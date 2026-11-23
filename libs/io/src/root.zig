//! io (layer L3): Audio backends, MIDI input/output, controllers and latency queries. Depends on core and analysis.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "io";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const audiofile = @import("audiofile/codec.zig");
pub const audiofile_aiff = @import("audiofile/aiff.zig");
pub const audiofile_buffer = @import("audiofile/buffer.zig");
pub const audiofile_flac = @import("audiofile/flac.zig");
pub const audiofile_pcm = @import("audiofile/pcm.zig");
pub const audiofile_types = @import("audiofile/types.zig");
pub const audiofile_wav = @import("audiofile/wav.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("io", lib_name);
}
