//! Stereo Width Effect
//!
//! M/S based stereo width control.
//! Wraps the DSP library StereoWidth processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const StereoWidthEffect = struct {
    effect: Effect,
    processor: dsp.StereoWidth,

    // Parameters: Width
    params: [1]Parameter = .{
        .{ .name = "Width", .min = 0.0, .max = 2.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() StereoWidthEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Stereo Width",
            },
            .processor = dsp.StereoWidth.init(),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *StereoWidthEffect = @fieldParentPtr("effect", effect);
        _ = sample_rate;

        // Process stereo pairs
        var i: usize = 0;
        while (i + 1 < buffer.len) : (i += 2) {
            const result = self.processor.process(buffer[i], buffer[i + 1]);
            buffer[i] = result.left;
            buffer[i + 1] = result.right;
        }
    }

    fn reset(effect: *Effect) void {
        _ = effect;
        // StereoWidth has no state to reset
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 1;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const StereoWidthEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *StereoWidthEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setWidth(self.params[0].value),
            else => {},
        }
    }

    // Convenience method
    pub fn setWidth(self: *StereoWidthEffect, width: f32) void {
        setParameter(&self.effect, 0, width);
    }
};

test "stereo width effect" {
    var width_fx = StereoWidthEffect.init();
    width_fx.setWidth(0.0); // Mono

    // Stereo buffer with opposite signals
    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    width_fx.effect.process(&buffer, 48000);

    const testing = std.testing;
    // At width=0 (mono), L and R should be equal
    try testing.expectApproxEqAbs(buffer[0], buffer[1], 0.001);
}
