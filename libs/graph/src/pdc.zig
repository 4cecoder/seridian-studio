// Translated to Zig from soundcraft/crates/mix/src/lib.rs, soundcraft/crates/mix/src/strip.rs, soundcraft/crates/mix/src/tests.rs, soundcraft/crates/mix/tests/it/bus_aux_interval.rs, soundcraft/crates/mix/tests/it/master_insert_latency.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Plugin delay compensation (PDC) for the graph.
//!
//! Three pieces, split by thread:
//! - `computePlan` (control thread, no allocation): from the routing skeleton and each
//!   node's reported insert and instrument latency it works out the mix latency, the
//!   longest track and aux paths (`track_latency`, `aux_latency`) and, per node, the
//!   delays that bring every path to the same total. The result goes into a `PdcPlan`
//!   that the caller owns (a fixed-size value, nothing is allocated).
//! - `Pdc.ensure` (control thread, allocates): grows the per-node delay lines to the
//!   plan's needs. It is the only allocating call in this file.
//! - `Pdc.apply`, `Pdc.process`, `Pdc.reset` (audio thread): move indices and write into
//!   storage that already exists. They never allocate, lock, log or do I/O.
//!
//! Offline renders (bounces) read the same plan: they render `latency` samples ahead and
//! drop the head, so the output lines up with the timeline (`renderRange` in the test rig
//! below). The mix latency of a bus is `PdcPlan.busLatency`.
//!
//! Latency that is reported is capped at `MAX_LATENCY` per node (a plugin's bogus value
//! cannot stall renders). Sums of node latencies saturate.

const std = @import("std");
const topology = @import("topology.zig");
const delay_line = @import("delay_line.zig");
const routing = @import("routing.zig");
const failure = @import("failure.zig");

const Topology = topology.Topology;
const Node = topology.Node;
const NodeId = topology.NodeId;
const BusId = topology.BusId;
const DelayLine = delay_line.DelayLine;
const MAX_LATENCY = delay_line.MAX_LATENCY;
const max_nodes = topology.max_nodes;
const max_buses = topology.max_buses;

/// Caps one reported latency at `MAX_LATENCY`. `failure.zig` owns the single definition.
const capLatency = failure.capLatency;

/// What the control thread knows about one node. The plugin latencies are read from the
/// plugins by the owner (plughost, or a test) and passed in here.
pub const NodeLatency = struct {
    /// Summed latency of the node's active, non-failed inserts (samples, uncapped).
    inserts: usize = 0,
    /// Latency of the node's instrument (samples, uncapped). Zero for nodes without one.
    /// SoundCraft does not add instrument latency to its PDC sums; this file does, as the
    /// graph spec asks. See the notes on `computePlan`.
    instrument: usize = 0,
    /// Rust `Track::inactive`: the node is not rendered and takes no part in the latency.
    inactive: bool = false,
};

/// Delays of one node, in samples. All values are at most `MAX_LATENCY`.
pub const NodeDelay = struct {
    /// The node's own reported latency (inserts plus instrument, capped).
    latency: usize = 0,
    /// Delay on the post-fader path (the strip's `align_post`).
    align_post: usize = 0,
    /// Delay on the pre-fader tap feeding pre-fader sends (tracks only).
    align_pre: usize = 0,
    /// Extra delay for a direct output that waits for the aux returns (tracks only).
    out_extra: usize = 0,
};

/// The precomputed delay plan. Fixed size: filled by `computePlan`, read by `Pdc.apply`.
pub const PdcPlan = struct {
    /// `Session.edit.delay_compensation`. When false every delay below is zero.
    enabled: bool = false,
    /// Total latency of the main mix: slowest track, slowest aux return and the master
    /// inserts, added up (Rust `MixEngine::latency`). Offline main renders pre-roll by it.
    latency: usize = 0,
    /// Delay already applied to audio written onto busses: the slowest track (Rust `track_latency`).
    track_latency: usize = 0,
    /// Slowest aux return (Rust `aux_latency`).
    aux_latency: usize = 0,
    /// Busses an aux returns onto. Audio written onto such a bus also waits for `aux_latency`.
    aux_fed: [max_buses]bool = @splat(false),
    /// Per-node delays, indexed by node id.
    nodes: [max_nodes]NodeDelay = @splat(NodeDelay{}),

    /// Latency of a bus, for bounces: the slowest track plus the slowest aux return when an
    /// aux returns onto this bus (Rust `bus_latency`).
    pub fn busLatency(self: *const PdcPlan, bus: BusId) usize {
        const fed = bus < max_buses and self.aux_fed[bus];
        return self.track_latency + if (fed) self.aux_latency else 0;
    }

    /// The largest delay any line of this plan needs (the capacity `Pdc.ensure` must reach).
    pub fn largestDelay(self: *const PdcPlan) usize {
        var m: usize = 0;
        for (self.nodes) |d| m = @max(m, d.align_post, d.align_pre, d.out_extra);
        return m;
    }
};

fn hasPreFaderSend(node: *const Node) bool {
    for (node.sends) |maybe| {
        const send = maybe orelse continue;
        if (send.pre_fader) return true;
    }
    return false;
}

/// Control thread, no allocation. Fills `plan` from the routing skeleton and the per-node
/// latencies (`lat[i]` belongs to `topo.nodes[i]`, `lat.len >= topo.len`).
///
/// The rules follow SoundCraft's `compensate_delay`:
/// - the track latency `lmax_t` is the slowest live track; every track is delayed by
///   `lmax_t - latency` (plus `aux_latency` on its direct output if it waits for the aux
///   returns: it goes to Main, or to a bus an aux returns onto);
/// - the aux latency `lmax_a` is the slowest live aux or folder; every aux is delayed by
///   `lmax_a - latency`;
/// - master inserts are not aligned, they add to `latency` (the whole main mix pre-rolls by it);
/// - with `enabled == false` the latencies are reported per node but every delay is zero.
///
/// Notes: a node's latency is `min(MAX_LATENCY, inserts +| instrument)`. The instrument term
/// is an addition to SoundCraft (it does not count instrument latency).
/// `VCA` nodes do not exist in the skeleton; SoundCraft's `is_live` also excludes them.
pub fn computePlan(plan: *PdcPlan, topo: *const Topology, lat: []const NodeLatency, enabled: bool) void {
    std.debug.assert(lat.len >= topo.len);
    const nodes = topo.items();
    plan.enabled = enabled;
    plan.latency = 0;
    plan.track_latency = 0;
    plan.aux_latency = 0;
    @memset(&plan.aux_fed, false);
    @memset(&plan.nodes, NodeDelay{});

    var lmax_t: usize = 0;
    var lmax_a: usize = 0;
    var lmax_m: usize = 0;
    for (nodes, 0..) |node, i| {
        const l = lat[i];
        const reported = capLatency(l.inserts +| l.instrument);
        plan.nodes[i].latency = reported;
        if (!enabled or l.inactive) continue;
        switch (node.kind) {
            .track => lmax_t = @max(lmax_t, reported),
            .aux, .folder => lmax_a = @max(lmax_a, reported),
            .master => lmax_m = lmax_m +| reported,
        }
    }
    if (!enabled) return;

    plan.track_latency = lmax_t;
    plan.aux_latency = lmax_a;
    plan.latency = lmax_t +| lmax_a +| lmax_m;

    // An aux that returns onto a bus delays it by the slowest aux return, so the tracks routed
    // to that bus wait as well (as the ones routed to the main mix do) and the bus lines up.
    for (nodes, 0..) |node, i| {
        if (!isAuxLike(node.kind) or lat[i].inactive) continue;
        switch (node.output) {
            // A bus id outside the table (`Topology.validate` rejects it) names no bus.
            .bus => |b| if (b < max_buses) {
                plan.aux_fed[b] = true;
            },
            .main, .none => {},
        }
    }

    for (nodes, 0..) |node, i| {
        if (lat[i].inactive) continue;
        switch (node.kind) {
            .track => {
                const align_post = lmax_t -| plan.nodes[i].latency;
                plan.nodes[i].align_post = align_post;
                plan.nodes[i].align_pre = if (hasPreFaderSend(&node)) align_post else 0;
                const waits = switch (node.output) {
                    .main => true,
                    .bus => |b| b < max_buses and plan.aux_fed[b],
                    .none => false,
                };
                plan.nodes[i].out_extra = if (waits) lmax_a else 0;
            },
            .aux, .folder => plan.nodes[i].align_post = lmax_a -| plan.nodes[i].latency,
            .master => {},
        }
    }
}

fn isAuxLike(kind: topology.Kind) bool {
    return kind == .aux or kind == .folder;
}

/// The three delay lines a node owns.
const NodeLines = struct {
    align_post: DelayLine = .{},
    align_pre: DelayLine = .{},
    out_extra: DelayLine = .{},
};

/// Which of a node's lines to use.
pub const Line = enum { align_post, align_pre, out_extra };

/// The delay lines of every node, sized by the control thread and driven by the audio thread.
pub const Pdc = struct {
    lines: [max_nodes]NodeLines = undefined,

    pub fn init() Pdc {
        var p: Pdc = .{};
        @memset(&p.lines, NodeLines{});
        return p;
    }

    /// Control thread. Frees every line.
    pub fn deinit(self: *Pdc, gpa: std.mem.Allocator) void {
        for (&self.lines) |*l| {
            l.align_post.deinit(gpa);
            l.align_pre.deinit(gpa);
            l.out_extra.deinit(gpa);
        }
    }

    /// Control thread, allocates. Makes every line that the plan delays hold its delay for
    /// `channels` channels. Lines that already fit are left alone, so the common case (a plan
    /// change that keeps the same delays) allocates nothing. A line that is re-prepared loses
    /// its history: call this only while the audio thread is not rendering, or hand the
    /// result over with the graph-3 swap (see the file header of `delay_line.zig`).
    pub fn ensure(self: *Pdc, gpa: std.mem.Allocator, plan: *const PdcPlan, channels: usize) !void {
        for (0..max_nodes) |i| {
            const d = plan.nodes[i];
            try ensureLine(gpa, &self.lines[i].align_post, d.align_post, channels);
            try ensureLine(gpa, &self.lines[i].align_pre, d.align_pre, channels);
            try ensureLine(gpa, &self.lines[i].out_extra, d.out_extra, channels);
        }
    }

    /// Audio thread. Sets every line to the plan's delay. Returns false if some delay did not
    /// fit its line (`Pdc.ensure` was not run for this plan); that delay is clamped.
    pub fn apply(self: *Pdc, plan: *const PdcPlan) bool {
        var fits = true;
        for (0..max_nodes) |i| {
            const d = plan.nodes[i];
            fits = self.lines[i].align_post.setDelay(d.align_post) and fits;
            fits = self.lines[i].align_pre.setDelay(d.align_pre) and fits;
            fits = self.lines[i].out_extra.setDelay(d.out_extra) and fits;
        }
        return fits;
    }

    /// Audio thread. The delay line `which` of `node`.
    pub fn line(self: *Pdc, node: usize, which: Line) *DelayLine {
        const lines = &self.lines[node];
        return switch (which) {
            .align_post => &lines.align_post,
            .align_pre => &lines.align_pre,
            .out_extra => &lines.out_extra,
        };
    }

    /// Audio thread. Delays `io` in place (the first `frames` samples of each channel).
    pub fn process(self: *Pdc, node: usize, which: Line, io: []const [*]f32, frames: usize) void {
        self.line(node, which).process(io, frames);
    }

    /// Audio thread. Clears every line's history (stop, locate). Delays and storage stay.
    pub fn reset(self: *Pdc) void {
        for (&self.lines) |*l| {
            l.align_post.clear();
            l.align_pre.clear();
            l.out_extra.clear();
        }
    }
};

fn ensureLine(gpa: std.mem.Allocator, line: *DelayLine, need: usize, channels: usize) !void {
    if (need == 0) return;
    if (need <= line.capacity and line.channels == channels) return;
    try line.prepare(gpa, need, channels);
}

// --- test-only render rig -------------------------------------------------------------
//
// The Rust tests render a whole `Session` through `MixEngine`. Here a small rig stands in:
// nodes are the routing skeleton of `topology.zig`, a track plays a mono source (both
// channels get the same samples), every insert is a fixed-latency delay with a reported
// latency that can differ from the real one (the bogus-latency test), sends are unity-gain
// adds, and busses are sums. The render loop follows graph-1's processing order.

const testing = std.testing;

/// Largest block the rig renders (the Rust fixtures render at 1024).
const max_test_block: usize = 1024;
/// Channels the rig renders (stereo, like the Rust fixtures).
const max_channels: usize = 2;

fn dbToGain(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

/// Source sample at timeline position `p` (0 outside the clip).
fn sampleAt(src: []const f32, p: i64) f32 {
    if (p < 0 or p >= @as(i64, @intCast(src.len))) return 0;
    return src[@intCast(p)];
}

pub const Rig = struct {
    gpa: std.mem.Allocator,
    channels: usize,
    max_block: usize,
    topo: Topology,
    /// What the control thread is told about each node.
    lat: [max_nodes]NodeLatency = undefined,
    /// What each insert really delays its signal by. Equal to its report except in the
    /// bogus-latency test.
    insert_delay: [max_nodes]usize = undefined,
    /// Mono source of each track node (null for everything else).
    source: [max_nodes]?[]const f32 = undefined,
    insert_lines: [max_nodes]DelayLine = undefined,
    pdc: Pdc = undefined,
    plan: PdcPlan = .{},
    order: [max_nodes]NodeId = undefined,
    order_len: usize = 0,
    /// Per node, per channel: the strip buffer, and the pre-fader copy.
    strip: []f32,
    pre: []f32,
    /// Per bus, per channel. Summed into during a block.
    bus: []f32,
    /// Main mix, per channel (index 0 lanes).
    main: []f32,

    pub fn create(gpa: std.mem.Allocator, channels: usize, max_block: usize) !*Rig {
        std.debug.assert(channels >= 1 and channels <= max_channels);
        std.debug.assert(max_block <= max_test_block);
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        const strip = try gpa.alloc(f32, max_nodes * channels * max_block);
        errdefer gpa.free(strip);
        const pre = try gpa.alloc(f32, max_nodes * channels * max_block);
        errdefer gpa.free(pre);
        const bus = try gpa.alloc(f32, max_buses * channels * max_block);
        errdefer gpa.free(bus);
        const main = try gpa.alloc(f32, channels * max_block);
        errdefer gpa.free(main);

        self.* = .{
            .gpa = gpa,
            .channels = channels,
            .max_block = max_block,
            .topo = Topology.init(),
            .strip = strip,
            .pre = pre,
            .bus = bus,
            .main = main,
        };
        @memset(&self.lat, NodeLatency{});
        @memset(&self.insert_delay, 0);
        @memset(&self.source, null);
        @memset(&self.insert_lines, DelayLine{});
        self.pdc = Pdc.init();
        return self;
    }

    pub fn destroy(self: *Rig) void {
        const gpa = self.gpa;
        for (&self.insert_lines) |*d| d.deinit(gpa);
        self.pdc.deinit(gpa);
        gpa.free(self.strip);
        gpa.free(self.pre);
        gpa.free(self.bus);
        gpa.free(self.main);
        gpa.destroy(self);
    }

    /// Adds a node. `source` is a track's mono signal; `latency` is both the report and the real delay.
    pub fn addNode(self: *Rig, node: Node, source: ?[]const f32, latency: usize) !NodeId {
        const id = try self.topo.addNode(node);
        const i: usize = id;
        self.source[i] = source;
        self.lat[i] = .{ .inserts = latency };
        self.insert_delay[i] = latency;
        return id;
    }

    /// Changes the real and the reported latency of a node's insert.
    pub fn setInsert(self: *Rig, id: NodeId, latency: usize) void {
        self.lat[id].inserts = latency;
        self.insert_delay[id] = latency;
    }

    /// Changes only the reported latency (the real delay stays).
    pub fn setReported(self: *Rig, id: NodeId, latency: usize) void {
        self.lat[id].inserts = latency;
    }

    /// Adds a unity-gain post-fader send from `id` to `bus` (send slot 0).
    pub fn setSendTo(self: *Rig, id: NodeId, bus: BusId) !void {
        try self.topo.setSend(id, 0, .{ .target = .{ .bus = bus }, .level_db = 0.0 });
    }

    /// Control thread. Recomputes the order and the plan, grows the lines and applies the plan.
    /// Call after every change to the graph, the latencies or `enabled`.
    pub fn rebuild(self: *Rig, enabled: bool) !void {
        self.order_len = try routing.processingOrder(&self.topo, &self.order);
        computePlan(&self.plan, &self.topo, self.lat[0..self.topo.len], enabled);
        try self.pdc.ensure(self.gpa, &self.plan, self.channels);
        const fits = self.pdc.apply(&self.plan);
        std.debug.assert(fits);
        for (0..self.topo.len) |i| {
            const need = self.insert_delay[i];
            try ensureLine(self.gpa, &self.insert_lines[i], need, self.channels);
            const fits_insert = self.insert_lines[i].setDelay(need);
            std.debug.assert(fits_insert);
        }
    }

    /// Audio thread. Clears every history (stop, locate).
    pub fn reset(self: *Rig) void {
        self.pdc.reset();
        for (0..self.topo.len) |i| self.insert_lines[i].clear();
    }

    fn lane(self: *Rig, buf: []f32, index: usize, c: usize) []f32 {
        const base = (index * self.channels + c) * self.max_block;
        return buf[base..][0..self.max_block];
    }

    fn ptrs(self: *Rig, buf: []f32, index: usize) [max_channels][*]f32 {
        var p: [max_channels][*]f32 = undefined;
        for (0..self.channels) |c| p[c] = self.lane(buf, index, c).ptr;
        return p;
    }

    fn zeroLanes(self: *Rig, buf: []f32, index: usize, frames: usize) void {
        for (0..self.channels) |c| @memset(self.lane(buf, index, c)[0..frames], 0);
    }

    fn copyLanes(self: *Rig, dst: []f32, dst_index: usize, src: []f32, src_index: usize, frames: usize) void {
        for (0..self.channels) |c| {
            @memcpy(self.lane(dst, dst_index, c)[0..frames], self.lane(src, src_index, c)[0..frames]);
        }
    }

    fn addLanes(self: *Rig, dst: []f32, dst_index: usize, src: []f32, src_index: usize, gain: f32, frames: usize) void {
        for (0..self.channels) |c| {
            const d = self.lane(dst, dst_index, c)[0..frames];
            const s = self.lane(src, src_index, c)[0..frames];
            for (d, s) |*x, y| x.* += y * gain;
        }
    }

    /// The insert of a node: its real delay, applied in place to its strip.
    fn runInsert(self: *Rig, id: usize, frames: usize) void {
        var p = self.ptrs(self.strip, id);
        self.insert_lines[id].process(p[0..self.channels], frames);
    }

    /// Pre-fader tap, alignment, sends, output delay and routing of a strip that has its
    /// insert output in `strip` (the common tail of a track and an aux).
    fn finishStrip(self: *Rig, id: usize, frames: usize) void {
        const node = self.topo.nodes[id];
        if (hasPreFaderSend(&node)) {
            self.copyLanes(self.pre, id, self.strip, id, frames);
            var p = self.ptrs(self.pre, id);
            self.pdc.process(id, .align_pre, p[0..self.channels], frames);
        }
        var q = self.ptrs(self.strip, id);
        self.pdc.process(id, .align_post, q[0..self.channels], frames);
        for (node.sends) |maybe| {
            const send = maybe orelse continue;
            const target: usize = switch (send.target) {
                .bus => |b| b,
                .none, .main => continue,
            };
            const src = if (send.pre_fader) self.pre else self.strip;
            self.addLanes(self.bus, target, src, id, dbToGain(send.level_db), frames);
        }
        // Sends read the aligned strip before the output delay (Rust `route_strip`).
        var r = self.ptrs(self.strip, id);
        self.pdc.process(id, .out_extra, r[0..self.channels], frames);
        switch (node.output) {
            .main => self.addLanes(self.main, 0, self.strip, id, 1.0, frames),
            .bus => |b| self.addLanes(self.bus, b, self.strip, id, 1.0, frames),
            .none => {},
        }
    }

    /// Renders one block at timeline position `pos`. `bus` picks the bus to copy out instead
    /// of the main mix. `out` has one slice per channel, each at least `frames` long.
    pub fn renderBlock(self: *Rig, pos: i64, frames: usize, bus: ?BusId, out: []const []f32) void {
        std.debug.assert(frames <= self.max_block);
        for (0..max_buses) |b| self.zeroLanes(self.bus, b, frames);
        self.zeroLanes(self.main, 0, frames);

        // Phase 1 and 2: tracks, then auxes in graph-1 order. Masters are skipped here.
        for (self.order[0..self.order_len]) |id| {
            const node = self.topo.nodes[id];
            switch (node.kind) {
                .track => {
                    for (0..self.channels) |c| {
                        const dst = self.lane(self.strip, id, c)[0..frames];
                        const src = self.source[id];
                        for (dst, 0..) |*x, i| {
                            x.* = if (src) |s| sampleAt(s, pos + @as(i64, @intCast(i))) else 0;
                        }
                    }
                    self.runInsert(id, frames);
                    self.finishStrip(id, frames);
                },
                .aux, .folder => {
                    for (0..self.channels) |c| {
                        const dst = self.lane(self.strip, id, c)[0..frames];
                        switch (node.input) {
                            .bus => |b| @memcpy(dst, self.lane(self.bus, b, c)[0..frames]),
                            .none, .main => @memset(dst, 0),
                        }
                    }
                    self.runInsert(id, frames);
                    self.finishStrip(id, frames);
                },
                .master => {},
            }
        }

        // Phase 3: master inserts process the main mix, one after the other (Rust `render_masters`).
        for (0..self.topo.len) |id| {
            if (self.topo.nodes[id].kind != .master) continue;
            self.copyLanes(self.strip, id, self.main, 0, frames);
            self.runInsert(id, frames);
            self.copyLanes(self.main, 0, self.strip, id, frames);
        }

        const src_buf = if (bus != null) self.bus else self.main;
        const src_index: usize = bus orelse 0;
        for (out[0..@min(out.len, self.channels)], 0..) |o, c| {
            @memcpy(o[0..frames], self.lane(src_buf, src_index, c)[0..frames]);
        }
    }
};

/// Offline output: one owned slice per channel, and how many blocks produced no output
/// (their frames were all pre-roll).
pub const Rendered = struct {
    gpa: std.mem.Allocator,
    channels: [][]f32,
    skipped: usize,

    pub fn deinit(self: Rendered) void {
        for (self.channels) |c| self.gpa.free(c);
        self.gpa.free(self.channels);
    }
};

/// Renders `[start, end)` the way SoundCraft's `RangeRender` does: the engine runs
/// `latency` samples ahead (`bus` or main, per the plan) and the first `latency` samples are
/// dropped, so the output lines up with the timeline.
pub fn renderRange(rig: *Rig, start: i64, end: i64, block: usize, bus: ?BusId) !Rendered {
    std.debug.assert(end >= start);
    std.debug.assert(block >= 1 and block <= max_test_block);
    const gpa = rig.gpa;
    const len: usize = @intCast(end - start);
    const latency = if (bus) |b| rig.plan.busLatency(b) else rig.plan.latency;

    const chans = try gpa.alloc([]f32, rig.channels);
    var made: usize = 0;
    errdefer {
        for (chans[0..made]) |c| gpa.free(c);
        gpa.free(chans);
    }
    while (made < rig.channels) : (made += 1) chans[made] = try gpa.alloc(f32, len);

    var store: [max_channels][max_test_block]f32 = undefined;
    var chunk: [max_channels][]f32 = undefined;
    for (0..rig.channels) |c| chunk[c] = store[c][0..];

    var pos = start;
    var engine_left: usize = len + latency;
    var skip = latency;
    var got: usize = 0;
    var skipped: usize = 0;
    while (engine_left > 0) {
        const frames = @min(block, engine_left);
        rig.renderBlock(pos, frames, bus, chunk[0..rig.channels]);
        pos += @intCast(frames);
        engine_left -= frames;
        const drop = @min(skip, frames);
        skip -= drop;
        const n = frames - drop;
        if (n == 0) skipped += 1;
        for (0..rig.channels) |c| @memcpy(chans[c][got..][0..n], chunk[c][drop..][0..n]);
        got += n;
    }
    std.debug.assert(got == len);
    return .{ .gpa = gpa, .channels = chans, .skipped = skipped };
}

// --- tests ----------------------------------------------------------------------------

/// 5 ms at 48 kHz: the lookahead of the Rust fixtures' compressor and maximizer.
const lookahead_5ms: usize = 240;
const bus_a: BusId = 0;
const bus_b: BusId = 1;
const impulse_positions = [_]usize{ 0, 2048, 8000 };

fn impulseSignal() [8192]f32 {
    var signal: [8192]f32 = @splat(0);
    for (impulse_positions) |at| signal[at] = 0.25;
    return signal;
}

/// Index of the sample with the largest magnitude; the last one wins a tie (Rust `max_by`).
fn peakAt(ch: []const f32) usize {
    var best: usize = 0;
    var best_v: f32 = -1;
    for (ch, 0..) |x, i| {
        if (@abs(x) >= best_v) {
            best_v = @abs(x);
            best = i;
        }
    }
    return best;
}

/// Positions whose magnitude is above 1e-4 (Rust `positions` / `impulse_at`).
fn impulsePositions(ch: []const f32, buf: []usize) []usize {
    var n: usize = 0;
    for (ch, 0..) |x, i| {
        if (@abs(x) > 1e-4) {
            buf[n] = i;
            n += 1;
        }
    }
    return buf[0..n];
}

fn expectImpulses(ch: []const f32, want: []const usize) !void {
    var buf: [64]usize = undefined;
    const got = impulsePositions(ch, &buf);
    try testing.expectEqualSlices(usize, want, got);
}

/// Bus fixture (bus_aux_interval.rs): a source routed to bus A, and an aux that reads A and
/// returns onto B (or the main mix), with `aux_latency` on its insert.
fn busScene(gpa: std.mem.Allocator, signal: []const f32, aux_latency: usize, aux_to_main: bool) !*Rig {
    const rig = try Rig.create(gpa, 2, max_test_block);
    errdefer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .{ .bus = bus_a } }, signal, 0);
    _ = try rig.addNode(.{
        .kind = .aux,
        .input = .{ .bus = bus_a },
        .output = if (aux_to_main) .main else .{ .bus = bus_b },
    }, null, aux_latency);
    try rig.rebuild(true);
    return rig;
}

test "named bus after aux preserves requested timeline" {
    const signal = impulseSignal();
    const rig = try busScene(testing.allocator, &signal, lookahead_5ms, false);
    defer rig.destroy();
    const control_rig = try busScene(testing.allocator, &signal, 0, false);
    defer control_rig.destroy();
    const main_rig = try busScene(testing.allocator, &signal, lookahead_5ms, true);
    defer main_rig.destroy();

    const bus = try renderRange(rig, 0, 8192, 1024, bus_b);
    defer bus.deinit();
    const upstream = try renderRange(rig, 0, 8192, 1024, bus_a);
    defer upstream.deinit();
    const control = try renderRange(control_rig, 0, 8192, 1024, bus_b);
    defer control.deinit();
    const main = try renderRange(main_rig, 0, 8192, 1024, null);
    defer main.deinit();

    for (0..2) |c| {
        // Controls: the bus before the aux, the same route without the insert, and the main mix.
        try expectImpulses(control.channels[c], &impulse_positions);
        try testing.expectEqualSlices(f32, control.channels[c], upstream.channels[c]);
        try testing.expectEqualSlices(f32, control.channels[c], main.channels[c]);
        // The bus after the aux: the whole interval, nothing late, nothing cut off.
        try testing.expectEqual(@as(usize, 8192), bus.channels[c].len);
        try expectImpulses(bus.channels[c], &impulse_positions);
        try testing.expectEqualSlices(f32, control.channels[c], bus.channels[c]);
    }
    // A partial range lines up too.
    const part = try renderRange(rig, 2048, 4096, 1024, bus_b);
    defer part.deinit();
    try expectImpulses(part.channels[0], &.{0});
}

test "a track routed to the same bus stays aligned with the aux return" {
    // A second track goes straight to bus B, where the aux (with its lookahead) also returns.
    const signal = impulseSignal();
    const rig = try busScene(testing.allocator, &signal, lookahead_5ms, false);
    defer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .{ .bus = bus_b } }, &signal, 0);
    try rig.rebuild(true);

    const bus = try renderRange(rig, 0, 8192, 1024, bus_b);
    defer bus.deinit();
    for (bus.channels) |ch| {
        try expectImpulses(ch, &impulse_positions);
        for (impulse_positions) |at| try testing.expect(@abs(ch[at] - 0.5) < 1e-3);
    }
}

/// Master fixture (master_insert_latency.rs): a track with an impulse at 2000 routed to the
/// main mix, and a master with `master_latency` on its insert.
fn masterScene(gpa: std.mem.Allocator, signal: []const f32, master_latency: usize) !*Rig {
    const rig = try Rig.create(gpa, 2, max_test_block);
    errdefer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, signal, 0);
    _ = try rig.addNode(.{ .kind = .master }, null, master_latency);
    try rig.rebuild(true);
    return rig;
}

test "a master insert with lookahead does not delay the bounce" {
    var signal: [12_000]f32 = @splat(0);
    signal[2000] = 0.9;
    const control_rig = try masterScene(testing.allocator, &signal, 0);
    defer control_rig.destroy();
    const control = try renderRange(control_rig, 0, 12_000, 512, null);
    defer control.deinit();
    try testing.expectEqual(@as(usize, 2000), peakAt(control.channels[0]));

    const rig = try masterScene(testing.allocator, &signal, lookahead_5ms);
    defer rig.destroy();
    const out = try renderRange(rig, 0, 12_000, 512, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 12_000), out.channels[0].len);
    // The limited impulse lines up with the mix without the master insert.
    try testing.expectEqual(@as(usize, 2000), peakAt(out.channels[0]));
    try testing.expectEqual(@as(usize, 2000), peakAt(out.channels[1]));
    try testing.expect(rig.plan.latency > 0); // the master reports a lookahead

    // With Delay Compensation off nothing is compensated (and nothing is dropped).
    try rig.rebuild(false);
    const late = try renderRange(rig, 0, 12_000, 512, null);
    defer late.deinit();
    try testing.expectEqual(@as(usize, 2000 + lookahead_5ms), peakAt(late.channels[0]));
}

test "master inserts without latency change nothing" {
    var signal: [12_000]f32 = @splat(0);
    signal[2000] = 0.9;
    const control_rig = try masterScene(testing.allocator, &signal, 0);
    defer control_rig.destroy();
    const control = try renderRange(control_rig, 0, 12_000, 512, null);
    defer control.deinit();
    const gain_rig = try masterScene(testing.allocator, &signal, 0);
    defer gain_rig.destroy();
    const gain = try renderRange(gain_rig, 0, 12_000, 512, null);
    defer gain.deinit();
    try testing.expectEqual(@as(usize, 2000), peakAt(gain.channels[0]));
    try testing.expectEqual(control.channels[0].len, gain.channels[0].len);
}

test "delay compensation aligns latent tracks" {
    // The Rust test pans one latent track left and one plain track right and compares the
    // peaks of L and R. This rig has no pan: the two tracks are summed into one main mix,
    // so alignment shows as a single impulse of double height instead of two.
    var imp: [48_000]f32 = @splat(0);
    imp[1000] = 1.0;
    const rig = try Rig.create(testing.allocator, 2, max_test_block);
    defer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, &imp, lookahead_5ms);
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, &imp, 0);
    try rig.rebuild(true);
    try testing.expect(rig.plan.latency > 0); // test needs a latent plugin

    const out = try renderRange(rig, 0, 8000, 512, null);
    defer out.deinit();
    try expectImpulses(out.channels[0], &.{1000});
    try testing.expectEqual(@as(f32, 2.0), out.channels[0][1000]);

    try rig.rebuild(false);
    const off = try renderRange(rig, 0, 8000, 512, null);
    defer off.deinit();
    try expectImpulses(off.channels[0], &.{ 1000, 1000 + lookahead_5ms });
}

// A reset (stop, locate) must not leave the previous position's audio in the alignment delay.
test "reset clears delay compensation history" {
    var dc: [4800]f32 = @splat(0.5);
    const rig = try Rig.create(testing.allocator, 2, max_test_block);
    defer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, &dc, 0);
    // A silent latent track: it only adds latency to the mix.
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, null, lookahead_5ms);
    try rig.rebuild(true);

    var store: [2][512]f32 = undefined;
    var out: [2][]f32 = .{ store[0][0..], store[1][0..] };
    for (0..9) |b| rig.renderBlock(@intCast(b * 512), 512, null, &out);
    try testing.expect(rig.plan.latency > 0 and out[1][500] > 0.3); // plays through the alignment delay

    rig.reset();
    rig.renderBlock(1_000_000, 512, null, &out);
    for (out) |ch| for (ch) |x| try testing.expectEqual(@as(f32, 0.0), x);
}

/// Aux fixture (delay_compensation_aligns_an_aux_insert): impulses routed to bus A, an aux
/// that reads bus A and returns to the main mix. Latencies go on the source and on the aux.
fn auxMainScene(gpa: std.mem.Allocator, signal: []const f32, source_latency: usize, aux_latency: usize) !*Rig {
    const rig = try Rig.create(gpa, 2, max_test_block);
    errdefer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .{ .bus = bus_a } }, signal, source_latency);
    _ = try rig.addNode(.{ .kind = .aux, .input = .{ .bus = bus_a }, .output = .main }, null, aux_latency);
    try rig.rebuild(true);
    return rig;
}

test "delay compensation aligns an aux insert" {
    const signal = impulseSignal();
    const control_rig = try auxMainScene(testing.allocator, &signal, 0, 0);
    defer control_rig.destroy();
    const control = try renderRange(control_rig, 0, 8192, 1024, null);
    defer control.deinit();
    try expectImpulses(control.channels[0], &impulse_positions);
    try expectImpulses(control.channels[1], &impulse_positions);

    // A compressor with lookahead on the source: the path is delayed, the mix still lines up.
    const on_source_rig = try auxMainScene(testing.allocator, &signal, lookahead_5ms, 0);
    defer on_source_rig.destroy();
    const on_source = try renderRange(on_source_rig, 0, 8192, 1024, null);
    defer on_source.deinit();
    try expectImpulses(on_source.channels[0], &impulse_positions);

    // The same compressor on the aux: its lookahead stays inside the bounce.
    const on_aux_rig = try auxMainScene(testing.allocator, &signal, 0, lookahead_5ms);
    defer on_aux_rig.destroy();
    const on_aux = try renderRange(on_aux_rig, 0, 8192, 1024, null);
    defer on_aux.deinit();
    try expectImpulses(on_aux.channels[0], &impulse_positions);
    try expectImpulses(on_aux.channels[1], &impulse_positions);
    try testing.expect(@abs(on_aux.channels[0][8000] - 0.25) < 1e-3);

    const partial = try renderRange(on_aux_rig, 2048, 3072, 1024, null);
    defer partial.deinit();
    try expectImpulses(partial.channels[0], &.{0});

    // A lookahead of zero: nothing to compensate, the same as the control.
    on_aux_rig.setInsert(1, 0);
    try on_aux_rig.rebuild(true);
    const zero = try renderRange(on_aux_rig, 0, 8192, 1024, null);
    defer zero.deinit();
    try expectImpulses(zero.channels[0], &impulse_positions);
}

test "offline renders line up with the timeline in any block size" {
    var imp: [48_000]f32 = @splat(0);
    imp[1000] = 1.0;
    const rig = try Rig.create(testing.allocator, 2, max_test_block);
    defer rig.destroy();
    const t = try rig.addNode(.{ .kind = .track, .output = .main }, &imp, lookahead_5ms);
    try rig.setSendTo(t, bus_a);
    try rig.rebuild(true);
    const latency = rig.plan.latency;
    try testing.expect(latency > 16);

    for ([_]?BusId{ null, bus_a }) |source| {
        for ([_]usize{ 16, 100, 512 }) |block| {
            const r = try renderRange(rig, 900, 2900, block, source);
            defer r.deinit();
            try testing.expectEqual(@as(usize, 2000), r.channels[0].len);
            try testing.expectEqual(latency / block, r.skipped);
            try testing.expectEqual(@as(usize, 100), peakAt(r.channels[0]));
        }
    }
}

// Renders the same session at four block sizes and checks the outputs are bit-identical.
test "renders are identical at block sizes 16, 63, 128 and 512" {
    var signal: [8192]f32 = @splat(0);
    for (impulse_positions) |at| signal[at] = 0.25;
    const rig = try Rig.create(testing.allocator, 2, max_test_block);
    defer rig.destroy();
    _ = try rig.addNode(.{ .kind = .track, .output = .{ .bus = bus_a } }, &signal, 37);
    _ = try rig.addNode(.{ .kind = .aux, .input = .{ .bus = bus_a }, .output = .main }, null, lookahead_5ms);
    _ = try rig.addNode(.{ .kind = .track, .output = .main }, &signal, 100);
    _ = try rig.addNode(.{ .kind = .master }, null, 16);
    try rig.rebuild(true);

    const reference = try renderRange(rig, 0, 8192, 512, null);
    defer reference.deinit();
    for ([_]usize{ 16, 63, 128 }) |block| {
        const r = try renderRange(rig, 0, 8192, block, null);
        defer r.deinit();
        for (0..2) |c| try testing.expectEqualSlices(f32, reference.channels[c], r.channels[c]);
    }
}

test "a plugin's bogus latency is capped" {
    var dc: [48_000]f32 = @splat(0.5);
    const rig = try Rig.create(testing.allocator, 2, max_test_block);
    defer rig.destroy();
    const t = try rig.addNode(.{ .kind = .track, .output = .main }, &dc, 0);
    rig.setReported(t, std.math.maxInt(u32));
    const aux = try rig.addNode(.{ .kind = .aux, .output = .main }, null, 0);
    rig.setReported(aux, std.math.maxInt(u32));
    try rig.rebuild(true);

    var store: [2][512]f32 = undefined;
    var out: [2][]f32 = .{ store[0][0..], store[1][0..] };
    rig.renderBlock(0, 512, null, &out);
    try testing.expectEqual(MAX_LATENCY, rig.plan.track_latency);
    try testing.expectEqual(2 * MAX_LATENCY, rig.plan.latency);
}

test "processing a block with PDC allocates nothing" {
    // The render path takes no allocator: everything it touches was sized by `create`
    // and `rebuild`. The counting allocator wraps the control-thread calls and must see no
    // allocation between the first and the last audio block.
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = counting.allocator();
    const signal = impulseSignal();
    const rig = try busScene(gpa, &signal, lookahead_5ms, false);
    defer rig.destroy();

    var store: [2][512]f32 = undefined;
    var out: [2][]f32 = .{ store[0][0..], store[1][0..] };
    const allocs_before = counting.allocations;
    const frees_before = counting.deallocations;
    for (0..32) |b| rig.renderBlock(@intCast(b * 512), 512, bus_b, &out);
    rig.reset();
    rig.renderBlock(0, 512, null, &out);
    try testing.expectEqual(allocs_before, counting.allocations);
    try testing.expectEqual(frees_before, counting.deallocations);
}

test "computePlan: latency sums, aux feeding and the disabled switch" {
    var topo = Topology.init();
    _ = try topo.addNode(.{ .kind = .track, .output = .main });
    _ = try topo.addNode(.{ .kind = .track, .output = .{ .bus = bus_b } });
    _ = try topo.addNode(.{ .kind = .aux, .input = .{ .bus = bus_b }, .output = .{ .bus = bus_a } });
    _ = try topo.addNode(.{ .kind = .master });
    const lat = [_]NodeLatency{
        .{ .inserts = 100 },
        .{ .inserts = 0, .instrument = 20 },
        .{ .inserts = 50 },
        .{ .inserts = 7 },
    };
    var plan: PdcPlan = .{};
    computePlan(&plan, &topo, &lat, true);
    try testing.expectEqual(@as(usize, 100), plan.track_latency);
    try testing.expectEqual(@as(usize, 50), plan.aux_latency);
    try testing.expectEqual(@as(usize, 100 + 50 + 7), plan.latency);
    try testing.expect(plan.aux_fed[bus_a]);
    try testing.expect(!plan.aux_fed[bus_b]);
    try testing.expectEqual(@as(usize, 0), plan.nodes[0].align_post);
    try testing.expectEqual(@as(usize, 80), plan.nodes[1].align_post);
    try testing.expectEqual(@as(usize, 0), plan.nodes[2].align_post);
    // The aux feeds bus A, so the main-routed track waits for the aux return.
    try testing.expectEqual(@as(usize, 50), plan.nodes[0].out_extra);
    try testing.expectEqual(@as(usize, 0), plan.nodes[1].out_extra);
    try testing.expectEqual(@as(usize, 150), plan.busLatency(bus_a));
    try testing.expectEqual(@as(usize, 100), plan.busLatency(bus_b));

    computePlan(&plan, &topo, &lat, false);
    try testing.expectEqual(@as(usize, 0), plan.latency);
    try testing.expectEqual(@as(usize, 0), plan.nodes[0].out_extra);
    try testing.expectEqual(@as(usize, 100), plan.nodes[0].latency);
}

test "computePlan: a bus id outside the table is ignored, not an out-of-bounds write" {
    var topo = Topology.init();
    _ = try topo.addNode(.{ .kind = .track, .output = .{ .bus = max_buses } });
    _ = try topo.addNode(.{ .kind = .aux, .output = .{ .bus = max_buses + 3 } });
    const lat = [_]NodeLatency{ .{ .inserts = 10 }, .{ .inserts = 30 } };
    var plan: PdcPlan = .{};
    computePlan(&plan, &topo, &lat, true);
    for (plan.aux_fed) |fed| try testing.expect(!fed);
    try testing.expectEqual(@as(usize, 0), plan.nodes[0].out_extra);
    try testing.expectEqual(@as(usize, 40), plan.latency);
    try testing.expectEqual(@as(usize, 10), plan.track_latency);
}

test "a fresh PdcPlan holds no delay" {
    const plan: PdcPlan = .{};
    try testing.expectEqual(@as(usize, 0), plan.largestDelay());
    try testing.expectEqual(@as(usize, 0), plan.busLatency(3));
}

test "pdc caps through failure.capLatency" {
    try testing.expectEqual(MAX_LATENCY, capLatency(std.math.maxInt(usize)));
}
