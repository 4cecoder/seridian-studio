// Translated to Zig from pitchpure/crates/pitchpure_engine/src/resampler.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Stateless linear and Catmull-Rom resamplers, clean-room from first principles.
//!
//! Both functions are pure and stateless: they work for any input length
//! and allocate only the returned slice (owned by the caller, free it with
//! the same allocator). They allocate, so call them off the audio thread.
//!
//! Ratio convention: `output.len == round(input.len / ratio)` and
//! `output[i] = input[i * ratio]` interpolated. A ratio greater than one
//! shortens the buffer (content plays back at a higher pitch when heard at
//! the same sample rate); a ratio between zero and one lengthens it.
//!
//! Seridian: the Rust functions panicked on empty input or a non-finite /
//! non-positive ratio; here they return `error.EmptyInput` and
//! `error.InvalidRatio`.

const std = @import("std");

pub const ResampleError = error{ EmptyInput, InvalidRatio, OutOfMemory };

/// Rust `f64 as usize`: truncates toward zero, saturates, NaN maps to 0.
fn f64ToUsizeSat(x: f64) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// Rust `f32 as usize`: truncates toward zero, saturates, NaN maps to 0.
fn f32ToUsizeSat(x: f32) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

fn checkArgs(input: []const f32, ratio: f32) ResampleError!usize {
    if (input.len == 0) return error.EmptyInput;
    if (!(std.math.isFinite(ratio) and ratio > 0.0)) return error.InvalidRatio;
    return f64ToUsizeSat(@round(@as(f64, @floatFromInt(input.len)) / @as(f64, ratio)));
}

/// Linearly interpolate `input` by `ratio`.
///
/// The output has `round(len / ratio)` samples where each sample is the
/// linear blend of the two surrounding input samples at position
/// `i * ratio`. Positions past the final sample clamp to the last value.
/// Errors on empty `input`, or if `ratio` is not finite and greater than
/// zero. Caller owns the result.
pub fn linearResample(gpa: std.mem.Allocator, input: []const f32, ratio: f32) ResampleError![]f32 {
    const out_len = try checkArgs(input, ratio);
    const output = try gpa.alloc(f32, out_len);
    const last = input.len - 1;
    for (output, 0..) |*o, i| {
        const pos = @as(f32, @floatFromInt(i)) * ratio;
        const idx = f32ToUsizeSat(@floor(pos));
        if (idx >= last) {
            o.* = input[last];
        } else {
            const frac = pos - @as(f32, @floatFromInt(idx));
            const low = input[idx];
            const high = input[idx + 1];
            o.* = low + (high - low) * frac;
        }
    }
    return output;
}

/// Resample `input` by `ratio` with Catmull-Rom cubic interpolation.
///
/// Same length and ratio contract as `linearResample`: the output has
/// `round(len / ratio)` samples at positions `i * ratio`. Each interior
/// position blends the four surrounding samples (`idx - 1 ..= idx + 2`)
/// with the uniform Catmull-Rom basis. Out-of-range neighbours clamp to
/// the nearest edge sample, and positions at or past the final sample
/// return the last value directly. Errors like `linearResample`. Caller
/// owns the result.
pub fn cubicResample(gpa: std.mem.Allocator, input: []const f32, ratio: f32) ResampleError![]f32 {
    const out_len = try checkArgs(input, ratio);
    const output = try gpa.alloc(f32, out_len);
    if (out_len == 0) return output;
    const last = input.len - 1;
    const last_pos: f32 = @floatFromInt(last);
    for (output, 0..) |*o, i| {
        const pos = @as(f32, @floatFromInt(i)) * ratio;
        if (pos >= last_pos) {
            o.* = input[last];
            continue;
        }
        const idx = f32ToUsizeSat(@floor(pos));
        const t = pos - @as(f32, @floatFromInt(idx));
        const idx_0 = idx -| 1;
        const idx_3 = @min(idx + 2, last);
        const p0 = input[idx_0];
        const p1 = input[idx];
        const p2 = input[idx + 1];
        const p3 = input[idx_3];
        const t2 = t * t;
        const t3 = t2 * t;
        o.* = 0.5 *
            ((2.0 * p1) +
                (-p0 + p2) * t +
                (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
                (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
    }
    return output;
}

const YinDetector = @import("detector_yin.zig").YinDetector;

fn sine(gpa: std.mem.Allocator, freq_hz: f32, sample_rate: u32, len: usize) ![]f32 {
    const rate: f32 = @floatFromInt(sample_rate);
    const out = try gpa.alloc(f32, len);
    for (out, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / rate);
    }
    return out;
}

fn rmsError(actual: []const f32, expected: []const f32) !f32 {
    try std.testing.expectEqual(expected.len, actual.len);
    var sum: f32 = 0.0;
    for (actual, expected) |a, b| {
        const d = a - b;
        sum += d * d;
    }
    return @sqrt(sum / @as(f32, @floatFromInt(actual.len)));
}

test "linear_identity_within_tolerance" {
    const gpa = std.testing.allocator;
    const input = try sine(gpa, 440.0, 44_100, 4096);
    defer gpa.free(input);
    const output = try linearResample(gpa, input, 1.0);
    defer gpa.free(output);
    try std.testing.expectEqual(input.len, output.len);
    for (output, input) |got, want| {
        try std.testing.expect(@abs(got - want) <= 1e-6);
    }
}

test "cubic_identity_within_tolerance" {
    const gpa = std.testing.allocator;
    const input = try sine(gpa, 440.0, 44_100, 4096);
    defer gpa.free(input);
    const output = try cubicResample(gpa, input, 1.0);
    defer gpa.free(output);
    try std.testing.expectEqual(input.len, output.len);
    for (output, input) |got, want| {
        try std.testing.expect(@abs(got - want) <= 1e-6);
    }
}

test "double_rate_halves_length_and_doubles_pitch" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 44_100;
    const input = try sine(gpa, 440.0, sample_rate, 8192);
    defer gpa.free(input);
    const output = try linearResample(gpa, input, 2.0);
    defer gpa.free(output);
    try std.testing.expectEqual(@as(usize, 4096), output.len);
    var detector = try YinDetector.init(gpa, sample_rate, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(output) orelse return error.Resampled880HzMustBeDetected;
    const relative = @abs(reading.freq_hz - 880.0) / 880.0;
    try std.testing.expect(relative <= 0.05);
}

test "cubic_double_rate_also_doubles_pitch" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 44_100;
    const input = try sine(gpa, 440.0, sample_rate, 8192);
    defer gpa.free(input);
    const output = try cubicResample(gpa, input, 2.0);
    defer gpa.free(output);
    try std.testing.expectEqual(@as(usize, 4096), output.len);
    var detector = try YinDetector.init(gpa, sample_rate, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(output) orelse return error.CubicResampled880HzMustBeDetected;
    const relative = @abs(reading.freq_hz - 880.0) / 880.0;
    try std.testing.expect(relative <= 0.05);
}

test "cubic_beats_linear_on_sine_at_1_37" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 44_100;
    const freq_hz: f32 = 440.0;
    const ratio: f32 = 1.37;
    const input = try sine(gpa, freq_hz, sample_rate, 8192);
    defer gpa.free(input);
    const linear = try linearResample(gpa, input, ratio);
    defer gpa.free(linear);
    const cubic = try cubicResample(gpa, input, ratio);
    defer gpa.free(cubic);
    const expected_len = f64ToUsizeSat(@round(@as(f64, @floatFromInt(input.len)) / @as(f64, ratio)));
    try std.testing.expectEqual(expected_len, linear.len);
    try std.testing.expectEqual(expected_len, cubic.len);
    const rate: f32 = @floatFromInt(sample_rate);
    const analytic = try gpa.alloc(f32, expected_len);
    defer gpa.free(analytic);
    for (analytic, 0..) |*a, i| {
        a.* = @sin(2.0 * std.math.pi * freq_hz * ratio * @as(f32, @floatFromInt(i)) / rate);
    }
    const linear_err = try rmsError(linear, analytic);
    const cubic_err = try rmsError(cubic, analytic);
    try std.testing.expect(cubic_err < linear_err);
}

// Rust #[should_panic] tests: the Zig functions return errors instead.
test "linear_empty_panics" {
    try std.testing.expectError(error.EmptyInput, linearResample(std.testing.allocator, &.{}, 1.0));
}

test "cubic_empty_panics" {
    try std.testing.expectError(error.EmptyInput, cubicResample(std.testing.allocator, &.{}, 1.0));
}

test "linear_nonpositive_ratio_panics" {
    try std.testing.expectError(error.InvalidRatio, linearResample(std.testing.allocator, &.{ 1.0, 2.0 }, 0.0));
}

test "cubic_nonpositive_ratio_panics" {
    try std.testing.expectError(error.InvalidRatio, cubicResample(std.testing.allocator, &.{ 1.0, 2.0 }, -1.0));
}
