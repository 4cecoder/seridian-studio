// Translated to Zig from soundcraft/crates/mix/src/instances.rs, soundcraft/crates/mix/src/lib.rs, soundcraft/crates/mix/src/strip.rs, soundcraft/crates/mix/src/tests.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Plugin instance handoff, graph side.
//!
//! Third-party plugins are expensive to create and destroy, so they never touch the audio
//! thread. The flow is:
//!
//! 1. The control thread creates and prepares an instance (plughost), then calls
//!    [`SlotTable.adopt`], which pushes a [`PreparedInstance`] onto a preallocated SPSC queue.
//! 2. The audio thread calls [`SlotTable.service`] once per block. It consumes adopted
//!    instances into their slots, retiring whatever they replace.
//! 3. A processor that leaves a slot (replaced, removed, track deleted) is pushed onto a
//!    preallocated retire SPSC queue. The control thread calls [`SlotTable.takeRetired`] and
//!    destroys it. Nothing is freed or torn down on the audio thread.
//! 4. If the retire queue is full, the processor parks in its cell's `zombie` field and
//!    `service` retries it next block. The audio thread never blocks.
//!
//! The slot table is fixed capacity (`max_tracks` rows of `max_inserts + 1` cells, the last
//! cell being the instrument). Rows are found by a bounded linear scan; nothing is allocated
//! and no hash map is rebuilt per block.
//!
//! Slot-index convention (same as SoundCraft): an insert uses its index, the instrument uses
//! [`INSTRUMENT_SLOT`].
//!
//! Thread roles (each SPSC queue has exactly one producer and one consumer):
//! - `adopt_q`: control produces, audio consumes.
//! - `retire_q`: audio produces, control consumes.
//! `drainPlugins` takes both consumer roles and every cell, so it is only legal once the
//! audio thread no longer touches the table (engine replacement, stream stopped).

const std = @import("std");
const processor = @import("processor.zig");

pub const Processor = processor.Processor;

/// Graph-local track identifier. The session maps its track ids onto this.
pub const TrackId = u32;

/// Slot index used for a track's instrument plugin (insert slots use their index).
pub const INSTRUMENT_SLOT: usize = std.math.maxInt(usize);

/// Insert slots per track in SoundCraft's mixer (`INSERT_SLOTS`).
pub const INSERT_SLOTS: usize = 10;

/// A third-party plugin a session needs: which track and slot, which plugin, how many
/// channels, and the state to restore. The control thread turns this into an instance.
pub const InstanceSpec = struct {
    track: TrackId,
    /// Insert slot index, or [`INSTRUMENT_SLOT`].
    slot: usize,
    id: []const u8,
    /// Channel count the instance is prepared for.
    ch: usize,
    /// Decoded insert state, if any.
    state: ?[]const u8 = null,
};

/// A processor created and prepared off the audio thread, handed to [`SlotTable.adopt`].
pub const PreparedInstance = struct {
    track: TrackId,
    slot: usize,
    processor: Processor,
    /// Channel count the processor was prepared for.
    channels: usize,
};

/// How often a track's plugins were taken out of the signal path for putting out NaN or
/// infinity. Each stays out until the engine is next reset.
pub const PluginFailures = struct {
    /// Only grows.
    count: u32 = 0,
    /// The slot of the latest: an insert index or [`INSTRUMENT_SLOT`].
    last: usize = 0,

    pub fn record(self: *PluginFailures, slot: usize) void {
        self.count +%= 1;
        self.last = slot;
    }
};

/// Single-producer, single-consumer ring with a fixed capacity. Acquire/release atomics:
/// the producer publishes `tail` with release after writing the slot; the consumer reads
/// `tail` with acquire before reading the slot.
// TODO(core): replace with core.SpscQueue once libs/core exports it.
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

        pub fn len(self: *const Self) usize {
            return self.tail.load(.acquire) -% self.head.load(.acquire);
        }
    };
}

/// Fixed-capacity table of plugin slots for up to `max_tracks` tracks, each with
/// `max_inserts` insert slots and one instrument cell.
pub fn SlotTable(comptime max_tracks: usize, comptime max_inserts: usize, comptime queue_capacity: usize) type {
    comptime std.debug.assert(max_tracks > 0 and max_inserts > 0);
    const cells_per_track = max_inserts + 1;
    const cells_total = max_tracks * cells_per_track;

    return struct {
        const Self = @This();

        /// Upper bound on what `drainPlugins` can hand back: one occupant and one zombie per
        /// cell, plus both queues.
        pub const max_drained = 2 * cells_total + 2 * queue_capacity;

        pub const Cell = struct {
            /// The processor the audio thread renders with.
            processor: ?Processor = null,
            /// Channel count `processor` was prepared for.
            channels: usize = 0,
            /// Channel count the session wants here. 0 means no plugin is wanted.
            want: usize = 0,
            /// Output went non-finite: taken out of the signal path until reset.
            failed: bool = false,
            /// A retired processor whose push to a full retire queue failed. Retried every block.
            zombie: ?Processor = null,
        };

        pub const Row = struct {
            bound: bool = false,
            track: TrackId = 0,
            failures: PluginFailures = .{},
            cells: [cells_per_track]Cell = @splat(Cell{}),
        };

        rows: [max_tracks]Row = @splat(Row{}),
        adopt_q: SpscQueue(PreparedInstance, queue_capacity) = .{},
        retire_q: SpscQueue(Processor, queue_capacity) = .{},
        /// Set by the host (see [`setExternalInstances`]). The table never creates instances.
        external: bool = false,

        // ----- control thread -----

        /// Realtime mode flag, as in SoundCraft's `set_external_instances`. This table never
        /// creates plugins itself, so the flag is recorded for the host and does not change
        /// adoption or retirement.
        pub fn setExternalInstances(self: *Self, on: bool) void {
            self.external = on;
        }

        pub fn externalInstances(self: *const Self) bool {
            return self.external;
        }

        /// Hands an instance to the audio thread. On `error.QueueFull` the caller still owns it.
        pub fn adopt(self: *Self, instance: PreparedInstance) error{QueueFull}!void {
            if (!self.adopt_q.push(instance)) return error.QueueFull;
        }

        /// Moves retired processors into `out` and returns how many. Anything beyond
        /// `out.len` stays queued for the next call. Each returned processor must be
        /// destroyed here, on the control thread.
        pub fn takeRetired(self: *Self, out: []Processor) usize {
            var n: usize = 0;
            while (n < out.len) : (n += 1) {
                out[n] = self.retire_q.pop() orelse break;
            }
            return n;
        }

        /// Takes back everything the table holds: installed and zombie processors, pending
        /// adoptions, and retired ones. Leaves the table empty. Requires `out.len >=
        /// max_drained` and that the audio thread no longer touches this table.
        pub fn drainPlugins(self: *Self, out: []Processor) error{BufferTooSmall}!usize {
            if (out.len < max_drained) return error.BufferTooSmall;
            var n: usize = 0;
            while (self.retire_q.pop()) |p| : (n += 1) out[n] = p;
            while (self.adopt_q.pop()) |a| : (n += 1) out[n] = a.processor;
            for (&self.rows) |*row| {
                for (&row.cells) |*cell| {
                    if (cell.processor) |p| {
                        out[n] = p;
                        n += 1;
                    }
                    if (cell.zombie) |z| {
                        out[n] = z;
                        n += 1;
                    }
                    cell.* = .{};
                }
                row.* = .{};
            }
            return n;
        }

        // ----- audio thread (no allocation, no locks, no logging, no I/O) -----

        /// Once per block, before rendering. Retries parked zombies, then consumes adopted
        /// instances into their cells, retiring whatever they replace.
        pub fn service(self: *Self) void {
            for (&self.rows) |*row| {
                for (&row.cells) |*cell| {
                    if (cell.zombie) |z| {
                        if (self.retire_q.push(z)) cell.zombie = null;
                    }
                }
            }
            while (self.adopt_q.peek()) |item| {
                const cell = self.cellFor(item.track, item.slot) orelse {
                    // Nobody claims it: retire it. If the retire queue is full, leave it queued.
                    if (!self.retire_q.push(item.processor)) return;
                    _ = self.adopt_q.pop();
                    continue;
                };
                if (cell.want == 0 or cell.want != item.channels) {
                    if (!self.retire_q.push(item.processor)) return;
                    _ = self.adopt_q.pop();
                    continue;
                }
                // The cell still holds a zombie: its occupant cannot be retired yet. Wait.
                if (cell.zombie != null) return;
                _ = self.adopt_q.pop();
                const old = cell.processor;
                cell.processor = item.processor;
                cell.channels = item.channels;
                cell.failed = false;
                if (old) |o| self.park(cell, o);
            }
        }

        /// Session wants `channels` channels in this slot. Replaces an instance prepared for a
        /// different count. Returns false (try again next block) while the cell is busy.
        pub fn configure(self: *Self, track: TrackId, slot: usize, channels: usize) bool {
            const row = self.rowFor(track) orelse self.bindRow(track) orelse return false;
            const idx = cellIndex(slot) orelse return false;
            const cell = &row.cells[idx];
            if (cell.zombie != null) return false;
            cell.want = channels;
            if (cell.processor != null and cell.channels != channels) {
                const old = cell.processor.?;
                cell.processor = null;
                cell.channels = 0;
                cell.failed = false;
                self.park(cell, old);
            }
            return true;
        }

        /// The session no longer wants a plugin in this slot. Retires its instance.
        /// Returns false (try again next block) while the cell is busy.
        pub fn removeSlot(self: *Self, track: TrackId, slot: usize) bool {
            const row = self.rowFor(track) orelse return true;
            const idx = cellIndex(slot) orelse return false;
            const cell = &row.cells[idx];
            if (cell.zombie != null) return false;
            cell.want = 0;
            cell.failed = false;
            if (cell.processor) |old| {
                cell.processor = null;
                cell.channels = 0;
                self.park(cell, old);
            }
            return true;
        }

        /// The track was deleted: retires every instance on it and frees its row.
        /// Returns false (try again next block) while any cell is busy.
        pub fn removeTrack(self: *Self, track: TrackId) bool {
            const row = self.rowFor(track) orelse return true;
            for (row.cells) |cell| {
                if (cell.zombie != null) return false;
            }
            for (&row.cells) |*cell| {
                cell.want = 0;
                cell.failed = false;
                if (cell.processor) |old| {
                    cell.processor = null;
                    cell.channels = 0;
                    self.park(cell, old);
                }
            }
            row.bound = false;
            return true;
        }

        /// The installed processor for a slot, or null. Skips nothing: check [`isFailed`].
        pub fn lookup(self: *Self, track: TrackId, slot: usize) ?*Processor {
            const row = self.rowFor(track) orelse return null;
            const idx = cellIndex(slot) orelse return null;
            if (row.cells[idx].processor) |*p| return p;
            return null;
        }

        pub fn isFailed(self: *Self, track: TrackId, slot: usize) bool {
            const row = self.rowFor(track) orelse return false;
            const idx = cellIndex(slot) orelse return false;
            return row.cells[idx].failed;
        }

        /// Output of this slot went non-finite: take it out of the signal path until `reset`.
        pub fn recordFailure(self: *Self, track: TrackId, slot: usize) bool {
            const row = self.rowFor(track) orelse return false;
            const idx = cellIndex(slot) orelse return false;
            row.cells[idx].failed = true;
            row.failures.record(slot);
            return true;
        }

        pub fn failuresOf(self: *Self, track: TrackId) PluginFailures {
            const row = self.rowFor(track) orelse return .{};
            return row.failures;
        }

        /// Stop or seek: resets every installed plugin and re-enables failed ones. The
        /// instrument gets all-notes-off first, as in SoundCraft.
        pub fn reset(self: *Self) void {
            for (&self.rows) |*row| {
                if (!row.bound) continue;
                for (&row.cells, 0..) |*cell, idx| {
                    if (cell.processor) |p| {
                        if (idx == max_inserts) p.allNotesOff();
                        p.reset();
                    }
                    cell.failed = false;
                }
            }
        }

        // ----- internals -----

        fn cellIndex(slot: usize) ?usize {
            if (slot == INSTRUMENT_SLOT) return max_inserts;
            if (slot < max_inserts) return slot;
            return null;
        }

        fn rowFor(self: *Self, track: TrackId) ?*Row {
            for (&self.rows) |*row| {
                if (row.bound and row.track == track) return row;
            }
            return null;
        }

        /// A free row: unbound, and with nothing left in its cells.
        fn bindRow(self: *Self, track: TrackId) ?*Row {
            for (&self.rows) |*row| {
                if (row.bound) continue;
                var clean = true;
                for (row.cells) |cell| {
                    if (cell.processor != null or cell.zombie != null or cell.want != 0) clean = false;
                }
                if (!clean) continue;
                row.* = .{ .bound = true, .track = track };
                return row;
            }
            return null;
        }

        fn cellFor(self: *Self, track: TrackId, slot: usize) ?*Cell {
            const row = self.rowFor(track) orelse return null;
            const idx = cellIndex(slot) orelse return null;
            return &row.cells[idx];
        }

        /// Sends an occupant out of the slot. If the retire queue is full, it parks in the
        /// cell's zombie field. Callers check that the zombie field is empty first.
        fn park(self: *Self, cell: *Cell, p: Processor) void {
            std.debug.assert(cell.zombie == null);
            if (!self.retire_q.push(p)) cell.zombie = p;
        }
    };
}

/// The table used by the graph: 64 tracks, `INSERT_SLOTS` inserts each, 64-deep queues.
pub const Slots = SlotTable(64, INSERT_SLOTS, 64);

// ---------------------------------------------------------------------------------------------
// Tests. The Rust tests in tests.rs render audio, so they need the mix engine. The ones that
// exercise adoption, retirement and drain are ported below against a fake Processor; the
// render-only ones are kept as skipped stubs with the reason.
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

/// Test fake: a processor that records its calls and frees itself through the allocator it
/// was created with (control thread only).
const Fake = struct {
    gpa: std.mem.Allocator,
    tag: u8,
    resets: usize = 0,
    notes_off: usize = 0,

    const vtable: Processor.VTable = .{
        .prepare = prepare,
        .reset = reset,
        .process = process,
        .latency_samples = latency,
        .tail_samples = tail,
        .set_transport = setTransport,
        .all_notes_off = allNotesOff,
        .destroy = destroy,
    };

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }
    fn prepare(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
        _ = ptr;
        _ = sample_rate;
        _ = max_block;
        _ = channels;
    }
    fn reset(ptr: *anyopaque) void {
        of(ptr).resets += 1;
    }
    fn process(ptr: *anyopaque, io: [][]f32, frames: usize, events: []const processor.MidiEvent) void {
        _ = ptr;
        _ = io;
        _ = frames;
        _ = events;
    }
    fn latency(ptr: *anyopaque) usize {
        _ = ptr;
        return 0;
    }
    fn tail(ptr: *anyopaque) usize {
        _ = ptr;
        return 0;
    }
    fn setTransport(ptr: *anyopaque, t: *const processor.Transport) void {
        _ = ptr;
        _ = t;
    }
    fn allNotesOff(ptr: *anyopaque) void {
        of(ptr).notes_off += 1;
    }
    fn destroy(ptr: *anyopaque) void {
        const self = of(ptr);
        self.gpa.destroy(self);
    }
};

fn makeFake(gpa: std.mem.Allocator, tag: u8) !Processor {
    const f = try gpa.create(Fake);
    f.* = .{ .gpa = gpa, .tag = tag };
    return .{ .ptr = f, .vtable = &Fake.vtable };
}

fn tagOf(p: Processor) u8 {
    return Fake.of(p.ptr).tag;
}

/// Counts every allocation it forwards. Used to prove the audio-side calls allocate nothing.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocations: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
    }
};

const Small = SlotTable(2, 4, 2);

test "INSTRUMENT_SLOT is distinct from every insert index" {
    try testing.expect(INSTRUMENT_SLOT != INSERT_SLOTS - 1);
    try testing.expectEqual(@as(usize, 10), INSERT_SLOTS);
}

test "SpscQueue: FIFO order, full on capacity, empty after drain" {
    var q: SpscQueue(u32, 2) = .{};
    try testing.expect(q.push(1));
    try testing.expect(q.push(2));
    try testing.expect(!q.push(3));
    try testing.expectEqual(@as(?u32, 1), q.peek());
    try testing.expectEqual(@as(usize, 2), q.len());
    try testing.expectEqual(@as(?u32, 1), q.pop());
    try testing.expect(q.push(3));
    try testing.expectEqual(@as(?u32, 2), q.pop());
    try testing.expectEqual(@as(?u32, 3), q.pop());
    try testing.expectEqual(@as(?u32, null), q.pop());
}

test "external_instances_are_adopted_and_retired" {
    // Port of tests.rs `external_instances_are_adopted_and_retired`. The audio-level asserts
    // (dry/wet level through the mix engine) need the render path and are left out here; the
    // adoption and retirement sequence is kept.
    var table: Small = .{};
    table.setExternalInstances(true);
    try testing.expect(table.externalInstances());
    // The session wants one channel in insert 0 of track 1.
    try testing.expect(table.configure(1, 0, 1));
    table.service();
    // Nothing adopted yet: the slot is empty and passes audio through.
    try testing.expect(table.lookup(1, 0) == null);

    const gpa = testing.allocator;

    // An instance for the wrong channel count is retired, not used.
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'w'), .channels = 2 });
    table.service();
    try testing.expect(table.lookup(1, 0) == null);
    var buf: [Small.max_drained]Processor = undefined;
    var n = table.takeRetired(&buf);
    try testing.expectEqual(@as(usize, 1), n);
    buf[0].destroy();

    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'f'), .channels = 1 });
    table.service();
    try testing.expectEqual(@as(u8, 'f'), tagOf(table.lookup(1, 0).?.*));
    try testing.expectEqual(@as(usize, 0), table.takeRetired(&buf));

    // Removing the insert retires the instance instead of dropping it here.
    try testing.expect(table.removeSlot(1, 0));
    try testing.expect(table.lookup(1, 0) == null);
    n = table.takeRetired(&buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 'f'), tagOf(buf[0]));
    buf[0].destroy();

    // Instances nobody claims are retired too: slot 3 is a valid index but was never
    // configured, so nothing wants it. drainPlugins then empties the engine.
    try table.adopt(.{ .track = 1, .slot = 3, .processor = try makeFake(gpa, 'x'), .channels = 1 });
    table.service();
    n = table.takeRetired(&buf);
    try testing.expectEqual(@as(usize, 1), n);
    buf[0].destroy();

    const drained = try table.drainPlugins(&buf);
    try testing.expectEqual(@as(usize, 0), drained);
}

test "a_new_instance_replaces_a_matching_one_in_its_slot" {
    // Port of tests.rs `a_new_instance_replaces_a_matching_one_in_its_slot`. The host removed
    // and re-added the plugin; the new instance must win and the old one must be retired.
    var table: Small = .{};
    table.setExternalInstances(true);
    try testing.expect(table.configure(7, 0, 1));
    const gpa = testing.allocator;

    try table.adopt(.{ .track = 7, .slot = 0, .processor = try makeFake(gpa, 'o'), .channels = 1 });
    table.service();
    var buf: [Small.max_drained]Processor = undefined;
    try testing.expectEqual(@as(usize, 0), table.takeRetired(&buf));

    try table.adopt(.{ .track = 7, .slot = 0, .processor = try makeFake(gpa, 'n'), .channels = 1 });
    table.service();
    const retired = buf[0..table.takeRetired(&buf)];
    try testing.expectEqual(@as(usize, 1), retired.len);
    try testing.expectEqual(@as(u8, 'o'), tagOf(retired[0]));
    try testing.expectEqual(@as(u8, 'n'), tagOf(table.lookup(7, 0).?.*));
    retired[0].destroy();
    const left = try table.drainPlugins(&buf);
    try testing.expectEqual(@as(usize, 1), left);
    try testing.expectEqual(@as(u8, 'n'), tagOf(buf[0]));
    buf[0].destroy();
}

test "drain_plugins hands back occupants, zombies, pending and retired, and empties the table" {
    var table: Small = .{};
    try testing.expect(table.configure(1, 0, 1));
    try testing.expect(table.configure(1, INSTRUMENT_SLOT, 2));
    const gpa = testing.allocator;

    // Occupant in insert 0, occupant in the instrument cell.
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'a'), .channels = 1 });
    try table.adopt(.{ .track = 1, .slot = INSTRUMENT_SLOT, .processor = try makeFake(gpa, 'i'), .channels = 2 });
    table.service();
    // A pending adoption that the audio thread has not consumed yet.
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'p'), .channels = 1 });
    // A retired one waiting on the control thread.
    try testing.expect(table.removeSlot(1, INSTRUMENT_SLOT));

    var out: [Small.max_drained]Processor = undefined;
    const n = try table.drainPlugins(&out);
    try testing.expectEqual(@as(usize, 3), n);
    var seen = [_]bool{ false, false, false };
    for (out[0..n]) |p| {
        switch (tagOf(p)) {
            'a' => seen[0] = true,
            'i' => seen[1] = true,
            'p' => seen[2] = true,
            else => return error.UnexpectedProcessor,
        }
        p.destroy();
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
    try testing.expect(table.lookup(1, 0) == null);
    try testing.expectError(error.BufferTooSmall, table.drainPlugins(out[0..1]));
}

test "a full retire queue parks the old instance in its zombie cell and retries it next block" {
    // Retire queue of capacity 2 with nobody taking retirements, then one more replacement
    // than the queue can hold.
    const Tiny = SlotTable(1, 1, 2);
    var table: Tiny = .{};
    try testing.expect(table.configure(1, 0, 1));
    const gpa = testing.allocator;

    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'A'), .channels = 1 });
    table.service();
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'B'), .channels = 1 });
    table.service(); // retires A into the queue (1 of 2)
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'C'), .channels = 1 });
    table.service(); // retires B into the queue (2 of 2)
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'D'), .channels = 1 });
    table.service(); // queue full: C parks in the zombie cell, D is installed
    try testing.expectEqual(@as(u8, 'D'), tagOf(table.lookup(1, 0).?.*));
    try testing.expect(table.rows[0].cells[0].zombie != null);

    // A new adoption must wait while the cell holds a zombie.
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'E'), .channels = 1 });
    table.service();
    try testing.expectEqual(@as(u8, 'D'), tagOf(table.lookup(1, 0).?.*));

    var out: [Tiny.max_drained]Processor = undefined;
    var n = table.takeRetired(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 'A'), tagOf(out[0]));
    try testing.expectEqual(@as(u8, 'B'), tagOf(out[1]));
    for (out[0..n]) |p| p.destroy();

    // Next block: the zombie is retried into the freed queue (C), the cell is clear, so E is
    // installed and D is retired behind it.
    table.service();
    try testing.expect(table.rows[0].cells[0].zombie == null);
    try testing.expectEqual(@as(u8, 'E'), tagOf(table.lookup(1, 0).?.*));
    n = table.takeRetired(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 'C'), tagOf(out[0]));
    try testing.expectEqual(@as(u8, 'D'), tagOf(out[1]));
    for (out[0..n]) |p| p.destroy();

    const drained = try table.drainPlugins(&out);
    try testing.expectEqual(@as(usize, 1), drained);
    try testing.expectEqual(@as(u8, 'E'), tagOf(out[0]));
    out[0].destroy();
}

test "adoption, service, configure, remove and reset allocate nothing on the audio side" {
    var counting = CountingAllocator{ .inner = testing.allocator };
    const gpa = counting.allocator();
    var table: Small = .{};
    table.setExternalInstances(true);

    // Control thread: configure, create and adopt. Allocation is allowed here.
    try testing.expect(table.configure(3, 0, 1));
    try testing.expect(table.configure(3, INSTRUMENT_SLOT, 2));
    try table.adopt(.{ .track = 3, .slot = 0, .processor = try makeFake(gpa, 'a'), .channels = 1 });
    try table.adopt(.{ .track = 3, .slot = INSTRUMENT_SLOT, .processor = try makeFake(gpa, 'i'), .channels = 2 });
    const before_audio = counting.allocations;

    // Audio thread: consume adoptions, replace, remove, reset, look up. No allocator here.
    table.service();
    try testing.expect(table.configure(3, 0, 2)); // channel change retires 'a'
    table.service();
    try testing.expect(table.lookup(3, INSTRUMENT_SLOT) != null);
    table.reset();
    try testing.expect(table.removeSlot(3, INSTRUMENT_SLOT));
    try testing.expect(table.removeTrack(3));
    table.service();
    try testing.expectEqual(before_audio, counting.allocations);

    // Control thread again: take back what was retired and destroy it.
    var out: [Small.max_drained]Processor = undefined;
    const n = table.takeRetired(&out);
    try testing.expectEqual(@as(usize, 2), n);
    for (out[0..n]) |p| p.destroy();
}

test "reset clears failure flags and all-notes-off reaches the instrument only" {
    var table: Small = .{};
    try testing.expect(table.configure(1, 0, 1));
    try testing.expect(table.configure(1, INSTRUMENT_SLOT, 2));
    const gpa = testing.allocator;
    try table.adopt(.{ .track = 1, .slot = 0, .processor = try makeFake(gpa, 'a'), .channels = 1 });
    try table.adopt(.{ .track = 1, .slot = INSTRUMENT_SLOT, .processor = try makeFake(gpa, 'i'), .channels = 2 });
    table.service();

    try testing.expect(table.recordFailure(1, 0));
    try testing.expect(table.isFailed(1, 0));
    try testing.expectEqual(PluginFailures{ .count = 1, .last = 0 }, table.failuresOf(1));
    table.reset();
    try testing.expect(!table.isFailed(1, 0));
    // Reset does not clear the count: it only grows.
    try testing.expectEqual(PluginFailures{ .count = 1, .last = 0 }, table.failuresOf(1));
    try testing.expectEqual(@as(usize, 1), Fake.of(table.lookup(1, INSTRUMENT_SLOT).?.ptr).notes_off);
    try testing.expectEqual(@as(usize, 0), Fake.of(table.lookup(1, 0).?.ptr).notes_off);

    var out: [Small.max_drained]Processor = undefined;
    const n = try table.drainPlugins(&out);
    try testing.expectEqual(@as(usize, 2), n);
    for (out[0..n]) |p| p.destroy();
}

test "InstanceSpec and PreparedInstance carry the slot-index convention" {
    const spec: InstanceSpec = .{ .track = 4, .slot = INSTRUMENT_SLOT, .id = "clap:test.keys", .ch = 2 };
    try testing.expectEqual(INSTRUMENT_SLOT, spec.slot);
    try testing.expect(spec.state == null);
}

// --- Render-coupled Rust tests: they need the mix engine (clips, strips, sessions) and
// cannot run against the graph's slot table alone. Kept as skipped stubs so the mapping
// stays visible. Port them when the render path lands in the graph library.

test "plugins_get_the_session_transport" {
    // Needs MixEngine.render and Plugin::set_transport from a session.
    return error.SkipZigTest;
}

test "controllers_play_at_their_offsets_and_are_chased_after_a_seek" {
    // Needs MixEngine.render and MIDI scheduling.
    return error.SkipZigTest;
}

test "real_time_properties_reach_the_instrument" {
    // Needs MixEngine.render and note/property dispatch from the session.
    return error.SkipZigTest;
}

test "an_insert_that_puts_out_nan_is_taken_out_until_the_next_reset" {
    // Needs MixEngine.render: NaN containment happens in the strip render.
    return error.SkipZigTest;
}

test "nan_from_an_instrument_or_a_master_insert_is_contained" {
    // Needs MixEngine.render: NaN containment happens in the strip render.
    return error.SkipZigTest;
}

test "failed_inserts_stop_contributing_latency_until_reset" {
    // Needs MixEngine.render and delay compensation.
    return error.SkipZigTest;
}

test "stored_state_comes_first_then_session_params" {
    // Needs state restore through create_instance (plughost) and MixEngine.render.
    return error.SkipZigTest;
}

test "a_plugins_bogus_latency_is_capped" {
    // Needs MixEngine.render and latency compensation.
    return error.SkipZigTest;
}
