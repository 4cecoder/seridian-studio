//! Sample-offset events delivered to a plugin's `process` call.
//!
//! Replaces the Rust per-event methods (`note_on`, `note_off`, `midi`) with one
//! sorted list per block. `EventList` is allocated once (in `init`, called from the
//! host's prepare step); `push` never grows it and never allocates, so it is safe
//! on the audio thread. Core has no event or queue type yet, so this file defines
//! the model for plugin hosting.

const std = @import("std");
const testing = std.testing;

/// One event at a sample offset within the next block.
pub const Event = struct {
    /// Sample offset from the start of the block.
    offset: u32,
    kind: Kind,

    pub const NoteOn = struct { note: u8, velocity: u8 };

    /// A dense parameter index (see `PluginInfo.params`) and its new value in
    /// SoundCraft units.
    pub const ParamChange = struct { index: u32, value: f32 };

    pub const Kind = union(enum) {
        note_on: NoteOn,
        note_off: u8,
        /// Any other MIDI 1.0 channel message: control change, pitch bend, pressure,
        /// program change.
        midi3: [3]u8,
        param: ParamChange,
    };
};

/// Fixed-capacity event list. Storage is allocated by `init` and kept until
/// `deinit`; `push` returns false when full instead of growing.
pub const EventList = struct {
    buf: []Event,
    len: usize = 0,

    /// Control thread (prepare). Allocates the storage once.
    pub fn init(gpa: std.mem.Allocator, max_events: usize) std.mem.Allocator.Error!EventList {
        const buf = try gpa.alloc(Event, max_events);
        return .{ .buf = buf, .len = 0 };
    }

    /// Control thread.
    pub fn deinit(self: *EventList, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.buf = &.{};
        self.len = 0;
    }

    /// Audio thread safe: no allocation, no locks. Keeps the list sorted by offset;
    /// events with equal offsets stay in arrival order. Returns false, leaving the
    /// list unchanged, when it is full.
    pub fn push(self: *EventList, ev: Event) bool {
        if (self.len == self.buf.len) return false;
        var i = self.len;
        while (i > 0 and self.buf[i - 1].offset > ev.offset) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[i] = ev;
        self.len += 1;
        return true;
    }

    /// Empties the list for the next block; keeps its capacity.
    pub fn clear(self: *EventList) void {
        self.len = 0;
    }

    pub fn capacity(self: *const EventList) usize {
        return self.buf.len;
    }

    /// The events pushed since the last `clear`, in offset order.
    pub fn items(self: *const EventList) []const Event {
        return self.buf[0..self.len];
    }
};

test "EventList keeps events sorted by offset" {
    var list = try EventList.init(testing.allocator, 8);
    defer list.deinit(testing.allocator);

    try testing.expect(list.push(.{ .offset = 5, .kind = .{ .note_off = 60 } }));
    try testing.expect(list.push(.{ .offset = 1, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } }));
    try testing.expect(list.push(.{ .offset = 3, .kind = .{ .midi3 = .{ 0xB0, 1, 64 } } }));
    try testing.expect(list.push(.{ .offset = 0, .kind = .{ .param = .{ .index = 2, .value = 0.5 } } }));

    const items = list.items();
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqual(@as(u32, 0), items[0].offset);
    try testing.expectEqual(@as(u32, 1), items[1].offset);
    try testing.expectEqual(@as(u32, 3), items[2].offset);
    try testing.expectEqual(@as(u32, 5), items[3].offset);
    try testing.expect(items[1].kind == .note_on);
    try testing.expect(items[3].kind == .note_off);
}

test "EventList keeps equal offsets in arrival order" {
    var list = try EventList.init(testing.allocator, 4);
    defer list.deinit(testing.allocator);

    try testing.expect(list.push(.{ .offset = 7, .kind = .{ .note_off = 1 } }));
    try testing.expect(list.push(.{ .offset = 7, .kind = .{ .note_off = 2 } }));
    try testing.expect(list.push(.{ .offset = 7, .kind = .{ .note_off = 3 } }));

    const items = list.items();
    try testing.expectEqual(@as(u8, 1), items[0].kind.note_off);
    try testing.expectEqual(@as(u8, 2), items[1].kind.note_off);
    try testing.expectEqual(@as(u8, 3), items[2].kind.note_off);
}

test "EventList push returns false when full and does not grow" {
    var list = try EventList.init(testing.allocator, 2);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), list.capacity());
    try testing.expect(list.push(.{ .offset = 10, .kind = .{ .note_off = 60 } }));
    try testing.expect(list.push(.{ .offset = 20, .kind = .{ .note_off = 61 } }));

    // Full: the event is refused, and an earlier-offset event is refused too
    // instead of evicting anything.
    try testing.expect(!list.push(.{ .offset = 0, .kind = .{ .note_off = 62 } }));
    try testing.expect(!list.push(.{ .offset = 30, .kind = .{ .note_off = 63 } }));
    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expectEqual(@as(u32, 10), list.items()[0].offset);
    try testing.expectEqual(@as(u32, 20), list.items()[1].offset);
    try testing.expectEqual(@as(usize, 2), list.buf.len);
}

test "EventList clear keeps capacity and accepts events again" {
    var list = try EventList.init(testing.allocator, 1);
    defer list.deinit(testing.allocator);

    try testing.expect(list.push(.{ .offset = 0, .kind = .{ .note_off = 60 } }));
    try testing.expect(!list.push(.{ .offset = 0, .kind = .{ .note_off = 61 } }));
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.items().len);
    try testing.expect(list.push(.{ .offset = 4, .kind = .{ .note_off = 62 } }));
    try testing.expectEqual(@as(usize, 1), list.capacity());
}

test "an empty EventList has no items and a zero capacity" {
    var list = try EventList.init(testing.allocator, 0);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), list.items().len);
    try testing.expect(!list.push(.{ .offset = 0, .kind = .{ .note_off = 60 } }));
}
