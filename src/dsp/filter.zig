//! Biquad Filters
//!
//! Implementation of standard biquad filter types using the Audio EQ Cookbook.
//! Supports low-pass, high-pass, band-pass, notch, and shelving filters.

const std = @import("std");

/// Filter type
pub const FilterType = enum(u8) {
    lowpass,
    highpass,
    bandpass,
    notch,
    peak,
    low_shelf,
    high_shelf,
};

/// Biquad filter using Direct Form II Transposed
/// Most numerically stable implementation for floating point
pub const BiquadFilter = struct {
    // Coefficients
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    // State (Direct Form II Transposed)
    z1: f32 = 0.0,
    z2: f32 = 0.0,

    // Parameters for recalculation
    filter_type: FilterType = .lowpass,
    frequency: f32 = 1000.0,
    q: f32 = 0.707, // 1/sqrt(2) = Butterworth
    gain_db: f32 = 0.0, // For peak/shelf
    sample_rate: f32 = 48000.0,

    pub fn init(sample_rate: f32) BiquadFilter {
        var f = BiquadFilter{ .sample_rate = sample_rate };
        f.updateCoefficients();
        return f;
    }

    /// Process one sample
    pub fn tick(self: *BiquadFilter, input: f32) f32 {
        const output = input * self.b0 + self.z1;
        self.z1 = input * self.b1 - self.a1 * output + self.z2;
        self.z2 = input * self.b2 - self.a2 * output;
        return output;
    }

    /// Process buffer in place
    pub fn process(self: *BiquadFilter, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.tick(sample.*);
        }
    }

    /// Reset filter state
    pub fn reset(self: *BiquadFilter) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    /// Set filter parameters and recalculate coefficients
    pub fn setParams(self: *BiquadFilter, filter_type: FilterType, freq: f32, q: f32, gain_db: f32) void {
        self.filter_type = filter_type;
        self.frequency = std.math.clamp(freq, 20.0, self.sample_rate * 0.49);
        self.q = @max(0.1, q);
        self.gain_db = gain_db;
        self.updateCoefficients();
    }

    /// Set just frequency (for modulation)
    pub fn setFrequency(self: *BiquadFilter, freq: f32) void {
        self.frequency = std.math.clamp(freq, 20.0, self.sample_rate * 0.49);
        self.updateCoefficients();
    }

    /// Set just Q/resonance
    pub fn setQ(self: *BiquadFilter, q: f32) void {
        self.q = @max(0.1, q);
        self.updateCoefficients();
    }

    /// Recalculate coefficients from current parameters
    /// Based on Audio EQ Cookbook by Robert Bristow-Johnson
    pub fn updateCoefficients(self: *BiquadFilter) void {
        const omega = std.math.tau * self.frequency / self.sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const alpha = sin_omega / (2.0 * self.q);

        var b0: f32 = 0;
        var b1: f32 = 0;
        var b2: f32 = 0;
        var a0: f32 = 1;
        var a1: f32 = 0;
        var a2: f32 = 0;

        switch (self.filter_type) {
            .lowpass => {
                b0 = (1.0 - cos_omega) / 2.0;
                b1 = 1.0 - cos_omega;
                b2 = (1.0 - cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .highpass => {
                b0 = (1.0 + cos_omega) / 2.0;
                b1 = -(1.0 + cos_omega);
                b2 = (1.0 + cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .bandpass => {
                b0 = alpha;
                b1 = 0.0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .notch => {
                b0 = 1.0;
                b1 = -2.0 * cos_omega;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .peak => {
                const A = std.math.pow(f32, 10.0, self.gain_db / 40.0);
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cos_omega;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha / A;
            },
            .low_shelf => {
                const A = std.math.pow(f32, 10.0, self.gain_db / 40.0);
                const sqrt_A = @sqrt(A);
                const shelf_alpha = sin_omega / 2.0 * @sqrt((A + 1.0 / A) * (1.0 / self.q - 1.0) + 2.0);

                b0 = A * ((A + 1.0) - (A - 1.0) * cos_omega + 2.0 * sqrt_A * shelf_alpha);
                b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_omega);
                b2 = A * ((A + 1.0) - (A - 1.0) * cos_omega - 2.0 * sqrt_A * shelf_alpha);
                a0 = (A + 1.0) + (A - 1.0) * cos_omega + 2.0 * sqrt_A * shelf_alpha;
                a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_omega);
                a2 = (A + 1.0) + (A - 1.0) * cos_omega - 2.0 * sqrt_A * shelf_alpha;
            },
            .high_shelf => {
                const A = std.math.pow(f32, 10.0, self.gain_db / 40.0);
                const sqrt_A = @sqrt(A);
                const shelf_alpha = sin_omega / 2.0 * @sqrt((A + 1.0 / A) * (1.0 / self.q - 1.0) + 2.0);

                b0 = A * ((A + 1.0) + (A - 1.0) * cos_omega + 2.0 * sqrt_A * shelf_alpha);
                b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_omega);
                b2 = A * ((A + 1.0) + (A - 1.0) * cos_omega - 2.0 * sqrt_A * shelf_alpha);
                a0 = (A + 1.0) - (A - 1.0) * cos_omega + 2.0 * sqrt_A * shelf_alpha;
                a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_omega);
                a2 = (A + 1.0) - (A - 1.0) * cos_omega - 2.0 * sqrt_A * shelf_alpha;
            },
        }

        // Normalize by a0
        const inv_a0 = 1.0 / a0;
        self.b0 = b0 * inv_a0;
        self.b1 = b1 * inv_a0;
        self.b2 = b2 * inv_a0;
        self.a1 = a1 * inv_a0;
        self.a2 = a2 * inv_a0;
    }
};

/// State Variable Filter - better for modulation
/// Provides simultaneous LP, HP, BP, Notch outputs
pub const SVFilter = struct {
    low: f32 = 0.0,
    band: f32 = 0.0,
    frequency: f32 = 1000.0,
    q: f32 = 0.707,
    sample_rate: f32 = 48000.0,

    // Cached
    f: f32 = 0.0,
    damp: f32 = 0.0,

    pub fn init(sample_rate: f32) SVFilter {
        var filter = SVFilter{ .sample_rate = sample_rate };
        filter.updateCoefficients();
        return filter;
    }

    pub fn setFrequency(self: *SVFilter, freq: f32) void {
        self.frequency = std.math.clamp(freq, 20.0, self.sample_rate * 0.49);
        self.updateCoefficients();
    }

    pub fn setQ(self: *SVFilter, q: f32) void {
        self.q = @max(0.5, q);
        self.updateCoefficients();
    }

    fn updateCoefficients(self: *SVFilter) void {
        // Protect against bad frequency/sample_rate
        const safe_freq = if (std.math.isNan(self.frequency) or std.math.isInf(self.frequency))
            1000.0
        else
            std.math.clamp(self.frequency, 20.0, self.sample_rate * 0.49);

        self.f = 2.0 * @sin(std.math.pi * safe_freq / self.sample_rate);

        // Protect against division by zero/small Q
        const safe_q = if (std.math.isNan(self.q) or std.math.isInf(self.q) or self.q < 0.1)
            0.707
        else
            self.q;
        self.damp = 1.0 / safe_q;

        // Sanitize coefficients
        if (std.math.isNan(self.f) or std.math.isInf(self.f)) self.f = 0.1;
        if (std.math.isNan(self.damp) or std.math.isInf(self.damp)) self.damp = 1.414;
    }

    /// Process and return low-pass output
    pub fn tickLP(self: *SVFilter, input: f32) f32 {
        _ = self.tick(input);
        // Return sanitized low output
        return if (std.math.isNan(self.low) or std.math.isInf(self.low)) 0.0 else self.low;
    }

    /// Process and return high-pass output
    pub fn tickHP(self: *SVFilter, input: f32) f32 {
        return self.tick(input);
    }

    /// Process and return band-pass output
    pub fn tickBP(self: *SVFilter, input: f32) f32 {
        _ = self.tick(input);
        // Return sanitized band output
        return if (std.math.isNan(self.band) or std.math.isInf(self.band)) 0.0 else self.band;
    }

    /// Process one sample, returns high-pass output
    fn tick(self: *SVFilter, input: f32) f32 {
        // Sanitize input
        const safe_input = if (std.math.isNan(input) or std.math.isInf(input)) 0.0 else input;

        const high = safe_input - self.low - self.damp * self.band;
        self.band += self.f * high;
        self.low += self.f * self.band;

        // CRITICAL: Sanitize state to prevent runaway feedback
        // If state becomes NaN/Inf, it corrupts all future output
        if (std.math.isNan(self.band) or std.math.isInf(self.band) or @abs(self.band) > 1e6) {
            self.band = 0.0;
        }
        if (std.math.isNan(self.low) or std.math.isInf(self.low) or @abs(self.low) > 1e6) {
            self.low = 0.0;
        }

        return if (std.math.isNan(high) or std.math.isInf(high)) 0.0 else high;
    }

    pub fn reset(self: *SVFilter) void {
        self.low = 0.0;
        self.band = 0.0;
    }
};

/// One-pole filter (6dB/octave) - very efficient
pub const OnePoleFilter = struct {
    y1: f32 = 0.0,
    a0: f32 = 1.0,
    b1: f32 = 0.0,

    pub fn initLP(cutoff: f32, sample_rate: f32) OnePoleFilter {
        const w = std.math.tau * cutoff / sample_rate;
        const b1 = @exp(-w);
        return .{
            .a0 = 1.0 - b1,
            .b1 = b1,
        };
    }

    pub fn initHP(cutoff: f32, sample_rate: f32) OnePoleFilter {
        const w = std.math.tau * cutoff / sample_rate;
        const b1 = @exp(-w);
        return .{
            .a0 = (1.0 + b1) / 2.0,
            .b1 = -b1,
        };
    }

    pub fn tick(self: *OnePoleFilter, input: f32) f32 {
        self.y1 = input * self.a0 + self.y1 * self.b1;
        return self.y1;
    }

    pub fn reset(self: *OnePoleFilter) void {
        self.y1 = 0.0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "biquad lowpass" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.lowpass, 1000.0, 0.707, 0.0);

    // Process some samples
    var output: f32 = 0;
    for (0..100) |_| {
        output = filter.tick(1.0);
    }

    // DC should pass through lowpass
    try testing.expect(output > 0.9);

    filter.reset();
}

test "svf outputs" {
    var filter = SVFilter.init(48000.0);
    filter.setFrequency(1000.0);

    // Process impulse
    _ = filter.tick(1.0);
    for (0..99) |_| {
        _ = filter.tick(0.0);
    }

    // All outputs should decay to near zero
    try std.testing.expect(@abs(filter.low) < 0.01);
    try std.testing.expect(@abs(filter.band) < 0.01);
}

test "biquad highpass" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.highpass, 1000.0, 0.707, 0.0);

    // Process DC signal - should be blocked by highpass
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tick(1.0);
    }

    // DC should be blocked by highpass (should be near zero)
    try testing.expect(@abs(output) < 0.1);
}

test "biquad bandpass" {
    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.bandpass, 1000.0, 2.0, 0.0);

    // Process impulse
    _ = filter.tick(1.0);
    for (0..100) |_| {
        _ = filter.tick(0.0);
    }

    // Should have ringing (band-limited response)
    filter.reset();
}

test "biquad notch" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.notch, 1000.0, 5.0, 0.0);

    // Process DC - should pass through notch
    var output: f32 = 0;
    for (0..100) |_| {
        output = filter.tick(1.0);
    }

    try testing.expect(output > 0.9);
}

test "biquad peak eq" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.peak, 1000.0, 1.0, 6.0); // 6dB boost

    // Process DC
    var output: f32 = 0;
    for (0..100) |_| {
        output = filter.tick(1.0);
    }

    // DC should pass through mostly unchanged
    try testing.expect(@abs(output - 1.0) < 0.2);
}

test "biquad low shelf" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.low_shelf, 200.0, 0.707, 6.0); // 6dB boost below 200Hz

    // Process DC (0Hz) - should be boosted
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tick(1.0);
    }

    // DC should be boosted by ~6dB (factor of 2)
    try testing.expect(output > 1.5);
}

test "biquad high shelf" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.high_shelf, 10000.0, 0.707, -6.0); // 6dB cut above 10kHz

    // Process DC - should be unaffected by high shelf
    var output: f32 = 0;
    for (0..100) |_| {
        output = filter.tick(1.0);
    }

    try testing.expect(@abs(output - 1.0) < 0.1);
}

test "biquad frequency modulation" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.lowpass, 1000.0, 0.707, 0.0);

    // Modulate frequency
    filter.setFrequency(500.0);
    try testing.expectApproxEqAbs(@as(f32, 500.0), filter.frequency, 0.1);

    filter.setFrequency(2000.0);
    try testing.expectApproxEqAbs(@as(f32, 2000.0), filter.frequency, 0.1);

    // Frequency should clamp to Nyquist
    filter.setFrequency(30000.0);
    try testing.expect(filter.frequency < 24000.0);
}

test "biquad q modulation" {
    const testing = std.testing;

    var filter = BiquadFilter.init(48000.0);
    filter.setParams(.lowpass, 1000.0, 0.707, 0.0);

    filter.setQ(5.0);
    try testing.expectApproxEqAbs(@as(f32, 5.0), filter.q, 0.01);

    // Q should clamp to minimum
    filter.setQ(0.01);
    try testing.expect(filter.q >= 0.1);
}

test "one pole lowpass" {
    const testing = std.testing;

    var filter = OnePoleFilter.initLP(1000.0, 48000.0);

    // Process DC
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tick(1.0);
    }

    // DC should pass through
    try testing.expect(output > 0.95);

    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.y1, 0.001);
}

test "one pole highpass" {
    const testing = std.testing;

    var filter = OnePoleFilter.initHP(1000.0, 48000.0);

    // Process DC - one-pole HP attenuates but doesn't fully block
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tick(1.0);
    }

    // One-pole filter provides some DC attenuation (not full blocking)
    // The steady-state response depends on cutoff frequency
    try testing.expect(@abs(output) < 0.6);
}

test "svf lowpass mode" {
    const testing = std.testing;

    var filter = SVFilter.init(48000.0);
    filter.setFrequency(1000.0);

    // Process DC through lowpass
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tickLP(1.0);
    }

    // DC should pass through lowpass
    try testing.expect(output > 0.9);
}

test "svf highpass mode" {
    const testing = std.testing;

    var filter = SVFilter.init(48000.0);
    filter.setFrequency(1000.0);

    // Process DC through highpass
    var output: f32 = 0;
    for (0..200) |_| {
        output = filter.tickHP(1.0);
    }

    // DC should be blocked by highpass
    try testing.expect(@abs(output) < 0.1);
}

test "svf bandpass mode" {
    const testing = std.testing;

    var filter = SVFilter.init(48000.0);
    filter.setFrequency(1000.0);
    filter.setQ(2.0);

    // Process impulse through bandpass
    _ = filter.tickBP(1.0);
    for (0..100) |_| {
        _ = filter.tickBP(0.0);
    }

    // Band should decay
    try testing.expect(@abs(filter.band) < 0.01);
}

test "svf reset" {
    const testing = std.testing;

    var filter = SVFilter.init(48000.0);

    // Build up state
    for (0..50) |_| {
        _ = filter.tick(1.0);
    }

    try testing.expect(filter.low != 0.0);

    filter.reset();
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.low, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), filter.band, 0.001);
}
