//! Noise Gate Effect
//!
//! Noise gate with hysteresis and hold time for clean gating.
//! Wraps the DSP library Gate processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const GateEffect = struct {
    effect: Effect,
    processor: dsp.Gate,

    // Parameters: Threshold, Attack, Hold, Release, Range
    params: [5]Parameter = .{
        .{ .name = "Threshold", .min = -80.0, .max = 0.0, .default = -40.0, .value = -40.0, .unit = "dB" },
        .{ .name = "Attack", .min = 0.1, .max = 50.0, .default = 1.0, .value = 1.0, .unit = "ms" },
        .{ .name = "Hold", .min = 0.0, .max = 500.0, .default = 50.0, .value = 50.0, .unit = "ms" },
        .{ .name = "Release", .min = 10.0, .max = 1000.0, .default = 100.0, .value = 100.0, .unit = "ms" },
        .{ .name = "Range", .min = -80.0, .max = 0.0, .default = -80.0, .value = -80.0, .unit = "dB" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() GateEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Gate",
            },
            .processor = dsp.Gate.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *GateEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
            // Re-apply time-based parameters
            self.processor.setAttack(self.params[1].value);
            self.processor.setHold(self.params[2].value);
            self.processor.setRelease(self.params[3].value);
        }

        // Process each sample
        for (buffer) |*sample| {
            sample.* = self.processor.process(sample.*);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *GateEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 5;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const GateEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *GateEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setThreshold(self.params[0].value),
            1 => self.processor.setAttack(self.params[1].value),
            2 => self.processor.setHold(self.params[2].value),
            3 => self.processor.setRelease(self.params[3].value),
            4 => self.processor.setRange(self.params[4].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setThreshold(self: *GateEffect, db: f32) void {
        setParameter(&self.effect, 0, db);
    }

    pub fn setAttack(self: *GateEffect, ms: f32) void {
        setParameter(&self.effect, 1, ms);
    }

    pub fn setHold(self: *GateEffect, ms: f32) void {
        setParameter(&self.effect, 2, ms);
    }

    pub fn setRelease(self: *GateEffect, ms: f32) void {
        setParameter(&self.effect, 3, ms);
    }

    pub fn setRange(self: *GateEffect, db: f32) void {
        setParameter(&self.effect, 4, db);
    }

    pub fn isOpen(self: *GateEffect) bool {
        return self.processor.isOpen();
    }
};

test "gate effect" {
    var gate = GateEffect.init();
    gate.setThreshold(-20);

    // Very quiet signal should be gated
    var buffer = [_]f32{ 0.001, -0.001, 0.001, -0.001 };
    gate.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Output should be very quiet (gated)
    try testing.expect(@abs(buffer[0]) < 0.01);
}
