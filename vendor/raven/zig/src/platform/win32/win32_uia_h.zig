// Translated to Zig from vendor/raven/src/platform/win32/win32_uia.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/win32/win32_uia.h
// UI Automation for the screen readers of Windows (win32_uia.c).
//
// <windows.h> is not available: the handful of Win32 scalar types of these prototypes are declared here
// (HWND is a pointer to an opaque struct, WPARAM / LPARAM / LRESULT are pointer-sized integers).

const raven = @import("raven");
const platform = @import("../platform_h.zig");

pub const HWND = ?*anyopaque;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const UINT = c_uint;

/// WM_GETOBJECT: R_TRUE with *result when the window answered with its provider. `user`: the window of Raven.
pub extern fn rvn_uia_get_object(hwnd: HWND, user: ?*anyopaque, wparam: WPARAM, lparam: LPARAM, result: [*c]LRESULT) c_int;
/// A call of a screen reader sent to the UI thread: R_TRUE when the message was one.
pub extern fn rvn_uia_handle_message(message: UINT, wparam: WPARAM, lparam: LPARAM) c_int;
pub extern fn rvn_uia_window_destroyed(hwnd: HWND) void;
pub extern fn rvn_uia_shutdown() void;

pub extern fn rvn_uia_event(hwnd: HWND, event: c_int, node: u64) void;
pub extern fn rvn_uia_announce(hwnd: HWND, user: ?*anyopaque, text: [*c]const u8, assertive: c_int) void;
pub extern fn rvn_uia_active() c_int;
pub extern fn rvn_uia_settings(settings: [*c]raven.RAccessibilitySettings) void;
