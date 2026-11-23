//! Fixed-size single-producer single-consumer ring of MIDI note events.
//! The producer is the MIDI poll thread, the consumer is the audio thread.
//! No allocation, no locks: indices are atomics. A full ring drops the new event.

const std = @import("std");

/// One note event from a hardware MIDI input.
pub const NoteEvent = struct {
    note: u8,
    velocity: u8,
    on: bool,
};

/// Ring capacity in events (power of two).
pub const NOTE_RING_CAPACITY = 256;

pub const NoteRing = struct {
    buf: [NOTE_RING_CAPACITY]NoteEvent = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // next write (producer)
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // next read (consumer)
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Producer side. Returns false (and counts a drop) when the ring is full.
    pub fn push(self: *NoteRing, ev: NoteEvent) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head -% tail >= NOTE_RING_CAPACITY) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        self.buf[head % NOTE_RING_CAPACITY] = ev;
        self.head.store(head +% 1, .release);
        return true;
    }

    /// Consumer side. Returns null when empty.
    pub fn pop(self: *NoteRing) ?NoteEvent {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail == head) return null;
        const ev = self.buf[tail % NOTE_RING_CAPACITY];
        self.tail.store(tail +% 1, .release);
        return ev;
    }
};

test "NoteRing: pushes and pops in order" {
    var ring: NoteRing = .{};
    try std.testing.expectEqual(@as(?NoteEvent, null), ring.pop());
    try std.testing.expect(ring.push(.{ .note = 60, .velocity = 100, .on = true }));
    try std.testing.expect(ring.push(.{ .note = 62, .velocity = 90, .on = true }));
    try std.testing.expect(ring.push(.{ .note = 60, .velocity = 0, .on = false }));
    const a = ring.pop().?;
    try std.testing.expectEqual(@as(u8, 60), a.note);
    try std.testing.expect(a.on);
    const b = ring.pop().?;
    try std.testing.expectEqual(@as(u8, 62), b.note);
    const c = ring.pop().?;
    try std.testing.expect(!c.on);
    try std.testing.expectEqual(@as(?NoteEvent, null), ring.pop());
}

test "NoteRing: drops new events when full" {
    var ring: NoteRing = .{};
    for (0..NOTE_RING_CAPACITY) |i| {
        try std.testing.expect(ring.push(.{ .note = @intCast(i % 128), .velocity = 1, .on = true }));
    }
    try std.testing.expect(!ring.push(.{ .note = 99, .velocity = 1, .on = true }));
    try std.testing.expectEqual(@as(u64, 1), ring.dropped.load(.monotonic));
    // Oldest events are kept, in order.
    for (0..NOTE_RING_CAPACITY) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i % 128)), ring.pop().?.note);
    }
    try std.testing.expectEqual(@as(?NoteEvent, null), ring.pop());
    // Wraps around after draining.
    try std.testing.expect(ring.push(.{ .note = 5, .velocity = 1, .on = true }));
    try std.testing.expectEqual(@as(u8, 5), ring.pop().?.note);
}
