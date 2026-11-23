// Translated to Zig from vendor/raven/src/widgets/progress_bar.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/progress_bar.c
// ProgressBar (Slate SProgressBar) and Separator (SSeparator): two widgets
// that only draw.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

// ===========================================================================
//  ProgressBar
// ===========================================================================

const rvn_progress_bar_t = extern struct {
    base: widget_h.rvn_widget_t,
    value: f32,
    /// The value as drawn: it glides to the real one.
    shown: raven.RSpring,
};

fn rvn_progress_bar_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    _ = widget;
    return base.rvn_vec2(120.0, 8.0);
}

fn rvn_progress_bar_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const bar: [*c]rvn_progress_bar_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const radius = base.rvn_minf(widget.*.rect.h * 0.5, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS));
    const shown = ext.rvn_paint_spring(painter, &bar.*.shown, base.rvn_clampf(bar.*.value, 0.0, 1.0), raven.R_MOTION_SMOOTH);
    const filled = @floor(widget.*.rect.w * base.rvn_clampf(shown, 0.0, 1.0) + 0.5);
    var fill = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));

    if (dp.enabled == 0) fill = base.rvn_color_fade(fill, 0.4);
    ext.rvn_paint_box(painter, rect, radius, ext.rvn_widget_color(widget, raven.R_COLOR_TRACK), 0.0, 0);
    if (filled > 0.0) {
        // clipping the full-size shape keeps the rounded ends at any progress
        ext.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, filled, widget.*.rect.h));
        ext.rvn_paint_box(painter, rect, radius, fill, 0.0, 0);
        ext.rvn_paint_pop_clip(painter);
    }
}

fn rvn_progress_bar_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    if (base.rvn_stricmp(name, "Value") == 0) {
        const bar: [*c]rvn_progress_bar_t = @ptrCast(widget);
        if (ext.rvn_parse_float(value, &bar.*.value) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_paint(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_progress_bar: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_PROGRESSBAR,
    .name = "ProgressBar",
    .size = @sizeOf(rvn_progress_bar_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_NO_HIT | widget_h.RVN_CF_SURFACE,
    .measure = rvn_progress_bar_measure,
    .paint = rvn_progress_bar_paint,
    .set_attribute = rvn_progress_bar_set_attribute,
});

export fn Rprogress_bar_set_value(id: raven.Rid, value: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_PROGRESSBAR, "Rprogress_bar_set_value");
    if (widget == null) return;
    const clamped = base.rvn_clampf(value, 0.0, 1.0);
    const bar: [*c]rvn_progress_bar_t = @ptrCast(widget);
    if (bar.*.value == clamped) return;
    bar.*.value = clamped;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rprogress_bar_get_value(id: raven.Rid) f32 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_PROGRESSBAR, "Rprogress_bar_get_value");
    if (widget == null) return 0.0;
    const bar: [*c]rvn_progress_bar_t = @ptrCast(widget);
    return bar.*.value;
}

// ===========================================================================
//  Separator
// ===========================================================================

const rvn_separator_t = extern struct {
    base: widget_h.rvn_widget_t,
    orientation: raven.ROrientation,
};

fn rvn_separator_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const separator: [*c]rvn_separator_t = @ptrCast(widget);
    separator.*.orientation = raven.R_HORIZONTAL;
}

fn rvn_separator_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    _ = widget;
    // one unit thick in both cases: it stretches along the other axis by its fill alignment
    return base.rvn_vec2(1.0, 1.0);
}

fn rvn_separator_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const separator: [*c]rvn_separator_t = @ptrCast(widget);
    const color = ext.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR);
    if (separator.*.orientation == raven.R_HORIZONTAL) {
        ext.rvn_paint_rect(painter, base.rvn_rect(0.0, @floor((widget.*.rect.h - 1.0) * 0.5), widget.*.rect.w, 1.0), color);
    } else {
        ext.rvn_paint_rect(painter, base.rvn_rect(@floor((widget.*.rect.w - 1.0) * 0.5), 0.0, 1.0, widget.*.rect.h), color);
    }
}

fn rvn_separator_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    if (base.rvn_stricmp(name, "Orientation") == 0) {
        const separator: [*c]rvn_separator_t = @ptrCast(widget);
        if (ext.rvn_parse_orientation(value, &separator.*.orientation) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_paint(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_separator: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SEPARATOR,
    .name = "Separator",
    .size = @sizeOf(rvn_separator_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_NO_HIT | widget_h.RVN_CF_SURFACE,
    .init = rvn_separator_init,
    .measure = rvn_separator_measure,
    .paint = rvn_separator_paint,
    .set_attribute = rvn_separator_set_attribute,
});

export fn Rseparator_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SEPARATOR, "Rseparator_set_orientation");
    if (widget == null) return;
    if (orientation != raven.R_HORIZONTAL and orientation != raven.R_VERTICAL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rseparator_set_orientation: invalid orientation");
        return;
    }
    const separator: [*c]rvn_separator_t = @ptrCast(widget);
    separator.*.orientation = orientation;
    widget_h.rvn_widget_invalidate_paint(widget);
}
