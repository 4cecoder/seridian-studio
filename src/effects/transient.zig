//! Transient Shaper Effect
//!
//! Transient designer for attack and sustain control.
//! Wraps the DSP library TransientShaper processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const TransientEffect = struct {
    effect: Effect,
    processor: dsp.TransientShaper,

    // Parameters: Attack, Sustain
    params: [2]Parameter = .{
        .{ .name = "Attack", .min = -24.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" },
        .{ .name = "Sustain", .min = -24.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() TransientEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Transient",
            },
            .processor = dsp.TransientShaper.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *TransientEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
            // Re-init envelope followers with new sample rate
            self.processor.fast_env = dsp.EnvelopeFollower.init(@floatFromInt(sample_rate));
            self.processor.slow_env = dsp.EnvelopeFollower.init(@floatFromInt(sample_rate));
            self.processor.fast_env.setAttack(0.1);
            self.processor.fast_env.setRelease(20);
            self.processor.slow_env.setAttack(20);
            self.processor.slow_env.setRelease(200);
        }

        // Process each sample
        for (buffer) |*sample| {
            sample.* = self.processor.process(sample.*);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *TransientEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const TransientEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *TransientEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setAttack(self.params[0].value),
            1 => self.processor.setSustain(self.params[1].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setAttackGain(self: *TransientEffect, db: f32) void {
        setParameter(&self.effect, 0, db);
    }

    pub fn setSustainGain(self: *TransientEffect, db: f32) void {
        setParameter(&self.effect, 1, db);
    }
};

test "transient shaper effect" {
    var trans = TransientEffect.init();
    trans.setAttackGain(6);
    trans.setSustainGain(-6);

    var buffer = [_]f32{ 0.5, 0.4, 0.3, 0.2 };
    trans.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Should process without crashing
    try testing.expect(buffer[0] != 0 or buffer[1] != 0);
}
