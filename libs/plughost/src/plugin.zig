// Translated to Zig from soundcraft/crates/dsp/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The plugin host interface shared by every realtime plugin and by the CLAP,
//! VST3 and AU wrappers. Types: Category, PluginInfo, Transport, AudioBlock, and
//! the `Plugin` handle (a hand-written vtable, the Zig form of Rust's
//! `Box<dyn Plugin>`), with `PluginEditor` and `PluginStateReader` handles.
//!
//! Differences from the Rust trait, all deliberate:
//! - Parameters are addressed by a dense `u32` index into `PluginInfo.params`.
//!   String ids are only for UI, state and MCP lookup: `indexOfId` (linear, non-RT).
//! - Audio is planar `f32` in an `AudioBlock` of at most `MAX_CHANNELS` channels.
//! - Note and MIDI calls are `Event`s in the `events` slice passed to `process`.
//!   `set_sample` and `all_notes_off` are not translated (no sampler here).
//! - Optional methods are nullable vtable entries; a null entry gives the Rust
//!   default (latency 0, no state, no editor, and so on).
//!
//! Realtime contract: `Plugin.process` never allocates, locks, logs or does I/O;
//! buffers are sized in `prepare`. `saveState`, `openEditor`, `editor` and the
//! editor handle's calls are control or UI thread only.

const std = @import("std");
const testing = std.testing;
const params = @import("params.zig");
const event = @import("event.zig");

pub const ParamInfo = params.ParamInfo;
pub const Unit = params.Unit;
pub const Taper = params.Taper;
pub const Event = event.Event;
pub const EventList = event.EventList;

/// Most channels a block can carry. Matches the host's planar layout limit.
pub const MAX_CHANNELS: usize = 16;

/// Plugin category, used to group the insert menu.
pub const Category = enum { eq, dynamics, pitch_shift, reverb, delay, modulation, harmonic, dither, instrument, other };

/// Static description of a plugin.
pub const PluginInfo = struct {
    id: []const u8,
    name: []const u8,
    /// At most 8 characters, for insert slots.
    short_name: []const u8,
    category: Category,
    params: []const ParamInfo,
    is_instrument: bool,
    /// Usable as an offline (AudioSuite-style) process.
    audiosuite: bool,
};

/// Looks up a parameter's dense index by id. Linear scan: use it on the control
/// thread (UI, state, MCP), never per block.
pub fn indexOfId(info: *const PluginInfo, id: []const u8) ?u32 {
    for (info.params, 0..) |pi, i| {
        if (std.mem.eql(u8, pi.id, id)) return @intCast(i);
    }
    return null;
}

/// The host's transport at the start of a block, for tempo-synced plugins.
pub const Transport = struct {
    playing: bool = false,
    recording: bool = false,
    /// Quarter notes per minute.
    tempo: f64 = 0.0,
    numerator: u32 = 0,
    denominator: u32 = 0,
    /// Timeline position.
    samples: i64 = 0,
    seconds: f64 = 0.0,
    quarters: f64 = 0.0,
    /// Start of the current bar, in quarter notes, and its number (0 for the first bar).
    bar_start: f64 = 0.0,
    bar: i64 = 0,
};

/// Planar audio for one block: `channels[c][0..frames]` is channel `c`. Only the
/// first `n_channels` entries are valid. The pointers are borrowed from the host
/// for the duration of the call.
pub const AudioBlock = struct {
    channels: [MAX_CHANNELS][*]f32 = undefined,
    n_channels: usize = 0,
    frames: usize = 0,

    /// Builds a block from channel slices. `frames` is the shortest channel, so
    /// every index below it is readable. Control thread or tests (checks its length).
    pub fn fromSlices(bufs: []const []f32) AudioBlock {
        if (bufs.len > MAX_CHANNELS) @panic("AudioBlock: more than MAX_CHANNELS channels");
        var block: AudioBlock = .{ .n_channels = bufs.len, .frames = 0 };
        var frames: usize = std.math.maxInt(usize);
        for (bufs, 0..) |buf, i| {
            block.channels[i] = buf.ptr;
            frames = @min(frames, buf.len);
        }
        block.frames = if (bufs.len == 0) 0 else frames;
        return block;
    }

    /// One channel's frames. `ch` must be below `n_channels`.
    pub fn channel(self: AudioBlock, ch: usize) []f32 {
        std.debug.assert(ch < self.n_channels);
        return self.channels[ch][0..self.frames];
    }
};

/// Errors from opening an editor (the Rust `Result<(), String>`).
pub const EditorError = error{ NoEditor, OpenFailed };

/// A realtime audio processor or instrument, as a handle over an implementation.
/// `ptr` is the instance; `vtable` holds its methods. The handle is a borrowed
/// reference: the instance must outlive it.
pub const Plugin = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Required entries have no Rust default; the rest are optional.
    pub const VTable = struct {
        info: *const fn (ptr: *anyopaque) *const PluginInfo,
        /// Sizes every buffer the plugin needs. Control thread.
        prepare: *const fn (ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void,
        reset: *const fn (ptr: *anyopaque) void,
        /// Clamps into range (NaN becomes the default). `false` if `index` is out of range.
        set_param: *const fn (ptr: *anyopaque, index: u32, value: f32) bool,
        get_param: *const fn (ptr: *anyopaque, index: u32) ?f32,
        /// In-place processing of `block.frames` frames. Audio thread: no allocation.
        /// Events are sorted by offset and lie within the block.
        process: *const fn (ptr: *anyopaque, block: AudioBlock, events: []const Event) void,

        latency: ?*const fn (ptr: *anyopaque) usize = null,
        tail_samples: ?*const fn (ptr: *anyopaque) usize = null,
        /// Gain reduction in dB for metering (a non-negative amount).
        gain_reduction_db: ?*const fn (ptr: *anyopaque) f32 = null,
        set_transport: ?*const fn (ptr: *anyopaque, transport: *const Transport) void = null,
        /// Control thread only. Returns caller-owned bytes from `gpa`, or null.
        save_state: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 = null,
        /// Hostile input: the implementation must validate `data`. `false` keeps the previous state.
        load_state: ?*const fn (ptr: *anyopaque, data: []const u8) bool = null,
        open_editor: ?*const fn (ptr: *anyopaque) EditorError!void = null,
        close_editor: ?*const fn (ptr: *anyopaque) void = null,
        editor: ?*const fn (ptr: *anyopaque) ?PluginEditor = null,
        state_reader: ?*const fn (ptr: *anyopaque) ?PluginStateReader = null,
    };

    pub fn info(self: Plugin) *const PluginInfo {
        return self.vtable.info(self.ptr);
    }

    pub fn prepare(self: Plugin, sample_rate: f32, max_block: usize, channels: usize) void {
        self.vtable.prepare(self.ptr, sample_rate, max_block, channels);
    }

    pub fn reset(self: Plugin) void {
        self.vtable.reset(self.ptr);
    }

    pub fn setParam(self: Plugin, index: u32, value: f32) bool {
        return self.vtable.set_param(self.ptr, index, value);
    }

    pub fn getParam(self: Plugin, index: u32) ?f32 {
        return self.vtable.get_param(self.ptr, index);
    }

    /// Audio thread.
    pub fn process(self: Plugin, block: AudioBlock, events: []const Event) void {
        self.vtable.process(self.ptr, block, events);
    }

    pub fn latency(self: Plugin) usize {
        return if (self.vtable.latency) |f| f(self.ptr) else 0;
    }

    pub fn tailSamples(self: Plugin) usize {
        return if (self.vtable.tail_samples) |f| f(self.ptr) else 0;
    }

    pub fn gainReductionDb(self: Plugin) f32 {
        return if (self.vtable.gain_reduction_db) |f| f(self.ptr) else 0.0;
    }

    /// Called before `process` with the transport for the next block.
    pub fn setTransport(self: Plugin, transport: *const Transport) void {
        if (self.vtable.set_transport) |f| f(self.ptr, transport);
    }

    /// The plugin's whole state as bytes. Without a `save_state` entry, reads it
    /// through the state reader, as the Rust default does. Control thread only:
    /// may allocate.
    pub fn saveState(self: Plugin, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        if (self.vtable.save_state) |f| return f(self.ptr, gpa);
        var reader = self.stateReader() orelse return null;
        return reader.saveState(gpa);
    }

    /// Hostile input. `false` if unsupported or rejected; the plugin keeps its previous state.
    pub fn loadState(self: Plugin, data: []const u8) bool {
        return if (self.vtable.load_state) |f| f(self.ptr, data) else false;
    }

    /// Control thread (UI).
    pub fn openEditor(self: Plugin) EditorError!void {
        const f = self.vtable.open_editor orelse return error.NoEditor;
        return f(self.ptr);
    }

    /// Control thread (UI). No-op when no editor is open.
    pub fn closeEditor(self: Plugin) void {
        if (self.vtable.close_editor) |f| f(self.ptr);
    }

    /// Control thread (UI). The handle stays valid after the instance is gone; its calls then do nothing.
    pub fn editor(self: Plugin) ?PluginEditor {
        const f = self.vtable.editor orelse return null;
        return f(self.ptr);
    }

    /// Control thread (UI). `null` when the plugin has no state of its own.
    pub fn stateReader(self: Plugin) ?PluginStateReader {
        const f = self.vtable.state_reader orelse return null;
        return f(self.ptr);
    }
};

/// A parameter change made in the editor, by dense index, in SoundCraft units.
pub const ParamEdit = struct { index: u32, value: f32 };

/// A plugin's editor (GUI), driven from the UI thread while the instance processes
/// on the audio thread.
pub const PluginEditor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque) EditorError!void,
        close: *const fn (ptr: *anyopaque) void,
        is_open: *const fn (ptr: *anyopaque) bool,
        /// Call every UI frame while open. Returns edits made in the editor; the
        /// caller frees the slice with the same `gpa`.
        idle: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error![]ParamEdit,
        state_changed: ?*const fn (ptr: *anyopaque) bool = null,
        set_param: ?*const fn (ptr: *anyopaque, index: u32, value: f32) void = null,
        /// The plugin's own text for a value, or null to format it yourself. Caller frees.
        value_text: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, index: u32, value: f32) std.mem.Allocator.Error!?[]u8 = null,
        /// Gives the handle back. Implementations that reference-count a shared block
        /// (CLAP, VST3) need it; the handle must not be used afterwards.
        release: ?*const fn (ptr: *anyopaque) void = null,
    };

    /// Returns the handle to its owner, exactly once. A no-op for implementations that
    /// hold no reference. Control or UI thread.
    pub fn release(self: PluginEditor) void {
        if (self.vtable.release) |f| f(self.ptr);
    }

    pub fn open(self: PluginEditor) EditorError!void {
        return self.vtable.open(self.ptr);
    }

    pub fn close(self: PluginEditor) void {
        self.vtable.close(self.ptr);
    }

    pub fn isOpen(self: PluginEditor) bool {
        return self.vtable.is_open(self.ptr);
    }

    /// Caller frees the returned slice with `gpa`.
    pub fn idle(self: PluginEditor, gpa: std.mem.Allocator) std.mem.Allocator.Error![]ParamEdit {
        return self.vtable.idle(self.ptr, gpa);
    }

    /// True once after the plugin marked its state dirty without a parameter change.
    pub fn stateChanged(self: PluginEditor) bool {
        return if (self.vtable.state_changed) |f| f(self.ptr) else false;
    }

    /// Tells the editor a parameter changed elsewhere (automation, generic editor).
    pub fn setParam(self: PluginEditor, index: u32, value: f32) void {
        if (self.vtable.set_param) |f| f(self.ptr, index, value);
    }

    pub fn valueText(self: PluginEditor, gpa: std.mem.Allocator, index: u32, value: f32) std.mem.Allocator.Error!?[]u8 {
        const f = self.vtable.value_text orelse return null;
        return f(self.ptr, gpa, index, value);
    }
};

/// Reads a plugin's state from the UI thread while the instance processes.
pub const PluginStateReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// What `Plugin.saveState` would return. Caller frees with `gpa`.
        save_state: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8,
        /// Gives the handle back; see `PluginEditor.VTable.release`.
        release: ?*const fn (ptr: *anyopaque) void = null,
    };

    /// Returns the handle to its owner, exactly once. Control or UI thread.
    pub fn release(self: PluginStateReader) void {
        if (self.vtable.release) |f| f(self.ptr);
    }

    pub fn saveState(self: PluginStateReader, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        return self.vtable.save_state(self.ptr, gpa);
    }
};

// --- tests ---

const test_params = [_]ParamInfo{
    params.lin("gain", "Gain", 0.0, 2.0, 1.0, .none),
    params.log("freq", "Frequency", 20.0, 20000.0, 1000.0, .hz),
    params.toggle("bypass", "Bypass", false),
};

const test_info = PluginInfo{
    .id = "test_gain",
    .name = "Test Gain",
    .short_name = "Gain",
    .category = .other,
    .params = &test_params,
    .is_instrument = false,
    .audiosuite = false,
};

/// A minimal plugin implementing only the required vtable entries.
const TestGain = struct {
    gain: f32 = 1.0,
    freq: f32 = 1000.0,
    bypass: f32 = 0.0,
    last_events: usize = 0,

    fn fromPtr(ptr: *anyopaque) *TestGain {
        return @ptrCast(@alignCast(ptr));
    }

    fn infoFn(_: *anyopaque) *const PluginInfo {
        return &test_info;
    }

    fn prepareFn(_: *anyopaque, _: f32, _: usize, _: usize) void {}

    fn resetFn(_: *anyopaque) void {}

    fn setParamFn(ptr: *anyopaque, index: u32, value: f32) bool {
        if (index >= test_params.len) return false;
        const self = fromPtr(ptr);
        const v = test_params[index].clamp(value);
        switch (index) {
            0 => self.gain = v,
            1 => self.freq = v,
            else => self.bypass = v,
        }
        return true;
    }

    fn getParamFn(ptr: *anyopaque, index: u32) ?f32 {
        const self = fromPtr(ptr);
        return switch (index) {
            0 => self.gain,
            1 => self.freq,
            2 => self.bypass,
            else => null,
        };
    }

    fn processFn(ptr: *anyopaque, block: AudioBlock, events: []const Event) void {
        const self = fromPtr(ptr);
        self.last_events = events.len;
        for (0..block.n_channels) |ch| {
            for (block.channel(ch)) |*s| s.* *= self.gain;
        }
    }

    const vtable: Plugin.VTable = .{
        .info = infoFn,
        .prepare = prepareFn,
        .reset = resetFn,
        .set_param = setParamFn,
        .get_param = getParamFn,
        .process = processFn,
    };

    fn plugin(self: *TestGain) Plugin {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Same as `TestGain`, plus a state reader. Its `save_state` entry is null, so
/// `Plugin.saveState` must fall back to the reader.
const StatefulGain = struct {
    gain: f32 = 1.0,

    fn stateReaderFn(ptr: *anyopaque) ?PluginStateReader {
        return .{ .ptr = ptr, .vtable = &reader_vtable };
    }

    fn readerSave(_: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        const out = try gpa.alloc(u8, 1);
        out[0] = 42;
        return out;
    }

    const reader_vtable: PluginStateReader.VTable = .{ .save_state = readerSave };

    const vtable: Plugin.VTable = blk: {
        var v = TestGain.vtable;
        v.state_reader = stateReaderFn;
        break :blk v;
    };

    fn plugin(self: *StatefulGain) Plugin {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "indexOfId returns the dense parameter index" {
    try testing.expectEqual(@as(?u32, 0), indexOfId(&test_info, "gain"));
    try testing.expectEqual(@as(?u32, 1), indexOfId(&test_info, "freq"));
    try testing.expectEqual(@as(?u32, 2), indexOfId(&test_info, "bypass"));
}

test "indexOfId returns null for an unknown id" {
    try testing.expectEqual(@as(?u32, null), indexOfId(&test_info, "missing"));
    try testing.expectEqual(@as(?u32, null), indexOfId(&test_info, ""));
    try testing.expectEqual(@as(?u32, null), indexOfId(&test_info, "GAIN"));
}

test "indexOfId works on an empty table" {
    const empty = PluginInfo{
        .id = "e",
        .name = "E",
        .short_name = "E",
        .category = .other,
        .params = &.{},
        .is_instrument = false,
        .audiosuite = false,
    };
    try testing.expectEqual(@as(?u32, null), indexOfId(&empty, "gain"));
}

test "Transport defaults to stopped at the origin" {
    const t: Transport = .{};
    try testing.expect(!t.playing);
    try testing.expect(!t.recording);
    try testing.expectEqual(@as(f64, 0.0), t.tempo);
    try testing.expectEqual(@as(i64, 0), t.samples);
    try testing.expectEqual(@as(i64, 0), t.bar);
}

test "AudioBlock.fromSlices takes the shortest channel as the frame count" {
    var left = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var right = [_]f32{ 0, 0, 0, 0, 0, 0, 0 };
    const bufs = [_][]f32{ &left, &right };
    const block = AudioBlock.fromSlices(&bufs);
    try testing.expectEqual(@as(usize, 2), block.n_channels);
    try testing.expectEqual(@as(usize, 7), block.frames);
    try testing.expectEqual(@as(f32, 4.0), block.channel(0)[3]);

    const none = AudioBlock.fromSlices(&.{});
    try testing.expectEqual(@as(usize, 0), none.n_channels);
    try testing.expectEqual(@as(usize, 0), none.frames);
}

test "Plugin dispatches parameters by index and clamps them" {
    var g: TestGain = .{};
    const p = g.plugin();

    try testing.expect(p.setParam(0, 5.0));
    try testing.expectEqual(@as(?f32, 2.0), p.getParam(0));
    try testing.expect(p.setParam(2, 0.8));
    try testing.expectEqual(@as(?f32, 1.0), p.getParam(2));
    try testing.expectEqual(@as(?f32, 1000.0), p.getParam(1));

    try testing.expect(!p.setParam(9, 1.0));
    try testing.expectEqual(@as(?f32, null), p.getParam(9));
    try testing.expectEqualStrings("test_gain", p.info().id);
}

test "Plugin.process scales every channel and passes the events through" {
    var g: TestGain = .{};
    const p = g.plugin();
    try testing.expect(p.setParam(0, 2.0));

    var left = [_]f32{ 1, 1, 1, 1 };
    var right = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    const bufs = [_][]f32{ &left, &right };
    var list = try EventList.init(testing.allocator, 2);
    defer list.deinit(testing.allocator);
    try testing.expect(list.push(.{ .offset = 2, .kind = .{ .note_off = 60 } }));

    p.process(AudioBlock.fromSlices(&bufs), list.items());
    try testing.expectEqual(@as(f32, 2.0), left[0]);
    try testing.expectEqual(@as(f32, 1.0), right[3]);
    try testing.expectEqual(@as(usize, 1), g.last_events);
}

test "a plugin without optional entries has no state or editor" {
    var g: TestGain = .{};
    const p = g.plugin();

    try testing.expectEqual(@as(?[]u8, null), try p.saveState(testing.allocator));
    try testing.expect(!p.loadState("anything"));
    try testing.expectError(error.NoEditor, p.openEditor());
    p.closeEditor();
    try testing.expectEqual(@as(?PluginEditor, null), p.editor());
    try testing.expectEqual(@as(?PluginStateReader, null), p.stateReader());
}

test "Rust defaults for latency, tail, gain reduction and transport" {
    var g: TestGain = .{};
    const p = g.plugin();
    try testing.expectEqual(@as(usize, 0), p.latency());
    try testing.expectEqual(@as(usize, 0), p.tailSamples());
    try testing.expectEqual(@as(f32, 0.0), p.gainReductionDb());
    const t: Transport = .{ .playing = true };
    p.setTransport(&t);
}

test "saveState falls back to the state reader and the caller frees the bytes" {
    var s: StatefulGain = .{};
    const p = s.plugin();
    const bytes = (try p.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 1), bytes.len);
    try testing.expectEqual(@as(u8, 42), bytes[0]);
}

test "only_the_sampler_takes_samples is not translated" {
    // Rust: `only_the_sampler_takes_samples` checks `set_sample` on every registry
    // plugin. There is no sampler and no registry in this unit, and `set_sample` is
    // not translated, so the test cannot be expressed here.
    return error.SkipZigTest;
}

test "sample_buffer_frames_is_the_shortest_channel is not translated" {
    // Rust: `sample_buffer_frames_is_the_shortest_channel` tests `SampleBuffer`, which
    // is out of scope for this unit (the sampler owns it). The shortest-channel rule
    // is covered by `AudioBlock.fromSlices` above.
    return error.SkipZigTest;
}
