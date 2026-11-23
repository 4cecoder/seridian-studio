//! mcp (layer L4): Agent (MCP) control surface over the session. Depends on every L0-L3 library listed here.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "mcp";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const file_access = @import("file_access.zig");
pub const backend = @import("backend.zig");
pub const control_target = @import("control_target.zig");
pub const remote = @import("remote.zig");
pub const roots_test = @import("roots_test.zig");
pub const server = @import("server.zig");
pub const server_test = @import("server_test.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("mcp", lib_name);
}
