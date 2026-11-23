// Translated to Zig from soundcraft/crates/playback/src/callback.rs, soundcraft/crates/playback/src/lib.rs, soundcraft/crates/playback/src/tests.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! UI-thread bookkeeping for the plugin instances the audio thread renders: the
//! `Side` of playback's `callback.rs`, plus the snapshot return channel and the
//! command queue from `lib.rs` that it needs.
//!
//! What the side does, all on the control thread:
//! - `prepare` creates each third-party instance a session needs that the audio
//!   thread does not have yet (once; failures are remembered, not retried), and
//!   returns them for the caller to adopt into the graph's slot table.
//! - `collectGarbage` destroys the processors the graph retired (`takeRetired`)
//!   and releases the session snapshots the audio thread replaced.
//! - Editors (`PluginEditor`) and state readers (`PluginStateReader`) are kept per
//!   (track, slot) from each instance before it leaves for the audio thread, so
//!   editors can be driven and states saved without touching the audio thread.
//! - Instances that refused their stored state keep it until their editor opens.
//!
//! Ownership and threads. The UI thread is the only producer of `CmdQueue` and
//! the only consumer of `SnapshotQueue`; the audio thread is the reverse. Both are
//! single-producer single-consumer rings (`graph.slot.SpscQueue`), so there is no
//! lock. `Side` is not thread-safe: one control thread drives it. Snapshot
//! handles are references owned by whoever holds them; `release` drops one.
//!
//! Differences from the Rust code, all deliberate:
//! - Rust `BTreeMap` iteration order (sorted by track, then slot) is produced by
//!   sorting the keys at capture time.
//! - Rust `mpsc` channels become preallocated SPSC rings. Rust's `update_session`,
//!   `idle`, meter and transport plumbing lives in other units and is not here.
//! - Rust `Cmd::Forget` is not in `Cmd`: meter forgetting belongs to the meter unit.
//!
//! Realtime: nothing in this file runs on the audio thread. The audio thread only
//! pushes to `SnapshotQueue` and pops `CmdQueue`, through the queues.

const std = @import("std");
const graph = @import("graph");
const plughost = @import("plughost");
const pi = @import("plugin_instances.zig");

const Allocator = std.mem.Allocator;
const TrackId = graph.slot.TrackId;
const Processor = graph.processor.Processor;
const PreparedInstance = graph.slot.PreparedInstance;
const SpscQueue = graph.slot.SpscQueue;
const PluginEditor = plughost.plugin.PluginEditor;
const PluginStateReader = plughost.plugin.PluginStateReader;
const INSTRUMENT_SLOT = pi.INSTRUMENT_SLOT;
const log = std.log.scoped(.session_control_side);

/// Block size instances are prepared for (playback's `BLOCK`).
pub const BLOCK: usize = 512;
/// Room for replaced snapshots on their way back (playback's `OLD_SESSIONS`).
pub const OLD_SESSIONS: usize = 16;
/// Room for commands from the UI thread to the audio thread.
pub const CMD_CAPACITY: usize = 64;
/// Processors `collectGarbage` takes from the retire queue per call.
pub const GARBAGE_BATCH: usize = 32;

/// `(track, slot)`: `slot` is an insert index or `INSTRUMENT_SLOT`.
pub const Key = struct {
    track: TrackId,
    slot: usize,
};

/// A saved plugin state. `bytes` is owned; free the list with `freeStates`.
pub const PluginState = struct {
    track: TrackId,
    slot: usize,
    bytes: []u8,
};

/// One reference to an immutable session snapshot the audio thread holds. Releasing
/// the last reference frees it (the implementation's ref count and destroy callback).
pub const SnapshotHandle = struct {
    ptr: *anyopaque,
    release_fn: *const fn (ptr: *anyopaque) void,

    pub fn release(self: SnapshotHandle) void {
        self.release_fn(self.ptr);
    }
};

/// Snapshots the audio thread replaced, on their way back to the UI thread.
pub const SnapshotQueue = SpscQueue(SnapshotHandle, OLD_SESSIONS);

/// Commands from the UI thread to the audio thread that this unit sends.
pub const Cmd = union(enum) {
    /// A new snapshot for the audio thread to render. The reference moves with it.
    session: SnapshotHandle,
    /// Where the audio thread returns the snapshots it replaces.
    old_sessions: *SnapshotQueue,
};

/// The UI-to-audio command queue (single producer: the UI thread).
pub const CmdQueue = SpscQueue(Cmd, CMD_CAPACITY);

/// Where retired processors come from: the graph's slot table (`takeRetired`).
pub const RetireSource = struct {
    ptr: *anyopaque,
    take_retired: *const fn (ptr: *anyopaque, out: []Processor) usize,

    pub fn takeRetired(self: RetireSource, out: []Processor) usize {
        return self.take_retired(self.ptr, out);
    }
};

/// Adapts any `SlotTable(...)` instance to a `RetireSource`.
pub fn retireSourceOf(comptime Table: type, table: *Table) RetireSource {
    const Adapter = struct {
        fn take(ptr: *anyopaque, out: []Processor) usize {
            const t: *Table = @ptrCast(@alignCast(ptr));
            return t.takeRetired(out);
        }
    };
    return .{ .ptr = table, .take_retired = Adapter.take };
}

/// Errors `Side` methods can return.
pub const SideError = Allocator.Error || plughost.plugin.EditorError || error{
    /// No editor is registered for the key (the Rust "no editor (or it is not loaded)").
    NoEditor,
    /// The audio thread's command queue is full; the command was not sent.
    CommandQueueFull,
};

/// Frees a list returned by `Side.captureStates` or `captureStatesOf`.
pub fn freeStates(gpa: Allocator, states: []PluginState) void {
    for (states) |s| gpa.free(s.bytes);
    gpa.free(states);
}

fn keyLessThan(_: void, a: Key, b: Key) bool {
    if (a.track != b.track) return a.track < b.track;
    return a.slot < b.slot;
}

fn containsKey(keys: []const Key, key: Key) bool {
    for (keys) |k| {
        if (k.track == key.track and k.slot == key.slot) return true;
    }
    return false;
}

fn containsSpec(specs: []const graph.slot.InstanceSpec, key: Key) bool {
    for (specs) |s| {
        if (s.track == key.track and s.slot == key.slot) return true;
    }
    return false;
}

/// UI-thread bookkeeping of the third-party instances the audio thread holds.
pub const Side = struct {
    /// What was last created for each slot.
    pub const Shadow = struct {
        /// Owned copy of the plugin id.
        id: []u8,
        channels: usize,
        /// The backend made the instance (false: it failed and is not retried).
        created: bool,
    };

    gpa: Allocator,
    backend: pi.Backend,
    /// Session sample rate the instances were prepared for.
    rate: f32,
    shadow: std.AutoHashMapUnmanaged(Key, Shadow) = .empty,
    /// Editor handles of the live instances.
    editors: std.AutoHashMapUnmanaged(Key, PluginEditor) = .empty,
    /// State readers of the live instances.
    states: std.AutoHashMapUnmanaged(Key, PluginStateReader) = .empty,
    /// Instances that refused their stored state: saves keep that state until the
    /// plugin's editor is opened.
    refused: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// The tracks of the session last seen, to tell which ones went.
    tracks: std.AutoHashMapUnmanaged(TrackId, void) = .empty,
    retire: RetireSource,
    /// Scratch for `collectGarbage`, allocated once in `init`.
    retire_buf: []Processor,
    /// Replaced snapshots coming back from the audio thread. Allocated on the first
    /// `returnOldSessions`; freed by `deinit`.
    old_sessions: ?*SnapshotQueue = null,

    /// Control thread. Allocates the scratch buffer only.
    pub fn init(gpa: Allocator, rate: f32, backend: pi.Backend, retire: RetireSource) Allocator.Error!Side {
        const buf = try gpa.alloc(Processor, GARBAGE_BATCH);
        return .{ .gpa = gpa, .backend = backend, .rate = rate, .retire = retire, .retire_buf = buf };
    }

    /// Frees the bookkeeping. Destroy retired processors first (`collectGarbage`), and
    /// stop the audio thread before this: it still holds the snapshot queue.
    pub fn deinit(self: *Side) void {
        var it = self.shadow.valueIterator();
        while (it.next()) |sh| self.gpa.free(sh.id);
        self.shadow.deinit(self.gpa);
        self.editors.deinit(self.gpa);
        self.states.deinit(self.gpa);
        self.refused.deinit(self.gpa);
        self.tracks.deinit(self.gpa);
        self.gpa.free(self.retire_buf);
        if (self.old_sessions) |q| {
            while (q.pop()) |h| h.release();
            self.gpa.destroy(q);
            self.old_sessions = null;
        }
    }

    /// Notes the session's tracks. Returns the ones the previous session had and this
    /// one does not. The caller frees the slice with `gpa`.
    pub fn goneTracks(self: *Side, source: pi.SlotSource) Allocator.Error![]TrackId {
        var now: std.AutoHashMapUnmanaged(TrackId, void) = .empty;
        errdefer now.deinit(self.gpa);
        for (source.tracks()) |t| try now.put(self.gpa, t, {});
        var gone: std.ArrayList(TrackId) = .empty;
        errdefer gone.deinit(self.gpa);
        var it = self.tracks.keyIterator();
        while (it.next()) |k| {
            if (!now.contains(k.*)) try gone.append(self.gpa, k.*);
        }
        self.tracks.deinit(self.gpa);
        self.tracks = now;
        return gone.toOwnedSlice(self.gpa);
    }

    /// Destroys retired processors (closing their editors first is the plugin's own drop
    /// business) and releases the replaced snapshots. Call once per UI frame.
    pub fn collectGarbage(self: *Side) void {
        while (true) {
            const n = self.retire.takeRetired(self.retire_buf);
            for (self.retire_buf[0..n]) |p| p.destroy();
            if (n < self.retire_buf.len) break;
        }
        if (self.old_sessions) |q| {
            while (q.pop()) |h| h.release();
        }
    }

    /// Sends the audio thread the queue it returns replaced snapshots through. Call once
    /// per session engine; calling again reuses the queue.
    pub fn returnOldSessions(self: *Side, cmds: *CmdQueue) SideError!void {
        if (self.old_sessions == null) {
            const q = try self.gpa.create(SnapshotQueue);
            q.* = .{};
            self.old_sessions = q;
        }
        if (!cmds.push(.{ .old_sessions = self.old_sessions.? })) return error.CommandQueueFull;
    }

    /// Drops every record of `key`: its shadow entry, state reader and refusal, and closes
    /// and removes its editor.
    pub fn forget(self: *Side, key: Key) void {
        if (self.shadow.fetchRemove(key)) |kv| self.gpa.free(kv.value.id);
        _ = self.states.remove(key);
        _ = self.refused.remove(key);
        if (self.editors.fetchRemove(key)) |kv| kv.value.close();
    }

    /// Creates the third-party instances `source` needs that the audio thread does not
    /// have yet, and returns them. Each slot is created at most once per plugin id and
    /// channel count; a failed creation is remembered and not retried. The caller adopts
    /// the returned instances into the graph's slot table and frees the slice with `gpa`.
    pub fn prepare(self: *Side, source: pi.SlotSource) SideError![]PreparedInstance {
        self.collectGarbage();
        const sr = source.sampleRate();
        if (@abs(sr - self.rate) > 0.5) {
            // The audio thread rebuilds its engine: everything is created anew.
            var all: std.ArrayList(Key) = .empty;
            defer all.deinit(self.gpa);
            var kit = self.shadow.keyIterator();
            while (kit.next()) |k| try all.append(self.gpa, k.*);
            for (all.items) |k| self.forget(k);
            self.rate = sr;
        }
        const specs = try pi.instanceSpecs(self.gpa, source);
        defer self.gpa.free(specs);

        var stale: std.ArrayList(Key) = .empty;
        defer stale.deinit(self.gpa);
        var sit = self.shadow.keyIterator();
        while (sit.next()) |k| {
            if (!containsSpec(specs, k.*)) try stale.append(self.gpa, k.*);
        }
        for (stale.items) |k| self.forget(k);

        var out: std.ArrayList(PreparedInstance) = .empty;
        errdefer {
            // Nothing is handed back on failure: destroy what was made and forget it, so the
            // next prepare creates it again.
            for (out.items) |p| {
                self.forget(.{ .track = p.track, .slot = p.slot });
                p.processor.destroy();
            }
            out.deinit(self.gpa);
        }

        for (specs) |spec| {
            const key: Key = .{ .track = spec.track, .slot = spec.slot };
            if (self.shadow.get(key)) |sh| {
                if (sh.channels == spec.ch and std.mem.eql(u8, sh.id, spec.id)) continue;
            }
            self.forget(key);
            // Reserve every slot this step fills before creating the plugin, so nothing after
            // the creation can fail and leak it.
            try self.shadow.ensureUnusedCapacity(self.gpa, 1);
            try self.states.ensureUnusedCapacity(self.gpa, 1);
            try self.editors.ensureUnusedCapacity(self.gpa, 1);
            try self.refused.ensureUnusedCapacity(self.gpa, 1);
            try out.ensureUnusedCapacity(self.gpa, 1);
            const id_copy = try self.gpa.dupe(u8, spec.id);
            errdefer self.gpa.free(id_copy);
            const made = try pi.createInstance(self.gpa, self.backend, spec.id, spec.state, sr, BLOCK, spec.ch);
            log.debug("plugin instance for track {d} slot {d}: {s} ({d} ch, created: {})", .{ spec.track, spec.slot, spec.id, spec.ch, made != null });
            self.shadow.putAssumeCapacity(key, .{ .id = id_copy, .channels = spec.ch, .created = made != null });
            const m = made orelse continue;
            if (m.plugin.editor()) |e| self.storeEditor(key, e);
            if (m.plugin.stateReader()) |r| self.states.putAssumeCapacity(key, r);
            if (m.refused_state) self.refused.putAssumeCapacity(key, {});
            out.appendAssumeCapacity(.{ .track = spec.track, .slot = spec.slot, .processor = m.processor, .channels = spec.ch });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Plugin states of every live instance that did not refuse its stored state, sorted by
    /// (track, slot). The caller frees the list with `freeStates`.
    pub fn captureStates(self: *Side) SideError![]PluginState {
        return self.captureWhere(null);
    }

    /// Like `captureStates`, restricted to `slots`.
    pub fn captureStatesOf(self: *Side, slots: []const Key) SideError![]PluginState {
        return self.captureWhere(slots);
    }

    fn captureWhere(self: *Side, only: ?[]const Key) SideError![]PluginState {
        var keys: std.ArrayList(Key) = .empty;
        defer keys.deinit(self.gpa);
        var it = self.states.keyIterator();
        while (it.next()) |k| {
            if (self.refused.contains(k.*)) continue;
            if (only) |slots| {
                if (!containsKey(slots, k.*)) continue;
            }
            try keys.append(self.gpa, k.*);
        }
        std.mem.sort(Key, keys.items, {}, keyLessThan);

        var out: std.ArrayList(PluginState) = .empty;
        errdefer freeStates(self.gpa, out.items);
        errdefer out.deinit(self.gpa);
        for (keys.items) |k| {
            const reader = self.states.get(k) orelse continue;
            try out.ensureUnusedCapacity(self.gpa, 1);
            const maybe = try reader.saveState(self.gpa);
            const bytes = maybe orelse continue;
            out.appendAssumeCapacity(.{ .track = k.track, .slot = k.slot, .bytes = bytes });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// The keys whose plugin said its state changed since the last call (each change is
    /// reported once). The caller frees the slice with `gpa`.
    pub fn changedStates(self: *Side) Allocator.Error![]Key {
        var out: std.ArrayList(Key) = .empty;
        errdefer out.deinit(self.gpa);
        var it = self.editors.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.stateChanged()) try out.append(self.gpa, entry.key_ptr.*);
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Registers the editor of a freshly made instance. A plugin that marks its state dirty
    /// while it loads or restores it has not changed, so the flag is cleared here.
    pub fn addEditor(self: *Side, key: Key, e: PluginEditor) Allocator.Error!void {
        try self.editors.ensureUnusedCapacity(self.gpa, 1);
        self.storeEditor(key, e);
    }

    fn storeEditor(self: *Side, key: Key, e: PluginEditor) void {
        _ = e.stateChanged();
        self.editors.putAssumeCapacity(key, e);
    }

    /// Opens the plugin's own editor window. A successful open clears the refusal, so the
    /// next save writes the plugin's state.
    pub fn openEditor(self: *Side, key: Key) SideError!void {
        const e = self.editors.get(key) orelse return error.NoEditor;
        try e.open();
        _ = self.refused.remove(key);
    }
};

// --- tests: ports of playback/src/tests.rs (same names, same expectations) ---

const testing = std.testing;
const fake = pi.test_support;

/// A retire source with nothing retired, for tests that do not drive the graph.
const NoRetire = struct {
    var ctx: u8 = 0;
    fn take(_: *anyopaque, _: []Processor) usize {
        return 0;
    }
    fn source() RetireSource {
        return .{ .ptr = &ctx, .take_retired = take };
    }
};

fn testSide(backend: pi.Backend, retire: RetireSource) Allocator.Error!Side {
    return Side.init(testing.allocator, 48_000.0, backend, retire);
}

/// A state reader over fixed bytes (null: the plugin has no state).
const Bytes = struct {
    value: ?[]const u8,

    const vtable: PluginStateReader.VTable = .{ .save_state = saveFn };

    fn saveFn(ptr: *anyopaque, gpa: Allocator) Allocator.Error!?[]u8 {
        const self: *Bytes = @ptrCast(@alignCast(ptr));
        const v = self.value orelse return null;
        return try gpa.dupe(u8, v);
    }

    fn reader(self: *Bytes) PluginStateReader {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// An editor without a dirty flag.
const Window = struct {
    const vtable: PluginEditor.VTable = .{ .open = openFn, .close = closeFn, .is_open = isOpenFn, .idle = idleFn };

    fn openFn(_: *anyopaque) plughost.plugin.EditorError!void {}
    fn closeFn(_: *anyopaque) void {}
    fn isOpenFn(_: *anyopaque) bool {
        return false;
    }
    fn idleFn(_: *anyopaque, _: Allocator) Allocator.Error![]plughost.plugin.ParamEdit {
        return &.{};
    }

    fn editor(self: *Window) PluginEditor {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// An editor whose plugin said its state changed (CLAP `state.mark_dirty`).
const Dirty = struct {
    dirty: bool,

    const vtable: PluginEditor.VTable = .{
        .open = openFn,
        .close = closeFn,
        .is_open = isOpenFn,
        .idle = idleFn,
        .state_changed = stateChangedFn,
    };

    fn fromPtr(ptr: *anyopaque) *Dirty {
        return @ptrCast(@alignCast(ptr));
    }

    fn openFn(_: *anyopaque) plughost.plugin.EditorError!void {}
    fn closeFn(_: *anyopaque) void {}
    fn isOpenFn(_: *anyopaque) bool {
        return true;
    }
    fn idleFn(_: *anyopaque, _: Allocator) Allocator.Error![]plughost.plugin.ParamEdit {
        return &.{};
    }
    fn stateChangedFn(ptr: *anyopaque) bool {
        const self = fromPtr(ptr);
        const was = self.dirty;
        self.dirty = false;
        return was;
    }

    fn editor(self: *Dirty) PluginEditor {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// A session snapshot for the replacement test: one reference, freed when the count drops.
const Snap = struct {
    refs: u32 = 1,
    alive: bool = true,

    fn handle(self: *Snap) SnapshotHandle {
        return .{ .ptr = self, .release_fn = release };
    }

    fn release(ptr: *anyopaque) void {
        const self: *Snap = @ptrCast(@alignCast(ptr));
        self.refs -= 1;
        if (self.refs == 0) self.alive = false;
    }
};

/// The audio thread's side of the command queue: takes the return channel and the
/// snapshots, and returns the snapshots it replaces (`AudioState::drain` and `fill`).
const FakeAudio = struct {
    current: SnapshotHandle,
    old_out: ?*SnapshotQueue = null,

    fn drain(self: *FakeAudio, cmds: *CmdQueue) void {
        while (cmds.pop()) |cmd| {
            switch (cmd) {
                .old_sessions => |q| self.old_out = q,
                .session => |next| {
                    const old = self.current;
                    self.current = next;
                    if (self.old_out) |q| {
                        // A full return channel drops the snapshot here (as try_send does).
                        if (!q.push(old)) old.release();
                    } else {
                        old.release();
                    }
                },
            }
        }
    }
};

test "instances_arrive_with_the_session_and_leave_through_the_return_channel" {
    const gpa = testing.allocator;
    const Table = graph.slot.SlotTable(4, 10, 8);
    var table: Table = .{};
    const track: TrackId = 1;
    const tracks = [_]TrackId{track};
    var with_insert: fake.TestSource = .{
        .rate = 48_000.0,
        .track_list = &tracks,
        .slot_list = &.{.{ .track = track, .slot = 1, .plugin = "clap:test.fake", .channels = 2 }},
    };
    var without: fake.TestSource = .{ .rate = 48_000.0, .track_list = &tracks, .slot_list = &.{} };
    var backend_state: fake.FakeBackend = .{ .known = &.{"clap:test.fake"} };
    var side = try testSide(backend_state.backend(), retireSourceOf(Table, &table));
    defer side.deinit();

    // Instance A arrives with its session: adopted, placed on the audio thread, nothing retired.
    const a = try side.prepare(with_insert.source());
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 1), a.len);
    for (a) |p| try table.adopt(p);
    try testing.expect(table.configure(track, 1, 2));
    table.service();
    var buf: [Table.max_drained]Processor = undefined;
    try testing.expectEqual(@as(usize, 0), table.takeRetired(&buf));

    // A session without the insert retires the instance to the return channel.
    const none = try side.prepare(without.source());
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expect(table.removeSlot(track, 1));
    table.service();
    const retired = table.takeRetired(&buf);
    try testing.expectEqual(@as(usize, 1), retired);
    buf[0].destroy();

    // Instance B arrives again.
    const b = try side.prepare(with_insert.source());
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 1), b.len);
    for (b) |p| try table.adopt(p);
    try testing.expect(table.configure(track, 1, 2));
    table.service();

    // A sample-rate change rebuilds the engine: its plugins come back through the drain, on
    // the UI thread.
    var moved: fake.TestSource = .{ .rate = 44_100.0, .track_list = &tracks, .slot_list = &.{} };
    const none_44 = try side.prepare(moved.source());
    defer gpa.free(none_44);
    const drained = try table.drainPlugins(&buf);
    try testing.expectEqual(@as(usize, 1), drained);
    for (buf[0..drained]) |p| p.destroy();
    try testing.expectEqual(@as(usize, 2), backend_state.destroys);
}

test "plugin_states_are_read_without_the_audio_thread" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    const a: TrackId = 1;
    const b: TrackId = 2;
    var b0 = Bytes{ .value = "b0" };
    var synth = Bytes{ .value = "synth" };
    var a3 = Bytes{ .value = "a3" };
    var a4 = Bytes{ .value = null };
    try side.states.put(gpa, .{ .track = b, .slot = 0 }, b0.reader());
    try side.states.put(gpa, .{ .track = a, .slot = INSTRUMENT_SLOT }, synth.reader());
    try side.states.put(gpa, .{ .track = a, .slot = 3 }, a3.reader());
    try side.states.put(gpa, .{ .track = a, .slot = 4 }, a4.reader());

    const got = try side.captureStates();
    defer freeStates(gpa, got);
    try expectStates(&.{
        .{ .track = a, .slot = 3, .bytes = "a3" },
        .{ .track = a, .slot = INSTRUMENT_SLOT, .bytes = "synth" },
        .{ .track = b, .slot = 0, .bytes = "b0" },
    }, got);

    side.forget(.{ .track = a, .slot = 3 });
    const after = try side.captureStates();
    defer freeStates(gpa, after);
    try expectStates(&.{
        .{ .track = a, .slot = INSTRUMENT_SLOT, .bytes = "synth" },
        .{ .track = b, .slot = 0, .bytes = "b0" },
    }, after);
}

const Expect = struct { track: TrackId, slot: usize, bytes: []const u8 };

fn expectStates(want: []const Expect, got: []const PluginState) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.track, g.track);
        try testing.expectEqual(w.slot, g.slot);
        try testing.expectEqualStrings(w.bytes, g.bytes);
    }
}

test "a_refused_state_is_kept_until_the_editor_opens" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    const k: Key = .{ .track = 1, .slot = 0 };
    var defaults = Bytes{ .value = "defaults" };
    try side.states.put(gpa, k, defaults.reader());
    var win = Window{};
    try side.editors.put(gpa, k, win.editor());
    try side.refused.put(gpa, k, {});

    const before = try side.captureStates();
    defer freeStates(gpa, before);
    try testing.expectEqual(@as(usize, 0), before.len);

    try side.openEditor(k);
    const after = try side.captureStates();
    defer freeStates(gpa, after);
    try expectStates(&.{.{ .track = 1, .slot = 0, .bytes = "defaults" }}, after);
}

test "changed_states_are_reported_once_and_read_for_the_session" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    const a: TrackId = 1;
    const b: TrackId = 2;
    const synth: Key = .{ .track = a, .slot = INSTRUMENT_SLOT };
    var a0 = Bytes{ .value = "a0" };
    var a1 = Bytes{ .value = "a1" };
    var s = Bytes{ .value = "synth" };
    var b0 = Bytes{ .value = "b0" };
    try side.states.put(gpa, .{ .track = a, .slot = 0 }, a0.reader());
    try side.states.put(gpa, .{ .track = a, .slot = 1 }, a1.reader());
    try side.states.put(gpa, synth, s.reader());
    try side.states.put(gpa, .{ .track = b, .slot = 0 }, b0.reader());
    var dirty_a0 = Dirty{ .dirty = true };
    var dirty_a1 = Dirty{ .dirty = false };
    var dirty_b0 = Dirty{ .dirty = true };
    try side.editors.put(gpa, .{ .track = a, .slot = 0 }, dirty_a0.editor());
    try side.editors.put(gpa, .{ .track = a, .slot = 1 }, dirty_a1.editor());
    try side.editors.put(gpa, .{ .track = b, .slot = 0 }, dirty_b0.editor());
    try side.refused.put(gpa, .{ .track = b, .slot = 0 }, {});

    const changed = try side.changedStates();
    defer gpa.free(changed);
    std.mem.sort(Key, changed, {}, keyLessThan);
    try testing.expectEqual(@as(usize, 2), changed.len);
    try testing.expect(changed[0].track == a and changed[0].slot == 0);
    try testing.expect(changed[1].track == b and changed[1].slot == 0);

    const again = try side.changedStates();
    defer gpa.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);

    const got = try side.captureStatesOf(&.{ .{ .track = a, .slot = 0 }, synth, .{ .track = b, .slot = 0 } });
    defer freeStates(gpa, got);
    try expectStates(&.{
        .{ .track = a, .slot = 0, .bytes = "a0" },
        .{ .track = a, .slot = INSTRUMENT_SLOT, .bytes = "synth" },
    }, got);
}

test "a_state_marked_changed_while_loading_is_not_a_change" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    const k: Key = .{ .track = 1, .slot = 0 };
    var loaded = Bytes{ .value = "loaded" };
    try side.states.put(gpa, k, loaded.reader());
    var dirty = Dirty{ .dirty = true };
    try side.addEditor(k, dirty.editor());
    const changed = try side.changedStates();
    defer gpa.free(changed);
    try testing.expectEqual(@as(usize, 0), changed.len);
}

test "side_creates_each_missing_instance_once" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    const t: TrackId = 1;
    const tracks = [_]TrackId{t};
    var entries = [_]pi.SlotEntry{
        .{ .track = t, .slot = 0, .plugin = "clap:does.not.exist", .channels = 1 },
        .{ .track = t, .slot = 1, .plugin = "gain", .channels = 1 },
    };
    var src: fake.TestSource = .{ .rate = 48_000.0, .track_list = &tracks, .slot_list = &entries };

    const first = try side.prepare(src.source());
    defer gpa.free(first);
    try testing.expectEqual(@as(usize, 0), first.len);
    const sh = side.shadow.get(.{ .track = t, .slot = 0 }).?;
    try testing.expectEqualStrings("clap:does.not.exist", sh.id);
    try testing.expectEqual(@as(usize, 1), sh.channels);
    try testing.expect(!sh.created);

    const second = try side.prepare(src.source());
    defer gpa.free(second);
    try testing.expectEqual(@as(usize, 0), second.len);
    try testing.expectEqual(@as(usize, 1), side.shadow.count());
    try testing.expectEqual(@as(usize, 1), backend_state.attempts);

    entries[0].plugin = "gain";
    const gone = try side.prepare(src.source());
    defer gpa.free(gone);
    try testing.expectEqual(@as(usize, 0), side.shadow.count());
}

test "replaced_sessions_are_freed_on_the_ui_thread" {
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    var side = try testSide(backend_state.backend(), NoRetire.source());
    defer side.deinit();
    var cmds: CmdQueue = .{};
    try side.returnOldSessions(&cmds);

    var storage: [3 * OLD_SESSIONS + 1]Snap = @splat(.{});
    var audio = FakeAudio{ .current = storage[0].handle() };
    audio.drain(&cmds);

    var i: usize = 0;
    while (i < 3 * OLD_SESSIONS) : (i += 1) {
        side.collectGarbage();
        try testing.expect(cmds.push(.{ .session = storage[i + 1].handle() }));
        audio.drain(&cmds);
        if (i >= 1) {
            // The snapshot the audio thread just replaced is held only by the return queue.
            const replaced = &storage[i];
            try testing.expect(replaced.alive);
            try testing.expectEqual(@as(u32, 1), replaced.refs);
        }
    }
    side.collectGarbage();
    var live: usize = 0;
    for (storage) |s| {
        if (s.alive) live += 1;
    }
    try testing.expectEqual(@as(usize, 1), live);
}
