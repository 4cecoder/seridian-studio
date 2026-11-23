// Translated to Zig from pitchpure/crates/pitchpure_engine/src/detector_yin.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! YIN fundamental-frequency estimator, from first principles.
//!
//! Implements the classic YIN algorithm (squared-difference function,
//! cumulative mean normalisation, absolute threshold with walk to the
//! local minimum, parabolic interpolation) over a lag range derived
//! from the configured frequency bounds.
//!
//! Seridian: the Rust version allocated the difference and CMND buffers on
//! every `estimate` call. Here they are preallocated in `init` (their size,
//! `max_lag + 1`, depends only on the configuration), so `estimate` never
//! allocates.

const std = @import("std");
const types = @import("types.zig");
const DetectorReading = types.DetectorReading;

/// Absolute CMND threshold below which a lag counts as a periodic dip.
const threshold: f32 = 0.10;

/// Minimum RMS level below which a frame counts as silence.
const silence_rms: f32 = 1e-6;

/// Rust `f32 as usize`: truncates toward zero, saturates, NaN maps to 0.
fn floatToUsizeSat(x: f32) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// YIN pitch detector.
///
/// Operates on one monophonic frame at a time. Construct once with
/// `init`, then call `estimate` per frame. Owns two scratch buffers of
/// `max_lag + 1` samples; free them with `deinit`.
pub const YinDetector = struct {
    sample_rate: u32,
    min_hz: f32,
    max_hz: f32,
    /// Squared-difference scratch, `max_lag + 1` long (empty when the
    /// configuration is invalid).
    diff: []f32,
    /// Cumulative-mean-normalised difference scratch, same length as `diff`.
    cmnd: []f32,

    /// Create a detector for the given sample rate and search range.
    ///
    /// `min_hz` must be greater than zero and less than `max_hz`;
    /// invalid ranges are stored as-is and cause `estimate` to return null.
    /// Allocates `2 * (ceil(sample_rate / min_hz) + 1)` floats.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, min_hz: f32, max_hz: f32) error{OutOfMemory}!YinDetector {
        var scratch_len: usize = 0;
        if (sample_rate != 0 and min_hz > 0.0 and max_hz > min_hz) {
            const max_lag = floatToUsizeSat(@ceil(@as(f32, @floatFromInt(sample_rate)) / min_hz));
            scratch_len = std.math.add(usize, max_lag, 1) catch return error.OutOfMemory;
        }
        const diff = try gpa.alloc(f32, scratch_len);
        errdefer gpa.free(diff);
        const cmnd = try gpa.alloc(f32, scratch_len);
        return .{
            .sample_rate = sample_rate,
            .min_hz = min_hz,
            .max_hz = max_hz,
            .diff = diff,
            .cmnd = cmnd,
        };
    }

    pub fn deinit(self: *YinDetector, gpa: std.mem.Allocator) void {
        gpa.free(self.diff);
        gpa.free(self.cmnd);
        self.* = undefined;
    }

    /// Estimate the fundamental of `frame`.
    ///
    /// Returns null when the frame is silent (`rms < 1e-6`), when the
    /// frame is too short to cover the lag of `min_hz`, or when no
    /// cumulative-mean-normalised dip falls below the 0.10 threshold.
    /// Otherwise returns the interpolated frequency with
    /// `confidence = 1 - cmnd`, clamped to `0..=1`. Never allocates.
    pub fn estimate(self: *YinDetector, frame: []const f32) ?DetectorReading {
        if (self.sample_rate == 0) return null;
        if (!(self.min_hz > 0.0) or !(self.max_hz > self.min_hz)) return null;
        if (frame.len == 0) return null;
        if (types.rms(frame) < silence_rms) return null;

        const rate: f32 = @floatFromInt(self.sample_rate);
        var min_lag = floatToUsizeSat(@floor(rate / self.max_hz));
        const max_lag = floatToUsizeSat(@ceil(rate / self.min_hz));
        if (min_lag < 1) min_lag = 1;
        if (max_lag <= min_lag) return null;
        if (frame.len <= max_lag) return null;

        // Seridian: preallocated, Rust allocated here.
        const diff = self.diff[0 .. max_lag + 1];
        const cmnd = self.cmnd[0 .. max_lag + 1];

        diff[0] = 0.0;
        var tau: usize = 1;
        while (tau <= max_lag) : (tau += 1) {
            var sum: f32 = 0.0;
            const limit = frame.len - tau;
            for (0..limit) |j| {
                const d = frame[j] - frame[j + tau];
                sum += d * d;
            }
            diff[tau] = sum;
        }

        @memset(cmnd, 1.0);
        cmnd[0] = 1.0;
        var running_sum: f32 = 0.0;
        tau = 1;
        while (tau <= max_lag) : (tau += 1) {
            running_sum += diff[tau];
            if (running_sum == 0.0) {
                cmnd[tau] = 1.0;
            } else {
                cmnd[tau] = diff[tau] * @as(f32, @floatFromInt(tau)) / running_sum;
            }
        }

        var chosen: ?usize = null;
        tau = min_lag;
        while (tau <= max_lag) {
            if (cmnd[tau] < threshold) {
                while (tau + 1 <= max_lag and cmnd[tau + 1] < cmnd[tau]) {
                    tau += 1;
                }
                chosen = tau;
                break;
            }
            tau += 1;
        }
        const best = chosen orelse return null;

        var refined: f32 = @floatFromInt(best);
        if (best > 0 and best < max_lag) {
            const y0 = cmnd[best - 1];
            const y1 = cmnd[best];
            const y2 = cmnd[best + 1];
            const denom = y0 - 2.0 * y1 + y2;
            if (denom != 0.0 and std.math.isFinite(denom)) {
                const shift = 0.5 * (y0 - y2) / denom;
                if (std.math.isFinite(shift)) {
                    refined = @as(f32, @floatFromInt(best)) + std.math.clamp(shift, -1.0, 1.0);
                }
            }
        }
        if (!(refined > 0.0) or !std.math.isFinite(refined)) return null;
        const freq_hz = rate / refined;
        if (!std.math.isFinite(freq_hz) or !(freq_hz > 0.0)) return null;

        const confidence = std.math.clamp(1.0 - cmnd[best], 0.0, 1.0);
        return .{ .freq_hz = freq_hz, .confidence = confidence };
    }
};

fn sineFrame(gpa: std.mem.Allocator, freq_hz: f32, sample_rate: u32, len: usize) ![]f32 {
    const out = try gpa.alloc(f32, len);
    const rate: f32 = @floatFromInt(sample_rate);
    for (out, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / rate);
    }
    return out;
}

test "finds_440hz_with_high_confidence" {
    const gpa = std.testing.allocator;
    const frame = try sineFrame(gpa, 440.0, 44100, 4096);
    defer gpa.free(frame);
    var detector = try YinDetector.init(gpa, 44100, 50.0, 1000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.ShouldDetect440Hz;
    try std.testing.expect(@abs(reading.freq_hz - 440.0) <= 2.0);
    try std.testing.expect(reading.confidence > 0.9);
}

test "silence_returns_none" {
    const gpa = std.testing.allocator;
    const frame: [4096]f32 = @splat(0.0);
    var detector = try YinDetector.init(gpa, 44100, 50.0, 1000.0);
    defer detector.deinit(gpa);
    try std.testing.expect(detector.estimate(&frame) == null);
}

test "finds_220hz" {
    const gpa = std.testing.allocator;
    const frame = try sineFrame(gpa, 220.0, 44100, 4096);
    defer gpa.free(frame);
    var detector = try YinDetector.init(gpa, 44100, 50.0, 1000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.ShouldDetect220Hz;
    try std.testing.expect(@abs(reading.freq_hz - 220.0) <= 2.0);
}
