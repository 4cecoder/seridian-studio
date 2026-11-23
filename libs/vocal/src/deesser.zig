// Translated to Zig from pitchpure/crates/pitchpure_engine/src/deesser.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Split-band de-esser: turns down only the sibilant top end, and only
//! while an "s" is happening.
//!
//! Per sample (continuous state, so block size never matters):
//!
//! 1. Split: a 2-pole low-pass at `frequency_hz` gives `low`; the high band
//!    is `x - low`, so `low + high` rebuilds the input exactly.
//! 2. Detector: peak follower (1 ms attack, 60 ms release) on a separate
//!    2-pole high-pass at the same frequency, which rejects the low voice
//!    far better than the subtractive split does.
//! 3. Reduction: everything the detector reads above `threshold_db` is
//!    taken off the high band, limited to `range_db`, then smoothed.
//! 4. Output `low + high * gain`, or the detector band alone while
//!    `listen` is on (to hear exactly what is being caught).
//!
//! With no reduction the output equals the input to float rounding.
//! Zero latency, no allocation.

const std = @import("std");
const types = @import("types.zig");

/// `ln(10) / 20`: dB to natural-log gain.
const DB_TO_LN: f32 = std.math.ln10 / 20.0;
const ATTACK_S: f32 = 0.001;
const RELEASE_S: f32 = 0.06;
/// Smoothing of the applied reduction, so it never zippers.
const GAIN_S: f32 = 0.002;

/// Split-band sibilance reducer. Holds no heap memory.
pub const VocalDeEsser = struct {
    sample_rate: f32,
    frequency_hz_value: f32,
    threshold_db: f32,
    range_db: f32,
    listen: bool,
    // Low-pass split and high-pass detector biquads (transposed direct
    // form II); both share the denominator.
    b0: f32,
    b1: f32,
    b2: f32,
    hb0: f32,
    hb1: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,
    hz1: f32,
    hz2: f32,
    env: f32,
    reduction_db: f32,
    attack_coef: f32,
    release_coef: f32,
    gain_coef: f32,

    /// De-esser for `sample_rate`: 6.5 kHz split, -30 dB threshold, up to
    /// 8 dB of reduction.
    pub fn init(sample_rate: types.SampleRateHz) VocalDeEsser {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        var d: VocalDeEsser = .{
            .sample_rate = sr,
            .frequency_hz_value = 6500.0,
            .threshold_db = -30.0,
            .range_db = 8.0,
            .listen = false,
            .b0 = 1.0,
            .b1 = 0.0,
            .b2 = 0.0,
            .hb0 = 0.0,
            .hb1 = 0.0,
            .a1 = 0.0,
            .a2 = 0.0,
            .z1 = 0.0,
            .z2 = 0.0,
            .hz1 = 0.0,
            .hz2 = 0.0,
            .env = 0.0,
            .reduction_db = 0.0,
            .attack_coef = onePole(ATTACK_S, sr),
            .release_coef = onePole(RELEASE_S, sr),
            .gain_coef = onePole(GAIN_S, sr),
        };
        d.setFrequencyHz(6500.0);
        return d;
    }

    /// Split frequency in Hz, clamped to `2000..=12000` (and below Nyquist).
    pub fn setFrequencyHz(self: *VocalDeEsser, hz: f32) void {
        const nyq = self.sample_rate * 0.45;
        self.frequency_hz_value = @min(std.math.clamp(finiteOr(hz, 6500.0), 2000.0, 12_000.0), nyq);
        // RBJ low-pass, Q = 1/sqrt(2).
        const w = 2.0 * std.math.pi * self.frequency_hz_value / self.sample_rate;
        const sin = @sin(w);
        const cos = @cos(w);
        const alpha = sin / (2.0 * @as(f32, std.math.sqrt1_2));
        const a0 = 1.0 + alpha;
        self.b0 = (1.0 - cos) / 2.0 / a0;
        self.b1 = (1.0 - cos) / a0;
        self.b2 = self.b0;
        self.hb0 = (1.0 + cos) / 2.0 / a0;
        self.hb1 = -(1.0 + cos) / a0;
        self.a1 = -2.0 * cos / a0;
        self.a2 = (1.0 - alpha) / a0;
    }

    /// Level above which sibilance is reduced, dBFS, clamped to `-60..=0`.
    pub fn setThresholdDb(self: *VocalDeEsser, db: f32) void {
        self.threshold_db = std.math.clamp(finiteOr(db, -30.0), -60.0, 0.0);
    }

    /// Most reduction allowed, dB, clamped to `0..=24`.
    pub fn setRangeDb(self: *VocalDeEsser, db: f32) void {
        self.range_db = std.math.clamp(finiteOr(db, 8.0), 0.0, 24.0);
    }

    /// Output only the high band, to audition what is caught.
    pub fn setListen(self: *VocalDeEsser, on: bool) void {
        self.listen = on;
    }

    pub fn frequencyHz(self: *const VocalDeEsser) f32 {
        return self.frequency_hz_value;
    }

    /// Reduction currently applied to the high band, dB (<= 0).
    pub fn gainReductionDb(self: *const VocalDeEsser) f32 {
        return self.reduction_db;
    }

    /// Detected high-band level, dBFS, for metering.
    pub fn sibilanceDb(self: *const VocalDeEsser) f32 {
        return 20.0 * @log10(@max(self.env, 1e-6));
    }

    pub fn reset(self: *VocalDeEsser) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
        self.hz1 = 0.0;
        self.hz2 = 0.0;
        self.env = 0.0;
        self.reduction_db = 0.0;
    }

    /// Processes `min(input.len, output.len)` samples.
    pub fn process(self: *VocalDeEsser, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        for (input[0..n], output[0..n]) |x, *y| {
            const s: f32 = if (std.math.isFinite(x)) x else 0.0;
            const low = self.b0 * s + self.z1;
            self.z1 = self.b1 * s - self.a1 * low + self.z2;
            self.z2 = self.b2 * s - self.a2 * low;
            const high = s - low;
            const detect = self.hb0 * s + self.hz1;
            self.hz1 = self.hb1 * s - self.a1 * detect + self.hz2;
            self.hz2 = self.hb0 * s - self.a2 * detect;
            const mag = @abs(detect);
            const coef = if (mag > self.env) self.attack_coef else self.release_coef;
            self.env += (mag - self.env) * coef;
            if (self.env < 1e-12) self.env = 0.0;
            const level = 20.0 * @log10(@max(self.env, 1e-6));
            const want = std.math.clamp(self.threshold_db - level, -self.range_db, 0.0);
            self.reduction_db += (want - self.reduction_db) * self.gain_coef;
            if (@abs(self.reduction_db) < 1e-9) self.reduction_db = 0.0;
            const gain: f32 = if (self.reduction_db == 0.0) 1.0 else @exp(self.reduction_db * DB_TO_LN);
            y.* = if (self.listen) detect * gain else low + high * gain;
        }
    }
};

comptime {
    types.assertProcessor(VocalDeEsser);
}

/// One-pole smoothing coefficient for time constant `tau_s`.
fn onePole(tau_s: f32, sample_rate: f32) f32 {
    return 1.0 - @exp(-1.0 / (@max(tau_s, 1e-5) * sample_rate));
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const SR: u32 = 48_000;

fn testTone(gpa: std.mem.Allocator, hz: f32, amp: f32, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(2.0 * std.math.pi * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    return out;
}

fn testRms(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |s| sum += s * s;
    return @sqrt(sum / @as(f32, @floatFromInt(x.len)));
}

fn zeros(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const y = try gpa.alloc(f32, n);
    @memset(y, 0.0);
    return y;
}

test "quiet_input_rebuilds_exactly" {
    const gpa = testing.allocator;
    var d = VocalDeEsser.init(SR);
    d.setThresholdDb(0.0);
    const x = try testTone(gpa, 8000.0, 0.3, 4800);
    defer gpa.free(x);
    const y = try zeros(gpa, x.len);
    defer gpa.free(y);
    d.process(x, y);
    var err: f32 = 0.0;
    for (x, y) |p, q| err = @max(err, @abs(p - q));
    try testing.expect(err < 1e-5);
}

test "loud_sibilance_is_reduced_but_lows_are_not" {
    const gpa = testing.allocator;
    const n: usize = SR / 2;
    var d = VocalDeEsser.init(SR);
    d.setThresholdDb(-30.0);
    d.setRangeDb(10.0);
    const hiss = try testTone(gpa, 9000.0, 0.5, n);
    defer gpa.free(hiss);
    const y = try zeros(gpa, n);
    defer gpa.free(y);
    d.process(hiss, y);
    const drop = 20.0 * @log10(testRms(y[n / 2 ..]) / testRms(hiss[n / 2 ..]));
    try testing.expect(drop < -6.0);
    try testing.expect(d.gainReductionDb() <= -6.0);

    d = VocalDeEsser.init(SR);
    d.setThresholdDb(-30.0);
    const voice = try testTone(gpa, 200.0, 0.5, n);
    defer gpa.free(voice);
    const z = try zeros(gpa, n);
    defer gpa.free(z);
    d.process(voice, z);
    const drop2 = 20.0 * @log10(testRms(z[n / 2 ..]) / testRms(voice[n / 2 ..]));
    try testing.expect(@abs(drop2) < 0.3);
}

test "listen_outputs_only_the_high_band" {
    const gpa = testing.allocator;
    const n: usize = SR / 4;
    var d = VocalDeEsser.init(SR);
    d.setListen(true);
    d.setThresholdDb(0.0);
    const low = try testTone(gpa, 150.0, 0.5, n);
    defer gpa.free(low);
    const y = try zeros(gpa, n);
    defer gpa.free(y);
    d.process(low, y);
    try testing.expect(testRms(y[n / 2 ..]) < 0.01 * testRms(low[n / 2 ..]));
}

fn runBlocks(gpa: std.mem.Allocator, x: []const f32, block: usize) ![]f32 {
    var d = VocalDeEsser.init(SR);
    const y = try zeros(gpa, x.len);
    var start: usize = 0;
    while (start < x.len) : (start += block) {
        const end = @min(start + block, x.len);
        d.process(x[start..end], y[start..end]);
    }
    return y;
}

test "block_size_does_not_change_output" {
    const gpa = testing.allocator;
    const x = try testTone(gpa, 7000.0, 0.7, 9600);
    defer gpa.free(x);
    const a = try runBlocks(gpa, x, 32);
    defer gpa.free(a);
    const b = try runBlocks(gpa, x, 777);
    defer gpa.free(b);
    try testing.expectEqualSlices(f32, a, b);
}
