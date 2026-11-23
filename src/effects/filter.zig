//! Biquad Filter effect
//!
//! State-variable filter with low-pass, high-pass, band-pass, and notch modes.
//! Uses the RBJ Audio EQ Cookbook formulas.

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

pub const FilterType = enum(u8) {
    low_pass = 0,
    high_pass = 1,
    band_pass = 2,
    notch = 3,
    peak = 4,
    low_shelf = 5,
    high_shelf = 6,
};

pub const Filter = struct {
    effect: Effect,

    // Parameters
    params: [4]Parameter = .{
        .{ .name = "Cutoff", .min = 20.0, .max = 20000.0, .default = 1000.0, .value = 1000.0, .unit = "Hz" },
        .{ .name = "Resonance", .min = 0.1, .max = 10.0, .default = 0.707, .value = 0.707, .unit = "Q" },
        .{ .name = "Type", .min = 0.0, .max = 6.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Gain", .min = -24.0, .max = 24.0, .default = 0.0, .value = 0.0, .unit = "dB" },
    },

    // Biquad coefficients
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    // Filter state (stereo)
    x1: [2]f32 = .{ 0.0, 0.0 },
    x2: [2]f32 = .{ 0.0, 0.0 },
    y1: [2]f32 = .{ 0.0, 0.0 },
    y2: [2]f32 = .{ 0.0, 0.0 },

    // Cached values
    last_sample_rate: u32 = 0,
    coeffs_dirty: bool = true,

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Filter {
        return .{
            .effect = .{
                .vtable = &vtable,
                .name = "Filter",
            },
        };
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *Filter = @fieldParentPtr("effect", effect);

        // Recalculate coefficients if needed
        if (self.coeffs_dirty or self.last_sample_rate != sample_rate) {
            self.calculateCoefficients(sample_rate);
            self.last_sample_rate = sample_rate;
            self.coeffs_dirty = false;
        }

        const frames = buffer.len / 2;

        for (0..frames) |i| {
            // Left channel
            const x_l = buffer[i * 2];
            const y_l = self.b0 * x_l + self.b1 * self.x1[0] + self.b2 * self.x2[0] - self.a1 * self.y1[0] - self.a2 * self.y2[0];

            self.x2[0] = self.x1[0];
            self.x1[0] = x_l;
            self.y2[0] = self.y1[0];
            self.y1[0] = y_l;

            buffer[i * 2] = y_l;

            // Right channel
            const x_r = buffer[i * 2 + 1];
            const y_r = self.b0 * x_r + self.b1 * self.x1[1] + self.b2 * self.x2[1] - self.a1 * self.y1[1] - self.a2 * self.y2[1];

            self.x2[1] = self.x1[1];
            self.x1[1] = x_r;
            self.y2[1] = self.y1[1];
            self.y1[1] = y_r;

            buffer[i * 2 + 1] = y_r;
        }
    }

    fn calculateCoefficients(self: *Filter, sample_rate: u32) void {
        // Safely get parameters with NaN protection
        const freq = if (std.math.isNan(self.params[0].value) or std.math.isInf(self.params[0].value))
            1000.0
        else
            std.math.clamp(self.params[0].value, 20.0, 20000.0);
        const q = if (std.math.isNan(self.params[1].value) or std.math.isInf(self.params[1].value))
            0.707
        else
            @max(0.1, self.params[1].value);
        const type_value = self.params[2].value;
        const type_int: u8 = if (std.math.isNan(type_value) or std.math.isInf(type_value))
            0
        else
            @intFromFloat(std.math.clamp(type_value, 0.0, 6.0));
        const filter_type: FilterType = @fromBackingInt(@intCast(type_int));
        const gain_db = if (std.math.isNan(self.params[3].value)) 0.0 else self.params[3].value;

        const sr = @as(f32, @floatFromInt(sample_rate));
        const omega = 2.0 * std.math.pi * freq / sr;
        const sin_omega = @sin(omega);
        const cos_omega = @cos(omega);
        const alpha = sin_omega / (2.0 * q);

        var b0: f32 = 1.0;
        var b1: f32 = 0.0;
        var b2: f32 = 0.0;
        var a0: f32 = 1.0;
        var a1: f32 = 0.0;
        var a2: f32 = 0.0;

        switch (filter_type) {
            .low_pass => {
                b0 = (1.0 - cos_omega) / 2.0;
                b1 = 1.0 - cos_omega;
                b2 = (1.0 - cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .high_pass => {
                b0 = (1.0 + cos_omega) / 2.0;
                b1 = -(1.0 + cos_omega);
                b2 = (1.0 + cos_omega) / 2.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .band_pass => {
                b0 = alpha;
                b1 = 0.0;
                b2 = -alpha;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .notch => {
                b0 = 1.0;
                b1 = -2.0 * cos_omega;
                b2 = 1.0;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha;
            },
            .peak => {
                const a = std.math.pow(f32, 10.0, gain_db / 40.0);
                b0 = 1.0 + alpha * a;
                b1 = -2.0 * cos_omega;
                b2 = 1.0 - alpha * a;
                a0 = 1.0 + alpha / a;
                a1 = -2.0 * cos_omega;
                a2 = 1.0 - alpha / a;
            },
            .low_shelf => {
                const a = std.math.pow(f32, 10.0, gain_db / 40.0);
                const sq_a = @sqrt(a);
                b0 = a * ((a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sq_a * alpha);
                b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_omega);
                b2 = a * ((a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sq_a * alpha);
                a0 = (a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sq_a * alpha;
                a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cos_omega);
                a2 = (a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sq_a * alpha;
            },
            .high_shelf => {
                const a = std.math.pow(f32, 10.0, gain_db / 40.0);
                const sq_a = @sqrt(a);
                b0 = a * ((a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sq_a * alpha);
                b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_omega);
                b2 = a * ((a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sq_a * alpha);
                a0 = (a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sq_a * alpha;
                a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cos_omega);
                a2 = (a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sq_a * alpha;
            },
        }

        // Normalize coefficients (protect against division by zero/NaN)
        if (a0 == 0.0 or std.math.isNan(a0) or std.math.isInf(a0)) {
            // Reset to passthrough if coefficients are invalid
            self.b0 = 1.0;
            self.b1 = 0.0;
            self.b2 = 0.0;
            self.a1 = 0.0;
            self.a2 = 0.0;
        } else {
            self.b0 = b0 / a0;
            self.b1 = b1 / a0;
            self.b2 = b2 / a0;
            self.a1 = a1 / a0;
            self.a2 = a2 / a0;

            // Sanitize any NaN/Inf that might have crept in
            if (std.math.isNan(self.b0) or std.math.isInf(self.b0)) self.b0 = 1.0;
            if (std.math.isNan(self.b1) or std.math.isInf(self.b1)) self.b1 = 0.0;
            if (std.math.isNan(self.b2) or std.math.isInf(self.b2)) self.b2 = 0.0;
            if (std.math.isNan(self.a1) or std.math.isInf(self.a1)) self.a1 = 0.0;
            if (std.math.isNan(self.a2) or std.math.isInf(self.a2)) self.a2 = 0.0;
        }
    }

    fn reset(effect: *Effect) void {
        const self: *Filter = @fieldParentPtr("effect", effect);
        self.x1 = .{ 0.0, 0.0 };
        self.x2 = .{ 0.0, 0.0 };
        self.y1 = .{ 0.0, 0.0 };
        self.y2 = .{ 0.0, 0.0 };
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 4;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Filter = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Filter = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;

        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
        self.coeffs_dirty = true;
    }

    /// Convenience: set cutoff frequency
    pub fn setCutoff(self: *Filter, freq: f32) void {
        setParameter(&self.effect, 0, freq);
    }

    /// Convenience: set resonance (Q)
    pub fn setResonance(self: *Filter, q: f32) void {
        setParameter(&self.effect, 1, q);
    }

    /// Convenience: set filter type
    pub fn setType(self: *Filter, filter_type: FilterType) void {
        setParameter(&self.effect, 2, @floatFromInt(@backingInt(filter_type)));
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "filter: lowpass filters high frequencies" {
    var filter = Filter.init();
    filter.setType(.low_pass);
    filter.setCutoff(1000.0);
    filter.setResonance(0.707);

    // Create stereo buffer with alternating high-frequency signal
    // This simulates a ~12kHz signal at 48kHz sample rate
    var buffer = [_]f32{
        1.0, 1.0, // L, R
        -1.0, -1.0, // L, R
        1.0, 1.0, // L, R
        -1.0, -1.0, // L, R
    };

    filter.effect.process(&buffer, 48000);

    // High-frequency content should be attenuated
    for (buffer) |sample| {
        try testing.expect(@abs(sample) < 1.0);
    }
}

test "filter: highpass filters low frequencies" {
    var filter = Filter.init();
    filter.setType(.high_pass);
    filter.setCutoff(1000.0);
    filter.setResonance(0.707);

    // Create stereo buffer with DC offset (0 Hz)
    var buffer = [_]f32{
        1.0, 1.0, // L, R
        1.0, 1.0, // L, R
        1.0, 1.0, // L, R
        1.0, 1.0, // L, R
    };

    filter.effect.process(&buffer, 48000);

    // DC should be filtered out, signal should approach zero
    for (buffer) |sample| {
        try testing.expect(@abs(sample) < 1.0);
    }
}

test "filter: bandpass isolates frequency range" {
    var filter = Filter.init();
    filter.setType(.band_pass);
    filter.setCutoff(1000.0);
    filter.setResonance(2.0); // Higher Q for narrower band

    // Create stereo buffer
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0, 0.5, 0.5, -0.5, -0.5 };

    filter.effect.process(&buffer, 48000);

    // Bandpass should modify the signal
    var signal_changed = false;
    for (buffer, 0..) |sample, i| {
        const original = if (i < 2) @as(f32, 1.0) else if (i < 4) @as(f32, -1.0) else if (i < 6) @as(f32, 0.5) else @as(f32, -0.5);
        if (@abs(sample - original) > 0.01) {
            signal_changed = true;
            break;
        }
    }
    try testing.expect(signal_changed);
}

test "filter: notch removes specific frequency" {
    var filter = Filter.init();
    filter.setType(.notch);
    filter.setCutoff(1000.0);
    filter.setResonance(5.0); // High Q for narrow notch

    // Create stereo buffer
    var buffer = [_]f32{ 0.8, 0.8, -0.8, -0.8, 0.6, 0.6, -0.6, -0.6 };

    filter.effect.process(&buffer, 48000);

    // Notch filter should affect the signal
    var signal_changed = false;
    for (buffer, 0..) |sample, i| {
        const original = if (i < 2) @as(f32, 0.8) else if (i < 4) @as(f32, -0.8) else if (i < 6) @as(f32, 0.6) else @as(f32, -0.6);
        if (@abs(sample - original) > 0.01) {
            signal_changed = true;
            break;
        }
    }
    try testing.expect(signal_changed);
}

test "filter: peak boosts/cuts frequency" {
    var filter = Filter.init();
    filter.setType(.peak);
    filter.setCutoff(1000.0);
    filter.setResonance(2.0);
    filter.effect.vtable.setParameter(&filter.effect, 3, 6.0); // +6 dB gain

    // Create stereo buffer
    var buffer = [_]f32{ 0.5, 0.5, -0.5, -0.5, 0.3, 0.3, -0.3, -0.3 };

    filter.effect.process(&buffer, 48000);

    // Peak filter should modify the signal
    var signal_changed = false;
    for (buffer, 0..) |sample, i| {
        const original = if (i < 2) @as(f32, 0.5) else if (i < 4) @as(f32, -0.5) else if (i < 6) @as(f32, 0.3) else @as(f32, -0.3);
        if (@abs(sample - original) > 0.01) {
            signal_changed = true;
            break;
        }
    }
    try testing.expect(signal_changed);
}

test "filter: low shelf boosts/cuts low frequencies" {
    var filter = Filter.init();
    filter.setType(.low_shelf);
    filter.setCutoff(500.0);
    filter.setResonance(0.707);
    filter.effect.vtable.setParameter(&filter.effect, 3, 6.0); // +6 dB gain

    // Create stereo buffer with low-frequency content
    var buffer = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };

    filter.effect.process(&buffer, 48000);

    // Low shelf should modify the signal
    var signal_changed = false;
    for (buffer) |sample| {
        if (@abs(sample - 0.5) > 0.01) {
            signal_changed = true;
            break;
        }
    }
    try testing.expect(signal_changed);
}

test "filter: high shelf boosts/cuts high frequencies" {
    var filter = Filter.init();
    filter.setType(.high_shelf);
    filter.setCutoff(5000.0);
    filter.setResonance(0.707);
    filter.effect.vtable.setParameter(&filter.effect, 3, -6.0); // -6 dB gain

    // Create stereo buffer with alternating signal
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0 };

    filter.effect.process(&buffer, 48000);

    // High shelf should modify the signal
    var signal_changed = false;
    for (buffer, 0..) |sample, i| {
        const original = if (i % 4 < 2) @as(f32, 1.0) else @as(f32, -1.0);
        if (@abs(sample - original) > 0.01) {
            signal_changed = true;
            break;
        }
    }
    try testing.expect(signal_changed);
}

test "filter: stereo processing maintains independence" {
    var filter = Filter.init();
    filter.setType(.low_pass);
    filter.setCutoff(1000.0);
    filter.setResonance(0.707);

    // Create stereo buffer with different signals in L/R
    var buffer = [_]f32{
        1.0, 0.5, // L=1.0, R=0.5
        -1.0, -0.5, // L=-1.0, R=-0.5
        1.0, 0.5, // L=1.0, R=0.5
        -1.0, -0.5, // L=-1.0, R=-0.5
    };

    filter.effect.process(&buffer, 48000);

    // Both channels should be processed independently
    // Left channel (index 0, 2, 4, 6) should have different values than right (1, 3, 5, 7)
    try testing.expect(buffer[0] != buffer[1]);
    try testing.expect(buffer[2] != buffer[3]);
}

test "filter: coefficient recalculation on parameter change" {
    var filter = Filter.init();
    filter.setCutoff(1000.0);

    // Force coefficient calculation
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0 };
    filter.effect.process(&buffer, 48000);

    const b0_before = filter.b0;

    // Change cutoff frequency
    filter.setCutoff(2000.0);
    try testing.expect(filter.coeffs_dirty);

    // Process again to trigger recalculation
    filter.effect.process(&buffer, 48000);

    // Coefficients should have changed
    try testing.expect(filter.b0 != b0_before);
    try testing.expect(!filter.coeffs_dirty);
}

test "filter: coefficient recalculation on sample rate change" {
    var filter = Filter.init();
    filter.setCutoff(1000.0);

    // Process at 48kHz
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0 };
    filter.effect.process(&buffer, 48000);

    const b0_at_48k = filter.b0;

    // Process at 44.1kHz
    filter.effect.process(&buffer, 44100);

    // Coefficients should have changed due to sample rate change
    try testing.expect(filter.b0 != b0_at_48k);
    try testing.expectEqual(@as(u32, 44100), filter.last_sample_rate);
}

test "filter: reset clears state" {
    var filter = Filter.init();
    filter.setType(.low_pass);
    filter.setCutoff(1000.0);

    // Process some data to populate state
    var buffer = [_]f32{ 1.0, 1.0, -1.0, -1.0, 0.5, 0.5, -0.5, -0.5 };
    filter.effect.process(&buffer, 48000);

    // State should be non-zero
    const has_state = filter.x1[0] != 0.0 or filter.x1[1] != 0.0 or filter.y1[0] != 0.0 or filter.y1[1] != 0.0;
    try testing.expect(has_state);

    // Reset
    filter.effect.vtable.reset(&filter.effect);

    // All state should be zero
    try testing.expectEqual(@as(f32, 0.0), filter.x1[0]);
    try testing.expectEqual(@as(f32, 0.0), filter.x1[1]);
    try testing.expectEqual(@as(f32, 0.0), filter.x2[0]);
    try testing.expectEqual(@as(f32, 0.0), filter.x2[1]);
    try testing.expectEqual(@as(f32, 0.0), filter.y1[0]);
    try testing.expectEqual(@as(f32, 0.0), filter.y1[1]);
    try testing.expectEqual(@as(f32, 0.0), filter.y2[0]);
    try testing.expectEqual(@as(f32, 0.0), filter.y2[1]);
}

test "filter: parameter clamping" {
    var filter = Filter.init();

    // Test cutoff clamping (min: 20 Hz, max: 20000 Hz)
    filter.setCutoff(50000.0);
    try testing.expectEqual(@as(f32, 20000.0), filter.params[0].value);

    filter.setCutoff(5.0);
    try testing.expectEqual(@as(f32, 20.0), filter.params[0].value);

    // Test resonance clamping (min: 0.1, max: 10.0)
    filter.setResonance(100.0);
    try testing.expectEqual(@as(f32, 10.0), filter.params[1].value);

    filter.setResonance(0.01);
    try testing.expectEqual(@as(f32, 0.1), filter.params[1].value);

    // Test type clamping (min: 0, max: 6)
    filter.effect.vtable.setParameter(&filter.effect, 2, 100.0);
    try testing.expectEqual(@as(f32, 6.0), filter.params[2].value);

    filter.effect.vtable.setParameter(&filter.effect, 2, -1.0);
    try testing.expectEqual(@as(f32, 0.0), filter.params[2].value);
}

test "filter: parameter count and access" {
    const filter = Filter.init();

    try testing.expectEqual(@as(usize, 4), filter.effect.vtable.getParameterCount(&filter.effect));

    const param0 = filter.effect.vtable.getParameter(&filter.effect, 0);
    try testing.expect(param0 != null);
    try testing.expectEqualStrings("Cutoff", param0.?.name);

    const param1 = filter.effect.vtable.getParameter(&filter.effect, 1);
    try testing.expect(param1 != null);
    try testing.expectEqualStrings("Resonance", param1.?.name);

    const param2 = filter.effect.vtable.getParameter(&filter.effect, 2);
    try testing.expect(param2 != null);
    try testing.expectEqualStrings("Type", param2.?.name);

    const param3 = filter.effect.vtable.getParameter(&filter.effect, 3);
    try testing.expect(param3 != null);
    try testing.expectEqualStrings("Gain", param3.?.name);

    const param_invalid = filter.effect.vtable.getParameter(&filter.effect, 4);
    try testing.expect(param_invalid == null);
}
