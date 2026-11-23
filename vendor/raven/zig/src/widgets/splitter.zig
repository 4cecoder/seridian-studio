// Translated to Zig from vendor/raven/src/widgets/splitter.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/splitter.c
// Splitter (Slate SSplitter): panes separated by handles the user can drag.
// The relative size of a pane is the fill coefficient of its slot.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_splitter_t = extern struct {
    base: widget_h.rvn_widget_t,
    orientation: raven.ROrientation,
    min_pane: f32,
    /// Handle under the cursor / being dragged (index of the pane before it), or -1.
    hot_handle: c_int,
    drag_handle: c_int,
    /// Cursor position along the axis when the drag started, and the two pane sizes then.
    drag_origin: f32,
    drag_before: f32,
    drag_after: f32,
};

fn rvn_splitter_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    splitter.*.orientation = raven.R_HORIZONTAL;
    splitter.*.min_pane = 24.0;
    splitter.*.hot_handle = -1;
    splitter.*.drag_handle = -1;
}

fn rvn_splitter_horizontal(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const splitter: [*c]const rvn_splitter_t = @ptrCast(widget);
    return @intFromBool(splitter.*.orientation == raven.R_HORIZONTAL);
}

fn rvn_splitter_pane_count(widget: [*c]const widget_h.rvn_widget_t) u32 {
    var i: u32 = 0;
    var count: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget_h.rvn_widget_collapsed(widget.*.children[i]) == 0) count += 1;
    }
    return count;
}

fn rvn_splitter_weight(child: [*c]const widget_h.rvn_widget_t) f32 {
    return if (child.*.slot.fill > 0.0) child.*.slot.fill else 0.0001;
}

fn rvn_splitter_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const horizontal = rvn_splitter_horizontal(widget) != 0;
    const handle = ext.rvn_widget_metric(widget, raven.R_METRIC_SPLITTER_SIZE);
    var main: f32 = 0.0;
    var cross: f32 = 0.0;
    var i: u32 = 0;
    var panes: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        main += if (horizontal) size.x else size.y;
        cross = base.rvn_maxf(cross, if (horizontal) size.y else size.x);
        panes += 1;
    }
    if (panes > 1) main += handle * @as(f32, @floatFromInt(panes - 1));
    return if (horizontal) base.rvn_vec2(main, cross) else base.rvn_vec2(cross, main);
}

fn rvn_splitter_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const horizontal = rvn_splitter_horizontal(widget) != 0;
    const handle = ext.rvn_widget_metric(widget, raven.R_METRIC_SPLITTER_SIZE);
    const main_size: f32 = if (horizontal) widget.*.rect.w else widget.*.rect.h;
    const cross_size: f32 = if (horizontal) widget.*.rect.h else widget.*.rect.w;
    const panes = rvn_splitter_pane_count(widget);
    var i: u32 = 0;
    var seen: u32 = 0;
    var total: f32 = 0.0;
    var position: f32 = 0.0;

    if (panes == 0) return;
    const available = base.rvn_maxf(0.0, main_size - handle * @as(f32, @floatFromInt(panes - 1)));
    while (i < widget.*.child_count) : (i += 1) {
        if (widget_h.rvn_widget_collapsed(widget.*.children[i]) == 0) total += rvn_splitter_weight(widget.*.children[i]);
    }
    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        seen += 1;
        // the last pane takes what is left, so rounding never leaves a gap
        const size: f32 = if (seen == panes) base.rvn_maxf(0.0, main_size - position) else @floor(available * rvn_splitter_weight(child) / total + 0.5);
        if (horizontal) {
            ext.rvn_widget_arrange_slot(child, base.rvn_rect(position, 0.0, size, cross_size));
        } else {
            ext.rvn_widget_arrange_slot(child, base.rvn_rect(0.0, position, cross_size, size));
        }
        position += size + handle;
    }
}

/// Rectangle of the handle that follows the visible pane number `index`.
fn rvn_splitter_handle_rect(widget: [*c]const widget_h.rvn_widget_t, index: c_int, rect: [*c]base.rvn_rect_t, before: [*c][*c]widget_h.rvn_widget_t, after: [*c][*c]widget_h.rvn_widget_t) c_int {
    const horizontal = rvn_splitter_horizontal(widget) != 0;
    const handle = ext.rvn_widget_metric(widget, raven.R_METRIC_SPLITTER_SIZE);
    var previous: [*c]widget_h.rvn_widget_t = null;
    var i: u32 = 0;
    var seen: c_int = -1;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        if (seen == index and previous != null) {
            // slot paddings are part of the pane: the handle starts where the slot ends
            const edge: f32 = if (horizontal)
                previous.*.rect.x + previous.*.rect.w + previous.*.slot.padding.r
            else
                previous.*.rect.y + previous.*.rect.h + previous.*.slot.padding.b;
            rect.* = if (horizontal) base.rvn_rect(edge, 0.0, handle, widget.*.rect.h) else base.rvn_rect(0.0, edge, widget.*.rect.w, handle);
            if (before != null) before.* = previous;
            if (after != null) after.* = child;
            return raven.R_TRUE;
        }
        previous = child;
        seen += 1;
    }
    return raven.R_FALSE;
}

fn rvn_splitter_handle_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const count: c_int = @as(c_int, @intCast(rvn_splitter_pane_count(widget))) - 1;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        var rect: base.rvn_rect_t = undefined;
        if (rvn_splitter_handle_rect(widget, i, &rect, null, null) == 0) continue;
        // a slightly larger target than what is drawn
        rect.x -= 2.0;
        rect.y -= 2.0;
        rect.w += 4.0;
        rect.h += 4.0;
        if (base.rvn_rect_contains(rect, x, y) != 0) return i;
    }
    return -1;
}

fn rvn_splitter_pane_size(widget: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) f32 {
    return if (rvn_splitter_horizontal(widget) != 0)
        child.*.rect.w + child.*.slot.padding.l + child.*.slot.padding.r
    else
        child.*.rect.h + child.*.slot.padding.t + child.*.slot.padding.b;
}

fn rvn_splitter_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    const horizontal = rvn_splitter_horizontal(widget) != 0;
    const along: f32 = if (horizontal) event.*.local_x else event.*.local_y;
    var before: [*c]widget_h.rvn_widget_t = null;
    var after: [*c]widget_h.rvn_widget_t = null;
    var rect: base.rvn_rect_t = undefined;
    var i: u32 = 0;

    switch (event.*.type) {
        raven.R_EVENT_MOUSE_DOWN => {
            const handle = rvn_splitter_handle_at(widget, event.*.local_x, event.*.local_y);
            if (event.*.button != raven.R_MOUSE_LEFT or handle < 0) return raven.R_FALSE;
            if (rvn_splitter_handle_rect(widget, handle, &rect, &before, &after) == 0) return raven.R_FALSE;
            // from now on the weights are the pane sizes in logical units
            i = 0;
            while (i < widget.*.child_count) : (i += 1) {
                const child = widget.*.children[i];
                if (widget_h.rvn_widget_collapsed(child) == 0) child.*.slot.fill = base.rvn_maxf(rvn_splitter_pane_size(widget, child), 0.0001);
            }
            splitter.*.drag_handle = handle;
            splitter.*.drag_origin = along;
            splitter.*.drag_before = before.*.slot.fill;
            splitter.*.drag_after = after.*.slot.fill;
            ext.rvn_widget_capture_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (splitter.*.drag_handle >= 0) {
                const delta = along - splitter.*.drag_origin;
                const total = splitter.*.drag_before + splitter.*.drag_after;
                const minimum = base.rvn_minf(splitter.*.min_pane, total * 0.5);
                if (rvn_splitter_handle_rect(widget, splitter.*.drag_handle, &rect, &before, &after) == 0) return raven.R_TRUE;
                const size = base.rvn_clampf(splitter.*.drag_before + delta, minimum, total - minimum);
                before.*.slot.fill = base.rvn_maxf(size, 0.0001);
                after.*.slot.fill = base.rvn_maxf(total - size, 0.0001);
                ext.rvn_widget_invalidate_layout(widget);
                return raven.R_TRUE;
            } else {
                const handle = rvn_splitter_handle_at(widget, event.*.local_x, event.*.local_y);
                if (handle != splitter.*.hot_handle) {
                    splitter.*.hot_handle = handle;
                    ext.rvn_widget_invalidate_paint(widget);
                }
                widget.*.cursor = if (handle >= 0)
                    @intCast(if (horizontal) raven.R_CURSOR_RESIZE_H else raven.R_CURSOR_RESIZE_V)
                else
                    0;
                return raven.R_FALSE;
            }
        },
        raven.R_EVENT_MOUSE_UP => {
            if (splitter.*.drag_handle < 0 or event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            splitter.*.drag_handle = -1;
            ext.rvn_widget_release_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            if (splitter.*.hot_handle >= 0 and splitter.*.drag_handle < 0) {
                splitter.*.hot_handle = -1;
                widget.*.cursor = 0;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_splitter_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    const horizontal = rvn_splitter_horizontal(widget) != 0;
    const count: c_int = @as(c_int, @intCast(rvn_splitter_pane_count(widget))) - 1;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        var rect: base.rvn_rect_t = undefined;
        const hot = i == splitter.*.drag_handle or (i == splitter.*.hot_handle and splitter.*.drag_handle < 0);
        if (rvn_splitter_handle_rect(widget, i, &rect, null, null) == 0) continue;
        if (hot and widget_h.rvn_widget_glass(widget) != 0) {
            // a short grip in the middle of the handle
            const length = base.rvn_minf(if (horizontal) rect.h else rect.w, 44.0);
            const line: base.rvn_rect_t = if (horizontal)
                base.rvn_rect(rect.x + @floor((rect.w - 4.0) * 0.5), rect.y + (rect.h - length) * 0.5, 4.0, length)
            else
                base.rvn_rect(rect.x + (rect.w - length) * 0.5, rect.y + @floor((rect.h - 4.0) * 0.5), length, 4.0);
            ext.rvn_paint_box(painter, line, 2.0, ext.rvn_widget_color(widget, raven.R_COLOR_HANDLE_HOVERED), 0.0, 0);
        } else if (hot) {
            ext.rvn_paint_rect(painter, rect, ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT));
        } else if (widget_h.rvn_widget_glass(widget) == 0) {
            // at rest, a thin line in the middle of the handle
            const line: base.rvn_rect_t = if (horizontal)
                base.rvn_rect(rect.x + @floor(rect.w * 0.5), rect.y, 1.0, rect.h)
            else
                base.rvn_rect(rect.x, rect.y + @floor(rect.h * 0.5), rect.w, 1.0);
            ext.rvn_paint_rect(painter, line, ext.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
        }
    }
}

fn rvn_splitter_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Orientation") == 0) {
        if (ext.rvn_parse_orientation(value, &splitter.*.orientation) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "MinPaneSize") == 0) {
        if (ext.rvn_parse_float(value, &splitter.*.min_pane) == 0) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_splitter: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SPLITTER,
    .name = "Splitter",
    .size = @sizeOf(rvn_splitter_t),
    .flags = widget_h.RVN_CF_SURFACE,
    .init = rvn_splitter_init,
    .measure = rvn_splitter_measure,
    .arrange = rvn_splitter_arrange,
    .paint_overlay = rvn_splitter_paint_overlay,
    .event = rvn_splitter_event,
    .set_attribute = rvn_splitter_set_attribute,
});

export fn Rsplitter_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPLITTER, "Rsplitter_set_orientation");
    if (widget == null) return;
    if (orientation != raven.R_HORIZONTAL and orientation != raven.R_VERTICAL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rsplitter_set_orientation: invalid orientation");
        return;
    }
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    splitter.*.orientation = orientation;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rsplitter_set_min_pane_size(id: raven.Rid, size: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPLITTER, "Rsplitter_set_min_pane_size");
    if (widget == null) return;
    const splitter: [*c]rvn_splitter_t = @ptrCast(widget);
    splitter.*.min_pane = if (size > 0.0) size else 0.0;
}
