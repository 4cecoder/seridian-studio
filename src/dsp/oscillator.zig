//! Oscillators - Band-limited waveform generation
//!
//! Implements anti-aliased oscillators using PolyBLEP for real-time synthesis.
//! All oscillators are designed for zero-allocation real-time use.

const std = @import("std");

/// Basic phase accumulator oscillator
pub const Oscillator = struct {
    phase: f32 = 0.0,
    frequency: f32 = 440.0,
    sample_rate: f32 = 48000.0,

    /// Phase increment per sample
    pub inline fn getPhaseIncrement(self: *const Oscillator) f32 {
        return self.frequency / self.sample_rate;
    }

    /// Advance phase by one sample
    pub inline fn advance(self: *Oscillator) void {
        self.phase += self.getPhaseIncrement();
        if (self.phase >= 1.0) self.phase -= 1.0;
    }

    /// Advance phase and return current phase before advance
    pub inline fn tick(self: *Oscillator) f32 {
        const p = self.phase;
        self.advance();
        return p;
    }

    /// Set frequency from MIDI note
    pub fn setNote(self: *Oscillator, note: u8) void {
        self.frequency = midiNoteToFreq(note);
    }

    /// Reset phase to 0
    pub fn reset(self: *Oscillator) void {
        self.phase = 0.0;
    }
};

/// Convert MIDI note to frequency (A4 = 440Hz)
pub fn midiNoteToFreq(note: u8) f32 {
    const n = @as(f32, @floatFromInt(note));
    return 440.0 * std.math.pow(f32, 2.0, (n - 69.0) / 12.0);
}

// =============================================================================
// Basic Waveforms (naive - for reference)
// =============================================================================

/// Pure sine wave
pub inline fn sine(phase: f32) f32 {
    return @sin(phase * std.math.tau);
}

/// Naive sawtooth (creates aliasing at high frequencies)
pub inline fn sawNaive(phase: f32) f32 {
    return 2.0 * phase - 1.0;
}

/// Naive square (creates aliasing at high frequencies)
pub inline fn squareNaive(phase: f32) f32 {
    return if (phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0);
}

/// Triangle wave (naturally band-limited, minimal aliasing)
pub inline fn triangle(phase: f32) f32 {
    return 4.0 * @abs(phase - 0.5) - 1.0;
}

// =============================================================================
// PolyBLEP - Polynomial Band-Limited Step
// =============================================================================

/// PolyBLEP correction for discontinuities
/// Smooths hard transitions to prevent aliasing
pub fn polyblep(t: f32, dt: f32) f32 {
    // t = phase position, dt = phase increment (frequency/sample_rate)
    if (t < dt) {
        // Rising discontinuity
        const x = t / dt;
        return x + x - x * x - 1.0;
    } else if (t > 1.0 - dt) {
        // Falling discontinuity
        const x = (t - 1.0) / dt;
        return x * x + x + x + 1.0;
    }
    return 0.0;
}

/// Band-limited sawtooth using PolyBLEP
pub fn sawBL(phase: f32, phase_inc: f32) f32 {
    var value = 2.0 * phase - 1.0;
    value -= polyblep(phase, phase_inc);
    return value;
}

/// Band-limited square using PolyBLEP
pub fn squareBL(phase: f32, phase_inc: f32) f32 {
    var value: f32 = if (phase < 0.5) 1.0 else -1.0;
    value += polyblep(phase, phase_inc);
    value -= polyblep(@mod(phase + 0.5, 1.0), phase_inc);
    return value;
}

/// Band-limited pulse with variable width
pub fn pulseBL(phase: f32, phase_inc: f32, width: f32) f32 {
    var value: f32 = if (phase < width) 1.0 else -1.0;
    value += polyblep(phase, phase_inc);
    value -= polyblep(@mod(phase + (1.0 - width), 1.0), phase_inc);
    return value;
}

// =============================================================================
// BLEPOscillator - Complete band-limited oscillator
// =============================================================================

pub const Waveform = enum(u8) {
    sine = 0,
    saw = 1,
    square = 2,
    triangle = 3,
    pulse = 4,

    pub fn name(self: Waveform) []const u8 {
        return switch (self) {
            .sine => "Sine",
            .saw => "Saw",
            .square => "Square",
            .triangle => "Triangle",
            .pulse => "Pulse",
        };
    }
};

/// Band-limited oscillator with multiple waveforms
pub const BLEPOscillator = struct {
    osc: Oscillator = .{},
    waveform: Waveform = .saw,
    pulse_width: f32 = 0.5, // For pulse wave

    pub fn init(sample_rate: f32) BLEPOscillator {
        return .{
            .osc = .{ .sample_rate = sample_rate },
        };
    }

    /// Generate one sample and advance phase
    pub fn tick(self: *BLEPOscillator) f32 {
        const phase = self.osc.phase;
        const phase_inc = self.osc.getPhaseIncrement();

        const output = switch (self.waveform) {
            .sine => sine(phase),
            .saw => sawBL(phase, phase_inc),
            .square => squareBL(phase, phase_inc),
            .triangle => triangle(phase),
            .pulse => pulseBL(phase, phase_inc, self.pulse_width),
        };

        self.osc.advance();
        return output;
    }

    pub fn setFrequency(self: *BLEPOscillator, freq: f32) void {
        self.osc.frequency = freq;
    }

    pub fn setNote(self: *BLEPOscillator, note: u8) void {
        self.osc.setNote(note);
    }

    pub fn reset(self: *BLEPOscillator) void {
        self.osc.reset();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "midi note to freq" {
    const testing = std.testing;

    // A4 = 440Hz
    try testing.expectApproxEqAbs(@as(f32, 440.0), midiNoteToFreq(69), 0.01);
    // A3 = 220Hz
    try testing.expectApproxEqAbs(@as(f32, 220.0), midiNoteToFreq(57), 0.01);
    // A5 = 880Hz
    try testing.expectApproxEqAbs(@as(f32, 880.0), midiNoteToFreq(81), 0.01);
    // C4 = 261.63Hz
    try testing.expectApproxEqAbs(@as(f32, 261.63), midiNoteToFreq(60), 0.1);
}

test "oscillator phase" {
    var osc = Oscillator{ .frequency = 48000.0, .sample_rate = 48000.0 };

    // At fs == freq, phase should advance by 1.0 per sample (wrap to 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), osc.phase, 0.001);
    osc.advance();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), osc.phase, 0.001); // Wrapped
}

test "sine wave range" {
    const testing = std.testing;

    // Sine should be in [-1, 1]
    try testing.expect(sine(0.0) >= -1.0 and sine(0.0) <= 1.0);
    try testing.expect(sine(0.25) >= -1.0 and sine(0.25) <= 1.0);
    try testing.expect(sine(0.5) >= -1.0 and sine(0.5) <= 1.0);
    try testing.expect(sine(0.75) >= -1.0 and sine(0.75) <= 1.0);

    // Specific values
    try testing.expectApproxEqAbs(@as(f32, 0.0), sine(0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), sine(0.25), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), sine(0.5), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), sine(0.75), 0.001);
}
