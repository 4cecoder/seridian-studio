//! Freeverb Effect
//!
//! Stereo Freeverb based on Jezar's public domain implementation.
//! Wraps the DSP library Freeverb processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const FreeverbEffect = struct {
    effect: Effect,
    processor: dsp.Freeverb,

    // Parameters: Room Size, Damping, Width, Mix
    params: [4]Parameter = .{
        .{ .name = "Room", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Damping", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Width", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() FreeverbEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Freeverb",
            },
            .processor = dsp.Freeverb.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *FreeverbEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor = dsp.Freeverb.init(@floatFromInt(sample_rate));
            self.processor.setRoomSize(self.params[0].value);
            self.processor.setDamping(self.params[1].value);
            self.processor.setWidth(self.params[2].value);
            self.processor.setMix(self.params[3].value);
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
        const self: *FreeverbEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const FreeverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *FreeverbEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setRoomSize(self.params[0].value),
            1 => self.processor.setDamping(self.params[1].value),
            2 => self.processor.setWidth(self.params[2].value),
            3 => self.processor.setMix(self.params[3].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setRoomSize(self: *FreeverbEffect, size: f32) void {
        setParameter(&self.effect, 0, size);
    }

    pub fn setDamping(self: *FreeverbEffect, damp: f32) void {
        setParameter(&self.effect, 1, damp);
    }

    pub fn setWidth(self: *FreeverbEffect, width: f32) void {
        setParameter(&self.effect, 2, width);
    }

    pub fn setMix(self: *FreeverbEffect, mix: f32) void {
        setParameter(&self.effect, 3, mix);
    }
};

test "freeverb effect" {
    var verb = FreeverbEffect.init();
    verb.setRoomSize(0.7);
    verb.setMix(0.5);

    // Stereo buffer
    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    verb.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Should produce some output
    try testing.expect(buffer[0] != 0 or buffer[1] != 0);
}
