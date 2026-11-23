//! Single-producer, single-consumer ring with a fixed capacity, for handing
//! items between the control thread and the audio thread without locks.
//!
//! Acquire/release atomics: the producer publishes `tail` with release after
//! writing the slot; the consumer reads `tail` with acquire before reading the
//! slot. `head`/`tail` count positions without wrapping (`.%`), so a lagging
//! reader cannot alias a live slot.

const std = @import("std");
const testing = std.testing;

pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        /// Next slot to pop. Written by the consumer only.
        head: std.atomic.Value(usize) = .init(0),
        /// Next slot to push. Written by the producer only.
        tail: std.atomic.Value(usize) = .init(0),

        /// Producer side. Returns false when full; the item is not taken.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail -% head == capacity) return false;
            self.items[tail % capacity] = item;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Consumer side. Returns null when empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            const item = self.items[head % capacity];
            self.head.store(head +% 1, .release);
            return item;
        }

        /// Consumer side. Looks at the next item without consuming it.
        pub fn peek(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            return self.items[head % capacity];
        }

        /// Number of items between the consumer and producer cursors.
        pub fn len(self: *const Self) usize {
            return self.tail.load(.acquire) -% self.head.load(.acquire);
        }
    };
}

test "SpscQueue: FIFO order, full on capacity, empty after drain" {
    var q: SpscQueue(u32, 2) = .{};
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expectEqual(@as(?u32, null), q.peek());

    try testing.expect(q.push(1));
    try testing.expect(q.push(2));
    try testing.expect(!q.push(3)); // full
    try testing.expectEqual(@as(usize, 2), q.len());
    try testing.expectEqual(@as(?u32, 1), q.peek());

    try testing.expectEqual(@as(?u32, 1), q.pop());
    try testing.expectEqual(@as(?u32, 2), q.pop());
    try testing.expectEqual(@as(?u32, null), q.pop()); // empty
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "SpscQueue: keeps FIFO order across the wrap-around" {
    var q: SpscQueue(u64, 3) = .{};
    var sent: u64 = 0;
    var got: u64 = 0;
    // Push and pop in lockstep well past the capacity so both cursors wrap.
    while (sent < 10_000) : (sent += 1) {
        try testing.expect(q.push(sent));
        try testing.expectEqual(sent, q.pop().?);
        got += 1;
    }
    try testing.expectEqual(@as(u64, 10_000), got);
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "SpscQueue: producer and consumer threads keep order" {
    // Small capacity, far more items than slots: every hand-off goes through
    // the ring while both cursors wrap many times.
    const total = 50_000;
    const Q = SpscQueue(u64, 17);
    var queue: Q = .{};

    const Producer = struct {
        fn run(q: *Q) void {
            var n: u64 = 0;
            while (n < total) {
                if (q.push(n)) n += 1;
            }
        }
    };
    const Consumer = struct {
        first_bad: u64 = std.math.maxInt(u64),
        fn run(q: *Q, self: *@This()) void {
            var n: u64 = 0;
            while (n < total) {
                if (q.pop()) |item| {
                    if (item != n) {
                        self.first_bad = item;
                        return;
                    }
                    n += 1;
                }
            }
        }
    };

    var consumer_state: Consumer = .{};
    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &queue, &consumer_state });
    const producer = try std.Thread.spawn(.{}, Producer.run, .{&queue});
    producer.join();
    consumer.join();

    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), consumer_state.first_bad);

    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expectEqual(@as(?u64, null), queue.pop());
}
