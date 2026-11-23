// Translated to Zig from pitchpure/crates/pitchpure_engine/src/detector_mpm.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! McLeod Pitch Method (MPM) detector, clean-room from first principles.
//!
//! Pipeline per frame: normalized square difference function (NSDF),
//! local-peak picking with parabolic interpolation, then octave-cost
//! key-maximum selection. `freq = sample_rate / period` of the key peak
//! and `confidence` is the key peak height clamped to `0..=1`.
//!
//! Seridian: the Rust version resized its NSDF buffer to the frame length
//! and collected peaks into a `Vec` on every call. Only lags `0..=hi + 1`
//! (with `hi <= floor(sample_rate / min_hz)`) are ever read, so the NSDF
//! scratch is preallocated in `init` to `floor(sample_rate / min_hz) + 2`
//! and only that prefix is computed (each NSDF value is independent, so
//! the result is bit-identical). The peak list is replaced by two passes
//! over the same deterministic peak computation. `estimate` never
//! allocates.

const std = @import("std");
const types = @import("types.zig");
const DetectorReading = types.DetectorReading;

/// Octave-cost factor: the key maximum is the first (lowest-lag) peak
/// whose height is at least `k_cutoff` times the global maximum peak.
/// Preferring the leftmost strong peak rejects octave-down errors.
const k_cutoff: f32 = 0.85;

/// Minimum NSDF peak height accepted as a confident pitch.
/// Below this `MpmDetector.estimate` returns null.
const confidence_threshold: f32 = 0.3;

/// Silence gate: frames quieter than this RMS report null.
const silence_rms: f32 = 1e-6;

/// Rust `f32 as usize`: truncates toward zero, saturates, NaN maps to 0.
fn floatToUsizeSat(x: f32) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// One interpolated NSDF local maximum.
const Peak = struct {
    /// Refined lag in samples (may be fractional).
    period: f32,
    /// Refined NSDF value at the peak.
    height: f32,
};

/// The accepted peak at integer lag `i`, if `nsdf` has one there.
/// Requires `1 <= i` and `i + 1 < nsdf.len`.
fn peakAt(nsdf: []const f32, i: usize) ?Peak {
    if (!(nsdf[i - 1] < nsdf[i] and nsdf[i] >= nsdf[i + 1])) return null;
    const y0 = nsdf[i - 1];
    const y1 = nsdf[i];
    const y2 = nsdf[i + 1];
    const denom = y0 - 2.0 * y1 + y2;
    var period: f32 = @floatFromInt(i);
    var height: f32 = y1;
    if (@abs(denom) > 1e-12) {
        const shift = std.math.clamp(0.5 * (y0 - y2) / denom, -0.5, 0.5);
        period = @as(f32, @floatFromInt(i)) + shift;
        height = y1 - 0.25 * (y0 - y2) * shift;
    }
    if (period > 0.0 and std.math.isFinite(height)) return .{ .period = period, .height = height };
    return null;
}

/// McLeod Pitch Method fundamental-frequency estimator.
///
/// Construct once with `init`, then call `estimate` per frame. Holds a
/// reusable NSDF scratch buffer so repeated calls do not reallocate; free it
/// with `deinit`.
pub const MpmDetector = struct {
    sample_rate: u32,
    min_hz: f32,
    max_hz: f32,
    /// NSDF scratch, `floor(sample_rate / min_hz) + 2` long (empty when the
    /// configuration is invalid).
    nsdf: []f32,

    /// Create a detector for `sample_rate` searching `min_hz..=max_hz`.
    ///
    /// Bounds are stored as given; `estimate` returns null when they are
    /// non-finite or do not satisfy `0 < min_hz < max_hz`.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, min_hz: f32, max_hz: f32) error{OutOfMemory}!MpmDetector {
        var scratch_len: usize = 0;
        if (sample_rate != 0 and std.math.isFinite(min_hz) and std.math.isFinite(max_hz) and
            min_hz > 0.0 and max_hz > min_hz)
        {
            const max_period = @as(f32, @floatFromInt(sample_rate)) / min_hz;
            if (std.math.isFinite(max_period)) {
                scratch_len = std.math.add(usize, floatToUsizeSat(@floor(max_period)), 2) catch
                    return error.OutOfMemory;
            }
        }
        const nsdf = try gpa.alloc(f32, scratch_len);
        @memset(nsdf, 0.0);
        return .{
            .sample_rate = sample_rate,
            .min_hz = min_hz,
            .max_hz = max_hz,
            .nsdf = nsdf,
        };
    }

    pub fn deinit(self: *MpmDetector, gpa: std.mem.Allocator) void {
        gpa.free(self.nsdf);
        self.* = undefined;
    }

    /// Estimate the fundamental of `frame`.
    ///
    /// Returns null when the frame is silent (`rms < 1e-6`), too short
    /// to hold the search range, misconfigured, or when no NSDF peak
    /// reaches `confidence_threshold`. Never allocates.
    pub fn estimate(self: *MpmDetector, frame: []const f32) ?DetectorReading {
        const n = frame.len;
        if (n < 4 or self.sample_rate == 0) return null;
        if (!(std.math.isFinite(self.min_hz) and std.math.isFinite(self.max_hz)) or
            self.min_hz <= 0.0 or self.max_hz <= self.min_hz)
        {
            return null;
        }
        if (types.rms(frame) < silence_rms) return null;

        const rate: f32 = @floatFromInt(self.sample_rate);
        const min_period = rate / self.max_hz;
        const max_period = rate / self.min_hz;
        if (!(std.math.isFinite(min_period) and std.math.isFinite(max_period))) return null;

        // Search integer lags within [min_period, max_period], clamped so
        // every candidate has both neighbours for peak testing.
        var lo = floatToUsizeSat(@ceil(min_period));
        var hi = floatToUsizeSat(@floor(max_period));
        if (lo < 1) lo = 1;
        if (hi > n -| 2) hi = n -| 2;
        if (lo > hi) return null;

        // Seridian: preallocated, Rust allocated here. Only lags 0..=hi+1
        // are read below; hi + 1 < self.nsdf.len by construction.
        const nsdf = self.nsdf[0 .. hi + 2];
        for (nsdf, 0..) |*out, tau| {
            var num: f32 = 0.0;
            var den: f32 = 0.0;
            const bound = n - tau;
            for (0..bound) |j| {
                const a = frame[j];
                const b = frame[j + tau];
                num += a * b;
                den += a * a + b * b;
            }
            out.* = if (den > 1e-12) 2.0 * num / den else 0.0;
        }

        // Skip the trivial zero-lag peak: start past the first downward
        // zero crossing of the NSDF when one exists. A crossing past `hi`
        // never changes `lo`, so the scan stops at `hi`.
        var zero = hi + 1;
        for (1..hi + 1) |i| {
            if (nsdf[i] <= 0.0) {
                zero = i;
                break;
            }
        }
        if (zero <= hi and zero + 1 > lo) {
            lo = @min(zero + 1, hi + 1);
            if (lo > hi) return null;
        }

        // Seridian: the Rust collected peaks into a Vec; two passes instead.
        var any_peak = false;
        var max_height = -std.math.inf(f32);
        for (lo..hi + 1) |i| {
            if (peakAt(nsdf, i)) |p| {
                any_peak = true;
                max_height = @max(max_height, p.height);
            }
        }
        if (!any_peak) return null;
        if (!std.math.isFinite(max_height) or max_height < confidence_threshold) return null;

        const cutoff = k_cutoff * max_height;
        var key: ?Peak = null;
        for (lo..hi + 1) |i| {
            if (peakAt(nsdf, i)) |p| {
                if (p.height >= cutoff) {
                    key = p;
                    break;
                }
            }
        }
        const k = key orelse return null;
        if (k.height < confidence_threshold or k.period <= 0.0) return null;

        const freq = rate / k.period;
        if (!std.math.isFinite(freq) or freq <= 0.0) return null;
        return .{ .freq_hz = freq, .confidence = std.math.clamp(k.height, 0.0, 1.0) };
    }
};

fn sine(gpa: std.mem.Allocator, freq_hz: f32, sample_rate: u32, len: usize) ![]f32 {
    const rate: f32 = @floatFromInt(sample_rate);
    const out = try gpa.alloc(f32, len);
    for (out, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / rate);
    }
    return out;
}

test "detects_440hz_sine" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 44_100;
    const frame = try sine(gpa, 440.0, sample_rate, 4096);
    defer gpa.free(frame);
    var detector = try MpmDetector.init(gpa, sample_rate, 50.0, 1000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.MustDetect440Hz;
    try std.testing.expect(@abs(reading.freq_hz - 440.0) <= 3.0);
    try std.testing.expect(reading.confidence > 0.8);
}

test "detects_110hz_sine" {
    const gpa = std.testing.allocator;
    const sample_rate: u32 = 44_100;
    const frame = try sine(gpa, 110.0, sample_rate, 4096);
    defer gpa.free(frame);
    var detector = try MpmDetector.init(gpa, sample_rate, 50.0, 1000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(frame) orelse return error.MustDetect110Hz;
    try std.testing.expect(@abs(reading.freq_hz - 110.0) <= 3.0);
    try std.testing.expect(reading.confidence > 0.8);
}

test "silence_returns_none" {
    const gpa = std.testing.allocator;
    var detector = try MpmDetector.init(gpa, 44_100, 50.0, 1000.0);
    defer detector.deinit(gpa);
    const frame: [4096]f32 = @splat(0.0);
    try std.testing.expect(detector.estimate(&frame) == null);
}
