// Translated to Zig from soundcraft/crates/vst3-host/src/plugin.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! `Vst3Plugin`: a loaded VST3 instance behind the plug-0 `Plugin` handle (`../plugin.zig`),
//! over `instance.zig`, `process.zig` and `editor.zig`.
//!
//! Differences from the Rust code, all deliberate:
//! * Parameters are addressed by dense index (`PluginInfo.params` order, which must match the
//!   instance's `ParamTable`). The Rust string ids stay in `PluginInfo` for the UI only.
//! * The Rust `note_on` / `note_off` / `midi` queue methods are the sorted `event.Event` slice
//!   of `process`. Notes are converted straight into the preallocated VST3 event list of the
//!   `ProcessBlock`; MIDI controllers become parameter points through `IMidiMapping`. The only
//!   persistent note queue left is `NoteQueue`, the releases `reset` schedules for the next
//!   block (the Rust `notes` vector, bounded the same way).
//! * `process` builds the VST3 `ProcessData` itself (`ProcessBlock.begin`, then the pending and
//!   event parameter points, then `IAudioProcessor::process`) instead of calling
//!   `Instance.process`, so host-normalized values reach the input queue without going through
//!   plain values and so the plugin's output parameter queue can be read afterwards.
//! * Parameter changes the plugin makes by itself (its own automation or GUI motion, reported
//!   in `ProcessData.outputParameterChanges`) are copied into a bounded preallocated outbox and
//!   handed to the UI by `idle`. Edits made in the editor (`performEdit`) are returned by
//!   `idle` and also forwarded, through a second bounded queue, into the input queue of the next
//!   block, so the audio side and the GUI stay in sync even before the session writes the value
//!   back with `setParam`.
//! * The handles returned by `editor` / `stateReader` each hold one reference on a shared
//!   control block; give them back with `PluginEditor.release` / `PluginStateReader.release`
//!   (or `releaseEditor` / `releaseStateReader`). Forgetting only leaks that small block.
//!
//! Threading. `prepare`, `reset`, `setParam`, `loadState`, `saveState` and the editor calls are
//! control or UI thread only (they may allocate and call the controller). `process` is the audio
//! thread: it allocates nothing, takes no lock, logs nothing and does no I/O. The plugin is
//! dropped on the control thread only (`deinit`), which runs `Instance.destroy` and so keeps the
//! module exit ordering of `instance.zig` and `module.zig`.

const std = @import("std");
const abi = @import("abi.zig");
const host_mod = @import("host.zig");
const process_mod = @import("process.zig");
const editor_mod = @import("editor.zig");
const inst_mod = @import("instance.zig");
const plug = @import("../plugin.zig");

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Plugin = plug.Plugin;
const PluginInfo = plug.PluginInfo;
const PluginEditor = plug.PluginEditor;
const PluginStateReader = plug.PluginStateReader;
const ParamEdit = plug.ParamEdit;
const AudioBlock = plug.AudioBlock;
const Event = plug.Event;
const Transport = plug.Transport;
const ParamInfo = plug.ParamInfo;
const Instance = inst_mod.Instance;
const Mapping = inst_mod.Mapping;
const NoteEvent = process_mod.NoteEvent;
const EditorLink = editor_mod.EditorLink;
const HostContext = host_mod.HostContext;

const log = std.log.scoped(.plughost_vst3);

/// Largest block we set a plugin up for.
pub const MAX_BLOCK: usize = 1 << 16;
/// Most channels a host strip may ask for. The Rust code allowed 64; the planar `AudioBlock`
/// carries at most `plug.MAX_CHANNELS`.
pub const MAX_CHANNELS: usize = plug.MAX_CHANNELS;
/// An `unsynced` slot with no value waiting (a NaN pattern, which `setParam` never stores).
const SYNCED: u64 = std.math.maxInt(u64);
/// Slots of each cross-thread parameter queue (editor to audio, plugin to UI).
pub const QUEUE_CAP: usize = 256;
/// Notes in a MIDI 1.0 channel.
const KEYS: usize = 128;
const MIDI_DATA_MAX: u8 = 127;
const MIDI_14BIT_MAX: f64 = 16383.0;
const STATUS_MASK: u8 = 0xF0;
const STATUS_POLY_PRESSURE: u8 = 0xA0;
const STATUS_CONTROL_CHANGE: u8 = 0xB0;
const STATUS_CHANNEL_PRESSURE: u8 = 0xD0;
const STATUS_PITCH_BEND: u8 = 0xE0;
/// Sample rate used when the host gives a non-positive or non-finite one.
const FALLBACK_SAMPLE_RATE: f64 = 48_000.0;

pub const Error = error{
    OutOfMemory,
    /// `PluginInfo.params` does not match the instance's parameter table (count or ids).
    ParamMismatch,
};

// ---- note queue ------------------------------------------------------------------------------

/// Pending notes, kept sorted by time, in storage allocated once. Never grows past its capacity
/// (the Rust `notes: Vec<NoteEvent>` with `EVENT_CAP`).
pub const NoteQueue = struct {
    buf: []NoteEvent,
    len: usize = 0,

    pub fn init(gpa: Allocator, cap: usize) Allocator.Error!NoteQueue {
        return .{ .buf = try gpa.alloc(NoteEvent, cap) };
    }

    pub fn deinit(self: *NoteQueue, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn items(self: *const NoteQueue) []const NoteEvent {
        return self.buf[0..self.len];
    }
};

/// Inserts keeping the queue time-sorted (after equal times); drops the event when the queue is
/// full (never allocates).
pub fn pushSorted(q: *NoteQueue, e: NoteEvent) void {
    if (q.len >= q.buf.len) return;
    var pos: usize = q.len;
    while (pos > 0 and q.buf[pos - 1].time() > e.time()) : (pos -= 1) {}
    var i = q.len;
    while (i > pos) : (i -= 1) q.buf[i] = q.buf[i - 1];
    q.buf[pos] = e;
    q.len += 1;
}

/// Keeps only the pending releases, one per key and moved to the start of the next block, so at
/// most 128 remain and `allNotesOff` always has room in the queue.
pub fn keepReleases(q: *NoteQueue) void {
    var seen: [KEYS]bool = @splat(false);
    var w: usize = 0;
    for (q.buf[0..q.len]) |e| {
        switch (e) {
            .off => |o| {
                if (o.key < KEYS and !seen[o.key]) {
                    seen[o.key] = true;
                    q.buf[w] = e;
                    w += 1;
                }
            },
            else => {},
        }
    }
    q.len = w;
    for (q.buf[0..q.len]) |*e| e.setTime(0);
}

// ---- cross-thread queue ----------------------------------------------------------------------

/// A normalized parameter value for a dense index.
const Change = struct { index: u32, value: f64 };

/// Single-producer single-consumer ring, wait-free, no allocation.
// TODO(core): use core.SpscQueue once core exports it.
fn Ring(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        buf: [cap]T = undefined,
        /// Next slot the consumer reads.
        head: Atomic(usize) = .init(0),
        /// Next slot the producer writes.
        tail: Atomic(usize) = .init(0),

        /// Producer side. False (value dropped) when full.
        fn push(self: *Self, v: T) bool {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h >= cap) return false;
            self.buf[t % cap] = v;
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Consumer side.
        fn pop(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h == t) return null;
            const v = self.buf[h % cap];
            self.head.store(h +% 1, .release);
            return v;
        }
    };
}

const IdIndex = struct { id: u32, index: u32 };

fn idLess(_: void, a: IdIndex, b: IdIndex) bool {
    return a.id < b.id;
}

// ---- value mapping ---------------------------------------------------------------------------

/// A table value for a normalized one (`plain_from_normalized`), unclamped. `src` is the
/// `Instance` (plugin side) or the `EditorLink` (editor side): both answer `toPlain`.
fn plainFrom(src: anytype, pi: ParamInfo, map: Mapping, id: u32, n: f64) ?f32 {
    const v: f64 = switch (map) {
        .stepped => |steps| @round(n * steps),
        .plain => src.toPlain(id, n) orelse return null,
        .linear => @as(f64, pi.min) + n * @as(f64, pi.max - pi.min),
    };
    return if (std.math.isFinite(v)) @floatCast(v) else null;
}

/// The normalized value for a table value (`normalized_from_plain`), clamped to 0..1.
fn normalizedFrom(src: anytype, pi: ParamInfo, map: Mapping, id: u32, v: f32) ?f64 {
    const span: f64 = @as(f64, pi.max) - @as(f64, pi.min);
    const linear: f64 = if (span > 0.0) (@as(f64, v) - @as(f64, pi.min)) / span else 0.0;
    const n: f64 = switch (map) {
        .stepped => |steps| if (steps > 0.0) @as(f64, v) / steps else 0.0,
        .plain => src.toNormalized(id, @as(f64, v)) orelse linear,
        .linear => linear,
    };
    return if (std.math.isFinite(n)) std.math.clamp(n, 0.0, 1.0) else null;
}

/// The same mapping without calling the plugin, for the audio thread: plain values go through
/// the table's own range and taper.
fn normalizedLocal(pi: ParamInfo, map: Mapping, v: f32) f64 {
    const n: f64 = switch (map) {
        .stepped => |steps| if (steps > 0.0) @as(f64, v) / steps else 0.0,
        .plain, .linear => @as(f64, pi.toNormalized(v)),
    };
    return if (std.math.isFinite(n)) std.math.clamp(n, 0.0, 1.0) else 0.0;
}

fn editorError(e: editor_mod.EditorError) plug.EditorError {
    return switch (e) {
        error.NoEditor => error.NoEditor,
        else => error.OpenFailed,
    };
}

// ---- shared control block --------------------------------------------------------------------

/// What the plugin, its editor handles and its state readers share. Reference counted so a
/// handle held by the UI stays valid (and inert) after the plugin is dropped.
const Shared = struct {
    gpa: Allocator,
    refs: Atomic(usize) = .init(1),
    /// Must outlive every handle (it is `PluginInfo` data owned by the registry).
    info: *const PluginInfo,
    link: *EditorLink,
    host: *HostContext,
    ids: []u32,
    maps: []Mapping,
    /// The plugin's own unit label of each parameter, owned.
    units: [][]u8,
    by_id: []IdIndex,
    /// Host-set normalized values the controller has not seen yet (the bits of an `f64`, or
    /// `SYNCED`). `setParam` may run near the audio thread, so it never calls the controller;
    /// the state reader, which already does, hands them over first.
    unsynced: []Atomic(u64),
    /// Editor to audio: edits forwarded into the next block.
    to_audio: Ring(Change, QUEUE_CAP) = .{},
    /// Audio to UI: parameter changes the plugin made by itself.
    from_plugin: Ring(Change, QUEUE_CAP) = .{},

    fn indexOf(self: *const Shared, id: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = self.by_id.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.by_id[mid];
            if (e.id == id) return e.index;
            if (e.id < id) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn retain(self: *Shared) *Shared {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = self.gpa;
        self.link.release();
        self.host.release();
        for (self.units) |u| gpa.free(u);
        gpa.free(self.units);
        gpa.free(self.ids);
        gpa.free(self.maps);
        gpa.free(self.by_id);
        gpa.free(self.unsynced);
        gpa.destroy(self);
    }

    /// Hands pending host-set values to the controller, then saves. Control or UI thread.
    fn saveState(self: *Shared, gpa: Allocator) Allocator.Error!?[]u8 {
        // A parameter only the controller stores (no processor state) would otherwise be saved
        // with the controller's stale value.
        for (self.ids, self.unsynced) |id, *u| {
            const bits = u.swap(SYNCED, .monotonic);
            if (bits != SYNCED) self.link.syncParam(id, @bitCast(bits));
        }
        return self.link.saveState(gpa);
    }

    fn plain(self: *Shared, i: usize, n: f64) ?f32 {
        if (i >= self.ids.len) return null;
        const pi = self.info.params[i];
        const v = plainFrom(self.link, pi, self.maps[i], self.ids[i], n) orelse return null;
        return pi.clamp(v);
    }

    fn normalized(self: *Shared, i: usize, v: f32) ?f64 {
        if (i >= self.ids.len) return null;
        return normalizedFrom(self.link, self.info.params[i], self.maps[i], self.ids[i], v);
    }
};

fn sharedFrom(ptr: *anyopaque) *Shared {
    return @ptrCast(@alignCast(ptr));
}

// ---- the plugin ------------------------------------------------------------------------------

/// A hosted VST3 plugin. Parameters are `info.params` entries in order, with their VST3
/// `ParamID` parsed from the decimal id strings; values are plain (display) values.
pub const Vst3Plugin = struct {
    gpa: Allocator,
    /// Owned: `deinit` destroys it.
    inst: *Instance,
    info: *const PluginInfo,
    shared: *Shared,
    values: []f32,
    /// Normalized values waiting for the next block (coalesced per parameter; bounded).
    pending: []Change,
    pending_len: usize = 0,
    /// Releases scheduled by `reset`, delivered at the start of the next block.
    notes: NoteQueue,
    /// The parameter each MIDI controller drives (`Instance.midiMapping`).
    midi_map: []?u32 = &.{},
    has_input: bool = false,
    has_output: bool = false,
    event_input: bool = false,
    held: [KEYS]bool = @splat(false),
    channels: usize = 2,
    max_block: usize = 0,
    latency: usize = 0,
    tail: usize = 0,
    position: i64 = 0,
    transport: ?Transport = null,

    /// Control thread. Takes ownership of `inst` (destroyed on error and by `deinit`).
    /// `info.params` must be the instance's parameter table (`Instance.paramTable`), in order.
    pub fn init(gpa: Allocator, inst: *Instance, info: *const PluginInfo) Error!Vst3Plugin {
        errdefer inst.destroy();
        const table = try inst.paramTable();
        const n = table.ids.len;
        if (info.params.len != n) return error.ParamMismatch;
        for (info.params, table.ids) |p, id| {
            // Rust: `id.parse::<u32>().unwrap_or(u32::MAX)`.
            const parsed = std.fmt.parseInt(u32, p.id, 10) catch std.math.maxInt(u32);
            if (parsed != id) return error.ParamMismatch;
        }

        const link = inst.editor_link.retain();
        errdefer link.release();
        const hc = inst.hostContext();
        _ = hc.refs.add();
        errdefer hc.release();
        const ids = try gpa.dupe(u32, table.ids);
        errdefer gpa.free(ids);
        const maps = try gpa.dupe(Mapping, table.maps);
        errdefer gpa.free(maps);
        const by_id = try gpa.alloc(IdIndex, n);
        errdefer gpa.free(by_id);
        for (by_id, ids, 0..) |*e, id, i| e.* = .{ .id = id, .index = @intCast(i) };
        std.mem.sort(IdIndex, by_id, {}, idLess);
        const unsynced = try gpa.alloc(Atomic(u64), n);
        errdefer gpa.free(unsynced);
        for (unsynced) |*u| u.* = .init(SYNCED);
        const units = try gpa.alloc([]u8, n);
        errdefer gpa.free(units);
        var made: usize = 0;
        errdefer for (units[0..made]) |u| gpa.free(u);
        {
            const raw = try inst.params(gpa);
            defer inst_mod.freeParams(gpa, raw);
            for (ids, 0..) |id, i| {
                var label: []const u8 = "";
                for (raw) |r| {
                    if (r.id == id) {
                        label = r.units;
                        break;
                    }
                }
                units[i] = try gpa.dupe(u8, label);
                made += 1;
            }
        }

        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        shared.* = .{
            .gpa = gpa,
            .info = info,
            .link = link,
            .host = hc,
            .ids = ids,
            .maps = maps,
            .units = units,
            .by_id = by_id,
            .unsynced = unsynced,
        };
        // From here `shared` owns link, host, ids, maps, units, by_id and unsynced.
        const values = gpa.alloc(f32, n) catch |e| {
            shared.release();
            return e;
        };
        const pending = gpa.alloc(Change, @min(n, abi.PARAM_QUEUE_CAP)) catch |e| {
            gpa.free(values);
            shared.release();
            return e;
        };
        const notes = NoteQueue.init(gpa, abi.EVENT_CAP) catch |e| {
            gpa.free(values);
            gpa.free(pending);
            shared.release();
            return e;
        };
        for (info.params, ids, maps, values) |pi, id, map, *slot| {
            slot.* = if (inst.normalizedValue(id)) |nv|
                (if (plainFrom(inst, pi, map, id, nv)) |v| pi.clamp(v) else pi.default)
            else
                pi.default;
        }
        return .{
            .gpa = gpa,
            .inst = inst,
            .info = info,
            .shared = shared,
            .values = values,
            .pending = pending,
            .notes = notes,
        };
    }

    /// Control thread, the thread that created it. Destroys the instance in the order
    /// `Instance.destroy` documents (editor closed first, bundle released last). Editor and
    /// state-reader handles still held by the UI become inert.
    pub fn deinit(self: *Vst3Plugin) void {
        self.inst.destroy();
        self.gpa.free(self.values);
        self.gpa.free(self.pending);
        self.gpa.free(self.midi_map);
        self.notes.deinit(self.gpa);
        self.shared.release();
        self.* = undefined;
    }

    /// The plug-0 handle over this instance. Borrowed: the `Vst3Plugin` must outlive it and not
    /// move.
    pub fn plugin(self: *Vst3Plugin) Plugin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mapOf(self: *const Vst3Plugin, i: usize) Mapping {
        return self.shared.maps[i];
    }

    fn plainFromNormalized(self: *Vst3Plugin, i: usize, n: f64) ?f32 {
        if (i >= self.values.len) return null;
        return plainFrom(self.inst, self.info.params[i], self.mapOf(i), self.shared.ids[i], n);
    }

    fn normalizedFromPlain(self: *Vst3Plugin, i: usize, v: f32) ?f64 {
        if (i >= self.values.len) return null;
        return normalizedFrom(self.inst, self.info.params[i], self.mapOf(i), self.shared.ids[i], v);
    }

    /// The editor's size in pixels without opening it (creates and releases a view). For
    /// diagnostics and tests; real plugins expect this on the main thread.
    pub fn editorSize(self: *Vst3Plugin) editor_mod.EditorError!editor_mod.EditorSize {
        const link = self.inst.editor() orelse return error.NoEditor;
        defer link.release();
        return link.probe();
    }

    /// Re-reads every parameter value from the controller (after a state load) and drops
    /// changes still queued from before it.
    fn refreshValues(self: *Vst3Plugin) void {
        for (self.info.params, self.shared.ids, 0..) |pi, id, i| {
            if (self.inst.normalizedValue(id)) |n| {
                if (plainFrom(self.inst, pi, self.mapOf(i), id, n)) |v| self.values[i] = pi.clamp(v);
            }
        }
        self.pending_len = 0;
        for (self.shared.unsynced) |*u| u.store(SYNCED, .monotonic);
    }

    /// Queues a normalized value for the next block, coalescing per parameter. Drops it when the
    /// queue is full (never allocates).
    fn queuePending(self: *Vst3Plugin, index: u32, n: f64) void {
        for (self.pending[0..self.pending_len]) |*e| {
            if (e.index == index) {
                e.value = n;
                return;
            }
        }
        if (self.pending_len < self.pending.len) {
            self.pending[self.pending_len] = .{ .index = index, .value = n };
            self.pending_len += 1;
        }
    }

    /// Sizes the plugin for `sample_rate`, `max_block` frames and `channels` channels (activates
    /// it), then queues every value again so a re-activated plugin matches the session. Control
    /// thread, with the audio thread not inside `process`.
    pub fn prepare(self: *Vst3Plugin, sample_rate: f32, max_block: usize, channels: usize) void {
        const sr: f64 = if (std.math.isFinite(sample_rate) and sample_rate > 0.0) @as(f64, sample_rate) else FALLBACK_SAMPLE_RATE;
        const mb = std.math.clamp(max_block, 1, MAX_BLOCK);
        self.channels = std.math.clamp(channels, 1, MAX_CHANNELS);
        self.max_block = 0;
        if (self.inst.configure(sr, @intCast(mb), self.channels == 1)) |layout| {
            const ins = layout.inputs();
            const outs = layout.outputs();
            self.has_input = ins.len > 0 and ins[0] > 0;
            self.has_output = outs.len > 0 and outs[0] > 0;
            self.event_input = layout.event_input;
            self.max_block = mb;
            self.latency = self.inst.latency();
            self.tail = self.inst.tail();
            self.gpa.free(self.midi_map);
            self.midi_map = self.inst.midiMapping(self.gpa) catch &.{};
        } else |err| {
            log.warn("{s}: {s}", .{ self.info.id, @errorName(err) });
            self.latency = 0;
        }
        self.pending_len = 0;
        const n = @min(self.values.len, self.pending.len);
        for (0..n) |i| {
            if (self.normalizedFromPlain(i, self.values[i])) |nv| self.queuePending(@intCast(i), nv);
        }
    }

    /// Keeps pending releases and releases whatever is still held, so the processor's voices
    /// stop on the next block instead of sounding on while the host forgets them. Control thread.
    pub fn reset(self: *Vst3Plugin) void {
        keepReleases(&self.notes);
        self.allNotesOff();
        self.held = @splat(false);
    }

    fn allNotesOff(self: *Vst3Plugin) void {
        if (!self.event_input) return;
        for (0..KEYS) |k| {
            if (self.held[k]) pushSorted(&self.notes, .{ .off = .{ .time = 0, .key = @intCast(k) } });
        }
    }

    /// Sets parameter `index` (clamped into its range, NaN becomes the default). `false` when
    /// out of range. Calls the controller for plain-mapped parameters: control thread (the
    /// audio thread sets values through `.param` events instead).
    pub fn setParam(self: *Vst3Plugin, index: u32, value: f32) bool {
        if (index >= self.values.len) return false;
        const v = self.info.params[index].clamp(value);
        self.values[index] = v;
        const n = self.normalizedFromPlain(index, v) orelse return true;
        self.shared.unsynced[index].store(@bitCast(n), .monotonic);
        self.queuePending(index, n);
        return true;
    }

    /// The last value set for parameter `index`, or null when out of range.
    pub fn getParam(self: *const Vst3Plugin, index: u32) ?f32 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    /// Audio thread. Copies the block into the plugin's input bus, runs it (in slices of at most
    /// the configured block), and copies the main output bus back. `events` must be sorted by
    /// offset; offsets past the block end are clamped onto its last frame. Allocates nothing,
    /// takes no lock, logs nothing.
    pub fn process(self: *Vst3Plugin, block: AudioBlock, events: []const Event) void {
        if (!self.inst.isActive() or self.max_block == 0) return;
        const ch = @min(self.channels, block.n_channels);
        const frames = block.frames;
        if (frames == 0 or ch == 0) return;
        const blk: *process_mod.ProcessBlock = if (self.inst.block) |*b| b else return;
        const proc = self.inst.processor orelse return;
        const sh = self.shared;
        if (sh.host.latency_changed.swap(false, .monotonic)) self.latency = self.inst.latency();
        // Edits forwarded from the editor go into this block, coalesced with queued values.
        while (sh.to_audio.pop()) |c| self.queuePending(c.index, c.value);

        var start: usize = 0;
        var next: usize = 0;
        var first = true;
        while (start < frames) {
            const n = @min(frames - start, self.max_block);
            const end = start + n;
            if (self.has_input) feedInput(blk, block, ch, start, n);
            var tr: Transport = self.transport orelse .{ .tempo = 120.0, .numerator = 4, .denominator = 4 };
            tr.samples = if (self.transport != null) tr.samples +| @as(i64, @intCast(start)) else self.position;
            const data = blk.begin(@intCast(n), &tr, &.{}, &.{});
            blk.context.continousTimeSamples = self.position;
            if (first) {
                const last: u32 = @intCast(frames - 1);
                for (self.notes.items()) |e| {
                    var q = e;
                    if (q.time() > last) q.setTime(last);
                    _ = blk.in_events.push(q, 0);
                }
                self.notes.len = 0;
                for (self.pending[0..self.pending_len]) |c| {
                    if (c.index < self.shared.ids.len) _ = blk.in_params.set(self.shared.ids[c.index], 0, c.value);
                }
                self.pending_len = 0;
                first = false;
            }
            // Events at or after `end` wait for the next slice.
            while (next < events.len) : (next += 1) {
                const at = @min(@as(usize, events[next].offset), frames - 1);
                if (at >= end) break;
                self.applyEvent(blk, events[next].kind, @intCast(at -| start));
            }
            const r = proc.process(data);
            self.position +|= @as(i64, @intCast(n));
            if (abi.ok(r)) {
                if (self.has_output) readOutput(blk, block, ch, start, n);
                self.collectOutputParams(blk);
            }
            start = end;
        }
    }

    /// Copies the parameter points the plugin wrote this block into the outbox for the UI.
    /// Audio thread; a full outbox drops the change.
    fn collectOutputParams(self: *Vst3Plugin, blk: *process_mod.ProcessBlock) void {
        var i: usize = 0;
        const count = blk.out_params.count();
        while (i < count) : (i += 1) {
            const c = blk.out_params.at(i) orelse continue;
            const idx = self.shared.indexOf(c.id) orelse continue;
            if (!std.math.isFinite(c.value)) continue;
            _ = self.shared.from_plugin.push(.{ .index = idx, .value = std.math.clamp(c.value, 0.0, 1.0) });
        }
    }

    /// Converts one event into the block's VST3 queues at slice-relative `offset`. Audio thread.
    fn applyEvent(self: *Vst3Plugin, blk: *process_mod.ProcessBlock, kind: Event.Kind, offset: u32) void {
        switch (kind) {
            .note_on => |n| {
                if (n.note > MIDI_DATA_MAX or !self.event_input) return;
                const vel = @as(f32, @floatFromInt(@min(n.velocity, MIDI_DATA_MAX))) / 127.0;
                _ = blk.in_events.push(.{ .on = .{ .time = offset, .key = n.note, .velocity = vel } }, 0);
                self.held[n.note] = true;
            },
            .note_off => |k| {
                if (k > MIDI_DATA_MAX or !self.event_input) return;
                _ = blk.in_events.push(.{ .off = .{ .time = offset, .key = k } }, 0);
                self.held[k] = false;
            },
            .midi3 => |m| {
                const d1 = m[1] & MIDI_DATA_MAX;
                const d2 = m[2] & MIDI_DATA_MAX;
                var ctrl: usize = undefined;
                var value: f64 = undefined;
                switch (m[0] & STATUS_MASK) {
                    STATUS_CONTROL_CHANGE => {
                        ctrl = d1;
                        value = @as(f64, @floatFromInt(d2)) / 127.0;
                    },
                    STATUS_CHANNEL_PRESSURE => {
                        ctrl = abi.AFTERTOUCH;
                        value = @as(f64, @floatFromInt(d1)) / 127.0;
                    },
                    STATUS_PITCH_BEND => {
                        ctrl = abi.PITCH_BEND;
                        const raw: u16 = (@as(u16, d2) << 7) | @as(u16, d1);
                        value = @as(f64, @floatFromInt(raw)) / MIDI_14BIT_MAX;
                    },
                    STATUS_POLY_PRESSURE => {
                        if (!self.event_input) return;
                        const p = @as(f32, @floatFromInt(d2)) / 127.0;
                        _ = blk.in_events.push(.{ .pressure = .{ .time = offset, .key = d1, .pressure = p } }, 0);
                        return;
                    },
                    else => return,
                }
                if (ctrl < self.midi_map.len) {
                    if (self.midi_map[ctrl]) |id| _ = blk.in_params.set(id, @intCast(offset), value);
                }
            },
            .param => |pc| {
                if (pc.index >= self.values.len) return;
                const pi = self.info.params[pc.index];
                const v = pi.clamp(pc.value);
                self.values[pc.index] = v;
                const n = normalizedLocal(pi, self.mapOf(pc.index), v);
                _ = blk.in_params.set(self.shared.ids[pc.index], @intCast(offset), n);
            },
        }
    }

    pub fn latencySamples(self: *const Vst3Plugin) usize {
        return self.latency;
    }

    pub fn tailSamples(self: *const Vst3Plugin) usize {
        return self.tail;
    }

    pub fn setTransport(self: *Vst3Plugin, transport: *const Transport) void {
        self.transport = transport.*;
    }

    /// The component and controller state in Seridian's container. Control thread.
    pub fn saveState(self: *Vst3Plugin, gpa: Allocator) Allocator.Error!?[]u8 {
        return self.shared.saveState(gpa);
    }

    /// Restores a state blob (hostile input; false keeps the previous state), then re-reads the
    /// parameter values. Control thread.
    pub fn loadState(self: *Vst3Plugin, data: []const u8) bool {
        const ok = self.inst.loadState(data) catch false;
        if (ok) self.refreshValues();
        return ok;
    }

    pub fn openEditor(self: *Vst3Plugin) plug.EditorError!void {
        const link = self.inst.editor() orelse return error.NoEditor;
        defer link.release();
        link.open(self.info.name) catch |e| return editorError(e);
    }

    pub fn closeEditor(self: *Vst3Plugin) void {
        const link = self.inst.editor() orelse return;
        defer link.release();
        link.close();
    }

    /// An editor handle (null without an edit controller). Control thread. Give it back with
    /// `releaseEditor`.
    pub fn editor(self: *Vst3Plugin) ?PluginEditor {
        if (!self.shared.link.hasController()) return null;
        return .{ .ptr = self.shared.retain(), .vtable = &editor_vtable };
    }

    /// A state reader usable from the UI thread while the plugin processes. Give it back with
    /// `releaseStateReader`.
    pub fn stateReader(self: *Vst3Plugin) PluginStateReader {
        return .{ .ptr = self.shared.retain(), .vtable = &reader_vtable };
    }
};

/// Gives back a handle from `Vst3Plugin.editor`. Control or UI thread.
pub fn releaseEditor(ed: PluginEditor) void {
    std.debug.assert(ed.vtable == &editor_vtable);
    sharedFrom(ed.ptr).release();
}

/// Gives back a reader from `Vst3Plugin.stateReader`.
pub fn releaseStateReader(r: PluginStateReader) void {
    std.debug.assert(r.vtable == &reader_vtable);
    sharedFrom(r.ptr).release();
}

/// Copies `n` frames from `start` of the host block into the plugin's main input bus (a mono
/// source fills every bus channel). Audio thread.
fn feedInput(blk: *process_mod.ProcessBlock, block: AudioBlock, ch: usize, start: usize, n: usize) void {
    const inputs = &blk.inputs;
    for (0..inputs.channels(0)) |c| {
        const src = block.channels[@min(c, ch - 1)][start .. start + n];
        const dst = inputs.channelMut(0, c) orelse continue;
        if (dst.len < n) continue;
        @memcpy(dst[0..n], src);
    }
}

/// Copies `n` frames of the plugin's main output bus into the host block from `start`; a mono
/// host buffer takes the average of a stereo bus. Audio thread.
fn readOutput(blk: *process_mod.ProcessBlock, block: AudioBlock, ch: usize, start: usize, n: usize) void {
    const outputs = &blk.outputs;
    const oc = outputs.channels(0);
    if (oc == 0) return;
    for (0..ch) |c| {
        const dst = block.channels[c][start .. start + n];
        if (ch == 1 and oc >= 2) {
            const l = outputs.channel(0, 0) orelse continue;
            const r = outputs.channel(0, 1) orelse continue;
            for (dst, l[0..n], r[0..n]) |*d, a, b| d.* = 0.5 * (a + b);
        } else if (outputs.channel(0, @min(c, oc - 1))) |src| {
            @memcpy(dst, src[0..n]);
        }
    }
}

// ---- plug-0 vtable ---------------------------------------------------------------------------

fn fromPtr(ptr: *anyopaque) *Vst3Plugin {
    return @ptrCast(@alignCast(ptr));
}

fn infoFn(ptr: *anyopaque) *const PluginInfo {
    return fromPtr(ptr).info;
}
fn prepareFn(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
    fromPtr(ptr).prepare(sample_rate, max_block, channels);
}
fn resetFn(ptr: *anyopaque) void {
    fromPtr(ptr).reset();
}
fn setParamFn(ptr: *anyopaque, index: u32, value: f32) bool {
    return fromPtr(ptr).setParam(index, value);
}
fn getParamFn(ptr: *anyopaque, index: u32) ?f32 {
    return fromPtr(ptr).getParam(index);
}
fn processFn(ptr: *anyopaque, block: AudioBlock, events: []const Event) void {
    fromPtr(ptr).process(block, events);
}
fn latencyFn(ptr: *anyopaque) usize {
    return fromPtr(ptr).latencySamples();
}
fn tailFn(ptr: *anyopaque) usize {
    return fromPtr(ptr).tailSamples();
}
fn setTransportFn(ptr: *anyopaque, transport: *const Transport) void {
    fromPtr(ptr).setTransport(transport);
}
fn saveStateFn(ptr: *anyopaque, gpa: Allocator) Allocator.Error!?[]u8 {
    return fromPtr(ptr).saveState(gpa);
}
fn loadStateFn(ptr: *anyopaque, data: []const u8) bool {
    return fromPtr(ptr).loadState(data);
}
fn openEditorFn(ptr: *anyopaque) plug.EditorError!void {
    return fromPtr(ptr).openEditor();
}
fn closeEditorFn(ptr: *anyopaque) void {
    fromPtr(ptr).closeEditor();
}
fn editorFn(ptr: *anyopaque) ?PluginEditor {
    return fromPtr(ptr).editor();
}
fn stateReaderFn(ptr: *anyopaque) ?PluginStateReader {
    return fromPtr(ptr).stateReader();
}

const vtable: Plugin.VTable = .{
    .info = infoFn,
    .prepare = prepareFn,
    .reset = resetFn,
    .set_param = setParamFn,
    .get_param = getParamFn,
    .process = processFn,
    .latency = latencyFn,
    .tail_samples = tailFn,
    .set_transport = setTransportFn,
    .save_state = saveStateFn,
    .load_state = loadStateFn,
    .open_editor = openEditorFn,
    .close_editor = closeEditorFn,
    .editor = editorFn,
    .state_reader = stateReaderFn,
};

// ---- editor handle ---------------------------------------------------------------------------

fn edOpen(ptr: *anyopaque) plug.EditorError!void {
    const sh = sharedFrom(ptr);
    // Edits reported before the editor opened (e.g. during setup) are stale.
    var scratch: [abi.EDIT_CAP]host_mod.Edit = undefined;
    while (sh.host.takeEdits(&scratch) == scratch.len) {}
    sh.link.open(sh.info.name) catch |e| return editorError(e);
}

fn edClose(ptr: *anyopaque) void {
    sharedFrom(ptr).link.close();
}

fn edIsOpen(ptr: *anyopaque) bool {
    return sharedFrom(ptr).link.isOpen();
}

/// UI thread, every frame while open: view housekeeping, then the edits made in the editor
/// (also forwarded into the next audio block) and the changes the plugin made by itself.
fn edIdle(ptr: *anyopaque, gpa: Allocator) Allocator.Error![]ParamEdit {
    const sh = sharedFrom(ptr);
    sh.link.idle();
    var out: std.ArrayList(ParamEdit) = .empty;
    errdefer out.deinit(gpa);
    var buf: [abi.EDIT_CAP]host_mod.Edit = undefined;
    while (true) {
        const got = sh.host.takeEdits(&buf);
        for (buf[0..got]) |e| {
            const i = sh.indexOf(e.id) orelse continue;
            const v = sh.plain(i, e.value) orelse continue;
            try out.append(gpa, .{ .index = i, .value = v });
            // A full forward queue drops the edit; the session's `setParam` still carries it.
            _ = sh.to_audio.push(.{ .index = i, .value = e.value });
        }
        if (got < buf.len) break;
    }
    while (sh.from_plugin.pop()) |c| {
        const v = sh.plain(c.index, c.value) orelse continue;
        try out.append(gpa, .{ .index = c.index, .value = v });
    }
    return out.toOwnedSlice(gpa);
}

/// True once after the plugin marked its state dirty or asked for a restart.
fn edStateChanged(ptr: *anyopaque) bool {
    const sh = sharedFrom(ptr);
    const dirty = sh.host.dirty.swap(false, .monotonic);
    const restart = sh.host.restart_requested.swap(false, .monotonic);
    return dirty or restart;
}

fn edSetParam(ptr: *anyopaque, index: u32, value: f32) void {
    const sh = sharedFrom(ptr);
    if (index >= sh.ids.len) return;
    if (sh.normalized(index, value)) |n| sh.link.setNormalized(sh.ids[index], n);
}

/// The plugin's own text for a value (`IEditController::getParamStringByValue`), main thread
/// only. Only for identity-mapped 0..1 parameters: a plugin whose plain mapping is the identity
/// (JUCE, the SDK's default `Parameter`) leaves a 0..1 range with the units of its real one, so
/// only its own text says what the value is.
fn edValueText(ptr: *anyopaque, gpa: Allocator, index: u32, value: f32) Allocator.Error!?[]u8 {
    const sh = sharedFrom(ptr);
    if (index >= sh.ids.len) return null;
    const pi = sh.info.params[index];
    if (sh.maps[index] != .plain or pi.min != 0.0 or pi.max != 1.0) return null;
    const n = sh.normalized(index, value) orelse return null;
    const text = (try sh.link.valueText(gpa, sh.ids[index], n)) orelse return null;
    // VST3 keeps the units apart from the text (JUCE's label, the SDK's `RangeParameter`), but
    // some plugins put them in both.
    const units = std.mem.trim(u8, sh.units[index], " \t\r\n");
    const shown = std.mem.trimEnd(u8, text, " \t\r\n");
    if (units.len == 0 or std.ascii.endsWithIgnoreCase(shown, units)) return text;
    defer gpa.free(text);
    return try std.fmt.allocPrint(gpa, "{s} {s}", .{ text, units });
}

const editor_vtable: PluginEditor.VTable = .{
    .open = edOpen,
    .close = edClose,
    .is_open = edIsOpen,
    .idle = edIdle,
    .state_changed = edStateChanged,
    .set_param = edSetParam,
    .value_text = edValueText,
    .release = handleRelease,
};

fn handleRelease(ptr: *anyopaque) void {
    sharedFrom(ptr).release();
}

fn readerSave(ptr: *anyopaque, gpa: Allocator) Allocator.Error!?[]u8 {
    return sharedFrom(ptr).saveState(gpa);
}

const reader_vtable: PluginStateReader.VTable = .{ .save_state = readerSave, .release = handleRelease };

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;
const fx = editor_mod.fixture;
const module = @import("module.zig");

// Port of plugin.rs `reset_keeps_room_to_release_every_held_key`: a queue full of releases still
// has room to release every held key after a reset.
test "reset_keeps_room_to_release_every_held_key" {
    var notes = try NoteQueue.init(testing.allocator, abi.EVENT_CAP);
    defer notes.deinit(testing.allocator);
    for (0..abi.EVENT_CAP) |i| {
        pushSorted(&notes, .{ .off = .{ .time = @intCast(i), .key = @intCast(i % 4) } });
    }
    keepReleases(&notes);
    var key: u8 = 0;
    while (key < 128) : (key += 1) {
        pushSorted(&notes, .{ .off = .{ .time = 0, .key = key } });
    }
    key = 0;
    while (key < 128) : (key += 1) {
        var found = false;
        for (notes.items()) |e| {
            switch (e) {
                .off => |o| if (o.key == key) {
                    found = true;
                },
                else => {},
            }
        }
        // "key {key} was never released"
        try testing.expect(found);
    }
}

test "NoteQueue: sorted insert, bounded, releases deduplicated at time zero" {
    var q = try NoteQueue.init(testing.allocator, 4);
    defer q.deinit(testing.allocator);
    pushSorted(&q, .{ .off = .{ .time = 9, .key = 1 } });
    pushSorted(&q, .{ .on = .{ .time = 3, .key = 2, .velocity = 1.0 } });
    pushSorted(&q, .{ .off = .{ .time = 9, .key = 1 } });
    pushSorted(&q, .{ .off = .{ .time = 5, .key = 7 } });
    pushSorted(&q, .{ .off = .{ .time = 6, .key = 8 } }); // full: dropped
    try testing.expectEqual(@as(usize, 4), q.len);
    try testing.expectEqual(@as(u32, 3), q.items()[0].time());
    try testing.expectEqual(@as(u32, 5), q.items()[1].time());
    keepReleases(&q);
    try testing.expectEqual(@as(usize, 2), q.len); // key 1 once, key 7; the note-on is gone
    for (q.items()) |e| try testing.expectEqual(@as(u32, 0), e.time());
}

test "Ring: bounded SPSC order" {
    var r: Ring(Change, 4) = .{};
    try testing.expect(r.pop() == null);
    for (0..4) |i| try testing.expect(r.push(.{ .index = @intCast(i), .value = 0 }));
    try testing.expect(!r.push(.{ .index = 9, .value = 0 }));
    try testing.expectEqual(@as(u32, 0), r.pop().?.index);
    try testing.expect(r.push(.{ .index = 4, .value = 0 }));
    for (1..5) |i| try testing.expectEqual(@as(u32, @intCast(i)), r.pop().?.index);
    try testing.expect(r.pop() == null);
}

/// A fake plugin set up on the test stack: config, log, factory, bundle.
const Rig = struct {
    cfg: fx.Config,
    log: fx.Log = .{},
    factory: *fx.Factory,
    bundle: module.Bundle,

    fn init(rig: *Rig, single: bool, cfg: fx.Config) !void {
        rig.* = .{ .cfg = cfg, .factory = undefined, .bundle = undefined };
        rig.factory = try fx.Factory.create(testing.allocator, single, &rig.cfg, &rig.log);
        rig.bundle = .{ .gpa = testing.allocator, .path = &.{}, .factory = &rig.factory.iface, .exit_fn = null, .entered_on = .main };
    }

    fn make(rig: *Rig) !*Instance {
        return Instance.create(testing.allocator, &rig.bundle, &fx.Factory.comp_cid);
    }

    fn deinit(rig: *Rig) void {
        _ = abi.comRelease(&rig.factory.iface);
    }
};

const test_params = [_]fx.FakeParam{
    .{ .id = 10, .title = "Gain", .units = "dB", .min = -24, .max = 12, .default = 2.0 / 3.0 },
    .{ .id = 11, .title = "Power", .step_count = 1, .default = 1.0 },
    .{ .id = 12, .title = "Mode", .step_count = 3, .default = 0.5 },
    .{ .id = 13, .title = "Hidden", .flags = abi.kIsHidden },
    .{ .id = 20, .title = "Mix", .units = "%", .min = 0, .max = 1, .default = 0.25 },
};
// Dense order after hiding: Gain 10, Power 11, Mode 12, Mix 20.

fn testInfo(table: *const inst_mod.ParamTable) PluginInfo {
    return .{
        .id = "vst3.fake",
        .name = "Fake",
        .short_name = "Fake",
        .category = .other,
        .params = table.infos,
        .is_instrument = false,
        .audiosuite = false,
    };
}

test "init: values come from the controller, a mismatched info is refused" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const table = try inst.paramTable();
    const info = testInfo(table);
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 4), p.values.len);
    try testing.expectApproxEqAbs(@as(f32, 0.0), p.getParam(0).?, 1e-4); // 2/3 of -24..12
    try testing.expect(p.getParam(4) == null);

    var rig2: Rig = undefined;
    try rig2.init(true, .{ .params = &test_params });
    defer rig2.deinit();
    const inst2 = try rig2.make();
    var bad = testInfo(try inst2.paramTable());
    bad.params = bad.params[0..2];
    // `init` destroys the instance on error.
    try testing.expectError(error.ParamMismatch, Vst3Plugin.init(testing.allocator, inst2, &bad));
}

test "setParam / getParam: clamp, normalize, queue for the next block" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    p.prepare(48_000, 128, 2);
    p.pending_len = 0;

    try testing.expect(p.setParam(0, -6.0));
    try testing.expectEqual(@as(?f32, -6.0), p.getParam(0));
    try testing.expectEqual(@as(usize, 1), p.pending_len);
    try testing.expectEqual(@as(f64, 0.5), p.pending[0].value);
    // A second value for the same parameter is coalesced; out of range clamps.
    try testing.expect(p.setParam(0, 99.0));
    try testing.expectEqual(@as(?f32, 12.0), p.getParam(0));
    try testing.expectEqual(@as(usize, 1), p.pending_len);
    try testing.expectEqual(@as(f64, 1.0), p.pending[0].value);
    // Choice rounds and normalizes by steps.
    try testing.expect(p.setParam(2, 1.6));
    try testing.expectEqual(@as(?f32, 2.0), p.getParam(2));
    try testing.expect(!p.setParam(9, 0.0));
    // The controller has not seen the host-set value yet.
    try testing.expect(p.shared.unsynced[0].load(.monotonic) != SYNCED);
}

test "prepare: latency, tail and bus layout; process copies audio and slices long blocks" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params, .latency = 64, .tail = 4800 });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 64, 2);
    try testing.expectEqual(@as(usize, 64), h.latency());
    try testing.expectEqual(@as(usize, 4800), h.tailSamples());
    try testing.expect(p.has_input and p.has_output);
    try testing.expectEqual(@as(usize, 4), p.pending_len); // every value re-sent

    var l: [200]f32 = undefined;
    var r: [200]f32 = @splat(0);
    for (&l, 0..) |*s, i| s.* = @floatFromInt(i);
    const bufs = [_][]f32{ &l, &r };
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    // 200 frames at a 64-frame setup: four slices (the fake plugin doubles channel 0).
    try testing.expectEqual(@as(u32, 4), rig.log.process_calls);
    try testing.expectEqual(@as(f32, 0.0), l[0]);
    try testing.expectEqual(@as(f32, 398.0), l[199]);
    try testing.expectEqual(@as(f32, 140.0), l[70]); // second slice, offset into the host block
    try testing.expectEqual(@as(f32, 0.0), r[10]); // the fake plugin writes channel 0 only
}

test "process: events become VST3 notes, held keys are released by reset" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params, .event_in = true });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 128, 2);
    p.pending_len = 0;
    var l: [64]f32 = @splat(0);
    var r: [64]f32 = @splat(0);
    const bufs = [_][]f32{ &l, &r };
    const evs = [_]Event{
        .{ .offset = 4, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } },
        .{ .offset = 9, .kind = .{ .note_on = .{ .note = 200, .velocity = 100 } } }, // not a MIDI key
        .{ .offset = 70, .kind = .{ .note_on = .{ .note = 62, .velocity = 90 } } }, // past the end: clamped
    };
    h.process(AudioBlock.fromSlices(&bufs), &evs);
    try testing.expectEqual(@as(i32, 2), rig.log.last_event_count);
    try testing.expect(p.held[60] and p.held[62] and !p.held[200 % 128]);
    // reset releases both held keys at the start of the next block.
    h.reset();
    try testing.expectEqual(@as(usize, 2), p.notes.len);
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(i32, 2), rig.log.last_event_count);
    try testing.expectEqual(@as(usize, 0), p.notes.len);
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(i32, 0), rig.log.last_event_count);
}

test "process: notes are ignored without an event input" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 128, 2);
    var l: [32]f32 = @splat(0);
    var r: [32]f32 = @splat(0);
    const bufs = [_][]f32{ &l, &r };
    const evs = [_]Event{.{ .offset = 0, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } }};
    h.process(AudioBlock.fromSlices(&bufs), &evs);
    try testing.expectEqual(@as(i32, 0), rig.log.last_event_count);
    try testing.expect(!p.held[60]);
}

test "process: parameter events, pending values and midi mapping reach the input queue" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params, .has_midi_mapping = true });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 128, 2);
    var l: [32]f32 = @splat(0);
    var r: [32]f32 = @splat(0);
    const bufs = [_][]f32{ &l, &r };
    // prepare re-sent all four values.
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(i32, 4), rig.log.last_param_count);
    // Nothing pending now.
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(i32, 0), rig.log.last_param_count);
    // A param event, a mapped CC (CC1 -> param 11) and an unmapped CC.
    const evs = [_]Event{
        .{ .offset = 0, .kind = .{ .param = .{ .index = 0, .value = -6.0 } } },
        .{ .offset = 1, .kind = .{ .midi3 = .{ 0xB0, 1, 127 } } },
        .{ .offset = 2, .kind = .{ .midi3 = .{ 0xB0, 5, 10 } } },
        .{ .offset = 3, .kind = .{ .param = .{ .index = 99, .value = 1.0 } } },
    };
    h.process(AudioBlock.fromSlices(&bufs), &evs);
    try testing.expectEqual(@as(i32, 2), rig.log.last_param_count);
    try testing.expectEqual(@as(?f32, -6.0), h.getParam(0));
}

test "latency changes requested by the plugin are picked up in process" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params, .latency = 10 });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 128, 1);
    try testing.expectEqual(@as(usize, 10), h.latency());
    rig.cfg.latency = 99;
    inst.host.latency_changed.store(true, .monotonic);
    var l: [16]f32 = @splat(0);
    const bufs = [_][]f32{&l};
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(usize, 99), h.latency());
}

test "process before prepare or with an empty block does nothing" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    var l: [16]f32 = @splat(1);
    const bufs = [_][]f32{&l};
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(u32, 0), rig.log.process_calls);
    h.prepare(48_000, 128, 1);
    h.process(AudioBlock.fromSlices(&.{}), &.{});
    try testing.expectEqual(@as(u32, 0), rig.log.process_calls);
}

test "editor: idle returns edits, forwards them to the next block, and reports the plugin's own changes" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    h.prepare(48_000, 128, 2);
    var l: [16]f32 = @splat(0);
    var r: [16]f32 = @splat(0);
    const bufs = [_][]f32{ &l, &r };
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    const ed = h.editor().?;
    defer releaseEditor(ed);
    // performEdit from the plugin's GUI (any thread), for Gain (id 10) and an unknown id.
    p.inst.host.edits.record(10, 0.5);
    p.inst.host.edits.record(404, 0.5);
    const edits = try ed.idle(testing.allocator);
    defer testing.allocator.free(edits);
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(u32, 0), edits[0].index);
    try testing.expectEqual(@as(f32, -6.0), edits[0].value);
    // Nothing more to report.
    const again = try ed.idle(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);
    // The audio side gets the same value in its next block, without a `setParam` call.
    h.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectEqual(@as(i32, 1), rig.log.last_param_count);
    // The plugin writes an output parameter change (Power, id 11): it reaches idle().
    const blk = &p.inst.block.?;
    _ = blk.out_params.set(11, 0, 1.0);
    p.collectOutputParams(blk);
    const own = try ed.idle(testing.allocator);
    defer testing.allocator.free(own);
    try testing.expectEqual(@as(usize, 1), own.len);
    try testing.expectEqual(@as(u32, 1), own[0].index);
    try testing.expectEqual(@as(f32, 1.0), own[0].value);
}

test "editor: stateChanged is true once after setDirty or a restart request" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const ed = p.plugin().editor().?;
    defer releaseEditor(ed);
    try testing.expect(!ed.stateChanged());
    p.inst.host.dirty.store(true, .monotonic);
    try testing.expect(ed.stateChanged());
    try testing.expect(!ed.stateChanged());
    p.inst.host.restart_requested.store(true, .monotonic);
    try testing.expect(ed.stateChanged());
    try testing.expect(!ed.stateChanged());
}

test "editor: setParam shows the value, value_text only for identity-mapped 0..1 parameters" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const ed = p.plugin().editor().?;
    defer releaseEditor(ed);
    ed.setParam(0, -6.0);
    try testing.expectEqual(@as(u32, 1), rig.log.param_sets);
    try testing.expectEqual(@as(f64, 0.5), rig.log.last_param_set_value);
    // Gain has a real range: the host formats it itself.
    try testing.expect((try ed.valueText(testing.allocator, 0, -6.0)) == null);
    // Mix (index 3) is 0..1: the plugin's text plus its unit label.
    const text = (try ed.valueText(testing.allocator, 3, 0.5)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("0.5 %", text);
    try testing.expect((try ed.valueText(testing.allocator, 99, 0.5)) == null);
}

test "state: save syncs unsynced values first, load refreshes values" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    const h = p.plugin();
    try testing.expect(h.setParam(0, 12.0));
    const blob = (try h.saveState(testing.allocator)).?;
    defer testing.allocator.free(blob);
    try testing.expect(std.mem.startsWith(u8, blob, abi.STATE_MAGIC));
    // The controller was handed the host-set value before saving.
    try testing.expectEqual(@as(f64, 1.0), rig.log.last_param_set_value);
    try testing.expect(p.shared.unsynced[0].load(.monotonic) == SYNCED);
    // The UI-thread reader does the same.
    try testing.expect(h.setParam(0, 0.0));
    const rd = h.stateReader().?;
    defer releaseStateReader(rd);
    const blob2 = (try rd.saveState(testing.allocator)).?;
    defer testing.allocator.free(blob2);
    try testing.expect(p.shared.unsynced[0].load(.monotonic) == SYNCED);
    // Loading re-reads the values and drops what was queued.
    try testing.expect(h.loadState(blob));
    try testing.expectEqual(@as(usize, 0), p.pending_len);
    try testing.expect(!h.loadState(""));
}

test "handles outlive the plugin and become inert; no leaks" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    const ed = p.plugin().editor().?;
    const rd = p.plugin().stateReader().?;
    p.deinit();
    try testing.expectEqual(@as(usize, 1), rig.bundle.refs.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.destroyed));
    try testing.expect(!ed.isOpen());
    ed.setParam(0, 1.0);
    const edits = try ed.idle(testing.allocator);
    try testing.expectEqual(@as(usize, 0), edits.len);
    testing.allocator.free(edits);
    try testing.expect((try rd.saveState(testing.allocator)) == null);
    try testing.expectError(error.OpenFailed, ed.open());
    ed.release();
    rd.release();
}

test "editor handle: none without an edit controller" {
    var rig: Rig = undefined;
    try rig.init(false, .{ .controller_initialize_ok = false, .params = &test_params });
    defer rig.deinit();
    const inst = try rig.make();
    const info = testInfo(try inst.paramTable());
    var p = try Vst3Plugin.init(testing.allocator, inst, &info);
    defer p.deinit();
    try testing.expect(p.plugin().editor() == null);
    try testing.expectError(error.NoEditor, p.plugin().openEditor());
}
