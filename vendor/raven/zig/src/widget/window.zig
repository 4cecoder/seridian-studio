// Translated to Zig from vendor/raven/src/widget/window.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/window.c
// Windows: layout and paint scheduling, input routing (hover, focus, mouse
// capture, popups, tooltips, shortcuts) and the public window API.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const handle_h = @import("../core/handle_h.zig");
const thread_h = @import("../core/thread_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const common_h = @import("../widgets/common_h.zig");
const widget_h = @import("widget_h.zig");
const libc = @import("../sys/libc.zig");

const rvn_window_t = widget_h.rvn_window_t;
const rvn_widget_t = widget_h.rvn_widget_t;
const rvn_popup_t = widget_h.rvn_popup_t;
const rvn_ghost_t = widget_h.rvn_ghost_t;
const rvn_shortcut_t = widget_h.rvn_shortcut_t;
const rvn_layout_spring_t = widget_h.rvn_layout_spring_t;
const rvn_vec2_t = base.rvn_vec2_t;
const rvn_rect_t = base.rvn_rect_t;
const rvn_color_t = base.rvn_color_t;
const rvn_pregion_t = plat_h.rvn_pregion_t;
const rvn_glass_t = draw_h.rvn_glass_t;
const RPainter = draw_h.RPainter;

const RVN_THEME_COLOR = ctx_h.RVN_THEME_COLOR;
const RVN_THEME_METRIC = ctx_h.RVN_THEME_METRIC;

/// one frame waits to be rendered at most: the next one is painted with what the pointer did last (see rvn_windows_throttle)
const RVN_MAX_FRAMES_IN_FLIGHT = 1;
/// Backdrop captures per frame (glass). The first one blurs the whole window, the others an area of it.
const RVN_MAX_BACKDROPS = 24;
const RVN_DOUBLE_CLICK_TIME: f64 = 0.4;
const RVN_DOUBLE_CLICK_DISTANCE: f32 = 4.0;
const RVN_TOOLTIP_DELAY: f64 = 0.6;
const RVN_MAX_PATH_DEPTH = 128;

/// Space kept between a dialog and the edges of its window, and between its frame and its content.
const RVN_DIALOG_MARGIN: f32 = 24.0;
const RVN_DIALOG_PADDING: f32 = 18.0;

/// Width of the band along the edges that resizes the window, and length of its corners.
const RVN_RESIZE_GRIP: f32 = 6.0;
const RVN_RESIZE_CORNER: f32 = 18.0;

/// g_rvn.platform (the window system table), C: g_rvn.platform->...
inline fn platform() [*c]const plat_h.rvn_platform_t {
    return @ptrCast(@alignCast(ctx_h.g_rvn.platform));
}

inline fn asWindow(p: ?*anyopaque) [*c]rvn_window_t {
    return @ptrCast(@alignCast(p));
}

inline fn asWidget(p: ?*anyopaque) [*c]rvn_widget_t {
    return @ptrCast(@alignCast(p));
}

/// RVN_ARRAY_RESERVE for an array whose items are pointers (base_h's version needs a single-pointer data argument).
inline fn reserveArray(comptime Item: type, data: *[*c]Item, cap: [*c]u32, needed: u32) void {
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(Item))));
}

/// `x ? x : ""` for a C string.
inline fn orEmpty(s: [*c]const u8) [*c]const u8 {
    return if (s != null) s else "";
}

// ---------------------------------------------------------------------------
//  Lookup
// ---------------------------------------------------------------------------

export fn rvn_window_get(id: raven.Rid) [*c]rvn_window_t {
    const window = asWindow(handle_h.rvn_pool_get(&ctx_h.g_rvn.windows, id));
    return if (window != null and window.*.dead == 0) window else null;
}

export fn rvn_window_check(id: raven.Rid, function: [*c]const u8) [*c]rvn_window_t {
    if (ctx_h.rvn_api_check(function) == 0) return null;
    const window = rvn_window_get(id);
    if (window == null) base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "%s: invalid window handle 0x%08X", function, @as(c_uint, id));
    return window;
}

export fn rvn_window_size(window: [*c]const rvn_window_t) rvn_vec2_t {
    const scale: f32 = if (window.*.scale > 0.0) window.*.scale else 1.0;
    return base.rvn_vec2(@as(f32, @floatFromInt(window.*.width_px)) / scale, @as(f32, @floatFromInt(window.*.height_px)) / scale);
}

fn rvn_window_event(window: [*c]rvn_window_t, type_: raven.REventType) raven.REvent {
    var event = std.mem.zeroes(raven.REvent);
    event.type = type_;
    event.window = window.*.id;
    event.target = raven.R_INVALID_ID;
    event.x = window.*.mouse_x;
    event.y = window.*.mouse_y;
    event.modifiers = window.*.modifiers;
    return event;
}

// ---------------------------------------------------------------------------
//  Tooltip
// ---------------------------------------------------------------------------

fn rvn_window_tooltip_hide(window: [*c]rvn_window_t) void {
    if (window.*.tooltip_timer != raven.R_INVALID_ID) {
        raven.Rtimer_destroy(window.*.tooltip_timer);
        window.*.tooltip_timer = raven.R_INVALID_ID;
    }
    if (window.*.tooltip_visible != 0) {
        window.*.tooltip_visible = raven.R_FALSE;
        window.*.needs_paint = raven.R_TRUE;
    }
    window.*.tooltip_widget = null;
}

fn rvn_window_tooltip_fire(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const window = rvn_window_get(@truncate(@intFromPtr(user_data)));
    _ = timer;
    if (window == null) return;
    window.*.tooltip_timer = raven.R_INVALID_ID;
    if (window.*.tooltip_widget != null and window.*.tooltip_widget.*.tooltip != null) {
        window.*.tooltip_visible = raven.R_TRUE;
        window.*.tooltip_shown = std.mem.zeroes(raven.RSpring);
        window.*.tooltip_x = window.*.mouse_x;
        window.*.tooltip_y = window.*.mouse_y;
        window.*.needs_paint = raven.R_TRUE;
    }
}

/// Arms the tooltip of the nearest widget with a tooltip text under the cursor.
fn rvn_window_tooltip_arm(window: [*c]rvn_window_t) void {
    var walk: [*c]rvn_widget_t = undefined;
    rvn_window_tooltip_hide(window);
    walk = window.*.hover;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.tooltip != null) break;
        if ((walk.*.flags & widget_h.RVN_WF_POPUP) != 0) {
            walk = null;
            break;
        }
    }
    if (walk == null) return;
    window.*.tooltip_widget = walk;
    window.*.tooltip_timer = raven.Rtimer_create(RVN_TOOLTIP_DELAY, raven.R_FALSE, rvn_window_tooltip_fire, @ptrFromInt(@as(usize, window.*.id)));
}

export fn rvn_window_rearm_tooltip(window: [*c]rvn_window_t) void {
    if (window.*.dead == 0) rvn_window_tooltip_arm(window);
}

fn rvn_window_paint_tooltip(window: [*c]rvn_window_t, painter: [*c]RPainter) void {
    var text: [*c]const u8 = undefined;
    var line: [*c]const u8 = undefined;
    const size = rvn_window_size(window);
    const font_size = RVN_THEME_METRIC(raven.R_METRIC_FONT_SIZE);
    var width: f32 = 0.0;
    var height: f32 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var shown: f32 = undefined;
    const opacity = painter.*.opacity;
    const first_instance = painter.*.list.*.instance_count;
    const first_command = painter.*.list.*.command_count;
    var lines: c_int = 0;

    if (window.*.tooltip_visible == 0 or window.*.tooltip_widget == null or window.*.tooltip_widget.*.tooltip == null) return;
    shown = draw_h.rvn_paint_spring_from(painter, &window.*.tooltip_shown, 1.0, raven.R_MOTION_BOUNCY);
    painter.*.opacity *= base.rvn_clampf(shown * 2.0, 0.0, 1.0);
    text = window.*.tooltip_widget.*.tooltip;
    const font = font_h.rvn_font_resolve(raven.R_INVALID_ID) orelse return;
    var metrics: font_h.rvn_font_metrics_t = undefined;
    font_h.rvn_font_metrics(font, font_size, &metrics);

    line = text;
    while (true) {
        const newline = libc.strchr(line, '\n');
        const length: c_int = if (newline != null) @intCast(@intFromPtr(newline) - @intFromPtr(line)) else @intCast(libc.strlen(line));
        width = base.rvn_maxf(width, font_h.rvn_text_width(font, font_size, line, length));
        lines += 1;
        if (newline == null) break;
        line = newline + 1;
    }
    width += 16.0;
    height = metrics.line_height * @as(f32, @floatFromInt(lines)) + 10.0;
    x = base.rvn_clampf(window.*.tooltip_x + 12.0, 0.0, base.rvn_maxf(0.0, size.x - width));
    y = window.*.tooltip_y + 20.0;
    if (y + height > size.y) y = window.*.tooltip_y - height - 6.0;
    if (y < 0.0) y = 0.0;

    if (ctx_h.g_rvn.theme.glass != 0) {
        var glass = std.mem.zeroes(rvn_glass_t);
        const radius = base.rvn_minf(height * 0.5, 12.0);
        const radii = [4]f32{ radius, radius, radius, radius };
        glass.tint = RVN_THEME_COLOR(raven.R_COLOR_TOOLTIP);
        glass.rim = base.rvn_rgba(1.0, 1.0, 1.0, if (ctx_h.g_rvn.theme.dark != 0) 0.5 else 0.8);
        glass.frost = 1.0;
        glass.refraction = 8.0;
        glass.saturation = 1.6;
        glass.shadow = 12.0;
        glass.shadow_color = RVN_THEME_COLOR(raven.R_COLOR_SHADOW);
        draw_h.rvn_paint_glass(painter, base.rvn_rect(x, y, width, height), &radii, &glass);
    } else {
        draw_h.rvn_paint_shadow(painter, base.rvn_rect(x, y + 2.0, width, height), 4.0, 8.0, RVN_THEME_COLOR(raven.R_COLOR_SHADOW));
        draw_h.rvn_paint_box(painter, base.rvn_rect(x, y, width, height), 4.0, RVN_THEME_COLOR(raven.R_COLOR_TOOLTIP), 1.0, RVN_THEME_COLOR(raven.R_COLOR_POPUP_BORDER));
    }
    y += 5.0;
    line = text;
    while (true) {
        const newline = libc.strchr(line, '\n');
        const length: c_int = if (newline != null) @intCast(@intFromPtr(newline) - @intFromPtr(line)) else @intCast(libc.strlen(line));
        draw_h.rvn_paint_text(painter, raven.R_INVALID_ID, font_size, x + 8.0, y, line, length, RVN_THEME_COLOR(raven.R_COLOR_TOOLTIP_TEXT));
        y += metrics.line_height;
        if (newline == null) break;
        line = newline + 1;
    }
    // pops out of the pointer
    painter.*.opacity = opacity;
    draw_h.rvn_drawlist_transform(painter.*.list, first_instance, first_command, 0.7 + 0.3 * shown, 0.7 + 0.3 * shown, (window.*.tooltip_x + 8.0) * painter.*.scale, (window.*.tooltip_y + 12.0) * painter.*.scale, 0.0, 0.0, painter.*.clip);
}

// ---------------------------------------------------------------------------
//  Hover and cursor
// ---------------------------------------------------------------------------

/// Collects a widget and its ancestors, up to and including the popup root.
fn rvn_hover_path(from: [*c]rvn_widget_t, path: [*c][*c]rvn_widget_t) usize {
    var count: usize = 0;
    var walk = from;
    while (walk != null and count < RVN_MAX_PATH_DEPTH) : (walk = walk.*.parent) {
        path[count] = walk;
        count += 1;
        if ((walk.*.flags & widget_h.RVN_WF_POPUP) != 0) break;
    }
    return count;
}

fn rvn_hover_clear_flags(from: [*c]rvn_widget_t) void {
    var walk = from;
    while (walk != null) : (walk = walk.*.parent) walk.*.flags &= ~widget_h.RVN_WF_HOVERED;
}

fn rvn_window_set_hover(window: [*c]rvn_window_t, target: [*c]rvn_widget_t) void {
    var old_path: [RVN_MAX_PATH_DEPTH][*c]rvn_widget_t = undefined;
    var new_path: [RVN_MAX_PATH_DEPTH][*c]rvn_widget_t = undefined;
    var left: [RVN_MAX_PATH_DEPTH]raven.Rid = undefined;
    var entered: [RVN_MAX_PATH_DEPTH]raven.Rid = undefined;
    var left_count: usize = 0;
    var entered_count: usize = 0;
    var i: usize = 0;
    var j: usize = 0;

    if (window.*.hover == target) return;

    const old_count: usize = if (window.*.hover != null) rvn_hover_path(window.*.hover, &old_path[0]) else 0;
    const new_count: usize = if (target != null) rvn_hover_path(target, &new_path[0]) else 0;
    while (i < old_count) : (i += 1) {
        j = 0;
        while (j < new_count and new_path[j] != old_path[i]) : (j += 1) {}
        if (j == new_count) {
            left[left_count] = old_path[i].*.id;
            left_count += 1;
        }
    }
    i = 0;
    while (i < new_count) : (i += 1) {
        j = 0;
        while (j < old_count and old_path[j] != new_path[i]) : (j += 1) {}
        if (j == old_count) {
            entered[entered_count] = new_path[i].*.id;
            entered_count += 1;
        }
    }

    rvn_hover_clear_flags(window.*.hover);
    i = 0;
    while (i < new_count) : (i += 1) new_path[i].*.flags |= widget_h.RVN_WF_HOVERED;
    window.*.hover = target;
    window.*.needs_paint = raven.R_TRUE;

    // notify through handles: a callback may delete widgets of either path
    i = 0;
    while (i < left_count) : (i += 1) {
        const widget = widget_h.rvn_widget_get(left[i]);
        if (widget == null) continue;
        var event = rvn_window_event(window, raven.R_EVENT_MOUSE_LEAVE);
        _ = widget_h.rvn_widget_send(widget, &event);
    }
    var k: usize = entered_count;
    while (k > 0) : (k -= 1) {
        const widget = widget_h.rvn_widget_get(entered[k - 1]);
        if (widget == null) continue;
        var event = rvn_window_event(window, raven.R_EVENT_MOUSE_ENTER);
        _ = widget_h.rvn_widget_send(widget, &event);
    }
    if (window.*.dead == 0) rvn_window_tooltip_arm(window);
}

fn rvn_window_hit(window: [*c]rvn_window_t, x: f32, y: f32, popup_index: [*c]c_int) [*c]rvn_widget_t {
    var i: u32 = window.*.popup_count;
    while (i > 0) : (i -= 1) {
        const hit = widget_h.rvn_widget_hit_test(window.*.popups[i - 1].root, x, y);
        // a dialog keeps for itself everything that is under it, the veil around it included
        if (hit != null or window.*.popups[i - 1].placement == widget_h.RVN_POPUP_DIALOG) {
            if (popup_index != null) popup_index.* = @as(c_int, @intCast(i - 1));
            return hit;
        }
    }
    if (popup_index != null) popup_index.* = -1;
    // the island floats above the content
    if (window.*.island != null) {
        const hit = widget_h.rvn_widget_hit_test(window.*.island, x, y);
        if (hit != null) return hit;
    }
    return if (window.*.root != null) widget_h.rvn_widget_hit_test(window.*.root, x, y) else null;
}

fn rvn_window_update_cursor(window: [*c]rvn_window_t) void {
    var cursor: raven.RCursor = raven.R_CURSOR_ARROW;
    var walk: [*c]rvn_widget_t = if (window.*.capture != null) window.*.capture else window.*.hover;
    const region: rvn_pregion_t = if (window.*.capture != null) plat_h.RVN_PREGION_CLIENT else window.*.edge;
    switch (region) {
        plat_h.RVN_PREGION_LEFT, plat_h.RVN_PREGION_RIGHT => {
            cursor = raven.R_CURSOR_RESIZE_H;
            walk = null;
        },
        plat_h.RVN_PREGION_TOP, plat_h.RVN_PREGION_BOTTOM => {
            cursor = raven.R_CURSOR_RESIZE_V;
            walk = null;
        },
        plat_h.RVN_PREGION_TOP_LEFT, plat_h.RVN_PREGION_BOTTOM_RIGHT => {
            cursor = raven.R_CURSOR_RESIZE_NWSE;
            walk = null;
        },
        plat_h.RVN_PREGION_TOP_RIGHT, plat_h.RVN_PREGION_BOTTOM_LEFT => {
            cursor = raven.R_CURSOR_RESIZE_NESW;
            walk = null;
        },
        else => {},
    }
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.cursor != 0) {
            cursor = walk.*.cursor;
            break;
        }
        if ((walk.*.flags & widget_h.RVN_WF_POPUP) != 0) break;
    }
    if (cursor != window.*.cursor) {
        window.*.cursor = cursor;
        if (window.*.platform != null) platform().*.window_set_cursor.?(window.*.platform, cursor);
    }
}

/// Recomputes the hovered widget for a cursor that did not move (after a layout).
fn rvn_window_refresh_hover(window: [*c]rvn_window_t) void {
    if (window.*.capture != null or window.*.mouse_inside == 0) return;
    rvn_window_set_hover(window, rvn_window_hit(window, window.*.mouse_x, window.*.mouse_y, null));
    if (window.*.dead == 0) rvn_window_update_cursor(window);
}

// ---------------------------------------------------------------------------
//  Focus
// ---------------------------------------------------------------------------

export fn rvn_window_set_focus(window: [*c]rvn_window_t, widget: [*c]rvn_widget_t) void {
    const old = window.*.focus;
    if (old == widget) return;
    window.*.focus = widget;
    window.*.needs_paint = raven.R_TRUE;
    if (old != null) {
        old.*.flags &= ~widget_h.RVN_WF_FOCUSED;
        var event = rvn_window_event(window, raven.R_EVENT_FOCUS_LOST);
        _ = widget_h.rvn_widget_send(old, &event);
    }
    // the callback above may have changed the focus again
    if (widget != null and window.*.focus == widget and (widget.*.flags & widget_h.RVN_WF_DEAD) == 0) {
        widget.*.flags |= widget_h.RVN_WF_FOCUSED;
        var event = rvn_window_event(window, raven.R_EVENT_FOCUS_GAINED);
        _ = widget_h.rvn_widget_send(widget, &event);
    }
}

const rvn_focus_list_t = extern struct {
    items: [*c][*c]rvn_widget_t,
    count: u32,
    cap: u32,
};

fn rvn_focus_collect(widget: [*c]rvn_widget_t, list: *rvn_focus_list_t) void {
    if (widget.*.visibility != raven.R_VISIBLE or (widget.*.flags & widget_h.RVN_WF_DISABLED) != 0) return;
    if ((widget.*.flags & widget_h.RVN_WF_FOCUSABLE) != 0) {
        reserveArray([*c]rvn_widget_t, &list.items, &list.cap, list.count + 1);
        list.items[list.count] = widget;
        list.count += 1;
    }
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget.*.cls.*.child_active) |child_active_fn| {
            if (child_active_fn(widget, child) == 0) continue;
        }
        rvn_focus_collect(child, list);
    }
}

fn rvn_window_focus_next(window: [*c]rvn_window_t, direction: c_int) void {
    var list = std.mem.zeroes(rvn_focus_list_t);
    var index: u32 = 0;
    var found = false;

    // the Tab key stays inside a dialog
    if (rvn_window_top_dialog(window) != null) {
        rvn_focus_collect(rvn_window_top_dialog(window), &list);
    } else if (window.*.root != null) {
        rvn_focus_collect(window.*.root, &list);
    }
    if (list.count == 0) {
        base.rvn_free(@ptrCast(list.items));
        return;
    }
    var i: u32 = 0;
    while (i < list.count) : (i += 1) {
        if (list.items[i] == window.*.focus) {
            index = i;
            found = true;
            break;
        }
    }
    if (!found) {
        index = if (direction > 0) 0 else list.count - 1;
    } else {
        index = (index +% (if (direction > 0) @as(u32, 1) else list.count -% 1)) % list.count;
    }
    window.*.focus_visible = raven.R_TRUE;
    rvn_window_set_focus(window, list.items[index]);
    base.rvn_free(@ptrCast(list.items));
}

// ---------------------------------------------------------------------------
//  Popups
// ---------------------------------------------------------------------------

export fn rvn_window_popup_index(window: [*c]const rvn_window_t, root: [*c]const rvn_widget_t) c_int {
    var i: u32 = 0;
    while (i < window.*.popup_count) : (i += 1) {
        if (window.*.popups[i].root == root) return @as(c_int, @intCast(i));
    }
    return -1;
}

export fn rvn_window_open_popup(window: [*c]rvn_window_t, root: [*c]rvn_widget_t, owner: [*c]rvn_widget_t, anchor_: rvn_rect_t, placement: widget_h.rvn_popup_placement_t, min_width: f32) void {
    var anchor = anchor_;
    if (rvn_window_popup_index(window, root) >= 0) return;
    base.RVN_ARRAY_RESERVE(&window.*.popups, &window.*.popup_cap, window.*.popup_count + 1);
    const popup: [*c]rvn_popup_t = &window.*.popups[window.*.popup_count];
    window.*.popup_count += 1;
    popup.* = std.mem.zeroes(rvn_popup_t);
    popup.*.root = root;
    popup.*.owner = owner;
    if (owner != null) {
        // the owner gave the place where it believes it is: inside a canvas that zooms, it shows somewhere else
        var x0 = anchor.x;
        var y0 = anchor.y;
        var x1 = anchor.x + anchor.w;
        var y1 = anchor.y + anchor.h;
        widget_h.rvn_widget_from_virtual(owner, &x0, &y0);
        widget_h.rvn_widget_from_virtual(owner, &x1, &y1);
        anchor = base.rvn_rect(x0, y0, x1 - x0, y1 - y0);
    }
    popup.*.anchor = anchor;
    popup.*.placement = placement;
    popup.*.min_width = min_width;
    // opened again while it was still closing, here or in another window
    if (root.*.window != null) rvn_window_forget_ghost(root.*.window, root);
    root.*.flags |= widget_h.RVN_WF_POPUP | widget_h.RVN_WF_LAYOUT_DIRTY;
    if (root.*.window != window) widget_h.rvn_widget_set_window(root, window);
    // a menu or a list opened from a part of the window that has its own theme wears it too
    if (owner != null) widget_h.rvn_widget_inherit_theme(root, owner.*.theme);
    rvn_window_tooltip_hide(window);
    window.*.needs_layout = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
}

export fn rvn_window_top_dialog(window: [*c]const rvn_window_t) [*c]rvn_widget_t {
    var i: u32 = window.*.popup_count;
    while (i > 0) : (i -= 1) {
        if (window.*.popups[i - 1].placement == widget_h.RVN_POPUP_DIALOG) return window.*.popups[i - 1].root;
    }
    return null;
}

export fn rvn_window_open_dialog(window: [*c]rvn_window_t, root: [*c]rvn_widget_t, closed: raven.RDialogClosedCallback, user: ?*anyopaque) void {
    const focus = window.*.focus;
    if (rvn_window_popup_index(window, root) >= 0) return;
    // menus and lists do not stay open under a dialog
    rvn_window_close_popups(window);
    if (root.*.parent != null or root.*.window != null) widget_h.rvn_widget_detach(root);
    window.*.capture = null;
    rvn_window_set_focus(window, null);
    if (window.*.dead != 0 or (root.*.flags & widget_h.RVN_WF_DEAD) != 0) return;
    // the widget that had the keyboard gets it back when the dialog closes
    rvn_window_open_popup(window, root, null, base.rvn_rect(0.0, 0.0, 0.0, 0.0), widget_h.RVN_POPUP_DIALOG, 0.0);
    const popup: [*c]rvn_popup_t = &window.*.popups[window.*.popup_count - 1];
    popup.*.focus_back = if (focus != null and (focus.*.flags & widget_h.RVN_WF_DEAD) == 0) focus.*.id else raven.R_INVALID_ID;
    popup.*.closed = closed;
    popup.*.closed_user = user;
    rvn_window_refresh_hover(window);
}

export fn rvn_window_close_dialog(inside: [*c]rvn_widget_t, result: c_int) c_int {
    const window = inside.*.window;
    if (window == null) return raven.R_FALSE;
    var i: u32 = window.*.popup_count;
    while (i > 0) : (i -= 1) {
        const popup: [*c]rvn_popup_t = &window.*.popups[i - 1];
        if (popup.*.placement != widget_h.RVN_POPUP_DIALOG or widget_h.rvn_widget_is_inside(inside, popup.*.root) == 0) continue;
        popup.*.result = result;
        rvn_window_close_popup(window, popup.*.root);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export fn rvn_window_close_popup(window: [*c]rvn_window_t, root: [*c]rvn_widget_t) void {
    const index = rvn_window_popup_index(window, root);
    if (index < 0) return;
    ctx_h.rvn_dispatch_begin();
    while (@as(c_int, @intCast(window.*.popup_count)) > index) {
        window.*.popup_count -= 1;
        const popup = window.*.popups[window.*.popup_count];
        const closed = popup.root;
        const dialog = popup.placement == widget_h.RVN_POPUP_DIALOG;
        var ghost_shown = false;
        // the popup closes because its own widgets are being removed: nothing of it may stay behind
        const leaving = window.*.forgetting != null and widget_h.rvn_widget_is_inside(closed, window.*.forgetting) != 0;
        if (window.*.hover != null and widget_h.rvn_widget_is_inside(window.*.hover, closed) != 0) {
            rvn_hover_clear_flags(window.*.hover);
            window.*.hover = null;
        }
        if (window.*.capture != null and widget_h.rvn_widget_is_inside(window.*.capture, closed) != 0) window.*.capture = null;
        if (window.*.focus != null and widget_h.rvn_widget_is_inside(window.*.focus, closed) != 0) {
            window.*.focus.*.flags &= ~widget_h.RVN_WF_FOCUSED;
            window.*.focus = null;
        }
        closed.*.flags &= ~widget_h.RVN_WF_POPUP;
        if (!leaving and ctx_h.g_rvn.animations_disabled == 0 and window.*.dead == 0 and window.*.visible != 0 and (closed.*.flags & widget_h.RVN_WF_DEAD) == 0) {
            // it stays in the window, without input, for the time it takes to shrink away
            base.RVN_ARRAY_RESERVE(&window.*.ghosts, &window.*.ghost_cap, window.*.ghost_count + 1);
            const ghost: [*c]rvn_ghost_t = &window.*.ghosts[window.*.ghost_count];
            window.*.ghost_count += 1;
            ghost.*.root = closed;
            ghost.*.anchor = popup.anchor;
            ghost.*.shown = popup.shown;
            ghost.*.shown.started = raven.R_TRUE;
            ghost.*.dialog = if (dialog) raven.R_TRUE else raven.R_FALSE;
            ghost_shown = true;
        } else if (closed.*.parent == null and (!dialog or leaving)) {
            // a popup that is not part of the tree leaves the window
            widget_h.rvn_widget_set_window(closed, null);
        }
        if (closed.*.cls.*.popup_closed) |popup_closed_fn| popup_closed_fn(closed);
        if (dialog) {
            const owner = popup.focus_back;
            const closed_id = closed.*.id;
            if (popup.closed) |closed_fn| closed_fn(closed_id, popup.result, popup.closed_user);
            // (the callback may have deleted anything)
            if (!ghost_shown and !leaving and widget_h.rvn_widget_get(closed_id) != null) widget_h.rvn_widget_destroy(closed);
            if (window.*.dead == 0 and widget_h.rvn_widget_get(owner) != null and window.*.focus == null and rvn_window_top_dialog(window) == null) {
                widget_h.rvn_widget_focus(widget_h.rvn_widget_get(owner));
            }
            if (window.*.dead != 0) break;
        }
    }
    if (window.*.dead == 0) {
        window.*.needs_layout = raven.R_TRUE;
        window.*.needs_paint = raven.R_TRUE;
    }
    ctx_h.rvn_dispatch_end();
}

export fn rvn_window_close_popups(window: [*c]rvn_window_t) void {
    // what is above the dialog on top; everything when there is no dialog
    var i: u32 = window.*.popup_count;
    while (i > 0) : (i -= 1) {
        if (window.*.popups[i - 1].placement == widget_h.RVN_POPUP_DIALOG) break;
    }
    if (i < window.*.popup_count) rvn_window_close_popup(window, window.*.popups[i].root);
}

fn rvn_window_close_all_popups(window: [*c]rvn_window_t) void {
    if (window.*.popup_count > 0) rvn_window_close_popup(window, window.*.popups[0].root);
}

fn rvn_window_layout_popup(window: [*c]rvn_window_t, popup: [*c]rvn_popup_t) void {
    const area = rvn_window_size(window);
    const desired = widget_h.rvn_widget_measure(popup.*.root);
    var width = base.rvn_maxf(desired.x, popup.*.min_width);
    var height = desired.y;
    var x = popup.*.anchor.x;
    var y = popup.*.anchor.y;

    if (width > area.x) width = area.x;
    if (height > area.y) height = area.y;

    switch (popup.*.placement) {
        widget_h.RVN_POPUP_DIALOG => {
            const room = RVN_DIALOG_MARGIN + RVN_DIALOG_PADDING;
            width = base.rvn_minf(desired.x, base.rvn_maxf(area.x - room * 2.0, 40.0));
            height = base.rvn_minf(desired.y, base.rvn_maxf(area.y - room * 2.0, 40.0));
            widget_h.rvn_widget_arrange(popup.*.root, @floor((area.x - width) * 0.5), @floor((area.y - height) * 0.5), width, height);
            return;
        },
        widget_h.RVN_POPUP_BELOW => {
            y = popup.*.anchor.y + popup.*.anchor.h;
            if (y + height > area.y and popup.*.anchor.y - height >= 0.0) y = popup.*.anchor.y - height;
        },
        widget_h.RVN_POPUP_RIGHT => {
            x = popup.*.anchor.x + popup.*.anchor.w;
            if (x + width > area.x and popup.*.anchor.x - width >= 0.0) x = popup.*.anchor.x - width;
        },
        else => {},
    }
    x = base.rvn_clampf(x, 0.0, base.rvn_maxf(0.0, area.x - width));
    y = base.rvn_clampf(y, 0.0, base.rvn_maxf(0.0, area.y - height));
    widget_h.rvn_widget_arrange(popup.*.root, @floor(x), @floor(y), width, height);
}

// ---------------------------------------------------------------------------
//  References to widgets
// ---------------------------------------------------------------------------

export fn rvn_window_forget_widget(window: [*c]rvn_window_t, widget: [*c]rvn_widget_t) void {
    var i: u32 = 0;
    if (window.*.capture != null and widget_h.rvn_widget_is_inside(window.*.capture, widget) != 0) window.*.capture = null;
    if (window.*.focus != null and widget_h.rvn_widget_is_inside(window.*.focus, widget) != 0) {
        window.*.focus.*.flags &= ~widget_h.RVN_WF_FOCUSED;
        window.*.focus = null;
    }
    if (window.*.hover != null and widget_h.rvn_widget_is_inside(window.*.hover, widget) != 0) {
        rvn_hover_clear_flags(window.*.hover);
        window.*.hover = null;
    }
    if (window.*.tooltip_widget != null and widget_h.rvn_widget_is_inside(window.*.tooltip_widget, widget) != 0) {
        rvn_window_tooltip_hide(window);
    }
    if (window.*.drop_target != null and widget_h.rvn_widget_is_inside(window.*.drop_target, widget) != 0) {
        window.*.drop_target = null;
        window.*.drop_accepted = raven.R_FALSE;
    }
    // a spring of the layout that stops being stepped must not stay half-way
    i = 0;
    while (i < window.*.layout_spring_count) {
        const entry: [*c]rvn_layout_spring_t = &window.*.layout_springs[i];
        if (widget_h.rvn_widget_is_inside(entry.*.widget, widget) == 0) {
            i += 1;
            continue;
        }
        draw_h.rvn_spring_set(entry.*.spring, entry.*.target);
        window.*.layout_spring_count -= 1;
        window.*.layout_springs[i] = window.*.layout_springs[window.*.layout_spring_count];
    }
    // close the popups shown from this subtree, lowest first (it closes the ones above)
    i = 0;
    while (i < window.*.popup_count) : (i += 1) {
        const popup: [*c]rvn_popup_t = &window.*.popups[i];
        if (widget_h.rvn_widget_is_inside(popup.*.root, widget) != 0 or (popup.*.owner != null and widget_h.rvn_widget_is_inside(popup.*.owner, widget) != 0)) {
            const previous = window.*.forgetting;
            window.*.forgetting = widget;
            rvn_window_close_popup(window, popup.*.root);
            window.*.forgetting = previous;
            break;
        }
    }
    i = 0;
    while (i < window.*.ghost_count) {
        const root = window.*.ghosts[i].root;
        if (widget_h.rvn_widget_is_inside(root, widget) == 0) {
            i += 1;
            continue;
        }
        window.*.ghost_count -= 1;
        window.*.ghosts[i] = window.*.ghosts[window.*.ghost_count];
        // (a closed popup that is not in the tree only stayed in the window to be drawn)
        if (root.*.parent == null and (root.*.flags & widget_h.RVN_WF_POPUP) == 0) widget_h.rvn_widget_set_window(root, null);
    }
    window.*.needs_paint = raven.R_TRUE;
}

export fn rvn_window_release_natives(window: [*c]rvn_window_t, subtree: [*c]rvn_widget_t) void {
    var i: u32 = window.*.native_viewport_count;
    while (i > 0) : (i -= 1) {
        const viewport = window.*.native_viewports[i - 1];
        if (widget_h.rvn_widget_is_inside(viewport, subtree) != 0) widget_h.rvn_viewport_native_release(viewport, window);
    }
}

// ---------------------------------------------------------------------------
//  Layout
// ---------------------------------------------------------------------------

export fn rvn_window_layout(window: [*c]rvn_window_t) void {
    const start = thread_h.rvn_clock_seconds();
    const size = rvn_window_size(window);
    var pass: c_int = 0;
    var i: u32 = 0;

    // a second pass is needed when the arrangement changes a desired size (wrapped text)
    while (pass < 4 and window.*.needs_layout != 0) : (pass += 1) {
        window.*.needs_layout = raven.R_FALSE;
        if (window.*.root != null) {
            _ = widget_h.rvn_widget_measure(window.*.root);
            // the content obeys its slot like any child: padding and alignment in the window
            widget_h.rvn_widget_arrange_slot(window.*.root, base.rvn_rect(0.0, 0.0, size.x, size.y));
        }
        if (window.*.island != null) {
            // at the top, in the middle, at its own size
            const desired = widget_h.rvn_widget_measure(window.*.island);
            const width = base.rvn_minf(desired.x, size.x);
            const height = base.rvn_minf(desired.y, size.y);
            widget_h.rvn_widget_arrange(window.*.island, @floor((size.x - width) * 0.5), window.*.island.*.slot.padding.t, width, height);
        }
        i = 0;
        while (i < window.*.popup_count) : (i += 1) rvn_window_layout_popup(window, &window.*.popups[i]);
    }
    window.*.needs_layout = raven.R_FALSE;
    window.*.needs_paint = raven.R_TRUE;
    window.*.stats.layout_ms = (thread_h.rvn_clock_seconds() - start) * 1000.0;
    rvn_window_refresh_hover(window);
}

// ---------------------------------------------------------------------------
//  Paint
// ---------------------------------------------------------------------------

export fn rvn_window_see_through(window: [*c]const rvn_window_t) c_int {
    return if (window.*.transparent != 0 and window.*.backdrop != 0 and window.*.backdrop != raven.R_BACKDROP_NONE) raven.R_TRUE else raven.R_FALSE;
}

/// The image behind the content: the one of the window, else the wallpaper of a glass theme.
fn rvn_window_paint_background(window: [*c]rvn_window_t, painter: [*c]RPainter) void {
    var texture: raven.Rid = if (renderer_h.rvn_texture_get(window.*.background) != null) window.*.background else raven.R_INVALID_ID;
    const size = rvn_window_size(window);

    // a window with its own clear color keeps it; one that is seen through has the screen for a wallpaper
    if (texture == raven.R_INVALID_ID and window.*.has_clear_color == 0 and rvn_window_see_through(window) == 0) texture = ctx_h.g_rvn.theme.wallpaper;
    const object = renderer_h.rvn_texture_get(texture);
    if (object == null or object.*.created == 0 or object.*.width <= 0 or object.*.height <= 0 or size.x <= 0.0 or size.y <= 0.0) return;

    // covers the window whatever its proportions: the centered part of the image with the same ratio
    const scale = base.rvn_maxf(size.x / @as(f32, @floatFromInt(object.*.width)), size.y / @as(f32, @floatFromInt(object.*.height)));
    const visible_u = size.x / (@as(f32, @floatFromInt(object.*.width)) * scale);
    const visible_v = size.y / (@as(f32, @floatFromInt(object.*.height)) * scale);
    var uv: [4]f32 = undefined;
    uv[0] = 0.5 - visible_u * 0.5;
    uv[1] = 0.5 - visible_v * 0.5;
    uv[2] = 0.5 + visible_u * 0.5;
    uv[3] = 0.5 + visible_v * 0.5;
    draw_h.rvn_paint_image(painter, base.rvn_rect(0.0, 0.0, size.x, size.y), texture, &uv, base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.0);
}

/// Detaches the root of a ghost that is not shown any more.
fn rvn_window_remove_ghost(window: [*c]rvn_window_t, index: u32) void {
    const root = window.*.ghosts[index].root;
    const dialog = window.*.ghosts[index].dialog;
    window.*.ghost_count -= 1;
    window.*.ghosts[index] = window.*.ghosts[window.*.ghost_count];
    if (dialog != 0) {
        // the window owns its dialogs
        if ((root.*.flags & widget_h.RVN_WF_POPUP) == 0) widget_h.rvn_widget_destroy(root);
        return;
    }
    // a popup that is not part of the tree leaves the window, unless it was opened again meanwhile
    if (root.*.parent == null and (root.*.flags & widget_h.RVN_WF_POPUP) == 0 and root.*.window == window) widget_h.rvn_widget_set_window(root, null);
}

fn rvn_window_forget_ghost(window: [*c]rvn_window_t, root: [*c]const rvn_widget_t) void {
    var i: u32 = 0;
    while (i < window.*.ghost_count) : (i += 1) {
        if (window.*.ghosts[i].root == root) {
            window.*.ghost_count -= 1;
            window.*.ghosts[i] = window.*.ghosts[window.*.ghost_count];
            return;
        }
    }
}

/// A popup grows out of what opened it: it is painted in place, then scaled
/// around the point of its frame that is nearest to its anchor.
fn rvn_window_paint_popup(painter: [*c]RPainter, root: [*c]rvn_widget_t, anchor: rvn_rect_t, shown: f32) void {
    const first_instance = painter.*.list.*.instance_count;
    const first_command = painter.*.list.*.command_count;
    const opacity = painter.*.opacity;

    if (shown > 0.999 and shown < 1.001) {
        widget_h.rvn_widget_paint(root, @ptrCast(painter));
        return;
    }
    painter.*.opacity *= base.rvn_clampf(shown * 1.8, 0.0, 1.0);
    widget_h.rvn_widget_paint(root, @ptrCast(painter));
    painter.*.opacity = opacity;

    const scale = 0.72 + 0.28 * shown;
    const pivot_x = base.rvn_clampf(anchor.x + anchor.w * 0.5, root.*.rect.x, root.*.rect.x + root.*.rect.w);
    const pivot_y = base.rvn_clampf(anchor.y + anchor.h * 0.5, root.*.rect.y, root.*.rect.y + root.*.rect.h);
    draw_h.rvn_drawlist_transform(painter.*.list, first_instance, first_command, scale, scale, pivot_x * painter.*.scale, pivot_y * painter.*.scale, 0.0, 0.0, painter.*.clip);
}

/// A dialog: a veil falls over the window, and the sheet rises from below
/// and settles with a bounce.
fn rvn_window_paint_dialog(window: [*c]rvn_window_t, painter: [*c]RPainter, root: [*c]rvn_widget_t, shown: f32) void {
    const size = rvn_window_size(window);
    const frame = base.rvn_rect(root.*.rect.x - RVN_DIALOG_PADDING, root.*.rect.y - RVN_DIALOG_PADDING, root.*.rect.w + RVN_DIALOG_PADDING * 2.0, root.*.rect.h + RVN_DIALOG_PADDING * 2.0);
    const veil = base.rvn_clampf(shown, 0.0, 1.0);
    const opacity = painter.*.opacity;
    var first_instance: u32 = undefined;
    var first_command: u32 = undefined;

    if (ctx_h.g_rvn.theme.glass != 0) {
        // the window goes out of focus behind the sheet
        var glass = std.mem.zeroes(rvn_glass_t);
        const radii = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
        glass.tint = base.rvn_rgba(0.0, 0.0, 0.0, if (ctx_h.g_rvn.theme.dark != 0) 0.34 else 0.16);
        glass.frost = 1.0;
        glass.saturation = 1.0;
        painter.*.opacity *= veil;
        draw_h.rvn_paint_glass(painter, base.rvn_rect(0.0, 0.0, size.x, size.y), &radii, &glass);
        painter.*.opacity = opacity;
    } else {
        draw_h.rvn_paint_rect(painter, base.rvn_rect(0.0, 0.0, size.x, size.y), base.rvn_rgba(0.0, 0.0, 0.0, 0.42 * veil));
    }

    first_instance = painter.*.list.*.instance_count;
    first_command = painter.*.list.*.command_count;
    painter.*.opacity *= base.rvn_clampf(shown * 2.2, 0.0, 1.0);
    if (ctx_h.g_rvn.theme.glass != 0) {
        common_h.rvn_paint_surface(@ptrCast(painter), root, frame, 26.0, common_h.RVN_SURFACE_POPUP, 0.0, 0.0);
    } else {
        draw_h.rvn_paint_shadow(painter, base.rvn_rect(frame.x, frame.y + 6.0, frame.w, frame.h), 10.0, 28.0, RVN_THEME_COLOR(raven.R_COLOR_SHADOW));
        draw_h.rvn_paint_box(painter, frame, 10.0, RVN_THEME_COLOR(raven.R_COLOR_POPUP), 1.0, RVN_THEME_COLOR(raven.R_COLOR_POPUP_BORDER));
    }
    widget_h.rvn_widget_paint(root, @ptrCast(painter));
    painter.*.opacity = opacity;
    if (shown < 0.999 or shown > 1.001) {
        const scale = 0.9 + 0.1 * shown;
        draw_h.rvn_drawlist_transform(painter.*.list, first_instance, first_command, scale, scale, (frame.x + frame.w * 0.5) * painter.*.scale, (frame.y + frame.h) * painter.*.scale, 0.0, (1.0 - shown) * 60.0 * painter.*.scale, painter.*.clip);
    }
}

/// What would take the drop of a drag coming from another application lights up.
fn rvn_window_paint_drop(window: [*c]rvn_window_t, painter: [*c]RPainter) void {
    const accent = RVN_THEME_COLOR(raven.R_COLOR_ACCENT);
    var rect = window.*.drop_rect;
    if (window.*.drop_accepted == 0 and window.*.drop_shown.started == 0) return;
    const shown = draw_h.rvn_paint_spring_from(painter, &window.*.drop_shown, if (window.*.drop_accepted != 0) 1.0 else 0.0, if (window.*.drop_accepted != 0) raven.R_MOTION_BOUNCY else raven.R_MOTION_SNAPPY);
    if (shown <= 0.01) return;
    // the frame lands on its target from a little further out
    const opacity = base.rvn_clampf(shown, 0.0, 1.0);
    const grow = (1.0 - shown) * 14.0;
    rect = base.rvn_rect(rect.x - grow, rect.y - grow, rect.w + grow * 2.0, rect.h + grow * 2.0);
    draw_h.rvn_paint_shadow(painter, rect, window.*.drop_radius, 18.0, base.rvn_color_fade(accent, 0.35 * opacity));
    draw_h.rvn_paint_box(painter, rect, window.*.drop_radius, base.rvn_color_fade(accent, 0.16 * opacity), 2.0, base.rvn_color_fade(accent, 0.95 * opacity));
}

fn rvn_window_can_paint(window: [*c]const rvn_window_t) bool {
    return window.*.surface_ready != 0 and window.*.width_px > 0 and window.*.height_px > 0;
}

fn rvn_window_paint(window: [*c]rvn_window_t, capture: [*c]raven.RCapture) void {
    var painter = std.mem.zeroes(RPainter);
    var widgets: u32 = 0;
    var backdrops: u32 = undefined;

    window.*.needs_paint = raven.R_FALSE;
    if (!rvn_window_can_paint(window) or (window.*.visible == 0 and capture == null)) return;

    // never queue more than a couple of frames: this is what paces a busy UI thread
    renderer_h.rvn_renderer_throttle(&window.*.frames_in_flight, RVN_MAX_FRAMES_IN_FLIGHT);

    const frame = renderer_h.rvn_renderer_acquire_frame();
    const start = thread_h.rvn_clock_seconds();

    painter.list = &frame.*.list;
    painter.window = window;
    painter.scale = window.*.scale;
    painter.clip = base.rvn_box(0.0, 0.0, @floatFromInt(window.*.width_px), @floatFromInt(window.*.height_px));
    painter.opacity = 1.0;
    painter.text_color = RVN_THEME_COLOR(raven.R_COLOR_TEXT);
    painter.enabled = raven.R_TRUE;
    // animations advance by the time since the last frame
    painter.dt = widget_h.rvn_animation_dt(start - window.*.paint_time);
    window.*.paint_time = start;

    thread_h.rvn_atomic_store(&window.*.realtime_viewports, 0);
    thread_h.rvn_atomic_store(&window.*.animating, 0);
    rvn_window_paint_background(window, &painter);
    if (window.*.root != null) {
        widget_h.rvn_widget_paint(window.*.root, @ptrCast(&painter));
        widgets += window.*.root.*.subtree_count;
    }
    if (window.*.island != null) {
        widget_h.rvn_widget_paint(window.*.island, @ptrCast(&painter));
        widgets += window.*.island.*.subtree_count;
    }
    rvn_window_paint_drop(window, &painter);
    rvn_window_paint_drag(window, &painter);
    // popups that were closed shrink away under the ones that are open
    var i: u32 = 0;
    while (i < window.*.ghost_count) {
        const ghost: [*c]rvn_ghost_t = &window.*.ghosts[i];
        const shown = draw_h.rvn_paint_spring_from(&painter, &ghost.*.shown, 0.0, raven.R_MOTION_SNAPPY);
        if (shown <= 0.02) {
            rvn_window_remove_ghost(window, i);
            continue;
        }
        if (ghost.*.dialog != 0) rvn_window_paint_dialog(window, &painter, ghost.*.root, shown) else rvn_window_paint_popup(&painter, ghost.*.root, ghost.*.anchor, shown);
        i += 1;
    }
    i = 0;
    while (i < window.*.popup_count) : (i += 1) {
        const popup: [*c]rvn_popup_t = &window.*.popups[i];
        const shown = draw_h.rvn_paint_spring_from(&painter, &popup.*.shown, 1.0, raven.R_MOTION_BOUNCY);
        if (popup.*.placement == widget_h.RVN_POPUP_DIALOG) rvn_window_paint_dialog(window, &painter, popup.*.root, shown) else rvn_window_paint_popup(&painter, popup.*.root, popup.*.anchor, shown);
        widgets += popup.*.root.*.subtree_count;
    }
    rvn_window_paint_tooltip(window, &painter);
    // color filters for the color blind (core/accessibility.c)
    widget_h.rvn_a11y_filter_instances(frame.*.list.instances, frame.*.list.instance_count);
    // what the screen reader must be told after this frame
    widget_h.rvn_a11y_frame(window);

    // new glyphs reach the GPU before the frame that uses them
    font_h.rvn_fonts_flush();
    font_h.rvn_fonts_resolve_pages(&frame.*.list);
    // glass: only keep the backdrop captures that show something new
    backdrops = draw_h.rvn_drawlist_resolve_backdrops(&frame.*.list, base.rvn_box(0.0, 0.0, @floatFromInt(window.*.width_px), @floatFromInt(window.*.height_px)), RVN_MAX_BACKDROPS);

    window.*.stats.paint_ms = (thread_h.rvn_clock_seconds() - start) * 1000.0;
    window.*.stats.render_ms = @as(f64, @floatFromInt(thread_h.rvn_atomic_load(&window.*.render_us))) / 1000.0;
    window.*.stats.widget_count = widgets;
    window.*.stats.instance_count = frame.*.list.instance_count;
    window.*.stats.draw_call_count = frame.*.list.command_count -% backdrops;
    window.*.stats.backdrop_count = backdrops;
    window.*.stats.paint_job_count = @bitCast(widget_h.rvn_paint_take_job_count());
    window.*.stats.frame_index = window.*.frame_index;

    const clear = RVN_THEME_COLOR(raven.R_COLOR_WINDOW);
    frame.*.data.window = window.*.id;
    frame.*.data.framebuffer_width = @bitCast(window.*.width_px);
    frame.*.data.framebuffer_height = @bitCast(window.*.height_px);
    frame.*.data.vsync = ctx_h.g_rvn.vsync;
    if (rvn_window_see_through(window) != 0) {
        // only what the widgets draw hides the screen; a clear color of the window, if any, veils it (premultiplied)
        const alpha: f32 = if (window.*.has_clear_color != 0) window.*.clear_color[3] else 0.0;
        frame.*.data.clear_color[0] = if (window.*.has_clear_color != 0) window.*.clear_color[0] * alpha else 0.0;
        frame.*.data.clear_color[1] = if (window.*.has_clear_color != 0) window.*.clear_color[1] * alpha else 0.0;
        frame.*.data.clear_color[2] = if (window.*.has_clear_color != 0) window.*.clear_color[2] * alpha else 0.0;
        frame.*.data.clear_color[3] = alpha;
    } else if (window.*.has_clear_color != 0) {
        @memcpy(&frame.*.data.clear_color, &window.*.clear_color);
    } else {
        base.rvn_color_to_floats(clear, &frame.*.data.clear_color[0], &frame.*.data.clear_color[1], &frame.*.data.clear_color[2], &frame.*.data.clear_color[3]);
    }
    frame.*.data.frame_index = window.*.frame_index;
    window.*.frame_index += 1;
    frame.*.data.scale = window.*.scale;
    frame.*.data.pointer[0] = if (window.*.mouse_inside != 0) window.*.mouse_x * window.*.scale else -1e6;
    frame.*.data.pointer[1] = if (window.*.mouse_inside != 0) window.*.mouse_y * window.*.scale else -1e6;
    frame.*.capture = capture;
    frame.*.frames_in_flight = &window.*.frames_in_flight;
    frame.*.render_us = &window.*.render_us;
    renderer_h.rvn_renderer_submit_frame(frame);

    // native child windows follow the viewports that were just painted, the others hide
    i = 0;
    while (i < window.*.native_viewport_count) : (i += 1) {
        widget_h.rvn_viewport_native_sync(window.*.native_viewports[i], window.*.frame_index - 1);
    }
}

export fn rvn_window_wants_frame(window: [*c]rvn_window_t) c_int {
    if (window.*.dead != 0) return raven.R_FALSE;
    if (window.*.needs_layout != 0 or window.*.layout_spring_count > 0) return raven.R_TRUE;
    if (!rvn_window_can_paint(window) or window.*.visible == 0) return raven.R_FALSE;
    return if (window.*.needs_paint != 0 or window.*.continuous != 0 or thread_h.rvn_atomic_load(&window.*.animating) != 0 or thread_h.rvn_atomic_load(&window.*.realtime_viewports) > 0 or thread_h.rvn_atomic_load(&window.*.redraw_requested) != 0) raven.R_TRUE else raven.R_FALSE;
}

export fn rvn_widget_animate_layout(widget: [*c]rvn_widget_t, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) void {
    const window = widget.*.window;
    var entry: [*c]rvn_layout_spring_t = null;
    var i: u32 = 0;

    if (window == null or window.*.dead != 0 or ctx_h.g_rvn.animations_disabled != 0 or spring.*.started == 0) {
        draw_h.rvn_spring_set(spring, target);
        widget_h.rvn_widget_invalidate_layout(widget);
        return;
    }
    while (i < window.*.layout_spring_count and entry == null) : (i += 1) {
        if (window.*.layout_springs[i].spring == spring) entry = &window.*.layout_springs[i];
    }
    if (entry == null) {
        base.RVN_ARRAY_RESERVE(&window.*.layout_springs, &window.*.layout_spring_cap, window.*.layout_spring_count + 1);
        entry = &window.*.layout_springs[window.*.layout_spring_count];
        window.*.layout_spring_count += 1;
    }
    entry.*.widget = widget;
    entry.*.spring = spring;
    entry.*.target = target;
    entry.*.motion = motion;
    window.*.needs_layout = raven.R_TRUE;
}

export fn rvn_widget_forget_layout_spring(widget: [*c]rvn_widget_t, spring: [*c]const raven.RSpring) void {
    const window = widget.*.window;
    var i: u32 = 0;
    if (window == null) return;
    while (i < window.*.layout_spring_count) : (i += 1) {
        if (window.*.layout_springs[i].spring != spring) continue;
        window.*.layout_spring_count -= 1;
        window.*.layout_springs[i] = window.*.layout_springs[window.*.layout_spring_count];
        return;
    }
}

/// Advances the springs that drive the layout; true while some are moving.
fn rvn_window_step_layout_springs(window: [*c]rvn_window_t) bool {
    var clock = std.mem.zeroes(RPainter);
    var i: u32 = 0;
    if (window.*.layout_spring_count == 0) return false;
    // (only the time of a painter is used: the springs are stepped as they would be while painting)
    clock.dt = widget_h.rvn_animation_dt(thread_h.rvn_clock_seconds() - window.*.paint_time);
    while (i < window.*.layout_spring_count) {
        const entry: [*c]rvn_layout_spring_t = &window.*.layout_springs[i];
        _ = draw_h.rvn_paint_spring_from(&clock, entry.*.spring, entry.*.target, entry.*.motion);
        widget_h.rvn_widget_invalidate_layout(entry.*.widget);
        if (draw_h.rvn_spring_moving(entry.*.spring, entry.*.target) == 0) {
            window.*.layout_spring_count -= 1;
            window.*.layout_springs[i] = window.*.layout_springs[window.*.layout_spring_count];
        } else {
            i += 1;
        }
    }
    return window.*.layout_spring_count > 0;
}

export fn rvn_window_update(window: [*c]rvn_window_t) void {
    if (window.*.dead != 0) return;
    if (thread_h.rvn_atomic_exchange(&window.*.redraw_requested, 0) != 0) window.*.needs_paint = raven.R_TRUE;
    _ = rvn_window_step_layout_springs(window);
    if (window.*.continuous != 0 or thread_h.rvn_atomic_load(&window.*.realtime_viewports) > 0 or thread_h.rvn_atomic_load(&window.*.animating) != 0) {
        window.*.needs_paint = raven.R_TRUE;
    }
    if (window.*.needs_layout != 0) rvn_window_layout(window);
    if (window.*.needs_paint != 0) rvn_window_paint(window, null);
}

export fn rvn_invalidate_all_windows() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.widgets.used) : (i += 1) {
        const widget = asWidget(handle_h.rvn_pool_at(&ctx_h.g_rvn.widgets, i));
        if (widget != null) widget.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
    }
    i = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window != null and window.*.dead == 0) {
            window.*.needs_layout = raven.R_TRUE;
            window.*.needs_paint = raven.R_TRUE;
        }
    }
}

export fn rvn_windows_theme_changed() void {
    var i: u32 = 0;
    // the materials the OS puts behind a window are light or dark with the theme
    if (ctx_h.g_rvn.platform == null or platform().*.window_set_backdrop == null) return;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window == null or window.*.dead != 0 or window.*.transparent == 0 or window.*.backdrop_wanted == 0) continue;
        if (window.*.backdrop_dark == ctx_h.g_rvn.theme.dark) continue;
        window.*.backdrop_dark = ctx_h.g_rvn.theme.dark;
        window.*.backdrop = @bitCast(platform().*.window_set_backdrop.?(window.*.platform, @bitCast(window.*.backdrop_wanted), ctx_h.g_rvn.theme.dark));
    }
}

export fn rvn_repaint_all_windows() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window != null and window.*.dead == 0) window.*.needs_paint = raven.R_TRUE;
    }
}

// ---------------------------------------------------------------------------
//  Custom header (R_WINDOW_CUSTOM_HEADER)
// ---------------------------------------------------------------------------

/// What a point of the window is for the window system: an edge, the title bar, or content.
fn rvn_window_region(window: [*c]rvn_window_t, x: f32, y: f32) rvn_pregion_t {
    const size = rvn_window_size(window);
    var walk: [*c]rvn_widget_t = undefined;
    var popup_index: c_int = -1;

    if ((window.*.window_flags & raven.R_WINDOW_CUSTOM_HEADER) == 0) return plat_h.RVN_PREGION_CLIENT;
    if ((window.*.window_flags & raven.R_WINDOW_NO_RESIZE) == 0 and window.*.state != plat_h.RVN_PWINDOW_MAXIMIZED) {
        const left = x < RVN_RESIZE_GRIP;
        const right = x >= size.x - RVN_RESIZE_GRIP;
        const top = y < RVN_RESIZE_GRIP;
        const bottom = y >= size.y - RVN_RESIZE_GRIP;
        if (left or right or top or bottom) {
            const near_left = x < RVN_RESIZE_CORNER;
            const near_right = x >= size.x - RVN_RESIZE_CORNER;
            const near_top = y < RVN_RESIZE_CORNER;
            const near_bottom = y >= size.y - RVN_RESIZE_CORNER;
            if (near_top and near_left) return plat_h.RVN_PREGION_TOP_LEFT;
            if (near_top and near_right) return plat_h.RVN_PREGION_TOP_RIGHT;
            if (near_bottom and near_left) return plat_h.RVN_PREGION_BOTTOM_LEFT;
            if (near_bottom and near_right) return plat_h.RVN_PREGION_BOTTOM_RIGHT;
            if (left) return plat_h.RVN_PREGION_LEFT;
            if (right) return plat_h.RVN_PREGION_RIGHT;
            return if (top) plat_h.RVN_PREGION_TOP else plat_h.RVN_PREGION_BOTTOM;
        }
    }
    if (window.*.capture != null) return plat_h.RVN_PREGION_CLIENT;
    walk = rvn_window_hit(window, x, y, &popup_index);
    if (popup_index >= 0) {
        // the title bar still moves the window through the veil of a dialog
        if (walk != null or window.*.root == null or window.*.popups[@as(usize, @intCast(popup_index))].placement != widget_h.RVN_POPUP_DIALOG) return plat_h.RVN_PREGION_CLIENT;
        walk = widget_h.rvn_widget_hit_test(window.*.root, x, y);
    }
    while (walk != null) : (walk = walk.*.parent) {
        if ((walk.*.flags & widget_h.RVN_WF_WINDOW_DRAG) != 0) {
            const origin = widget_h.rvn_widget_origin(walk);
            if (walk.*.cls.*.window_drag_at) |window_drag_at_fn| {
                if (window_drag_at_fn(walk, x - origin.x, y - origin.y) == 0) return plat_h.RVN_PREGION_CLIENT;
            }
            return plat_h.RVN_PREGION_CAPTION;
        }
        // a control inside the title bar keeps the mouse; what only shows something lets it through
        if (walk.*.cls.*.event != null or walk.*.event_callback != null or (walk.*.flags & widget_h.RVN_WF_FOCUSABLE) != 0) break;
    }
    return plat_h.RVN_PREGION_CLIENT;
}

export fn rvn_window_region_at(user: ?*anyopaque, x: c_int, y: c_int) rvn_pregion_t {
    const window = asWindow(user);
    if (window == null or window.*.dead != 0) return plat_h.RVN_PREGION_CLIENT;
    const scale: f32 = if (window.*.scale > 0.0) window.*.scale else 1.0;
    return rvn_window_region(window, @as(f32, @floatFromInt(x)) / scale, @as(f32, @floatFromInt(y)) / scale);
}

export fn rvn_window_toggle_maximized(window: [*c]rvn_window_t) void {
    if ((window.*.window_flags & raven.R_WINDOW_NO_RESIZE) != 0) return;
    platform().*.window_set_state.?(window.*.platform, if (window.*.state == plat_h.RVN_PWINDOW_MAXIMIZED) plat_h.RVN_PWINDOW_NORMAL else plat_h.RVN_PWINDOW_MAXIMIZED);
}

export fn rvn_window_request_close(window: [*c]rvn_window_t) void {
    ctx_h.rvn_dispatch_begin();
    var close: bool = true;
    if (window.*.close_callback) |close_fn| close = close_fn(window.*.id, window.*.close_user) != 0;
    if (close and window.*.dead == 0) rvn_window_destroy(window);
    ctx_h.rvn_dispatch_end();
}

/// The window system took the pointer (it moves or resizes the window): nothing is pressed any more.
fn rvn_window_lose_pointer(window: [*c]rvn_window_t) void {
    window.*.capture = null;
    window.*.buttons = 0;
    window.*.click_count = 0;
    window.*.edge = plat_h.RVN_PREGION_CLIENT;
    rvn_window_set_hover(window, null);
}

/// Window systems that do not ask for the regions (X11): a press of the left
/// button on the title bar or on an edge starts moving or resizing the window.
/// Returns true when the press was used.
fn rvn_window_press_region(window: [*c]rvn_window_t, x: f32, y: f32) bool {
    const clicks = window.*.click_count;
    if (platform().*.native_regions != 0 or window.*.capture != null) return false;
    const region = rvn_window_region(window, x, y);
    if (region == plat_h.RVN_PREGION_CLIENT) return false;
    rvn_window_lose_pointer(window);
    if (window.*.dead != 0) return true;
    if (region != plat_h.RVN_PREGION_CAPTION) {
        platform().*.window_begin_resize.?(window.*.platform, region);
    } else if (clicks == 2) {
        rvn_window_toggle_maximized(window);
    } else {
        // (the count is kept so that the next press can be the second click)
        window.*.click_count = clicks;
        platform().*.window_begin_move.?(window.*.platform);
    }
    return true;
}

// ---------------------------------------------------------------------------
//  Drag and drop from other applications
// ---------------------------------------------------------------------------

fn rvn_window_drop_send(window: [*c]rvn_window_t, phase: raven.RDropPhase, x: f32, y: f32, paths: [*c]const [*c]const u8, path_count: c_int, text: [*c]const u8) c_int {
    var event = std.mem.zeroes(raven.RDropEvent);
    var callback: raven.RDropCallback = null;
    var user: ?*anyopaque = null;
    var target: raven.Rid = raven.R_INVALID_ID;

    event.phase = phase;
    event.window = window.*.id;
    event.x = x;
    event.local_x = x;
    event.y = y;
    event.local_y = y;
    event.paths = paths;
    event.path_count = path_count;
    event.text = text;
    if (window.*.drag_active != 0) {
        event.text = window.*.drag_data;
        event.drag_type = window.*.drag_type;
        event.drag_source = window.*.drag_source;
    }
    if (window.*.drop_target != null) {
        const origin = widget_h.rvn_widget_origin(window.*.drop_target);
        event.local_x = x - origin.x;
        event.local_y = y - origin.y;
        callback = window.*.drop_target.*.drop_callback;
        user = window.*.drop_target.*.drop_user;
        target = window.*.drop_target.*.id;
    } else if (window.*.drop_on_window != 0) {
        callback = window.*.drop_callback;
        user = window.*.drop_user;
        target = window.*.id;
    } else {
        return raven.R_FALSE;
    }
    const cb = callback orelse return raven.R_FALSE;
    ctx_h.rvn_dispatch_begin();
    const result: c_int = if (cb(target, &event, user) != 0) raven.R_TRUE else raven.R_FALSE;
    ctx_h.rvn_dispatch_end();
    return result;
}

fn rvn_window_drop_clear(window: [*c]rvn_window_t) void {
    window.*.drop_target = null;
    window.*.drop_on_window = raven.R_FALSE;
    window.*.drop_accepted = raven.R_FALSE;
    window.*.needs_paint = raven.R_TRUE;
}

/// The drag moved to (x, y), or left the window. Returns R_TRUE when a drop there would be taken.
fn rvn_window_drag(window: [*c]rvn_window_t, x: f32, y: f32, inside: c_int) c_int {
    var target: [*c]rvn_widget_t = null;
    var accepted: c_int = undefined;

    if (inside != 0) {
        target = rvn_window_hit(window, x, y, null);
        while (target != null) : (target = target.*.parent) {
            if (target.*.drop_callback != null and widget_h.rvn_widget_is_enabled(target) != 0) break;
        }
    }
    // a drag inside the application only goes to widgets
    const on_window = inside != 0 and target == null and window.*.drop_callback != null and window.*.drag_active == 0;

    if (target != window.*.drop_target or on_window != (window.*.drop_on_window != 0)) {
        const target_id: raven.Rid = if (target != null) target.*.id else raven.R_INVALID_ID;
        if (window.*.drop_target != null or window.*.drop_on_window != 0) _ = rvn_window_drop_send(window, raven.R_DROP_LEAVE, x, y, null, 0, null);
        if (window.*.dead != 0) return raven.R_FALSE;
        rvn_window_drop_clear(window);
        // (the callback may have deleted the new target)
        target = if (target != null) widget_h.rvn_widget_get(target_id) else null;
        if (target == null and !on_window) return raven.R_FALSE;
        window.*.drop_target = target;
        window.*.drop_on_window = if (target == null) raven.R_TRUE else raven.R_FALSE;
        accepted = rvn_window_drop_send(window, raven.R_DROP_ENTER, x, y, null, 0, null);
    } else if (target != null or on_window) {
        accepted = rvn_window_drop_send(window, raven.R_DROP_MOVE, x, y, null, 0, null);
    } else {
        return raven.R_FALSE;
    }
    if (window.*.dead != 0) return raven.R_FALSE;
    window.*.drop_accepted = if (accepted != 0 and (window.*.drop_target != null or window.*.drop_on_window != 0)) raven.R_TRUE else raven.R_FALSE;
    window.*.needs_paint = raven.R_TRUE;
    if (window.*.drop_accepted != 0) {
        const old = window.*.drop_rect;
        if (window.*.drop_target != null) {
            const origin = widget_h.rvn_widget_origin(window.*.drop_target);
            window.*.drop_rect = base.rvn_rect(origin.x, origin.y, window.*.drop_target.*.rect.w, window.*.drop_target.*.rect.h);
            window.*.drop_radius = widget_h.rvn_widget_metric(window.*.drop_target, raven.R_METRIC_CORNER_RADIUS) + 2.0;
        } else {
            const size = rvn_window_size(window);
            window.*.drop_rect = base.rvn_rect(8.0, 8.0, base.rvn_maxf(size.x - 16.0, 0.0), base.rvn_maxf(size.y - 16.0, 0.0));
            window.*.drop_radius = 14.0;
        }
        // another target: the highlight lands again
        if (old.x != window.*.drop_rect.x or old.y != window.*.drop_rect.y or old.w != window.*.drop_rect.w or old.h != window.*.drop_rect.h) {
            window.*.drop_shown = std.mem.zeroes(raven.RSpring);
        }
    }
    return window.*.drop_accepted;
}

fn rvn_window_drop(window: [*c]rvn_window_t, x: f32, y: f32, paths: [*c]const [*c]const u8, path_count: c_int, text: [*c]const u8) c_int {
    var taken: c_int = raven.R_FALSE;
    // (some window systems only tell about the drop: this finds the target)
    if (rvn_window_drag(window, x, y, raven.R_TRUE) != 0) taken = rvn_window_drop_send(window, raven.R_DROP_DROPPED, x, y, paths, path_count, text);
    if (window.*.dead == 0) rvn_window_drop_clear(window);
    return taken;
}

// ---------------------------------------------------------------------------
//  Input (positions in logical units)
// ---------------------------------------------------------------------------

fn rvn_window_drag_end(window: [*c]rvn_window_t) void {
    window.*.drag_active = raven.R_FALSE;
    base.rvn_free(window.*.drag_type);
    base.rvn_free(window.*.drag_data);
    base.rvn_free(window.*.drag_label);
    window.*.drag_type = null;
    window.*.drag_data = null;
    window.*.drag_label = null;
    window.*.drag_source = raven.R_INVALID_ID;
    window.*.needs_paint = raven.R_TRUE;
}

fn rvn_window_drag_cancel(window: [*c]rvn_window_t) void {
    if (window.*.drag_active == 0) return;
    if (window.*.drop_target != null or window.*.drop_on_window != 0) _ = rvn_window_drop_send(window, raven.R_DROP_LEAVE, window.*.mouse_x, window.*.mouse_y, null, 0, null);
    if (window.*.dead != 0) return;
    rvn_window_drop_clear(window);
    rvn_window_drag_end(window);
}

fn rvn_window_paint_drag(window: [*c]rvn_window_t, painter: [*c]RPainter) void {
    if (window.*.drag_active == 0 or window.*.mouse_inside == 0) return;
    const label: [*c]const u8 = if (window.*.drag_label != null and window.*.drag_label[0] != 0) window.*.drag_label else null;
    if (label == null) return;
    const size = RVN_THEME_METRIC(raven.R_METRIC_FONT_SIZE);
    const font = font_h.rvn_font_resolve(raven.R_INVALID_ID);
    const width = (if (font != null) font_h.rvn_text_width(font, size, label, -1) else 80.0) + 20.0;
    const x = window.*.mouse_x + 14.0;
    const y = window.*.mouse_y + 10.0;
    draw_h.rvn_paint_shadow(painter, base.rvn_rect(x, y, width, size + 12.0), 6.0, 12.0, base.rvn_color_fade(RVN_THEME_COLOR(raven.R_COLOR_SHADOW), 0.6));
    draw_h.rvn_paint_box(painter, base.rvn_rect(x, y, width, size + 12.0), 6.0, RVN_THEME_COLOR(raven.R_COLOR_POPUP), 1.0, RVN_THEME_COLOR(if (window.*.drop_accepted != 0) raven.R_COLOR_ACCENT else raven.R_COLOR_POPUP_BORDER));
    draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, size, base.rvn_rect(x + 10.0, y, width - 20.0, size + 12.0), 0.0, label, -1, RVN_THEME_COLOR(raven.R_COLOR_TEXT));
}

/// The hook of the window sees the event before the widgets; R_TRUE consumes it.
fn rvn_window_hook(window: [*c]rvn_window_t, event: [*c]raven.REvent) c_int {
    const hook = window.*.event_hook orelse return raven.R_FALSE;
    event.*.target = if (window.*.hover != null) window.*.hover.*.id else raven.R_INVALID_ID;
    return if (hook(window.*.id, event, window.*.event_hook_user) != 0) raven.R_TRUE else raven.R_FALSE;
}

fn rvn_window_mouse_move(window: [*c]rvn_window_t, x: f32, y: f32) void {
    const dx: f32 = if (window.*.mouse_inside != 0) x - window.*.mouse_x else 0.0;
    const dy: f32 = if (window.*.mouse_inside != 0) y - window.*.mouse_y else 0.0;

    window.*.mouse_x = x;
    window.*.mouse_y = y;
    window.*.mouse_inside = raven.R_TRUE;
    if (window.*.tooltip_visible != 0 and (@abs(x - window.*.tooltip_x) > 6.0 or @abs(y - window.*.tooltip_y) > 6.0)) {
        rvn_window_tooltip_arm(window);
    }

    // custom header: the edges resize the window and are not part of the content
    if ((window.*.window_flags & raven.R_WINDOW_CUSTOM_HEADER) != 0 and platform().*.native_regions == 0 and window.*.capture == null) {
        const region: rvn_pregion_t = if (window.*.buttons != 0) plat_h.RVN_PREGION_CLIENT else rvn_window_region(window, x, y);
        window.*.edge = if (region == plat_h.RVN_PREGION_CAPTION) plat_h.RVN_PREGION_CLIENT else region;
        if (window.*.edge != plat_h.RVN_PREGION_CLIENT) {
            rvn_window_set_hover(window, null);
            if (window.*.dead == 0) rvn_window_update_cursor(window);
            return;
        }
    }

    var event = rvn_window_event(window, raven.R_EVENT_MOUSE_MOVE);
    event.delta_x = dx;
    event.delta_y = dy;
    if (window.*.capture == null) {
        const under = rvn_window_hit(window, x, y, null);
        rvn_window_set_hover(window, under);
        if (window.*.dead != 0) return;
    }
    if (rvn_window_hook(window, &event) != 0 or window.*.dead != 0) {
        if (window.*.dead == 0) rvn_window_update_cursor(window);
        return;
    }
    if (window.*.drag_active != 0) {
        _ = rvn_window_drag(window, x, y, raven.R_TRUE);
        window.*.needs_paint = raven.R_TRUE;
        return;
    }
    if (window.*.capture != null) {
        _ = widget_h.rvn_widget_send(window.*.capture, &event);
    } else {
        const hit = rvn_window_hit(window, x, y, null);
        rvn_window_set_hover(window, hit);
        if (window.*.dead != 0) return;
        const hovered = window.*.hover;
        if (hovered != null and widget_h.rvn_widget_is_enabled(hovered) != 0) _ = widget_h.rvn_widget_dispatch(hovered, &event);
    }
    if (window.*.dead == 0) rvn_window_update_cursor(window);
}

fn rvn_window_mouse_leave(window: [*c]rvn_window_t) void {
    window.*.mouse_inside = raven.R_FALSE;
    window.*.edge = plat_h.RVN_PREGION_CLIENT;
    if (window.*.capture == null) rvn_window_set_hover(window, null);
    if (window.*.dead == 0) rvn_window_tooltip_hide(window);
}

fn rvn_focusable_ancestor(widget: [*c]rvn_widget_t) [*c]rvn_widget_t {
    var walk = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if ((walk.*.flags & widget_h.RVN_WF_FOCUSABLE) != 0) return walk;
        if ((walk.*.flags & widget_h.RVN_WF_POPUP) != 0) break;
    }
    return null;
}

fn rvn_window_open_context_menu(window: [*c]rvn_window_t, target: [*c]rvn_widget_t) void {
    var walk = target;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.context_menu == raven.R_INVALID_ID) continue;
        const menu = widget_h.rvn_widget_get(walk.*.context_menu);
        if (menu != null and menu.*.cls.*.type == raven.R_WIDGET_MENU) widget_h.rvn_menu_popup(menu, window, window.*.mouse_x, window.*.mouse_y);
        return;
    }
}

fn rvn_window_mouse_button(window: [*c]rvn_window_t, button: raven.RMouseButton, pressed: c_int) void {
    var popup_index: c_int = -1;
    const x = window.*.mouse_x;
    const y = window.*.mouse_y;

    const button_i: c_int = @bitCast(button);
    if (button_i < 0 or button_i > raven.R_MOUSE_X2) return;
    const shift: u5 = @intCast(button);
    if (pressed != 0) {
        window.*.buttons |= @as(u32, 1) << shift;
    } else {
        window.*.buttons &= ~(@as(u32, 1) << shift);
    }
    rvn_window_tooltip_hide(window);

    {
        var hooked = rvn_window_event(window, if (pressed != 0) raven.R_EVENT_MOUSE_DOWN else raven.R_EVENT_MOUSE_UP);
        hooked.button = button;
        hooked.clicks = window.*.click_count;
        if (rvn_window_hook(window, &hooked) != 0 or window.*.dead != 0) {
            if (pressed == 0 and window.*.buttons == 0) window.*.capture = null;
            if (pressed == 0 and window.*.drag_active != 0 and window.*.buttons == 0) rvn_window_drag_cancel(window);
            return;
        }
    }

    // the end of a drag inside the application: dropped where the pointer is
    if (window.*.drag_active != 0) {
        if (pressed == 0 and window.*.buttons == 0) {
            if (rvn_window_drag(window, x, y, raven.R_TRUE) != 0 and window.*.dead == 0) {
                _ = rvn_window_drop_send(window, raven.R_DROP_DROPPED, x, y, null, 0, null);
            }
            if (window.*.dead != 0) return;
            rvn_window_drop_clear(window);
            rvn_window_drag_end(window);
            window.*.capture = null;
            rvn_window_refresh_hover(window);
        } else if (pressed != 0 and button != raven.R_MOUSE_LEFT) {
            rvn_window_drag_cancel(window);
        }
        return;
    }

    const hit = rvn_window_hit(window, x, y, &popup_index);

    if (pressed != 0) {
        const now = thread_h.rvn_clock_seconds();
        window.*.focus_visible = raven.R_FALSE;
        if (button == @as(raven.RMouseButton, @bitCast(window.*.click_button)) and now - window.*.click_time < RVN_DOUBLE_CLICK_TIME and @abs(x - window.*.click_x) < RVN_DOUBLE_CLICK_DISTANCE and @abs(y - window.*.click_y) < RVN_DOUBLE_CLICK_DISTANCE) {
            window.*.click_count += 1;
        } else {
            window.*.click_count = 1;
        }
        window.*.click_time = now;
        window.*.click_x = x;
        window.*.click_y = y;
        window.*.click_button = button_i;

        // a click outside of the open menus and lists closes them and is not passed on
        if (window.*.popup_count > 0 and window.*.capture == null and
            window.*.popups[window.*.popup_count - 1].placement != widget_h.RVN_POPUP_DIALOG and
            (popup_index < 0 or window.*.popups[@as(usize, @intCast(popup_index))].placement == widget_h.RVN_POPUP_DIALOG))
        {
            rvn_window_close_popups(window);
            rvn_window_refresh_hover(window);
            return;
        }

        if (button == raven.R_MOUSE_LEFT and (window.*.window_flags & raven.R_WINDOW_CUSTOM_HEADER) != 0 and rvn_window_press_region(window, x, y)) return;

        // an island unfolded by a click folds when the user goes on with something else
        if (window.*.capture == null) {
            common_h.rvn_islands_pressed(window, hit, if (popup_index >= 0) raven.R_TRUE else raven.R_FALSE);
            if (window.*.dead != 0) return;
        }

        const target = if (window.*.capture != null) window.*.capture else hit;
        if (target == null) {
            rvn_window_set_focus(window, null);
            return;
        }
        if (widget_h.rvn_widget_is_enabled(target) == 0) return;
        // menus and lists do not take the keyboard focus from the widget that opened them; a dialog has its own
        if ((popup_index < 0 or window.*.popups[@as(usize, @intCast(popup_index))].placement == widget_h.RVN_POPUP_DIALOG) and window.*.capture == null) {
            rvn_window_set_focus(window, rvn_focusable_ancestor(target));
            if (window.*.dead != 0 or (target.*.flags & widget_h.RVN_WF_DEAD) != 0) return;
        }
        var event = rvn_window_event(window, raven.R_EVENT_MOUSE_DOWN);
        event.button = button;
        event.clicks = window.*.click_count;
        if (window.*.capture != null) {
            _ = widget_h.rvn_widget_send(target, &event);
        } else {
            _ = widget_h.rvn_widget_dispatch(target, &event);
        }
    } else {
        const was_captured = window.*.capture != null;
        const target = if (window.*.capture != null) window.*.capture else hit;
        if (target != null and widget_h.rvn_widget_is_enabled(target) != 0) {
            var event = rvn_window_event(window, raven.R_EVENT_MOUSE_UP);
            event.button = button;
            event.clicks = window.*.click_count;
            if (window.*.capture != null) {
                _ = widget_h.rvn_widget_send(target, &event);
            } else {
                _ = widget_h.rvn_widget_dispatch(target, &event);
            }
        }
        if (window.*.dead != 0) return;
        if (window.*.buttons == 0) {
            // the hover was frozen during the capture: bring it up to date
            window.*.capture = null;
            if (was_captured) rvn_window_refresh_hover(window);
        }
        if (button == raven.R_MOUSE_RIGHT and hit != null and (hit.*.flags & widget_h.RVN_WF_DEAD) == 0 and window.*.dead == 0) {
            rvn_window_open_context_menu(window, hit);
        }
    }
    if (window.*.dead == 0) rvn_window_update_cursor(window);
}

fn rvn_window_mouse_wheel(window: [*c]rvn_window_t, wheel_x: f32, wheel_y: f32) void {
    const target = if (window.*.capture != null) window.*.capture else rvn_window_hit(window, window.*.mouse_x, window.*.mouse_y, null);
    rvn_window_tooltip_hide(window);
    var event = rvn_window_event(window, raven.R_EVENT_MOUSE_WHEEL);
    event.wheel_x = wheel_x;
    event.wheel_y = wheel_y;
    if (rvn_window_hook(window, &event) != 0 or window.*.dead != 0) return;
    if (target == null or widget_h.rvn_widget_is_enabled(target) == 0) return;
    _ = widget_h.rvn_widget_dispatch(target, &event);
}

fn rvn_window_key(window: [*c]rvn_window_t, key: raven.RKey, pressed: c_int, modifiers: u32, repeat: c_int) void {
    window.*.modifiers = modifiers;
    const key_i: c_int = @bitCast(key);
    if (key_i > 0 and key_i < raven.R_KEY_COUNT) window.*.keys[key] = if (pressed != 0) 1 else 0;
    if (pressed != 0) rvn_window_tooltip_hide(window);
    var event = rvn_window_event(window, if (pressed != 0) raven.R_EVENT_KEY_DOWN else raven.R_EVENT_KEY_UP);
    event.key = key;
    event.repeat = repeat;
    if (rvn_window_hook(window, &event) != 0 or window.*.dead != 0) return;
    if (window.*.drag_active != 0) {
        if (pressed != 0 and key == raven.R_KEY_ESCAPE) rvn_window_drag_cancel(window);
        return;
    }

    // the top popup sees the keyboard first (menu navigation)
    if (window.*.popup_count > 0 and window.*.popups[window.*.popup_count - 1].placement != widget_h.RVN_POPUP_DIALOG) {
        const top = window.*.popups[window.*.popup_count - 1].root;
        if (widget_h.rvn_widget_dispatch(top, &event) != 0 or window.*.dead != 0) return;
        if (pressed != 0 and key == raven.R_KEY_ESCAPE and window.*.popup_count > 0) {
            rvn_window_close_popup(window, window.*.popups[window.*.popup_count - 1].root);
            return;
        }
    }
    if (window.*.focus != null and widget_h.rvn_widget_is_enabled(window.*.focus) != 0) {
        if (widget_h.rvn_widget_dispatch(window.*.focus, &event) != 0 or window.*.dead != 0) return;
    } else if (rvn_window_top_dialog(window) != null) {
        // nothing has the keyboard: the dialog itself may want the key (Enter, a letter)
        if (widget_h.rvn_widget_dispatch(rvn_window_top_dialog(window), &event) != 0 or window.*.dead != 0) return;
    }
    if (pressed == 0) return;

    if (rvn_window_top_dialog(window) != null) {
        // Escape dismisses the dialog; the shortcuts of the window wait
        if (key == raven.R_KEY_TAB and (modifiers & (raven.R_MOD_CTRL | raven.R_MOD_ALT)) == 0) {
            rvn_window_focus_next(window, if ((modifiers & raven.R_MOD_SHIFT) != 0) -1 else 1);
        } else if (key == raven.R_KEY_ESCAPE) {
            _ = rvn_window_close_dialog(rvn_window_top_dialog(window), 0);
        }
        return;
    }

    if (key == raven.R_KEY_TAB and window.*.tab_navigation != 0 and (modifiers & (raven.R_MOD_CTRL | raven.R_MOD_ALT)) == 0) {
        rvn_window_focus_next(window, if ((modifiers & raven.R_MOD_SHIFT) != 0) -1 else 1);
        return;
    }
    if (key == raven.R_KEY_ESCAPE and window.*.focus != null) {
        rvn_window_set_focus(window, null);
        return;
    }
    var i: u32 = 0;
    while (i < window.*.shortcut_count) : (i += 1) {
        const shortcut: [*c]rvn_shortcut_t = &window.*.shortcuts[i];
        if (shortcut.*.key != key or shortcut.*.modifiers != (modifiers & 0xF)) continue;
        // copy: the callback may unregister the shortcut
        const action = base.rvn_strdup(shortcut.*.action);
        ctx_h.rvn_fire_action(window.*.id, action);
        base.rvn_free(action);
        return;
    }
    // shortcuts shown in the menus of the window
    const item = widget_h.rvn_menu_find_shortcut(window.*.root, key, modifiers & 0xF);
    if (item != null) widget_h.rvn_menu_item_trigger(item);
}

fn rvn_window_text(window: [*c]rvn_window_t, codepoint: u32) void {
    var event = rvn_window_event(window, raven.R_EVENT_TEXT);
    event.codepoint = codepoint;
    if (rvn_window_hook(window, &event) != 0 or window.*.dead != 0) return;
    if (window.*.focus == null or widget_h.rvn_widget_is_enabled(window.*.focus) == 0) return;
    _ = widget_h.rvn_widget_dispatch(window.*.focus, &event);
}

fn rvn_window_resized(window: [*c]rvn_window_t, width_px: c_int, height_px: c_int, platform_scale: f32) void {
    const scale: f32 = (if (platform_scale > 0.0) platform_scale else 1.0) * ctx_h.g_rvn.ui_scale;
    if (window.*.width_px == width_px and window.*.height_px == height_px and window.*.scale == scale) return;
    window.*.width_px = width_px;
    window.*.height_px = height_px;
    window.*.scale = scale;
    rvn_window_close_popups(window);
    window.*.needs_layout = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
    if (window.*.resize_callback) |resize_fn| {
        const size = rvn_window_size(window);
        resize_fn(window.*.id, @intFromFloat(size.x + 0.5), @intFromFloat(size.y + 0.5), window.*.resize_user);
    }
}

// ---------------------------------------------------------------------------
//  Platform events
// ---------------------------------------------------------------------------

export fn rvn_window_on_platform_event(pevent: [*c]const plat_h.rvn_pevent_t) void {
    const window = asWindow(pevent.*.user);

    if (pevent.*.type == plat_h.RVN_PEVENT_MODAL_TICK) {
        ctx_h.rvn_update();
        return;
    }
    if (window == null or window.*.dead != 0) return;
    const scale: f32 = if (window.*.scale > 0.0) window.*.scale else 1.0;

    // a dialog of the OS is open: the windows are shown, resized and repainted, but take no input
    if (ctx_h.g_rvn.input_blocked > 0) {
        switch (pevent.*.type) {
            plat_h.RVN_PEVENT_RESIZE, plat_h.RVN_PEVENT_EXPOSE, plat_h.RVN_PEVENT_FOCUS, plat_h.RVN_PEVENT_STATE => {},
            plat_h.RVN_PEVENT_DRAG, plat_h.RVN_PEVENT_DROP => {
                if (pevent.*.accepted != null) pevent.*.accepted.* = raven.R_FALSE;
                return;
            },
            else => return,
        }
    }

    ctx_h.rvn_dispatch_begin();
    switch (pevent.*.type) {
        plat_h.RVN_PEVENT_CLOSE => {
            rvn_window_request_close(window);
        },
        plat_h.RVN_PEVENT_RESIZE => {
            rvn_window_resized(window, pevent.*.width, pevent.*.height, pevent.*.scale);
        },
        plat_h.RVN_PEVENT_EXPOSE => {
            window.*.needs_paint = raven.R_TRUE;
        },
        plat_h.RVN_PEVENT_MOUSE_MOVE => {
            window.*.modifiers = pevent.*.modifiers;
            rvn_window_mouse_move(window, @as(f32, @floatFromInt(pevent.*.x)) / scale, @as(f32, @floatFromInt(pevent.*.y)) / scale);
        },
        plat_h.RVN_PEVENT_MOUSE_BUTTON => {
            window.*.modifiers = pevent.*.modifiers;
            rvn_window_mouse_move(window, @as(f32, @floatFromInt(pevent.*.x)) / scale, @as(f32, @floatFromInt(pevent.*.y)) / scale);
            if (window.*.dead == 0) rvn_window_mouse_button(window, @bitCast(pevent.*.button), pevent.*.pressed);
        },
        plat_h.RVN_PEVENT_MOUSE_WHEEL => {
            window.*.modifiers = pevent.*.modifiers;
            rvn_window_mouse_wheel(window, pevent.*.wheel_x, pevent.*.wheel_y);
        },
        plat_h.RVN_PEVENT_MOUSE_LEAVE => {
            rvn_window_mouse_leave(window);
        },
        plat_h.RVN_PEVENT_KEY => {
            rvn_window_key(window, pevent.*.key, pevent.*.pressed, pevent.*.modifiers, pevent.*.repeat);
        },
        plat_h.RVN_PEVENT_TEXT => {
            rvn_window_text(window, pevent.*.codepoint);
        },
        plat_h.RVN_PEVENT_FOCUS => {
            if (pevent.*.focused == 0) {
                // the window lost the keyboard: drop transient state
                window.*.capture = null;
                window.*.buttons = 0;
                window.*.modifiers = 0;
                @memset(&window.*.keys, 0);
                rvn_window_drag_cancel(window);
                rvn_window_close_popups(window);
                rvn_window_tooltip_hide(window);
            }
            window.*.active = pevent.*.focused;
            window.*.needs_paint = raven.R_TRUE;
        },
        plat_h.RVN_PEVENT_STATE => {
            if (window.*.state != pevent.*.state) {
                window.*.state = pevent.*.state;
                window.*.edge = plat_h.RVN_PREGION_CLIENT;
                window.*.needs_layout = raven.R_TRUE;
                window.*.needs_paint = raven.R_TRUE;
            }
        },
        plat_h.RVN_PEVENT_DRAG => {
            const inside: c_int = if (pevent.*.leaving == 0) raven.R_TRUE else raven.R_FALSE;
            const accepted = rvn_window_drag(window, @as(f32, @floatFromInt(pevent.*.x)) / scale, @as(f32, @floatFromInt(pevent.*.y)) / scale, inside);
            if (pevent.*.accepted != null) pevent.*.accepted.* = accepted;
        },
        plat_h.RVN_PEVENT_DROP => {
            const taken = rvn_window_drop(window, @as(f32, @floatFromInt(pevent.*.x)) / scale, @as(f32, @floatFromInt(pevent.*.y)) / scale, pevent.*.drop_paths, pevent.*.drop_count, pevent.*.drop_text);
            if (pevent.*.accepted != null) pevent.*.accepted.* = taken;
        },
        else => {},
    }
    ctx_h.rvn_dispatch_end();
}

// ---------------------------------------------------------------------------
//  Shortcuts
// ---------------------------------------------------------------------------

export fn rvn_window_remove_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32) void {
    var i: u32 = 0;
    while (i < window.*.shortcut_count) : (i += 1) {
        if (window.*.shortcuts[i].key == key and window.*.shortcuts[i].modifiers == modifiers) {
            base.rvn_free(window.*.shortcuts[i].action);
            window.*.shortcut_count -= 1;
            window.*.shortcuts[i] = window.*.shortcuts[window.*.shortcut_count];
            return;
        }
    }
}

export fn rvn_window_add_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32, action: [*c]const u8) void {
    rvn_window_remove_shortcut(window, key, modifiers);
    base.RVN_ARRAY_RESERVE(&window.*.shortcuts, &window.*.shortcut_cap, window.*.shortcut_count + 1);
    const shortcut: [*c]rvn_shortcut_t = &window.*.shortcuts[window.*.shortcut_count];
    window.*.shortcut_count += 1;
    shortcut.*.key = key;
    shortcut.*.modifiers = modifiers;
    shortcut.*.action = base.rvn_strdup(action);
}

// ---------------------------------------------------------------------------
//  Destruction
// ---------------------------------------------------------------------------

fn rvn_window_free(window: [*c]rvn_window_t) void {
    // waits for the frames still queued: they point into this structure
    if (window.*.surface_ready != 0) renderer_h.rvn_renderer_destroy_surface(window.*.id);
    if (window.*.platform != null) platform().*.window_destroy.?(window.*.platform);
    handle_h.rvn_pool_remove(&ctx_h.g_rvn.windows, window.*.id);
    var i: u32 = 0;
    while (i < window.*.shortcut_count) : (i += 1) base.rvn_free(window.*.shortcuts[i].action);
    base.rvn_free(window.*.shortcuts);
    base.rvn_free(@ptrCast(window.*.native_viewports));
    base.rvn_free(window.*.popups);
    base.rvn_free(window.*.ghosts);
    base.rvn_free(window.*.layout_springs);
    base.rvn_free(window.*.title);
    base.rvn_free(window.*.drag_type);
    base.rvn_free(window.*.drag_data);
    base.rvn_free(window.*.drag_label);
    base.rvn_free(window);
}

export fn rvn_window_destroy(window: [*c]rvn_window_t) void {
    if (window.*.dead != 0) return;
    rvn_window_close_all_popups(window);
    if (window.*.dead != 0) return;
    while (window.*.ghost_count > 0) rvn_window_remove_ghost(window, 0);
    rvn_window_tooltip_hide(window);
    const root = window.*.root;
    if (root != null) widget_h.rvn_widget_destroy(root);
    window.*.root = null;
    if (window.*.island != null) widget_h.rvn_widget_destroy(window.*.island);
    window.*.island = null;
    window.*.hover = null;
    window.*.focus = null;
    window.*.capture = null;
    // the handle stops resolving now; the slot stays reserved until the surface is gone
    window.*.dead = raven.R_TRUE;
    if (ctx_h.g_rvn.dispatch_depth > 0) {
        reserveArray(?*anyopaque, &ctx_h.g_rvn.dead_windows, &ctx_h.g_rvn.dead_window_cap, ctx_h.g_rvn.dead_window_count + 1);
        ctx_h.g_rvn.dead_windows[ctx_h.g_rvn.dead_window_count] = window;
        ctx_h.g_rvn.dead_window_count += 1;
    } else {
        rvn_window_free(window);
    }
}

export fn rvn_windows_collect() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.dead_window_count) : (i += 1) rvn_window_free(asWindow(ctx_h.g_rvn.dead_windows[i]));
    ctx_h.g_rvn.dead_window_count = 0;
}

export fn rvn_windows_destroy_all() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window != null and window.*.dead == 0) rvn_window_destroy(window);
    }
    rvn_windows_collect();
}

// ---------------------------------------------------------------------------
//  Public API: windows
// ---------------------------------------------------------------------------

// Seridian addition (not in upstream Raven): the X11 WM_CLASS of the windows, set by
// Rset_window_class. Static storage, so that it can be set before Rinit and survives Rshutdown.
const RVN_WINDOW_CLASS_MAX = 64;
var g_window_class_name: [RVN_WINDOW_CLASS_MAX:0]u8 = rvn_window_class_default();
var g_window_class_class: [RVN_WINDOW_CLASS_MAX:0]u8 = rvn_window_class_default();

fn rvn_window_class_default() [RVN_WINDOW_CLASS_MAX:0]u8 {
    var name = std.mem.zeroes([RVN_WINDOW_CLASS_MAX:0]u8);
    @memcpy(name[0..5], "raven");
    return name;
}

/// Copies `text` (NULL or "" gives `fallback`) into `out`, truncated to RVN_WINDOW_CLASS_MAX - 1 bytes.
fn rvn_window_class_copy(out: *[RVN_WINDOW_CLASS_MAX:0]u8, text: [*c]const u8, fallback: [*c]const u8) void {
    const source: [*c]const u8 = if (text != null and text[0] != 0) text else fallback;
    out.* = std.mem.zeroes([RVN_WINDOW_CLASS_MAX:0]u8);
    var i: usize = 0;
    while (i < RVN_WINDOW_CLASS_MAX - 1 and source[i] != 0) : (i += 1) out[i] = source[i];
}

export fn Rset_window_class(name: [*c]const u8, class_name: [*c]const u8) void {
    rvn_window_class_copy(&g_window_class_name, name, "raven");
    rvn_window_class_copy(&g_window_class_class, class_name, &g_window_class_name);
}

export fn Rget_window_class(name: [*c][*c]const u8, class_name: [*c][*c]const u8) void {
    if (name != null) name.* = &g_window_class_name;
    if (class_name != null) class_name.* = &g_window_class_class;
}

export fn Rwindow_create(title: [*c]const u8, width: c_int, height: c_int, flags: raven.Ruint) raven.Rid {
    if (ctx_h.rvn_api_check("Rwindow_create") == 0) return raven.R_INVALID_ID;
    if (width <= 0 or height <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwindow_create: invalid size %d x %d", width, height);
        return raven.R_INVALID_ID;
    }

    const window = asWindow(base.rvn_calloc(@sizeOf(rvn_window_t)));
    window.*.title = base.rvn_strdup(orEmpty(title));
    window.*.tooltip_timer = raven.R_INVALID_ID;
    window.*.cursor = raven.R_CURSOR_ARROW;
    window.*.click_button = -1;
    window.*.opacity = 1.0;
    window.*.tab_navigation = raven.R_TRUE;
    window.*.id = handle_h.rvn_pool_add(&ctx_h.g_rvn.windows, window);
    if (window.*.id == raven.R_INVALID_ID) {
        base.rvn_free(window.*.title);
        base.rvn_free(window);
        return raven.R_INVALID_ID;
    }

    var desc = std.mem.zeroes(plat_h.rvn_pwindow_desc_t);
    desc.title = window.*.title;
    desc.width = @intFromFloat(@as(f32, @floatFromInt(width)) * ctx_h.g_rvn.ui_scale + 0.5);
    desc.height = @intFromFloat(@as(f32, @floatFromInt(height)) * ctx_h.g_rvn.ui_scale + 0.5);
    desc.flags = flags;
    desc.user = window;
    desc.wm_name = &g_window_class_name;
    desc.wm_class = &g_window_class_class;
    window.*.platform = platform().*.window_create.?(&desc);
    if (window.*.platform == null) {
        base.rvn_error(raven.R_ERROR_PLATFORM, raven.R_SEVERITY_ERROR, "Rwindow_create: the window system refused to create the window");
        handle_h.rvn_pool_remove(&ctx_h.g_rvn.windows, window.*.id);
        base.rvn_free(window.*.title);
        base.rvn_free(window);
        return raven.R_INVALID_ID;
    }
    platform().*.window_get_size.?(window.*.platform, &window.*.width_px, &window.*.height_px);
    window.*.scale = platform().*.window_get_scale.?(window.*.platform) * ctx_h.g_rvn.ui_scale;
    if (window.*.scale <= 0.0) window.*.scale = 1.0;

    var native = std.mem.zeroes(raven.RNativeWindow);
    platform().*.window_get_native.?(window.*.platform, &native);
    if (renderer_h.rvn_renderer_create_surface(window.*.id, &native, @intCast(base.rvn_maxi(window.*.width_px, 1)), @intCast(base.rvn_maxi(window.*.height_px, 1))) == 0) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Rwindow_create: cannot create the rendering surface");
        platform().*.window_destroy.?(window.*.platform);
        handle_h.rvn_pool_remove(&ctx_h.g_rvn.windows, window.*.id);
        base.rvn_free(window.*.title);
        base.rvn_free(window);
        return raven.R_INVALID_ID;
    }
    window.*.surface_ready = raven.R_TRUE;
    window.*.needs_layout = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
    window.*.visible = if ((flags & raven.R_WINDOW_HIDDEN) == 0) raven.R_TRUE else raven.R_FALSE;
    window.*.window_flags = flags;
    window.*.transparent = if (native.transparent != 0) raven.R_TRUE else raven.R_FALSE;
    if ((flags & raven.R_WINDOW_TRANSPARENT) != 0) {
        // seen through from the start; Rwindow_set_backdrop says what the OS puts behind
        window.*.backdrop_wanted = raven.R_BACKDROP_TRANSPARENT;
        if (window.*.transparent != 0 and platform().*.window_set_backdrop != null) {
            window.*.backdrop = @bitCast(platform().*.window_set_backdrop.?(window.*.platform, raven.R_BACKDROP_TRANSPARENT, ctx_h.g_rvn.theme.dark));
            window.*.backdrop_dark = ctx_h.g_rvn.theme.dark;
        }
    }
    window.*.state = platform().*.window_get_state.?(window.*.platform);
    window.*.active = raven.R_TRUE;
    ctx_h.g_rvn.had_window = raven.R_TRUE;
    if (window.*.visible != 0) platform().*.window_show.?(window.*.platform, raven.R_TRUE);
    return window.*.id;
}

export fn Rwindow_destroy(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_destroy");
    if (window == null) return;
    rvn_window_destroy(window);
}

export fn Rwindow_is_valid(window: raven.Rid) c_int {
    return if (ctx_h.g_rvn.initialized != 0 and rvn_window_get(window) != null) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_set_content(id: raven.Rid, widget_id: raven.Rid) void {
    var widget: [*c]rvn_widget_t = null;
    const window = rvn_window_check(id, "Rwindow_set_content");
    if (window == null) return;
    if (widget_id != raven.R_INVALID_ID) {
        widget = widget_h.rvn_widget_check(widget_id, 0, "Rwindow_set_content");
        if (widget == null) return;
    }
    if (window.*.root == widget) return;
    if (window.*.root != null) widget_h.rvn_widget_destroy(window.*.root);
    window.*.root = null;
    if (widget != null) {
        if (widget.*.parent != null or widget.*.window != null) widget_h.rvn_widget_detach(widget);
        window.*.root = widget;
        widget_h.rvn_widget_set_window(widget, window);
        widget.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
    }
    window.*.needs_layout = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_set_backdrop(id: raven.Rid, backdrop: raven.RBackdrop) c_int {
    const window = rvn_window_check(id, "Rwindow_set_backdrop");
    if (window == null) return raven.R_FALSE;
    if (backdrop < raven.R_BACKDROP_NONE or backdrop > raven.R_BACKDROP_MICA) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwindow_set_backdrop: invalid backdrop");
        return raven.R_FALSE;
    }
    if (backdrop != raven.R_BACKDROP_NONE and (window.*.window_flags & raven.R_WINDOW_TRANSPARENT) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rwindow_set_backdrop: the window was not created with R_WINDOW_TRANSPARENT");
        return raven.R_FALSE;
    }
    var given: c_int = raven.R_BACKDROP_NONE;
    if (backdrop != raven.R_BACKDROP_NONE and window.*.transparent != 0 and platform().*.window_set_backdrop != null) {
        given = platform().*.window_set_backdrop.?(window.*.platform, @bitCast(backdrop), ctx_h.g_rvn.theme.dark);
    } else if (platform().*.window_set_backdrop != null and window.*.transparent != 0) {
        _ = platform().*.window_set_backdrop.?(window.*.platform, raven.R_BACKDROP_NONE, ctx_h.g_rvn.theme.dark);
    }
    window.*.backdrop_wanted = backdrop;
    window.*.backdrop = @bitCast(given);
    window.*.backdrop_dark = ctx_h.g_rvn.theme.dark;
    window.*.needs_paint = raven.R_TRUE;
    return if (backdrop == raven.R_BACKDROP_NONE or given != raven.R_BACKDROP_NONE) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_get_backdrop(id: raven.Rid) raven.RBackdrop {
    const window = rvn_window_check(id, "Rwindow_get_backdrop");
    if (window == null) return raven.R_BACKDROP_NONE;
    return if (window.*.backdrop != 0) window.*.backdrop else raven.R_BACKDROP_NONE;
}

export fn Rwindow_set_opacity(id: raven.Rid, opacity: f32) c_int {
    const window = rvn_window_check(id, "Rwindow_set_opacity");
    if (window == null) return raven.R_FALSE;
    const opacity_ = base.rvn_clampf(opacity, 0.0, 1.0);
    if (platform().*.window_set_opacity == null or platform().*.window_set_opacity.?(window.*.platform, opacity_) == 0) return raven.R_FALSE;
    window.*.opacity = opacity_;
    return raven.R_TRUE;
}

export fn Rwindow_set_topmost(id: raven.Rid, topmost: c_int) c_int {
    const window = rvn_window_check(id, "Rwindow_set_topmost");
    if (window == null) return raven.R_FALSE;
    if (platform().*.window_set_topmost == null) return raven.R_FALSE;
    return platform().*.window_set_topmost.?(window.*.platform, if (topmost != 0) raven.R_TRUE else raven.R_FALSE);
}

export fn Rwindow_center(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_center");
    if (window == null) return;
    if (platform().*.window_center != null) platform().*.window_center.?(window.*.platform);
}

export fn Rwindow_get_opacity(id: raven.Rid) f32 {
    const window = rvn_window_check(id, "Rwindow_get_opacity");
    if (window == null) return 1.0;
    return window.*.opacity;
}

export fn Rwindow_set_island(id: raven.Rid, widget_id: raven.Rid) void {
    var widget: [*c]rvn_widget_t = null;
    const window = rvn_window_check(id, "Rwindow_set_island");
    if (window == null) return;
    if (widget_id != raven.R_INVALID_ID) {
        widget = widget_h.rvn_widget_check(widget_id, 0, "Rwindow_set_island");
        if (widget == null) return;
    }
    if (window.*.island == widget) return;
    if (window.*.island != null) widget_h.rvn_widget_destroy(window.*.island);
    window.*.island = null;
    if (widget != null) {
        if (widget.*.parent != null or widget.*.window != null) widget_h.rvn_widget_detach(widget);
        window.*.island = widget;
        widget_h.rvn_widget_set_window(widget, window);
        widget.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
        widget_h.rvn_widget_appear(widget);
    }
    window.*.needs_layout = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_get_island(id: raven.Rid) raven.Rid {
    const window = rvn_window_check(id, "Rwindow_get_island");
    if (window == null) return raven.R_INVALID_ID;
    return if (window.*.island != null) window.*.island.*.id else raven.R_INVALID_ID;
}

export fn Rwindow_get_content(id: raven.Rid) raven.Rid {
    const window = rvn_window_check(id, "Rwindow_get_content");
    if (window == null) return raven.R_INVALID_ID;
    return if (window.*.root != null) window.*.root.*.id else raven.R_INVALID_ID;
}

export fn Rwindow_set_title(id: raven.Rid, title: [*c]const u8) void {
    const window = rvn_window_check(id, "Rwindow_set_title");
    if (window == null) return;
    if (base.rvn_str_set(&window.*.title, orEmpty(title)) == 0) return;
    platform().*.window_set_title.?(window.*.platform, window.*.title);
    // a header bar shows it
    window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_get_title(id: raven.Rid) [*c]const u8 {
    const window = rvn_window_check(id, "Rwindow_get_title");
    if (window == null) return "";
    return orEmpty(window.*.title);
}

export fn Rwindow_set_size(id: raven.Rid, width: c_int, height: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_size");
    if (window == null) return;
    if (width <= 0 or height <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwindow_set_size: invalid size");
        return;
    }
    platform().*.window_set_size.?(window.*.platform, @intFromFloat(@as(f32, @floatFromInt(width)) * window.*.scale + 0.5), @intFromFloat(@as(f32, @floatFromInt(height)) * window.*.scale + 0.5));
}

export fn Rwindow_get_size(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) void {
    if (width != null) width.* = 0;
    if (height != null) height.* = 0;
    const window = rvn_window_check(id, "Rwindow_get_size");
    if (window == null) return;
    const size = rvn_window_size(window);
    if (width != null) width.* = @intFromFloat(size.x + 0.5);
    if (height != null) height.* = @intFromFloat(size.y + 0.5);
}

export fn Rwindow_set_min_size(id: raven.Rid, width: c_int, height: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_min_size");
    if (window == null) return;
    platform().*.window_set_min_size.?(window.*.platform, @intFromFloat(@as(f32, @floatFromInt(base.rvn_maxi(width, 0))) * window.*.scale + 0.5), @intFromFloat(@as(f32, @floatFromInt(base.rvn_maxi(height, 0))) * window.*.scale + 0.5));
}

export fn Rwindow_set_position(id: raven.Rid, x: c_int, y: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_position");
    if (window == null) return;
    platform().*.window_set_position.?(window.*.platform, x, y);
}

export fn Rwindow_get_position(id: raven.Rid, x: [*c]c_int, y: [*c]c_int) void {
    var px: c_int = 0;
    var py: c_int = 0;
    if (x != null) x.* = 0;
    if (y != null) y.* = 0;
    const window = rvn_window_check(id, "Rwindow_get_position");
    if (window == null) return;
    platform().*.window_get_position.?(window.*.platform, &px, &py);
    if (x != null) x.* = px;
    if (y != null) y.* = py;
}

export fn Rwindow_get_framebuffer_size(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) void {
    if (width != null) width.* = 0;
    if (height != null) height.* = 0;
    const window = rvn_window_check(id, "Rwindow_get_framebuffer_size");
    if (window == null) return;
    if (width != null) width.* = window.*.width_px;
    if (height != null) height.* = window.*.height_px;
}

export fn Rwindow_get_scale(id: raven.Rid) f32 {
    const window = rvn_window_check(id, "Rwindow_get_scale");
    if (window == null) return 1.0;
    return window.*.scale;
}

export fn Rwindow_show(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_show");
    if (window == null) return;
    window.*.visible = raven.R_TRUE;
    window.*.needs_paint = raven.R_TRUE;
    platform().*.window_show.?(window.*.platform, raven.R_TRUE);
}

export fn Rwindow_hide(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_hide");
    if (window == null) return;
    window.*.visible = raven.R_FALSE;
    platform().*.window_show.?(window.*.platform, raven.R_FALSE);
}

export fn Rwindow_maximize(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_maximize");
    if (window == null) return;
    platform().*.window_set_state.?(window.*.platform, plat_h.RVN_PWINDOW_MAXIMIZED);
}

export fn Rwindow_minimize(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_minimize");
    if (window == null) return;
    platform().*.window_set_state.?(window.*.platform, plat_h.RVN_PWINDOW_MINIMIZED);
}

export fn Rwindow_restore(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_restore");
    if (window == null) return;
    platform().*.window_set_state.?(window.*.platform, plat_h.RVN_PWINDOW_NORMAL);
}

export fn Rwindow_is_maximized(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_is_maximized");
    if (window == null) return raven.R_FALSE;
    return if (window.*.state == plat_h.RVN_PWINDOW_MAXIMIZED) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_is_minimized(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_is_minimized");
    if (window == null) return raven.R_FALSE;
    return if (window.*.state == plat_h.RVN_PWINDOW_MINIMIZED) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_is_active(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_is_active");
    if (window == null) return raven.R_FALSE;
    return window.*.active;
}

export fn Rwindow_close(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_close");
    if (window == null) return;
    rvn_window_request_close(window);
}

export fn Rwindow_begin_move(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_begin_move");
    if (window == null) return;
    ctx_h.rvn_dispatch_begin();
    rvn_window_lose_pointer(window);
    if (window.*.dead == 0) platform().*.window_begin_move.?(window.*.platform);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_begin_resize(id: raven.Rid, edge: raven.RWindowEdge) void {
    const regions = [_]rvn_pregion_t{
        plat_h.RVN_PREGION_LEFT,     plat_h.RVN_PREGION_RIGHT,     plat_h.RVN_PREGION_TOP,         plat_h.RVN_PREGION_BOTTOM,
        plat_h.RVN_PREGION_TOP_LEFT, plat_h.RVN_PREGION_TOP_RIGHT, plat_h.RVN_PREGION_BOTTOM_LEFT, plat_h.RVN_PREGION_BOTTOM_RIGHT,
    };
    const window = rvn_window_check(id, "Rwindow_begin_resize");
    if (window == null) return;
    if (edge < raven.R_EDGE_LEFT or edge > raven.R_EDGE_BOTTOM_RIGHT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwindow_begin_resize: invalid edge");
        return;
    }
    if ((window.*.window_flags & raven.R_WINDOW_NO_RESIZE) != 0 or window.*.state == plat_h.RVN_PWINDOW_MAXIMIZED) return;
    ctx_h.rvn_dispatch_begin();
    rvn_window_lose_pointer(window);
    if (window.*.dead == 0) platform().*.window_begin_resize.?(window.*.platform, regions[edge - raven.R_EDGE_LEFT]);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_set_drop_callback(id: raven.Rid, callback: raven.RDropCallback, user_data: ?*anyopaque) void {
    const window = rvn_window_check(id, "Rwindow_set_drop_callback");
    if (window == null) return;
    window.*.drop_callback = callback;
    window.*.drop_user = user_data;
}

export fn Rwindow_set_clear_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const window = rvn_window_check(id, "Rwindow_set_clear_color");
    if (window == null) return;
    window.*.has_clear_color = raven.R_TRUE;
    window.*.clear_color[0] = r;
    window.*.clear_color[1] = g;
    window.*.clear_color[2] = b;
    window.*.clear_color[3] = a;
    window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_set_background(id: raven.Rid, texture: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_set_background");
    if (window == null) return;
    if (texture != raven.R_INVALID_ID and renderer_h.rvn_texture_get(texture) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rwindow_set_background: invalid texture");
        return;
    }
    window.*.background = texture;
    window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_request_redraw(id: raven.Rid) void {
    if (ctx_h.g_rvn.initialized == 0) return;
    if (raven.Ris_ui_thread() == 0) {
        // the window table belongs to the UI thread: ask for every window instead
        thread_h.rvn_atomic_store(&ctx_h.g_rvn.redraw_all, 1);
        ctx_h.rvn_wake();
        return;
    }
    const window = rvn_window_get(id);
    if (window != null) thread_h.rvn_atomic_store(&window.*.redraw_requested, 1);
}

export fn Rwindow_set_continuous_redraw(id: raven.Rid, enabled: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_continuous_redraw");
    if (window == null) return;
    window.*.continuous = if (enabled != 0) raven.R_TRUE else raven.R_FALSE;
    if (enabled != 0) window.*.needs_paint = raven.R_TRUE;
}

export fn Rwindow_set_close_callback(id: raven.Rid, callback: raven.RWindowCloseCallback, user_data: ?*anyopaque) void {
    const window = rvn_window_check(id, "Rwindow_set_close_callback");
    if (window == null) return;
    window.*.close_callback = callback;
    window.*.close_user = user_data;
}

export fn Rwindow_set_resize_callback(id: raven.Rid, callback: raven.RWindowResizeCallback, user_data: ?*anyopaque) void {
    const window = rvn_window_check(id, "Rwindow_set_resize_callback");
    if (window == null) return;
    window.*.resize_callback = callback;
    window.*.resize_user = user_data;
}

export fn Rwindow_set_user_handle(id: raven.Rid, handle: ?*anyopaque) void {
    const window = rvn_window_check(id, "Rwindow_set_user_handle");
    if (window == null) return;
    window.*.user_handle = handle;
}

export fn Rwindow_get_user_handle(id: raven.Rid) ?*anyopaque {
    const window = rvn_window_check(id, "Rwindow_get_user_handle");
    if (window == null) return null;
    return window.*.user_handle;
}

export fn Rwindow_get_native_handle(id: raven.Rid, native: [*c]raven.RNativeWindow) c_int {
    const window = rvn_window_check(id, "Rwindow_get_native_handle");
    if (window == null) return raven.R_FALSE;
    if (native == null) return raven.R_FALSE;
    native.* = std.mem.zeroes(raven.RNativeWindow);
    platform().*.window_get_native.?(window.*.platform, native);
    return if (native.*.system != raven.R_WINDOW_SYSTEM_NONE) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_capture(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    if (width != null) width.* = 0;
    if (height != null) height.* = 0;
    const window = rvn_window_check(id, "Rwindow_capture");
    if (window == null) return null;
    var capture = std.mem.zeroes(raven.RCapture);
    if (window.*.needs_layout != 0) rvn_window_layout(window);
    rvn_window_paint(window, &capture);
    // the capture structure lives on this stack: wait for the render thread
    renderer_h.rvn_renderer_sync();
    if (width != null) width.* = capture.width;
    if (height != null) height.* = capture.height;
    return capture.pixels;
}

export fn Rwindow_get_frame_stats(id: raven.Rid, stats: [*c]raven.RFrameStats) void {
    if (stats == null) return;
    stats.* = std.mem.zeroes(raven.RFrameStats);
    const window = rvn_window_check(id, "Rwindow_get_frame_stats");
    if (window != null) stats.* = window.*.stats;
}

// ---------------------------------------------------------------------------
//  Public API: input state and synthetic input
// ---------------------------------------------------------------------------

export fn Rwindow_get_focused_widget(id: raven.Rid) raven.Rid {
    const window = rvn_window_check(id, "Rwindow_get_focused_widget");
    if (window == null) return raven.R_INVALID_ID;
    return if (window.*.focus != null) window.*.focus.*.id else raven.R_INVALID_ID;
}

export fn Rwindow_get_hovered_widget(id: raven.Rid) raven.Rid {
    const window = rvn_window_check(id, "Rwindow_get_hovered_widget");
    if (window == null) return raven.R_INVALID_ID;
    return if (window.*.hover != null) window.*.hover.*.id else raven.R_INVALID_ID;
}

export fn Rwindow_get_mouse_position(id: raven.Rid, x: [*c]f32, y: [*c]f32) void {
    if (x != null) x.* = 0.0;
    if (y != null) y.* = 0.0;
    const window = rvn_window_check(id, "Rwindow_get_mouse_position");
    if (window == null) return;
    if (x != null) x.* = window.*.mouse_x;
    if (y != null) y.* = window.*.mouse_y;
}

/// Synthetic input acts on the current layout, like real input does.
fn rvn_window_inject_begin(id: raven.Rid, function: [*c]const u8) [*c]rvn_window_t {
    const window = rvn_window_check(id, function);
    if (window == null) return null;
    if (window.*.needs_layout != 0) rvn_window_layout(window);
    ctx_h.rvn_dispatch_begin();
    return window;
}

export fn Rwindow_inject_mouse_move(id: raven.Rid, x: f32, y: f32) void {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_mouse_move");
    if (window == null) return;
    rvn_window_mouse_move(window, x, y);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_inject_mouse_button(id: raven.Rid, button: raven.RMouseButton, pressed: c_int) void {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_mouse_button");
    if (window == null) return;
    rvn_window_mouse_button(window, button, pressed);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_inject_mouse_wheel(id: raven.Rid, wheel_x: f32, wheel_y: f32) void {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_mouse_wheel");
    if (window == null) return;
    rvn_window_mouse_wheel(window, wheel_x, wheel_y);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_inject_key(id: raven.Rid, key: raven.RKey, pressed: c_int, modifiers: raven.Ruint) void {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_key");
    if (window == null) return;
    rvn_window_key(window, key, pressed, modifiers, raven.R_FALSE);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_inject_text(id: raven.Rid, text: [*c]const u8) void {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_text");
    if (window == null) return;
    var cursor: [*c]const u8 = text;
    const end: [*c]const u8 = if (text != null) text + libc.strlen(text) else null;
    while (text != null and cursor < end and window.*.dead == 0) {
        rvn_window_text(window, base.rvn_utf8_decode(&cursor, end));
    }
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_inject_drag(id: raven.Rid, x: f32, y: f32, inside: c_int) c_int {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_drag");
    if (window == null) return raven.R_FALSE;
    const accepted = rvn_window_drag(window, x, y, inside);
    ctx_h.rvn_dispatch_end();
    return accepted;
}

export fn Rwindow_inject_drop(id: raven.Rid, x: f32, y: f32, paths: [*c]const [*c]const u8, path_count: c_int, text: [*c]const u8) c_int {
    const window = rvn_window_inject_begin(id, "Rwindow_inject_drop");
    if (window == null) return raven.R_FALSE;
    const taken = rvn_window_drop(window, x, y, if (path_count > 0) paths else null, if (path_count > 0) path_count else 0, text);
    ctx_h.rvn_dispatch_end();
    return taken;
}

export fn Rwindow_register_shortcut(id: raven.Rid, key: raven.RKey, modifiers: raven.Ruint, action: [*c]const u8) void {
    const window = rvn_window_check(id, "Rwindow_register_shortcut");
    if (window == null) return;
    if (action == null or action[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwindow_register_shortcut: empty action name");
        return;
    }
    rvn_window_add_shortcut(window, key, modifiers & 0xF, action);
}

export fn Rwindow_unregister_shortcut(id: raven.Rid, key: raven.RKey, modifiers: raven.Ruint) void {
    const window = rvn_window_check(id, "Rwindow_unregister_shortcut");
    if (window == null) return;
    rvn_window_remove_shortcut(window, key, modifiers & 0xF);
}

export fn Rwindow_close_popups(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rwindow_close_popups");
    if (window == null) return;
    rvn_window_close_popups(window);
}

// ---------------------------------------------------------------------------
//  Raw input state
// ---------------------------------------------------------------------------

export fn Rwindow_is_key_down(id: raven.Rid, key: raven.RKey) c_int {
    const window = rvn_window_check(id, "Rwindow_is_key_down");
    const key_i: c_int = @bitCast(key);
    if (window == null or key_i <= 0 or key_i >= raven.R_KEY_COUNT) return raven.R_FALSE;
    return if (window.*.keys[key] != 0) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_is_mouse_button_down(id: raven.Rid, button: raven.RMouseButton) c_int {
    const window = rvn_window_check(id, "Rwindow_is_mouse_button_down");
    const button_i: c_int = @bitCast(button);
    if (window == null or button_i < 0 or button_i > raven.R_MOUSE_X2) return raven.R_FALSE;
    const shift: u5 = @intCast(button);
    return if ((window.*.buttons & (@as(u32, 1) << shift)) != 0) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_get_modifiers(id: raven.Rid) raven.Ruint {
    const window = rvn_window_check(id, "Rwindow_get_modifiers");
    return if (window != null) window.*.modifiers else 0;
}

export fn Rwindow_is_mouse_inside(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_is_mouse_inside");
    return if (window != null) window.*.mouse_inside else raven.R_FALSE;
}

export fn Rwindow_set_tab_navigation(id: raven.Rid, enabled: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_tab_navigation");
    if (window != null) window.*.tab_navigation = if (enabled != 0) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_set_event_hook(id: raven.Rid, hook: raven.RWindowEventHook, user_data: ?*anyopaque) void {
    const window = rvn_window_check(id, "Rwindow_set_event_hook");
    if (window == null) return;
    window.*.event_hook = hook;
    window.*.event_hook_user = user_data;
}

export fn Rwindow_has_popup(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_has_popup");
    return if (window != null and window.*.popup_count > 0) raven.R_TRUE else raven.R_FALSE;
}

export fn Rwindow_wants_text_input(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rwindow_wants_text_input");
    if (window == null or window.*.focus == null or (window.*.focus.*.flags & widget_h.RVN_WF_DEAD) != 0) return raven.R_FALSE;
    const type_ = window.*.focus.*.cls.*.type;
    return if (type_ == raven.R_WIDGET_TEXT_INPUT or type_ == raven.R_WIDGET_TEXT_EDITOR or type_ == raven.R_WIDGET_SPIN_BOX) raven.R_TRUE else raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Drag and drop inside the application
// ---------------------------------------------------------------------------

export fn Rdrag_begin(source: raven.Rid, @"type": [*c]const u8, data: [*c]const u8, label: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rdrag_begin") == 0) return raven.R_FALSE;
    const widget = widget_h.rvn_widget_get(source);
    if (widget == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rdrag_begin: invalid widget handle 0x%08X", @as(c_uint, source));
        return raven.R_FALSE;
    }
    const window = widget.*.window;
    if (window == null or window.*.dead != 0) return raven.R_FALSE;
    if (window.*.drag_active != 0) rvn_window_drag_cancel(window);
    window.*.drag_active = raven.R_TRUE;
    window.*.drag_type = base.rvn_strdup(orEmpty(@"type"));
    window.*.drag_data = base.rvn_strdup(orEmpty(data));
    window.*.drag_label = base.rvn_strdup(orEmpty(label));
    window.*.drag_source = source;
    // the widget that started it no longer follows the pointer
    window.*.capture = null;
    rvn_window_tooltip_hide(window);
    _ = rvn_window_drag(window, window.*.mouse_x, window.*.mouse_y, raven.R_TRUE);
    window.*.needs_paint = raven.R_TRUE;
    return raven.R_TRUE;
}

export fn Rdrag_is_active(id: raven.Rid) c_int {
    const window = rvn_window_check(id, "Rdrag_is_active");
    return if (window != null) window.*.drag_active else raven.R_FALSE;
}

export fn Rdrag_get_type(id: raven.Rid) [*c]const u8 {
    const window = rvn_window_check(id, "Rdrag_get_type");
    return if (window != null and window.*.drag_active != 0) window.*.drag_type else null;
}

export fn Rdrag_get_data(id: raven.Rid) [*c]const u8 {
    const window = rvn_window_check(id, "Rdrag_get_data");
    return if (window != null and window.*.drag_active != 0) window.*.drag_data else null;
}

export fn Rdrag_cancel(id: raven.Rid) void {
    const window = rvn_window_check(id, "Rdrag_cancel");
    if (window == null) return;
    ctx_h.rvn_dispatch_begin();
    rvn_window_drag_cancel(window);
    ctx_h.rvn_dispatch_end();
}

export fn Rwindow_set_icon(id: raven.Rid, rgba: [*c]const u8, width: c_int, height: c_int) void {
    const window = rvn_window_check(id, "Rwindow_set_icon");
    if (window == null or window.*.platform == null or platform().*.window_set_icon == null) return;
    platform().*.window_set_icon.?(window.*.platform, rgba, width, height);
}

// ---------------------------------------------------------------------------
//  Scale of the interface
// ---------------------------------------------------------------------------

export fn Rset_vsync(enabled_: c_int) void {
    if (ctx_h.rvn_api_check("Rset_vsync") == 0) return;
    const enabled: c_int = if (enabled_ != 0) raven.R_TRUE else raven.R_FALSE;
    if (enabled == ctx_h.g_rvn.vsync) return;
    ctx_h.g_rvn.vsync = enabled;
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window != null) Rwindow_request_redraw(window.*.id);
    }
}

export fn Rget_vsync() c_int {
    return ctx_h.g_rvn.vsync;
}

export fn Rset_ui_scale(scale_: f32) void {
    if (ctx_h.rvn_api_check("Rset_ui_scale") == 0) return;
    var scale = scale_;
    if (!(scale > 0.0)) scale = 1.0;
    scale = base.rvn_clampf(scale, 0.25, 4.0);
    if (scale == ctx_h.g_rvn.ui_scale) return;
    ctx_h.g_rvn.ui_scale = scale;
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window == null or window.*.dead != 0 or window.*.platform == null) continue;
        const platform_scale = platform().*.window_get_scale.?(window.*.platform);
        window.*.scale = (if (platform_scale > 0.0) platform_scale else 1.0) * ctx_h.g_rvn.ui_scale;
        rvn_window_close_popups(window);
    }
    rvn_invalidate_all_windows();
    // the glyphs are rasterized for the new sizes
    rvn_repaint_all_windows();
}

export fn Rget_ui_scale() f32 {
    return if (ctx_h.g_rvn.ui_scale > 0.0) ctx_h.g_rvn.ui_scale else 1.0;
}

export fn rvn_window_pointer(window_: ?*const anyopaque, x: [*c]f32, y: [*c]f32, buttons: [*c]u32) c_int {
    const window: [*c]const rvn_window_t = @ptrCast(@alignCast(window_));
    x.* = window.*.mouse_x;
    y.* = window.*.mouse_y;
    buttons.* = window.*.buttons;
    return if (window.*.mouse_inside != 0 and window.*.dead == 0) raven.R_TRUE else raven.R_FALSE;
}

export fn rvn_windows_throttle() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window = asWindow(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i));
        if (window != null and rvn_window_wants_frame(window) != 0) renderer_h.rvn_renderer_throttle(&window.*.frames_in_flight, RVN_MAX_FRAMES_IN_FLIGHT);
    }
}

// ---------------------------------------------------------------------------
//  Deprecated: Raven no longer has editions nor a watermark (it is open source,
//  Apache License 2.0). Kept so that programs and bindings built against older
//  versions still compile and link.
// ---------------------------------------------------------------------------

export fn Ris_free_edition() c_int {
    return raven.R_FALSE;
}

export fn Rwindow_get_watermark_rect(id: raven.Rid, x: [*c]f32, y: [*c]f32, width: [*c]f32, height: [*c]f32) c_int {
    _ = id;
    if (x != null) x.* = 0.0;
    if (y != null) y.* = 0.0;
    if (width != null) width.* = 0.0;
    if (height != null) height.* = 0.0;
    return raven.R_FALSE;
}
