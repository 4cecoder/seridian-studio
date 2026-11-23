// Translated to Zig from vendor/raven/src/widget/direction.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/direction.c
// Right-to-left layouts (Rset_layout_direction, Rwidget_set_direction).
//
// In a right-to-left part of a window, every container places its children
// as in a mirror: what would be on the left is on the right (rvn_widget_arrange
// mirrors the rectangles), and the texts that start on the left start on the
// right (the painter carries the direction: rvn_paint_text_in and the labels
// flip their alignment). The widgets that are a surface of their own (a
// canvas, a node graph, a timeline, a text editor...) keep their inside as
// it is: their class has RVN_CF_NO_MIRROR.
//
// The text itself is ordered by the bidirectional algorithm whatever the
// direction of the layout (render/bidi.c).

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const handle_h = @import("../core/handle_h.zig");
const widget_h = @import("widget_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;

var g_direction: raven.RDirection = raven.R_DIRECTION_AUTO;

export fn rvn_direction_global_rtl() c_int {
    if (g_direction == raven.R_DIRECTION_RTL) return raven.R_TRUE;
    if (g_direction == raven.R_DIRECTION_LTR) return raven.R_FALSE;
    return widget_h.rvn_locale_rtl();
}

export fn rvn_widget_is_rtl(widget: [*c]const rvn_widget_t) c_int {
    var walk = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.direction == raven.R_DIRECTION_RTL) return raven.R_TRUE;
        if (walk.*.direction == raven.R_DIRECTION_LTR) return raven.R_FALSE;
    }
    return rvn_direction_global_rtl();
}

fn rvn_direction_dirty(widget: [*c]rvn_widget_t) void {
    widget.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) rvn_direction_dirty(widget.*.children[i]);
}

// Every window is laid out again, entirely: positions depend on the direction of the parents.
fn rvn_direction_relayout() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.widgets.used) : (i += 1) {
        const widget: [*c]rvn_widget_t = @ptrCast(@alignCast(handle_h.rvn_pool_at(&ctx_h.g_rvn.widgets, i)));
        if (widget != null and widget.*.parent == null and widget.*.window != null) {
            rvn_direction_dirty(widget);
            widget_h.rvn_widget_invalidate_layout(widget);
        }
    }
    ctx_h.rvn_invalidate_all_windows();
}

export fn rvn_direction_refresh() void {
    const S = struct {
        var last: c_int = -1;
    };
    const rtl = rvn_direction_global_rtl();
    if (rtl == S.last) return;
    S.last = rtl;
    rvn_direction_relayout();
}

export fn Rset_layout_direction(direction: raven.RDirection) void {
    if (ctx_h.rvn_api_check("Rset_layout_direction") == 0) return;
    if (direction != raven.R_DIRECTION_AUTO and direction != raven.R_DIRECTION_LTR and direction != raven.R_DIRECTION_RTL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rset_layout_direction: R_DIRECTION_AUTO, _LTR or _RTL");
        return;
    }
    g_direction = direction;
    rvn_direction_refresh();
}

export fn Rget_layout_direction() raven.RDirection {
    if (ctx_h.rvn_api_check("Rget_layout_direction") == 0) return raven.R_DIRECTION_LTR;
    return if (rvn_direction_global_rtl() != 0) @as(raven.RDirection, raven.R_DIRECTION_RTL) else @as(raven.RDirection, raven.R_DIRECTION_LTR);
}

export fn Rwidget_set_direction(id: raven.Rid, direction: raven.RDirection) void {
    if (ctx_h.rvn_api_check("Rwidget_set_direction") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_direction");
    if (widget == null) return;
    if (direction != raven.R_DIRECTION_INHERIT and direction != raven.R_DIRECTION_LTR and direction != raven.R_DIRECTION_RTL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_direction: R_DIRECTION_INHERIT, _LTR or _RTL");
        return;
    }
    widget.*.direction = @truncate(direction);
    rvn_direction_dirty(widget);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_get_direction(id: raven.Rid) raven.RDirection {
    if (ctx_h.rvn_api_check("Rwidget_get_direction") == 0) return raven.R_DIRECTION_LTR;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_direction");
    if (widget == null) return raven.R_DIRECTION_LTR;
    return if (widget_h.rvn_widget_is_rtl(widget) != 0) @as(raven.RDirection, raven.R_DIRECTION_RTL) else @as(raven.RDirection, raven.R_DIRECTION_LTR);
}
