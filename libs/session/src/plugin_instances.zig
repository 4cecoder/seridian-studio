// Translated to Zig from soundcraft/crates/mix/src/instances.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Plugin instance handoff, session side: which third-party plugins a session
//! needs (`instance_specs`), and how one is created, given its stored state and
//! prepared (`createInstance`). Control thread only.
//!
//! Differences from the Rust module, all deliberate:
//! - Seridian has no SoundCraft `Session` model yet, so `instanceSpecs` reads a
//!   `SlotSource` (a vtable over tracks, inserts and instruments) instead of a
//!   struct. Each `SlotEntry` already carries the strip's channel count; the
//!   instrument rule (at least 2 channels) is applied here, as in Rust.
//! - The built-in (dsp) branch of `create_plugin` is not translated: only the
//!   CLAP, VST3 and AU hosts create plugins here.
//! - `Backend` is the factory seam. `Hosts` routes by id prefix to the real
//!   plughost `create` functions. Tests use `test_support.FakeBackend`, a
//!   plughost-style fake, so no plugin is ever scanned (the Rust comment explains
//!   why: a real scan loads every installed plugin in-process).
//! - The Rust `Box<dyn Plugin>` becomes a `Created` value: the plughost `Plugin`
//!   handle plus an `Owner` that frees the instance. `HostedProcessor` adapts
//!   that handle to graph's `Processor` vtable.
//! - `instanceSpecs` returns graph's `InstanceSpec` with `id` and `state`
//!   borrowed from the source (valid while the source is). Rust cloned them.
//!
//! Realtime: `HostedProcessor`'s graph vtable calls (`process`, `reset`,
//! `setTransport`, `latencySamples`, `tailSamples`, `allNotesOff`) run on the audio
//! thread. They do not allocate, lock, log or do I/O; the MIDI event list is
//! allocated in `HostedProcessor.create`. Creation and destruction are control
//! thread only.

const std = @import("std");
const builtin = @import("builtin");
const graph = @import("graph");
const plughost = @import("plughost");

const Allocator = std.mem.Allocator;
const Plugin = plughost.plugin.Plugin;
const AudioBlock = plughost.plugin.AudioBlock;
const Processor = graph.processor.Processor;
const log = std.log.scoped(.session_plugin_instances);

/// Slot index used for a track's instrument plugin (insert slots use their index).
pub const INSTRUMENT_SLOT: usize = graph.slot.INSTRUMENT_SLOT;
/// Graph-local track identifier.
pub const TrackId = graph.slot.TrackId;
/// Most MIDI events one block can carry into a hosted plugin. Events beyond this
/// are dropped by `HostedProcessor.processFn`; see the notes in the session README.
pub const MAX_BLOCK_EVENTS: usize = 256;

/// Hosted third-party plugin ids (CLAP, VST3 or AU) are created off the audio thread.
pub fn isThirdParty(id: []const u8) bool {
    return std.mem.startsWith(u8, id, plughost.clap.ID_PREFIX) or
        std.mem.startsWith(u8, id, plughost.vst3.ID_PREFIX) or
        std.mem.startsWith(u8, id, plughost.au.ID_PREFIX);
}

/// One plugin slot of a session, inserts and instruments alike, in session order
/// (per track: inserts first, then the instrument). `state` is the decoded insert
/// state if any. `channels` is the channel count of the strip the slot sits on.
pub const SlotEntry = struct {
    track: TrackId,
    slot: usize,
    plugin: []const u8,
    state: ?[]const u8 = null,
    channels: usize,
};

/// The session as `instanceSpecs` sees it. The slices are borrowed from the
/// source and valid until it changes; the caller holds the source for the call.
pub const SlotSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The session sample rate in Hz.
        sample_rate: *const fn (ptr: *anyopaque) f32,
        /// Every track id the session has, including inactive and master tracks.
        tracks: *const fn (ptr: *anyopaque) []const TrackId,
        /// Every slot of every track, in session order (see `SlotEntry`).
        slots: *const fn (ptr: *anyopaque) []const SlotEntry,
    };

    pub fn sampleRate(self: SlotSource) f32 {
        return self.vtable.sample_rate(self.ptr);
    }

    pub fn tracks(self: SlotSource) []const TrackId {
        return self.vtable.tracks(self.ptr);
    }

    pub fn slots(self: SlotSource) []const SlotEntry {
        return self.vtable.slots(self.ptr);
    }
};

/// Every third-party plugin slot (inserts and instruments) of the session, with the
/// channel count the instance is prepared for. Built-in plugins are left to the
/// engine. The caller frees the returned slice with `gpa`; its `id` and `state`
/// fields are borrowed from `source`.
pub fn instanceSpecs(gpa: Allocator, source: SlotSource) Allocator.Error![]graph.slot.InstanceSpec {
    var out: std.ArrayList(graph.slot.InstanceSpec) = .empty;
    errdefer out.deinit(gpa);
    for (source.slots()) |entry| {
        if (!isThirdParty(entry.plugin)) continue;
        const ch = if (entry.slot == INSTRUMENT_SLOT) @max(entry.channels, 2) else entry.channels;
        try out.append(gpa, .{ .track = entry.track, .slot = entry.slot, .id = entry.plugin, .ch = ch, .state = entry.state });
    }
    return out.toOwnedSlice(gpa);
}

/// Frees a plugin instance. `ctx` is the backend's own context (or null); `object`
/// is the instance the backend returned. Control thread only.
pub const Owner = struct {
    ctx: ?*anyopaque,
    object: *anyopaque,
    destroy: *const fn (ctx: ?*anyopaque, object: *anyopaque) void,

    pub fn release(self: Owner) void {
        self.destroy(self.ctx, self.object);
    }
};

/// A plugin made by a backend: the handle the rest of the session uses, and the
/// owner that frees it.
pub const Created = struct {
    plugin: Plugin,
    owner: Owner,
};

/// The factory seam: creates a hosted plugin for an id, or null when the id is not
/// one this backend hosts, is unknown, or fails to load (the reason is logged by
/// the host). Control thread only.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (ptr: *anyopaque, gpa: Allocator, id: []const u8) ?Created,
    };

    pub fn create(self: Backend, gpa: Allocator, id: []const u8) ?Created {
        return self.vtable.create(self.ptr, gpa, id);
    }
};

/// The real backend: routes each id by prefix to the plughost host that owns it.
/// `au_host` is the process's Audio Unit host (usually owned by the session
/// layer); when null, `au:` ids are not created.
pub const Hosts = struct {
    io: std.Io,
    au_host: ?*plughost.au.Host = null,

    pub fn backend(self: *Hosts) Backend {
        return .{ .ptr = self, .vtable = &backend_vtable };
    }

    const backend_vtable: Backend.VTable = .{ .create = createFn };

    fn createFn(ptr: *anyopaque, gpa: Allocator, id: []const u8) ?Created {
        const self: *Hosts = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, id, plughost.clap.ID_PREFIX)) {
            const p = plughost.clap.create(self.io, id) orelse return null;
            return .{ .plugin = p.plugin(), .owner = .{ .ctx = null, .object = p, .destroy = destroyClap } };
        }
        if (std.mem.startsWith(u8, id, plughost.vst3.ID_PREFIX)) {
            const p = plughost.vst3.create(gpa, id) orelse return null;
            return .{ .plugin = p.plugin(), .owner = .{ .ctx = null, .object = p, .destroy = destroyVst3 } };
        }
        if (std.mem.startsWith(u8, id, plughost.au.ID_PREFIX)) {
            const host = self.au_host orelse return null;
            const p = host.create(id) orelse return null;
            return .{ .plugin = p.plugin(), .owner = .{ .ctx = host, .object = p, .destroy = destroyAu } };
        }
        return null;
    }

    fn destroyClap(_: ?*anyopaque, object: *anyopaque) void {
        const p: *plughost.clap.ClapPlugin = @ptrCast(@alignCast(object));
        p.destroy();
    }

    fn destroyVst3(_: ?*anyopaque, object: *anyopaque) void {
        const p: *plughost.vst3.plugin.Vst3Plugin = @ptrCast(@alignCast(object));
        plughost.vst3.destroyPlugin(p);
    }

    fn destroyAu(ctx: ?*anyopaque, object: *anyopaque) void {
        const host: *plughost.au.Host = @ptrCast(@alignCast(ctx.?));
        const p: *plughost.au.AuPlugin = @ptrCast(@alignCast(object));
        host.destroy(p);
    }
};

/// A plugin instance made by `createInstance`: the handle (for editors and state),
/// the graph processor that renders it, and whether it refused its stored state.
pub const NewInstance = struct {
    plugin: Plugin,
    processor: Processor,
    /// The plugin refused the stored state and starts from its defaults.
    refused_state: bool,
};

/// Creates a plugin by id, restores `state` (if any; the plugin treats it as hostile
/// input), prepares it, and wraps it for the graph. Returns null when the backend
/// cannot make the id. Expensive for hosted plugins: control thread only.
pub fn createInstance(
    gpa: Allocator,
    backend: Backend,
    id: []const u8,
    state: ?[]const u8,
    sample_rate: f32,
    max_block: usize,
    ch: usize,
) Allocator.Error!?NewInstance {
    const made = backend.create(gpa, id) orelse return null;
    errdefer made.owner.release();
    const refused = if (state) |st| !made.plugin.loadState(st) else false;
    if (refused) log.warn("{s}: the plugin did not accept its stored state", .{id});
    made.plugin.prepare(sample_rate, max_block, ch);
    const hosted = try HostedProcessor.create(gpa, made, sample_rate);
    return .{ .plugin = made.plugin, .processor = hosted.processor(), .refused_state = refused };
}

/// Adapts a plughost `Plugin` handle to graph's `Processor` vtable and owns the
/// instance until `destroy`. Heap allocated so the processor's pointer is stable.
pub const HostedProcessor = struct {
    gpa: Allocator,
    plugin: Plugin,
    owner: Owner,
    sample_rate: f64,
    /// Preallocated in `create`; `processFn` clears and refills it per block.
    events: plughost.event.EventList,
    transport: plughost.plugin.Transport = .{},

    /// Takes ownership of `made.owner` only on success; on error the caller releases it.
    fn create(gpa: Allocator, made: Created, sample_rate: f32) Allocator.Error!*HostedProcessor {
        const events = try plughost.event.EventList.init(gpa, MAX_BLOCK_EVENTS);
        errdefer {
            var list = events;
            list.deinit(gpa);
        }
        const self = try gpa.create(HostedProcessor);
        self.* = .{
            .gpa = gpa,
            .plugin = made.plugin,
            .owner = made.owner,
            .sample_rate = @as(f64, sample_rate),
            .events = events,
        };
        return self;
    }

    pub fn processor(self: *HostedProcessor) Processor {
        return .{ .ptr = self, .vtable = &processor_vtable };
    }

    fn fromPtr(ptr: *anyopaque) *HostedProcessor {
        return @ptrCast(@alignCast(ptr));
    }

    fn prepareFn(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
        const self = fromPtr(ptr);
        self.sample_rate = @as(f64, sample_rate);
        self.plugin.prepare(sample_rate, max_block, channels);
    }

    fn resetFn(ptr: *anyopaque) void {
        fromPtr(ptr).plugin.reset();
    }

    /// Audio thread. Builds the plugin's block from the planar buffers and its
    /// events from the graph's MIDI list. No allocation.
    fn processFn(ptr: *anyopaque, io: [][]f32, frames: usize, events: []const graph.processor.MidiEvent) void {
        const self = fromPtr(ptr);
        const n = @min(io.len, plughost.plugin.MAX_CHANNELS);
        var block: AudioBlock = .{ .n_channels = n, .frames = frames };
        for (io[0..n], 0..) |buf, c| block.channels[c] = buf.ptr;
        self.events.clear();
        for (events) |ev| {
            // Full list: the event is dropped (bounded, no allocation on the audio thread).
            _ = self.events.push(.{ .offset = ev.offset, .kind = .{ .midi3 = ev.bytes } });
        }
        self.plugin.process(block, self.events.items());
    }

    fn latencyFn(ptr: *anyopaque) usize {
        return fromPtr(ptr).plugin.latency();
    }

    fn tailFn(ptr: *anyopaque) usize {
        return fromPtr(ptr).plugin.tailSamples();
    }

    fn setTransportFn(ptr: *anyopaque, t: *const graph.processor.Transport) void {
        const self = fromPtr(ptr);
        const sr = @max(self.sample_rate, 1.0);
        const seconds = @as(f64, @floatFromInt(t.samples)) / sr;
        self.transport = .{
            .playing = t.playing,
            .recording = t.recording,
            .tempo = t.tempo,
            .numerator = t.numerator,
            .denominator = t.denominator,
            .samples = t.samples,
            .seconds = seconds,
            .quarters = seconds * t.tempo / 60.0,
        };
        self.plugin.setTransport(&self.transport);
    }

    /// Approximation: the plughost handle has no all-notes-off entry, so this resets the
    /// plugin, which silences its sounding notes. See the notes in the session README.
    fn allNotesOffFn(ptr: *anyopaque) void {
        fromPtr(ptr).plugin.reset();
    }

    /// Control thread only.
    fn destroyFn(ptr: *anyopaque) void {
        const self = fromPtr(ptr);
        const gpa = self.gpa;
        var list = self.events;
        list.deinit(gpa);
        self.owner.release();
        gpa.destroy(self);
    }

    const processor_vtable: Processor.VTable = .{
        .prepare = prepareFn,
        .reset = resetFn,
        .process = processFn,
        .latency_samples = latencyFn,
        .tail_samples = tailFn,
        .set_transport = setTransportFn,
        .all_notes_off = allNotesOffFn,
        .destroy = destroyFn,
    };
};

/// Test-only factory. Plughost-style fakes, registered in place of the real hosts,
/// so no plugin is scanned or loaded. Empty outside tests.
pub const test_support = if (builtin.is_test) struct {
    /// A plughost `Plugin` with no parameters. It records what it was given.
    pub const FakePlugin = struct {
        gpa: Allocator,
        sample_rate: f32 = 0.0,
        prepared: usize = 0,
        events_seen: usize = 0,
        blocks: usize = 0,

        const info: plughost.plugin.PluginInfo = .{
            .id = "test.fake",
            .name = "Fake Plugin",
            .short_name = "Fake",
            .category = .other,
            .params = &.{},
            .is_instrument = false,
            .audiosuite = false,
        };

        fn fromPtr(ptr: *anyopaque) *FakePlugin {
            return @ptrCast(@alignCast(ptr));
        }

        fn infoFn(_: *anyopaque) *const plughost.plugin.PluginInfo {
            return &info;
        }

        fn prepareFn(ptr: *anyopaque, sample_rate: f32, _: usize, _: usize) void {
            const self = fromPtr(ptr);
            self.sample_rate = sample_rate;
            self.prepared += 1;
        }

        fn resetFn(_: *anyopaque) void {}

        fn setParamFn(_: *anyopaque, _: u32, _: f32) bool {
            return false;
        }

        fn getParamFn(_: *anyopaque, _: u32) ?f32 {
            return null;
        }

        fn processFn(ptr: *anyopaque, _: AudioBlock, events: []const plughost.plugin.Event) void {
            const self = fromPtr(ptr);
            self.events_seen += events.len;
            self.blocks += 1;
        }

        /// Refuses the state bytes "refuse" and accepts anything else.
        fn loadStateFn(_: *anyopaque, data: []const u8) bool {
            return !std.mem.eql(u8, data, "refuse");
        }

        const vtable: Plugin.VTable = .{
            .info = infoFn,
            .prepare = prepareFn,
            .reset = resetFn,
            .set_param = setParamFn,
            .get_param = getParamFn,
            .process = processFn,
            .load_state = loadStateFn,
        };

        pub fn plugin(self: *FakePlugin) Plugin {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    /// A backend that makes `FakePlugin`s for the ids in `known` and nothing else.
    /// `attempts` counts every create call, `creates` the successful ones, `destroys`
    /// the instances freed.
    pub const FakeBackend = struct {
        known: []const []const u8,
        attempts: usize = 0,
        creates: usize = 0,
        destroys: usize = 0,

        pub fn backend(self: *FakeBackend) Backend {
            return .{ .ptr = self, .vtable = &backend_vtable };
        }

        const backend_vtable: Backend.VTable = .{ .create = createFn };

        fn createFn(ptr: *anyopaque, gpa: Allocator, id: []const u8) ?Created {
            const self: *FakeBackend = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            for (self.known) |k| {
                if (!std.mem.eql(u8, k, id)) continue;
                const p = gpa.create(FakePlugin) catch return null;
                p.* = .{ .gpa = gpa };
                self.creates += 1;
                return .{ .plugin = p.plugin(), .owner = .{ .ctx = self, .object = p, .destroy = destroyFn } };
            }
            return null;
        }

        fn destroyFn(ctx: ?*anyopaque, object: *anyopaque) void {
            const self: *FakeBackend = @ptrCast(@alignCast(ctx.?));
            self.destroys += 1;
            const p: *FakePlugin = @ptrCast(@alignCast(object));
            p.gpa.destroy(p);
        }
    };

    /// A `SlotSource` over fixed slices, for tests.
    pub const TestSource = struct {
        rate: f32,
        track_list: []const TrackId,
        slot_list: []const SlotEntry,

        const vtable: SlotSource.VTable = .{ .sample_rate = sampleRateFn, .tracks = tracksFn, .slots = slotsFn };

        fn fromPtr(ptr: *anyopaque) *TestSource {
            return @ptrCast(@alignCast(ptr));
        }

        fn sampleRateFn(ptr: *anyopaque) f32 {
            return fromPtr(ptr).rate;
        }

        fn tracksFn(ptr: *anyopaque) []const TrackId {
            return fromPtr(ptr).track_list;
        }

        fn slotsFn(ptr: *anyopaque) []const SlotEntry {
            return fromPtr(ptr).slot_list;
        }

        pub fn source(self: *TestSource) SlotSource {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };
} else struct {};

// --- tests ---

const testing = std.testing;
const fake = test_support;

test "is_third_party: CLAP, VST3 and AU ids are hosted, built-ins are not" {
    try testing.expect(isThirdParty("clap:com.example.synth"));
    try testing.expect(isThirdParty("vst3:0123456789ABCDEF0123456789ABCDEF"));
    try testing.expect(isThirdParty("au:aumu:dls:appl"));
    try testing.expect(!isThirdParty("gain"));
    try testing.expect(!isThirdParty("clapx:not.a.prefix"));
}

test "instanceSpecs: keeps third-party slots in order and gives instruments at least 2 channels" {
    const gpa = testing.allocator;
    const slots = [_]SlotEntry{
        .{ .track = 1, .slot = 0, .plugin = "clap:a", .state = "s0", .channels = 1 },
        .{ .track = 1, .slot = 1, .plugin = "gain", .channels = 1 },
        .{ .track = 1, .slot = INSTRUMENT_SLOT, .plugin = "clap:synth", .channels = 1 },
    };
    const tracks = [_]TrackId{1};
    var src: fake.TestSource = .{ .rate = 48_000.0, .track_list = &tracks, .slot_list = &slots };
    const specs = try instanceSpecs(gpa, src.source());
    defer gpa.free(specs);
    try testing.expectEqual(@as(usize, 2), specs.len);
    try testing.expectEqualStrings("clap:a", specs[0].id);
    try testing.expectEqual(@as(usize, 1), specs[0].ch);
    try testing.expectEqualStrings("s0", specs[0].state.?);
    try testing.expectEqual(INSTRUMENT_SLOT, specs[1].slot);
    try testing.expectEqual(@as(usize, 2), specs[1].ch);
}

test "createInstance: refused state is reported, the plugin is prepared, and it renders through the graph" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{"clap:test.fake"} };
    const made = (try createInstance(gpa, backend_state.backend(), "clap:test.fake", "refuse", 48_000.0, 512, 2)).?;
    try testing.expect(made.refused_state);
    const fp: *fake.FakePlugin = @ptrCast(@alignCast(made.plugin.ptr));
    try testing.expectEqual(@as(usize, 1), fp.prepared);
    try testing.expectEqual(@as(f32, 48_000.0), fp.sample_rate);

    var l = [_]f32{ 0.5, 0.5 };
    var r = [_]f32{ 0.5, 0.5 };
    var io = [_][]f32{ &l, &r };
    const events = [_]graph.processor.MidiEvent{.{ .offset = 0, .bytes = .{ 0x90, 60, 100 } }};
    made.processor.process(&io, 2, &events);
    try testing.expectEqual(@as(usize, 1), fp.events_seen);
    try testing.expectEqual(@as(usize, 1), fp.blocks);

    made.processor.destroy();
    try testing.expectEqual(@as(usize, 1), backend_state.destroys);
}

test "createInstance: an id the backend does not host yields null and creates nothing" {
    const gpa = testing.allocator;
    var backend_state: fake.FakeBackend = .{ .known = &.{} };
    try testing.expect((try createInstance(gpa, backend_state.backend(), "clap:does.not.exist", null, 48_000.0, 512, 2)) == null);
    try testing.expectEqual(@as(usize, 1), backend_state.attempts);
    try testing.expectEqual(@as(usize, 0), backend_state.creates);
}
