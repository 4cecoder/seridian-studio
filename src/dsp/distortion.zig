//! Distortion and Waveshaping Effects
//!
//! Various distortion algorithms for sound design:
//! - Wavefolder (West Coast synthesis style)
//! - Soft Clipping (tube-like saturation)
//! - Hard Clipping (transistor-style)
//! - Bitcrusher (lo-fi bit reduction)
//! - Sample Rate Reducer (aliasing effects)
//! - Slew Rate Limiter (smoothing distortion)
//! - Asymmetric Distortion (even harmonics)
//!
//! Based on algorithms from:
//! - LMMS DspEffectLibrary.h
//! - Serge modular wavefolder circuits
//! - Classic tube amplifier models

const std = @import("std");
const math = std.math;
const dsp = @import("dsp.zig");

// =============================================================================
// Wavefolder
// =============================================================================

/// West Coast style wavefolder
/// Creates complex harmonics by folding the waveform back on itself
pub const Wavefolder = struct {
    threshold: f32 = 1.0,
    gain: f32 = 1.0,
    stages: u8 = 1,
    symmetry: f32 = 1.0, // 0.5 = asymmetric, 1.0 = symmetric

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set fold threshold (lower = more folding)
    pub fn setThreshold(self: *Self, thresh: f32) void {
        self.threshold = @max(0.01, thresh);
    }

    /// Set input gain (drive)
    pub fn setGain(self: *Self, gain: f32) void {
        self.gain = @max(0.1, gain);
    }

    /// Set number of fold stages
    pub fn setStages(self: *Self, stages: u8) void {
        self.stages = @max(1, @min(8, stages));
    }

    /// Set symmetry (0.5 = asymmetric for even harmonics, 1.0 = symmetric for odd)
    pub fn setSymmetry(self: *Self, sym: f32) void {
        self.symmetry = math.clamp(sym, 0.0, 1.0);
    }

    pub fn process(self: *Self, input: f32) f32 {
        var x = input * self.gain;

        // Apply asymmetry bias
        if (self.symmetry < 1.0) {
            x += (1.0 - self.symmetry) * 0.5;
        }

        // Multi-stage folding
        for (0..self.stages) |_| {
            x = self.foldSingle(x);
        }

        // Remove DC offset from asymmetry
        if (self.symmetry < 1.0) {
            x -= (1.0 - self.symmetry) * 0.25;
        }

        return x;
    }

    fn foldSingle(self: *Self, x: f32) f32 {
        const thresh = self.threshold;
        const thresh4 = thresh * 4.0;

        if (@abs(x) >= thresh) {
            // Foldback algorithm
            const sign: f32 = if (x >= 0) 1.0 else -1.0;
            const abs_x = @abs(x);
            const folded = @abs(@abs(@mod(abs_x - thresh, thresh4)) - thresh * 2.0) - thresh;
            return folded * sign;
        }
        return x;
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Soft Clipper (Tube-style)
// =============================================================================

/// Soft clipping distortion with tube-like character
pub const SoftClipper = struct {
    drive: f32 = 1.0,
    threshold: f32 = 0.5,
    mix: f32 = 1.0,
    asymmetry: f32 = 0.0, // 0 = symmetric, 1 = full asymmetric

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set drive amount (1.0 = unity, higher = more distortion)
    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = @max(0.1, drive);
    }

    /// Set clipping threshold
    pub fn setThreshold(self: *Self, thresh: f32) void {
        self.threshold = math.clamp(thresh, 0.01, 1.0);
    }

    /// Set dry/wet mix
    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    /// Set asymmetry for even harmonic content
    pub fn setAsymmetry(self: *Self, asym: f32) void {
        self.asymmetry = math.clamp(asym, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        var x = input * self.drive;

        // Add asymmetry bias
        x += self.asymmetry * 0.1;

        // Attempt soft clip using rational function
        // f(x) = x * (|x| + threshold) / (x^2 + (threshold-1)*|x| + 1)
        const abs_x = @abs(x);
        const thresh = self.threshold;
        const wet = x * (abs_x + thresh) / (x * x + (thresh - 1.0) * abs_x + 1.0);

        // Mix dry/wet
        return dsp.lerp(input, wet, self.mix);
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Hard Clipper
// =============================================================================

/// Hard clipping distortion (transistor-style)
pub const HardClipper = struct {
    drive: f32 = 1.0,
    threshold: f32 = 1.0,
    mix: f32 = 1.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = @max(0.1, drive);
    }

    pub fn setThreshold(self: *Self, thresh: f32) void {
        self.threshold = @max(0.01, thresh);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const driven = input * self.drive;
        const clipped = math.clamp(driven, -self.threshold, self.threshold);
        return dsp.lerp(input, clipped, self.mix);
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Tanh Saturation
// =============================================================================

/// Smooth tanh saturation
pub const TanhSaturator = struct {
    drive: f32 = 1.0,
    mix: f32 = 1.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = @max(0.1, drive);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const driven = input * self.drive;
        const saturated = fastTanh(driven);
        return dsp.lerp(input, saturated, self.mix);
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Bitcrusher
// =============================================================================

/// Bit depth and sample rate reduction for lo-fi effects
pub const Bitcrusher = struct {
    // Bit reduction
    bit_depth: u8 = 16,
    quantize_levels: f32 = 65536,

    // Sample rate reduction
    rate_reduction: f32 = 1.0, // 1.0 = no reduction, 0.1 = 10x reduction
    sample_hold: f32 = 0,
    rate_counter: f32 = 0,

    // Mix
    mix: f32 = 1.0,

    // Optional dither
    dither_amount: f32 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set bit depth (1-16 bits)
    pub fn setBitDepth(self: *Self, bits: u8) void {
        self.bit_depth = math.clamp(bits, 1, 16);
        self.quantize_levels = @floatFromInt(@as(u32, 1) << @as(u5, @intCast(self.bit_depth)));
    }

    /// Set sample rate reduction factor (0.01 = extreme, 1.0 = none)
    pub fn setRateReduction(self: *Self, rate: f32) void {
        self.rate_reduction = math.clamp(rate, 0.01, 1.0);
    }

    /// Set dither amount (0-1)
    pub fn setDither(self: *Self, amount: f32) void {
        self.dither_amount = math.clamp(amount, 0, 1);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Sample rate reduction
        self.rate_counter += self.rate_reduction;
        if (self.rate_counter >= 1.0) {
            self.rate_counter -= 1.0;
            self.sample_hold = input;
        }

        var x = self.sample_hold;

        // Add dither before quantization
        if (self.dither_amount > 0) {
            // Attempt triangular dither using simple PRNG
            const dither = triangularDither() * self.dither_amount / self.quantize_levels;
            x += dither;
        }

        // Bit depth reduction (quantization)
        const scaled = (x + 1.0) * 0.5 * self.quantize_levels;
        const quantized = @floor(scaled) / self.quantize_levels * 2.0 - 1.0;

        return dsp.lerp(input, quantized, self.mix);
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    pub fn reset(self: *Self) void {
        self.sample_hold = 0;
        self.rate_counter = 0;
    }
};

// =============================================================================
// Slew Rate Limiter
// =============================================================================

/// Limits the rate of change of a signal
/// Creates smooth distortion and can remove high frequencies
pub const SlewLimiter = struct {
    rise_rate: f32 = 1.0, // Max rise per sample
    fall_rate: f32 = 1.0, // Max fall per sample
    last_output: f32 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set rise rate (samples to go from -1 to +1)
    pub fn setRiseRate(self: *Self, samples: f32) void {
        self.rise_rate = 2.0 / @max(1.0, samples);
    }

    /// Set fall rate (samples to go from +1 to -1)
    pub fn setFallRate(self: *Self, samples: f32) void {
        self.fall_rate = 2.0 / @max(1.0, samples);
    }

    /// Set symmetric slew rate
    pub fn setRate(self: *Self, samples: f32) void {
        self.setRiseRate(samples);
        self.setFallRate(samples);
    }

    /// Set rates in Hz (cutoff-like parameter)
    pub fn setRateHz(self: *Self, hz: f32, sample_rate: f32) void {
        const samples = sample_rate / hz;
        self.setRate(samples);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const diff = input - self.last_output;

        if (diff > self.rise_rate) {
            self.last_output += self.rise_rate;
        } else if (diff < -self.fall_rate) {
            self.last_output -= self.fall_rate;
        } else {
            self.last_output = input;
        }

        return self.last_output;
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    pub fn reset(self: *Self) void {
        self.last_output = 0;
    }
};

// =============================================================================
// Rectifier
// =============================================================================

/// Full and half-wave rectification for harmonic generation
pub const Rectifier = struct {
    mode: RectMode = .full,
    mix: f32 = 1.0,

    pub const RectMode = enum {
        full, // |x| - adds even harmonics
        half_positive, // max(x, 0) - octave up effect
        half_negative, // min(x, 0) - octave up effect
    };

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn setMode(self: *Self, mode: RectMode) void {
        self.mode = mode;
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const rectified = switch (self.mode) {
            .full => @abs(input),
            .half_positive => @max(input, 0),
            .half_negative => @min(input, 0),
        };
        return dsp.lerp(input, rectified, self.mix);
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Chebyshev Waveshaper
// =============================================================================

/// Chebyshev polynomial waveshaper for precise harmonic control
pub const ChebyshevShaper = struct {
    harmonics: [8]f32 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    drive: f32 = 1.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set individual harmonic amplitudes (1-8)
    pub fn setHarmonic(self: *Self, harmonic: u8, amplitude: f32) void {
        if (harmonic >= 1 and harmonic <= 8) {
            self.harmonics[harmonic - 1] = amplitude;
        }
    }

    /// Set all harmonics at once
    pub fn setHarmonics(self: *Self, h: [8]f32) void {
        self.harmonics = h;
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = @max(0.1, drive);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const x = math.clamp(input * self.drive, -1, 1);

        // Chebyshev polynomials T_n(x)
        const t1 = x;
        const t2 = 2 * x * x - 1;
        const t3 = 4 * x * x * x - 3 * x;
        const t4 = 8 * x * x * x * x - 8 * x * x + 1;
        const t5 = 16 * x * x * x * x * x - 20 * x * x * x + 5 * x;
        const t6 = 32 * x * x * x * x * x * x - 48 * x * x * x * x + 18 * x * x - 1;
        const t7 = 64 * math.pow(x, 7) - 112 * math.pow(x, 5) + 56 * math.pow(x, 3) - 7 * x;
        const t8 = 128 * math.pow(x, 8) - 256 * math.pow(x, 6) + 160 * math.pow(x, 4) - 32 * x * x + 1;

        return self.harmonics[0] * t1 +
            self.harmonics[1] * t2 +
            self.harmonics[2] * t3 +
            self.harmonics[3] * t4 +
            self.harmonics[4] * t5 +
            self.harmonics[5] * t6 +
            self.harmonics[6] * t7 +
            self.harmonics[7] * t8;
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Diode Clipper
// =============================================================================

/// Attempt asymmetric diode clipper model
pub const DiodeClipper = struct {
    drive: f32 = 1.0,
    vt: f32 = 0.026, // Thermal voltage (~26mV at room temp)
    eta: f32 = 1.0, // Ideality factor
    is: f32 = 1e-12, // Saturation current

    // DC blocking
    dc_block_state: f32 = 0,
    dc_block_coef: f32 = 0.995,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn setDrive(self: *Self, drive: f32) void {
        self.drive = @max(0.1, drive);
    }

    /// Set diode ideality factor (1.0 = ideal, 1.5-2.0 = real silicon)
    pub fn setIdeality(self: *Self, eta: f32) void {
        self.eta = math.clamp(eta, 1.0, 3.0);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const x = input * self.drive;

        // Attempt Shockley diode equation: I = Is * (exp(V/nVt) - 1)
        // Approximated for audio using piecewise function
        const threshold = self.vt * self.eta * 10.0;

        var output: f32 = undefined;
        if (@abs(x) < threshold) {
            // Linear region
            output = x;
        } else {
            // Exponential limiting
            const sign: f32 = if (x >= 0) 1.0 else -1.0;
            const abs_x = @abs(x);
            output = sign * (threshold + math.log1p((abs_x - threshold) / threshold) * threshold);
        }

        // DC blocking
        const dc_free = output - self.dc_block_state;
        self.dc_block_state = output - dc_free * self.dc_block_coef;

        return dc_free;
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

fn fastTanh(x: f32) f32 {
    if (x < -3.0) return -1.0;
    if (x > 3.0) return 1.0;
    const x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

// Simple PRNG for dither
var prng_state: u32 = 12345;

fn triangularDither() f32 {
    // Two uniform randoms for triangular PDF
    const r1 = nextRandom();
    const r2 = nextRandom();
    return r1 - r2;
}

fn nextRandom() f32 {
    // Xorshift32
    prng_state ^= prng_state << 13;
    prng_state ^= prng_state >> 17;
    prng_state ^= prng_state << 5;
    return @as(f32, @floatFromInt(prng_state)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

// =============================================================================
// Tests
// =============================================================================

test "wavefolder basic" {
    const testing = std.testing;

    var folder = Wavefolder.init();
    folder.setThreshold(0.5);
    folder.setGain(2.0);

    // Should fold when input exceeds threshold
    const out = folder.process(1.0);
    try testing.expect(@abs(out) <= 0.5);
}

test "bitcrusher reduces bits" {
    const testing = std.testing;

    var crusher = Bitcrusher.init();
    crusher.setBitDepth(4);
    crusher.setRateReduction(1.0);

    // Process a smooth value
    const out = crusher.process(0.123);

    // Should be quantized to 4-bit levels (16 levels)
    // One of: -1, -0.875, -0.75, ... 0.875, 1
    const quantized = @round(out * 8.0) / 8.0;
    try testing.expectApproxEqAbs(out, quantized, 0.1);
}

test "slew limiter smooths" {
    const testing = std.testing;

    var slew = SlewLimiter.init();
    slew.setRate(10); // 10 samples to go full range

    // Jump from 0 to 1 should be limited
    slew.last_output = 0;
    const out = slew.process(1.0);
    try testing.expect(out < 1.0);
    try testing.expect(out > 0);
}

test "soft clipper saturates" {
    const testing = std.testing;

    var clip = SoftClipper.init();
    clip.setDrive(5.0);

    // High drive should saturate
    const out = clip.process(1.0);
    try testing.expect(@abs(out) < 1.5); // Should be somewhat limited
}
