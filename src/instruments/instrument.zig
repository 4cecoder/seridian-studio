//! Instrument interface
//!
//! Base interface for all virtual instruments. Designed for real-time audio
//! processing with zero allocations in the audio thread.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");

/// Maximum polyphony (voices) per instrument
pub const MAX_VOICES = 16;

/// MIDI note range
pub const MIDI_NOTE_MIN: u8 = 0;
pub const MIDI_NOTE_MAX: u8 = 127;

/// Base instrument interface using vtable pattern
pub const Instrument = struct {
    vtable: *const VTable,
    name: []const u8,

    pub const VTable = struct {
        /// Process audio into buffer (stereo interleaved)
        /// REAL-TIME SAFE - NO ALLOCATIONS
        process: *const fn (self: *Instrument, buffer: []f32, sample_rate: u32) void,

        /// Trigger note on
        noteOn: *const fn (self: *Instrument, note: u8, velocity: u8) void,

        /// Trigger note off
        noteOff: *const fn (self: *Instrument, note: u8) void,

        /// All notes off (panic)
        allNotesOff: *const fn (self: *Instrument) void,

        /// Reset instrument state
        reset: *const fn (self: *Instrument) void,

        /// Get parameter count
        getParameterCount: *const fn (self: *const Instrument) usize,

        /// Get parameter by index
        getParameter: *const fn (self: *const Instrument, index: usize) ?*const Parameter,

        /// Set parameter value
        setParameter: *const fn (self: *Instrument, index: usize, value: f32) void,

        /// Cleanup (called before deallocation)
        deinit: *const fn (self: *Instrument, allocator: std.mem.Allocator) void,

        /// Destroy and deallocate (calls deinit internally)
        destroy: *const fn (self: *Instrument, allocator: std.mem.Allocator) void,
    };

    /// Process audio
    pub inline fn process(self: *Instrument, buffer: []f32, sample_rate: u32) void {
        self.vtable.process(self, buffer, sample_rate);
    }

    /// Note on
    pub inline fn noteOn(self: *Instrument, note: u8, velocity: u8) void {
        self.vtable.noteOn(self, note, velocity);
    }

    /// Note off
    pub inline fn noteOff(self: *Instrument, note: u8) void {
        self.vtable.noteOff(self, note);
    }

    /// All notes off
    pub inline fn allNotesOff(self: *Instrument) void {
        self.vtable.allNotesOff(self);
    }

    /// Reset
    pub inline fn reset(self: *Instrument) void {
        self.vtable.reset(self);
    }

    /// Get parameter count
    pub inline fn getParameterCount(self: *const Instrument) usize {
        return self.vtable.getParameterCount(self);
    }

    /// Get parameter
    pub inline fn getParameter(self: *const Instrument, index: usize) ?*const Parameter {
        return self.vtable.getParameter(self, index);
    }

    /// Set parameter
    pub inline fn setParameter(self: *Instrument, index: usize, value: f32) void {
        self.vtable.setParameter(self, index, value);
    }

    /// Deinit
    pub inline fn deinit(self: *Instrument, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    /// Destroy and deallocate
    pub inline fn destroy(self: *Instrument, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self, allocator);
    }
};

/// Instrument parameter
pub const Parameter = struct {
    name: []const u8,
    min: f32,
    max: f32,
    default: f32,
    value: f32,
    unit: []const u8 = "",

    /// Get normalized value (0.0 to 1.0)
    pub fn getNormalized(self: *const Parameter) f32 {
        if (self.max == self.min) return 0.0;
        return (self.value - self.min) / (self.max - self.min);
    }

    /// Set from normalized value
    pub fn setNormalized(self: *Parameter, normalized: f32) void {
        self.value = self.min + normalized * (self.max - self.min);
    }
};

/// Mixin for common parameter handling functions
pub fn ParameterMixin(comptime T: type, comptime field_name: []const u8) type {
    return struct {
        pub fn getParameterCount(inst: *const Instrument) usize {
            const self: *const T = @fieldParentPtr(field_name, inst);
            return self.params.len;
        }

        pub fn getParameter(inst: *const Instrument, index: usize) ?*const Parameter {
            const self: *const T = @fieldParentPtr(field_name, inst);
            if (index >= self.params.len) return null;
            return &self.params[index];
        }

        pub fn setParameter(inst: *Instrument, index: usize, value: f32) void {
            const self: *T = @fieldParentPtr(field_name, inst);
            if (index >= self.params.len) return;
            self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
        }
    };
}

/// Mixin for common destroy/deinit functions
pub fn DestroyMixin(comptime T: type, comptime field_name: []const u8) type {
    return struct {
        pub fn destroy(inst: *Instrument, allocator: std.mem.Allocator) void {
            const self: *T = @fieldParentPtr(field_name, inst);
            allocator.destroy(self);
        }

        pub fn deinit(inst: *Instrument, allocator: std.mem.Allocator) void {
            _ = inst;
            _ = allocator;
        }
    };
}

/// Convert velocity (0-127) to amplitude (0.0-1.0)
pub fn velocityToAmplitude(velocity: u8) f32 {
    // Use quadratic curve for more natural feel
    const v = @as(f32, @floatFromInt(velocity)) / 127.0;
    return v * v;
}

test "midi note to freq" {
    const testing = std.testing;

    // A4 = 440Hz
    try testing.expectApproxEqAbs(@as(f32, 440.0), dsp.midiNoteToFreq(69), 0.01);

    // A3 = 220Hz
    try testing.expectApproxEqAbs(@as(f32, 220.0), dsp.midiNoteToFreq(57), 0.01);

    // A5 = 880Hz
    try testing.expectApproxEqAbs(@as(f32, 880.0), dsp.midiNoteToFreq(81), 0.01);

    // Middle C (C4) = 261.63Hz
    try testing.expectApproxEqAbs(@as(f32, 261.63), dsp.midiNoteToFreq(60), 0.1);
}

test "ParameterMixin and DestroyMixin" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Mock instrument type using the mixins
    const MockInstrument = struct {
        instrument: Instrument,
        params: [2]Parameter,

        const Self = @This();
        const ParamMixin = ParameterMixin(Self, "instrument");
        const DestroyMix = DestroyMixin(Self, "instrument");

        const vtable = Instrument.VTable{
            .process = process,
            .noteOn = noteOn,
            .noteOff = noteOff,
            .allNotesOff = allNotesOff,
            .reset = reset,
            .getParameterCount = ParamMixin.getParameterCount,
            .getParameter = ParamMixin.getParameter,
            .setParameter = ParamMixin.setParameter,
            .deinit = DestroyMix.deinit,
            .destroy = DestroyMix.destroy,
        };

        fn process(inst: *Instrument, buffer: []f32, sample_rate: u32) void {
            _ = inst;
            _ = buffer;
            _ = sample_rate;
        }

        fn noteOn(inst: *Instrument, note: u8, velocity: u8) void {
            _ = inst;
            _ = note;
            _ = velocity;
        }

        fn noteOff(inst: *Instrument, note: u8) void {
            _ = inst;
            _ = note;
        }

        fn allNotesOff(inst: *Instrument) void {
            _ = inst;
        }

        fn reset(inst: *Instrument) void {
            _ = inst;
        }

        fn create(alloc: std.mem.Allocator) !*Self {
            const self = try alloc.create(Self);
            self.* = .{
                .instrument = .{
                    .vtable = &vtable,
                    .name = "MockInstrument",
                },
                .params = [_]Parameter{
                    .{
                        .name = "Volume",
                        .min = 0.0,
                        .max = 1.0,
                        .default = 0.8,
                        .value = 0.8,
                        .unit = "dB",
                    },
                    .{
                        .name = "Pan",
                        .min = -1.0,
                        .max = 1.0,
                        .default = 0.0,
                        .value = 0.0,
                        .unit = "",
                    },
                },
            };
            return self;
        }
    };

    // Create mock instrument
    const mock = try MockInstrument.create(allocator);
    defer mock.instrument.destroy(allocator);

    const inst = &mock.instrument;

    // Test ParameterMixin - getParameterCount
    try testing.expectEqual(@as(usize, 2), inst.getParameterCount());

    // Test ParameterMixin - getParameter
    const param0 = inst.getParameter(0);
    try testing.expect(param0 != null);
    try testing.expectEqualStrings("Volume", param0.?.name);
    try testing.expectEqual(@as(f32, 0.8), param0.?.value);

    const param1 = inst.getParameter(1);
    try testing.expect(param1 != null);
    try testing.expectEqualStrings("Pan", param1.?.name);
    try testing.expectEqual(@as(f32, 0.0), param1.?.value);

    // Out of bounds should return null
    try testing.expect(inst.getParameter(2) == null);

    // Test ParameterMixin - setParameter
    inst.setParameter(0, 0.5);
    const updated_param0 = inst.getParameter(0);
    try testing.expectEqual(@as(f32, 0.5), updated_param0.?.value);

    // Test clamping
    inst.setParameter(0, 2.0); // Above max
    const clamped_param0 = inst.getParameter(0);
    try testing.expectEqual(@as(f32, 1.0), clamped_param0.?.value);

    inst.setParameter(0, -1.0); // Below min
    const clamped_param0_low = inst.getParameter(0);
    try testing.expectEqual(@as(f32, 0.0), clamped_param0_low.?.value);

    // Out of bounds setParameter should be a no-op
    inst.setParameter(10, 0.5);
    try testing.expectEqual(@as(usize, 2), inst.getParameterCount());

    // DestroyMixin is tested by the defer above - it should not leak
}
