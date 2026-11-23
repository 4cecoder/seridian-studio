// Translated to Zig from pitchpure/crates/pitchpure_engine/src/detector_acf.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Autocorrelation (ACF) fundamental-frequency estimator.
//!
//! Textbook implementation from first principles: biased normalized
//! autocorrelation (each lag normalized by the lag-0 energy), peak search
//! over the lag range implied by `min_hz..max_hz`, parabolic interpolation
//! of the chosen peak, and an octave guard that prefers the smallest
//! qualifying peak. See `AcfDetector`.
//!
//! Seridian: the Rust version allocated the correlation buffer on every
//! `estimate` call. Here it is preallocated in `init` (its size,
//! `tau_max + 1`, depends only on the configuration), so `estimate` never
//! allocates.

const std = @import("std");
const types = @import("types.zig");
const DetectorReading = types.DetectorReading;

/// RMS level below which the input counts as silence.
const silence_rms: f32 = 1e-6;

/// Minimum normalized correlation required to report a pitch.
const min_corr: f32 = 0.3;

/// Octave-guard fraction: the chosen peak must reach this fraction of the
/// global maximum. Prefers the smallest qualifying lag to fight octave-down
/// errors.
const octave_fraction: f64 = 0.5;

/// Rust `f64 as usize`: truncates toward zero, saturates, NaN maps to 0.
fn floatToUsizeSat(x: f64) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// Normalized-autocorrelation pitch detector.
///
/// Searches lags corresponding to `min_hz..max_hz`, picks the smallest
/// correlation peak reaching half the global maximum, and refines it with
/// parabolic interpolation. Stateless apart from its configuration and a
/// preallocated scratch buffer (free it with `deinit`).
pub const AcfDetector = struct {
    sample_rate: u32,
    min_hz: f32,
    max_hz: f32,
    /// Correlation scratch, `tau_max + 1` long (empty when the configuration
    /// is invalid).
    corr: []f64,

    /// Create a detector for `sample_rate` searching `min_hz..max_hz`.
    ///
    /// Invalid ranges are not rejected here; `estimate` returns null when
    /// the range is invalid. Allocates `round(sample_rate / min_hz) + 1`
    /// doubles.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, min_hz: f32, max_hz: f32) error{OutOfMemory}!AcfDetector {
        var scratch_len: usize = 0;
        if (sample_rate != 0 and std.math.isFinite(min_hz) and std.math.isFinite(max_hz) and
            min_hz > 0.0 and max_hz > min_hz)
        {
            const sr: f64 = @floatFromInt(sample_rate);
            const tau_max = floatToUsizeSat(@round(sr / @as(f64, min_hz)));
            scratch_len = std.math.add(usize, tau_max, 1) catch return error.OutOfMemory;
        }
        const corr = try gpa.alloc(f64, scratch_len);
        return .{
            .sample_rate = sample_rate,
            .min_hz = min_hz,
            .max_hz = max_hz,
            .corr = corr,
        };
    }

    pub fn deinit(self: *AcfDetector, gpa: std.mem.Allocator) void {
        gpa.free(self.corr);
        self.* = undefined;
    }

    /// Estimate the fundamental of `frame`.
    ///
    /// Returns null when the input is silent (RMS below `1e-6`), too
    /// short to cover the longest lag, has an invalid configuration, or
    /// when the best normalized correlation is below `0.3`. Otherwise
    /// returns the interpolated frequency with `confidence` set to the
    /// peak correlation clamped to `0..=1`. Never allocates.
    pub fn estimate(self: *AcfDetector, frame: []const f32) ?DetectorReading {
        if (self.sample_rate == 0) return null;
        if (!std.math.isFinite(self.min_hz) or !std.math.isFinite(self.max_hz)) return null;
        if (self.min_hz <= 0.0 or self.max_hz <= self.min_hz) return null;
        const n = frame.len;
        if (n < 4) return null;
        const level = types.rms(frame);
        if (!std.math.isFinite(level) or level < silence_rms) return null;

        const sr: f64 = @floatFromInt(self.sample_rate);
        const tau_min = @max(floatToUsizeSat(@round(sr / @as(f64, self.max_hz))), 1);
        const tau_max = floatToUsizeSat(@round(sr / @as(f64, self.min_hz)));
        if (tau_max < 2 or tau_min >= tau_max) return null;
        if (n <= tau_max) return null;

        var energy: f64 = 0.0;
        for (frame) |s| {
            const v: f64 = s;
            energy += v * v;
        }
        if (!std.math.isFinite(energy) or energy <= 0.0) return null;

        // Seridian: preallocated, Rust allocated here.
        const corr = self.corr[0 .. tau_max + 1];
        corr[0] = 1.0;
        var lag: usize = 1;
        while (lag <= tau_max) : (lag += 1) {
            var acc: f64 = 0.0;
            for (0..n - lag) |i| {
                acc += @as(f64, frame[i]) * @as(f64, frame[i + lag]);
            }
            corr[lag] = acc / energy;
        }

        var best_lag = tau_min;
        var best_val = corr[tau_min];
        lag = tau_min + 1;
        while (lag <= tau_max) : (lag += 1) {
            if (corr[lag] > best_val) {
                best_val = corr[lag];
                best_lag = lag;
            }
        }
        if (!std.math.isFinite(best_val) or best_val < @as(f64, min_corr)) return null;

        const thresh = best_val * octave_fraction;
        var chosen = best_lag;
        lag = tau_min;
        while (lag < tau_max) : (lag += 1) {
            const c = corr[lag];
            if (c >= thresh and c >= corr[lag - 1] and c >= corr[lag + 1] and
                (c > corr[lag - 1] or c > corr[lag + 1]))
            {
                chosen = lag;
                break;
            }
        }
        const peak = corr[chosen];
        if (!std.math.isFinite(peak) or peak < @as(f64, min_corr)) return null;

        var period: f64 = @floatFromInt(chosen);
        if (chosen > 0 and chosen < tau_max) {
            const y0 = corr[chosen - 1];
            const y1 = corr[chosen];
            const y2 = corr[chosen + 1];
            const denom = y0 - 2.0 * y1 + y2;
            if (denom != 0.0 and std.math.isFinite(denom)) {
                const shift = std.math.clamp(0.5 * (y0 - y2) / denom, -0.5, 0.5);
                if (std.math.isFinite(shift)) period += shift;
            }
        }
        if (!std.math.isFinite(period) or period <= 0.0) return null;
        const freq: f32 = @floatCast(sr / period);
        if (!std.math.isFinite(freq) or freq <= 0.0) return null;
        const confidence = std.math.clamp(@as(f32, @floatCast(peak)), 0.0, 1.0);
        if (confidence < min_corr) return null;
        return .{ .freq_hz = freq, .confidence = confidence };
    }
};

fn sine(gpa: std.mem.Allocator, freq_hz: f32, len: usize) ![]f32 {
    const out = try gpa.alloc(f32, len);
    for (out, 0..) |*s, i| {
        s.* = @sin(std.math.tau * freq_hz * @as(f32, @floatFromInt(i)) / 44100.0) * 0.5;
    }
    return out;
}

test "finds_440hz_sine" {
    const gpa = std.testing.allocator;
    const frame = try sine(gpa, 440.0, 4096);
    defer gpa.free(frame);
    var detector = try AcfDetector.init(gpa, 44100, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.MustDetect440Hz;
    try std.testing.expect(@abs(reading.freq_hz - 440.0) <= 4.0);
    try std.testing.expect(reading.confidence >= 0.0 and reading.confidence <= 1.0);
    try std.testing.expect(reading.confidence >= 0.3);
}

test "octave_guard_rejects_half_frequency" {
    const gpa = std.testing.allocator;
    const frame = try sine(gpa, 220.0, 4096);
    defer gpa.free(frame);
    var detector = try AcfDetector.init(gpa, 44100, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.MustDetect220Hz;
    try std.testing.expect(@abs(reading.freq_hz - 220.0) <= 4.0);
    try std.testing.expect(@abs(reading.freq_hz - 110.0) > 30.0);
}

test "silence_returns_none" {
    const gpa = std.testing.allocator;
    var detector = try AcfDetector.init(gpa, 44100, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const zeros: [4096]f32 = @splat(0.0);
    const tiny: [4096]f32 = @splat(1e-8);
    try std.testing.expect(detector.estimate(&zeros) == null);
    try std.testing.expect(detector.estimate(&tiny) == null);
}

test "short_frame_returns_none" {
    const gpa = std.testing.allocator;
    var detector = try AcfDetector.init(gpa, 44100, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const half: [8]f32 = @splat(0.5);
    try std.testing.expect(detector.estimate(&.{}) == null);
    try std.testing.expect(detector.estimate(&half) == null);
}
