//! Envelope Generators
//!
//! ADSR and other envelope types for shaping sound over time.
//! Uses exponential curves for natural-sounding envelopes.

const std = @import("std");

/// Envelope state
pub const EnvelopeState = enum(u8) {
    idle,
    attack,
    decay,
    sustain,
    release,
};

/// ADSR Envelope with exponential curves
/// Uses the one-pole filter approach for smooth, efficient envelopes
pub const ADSREnvelope = struct {
    // Parameters (in seconds)
    attack: f32 = 0.01,
    decay: f32 = 0.1,
    sustain: f32 = 0.7, // Level 0.0-1.0
    release: f32 = 0.3,

    // State
    state: EnvelopeState = .idle,
    output: f32 = 0.0,
    target: f32 = 0.0,
    coeff: f32 = 0.0,

    // Cached coefficients
    attack_coeff: f32 = 0.0,
    decay_coeff: f32 = 0.0,
    release_coeff: f32 = 0.0,

    sample_rate: f32 = 48000.0,

    /// Time constant multiplier for exponential curves
    /// Larger = faster approach to target
    const TIME_CONSTANT: f32 = 5.0;

    pub fn init(sample_rate: f32) ADSREnvelope {
        var env = ADSREnvelope{ .sample_rate = sample_rate };
        env.updateCoefficients();
        return env;
    }

    /// Recalculate coefficients when parameters change
    pub fn updateCoefficients(self: *ADSREnvelope) void {
        self.attack_coeff = calcCoeff(self.attack, self.sample_rate);
        self.decay_coeff = calcCoeff(self.decay, self.sample_rate);
        self.release_coeff = calcCoeff(self.release, self.sample_rate);
    }

    /// Calculate exponential coefficient from time
    fn calcCoeff(time_seconds: f32, sample_rate: f32) f32 {
        if (time_seconds <= 0.0) return 0.0;
        return @exp(-TIME_CONSTANT / (time_seconds * sample_rate));
    }

    /// Trigger note on
    pub fn noteOn(self: *ADSREnvelope) void {
        self.state = .attack;
        self.target = 1.0;
        self.coeff = self.attack_coeff;
    }

    /// Trigger note off
    pub fn noteOff(self: *ADSREnvelope) void {
        if (self.state != .idle) {
            self.state = .release;
            self.target = 0.0;
            self.coeff = self.release_coeff;
        }
    }

    /// Force envelope to idle
    pub fn kill(self: *ADSREnvelope) void {
        self.state = .idle;
        self.output = 0.0;
        self.target = 0.0;
    }

    /// Process one sample
    pub fn tick(self: *ADSREnvelope) f32 {
        switch (self.state) {
            .idle => {
                self.output = 0.0;
            },
            .attack => {
                self.output = self.target + self.coeff * (self.output - self.target);
                if (self.output >= 0.999) {
                    self.output = 1.0;
                    self.state = .decay;
                    self.target = self.sustain;
                    self.coeff = self.decay_coeff;
                }
            },
            .decay => {
                self.output = self.target + self.coeff * (self.output - self.target);
                if (@abs(self.output - self.sustain) < 0.001) {
                    self.output = self.sustain;
                    self.state = .sustain;
                }
            },
            .sustain => {
                self.output = self.sustain;
            },
            .release => {
                self.output = self.target + self.coeff * (self.output - self.target);
                if (self.output <= 0.0001) {
                    self.output = 0.0;
                    self.state = .idle;
                }
            },
        }

        return self.output;
    }

    /// Check if envelope is active
    pub fn isActive(self: *const ADSREnvelope) bool {
        return self.state != .idle;
    }

    /// Set attack time in seconds
    pub fn setAttack(self: *ADSREnvelope, seconds: f32) void {
        self.attack = @max(0.001, seconds);
        self.attack_coeff = calcCoeff(self.attack, self.sample_rate);
    }

    /// Set decay time in seconds
    pub fn setDecay(self: *ADSREnvelope, seconds: f32) void {
        self.decay = @max(0.001, seconds);
        self.decay_coeff = calcCoeff(self.decay, self.sample_rate);
    }

    /// Set sustain level (0.0-1.0)
    pub fn setSustain(self: *ADSREnvelope, level: f32) void {
        self.sustain = std.math.clamp(level, 0.0, 1.0);
    }

    /// Set release time in seconds
    pub fn setRelease(self: *ADSREnvelope, seconds: f32) void {
        self.release = @max(0.001, seconds);
        self.release_coeff = calcCoeff(self.release, self.sample_rate);
    }
};

/// Simple AR (Attack-Release) envelope
/// Useful for filter envelopes, LFO fades, etc.
pub const AREnvelope = struct {
    attack_coeff: f32 = 0.0,
    release_coeff: f32 = 0.0,
    output: f32 = 0.0,
    gate: bool = false,

    pub fn init(attack_ms: f32, release_ms: f32, sample_rate: f32) AREnvelope {
        return .{
            .attack_coeff = @exp(-1.0 / (attack_ms * 0.001 * sample_rate)),
            .release_coeff = @exp(-1.0 / (release_ms * 0.001 * sample_rate)),
        };
    }

    pub fn trigger(self: *AREnvelope, on: bool) void {
        self.gate = on;
    }

    pub fn tick(self: *AREnvelope) f32 {
        const target: f32 = if (self.gate) 1.0 else 0.0;
        const coeff = if (self.gate) self.attack_coeff else self.release_coeff;
        self.output = target + coeff * (self.output - target);
        return self.output;
    }
};

/// Envelope follower - extract amplitude envelope from audio
pub const EnvelopeFollower = struct {
    attack_coeff: f32,
    release_coeff: f32,
    envelope: f32 = 0.0,

    pub fn init(attack_ms: f32, release_ms: f32, sample_rate: f32) EnvelopeFollower {
        return .{
            .attack_coeff = @exp(-1.0 / (attack_ms * 0.001 * sample_rate)),
            .release_coeff = @exp(-1.0 / (release_ms * 0.001 * sample_rate)),
        };
    }

    pub fn tick(self: *EnvelopeFollower, input: f32) f32 {
        const rectified = @abs(input);
        const coeff = if (rectified > self.envelope) self.attack_coeff else self.release_coeff;
        self.envelope = rectified + coeff * (self.envelope - rectified);
        return self.envelope;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "adsr envelope lifecycle" {
    const testing = std.testing;

    var env = ADSREnvelope.init(48000.0);
    env.attack = 0.01; // 10ms attack (more samples to verify attack phase)
    env.sustain = 0.95; // High sustain so we stay above 0.9 during decay
    env.updateCoefficients();

    // Initially idle
    try testing.expectEqual(EnvelopeState.idle, env.state);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.tick(), 0.001);

    // Trigger note on
    env.noteOn();
    try testing.expectEqual(EnvelopeState.attack, env.state);

    // Run for a while - should reach peak (10ms = 480 samples at 48kHz)
    for (0..1000) |_| {
        _ = env.tick();
    }
    try testing.expect(env.output > 0.9);

    // Should eventually reach sustain
    for (0..5000) |_| {
        _ = env.tick();
    }

    // Trigger release
    env.noteOff();
    try testing.expectEqual(EnvelopeState.release, env.state);

    // Run until idle
    for (0..50000) |_| {
        _ = env.tick();
        if (env.state == .idle) break;
    }
    try testing.expectEqual(EnvelopeState.idle, env.state);
}

test "adsr parameter setters" {
    const testing = std.testing;

    var env = ADSREnvelope.init(48000.0);

    env.setAttack(0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.05), env.attack, 0.001);

    env.setDecay(0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.2), env.decay, 0.001);

    env.setSustain(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), env.sustain, 0.001);

    env.setRelease(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), env.release, 0.001);

    // Sustain should clamp to 0-1
    env.setSustain(1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), env.sustain, 0.001);

    env.setSustain(-0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.sustain, 0.001);
}

test "adsr isActive" {
    const testing = std.testing;

    var env = ADSREnvelope.init(48000.0);

    // Initially not active
    try testing.expect(!env.isActive());

    // Active after note on
    env.noteOn();
    try testing.expect(env.isActive());

    // Still active during release
    env.noteOff();
    try testing.expect(env.isActive());

    // Run until idle
    for (0..100000) |_| {
        _ = env.tick();
        if (!env.isActive()) break;
    }
    try testing.expect(!env.isActive());
}

test "adsr kill" {
    const testing = std.testing;

    var env = ADSREnvelope.init(48000.0);

    env.noteOn();
    for (0..100) |_| {
        _ = env.tick();
    }

    try testing.expect(env.isActive());
    try testing.expect(env.output > 0.0);

    // Kill should immediately stop
    env.kill();
    try testing.expect(!env.isActive());
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.output, 0.001);
}

test "ar envelope" {
    const testing = std.testing;

    var env = AREnvelope.init(1.0, 10.0, 48000.0); // 1ms attack, 10ms release (fast)

    // Initially off
    try testing.expectApproxEqAbs(@as(f32, 0.0), env.output, 0.001);

    // Trigger on
    env.trigger(true);

    // Run attack - 1ms at 48kHz = 48 samples, run extra for settling
    for (0..500) |_| {
        _ = env.tick();
    }

    // Should be near 1.0 after attack
    try testing.expect(env.output > 0.8);

    // Trigger off
    env.trigger(false);

    // Run release - 10ms at 48kHz = 480 samples, run extra
    for (0..2000) |_| {
        _ = env.tick();
    }

    // Should decay toward 0
    try testing.expect(env.output < 0.2);
}

test "ar envelope gate behavior" {
    const testing = std.testing;

    var env = AREnvelope.init(1.0, 5.0, 48000.0); // Fast: 1ms attack, 5ms release

    // Multiple on/off cycles
    for (0..3) |_| {
        env.trigger(true);
        for (0..500) |_| {
            _ = env.tick();
        }

        env.trigger(false);
        for (0..1000) |_| { // More samples for release
            _ = env.tick();
        }
    }

    // Should handle repeated triggers and decay
    try testing.expect(env.output < 0.5);
}

test "envelope follower" {
    const testing = std.testing;

    var follower = EnvelopeFollower.init(1.0, 50.0, 48000.0); // 1ms attack, 50ms release

    // Initially zero
    try testing.expectApproxEqAbs(@as(f32, 0.0), follower.envelope, 0.001);

    // Feed constant signal - should rise toward 1.0
    for (0..100) |_| {
        _ = follower.tick(1.0);
    }
    // After 100 samples (~2ms) with 1ms attack, should be well above 0.5
    try testing.expect(follower.envelope > 0.5);

    // Feed zeros - should decay slowly (50ms release)
    for (0..1000) |_| {
        _ = follower.tick(0.0);
    }
    try testing.expect(follower.envelope < 0.8);

    // Continue decay
    for (0..10000) |_| {
        _ = follower.tick(0.0);
    }
    try testing.expect(follower.envelope < 0.01);
}

test "envelope follower tracks amplitude" {
    const testing = std.testing;

    var follower = EnvelopeFollower.init(1.0, 10.0, 48000.0);

    // Feed constant signal
    for (0..1000) |_| {
        _ = follower.tick(0.5);
    }

    // Should track amplitude
    try testing.expect(follower.envelope > 0.4);
    try testing.expect(follower.envelope < 0.6);

    // Feed larger signal
    for (0..1000) |_| {
        _ = follower.tick(0.8);
    }

    try testing.expect(follower.envelope > 0.7);
}

test "envelope follower handles negative" {
    const testing = std.testing;

    var follower = EnvelopeFollower.init(1.0, 10.0, 48000.0);

    // Feed negative signal (should rectify)
    for (0..1000) |_| {
        _ = follower.tick(-0.7);
    }

    // Should track absolute value
    try testing.expect(follower.envelope > 0.6);
}
