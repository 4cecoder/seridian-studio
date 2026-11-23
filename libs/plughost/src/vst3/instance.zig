// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/instance.rs, soundcraft/crates/vst3-host/src/ffi/module.rs (Bundle::instantiate), soundcraft/crates/vst3-host/src/registry.rs (parameter table), soundcraft/crates/vst3-host/src/plugin.rs (value mapping) (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! A live VST3 plugin instance: creation from a factory, the split-or-combined component and
//! controller handling, bus negotiation and activation, the processing lifecycle, the
//! parameter table, state save and load, and the teardown order.
//!
//! Threading. Everything except `process` is control-thread code (it allocates and calls into
//! the plugin's non-realtime methods). `process` is the only audio-thread entry: it allocates
//! nothing, takes no lock, logs nothing and does no I/O of its own; it fills the preallocated
//! `ProcessBlock` (see `process.zig`) and calls `IAudioProcessor::process`. An instance is used
//! through `*Instance` by one thread at a time (the caller serialises), as in the Rust code.
//!
//! Teardown order (`destroy`, kept from the Rust `Drop`, with the module exit rules of
//! `module.zig` in mind): the editor is closed and cut off first (`EditorLink.kill`; a leaked
//! view marks the bundle so its module is never exited), then processing stops and the component
//! is deactivated, the connection points are disconnected, the controller loses its component
//! handler and is terminated (only when it was created separately), the processor reference is
//! dropped, the component is terminated, and finally the component, the host context and the
//! bundle reference are released. The bundle goes last: it keeps the plugin's code mapped.
//!
//! Differences from the Rust code, all deliberate:
//! * `Instance.create` is `Bundle::instantiate` (module.zig leaves it to this file). The
//!   instance is heap allocated (`*Instance`); `destroy` replaces `Drop`.
//! * Parameters are addressed by a dense index into `ParamTable` (built once, control thread).
//!   The Rust `process` took per-call `params` / `controls` / `notes`; here the caller passes
//!   `event.Event`s and `ProcessBlock.begin` converts them (notes, MIDI pressure and
//!   parameter changes) without allocating.
//! * All process buffers (audio buses, parameter queues, event lists) are allocated in
//!   `configure`, never in `process`. The caller writes the input channels through
//!   `inputs()` and reads the output channels through `outputs()`.
//! * `setProcessing(true)` happens at the end of `configure` (control thread), not lazily on
//!   the first `process` call, so the audio thread never calls it.
//! * `configure` also refuses a non-finite or non-positive sample rate and a zero block size.
//! * Errors are an error set (`Error`); the Rust code formatted strings.
//! * State blobs are hostile input: `splitState` bounds the sizes, the memory streams are
//!   capped at `abi.MAX_STATE_BYTES`, and a refused load keeps the previous state.

const std = @import("std");
const abi = @import("abi.zig");
const host_mod = @import("host.zig");
const process_mod = @import("process.zig");
const module = @import("module.zig");
const editor_mod = @import("editor.zig");
const event = @import("../event.zig");
const params_mod = @import("../params.zig");
const plugin = @import("../plugin.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vst3);

pub const Bundle = module.Bundle;
pub const EditorLink = editor_mod.EditorLink;
pub const HostContext = host_mod.HostContext;
pub const ProcessBlock = process_mod.ProcessBlock;
pub const BusBuffers = process_mod.BusBuffers;
pub const ParamInfo = params_mod.ParamInfo;

/// `ProcessContext` from the host transport (shared with `process.zig`).
pub const applyTransport = process_mod.applyTransport;

pub const PARAM_HIDDEN: i32 = abi.kIsHidden;
pub const PARAM_READ_ONLY: i32 = abi.kIsReadOnly;
pub const PARAM_BYPASS: i32 = abi.kIsBypass;

/// Most labels read for a stepped parameter (more steps are shown as a plain range).
pub const MAX_CHOICES: i32 = 128;

/// `Steinberg::Vst::SpeakerArr::kMono` and `kStereo`.
pub const SPEAKER_MONO: abi.SpeakerArrangement = 1 << 19;
pub const SPEAKER_STEREO: abi.SpeakerArrangement = 3;

/// The tempo and time signature a freshly configured instance reports before the first
/// transport arrives.
const DEFAULT_TEMPO: f64 = 120.0;
const DEFAULT_TIME_SIG: i32 = 4;

pub const Error = error{
    OutOfMemory,
    /// The factory cannot create the class as an `IComponent`.
    FactoryCannotCreateComponent,
    ComponentInitializeFailed,
    NoAudioProcessor,
    /// More audio buses than `abi.MAX_BUSES` in one direction.
    TooManyBuses,
    /// More channels than `abi.MAX_BUS_CHANNELS` on one bus.
    TooManyBusChannels,
    /// The sample rate or block size is unusable.
    BadConfig,
    Cannot32Bit,
    SetupProcessingFailed,
    SetActiveFailed,
    /// `process` before a successful `configure`.
    NotActive,
    /// The block is empty or larger than the configured size.
    BlockTooLarge,
    /// The plugin's `process` returned an error code.
    ProcessFailed,
};

/// One parameter as reported by `IEditController::getParameterInfo`. The strings are owned by the
/// caller's allocator (`freeParams`).
pub const RawParam = struct {
    id: u32,
    title: []u8,
    units: []u8,
    step_count: i32,
    default_normalized: f64,
    flags: i32,
};

/// Frees a list from `Instance.params`.
pub fn freeParams(gpa: Allocator, list: []RawParam) void {
    for (list) |p| {
        gpa.free(p.title);
        gpa.free(p.units);
    }
    gpa.free(list);
}

/// The audio bus layout chosen by `Instance.configure`.
pub const Layout = struct {
    in_buf: [@as(usize, @intCast(abi.MAX_BUSES))]u32 = @splat(0),
    out_buf: [@as(usize, @intCast(abi.MAX_BUSES))]u32 = @splat(0),
    n_in: usize = 0,
    n_out: usize = 0,
    event_input: bool = false,

    /// Channels of each input bus.
    pub fn inputs(self: *const Layout) []const u32 {
        return self.in_buf[0..self.n_in];
    }
    /// Channels of each output bus.
    pub fn outputs(self: *const Layout) []const u32 {
        return self.out_buf[0..self.n_out];
    }
};

/// `"input"` or `"output"`.
pub fn dirName(dir: abi.BusDirection) []const u8 {
    return if (dir == abi.kInput) "input" else "output";
}

// ---- parameter table ---------------------------------------------------------------------------

/// How a plug-0 value maps onto the controller's normalized value (`plugin.rs` `Mapping`).
pub const Mapping = union(enum) {
    /// The controller's own plain range matches the table's `min` / `max`.
    plain,
    /// A straight line between `min` and `max`.
    linear,
    /// A toggle or choice with this many steps: normalized = value / steps.
    stepped: f64,
};

/// The usable parameters of a controller as plug-0 `ParamInfo`s, in dense-index order. Hidden,
/// read-only and bypass parameters are left out. Built once on the control thread; `infos` stays
/// valid until `deinit`.
pub const ParamTable = struct {
    arena: std.heap.ArenaAllocator,
    /// VST3 `ParamID` of each entry.
    ids: []abi.ParamID,
    infos: []ParamInfo,
    maps: []Mapping,

    pub fn deinit(self: *ParamTable) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Dense index of a VST3 parameter id (linear scan; control thread).
    pub fn indexOfId(self: *const ParamTable, id: abi.ParamID) ?usize {
        return std.mem.indexOfScalar(abi.ParamID, self.ids, id);
    }
};

/// Maps a VST3 unit label to a display unit.
pub fn unitFromLabel(units: []const u8) params_mod.Unit {
    const t = std.mem.trim(u8, units, " \t\r\n\x0b\x0c");
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(t, "db")) return .db;
    if (eq(t, "hz")) return .hz;
    if (eq(t, "ms")) return .ms;
    if (eq(t, "%")) return .percent;
    if (eq(t, "s") or eq(t, "sec") or eq(t, "secs") or eq(t, "seconds")) return .seconds;
    if (eq(t, "st") or eq(t, "semi") or eq(t, "semitones")) return .semitones;
    if (eq(t, "ct") or eq(t, "cent") or eq(t, "cents")) return .cents;
    return .none;
}

// ---- state container ---------------------------------------------------------------------------

/// The two halves of a state blob.
pub const SplitState = struct { component: []const u8, controller: []const u8 };

/// Splits a state blob into (component, controller) parts. A blob without Seridian's container
/// header is taken as a bare component state. The blob is hostile: it is bounded by twice
/// `abi.MAX_STATE_BYTES`, each part by `abi.MAX_STATE_BYTES`, and trailing bytes are refused.
pub fn splitState(data: []const u8) ?SplitState {
    if (data.len > abi.MAX_STATE_BYTES *| 2) return null;
    if (!std.mem.startsWith(u8, data, abi.STATE_MAGIC)) {
        if (data.len == 0) return null;
        return .{ .component = data, .controller = &.{} };
    }
    const rest = data[abi.STATE_MAGIC.len..];
    const first = takePart(rest) orelse return null;
    const rest2 = rest[first.end..];
    const second = takePart(rest2) orelse return null;
    if (second.end != rest2.len) return null;
    return .{ .component = first.bytes, .controller = second.bytes };
}

/// One length-prefixed part: `u32` little-endian length, then that many bytes.
fn takePart(b: []const u8) ?struct { bytes: []const u8, end: usize } {
    if (b.len < 4) return null;
    const n: usize = std.mem.readInt(u32, b[0..4], .little);
    if (n > abi.MAX_STATE_BYTES or b.len < 4 + n) return null;
    return .{ .bytes = b[4 .. 4 + n], .end = 4 + n };
}

// ---- the instance ------------------------------------------------------------------------------

/// A live plugin: component + audio processor (+ edit controller) and the host objects.
pub const Instance = struct {
    gpa: Allocator,
    /// One bundle reference, released last.
    bundle: *Bundle,
    component: *abi.IComponent,
    host: *HostContext,
    processor: ?*abi.IAudioProcessor = null,
    controller: ?*abi.IEditController = null,
    /// The controller is the component itself (single-component plugin).
    single: bool = false,
    connections: ?struct { a: *abi.IConnectionPoint, b: *abi.IConnectionPoint } = null,
    component_initialized: bool = false,
    controller_initialized: bool = false,
    active: bool = false,
    processing: bool = false,
    max_frames: u32 = 0,
    event_in: bool = false,
    /// Process buffers, queues and context; allocated by `configure`.
    block: ?ProcessBlock = null,
    table: ?ParamTable = null,
    editor_link: *EditorLink,

    /// Creates, initialises and wires up one plugin instance of class `cid` from `bundle`
    /// (`Bundle::instantiate`). Control thread. The instance holds its own bundle reference.
    pub fn create(gpa: Allocator, bundle: *Bundle, cid: *const [16]u8) Error!*Instance {
        const component = bundle.create(abi.IComponent, cid) orelse return error.FactoryCannotCreateComponent;
        var component_owned = true;
        defer if (component_owned) {
            _ = abi.comRelease(component);
        };
        const hc = try HostContext.create(gpa);
        var hc_owned = true;
        defer if (hc_owned) hc.release();
        const link = try EditorLink.create(gpa);
        var link_owned = true;
        defer if (link_owned) link.release();
        const self = try gpa.create(Instance);
        var self_owned = true;
        defer if (self_owned) gpa.destroy(self);

        const host_unknown: *abi.FUnknown = @ptrCast(hc.hostApplication());
        if (!abi.ok(component.initialize(host_unknown))) {
            // Not initialised: released without `terminate`, as in the Rust code.
            return error.ComponentInitializeFailed;
        }
        self.* = .{
            .gpa = gpa,
            .bundle = bundle.acquire(),
            .component = component,
            .host = hc,
            .component_initialized = true,
            .editor_link = link,
        };
        component_owned = false;
        hc_owned = false;
        link_owned = false;
        self_owned = false;
        // From here `destroy` undoes everything in the right order.
        errdefer self.destroy();

        self.processor = abi.comCast(abi.IAudioProcessor, component) orelse return error.NoAudioProcessor;
        // Edit controller: the component itself (single-component plugin) or a separate class.
        if (abi.comCast(abi.IEditController, component)) |c| {
            self.controller = c;
            self.single = true;
        } else {
            var ccid: abi.TUID = @splat(0);
            if (abi.ok(component.getControllerClassId(&ccid))) {
                if (bundle.create(abi.IEditController, &module.tuidBytes(&ccid))) |c| {
                    if (abi.ok(c.initialize(host_unknown))) {
                        self.controller = c;
                        self.controller_initialized = true;
                    } else {
                        log.warn("vst3 {s}: controller initialize failed; parameters unavailable", .{&abi.hex(cid)});
                        _ = abi.comRelease(c);
                    }
                }
            }
        }
        if (self.controller) |c| {
            if (!self.single) {
                const a = abi.comCast(abi.IConnectionPoint, component);
                const b = abi.comCast(abi.IConnectionPoint, c);
                if (a != null and b != null) {
                    _ = a.?.connect(b.?);
                    _ = b.?.connect(a.?);
                    self.connections = .{ .a = a.?, .b = b.? };
                } else {
                    if (a) |p| _ = abi.comRelease(p);
                    if (b) |p| _ = abi.comRelease(p);
                }
            }
            self.syncControllerState();
            _ = c.setComponentHandler(hc.componentHandler());
        }
        link.bind(component, self.controller);
        return self;
    }

    /// The reverse of `create` (`Drop`): see the module docs for the order. Control thread.
    pub fn destroy(self: *Instance) void {
        const gpa = self.gpa;
        const bundle = self.bundle;
        // Close any editor and cut its handles off before the controller goes away.
        if (self.editor_link.kill()) bundle.markLeaked();
        self.shutdown();
        if (self.connections) |c| {
            // The pair was connected in `create`; disconnect before terminating.
            _ = c.a.disconnect(c.b);
            _ = c.b.disconnect(c.a);
            _ = abi.comRelease(c.a);
            _ = abi.comRelease(c.b);
            self.connections = null;
        }
        if (self.controller) |c| {
            // Detach our handler before the controller goes away.
            _ = c.setComponentHandler(null);
            if (self.controller_initialized) _ = c.terminate();
            _ = abi.comRelease(c);
            self.controller = null;
        }
        if (self.processor) |p| _ = abi.comRelease(p);
        self.processor = null;
        if (self.component_initialized) {
            _ = self.component.terminate();
            self.component_initialized = false;
        }
        _ = abi.comRelease(self.component);
        if (self.block) |*b| b.deinit();
        if (self.table) |*t| t.deinit();
        self.editor_link.release();
        self.host.release();
        gpa.destroy(self);
        // The bundle keeps the plugin's code mapped: it goes last.
        bundle.release();
    }

    pub fn hostContext(self: *Instance) *HostContext {
        return self.host;
    }

    /// The editor link shared with editor handles, with a reference added for the caller (null
    /// without an edit controller). `EditorHandle.init` takes its own reference.
    pub fn editor(self: *Instance) ?*EditorLink {
        return if (self.editor_link.hasController()) self.editor_link.retain() else null;
    }

    /// The same link, for state handles; the caller releases the reference.
    pub fn stateLink(self: *Instance) *EditorLink {
        return self.editor_link.retain();
    }

    // ---- state ---------------------------------------------------------------------------------

    /// Restores an `EditorLink.saveState` blob (or a bare component state): component `setState`,
    /// then the controller's `setComponentState` and `setState`. False when the blob is malformed
    /// or the component refuses it (then nothing else was touched).
    pub fn loadState(self: *Instance, data: []const u8) Error!bool {
        const parts = splitState(data) orelse return false;
        const stream = try process_mod.MemoryStream.create(self.gpa, parts.component);
        defer stream.release();
        if (!abi.ok(self.component.setState(stream.interface()))) return false;
        if (self.controller) |c| {
            stream.pos = 0;
            _ = c.setComponentState(stream.interface());
            if (parts.controller.len > 0) {
                const cs = try process_mod.MemoryStream.create(self.gpa, parts.controller);
                defer cs.release();
                _ = c.setState(cs.interface());
            }
        }
        return true;
    }

    /// Copies the component's state into the controller (`getState` then `setComponentState`).
    fn syncControllerState(self: *Instance) void {
        const c = self.controller orelse return;
        const stream = process_mod.MemoryStream.create(self.gpa, &.{}) catch return;
        defer stream.release();
        if (abi.ok(self.component.getState(stream.interface()))) {
            stream.pos = 0;
            _ = c.setComponentState(stream.interface());
        }
    }

    // ---- parameters ----------------------------------------------------------------------------

    /// The controller's parameters (at most `abi.MAX_PARAMS`; the count is hostile input). Free
    /// with `freeParams`.
    pub fn params(self: *Instance, gpa: Allocator) Allocator.Error![]RawParam {
        const c = self.controller orelse return gpa.alloc(RawParam, 0);
        const n = std.math.clamp(c.getParameterCount(), 0, abi.MAX_PARAMS);
        var out: std.ArrayList(RawParam) = .empty;
        errdefer {
            for (out.items) |p| {
                gpa.free(p.title);
                gpa.free(p.units);
            }
            out.deinit(gpa);
        }
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            var info = std.mem.zeroes(abi.ParameterInfo);
            if (!abi.ok(c.getParameterInfo(i, &info))) continue;
            const d = info.defaultNormalizedValue;
            const title = try abi.readC16(gpa, &info.title);
            errdefer gpa.free(title);
            const units = try abi.readC16(gpa, &info.units);
            errdefer gpa.free(units);
            try out.append(gpa, .{
                .id = info.id,
                .title = title,
                .units = units,
                .step_count = @max(info.stepCount, 0),
                .default_normalized = if (std.math.isFinite(d)) std.math.clamp(d, 0.0, 1.0) else 0.0,
                .flags = info.flags,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Normalized to plain (null without a controller or for a non-finite answer).
    pub fn toPlain(self: *Instance, id: u32, normalized: f64) ?f64 {
        const c = self.controller orelse return null;
        return editor_mod.controllerToPlain(c, id, normalized);
    }

    /// Plain to normalized, clamped to 0..1.
    pub fn toNormalized(self: *Instance, id: u32, plain: f64) ?f64 {
        const c = self.controller orelse return null;
        return editor_mod.controllerToNormalized(c, id, plain);
    }

    pub fn normalizedValue(self: *Instance, id: u32) ?f64 {
        const c = self.controller orelse return null;
        const v = c.getParamNormalized(id);
        return if (std.math.isFinite(v)) std.math.clamp(v, 0.0, 1.0) else null;
    }

    /// The plugin's own text for a normalized value, owned by the caller; null when refused or
    /// empty.
    pub fn valueText(self: *Instance, gpa: Allocator, id: u32, normalized: f64) Allocator.Error!?[]u8 {
        const c = self.controller orelse return null;
        return editor_mod.controllerValueText(gpa, c, id, normalized);
    }

    /// The parameter each MIDI controller drives on channel 1 (`IMidiMapping`), indexed by VST3's
    /// controller numbers: CCs 0 to 127, then `abi.AFTERTOUCH` and `abi.PITCH_BEND`. Empty
    /// without the interface. Main thread only. Free with `gpa.free`.
    pub fn midiMapping(self: *Instance, gpa: Allocator) Allocator.Error![]?u32 {
        const c = self.controller orelse return gpa.alloc(?u32, 0);
        const m = abi.comCast(abi.IMidiMapping, c) orelse return gpa.alloc(?u32, 0);
        defer _ = abi.comRelease(m);
        const out = try gpa.alloc(?u32, abi.PITCH_BEND + 1);
        for (out, 0..) |*slot, n| {
            var id: abi.ParamID = 0;
            const cc: i16 = @intCast(n);
            slot.* = if (abi.ok(m.getMidiControllerAssignment(0, 0, cc, &id))) id else null;
        }
        return out;
    }

    /// Builds (once) and returns the plug-0 parameter table (`registry.rs` `param_info` and
    /// `plugin.rs` `Mapping`). Control thread; the table lives until `destroy`.
    pub fn paramTable(self: *Instance) Allocator.Error!*const ParamTable {
        if (self.table) |*t| return t;
        const raw = try self.params(self.gpa);
        defer freeParams(self.gpa, raw);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var ids: std.ArrayList(abi.ParamID) = .empty;
        var infos: std.ArrayList(ParamInfo) = .empty;
        var maps: std.ArrayList(Mapping) = .empty;
        for (raw) |p| {
            if (p.flags & (PARAM_HIDDEN | PARAM_READ_ONLY | PARAM_BYPASS) != 0) continue;
            const info = try self.buildInfo(a, p);
            try ids.append(a, p.id);
            try infos.append(a, info);
            try maps.append(a, self.mappingFor(p.id, info));
        }
        self.table = .{ .arena = arena, .ids = ids.items, .infos = infos.items, .maps = maps.items };
        return &self.table.?;
    }

    fn buildInfo(self: *Instance, a: Allocator, p: RawParam) Allocator.Error!ParamInfo {
        const name = if (p.title.len == 0) try std.fmt.allocPrint(a, "Param {d}", .{p.id}) else try a.dupe(u8, p.title);
        var info: ParamInfo = .{
            .id = try std.fmt.allocPrint(a, "{d}", .{p.id}),
            .name = name,
            .min = 0.0,
            .max = 1.0,
            .default = 0.0,
            .unit = .none,
            .taper = .linear,
        };
        if (p.step_count == 1) {
            info.unit = .toggle;
            info.default = @floatCast(@round(p.default_normalized));
            return info;
        }
        if (p.step_count >= 2 and p.step_count <= MAX_CHOICES) {
            const steps: f64 = @floatFromInt(p.step_count);
            const labels = try a.alloc([]const u8, @intCast(p.step_count + 1));
            for (labels, 0..) |*l, i| {
                const frac = @as(f64, @floatFromInt(i)) / steps;
                l.* = (try self.valueText(a, p.id, frac)) orelse try std.fmt.allocPrint(a, "{d}", .{i});
            }
            info.max = @floatFromInt(p.step_count);
            info.default = @floatCast(@round(p.default_normalized * steps));
            info.unit = .choice;
            info.choices = labels;
            return info;
        }
        // Continuous (or too many steps for a menu): the plain range from the controller.
        info.unit = unitFromLabel(p.units);
        const lo_o = self.toPlain(p.id, 0.0);
        const hi_o = self.toPlain(p.id, 1.0);
        if (lo_o != null and hi_o != null) {
            const lo = lo_o.?;
            const hi = hi_o.?;
            const lo32: f32 = @floatCast(lo);
            const hi32: f32 = @floatCast(hi);
            if (hi > lo and std.math.isFinite(lo32) and std.math.isFinite(hi32) and hi32 > lo32) {
                const def = if (self.toPlain(p.id, p.default_normalized)) |d| std.math.clamp(d, lo, hi) else lo;
                // A logarithmic plugin mapping (frequency knobs) shows its geometric mean at mid travel.
                var taper: params_mod.Taper = .linear;
                if (self.toPlain(p.id, 0.5)) |mid| {
                    const geo = @sqrt(lo * hi);
                    if (lo > 0.0 and @abs(mid - geo) <= 0.01 * geo and @abs(mid - (lo + hi) / 2.0) > 0.01 * (hi - lo)) taper = .log;
                }
                info.min = lo32;
                info.max = hi32;
                info.default = @floatCast(def);
                info.taper = taper;
                return info;
            }
        }
        info.default = @floatCast(p.default_normalized);
        return info;
    }

    fn mappingFor(self: *Instance, id: u32, info: ParamInfo) Mapping {
        switch (info.unit) {
            .toggle, .choice => return .{ .stepped = @as(f64, @max(info.max, 1.0)) },
            else => {},
        }
        const lo = self.toPlain(id, 0.0);
        const hi = self.toPlain(id, 1.0);
        if (lo != null and hi != null) {
            const lo32: f32 = @floatCast(lo.?);
            const hi32: f32 = @floatCast(hi.?);
            if (@abs(lo32 - info.min) <= 1e-6 * @max(@abs(info.min), 1.0) and @abs(hi32 - info.max) <= 1e-6 * @max(@abs(info.max), 1.0)) return .plain;
        }
        return .linear;
    }

    /// The table value of dense parameter `index` for a normalized value (null on an unusable
    /// answer). Control thread.
    pub fn plainFromNormalized(self: *Instance, index: usize, n: f64) ?f32 {
        const t: *const ParamTable = if (self.table) |*x| x else return null;
        if (index >= t.ids.len) return null;
        const pi = t.infos[index];
        const v: f64 = switch (t.maps[index]) {
            .stepped => |steps| @round(n * steps),
            .plain => self.toPlain(t.ids[index], n) orelse return null,
            .linear => @as(f64, pi.min) + n * @as(f64, pi.max - pi.min),
        };
        return if (std.math.isFinite(v)) @floatCast(v) else null;
    }

    /// The normalized value for a table value of dense parameter `index`, clamped to 0..1.
    pub fn normalizedFromPlain(self: *Instance, index: usize, v: f32) ?f64 {
        const t: *const ParamTable = if (self.table) |*x| x else return null;
        if (index >= t.ids.len) return null;
        const pi = t.infos[index];
        const span: f64 = @as(f64, pi.max) - @as(f64, pi.min);
        const linear: f64 = if (span > 0.0) (@as(f64, v) - @as(f64, pi.min)) / span else 0.0;
        const n: f64 = switch (t.maps[index]) {
            .stepped => |steps| if (steps > 0.0) @as(f64, v) / steps else 0.0,
            .plain => self.toNormalized(t.ids[index], v) orelse linear,
            .linear => linear,
        };
        return if (std.math.isFinite(n)) std.math.clamp(n, 0.0, 1.0) else null;
    }

    // ---- latency and tail ----------------------------------------------------------------------

    pub fn latency(self: *Instance) u32 {
        return if (self.processor) |p| p.getLatencySamples() else 0;
    }

    pub fn tail(self: *Instance) u32 {
        return if (self.processor) |p| p.getTailSamples() else 0;
    }

    pub fn isActive(self: *const Instance) bool {
        return self.active;
    }

    // ---- buses ---------------------------------------------------------------------------------

    fn busCount(self: *Instance, media: abi.MediaType, dir: abi.BusDirection) i32 {
        return @max(self.component.getBusCount(media, dir), 0);
    }

    /// The plugin's audio buses in one direction. More than `abi.MAX_BUSES` is an error: we never
    /// hand a plugin fewer buses than it advertised.
    fn audioBusCount(self: *Instance, dir: abi.BusDirection) Error!i32 {
        const n = self.busCount(abi.kAudio, dir);
        if (n > abi.MAX_BUSES) {
            log.warn("{d} audio {s} buses (at most {d} supported)", .{ n, dirName(dir), abi.MAX_BUSES });
            return error.TooManyBuses;
        }
        return n;
    }

    fn arrangement(self: *Instance, dir: abi.BusDirection, index: i32) ?abi.SpeakerArrangement {
        const p = self.processor orelse return null;
        var arr: abi.SpeakerArrangement = 0;
        return if (abi.ok(p.getBusArrangement(dir, index, &arr))) arr else null;
    }

    /// Channels of one audio bus. More than `abi.MAX_BUS_CHANNELS` is an error, as for the bus count.
    fn busChannels(self: *Instance, dir: abi.BusDirection, index: i32) Error!u32 {
        const channels: u32 = if (self.arrangement(dir, index)) |arr| @popCount(arr) else blk: {
            var info = std.mem.zeroes(abi.BusInfo);
            if (abi.ok(self.component.getBusInfo(abi.kAudio, dir, index, &info))) {
                break :blk std.math.cast(u32, info.channelCount) orelse 0;
            }
            break :blk 0;
        };
        if (channels > abi.MAX_BUS_CHANNELS) {
            log.warn("audio {s} bus {d} has {d} channels (at most {d} supported)", .{ dirName(dir), index, channels, abi.MAX_BUS_CHANNELS });
            return error.TooManyBusChannels;
        }
        return channels;
    }

    /// Stops processing, deactivates, negotiates the bus layout (main buses mono or stereo as
    /// asked, falling back to stereo and then to the plugin's own choice), activates the main
    /// buses, sets up 32-bit processing, allocates the process buffers and activates the
    /// component, then starts processing. A layout beyond `abi.MAX_BUSES` buses or
    /// `abi.MAX_BUS_CHANNELS` channels per bus is an error, and the component stays inactive.
    /// Control thread.
    pub fn configure(self: *Instance, sample_rate: f64, max_frames: u32, mono: bool) Error!Layout {
        self.shutdown();
        if (self.block) |*b| b.deinit();
        self.block = null;
        if (!std.math.isFinite(sample_rate) or sample_rate <= 0 or max_frames == 0) return error.BadConfig;
        const p = self.processor orelse return error.NoAudioProcessor;
        const nin = try self.audioBusCount(abi.kInput);
        const nout = try self.audioBusCount(abi.kOutput);
        const want: abi.SpeakerArrangement = if (mono) SPEAKER_MONO else SPEAKER_STEREO;
        var tried_ok = false;
        const attempts = [_]abi.SpeakerArrangement{ want, SPEAKER_STEREO };
        for (attempts) |main| {
            var ins: [@as(usize, @intCast(abi.MAX_BUSES))]abi.SpeakerArrangement = undefined;
            var outs: [@as(usize, @intCast(abi.MAX_BUSES))]abi.SpeakerArrangement = undefined;
            var i: i32 = 0;
            while (i < nin) : (i += 1) ins[@intCast(i)] = self.arrangement(abi.kInput, i) orelse SPEAKER_STEREO;
            i = 0;
            while (i < nout) : (i += 1) outs[@intCast(i)] = self.arrangement(abi.kOutput, i) orelse SPEAKER_STEREO;
            if (nin > 0) ins[0] = main;
            if (nout > 0) outs[0] = main;
            // The arrays hold exactly `nin` / `nout` arrangements and outlive the call.
            if (abi.ok(p.setBusArrangements(&ins, nin, &outs, nout))) {
                tried_ok = true;
                break;
            }
            if (main == SPEAKER_STEREO) break;
        }
        if (!tried_ok) log.debug("plugin refused mono/stereo bus arrangements; using its own", .{});
        var layout: Layout = .{};
        var i: i32 = 0;
        while (i < nin) : (i += 1) {
            layout.in_buf[@intCast(i)] = try self.busChannels(abi.kInput, i);
        }
        layout.n_in = @intCast(nin);
        i = 0;
        while (i < nout) : (i += 1) {
            layout.out_buf[@intCast(i)] = try self.busChannels(abi.kOutput, i);
        }
        layout.n_out = @intCast(nout);
        layout.event_input = self.busCount(abi.kEvent, abi.kInput) > 0;
        // Main buses on, aux buses off (VST3 still gets buffers for every bus).
        for ([_]struct { dir: abi.BusDirection, n: i32 }{ .{ .dir = abi.kInput, .n = nin }, .{ .dir = abi.kOutput, .n = nout } }) |d| {
            i = 0;
            while (i < d.n) : (i += 1) _ = self.component.activateBus(abi.kAudio, d.dir, i, i == 0);
        }
        if (layout.event_input) _ = self.component.activateBus(abi.kEvent, abi.kInput, 0, true);
        self.event_in = layout.event_input;
        if (!abi.ok(p.canProcessSampleSize(abi.kSample32))) return error.Cannot32Bit;
        var setup: abi.ProcessSetup = .{
            .processMode = abi.kRealtime,
            .symbolicSampleSize = abi.kSample32,
            .maxSamplesPerBlock = std.math.cast(i32, max_frames) orelse std.math.maxInt(i32),
            .sampleRate = sample_rate,
        };
        if (!abi.ok(p.setupProcessing(&setup))) return error.SetupProcessingFailed;

        // Seridian: preallocated here, Rust allocated per block. The table must exist first: the
        // parameter queues are keyed by its ids.
        const table = try self.paramTable();
        var block = try ProcessBlock.init(self.gpa, .{
            .sample_rate = sample_rate,
            .max_frames = max_frames,
            .in_channels = layout.inputs(),
            .out_channels = layout.outputs(),
            .param_ids = table.ids,
            .param_cap = abi.PARAM_QUEUE_CAP,
            .event_cap = abi.EVENT_CAP,
        });
        errdefer block.deinit();
        block.context.tempo = DEFAULT_TEMPO;
        block.context.timeSigNumerator = DEFAULT_TIME_SIG;
        block.context.timeSigDenominator = DEFAULT_TIME_SIG;
        block.context.state = abi.ProcessStates.kTempoValid | abi.ProcessStates.kTimeSigValid;

        if (!abi.ok(self.component.setActive(true))) return error.SetActiveFailed;
        self.active = true;
        self.max_frames = max_frames;
        self.block = block;
        // Many plugins return kNotImplemented here; that is not an error.
        _ = p.setProcessing(true);
        self.processing = true;
        _ = self.host.latency_changed.swap(false, .monotonic);
        return layout;
    }

    /// `setProcessing(false)` and `setActive(false)` when needed.
    pub fn shutdown(self: *Instance) void {
        if (self.processing) {
            if (self.processor) |p| _ = p.setProcessing(false);
            self.processing = false;
        }
        if (self.active) {
            _ = self.component.setActive(false);
            self.active = false;
        }
    }

    // ---- processing ----------------------------------------------------------------------------

    /// The input channels the caller fills before `process` (null before `configure`).
    pub fn inputs(self: *Instance) ?*BusBuffers {
        return if (self.block) |*b| &b.inputs else null;
    }

    /// The output channels the plugin wrote (null before `configure`).
    pub fn outputs(self: *Instance) ?*BusBuffers {
        return if (self.block) |*b| &b.outputs else null;
    }

    /// AUDIO THREAD. Runs one `process` call over `frames` frames: `events` (sorted by offset)
    /// become note events and one parameter point each (the last one wins per parameter), the
    /// transport fills the process context (`null` keeps the default tempo and signature, with
    /// `project_time` as the position). Allocates nothing, takes no lock and logs nothing; it
    /// only rewrites the preallocated tables and calls the plugin.
    pub fn process(self: *Instance, frames: u32, project_time: i64, transport: ?*const plugin.Transport, events: []const event.Event) Error!void {
        if (!self.active) return error.NotActive;
        const blk: *ProcessBlock = if (self.block) |*b| b else return error.NotActive;
        const p = self.processor orelse return error.NoAudioProcessor;
        if (frames == 0 or frames > self.max_frames) return error.BlockTooLarge;
        const fallback: plugin.Transport = .{ .tempo = DEFAULT_TEMPO, .numerator = DEFAULT_TIME_SIG, .denominator = DEFAULT_TIME_SIG, .samples = project_time };
        const infos: []const ParamInfo = if (self.table) |t| t.infos else &.{};
        const data = blk.begin(frames, transport orelse &fallback, events, infos);
        blk.context.continousTimeSamples = project_time;
        const r = p.process(data);
        return if (abi.ok(r)) {} else error.ProcessFailed;
    }
};

// ---- tests -------------------------------------------------------------------------------------
//
// The Rust tests that belong to this file are `state_container_parses_strictly` and
// `the_transport_fills_the_process_context` (ffi.rs). instance.rs and module.rs have none of
// their own; the rest drives the code against the fake plugin of `editor.zig`.

const testing = std.testing;
const fx = editor_mod.fixture;

// Port of ffi.rs `state_container_parses_strictly`.
test "state_container_parses_strictly" {
    const gpa = testing.allocator;
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try blob.appendSlice(gpa, "SCV3");
    try blob.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, 3)));
    try blob.appendSlice(gpa, "abc");
    try blob.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, 2)));
    try blob.appendSlice(gpa, "xy");
    const ok_split = splitState(blob.items).?;
    try testing.expectEqualStrings("abc", ok_split.component);
    try testing.expectEqualStrings("xy", ok_split.controller);

    // bare component state
    const bare = splitState("raw component").?;
    try testing.expectEqualStrings("raw component", bare.component);
    try testing.expectEqual(@as(usize, 0), bare.controller.len);

    try testing.expect(splitState("") == null);

    var trailing: std.ArrayList(u8) = .empty;
    defer trailing.deinit(gpa);
    try trailing.appendSlice(gpa, blob.items);
    try trailing.append(gpa, 0);
    try testing.expect(splitState(trailing.items) == null);

    try testing.expect(splitState(blob.items[0 .. blob.items.len - 1]) == null);

    var huge: std.ArrayList(u8) = .empty;
    defer huge.deinit(gpa);
    try huge.appendSlice(gpa, "SCV3");
    try huge.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, std.math.maxInt(u32))));
    try testing.expect(splitState(huge.items) == null);

    try testing.expect(splitState("SCV3") == null);
}

// Port of ffi.rs `the_transport_fills_the_process_context` (the function lives in process.zig
// and is re-exported here).
test "the_transport_fills_the_process_context" {
    const S = abi.ProcessStates;
    var c = std.mem.zeroes(abi.ProcessContext);
    const t: plugin.Transport = .{
        .playing = true,
        .tempo = 90.0,
        .numerator = 3,
        .denominator = 4,
        .samples = 96_000,
        .quarters = 3.5,
        .bar_start = 3.0,
    };
    applyTransport(&c, &t);
    try testing.expectEqual(S.kPlaying, c.state & S.kPlaying);
    try testing.expectEqual(@as(u32, 0), c.state & S.kRecording);
    try testing.expectEqual(@as(f64, 90.0), c.tempo);
    try testing.expectEqual(@as(i32, 3), c.timeSigNumerator);
    try testing.expectEqual(@as(i32, 4), c.timeSigDenominator);
    try testing.expectEqual(@as(i64, 96_000), c.projectTimeSamples);
    try testing.expectEqual(@as(f64, 3.5), c.projectTimeMusic);
    try testing.expectEqual(@as(f64, 3.0), c.barPositionMusic);
    var stopped = t;
    stopped.playing = false;
    applyTransport(&c, &stopped);
    try testing.expectEqual(@as(u32, 0), c.state & S.kPlaying);
}

/// A fake plugin set up on the test stack: config, log, factory, bundle.
const Rig = struct {
    cfg: fx.Config,
    log: fx.Log = .{},
    factory: *fx.Factory,
    bundle: Bundle,

    fn init(rig: *Rig, single: bool, cfg: fx.Config) !void {
        rig.* = .{ .cfg = cfg, .factory = undefined, .bundle = undefined };
        rig.factory = try fx.Factory.create(testing.allocator, single, &rig.cfg, &rig.log);
        rig.bundle = .{ .gpa = testing.allocator, .path = &.{}, .factory = &rig.factory.iface, .exit_fn = null, .entered_on = .main };
    }

    fn make(rig: *Rig) Error!*Instance {
        return Instance.create(testing.allocator, &rig.bundle, &fx.Factory.comp_cid);
    }

    fn deinit(rig: *Rig) void {
        _ = abi.comRelease(&rig.factory.iface);
    }
};

const two_params = [_]fx.FakeParam{
    .{ .id = 10, .title = "Gain", .units = "dB", .min = -24, .max = 12, .default = 2.0 / 3.0 },
    .{ .id = 11, .title = "Power", .step_count = 1, .default = 1.0 },
    .{ .id = 12, .title = "Mode", .step_count = 3, .default = 0.5 },
    .{ .id = 13, .title = "Hidden", .flags = abi.kIsHidden },
    .{ .id = 14, .title = "Bypass", .flags = abi.kIsBypass, .step_count = 1 },
    .{ .id = 15, .title = "", .units = "Hz", .min = 20, .max = 20000 },
};

test "create: single component is its own controller; teardown order and no leaks" {
    var rig: Rig = undefined;
    try rig.init(true, .{});
    defer rig.deinit();
    const inst = try rig.make();
    try testing.expect(inst.single);
    try testing.expect(inst.controller != null and inst.processor != null);
    try testing.expect(inst.connections == null);
    try testing.expectEqual(@as(usize, 1), rig.log.count(.initialize));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.handler_set));
    try testing.expectEqual(@as(usize, 2), rig.bundle.refs.load(.monotonic));
    inst.destroy();
    try testing.expectEqual(@as(usize, 1), rig.bundle.refs.load(.monotonic));
    // The handler is detached, the component terminated once (the controller is the component
    // itself, so it is not terminated twice) and the object is gone.
    try testing.expectEqual(@as(usize, 1), rig.log.count(.handler_cleared));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.terminate));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.destroyed));
    try testing.expect(rig.log.indexOf(.handler_cleared, 1).? < rig.log.indexOf(.terminate, 0).?);
}

test "create: split component and controller are connected and torn down in order" {
    var rig: Rig = undefined;
    try rig.init(false, .{});
    defer rig.deinit();
    const inst = try rig.make();
    try testing.expect(!inst.single);
    try testing.expect(inst.controller_initialized and inst.connections != null);
    try testing.expectEqual(@as(usize, 2), rig.log.count(.initialize));
    try testing.expectEqual(@as(usize, 2), rig.log.count(.connect));
    // The component's state was handed to the controller.
    try testing.expect(rig.log.indexOf(.component_state_set, 1) != null);
    inst.destroy();
    try testing.expectEqual(@as(usize, 2), rig.log.count(.disconnect));
    try testing.expectEqual(@as(usize, 2), rig.log.count(.terminate));
    try testing.expectEqual(@as(usize, 2), rig.log.count(.destroyed));
    // Disconnect before either side terminates; the controller goes before the component.
    const first_term = @min(rig.log.indexOf(.terminate, 0).?, rig.log.indexOf(.terminate, 1).?);
    try testing.expect(rig.log.indexOf(.disconnect, 0).? < first_term);
    try testing.expect(rig.log.indexOf(.disconnect, 1).? < first_term);
    try testing.expect(rig.log.indexOf(.terminate, 1).? < rig.log.indexOf(.terminate, 0).?);
    try testing.expectEqual(@as(usize, 1), rig.bundle.refs.load(.monotonic));
}

test "create: failures release everything and report why" {
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .initialize_ok = false });
        defer rig.deinit();
        try testing.expectError(error.ComponentInitializeFailed, rig.make());
        // Not initialised, so not terminated; the object is gone and the bundle reference too.
        try testing.expectEqual(@as(usize, 0), rig.log.count(.terminate));
        try testing.expectEqual(@as(usize, 1), rig.log.count(.destroyed));
        try testing.expectEqual(@as(usize, 1), rig.bundle.refs.load(.monotonic));
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .no_processor = true });
        defer rig.deinit();
        try testing.expectError(error.NoAudioProcessor, rig.make());
        // It was initialised, so it is terminated again.
        try testing.expectEqual(@as(usize, 1), rig.log.count(.terminate));
        try testing.expectEqual(@as(usize, 1), rig.log.count(.destroyed));
        try testing.expectEqual(@as(usize, 1), rig.bundle.refs.load(.monotonic));
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{});
        defer rig.deinit();
        const unknown_cid: [16]u8 = @splat(0x01);
        try testing.expectError(error.FactoryCannotCreateComponent, Instance.create(testing.allocator, &rig.bundle, &unknown_cid));
    }
}

test "create: a controller that fails to initialize leaves parameters unavailable" {
    var rig: Rig = undefined;
    try rig.init(false, .{ .controller_initialize_ok = false, .params = &two_params });
    defer rig.deinit();
    const inst = try rig.make();
    try testing.expect(inst.controller == null and !inst.controller_initialized and inst.connections == null);
    try testing.expect(!inst.editor_link.hasController());
    try testing.expect(inst.editor() == null);
    const raw = try inst.params(testing.allocator);
    defer freeParams(testing.allocator, raw);
    try testing.expectEqual(@as(usize, 0), raw.len);
    const t = try inst.paramTable();
    try testing.expectEqual(@as(usize, 0), t.infos.len);
    inst.destroy();
    // The controller object was released without being terminated; only the component was.
    try testing.expectEqual(@as(usize, 2), rig.log.count(.destroyed));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.terminate));
}

test "configure: stereo negotiation, layout, activation, and processing starts" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .event_in = true, .latency = 64, .tail = 4800 });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    const layout = try inst.configure(48_000, 512, false);
    try testing.expectEqualSlices(u32, &.{2}, layout.inputs());
    try testing.expectEqualSlices(u32, &.{2}, layout.outputs());
    try testing.expect(layout.event_input);
    try testing.expect(inst.isActive());
    try testing.expectEqual(@as(usize, 1), rig.log.count(.set_active_true));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.set_processing_true));
    try testing.expect(rig.log.indexOf(.set_active_true, 0).? < rig.log.indexOf(.set_processing_true, 0).?);
    try testing.expectEqual(@as(u32, 64), inst.latency());
    try testing.expectEqual(@as(u32, 4800), inst.tail());
    // Reconfiguring stops and deactivates first.
    _ = try inst.configure(44_100, 256, true);
    try testing.expectEqual(@as(usize, 1), rig.log.count(.set_processing_false));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.set_active_false));
    try testing.expectEqual(@as(usize, 2), rig.log.count(.set_active_true));
}

test "configure: mono is asked for and a refusal falls back to stereo, then to the plugin's own" {
    {
        var rig: Rig = undefined;
        try rig.init(true, .{});
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const layout = try inst.configure(48_000, 128, true);
        try testing.expectEqualSlices(u32, &.{1}, layout.inputs());
        try testing.expectEqualSlices(u32, &.{1}, layout.outputs());
        try testing.expectEqual(@as(u32, 1), rig.log.arrangements_set);
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .refuse_mono = true });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const layout = try inst.configure(48_000, 128, true);
        try testing.expectEqualSlices(u32, &.{2}, layout.inputs());
        try testing.expectEqual(@as(u32, 2), rig.log.arrangements_set);
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .refuse_all = true, .in_buses = &.{fx.kMono}, .out_buses = &.{fx.kMono} });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const layout = try inst.configure(48_000, 128, false);
        try testing.expectEqualSlices(u32, &.{1}, layout.inputs());
        try testing.expectEqualSlices(u32, &.{1}, layout.outputs());
        // Stereo was asked for and refused: there is no further fallback to try.
        try testing.expectEqual(@as(u32, 1), rig.log.arrangements_set);
    }
}

test "configure: too many buses or channels is an error and the component stays inactive" {
    {
        const many: [17]u64 = @splat(fx.kStereo);
        var rig: Rig = undefined;
        try rig.init(true, .{ .in_buses = &many });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.TooManyBuses, inst.configure(48_000, 128, false));
        try testing.expect(!inst.isActive());
    }
    {
        var rig: Rig = undefined;
        // The plugin gives no arrangement, and its bus info claims 65 channels.
        try rig.init(true, .{ .no_arrangement = true, .info_channels = 65 });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.TooManyBusChannels, inst.configure(48_000, 128, false));
        try testing.expect(!inst.isActive());
        try testing.expectEqual(@as(usize, 0), rig.log.count(.set_active_true));
    }
    {
        // Exactly the limit is fine, read from the bus info.
        var rig: Rig = undefined;
        try rig.init(true, .{ .no_arrangement = true, .info_channels = 64 });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const layout = try inst.configure(48_000, 32, false);
        try testing.expectEqualSlices(u32, &.{64}, layout.inputs());
    }
}

test "configure: refusals are reported and leave the component inactive" {
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .can_32 = false });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.Cannot32Bit, inst.configure(48_000, 128, false));
        try testing.expect(!inst.isActive());
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .setup_ok = false });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.SetupProcessingFailed, inst.configure(48_000, 128, false));
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .set_active_ok = false });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.SetActiveFailed, inst.configure(48_000, 128, false));
        try testing.expect(!inst.isActive());
        try testing.expectEqual(@as(usize, 0), rig.log.count(.set_processing_true));
        try testing.expect(inst.inputs() == null);
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{});
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        try testing.expectError(error.BadConfig, inst.configure(0, 128, false));
        try testing.expectError(error.BadConfig, inst.configure(std.math.nan(f64), 128, false));
        try testing.expectError(error.BadConfig, inst.configure(48_000, 0, false));
    }
}

test "params: raw table, bounds and string handling" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &two_params });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    const raw = try inst.params(testing.allocator);
    defer freeParams(testing.allocator, raw);
    try testing.expectEqual(@as(usize, 6), raw.len);
    try testing.expectEqualStrings("Gain", raw[0].title);
    try testing.expectEqualStrings("dB", raw[0].units);
    try testing.expectEqual(@as(u32, 10), raw[0].id);
    try testing.expectEqual(@as(i32, 3), raw[2].step_count);
    try testing.expectEqual(abi.kIsHidden, raw[3].flags);
}

test "paramTable: hidden and bypass parameters are left out, ranges come from the controller" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &two_params });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    const t = try inst.paramTable();
    try testing.expectEqual(@as(usize, 4), t.infos.len);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12, 15 }, t.ids);
    // Continuous: plain range, unit from the label.
    try testing.expectEqualStrings("10", t.infos[0].id);
    try testing.expectEqualStrings("Gain", t.infos[0].name);
    try testing.expectEqual(@as(f32, -24), t.infos[0].min);
    try testing.expectEqual(@as(f32, 12), t.infos[0].max);
    try testing.expectApproxEqAbs(@as(f32, 0.0), t.infos[0].default, 1e-4);
    try testing.expect(t.infos[0].unit == .db);
    try testing.expect(t.infos[0].taper == .linear);
    // One step is a toggle.
    try testing.expect(t.infos[1].unit == .toggle);
    try testing.expectEqual(@as(f32, 1), t.infos[1].default);
    // Several steps are a choice with labels from the plugin.
    try testing.expect(t.infos[2].unit == .choice);
    try testing.expectEqual(@as(f32, 3), t.infos[2].max);
    try testing.expectEqual(@as(usize, 4), t.infos[2].choices.len);
    try testing.expectEqualStrings("Choice0", t.infos[2].choices[0]);
    try testing.expectEqualStrings("Choice3", t.infos[2].choices[3]);
    try testing.expectEqual(@as(f32, 2), t.infos[2].default); // round(0.5 * 3)
    // An empty title gets a generated name.
    try testing.expectEqualStrings("Param 15", t.infos[3].name);
    try testing.expect(t.infos[3].unit == .hz);
    // Built once.
    try testing.expect(t == try inst.paramTable());
}

test "value mapping between the table and the controller" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &two_params });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    _ = try inst.paramTable();
    // Gain: plain mapping through the controller.
    try testing.expectEqual(@as(?f32, -6.0), inst.plainFromNormalized(0, 0.5));
    try testing.expectEqual(@as(?f32, -24.0), inst.plainFromNormalized(0, 0.0));
    try testing.expectEqual(@as(?f32, 12.0), inst.plainFromNormalized(0, 1.0));
    try testing.expectEqual(@as(?f64, 0.5), inst.normalizedFromPlain(0, -6.0));
    try testing.expectEqual(@as(?f64, 1.0), inst.normalizedFromPlain(0, 99.0));
    // Toggle and choice: stepped.
    try testing.expectEqual(@as(?f32, 1.0), inst.plainFromNormalized(1, 1.0));
    try testing.expectEqual(@as(?f32, 2.0), inst.plainFromNormalized(2, 0.67));
    try testing.expectEqual(@as(?f64, 1.0), inst.normalizedFromPlain(2, 3.0));
    try testing.expectEqual(@as(?f64, 0.0), inst.normalizedFromPlain(2, -4.0));
    // Out of range index.
    try testing.expect(inst.plainFromNormalized(9, 0.5) == null);
    try testing.expect(inst.normalizedFromPlain(9, 0.5) == null);
    // Raw conversions by id.
    try testing.expectEqual(@as(?f64, -24.0), inst.toPlain(10, 0.0));
    try testing.expectEqual(@as(?f64, null), inst.toPlain(404, 0.0));
    try testing.expectEqual(@as(?f64, null), inst.toNormalized(10, std.math.inf(f64)));
    try testing.expectEqual(@as(?f64, 2.0 / 3.0), inst.normalizedValue(10));
    const text = (try inst.valueText(testing.allocator, 10, 1.0)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("12.0", text);
    try testing.expect((try inst.valueText(testing.allocator, 404, 0.5)) == null);
}

test "unitFromLabel" {
    try testing.expect(unitFromLabel(" dB ") == .db);
    try testing.expect(unitFromLabel("HZ") == .hz);
    try testing.expect(unitFromLabel("ms") == .ms);
    try testing.expect(unitFromLabel("%") == .percent);
    try testing.expect(unitFromLabel("Secs") == .seconds);
    try testing.expect(unitFromLabel("st") == .semitones);
    try testing.expect(unitFromLabel("cents") == .cents);
    try testing.expect(unitFromLabel("furlongs") == .none);
    try testing.expect(unitFromLabel("") == .none);
}

test "midiMapping: indexed by controller number, empty without the interface" {
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .params = &two_params, .has_midi_mapping = true });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const m = try inst.midiMapping(testing.allocator);
        defer testing.allocator.free(m);
        try testing.expectEqual(abi.PITCH_BEND + 1, m.len);
        try testing.expectEqual(@as(?u32, 11), m[1]);
        try testing.expectEqual(@as(?u32, null), m[2]);
        try testing.expectEqual(@as(?u32, 10), m[abi.PITCH_BEND]);
        try testing.expectEqual(@as(?u32, null), m[abi.AFTERTOUCH]);
    }
    {
        var rig: Rig = undefined;
        try rig.init(true, .{ .params = &two_params });
        defer rig.deinit();
        const inst = try rig.make();
        defer inst.destroy();
        const m = try inst.midiMapping(testing.allocator);
        defer testing.allocator.free(m);
        try testing.expectEqual(@as(usize, 0), m.len);
    }
}

test "state: save, load and hostile blobs" {
    var rig: Rig = undefined;
    try rig.init(false, .{ .comp_state = "abc", .ctrl_state = "xy" });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    const link = inst.stateLink();
    defer link.release();
    const blob = (try link.saveState(testing.allocator)).?;
    defer testing.allocator.free(blob);
    const parts = splitState(blob).?;
    try testing.expectEqualStrings("abc", parts.component);
    try testing.expectEqualStrings("xy", parts.controller);
    // The saved blob loads: the component, then the controller are told.
    const before = rig.log.count(.component_state_set);
    try testing.expect(try inst.loadState(blob));
    try testing.expectEqual(before + 2, rig.log.count(.component_state_set));
    // A bare component state loads too.
    try testing.expect(try inst.loadState("raw"));
    // Hostile blobs are refused without touching the plugin.
    const calls = rig.log.count(.component_state_set);
    try testing.expect(!(try inst.loadState("")));
    try testing.expect(!(try inst.loadState("SCV3\xff\xff\xff\xff")));
    try testing.expect(!(try inst.loadState("SCV3\x01\x00\x00\x00a")));
    try testing.expectEqual(calls, rig.log.count(.component_state_set));
}

test "state: a component that refuses setState keeps the previous state" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .refuse_set_state = true });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    try testing.expect(!(try inst.loadState("anything")));
}

test "editor handles: link is shared, absent without a controller, and survives the instance" {
    var rig: Rig = undefined;
    try rig.init(true, .{});
    defer rig.deinit();
    const inst = try rig.make();
    const link = inst.editor().?;
    var handle = editor_mod.EditorHandle.init(link);
    link.release();
    defer handle.deinit();
    try testing.expect(handle.link.hasController());
    inst.destroy();
    // The instance is gone; the handle is inert.
    try testing.expect(!handle.link.hasController());
    handle.setNormalized(1, 0.5);
    handle.close();
    try testing.expect(!handle.isOpen());
    try testing.expectEqual(@as(?f64, null), handle.link.toPlain(1, 0.5));
}

test "process: wiring, preallocated buffers, events and transport" {
    var rig: Rig = undefined;
    try rig.init(true, .{ .params = &two_params, .event_in = true });
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    // Before configure there is nothing to process with.
    try testing.expectError(error.NotActive, inst.process(64, 0, null, &.{}));
    const layout = try inst.configure(48_000, 256, false);
    try testing.expectEqual(@as(usize, 1), layout.inputs().len);
    const in = inst.inputs().?;
    const out = inst.outputs().?;
    for (in.channelMut(0, 0).?, 0..) |*s, i| s.* = @floatFromInt(i);

    const evs = [_]event.Event{
        .{ .offset = 4, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } },
        .{ .offset = 9, .kind = .{ .note_off = 60 } },
        .{ .offset = 0, .kind = .{ .param = .{ .index = 0, .value = 0.0 } } },
    };
    try inst.process(128, 1000, null, &evs);
    try testing.expectEqual(@as(u32, 1), rig.log.process_calls);
    try testing.expectEqual(@as(i32, 128), rig.log.last_num_samples);
    try testing.expectEqual(@as(i32, 1), rig.log.last_num_inputs);
    try testing.expectEqual(@as(i32, 1), rig.log.last_num_outputs);
    try testing.expectEqual(@as(i32, 2), rig.log.last_event_count);
    try testing.expectEqual(@as(i32, 1), rig.log.last_param_count);
    // With no transport the context keeps the default tempo.
    try testing.expectEqual(@as(f64, 120.0), rig.log.last_tempo);
    // The fake plugin doubled the first input channel into the first output channel.
    const o = out.channel(0, 0).?;
    try testing.expectEqual(@as(f32, 0.0), o[0]);
    try testing.expectEqual(@as(f32, 10.0), o[5]);
    try testing.expectEqual(@as(f32, 254.0), o[127]);

    // A transport is applied.
    const tr: plugin.Transport = .{ .playing = true, .tempo = 90, .numerator = 3, .denominator = 4 };
    try inst.process(64, 5000, &tr, &.{});
    try testing.expectEqual(@as(f64, 90.0), rig.log.last_tempo);
    try testing.expectEqual(@as(i64, 5000), inst.block.?.context.continousTimeSamples);
}

test "process: errors" {
    var rig: Rig = undefined;
    try rig.init(true, .{});
    defer rig.deinit();
    const inst = try rig.make();
    defer inst.destroy();
    _ = try inst.configure(48_000, 128, false);
    try testing.expectError(error.BlockTooLarge, inst.process(0, 0, null, &.{}));
    try testing.expectError(error.BlockTooLarge, inst.process(129, 0, null, &.{}));
    rig.log.process_result = abi.kInternalError;
    try testing.expectError(error.ProcessFailed, inst.process(64, 0, null, &.{}));
    rig.log.process_result = abi.kResultOk;
    try inst.process(64, 0, null, &.{});
    // After shutdown the instance refuses to process.
    inst.shutdown();
    try testing.expectError(error.NotActive, inst.process(64, 0, null, &.{}));
    try testing.expectEqual(@as(usize, 1), rig.log.count(.set_processing_false));
}

test "destroy with an editor view leaked off the main thread marks the bundle" {
    var rig: Rig = undefined;
    try rig.init(true, .{});
    defer rig.deinit();
    const inst = try rig.make();
    const view = inst.controller.?.createView("editor").?;
    inst.editor_link.inner.view = view;
    const T = struct {
        fn run(i: *Instance) void {
            i.destroy();
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{inst});
    th.join();
    try testing.expect(rig.bundle.leaked.load(.acquire));
    // Release the deliberately leaked view so the test itself does not leak.
    _ = abi.comRelease(view);
}
