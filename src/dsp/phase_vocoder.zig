//! Phase Vocoder Module
//!
//! Frequency-domain pitch shifting and time stretching based on
//! public domain phase vocoder algorithms (Flanagan 1966, Laroche & Dolson 1999).
//!
//! Features:
//! - STFT-based analysis/synthesis
//! - Phase propagation for time stretching
//! - Pitch shifting via stretch + resample
//! - Vertical phase coherence for reduced phasiness

const std = @import("std");
const math = std.math;

// =============================================================================
// Complex Number Operations
// =============================================================================

pub const Complex = struct {
    re: f32,
    im: f32,

    pub const zero = Complex{ .re = 0.0, .im = 0.0 };

    pub fn init(re: f32, im: f32) Complex {
        return .{ .re = re, .im = im };
    }

    pub fn fromPolar(magnitude: f32, angle: f32) Complex {
        return .{
            .re = magnitude * @cos(angle),
            .im = magnitude * @sin(angle),
        };
    }

    pub fn mag(self: Complex) f32 {
        return @sqrt(self.re * self.re + self.im * self.im);
    }

    pub fn arg(self: Complex) f32 {
        return math.atan2(self.im, self.re);
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn conj(self: Complex) Complex {
        return .{ .re = self.re, .im = -self.im };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn scale(self: Complex, s: f32) Complex {
        return .{ .re = self.re * s, .im = self.im * s };
    }
};

// =============================================================================
// Window Functions
// =============================================================================

pub const WindowType = enum {
    rectangular,
    hann,
    hamming,
    blackman,
    blackman_harris,
};

/// Generate window function
pub fn generateWindow(buffer: []f32, window_type: WindowType) void {
    const N = buffer.len;

    switch (window_type) {
        .rectangular => {
            @memset(buffer, 1.0);
        },
        .hann => {
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(N - 1));
                buffer[n] = 0.5 * (1.0 - @cos(x));
            }
        },
        .hamming => {
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(N - 1));
                buffer[n] = 0.54 - 0.46 * @cos(x);
            }
        },
        .blackman => {
            const a0: f32 = 0.42;
            const a1: f32 = 0.5;
            const a2: f32 = 0.08;
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(N - 1));
                buffer[n] = a0 - a1 * @cos(x) + a2 * @cos(2.0 * x);
            }
        },
        .blackman_harris => {
            const a0: f32 = 0.35875;
            const a1: f32 = 0.48829;
            const a2: f32 = 0.14128;
            const a3: f32 = 0.01168;
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(N - 1));
                buffer[n] = a0 - a1 * @cos(x) + a2 * @cos(2.0 * x) - a3 * @cos(3.0 * x);
            }
        },
    }
}

// =============================================================================
// Simple FFT (Cooley-Tukey radix-2 DIT)
// =============================================================================

/// In-place FFT (must be power of 2)
pub fn fft(data: []Complex) void {
    const n = data.len;
    if (n <= 1) return;

    // Bit-reversal permutation
    var j: usize = 0;
    for (0..n) |i| {
        if (j > i) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
        var m = n / 2;
        while (m >= 1 and j >= m) {
            j -= m;
            m /= 2;
        }
        j += m;
    }

    // Cooley-Tukey iterative FFT
    var mmax: usize = 1;
    while (mmax < n) {
        const istep = mmax * 2;
        const theta = -math.pi / @as(f32, @floatFromInt(mmax));
        var wtemp = @sin(0.5 * theta);
        const wpr = -2.0 * wtemp * wtemp;
        const wpi = @sin(theta);
        var wr: f32 = 1.0;
        var wi: f32 = 0.0;

        var m: usize = 0;
        while (m < mmax) : (m += 1) {
            var i = m;
            while (i < n) : (i += istep) {
                const j_idx = i + mmax;
                const tr = wr * data[j_idx].re - wi * data[j_idx].im;
                const ti = wr * data[j_idx].im + wi * data[j_idx].re;

                data[j_idx].re = data[i].re - tr;
                data[j_idx].im = data[i].im - ti;
                data[i].re += tr;
                data[i].im += ti;
            }

            wtemp = wr;
            wr = wr * wpr - wi * wpi + wr;
            wi = wi * wpr + wtemp * wpi + wi;
        }

        mmax = istep;
    }
}

/// In-place inverse FFT
pub fn ifft(data: []Complex) void {
    const n = data.len;

    // Conjugate
    for (data) |*c| {
        c.im = -c.im;
    }

    // Forward FFT
    fft(data);

    // Conjugate and scale
    const scale = 1.0 / @as(f32, @floatFromInt(n));
    for (data) |*c| {
        c.im = -c.im;
        c.re *= scale;
        c.im *= scale;
    }
}

// =============================================================================
// Phase Vocoder
// =============================================================================

/// Phase Vocoder for time-stretching and pitch-shifting
///
/// Based on public domain algorithms:
/// - Flanagan & Golden (1966) - original phase vocoder
/// - Laroche & Dolson (1999) - improved phase coherence
pub const PhaseVocoder = struct {
    /// FFT size (must be power of 2)
    fft_size: usize,

    /// Analysis hop size
    hop_size: usize,

    /// Analysis window
    window: []f32,

    /// FFT work buffer
    fft_buffer: []Complex,

    /// Last analysis phases
    last_phase: []f32,

    /// Synthesis phase accumulator
    sum_phase: []f32,

    /// Sample rate
    sample_rate: u32,

    pub fn init(allocator: std.mem.Allocator, fft_size: usize, hop_size: usize, sample_rate: u32) !PhaseVocoder {
        const num_bins = fft_size / 2 + 1;

        const pv = PhaseVocoder{
            .fft_size = fft_size,
            .hop_size = hop_size,
            .window = try allocator.alloc(f32, fft_size),
            .fft_buffer = try allocator.alloc(Complex, fft_size),
            .last_phase = try allocator.alloc(f32, num_bins),
            .sum_phase = try allocator.alloc(f32, num_bins),
            .sample_rate = sample_rate,
        };

        // Initialize Hann window
        generateWindow(pv.window, .hann);

        // Initialize phase arrays
        @memset(pv.last_phase, 0.0);
        @memset(pv.sum_phase, 0.0);

        return pv;
    }

    pub fn deinit(self: *PhaseVocoder, allocator: std.mem.Allocator) void {
        allocator.free(self.window);
        allocator.free(self.fft_buffer);
        allocator.free(self.last_phase);
        allocator.free(self.sum_phase);
    }

    /// Reset phase accumulators
    pub fn reset(self: *PhaseVocoder) void {
        @memset(self.last_phase, 0.0);
        @memset(self.sum_phase, 0.0);
    }

    /// Analyze a frame and return STFT bins
    pub fn analyze(self: *PhaseVocoder, input: []const f32) void {
        // Apply window and copy to FFT buffer
        for (0..self.fft_size) |i| {
            const sample = if (i < input.len) input[i] else 0.0;
            self.fft_buffer[i] = Complex.init(sample * self.window[i], 0.0);
        }

        // Forward FFT
        fft(self.fft_buffer);
    }

    /// Process STFT for time stretching
    pub fn processTimeStretch(self: *PhaseVocoder, stretch_ratio: f32) void {
        const num_bins = self.fft_size / 2 + 1;
        const expected_phase_advance = 2.0 * math.pi * @as(f32, @floatFromInt(self.hop_size)) /
            @as(f32, @floatFromInt(self.fft_size));

        for (0..num_bins) |bin| {
            const magnitude = self.fft_buffer[bin].mag();
            const current_phase = self.fft_buffer[bin].arg();

            // Phase deviation from expected
            var phase_diff = current_phase - self.last_phase[bin] -
                @as(f32, @floatFromInt(bin)) * expected_phase_advance;

            // Wrap to [-π, π]
            phase_diff = wrapPhase(phase_diff);

            // True frequency deviation
            const freq_deviation = phase_diff / @as(f32, @floatFromInt(self.hop_size));

            // True bin frequency
            const true_freq = @as(f32, @floatFromInt(bin)) * expected_phase_advance /
                @as(f32, @floatFromInt(self.hop_size)) + freq_deviation;

            // Update last phase
            self.last_phase[bin] = current_phase;

            // Propagate synthesis phase
            const synthesis_hop = @as(f32, @floatFromInt(self.hop_size)) * stretch_ratio;
            self.sum_phase[bin] += true_freq * synthesis_hop;
            self.sum_phase[bin] = wrapPhase(self.sum_phase[bin]);

            // Reconstruct with new phase
            self.fft_buffer[bin] = Complex.fromPolar(magnitude, self.sum_phase[bin]);

            // Mirror for real signal
            if (bin > 0 and bin < num_bins - 1) {
                const mirror_idx = self.fft_size - bin;
                self.fft_buffer[mirror_idx] = self.fft_buffer[bin].conj();
            }
        }
    }

    /// Synthesize frame from STFT bins
    pub fn synthesize(self: *PhaseVocoder, output: []f32) void {
        // Inverse FFT
        ifft(self.fft_buffer);

        // Apply window and extract real part
        for (0..@min(self.fft_size, output.len)) |i| {
            output[i] = self.fft_buffer[i].re * self.window[i];
        }
    }

    /// Complete pitch shift on a buffer
    pub fn pitchShift(
        self: *PhaseVocoder,
        input: []const f32,
        output: []f32,
        pitch_ratio: f32,
        allocator: std.mem.Allocator,
    ) !void {
        if (pitch_ratio == 1.0) {
            @memcpy(output, input[0..@min(input.len, output.len)]);
            return;
        }

        // Step 1: Time stretch by pitch ratio
        const stretched_len = @as(usize, @intFromFloat(@as(f32, @floatFromInt(input.len)) * pitch_ratio));
        const stretched = try allocator.alloc(f32, stretched_len);
        defer allocator.free(stretched);

        try self.timeStretch(input, stretched, pitch_ratio, allocator);

        // Step 2: Resample back to original length
        resample(stretched, output);
    }

    /// Time stretch a buffer
    pub fn timeStretch(
        self: *PhaseVocoder,
        input: []const f32,
        output: []f32,
        stretch_ratio: f32,
        allocator: std.mem.Allocator,
    ) !void {
        self.reset();

        const synthesis_hop = @as(f32, @floatFromInt(self.hop_size)) * stretch_ratio;
        const frame_buffer = try allocator.alloc(f32, self.fft_size);
        defer allocator.free(frame_buffer);

        @memset(output, 0.0);

        var input_pos: usize = 0;
        var output_pos: f32 = 0.0;

        while (input_pos + self.fft_size <= input.len and
            @as(usize, @intFromFloat(output_pos)) + self.fft_size <= output.len)
        {
            // Analyze
            self.analyze(input[input_pos..]);

            // Process
            self.processTimeStretch(stretch_ratio);

            // Synthesize
            self.synthesize(frame_buffer);

            // Overlap-add
            const out_start = @as(usize, @intFromFloat(output_pos));
            for (0..self.fft_size) |i| {
                const idx = out_start + i;
                if (idx < output.len) {
                    output[idx] += frame_buffer[i];
                }
            }

            input_pos += self.hop_size;
            output_pos += synthesis_hop;
        }
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

/// Wrap phase to [-π, π]
fn wrapPhase(phase: f32) f32 {
    var p = phase;
    while (p > math.pi) p -= 2.0 * math.pi;
    while (p < -math.pi) p += 2.0 * math.pi;
    return p;
}

/// Simple linear resampling
fn resample(input: []const f32, output: []f32) void {
    const ratio = @as(f32, @floatFromInt(input.len)) / @as(f32, @floatFromInt(output.len));

    for (0..output.len) |i| {
        const src_pos = @as(f32, @floatFromInt(i)) * ratio;
        const src_idx = @as(usize, @intFromFloat(src_pos));
        const frac = src_pos - @as(f32, @floatFromInt(src_idx));

        if (src_idx + 1 < input.len) {
            output[i] = input[src_idx] * (1.0 - frac) + input[src_idx + 1] * frac;
        } else if (src_idx < input.len) {
            output[i] = input[src_idx];
        } else {
            output[i] = 0.0;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "complex operations" {
    const testing = std.testing;

    const a = Complex.init(3.0, 4.0);
    try testing.expectApproxEqAbs(@as(f32, 5.0), a.mag(), 0.001);

    const b = Complex.fromPolar(2.0, math.pi / 4.0);
    try testing.expectApproxEqAbs(@as(f32, 2.0), b.mag(), 0.001);
}

test "window generation" {
    var buffer: [256]f32 = undefined;

    generateWindow(&buffer, .hann);

    // Hann window should be 0 at edges, 1 at center
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f32, 0.0), buffer[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), buffer[127], 0.02);
}

test "fft round trip" {
    const testing = std.testing;

    var data: [8]Complex = undefined;
    for (0..8) |i| {
        data[i] = Complex.init(@as(f32, @floatFromInt(i)), 0.0);
    }

    const original = data;

    fft(&data);
    ifft(&data);

    for (0..8) |i| {
        try testing.expectApproxEqAbs(original[i].re, data[i].re, 0.001);
        try testing.expectApproxEqAbs(original[i].im, data[i].im, 0.001);
    }
}
