//! session (layer L4): Wires engine, project and io together; owns the daw_runtime_* C ABI. Depends on every L0-L3 library listed here.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const command = @import("command.zig");
pub const command_params = @import("command_params.zig");
pub const control_side = @import("control_side.zig");
pub const executor = @import("executor.zig");

pub const lib_name = "session";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const output_guard = @import("output_guard.zig");
pub const plugin_instances = @import("plugin_instances.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("session", lib_name);
}
