//! Bitcrusher Effect
//!
//! Lo-fi bit depth and sample rate reduction effect.
//! Wraps the DSP library Bitcrusher processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const Bitcrusher = struct {
    effect: Effect,
    processor: dsp.Bitcrusher,

    // Parameters: Bit Depth, Rate Reduction, Dither, Mix
    params: [4]Parameter = .{
        .{ .name = "Bit Depth", .min = 1.0, .max = 16.0, .default = 8.0, .value = 8.0, .unit = "bits" },
        .{ .name = "Rate", .min = 0.01, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Dither", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Bitcrusher {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Bitcrusher",
            },
            .processor = dsp.Bitcrusher.init(),
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        _ = sample_rate;
        const self: *Bitcrusher = @fieldParentPtr("effect", effect);
        self.processor.processBlock(buffer);
    }

    fn reset(effect: *Effect) void {
        const self: *Bitcrusher = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Bitcrusher = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Bitcrusher = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        // Update processor parameters
        switch (index) {
            0 => self.processor.setBitDepth(@intFromFloat(self.params[0].value)),
            1 => self.processor.setRateReduction(self.params[1].value),
            2 => self.processor.setDither(self.params[2].value),
            3 => self.processor.setMix(self.params[3].value),
            else => {},
        }
    }

    // Convenience methods
    pub fn setBitDepth(self: *Bitcrusher, bits: u8) void {
        setParameter(&self.effect, 0, @floatFromInt(bits));
    }

    pub fn setRateReduction(self: *Bitcrusher, rate: f32) void {
        setParameter(&self.effect, 1, rate);
    }

    pub fn setDither(self: *Bitcrusher, amount: f32) void {
        setParameter(&self.effect, 2, amount);
    }

    pub fn setMix(self: *Bitcrusher, mix: f32) void {
        setParameter(&self.effect, 3, mix);
    }
};

test "bitcrusher effect" {
    var bc = Bitcrusher.init();
    bc.setBitDepth(4);

    var buffer = [_]f32{ 0.123, -0.456, 0.789, -0.321 };
    bc.effect.process(&buffer, 48000);

    // Values should be quantized
    const testing = std.testing;
    try testing.expect(@abs(buffer[0] - 0.123) > 0.01);
}
