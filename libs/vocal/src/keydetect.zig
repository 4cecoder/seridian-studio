// Translated to Zig from pitchpure/crates/pitchpure_engine/src/keydetect.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Key detection from a stream of pitch observations.
//!
//! `KeyDetector` accumulates confidence-weighted votes into a 12-bin
//! pitch-class histogram and matches it against rotated Krumhansl major/minor
//! profiles.

const std = @import("std");

/// Minimum per-observation confidence required for a vote to count.
const min_obs_confidence: f32 = 0.3;
/// Minimum accumulated vote weight before `estimate` returns a key.
const min_total_votes: f32 = 50.0;

/// Krumhansl-Kessler major profile, indexed by semitone offset from the root.
const major_profile = [12]f32{ 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 };
/// Krumhansl-Kessler minor profile, indexed by semitone offset from the root.
const minor_profile = [12]f32{ 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 };

/// Reference frequency (A4) for frequency-to-pitch-class conversion.
const reference_hz: f32 = 440.0;
/// MIDI note of the reference frequency (A4).
const reference_midi: f32 = 69.0;
/// MIDI note of C4; key roots are reported in octave 4 (`60..=71`).
const octave_base_midi: i32 = 60;

/// Estimated musical key.
pub const KeyEstimate = struct {
    /// Root of the key as a MIDI note number in octave 4 (`60` = C ..= `71` = B).
    root_midi: u8,
    /// True for a minor key, false for a major key.
    minor: bool,
    /// Normalized margin between the best and runner-up key correlations (`0..=1`).
    confidence: f32,
};

/// Accumulates pitch observations and estimates the musical key.
/// Order-free: only the pitch-class histogram matters.
pub const KeyDetector = struct {
    votes: [12]f32 = @splat(0.0),
    total: f32 = 0.0,
    /// Reserved for future sample-rate-dependent weighting. Unused for now.
    sample_rate: u32,

    /// Create an empty detector. `sample_rate` is unused for now.
    pub fn init(sample_rate: u32) KeyDetector {
        return .{ .sample_rate = sample_rate };
    }

    /// Accumulate one pitch observation, weighted by `confidence`.
    /// Observations with `confidence < 0.3`, non-finite `confidence`, or
    /// non-finite/non-positive `freq_hz` are ignored.
    pub fn observe(self: *KeyDetector, freq_hz: f32, confidence: f32) void {
        if (!std.math.isFinite(freq_hz) or freq_hz <= 0.0) return;
        if (!std.math.isFinite(confidence) or confidence < min_obs_confidence) return;
        // Finite positive input keeps this well inside i32 range.
        const midi: i32 = @intFromFloat(@round(reference_midi + 12.0 * std.math.log2(freq_hz / reference_hz)));
        const pitch_class: usize = @intCast(@mod(midi, 12));
        self.votes[pitch_class] += confidence;
        self.total += confidence;
    }

    /// Estimate the key, or null until at least 50.0 votes have accumulated.
    /// `confidence` is half the margin between the best and runner-up Pearson
    /// correlations, clamped to `0..=1`.
    pub fn estimate(self: *const KeyDetector) ?KeyEstimate {
        if (self.total < min_total_votes) return null;
        var best_score = -std.math.inf(f32);
        var runner_up = -std.math.inf(f32);
        var best_root: usize = 0;
        var best_minor = false;
        const profiles = [_]struct { minor: bool, profile: *const [12]f32 }{
            .{ .minor = false, .profile = &major_profile },
            .{ .minor = true, .profile = &minor_profile },
        };
        for (0..12) |root| {
            for (profiles) |entry| {
                var template: [12]f32 = undefined;
                for (&template, 0..) |*slot, pitch_class| {
                    slot.* = entry.profile[(pitch_class + 12 - root) % 12];
                }
                const score = pearson(&self.votes, &template);
                if (score > best_score) {
                    runner_up = best_score;
                    best_score = score;
                    best_root = root;
                    best_minor = entry.minor;
                } else if (score > runner_up) {
                    runner_up = score;
                }
            }
        }
        return .{
            .root_midi = @intCast(octave_base_midi + @as(i32, @intCast(best_root))),
            .minor = best_minor,
            .confidence = std.math.clamp((best_score - runner_up) * 0.5, 0.0, 1.0),
        };
    }

    /// Clear all accumulated votes.
    pub fn reset(self: *KeyDetector) void {
        self.votes = @splat(0.0);
        self.total = 0.0;
    }
};

/// Pearson correlation between two 12-bin vectors. 0.0 when either vector
/// has zero variance.
fn pearson(histogram: *const [12]f32, template: *const [12]f32) f32 {
    var hsum: f32 = 0.0;
    for (histogram) |h| hsum += h;
    var tsum: f32 = 0.0;
    for (template) |t| tsum += t;
    const histogram_mean = hsum / 12.0;
    const template_mean = tsum / 12.0;
    var numerator: f32 = 0.0;
    var histogram_var: f32 = 0.0;
    var template_var: f32 = 0.0;
    for (histogram, template) |h, t| {
        const dh = h - histogram_mean;
        const dt = t - template_mean;
        numerator += dh * dt;
        histogram_var += dh * dh;
        template_var += dt * dt;
    }
    const denominator = @sqrt(histogram_var * template_var);
    if (denominator > 0.0 and std.math.isFinite(denominator)) return numerator / denominator;
    return 0.0;
}

const testing = std.testing;

fn feed(detector: *KeyDetector, freqs: []const f32, count: usize, confidence: f32) void {
    for (0..count) |i| detector.observe(freqs[i % freqs.len], confidence);
}

test "detects_c_major_triad" {
    var detector = KeyDetector.init(48_000);
    feed(&detector, &.{ 261.6, 329.6, 392.0 }, 500, 0.9);
    const est = detector.estimate() orelse return error.ExpectedKeyEstimate;
    try testing.expectEqual(@as(u8, 60), est.root_midi);
    try testing.expect(!est.minor);
}

test "detects_a_minor_triad" {
    var detector = KeyDetector.init(48_000);
    feed(&detector, &.{ 220.0, 261.6, 329.6 }, 500, 0.9);
    const est = detector.estimate() orelse return error.ExpectedKeyEstimate;
    try testing.expectEqual(@as(u8, 69), est.root_midi);
    try testing.expect(est.minor);
}

test "returns_none_below_vote_threshold" {
    var detector = KeyDetector.init(48_000);
    try testing.expect(detector.estimate() == null);
    feed(&detector, &.{ 261.6, 329.6, 392.0 }, 10, 0.9);
    try testing.expect(detector.estimate() == null);
}

test "ignores_low_confidence_and_bad_freqs" {
    var detector = KeyDetector.init(48_000);
    for (0..500) |_| {
        detector.observe(261.6, 0.1);
        detector.observe(std.math.nan(f32), 0.9);
        detector.observe(std.math.inf(f32), 0.9);
        detector.observe(-100.0, 0.9);
        detector.observe(0.0, 0.9);
    }
    try testing.expect(detector.estimate() == null);
}

test "reset_clears_votes" {
    var detector = KeyDetector.init(48_000);
    feed(&detector, &.{ 261.6, 329.6, 392.0 }, 500, 0.9);
    try testing.expect(detector.estimate() != null);
    detector.reset();
    try testing.expect(detector.estimate() == null);
}
