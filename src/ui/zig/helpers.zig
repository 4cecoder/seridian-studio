//! The pure UI helpers (no Raven, no engine), gathered for the tests in tests/ui (as the module `ui_impl`) and for
//! the in-file tests of the pure Zig widget logic.

pub const palette = @import("palette.zig");
pub const ui_math = @import("ui_math.zig");
pub const knob_math = @import("knob_math.zig");
pub const piano_math = @import("piano_math.zig");
pub const input_dispatch = @import("input_dispatch.zig");
pub const ui_state = @import("ui_state.zig");

test {
    _ = palette;
    _ = ui_math;
    _ = knob_math;
    _ = piano_math;
    _ = input_dispatch;
    _ = ui_state;
    _ = @import("keymap.zig");
    _ = @import("dirty.zig");
    _ = @import("piano_edit.zig");
    _ = @import("fader_math.zig");
    _ = @import("meter_math.zig");
    _ = @import("waveform_math.zig");
    _ = @import("app/libc.zig");
    _ = @import("app/externs.zig");
    _ = @import("preflight_report.zig");
    _ = @import("idle_inhibit.zig");
    _ = @import("idle_inhibit_linux.zig");
    _ = @import("scroll_wrap.zig");
    _ = @import("track_names.zig");
}
