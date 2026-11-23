//! Saturator Effect
//!
//! Smooth tanh saturation for warm analog-style distortion.
//! Wraps the DSP library TanhSaturator processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const Saturator = struct {
    effect: Effect,
    processor: dsp.TanhSaturator,

    // Parameters: Drive, Mix
    params: [2]Parameter = .{
        .{ .name = "Drive", .min = 1.0, .max = 20.0, .default = 1.0, .value = 1.0, .unit = "x" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Saturator {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Saturator",
            },
            .processor = dsp.TanhSaturator.init(),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        _ = sample_rate;
        const self: *Saturator = @fieldParentPtr("effect", effect);
        self.processor.processBlock(buffer);
    }

    fn reset(effect: *Effect) void {
        _ = effect;
        // TanhSaturator has no state to reset
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Saturator = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Saturator = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        // Update processor parameters
        switch (index) {
            0 => self.processor.setDrive(self.params[0].value),
            1 => self.processor.setMix(self.params[1].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setDrive(self: *Saturator, drive: f32) void {
        setParameter(&self.effect, 0, drive);
    }

    pub fn setMix(self: *Saturator, mix: f32) void {
        setParameter(&self.effect, 1, mix);
    }
};

test "saturator effect" {
    var sat = Saturator.init();
    sat.setDrive(5.0);

    var buffer = [_]f32{ 0.5, -0.5, 1.0, -1.0 };
    sat.effect.process(&buffer, 48000);

    // High input should be limited (tanh clamps to +-1)
    const testing = std.testing;
    try testing.expect(@abs(buffer[2]) <= 1.0);
    try testing.expect(@abs(buffer[3]) <= 1.0);
    // Lower inputs should be affected by saturation
    try testing.expect(buffer[0] != 0.5);
}
