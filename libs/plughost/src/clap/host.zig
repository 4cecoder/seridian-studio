// Translated to Zig from soundcraft/crates/clap-host/src/ffi/host.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The host side of the CLAP connection: the `clap_host` callbacks a plugin calls
//! back into, the extension structs `get_extension` hands out, and the shared
//! `HostState` those callbacks write to.
//!
//! Threading: a plugin calls these from any thread, including the audio thread
//! (`request_process`, `params.request_flush`, `log`). Every callback here does a
//! bounded number of atomic stores and nothing else: no allocation, no locks, no
//! logging, no I/O. The UI reads the flags with `load` on the main thread.
//! `HostState` must not move after the instance creates it, because the
//! `clap_host.host_data` pointer refers to it.
//!
//! Differences from host.rs, all deliberate:
//! - `edits` was a `Mutex<Vec<_>>` that the audio thread `try_lock`ed. It is now
//!   `EditQueue`, a single-producer single-consumer ring: the audio thread's
//!   `process` pushes, the UI thread pops. No lock is reachable from the audio
//!   thread, and a full ring drops the edit, as the Rust did.
//! - `host_log` read the plugin's message and called `log::error!` and friends.
//!   Logging is not allowed on the audio thread, and the message pointer is plugin
//!   memory, so the message is not read at all: each severity is counted in
//!   `LogCounters` and the text is dropped.
//! - The host identifies itself as "Seridian" (the Rust host said "SoundCraft").
//!   The URL and version strings are left null rather than invented.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const events = @import("events.zig");

/// An atomic boolean flag, as the plugin raises it and the UI reads it.
pub const Flag = std.atomic.Value(bool);

/// Host name and vendor reported to plugins.
pub const HOST_NAME: [:0]const u8 = "Seridian";
pub const HOST_VENDOR: [:0]const u8 = "Seridian";

/// Counts of plugin log messages by severity. The text itself is not kept.
pub const LogCounters = struct {
    /// `CLAP_LOG_ERROR` and `CLAP_LOG_FATAL`.
    errors: std.atomic.Value(u32) = .init(0),
    /// `CLAP_LOG_WARNING`.
    warnings: std.atomic.Value(u32) = .init(0),
    /// Everything else (debug, info, host or plugin misbehaving).
    other: std.atomic.Value(u32) = .init(0),
};

/// Parameter edits the plugin reported (typically from its own GUI), waiting for the
/// UI. A bounded single-producer single-consumer ring of `abi.EDIT_CAP` slots:
/// `push` is called only from the audio thread, `pop` only from the UI thread.
/// Both are wait-free. A full ring refuses the edit.
pub const EditQueue = struct {
    slots: [abi.EDIT_CAP]events.ClapParamEdit = undefined,
    /// Written only by the producer. Counts edits ever pushed (wrapping).
    head: std.atomic.Value(usize) = .init(0),
    /// Written only by the consumer. Counts edits ever popped (wrapping).
    tail: std.atomic.Value(usize) = .init(0),

    /// Audio thread. Returns false, keeping nothing, when the ring is full.
    pub fn push(self: *EditQueue, edit: events.ClapParamEdit) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head -% tail >= abi.EDIT_CAP) return false;
        self.slots[head % abi.EDIT_CAP] = edit;
        self.head.store(head +% 1, .release);
        return true;
    }

    /// UI thread. The oldest pending edit, or null when none is pending.
    pub fn pop(self: *EditQueue) ?events.ClapParamEdit {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (head == tail) return null;
        const edit = self.slots[tail % abi.EDIT_CAP];
        self.tail.store(tail +% 1, .release);
        return edit;
    }
};

/// Flags the plugin raises through the host callbacks (any thread). The UI or the
/// owner reads and clears them on its own thread.
pub const HostState = struct {
    pub const Count = std.atomic.Value(u64);

    restart: Flag = .init(false),
    process: Flag = .init(false),
    callback: Flag = .init(false),
    latency_changed: Flag = .init(false),
    params_rescan: Flag = .init(false),
    /// `clap_host_state.mark_dirty`.
    dirty: Flag = .init(false),
    /// `clap_host_gui` requests, serviced by the editor's `idle` on the main thread.
    gui_closed: Flag = .init(false),
    gui_destroyed: Flag = .init(false),
    gui_show: Flag = .init(false),
    gui_hide: Flag = .init(false),
    /// A size an embedded editor asked for (`width << 32 | height`; 0 = none pending).
    gui_resize: Count = .init(0),
    logs: LogCounters = .{},
    edits: EditQueue = .{},

    /// UI thread. Moves the pending plugin-reported edits into `out` (CLAP ids and
    /// values) and returns how many were moved. Stops when `out` is full.
    pub fn drainEdits(self: *HostState, out: []events.ClapParamEdit) usize {
        var n: usize = 0;
        while (n < out.len) {
            out[n] = self.edits.pop() orelse break;
            n += 1;
        }
        return n;
    }
};

/// The state a `clap_host` points to through `host_data`, or null for a null host or
/// a host with no data. A plugin can pass back any pointer it likes, so both are
/// checked.
fn stateOf(host: ?*const abi.ClapHost) ?*HostState {
    const h = host orelse return null;
    const data = h.host_data orelse return null;
    return @ptrCast(@alignCast(data));
}

// ---- core callbacks ---------------------------------------------------------------------------

pub fn hostRequestRestart(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.restart.store(true, .monotonic);
}

pub fn hostRequestProcess(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.process.store(true, .monotonic);
}

pub fn hostRequestCallback(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.callback.store(true, .monotonic);
}

// ---- log --------------------------------------------------------------------------------------

/// `clap_host_log.log`. Counts the severity; the message is not read or logged (see
/// the module docs). Safe on any thread.
pub fn hostLog(host: *const abi.ClapHost, severity: i32, msg: [*:0]const u8) callconv(.c) void {
    _ = msg;
    const s = stateOf(host) orelse return;
    switch (severity) {
        abi.CLAP_LOG_ERROR, abi.CLAP_LOG_FATAL => _ = s.logs.errors.fetchAdd(1, .monotonic),
        abi.CLAP_LOG_WARNING => _ = s.logs.warnings.fetchAdd(1, .monotonic),
        else => _ = s.logs.other.fetchAdd(1, .monotonic),
    }
}

// ---- params -----------------------------------------------------------------------------------

/// `clap_host_params.rescan`. The flags are accepted and not interpreted here; the
/// owner re-reads the whole table when the flag is set.
pub fn hostParamsRescan(host: *const abi.ClapHost, flags: u32) callconv(.c) void {
    _ = flags;
    if (stateOf(host)) |s| s.params_rescan.store(true, .monotonic);
}

/// `clap_host_params.clear`. Accepted and ignored: this host keeps no automation.
pub fn hostParamsClear(host: *const abi.ClapHost, param_id: abi.ClapId, flags: u32) callconv(.c) void {
    _ = host;
    _ = param_id;
    _ = flags;
}

/// `clap_host_params.request_flush`. The plugin wants a flush, which needs the audio
/// loop to run, so this raises the same flag as `request_process`.
pub fn hostParamsRequestFlush(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.process.store(true, .monotonic);
}

// ---- latency, state ---------------------------------------------------------------------------

/// `clap_host_latency.changed`.
pub fn hostLatencyChanged(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.latency_changed.store(true, .monotonic);
}

/// `clap_host_state.mark_dirty`.
pub fn hostStateMarkDirty(host: *const abi.ClapHost) callconv(.c) void {
    if (stateOf(host)) |s| s.dirty.store(true, .monotonic);
}

// ---- gui --------------------------------------------------------------------------------------

/// `clap_host_gui.resize_hints_changed`. Accepted and ignored.
pub fn hostGuiResizeHintsChanged(host: *const abi.ClapHost) callconv(.c) void {
    _ = host;
}

/// `clap_host_gui.request_resize`. Floating windows belong to the plugin, which
/// resizes them itself; an embedded editor's host window is resized by the editor's
/// `idle` on the main thread. Zero sizes are ignored. Always reports success, as the
/// Rust did.
pub fn hostGuiRequestResize(host: *const abi.ClapHost, width: u32, height: u32) callconv(.c) bool {
    if (stateOf(host)) |s| {
        if (width > 0 and height > 0) {
            s.gui_resize.store((@as(u64, width) << 32) | @as(u64, height), .monotonic);
        }
    }
    return true;
}

/// `clap_host_gui.request_show`. Reports false when there is no host state.
pub fn hostGuiRequestShow(host: *const abi.ClapHost) callconv(.c) bool {
    const s = stateOf(host) orelse return false;
    s.gui_show.store(true, .monotonic);
    return true;
}

/// `clap_host_gui.request_hide`. Reports false when there is no host state.
pub fn hostGuiRequestHide(host: *const abi.ClapHost) callconv(.c) bool {
    const s = stateOf(host) orelse return false;
    s.gui_hide.store(true, .monotonic);
    return true;
}

/// `clap_host_gui.closed`. `was_destroyed` is recorded separately so the owner knows
/// the plugin already released its window.
pub fn hostGuiClosed(host: *const abi.ClapHost, was_destroyed: bool) callconv(.c) void {
    if (stateOf(host)) |s| {
        if (was_destroyed) s.gui_destroyed.store(true, .monotonic);
        s.gui_closed.store(true, .monotonic);
    }
}

// ---- extension structs handed out by get_extension ---------------------------------------------

const host_log_ext: abi.ClapHostLog = .{ .log = hostLog };

const host_params_ext: abi.ClapHostParams = .{
    .rescan = hostParamsRescan,
    .clear = hostParamsClear,
    .request_flush = hostParamsRequestFlush,
};

const host_latency_ext: abi.ClapHostLatency = .{ .changed = hostLatencyChanged };

const host_state_ext: abi.ClapHostState = .{ .mark_dirty = hostStateMarkDirty };

const host_gui_ext: abi.ClapHostGui = .{
    .resize_hints_changed = hostGuiResizeHintsChanged,
    .request_resize = hostGuiRequestResize,
    .request_show = hostGuiRequestShow,
    .request_hide = hostGuiRequestHide,
    .closed = hostGuiClosed,
};

/// `clap_host.get_extension`. Hands out the extensions this host implements, and
/// null for everything else (thread-check, timers, fd support and the rest: CLAP
/// allows null). An id that is too long, or has no NUL within the cap, is null.
pub fn hostGetExtension(host: *const abi.ClapHost, extension_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    _ = host;
    const id = abi.readCStr(extension_id) orelse return null;
    if (std.mem.eql(u8, id, abi.CLAP_EXT_LOG)) return &host_log_ext;
    if (std.mem.eql(u8, id, abi.CLAP_EXT_PARAMS)) return &host_params_ext;
    if (std.mem.eql(u8, id, abi.CLAP_EXT_LATENCY)) return &host_latency_ext;
    if (std.mem.eql(u8, id, abi.CLAP_EXT_STATE)) return &host_state_ext;
    if (std.mem.eql(u8, id, abi.CLAP_EXT_GUI)) return &host_gui_ext;
    return null;
}

/// The `clap_host` struct for one instance. `state` must outlive it and must not
/// move: the plugin keeps `host_data` pointing at it.
pub fn makeClapHost(state: *HostState) abi.ClapHost {
    return .{
        .clap_version = abi.CLAP_VERSION,
        .host_data = state,
        .name = HOST_NAME.ptr,
        .vendor = HOST_VENDOR.ptr,
        .url = null,
        .version = null,
        .get_extension = hostGetExtension,
        .request_restart = hostRequestRestart,
        .request_process = hostRequestProcess,
        .request_callback = hostRequestCallback,
    };
}

// ---- tests ------------------------------------------------------------------------------------
// The Rust file has no inline tests. These check the behaviour the Seridian
// adaptations rely on (flags, the edit ring, the log counters, bounded extension ids).

test "plugin callbacks raise the flags the owner reads" {
    var state: HostState = .{};
    const host = makeClapHost(&state);

    hostRequestRestart(&host);
    hostRequestProcess(&host);
    hostRequestCallback(&host);
    hostLatencyChanged(&host);
    hostStateMarkDirty(&host);
    hostParamsRescan(&host, abi.CLAP_PARAM_RESCAN_ALL);
    hostParamsRequestFlush(&host);

    try testing.expect(state.restart.load(.monotonic));
    try testing.expect(state.process.load(.monotonic));
    try testing.expect(state.callback.load(.monotonic));
    try testing.expect(state.latency_changed.load(.monotonic));
    try testing.expect(state.dirty.load(.monotonic));
    try testing.expect(state.params_rescan.load(.monotonic));
    try testing.expect(!state.gui_show.load(.monotonic));
}

test "a host without state data ignores the callbacks and refuses gui show and hide" {
    var state: HostState = .{};
    var host = makeClapHost(&state);
    host.host_data = null;

    hostRequestRestart(&host);
    hostRequestProcess(&host);
    hostParamsClear(&host, 1, abi.CLAP_PARAM_CLEAR_ALL);
    try testing.expect(!hostGuiRequestShow(&host));
    try testing.expect(!hostGuiRequestHide(&host));
    try testing.expect(hostGuiRequestResize(&host, 640, 480));
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_PARAMS.ptr) != null);
}

test "get_extension hands out the implemented extensions and null for the rest" {
    var state: HostState = .{};
    const host = makeClapHost(&state);

    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_LOG.ptr) == @as(?*const anyopaque, &host_log_ext));
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_PARAMS.ptr) != null);
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_LATENCY.ptr) != null);
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_STATE.ptr) != null);
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_GUI.ptr) != null);

    // Thread check, audio ports and unknown ids are unsupported: null.
    try testing.expect(hostGetExtension(&host, abi.CLAP_EXT_THREAD_CHECK.ptr) == null);
    try testing.expect(hostGetExtension(&host, "clap.not-a-real-extension") == null);
}

test "get_extension treats an unterminated id as absent, not as a read past the cap" {
    var state: HostState = .{};
    const host = makeClapHost(&state);
    var big: [abi.MAX_STRING_LEN + 8]u8 = @splat('x');
    const unterminated: [*:0]const u8 = @ptrCast(&big);
    try testing.expect(hostGetExtension(&host, unterminated) == null);
}

test "the gui resize request packs width and height and ignores zero sizes" {
    var state: HostState = .{};
    const host = makeClapHost(&state);

    try testing.expect(hostGuiRequestResize(&host, 640, 480));
    try testing.expectEqual((@as(u64, 640) << 32) | 480, state.gui_resize.load(.monotonic));

    // A zero dimension leaves the pending size as it was, and still reports success.
    try testing.expect(hostGuiRequestResize(&host, 0, 100));
    try testing.expect(hostGuiRequestResize(&host, 100, 0));
    try testing.expectEqual((@as(u64, 640) << 32) | 480, state.gui_resize.load(.monotonic));
}

test "gui show, hide and closed set their flags, and destroyed only with was_destroyed" {
    var state: HostState = .{};
    const host = makeClapHost(&state);

    try testing.expect(hostGuiRequestShow(&host));
    try testing.expect(state.gui_show.load(.monotonic));
    try testing.expect(hostGuiRequestHide(&host));
    try testing.expect(state.gui_hide.load(.monotonic));

    hostGuiClosed(&host, false);
    try testing.expect(state.gui_closed.load(.monotonic));
    try testing.expect(!state.gui_destroyed.load(.monotonic));
    hostGuiClosed(&host, true);
    try testing.expect(state.gui_destroyed.load(.monotonic));
}

test "the edit ring is first-in first-out, refuses at capacity and drains to the UI" {
    var state: HostState = .{};
    var i: usize = 0;
    while (i < abi.EDIT_CAP) : (i += 1) {
        try testing.expect(state.edits.push(.{ .param_id = @intCast(i), .value = 0.5 }));
    }
    // Full: the next edit is refused, and nothing already queued is lost.
    try testing.expect(!state.edits.push(.{ .param_id = 9999, .value = 1.0 }));

    try testing.expectEqual(@as(abi.ClapId, 0), state.edits.pop().?.param_id);
    // One slot is free again, and it is used at the back of the queue.
    try testing.expect(state.edits.push(.{ .param_id = 9999, .value = 1.0 }));

    var out: [abi.EDIT_CAP]events.ClapParamEdit = undefined;
    const n = state.drainEdits(&out);
    try testing.expectEqual(@as(usize, abi.EDIT_CAP), n);
    try testing.expectEqual(@as(abi.ClapId, 1), out[0].param_id);
    try testing.expectEqual(@as(abi.ClapId, 9999), out[n - 1].param_id);
    try testing.expect(state.edits.pop() == null);
    try testing.expectEqual(@as(usize, 0), state.drainEdits(&out));
}

test "the edit ring keeps working after its counters wrap a full lap" {
    var q: EditQueue = .{};
    var k: usize = 0;
    while (k < 3 * abi.EDIT_CAP) : (k += 1) {
        try testing.expect(q.push(.{ .param_id = @intCast(k % 1000), .value = 0.0 }));
        const got = q.pop().?;
        try testing.expectEqual(@as(abi.ClapId, @intCast(k % 1000)), got.param_id);
    }
}

test "plugin log messages are counted by severity and the text is not read" {
    var state: HostState = .{};
    const host = makeClapHost(&state);

    hostLog(&host, abi.CLAP_LOG_ERROR, "boom");
    hostLog(&host, abi.CLAP_LOG_FATAL, "boom");
    hostLog(&host, abi.CLAP_LOG_WARNING, "careful");
    hostLog(&host, abi.CLAP_LOG_DEBUG, "details");
    hostLog(&host, abi.CLAP_LOG_PLUGIN_MISBEHAVING, "bad");

    try testing.expectEqual(@as(u32, 2), state.logs.errors.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), state.logs.warnings.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), state.logs.other.load(.monotonic));
}
