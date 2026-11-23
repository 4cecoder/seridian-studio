// Translated to Zig from soundcraft/crates/au-host/src/ffi.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! AudioUnit (AUv2) instance wrapper: input render callback, `Instance` (create, configure,
//! render, parameters, tail/latency, ClassInfo state) and the `StateLink` that lets a state
//! handle on another thread read the unit safely.
//!
//! Covers lines ~460-1006 of ffi.rs. macOS only: on other targets `Instance.create` fails with
//! `error.Unsupported` and nothing touches the AudioToolbox externs.
//!
//! Threading: an `Instance` is Send-like but NOT thread-safe. It may move between threads, but
//! every call must come from one thread at a time (the audio thread while rendering, the control
//! thread otherwise). The only cross-thread object is `StateLink`, which serialises
//! `saveState` against `destroy` with a spin lock that the audio thread never takes.
//!
//! Real-time rules: `render`, `inputMut`, `output`, `midi`, `setParam`, `getParam`,
//! `scheduleParam`, `setTransport` allocate nothing and take no locks. Everything else
//! (`create`, `configure`, `params`, `saveState`, `loadState`, `destroy`) is control-thread only.

const std = @import("std");
const abi = @import("abi.zig");
const Transport = @import("../plugin.zig").Transport;

const is_macos = abi.is_macos;
const sys = abi.sys;
const OSStatus = abi.OSStatus;
const AudioUnit = abi.AudioUnit;
const CFTypeRef = abi.CFTypeRef;
const RawParam = abi.RawParam;
const AudioBuffer = abi.AudioBuffer;
const AudioBufferList = abi.AudioBufferList;
const AudioBufferListHeader = abi.AudioBufferListHeader;
const AudioTimeStamp = abi.AudioTimeStamp;
const max_au_channels = abi.max_au_channels;
const max_slice = abi.max_slice;

const err_param: OSStatus = -50;

/// `kParameterEvent_Immediate`.
const param_event_immediate: u32 = 1;

/// `AudioUnitParameterEvent` (AudioUnitProperties.h): 32 bytes.
pub const AudioUnitParameterEvent = extern struct {
    scope: u32,
    element: u32,
    parameter: u32,
    event_type: u32,
    /// For the immediate form: `buffer_offset` then `value` (an f32) overlay `start_buffer_offset`
    /// and `duration_in_frames`. Written through the helpers below.
    a: u32,
    b: u32,
    c: u32,
    d: u32,

    pub fn immediate(parameter: u32, value: f32, buffer_offset: u32) AudioUnitParameterEvent {
        return .{
            .scope = abi.scope_global,
            .element = 0,
            .parameter = parameter,
            .event_type = param_event_immediate,
            .a = buffer_offset,
            .b = @bitCast(value),
            .c = 0,
            .d = 0,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(AudioUnitParameterEvent) == 32);
}

const ext = if (is_macos) struct {
    pub extern fn AudioUnitScheduleParameters(unit: AudioUnit, events: [*]const AudioUnitParameterEvent, count: u32) callconv(.c) OSStatus;
} else struct {};

pub const CreateError = error{ Unsupported, NotRegistered, RequiresAsync, InstantiationFailed, OutOfMemory };
pub const ConfigureError = error{ CannotSetInputCallback, NoSupportedFormat, OutOfMemory };
pub const RenderError = error{ NotReady, RenderFailed };

/// The state the input render callback reads: one buffer per channel, filled by the host before
/// each render. The buffers are slices into the instance's preallocated slab.
pub const InputState = struct {
    bufs: [max_au_channels][]f32 = @splat(&.{}),
    n_bufs: usize = 0,
    frames: usize = 0,
};

/// Supplies the effect's input: copies (or lends) our input buffers into the unit's list.
/// Runs on the audio thread inside `AudioUnitRender`: no allocation, no locks.
pub fn inputCallback(
    ref_con: ?*anyopaque,
    action_flags: ?*u32,
    time_stamp: ?*const AudioTimeStamp,
    bus: u32,
    frames_in: u32,
    data: ?*AudioBufferListHeader,
) callconv(.c) OSStatus {
    _ = action_flags;
    _ = time_stamp;
    _ = bus;
    const rc = ref_con orelse return err_param;
    const list = data orelse return err_param;
    // `ref_con` is the `InputState` embedded in the live Instance; the host only reads it while
    // inside `AudioUnitRender`. `list` is the unit's buffer list with `number_buffers` buffers
    // laid out contiguously from `first`.
    const input: *InputState = @ptrCast(@alignCast(rc));
    const n: usize = list.number_buffers;
    const first: [*]AudioBuffer = @ptrCast(&list.first);
    const frames = @min(@as(usize, frames_in), max_slice);
    const avail = @min(input.frames, frames);
    for (0..@min(n, 64)) |i| {
        const b = &first[i];
        if (input.n_bufs == 0) continue;
        const src = input.bufs[@min(i, input.n_bufs - 1)];
        if (b.data == null) {
            // Lend our buffer (the unit may process in place; it is ours to scribble on).
            if (src.len >= frames) {
                b.data = src.ptr;
                b.data_byte_size = @intCast(frames * 4);
                b.number_channels = 1;
            }
            continue;
        }
        const room = @min(@as(usize, b.data_byte_size) / 4, frames);
        const dst: [*]f32 = @ptrCast(@alignCast(b.data.?));
        for (0..room) |k| {
            dst[k] = if (k < avail and k < src.len) src[k] else 0.0;
        }
    }
    return 0;
}

/// The link between an instance and its state handles: the unit's state is read on the control
/// thread while the instance renders on the audio thread. The instance clears the link under its
/// lock before it disposes of the unit, so a handle never reads a dead unit. Reference counted;
/// the instance holds one reference, each handle another.
pub const StateLink = struct {
    allocator: std.mem.Allocator,
    locked: std.atomic.Value(bool) = .init(false),
    unit: AudioUnit,
    refs: std.atomic.Value(usize) = .init(1),

    fn lock(self: *StateLink) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *StateLink) void {
        self.locked.store(false, .release);
    }

    pub fn retain(self: *StateLink) *StateLink {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn releaseRef(self: *StateLink) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }

    fn kill(self: *StateLink) void {
        self.lock();
        defer self.unlock();
        self.unit = null;
    }

    /// The unit's `ClassInfo` as a binary property list (`null` once the instance is gone).
    /// Control thread. Caller frees with `allocator`.
    pub fn saveState(self: *StateLink, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        if (!is_macos) return null;
        self.lock();
        defer self.unlock();
        const unit = self.unit orelse return null;
        var plist: CFTypeRef = null;
        var size: u32 = @sizeOf(CFTypeRef);
        // The property is a CFPropertyListRef returned +1.
        const st = sys.AudioUnitGetProperty(unit, abi.prop_class_info, abi.scope_global, 0, @ptrCast(&plist), &size);
        if (st != 0 or plist == null) {
            abi.release(plist);
            return null;
        }
        var err: CFTypeRef = null;
        const data = sys.CFPropertyListCreateData(null, plist, abi.cf_property_list_binary_format, 0, &err);
        abi.release(err);
        abi.release(plist);
        if (data == null) return null;
        defer abi.release(data);
        const len = sys.CFDataGetLength(data);
        const p = sys.CFDataGetBytePtr(data);
        if (len <= 0 or @as(usize, @intCast(len)) > abi.max_state) return null;
        return try allocator.dupe(u8, p[0..@intCast(len)]);
    }
};

/// A live Audio Unit instance. Heap allocated (stable address: the unit holds pointers to the
/// embedded input state and host time). Free with `destroy`.
pub const Instance = struct {
    allocator: std.mem.Allocator,
    unit: AudioUnit,
    input: InputState = .{},
    time: abi.HostTime = .{},
    /// One slab holds every output and input channel buffer; sized in `configure`.
    slab: []f32 = &.{},
    outputs: [max_au_channels][]f32 = @splat(&.{}),
    abl: AudioBufferList,
    /// Parameter ids in the order `params` listed them: the dense index space for
    /// `getParamAt` / `setParamAt` / `scheduleParamAt`.
    param_ids: []u32 = &.{},
    has_input: bool,
    initialized: bool = false,
    channels: usize = 0,
    max_frames: usize = 0,
    sample_rate: f64 = 48_000.0,
    sample_time: f64 = 0.0,
    /// Status of the last failing AudioToolbox call (diagnostics).
    last_status: OSStatus = 0,
    link: *StateLink,

    /// Creates (but does not initialize) the component `(ty, subtype, manufacturer)`.
    pub fn create(allocator: std.mem.Allocator, ty: u32, subtype: u32, manufacturer: u32, has_input: bool) CreateError!*Instance {
        if (!is_macos) return error.Unsupported;
        const desc: abi.AudioComponentDescription = .{ .component_type = ty, .component_sub_type = subtype, .component_manufacturer = manufacturer };
        const comp = sys.AudioComponentFindNext(null, &desc);
        if (comp == null) return error.NotRegistered;
        var d: abi.AudioComponentDescription = .{};
        if (sys.AudioComponentGetDescription(comp, &d) == 0 and d.component_flags & abi.component_flag_requires_async != 0) {
            return error.RequiresAsync;
        }
        var unit: AudioUnit = null;
        const st = sys.AudioComponentInstanceNew(comp, &unit);
        if (st != 0 or unit == null) return error.InstantiationFailed;
        errdefer _ = sys.AudioComponentInstanceDispose(unit);

        const link = try allocator.create(StateLink);
        errdefer allocator.destroy(link);
        link.* = .{ .allocator = allocator, .unit = unit };
        const self = try allocator.create(Instance);
        const empty: AudioBuffer = .{ .number_channels = 1, .data_byte_size = 0, .data = null };
        self.* = .{
            .allocator = allocator,
            .unit = unit,
            .abl = .{ .number_buffers = 0, .buffers = @splat(empty) },
            .has_input = has_input,
            .link = link,
        };
        const callbacks = abi.HostCallbackInfo.forHostTime(&self.time);
        // Units that never ask for host time may refuse it.
        _ = self.setProperty(abi.prop_host_callbacks, abi.scope_global, 0, &callbacks);
        return self;
    }

    /// Uninitializes and disposes the unit and frees everything.
    pub fn destroy(self: *Instance) void {
        const a = self.allocator;
        self.link.kill();
        self.link.releaseRef();
        if (is_macos) {
            if (self.initialized) _ = sys.AudioUnitUninitialize(self.unit);
            _ = sys.AudioComponentInstanceDispose(self.unit);
        }
        if (self.slab.len != 0) a.free(self.slab);
        if (self.param_ids.len != 0) a.free(self.param_ids);
        a.destroy(self);
    }

    /// The transport the host callbacks report during the next renders. Lock-free.
    pub fn setTransport(self: *Instance, t: *const Transport) void {
        self.time.set(t);
    }

    fn setProperty(self: *const Instance, id: u32, scope: u32, element: u32, value: anytype) OSStatus {
        if (!is_macos) return err_param;
        const T = @typeInfo(@TypeOf(value)).pointer.child;
        return sys.AudioUnitSetProperty(self.unit, id, scope, element, @ptrCast(value), @sizeOf(T));
    }

    fn getF64(self: *const Instance, id: u32) ?f64 {
        if (!is_macos) return null;
        var v: f64 = 0;
        var size: u32 = @sizeOf(f64);
        const st = sys.AudioUnitGetProperty(self.unit, id, abi.scope_global, 0, &v, &size);
        return if (st == 0 and std.math.isFinite(v)) v else null;
    }

    fn format(self: *const Instance, scope: u32, sample_rate: f64, channels: usize) OSStatus {
        const asbd: abi.AudioStreamBasicDescription = .{
            .sample_rate = sample_rate,
            .format_id = abi.format_linear_pcm,
            .format_flags = abi.format_flag_float | abi.format_flag_packed | abi.format_flag_non_interleaved,
            .bytes_per_packet = 4,
            .frames_per_packet = 1,
            .bytes_per_frame = 4,
            .channels_per_frame = @intCast(channels),
            .bits_per_channel = 32,
            .reserved = 0,
        };
        return self.setProperty(abi.prop_stream_format, scope, 0, &asbd);
    }

    /// (Re)configures and initializes the unit for `sample_rate`, `max_frames_in`-frame slices
    /// and (preferably) `channels_in` channels on its main input and output buses. Returns the
    /// channel count it accepted. Control thread (allocates the buffers); builds every buffer
    /// list `render` will use.
    pub fn configure(self: *Instance, sample_rate: f64, max_frames_in: usize, channels_in: usize) ConfigureError!usize {
        if (!is_macos) return error.NoSupportedFormat;
        if (self.initialized) {
            _ = sys.AudioUnitUninitialize(self.unit);
            self.initialized = false;
        }
        self.max_frames = 0;
        const mf = std.math.clamp(max_frames_in, 1, max_slice);
        _ = self.setProperty(abi.prop_max_frames, abi.scope_global, 0, &@as(u32, @intCast(mf)));
        if (self.has_input) {
            const cb: abi.AuRenderCallbackStruct = .{ .input_proc = &inputCallback, .input_proc_ref_con = &self.input };
            const st = self.setProperty(abi.prop_set_render_callback, abi.scope_input, 0, &cb);
            if (st != 0) {
                self.last_status = st;
                return error.CannotSetInputCallback;
            }
        }
        const want = std.math.clamp(channels_in, 1, max_au_channels);
        var tried: [3]usize = @splat(0);
        var ok: ?usize = null;
        var last: OSStatus = 0;
        const candidates = [3]usize{ want, 2, 1 };
        for (candidates, 0..) |ch, k| {
            if (std.mem.indexOfScalar(usize, &tried, ch) != null) continue;
            tried[k] = ch;
            const o = self.format(abi.scope_output, sample_rate, ch);
            const i: OSStatus = if (self.has_input) self.format(abi.scope_input, sample_rate, ch) else 0;
            if (o != 0 or i != 0) {
                last = if (o != 0) o else i;
                continue;
            }
            const st = sys.AudioUnitInitialize(self.unit);
            if (st == 0) {
                ok = ch;
                break;
            }
            last = st;
        }
        self.last_status = last;
        const ch = ok orelse return error.NoSupportedFormat;
        self.initialized = true;
        self.channels = ch;
        self.sample_rate = sample_rate;
        self.time.setSampleRate(sample_rate);

        const per = if (self.has_input) ch * 2 else ch;
        const new_slab = try self.allocator.alloc(f32, per * mf);
        @memset(new_slab, 0);
        // No render is running (we hold the instance exclusively), so swapping is race-free.
        if (self.slab.len != 0) self.allocator.free(self.slab);
        self.slab = new_slab;
        self.outputs = @splat(&.{});
        self.input = .{};
        for (0..ch) |c| {
            self.outputs[c] = new_slab[c * mf ..][0..mf];
            if (self.has_input) self.input.bufs[c] = new_slab[(ch + c) * mf ..][0..mf];
        }
        self.input.n_bufs = if (self.has_input) ch else 0;
        const empty: AudioBuffer = .{ .number_channels = 1, .data_byte_size = 0, .data = null };
        self.abl = .{ .number_buffers = @intCast(ch), .buffers = @splat(empty) };
        for (0..ch) |c| self.abl.buffers[c] = .{ .number_channels = 1, .data_byte_size = @intCast(mf * 4), .data = self.outputs[c].ptr };
        self.sample_time = 0;
        self.max_frames = mf;
        return ch;
    }

    pub fn isReady(self: *const Instance) bool {
        return self.initialized and self.max_frames > 0;
    }

    pub fn maxFrames(self: *const Instance) usize {
        return self.max_frames;
    }

    pub fn channelCount(self: *const Instance) usize {
        return self.channels;
    }

    /// Input buffer `ch` (for effects), `max_frames` long.
    pub fn inputMut(self: *Instance, ch: usize) ?[]f32 {
        if (ch >= self.input.n_bufs) return null;
        return self.input.bufs[ch];
    }

    /// Renders `frames` (<= `max_frames`) into the output buffers. Never allocates or locks.
    /// Pending `midi` / `scheduleParam` events apply at their offsets inside this render.
    pub fn render(self: *Instance, frames: usize) RenderError!void {
        if (!self.isReady() or frames == 0 or frames > self.max_frames) return error.NotReady;
        if (!is_macos) return error.NotReady;
        self.input.frames = frames;
        const n: usize = self.channels;
        for (0..n) |c| {
            self.abl.buffers[c] = .{ .number_channels = 1, .data_byte_size = @intCast(frames * 4), .data = self.outputs[c].ptr };
        }
        self.abl.number_buffers = @intCast(n);
        const ts: AudioTimeStamp = .{ .sample_time = self.sample_time, .flags = abi.timestamp_sample_time_valid };
        var flags: u32 = 0;
        const st = sys.AudioUnitRender(self.unit, &flags, &ts, 0, @intCast(frames), &self.abl);
        self.sample_time += @floatFromInt(frames);
        if (st != 0) {
            self.last_status = st;
            return error.RenderFailed;
        }
    }

    /// Output channel `ch` of the last render (`frames` long), wherever the unit left it.
    pub fn output(self: *const Instance, ch: usize, frames: usize) ?[]const f32 {
        if (ch >= self.abl.number_buffers) return null;
        const b = self.abl.buffers[ch];
        const p = b.data orelse return null;
        const len = @min(@as(usize, b.data_byte_size) / 4, frames);
        const fp: [*]const f32 = @ptrCast(@alignCast(p));
        return fp[0..len];
    }

    pub fn reset(self: *Instance) void {
        if (!is_macos) return;
        _ = sys.AudioUnitReset(self.unit, abi.scope_global, 0);
    }

    /// Latency in samples at the configured rate (capped at 10 s).
    pub fn latency(self: *const Instance) usize {
        return self.secondsToSamples(self.getF64(abi.prop_latency), 10.0);
    }

    /// Tail in samples at the configured rate (capped at a minute).
    pub fn tail(self: *const Instance) usize {
        return self.secondsToSamples(self.getF64(abi.prop_tail_time), 60.0);
    }

    fn secondsToSamples(self: *const Instance, s: ?f64, cap: f64) usize {
        const v = s orelse return 0;
        if (!(v > 0.0)) return 0;
        return @intFromFloat(@round(@min(v, cap) * self.sample_rate));
    }

    /// A MIDI channel message `offset` frames into the next `render` (AUv2 instruments honour
    /// `inOffsetSampleFrame`). Call it before the render that covers the offset; `offset` must be
    /// below that render's frame count. Lock-free.
    pub fn midi(self: *Instance, status: u8, data1: u8, data2: u8, offset: u32) bool {
        if (!is_macos) return false;
        return sys.MusicDeviceMIDIEvent(self.unit, status, data1, data2, offset) == 0;
    }

    pub fn getParam(self: *const Instance, id: u32) ?f32 {
        if (!is_macos) return null;
        var v: f32 = 0;
        const st = sys.AudioUnitGetParameter(self.unit, id, abi.scope_global, 0, &v);
        return if (st == 0 and std.math.isFinite(v)) v else null;
    }

    pub fn setParam(self: *Instance, id: u32, value: f32) bool {
        if (!is_macos) return false;
        return sys.AudioUnitSetParameter(self.unit, id, abi.scope_global, 0, value, 0) == 0;
    }

    /// Sets parameter `id` to `value` at `start_frame` inside the next render
    /// (`AudioUnitScheduleParameters`, immediate event). Lock-free; the event lives on the stack.
    pub fn scheduleParam(self: *Instance, id: u32, value: f32, start_frame: u32) bool {
        if (!is_macos) return false;
        const ev = [1]AudioUnitParameterEvent{.immediate(id, value, start_frame)};
        return ext.AudioUnitScheduleParameters(self.unit, &ev, 1) == 0;
    }

    /// Id for dense parameter index `index` (valid after `params`).
    pub fn paramId(self: *const Instance, index: usize) ?u32 {
        if (index >= self.param_ids.len) return null;
        return self.param_ids[index];
    }

    pub fn getParamAt(self: *const Instance, index: usize) ?f32 {
        return self.getParam(self.paramId(index) orelse return null);
    }

    pub fn setParamAt(self: *Instance, index: usize, value: f32) bool {
        return self.setParam(self.paramId(index) orelse return false, value);
    }

    pub fn scheduleParamAt(self: *Instance, index: usize, value: f32, start_frame: u32) bool {
        return self.scheduleParam(self.paramId(index) orelse return false, value, start_frame);
    }

    /// The global-scope parameters, bounded by `max_params`. Also (re)builds the dense
    /// index -> id table. Control thread. Free with `freeParams`.
    pub fn params(self: *Instance, allocator: std.mem.Allocator) std.mem.Allocator.Error![]RawParam {
        var out: std.ArrayList(RawParam) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit(allocator);
            out.deinit(allocator);
        }
        if (!is_macos) return out.toOwnedSlice(allocator);
        var size: u32 = 0;
        var writable: u8 = 0;
        var st = sys.AudioUnitGetPropertyInfo(self.unit, abi.prop_parameter_list, abi.scope_global, 0, &size, &writable);
        if (st != 0 or size == 0) return out.toOwnedSlice(allocator);
        const n = @min(@as(usize, size) / 4, abi.max_params);
        const ids = try allocator.alloc(u32, n);
        defer allocator.free(ids);
        @memset(ids, 0);
        size = @intCast(n * 4);
        st = sys.AudioUnitGetProperty(self.unit, abi.prop_parameter_list, abi.scope_global, 0, ids.ptr, &size);
        if (st != 0) return out.toOwnedSlice(allocator);
        const got = @min(@as(usize, size) / 4, n);
        var good: std.ArrayList(u32) = .empty;
        defer good.deinit(allocator);
        for (ids[0..got]) |id| {
            if (try self.paramInfo(allocator, id)) |p| {
                out.append(allocator, p) catch |e| {
                    var pp = p;
                    pp.deinit(allocator);
                    return e;
                };
                try good.append(allocator, id);
            }
        }
        const table = try self.allocator.dupe(u32, good.items);
        if (self.param_ids.len != 0) self.allocator.free(self.param_ids);
        self.param_ids = table;
        return out.toOwnedSlice(allocator);
    }

    pub fn freeParams(allocator: std.mem.Allocator, list: []RawParam) void {
        for (list) |*p| p.deinit(allocator);
        allocator.free(list);
    }

    fn paramInfo(self: *const Instance, allocator: std.mem.Allocator, id: u32) std.mem.Allocator.Error!?RawParam {
        var info = std.mem.zeroes(abi.AudioUnitParameterInfo);
        var size: u32 = @sizeOf(abi.AudioUnitParameterInfo);
        const st = sys.AudioUnitGetProperty(self.unit, abi.prop_parameter_info, abi.scope_global, id, &info, &size);
        if (st != 0) return null;
        const owned = info.flags & abi.param_flag_cf_name_release != 0;
        const has_cf = info.flags & abi.param_flag_has_cf_name != 0;
        const is_custom = info.unit == abi.unit_custom;
        // Release the CF strings (when the unit gave us ownership) on every exit path.
        defer if (owned) {
            if (has_cf) abi.release(info.cf_name_string);
            if (is_custom) abi.release(info.unit_name);
        };
        var name: []u8 = if (has_cf) try abi.cfString(allocator, info.cf_name_string) else try allocator.alloc(u8, 0);
        errdefer allocator.free(name);
        if (name.len == 0) {
            const n = std.mem.indexOfScalar(u8, &info.name, 0) orelse info.name.len;
            allocator.free(name);
            name = try lossyUtf8(allocator, info.name[0..n]);
        }
        const custom_unit = if (is_custom) try abi.cfString(allocator, info.unit_name) else try allocator.alloc(u8, 0);
        errdefer allocator.free(custom_unit);
        const value_strings = if (info.unit == abi.unit_indexed) try self.valueStrings(allocator, id) else try allocator.alloc([]u8, 0);
        return .{
            .id = id,
            .name = name,
            .unit = info.unit,
            .custom_unit = custom_unit,
            .min = info.min_value,
            .max = info.max_value,
            .default = info.default_value,
            .flags = info.flags,
            .value_strings = value_strings,
        };
    }

    fn valueStrings(self: *const Instance, allocator: std.mem.Allocator, id: u32) std.mem.Allocator.Error![][]u8 {
        var arr: CFTypeRef = null;
        var size: u32 = @sizeOf(CFTypeRef);
        // The property is a CFArrayRef (returned +1).
        const st = sys.AudioUnitGetProperty(self.unit, abi.prop_parameter_value_strings, abi.scope_global, id, @ptrCast(&arr), &size);
        if (st != 0 or arr == null) return allocator.alloc([]u8, 0);
        defer abi.release(arr);
        const n: usize = @intCast(std.math.clamp(sys.CFArrayGetCount(arr), 0, abi.max_value_strings));
        const out = try allocator.alloc([]u8, n);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |s| allocator.free(s);
            allocator.free(out);
        }
        while (filled < n) : (filled += 1) {
            out[filled] = try abi.cfString(allocator, sys.CFArrayGetValueAtIndex(arr, @intCast(filled)));
        }
        return out;
    }

    /// The link for state handles (retained: call `releaseRef` when done).
    pub fn stateLink(self: *Instance) *StateLink {
        return self.link.retain();
    }

    /// Restores a blob from `StateLink.saveState`. Hostile input: size bounded, parsed by
    /// CoreFoundation, must be a dictionary, and the unit validates it. Control thread.
    pub fn loadState(self: *Instance, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > abi.max_state) return false;
        if (!is_macos) return false;
        const data = sys.CFDataCreate(null, bytes.ptr, @intCast(bytes.len));
        if (data == null) return false;
        var err: CFTypeRef = null;
        const plist = sys.CFPropertyListCreateWithData(null, data, 0, null, &err);
        abi.release(err);
        abi.release(data);
        if (plist == null) return false;
        defer abi.release(plist);
        const is_dict = sys.CFGetTypeID(plist) == sys.CFDictionaryGetTypeID();
        const st: OSStatus = if (is_dict) self.setProperty(abi.prop_class_info, abi.scope_global, 0, &plist) else err_param;
        return st == 0;
    }
};

/// Rust used `String::from_utf8_lossy`: invalid sequences become U+FFFD.
fn lossyUtf8(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (l != 0 and i + l <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + l])) {
            try out.appendSlice(allocator, bytes[i .. i + l]);
            i += l;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// --- tests (ffi.rs has none in lines 460-1006; these pin the callback and the instance) ---

const testing = std.testing;

test "AudioUnitParameterEvent is 32 bytes and encodes an immediate event" {
    const e = AudioUnitParameterEvent.immediate(7, 0.5, 33);
    try testing.expectEqual(@as(usize, 32), @sizeOf(AudioUnitParameterEvent));
    try testing.expectEqual(@as(u32, 7), e.parameter);
    try testing.expectEqual(@as(u32, 1), e.event_type);
    try testing.expectEqual(@as(u32, 33), e.a);
    try testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(e.b)));
}

test "inputCallback rejects null ref_con or data" {
    var l: AudioBufferList = .{ .number_buffers = 0, .buffers = undefined };
    try testing.expectEqual(@as(OSStatus, -50), inputCallback(null, null, null, 0, 4, @ptrCast(&l)));
    var st: InputState = .{};
    try testing.expectEqual(@as(OSStatus, -50), inputCallback(&st, null, null, 0, 4, null));
}

test "inputCallback copies input into the unit's buffers and zero-pads" {
    var a = [_]f32{ 1, 2, 3, 4 };
    var b = [_]f32{ 5, 6, 7, 8 };
    var st: InputState = .{ .frames = 3 };
    st.bufs[0] = &a;
    st.bufs[1] = &b;
    st.n_bufs = 2;
    var d0: [4]f32 = @splat(9);
    var d1: [4]f32 = @splat(9);
    const empty: AudioBuffer = .{ .number_channels = 1, .data_byte_size = 0, .data = null };
    var l: AudioBufferList = .{ .number_buffers = 2, .buffers = @splat(empty) };
    l.buffers[0] = .{ .number_channels = 1, .data_byte_size = 16, .data = &d0 };
    l.buffers[1] = .{ .number_channels = 1, .data_byte_size = 16, .data = &d1 };
    try testing.expectEqual(@as(OSStatus, 0), inputCallback(&st, null, null, 0, 4, @ptrCast(&l)));
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 0 }, &d0);
    try testing.expectEqualSlices(f32, &.{ 5, 6, 7, 0 }, &d1);
}

test "inputCallback lends our buffer when the unit supplies none, and clamps extra channels" {
    var a = [_]f32{ 1, 2, 3, 4 };
    var st: InputState = .{ .frames = 4 };
    st.bufs[0] = &a;
    st.n_bufs = 1;
    const empty: AudioBuffer = .{ .number_channels = 2, .data_byte_size = 0, .data = null };
    var l: AudioBufferList = .{ .number_buffers = 2, .buffers = @splat(empty) };
    try testing.expectEqual(@as(OSStatus, 0), inputCallback(&st, null, null, 0, 4, @ptrCast(&l)));
    // Channel 1 maps onto the last (only) input buffer.
    for (0..2) |i| {
        try testing.expect(l.buffers[i].data == @as(?*anyopaque, &a));
        try testing.expectEqual(@as(u32, 16), l.buffers[i].data_byte_size);
        try testing.expectEqual(@as(u32, 1), l.buffers[i].number_channels);
    }
}

test "inputCallback with no input buffers leaves the list alone" {
    var st: InputState = .{};
    var d: [2]f32 = @splat(9);
    var l: AudioBufferList = .{ .number_buffers = 1, .buffers = undefined };
    l.buffers[0] = .{ .number_channels = 1, .data_byte_size = 8, .data = &d };
    try testing.expectEqual(@as(OSStatus, 0), inputCallback(&st, null, null, 0, 2, @ptrCast(&l)));
    try testing.expectEqualSlices(f32, &.{ 9, 9 }, &d);
}

test "create of an unregistered component fails" {
    const r = Instance.create(testing.allocator, std.mem.readInt(u32, "aufx", .big), std.mem.readInt(u32, "zzzz", .big), std.mem.readInt(u32, "zzzz", .big), true);
    try testing.expectError(if (is_macos) error.NotRegistered else error.Unsupported, r);
}

test "lossyUtf8 replaces invalid bytes" {
    const s = try lossyUtf8(testing.allocator, "a\xffb");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a\u{FFFD}b", s);
}

fn appleDelay() !*Instance {
    if (!is_macos) return error.SkipZigTest;
    return Instance.create(testing.allocator, std.mem.readInt(u32, "aufx", .big), std.mem.readInt(u32, "dely", .big), std.mem.readInt(u32, "appl", .big), true) catch |e| switch (e) {
        error.NotRegistered, error.InstantiationFailed => error.SkipZigTest,
        else => e,
    };
}

test "Apple AUDelay: configure, render, parameters, state round trip" {
    const inst = try appleDelay();
    defer inst.destroy();
    try testing.expect(!inst.isReady());
    try testing.expectError(error.NotReady, inst.render(64));
    const ch = try inst.configure(48_000, 256, 2);
    try testing.expect(ch >= 1);
    try testing.expect(inst.isReady());
    try testing.expectEqual(@as(usize, 256), inst.maxFrames());
    try testing.expectError(error.NotReady, inst.render(0));
    try testing.expectError(error.NotReady, inst.render(257));
    inst.inputMut(0).?[0..64].* = @splat(0.5);
    try inst.render(64);
    try testing.expect(inst.output(0, 64).?.len == 64);
    try testing.expect(inst.output(ch, 64) == null);
    try testing.expect(inst.inputMut(ch) == null);
    _ = inst.latency();
    _ = inst.tail();
    inst.reset();

    const list = try inst.params(testing.allocator);
    defer Instance.freeParams(testing.allocator, list);
    try testing.expect(list.len > 0);
    try testing.expect(list.len <= abi.max_params);
    for (list, 0..) |p, i| try testing.expectEqual(p.id, inst.paramId(i).?);
    try testing.expect(inst.paramId(list.len) == null);
    const p0 = list[0];
    try testing.expect(inst.getParamAt(0) != null);
    try testing.expect(inst.setParamAt(0, p0.default));
    try testing.expect(inst.scheduleParamAt(0, p0.default, 10));
    try inst.render(64);

    const link = inst.stateLink();
    defer link.releaseRef();
    const blob = (try link.saveState(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(blob);
    try testing.expect(blob.len > 0);
    try testing.expect(inst.loadState(blob));
    try testing.expect(!inst.loadState(""));
    try testing.expect(!inst.loadState("not a plist"));
}

test "state link goes dead after destroy" {
    const inst = try appleDelay();
    const link = inst.stateLink();
    defer link.releaseRef();
    inst.destroy();
    try testing.expect((try link.saveState(testing.allocator)) == null);
}
