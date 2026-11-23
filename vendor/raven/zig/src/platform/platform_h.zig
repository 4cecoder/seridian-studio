// Translated to Zig from vendor/raven/src/platform/platform.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/platform.h
// Windowing interface implemented once per window system.
//
//   platform/x11/     Xlib               (Linux, BSD)
//   platform/win32/   Win32              (Windows)
//   platform/cocoa/   Cocoa + Metal      (macOS)
//   platform/null/    no window at all   (headless runs, tests)
//
// To port Raven to another window system (for example Wayland), implement this
// table and return it from rvn_platform_select.
//
// Unless noted, sizes and positions are in pixels of the client area and all
// functions are called from the UI thread.
//
// The `#include "../core/base.h"` is `@import("../core/base_h.zig")`, not re-exported here.
// RAVEN_PLATFORM_* guards of the prototypes at the end are not needed: an unused `extern fn` is never linked.

const raven = @import("raven");

/// A native window. Each platform defines its own structure.
pub const rvn_pwindow_t = opaque {};
pub const struct_rvn_pwindow_t = rvn_pwindow_t;

pub const rvn_pevent_type_t = c_uint;
/// The user asked to close the window.
pub const RVN_PEVENT_CLOSE: c_int = 0;
/// The client area changed: width, height, scale.
pub const RVN_PEVENT_RESIZE: c_int = 1;
/// The content of the window must be redrawn.
pub const RVN_PEVENT_EXPOSE: c_int = 2;
pub const RVN_PEVENT_MOUSE_MOVE: c_int = 3;
pub const RVN_PEVENT_MOUSE_BUTTON: c_int = 4;
pub const RVN_PEVENT_MOUSE_WHEEL: c_int = 5;
pub const RVN_PEVENT_MOUSE_LEAVE: c_int = 6;
pub const RVN_PEVENT_KEY: c_int = 7;
/// A character was typed: codepoint.
pub const RVN_PEVENT_TEXT: c_int = 8;
pub const RVN_PEVENT_FOCUS: c_int = 9;
/// The platform is inside a modal loop (Win32 live resize): the core
/// should produce a frame now because the loop of the application is not running.
pub const RVN_PEVENT_MODAL_TICK: c_int = 10;
/// The window was maximized, minimized or restored: state.
pub const RVN_PEVENT_STATE: c_int = 11;
/// Something is being dragged over the window from another application:
/// x, y, and `leaving` when it left without being dropped. The core
/// answers through `accepted` whether a drop there would be taken.
pub const RVN_PEVENT_DRAG: c_int = 12;
/// Files or text were dropped: x, y, drop_paths / drop_count, drop_text.
pub const RVN_PEVENT_DROP: c_int = 13;

/// Parts of a window whose title bar is drawn by the application (R_WINDOW_CUSTOM_HEADER).
pub const rvn_pregion_t = c_uint;
pub const RVN_PREGION_CLIENT: c_int = 0;
/// Moves the window when dragged, maximizes it when double-clicked.
pub const RVN_PREGION_CAPTION: c_int = 1;
pub const RVN_PREGION_LEFT: c_int = 2;
pub const RVN_PREGION_RIGHT: c_int = 3;
pub const RVN_PREGION_TOP: c_int = 4;
pub const RVN_PREGION_BOTTOM: c_int = 5;
pub const RVN_PREGION_TOP_LEFT: c_int = 6;
pub const RVN_PREGION_TOP_RIGHT: c_int = 7;
pub const RVN_PREGION_BOTTOM_LEFT: c_int = 8;
pub const RVN_PREGION_BOTTOM_RIGHT: c_int = 9;

pub const rvn_pwindow_state_t = c_uint;
pub const RVN_PWINDOW_NORMAL: c_int = 0;
pub const RVN_PWINDOW_MINIMIZED: c_int = 1;
pub const RVN_PWINDOW_MAXIMIZED: c_int = 2;

pub const rvn_pevent_t = extern struct {
    type: rvn_pevent_type_t,
    /// User pointer given when the window was created.
    user: ?*anyopaque,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    scale: f32,
    wheel_x: f32,
    wheel_y: f32,
    button: c_int,
    pressed: c_int,
    key: raven.RKey,
    modifiers: u32,
    repeat: c_int,
    codepoint: u32,
    focused: c_int,
    state: rvn_pwindow_state_t,
    leaving: c_int,
    accepted: [*c]c_int,
    /// UTF-8 paths, valid during the call.
    drop_paths: [*c]const [*c]const u8,
    drop_count: c_int,
    /// Dropped text when it is not files, or NULL.
    drop_text: [*c]const u8,
};
pub const struct_rvn_pevent_t = rvn_pevent_t;

pub const rvn_pevent_handler_t = ?*const fn (event: [*c]const rvn_pevent_t) callconv(.c) void;
/// Asked by a window system that moves and resizes windows by itself (Win32):
/// what is at this pixel of a window with a custom header? `user` is the user
/// pointer of the window.
pub const rvn_pregion_handler_t = ?*const fn (user: ?*anyopaque, x: c_int, y: c_int) callconv(.c) rvn_pregion_t;

pub const rvn_pwindow_desc_t = extern struct {
    title: [*c]const u8,
    /// Client size in logical units: the platform multiplies by its scale.
    width: c_int,
    height: c_int,
    /// Bitmask of RWindowFlags.
    flags: u32,
    user: ?*anyopaque,
    /// Seridian: X11 WM_CLASS res_name / res_class (Rset_window_class); NULL = "raven".
    wm_name: [*c]const u8,
    wm_class: [*c]const u8,
};
pub const struct_rvn_pwindow_desc_t = rvn_pwindow_desc_t;

pub const rvn_platform_t = extern struct {
    name: [*c]const u8,
    system: raven.RWindowSystem,

    init: ?*const fn (handler: rvn_pevent_handler_t, regions: rvn_pregion_handler_t) callconv(.c) c_int,
    shutdown: ?*const fn () callconv(.c) void,
    /// Display connection handed to the rendering backend (X11 Display*), or NULL.
    native_display: ?*const fn () callconv(.c) ?*anyopaque,

    window_create: ?*const fn (desc: [*c]const rvn_pwindow_desc_t) callconv(.c) ?*rvn_pwindow_t,
    window_destroy: ?*const fn (window: ?*rvn_pwindow_t) callconv(.c) void,
    window_set_title: ?*const fn (window: ?*rvn_pwindow_t, title: [*c]const u8) callconv(.c) void,
    window_set_size: ?*const fn (window: ?*rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void,
    window_get_size: ?*const fn (window: ?*rvn_pwindow_t, width: [*c]c_int, height: [*c]c_int) callconv(.c) void,
    window_set_min_size: ?*const fn (window: ?*rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void,
    window_set_position: ?*const fn (window: ?*rvn_pwindow_t, x: c_int, y: c_int) callconv(.c) void,
    window_get_position: ?*const fn (window: ?*rvn_pwindow_t, x: [*c]c_int, y: [*c]c_int) callconv(.c) void,
    /// Pixels per logical unit on the monitor showing the window.
    window_get_scale: ?*const fn (window: ?*rvn_pwindow_t) callconv(.c) f32,
    window_show: ?*const fn (window: ?*rvn_pwindow_t, visible: c_int) callconv(.c) void,
    window_set_state: ?*const fn (window: ?*rvn_pwindow_t, state: rvn_pwindow_state_t) callconv(.c) void,
    window_get_state: ?*const fn (window: ?*rvn_pwindow_t) callconv(.c) rvn_pwindow_state_t,
    /// Windows with a custom header. The user pressed the left button on the
    /// caption or on an edge: the window follows the pointer until the button
    /// is released. The release is not reported to the core.
    window_begin_move: ?*const fn (window: ?*rvn_pwindow_t) callconv(.c) void,
    window_begin_resize: ?*const fn (window: ?*rvn_pwindow_t, edge: rvn_pregion_t) callconv(.c) void,
    /// R_TRUE when the window system asks for the regions itself and handles
    /// presses on them (Win32: dragging, snapping, the system menu). Otherwise
    /// the core watches the mouse and calls window_begin_move / _resize.
    native_regions: c_int,
    /// Optional (may be NULL). What the window system shows behind a window
    /// created with R_WINDOW_TRANSPARENT: a RBackdrop. `dark` tells which
    /// tint the materials of the OS take. Returns the RBackdrop it could give
    /// (R_BACKDROP_NONE when the window cannot be seen through at all).
    window_set_backdrop: ?*const fn (window: ?*rvn_pwindow_t, backdrop: c_int, dark: c_int) callconv(.c) c_int,
    /// Optional (may be NULL). Opacity of the whole window, 0..1. Returns R_FALSE when it cannot.
    window_set_opacity: ?*const fn (window: ?*rvn_pwindow_t, opacity: f32) callconv(.c) c_int,
    window_set_topmost: ?*const fn (window: ?*rvn_pwindow_t, topmost: c_int) callconv(.c) c_int,
    window_center: ?*const fn (window: ?*rvn_pwindow_t) callconv(.c) void,
    /// Optional (may be NULL). Icon from RGBA8 pixels; NULL rgba restores the default.
    window_set_icon: ?*const fn (window: ?*rvn_pwindow_t, rgba: [*c]const u8, width: c_int, height: c_int) callconv(.c) void,
    window_set_cursor: ?*const fn (window: ?*rvn_pwindow_t, cursor: raven.RCursor) callconv(.c) void,
    window_get_native: ?*const fn (window: ?*rvn_pwindow_t, native: [*c]raven.RNativeWindow) callconv(.c) void,

    /// Child window used by native viewports. Destroyed with window_destroy.
    child_create: ?*const fn (parent: ?*rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) ?*rvn_pwindow_t,
    child_set_rect: ?*const fn (child: ?*rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, visible: c_int) callconv(.c) void,

    /// Dispatches pending events to the handler.
    /// @param timeout_seconds 0 returns at once, negative waits without limit.
    pump: ?*const fn (timeout_seconds: f64) callconv(.c) void,
    /// Interrupts a waiting pump. Thread-safe.
    wake: ?*const fn () callconv(.c) void,

    clipboard_set: ?*const fn (text: [*c]const u8) callconv(.c) void,
    /// Returns a rvn_alloc'ed string, or NULL.
    clipboard_get: ?*const fn () callconv(.c) [*c]u8,

    /// Optional (may be NULL). Called repeatedly while the UI thread is blocked
    /// waiting for the render thread. A window system whose windows must keep
    /// answering requests coming from other threads (Win32: messages sent by
    /// the graphics driver while it creates or resizes a swapchain) answers
    /// them here, without dispatching anything to the core.
    wait_service: ?*const fn () callconv(.c) void,

    // ---- accessibility (optional, NULL when the platform has none; core/accessibility.h) ----

    /// Something changed in the tree a screen reader sees (rvn_a11y_event_t), at a node.
    a11y_event: ?*const fn (window: ?*rvn_pwindow_t, event: c_int, node: u64) callconv(.c) void,
    /// A message for the screen reader.
    a11y_announce: ?*const fn (window: ?*rvn_pwindow_t, text: [*c]const u8, assertive: c_int) callconv(.c) void,
    /// R_TRUE when a screen reader (or another assistive program) is listening.
    a11y_active: ?*const fn () callconv(.c) c_int,
    /// What the user asked the system for: text size, contrast, motion.
    a11y_settings: ?*const fn (settings: [*c]raven.RAccessibilitySettings) callconv(.c) void,
};
pub const struct_rvn_platform_t = rvn_platform_t;

/// Picks the platform compiled in for this OS, or the null platform.
pub extern fn rvn_platform_select(headless: c_int) [*c]const rvn_platform_t;

pub extern fn rvn_platform_null() [*c]const rvn_platform_t;
// #if defined(RAVEN_PLATFORM_X11)
pub extern fn rvn_platform_x11() [*c]const rvn_platform_t;
// #if defined(RAVEN_PLATFORM_WIN32)
pub extern fn rvn_platform_win32() [*c]const rvn_platform_t;
// #if defined(RAVEN_PLATFORM_COCOA)
pub extern fn rvn_platform_cocoa() [*c]const rvn_platform_t;
