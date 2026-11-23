//! Formant Filter Effect
//!
//! Vowel synthesis filter with morphing between vowel sounds.
//! Wraps the DSP library FormantFilter processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const FormantFilterEffect = struct {
    effect: Effect,
    processor: dsp.FormantFilter,

    // Parameters: Vowel (0-4 = A/E/I/O/U), Morph Speed
    params: [2]Parameter = .{
        .{ .name = "Vowel", .min = 0.0, .max = 4.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Morph", .min = 0.001, .max = 0.1, .default = 0.01, .value = 0.01, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() FormantFilterEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Formant Filter",
            },
            .processor = dsp.FormantFilter.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *FormantFilterEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
        }

        self.processor.processBlock(buffer);
    }

    fn reset(effect: *Effect) void {
        const self: *FormantFilterEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const FormantFilterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *FormantFilterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => {
                // Map 0-4 to vowels A/E/I/O/U
                const vowel_idx: u8 = @intFromFloat(self.params[0].value);
                const target = switch (vowel_idx) {
                    0 => dsp.Vowels.A,
                    1 => dsp.Vowels.E,
                    2 => dsp.Vowels.I,
                    3 => dsp.Vowels.O,
                    else => dsp.Vowels.U,
                };
                self.processor.morphTo(target, self.params[1].value);
            },
            1 => self.processor.morph_speed = self.params[1].value,
            else => {},
        }
    }

    // Convenience methods
    pub fn setVowel(self: *FormantFilterEffect, vowel: u8) void {
        setParameter(&self.effect, 0, @floatFromInt(vowel));
    }

    pub fn setMorphSpeed(self: *FormantFilterEffect, speed: f32) void {
        setParameter(&self.effect, 1, speed);
    }
};

test "formant filter effect" {
    var formant = FormantFilterEffect.init();
    formant.setVowel(0); // A

    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    formant.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Filter should process without crashing
    try testing.expect(buffer[0] != 1.0 or buffer[1] != -1.0);
}
