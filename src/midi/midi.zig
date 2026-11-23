const std = @import("std");
const builtin = @import("builtin");

pub const coremidi = @import("coremidi.zig");
pub const MIDIEvent = coremidi.MIDIEvent;

const log = std.log.scoped(.midi);

/// Platform-agnostic MIDI backend
pub const MIDIBackend = union(enum) {
    coremidi: coremidi.CoreMIDIBackend,
    none: void,

    pub fn init(allocator: std.mem.Allocator) !MIDIBackend {
        if (builtin.os.tag == .macos) {
            log.info("Initializing CoreMIDI backend", .{});
            return .{ .coremidi = try coremidi.CoreMIDIBackend.init(allocator) };
        }

        log.warn("No MIDI backend available for this platform", .{});
        return .{ .none = {} };
    }

    pub fn deinit(self: *MIDIBackend) void {
        switch (self.*) {
            .coremidi => |*cm| cm.deinit(),
            .none => {},
        }
    }

    pub fn connectAllSources(self: *MIDIBackend) !void {
        switch (self.*) {
            .coremidi => |*cm| try cm.connectAllSources(),
            .none => {},
        }
    }

    pub fn getSourceCount(self: *const MIDIBackend) usize {
        switch (self.*) {
            .coremidi => return coremidi.CoreMIDIBackend.getSourceCount(),
            .none => return 0,
        }
    }

    pub fn getDestinationCount(self: *const MIDIBackend) usize {
        switch (self.*) {
            .coremidi => return coremidi.CoreMIDIBackend.getDestinationCount(),
            .none => return 0,
        }
    }

    pub fn setEventCallback(
        self: *MIDIBackend,
        callback: *const fn (event: MIDIEvent, user_data: ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        switch (self.*) {
            .coremidi => |*cm| cm.setEventCallback(callback, user_data),
            .none => {},
        }
    }

    pub fn pollEvents(self: *MIDIBackend, buffer: []MIDIEvent) usize {
        switch (self.*) {
            .coremidi => |*cm| return cm.pollEvents(buffer),
            .none => return 0,
        }
    }

    pub fn sendNoteOn(self: *MIDIBackend, dest: usize, channel: u4, note: u7, velocity: u7) !void {
        switch (self.*) {
            .coremidi => |*cm| try cm.sendNoteOn(dest, channel, note, velocity),
            .none => return error.NoMIDIBackend,
        }
    }

    pub fn sendNoteOff(self: *MIDIBackend, dest: usize, channel: u4, note: u7, velocity: u7) !void {
        switch (self.*) {
            .coremidi => |*cm| try cm.sendNoteOff(dest, channel, note, velocity),
            .none => return error.NoMIDIBackend,
        }
    }

    pub fn isAvailable(self: *const MIDIBackend) bool {
        return self.* != .none;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MIDIBackend.isAvailable - none backend should be unavailable" {
    const backend = MIDIBackend{ .none = {} };
    try std.testing.expect(!backend.isAvailable());
}

test "MIDIBackend.isAvailable - coremidi backend should be available" {
    const allocator = std.testing.allocator;

    // Create a mock CoreMIDI backend struct
    const mock_backend = coremidi.CoreMIDIBackend{
        .allocator = allocator,
    };

    const backend = MIDIBackend{ .coremidi = mock_backend };
    try std.testing.expect(backend.isAvailable());
}

test "MIDIBackend.getSourceCount - none backend returns zero" {
    const backend = MIDIBackend{ .none = {} };
    try std.testing.expectEqual(@as(usize, 0), backend.getSourceCount());
}

test "MIDIBackend.getDestinationCount - none backend returns zero" {
    const backend = MIDIBackend{ .none = {} };
    try std.testing.expectEqual(@as(usize, 0), backend.getDestinationCount());
}

test "MIDIBackend.pollEvents - none backend returns zero events" {
    var backend = MIDIBackend{ .none = {} };
    var buffer: [10]MIDIEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), backend.pollEvents(&buffer));
}

test "MIDIBackend.sendNoteOn - none backend returns error" {
    var backend = MIDIBackend{ .none = {} };
    try std.testing.expectError(error.NoMIDIBackend, backend.sendNoteOn(0, 0, 60, 100));
}

test "MIDIBackend.sendNoteOff - none backend returns error" {
    var backend = MIDIBackend{ .none = {} };
    try std.testing.expectError(error.NoMIDIBackend, backend.sendNoteOff(0, 0, 60, 100));
}

test "MIDIBackend platform detection" {
    // Test that platform detection works correctly
    // On macOS, we should get coremidi backend (if init succeeds)
    // On other platforms, we should get none backend
    if (builtin.os.tag == .macos) {
        // We can't easily test the actual init without CoreMIDI hardware,
        // but we can verify that detectCoreMIDI returns true
        try std.testing.expect(coremidi.detectCoreMIDI());
    } else {
        try std.testing.expect(!coremidi.detectCoreMIDI());
    }
}
