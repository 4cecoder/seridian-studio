// Translated to Zig from vendor/raven/src/widgets/viewport.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/viewport.c
// Viewport: an area of the layout showing content rendered by the
// application (see raven_viewport.h for the three modes), and Custom: a widget
// measured and painted by application callbacks.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const draw_h = @import("../render/draw_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const common = @import("common_h.zig");
const thread_h = @import("../core/thread_h.zig");
const ext = @import("externs.zig");

// ===========================================================================
//  Viewport
// ===========================================================================

const rvn_viewport_t = extern struct {
    base: widget_h.rvn_widget_t,
    // mode 1: texture
    texture: raven.Rid,
    stretch: raven.RStretch,
    flip_y: c_int,
    // mode 2: draw callback
    draw_callback: raven.RViewportDrawCallback,
    draw_user: ?*anyopaque,
    // mode 3: native child window
    native: ?*plat_h.rvn_pwindow_t,
    /// Frame at which the viewport was last painted, and where (pixels).
    native_frame: u64,
    native_rect: [4]c_int,
    native_shown: c_int,

    realtime: c_int,
    pixel_width: c_int,
    pixel_height: c_int,
    resize_callback: raven.RViewportResizeCallback,
    resize_user: ?*anyopaque,
};

fn rvn_viewport_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.texture = raven.R_INVALID_ID;
    viewport.*.stretch = raven.R_STRETCH_FILL;
}

/// Removes the viewport from the native list of a window and destroys its child window.
export fn rvn_viewport_native_release(widget: [*c]widget_h.rvn_widget_t, window: [*c]widget_h.rvn_window_t) void {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    var i: u32 = 0;
    while (window != null and i < window.*.native_viewport_count) : (i += 1) {
        if (window.*.native_viewports[i] != widget) continue;
        window.*.native_viewport_count -= 1;
        window.*.native_viewports[i] = window.*.native_viewports[window.*.native_viewport_count];
        break;
    }
    if (viewport.*.native != null) {
        const platform: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
        platform.*.window_destroy.?(viewport.*.native);
        viewport.*.native = null;
    }
    viewport.*.native_shown = raven.R_FALSE;
}

/// Called on the UI thread after each paint: moves, shows or hides the child window.
export fn rvn_viewport_native_sync(widget: [*c]widget_h.rvn_widget_t, frame: u64) void {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    const visible: c_int = @intFromBool(viewport.*.native_frame == frame and viewport.*.native_rect[2] > 0 and viewport.*.native_rect[3] > 0);
    if (viewport.*.native == null) return;
    if (visible == 0 and viewport.*.native_shown == 0) return;
    const platform: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
    platform.*.child_set_rect.?(viewport.*.native, viewport.*.native_rect[0], viewport.*.native_rect[1], viewport.*.native_rect[2], viewport.*.native_rect[3], visible);
    viewport.*.native_shown = visible;
}

fn rvn_viewport_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    // the child window was released when the viewport left its window; this is a safety net
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    if (viewport.*.native != null and ext.g_rvn.platform != null) {
        const platform: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
        platform.*.window_destroy.?(viewport.*.native);
    }
    viewport.*.native = null;
}

fn rvn_viewport_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    _ = widget;
    // a viewport takes the size it is given; this is only a visible minimum
    return base.rvn_vec2(64.0, 64.0);
}

fn rvn_viewport_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    const scale: f32 = if (widget.*.window != null) widget.*.window.*.scale else 1.0;
    const width: c_int = @intFromFloat(@floor(widget.*.rect.w * scale + 0.5));
    const height: c_int = @intFromFloat(@floor(widget.*.rect.h * scale + 0.5));
    if (width == viewport.*.pixel_width and height == viewport.*.pixel_height) return;
    viewport.*.pixel_width = width;
    viewport.*.pixel_height = height;
    if (viewport.*.resize_callback) |callback| {
        if (width > 0 and height > 0) {
            ext.rvn_dispatch_begin();
            callback(widget.*.id, width, height, viewport.*.resize_user);
            ext.rvn_dispatch_end();
        }
    }
}

fn rvn_viewport_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const box = ext.rvn_paint_snap(painter, rect);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const visible = base.rvn_box_intersect(box, dp.clip);
    const texture = ext.rvn_texture_get(viewport.*.texture);
    const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(dp.window));

    if (viewport.*.realtime != 0 and window != null) _ = thread_h.rvn_atomic_add(&window.*.realtime_viewports, 1);

    if (viewport.*.native != null) {
        // the child window covers this area: nothing of ours would be seen
        viewport.*.native_frame = if (window != null) window.*.frame_index else 0;
        viewport.*.native_rect[0] = @intFromFloat(box.x0);
        viewport.*.native_rect[1] = @intFromFloat(box.y0);
        viewport.*.native_rect[2] = @intFromFloat(box.x1 - box.x0);
        viewport.*.native_rect[3] = @intFromFloat(box.y1 - box.y0);
        return;
    }

    if (texture != null and texture.*.created != 0) {
        const full: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 }; // static const float full[4]
        var target: base.rvn_rect_t = undefined;
        var uv: [4]f32 = undefined;
        common.rvn_image_fit(viewport.*.stretch, base.rvn_vec2(@floatFromInt(texture.*.width), @floatFromInt(texture.*.height)), rect.w, rect.h, &full, &target, &uv);
        if (viewport.*.flip_y != 0) {
            const top = uv[1];
            uv[1] = uv[3];
            uv[3] = top;
        }
        if (viewport.*.stretch != raven.R_STRETCH_FILL and viewport.*.stretch != raven.R_STRETCH_COVER) {
            ext.rvn_paint_rect(painter, rect, base.rvn_rgba8(0, 0, 0, 255));
        }
        ext.rvn_paint_push_clip(painter, rect);
        ext.rvn_paint_image(painter, target, viewport.*.texture, &uv, 0xFFFFFFFF, 0.0);
        ext.rvn_paint_pop_clip(painter);
    } else {
        ext.rvn_paint_rect(painter, rect, base.rvn_rgba8(0, 0, 0, 255));
    }

    if (viewport.*.draw_callback != null and base.rvn_box_empty(visible) == 0) {
        var command: raven.RDrawCommand = std.mem.zeroes(raven.RDrawCommand);
        command.callback = viewport.*.draw_callback;
        command.user_data = viewport.*.draw_user;
        command.viewport = widget.*.id;
        command.texture = raven.R_INVALID_ID;
        command.rect[0] = @intFromFloat(box.x0);
        command.rect[1] = @intFromFloat(box.y0);
        command.rect[2] = @intFromFloat(box.x1 - box.x0);
        command.rect[3] = @intFromFloat(box.y1 - box.y0);
        command.clip[0] = @intFromFloat(visible.x0);
        command.clip[1] = @intFromFloat(visible.y0);
        command.clip[2] = @intFromFloat(visible.x1 - visible.x0);
        command.clip[3] = @intFromFloat(visible.y1 - visible.y0);
        ext.rvn_drawlist_add_callback(dp.list, &command);
    }
}

fn rvn_viewport_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, 0.0);
}

fn rvn_viewport_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    // The application receives the events through Rwidget_set_event_callback
    // before this function. Here the viewport only keeps a drag alive when
    // the cursor leaves it, and stops clicks from reaching what is behind.
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            widget_h.rvn_widget_capture_mouse(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => return raven.R_TRUE,
        else => return raven.R_FALSE,
    }
}

fn rvn_viewport_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Stretch") == 0) {
        if (common.rvn_parse_stretch(value, &viewport.*.stretch) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "FlipY") == 0) {
        if (ext.rvn_parse_bool(value, &viewport.*.flip_y) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Realtime") == 0) {
        if (ext.rvn_parse_bool(value, &viewport.*.realtime) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Source") == 0) {
        viewport.*.texture = common.rvn_xml_texture(value);
        if (viewport.*.texture == raven.R_INVALID_ID) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_viewport: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_VIEWPORT,
    .name = "Viewport",
    .size = @sizeOf(rvn_viewport_t),
    // painting updates the state of the native child window: UI thread only
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_UI_PAINT | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_NO_MIRROR,
    .init = rvn_viewport_init,
    .destroy = rvn_viewport_destroy,
    .measure = rvn_viewport_measure,
    .arrange = rvn_viewport_arrange,
    .paint = rvn_viewport_paint,
    .paint_overlay = rvn_viewport_paint_overlay,
    .event = rvn_viewport_event,
    .set_attribute = rvn_viewport_set_attribute,
});

export fn Rviewport_set_texture(id: raven.Rid, texture: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_texture");
    if (widget == null) return;
    if (texture != raven.R_INVALID_ID and ext.rvn_texture_get(texture) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rviewport_set_texture: invalid texture");
        return;
    }
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.texture = texture;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rviewport_set_stretch(id: raven.Rid, stretch: raven.RStretch) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_stretch");
    if (widget == null) return;
    if (stretch < raven.R_STRETCH_FILL or stretch > raven.R_STRETCH_NONE) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rviewport_set_stretch: invalid stretch mode");
        return;
    }
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.stretch = stretch;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rviewport_set_flip_y(id: raven.Rid, flip: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_flip_y");
    if (widget == null) return;
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.flip_y = @intFromBool(flip != 0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rviewport_set_draw_callback(id: raven.Rid, callback: raven.RViewportDrawCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_draw_callback");
    if (widget == null) return;
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.draw_callback = callback;
    viewport.*.draw_user = user_data;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rviewport_set_native(id: raven.Rid, enabled: c_int) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_native");
    if (widget == null) return raven.R_FALSE;
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    const window = widget.*.window;

    if (enabled == 0) {
        rvn_viewport_native_release(widget, window);
        widget_h.rvn_widget_invalidate_paint(widget);
        return raven.R_TRUE;
    }
    if (viewport.*.native != null) return raven.R_TRUE;
    if (window == null or window.*.platform == null) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rviewport_set_native: the viewport is not in a window yet");
        return raven.R_FALSE;
    }
    if (window.*.needs_layout != 0) ext.rvn_window_layout(window);
    const origin = widget_h.rvn_widget_origin(widget);
    const platform: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
    viewport.*.native = platform.*.child_create.?(
        window.*.platform,
        @intFromFloat(origin.x * window.*.scale),
        @intFromFloat(origin.y * window.*.scale),
        base.rvn_maxi(1, @intFromFloat(widget.*.rect.w * window.*.scale)),
        base.rvn_maxi(1, @intFromFloat(widget.*.rect.h * window.*.scale)),
        window,
    );
    if (viewport.*.native == null) {
        base.rvn_error(raven.R_ERROR_PLATFORM, raven.R_SEVERITY_ERROR, "Rviewport_set_native: the window system cannot create a child window");
        return raven.R_FALSE;
    }
    // RVN_ARRAY_RESERVE(window->native_viewports, window->native_viewport_cap, window->native_viewport_count + 1),
    // expanded by hand: base_h's version passes a [*c][*c] data pointer to rvn_array_grow_ without a cast, which does not compile
    const needed: u32 = window.*.native_viewport_count + 1;
    if (needed > window.*.native_viewport_cap) {
        window.*.native_viewports = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(window.*.native_viewports), &window.*.native_viewport_cap, needed, @sizeOf([*c]widget_h.rvn_widget_t))));
    }
    window.*.native_viewports[window.*.native_viewport_count] = widget;
    window.*.native_viewport_count += 1;
    viewport.*.native_shown = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export fn Rviewport_get_native_handle(id: raven.Rid, native: [*c]raven.RNativeWindow) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_get_native_handle");
    if (widget == null) return raven.R_FALSE;
    if (native == null) return raven.R_FALSE;
    native.* = std.mem.zeroes(raven.RNativeWindow); // memset(native, 0, sizeof(*native))
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    if (viewport.*.native == null) return raven.R_FALSE;
    const platform: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
    platform.*.window_get_native.?(viewport.*.native, native);
    return @intFromBool(native.*.system != raven.R_WINDOW_SYSTEM_NONE);
}

export fn Rviewport_get_pixel_size(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) void {
    if (width != null) width.* = 0;
    if (height != null) height.* = 0;
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_get_pixel_size");
    if (widget == null) return;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) ext.rvn_window_layout(widget.*.window);
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    if (width != null) width.* = viewport.*.pixel_width;
    if (height != null) height.* = viewport.*.pixel_height;
}

export fn Rviewport_set_resize_callback(id: raven.Rid, callback: raven.RViewportResizeCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_resize_callback");
    if (widget == null) return;
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.resize_callback = callback;
    viewport.*.resize_user = user_data;
}

export fn Rviewport_set_realtime(id: raven.Rid, realtime: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_VIEWPORT, "Rviewport_set_realtime");
    if (widget == null) return;
    const viewport: [*c]rvn_viewport_t = @ptrCast(widget);
    viewport.*.realtime = @intFromBool(realtime != 0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

// ===========================================================================
//  Custom
// ===========================================================================

const rvn_custom_t = extern struct {
    base: widget_h.rvn_widget_t,
    paint_callback: raven.RPaintCallback,
    paint_user: ?*anyopaque,
    measure_callback: raven.RMeasureCallback,
    measure_user: ?*anyopaque,
};

fn rvn_custom_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const custom: [*c]rvn_custom_t = @ptrCast(widget);
    var width: f32 = 0.0;
    var height: f32 = 0.0;
    var i: u32 = 0;
    if (custom.*.measure_callback) |callback| callback(widget.*.id, &width, &height, custom.*.measure_user);
    // a custom widget may also hold children: it is at least as large as they need
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget_h.rvn_widget_measure_slot(widget.*.children[i]);
        width = base.rvn_maxf(width, child.x);
        height = base.rvn_maxf(height, child.y);
    }
    return base.rvn_vec2(base.rvn_maxf(width, 0.0), base.rvn_maxf(height, 0.0));
}

fn rvn_custom_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const custom: [*c]rvn_custom_t = @ptrCast(widget);
    if (custom.*.paint_callback) |callback| {
        callback(widget.*.id, painter, widget.*.rect.w, widget.*.rect.h, custom.*.paint_user);
    }
}

export const rvn_class_custom: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_CUSTOM,
    .name = "Custom",
    .size = @sizeOf(rvn_custom_t),
    .flags = widget_h.RVN_CF_UI_PAINT,
    .measure = rvn_custom_measure,
    .paint = rvn_custom_paint,
});

export fn Rcustom_set_paint_callback(id: raven.Rid, callback: raven.RPaintCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CUSTOM, "Rcustom_set_paint_callback");
    if (widget == null) return;
    const custom: [*c]rvn_custom_t = @ptrCast(widget);
    custom.*.paint_callback = callback;
    custom.*.paint_user = user_data;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rcustom_set_measure_callback(id: raven.Rid, callback: raven.RMeasureCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CUSTOM, "Rcustom_set_measure_callback");
    if (widget == null) return;
    const custom: [*c]rvn_custom_t = @ptrCast(widget);
    custom.*.measure_callback = callback;
    custom.*.measure_user = user_data;
    ext.rvn_widget_invalidate_layout(widget);
}
