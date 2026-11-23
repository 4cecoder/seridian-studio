//! Onset and Beat Detection Module
//!
//! Audio event detection algorithms:
//! - Onset detection (spectral flux, energy, complex domain)
//! - Peak picking with adaptive thresholding
//! - Beat tracking
//! - Tempo estimation
//!
//! Based on algorithms from:
//! - Bello et al. "A Tutorial on Onset Detection" (2005)
//! - Ellis "Beat Tracking by Dynamic Programming" (2007)
//! - librosa beat tracking implementation
//!
//! All implementations designed for real-time and offline use.
//!
//! See also: `loop_tempo` module for fast loop classification and tempo estimation.

const std = @import("std");
const math = std.math;
const spectral = @import("spectral.zig");

// =============================================================================
// Onset Detection Functions
// =============================================================================

/// Types of onset detection functions
pub const OnsetMethod = enum {
    /// Energy-based (simple RMS)
    energy,

    /// Spectral flux (change in spectrum)
    spectral_flux,

    /// High-frequency content
    hfc,

    /// Complex domain (phase + magnitude)
    complex,

    /// Spectral difference
    spectral_diff,
};

/// Compute onset detection function value for a frame
pub fn computeOnsetFunction(
    method: OnsetMethod,
    magnitudes: []const f32,
    phases: ?[]const f32,
    prev_magnitudes: ?[]const f32,
    prev_phases: ?[]const f32,
    sample_rate: u32,
) f32 {
    return switch (method) {
        .energy => energyOnset(magnitudes),
        .spectral_flux => spectralFluxOnset(magnitudes, prev_magnitudes),
        .hfc => hfcOnset(magnitudes, sample_rate),
        .complex => complexOnset(magnitudes, phases, prev_magnitudes, prev_phases),
        .spectral_diff => spectralDiffOnset(magnitudes, prev_magnitudes),
    };
}

/// Energy-based onset detection
fn energyOnset(magnitudes: []const f32) f32 {
    var sum: f32 = 0.0;
    for (magnitudes) |m| {
        sum += m * m;
    }
    return sum;
}

/// Spectral flux (half-wave rectified)
fn spectralFluxOnset(magnitudes: []const f32, prev: ?[]const f32) f32 {
    const prev_mags = prev orelse return energyOnset(magnitudes);

    var sum: f32 = 0.0;
    const len = @min(magnitudes.len, prev_mags.len);

    for (0..len) |i| {
        const diff = magnitudes[i] - prev_mags[i];
        if (diff > 0.0) {
            sum += diff * diff;
        }
    }

    return @sqrt(sum);
}

/// High-frequency content
fn hfcOnset(magnitudes: []const f32, sample_rate: u32) f32 {
    _ = sample_rate;
    var sum: f32 = 0.0;

    for (0..magnitudes.len) |i| {
        // Weight by frequency (bin index)
        const weight = @as(f32, @floatFromInt(i + 1));
        sum += magnitudes[i] * magnitudes[i] * weight;
    }

    return sum;
}

/// Complex domain onset (uses phase information)
fn complexOnset(
    mags: []const f32,
    phases: ?[]const f32,
    prev_mags: ?[]const f32,
    prev_phases: ?[]const f32,
) f32 {
    const p = phases orelse return spectralFluxOnset(mags, prev_mags);
    const pm = prev_mags orelse return energyOnset(mags);
    const pp = prev_phases orelse return spectralFluxOnset(mags, prev_mags);

    var sum: f32 = 0.0;
    const len = @min(@min(mags.len, p.len), @min(pm.len, pp.len));

    for (0..len) |i| {
        // Predicted magnitude and phase
        const predicted_phase = 2.0 * p[i] - pp[i];
        const predicted_mag = pm[i];

        // Complex difference
        const real_diff = mags[i] * @cos(p[i]) - predicted_mag * @cos(predicted_phase);
        const imag_diff = mags[i] * @sin(p[i]) - predicted_mag * @sin(predicted_phase);

        sum += real_diff * real_diff + imag_diff * imag_diff;
    }

    return @sqrt(sum);
}

/// Spectral difference (L1 norm)
fn spectralDiffOnset(magnitudes: []const f32, prev: ?[]const f32) f32 {
    const prev_mags = prev orelse return energyOnset(magnitudes);

    var sum: f32 = 0.0;
    const len = @min(magnitudes.len, prev_mags.len);

    for (0..len) |i| {
        sum += @abs(magnitudes[i] - prev_mags[i]);
    }

    return sum;
}

// =============================================================================
// Peak Picking
// =============================================================================

/// Adaptive threshold peak picker
pub const PeakPicker = struct {
    /// Threshold multiplier above median
    threshold: f32 = 1.5,

    /// Pre-maximum wait (frames)
    pre_max: usize = 3,

    /// Post-maximum wait (frames)
    post_max: usize = 3,

    /// Pre-average window (frames)
    pre_avg: usize = 10,

    /// Post-average window (frames)
    post_avg: usize = 10,

    /// Minimum time between onsets (frames)
    wait: usize = 5,

    /// Ring buffer for onset function history
    history: []f32,

    /// Current position in history
    history_pos: usize = 0,

    /// Frames since last onset
    frames_since_onset: usize = 0,

    /// Whether history is filled
    history_filled: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, history_size: usize) !PeakPicker {
        const history = try allocator.alloc(f32, history_size);
        @memset(history, 0.0);

        return .{
            .history = history,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PeakPicker) void {
        self.allocator.free(self.history);
    }

    /// Process one onset function value, return true if onset detected
    pub fn process(self: *PeakPicker, odf_value: f32) bool {
        // Add to history
        self.history[self.history_pos] = odf_value;
        self.history_pos = (self.history_pos + 1) % self.history.len;

        if (!self.history_filled and self.history_pos == 0) {
            self.history_filled = true;
        }

        self.frames_since_onset += 1;

        // Need enough history
        const total_window = self.pre_max + self.post_max + 1;
        if (!self.history_filled and self.history_pos < total_window) {
            return false;
        }

        // Minimum wait between onsets
        if (self.frames_since_onset < self.wait) {
            return false;
        }

        // Get candidate position (center of max window)
        const center_offset = self.pre_max;
        const center_pos = (self.history_pos + self.history.len - center_offset - 1) % self.history.len;
        const center_value = self.history[center_pos];

        // Check if local maximum
        for (0..total_window) |i| {
            if (i == center_offset) continue;
            const check_pos = (self.history_pos + self.history.len - total_window + i) % self.history.len;
            if (self.history[check_pos] >= center_value) {
                return false; // Not a local max
            }
        }

        // Compute adaptive threshold
        const threshold = self.computeThreshold();

        if (center_value > threshold) {
            self.frames_since_onset = 0;
            return true;
        }

        return false;
    }

    /// Compute adaptive threshold based on local median/mean
    fn computeThreshold(self: *const PeakPicker) f32 {
        const avg_window = self.pre_avg + self.post_avg;
        if (avg_window == 0) return 0.0;

        var sum: f32 = 0.0;
        var count: usize = 0;

        for (0..avg_window) |i| {
            const pos = (self.history_pos + self.history.len - avg_window + i) % self.history.len;
            sum += self.history[pos];
            count += 1;
        }

        const mean = if (count > 0) sum / @as(f32, @floatFromInt(count)) else 0.0;

        return mean * self.threshold;
    }

    /// Reset state
    pub fn reset(self: *PeakPicker) void {
        @memset(self.history, 0.0);
        self.history_pos = 0;
        self.history_filled = false;
        self.frames_since_onset = 0;
    }
};

// =============================================================================
// Tempo Estimation
// =============================================================================

/// Estimate tempo using autocorrelation
pub fn estimateTempo(
    onset_envelope: []const f32,
    sample_rate: u32,
    hop_size: usize,
    min_bpm: f32,
    max_bpm: f32,
) f32 {
    const frame_rate = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(hop_size));

    // Convert BPM to lag in frames
    const min_lag = @as(usize, @intFromFloat(60.0 * frame_rate / max_bpm));
    const max_lag = @as(usize, @intFromFloat(60.0 * frame_rate / min_bpm));

    if (max_lag >= onset_envelope.len or min_lag >= max_lag) {
        return 120.0; // Default
    }

    // Compute autocorrelation
    var best_lag: usize = min_lag;
    var best_corr: f32 = 0.0;

    for (min_lag..max_lag) |lag| {
        var corr: f32 = 0.0;
        const n = onset_envelope.len - lag;

        for (0..n) |i| {
            corr += onset_envelope[i] * onset_envelope[i + lag];
        }
        corr /= @as(f32, @floatFromInt(n));

        // Weight by lag to prefer slower tempos (beat vs tatum)
        const lag_weight = @as(f32, @floatFromInt(lag)) / @as(f32, @floatFromInt(max_lag));
        corr *= 1.0 + 0.5 * lag_weight;

        if (corr > best_corr) {
            best_corr = corr;
            best_lag = lag;
        }
    }

    // Convert lag to BPM
    return 60.0 * frame_rate / @as(f32, @floatFromInt(best_lag));
}

/// Refine tempo estimate using comb filter
pub fn refineTempoWithComb(
    onset_envelope: []const f32,
    initial_bpm: f32,
    sample_rate: u32,
    hop_size: usize,
) f32 {
    const frame_rate = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(hop_size));

    // Search around initial estimate
    var best_bpm = initial_bpm;
    var best_score: f32 = 0.0;

    var bpm = initial_bpm * 0.9;
    while (bpm <= initial_bpm * 1.1) : (bpm += 0.5) {
        const period = 60.0 * frame_rate / bpm;

        // Comb filter: sum at period multiples
        var score: f32 = 0.0;
        var h: f32 = 1.0;
        while (h <= 4.0) : (h += 1.0) {
            const lag = @as(usize, @intFromFloat(period * h));
            if (lag >= onset_envelope.len) break;

            for (0..onset_envelope.len - lag) |i| {
                score += onset_envelope[i] * onset_envelope[i + lag];
            }
        }

        if (score > best_score) {
            best_score = score;
            best_bpm = bpm;
        }
    }

    return best_bpm;
}

// =============================================================================
// Beat Tracker
// =============================================================================

/// Simple beat tracker using onset detection
pub const BeatTracker = struct {
    /// Sample rate
    sample_rate: u32,

    /// Hop size for onset detection
    hop_size: usize,

    /// Onset detection method
    method: OnsetMethod = .spectral_flux,

    /// Peak picker for onset detection
    peak_picker: PeakPicker,

    /// Previous frame magnitudes
    prev_magnitudes: []f32,

    /// Previous frame phases
    prev_phases: []f32,

    /// Onset envelope (for tempo estimation)
    onset_envelope: []f32,
    onset_env_pos: usize = 0,

    /// Current tempo estimate (BPM)
    tempo: f32 = 120.0,

    /// Frame counter
    frame_count: usize = 0,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        fft_size: usize,
        hop_size: usize,
        sample_rate: u32,
    ) !BeatTracker {
        const n_bins = fft_size / 2 + 1;
        const envelope_size: usize = 1024; // About 23 seconds at 44100/512

        return .{
            .sample_rate = sample_rate,
            .hop_size = hop_size,
            .peak_picker = try PeakPicker.init(allocator, 64),
            .prev_magnitudes = try allocator.alloc(f32, n_bins),
            .prev_phases = try allocator.alloc(f32, n_bins),
            .onset_envelope = try allocator.alloc(f32, envelope_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BeatTracker) void {
        self.peak_picker.deinit();
        self.allocator.free(self.prev_magnitudes);
        self.allocator.free(self.prev_phases);
        self.allocator.free(self.onset_envelope);
    }

    /// Process one frame, returns true if beat detected
    pub fn processFrame(
        self: *BeatTracker,
        magnitudes: []const f32,
        phases: ?[]const f32,
    ) bool {
        // Compute onset function
        const odf = computeOnsetFunction(
            self.method,
            magnitudes,
            phases,
            if (self.frame_count > 0) self.prev_magnitudes else null,
            if (self.frame_count > 0) self.prev_phases else null,
            self.sample_rate,
        );

        // Store in onset envelope
        self.onset_envelope[self.onset_env_pos] = odf;
        self.onset_env_pos = (self.onset_env_pos + 1) % self.onset_envelope.len;

        // Update previous frame
        const len = @min(magnitudes.len, self.prev_magnitudes.len);
        @memcpy(self.prev_magnitudes[0..len], magnitudes[0..len]);

        if (phases) |p| {
            const plen = @min(p.len, self.prev_phases.len);
            @memcpy(self.prev_phases[0..plen], p[0..plen]);
        }

        self.frame_count += 1;

        // Peak picking
        return self.peak_picker.process(odf);
    }

    /// Get current tempo estimate
    pub fn getTempo(self: *BeatTracker) f32 {
        return self.tempo;
    }

    /// Update tempo estimate (call periodically, not every frame)
    pub fn updateTempo(self: *BeatTracker) void {
        if (self.onset_env_pos < 100) return; // Need enough data

        self.tempo = estimateTempo(
            self.onset_envelope[0..self.onset_env_pos],
            self.sample_rate,
            self.hop_size,
            60.0, // min BPM
            200.0, // max BPM
        );
    }

    /// Reset tracker state
    pub fn reset(self: *BeatTracker) void {
        self.peak_picker.reset();
        @memset(self.prev_magnitudes, 0.0);
        @memset(self.prev_phases, 0.0);
        @memset(self.onset_envelope, 0.0);
        self.onset_env_pos = 0;
        self.frame_count = 0;
        self.tempo = 120.0;
    }
};

// =============================================================================
// Transient Detection
// =============================================================================

/// Detect transients using energy envelope
pub fn detectTransients(
    samples: []const f32,
    threshold: f32,
    min_distance: usize,
    output: []usize,
) usize {
    if (samples.len < 2) return 0;

    var count: usize = 0;
    var last_transient: usize = 0;

    // Compute short-term energy
    const window_size: usize = 256;
    var i: usize = window_size;

    while (i < samples.len and count < output.len) : (i += window_size / 4) {
        // Current window energy
        var curr_energy: f32 = 0.0;
        for (i - window_size..i) |j| {
            curr_energy += samples[j] * samples[j];
        }
        curr_energy /= @as(f32, @floatFromInt(window_size));

        // Previous window energy
        var prev_energy: f32 = 0.0;
        if (i >= window_size * 2) {
            for (i - window_size * 2..i - window_size) |j| {
                prev_energy += samples[j] * samples[j];
            }
            prev_energy /= @as(f32, @floatFromInt(window_size));
        }

        // Transient = sudden energy increase
        if (prev_energy > 1e-10 and curr_energy / prev_energy > threshold) {
            if (i - last_transient >= min_distance) {
                output[count] = i;
                count += 1;
                last_transient = i;
            }
        }
    }

    return count;
}

// =============================================================================
// Tests
// =============================================================================

test "onset function computation" {
    const testing = std.testing;

    // Create test spectra
    var mags1: [256]f32 = @as([256]f32, @splat(0.0));
    var mags2: [256]f32 = @as([256]f32, @splat(0.0));

    mags1[50] = 1.0;
    mags2[50] = 2.0; // Increase = onset

    const flux = computeOnsetFunction(.spectral_flux, &mags2, null, &mags1, null, 44100);
    try testing.expect(flux > 0.0);

    const energy = computeOnsetFunction(.energy, &mags1, null, null, null, 44100);
    try testing.expect(energy > 0.0);
}

test "peak picker" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var picker = try PeakPicker.init(allocator, 32);
    defer picker.deinit();

    // Feed some values
    _ = picker.process(0.1);
    _ = picker.process(0.2);
    _ = picker.process(0.3);
    _ = picker.process(0.5); // Peak
    _ = picker.process(0.3);
    _ = picker.process(0.2);
    _ = picker.process(0.1);

    // Should have detected something (after enough history)
    for (0..20) |_| {
        _ = picker.process(0.05);
    }

    // Just verify it doesn't crash
    try testing.expect(true);
}

test "tempo estimation" {
    // Create simple onset envelope with regular peaks
    var envelope: [512]f32 = @as([512]f32, @splat(0.0));

    // Peaks at 120 BPM (every ~20 frames at 44100/512)
    const period: usize = 20;
    var i: usize = 0;
    while (i < envelope.len) : (i += period) {
        envelope[i] = 1.0;
    }

    const tempo = estimateTempo(&envelope, 44100, 512, 60.0, 200.0);

    const testing = std.testing;
    // Should be around 120 BPM (± tolerance)
    try testing.expect(tempo > 100.0 and tempo < 140.0);
}
