//! analysis (layer L2): Audio analysis: key detection, tempo/beat, onsets, loudness, spectrum, waveform peaks. Depends on core.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "analysis";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const biquad = @import("biquad.zig");
pub const db = @import("db.zig");
pub const meter = @import("meter.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("analysis", lib_name);
}
