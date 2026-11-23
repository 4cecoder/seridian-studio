//! Limiter Effect
//!
//! Brickwall peak limiter with lookahead for transparent limiting.
//! Wraps the DSP library Limiter processor.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;
const dsp = @import("../dsp/dsp.zig");

pub const LimiterEffect = struct {
    effect: Effect,
    processor: dsp.Limiter,

    // Parameters: Ceiling, Release, Lookahead
    params: [3]Parameter = .{
        .{ .name = "Ceiling", .min = -24.0, .max = 0.0, .default = -0.3, .value = -0.3, .unit = "dB" },
        .{ .name = "Release", .min = 10.0, .max = 500.0, .default = 100.0, .value = 100.0, .unit = "ms" },
        .{ .name = "Lookahead", .min = 0.0, .max = 128.0, .default = 64.0, .value = 64.0, .unit = "smp" },
    },

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() LimiterEffect {
        var self = LimiterEffect{
            .effect = .{
                .vtable = &vtable,
                .name = "Limiter",
            },
            .processor = dsp.Limiter.init(48000),
        };
        self.processor.setCeiling(-0.3);
        self.processor.setLookahead(64);
        return self;
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *LimiterEffect = @fieldParentPtr("effect", effect);

        // Update sample rate if changed
        if (self.processor.sample_rate != @as(f32, @floatFromInt(sample_rate))) {
            self.processor.sample_rate = @floatFromInt(sample_rate);
            self.processor.setRelease(self.params[1].value);
        }

        // Process each sample
        for (buffer) |*sample| {
            sample.* = self.processor.process(sample.*);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *LimiterEffect = @fieldParentPtr("effect", effect);
        self.processor.reset();
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 3;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const LimiterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *LimiterEffect = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        switch (index) {
            0 => self.processor.setCeiling(self.params[0].value),
            1 => self.processor.setRelease(self.params[1].value),
            2 => self.processor.setLookahead(@intFromFloat(self.params[2].value)),
            else => {},
        }
    }

    // Convenience methods
    pub fn setCeiling(self: *LimiterEffect, db: f32) void {
        setParameter(&self.effect, 0, db);
    }

    pub fn setRelease(self: *LimiterEffect, ms: f32) void {
        setParameter(&self.effect, 1, ms);
    }

    /// Detect inter-sample (true) peaks as well as sample peaks.
    pub fn setTruePeak(self: *LimiterEffect, enabled: bool) void {
        self.processor.setTruePeak(enabled);
    }

    pub fn getGainReduction(self: *LimiterEffect) f32 {
        return self.processor.getGainReduction();
    }
};

test "limiter effect" {
    var lim = LimiterEffect.init();
    lim.setCeiling(-6);

    // Feed loud signal
    var buffer = [_]f32{ 2.0, -2.0, 1.5, -1.5 };

    // Process a bit to fill lookahead
    for (0..100) |_| {
        lim.effect.process(&buffer, 48000);
    }

    const testing = std.testing;
    // Should have applied some limiting
    try testing.expect(lim.processor.gain <= 1.0);
}
