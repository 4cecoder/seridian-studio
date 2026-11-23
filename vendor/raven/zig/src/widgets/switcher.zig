// Translated to Zig from vendor/raven/src/widgets/switcher.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/switcher.c
// Switcher (Slate SWidgetSwitcher): shows one of its children. The others
// are neither laid out, painted nor reachable by the mouse or the keyboard.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_switcher_t = extern struct {
    base: widget_h.rvn_widget_t,
    index: c_int,
};

fn rvn_switcher_active(widget: [*c]widget_h.rvn_widget_t) [*c]widget_h.rvn_widget_t {
    const switcher: [*c]rvn_switcher_t = @ptrCast(widget);
    const count: c_int = @bitCast(widget.*.child_count); // (int)widget->child_count
    if (switcher.*.index < 0 or switcher.*.index >= count) return null;
    return widget.*.children[@intCast(switcher.*.index)];
}

fn rvn_switcher_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const active = rvn_switcher_active(widget);
    return if (active != null) ext.rvn_widget_measure_slot(active) else base.rvn_vec2(0.0, 0.0);
}

fn rvn_switcher_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const active = rvn_switcher_active(widget);
    if (active != null and widget_h.rvn_widget_collapsed(active) == 0) {
        ext.rvn_widget_arrange_slot(active, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
    }
}

fn rvn_switcher_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    return @intFromBool(rvn_switcher_active(widget) == child);
}

fn rvn_switcher_set(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const switcher: [*c]rvn_switcher_t = @ptrCast(widget);
    const previous = rvn_switcher_active(widget);
    if (switcher.*.index == index) return;
    // the page being hidden may hold the focus, the hover or an open popup
    if (previous != null and widget.*.window != null) ext.rvn_window_forget_widget(widget.*.window, previous);
    switcher.*.index = index;
    widget_h.rvn_widget_invalidate_layout(widget);
}

fn rvn_switcher_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    var index: c_int = undefined;
    if (base.rvn_stricmp(name, "Index") == 0) {
        if (ext.rvn_parse_int(value, &index) == 0) return raven.R_FALSE;
        rvn_switcher_set(widget, index);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_switcher: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SWITCHER,
    .name = "Switcher",
    .size = @sizeOf(rvn_switcher_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .measure = rvn_switcher_measure,
    .arrange = rvn_switcher_arrange,
    .child_active = rvn_switcher_child_active,
    .set_attribute = rvn_switcher_set_attribute,
});

export fn Rswitcher_set_index(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SWITCHER, "Rswitcher_set_index");
    if (widget == null) return;
    rvn_switcher_set(widget, index);
}

export fn Rswitcher_get_index(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SWITCHER, "Rswitcher_get_index");
    if (widget == null) return -1;
    const switcher: [*c]rvn_switcher_t = @ptrCast(widget);
    return switcher.*.index;
}
