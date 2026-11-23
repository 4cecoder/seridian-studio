//! Moog Ladder Filter Effect
//!
//! Classic 4-pole ladder filter with resonance and self-oscillation.
//! Wraps the DSP library MoogLadder processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const MoogFilter = struct {
    effect: Effect,
    processor: dsp.MoogLadder,

    // Parameters: Cutoff, Resonance
    params: [2]Parameter = .{
        .{ .name = "Cutoff", .min = 20.0, .max = 20000.0, .default = 1000.0, .value = 1000.0, .unit = "Hz" },
        .{ .name = "Resonance", .min = 0.0, .max = 1.25, .default = 0.0, .value = 0.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() MoogFilter {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Moog Filter",
            },
            .processor = dsp.MoogLadder.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *MoogFilter = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
            self.processor.setCutoff(self.params[0].value);
        }

        self.processor.processBlock(buffer);
    }

    fn reset(effect: *Effect) void {
        const self: *MoogFilter = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const MoogFilter = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *MoogFilter = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setCutoff(self.params[0].value),
            1 => self.processor.setResonance(self.params[1].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setCutoff(self: *MoogFilter, freq: f32) void {
        setParameter(&self.effect, 0, freq);
    }

    pub fn setResonance(self: *MoogFilter, res: f32) void {
        setParameter(&self.effect, 1, res);
    }
};

test "moog filter effect" {
    var moog = MoogFilter.init();
    moog.setCutoff(500);
    moog.setResonance(0.8);

    var buffer = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    moog.effect.process(&buffer, 48000);

    // Filter should have smoothed the signal
    const testing = std.testing;
    try testing.expect(@abs(buffer[0]) < 1.0);
}
