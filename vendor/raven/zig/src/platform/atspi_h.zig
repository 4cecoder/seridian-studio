// Translated to Zig from vendor/raven/src/platform/atspi.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/atspi.h
// AT-SPI 2 for the screen readers of Linux (platform/atspi.c), used by the
// X11 platform (and by any Unix platform that wants it).

const raven = @import("raven");
const platform = @import("platform_h.zig");

/// Connects to the accessibility bus when assistive technologies are on. R_FALSE otherwise (nothing to do).
pub extern fn rvn_atspi_init() c_int;
pub extern fn rvn_atspi_shutdown() void;
/// The socket to wait on with the window system (-1 when not connected).
pub extern fn rvn_atspi_fd() c_int;
/// Answers the requests that came in.
pub extern fn rvn_atspi_dispatch() void;

// the accessibility entries of rvn_platform_t
pub extern fn rvn_atspi_event(window: ?*platform.rvn_pwindow_t, event: c_int, node: u64) void;
pub extern fn rvn_atspi_announce(window: ?*platform.rvn_pwindow_t, text: [*c]const u8, assertive: c_int) void;
pub extern fn rvn_atspi_active() c_int;
pub extern fn rvn_atspi_settings(settings: [*c]raven.RAccessibilitySettings) void;
