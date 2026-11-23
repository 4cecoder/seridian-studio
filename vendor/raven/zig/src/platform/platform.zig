// Translated to Zig from vendor/raven/src/platform/platform.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/platform.c
// Selection of the window system compiled into the library.

const config = @import("raven_config");
const platform_h = @import("platform_h.zig");

export fn rvn_platform_select(headless: c_int) [*c]const platform_h.rvn_platform_t {
    if (headless != 0) return platform_h.rvn_platform_null();
    if (config.platform_win32) {
        return platform_h.rvn_platform_win32();
    } else if (config.platform_x11) {
        return platform_h.rvn_platform_x11();
    } else if (config.platform_cocoa) {
        return platform_h.rvn_platform_cocoa();
    } else {
        // no window system for this OS yet: the library still works headless
        return platform_h.rvn_platform_null();
    }
}
