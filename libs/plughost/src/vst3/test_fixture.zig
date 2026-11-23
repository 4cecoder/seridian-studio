// Translated to Zig from soundcraft/crates/vst3-host/tests/fixture/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Test-only VST3 plugin for plughost, written in Zig with hand-written COM vtables over
//! `abi.zig`. There is no dylib: the fixture is an in-process factory (`getPluginFactory`) plus
//! the module entry/exit pair (`moduleEntry`, `moduleExit`), and `adopt` registers it with a
//! `module.Registry` the way a loaded binary would be, so the host can create instances without
//! `dlopen`.
//!
//! Classes (the same six as the Rust fixture):
//!
//! - "Fixture Gain" (`Fx`, `GAIN_CID`): stereo or mono in, out = in * gain, with a separate edit
//!   controller (`GAIN_CTRL_CID`) connected through `IConnectionPoint`. Params: 7 "Gain" (plain
//!   0..2, linear, units dB), 3 "Mode" (3 steps A/B/C), 12 "Freq" (20..20000 Hz, log), 9 hidden,
//!   11 bypass, 13 "Level" and 14 "Drive" (identity mappings with their own text). The component
//!   starts at normalized gain 0.25 (plain 0.5) although the declared default is 0.5. Latency 3.
//!   State: the component stores the gain (one LE f64), the controller the Freq value (one LE
//!   f64). The controller has an editor view (`IPlugView`, 320x240, no drawing) accepting
//!   NSView/HWND/X11EmbedWindowID.
//! - "Fixture Synth" (`Instrument|Synth`, `SYNTH_CID`): one component that is also its edit
//!   controller and `IMidiMapping` (CC 7 -> hidden parameter 1). No audio input, one stereo
//!   output, one event input; every output sample is the velocity of the held note
//!   (sample-accurate), 0 when none. Poly pressure and parameter 1 set the level too.
//! - "Fixture Wide 16x64", "Fixture Wide 17 buses", "Fixture Wide 65 channels" (`Fx`):
//!   `process` writes 1.0 into every channel of output bus 0 when the host's buffers match the
//!   advertised layout, -1.0 when they do not. Latency 3.
//!
//! Test hooks beyond the Rust fixture, all plain globals (see `reset`): `nan_output`,
//! `bogus_latency`, `refuse_state`, `emit_param_output`, `view_resizable`; counters; the ring of
//! recorded events with their `sampleOffset`s; the last input parameter point.
//!
//! The Rust fixture aborts the process (`_exit(3)`) when the host breaks the module lifecycle or
//! when one of its `assert!`s fails. In-process that would kill the test runner, so a violation
//! bumps `violations` (and stores `last_violation`), the module exit returns `false`, and a
//! failed assert makes the call return an error code and bumps `contract_failures`. Tests
//! assert both are zero. The `VST3_FIXTURE_LATE_STATE` / `atexit` checks have no in-process
//! equivalent and are not translated.
//!
//! Every COM object is one heap `Object` carrying up to seven interface slots (an `Iface` is
//! `{ vtbl, owner }`, so `this` of any interface leads back to the object). One reference count
//! per object is shared by all its interfaces, like the `vst3` crate's `ComWrapper`.
//!
//! Real-time: `process` of every class only touches fixed storage and atomics; objects are
//! allocated in `createInstance`/`createView`, which run on the control thread.

const std = @import("std");
const abi = @import("abi.zig");
const module = @import("module.zig");

const Atomic = std.atomic.Value;
const Counter = Atomic(i64);

// ---- class ids -------------------------------------------------------------------------------

pub const GAIN_CID: abi.TUID = abi.uid(0x5C0A1D00, 0x11112222, 0x33334444, 0x55556666);
pub const GAIN_CTRL_CID: abi.TUID = abi.uid(0x5C0A1D01, 0x11112222, 0x33334444, 0x55556666);
pub const SYNTH_CID: abi.TUID = abi.uid(0x5C0A1D02, 0x11112222, 0x33334444, 0x55556666);
pub const WIDE16_CID: abi.TUID = abi.uid(0x5C0A1D03, 0x11112222, 0x33334444, 0x55556666);
pub const WIDE17_CID: abi.TUID = abi.uid(0x5C0A1D04, 0x11112222, 0x33334444, 0x55556666);
pub const WIDE65_CID: abi.TUID = abi.uid(0x5C0A1D05, 0x11112222, 0x33334444, 0x55556666);

/// The synth's hidden parameter that MIDI CC 7 drives.
pub const VOLUME_PARAM: abi.ParamID = 1;
/// Latency reported with `bogus_latency` set.
pub const BOGUS_LATENCY: u32 = 0xFFFF_FFF0;
/// Latency of the gain and wide effects.
pub const LATENCY: u32 = 3;

const kMono: abi.SpeakerArrangement = 1 << 19;
const kStereo: abi.SpeakerArrangement = 3;
const kUnicodeFactory: i32 = 1 << 4;
const kManyInstances: i32 = 0x7FFF_FFFF;

// ---- test hooks (plain globals) --------------------------------------------------------------

/// Plugin objects alive: components, controllers, views.
pub var objects_alive: Counter = .init(0);
/// Factories handed out and not yet released.
pub var factories_alive: Counter = .init(0);
/// Module entries minus module exits.
pub var entered: Counter = .init(0);
/// The OS thread that ran the outermost module entry.
pub var entry_thread: Atomic(usize) = .init(0);
/// Host contract violations seen by the module lifecycle check (the Rust fixture exits with 3).
pub var violations: Atomic(u32) = .init(0);
/// Description of the latest violation.
pub var last_violation: []const u8 = "";
/// Failed asserts of the Rust fixture (null host context, `removed` without `attached`, ...).
pub var contract_failures: Atomic(u32) = .init(0);

/// Switches. Set before the call under test; `reset` clears them.
pub var nan_output: Atomic(bool) = .init(false);
pub var bogus_latency: Atomic(bool) = .init(false);
pub var refuse_state: Atomic(bool) = .init(false);
pub var emit_param_output: Atomic(bool) = .init(false);
pub var view_resizable: Atomic(bool) = .init(false);

/// Counters.
pub var process_calls: Atomic(u32) = .init(0);
pub var state_saves: Atomic(u32) = .init(0);
pub var state_loads: Atomic(u32) = .init(0);
pub var state_refusals: Atomic(u32) = .init(0);
pub var connects: Atomic(u32) = .init(0);
pub var handler_edits: Atomic(u32) = .init(0);
pub var view_attaches: Atomic(u32) = .init(0);
pub var view_removes: Atomic(u32) = .init(0);
pub var view_resizes: Atomic(u32) = .init(0);
pub var view_last_width: Atomic(i32) = .init(0);
pub var view_last_height: Atomic(i32) = .init(0);
pub var events_seen: Atomic(u32) = .init(0);
pub var param_points_seen: Atomic(u32) = .init(0);
/// The latest input parameter point the gain effect read.
pub var last_param_id: Atomic(u32) = .init(0);
pub var last_param_offset: Atomic(i32) = .init(0);
pub var last_param_value_bits: Atomic(u64) = .init(0);

/// One event the synth received, with its sample offset.
pub const RecordedEvent = struct {
    type: u16 = 0,
    sample_offset: i32 = 0,
    pitch: i16 = 0,
    /// Velocity (note on/off) or pressure (poly pressure).
    value: f32 = 0,
};
pub const RECORD_CAP = 64;
pub var recorded: [RECORD_CAP]RecordedEvent = @splat(.{});
pub var recorded_len: Atomic(usize) = .init(0);

/// Clears the switches, counters and recordings. The alive counters and the module entry count
/// are state, not hooks, and are left alone.
pub fn reset() void {
    nan_output.store(false, .monotonic);
    bogus_latency.store(false, .monotonic);
    refuse_state.store(false, .monotonic);
    emit_param_output.store(false, .monotonic);
    view_resizable.store(false, .monotonic);
    inline for (.{ &process_calls, &state_saves, &state_loads, &state_refusals, &connects, &handler_edits, &view_attaches, &view_removes, &view_resizes, &events_seen, &param_points_seen, &violations, &contract_failures }) |c| c.store(0, .monotonic);
    view_last_width.store(0, .monotonic);
    view_last_height.store(0, .monotonic);
    last_param_id.store(0, .monotonic);
    last_param_offset.store(0, .monotonic);
    last_param_value_bits.store(0, .monotonic);
    recorded_len.store(0, .monotonic);
    recorded = @splat(.{});
    last_violation = "";
}

fn contractFailure() void {
    _ = contract_failures.fetchAdd(1, .monotonic);
}

fn recordEvent(e: RecordedEvent) void {
    _ = events_seen.fetchAdd(1, .monotonic);
    const i = recorded_len.fetchAdd(1, .monotonic);
    if (i < RECORD_CAP) recorded[i] = e;
}

/// The events recorded since `reset` (at most `RECORD_CAP`).
pub fn recordedEvents() []const RecordedEvent {
    return recorded[0..@min(recorded_len.load(.monotonic), RECORD_CAP)];
}

// ---- helpers ---------------------------------------------------------------------------------

fn copyC8(src: []const u8, dst: []u8) void {
    @memset(dst, 0);
    if (dst.len == 0) return;
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
}

fn ldF64(a: *const Atomic(u64)) f64 {
    return @bitCast(a.load(.monotonic));
}

fn stF64(a: *Atomic(u64), v: f64) void {
    a.store(@bitCast(v), .monotonic);
}

fn audioBus(bus: *abi.BusInfo, dir: abi.BusDirection, name: []const u8, channels: i32) void {
    bus.mediaType = abi.kAudio;
    bus.direction = dir;
    bus.channelCount = channels;
    abi.writeC16(name, &bus.name);
    bus.busType = abi.kMain;
    bus.flags = abi.kDefaultActive;
}

/// Channel `ch` of a bus as a slice, null when the host gave no such channel.
fn chan(bus: *const abi.AudioBusBuffers, ch: usize, frames: usize) ?[]f32 {
    if (bus.numChannels < 0 or ch >= @as(usize, @intCast(bus.numChannels))) return null;
    const table = bus.channelBuffers.channelBuffers32 orelse return null;
    const p = table[ch] orelse return null;
    return p[0..frames];
}

/// Reads exactly one LE f64 from a stream.
fn readF64(s: *abi.IBStream) ?f64 {
    var bytes: [8]u8 = undefined;
    var n: i32 = 0;
    if (s.read(&bytes, 8, &n) != abi.kResultOk or n != 8) return null;
    return @bitCast(std.mem.readInt(u64, &bytes, .little));
}

fn writeF64(s: *abi.IBStream, v: f64) abi.tresult {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(v), .little);
    var n: i32 = 0;
    return s.write(&bytes, 8, &n);
}

// ---- objects ---------------------------------------------------------------------------------

const Kind = enum { gain, gain_ctrl, synth, wide, view, factory };

/// One interface slot of an object: a COM interface pointer is a pointer to this.
const Iface = extern struct {
    vtbl: *const anyopaque,
    obj: *Object,
};

const Object = struct {
    kind: Kind,
    refs: Atomic(u32) = .init(1),
    counter: *Counter,
    comp: Iface,
    proc: Iface,
    conn: Iface,
    ctrl: Iface,
    midi: Iface,
    view_if: Iface,
    fac: Iface,
    /// Normalized gain (plain = 2 x normalized), f64 bits.
    gain: Atomic(u64) = .init(0),
    freq: Atomic(u64) = .init(0),
    level: Atomic(u32) = .init(0),
    arrangement: Atomic(u64) = .init(kStereo),
    attached: Atomic(bool) = .init(false),
    buses: i32 = 0,
    channels: i32 = 0,
};

const allocator = std.heap.smp_allocator;

fn ob(this: anytype) *Object {
    const i: *const Iface = @ptrCast(@alignCast(this));
    return i.obj;
}

fn newObject(kind: Kind, counter: *Counter) ?*Object {
    const o = allocator.create(Object) catch return null;
    o.* = .{
        .kind = kind,
        .counter = counter,
        .comp = .{ .vtbl = &comp_vtbl, .obj = o },
        .proc = .{ .vtbl = &proc_vtbl, .obj = o },
        .conn = .{ .vtbl = &conn_vtbl, .obj = o },
        .ctrl = .{ .vtbl = &ctrl_vtbl, .obj = o },
        .midi = .{ .vtbl = &midi_vtbl, .obj = o },
        .view_if = .{ .vtbl = &view_vtbl, .obj = o },
        .fac = .{ .vtbl = &fac_vtbl, .obj = o },
    };
    _ = counter.fetchAdd(1, .seq_cst);
    return o;
}

fn objRelease(o: *Object) u32 {
    const prev = o.refs.fetchSub(1, .acq_rel);
    std.debug.assert(prev > 0);
    if (prev == 1) {
        const counter = o.counter;
        allocator.destroy(o);
        _ = counter.fetchSub(1, .seq_cst);
    }
    return prev - 1;
}

fn same(id: *const abi.TUID, comptime T: type) bool {
    return std.mem.eql(u8, id, &T.iid);
}

fn queryIface(o: *Object, id: *const abi.TUID) ?*anyopaque {
    const has_comp = o.kind == .gain or o.kind == .synth or o.kind == .wide;
    if (same(id, abi.FUnknown)) {
        return switch (o.kind) {
            .gain, .synth, .wide => &o.comp,
            .gain_ctrl => &o.ctrl,
            .view => &o.view_if,
            .factory => &o.fac,
        };
    }
    if (same(id, abi.IPluginBase)) {
        if (has_comp) return &o.comp;
        if (o.kind == .gain_ctrl) return &o.ctrl;
        return null;
    }
    if (same(id, abi.IComponent) and has_comp) return &o.comp;
    if (same(id, abi.IAudioProcessor) and has_comp) return &o.proc;
    if (same(id, abi.IConnectionPoint) and (o.kind == .gain or o.kind == .gain_ctrl)) return &o.conn;
    if (same(id, abi.IEditController) and (o.kind == .gain_ctrl or o.kind == .synth)) return &o.ctrl;
    if (same(id, abi.IMidiMapping) and o.kind == .synth) return &o.midi;
    if (same(id, abi.IPlugView) and o.kind == .view) return &o.view_if;
    if (o.kind == .factory and (same(id, abi.IPluginFactory) or same(id, abi.IPluginFactory2) or same(id, abi.IPluginFactory3))) return &o.fac;
    return null;
}

fn objQuery(o: *Object, id: *const abi.TUID, out: *?*anyopaque) abi.tresult {
    const p = queryIface(o, id) orelse {
        out.* = null;
        return abi.kNoInterface;
    };
    _ = o.refs.fetchAdd(1, .monotonic);
    out.* = p;
    return abi.kResultOk;
}

fn unkQuery(this: *abi.FUnknown, id: *const abi.TUID, out: *?*anyopaque) callconv(.c) abi.tresult {
    return objQuery(ob(this), id, out);
}
fn unkAddRef(this: *abi.FUnknown) callconv(.c) u32 {
    return ob(this).refs.fetchAdd(1, .monotonic) + 1;
}
fn unkRelease(this: *abi.FUnknown) callconv(.c) u32 {
    return objRelease(ob(this));
}

const unk_vtbl: abi.FUnknown.Vtbl = .{ .queryInterface = unkQuery, .addRef = unkAddRef, .release = unkRelease };

// ---- IPluginBase -----------------------------------------------------------------------------

fn baseInitialize(this: *abi.IPluginBase, context: ?*abi.FUnknown) callconv(.c) abi.tresult {
    // The Rust gain processor asserts a non-null host context.
    if (ob(this).kind == .gain and context == null) {
        contractFailure();
        return abi.kInvalidArgument;
    }
    return abi.kResultOk;
}
fn baseTerminate(_: *abi.IPluginBase) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
const base_vtbl: abi.IPluginBase.Vtbl = .{ .unknown = unk_vtbl, .initialize = baseInitialize, .terminate = baseTerminate };

// ---- IConnectionPoint ------------------------------------------------------------------------

fn connConnect(_: *abi.IConnectionPoint, other: ?*abi.IConnectionPoint) callconv(.c) abi.tresult {
    if (other == null) return abi.kInvalidArgument;
    _ = connects.fetchAdd(1, .monotonic);
    return abi.kResultOk;
}
fn connDisconnect(_: *abi.IConnectionPoint, _: ?*abi.IConnectionPoint) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn connNotify(_: *abi.IConnectionPoint, _: ?*abi.IMessage) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
const conn_vtbl: abi.IConnectionPoint.Vtbl = .{
    .unknown = unk_vtbl,
    .connect = @ptrCast(&connConnect),
    .disconnect = @ptrCast(&connDisconnect),
    .notify = connNotify,
};

// ---- IComponent ------------------------------------------------------------------------------

fn compControllerClassId(this: *abi.IComponent, out: *abi.TUID) callconv(.c) abi.tresult {
    if (ob(this).kind != .gain) return abi.kNotImplemented;
    out.* = GAIN_CTRL_CID;
    return abi.kResultOk;
}
fn compSetIoMode(_: *abi.IComponent, _: abi.IoMode) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn compBusCount(this: *abi.IComponent, media: abi.MediaType, dir: abi.BusDirection) callconv(.c) i32 {
    const o = ob(this);
    switch (o.kind) {
        .gain => return if (media == abi.kAudio) 1 else 0,
        .synth => {
            const out = dir == abi.kOutput;
            if (media == abi.kAudio and out) return 1;
            if (media == abi.kEvent and !out) return 1;
            return 0;
        },
        .wide => return if (media == abi.kAudio) o.buses else 0,
        else => return 0,
    }
}
fn compBusInfo(this: *abi.IComponent, media: abi.MediaType, dir: abi.BusDirection, index: i32, bus: *abi.BusInfo) callconv(.c) abi.tresult {
    const o = ob(this);
    switch (o.kind) {
        .gain => {
            if (media != abi.kAudio or index != 0) return abi.kInvalidArgument;
            audioBus(bus, dir, "Main", 2);
            return abi.kResultOk;
        },
        .synth => {
            if (index != 0) return abi.kInvalidArgument;
            if (media == abi.kAudio and dir == abi.kOutput) {
                audioBus(bus, dir, "Out", 2);
                return abi.kResultOk;
            }
            if (media == abi.kEvent and dir == abi.kInput) {
                bus.mediaType = media;
                bus.direction = dir;
                bus.channelCount = 16;
                abi.writeC16("Notes", &bus.name);
                bus.busType = abi.kMain;
                bus.flags = abi.kDefaultActive;
                return abi.kResultOk;
            }
            return abi.kInvalidArgument;
        },
        .wide => {
            if (media != abi.kAudio or index < 0 or index >= o.buses) return abi.kInvalidArgument;
            audioBus(bus, dir, "Wide", o.channels);
            return abi.kResultOk;
        },
        else => return abi.kInvalidArgument,
    }
}
fn compRoutingInfo(_: *abi.IComponent, _: *abi.RoutingInfo, _: *abi.RoutingInfo) callconv(.c) abi.tresult {
    return abi.kNotImplemented;
}
fn compActivateBus(_: *abi.IComponent, _: abi.MediaType, _: abi.BusDirection, _: i32, _: abi.TBool) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn compSetActive(_: *abi.IComponent, _: abi.TBool) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn compSetState(this: *abi.IComponent, state: ?*abi.IBStream) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind != .gain) return abi.kResultOk;
    const s = state orelse return abi.kInvalidArgument;
    if (refuse_state.load(.monotonic)) {
        _ = state_refusals.fetchAdd(1, .monotonic);
        return abi.kResultFalse;
    }
    const g = readF64(s) orelse return abi.kResultFalse;
    if (!(g >= 0.0 and g <= 1.0)) return abi.kResultFalse;
    stF64(&o.gain, g);
    _ = state_loads.fetchAdd(1, .monotonic);
    return abi.kResultOk;
}
fn compGetState(this: *abi.IComponent, state: ?*abi.IBStream) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind != .gain) return abi.kResultOk;
    const s = state orelse return abi.kInvalidArgument;
    _ = state_saves.fetchAdd(1, .monotonic);
    return writeF64(s, ldF64(&o.gain));
}
const comp_vtbl: abi.IComponent.Vtbl = .{
    .base = base_vtbl,
    .getControllerClassId = compControllerClassId,
    .setIoMode = compSetIoMode,
    .getBusCount = compBusCount,
    .getBusInfo = compBusInfo,
    .getRoutingInfo = compRoutingInfo,
    .activateBus = compActivateBus,
    .setActive = compSetActive,
    .setState = @ptrCast(&compSetState),
    .getState = @ptrCast(&compGetState),
};

// ---- IAudioProcessor -------------------------------------------------------------------------

fn procSetBusArrangements(this: *abi.IAudioProcessor, ins: ?[*]abi.SpeakerArrangement, n_in: i32, outs: ?[*]abi.SpeakerArrangement, n_out: i32) callconv(.c) abi.tresult {
    const o = ob(this);
    switch (o.kind) {
        .gain => {
            if (n_in != 1 or n_out != 1) return abi.kResultFalse;
            const i = (ins orelse return abi.kResultFalse)[0];
            const out = (outs orelse return abi.kResultFalse)[0];
            if (i != out or (i != kStereo and i != kMono)) return abi.kResultFalse;
            o.arrangement.store(i, .monotonic);
            return abi.kResultTrue;
        },
        .synth => {
            if (n_in == 0 and n_out == 1) {
                if (outs) |p| if (p[0] == kStereo) return abi.kResultTrue;
            }
            return abi.kResultFalse;
        },
        else => return abi.kResultFalse,
    }
}
fn procGetBusArrangement(this: *abi.IAudioProcessor, dir: abi.BusDirection, index: i32, arr: *abi.SpeakerArrangement) callconv(.c) abi.tresult {
    const o = ob(this);
    switch (o.kind) {
        .gain => {
            if (index != 0) return abi.kInvalidArgument;
            arr.* = o.arrangement.load(.monotonic);
            return abi.kResultOk;
        },
        .synth => {
            if (dir != abi.kOutput or index != 0) return abi.kInvalidArgument;
            arr.* = kStereo;
            return abi.kResultOk;
        },
        else => return abi.kNotImplemented,
    }
}
fn procCanProcessSampleSize(_: *abi.IAudioProcessor, size: i32) callconv(.c) abi.tresult {
    return if (size == abi.kSample32) abi.kResultOk else abi.kNotImplemented;
}
fn procLatency(this: *abi.IAudioProcessor) callconv(.c) u32 {
    if (ob(this).kind == .synth) return 0;
    return if (bogus_latency.load(.monotonic)) BOGUS_LATENCY else LATENCY;
}
fn procSetup(this: *abi.IAudioProcessor, setup: *abi.ProcessSetup) callconv(.c) abi.tresult {
    if (ob(this).kind == .gain) {
        if (setup.symbolicSampleSize != abi.kSample32 or setup.maxSamplesPerBlock <= 0 or !(setup.sampleRate > 0.0)) {
            contractFailure();
            return abi.kInvalidArgument;
        }
    }
    return abi.kResultOk;
}
fn procSetProcessing(this: *abi.IAudioProcessor, _: abi.TBool) callconv(.c) abi.tresult {
    return if (ob(this).kind == .gain) abi.kNotImplemented else abi.kResultOk;
}
fn procTail(_: *abi.IAudioProcessor) callconv(.c) u32 {
    return 0;
}

fn processGain(o: *Object, d: *abi.ProcessData) abi.tresult {
    if (d.processContext == null) contractFailure();
    if (d.inputParameterChanges) |changes| {
        const count = changes.getParameterCount();
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const q = changes.getParameterData(i) orelse continue;
            const n = q.getPointCount();
            if (n <= 0) continue;
            var off: i32 = 0;
            var v: f64 = 0;
            if (q.getPoint(n - 1, &off, &v) != abi.kResultOk) continue;
            const id = q.getParameterId();
            _ = param_points_seen.fetchAdd(1, .monotonic);
            last_param_id.store(id, .monotonic);
            last_param_offset.store(off, .monotonic);
            last_param_value_bits.store(@bitCast(v), .monotonic);
            if (id == 7) stF64(&o.gain, v);
        }
    }
    if (emit_param_output.load(.monotonic)) {
        if (d.outputParameterChanges) |oc| {
            var idx: i32 = 0;
            const pid: abi.ParamID = 7;
            if (oc.addParameterData(&pid, &idx)) |q| _ = q.addPoint(0, ldF64(&o.gain), null);
        }
    }
    if (d.numInputs != 1 or d.numOutputs != 1) return abi.kResultOk;
    const ins = d.inputs orelse return abi.kResultOk;
    const outs = d.outputs orelse return abi.kResultOk;
    const frames: usize = @intCast(@max(d.numSamples, 0));
    const g: f32 = 2.0 * @as(f32, @floatCast(ldF64(&o.gain)));
    const n_ch: usize = @intCast(@max(@min(ins[0].numChannels, outs[0].numChannels), 0));
    const nan = nan_output.load(.monotonic);
    var ch: usize = 0;
    while (ch < n_ch) : (ch += 1) {
        const in = chan(&ins[0], ch, frames) orelse continue;
        const out = chan(&outs[0], ch, frames) orelse continue;
        for (in, out) |x, *y| y.* = if (nan) std.math.nan(f32) else g * x;
    }
    return abi.kResultOk;
}

fn processSynth(o: *Object, d: *abi.ProcessData) abi.tresult {
    if (d.numOutputs != 1) return abi.kResultOk;
    const outs = d.outputs orelse return abi.kResultOk;
    const frames: usize = @intCast(@max(d.numSamples, 0));

    // Seridian: fixed storage, the Rust code collected the events into a Vec here.
    var events: [SYNTH_EVENT_CAP]abi.Event = undefined;
    var n_events: usize = 0;
    if (d.inputEvents) |list| {
        const count = list.getEventCount();
        var i: i32 = 0;
        while (i < count and n_events < SYNTH_EVENT_CAP) : (i += 1) {
            var e = std.mem.zeroes(abi.Event);
            if (list.getEvent(i, &e) != abi.kResultOk) continue;
            events[n_events] = e;
            n_events += 1;
            switch (e.type) {
                abi.EventTypes.kNoteOnEvent => recordEvent(.{ .type = e.type, .sample_offset = e.sampleOffset, .pitch = e.payload.noteOn.pitch, .value = e.payload.noteOn.velocity }),
                abi.EventTypes.kNoteOffEvent => recordEvent(.{ .type = e.type, .sample_offset = e.sampleOffset, .pitch = e.payload.noteOff.pitch, .value = e.payload.noteOff.velocity }),
                abi.EventTypes.kPolyPressureEvent => recordEvent(.{ .type = e.type, .sample_offset = e.sampleOffset, .pitch = e.payload.polyPressure.pitch, .value = e.payload.polyPressure.pressure }),
                else => recordEvent(.{ .type = e.type, .sample_offset = e.sampleOffset }),
            }
        }
    }
    var volume: ?struct { at: i32, v: f32 } = null;
    if (d.inputParameterChanges) |changes| {
        const count = changes.getParameterCount();
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const q = changes.getParameterData(i) orelse continue;
            var at: i32 = 0;
            var v: f64 = 0;
            if (q.getParameterId() == VOLUME_PARAM and q.getPoint(0, &at, &v) == abi.kResultOk) {
                volume = .{ .at = @max(at, 0), .v = @floatCast(v) };
            }
        }
    }
    var level: f32 = @bitCast(o.level.load(.monotonic));
    const first = chan(&outs[0], 0, frames);
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const at: i32 = @intCast(i);
        for (events[0..n_events]) |e| {
            if (e.sampleOffset != at) continue;
            switch (e.type) {
                abi.EventTypes.kNoteOnEvent => level = e.payload.noteOn.velocity,
                abi.EventTypes.kNoteOffEvent => level = 0.0,
                abi.EventTypes.kPolyPressureEvent => level = e.payload.polyPressure.pressure,
                else => {},
            }
        }
        if (volume) |v| if (v.at == at) {
            level = v.v;
        };
        if (first) |f| f[i] = if (nan_output.load(.monotonic)) std.math.nan(f32) else level;
    }
    o.level.store(@bitCast(level), .monotonic);
    if (first) |f| {
        var ch: usize = 1;
        const n_ch: usize = @intCast(@max(outs[0].numChannels, 0));
        while (ch < n_ch) : (ch += 1) {
            if (chan(&outs[0], ch, frames)) |c| @memcpy(c, f);
        }
    }
    return abi.kResultOk;
}

/// Most input events the synth reads per block.
const SYNTH_EVENT_CAP = 256;

fn wideFits(o: *Object, bufs: ?[*]abi.AudioBusBuffers, n: i32) bool {
    if (n != o.buses) return false;
    if (n == 0) return true;
    const b = bufs orelse return false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        if (b[i].numChannels != o.channels) return false;
    }
    return true;
}

fn processWide(o: *Object, d: *abi.ProcessData) abi.tresult {
    const ok = wideFits(o, d.inputs, d.numInputs) and wideFits(o, d.outputs, d.numOutputs);
    if (d.numOutputs > 0) {
        const outs = d.outputs orelse return abi.kResultOk;
        const frames: usize = @intCast(@max(d.numSamples, 0));
        const v: f32 = if (nan_output.load(.monotonic)) std.math.nan(f32) else if (ok) 1.0 else -1.0;
        var ch: usize = 0;
        const n_ch: usize = @intCast(@max(outs[0].numChannels, 0));
        while (ch < n_ch) : (ch += 1) {
            if (chan(&outs[0], ch, frames)) |c| @memset(c, v);
        }
    }
    return abi.kResultOk;
}

fn procProcess(this: *abi.IAudioProcessor, data: *abi.ProcessData) callconv(.c) abi.tresult {
    const o = ob(this);
    _ = process_calls.fetchAdd(1, .monotonic);
    return switch (o.kind) {
        .gain => processGain(o, data),
        .synth => processSynth(o, data),
        .wide => processWide(o, data),
        else => abi.kResultOk,
    };
}

const proc_vtbl: abi.IAudioProcessor.Vtbl = .{
    .unknown = unk_vtbl,
    .setBusArrangements = procSetBusArrangements,
    .getBusArrangement = procGetBusArrangement,
    .canProcessSampleSize = procCanProcessSampleSize,
    .getLatencySamples = procLatency,
    .setupProcessing = procSetup,
    .setProcessing = procSetProcessing,
    .process = procProcess,
    .getTailSamples = procTail,
};

// ---- IMidiMapping ----------------------------------------------------------------------------

fn midiAssignment(_: *abi.IMidiMapping, bus: i32, channel: i16, ctrl: i16, id: *abi.ParamID) callconv(.c) abi.tresult {
    if (bus == 0 and channel == 0 and ctrl == 7) {
        id.* = VOLUME_PARAM;
        return abi.kResultOk;
    }
    return abi.kResultFalse;
}
const midi_vtbl: abi.IMidiMapping.Vtbl = .{ .unknown = unk_vtbl, .getMidiControllerAssignment = midiAssignment };

// ---- IEditController -------------------------------------------------------------------------

const ParamDef = struct { id: u32, title: []const u8, units: []const u8, steps: i32, def: f64, flags: i32 };

const GAIN_PARAMS = [_]ParamDef{
    .{ .id = 7, .title = "Gain", .units = "dB", .steps = 0, .def = 0.5, .flags = abi.kCanAutomate },
    .{ .id = 9, .title = "Secret", .units = "", .steps = 0, .def = 0.0, .flags = abi.kIsHidden },
    .{ .id = 3, .title = "Mode", .units = "", .steps = 2, .def = 0.0, .flags = abi.kIsList },
    .{ .id = 11, .title = "Bypass", .units = "", .steps = 1, .def = 0.0, .flags = abi.kIsBypass },
    .{ .id = 12, .title = "Freq", .units = "Hz", .steps = 0, .def = 0.5, .flags = 0 },
    // Like JUCE and the SDK's default `Parameter`: no plain mapping (identity), so the real range
    // is only in the plugin's own text (-24..+24, the default 0.375 is -6), without the units.
    .{ .id = 13, .title = "Level", .units = "dB", .steps = 0, .def = 0.375, .flags = abi.kCanAutomate },
    // Identity too, but its text already carries the units (0..12 dB).
    .{ .id = 14, .title = "Drive", .units = "dB", .steps = 0, .def = 0.0, .flags = abi.kCanAutomate },
};

fn ctrlSetComponentState(this: *abi.IEditController, state: ?*abi.IBStream) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind != .gain_ctrl) return abi.kResultOk;
    const s = state orelse return abi.kInvalidArgument;
    if (readF64(s)) |g| stF64(&o.gain, g);
    return abi.kResultOk;
}
fn ctrlSetState(this: *abi.IEditController, state: ?*abi.IBStream) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind != .gain_ctrl) return abi.kResultOk;
    const s = state orelse return abi.kInvalidArgument;
    if (refuse_state.load(.monotonic)) {
        _ = state_refusals.fetchAdd(1, .monotonic);
        return abi.kResultFalse;
    }
    if (readF64(s)) |f| {
        stF64(&o.freq, std.math.clamp(f, 0.0, 1.0));
        _ = state_loads.fetchAdd(1, .monotonic);
    }
    return abi.kResultOk;
}
fn ctrlGetState(this: *abi.IEditController, state: ?*abi.IBStream) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind != .gain_ctrl) return abi.kResultOk;
    const s = state orelse return abi.kInvalidArgument;
    _ = state_saves.fetchAdd(1, .monotonic);
    return writeF64(s, ldF64(&o.freq));
}
fn ctrlParamCount(this: *abi.IEditController) callconv(.c) i32 {
    return if (ob(this).kind == .gain_ctrl) GAIN_PARAMS.len else 0;
}
fn ctrlParamInfo(this: *abi.IEditController, index: i32, info: *abi.ParameterInfo) callconv(.c) abi.tresult {
    if (ob(this).kind != .gain_ctrl) return abi.kInvalidArgument;
    if (index < 0 or index >= GAIN_PARAMS.len) return abi.kInvalidArgument;
    const p = GAIN_PARAMS[@intCast(index)];
    info.id = p.id;
    abi.writeC16(p.title, &info.title);
    abi.writeC16(p.title, &info.shortTitle);
    abi.writeC16(p.units, &info.units);
    info.stepCount = p.steps;
    info.defaultNormalizedValue = p.def;
    info.unitId = 0;
    info.flags = p.flags;
    return abi.kResultOk;
}
fn plainOf(id: u32, n: f64) f64 {
    return switch (id) {
        7 => 2.0 * n,
        3 => @round(n * 2.0),
        12 => 20.0 * std.math.pow(f64, 1000.0, n),
        else => n,
    };
}
fn ctrlParamString(this: *abi.IEditController, id: u32, n: f64, string: *abi.String128) callconv(.c) abi.tresult {
    if (ob(this).kind != .gain_ctrl) return abi.kInvalidArgument;
    var buf: [64]u8 = undefined;
    const text: []const u8 = switch (id) {
        3 => blk: {
            const r = @round(n * 2.0);
            const idx: usize = if (!(r > 0.0)) 0 else if (r >= 2.0) 2 else @intFromFloat(r);
            break :blk (&[_][]const u8{ "A", "B", "C" })[idx];
        },
        13 => blk: {
            // Rust replaced '-' by U+2212.
            const raw = std.fmt.bufPrint(buf[8..], "{d:.1}", .{48.0 * n - 24.0}) catch "";
            if (raw.len > 0 and raw[0] == '-') {
                const minus = "\u{2212}";
                const rest = raw[1..];
                @memcpy(buf[0..minus.len], minus);
                std.mem.copyForwards(u8, buf[minus.len..][0..rest.len], rest);
                break :blk buf[0 .. minus.len + rest.len];
            }
            std.mem.copyForwards(u8, buf[0..raw.len], raw);
            break :blk buf[0..raw.len];
        },
        14 => std.fmt.bufPrint(&buf, "{d:.1} dB", .{12.0 * n}) catch "",
        else => std.fmt.bufPrint(&buf, "{d:.2}", .{plainOf(id, n)}) catch "",
    };
    abi.writeC16(text, string);
    return abi.kResultOk;
}
fn ctrlParamValue(this: *abi.IEditController, _: u32, _: [*:0]const u16, _: *f64) callconv(.c) abi.tresult {
    return if (ob(this).kind == .gain_ctrl) abi.kNotImplemented else abi.kInvalidArgument;
}
fn ctrlToPlain(this: *abi.IEditController, id: u32, n: f64) callconv(.c) f64 {
    return if (ob(this).kind == .gain_ctrl) plainOf(id, n) else n;
}
fn ctrlToNormalized(this: *abi.IEditController, id: u32, v: f64) callconv(.c) f64 {
    if (ob(this).kind != .gain_ctrl) return v;
    return switch (id) {
        7 => v / 2.0,
        3 => v / 2.0,
        12 => @log(v / 20.0) / @log(@as(f64, 1000.0)),
        else => v,
    };
}
fn ctrlGetNormalized(this: *abi.IEditController, id: u32) callconv(.c) f64 {
    const o = ob(this);
    if (o.kind != .gain_ctrl) return 0.0;
    return switch (id) {
        7 => ldF64(&o.gain),
        12 => ldF64(&o.freq),
        else => 0.0,
    };
}
fn ctrlSetNormalized(this: *abi.IEditController, id: u32, v: f64) callconv(.c) abi.tresult {
    const o = ob(this);
    if (o.kind == .gain_ctrl) {
        if (id == 7) stF64(&o.gain, v) else if (id == 12) stF64(&o.freq, v);
    }
    return abi.kResultOk;
}
fn ctrlSetHandler(this: *abi.IEditController, handler: ?*abi.IComponentHandler) callconv(.c) abi.tresult {
    if (ob(this).kind != .gain_ctrl) return abi.kResultOk;
    // Exercise the host's handler: an edit from the "plugin GUI" must be accepted.
    if (handler) |h| {
        const ok = h.vtbl.beginEdit(h, 7) == abi.kResultOk and
            h.vtbl.performEdit(h, 7, 0.9) == abi.kResultOk and
            h.vtbl.endEdit(h, 7) == abi.kResultOk;
        if (ok) _ = handler_edits.fetchAdd(1, .monotonic) else contractFailure();
    }
    return abi.kResultOk;
}
fn ctrlCreateView(this: *abi.IEditController, name: [*:0]const u8) callconv(.c) ?*abi.IPlugView {
    if (ob(this).kind != .gain_ctrl) return null;
    if (!std.mem.eql(u8, std.mem.span(name), "editor")) return null;
    const v = newObject(.view, &objects_alive) orelse return null;
    return @ptrCast(&v.view_if);
}
const ctrl_vtbl: abi.IEditController.Vtbl = .{
    .base = base_vtbl,
    .setComponentState = @ptrCast(&ctrlSetComponentState),
    .setState = @ptrCast(&ctrlSetState),
    .getState = @ptrCast(&ctrlGetState),
    .getParameterCount = ctrlParamCount,
    .getParameterInfo = ctrlParamInfo,
    .getParamStringByValue = ctrlParamString,
    .getParamValueByString = ctrlParamValue,
    .normalizedParamToPlain = ctrlToPlain,
    .plainParamToNormalized = ctrlToNormalized,
    .getParamNormalized = ctrlGetNormalized,
    .setParamNormalized = ctrlSetNormalized,
    .setComponentHandler = ctrlSetHandler,
    .createView = ctrlCreateView,
};

// ---- IPlugView -------------------------------------------------------------------------------

fn viewPlatformSupported(_: *abi.IPlugView, t: [*:0]const u8) callconv(.c) abi.tresult {
    const s = std.mem.span(t);
    const yes = std.mem.eql(u8, s, "NSView") or std.mem.eql(u8, s, "HWND") or std.mem.eql(u8, s, "X11EmbedWindowID");
    return if (yes) abi.kResultTrue else abi.kResultFalse;
}
fn viewAttached(this: *abi.IPlugView, parent: ?*anyopaque, _: [*:0]const u8) callconv(.c) abi.tresult {
    if (parent == null) return abi.kInvalidArgument;
    ob(this).attached.store(true, .monotonic);
    _ = view_attaches.fetchAdd(1, .monotonic);
    return abi.kResultOk;
}
fn viewRemoved(this: *abi.IPlugView) callconv(.c) abi.tresult {
    if (!ob(this).attached.swap(false, .monotonic)) {
        contractFailure();
        return abi.kInvalidArgument;
    }
    _ = view_removes.fetchAdd(1, .monotonic);
    return abi.kResultOk;
}
fn viewWheel(_: *abi.IPlugView, _: f32) callconv(.c) abi.tresult {
    return abi.kResultFalse;
}
fn viewKey(_: *abi.IPlugView, _: u16, _: i16, _: i16) callconv(.c) abi.tresult {
    return abi.kResultFalse;
}
fn viewGetSize(_: *abi.IPlugView, size: *abi.ViewRect) callconv(.c) abi.tresult {
    size.* = .{ .left = 0, .top = 0, .right = 320, .bottom = 240 };
    return abi.kResultOk;
}
fn viewOnSize(_: *abi.IPlugView, size: *abi.ViewRect) callconv(.c) abi.tresult {
    view_last_width.store(size.right - size.left, .monotonic);
    view_last_height.store(size.bottom - size.top, .monotonic);
    _ = view_resizes.fetchAdd(1, .monotonic);
    return abi.kResultOk;
}
fn viewOnFocus(_: *abi.IPlugView, _: abi.TBool) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn viewSetFrame(_: *abi.IPlugView, _: ?*abi.IPlugFrame) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
fn viewCanResize(_: *abi.IPlugView) callconv(.c) abi.tresult {
    return if (view_resizable.load(.monotonic)) abi.kResultTrue else abi.kResultFalse;
}
fn viewCheckSize(_: *abi.IPlugView, _: *abi.ViewRect) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
const view_vtbl: abi.IPlugView.Vtbl = .{
    .unknown = unk_vtbl,
    .isPlatformTypeSupported = viewPlatformSupported,
    .attached = viewAttached,
    .removed = viewRemoved,
    .onWheel = viewWheel,
    .onKeyDown = viewKey,
    .onKeyUp = viewKey,
    .getSize = viewGetSize,
    .onSize = viewOnSize,
    .onFocus = viewOnFocus,
    .setFrame = viewSetFrame,
    .canResize = viewCanResize,
    .checkSizeConstraint = viewCheckSize,
};

// ---- factory ---------------------------------------------------------------------------------

const ClassDef = struct { cid: abi.TUID, category: []const u8, name: []const u8, sub: []const u8 };

/// The classes the factory reports, in index order.
pub const CLASSES = [_]ClassDef{
    .{ .cid = GAIN_CID, .category = "Audio Module Class", .name = "Fixture Gain", .sub = "Fx" },
    .{ .cid = GAIN_CTRL_CID, .category = "Component Controller Class", .name = "Fixture Gain", .sub = "" },
    .{ .cid = SYNTH_CID, .category = "Audio Module Class", .name = "Fixture Synth", .sub = "Instrument|Synth" },
    .{ .cid = WIDE16_CID, .category = "Audio Module Class", .name = "Fixture Wide 16x64", .sub = "Fx" },
    .{ .cid = WIDE17_CID, .category = "Audio Module Class", .name = "Fixture Wide 17 buses", .sub = "Fx" },
    .{ .cid = WIDE65_CID, .category = "Audio Module Class", .name = "Fixture Wide 65 channels", .sub = "Fx" },
};

fn facGetFactoryInfo(_: *abi.IPluginFactory, info: *abi.PFactoryInfo) callconv(.c) abi.tresult {
    copyC8("SoundCraft tests", &info.vendor);
    copyC8("https://example.invalid", &info.url);
    copyC8("tests@example.invalid", &info.email);
    info.flags = kUnicodeFactory;
    return abi.kResultOk;
}
fn facCountClasses(_: *abi.IPluginFactory) callconv(.c) i32 {
    return CLASSES.len;
}
fn facGetClassInfo(_: *abi.IPluginFactory, index: i32, info: *abi.PClassInfo) callconv(.c) abi.tresult {
    if (index < 0 or index >= CLASSES.len) return abi.kInvalidArgument;
    const c = CLASSES[@intCast(index)];
    info.cid = c.cid;
    info.cardinality = kManyInstances;
    copyC8(c.category, &info.category);
    copyC8(c.name, &info.name);
    return abi.kResultOk;
}
fn facCreateInstance(_: *abi.IPluginFactory, cid: *const abi.TUID, id: *const abi.TUID, out: *?*anyopaque) callconv(.c) abi.tresult {
    out.* = null;
    const o: *Object = blk: {
        if (std.mem.eql(u8, cid, &GAIN_CID)) {
            const o = newObject(.gain, &objects_alive) orelse return abi.kOutOfMemory;
            stF64(&o.gain, 0.25);
            break :blk o;
        } else if (std.mem.eql(u8, cid, &GAIN_CTRL_CID)) {
            const o = newObject(.gain_ctrl, &objects_alive) orelse return abi.kOutOfMemory;
            stF64(&o.gain, 0.5);
            stF64(&o.freq, 0.5);
            break :blk o;
        } else if (std.mem.eql(u8, cid, &SYNTH_CID)) {
            break :blk newObject(.synth, &objects_alive) orelse return abi.kOutOfMemory;
        }
        const layouts = [_]struct { cid: abi.TUID, buses: i32, channels: i32 }{
            .{ .cid = WIDE16_CID, .buses = 16, .channels = 64 },
            .{ .cid = WIDE17_CID, .buses = 17, .channels = 2 },
            .{ .cid = WIDE65_CID, .buses = 1, .channels = 65 },
        };
        for (layouts) |l| {
            if (std.mem.eql(u8, cid, &l.cid)) {
                const o = newObject(.wide, &objects_alive) orelse return abi.kOutOfMemory;
                o.buses = l.buses;
                o.channels = l.channels;
                break :blk o;
            }
        }
        return abi.kInvalidArgument;
    };
    // The creation reference is dropped once the query took its own.
    const r = objQuery(o, id, out);
    _ = objRelease(o);
    return r;
}
fn facGetClassInfo2(_: *abi.IPluginFactory2, index: i32, info: *abi.PClassInfo2) callconv(.c) abi.tresult {
    if (index < 0 or index >= CLASSES.len) return abi.kInvalidArgument;
    const c = CLASSES[@intCast(index)];
    info.cid = c.cid;
    info.cardinality = kManyInstances;
    copyC8(c.category, &info.category);
    copyC8(c.name, &info.name);
    info.classFlags = 0;
    copyC8(c.sub, &info.subCategories);
    copyC8("", &info.vendor);
    copyC8("1.2.3", &info.version);
    copyC8("VST 3.8.0", &info.sdkVersion);
    return abi.kResultOk;
}
fn facGetClassInfoUnicode(_: *abi.IPluginFactory3, index: i32, info: *abi.PClassInfoW) callconv(.c) abi.tresult {
    if (index < 0 or index >= CLASSES.len) return abi.kInvalidArgument;
    const c = CLASSES[@intCast(index)];
    info.cid = c.cid;
    info.cardinality = kManyInstances;
    copyC8(c.category, &info.category);
    abi.writeC16(c.name, &info.name);
    info.classFlags = 0;
    copyC8(c.sub, &info.subCategories);
    abi.writeC16("", &info.vendor);
    abi.writeC16("1.2.3", &info.version);
    abi.writeC16("VST 3.8.0", &info.sdkVersion);
    return abi.kResultOk;
}
fn facSetHostContext(_: *abi.IPluginFactory3, _: ?*abi.FUnknown) callconv(.c) abi.tresult {
    return abi.kResultOk;
}
const fac_vtbl: abi.IPluginFactory3.Vtbl = .{
    .base = .{
        .base = .{
            .unknown = unk_vtbl,
            .getFactoryInfo = facGetFactoryInfo,
            .countClasses = facCountClasses,
            .getClassInfo = facGetClassInfo,
            .createInstance = facCreateInstance,
        },
        .getClassInfo2 = facGetClassInfo2,
    },
    .getClassInfoUnicode = facGetClassInfoUnicode,
    .setHostContext = facSetHostContext,
};

// ---- module lifecycle ------------------------------------------------------------------------
//
// The contract real plugins rely on: the host runs the module exit once the factory and every
// plugin object are released, on the thread that ran the module entry. Breaking it is counted in
// `violations` (the Rust fixture ends the process with status 3).

fn violation(what: []const u8) void {
    last_violation = what;
    _ = violations.fetchAdd(1, .seq_cst);
}

/// The VST3 module entry (`bundleEntry` / `ModuleEntry`): counts nested entries and remembers the
/// thread of the outermost one. Fails for a null bundle.
pub fn moduleEntry(bundle: ?*anyopaque) callconv(.c) bool {
    if (bundle == null) return false;
    if (entered.fetchAdd(1, .seq_cst) == 0) entry_thread.store(module.osThread(), .seq_cst);
    return true;
}

/// The VST3 module exit: returns false (and counts a violation) when the exit has no entry, when
/// the factory or a plugin object is still alive at the outermost exit, or when it runs on
/// another thread than the entry.
pub fn moduleExit() callconv(.c) bool {
    var ok = true;
    const left = entered.fetchSub(1, .seq_cst) - 1;
    if (left < 0) {
        violation("module exit without a module entry");
        entered.store(0, .seq_cst);
        return false;
    }
    if (left == 0 and (factories_alive.load(.seq_cst) != 0 or objects_alive.load(.seq_cst) != 0)) {
        violation("module exit with factories or plugin objects alive");
        ok = false;
    }
    if (left == 0 and module.osThread() != entry_thread.load(.seq_cst)) {
        violation("module exit on another thread than the module entry");
        ok = false;
    }
    return ok;
}

/// `GetPluginFactory`: a new factory (one reference for the caller, counted in `factories_alive`).
pub fn getPluginFactory() ?*abi.IPluginFactory {
    const o = newObject(.factory, &factories_alive) orelse return null;
    return @ptrCast(&o.fac);
}

/// Registers the fixture with a registry as a loaded bundle: runs the module entry, takes the
/// factory, and installs `moduleExit` as the bundle's exit. The bundle then behaves like a
/// `dlopen`ed one for `Registry.exitModules` and `Bundle.create`. `entered_on` must match the
/// thread that will run the exit (use `.main` together with `reg.assume_main = true` from the
/// test thread).
pub fn adopt(reg: *module.Registry, path: []const u8, entered_on: module.EntryThread) !*module.Bundle {
    var token: u8 = 0;
    if (!moduleEntry(&token)) return error.EntryFailed;
    errdefer _ = moduleExit();
    const factory = getPluginFactory() orelse return error.OutOfMemory;
    errdefer _ = abi.comRelease(factory);
    const b = try reg.gpa.create(module.Bundle);
    errdefer reg.gpa.destroy(b);
    const owned_path = try reg.gpa.dupe(u8, path);
    errdefer reg.gpa.free(owned_path);
    b.* = .{ .gpa = reg.gpa, .path = owned_path, .factory = factory, .exit_fn = moduleExit, .entered_on = entered_on };
    try reg.adopt(b);
    return b;
}

// ---- tests -----------------------------------------------------------------------------------
//
// The Rust fixture has no tests of its own (the vst3-host integration tests drive it). These
// check the fixture directly: the COM plumbing, reference counting, every class, and the
// switches, so the host tests that build on it can trust it.

const testing = std.testing;

fn noQuery(_: *abi.FUnknown, _: *const abi.TUID, out: *?*anyopaque) callconv(.c) abi.tresult {
    out.* = null;
    return abi.kNoInterface;
}
fn noAddRef(_: *abi.FUnknown) callconv(.c) u32 {
    return 1;
}
fn noRelease(_: *abi.FUnknown) callconv(.c) u32 {
    return 1;
}
const fake_unk: abi.FUnknown.Vtbl = .{ .queryInterface = noQuery, .addRef = noAddRef, .release = noRelease };

/// An in-memory `IBStream`.
const MemStream = struct {
    iface: abi.IBStream = .{ .vtbl = &vtbl },
    buf: [64]u8 = @splat(0),
    len: usize = 0,
    pos: usize = 0,

    const vtbl: abi.IBStream.Vtbl = .{ .unknown = fake_unk, .read = read, .write = write, .seek = seek, .tell = tell };

    fn self(this: *abi.IBStream) *MemStream {
        return @fieldParentPtr("iface", this);
    }
    fn read(this: *abi.IBStream, buffer: ?*anyopaque, n: i32, got: ?*i32) callconv(.c) abi.tresult {
        const s = self(this);
        const want: usize = @intCast(n);
        const k = @min(want, s.len - s.pos);
        const dst: [*]u8 = @ptrCast(buffer.?);
        @memcpy(dst[0..k], s.buf[s.pos..][0..k]);
        s.pos += k;
        if (got) |g| g.* = @intCast(k);
        return abi.kResultOk;
    }
    fn write(this: *abi.IBStream, buffer: ?*anyopaque, n: i32, put: ?*i32) callconv(.c) abi.tresult {
        const s = self(this);
        const k: usize = @intCast(n);
        const src: [*]const u8 = @ptrCast(buffer.?);
        @memcpy(s.buf[s.pos..][0..k], src[0..k]);
        s.pos += k;
        s.len = @max(s.len, s.pos);
        if (put) |p| p.* = n;
        return abi.kResultOk;
    }
    fn seek(this: *abi.IBStream, pos: i64, _: i32, _: ?*i64) callconv(.c) abi.tresult {
        self(this).pos = @intCast(pos);
        return abi.kResultOk;
    }
    fn tell(this: *abi.IBStream, pos: ?*i64) callconv(.c) abi.tresult {
        if (pos) |p| p.* = @intCast(self(this).pos);
        return abi.kResultOk;
    }
};

/// A host-side `IParameterChanges` holding one queue per entry, and the `IParamValueQueue`s.
const FakeQueue = struct {
    iface: abi.IParamValueQueue = .{ .vtbl = &vtbl },
    id: abi.ParamID = 0,
    points: [4]struct { at: i32, v: f64 } = undefined,
    n: i32 = 0,

    const vtbl: abi.IParamValueQueue.Vtbl = .{ .unknown = fake_unk, .getParameterId = getId, .getPointCount = getCount, .getPoint = getPoint, .addPoint = addPoint };
    fn self(this: *abi.IParamValueQueue) *FakeQueue {
        return @fieldParentPtr("iface", this);
    }
    fn getId(this: *abi.IParamValueQueue) callconv(.c) abi.ParamID {
        return self(this).id;
    }
    fn getCount(this: *abi.IParamValueQueue) callconv(.c) i32 {
        return self(this).n;
    }
    fn getPoint(this: *abi.IParamValueQueue, i: i32, at: ?*i32, v: ?*f64) callconv(.c) abi.tresult {
        const s = self(this);
        if (i < 0 or i >= s.n) return abi.kInvalidArgument;
        at.?.* = s.points[@intCast(i)].at;
        v.?.* = s.points[@intCast(i)].v;
        return abi.kResultOk;
    }
    fn addPoint(this: *abi.IParamValueQueue, at: i32, v: f64, index: ?*i32) callconv(.c) abi.tresult {
        const s = self(this);
        s.points[@intCast(s.n)] = .{ .at = at, .v = v };
        if (index) |p| p.* = s.n;
        s.n += 1;
        return abi.kResultOk;
    }
};

const FakeChanges = struct {
    iface: abi.IParameterChanges = .{ .vtbl = &vtbl },
    queues: [2]FakeQueue = .{ .{}, .{} },
    n: i32 = 0,

    const vtbl: abi.IParameterChanges.Vtbl = .{ .unknown = fake_unk, .getParameterCount = count, .getParameterData = data, .addParameterData = add };
    fn self(this: *abi.IParameterChanges) *FakeChanges {
        return @fieldParentPtr("iface", this);
    }
    fn count(this: *abi.IParameterChanges) callconv(.c) i32 {
        return self(this).n;
    }
    fn data(this: *abi.IParameterChanges, i: i32) callconv(.c) ?*abi.IParamValueQueue {
        const s = self(this);
        if (i < 0 or i >= s.n) return null;
        return &s.queues[@intCast(i)].iface;
    }
    fn add(this: *abi.IParameterChanges, id: *const abi.ParamID, index: *i32) callconv(.c) ?*abi.IParamValueQueue {
        const s = self(this);
        const q = &s.queues[@intCast(s.n)];
        q.* = .{ .id = id.* };
        index.* = s.n;
        s.n += 1;
        return &q.iface;
    }
    fn put(self_: *FakeChanges, id: abi.ParamID, at: i32, v: f64) void {
        self_.queues[@intCast(self_.n)] = .{ .id = id };
        _ = FakeQueue.addPoint(&self_.queues[@intCast(self_.n)].iface, at, v, null);
        self_.n += 1;
    }
};

const FakeEvents = struct {
    iface: abi.IEventList = .{ .vtbl = &vtbl },
    events: [8]abi.Event = undefined,
    n: i32 = 0,

    const vtbl: abi.IEventList.Vtbl = .{ .unknown = fake_unk, .getEventCount = count, .getEvent = get, .addEvent = add };
    fn self(this: *abi.IEventList) *FakeEvents {
        return @fieldParentPtr("iface", this);
    }
    fn count(this: *abi.IEventList) callconv(.c) i32 {
        return self(this).n;
    }
    fn get(this: *abi.IEventList, i: i32, e: *abi.Event) callconv(.c) abi.tresult {
        const s = self(this);
        if (i < 0 or i >= s.n) return abi.kInvalidArgument;
        e.* = s.events[@intCast(i)];
        return abi.kResultOk;
    }
    fn add(this: *abi.IEventList, e: *abi.Event) callconv(.c) abi.tresult {
        const s = self(this);
        s.events[@intCast(s.n)] = e.*;
        s.n += 1;
        return abi.kResultOk;
    }
    fn noteOn(self_: *FakeEvents, at: i32, pitch: i16, vel: f32) void {
        var e = std.mem.zeroes(abi.Event);
        e.sampleOffset = at;
        e.type = abi.EventTypes.kNoteOnEvent;
        e.payload.noteOn = .{ .channel = 0, .pitch = pitch, .tuning = 0, .velocity = vel, .length = 0, .noteId = -1 };
        _ = add(&self_.iface, &e);
    }
    fn noteOff(self_: *FakeEvents, at: i32, pitch: i16) void {
        var e = std.mem.zeroes(abi.Event);
        e.sampleOffset = at;
        e.type = abi.EventTypes.kNoteOffEvent;
        e.payload.noteOff = .{ .channel = 0, .pitch = pitch, .velocity = 0, .noteId = -1, .tuning = 0 };
        _ = add(&self_.iface, &e);
    }
};

/// A host `IComponentHandler` that counts edits.
const FakeHandler = struct {
    iface: abi.IComponentHandler = .{ .vtbl = &vtbl },
    begins: u32 = 0,
    performs: u32 = 0,
    ends: u32 = 0,
    last_value: f64 = 0,

    const vtbl: abi.IComponentHandler.Vtbl = .{ .unknown = fake_unk, .beginEdit = begin, .performEdit = perform, .endEdit = end, .restartComponent = restart };
    fn self(this: *abi.IComponentHandler) *FakeHandler {
        return @fieldParentPtr("iface", this);
    }
    fn begin(this: *abi.IComponentHandler, _: abi.ParamID) callconv(.c) abi.tresult {
        self(this).begins += 1;
        return abi.kResultOk;
    }
    fn perform(this: *abi.IComponentHandler, _: abi.ParamID, v: f64) callconv(.c) abi.tresult {
        self(this).performs += 1;
        self(this).last_value = v;
        return abi.kResultOk;
    }
    fn end(this: *abi.IComponentHandler, _: abi.ParamID) callconv(.c) abi.tresult {
        self(this).ends += 1;
        return abi.kResultOk;
    }
    fn restart(_: *abi.IComponentHandler, _: i32) callconv(.c) abi.tresult {
        return abi.kResultOk;
    }
};

fn createFrom(f: *abi.IPluginFactory, comptime I: type, cid: *const abi.TUID) ?*I {
    var obj: ?*anyopaque = null;
    const id: abi.TUID = I.iid;
    if (f.createInstance(cid, &id, &obj) != abi.kResultOk) return null;
    return @ptrCast(@alignCast(obj.?));
}

const host_context: abi.FUnknown = .{ .vtbl = &fake_unk };

/// Starts a test: clean hooks, and the module entry the host would run.
fn startTest() *abi.IPluginFactory {
    reset();
    var token: u8 = 0;
    std.debug.assert(moduleEntry(&token));
    return getPluginFactory().?;
}

/// Ends a test: releases the factory, runs the module exit, and checks nothing leaked.
fn finish(f: *abi.IPluginFactory) !void {
    _ = abi.comRelease(f);
    try testing.expect(moduleExit());
    try testing.expectEqual(@as(i64, 0), objects_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), factories_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), entered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), contract_failures.load(.seq_cst));
}

test "fixture: the factory reports six classes through factory 1, 2 and 3" {
    const f = startTest();
    try testing.expectEqual(@as(i32, 6), f.countClasses());

    var info: abi.PFactoryInfo = undefined;
    try testing.expectEqual(abi.kResultOk, f.getFactoryInfo(&info));
    try testing.expectEqualStrings("SoundCraft tests", abi.readC8(&info.vendor));
    try testing.expectEqual(kUnicodeFactory, info.flags);

    var ci: abi.PClassInfo = undefined;
    try testing.expectEqual(abi.kResultOk, f.getClassInfo(0, &ci));
    try testing.expectEqualStrings("Fixture Gain", abi.readC8(&ci.name));
    try testing.expectEqualStrings("Audio Module Class", abi.readC8(&ci.category));
    try testing.expectEqual(abi.kInvalidArgument, f.getClassInfo(6, &ci));
    try testing.expectEqual(abi.kInvalidArgument, f.getClassInfo(-1, &ci));

    const f2 = abi.comCast(abi.IPluginFactory2, f).?;
    var c2: abi.PClassInfo2 = undefined;
    try testing.expectEqual(abi.kResultOk, f2.getClassInfo2(2, &c2));
    try testing.expectEqualStrings("Instrument|Synth", abi.readC8(&c2.subCategories));
    try testing.expectEqualStrings("1.2.3", abi.readC8(&c2.version));
    try testing.expectEqualStrings("VST 3.8.0", abi.readC8(&c2.sdkVersion));
    _ = abi.comRelease(f2);

    const f3 = abi.comCast(abi.IPluginFactory3, f).?;
    var cw: abi.PClassInfoW = undefined;
    try testing.expectEqual(abi.kResultOk, f3.getClassInfoUnicode(5, &cw));
    const name = try abi.readC16(testing.allocator, &cw.name);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Fixture Wide 65 channels", name);
    try testing.expectEqual(abi.kResultOk, f3.setHostContext(null));
    _ = abi.comRelease(f3);

    var unknown: ?*anyopaque = null;
    const bogus: abi.TUID = abi.uid(1, 2, 3, 4);
    try testing.expectEqual(abi.kNoInterface, abi.asUnknown(f).queryInterface(&bogus, &unknown));
    try finish(f);
}

test "fixture: createInstance, queryInterface and reference counting" {
    const f = startTest();
    const comp = createFrom(f, abi.IComponent, &GAIN_CID).?;
    try testing.expectEqual(@as(i64, 1), objects_alive.load(.seq_cst));

    // One count shared by every interface of the object.
    const proc = abi.comCast(abi.IAudioProcessor, comp).?;
    const conn = abi.comCast(abi.IConnectionPoint, comp).?;
    try testing.expect(abi.comCast(abi.IEditController, comp) == null);
    try testing.expect(abi.comCast(abi.IPlugView, comp) == null);
    try testing.expectEqual(@as(u32, 2), abi.comRelease(conn));
    try testing.expectEqual(@as(u32, 1), abi.comRelease(proc));
    try testing.expectEqual(@as(i64, 1), objects_alive.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), abi.comRelease(comp));
    try testing.expectEqual(@as(i64, 0), objects_alive.load(.seq_cst));

    // Wrong interface for the class: nothing is created or leaked.
    var obj: ?*anyopaque = null;
    const wrong: abi.TUID = abi.IEditController.iid;
    try testing.expectEqual(abi.kNoInterface, f.createInstance(&GAIN_CID, &wrong, &obj));
    try testing.expect(obj == null);
    try testing.expectEqual(abi.kInvalidArgument, f.createInstance(&abi.uid(9, 9, 9, 9), &abi.IComponent.iid, &obj));
    try testing.expectEqual(@as(i64, 0), objects_alive.load(.seq_cst));
    try finish(f);
}

test "fixture: gain component layout, state and latency" {
    const f = startTest();
    const comp = createFrom(f, abi.IComponent, &GAIN_CID).?;
    const proc = abi.comCast(abi.IAudioProcessor, comp).?;
    try testing.expectEqual(abi.kInvalidArgument, comp.initialize(null));
    try testing.expectEqual(@as(u32, 1), contract_failures.swap(0, .seq_cst));
    try testing.expectEqual(abi.kResultOk, comp.initialize(@constCast(&host_context)));

    var cid: abi.TUID = undefined;
    try testing.expectEqual(abi.kResultOk, comp.getControllerClassId(&cid));
    try testing.expectEqualSlices(u8, &GAIN_CTRL_CID, &cid);
    try testing.expectEqual(@as(i32, 1), comp.getBusCount(abi.kAudio, abi.kInput));
    try testing.expectEqual(@as(i32, 0), comp.getBusCount(abi.kEvent, abi.kInput));
    var bus: abi.BusInfo = undefined;
    try testing.expectEqual(abi.kResultOk, comp.getBusInfo(abi.kAudio, abi.kOutput, 0, &bus));
    try testing.expectEqual(@as(i32, 2), bus.channelCount);
    try testing.expectEqual(abi.kInvalidArgument, comp.getBusInfo(abi.kAudio, abi.kOutput, 1, &bus));

    var arr: abi.SpeakerArrangement = 0;
    try testing.expectEqual(abi.kResultOk, proc.getBusArrangement(abi.kInput, 0, &arr));
    try testing.expectEqual(kStereo, arr);
    var mono: [1]abi.SpeakerArrangement = .{kMono};
    try testing.expectEqual(abi.kResultTrue, proc.setBusArrangements(&mono, 1, &mono, 1));
    try testing.expectEqual(abi.kResultOk, proc.getBusArrangement(abi.kOutput, 0, &arr));
    try testing.expectEqual(kMono, arr);
    var six: [1]abi.SpeakerArrangement = .{0x3F};
    try testing.expectEqual(abi.kResultFalse, proc.setBusArrangements(&six, 1, &six, 1));

    try testing.expectEqual(abi.kResultOk, proc.canProcessSampleSize(abi.kSample32));
    try testing.expectEqual(abi.kNotImplemented, proc.canProcessSampleSize(abi.kSample64));
    try testing.expectEqual(@as(u32, 3), proc.getLatencySamples());
    try testing.expectEqual(@as(u32, 0), proc.getTailSamples());
    bogus_latency.store(true, .monotonic);
    try testing.expectEqual(BOGUS_LATENCY, proc.getLatencySamples());
    bogus_latency.store(false, .monotonic);
    var setup: abi.ProcessSetup = .{ .processMode = abi.kRealtime, .symbolicSampleSize = abi.kSample32, .maxSamplesPerBlock = 256, .sampleRate = 48000 };
    try testing.expectEqual(abi.kResultOk, proc.setupProcessing(&setup));
    setup.symbolicSampleSize = abi.kSample64;
    try testing.expectEqual(abi.kInvalidArgument, proc.setupProcessing(&setup));
    try testing.expectEqual(@as(u32, 1), contract_failures.swap(0, .seq_cst));

    // State: one LE f64, initial normalized gain 0.25.
    var s: MemStream = .{};
    try testing.expectEqual(abi.kResultOk, comp.getState(&s.iface));
    try testing.expectEqual(@as(usize, 8), s.len);
    try testing.expectEqual(@as(f64, 0.25), @as(f64, @bitCast(std.mem.readInt(u64, s.buf[0..8], .little))));
    var t: MemStream = .{};
    std.mem.writeInt(u64, t.buf[0..8], @bitCast(@as(f64, 0.75)), .little);
    t.len = 8;
    try testing.expectEqual(abi.kResultOk, comp.setState(&t.iface));
    var u: MemStream = .{};
    try testing.expectEqual(abi.kResultOk, comp.getState(&u.iface));
    try testing.expectEqualSlices(u8, t.buf[0..8], u.buf[0..8]);
    // Out of range, short and refused states.
    std.mem.writeInt(u64, t.buf[0..8], @bitCast(@as(f64, 1.5)), .little);
    t.pos = 0;
    try testing.expectEqual(abi.kResultFalse, comp.setState(&t.iface));
    var short: MemStream = .{ .len = 3 };
    try testing.expectEqual(abi.kResultFalse, comp.setState(&short.iface));
    refuse_state.store(true, .monotonic);
    std.mem.writeInt(u64, t.buf[0..8], @bitCast(@as(f64, 0.5)), .little);
    t.pos = 0;
    try testing.expectEqual(abi.kResultFalse, comp.setState(&t.iface));
    try testing.expectEqual(@as(u32, 1), state_refusals.load(.monotonic));

    _ = abi.comRelease(proc);
    _ = abi.comRelease(comp);
    try finish(f);
}

test "fixture: gain processes, applies parameter changes and can emit NaN or parameters" {
    const f = startTest();
    const comp = createFrom(f, abi.IComponent, &GAIN_CID).?;
    const proc = abi.comCast(abi.IAudioProcessor, comp).?;

    var in_l: [4]f32 = .{ 1, 2, 3, 4 };
    var in_r: [4]f32 = .{ -1, -2, -3, -4 };
    var out_l: [4]f32 = @splat(0);
    var out_r: [4]f32 = @splat(0);
    var in_ptrs: [2]?[*]f32 = .{ &in_l, &in_r };
    var out_ptrs: [2]?[*]f32 = .{ &out_l, &out_r };
    var in_bus: [1]abi.AudioBusBuffers = .{.{ .numChannels = 2, .silenceFlags = 0, .channelBuffers = .{ .channelBuffers32 = &in_ptrs } }};
    var out_bus: [1]abi.AudioBusBuffers = .{.{ .numChannels = 2, .silenceFlags = 0, .channelBuffers = .{ .channelBuffers32 = &out_ptrs } }};
    var ctx = std.mem.zeroes(abi.ProcessContext);
    var changes: FakeChanges = .{};
    var out_changes: FakeChanges = .{};
    var data: abi.ProcessData = .{
        .processMode = abi.kRealtime,
        .symbolicSampleSize = abi.kSample32,
        .numSamples = 4,
        .numInputs = 1,
        .numOutputs = 1,
        .inputs = &in_bus,
        .outputs = &out_bus,
        .inputParameterChanges = &changes.iface,
        .outputParameterChanges = &out_changes.iface,
        .inputEvents = null,
        .outputEvents = null,
        .processContext = &ctx,
    };

    // The component starts at normalized 0.25: plain gain 0.5.
    try testing.expectEqual(abi.kResultOk, proc.process(&data));
    try testing.expectEqualSlices(f32, &.{ 0.5, 1, 1.5, 2 }, &out_l);
    try testing.expectEqualSlices(f32, &.{ -0.5, -1, -1.5, -2 }, &out_r);
    try testing.expectEqual(@as(u32, 1), process_calls.load(.monotonic));

    // Parameter 7 (last point wins); other ids are read but ignored.
    changes.put(9, 1, 1.0);
    changes.put(7, 2, 1.0);
    try testing.expectEqual(abi.kResultOk, proc.process(&data));
    try testing.expectEqualSlices(f32, &.{ 2, 4, 6, 8 }, &out_l);
    try testing.expectEqual(@as(u32, 7), last_param_id.load(.monotonic));
    try testing.expectEqual(@as(i32, 2), last_param_offset.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), param_points_seen.load(.monotonic));

    // Parameter output.
    emit_param_output.store(true, .monotonic);
    try testing.expectEqual(abi.kResultOk, proc.process(&data));
    try testing.expectEqual(@as(i32, 1), out_changes.n);
    try testing.expectEqual(@as(abi.ParamID, 7), out_changes.queues[0].id);
    try testing.expectEqual(@as(f64, 1.0), out_changes.queues[0].points[0].v);

    emit_param_output.store(false, .monotonic);
    // NaN emission.
    nan_output.store(true, .monotonic);
    try testing.expectEqual(abi.kResultOk, proc.process(&data));
    try testing.expect(std.math.isNan(out_l[0]) and std.math.isNan(out_r[3]));

    // Missing process context is a contract failure; other bus counts are ignored.
    nan_output.store(false, .monotonic);
    data.processContext = null;
    _ = proc.process(&data);
    try testing.expectEqual(@as(u32, 1), contract_failures.swap(0, .seq_cst));
    data.processContext = &ctx;
    data.numInputs = 0;
    @memset(&out_l, 7);
    try testing.expectEqual(abi.kResultOk, proc.process(&data));
    try testing.expectEqual(@as(f32, 7), out_l[0]);

    _ = abi.comRelease(proc);
    _ = abi.comRelease(comp);
    try finish(f);
}

test "fixture: gain controller parameters, strings, state, handler and connection" {
    const f = startTest();
    const comp = createFrom(f, abi.IComponent, &GAIN_CID).?;
    const ctrl = createFrom(f, abi.IEditController, &GAIN_CTRL_CID).?;
    try testing.expectEqual(abi.kResultOk, ctrl.initialize(null));

    try testing.expectEqual(@as(i32, 7), ctrl.getParameterCount());
    var pi: abi.ParameterInfo = undefined;
    try testing.expectEqual(abi.kResultOk, ctrl.getParameterInfo(0, &pi));
    try testing.expectEqual(@as(abi.ParamID, 7), pi.id);
    try testing.expectEqual(@as(f64, 0.5), pi.defaultNormalizedValue);
    const title = try abi.readC16(testing.allocator, &pi.title);
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Gain", title);
    try testing.expectEqual(abi.kCanAutomate, pi.flags);
    try testing.expectEqual(abi.kResultOk, ctrl.getParameterInfo(2, &pi));
    try testing.expectEqual(@as(i32, 2), pi.stepCount);
    try testing.expectEqual(abi.kIsList, pi.flags);
    try testing.expectEqual(abi.kInvalidArgument, ctrl.getParameterInfo(7, &pi));
    try testing.expectEqual(abi.kInvalidArgument, ctrl.getParameterInfo(-1, &pi));

    // Plain/normalized mappings.
    try testing.expectEqual(@as(f64, 1.0), ctrl.vtbl.normalizedParamToPlain(ctrl, 7, 0.5));
    try testing.expectEqual(@as(f64, 0.25), ctrl.vtbl.plainParamToNormalized(ctrl, 7, 0.5));
    try testing.expectApproxEqAbs(@as(f64, 20.0), ctrl.vtbl.normalizedParamToPlain(ctrl, 12, 0.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20000.0), ctrl.vtbl.normalizedParamToPlain(ctrl, 12, 1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5), ctrl.vtbl.plainParamToNormalized(ctrl, 12, 20.0 * std.math.pow(f64, 1000.0, 0.5)), 1e-12);
    try testing.expectEqual(@as(f64, 0.3), ctrl.vtbl.normalizedParamToPlain(ctrl, 99, 0.3));

    // Strings.
    var s128: abi.String128 = undefined;
    const expect = struct {
        fn str(c: *abi.IEditController, id: u32, n: f64, want: []const u8) !void {
            var buf: abi.String128 = undefined;
            try testing.expectEqual(abi.kResultOk, c.getParamStringByValue(id, n, &buf));
            const got = try abi.readC16(testing.allocator, &buf);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }.str;
    try expect(ctrl, 3, 0.0, "A");
    try expect(ctrl, 3, 0.5, "B");
    try expect(ctrl, 3, 1.0, "C");
    try expect(ctrl, 7, 0.5, "1.00");
    try expect(ctrl, 13, 0.375, "\u{2212}6.0");
    try expect(ctrl, 13, 1.0, "24.0");
    try expect(ctrl, 14, 0.5, "6.0 dB");
    _ = &s128;

    // Values and the component state sync.
    try testing.expectEqual(@as(f64, 0.5), ctrl.getParamNormalized(7));
    try testing.expectEqual(abi.kResultOk, ctrl.setParamNormalized(12, 0.8));
    try testing.expectEqual(@as(f64, 0.8), ctrl.getParamNormalized(12));
    try testing.expectEqual(@as(f64, 0.0), ctrl.getParamNormalized(9));
    var cs: MemStream = .{};
    try testing.expectEqual(abi.kResultOk, comp.getState(&cs.iface));
    cs.pos = 0;
    try testing.expectEqual(abi.kResultOk, ctrl.setComponentState(&cs.iface));
    try testing.expectEqual(@as(f64, 0.25), ctrl.getParamNormalized(7));

    // Controller state is the Freq value, clamped on load.
    var st: MemStream = .{};
    try testing.expectEqual(abi.kResultOk, ctrl.getState(&st.iface));
    try testing.expectEqual(@as(f64, 0.8), @as(f64, @bitCast(std.mem.readInt(u64, st.buf[0..8], .little))));
    std.mem.writeInt(u64, st.buf[0..8], @bitCast(@as(f64, 3.0)), .little);
    st.pos = 0;
    try testing.expectEqual(abi.kResultOk, ctrl.setState(&st.iface));
    try testing.expectEqual(@as(f64, 1.0), ctrl.getParamNormalized(12));

    // The host's handler receives the GUI edit.
    var h: FakeHandler = .{};
    try testing.expectEqual(abi.kResultOk, ctrl.setComponentHandler(&h.iface));
    try testing.expectEqual(@as(u32, 1), h.begins);
    try testing.expectEqual(@as(u32, 1), h.performs);
    try testing.expectEqual(@as(u32, 1), h.ends);
    try testing.expectEqual(@as(f64, 0.9), h.last_value);
    try testing.expectEqual(@as(u32, 1), handler_edits.load(.monotonic));
    try testing.expectEqual(abi.kResultOk, ctrl.setComponentHandler(null));

    // Component and controller connect to each other.
    const cc = abi.comCast(abi.IConnectionPoint, comp).?;
    const kc = abi.comCast(abi.IConnectionPoint, ctrl).?;
    try testing.expectEqual(abi.kResultOk, cc.connect(kc));
    try testing.expectEqual(abi.kResultOk, kc.connect(cc));
    try testing.expectEqual(@as(u32, 2), connects.load(.monotonic));
    try testing.expectEqual(abi.kResultOk, cc.disconnect(kc));
    try testing.expectEqual(abi.kResultOk, kc.disconnect(cc));
    _ = abi.comRelease(cc);
    _ = abi.comRelease(kc);

    // setState refusal switch.
    refuse_state.store(true, .monotonic);
    st.pos = 0;
    try testing.expectEqual(abi.kResultFalse, ctrl.setState(&st.iface));

    _ = ctrl.terminate();
    _ = abi.comRelease(ctrl);
    _ = abi.comRelease(comp);
    try finish(f);
}

test "fixture: the editor view attaches, resizes and releases in order" {
    const f = startTest();
    const ctrl = createFrom(f, abi.IEditController, &GAIN_CTRL_CID).?;
    try testing.expect(ctrl.createView("other") == null);
    try testing.expectEqual(@as(i64, 1), objects_alive.load(.seq_cst));
    const view = ctrl.createView("editor").?;
    try testing.expectEqual(@as(i64, 2), objects_alive.load(.seq_cst));

    try testing.expectEqual(abi.kResultTrue, view.isPlatformTypeSupported("NSView"));
    try testing.expectEqual(abi.kResultTrue, view.isPlatformTypeSupported("HWND"));
    try testing.expectEqual(abi.kResultTrue, view.isPlatformTypeSupported("X11EmbedWindowID"));
    try testing.expectEqual(abi.kResultFalse, view.isPlatformTypeSupported("Cocoa"));
    var r: abi.ViewRect = undefined;
    try testing.expectEqual(abi.kResultOk, view.getSize(&r));
    try testing.expectEqual(@as(i32, 320), r.right - r.left);
    try testing.expectEqual(@as(i32, 240), r.bottom - r.top);
    try testing.expectEqual(abi.kResultFalse, view.vtbl.canResize(view));

    // Removing before attaching is a contract failure.
    try testing.expectEqual(abi.kInvalidArgument, view.removed());
    try testing.expectEqual(@as(u32, 1), contract_failures.swap(0, .seq_cst));
    try testing.expectEqual(abi.kInvalidArgument, view.attached(null, "NSView"));
    var parent: u8 = 0;
    try testing.expectEqual(abi.kResultOk, view.attached(&parent, "NSView"));
    var bigger: abi.ViewRect = .{ .left = 0, .top = 0, .right = 640, .bottom = 480 };
    view_resizable.store(true, .monotonic);
    try testing.expectEqual(abi.kResultTrue, view.vtbl.canResize(view));
    try testing.expectEqual(abi.kResultOk, view.onSize(&bigger));
    try testing.expectEqual(@as(i32, 640), view_last_width.load(.monotonic));
    try testing.expectEqual(@as(i32, 480), view_last_height.load(.monotonic));
    try testing.expectEqual(abi.kResultOk, view.onFocus(true));
    try testing.expectEqual(abi.kResultOk, view.setFrame(null));
    try testing.expectEqual(abi.kResultOk, view.removed());
    try testing.expectEqual(@as(u32, 1), view_attaches.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), view_removes.load(.monotonic));

    // The view outlives its controller's last reference by its own count.
    _ = abi.comRelease(ctrl);
    try testing.expectEqual(@as(i64, 1), objects_alive.load(.seq_cst));
    _ = abi.comRelease(view);
    try finish(f);
}

fn synthSetup(f: *abi.IPluginFactory) struct { comp: *abi.IComponent, proc: *abi.IAudioProcessor } {
    const comp = createFrom(f, abi.IComponent, &SYNTH_CID).?;
    return .{ .comp = comp, .proc = abi.comCast(abi.IAudioProcessor, comp).? };
}

test "fixture: synth is sample accurate, records events and follows CC 7 and pressure" {
    const f = startTest();
    const s = synthSetup(f);
    try testing.expectEqual(@as(i32, 0), s.comp.getBusCount(abi.kAudio, abi.kInput));
    try testing.expectEqual(@as(i32, 1), s.comp.getBusCount(abi.kAudio, abi.kOutput));
    try testing.expectEqual(@as(i32, 1), s.comp.getBusCount(abi.kEvent, abi.kInput));
    var bus: abi.BusInfo = undefined;
    try testing.expectEqual(abi.kResultOk, s.comp.getBusInfo(abi.kEvent, abi.kInput, 0, &bus));
    try testing.expectEqual(@as(i32, 16), bus.channelCount);
    try testing.expectEqual(abi.kInvalidArgument, s.comp.getBusInfo(abi.kAudio, abi.kInput, 0, &bus));
    var cid: abi.TUID = undefined;
    try testing.expectEqual(abi.kNotImplemented, s.comp.getControllerClassId(&cid));
    var stereo: [1]abi.SpeakerArrangement = .{kStereo};
    try testing.expectEqual(abi.kResultTrue, s.proc.setBusArrangements(null, 0, &stereo, 1));
    try testing.expectEqual(abi.kResultFalse, s.proc.setBusArrangements(&stereo, 1, &stereo, 1));
    try testing.expectEqual(@as(u32, 0), s.proc.getLatencySamples());

    // The component is its own controller and MIDI mapping.
    const ctrl = abi.comCast(abi.IEditController, s.comp).?;
    const midi = abi.comCast(abi.IMidiMapping, s.comp).?;
    try testing.expectEqual(@as(i32, 0), ctrl.getParameterCount());
    try testing.expect(ctrl.createView("editor") == null);
    var pid: abi.ParamID = 0;
    try testing.expectEqual(abi.kResultOk, midi.getMidiControllerAssignment(0, 0, 7, &pid));
    try testing.expectEqual(VOLUME_PARAM, pid);
    try testing.expectEqual(abi.kResultFalse, midi.getMidiControllerAssignment(0, 0, 1, &pid));
    try testing.expectEqual(abi.kResultFalse, midi.getMidiControllerAssignment(1, 0, 7, &pid));

    var l: [8]f32 = @splat(-1);
    var r: [8]f32 = @splat(-1);
    var ptrs: [2]?[*]f32 = .{ &l, &r };
    var out_bus: [1]abi.AudioBusBuffers = .{.{ .numChannels = 2, .silenceFlags = 0, .channelBuffers = .{ .channelBuffers32 = &ptrs } }};
    var events: FakeEvents = .{};
    events.noteOn(2, 60, 0.8);
    events.noteOff(5, 60);
    var changes: FakeChanges = .{};
    var data: abi.ProcessData = .{
        .processMode = abi.kRealtime,
        .symbolicSampleSize = abi.kSample32,
        .numSamples = 8,
        .numInputs = 0,
        .numOutputs = 1,
        .inputs = null,
        .outputs = &out_bus,
        .inputParameterChanges = &changes.iface,
        .outputParameterChanges = null,
        .inputEvents = &events.iface,
        .outputEvents = null,
        .processContext = null,
    };
    try testing.expectEqual(abi.kResultOk, s.proc.process(&data));
    const want: [8]f32 = .{ 0, 0, 0.8, 0.8, 0.8, 0, 0, 0 };
    try testing.expectEqualSlices(f32, &want, &l);
    try testing.expectEqualSlices(f32, &want, &r);

    const rec = recordedEvents();
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqual(abi.EventTypes.kNoteOnEvent, rec[0].type);
    try testing.expectEqual(@as(i32, 2), rec[0].sample_offset);
    try testing.expectEqual(@as(i16, 60), rec[0].pitch);
    try testing.expectEqual(@as(f32, 0.8), rec[0].value);
    try testing.expectEqual(abi.EventTypes.kNoteOffEvent, rec[1].type);
    try testing.expectEqual(@as(i32, 5), rec[1].sample_offset);

    // Level carries over blocks; a note on at offset 0 then CC 7 (parameter 1) at offset 3.
    events = .{};
    events.noteOn(0, 61, 0.5);
    changes.put(VOLUME_PARAM, 3, 0.25);
    try testing.expectEqual(abi.kResultOk, s.proc.process(&data));
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25, 0.25 }, &l);
    // Poly pressure sets the level too, and the held level survives an empty block.
    events = .{};
    changes = .{};
    var pp = std.mem.zeroes(abi.Event);
    pp.sampleOffset = 1;
    pp.type = abi.EventTypes.kPolyPressureEvent;
    pp.payload.polyPressure = .{ .channel = 0, .pitch = 61, .pressure = 0.9, .noteId = -1 };
    _ = FakeEvents.add(&events.iface, &pp);
    try testing.expectEqual(abi.kResultOk, s.proc.process(&data));
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9 }, &l);
    events = .{};
    try testing.expectEqual(abi.kResultOk, s.proc.process(&data));
    try testing.expectEqual(@as(f32, 0.9), l[0]);

    _ = abi.comRelease(midi);
    _ = abi.comRelease(ctrl);
    _ = abi.comRelease(s.proc);
    _ = abi.comRelease(s.comp);
    try finish(f);
}

test "fixture: wide effects write 1.0 for matching buffers and -1.0 otherwise" {
    const f = startTest();
    const Layout = struct { cid: abi.TUID, buses: i32, channels: i32 };
    const layouts = [_]Layout{
        .{ .cid = WIDE16_CID, .buses = 16, .channels = 64 },
        .{ .cid = WIDE17_CID, .buses = 17, .channels = 2 },
        .{ .cid = WIDE65_CID, .buses = 1, .channels = 65 },
    };
    for (layouts) |l| {
        const comp = createFrom(f, abi.IComponent, &l.cid).?;
        const proc = abi.comCast(abi.IAudioProcessor, comp).?;
        try testing.expectEqual(l.buses, comp.getBusCount(abi.kAudio, abi.kInput));
        try testing.expectEqual(l.buses, comp.getBusCount(abi.kAudio, abi.kOutput));
        try testing.expectEqual(@as(i32, 0), comp.getBusCount(abi.kEvent, abi.kInput));
        var bus: abi.BusInfo = undefined;
        try testing.expectEqual(abi.kResultOk, comp.getBusInfo(abi.kAudio, abi.kInput, l.buses - 1, &bus));
        try testing.expectEqual(l.channels, bus.channelCount);
        try testing.expectEqual(abi.kInvalidArgument, comp.getBusInfo(abi.kAudio, abi.kInput, l.buses, &bus));
        try testing.expectEqual(@as(u32, 3), proc.getLatencySamples());
        try testing.expectEqual(abi.kResultFalse, proc.setBusArrangements(null, 0, null, 0));

        // Storage for the widest layout, shared by all buses.
        var chans: [65][2]f32 = undefined;
        var ptrs: [65]?[*]f32 = undefined;
        for (&ptrs, &chans) |*p, *c| p.* = c;
        var ins: [17]abi.AudioBusBuffers = undefined;
        var outs: [17]abi.AudioBusBuffers = undefined;
        const n: usize = @intCast(l.buses);
        for (0..n) |i| {
            ins[i] = .{ .numChannels = l.channels, .silenceFlags = 0, .channelBuffers = .{ .channelBuffers32 = &ptrs } };
            outs[i] = ins[i];
        }
        var data: abi.ProcessData = .{
            .processMode = abi.kRealtime,
            .symbolicSampleSize = abi.kSample32,
            .numSamples = 2,
            .numInputs = l.buses,
            .numOutputs = l.buses,
            .inputs = &ins,
            .outputs = &outs,
            .inputParameterChanges = null,
            .outputParameterChanges = null,
            .inputEvents = null,
            .outputEvents = null,
            .processContext = null,
        };
        try testing.expectEqual(abi.kResultOk, proc.process(&data));
        for (chans[0..@intCast(l.channels)]) |c| try testing.expectEqualSlices(f32, &.{ 1, 1 }, &c);

        // Wrong channel count on one input bus, then a wrong bus count.
        ins[n - 1].numChannels = l.channels - 1;
        try testing.expectEqual(abi.kResultOk, proc.process(&data));
        for (chans[0..@intCast(l.channels)]) |c| try testing.expectEqualSlices(f32, &.{ -1, -1 }, &c);
        ins[n - 1].numChannels = l.channels;
        data.numOutputs = l.buses - 1;
        try testing.expectEqual(abi.kResultOk, proc.process(&data));
        for (chans[0..@intCast(l.channels)]) |c| try testing.expectEqualSlices(f32, &.{ -1, -1 }, &c);

        _ = abi.comRelease(proc);
        _ = abi.comRelease(comp);
    }
    try finish(f);
}

test "fixture: module exit with objects alive or without an entry is a violation" {
    reset();
    // Exit without entry.
    try testing.expect(!moduleExit());
    try testing.expectEqual(@as(u32, 1), violations.load(.seq_cst));
    try testing.expectEqualStrings("module exit without a module entry", last_violation);

    // Exit with the factory and an object still alive (the wrong release order).
    reset();
    var token: u8 = 0;
    try testing.expect(!moduleEntry(null));
    try testing.expect(moduleEntry(&token));
    const f = getPluginFactory().?;
    const comp = createFrom(f, abi.IComponent, &GAIN_CID).?;
    try testing.expect(!moduleExit());
    try testing.expectEqual(@as(u32, 1), violations.load(.seq_cst));
    // The right order: object, factory, then exit.
    reset();
    try testing.expect(moduleEntry(&token));
    _ = abi.comRelease(comp);
    _ = abi.comRelease(f);
    try testing.expect(moduleExit());
    try testing.expectEqual(@as(u32, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), entered.load(.seq_cst));

    // Nested entries only check at the outermost exit; another thread's exit is a violation.
    reset();
    try testing.expect(moduleEntry(&token));
    try testing.expect(moduleEntry(&token));
    try testing.expect(moduleExit());
    const t = try std.Thread.spawn(.{}, struct {
        fn run() void {
            _ = moduleExit();
        }
    }.run, .{});
    t.join();
    try testing.expectEqual(@as(u32, 1), violations.load(.seq_cst));
    try testing.expectEqualStrings("module exit on another thread than the module entry", last_violation);
    reset();
}

test "fixture: adopted into a registry the exit runs after the factory is released" {
    reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;
    const b = try adopt(&reg, "fixture.vst3", .main);
    try testing.expectEqual(@as(i64, 1), factories_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 1), entered.load(.seq_cst));

    const comp = b.create(abi.IComponent, &GAIN_CID).?;
    const synth = b.create(abi.IComponent, &SYNTH_CID).?;
    try testing.expectEqual(@as(i64, 2), objects_alive.load(.seq_cst));
    _ = abi.comRelease(synth);
    _ = abi.comRelease(comp);

    // Bundle.exit releases the factory, then runs the module exit.
    reg.exitModules();
    try testing.expectEqual(@as(i64, 0), factories_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), objects_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), entered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), violations.load(.seq_cst));
    reset();
}
