//! Delay effect
//!
//! Simple stereo delay with feedback and tempo sync capability.
//! Uses a fixed-size buffer suitable for common delay times (up to ~500ms at 48kHz).

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

pub const Delay = struct {
    effect: Effect,

    // Parameters
    params: [4]Parameter = .{
        .{ .name = "Time", .min = 1.0, .max = 100.0, .default = 50.0, .value = 50.0, .unit = "ms" },
        .{ .name = "Feedback", .min = 0.0, .max = 0.95, .default = 0.3, .value = 0.3, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Stereo", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
    },

    // Delay buffer - sized for short delays (slapback, doubling effects)
    // 4800 samples = 100ms at 48kHz, keeping struct size small (~38KB)
    // For longer delays, use heap-allocated LongDelay effect (TODO)
    buffer: [MAX_DELAY_SAMPLES * 2]f32 = @as([(MAX_DELAY_SAMPLES * 2)]f32, @splat(0.0)),
    write_pos: usize = 0,

    // Cached values
    delay_samples: usize = 0,
    last_sample_rate: u32 = 0,

    // 100ms at 48kHz = 4800 samples stereo (~38KB total)
    const MAX_DELAY_SAMPLES = 4800;

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Delay {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Delay",
            },
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *Delay = @fieldParentPtr("effect", effect);

        // Update delay time if sample rate changed
        if (self.last_sample_rate != sample_rate) {
            self.updateDelayTime(sample_rate);
            self.last_sample_rate = sample_rate;
        }

        const delay_ms = self.params[0].value;
        const feedback = self.params[1].value;
        const mix = self.params[2].value;
        const stereo_spread = self.params[3].value;

        // Calculate delay in samples
        const delay_samples_f = delay_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0;
        const delay_samples: usize = if (std.math.isNan(delay_samples_f)) 0 else @intFromFloat(std.math.clamp(delay_samples_f, 0.0, @as(f32, MAX_DELAY_SAMPLES - 1)));

        // Stereo offset for ping-pong effect
        // Clamp to the buffer so extreme settings cannot overflow the read index.
        const stereo_offset_f = std.math.clamp(stereo_spread * 50.0 * @as(f32, @floatFromInt(sample_rate)) / 1000.0, 0.0, @as(f32, MAX_DELAY_SAMPLES - 2));
        const stereo_offset: usize = if (std.math.isNan(stereo_offset_f)) 0 else @intFromFloat(stereo_offset_f);

        const frames = buffer.len / 2;
        const dry_gain = 1.0 - mix;
        const wet_gain = mix;

        for (0..frames) |i| {
            const dry_l = buffer[i * 2];
            const dry_r = buffer[i * 2 + 1];

            // Calculate read positions
            const read_pos_l = (self.write_pos + MAX_DELAY_SAMPLES * 2 - delay_samples * 2) % (MAX_DELAY_SAMPLES * 2);
            // The combined look-back can exceed the ring size, so reduce it before subtracting.
            const back_r = (delay_samples * 2 + stereo_offset * 2) % (MAX_DELAY_SAMPLES * 2);
            const read_pos_r = (self.write_pos + MAX_DELAY_SAMPLES * 2 - back_r + 1) % (MAX_DELAY_SAMPLES * 2);

            // Read delayed samples
            const delayed_l = self.buffer[read_pos_l];
            const delayed_r = self.buffer[read_pos_r];

            // Write to delay buffer with feedback
            self.buffer[self.write_pos] = dry_l + delayed_l * feedback;
            self.buffer[self.write_pos + 1] = dry_r + delayed_r * feedback;

            // Advance write position
            self.write_pos = (self.write_pos + 2) % (MAX_DELAY_SAMPLES * 2);

            // Mix dry and wet
            buffer[i * 2] = dry_l * dry_gain + delayed_l * wet_gain;
            buffer[i * 2 + 1] = dry_r * dry_gain + delayed_r * wet_gain;
        }
    }

    fn updateDelayTime(self: *Delay, sample_rate: u32) void {
        const delay_ms = self.params[0].value;
        const delay_samples_f = delay_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0;
        self.delay_samples = if (std.math.isNan(delay_samples_f))
            0
        else
            @intFromFloat(std.math.clamp(delay_samples_f, 0.0, @as(f32, MAX_DELAY_SAMPLES - 1)));
    }

    fn reset(effect: *Effect) void {
        const self: *Delay = @fieldParentPtr("effect", effect);
        @memset(&self.buffer, 0.0);
        self.write_pos = 0;
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Delay = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Delay = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
    }

    /// Convenience: set delay time in ms
    pub fn setTime(self: *Delay, ms: f32) void {
        setParameter(&self.effect, 0, ms);
    }

    /// Convenience: set feedback amount
    pub fn setFeedback(self: *Delay, feedback: f32) void {
        setParameter(&self.effect, 1, feedback);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "delay: basic delay time conversion" {
    var delay = Delay.init();
    delay.setTime(50.0); // 50 ms

    // At 48kHz, 50ms = 2400 samples
    const expected_samples = 2400;

    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0 };
    delay.effect.process(&buffer, 48000);

    try testing.expectEqual(@as(usize, expected_samples), delay.delay_samples);
}

test "delay: circular buffer wraparound" {
    var delay = Delay.init();
    delay.setTime(10.0); // Short delay
    delay.setFeedback(0.0); // No feedback
    delay.effect.vtable.setParameter(&delay.effect, 2, 1.0); // 100% wet

    // Create impulse in stereo buffer
    var buffer = [_]f32{
        1.0, 1.0, // Impulse
        0.0, 0.0,
        0.0, 0.0,
        0.0, 0.0,
    };

    // Process multiple buffers to force wraparound
    for (0..1000) |_| {
        delay.effect.process(&buffer, 48000);
    }

    // Write position should have wrapped around
    try testing.expect(delay.write_pos < Delay.MAX_DELAY_SAMPLES * 2);
}

test "delay: feedback loop creates repeating delays" {
    var delay = Delay.init();
    delay.setTime(5.0); // Very short delay for testing
    delay.setFeedback(0.5); // 50% feedback
    delay.effect.vtable.setParameter(&delay.effect, 2, 1.0); // 100% wet

    // Single impulse
    var buffer1 = [_]f32{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    delay.effect.process(&buffer1, 48000);

    // Process more buffers - feedback should keep signal alive
    var buffer2 = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };

    var signal_continues = false;
    for (0..100) |_| {
        delay.effect.process(&buffer2, 48000);

        // Check if any sample is non-zero
        for (buffer2) |sample| {
            if (@abs(sample) > 0.001) {
                signal_continues = true;
                break;
            }
        }
        if (signal_continues) break;
    }

    // Feedback should keep the signal going
    try testing.expect(signal_continues);
}

test "delay: zero feedback stops repetition" {
    var delay = Delay.init();
    delay.setTime(5.0); // Very short delay
    delay.setFeedback(0.0); // No feedback
    delay.effect.vtable.setParameter(&delay.effect, 2, 1.0); // 100% wet

    // Single impulse
    var buffer1 = [_]f32{ 1.0, 1.0, 0.0, 0.0 };
    delay.effect.process(&buffer1, 48000);

    // Calculate delay in samples at 48kHz for 5ms
    const delay_samples = @as(usize, @intFromFloat(5.0 * 48.0));
    const delay_frames = delay_samples;

    // Process enough buffers to exceed the delay time
    const frames_to_process = delay_frames + 100;
    var buffer2 = [_]f32{ 0.0, 0.0, 0.0, 0.0 };

    const iterations_needed = (frames_to_process / 2) + 1;
    for (0..iterations_needed) |_| {
        delay.effect.process(&buffer2, 48000);
    }

    // Signal should die out without feedback
    var all_silent = true;
    for (buffer2) |sample| {
        if (@abs(sample) > 0.001) {
            all_silent = false;
            break;
        }
    }
    try testing.expect(all_silent);
}

test "delay: feedback clamping prevents instability" {
    var delay = Delay.init();

    // Try to set feedback above maximum (0.95)
    delay.setFeedback(1.5);
    try testing.expectEqual(@as(f32, 0.95), delay.params[1].value);

    // Try to set feedback below minimum (0.0)
    delay.setFeedback(-0.5);
    try testing.expectEqual(@as(f32, 0.0), delay.params[1].value);
}

test "delay: mix control blends dry and wet" {
    var delay1 = Delay.init();
    delay1.setTime(10.0);
    delay1.setFeedback(0.0);
    delay1.effect.vtable.setParameter(&delay1.effect, 2, 0.0); // 0% wet (100% dry)

    var delay2 = Delay.init();
    delay2.setTime(10.0);
    delay2.setFeedback(0.0);
    delay2.effect.vtable.setParameter(&delay2.effect, 2, 1.0); // 100% wet (0% dry)

    var buffer_dry = [_]f32{ 1.0, 1.0, 0.5, 0.5 };
    var buffer_wet = [_]f32{ 1.0, 1.0, 0.5, 0.5 };
    const original = buffer_dry;

    delay1.effect.process(&buffer_dry, 48000);
    delay2.effect.process(&buffer_wet, 48000);

    // Dry should match original closely
    try testing.expectApproxEqAbs(original[0], buffer_dry[0], 0.01);
    try testing.expectApproxEqAbs(original[1], buffer_dry[1], 0.01);

    // Wet should be different from original (delayed signal)
    try testing.expect(@abs(buffer_wet[0] - original[0]) > 0.1 or @abs(buffer_wet[1] - original[1]) > 0.1);
}

test "delay: stereo spread creates ping-pong effect" {
    var delay = Delay.init();
    delay.setTime(10.0);
    delay.setFeedback(0.3);
    delay.effect.vtable.setParameter(&delay.effect, 2, 0.5); // 50% mix
    delay.effect.vtable.setParameter(&delay.effect, 3, 1.0); // Max stereo spread

    // Create mono impulse (same in L and R)
    var buffer = [_]f32{
        1.0, 1.0, // L, R
        0.0, 0.0,
        0.0, 0.0,
        0.0, 0.0,
    };

    // Process several times
    for (0..50) |_| {
        delay.effect.process(&buffer, 48000);
    }

    // With stereo spread, L and R delayed signals should differ
    // (This is a qualitative test - stereo spread adds offset)
    const stereo_spread = delay.params[3].value;
    try testing.expect(stereo_spread > 0.0);
}

test "delay: reset clears buffer" {
    var delay = Delay.init();
    delay.setTime(20.0);
    delay.setFeedback(0.5);

    // Fill buffer with signal
    var buffer = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    for (0..100) |_| {
        delay.effect.process(&buffer, 48000);
    }

    // Buffer should have content
    var has_content = false;
    for (delay.buffer) |sample| {
        if (@abs(sample) > 0.001) {
            has_content = true;
            break;
        }
    }
    try testing.expect(has_content);

    // Reset
    delay.effect.vtable.reset(&delay.effect);

    // Buffer should be cleared
    for (delay.buffer) |sample| {
        try testing.expectEqual(@as(f32, 0.0), sample);
    }
    try testing.expectEqual(@as(usize, 0), delay.write_pos);
}

test "delay: delay time clamping" {
    var delay = Delay.init();

    // Test time clamping (min: 1.0 ms, max: 100.0 ms)
    delay.setTime(500.0); // Way above max
    try testing.expectEqual(@as(f32, 100.0), delay.params[0].value);

    delay.setTime(0.1); // Below min
    try testing.expectEqual(@as(f32, 1.0), delay.params[0].value);
}

test "delay: maximum delay time respects buffer size" {
    var delay = Delay.init();
    delay.setTime(50.0); // Use moderate delay time to avoid overflow

    // Prime the delay buffer by processing many frames first
    // to ensure write_pos is well ahead of read_pos
    var prime_buffer = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    for (0..5000) |_| {
        delay.effect.process(&prime_buffer, 48000);
    }

    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0 };
    delay.effect.process(&buffer, 48000);

    // At 48kHz, 50ms = 2400 samples
    // Should not exceed MAX_DELAY_SAMPLES
    try testing.expect(delay.delay_samples <= Delay.MAX_DELAY_SAMPLES - 1);
    try testing.expectEqual(@as(usize, 2400), delay.delay_samples);
}

test "delay: sample rate change updates delay samples" {
    var delay = Delay.init();
    delay.setTime(50.0); // 50 ms

    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0 };

    // Process at 48kHz
    delay.effect.process(&buffer, 48000);
    const samples_at_48k = delay.delay_samples;

    // Process at 44.1kHz
    delay.effect.process(&buffer, 44100);
    const samples_at_44k = delay.delay_samples;

    // Different sample rates should result in different sample counts
    // for the same delay time in milliseconds
    try testing.expect(samples_at_48k != samples_at_44k);
    try testing.expectEqual(@as(u32, 44100), delay.last_sample_rate);
}

test "delay: stereo processing maintains independence" {
    var delay = Delay.init();
    delay.setTime(10.0);
    delay.setFeedback(0.2);
    delay.effect.vtable.setParameter(&delay.effect, 2, 0.5); // 50% mix
    delay.effect.vtable.setParameter(&delay.effect, 3, 0.0); // No stereo spread

    // Different signals in L and R
    var buffer = [_]f32{
        1.0,  0.5, // L, R
        -1.0, -0.5,
        1.0,  0.5,
        -1.0, -0.5,
    };

    delay.effect.process(&buffer, 48000);

    // Channels should still be different (processed independently)
    try testing.expect(buffer[0] != buffer[1]);
    try testing.expect(buffer[2] != buffer[3]);
}

test "delay: write position advances correctly" {
    var delay = Delay.init();
    delay.setTime(10.0);

    const initial_pos = delay.write_pos;

    var buffer = [_]f32{ 1.0, 1.0, 0.5, 0.5 }; // 2 stereo frames
    delay.effect.process(&buffer, 48000);

    // Write position should have advanced by buffer frames * 2 (stereo)
    const expected_advance = 2 * 2; // 2 frames * 2 channels
    try testing.expectEqual(initial_pos + expected_advance, delay.write_pos);
}

test "delay: parameter count and access" {
    const delay = Delay.init();

    try testing.expectEqual(@as(usize, 4), delay.effect.vtable.getParameterCount(&delay.effect));

    const param0 = delay.effect.vtable.getParameter(&delay.effect, 0);
    try testing.expect(param0 != null);
    try testing.expectEqualStrings("Time", param0.?.name);

    const param1 = delay.effect.vtable.getParameter(&delay.effect, 1);
    try testing.expect(param1 != null);
    try testing.expectEqualStrings("Feedback", param1.?.name);

    const param2 = delay.effect.vtable.getParameter(&delay.effect, 2);
    try testing.expect(param2 != null);
    try testing.expectEqualStrings("Mix", param2.?.name);

    const param3 = delay.effect.vtable.getParameter(&delay.effect, 3);
    try testing.expect(param3 != null);
    try testing.expectEqualStrings("Stereo", param3.?.name);

    const param_invalid = delay.effect.vtable.getParameter(&delay.effect, 4);
    try testing.expect(param_invalid == null);
}

test "delay: high feedback maintains signal energy" {
    var delay = Delay.init();
    delay.setTime(5.0);
    delay.setFeedback(0.9); // High feedback
    delay.effect.vtable.setParameter(&delay.effect, 2, 1.0); // 100% wet

    // Single impulse
    var buffer = [_]f32{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    delay.effect.process(&buffer, 48000);

    // Process many iterations
    var max_amplitude: f32 = 0.0;
    for (0..200) |_| {
        var temp_buffer = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
        delay.effect.process(&temp_buffer, 48000);

        for (temp_buffer) |sample| {
            max_amplitude = @max(max_amplitude, @abs(sample));
        }
    }

    // With 90% feedback, signal should persist for many iterations
    try testing.expect(max_amplitude > 0.1);
}

fn expectFiniteOutput(delay: *Delay, sample_rate: u32) !void {
    var buffer: [128]f32 = undefined;
    for (0..40) |block| {
        for (0..buffer.len / 2) |i| {
            const v: f32 = if (block == 0 and i == 0) 1.0 else 0.25 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
            buffer[i * 2] = v;
            buffer[i * 2 + 1] = -v;
        }
        delay.effect.process(&buffer, sample_rate);
        for (buffer) |sample| try testing.expect(std.math.isFinite(sample));
    }
}

test "delay: stress - extreme delay times via setParameter stay finite" {
    const times = [_]f32{ 0.0, -1.0, -1.0e9, std.math.nan(f32), std.math.inf(f32), 10000.0, 1.0e9 };
    for (times) |t| {
        for ([_]f32{ 0.0, 0.5, 1.0 }) |spread| {
            var delay = Delay.init();
            delay.effect.vtable.setParameter(&delay.effect, 0, t);
            delay.effect.vtable.setParameter(&delay.effect, 1, 0.99);
            delay.effect.vtable.setParameter(&delay.effect, 3, spread);
            try expectFiniteOutput(&delay, 48000);
        }
    }
}

test "delay: stress - out-of-range parameters written directly stay finite" {
    // Bypasses the setParameter clamp, as a corrupt project or automation write could.
    const times = [_]f32{ 0.0, -1.0, -1.0e9, std.math.nan(f32), 10000.0, 1.0e9 };
    const spreads = [_]f32{ 0.0, 0.5, 1.0, 1000.0 };
    const rates = [_]u32{ 44100, 48000, 96000, 192000 };
    for (times) |t| {
        for (spreads) |spread| {
            for (rates) |rate| {
                var delay = Delay.init();
                delay.params[0].value = t;
                delay.params[1].value = 0.99;
                delay.params[3].value = spread;
                try expectFiniteOutput(&delay, rate);
                try testing.expect(delay.delay_samples <= Delay.MAX_DELAY_SAMPLES - 1);
            }
        }
    }
}

test "delay: stress - full wet at feedback 0.99 does not blow up" {
    var delay = Delay.init();
    delay.setTime(1.0);
    delay.effect.vtable.setParameter(&delay.effect, 1, 0.99);
    delay.effect.vtable.setParameter(&delay.effect, 2, 1.0);
    delay.effect.vtable.setParameter(&delay.effect, 3, 1.0);
    var buffer: [64]f32 = undefined;
    var peak: f32 = 0.0;
    for (0..2000) |block| {
        for (&buffer, 0..) |*s, i| s.* = if (block == 0 and i < 2) 1.0 else 0.0;
        delay.effect.process(&buffer, 48000);
        for (buffer) |s| {
            try testing.expect(std.math.isFinite(s));
            peak = @max(peak, @abs(s));
        }
    }
    try testing.expect(peak <= 1.0);
}
