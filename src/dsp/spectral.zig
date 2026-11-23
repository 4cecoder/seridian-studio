//! Spectral Analysis Module
//!
//! Audio feature extraction and spectral analysis:
//! - Spectral descriptors (centroid, spread, flux, rolloff)
//! - Mel-frequency cepstral coefficients (MFCC)
//! - Chroma features (pitch class profiles)
//! - Mel filterbank
//!
//! Based on algorithms from:
//! - librosa (Python audio analysis)
//! - Essentia (MTG-UPF)
//! - Standard MIR literature
//!
//! All implementations designed for real-time use.

const std = @import("std");
const math = std.math;

// =============================================================================
// Mel Scale Conversion
// =============================================================================

/// Convert frequency (Hz) to Mel scale
pub fn hzToMel(hz: f32) f32 {
    return 2595.0 * @log10(1.0 + hz / 700.0);
}

/// Convert Mel scale to frequency (Hz)
pub fn melToHz(mel: f32) f32 {
    return 700.0 * (math.pow(f32, 10.0, mel / 2595.0) - 1.0);
}

/// Convert frequency to ERB (Equivalent Rectangular Bandwidth) scale
pub fn hzToErb(hz: f32) f32 {
    return 21.4 * @log10(1.0 + hz * 0.00437);
}

/// Convert ERB scale to Hz
pub fn erbToHz(erb: f32) f32 {
    return (math.pow(f32, 10.0, erb / 21.4) - 1.0) / 0.00437;
}

// =============================================================================
// Spectral Descriptors
// =============================================================================

/// Collection of spectral shape descriptors
pub const SpectralDescriptors = struct {
    centroid: f32 = 0.0,
    spread: f32 = 0.0,
    skewness: f32 = 0.0,
    kurtosis: f32 = 0.0,
    flatness: f32 = 0.0,
    rolloff: f32 = 0.0,
    flux: f32 = 0.0,
    crest: f32 = 0.0,
};

/// Compute all spectral descriptors from magnitude spectrum
pub fn computeSpectralDescriptors(
    magnitudes: []const f32,
    prev_magnitudes: ?[]const f32,
    sample_rate: u32,
) SpectralDescriptors {
    const n_bins = magnitudes.len;
    const bin_freq = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n_bins * 2));

    // Compute spectral sum and weighted sum
    var sum: f32 = 0.0;
    var weighted_sum: f32 = 0.0;
    var log_sum: f32 = 0.0;
    var max_mag: f32 = 0.0;

    for (0..n_bins) |i| {
        const mag = magnitudes[i];
        const freq = @as(f32, @floatFromInt(i)) * bin_freq;

        sum += mag;
        weighted_sum += freq * mag;
        max_mag = @max(max_mag, mag);

        if (mag > 1e-10) {
            log_sum += @log(mag);
        } else {
            log_sum += @log(1e-10);
        }
    }

    var result = SpectralDescriptors{};

    if (sum < 1e-10) {
        return result;
    }

    // Centroid: weighted average frequency
    result.centroid = weighted_sum / sum;

    // Spread: weighted standard deviation
    var spread_sum: f32 = 0.0;
    for (0..n_bins) |i| {
        const freq = @as(f32, @floatFromInt(i)) * bin_freq;
        const diff = freq - result.centroid;
        spread_sum += diff * diff * magnitudes[i];
    }
    result.spread = @sqrt(spread_sum / sum);

    // Skewness and Kurtosis
    var skew_sum: f32 = 0.0;
    var kurt_sum: f32 = 0.0;
    if (result.spread > 1e-10) {
        for (0..n_bins) |i| {
            const freq = @as(f32, @floatFromInt(i)) * bin_freq;
            const diff = (freq - result.centroid) / result.spread;
            const diff3 = diff * diff * diff;
            const diff4 = diff3 * diff;
            skew_sum += diff3 * magnitudes[i];
            kurt_sum += diff4 * magnitudes[i];
        }
        result.skewness = skew_sum / sum;
        result.kurtosis = kurt_sum / sum - 3.0; // Excess kurtosis
    }

    // Flatness: geometric mean / arithmetic mean (dB)
    const geometric_mean = @exp(log_sum / @as(f32, @floatFromInt(n_bins)));
    const arithmetic_mean = sum / @as(f32, @floatFromInt(n_bins));
    if (arithmetic_mean > 1e-10) {
        result.flatness = geometric_mean / arithmetic_mean;
    }

    // Rolloff: frequency below which 85% of energy lies
    const threshold = 0.85 * sum;
    var cumsum: f32 = 0.0;
    for (0..n_bins) |i| {
        cumsum += magnitudes[i];
        if (cumsum >= threshold) {
            result.rolloff = @as(f32, @floatFromInt(i)) * bin_freq;
            break;
        }
    }

    // Flux: L2 norm of difference with previous frame
    if (prev_magnitudes) |prev| {
        var flux_sum: f32 = 0.0;
        for (0..n_bins) |i| {
            const diff = magnitudes[i] - prev[i];
            // Half-wave rectified (only increases)
            if (diff > 0.0) {
                flux_sum += diff * diff;
            }
        }
        result.flux = @sqrt(flux_sum);
    }

    // Crest factor: peak / RMS
    if (sum > 1e-10) {
        const rms = @sqrt(sum / @as(f32, @floatFromInt(n_bins)));
        result.crest = max_mag / rms;
    }

    return result;
}

/// Compute spectral centroid only (faster for single feature)
pub fn spectralCentroid(magnitudes: []const f32, sample_rate: u32) f32 {
    const n_bins = magnitudes.len;
    const bin_freq = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n_bins * 2));

    var sum: f32 = 0.0;
    var weighted_sum: f32 = 0.0;

    for (0..n_bins) |i| {
        const mag = magnitudes[i];
        sum += mag;
        weighted_sum += @as(f32, @floatFromInt(i)) * bin_freq * mag;
    }

    if (sum < 1e-10) return 0.0;
    return weighted_sum / sum;
}

/// Compute spectral flux (change from previous frame)
pub fn spectralFlux(magnitudes: []const f32, prev_magnitudes: []const f32) f32 {
    var sum: f32 = 0.0;
    const len = @min(magnitudes.len, prev_magnitudes.len);

    for (0..len) |i| {
        const diff = magnitudes[i] - prev_magnitudes[i];
        if (diff > 0.0) {
            sum += diff * diff;
        }
    }

    return @sqrt(sum);
}

// =============================================================================
// Mel Filterbank
// =============================================================================

/// Mel filterbank for MFCC computation
pub const MelFilterbank = struct {
    /// Filter coefficients [n_filters][n_fft_bins]
    filters: [][]f32,

    /// Number of mel filters
    n_filters: usize,

    /// FFT size used
    n_fft: usize,

    /// Allocator used
    allocator: std.mem.Allocator,

    /// Create mel filterbank
    pub fn init(
        allocator: std.mem.Allocator,
        n_filters: usize,
        n_fft: usize,
        sample_rate: u32,
        f_min: f32,
        f_max: f32,
    ) !MelFilterbank {
        const n_bins = n_fft / 2 + 1;

        // Allocate filter matrix
        const filters = try allocator.alloc([]f32, n_filters);
        for (filters) |*filter| {
            filter.* = try allocator.alloc(f32, n_bins);
            @memset(filter.*, 0.0);
        }

        // Mel points
        const mel_min = hzToMel(f_min);
        const mel_max = hzToMel(f_max);

        // Create n_filters + 2 points (include edges)
        const n_points = n_filters + 2;
        const mel_points = try allocator.alloc(f32, n_points);
        defer allocator.free(mel_points);

        for (0..n_points) |i| {
            const mel = mel_min + @as(f32, @floatFromInt(i)) * (mel_max - mel_min) / @as(f32, @floatFromInt(n_points - 1));
            mel_points[i] = melToHz(mel);
        }

        // Convert to FFT bin indices
        const bin_freq = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n_fft));

        const bin_points = try allocator.alloc(usize, n_points);
        defer allocator.free(bin_points);

        for (0..n_points) |i| {
            bin_points[i] = @intFromFloat(@floor(mel_points[i] / bin_freq));
        }

        // Create triangular filters
        for (0..n_filters) |m| {
            const left = bin_points[m];
            const center = bin_points[m + 1];
            const right = bin_points[m + 2];

            // Rising edge
            for (left..center) |k| {
                if (k < n_bins and center > left) {
                    filters[m][k] = @as(f32, @floatFromInt(k - left)) /
                        @as(f32, @floatFromInt(center - left));
                }
            }

            // Falling edge
            for (center..right) |k| {
                if (k < n_bins and right > center) {
                    filters[m][k] = @as(f32, @floatFromInt(right - k)) /
                        @as(f32, @floatFromInt(right - center));
                }
            }
        }

        return .{
            .filters = filters,
            .n_filters = n_filters,
            .n_fft = n_fft,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MelFilterbank) void {
        for (self.filters) |filter| {
            self.allocator.free(filter);
        }
        self.allocator.free(self.filters);
    }

    /// Apply filterbank to power spectrum
    pub fn apply(self: *const MelFilterbank, power_spectrum: []const f32, output: []f32) void {
        const n_bins = @min(power_spectrum.len, self.n_fft / 2 + 1);

        for (0..self.n_filters) |m| {
            var sum: f32 = 0.0;
            for (0..n_bins) |k| {
                sum += self.filters[m][k] * power_spectrum[k];
            }
            output[m] = sum;
        }
    }
};

// =============================================================================
// MFCC (Mel-Frequency Cepstral Coefficients)
// =============================================================================

/// MFCC feature extractor
pub const MfccExtractor = struct {
    /// Mel filterbank
    mel_fb: MelFilterbank,

    /// DCT matrix
    dct_matrix: [][]f32,

    /// Number of MFCCs to extract
    n_mfcc: usize,

    /// Work buffer for log mel energies
    mel_energies: []f32,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        n_mfcc: usize,
        n_mels: usize,
        n_fft: usize,
        sample_rate: u32,
    ) !MfccExtractor {
        // Create mel filterbank
        const mel_fb = try MelFilterbank.init(
            allocator,
            n_mels,
            n_fft,
            sample_rate,
            0.0, // f_min
            @as(f32, @floatFromInt(sample_rate)) / 2.0, // f_max
        );

        // Create DCT-II matrix
        const dct_matrix = try allocator.alloc([]f32, n_mfcc);
        for (0..n_mfcc) |k| {
            dct_matrix[k] = try allocator.alloc(f32, n_mels);
            for (0..n_mels) |n| {
                // DCT-II formula
                dct_matrix[k][n] = @cos(math.pi * @as(f32, @floatFromInt(k)) *
                    (@as(f32, @floatFromInt(n)) + 0.5) / @as(f32, @floatFromInt(n_mels)));
            }
        }

        // Normalize
        const scale0 = 1.0 / @sqrt(@as(f32, @floatFromInt(n_mels)));
        const scale_k = @sqrt(2.0 / @as(f32, @floatFromInt(n_mels)));

        for (0..n_mels) |n| {
            dct_matrix[0][n] *= scale0;
        }
        for (1..n_mfcc) |k| {
            for (0..n_mels) |n| {
                dct_matrix[k][n] *= scale_k;
            }
        }

        return .{
            .mel_fb = mel_fb,
            .dct_matrix = dct_matrix,
            .n_mfcc = n_mfcc,
            .mel_energies = try allocator.alloc(f32, n_mels),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MfccExtractor) void {
        self.mel_fb.deinit();
        for (self.dct_matrix) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.dct_matrix);
        self.allocator.free(self.mel_energies);
    }

    /// Compute MFCCs from power spectrum
    pub fn compute(self: *MfccExtractor, power_spectrum: []const f32, output: []f32) void {
        // Apply mel filterbank
        self.mel_fb.apply(power_spectrum, self.mel_energies);

        // Log compression
        for (self.mel_energies) |*e| {
            e.* = @log(@max(e.*, 1e-10));
        }

        // DCT
        const n_out = @min(self.n_mfcc, output.len);
        for (0..n_out) |k| {
            var sum: f32 = 0.0;
            for (0..self.mel_energies.len) |n| {
                sum += self.dct_matrix[k][n] * self.mel_energies[n];
            }
            output[k] = sum;
        }
    }
};

// =============================================================================
// Chroma Features
// =============================================================================

/// Chroma (pitch class) feature extractor
pub const ChromaExtractor = struct {
    /// Chroma filterbank [12][n_bins]
    filters: [12][]f32,

    /// Number of FFT bins
    n_bins: usize,

    /// Base frequency (default: C1 ≈ 32.7 Hz)
    base_freq: f32,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        n_fft: usize,
        sample_rate: u32,
    ) !ChromaExtractor {
        const n_bins = n_fft / 2 + 1;
        const bin_freq = @as(f32, @floatFromInt(sample_rate)) / @as(f32, @floatFromInt(n_fft));

        var self = ChromaExtractor{
            .filters = undefined,
            .n_bins = n_bins,
            .base_freq = 32.7032, // C1
            .allocator = allocator,
        };

        // Initialize filter arrays
        for (0..12) |c| {
            self.filters[c] = try allocator.alloc(f32, n_bins);
            @memset(self.filters[c], 0.0);
        }

        // Build chroma filterbank
        for (1..n_bins) |k| {
            const freq = @as(f32, @floatFromInt(k)) * bin_freq;
            if (freq < 20.0) continue; // Skip very low frequencies

            // Map frequency to pitch class (0-11)
            const pitch = 12.0 * @log2(freq / self.base_freq);
            const pitch_class = @mod(pitch, 12.0);
            const pc_int = @as(usize, @intFromFloat(pitch_class)) % 12;

            // Triangular weighting based on distance from center
            const frac = pitch_class - @as(f32, @floatFromInt(pc_int));
            self.filters[pc_int][k] += 1.0 - frac;
            self.filters[(pc_int + 1) % 12][k] += frac;
        }

        // Normalize each filter
        for (0..12) |c| {
            var sum: f32 = 0.0;
            for (self.filters[c]) |v| {
                sum += v;
            }
            if (sum > 0.0) {
                for (self.filters[c]) |*v| {
                    v.* /= sum;
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *ChromaExtractor) void {
        for (0..12) |c| {
            self.allocator.free(self.filters[c]);
        }
    }

    /// Compute chroma features from magnitude spectrum
    /// Output: 12-element array (C, C#, D, D#, E, F, F#, G, G#, A, A#, B)
    pub fn compute(self: *const ChromaExtractor, magnitudes: []const f32, output: *[12]f32) void {
        for (0..12) |c| {
            var sum: f32 = 0.0;
            const len = @min(magnitudes.len, self.n_bins);
            for (0..len) |k| {
                sum += self.filters[c][k] * magnitudes[k];
            }
            output[c] = sum;
        }

        // Normalize to unit sum
        var total: f32 = 0.0;
        for (output) |v| {
            total += v;
        }
        if (total > 1e-10) {
            for (output) |*v| {
                v.* /= total;
            }
        }
    }

    /// Get pitch class name
    pub fn pitchClassName(index: usize) []const u8 {
        const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
        return names[index % 12];
    }
};

// =============================================================================
// Zero Crossing Rate
// =============================================================================

/// Compute zero crossing rate
pub fn zeroCrossingRate(samples: []const f32) f32 {
    if (samples.len < 2) return 0.0;

    var crossings: usize = 0;
    for (1..samples.len) |i| {
        if ((samples[i] >= 0.0) != (samples[i - 1] >= 0.0)) {
            crossings += 1;
        }
    }

    return @as(f32, @floatFromInt(crossings)) / @as(f32, @floatFromInt(samples.len - 1));
}

// =============================================================================
// RMS Energy
// =============================================================================

/// Compute RMS energy
pub fn rmsEnergy(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;

    var sum: f32 = 0.0;
    for (samples) |s| {
        sum += s * s;
    }

    return @sqrt(sum / @as(f32, @floatFromInt(samples.len)));
}

/// Compute RMS energy in dB
pub fn rmsEnergyDb(samples: []const f32) f32 {
    const rms = rmsEnergy(samples);
    if (rms < 1e-10) return -120.0;
    return 20.0 * @log10(rms);
}

// =============================================================================
// Harmonic Features
// =============================================================================

/// Compute harmonic-to-noise ratio estimate
pub fn harmonicRatio(magnitudes: []const f32, fundamental_bin: usize) f32 {
    if (fundamental_bin == 0 or fundamental_bin >= magnitudes.len) return 0.0;

    var harmonic_energy: f32 = 0.0;
    var total_energy: f32 = 0.0;

    // Sum energy at harmonic frequencies
    var h: usize = 1;
    while (fundamental_bin * h < magnitudes.len) : (h += 1) {
        const bin = fundamental_bin * h;
        // Include nearby bins (±1)
        for (@max(1, bin) - 1..@min(bin + 2, magnitudes.len)) |b| {
            harmonic_energy += magnitudes[b] * magnitudes[b];
        }
    }

    // Total energy
    for (magnitudes) |m| {
        total_energy += m * m;
    }

    if (total_energy < 1e-10) return 0.0;
    return harmonic_energy / total_energy;
}

// =============================================================================
// Tests
// =============================================================================

test "mel scale conversion" {
    const testing = std.testing;

    // Round trip
    const hz: f32 = 1000.0;
    const mel = hzToMel(hz);
    const back = melToHz(mel);
    try testing.expectApproxEqAbs(hz, back, 0.01);

    // 0 Hz = 0 Mel
    try testing.expectApproxEqAbs(@as(f32, 0.0), hzToMel(0.0), 0.001);
}

test "spectral descriptors" {
    const testing = std.testing;

    // Create test spectrum (peak at bin 50)
    var magnitudes: [256]f32 = @as([256]f32, @splat(0.0));
    magnitudes[50] = 1.0;
    magnitudes[49] = 0.5;
    magnitudes[51] = 0.5;

    const desc = computeSpectralDescriptors(&magnitudes, null, 44100);

    // Centroid should be around bin 50
    const expected_centroid = 50.0 * 44100.0 / 512.0;
    try testing.expectApproxEqRel(expected_centroid, desc.centroid, 0.1);
}

test "zero crossing rate" {
    const testing = std.testing;

    // Alternating signal: maximum ZCR
    var alt: [10]f32 = undefined;
    for (0..10) |i| {
        alt[i] = if (i % 2 == 0) 1.0 else -1.0;
    }
    const zcr = zeroCrossingRate(&alt);
    try testing.expectApproxEqAbs(@as(f32, 1.0), zcr, 0.01);

    // Constant signal: zero ZCR
    const constant = @as([10]f32, @splat(1.0));
    try testing.expectApproxEqAbs(@as(f32, 0.0), zeroCrossingRate(&constant), 0.001);
}

test "rms energy" {
    const testing = std.testing;

    // Sine wave RMS = amplitude / sqrt(2)
    var sine: [1000]f32 = undefined;
    for (0..1000) |i| {
        sine[i] = @sin(@as(f32, @floatFromInt(i)) * 0.1);
    }

    const rms = rmsEnergy(&sine);
    const expected = 1.0 / @sqrt(2.0);
    try testing.expectApproxEqAbs(expected, rms, 0.01);
}
