//! Dynamics Processing
//!
//! Professional dynamics processors for mixing and mastering:
//! - Compressor (with soft/hard knee, sidechain, lookahead)
//! - Limiter (brickwall peak limiting)
//! - Gate (noise gate with hysteresis)
//! - Expander (downward expansion)
//! - Transient Shaper (attack/sustain control)
//!
//! Based on algorithms from:
//! - LMMS Compressor plugin
//! - Digital Audio FX (DAFX) book
//! - Giannoulis et al. "Digital Dynamic Range Compressor Design"

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// =============================================================================
// Envelope Follower (shared by dynamics processors)
// =============================================================================

/// Attempt envelope follower with separate attack/release
pub const EnvelopeFollower = struct {
    attack_coef: f32 = 0.1,
    release_coef: f32 = 0.01,
    envelope: f32 = 0,
    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var ef = Self{ .sample_rate = sample_rate, .envelope = 0 };
        ef.setAttack(10); // 10ms
        ef.setRelease(100); // 100ms
        return ef;
    }

    /// Set attack time in milliseconds
    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_coef = msToCoef(ms, self.sample_rate);
    }

    /// Set release time in milliseconds
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_coef = msToCoef(ms, self.sample_rate);
    }

    /// Process input and return envelope value
    pub fn process(self: *Self, input: f32) f32 {
        const abs_in = @abs(input);

        if (abs_in > self.envelope) {
            // Attack phase
            self.envelope += self.attack_coef * (abs_in - self.envelope);
        } else {
            // Release phase
            self.envelope += self.release_coef * (abs_in - self.envelope);
        }

        return self.envelope;
    }

    /// Process using RMS detection
    pub fn processRms(self: *Self, input: f32) f32 {
        const squared = input * input;

        if (squared > self.envelope * self.envelope) {
            self.envelope += self.attack_coef * (@sqrt(squared) - self.envelope);
        } else {
            self.envelope += self.release_coef * (@sqrt(squared) - self.envelope);
        }

        return self.envelope;
    }

    pub fn reset(self: *Self) void {
        self.envelope = 0;
    }
};

// =============================================================================
// Compressor
// =============================================================================

/// Full-featured compressor with soft knee and optional lookahead
pub const Compressor = struct {
    // Parameters
    threshold_db: f32 = 0,
    ratio: f32 = 4,
    knee_db: f32 = 0,
    attack_ms: f32 = 10,
    release_ms: f32 = 100,
    makeup_db: f32 = 0,

    // Derived values
    threshold_lin: f32 = 1,
    knee_width: f32 = 0,
    makeup_lin: f32 = 1,

    // State
    envelope: EnvelopeFollower,
    gain_reduction_db: f32 = 0,

    // Lookahead (optional)
    lookahead_samples: usize = 0,
    lookahead_buffer: ?[]f32 = null,
    lookahead_pos: usize = 0,

    sample_rate: f32,
    allocator: ?Allocator = null,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .envelope = EnvelopeFollower.init(sample_rate),
        };
    }

    pub fn initWithLookahead(allocator: Allocator, sample_rate: f32, lookahead_ms: f32) !Self {
        var self = Self{
            .sample_rate = sample_rate,
            .envelope = EnvelopeFollower.init(sample_rate),
            .allocator = allocator,
        };

        const samples = @as(usize, @intFromFloat(lookahead_ms * sample_rate / 1000.0));
        if (samples > 0) {
            self.lookahead_buffer = try allocator.alloc(f32, samples);
            @memset(self.lookahead_buffer.?, 0);
            self.lookahead_samples = samples;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.allocator) |alloc| {
            if (self.lookahead_buffer) |buf| {
                alloc.free(buf);
            }
        }
    }

    /// Set threshold in dB (typically -60 to 0)
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold_lin = utils.dbToLinear(db);
    }

    /// Set compression ratio (1:1 to inf:1)
    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    /// Set soft knee width in dB (0 = hard knee)
    pub fn setKnee(self: *Self, db: f32) void {
        self.knee_db = @max(0, db);
        self.knee_width = self.knee_db;
    }

    /// Set attack time in ms
    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_ms = ms;
        self.envelope.setAttack(ms);
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_ms = ms;
        self.envelope.setRelease(ms);
    }

    /// Set makeup gain in dB
    pub fn setMakeup(self: *Self, db: f32) void {
        self.makeup_db = db;
        self.makeup_lin = utils.dbToLinear(db);
    }

    /// Auto-calculate makeup gain based on threshold and ratio
    pub fn autoMakeup(self: *Self) void {
        // Approximate makeup = -threshold * (1 - 1/ratio)
        const makeup = -self.threshold_db * (1.0 - 1.0 / self.ratio) * 0.5;
        self.setMakeup(makeup);
    }

    /// Compute gain reduction for a given input level
    fn computeGainDb(self: *Self, input_db: f32) f32 {
        const thresh = self.threshold_db;
        const knee = self.knee_width;

        if (knee > 0 and input_db > thresh - knee / 2 and input_db < thresh + knee / 2) {
            // Soft knee region
            const x = input_db - thresh + knee / 2;
            const compression = (1.0 / self.ratio - 1.0) * x * x / (2.0 * knee);
            return input_db + compression;
        } else if (input_db >= thresh + knee / 2) {
            // Above threshold: compress
            return thresh + (input_db - thresh) / self.ratio;
        } else {
            // Below threshold: no compression
            return input_db;
        }
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Detect level
        const level = self.envelope.process(input);
        const level_db = utils.linearToDb(level);

        // Compute gain reduction
        const output_db = self.computeGainDb(level_db);
        self.gain_reduction_db = level_db - output_db;

        // Apply gain
        const gain = utils.dbToLinear(-self.gain_reduction_db) * self.makeup_lin;

        // Handle lookahead
        if (self.lookahead_buffer) |buffer| {
            const delayed = buffer[self.lookahead_pos];
            buffer[self.lookahead_pos] = input;
            self.lookahead_pos = (self.lookahead_pos + 1) % self.lookahead_samples;
            return delayed * gain;
        }

        return input * gain;
    }

    /// Process stereo with linked detection
    pub fn processStereo(self: *Self, left: f32, right: f32) struct { left: f32, right: f32 } {
        // Use max of both channels for detection
        const max_level = @max(@abs(left), @abs(right));
        const level = self.envelope.process(max_level);
        const level_db = utils.linearToDb(level);

        const output_db = self.computeGainDb(level_db);
        self.gain_reduction_db = level_db - output_db;

        const gain = utils.dbToLinear(-self.gain_reduction_db) * self.makeup_lin;

        return .{
            .left = left * gain,
            .right = right * gain,
        };
    }

    /// Get current gain reduction in dB
    pub fn getGainReduction(self: *Self) f32 {
        return self.gain_reduction_db;
    }

    pub fn reset(self: *Self) void {
        self.envelope.reset();
        self.gain_reduction_db = 0;
        if (self.lookahead_buffer) |buffer| {
            @memset(buffer, 0);
        }
        self.lookahead_pos = 0;
    }
};

// =============================================================================
// Limiter
// =============================================================================

/// Brickwall peak limiter with lookahead
pub const Limiter = struct {
    ceiling_db: f32 = 0,
    ceiling_lin: f32 = 1,
    release_ms: f32 = 100,

    // State
    gain: f32 = 1,
    release_coef: f32 = 0.01,

    // Lookahead buffer
    buffer: [512]f32 = @as([512]f32, @splat(0)),
    write_pos: usize = 0,
    lookahead: usize = 64,

    // True-peak detection: when enabled, the detector also considers the
    // inter-sample peaks between samples (4x oversampled Catmull-Rom estimate).
    // `local_peak[i]` is the largest estimated level in the segment ending at
    // buffer[i]. Needs a lookahead of at least 3 samples.
    true_peak: bool = false,
    local_peak: [512]f32 = @as([512]f32, @splat(0)),
    hist: [3]f32 = .{ 0, 0, 0 }, // last three inputs, oldest first

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setRelease(100);
        return self;
    }

    /// Set ceiling level in dB
    pub fn setCeiling(self: *Self, db: f32) void {
        self.ceiling_db = db;
        self.ceiling_lin = utils.dbToLinear(db);
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_ms = ms;
        self.release_coef = msToCoef(ms, self.sample_rate);
    }

    /// Set lookahead in samples
    pub fn setLookahead(self: *Self, samples: usize) void {
        self.lookahead = @min(samples, self.buffer.len - 1);
    }

    /// Enable or disable inter-sample (true) peak detection.
    pub fn setTruePeak(self: *Self, enabled: bool) void {
        self.true_peak = enabled;
    }

    /// Largest |value| of the Catmull-Rom curve through p1..p2 at t = 0.25, 0.5, 0.75.
    fn segmentPeak(p0: f32, p1: f32, p2: f32, p3: f32) f32 {
        var best: f32 = 0;
        const ts = [_]f32{ 0.25, 0.5, 0.75 };
        for (ts) |t| {
            const t2 = t * t;
            const t3 = t2 * t;
            const v = 0.5 * ((2 * p1) + (-p0 + p2) * t +
                (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
            best = @max(best, @abs(v));
        }
        return best;
    }

    pub fn process(self: *Self, input: f32) f32 {
        // With true-peak detection, the segment between the previous two inputs
        // is now fully known (4 points), so record its level on the older sample.
        var tp_input: f32 = 0;
        if (self.true_peak) {
            const prev_slot = (self.write_pos + self.buffer.len - 1) % self.buffer.len;
            const seg = segmentPeak(self.hist[0], self.hist[1], self.hist[2], input);
            self.local_peak[prev_slot] = @max(@abs(self.hist[2]), seg);
            tp_input = @abs(input);
        }

        // Find peak over the samples that are about to be output (the last
        // `lookahead` written samples) plus the new input.
        var peak: f32 = 0;
        var pos = (self.write_pos + self.buffer.len - self.lookahead) % self.buffer.len;
        for (0..self.lookahead) |_| {
            const v = if (self.true_peak) self.local_peak[pos] else @abs(self.buffer[pos]);
            peak = @max(peak, v);
            pos = (pos + 1) % self.buffer.len;
        }
        peak = @max(peak, @max(@abs(input), tp_input));

        // Calculate required gain
        var target_gain: f32 = 1.0;
        if (peak > self.ceiling_lin) {
            target_gain = self.ceiling_lin / peak;
        }

        // Smooth gain changes (instant attack, smooth release)
        if (target_gain < self.gain) {
            self.gain = target_gain; // Instant attack
        } else {
            self.gain += self.release_coef * (target_gain - self.gain);
        }

        // Read from delay and write input
        const read_pos = (self.write_pos + self.buffer.len - self.lookahead) % self.buffer.len;
        const output = self.buffer[read_pos] * self.gain;

        self.buffer[self.write_pos] = input;
        self.local_peak[self.write_pos] = @abs(input);
        self.hist = .{ self.hist[1], self.hist[2], input };
        self.write_pos = (self.write_pos + 1) % self.buffer.len;

        return output;
    }

    pub fn getGainReduction(self: *Self) f32 {
        return utils.linearToDb(self.gain);
    }

    pub fn reset(self: *Self) void {
        @memset(&self.buffer, 0);
        @memset(&self.local_peak, 0);
        self.hist = .{ 0, 0, 0 };
        self.gain = 1;
        self.write_pos = 0;
    }
};

// =============================================================================
// Noise Gate
// =============================================================================

/// Noise gate with hysteresis and hold time
pub const Gate = struct {
    threshold_db: f32 = -40,
    threshold_lin: f32 = 0.01,
    hysteresis_db: f32 = 3,
    attack_ms: f32 = 1,
    hold_ms: f32 = 50,
    release_ms: f32 = 100,
    range_db: f32 = -80, // How much to reduce when gated

    // State
    envelope: EnvelopeFollower,
    gate_state: GateState = .closed,
    hold_counter: usize = 0,
    current_gain: f32 = 0,

    // Coefficients
    attack_coef: f32 = 0.1,
    release_coef: f32 = 0.01,
    hold_samples: usize = 2205,
    range_lin: f32 = 0.0001,

    sample_rate: f32,

    const GateState = enum { closed, opening, open, holding, closing };

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{
            .sample_rate = sample_rate,
            .envelope = EnvelopeFollower.init(sample_rate),
        };
        self.setThreshold(-40);
        self.setAttack(1);
        self.setHold(50);
        self.setRelease(100);
        return self;
    }

    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold_lin = utils.dbToLinear(db);
    }

    pub fn setHysteresis(self: *Self, db: f32) void {
        self.hysteresis_db = @max(0, db);
    }

    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_ms = ms;
        self.attack_coef = msToCoef(ms, self.sample_rate);
    }

    pub fn setHold(self: *Self, ms: f32) void {
        self.hold_ms = ms;
        self.hold_samples = @as(usize, @intFromFloat(ms * self.sample_rate / 1000.0));
    }

    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_ms = ms;
        self.release_coef = msToCoef(ms, self.sample_rate);
    }

    pub fn setRange(self: *Self, db: f32) void {
        self.range_db = db;
        self.range_lin = utils.dbToLinear(db);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const level = self.envelope.process(input);

        // Threshold with hysteresis
        const open_thresh = self.threshold_lin;
        const close_thresh = utils.dbToLinear(self.threshold_db - self.hysteresis_db);

        // State machine
        switch (self.gate_state) {
            .closed => {
                if (level > open_thresh) {
                    self.gate_state = .opening;
                }
            },
            .opening => {
                self.current_gain += self.attack_coef * (1.0 - self.current_gain);
                if (self.current_gain >= 0.999) {
                    self.current_gain = 1.0;
                    self.gate_state = .open;
                }
            },
            .open => {
                if (level < close_thresh) {
                    self.gate_state = .holding;
                    self.hold_counter = self.hold_samples;
                }
            },
            .holding => {
                if (level > open_thresh) {
                    self.gate_state = .open;
                } else if (self.hold_counter > 0) {
                    self.hold_counter -= 1;
                } else {
                    self.gate_state = .closing;
                }
            },
            .closing => {
                if (level > open_thresh) {
                    self.gate_state = .opening;
                } else {
                    self.current_gain += self.release_coef * (self.range_lin - self.current_gain);
                    if (self.current_gain <= self.range_lin + 0.001) {
                        self.current_gain = self.range_lin;
                        self.gate_state = .closed;
                    }
                }
            },
        }

        return input * self.current_gain;
    }

    pub fn isOpen(self: *Self) bool {
        return self.gate_state == .open or self.gate_state == .opening or self.gate_state == .holding;
    }

    pub fn reset(self: *Self) void {
        self.envelope.reset();
        self.gate_state = .closed;
        self.hold_counter = 0;
        self.current_gain = 0;
    }
};

// =============================================================================
// Expander
// =============================================================================

/// Downward expander (opposite of compressor)
pub const Expander = struct {
    threshold_db: f32 = -40,
    threshold_lin: f32 = 0.01,
    ratio: f32 = 2,
    attack_ms: f32 = 10,
    release_ms: f32 = 100,

    envelope: EnvelopeFollower,
    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .envelope = EnvelopeFollower.init(sample_rate),
        };
    }

    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold_lin = utils.dbToLinear(db);
    }

    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_ms = ms;
        self.envelope.setAttack(ms);
    }

    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_ms = ms;
        self.envelope.setRelease(ms);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const level = self.envelope.process(input);
        const level_db = utils.linearToDb(level);

        // Expand below threshold
        if (level_db < self.threshold_db) {
            const diff = self.threshold_db - level_db;
            const expanded_diff = diff * self.ratio;
            const gain_db = -(expanded_diff - diff);
            return input * utils.dbToLinear(gain_db);
        }

        return input;
    }

    pub fn reset(self: *Self) void {
        self.envelope.reset();
    }
};

// =============================================================================
// Transient Shaper
// =============================================================================

/// Transient designer for attack/sustain control
pub const TransientShaper = struct {
    attack_gain: f32 = 0, // dB, can be negative
    sustain_gain: f32 = 0, // dB, can be negative

    // Envelope followers with different time constants
    fast_env: EnvelopeFollower,
    slow_env: EnvelopeFollower,

    // Output smoothing
    attack_smooth: f32 = 0,
    sustain_smooth: f32 = 0,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{
            .sample_rate = sample_rate,
            .fast_env = EnvelopeFollower.init(sample_rate),
            .slow_env = EnvelopeFollower.init(sample_rate),
        };

        // Fast envelope for transient detection
        self.fast_env.setAttack(0.1);
        self.fast_env.setRelease(20);

        // Slow envelope for sustain detection
        self.slow_env.setAttack(20);
        self.slow_env.setRelease(200);

        return self;
    }

    /// Set attack enhancement/reduction in dB (-12 to +12 typical)
    pub fn setAttack(self: *Self, db: f32) void {
        self.attack_gain = math.clamp(db, -24, 24);
    }

    /// Set sustain enhancement/reduction in dB
    pub fn setSustain(self: *Self, db: f32) void {
        self.sustain_gain = math.clamp(db, -24, 24);
    }

    pub fn process(self: *Self, input: f32) f32 {
        const fast = self.fast_env.process(input);
        const slow = self.slow_env.process(input);

        // Transient = fast - slow (positive during attack)
        const transient = fast - slow;

        // Sustain = slow envelope
        const sustain = slow;

        // Calculate gain modifiers
        var attack_mod: f32 = 0;
        var sustain_mod: f32 = 0;

        if (transient > 0.001 and fast > 0.001) {
            // We're in a transient
            const transient_amount = transient / fast; // Normalized 0-1
            attack_mod = self.attack_gain * transient_amount;
        }

        if (sustain > 0.001) {
            sustain_mod = self.sustain_gain;
        }

        // Smooth the gain changes
        self.attack_smooth += 0.1 * (attack_mod - self.attack_smooth);
        self.sustain_smooth += 0.01 * (sustain_mod - self.sustain_smooth);

        // Apply combined gain
        const total_db = self.attack_smooth + self.sustain_smooth;
        return input * utils.dbToLinear(total_db);
    }

    pub fn reset(self: *Self) void {
        self.fast_env.reset();
        self.slow_env.reset();
        self.attack_smooth = 0;
        self.sustain_smooth = 0;
    }
};

// =============================================================================
// Utility Functions
// =============================================================================

/// Convert milliseconds to exponential coefficient
fn msToCoef(ms: f32, sample_rate: f32) f32 {
    if (ms <= 0) return 1.0;
    const samples = ms * sample_rate / 1000.0;
    return 1.0 - @exp(-1.0 / samples);
}

// =============================================================================
// Tests
// =============================================================================

test "compressor reduces gain" {
    const testing = std.testing;

    var comp = Compressor.init(44100);
    comp.setThreshold(-20);
    comp.setRatio(4);
    comp.setAttack(1);
    comp.setRelease(50);

    // Feed loud signal
    for (0..1000) |_| {
        _ = comp.process(1.0);
    }

    // Should have some gain reduction
    try testing.expect(comp.getGainReduction() > 0);
}

test "limiter prevents clipping" {
    const testing = std.testing;

    var lim = Limiter.init(44100);
    lim.setCeiling(-3);
    lim.setLookahead(64);

    // Feed signal louder than ceiling
    for (0..200) |_| {
        const out = lim.process(2.0);
        // After lookahead fills, output should be limited
        if (out != 0) {
            try testing.expect(@abs(out) <= utils.dbToLinear(-3) + 0.01);
        }
    }
}

test "gate opens and closes" {
    const testing = std.testing;

    var gate = Gate.init(44100);
    gate.setThreshold(-20);
    gate.setAttack(1);
    gate.setRelease(10);
    gate.setHold(0);
    gate.setRange(-40); // Set a less aggressive range for faster closure

    // Start closed
    try testing.expect(!gate.isOpen());

    // Feed loud signal
    for (0..1000) |_| {
        _ = gate.process(1.0);
    }
    try testing.expect(gate.isOpen());

    // Feed silence - needs enough samples for exponential decay
    for (0..50000) |_| {
        _ = gate.process(0.0);
    }
    try testing.expect(!gate.isOpen());
}
