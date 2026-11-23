//! Modal Synthesis Module
//!
//! Physical modeling using modal decomposition:
//! - Resonant bodies as sum of decaying sinusoids
//! - Bells, bars, drums, plates, strings
//! - Real-time excitation and resonance
//!
//! Based on:
//! - Mutable Instruments open-source designs (Émilie Gillet)
//! - Modal synthesis literature (Adrien, Rabenstein)
//! - IRCAM Modalys concepts
//!
//! Each mode is a damped harmonic oscillator:
//!   y(t) = A * e^(-d*t) * sin(2π*f*t + φ)
//!
//! Where:
//!   A = amplitude
//!   d = decay rate (damping)
//!   f = frequency
//!   φ = phase

const std = @import("std");
const sys = @import("../utils/sys.zig");
const math = std.math;

// =============================================================================
// Single Resonant Mode
// =============================================================================

/// A single damped harmonic oscillator (resonant mode)
pub const Mode = struct {
    /// Oscillator state (complex phasor)
    state_re: f32 = 0.0,
    state_im: f32 = 0.0,

    /// Frequency coefficient (rotation per sample)
    cos_omega: f32 = 1.0,
    sin_omega: f32 = 0.0,

    /// Decay coefficient per sample (0.999 = slow, 0.9 = fast)
    decay: f32 = 0.999,

    /// Amplitude scaling
    amplitude: f32 = 1.0,

    /// Initialize mode with frequency and decay
    pub fn init(freq: f32, decay_time: f32, amplitude: f32, sample_rate: u32) Mode {
        const omega = 2.0 * math.pi * freq / @as(f32, @floatFromInt(sample_rate));

        // Convert decay time (seconds) to per-sample coefficient
        // decay^(sample_rate * decay_time) = e^(-3) ≈ 0.05
        const samples_to_decay = decay_time * @as(f32, @floatFromInt(sample_rate));
        const decay_coeff = if (samples_to_decay > 0.0)
            @exp(-3.0 / samples_to_decay)
        else
            0.0;

        return .{
            .cos_omega = @cos(omega),
            .sin_omega = @sin(omega),
            .decay = decay_coeff,
            .amplitude = amplitude,
        };
    }

    /// Set frequency
    pub fn setFrequency(self: *Mode, freq: f32, sample_rate: u32) void {
        const omega = 2.0 * math.pi * freq / @as(f32, @floatFromInt(sample_rate));
        self.cos_omega = @cos(omega);
        self.sin_omega = @sin(omega);
    }

    /// Set decay time in seconds
    pub fn setDecay(self: *Mode, decay_time: f32, sample_rate: u32) void {
        const samples = decay_time * @as(f32, @floatFromInt(sample_rate));
        self.decay = if (samples > 0.0) @exp(-3.0 / samples) else 0.0;
    }

    /// Excite the mode (add energy)
    pub fn excite(self: *Mode, energy: f32) void {
        self.state_re += energy * self.amplitude;
    }

    /// Excite with specific phase
    pub fn exciteWithPhase(self: *Mode, energy: f32, phase: f32) void {
        self.state_re += energy * self.amplitude * @cos(phase);
        self.state_im += energy * self.amplitude * @sin(phase);
    }

    /// Process one sample (returns output and advances state)
    pub fn process(self: *Mode) f32 {
        // Complex multiplication for rotation: z = z * e^(jω)
        const new_re = self.state_re * self.cos_omega - self.state_im * self.sin_omega;
        const new_im = self.state_re * self.sin_omega + self.state_im * self.cos_omega;

        // Apply decay
        self.state_re = new_re * self.decay;
        self.state_im = new_im * self.decay;

        // Output is real part
        return self.state_re;
    }

    /// Get current energy level
    pub fn getEnergy(self: *const Mode) f32 {
        return @sqrt(self.state_re * self.state_re + self.state_im * self.state_im);
    }

    /// Check if mode is silent
    pub fn isSilent(self: *const Mode, threshold: f32) bool {
        return self.getEnergy() < threshold;
    }

    /// Reset state
    pub fn reset(self: *Mode) void {
        self.state_re = 0.0;
        self.state_im = 0.0;
    }
};

// =============================================================================
// Modal Resonator (Multiple Modes)
// =============================================================================

/// Maximum number of modes supported
pub const MAX_MODES: usize = 64;

/// Modal resonator combining multiple modes
pub const ModalResonator = struct {
    /// Array of modes
    modes: []Mode,

    /// Number of active modes
    num_modes: usize,

    /// Overall amplitude
    master_amplitude: f32 = 1.0,

    /// Sample rate
    sample_rate: u32,

    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_modes: usize, sample_rate: u32) !ModalResonator {
        const modes = try allocator.alloc(Mode, max_modes);
        for (modes) |*m| {
            m.* = Mode{};
        }

        return .{
            .modes = modes,
            .num_modes = 0,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModalResonator) void {
        self.allocator.free(self.modes);
    }

    /// Add a mode to the resonator
    pub fn addMode(self: *ModalResonator, freq: f32, decay_time: f32, amplitude: f32) void {
        if (self.num_modes >= self.modes.len) return;

        self.modes[self.num_modes] = Mode.init(freq, decay_time, amplitude, self.sample_rate);
        self.num_modes += 1;
    }

    /// Clear all modes
    pub fn clearModes(self: *ModalResonator) void {
        self.num_modes = 0;
    }

    /// Excite all modes simultaneously
    pub fn excite(self: *ModalResonator, energy: f32) void {
        for (self.modes[0..self.num_modes]) |*mode| {
            mode.excite(energy);
        }
    }

    /// Excite with position-dependent coupling
    /// position: 0.0-1.0, affects which modes are excited
    pub fn exciteAtPosition(self: *ModalResonator, energy: f32, position: f32) void {
        for (0..self.num_modes) |i| {
            // Mode coupling varies with position (simplified)
            // Real physical models would use mode shapes
            const coupling = @sin(math.pi * position * @as(f32, @floatFromInt(i + 1)));
            self.modes[i].excite(energy * @abs(coupling));
        }
    }

    /// Process one sample
    pub fn process(self: *ModalResonator) f32 {
        var sum: f32 = 0.0;

        for (self.modes[0..self.num_modes]) |*mode| {
            sum += mode.process();
        }

        return sum * self.master_amplitude;
    }

    /// Process block
    pub fn processBlock(self: *ModalResonator, output: []f32) void {
        for (output) |*out| {
            out.* = self.process();
        }
    }

    /// Reset all modes
    pub fn reset(self: *ModalResonator) void {
        for (self.modes) |*mode| {
            mode.reset();
        }
    }

    /// Check if resonator is silent
    pub fn isSilent(self: *const ModalResonator, threshold: f32) bool {
        for (self.modes[0..self.num_modes]) |*mode| {
            if (!mode.isSilent(threshold)) return false;
        }
        return true;
    }
};

// =============================================================================
// Preset Modal Ratios
// =============================================================================

/// Predefined frequency ratios for common resonant objects
pub const ModalPresets = struct {
    /// Ideal string harmonics (1, 2, 3, 4, ...)
    pub const string_harmonics = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };

    /// Stiff string (slightly sharp harmonics)
    pub const stiff_string = [_]f32{ 1.0, 2.01, 3.03, 4.06, 5.10, 6.15, 7.21, 8.28 };

    /// Ideal bar/marimba (1, 2.756, 5.404, ...)
    pub const bar = [_]f32{ 1.0, 2.756, 5.404, 8.933, 13.34, 18.64 };

    /// Circular membrane (drum head)
    pub const membrane = [_]f32{ 1.0, 1.594, 2.136, 2.296, 2.653, 2.918, 3.156, 3.501 };

    /// Bell (church bell approximation)
    pub const bell = [_]f32{ 0.5, 1.0, 1.183, 1.506, 1.627, 2.0, 2.542, 2.662, 3.0 };

    /// Tubular bell / chime
    pub const chime = [_]f32{ 1.0, 2.756, 5.404, 8.933 };

    /// Gong (inharmonic)
    pub const gong = [_]f32{ 1.0, 1.16, 1.32, 1.51, 1.71, 1.94, 2.19, 2.46, 2.76 };

    /// Wine glass
    pub const glass = [_]f32{ 1.0, 1.8, 2.6, 3.4, 4.2 };

    /// Wooden block
    pub const wood_block = [_]f32{ 1.0, 2.572, 4.644, 6.984, 9.545 };
};

/// Preset decay ratios (higher modes decay faster)
pub const DecayPresets = struct {
    /// Uniform decay
    pub const uniform = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };

    /// Higher modes decay faster
    pub const natural = [_]f32{ 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.35, 0.3 };

    /// Very damped (like muted)
    pub const damped = [_]f32{ 1.0, 0.7, 0.5, 0.35, 0.25, 0.18, 0.12, 0.08, 0.05 };

    /// Sustained (like singing bowl)
    pub const sustained = [_]f32{ 1.0, 0.98, 0.96, 0.94, 0.92, 0.9, 0.88, 0.86, 0.84 };
};

/// Preset amplitude ratios
pub const AmplitudePresets = struct {
    /// Uniform amplitude
    pub const uniform = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };

    /// Decreasing (natural)
    pub const natural = [_]f32{ 1.0, 0.7, 0.5, 0.35, 0.25, 0.18, 0.12, 0.08, 0.05 };

    /// Bright (emphasized highs)
    pub const bright = [_]f32{ 0.7, 1.0, 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4 };

    /// Mellow (reduced highs)
    pub const mellow = [_]f32{ 1.0, 0.5, 0.25, 0.12, 0.06, 0.03, 0.015, 0.008, 0.004 };
};

// =============================================================================
// Preset Builders
// =============================================================================

/// Build a bell-like resonator
pub fn buildBell(
    allocator: std.mem.Allocator,
    fundamental: f32,
    decay_time: f32,
    brightness: f32,
    sample_rate: u32,
) !ModalResonator {
    var resonator = try ModalResonator.init(allocator, 16, sample_rate);

    for (0..ModalPresets.bell.len) |i| {
        const freq = fundamental * ModalPresets.bell[i];
        const decay = decay_time * DecayPresets.natural[i];
        var amp = AmplitudePresets.natural[i];

        // Brightness affects high mode amplitudes
        if (i > 2) {
            amp *= brightness;
        }

        resonator.addMode(freq, decay, amp);
    }

    return resonator;
}

/// Build a marimba/bar-like resonator
pub fn buildBar(
    allocator: std.mem.Allocator,
    fundamental: f32,
    decay_time: f32,
    hardness: f32,
    sample_rate: u32,
) !ModalResonator {
    var resonator = try ModalResonator.init(allocator, 8, sample_rate);

    for (0..ModalPresets.bar.len) |i| {
        const freq = fundamental * ModalPresets.bar[i];
        const decay = decay_time * DecayPresets.natural[i];
        var amp = AmplitudePresets.natural[i];

        // Hardness affects attack/high harmonics
        amp *= 1.0 + (hardness - 0.5) * @as(f32, @floatFromInt(i)) * 0.2;

        resonator.addMode(freq, decay, @max(0.0, amp));
    }

    return resonator;
}

/// Build a drum-like resonator
pub fn buildDrum(
    allocator: std.mem.Allocator,
    fundamental: f32,
    decay_time: f32,
    tension: f32,
    sample_rate: u32,
) !ModalResonator {
    var resonator = try ModalResonator.init(allocator, 12, sample_rate);

    for (0..ModalPresets.membrane.len) |i| {
        // Tension affects frequency ratios
        var ratio = ModalPresets.membrane[i];
        ratio = 1.0 + (ratio - 1.0) * (0.5 + tension * 0.5);

        const freq = fundamental * ratio;
        const decay = decay_time * DecayPresets.damped[i];
        const amp = AmplitudePresets.natural[i];

        resonator.addMode(freq, decay, amp);
    }

    return resonator;
}

/// Build a string-like resonator with stiffness
pub fn buildString(
    allocator: std.mem.Allocator,
    fundamental: f32,
    decay_time: f32,
    stiffness: f32,
    sample_rate: u32,
) !ModalResonator {
    var resonator = try ModalResonator.init(allocator, 16, sample_rate);

    // Generate harmonics with inharmonicity from stiffness
    for (1..17) |n| {
        const n_f = @as(f32, @floatFromInt(n));

        // Inharmonicity: f_n = n * f_1 * sqrt(1 + B * n^2)
        // B is stiffness coefficient
        const B = stiffness * 0.0001;
        const ratio = n_f * @sqrt(1.0 + B * n_f * n_f);

        const freq = fundamental * ratio;
        const decay = decay_time / (1.0 + stiffness * n_f * 0.1);
        const amp = 1.0 / n_f; // 1/n amplitude rolloff

        resonator.addMode(freq, decay, amp);
    }

    return resonator;
}

// =============================================================================
// Excitation Sources
// =============================================================================

/// Generate impulse excitation
pub fn impulseExcitation(output: []f32, amplitude: f32) void {
    @memset(output, 0.0);
    if (output.len > 0) {
        output[0] = amplitude;
    }
}

/// Generate noise burst excitation
pub fn noiseBurstExcitation(output: []f32, amplitude: f32, decay_samples: usize) void {
    var rng = std.rand.DefaultPrng.init(@intCast(sys.milliTimestamp() & 0xFFFFFFFF));

    for (0..output.len) |i| {
        var sample = (rng.random().float(f32) * 2.0 - 1.0) * amplitude;

        // Exponential decay
        if (i < decay_samples) {
            sample *= @exp(-3.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(decay_samples)));
        } else {
            sample = 0.0;
        }

        output[i] = sample;
    }
}

/// Generate mallet/hammer excitation
pub fn malletExcitation(output: []f32, amplitude: f32, hardness: f32) void {
    // Raised cosine attack with variable width based on hardness
    const attack_len = @as(usize, @intFromFloat((1.0 - hardness * 0.9) * @as(f32, @floatFromInt(output.len / 2))));

    for (0..output.len) |i| {
        if (i < attack_len) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(attack_len));
            output[i] = amplitude * 0.5 * (1.0 - @cos(math.pi * t));
        } else if (i < attack_len * 2) {
            const t = @as(f32, @floatFromInt(i - attack_len)) / @as(f32, @floatFromInt(attack_len));
            output[i] = amplitude * 0.5 * (1.0 + @cos(math.pi * t));
        } else {
            output[i] = 0.0;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "single mode" {
    const testing = std.testing;

    var mode = Mode.init(440.0, 1.0, 1.0, 44100);
    mode.excite(1.0);

    // Should produce output
    var has_output = false;
    for (0..1000) |_| {
        const out = mode.process();
        if (@abs(out) > 0.01) has_output = true;
    }
    try testing.expect(has_output);

    // Should decay. Mode.init's decay_time is the time to fall by e^-3
    // (about 0.05 amplitude), so after ~1.02 s the peak must sit near 0.05.
    // The old check summed |out| over 100 samples, which is ~100x the peak
    // and could never be below 0.1; assert on the peak instead.
    for (0..44100) |_| {
        _ = mode.process();
    }
    var late_peak: f32 = 0.0;
    for (0..100) |_| {
        late_peak = @max(late_peak, @abs(mode.process()));
    }
    try testing.expect(late_peak < 0.06);
    try testing.expect(late_peak > 0.03);
}

test "modal resonator" {
    const testing = std.testing;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resonator = try ModalResonator.init(allocator, 8, 44100);
    defer resonator.deinit();

    // Add bell-like modes
    resonator.addMode(440.0, 2.0, 1.0);
    resonator.addMode(880.0, 1.5, 0.5);
    resonator.addMode(1320.0, 1.0, 0.25);

    try testing.expectEqual(@as(usize, 3), resonator.num_modes);

    resonator.excite(1.0);

    // Should produce sound
    var output: [512]f32 = undefined;
    resonator.processBlock(&output);

    var has_output = false;
    for (output) |s| {
        if (@abs(s) > 0.01) has_output = true;
    }
    try testing.expect(has_output);
}

test "preset builders" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bell = try buildBell(allocator, 440.0, 2.0, 0.5, 44100);
    defer bell.deinit();

    const testing = std.testing;
    try testing.expect(bell.num_modes > 0);

    bell.excite(1.0);
    const sample = bell.process();
    _ = sample;
}
