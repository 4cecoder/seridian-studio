//! graph (layer L3): Audio graph: routing, buses, sends, sidechain, latency compensation, scheduling, metering. Depends on core, analysis, io.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "graph";

// --- file re-exports: add one line per file, keep alphabetical ---
pub const delay_line = @import("delay_line.zig");
pub const failure = @import("failure.zig");
pub const pdc = @import("pdc.zig");
pub const processor = @import("processor.zig");
pub const routing = @import("routing.zig");
pub const slot = @import("slot.zig");
pub const topology = @import("topology.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("graph", lib_name);
}
