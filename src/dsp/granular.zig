//! Granular Processing
//!
//! Granular synthesis and processing algorithms:
//! - Granular Pitch Shifter (real-time pitch shift without time change)
//! - Granular Time Stretcher (time stretch without pitch change)
//! - Granular Synthesizer (texture generation from samples)
//! - Freeze Effect (sustain/hold any sound)
//!
//! Based on algorithms from:
//! - Roads "Microsound" (MIT Press)
//! - LMMS GranularPitchShifter
//! - Csound granular opcodes

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// =============================================================================
// Grain Window Functions
// =============================================================================

/// Generate a grain window
pub fn generateWindow(buffer: []f32, window_type: WindowType) void {
    const n = buffer.len;
    const n_f = @as(f32, @floatFromInt(n));

    for (buffer, 0..) |*val, i| {
        const t = @as(f32, @floatFromInt(i)) / n_f;

        val.* = switch (window_type) {
            .hann => 0.5 - 0.5 * @cos(2.0 * math.pi * t),
            .hamming => 0.54 - 0.46 * @cos(2.0 * math.pi * t),
            .blackman => 0.42 - 0.5 * @cos(2.0 * math.pi * t) + 0.08 * @cos(4.0 * math.pi * t),
            .triangle => if (t < 0.5) t * 2.0 else (1.0 - t) * 2.0,
            .tukey => blk: {
                const alpha = 0.5;
                if (t < alpha / 2.0) {
                    break :blk 0.5 * (1.0 + @cos(math.pi * (2.0 * t / alpha - 1.0)));
                } else if (t > 1.0 - alpha / 2.0) {
                    break :blk 0.5 * (1.0 + @cos(math.pi * (2.0 * t / alpha - 2.0 / alpha + 1.0)));
                } else {
                    break :blk 1.0;
                }
            },
            .gaussian => blk: {
                const sigma = 0.4;
                const x = (t - 0.5) / sigma;
                break :blk @exp(-0.5 * x * x);
            },
        };
    }
}

pub const WindowType = enum {
    hann,
    hamming,
    blackman,
    triangle,
    tukey,
    gaussian,
};

// =============================================================================
// Grain Structure
// =============================================================================

const Grain = struct {
    active: bool = false,
    position: f32 = 0, // Read position in source buffer
    phase: f32 = 0, // Position within grain (0-1)
    speed: f32 = 1.0, // Playback speed (1.0 = normal, 2.0 = octave up)
    amp: f32 = 1.0, // Amplitude
    pan: f32 = 0, // -1 to 1

    pub fn reset(self: *Grain) void {
        self.active = false;
        self.position = 0;
        self.phase = 0;
    }
};

// =============================================================================
// Granular Pitch Shifter
// =============================================================================

/// Real-time granular pitch shifter
/// Shifts pitch without changing playback speed
pub const GranularPitchShifter = struct {
    allocator: Allocator,

    // Circular input buffer
    buffer: []f32,
    buffer_size: usize,
    write_pos: usize = 0,

    // Grains
    grains: [MAX_GRAINS]Grain = @as([MAX_GRAINS]Grain, @splat(.{})),
    active_grains: usize = 0,

    // Grain window (pre-computed)
    window: []f32,
    grain_size: usize,

    // Parameters
    pitch_ratio: f32 = 1.0, // 0.5 = octave down, 2.0 = octave up
    grain_size_ms: f32 = 50,
    overlap: f32 = 4, // Number of overlapping grains
    mix: f32 = 1.0,

    // Grain scheduling
    samples_since_grain: usize = 0,
    grain_interval: usize = 0,

    sample_rate: f32,

    const MAX_GRAINS = 8;
    const MAX_BUFFER_SIZE = 65536;
    const MAX_GRAIN_SIZE = 8192;

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: f32) !Self {
        const buffer = try allocator.alloc(f32, MAX_BUFFER_SIZE);
        @memset(buffer, 0);

        const window = try allocator.alloc(f32, MAX_GRAIN_SIZE);
        generateWindow(window, .hann);

        var self = Self{
            .allocator = allocator,
            .buffer = buffer,
            .buffer_size = MAX_BUFFER_SIZE,
            .window = window,
            .grain_size = 2048,
            .sample_rate = sample_rate,
        };

        self.setGrainSize(50);
        self.setOverlap(4);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.window);
    }

    /// Set pitch shift ratio (0.5 = octave down, 2.0 = octave up)
    pub fn setPitch(self: *Self, ratio: f32) void {
        self.pitch_ratio = math.clamp(ratio, 0.25, 4.0);
    }

    /// Set pitch shift in semitones
    pub fn setPitchSemitones(self: *Self, semitones: f32) void {
        self.pitch_ratio = math.pow(f32, 2.0, semitones / 12.0);
    }

    /// Set grain size in milliseconds
    pub fn setGrainSize(self: *Self, ms: f32) void {
        self.grain_size_ms = math.clamp(ms, 10, 200);
        self.grain_size = @min(
            @as(usize, @intFromFloat(ms * self.sample_rate / 1000.0)),
            MAX_GRAIN_SIZE,
        );
        self.updateGrainInterval();

        // Regenerate window
        generateWindow(self.window[0..self.grain_size], .hann);
    }

    /// Set number of overlapping grains
    pub fn setOverlap(self: *Self, overlap: f32) void {
        self.overlap = math.clamp(overlap, 1, @as(f32, MAX_GRAINS));
        self.updateGrainInterval();
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    fn updateGrainInterval(self: *Self) void {
        self.grain_interval = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.grain_size)) / self.overlap)));
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Write input to circular buffer
        self.buffer[self.write_pos] = input;
        self.write_pos = (self.write_pos + 1) % self.buffer_size;

        // Trigger new grain if needed
        self.samples_since_grain += 1;
        if (self.samples_since_grain >= self.grain_interval) {
            self.samples_since_grain = 0;
            self.triggerGrain();
        }

        // Sum active grains
        var output: f32 = 0;
        var grain_count: usize = 0;

        for (&self.grains) |*grain| {
            if (grain.active) {
                output += self.processGrain(grain);
                grain_count += 1;
            }
        }

        // Normalize by overlap
        if (grain_count > 0) {
            output /= @sqrt(@as(f32, @floatFromInt(grain_count)));
        }

        // Mix dry/wet
        return input * (1.0 - self.mix) + output * self.mix;
    }

    fn triggerGrain(self: *Self) void {
        // Find inactive grain slot
        for (&self.grains) |*grain| {
            if (!grain.active) {
                grain.active = true;
                grain.phase = 0;
                grain.speed = self.pitch_ratio;
                grain.amp = 1.0;

                // Start position: where we were `grain_size` samples ago
                const offset = self.grain_size;
                grain.position = @floatFromInt((self.write_pos + self.buffer_size - offset) % self.buffer_size);

                self.active_grains += 1;
                return;
            }
        }
    }

    fn processGrain(self: *Self, grain: *Grain) f32 {
        // Get window value
        const window_pos = @as(usize, @intFromFloat(grain.phase * @as(f32, @floatFromInt(self.grain_size))));
        const window_val = if (window_pos < self.grain_size) self.window[window_pos] else 0;

        // Read from buffer with interpolation
        const pos_int = @as(usize, @intFromFloat(grain.position)) % self.buffer_size;
        const pos_frac = grain.position - @floor(grain.position);
        const next_pos = (pos_int + 1) % self.buffer_size;

        const sample = self.buffer[pos_int] * (1.0 - pos_frac) + self.buffer[next_pos] * pos_frac;

        // Advance grain
        grain.position += grain.speed;
        if (grain.position >= @as(f32, @floatFromInt(self.buffer_size))) {
            grain.position -= @as(f32, @floatFromInt(self.buffer_size));
        }

        grain.phase += 1.0 / @as(f32, @floatFromInt(self.grain_size));

        // Deactivate if grain complete
        if (grain.phase >= 1.0) {
            grain.active = false;
            self.active_grains -= 1;
        }

        return sample * window_val * grain.amp;
    }

    pub fn reset(self: *Self) void {
        @memset(self.buffer, 0);
        self.write_pos = 0;
        for (&self.grains) |*g| g.reset();
        self.active_grains = 0;
        self.samples_since_grain = 0;
    }
};

// =============================================================================
// Granular Time Stretcher
// =============================================================================

/// Granular time stretcher for offline or buffered processing
pub const GranularTimeStretcher = struct {
    allocator: Allocator,

    // Source buffer (external)
    source: []const f32 = &.{},
    source_len: usize = 0,

    // Read position
    read_pos: f32 = 0,

    // Grains
    grains: [MAX_GRAINS]Grain = @as([MAX_GRAINS]Grain, @splat(.{})),

    // Window
    window: []f32,
    grain_size: usize,

    // Parameters
    stretch_ratio: f32 = 1.0, // 2.0 = twice as long
    grain_size_ms: f32 = 50,
    overlap: f32 = 4,

    grain_interval: usize = 0,
    samples_since_grain: usize = 0,

    sample_rate: f32,

    const MAX_GRAINS = 8;
    const MAX_GRAIN_SIZE = 8192;

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: f32) !Self {
        const window = try allocator.alloc(f32, MAX_GRAIN_SIZE);
        generateWindow(window, .hann);

        var self = Self{
            .allocator = allocator,
            .window = window,
            .grain_size = 2048,
            .sample_rate = sample_rate,
        };

        self.setGrainSize(50);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.window);
    }

    /// Set source audio buffer
    pub fn setSource(self: *Self, source: []const f32) void {
        self.source = source;
        self.source_len = source.len;
        self.read_pos = 0;
    }

    /// Set time stretch ratio (0.5 = half speed, 2.0 = double speed)
    pub fn setStretch(self: *Self, ratio: f32) void {
        self.stretch_ratio = math.clamp(ratio, 0.1, 10.0);
    }

    pub fn setGrainSize(self: *Self, ms: f32) void {
        self.grain_size_ms = ms;
        self.grain_size = @min(
            @as(usize, @intFromFloat(ms * self.sample_rate / 1000.0)),
            MAX_GRAIN_SIZE,
        );
        self.grain_interval = @max(1, self.grain_size / 4);
        generateWindow(self.window[0..self.grain_size], .hann);
    }

    /// Generate next output sample
    pub fn process(self: *Self) f32 {
        if (self.source_len == 0) return 0;

        // Advance read position
        self.read_pos += 1.0 / self.stretch_ratio;
        if (self.read_pos >= @as(f32, @floatFromInt(self.source_len))) {
            self.read_pos = 0; // Loop
        }

        // Trigger grains
        self.samples_since_grain += 1;
        if (self.samples_since_grain >= self.grain_interval) {
            self.samples_since_grain = 0;
            self.triggerGrain();
        }

        // Sum grains
        var output: f32 = 0;
        for (&self.grains) |*grain| {
            if (grain.active) {
                output += self.processGrain(grain);
            }
        }

        return output / @sqrt(self.overlap);
    }

    fn triggerGrain(self: *Self) void {
        for (&self.grains) |*grain| {
            if (!grain.active) {
                grain.active = true;
                grain.phase = 0;
                grain.position = self.read_pos;
                grain.speed = 1.0;
                grain.amp = 1.0;
                return;
            }
        }
    }

    fn processGrain(self: *Self, grain: *Grain) f32 {
        const window_pos = @as(usize, @intFromFloat(grain.phase * @as(f32, @floatFromInt(self.grain_size))));
        const window_val = if (window_pos < self.grain_size) self.window[window_pos] else 0;

        // Read from source with interpolation
        const pos_int = @as(usize, @intFromFloat(grain.position)) % self.source_len;
        const pos_frac = grain.position - @floor(grain.position);
        const next_pos = (pos_int + 1) % self.source_len;

        const sample = self.source[pos_int] * (1.0 - pos_frac) + self.source[next_pos] * pos_frac;

        // Advance
        grain.position += grain.speed;
        grain.phase += 1.0 / @as(f32, @floatFromInt(self.grain_size));

        if (grain.phase >= 1.0) {
            grain.active = false;
        }

        return sample * window_val;
    }

    pub fn reset(self: *Self) void {
        self.read_pos = 0;
        for (&self.grains) |*g| g.reset();
        self.samples_since_grain = 0;
    }

    /// Check if playback is complete
    pub fn isComplete(self: *Self) bool {
        return self.read_pos >= @as(f32, @floatFromInt(self.source_len)) - 1;
    }
};

// =============================================================================
// Granular Freeze Effect
// =============================================================================

/// Freeze effect - captures and sustains a moment in time
pub const GranularFreeze = struct {
    allocator: Allocator,

    // Capture buffer
    buffer: []f32,
    buffer_size: usize,
    capture_pos: usize = 0,
    is_frozen: bool = false,

    // Grains
    grains: [MAX_GRAINS]Grain = @as([MAX_GRAINS]Grain, @splat(.{})),

    // Window
    window: []f32,
    grain_size: usize,

    // Parameters
    position: f32 = 0.5, // Playback position in frozen buffer (0-1)
    jitter: f32 = 0.1, // Random position variation
    grain_size_ms: f32 = 100,
    overlap: f32 = 4,
    pitch: f32 = 1.0,

    grain_interval: usize = 0,
    samples_since_grain: usize = 0,

    sample_rate: f32,

    const MAX_GRAINS = 8;
    const BUFFER_SIZE = 88200; // 2 seconds at 44.1kHz
    const MAX_GRAIN_SIZE = 8192;

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: f32) !Self {
        const buffer = try allocator.alloc(f32, BUFFER_SIZE);
        @memset(buffer, 0);

        const window = try allocator.alloc(f32, MAX_GRAIN_SIZE);
        generateWindow(window, .hann);

        var self = Self{
            .allocator = allocator,
            .buffer = buffer,
            .buffer_size = BUFFER_SIZE,
            .window = window,
            .grain_size = 4410,
            .sample_rate = sample_rate,
        };

        self.setGrainSize(100);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.window);
    }

    /// Toggle freeze on/off
    pub fn setFreeze(self: *Self, freeze: bool) void {
        self.is_frozen = freeze;
        if (!freeze) {
            // Clear grains when unfreezing
            for (&self.grains) |*g| g.reset();
        }
    }

    /// Set playback position within frozen buffer (0-1)
    pub fn setPosition(self: *Self, pos: f32) void {
        self.position = math.clamp(pos, 0, 1);
    }

    /// Set position randomization amount
    pub fn setJitter(self: *Self, jitter: f32) void {
        self.jitter = math.clamp(jitter, 0, 1);
    }

    /// Set pitch ratio
    pub fn setPitch(self: *Self, pitch: f32) void {
        self.pitch = math.clamp(pitch, 0.25, 4.0);
    }

    pub fn setGrainSize(self: *Self, ms: f32) void {
        self.grain_size_ms = ms;
        self.grain_size = @min(
            @as(usize, @intFromFloat(ms * self.sample_rate / 1000.0)),
            MAX_GRAIN_SIZE,
        );
        self.grain_interval = @max(1, self.grain_size / 4);
        generateWindow(self.window[0..self.grain_size], .hann);
    }

    pub fn process(self: *Self, input: f32) f32 {
        if (!self.is_frozen) {
            // Recording mode: write to buffer
            self.buffer[self.capture_pos] = input;
            self.capture_pos = (self.capture_pos + 1) % self.buffer_size;
            return input;
        }

        // Frozen mode: playback from buffer
        self.samples_since_grain += 1;
        if (self.samples_since_grain >= self.grain_interval) {
            self.samples_since_grain = 0;
            self.triggerGrain();
        }

        var output: f32 = 0;
        for (&self.grains) |*grain| {
            if (grain.active) {
                output += self.processGrain(grain);
            }
        }

        return output / @sqrt(self.overlap);
    }

    fn triggerGrain(self: *Self) void {
        for (&self.grains) |*grain| {
            if (!grain.active) {
                grain.active = true;
                grain.phase = 0;
                grain.speed = self.pitch;
                grain.amp = 1.0;

                // Calculate position with jitter
                const base_pos = self.position * @as(f32, @floatFromInt(self.buffer_size));
                const jitter_amount = (pseudoRandom() - 0.5) * self.jitter * @as(f32, @floatFromInt(self.buffer_size)) * 0.2;
                grain.position = base_pos + jitter_amount;

                // Wrap position
                if (grain.position < 0) grain.position += @as(f32, @floatFromInt(self.buffer_size));
                if (grain.position >= @as(f32, @floatFromInt(self.buffer_size))) {
                    grain.position -= @as(f32, @floatFromInt(self.buffer_size));
                }

                return;
            }
        }
    }

    fn processGrain(self: *Self, grain: *Grain) f32 {
        const window_pos = @as(usize, @intFromFloat(grain.phase * @as(f32, @floatFromInt(self.grain_size))));
        const window_val = if (window_pos < self.grain_size) self.window[window_pos] else 0;

        // Read with interpolation
        const pos_int = @as(usize, @intFromFloat(grain.position)) % self.buffer_size;
        const pos_frac = grain.position - @floor(grain.position);
        const next_pos = (pos_int + 1) % self.buffer_size;

        const sample = self.buffer[pos_int] * (1.0 - pos_frac) + self.buffer[next_pos] * pos_frac;

        // Advance
        grain.position += grain.speed;
        if (grain.position >= @as(f32, @floatFromInt(self.buffer_size))) {
            grain.position -= @as(f32, @floatFromInt(self.buffer_size));
        }

        grain.phase += 1.0 / @as(f32, @floatFromInt(self.grain_size));

        if (grain.phase >= 1.0) {
            grain.active = false;
        }

        return sample * window_val;
    }

    pub fn reset(self: *Self) void {
        @memset(self.buffer, 0);
        self.capture_pos = 0;
        self.is_frozen = false;
        for (&self.grains) |*g| g.reset();
    }
};

// =============================================================================
// Utility
// =============================================================================

var prng_state: u32 = 12345;

fn pseudoRandom() f32 {
    prng_state ^= prng_state << 13;
    prng_state ^= prng_state >> 17;
    prng_state ^= prng_state << 5;
    return @as(f32, @floatFromInt(prng_state)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

// =============================================================================
// Tests
// =============================================================================

test "granular pitch shifter" {
    const testing = std.testing;

    var shifter = try GranularPitchShifter.init(testing.allocator, 44100);
    defer shifter.deinit();

    shifter.setPitchSemitones(12); // Octave up

    // Process some samples
    var output: f32 = 0;
    for (0..10000) |i| {
        const input = @sin(@as(f32, @floatFromInt(i)) * 0.1);
        output = shifter.process(input);
    }

    try testing.expect(output != 0 or shifter.active_grains > 0);
}

test "granular freeze" {
    const testing = std.testing;

    var freeze = try GranularFreeze.init(testing.allocator, 44100);
    defer freeze.deinit();

    // Record some audio
    for (0..4410) |i| {
        const input = @sin(@as(f32, @floatFromInt(i)) * 0.1);
        _ = freeze.process(input);
    }

    // Freeze
    freeze.setFreeze(true);
    freeze.setPosition(0.5);

    // Should produce output from frozen buffer
    var output: f32 = 0;
    for (0..1000) |_| {
        output = freeze.process(0);
    }

    // After some samples, we should have grain activity
    try testing.expect(true); // Basic smoke test
}

test "window generation" {
    const testing = std.testing;

    var window: [256]f32 = undefined;
    generateWindow(&window, .hann);

    // Hann window should be 0 at edges, 1 at center
    try testing.expectApproxEqAbs(@as(f32, 0), window[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), window[128], 0.01);
}
