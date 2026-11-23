// Translated to Zig from vendor/raven/src/platform/null/null_platform.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/null/null_platform.c
// Window system that opens no window. Windows only exist as a size, which is
// all the layout needs: used for headless runs and unit tests, together with
// Rwindow_inject_... for input.

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const platform_h = @import("../platform_h.zig");
const ext = @import("../externs.zig");

// struct rvn_pwindow_t (the C struct behind the opaque rvn_pwindow_t of platform.h)
const NullWindow = extern struct {
    width: c_int,
    height: c_int,
    x: c_int,
    y: c_int,
    user: ?*anyopaque,
    title: [*c]u8,
    state: platform_h.rvn_pwindow_state_t,
    transparent: c_int,
};

const NullState = extern struct {
    handler: platform_h.rvn_pevent_handler_t,
    mutex: ext.rvn_mutex_t,
    cond: ext.rvn_cond_t,
    woken: c_int,
    clipboard: [*c]u8,
};

var g_null: NullState = std.mem.zeroes(NullState);

fn rvn_null_init(handler: platform_h.rvn_pevent_handler_t, regions: platform_h.rvn_pregion_handler_t) callconv(.c) c_int {
    _ = regions; // RVN_UNUSED(regions);
    g_null = std.mem.zeroes(NullState);
    g_null.handler = handler;
    ext.rvn_mutex_init(&g_null.mutex);
    ext.rvn_cond_init(&g_null.cond);
    return raven.R_TRUE;
}

fn rvn_null_shutdown() callconv(.c) void {
    base.rvn_free(g_null.clipboard);
    ext.rvn_cond_destroy(&g_null.cond);
    ext.rvn_mutex_destroy(&g_null.mutex);
    g_null = std.mem.zeroes(NullState);
}

fn rvn_null_native_display() callconv(.c) ?*anyopaque {
    return null;
}

fn rvn_null_window_create(desc: [*c]const platform_h.rvn_pwindow_desc_t) callconv(.c) ?*platform_h.rvn_pwindow_t {
    const window: [*c]NullWindow = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(NullWindow))));
    window.*.width = desc.*.width;
    window.*.height = desc.*.height;
    window.*.user = desc.*.user;
    window.*.title = base.rvn_strdup(desc.*.title);
    // (nothing is shown, so nothing prevents a window from being seen through: the tests can ask for it)
    window.*.transparent = @as(c_int, @intFromBool((desc.*.flags & @as(u32, @intCast(raven.R_WINDOW_TRANSPARENT))) != 0));
    return @ptrCast(window);
}

fn rvn_null_window_destroy(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    base.rvn_free(window.*.title);
    base.rvn_free(window);
}

fn rvn_null_window_set_title(window_: ?*platform_h.rvn_pwindow_t, title: [*c]const u8) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    _ = base.rvn_str_set(&window.*.title, title);
}

fn rvn_null_window_set_size(window_: ?*platform_h.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    if (window.*.width == width and window.*.height == height) return;
    window.*.width = width;
    window.*.height = height;
    // behave like a real window system: the core learns the size from an event
    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_RESIZE);
    event.user = window.*.user;
    event.width = width;
    event.height = height;
    event.scale = 1.0;
    g_null.handler.?(&event);
}

fn rvn_null_window_get_size(window_: ?*platform_h.rvn_pwindow_t, width: [*c]c_int, height: [*c]c_int) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    width.* = window.*.width;
    height.* = window.*.height;
}

fn rvn_null_window_set_min_size(window_: ?*platform_h.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    _ = window_; // RVN_UNUSED(window);
    _ = width; // RVN_UNUSED(width);
    _ = height; // RVN_UNUSED(height);
}

fn rvn_null_window_set_position(window_: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    window.*.x = x;
    window.*.y = y;
}

fn rvn_null_window_get_position(window_: ?*platform_h.rvn_pwindow_t, x: [*c]c_int, y: [*c]c_int) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    x.* = window.*.x;
    y.* = window.*.y;
}

fn rvn_null_window_get_scale(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) f32 {
    _ = window_; // RVN_UNUSED(window);
    return 1.0;
}

fn rvn_null_window_show(window_: ?*platform_h.rvn_pwindow_t, visible: c_int) callconv(.c) void {
    _ = window_; // RVN_UNUSED(window);
    _ = visible; // RVN_UNUSED(visible);
}

fn rvn_null_window_set_state(window_: ?*platform_h.rvn_pwindow_t, state: platform_h.rvn_pwindow_state_t) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    if (window.*.state == state) return;
    window.*.state = state;
    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_STATE);
    event.user = window.*.user;
    event.state = state;
    g_null.handler.?(&event);
}

fn rvn_null_window_get_state(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) platform_h.rvn_pwindow_state_t {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    return window.*.state;
}

fn rvn_null_window_begin_move(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) void {
    _ = window_; // RVN_UNUSED(window);
}

fn rvn_null_window_begin_resize(window_: ?*platform_h.rvn_pwindow_t, edge: platform_h.rvn_pregion_t) callconv(.c) void {
    _ = window_; // RVN_UNUSED(window);
    _ = edge; // RVN_UNUSED(edge);
}

fn rvn_null_window_set_cursor(window_: ?*platform_h.rvn_pwindow_t, cursor: raven.RCursor) callconv(.c) void {
    _ = window_; // RVN_UNUSED(window);
    _ = cursor; // RVN_UNUSED(cursor);
}

fn rvn_null_window_get_native(window_: ?*platform_h.rvn_pwindow_t, native: [*c]raven.RNativeWindow) callconv(.c) void {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    native.* = std.mem.zeroes(raven.RNativeWindow);
    native.*.system = @intCast(raven.R_WINDOW_SYSTEM_NONE);
    native.*.transparent = window.*.transparent;
}

fn rvn_null_window_set_backdrop(window_: ?*platform_h.rvn_pwindow_t, backdrop: c_int, dark: c_int) callconv(.c) c_int {
    const window: [*c]NullWindow = @ptrCast(@alignCast(window_));
    _ = dark; // RVN_UNUSED(dark);
    return if (window.*.transparent != 0) backdrop else raven.R_BACKDROP_NONE;
}

fn rvn_null_window_set_opacity(window_: ?*platform_h.rvn_pwindow_t, opacity: f32) callconv(.c) c_int {
    _ = window_; // RVN_UNUSED(window);
    _ = opacity; // RVN_UNUSED(opacity);
    return raven.R_TRUE;
}

fn rvn_null_child_create(parent: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) ?*platform_h.rvn_pwindow_t {
    _ = parent; // RVN_UNUSED(parent);
    _ = x; // RVN_UNUSED(x);
    _ = y; // RVN_UNUSED(y);
    _ = width; // RVN_UNUSED(width);
    _ = height; // RVN_UNUSED(height);
    _ = user; // RVN_UNUSED(user);
    return null;
}

fn rvn_null_child_set_rect(child: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, visible: c_int) callconv(.c) void {
    _ = child; // RVN_UNUSED(child);
    _ = x; // RVN_UNUSED(x);
    _ = y; // RVN_UNUSED(y);
    _ = width; // RVN_UNUSED(width);
    _ = height; // RVN_UNUSED(height);
    _ = visible; // RVN_UNUSED(visible);
}

fn rvn_null_pump(timeout_seconds: f64) callconv(.c) void {
    ext.rvn_mutex_lock(&g_null.mutex);
    if (g_null.woken == 0 and timeout_seconds != 0.0) {
        if (timeout_seconds < 0.0) {
            while (g_null.woken == 0) ext.rvn_cond_wait(&g_null.cond, &g_null.mutex);
        } else {
            _ = ext.rvn_cond_wait_timeout(&g_null.cond, &g_null.mutex, timeout_seconds);
        }
    }
    g_null.woken = raven.R_FALSE;
    ext.rvn_mutex_unlock(&g_null.mutex);
}

fn rvn_null_wake() callconv(.c) void {
    ext.rvn_mutex_lock(&g_null.mutex);
    g_null.woken = raven.R_TRUE;
    ext.rvn_cond_signal(&g_null.cond);
    ext.rvn_mutex_unlock(&g_null.mutex);
}

fn rvn_null_clipboard_set(text: [*c]const u8) callconv(.c) void {
    _ = base.rvn_str_set(&g_null.clipboard, text);
}

fn rvn_null_clipboard_get() callconv(.c) [*c]u8 {
    return base.rvn_strdup(g_null.clipboard);
}

const platform: platform_h.rvn_platform_t = .{
    .name = "null",
    .system = @intCast(raven.R_WINDOW_SYSTEM_NONE),
    .init = &rvn_null_init,
    .shutdown = &rvn_null_shutdown,
    .native_display = &rvn_null_native_display,
    .window_create = &rvn_null_window_create,
    .window_destroy = &rvn_null_window_destroy,
    .window_set_title = &rvn_null_window_set_title,
    .window_set_size = &rvn_null_window_set_size,
    .window_get_size = &rvn_null_window_get_size,
    .window_set_min_size = &rvn_null_window_set_min_size,
    .window_set_position = &rvn_null_window_set_position,
    .window_get_position = &rvn_null_window_get_position,
    .window_get_scale = &rvn_null_window_get_scale,
    .window_show = &rvn_null_window_show,
    .window_set_state = &rvn_null_window_set_state,
    .window_get_state = &rvn_null_window_get_state,
    .window_begin_move = &rvn_null_window_begin_move,
    .window_begin_resize = &rvn_null_window_begin_resize,
    .window_set_cursor = &rvn_null_window_set_cursor,
    .window_set_backdrop = &rvn_null_window_set_backdrop,
    .window_set_opacity = &rvn_null_window_set_opacity,
    .window_get_native = &rvn_null_window_get_native,
    .child_create = &rvn_null_child_create,
    .child_set_rect = &rvn_null_child_set_rect,
    .pump = &rvn_null_pump,
    .wake = &rvn_null_wake,
    .clipboard_set = &rvn_null_clipboard_set,
    .clipboard_get = &rvn_null_clipboard_get,
    // not set by the C initializer: zero
    .window_set_topmost = null,
    .window_center = null,
    .window_set_icon = null,
    .native_regions = 0,
    .wait_service = null,
    .a11y_event = null,
    .a11y_announce = null,
    .a11y_active = null,
    .a11y_settings = null,
};

export fn rvn_platform_null() [*c]const platform_h.rvn_platform_t {
    return &platform;
}
