//! core (layer L0): Real-time primitives: lock-free queues, atomics, parameter smoothing, units, counting allocator. Depends on nothing.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "core";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const atomic = @import("atomic.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const spsc = @import("spsc.zig");
pub const util = @import("util.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("core", lib_name);
}
