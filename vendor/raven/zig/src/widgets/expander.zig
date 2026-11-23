// Translated to Zig from vendor/raven/src/widgets/expander.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/expander.c
// Expander (Slate SExpandableArea): a clickable header that shows or hides
// one child. Used for the sections of property panels.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_expander_t = extern struct {
    base: widget_h.rvn_widget_t,
    title: [*c]u8,
    expanded: c_int,
    callback: raven.RExpanderChangedCallback,
    user_data: ?*anyopaque,
    /// How much of the content shows, 0 .. 1: the layout follows it while the expander opens or closes.
    open: raven.RSpring,
};

fn rvn_expander_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    expander.*.expanded = raven.R_TRUE;
    ext.rvn_spring_set(&expander.*.open, 1.0);
}

fn rvn_expander_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    base.rvn_free(expander.*.title);
}

fn rvn_expander_header(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT) + 4.0;
}

fn rvn_expander_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    const header = rvn_expander_header(widget);
    var desired: base.rvn_vec2_t = undefined;
    desired.x = header + common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, expander.*.title) +
        ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X);
    desired.y = header;
    if (expander.*.open.value > 0.0 and widget.*.child_count > 0) {
        const child = ext.rvn_widget_measure_slot(widget.*.children[0]);
        desired.x = base.rvn_maxf(desired.x, child.x);
        // the spring runs a little past 1 when it opens: the content below bounces with it
        desired.y += @floor(child.y * expander.*.open.value + 0.5);
    }
    return desired;
}

fn rvn_expander_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    const header = rvn_expander_header(widget);
    const moving = ext.rvn_spring_moving(&expander.*.open, if (expander.*.expanded != 0) 1.0 else 0.0);
    // while it moves, the content keeps its size and is uncovered by the edge of the expander
    if (moving != 0) {
        widget.*.flags |= widget_h.RVN_WF_CLIP;
    } else {
        widget.*.flags &= ~widget_h.RVN_WF_CLIP;
    }
    if (expander.*.open.value > 0.0 and widget.*.child_count > 0 and widget_h.rvn_widget_collapsed(widget.*.children[0]) == 0) {
        var height = base.rvn_maxf(0.0, widget.*.rect.h - header);
        if (moving != 0) height = base.rvn_maxf(height, ext.rvn_widget_measure_slot(widget.*.children[0]).y);
        ext.rvn_widget_arrange_slot(widget.*.children[0], base.rvn_rect(0.0, header, widget.*.rect.w, height));
    }
}

fn rvn_expander_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    _ = child;
    // still drawn while it closes
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    return @as(c_int, @intFromBool(expander.*.open.value > 0.0));
}

fn rvn_expander_set(widget: [*c]widget_h.rvn_widget_t, expanded_: c_int, notify: c_int) void {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    const expanded: c_int = if (expanded_ != 0) 1 else 0;
    if (expander.*.expanded == expanded) return;
    if (expanded == 0 and widget.*.child_count > 0 and widget.*.window != null) {
        ext.rvn_window_forget_widget(widget.*.window, widget.*.children[0]);
    }
    expander.*.expanded = expanded;
    ext.rvn_widget_animate_layout(
        widget,
        &expander.*.open,
        if (expanded != 0) 1.0 else 0.0,
        if (expanded != 0) raven.R_MOTION_BOUNCY else raven.R_MOTION_SNAPPY,
    );
    if (notify != 0) {
        if (expander.*.callback) |callback| callback(widget.*.id, expanded, expander.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    }
}

fn rvn_expander_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT or event.*.local_y >= rvn_expander_header(widget)) return raven.R_FALSE;
            rvn_expander_set(widget, @as(c_int, @intFromBool(expander.*.expanded == 0)), raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0) return raven.R_FALSE;
            if (event.*.key == raven.R_KEY_ENTER or event.*.key == raven.R_KEY_SPACE) {
                rvn_expander_set(widget, @as(c_int, @intFromBool(expander.*.expanded == 0)), raven.R_TRUE);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_MOVE, raven.R_EVENT_MOUSE_ENTER, raven.R_EVENT_MOUSE_LEAVE => {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_expander_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    const header = rvn_expander_header(widget);
    const origin = ext.rvn_widget_origin(widget);
    const hot = (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and widget.*.window != null and
        widget.*.window.*.mouse_y - origin.y < header and widget.*.window.*.mouse_y - origin.y >= 0.0;
    const text = ext.rvn_widget_text_color(widget, painter);

    ext.rvn_paint_box(
        painter,
        base.rvn_rect(0.0, 0.0, widget.*.rect.w, header),
        if (widget_h.rvn_widget_glass(widget) != 0) 10.0 else 0.0,
        ext.rvn_widget_color(widget, if (hot) raven.R_COLOR_HEADER_HOVERED else raven.R_COLOR_HEADER),
        0.0,
        0,
    );
    // the chevron turns with the content
    ext.rvn_paint_chevron(painter, header * 0.5, header * 0.5, 8.0, expander.*.open.value * 1.5707963, text);
    if (expander.*.title != null) {
        ext.rvn_paint_text_in(
            painter,
            raven.R_INVALID_ID,
            common.rvn_widget_font_size(widget, 0.0),
            base.rvn_rect(header, 0.0, base.rvn_maxf(0.0, widget.*.rect.w - header), header),
            0.0,
            expander.*.title,
            -1,
            text,
        );
    }
}

fn rvn_expander_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, if (widget_h.rvn_widget_glass(widget) != 0) 10.0 else 0.0);
}

fn rvn_expander_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Title") == 0 or base.rvn_stricmp(name, "Text") == 0) {
        _ = base.rvn_str_set(&expander.*.title, value);
        ext.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Expanded") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_expander_set(widget, flag, raven.R_FALSE);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_expander: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_EXPANDER,
    .name = "Expander",
    .size = @sizeOf(rvn_expander_t),
    .flags = widget_h.RVN_CF_SINGLE_CHILD | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_expander_init,
    .destroy = rvn_expander_destroy,
    .measure = rvn_expander_measure,
    .arrange = rvn_expander_arrange,
    .paint = rvn_expander_paint,
    .paint_overlay = rvn_expander_paint_overlay,
    .event = rvn_expander_event,
    .set_attribute = rvn_expander_set_attribute,
    .child_active = rvn_expander_child_active,
});

export fn Rexpander_set_title(id: raven.Rid, title: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_EXPANDER, "Rexpander_set_title");
    if (widget == null) return;
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    if (base.rvn_str_set(&expander.*.title, title) != 0) ext.rvn_widget_invalidate_layout(widget);
}

export fn Rexpander_get_title(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_EXPANDER, "Rexpander_get_title");
    if (widget == null) return "";
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    if (expander.*.title != null) return expander.*.title;
    return "";
}

export fn Rexpander_set_expanded(id: raven.Rid, expanded: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_EXPANDER, "Rexpander_set_expanded");
    if (widget == null) return;
    rvn_expander_set(widget, expanded, raven.R_FALSE);
}

export fn Rexpander_is_expanded(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_EXPANDER, "Rexpander_is_expanded");
    if (widget == null) return raven.R_FALSE;
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    return expander.*.expanded;
}

export fn Rexpander_set_changed_callback(id: raven.Rid, callback: raven.RExpanderChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_EXPANDER, "Rexpander_set_changed_callback");
    if (widget == null) return;
    const expander: [*c]rvn_expander_t = @ptrCast(widget);
    expander.*.callback = callback;
    expander.*.user_data = user_data;
}
