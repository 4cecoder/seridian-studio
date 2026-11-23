//! Native PipeWire playback stream (Linux), in Zig over hand-written libpipewire declarations.
//!
//! Translated from the former pw_stream.c. There is no @cImport: the few libpipewire functions
//! and the structs the stream touches are declared below with their C layout (PipeWire 1.x,
//! checked against the headers with sizes and offsets in the tests), and the SPA format POD,
//! which SPA only offers as inline C, is built by spa_pod.zig. The render callback runs on
//! PipeWire's real-time data thread.

const std = @import("std");
const spa_pod = @import("spa_pod.zig");

const log = std.log.scoped(.pipewire_backend);

// ---- libpipewire-0.3 (opaque handles and the structs we read or fill) -------------------------

pub const pw_thread_loop = opaque {};
pub const pw_loop = opaque {};
pub const pw_context = opaque {};
pub const pw_core = opaque {};
pub const pw_stream = opaque {};
pub const pw_properties = opaque {};
pub const spa_dict = opaque {};
pub const spa_pod_t = opaque {};

/// struct spa_list
pub const spa_list = extern struct {
    next: ?*spa_list = null,
    prev: ?*spa_list = null,
};

/// struct spa_callbacks
pub const spa_callbacks = extern struct {
    funcs: ?*const anyopaque = null,
    data: ?*anyopaque = null,
};

/// struct spa_hook: owned by the caller, linked into the stream's listener list.
pub const spa_hook = extern struct {
    link: spa_list = .{},
    cb: spa_callbacks = .{},
    removed: ?*const fn (hook: *spa_hook) callconv(.c) void = null,
    priv: ?*anyopaque = null,
};

/// struct spa_chunk
pub const spa_chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

/// struct spa_data
pub const spa_data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: *spa_chunk,
};

/// struct spa_buffer
pub const spa_buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
    datas: [*]spa_data,
};

/// struct pw_buffer (only the leading fields; PipeWire allocates it and may append more).
pub const pw_buffer = extern struct {
    buffer: *spa_buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

/// enum pw_stream_state
pub const PW_STREAM_STATE_ERROR: c_int = -1;

/// struct pw_stream_events, version PW_VERSION_STREAM_EVENTS (2).
pub const pw_stream_events = extern struct {
    version: u32,
    destroy: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (data: ?*anyopaque, old: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const fn (data: ?*anyopaque, id: u32, control: ?*const anyopaque) callconv(.c) void = null,
    io_changed: ?*const fn (data: ?*anyopaque, id: u32, area: ?*anyopaque, size: u32) callconv(.c) void = null,
    param_changed: ?*const fn (data: ?*anyopaque, id: u32, param: ?*const spa_pod_t) callconv(.c) void = null,
    add_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.c) void = null,
    remove_buffer: ?*const fn (data: ?*anyopaque, buffer: *pw_buffer) callconv(.c) void = null,
    process: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    drained: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
    command: ?*const fn (data: ?*anyopaque, command: ?*const anyopaque) callconv(.c) void = null,
    trigger_done: ?*const fn (data: ?*anyopaque) callconv(.c) void = null,
};
pub const PW_VERSION_STREAM_EVENTS: u32 = 2;

/// enum spa_direction
pub const SPA_DIRECTION_OUTPUT: c_int = 1;
/// PW_ID_ANY
pub const PW_ID_ANY: u32 = 0xffff_ffff;

/// enum pw_stream_flags
pub const PW_STREAM_FLAG_AUTOCONNECT: u32 = 1 << 0;
pub const PW_STREAM_FLAG_INACTIVE: u32 = 1 << 1;
pub const PW_STREAM_FLAG_MAP_BUFFERS: u32 = 1 << 2;
pub const PW_STREAM_FLAG_RT_PROCESS: u32 = 1 << 4;

/// pipewire/keys.h
pub const PW_KEY_MEDIA_TYPE = "media.type";
pub const PW_KEY_MEDIA_CATEGORY = "media.category";
pub const PW_KEY_MEDIA_ROLE = "media.role";
pub const PW_KEY_NODE_NAME = "node.name";
pub const PW_KEY_NODE_DESCRIPTION = "node.description";
pub const PW_KEY_APP_NAME = "application.name";
pub const PW_KEY_NODE_LATENCY = "node.latency";

extern fn pw_init(argc: ?*c_int, argv: ?*?[*]?[*:0]u8) void;
extern fn pw_deinit() void;
extern fn pw_thread_loop_new(name: [*:0]const u8, props: ?*const spa_dict) ?*pw_thread_loop;
extern fn pw_thread_loop_get_loop(loop: *pw_thread_loop) *pw_loop;
extern fn pw_thread_loop_start(loop: *pw_thread_loop) c_int;
extern fn pw_thread_loop_stop(loop: *pw_thread_loop) void;
extern fn pw_thread_loop_destroy(loop: *pw_thread_loop) void;
extern fn pw_thread_loop_lock(loop: *pw_thread_loop) void;
extern fn pw_thread_loop_unlock(loop: *pw_thread_loop) void;
extern fn pw_context_new(main_loop: *pw_loop, props: ?*pw_properties, user_data_size: usize) ?*pw_context;
extern fn pw_context_destroy(context: *pw_context) void;
extern fn pw_context_connect(context: *pw_context, props: ?*pw_properties, user_data_size: usize) ?*pw_core;
extern fn pw_core_disconnect(core: *pw_core) c_int;
extern fn pw_properties_new(key: ?[*:0]const u8, ...) ?*pw_properties;
extern fn pw_stream_new(core: *pw_core, name: [*:0]const u8, props: ?*pw_properties) ?*pw_stream;
extern fn pw_stream_destroy(stream: *pw_stream) void;
extern fn pw_stream_add_listener(stream: *pw_stream, listener: *spa_hook, events: *const pw_stream_events, data: ?*anyopaque) void;
extern fn pw_stream_connect(stream: *pw_stream, direction: c_int, target_id: u32, flags: u32, params: [*]const *const spa_pod_t, n_params: u32) c_int;
extern fn pw_stream_set_active(stream: *pw_stream, active: bool) c_int;
extern fn pw_stream_dequeue_buffer(stream: *pw_stream) ?*pw_buffer;
extern fn pw_stream_queue_buffer(stream: *pw_stream, buffer: *pw_buffer) c_int;

/// spa_hook_remove (static inline in spa/utils/hook.h): unlink if linked, then notify.
pub fn spaHookRemove(hook: *spa_hook) void {
    if (hook.link.prev != null) {
        // spa_list_remove
        const prev = hook.link.prev.?;
        const next = hook.link.next.?;
        prev.next = next;
        next.prev = prev;
    }
    if (hook.removed) |removed| removed(hook);
}

// ---- The stream --------------------------------------------------------------------------------

/// Fills `frames * channels` interleaved f32 samples at `out`. Called on the PipeWire data thread.
pub const RenderFn = *const fn (ctx: ?*anyopaque, out: [*]f32, frames: u32) void;

/// Most channels the stream accepts (SPA_AUDIO_MAX_CHANNELS).
pub const MAX_CHANNELS = spa_pod.AUDIO_MAX_CHANNELS;

pub const OpenError = error{
    InvalidParameters,
    OutOfMemory,
    ThreadLoopFailed,
    ContextFailed,
    NoServer,
    StreamFailed,
    FormatFailed,
    ConnectFailed,
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    loop: ?*pw_thread_loop = null,
    context: ?*pw_context = null,
    core: ?*pw_core = null,
    stream: ?*pw_stream = null,
    listener: spa_hook = .{},
    listening: bool = false,
    render: RenderFn,
    ctx: ?*anyopaque,
    channels: u32,

    const events: pw_stream_events = .{
        .version = PW_VERSION_STREAM_EVENTS,
        .state_changed = onStateChanged,
        .process = onProcess,
    };

    /// Connects to PipeWire and creates an inactive F32 interleaved playback node named
    /// `seridian-studio` with `node.latency` = quantum/rate. Fails with `NoServer` when no
    /// PipeWire server accepts the connection. The stream is heap-allocated (PipeWire keeps a
    /// pointer to it); free it with `close`.
    pub fn open(allocator: std.mem.Allocator, rate: u32, channels: u32, quantum: u32, render: RenderFn, ctx: ?*anyopaque) OpenError!*Stream {
        if (channels == 0 or channels > MAX_CHANNELS or rate == 0 or quantum == 0) return OpenError.InvalidParameters;

        pw_init(null, null);
        const self = allocator.create(Stream) catch {
            pw_deinit();
            return OpenError.OutOfMemory;
        };
        self.* = .{ .allocator = allocator, .render = render, .ctx = ctx, .channels = channels };
        errdefer self.close();

        self.loop = pw_thread_loop_new("seridian-pipewire", null) orelse return OpenError.ThreadLoopFailed;
        self.context = pw_context_new(pw_thread_loop_get_loop(self.loop.?), null, 0) orelse return OpenError.ContextFailed;
        if (pw_thread_loop_start(self.loop.?) < 0) return OpenError.ThreadLoopFailed;

        pw_thread_loop_lock(self.loop.?);
        defer pw_thread_loop_unlock(self.loop.?);

        self.core = pw_context_connect(self.context.?, null, 0) orelse return OpenError.NoServer;

        var latency_buf: [32]u8 = undefined;
        const latency = std.fmt.bufPrintSentinel(&latency_buf, "{d}/{d}", .{ quantum, rate }, 0) catch return OpenError.InvalidParameters;
        const props = pw_properties_new(
            PW_KEY_MEDIA_TYPE,
            @as([*:0]const u8, "Audio"),
            @as([*:0]const u8, PW_KEY_MEDIA_CATEGORY),
            @as([*:0]const u8, "Playback"),
            @as([*:0]const u8, PW_KEY_MEDIA_ROLE),
            @as([*:0]const u8, "Production"),
            @as([*:0]const u8, PW_KEY_NODE_NAME),
            @as([*:0]const u8, "seridian-studio"),
            @as([*:0]const u8, PW_KEY_NODE_DESCRIPTION),
            @as([*:0]const u8, "Seridian Studio"),
            @as([*:0]const u8, PW_KEY_APP_NAME),
            @as([*:0]const u8, "Seridian Studio"),
            @as([*:0]const u8, PW_KEY_NODE_LATENCY),
            @as([*:0]const u8, latency.ptr),
            @as(?[*:0]const u8, null),
        );
        // pw_stream_new takes ownership of props, also on failure.
        self.stream = pw_stream_new(self.core.?, "Seridian Studio Output", props) orelse return OpenError.StreamFailed;
        pw_stream_add_listener(self.stream.?, &self.listener, &events, self);
        self.listening = true;

        var pod_buf: [1024]u8 align(8) = undefined;
        const pod = spa_pod.buildAudioRawFormat(&pod_buf, spa_pod.PARAM_ENUM_FORMAT, .{
            .format = spa_pod.AUDIO_FORMAT_F32,
            .rate = rate,
            .channels = channels,
            .positions = spa_pod.defaultPositions(channels),
        }) catch return OpenError.FormatFailed;
        const params = [_]*const spa_pod_t{@ptrCast(pod.ptr)};

        const res = pw_stream_connect(
            self.stream.?,
            SPA_DIRECTION_OUTPUT,
            PW_ID_ANY,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE,
            &params,
            params.len,
        );
        if (res < 0) {
            log.warn("pw_stream_connect failed ({d})", .{res});
            return OpenError.ConnectFailed;
        }
        return self;
    }

    /// Starts (true) or pauses (false) the stream. Returns 0 or a negative errno.
    pub fn setActive(self: *Stream, active: bool) c_int {
        const loop = self.loop orelse return -1;
        const stream = self.stream orelse return -1;
        pw_thread_loop_lock(loop);
        defer pw_thread_loop_unlock(loop);
        return pw_stream_set_active(stream, active);
    }

    /// Disconnects and frees everything `open` created, including the Stream itself.
    pub fn close(self: *Stream) void {
        if (self.loop) |loop| pw_thread_loop_stop(loop);
        if (self.stream) |stream| {
            if (self.listening) spaHookRemove(&self.listener);
            pw_stream_destroy(stream);
        }
        if (self.core) |core| {
            const res = pw_core_disconnect(core);
            if (res < 0) log.warn("pw_core_disconnect failed ({d})", .{res});
        }
        if (self.context) |context| pw_context_destroy(context);
        if (self.loop) |loop| pw_thread_loop_destroy(loop);
        self.allocator.destroy(self);
        pw_deinit();
    }

    /// Real-time data thread: fill one buffer. No allocation, locks or logging.
    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(data orelse return));
        const stream = self.stream orelse return;
        const b = pw_stream_dequeue_buffer(stream) orelse return;
        const d = &b.buffer.datas[0];
        const samples = d.data orelse {
            _ = pw_stream_queue_buffer(stream, b);
            return;
        };
        const stride: u32 = @sizeOf(f32) * self.channels;
        var frames: u32 = d.maxsize / stride;
        if (b.requested != 0 and b.requested < frames) frames = @intCast(b.requested);

        self.render(self.ctx, @ptrCast(@alignCast(samples)), frames);

        d.chunk.offset = 0;
        d.chunk.stride = @intCast(stride);
        d.chunk.size = frames * stride;
        _ = pw_stream_queue_buffer(stream, b);
    }

    /// Main-loop thread.
    fn onStateChanged(data: ?*anyopaque, old: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void {
        _ = data;
        _ = old;
        if (state == PW_STREAM_STATE_ERROR) {
            log.err("stream error: {s}", .{if (err) |e| std.mem.span(e) else "unknown"});
        }
    }
};

// ---- Tests -------------------------------------------------------------------------------------

test "pw_stream: struct layouts match the PipeWire 1.x headers" {
    // Sizes and offsets printed by a C program compiled against pipewire-0.3 1.6.9 (x86_64).
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(spa_hook));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(pw_buffer));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(pw_buffer, "requested"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(spa_data));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(spa_data, "maxsize"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(spa_data, "data"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(spa_data, "chunk"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(spa_buffer));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(spa_chunk));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(pw_stream_events));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(pw_stream_events, "state_changed"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(pw_stream_events, "process"));
}

test "pw_stream: spaHookRemove unlinks the hook and calls removed" {
    const Probe = struct {
        var removed_calls: usize = 0;
        fn removed(_: *spa_hook) callconv(.c) void {
            removed_calls += 1;
        }
    };
    var head: spa_list = .{};
    var hook: spa_hook = .{ .removed = Probe.removed };
    // A two-element ring: head <-> hook.link.
    head.next = &hook.link;
    head.prev = &hook.link;
    hook.link.next = &head;
    hook.link.prev = &head;
    spaHookRemove(&hook);
    try std.testing.expectEqual(@as(?*spa_list, &head), head.next);
    try std.testing.expectEqual(@as(?*spa_list, &head), head.prev);
    try std.testing.expectEqual(@as(usize, 1), Probe.removed_calls);

    // A hook that was never linked is only notified.
    var lone: spa_hook = .{ .removed = Probe.removed };
    spaHookRemove(&lone);
    try std.testing.expectEqual(@as(usize, 2), Probe.removed_calls);
}

test "pw_stream: open rejects invalid parameters before touching PipeWire" {
    const Render = struct {
        fn render(_: ?*anyopaque, _: [*]f32, _: u32) void {}
    };
    try std.testing.expectError(OpenError.InvalidParameters, Stream.open(std.testing.allocator, 48000, 0, 128, Render.render, null));
    try std.testing.expectError(OpenError.InvalidParameters, Stream.open(std.testing.allocator, 48000, MAX_CHANNELS + 1, 128, Render.render, null));
    try std.testing.expectError(OpenError.InvalidParameters, Stream.open(std.testing.allocator, 0, 2, 128, Render.render, null));
}
