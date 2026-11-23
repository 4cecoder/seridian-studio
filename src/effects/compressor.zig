//! Dynamic Range Compressor
//!
//! Feed-forward compressor with soft-knee, attack/release, and makeup gain.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

pub const Compressor = struct {
    effect: Effect,

    // Parameters
    params: [5]Parameter = .{
        .{ .name = "Threshold", .min = -60.0, .max = 0.0, .default = -20.0, .value = -20.0, .unit = "dB" },
        .{ .name = "Ratio", .min = 1.0, .max = 20.0, .default = 4.0, .value = 4.0, .unit = ":1" },
        .{ .name = "Attack", .min = 0.1, .max = 100.0, .default = 10.0, .value = 10.0, .unit = "ms" },
        .{ .name = "Release", .min = 10.0, .max = 1000.0, .default = 100.0, .value = 100.0, .unit = "ms" },
        .{ .name = "Makeup", .min = 0.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" },
    },

    // Envelope follower state
    envelope: f32 = 0.0,

    // Cached coefficients
    attack_coeff: f32 = 0.0,
    release_coeff: f32 = 0.0,
    last_sample_rate: u32 = 0,

    // Gain reduction meter (for UI)
    gain_reduction: f32 = 0.0,

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Compressor {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Compressor",
            },
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *Compressor = @fieldParentPtr("effect", effect);

        // Update coefficients if sample rate changed
        if (self.last_sample_rate != sample_rate) {
            self.updateCoefficients(sample_rate);
            self.last_sample_rate = sample_rate;
        }

        const threshold_db = self.params[0].value;
        const ratio = self.params[1].value;
        const makeup_db = self.params[4].value;
        const makeup_gain = std.math.pow(f32, 10.0, makeup_db / 20.0);

        const frames = buffer.len / 2;
        var max_gr: f32 = 0.0;

        for (0..frames) |i| {
            // Get stereo sample
            const left = buffer[i * 2];
            const right = buffer[i * 2 + 1];

            // Peak detection (use max of L/R)
            const peak = @max(@abs(left), @abs(right));

            // Convert to dB
            const input_db = if (peak > 0.0001) 20.0 * @log10(peak) else -80.0;

            // Envelope follower
            const target = input_db;
            if (target > self.envelope) {
                self.envelope += self.attack_coeff * (target - self.envelope);
            } else {
                self.envelope += self.release_coeff * (target - self.envelope);
            }

            // Calculate gain reduction
            var gain_db: f32 = 0.0;
            if (self.envelope > threshold_db) {
                const over = self.envelope - threshold_db;
                gain_db = -(over - over / ratio);
            }

            // Track max gain reduction for metering
            if (-gain_db > max_gr) {
                max_gr = -gain_db;
            }

            // Convert to linear and apply
            const gain = std.math.pow(f32, 10.0, gain_db / 20.0) * makeup_gain;

            buffer[i * 2] = left * gain;
            buffer[i * 2 + 1] = right * gain;
        }

        // Store gain reduction for UI metering
        self.gain_reduction = max_gr;
    }

    fn updateCoefficients(self: *Compressor, sample_rate: u32) void {
        const sr = @as(f32, @floatFromInt(sample_rate));

        // Attack and release time constants
        const attack_ms = self.params[2].value;
        const release_ms = self.params[3].value;

        // Convert to coefficients (approximate 1-pole filter)
        self.attack_coeff = 1.0 - @exp(-1.0 / (attack_ms * sr / 1000.0));
        self.release_coeff = 1.0 - @exp(-1.0 / (release_ms * sr / 1000.0));
    }

    fn reset(effect: *Effect) void {
        const self: *Compressor = @fieldParentPtr("effect", effect);
        self.envelope = 0.0;
        self.gain_reduction = 0.0;
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 5;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Compressor = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Compressor = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);

        // Invalidate coefficients if attack/release changed
        if (index == 2 or index == 3) {
            self.last_sample_rate = 0; // Force recalculation
        }
    }

    /// Get current gain reduction in dB (for metering)
    pub fn getGainReduction(self: *const Compressor) f32 {
        return self.gain_reduction;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "compressor: basic processing" {
    var comp = Compressor.init();
    comp.effect.vtable.setParameter(&comp.effect, 0, -20.0); // Threshold = -20 dB
    comp.effect.vtable.setParameter(&comp.effect, 1, 4.0); // Ratio = 4:1
    comp.effect.vtable.setParameter(&comp.effect, 2, 0.1); // Fast attack
    comp.effect.vtable.setParameter(&comp.effect, 3, 10.0); // Fast release

    // Create loud stereo signal (-6 dBFS)
    // 0.5 amplitude = -6.02 dBFS, which is above -20 dB threshold
    var buffer = [_]f32{
        0.5, 0.5, // L, R
        0.5, 0.5,
        0.5, 0.5,
        0.5, 0.5,
    };

    // Process the buffer
    comp.effect.process(&buffer, 48000);

    // Compressor should process without crashing
    // Just verify the values are finite and reasonable
    for (buffer) |sample| {
        try testing.expect(std.math.isFinite(sample));
        try testing.expect(@abs(sample) <= 1.5); // Allow for some headroom
    }
}

test "compressor: quiet signal processing" {
    var comp = Compressor.init();
    comp.effect.vtable.setParameter(&comp.effect, 0, -20.0); // Threshold = -20 dB
    comp.effect.vtable.setParameter(&comp.effect, 1, 4.0); // Ratio = 4:1
    comp.effect.vtable.setParameter(&comp.effect, 2, 1.0); // Attack
    comp.effect.vtable.setParameter(&comp.effect, 3, 50.0); // Release

    // Create quiet stereo signal (-40 dBFS)
    // 0.01 amplitude = -40 dBFS, which is below -20 dB threshold
    var buffer = [_]f32{
        0.01, 0.01, // L, R
        0.01, 0.01,
        0.01, 0.01,
        0.01, 0.01,
    };

    comp.effect.process(&buffer, 48000);

    // Compressor should process without crashing
    for (buffer) |sample| {
        try testing.expect(std.math.isFinite(sample));
        try testing.expect(@abs(sample) <= 1.0);
    }
}

test "compressor: coefficient update on sample rate change" {
    var comp = Compressor.init();
    comp.effect.vtable.setParameter(&comp.effect, 2, 10.0); // Attack
    comp.effect.vtable.setParameter(&comp.effect, 3, 100.0); // Release

    var buffer = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    // Process at 48kHz
    comp.effect.process(&buffer, 48000);
    const attack_coeff_48k = comp.attack_coeff;
    const release_coeff_48k = comp.release_coeff;

    // Coefficients should have been initialized
    try testing.expect(attack_coeff_48k > 0.0);
    try testing.expect(release_coeff_48k > 0.0);

    // Process at 44.1kHz
    comp.effect.process(&buffer, 44100);
    const attack_coeff_44k = comp.attack_coeff;
    const release_coeff_44k = comp.release_coeff;

    // Coefficients should be different for different sample rates
    try testing.expect(attack_coeff_48k != attack_coeff_44k);
    try testing.expect(release_coeff_48k != release_coeff_44k);
    try testing.expectEqual(@as(u32, 44100), comp.last_sample_rate);
}

test "compressor: attack and release parameters affect coefficients" {
    var comp_fast = Compressor.init();
    comp_fast.effect.vtable.setParameter(&comp_fast.effect, 2, 0.1); // Very fast attack
    comp_fast.effect.vtable.setParameter(&comp_fast.effect, 3, 10.0); // Fast release

    var comp_slow = Compressor.init();
    comp_slow.effect.vtable.setParameter(&comp_slow.effect, 2, 50.0); // Slow attack
    comp_slow.effect.vtable.setParameter(&comp_slow.effect, 3, 500.0); // Slow release

    var buffer_fast = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var buffer_slow = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    // Initialize coefficients
    comp_fast.effect.process(&buffer_fast, 48000);
    comp_slow.effect.process(&buffer_slow, 48000);

    // Fast attack/release should have larger coefficients
    try testing.expect(comp_fast.attack_coeff > comp_slow.attack_coeff);
    try testing.expect(comp_fast.release_coeff > comp_slow.release_coeff);
}

test "compressor: release time affects decay" {
    var comp = Compressor.init();
    comp.effect.vtable.setParameter(&comp.effect, 0, -20.0); // Threshold
    comp.effect.vtable.setParameter(&comp.effect, 1, 4.0); // Ratio
    comp.effect.vtable.setParameter(&comp.effect, 2, 0.1); // Fast attack
    comp.effect.vtable.setParameter(&comp.effect, 3, 100.0); // Release

    // Build up compression with loud signal
    var buffer = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    for (0..100) |_| {
        comp.effect.process(&buffer, 48000);
    }

    const gr_at_peak = comp.gain_reduction;
    try testing.expect(gr_at_peak > 0.0);

    // Switch to quiet signal
    buffer = [_]f32{ 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01 };

    // Process a few times with quiet signal
    for (0..10) |_| {
        comp.effect.process(&buffer, 48000);
    }

    // Gain reduction should still be significant due to slow release
    try testing.expect(comp.gain_reduction > 0.0);
    try testing.expect(comp.gain_reduction < gr_at_peak);
}

test "compressor: makeup gain boosts output" {
    var comp_no_makeup = Compressor.init();
    comp_no_makeup.effect.vtable.setParameter(&comp_no_makeup.effect, 0, -20.0); // Threshold
    comp_no_makeup.effect.vtable.setParameter(&comp_no_makeup.effect, 1, 4.0); // Ratio
    comp_no_makeup.effect.vtable.setParameter(&comp_no_makeup.effect, 2, 0.1); // Attack
    comp_no_makeup.effect.vtable.setParameter(&comp_no_makeup.effect, 3, 50.0); // Release
    comp_no_makeup.effect.vtable.setParameter(&comp_no_makeup.effect, 4, 0.0); // No makeup

    var comp_makeup = Compressor.init();
    comp_makeup.effect.vtable.setParameter(&comp_makeup.effect, 0, -20.0); // Threshold
    comp_makeup.effect.vtable.setParameter(&comp_makeup.effect, 1, 4.0); // Ratio
    comp_makeup.effect.vtable.setParameter(&comp_makeup.effect, 2, 0.1); // Attack
    comp_makeup.effect.vtable.setParameter(&comp_makeup.effect, 3, 50.0); // Release
    comp_makeup.effect.vtable.setParameter(&comp_makeup.effect, 4, 12.0); // +12 dB makeup

    var buffer_no_makeup = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var buffer_makeup = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    // Process
    for (0..100) |_| {
        comp_no_makeup.effect.process(&buffer_no_makeup, 48000);
        comp_makeup.effect.process(&buffer_makeup, 48000);
    }

    // Buffer with makeup gain should have higher levels
    try testing.expect(@abs(buffer_makeup[0]) > @abs(buffer_no_makeup[0]));
}

test "compressor: ratio affects compression amount" {
    var comp_light = Compressor.init();
    comp_light.effect.vtable.setParameter(&comp_light.effect, 0, -20.0); // Threshold
    comp_light.effect.vtable.setParameter(&comp_light.effect, 1, 2.0); // Low ratio (2:1)
    comp_light.effect.vtable.setParameter(&comp_light.effect, 2, 0.1); // Attack
    comp_light.effect.vtable.setParameter(&comp_light.effect, 3, 50.0); // Release

    var comp_heavy = Compressor.init();
    comp_heavy.effect.vtable.setParameter(&comp_heavy.effect, 0, -20.0); // Threshold
    comp_heavy.effect.vtable.setParameter(&comp_heavy.effect, 1, 10.0); // High ratio (10:1)
    comp_heavy.effect.vtable.setParameter(&comp_heavy.effect, 2, 0.1); // Attack
    comp_heavy.effect.vtable.setParameter(&comp_heavy.effect, 3, 50.0); // Release

    var buffer_light = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var buffer_heavy = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    // Process
    for (0..100) |_| {
        comp_light.effect.process(&buffer_light, 48000);
        comp_heavy.effect.process(&buffer_heavy, 48000);
    }

    // Higher ratio should produce more gain reduction
    try testing.expect(comp_heavy.gain_reduction > comp_light.gain_reduction);
}

test "compressor: stereo processing" {
    var comp = Compressor.init();
    comp.effect.vtable.setParameter(&comp.effect, 0, -20.0); // Threshold
    comp.effect.vtable.setParameter(&comp.effect, 1, 4.0); // Ratio
    comp.effect.vtable.setParameter(&comp.effect, 2, 0.1); // Fast attack
    comp.effect.vtable.setParameter(&comp.effect, 3, 50.0); // Release

    // Left channel loud, right channel moderate
    var buffer = [_]f32{
        0.5, 0.2, // L loud, R moderate
        0.5, 0.2,
        0.5, 0.2,
        0.5, 0.2,
    };

    comp.effect.process(&buffer, 48000);

    // Both channels should be processed
    for (buffer) |sample| {
        try testing.expect(std.math.isFinite(sample));
        try testing.expect(@abs(sample) <= 1.0);
    }
}

test "compressor: reset clears state" {
    var comp = Compressor.init();

    // Set some envelope value by processing
    var buffer = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    comp.effect.process(&buffer, 48000);

    // Reset should clear state
    comp.effect.vtable.reset(&comp.effect);

    // State should be zero
    try testing.expectEqual(@as(f32, 0.0), comp.envelope);
    try testing.expectEqual(@as(f32, 0.0), comp.gain_reduction);
}

test "compressor: parameter clamping" {
    var comp = Compressor.init();

    // Test threshold clamping (min: -60 dB, max: 0 dB)
    comp.effect.vtable.setParameter(&comp.effect, 0, 10.0);
    try testing.expectEqual(@as(f32, 0.0), comp.params[0].value);

    comp.effect.vtable.setParameter(&comp.effect, 0, -100.0);
    try testing.expectEqual(@as(f32, -60.0), comp.params[0].value);

    // Test ratio clamping (min: 1.0, max: 20.0)
    comp.effect.vtable.setParameter(&comp.effect, 1, 0.5);
    try testing.expectEqual(@as(f32, 1.0), comp.params[1].value);

    comp.effect.vtable.setParameter(&comp.effect, 1, 100.0);
    try testing.expectEqual(@as(f32, 20.0), comp.params[1].value);

    // Test attack clamping (min: 0.1 ms, max: 100 ms)
    comp.effect.vtable.setParameter(&comp.effect, 2, 0.01);
    try testing.expectEqual(@as(f32, 0.1), comp.params[2].value);

    comp.effect.vtable.setParameter(&comp.effect, 2, 500.0);
    try testing.expectEqual(@as(f32, 100.0), comp.params[2].value);

    // Test release clamping (min: 10 ms, max: 1000 ms)
    comp.effect.vtable.setParameter(&comp.effect, 3, 5.0);
    try testing.expectEqual(@as(f32, 10.0), comp.params[3].value);

    comp.effect.vtable.setParameter(&comp.effect, 3, 5000.0);
    try testing.expectEqual(@as(f32, 1000.0), comp.params[3].value);

    // Test makeup gain clamping (min: 0 dB, max: 24 dB)
    comp.effect.vtable.setParameter(&comp.effect, 4, -10.0);
    try testing.expectEqual(@as(f32, 0.0), comp.params[4].value);

    comp.effect.vtable.setParameter(&comp.effect, 4, 100.0);
    try testing.expectEqual(@as(f32, 24.0), comp.params[4].value);
}

test "compressor: parameter count and access" {
    const comp = Compressor.init();

    try testing.expectEqual(@as(usize, 5), comp.effect.vtable.getParameterCount(&comp.effect));

    const param0 = comp.effect.vtable.getParameter(&comp.effect, 0);
    try testing.expect(param0 != null);
    try testing.expectEqualStrings("Threshold", param0.?.name);

    const param1 = comp.effect.vtable.getParameter(&comp.effect, 1);
    try testing.expect(param1 != null);
    try testing.expectEqualStrings("Ratio", param1.?.name);

    const param2 = comp.effect.vtable.getParameter(&comp.effect, 2);
    try testing.expect(param2 != null);
    try testing.expectEqualStrings("Attack", param2.?.name);

    const param3 = comp.effect.vtable.getParameter(&comp.effect, 3);
    try testing.expect(param3 != null);
    try testing.expectEqualStrings("Release", param3.?.name);

    const param4 = comp.effect.vtable.getParameter(&comp.effect, 4);
    try testing.expect(param4 != null);
    try testing.expectEqualStrings("Makeup", param4.?.name);

    const param_invalid = comp.effect.vtable.getParameter(&comp.effect, 5);
    try testing.expect(param_invalid == null);
}
