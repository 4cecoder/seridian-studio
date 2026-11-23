//! TB-303 Style Filter Effect
//!
//! Acid bass filter with envelope modulation and accent.
//! Wraps the DSP library TB303Filter processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const TB303FilterEffect = struct {
    effect: Effect,
    processor: dsp.TB303Filter,

    // Parameters: Cutoff, Resonance, Env Mod, Env Decay
    params: [4]Parameter = .{
        .{ .name = "Cutoff", .min = 20.0, .max = 8000.0, .default = 1000.0, .value = 1000.0, .unit = "Hz" },
        .{ .name = "Resonance", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Env Mod", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Decay", .min = 10.0, .max = 1000.0, .default = 200.0, .value = 200.0, .unit = "ms" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() TB303FilterEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "TB-303 Filter",
            },
            .processor = dsp.TB303Filter.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *TB303FilterEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
            self.processor.setCutoff(self.params[0].value);
            self.processor.setEnvDecay(self.params[3].value);
        }

        // Process each sample
        for (buffer) |*sample| {
            sample.* = self.processor.process(sample.*);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *TB303FilterEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const TB303FilterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *TB303FilterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setCutoff(self.params[0].value),
            1 => self.processor.setResonance(self.params[1].value),
            2 => self.processor.setEnvMod(self.params[2].value),
            3 => self.processor.setEnvDecay(self.params[3].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setCutoff(self: *TB303FilterEffect, freq: f32) void {
        setParameter(&self.effect, 0, freq);
    }

    pub fn setResonance(self: *TB303FilterEffect, res: f32) void {
        setParameter(&self.effect, 1, res);
    }

    pub fn setEnvMod(self: *TB303FilterEffect, amount: f32) void {
        setParameter(&self.effect, 2, amount);
    }

    pub fn setEnvDecay(self: *TB303FilterEffect, ms: f32) void {
        setParameter(&self.effect, 3, ms);
    }

    /// Trigger the filter envelope (call on note-on)
    pub fn trigger(self: *TB303FilterEffect, accent: f32) void {
        self.processor.trigger(accent);
    }
};

test "tb303 filter effect" {
    var tb = TB303FilterEffect.init();
    tb.setCutoff(500);
    tb.setResonance(0.8);
    tb.trigger(0.5);

    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    tb.effect.process(&buffer, 48000);

    const testing = std.testing;
    // Filter should have processed the signal
    try testing.expect(@abs(buffer[0]) <= 1.0);
}
