// Translated to Zig from soundcraft/crates/clap-host/src/plugin.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! `ClapPlugin`: a loaded CLAP instance behind the plug-0 `Plugin` handle (`../plugin.zig`).
//!
//! It owns one `Instance` (`instance.zig`), the port buffers, the per-parameter value table,
//! and a `Shared` link to the plugin's editor and state (`gui.zig`). The UI gets its editor and
//! state-reader handles from here. Those handles are reference counted: they stay valid after
//! the plugin is destroyed, and their calls then do nothing (`alive` is false).
//!
//! Threading. Control thread: `create`, `destroy`, `prepare`, `setParam`, `getParam`,
//! `loadState`, `saveState`, the editor calls. Audio thread: `process` and `reset`. The caller
//! serialises them: one instance is never used from two threads at once (as in `instance.zig`).
//! Editor and state-reader handles are used on the UI (main) thread.
//!
//! Seridian adaptations, all deliberate:
//! 1. `process(block, events)` takes the block's events as sample-offset `Event`s. There are no
//!    per-event `note_on`/`note_off`/`midi` methods. `adaptEvent` maps them for the plugin's
//!    note dialect before they reach the instance.
//! 2. Parameters are addressed by dense index. `setParam` and `getParam` take the index, and
//!    the table of values is built once in `create`. String ids are not used here.
//! 3. Every buffer `process` touches is allocated before the first block: the port buffers
//!    (`prepare`), the pending and merged event lists (`create`). `process` allocates nothing,
//!    takes no lock and does no I/O.
//! 4. `process` cannot log. A block whose call fails is counted in `process_errors` and passes
//!    through unchanged, which is what the Rust code did when the plugin returned an error.
//! 5. `prepare` returns nothing (the `Plugin` contract). An allocation failure there is logged
//!    on the control thread and leaves the plugin inactive, so `process` passes audio through.
//! 6. Channels are capped at `plugin.MAX_CHANNELS` (16, the planar block limit), where the Rust
//!    code allowed 64.
//! 7. `tailSamples` reads the plugin's `clap.tail` extension. The Rust `ClapPlugin` did not
//!    override it, so Rust reported the trait default (0).
//! 8. The editor and state-reader handles are `Shared` pointers. The `PluginEditor` and
//!    `PluginStateReader` handles carry a `release` entry (also `releaseEditor` /
//!    `releaseStateReader`); the caller must return each one exactly once.
//! 9. Editor errors are the `EditorError` set. The Rust `String` messages are not kept.
//! 10. A parameter edit the plugin reports from its GUI reaches the UI through the `Shared`
//!     link. Each `idle` call returns at most `IDLE_EDIT_CAP` edits; the rest wait for the
//!     next call. The Rust code drained them all.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const abi = @import("abi.zig");
const events = @import("events.zig");
const instance = @import("instance.zig");
const gui = @import("gui.zig");
const bundle = @import("bundle.zig");
const test_fixture = @import("test_fixture.zig");
const plugin_mod = @import("../plugin.zig");
const host_event = @import("../event.zig");
const params = @import("../params.zig");

const Instance = instance.Instance;
const PortBuffers = instance.PortBuffers;
const PortInfo = instance.PortInfo;
const NotePort = instance.NotePort;
const EventList = host_event.EventList;
const Event = host_event.Event;
const Plugin = plugin_mod.Plugin;
const PluginInfo = plugin_mod.PluginInfo;
const PluginEditor = plugin_mod.PluginEditor;
const PluginStateReader = plugin_mod.PluginStateReader;
const EditorError = plugin_mod.EditorError;
const AudioBlock = plugin_mod.AudioBlock;
const Transport = plugin_mod.Transport;
const ParamEdit = plugin_mod.ParamEdit;

const log = std.log.scoped(.plughost_clap);

/// Largest block a plugin is activated for.
pub const MAX_BLOCK: usize = 1 << 16;
/// The sample rate used when `prepare` is given a non-finite or non-positive one.
pub const DEFAULT_SAMPLE_RATE: f64 = 48_000.0;
/// Parameter edits taken from the editor in one `idle` call.
pub const IDLE_EDIT_CAP: usize = 256;
/// Room for the pending parameter changes and one block's events together.
const MERGE_CAP: usize = 2 * abi.EVENT_CAP;
/// The highest MIDI note and velocity values.
const MIDI_MAX_DATA: u8 = 127;

/// How a note event is delivered to the plugin, from its note port's dialects.
pub const NoteMode = enum { none, clap, midi };

/// Failure of `create`.
pub const CreateError = instance.CreateError;

/// The note mode for a plugin's first input note port. CLAP is preferred over MIDI when both
/// are offered; no port means the plugin takes no notes.
pub fn noteMode(port: ?NotePort) NoteMode {
    const p = port orelse return .none;
    if ((p.supported & abi.CLAP_NOTE_DIALECT_CLAP) != 0) return .clap;
    if ((p.supported & abi.CLAP_NOTE_DIALECT_MIDI) != 0) return .midi;
    return .none;
}

/// The main audio port: the first with the `main` flag and channels, else the first with
/// channels. Null when no port has a channel.
pub fn pickMain(ports: []const PortInfo) ?usize {
    for (ports, 0..) |p, i| {
        if (p.main and p.channels > 0) return i;
    }
    for (ports, 0..) |p, i| {
        if (p.channels > 0) return i;
    }
    return null;
}

/// Maps one of the block's events to what the plugin accepts, for its note mode and MIDI
/// input. Null drops it. The offset is clamped to `last` (the block's last frame). Notes above
/// 127 are dropped, and a note velocity above 127 is clamped to 127.
pub fn adaptEvent(notes: NoteMode, midi_in: bool, ev: Event, last: u32) ?Event {
    var out = ev;
    out.offset = @min(ev.offset, last);
    switch (ev.kind) {
        .note_on => |n| {
            if (n.note > MIDI_MAX_DATA) return null;
            const vel = @min(n.velocity, MIDI_MAX_DATA);
            return switch (notes) {
                .none => null,
                .clap => blk: {
                    out.kind = .{ .note_on = .{ .note = n.note, .velocity = vel } };
                    break :blk out;
                },
                .midi => blk: {
                    out.kind = .{ .midi3 = .{ 0x90, n.note, vel } };
                    break :blk out;
                },
            };
        },
        .note_off => |key| {
            if (key > MIDI_MAX_DATA) return null;
            return switch (notes) {
                .none => null,
                .clap => out,
                .midi => blk: {
                    out.kind = .{ .midi3 = .{ 0x80, key, 0 } };
                    break :blk out;
                },
            };
        },
        .midi3 => return if (midi_in) out else null,
        .param => return out,
    }
}

// ---- editor and state link -------------------------------------------------------------------

/// The editor and state link of one plugin, shared by the `ClapPlugin` and by the handles it
/// hands out. It is reference counted: the plugin holds one reference, and each handle from
/// `editor` or `stateReader` holds one until it is released.
const Shared = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32),
    /// False once the plugin is destroyed. Every handle call checks it first.
    alive: std.atomic.Value(bool),
    /// The instance, while alive. Read by the editor's `idle` to map CLAP ids to dense indices.
    inst: ?*const Instance,
    info: *const PluginInfo,
    link: gui.GuiLink,
};

fn sharedOf(ptr: *anyopaque) *Shared {
    return @ptrCast(@alignCast(ptr));
}

fn retain(s: *Shared) void {
    _ = s.refs.fetchAdd(1, .monotonic);
}

/// Drops one reference, freeing the link when it was the last.
fn release(s: *Shared) void {
    if (s.refs.fetchSub(1, .acq_rel) == 1) s.gpa.destroy(s);
}

/// Control thread. Ends the link: an open editor is closed while the plugin is still alive,
/// then every handle sees `alive == false`. Call before the instance is destroyed.
fn killShared(s: *Shared) void {
    s.link.kill();
    s.inst = null;
    s.alive.store(false, .release);
}

/// The plugin's `clap.gui` table, or null.
fn guiExtension(plugin: *const abi.ClapPlugin) ?*const abi.ClapPluginGui {
    return extensionOf(abi.ClapPluginGui, plugin, abi.CLAP_EXT_GUI);
}

/// The plugin's extension `id`, typed, or null. Same lookup as `instance.zig`.
fn extensionOf(comptime T: type, plugin: *const abi.ClapPlugin, id: [:0]const u8) ?*const T {
    const get = plugin.get_extension orelse return null;
    const raw = get(plugin, id.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

// ---- the plugin ------------------------------------------------------------------------------

pub const ClapPlugin = struct {
    gpa: Allocator,
    inst: *Instance,
    info: *const PluginInfo,
    shared: *Shared,
    /// The plugin has a `clap.gui` table.
    has_gui: bool,
    /// Current value of each dense index, in plug-0 units. Length is `info.params.len`.
    values: []f32,
    /// Parameter changes waiting for the next block. Each is at offset 0 and coalesced by index.
    pending: EventList,
    /// The pending changes and the block's events, sorted by offset, for one `process` call.
    merged: EventList,
    inputs: PortBuffers,
    outputs: PortBuffers,
    in_main: ?usize = null,
    out_main: ?usize = null,
    notes: NoteMode = .none,
    /// The note port takes raw MIDI (controllers, pitch bend, program changes).
    midi_in: bool = false,
    channels: usize = 2,
    /// Largest block the plugin is active for. Zero means inactive: `process` passes through.
    max_block: usize = 0,
    latency: usize = 0,
    /// Timeline position of the next frame, in samples.
    steady: i64 = 0,
    transport: Transport = .{},
    has_transport: bool = false,
    /// Process calls the plugin rejected, since creation. Written on the audio thread.
    process_errors: std.atomic.Value(u32) = .init(0),
    /// Block events dropped because `merged` was full, since creation. Written on the audio thread.
    dropped_events: std.atomic.Value(usize) = .init(0),

    /// Control thread. Creates the plugin from `factory` with `plugin_id`, maps its parameters
    /// onto `info.params` (one entry per usable CLAP parameter, in order), and reads the
    /// current values. `factory`'s binary must stay loaded until `destroy` returns.
    pub fn create(gpa: Allocator, factory: *const abi.ClapPluginFactory, plugin_id: [:0]const u8, info: *const PluginInfo) CreateError!*ClapPlugin {
        const inst = try Instance.create(gpa, factory, plugin_id, info.params);
        errdefer inst.destroy();

        const gui_ext = guiExtension(inst.plugin);
        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        shared.* = .{
            .gpa = gpa,
            .refs = .init(1),
            .alive = .init(true),
            .inst = inst,
            .info = info,
            .link = gui.GuiLink.init(inst.hostState()),
        };
        shared.link.attach(inst.plugin, gui_ext, inst.state_ext);

        const values = try gpa.alloc(f32, info.params.len);
        errdefer gpa.free(values);
        for (values, info.params) |*v, p| v.* = p.default;

        var pending = try EventList.init(gpa, abi.EVENT_CAP);
        errdefer pending.deinit(gpa);
        var merged = try EventList.init(gpa, MERGE_CAP);
        errdefer merged.deinit(gpa);

        const self = try gpa.create(ClapPlugin);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .inst = inst,
            .info = info,
            .shared = shared,
            .has_gui = gui_ext != null,
            .values = values,
            .pending = pending,
            .merged = merged,
            .inputs = emptyPorts(),
            .outputs = emptyPorts(),
        };
        self.refreshValues();
        return self;
    }

    /// Control thread. The last call for this plugin. The editor is closed first (on the main
    /// thread), then the plugin is destroyed. Editor and state-reader handles still held stay
    /// valid memory, but their calls do nothing.
    pub fn destroy(self: *ClapPlugin) void {
        const gpa = self.gpa;
        killShared(self.shared);
        self.inst.destroy();
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.pending.deinit(gpa);
        self.merged.deinit(gpa);
        gpa.free(self.values);
        release(self.shared);
        gpa.destroy(self);
    }

    /// The plug-0 `Plugin` handle. Borrowed: it is valid until `destroy`.
    pub fn plugin(self: *ClapPlugin) Plugin {
        return .{ .ptr = self, .vtable = &plugin_vtable };
    }

    /// Re-reads every parameter value from the plugin. A value the plugin does not report keeps
    /// what it had (the default at creation).
    fn refreshValues(self: *ClapPlugin) void {
        for (self.values, self.info.params, 0..) |*v, p, i| {
            const clap_id = self.inst.param_ids[i];
            const raw = self.inst.paramValue(clap_id) orelse continue;
            const x = self.inst.fromClapValue(@intCast(i), raw) orelse continue;
            v.* = p.clamp(x);
        }
    }

    /// Control thread. Sizes the plugin for a sample rate and maximum block, and activates it.
    /// Failures leave the plugin inactive, which `process` treats as a pass-through.
    fn prepare(self: *ClapPlugin, sample_rate: f32, max_block: usize, channels: usize) Allocator.Error!void {
        const sr: f64 = if (std.math.isFinite(sample_rate) and sample_rate > 0.0) @as(f64, sample_rate) else DEFAULT_SAMPLE_RATE;
        const mb = std.math.clamp(max_block, 1, MAX_BLOCK);
        self.channels = std.math.clamp(channels, 1, plugin_mod.MAX_CHANNELS);
        self.inst.deactivate();
        self.inst.serviceCallback();

        const ins = self.inst.audioPorts(true) catch |err| {
            log.warn("{s}: input ports refused: {}", .{ self.info.id, err });
            return self.setInactive();
        };
        const outs = self.inst.audioPorts(false) catch |err| {
            log.warn("{s}: output ports refused: {}", .{ self.info.id, err });
            return self.setInactive();
        };
        const in_list = ins.slice();
        const out_list = outs.slice();

        var in_counts: [abi.MAX_PORTS]u32 = undefined;
        for (in_list, 0..) |p, i| in_counts[i] = p.channels;
        var out_counts: [abi.MAX_PORTS]u32 = undefined;
        for (out_list, 0..) |p, i| out_counts[i] = p.channels;

        var new_in = try PortBuffers.init(self.gpa, in_counts[0..in_list.len], mb);
        errdefer new_in.deinit(self.gpa);
        var new_out = try PortBuffers.init(self.gpa, out_counts[0..out_list.len], mb);
        errdefer new_out.deinit(self.gpa);
        self.inputs.deinit(self.gpa);
        self.inputs = new_in;
        self.outputs.deinit(self.gpa);
        self.outputs = new_out;

        self.in_main = pickMain(in_list);
        self.out_main = pickMain(out_list);
        const port = self.inst.notePort();
        self.notes = noteMode(port);
        self.midi_in = if (port) |p| (p.supported & abi.CLAP_NOTE_DIALECT_MIDI) != 0 else false;
        self.max_block = mb;
        self.inst.hostState().restart.store(false, .monotonic);

        const max_frames = std.math.cast(u32, mb) orelse std.math.maxInt(u32);
        self.inst.activate(sr, 1, max_frames) catch |err| {
            log.warn("{s}: activation failed: {}", .{ self.info.id, err });
            self.latency = 0;
            return;
        };
        self.latency = self.inst.latency();
        self.inst.hostState().latency_changed.store(false, .monotonic);
    }

    /// Control thread. Leaves the plugin unable to process, after a port layout it refuses.
    fn setInactive(self: *ClapPlugin) void {
        self.in_main = null;
        self.out_main = null;
        self.max_block = 0;
        self.latency = 0;
    }

    /// Audio thread. Runs the plugin over `block`, splitting it into chunks of at most
    /// `max_block` frames, and delivers the pending parameter changes and `events` at their
    /// offsets. Passes the block through unchanged when the plugin is inactive, or when a
    /// chunk's call fails.
    fn processBlock(self: *ClapPlugin, block: AudioBlock, events_in: []const Event) void {
        if (!self.inst.isActive() or self.max_block == 0) return;
        const ch = @min(self.channels, block.n_channels);
        const frames = block.frames;
        if (frames == 0 or ch == 0) return;
        const last: u32 = std.math.cast(u32, frames - 1) orelse std.math.maxInt(u32);

        // The pending changes sit at the block start, ahead of the block's own events.
        self.merged.clear();
        for (self.pending.items()) |ev| self.mergeOne(ev, last);
        for (events_in) |ev| {
            if (adaptEvent(self.notes, self.midi_in, ev, last)) |a| self.mergeOne(a, last);
        }
        self.pending.clear();

        const items = self.merged.items();
        var cursor: usize = 0;
        var start: usize = 0;
        while (start < frames) {
            const n = @min(frames - start, self.max_block);
            const end = start + n;
            if (self.in_main) |p| feedInput(&self.inputs, p, block, ch, start, n);

            var k = cursor;
            while (k < items.len and @as(usize, items[k].offset) < end) : (k += 1) {}
            const offset = std.math.cast(u32, start) orelse std.math.maxInt(u32);
            const result = self.inst.process(.{
                .frames = n,
                .steady_time = self.steady,
                .inputs = &self.inputs,
                .outputs = &self.outputs,
                .events = items[cursor..k],
                .offset = offset,
                .transport = if (self.has_transport) &self.transport else null,
            });
            cursor = k;
            self.steady +|= @as(i64, @intCast(n));

            if (result) |_| {
                if (self.out_main) |p| readOutput(&self.outputs, p, block, ch, start, n);
            } else |_| {
                _ = self.process_errors.fetchAdd(1, .monotonic);
            }
            start = end;
        }
    }

    /// Appends `ev` to `merged`. A full list drops it and counts the drop.
    fn mergeOne(self: *ClapPlugin, ev: Event, last: u32) void {
        var e = ev;
        e.offset = @min(e.offset, last);
        if (!self.merged.push(e)) _ = self.dropped_events.fetchAdd(1, .monotonic);
    }

    /// Control thread. Sets parameter `index` to `value` (clamped into the parameter's range)
    /// and queues the change for the next block. A change to the same parameter that is still
    /// queued overwrites it. Returns false for an unknown index.
    fn setParamByIndex(self: *ClapPlugin, index: u32, value: f32) bool {
        if (index >= self.info.params.len) return false;
        const v = self.info.params[index].clamp(value);
        self.values[index] = v;
        for (self.pending.buf[0..self.pending.len]) |*ev| {
            switch (ev.kind) {
                .param => |*p| {
                    if (p.index == index) {
                        p.value = v;
                        return true;
                    }
                },
                else => {},
            }
        }
        // A full pending list drops the change, as the Rust queue did. The value table is
        // still updated, so `getParam` reports it.
        _ = self.pending.push(.{ .offset = 0, .kind = .{ .param = .{ .index = index, .value = v } } });
        return true;
    }

    /// Control thread. The stored value of parameter `index`, or null for an unknown index.
    fn paramByIndex(self: *const ClapPlugin, index: u32) ?f32 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    /// Control thread. Loads plugin state from `data` (untrusted). A refused load changes
    /// nothing. An accepted one re-reads the values and drops the changes queued before it.
    fn loadStateBytes(self: *ClapPlugin, data: []const u8) bool {
        // Allocation failure in the snapshot is a refusal, not a crash.
        const ok = self.inst.loadState(self.gpa, data) catch return false;
        if (ok) {
            self.refreshValues();
            self.pending.clear();
        }
        return ok;
    }

    /// Control thread. The plugin's state, in bytes from `gpa`. Null when it has none.
    fn saveStateBytes(self: *ClapPlugin, gpa: Allocator) Allocator.Error!?[]u8 {
        return self.inst.saveState(gpa);
    }

    fn openEditorUi(self: *ClapPlugin) EditorError!void {
        if (!self.has_gui) return error.NoEditor;
        self.shared.link.open(self.info.name) catch |err| return switch (err) {
            error.NoEditor => error.NoEditor,
            else => error.OpenFailed,
        };
    }

    fn closeEditorUi(self: *ClapPlugin) void {
        if (self.has_gui) self.shared.link.close();
    }

    /// Control thread. A new editor handle (one reference). Release it with `releaseEditor`.
    fn editorHandle(self: *ClapPlugin) ?PluginEditor {
        if (!self.has_gui) return null;
        retain(self.shared);
        return .{ .ptr = self.shared, .vtable = &editor_vtable };
    }

    /// Control thread. A new state-reader handle (one reference). Release it with
    /// `releaseStateReader`.
    fn stateReaderHandle(self: *ClapPlugin) ?PluginStateReader {
        if (self.inst.state_ext == null) return null;
        retain(self.shared);
        return .{ .ptr = self.shared, .vtable = &state_reader_vtable };
    }
};

/// Port buffers with no ports and no storage. `deinit` on the result frees nothing.
fn emptyPorts() PortBuffers {
    return .{
        .storage = &.{},
        .frames = 0,
        .port_count = 0,
        .channel_counts = @splat(0),
        .chans = undefined,
        .ptrs = std.mem.zeroes([abi.MAX_PORTS][plugin_mod.MAX_CHANNELS]?[*]f32),
        .bufs = std.mem.zeroes([abi.MAX_PORTS]abi.ClapAudioBuffer),
    };
}

/// Copies `n` frames from `start` of the block into the main input port. A mono block fills
/// every port channel.
fn feedInput(inputs: *PortBuffers, port: usize, block: AudioBlock, ch: usize, start: usize, n: usize) void {
    const count = inputs.channel_counts[port];
    for (0..count) |c| {
        const dst = inputs.channel(port, c) orelse continue;
        const src = block.channels[@min(c, ch - 1)][start .. start + n];
        @memcpy(dst[0..n], src);
    }
}

/// Copies `n` frames of the main output port into the block from `start`. A mono block takes
/// the average of a stereo port.
fn readOutput(outputs: *PortBuffers, port: usize, block: AudioBlock, ch: usize, start: usize, n: usize) void {
    const oc = outputs.channel_counts[port];
    if (oc == 0) return;
    for (0..ch) |c| {
        const dst = block.channels[c][start .. start + n];
        if (ch == 1 and oc >= 2) {
            const l = outputs.channel(port, 0) orelse return;
            const r = outputs.channel(port, 1) orelse return;
            for (dst, l[0..n], r[0..n]) |*d, a, b| d.* = 0.5 * (a + b);
        } else {
            const src = outputs.channel(port, @min(c, oc - 1)) orelse continue;
            @memcpy(dst, src[0..n]);
        }
    }
}

// ---- the plug-0 vtable -----------------------------------------------------------------------

fn selfOf(ptr: *anyopaque) *ClapPlugin {
    return @ptrCast(@alignCast(ptr));
}

fn vInfo(ptr: *anyopaque) *const PluginInfo {
    return selfOf(ptr).info;
}

fn vPrepare(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
    const self = selfOf(ptr);
    self.prepare(sample_rate, max_block, channels) catch |err| {
        log.err("{s}: prepare failed: {}", .{ self.info.id, err });
        self.setInactive();
    };
}

fn vReset(ptr: *anyopaque) void {
    selfOf(ptr).inst.reset();
}

fn vSetParam(ptr: *anyopaque, index: u32, value: f32) bool {
    return selfOf(ptr).setParamByIndex(index, value);
}

fn vGetParam(ptr: *anyopaque, index: u32) ?f32 {
    return selfOf(ptr).paramByIndex(index);
}

fn vProcess(ptr: *anyopaque, block: AudioBlock, events_in: []const Event) void {
    selfOf(ptr).processBlock(block, events_in);
}

fn vLatency(ptr: *anyopaque) usize {
    return selfOf(ptr).latency;
}

fn vTailSamples(ptr: *anyopaque) usize {
    return selfOf(ptr).inst.tailSamples();
}

fn vSetTransport(ptr: *anyopaque, transport: *const Transport) void {
    const self = selfOf(ptr);
    self.transport = transport.*;
    self.has_transport = true;
}

fn vSaveState(ptr: *anyopaque, gpa: Allocator) Allocator.Error!?[]u8 {
    return selfOf(ptr).saveStateBytes(gpa);
}

fn vLoadState(ptr: *anyopaque, data: []const u8) bool {
    return selfOf(ptr).loadStateBytes(data);
}

fn vOpenEditor(ptr: *anyopaque) EditorError!void {
    return selfOf(ptr).openEditorUi();
}

fn vCloseEditor(ptr: *anyopaque) void {
    selfOf(ptr).closeEditorUi();
}

fn vEditor(ptr: *anyopaque) ?PluginEditor {
    return selfOf(ptr).editorHandle();
}

fn vStateReader(ptr: *anyopaque) ?PluginStateReader {
    return selfOf(ptr).stateReaderHandle();
}

const plugin_vtable: Plugin.VTable = .{
    .info = vInfo,
    .prepare = vPrepare,
    .reset = vReset,
    .set_param = vSetParam,
    .get_param = vGetParam,
    .process = vProcess,
    .latency = vLatency,
    .tail_samples = vTailSamples,
    .set_transport = vSetTransport,
    .save_state = vSaveState,
    .load_state = vLoadState,
    .open_editor = vOpenEditor,
    .close_editor = vCloseEditor,
    .editor = vEditor,
    .state_reader = vStateReader,
};

// ---- the editor and state-reader handles -----------------------------------------------------

const editor_vtable: PluginEditor.VTable = .{
    .open = editorOpen,
    .close = editorClose,
    .is_open = editorIsOpen,
    .idle = editorIdle,
    .state_changed = editorStateChanged,
    .release = handleRelease,
};

fn editorOpen(ptr: *anyopaque) EditorError!void {
    const s = sharedOf(ptr);
    if (!s.alive.load(.acquire)) return error.NoEditor;
    // Edits reported before the editor opened are stale.
    var stale: [IDLE_EDIT_CAP]events.ClapParamEdit = undefined;
    _ = s.link.idle(&stale);
    s.link.open(s.info.name) catch |err| return switch (err) {
        error.NoEditor => error.NoEditor,
        else => error.OpenFailed,
    };
}

fn editorClose(ptr: *anyopaque) void {
    const s = sharedOf(ptr);
    if (s.alive.load(.acquire)) s.link.close();
}

fn editorIsOpen(ptr: *anyopaque) bool {
    const s = sharedOf(ptr);
    return s.alive.load(.acquire) and s.link.isOpen();
}

fn editorIdle(ptr: *anyopaque, gpa: Allocator) Allocator.Error![]ParamEdit {
    const s = sharedOf(ptr);
    var out: std.ArrayList(ParamEdit) = .empty;
    errdefer out.deinit(gpa);
    if (!s.alive.load(.acquire)) return out.toOwnedSlice(gpa);
    const inst = s.inst orelse return out.toOwnedSlice(gpa);

    var raw: [IDLE_EDIT_CAP]events.ClapParamEdit = undefined;
    const n = s.link.idle(&raw);
    for (raw[0..n]) |e| {
        const index = inst.indexOfClapId(e.param_id) orelse continue;
        if (index >= s.info.params.len) continue;
        const value = inst.fromClapValue(index, e.value) orelse continue;
        const v = s.info.params[index].clamp(value);
        // Keep only the latest value per parameter.
        var found = false;
        for (out.items) |*item| {
            if (item.index == index) {
                item.value = v;
                found = true;
                break;
            }
        }
        if (!found) try out.append(gpa, .{ .index = index, .value = v });
    }
    return out.toOwnedSlice(gpa);
}

fn editorStateChanged(ptr: *anyopaque) bool {
    const s = sharedOf(ptr);
    if (!s.alive.load(.acquire)) return false;
    return s.link.host().dirty.swap(false, .monotonic);
}

const state_reader_vtable: PluginStateReader.VTable = .{
    .save_state = readerSaveState,
    .release = handleRelease,
};

fn handleRelease(ptr: *anyopaque) void {
    release(sharedOf(ptr));
}

fn readerSaveState(ptr: *anyopaque, gpa: Allocator) Allocator.Error!?[]u8 {
    const s = sharedOf(ptr);
    if (!s.alive.load(.acquire)) return null;
    return s.link.saveState(gpa);
}

/// Releases an editor handle returned by `ClapPlugin.plugin().editor`, exactly once. The handle
/// must not be used afterwards.
pub fn releaseEditor(handle: PluginEditor) void {
    release(sharedOf(handle.ptr));
}

/// Releases a state-reader handle returned by `ClapPlugin.plugin().stateReader`, exactly once.
pub fn releaseStateReader(handle: PluginStateReader) void {
    release(sharedOf(handle.ptr));
}

// ---- tests ------------------------------------------------------------------------------------
// plugin.rs has no inline tests, so every test here is new. They run the ClapPlugin against
// the in-process CLAP fixtures in test_fixture.zig (the gain effect with its GUI and state,
// and the synth with no parameters and no editor).

const fixture_gain_id: [:0]const u8 = "org.soundcraft.test.gain";
const fixture_synth_id: [:0]const u8 = "org.soundcraft.test.synth";

const gain_params = [_]plugin_mod.ParamInfo{
    params.lin("gain", "Gain", 0.0, 2.0, 1.0, .none),
    params.choice("mode", "Mode", &.{ "A", "B", "C" }, 0),
    params.lin("secret", "Secret", 0.0, 1.0, 0.0, .none),
};

const gain_info: PluginInfo = .{
    .id = fixture_gain_id,
    .name = "Fixture Gain",
    .short_name = "Gain",
    .category = .dynamics,
    .params = &gain_params,
    .is_instrument = false,
    .audiosuite = false,
};

const synth_info: PluginInfo = .{
    .id = fixture_synth_id,
    .name = "Fixture Synth",
    .short_name = "Synth",
    .category = .instrument,
    .params = &.{},
    .is_instrument = true,
    .audiosuite = false,
};

/// A loaded fixture bundle and one ClapPlugin of it. Call `close` (after the plugin is gone).
const Loaded = struct {
    bundle: bundle.Bundle,
    plug: *ClapPlugin,

    fn open(gpa: Allocator, id: [:0]const u8, info: *const PluginInfo) !Loaded {
        test_fixture.reset();
        var b = try bundle.Bundle.fromEntry(&test_fixture.entry, "");
        errdefer b.deinit();
        const plug = try ClapPlugin.create(gpa, b.factory, id, info);
        return .{ .bundle = b, .plug = plug };
    }

    fn close(self: *Loaded) void {
        self.plug.destroy();
        self.bundle.deinit();
    }
};

test "ClapPlugin: prepare activates the gain fixture and reports its latency" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 64, 2);
    try testing.expect(l.plug.inst.isActive());
    try testing.expectEqual(@as(usize, 3), p.latency());
    try testing.expectEqualStrings("Fixture Gain", p.info().name);
}

test "ClapPlugin: initial values are the plugin's, in plug-0 units, and unknown indices are refused" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    try testing.expectEqual(@as(?f32, 1.0), p.getParam(0));
    try testing.expectEqual(@as(?f32, 0.0), p.getParam(1));
    try testing.expectEqual(@as(?f32, 0.0), p.getParam(2));
    try testing.expectEqual(@as(?f32, null), p.getParam(3));
    try testing.expect(!p.setParam(3, 0.5));
}

test "ClapPlugin: set_param clamps into range, NaN becomes the default, and get_param reads it back" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    try testing.expect(p.setParam(0, 5.0));
    try testing.expectEqual(@as(?f32, 2.0), p.getParam(0));
    try testing.expect(p.setParam(0, std.math.nan(f32)));
    try testing.expectEqual(@as(?f32, 1.0), p.getParam(0));
    // A second change to the same parameter overwrites the queued one.
    try testing.expect(p.setParam(0, 0.25));
    try testing.expect(p.setParam(0, 0.5));
    try testing.expectEqual(@as(usize, 1), l.plug.pending.len);
}

test "ClapPlugin: a queued parameter change applies to the whole next block" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 64, 2);

    var left: [32]f32 = @splat(1.0);
    var right: [32]f32 = @splat(-1.0);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    try testing.expect(p.setParam(0, 0.5));
    p.process(block, &.{});

    for (left) |s| try testing.expectApproxEqAbs(@as(f32, 0.5), s, 1e-6);
    for (right) |s| try testing.expectApproxEqAbs(@as(f32, -0.5), s, 1e-6);
    try testing.expectEqual(@as(usize, 0), l.plug.pending.len);
}

test "ClapPlugin: a block longer than max_block runs in chunks" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 16, 2);

    var left: [40]f32 = @splat(0.5);
    var right: [40]f32 = @splat(0.5);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    test_fixture.reset();
    p.process(block, &.{});
    // 40 frames at 16 per call: 16, 16 and 8.
    try testing.expectEqual(@as(u32, 3), test_fixture.process_calls.load(.monotonic));
    for (left) |s| try testing.expectApproxEqAbs(@as(f32, 0.5), s, 1e-6);
}

test "ClapPlugin: a block event lands at its offset, in the chunk that holds it" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 16, 2);

    var left: [40]f32 = @splat(1.0);
    var right: [40]f32 = @splat(1.0);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    const evs = [_]Event{.{ .offset = 20, .kind = .{ .param = .{ .index = 0, .value = 0.25 } } }};
    p.process(block, &evs);

    // Frame 19 is in the second chunk, before the change; frame 20 is the first frame after it.
    try testing.expectApproxEqAbs(@as(f32, 1.0), left[19], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), left[20], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), left[39], 1e-6);
}

test "ClapPlugin: an inactive plugin passes the block through untouched" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    var left: [8]f32 = @splat(0.7);
    var right: [8]f32 = @splat(0.7);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    p.process(block, &.{});
    for (left) |s| try testing.expectEqual(@as(f32, 0.7), s);
}

test "ClapPlugin: a non-finite sample rate falls back to 48 kHz and still activates" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(std.math.nan(f32), 32, 2);
    try testing.expect(l.plug.inst.isActive());
    try testing.expectEqual(@as(usize, 3), p.latency());
}

test "ClapPlugin: the channel count is capped at the planar block limit" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 32, 100);
    try testing.expectEqual(plugin_mod.MAX_CHANNELS, l.plug.channels);
}

test "ClapPlugin: adaptEvent maps notes to MIDI for a MIDI-dialect plugin and clamps offset and velocity" {
    const on: Event = .{ .offset = 3, .kind = .{ .note_on = .{ .note = 60, .velocity = 200 } } };
    const clap = adaptEvent(.clap, false, on, 31).?;
    try testing.expectEqual(@as(u8, 127), clap.kind.note_on.velocity);

    const midi = adaptEvent(.midi, false, on, 31).?;
    try testing.expectEqualSlices(u8, &.{ 0x90, 60, 127 }, &midi.kind.midi3);

    const off: Event = .{ .offset = 9, .kind = .{ .note_off = 60 } };
    const midi_off = adaptEvent(.midi, false, off, 31).?;
    try testing.expectEqualSlices(u8, &.{ 0x80, 60, 0 }, &midi_off.kind.midi3);

    const late: Event = .{ .offset = 100, .kind = .{ .note_off = 61 } };
    try testing.expectEqual(@as(u32, 31), adaptEvent(.clap, false, late, 31).?.offset);
}

test "ClapPlugin: adaptEvent drops notes a plugin cannot take, and passes MIDI only with MIDI input" {
    const on: Event = .{ .offset = 0, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } };
    try testing.expect(adaptEvent(.none, false, on, 31) == null);

    const high: Event = .{ .offset = 0, .kind = .{ .note_on = .{ .note = 200, .velocity = 100 } } };
    try testing.expect(adaptEvent(.clap, false, high, 31) == null);

    const cc: Event = .{ .offset = 0, .kind = .{ .midi3 = .{ 0xB0, 7, 64 } } };
    try testing.expect(adaptEvent(.clap, false, cc, 31) == null);
    try testing.expect(adaptEvent(.clap, true, cc, 31) != null);

    const param: Event = .{ .offset = 0, .kind = .{ .param = .{ .index = 1, .value = 2.0 } } };
    try testing.expect(adaptEvent(.none, false, param, 31) != null);
}

test "ClapPlugin: noteMode prefers CLAP over MIDI, and a port without either takes no notes" {
    try testing.expectEqual(NoteMode.clap, noteMode(.{ .supported = abi.CLAP_NOTE_DIALECT_CLAP | abi.CLAP_NOTE_DIALECT_MIDI, .preferred = 0 }));
    try testing.expectEqual(NoteMode.midi, noteMode(.{ .supported = abi.CLAP_NOTE_DIALECT_MIDI, .preferred = 0 }));
    try testing.expectEqual(NoteMode.none, noteMode(.{ .supported = 0, .preferred = 0 }));
    try testing.expectEqual(NoteMode.none, noteMode(null));
}

test "ClapPlugin: pickMain takes the main port with channels, else the first with channels" {
    const ports = [_]PortInfo{
        .{ .channels = 0, .main = true },
        .{ .channels = 2, .main = false },
        .{ .channels = 2, .main = true },
    };
    try testing.expectEqual(@as(?usize, 2), pickMain(&ports));
    try testing.expectEqual(@as(?usize, 1), pickMain(ports[0..2]));
    try testing.expectEqual(@as(?usize, null), pickMain(ports[0..1]));
    try testing.expectEqual(@as(?usize, null), pickMain(&.{}));
}

test "ClapPlugin: the synth has no editor and refuses to open one" {
    var l = try Loaded.open(testing.allocator, fixture_synth_id, &synth_info);
    defer l.close();
    const p = l.plug.plugin();
    try testing.expectError(error.NoEditor, p.openEditor());
    try testing.expect(p.editor() == null);
    if (p.stateReader()) |reader| releaseStateReader(reader);
}

test "ClapPlugin: an editor handle opens, shows and closes the gain fixture's GUI" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    const ed = p.editor().?;
    defer releaseEditor(ed);

    try testing.expect(!ed.isOpen());
    try ed.open();
    try testing.expect(ed.isOpen());
    try testing.expectEqual(@as(u32, 1), test_fixture.gui_creates.load(.monotonic));
    ed.close();
    try testing.expect(!ed.isOpen());
}

test "ClapPlugin: an editor handle stays valid after the plugin is destroyed, and then does nothing" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    const p = l.plug.plugin();
    const ed = p.editor().?;
    const reader = p.stateReader().?;
    try ed.open();
    try testing.expect(ed.isOpen());

    l.close();

    // The plugin, its host state and its GUI are gone. The handles are still memory-safe.
    try testing.expect(!ed.isOpen());
    try testing.expectError(error.NoEditor, ed.open());
    ed.close();
    const edits = try ed.idle(testing.allocator);
    defer testing.allocator.free(edits);
    try testing.expectEqual(@as(usize, 0), edits.len);
    try testing.expect(!ed.stateChanged());
    try testing.expect((try reader.saveState(testing.allocator)) == null);

    // Release through the generic handle API, as a caller that only knows `Plugin` would.
    ed.release();
    reader.release();
}

test "ClapPlugin: a parameter edit made in the editor reaches the UI as a dense index and value" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 64, 2);
    const ed = p.editor().?;
    defer releaseEditor(ed);
    try ed.open();

    // The fixture's GUI queues a gain edit when shown. The next block reports it.
    var left: [8]f32 = @splat(1.0);
    var right: [8]f32 = @splat(1.0);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    p.process(block, &.{});

    const edits = try ed.idle(testing.allocator);
    defer testing.allocator.free(edits);
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(u32, 0), edits[0].index);
    try testing.expectApproxEqAbs(@as(f32, 0.25), edits[0].value, 1e-6);
}

test "ClapPlugin: load_state refuses a hostile blob and keeps the values; a saved blob restores them" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();

    try testing.expect(!p.loadState(&.{ 1, 2, 3 }));
    try testing.expectEqual(@as(?f32, 1.0), p.getParam(0));

    const saved = (try p.saveState(testing.allocator)).?;
    defer testing.allocator.free(saved);
    try testing.expectEqual(@as(usize, 16), saved.len);

    try testing.expect(p.setParam(0, 0.5));
    try testing.expect(p.loadState(saved));
    try testing.expectEqual(@as(?f32, 1.0), p.getParam(0));
    // The load dropped the change that was queued before it.
    try testing.expectEqual(@as(usize, 0), l.plug.pending.len);
}

test "ClapPlugin: transport and reset are accepted in any state" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    p.prepare(48_000.0, 32, 2);
    const t: Transport = .{ .playing = true, .tempo = 120.0 };
    p.setTransport(&t);
    try testing.expect(l.plug.has_transport);
    p.reset();
    p.reset();
    try testing.expect(l.plug.inst.isActive());
}

test "ClapPlugin: two editor handles keep the link until both are released" {
    var l = try Loaded.open(testing.allocator, fixture_gain_id, &gain_info);
    defer l.close();
    const p = l.plug.plugin();
    const a = p.editor().?;
    const b = p.editor().?;
    releaseEditor(a);
    // The second handle still owns a reference: the link stays readable.
    try testing.expect(!b.isOpen());
    releaseEditor(b);
}
