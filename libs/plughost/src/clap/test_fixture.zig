// Translated to Zig from soundcraft/crates/clap-host/tests/fixture/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Test-only CLAP plugins for plughost: a gain effect, a "DC synth", and three
//! wide-layout effects, all reached through one in-process entry (`entry`).
//!
//! - `org.soundcraft.test.gain`: stereo in/out, param 7 "Gain" (0..2, default 1), param 3
//!   "Mode" (stepped enum A/B/C), hidden param 9 "Secret", latency 3 samples, `clap.state`
//!   (gain and mode as two little-endian f64s), and a floating-only `clap.gui` with no window.
//!   Showing the GUI queues an edit that sets the gain to 0.25; the next `process` call
//!   reports it as an output parameter event.
//! - `org.soundcraft.test.synth`: instrument, stereo out, one CLAP note port. Its output is the
//!   velocity of the held note (0 when none), switching at the event's sample offset. MIDI CC 7
//!   sets the level to value / 127.
//! - `org.soundcraft.test.wide16`, `.wide17ports`, `.wide65ch`: effects advertising wide layouts
//!   (16 ports of 64 channels, 17 ports of 2 channels, 1 port of 65 channels). `process` writes
//!   1.0 into every output channel when the host buffers match the advertised layout, -1.0 when
//!   they do not.
//!
//! Test-only: nothing in the library imports this file except the test re-export in root.zig,
//! and Zig analyses it lazily, so non-test builds never compile it. Instances live in a fixed
//! pool, so `create` allocates nothing. `create` and `destroy` run on the control thread;
//! `process` and `flush` run on the audio thread and only write fixed storage.
//!
//! Observation hooks for tests: counters, a ring of the last events with their sample offsets,
//! the last saved state blob, and an ordered log of the fake GUI calls. `reset` clears them.

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const bundle = @import("bundle.zig");

/// `CLAP_PARAM_IS_ENUM` from CLAP 1.2 `params.h`. Not in abi.zig yet.
/// TODO(abi): verify this value against the CLAP headers and move it into abi.zig.
const CLAP_PARAM_IS_ENUM: u32 = 1 << 16;

const PARAM_GAIN: abi.ClapId = 7;
const PARAM_MODE: abi.ClapId = 3;
const PARAM_SECRET: abi.ClapId = 9;

const GUI_WIDTH: u32 = 300;
const GUI_HEIGHT: u32 = 200;
const GUI_EDIT_GAIN: f64 = 0.25;
const LATENCY_SAMPLES: u32 = 3;
const MAX_INSTANCES = 8;
const EVENT_LOG_CAP = 64;
const GUI_LOG_CAP = 16;
const STATE_BYTES = 16;

// ---- observation hooks ----------------------------------------------------------------------

pub var process_calls = std.atomic.Value(u32).init(0);
pub var flush_calls = std.atomic.Value(u32).init(0);
pub var state_saves = std.atomic.Value(u32).init(0);
pub var state_loads = std.atomic.Value(u32).init(0);
pub var state_refusals = std.atomic.Value(u32).init(0);
pub var gui_creates = std.atomic.Value(u32).init(0);
pub var gui_shows = std.atomic.Value(u32).init(0);
pub var gui_hides = std.atomic.Value(u32).init(0);
pub var gui_destroys = std.atomic.Value(u32).init(0);
pub var host_log_calls = std.atomic.Value(u32).init(0);
pub var host_resize_calls = std.atomic.Value(u32).init(0);
pub var host_last_width = std.atomic.Value(u32).init(0);
pub var host_last_height = std.atomic.Value(u32).init(0);

/// One event as the plugin received it. Payload fields are filled only for core-space events
/// of the types the fixture understands.
pub const RecordedEvent = struct {
    sample_offset: u32,
    space_id: u16,
    kind: u16,
    param_id: abi.ClapId = 0,
    key: i16 = 0,
    value: f64 = 0,
    midi: [3]u8 = .{ 0, 0, 0 },
};

var event_log: [EVENT_LOG_CAP]RecordedEvent = undefined;
var event_total = std.atomic.Value(u32).init(0);

/// The state blob the plugin last tried to save (16 bytes; zero before the first save).
pub var last_saved_state: [STATE_BYTES]u8 = @splat(0);

pub const GuiOp = enum { create, show, hide, destroy };
var gui_log: [GUI_LOG_CAP]GuiOp = undefined;
var gui_log_len = std.atomic.Value(u32).init(0);

fn bump(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn record(rec: RecordedEvent) void {
    const n = event_total.load(.monotonic);
    event_log[n % EVENT_LOG_CAP] = rec;
    event_total.store(n + 1, .release);
}

/// Copies up to `out.len` of the most recent events into `out`, oldest first.
pub fn recordedEvents(out: []RecordedEvent) []const RecordedEvent {
    const total = event_total.load(.acquire);
    const kept = @min(total, EVENT_LOG_CAP);
    const take = @min(kept, out.len);
    const first = total - take;
    for (out[0..take], 0..) |*dst, k| dst.* = event_log[(first + k) % EVENT_LOG_CAP];
    return out[0..take];
}

fn guiPush(op: GuiOp) void {
    const n = gui_log_len.load(.monotonic);
    if (n < GUI_LOG_CAP) {
        gui_log[n] = op;
        gui_log_len.store(n + 1, .release);
    }
}

/// The fake GUI calls since the last `reset`, oldest first.
pub fn guiLog() []const GuiOp {
    return gui_log[0..gui_log_len.load(.acquire)];
}

/// Clears every counter, the event ring and the GUI log. Live instances are untouched.
pub fn reset() void {
    const counters = [_]*std.atomic.Value(u32){
        &process_calls,
        &flush_calls,
        &state_saves,
        &state_loads,
        &state_refusals,
        &gui_creates,
        &gui_shows,
        &gui_hides,
        &gui_destroys,
        &host_log_calls,
        &host_resize_calls,
        &host_last_width,
        &host_last_height,
        &event_total,
        &gui_log_len,
    };
    for (counters) |c| c.store(0, .monotonic);
}

// ---- helpers shared by the callbacks ----------------------------------------------------------

/// Writes `s` into a fixed `char[N]` field, NUL-terminated when it fits (`write_name` in lib.rs).
fn writeName(dst: []u8, s: []const u8) void {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    if (n < dst.len) dst[n] = 0;
}

fn inRange(x: f64) bool {
    return x >= 0.0 and x <= 2.0;
}

// ---- instances ------------------------------------------------------------------------------

const Wide = struct {
    ports: u32,
    channels: u32,
};

const Fx = struct {
    plugin: abi.ClapPlugin,
    host: *const abi.ClapHost,
    synth: bool,
    wide: ?Wide,
    gain: f64,
    mode: f64,
    level: f64,
    active: bool,
    processing: bool,
    gui_created: bool,
    gui_visible: bool,
    gui_edit_pending: bool,
    slot: usize,
};

/// Fixed storage for instances. Slots are claimed and released on the control thread only.
var instances: [MAX_INSTANCES]Fx = undefined;
var slot_used: [MAX_INSTANCES]bool = @splat(false);

fn fx(p: *const abi.ClapPlugin) *Fx {
    const data = p.plugin_data orelse @panic("plugin_data is null");
    return @ptrCast(@alignCast(data));
}

// ---- events -----------------------------------------------------------------------------------

fn describe(h: *const abi.ClapEventHeader) RecordedEvent {
    var rec: RecordedEvent = .{ .sample_offset = h.time, .space_id = h.space_id, .kind = h.type_ };
    if (h.space_id != abi.CLAP_CORE_EVENT_SPACE_ID) return rec;
    switch (h.type_) {
        abi.CLAP_EVENT_PARAM_VALUE => {
            const e: *const abi.ClapEventParamValue = @ptrCast(@alignCast(h));
            rec.param_id = e.param_id;
            rec.key = e.key;
            rec.value = e.value;
        },
        abi.CLAP_EVENT_NOTE_ON, abi.CLAP_EVENT_NOTE_OFF => {
            const e: *const abi.ClapEventNote = @ptrCast(@alignCast(h));
            rec.key = e.key;
            rec.value = e.velocity;
        },
        abi.CLAP_EVENT_MIDI => {
            const e: *const abi.ClapEventMidi = @ptrCast(@alignCast(h));
            rec.midi = e.data;
        },
        else => {},
    }
    return rec;
}

fn apply(f: *Fx, rec: RecordedEvent) void {
    switch (rec.kind) {
        abi.CLAP_EVENT_PARAM_VALUE => switch (rec.param_id) {
            PARAM_GAIN => f.gain = rec.value,
            PARAM_MODE => f.mode = rec.value,
            else => {},
        },
        abi.CLAP_EVENT_NOTE_ON => f.level = rec.value,
        abi.CLAP_EVENT_NOTE_OFF => f.level = 0.0,
        abi.CLAP_EVENT_MIDI => {
            if ((rec.midi[0] & 0xF0) == 0xB0 and rec.midi[1] == 7) {
                f.level = @as(f64, @floatFromInt(rec.midi[2])) / 127.0;
            }
        },
        else => {},
    }
}

/// Records one event and, for core-space events, applies it.
fn receive(f: *Fx, h: *const abi.ClapEventHeader) void {
    const rec = describe(h);
    record(rec);
    if (h.space_id == abi.CLAP_CORE_EVENT_SPACE_ID) apply(f, rec);
}

// ---- lifecycle ----------------------------------------------------------------------------------

fn pluginInit(p: *const abi.ClapPlugin) callconv(.c) bool {
    const f = fx(p);
    // Exercise the host's extension lookup and log callback.
    const get = f.host.get_extension orelse return true;
    if (get(f.host, abi.CLAP_EXT_LOG.ptr)) |raw| {
        const log: *const abi.ClapHostLog = @ptrCast(@alignCast(raw));
        if (log.log) |log_fn| log_fn(f.host, abi.CLAP_LOG_INFO, "fixture init");
    }
    if (get(f.host, "clap.does-not-exist") != null) return false;
    return true;
}

fn pluginDestroy(p: *const abi.ClapPlugin) callconv(.c) void {
    const f = fx(p);
    if (f.gui_created) @panic("plugin destroyed with its GUI alive");
    slot_used[f.slot] = false;
}

fn pluginActivate(p: *const abi.ClapPlugin, sample_rate: f64, min_frames: u32, max_frames: u32) callconv(.c) bool {
    const f = fx(p);
    if (f.active or !(sample_rate > 0.0) or min_frames == 0 or max_frames < min_frames) return false;
    f.active = true;
    return true;
}

fn pluginDeactivate(p: *const abi.ClapPlugin) callconv(.c) void {
    const f = fx(p);
    if (f.processing) @panic("deactivate while processing");
    f.active = false;
}

fn pluginStartProcessing(p: *const abi.ClapPlugin) callconv(.c) bool {
    const f = fx(p);
    if (!f.active) @panic("start_processing while inactive");
    f.processing = true;
    return true;
}

fn pluginStopProcessing(p: *const abi.ClapPlugin) callconv(.c) void {
    fx(p).processing = false;
}

fn pluginReset(p: *const abi.ClapPlugin) callconv(.c) void {
    fx(p).level = 0.0;
}

// ---- audio processing ----------------------------------------------------------------------------

/// Every output channel of the first output port gets 1.0 when all ports match the wide layout,
/// -1.0 otherwise.
fn fits(bufs: ?[*]const abi.ClapAudioBuffer, count: u32, ports: u32, channels: u32) bool {
    if (count != ports) return false;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const b = bufs orelse return false;
        if (b[i].channel_count != channels) return false;
    }
    return true;
}

fn fillWide(pr: *const abi.ClapProcess, ports: u32, channels: u32, n: usize) void {
    const ok = fits(pr.audio_inputs, pr.audio_inputs_count, ports, channels) and
        fits(pr.audio_outputs, pr.audio_outputs_count, ports, channels);
    if (pr.audio_outputs_count == 0) return;
    const outs = pr.audio_outputs orelse @panic("no output ports");
    const out = &outs[0];
    const chans = out.data32 orelse @panic("no output channel pointers");
    var c: usize = 0;
    while (c < out.channel_count) : (c += 1) {
        const o = chans[c] orelse @panic("null output channel");
        var i: usize = 0;
        while (i < n) : (i += 1) o[i] = if (ok) 1.0 else -1.0;
    }
}

/// Pushes the host-visible parameter edit and an ignorable note event onto the output queue.
fn pushGuiEdit(pr: *const abi.ClapProcess) void {
    const out = pr.out_events orelse @panic("no output events");
    const try_push = out.try_push orelse @panic("no try_push");
    const edit: abi.ClapEventParamValue = .{
        .header = .{
            .size = @sizeOf(abi.ClapEventParamValue),
            .time = 0,
            .space_id = abi.CLAP_CORE_EVENT_SPACE_ID,
            .type_ = abi.CLAP_EVENT_PARAM_VALUE,
            .flags = 0,
        },
        .param_id = PARAM_GAIN,
        .cookie = null,
        .note_id = -1,
        .port_index = -1,
        .channel = -1,
        .key = -1,
        .value = GUI_EDIT_GAIN,
    };
    if (!try_push(out, &edit.header)) @panic("try_push refused the parameter edit");
    // Other event types are accepted and ignored by the host.
    const note: abi.ClapEventNote = .{
        .header = .{
            .size = @sizeOf(abi.ClapEventNote),
            .time = 0,
            .space_id = abi.CLAP_CORE_EVENT_SPACE_ID,
            .type_ = abi.CLAP_EVENT_NOTE_END,
            .flags = 0,
        },
        .note_id = -1,
        .port_index = 0,
        .channel = 0,
        .key = 60,
        .velocity = 0.0,
    };
    if (!try_push(out, &note.header)) @panic("try_push refused the note event");
}

fn pluginProcess(p: *const abi.ClapPlugin, pr: *const abi.ClapProcess) callconv(.c) abi.ClapProcessStatus {
    const f = fx(p);
    bump(&process_calls);
    if (!f.processing) @panic("process while not processing");
    const n: usize = pr.frames_count;
    const ev = pr.in_events orelse @panic("no input events");
    const count = ev.size.?(ev);
    if (f.wide) |w| {
        fillWide(pr, w.ports, w.channels, n);
        return abi.CLAP_PROCESS_CONTINUE;
    }
    if (pr.audio_outputs_count != 1) return abi.CLAP_PROCESS_ERROR;
    const outs = pr.audio_outputs orelse return abi.CLAP_PROCESS_ERROR;
    const out = &outs[0];
    var input: ?*const abi.ClapAudioBuffer = null;
    if (f.synth) {
        if (pr.audio_inputs_count != 0) return abi.CLAP_PROCESS_ERROR;
    } else {
        if (pr.audio_inputs_count != 1) return abi.CLAP_PROCESS_ERROR;
        const ins = pr.audio_inputs orelse return abi.CLAP_PROCESS_ERROR;
        input = &ins[0];
    }
    if (f.gui_edit_pending) {
        f.gui_edit_pending = false;
        f.gain = GUI_EDIT_GAIN;
        pushGuiEdit(pr);
    }
    var next: u32 = 0;
    var last_time: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        while (next < count) {
            const h = ev.get.?(ev, next) orelse @panic("event get returned null");
            if (h.time < last_time) @panic("events not sorted");
            if (@as(usize, h.time) >= n) @panic("event time outside the block");
            if (@as(usize, h.time) > i) break;
            last_time = h.time;
            receive(f, h);
            next += 1;
        }
        const chans = out.data32 orelse @panic("no output channel pointers");
        var c: usize = 0;
        while (c < out.channel_count) : (c += 1) {
            const o = chans[c] orelse @panic("null output channel");
            const v: f32 = if (input) |inp| blk: {
                const in_chans = inp.data32 orelse @panic("no input channel pointers");
                const idx = @min(c, @as(usize, inp.channel_count) - 1);
                const src = in_chans[idx] orelse @panic("null input channel");
                break :blk src[i] * @as(f32, @floatCast(f.gain));
            } else @as(f32, @floatCast(f.level));
            o[i] = v;
        }
    }
    return abi.CLAP_PROCESS_CONTINUE;
}

// ---- params -------------------------------------------------------------------------------------

fn paramsCount(p: *const abi.ClapPlugin) callconv(.c) u32 {
    return if (fx(p).synth) 0 else 3;
}

const ParamRow = struct {
    id: abi.ClapId,
    name: []const u8,
    flags: u32,
    min: f64,
    max: f64,
    default: f64,
};

fn paramsGetInfo(_: *const abi.ClapPlugin, index: u32, info: *abi.ClapParamInfo) callconv(.c) bool {
    const row: ParamRow = switch (index) {
        0 => .{ .id = PARAM_GAIN, .name = "Gain", .flags = abi.CLAP_PARAM_IS_AUTOMATABLE, .min = 0.0, .max = 2.0, .default = 1.0 },
        1 => .{ .id = PARAM_MODE, .name = "Mode", .flags = abi.CLAP_PARAM_IS_STEPPED | CLAP_PARAM_IS_ENUM, .min = 0.0, .max = 2.0, .default = 0.0 },
        2 => .{ .id = PARAM_SECRET, .name = "Secret", .flags = abi.CLAP_PARAM_IS_HIDDEN, .min = 0.0, .max = 1.0, .default = 0.0 },
        else => return false,
    };
    info.id = row.id;
    info.flags = row.flags;
    info.cookie = null;
    writeName(&info.name, row.name);
    writeName(&info.module, "");
    info.min_value = row.min;
    info.max_value = row.max;
    info.default_value = row.default;
    return true;
}

fn paramsGetValue(p: *const abi.ClapPlugin, id: abi.ClapId, out: *f64) callconv(.c) bool {
    const f = fx(p);
    const v: f64 = switch (id) {
        PARAM_GAIN => f.gain,
        PARAM_MODE => f.mode,
        PARAM_SECRET => 0.0,
        else => return false,
    };
    out.* = v;
    return true;
}

fn paramsValueToText(_: *const abi.ClapPlugin, id: abi.ClapId, value: f64, buf: [*]u8, capacity: u32) callconv(.c) bool {
    if (id != PARAM_MODE or capacity < 2) return false;
    const labels = "ABC";
    // Saturating like Rust's `as usize`: negatives and NaN map to 0, anything >= 3 to '?'.
    const r = @round(value);
    const idx: usize = if (!(r >= 0.0)) 0 else if (r >= 3.0) 3 else @intFromFloat(r);
    buf[0] = if (idx < labels.len) labels[idx] else '?';
    buf[1] = 0;
    return true;
}

fn paramsFlush(p: *const abi.ClapPlugin, in: *const abi.ClapInputEvents, out: *const abi.ClapOutputEvents) callconv(.c) void {
    _ = out;
    bump(&flush_calls);
    const f = fx(p);
    const n = in.size.?(in);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const h = in.get.?(in, i) orelse @panic("event get returned null");
        receive(f, h);
    }
}

const params_ext: abi.ClapPluginParams = .{
    .count = paramsCount,
    .get_info = paramsGetInfo,
    .get_value = paramsGetValue,
    .value_to_text = paramsValueToText,
    .text_to_value = null,
    .flush = paramsFlush,
};

// ---- audio ports, note ports, latency --------------------------------------------------------------

fn portsCount(p: *const abi.ClapPlugin, is_input: bool) callconv(.c) u32 {
    const f = fx(p);
    if (f.wide) |w| return w.ports;
    return if (is_input and f.synth) 0 else 1;
}

fn portsGet(p: *const abi.ClapPlugin, index: u32, is_input: bool, info: *abi.ClapAudioPortInfo) callconv(.c) bool {
    const f = fx(p);
    if (f.wide) |w| {
        if (index >= w.ports) return false;
        info.id = index * 2 + @as(u32, @intFromBool(is_input));
        writeName(&info.name, "wide");
        info.flags = if (index == 0) abi.CLAP_AUDIO_PORT_IS_MAIN else 0;
        info.channel_count = w.channels;
        info.port_type = null;
        info.in_place_pair = abi.CLAP_INVALID_ID;
        return true;
    }
    if (index != 0 or (is_input and f.synth)) return false;
    info.id = if (is_input) 0 else 1;
    writeName(&info.name, "main");
    info.flags = abi.CLAP_AUDIO_PORT_IS_MAIN;
    info.channel_count = 2;
    info.port_type = "stereo";
    info.in_place_pair = abi.CLAP_INVALID_ID;
    return true;
}

const ports_ext: abi.ClapPluginAudioPorts = .{ .count = portsCount, .get = portsGet };

fn latencyGet(_: *const abi.ClapPlugin) callconv(.c) u32 {
    return LATENCY_SAMPLES;
}

const latency_ext: abi.ClapPluginLatency = .{ .get = latencyGet };

fn notesCount(p: *const abi.ClapPlugin, is_input: bool) callconv(.c) u32 {
    return if (is_input and fx(p).synth) 1 else 0;
}

fn notesGet(_: *const abi.ClapPlugin, index: u32, is_input: bool, info: *abi.ClapNotePortInfo) callconv(.c) bool {
    if (index != 0 or !is_input) return false;
    info.id = 0;
    info.supported_dialects = abi.CLAP_NOTE_DIALECT_CLAP | abi.CLAP_NOTE_DIALECT_MIDI;
    info.preferred_dialect = abi.CLAP_NOTE_DIALECT_CLAP;
    writeName(&info.name, "notes");
    return true;
}

const notes_ext: abi.ClapPluginNotePorts = .{ .count = notesCount, .get = notesGet };

// ---- state --------------------------------------------------------------------------------------

fn stateSave(p: *const abi.ClapPlugin, stream: *const abi.ClapOStream) callconv(.c) bool {
    const f = fx(p);
    var bytes: [STATE_BYTES]u8 = undefined;
    const gain_bits: u64 = @bitCast(f.gain);
    const mode_bits: u64 = @bitCast(f.mode);
    std.mem.writeInt(u64, bytes[0..8], gain_bits, .little);
    std.mem.writeInt(u64, bytes[8..16], mode_bits, .little);
    const write = stream.write orelse @panic("ostream has no write");
    // Written in two pieces to exercise appending.
    const a = write(stream, &bytes, 5);
    const b = write(stream, &bytes[5], 11);
    last_saved_state = bytes;
    bump(&state_saves);
    return a == 5 and b == 11;
}

fn stateLoad(p: *const abi.ClapPlugin, stream: *const abi.ClapIStream) callconv(.c) bool {
    const f = fx(p);
    bump(&state_loads);
    const read = stream.read orelse @panic("istream has no read");
    // One byte more than a valid blob, so an oversized blob is detected.
    var bytes: [STATE_BYTES + 1]u8 = @splat(0);
    var got: usize = 0;
    while (got < bytes.len) {
        const n = read(stream, &bytes[got], bytes.len - got);
        if (n <= 0) break;
        got += @as(usize, @intCast(n));
    }
    if (got != STATE_BYTES) {
        bump(&state_refusals);
        return false;
    }
    const gain: f64 = @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    const mode: f64 = @bitCast(std.mem.readInt(u64, bytes[8..16], .little));
    if (!inRange(gain) or !inRange(mode)) {
        bump(&state_refusals);
        return false;
    }
    f.gain = gain;
    f.mode = mode;
    return true;
}

const state_ext: abi.ClapPluginState = .{ .save = stateSave, .load = stateLoad };

// ---- GUI (floating only, no window) ---------------------------------------------------------------

fn guiIsApiSupported(_: *const abi.ClapPlugin, _: [*:0]const u8, is_floating: bool) callconv(.c) bool {
    return is_floating;
}

fn guiCreate(p: *const abi.ClapPlugin, _: [*:0]const u8, is_floating: bool) callconv(.c) bool {
    const f = fx(p);
    if (!(is_floating and !f.gui_created)) @panic("gui create");
    f.gui_created = true;
    bump(&gui_creates);
    guiPush(.create);
    return true;
}

fn guiDestroy(p: *const abi.ClapPlugin) callconv(.c) void {
    const f = fx(p);
    if (!f.gui_created) @panic("gui destroy without create");
    f.gui_created = false;
    f.gui_visible = false;
    bump(&gui_destroys);
    guiPush(.destroy);
}

fn guiSetScale(_: *const abi.ClapPlugin, scale: f64) callconv(.c) bool {
    return scale > 0.0;
}

fn guiSuggestTitle(p: *const abi.ClapPlugin, title: [*:0]const u8) callconv(.c) void {
    if (!fx(p).gui_created) @panic("suggest_title without create");
    if (std.mem.span(title).len == 0) @panic("empty title");
}

fn guiShow(p: *const abi.ClapPlugin) callconv(.c) bool {
    const f = fx(p);
    if (!f.gui_created) @panic("gui show without create");
    f.gui_visible = true;
    f.gui_edit_pending = true;
    bump(&gui_shows);
    guiPush(.show);
    // Exercise the host GUI extension: it must answer, and must accept the resize.
    const get = f.host.get_extension orelse @panic("host has no get_extension");
    const raw = get(f.host, abi.CLAP_EXT_GUI.ptr) orelse @panic("host gui extension");
    const host_gui: *const abi.ClapHostGui = @ptrCast(@alignCast(raw));
    const resize = host_gui.request_resize orelse @panic("host has no request_resize");
    if (!resize(f.host, GUI_WIDTH, GUI_HEIGHT)) @panic("host refused the resize");
    return true;
}

fn guiHide(p: *const abi.ClapPlugin) callconv(.c) bool {
    const f = fx(p);
    f.gui_visible = false;
    bump(&gui_hides);
    guiPush(.hide);
    return true;
}

const gui_ext: abi.ClapPluginGui = .{
    .is_api_supported = guiIsApiSupported,
    .get_preferred_api = null,
    .create = guiCreate,
    .destroy = guiDestroy,
    .set_scale = guiSetScale,
    .get_size = null,
    .can_resize = null,
    .get_resize_hints = null,
    .adjust_size = null,
    .set_size = null,
    .set_parent = null,
    .set_transient = null,
    .suggest_title = guiSuggestTitle,
    .show = guiShow,
    .hide = guiHide,
};

// ---- extension lookup and plugin construction ----------------------------------------------------

fn pluginGetExtension(p: *const abi.ClapPlugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const f = fx(p);
    const name = std.mem.span(id);
    if (std.mem.eql(u8, name, abi.CLAP_EXT_PARAMS)) return &params_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_AUDIO_PORTS)) return &ports_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_LATENCY) and !f.synth) return &latency_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_NOTE_PORTS) and f.synth) return &notes_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_STATE) and !f.synth) return &state_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_GUI) and !f.synth) return &gui_ext;
    return null;
}

fn pluginOnMainThread(_: *const abi.ClapPlugin) callconv(.c) void {}

const gain_features = [_:null]?[*:0]const u8{ "audio-effect", "stereo" };
const synth_features = [_:null]?[*:0]const u8{ "instrument", "synthesizer" };
const wide_features = [_:null]?[*:0]const u8{"audio-effect"};

fn wideDescriptor(comptime id: [:0]const u8, comptime name: [:0]const u8) abi.ClapPluginDescriptor {
    return .{
        .clap_version = abi.CLAP_VERSION,
        .id = id.ptr,
        .name = name.ptr,
        .vendor = "SoundCraft tests",
        .url = null,
        .manual_url = null,
        .support_url = null,
        .version = "1.0.0",
        .description = null,
        .features = &wide_features,
    };
}

const gain_desc: abi.ClapPluginDescriptor = .{
    .clap_version = abi.CLAP_VERSION,
    .id = "org.soundcraft.test.gain",
    .name = "Fixture Gain",
    .vendor = "SoundCraft tests",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "1.0.0",
    .description = "test gain",
    .features = &gain_features,
};

const synth_desc: abi.ClapPluginDescriptor = .{
    .clap_version = abi.CLAP_VERSION,
    .id = "org.soundcraft.test.synth",
    .name = "Fixture Synth",
    .vendor = "SoundCraft tests",
    .url = null,
    .manual_url = null,
    .support_url = null,
    .version = "1.0.0",
    .description = null,
    .features = &synth_features,
};

const wide16_desc = wideDescriptor("org.soundcraft.test.wide16", "Fixture Wide 16x64");
const wide17_desc = wideDescriptor("org.soundcraft.test.wide17ports", "Fixture Wide 17 ports");
const wide65_desc = wideDescriptor("org.soundcraft.test.wide65ch", "Fixture Wide 65 channels");

// ---- factory and entry ------------------------------------------------------------------------------

fn factoryCount(_: *const abi.ClapPluginFactory) callconv(.c) u32 {
    return 5;
}

fn factoryDescriptor(_: *const abi.ClapPluginFactory, index: u32) callconv(.c) ?*const abi.ClapPluginDescriptor {
    return switch (index) {
        0 => &gain_desc,
        1 => &synth_desc,
        2 => &wide16_desc,
        3 => &wide17_desc,
        4 => &wide65_desc,
        else => null,
    };
}

const Choice = struct {
    desc: *const abi.ClapPluginDescriptor,
    synth: bool,
    wide: ?Wide,
};

fn factoryCreatePlugin(_: *const abi.ClapPluginFactory, host: *const abi.ClapHost, plugin_id: [*:0]const u8) callconv(.c) ?*const abi.ClapPlugin {
    const id = std.mem.span(plugin_id);
    const choice: Choice = if (std.mem.eql(u8, id, "org.soundcraft.test.gain"))
        .{ .desc = &gain_desc, .synth = false, .wide = null }
    else if (std.mem.eql(u8, id, "org.soundcraft.test.synth"))
        .{ .desc = &synth_desc, .synth = true, .wide = null }
    else if (std.mem.eql(u8, id, "org.soundcraft.test.wide16"))
        .{ .desc = &wide16_desc, .synth = false, .wide = .{ .ports = 16, .channels = 64 } }
    else if (std.mem.eql(u8, id, "org.soundcraft.test.wide17ports"))
        .{ .desc = &wide17_desc, .synth = false, .wide = .{ .ports = 17, .channels = 2 } }
    else if (std.mem.eql(u8, id, "org.soundcraft.test.wide65ch"))
        .{ .desc = &wide65_desc, .synth = false, .wide = .{ .ports = 1, .channels = 65 } }
    else
        return null;

    const slot = for (slot_used, 0..) |used, i| {
        if (!used) break i;
    } else return null;
    slot_used[slot] = true;
    instances[slot] = .{
        .plugin = .{
            .desc = choice.desc,
            .plugin_data = null,
            .init = pluginInit,
            .destroy = pluginDestroy,
            .activate = pluginActivate,
            .deactivate = pluginDeactivate,
            .start_processing = pluginStartProcessing,
            .stop_processing = pluginStopProcessing,
            .reset = pluginReset,
            .process = pluginProcess,
            .get_extension = pluginGetExtension,
            .on_main_thread = pluginOnMainThread,
        },
        .host = host,
        .synth = choice.synth,
        .wide = choice.wide,
        .gain = 1.0,
        .mode = 0.0,
        .level = 0.0,
        .active = false,
        .processing = false,
        .gui_created = false,
        .gui_visible = false,
        .gui_edit_pending = false,
        .slot = slot,
    };
    const f = &instances[slot];
    f.plugin.plugin_data = f;
    return &f.plugin;
}

const factory: abi.ClapPluginFactory = .{
    .get_plugin_count = factoryCount,
    .get_plugin_descriptor = factoryDescriptor,
    .create_plugin = factoryCreatePlugin,
};

fn entryInit(_: [*:0]const u8) callconv(.c) bool {
    return true;
}

fn entryDeinit() callconv(.c) void {}

fn entryGetFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(factory_id), abi.CLAP_PLUGIN_FACTORY_ID)) return &factory;
    return null;
}

/// The in-process entry. Load it with `bundle.Bundle.fromEntry(&entry, "")`; no dlopen.
pub const entry: abi.ClapPluginEntry = .{
    .clap_version = abi.CLAP_VERSION,
    .init = entryInit,
    .deinit = entryDeinit,
    .get_factory = entryGetFactory,
};

// ---- host side used by the tests ------------------------------------------------------------------

fn hostLog(_: *const abi.ClapHost, _: i32, _: [*:0]const u8) callconv(.c) void {
    bump(&host_log_calls);
}

fn hostRequestResize(_: *const abi.ClapHost, width: u32, height: u32) callconv(.c) bool {
    bump(&host_resize_calls);
    host_last_width.store(width, .monotonic);
    host_last_height.store(height, .monotonic);
    return true;
}

const host_log_ext: abi.ClapHostLog = .{ .log = hostLog };

const host_gui_ext: abi.ClapHostGui = .{
    .resize_hints_changed = null,
    .request_resize = hostRequestResize,
    .request_show = null,
    .request_hide = null,
    .closed = null,
};

fn hostGetExtension(_: *const abi.ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const name = std.mem.span(id);
    if (std.mem.eql(u8, name, abi.CLAP_EXT_LOG)) return &host_log_ext;
    if (std.mem.eql(u8, name, abi.CLAP_EXT_GUI)) return &host_gui_ext;
    return null;
}

/// A host that answers the log and GUI extensions and nothing else.
pub const test_host: abi.ClapHost = .{
    .clap_version = abi.CLAP_VERSION,
    .host_data = null,
    .name = "soundcraft fixture host",
    .vendor = "Seridian",
    .url = null,
    .version = null,
    .get_extension = hostGetExtension,
    .request_restart = null,
    .request_process = null,
    .request_callback = null,
};

/// An input event list backed by a slice. `bind` must run once the list has its final address.
const InputList = struct {
    events: []const *const abi.ClapEventHeader,
    api: abi.ClapInputEvents = undefined,

    fn bind(self: *InputList) void {
        self.api = .{ .ctx = self, .size = inputSize, .get = inputGet };
    }

    fn inputSize(list: *const abi.ClapInputEvents) callconv(.c) u32 {
        const self: *const InputList = @ptrCast(@alignCast(list.ctx.?));
        return @intCast(self.events.len);
    }

    fn inputGet(list: *const abi.ClapInputEvents, index: u32) callconv(.c) ?*const abi.ClapEventHeader {
        const self: *const InputList = @ptrCast(@alignCast(list.ctx.?));
        return self.events[index];
    }
};

/// An output event list that records the type of each pushed event.
const OutputList = struct {
    kinds: [8]u16 = @splat(0),
    count: usize = 0,
    api: abi.ClapOutputEvents = undefined,

    fn bind(self: *OutputList) void {
        self.api = .{ .ctx = self, .try_push = tryPush };
    }

    fn tryPush(list: *const abi.ClapOutputEvents, event: ?*const abi.ClapEventHeader) callconv(.c) bool {
        const self: *OutputList = @ptrCast(@alignCast(list.ctx.?));
        const e = event orelse return false;
        if (self.count == self.kinds.len) return false;
        self.kinds[self.count] = e.type_;
        self.count += 1;
        return true;
    }
};

/// Writes into a fixed buffer, like a host-side `clap_ostream`.
const ByteSink = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,
    api: abi.ClapOStream = undefined,

    fn bind(self: *ByteSink) void {
        self.api = .{ .ctx = self, .write = write };
    }

    fn write(stream: *const abi.ClapOStream, buffer: ?*const anyopaque, size: u64) callconv(.c) i64 {
        const self: *ByteSink = @ptrCast(@alignCast(stream.ctx.?));
        const src: [*]const u8 = @ptrCast(buffer orelse return 0);
        const n: usize = @intCast(size);
        if (self.len + n > self.bytes.len) return 0;
        @memcpy(self.bytes[self.len..][0..n], src[0..n]);
        self.len += n;
        return @intCast(size);
    }
};

/// Reads from a fixed buffer, like a host-side `clap_istream`.
const ByteSource = struct {
    bytes: []const u8,
    pos: usize = 0,
    api: abi.ClapIStream = undefined,

    fn bind(self: *ByteSource) void {
        self.api = .{ .ctx = self, .read = read };
    }

    fn read(stream: *const abi.ClapIStream, buffer: ?*anyopaque, size: u64) callconv(.c) i64 {
        const self: *ByteSource = @ptrCast(@alignCast(stream.ctx.?));
        const dst: [*]u8 = @ptrCast(buffer orelse return 0);
        const avail = self.bytes.len - self.pos;
        const n = @min(avail, @as(usize, @intCast(size)));
        @memcpy(dst[0..n], self.bytes[self.pos..][0..n]);
        self.pos += n;
        return @intCast(n);
    }
};

fn createPlugin(f: *const abi.ClapPluginFactory, id: [:0]const u8) ?*const abi.ClapPlugin {
    const create = f.create_plugin orelse return null;
    return create(f, &test_host, id.ptr);
}

fn destroyPlugin(p: *const abi.ClapPlugin) void {
    const d = p.destroy orelse return;
    d(p);
}

fn startPlugin(p: *const abi.ClapPlugin) !void {
    const activate = p.activate orelse return error.NoActivate;
    if (!activate(p, 48_000.0, 1, 512)) return error.ActivateFailed;
    const start = p.start_processing orelse return error.NoStart;
    if (!start(p)) return error.StartFailed;
}

fn ext(comptime T: type, p: *const abi.ClapPlugin, id: [:0]const u8) ?*const T {
    const get = p.get_extension orelse return null;
    const raw = get(p, id.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn header(size: u32, time: u32, kind: u16) abi.ClapEventHeader {
    return .{ .size = size, .time = time, .space_id = abi.CLAP_CORE_EVENT_SPACE_ID, .type_ = kind, .flags = 0 };
}

fn processBlock(
    p: *const abi.ClapPlugin,
    frames: u32,
    inputs: []abi.ClapAudioBuffer,
    outputs: []abi.ClapAudioBuffer,
    in_events: *const abi.ClapInputEvents,
    out_events: *const abi.ClapOutputEvents,
) abi.ClapProcessStatus {
    const process = p.process orelse @panic("plugin has no process");
    var pr: abi.ClapProcess = .{
        .steady_time = 0,
        .frames_count = frames,
        .transport = null,
        .audio_inputs = inputs.ptr,
        .audio_outputs = outputs.ptr,
        .audio_inputs_count = @intCast(inputs.len),
        .audio_outputs_count = @intCast(outputs.len),
        .in_events = in_events,
        .out_events = out_events,
    };
    return process(p, &pr);
}

// ---- tests -----------------------------------------------------------------------------------------

test "entry initialises and the factory lists the five fixture plugins" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    var buf: [8]bundle.RawDescriptor = undefined;
    const n = b.descriptors(&buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("org.soundcraft.test.gain", buf[0].id);
    try testing.expectEqualStrings("Fixture Gain", buf[0].name);
    try testing.expectEqualStrings("SoundCraft tests", buf[0].vendor);
    try testing.expectEqual(@as(usize, 2), buf[0].featureList().len);
    try testing.expectEqualStrings("stereo", buf[0].featureList()[1]);
    try testing.expectEqualStrings("org.soundcraft.test.synth", buf[1].id);
    try testing.expectEqualStrings("instrument", buf[1].featureList()[0]);
    try testing.expectEqualStrings("org.soundcraft.test.wide65ch", buf[4].id);
}

test "gain fixture: params expose Gain and Mode, report the hidden Secret, and letter Mode" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    const params = ext(abi.ClapPluginParams, p, abi.CLAP_EXT_PARAMS) orelse return error.NoParams;
    try testing.expectEqual(@as(u32, 3), params.count.?(p));

    var info: abi.ClapParamInfo = undefined;
    try testing.expect(params.get_info.?(p, 0, &info));
    try testing.expectEqual(PARAM_GAIN, info.id);
    try testing.expectEqualStrings("Gain", abi.readName(&info.name));
    try testing.expectEqual(@as(f64, 1.0), info.default_value);
    try testing.expect(params.get_info.?(p, 1, &info));
    try testing.expectEqual(PARAM_MODE, info.id);
    try testing.expect(info.flags & CLAP_PARAM_IS_ENUM != 0);
    try testing.expect(params.get_info.?(p, 2, &info));
    try testing.expectEqual(PARAM_SECRET, info.id);
    try testing.expect(info.flags & abi.CLAP_PARAM_IS_HIDDEN != 0);
    try testing.expect(!params.get_info.?(p, 3, &info));

    var value: f64 = 0;
    try testing.expect(params.get_value.?(p, PARAM_GAIN, &value));
    try testing.expectEqual(@as(f64, 1.0), value);
    var text: [8]u8 = @splat(0);
    try testing.expect(params.value_to_text.?(p, PARAM_MODE, 1.0, &text, text.len));
    try testing.expectEqualStrings("B", abi.readName(&text));
    try testing.expect(params.value_to_text.?(p, PARAM_MODE, 9.0, &text, text.len));
    try testing.expectEqualStrings("?", abi.readName(&text));
}

test "gain fixture: state saves 16 bytes, restores into a new instance, and refuses bad blobs" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    const state = ext(abi.ClapPluginState, p, abi.CLAP_EXT_STATE) orelse return error.NoState;
    const params = ext(abi.ClapPluginParams, p, abi.CLAP_EXT_PARAMS) orelse return error.NoParams;

    // Set gain 1.5 and mode 2.0 through the flush path.
    const set_gain: abi.ClapEventParamValue = .{ .header = header(@sizeOf(abi.ClapEventParamValue), 0, abi.CLAP_EVENT_PARAM_VALUE), .param_id = PARAM_GAIN, .cookie = null, .note_id = -1, .port_index = -1, .channel = -1, .key = -1, .value = 1.5 };
    const set_mode: abi.ClapEventParamValue = .{ .header = header(@sizeOf(abi.ClapEventParamValue), 0, abi.CLAP_EVENT_PARAM_VALUE), .param_id = PARAM_MODE, .cookie = null, .note_id = -1, .port_index = -1, .channel = -1, .key = -1, .value = 2.0 };
    const items = [_]*const abi.ClapEventHeader{ &set_gain.header, &set_mode.header };
    var in_list: InputList = .{ .events = &items };
    in_list.bind();
    var out_list: OutputList = .{};
    out_list.bind();
    params.flush.?(p, &in_list.api, &out_list.api);

    var sink: ByteSink = .{};
    sink.bind();
    try testing.expect(state.save.?(p, &sink.api));
    try testing.expectEqual(@as(usize, STATE_BYTES), sink.len);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), std.mem.readInt(u64, sink.bytes[0..8], .little));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.0))), std.mem.readInt(u64, sink.bytes[8..16], .little));
    try testing.expectEqualSlices(u8, sink.bytes[0..STATE_BYTES], &last_saved_state);

    // A fresh instance starts at the defaults, then takes the blob.
    const q = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(q);
    const q_state = ext(abi.ClapPluginState, q, abi.CLAP_EXT_STATE) orelse return error.NoState;
    const q_params = ext(abi.ClapPluginParams, q, abi.CLAP_EXT_PARAMS) orelse return error.NoParams;
    var source: ByteSource = .{ .bytes = sink.bytes[0..STATE_BYTES] };
    source.bind();
    try testing.expect(q_state.load.?(q, &source.api));
    var value: f64 = 0;
    try testing.expect(q_params.get_value.?(q, PARAM_GAIN, &value));
    try testing.expectEqual(@as(f64, 1.5), value);
    try testing.expect(q_params.get_value.?(q, PARAM_MODE, &value));
    try testing.expectEqual(@as(f64, 2.0), value);

    // Refusals: a short blob, a NaN gain, and an oversized blob leave the plugin as it was.
    const short = [_]u8{ 1, 2, 3, 4, 5 };
    var short_src: ByteSource = .{ .bytes = &short };
    short_src.bind();
    try testing.expect(!q_state.load.?(q, &short_src.api));
    const nan_blob: [STATE_BYTES]u8 = @splat(0xff);
    var nan_src: ByteSource = .{ .bytes = &nan_blob };
    nan_src.bind();
    try testing.expect(!q_state.load.?(q, &nan_src.api));
    const big: [4096]u8 = @splat(0);
    var big_src: ByteSource = .{ .bytes = &big };
    big_src.bind();
    try testing.expect(!q_state.load.?(q, &big_src.api));
    try testing.expect(q_params.get_value.?(q, PARAM_GAIN, &value));
    try testing.expectEqual(@as(f64, 1.5), value);
    try testing.expectEqual(@as(u32, 3), state_refusals.load(.monotonic));
}

test "gain fixture: a parameter event applies at its sample offset and is recorded" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    try startPlugin(p);

    const edit: abi.ClapEventParamValue = .{ .header = header(@sizeOf(abi.ClapEventParamValue), 2, abi.CLAP_EVENT_PARAM_VALUE), .param_id = PARAM_GAIN, .cookie = null, .note_id = -1, .port_index = -1, .channel = -1, .key = -1, .value = 2.0 };
    const items = [_]*const abi.ClapEventHeader{&edit.header};
    var in_list: InputList = .{ .events = &items };
    in_list.bind();
    var out_list: OutputList = .{};
    out_list.bind();

    var l_in: [4]f32 = @splat(0.5);
    var r_in: [4]f32 = @splat(-0.25);
    var l_out: [4]f32 = @splat(0.0);
    var r_out: [4]f32 = @splat(0.0);
    var in_ch: [2]?[*]f32 = .{ &l_in, &r_in };
    var out_ch: [2]?[*]f32 = .{ &l_out, &r_out };
    var ins = [_]abi.ClapAudioBuffer{.{ .data32 = &in_ch, .data64 = null, .channel_count = 2, .latency = 0, .constant_mask = 0 }};
    var outs = [_]abi.ClapAudioBuffer{.{ .data32 = &out_ch, .data64 = null, .channel_count = 2, .latency = 0, .constant_mask = 0 }};
    const status = processBlock(p, 4, &ins, &outs, &in_list.api, &out_list.api);
    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, status);

    // Frames 0 and 1 run at gain 1.0; the edit at offset 2 takes effect for frames 2 and 3.
    try testing.expectApproxEqAbs(@as(f32, 0.5), l_out[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l_out[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), r_out[3], 1e-6);
    try testing.expectEqual(@as(u32, 1), process_calls.load(.monotonic));

    var rec: [8]RecordedEvent = undefined;
    const got = recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u32, 2), got[0].sample_offset);
    try testing.expectEqual(abi.CLAP_EVENT_PARAM_VALUE, got[0].kind);
    try testing.expectEqual(PARAM_GAIN, got[0].param_id);
    try testing.expectEqual(@as(f64, 2.0), got[0].value);
}

test "gain fixture: latency is 3 samples; the synth reports none" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const gain = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(gain);
    const lat = ext(abi.ClapPluginLatency, gain, abi.CLAP_EXT_LATENCY) orelse return error.NoLatency;
    try testing.expectEqual(LATENCY_SAMPLES, lat.get.?(gain));
    const synth = createPlugin(b.factory, "org.soundcraft.test.synth") orelse return error.CreateFailed;
    defer destroyPlugin(synth);
    try testing.expect(ext(abi.ClapPluginLatency, synth, abi.CLAP_EXT_LATENCY) == null);
}

test "synth: note velocity and MIDI CC 7 switch the output at their sample offsets" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.synth") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    try startPlugin(p);

    const note_on: abi.ClapEventNote = .{ .header = header(@sizeOf(abi.ClapEventNote), 2, abi.CLAP_EVENT_NOTE_ON), .note_id = 0, .port_index = 0, .channel = 0, .key = 60, .velocity = 0.8 };
    const cc7: abi.ClapEventMidi = .{ .header = header(@sizeOf(abi.ClapEventMidi), 3, abi.CLAP_EVENT_MIDI), .port_index = 0, .data = .{ 0xB0, 7, 127 } };
    const items = [_]*const abi.ClapEventHeader{ &note_on.header, &cc7.header };
    var in_list: InputList = .{ .events = &items };
    in_list.bind();
    var out_list: OutputList = .{};
    out_list.bind();

    var l: [4]f32 = @splat(-1.0);
    var r: [4]f32 = @splat(-1.0);
    var out_ch: [2]?[*]f32 = .{ &l, &r };
    var outs = [_]abi.ClapAudioBuffer{.{ .data32 = &out_ch, .data64 = null, .channel_count = 2, .latency = 0, .constant_mask = 0 }};
    var no_ins: [0]abi.ClapAudioBuffer = .{};
    const status = processBlock(p, 4, &no_ins, &outs, &in_list.api, &out_list.api);
    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, status);

    try testing.expectApproxEqAbs(@as(f32, 0.0), l[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), l[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), r[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[3], 1e-6);

    var rec: [8]RecordedEvent = undefined;
    const got = recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_ON, got[0].kind);
    try testing.expectEqual(@as(i16, 60), got[0].key);
    try testing.expectEqual(@as(u32, 3), got[1].sample_offset);
    try testing.expectEqualSlices(u8, &.{ 0xB0, 7, 127 }, &got[1].midi);
}

test "gain fixture GUI: floating create, show, hide, destroy; show requests a resize and queues the edit" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.gain") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    const gui = ext(abi.ClapPluginGui, p, abi.CLAP_EXT_GUI) orelse return error.NoGui;

    try testing.expect(gui.is_api_supported.?(p, "cocoa", true));
    try testing.expect(!gui.is_api_supported.?(p, "cocoa", false));
    try testing.expect(gui.create.?(p, "cocoa", true));
    try testing.expect(gui.set_scale.?(p, 2.0));
    try testing.expect(!gui.set_scale.?(p, 0.0));
    gui.suggest_title.?(p, "Fixture");
    try testing.expect(gui.show.?(p));
    try testing.expectEqual(GUI_WIDTH, host_last_width.load(.monotonic));
    try testing.expectEqual(GUI_HEIGHT, host_last_height.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), host_resize_calls.load(.monotonic));

    // The queued edit reaches the host on the next process call: a gain param event, then a note.
    try startPlugin(p);
    var l_in: [2]f32 = @splat(1.0);
    var l_out: [2]f32 = @splat(0.0);
    var in_ch: [1]?[*]f32 = .{&l_in};
    var out_ch: [1]?[*]f32 = .{&l_out};
    var ins = [_]abi.ClapAudioBuffer{.{ .data32 = &in_ch, .data64 = null, .channel_count = 1, .latency = 0, .constant_mask = 0 }};
    var outs = [_]abi.ClapAudioBuffer{.{ .data32 = &out_ch, .data64 = null, .channel_count = 1, .latency = 0, .constant_mask = 0 }};
    var in_list: InputList = .{ .events = &.{} };
    in_list.bind();
    var out_list: OutputList = .{};
    out_list.bind();
    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, processBlock(p, 2, &ins, &outs, &in_list.api, &out_list.api));
    try testing.expectEqual(@as(usize, 2), out_list.count);
    try testing.expectEqual(abi.CLAP_EVENT_PARAM_VALUE, out_list.kinds[0]);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_END, out_list.kinds[1]);
    // The edit set the gain to 0.25 for this block.
    try testing.expectApproxEqAbs(@as(f32, 0.25), l_out[0], 1e-6);

    try testing.expect(gui.hide.?(p));
    gui.destroy.?(p);
    try testing.expectEqualSlices(GuiOp, &.{ .create, .show, .hide, .destroy }, guiLog());
    try testing.expectEqual(@as(u32, 1), gui_creates.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), gui_destroys.load(.monotonic));
}

test "wide65ch: fills every output channel with 1.0 when the layout matches, -1.0 when not" {
    reset();
    var b = try bundle.Bundle.fromEntry(&entry, "");
    defer b.deinit();
    const p = createPlugin(b.factory, "org.soundcraft.test.wide65ch") orelse return error.CreateFailed;
    defer destroyPlugin(p);
    try startPlugin(p);

    const frames = 4;
    var in_data: [65 * frames]f32 = @splat(0.5);
    var out_data: [65 * frames]f32 = @splat(0.0);
    var in_ptrs: [65]?[*]f32 = undefined;
    var out_ptrs: [65]?[*]f32 = undefined;
    for (0..65) |c| {
        in_ptrs[c] = in_data[c * frames ..].ptr;
        out_ptrs[c] = out_data[c * frames ..].ptr;
    }
    var ins = [_]abi.ClapAudioBuffer{.{ .data32 = &in_ptrs, .data64 = null, .channel_count = 65, .latency = 0, .constant_mask = 0 }};
    var outs = [_]abi.ClapAudioBuffer{.{ .data32 = &out_ptrs, .data64 = null, .channel_count = 65, .latency = 0, .constant_mask = 0 }};
    var in_list: InputList = .{ .events = &.{} };
    in_list.bind();
    var out_list: OutputList = .{};
    out_list.bind();

    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, processBlock(p, frames, &ins, &outs, &in_list.api, &out_list.api));
    for (out_data) |x| try testing.expectEqual(@as(f32, 1.0), x);

    // A host that feeds 2 channels where 65 were advertised gets -1.0 everywhere.
    ins[0].channel_count = 2;
    for (out_data[0..]) |*x| x.* = 0.0;
    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, processBlock(p, frames, &ins, &outs, &in_list.api, &out_list.api));
    for (out_data) |x| try testing.expectEqual(@as(f32, -1.0), x);
}
