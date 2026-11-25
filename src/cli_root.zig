//! Module root for the `seridian` CLI.
//!
//! Zig only lets a module import files beneath its root file's directory. The
//! CLI lives in src/cli/, but it shares src/audio/device_parse.zig with the
//! engine, so the module root sits here in src/ and re-exports the CLI entry.

pub const main = @import("cli/main.zig").main;

comptime {
    _ = @import("cli/song.zig");
    _ = @import("cli/main.zig");
    _ = @import("control_limits");
}
