// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/process.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Everything a VST3 `process` call needs: the parameter-change queues (`IParameterChanges` /
//! `IParamValueQueue`), the event list (`IEventList`), planar audio bus buffers
//! (`AudioBusBuffers`), the in-memory `IBStream` used for state, and `ProcessBlock`, which
//! assembles one `ProcessData` per block from the host's events and transport.
//!
//! Real-time design (the Rust code used `Mutex<Vec<..>>` and per-block `Vec`s; here nothing in
//! the per-block path allocates, locks or grows):
//! * Parameter queues live in a pool sized once at `create` (`cap` queues). A dense table built
//!   at `create` maps each known VST3 `ParamID` to its queue by binary search over a sorted id
//!   array (no strings, no hashing). A block touching more than `cap` ids drops the extra
//!   changes and counts them in `overflowCount`; the pool never grows.
//! * `EventList` is a fixed array of `abi.Event`; `addEvent` past capacity fails and counts a
//!   drop. It is touched by one thread at a time (the host fills it, the plugin reads it inside
//!   `process`), so it needs no lock.
//! * `BusBuffers` allocates every channel buffer once; `refresh` only rewrites pointers.
//! * `MemoryStream` (state transfer) allocates and is control-thread only.
//!
//! The COM objects are heap objects with a `vtbl`-first interface field and an atomic
//! reference count (see `host.zig`); pool entries (`ParamQueue`) are owned by their
//! `ParamChanges` and are not individually reference counted.

const std = @import("std");
const abi = @import("abi.zig");
const host = @import("host.zig");
const event = @import("../event.zig");
const params_mod = @import("../params.zig");
const plugin = @import("../plugin.zig");

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

// ---- parameter queues ------------------------------------------------------------------------

/// One parameter's points for one block. SoundCraft sends at most one point per block; a
/// plugin writing output changes may add more, of which only the last is kept.
pub const ParamQueue = extern struct {
    iface: abi.IParamValueQueue,
    id: abi.ParamID,
    offset: i32,
    value: f64,
    points: i32,
    /// Index into the owner's dense id table, or `no_dense` for ids it does not know.
    dense: u32,

    const no_dense: u32 = std.math.maxInt(u32);
    const U = host.StaticUnknown;

    fn self_(this: *abi.IParamValueQueue) *ParamQueue {
        return @fieldParentPtr("iface", this);
    }

    fn getParameterId(this: *abi.IParamValueQueue) callconv(.c) abi.ParamID {
        return self_(this).id;
    }
    fn getPointCount(this: *abi.IParamValueQueue) callconv(.c) i32 {
        return self_(this).points;
    }
    fn getPoint(this: *abi.IParamValueQueue, index: i32, offset: ?*i32, value: ?*f64) callconv(.c) abi.tresult {
        const q = self_(this);
        if (index != 0 or q.points < 1) return abi.kInvalidArgument;
        const o = offset orelse return abi.kInvalidArgument;
        const v = value orelse return abi.kInvalidArgument;
        o.* = q.offset;
        v.* = q.value;
        return abi.kResultOk;
    }
    fn addPoint(this: *abi.IParamValueQueue, offset: i32, value: f64, index: ?*i32) callconv(.c) abi.tresult {
        const q = self_(this);
        q.offset = offset;
        q.value = value;
        q.points = 1;
        if (index) |i| i.* = 0;
        return abi.kResultOk;
    }

    const vtbl: abi.IParamValueQueue.Vtbl = .{
        .unknown = U.vtbl,
        .getParameterId = getParameterId,
        .getPointCount = getPointCount,
        .getPoint = getPoint,
        .addPoint = addPoint,
    };
};

/// One change read back from a queue.
pub const ParamChange = struct { id: abi.ParamID, offset: i32, value: f64 };

/// A fixed pool of parameter queues (`IParameterChanges`), reused every block.
pub const ParamChanges = struct {
    iface: abi.IParameterChanges,
    refs: host.RefCount = .{},
    gpa: Allocator,
    queues: []ParamQueue,
    /// Queues in use this block (first-use order).
    used: usize = 0,
    /// Known ids, sorted and unique: the dense table.
    ids: []abi.ParamID,
    /// Per dense index: queue index + 1 this block, 0 when the id has no queue yet.
    slot: []u32,
    /// Changes dropped because the pool was full (or the plugin passed a null id), since
    /// `create`/`resetOverflow`. Atomic so another thread may watch it.
    overflow: Atomic(u32) = .init(0),

    const U = host.Unknown(ParamChanges, "iface");

    /// Control thread (prepare). `cap` is the most distinct ids per block; `known_ids` are the
    /// plugin's parameter ids (any order, duplicates ignored). The result has one reference.
    pub fn create(gpa: Allocator, cap: usize, known_ids: []const abi.ParamID) Allocator.Error!*ParamChanges {
        const self = try gpa.create(ParamChanges);
        errdefer gpa.destroy(self);
        const queues = try gpa.alloc(ParamQueue, cap);
        errdefer gpa.free(queues);
        const sorted = try gpa.dupe(abi.ParamID, known_ids);
        errdefer gpa.free(sorted);
        std.mem.sort(abi.ParamID, sorted, {}, std.sort.asc(abi.ParamID));
        var n: usize = 0;
        for (sorted) |id| {
            if (n > 0 and sorted[n - 1] == id) continue;
            sorted[n] = id;
            n += 1;
        }
        const ids = try gpa.realloc(sorted, n);
        errdefer gpa.free(ids);
        const slot = try gpa.alloc(u32, n);
        @memset(slot, 0);
        for (queues) |*q| {
            q.* = .{ .iface = .{ .vtbl = &ParamQueue.vtbl }, .id = 0, .offset = 0, .value = 0, .points = 0, .dense = ParamQueue.no_dense };
        }
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa, .queues = queues, .ids = ids, .slot = slot };
        return self;
    }

    pub fn release(self: *ParamChanges) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn interface(self: *ParamChanges) *abi.IParameterChanges {
        return &self.iface;
    }

    pub fn queryImpl(self: *ParamChanges, id: *const abi.TUID) ?*anyopaque {
        if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IParameterChanges.iid)) return &self.iface;
        return null;
    }

    pub fn destroy(self: *ParamChanges) void {
        const gpa = self.gpa;
        gpa.free(self.queues);
        gpa.free(self.ids);
        gpa.free(self.slot);
        gpa.destroy(self);
    }

    /// Audio thread: empties the pool for the next block. Touches only the queues used.
    pub fn clear(self: *ParamChanges) void {
        for (self.queues[0..self.used]) |*q| {
            if (q.dense != ParamQueue.no_dense) self.slot[q.dense] = 0;
            q.dense = ParamQueue.no_dense;
            q.points = 0;
        }
        self.used = 0;
    }

    pub fn overflowCount(self: *const ParamChanges) u32 {
        return self.overflow.load(.monotonic);
    }

    pub fn resetOverflow(self: *ParamChanges) void {
        self.overflow.store(0, .monotonic);
    }

    pub fn count(self: *const ParamChanges) usize {
        return self.used;
    }

    fn denseIndex(self: *const ParamChanges, id: abi.ParamID) ?usize {
        const Ctx = struct {
            fn order(want: abi.ParamID, item: abi.ParamID) std.math.Order {
                return std.math.order(want, item);
            }
        };
        return std.sort.binarySearch(abi.ParamID, self.ids, id, Ctx.order);
    }

    /// Finds or adds the queue for `id`; null (and a counted drop) when the pool is full.
    fn queueFor(self: *ParamChanges, id: abi.ParamID) ?struct { index: usize, queue: *ParamQueue } {
        const dense = self.denseIndex(id);
        if (dense) |d| {
            if (self.slot[d] != 0) {
                const i = self.slot[d] - 1;
                return .{ .index = i, .queue = &self.queues[i] };
            }
        } else {
            // An id outside the table (output side, or a parameter added after prepare).
            for (self.queues[0..self.used], 0..) |*q, i| {
                if (q.dense == ParamQueue.no_dense and q.id == id) return .{ .index = i, .queue = q };
            }
        }
        if (self.used >= self.queues.len) {
            _ = self.overflow.fetchAdd(1, .monotonic);
            return null;
        }
        const i = self.used;
        const q = &self.queues[i];
        q.id = id;
        q.points = 0;
        if (dense) |d| {
            q.dense = @intCast(d);
            self.slot[d] = @intCast(i + 1);
        } else {
            q.dense = ParamQueue.no_dense;
        }
        self.used += 1;
        return .{ .index = i, .queue = q };
    }

    /// Host side, audio thread: one point for `id` at `offset` (replacing an earlier one this
    /// block). Returns false when the pool was full and the change was dropped.
    pub fn set(self: *ParamChanges, id: abi.ParamID, offset: i32, value: f64) bool {
        const r = self.queueFor(id) orelse return false;
        r.queue.offset = offset;
        r.queue.value = value;
        r.queue.points = 1;
        return true;
    }

    /// Reads queue `index` (first-use order); null past `count()` or when it has no point.
    pub fn at(self: *const ParamChanges, index: usize) ?ParamChange {
        if (index >= self.used) return null;
        const q = &self.queues[index];
        if (q.points < 1) return null;
        return .{ .id = q.id, .offset = q.offset, .value = q.value };
    }

    fn queuePtr(self: *ParamChanges, index: usize) ?*abi.IParamValueQueue {
        if (index >= self.queues.len) return null;
        return &self.queues[index].iface;
    }

    fn self_(this: *abi.IParameterChanges) *ParamChanges {
        return @fieldParentPtr("iface", this);
    }

    fn getParameterCount(this: *abi.IParameterChanges) callconv(.c) i32 {
        return @intCast(self_(this).used);
    }
    fn getParameterData(this: *abi.IParameterChanges, index: i32) callconv(.c) ?*abi.IParamValueQueue {
        const self = self_(this);
        if (index < 0 or index >= self.used) return null;
        return self.queuePtr(@intCast(index));
    }
    fn addParameterData(this: *abi.IParameterChanges, id: *const abi.ParamID, index: *i32) callconv(.c) ?*abi.IParamValueQueue {
        const self = self_(this);
        const r = self.queueFor(id.*) orelse return null;
        index.* = @intCast(r.index);
        return self.queuePtr(r.index);
    }

    const vtbl: abi.IParameterChanges.Vtbl = .{
        .unknown = U.vtbl,
        .getParameterCount = getParameterCount,
        .getParameterData = getParameterData,
        .addParameterData = addParameterData,
    };
};

// ---- events ----------------------------------------------------------------------------------

/// A host to plugin note event, safe to build anywhere; converted to the raw form on insertion.
pub const NoteEvent = union(enum) {
    on: struct { time: u32, key: u8, velocity: f32 },
    off: struct { time: u32, key: u8 },
    pressure: struct { time: u32, key: u8, pressure: f32 },

    pub fn time(self: NoteEvent) u32 {
        return switch (self) {
            inline else => |e| e.time,
        };
    }

    pub fn setTime(self: *NoteEvent, t: u32) void {
        switch (self.*) {
            inline else => |*e| e.time = t,
        }
    }

    /// The VST3 event, with `sampleOffset` taken relative to `offset` (the block start).
    pub fn toRaw(self: NoteEvent, offset: u32) abi.Event {
        var e = std.mem.zeroes(abi.Event);
        e.busIndex = 0;
        e.sampleOffset = std.math.cast(i32, self.time() -| offset) orelse 0;
        e.flags = 1; // kIsLive
        switch (self) {
            .on => |n| {
                e.type = abi.EventTypes.kNoteOnEvent;
                e.payload = .{ .noteOn = .{ .channel = 0, .pitch = n.key, .tuning = 0.0, .velocity = n.velocity, .length = 0, .noteId = -1 } };
            },
            .off => |n| {
                e.type = abi.EventTypes.kNoteOffEvent;
                e.payload = .{ .noteOff = .{ .channel = 0, .pitch = n.key, .velocity = 0.0, .noteId = -1, .tuning = 0.0 } };
            },
            .pressure => |n| {
                e.type = abi.EventTypes.kPolyPressureEvent;
                e.payload = .{ .polyPressure = .{ .channel = 0, .pitch = n.key, .pressure = n.pressure, .noteId = -1 } };
            },
        }
        return e;
    }
};

/// A bounded event list (`IEventList`) over preallocated storage. One thread at a time touches
/// it (the host fills it, then the plugin reads it inside `process`); there is no lock.
pub const EventList = struct {
    iface: abi.IEventList,
    refs: host.RefCount = .{},
    gpa: Allocator,
    events: []abi.Event,
    len: usize = 0,
    /// Events refused because the list was full, since `create`/`resetDropped`.
    dropped: u32 = 0,

    const U = host.Unknown(EventList, "iface");

    /// Control thread (prepare). The result has one reference.
    pub fn create(gpa: Allocator, cap: usize) Allocator.Error!*EventList {
        const self = try gpa.create(EventList);
        errdefer gpa.destroy(self);
        const events = try gpa.alloc(abi.Event, cap);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa, .events = events };
        return self;
    }

    pub fn release(self: *EventList) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn interface(self: *EventList) *abi.IEventList {
        return &self.iface;
    }

    pub fn queryImpl(self: *EventList, id: *const abi.TUID) ?*anyopaque {
        if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IEventList.iid)) return &self.iface;
        return null;
    }

    pub fn destroy(self: *EventList) void {
        const gpa = self.gpa;
        gpa.free(self.events);
        gpa.destroy(self);
    }

    pub fn capacity(self: *const EventList) usize {
        return self.events.len;
    }

    /// Audio thread: empties the list for the next block.
    pub fn clear(self: *EventList) void {
        self.len = 0;
    }

    pub fn resetDropped(self: *EventList) void {
        self.dropped = 0;
    }

    /// Appends a raw event; false (and a counted drop) when full.
    pub fn pushRaw(self: *EventList, e: abi.Event) bool {
        if (self.len >= self.events.len) {
            self.dropped +|= 1;
            return false;
        }
        self.events[self.len] = e;
        self.len += 1;
        return true;
    }

    /// Appends a note event, its offset taken relative to `block_start`.
    pub fn push(self: *EventList, e: NoteEvent, block_start: u32) bool {
        return self.pushRaw(e.toRaw(block_start));
    }

    pub fn items(self: *const EventList) []const abi.Event {
        return self.events[0..self.len];
    }

    fn self_(this: *abi.IEventList) *EventList {
        return @fieldParentPtr("iface", this);
    }

    fn getEventCount(this: *abi.IEventList) callconv(.c) i32 {
        return std.math.cast(i32, self_(this).len) orelse std.math.maxInt(i32);
    }
    fn getEvent(this: *abi.IEventList, index: i32, e: *abi.Event) callconv(.c) abi.tresult {
        const self = self_(this);
        const i = std.math.cast(usize, index) orelse return abi.kInvalidArgument;
        if (i >= self.len) return abi.kInvalidArgument;
        e.* = self.events[i];
        return abi.kResultOk;
    }
    /// Output events (e.g. MIDI out) are accepted while there is room; SoundCraft ignores them.
    fn addEvent(this: *abi.IEventList, e: *abi.Event) callconv(.c) abi.tresult {
        return if (self_(this).pushRaw(e.*)) abi.kResultOk else abi.kResultFalse;
    }

    const vtbl: abi.IEventList.Vtbl = .{
        .unknown = U.vtbl,
        .getEventCount = getEventCount,
        .getEvent = getEvent,
        .addEvent = addEvent,
    };
};

// ---- IBStream --------------------------------------------------------------------------------

/// An in-memory `IBStream`, used to hand the component's state to its controller. Control
/// thread only: it grows with the allocator and takes no lock.
pub const MemoryStream = struct {
    iface: abi.IBStream,
    refs: host.RefCount = .{},
    gpa: Allocator,
    data: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    const U = host.Unknown(MemoryStream, "iface");

    /// Copies `initial` into the stream (position 0). The result has one reference.
    pub fn create(gpa: Allocator, initial: []const u8) Allocator.Error!*MemoryStream {
        const self = try gpa.create(MemoryStream);
        errdefer gpa.destroy(self);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa };
        errdefer self.data.deinit(gpa);
        try self.data.appendSlice(gpa, initial);
        return self;
    }

    pub fn release(self: *MemoryStream) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn interface(self: *MemoryStream) *abi.IBStream {
        return &self.iface;
    }

    /// The bytes written so far.
    pub fn bytes(self: *const MemoryStream) []const u8 {
        return self.data.items;
    }

    /// Moves the contents out (caller frees with the stream's allocator) and empties the stream.
    pub fn take(self: *MemoryStream) Allocator.Error![]u8 {
        const out = try self.data.toOwnedSlice(self.gpa);
        self.pos = 0;
        return out;
    }

    pub fn queryImpl(self: *MemoryStream, id: *const abi.TUID) ?*anyopaque {
        if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IBStream.iid)) return &self.iface;
        return null;
    }

    pub fn destroy(self: *MemoryStream) void {
        const gpa = self.gpa;
        self.data.deinit(gpa);
        gpa.destroy(self);
    }

    fn self_(this: *abi.IBStream) *MemoryStream {
        return @fieldParentPtr("iface", this);
    }

    fn read(this: *abi.IBStream, buffer: ?*anyopaque, num_bytes: i32, num_read: ?*i32) callconv(.c) abi.tresult {
        const self = self_(this);
        const want: usize = std.math.cast(usize, num_bytes) orelse 0;
        const avail = self.data.items.len -| self.pos;
        const n = @min(want, avail);
        if (n > 0) {
            if (buffer) |b| {
                const dst: [*]u8 = @ptrCast(b);
                @memcpy(dst[0..n], self.data.items[self.pos..][0..n]);
                self.pos += n;
            }
        }
        if (num_read) |r| r.* = std.math.cast(i32, n) orelse 0;
        return abi.kResultOk;
    }

    fn write(this: *abi.IBStream, buffer: ?*anyopaque, num_bytes: i32, num_written: ?*i32) callconv(.c) abi.tresult {
        const self = self_(this);
        const n: usize = std.math.cast(usize, num_bytes) orelse 0;
        const end = self.pos +| n;
        const b = buffer orelse return abi.kResultFalse;
        if (end > abi.MAX_STATE_BYTES) return abi.kResultFalse;
        if (self.data.items.len < end) {
            self.data.resize(self.gpa, end) catch return abi.kOutOfMemory;
            // Bytes between the old length and `pos` (a seek never goes past the end, so
            // none): resize leaves new bytes undefined, and the write below covers them all.
        }
        const src: [*]const u8 = @ptrCast(b);
        @memcpy(self.data.items[self.pos..end], src[0..n]);
        self.pos = end;
        if (num_written) |w| w.* = num_bytes;
        return abi.kResultOk;
    }

    fn seek(this: *abi.IBStream, pos: i64, mode: i32, result: ?*i64) callconv(.c) abi.tresult {
        const self = self_(this);
        const len: i64 = std.math.cast(i64, self.data.items.len) orelse std.math.maxInt(i64);
        const cur: i64 = std.math.cast(i64, self.pos) orelse 0;
        const base: i64 = switch (mode) {
            abi.kIBSeekSet => 0,
            abi.kIBSeekCur => cur,
            abi.kIBSeekEnd => len,
            else => return abi.kInvalidArgument,
        };
        const new = std.math.clamp(base +| pos, 0, len);
        self.pos = @intCast(new);
        if (result) |r| r.* = new;
        return abi.kResultOk;
    }

    fn tell(this: *abi.IBStream, pos: ?*i64) callconv(.c) abi.tresult {
        const p = pos orelse return abi.kInvalidArgument;
        p.* = std.math.cast(i64, self_(this).pos) orelse 0;
        return abi.kResultOk;
    }

    const vtbl: abi.IBStream.Vtbl = .{ .unknown = U.vtbl, .read = read, .write = write, .seek = seek, .tell = tell };
};

// ---- audio buffers ---------------------------------------------------------------------------

/// Planar f32 buffers for every audio bus in one direction, with the pointer tables VST3 needs.
/// Everything is allocated in `init`; `refresh` only rewrites pointers in place.
pub const BusBuffers = struct {
    samples: []f32,
    ptrs: []?[*]f32,
    bufs: []abi.AudioBusBuffers,
    /// Per bus: index of its first channel in `ptrs`, and its channel count.
    first: []usize,
    chans: []usize,
    frames: usize,

    /// One buffer set per bus, `channels[b]` channels each (buses and channels capped by the
    /// ABI limits), `frames` long.
    pub fn init(gpa: Allocator, bus_channels: []const u32, frames: usize) Allocator.Error!BusBuffers {
        const n_buses = @min(bus_channels.len, @as(usize, @intCast(abi.MAX_BUSES)));
        const first = try gpa.alloc(usize, n_buses);
        errdefer gpa.free(first);
        const chans = try gpa.alloc(usize, n_buses);
        errdefer gpa.free(chans);
        var total: usize = 0;
        for (bus_channels[0..n_buses], 0..) |c, b| {
            first[b] = total;
            chans[b] = @min(c, abi.MAX_BUS_CHANNELS);
            total += chans[b];
        }
        const samples = try gpa.alloc(f32, total * frames);
        errdefer gpa.free(samples);
        @memset(samples, 0);
        const ptrs = try gpa.alloc(?[*]f32, total);
        errdefer gpa.free(ptrs);
        @memset(ptrs, null);
        const bufs = try gpa.alloc(abi.AudioBusBuffers, n_buses);
        for (bufs) |*b| b.* = .{ .numChannels = 0, .silenceFlags = 0, .channelBuffers = .{ .channelBuffers32 = null } };
        return .{ .samples = samples, .ptrs = ptrs, .bufs = bufs, .first = first, .chans = chans, .frames = frames };
    }

    pub fn deinit(self: *BusBuffers, gpa: Allocator) void {
        gpa.free(self.samples);
        gpa.free(self.ptrs);
        gpa.free(self.bufs);
        gpa.free(self.first);
        gpa.free(self.chans);
        self.* = undefined;
    }

    pub fn buses(self: *const BusBuffers) usize {
        return self.bufs.len;
    }

    pub fn channels(self: *const BusBuffers, bus: usize) usize {
        return if (bus < self.chans.len) self.chans[bus] else 0;
    }

    pub fn channel(self: *const BusBuffers, bus: usize, ch: usize) ?[]const f32 {
        if (ch >= self.channels(bus)) return null;
        return self.samples[(self.first[bus] + ch) * self.frames ..][0..self.frames];
    }

    pub fn channelMut(self: *BusBuffers, bus: usize, ch: usize) ?[]f32 {
        if (ch >= self.channels(bus)) return null;
        return self.samples[(self.first[bus] + ch) * self.frames ..][0..self.frames];
    }

    /// Points the VST3 tables at the current data (no allocation).
    pub fn refresh(self: *BusBuffers) void {
        for (self.bufs, 0..) |*b, bus| {
            const base = self.first[bus];
            for (0..self.chans[bus]) |c| {
                self.ptrs[base + c] = self.samples[(base + c) * self.frames ..].ptr;
            }
            b.numChannels = @intCast(self.chans[bus]);
            b.silenceFlags = 0;
            b.channelBuffers = .{ .channelBuffers32 = if (self.chans[bus] == 0) null else self.ptrs[base..].ptr };
        }
    }
};

// ---- transport -------------------------------------------------------------------------------

/// Fills `c` from the host transport (the flags say which fields are valid).
pub fn applyTransport(c: *abi.ProcessContext, t: *const plugin.Transport) void {
    const S = abi.ProcessStates;
    var state: u32 = S.kTempoValid | S.kTimeSigValid | S.kProjectTimeMusicValid | S.kBarPositionValid | S.kContTimeValid;
    if (t.playing) state |= S.kPlaying;
    if (t.recording) state |= S.kRecording;
    c.state = state;
    c.tempo = t.tempo;
    c.timeSigNumerator = std.math.cast(i32, t.numerator) orelse 4;
    c.timeSigDenominator = std.math.cast(i32, t.denominator) orelse 4;
    c.projectTimeSamples = t.samples;
    c.projectTimeMusic = t.quarters;
    c.barPositionMusic = t.bar_start;
}

// ---- ProcessBlock ----------------------------------------------------------------------------

/// Everything one plugin instance needs to build `ProcessData` per block, allocated once.
pub const ProcessBlock = struct {
    gpa: Allocator,
    inputs: BusBuffers,
    outputs: BusBuffers,
    in_params: *ParamChanges,
    out_params: *ParamChanges,
    in_events: *EventList,
    out_events: *EventList,
    context: abi.ProcessContext,
    data: abi.ProcessData,
    /// Dense parameter index to VST3 `ParamID`.
    param_ids: []abi.ParamID,
    max_frames: u32,
    data_mode: i32,
    /// Events the VST3 model has no direct form for (plain MIDI messages other than poly
    /// pressure; they need the instance's `IMidiMapping`), counted since the last `begin`.
    unmapped_events: u32 = 0,

    pub const Config = struct {
        sample_rate: f64,
        max_frames: u32,
        /// Channels of each input / output audio bus.
        in_channels: []const u32,
        out_channels: []const u32,
        /// The plugin's `ParamID`s in dense-index order (`event.ParamChange.index`).
        param_ids: []const abi.ParamID,
        /// Most distinct parameters changed per block, input and output side each.
        param_cap: usize = 256,
        event_cap: usize = abi.EVENT_CAP,
        process_mode: i32 = abi.kRealtime,
    };

    /// Control thread (prepare).
    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!ProcessBlock {
        var inputs = try BusBuffers.init(gpa, cfg.in_channels, cfg.max_frames);
        errdefer inputs.deinit(gpa);
        var outputs = try BusBuffers.init(gpa, cfg.out_channels, cfg.max_frames);
        errdefer outputs.deinit(gpa);
        const in_params = try ParamChanges.create(gpa, cfg.param_cap, cfg.param_ids);
        errdefer in_params.release();
        const out_params = try ParamChanges.create(gpa, cfg.param_cap, cfg.param_ids);
        errdefer out_params.release();
        const in_events = try EventList.create(gpa, cfg.event_cap);
        errdefer in_events.release();
        const out_events = try EventList.create(gpa, cfg.event_cap);
        errdefer out_events.release();
        const ids = try gpa.dupe(abi.ParamID, cfg.param_ids);
        var ctx = std.mem.zeroes(abi.ProcessContext);
        ctx.sampleRate = cfg.sample_rate;
        return .{
            .gpa = gpa,
            .inputs = inputs,
            .outputs = outputs,
            .in_params = in_params,
            .out_params = out_params,
            .in_events = in_events,
            .out_events = out_events,
            .context = ctx,
            .data = std.mem.zeroes(abi.ProcessData),
            .param_ids = ids,
            .max_frames = cfg.max_frames,
            .data_mode = cfg.process_mode,
        };
    }

    pub fn deinit(self: *ProcessBlock) void {
        self.inputs.deinit(self.gpa);
        self.outputs.deinit(self.gpa);
        self.in_params.release();
        self.out_params.release();
        self.in_events.release();
        self.out_events.release();
        self.gpa.free(self.param_ids);
        self.* = undefined;
    }

    /// Audio thread. Prepares `ProcessData` for a block of `frames` samples (clamped to
    /// `max_frames`): clears the queues and lists, points the buses and context at current data,
    /// and converts `events` (sorted by offset, as `event.EventList` keeps them) into VST3
    /// events and parameter changes. `infos` are the parameters' descriptions in the same dense
    /// order as `param_ids`, used to normalize `event.Event.ParamChange` values. No allocation:
    /// excess events and parameter changes are dropped and counted. The returned pointer stays
    /// valid until the next `begin` and must not outlive `self` moving.
    pub fn begin(
        self: *ProcessBlock,
        frames: u32,
        transport: *const plugin.Transport,
        events: []const event.Event,
        infos: []const params_mod.ParamInfo,
    ) *abi.ProcessData {
        const n = @min(frames, self.max_frames);
        self.in_params.clear();
        self.out_params.clear();
        self.in_events.clear();
        self.out_events.clear();
        self.unmapped_events = 0;
        self.inputs.refresh();
        self.outputs.refresh();
        applyTransport(&self.context, transport);
        for (events) |ev| self.addEvent(ev, infos);
        self.data = .{
            .processMode = self.data_mode,
            .symbolicSampleSize = abi.kSample32,
            .numSamples = @intCast(n),
            .numInputs = @intCast(self.inputs.bufs.len),
            .numOutputs = @intCast(self.outputs.bufs.len),
            .inputs = if (self.inputs.bufs.len == 0) null else self.inputs.bufs.ptr,
            .outputs = if (self.outputs.bufs.len == 0) null else self.outputs.bufs.ptr,
            .inputParameterChanges = self.in_params.interface(),
            .outputParameterChanges = self.out_params.interface(),
            .inputEvents = self.in_events.interface(),
            .outputEvents = self.out_events.interface(),
            .processContext = &self.context,
        };
        return &self.data;
    }

    fn addEvent(self: *ProcessBlock, ev: event.Event, infos: []const params_mod.ParamInfo) void {
        switch (ev.kind) {
            .note_on => |n| _ = self.in_events.push(.{ .on = .{ .time = ev.offset, .key = n.note, .velocity = @as(f32, @floatFromInt(n.velocity)) / 127.0 } }, 0),
            .note_off => |k| _ = self.in_events.push(.{ .off = .{ .time = ev.offset, .key = k } }, 0),
            .midi3 => |m| {
                if (m[0] & 0xF0 == 0xA0) {
                    _ = self.in_events.push(.{ .pressure = .{ .time = ev.offset, .key = m[1] & 0x7F, .pressure = @as(f32, @floatFromInt(m[2] & 0x7F)) / 127.0 } }, 0);
                } else {
                    self.unmapped_events +|= 1;
                }
            },
            .param => |p| {
                if (p.index >= self.param_ids.len or p.index >= infos.len) return;
                const norm = infos[p.index].toNormalized(p.value);
                _ = self.in_params.set(self.param_ids[p.index], std.math.cast(i32, ev.offset) orelse 0, norm);
            },
        }
    }
};

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

// Port of ffi.rs `host_objects_behave` (the ParamChanges part).
test "host_objects_behave: ParamChanges" {
    const pc = try ParamChanges.create(testing.allocator, 2, &.{ 5, 6, 7 });
    defer pc.release();
    _ = pc.set(5, 0, 0.25);
    _ = pc.set(5, 0, 0.5);
    _ = pc.set(6, 0, 1.0);
    try testing.expect(!pc.set(7, 0, 1.0));
    const i = pc.interface();
    // full pool drops extra params
    try testing.expectEqual(@as(i32, 2), i.getParameterCount());
    try testing.expect(i.getParameterData(2) == null);
    try testing.expect(i.getParameterData(-1) == null);
    const q = i.getParameterData(0).?;
    var o: i32 = 9;
    var v: f64 = 0;
    try testing.expectEqual(abi.kResultOk, q.getPoint(0, &o, &v));
    try testing.expectEqual(@as(i32, 0), o);
    try testing.expectEqual(@as(f64, 0.5), v);
    try testing.expect(q.getPoint(1, &o, &v) != abi.kResultOk);
    try testing.expect(q.getPoint(0, null, &v) != abi.kResultOk);
    try testing.expectEqual(@as(u32, 1), pc.overflowCount());
}

// Port of ffi.rs `host_objects_behave` (the EventList part).
test "host_objects_behave: EventList" {
    const el = try EventList.create(testing.allocator, 1);
    defer el.release();
    var e = (NoteEvent{ .on = .{ .time = 5, .key = 60, .velocity = 1.0 } }).toRaw(2);
    const i = el.interface();
    try testing.expectEqual(abi.kResultOk, i.addEvent(&e));
    // bounded
    try testing.expect(i.addEvent(&e) != abi.kResultOk);
    try testing.expectEqual(@as(i32, 1), i.getEventCount());
    var out = std.mem.zeroes(abi.Event);
    try testing.expectEqual(abi.kResultOk, i.getEvent(0, &out));
    try testing.expectEqual(@as(i32, 3), out.sampleOffset);
    try testing.expectEqual(@as(i16, 60), out.payload.noteOn.pitch);
    try testing.expect(i.getEvent(1, &out) != abi.kResultOk);
    try testing.expect(i.getEvent(-1, &out) != abi.kResultOk);
    try testing.expectEqual(@as(u32, 1), el.dropped);
}

// Port of ffi.rs `host_objects_behave` (the MemoryStream part).
test "host_objects_behave: MemoryStream" {
    const s = try MemoryStream.create(testing.allocator, "");
    defer s.release();
    const i = s.interface();
    var buf = "hello".*;
    var n: i32 = 0;
    try testing.expectEqual(abi.kResultOk, i.write(&buf, 5, &n));
    try testing.expectEqual(@as(i32, 5), n);
    var pos: i64 = 0;
    try testing.expectEqual(abi.kResultOk, i.seek(1, abi.kIBSeekSet, &pos));
    var out: [8]u8 = undefined;
    try testing.expectEqual(abi.kResultOk, i.read(&out, 8, &n));
    try testing.expectEqual(@as(i32, 4), n);
    try testing.expectEqualStrings("ello", out[0..4]);
    try testing.expectEqual(abi.kResultOk, i.seek(-100, abi.kIBSeekEnd, &pos));
    try testing.expectEqual(@as(i64, 0), pos);
    try testing.expectEqual(abi.kResultFalse, i.write(null, 5, &n));
}

// Port of ffi.rs `host_objects_behave` (the HostContext and hex part).
test "host_objects_behave: HostContext and hex" {
    const h = try host.HostContext.create(testing.allocator);
    defer h.release();
    var name: abi.String128 = @splat(0);
    const app = h.hostApplication();
    try testing.expectEqual(abi.kResultOk, app.vtbl.getName(app, &name));
    const hd = h.componentHandler();
    try testing.expectEqual(abi.kResultOk, hd.vtbl.restartComponent(hd, abi.kLatencyChanged));
    const text = try abi.readC16(testing.allocator, &name);
    defer testing.allocator.free(text);
    // Seridian reports its own name (the Rust host said "SoundCraft").
    try testing.expectEqualStrings("Seridian Studio", text);
    try testing.expect(h.latency_changed.load(.monotonic));
    const h16: [16]u8 = @splat(0xAB);
    try testing.expectEqualStrings("ABABABABABABABABABABABABABABABAB", &abi.hex(&h16));
}

// Port of ffi.rs `the_transport_fills_the_process_context`.
test "the_transport_fills_the_process_context" {
    const S = abi.ProcessStates;
    var c = std.mem.zeroes(abi.ProcessContext);
    const t: plugin.Transport = .{
        .playing = true,
        .tempo = 90.0,
        .numerator = 3,
        .denominator = 4,
        .samples = 96_000,
        .quarters = 3.5,
        .bar_start = 3.0,
    };
    applyTransport(&c, &t);
    try testing.expectEqual(S.kPlaying, c.state & S.kPlaying);
    try testing.expectEqual(@as(u32, 0), c.state & S.kRecording);
    try testing.expectEqual(@as(f64, 90.0), c.tempo);
    try testing.expectEqual(@as(i32, 3), c.timeSigNumerator);
    try testing.expectEqual(@as(i32, 4), c.timeSigDenominator);
    try testing.expectEqual(@as(i64, 96_000), c.projectTimeSamples);
    try testing.expectEqual(@as(f64, 3.5), c.projectTimeMusic);
    try testing.expectEqual(@as(f64, 3.0), c.barPositionMusic);
    var stopped = t;
    stopped.playing = false;
    applyTransport(&c, &stopped);
    try testing.expectEqual(@as(u32, 0), c.state & S.kPlaying);
    try testing.expect(c.state & S.kTempoValid != 0);
}

test "param queue order is first-use order, later sets replace" {
    const pc = try ParamChanges.create(testing.allocator, 8, &.{ 30, 10, 20, 10 });
    defer pc.release();
    try testing.expectEqual(@as(usize, 3), pc.ids.len);
    try testing.expect(pc.set(20, 4, 0.2));
    try testing.expect(pc.set(10, 8, 0.1));
    try testing.expect(pc.set(99, 1, 0.9)); // unknown id still gets a queue
    try testing.expect(pc.set(20, 16, 0.25)); // replaces
    try testing.expectEqual(@as(usize, 3), pc.count());
    try testing.expectEqual(ParamChange{ .id = 20, .offset = 16, .value = 0.25 }, pc.at(0).?);
    try testing.expectEqual(ParamChange{ .id = 10, .offset = 8, .value = 0.1 }, pc.at(1).?);
    try testing.expectEqual(ParamChange{ .id = 99, .offset = 1, .value = 0.9 }, pc.at(2).?);
    try testing.expect(pc.at(3) == null);
    // The plugin sees the same order through COM.
    const i = pc.interface();
    try testing.expectEqual(@as(u32, 20), i.getParameterData(0).?.getParameterId());
    try testing.expectEqual(@as(u32, 99), i.getParameterData(2).?.getParameterId());
    try testing.expectEqual(@as(i32, 1), i.getParameterData(1).?.getPointCount());
    // clear empties, and ids can be reused in a different order.
    pc.clear();
    try testing.expectEqual(@as(usize, 0), pc.count());
    try testing.expect(pc.set(10, 0, 0.5));
    try testing.expect(pc.set(20, 0, 0.6));
    try testing.expectEqual(@as(u32, 10), pc.at(0).?.id);
    try testing.expectEqual(@as(u32, 20), pc.at(1).?.id);
    try testing.expectEqual(@as(u32, 0), pc.overflowCount());
}

test "param queue overflow is counted and dropped, never grown" {
    const pc = try ParamChanges.create(testing.allocator, 3, &.{ 1, 2, 3, 4, 5 });
    defer pc.release();
    var id: u32 = 1;
    while (id <= 5) : (id += 1) _ = pc.set(id, 0, 0.5);
    try testing.expectEqual(@as(usize, 3), pc.count());
    try testing.expectEqual(@as(usize, 3), pc.queues.len);
    try testing.expectEqual(@as(u32, 2), pc.overflowCount());
    // A dropped id stays dropped, an accepted id still updates, each drop is counted.
    try testing.expect(!pc.set(5, 0, 0.7));
    try testing.expect(pc.set(2, 3, 0.7));
    try testing.expectEqual(@as(f64, 0.7), pc.at(1).?.value);
    try testing.expectEqual(@as(u32, 3), pc.overflowCount());
    pc.resetOverflow();
    try testing.expectEqual(@as(u32, 0), pc.overflowCount());
    // The plugin-side path overflows the same way.
    const i = pc.interface();
    pc.clear();
    var idx: i32 = -1;
    var pid: u32 = 100;
    var got: usize = 0;
    while (pid < 105) : (pid += 1) {
        if (i.addParameterData(&pid, &idx)) |q| {
            _ = q.addPoint(2, 0.3, null);
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), got);
    try testing.expectEqual(@as(u32, 2), pc.overflowCount());
    // Output side read-back by id: asking again returns the same queue.
    pid = 101;
    const again = i.addParameterData(&pid, &idx).?;
    try testing.expectEqual(@as(i32, 1), idx);
    try testing.expectEqual(@as(u32, 101), again.getParameterId());
    try testing.expectEqual(ParamChange{ .id = 101, .offset = 2, .value = 0.3 }, pc.at(1).?);
}

test "zero-capacity pools drop everything" {
    const pc = try ParamChanges.create(testing.allocator, 0, &.{});
    defer pc.release();
    try testing.expect(!pc.set(1, 0, 0.5));
    try testing.expectEqual(@as(u32, 1), pc.overflowCount());
    const el = try EventList.create(testing.allocator, 0);
    defer el.release();
    try testing.expect(!el.push(.{ .off = .{ .time = 0, .key = 60 } }, 0));
}

test "event list keeps insertion order and offsets relative to the block" {
    const el = try EventList.create(testing.allocator, 4);
    defer el.release();
    try testing.expect(el.push(.{ .on = .{ .time = 1000, .key = 60, .velocity = 0.5 } }, 1000));
    try testing.expect(el.push(.{ .pressure = .{ .time = 1010, .key = 60, .pressure = 0.25 } }, 1000));
    try testing.expect(el.push(.{ .off = .{ .time = 1020, .key = 60 } }, 1000));
    try testing.expect(el.push(.{ .off = .{ .time = 3, .key = 61 } }, 1000)); // before the block: clamps to 0
    try testing.expect(!el.push(.{ .off = .{ .time = 5, .key = 62 } }, 0));
    const it = el.items();
    try testing.expectEqual(@as(usize, 4), it.len);
    try testing.expectEqual(@as(i32, 0), it[0].sampleOffset);
    try testing.expectEqual(abi.EventTypes.kNoteOnEvent, it[0].type);
    try testing.expectEqual(@as(i32, 10), it[1].sampleOffset);
    try testing.expectEqual(abi.EventTypes.kPolyPressureEvent, it[1].type);
    try testing.expectEqual(@as(f32, 0.25), it[1].payload.polyPressure.pressure);
    try testing.expectEqual(@as(i32, 20), it[2].sampleOffset);
    try testing.expectEqual(abi.EventTypes.kNoteOffEvent, it[2].type);
    try testing.expectEqual(@as(i32, 0), it[3].sampleOffset);
    try testing.expectEqual(@as(u32, 1), el.dropped);
    el.clear();
    try testing.expectEqual(@as(i32, 0), el.interface().getEventCount());
}

test "NoteEvent time accessors" {
    var e: NoteEvent = .{ .on = .{ .time = 5, .key = 60, .velocity = 1.0 } };
    try testing.expectEqual(@as(u32, 5), e.time());
    e.setTime(9);
    try testing.expectEqual(@as(u32, 9), e.time());
    var p: NoteEvent = .{ .pressure = .{ .time = 1, .key = 60, .pressure = 0.5 } };
    p.setTime(2);
    try testing.expectEqual(@as(u32, 2), p.time());
}

test "MemoryStream: seek modes, cur, tell, take, overwrite and initial data" {
    const s = try MemoryStream.create(testing.allocator, "abcdef");
    defer s.release();
    const i = s.interface();
    var pos: i64 = -1;
    try testing.expectEqual(abi.kResultOk, i.tell(&pos));
    try testing.expectEqual(@as(i64, 0), pos);
    try testing.expectEqual(abi.kInvalidArgument, i.tell(null));
    try testing.expectEqual(abi.kResultOk, i.seek(2, abi.kIBSeekCur, &pos));
    try testing.expectEqual(@as(i64, 2), pos);
    try testing.expectEqual(abi.kResultOk, i.seek(100, abi.kIBSeekSet, &pos));
    try testing.expectEqual(@as(i64, 6), pos); // clamped to the end
    try testing.expectEqual(abi.kInvalidArgument, i.seek(0, 99, &pos));
    // overwrite in the middle, then extend past the end
    _ = i.seek(4, abi.kIBSeekSet, null);
    var w = "XYZ".*;
    var n: i32 = 0;
    try testing.expectEqual(abi.kResultOk, i.write(&w, 3, &n));
    try testing.expectEqualStrings("abcdXYZ", s.bytes());
    // reading at the end yields zero bytes
    var out: [4]u8 = undefined;
    try testing.expectEqual(abi.kResultOk, i.read(&out, 4, &n));
    try testing.expectEqual(@as(i32, 0), n);
    // negative sizes are zero-length
    try testing.expectEqual(abi.kResultOk, i.read(&out, -3, &n));
    try testing.expectEqual(@as(i32, 0), n);
    const owned = try s.take();
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("abcdXYZ", owned);
    try testing.expectEqual(@as(usize, 0), s.bytes().len);
    // writes beyond the state limit are refused
    _ = i.seek(0, abi.kIBSeekSet, null);
    try testing.expectEqual(abi.kResultFalse, i.write(&w, std.math.maxInt(i32), &n));
}

test "queryInterface on pool objects" {
    const s = try MemoryStream.create(testing.allocator, "");
    defer s.release();
    const st = abi.comCast(abi.IBStream, s.interface()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), abi.comRelease(st));
    const bad: abi.TUID = abi.IEventList.iid;
    var obj: ?*anyopaque = null;
    try testing.expectEqual(abi.kNoInterface, abi.asUnknown(s.interface()).queryInterface(&bad, &obj));
    // Pool queues answer FUnknown only and never free themselves.
    const pc = try ParamChanges.create(testing.allocator, 1, &.{1});
    defer pc.release();
    _ = pc.set(1, 0, 0.5);
    const q = pc.interface().getParameterData(0).?;
    _ = abi.comAddRef(q);
    _ = abi.comRelease(q);
    _ = abi.comRelease(q);
    try testing.expectEqual(@as(u32, 1), q.getParameterId());
    const iq = abi.comCast(abi.IParamValueQueue, q);
    try testing.expect(iq == null);
}

test "BusBuffers: layout, capping and pointer refresh" {
    var b = try BusBuffers.init(testing.allocator, &.{ 2, 1, 1000 }, 8);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), b.buses());
    try testing.expectEqual(@as(usize, 2), b.channels(0));
    try testing.expectEqual(@as(usize, abi.MAX_BUS_CHANNELS), b.channels(2));
    try testing.expectEqual(@as(usize, 0), b.channels(3));
    try testing.expect(b.channel(0, 2) == null);
    try testing.expect(b.channelMut(3, 0) == null);
    b.channelMut(0, 1).?[3] = 0.75;
    b.channelMut(1, 0).?[0] = -1.0;
    b.refresh();
    try testing.expectEqual(@as(i32, 2), b.bufs[0].numChannels);
    const p0 = b.bufs[0].channelBuffers.channelBuffers32.?;
    try testing.expectEqual(@as(f32, 0.75), p0[1].?[3]);
    try testing.expectEqual(@as(f32, -1.0), b.bufs[1].channelBuffers.channelBuffers32.?[0].?[0]);
    // Writing through the VST3 pointers lands in the same storage.
    p0[0].?[7] = 2.0;
    try testing.expectEqual(@as(f32, 2.0), b.channel(0, 0).?[7]);
    // Buses do not overlap.
    try testing.expect(b.channel(0, 1).?.ptr != b.channel(1, 0).?.ptr);

    var none = try BusBuffers.init(testing.allocator, &.{}, 4);
    defer none.deinit(testing.allocator);
    none.refresh();
    try testing.expectEqual(@as(usize, 0), none.buses());
}

test "ProcessBlock builds ProcessData from events and transport without allocating" {
    const infos = [_]params_mod.ParamInfo{
        params_mod.lin("gain", "Gain", 0, 10, 5, .none),
        params_mod.lin("mix", "Mix", -1, 1, 0, .none),
    };
    // The only allocator use is init; `begin` has no allocator parameter at all.
    var pb = try ProcessBlock.init(testing.allocator, .{
        .sample_rate = 48000,
        .max_frames = 64,
        .in_channels = &.{2},
        .out_channels = &.{ 2, 1 },
        .param_ids = &.{ 1001, 1002 },
        .param_cap = 4,
        .event_cap = 3,
    });
    defer pb.deinit();

    var list = try event.EventList.init(testing.allocator, 16);
    defer list.deinit(testing.allocator);
    try testing.expect(list.push(.{ .offset = 0, .kind = .{ .note_on = .{ .note = 64, .velocity = 127 } } }));
    try testing.expect(list.push(.{ .offset = 4, .kind = .{ .param = .{ .index = 1, .value = 0.5 } } }));
    try testing.expect(list.push(.{ .offset = 8, .kind = .{ .midi3 = .{ 0xB0, 1, 64 } } })); // CC: unmapped
    try testing.expect(list.push(.{ .offset = 9, .kind = .{ .midi3 = .{ 0xA0, 64, 127 } } }));
    try testing.expect(list.push(.{ .offset = 10, .kind = .{ .param = .{ .index = 0, .value = 10 } } }));
    try testing.expect(list.push(.{ .offset = 12, .kind = .{ .param = .{ .index = 7, .value = 1 } } })); // no such param
    try testing.expect(list.push(.{ .offset = 16, .kind = .{ .note_off = 64 } }));
    try testing.expect(list.push(.{ .offset = 20, .kind = .{ .note_off = 65 } })); // list full (cap 3)

    const t: plugin.Transport = .{ .playing = true, .tempo = 140, .numerator = 4, .denominator = 4, .samples = 480 };
    const data = pb.begin(32, &t, list.items(), &infos);
    try testing.expectEqual(@as(i32, 32), data.numSamples);
    try testing.expectEqual(@as(i32, 1), data.numInputs);
    try testing.expectEqual(@as(i32, 2), data.numOutputs);
    try testing.expectEqual(abi.kSample32, data.symbolicSampleSize);
    try testing.expectEqual(abi.kRealtime, data.processMode);
    try testing.expectEqual(@as(f64, 140), data.processContext.?.tempo);
    try testing.expectEqual(@as(f64, 48000), data.processContext.?.sampleRate);

    const ev = data.inputEvents.?;
    try testing.expectEqual(@as(i32, 3), ev.getEventCount());
    var e = std.mem.zeroes(abi.Event);
    try testing.expectEqual(abi.kResultOk, ev.getEvent(0, &e));
    try testing.expectEqual(abi.EventTypes.kNoteOnEvent, e.type);
    try testing.expectEqual(@as(f32, 1.0), e.payload.noteOn.velocity);
    try testing.expectEqual(abi.kResultOk, ev.getEvent(1, &e));
    try testing.expectEqual(abi.EventTypes.kPolyPressureEvent, e.type);
    try testing.expectEqual(@as(i32, 9), e.sampleOffset);
    try testing.expectEqual(abi.kResultOk, ev.getEvent(2, &e));
    try testing.expectEqual(abi.EventTypes.kNoteOffEvent, e.type);
    try testing.expectEqual(@as(u32, 1), pb.in_events.dropped);
    try testing.expectEqual(@as(u32, 1), pb.unmapped_events);

    const pc = data.inputParameterChanges.?;
    try testing.expectEqual(@as(i32, 2), pc.getParameterCount());
    const q0 = pc.getParameterData(0).?;
    try testing.expectEqual(@as(u32, 1002), q0.getParameterId());
    var off: i32 = 0;
    var val: f64 = 0;
    try testing.expectEqual(abi.kResultOk, q0.getPoint(0, &off, &val));
    try testing.expectEqual(@as(i32, 4), off);
    try testing.expectApproxEqAbs(@as(f64, 0.75), val, 1e-6); // 0.5 of [-1, 1] normalized
    const q1 = pc.getParameterData(1).?;
    try testing.expectEqual(@as(u32, 1001), q1.getParameterId());
    try testing.expectEqual(abi.kResultOk, q1.getPoint(0, &off, &val));
    try testing.expectApproxEqAbs(@as(f64, 1.0), val, 1e-6);

    // Buses are wired to the buffers.
    try testing.expectEqual(@as(i32, 2), data.outputs.?[0].numChannels);
    try testing.expectEqual(@as(i32, 1), data.outputs.?[1].numChannels);
    pb.outputs.channelMut(0, 0).?[0] = 0.5;
    try testing.expectEqual(@as(f32, 0.5), data.outputs.?[0].channelBuffers.channelBuffers32.?[0].?[0]);

    // Next block starts clean; frames clamp to the maximum.
    const data2 = pb.begin(1000, &t, &.{}, &infos);
    try testing.expectEqual(@as(i32, 64), data2.numSamples);
    try testing.expectEqual(@as(i32, 0), data2.inputEvents.?.getEventCount());
    try testing.expectEqual(@as(i32, 0), data2.inputParameterChanges.?.getParameterCount());
    try testing.expectEqual(@as(u32, 0), pb.unmapped_events);
}

test "ProcessBlock without audio buses passes null bus tables" {
    var pb = try ProcessBlock.init(testing.allocator, .{
        .sample_rate = 44100,
        .max_frames = 16,
        .in_channels = &.{},
        .out_channels = &.{},
        .param_ids = &.{},
    });
    defer pb.deinit();
    const data = pb.begin(16, &.{}, &.{}, &.{});
    try testing.expect(data.inputs == null);
    try testing.expect(data.outputs == null);
    try testing.expectEqual(@as(i32, 0), data.numInputs);
}
