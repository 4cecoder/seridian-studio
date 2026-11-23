//! Bounded lock-free multi-producer, single-consumer queue of note events for the audio thread.
//!
//! Every thread that wants to play or stop a note (the UI for audition, the CLI socket, a MIDI
//! backend thread) pushes here; only the audio thread pops, at the start of each block, and only
//! the audio thread touches instrument voices. Producers claim a slot with a compare-and-swap on
//! the write index (Vyukov's bounded queue); the consumer never waits and never blocks a producer.
//! No allocation: the slots are a fixed array. A full queue drops the new event and counts it.

const std = @import("std");

/// What a queued event does to a track's instrument.
pub const Kind = enum(u8) {
    note_on,
    note_off,
    all_notes_off,
};

/// One event for one track. `note` and `velocity` are ignored by `all_notes_off`.
pub const Event = struct {
    track: u8,
    kind: Kind,
    note: u8 = 0,
    velocity: u8 = 0,
};

/// Queue capacity in events (power of two).
pub const CAPACITY = 1024;

const Cell = struct {
    /// Equals the slot's position when free for that position, position + 1 once filled.
    sequence: std.atomic.Value(usize),
    event: Event,
};

fn initialCells() [CAPACITY]Cell {
    @setEvalBranchQuota(CAPACITY * 4);
    var cells: [CAPACITY]Cell = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{ .sequence = std.atomic.Value(usize).init(i), .event = .{ .track = 0, .kind = .note_off } };
    }
    return cells;
}

pub const EventQueue = struct {
    cells: [CAPACITY]Cell = initialCells(),
    /// Next position a producer claims.
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Next position the consumer reads (consumer thread only).
    read_pos: usize = 0,
    /// Events refused because the queue was full.
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    comptime {
        std.debug.assert(std.math.isPowerOfTwo(CAPACITY));
    }

    /// Producer side, any thread. Returns false (and counts a drop) when the queue is full.
    pub fn push(self: *EventQueue, event: Event) bool {
        var pos = self.write_pos.load(.monotonic);
        while (true) {
            const cell = &self.cells[pos & (CAPACITY - 1)];
            const sequence = cell.sequence.load(.acquire);
            const diff: isize = @bitCast(sequence -% pos);
            if (diff == 0) {
                if (self.write_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                cell.event = event;
                cell.sequence.store(pos +% 1, .release);
                return true;
            } else if (diff < 0) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            } else {
                pos = self.write_pos.load(.monotonic);
            }
        }
    }

    /// Consumer side (the audio thread only). Returns null when nothing is ready.
    pub fn pop(self: *EventQueue) ?Event {
        const pos = self.read_pos;
        const cell = &self.cells[pos & (CAPACITY - 1)];
        if (cell.sequence.load(.acquire) != pos +% 1) return null;
        const event = cell.event;
        cell.sequence.store(pos +% CAPACITY, .release);
        self.read_pos = pos +% 1;
        return event;
    }
};

test "EventQueue: pops in push order and reports empty" {
    var queue: EventQueue = .{};
    try std.testing.expectEqual(@as(?Event, null), queue.pop());
    try std.testing.expect(queue.push(.{ .track = 1, .kind = .note_on, .note = 60, .velocity = 100 }));
    try std.testing.expect(queue.push(.{ .track = 1, .kind = .note_off, .note = 60 }));
    try std.testing.expect(queue.push(.{ .track = 3, .kind = .all_notes_off }));
    const a = queue.pop().?;
    try std.testing.expectEqual(Kind.note_on, a.kind);
    try std.testing.expectEqual(@as(u8, 100), a.velocity);
    try std.testing.expectEqual(Kind.note_off, queue.pop().?.kind);
    try std.testing.expectEqual(@as(u8, 3), queue.pop().?.track);
    try std.testing.expectEqual(@as(?Event, null), queue.pop());
}

test "EventQueue: drops new events when full and wraps after draining" {
    var queue: EventQueue = .{};
    for (0..CAPACITY) |i| {
        try std.testing.expect(queue.push(.{ .track = 0, .kind = .note_on, .note = @intCast(i % 128) }));
    }
    try std.testing.expect(!queue.push(.{ .track = 0, .kind = .note_on, .note = 1 }));
    try std.testing.expectEqual(@as(u64, 1), queue.dropped.load(.monotonic));
    for (0..CAPACITY) |i| try std.testing.expectEqual(@as(u8, @intCast(i % 128)), queue.pop().?.note);
    try std.testing.expectEqual(@as(?Event, null), queue.pop());
    for (0..3 * CAPACITY) |i| {
        try std.testing.expect(queue.push(.{ .track = 0, .kind = .note_on, .note = @intCast(i % 128) }));
        try std.testing.expectEqual(@as(u8, @intCast(i % 128)), queue.pop().?.note);
    }
}

test "EventQueue: concurrent producers lose nothing and keep per-producer order" {
    const producers = 4;
    const per_producer = 20_000;
    const Ctx = struct {
        queue: *EventQueue,
        id: u8,
        fn run(ctx: @This()) void {
            var i: usize = 0;
            while (i < per_producer) {
                // The note carries the low bits of the sequence number; order is checked per track.
                if (ctx.queue.push(.{ .track = ctx.id, .kind = .note_on, .note = @intCast(i % 128) })) {
                    i += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };
    var queue: EventQueue = .{};
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .queue = &queue, .id = @intCast(id) }});

    var received: [producers]usize = @splat(0);
    var total: usize = 0;
    while (total < producers * per_producer) {
        const event = queue.pop() orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        try std.testing.expectEqual(@as(u8, @intCast(received[event.track] % 128)), event.note);
        received[event.track] += 1;
        total += 1;
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(?Event, null), queue.pop());
    for (received) |n| try std.testing.expectEqual(@as(usize, per_producer), n);
}
