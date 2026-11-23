//! automation (layer L3): Automation lanes, modes, MIDI learn, macros. Depends on core, analysis, io.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "automation";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const eval = @import("eval.zig");
pub const lane = @import("lane.zig");
pub const modes = @import("modes.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("automation", lib_name);
}
