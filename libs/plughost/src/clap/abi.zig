// Translated to Zig from soundcraft/crates/clap-host/src/ffi.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The CLAP 1.2 C ABI used by the host, as hand-written `extern struct`s and
//! constants (Zig 0.18 has no `@cImport`).
//!
//! The layouts are the ones the Rust crate gets from `clap-sys` 0.5, in the same
//! field order. Comptime asserts pin the sizes and offsets of the event structs
//! and the extension structs that have layout-sensitive fields. They check this
//! file against the layout we intend, not against a C compiler: confirm against
//! the CLAP headers when the toolchain can build them.
//!
//! Every function pointer is optional (`?*const fn ... callconv(.c)`). A null
//! entry means "not implemented", and the caller checks before calling it.
//! Pointers and strings returned by a plugin are hostile: read strings with
//! `readCStr` (bounded) and clamp every count against the caps below.

const std = @import("std");

// ---- ids, sizes and caps -------------------------------------------------------------------

pub const ClapId = u32;
pub const CLAP_INVALID_ID: ClapId = std.math.maxInt(u32);
pub const CLAP_NAME_SIZE = 256;
pub const CLAP_PATH_SIZE = 1024;

/// Most plugins one factory may report (hostile-input cap).
pub const MAX_PLUGINS_PER_FACTORY: u32 = 1024;
/// Most parameters read from one plugin.
pub const MAX_PARAMS: u32 = 4096;
/// Most audio ports per direction we provide buffers for.
pub const MAX_PORTS: u32 = 16;
/// Most channels per audio port.
pub const MAX_PORT_CHANNELS: u32 = 64;
/// Most feature strings read from a descriptor.
pub const MAX_FEATURES: usize = 64;
/// Capacity of the per-block event list (preallocated: `process` never allocates).
pub const EVENT_CAP: usize = 1024;
/// Largest plugin state accepted from `clap_plugin_state.save` (hostile-input cap).
pub const MAX_STATE_BYTES: usize = 64 << 20;
/// Most editor parameter edits buffered between two UI frames.
pub const EDIT_CAP: usize = 256;
/// Seridian: longest plugin string read, in bytes before the NUL. A longer string
/// (or one without a NUL inside the cap) reads as absent.
pub const MAX_STRING_LEN: usize = 4096;

/// Reads a NUL-terminated plugin string of at most `MAX_STRING_LEN` bytes. Null,
/// or no NUL within the cap, gives null. The bytes are not checked for UTF-8.
pub fn readCStr(p: ?[*:0]const u8) ?[]const u8 {
    const s = p orelse return null;
    const bytes: [*]const u8 = @ptrCast(s);
    var i: usize = 0;
    while (i < MAX_STRING_LEN) : (i += 1) {
        if (bytes[i] == 0) return bytes[0..i];
    }
    return null;
}

/// Reads a fixed-size `char[N]` name, stopping at the first NUL or the end of the
/// array (`read_name` in ffi.rs).
pub fn readName(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

// ---- factory and entry ids -------------------------------------------------------------------

pub const CLAP_PLUGIN_FACTORY_ID: [:0]const u8 = "clap.plugin-factory";
pub const CLAP_EXT_PARAMS: [:0]const u8 = "clap.params";
pub const CLAP_EXT_STATE: [:0]const u8 = "clap.state";
pub const CLAP_EXT_GUI: [:0]const u8 = "clap.gui";
pub const CLAP_EXT_LATENCY: [:0]const u8 = "clap.latency";
pub const CLAP_EXT_TAIL: [:0]const u8 = "clap.tail";
pub const CLAP_EXT_AUDIO_PORTS: [:0]const u8 = "clap.audio-ports";
pub const CLAP_EXT_NOTE_PORTS: [:0]const u8 = "clap.note-ports";
pub const CLAP_EXT_THREAD_CHECK: [:0]const u8 = "clap.thread-check";
pub const CLAP_EXT_LOG: [:0]const u8 = "clap.log";

// ---- version -----------------------------------------------------------------------------------

pub const ClapVersion = extern struct {
    major: u32,
    minor: u32,
    revision: u32,
};

/// The CLAP version this host is built against.
pub const CLAP_VERSION: ClapVersion = .{ .major = 1, .minor = 2, .revision = 4 };

/// CLAP's compatibility rule: any 1.x plugin is accepted.
pub fn clapVersionIsCompatible(v: ClapVersion) bool {
    return v.major >= 1;
}

// ---- entry, factory, descriptor ------------------------------------------------------------

pub const ClapPluginEntry = extern struct {
    clap_version: ClapVersion,
    init: ?*const fn (plugin_path: [*:0]const u8) callconv(.c) bool,
    deinit: ?*const fn () callconv(.c) void,
    get_factory: ?*const fn (factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque,
};

pub const ClapPluginDescriptor = extern struct {
    clap_version: ClapVersion,
    id: ?[*:0]const u8,
    name: ?[*:0]const u8,
    vendor: ?[*:0]const u8,
    url: ?[*:0]const u8,
    manual_url: ?[*:0]const u8,
    support_url: ?[*:0]const u8,
    version: ?[*:0]const u8,
    description: ?[*:0]const u8,
    /// NULL-terminated array of NUL-terminated feature strings.
    features: ?[*]const ?[*:0]const u8,
};

pub const ClapPluginFactory = extern struct {
    get_plugin_count: ?*const fn (factory: *const ClapPluginFactory) callconv(.c) u32,
    get_plugin_descriptor: ?*const fn (factory: *const ClapPluginFactory, index: u32) callconv(.c) ?*const ClapPluginDescriptor,
    create_plugin: ?*const fn (factory: *const ClapPluginFactory, host: *const ClapHost, plugin_id: [*:0]const u8) callconv(.c) ?*const ClapPlugin,
};

// ---- host and plugin ---------------------------------------------------------------------------

pub const ClapHost = extern struct {
    clap_version: ClapVersion,
    host_data: ?*anyopaque,
    name: ?[*:0]const u8,
    vendor: ?[*:0]const u8,
    url: ?[*:0]const u8,
    version: ?[*:0]const u8,
    get_extension: ?*const fn (host: *const ClapHost, extension_id: [*:0]const u8) callconv(.c) ?*const anyopaque,
    request_restart: ?*const fn (host: *const ClapHost) callconv(.c) void,
    request_process: ?*const fn (host: *const ClapHost) callconv(.c) void,
    request_callback: ?*const fn (host: *const ClapHost) callconv(.c) void,
};

/// `clap_process_status`.
pub const ClapProcessStatus = i32;
pub const CLAP_PROCESS_ERROR: ClapProcessStatus = 0;
pub const CLAP_PROCESS_CONTINUE: ClapProcessStatus = 1;
pub const CLAP_PROCESS_CONTINUE_IF_NOT_QUIET: ClapProcessStatus = 2;
pub const CLAP_PROCESS_TAIL: ClapProcessStatus = 3;
pub const CLAP_PROCESS_SLEEP: ClapProcessStatus = 4;

pub const ClapPlugin = extern struct {
    desc: ?*const ClapPluginDescriptor,
    plugin_data: ?*anyopaque,
    init: ?*const fn (plugin: *const ClapPlugin) callconv(.c) bool,
    destroy: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
    activate: ?*const fn (plugin: *const ClapPlugin, sample_rate: f64, min_frames_count: u32, max_frames_count: u32) callconv(.c) bool,
    deactivate: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
    start_processing: ?*const fn (plugin: *const ClapPlugin) callconv(.c) bool,
    stop_processing: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
    reset: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
    process: ?*const fn (plugin: *const ClapPlugin, process: *const ClapProcess) callconv(.c) ClapProcessStatus,
    get_extension: ?*const fn (plugin: *const ClapPlugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque,
    on_main_thread: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
};

/// One planar audio buffer. `data32` (or `data64`) points at `channel_count` channel pointers.
pub const ClapAudioBuffer = extern struct {
    data32: ?[*]?[*]f32,
    data64: ?[*]?[*]f64,
    channel_count: u32,
    latency: u32,
    constant_mask: u64,
};

pub const ClapProcess = extern struct {
    steady_time: i64,
    frames_count: u32,
    transport: ?*const ClapEventTransport,
    audio_inputs: ?[*]const ClapAudioBuffer,
    audio_outputs: ?[*]ClapAudioBuffer,
    audio_inputs_count: u32,
    audio_outputs_count: u32,
    in_events: ?*const ClapInputEvents,
    out_events: ?*const ClapOutputEvents,
};

// ---- events ----------------------------------------------------------------------------------

pub const CLAP_CORE_EVENT_SPACE_ID: u16 = 0;

pub const CLAP_EVENT_NOTE_ON: u16 = 0;
pub const CLAP_EVENT_NOTE_OFF: u16 = 1;
pub const CLAP_EVENT_NOTE_CHOKE: u16 = 2;
pub const CLAP_EVENT_NOTE_END: u16 = 3;
pub const CLAP_EVENT_NOTE_EXPRESSION: u16 = 4;
pub const CLAP_EVENT_PARAM_VALUE: u16 = 5;
pub const CLAP_EVENT_PARAM_MOD: u16 = 6;
pub const CLAP_EVENT_PARAM_GESTURE_BEGIN: u16 = 7;
pub const CLAP_EVENT_PARAM_GESTURE_END: u16 = 8;
pub const CLAP_EVENT_TRANSPORT: u16 = 9;
pub const CLAP_EVENT_MIDI: u16 = 10;
pub const CLAP_EVENT_MIDI_SYSEX: u16 = 11;
pub const CLAP_EVENT_MIDI2: u16 = 12;

/// Fixed-point scales for transport positions (`clap_beattime`, `clap_sectime`).
pub const CLAP_BEATTIME_FACTOR: i64 = 1 << 31;
pub const CLAP_SECTIME_FACTOR: i64 = 1 << 31;

pub const CLAP_TRANSPORT_HAS_TEMPO: u32 = 1 << 0;
pub const CLAP_TRANSPORT_HAS_BEATS_TIMELINE: u32 = 1 << 1;
pub const CLAP_TRANSPORT_HAS_SECONDS_TIMELINE: u32 = 1 << 2;
pub const CLAP_TRANSPORT_HAS_TIME_SIGNATURE: u32 = 1 << 3;
pub const CLAP_TRANSPORT_IS_PLAYING: u32 = 1 << 4;
pub const CLAP_TRANSPORT_IS_RECORDING: u32 = 1 << 5;
pub const CLAP_TRANSPORT_IS_LOOP_ACTIVE: u32 = 1 << 6;
pub const CLAP_TRANSPORT_IS_WITHIN_PRE_ROLL: u32 = 1 << 7;

pub const ClapEventHeader = extern struct {
    size: u32,
    time: u32,
    space_id: u16,
    type_: u16,
    flags: u32,
};

pub const ClapEventNote = extern struct {
    header: ClapEventHeader,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    velocity: f64,
};

pub const ClapEventParamValue = extern struct {
    header: ClapEventHeader,
    param_id: ClapId,
    cookie: ?*anyopaque,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    value: f64,
};

pub const ClapEventMidi = extern struct {
    header: ClapEventHeader,
    port_index: u16,
    data: [3]u8,
};

pub const ClapEventTransport = extern struct {
    header: ClapEventHeader,
    flags: u32,
    song_pos_beats: i64,
    song_pos_seconds: i64,
    tempo: f64,
    tempo_inc: f64,
    loop_start_beats: i64,
    loop_end_beats: i64,
    loop_start_seconds: i64,
    loop_end_seconds: i64,
    bar_start: i64,
    bar_number: i32,
    tsig_num: u16,
    tsig_denom: u16,
};

pub const ClapInputEvents = extern struct {
    ctx: ?*anyopaque,
    size: ?*const fn (list: *const ClapInputEvents) callconv(.c) u32,
    get: ?*const fn (list: *const ClapInputEvents, index: u32) callconv(.c) ?*const ClapEventHeader,
};

pub const ClapOutputEvents = extern struct {
    ctx: ?*anyopaque,
    try_push: ?*const fn (list: *const ClapOutputEvents, event: ?*const ClapEventHeader) callconv(.c) bool,
};

// ---- streams ---------------------------------------------------------------------------------

pub const ClapIStream = extern struct {
    ctx: ?*anyopaque,
    read: ?*const fn (stream: *const ClapIStream, buffer: ?*anyopaque, size: u64) callconv(.c) i64,
};

pub const ClapOStream = extern struct {
    ctx: ?*anyopaque,
    write: ?*const fn (stream: *const ClapOStream, buffer: ?*const anyopaque, size: u64) callconv(.c) i64,
};

// ---- extensions: params ----------------------------------------------------------------------

pub const CLAP_PARAM_IS_STEPPED: u32 = 1 << 0;
pub const CLAP_PARAM_IS_PERIODIC: u32 = 1 << 1;
pub const CLAP_PARAM_IS_HIDDEN: u32 = 1 << 2;
pub const CLAP_PARAM_IS_READONLY: u32 = 1 << 3;
pub const CLAP_PARAM_IS_BYPASS: u32 = 1 << 4;
pub const CLAP_PARAM_IS_AUTOMATABLE: u32 = 1 << 5;
pub const CLAP_PARAM_IS_MODULATABLE: u32 = 1 << 10;
pub const CLAP_PARAM_REQUIRES_PROCESS: u32 = 1 << 15;

/// Flags for `clap_host_params.rescan` (CLAP 1.2 `clap_param_rescan_flags`).
pub const CLAP_PARAM_RESCAN_ALL: u32 = 1 << 0;
pub const CLAP_PARAM_RESCAN_VALUES: u32 = 1 << 1;
pub const CLAP_PARAM_RESCAN_TEXT: u32 = 1 << 2;
pub const CLAP_PARAM_RESCAN_INFO: u32 = 1 << 3;

/// Flags for `clap_host_params.clear` (CLAP 1.2 `clap_param_clear_flags`).
pub const CLAP_PARAM_CLEAR_ALL: u32 = 1 << 0;
pub const CLAP_PARAM_CLEAR_AUTOMATIONS: u32 = 1 << 1;
pub const CLAP_PARAM_CLEAR_MODULATIONS: u32 = 1 << 2;

pub const ClapParamInfo = extern struct {
    id: ClapId,
    flags: u32,
    cookie: ?*anyopaque,
    name: [CLAP_NAME_SIZE]u8,
    module: [CLAP_PATH_SIZE]u8,
    min_value: f64,
    max_value: f64,
    default_value: f64,
};

pub const ClapPluginParams = extern struct {
    count: ?*const fn (plugin: *const ClapPlugin) callconv(.c) u32,
    get_info: ?*const fn (plugin: *const ClapPlugin, param_index: u32, param_info: *ClapParamInfo) callconv(.c) bool,
    get_value: ?*const fn (plugin: *const ClapPlugin, param_id: ClapId, out_value: *f64) callconv(.c) bool,
    value_to_text: ?*const fn (plugin: *const ClapPlugin, param_id: ClapId, value: f64, out_buffer: [*]u8, out_buffer_capacity: u32) callconv(.c) bool,
    text_to_value: ?*const fn (plugin: *const ClapPlugin, param_id: ClapId, param_value_text: [*:0]const u8, out_value: *f64) callconv(.c) bool,
    flush: ?*const fn (plugin: *const ClapPlugin, in: *const ClapInputEvents, out: *const ClapOutputEvents) callconv(.c) void,
};

pub const ClapHostParams = extern struct {
    rescan: ?*const fn (host: *const ClapHost, flags: u32) callconv(.c) void,
    clear: ?*const fn (host: *const ClapHost, param_id: ClapId, flags: u32) callconv(.c) void,
    request_flush: ?*const fn (host: *const ClapHost) callconv(.c) void,
};

// ---- extensions: state, latency, tail, thread check, log ------------------------------------

pub const ClapPluginState = extern struct {
    save: ?*const fn (plugin: *const ClapPlugin, stream: *const ClapOStream) callconv(.c) bool,
    load: ?*const fn (plugin: *const ClapPlugin, stream: *const ClapIStream) callconv(.c) bool,
};

pub const ClapHostState = extern struct {
    mark_dirty: ?*const fn (host: *const ClapHost) callconv(.c) void,
};

pub const ClapPluginLatency = extern struct {
    get: ?*const fn (plugin: *const ClapPlugin) callconv(.c) u32,
};

pub const ClapHostLatency = extern struct {
    changed: ?*const fn (host: *const ClapHost) callconv(.c) void,
};

pub const ClapPluginTail = extern struct {
    get: ?*const fn (plugin: *const ClapPlugin) callconv(.c) u32,
};

pub const ClapHostTail = extern struct {
    changed: ?*const fn (host: *const ClapHost) callconv(.c) void,
};

pub const ClapHostThreadCheck = extern struct {
    is_main_thread: ?*const fn (host: *const ClapHost) callconv(.c) bool,
    is_audio_thread: ?*const fn (host: *const ClapHost) callconv(.c) bool,
};

pub const CLAP_LOG_DEBUG: i32 = 0;
pub const CLAP_LOG_INFO: i32 = 1;
pub const CLAP_LOG_WARNING: i32 = 2;
pub const CLAP_LOG_ERROR: i32 = 3;
pub const CLAP_LOG_FATAL: i32 = 4;
pub const CLAP_LOG_HOST_MISBEHAVING: i32 = 5;
pub const CLAP_LOG_PLUGIN_MISBEHAVING: i32 = 6;

pub const ClapHostLog = extern struct {
    log: ?*const fn (host: *const ClapHost, severity: i32, msg: [*:0]const u8) callconv(.c) void,
};

// ---- extensions: audio and note ports ----------------------------------------------------------

pub const CLAP_AUDIO_PORT_IS_MAIN: u32 = 1 << 0;
pub const CLAP_AUDIO_PORT_SUPPORTS_64BITS: u32 = 1 << 1;
pub const CLAP_AUDIO_PORT_PREFERS_64BITS: u32 = 1 << 2;
pub const CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE: u32 = 1 << 3;

pub const ClapAudioPortInfo = extern struct {
    id: ClapId,
    name: [CLAP_NAME_SIZE]u8,
    flags: u32,
    channel_count: u32,
    port_type: ?[*:0]const u8,
    in_place_pair: ClapId,
};

pub const ClapPluginAudioPorts = extern struct {
    count: ?*const fn (plugin: *const ClapPlugin, is_input: bool) callconv(.c) u32,
    get: ?*const fn (plugin: *const ClapPlugin, index: u32, is_input: bool, info: *ClapAudioPortInfo) callconv(.c) bool,
};

pub const CLAP_NOTE_DIALECT_CLAP: u32 = 1 << 0;
pub const CLAP_NOTE_DIALECT_MIDI_MPE: u32 = 1 << 1;
pub const CLAP_NOTE_DIALECT_MIDI2: u32 = 1 << 2;
pub const CLAP_NOTE_DIALECT_MIDI: u32 = 1 << 3;

pub const ClapNotePortInfo = extern struct {
    id: ClapId,
    supported_dialects: u32,
    preferred_dialect: u32,
    name: [CLAP_NAME_SIZE]u8,
};

pub const ClapPluginNotePorts = extern struct {
    count: ?*const fn (plugin: *const ClapPlugin, is_input: bool) callconv(.c) u32,
    get: ?*const fn (plugin: *const ClapPlugin, index: u32, is_input: bool, info: *ClapNotePortInfo) callconv(.c) bool,
};

// ---- extensions: gui ----------------------------------------------------------------------------

/// `clap_window_handle`: a platform view or window, depending on the API string.
pub const ClapWindowHandle = extern union {
    cocoa: ?*anyopaque,
    x11: c_ulong,
    win32: ?*anyopaque,
    ptr: usize,
};

pub const ClapWindow = extern struct {
    api: ?[*:0]const u8,
    handle: ClapWindowHandle,
};

pub const ClapGuiResizeHints = extern struct {
    can_resize_horizontally: bool,
    can_resize_vertically: bool,
    preserve_aspect_ratio: bool,
    aspect_ratio_width: u32,
    aspect_ratio_height: u32,
};

pub const ClapPluginGui = extern struct {
    is_api_supported: ?*const fn (plugin: *const ClapPlugin, api: [*:0]const u8, is_floating: bool) callconv(.c) bool,
    get_preferred_api: ?*const fn (plugin: *const ClapPlugin, api: *?[*:0]const u8, is_floating: *bool) callconv(.c) bool,
    create: ?*const fn (plugin: *const ClapPlugin, api: [*:0]const u8, is_floating: bool) callconv(.c) bool,
    destroy: ?*const fn (plugin: *const ClapPlugin) callconv(.c) void,
    set_scale: ?*const fn (plugin: *const ClapPlugin, scale: f64) callconv(.c) bool,
    get_size: ?*const fn (plugin: *const ClapPlugin, width: *u32, height: *u32) callconv(.c) bool,
    can_resize: ?*const fn (plugin: *const ClapPlugin) callconv(.c) bool,
    get_resize_hints: ?*const fn (plugin: *const ClapPlugin, hints: *ClapGuiResizeHints) callconv(.c) bool,
    adjust_size: ?*const fn (plugin: *const ClapPlugin, width: *u32, height: *u32) callconv(.c) bool,
    set_size: ?*const fn (plugin: *const ClapPlugin, width: u32, height: u32) callconv(.c) bool,
    set_parent: ?*const fn (plugin: *const ClapPlugin, window: *const ClapWindow) callconv(.c) bool,
    set_transient: ?*const fn (plugin: *const ClapPlugin, window: *const ClapWindow) callconv(.c) bool,
    suggest_title: ?*const fn (plugin: *const ClapPlugin, title: [*:0]const u8) callconv(.c) void,
    show: ?*const fn (plugin: *const ClapPlugin) callconv(.c) bool,
    hide: ?*const fn (plugin: *const ClapPlugin) callconv(.c) bool,
};

pub const ClapHostGui = extern struct {
    resize_hints_changed: ?*const fn (host: *const ClapHost) callconv(.c) void,
    request_resize: ?*const fn (host: *const ClapHost, width: u32, height: u32) callconv(.c) bool,
    request_show: ?*const fn (host: *const ClapHost) callconv(.c) bool,
    request_hide: ?*const fn (host: *const ClapHost) callconv(.c) bool,
    closed: ?*const fn (host: *const ClapHost, was_destroyed: bool) callconv(.c) void,
};

// ---- layout asserts -----------------------------------------------------------------------------
// Sizes and offsets of the event structs and the layout-sensitive extension structs. A failure
// here means a field was reordered or retyped, which would corrupt every call across the boundary.

comptime {
    if (@sizeOf(ClapVersion) != 12) @compileError("clap_version must be 12 bytes");
    if (@sizeOf(ClapEventHeader) != 16) @compileError("clap_event_header must be 16 bytes");
    if (@sizeOf(ClapEventNote) != 40 or @offsetOf(ClapEventNote, "velocity") != 32)
        @compileError("clap_event_note layout");
    if (@sizeOf(ClapEventParamValue) != 56 or @offsetOf(ClapEventParamValue, "cookie") != 24 or @offsetOf(ClapEventParamValue, "value") != 48)
        @compileError("clap_event_param_value layout");
    if (@sizeOf(ClapEventMidi) != 24 or @offsetOf(ClapEventMidi, "data") != 18)
        @compileError("clap_event_midi layout");
    if (@sizeOf(ClapEventTransport) != 104 or @offsetOf(ClapEventTransport, "song_pos_beats") != 24 or @offsetOf(ClapEventTransport, "bar_start") != 88)
        @compileError("clap_event_transport layout");
    if (@sizeOf(ClapAudioBuffer) != 32 or @offsetOf(ClapAudioBuffer, "constant_mask") != 24)
        @compileError("clap_audio_buffer layout");
    if (@sizeOf(ClapParamInfo) != 1320 or @offsetOf(ClapParamInfo, "min_value") != 1296)
        @compileError("clap_param_info layout");
    if (@sizeOf(ClapAudioPortInfo) != 288 or @offsetOf(ClapAudioPortInfo, "port_type") != 272)
        @compileError("clap_audio_port_info layout");
    if (@sizeOf(ClapNotePortInfo) != 268)
        @compileError("clap_note_port_info layout");
    if (@sizeOf(ClapHost) != 88 or @offsetOf(ClapHost, "host_data") != 16)
        @compileError("clap_host layout");
    if (@sizeOf(ClapPluginDescriptor) != 88 or @offsetOf(ClapPluginDescriptor, "features") != 80)
        @compileError("clap_plugin_descriptor layout");
    if (@sizeOf(ClapPluginEntry) != 40 or @offsetOf(ClapPluginEntry, "init") != 16)
        @compileError("clap_plugin_entry layout");
    if (@sizeOf(ClapProcess) != 64 or @offsetOf(ClapProcess, "in_events") != 48)
        @compileError("clap_process layout");
}

test "ABI sizes match the CLAP 1.2 layouts the host relies on" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ClapEventHeader));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ClapEventNote));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ClapEventParamValue));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ClapEventMidi));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(ClapEventTransport));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ClapAudioBuffer));
    try std.testing.expectEqual(@as(usize, 1320), @sizeOf(ClapParamInfo));
    try std.testing.expectEqual(@as(usize, 288), @sizeOf(ClapAudioPortInfo));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(ClapHost));
}

test "readCStr is bounded and treats null as absent" {
    try std.testing.expect(readCStr(null) == null);
    const s: [*:0]const u8 = "SoundCraft";
    try std.testing.expectEqualStrings("SoundCraft", readCStr(s).?);

    // No NUL inside the cap: the string is absent, not read past the cap.
    var big: [MAX_STRING_LEN + 8]u8 = @splat('a');
    const unterminated: [*:0]const u8 = @ptrCast(&big);
    try std.testing.expect(readCStr(unterminated) == null);

    // A NUL just inside the cap is accepted.
    var edge: [MAX_STRING_LEN + 1]u8 = @splat('b');
    edge[MAX_STRING_LEN - 1] = 0;
    const edge_ptr: [*:0]const u8 = @ptrCast(&edge);
    try std.testing.expectEqual(MAX_STRING_LEN - 1, readCStr(edge_ptr).?.len);
}

test "readName stops at the first NUL or at the end of the array" {
    var buf: [CLAP_NAME_SIZE]u8 = @splat(0);
    @memcpy(buf[0..4], "Gain");
    try std.testing.expectEqualStrings("Gain", readName(&buf));
    const full: [4]u8 = .{ 'a', 'b', 'c', 'd' };
    try std.testing.expectEqualStrings("abcd", readName(&full));
}

test "clapVersionIsCompatible accepts 1.x and rejects 0.x" {
    try std.testing.expect(clapVersionIsCompatible(CLAP_VERSION));
    try std.testing.expect(clapVersionIsCompatible(.{ .major = 1, .minor = 0, .revision = 0 }));
    try std.testing.expect(!clapVersionIsCompatible(.{ .major = 0, .minor = 9, .revision = 0 }));
}
