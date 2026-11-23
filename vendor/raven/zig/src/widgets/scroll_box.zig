// Translated to Zig from vendor/raven/src/widgets/scroll_box.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/scroll_box.c
// ScrollBox (Slate SScrollBox): children stacked along one axis inside a
// clipped, scrollable area.
//
// Scrolling only moves the children: their own layout is untouched, so the
// cost of a scroll step does not depend on what the children contain.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const RVN_SCROLL_WHEEL_STEP: f32 = 48.0;

const rvn_scroll_box_t = extern struct {
    base: widget_h.rvn_widget_t,
    spacing: f32,
    orientation: raven.ROrientation,
    scroll_both: c_int,
    /// Along the stacking direction / across it.
    main_bar: common.rvn_scrollbar_t,
    cross_bar: common.rvn_scrollbar_t,
};

fn rvn_scroll_box_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    box.*.orientation = raven.R_VERTICAL;
}

fn rvn_scroll_box_vertical(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const box: [*c]const rvn_scroll_box_t = @ptrCast(widget);
    return @intFromBool(box.*.orientation == raven.R_VERTICAL);
}

/// Size of the stacked children: x = along the axis, y = across.
fn rvn_scroll_box_content(widget: [*c]widget_h.rvn_widget_t) base.rvn_vec2_t {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    const vertical = rvn_scroll_box_vertical(widget);
    var main: f32 = 0.0;
    var cross: f32 = 0.0;
    var i: u32 = 0;
    var visible: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        main += if (vertical != 0) size.y else size.x;
        cross = base.rvn_maxf(cross, if (vertical != 0) size.x else size.y);
        visible += 1;
    }
    if (visible > 1) main += box.*.spacing * @as(f32, @floatFromInt(visible - 1));
    return base.rvn_vec2(main, cross);
}

fn rvn_scroll_box_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    // asks for the whole content; it scrolls when the parent gives less
    const content = rvn_scroll_box_content(widget);
    return if (rvn_scroll_box_vertical(widget) != 0) base.rvn_vec2(content.y, content.x) else base.rvn_vec2(content.x, content.y);
}

fn rvn_scroll_box_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    const vertical = rvn_scroll_box_vertical(widget);
    const bar_size = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    var view_main: f32 = if (vertical != 0) widget.*.rect.h else widget.*.rect.w;
    var view_cross: f32 = if (vertical != 0) widget.*.rect.w else widget.*.rect.h;
    const content = rvn_scroll_box_content(widget);

    // a visible scrollbar takes its thickness from the other axis
    if (content.x > view_main + 0.5) view_cross -= bar_size;
    if (box.*.scroll_both != 0 and content.y > view_cross + 0.5) {
        view_main -= bar_size;
        if (content.x > view_main + 0.5 and view_cross == (if (vertical != 0) widget.*.rect.w else widget.*.rect.h)) view_cross -= bar_size;
    }
    view_main = base.rvn_maxf(view_main, 0.0);
    view_cross = base.rvn_maxf(view_cross, 0.0);

    box.*.main_bar.content = content.x;
    box.*.main_bar.viewport = view_main;
    _ = common.rvn_scrollbar_clamp(&box.*.main_bar);
    // without cross scrolling the children are simply as wide as the view
    const cross_size: f32 = if (box.*.scroll_both != 0) base.rvn_maxf(content.y, view_cross) else view_cross;
    box.*.cross_bar.content = cross_size;
    box.*.cross_bar.viewport = view_cross;
    _ = common.rvn_scrollbar_clamp(&box.*.cross_bar);

    var position: f32 = -box.*.main_bar.offset;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        const length = if (vertical != 0) size.y else size.x;
        if (vertical != 0) {
            ext.rvn_widget_arrange_slot(child, base.rvn_rect(-box.*.cross_bar.offset, position, cross_size, length));
        } else {
            ext.rvn_widget_arrange_slot(child, base.rvn_rect(position, -box.*.cross_bar.offset, length, cross_size));
        }
        position += length + box.*.spacing;
    }
}

/// Applies new scroll offsets at once: only the positions of the children change.
fn rvn_scroll_box_apply(widget: [*c]widget_h.rvn_widget_t) void {
    rvn_scroll_box_arrange(widget);
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_scroll_box_tracks(widget: [*c]const widget_h.rvn_widget_t, main_track: [*c]base.rvn_rect_t, cross_track: [*c]base.rvn_rect_t) void {
    const box: [*c]const rvn_scroll_box_t = @ptrCast(widget);
    const bar_size = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    const cross_needed = common.rvn_scrollbar_needed(&box.*.cross_bar);
    const main_needed = common.rvn_scrollbar_needed(&box.*.main_bar);
    if (rvn_scroll_box_vertical(widget) != 0) {
        main_track.* = base.rvn_rect(widget.*.rect.w - bar_size, 0.0, bar_size, widget.*.rect.h - (if (cross_needed != 0) bar_size else 0.0));
        cross_track.* = base.rvn_rect(0.0, widget.*.rect.h - bar_size, widget.*.rect.w - (if (main_needed != 0) bar_size else 0.0), bar_size);
    } else {
        main_track.* = base.rvn_rect(0.0, widget.*.rect.h - bar_size, widget.*.rect.w - (if (cross_needed != 0) bar_size else 0.0), bar_size);
        cross_track.* = base.rvn_rect(widget.*.rect.w - bar_size, 0.0, bar_size, widget.*.rect.h - (if (main_needed != 0) bar_size else 0.0));
    }
}

// Nothing of its own to draw: only moves the children from where the layout
// put them (the offset) to where the scrolling is drawn this frame.
fn rvn_scroll_box_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    var main: f32 = box.*.main_bar.offset - common.rvn_scrollbar_shown(&box.*.main_bar, painter);
    var cross: f32 = box.*.cross_bar.offset - common.rvn_scrollbar_shown(&box.*.cross_bar, painter);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    // whole pixels: scrolled text stays sharp
    main = @floor(main * dp.scale + 0.5) / dp.scale;
    cross = @floor(cross * dp.scale + 0.5) / dp.scale;
    if (rvn_scroll_box_vertical(widget) != 0) {
        widget.*.child_shift = base.rvn_vec2(cross, main);
    } else {
        widget.*.child_shift = base.rvn_vec2(main, cross);
    }
}

fn rvn_scroll_box_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    var main_track: base.rvn_rect_t = undefined;
    var cross_track: base.rvn_rect_t = undefined;
    const origin = ext.rvn_widget_origin(widget);
    const mouse_x: f32 = if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0;
    const mouse_y: f32 = if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0;
    const vertical = rvn_scroll_box_vertical(widget);

    rvn_scroll_box_tracks(widget, &main_track, &cross_track);
    common.rvn_scrollbar_paint(&box.*.main_bar, widget, painter, main_track, vertical, mouse_x, mouse_y);
    common.rvn_scrollbar_paint(&box.*.cross_bar, widget, painter, cross_track, if (vertical != 0) 0 else 1, mouse_x, mouse_y);
}

fn rvn_scroll_box_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    var main_track: base.rvn_rect_t = undefined;
    var cross_track: base.rvn_rect_t = undefined;
    const vertical = rvn_scroll_box_vertical(widget);
    var changed: c_int = raven.R_FALSE;
    var used: c_int = undefined;

    switch (event.*.type) {
        raven.R_EVENT_MOUSE_WHEEL => {
            // the wheel scrolls vertically; with Shift, or on a horizontal box, horizontally
            var along: f32 = if (vertical != 0) event.*.wheel_y else (if (event.*.wheel_y != 0.0) event.*.wheel_y else event.*.wheel_x);
            var across: f32 = if (vertical != 0) event.*.wheel_x else 0.0;
            if ((event.*.modifiers & @as(c_uint, @intCast(raven.R_MOD_SHIFT))) != 0) {
                across = along;
                along = 0.0;
            }
            if (along != 0.0) changed |= common.rvn_scrollbar_wheel(&box.*.main_bar, -along * RVN_SCROLL_WHEEL_STEP);
            if (across != 0.0) changed |= common.rvn_scrollbar_wheel(&box.*.cross_bar, -across * RVN_SCROLL_WHEEL_STEP);
            if (changed != 0) {
                rvn_scroll_box_apply(widget);
            } else {
                ext.rvn_widget_invalidate_paint(widget);
            }
            // at the end of its range, the wheel goes to the scroll box above
            return changed;
        },
        raven.R_EVENT_MOUSE_DOWN, raven.R_EVENT_MOUSE_MOVE, raven.R_EVENT_MOUSE_UP => {
            rvn_scroll_box_tracks(widget, &main_track, &cross_track);
            used = common.rvn_scrollbar_event(&box.*.main_bar, widget, event, main_track, vertical, &changed);
            if (used == 0) used = common.rvn_scrollbar_event(&box.*.cross_bar, widget, event, cross_track, if (vertical != 0) 0 else 1, &changed);
            if (changed != 0) {
                rvn_scroll_box_apply(widget);
            } else if (used != 0 or event.*.type == raven.R_EVENT_MOUSE_MOVE) {
                ext.rvn_widget_invalidate_paint(widget);
            }
            return used;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_scroll_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Orientation") == 0) {
        if (ext.rvn_parse_orientation(value, &box.*.orientation) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "ScrollBoth") == 0) {
        if (ext.rvn_parse_bool(value, &box.*.scroll_both) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &box.*.spacing) == 0) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_scroll_box: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .type = raven.R_WIDGET_SCROLL_BOX,
    .name = "ScrollBox",
    .size = @sizeOf(rvn_scroll_box_t),
    .flags = widget_h.RVN_CF_CLIP | widget_h.RVN_CF_NO_MIRROR,
    .init = rvn_scroll_box_init,
    .measure = rvn_scroll_box_measure,
    .arrange = rvn_scroll_box_arrange,
    .paint = rvn_scroll_box_paint,
    .paint_overlay = rvn_scroll_box_paint_overlay,
    .event = rvn_scroll_box_event,
    .set_attribute = rvn_scroll_box_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/// Offsets are validated against the current layout.
fn rvn_scroll_box_sync(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) ext.rvn_window_layout(widget.*.window);
}

export fn Rscroll_box_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SCROLL_BOX, "Rscroll_box_set_orientation");
    if (widget == null) return;
    if (orientation != raven.R_HORIZONTAL and orientation != raven.R_VERTICAL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rscroll_box_set_orientation: invalid orientation");
        return;
    }
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    box.*.orientation = orientation;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rscroll_box_set_scroll_both(id: raven.Rid, enabled: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SCROLL_BOX, "Rscroll_box_set_scroll_both");
    if (widget == null) return;
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    box.*.scroll_both = @intFromBool(enabled != 0);
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rscroll_box_set_offset(id: raven.Rid, x: f32, y: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SCROLL_BOX, "Rscroll_box_set_offset");
    if (widget == null) return;
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    const vertical = rvn_scroll_box_vertical(widget);
    rvn_scroll_box_sync(widget);
    _ = common.rvn_scrollbar_set(&box.*.main_bar, if (vertical != 0) y else x);
    _ = common.rvn_scrollbar_set(&box.*.cross_bar, if (vertical != 0) x else y);
    rvn_scroll_box_apply(widget);
}

export fn Rscroll_box_get_offset(id: raven.Rid, x: [*c]f32, y: [*c]f32) void {
    if (x != null) x.* = 0.0;
    if (y != null) y.* = 0.0;
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SCROLL_BOX, "Rscroll_box_get_offset");
    if (widget == null) return;
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    const vertical = rvn_scroll_box_vertical(widget);
    if (x != null) x.* = if (vertical != 0) box.*.cross_bar.offset else box.*.main_bar.offset;
    if (y != null) y.* = if (vertical != 0) box.*.main_bar.offset else box.*.cross_bar.offset;
}

export fn Rscroll_box_scroll_to_end(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SCROLL_BOX, "Rscroll_box_scroll_to_end");
    if (widget == null) return;
    const box: [*c]rvn_scroll_box_t = @ptrCast(widget);
    rvn_scroll_box_sync(widget);
    _ = common.rvn_scrollbar_set(&box.*.main_bar, common.rvn_scrollbar_max(&box.*.main_bar));
    rvn_scroll_box_apply(widget);
}

export fn Rwidget_scroll_into_view(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_scroll_into_view");
    if (widget == null) return;
    rvn_scroll_box_sync(widget);
    var target: [*c]widget_h.rvn_widget_t = widget;
    // every scroll box above the widget brings it into its own view
    var ancestor: [*c]widget_h.rvn_widget_t = widget.*.parent;
    while (ancestor != null) : (ancestor = ancestor.*.parent) {
        if (ancestor.*.cls.*.type != raven.R_WIDGET_SCROLL_BOX) continue;
        const box: [*c]rvn_scroll_box_t = @ptrCast(ancestor);
        const vertical = rvn_scroll_box_vertical(ancestor);
        const inner = ext.rvn_widget_origin(target);
        const outer = ext.rvn_widget_origin(ancestor);
        const start: f32 = (if (vertical != 0) inner.y - outer.y else inner.x - outer.x) + box.*.main_bar.offset;
        const end: f32 = start + (if (vertical != 0) target.*.rect.h else target.*.rect.w);
        if (start < box.*.main_bar.offset) {
            _ = common.rvn_scrollbar_set(&box.*.main_bar, start);
        } else if (end > box.*.main_bar.offset + box.*.main_bar.viewport) {
            _ = common.rvn_scrollbar_set(&box.*.main_bar, end - box.*.main_bar.viewport);
        }
        rvn_scroll_box_apply(ancestor);
        target = ancestor;
    }
}
