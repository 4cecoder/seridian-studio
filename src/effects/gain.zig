//! Gain/Volume effect
//!
//! Simple gain control with optional soft clipping.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

pub const Gain = struct {
    effect: Effect,

    // Parameters
    params: [2]Parameter = .{
        .{ .name = "Gain", .min = -60.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "Soft Clip", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
    },

    // Cached linear gain
    linear_gain: f32 = 1.0,

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Gain {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Gain",
            },
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        _ = sample_rate;
        const self: *Gain = @fieldParentPtr("effect", effect);

        const gain = self.linear_gain;
        const soft_clip = self.params[1].value > 0.5;

        for (buffer) |*sample| {
            var s = sample.* * gain;

            if (soft_clip) {
                // Soft clipping using tanh approximation
                s = softClip(s);
            }

            sample.* = s;
        }
    }

    fn softClip(x: f32) f32 {
        // Fast tanh approximation for soft clipping
        if (x > 3.0) return 1.0;
        if (x < -3.0) return -1.0;
        const x2 = x * x;
        return x * (27.0 + x2) / (27.0 + 9.0 * x2);
    }

    fn reset(effect: *Effect) void {
        _ = effect;
        // Gain has no state to reset
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Gain = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Gain = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        // Update cached values
        if (index == 0) {
            // Convert dB to linear
            self.linear_gain = std.math.pow(f32, 10.0, self.params[0].value / 20.0);
        }
    }

    /// Convenience: set gain in dB
    pub fn setGainDb(self: *Gain, db: f32) void {
        setParameter(&self.effect, 0, db);
    }

    /// Convenience: get gain in dB
    pub fn getGainDb(self: *const Gain) f32 {
        return self.params[0].value;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "gain: dB to linear conversion accuracy" {
    var gain = Gain.init();

    // Test 0 dB = 1.0 linear
    gain.setGainDb(0.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), gain.linear_gain, 0.0001);

    // Test +6 dB = ~2.0 linear
    gain.setGainDb(6.0);
    try testing.expectApproxEqAbs(@as(f32, 1.9953), gain.linear_gain, 0.001);

    // Test -6 dB = ~0.5 linear
    gain.setGainDb(-6.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5012), gain.linear_gain, 0.001);

    // Test +12 dB = ~4.0 linear
    gain.setGainDb(12.0);
    try testing.expectApproxEqAbs(@as(f32, 3.9811), gain.linear_gain, 0.001);

    // Test -12 dB = ~0.25 linear
    gain.setGainDb(-12.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2512), gain.linear_gain, 0.001);

    // Test -60 dB (very quiet)
    gain.setGainDb(-60.0);
    try testing.expectApproxEqAbs(@as(f32, 0.001), gain.linear_gain, 0.0001);

    // Test +24 dB (max)
    gain.setGainDb(24.0);
    try testing.expectApproxEqAbs(@as(f32, 15.8489), gain.linear_gain, 0.01);
}

test "gain: soft clipping behavior" {
    var gain = Gain.init();

    // Enable soft clipping
    gain.effect.vtable.setParameter(&gain.effect, 1, 1.0);
    try testing.expect(gain.params[1].value > 0.5);

    // Test soft clip with high input
    var buffer = [_]f32{ 5.0, -5.0, 10.0, -10.0 };
    gain.effect.process(&buffer, 48000);

    // All samples should be clamped between -1.0 and 1.0
    for (buffer) |sample| {
        try testing.expect(sample >= -1.0 and sample <= 1.0);
    }

    // Test soft clip approximation at boundaries
    const clipped_positive = Gain.softClip(3.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), clipped_positive, 0.01);

    const clipped_negative = Gain.softClip(-3.5);
    try testing.expectApproxEqAbs(@as(f32, -1.0), clipped_negative, 0.01);

    // Test soft clip in the middle range
    const mid_clip = Gain.softClip(1.0);
    try testing.expect(mid_clip > 0.7 and mid_clip < 0.8);
}

test "gain: soft clipping disabled" {
    var gain = Gain.init();

    // Disable soft clipping (default)
    gain.effect.vtable.setParameter(&gain.effect, 1, 0.0);

    // Set gain to +12 dB
    gain.setGainDb(12.0);

    var buffer = [_]f32{ 0.5, -0.5, 1.0, -1.0 };
    gain.effect.process(&buffer, 48000);

    // With ~4x gain, outputs should exceed +-1.0
    try testing.expect(buffer[2] > 3.0);
    try testing.expect(buffer[3] < -3.0);
}

test "gain: parameter clamping" {
    var gain = Gain.init();

    // Test gain parameter clamping (min: -60 dB, max: +24 dB)
    gain.setGainDb(100.0); // Way above max
    try testing.expectEqual(@as(f32, 24.0), gain.getGainDb());

    gain.setGainDb(-100.0); // Way below min
    try testing.expectEqual(@as(f32, -60.0), gain.getGainDb());

    // Test soft clip parameter clamping (min: 0.0, max: 1.0)
    gain.effect.vtable.setParameter(&gain.effect, 1, 5.0); // Above max
    try testing.expectEqual(@as(f32, 1.0), gain.params[1].value);

    gain.effect.vtable.setParameter(&gain.effect, 1, -5.0); // Below min
    try testing.expectEqual(@as(f32, 0.0), gain.params[1].value);
}

test "gain: unity gain passes signal unchanged" {
    var gain = Gain.init();
    gain.setGainDb(0.0);

    var buffer = [_]f32{ 0.5, -0.5, 0.25, -0.75 };
    const expected = buffer;
    gain.effect.process(&buffer, 48000);

    for (buffer, expected) |actual, expect| {
        try testing.expectApproxEqAbs(expect, actual, 0.0001);
    }
}

test "gain: negative gain attenuates signal" {
    var gain = Gain.init();
    gain.setGainDb(-6.0);

    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    gain.effect.process(&buffer, 48000);

    // -6 dB should halve the amplitude
    try testing.expectApproxEqAbs(@as(f32, 0.5), buffer[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, -0.5), buffer[1], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.25), buffer[2], 0.01);
    try testing.expectApproxEqAbs(@as(f32, -0.25), buffer[3], 0.01);
}

test "gain: parameter count and access" {
    const gain = Gain.init();

    try testing.expectEqual(@as(usize, 2), gain.effect.vtable.getParameterCount(&gain.effect));

    const param0 = gain.effect.vtable.getParameter(&gain.effect, 0);
    try testing.expect(param0 != null);
    try testing.expectEqualStrings("Gain", param0.?.name);

    const param1 = gain.effect.vtable.getParameter(&gain.effect, 1);
    try testing.expect(param1 != null);
    try testing.expectEqualStrings("Soft Clip", param1.?.name);

    const param_invalid = gain.effect.vtable.getParameter(&gain.effect, 2);
    try testing.expect(param_invalid == null);
}
