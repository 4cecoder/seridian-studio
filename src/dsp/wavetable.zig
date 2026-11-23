//! Wavetable Oscillator with Band-Limiting
//!
//! High-quality wavetable synthesis with:
//! - Multi-octave band-limited tables (mipmap structure)
//! - Smooth morphing between waveforms
//! - Classic waveforms (saw, square, triangle, pulse)
//! - Custom wavetable loading
//! - Sub-sample interpolation
//!
//! Based on algorithms from:
//! - LMMS Oscillator.h and BandLimitedWave.h
//! - "Alias-Free Digital Synthesis of Classic Waveforms" (Stilson & Smith)
//! - Wavetable synthesis as used in Serum, Vital, etc.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// =============================================================================
// Constants
// =============================================================================

/// Samples per wavetable
pub const TABLE_SIZE: usize = 2048;

/// Number of band-limited tables (one per octave roughly)
pub const NUM_TABLES: usize = 10;

/// Semitones per table (for smooth transitions)
pub const SEMITONES_PER_TABLE: usize = 12;

// =============================================================================
// Band-Limited Wavetable Set
// =============================================================================

/// A set of progressively band-limited versions of a waveform
pub const BandLimitedWave = struct {
    tables: [NUM_TABLES][TABLE_SIZE]f32 = undefined,
    max_harmonics: [NUM_TABLES]usize = undefined,

    const Self = @This();

    /// Generate band-limited sawtooth wave
    pub fn generateSaw(self: *Self) void {
        for (0..NUM_TABLES) |table_idx| {
            // Number of harmonics decreases with higher tables (higher frequencies)
            const max_harmonic = getMaxHarmonics(table_idx);
            self.max_harmonics[table_idx] = max_harmonic;

            for (0..TABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, TABLE_SIZE);
                var sample: f32 = 0;

                // Additive synthesis: saw = sum of sin(n*x)/n
                var n: usize = 1;
                while (n <= max_harmonic) : (n += 1) {
                    const harmonic = @as(f32, @floatFromInt(n));
                    sample += @sin(2.0 * math.pi * phase * harmonic) / harmonic;
                }

                // Normalize: theoretical amplitude is pi/2
                self.tables[table_idx][i] = sample * (2.0 / math.pi);
            }
        }
    }

    /// Generate band-limited square wave
    pub fn generateSquare(self: *Self) void {
        for (0..NUM_TABLES) |table_idx| {
            const max_harmonic = getMaxHarmonics(table_idx);
            self.max_harmonics[table_idx] = max_harmonic;

            for (0..TABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, TABLE_SIZE);
                var sample: f32 = 0;

                // Square = sum of sin((2n-1)*x)/(2n-1) (odd harmonics only)
                var n: usize = 1;
                while (2 * n - 1 <= max_harmonic) : (n += 1) {
                    const harmonic = @as(f32, @floatFromInt(2 * n - 1));
                    sample += @sin(2.0 * math.pi * phase * harmonic) / harmonic;
                }

                self.tables[table_idx][i] = sample * (4.0 / math.pi);
            }
        }
    }

    /// Generate band-limited triangle wave
    pub fn generateTriangle(self: *Self) void {
        for (0..NUM_TABLES) |table_idx| {
            const max_harmonic = getMaxHarmonics(table_idx);
            self.max_harmonics[table_idx] = max_harmonic;

            for (0..TABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, TABLE_SIZE);
                var sample: f32 = 0;

                // Triangle = sum of (-1)^n * sin((2n-1)*x)/(2n-1)^2
                var n: usize = 1;
                while (2 * n - 1 <= max_harmonic) : (n += 1) {
                    const harmonic = @as(f32, @floatFromInt(2 * n - 1));
                    const sign: f32 = if (n % 2 == 1) 1.0 else -1.0;
                    sample += sign * @sin(2.0 * math.pi * phase * harmonic) / (harmonic * harmonic);
                }

                self.tables[table_idx][i] = sample * (8.0 / (math.pi * math.pi));
            }
        }
    }

    /// Generate sine wave (same for all tables since no harmonics)
    pub fn generateSine(self: *Self) void {
        for (0..NUM_TABLES) |table_idx| {
            self.max_harmonics[table_idx] = 1;

            for (0..TABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, TABLE_SIZE);
                self.tables[table_idx][i] = @sin(2.0 * math.pi * phase);
            }
        }
    }

    /// Copy from user-provided single table (will be used for all octaves)
    pub fn setFromTable(self: *Self, source: []const f32) void {
        for (0..NUM_TABLES) |table_idx| {
            self.max_harmonics[table_idx] = TABLE_SIZE / 2;

            for (0..TABLE_SIZE) |i| {
                const src_pos = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(source.len)) / @as(f32, TABLE_SIZE);
                const src_idx = @as(usize, @intFromFloat(src_pos)) % source.len;
                self.tables[table_idx][i] = source[src_idx];
            }
        }
    }

    /// Read from appropriate table with interpolation
    pub fn read(self: *Self, phase: f32, frequency: f32, sample_rate: f32) f32 {
        // Select table based on frequency (higher freq = higher table = fewer harmonics)
        const table_idx = selectTable(frequency, sample_rate);

        // Fractional position in table
        const pos = phase * @as(f32, TABLE_SIZE);
        const idx = @as(usize, @intFromFloat(pos)) % TABLE_SIZE;
        const frac = pos - @floor(pos);

        // Linear interpolation within table
        const next_idx = (idx + 1) % TABLE_SIZE;
        const sample = self.tables[table_idx][idx] * (1.0 - frac) + self.tables[table_idx][next_idx] * frac;

        return sample;
    }

    /// Read with cubic interpolation for higher quality
    pub fn readCubic(self: *Self, phase: f32, frequency: f32, sample_rate: f32) f32 {
        const table_idx = selectTable(frequency, sample_rate);

        const pos = phase * @as(f32, TABLE_SIZE);
        const idx = @as(usize, @intFromFloat(pos));
        const frac = pos - @floor(pos);

        // 4-point cubic interpolation
        const idx0 = (idx + TABLE_SIZE - 1) % TABLE_SIZE;
        const idx1 = idx % TABLE_SIZE;
        const idx2 = (idx + 1) % TABLE_SIZE;
        const idx3 = (idx + 2) % TABLE_SIZE;

        const y0 = self.tables[table_idx][idx0];
        const y1 = self.tables[table_idx][idx1];
        const y2 = self.tables[table_idx][idx2];
        const y3 = self.tables[table_idx][idx3];

        return cubicInterpolate(y0, y1, y2, y3, frac);
    }
};

/// Calculate max harmonics for a table index
fn getMaxHarmonics(table_idx: usize) usize {
    // Table 0: most harmonics (lowest frequencies)
    // Table N-1: fewest harmonics (highest frequencies)
    const base = TABLE_SIZE / 2;
    return @max(1, base >> @as(u5, @intCast(table_idx)));
}

/// Select appropriate table based on frequency
fn selectTable(frequency: f32, sample_rate: f32) usize {
    // Nyquist-based selection
    const nyquist = sample_rate / 2.0;
    const max_harmonic = nyquist / frequency;

    // Find table with appropriate harmonic count
    var table_idx: usize = 0;
    while (table_idx < NUM_TABLES - 1) : (table_idx += 1) {
        const table_harmonics = getMaxHarmonics(table_idx);
        if (@as(f32, @floatFromInt(table_harmonics)) <= max_harmonic) {
            return table_idx;
        }
    }
    return NUM_TABLES - 1;
}

fn cubicInterpolate(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) f32 {
    const a0 = y3 - y2 - y0 + y1;
    const a1 = y0 - y1 - a0;
    const a2 = y2 - y0;
    const a3 = y1;
    return a0 * t * t * t + a1 * t * t + a2 * t + a3;
}

// =============================================================================
// Wavetable Oscillator
// =============================================================================

/// Full-featured wavetable oscillator
pub const WavetableOscillator = struct {
    // Waveform tables
    tables: [4]BandLimitedWave = undefined,
    current_table: usize = 0,

    // Morphing between tables
    morph_position: f32 = 0, // 0-3 for 4 tables
    morph_target: f32 = 0,
    morph_speed: f32 = 0.001,

    // Oscillator state
    phase: f32 = 0,
    frequency: f32 = 440,
    phase_increment: f32 = 0,

    // Modulation
    phase_mod: f32 = 0,
    freq_mod: f32 = 0,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };

        // Initialize with classic waveforms
        self.tables[0].generateSine();
        self.tables[1].generateTriangle();
        self.tables[2].generateSaw();
        self.tables[3].generateSquare();

        self.setFrequency(440);
        return self;
    }

    /// Set oscillator frequency
    pub fn setFrequency(self: *Self, freq: f32) void {
        self.frequency = math.clamp(freq, 0.1, self.sample_rate / 2.0);
        self.phase_increment = self.frequency / self.sample_rate;
    }

    /// Set frequency from MIDI note
    pub fn setNote(self: *Self, note: f32) void {
        const freq = 440.0 * math.pow(f32, 2.0, (note - 69.0) / 12.0);
        self.setFrequency(freq);
    }

    /// Set waveform (0=sine, 1=tri, 2=saw, 3=square)
    pub fn setWaveform(self: *Self, waveform: usize) void {
        self.current_table = @min(waveform, 3);
        self.morph_position = @floatFromInt(self.current_table);
        self.morph_target = self.morph_position;
    }

    /// Set morph position (0-3, fractional for blend)
    pub fn setMorphPosition(self: *Self, position: f32) void {
        self.morph_target = math.clamp(position, 0, 3);
    }

    /// Set phase modulation amount
    pub fn setPhaseModulation(self: *Self, amount: f32) void {
        self.phase_mod = amount;
    }

    /// Set frequency modulation amount (in semitones)
    pub fn setFreqModulation(self: *Self, semitones: f32) void {
        self.freq_mod = semitones;
    }

    /// Generate next sample
    pub fn process(self: *Self) f32 {
        // Update morph
        if (self.morph_position != self.morph_target) {
            const diff = self.morph_target - self.morph_position;
            if (@abs(diff) < self.morph_speed) {
                self.morph_position = self.morph_target;
            } else if (diff > 0) {
                self.morph_position += self.morph_speed;
            } else {
                self.morph_position -= self.morph_speed;
            }
        }

        // Calculate effective frequency with modulation
        const freq_mult = math.pow(f32, 2.0, self.freq_mod / 12.0);
        const effective_freq = self.frequency * freq_mult;

        // Read from wavetable(s)
        var sample: f32 = 0;

        if (self.morph_position == @floor(self.morph_position)) {
            // No morphing needed
            const table_idx = @as(usize, @intFromFloat(self.morph_position));
            sample = self.tables[table_idx].read(self.phase, effective_freq, self.sample_rate);
        } else {
            // Morph between two tables
            const table_a = @as(usize, @intFromFloat(@floor(self.morph_position)));
            const table_b = @min(table_a + 1, 3);
            const blend = self.morph_position - @floor(self.morph_position);

            const sample_a = self.tables[table_a].read(self.phase, effective_freq, self.sample_rate);
            const sample_b = self.tables[table_b].read(self.phase, effective_freq, self.sample_rate);

            sample = sample_a * (1.0 - blend) + sample_b * blend;
        }

        // Advance phase
        self.phase += effective_freq / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return sample;
    }

    /// Process with external phase modulation input
    pub fn processWithPM(self: *Self, pm_input: f32) f32 {
        // Temporarily modify phase
        const original_phase = self.phase;
        self.phase += pm_input * self.phase_mod;
        if (self.phase < 0) self.phase += 1.0;
        if (self.phase >= 1.0) self.phase -= 1.0;

        const sample = self.process();

        // Restore phase (process already advanced it)
        _ = original_phase;

        return sample;
    }

    /// Reset phase
    pub fn reset(self: *Self) void {
        self.phase = 0;
    }

    /// Hard sync (reset phase when master crosses zero)
    pub fn sync(self: *Self) void {
        self.phase = 0;
    }
};

// =============================================================================
// Wavetable Bank (for complex wavetables)
// =============================================================================

/// A bank of wavetables for morphing synthesis
pub const WavetableBank = struct {
    allocator: Allocator,
    tables: []BandLimitedWave,
    num_tables: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, num_tables: usize) !Self {
        const tables = try allocator.alloc(BandLimitedWave, num_tables);

        // Initialize with sine as default
        for (tables) |*table| {
            table.generateSine();
        }

        return Self{
            .allocator = allocator,
            .tables = tables,
            .num_tables = num_tables,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.tables);
    }

    /// Load a wavetable at a specific index
    pub fn setTable(self: *Self, index: usize, source: []const f32) void {
        if (index < self.num_tables) {
            self.tables[index].setFromTable(source);
        }
    }

    /// Read with morphing between tables
    pub fn read(self: *Self, phase: f32, table_position: f32, frequency: f32, sample_rate: f32) f32 {
        if (self.num_tables == 0) return 0;

        const pos = math.clamp(table_position, 0, @as(f32, @floatFromInt(self.num_tables - 1)));
        const table_a = @as(usize, @intFromFloat(@floor(pos)));
        const table_b = @min(table_a + 1, self.num_tables - 1);
        const blend = pos - @floor(pos);

        const sample_a = self.tables[table_a].read(phase, frequency, sample_rate);
        const sample_b = self.tables[table_b].read(phase, frequency, sample_rate);

        return sample_a * (1.0 - blend) + sample_b * blend;
    }
};

// =============================================================================
// Pulse Wave with PWM
// =============================================================================

/// Pulse wave oscillator with pulse width modulation
pub const PulseOscillator = struct {
    saw_table: BandLimitedWave = undefined,
    phase: f32 = 0,
    frequency: f32 = 440,
    pulse_width: f32 = 0.5, // 0.0 to 1.0
    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.saw_table.generateSaw();
        return self;
    }

    pub fn setFrequency(self: *Self, freq: f32) void {
        self.frequency = math.clamp(freq, 0.1, self.sample_rate / 2.0);
    }

    /// Set pulse width (0.0 to 1.0, 0.5 = square wave)
    pub fn setPulseWidth(self: *Self, width: f32) void {
        self.pulse_width = math.clamp(width, 0.01, 0.99);
    }

    pub fn process(self: *Self) f32 {
        // Pulse = saw(phase) - saw(phase + pulse_width)
        // This creates a band-limited pulse wave
        var phase2 = self.phase + self.pulse_width;
        if (phase2 >= 1.0) phase2 -= 1.0;

        const saw1 = self.saw_table.read(self.phase, self.frequency, self.sample_rate);
        const saw2 = self.saw_table.read(phase2, self.frequency, self.sample_rate);

        // Advance phase
        self.phase += self.frequency / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        // Normalize based on pulse width
        return (saw1 - saw2) * 0.5;
    }

    pub fn reset(self: *Self) void {
        self.phase = 0;
    }
};

// =============================================================================
// Super Saw (Unison Oscillator)
// =============================================================================

/// Super saw oscillator with multiple detuned voices
pub const SuperSaw = struct {
    tables: [MAX_VOICES]BandLimitedWave = undefined,
    phases: [MAX_VOICES]f32 = @as([MAX_VOICES]f32, @splat(0)),
    detune_amounts: [MAX_VOICES]f32 = @as([MAX_VOICES]f32, @splat(0)),

    frequency: f32 = 440,
    num_voices: usize = 7,
    detune: f32 = 0.1, // In semitones
    mix: f32 = 0.5, // Center voice vs detuned

    sample_rate: f32,

    const MAX_VOICES = 9;

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };

        for (&self.tables) |*table| {
            table.generateSaw();
        }

        self.setVoices(7);
        self.setDetune(0.1);

        return self;
    }

    /// Set number of voices (1, 3, 5, 7, or 9)
    pub fn setVoices(self: *Self, voices: usize) void {
        self.num_voices = math.clamp(voices, 1, MAX_VOICES);
        self.updateDetune();
    }

    /// Set detune amount in semitones
    pub fn setDetune(self: *Self, semitones: f32) void {
        self.detune = math.clamp(semitones, 0, 2);
        self.updateDetune();
    }

    pub fn setFrequency(self: *Self, freq: f32) void {
        self.frequency = math.clamp(freq, 0.1, self.sample_rate / 2.0);
    }

    fn updateDetune(self: *Self) void {
        const n = self.num_voices;
        if (n == 1) {
            self.detune_amounts[0] = 0;
            return;
        }

        // Spread voices evenly
        for (0..n) |i| {
            const normalized = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1)) - 0.5;
            self.detune_amounts[i] = normalized * self.detune * 2.0;
        }
    }

    pub fn process(self: *Self) f32 {
        var sum: f32 = 0;

        for (0..self.num_voices) |i| {
            // Calculate detuned frequency
            const freq_mult = math.pow(f32, 2.0, self.detune_amounts[i] / 12.0);
            const voice_freq = self.frequency * freq_mult;

            // Read from table
            sum += self.tables[i].read(self.phases[i], voice_freq, self.sample_rate);

            // Advance phase
            self.phases[i] += voice_freq / self.sample_rate;
            if (self.phases[i] >= 1.0) self.phases[i] -= 1.0;
        }

        // Normalize by voice count
        return sum / @sqrt(@as(f32, @floatFromInt(self.num_voices)));
    }

    pub fn reset(self: *Self) void {
        for (&self.phases) |*p| p.* = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "band-limited saw generation" {
    const testing = std.testing;

    var wave: BandLimitedWave = undefined;
    wave.generateSaw();

    // First table should have most harmonics
    try testing.expect(wave.max_harmonics[0] > wave.max_harmonics[NUM_TABLES - 1]);

    // Sample should be in valid range
    const sample = wave.read(0.25, 440, 44100);
    try testing.expect(@abs(sample) <= 1.1);
}

test "wavetable oscillator" {
    const testing = std.testing;

    var osc = WavetableOscillator.init(44100);
    osc.setFrequency(440);
    osc.setWaveform(0); // Sine

    // Generate samples
    var max: f32 = 0;
    for (0..1000) |_| {
        const sample = osc.process();
        max = @max(max, @abs(sample));
    }

    // Sine should be normalized
    try testing.expect(max <= 1.1);
    try testing.expect(max >= 0.9);
}

test "super saw" {
    const testing = std.testing;

    var osc = SuperSaw.init(44100);
    osc.setFrequency(440);
    osc.setVoices(7);
    osc.setDetune(0.1);

    var sum: f32 = 0;
    for (0..1000) |_| {
        sum += @abs(osc.process());
    }

    // Should produce output
    try testing.expect(sum > 0);
}

test "pulse oscillator pwm" {
    const testing = std.testing;

    var osc = PulseOscillator.init(44100);
    osc.setFrequency(440);
    osc.setPulseWidth(0.5); // Square wave

    var sample = osc.process();
    try testing.expect(@abs(sample) <= 1.1);

    // Narrow pulse
    osc.setPulseWidth(0.1);
    sample = osc.process();
    try testing.expect(@abs(sample) <= 1.1);
}
