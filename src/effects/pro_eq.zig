//! Pro EQ - FabFilter Pro-Q style parametric equalizer
//!
//! 8 fully configurable bands with multiple filter types:
//! - Bell (parametric peak/dip)
//! - Low/High Shelf
//! - Low/High Cut (high-pass/low-pass)
//! - Notch
//! - Band Pass
//!
//! Each band has frequency, gain, Q, type, enabled, and solo controls.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

pub const MAX_BANDS: usize = 8;
pub const PARAMS_PER_BAND: usize = 6; // freq, gain, q, type, enabled, solo
pub const TOTAL_PARAMS: usize = MAX_BANDS * PARAMS_PER_BAND + 1; // +1 for output gain

/// Filter types available for each band
pub const FilterType = enum(u8) {
    bell = 0, // Parametric peak/dip
    low_shelf = 1, // Low shelf
    high_shelf = 2, // High shelf
    low_cut = 3, // High-pass filter (cuts lows)
    high_cut = 4, // Low-pass filter (cuts highs)
    notch = 5, // Notch/band-reject
    band_pass = 6, // Band-pass
};

/// Single EQ band with biquad filter
const EQBand = struct {
    // Parameters
    frequency: f32 = 1000.0,
    gain: f32 = 0.0,
    q: f32 = 1.0,
    filter_type: FilterType = .bell,
    enabled: bool = false,
    solo: bool = false,

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

    coeffs_dirty: bool = true,

    pub fn updateCoefficients(self: *EQBand, sample_rate: f32) void {
        if (!self.coeffs_dirty) return;
        self.coeffs_dirty = false;

        if (!self.enabled) {
            self.setPassthrough();
            return;
        }

        const freq = std.math.clamp(self.frequency, 20.0, sample_rate * 0.45);
        const q = std.math.clamp(self.q, 0.1, 30.0);

        const omega = 2.0 * std.math.pi * freq / sample_rate;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const alpha = sin_omega / (2.0 * q);

        // Gain for shelving and peaking filters
        const A = std.math.pow(f32, 10.0, self.gain / 40.0);
        const sq_a = @sqrt(A);

        var b0: f32 = 1.0;
        var b1: f32 = 0.0;
        var b2: f32 = 0.0;
        var a0: f32 = 1.0;
        var a1: f32 = 0.0;
        var a2: f32 = 0.0;

        switch (self.filter_type) {
            .bell => {
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cos_omega;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha / A;
            },
            .low_shelf => {
                b0 = A * ((A + 1.0) - (A - 1.0) * cos_omega + 2.0 * sq_a * alpha);
                b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_omega);
                b2 = A * ((A + 1.0) - (A - 1.0) * cos_omega - 2.0 * sq_a * alpha);
                a0 = (A + 1.0) + (A - 1.0) * cos_omega + 2.0 * sq_a * alpha;
                a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_omega);
                a2 = (A + 1.0) + (A - 1.0) * cos_omega - 2.0 * sq_a * alpha;
            },
            .high_shelf => {
                b0 = A * ((A + 1.0) + (A - 1.0) * cos_omega + 2.0 * sq_a * alpha);
                b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_omega);
                b2 = A * ((A + 1.0) + (A - 1.0) * cos_omega - 2.0 * sq_a * alpha);
                a0 = (A + 1.0) - (A - 1.0) * cos_omega + 2.0 * sq_a * alpha;
                a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_omega);
                a2 = (A + 1.0) - (A - 1.0) * cos_omega - 2.0 * sq_a * alpha;
            },
            .low_cut => {
                // High-pass filter
                b0 = (1.0 + cos_omega) / 2.0;
                b1 = -(1.0 + cos_omega);
                b2 = (1.0 + cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .high_cut => {
                // Low-pass filter
                b0 = (1.0 - cos_omega) / 2.0;
                b1 = 1.0 - cos_omega;
                b2 = (1.0 - cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .notch => {
                b0 = 1.0;
                b1 = -2.0 * cos_omega;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .band_pass => {
                b0 = alpha;
                b1 = 0.0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
        }

        self.normalizeCoeffs(b0, b1, b2, a0, a1, a2);
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

        // Sanitize
        if (std.math.isNan(self.b0) or std.math.isInf(self.b0)) self.b0 = 1.0;
        if (std.math.isNan(self.b1) or std.math.isInf(self.b1)) self.b1 = 0.0;
        if (std.math.isNan(self.b2) or std.math.isInf(self.b2)) self.b2 = 0.0;
        if (std.math.isNan(self.a1) or std.math.isInf(self.a1)) self.a1 = 0.0;
        if (std.math.isNan(self.a2) or std.math.isInf(self.a2)) self.a2 = 0.0;
    }

    fn setPassthrough(self: *EQBand) void {
        self.b0 = 1.0;
        self.b1 = 0.0;
        self.b2 = 0.0;
        self.a1 = 0.0;
        self.a2 = 0.0;
    }

    pub fn process(self: *EQBand, in_l: f32, in_r: f32) struct { l: f32, r: f32 } {
        if (!self.enabled) return .{ .l = in_l, .r = in_r };

        // Sanitize input
        const safe_l = if (std.math.isNan(in_l) or std.math.isInf(in_l)) 0.0 else in_l;
        const safe_r = if (std.math.isNan(in_r) or std.math.isInf(in_r)) 0.0 else in_r;

        // Left channel
        var y_l = self.b0 * safe_l + self.b1 * self.x1[0] + self.b2 * self.x2[0] - self.a1 * self.y1[0] - self.a2 * self.y2[0];

        if (std.math.isNan(y_l) or std.math.isInf(y_l) or @abs(y_l) > 1e6) {
            y_l = 0.0;
            self.reset();
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

    pub fn markDirty(self: *EQBand) void {
        self.coeffs_dirty = true;
    }
};

/// Pro EQ - 8-band parametric equalizer
pub const ProEQ = struct {
    effect: Effect,
    bands: [MAX_BANDS]EQBand = @as([MAX_BANDS]EQBand, @splat(.{})),
    output_gain: f32 = 0.0, // dB

    // Parameters array for Effect interface
    params: [TOTAL_PARAMS]Parameter = initParams(),

    // Cache
    last_sample_rate: u32 = 0,
    coeffs_dirty: bool = true,

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    fn initParams() [TOTAL_PARAMS]Parameter {
        var params: [TOTAL_PARAMS]Parameter = undefined;

        // Default frequencies spread across spectrum
        const default_freqs = [_]f32{ 60, 170, 400, 1000, 2500, 5000, 10000, 16000 };
        const default_types = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 2 }; // low_shelf, bells, high_shelf

        for (0..MAX_BANDS) |band| {
            const base = band * PARAMS_PER_BAND;

            params[base + 0] = .{ .name = "Freq", .min = 20.0, .max = 20000.0, .default = default_freqs[band], .value = default_freqs[band], .unit = "Hz" };
            params[base + 1] = .{ .name = "Gain", .min = -30.0, .max = 30.0, .default = 0.0, .value = 0.0, .unit = "dB" };
            params[base + 2] = .{ .name = "Q", .min = 0.1, .max = 30.0, .default = 1.0, .value = 1.0, .unit = "" };
            params[base + 3] = .{ .name = "Type", .min = 0.0, .max = 6.0, .default = default_types[band], .value = default_types[band], .unit = "" };
            params[base + 4] = .{ .name = "On", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" };
            params[base + 5] = .{ .name = "Solo", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" };
        }

        // Enable bands 0, 3, 7 by default
        params[0 * PARAMS_PER_BAND + 4].value = 1.0; // Band 0 enabled
        params[0 * PARAMS_PER_BAND + 4].default = 1.0;
        params[3 * PARAMS_PER_BAND + 4].value = 1.0; // Band 3 enabled
        params[3 * PARAMS_PER_BAND + 4].default = 1.0;
        params[7 * PARAMS_PER_BAND + 4].value = 1.0; // Band 7 enabled
        params[7 * PARAMS_PER_BAND + 4].default = 1.0;

        // Output gain
        params[TOTAL_PARAMS - 1] = .{ .name = "Output", .min = -24.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" };

        return params;
    }

    pub fn init() ProEQ {
        var eq = ProEQ{
            .effect = .{
                .vtable = &vtable,
                .name = "Pro EQ",
            },
        };

        // Initialize bands from params
        eq.syncBandsFromParams();

        return eq;
    }

    fn syncBandsFromParams(self: *ProEQ) void {
        for (0..MAX_BANDS) |i| {
            const base = i * PARAMS_PER_BAND;
            self.bands[i].frequency = self.params[base + 0].value;
            self.bands[i].gain = self.params[base + 1].value;
            self.bands[i].q = self.params[base + 2].value;
            self.bands[i].filter_type = @fromBackingInt(@intCast(@as(u8, @intFromFloat(self.params[base + 3].value))));
            self.bands[i].enabled = self.params[base + 4].value >= 0.5;
            self.bands[i].solo = self.params[base + 5].value >= 0.5;
            self.bands[i].markDirty();
        }
        self.output_gain = self.params[TOTAL_PARAMS - 1].value;
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *ProEQ = @fieldParentPtr("effect", effect);

        // Update coefficients if needed
        if (self.coeffs_dirty or self.last_sample_rate != sample_rate) {
            self.syncBandsFromParams();
            for (&self.bands) |*band| {
                band.updateCoefficients(@floatFromInt(sample_rate));
            }
            self.last_sample_rate = sample_rate;
            self.coeffs_dirty = false;
        }

        // Check if any band is soloed
        var any_solo = false;
        for (&self.bands) |*band| {
            if (band.solo and band.enabled) {
                any_solo = true;
                break;
            }
        }

        const output_gain_linear = std.math.pow(f32, 10.0, self.output_gain / 20.0);
        const frames = buffer.len / 2;

        for (0..frames) |i| {
            var l = buffer[i * 2];
            var r = buffer[i * 2 + 1];

            // Process through all enabled bands
            for (&self.bands) |*band| {
                if (!band.enabled) continue;
                if (any_solo and !band.solo) continue;

                const out = band.process(l, r);
                l = out.l;
                r = out.r;
            }

            // Apply output gain
            buffer[i * 2] = l * output_gain_linear;
            buffer[i * 2 + 1] = r * output_gain_linear;
        }
    }

    fn reset(effect: *Effect) void {
        const self: *ProEQ = @fieldParentPtr("effect", effect);
        for (&self.bands) |*band| {
            band.reset();
        }
    }

    fn getParameterCount(_: *const Effect) usize {
        return TOTAL_PARAMS;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const ProEQ = @fieldParentPtr("effect", effect);
        if (index >= TOTAL_PARAMS) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *ProEQ = @fieldParentPtr("effect", effect);
        if (index >= TOTAL_PARAMS) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
        self.coeffs_dirty = true;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pro eq init" {
    const eq = ProEQ.init();
    try testing.expectEqualStrings("Pro EQ", eq.effect.name);
    try testing.expectEqual(@as(usize, TOTAL_PARAMS), eq.effect.vtable.getParameterCount(&eq.effect));
}

test "pro eq parameter count" {
    try testing.expectEqual(@as(usize, 49), TOTAL_PARAMS); // 8 bands * 6 params + 1 output
}

test "pro eq default bands enabled" {
    const eq = ProEQ.init();
    try testing.expect(eq.bands[0].enabled); // Low shelf
    try testing.expect(!eq.bands[1].enabled);
    try testing.expect(!eq.bands[2].enabled);
    try testing.expect(eq.bands[3].enabled); // Mid bell
    try testing.expect(!eq.bands[4].enabled);
    try testing.expect(!eq.bands[5].enabled);
    try testing.expect(!eq.bands[6].enabled);
    try testing.expect(eq.bands[7].enabled); // High shelf
}
