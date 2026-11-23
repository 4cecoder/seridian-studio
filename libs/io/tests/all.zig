//! External tests for io: use the library only through its public API,
//! imported by name like any consumer. Add `_ = @import("<file>.zig");`
//! for each test file placed in this directory.

const std = @import("std");
const lib = @import("io");

// --- test files: add one line per file ---

test "public API is reachable" {
    try std.testing.expectEqualStrings("io", lib.lib_name);
}
