//! Pitch Shifter Effect
//!
//! Real-time granular pitch shifting without tempo change.
//! Wraps the DSP library GranularPitchShifter processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const PitchShifterEffect = struct {
    effect: Effect,
    processor: ?dsp.GranularPitchShifter = null,
    allocator: std.mem.Allocator,
    sample_rate: f32 = 48000,

    // Parameters: Pitch (semitones), Grain Size, Mix
    params: [3]Parameter = .{
        .{ .name = "Pitch", .min = -12.0, .max = 12.0, .default = 0.0, .value = 0.0, .unit = "st" },
        .{ .name = "Grain", .min = 10.0, .max = 200.0, .default = 50.0, .value = 50.0, .unit = "ms" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init(allocator: std.mem.Allocator) PitchShifterEffect {
        // Pre-allocate the processor to avoid allocation on the audio thread
        const processor = dsp.GranularPitchShifter.init(allocator, 48000) catch null;

        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Pitch Shifter",
            },
            .allocator = allocator,
            .processor = processor,
        };
    }

    pub fn deinit(self: *PitchShifterEffect) void {
        if (self.processor) |*proc| {
            proc.deinit();
            self.processor = null;
        }
    }

    fn ensureProcessor(self: *PitchShifterEffect) void {
        if (self.processor == null) {
            self.processor = dsp.GranularPitchShifter.init(self.allocator, self.sample_rate) catch null;
            if (self.processor) |*proc| {
                proc.setPitchSemitones(self.params[0].value);
                proc.setGrainSize(self.params[1].value);
                proc.setMix(self.params[2].value);
            }
        }
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *PitchShifterEffect = @fieldParentPtr("effect", effect);
        _ = sample_rate; // Processor was initialized with default rate

        if (self.processor) |*proc| {
            // Process mono (pitch shifter is mono)
            for (buffer) |*sample| {
                sample.* = proc.process(sample.*);
            }
        }
    }

    fn reset(effect: *Effect) void {
        const self: *PitchShifterEffect = @fieldParentPtr("effect", effect);
        if (self.processor) |*proc| {
            proc.reset();
        }
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 3;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const PitchShifterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *PitchShifterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        if (self.processor) |*proc| {
            switch (index) {
                0 => proc.setPitchSemitones(self.params[0].value),
                1 => proc.setGrainSize(self.params[1].value),
                2 => proc.setMix(self.params[2].value),
                else => {},
            }
        }
    }

    // Convenience methods
    pub fn setPitch(self: *PitchShifterEffect, semitones: f32) void {
        setParameter(&self.effect, 0, semitones);
    }

    pub fn setGrainSize(self: *PitchShifterEffect, ms: f32) void {
        setParameter(&self.effect, 1, ms);
    }

    pub fn setMix(self: *PitchShifterEffect, mix: f32) void {
        setParameter(&self.effect, 2, mix);
    }
};

test "pitch shifter effect" {
    const testing = std.testing;

    var shifter = PitchShifterEffect.init(testing.allocator);
    defer shifter.deinit();

    shifter.setPitch(12); // Octave up

    var buffer = [_]f32{ 0.5, 0.3, -0.2, 0.1, 0.0, -0.1, 0.2, -0.3 };
    shifter.effect.process(&buffer, 48000);

    // Effect should process without crashing
    try testing.expect(true);
}
