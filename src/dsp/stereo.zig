//! Stereo Processing Utilities
//!
//! Tools for stereo field manipulation:
//! - Mid-Side encoding/decoding
//! - Stereo width control
//! - Stereo enhancer (Haas effect, etc.)
//! - Pan laws (linear, constant power, etc.)
//! - Channel operations (swap, mono, etc.)
//! - Correlation metering
//!
//! All utilities are designed for sample-by-sample or block processing.

const std = @import("std");
const math = std.math;
const utils = @import("utils.zig");

// =============================================================================
// Stereo Sample Type
// =============================================================================

pub const StereoSample = struct {
    left: f32,
    right: f32,

    pub fn mono(value: f32) StereoSample {
        return .{ .left = value, .right = value };
    }

    pub fn add(self: StereoSample, other: StereoSample) StereoSample {
        return .{
            .left = self.left + other.left,
            .right = self.right + other.right,
        };
    }

    pub fn scale(self: StereoSample, factor: f32) StereoSample {
        return .{
            .left = self.left * factor,
            .right = self.right * factor,
        };
    }

    pub fn toMono(self: StereoSample) f32 {
        return (self.left + self.right) * 0.5;
    }
};

// =============================================================================
// Mid-Side Processing
// =============================================================================

/// Encode left/right to mid/side
pub fn encodeMS(left: f32, right: f32) struct { mid: f32, side: f32 } {
    return .{
        .mid = (left + right) * 0.5,
        .side = (left - right) * 0.5,
    };
}

/// Decode mid/side to left/right
pub fn decodeMS(mid: f32, side: f32) StereoSample {
    return .{
        .left = mid + side,
        .right = mid - side,
    };
}

/// Process stereo signal in M/S domain
pub const MidSideProcessor = struct {
    mid_gain: f32 = 1.0,
    side_gain: f32 = 1.0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set mid gain in dB
    pub fn setMidGain(self: *Self, db: f32) void {
        self.mid_gain = utils.dbToLinear(db);
    }

    /// Set side gain in dB
    pub fn setSideGain(self: *Self, db: f32) void {
        self.side_gain = utils.dbToLinear(db);
    }

    /// Set width (0 = mono, 1 = normal, 2 = extra wide)
    pub fn setWidth(self: *Self, width: f32) void {
        self.side_gain = math.clamp(width, 0, 3);
    }

    pub fn process(self: *Self, left: f32, right: f32) StereoSample {
        const ms = encodeMS(left, right);
        return decodeMS(ms.mid * self.mid_gain, ms.side * self.side_gain);
    }

    pub fn processBlock(self: *Self, left: []f32, right: []f32) void {
        for (left, right) |*l, *r| {
            const result = self.process(l.*, r.*);
            l.* = result.left;
            r.* = result.right;
        }
    }
};

// =============================================================================
// Stereo Width Control
// =============================================================================

/// Attempt stereo width control using correlation-based widening
pub const StereoWidth = struct {
    width: f32 = 1.0, // 0 = mono, 1 = normal, 2 = extra wide

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set width (0 = mono, 1 = unchanged, 2 = double width)
    pub fn setWidth(self: *Self, width: f32) void {
        self.width = math.clamp(width, 0, 3);
    }

    pub fn process(self: *Self, left: f32, right: f32) StereoSample {
        // Simple M/S based width
        const mid = (left + right) * 0.5;
        const side = (left - right) * 0.5 * self.width;

        return .{
            .left = mid + side,
            .right = mid - side,
        };
    }
};

// =============================================================================
// Stereo Enhancer (Haas Effect)
// =============================================================================

/// Stereo enhancer using micro-delays and EQ
pub const StereoEnhancer = struct {
    // Delay for Haas effect
    delay_buffer_l: [512]f32 = @as([512]f32, @splat(0)),
    delay_buffer_r: [512]f32 = @as([512]f32, @splat(0)),
    write_pos: usize = 0,
    delay_samples: usize = 20,

    // Parameters
    width: f32 = 0.5, // 0-1 enhancement amount
    bass_mono: f32 = 0, // Bass mono-ification frequency

    // Bass filter state
    bass_lp_l: f32 = 0,
    bass_lp_r: f32 = 0,
    bass_coef: f32 = 0.1,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setDelayMs(15);
        return self;
    }

    /// Set delay time in milliseconds (affects stereo spread)
    pub fn setDelayMs(self: *Self, ms: f32) void {
        const samples = ms * self.sample_rate / 1000.0;
        self.delay_samples = @min(@as(usize, @intFromFloat(samples)), self.delay_buffer_l.len - 1);
    }

    /// Set enhancement amount (0-1)
    pub fn setWidth(self: *Self, width: f32) void {
        self.width = math.clamp(width, 0, 1);
    }

    /// Set bass mono frequency (0 = disabled)
    pub fn setBassMono(self: *Self, freq: f32) void {
        self.bass_mono = freq;
        if (freq > 0) {
            self.bass_coef = 1.0 - @exp(-2.0 * math.pi * freq / self.sample_rate);
        }
    }

    pub fn process(self: *Self, left: f32, right: f32) StereoSample {
        // Read delayed signals
        const read_pos = (self.write_pos + self.delay_buffer_l.len - self.delay_samples) % self.delay_buffer_l.len;
        const delayed_l = self.delay_buffer_l[read_pos];
        const delayed_r = self.delay_buffer_r[read_pos];

        // Write current to delay
        self.delay_buffer_l[self.write_pos] = left;
        self.delay_buffer_r[self.write_pos] = right;
        self.write_pos = (self.write_pos + 1) % self.delay_buffer_l.len;

        // Cross-mix delayed signal for width
        var out_l = left + delayed_r * self.width * 0.3;
        var out_r = right + delayed_l * self.width * 0.3;

        // Bass mono-ification
        if (self.bass_mono > 0) {
            // Extract bass
            self.bass_lp_l += self.bass_coef * (out_l - self.bass_lp_l);
            self.bass_lp_r += self.bass_coef * (out_r - self.bass_lp_r);

            // Mono the bass
            const bass_mono = (self.bass_lp_l + self.bass_lp_r) * 0.5;

            // Replace stereo bass with mono bass
            out_l = (out_l - self.bass_lp_l) + bass_mono;
            out_r = (out_r - self.bass_lp_r) + bass_mono;
        }

        return .{ .left = out_l, .right = out_r };
    }

    pub fn reset(self: *Self) void {
        @memset(&self.delay_buffer_l, 0);
        @memset(&self.delay_buffer_r, 0);
        self.write_pos = 0;
        self.bass_lp_l = 0;
        self.bass_lp_r = 0;
    }
};

// =============================================================================
// Pan Laws
// =============================================================================

pub const PanLaw = enum {
    linear, // Simple linear pan
    constant_power, // -3dB at center
    constant_power_4_5db, // -4.5dB at center (common in DAWs)
    constant_power_6db, // -6dB at center
};

/// Calculate pan gains for left and right channels
/// pan: -1.0 (hard left) to +1.0 (hard right)
pub fn panGains(pan: f32, law: PanLaw) StereoSample {
    const p = math.clamp(pan, -1, 1);

    switch (law) {
        .linear => {
            // Simple linear: left = (1-pan)/2, right = (1+pan)/2
            return .{
                .left = (1.0 - p) * 0.5,
                .right = (1.0 + p) * 0.5,
            };
        },
        .constant_power => {
            // -3dB at center using sine/cosine
            const angle = (p + 1.0) * math.pi * 0.25; // 0 to pi/2
            return .{
                .left = @cos(angle),
                .right = @sin(angle),
            };
        },
        .constant_power_4_5db => {
            // -4.5dB at center (compromise)
            const linear = StereoSample{
                .left = (1.0 - p) * 0.5,
                .right = (1.0 + p) * 0.5,
            };
            const angle = (p + 1.0) * math.pi * 0.25;
            const constant = StereoSample{
                .left = @cos(angle),
                .right = @sin(angle),
            };
            // Blend between linear and constant power
            return .{
                .left = (linear.left + constant.left) * 0.5,
                .right = (linear.right + constant.right) * 0.5,
            };
        },
        .constant_power_6db => {
            // -6dB at center (sqrt law)
            return .{
                .left = @sqrt((1.0 - p) * 0.5),
                .right = @sqrt((1.0 + p) * 0.5),
            };
        },
    }
}

/// Apply pan to a mono signal
pub fn panMono(input: f32, pan: f32, law: PanLaw) StereoSample {
    const gains = panGains(pan, law);
    return .{
        .left = input * gains.left,
        .right = input * gains.right,
    };
}

/// Apply balance to a stereo signal (preserves existing stereo image)
pub fn balance(left: f32, right: f32, bal: f32) StereoSample {
    const b = math.clamp(bal, -1, 1);
    if (b < 0) {
        // Balance left: attenuate right
        return .{
            .left = left,
            .right = right * (1.0 + b),
        };
    } else {
        // Balance right: attenuate left
        return .{
            .left = left * (1.0 - b),
            .right = right,
        };
    }
}

// =============================================================================
// Channel Operations
// =============================================================================

/// Swap left and right channels
pub fn swapChannels(left: f32, right: f32) StereoSample {
    return .{ .left = right, .right = left };
}

/// Invert phase of one or both channels
pub fn invertPhase(left: f32, right: f32, invert_left: bool, invert_right: bool) StereoSample {
    return .{
        .left = if (invert_left) -left else left,
        .right = if (invert_right) -right else right,
    };
}

/// Sum to mono
pub fn sumToMono(left: f32, right: f32) f32 {
    return (left + right) * 0.5;
}

/// Difference (side signal)
pub fn difference(left: f32, right: f32) f32 {
    return (left - right) * 0.5;
}

// =============================================================================
// Correlation Meter
// =============================================================================

/// Measures stereo correlation (-1 to +1)
/// +1 = mono/correlated, 0 = uncorrelated, -1 = out of phase
pub const CorrelationMeter = struct {
    sum_lr: f32 = 0,
    sum_l2: f32 = 0,
    sum_r2: f32 = 0,
    decay: f32 = 0.999,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Set averaging time in milliseconds
    pub fn setAveragingTime(self: *Self, ms: f32, sample_rate: f32) void {
        const samples = ms * sample_rate / 1000.0;
        self.decay = 1.0 - 1.0 / samples;
    }

    pub fn process(self: *Self, left: f32, right: f32) void {
        self.sum_lr = self.sum_lr * self.decay + left * right;
        self.sum_l2 = self.sum_l2 * self.decay + left * left;
        self.sum_r2 = self.sum_r2 * self.decay + right * right;
    }

    /// Get current correlation value (-1 to +1)
    pub fn getCorrelation(self: *Self) f32 {
        const denominator = @sqrt(self.sum_l2 * self.sum_r2);
        if (denominator < 0.0001) return 0;
        return math.clamp(self.sum_lr / denominator, -1, 1);
    }

    pub fn reset(self: *Self) void {
        self.sum_lr = 0;
        self.sum_l2 = 0;
        self.sum_r2 = 0;
    }
};

// =============================================================================
// Stereo Balance Analyzer
// =============================================================================

/// Analyzes left/right balance
pub const BalanceAnalyzer = struct {
    sum_l: f32 = 0,
    sum_r: f32 = 0,
    decay: f32 = 0.999,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn process(self: *Self, left: f32, right: f32) void {
        self.sum_l = self.sum_l * self.decay + @abs(left);
        self.sum_r = self.sum_r * self.decay + @abs(right);
    }

    /// Get balance (-1 = left, 0 = center, +1 = right)
    pub fn getBalance(self: *Self) f32 {
        const total = self.sum_l + self.sum_r;
        if (total < 0.0001) return 0;
        return (self.sum_r - self.sum_l) / total;
    }

    pub fn reset(self: *Self) void {
        self.sum_l = 0;
        self.sum_r = 0;
    }
};

// =============================================================================
// Auto-Pan
// =============================================================================

/// Automatic panning with LFO
pub const AutoPan = struct {
    phase: f32 = 0,
    rate: f32 = 1.0, // Hz
    depth: f32 = 1.0, // 0-1
    law: PanLaw = .constant_power,

    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        return .{ .sample_rate = sample_rate };
    }

    /// Set rate in Hz
    pub fn setRate(self: *Self, hz: f32) void {
        self.rate = @max(0.01, hz);
    }

    /// Set depth (0-1)
    pub fn setDepth(self: *Self, depth: f32) void {
        self.depth = math.clamp(depth, 0, 1);
    }

    pub fn process(self: *Self, left: f32, right: f32) StereoSample {
        // LFO
        self.phase += self.rate / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        const lfo = @sin(self.phase * math.pi * 2.0);
        const pan = lfo * self.depth;

        // Apply pan to input
        const gains = panGains(pan, self.law);
        const mono = (left + right) * 0.5;

        return .{
            .left = mono * gains.left * 2.0,
            .right = mono * gains.right * 2.0,
        };
    }

    pub fn reset(self: *Self) void {
        self.phase = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "mid-side encoding" {
    const testing = std.testing;

    // Mono signal should have no side
    const ms = encodeMS(0.5, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ms.mid, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), ms.side, 0.001);

    // Hard left should have equal mid and side
    const ms_left = encodeMS(1.0, 0.0);
    try testing.expectApproxEqAbs(ms_left.mid, ms_left.side, 0.001);

    // Round trip
    const decoded = decodeMS(ms.mid, ms.side);
    try testing.expectApproxEqAbs(@as(f32, 0.5), decoded.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), decoded.right, 0.001);
}

test "pan laws" {
    const testing = std.testing;

    // Center should have equal gains
    const center = panGains(0, .constant_power);
    try testing.expectApproxEqAbs(center.left, center.right, 0.001);

    // Hard left
    const left = panGains(-1, .linear);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left.right, 0.001);
}

test "correlation meter" {
    const testing = std.testing;

    var meter = CorrelationMeter.init();

    // Identical signals = +1 correlation
    for (0..1000) |_| {
        meter.process(0.5, 0.5);
    }
    try testing.expect(meter.getCorrelation() > 0.99);

    meter.reset();

    // Inverted signals = -1 correlation
    for (0..1000) |_| {
        meter.process(0.5, -0.5);
    }
    try testing.expect(meter.getCorrelation() < -0.99);
}
