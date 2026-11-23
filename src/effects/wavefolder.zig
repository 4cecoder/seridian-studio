//! Wavefolder Effect
//!
//! West Coast style wavefolder for complex harmonic generation.
//! Wraps the DSP library Wavefolder processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const Wavefolder = struct {
    effect: Effect,
    processor: dsp.Wavefolder,

    // Parameters: Threshold, Drive, Stages, Symmetry
    params: [4]Parameter = .{
        .{ .name = "Threshold", .min = 0.1, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Drive", .min = 1.0, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "x" },
        .{ .name = "Stages", .min = 1.0, .max = 8.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Symmetry", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Wavefolder {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Wavefolder",
            },
            .processor = dsp.Wavefolder.init(),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        _ = sample_rate;
        const self: *Wavefolder = @fieldParentPtr("effect", effect);
        self.processor.processBlock(buffer);
    }

    fn reset(effect: *Effect) void {
        _ = effect;
        // Wavefolder has no state to reset
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Wavefolder = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Wavefolder = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        // Update processor parameters
        switch (index) {
            0 => self.processor.setThreshold(self.params[0].value),
            1 => self.processor.setGain(self.params[1].value),
            2 => self.processor.setStages(@intFromFloat(self.params[2].value)),
            3 => self.processor.setSymmetry(self.params[3].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setThreshold(self: *Wavefolder, threshold: f32) void {
        setParameter(&self.effect, 0, threshold);
    }

    pub fn setDrive(self: *Wavefolder, drive: f32) void {
        setParameter(&self.effect, 1, drive);
    }

    pub fn setStages(self: *Wavefolder, stages: u8) void {
        setParameter(&self.effect, 2, @floatFromInt(stages));
    }

    pub fn setSymmetry(self: *Wavefolder, symmetry: f32) void {
        setParameter(&self.effect, 3, symmetry);
    }
};

test "wavefolder effect" {
    var wf = Wavefolder.init();
    wf.setDrive(3.0);
    wf.setThreshold(0.3);

    var buffer = [_]f32{ 0.5, -0.5, 0.8, -0.8 };
    wf.effect.process(&buffer, 48000);

    // Should have processed without crashing
    const testing = std.testing;
    try testing.expect(buffer[0] != 0.5 or buffer[1] != -0.5);
}
