// Translated to Zig from pitchpure/crates/pitchpure_engine/src/detector_track.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Multi-detector pitch tracker: fuses YIN, MPM, and ACF readings.
//!
//! Each frame is offered to all three estimators. Readings below the
//! confidence floor are discarded, agreeing survivors (within 3% of the
//! median) are fused by confidence-weighted mean, and the fused frequency
//! passes through a 5-frame median smoother. Brief dropouts hold the last
//! pitch with decaying confidence for up to 3 frames before reporting null.
//!
//! Seridian: the Rust version collected readings, frequencies and the
//! sorted median input into `Vec`s per frame. Here they live in fixed stack
//! arrays (at most 3 readings, at most 5 history entries), so `estimate`
//! never allocates. The detectors' scratch buffers are allocated in `init`.

const std = @import("std");
const types = @import("types.zig");
const DetectorReading = types.DetectorReading;
const AcfDetector = @import("detector_acf.zig").AcfDetector;
const MpmDetector = @import("detector_mpm.zig").MpmDetector;
const YinDetector = @import("detector_yin.zig").YinDetector;

/// Lower search bound handed to every inner detector, in Hz.
const min_hz: f32 = 55.0;
/// Upper search bound handed to every inner detector, in Hz.
const max_hz: f32 = 1200.0;
/// Minimum per-detector confidence kept for fusion.
const confidence_floor: f32 = 0.35;
/// Relative frequency tolerance around the median for fusion (3%).
const agree_tolerance: f32 = 0.03;
/// Length of the output median-smoothing window, in frames.
const smooth_len: usize = 5;
/// Held-pitch frames emitted during a dropout before giving up.
const max_misses: u32 = 3;
/// Per-frame confidence multiplier applied to the held pitch on a miss.
const hold_decay: f32 = 0.8;

/// A single smoothed, fused pitch estimate.
pub const TrackedPitch = struct {
    /// Estimated fundamental in Hz.
    freq_hz: f32,
    /// Mean of the fused detectors' confidences, 0.0..=1.0.
    /// Decays while holding through a dropout.
    confidence: f32,
};

/// Fuses `YinDetector`, `MpmDetector`, and `AcfDetector` into one stable
/// pitch stream.
///
/// Construct once with `init`, then call `estimate` per frame. Holds
/// detector scratch, a short frequency history for median smoothing, and
/// dropout-hold state; use `reset` to clear all of it. Free with `deinit`.
pub const PitchTracker = struct {
    sample_rate: u32,
    yin: YinDetector,
    mpm: MpmDetector,
    acf: AcfDetector,
    history_buf: [smooth_len]f32 = @splat(0.0),
    history_len: usize = 0,
    misses: u32 = 0,
    last: ?TrackedPitch = null,

    /// Create a tracker for `sample_rate` searching 55..1200 Hz internally.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32) error{OutOfMemory}!PitchTracker {
        var yin = try YinDetector.init(gpa, sample_rate, min_hz, max_hz);
        errdefer yin.deinit(gpa);
        var mpm = try MpmDetector.init(gpa, sample_rate, min_hz, max_hz);
        errdefer mpm.deinit(gpa);
        const acf = try AcfDetector.init(gpa, sample_rate, min_hz, max_hz);
        return .{ .sample_rate = sample_rate, .yin = yin, .mpm = mpm, .acf = acf };
    }

    pub fn deinit(self: *PitchTracker, gpa: std.mem.Allocator) void {
        self.yin.deinit(gpa);
        self.mpm.deinit(gpa);
        self.acf.deinit(gpa);
        self.* = undefined;
    }

    /// Clear smoothing history and dropout hold. The detectors keep no
    /// state between frames beyond scratch that every `estimate` fully
    /// rewrites before reading, so (unlike the Rust, which rebuilt them)
    /// they need no reset. Never allocates.
    pub fn reset(self: *PitchTracker) void {
        self.history_len = 0;
        self.misses = 0;
        self.last = null;
    }

    /// Estimate the pitch of `frame`.
    ///
    /// Runs all three detectors and fuses readings with confidence >= 0.35
    /// that agree within 3% of their median. Returns null only when no
    /// detector passes the floor: the last pitch is then held with falling
    /// confidence for up to 3 frames before null is reported. Never
    /// allocates.
    pub fn estimate(self: *PitchTracker, frame: []const f32) ?TrackedPitch {
        var kept: [3]DetectorReading = @splat(.{ .freq_hz = 0.0, .confidence = 0.0 });
        var count: usize = 0;
        const readings = [3]?DetectorReading{
            self.yin.estimate(frame),
            self.mpm.estimate(frame),
            self.acf.estimate(frame),
        };
        for (readings) |maybe| {
            const reading = maybe orelse continue;
            if (std.math.isFinite(reading.freq_hz) and reading.freq_hz > 0.0 and
                std.math.isFinite(reading.confidence) and reading.confidence >= confidence_floor)
            {
                kept[count] = reading;
                count += 1;
            }
        }
        if (count == 0) return self.miss();

        var freqs: [3]f32 = undefined;
        for (kept[0..count], 0..) |r, i| freqs[i] = r.freq_hz;
        const median = medianOf(freqs[0..count]);

        var agreed: [3]DetectorReading = undefined;
        var agreed_len: usize = 0;
        for (kept[0..count]) |r| {
            if (@abs(r.freq_hz - median) <= agree_tolerance * median) {
                agreed[agreed_len] = r;
                agreed_len += 1;
            }
        }
        if (agreed_len == 0) {
            // max_by(total_cmp): the last maximal element wins ties.
            var best = kept[0];
            for (kept[1..count]) |r| {
                if (totalOrderKey(r.confidence) >= totalOrderKey(best.confidence)) best = r;
            }
            agreed[0] = best;
            agreed_len = 1;
        }

        var weight_sum: f32 = 0.0;
        var freq_sum: f32 = 0.0;
        var conf_sum: f32 = 0.0;
        for (agreed[0..agreed_len]) |r| {
            weight_sum += r.confidence;
            freq_sum += r.freq_hz * r.confidence;
            conf_sum += r.confidence;
        }
        const fused_freq = freq_sum / weight_sum;
        const fused_conf = std.math.clamp(conf_sum / @as(f32, @floatFromInt(agreed_len)), 0.0, 1.0);

        if (self.history_len == smooth_len) {
            std.mem.copyForwards(f32, self.history_buf[0 .. smooth_len - 1], self.history_buf[1..smooth_len]);
            self.history_len -= 1;
        }
        self.history_buf[self.history_len] = fused_freq;
        self.history_len += 1;
        const out: TrackedPitch = .{
            .freq_hz = medianOf(self.history_buf[0..self.history_len]),
            .confidence = fused_conf,
        };
        self.misses = 0;
        self.last = out;
        return out;
    }

    /// Handle a frame with no usable detector reading.
    fn miss(self: *PitchTracker) ?TrackedPitch {
        self.misses +|= 1;
        if (self.misses > max_misses) {
            self.last = null;
            self.history_len = 0;
            return null;
        }
        if (self.last) |prev| {
            const held: TrackedPitch = .{
                .freq_hz = prev.freq_hz,
                .confidence = std.math.clamp(prev.confidence * hold_decay, 0.0, 1.0),
            };
            self.last = held;
            return held;
        }
        return null;
    }
};

/// Key whose signed-integer order equals Rust's `f32::total_cmp` order.
fn totalOrderKey(x: f32) i32 {
    const bits: i32 = @bitCast(x);
    const mask: u32 = @as(u32, @bitCast(bits >> 31)) >> 1;
    return bits ^ @as(i32, @bitCast(mask));
}

/// Median of a non-empty slice of at most `smooth_len` values. Callers
/// guarantee at least one element. Sorts a stack copy by `total_cmp`.
fn medianOf(values: []const f32) f32 {
    std.debug.assert(values.len > 0 and values.len <= smooth_len);
    var sorted_buf: [smooth_len]f32 = undefined;
    const sorted = sorted_buf[0..values.len];
    @memcpy(sorted, values);
    // Insertion sort (stable, like Rust's sort_by) on at most 5 values.
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        const v = sorted[i];
        var j = i;
        while (j > 0 and totalOrderKey(sorted[j - 1]) > totalOrderKey(v)) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = v;
    }
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    return 0.5 * (sorted[mid - 1] + sorted[mid]);
}

const test_sample_rate: u32 = 44_100;
const test_frame_len: usize = 2048;

/// Frames of a phase-continuous sine, one frequency per frame. Caller frees
/// with `freeFrames`.
fn synthFrames(gpa: std.mem.Allocator, freqs: []const f32, frame_len: usize) ![][]f32 {
    const frames = try gpa.alloc([]f32, freqs.len);
    var made: usize = 0;
    errdefer {
        for (frames[0..made]) |f| gpa.free(f);
        gpa.free(frames);
    }
    var phase: f32 = 0.0;
    for (freqs) |freq| {
        const step = 2.0 * std.math.pi * freq / @as(f32, @floatFromInt(test_sample_rate));
        const frame = try gpa.alloc(f32, frame_len);
        for (frame) |*s| {
            s.* = @sin(phase);
            phase += step;
        }
        frames[made] = frame;
        made += 1;
    }
    return frames;
}

fn freeFrames(gpa: std.mem.Allocator, frames: [][]f32) void {
    for (frames) |f| gpa.free(f);
    gpa.free(frames);
}

fn steady(gpa: std.mem.Allocator, freq: f32, n_frames: usize) ![][]f32 {
    const freqs = try gpa.alloc(f32, n_frames);
    defer gpa.free(freqs);
    @memset(freqs, freq);
    return synthFrames(gpa, freqs, test_frame_len);
}

fn trackAll(gpa: std.mem.Allocator, tracker: *PitchTracker, frames: []const []f32) ![]?TrackedPitch {
    const out = try gpa.alloc(?TrackedPitch, frames.len);
    for (frames, 0..) |f, i| out[i] = tracker.estimate(f);
    return out;
}

const XorShift = struct {
    state: u32,
    fn nextBipolar(self: *XorShift) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(std.math.maxInt(u32)))) * 2.0 - 1.0;
    }
};

test "steady_440_tracks_within_3hz" {
    const gpa = std.testing.allocator;
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const frames = try steady(gpa, 440.0, 12);
    defer freeFrames(gpa, frames);
    const out = try trackAll(gpa, &tracker, frames);
    defer gpa.free(out);
    for (out[8..]) |reading| {
        const pitch = reading orelse return error.SteadyToneMustTrackAfterWarmup;
        try std.testing.expect(@abs(pitch.freq_hz - 440.0) <= 3.0);
    }
}

test "silence_returns_none" {
    const gpa = std.testing.allocator;
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const silence: [test_frame_len]f32 = @splat(0.0);
    for (0..3) |_| {
        try std.testing.expect(tracker.estimate(&silence) == null);
    }
}

test "dropout_holds_then_releases" {
    const gpa = std.testing.allocator;
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const warmup = try steady(gpa, 440.0, 8);
    defer freeFrames(gpa, warmup);
    const out = try trackAll(gpa, &tracker, warmup);
    defer gpa.free(out);
    const held_freq = (out[out.len - 1] orelse return error.WarmupMustProduceReading).freq_hz;
    const silence: [test_frame_len]f32 = @splat(0.0);
    var prev_conf = std.math.inf(f32);
    for (0..3) |_| {
        const held = tracker.estimate(&silence) orelse return error.DropoutMustHold3Frames;
        try std.testing.expect(@abs(held.freq_hz - held_freq) <= 3.0);
        try std.testing.expect(held.confidence < prev_conf);
        prev_conf = held.confidence;
    }
    try std.testing.expect(tracker.estimate(&silence) == null);
    try std.testing.expect(tracker.estimate(&silence) == null);
}

test "step_440_to_880_tracks_within_10_frames" {
    const gpa = std.testing.allocator;
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const warmup = try steady(gpa, 440.0, 8);
    defer freeFrames(gpa, warmup);
    const warm_out = try trackAll(gpa, &tracker, warmup);
    defer gpa.free(warm_out);
    const post = try steady(gpa, 880.0, 10);
    defer freeFrames(gpa, post);
    const out = try trackAll(gpa, &tracker, post);
    defer gpa.free(out);
    var settled_at: ?usize = null;
    for (out, 0..) |reading, i| {
        const pitch = reading orelse return error.StepResponseMustKeepProducingReadings;
        if (@abs(pitch.freq_hz - 880.0) <= 15.0 and settled_at == null) settled_at = i;
    }
    const settled = settled_at orelse return error.MustSettleNear880Hz;
    try std.testing.expect(settled < 10);
    const last = out[9] orelse return error.LastStepFrameMustBeReading;
    try std.testing.expect(@abs(last.freq_hz - 880.0) <= 15.0);
}

test "noisy_sine_20db_tracks_within_8hz" {
    const gpa = std.testing.allocator;
    var rng: XorShift = .{ .state = 0x9E37_79B9 };
    const signal_rms: f32 = 1.0 / @sqrt(@as(f32, 2.0));
    const noise_rms = signal_rms / 10.0;
    const uniform_rms: f32 = 1.0 / @sqrt(@as(f32, 3.0));
    const scale = noise_rms / uniform_rms;
    const frames = try steady(gpa, 440.0, 12);
    defer freeFrames(gpa, frames);
    for (frames) |frame| {
        for (frame) |*s| s.* = s.* + rng.nextBipolar() * scale;
    }
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const out = try trackAll(gpa, &tracker, frames);
    defer gpa.free(out);
    for (out[8..]) |reading| {
        const pitch = reading orelse return error.NoisyToneMustTrackAfterWarmup;
        try std.testing.expect(@abs(pitch.freq_hz - 440.0) <= 8.0);
    }
}

test "reset_clears_hold_and_history" {
    const gpa = std.testing.allocator;
    var tracker = try PitchTracker.init(gpa, test_sample_rate);
    defer tracker.deinit(gpa);
    const warmup = try steady(gpa, 440.0, 8);
    defer freeFrames(gpa, warmup);
    const warm_out = try trackAll(gpa, &tracker, warmup);
    defer gpa.free(warm_out);
    tracker.reset();
    const silence: [test_frame_len]f32 = @splat(0.0);
    try std.testing.expect(tracker.estimate(&silence) == null);
    const again = try steady(gpa, 440.0, 10);
    defer freeFrames(gpa, again);
    const retrack = try trackAll(gpa, &tracker, again);
    defer gpa.free(retrack);
    const last = retrack[9] orelse return error.MustRetrackAfterReset;
    try std.testing.expect(@abs(last.freq_hz - 440.0) <= 3.0);
}

test "medianOf matches total_cmp sort" {
    try std.testing.expectEqual(@as(f32, 2.0), medianOf(&.{ 3.0, 1.0, 2.0 }));
    try std.testing.expectEqual(@as(f32, 2.5), medianOf(&.{ 4.0, 1.0, 3.0, 2.0 }));
    try std.testing.expect(totalOrderKey(-1.0) < totalOrderKey(-0.0));
    try std.testing.expect(totalOrderKey(-0.0) < totalOrderKey(0.0));
    try std.testing.expect(totalOrderKey(0.0) < totalOrderKey(1.0));
}
