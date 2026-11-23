//! Core DSP Utilities
//!
//! Fundamental building blocks for audio signal processing:
//! - Ring buffers (lock-free, real-time safe)
//! - Window functions (Hann, Hamming, Blackman, Kaiser, etc.)
//! - Interpolation (linear, cubic, sinc)
//! - Sample format conversion
//! - Decibel/linear conversion
//! - Frequency/MIDI utilities
//!
//! All components are designed for zero-allocation real-time use.

const std = @import("std");
const math = std.math;
const dsp = @import("dsp.zig");

// =============================================================================
// Ring Buffer
// =============================================================================

/// Lock-free ring buffer for real-time audio
/// Suitable for delay lines, circular convolution, and inter-thread communication
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        write_pos: usize = 0,
        read_pos: usize = 0,
        mask: usize,

        /// Create ring buffer with power-of-2 size
        /// Caller owns the buffer memory
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            std.debug.assert((buffer.len & (buffer.len - 1)) == 0); // Power of 2

            return .{
                .buffer = buffer,
                .mask = buffer.len - 1,
            };
        }

        /// Write a single sample
        pub fn write(self: *Self, sample: T) void {
            self.buffer[self.write_pos] = sample;
            self.write_pos = (self.write_pos + 1) & self.mask;
        }

        /// Read a single sample and advance read position
        pub fn read(self: *Self) T {
            const sample = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) & self.mask;
            return sample;
        }

        /// Read sample at offset from write position (for delay lines)
        /// delay_samples = 0 returns most recent sample
        pub fn readDelay(self: *const Self, delay_samples: usize) T {
            const idx = (self.write_pos -% delay_samples -% 1) & self.mask;
            return self.buffer[idx];
        }

        /// Read with fractional delay using linear interpolation
        pub fn readDelayLinear(self: *const Self, delay_samples: f32) T {
            const delay_int = @as(usize, @intFromFloat(delay_samples));
            const frac = delay_samples - @as(f32, @floatFromInt(delay_int));

            const s0 = self.readDelay(delay_int);
            const s1 = self.readDelay(delay_int + 1);

            // Linear interpolation inline
            return s0 + (s1 - s0) * frac;
        }

        /// Read with fractional delay using cubic interpolation (higher quality)
        pub fn readDelayCubic(self: *const Self, delay_samples: f32) T {
            const delay_int = @as(usize, @intFromFloat(delay_samples));
            const frac = delay_samples - @as(f32, @floatFromInt(delay_int));

            // Get 4 samples for cubic interpolation
            const y0 = self.readDelay(delay_int + 1);
            const y1 = self.readDelay(delay_int);
            const y2 = self.readDelay(if (delay_int > 0) delay_int - 1 else 0);
            const y3 = self.readDelay(if (delay_int > 1) delay_int - 2 else 0);

            return cubicInterpolate(y0, y1, y2, y3, frac);
        }

        /// Write block of samples
        pub fn writeBlock(self: *Self, samples: []const T) void {
            for (samples) |s| {
                self.write(s);
            }
        }

        /// Read block of samples
        pub fn readBlock(self: *Self, output: []T) void {
            for (output) |*s| {
                s.* = self.read();
            }
        }

        /// Clear buffer to zero
        pub fn clear(self: *Self) void {
            @memset(self.buffer, 0);
            self.write_pos = 0;
            self.read_pos = 0;
        }

        /// Get number of samples available to read
        pub fn available(self: *const Self) usize {
            return (self.write_pos -% self.read_pos) & self.mask;
        }

        /// Get buffer capacity
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }
    };
}

// =============================================================================
// Delay Line (specialized ring buffer)
// =============================================================================

/// Simple delay line with configurable maximum delay
pub fn DelayLine(comptime T: type) type {
    return struct {
        const Self = @This();

        ring: RingBuffer(T),
        delay_samples: usize,

        pub fn init(buffer: []T, initial_delay: usize) Self {
            var self = Self{
                .ring = RingBuffer(T).init(buffer),
                .delay_samples = @min(initial_delay, buffer.len - 1),
            };
            self.ring.clear();
            return self;
        }

        /// Process one sample through delay line
        pub fn process(self: *Self, input: T) T {
            const output = self.ring.readDelay(self.delay_samples);
            self.ring.write(input);
            return output;
        }

        /// Process with fractional delay (linear interpolation)
        pub fn processLinear(self: *Self, input: T, delay: f32) T {
            const output = self.ring.readDelayLinear(delay);
            self.ring.write(input);
            return output;
        }

        /// Set delay in samples
        pub fn setDelay(self: *Self, samples: usize) void {
            self.delay_samples = @min(samples, self.ring.capacity() - 1);
        }

        /// Set delay in milliseconds
        pub fn setDelayMs(self: *Self, ms: f32, sample_rate: u32) void {
            const samples = @as(usize, @intFromFloat(ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0));
            self.setDelay(samples);
        }
    };
}

// =============================================================================
// Window Functions
// =============================================================================

/// Window function types
pub const WindowType = enum {
    rectangular,
    hann,
    hamming,
    blackman,
    blackman_harris,
    kaiser,
    triangular,
    gaussian,
    tukey,
};

/// Generate window function into buffer
pub fn generateWindow(buffer: []f32, window_type: WindowType) void {
    generateWindowWithParam(buffer, window_type, 0.5);
}

/// Generate window function with parameter (for Kaiser beta, Gaussian sigma, Tukey alpha)
pub fn generateWindowWithParam(buffer: []f32, window_type: WindowType, param: f32) void {
    const N = buffer.len;
    const n_f = @as(f32, @floatFromInt(N));

    switch (window_type) {
        .rectangular => {
            @memset(buffer, 1.0);
        },
        .hann => {
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / (n_f - 1.0);
                buffer[n] = 0.5 * (1.0 - @cos(x));
            }
        },
        .hamming => {
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / (n_f - 1.0);
                buffer[n] = 0.54 - 0.46 * @cos(x);
            }
        },
        .blackman => {
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / (n_f - 1.0);
                buffer[n] = 0.42 - 0.5 * @cos(x) + 0.08 * @cos(2.0 * x);
            }
        },
        .blackman_harris => {
            const a0: f32 = 0.35875;
            const a1: f32 = 0.48829;
            const a2: f32 = 0.14128;
            const a3: f32 = 0.01168;
            for (0..N) |n| {
                const x = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / (n_f - 1.0);
                buffer[n] = a0 - a1 * @cos(x) + a2 * @cos(2.0 * x) - a3 * @cos(3.0 * x);
            }
        },
        .kaiser => {
            const beta = param * math.pi; // Typical: 5-14
            const denom = besselI0(beta);
            for (0..N) |n| {
                const t = 2.0 * @as(f32, @floatFromInt(n)) / (n_f - 1.0) - 1.0;
                const arg = beta * @sqrt(1.0 - t * t);
                buffer[n] = besselI0(arg) / denom;
            }
        },
        .triangular => {
            const half = (n_f - 1.0) / 2.0;
            for (0..N) |n| {
                buffer[n] = 1.0 - @abs((@as(f32, @floatFromInt(n)) - half) / half);
            }
        },
        .gaussian => {
            const sigma = param; // Typical: 0.3-0.5
            const center = (n_f - 1.0) / 2.0;
            for (0..N) |n| {
                const t = (@as(f32, @floatFromInt(n)) - center) / (sigma * center);
                buffer[n] = @exp(-0.5 * t * t);
            }
        },
        .tukey => {
            const alpha = param; // 0 = rectangular, 1 = Hann
            const taper_len = @as(usize, @intFromFloat(alpha * n_f / 2.0));

            for (0..N) |n| {
                if (n < taper_len) {
                    const x = math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(taper_len));
                    buffer[n] = 0.5 * (1.0 - @cos(x));
                } else if (n >= N - taper_len) {
                    const x = math.pi * @as(f32, @floatFromInt(n - (N - taper_len))) / @as(f32, @floatFromInt(taper_len));
                    buffer[n] = 0.5 * (1.0 + @cos(x));
                } else {
                    buffer[n] = 1.0;
                }
            }
        },
    }
}

/// Compute window sum for overlap-add normalization
pub fn windowSum(buffer: []const f32, hop_size: usize) f32 {
    var sum: f32 = 0.0;
    const num_windows = (buffer.len + hop_size - 1) / hop_size;

    for (0..buffer.len) |i| {
        var accum: f32 = 0.0;
        for (0..num_windows) |w| {
            const offset = w * hop_size;
            if (i >= offset and i < offset + buffer.len) {
                const idx = i - offset;
                if (idx < buffer.len) {
                    accum += buffer[idx] * buffer[idx];
                }
            }
        }
        sum = @max(sum, accum);
    }

    return @sqrt(sum);
}

// =============================================================================
// Interpolation Functions
// =============================================================================

/// Cubic Hermite interpolation (4-point, 3rd order)
pub fn cubicInterpolate(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) f32 {
    const a0 = y3 - y2 - y0 + y1;
    const a1 = y0 - y1 - a0;
    const a2 = y2 - y0;
    const a3 = y1;

    return a0 * t * t * t + a1 * t * t + a2 * t + a3;
}

/// Catmull-Rom spline interpolation
pub fn catmullRomInterpolate(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) f32 {
    const t2 = t * t;
    const t3 = t2 * t;

    return 0.5 * ((2.0 * y1) +
        (-y0 + y2) * t +
        (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t2 +
        (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t3);
}

/// Sinc function
pub fn sinc(x: f32) f32 {
    if (@abs(x) < 1e-6) return 1.0;
    const px = math.pi * x;
    return @sin(px) / px;
}

/// Windowed sinc for high-quality resampling
pub fn windowedSinc(x: f32, window_size: usize) f32 {
    const w = @as(f32, @floatFromInt(window_size));
    if (@abs(x) > w / 2.0) return 0.0;

    // Blackman window
    const t = x / (w / 2.0);
    const window = 0.42 + 0.5 * @cos(math.pi * t) + 0.08 * @cos(2.0 * math.pi * t);

    return sinc(x) * window;
}

// =============================================================================
// Decibel Conversion
// =============================================================================

/// Convert linear power to decibels
pub fn powerToDb(power: f32) f32 {
    if (power <= 0.0) return -120.0;
    return 10.0 * @log10(power);
}

/// Convert decibels to linear power
pub fn dbToPower(db: f32) f32 {
    return math.pow(f32, 10.0, db / 10.0);
}

// =============================================================================
// Frequency Utilities
// =============================================================================

pub const A4_FREQ: f32 = 440.0;
pub const A4_MIDI: u8 = 69;

/// Convert MIDI note to frequency
pub fn midiToFreq(midi: f32) f32 {
    return A4_FREQ * math.pow(f32, 2.0, (midi - @as(f32, A4_MIDI)) / 12.0);
}

/// Convert frequency to MIDI note
pub fn freqToMidi(freq: f32) f32 {
    if (freq <= 0.0) return 0.0;
    return @as(f32, A4_MIDI) + 12.0 * @log2(freq / A4_FREQ);
}

/// Convert frequency to period in samples
pub fn freqToPeriod(freq: f32, sample_rate: u32) f32 {
    if (freq <= 0.0) return 0.0;
    return @as(f32, @floatFromInt(sample_rate)) / freq;
}

/// Convert period in samples to frequency
pub fn periodToFreq(period: f32, sample_rate: u32) f32 {
    if (period <= 0.0) return 0.0;
    return @as(f32, @floatFromInt(sample_rate)) / period;
}

// =============================================================================
// Smoothing / Parameter Interpolation
// =============================================================================

/// One-pole smoother for parameter changes
pub const OnePoleSmoother = struct {
    current: f32 = 0.0,
    target: f32 = 0.0,
    coeff: f32 = 0.0,

    /// Initialize with time constant
    pub fn init(time_ms: f32, sample_rate: u32) OnePoleSmoother {
        return .{
            .coeff = calculateCoeff(time_ms, sample_rate),
        };
    }

    /// Set new target value
    pub fn setTarget(self: *OnePoleSmoother, target: f32) void {
        self.target = target;
    }

    /// Set target and immediately jump to it
    pub fn setImmediate(self: *OnePoleSmoother, value: f32) void {
        self.target = value;
        self.current = value;
    }

    /// Process one sample
    pub fn process(self: *OnePoleSmoother) f32 {
        self.current += self.coeff * (self.target - self.current);
        return self.current;
    }

    /// Update time constant
    pub fn setTime(self: *OnePoleSmoother, time_ms: f32, sample_rate: u32) void {
        self.coeff = calculateCoeff(time_ms, sample_rate);
    }

    fn calculateCoeff(time_ms: f32, sample_rate: u32) f32 {
        if (time_ms <= 0.0) return 1.0;
        // Convert milliseconds to samples inline
        const samples = time_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0;
        return 1.0 - @exp(-1.0 / samples);
    }
};

/// Linear ramp for sample-accurate automation
pub const LinearRamp = struct {
    current: f32 = 0.0,
    target: f32 = 0.0,
    increment: f32 = 0.0,
    samples_remaining: usize = 0,

    pub fn init(initial_value: f32) LinearRamp {
        return .{ .current = initial_value, .target = initial_value };
    }

    /// Start ramping to target over given number of samples
    pub fn rampTo(self: *LinearRamp, target: f32, samples: usize) void {
        self.target = target;
        if (samples == 0) {
            self.current = target;
            self.increment = 0.0;
            self.samples_remaining = 0;
        } else {
            self.increment = (target - self.current) / @as(f32, @floatFromInt(samples));
            self.samples_remaining = samples;
        }
    }

    /// Process one sample
    pub fn process(self: *LinearRamp) f32 {
        if (self.samples_remaining > 0) {
            self.current += self.increment;
            self.samples_remaining -= 1;
            if (self.samples_remaining == 0) {
                self.current = self.target;
            }
        }
        return self.current;
    }

    /// Check if ramp is complete
    pub fn isComplete(self: *const LinearRamp) bool {
        return self.samples_remaining == 0;
    }
};

// =============================================================================
// Clipping and Saturation
// =============================================================================

/// Hard clip to range [-1, 1]
pub fn hardClip(x: f32) f32 {
    return math.clamp(x, -1.0, 1.0);
}

/// Soft clip using tanh
pub fn softClipTanh(x: f32) f32 {
    return math.tanh(x);
}

/// Soft clip using polynomial (faster than tanh)
pub fn softClipPoly(x: f32) f32 {
    if (x > 1.0) return 1.0 - 1.0 / (x + 1.0);
    if (x < -1.0) return -1.0 + 1.0 / (-x + 1.0);
    return x;
}

/// Asymmetric soft clip (tube-like)
pub fn softClipAsymmetric(x: f32, drive: f32) f32 {
    const k = 2.0 * drive / (1.0 - drive);
    return (1.0 + k) * x / (1.0 + k * @abs(x));
}

// =============================================================================
// Special Functions
// =============================================================================

/// Modified Bessel function of first kind, order 0 (for Kaiser window)
pub fn besselI0(x: f32) f32 {
    var sum: f32 = 1.0;
    var term: f32 = 1.0;
    const x2 = x * x / 4.0;

    var k: f32 = 1.0;
    while (k < 20.0) : (k += 1.0) {
        term *= x2 / (k * k);
        sum += term;
        if (term < 1e-10) break;
    }

    return sum;
}

// =============================================================================
// Tests
// =============================================================================

test "ring buffer basic operations" {
    const testing = std.testing;
    var buffer: [8]f32 = undefined;
    var ring = RingBuffer(f32).init(&buffer);

    ring.write(1.0);
    ring.write(2.0);
    ring.write(3.0);

    try testing.expectEqual(@as(usize, 3), ring.available());
    try testing.expectApproxEqAbs(@as(f32, 1.0), ring.read(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), ring.read(), 0.001);
}

test "ring buffer delay read" {
    const testing = std.testing;
    var buffer: [16]f32 = undefined;
    var ring = RingBuffer(f32).init(&buffer);

    for (0..10) |i| {
        ring.write(@floatFromInt(i));
    }

    // Most recent is 9, delay 0 should be 9
    try testing.expectApproxEqAbs(@as(f32, 9.0), ring.readDelay(0), 0.001);
    // Delay 5 should be 4
    try testing.expectApproxEqAbs(@as(f32, 4.0), ring.readDelay(5), 0.001);
}

test "window functions" {
    const testing = std.testing;
    var buffer: [64]f32 = undefined;

    // Hann window should be 0 at edges
    generateWindow(&buffer, .hann);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buffer[0], 0.001);
    try testing.expect(buffer[32] > 0.99);

    // Hamming window should be ~0.08 at edges
    generateWindow(&buffer, .hamming);
    try testing.expectApproxEqAbs(@as(f32, 0.08), buffer[0], 0.01);
}

test "sinc function" {
    const testing = std.testing;

    // Sinc at 0 should be 1
    try testing.expectApproxEqAbs(@as(f32, 1.0), sinc(0.0), 0.001);
}

test "one pole smoother" {
    var smoother = OnePoleSmoother.init(10.0, 44100);
    smoother.setImmediate(0.0);
    smoother.setTarget(1.0);

    // After many iterations, should approach target
    for (0..10000) |_| {
        _ = smoother.process();
    }

    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f32, 1.0), smoother.current, 0.01);
}
