//! sequencer (layer L3): Transport, tempo map, clips, clip launcher, step sequencer, MIDI scheduling, recording. Depends on core, analysis, io.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "sequencer";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const time = @import("time/time.zig");

pub const format = @import("time/format.zig");

pub const grid = @import("time/grid.zig");

pub const midi = @import("midi/midi.zig");

pub const ops = @import("midi/ops.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("sequencer", lib_name);
}
