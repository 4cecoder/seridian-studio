//! Minimal routing-graph description consumed by `routing.zig`.
//!
//! SoundCraft's routing algorithms read a full `Session` (tracks with playlists,
//! plugins, pool audio). Seridian's graph only needs the routing skeleton, so this
//! file defines that skeleton as plain index-based data: no strings, no pointers,
//! no allocation. Fixed capacity: `max_nodes` nodes, each with `max_sends` send
//! slots (SoundCraft's `SEND_SLOTS`). Bus ids are indices below `max_buses`.
//!
//! Node ids are positions in the node array. `removeNode` shifts later nodes down,
//! so ids are only stable until the next structural edit; the graph rebuild path
//! recomputes everything from the current ids.
//!
//! Hand-written for Seridian (no SoundCraft file is translated here); the algorithm
//! that consumes it is in `routing.zig`.

const std = @import("std");

/// Maximum nodes (tracks, auxes, folders and masters) in one topology.
pub const max_nodes: usize = 256;
/// Bus ids must be strictly below this. Equal to `max_nodes` so that `NodeId`
/// sentinels can reuse the same bound.
pub const max_buses: usize = 256;
/// Send slots per node (SoundCraft `SEND_SLOTS`).
pub const max_sends: usize = 10;

pub const NodeId = u16;
pub const BusId = u16;

pub const Kind = enum(u8) {
    /// Audio or instrument track. Always processed before any aux.
    track,
    /// Aux (bus return). Reads a bus, may write one or more busses.
    aux,
    /// Routing folder. Same routing role as an aux; kept distinct for fingerprinting.
    folder,
    /// Master strip. Does not participate in bus dependencies.
    master,
};

pub const Route = union(enum) {
    /// No destination (or no source).
    none,
    /// The main output.
    main,
    /// A bus by index.
    bus: BusId,
};

pub const Send = struct {
    target: Route,
    level_db: f32 = 0.0,
    pre_fader: bool = false,
};

pub const Node = struct {
    /// Index of this node in `Topology.nodes` at the time it was added.
    id: NodeId = 0,
    kind: Kind,
    input: Route = .none,
    output: Route = .main,
    sends: [max_sends]?Send = @splat(null),
    solo: bool = false,
    mute: bool = false,
};

/// A route names a bus id that is not below `max_buses`.
pub const RouteError = error{BusOutOfRange};

pub const TopologyError = error{
    /// `max_nodes` nodes already present.
    TopologyFull,
    /// Send slot index is not below `max_sends`.
    SlotOutOfRange,
};

pub const Topology = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,

    pub fn init() Topology {
        return .{};
    }

    /// Appends a node and returns its id. The stored `id` is set to that index.
    pub fn addNode(self: *Topology, node: Node) TopologyError!NodeId {
        if (self.len >= max_nodes) return error.TopologyFull;
        const id: NodeId = @intCast(self.len);
        var stored = node;
        stored.id = id;
        self.nodes[self.len] = stored;
        self.len += 1;
        return id;
    }

    /// Sets (or clears, with `null`) one send slot of a node, like `sends[slot] = ...`.
    pub fn setSend(self: *Topology, id: NodeId, slot: usize, send: ?Send) TopologyError!void {
        if (slot >= max_sends) return error.SlotOutOfRange;
        std.debug.assert(id < self.len);
        self.nodes[id].sends[slot] = send;
    }

    /// Removes a node, shifting later nodes down by one (ordered, like `Vec::remove`).
    /// Later ids change; their stored `id` fields are rewritten to match.
    pub fn removeNode(self: *Topology, id: NodeId) void {
        const index: usize = id;
        std.debug.assert(index < self.len);
        std.mem.copyForwards(Node, self.nodes[index .. self.len - 1], self.nodes[index + 1 .. self.len]);
        self.len -= 1;
        for (self.nodes[index..self.len], index..) |*node, i| node.id = @intCast(i);
    }

    /// Live nodes, in order.
    pub fn items(self: *const Topology) []const Node {
        return self.nodes[0..self.len];
    }

    /// Reverses node order (a track reorder) and rewrites the stored ids.
    pub fn reverseNodes(self: *Topology) void {
        std.mem.reverse(Node, self.nodes[0..self.len]);
        for (self.nodes[0..self.len], 0..) |*node, i| node.id = @intCast(i);
    }

    /// Checks that every route names a bus below `max_buses`.
    pub fn validate(self: *const Topology) RouteError!void {
        for (self.items()) |node| {
            try checkRoute(node.input);
            try checkRoute(node.output);
            for (node.sends) |maybe| {
                if (maybe) |send| try checkRoute(send.target);
            }
        }
    }
};

fn checkRoute(route: Route) RouteError!void {
    switch (route) {
        .bus => |bus| if (bus >= max_buses) return error.BusOutOfRange,
        .none, .main => {},
    }
}

/// Route equality, the `==` of SoundCraft's `Route`.
pub fn routeEql(a: Route, b: Route) bool {
    return switch (a) {
        .none => b == .none,
        .main => b == .main,
        .bus => |ab| switch (b) {
            .bus => |bb| ab == bb,
            else => false,
        },
    };
}

/// Aux-like means the strip participates in bus dependencies (`Aux` or `Folder`).
pub fn isAuxLike(kind: Kind) bool {
    return kind == .aux or kind == .folder;
}

/// Bus that output slot `k` writes to: `k == 0` is the output route, `k > 0` is
/// send slot `k - 1`. Returns null when that slot is not a bus route.
pub fn outputBus(node: *const Node, k: usize) ?BusId {
    const route: Route = if (k == 0) node.output else blk: {
        const send = node.sends[k - 1] orelse return null;
        break :blk send.target;
    };
    return switch (route) {
        .bus => |bus| bus,
        else => null,
    };
}

test "addNode assigns index ids and rejects overflow" {
    var topo = Topology.init();
    const a = try topo.addNode(.{ .kind = .track });
    const b = try topo.addNode(.{ .kind = .aux });
    try std.testing.expectEqual(@as(NodeId, 0), a);
    try std.testing.expectEqual(@as(NodeId, 1), b);
    try std.testing.expectEqual(@as(NodeId, 1), topo.nodes[1].id);
    topo.len = max_nodes;
    try std.testing.expectError(error.TopologyFull, topo.addNode(.{ .kind = .aux }));
}

test "setSend bounds the slot index" {
    var topo = Topology.init();
    const a = try topo.addNode(.{ .kind = .aux });
    try topo.setSend(a, max_sends - 1, .{ .target = .{ .bus = 3 } });
    try std.testing.expectError(error.SlotOutOfRange, topo.setSend(a, max_sends, null));
    try std.testing.expect(topo.nodes[a].sends[max_sends - 1] != null);
}

test "validate rejects bus ids outside the table" {
    var topo = Topology.init();
    _ = try topo.addNode(.{ .kind = .aux, .output = .{ .bus = max_buses } });
    try std.testing.expectError(error.BusOutOfRange, topo.validate());
}

test "removeNode shifts later nodes and rewrites their ids" {
    var topo = Topology.init();
    _ = try topo.addNode(.{ .kind = .track });
    _ = try topo.addNode(.{ .kind = .aux });
    _ = try topo.addNode(.{ .kind = .folder });
    topo.removeNode(1);
    try std.testing.expectEqual(@as(usize, 2), topo.len);
    try std.testing.expectEqual(Kind.folder, topo.nodes[1].kind);
    try std.testing.expectEqual(@as(NodeId, 1), topo.nodes[1].id);
}
