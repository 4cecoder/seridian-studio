//! Root of libdaw-ui: the Seridian Studio window over the Raven toolkit, all Zig.
//!
//! Exported C ABI (what the executable and the separately built Zig widgets link against):
//!   seridian_raven_run                     app/control.zig, called by src/main.zig
//!   seridian_window_input_install/add/dispatch   window_input.zig, called by the knob and piano roll libraries
//!   ui_state_format, ui_state_write_file   ui_state.zig
//! The knob, piano roll and keymap widgets are separate static libraries (build.zig) because they declare their own
//! Raven prototypes; the window reaches them through app/externs.zig.

const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .info,
};

comptime {
    _ = @import("app/control.zig");
    _ = @import("window_input.zig");
    _ = @import("ui_state.zig");
}
