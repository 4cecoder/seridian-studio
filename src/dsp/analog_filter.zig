//! Analog Filter Emulations
//!
//! Classic analog filter algorithms with authentic nonlinear behavior:
//! - Moog Ladder Filter (4-pole lowpass with resonance)
//! - TB-303 Style Filter (acid bass character)
//! - Formant Filter (vowel synthesis)
//! - Oberheim SEM Filter (state-variable with character)
//!
//! Based on algorithms from:
//! - LMMS BasicFilters.h
//! - Välimäki & Smith "Analog Modeling" papers
//! - CSound filter implementations
//!
//! All filters support self-oscillation and maintain internal state
//! for sample-by-sample processing.

const std = @import("std");
const math = std.math;
const dsp = @import("dsp.zig");

// =============================================================================
// Moog Ladder Filter
// =============================================================================

/// Classic Moog 4-pole ladder filter with resonance and self-oscillation
/// Based on Stilson & Smith's digital model with empirical tuning
pub const MoogLadder = struct {
    // Filter state (4 cascaded one-pole stages)
    stage: [4]f32 = .{ 0, 0, 0, 0 },
    delay: [4]f32 = .{ 0, 0, 0, 0 },

    // Coefficients
    p: f32 = 0,
    k: f32 = 0,
    t1: f32 = 0,
    t2: f32 = 0,

    sample_rate: f32,
    cutoff: f32 = 1000,
    resonance: f32 = 0,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setCutoff(1000);
        self.setResonance(0);
        return self;
    }

    /// Set cutoff frequency (20 Hz - 20 kHz)
    pub fn setCutoff(self: *Self, freq: f32) void {
        self.cutoff = math.clamp(freq, 20, self.sample_rate * 0.49);

        // Compute normalized frequency
        const f = self.cutoff / self.sample_rate;

        // Empirical tuning formula (attempt to match analog response)
        // p = frequency coefficient, attempt to correct for warping
        self.p = f * (1.8 - 0.8 * f);

        // k = 2 * sin(f * pi/2) - 1 approximation for low frequencies
        self.k = 2.0 * @sin(f * math.pi * 0.5) - 1.0;

        // Tuning coefficients
        self.t1 = (1.0 - self.p) * 1.386249;
        self.t2 = 12.0 + self.t1 * self.t1;
    }

    /// Set resonance (0.0 - 1.0, >1.0 for self-oscillation)
    pub fn setResonance(self: *Self, res: f32) void {
        self.resonance = math.clamp(res, 0, 1.25);
    }

    /// Process a single sample
    pub fn process(self: *Self, input: f32) f32 {
        // Resonance with thermal noise (prevents denormals)
        const noise = 1.0e-10;

        // Input with feedback (resonance)
        const feedback = self.resonance * 4.0 * (self.delay[3] - input * 0.5);
        var x = input - feedback + noise;

        // Soft clip input to prevent runaway
        x = softClip(x);

        // Four cascaded one-pole stages with nonlinearity
        self.stage[0] = x * self.p + self.delay[0] * self.p - self.k * self.stage[0];
        self.delay[0] = x;

        self.stage[1] = self.stage[0] * self.p + self.delay[1] * self.p - self.k * self.stage[1];
        self.delay[1] = self.stage[0];

        self.stage[2] = self.stage[1] * self.p + self.delay[2] * self.p - self.k * self.stage[2];
        self.delay[2] = self.stage[1];

        self.stage[3] = self.stage[2] * self.p + self.delay[3] * self.p - self.k * self.stage[3];
        self.delay[3] = self.stage[2];

        return self.stage[3];
    }

    /// Process a block of samples
    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    /// Reset filter state
    pub fn reset(self: *Self) void {
        self.stage = .{ 0, 0, 0, 0 };
        self.delay = .{ 0, 0, 0, 0 };
    }
};

// =============================================================================
// Improved Moog Ladder (Huovilainen model)
// =============================================================================

/// Improved Moog ladder filter based on Antti Huovilainen's model
/// Better high-frequency accuracy and resonance behavior
pub const MoogLadderHuovilainen = struct {
    // State variables
    stage: [4]f32 = .{ 0, 0, 0, 0 },
    stage_tanh: [3]f32 = .{ 0, 0, 0 },

    // Coefficients
    cutoff_hz: f32 = 1000,
    resonance: f32 = 0,
    thermal: f32 = 0.000025,

    // Derived values
    tune: f32 = 0,
    acr: f32 = 0,
    res_quad: f32 = 0,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.update();
        return self;
    }

    pub fn setCutoff(self: *Self, freq: f32) void {
        self.cutoff_hz = math.clamp(freq, 20, self.sample_rate * 0.49);
        self.update();
    }

    pub fn setResonance(self: *Self, res: f32) void {
        self.resonance = math.clamp(res, 0, 1.0);
        self.update();
    }

    fn update(self: *Self) void {
        // Attempt frequency warping compensation
        const fc = self.cutoff_hz / self.sample_rate;
        const fc2 = fc * fc;
        const fc3 = fc2 * fc;

        // Attempt polynomial frequency correction
        const fcr = 1.8730 * fc3 + 0.4955 * fc2 - 0.6490 * fc + 0.9988;
        self.acr = -3.9364 * fc2 + 1.8409 * fc + 0.9968;

        self.tune = (1.0 - @exp(-2.0 * math.pi * fc * fcr)) / self.thermal;
        self.res_quad = 4.0 * self.resonance * self.acr;
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Input with resonance feedback
        var x = input - self.res_quad * self.stage[3];

        // Soft clip for stability
        x = fastTanh(x * self.thermal) / self.thermal;

        // Four stages with interleaved nonlinearities
        inline for (0..4) |i| {
            const prev = if (i == 0) x else self.stage_tanh[i - 1];
            self.stage[i] += self.tune * (prev - self.stage[i]);
            if (i < 3) {
                self.stage_tanh[i] = fastTanh(self.stage[i] * self.thermal);
            }
        }

        return self.stage[3];
    }

    pub fn reset(self: *Self) void {
        self.stage = .{ 0, 0, 0, 0 };
        self.stage_tanh = .{ 0, 0, 0 };
    }
};

// =============================================================================
// TB-303 Style Filter
// =============================================================================

/// TB-303 style filter with characteristic acid sound
/// Features envelope-modulated cutoff and accent behavior
pub const TB303Filter = struct {
    // State variables (3-pole)
    d1: f32 = 0,
    d2: f32 = 0,
    d3: f32 = 0,
    c0: f32 = 0,

    // Coefficients
    a: f32 = 0,
    b: f32 = 0,
    c: f32 = 0,

    // Parameters
    cutoff: f32 = 1000,
    resonance: f32 = 0.5,
    env_mod: f32 = 0,
    env_decay: f32 = 0.9999,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setCutoff(1000);
        self.setResonance(0.5);
        self.setEnvDecay(200); // 200ms decay
        return self;
    }

    pub fn setCutoff(self: *Self, freq: f32) void {
        self.cutoff = math.clamp(freq, 20, self.sample_rate * 0.4);
        self.updateCoeffs();
    }

    pub fn setResonance(self: *Self, res: f32) void {
        self.resonance = math.clamp(res, 0, 1.0);
        self.updateCoeffs();
    }

    /// Set envelope decay time in milliseconds
    pub fn setEnvDecay(self: *Self, ms: f32) void {
        const samples = ms * self.sample_rate / 1000.0;
        self.env_decay = @exp(-1.0 / samples);
    }

    /// Set envelope modulation amount (0.0 - 1.0)
    pub fn setEnvMod(self: *Self, amount: f32) void {
        self.env_mod = math.clamp(amount, 0, 1);
    }

    fn updateCoeffs(self: *Self) void {
        // Attempt to model 303's unique filter topology
        const w = 2.0 * math.pi * self.cutoff / self.sample_rate;
        const k = w / (w + 1.0);

        // Resonance feedback coefficient
        const q = 1.0 - self.resonance;

        self.a = k;
        self.b = k * k * k;
        self.c = 1.0 - q;
    }

    /// Trigger the filter envelope (call on note-on)
    pub fn trigger(self: *Self, accent: f32) void {
        // Envelope starts high and decays
        self.c0 = 1.0 + accent * 2.0;
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Decay the envelope
        self.c0 *= self.env_decay;

        // Calculate current cutoff with envelope modulation
        const env_offset = self.c0 * self.env_mod * 4000.0;
        const current_cutoff = self.cutoff + env_offset;

        // Recalculate coefficients for modulated cutoff
        const w = 2.0 * math.pi * math.clamp(current_cutoff, 20, self.sample_rate * 0.4) / self.sample_rate;
        const k = w / (w + 1.0);

        // 3-pole filter with feedback
        const feedback = self.resonance * self.d3;
        const in = input - feedback;

        // Three cascaded one-pole stages
        self.d1 += k * (in - self.d1);
        self.d2 += k * (self.d1 - self.d2);
        self.d3 += k * (self.d2 - self.d3);

        // Add some harmonic distortion characteristic of 303
        return fastTanh(self.d3 * (1.0 + self.resonance));
    }

    pub fn reset(self: *Self) void {
        self.d1 = 0;
        self.d2 = 0;
        self.d3 = 0;
        self.c0 = 0;
    }
};

// =============================================================================
// Formant Filter (Vowel Synthesis)
// =============================================================================

/// Vowel formant frequencies (Hz) for common vowels
pub const FormantPreset = struct {
    f1: f32, // First formant
    f2: f32, // Second formant
    f3: f32, // Third formant (optional)
    a1: f32, // Amplitude 1
    a2: f32, // Amplitude 2
    a3: f32, // Amplitude 3
};

pub const Vowels = struct {
    pub const A: FormantPreset = .{ .f1 = 800, .f2 = 1200, .f3 = 2800, .a1 = 1.0, .a2 = 0.5, .a3 = 0.25 };
    pub const E: FormantPreset = .{ .f1 = 400, .f2 = 2200, .f3 = 2800, .a1 = 1.0, .a2 = 0.5, .a3 = 0.25 };
    pub const I: FormantPreset = .{ .f1 = 280, .f2 = 2600, .f3 = 3200, .a1 = 1.0, .a2 = 0.4, .a3 = 0.2 };
    pub const O: FormantPreset = .{ .f1 = 500, .f2 = 800, .f3 = 2800, .a1 = 1.0, .a2 = 0.6, .a3 = 0.2 };
    pub const U: FormantPreset = .{ .f1 = 320, .f2 = 800, .f3 = 2500, .a1 = 1.0, .a2 = 0.4, .a3 = 0.2 };
};

/// Single resonant bandpass for formant
const FormantBand = struct {
    // State-variable filter state
    low: f32 = 0,
    band: f32 = 0,

    freq: f32 = 1000,
    q: f32 = 10,
    amp: f32 = 1.0,

    f_coef: f32 = 0,
    q_coef: f32 = 0,

    fn setParams(self: *FormantBand, freq: f32, q: f32, amp: f32, sample_rate: f32) void {
        self.freq = freq;
        self.q = q;
        self.amp = amp;

        self.f_coef = 2.0 * @sin(math.pi * freq / sample_rate);
        self.q_coef = 1.0 / q;
    }

    fn process(self: *FormantBand, input: f32) f32 {
        // State-variable bandpass
        self.low += self.f_coef * self.band;
        const high = input - self.low - self.q_coef * self.band;
        self.band += self.f_coef * high;

        return self.band * self.amp;
    }

    fn reset(self: *FormantBand) void {
        self.low = 0;
        self.band = 0;
    }
};

/// Formant filter with 3 parallel bandpass filters
pub const FormantFilter = struct {
    bands: [3]FormantBand = .{ .{}, .{}, .{} },
    sample_rate: f32,

    // Vowel morphing
    current: FormantPreset = Vowels.A,
    target: FormantPreset = Vowels.A,
    morph: f32 = 0,
    morph_speed: f32 = 0.001,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setVowel(Vowels.A);
        return self;
    }

    /// Set vowel preset directly
    pub fn setVowel(self: *Self, preset: FormantPreset) void {
        self.current = preset;
        self.target = preset;
        self.morph = 1.0;
        self.updateBands();
    }

    /// Morph toward a target vowel
    pub fn morphTo(self: *Self, preset: FormantPreset, speed: f32) void {
        self.target = preset;
        self.morph = 0;
        self.morph_speed = speed;
    }

    /// Set vowel by interpolating between two presets
    pub fn setVowelBlend(self: *Self, a: FormantPreset, b: FormantPreset, blend: f32) void {
        const t = math.clamp(blend, 0, 1);
        self.current = .{
            .f1 = dsp.lerp(a.f1, b.f1, t),
            .f2 = dsp.lerp(a.f2, b.f2, t),
            .f3 = dsp.lerp(a.f3, b.f3, t),
            .a1 = dsp.lerp(a.a1, b.a1, t),
            .a2 = dsp.lerp(a.a2, b.a2, t),
            .a3 = dsp.lerp(a.a3, b.a3, t),
        };
        self.updateBands();
    }

    fn updateBands(self: *Self) void {
        const q: f32 = 10.0; // Resonance
        self.bands[0].setParams(self.current.f1, q, self.current.a1, self.sample_rate);
        self.bands[1].setParams(self.current.f2, q, self.current.a2, self.sample_rate);
        self.bands[2].setParams(self.current.f3, q * 0.8, self.current.a3, self.sample_rate);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Update morphing
        if (self.morph < 1.0) {
            self.morph += self.morph_speed;
            if (self.morph >= 1.0) {
                self.morph = 1.0;
                self.current = self.target;
            } else {
                self.setVowelBlend(self.current, self.target, self.morph);
            }
        }

        // Sum of parallel bandpass filters
        var output: f32 = 0;
        for (&self.bands) |*band| {
            output += band.process(input);
        }

        return output * 0.5; // Normalize
    }

    pub fn processBlock(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    pub fn reset(self: *Self) void {
        for (&self.bands) |*band| {
            band.reset();
        }
    }
};

// =============================================================================
// Oberheim SEM-Style State Variable Filter
// =============================================================================

/// Oberheim SEM-style state-variable filter
/// Warmer character than standard SVF, with optional nonlinearity
pub const OberheimSVF = struct {
    // State
    low: f32 = 0,
    band: f32 = 0,
    notch: f32 = 0,
    high: f32 = 0,

    // Coefficients
    f_coef: f32 = 0,
    q_coef: f32 = 0,
    damp: f32 = 0,

    // Parameters
    cutoff: f32 = 1000,
    resonance: f32 = 0.5,
    sample_rate: f32,

    // Mode blend (0=LP, 0.5=BP, 1.0=HP)
    mode: f32 = 0,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setCutoff(1000);
        self.setResonance(0.5);
        return self;
    }

    pub fn setCutoff(self: *Self, freq: f32) void {
        self.cutoff = math.clamp(freq, 20, self.sample_rate * 0.49);
        self.updateCoeffs();
    }

    pub fn setResonance(self: *Self, res: f32) void {
        self.resonance = math.clamp(res, 0, 1.0);
        self.updateCoeffs();
    }

    /// Set filter mode (0=LP, 0.5=BP, 1.0=HP, or blend)
    pub fn setMode(self: *Self, mode: f32) void {
        self.mode = math.clamp(mode, 0, 1);
    }

    fn updateCoeffs(self: *Self) void {
        // 2x oversampling compensation
        self.f_coef = 2.0 * @sin(math.pi * self.cutoff / (self.sample_rate * 2.0));
        self.q_coef = 2.0 * (1.0 - self.resonance);
        self.damp = @min(self.q_coef, 2.0 - self.f_coef);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // 2x oversampling for stability at high resonance
        var out: f32 = 0;

        inline for (0..2) |_| {
            self.notch = input - self.damp * self.band;
            self.low += self.f_coef * self.band;
            self.high = self.notch - self.low;
            self.band += self.f_coef * self.high;

            // Apply soft saturation for analog character
            self.band = softClip(self.band);
        }

        // Blend between modes
        if (self.mode <= 0.5) {
            // LP to BP
            const t = self.mode * 2.0;
            out = dsp.lerp(self.low, self.band, t);
        } else {
            // BP to HP
            const t = (self.mode - 0.5) * 2.0;
            out = dsp.lerp(self.band, self.high, t);
        }

        return out;
    }

    /// Get individual outputs
    pub fn getOutputs(self: *Self, input: f32) struct { low: f32, band: f32, high: f32, notch: f32 } {
        _ = self.process(input);
        return .{
            .low = self.low,
            .band = self.band,
            .high = self.high,
            .notch = self.notch,
        };
    }

    pub fn reset(self: *Self) void {
        self.low = 0;
        self.band = 0;
        self.high = 0;
        self.notch = 0;
    }
};

// =============================================================================
// Comb Filter (for reverb/effects)
// =============================================================================

/// Comb filter with optional lowpass in feedback loop
pub fn CombFilter(comptime max_delay: usize) type {
    return struct {
        buffer: [max_delay]f32 = @as([max_delay]f32, @splat(0)),
        write_pos: usize = 0,
        delay_samples: usize = 100,
        feedback: f32 = 0.5,

        // Lowpass in feedback loop (damping)
        lp_state: f32 = 0,
        damping: f32 = 0.5,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn setDelay(self: *Self, samples: usize) void {
            self.delay_samples = @min(samples, max_delay - 1);
        }

        pub fn setDelayMs(self: *Self, ms: f32, sample_rate: f32) void {
            const samples = @as(usize, @intFromFloat(ms * sample_rate / 1000.0));
            self.setDelay(samples);
        }

        pub fn setFeedback(self: *Self, fb: f32) void {
            self.feedback = math.clamp(fb, 0, 0.999);
        }

        pub fn setDamping(self: *Self, damp: f32) void {
            self.damping = math.clamp(damp, 0, 1);
        }

        pub fn process(self: *Self, input: f32) f32 {
            // Read from delay line
            const read_pos = if (self.write_pos >= self.delay_samples)
                self.write_pos - self.delay_samples
            else
                max_delay - (self.delay_samples - self.write_pos);

            const delayed = self.buffer[read_pos];

            // Lowpass filter in feedback (damping)
            self.lp_state = delayed * (1.0 - self.damping) + self.lp_state * self.damping;

            // Write to delay line
            self.buffer[self.write_pos] = input + self.lp_state * self.feedback;

            // Advance write position
            self.write_pos = (self.write_pos + 1) % max_delay;

            return delayed;
        }

        pub fn reset(self: *Self) void {
            @memset(&self.buffer, 0);
            self.lp_state = 0;
            self.write_pos = 0;
        }
    };
}

/// Allpass filter for diffusion
pub fn AllpassFilter(comptime max_delay: usize) type {
    return struct {
        buffer: [max_delay]f32 = @as([max_delay]f32, @splat(0)),
        write_pos: usize = 0,
        delay_samples: usize = 100,
        feedback: f32 = 0.5,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn setDelay(self: *Self, samples: usize) void {
            self.delay_samples = @min(samples, max_delay - 1);
        }

        pub fn setFeedback(self: *Self, fb: f32) void {
            self.feedback = math.clamp(fb, -0.999, 0.999);
        }

        pub fn process(self: *Self, input: f32) f32 {
            const read_pos = if (self.write_pos >= self.delay_samples)
                self.write_pos - self.delay_samples
            else
                max_delay - (self.delay_samples - self.write_pos);

            const delayed = self.buffer[read_pos];

            // Allpass: y[n] = -x[n] + x[n-d] + g*y[n-d]
            const output = -input * self.feedback + delayed;
            self.buffer[self.write_pos] = input + delayed * self.feedback;

            self.write_pos = (self.write_pos + 1) % max_delay;

            return output;
        }

        pub fn reset(self: *Self) void {
            @memset(&self.buffer, 0);
            self.write_pos = 0;
        }
    };
}

// =============================================================================
// Utility Functions
// =============================================================================

fn softClip(x: f32) f32 {
    // Attempt polynomial soft clipper
    if (x > 1.0) return 1.0 - 1.0 / (x + 1.0);
    if (x < -1.0) return -1.0 + 1.0 / (-x + 1.0);
    return x;
}

fn fastTanh(x: f32) f32 {
    // Attempt Pade approximation for tanh
    if (x < -3.0) return -1.0;
    if (x > 3.0) return 1.0;
    const x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

// =============================================================================
// Tests
// =============================================================================

test "moog ladder basic" {
    const testing = std.testing;

    var filter = MoogLadder.init(44100);
    filter.setCutoff(1000);
    filter.setResonance(0.5);

    // Process some samples
    var output: f32 = 0;
    for (0..100) |_| {
        output = filter.process(1.0);
    }

    // Should have some output
    try testing.expect(output != 0);
}

test "formant filter vowels" {
    const testing = std.testing;

    var filter = FormantFilter.init(44100);
    filter.setVowel(Vowels.A);

    // Process impulse
    var output = filter.process(1.0);
    try testing.expect(output != 0);

    // Process silence
    for (0..100) |_| {
        output = filter.process(0);
    }
}

test "tb303 filter envelope" {
    const testing = std.testing;

    var filter = TB303Filter.init(44100);
    filter.setCutoff(200);
    filter.setResonance(0.8);
    filter.setEnvMod(0.8);
    filter.trigger(1.0);

    // Process with envelope active
    var output: f32 = 0;
    for (0..1000) |_| {
        output = filter.process(1.0);
    }

    try testing.expect(output != 0);
}
