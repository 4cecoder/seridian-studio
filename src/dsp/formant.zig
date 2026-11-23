//! Formant Analysis and Preservation Module
//!
//! Implements LPC (Linear Predictive Coding) based formant analysis
//! for preserving vocal characteristics during pitch shifting.
//!
//! Based on public domain LPC algorithms (Atal, Schroeder 1970s-80s).
//!
//! Key Features:
//! - LPC coefficient extraction via Levinson-Durbin recursion
//! - Formant frequency estimation from LPC roots
//! - Spectral envelope extraction for formant-preserving pitch shift

const std = @import("std");
const math = std.math;

// =============================================================================
// LPC Analysis
// =============================================================================

/// LPC (Linear Predictive Coding) Analyzer
///
/// Extracts LPC coefficients from audio frames for formant analysis.
/// Based on public domain algorithms from Bell Labs (1970s).
pub const LpcAnalyzer = struct {
    /// LPC order (typically 10-16 for speech)
    order: usize,

    /// LPC coefficients
    coefficients: []f32,

    /// Autocorrelation buffer
    autocorr: []f32,

    /// Reflection coefficients (PARCOR)
    reflection: []f32,

    /// Prediction error (gain)
    gain: f32,

    pub fn init(allocator: std.mem.Allocator, order: usize) !LpcAnalyzer {
        return .{
            .order = order,
            .coefficients = try allocator.alloc(f32, order),
            .autocorr = try allocator.alloc(f32, order + 1),
            .reflection = try allocator.alloc(f32, order),
            .gain = 1.0,
        };
    }

    pub fn deinit(self: *LpcAnalyzer, allocator: std.mem.Allocator) void {
        allocator.free(self.coefficients);
        allocator.free(self.autocorr);
        allocator.free(self.reflection);
    }

    /// Analyze a frame and compute LPC coefficients
    /// Uses Levinson-Durbin recursion for efficient coefficient extraction.
    pub fn analyze(self: *LpcAnalyzer, samples: []const f32) void {
        // Pre-emphasis (optional, improves formant estimation)
        // Skip for now, can be added as separate processing step

        // Step 1: Compute autocorrelation
        for (0..self.order + 1) |lag| {
            var sum: f32 = 0.0;
            for (0..samples.len -| lag) |i| {
                sum += samples[i] * samples[i + lag];
            }
            self.autocorr[lag] = sum;
        }

        // Step 2: Levinson-Durbin recursion
        self.levinsonDurbin();
    }

    /// Levinson-Durbin algorithm for solving Toeplitz system
    fn levinsonDurbin(self: *LpcAnalyzer) void {
        // Initialize
        var pred_error = self.autocorr[0];

        if (pred_error < 1e-10) {
            // Silent frame
            @memset(self.coefficients, 0.0);
            @memset(self.reflection, 0.0);
            self.gain = 1.0;
            return;
        }

        for (0..self.order) |i| {
            // Compute reflection coefficient (PARCOR)
            var lambda: f32 = 0.0;
            for (0..i) |j| {
                lambda += self.coefficients[j] * self.autocorr[i - j];
            }
            lambda = (self.autocorr[i + 1] - lambda) / pred_error;

            self.reflection[i] = lambda;

            // Update coefficients
            // a_new[j] = a_old[j] - lambda * a_old[i-j]
            var temp: [32]f32 = @as([32]f32, @splat(0.0));
            for (0..i) |j| {
                temp[j] = self.coefficients[j] - lambda * self.coefficients[i - 1 - j];
            }
            for (0..i) |j| {
                self.coefficients[j] = temp[j];
            }
            self.coefficients[i] = lambda;

            // Update prediction error
            pred_error *= (1.0 - lambda * lambda);
            if (pred_error < 1e-10) break;
        }

        self.gain = @sqrt(pred_error);
    }

    /// Get the spectral envelope at a given normalized frequency (0 to 0.5)
    /// Returns magnitude response of LPC filter
    pub fn getEnvelope(self: *LpcAnalyzer, normalized_freq: f32) f32 {
        // H(z) = G / (1 - Σ a_k z^-k)
        // Evaluate at z = e^(j*2*pi*f)

        const omega = 2.0 * math.pi * normalized_freq;
        var real: f32 = 1.0;
        var imag: f32 = 0.0;

        for (0..self.order) |k| {
            const angle = omega * @as(f32, @floatFromInt(k + 1));
            real -= self.coefficients[k] * @cos(angle);
            imag += self.coefficients[k] * @sin(angle);
        }

        const denominator = @sqrt(real * real + imag * imag);
        if (denominator < 1e-10) return 0.0;

        return self.gain / denominator;
    }

    /// Extract spectral envelope as array
    pub fn extractEnvelope(self: *LpcAnalyzer, output: []f32) void {
        const num_bins = output.len;
        for (0..num_bins) |i| {
            const freq = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_bins * 2));
            output[i] = self.getEnvelope(freq);
        }
    }
};

// =============================================================================
// Formant Tracker
// =============================================================================

/// Tracks formant frequencies over time
pub const FormantTracker = struct {
    /// LPC analyzer
    lpc: LpcAnalyzer,

    /// Sample rate
    sample_rate: u32,

    /// Current formant frequencies (F1, F2, F3, ...)
    formants: [5]f32,

    /// Current formant bandwidths
    bandwidths: [5]f32,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !FormantTracker {
        return .{
            .lpc = try LpcAnalyzer.init(allocator, 12), // 12th order for speech
            .sample_rate = sample_rate,
            .formants = [_]f32{ 500, 1500, 2500, 3500, 4500 }, // Default formants
            .bandwidths = [_]f32{ 100, 100, 150, 200, 200 },
        };
    }

    pub fn deinit(self: *FormantTracker, allocator: std.mem.Allocator) void {
        self.lpc.deinit(allocator);
    }

    /// Update formant tracking from audio frame
    pub fn update(self: *FormantTracker, samples: []const f32) void {
        self.lpc.analyze(samples);
        self.findFormants();
    }

    /// Find formant frequencies from LPC coefficients
    /// Uses peak picking in the spectral envelope
    fn findFormants(self: *FormantTracker) void {
        const num_points = 256;
        var envelope: [256]f32 = undefined;
        self.lpc.extractEnvelope(&envelope);

        // Find peaks in envelope
        var formant_idx: usize = 0;
        var prev_slope: f32 = 0.0;

        for (1..num_points - 1) |i| {
            const slope = envelope[i] - envelope[i - 1];

            // Detect peak (positive to negative slope transition)
            if (prev_slope > 0.0 and slope < 0.0) {
                // Convert bin to frequency
                const freq = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(self.sample_rate)) /
                    @as(f32, @floatFromInt(num_points * 2));

                // Filter to reasonable formant range (200 Hz - 5000 Hz)
                if (freq > 200.0 and freq < 5000.0) {
                    if (formant_idx < self.formants.len) {
                        self.formants[formant_idx] = freq;
                        formant_idx += 1;
                    }
                }
            }

            prev_slope = slope;
        }
    }

    /// Get current formant frequencies
    pub fn getFormants(self: *FormantTracker) []const f32 {
        return &self.formants;
    }
};

// =============================================================================
// Formant-Preserving Pitch Shifter
// =============================================================================

/// Pitch shifter with formant preservation
///
/// Uses LPC to separate excitation from spectral envelope,
/// shifts pitch of excitation, then reapplies original envelope.
pub const FormantPreservingShifter = struct {
    /// LPC analyzer
    lpc: LpcAnalyzer,

    /// Sample rate
    sample_rate: u32,

    /// Frame size
    frame_size: usize,

    /// Residual buffer (inverse filtered signal)
    residual: []f32,

    /// Synthesis buffer
    synthesis: []f32,

    pub fn init(allocator: std.mem.Allocator, frame_size: usize, sample_rate: u32) !FormantPreservingShifter {
        return .{
            .lpc = try LpcAnalyzer.init(allocator, 12),
            .sample_rate = sample_rate,
            .frame_size = frame_size,
            .residual = try allocator.alloc(f32, frame_size),
            .synthesis = try allocator.alloc(f32, frame_size),
        };
    }

    pub fn deinit(self: *FormantPreservingShifter, allocator: std.mem.Allocator) void {
        self.lpc.deinit(allocator);
        allocator.free(self.residual);
        allocator.free(self.synthesis);
    }

    /// Process a frame with formant-preserving pitch shift
    ///
    /// Algorithm:
    /// 1. Analyze LPC coefficients (captures formants)
    /// 2. Inverse filter to get residual (pitch information)
    /// 3. Pitch shift the residual
    /// 4. Re-synthesize with original LPC filter
    pub fn process(
        self: *FormantPreservingShifter,
        input: []const f32,
        output: []f32,
        pitch_ratio: f32,
    ) void {
        const len = @min(input.len, self.frame_size);

        // Step 1: LPC analysis
        self.lpc.analyze(input[0..len]);

        // Step 2: Inverse filter (LPC analysis filter)
        // e[n] = x[n] - Σ a[k] * x[n-k]
        self.inverseFilter(input[0..len], self.residual[0..len]);

        // Step 3: Pitch shift the residual using simple resampling
        // For higher quality, use PSOLA or phase vocoder on residual
        self.pitchShiftResidual(pitch_ratio, len);

        // Step 4: LPC synthesis filter
        // y[n] = e[n] + Σ a[k] * y[n-k]
        self.synthesisFilter(self.residual[0..len], output[0..len]);
    }

    /// LPC inverse (analysis) filter
    fn inverseFilter(self: *FormantPreservingShifter, input: []const f32, output: []f32) void {
        for (0..output.len) |n| {
            var sum: f32 = input[n];

            for (0..self.lpc.order) |k| {
                if (n > k) {
                    sum -= self.lpc.coefficients[k] * input[n - k - 1];
                }
            }

            output[n] = sum;
        }
    }

    /// LPC synthesis filter
    fn synthesisFilter(self: *FormantPreservingShifter, input: []const f32, output: []f32) void {
        for (0..output.len) |n| {
            var sum: f32 = input[n];

            for (0..self.lpc.order) |k| {
                if (n > k) {
                    sum += self.lpc.coefficients[k] * output[n - k - 1];
                }
            }

            output[n] = sum;
        }
    }

    /// Simple pitch shift of residual via resampling
    fn pitchShiftResidual(self: *FormantPreservingShifter, pitch_ratio: f32, len: usize) void {
        // Create temporary copy
        var temp: [4096]f32 = @as([4096]f32, @splat(0.0));
        const copy_len = @min(len, temp.len);
        @memcpy(temp[0..copy_len], self.residual[0..copy_len]);

        // Resample
        for (0..len) |i| {
            const src_pos = @as(f32, @floatFromInt(i)) * pitch_ratio;
            const src_idx = @as(usize, @intFromFloat(src_pos));
            const frac = src_pos - @as(f32, @floatFromInt(src_idx));

            if (src_idx + 1 < len) {
                self.residual[i] = temp[src_idx] * (1.0 - frac) + temp[src_idx + 1] * frac;
            } else if (src_idx < len) {
                self.residual[i] = temp[src_idx];
            } else {
                self.residual[i] = 0.0;
            }
        }
    }
};

// =============================================================================
// Pre-Emphasis and De-Emphasis Filters
// =============================================================================

/// Pre-emphasis filter (boosts high frequencies)
/// y[n] = x[n] - α * x[n-1]
pub fn preEmphasis(input: []const f32, output: []f32, alpha: f32) void {
    if (input.len == 0) return;

    output[0] = input[0];
    for (1..input.len) |i| {
        output[i] = input[i] - alpha * input[i - 1];
    }
}

/// De-emphasis filter (inverse of pre-emphasis)
/// y[n] = x[n] + α * y[n-1]
pub fn deEmphasis(input: []const f32, output: []f32, alpha: f32) void {
    if (input.len == 0) return;

    output[0] = input[0];
    for (1..input.len) |i| {
        output[i] = input[i] + alpha * output[i - 1];
    }
}

// =============================================================================
// Tests
// =============================================================================

test "LPC analysis" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lpc = try LpcAnalyzer.init(allocator, 10);
    defer lpc.deinit(allocator);

    // Create simple test signal
    var samples: [256]f32 = undefined;
    for (0..256) |i| {
        const t = @as(f32, @floatFromInt(i)) / 256.0;
        samples[i] = @sin(2.0 * math.pi * 440.0 * t) * 0.5;
    }

    lpc.analyze(&samples);

    // Coefficients should be computed
    // Check that gain is reasonable
    try testing.expect(lpc.gain > 0.0);
    try testing.expect(lpc.gain < 10.0);
}

test "pre-emphasis round trip" {
    const testing = std.testing;

    var input: [100]f32 = undefined;
    var emphasized: [100]f32 = undefined;
    var recovered: [100]f32 = undefined;

    // Create test signal
    for (0..100) |i| {
        input[i] = @sin(@as(f32, @floatFromInt(i)) * 0.1);
    }

    const alpha: f32 = 0.97;
    preEmphasis(&input, &emphasized, alpha);
    deEmphasis(&emphasized, &recovered, alpha);

    // Should approximately recover original (with some edge effects)
    for (5..95) |i| {
        try testing.expectApproxEqAbs(input[i], recovered[i], 0.01);
    }
}

test "formant tracker initialization" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tracker = try FormantTracker.init(allocator, 44100);
    defer tracker.deinit(allocator);

    const formants = tracker.getFormants();
    const testing = std.testing;
    try testing.expect(formants.len == 5);
}
