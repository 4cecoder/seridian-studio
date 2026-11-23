// Translated to Zig from soundcraft/crates/mix/src/routing.rs, soundcraft/crates/mix/tests/it/aux_routing_order.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Aux and folder processing order over a fixed-capacity `Topology`.
//!
//! The Rust original returns `Vec<usize>` from a `Session`. Here `processingOrder`
//! writes into a caller-provided `[]NodeId` and returns the used length. Every
//! scratch array is a stack array sized by the `topology.zig` capacities, so the
//! functions do not allocate. They are meant for the graph-rebuild path only: the
//! audio thread consumes the precomputed order and never calls them.
//!
//! Test coverage: the two inline Rust tests are ported as-is. The integration
//! tests in `aux_routing_order.rs` are ported as order-only assertions over
//! `Topology` fixtures. Their PCM assertions need the render engine and are kept as
//! `SkipZigTest` entries for graph-4 to re-enable.

const std = @import("std");
const topology = @import("topology.zig");

const Topology = topology.Topology;
const Node = topology.Node;
const Kind = topology.Kind;
const Route = topology.Route;
const Send = topology.Send;
const NodeId = topology.NodeId;
const BusId = topology.BusId;
const max_nodes = topology.max_nodes;
const max_buses = topology.max_buses;
const max_sends = topology.max_sends;
const isAuxLike = topology.isAuxLike;
const outputBus = topology.outputBus;
const routeEql = topology.routeEql;

/// Sentinel for "no node" in per-bus bookkeeping. Fits `NodeId` because `max_nodes <= 65535`.
const none_node: NodeId = @intCast(max_nodes);

/// Longest aux-hop depth the legacy whole-graph fallback counts before it stops.
const legacy_hop_cap = 8;

pub const OrderError = error{
    /// `out` cannot hold every node.
    OutputTooSmall,
} || topology.RouteError;

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

fn fnvByte(h: u64, byte: u8) u64 {
    return (h ^ byte) *% fnv_prime;
}

fn fnvU16(h: u64, v: u16) u64 {
    return fnvByte(fnvByte(h, @truncate(v)), @truncate(v >> 8));
}

fn fnvRoute(h: u64, route: Route) u64 {
    return switch (route) {
        .none => fnvByte(h, 0),
        .main => fnvByte(h, 1),
        .bus => |bus| fnvU16(fnvByte(h, 2), bus),
    };
}

/// Hash of the routing structure that `processingOrder` depends on: node ids, kinds,
/// input and output routes, and the present send targets in slot order.
///
/// Like the Rust, this hashes sends with `flatten()` semantics (empty slots are
/// skipped), so moving a send between empty-free slots keeps the hash. It does not
/// hash solo, mute or levels, which do not change order. Rust also hashes track
/// formats, insert plugins and bus formats; `Topology` does not carry those.
pub fn structureFingerprint(topo: *const Topology) usize {
    var h: u64 = fnv_offset;
    h = fnvU16(h, @intCast(topo.len));
    for (topo.items()) |node| {
        h = fnvU16(h, node.id);
        h = fnvByte(h, @backingInt(node.kind));
        h = fnvRoute(h, node.input);
        h = fnvRoute(h, node.output);
        for (node.sends) |maybe| {
            if (maybe) |send| h = fnvRoute(fnvByte(h, 1), send.target);
        }
        h = fnvByte(h, 0xff); // node boundary
    }
    return @truncate(h);
}

/// Bus read by a node's input, if it reads a bus.
fn inputBus(node: *const Node) ?BusId {
    return switch (node.input) {
        .bus => |bus| bus,
        .none, .main => null,
    };
}

/// Ordering key comparator: lower depth first, ties keep node-index (session) order.
const SortKeys = struct {
    keys: *const [max_nodes]u16,

    fn lessThan(ctx: SortKeys, a: NodeId, b: NodeId) bool {
        const ka = ctx.keys[a];
        const kb = ctx.keys[b];
        return ka < kb or (ka == kb and a < b);
    }
};

/// Audio/instrument tracks first (index order), then auxes ordered so bus producers
/// come before consumers. Writes the order into `out` and returns its length.
///
/// Acyclic graphs use exact longest-path depths. Any cycle switches the whole graph to
/// the bounded legacy depth (see `boundedAuxDepth`). Ties keep node-index order.
pub fn processingOrder(topo: *const Topology, out: []NodeId) OrderError!usize {
    try topo.validate();
    if (out.len < topo.len) return error.OutputTooSmall;

    const nodes = topo.items();
    var n: usize = 0;
    var auxes: [max_nodes]NodeId = undefined;
    var aux_len: usize = 0;
    for (nodes, 0..) |node, i| {
        const id: NodeId = @intCast(i);
        if (isAuxLike(node.kind)) {
            auxes[aux_len] = id;
            aux_len += 1;
        } else {
            out[n] = id;
            n += 1;
        }
    }

    var keys: [max_nodes]u16 = @splat(0);
    if (!acyclicAuxDepths(topo, &keys)) {
        // A cycle keeps the bounded ordering for the entire graph, including any
        // independent acyclic branches. Feedback has no finite longest-path depth.
        for (auxes[0..aux_len]) |id| keys[id] = boundedAuxDepth(topo, id);
    }
    std.mem.sort(NodeId, auxes[0..aux_len], SortKeys{ .keys = &keys }, SortKeys.lessThan);
    std.mem.copyForwards(NodeId, out[n .. n + aux_len], auxes[0..aux_len]);
    return n + aux_len;
}

/// Exact aux-hop depths when the whole Aux/Folder graph is acyclic. Writes each aux's
/// depth into `depths` (indexed by node id) and returns true. Returns false on a cycle,
/// leaving `depths` partially written.
///
/// Per bus: a count of distinct producers and the longest producer depth. A producer is
/// counted once per bus, even when several of its routes name the same bus. A bus
/// completes when all its producers are processed, and then its consumers become ready.
pub fn acyclicAuxDepths(topo: *const Topology, depths: *[max_nodes]u16) bool {
    const nodes = topo.items();
    var remaining: [max_buses]u16 = @splat(0);
    var bus_depth: [max_buses]u16 = @splat(0);
    var last_producer: [max_buses]NodeId = @splat(none_node);
    var last_processed: [max_buses]NodeId = @splat(none_node);
    var ready: [max_nodes]NodeId = undefined;
    var ready_len: usize = 0;
    var aux_count: usize = 0;

    depths.* = @splat(0);

    // Producer counts. Output and send routes both create a dependency.
    for (nodes, 0..) |*node, i| {
        if (!isAuxLike(node.kind)) continue;
        aux_count += 1;
        const id: NodeId = @intCast(i);
        var k: usize = 0;
        while (k <= max_sends) : (k += 1) {
            const bus = outputBus(node, k) orelse continue;
            if (last_producer[bus] != id) {
                last_producer[bus] = id;
                remaining[bus] += 1;
            }
        }
    }

    // Auxes with no pending input bus start ready. Consumers of busses still waiting
    // on producers are released when their bus completes.
    for (nodes, 0..) |*node, i| {
        if (!isAuxLike(node.kind)) continue;
        if (inputBus(node)) |bus| {
            if (remaining[bus] > 0) continue;
        }
        ready[ready_len] = @intCast(i);
        ready_len += 1;
    }

    var processed: usize = 0;
    while (processed < ready_len) : (processed += 1) {
        const id = ready[processed];
        const next_depth = depths[id] + 1;
        var k: usize = 0;
        while (k <= max_sends) : (k += 1) {
            const bus = outputBus(&nodes[id], k) orelse continue;
            if (last_processed[bus] == id) continue;
            last_processed[bus] = id;
            bus_depth[bus] = @max(bus_depth[bus], next_depth);
            if (remaining[bus] == 0) return false;
            remaining[bus] -= 1;
            if (remaining[bus] == 0) {
                // Release every aux that reads this bus, in node-index order.
                for (nodes, 0..) |*consumer, j| {
                    if (!isAuxLike(consumer.kind)) continue;
                    const read = inputBus(consumer) orelse continue;
                    if (read != bus) continue;
                    depths[j] = bus_depth[bus];
                    ready[ready_len] = @intCast(j);
                    ready_len += 1;
                }
            }
        }
    }
    return processed == aux_count;
}

/// Auxes that write one of `inputs` (a bus route), in node-index order, written to
/// `out`. Returns the count. `out` must hold `topo.len` entries.
pub fn auxesFeeding(topo: *const Topology, inputs: []const Route, out: []NodeId) usize {
    var reads: [max_buses]bool = @splat(false);
    for (inputs) |route| {
        switch (route) {
            .bus => |bus| reads[bus] = true,
            .none, .main => {},
        }
    }
    var n: usize = 0;
    for (topo.items(), 0..) |*node, i| {
        if (!isAuxLike(node.kind)) continue;
        var k: usize = 0;
        var feeds = false;
        while (k <= max_sends) : (k += 1) {
            if (outputBus(node, k)) |bus| {
                if (reads[bus]) feeds = true;
            }
        }
        if (feeds) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}

/// The previous bounded depth calculation, kept unchanged for cyclic graphs: walk
/// upstream through feeding auxes for at most `legacy_hop_cap` hops and count the hops.
pub fn boundedAuxDepth(topo: *const Topology, start: NodeId) u16 {
    const nodes = topo.items();
    var cur: [max_nodes]NodeId = undefined;
    var cur_len: usize = 1;
    cur[0] = start;
    var d: u16 = 0;
    var hop: usize = 0;
    while (hop < legacy_hop_cap) : (hop += 1) {
        var inputs: [max_nodes]Route = undefined;
        for (cur[0..cur_len], 0..) |id, k| inputs[k] = nodes[id].input;
        const found = auxesFeeding(topo, inputs[0..cur_len], &cur);
        if (found == 0) break;
        d += 1;
        cur_len = found;
    }
    return d;
}

/// Implicit solo: an aux is not muted when a soloed node feeds its input bus.
pub fn receivesSolo(topo: *const Topology, index: NodeId) bool {
    const nodes = topo.items();
    const bus = inputBus(&nodes[index]) orelse return false;
    const target: Route = .{ .bus = bus };
    for (nodes) |*other| {
        if (!other.solo) continue;
        if (routeEql(other.output, target)) return true;
        for (other.sends) |maybe| {
            if (maybe) |send| {
                if (routeEql(send.target, target)) return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn orderOf(topo: *const Topology, buf: []NodeId) ![]const NodeId {
    const n = try processingOrder(topo, buf);
    return buf[0..n];
}

fn expectOrder(expected: []const NodeId, topo: *const Topology) !void {
    var buf: [max_nodes]NodeId = undefined;
    const got = try orderOf(topo, &buf);
    try std.testing.expectEqualSlices(NodeId, expected, got);
}

/// Order-only check for acyclic graphs. Every node appears once, and every aux that
/// writes a bus is placed before each aux that reads it.
fn expectDependenciesRespected(topo: *const Topology, order: []const NodeId) !void {
    const nodes = topo.items();
    try std.testing.expectEqual(nodes.len, order.len);
    var pos: [max_nodes]usize = undefined;
    var seen: [max_nodes]bool = @splat(false);
    for (order, 0..) |id, p| {
        try std.testing.expect(!seen[id]);
        seen[id] = true;
        pos[id] = p;
    }
    for (nodes, 0..) |*consumer, c| {
        if (!isAuxLike(consumer.kind)) continue;
        const bus = inputBus(consumer) orelse continue;
        for (nodes, 0..) |*producer, p| {
            if (!isAuxLike(producer.kind)) continue;
            var writes = false;
            var k: usize = 0;
            while (k <= max_sends) : (k += 1) {
                if (outputBus(producer, k)) |written| {
                    if (written == bus) writes = true;
                }
            }
            if (writes) try std.testing.expect(pos[p] < pos[c]);
        }
    }
}

fn sendTo(bus: BusId) Send {
    return .{ .target = .{ .bus = bus }, .level_db = 0.0 };
}

fn addAux(topo: *Topology, kind: Kind, input: BusId, output: Route) !NodeId {
    return topo.addNode(.{ .kind = kind, .input = .{ .bus = input }, .output = output });
}

fn addSource(topo: *Topology, output: Route) !NodeId {
    return topo.addNode(.{ .kind = .track, .output = output });
}

/// Stage `s` reads bus `s` and writes bus `s + 1` (or Main for the last stage).
/// Created in reverse, so stage `s` lands at node `depth - 1 - s`.
const depth = 12;

fn busFor(stage: usize) BusId {
    return @intCast(stage);
}

const Chain = struct {
    topo: Topology,
    stage_node: [depth]NodeId,
};

/// Port of `reverse_chain` from aux_routing_order.rs, without the PDC flag (PDC only
/// changes audio, not order). The source track is appended last, as in the Rust.
fn reverseChain(send_links: bool, folders: bool) !Chain {
    var chain: Chain = .{ .topo = Topology.init(), .stage_node = undefined };
    var stage: usize = depth;
    while (stage > 0) {
        stage -= 1;
        const kind: Kind = if (folders and stage % 3 == 1) .folder else .aux;
        const output: Route = if (stage + 1 == depth)
            .main
        else if (send_links)
            .none
        else
            .{ .bus = busFor(stage + 1) };
        const id = try addAux(&chain.topo, kind, busFor(stage), output);
        if (send_links and stage + 1 < depth) {
            try chain.topo.setSend(id, 0, sendTo(busFor(stage + 1)));
        }
        chain.stage_node[stage] = id;
    }
    _ = try addSource(&chain.topo, .{ .bus = busFor(0) });
    return chain;
}

// Inline test 1 of routing.rs.
test "acyclic bus joins use longest depth and keep session order for ties" {
    var topo = Topology.init();
    _ = try topo.addNode(.{ .kind = .track }); // 0: Audio
    _ = try topo.addNode(.{ .kind = .aux, .input = .{ .bus = 1 } }); // 1
    const first_root = try topo.addNode(.{ .kind = .aux }); // 2: output Main
    try topo.setSend(first_root, 0, sendTo(0));
    const second_root = try topo.addNode(.{ .kind = .aux, .output = .{ .bus = 1 } }); // 3
    try topo.setSend(second_root, 0, sendTo(1));
    try topo.setSend(second_root, 1, sendTo(1));
    const middle = try topo.addNode(.{ .kind = .folder, .input = .{ .bus = 0 }, .output = .{ .bus = 1 } }); // 4
    try topo.setSend(middle, 0, sendTo(1));

    try expectOrder(&.{ 0, 2, 3, 4, 1 }, &topo);
}

// Inline test 2 of routing.rs.
test "a cycle preserves bounded order for the whole graph" {
    var topo = Topology.init();
    for (0..10) |i| {
        const output: Route = if (i == 0) .main else .{ .bus = @intCast(i - 1) };
        _ = try addAux(&topo, .aux, @intCast(i), output);
    }
    try expectOrder(&.{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, &topo);

    // A self-feeding aux: input bus 10, output bus 10.
    _ = try addAux(&topo, .aux, 10, .{ .bus = 10 });

    // Both deepest independent returns tie with the cycle at the legacy eight-hop cap.
    try expectOrder(&.{ 9, 8, 7, 6, 5, 4, 3, 2, 0, 1, 10 }, &topo);
}

// aux_routing_order.rs: reverse_created_twelve_aux_chain_preserves_every_sample.
// The PCM half is in the render skip below. The order half is checked here.
test "reverse-created twelve aux chain orders producers before consumers" {
    const chain = try reverseChain(false, false);
    // Node 12 is the source track (non-aux, first); stage 0 (node 11) through
    // stage 11 (node 0) follow in depth order. Depths reach 11, past the legacy cap.
    try expectOrder(&.{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, &chain.topo);
}

test "deep dependencies through sends without outputs order producers first" {
    const chain = try reverseChain(true, false);
    try expectOrder(&.{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, &chain.topo);
}

test "output and send to the same bus count one producer dependency" {
    var chain = try reverseChain(false, false);
    // tracks[4] in the Rust is stage 4. It writes bus 5 by output and again by send.
    try chain.topo.setSend(chain.stage_node[4], 0, sendTo(5));
    var buf: [max_nodes]NodeId = undefined;
    const got = try orderOf(&chain.topo, &buf);
    try expectDependenciesRespected(&chain.topo, got);
    try std.testing.expectEqualSlices(NodeId, &.{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, got);
}

test "short and deep branches both reach the join" {
    var chain = try reverseChain(false, false);
    // Short branch: reads bus 0, writes bus 11 (the deep chain's last input).
    _ = try addAux(&chain.topo, .aux, busFor(0), .{ .bus = busFor(depth - 1) });
    var buf: [max_nodes]NodeId = undefined;
    const got = try orderOf(&chain.topo, &buf);
    try expectDependenciesRespected(&chain.topo, got);
    // Depth 0 ties: stage 0 (node 11) before the short branch (node 13), by index.
    try std.testing.expectEqualSlices(NodeId, &.{ 12, 11, 13, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, got);
}

test "routing folders participate in deep dependencies" {
    const chain = try reverseChain(true, true);
    try expectOrder(&.{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, &chain.topo);
}

test "output edit reorders the order before the next block" {
    var topo = Topology.init();
    const root: BusId = 0;
    const join: BusId = 1;
    _ = try addAux(&topo, .aux, join, .main); // 0: consumer of join
    const producer = try addAux(&topo, .aux, root, .main); // 1
    _ = try addSource(&topo, .{ .bus = root }); // 2
    try expectOrder(&.{ 2, 0, 1 }, &topo);

    topo.nodes[producer].output = .{ .bus = join };
    try expectOrder(&.{ 2, 1, 0 }, &topo);
}

test "input edit reorders the order before the next block" {
    var topo = Topology.init();
    const root: BusId = 0;
    const join: BusId = 1;
    const consumer = try addAux(&topo, .folder, root, .main); // 0
    _ = try addAux(&topo, .aux, root, .{ .bus = join }); // 1
    _ = try addSource(&topo, .{ .bus = root }); // 2
    try expectOrder(&.{ 2, 0, 1 }, &topo);

    topo.nodes[consumer].input = .{ .bus = join };
    try expectOrder(&.{ 2, 1, 0 }, &topo);
}

test "send add retarget remove and readd update the order" {
    var topo = Topology.init();
    const root: BusId = 0;
    const join: BusId = 1;
    const unused: BusId = 2;
    _ = try addAux(&topo, .aux, join, .main); // 0
    const producer = try topo.addNode(.{ .kind = .folder, .input = .{ .bus = root }, .output = .none }); // 1
    _ = try addSource(&topo, .{ .bus = root }); // 2
    try expectOrder(&.{ 2, 0, 1 }, &topo);

    try topo.setSend(producer, 0, sendTo(join));
    try expectOrder(&.{ 2, 1, 0 }, &topo);
    try topo.setSend(producer, 0, sendTo(unused));
    try expectOrder(&.{ 2, 0, 1 }, &topo);
    try topo.setSend(producer, 0, sendTo(join));
    try expectOrder(&.{ 2, 1, 0 }, &topo);
    try topo.setSend(producer, 0, null);
    try expectOrder(&.{ 2, 0, 1 }, &topo);
    try topo.setSend(producer, 0, sendTo(join));
    try expectOrder(&.{ 2, 1, 0 }, &topo);
}

test "track reorder removal and new identity rebuild the order" {
    var chain = try reverseChain(false, false);
    var buf: [max_nodes]NodeId = undefined;
    try expectOrder(&.{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, &chain.topo);

    chain.topo.reverseNodes();
    try expectDependenciesRespected(&chain.topo, try orderOf(&chain.topo, &buf));

    // Remove the stage-6 aux (the only node reading bus 6).
    var stage6: NodeId = 0;
    for (chain.topo.items(), 0..) |*node, i| {
        if (node.kind == .aux and inputBus(node) == busFor(6)) stage6 = @intCast(i);
    }
    chain.topo.removeNode(stage6);
    try expectDependenciesRespected(&chain.topo, try orderOf(&chain.topo, &buf));

    // Readd a stage-6 replacement at the end of the list.
    _ = try addAux(&chain.topo, .aux, busFor(6), .{ .bus = busFor(7) });
    try expectDependenciesRespected(&chain.topo, try orderOf(&chain.topo, &buf));
}

test "deep routing order is deterministic and respects dependencies" {
    const chain = try reverseChain(true, true);
    var first: [max_nodes]NodeId = undefined;
    var second: [max_nodes]NodeId = undefined;
    const a = try orderOf(&chain.topo, &first);
    const b = try orderOf(&chain.topo, &second);
    try std.testing.expectEqualSlices(NodeId, a, b);
    try expectDependenciesRespected(&chain.topo, a);
}

test "self loop selects the whole-graph fallback order" {
    var chain = try reverseChain(false, false);
    // Loop bus 12 (after the 12 chain buses). The aux reads and writes it.
    const loop_bus: BusId = 12;
    const aux = try addAux(&chain.topo, .aux, loop_bus, .main); // 13
    try chain.topo.setSend(aux, 0, sendTo(loop_bus));
    _ = try addSource(&chain.topo, .{ .bus = loop_bus }); // 14

    // Cyclic, so the bounded fallback applies. Stage s (node 11 - s) has bounded depth
    // min(s, 8). The self-loop aux (node 13) has depth 8. Depth-8 ties keep index order.
    try expectOrder(&.{ 12, 14, 11, 10, 9, 8, 7, 6, 5, 4, 0, 1, 2, 3, 13 }, &chain.topo);
}

test "two aux cycle preserves session order and the whole graph fallback" {
    // reverse == false: a (node 13) reads bus 12, b (node 14) reads bus 13.
    // reverse == true builds b before a, which swaps their node ids. Both depths are
    // the cap (8) either way, so the order is the same numeric sequence.
    inline for ([_]bool{ false, true }) |reverse| {
        var chain = try reverseChain(false, false);
        const a_bus: BusId = 12;
        const b_bus: BusId = 13;
        var a: NodeId = undefined;
        var b: NodeId = undefined;
        if (reverse) {
            b = try addAux(&chain.topo, .aux, b_bus, .main);
            a = try addAux(&chain.topo, .folder, a_bus, .main);
        } else {
            a = try addAux(&chain.topo, .folder, a_bus, .main);
            b = try addAux(&chain.topo, .aux, b_bus, .main);
        }
        try chain.topo.setSend(a, 0, sendTo(b_bus));
        try chain.topo.setSend(b, 0, sendTo(a_bus));
        _ = try addSource(&chain.topo, .{ .bus = a_bus });
        // Both cycle auxes and nodes 0..3 sit at the cap (8); ties keep index order.
        try expectOrder(&.{ 12, 15, 11, 10, 9, 8, 7, 6, 5, 4, 0, 1, 2, 3, 13, 14 }, &chain.topo);
    }
}

test "structure fingerprint tracks routing changes but not solo" {
    var topo = Topology.init();
    _ = try addAux(&topo, .aux, 0, .main);
    const before = structureFingerprint(&topo);
    try std.testing.expectEqual(before, structureFingerprint(&topo));

    topo.nodes[0].solo = true;
    try std.testing.expectEqual(before, structureFingerprint(&topo));

    topo.nodes[0].output = .{ .bus = 1 };
    try std.testing.expect(before != structureFingerprint(&topo));
}

test "receivesSolo is true only when a soloed node feeds the input bus" {
    var topo = Topology.init();
    const consumer = try addAux(&topo, .aux, 0, .main);
    const feeder = try topo.addNode(.{ .kind = .aux, .output = .{ .bus = 0 } });
    try std.testing.expect(!receivesSolo(&topo, consumer));
    topo.nodes[feeder].solo = true;
    try std.testing.expect(receivesSolo(&topo, consumer));
    try std.testing.expect(!receivesSolo(&topo, feeder));
}

// --- Render-dependent assertions. Re-enable in graph-4 (needs MixEngine, render_range
// and the SourceAudio pool). Each one is the PCM half of an aux_routing_order.rs test.

test "render: reverse-created twelve aux chain preserves every sample" {
    // Needs graph-4 render_range over the 12-stage chain at block sizes 1024.
    return error.SkipZigTest;
}

test "render: deep send-only chain preserves every sample" {
    // Needs graph-4 render_range at block size 97.
    return error.SkipZigTest;
}

test "render: output and send to the same bus sum audio without duplicate dependency" {
    // Needs graph-4 render_range: expects 2x signal at block size 256.
    return error.SkipZigTest;
}

test "render: short and deep branches both reach the join" {
    // Needs graph-4 render_range: expects 2x signal at block size 512.
    return error.SkipZigTest;
}

test "render: routing folders participate in deep dependencies" {
    // Needs graph-4 render_range at block size 63.
    return error.SkipZigTest;
}

test "render: output edit reorders the same engine before the next block" {
    // Needs graph-4 MixEngine (persistent engine, per-block render).
    return error.SkipZigTest;
}

test "render: input edit reorders the same engine before the next block" {
    // Needs graph-4 MixEngine (persistent engine, per-block render).
    return error.SkipZigTest;
}

test "render: send add retarget remove and readd update the same engine" {
    // Needs graph-4 MixEngine: silence/signal per block as sends change.
    return error.SkipZigTest;
}

test "render: track reorder removal and new identity rebuild the same engine" {
    // Needs graph-4 MixEngine and audio-level silence after track removal.
    return error.SkipZigTest;
}

test "render: strip and bus format edits refresh the same engine workspace" {
    // Topology has no strip or bus formats, and the mono fold and pan are render-side.
    // The order is format-independent, so there is no order-only assertion to keep.
    // Needs graph-4 format model and render workspace.
    return error.SkipZigTest;
}

test "render: deep routing is invariant to offline and callback block sizes" {
    // Needs graph-4 render_range and MixEngine across block sizes 16..1024.
    return error.SkipZigTest;
}

test "render: self loop preserves audio under the whole-graph fallback" {
    // Needs graph-4 render_range: expects the source signal at block size 97.
    return error.SkipZigTest;
}

test "render: two aux cycle preserves session order audio" {
    // Needs graph-4 render_range: expects 2x or 1x signal depending on order at block 256.
    return error.SkipZigTest;
}
