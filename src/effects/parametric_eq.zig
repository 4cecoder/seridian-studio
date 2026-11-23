//! Parametric EQ Effect
//!
//! A 4-band parametric equalizer with:
//! - Low Shelf (bass boost/cut)
//! - Peak 1 (low-mid sculpting)
//! - Peak 2 (high-mid sculpting)
//! - High Shelf (treble boost/cut)
//!
//! Each band uses biquad filters with RBJ Audio EQ Cookbook formulas.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

/// Single biquad filter band
const EQBand = struct {
    // Biquad coefficients
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    // Filter state (stereo)
    x1: [2]f32 = .{ 0.0, 0.0 },
    x2: [2]f32 = .{ 0.0, 0.0 },
    y1: [2]f32 = .{ 0.0, 0.0 },
    y2: [2]f32 = .{ 0.0, 0.0 },

    pub fn process(self: *EQBand, input_l: f32, input_r: f32) struct { l: f32, r: f32 } {
        // Sanitize input
        const safe_l = if (std.math.isNan(input_l) or std.math.isInf(input_l)) 0.0 else input_l;
        const safe_r = if (std.math.isNan(input_r) or std.math.isInf(input_r)) 0.0 else input_r;

        // Left channel
        var y_l = self.b0 * safe_l + self.b1 * self.x1[0] + self.b2 * self.x2[0] - self.a1 * self.y1[0] - self.a2 * self.y2[0];

        // Sanitize state to prevent runaway
        if (std.math.isNan(y_l) or std.math.isInf(y_l) or @abs(y_l) > 1e6) {
            y_l = 0.0;
            self.x1[0] = 0.0;
            self.x2[0] = 0.0;
            self.y1[0] = 0.0;
            self.y2[0] = 0.0;
        } else {
            self.x2[0] = self.x1[0];
            self.x1[0] = safe_l;
            self.y2[0] = self.y1[0];
            self.y1[0] = y_l;
        }

        // Right channel
        var y_r = self.b0 * safe_r + self.b1 * self.x1[1] + self.b2 * self.x2[1] - self.a1 * self.y1[1] - self.a2 * self.y2[1];

        if (std.math.isNan(y_r) or std.math.isInf(y_r) or @abs(y_r) > 1e6) {
            y_r = 0.0;
            self.x1[1] = 0.0;
            self.x2[1] = 0.0;
            self.y1[1] = 0.0;
            self.y2[1] = 0.0;
        } else {
            self.x2[1] = self.x1[1];
            self.x1[1] = safe_r;
            self.y2[1] = self.y1[1];
            self.y1[1] = y_r;
        }

        return .{ .l = y_l, .r = y_r };
    }

    pub fn reset(self: *EQBand) void {
        self.x1 = .{ 0.0, 0.0 };
        self.x2 = .{ 0.0, 0.0 };
        self.y1 = .{ 0.0, 0.0 };
        self.y2 = .{ 0.0, 0.0 };
    }

    /// Calculate low shelf coefficients
    pub fn setLowShelf(self: *EQBand, freq: f32, gain_db: f32, q: f32, sample_rate: f32) void {
        const safe_freq = std.math.clamp(freq, 20.0, sample_rate * 0.4);
        const safe_q = @max(0.1, q);
        const safe_gain = std.math.clamp(gain_db, -24.0, 24.0);

        const omega = 2.0 * std.math.pi * safe_freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const a = std.math.pow(f32, 10.0, safe_gain / 40.0);
        const sq_a = @sqrt(a);
        const alpha = sin_omega / (2.0 * safe_q);

        const b0 = a * ((a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sq_a * alpha);
        const b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_omega);
        const b2 = a * ((a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sq_a * alpha);
        const a0 = (a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sq_a * alpha;
        const a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cos_omega);
        const a2 = (a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sq_a * alpha;

        self.normalizeCoeffs(b0, b1, b2, a0, a1, a2);
    }

    /// Calculate high shelf coefficients
    pub fn setHighShelf(self: *EQBand, freq: f32, gain_db: f32, q: f32, sample_rate: f32) void {
        const safe_freq = std.math.clamp(freq, 20.0, sample_rate * 0.4);
        const safe_q = @max(0.1, q);
        const safe_gain = std.math.clamp(gain_db, -24.0, 24.0);

        const omega = 2.0 * std.math.pi * safe_freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const a = std.math.pow(f32, 10.0, safe_gain / 40.0);
        const sq_a = @sqrt(a);
        const alpha = sin_omega / (2.0 * safe_q);

        const b0 = a * ((a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sq_a * alpha);
        const b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_omega);
        const b2 = a * ((a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sq_a * alpha);
        const a0 = (a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sq_a * alpha;
        const a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cos_omega);
        const a2 = (a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sq_a * alpha;

        self.normalizeCoeffs(b0, b1, b2, a0, a1, a2);
    }

    /// Calculate peak/parametric coefficients
    pub fn setPeak(self: *EQBand, freq: f32, gain_db: f32, q: f32, sample_rate: f32) void {
        const safe_freq = std.math.clamp(freq, 20.0, sample_rate * 0.4);
        const safe_q = @max(0.1, q);
        const safe_gain = std.math.clamp(gain_db, -24.0, 24.0);

        const omega = 2.0 * std.math.pi * safe_freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const a = std.math.pow(f32, 10.0, safe_gain / 40.0);
        const alpha = sin_omega / (2.0 * safe_q);

        const b0 = 1.0 + alpha * a;
        const b1 = -2.0 * cos_omega;
        const b2 = 1.0 - alpha * a;
        const a0 = 1.0 + alpha / a;
        const a1 = -2.0 * cos_omega;
        const a2 = 1.0 - alpha / a;

        self.normalizeCoeffs(b0, b1, b2, a0, a1, a2);
    }

    /// Calculate 2nd-order high-pass coefficients (12 dB/octave)
    pub fn setHighPass(self: *EQBand, freq: f32, q: f32, sample_rate: f32) void {
        const safe_freq = std.math.clamp(freq, 20.0, sample_rate * 0.4);
        const safe_q = @max(0.1, q);

        const omega = 2.0 * std.math.pi * safe_freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const alpha = sin_omega / (2.0 * safe_q);

        const b0 = (1.0 + cos_omega) / 2.0;
        const b1 = -(1.0 + cos_omega);
        const b2 = (1.0 + cos_omega) / 2.0;
        const a0 = 1.0 + alpha;
        const a1 = -2.0 * cos_omega;
        const a2 = 1.0 - alpha;

        self.normalizeCoeffs(b0, b1, b2, a0, a1, a2);
    }

    /// Set to passthrough (unity gain)
    pub fn setPassthrough(self: *EQBand) void {
        self.b0 = 1.0;
        self.b1 = 0.0;
        self.b2 = 0.0;
        self.a1 = 0.0;
        self.a2 = 0.0;
    }

    fn normalizeCoeffs(self: *EQBand, b0: f32, b1: f32, b2: f32, a0: f32, a1: f32, a2: f32) void {
        if (a0 == 0.0 or std.math.isNan(a0) or std.math.isInf(a0)) {
            self.setPassthrough();
            return;
        }

        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;

        // Sanitize any NaN/Inf
        if (std.math.isNan(self.b0) or std.math.isInf(self.b0)) self.b0 = 1.0;
        if (std.math.isNan(self.b1) or std.math.isInf(self.b1)) self.b1 = 0.0;
        if (std.math.isNan(self.b2) or std.math.isInf(self.b2)) self.b2 = 0.0;
        if (std.math.isNan(self.a1) or std.math.isInf(self.a1)) self.a1 = 0.0;
        if (std.math.isNan(self.a2) or std.math.isInf(self.a2)) self.a2 = 0.0;
    }
};

/// 4-Band Parametric EQ
pub const ParametricEQ = struct {
    pub const param_count = 14;
    pub const hp_freq_param = 13;
    /// High-pass frequency at or below which the stage is bypassed.
    pub const hp_off_hz: f32 = 20.5;

    effect: Effect,

    // 4 EQ bands
    bands: [4]EQBand = .{ .{}, .{}, .{}, .{} },

    // High-pass stage ahead of the bands; off at its minimum frequency
    high_pass: EQBand = .{},

    // Parameters: 4 bands x 3 params each (freq, gain, Q) + output gain + high-pass freq = 14 params
    params: [param_count]Parameter = .{
        // Low Shelf
        .{ .name = "Low Freq", .min = 20.0, .max = 500.0, .default = 80.0, .value = 80.0, .unit = "Hz" },
        .{ .name = "Low Gain", .min = -18.0, .max = 18.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "Low Q", .min = 0.1, .max = 3.0, .default = 0.7, .value = 0.7, .unit = "" },
        // Peak 1 (Low-Mid)
        .{ .name = "Mid1 Freq", .min = 100.0, .max = 2000.0, .default = 500.0, .value = 500.0, .unit = "Hz" },
        .{ .name = "Mid1 Gain", .min = -18.0, .max = 18.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "Mid1 Q", .min = 0.1, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "" },
        // Peak 2 (High-Mid)
        .{ .name = "Mid2 Freq", .min = 500.0, .max = 8000.0, .default = 2000.0, .value = 2000.0, .unit = "Hz" },
        .{ .name = "Mid2 Gain", .min = -18.0, .max = 18.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "Mid2 Q", .min = 0.1, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "" },
        // High Shelf
        .{ .name = "High Freq", .min = 2000.0, .max = 16000.0, .default = 8000.0, .value = 8000.0, .unit = "Hz" },
        .{ .name = "High Gain", .min = -18.0, .max = 18.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "High Q", .min = 0.1, .max = 3.0, .default = 0.7, .value = 0.7, .unit = "" },
        // Output
        .{ .name = "Output", .min = -12.0, .max = 12.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        // High-pass (20 Hz = off)
        .{ .name = "HP Freq", .min = 20.0, .max = 400.0, .default = 20.0, .value = 20.0, .unit = "Hz" },
    },

    // Cached values
    last_sample_rate: u32 = 0,
    coeffs_dirty: bool = true,

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() ParametricEQ {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Parametric EQ",
            },
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *ParametricEQ = @fieldParentPtr("effect", effect);

        // Recalculate coefficients if needed
        if (self.coeffs_dirty or self.last_sample_rate != sample_rate) {
            self.updateCoefficients(@floatFromInt(sample_rate));
            self.last_sample_rate = sample_rate;
            self.coeffs_dirty = false;
        }

        const output_gain = std.math.pow(f32, 10.0, self.params[12].value / 20.0);
        const hp_active = self.params[hp_freq_param].value > hp_off_hz;
        const frames = buffer.len / 2;

        for (0..frames) |i| {
            var l = buffer[i * 2];
            var r = buffer[i * 2 + 1];

            if (hp_active) {
                const out = self.high_pass.process(l, r);
                l = out.l;
                r = out.r;
            }

            // Process through all 4 bands in series
            for (&self.bands) |*band| {
                const out = band.process(l, r);
                l = out.l;
                r = out.r;
            }

            // Apply output gain
            buffer[i * 2] = l * output_gain;
            buffer[i * 2 + 1] = r * output_gain;
        }
    }

    fn updateCoefficients(self: *ParametricEQ, sample_rate: f32) void {
        // High-pass
        const hp_freq = self.params[hp_freq_param].value;
        if (hp_freq <= hp_off_hz) {
            self.high_pass.setPassthrough();
        } else {
            self.high_pass.setHighPass(hp_freq, 0.7071, sample_rate);
        }

        // Low Shelf
        const low_freq = self.params[0].value;
        const low_gain = self.params[1].value;
        const low_q = self.params[2].value;
        if (@abs(low_gain) < 0.1) {
            self.bands[0].setPassthrough();
        } else {
            self.bands[0].setLowShelf(low_freq, low_gain, low_q, sample_rate);
        }

        // Peak 1 (Low-Mid)
        const mid1_freq = self.params[3].value;
        const mid1_gain = self.params[4].value;
        const mid1_q = self.params[5].value;
        if (@abs(mid1_gain) < 0.1) {
            self.bands[1].setPassthrough();
        } else {
            self.bands[1].setPeak(mid1_freq, mid1_gain, mid1_q, sample_rate);
        }

        // Peak 2 (High-Mid)
        const mid2_freq = self.params[6].value;
        const mid2_gain = self.params[7].value;
        const mid2_q = self.params[8].value;
        if (@abs(mid2_gain) < 0.1) {
            self.bands[2].setPassthrough();
        } else {
            self.bands[2].setPeak(mid2_freq, mid2_gain, mid2_q, sample_rate);
        }

        // High Shelf
        const high_freq = self.params[9].value;
        const high_gain = self.params[10].value;
        const high_q = self.params[11].value;
        if (@abs(high_gain) < 0.1) {
            self.bands[3].setPassthrough();
        } else {
            self.bands[3].setHighShelf(high_freq, high_gain, high_q, sample_rate);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *ParametricEQ = @fieldParentPtr("effect", effect);
        for (&self.bands) |*band| {
            band.reset();
        }
        self.high_pass.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return param_count;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const ParametricEQ = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *ParametricEQ = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
        self.coeffs_dirty = true;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parametric eq init" {
    const eq = ParametricEQ.init();
    try testing.expectEqualStrings("Parametric EQ", eq.effect.name);
    try testing.expectEqual(@as(usize, 14), eq.effect.vtable.getParameterCount(&eq.effect));
}

test "parametric eq passthrough when flat" {
    var eq = ParametricEQ.init();

    // All gains at 0 dB - should be near-passthrough
    var buffer = [_]f32{ 0.5, 0.5, -0.5, -0.5 };
    eq.effect.process(&buffer, 48000);

    // With all gains at 0, output should be very close to input
    try testing.expect(@abs(buffer[0] - 0.5) < 0.1);
    try testing.expect(@abs(buffer[1] - 0.5) < 0.1);
}

test "parametric eq boost low" {
    var eq = ParametricEQ.init();

    // Boost low frequencies
    eq.effect.vtable.setParameter(&eq.effect, 1, 6.0); // Low Gain +6dB

    // An 80 Hz shelf needs ~100 samples to respond, so feed 100 ms of DC
    // and check the settled gain: +6 dB is a factor of 10^(6/20) ~= 1.995.
    var buffer: [2 * 4800]f32 = @splat(0.5);
    eq.effect.process(&buffer, 48000);
    try testing.expectApproxEqAbs(@as(f32, 0.5 * 1.9953), buffer[buffer.len - 1], 0.02);
}

test "parametric eq reset" {
    var eq = ParametricEQ.init();

    // Process some audio
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0 };
    eq.effect.vtable.setParameter(&eq.effect, 4, 12.0); // Big boost
    eq.effect.process(&buffer, 48000);

    // Reset
    eq.effect.vtable.reset(&eq.effect);

    // State should be cleared
    for (eq.bands) |band| {
        try testing.expectEqual(@as(f32, 0.0), band.x1[0]);
        try testing.expectEqual(@as(f32, 0.0), band.y1[0]);
    }
}

test "parametric eq parameter clamping" {
    var eq = ParametricEQ.init();

    // Try to set gain beyond limits
    eq.effect.vtable.setParameter(&eq.effect, 1, 100.0); // Low Gain
    try testing.expectEqual(@as(f32, 18.0), eq.params[1].value);

    eq.effect.vtable.setParameter(&eq.effect, 1, -100.0);
    try testing.expectEqual(@as(f32, -18.0), eq.params[1].value);
}
