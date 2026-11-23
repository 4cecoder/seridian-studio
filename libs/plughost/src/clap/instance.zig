// Translated to Zig from soundcraft/crates/clap-host/src/ffi/instance.rs, soundcraft/crates/clap-host/src/ffi/bundle.rs (instantiate) (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! A live CLAP plugin instance: creation from a factory, the activation lifecycle,
//! the audio `process` call, the parameter table, state save and load, and the
//! latency and tail queries.
//!
//! Ownership: `create` heap-allocates the instance, its `clap_host` struct and its
//! `HostState`, because the plugin keeps the host pointer and `host_data` for its
//! whole life. `destroy` is the last call: it deactivates and destroys the plugin,
//! then frees all of them. The caller keeps the factory's binary loaded until
//! `destroy` returns.
//!
//! Threading (CLAP): control thread: `create`, `activate`, `deactivate`, `readParams`,
//! `paramValue`, `valueText`, `audioPorts`, `saveState`, `loadState`, `drainEdits`,
//! `serviceCallback`, `destroy`. Audio thread: `process` and `reset`. The owner
//! calls these serially; an instance is never used from two threads at once.
//!
//! Seridian adaptations (the Rust code kept these inside `Instance` and
//! `PortBuffers` with `Vec`s; the numbers in brackets are the caps):
//! 1. `process` allocates nothing. Port buffers, the channel pointer tables
//!    (`MAX_CHANNELS` = 16 per port, `MAX_PORTS` ports) and the event lists are
//!    allocated before the first block (`PortBuffers.init`, `create`); `process`
//!    only rewrites pointers in place. No locks, no logging, no I/O.
//! 2. Parameter changes are `CLAP_EVENT_PARAM_VALUE` events addressed by the
//!    `clap_id` of the dense index. The dense index to `clap_id` table is built
//!    once in `create`. There are no string lookups and no hash map per block.
//! 3. The plug-0 value of a parameter (`ParamInfo` range and taper) converts to the
//!    plugin's native range through the per-index `ParamBinding` table: an index
//!    read, one normalise and one scale. Non-finite values become the parameter's
//!    default.
//! 4. `saveState` allocates through the caller's allocator and runs on the control
//!    thread only. `loadState` treats the bytes as hostile: the size is capped, the
//!    read is bounded by the buffer, and the plugin's return value is checked. A
//!    refused load restores the state saved just before it, so the plugin keeps
//!    what it had.
//! 5. `process` reports `CLAP_PROCESS_ERROR` as `error.PluginError` and any
//!    non-finite output sample as `error.NonFiniteOutput`. The caller (graph-5)
//!    decides how to silence the block; this file never rewrites the audio.
//!
//! Differences from instance.rs, all deliberate:
//! - Audio port buffers belong to the caller (`*PortBuffers` in `ProcessInput`), as
//!   in Rust, and the caller allocates them with `PortBuffers.init`.
//! - The editor link (`GuiLink`, `gui()`, `state_link()`, and the kill on drop) is
//!   not here: it is the clap-gui unit, which is not translated yet. `destroy`
//!   must kill the editor first when that unit lands; see the report.
//! - Channel counts above `MAX_CHANNELS` (16) are refused, where the Rust code
//!   allowed 64.
//! - `activate` also refuses a non-finite or non-positive sample rate and a frame
//!   range that is empty or inverted. The Rust code relied on its caller.
//! - The host name is "Seridian" (see host.zig).

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const events = @import("events.zig");
const host_mod = @import("host.zig");
const host_event = @import("../event.zig");
const plugin_mod = @import("../plugin.zig");
const param_info = @import("../params.zig");

// ---- errors ---------------------------------------------------------------------------------

pub const CreateError = std.mem.Allocator.Error || error{
    /// The plugin id contains an interior NUL, so it cannot be passed as a C string.
    IdContainsNul,
    /// The factory has no `create_plugin` entry.
    NoCreatePlugin,
    /// `create_plugin` returned null.
    CreateFailed,
    /// The plugin's `init` returned false (the plugin is destroyed again).
    InitFailed,
    /// The plug-0 parameter map does not have one entry per usable CLAP parameter.
    ParamMapMismatch,
};

pub const ActivateError = error{
    BadSampleRate,
    BadFrameRange,
    NoActivate,
    ActivateFailed,
};

pub const ProcessError = error{
    NotActive,
    /// A block of zero frames, a block longer than the activated maximum, or one
    /// longer than the buffers the caller passed.
    BadBlockSize,
    StartProcessingFailed,
    NoProcess,
    /// The plugin returned `CLAP_PROCESS_ERROR`.
    PluginError,
    /// At least one output sample is NaN or infinite.
    NonFiniteOutput,
};

pub const PortError = error{
    /// More audio ports than `MAX_PORTS`.
    TooManyPorts,
    /// A port with more channels than `MAX_CHANNELS`.
    TooManyChannels,
};

// ---- audio buffers --------------------------------------------------------------------------

/// Planar f32 buffers for every audio port in one direction, with the pointer tables
/// CLAP needs. The caller creates them once with `init` (control thread) and passes
/// them to `process`. `process` refreshes the pointer tables in place, because the
/// tables must point at the current address of this struct.
pub const PortBuffers = struct {
    /// One allocation holding every channel of every port, `frames` samples each.
    storage: []f32,
    frames: usize,
    port_count: usize,
    /// Channels actually allocated per port (capped at `MAX_CHANNELS`).
    channel_counts: [abi.MAX_PORTS]usize,
    /// Slices into `storage`: `chans[port][channel]`.
    chans: [abi.MAX_PORTS][plugin_mod.MAX_CHANNELS][]f32,
    /// The channel pointer tables CLAP reads. Rewritten by `refresh`.
    ptrs: [abi.MAX_PORTS][plugin_mod.MAX_CHANNELS]?[*]f32,
    /// The `clap_audio_buffer` per port. Rewritten by `refresh`.
    bufs: [abi.MAX_PORTS]abi.ClapAudioBuffer,

    /// Control thread (prepare). Allocates and zeroes the storage. Ports beyond
    /// `MAX_PORTS` are ignored; channels beyond `MAX_CHANNELS` are capped.
    pub fn init(gpa: std.mem.Allocator, channels: []const u32, frames: usize) std.mem.Allocator.Error!PortBuffers {
        const ports: usize = @min(channels.len, @as(usize, abi.MAX_PORTS));
        var total: usize = 0;
        for (channels[0..ports]) |c| {
            total += @min(@as(usize, c), plugin_mod.MAX_CHANNELS);
        }
        const storage = try gpa.alloc(f32, total * frames);
        @memset(storage, 0);

        var pb: PortBuffers = .{
            .storage = storage,
            .frames = frames,
            .port_count = ports,
            .channel_counts = @splat(0),
            .chans = undefined,
            .ptrs = std.mem.zeroes([abi.MAX_PORTS][plugin_mod.MAX_CHANNELS]?[*]f32),
            .bufs = std.mem.zeroes([abi.MAX_PORTS]abi.ClapAudioBuffer),
        };
        var off: usize = 0;
        for (0..ports) |p| {
            const c: usize = @min(@as(usize, channels[p]), plugin_mod.MAX_CHANNELS);
            pb.channel_counts[p] = c;
            for (0..c) |k| {
                pb.chans[p][k] = storage[off .. off + frames];
                off += frames;
            }
        }
        // The pointer tables are set by `refresh`, which runs for the current address.
        return pb;
    }

    /// Control thread.
    pub fn deinit(self: *PortBuffers, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
        self.storage = &.{};
    }

    /// Points the CLAP tables at the channels' current data. Called at the start of
    /// every block. Allocation-free.
    pub fn refresh(self: *PortBuffers) void {
        for (0..self.port_count) |p| {
            const c = self.channel_counts[p];
            for (0..c) |k| {
                self.ptrs[p][k] = self.chans[p][k].ptr;
            }
            self.bufs[p] = .{
                .data32 = &self.ptrs[p],
                .data64 = null,
                .channel_count = @intCast(c),
                .latency = 0,
                .constant_mask = 0,
            };
        }
    }

    /// The samples of one channel, `frames` long. Null for a port or channel that does
    /// not exist.
    pub fn channel(self: *PortBuffers, port: usize, ch: usize) ?[]f32 {
        if (port >= self.port_count) return null;
        if (ch >= self.channel_counts[port]) return null;
        return self.chans[port][ch];
    }
};

/// Every channel of every port, in the outputs, is free of NaN and infinity.
fn outputsAreFinite(outputs: *const PortBuffers, frames: usize) bool {
    for (0..outputs.port_count) |p| {
        for (0..outputs.channel_counts[p]) |c| {
            for (outputs.chans[p][c][0..frames]) |s| {
                if (!std.math.isFinite(s)) return false;
            }
        }
    }
    return true;
}

// ---- descriptions ---------------------------------------------------------------------------

/// What one audio port looks like.
pub const PortInfo = struct {
    channels: u32,
    main: bool,
};

/// The audio ports of one direction, in order. Fixed capacity, so no allocation.
pub const PortList = struct {
    items: [abi.MAX_PORTS]PortInfo = undefined,
    len: usize = 0,

    pub fn slice(self: *const PortList) []const PortInfo {
        return self.items[0..self.len];
    }
};

/// One parameter as reported by `clap_plugin_params.get_info`. `name` and `module`
/// are owned copies: free them with `freeParams`.
pub const RawParam = struct {
    id: abi.ClapId,
    name: []u8,
    module: []u8,
    flags: u32,
    min: f64,
    max: f64,
    default: f64,
};

/// Frees a list from `Instance.readParams`, including the copied strings.
pub fn freeParams(gpa: std.mem.Allocator, list: []RawParam) void {
    for (list) |p| {
        gpa.free(p.name);
        gpa.free(p.module);
    }
    gpa.free(list);
}

/// Note dialects of the plugin's first input note port.
pub const NotePort = struct {
    supported: u32,
    preferred: u32,
};

/// A parameter change the plugin reported (typically an edit in its GUI), in the
/// dense index and plug-0 units the UI uses.
pub const Edit = struct {
    index: u32,
    value: f32,
};

/// How one dense parameter index maps between the plug-0 description and CLAP's
/// native range. Built once in `create`; read on the audio thread by index only.
pub const ParamBinding = struct {
    clap_id: abi.ClapId,
    clap_min: f64,
    clap_max: f64,
    clap_default: f64,
    /// The plug-0 description, or null for an identity mapping (plug-0 values are
    /// CLAP values, clamped to the CLAP range). Its id and name slices are borrowed
    /// from the caller and must outlive the instance.
    plug: ?param_info.ParamInfo = null,
};

/// The block a caller hands to `process`.
pub const ProcessInput = struct {
    frames: usize,
    steady_time: i64,
    inputs: *PortBuffers,
    outputs: *PortBuffers,
    /// Sorted by sample offset (the plug-0 `EventList` guarantees it).
    events: []const host_event.Event,
    /// Sample offset that the block starts at; event times are relative to it.
    offset: u32,
    transport: ?*const plugin_mod.Transport,
};

// ---- the instance ---------------------------------------------------------------------------

pub const Instance = struct {
    gpa: std.mem.Allocator,
    /// The `clap_host` the plugin keeps. Heap, so its address is stable.
    host: *abi.ClapHost,
    /// What `host.host_data` points to. Heap, so its address is stable.
    host_state: *host_mod.HostState,
    plugin: *const abi.ClapPlugin,

    params_ext: ?*const abi.ClapPluginParams = null,
    ports_ext: ?*const abi.ClapPluginAudioPorts = null,
    latency_ext: ?*const abi.ClapPluginLatency = null,
    tail_ext: ?*const abi.ClapPluginTail = null,
    notes_ext: ?*const abi.ClapPluginNotePorts = null,
    state_ext: ?*const abi.ClapPluginState = null,

    /// Dense index to binding (and to clap_id, see `param_ids`). Built in `create`.
    bindings: []ParamBinding = &.{},
    /// Dense index to `clap_id`, the table `events.toRaw` reads. Built in `create`.
    param_ids: []abi.ClapId = &.{},

    in_events: events.InputEvents,
    out_events: events.OutputEvents,
    /// The `clap_input_events` / `clap_output_events` views handed to the plugin.
    /// Rebuilt per block; they point at the fields above, which do not move.
    clap_in: abi.ClapInputEvents = undefined,
    clap_out: abi.ClapOutputEvents = undefined,
    /// Storage for the transport event of the current block.
    transport_event: abi.ClapEventTransport = undefined,

    active: bool = false,
    processing: bool = false,
    max_frames: usize = 0,
    /// Input events that did not fit, or had an unknown parameter index, since
    /// creation. Written on the audio thread, read anywhere.
    events_dropped: std.atomic.Value(usize) = .init(0),

    /// Control thread. Creates the plugin from `factory`, runs its `init`, reads the
    /// extensions and the parameter table, and allocates the event lists.
    ///
    /// `plug_params`, when given, describes the usable parameters in plug-0 units: one
    /// entry per dense index, in the order `readParams` returns the usable ones (ranges
    /// that are inverted or non-finite are skipped, as in Rust). Null means identity.
    pub fn create(
        gpa: std.mem.Allocator,
        factory: *const abi.ClapPluginFactory,
        plugin_id: [:0]const u8,
        plug_params: ?[]const param_info.ParamInfo,
    ) CreateError!*Instance {
        if (std.mem.indexOfScalar(u8, plugin_id, 0) != null) return error.IdContainsNul;
        const create_fn = factory.create_plugin orelse return error.NoCreatePlugin;

        const state = try gpa.create(host_mod.HostState);
        state.* = .{};
        const host_ptr = gpa.create(abi.ClapHost) catch |e| {
            gpa.destroy(state);
            return e;
        };
        host_ptr.* = host_mod.makeClapHost(state);

        const plugin = create_fn(factory, host_ptr, plugin_id.ptr) orelse {
            freeHost(gpa, host_ptr, state);
            return error.CreateFailed;
        };
        const init_ok = if (plugin.init) |init_fn| init_fn(plugin) else false;
        if (!init_ok) {
            destroyPlugin(plugin);
            freeHost(gpa, host_ptr, state);
            return error.InitFailed;
        }

        // The plugin is alive from here: every failure path must destroy it.
        const inst = gpa.create(Instance) catch |e| {
            destroyPlugin(plugin);
            freeHost(gpa, host_ptr, state);
            return e;
        };
        inst.* = .{
            .gpa = gpa,
            .host = host_ptr,
            .host_state = state,
            .plugin = plugin,
            .in_events = .{ .buf = &.{} },
            .out_events = .{ .buf = &.{} },
        };
        errdefer inst.destroy();

        inst.in_events = try events.InputEvents.init(gpa, abi.EVENT_CAP);
        inst.out_events = try events.OutputEvents.init(gpa, abi.EVENT_CAP);

        inst.params_ext = extension(plugin, abi.CLAP_EXT_PARAMS, abi.ClapPluginParams);
        inst.ports_ext = extension(plugin, abi.CLAP_EXT_AUDIO_PORTS, abi.ClapPluginAudioPorts);
        inst.latency_ext = extension(plugin, abi.CLAP_EXT_LATENCY, abi.ClapPluginLatency);
        inst.tail_ext = extension(plugin, abi.CLAP_EXT_TAIL, abi.ClapPluginTail);
        inst.notes_ext = extension(plugin, abi.CLAP_EXT_NOTE_PORTS, abi.ClapPluginNotePorts);
        inst.state_ext = extension(plugin, abi.CLAP_EXT_STATE, abi.ClapPluginState);

        try inst.buildTables(gpa, plug_params);
        return inst;
    }

    /// Control thread. Frees the plugin (deactivated first), its host struct and
    /// state, and the instance itself. No pointer to the instance may be used after.
    pub fn destroy(self: *Instance) void {
        const gpa = self.gpa;
        // Deactivate before destroy, as CLAP requires. The editor link (clap-gui) is
        // killed here once that unit is translated, before the plugin goes.
        self.deactivate();
        destroyPlugin(self.plugin);
        self.in_events.deinit(gpa);
        self.out_events.deinit(gpa);
        gpa.free(self.param_ids);
        gpa.free(self.bindings);
        freeHost(gpa, self.host, self.host_state);
        gpa.destroy(self);
    }

    /// The UI reads and clears the plugin's flags through this. Valid while alive.
    pub fn hostState(self: *const Instance) *host_mod.HostState {
        return self.host_state;
    }

    /// Control thread. Reads the parameter table into owned copies (caller frees with
    /// `freeParams`). Entries whose range is inverted or non-finite are skipped. At
    /// most `MAX_PARAMS` parameters are read. Default values are clamped into range.
    pub fn readParams(self: *const Instance, gpa: std.mem.Allocator) std.mem.Allocator.Error![]RawParam {
        var out: std.ArrayList(RawParam) = .empty;
        errdefer {
            for (out.items) |p| {
                gpa.free(p.name);
                gpa.free(p.module);
            }
            out.deinit(gpa);
        }
        const p = self.params_ext orelse return out.toOwnedSlice(gpa);
        const count = p.count orelse return out.toOwnedSlice(gpa);
        const get_info = p.get_info orelse return out.toOwnedSlice(gpa);

        const n = @min(count(self.plugin), abi.MAX_PARAMS);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var info = std.mem.zeroes(abi.ClapParamInfo);
            if (!get_info(self.plugin, i, &info)) continue;
            const min = info.min_value;
            const max = info.max_value;
            if (!(std.math.isFinite(min) and std.math.isFinite(max)) or max < min) continue;
            const default = if (std.math.isFinite(info.default_value))
                std.math.clamp(info.default_value, min, max)
            else
                min;

            const name = try gpa.dupe(u8, abi.readName(&info.name));
            errdefer gpa.free(name);
            const module = try gpa.dupe(u8, abi.readName(&info.module));
            errdefer gpa.free(module);
            try out.append(gpa, .{
                .id = info.id,
                .name = name,
                .module = module,
                .flags = info.flags,
                .min = min,
                .max = max,
                .default = default,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Control thread. The plugin's current value for `id`, or null when it has no
    /// `clap.params` or the value is not finite.
    pub fn paramValue(self: *const Instance, id: abi.ClapId) ?f64 {
        const p = self.params_ext orelse return null;
        const get = p.get_value orelse return null;
        var v: f64 = 0.0;
        if (!get(self.plugin, id, &v)) return null;
        return if (std.math.isFinite(v)) v else null;
    }

    /// Control thread. The display text of `value` for parameter `id`, written into
    /// `buf` (zeroed first, and its length is the plugin's capacity). Null when the
    /// plugin refuses or the text is empty.
    pub fn valueText(self: *const Instance, id: abi.ClapId, value: f64, buf: []u8) ?[]const u8 {
        const p = self.params_ext orelse return null;
        const f = p.value_to_text orelse return null;
        if (buf.len == 0 or buf.len > std.math.maxInt(u32)) return null;
        @memset(buf, 0);
        if (!f(self.plugin, id, value, buf.ptr, @intCast(buf.len))) return null;
        const s = abi.readName(buf);
        return if (s.len == 0) null else s;
    }

    /// Control thread. The audio ports in one direction. More than `MAX_PORTS` ports,
    /// or a port wider than `MAX_CHANNELS`, is an error: the plugin is never handed
    /// fewer ports or channels than it advertised. An unreadable port keeps its slot
    /// as a silent zero-channel port.
    pub fn audioPorts(self: *const Instance, is_input: bool) PortError!PortList {
        var list: PortList = .{};
        const p = self.ports_ext orelse return list;
        const count = p.count orelse return list;
        const get = p.get orelse return list;

        const n = count(self.plugin, is_input);
        if (n > abi.MAX_PORTS) return error.TooManyPorts;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var info = std.mem.zeroes(abi.ClapAudioPortInfo);
            var port: PortInfo = .{ .channels = 0, .main = false };
            if (get(self.plugin, i, is_input, &info)) {
                if (info.channel_count > plugin_mod.MAX_CHANNELS) return error.TooManyChannels;
                port = .{
                    .channels = info.channel_count,
                    .main = (info.flags & abi.CLAP_AUDIO_PORT_IS_MAIN) != 0,
                };
            }
            list.items[i] = port;
            list.len = i + 1;
        }
        return list;
    }

    /// Control thread. The note dialects of the first input note port, or null when
    /// there is none.
    pub fn notePort(self: *const Instance) ?NotePort {
        const p = self.notes_ext orelse return null;
        const count = p.count orelse return null;
        const get = p.get orelse return null;
        if (count(self.plugin, true) == 0) return null;
        var info = std.mem.zeroes(abi.ClapNotePortInfo);
        if (!get(self.plugin, 0, true, &info)) return null;
        return .{ .supported = info.supported_dialects, .preferred = info.preferred_dialect };
    }

    /// The plugin's latency in samples, or 0 without `clap.latency`.
    pub fn latency(self: *const Instance) u32 {
        const l = self.latency_ext orelse return 0;
        const get = l.get orelse return 0;
        return get(self.plugin);
    }

    /// The plugin's tail in samples, or 0 without `clap.tail`.
    pub fn tailSamples(self: *const Instance) u32 {
        const t = self.tail_ext orelse return 0;
        const get = t.get orelse return 0;
        return get(self.plugin);
    }

    pub fn isActive(self: *const Instance) bool {
        return self.active;
    }

    /// Control thread. Activates the plugin for a sample rate and a block size range.
    /// Deactivates it first if it was active. The arguments are checked here.
    pub fn activate(self: *Instance, sample_rate: f64, min_frames: u32, max_frames: u32) ActivateError!void {
        if (!(std.math.isFinite(sample_rate) and sample_rate > 0.0)) return error.BadSampleRate;
        if (min_frames == 0 or max_frames < min_frames) return error.BadFrameRange;
        self.deactivate();
        const f = self.plugin.activate orelse return error.NoActivate;
        if (!f(self.plugin, sample_rate, min_frames, max_frames)) return error.ActivateFailed;
        self.active = true;
        self.max_frames = max_frames;
    }

    /// Stops processing if it runs, then deactivates. Safe to call when inactive.
    pub fn deactivate(self: *Instance) void {
        self.stopProcessing();
        if (self.active) {
            if (self.plugin.deactivate) |f| f(self.plugin);
            self.active = false;
        }
    }

    fn stopProcessing(self: *Instance) void {
        if (!self.processing) return;
        if (self.plugin.stop_processing) |f| f(self.plugin);
        self.processing = false;
    }

    /// Clears the plugin's internal state (its delay lines and so on) without
    /// deactivating it. Audio thread safe.
    pub fn reset(self: *Instance) void {
        if (!self.active) return;
        if (self.plugin.reset) |f| f(self.plugin);
    }

    /// Runs one `clap_process` call over `input.frames` frames. Audio thread: no
    /// allocation, no locks, no logging. The events are converted to CLAP form, with
    /// their times relative to `input.offset`. Parameter edits the plugin reports are
    /// queued for the UI (see `drainEdits`).
    pub fn process(self: *Instance, input: ProcessInput) ProcessError!abi.ClapProcessStatus {
        if (!self.active) return error.NotActive;
        const frames = input.frames;
        if (frames == 0 or frames > self.max_frames or frames > input.inputs.frames or frames > input.outputs.frames) {
            return error.BadBlockSize;
        }
        const frames_u32 = std.math.cast(u32, frames) orelse return error.BadBlockSize;

        if (!self.processing) {
            if (self.plugin.start_processing) |f| {
                if (!f(self.plugin)) return error.StartProcessingFailed;
            }
            self.processing = true;
        }
        const process_fn = self.plugin.process orelse return error.NoProcess;

        const dropped = self.fillInputs(input.events, input.offset);
        if (dropped > 0) _ = self.events_dropped.fetchAdd(dropped, .monotonic);
        self.out_events.clear();
        self.clap_in = self.in_events.asClap();
        self.clap_out = self.out_events.asClap();

        input.inputs.refresh();
        input.outputs.refresh();

        var transport_ptr: ?*const abi.ClapEventTransport = null;
        if (input.transport) |t| {
            self.transport_event = events.transportEvent(t);
            transport_ptr = &self.transport_event;
        }

        var call: abi.ClapProcess = .{
            .steady_time = input.steady_time,
            .frames_count = frames_u32,
            .transport = transport_ptr,
            .audio_inputs = &input.inputs.bufs,
            .audio_outputs = &input.outputs.bufs,
            .audio_inputs_count = @intCast(input.inputs.port_count),
            .audio_outputs_count = @intCast(input.outputs.port_count),
            .in_events = &self.clap_in,
            .out_events = &self.clap_out,
        };
        const status = process_fn(self.plugin, &call);

        // Edits go to the UI ring. A full ring drops them, as the Rust did; nothing blocks.
        for (self.out_events.drain()) |edit| {
            _ = self.host_state.edits.push(edit);
        }

        if (status == abi.CLAP_PROCESS_ERROR) return error.PluginError;
        if (!outputsAreFinite(input.outputs, frames)) return error.NonFiniteOutput;
        return status;
    }

    /// Converts the block's events into the preallocated input list. Parameter values
    /// go through the binding table. Returns how many events were dropped (the list
    /// was full, or the parameter index is unknown).
    fn fillInputs(self: *Instance, src: []const host_event.Event, base: u32) usize {
        const list = &self.in_events;
        list.clear();
        var dropped: usize = 0;
        for (src) |ev| {
            if (list.len == list.buf.len) {
                dropped += 1;
                continue;
            }
            var raw = events.toRaw(ev, base, self.param_ids) orelse {
                dropped += 1;
                continue;
            };
            switch (ev.kind) {
                .param => |p| {
                    const value = self.toClapValue(p.index, p.value) orelse {
                        dropped += 1;
                        continue;
                    };
                    raw.param.value = value;
                },
                else => {},
            }
            list.buf[list.len] = raw;
            list.len += 1;
        }
        return dropped;
    }

    /// Plug-0 value of dense index `index` to the CLAP value. Null for an unknown index.
    /// Audio thread safe: one table read and arithmetic.
    pub fn toClapValue(self: *const Instance, index: u32, value: f32) ?f64 {
        if (index >= self.bindings.len) return null;
        const b = self.bindings[index];
        if (b.plug) |p| {
            const t: f64 = p.toNormalized(value);
            return b.clap_min + t * (b.clap_max - b.clap_min);
        }
        if (!std.math.isFinite(value)) return b.clap_default;
        return std.math.clamp(@as(f64, value), b.clap_min, b.clap_max);
    }

    /// CLAP value of dense index `index` to plug-0 units. Null for an unknown index or
    /// a non-finite value.
    pub fn fromClapValue(self: *const Instance, index: u32, value: f64) ?f32 {
        if (index >= self.bindings.len) return null;
        if (!std.math.isFinite(value)) return null;
        const b = self.bindings[index];
        const span = b.clap_max - b.clap_min;
        if (b.plug) |p| {
            const t: f64 = if (span > 0.0) std.math.clamp((value - b.clap_min) / span, 0.0, 1.0) else 0.0;
            return p.fromNormalized(@floatCast(t));
        }
        return @floatCast(std.math.clamp(value, b.clap_min, b.clap_max));
    }

    /// The dense index of a CLAP id, or null. Linear: control thread only.
    pub fn indexOfClapId(self: *const Instance, id: abi.ClapId) ?u32 {
        for (self.param_ids, 0..) |pid, i| {
            if (pid == id) return @intCast(i);
        }
        return null;
    }

    /// Control thread. Moves the edits the plugin reported since the last call into
    /// `out`, in dense index and plug-0 units, and returns how many were written.
    /// Edits for an unknown id are discarded.
    pub fn drainEdits(self: *Instance, out: []Edit) usize {
        var n: usize = 0;
        while (n < out.len) {
            const e = self.host_state.edits.pop() orelse break;
            const index = self.indexOfClapId(e.param_id) orelse continue;
            const value = self.fromClapValue(index, e.value) orelse continue;
            out[n] = .{ .index = index, .value = value };
            n += 1;
        }
        return n;
    }

    /// Control thread (main thread). Runs the plugin's `on_main_thread` when it asked
    /// for a callback since the last service. Nothing when it did not.
    pub fn serviceCallback(self: *Instance) void {
        if (!self.host_state.callback.swap(false, .monotonic)) return;
        if (self.plugin.on_main_thread) |f| f(self.plugin);
    }

    /// Control thread. The plugin's state as bytes, allocated with `gpa` (caller
    /// frees). Null when there is no `clap.state`, or the plugin refuses to save.
    pub fn saveState(self: *const Instance, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        const st = self.state_ext orelse return null;
        const save = st.save orelse return null;
        var sink: events.WriteSink = .{ .gpa = gpa };
        defer sink.deinit();
        const stream = sink.stream();
        if (!save(self.plugin, &stream)) return null;
        return try sink.bytes.toOwnedSlice(gpa);
    }

    /// Control thread. Loads state from `data`, which is treated as untrusted. Returns
    /// false without touching the plugin when there is no `clap.state` or `data` is over
    /// `MAX_STATE_BYTES`. A refused load (the plugin returned false) restores the state
    /// that was in place before the call, so the plugin keeps what it had.
    pub fn loadState(self: *const Instance, gpa: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error!bool {
        const st = self.state_ext orelse return false;
        const load = st.load orelse return false;
        if (data.len > abi.MAX_STATE_BYTES) return false;

        // Snapshot first, so a refused load can be undone. This allocates, which is
        // allowed here: the control thread only.
        const previous = try self.saveState(gpa);
        defer if (previous) |p| gpa.free(p);

        var cursor: events.ReadCursor = .{ .data = data };
        const stream: abi.ClapIStream = .{ .ctx = &cursor, .read = events.istreamRead };
        if (load(self.plugin, &stream)) return true;

        if (previous) |p| {
            var back: events.ReadCursor = .{ .data = p };
            const restore: abi.ClapIStream = .{ .ctx = &back, .read = events.istreamRead };
            _ = load(self.plugin, &restore);
        }
        return false;
    }

    // ---- internals ------------------------------------------------------------------------

    /// Builds `bindings` and `param_ids` from the plugin's parameter table. Errors leave
    /// `self` with its previous (empty) tables, so `destroy` frees everything.
    fn buildTables(self: *Instance, gpa: std.mem.Allocator, plug_params: ?[]const param_info.ParamInfo) CreateError!void {
        const raw = try self.readParams(gpa);
        defer freeParams(gpa, raw);
        if (plug_params) |pp| {
            if (pp.len != raw.len) return error.ParamMapMismatch;
        }

        const bindings = try gpa.alloc(ParamBinding, raw.len);
        errdefer gpa.free(bindings);
        const ids = try gpa.alloc(abi.ClapId, raw.len);
        errdefer gpa.free(ids);
        for (raw, 0..) |p, i| {
            bindings[i] = .{
                .clap_id = p.id,
                .clap_min = p.min,
                .clap_max = p.max,
                .clap_default = p.default,
                .plug = if (plug_params) |pp| pp[i] else null,
            };
            ids[i] = p.id;
        }
        self.bindings = bindings;
        self.param_ids = ids;
    }
};

/// The `clap_plugin` extension `id`, typed, or null when the plugin does not have it.
fn extension(plugin: *const abi.ClapPlugin, id: [:0]const u8, comptime T: type) ?*const T {
    const get = plugin.get_extension orelse return null;
    const raw = get(plugin, id.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn destroyPlugin(plugin: *const abi.ClapPlugin) void {
    if (plugin.destroy) |f| f(plugin);
}

fn freeHost(gpa: std.mem.Allocator, host_ptr: *abi.ClapHost, state: *host_mod.HostState) void {
    gpa.destroy(host_ptr);
    gpa.destroy(state);
}

// ---- tests ----------------------------------------------------------------------------------
// The Rust files have no inline tests. The tests below are new: they check the
// Seridian adaptations (no allocation on the audio path, table-based conversion,
// hostile-state handling, output guard) against an in-process fake plugin.

/// An in-process fake CLAP plugin with three parameters (one of them invalid), one
/// audio port, latency, tail, state and a transport-aware process.
const Fake = struct {
    const Mode = enum { normal, process_error, emit_edit, nan_output };

    var init_ok: bool = true;
    var inits: u32 = 0;
    var destroys: u32 = 0;
    var activates: u32 = 0;
    var deactivates: u32 = 0;
    var starts: u32 = 0;
    var stops: u32 = 0;
    var processes: u32 = 0;
    var callbacks: u32 = 0;
    var mode: Mode = .normal;
    var port_channels: u32 = 2;
    var last_tempo: f64 = 0.0;
    var seen_count: usize = 0;
    var seen_ids: [8]abi.ClapId = undefined;
    var seen_values: [8]f64 = undefined;
    var seen_times: [8]u32 = undefined;
    var state_buf: [64]u8 = undefined;
    var state_len: usize = 0;

    fn reset() void {
        init_ok = true;
        inits = 0;
        destroys = 0;
        activates = 0;
        deactivates = 0;
        starts = 0;
        stops = 0;
        processes = 0;
        callbacks = 0;
        mode = .normal;
        port_channels = 2;
        last_tempo = 0.0;
        seen_count = 0;
        state_len = 0;
    }

    fn setName(buf: []u8, s: []const u8) void {
        @memcpy(buf[0..s.len], s);
    }

    fn createPlugin(f: *const abi.ClapPluginFactory, host: *const abi.ClapHost, id: [*:0]const u8) callconv(.c) ?*const abi.ClapPlugin {
        _ = f;
        _ = host;
        _ = id;
        return &plugin_obj;
    }

    fn pInit(plugin: *const abi.ClapPlugin) callconv(.c) bool {
        _ = plugin;
        inits += 1;
        return init_ok;
    }

    fn pDestroy(plugin: *const abi.ClapPlugin) callconv(.c) void {
        _ = plugin;
        destroys += 1;
    }

    fn pActivate(plugin: *const abi.ClapPlugin, sample_rate: f64, min_frames: u32, max_frames: u32) callconv(.c) bool {
        _ = plugin;
        _ = sample_rate;
        _ = min_frames;
        _ = max_frames;
        activates += 1;
        return true;
    }

    fn pDeactivate(plugin: *const abi.ClapPlugin) callconv(.c) void {
        _ = plugin;
        deactivates += 1;
    }

    fn pStart(plugin: *const abi.ClapPlugin) callconv(.c) bool {
        _ = plugin;
        starts += 1;
        return true;
    }

    fn pStop(plugin: *const abi.ClapPlugin) callconv(.c) void {
        _ = plugin;
        stops += 1;
    }

    fn pReset(plugin: *const abi.ClapPlugin) callconv(.c) void {
        _ = plugin;
    }

    fn pOnMainThread(plugin: *const abi.ClapPlugin) callconv(.c) void {
        _ = plugin;
        callbacks += 1;
    }

    fn pProcess(plugin: *const abi.ClapPlugin, process: *const abi.ClapProcess) callconv(.c) abi.ClapProcessStatus {
        _ = plugin;
        processes += 1;
        if (process.transport) |t| last_tempo = t.tempo;

        const input_list = process.in_events.?;
        const n = input_list.size.?(input_list);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const h = input_list.get.?(input_list, i).?;
            if (h.type_ == abi.CLAP_EVENT_PARAM_VALUE and seen_count < seen_ids.len) {
                const pv: *align(1) const abi.ClapEventParamValue = @ptrCast(h);
                seen_ids[seen_count] = pv.param_id;
                seen_values[seen_count] = pv.value;
                seen_times[seen_count] = h.time;
                seen_count += 1;
            }
        }

        if (mode == .emit_edit) {
            var ev: abi.ClapEventParamValue = std.mem.zeroes(abi.ClapEventParamValue);
            ev.header = .{
                .size = @sizeOf(abi.ClapEventParamValue),
                .time = 0,
                .space_id = abi.CLAP_CORE_EVENT_SPACE_ID,
                .type_ = abi.CLAP_EVENT_PARAM_VALUE,
                .flags = 0,
            };
            ev.param_id = 200;
            ev.value = -30.0;
            const out_list = process.out_events.?;
            _ = out_list.try_push.?(out_list, &ev.header);
        }
        if (mode == .process_error) return abi.CLAP_PROCESS_ERROR;
        if (mode == .nan_output) {
            const chans = process.audio_outputs.?[0].data32.?;
            chans[0].?[3] = std.math.nan(f32);
        }
        return abi.CLAP_PROCESS_CONTINUE;
    }

    fn pGetExt(plugin: *const abi.ClapPlugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        _ = plugin;
        const s = std.mem.span(id);
        if (std.mem.eql(u8, s, abi.CLAP_EXT_PARAMS)) return &params_ext;
        if (std.mem.eql(u8, s, abi.CLAP_EXT_AUDIO_PORTS)) return &ports_ext;
        if (std.mem.eql(u8, s, abi.CLAP_EXT_LATENCY)) return &latency_ext;
        if (std.mem.eql(u8, s, abi.CLAP_EXT_TAIL)) return &tail_ext;
        if (std.mem.eql(u8, s, abi.CLAP_EXT_STATE)) return &state_ext;
        return null;
    }

    fn paramCount(plugin: *const abi.ClapPlugin) callconv(.c) u32 {
        _ = plugin;
        return 3;
    }

    fn paramInfo(plugin: *const abi.ClapPlugin, index: u32, info: *abi.ClapParamInfo) callconv(.c) bool {
        _ = plugin;
        info.* = std.mem.zeroes(abi.ClapParamInfo);
        switch (index) {
            // An inverted range: the host must skip it.
            0 => {
                info.id = 50;
                setName(&info.name, "Broken");
                info.min_value = 5.0;
                info.max_value = 1.0;
                info.default_value = 3.0;
                return true;
            },
            1 => {
                info.id = 100;
                setName(&info.name, "Gain");
                info.min_value = 0.0;
                info.max_value = 10.0;
                info.default_value = 5.0;
                return true;
            },
            2 => {
                info.id = 200;
                setName(&info.name, "Mix");
                info.min_value = -60.0;
                info.max_value = 0.0;
                info.default_value = -12.0;
                return true;
            },
            else => return false,
        }
    }

    fn paramValue(plugin: *const abi.ClapPlugin, id: abi.ClapId, out: *f64) callconv(.c) bool {
        _ = plugin;
        out.* = switch (id) {
            100 => 5.0,
            200 => -12.0,
            else => return false,
        };
        return true;
    }

    fn portCount(plugin: *const abi.ClapPlugin, is_input: bool) callconv(.c) u32 {
        _ = plugin;
        _ = is_input;
        return 1;
    }

    fn portGet(plugin: *const abi.ClapPlugin, index: u32, is_input: bool, info: *abi.ClapAudioPortInfo) callconv(.c) bool {
        _ = plugin;
        _ = is_input;
        if (index != 0) return false;
        info.* = std.mem.zeroes(abi.ClapAudioPortInfo);
        info.channel_count = port_channels;
        info.flags = abi.CLAP_AUDIO_PORT_IS_MAIN;
        return true;
    }

    fn latencyGet(plugin: *const abi.ClapPlugin) callconv(.c) u32 {
        _ = plugin;
        return 64;
    }

    fn tailGet(plugin: *const abi.ClapPlugin) callconv(.c) u32 {
        _ = plugin;
        return 128;
    }

    /// Saves the bytes it holds.
    fn stateSave(plugin: *const abi.ClapPlugin, stream: *const abi.ClapOStream) callconv(.c) bool {
        _ = plugin;
        const write = stream.write.?;
        return write(stream, &state_buf, state_len) == @as(i64, @intCast(state_len));
    }

    /// Accepts any bytes except those starting with 'X'. For those it clears its state
    /// first, as a half-applied load would, and then refuses.
    fn stateLoad(plugin: *const abi.ClapPlugin, stream: *const abi.ClapIStream) callconv(.c) bool {
        _ = plugin;
        var buf: [64]u8 = undefined;
        const read = stream.read.?;
        const n = read(stream, &buf, buf.len);
        if (n <= 0) return false;
        const len: usize = @intCast(n);
        if (buf[0] == 'X') {
            state_len = 0;
            return false;
        }
        @memcpy(state_buf[0..len], buf[0..len]);
        state_len = len;
        return true;
    }

    const params_ext: abi.ClapPluginParams = .{
        .count = paramCount,
        .get_info = paramInfo,
        .get_value = paramValue,
        .value_to_text = null,
        .text_to_value = null,
        .flush = null,
    };
    const ports_ext: abi.ClapPluginAudioPorts = .{ .count = portCount, .get = portGet };
    const latency_ext: abi.ClapPluginLatency = .{ .get = latencyGet };
    const tail_ext: abi.ClapPluginTail = .{ .get = tailGet };
    const state_ext: abi.ClapPluginState = .{ .save = stateSave, .load = stateLoad };

    const plugin_obj: abi.ClapPlugin = .{
        .desc = null,
        .plugin_data = null,
        .init = pInit,
        .destroy = pDestroy,
        .activate = pActivate,
        .deactivate = pDeactivate,
        .start_processing = pStart,
        .stop_processing = pStop,
        .reset = pReset,
        .process = pProcess,
        .get_extension = pGetExt,
        .on_main_thread = pOnMainThread,
    };

    const factory: abi.ClapPluginFactory = .{
        .get_plugin_count = null,
        .get_plugin_descriptor = null,
        .create_plugin = createPlugin,
    };
};

/// Plug-0 description of the two valid fake parameters: 0..1 in each, mapped onto the
/// fake's CLAP ranges (Gain 0..10, Mix -60..0).
const map = [_]param_info.ParamInfo{
    param_info.lin("gain", "Gain", 0.0, 1.0, 0.5, .none),
    param_info.lin("mix", "Mix", 0.0, 1.0, 0.0, .none),
};

fn makeInstance(plug_params: ?[]const param_info.ParamInfo) CreateError!*Instance {
    Fake.reset();
    return Instance.create(testing.allocator, &Fake.factory, "fake.plugin", plug_params);
}

fn processFrames(
    inst: *Instance,
    frames: usize,
    inputs: *PortBuffers,
    outputs: *PortBuffers,
    evs: []const host_event.Event,
    transport: ?*const plugin_mod.Transport,
) ProcessError!abi.ClapProcessStatus {
    return inst.process(.{
        .frames = frames,
        .steady_time = 0,
        .inputs = inputs,
        .outputs = outputs,
        .events = evs,
        .offset = 0,
        .transport = transport,
    });
}

test "create builds the dense index to clap_id table and skips an inverted range" {
    const inst = try makeInstance(null);
    defer inst.destroy();

    try testing.expectEqual(@as(usize, 1), Fake.inits);
    try testing.expectEqual(@as(usize, 2), inst.param_ids.len);
    try testing.expectEqual(@as(abi.ClapId, 100), inst.param_ids[0]);
    try testing.expectEqual(@as(abi.ClapId, 200), inst.param_ids[1]);
    try testing.expectEqual(@as(?u32, 1), inst.indexOfClapId(200));
    try testing.expectEqual(@as(?u32, null), inst.indexOfClapId(50));
    try testing.expectEqual(@as(f64, 10.0), inst.bindings[0].clap_max);
    try testing.expectEqual(@as(f64, 5.0), inst.bindings[0].clap_default);
    try testing.expectEqual(@as(?f64, 5.0), inst.paramValue(100));
    try testing.expectEqual(@as(?f64, null), inst.paramValue(50));
}

test "create refuses a plugin whose init fails and destroys the plugin" {
    Fake.reset();
    Fake.init_ok = false;
    try testing.expectError(error.InitFailed, Instance.create(testing.allocator, &Fake.factory, "fake.plugin", null));
    try testing.expectEqual(@as(u32, 1), Fake.destroys);
}

test "create refuses a plug-0 map that does not match the usable parameters" {
    const three = [_]param_info.ParamInfo{ map[0], map[1], map[0] };
    try testing.expectError(error.ParamMapMismatch, makeInstance(&three));
    // The partly built instance is destroyed; testing.allocator reports any leak.
    try testing.expectEqual(@as(u32, 1), Fake.destroys);
}

test "create refuses an id with an interior NUL" {
    Fake.reset();
    const bad: [:0]const u8 = "fake\x00plugin";
    try testing.expectError(error.IdContainsNul, Instance.create(testing.allocator, &Fake.factory, bad, null));
    try testing.expectEqual(@as(u32, 0), Fake.inits);
}

test "plug-0 values convert to CLAP ranges through the binding table and back" {
    const inst = try makeInstance(&map);
    defer inst.destroy();

    try testing.expectApproxEqAbs(@as(f64, 2.5), inst.toClapValue(0, 0.25).?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), inst.toClapValue(1, 1.0).?, 1e-9);
    // NaN becomes the plug-0 default (0.5 for Gain), which maps to 5.0.
    try testing.expectApproxEqAbs(@as(f64, 5.0), inst.toClapValue(0, std.math.nan(f32)).?, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.5), inst.fromClapValue(1, -30.0).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), inst.fromClapValue(0, inst.toClapValue(0, 0.8).?).?, 1e-5);

    try testing.expect(inst.toClapValue(9, 0.1) == null);
    try testing.expect(inst.fromClapValue(9, 0.1) == null);
    try testing.expect(inst.fromClapValue(1, std.math.nan(f64)) == null);
}

test "without a plug-0 map the values are CLAP values clamped to the range" {
    const inst = try makeInstance(null);
    defer inst.destroy();

    try testing.expectApproxEqAbs(@as(f64, 10.0), inst.toClapValue(0, 20.0).?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -12.0), inst.toClapValue(1, std.math.nan(f32)).?, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -60.0), inst.fromClapValue(1, -100.0).?, 1e-5);
}

test "destroy deactivates a live instance and destroys the plugin exactly once" {
    const inst = try makeInstance(null);
    try inst.activate(48_000.0, 1, 512);
    try testing.expect(inst.isActive());
    inst.destroy();
    try testing.expectEqual(@as(u32, 1), Fake.deactivates);
    try testing.expectEqual(@as(u32, 1), Fake.destroys);
}

test "activate refuses impossible sample rates and frame ranges" {
    const inst = try makeInstance(null);
    defer inst.destroy();

    try testing.expectError(error.BadSampleRate, inst.activate(0.0, 1, 512));
    try testing.expectError(error.BadSampleRate, inst.activate(std.math.nan(f64), 1, 512));
    try testing.expectError(error.BadFrameRange, inst.activate(48_000.0, 0, 512));
    try testing.expectError(error.BadFrameRange, inst.activate(48_000.0, 512, 256));
    try testing.expectEqual(@as(u32, 0), Fake.activates);

    try inst.activate(48_000.0, 1, 512);
    try testing.expectEqual(@as(u32, 1), Fake.activates);
    try testing.expect(inst.isActive());
}

test "process delivers parameter events with CLAP ids and converted values, and counts the drops" {
    const inst = try makeInstance(&map);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);

    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 512);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 512);
    defer outputs.deinit(testing.allocator);

    const evs = [_]host_event.Event{
        .{ .offset = 3, .kind = .{ .param = .{ .index = 0, .value = 0.25 } } },
        // An unknown dense index is dropped and counted.
        .{ .offset = 4, .kind = .{ .param = .{ .index = 9, .value = 0.1 } } },
        .{ .offset = 7, .kind = .{ .param = .{ .index = 1, .value = 1.0 } } },
    };
    const status = try processFrames(inst, 32, &inputs, &outputs, &evs, null);
    try testing.expectEqual(abi.CLAP_PROCESS_CONTINUE, status);
    try testing.expectEqual(@as(u32, 1), Fake.processes);
    try testing.expectEqual(@as(usize, 2), Fake.seen_count);
    try testing.expectEqual(@as(abi.ClapId, 100), Fake.seen_ids[0]);
    try testing.expectApproxEqAbs(@as(f64, 2.5), Fake.seen_values[0], 1e-9);
    try testing.expectEqual(@as(u32, 3), Fake.seen_times[0]);
    try testing.expectEqual(@as(abi.ClapId, 200), Fake.seen_ids[1]);
    try testing.expectApproxEqAbs(@as(f64, 0.0), Fake.seen_values[1], 1e-9);
    try testing.expectEqual(@as(usize, 1), inst.events_dropped.load(.monotonic));
}

test "the transport reaches the plugin in the process call" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer outputs.deinit(testing.allocator);

    const transport: plugin_mod.Transport = .{ .playing = true, .tempo = 120.0 };
    _ = try processFrames(inst, 16, &inputs, &outputs, &.{}, &transport);
    try testing.expectEqual(@as(f64, 120.0), Fake.last_tempo);
}

test "a parameter edit the plugin pushes during process reaches the UI as a dense index" {
    const inst = try makeInstance(&map);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer outputs.deinit(testing.allocator);

    Fake.mode = .emit_edit;
    _ = try processFrames(inst, 32, &inputs, &outputs, &.{}, null);

    var out: [4]Edit = undefined;
    const n = inst.drainEdits(&out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0].value, 1e-6);
    try testing.expectEqual(@as(usize, 0), inst.drainEdits(&out));
}

test "a plugin processing error is reported to the caller, not silenced" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer outputs.deinit(testing.allocator);

    Fake.mode = .process_error;
    try testing.expectError(error.PluginError, processFrames(inst, 32, &inputs, &outputs, &.{}, null));
}

test "a non-finite output sample is reported to the caller" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer outputs.deinit(testing.allocator);

    Fake.mode = .nan_output;
    try testing.expectError(error.NonFiniteOutput, processFrames(inst, 32, &inputs, &outputs, &.{}, null));
    // The NaN is still in the buffer, so clear it before a block the plugin writes cleanly.
    Fake.mode = .normal;
    @memset(outputs.storage, 0);
    _ = try processFrames(inst, 32, &inputs, &outputs, &.{}, null);
}

test "process refuses to run when inactive and refuses blocks outside the activated size" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 128);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 128);
    defer outputs.deinit(testing.allocator);

    try testing.expectError(error.NotActive, processFrames(inst, 32, &inputs, &outputs, &.{}, null));

    try inst.activate(48_000.0, 1, 64);
    try testing.expectError(error.BadBlockSize, processFrames(inst, 0, &inputs, &outputs, &.{}, null));
    try testing.expectError(error.BadBlockSize, processFrames(inst, 128, &inputs, &outputs, &.{}, null));
    try testing.expectEqual(@as(u32, 0), Fake.processes);
    _ = try processFrames(inst, 64, &inputs, &outputs, &.{}, null);
    try testing.expectEqual(@as(u32, 1), Fake.processes);
}

test "stop_processing runs once per start, before deactivate" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    try inst.activate(48_000.0, 1, 512);
    var inputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer inputs.deinit(testing.allocator);
    var outputs = try PortBuffers.init(testing.allocator, &.{2}, 64);
    defer outputs.deinit(testing.allocator);

    _ = try processFrames(inst, 32, &inputs, &outputs, &.{}, null);
    _ = try processFrames(inst, 32, &inputs, &outputs, &.{}, null);
    try testing.expectEqual(@as(u32, 1), Fake.starts);
    inst.deactivate();
    try testing.expectEqual(@as(u32, 1), Fake.stops);
    try testing.expectEqual(@as(u32, 1), Fake.deactivates);
    inst.deactivate();
    try testing.expectEqual(@as(u32, 1), Fake.deactivates);
}

test "audioPorts reads the main port and refuses a port wider than MAX_CHANNELS" {
    const inst = try makeInstance(null);
    defer inst.destroy();

    const ports = try inst.audioPorts(true);
    try testing.expectEqual(@as(usize, 1), ports.len);
    try testing.expectEqual(@as(u32, 2), ports.slice()[0].channels);
    try testing.expect(ports.slice()[0].main);

    Fake.port_channels = 32;
    try testing.expectError(error.TooManyChannels, inst.audioPorts(false));
}

test "PortBuffers gives the plugin one pointer per channel and caps channels at MAX_CHANNELS" {
    var pb = try PortBuffers.init(testing.allocator, &.{ 2, 1, 40 }, 16);
    defer pb.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), pb.port_count);
    try testing.expectEqual(@as(usize, 16), pb.channel_counts[2]);
    try testing.expectEqual(@as(usize, 16), pb.channel(2, 0).?.len);
    try testing.expect(pb.channel(0, 2) == null);

    // Zeroed on creation.
    try testing.expectEqual(@as(f32, 0.0), pb.channel(0, 1).?[15]);

    pb.refresh();
    try testing.expectEqual(@as(u32, 2), pb.bufs[0].channel_count);
    const ptrs = pb.bufs[0].data32.?;
    try testing.expect(ptrs[0].? != ptrs[1].?);

    // A write through the channel slice is visible through the plugin's pointer table.
    pb.channel(0, 1).?[0] = 0.5;
    try testing.expectEqual(@as(f32, 0.5), ptrs[1].?[0]);
}

test "latency and tail come from the plugin extensions" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    try testing.expectEqual(@as(u32, 64), inst.latency());
    try testing.expectEqual(@as(u32, 128), inst.tailSamples());
}

test "a plugin callback request runs on_main_thread once, when serviced" {
    const inst = try makeInstance(null);
    defer inst.destroy();

    inst.host.request_callback.?(inst.host);
    try testing.expectEqual(@as(u32, 0), Fake.callbacks);
    inst.serviceCallback();
    inst.serviceCallback();
    try testing.expectEqual(@as(u32, 1), Fake.callbacks);
}

test "saveState returns the plugin's bytes; a refused loadState puts the previous state back" {
    const inst = try makeInstance(null);
    defer inst.destroy();
    @memcpy(Fake.state_buf[0..2], "ok");
    Fake.state_len = 2;

    const before = (try inst.saveState(testing.allocator)).?;
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("ok", before);

    const loaded = try inst.loadState(testing.allocator, "fresh");
    try testing.expect(loaded);
    const after_ok = (try inst.saveState(testing.allocator)).?;
    defer testing.allocator.free(after_ok);
    try testing.expectEqualStrings("fresh", after_ok);

    // The fake clears its state and refuses input that starts with 'X'. The host must
    // put "fresh" back.
    const refused = try inst.loadState(testing.allocator, "Xbad");
    try testing.expect(!refused);
    const after_refused = (try inst.saveState(testing.allocator)).?;
    defer testing.allocator.free(after_refused);
    try testing.expectEqualStrings("fresh", after_refused);
}
