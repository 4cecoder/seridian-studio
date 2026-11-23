// Translated to Zig from pitchpure/crates/pitchpure_engine/src/types.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Shared contracts for the vocal engine. Every stage speaks these types.
//!
//! Rust's `Processor` trait becomes a duck-typed contract: a stage is a struct
//! with `reset(*Self) void`, `process(*Self, input: []const f32, output: []f32) void`
//! and optionally `latencySamples(*const Self) usize` (0 when absent).
//! `assertProcessor` checks the contract at comptime.

const std = @import("std");

/// Sample rate in Hz. All stages assume a fixed rate for their lifetime.
pub const SampleRateHz = u32;

/// Comptime check that `T` implements the Processor contract.
pub fn assertProcessor(comptime T: type) void {
    if (!@hasDecl(T, "reset")) @compileError(@typeName(T) ++ " is missing reset");
    if (!@hasDecl(T, "process")) @compileError(@typeName(T) ++ " is missing process");
}

/// Algorithmic delay in samples of any Processor (0 if it declares none).
pub fn latencySamples(p: anytype) usize {
    const T = @TypeOf(p.*);
    if (@hasDecl(T, "latencySamples")) return p.latencySamples();
    return 0;
}

/// A single pitch estimate from any detector stage.
pub const DetectorReading = struct {
    /// Estimated fundamental in Hz.
    freq_hz: f32,
    /// 0.0 (noise) ..= 1.0 (pure periodic).
    confidence: f32,
};

/// MIDI note number (69.0 = A440) to frequency in Hz.
pub fn midiToHz(midi: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (midi - 69.0) / 12.0);
}

/// Frequency in Hz to fractional MIDI note number. Null for hz <= 0.
pub fn hzToMidi(hz: f32) ?f32 {
    if (hz > 0.0) return 69.0 + 12.0 * std.math.log2(hz / 440.0);
    return null;
}

/// Cents offset to frequency ratio.
pub fn centsToRatio(cents: f32) f32 {
    return std.math.pow(f32, 2.0, cents / 1200.0);
}

/// Root-mean-square level of a frame. 0.0 for empty input.
pub fn rms(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (samples) |s| sum += s * s;
    return @sqrt(sum / @as(f32, @floatFromInt(samples.len)));
}

test "midi and hz round trip" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), midiToHz(69.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), hzToMidi(midiToHz(60.0)).?, 1e-4);
    try std.testing.expect(hzToMidi(0.0) == null);
    try std.testing.expect(hzToMidi(-1.0) == null);
}

test "cents to ratio" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), centsToRatio(1200.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), centsToRatio(0.0), 1e-6);
}

test "rms" {
    try std.testing.expectEqual(@as(f32, 0.0), rms(&.{}));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rms(&.{ 1.0, -1.0, 1.0, -1.0 }), 1e-6);
}
