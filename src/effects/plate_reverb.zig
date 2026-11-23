//! Plate Reverb Effect
//!
//! Dense, metallic plate reverb based on Dattorro design.
//! Wraps the DSP library PlateReverb processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const PlateReverbEffect = struct {
    effect: Effect,
    processor: dsp.PlateReverb,

    // Parameters: Decay, Damping, Mix
    params: [3]Parameter = .{
        .{ .name = "Decay", .min = 0.0, .max = 0.99, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Damping", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() PlateReverbEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Plate Reverb",
            },
            .processor = dsp.PlateReverb.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *PlateReverbEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor = dsp.PlateReverb.init(@floatFromInt(sample_rate));
            self.processor.setDecay(self.params[0].value);
            self.processor.setDamping(self.params[1].value);
            self.processor.setMix(self.params[2].value);
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
        const self: *PlateReverbEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 3;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const PlateReverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *PlateReverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setDecay(self.params[0].value),
            1 => self.processor.setDamping(self.params[1].value),
            2 => self.processor.setMix(self.params[2].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setDecay(self: *PlateReverbEffect, decay: f32) void {
        setParameter(&self.effect, 0, decay);
    }

    pub fn setDamping(self: *PlateReverbEffect, damp: f32) void {
        setParameter(&self.effect, 1, damp);
    }

    pub fn setMix(self: *PlateReverbEffect, mix: f32) void {
        setParameter(&self.effect, 2, mix);
    }
};

test "plate reverb effect" {
    var plate = PlateReverbEffect.init();
    plate.setDecay(0.8);
    plate.setMix(0.5);

    // Stereo buffer
    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    plate.effect.process(&buffer, 48000);

    const testing = std.testing;
    try testing.expect(buffer[0] != 0 or buffer[1] != 0);
}
