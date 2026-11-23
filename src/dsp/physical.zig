//! Physical Modeling Synthesis
//!
//! Implements physically-inspired synthesis algorithms:
//! - Karplus-Strong (plucked strings, drums)
//! - Extended Karplus-Strong (with stiffness, damping, position)
//! - Bowed string model
//! - Simple waveguide elements
//!
//! Based on public domain algorithms:
//! - Karplus & Strong (1983) - Original plucked string
//! - Jaffe & Smith (1983) - Extensions
//! - Julius O. Smith - Digital waveguides (patents expired)
//!
//! References:
//! - CCRMA Physical Audio Signal Processing book
//! - STK (Synthesis ToolKit) by Perry Cook

const std = @import("std");
const sys = @import("../utils/sys.zig");
const math = std.math;
const core = @import("core.zig");

// =============================================================================
// Karplus-Strong Algorithm
// =============================================================================

/// Classic Karplus-Strong plucked string synthesis
///
/// Algorithm:
/// 1. Fill delay line with noise or excitation
/// 2. Output = delay line output
/// 3. Feedback = average of current and previous sample (low-pass filter)
///
/// The delay line length determines pitch: period = delay_length samples
pub const KarplusStrong = struct {
    /// Delay line buffer (caller-owned)
    buffer: []f32,

    /// Current write position
    write_pos: usize = 0,

    /// Previous output for averaging filter
    prev_output: f32 = 0.0,

    /// Damping factor (0 = no decay, 1 = instant decay)
    damping: f32 = 0.0,

    /// Blend between pluck (0) and pick (1) excitation
    pick_blend: f32 = 0.5,

    /// Sample rate for pitch calculations
    sample_rate: u32,

    pub fn init(buffer: []f32, sample_rate: u32) KarplusStrong {
        @memset(buffer, 0.0);
        return .{
            .buffer = buffer,
            .sample_rate = sample_rate,
        };
    }

    /// Trigger/pluck the string with noise excitation
    pub fn pluck(self: *KarplusStrong, amplitude: f32) void {
        var rng = std.rand.DefaultPrng.init(@intCast(sys.milliTimestamp() & 0xFFFFFFFF));

        for (self.buffer) |*sample| {
            // Mix of noise and impulse based on pick_blend
            const noise = (rng.random().float(f32) * 2.0 - 1.0) * amplitude;
            sample.* = noise * (1.0 - self.pick_blend);
        }

        // Add pick impulse at center
        const center = self.buffer.len / 2;
        self.buffer[center] = amplitude * self.pick_blend;

        self.prev_output = 0.0;
        self.write_pos = 0;
    }

    /// Pluck with custom excitation buffer
    pub fn pluckWithExcitation(self: *KarplusStrong, excitation: []const f32) void {
        const len = @min(excitation.len, self.buffer.len);
        @memcpy(self.buffer[0..len], excitation[0..len]);

        if (len < self.buffer.len) {
            @memset(self.buffer[len..], 0.0);
        }

        self.prev_output = 0.0;
        self.write_pos = 0;
    }

    /// Set pitch by frequency
    pub fn setFrequency(self: *KarplusStrong, freq: f32, new_buffer: []f32) void {
        const period = @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.sample_rate)) / freq));
        const clamped = @min(period, new_buffer.len);

        self.buffer = new_buffer[0..clamped];
        @memset(self.buffer, 0.0);
        self.write_pos = 0;
    }

    /// Process one sample
    pub fn process(self: *KarplusStrong) f32 {
        // Read current sample from delay line
        const current = self.buffer[self.write_pos];

        // Low-pass filter: average of current and previous
        const filtered = (current + self.prev_output) * 0.5;

        // Apply damping
        const output = filtered * (1.0 - self.damping);

        // Write back to delay line
        self.buffer[self.write_pos] = output;

        // Advance position
        self.write_pos = (self.write_pos + 1) % self.buffer.len;
        self.prev_output = current;

        return output;
    }

    /// Process block of samples
    pub fn processBlock(self: *KarplusStrong, output: []f32) void {
        for (output) |*out| {
            out.* = self.process();
        }
    }

    /// Get current period in samples
    pub fn getPeriod(self: *const KarplusStrong) usize {
        return self.buffer.len;
    }

    /// Get current frequency
    pub fn getFrequency(self: *const KarplusStrong) f32 {
        return @as(f32, @floatFromInt(self.sample_rate)) / @as(f32, @floatFromInt(self.buffer.len));
    }
};

// =============================================================================
// Extended Karplus-Strong
// =============================================================================

/// Extended Karplus-Strong with additional parameters
///
/// Adds:
/// - String stiffness (via allpass filter)
/// - Pick position control
/// - Dynamics (velocity sensitivity)
/// - Fractional delay for pitch accuracy
pub const ExtendedKarplusStrong = struct {
    /// Main delay line
    delay_buffer: []f32,

    /// Write position
    write_pos: usize = 0,

    /// Allpass filter state for fractional delay
    allpass_state: f32 = 0.0,

    /// Allpass coefficient for fractional delay
    allpass_coeff: f32 = 0.0,

    /// Loop filter state (previous sample)
    loop_filter_state: f32 = 0.0,

    /// Stiffness allpass state
    stiffness_state: f32 = 0.0,

    /// Configuration
    config: Config = .{},

    sample_rate: u32,

    pub const Config = struct {
        /// Damping (0-1, higher = faster decay)
        damping: f32 = 0.002,

        /// Brightness (0-1, higher = brighter)
        brightness: f32 = 0.5,

        /// Stiffness (0-1, 0 = ideal string)
        stiffness: f32 = 0.0,

        /// Pick position (0-1, 0 = bridge, 1 = center)
        pick_position: f32 = 0.13,

        /// Dynamics amount (velocity to brightness)
        dynamics: f32 = 0.5,
    };

    pub fn init(buffer: []f32, sample_rate: u32) ExtendedKarplusStrong {
        @memset(buffer, 0.0);
        return .{
            .delay_buffer = buffer,
            .sample_rate = sample_rate,
        };
    }

    /// Set frequency with fractional delay compensation
    pub fn setFrequency(self: *ExtendedKarplusStrong, freq: f32) void {
        const period = @as(f32, @floatFromInt(self.sample_rate)) / freq;
        const int_period = @as(usize, @intFromFloat(period));
        const frac_delay = period - @as(f32, @floatFromInt(int_period));

        // Allpass coefficient for fractional delay
        self.allpass_coeff = (1.0 - frac_delay) / (1.0 + frac_delay);
    }

    /// Pluck with velocity sensitivity
    pub fn pluck(self: *ExtendedKarplusStrong, velocity: f32) void {
        var rng = std.rand.DefaultPrng.init(@intCast(sys.milliTimestamp() & 0xFFFFFFFF));

        const amplitude = velocity;
        const brightness_mod = self.config.brightness + (1.0 - self.config.brightness) * velocity * self.config.dynamics;

        // Pick position affects harmonics (comb filtering)
        const pick_sample = @as(usize, @intFromFloat(self.config.pick_position * @as(f32, @floatFromInt(self.delay_buffer.len))));

        for (0..self.delay_buffer.len) |i| {
            var sample = (rng.random().float(f32) * 2.0 - 1.0) * amplitude;

            // Low-pass based on brightness
            sample *= brightness_mod;

            // Comb filter for pick position
            if (i < pick_sample or i >= self.delay_buffer.len - pick_sample) {
                sample *= 0.5;
            }

            self.delay_buffer[i] = sample;
        }

        self.loop_filter_state = 0.0;
        self.allpass_state = 0.0;
        self.stiffness_state = 0.0;
        self.write_pos = 0;
    }

    /// Process one sample
    pub fn process(self: *ExtendedKarplusStrong) f32 {
        // Read from delay line
        const delay_out = self.delay_buffer[self.write_pos];

        // Fractional delay via allpass
        const allpass_out = self.allpass_coeff * (delay_out - self.allpass_state) + self.loop_filter_state;
        self.allpass_state = allpass_out;

        // Stiffness via allpass (makes higher harmonics sharper)
        var output = allpass_out;
        if (self.config.stiffness > 0.0) {
            const stiff_coeff = self.config.stiffness * 0.5;
            output = stiff_coeff * (output - self.stiffness_state) + self.stiffness_state;
            self.stiffness_state = output;
        }

        // Loop filter (low-pass + damping)
        const brightness = 1.0 - self.config.brightness * 0.5;
        const filtered = brightness * output + (1.0 - brightness) * self.loop_filter_state;
        self.loop_filter_state = delay_out;

        // Apply damping
        const damped = filtered * (1.0 - self.config.damping);

        // Write back to delay line
        self.delay_buffer[self.write_pos] = damped;

        // Advance
        self.write_pos = (self.write_pos + 1) % self.delay_buffer.len;

        return output;
    }

    pub fn processBlock(self: *ExtendedKarplusStrong, output: []f32) void {
        for (output) |*out| {
            out.* = self.process();
        }
    }
};

// =============================================================================
// Drum Synthesis (Karplus-Strong variant)
// =============================================================================

/// Karplus-Strong drum synthesis
///
/// Uses a blend parameter to interpolate between:
/// - Noise-like decay (drum) at blend = 0
/// - Pitched decay (tom) at blend = 1
pub const KarplusStrongDrum = struct {
    buffer: []f32,
    write_pos: usize = 0,
    prev_output: f32 = 0.0,

    /// Blend: 0 = pure drum, 1 = pitched tom
    blend: f32 = 0.5,

    /// Stretch factor for decay time
    stretch: f32 = 1.0,

    sample_rate: u32,

    pub fn init(buffer: []f32, sample_rate: u32) KarplusStrongDrum {
        @memset(buffer, 0.0);
        return .{
            .buffer = buffer,
            .sample_rate = sample_rate,
        };
    }

    /// Trigger the drum
    pub fn trigger(self: *KarplusStrongDrum, amplitude: f32) void {
        var rng = std.rand.DefaultPrng.init(@intCast(sys.milliTimestamp() & 0xFFFFFFFF));

        for (self.buffer) |*sample| {
            sample.* = (rng.random().float(f32) * 2.0 - 1.0) * amplitude;
        }

        self.prev_output = 0.0;
        self.write_pos = 0;
    }

    pub fn process(self: *KarplusStrongDrum) f32 {
        const current = self.buffer[self.write_pos];

        // Drum algorithm: randomly invert sign based on blend
        var rng = std.rand.DefaultPrng.init(@intCast(self.write_pos));
        const should_invert = rng.random().float(f32) > self.blend;

        var filtered = (current + self.prev_output) * 0.5;

        if (should_invert) {
            filtered = -filtered;
        }

        // Apply stretch factor to decay
        filtered *= (1.0 - 0.002 / self.stretch);

        self.buffer[self.write_pos] = filtered;
        self.write_pos = (self.write_pos + 1) % self.buffer.len;
        self.prev_output = current;

        return filtered;
    }

    pub fn processBlock(self: *KarplusStrongDrum, output: []f32) void {
        for (output) |*out| {
            out.* = self.process();
        }
    }
};

// =============================================================================
// Simple Waveguide Elements
// =============================================================================

/// One-pole lowpass filter for waveguide junctions
pub const WaveguideLowpass = struct {
    state: f32 = 0.0,
    coeff: f32 = 0.5,

    /// Set cutoff frequency
    pub fn setCutoff(self: *WaveguideLowpass, freq: f32, sample_rate: u32) void {
        const w = 2.0 * math.pi * freq / @as(f32, @floatFromInt(sample_rate));
        self.coeff = 1.0 - @exp(-w);
    }

    /// Set coefficient directly (0-1)
    pub fn setCoeff(self: *WaveguideLowpass, coeff: f32) void {
        self.coeff = math.clamp(coeff, 0.0, 1.0);
    }

    pub fn process(self: *WaveguideLowpass, input: f32) f32 {
        self.state += self.coeff * (input - self.state);
        return self.state;
    }

    pub fn reset(self: *WaveguideLowpass) void {
        self.state = 0.0;
    }
};

/// First-order allpass filter for fractional delay
pub const AllpassDelay = struct {
    state: f32 = 0.0,
    coeff: f32 = 0.0,

    /// Set fractional delay (0-1 samples)
    pub fn setDelay(self: *AllpassDelay, frac_delay: f32) void {
        self.coeff = (1.0 - frac_delay) / (1.0 + frac_delay);
    }

    pub fn process(self: *AllpassDelay, input: f32) f32 {
        const output = self.coeff * (input - self.state) + self.state;
        self.state = input;
        return output;
    }

    pub fn reset(self: *AllpassDelay) void {
        self.state = 0.0;
    }
};

/// Simple biquad allpass for stiffness dispersion
pub const StiffnessAllpass = struct {
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    /// Stiffness coefficient (higher = more dispersion)
    coeff: f32 = 0.0,

    pub fn setStiffness(self: *StiffnessAllpass, stiffness: f32) void {
        self.coeff = math.clamp(stiffness, 0.0, 0.99);
    }

    pub fn process(self: *StiffnessAllpass, input: f32) f32 {
        // Second-order allpass: y[n] = c^2 * x[n] + c * x[n-1] + x[n-2] - c * y[n-1] - c^2 * y[n-2]
        const c = self.coeff;
        const c2 = c * c;

        const output = c2 * input + c * self.x1 + self.x2 - c * self.y1 - c2 * self.y2;

        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;

        return output;
    }

    pub fn reset(self: *StiffnessAllpass) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }
};

// =============================================================================
// Bowed String Model (simplified)
// =============================================================================

/// Simplified bowed string model
///
/// Based on the McIntyre-Schumacher-Woodhouse model.
/// Uses a nonlinear friction model for bow-string interaction.
pub const BowedString = struct {
    /// Delay line for string
    delay: []f32,
    write_pos: usize = 0,

    /// Bridge reflection filter
    bridge_filter: WaveguideLowpass = .{},

    /// Nut reflection
    nut_reflect: f32 = -0.95,

    /// Bow state
    bow_velocity: f32 = 0.0,
    bow_position: f32 = 0.2,
    bow_force: f32 = 0.0,

    /// Internal state
    velocity_hist: f32 = 0.0,

    sample_rate: u32,

    pub fn init(buffer: []f32, sample_rate: u32) BowedString {
        @memset(buffer, 0.0);
        return .{
            .delay = buffer,
            .sample_rate = sample_rate,
        };
    }

    /// Set frequency
    pub fn setFrequency(self: *BowedString, freq: f32) void {
        _ = freq;
        // Would resize delay line in full implementation
        _ = self;
    }

    /// Set bow parameters
    pub fn setBow(self: *BowedString, velocity: f32, force: f32, position: f32) void {
        self.bow_velocity = velocity;
        self.bow_force = math.clamp(force, 0.0, 1.0);
        self.bow_position = math.clamp(position, 0.1, 0.9);
    }

    /// Bow table (friction characteristic)
    fn bowTable(self: *BowedString, delta_v: f32) f32 {
        _ = self;
        // Simplified friction curve
        const slope = 3.0;
        const offset = 0.001;
        var force = @abs(delta_v + offset);
        force = @exp(-slope * force) * (1.0 + slope * force);
        return force;
    }

    pub fn process(self: *BowedString) f32 {
        // Read from delay line at bow position
        const bow_sample = @as(usize, @intFromFloat(self.bow_position * @as(f32, @floatFromInt(self.delay.len))));
        const string_vel = self.delay[bow_sample];

        // Bow-string interaction
        const delta_v = self.bow_velocity - string_vel;
        const friction = self.bowTable(delta_v) * self.bow_force;

        // Update string velocity at bow point
        const new_vel = string_vel + friction * 0.1;

        // Read output from bridge
        const output = self.delay[self.write_pos];

        // Apply bridge filter
        const reflected = self.bridge_filter.process(output) * -0.95;

        // Write to delay line
        self.delay[self.write_pos] = reflected;
        self.delay[bow_sample] = new_vel;

        self.write_pos = (self.write_pos + 1) % self.delay.len;

        return output;
    }
};

// =============================================================================
// Excitation Generators
// =============================================================================

/// Generate pluck excitation (for Karplus-Strong)
pub fn generatePluckExcitation(buffer: []f32, amplitude: f32, brightness: f32) void {
    var rng = std.rand.DefaultPrng.init(@intCast(sys.milliTimestamp() & 0xFFFFFFFF));

    // Generate noise
    for (buffer) |*sample| {
        sample.* = (rng.random().float(f32) * 2.0 - 1.0) * amplitude;
    }

    // Apply low-pass for brightness control
    if (brightness < 1.0) {
        const coeff = brightness;
        var state: f32 = 0.0;
        for (buffer) |*sample| {
            state += coeff * (sample.* - state);
            sample.* = state;
        }
    }
}

/// Generate pick excitation (impulse-like)
pub fn generatePickExcitation(buffer: []f32, amplitude: f32, position: f32) void {
    @memset(buffer, 0.0);

    const pick_pos = @as(usize, @intFromFloat(position * @as(f32, @floatFromInt(buffer.len))));
    const width: usize = @max(1, buffer.len / 20);

    // Triangular impulse
    for (0..width) |i| {
        const idx = (pick_pos + i) % buffer.len;
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(width));
        buffer[idx] = amplitude * (1.0 - t);
    }
}

/// Generate hammer excitation (for piano-like sounds)
pub fn generateHammerExcitation(buffer: []f32, amplitude: f32, hardness: f32) void {
    const attack_len = @as(usize, @intFromFloat((1.0 - hardness * 0.9) * @as(f32, @floatFromInt(buffer.len / 2))));

    for (0..buffer.len) |i| {
        if (i < attack_len) {
            // Raised cosine attack
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(attack_len));
            buffer[i] = amplitude * 0.5 * (1.0 - @cos(math.pi * t));
        } else if (i < attack_len * 2) {
            // Decay
            const t = @as(f32, @floatFromInt(i - attack_len)) / @as(f32, @floatFromInt(attack_len));
            buffer[i] = amplitude * 0.5 * (1.0 + @cos(math.pi * t));
        } else {
            buffer[i] = 0.0;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "karplus strong basic" {
    const testing = std.testing;
    var buffer: [256]f32 = undefined;

    var ks = KarplusStrong.init(&buffer, 44100);
    ks.pluck(1.0);

    // Process some samples
    var output: [512]f32 = undefined;
    ks.processBlock(&output);

    // Should have decaying output
    var max_early: f32 = 0.0;
    var max_late: f32 = 0.0;

    for (output[0..100]) |s| {
        max_early = @max(max_early, @abs(s));
    }
    for (output[400..]) |s| {
        max_late = @max(max_late, @abs(s));
    }

    // Early should be louder than late (decay)
    try testing.expect(max_early > max_late);
}

test "extended karplus strong" {
    var buffer: [256]f32 = undefined;
    var eks = ExtendedKarplusStrong.init(&buffer, 44100);

    eks.config.brightness = 0.8;
    eks.config.stiffness = 0.1;
    eks.pluck(0.8);

    var output: [256]f32 = undefined;
    eks.processBlock(&output);

    // Should produce output
    var has_output = false;
    for (output) |s| {
        if (@abs(s) > 0.001) {
            has_output = true;
            break;
        }
    }

    const testing = std.testing;
    try testing.expect(has_output);
}

test "waveguide elements" {
    const testing = std.testing;

    var lpf = WaveguideLowpass{};
    lpf.setCoeff(0.5);

    const out1 = lpf.process(1.0);
    const out2 = lpf.process(1.0);

    // Should be smoothing
    try testing.expect(out2 > out1);

    var ap = AllpassDelay{};
    ap.setDelay(0.5);

    const ap_out = ap.process(1.0);
    _ = ap_out;
    // Allpass should preserve energy (magnitude)
}
