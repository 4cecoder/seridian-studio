// Translated to Zig from pitchpure/crates/pitchpure_engine/src/slew.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Exponential pitch-glide (slew) limiter, domain-agnostic.
//!
//! `SlewLimiter` smooths abrupt per-sample jumps, typically semitone offsets
//! from the retune brain, with a one-pole lowpass whose time constant equals
//! `retune_ms`. Any linear-domain signal (semitones, cents, Hertz) glides the
//! same way.
//!
//! Retune times at or below 0.5 ms snap instantly to the target, which keeps
//! hard-tune (`retune_ms == 0`) free of special-casing at call sites.

const std = @import("std");

/// One-pole exponential glide toward a per-sample target.
pub const SlewLimiter = struct {
    sample_rate: u32,
    retune_ms: f32,
    last: f32,

    /// Create a limiter for `sample_rate` with glide time `retune_ms` ms,
    /// clamped to `0..=1000`. A `sample_rate` of zero disables gliding.
    pub fn init(sample_rate: u32, retune_ms: f32) SlewLimiter {
        return .{
            .sample_rate = sample_rate,
            .retune_ms = std.math.clamp(retune_ms, 0.0, 1000.0),
            .last = 0.0,
        };
    }

    /// Set the glide time in milliseconds, clamped to `0..=1000`.
    /// Values at or below 0.5 ms engage snap mode.
    pub fn setRetuneMs(self: *SlewLimiter, ms: f32) void {
        self.retune_ms = std.math.clamp(ms, 0.0, 1000.0);
    }

    /// Record `value` as the most recent output. The glide math threads state
    /// through `current` in `next`, so this only reseeds the mirrored `last`.
    pub fn reset(self: *SlewLimiter, value: f32) void {
        self.last = value;
    }

    /// Advance one sample from `current` toward `target` and return it.
    /// Coefficient `1 - exp(-1 / tau)` with `tau = retune_ms * sample_rate / 1000`.
    /// Returns `target` unchanged in snap mode or when `sample_rate == 0`.
    pub fn next(self: *SlewLimiter, current: f32, target: f32) f32 {
        if (self.retune_ms <= 0.5 or self.sample_rate == 0) {
            self.last = target;
            return target;
        }
        const tau_samples = self.retune_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        const coeff = 1.0 - @exp(-1.0 / tau_samples);
        const out = current + (target - current) * coeff;
        self.last = out;
        return out;
    }
};

const testing = std.testing;

const rate: u32 = 44_100;
const target_st: f32 = 12.0;

fn drive(limiter: *SlewLimiter, samples: usize) f32 {
    var value: f32 = 0.0;
    for (0..samples) |_| value = limiter.next(value, target_st);
    return value;
}

fn expectedAfter(target: f32, samples: f32, tau_samples: f32) f32 {
    return target * (1.0 - @exp(-samples / tau_samples));
}

test "doctest: new" {
    var glide = SlewLimiter.init(44_100, 40.0);
    const v = glide.next(0.0, 12.0);
    try testing.expect(v > 0.0 and v < 12.0);
}

test "snap_mode_returns_target_immediately" {
    for ([_]f32{ 0.0, 0.25, 0.5 }) |ms| {
        var limiter = SlewLimiter.init(rate, ms);
        try testing.expectEqual(target_st, limiter.next(0.0, target_st));
        try testing.expectEqual(@as(f32, 7.25), limiter.next(-3.5, 7.25));
    }
}

test "negative_retune_clamps_to_snap" {
    var limiter = SlewLimiter.init(rate, -20.0);
    try testing.expectEqual(target_st, limiter.next(0.0, target_st));
    limiter.setRetuneMs(-1.0);
    try testing.expectEqual(target_st, limiter.next(0.0, target_st));
}

test "just_above_snap_threshold_glides" {
    var limiter = SlewLimiter.init(rate, 0.51);
    const step = limiter.next(0.0, target_st);
    try testing.expect(step > 0.0 and step < target_st);
}

test "zero_sample_rate_snaps" {
    var limiter = SlewLimiter.init(0, 40.0);
    try testing.expectEqual(target_st, limiter.next(0.0, target_st));
}

test "set_retune_ms_clamps_to_1000" {
    var limiter = SlewLimiter.init(rate, 40.0);
    limiter.setRetuneMs(5000.0);
    const tau: f32 = 1000.0 * @as(f32, @floatFromInt(rate)) / 1000.0;
    const expected = target_st * (1.0 - @exp(-1.0 / tau));
    try testing.expect(@abs(limiter.next(0.0, target_st) - expected) < 1e-7);
}

test "single_step_matches_one_pole_formula" {
    var limiter = SlewLimiter.init(rate, 40.0);
    const tau: f32 = 40.0 * @as(f32, @floatFromInt(rate)) / 1000.0;
    const expected = target_st * (1.0 - @exp(-1.0 / tau));
    try testing.expect(@abs(limiter.next(0.0, target_st) - expected) < 1e-6);
}

test "glide_40ms_follows_exponential_time_constant" {
    const tau: f32 = 1764.0;
    var limiter = SlewLimiter.init(rate, 40.0);
    var prev: f32 = 0.0;
    var value: f32 = 0.0;
    for (0..1764) |_| {
        value = limiter.next(value, target_st);
        try testing.expect(value >= prev);
        try testing.expect(value <= target_st);
        prev = value;
    }
    try testing.expect(@abs(value - expectedAfter(target_st, 1764.0, tau)) < 0.05);
    for (1764..8820) |_| {
        value = limiter.next(value, target_st);
        try testing.expect(value >= prev);
        prev = value;
    }
    try testing.expect(@abs(value - expectedAfter(target_st, 8820.0, tau)) < 0.05);
    try testing.expect((target_st - value) < 0.15);
}

test "glide_settles_within_005_after_300ms" {
    var limiter = SlewLimiter.init(rate, 40.0);
    const value = drive(&limiter, 13_230);
    try testing.expect(@abs(target_st - value) < 0.05);
}

test "glide_1000ms_barely_moves_after_40ms" {
    var limiter = SlewLimiter.init(rate, 1000.0);
    const value = drive(&limiter, 1764);
    try testing.expect(value > 0.0);
    try testing.expect(value < 1.0);
}

test "reset_reseeds_last_without_changing_glide_math" {
    var fresh = SlewLimiter.init(rate, 40.0);
    var reset = SlewLimiter.init(rate, 40.0);
    reset.reset(3.0);
    try testing.expectEqual(fresh.next(0.0, target_st), reset.next(0.0, target_st));
}
