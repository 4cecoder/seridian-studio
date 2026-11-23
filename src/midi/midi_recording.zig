//! MIDI Recording Module
//!
//! Captures MIDI events during recording and stores them as MIDI clips.

const std = @import("std");
const coremidi = @import("coremidi.zig");
const MIDIEvent = coremidi.MIDIEvent;

const log = std.log.scoped(.midi_recording);

/// A recorded MIDI note (note-on + note-off pair)
pub const MIDINote = struct {
    /// Start time relative to recording start (seconds)
    start_time: f64,
    /// Duration (seconds)
    duration: f64,
    /// MIDI note number (0-127)
    note: u7,
    /// Velocity (0-127)
    velocity: u7,
    /// MIDI channel (0-15)
    channel: u4 = 0,
};

/// Buffer for recording raw MIDI events
pub const MIDIRecordBuffer = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(RecordedEvent),
    active_notes: [16][128]?ActiveNote, // [channel][note] = active note info

    recording: bool = false,
    start_timestamp: u64 = 0,
    sample_rate: u32 = 48000,

    /// Raw recorded event with timestamp
    pub const RecordedEvent = struct {
        /// Time relative to recording start (seconds)
        time: f64,
        /// The MIDI event
        event: MIDIEvent,
    };

    /// Active note waiting for note-off
    const ActiveNote = struct {
        start_time: f64,
        velocity: u7,
    };

    pub fn init(allocator: std.mem.Allocator) MIDIRecordBuffer {
        var buf = MIDIRecordBuffer{
            .allocator = allocator,
            .events = .empty,
            .active_notes = undefined,
        };
        // Initialize active notes array
        for (&buf.active_notes) |*channel| {
            for (channel) |*note| {
                note.* = null;
            }
        }
        return buf;
    }

    pub fn deinit(self: *MIDIRecordBuffer) void {
        self.events.deinit(self.allocator);
    }

    /// Start recording
    pub fn startRecording(self: *MIDIRecordBuffer, timestamp: u64) void {
        self.recording = true;
        self.start_timestamp = timestamp;
        self.events.clearRetainingCapacity();

        // Clear active notes
        for (&self.active_notes) |*channel| {
            for (channel) |*note| {
                note.* = null;
            }
        }

        log.info("MIDI recording started", .{});
    }

    /// Stop recording and return completed notes
    pub fn stopRecording(self: *MIDIRecordBuffer, allocator: std.mem.Allocator) ![]MIDINote {
        self.recording = false;

        // Convert events to notes using ArrayListUnmanaged
        var notes: std.ArrayList(MIDINote) = .empty;
        errdefer notes.deinit(allocator);

        // Process events to extract note pairs
        var active: [16][128]?ActiveNote = undefined;
        for (&active) |*ch| {
            for (ch) |*n| n.* = null;
        }

        for (self.events.items) |rec_event| {
            switch (rec_event.event.message) {
                .note_on => |n| {
                    if (n.velocity > 0) {
                        active[rec_event.event.channel][n.note] = .{
                            .start_time = rec_event.time,
                            .velocity = n.velocity,
                        };
                    } else {
                        // velocity 0 note-on is actually note-off
                        if (active[rec_event.event.channel][n.note]) |act| {
                            try notes.append(allocator, .{
                                .start_time = act.start_time,
                                .duration = rec_event.time - act.start_time,
                                .note = n.note,
                                .velocity = act.velocity,
                                .channel = rec_event.event.channel,
                            });
                            active[rec_event.event.channel][n.note] = null;
                        }
                    }
                },
                .note_off => |n| {
                    if (active[rec_event.event.channel][n.note]) |act| {
                        try notes.append(allocator, .{
                            .start_time = act.start_time,
                            .duration = rec_event.time - act.start_time,
                            .note = n.note,
                            .velocity = act.velocity,
                            .channel = rec_event.event.channel,
                        });
                        active[rec_event.event.channel][n.note] = null;
                    }
                },
                else => {},
            }
        }

        log.info("MIDI recording stopped: {} notes captured", .{notes.items.len});
        return notes.toOwnedSlice(allocator);
    }

    /// Record an incoming MIDI event
    pub fn recordEvent(self: *MIDIRecordBuffer, event: MIDIEvent) void {
        if (!self.recording) return;

        // Calculate time relative to start
        const elapsed_samples = event.timestamp -| self.start_timestamp;
        const time = @as(f64, @floatFromInt(elapsed_samples)) / @as(f64, @floatFromInt(self.sample_rate));

        self.events.append(self.allocator, .{
            .time = time,
            .event = event,
        }) catch {
            log.warn("Failed to record MIDI event", .{});
        };
    }

    /// Get number of recorded events
    pub fn getEventCount(self: *const MIDIRecordBuffer) usize {
        return self.events.items.len;
    }

    /// Get recording duration based on last event
    pub fn getDuration(self: *const MIDIRecordBuffer) f64 {
        if (self.events.items.len == 0) return 0.0;
        return self.events.items[self.events.items.len - 1].time;
    }
};

/// MIDI Clip data (stored notes for playback)
pub const MIDIClipData = struct {
    allocator: std.mem.Allocator,
    notes: []MIDINote,

    pub fn init(allocator: std.mem.Allocator) MIDIClipData {
        return .{
            .allocator = allocator,
            .notes = &.{},
        };
    }

    pub fn deinit(self: *MIDIClipData) void {
        if (self.notes.len > 0) {
            self.allocator.free(self.notes);
        }
    }

    /// Set notes from a recording
    pub fn setNotes(self: *MIDIClipData, notes: []MIDINote) void {
        if (self.notes.len > 0) {
            self.allocator.free(self.notes);
        }
        self.notes = notes;
    }

    /// Get duration based on last note end
    pub fn getDuration(self: *const MIDIClipData) f64 {
        var max_end: f64 = 0.0;
        for (self.notes) |note| {
            const end = note.start_time + note.duration;
            if (end > max_end) max_end = end;
        }
        return max_end;
    }

    /// Get notes in a time range (for playback)
    /// Note: Returns all notes - caller should filter using time range
    pub fn getNotesInRange(self: *const MIDIClipData, start: f64, end: f64) []const MIDINote {
        _ = start;
        _ = end;
        // For now, return all notes - caller filters by time
        return self.notes;
    }
};

// =============================================================================
// C API
// =============================================================================

var g_midi_recorder: ?*MIDIRecordBuffer = null;
var g_allocator: ?std.mem.Allocator = null;

/// Initialize MIDI recording
pub export fn midi_recording_init() callconv(.c) c_int {
    if (g_midi_recorder != null) return 0;

    // Use page allocator for long-lived global state
    // (Don't use a local GPA that goes out of scope!)
    g_allocator = std.heap.page_allocator;

    const rec = g_allocator.?.create(MIDIRecordBuffer) catch return -1;
    rec.* = MIDIRecordBuffer.init(g_allocator.?);
    g_midi_recorder = rec;

    log.info("MIDI recording system initialized", .{});
    return 0;
}

/// Start MIDI recording
pub export fn midi_recording_start(timestamp: u64) callconv(.c) c_int {
    const rec = g_midi_recorder orelse return -1;
    rec.startRecording(timestamp);
    return 0;
}

/// Stop MIDI recording
pub export fn midi_recording_stop() callconv(.c) c_int {
    const rec = g_midi_recorder orelse return -1;
    rec.recording = false;
    return 0;
}

/// Check if MIDI recording is active
pub export fn midi_recording_is_active() callconv(.c) c_int {
    const rec = g_midi_recorder orelse return 0;
    return if (rec.recording) 1 else 0;
}

/// Get number of recorded events
pub export fn midi_recording_get_event_count() callconv(.c) c_int {
    const rec = g_midi_recorder orelse return 0;
    return @intCast(rec.getEventCount());
}

/// Get recording duration
pub export fn midi_recording_get_duration() callconv(.c) f64 {
    const rec = g_midi_recorder orelse return 0.0;
    return rec.getDuration();
}

/// Record a MIDI note on event (called from MIDI callback)
pub export fn midi_recording_note_on(timestamp: u64, channel: u8, note: u8, velocity: u8) callconv(.c) void {
    const rec = g_midi_recorder orelse return;

    const event = MIDIEvent{
        .timestamp = timestamp,
        .channel = @intCast(channel & 0x0F),
        .message = .{ .note_on = .{
            .note = @intCast(note & 0x7F),
            .velocity = @intCast(velocity & 0x7F),
        } },
    };

    rec.recordEvent(event);
}

/// Record a MIDI note off event
pub export fn midi_recording_note_off(timestamp: u64, channel: u8, note: u8, velocity: u8) callconv(.c) void {
    const rec = g_midi_recorder orelse return;

    const event = MIDIEvent{
        .timestamp = timestamp,
        .channel = @intCast(channel & 0x0F),
        .message = .{ .note_off = .{
            .note = @intCast(note & 0x7F),
            .velocity = @intCast(velocity & 0x7F),
        } },
    };

    rec.recordEvent(event);
}

// =============================================================================
// Tests
// =============================================================================

test "midi record buffer basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = MIDIRecordBuffer.init(allocator);
    defer buf.deinit();

    // Initially not recording
    try testing.expect(!buf.recording);
    try testing.expectEqual(@as(usize, 0), buf.getEventCount());
    try testing.expectApproxEqAbs(@as(f64, 0.0), buf.getDuration(), 0.001);

    // Start recording
    buf.startRecording(0);
    try testing.expect(buf.recording);

    // Record some events
    buf.recordEvent(.{
        .timestamp = 0,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    });

    buf.recordEvent(.{
        .timestamp = 48000, // 1 second at 48kHz
        .channel = 0,
        .message = .{ .note_off = .{ .note = 60, .velocity = 0 } },
    });

    try testing.expectEqual(@as(usize, 2), buf.getEventCount());
    try testing.expectApproxEqAbs(@as(f64, 1.0), buf.getDuration(), 0.001);
}

test "midi record buffer note extraction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = MIDIRecordBuffer.init(allocator);
    defer buf.deinit();

    buf.startRecording(0);

    // Play C4 (note 60) from 0-1 second
    buf.recordEvent(.{
        .timestamp = 0,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 80 } },
    });
    buf.recordEvent(.{
        .timestamp = 48000,
        .channel = 0,
        .message = .{ .note_off = .{ .note = 60, .velocity = 0 } },
    });

    // Play E4 (note 64) from 0.5-1.5 seconds (overlapping)
    buf.recordEvent(.{
        .timestamp = 24000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 64, .velocity = 90 } },
    });
    buf.recordEvent(.{
        .timestamp = 72000,
        .channel = 0,
        .message = .{ .note_off = .{ .note = 64, .velocity = 0 } },
    });

    // Stop and extract notes
    const notes = try buf.stopRecording(allocator);
    defer allocator.free(notes);

    try testing.expectEqual(@as(usize, 2), notes.len);

    // Check first note (C4)
    try testing.expectEqual(@as(u7, 60), notes[0].note);
    try testing.expectEqual(@as(u7, 80), notes[0].velocity);
    try testing.expectApproxEqAbs(@as(f64, 0.0), notes[0].start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), notes[0].duration, 0.001);

    // Check second note (E4)
    try testing.expectEqual(@as(u7, 64), notes[1].note);
    try testing.expectEqual(@as(u7, 90), notes[1].velocity);
    try testing.expectApproxEqAbs(@as(f64, 0.5), notes[1].start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), notes[1].duration, 0.001);
}

test "midi record buffer velocity zero note-off" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = MIDIRecordBuffer.init(allocator);
    defer buf.deinit();

    buf.startRecording(0);

    // Note-on
    buf.recordEvent(.{
        .timestamp = 0,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    });

    // Note-off as velocity-0 note-on (common in MIDI)
    buf.recordEvent(.{
        .timestamp = 24000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 0 } },
    });

    // Verify events recorded
    try testing.expectEqual(@as(usize, 2), buf.getEventCount());

    const notes = try buf.stopRecording(allocator);
    defer allocator.free(notes);

    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(@as(u7, 60), notes[0].note);
    try testing.expectApproxEqAbs(@as(f64, 0.5), notes[0].duration, 0.001);
}

test "midi record buffer multi-channel" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = MIDIRecordBuffer.init(allocator);
    defer buf.deinit();

    buf.startRecording(0);

    // Same note on different channels
    buf.recordEvent(.{ .timestamp = 0, .channel = 0, .message = .{ .note_on = .{ .note = 60, .velocity = 80 } } });
    buf.recordEvent(.{ .timestamp = 0, .channel = 1, .message = .{ .note_on = .{ .note = 60, .velocity = 90 } } });

    buf.recordEvent(.{ .timestamp = 48000, .channel = 0, .message = .{ .note_off = .{ .note = 60, .velocity = 0 } } });
    buf.recordEvent(.{ .timestamp = 96000, .channel = 1, .message = .{ .note_off = .{ .note = 60, .velocity = 0 } } });

    const notes = try buf.stopRecording(allocator);
    defer allocator.free(notes);

    try testing.expectEqual(@as(usize, 2), notes.len);

    // Channel 0 note
    try testing.expectEqual(@as(u4, 0), notes[0].channel);
    try testing.expectApproxEqAbs(@as(f64, 1.0), notes[0].duration, 0.001);

    // Channel 1 note
    try testing.expectEqual(@as(u4, 1), notes[1].channel);
    try testing.expectApproxEqAbs(@as(f64, 2.0), notes[1].duration, 0.001);
}

test "midi record buffer ignores events when not recording" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = MIDIRecordBuffer.init(allocator);
    defer buf.deinit();

    // Record event before starting (should be ignored)
    buf.recordEvent(.{
        .timestamp = 0,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    });

    try testing.expectEqual(@as(usize, 0), buf.getEventCount());

    // Now start and record
    buf.startRecording(1000);
    buf.recordEvent(.{
        .timestamp = 1000,
        .channel = 0,
        .message = .{ .note_on = .{ .note = 60, .velocity = 100 } },
    });

    try testing.expectEqual(@as(usize, 1), buf.getEventCount());
}

test "midi clip data duration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var clip = MIDIClipData.init(allocator);
    defer clip.deinit();

    // Empty clip has 0 duration
    try testing.expectApproxEqAbs(@as(f64, 0.0), clip.getDuration(), 0.001);

    // Create some notes
    var notes = try allocator.alloc(MIDINote, 3);
    notes[0] = .{ .start_time = 0.0, .duration = 1.0, .note = 60, .velocity = 100 };
    notes[1] = .{ .start_time = 0.5, .duration = 2.0, .note = 64, .velocity = 100 }; // Ends at 2.5
    notes[2] = .{ .start_time = 1.0, .duration = 0.5, .note = 67, .velocity = 100 }; // Ends at 1.5

    clip.setNotes(notes);

    // Duration should be max end time (2.5)
    try testing.expectApproxEqAbs(@as(f64, 2.5), clip.getDuration(), 0.001);
}

test "midi note struct" {
    const testing = std.testing;

    const note = MIDINote{
        .start_time = 1.5,
        .duration = 0.25,
        .note = 72,
        .velocity = 100,
        .channel = 5,
    };

    try testing.expectApproxEqAbs(@as(f64, 1.5), note.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.25), note.duration, 0.001);
    try testing.expectEqual(@as(u7, 72), note.note);
    try testing.expectEqual(@as(u7, 100), note.velocity);
    try testing.expectEqual(@as(u4, 5), note.channel);
}
