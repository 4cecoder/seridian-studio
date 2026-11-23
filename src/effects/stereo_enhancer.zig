//! Stereo Enhancer Effect
//!
//! Haas effect based stereo enhancement with bass mono-ification.
//! Wraps the DSP library StereoEnhancer processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const StereoEnhancerEffect = struct {
    effect: Effect,
    processor: dsp.StereoEnhancer,

    // Parameters: Width, Delay, Bass Mono
    params: [3]Parameter = .{
        .{ .name = "Width", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Delay", .min = 1.0, .max = 30.0, .default = 15.0, .value = 15.0, .unit = "ms" },
        .{ .name = "Bass Mono", .min = 0.0, .max = 300.0, .default = 0.0, .value = 0.0, .unit = "Hz" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() StereoEnhancerEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Stereo Enhancer",
            },
            .processor = dsp.StereoEnhancer.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *StereoEnhancerEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor = dsp.StereoEnhancer.init(@floatFromInt(sample_rate));
            self.processor.setWidth(self.params[0].value);
            self.processor.setDelayMs(self.params[1].value);
            self.processor.setBassMono(self.params[2].value);
        }

        // Process stereo pairs
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const result = self.processor.process(buffer[i], buffer[i + 1]);
            buffer[i] = result.left;
            buffer[i + 1] = result.right;
        }
    }

    fn reset(effect: *Effect) void {
        const self: *StereoEnhancerEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 3;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const StereoEnhancerEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *StereoEnhancerEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setWidth(self.params[0].value),
            1 => self.processor.setDelayMs(self.params[1].value),
            2 => self.processor.setBassMono(self.params[2].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setWidth(self: *StereoEnhancerEffect, width: f32) void {
        setParameter(&self.effect, 0, width);
    }

    pub fn setDelayMs(self: *StereoEnhancerEffect, ms: f32) void {
        setParameter(&self.effect, 1, ms);
    }

    pub fn setBassMono(self: *StereoEnhancerEffect, freq: f32) void {
        setParameter(&self.effect, 2, freq);
    }
};

test "stereo enhancer effect" {
    var enhancer = StereoEnhancerEffect.init();
    enhancer.setWidth(0.8);
    enhancer.setBassMono(100);

    // Stereo buffer
    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    enhancer.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Should produce some output
    try testing.expect(buffer[0] != 0 or buffer[1] != 0);
}
