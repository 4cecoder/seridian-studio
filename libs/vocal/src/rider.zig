// Translated to Zig from pitchpure/crates/pitchpure_engine/src/rider.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Automatic vocal level riding: a slow "fader engineer" that nudges gain
//! toward a target loudness.
//!
//! Detector: mean-square one-pole follower with a ~300 ms time constant,
//! read in dB. The wanted gain is `target - level`, clamped to `+-range`.
//! The applied gain glides toward it with a one-pole whose time constant
//! is set by `speed` (2 s slow .. 0.15 s fast), so phrases are levelled
//! without compressor-style pumping.
//!
//! Silence gate: when the detected level drops below `GATE_DB` the gain
//! is frozen, so the rider never cranks up room noise between phrases.
//!
//! Everything runs per sample with continuous state, so any block size
//! gives identical output. `range == 0` yields a bit-exact passthrough
//! (gain is exactly 1.0). No allocation.

const std = @import("std");
const types = @import("types.zig");

/// Detector time constant in seconds.
const DETECT_TAU_S: f32 = 0.3;
/// Below this detected level (dBFS RMS) the gain holds still.
const GATE_DB: f32 = -50.0;
/// Gain glide time constant at `speed = 0` and `speed = 1`.
const SLOW_TAU_S: f32 = 2.0;
const FAST_TAU_S: f32 = 0.15;
/// `ln(10) / 20`: dB to natural-log gain.
const DB_TO_LN: f32 = std.math.ln10 / 20.0;

/// Automatic gain rider toward a target level. Holds no heap memory.
pub const VocalRider = struct {
    sample_rate: f32,
    target_db: f32,
    range_db: f32,
    speed_value: f32,
    detect_coef: f32,
    glide_coef: f32,
    mean_square: f32,
    gain_db: f32,

    /// Rider for `sample_rate` with defaults: target -18 dBFS, +-6 dB range,
    /// medium speed.
    pub fn init(sample_rate: types.SampleRateHz) VocalRider {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        var rider: VocalRider = .{
            .sample_rate = sr,
            .target_db = -18.0,
            .range_db = 6.0,
            .speed_value = 0.5,
            .detect_coef = onePole(DETECT_TAU_S, sr),
            .glide_coef = 0.0,
            .mean_square = 0.0,
            .gain_db = 0.0,
        };
        rider.setSpeed(0.5);
        return rider;
    }

    /// Target RMS level in dBFS, clamped to `-30..=-6`.
    pub fn setTargetDb(self: *VocalRider, db: f32) void {
        self.target_db = std.math.clamp(finiteOr(db, -18.0), -30.0, -6.0);
    }

    /// Maximum boost/cut in dB, clamped to `0..=12`.
    pub fn setRangeDb(self: *VocalRider, db: f32) void {
        self.range_db = std.math.clamp(finiteOr(db, 6.0), 0.0, 12.0);
    }

    /// Ride speed `0..=1` (0 = slow and gentle, 1 = quick).
    pub fn setSpeed(self: *VocalRider, new_speed: f32) void {
        self.speed_value = std.math.clamp(finiteOr(new_speed, 0.5), 0.0, 1.0);
        const tau = SLOW_TAU_S + (FAST_TAU_S - SLOW_TAU_S) * self.speed_value;
        self.glide_coef = onePole(tau, self.sample_rate);
    }

    /// Gain currently applied, in dB (for metering).
    pub fn gainDb(self: *const VocalRider) f32 {
        return self.gain_db;
    }

    pub fn targetDb(self: *const VocalRider) f32 {
        return self.target_db;
    }

    pub fn rangeDb(self: *const VocalRider) f32 {
        return self.range_db;
    }

    pub fn speed(self: *const VocalRider) f32 {
        return self.speed_value;
    }

    pub fn reset(self: *VocalRider) void {
        self.mean_square = 0.0;
        self.gain_db = 0.0;
    }

    /// Processes `min(input.len, output.len)` samples.
    pub fn process(self: *VocalRider, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        for (input[0..n], output[0..n]) |x, *y| {
            const s: f32 = if (std.math.isFinite(x)) x else 0.0;
            self.mean_square += (s * s - self.mean_square) * self.detect_coef;
            self.mean_square = flush(self.mean_square);
            const level_db = 10.0 * @log10(@max(self.mean_square, 1e-12));
            if (level_db > GATE_DB) {
                const want = std.math.clamp(self.target_db - level_db, -self.range_db, self.range_db);
                self.gain_db += (want - self.gain_db) * self.glide_coef;
            }
            self.gain_db = std.math.clamp(self.gain_db, -self.range_db, self.range_db);
            const gain: f32 = if (self.gain_db == 0.0) 1.0 else @exp(self.gain_db * DB_TO_LN);
            // As in the Rust: the raw (possibly non-finite) input is scaled.
            y.* = x * gain;
        }
    }
};

comptime {
    types.assertProcessor(VocalRider);
}

/// One-pole smoothing coefficient for time constant `tau_s`.
fn onePole(tau_s: f32, sample_rate: f32) f32 {
    return 1.0 - @exp(-1.0 / (@max(tau_s, 1e-4) * sample_rate));
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

/// Flush denormal-range values to zero.
fn flush(v: f32) f32 {
    return if (@abs(v) < 1e-20) 0.0 else v;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const SR: u32 = 48_000;

fn testSine(gpa: std.mem.Allocator, amp: f32, hz: f32, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(std.math.tau * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    return out;
}

fn run(gpa: std.mem.Allocator, rider: *VocalRider, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var start: usize = 0;
    while (start < input.len) : (start += block) {
        const end = @min(start + block, input.len);
        rider.process(input[start..end], out[start..end]);
    }
    return out;
}

test "quiet_voice_is_raised_within_range" {
    const gpa = testing.allocator;
    var rider = VocalRider.init(SR);
    // RMS -30 dBFS = 12 dB under the -18 target.
    const amp = std.math.pow(f32, 10.0, -30.0 / 20.0) * std.math.sqrt2;
    const x = try testSine(gpa, amp, 220.0, SR * 6);
    defer gpa.free(x);
    gpa.free(try run(gpa, &rider, x, 512));
    try testing.expect(rider.gainDb() >= 4.0);
    try testing.expect(rider.gainDb() <= 6.0 + 1e-4);
}

test "loud_voice_is_lowered" {
    const gpa = testing.allocator;
    var rider = VocalRider.init(SR);
    const amp = std.math.pow(f32, 10.0, -8.0 / 20.0) * std.math.sqrt2;
    const x = try testSine(gpa, amp, 220.0, SR * 6);
    defer gpa.free(x);
    gpa.free(try run(gpa, &rider, x, 512));
    try testing.expect(rider.gainDb() <= -4.0);
}

test "silence_does_not_raise_gain" {
    const gpa = testing.allocator;
    var rider = VocalRider.init(SR);
    const quiet = try gpa.alloc(f32, SR * 4);
    defer gpa.free(quiet);
    @memset(quiet, 1e-5);
    gpa.free(try run(gpa, &rider, quiet, 1024));
    try testing.expectEqual(@as(f32, 0.0), rider.gainDb());
}

test "zero_range_is_bit_exact" {
    const gpa = testing.allocator;
    var rider = VocalRider.init(SR);
    rider.setRangeDb(0.0);
    const input = try testSine(gpa, 0.01, 330.0, 20_000);
    defer gpa.free(input);
    const out = try run(gpa, &rider, input, 333);
    defer gpa.free(out);
    try testing.expectEqualSlices(f32, input, out);
}

test "block_sizes_match" {
    const gpa = testing.allocator;
    const input = try testSine(gpa, 0.02, 200.0, 30_000);
    defer gpa.free(input);
    for (input, 0..) |*s, i| {
        if (i > 15_000) s.* = s.* * 8.0;
    }
    var ref_rider = VocalRider.init(SR);
    const reference = try run(gpa, &ref_rider, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var rider = VocalRider.init(SR);
        const got = try run(gpa, &rider, input, block);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, reference, got);
    }
}

test "silence_after_burst_stays_clean" {
    const gpa = testing.allocator;
    var rider = VocalRider.init(SR);
    const burst = try testSine(gpa, 0.5, 300.0, 10_000);
    defer gpa.free(burst);
    const input = try gpa.alloc(f32, 10_000 + SR * 10);
    defer gpa.free(input);
    @memset(input, 0.0);
    @memcpy(input[0..10_000], burst);
    const out = try run(gpa, &rider, input, 512);
    defer gpa.free(out);
    for (out) |s| {
        try testing.expect(std.math.isFinite(s) and (s == 0.0 or @abs(s) >= std.math.floatMin(f32)));
    }
}

test "bench_cpu" {
    // Rust marks this #[ignore] (benchmark that only prints a timing, run
    // with --ignored --nocapture). Libraries must not print, so it is skipped.
    return error.SkipZigTest;
}
