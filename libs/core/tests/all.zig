//! External tests for core: use the library only through its public API,
//! imported by name like any consumer. Add `_ = @import("<file>.zig");`
//! for each test file placed in this directory.

const std = @import("std");
const lib = @import("core");

// --- test files: add one line per file ---

test "public API is reachable" {
    try std.testing.expectEqualStrings("core", lib.lib_name);
}
