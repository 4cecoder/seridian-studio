// Translated to Zig from vendor/raven/src/widgets/overlay.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/overlay.c
// Overlay (Slate SOverlay): children drawn on top of each other, each one
// aligned in the whole panel by its slot. Spacer: empty space.
//
// Both rely entirely on the default measure / arrange of the widget core:
// the desired size is the largest child, and every child is placed in the
// full bounds according to its slot padding and alignment.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");

export const rvn_class_overlay: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_OVERLAY,
    .name = "Overlay",
    .size = @sizeOf(widget_h.rvn_widget_t),
    .flags = widget_h.RVN_CF_NO_HIT,
});

// A spacer has no content: its size comes from Rwidget_set_size / the fill slot.
export const rvn_class_spacer: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SPACER,
    .name = "Spacer",
    .size = @sizeOf(widget_h.rvn_widget_t),
    .flags = widget_h.RVN_CF_NO_HIT | widget_h.RVN_CF_NO_CHILDREN,
});

export fn Rspacer_set_size(id: raven.Rid, width: f32, height: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPACER, "Rspacer_set_size");
    if (widget == null) return;
    widget.*.fixed_size = base.rvn_vec2(width, height);
    widget_h.rvn_widget_invalidate_layout(widget);
}
