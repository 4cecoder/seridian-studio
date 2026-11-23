// Translated to Zig from soundcraft/crates/au-host/src/ffi.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! AudioToolbox / CoreFoundation ABI for the AUv2 host: hand-written struct layouts, constants,
//! the four host transport callbacks (backed by an atomic `HostTime` snapshot so the audio thread
//! reads the transport without locks), and component enumeration.
//!
//! Covers lines 1-460 of ffi.rs. The layout types and `HostTime` compile on every OS; the
//! extern-backed functions (`components`, `cfString`, `release`) only do work on macOS and are
//! inert elsewhere. The build must link AudioToolbox and CoreFoundation for plughost on macOS.

const std = @import("std");
const builtin = @import("builtin");
const Transport = @import("../plugin.zig").Transport;

pub const is_macos = builtin.os.tag == .macos;

pub const OSStatus = i32;
pub const AudioComponent = ?*anyopaque;
pub const AudioUnit = ?*anyopaque;
pub const CFTypeRef = ?*const anyopaque;
pub const CFIndex = isize;

/// Most channels on one Audio Unit bus that we set up.
pub const max_au_channels: usize = 8;
/// Largest render slice we configure.
pub const max_slice: usize = 8192;
/// Most parameters read from one unit.
pub const max_params: usize = 4096;
/// Most components listed for one type.
pub const max_components: usize = 4096;
/// Most value strings read for one indexed parameter.
pub const max_value_strings: CFIndex = 256;
/// Largest state blob accepted or produced.
pub const max_state: usize = 64 << 20;
/// Longest CFString converted (bytes).
pub const max_string: CFIndex = 4096;

pub const component_flag_requires_async: u32 = 8;

pub const prop_class_info: u32 = 0;
pub const prop_parameter_list: u32 = 3;
pub const prop_parameter_info: u32 = 4;
pub const prop_stream_format: u32 = 8;
pub const prop_latency: u32 = 12;
pub const prop_max_frames: u32 = 14;
pub const prop_parameter_value_strings: u32 = 16;
pub const prop_tail_time: u32 = 20;
pub const prop_set_render_callback: u32 = 23;
pub const prop_host_callbacks: u32 = 27;

pub const scope_global: u32 = 0;
pub const scope_input: u32 = 1;
pub const scope_output: u32 = 2;

pub const format_linear_pcm: u32 = std.mem.readInt(u32, "lpcm", .big);
pub const format_flag_float: u32 = 1;
pub const format_flag_packed: u32 = 1 << 3;
pub const format_flag_non_interleaved: u32 = 1 << 5;

pub const timestamp_sample_time_valid: u32 = 1;

pub const cf_string_encoding_utf8: u32 = 0x0800_0100;
pub const cf_property_list_binary_format: CFIndex = 200;

pub const param_flag_cf_name_release: u32 = 1 << 4;
pub const param_flag_has_cf_name: u32 = 1 << 27;
pub const param_flag_display_log: u32 = 1 << 22;
pub const param_flag_readable: u32 = 1 << 30;
pub const param_flag_writable: u32 = 1 << 31;
pub const param_flag_meter_read_only: u32 = 1 << 15;

pub const unit_indexed: u32 = 1;
pub const unit_custom: u32 = 26;

pub const AudioComponentDescription = extern struct {
    component_type: u32 = 0,
    component_sub_type: u32 = 0,
    component_manufacturer: u32 = 0,
    component_flags: u32 = 0,
    component_flags_mask: u32 = 0,
};

pub const AudioStreamBasicDescription = extern struct {
    sample_rate: f64 = 0,
    format_id: u32 = 0,
    format_flags: u32 = 0,
    bytes_per_packet: u32 = 0,
    frames_per_packet: u32 = 0,
    bytes_per_frame: u32 = 0,
    channels_per_frame: u32 = 0,
    bits_per_channel: u32 = 0,
    reserved: u32 = 0,
};

pub const SmpteTime = extern struct {
    subframes: i16 = 0,
    subframe_divisor: i16 = 0,
    counter: u32 = 0,
    smpte_type: u32 = 0,
    flags: u32 = 0,
    hours: i16 = 0,
    minutes: i16 = 0,
    seconds: i16 = 0,
    frames: i16 = 0,
};

pub const AudioTimeStamp = extern struct {
    sample_time: f64 = 0,
    host_time: u64 = 0,
    rate_scalar: f64 = 0,
    word_clock_time: u64 = 0,
    smpte_time: SmpteTime = .{},
    flags: u32 = 0,
    reserved: u32 = 0,
};

pub const AudioBuffer = extern struct {
    number_channels: u32,
    data_byte_size: u32,
    data: ?*anyopaque,
};

/// `AudioBufferList` with room for `max_au_channels` buffers (the unit reads only
/// `number_buffers` of them).
pub const AudioBufferList = extern struct {
    number_buffers: u32,
    buffers: [max_au_channels]AudioBuffer,
};

/// The variable-length list the unit hands the render callback (we only see its header and
/// index into the buffers it says it has).
pub const AudioBufferListHeader = extern struct {
    number_buffers: u32,
    first: AudioBuffer,
};

pub const BeatAndTempoProc = *const fn (?*anyopaque, ?*f64, ?*f64) callconv(.c) OSStatus;
pub const MusicalTimeProc = *const fn (?*anyopaque, ?*u32, ?*f32, ?*u32, ?*f64) callconv(.c) OSStatus;
pub const TransportStateProc = *const fn (?*anyopaque, ?*u8, ?*u8, ?*f64, ?*u8, ?*f64, ?*f64) callconv(.c) OSStatus;
pub const TransportState2Proc = *const fn (?*anyopaque, ?*u8, ?*u8, ?*u8, ?*f64, ?*u8, ?*f64, ?*f64) callconv(.c) OSStatus;

pub const HostCallbackInfo = extern struct {
    host_user_data: ?*anyopaque = null,
    beat_and_tempo: ?BeatAndTempoProc = null,
    musical_time_location: ?MusicalTimeProc = null,
    transport_state: ?TransportStateProc = null,
    transport_state2: ?TransportState2Proc = null,

    /// A callback table wired to the four functions below, with `host_time` as user data.
    pub fn forHostTime(host_time: *HostTime) HostCallbackInfo {
        return .{
            .host_user_data = host_time,
            .beat_and_tempo = &beatAndTempo,
            .musical_time_location = &musicalTime,
            .transport_state = &transportState,
            .transport_state2 = &transportState2,
        };
    }
};

/// What the host callbacks report: the transport of the block being rendered. Atomics, because a
/// unit may also ask from another thread. Reads and writes never lock or allocate.
pub const HostTime = struct {
    playing: std.atomic.Value(bool) = .init(false),
    recording: std.atomic.Value(bool) = .init(false),
    changed: std.atomic.Value(bool) = .init(false),
    samples: std.atomic.Value(i64) = .init(0),
    tempo: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 120.0))),
    quarters: std.atomic.Value(u64) = .init(0),
    bar_start: std.atomic.Value(u64) = .init(0),
    numerator: std.atomic.Value(u32) = .init(4),
    denominator: std.atomic.Value(u32) = .init(4),
    sample_rate: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 48_000.0))),

    pub fn set(self: *HostTime, t: *const Transport) void {
        if (self.playing.swap(t.playing, .monotonic) != t.playing) {
            self.changed.store(true, .monotonic);
        }
        self.recording.store(t.recording, .monotonic);
        self.samples.store(t.samples, .monotonic);
        self.tempo.store(@bitCast(t.tempo), .monotonic);
        self.quarters.store(@bitCast(t.quarters), .monotonic);
        self.bar_start.store(@bitCast(t.bar_start), .monotonic);
        self.numerator.store(t.numerator, .monotonic);
        self.denominator.store(t.denominator, .monotonic);
    }

    pub fn setSampleRate(self: *HostTime, rate: f64) void {
        self.sample_rate.store(@bitCast(rate), .monotonic);
    }
};

fn loadF64(a: *const std.atomic.Value(u64)) f64 {
    return @bitCast(a.load(.monotonic));
}

/// Writes through an out-pointer the unit may leave null.
fn put(comptime T: type, p: ?*T, v: T) void {
    if (p) |q| q.* = v;
}

fn hostTimeFrom(user: ?*anyopaque) ?*HostTime {
    const u = user orelse return null;
    return @ptrCast(@alignCast(u));
}

const err_param: OSStatus = -50;

pub fn beatAndTempo(user: ?*anyopaque, beat: ?*f64, tempo: ?*f64) callconv(.c) OSStatus {
    const t = hostTimeFrom(user) orelse return err_param;
    put(f64, beat, loadF64(&t.quarters));
    put(f64, tempo, loadF64(&t.tempo));
    return 0;
}

pub fn musicalTime(
    user: ?*anyopaque,
    to_next_beat: ?*u32,
    numerator: ?*f32,
    denominator: ?*u32,
    downbeat: ?*f64,
) callconv(.c) OSStatus {
    const t = hostTimeFrom(user) orelse return err_param;
    const q = loadF64(&t.quarters);
    const per_quarter = loadF64(&t.sample_rate) * 60.0 / @max(loadF64(&t.tempo), 1.0);
    const raw = @round((@ceil(q) - q) * per_quarter);
    const next: u32 = if (std.math.isFinite(raw))
        @intFromFloat(std.math.clamp(raw, 0.0, @as(f64, std.math.maxInt(u32))))
    else
        0;
    put(u32, to_next_beat, next);
    put(f32, numerator, @floatFromInt(t.numerator.load(.monotonic)));
    put(u32, denominator, t.denominator.load(.monotonic));
    put(f64, downbeat, loadF64(&t.bar_start));
    return 0;
}

pub fn transportState2(
    user: ?*anyopaque,
    playing: ?*u8,
    recording: ?*u8,
    changed: ?*u8,
    sample: ?*f64,
    cycling: ?*u8,
    cycle_start: ?*f64,
    cycle_end: ?*f64,
) callconv(.c) OSStatus {
    const t = hostTimeFrom(user) orelse return err_param;
    put(u8, playing, @intFromBool(t.playing.load(.monotonic)));
    put(u8, recording, @intFromBool(t.recording.load(.monotonic)));
    put(u8, changed, @intFromBool(t.changed.swap(false, .monotonic)));
    put(f64, sample, @floatFromInt(t.samples.load(.monotonic)));
    put(u8, cycling, 0);
    put(f64, cycle_start, 0.0);
    put(f64, cycle_end, 0.0);
    return 0;
}

pub fn transportState(
    user: ?*anyopaque,
    playing: ?*u8,
    changed: ?*u8,
    sample: ?*f64,
    cycling: ?*u8,
    cycle_start: ?*f64,
    cycle_end: ?*f64,
) callconv(.c) OSStatus {
    return transportState2(user, playing, null, changed, sample, cycling, cycle_start, cycle_end);
}

pub const AuRenderCallback = *const fn (
    ref_con: ?*anyopaque,
    action_flags: ?*u32,
    time_stamp: ?*const AudioTimeStamp,
    bus: u32,
    frames: u32,
    data: ?*AudioBufferListHeader,
) callconv(.c) OSStatus;

pub const AuRenderCallbackStruct = extern struct {
    input_proc: ?AuRenderCallback = null,
    input_proc_ref_con: ?*anyopaque = null,
};

pub const AudioUnitParameterInfo = extern struct {
    name: [52]u8,
    unit_name: CFTypeRef,
    clump_id: u32,
    cf_name_string: CFTypeRef,
    unit: u32,
    min_value: f32,
    max_value: f32,
    default_value: f32,
    flags: u32,
};

comptime {
    std.debug.assert(@sizeOf(AudioStreamBasicDescription) == 40);
    std.debug.assert(@sizeOf(AudioTimeStamp) == 64);
    std.debug.assert(@sizeOf(AudioComponentDescription) == 20);
    std.debug.assert(@sizeOf(SmpteTime) == 24);
    std.debug.assert(@sizeOf(AudioBuffer) == 16);
    std.debug.assert(@sizeOf(AudioBufferList) == 8 + 16 * max_au_channels);
    std.debug.assert(@offsetOf(AudioBufferListHeader, "first") == 8);
    std.debug.assert(@sizeOf(HostCallbackInfo) == 40);
    std.debug.assert(@offsetOf(AudioTimeStamp, "flags") == 56);
    std.debug.assert(@offsetOf(AudioUnitParameterInfo, "unit_name") == 56);
}

/// Hand-declared AudioToolbox / AudioUnit / CoreFoundation symbols (macOS only; the build links
/// the frameworks). Only referenced under `is_macos`.
pub const sys = if (is_macos) struct {
    pub extern fn AudioComponentFindNext(component: AudioComponent, desc: *const AudioComponentDescription) callconv(.c) AudioComponent;
    pub extern fn AudioComponentCopyName(component: AudioComponent, name: *CFTypeRef) callconv(.c) OSStatus;
    pub extern fn AudioComponentGetDescription(component: AudioComponent, desc: *AudioComponentDescription) callconv(.c) OSStatus;
    pub extern fn AudioComponentGetVersion(component: AudioComponent, version: *u32) callconv(.c) OSStatus;
    pub extern fn AudioComponentInstanceNew(component: AudioComponent, instance: *AudioUnit) callconv(.c) OSStatus;
    pub extern fn AudioComponentInstanceDispose(instance: AudioUnit) callconv(.c) OSStatus;
    pub extern fn AudioUnitInitialize(unit: AudioUnit) callconv(.c) OSStatus;
    pub extern fn AudioUnitUninitialize(unit: AudioUnit) callconv(.c) OSStatus;
    pub extern fn AudioUnitGetPropertyInfo(unit: AudioUnit, id: u32, scope: u32, element: u32, size: ?*u32, writable: ?*u8) callconv(.c) OSStatus;
    pub extern fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*anyopaque, size: *u32) callconv(.c) OSStatus;
    pub extern fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) callconv(.c) OSStatus;
    pub extern fn AudioUnitGetParameter(unit: AudioUnit, id: u32, scope: u32, element: u32, value: *f32) callconv(.c) OSStatus;
    pub extern fn AudioUnitSetParameter(unit: AudioUnit, id: u32, scope: u32, element: u32, value: f32, offset: u32) callconv(.c) OSStatus;
    pub extern fn AudioUnitRender(
        unit: AudioUnit,
        action_flags: ?*u32,
        time_stamp: *const AudioTimeStamp,
        bus: u32,
        frames: u32,
        data: *AudioBufferList,
    ) callconv(.c) OSStatus;
    pub extern fn AudioUnitReset(unit: AudioUnit, scope: u32, element: u32) callconv(.c) OSStatus;
    pub extern fn MusicDeviceMIDIEvent(unit: AudioUnit, status: u32, data1: u32, data2: u32, offset: u32) callconv(.c) OSStatus;

    pub extern fn CFRelease(cf: CFTypeRef) callconv(.c) void;
    pub extern fn CFGetTypeID(cf: CFTypeRef) callconv(.c) usize;
    pub extern fn CFStringGetTypeID() callconv(.c) usize;
    pub extern fn CFDictionaryGetTypeID() callconv(.c) usize;
    pub extern fn CFStringGetLength(s: CFTypeRef) callconv(.c) CFIndex;
    pub extern fn CFStringGetMaximumSizeForEncoding(length: CFIndex, encoding: u32) callconv(.c) CFIndex;
    pub extern fn CFStringGetCString(s: CFTypeRef, buffer: [*]u8, size: CFIndex, encoding: u32) callconv(.c) u8;
    pub extern fn CFArrayGetCount(a: CFTypeRef) callconv(.c) CFIndex;
    pub extern fn CFArrayGetValueAtIndex(a: CFTypeRef, i: CFIndex) callconv(.c) CFTypeRef;
    pub extern fn CFDataCreate(alloc: CFTypeRef, bytes: [*]const u8, length: CFIndex) callconv(.c) CFTypeRef;
    pub extern fn CFDataGetLength(d: CFTypeRef) callconv(.c) CFIndex;
    pub extern fn CFDataGetBytePtr(d: CFTypeRef) callconv(.c) [*]const u8;
    pub extern fn CFPropertyListCreateData(alloc: CFTypeRef, plist: CFTypeRef, format: CFIndex, options: usize, err: ?*CFTypeRef) callconv(.c) CFTypeRef;
    pub extern fn CFPropertyListCreateWithData(alloc: CFTypeRef, data: CFTypeRef, options: usize, format: ?*CFIndex, err: ?*CFTypeRef) callconv(.c) CFTypeRef;
} else struct {};

/// Releases a CF object we own (null is ignored).
pub fn release(cf: CFTypeRef) void {
    if (!is_macos) return;
    if (cf != null) sys.CFRelease(cf);
}

/// Converts a borrowed CFString to an owned UTF-8 slice allocated from `allocator` (empty on any
/// failure or a non-string). Free with `allocator.free`. Control-thread only (allocates).
pub fn cfString(allocator: std.mem.Allocator, s: CFTypeRef) std.mem.Allocator.Error![]u8 {
    if (!is_macos or s == null) return allocator.alloc(u8, 0);
    if (sys.CFGetTypeID(s) != sys.CFStringGetTypeID()) return allocator.alloc(u8, 0);
    const len = std.math.clamp(sys.CFStringGetLength(s), 0, max_string);
    const cap0 = sys.CFStringGetMaximumSizeForEncoding(len, cf_string_encoding_utf8);
    if (cap0 <= 0) return allocator.alloc(u8, 0);
    const cap: usize = @intCast(@min(cap0 +| 1, max_string * 4 + 1));
    const buf = try allocator.alloc(u8, cap);
    defer allocator.free(buf);
    if (sys.CFStringGetCString(s, buf.ptr, @intCast(cap), cf_string_encoding_utf8) == 0) {
        return allocator.alloc(u8, 0);
    }
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    // Rust used to_string_lossy: replace invalid UTF-8 sequences with U+FFFD.
    if (std.unicode.utf8ValidateSlice(buf[0..n])) return allocator.dupe(u8, buf[0..n]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < n) {
        const l = std.unicode.utf8ByteSequenceLength(buf[i]) catch 0;
        if (l != 0 and i + l <= n and std.unicode.utf8ValidateSlice(buf[i .. i + l])) {
            try out.appendSlice(allocator, buf[i .. i + l]);
            i += l;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// One registered component.
pub const RawComponent = struct {
    ty: u32,
    subtype: u32,
    manufacturer: u32,
    /// `"Vendor: Name"` as registered. Owned by the allocator given to `components`.
    name: []u8,
    version: u32,
};

/// Frees a list returned by `components`.
pub fn freeComponents(allocator: std.mem.Allocator, list: []RawComponent) void {
    for (list) |c| allocator.free(c.name);
    allocator.free(list);
}

/// Every component of type `ty` that can be instantiated synchronously (at most
/// `max_components` are examined). Control-thread only. Free with `freeComponents`.
pub fn components(allocator: std.mem.Allocator, ty: u32) std.mem.Allocator.Error![]RawComponent {
    var out: std.ArrayList(RawComponent) = .empty;
    errdefer {
        for (out.items) |c| allocator.free(c.name);
        out.deinit(allocator);
    }
    if (!is_macos) return out.toOwnedSlice(allocator);
    const desc: AudioComponentDescription = .{ .component_type = ty };
    var comp: AudioComponent = null;
    for (0..max_components) |_| {
        comp = sys.AudioComponentFindNext(comp, &desc);
        if (comp == null) break;
        var d: AudioComponentDescription = .{};
        var name: CFTypeRef = null;
        var version: u32 = 0;
        const ds = sys.AudioComponentGetDescription(comp, &d);
        const ns = sys.AudioComponentCopyName(comp, &name);
        _ = sys.AudioComponentGetVersion(comp, &version);
        defer release(name);
        const full = if (ns == 0) try cfString(allocator, name) else try allocator.alloc(u8, 0);
        if (ds != 0 or d.component_type != ty or d.component_flags & component_flag_requires_async != 0) {
            allocator.free(full);
            continue;
        }
        out.append(allocator, .{
            .ty = ty,
            .subtype = d.component_sub_type,
            .manufacturer = d.component_manufacturer,
            .name = full,
            .version = version,
        }) catch |e| {
            allocator.free(full);
            return e;
        };
    }
    return out.toOwnedSlice(allocator);
}

/// One global-scope parameter as the unit describes it. Strings are owned by the allocator that
/// built it; free with `deinit`.
pub const RawParam = struct {
    id: u32,
    name: []u8,
    unit: u32,
    custom_unit: []u8,
    min: f32,
    max: f32,
    default: f32,
    flags: u32,
    /// Names of the values of an indexed parameter (when it has them).
    value_strings: [][]u8,

    pub fn deinit(self: *RawParam, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.custom_unit);
        for (self.value_strings) |s| allocator.free(s);
        allocator.free(self.value_strings);
        self.* = undefined;
    }
};

// --- tests (ffi.rs has none in lines 1-460; these pin the ABI and the callback behaviour) ---

const testing = std.testing;

test "ABI struct sizes match the C headers" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(AudioStreamBasicDescription));
    try testing.expectEqual(@as(usize, 64), @sizeOf(AudioTimeStamp));
    try testing.expectEqual(@as(usize, 20), @sizeOf(AudioComponentDescription));
}

test "format_linear_pcm is the fourcc lpcm" {
    try testing.expectEqual(@as(u32, 0x6c70636d), format_linear_pcm);
}

test "host callbacks report the transport snapshot" {
    var h: HostTime = .{};
    h.set(&.{ .playing = true, .recording = true, .tempo = 90.0, .numerator = 3, .denominator = 8, .samples = 1000, .quarters = 1.5, .bar_start = 0.0 });
    var beat: f64 = 0;
    var tempo: f64 = 0;
    try testing.expectEqual(@as(OSStatus, 0), beatAndTempo(&h, &beat, &tempo));
    try testing.expectEqual(@as(f64, 1.5), beat);
    try testing.expectEqual(@as(f64, 90.0), tempo);

    var to_next: u32 = 0;
    var num: f32 = 0;
    var den: u32 = 0;
    var down: f64 = -1;
    try testing.expectEqual(@as(OSStatus, 0), musicalTime(&h, &to_next, &num, &den, &down));
    // 0.5 quarter at 90 bpm and 48 kHz = 0.5 * 32000 samples.
    try testing.expectEqual(@as(u32, 16000), to_next);
    try testing.expectEqual(@as(f32, 3.0), num);
    try testing.expectEqual(@as(u32, 8), den);
    try testing.expectEqual(@as(f64, 0.0), down);
}

test "transport state reports changed once and tolerates null out-pointers" {
    var h: HostTime = .{};
    h.set(&.{ .playing = true, .samples = 77, .tempo = 120.0 });
    var playing: u8 = 0;
    var rec: u8 = 9;
    var changed: u8 = 0;
    var sample: f64 = 0;
    try testing.expectEqual(@as(OSStatus, 0), transportState2(&h, &playing, &rec, &changed, &sample, null, null, null));
    try testing.expectEqual(@as(u8, 1), playing);
    try testing.expectEqual(@as(u8, 0), rec);
    try testing.expectEqual(@as(u8, 1), changed);
    try testing.expectEqual(@as(f64, 77.0), sample);
    try testing.expectEqual(@as(OSStatus, 0), transportState(&h, &playing, &changed, &sample, null, null, null));
    try testing.expectEqual(@as(u8, 0), changed);
}

test "callbacks reject a null user pointer" {
    try testing.expectEqual(@as(OSStatus, -50), beatAndTempo(null, null, null));
    try testing.expectEqual(@as(OSStatus, -50), musicalTime(null, null, null, null, null));
    try testing.expectEqual(@as(OSStatus, -50), transportState2(null, null, null, null, null, null, null, null));
    try testing.expectEqual(@as(OSStatus, -50), transportState(null, null, null, null, null, null, null));
}

test "musicalTime clamps a non-finite or huge distance" {
    var h: HostTime = .{};
    h.set(&.{ .tempo = 0.0, .quarters = 0.5 });
    h.setSampleRate(1e30);
    var to_next: u32 = 0;
    try testing.expectEqual(@as(OSStatus, 0), musicalTime(&h, &to_next, null, null, null));
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), to_next);
}

test "HostCallbackInfo.forHostTime wires all four callbacks" {
    var h: HostTime = .{};
    const info = HostCallbackInfo.forHostTime(&h);
    try testing.expect(info.beat_and_tempo != null and info.transport_state2 != null);
    var tempo: f64 = 0;
    try testing.expectEqual(@as(OSStatus, 0), info.beat_and_tempo.?(info.host_user_data, null, &tempo));
    try testing.expectEqual(@as(f64, 120.0), tempo);
}

test "cfString of null is empty" {
    const s = try cfString(testing.allocator, null);
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "components enumerates effects without leaking" {
    if (!is_macos) return error.SkipZigTest;
    const list = try components(testing.allocator, std.mem.readInt(u32, "aufx", .big));
    defer freeComponents(testing.allocator, list);
    try testing.expect(list.len <= max_components);
    for (list) |c| try testing.expectEqual(std.mem.readInt(u32, "aufx", .big), c.ty);
}
