// Translated to Zig from pitchpure/crates/pitchpure_engine/src/voice_eq.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Smart active voice EQ: five switchable bands that polish a vocal.
//!
//! Signal path (feed-forward, zero latency):
//!
//! ```text
//! in -> LowCut (4th-order Butterworth HPF)
//!    -> Mud (dynamic peaking cut, ~300 Hz)
//!    -> Presence (dynamic peaking boost, ~4 kHz)
//!    -> DeEss (dynamic peaking cut, ~7 kHz, fast)
//!    -> Air (high shelf, ~11 kHz) -> out
//! ```
//!
//! "Smart" means each dynamic band compares its own sidechain energy with
//! the broadband energy and moves toward a neutral vocal tonal-balance
//! target. The sidechains are band-passed copies of the post-low-cut signal,
//! so the decisions never react to the EQ's own moves. A muddy voice gets
//! low mids pulled down, a dull voice gets presence, sibilant bursts get
//! ducked, and a voice that is already balanced is left alone.
//!
//! Every filter is an RBJ "Audio EQ Cookbook" biquad in transposed direct
//! form II. Envelopes are one-pole power followers with separate attack and
//! release. Gains are smoothed and coefficients are recomputed at most once
//! per `SUB_BLOCK` samples, counted globally across calls, so the output
//! does not depend on how the host slices blocks and gain moves cannot
//! click.
//!
//! `amount` scales every move, Air included, so `amount = 0` is flat. A band
//! sitting at exactly 0 dB is skipped rather than filtered, which keeps the
//! all-flat path bit-identical to the input.
//!
//! Realtime notes: `VoiceEq.init` needs no heap at all; `process` is scalar
//! math only. Filter and envelope states are flushed below `1e-20` once per
//! sub-block, so silence cannot decay into denormals.

const std = @import("std");
const types = @import("types.zig");

const pi: f64 = std.math.pi;

/// Samples between gain/coefficient updates.
const SUB_BLOCK: usize = 32;
/// Default global amount.
const DEFAULT_AMOUNT: f32 = 0.6;
/// Default low-cut corner in Hz.
const DEFAULT_LOW_CUT_HZ: f32 = 80.0;
/// Default air shelf gain in dB (before `amount`).
const DEFAULT_AIR_DB: f32 = 2.0;

/// Mud band centre (Hz) and Q.
const MUD_HZ: f64 = 300.0;
const MUD_Q: f64 = 1.2;
/// Mud starts cutting when its band holds more than this share of the
/// broadband power (dB). Pink-ish speech spectra sit near -8..-10 dB.
const MUD_TARGET_DB: f32 = -5.0;
const MUD_SLOPE: f32 = 1.2;
const MUD_MAX_CUT_DB: f32 = 6.0;

/// Presence band centre (Hz) and Q.
const PRESENCE_HZ: f64 = 4000.0;
const PRESENCE_Q: f64 = 0.9;
/// Presence boosts only when its share falls below this (dB).
const PRESENCE_TARGET_DB: f32 = -12.0;
const PRESENCE_SLOPE: f32 = 0.4;
const PRESENCE_MAX_BOOST_DB: f32 = 4.0;

/// Sibilance band centre (Hz) and Q (covers roughly 5.5-9 kHz).
const DEESS_HZ: f64 = 7000.0;
const DEESS_Q: f64 = 1.0;
/// De-essing starts when sibilance exceeds this share (dB) of the fast
/// broadband level; normal speech keeps it well below.
const DEESS_TARGET_DB: f32 = -10.0;
const DEESS_SLOPE: f32 = 1.5;
const DEESS_MAX_CUT_DB: f32 = 10.0;

/// Air shelf corner (Hz).
const AIR_HZ: f64 = 11_000.0;

/// Slow analysis follower (tonal balance): attack / release seconds.
const SLOW_ATTACK_S: f32 = 0.040;
const SLOW_RELEASE_S: f32 = 0.200;
/// Fast analysis follower (sibilance).
const FAST_ATTACK_S: f32 = 0.001;
const FAST_RELEASE_S: f32 = 0.060;
/// Gain smoothing for the tonal bands (seconds).
const TONAL_GAIN_TAU_S: f32 = 0.050;
/// Gain smoothing for the de-esser (seconds).
const DEESS_GAIN_TAU_S: f32 = 0.002;
/// Gain smoothing for user-set static gains (air).
const STATIC_GAIN_TAU_S: f32 = 0.020;
/// Broadband power below this (about -70 dBFS) counts as silence: no moves.
const SILENCE_POWER: f32 = 1e-7;
/// Smoothed gains this close to target snap onto it.
const SNAP_DB: f32 = 1e-3;
/// Flush threshold for denormal protection.
const FLUSH: f32 = 1e-20;

/// One EQ band. Order is the processing order.
pub const Band = enum {
    low_cut,
    mud,
    presence,
    de_ess,
    air,

    pub const ALL = [5]Band{ .low_cut, .mud, .presence, .de_ess, .air };

    fn index(self: Band) usize {
        return switch (self) {
            .low_cut => 0,
            .mud => 1,
            .presence => 2,
            .de_ess => 3,
            .air => 4,
        };
    }
};

/// Transposed direct form II biquad.
const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,

    const IDENTITY: Biquad = .{ .b0 = 1.0, .b1 = 0.0, .b2 = 0.0, .a1 = 0.0, .a2 = 0.0, .z1 = 0.0, .z2 = 0.0 };

    fn set(self: *Biquad, b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64) void {
        self.b0 = @floatCast(b0 / a0);
        self.b1 = @floatCast(b1 / a0);
        self.b2 = @floatCast(b2 / a0);
        self.a1 = @floatCast(a1 / a0);
        self.a2 = @floatCast(a2 / a0);
    }

    inline fn tick(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }

    fn clear(self: *Biquad) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    fn flush(self: *Biquad) void {
        if (@abs(self.z1) < FLUSH) self.z1 = 0.0;
        if (@abs(self.z2) < FLUSH) self.z2 = 0.0;
    }
};

const CosSin = struct { c: f64, s: f64 };

/// RBJ cookbook designs; `fs` in Hz, frequencies clamped below Nyquist.
const Design = struct {
    fs: f64,

    fn w0(self: *const Design, hz_in: f64) CosSin {
        const hz = std.math.clamp(hz_in, 10.0, self.fs * 0.45);
        const w = 2.0 * pi * hz / self.fs;
        return .{ .c = @cos(w), .s = @sin(w) };
    }

    fn highpass(self: *const Design, f: *Biquad, hz: f64, q: f64) void {
        const cs = self.w0(hz);
        const c = cs.c;
        const alpha = cs.s / (2.0 * q);
        // f64::midpoint(1.0, c): both operands are small, so (a + b) / 2.
        const half = (1.0 + c) / 2.0;
        f.set(half, -(1.0 + c), half, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
    }

    /// Band-pass with 0 dB peak gain.
    fn bandpass(self: *const Design, f: *Biquad, hz: f64, q: f64) void {
        const cs = self.w0(hz);
        const alpha = cs.s / (2.0 * q);
        f.set(alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cs.c, 1.0 - alpha);
    }

    fn peaking(self: *const Design, f: *Biquad, hz: f64, q: f64, db: f32) void {
        const cs = self.w0(hz);
        const c = cs.c;
        const alpha = cs.s / (2.0 * q);
        const a = std.math.pow(f64, 10.0, @as(f64, db) / 40.0);
        f.set(1.0 + alpha * a, -2.0 * c, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * c, 1.0 - alpha / a);
    }

    /// High shelf, slope S = 1.
    fn highShelf(self: *const Design, f: *Biquad, hz: f64, db: f32) void {
        const cs = self.w0(hz);
        const c = cs.c;
        const a = std.math.pow(f64, 10.0, @as(f64, db) / 40.0);
        const alpha = cs.s / 2.0 * @sqrt(@as(f64, 2.0));
        const sa = 2.0 * @sqrt(a) * alpha;
        f.set(
            a * ((a + 1.0) + (a - 1.0) * c + sa),
            -2.0 * a * ((a - 1.0) + (a + 1.0) * c),
            a * ((a + 1.0) + (a - 1.0) * c - sa),
            (a + 1.0) - (a - 1.0) * c + sa,
            2.0 * ((a - 1.0) - (a + 1.0) * c),
            (a + 1.0) - (a - 1.0) * c - sa,
        );
    }
};

/// One-pole power follower with separate attack and release.
const Follower = struct {
    attack: f32,
    release: f32,
    power: f32,

    fn init(fs: f32, attack_s: f32, release_s: f32) Follower {
        return .{ .attack = onePole(fs, attack_s), .release = onePole(fs, release_s), .power = 0.0 };
    }

    inline fn push(self: *Follower, x: f32) void {
        const p = x * x;
        const k = if (p > self.power) self.attack else self.release;
        self.power += k * (p - self.power);
    }

    fn flush(self: *Follower) void {
        if (self.power < FLUSH) self.power = 0.0;
    }
};

/// Coefficient for a one-pole smoother with time constant `tau` at `rate`.
fn onePole(rate: f32, tau: f32) f32 {
    return 1.0 - @exp(-1.0 / @max(tau * rate, 1e-6));
}

fn ratioDb(band: f32, broad: f32) f32 {
    return 10.0 * @log10((band + 1e-12) / (broad + 1e-12));
}

/// Five-band adaptive voice EQ. See the module docs. Holds no heap memory.
pub const VoiceEq = struct {
    design: Design,
    amount_value: f32,
    enabled: [5]bool,
    low_cut_hz_value: f32,
    air_db_value: f32,

    low_cut: [2]Biquad,
    mud: Biquad,
    presence: Biquad,
    deess: Biquad,
    air: Biquad,

    sc_mud: Biquad,
    sc_presence: Biquad,
    sc_deess: Biquad,
    env_broad_slow: Follower,
    env_broad_fast: Follower,
    env_mud: Follower,
    env_presence: Follower,
    env_deess: Follower,

    /// Applied (smoothed) gain per band in dB; index 0 unused.
    gain_db: [5]f32,
    /// Gain the coefficients currently realise, per band.
    coef_db: [5]f32,
    tonal_k: f32,
    deess_k: f32,
    static_k: f32,
    low_cut_dirty: bool,
    counter: usize,

    /// Build an EQ for `sample_rate` with all bands on, `amount` 0.6,
    /// low cut at 80 Hz and +2 dB of air (before `amount`).
    pub fn init(sample_rate: types.SampleRateHz) VoiceEq {
        const fs: f32 = @floatFromInt(@max(sample_rate, 8_000));
        const design: Design = .{ .fs = fs };
        const block_rate = fs / @as(f32, @floatFromInt(SUB_BLOCK));
        var sc_mud = Biquad.IDENTITY;
        var sc_presence = Biquad.IDENTITY;
        var sc_deess = Biquad.IDENTITY;
        design.bandpass(&sc_mud, MUD_HZ, MUD_Q);
        design.bandpass(&sc_presence, PRESENCE_HZ, PRESENCE_Q);
        design.bandpass(&sc_deess, DEESS_HZ, DEESS_Q);
        var eq: VoiceEq = .{
            .design = design,
            .amount_value = DEFAULT_AMOUNT,
            .enabled = @splat(true),
            .low_cut_hz_value = DEFAULT_LOW_CUT_HZ,
            .air_db_value = DEFAULT_AIR_DB,
            .low_cut = @splat(Biquad.IDENTITY),
            .mud = Biquad.IDENTITY,
            .presence = Biquad.IDENTITY,
            .deess = Biquad.IDENTITY,
            .air = Biquad.IDENTITY,
            .sc_mud = sc_mud,
            .sc_presence = sc_presence,
            .sc_deess = sc_deess,
            .env_broad_slow = .init(fs, SLOW_ATTACK_S, SLOW_RELEASE_S),
            .env_broad_fast = .init(fs, FAST_ATTACK_S, FAST_RELEASE_S),
            .env_mud = .init(fs, SLOW_ATTACK_S, SLOW_RELEASE_S),
            .env_presence = .init(fs, SLOW_ATTACK_S, SLOW_RELEASE_S),
            .env_deess = .init(fs, FAST_ATTACK_S, FAST_RELEASE_S),
            .gain_db = @splat(0.0),
            .coef_db = @splat(0.0),
            .tonal_k = onePole(block_rate, TONAL_GAIN_TAU_S),
            .deess_k = onePole(block_rate, DEESS_GAIN_TAU_S),
            .static_k = onePole(block_rate, STATIC_GAIN_TAU_S),
            .low_cut_dirty = true,
            .counter = 0,
        };
        eq.updateLowCut();
        return eq;
    }

    /// Global strength of every move, `0..=1` (0 = flat).
    pub fn setAmount(self: *VoiceEq, a: f32) void {
        self.amount_value = if (std.math.isFinite(a)) std.math.clamp(a, 0.0, 1.0) else 0.0;
    }

    pub fn amount(self: *const VoiceEq) f32 {
        return self.amount_value;
    }

    /// Switch one band in or out. Re-enabling starts from clean state.
    pub fn setBandEnabled(self: *VoiceEq, b: Band, on: bool) void {
        const i = b.index();
        if (self.enabled[i] != on) {
            self.enabled[i] = on;
            self.gain_db[i] = 0.0;
            self.coef_db[i] = 0.0;
            switch (b) {
                .low_cut => for (&self.low_cut) |*f| f.clear(),
                .mud => self.mud.clear(),
                .presence => self.presence.clear(),
                .de_ess => self.deess.clear(),
                .air => self.air.clear(),
            }
        }
    }

    pub fn bandEnabled(self: *const VoiceEq, b: Band) bool {
        return self.enabled[b.index()];
    }

    /// Low-cut corner, clamped to `40..=200` Hz.
    pub fn setLowCutHz(self: *VoiceEq, hz_in: f32) void {
        const hz = if (std.math.isFinite(hz_in)) std.math.clamp(hz_in, 40.0, 200.0) else DEFAULT_LOW_CUT_HZ;
        if (@abs(hz - self.low_cut_hz_value) > std.math.floatEps(f32)) {
            self.low_cut_hz_value = hz;
            self.low_cut_dirty = true;
        }
    }

    pub fn lowCutHz(self: *const VoiceEq) f32 {
        return self.low_cut_hz_value;
    }

    /// Air shelf gain, clamped to `0..=4` dB (scaled by `amount`).
    pub fn setAirDb(self: *VoiceEq, db: f32) void {
        self.air_db_value = if (std.math.isFinite(db)) std.math.clamp(db, 0.0, 4.0) else 0.0;
    }

    pub fn airDb(self: *const VoiceEq) f32 {
        return self.air_db_value;
    }

    /// Gain currently applied by `b` in dB, for metering. `low_cut` and
    /// disabled bands report 0.
    pub fn bandGainDb(self: *const VoiceEq, b: Band) f32 {
        if (b == .low_cut or !self.enabled[b.index()]) return 0.0;
        return self.gain_db[b.index()];
    }

    fn updateLowCut(self: *VoiceEq) void {
        // 4th-order Butterworth as two cascaded biquads.
        const hz: f64 = self.low_cut_hz_value;
        self.design.highpass(&self.low_cut[0], hz, 0.541_196_1);
        self.design.highpass(&self.low_cut[1], hz, 1.306_563);
        self.low_cut_dirty = false;
    }

    fn filters(self: *VoiceEq) [9]*Biquad {
        return .{
            &self.low_cut[0], &self.low_cut[1], &self.mud,         &self.presence, &self.deess,
            &self.air,        &self.sc_mud,     &self.sc_presence, &self.sc_deess,
        };
    }

    fn followers(self: *VoiceEq) [5]*Follower {
        return .{ &self.env_broad_slow, &self.env_broad_fast, &self.env_mud, &self.env_presence, &self.env_deess };
    }

    /// Per-sub-block control: targets from the analysis, smoothing, and
    /// coefficient refresh. Runs before the first sample of each sub-block.
    fn control(self: *VoiceEq) void {
        if (self.low_cut_dirty) self.updateLowCut();
        const silent = self.env_broad_slow.power < SILENCE_POWER;
        const amt = self.amount_value;
        var target: [5]f32 = @splat(0.0);
        if (!silent) {
            const mud = ratioDb(self.env_mud.power, self.env_broad_slow.power) - MUD_TARGET_DB;
            target[1] = -std.math.clamp(mud * MUD_SLOPE, 0.0, MUD_MAX_CUT_DB) * amt;
            const pres = PRESENCE_TARGET_DB - ratioDb(self.env_presence.power, self.env_broad_slow.power);
            target[2] = std.math.clamp(pres * PRESENCE_SLOPE, 0.0, PRESENCE_MAX_BOOST_DB) * amt;
        }
        if (self.env_broad_fast.power >= SILENCE_POWER) {
            const ess = ratioDb(self.env_deess.power, self.env_broad_fast.power) - DEESS_TARGET_DB;
            target[3] = -std.math.clamp(ess * DEESS_SLOPE, 0.0, DEESS_MAX_CUT_DB) * amt;
        }
        target[4] = self.air_db_value * amt;

        const ks = [5]f32{ 0.0, self.tonal_k, self.tonal_k, self.deess_k, self.static_k };
        for (1..5) |i| {
            if (!self.enabled[i]) continue;
            const g = &self.gain_db[i];
            g.* += ks[i] * (target[i] - g.*);
            if (@abs(target[i] - g.*) < SNAP_DB) g.* = target[i];
            if (@abs(g.* - self.coef_db[i]) > 0.005 or (g.* == 0.0 and self.coef_db[i] != 0.0)) {
                self.coef_db[i] = g.*;
                switch (i) {
                    1 => self.design.peaking(&self.mud, MUD_HZ, MUD_Q, g.*),
                    2 => self.design.peaking(&self.presence, PRESENCE_HZ, PRESENCE_Q, g.*),
                    3 => self.design.peaking(&self.deess, DEESS_HZ, DEESS_Q, g.*),
                    else => self.design.highShelf(&self.air, AIR_HZ, g.*),
                }
            }
        }

        for (self.filters()) |f| f.flush();
        for (self.followers()) |e| e.flush();
    }

    pub fn reset(self: *VoiceEq) void {
        for (self.filters()) |f| f.clear();
        for (self.followers()) |e| e.power = 0.0;
        self.gain_db = @splat(0.0);
        self.coef_db = @splat(0.0);
        self.counter = 0;
    }

    /// Processes `min(input.len, output.len)` samples.
    pub fn process(self: *VoiceEq, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        const analyse = self.enabled[1] or self.enabled[2] or self.enabled[3];
        for (0..n) |i| {
            if (self.counter == 0) self.control();
            self.counter = (self.counter + 1) % SUB_BLOCK;

            var x = input[i];
            if (!std.math.isFinite(x)) x = 0.0;
            if (self.enabled[0]) {
                x = self.low_cut[0].tick(x);
                x = self.low_cut[1].tick(x);
            }
            if (analyse) {
                self.env_broad_slow.push(x);
                self.env_broad_fast.push(x);
                if (self.enabled[1]) {
                    const s = self.sc_mud.tick(x);
                    self.env_mud.push(s);
                }
                if (self.enabled[2]) {
                    const s = self.sc_presence.tick(x);
                    self.env_presence.push(s);
                }
                if (self.enabled[3]) {
                    const s = self.sc_deess.tick(x);
                    self.env_deess.push(s);
                }
            }
            // A band at exactly 0 dB is skipped (bit-transparent).
            if (self.enabled[1] and self.coef_db[1] != 0.0) x = self.mud.tick(x);
            if (self.enabled[2] and self.coef_db[2] != 0.0) x = self.presence.tick(x);
            if (self.enabled[3] and self.coef_db[3] != 0.0) x = self.deess.tick(x);
            if (self.enabled[4] and self.coef_db[4] != 0.0) x = self.air.tick(x);
            output[i] = x;
        }
    }

    pub fn latencySamples(self: *const VoiceEq) usize {
        _ = self;
        return 0;
    }
};

comptime {
    types.assertProcessor(VoiceEq);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const FS: u32 = 48_000;

fn testSine(gpa: std.mem.Allocator, hz: f32, amp: f32, n: usize, phase0: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(2.0 * std.math.pi * hz * @as(f32, @floatFromInt(i + phase0)) / @as(f32, @floatFromInt(FS)));
    }
    return out;
}

fn testRms(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |v| sum += v * v;
    return @sqrt(sum / @as(f32, @floatFromInt(@max(x.len, 1))));
}

fn testDb(a: f32, b: f32) f32 {
    return 20.0 * @log10(a / b);
}

fn only(eq: *VoiceEq, band: ?Band) void {
    for (Band.ALL) |b| eq.setBandEnabled(b, band != null and band.? == b);
}

fn run(gpa: std.mem.Allocator, eq: *VoiceEq, x: []const f32) ![]f32 {
    const y = try gpa.alloc(f32, x.len);
    @memset(y, 0.0);
    eq.process(x, y);
    return y;
}

/// Deterministic white noise in -1..1 (xorshift).
fn testNoise(gpa: std.mem.Allocator, n: usize, seed: u32) ![]f32 {
    const out = try gpa.alloc(f32, n);
    var s: u32 = @max(seed, 1);
    for (out) |*v| {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        v.* = (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(std.math.maxInt(u32)))) * 2.0 - 1.0;
    }
    return out;
}

/// Pink-ish noise via Paul Kellet's economy filter.
fn testPink(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const out = try testNoise(gpa, n, 7);
    var b0: f32 = 0.0;
    var b1: f32 = 0.0;
    var b2: f32 = 0.0;
    for (out) |*v| {
        const w = v.*;
        b0 = 0.99765 * b0 + w * 0.099_046;
        b1 = 0.96300 * b1 + w * 0.296_516_4;
        b2 = 0.57000 * b2 + w * 1.052_691_3;
        v.* = (b0 + b1 + b2 + w * 0.1848) * 0.1;
    }
    return out;
}

test "flat_paths_are_bit_identical" {
    const gpa = testing.allocator;
    const x = try testNoise(gpa, 10_000, 3);
    defer gpa.free(x);
    var eq = VoiceEq.init(FS);
    only(&eq, null);
    const y1 = try run(gpa, &eq, x);
    defer gpa.free(y1);
    try testing.expectEqualSlices(f32, x, y1);
    // amount 0 with every dynamic band and air on is also untouched.
    eq = VoiceEq.init(FS);
    eq.setAmount(0.0);
    eq.setBandEnabled(.low_cut, false);
    const y2 = try run(gpa, &eq, x);
    defer gpa.free(y2);
    try testing.expectEqualSlices(f32, x, y2);
}

test "low_cut_removes_rumble_keeps_voice" {
    const gpa = testing.allocator;
    const cases = [_][2]f32{ .{ 30.0, -12.0 }, .{ 1000.0, 0.0 } };
    for (cases) |case| {
        const hz = case[0];
        const check = case[1];
        var eq = VoiceEq.init(FS);
        only(&eq, .low_cut);
        const x = try testSine(gpa, hz, 0.5, FS, 0);
        defer gpa.free(x);
        const y = try run(gpa, &eq, x);
        defer gpa.free(y);
        const tail = FS / 2;
        const g = testDb(testRms(y[tail..]), testRms(x[tail..]));
        if (check < 0.0) {
            try testing.expect(g <= check);
        } else {
            try testing.expect(@abs(g) <= 0.5);
        }
    }
}

test "deesser_ducks_sibilance_not_voice" {
    const gpa = testing.allocator;
    const n: usize = FS;
    const low = try testSine(gpa, 300.0, 0.3, n, 0);
    defer gpa.free(low);
    const ess = try testSine(gpa, 7000.0, 0.3, n, 0);
    defer gpa.free(ess);
    // 300 Hz tone throughout; 7 kHz burst in the second half.
    const x = try gpa.alloc(f32, n);
    defer gpa.free(x);
    for (x, 0..) |*v, i| v.* = low[i] + (if (i >= n / 2) ess[i] else 0.0);
    var eq = VoiceEq.init(FS);
    only(&eq, .de_ess);
    const y = try run(gpa, &eq, x);
    defer gpa.free(y);
    const a = n / 2 + FS / 10;
    var bp_in = Biquad.IDENTITY;
    var bp_out = Biquad.IDENTITY;
    const d: Design = .{ .fs = @floatFromInt(FS) };
    d.bandpass(&bp_in, 7000.0, 4.0);
    d.bandpass(&bp_out, 7000.0, 4.0);
    const xi = try gpa.alloc(f32, n);
    defer gpa.free(xi);
    const yo = try gpa.alloc(f32, n);
    defer gpa.free(yo);
    for (x, xi) |v, *o| o.* = bp_in.tick(v);
    for (y, yo) |v, *o| o.* = bp_out.tick(v);
    const ess_change = testDb(testRms(yo[a..]), testRms(xi[a..]));
    try testing.expect(ess_change <= -4.0);
    try testing.expect(eq.bandGainDb(.de_ess) <= -4.0);
    // Tone-only region keeps its level.
    const tone_change = testDb(testRms(y[FS / 10 .. n / 2]), testRms(x[FS / 10 .. n / 2]));
    try testing.expect(@abs(tone_change) <= 1.0);
}

test "mud_cuts_boomy_but_not_balanced" {
    const gpa = testing.allocator;
    var eq = VoiceEq.init(FS);
    only(&eq, .mud);
    const x = try testSine(gpa, 300.0, 0.3, FS, 0);
    defer gpa.free(x);
    gpa.free(try run(gpa, &eq, x));
    try testing.expect(eq.bandGainDb(.mud) < -2.0);

    eq = VoiceEq.init(FS);
    only(&eq, .mud);
    eq.setBandEnabled(.low_cut, true);
    const p = try testPink(gpa, FS);
    defer gpa.free(p);
    gpa.free(try run(gpa, &eq, p));
    try testing.expect(@abs(eq.bandGainDb(.mud)) < 0.5);
}

test "presence_lifts_dull_voice_only" {
    const gpa = testing.allocator;
    var eq = VoiceEq.init(FS);
    only(&eq, .presence);
    const s = try testSine(gpa, 200.0, 0.3, FS, 0);
    defer gpa.free(s);
    gpa.free(try run(gpa, &eq, s));
    const dull = eq.bandGainDb(.presence);
    try testing.expect(dull > 1.0);
    eq = VoiceEq.init(FS);
    only(&eq, .presence);
    const p = try testPink(gpa, FS);
    defer gpa.free(p);
    gpa.free(try run(gpa, &eq, p));
    try testing.expect(eq.bandGainDb(.presence) < 0.5);
}

test "silence_stays_finite_and_zero" {
    const gpa = testing.allocator;
    var eq = VoiceEq.init(FS);
    const nz = try testNoise(gpa, 4800, 9);
    defer gpa.free(nz);
    const x = try gpa.alloc(f32, 4800 + FS * 3);
    defer gpa.free(x);
    @memset(x, 0.0);
    @memcpy(x[0..4800], nz);
    const y = try run(gpa, &eq, x);
    defer gpa.free(y);
    for (y) |v| try testing.expect(std.math.isFinite(v));
    const tail = y[y.len - 1000 ..];
    for (tail) |v| try testing.expect(v == 0.0 or @abs(v) >= std.math.floatMin(f32));
    for (eq.low_cut) |f| try testing.expect(f.z1 == 0.0 or @abs(f.z1) >= FLUSH);
    // NaN input does not poison state.
    const nan_in = [_]f32{ std.math.nan(f32), 0.5, 0.25 };
    const y2 = try run(gpa, &eq, &nan_in);
    defer gpa.free(y2);
    for (y2) |v| try testing.expect(std.math.isFinite(v));
}

test "block_size_does_not_change_output" {
    const gpa = testing.allocator;
    const x = try testPink(gpa, 20_000);
    defer gpa.free(x);
    const s = try testSine(gpa, 7000.0, 0.2, 20_000, 0);
    defer gpa.free(s);
    for (x, s) |*a, b| a.* = a.* + b;
    var reference = VoiceEq.init(FS);
    const want = try run(gpa, &reference, x);
    defer gpa.free(want);
    const got = try gpa.alloc(f32, x.len);
    defer gpa.free(got);
    for ([_]usize{ 1, 37, 512, 1024 }) |size| {
        var eq = VoiceEq.init(FS);
        @memset(got, 0.0);
        var start: usize = 0;
        while (start < x.len) : (start += size) {
            const end = @min(start + size, x.len);
            eq.process(x[start..end], got[start..end]);
        }
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "cpu_cost_is_small" {
    const gpa = testing.allocator;
    const x = try testPink(gpa, 1024);
    defer gpa.free(x);
    var y: [1024]f32 = @splat(0.0);
    var eq = VoiceEq.init(FS);
    const iters: u32 = 2000;
    const io = std.Io.Threaded.global_single_threaded.io();
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iters) |_| eq.process(x, &y);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const ns: f64 = @floatFromInt(t0.durationTo(t1).raw.toNanoseconds());
    const us = ns / 1e3 / @as(f64, @floatFromInt(iters));
    // 1024 samples at 48 kHz = 21 333 us; stay far below.
    try testing.expect(us < 2000.0);
}
