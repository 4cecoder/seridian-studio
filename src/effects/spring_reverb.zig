//! Spring Reverb Effect
//!
//! Spring reverb emulation with characteristic chirp and drip.
//! Wraps the DSP library SpringReverb processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const SpringReverbEffect = struct {
    effect: Effect,
    processor: dsp.SpringReverb,

    // Parameters: Tension, Mix
    params: [2]Parameter = .{
        .{ .name = "Tension", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() SpringReverbEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Spring Reverb",
            },
            .processor = dsp.SpringReverb.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *SpringReverbEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor = dsp.SpringReverb.init(@floatFromInt(sample_rate));
            self.processor.setTension(self.params[0].value);
            self.processor.setMix(self.params[1].value);
        }

        // Process mono (spring reverb is typically mono)
        for (buffer) |*sample| {
            sample.* = self.processor.process(sample.*);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *SpringReverbEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const SpringReverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *SpringReverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setTension(self.params[0].value),
            1 => self.processor.setMix(self.params[1].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setTension(self: *SpringReverbEffect, tension: f32) void {
        setParameter(&self.effect, 0, tension);
    }

    pub fn setMix(self: *SpringReverbEffect, mix: f32) void {
        setParameter(&self.effect, 1, mix);
    }
};

test "spring reverb effect" {
    var spring = SpringReverbEffect.init();
    spring.setTension(0.7);
    spring.setMix(0.5);

    var buffer = [_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    spring.effect.process(&buffer, 48000);

    const testing = std.testing;
    try testing.expect(buffer[0] != 0);
}
