// Translated to Zig from pitchpure/crates/pitchpure_engine/src/compressor.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Feed-forward vocal compressor with a soft knee.
//!
//! Per sample (continuous state, so block size never matters):
//!
//! 1. Level: instantaneous peak `|x|` in dBFS.
//! 2. Gain computer (`gainReductionDb`): unity below the knee, the
//!    `1/ratio` slope above it, and a quadratic blend across a knee of
//!    `knee_db` centred on the threshold.
//! 3. The wanted reduction is smoothed in dB with separate attack and
//!    release one-poles (attack when reduction deepens, release when it
//!    eases), so the gain never steps.
//! 4. Makeup gain, then a parallel blend: `dry * (1 - mix) + wet * mix`.
//!
//! Ratio 1 with 0 dB makeup is a bit-exact passthrough (the applied gain is
//! exactly 1.0). No lookahead, no latency, no allocation.

const std = @import("std");
const types = @import("types.zig");
/// This file, so methods can reach the free `gainReductionDb` they shadow.
const compressor = @This();

/// `ln(10) / 20`: dB to natural-log gain.
const DB_TO_LN: f32 = std.math.ln10 / 20.0;

/// Static curve: how many dB (<= 0) the compressor takes off a signal at
/// `level_db`. Shared with the UI so the drawn curve is the real one.
pub fn gainReductionDb(level_db: f32, threshold_db: f32, ratio_in: f32, knee_db: f32) f32 {
    const ratio = @max(ratio_in, 1.0);
    const over = level_db - threshold_db;
    const slope = 1.0 / ratio - 1.0;
    if (knee_db > 0.0 and @abs(over) <= knee_db / 2.0) {
        const k = over + knee_db / 2.0;
        return slope * k * k / (2.0 * knee_db);
    } else if (over > 0.0) {
        return slope * over;
    } else {
        return 0.0;
    }
}

/// Soft-knee vocal compressor. Holds no heap memory.
pub const VocalCompressor = struct {
    sample_rate: f32,
    threshold_db: f32,
    ratio: f32,
    knee_db: f32,
    attack_ms: f32,
    release_ms: f32,
    makeup_db: f32,
    mix: f32,
    attack_coef: f32,
    release_coef: f32,
    /// Smoothed reduction currently applied, dB (<= 0).
    reduction_db: f32,
    /// Smoothed input peak for metering, dBFS.
    level_db: f32,
    meter_coef: f32,

    /// Compressor for `sample_rate` with gentle vocal defaults: -18 dB
    /// threshold, 3:1, 6 dB knee, 10 ms attack, 120 ms release.
    pub fn init(sample_rate: types.SampleRateHz) VocalCompressor {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        var comp: VocalCompressor = .{
            .sample_rate = sr,
            .threshold_db = -18.0,
            .ratio = 3.0,
            .knee_db = 6.0,
            .attack_ms = 10.0,
            .release_ms = 120.0,
            .makeup_db = 0.0,
            .mix = 1.0,
            .attack_coef = 0.0,
            .release_coef = 0.0,
            .reduction_db = 0.0,
            .level_db = -120.0,
            .meter_coef = onePole(0.05, sr),
        };
        comp.setAttackMs(10.0);
        comp.setReleaseMs(120.0);
        return comp;
    }

    /// Threshold in dBFS, clamped to `-60..=0`.
    pub fn setThresholdDb(self: *VocalCompressor, db: f32) void {
        self.threshold_db = std.math.clamp(finiteOr(db, -18.0), -60.0, 0.0);
    }

    /// Ratio, clamped to `1..=20`.
    pub fn setRatio(self: *VocalCompressor, ratio: f32) void {
        self.ratio = std.math.clamp(finiteOr(ratio, 3.0), 1.0, 20.0);
    }

    /// Knee width in dB, clamped to `0..=24`.
    pub fn setKneeDb(self: *VocalCompressor, db: f32) void {
        self.knee_db = std.math.clamp(finiteOr(db, 6.0), 0.0, 24.0);
    }

    /// Attack time in ms, clamped to `0.1..=100`.
    pub fn setAttackMs(self: *VocalCompressor, ms: f32) void {
        self.attack_ms = std.math.clamp(finiteOr(ms, 10.0), 0.1, 100.0);
        self.attack_coef = onePole(self.attack_ms / 1000.0, self.sample_rate);
    }

    /// Release time in ms, clamped to `10..=2000`.
    pub fn setReleaseMs(self: *VocalCompressor, ms: f32) void {
        self.release_ms = std.math.clamp(finiteOr(ms, 120.0), 10.0, 2000.0);
        self.release_coef = onePole(self.release_ms / 1000.0, self.sample_rate);
    }

    /// Makeup gain in dB, clamped to `0..=24`.
    pub fn setMakeupDb(self: *VocalCompressor, db: f32) void {
        self.makeup_db = std.math.clamp(finiteOr(db, 0.0), 0.0, 24.0);
    }

    /// Parallel blend `0..=1` (1 = fully compressed).
    pub fn setMix(self: *VocalCompressor, mix: f32) void {
        self.mix = std.math.clamp(finiteOr(mix, 1.0), 0.0, 1.0);
    }

    /// Reduction currently applied, dB (<= 0), for metering.
    pub fn gainReductionDb(self: *const VocalCompressor) f32 {
        return self.reduction_db;
    }

    /// Smoothed input peak, dBFS, for metering.
    pub fn inputLevelDb(self: *const VocalCompressor) f32 {
        return self.level_db;
    }

    pub fn reset(self: *VocalCompressor) void {
        self.reduction_db = 0.0;
        self.level_db = -120.0;
    }

    /// Processes `min(input.len, output.len)` samples.
    pub fn process(self: *VocalCompressor, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        for (input[0..n], output[0..n]) |x, *y| {
            const s: f32 = if (std.math.isFinite(x)) x else 0.0;
            const level = 20.0 * @log10(@max(@abs(s), 1e-6));
            const peak = @max(level, self.level_db);
            self.level_db = peak + (level - peak) * self.meter_coef;
            const want = compressor.gainReductionDb(level, self.threshold_db, self.ratio, self.knee_db);
            const coef = if (want < self.reduction_db) self.attack_coef else self.release_coef;
            self.reduction_db += (want - self.reduction_db) * coef;
            if (@abs(self.reduction_db) < 1e-9) self.reduction_db = 0.0;
            const gain_db = self.reduction_db + self.makeup_db;
            const gain: f32 = if (gain_db == 0.0) 1.0 else @exp(gain_db * DB_TO_LN);
            const wet = s * gain;
            y.* = if (self.mix >= 1.0) wet else s + (wet - s) * self.mix;
        }
    }
};

comptime {
    types.assertProcessor(VocalCompressor);
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

fn testSine(gpa: std.mem.Allocator, amp: f32, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(2.0 * std.math.pi * 220.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    return out;
}

fn testPeak(x: []const f32) f32 {
    var a: f32 = 0.0;
    for (x) |s| a = @max(a, @abs(s));
    return a;
}

test "curve_is_unity_below_and_ratio_above" {
    try testing.expectEqual(@as(f32, 0.0), gainReductionDb(-40.0, -20.0, 4.0, 0.0));
    // 20 dB over at 4:1 -> 5 dB out -> 15 dB reduction.
    try testing.expect(@abs(gainReductionDb(0.0, -20.0, 4.0, 0.0) + 15.0) < 1e-4);
    try testing.expectEqual(@as(f32, 0.0), gainReductionDb(0.0, -20.0, 1.0, 6.0));
}

test "knee_is_continuous_at_both_edges" {
    const t: f32 = -20.0;
    const r: f32 = 4.0;
    const k: f32 = 10.0;
    for ([_]f32{ t - k / 2.0, t + k / 2.0 }) |edge| {
        const below = gainReductionDb(edge - 1e-3, t, r, k);
        const above = gainReductionDb(edge + 1e-3, t, r, k);
        try testing.expect(@abs(below - above) < 1e-2);
    }
    // knee starts reducing before threshold
    try testing.expect(gainReductionDb(t, t, r, k) < 0.0);
}

test "ratio_one_is_bit_exact_passthrough" {
    const gpa = testing.allocator;
    var c = VocalCompressor.init(SR);
    c.setRatio(1.0);
    const x = try testSine(gpa, 0.9, 4800);
    defer gpa.free(x);
    const y = try gpa.alloc(f32, x.len);
    defer gpa.free(y);
    @memset(y, 0.0);
    c.process(x, y);
    try testing.expectEqualSlices(f32, x, y);
}

test "loud_signal_settles_near_static_curve" {
    const gpa = testing.allocator;
    var c = VocalCompressor.init(SR);
    c.setThresholdDb(-20.0);
    c.setRatio(4.0);
    c.setKneeDb(0.0);
    c.setAttackMs(1.0);
    c.setReleaseMs(50.0);
    const x = try testSine(gpa, 1.0, SR);
    defer gpa.free(x);
    const y = try gpa.alloc(f32, x.len);
    defer gpa.free(y);
    @memset(y, 0.0);
    c.process(x, y);
    const tail = y[y.len - 4800 ..];
    const out_db = 20.0 * @log10(testPeak(tail));
    // 20 dB over a -20 dB threshold at 4:1 leaves 5 dB over: -15 dBFS.
    try testing.expect(out_db >= -16.0 and out_db <= -13.5);
    try testing.expect(c.gainReductionDb() < -10.0);
}

test "quiet_signal_is_untouched_and_mix_blends" {
    const gpa = testing.allocator;
    var c = VocalCompressor.init(SR);
    c.setThresholdDb(-10.0);
    c.setKneeDb(0.0);
    const x = try testSine(gpa, 0.05, 4800);
    defer gpa.free(x);
    const y = try gpa.alloc(f32, x.len);
    defer gpa.free(y);
    @memset(y, 0.0);
    c.process(x, y);
    try testing.expectEqualSlices(f32, x, y);

    c = VocalCompressor.init(SR);
    c.setThresholdDb(-40.0);
    c.setRatio(20.0);
    c.setMix(0.0);
    const loud = try testSine(gpa, 0.8, 4800);
    defer gpa.free(loud);
    const z = try gpa.alloc(f32, loud.len);
    defer gpa.free(z);
    @memset(z, 0.0);
    c.process(loud, z);
    // mix 0 is fully dry
    try testing.expectEqualSlices(f32, loud, z);
}

fn runBlocks(gpa: std.mem.Allocator, x: []const f32, block: usize) ![]f32 {
    var c = VocalCompressor.init(SR);
    c.setThresholdDb(-24.0);
    c.setMakeupDb(6.0);
    const y = try gpa.alloc(f32, x.len);
    @memset(y, 0.0);
    var start: usize = 0;
    while (start < x.len) : (start += block) {
        const end = @min(start + block, x.len);
        c.process(x[start..end], y[start..end]);
    }
    return y;
}

test "block_size_does_not_change_output" {
    const gpa = testing.allocator;
    const x = try testSine(gpa, 0.9, 9600);
    defer gpa.free(x);
    const a = try runBlocks(gpa, x, 64);
    defer gpa.free(a);
    const b = try runBlocks(gpa, x, 1000);
    defer gpa.free(b);
    try testing.expectEqualSlices(f32, a, b);
}
