//! Auto Pan Effect
//!
//! LFO-controlled automatic panning effect.
//! Wraps the DSP library AutoPan processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const AutoPanEffect = struct {
    effect: Effect,
    processor: dsp.AutoPan,

    // Parameters: Rate, Depth
    params: [2]Parameter = .{
        .{ .name = "Rate", .min = 0.1, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "Hz" },
        .{ .name = "Depth", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() AutoPanEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Auto Pan",
            },
            .processor = dsp.AutoPan.init(48000),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *AutoPanEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor = dsp.AutoPan.init(@floatFromInt(sample_rate));
            self.processor.setRate(self.params[0].value);
            self.processor.setDepth(self.params[1].value);
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
        const self: *AutoPanEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const AutoPanEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *AutoPanEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setRate(self.params[0].value),
            1 => self.processor.setDepth(self.params[1].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setRate(self: *AutoPanEffect, rate: f32) void {
        setParameter(&self.effect, 0, rate);
    }

    pub fn setDepth(self: *AutoPanEffect, depth: f32) void {
        setParameter(&self.effect, 1, depth);
    }
};

test "auto pan effect" {
    var pan = AutoPanEffect.init();
    pan.setRate(2.0);
    pan.setDepth(1.0);

    // Process enough samples to see panning movement
    var buffer: [256]f32 = undefined;
    for (&buffer, 0..) |*s, i| {
        s.* = if (i % 2 == 0) 1.0 else 1.0; // Mono input
    }

    pan.effect.process(&buffer, 48000);

    const testing = std.testing;
    // With full depth, L and R should differ at some point
    var has_difference = false;
    var i: usize = 0;
    while (i + 1 < buffer.len) : (i += 2) {
        if (@abs(buffer[i] - buffer[i + 1]) > 0.01) {
            has_difference = true;
            break;
        }
    }
    try testing.expect(has_difference);
}
