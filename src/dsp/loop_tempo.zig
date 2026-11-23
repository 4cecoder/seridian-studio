//! Loop Tempo Estimator
//!
//! Fast, robust tempo estimation for audio loops based on the algorithm from
//! Audacity's loop-tempo-estimator (saintmatthieu/loop-tempo-estimator).
//!
//! Algorithm overview:
//! 1. Decimate audio to reduce computational load
//! 2. Compute STFT with compressed spectral representation
//! 3. Generate onset detection function via spectral novelty
//! 4. Use tatum quantization fit to find best BPM hypothesis
//! 5. Classify whether audio is actually a loop
//!
//! References:
//! - Müller, Meinard. "Fundamentals of Music Processing" (section 6.5)
//! - https://github.com/saintmatthieu/loop-tempo-estimator
//! - GPL-3.0 licensed reference implementation

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// =============================================================================
// Constants
// =============================================================================

/// Spectral compression gamma (per Müller section 6.5)
const COMPRESSION_GAMMA: f32 = 100.0;

/// Moving average smoothing window duration in seconds
const SMOOTHING_DURATION: f32 = 0.2;

/// Threshold raiser for onset detection
const THRESHOLD_RAISER: f32 = 1.5;

/// BPM range constraints
const MIN_BPM: f32 = 50.0;
const MAX_BPM: f32 = 200.0;

/// Valid tatums per bar for 4/4 time
const TATUMS_PER_BAR = [_]u32{ 1, 2, 4, 8, 12, 16, 24 };

/// Kurtosis threshold for single-event detection
const KURTOSIS_THRESHOLD: f32 = 20.0;

/// Target hop duration in seconds (10ms)
const HOP_DURATION: f32 = 0.01;

/// Maximum duration for loop classification (60 seconds)
const MAX_LOOP_DURATION: f32 = 60.0;

// =============================================================================
// Loop Tempo Estimator
// =============================================================================

pub const LoopTempoResult = struct {
    /// Estimated BPM (null if not a valid loop)
    bpm: ?f32,
    /// Confidence score (0.0 to 1.0)
    confidence: f32,
    /// Whether the audio is classified as a loop
    is_loop: bool,
    /// Number of bars detected
    num_bars: u32,
    /// Tatums per bar in best hypothesis
    tatums_per_bar: u32,
};

pub const LoopTempoEstimator = struct {
    allocator: Allocator,
    sample_rate: f32,

    // FFT configuration
    fft_size: usize,
    hop_size: usize,
    decimation_factor: u32,
    decimated_rate: f32,

    // Buffers
    window: []f32,
    fft_buffer: []f32,
    prev_spectrum: []f32,
    odf_buffer: []f32,
    smoothing_window: []f32,

    // Working storage for FFT (simplified real-only approach)
    fft_real: []f32,
    fft_imag: []f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: f32) !Self {
        // Calculate decimation factor (target ~4000 Hz effective rate)
        const decimation_factor = getDecimationFactor(sample_rate);
        const decimated_rate = sample_rate / @as(f32, @floatFromInt(decimation_factor));

        // FFT size: power of 2 for ~10ms hop
        const fft_size = getFftSize(decimated_rate);
        const hop_size = @as(usize, @intFromFloat(decimated_rate * HOP_DURATION));

        // Spectrum size (real FFT)
        const spectrum_size = fft_size / 2 + 1;

        // Smoothing window size
        const smoothing_samples = @as(usize, @intFromFloat(SMOOTHING_DURATION * decimated_rate / @as(f32, @floatFromInt(hop_size))));
        const smoothing_size = if (smoothing_samples % 2 == 0) smoothing_samples + 1 else smoothing_samples;

        // Allocate buffers
        const window = try allocator.alloc(f32, fft_size);
        const fft_buffer = try allocator.alloc(f32, fft_size);
        const prev_spectrum = try allocator.alloc(f32, spectrum_size);
        const odf_buffer = try allocator.alloc(f32, 65536); // Max ODF frames
        const smoothing_window = try allocator.alloc(f32, smoothing_size);
        const fft_real = try allocator.alloc(f32, fft_size);
        const fft_imag = try allocator.alloc(f32, fft_size);

        // Initialize Hann window (normalized to sum to unity)
        var window_sum: f32 = 0.0;
        for (window, 0..) |*w, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fft_size));
            w.* = 0.5 - 0.5 * @cos(2.0 * math.pi * t);
            window_sum += w.*;
        }
        for (window) |*w| {
            w.* /= window_sum;
        }

        // Initialize smoothing window (normalized Hann)
        var smooth_sum: f32 = 0.0;
        for (smoothing_window, 0..) |*w, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(smoothing_size));
            w.* = 0.5 - 0.5 * @cos(2.0 * math.pi * t);
            smooth_sum += w.*;
        }
        for (smoothing_window) |*w| {
            w.* /= smooth_sum;
        }

        // Zero previous spectrum
        @memset(prev_spectrum, 0);

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .fft_size = fft_size,
            .hop_size = hop_size,
            .decimation_factor = decimation_factor,
            .decimated_rate = decimated_rate,
            .window = window,
            .fft_buffer = fft_buffer,
            .prev_spectrum = prev_spectrum,
            .odf_buffer = odf_buffer,
            .smoothing_window = smoothing_window,
            .fft_real = fft_real,
            .fft_imag = fft_imag,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.window);
        self.allocator.free(self.fft_buffer);
        self.allocator.free(self.prev_spectrum);
        self.allocator.free(self.odf_buffer);
        self.allocator.free(self.smoothing_window);
        self.allocator.free(self.fft_real);
        self.allocator.free(self.fft_imag);
    }

    /// Estimate tempo of audio buffer
    /// Returns null BPM if audio is not classified as a loop
    pub fn estimate(self: *Self, audio: []const f32) LoopTempoResult {
        const duration = @as(f32, @floatFromInt(audio.len)) / self.sample_rate;

        // Reject files too long to be loops
        if (duration > MAX_LOOP_DURATION) {
            return .{
                .bpm = null,
                .confidence = 0.0,
                .is_loop = false,
                .num_bars = 0,
                .tatums_per_bar = 0,
            };
        }

        // Compute onset detection function
        const odf_len = self.computeOdf(audio);
        if (odf_len < 4) {
            return .{
                .bpm = null,
                .confidence = 0.0,
                .is_loop = false,
                .num_bars = 0,
                .tatums_per_bar = 0,
            };
        }

        const odf = self.odf_buffer[0..odf_len];

        // Check for single-event (not a loop)
        if (isSingleEvent(odf)) {
            return .{
                .bpm = null,
                .confidence = 0.0,
                .is_loop = false,
                .num_bars = 0,
                .tatums_per_bar = 0,
            };
        }

        // Find best tatum quantization fit
        const result = self.findBestFit(odf, duration);

        return result;
    }

    /// Compute onset detection function from audio
    fn computeOdf(self: *Self, audio: []const f32) usize {
        const decimated_len = audio.len / self.decimation_factor;
        if (decimated_len < self.fft_size) return 0;

        const num_frames = (decimated_len - self.fft_size) / self.hop_size + 1;
        if (num_frames > self.odf_buffer.len) return 0;

        // Reset previous spectrum
        @memset(self.prev_spectrum, 0);

        var frame_idx: usize = 0;
        var sample_pos: usize = 0;

        while (frame_idx < num_frames) : (frame_idx += 1) {
            // Extract and window frame (with decimation)
            for (self.fft_buffer, 0..) |*buf, i| {
                const src_idx = (sample_pos + i) * self.decimation_factor;
                if (src_idx < audio.len) {
                    buf.* = audio[src_idx] * self.window[i];
                } else {
                    buf.* = 0;
                }
            }

            // Compute FFT magnitude spectrum
            self.computeSpectrum();

            // Compute spectral novelty with compression
            var novelty: f32 = 0.0;
            const spectrum_size = self.fft_size / 2 + 1;

            for (0..spectrum_size) |bin| {
                // Magnitude from real/imag
                const re = self.fft_real[bin];
                const im = if (bin < self.fft_imag.len) self.fft_imag[bin] else 0;
                const mag = @sqrt(re * re + im * im);

                // Spectral compression: log2(1 + gamma * sqrt(x))
                const compressed = math.log2(1.0 + COMPRESSION_GAMMA * @sqrt(mag));

                // Half-wave rectified difference (novelty)
                const diff = compressed - self.prev_spectrum[bin];
                if (diff > 0) {
                    novelty += diff;
                }

                // Store for next frame
                self.prev_spectrum[bin] = compressed;
            }

            self.odf_buffer[frame_idx] = novelty;
            sample_pos += self.hop_size;
        }

        // Apply moving average smoothing and subtract
        self.smoothOdf(num_frames);

        return num_frames;
    }

    /// Simplified DFT (for when we don't have PFFFT)
    fn computeSpectrum(self: *Self) void {
        const n = self.fft_size;
        const spectrum_size = n / 2 + 1;

        // Simple DFT for magnitude spectrum
        // Note: In production, use optimized FFT library
        for (0..spectrum_size) |k| {
            var sum_re: f32 = 0.0;
            var sum_im: f32 = 0.0;
            const freq = 2.0 * math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));

            for (self.fft_buffer, 0..) |sample, i| {
                const angle = freq * @as(f32, @floatFromInt(i));
                sum_re += sample * @cos(angle);
                sum_im -= sample * @sin(angle);
            }

            self.fft_real[k] = sum_re;
            if (k < self.fft_imag.len) {
                self.fft_imag[k] = sum_im;
            }
        }
    }

    /// Apply smoothing and threshold to ODF
    fn smoothOdf(self: *Self, len: usize) void {
        const half_win = self.smoothing_window.len / 2;

        // Compute smoothed version (circular for loop assumption)
        var temp_buffer: [65536]f32 = undefined;

        for (0..len) |i| {
            var smoothed: f32 = 0.0;

            for (self.smoothing_window, 0..) |w, j| {
                // Circular indexing for loop
                const offset = @as(i32, @intCast(j)) - @as(i32, @intCast(half_win));
                var idx = @as(i32, @intCast(i)) + offset;
                if (idx < 0) idx += @as(i32, @intCast(len));
                if (idx >= @as(i32, @intCast(len))) idx -= @as(i32, @intCast(len));

                smoothed += self.odf_buffer[@as(usize, @intCast(idx))] * w;
            }

            temp_buffer[i] = smoothed * THRESHOLD_RAISER;
        }

        // Subtract smoothed and clip
        for (0..len) |i| {
            const diff = self.odf_buffer[i] - temp_buffer[i];
            self.odf_buffer[i] = @max(0.0, diff);
        }
    }

    /// Find best tatum quantization fit
    fn findBestFit(_: *Self, odf: []const f32, duration: f32) LoopTempoResult {
        var best_score: f32 = 0.0;
        var best_bpm: f32 = 0.0;
        var best_bars: u32 = 0;
        var best_tatums: u32 = 0;

        // Bars per minute constraints
        const min_bars = @as(u32, @intFromFloat(@ceil(duration * 12.5 / 60.0)));
        const max_bars = @as(u32, @intFromFloat(@floor(duration * 50.0 / 60.0)));

        // Try each bar count hypothesis
        var num_bars = min_bars;
        while (num_bars <= max_bars) : (num_bars += 1) {
            // Calculate BPM for this bar count (4/4 time)
            const bpm = @as(f32, @floatFromInt(num_bars)) * 4.0 * 60.0 / duration;

            // Skip if outside BPM range
            if (bpm < MIN_BPM or bpm > MAX_BPM) continue;

            // Try each tatum subdivision
            for (TATUMS_PER_BAR) |tatums| {
                const total_tatums = num_bars * tatums;
                const tatums_per_minute = @as(f32, @floatFromInt(total_tatums)) * 60.0 / duration;

                // Tatum rate constraints (12.5 to 720 per minute)
                if (tatums_per_minute < 12.5 or tatums_per_minute > 720.0) continue;

                // Compute quantization fit score
                const score = computeQuantizationScore(odf, total_tatums);

                if (score > best_score) {
                    best_score = score;
                    best_bpm = bpm;
                    best_bars = num_bars;
                    best_tatums = tatums;
                }
            }
        }

        // Classify as loop based on confidence threshold
        const is_loop = best_score > 0.5;

        return .{
            .bpm = if (is_loop) best_bpm else null,
            .confidence = best_score,
            .is_loop = is_loop,
            .num_bars = best_bars,
            .tatums_per_bar = best_tatums,
        };
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Get decimation factor based on sample rate
/// Target effective rate around 4000 Hz
fn getDecimationFactor(sample_rate: f32) u32 {
    if (sample_rate > 40000) return 12;
    if (sample_rate > 20000) return 6;
    if (sample_rate > 10000) return 3;
    return 1;
}

/// Get FFT size for given sample rate
fn getFftSize(sample_rate: f32) usize {
    // Target 10ms hop, FFT should be ~4x hop for good frequency resolution
    const hop_samples = sample_rate * HOP_DURATION;
    const target_fft = hop_samples * 4;

    // Round up to power of 2
    var size: usize = 64;
    while (@as(f32, @floatFromInt(size)) < target_fft and size < 4096) {
        size *= 2;
    }
    return size;
}

/// Check if ODF represents a single transient event (not a loop)
fn isSingleEvent(odf: []const f32) bool {
    if (odf.len < 2) return true;

    // Compute mean and variance
    var sum: f32 = 0.0;
    for (odf) |v| {
        sum += v;
    }
    const mean = sum / @as(f32, @floatFromInt(odf.len));

    if (mean < 0.0001) return false; // Silent

    // Normalize and compute kurtosis
    var m2: f32 = 0.0;
    var m4: f32 = 0.0;

    for (odf) |v| {
        const centered = v - mean;
        const c2 = centered * centered;
        m2 += c2;
        m4 += c2 * c2;
    }

    m2 /= @as(f32, @floatFromInt(odf.len));
    m4 /= @as(f32, @floatFromInt(odf.len));

    // Kurtosis = m4 / m2^2 - 3 (excess kurtosis)
    if (m2 < 0.0001) return false;
    const kurtosis = m4 / (m2 * m2) - 3.0;

    // High kurtosis indicates single spike
    return kurtosis > KURTOSIS_THRESHOLD;
}

/// Compute quantization score for given tatum count
fn computeQuantizationScore(odf: []const f32, num_tatums: u32) f32 {
    if (num_tatums == 0) return 0.0;

    const odf_len = @as(f32, @floatFromInt(odf.len));
    const tatum_spacing = odf_len / @as(f32, @floatFromInt(num_tatums));

    // Find peaks in ODF
    var peaks: [256]usize = undefined;
    var peak_values: [256]f32 = undefined;
    var num_peaks: usize = 0;

    for (1..odf.len - 1) |i| {
        if (num_peaks >= 256) break;
        if (odf[i] > odf[i - 1] and odf[i] > odf[i + 1] and odf[i] > 0.01) {
            peaks[num_peaks] = i;
            peak_values[num_peaks] = odf[i];
            num_peaks += 1;
        }
    }

    if (num_peaks == 0) return 0.0;

    // Find best lag (onset alignment)
    var best_error: f32 = math.inf(f32);
    var lag: usize = 0;

    while (lag < @as(usize, @intFromFloat(tatum_spacing))) : (lag += 1) {
        var total_error: f32 = 0.0;
        var total_weight: f32 = 0.0;

        for (0..num_peaks) |p| {
            const peak_pos = @as(f32, @floatFromInt(peaks[p]));
            const weight = peak_values[p];

            // Distance to nearest tatum
            const adjusted_pos = peak_pos - @as(f32, @floatFromInt(lag));
            const tatum_idx = adjusted_pos / tatum_spacing;
            const nearest_tatum = @round(tatum_idx) * tatum_spacing;
            const distance = @abs(adjusted_pos - nearest_tatum);

            // Normalized distance (0 to 0.5 of tatum spacing)
            const norm_dist = 2.0 * distance / tatum_spacing;

            total_error += norm_dist * weight;
            total_weight += weight;
        }

        if (total_weight > 0) {
            const avg_error = total_error / total_weight;
            if (avg_error < best_error) {
                best_error = avg_error;
            }
        }
    }

    // Convert error to score (1.0 = perfect alignment)
    return @max(0.0, 1.0 - best_error);
}

/// Estimate tempo with default parameters (convenience function)
pub fn estimateLoopTempo(allocator: Allocator, audio: []const f32, sample_rate: f32) !LoopTempoResult {
    var estimator = try LoopTempoEstimator.init(allocator, sample_rate);
    defer estimator.deinit();
    return estimator.estimate(audio);
}

// =============================================================================
// Additional Utilities
// =============================================================================

/// Snap BPM to common tempo values
pub fn snapToCommonTempo(bpm: f32, tolerance: f32) f32 {
    const common_tempos = [_]f32{
        60,  70,  75,  80,  85,  90,  95,  100, 105, 110,
        115, 120, 125, 128, 130, 135, 140, 145, 150, 155,
        160, 170, 174, 175, 180, 190, 200,
    };

    for (common_tempos) |tempo| {
        if (@abs(bpm - tempo) < tolerance) {
            return tempo;
        }
    }
    return bpm;
}

/// Get tempo as beat duration in samples
pub fn tempoToSamples(bpm: f32, sample_rate: f32) f32 {
    return sample_rate * 60.0 / bpm;
}

/// Get loop length in bars
pub fn getLoopBars(audio_len: usize, sample_rate: f32, bpm: f32) f32 {
    const duration = @as(f32, @floatFromInt(audio_len)) / sample_rate;
    const beats = duration * bpm / 60.0;
    return beats / 4.0; // Assuming 4/4
}

/// Quantize loop to exact bar boundary
pub fn quantizeToBar(audio_len: usize, sample_rate: f32, bpm: f32) usize {
    const samples_per_bar = sample_rate * 60.0 * 4.0 / bpm;
    const num_bars = @round(@as(f32, @floatFromInt(audio_len)) / samples_per_bar);
    return @as(usize, @intFromFloat(num_bars * samples_per_bar));
}

// =============================================================================
// Tests
// =============================================================================

test "decimation factor" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 12), getDecimationFactor(48000));
    try testing.expectEqual(@as(u32, 12), getDecimationFactor(44100));
    try testing.expectEqual(@as(u32, 6), getDecimationFactor(22050));
    try testing.expectEqual(@as(u32, 1), getDecimationFactor(8000));
}

test "fft size" {
    const testing = std.testing;

    // For 4000 Hz effective rate, 10ms = 40 samples hop, FFT should be ~160
    const size = getFftSize(4000);
    try testing.expect(size >= 128 and size <= 256);
}

test "single event detection" {
    const testing = std.testing;

    // Single spike should be detected
    var single_spike = @as([100]f32, @splat(0));
    single_spike[50] = 10.0;
    try testing.expect(isSingleEvent(&single_spike));

    // Regular pattern should not be single event
    var pattern = @as([100]f32, @splat(0));
    for (0..10) |i| {
        pattern[i * 10] = 1.0;
    }
    try testing.expect(!isSingleEvent(&pattern));
}

test "snap to common tempo" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f32, 120.0), snapToCommonTempo(119.5, 1.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 128.0), snapToCommonTempo(127.8, 1.0), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 133.0), snapToCommonTempo(133.0, 1.0), 0.01); // Not common, returns as-is
}

test "tempo to samples" {
    const testing = std.testing;

    // At 120 BPM, 44100 Hz: one beat = 22050 samples
    try testing.expectApproxEqAbs(@as(f32, 22050.0), tempoToSamples(120.0, 44100.0), 1.0);
}
