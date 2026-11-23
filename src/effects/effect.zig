//! Base effect interface and common types
//!
//! All effects implement this interface for consistent processing.
//! Effects are designed for real-time audio - NO allocations in process().

const std = @import("std");

/// Effect parameter with metadata
pub const Parameter = struct {
    name: []const u8,
    min: f32,
    max: f32,
    default: f32,
    value: f32,
    unit: []const u8 = "",

    pub fn normalized(self: *const Parameter) f32 {
        return (self.value - self.min) / (self.max - self.min);
    }

    pub fn setNormalized(self: *Parameter, norm: f32) void {
        self.value = self.min + norm * (self.max - self.min);
    }
};

/// Effect processing interface
/// All effects must implement these functions
pub const Effect = struct {
    /// Virtual function table
    vtable: *const VTable,

    /// Effect name for display
    name: []const u8,

    /// Bypass state
    bypassed: bool = false,

    /// Mix (dry/wet) control 0.0 = dry, 1.0 = wet
    mix: f32 = 1.0,

    pub const VTable = struct {
        /// Process audio in-place (stereo interleaved)
        /// REAL-TIME SAFE - NO ALLOCATIONS
        process: *const fn (self: *Effect, buffer: []f32, sample_rate: u32) void,

        /// Reset effect state (clear delays, filters, etc.)
        reset: *const fn (self: *Effect) void,

        /// Get parameter count
        getParameterCount: *const fn (self: *const Effect) usize,

        /// Get parameter by index
        getParameter: *const fn (self: *const Effect, index: usize) ?*const Parameter,

        /// Set parameter value by index
        setParameter: *const fn (self: *Effect, index: usize, value: f32) void,

        /// Algorithmic delay in frames; null means none. Used for delay compensation.
        latency: ?*const fn (self: *const Effect) usize = null,
    };

    /// Process audio through effect (handles bypass and mix)
    pub fn process(self: *Effect, buffer: []f32, sample_rate: u32) void {
        if (self.bypassed) return;

        if (self.mix >= 0.999) {
            // Fully wet - process in place
            self.vtable.process(self, buffer, sample_rate);
        } else if (self.mix <= 0.001) {
            // Fully dry - do nothing
            return;
        } else {
            // Mix dry/wet - need to preserve dry signal
            // For efficiency, we process in place and this is approximate
            // A full implementation would use a temp buffer
            self.vtable.process(self, buffer, sample_rate);
        }
    }

    /// Delay this effect adds to the signal, in frames (0 when bypassed or fully dry).
    pub fn latencySamples(self: *const Effect) usize {
        if (self.bypassed or self.mix <= 0.001) return 0;
        const f = self.vtable.latency orelse return 0;
        return f(self);
    }

    pub fn reset(self: *Effect) void {
        self.vtable.reset(self);
    }

    pub fn getParameterCount(self: *const Effect) usize {
        return self.vtable.getParameterCount(self);
    }

    pub fn getParameter(self: *const Effect, index: usize) ?*const Parameter {
        return self.vtable.getParameter(self, index);
    }

    pub fn setParameter(self: *Effect, index: usize, value: f32) void {
        self.vtable.setParameter(self, index, value);
    }

    pub fn setBypass(self: *Effect, bypassed: bool) void {
        self.bypassed = bypassed;
    }

    pub fn setMix(self: *Effect, mix: f32) void {
        self.mix = std.math.clamp(mix, 0.0, 1.0);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parameter normalization" {
    const testing = std.testing;

    var param = Parameter{
        .name = "Test",
        .min = 0.0,
        .max = 100.0,
        .default = 50.0,
        .value = 25.0,
    };

    // Value 25 out of 0-100 = 0.25 normalized
    try testing.expectApproxEqAbs(@as(f32, 0.25), param.normalized(), 0.001);

    // Set normalized to 0.75 = value 75
    param.setNormalized(0.75);
    try testing.expectApproxEqAbs(@as(f32, 75.0), param.value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), param.normalized(), 0.001);

    // Edge cases
    param.setNormalized(0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), param.value, 0.001);

    param.setNormalized(1.0);
    try testing.expectApproxEqAbs(@as(f32, 100.0), param.value, 0.001);
}

test "parameter normalization with negative range" {
    const testing = std.testing;

    // Parameter like pan: -1.0 to 1.0
    var param = Parameter{
        .name = "Pan",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .value = 0.0,
    };

    // Center (0.0) = 0.5 normalized
    try testing.expectApproxEqAbs(@as(f32, 0.5), param.normalized(), 0.001);

    // Hard left
    param.value = -1.0;
    try testing.expectApproxEqAbs(@as(f32, 0.0), param.normalized(), 0.001);

    // Hard right
    param.value = 1.0;
    try testing.expectApproxEqAbs(@as(f32, 1.0), param.normalized(), 0.001);

    // Set from normalized
    param.setNormalized(0.25); // -0.5
    try testing.expectApproxEqAbs(@as(f32, -0.5), param.value, 0.001);
}

test "parameter normalization dB range" {
    const testing = std.testing;

    // Gain in dB: -60 to +12
    var param = Parameter{
        .name = "Gain",
        .min = -60.0,
        .max = 12.0,
        .default = 0.0,
        .value = 0.0,
        .unit = "dB",
    };

    // 0 dB is at normalized = 60/72 ≈ 0.833
    try testing.expectApproxEqAbs(@as(f32, 0.833), param.normalized(), 0.01);

    // -60 dB = normalized 0.0
    param.value = -60.0;
    try testing.expectApproxEqAbs(@as(f32, 0.0), param.normalized(), 0.001);

    // +12 dB = normalized 1.0
    param.value = 12.0;
    try testing.expectApproxEqAbs(@as(f32, 1.0), param.normalized(), 0.001);
}

// Test effect with mock vtable
const MockEffect = struct {
    effect: Effect,
    process_count: usize = 0,
    reset_count: usize = 0,
    params: [2]Parameter = .{
        .{ .name = "Param1", .min = 0, .max = 1, .default = 0.5, .value = 0.5 },
        .{ .name = "Param2", .min = -10, .max = 10, .default = 0, .value = 0 },
    },

    const vtable = Effect.VTable{
        .process = mockProcess,
        .reset = mockReset,
        .getParameterCount = mockGetParameterCount,
        .getParameter = mockGetParameter,
        .setParameter = mockSetParameter,
    };

    fn mockProcess(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        _ = buffer;
        _ = sample_rate;
        const self: *MockEffect = @fieldParentPtr("effect", effect);
        self.process_count += 1;
    }

    fn mockReset(effect: *Effect) void {
        const self: *MockEffect = @fieldParentPtr("effect", effect);
        self.reset_count += 1;
    }

    fn mockGetParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 2;
    }

    fn mockGetParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const MockEffect = @fieldParentPtr("effect", effect);
        if (index >= 2) return null;
        return &self.params[index];
    }

    fn mockSetParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *MockEffect = @fieldParentPtr("effect", effect);
        if (index < 2) {
            self.params[index].value = value;
        }
    }
};

test "effect bypass" {
    const testing = std.testing;

    var mock = MockEffect{
        .effect = .{
            .vtable = &MockEffect.vtable,
            .name = "Mock Effect",
        },
    };

    var buffer = [_]f32{ 0.1, 0.2, 0.3, 0.4 };

    // Process normally
    mock.effect.process(&buffer, 48000);
    try testing.expectEqual(@as(usize, 1), mock.process_count);

    // Enable bypass
    mock.effect.setBypass(true);
    try testing.expect(mock.effect.bypassed);

    // Process with bypass - should not call vtable process
    mock.effect.process(&buffer, 48000);
    try testing.expectEqual(@as(usize, 1), mock.process_count); // Still 1

    // Disable bypass
    mock.effect.setBypass(false);
    mock.effect.process(&buffer, 48000);
    try testing.expectEqual(@as(usize, 2), mock.process_count);
}

test "effect mix control" {
    const testing = std.testing;

    var mock = MockEffect{
        .effect = .{
            .vtable = &MockEffect.vtable,
            .name = "Mock Effect",
        },
    };

    // Default mix is 1.0 (fully wet)
    try testing.expectApproxEqAbs(@as(f32, 1.0), mock.effect.mix, 0.001);

    // Set mix
    mock.effect.setMix(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mock.effect.mix, 0.001);

    // Clamp to valid range
    mock.effect.setMix(-0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), mock.effect.mix, 0.001);

    mock.effect.setMix(1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mock.effect.mix, 0.001);

    // Fully dry - should not process
    var buffer = [_]f32{ 0.1, 0.2 };
    mock.effect.setMix(0.0);
    mock.effect.process(&buffer, 48000);
    try testing.expectEqual(@as(usize, 0), mock.process_count);
}

test "effect reset" {
    const testing = std.testing;

    var mock = MockEffect{
        .effect = .{
            .vtable = &MockEffect.vtable,
            .name = "Mock Effect",
        },
    };

    try testing.expectEqual(@as(usize, 0), mock.reset_count);

    mock.effect.reset();
    try testing.expectEqual(@as(usize, 1), mock.reset_count);

    mock.effect.reset();
    try testing.expectEqual(@as(usize, 2), mock.reset_count);
}

test "effect parameters" {
    const testing = std.testing;

    var mock = MockEffect{
        .effect = .{
            .vtable = &MockEffect.vtable,
            .name = "Mock Effect",
        },
    };

    // Get parameter count
    try testing.expectEqual(@as(usize, 2), mock.effect.getParameterCount());

    // Get parameters
    const p0 = mock.effect.getParameter(0);
    try testing.expect(p0 != null);
    try testing.expectEqualStrings("Param1", p0.?.name);

    const p1 = mock.effect.getParameter(1);
    try testing.expect(p1 != null);
    try testing.expectEqualStrings("Param2", p1.?.name);

    // Invalid index
    const p2 = mock.effect.getParameter(2);
    try testing.expect(p2 == null);

    // Set parameter
    mock.effect.setParameter(0, 0.75);
    try testing.expectApproxEqAbs(@as(f32, 0.75), mock.params[0].value, 0.001);
}
