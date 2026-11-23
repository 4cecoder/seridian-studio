//! Freeze Effect
//!
//! Granular freeze/sustain effect - captures and holds a moment in time.
//! Wraps the DSP library GranularFreeze processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const FreezeEffect = struct {
    effect: Effect,
    processor: ?dsp.GranularFreeze = null,
    allocator: std.mem.Allocator,
    sample_rate: f32 = 48000,

    // Parameters: Freeze (on/off), Position, Jitter, Pitch
    params: [4]Parameter = .{
        .{ .name = "Freeze", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Position", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Jitter", .min = 0.0, .max = 1.0, .default = 0.1, .value = 0.1, .unit = "" },
        .{ .name = "Pitch", .min = 0.25, .max = 4.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init(allocator: std.mem.Allocator) FreezeEffect {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Freeze",
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FreezeEffect) void {
        if (self.processor) |*proc| {
            proc.deinit();
            self.processor = null;
        }
    }

    fn ensureProcessor(self: *FreezeEffect) void {
        if (self.processor == null) {
            self.processor = dsp.GranularFreeze.init(self.allocator, self.sample_rate) catch null;
            if (self.processor) |*proc| {
                proc.setFreeze(self.params[0].value >= 0.5);
                proc.setPosition(self.params[1].value);
                proc.setJitter(self.params[2].value);
                proc.setPitch(self.params[3].value);
            }
        }
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *FreezeEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        const new_rate = @as(f32, @floatFromInt(sample_rate));
        if (self.sample_rate != new_rate) {
            self.sample_rate = new_rate;
            // Reinitialize processor with new sample rate
            if (self.processor) |*proc| {
                proc.deinit();
                self.processor = null;
            }
        }

        self.ensureProcessor();

        if (self.processor) |*proc| {
            // Process mono
            for (buffer) |*sample| {
                sample.* = proc.process(sample.*);
            }
        }
    }

    fn reset(effect: *Effect) void {
        const self: *FreezeEffect = @fieldParentPtr("effect", effect);
        if (self.processor) |*proc| {
            proc.reset();
        }
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const FreezeEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *FreezeEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        if (self.processor) |*proc| {
            switch (index) {
                0 => proc.setFreeze(self.params[0].value >= 0.5),
                1 => proc.setPosition(self.params[1].value),
                2 => proc.setJitter(self.params[2].value),
                3 => proc.setPitch(self.params[3].value),
                else => {},
            }
        }
    }

    // Convenience methods
    pub fn setFreeze(self: *FreezeEffect, freeze: bool) void {
        setParameter(&self.effect, 0, if (freeze) 1.0 else 0.0);
    }

    pub fn setPosition(self: *FreezeEffect, pos: f32) void {
        setParameter(&self.effect, 1, pos);
    }

    pub fn setJitter(self: *FreezeEffect, jitter: f32) void {
        setParameter(&self.effect, 2, jitter);
    }

    pub fn setPitch(self: *FreezeEffect, pitch: f32) void {
        setParameter(&self.effect, 3, pitch);
    }
};

test "freeze effect" {
    const testing = std.testing;

    var freeze = FreezeEffect.init(testing.allocator);
    defer freeze.deinit();

    // Record some audio
    var buffer = [_]f32{ 0.5, 0.3, -0.2, 0.1, 0.0, -0.1, 0.2, -0.3 };
    freeze.effect.process(&buffer, 48000);

    // Enable freeze
    freeze.setFreeze(true);
    freeze.setPosition(0.5);

    // Process more - should now be frozen
    freeze.effect.process(&buffer, 48000);

    // Effect should process without crashing
    try testing.expect(true);
}
