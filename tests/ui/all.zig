//! UI helper tests (palette, UI math, knob math, piano math, input dispatch, state snapshot). The implementation
//! under test is the module `ui_impl`, wired in build.zig.

test {
    _ = @import("palette_test.zig");
    _ = @import("ui_math_test.zig");
    _ = @import("knob_math_test.zig");
    _ = @import("piano_math_test.zig");
    _ = @import("input_dispatch_test.zig");
    _ = @import("ui_state_test.zig");
}
