// Translated to Zig from soundcraft/crates/dsp/src/meter.rs, soundcraft/crates/dsp/src/util.rs, soundcraft/crates/dsp/tests/it/offline_meters.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Level meters: DAW-style peak meter, RMS meter, and an ITU-R BS.1770 loudness meter
//! (momentary, short-term and gated integrated LUFS plus 4x oversampled true peak).
//!
//! Realtime safety: `PeakMeter.feed` and `PeakMeter.process`, `RmsMeter.process` and
//! `LoudnessMeter.process` take caller slices and never allocate, lock, log or do I/O.
//! Everything `LoudnessMeter` needs is allocated once in `LoudnessMeter.init(gpa, sample_rate,
//! channels)` and released by `deinit`.
//!
//! Seridian: the Rust loudness gating history is a fixed 1800-bin histogram, created in `new()`
//! and never grown. It is an inline array here, so it costs no allocation at all. The bin step
//! (0.05 LU) is kept so the gated result is numerically the same as the Rust original.

const std = @import("std");
const testing = std.testing;
const biquad = @import("biquad.zig");
const db = @import("db.zig");

const Biquad = biquad.Biquad;
const Coeffs = biquad.Coeffs;
const MIN_DB = db.MIN_DB;

/// Upper bound on channels any plugin allocates state for (util.rs `MAX_CHANNELS`).
const MAX_CHANNELS: usize = 64;
const SUB_BLOCKS: usize = 30; // 3 s of 100 ms sub-blocks
const HIST_MIN: f32 = -70.0;
const HIST_STEP: f32 = 0.05;
const HIST_BINS: usize = 1800; // -70 .. +20 LUFS
const TP_PHASES: usize = 4;
const TP_TAPS: usize = 12;
const TP_HIST_LEN: usize = 2 * TP_TAPS;

/// `f32::max` as Rust defines it: a NaN operand is ignored, the other operand wins.
fn rustMax(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return b;
    if (std.math.isNan(b)) return a;
    return @max(a, b);
}

/// util.rs `ms_to_samples`: milliseconds to (fractional) samples, never negative or non-finite.
fn msToSamples(ms: f32, sr: f32) f32 {
    const s = ms * 0.001 * sr;
    return if (std.math.isFinite(s)) rustMax(s, 0.0) else 0.0;
}

/// util.rs `time_coef`: one-pole smoothing coefficient for a time constant.
fn timeCoef(ms: f32, sr: f32) f32 {
    const n = msToSamples(ms, sr);
    return if (n < 1.0e-3) 0.0 else @exp(-1.0 / n);
}

/// Peak meter with instant attack, linear-in-dB release, peak hold and a clip latch.
pub const PeakMeter = struct {
    sr: f32,
    level_db: f32,
    hold_db: f32,
    hold_left: f32,
    hold_secs: f32,
    release_db_per_sec: f32,
    clip_latched: bool,

    /// A meter with 20 dB/s release and a 2 s peak hold.
    pub fn init(sample_rate: f32) PeakMeter {
        return .{
            .sr = db.saneSr(sample_rate),
            .level_db = MIN_DB,
            .hold_db = MIN_DB,
            .hold_left = 0.0,
            .hold_secs = 2.0,
            .release_db_per_sec = 20.0,
            .clip_latched = false,
        };
    }

    pub fn setReleaseDbPerSec(self: *PeakMeter, rate: f32) void {
        if (std.math.isFinite(rate)) self.release_db_per_sec = std.math.clamp(rate, 0.1, 1000.0);
    }

    pub fn setHoldSecs(self: *PeakMeter, secs: f32) void {
        if (std.math.isFinite(secs)) self.hold_secs = std.math.clamp(secs, 0.0, 60.0);
    }

    /// Feeds one block of samples. Non-finite samples are ignored.
    pub fn process(self: *PeakMeter, samples: []const f32) void {
        var peak: f32 = 0.0;
        for (samples) |v| {
            if (std.math.isFinite(v)) peak = rustMax(peak, @abs(v));
        }
        self.feed(peak, samples.len);
    }

    /// Feeds an already-computed block peak (linear) covering `frames` samples.
    pub fn feed(self: *PeakMeter, peak: f32, frames: usize) void {
        const dt = @as(f32, @floatFromInt(frames)) / self.sr;
        if (peak >= 1.0) self.clip_latched = true;
        const peak_db = db.gainToDb(peak);
        const decayed = rustMax(self.level_db - self.release_db_per_sec * dt, MIN_DB);
        self.level_db = rustMax(decayed, peak_db);
        if (peak_db >= self.hold_db) {
            self.hold_db = peak_db;
            self.hold_left = self.hold_secs;
        } else if (self.hold_left > 0.0) {
            self.hold_left -= dt;
        } else {
            self.hold_db = rustMax(self.hold_db - self.release_db_per_sec * dt, self.level_db);
        }
    }

    /// Displayed level in dBFS.
    pub fn levelDb(self: *const PeakMeter) f32 {
        return self.level_db;
    }

    /// Held peak in dBFS.
    pub fn peakHoldDb(self: *const PeakMeter) f32 {
        return self.hold_db;
    }

    /// True once any sample reached full scale, until `resetClip`.
    pub fn clipped(self: *const PeakMeter) bool {
        return self.clip_latched;
    }

    pub fn resetClip(self: *PeakMeter) void {
        self.clip_latched = false;
    }

    pub fn reset(self: *PeakMeter) void {
        self.level_db = MIN_DB;
        self.hold_db = MIN_DB;
        self.hold_left = 0.0;
        self.clip_latched = false;
    }
};

/// Exponentially averaged RMS meter (300 ms time constant by default).
pub const RmsMeter = struct {
    sr: f32,
    coef: f32,
    ms: f64,

    pub fn init(sample_rate: f32) RmsMeter {
        var m: RmsMeter = .{ .sr = db.saneSr(sample_rate), .coef = 0.0, .ms = 0.0 };
        m.setWindowMs(300.0);
        return m;
    }

    pub fn setWindowMs(self: *RmsMeter, ms: f32) void {
        const window = if (std.math.isFinite(ms)) std.math.clamp(ms, 1.0, 10_000.0) else 300.0;
        self.coef = timeCoef(window, self.sr);
    }

    pub fn process(self: *RmsMeter, samples: []const f32) void {
        const k: f64 = @as(f64, 1.0 - self.coef);
        for (samples) |s| {
            const x: f64 = if (std.math.isFinite(s)) @as(f64, s) else 0.0;
            self.ms += (x * x - self.ms) * k;
        }
        if (self.ms < 1e-30) self.ms = 0.0;
    }

    /// Current RMS level in dBFS (sine-referenced: an RMS of 0.707 reads -3 dB).
    pub fn rmsDb(self: *const RmsMeter) f32 {
        return db.gainToDb(@floatCast(@sqrt(self.ms)));
    }

    pub fn reset(self: *RmsMeter) void {
        self.ms = 0.0;
    }
};

/// Loudness from mean-square energy (BS.1770 eq. 2).
fn lufs(energy: f64) f32 {
    if (energy <= 1e-20) return MIN_DB;
    return @floatCast(-0.691 + 10.0 * @log10(energy));
}

/// Bilinear prewarp of a corner frequency. The corner is held just below Nyquist, as
/// `Coeffs.design` does, so the tangent stays finite and the poles stay inside the unit circle.
fn prewarp(f0: f64, sr: f64) f64 {
    return @tan(std.math.pi * @min(f0, sr * 0.49) / sr);
}

/// K-weighting pre-filter (high shelf) and RLB high-pass, designed for any sample rate.
fn kWeighting(sample_rate: f32) [2]Coeffs {
    const sr: f64 = @floatCast(sample_rate);

    // Stage 1: high shelf.
    const f0_1: f64 = 1681.974450955533;
    const g: f64 = 3.999843853973347;
    const q1: f64 = 0.7071752369554196;
    const k1 = prewarp(f0_1, sr);
    const vh = std.math.pow(f64, 10.0, g / 20.0);
    const vb = std.math.pow(f64, vh, 0.4996667741545416);
    const a0_1 = 1.0 + k1 / q1 + k1 * k1;
    const s1 = Coeffs{
        .b0 = @floatCast((vh + vb * k1 / q1 + k1 * k1) / a0_1),
        .b1 = @floatCast(2.0 * (k1 * k1 - vh) / a0_1),
        .b2 = @floatCast((vh - vb * k1 / q1 + k1 * k1) / a0_1),
        .a1 = @floatCast(2.0 * (k1 * k1 - 1.0) / a0_1),
        .a2 = @floatCast((1.0 - k1 / q1 + k1 * k1) / a0_1),
    };

    // Stage 2: RLB high-pass.
    const f0_2: f64 = 38.13547087602444;
    const q2: f64 = 0.5003270373238773;
    const k2 = prewarp(f0_2, sr);
    const a0_2 = 1.0 + k2 / q2 + k2 * k2;
    const s2 = Coeffs{
        .b0 = 1.0,
        .b1 = -2.0,
        .b2 = 1.0,
        .a1 = @floatCast(2.0 * (k2 * k2 - 1.0) / a0_2),
        .a2 = @floatCast((1.0 - k2 / q2 + k2 * k2) / a0_2),
    };
    return .{ s1, s2 };
}

/// Interpolation filter for true peak: a windowed sinc at the original Nyquist, split into
/// `TP_PHASES` polyphase branches of `TP_TAPS` taps, each branch normalised to unity DC gain.
fn truePeakCoefs() [TP_TAPS][TP_PHASES]f32 {
    var coefs = std.mem.zeroes([TP_TAPS][TP_PHASES]f32);
    const total: usize = TP_TAPS * TP_PHASES;
    const total_f: f64 = @floatFromInt(total);
    const center = (total_f - 1.0) / 2.0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const i_f: f64 = @floatFromInt(i);
        const t = (i_f - center) / @as(f64, TP_PHASES);
        const sinc: f64 = if (@abs(t) < 1e-12) 1.0 else @sin(std.math.pi * t) / (std.math.pi * t);
        const x = i_f / (total_f - 1.0);
        const w = 0.42 - 0.5 * @cos(2.0 * std.math.pi * x) + 0.08 * @cos(4.0 * std.math.pi * x);
        coefs[i / TP_PHASES][i % TP_PHASES] = @floatCast(sinc * w);
    }
    var p: usize = 0;
    while (p < TP_PHASES) : (p += 1) {
        var s: f32 = 0.0;
        for (coefs) |tap| s += tap[p];
        if (@abs(s) > 1e-6) {
            for (&coefs) |*tap| tap[p] /= s;
        }
    }
    return coefs;
}

/// ITU-R BS.1770 / EBU R128 loudness meter.
///
/// Scratch memory (channel filters, block accumulators, true-peak history) is owned by the meter
/// and allocated in `init`; `process` and the readers never allocate.
pub const LoudnessMeter = struct {
    sr: f32,
    weights: []f32,
    filters: [][2]Biquad,
    block_len: usize,
    block_pos: usize,
    block_acc: []f64,
    sub: [SUB_BLOCKS]f64,
    sub_idx: usize,
    sub_filled: usize,
    /// Gating histogram of 400 ms block energies, indexed by loudness (`HIST_STEP` bins).
    hist_count: [HIST_BINS]u64,
    hist_energy: [HIST_BINS]f64,
    tp_coefs: [TP_TAPS][TP_PHASES]f32,
    tp_hist: [][TP_HIST_LEN]f32,
    tp_pos: []usize,
    true_peak: f32,
    max_momentary: f32,

    /// Creates a meter. Channel weights default to 1.0, except a 6-channel (5.1: L R C LFE Ls Rs)
    /// layout which uses 0 for LFE and 1.41 for the surrounds.
    /// Seridian: the only allocations of this meter; release them with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate: f32, channels: usize) !LoudnessMeter {
        const sr = db.saneSr(sample_rate);
        const ch = std.math.clamp(channels, 1, MAX_CHANNELS);

        const weights = try gpa.alloc(f32, ch);
        errdefer gpa.free(weights);
        if (ch == 6) {
            const surround = [6]f32{ 1.0, 1.0, 1.0, 0.0, 1.41, 1.41 };
            @memcpy(weights, &surround);
        } else {
            @memset(weights, 1.0);
        }

        const filters = try gpa.alloc([2]Biquad, ch);
        errdefer gpa.free(filters);
        const block_acc = try gpa.alloc(f64, ch);
        errdefer gpa.free(block_acc);
        const tp_hist = try gpa.alloc([TP_HIST_LEN]f32, ch);
        errdefer gpa.free(tp_hist);
        const tp_pos = try gpa.alloc(usize, ch);
        errdefer gpa.free(tp_pos);

        const c = kWeighting(sr);
        @memset(filters, [2]Biquad{ Biquad.init(c[0]), Biquad.init(c[1]) });
        @memset(block_acc, 0.0);
        @memset(tp_hist, std.mem.zeroes([TP_HIST_LEN]f32));
        @memset(tp_pos, 0);

        return .{
            .sr = sr,
            .weights = weights,
            .filters = filters,
            .block_len = @max(1, @as(usize, @intFromFloat(@round(sr * 0.1)))),
            .block_pos = 0,
            .block_acc = block_acc,
            .sub = std.mem.zeroes([SUB_BLOCKS]f64),
            .sub_idx = 0,
            .sub_filled = 0,
            .hist_count = std.mem.zeroes([HIST_BINS]u64),
            .hist_energy = std.mem.zeroes([HIST_BINS]f64),
            .tp_coefs = truePeakCoefs(),
            .tp_hist = tp_hist,
            .tp_pos = tp_pos,
            .true_peak = 0.0,
            .max_momentary = MIN_DB,
        };
    }

    pub fn deinit(self: *LoudnessMeter, gpa: std.mem.Allocator) void {
        gpa.free(self.weights);
        gpa.free(self.filters);
        gpa.free(self.block_acc);
        gpa.free(self.tp_hist);
        gpa.free(self.tp_pos);
        self.* = undefined;
    }

    /// Overrides a channel's weighting (e.g. 1.41 for surrounds, 0 to exclude LFE).
    pub fn setChannelWeight(self: *LoudnessMeter, channel: usize, weight: f32) void {
        if (channel < self.weights.len) {
            self.weights[channel] = if (std.math.isFinite(weight)) std.math.clamp(weight, 0.0, 4.0) else 1.0;
        }
    }

    pub fn sampleRate(self: *const LoudnessMeter) f32 {
        return self.sr;
    }

    pub fn reset(self: *LoudnessMeter) void {
        for (self.filters) |*f| {
            f[0].reset();
            f[1].reset();
        }
        self.block_pos = 0;
        @memset(self.block_acc, 0.0);
        self.sub = std.mem.zeroes([SUB_BLOCKS]f64);
        self.sub_idx = 0;
        self.sub_filled = 0;
        self.hist_count = std.mem.zeroes([HIST_BINS]u64);
        self.hist_energy = std.mem.zeroes([HIST_BINS]f64);
        @memset(self.tp_hist, std.mem.zeroes([TP_HIST_LEN]f32));
        @memset(self.tp_pos, 0);
        self.true_peak = 0.0;
        self.max_momentary = MIN_DB;
    }

    /// Feeds planar audio. Channels beyond the meter's channel count are ignored; non-finite
    /// samples count as silence. Never allocates.
    pub fn process(self: *LoudnessMeter, io: []const []const f32, frames_in: usize) void {
        const ch = @min(self.filters.len, io.len);
        var frames = frames_in;
        for (io[0..ch]) |b| frames = @min(frames, b.len);
        var n: usize = 0;
        while (n < frames) : (n += 1) {
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                const raw = io[c][n];
                const x: f32 = if (std.math.isFinite(raw)) raw else 0.0;
                const f = &self.filters[c];
                const y = f[1].processSample(f[0].processSample(x));
                self.block_acc[c] += @as(f64, y) * @as(f64, y);
                self.truePeakSample(c, x);
            }
            self.block_pos += 1;
            if (self.block_pos >= self.block_len) self.finishSubBlock();
        }
    }

    /// 4x oversampled true peak of one sample, via the polyphase FIR over a circular history.
    fn truePeakSample(self: *LoudnessMeter, c: usize, x: f32) void {
        const h = &self.tp_hist[c];
        const pos = &self.tp_pos[c];
        pos.* = (pos.* + TP_TAPS - 1) % TP_TAPS;
        const p = pos.*;
        h[p] = x;
        h[p + TP_TAPS] = x;
        const w = h[p .. p + TP_TAPS];
        var y: [TP_PHASES]f32 = @splat(-0.0);
        for (self.tp_coefs, w) |cs, s| {
            for (&y, cs) |*acc, k| acc.* += k * s;
        }
        var peak = @abs(x);
        for (y) |v| peak = rustMax(peak, @abs(v));
        if (peak > self.true_peak) self.true_peak = peak;
    }

    /// Closes a 100 ms sub-block: stores its weighted mean energy and, once four are available,
    /// updates the momentary maximum and the gating histogram. No allocation.
    fn finishSubBlock(self: *LoudnessMeter) void {
        const len: f64 = @floatFromInt(@max(self.block_pos, 1));
        var energy: f64 = 0.0;
        for (self.block_acc, self.weights) |*acc, w| {
            energy += @as(f64, w) * acc.* / len;
            acc.* = 0.0;
        }
        self.block_pos = 0;
        self.sub[self.sub_idx] = energy;
        self.sub_idx = (self.sub_idx + 1) % SUB_BLOCKS;
        self.sub_filled = @min(self.sub_filled + 1, SUB_BLOCKS);
        if (self.sub_filled >= 4) {
            const z = self.recentEnergy(4);
            const l = lufs(z);
            self.max_momentary = rustMax(self.max_momentary, l);
            if (l > HIST_MIN) {
                // l > HIST_MIN, so the scaled value is non-negative and finite.
                const raw = (l - HIST_MIN) / HIST_STEP;
                const bin: usize = @intFromFloat(@min(raw, @as(f32, HIST_BINS - 1)));
                self.hist_count[bin] += 1;
                self.hist_energy[bin] += z;
            }
        }
    }

    /// Mean energy of the last `n` completed 100 ms sub-blocks.
    fn recentEnergy(self: *const LoudnessMeter, n_req: usize) f64 {
        const n = @min(n_req, self.sub_filled);
        if (n == 0) return 0.0;
        var sum: f64 = 0.0;
        var k: usize = 1;
        while (k <= n) : (k += 1) {
            const idx = (self.sub_idx + SUB_BLOCKS - k) % SUB_BLOCKS;
            sum += self.sub[idx];
        }
        return sum / @as(f64, @floatFromInt(n));
    }

    /// Momentary loudness (400 ms window), LUFS. -144 until 400 ms have been measured.
    pub fn momentaryLufs(self: *const LoudnessMeter) f32 {
        return if (self.sub_filled < 4) MIN_DB else lufs(self.recentEnergy(4));
    }

    /// Short-term loudness (3 s window, or what is available so far), LUFS.
    pub fn shortTermLufs(self: *const LoudnessMeter) f32 {
        return if (self.sub_filled < 4) MIN_DB else lufs(self.recentEnergy(SUB_BLOCKS));
    }

    /// Highest momentary loudness seen.
    pub fn maxMomentaryLufs(self: *const LoudnessMeter) f32 {
        return self.max_momentary;
    }

    /// Gated integrated loudness (absolute gate -70 LUFS, relative gate -10 LU), LUFS.
    pub fn integratedLufs(self: *const LoudnessMeter) f32 {
        var n: u64 = 0;
        var e: f64 = 0.0;
        for (self.hist_count, self.hist_energy) |c, s| {
            n += c;
            e += s;
        }
        if (n == 0) return MIN_DB;
        const gate = lufs(e / @as(f64, @floatFromInt(n))) - 10.0;

        var n2: u64 = 0;
        var e2: f64 = 0.0;
        for (self.hist_count, self.hist_energy, 0..) |c, s, i| {
            const center = HIST_MIN + (@as(f32, @floatFromInt(i)) + 0.5) * HIST_STEP;
            if (center > gate) {
                n2 += c;
                e2 += s;
            }
        }
        if (n2 == 0) return MIN_DB;
        return lufs(e2 / @as(f64, @floatFromInt(n2)));
    }

    /// Maximum true peak (4x oversampled) in dBTP.
    pub fn truePeakDb(self: *const LoudnessMeter) f32 {
        return db.gainToDb(self.true_peak);
    }
};

// --- tests ---
//
// Ported from the Rust `#[cfg(test)] mod tests` of meter.rs and from the offline_meters.rs
// tests named in the task. Fixed seeds and the Rust expected values are kept unchanged.

/// Deterministic xorshift noise in [-amp, amp], as the Rust test helper.
fn noise(gpa: std.mem.Allocator, len: usize, seed: u64, amp: f32) ![]f32 {
    const out = try gpa.alloc(f32, len);
    var x: u64 = (seed *% 0x9E37_79B9_7F4A_7C15) | 1;
    for (out) |*v| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        const u: f32 = @floatFromInt(x >> 40);
        v.* = (u / @as(f32, @floatFromInt(@as(u64, 1) << 24)) * 2.0 - 1.0) * amp;
    }
    return out;
}

/// `amp * sin(TAU * freq * i / sr)`, as the Rust test helper.
fn sine(gpa: std.mem.Allocator, freq: f32, amp: f32, sr: f32, len: usize) ![]f32 {
    const out = try gpa.alloc(f32, len);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(std.math.tau * freq * @as(f32, @floatFromInt(i)) / sr);
    }
    return out;
}

/// True peak as first written: the history shifted every sample, each phase summed on its own.
fn truePeakReference(coefs: *const [TP_TAPS][TP_PHASES]f32, x: []const f32) f32 {
    var h = std.mem.zeroes([TP_TAPS]f32);
    var tp: f32 = 0.0;
    for (x) |raw| {
        const v: f32 = if (std.math.isFinite(raw)) raw else 0.0;
        var k: usize = TP_TAPS - 1;
        while (k > 0) : (k -= 1) h[k] = h[k - 1];
        h[0] = v;
        var peak = @abs(v);
        var p: usize = 0;
        while (p < TP_PHASES) : (p += 1) {
            var y: f32 = 0.0;
            for (coefs, h) |c, b| y += c[p] * b;
            peak = rustMax(peak, @abs(y));
        }
        if (peak > tp) tp = peak;
    }
    return tp;
}

test "true_peak_matches_the_shifted_history" {
    const gpa = testing.allocator;
    const sr: f32 = 48_000.0;
    const len: usize = 20_000;

    const n1 = try noise(gpa, len, 1, 0.3);
    defer gpa.free(n1);
    const l = try gpa.alloc(f32, len);
    defer gpa.free(l);
    for (l, 0..) |*v, i| {
        v.* = 0.6 * @sin(@as(f32, std.math.tau) * 0.25 * @as(f32, @floatFromInt(i)) + 0.7) + n1[i];
    }
    const r = try noise(gpa, len, 2, 0.9);
    defer gpa.free(r);
    l[123] = std.math.nan(f32);
    l[4_567] = std.math.inf(f32);

    for ([_]usize{ 1, 7, 480, len }) |block| {
        var m = try LoudnessMeter.init(gpa, sr, 2);
        defer m.deinit(gpa);
        const want = @max(truePeakReference(&m.tp_coefs, l), truePeakReference(&m.tp_coefs, r));
        var at: usize = 0;
        while (at < len) : (at += block) {
            const n = @min(block, len - at);
            const chunk = [_][]const f32{ l[at .. at + n], r[at .. at + n] };
            m.process(&chunk, n);
        }
        try testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(m.true_peak)));

        m.reset();
        const quiet = try noise(gpa, 500, 3, 0.1);
        defer gpa.free(quiet);
        const quiet_chunk = [_][]const f32{ quiet, quiet };
        m.process(&quiet_chunk, 500);
        try testing.expectEqual(
            @as(u32, @bitCast(truePeakReference(&m.tp_coefs, quiet))),
            @as(u32, @bitCast(m.true_peak)),
        );
    }
}

test "loudness_997hz_minus20_stereo_reads_minus20" {
    const gpa = testing.allocator;
    const sr: f32 = 48_000.0;
    const x = try sine(gpa, 997.0, db.dbToGain(-20.0), sr, 48_000 * 10);
    defer gpa.free(x);
    var m = try LoudnessMeter.init(gpa, sr, 2);
    defer m.deinit(gpa);
    const io = [_][]const f32{ x, x };
    m.process(&io, 48_000 * 10);
    try testing.expectApproxEqAbs(@as(f32, -20.0), m.integratedLufs(), 0.1);
    try testing.expectApproxEqAbs(@as(f32, -20.0), m.momentaryLufs(), 0.1);
    try testing.expectApproxEqAbs(@as(f32, -20.0), m.shortTermLufs(), 0.1);
    try testing.expectApproxEqAbs(@as(f32, -20.0), m.truePeakDb(), 0.2);
}

test "loudness_full_scale_mono_and_44k" {
    const gpa = testing.allocator;
    const rates = [_]f32{ 44_100.0, 48_000.0, 96_000.0 };
    for (rates) |sr| {
        const len: usize = @intFromFloat(sr * 5.0);
        const x = try sine(gpa, 997.0, 1.0, sr, len);
        defer gpa.free(x);
        var m = try LoudnessMeter.init(gpa, sr, 1);
        defer m.deinit(gpa);
        const io = [_][]const f32{x};
        m.process(&io, len);
        try testing.expectApproxEqAbs(@as(f32, -3.01), m.integratedLufs(), 0.1);
    }
}

test "loudness_stays_bounded_at_low_sample_rates" {
    // The K-weighting shelf corner (~1.7 kHz) sits at or above Nyquist below ~3.4 kHz; the
    // filter must stay stable there instead of reading hundreds of LUFS (issue #240).
    const gpa = testing.allocator;
    const rates = [_]f32{ 1000.0, 1200.0, 1600.0, 2000.0, 3000.0, 3400.0, 8000.0, 48_000.0 };
    for (rates) |sr| {
        const len: usize = @intFromFloat(sr);
        const x = try sine(gpa, 100.0, 0.5, sr, len);
        defer gpa.free(x);
        var m = try LoudnessMeter.init(gpa, sr, 1);
        defer m.deinit(gpa);
        try testing.expectEqual(sr, m.sampleRate());
        const io = [_][]const f32{x};
        m.process(&io, len);
        const levels = [_]f32{ m.integratedLufs(), m.momentaryLufs(), m.shortTermLufs() };
        for (levels) |level| {
            try testing.expect(std.math.isFinite(level) and level >= -30.0 and level <= 0.0);
        }
    }
}

test "loudness_gating_ignores_silence" {
    const gpa = testing.allocator;
    const sr: f32 = 48_000.0;
    const tone_len: usize = 48_000 * 5;
    const total: usize = 48_000 * 25;

    const tone = try sine(gpa, 997.0, db.dbToGain(-20.0), sr, tone_len);
    defer gpa.free(tone);
    const x = try gpa.alloc(f32, total);
    defer gpa.free(x);
    @memcpy(x[0..tone_len], tone);
    @memset(x[tone_len..], 0.0);

    var m = try LoudnessMeter.init(gpa, sr, 2);
    defer m.deinit(gpa);
    const io = [_][]const f32{ x, x };
    m.process(&io, total);
    try testing.expectApproxEqAbs(@as(f32, -20.0), m.integratedLufs(), 0.2);
    try testing.expect(m.momentaryLufs() < -100.0);
    m.reset();
    try testing.expectEqual(@as(f32, -144.0), m.integratedLufs());
}

test "true_peak_catches_intersample_overs" {
    // A sine at fs/4 phased 45 degrees has samples at +-0.707*A but true peak A.
    const gpa = testing.allocator;
    const sr: f32 = 48_000.0;
    const x = try gpa.alloc(f32, 48_000);
    defer gpa.free(x);
    for (x, 0..) |*v, i| {
        const phase = @as(f32, @floatFromInt(i % 4));
        v.* = @sin(@as(f32, std.math.tau) * 0.25 * phase + std.math.tau / 8.0);
    }
    var peak: f32 = 0.0;
    for (x) |v| peak = rustMax(peak, @abs(v));
    try testing.expect(peak < 0.71);

    var m = try LoudnessMeter.init(gpa, sr, 1);
    defer m.deinit(gpa);
    const io = [_][]const f32{x};
    m.process(&io, 48_000);
    try testing.expect(m.truePeakDb() > -0.5);
}

test "peak_meter_ballistics" {
    const gpa = testing.allocator;
    var m = PeakMeter.init(48_000.0);

    const half: [480]f32 = @splat(0.5);
    m.process(&half);
    try testing.expectApproxEqAbs(@as(f32, -6.02), m.levelDb(), 0.01);

    const zeros = try gpa.alloc(f32, 48_000);
    defer gpa.free(zeros);
    @memset(zeros, 0.0);
    m.process(zeros);
    try testing.expectApproxEqAbs(@as(f32, -6.02 - 20.0), m.levelDb(), 0.1);
    try testing.expectApproxEqAbs(@as(f32, -6.02), m.peakHoldDb(), 0.01);
    try testing.expect(!m.clipped());

    const one = [_]f32{1.0};
    m.process(&one);
    try testing.expect(m.clipped());
    m.resetClip();
    try testing.expect(!m.clipped());

    const tone = try sine(gpa, 1000.0, 1.0, 48_000.0, 48_000);
    defer gpa.free(tone);
    var r = RmsMeter.init(48_000.0);
    r.process(tone);
    try testing.expectApproxEqAbs(@as(f32, -3.01), r.rmsDb(), 0.2);
}

/// Counts every call into the wrapped allocator, so a test can prove that a code path asks for
/// no memory at all. Test-only; `core` will provide the shared counting allocator.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    calls: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "loudness_process_and_peak_feed_never_allocate" {
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();
    const sr: f32 = 48_000.0;

    var m = try LoudnessMeter.init(gpa, sr, 6);
    defer m.deinit(gpa);
    var peak = PeakMeter.init(sr);
    var rms = RmsMeter.init(sr);
    // The counter must see the allocations of init, or the check below proves nothing.
    try testing.expect(counting.calls > 0);
    const after_init = counting.calls;

    const block = [_]f32{ 0.25, -0.5, 0.75, -1.0 };
    const planes = [_][]const f32{ &block, &block, &block, &block, &block, &block };
    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        m.process(&planes, block.len);
        peak.process(&block);
        peak.feed(0.5, 480);
        rms.process(&block);
    }
    _ = m.integratedLufs();
    _ = m.momentaryLufs();
    m.setChannelWeight(4, 1.5);
    m.reset();

    try testing.expectEqual(after_init, counting.calls);
}

test "loudness_results_do_not_depend_on_block_size" {
    const gpa = testing.allocator;
    const sr: f32 = 48_000.0;
    const len: usize = 96_000;

    const n1 = try noise(gpa, len, 1, 0.3);
    defer gpa.free(n1);
    const n2 = try noise(gpa, len, 2, 0.2);
    defer gpa.free(n2);
    const tone_l = try sine(gpa, 997.0, 0.5, sr, len);
    defer gpa.free(tone_l);
    const tone_r = try sine(gpa, 11_025.0, 0.7, sr, len);
    defer gpa.free(tone_r);

    const l = try gpa.alloc(f32, len);
    defer gpa.free(l);
    const r = try gpa.alloc(f32, len);
    defer gpa.free(r);
    for (0..len) |i| {
        l[i] = tone_l[i] + n1[i];
        r[i] = tone_r[i] + n2[i];
    }

    const whole = try runLoudnessBlocks(gpa, sr, l, r, len);
    for ([_]usize{ 1, 7, 37, 480, 1024, 4096, 4801 }) |block| {
        const got = try runLoudnessBlocks(gpa, sr, l, r, block);
        try testing.expectEqualSlices(u32, &whole, &got);
    }

    // Values pinned by the Rust test `loudness_and_true_peak_do_not_depend_on_block_size`
    // (bit patterns of the Rust f32 results, compared within 1e-3 dB).
    const pin_lufs: f32 = @bitCast(@as(u32, 3_215_227_935));
    const pin_true_peak: f32 = @bitCast(@as(u32, 3_162_870_746));
    const got_lufs: f32 = @bitCast(whole[0]);
    const got_true_peak: f32 = @bitCast(whole[4]);
    try testing.expect(@abs(got_lufs - pin_lufs) < 1e-3);
    try testing.expect(@abs(got_true_peak - pin_true_peak) < 1e-3);
}

test "PeakMeter.process ignores non-finite samples at any length" {
    // Ported from the Rust `peak_skips_non_finite_samples_at_any_length`, applied to the peak meter.
    const gpa = testing.allocator;
    var len: usize = 0;
    while (len < 40) : (len += 1) {
        const x = try noise(gpa, len, len + 3, 0.9);
        defer gpa.free(x);
        if (len > 3) {
            x[1] = std.math.nan(f32);
            x[len - 1] = std.math.inf(f32);
            x[len / 2] = -std.math.inf(f32);
        }
        var naive: f32 = 0.0;
        for (x) |v| {
            if (std.math.isFinite(v)) naive = @max(naive, @abs(v));
        }
        var m = PeakMeter.init(48_000.0);
        m.process(x);
        try testing.expectEqual(db.gainToDb(naive), m.levelDb());
        try testing.expect(!m.clipped());
    }
}

/// Runs a stereo meter over the input in blocks of `block` frames and returns the output bits
/// (integrated, momentary, short-term, max momentary, true peak).
fn runLoudnessBlocks(gpa: std.mem.Allocator, sr: f32, l: []const f32, r: []const f32, block: usize) ![5]u32 {
    var m = try LoudnessMeter.init(gpa, sr, 2);
    defer m.deinit(gpa);
    var at: usize = 0;
    while (at < l.len) : (at += block) {
        const n = @min(block, l.len - at);
        const chunk = [_][]const f32{ l[at .. at + n], r[at .. at + n] };
        m.process(&chunk, n);
    }
    return .{
        @bitCast(m.integratedLufs()),
        @bitCast(m.momentaryLufs()),
        @bitCast(m.shortTermLufs()),
        @bitCast(m.maxMomentaryLufs()),
        @bitCast(m.truePeakDb()),
    };
}
