// Translated to Zig from vendor/raven/src/widgets/canvas.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/canvas.c
// Canvas (Slate SConstraintCanvas): children placed freely with anchors,
// offsets and a pivot. Children may lie outside of the canvas.
//
// Per axis, with the anchors given as fractions of the canvas size:
//   - anchors equal    : the child sits at anchor + position; its size is the
//                        slot size, or its desired size when that is <= 0;
//                        the pivot (alignment) shifts it by -pivot * size.
//   - anchors different: the child stretches between the anchors; position
//                        and size are the near and far margins.

const std = @import("std");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const raven = @import("raven");

fn rvn_canvas_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    var i: u32 = 0;
    // a canvas asks for no space, but its children still need a desired size
    while (i < widget.*.child_count) : (i += 1) _ = widget_h.rvn_widget_measure(widget.*.children[i]);
    return base.rvn_vec2(0.0, 0.0);
}

fn rvn_canvas_axis(canvas: f32, anchor_min: f32, anchor_max: f32, position: f32, size: f32, desired: f32, pivot: f32, out_position: [*c]f32, out_size: [*c]f32) void {
    if (anchor_max > anchor_min) {
        const near = canvas * anchor_min + position;
        const far = canvas * anchor_max - size;
        out_position.* = near;
        out_size.* = base.rvn_maxf(0.0, far - near);
    } else {
        const length = if (size > 0.0) size else desired;
        out_position.* = canvas * anchor_min + position - pivot * length;
        out_size.* = length;
    }
}

fn rvn_canvas_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]widget_h.rvn_widget_t = widget.*.children[i];
        const slot: [*c]const widget_h.rvn_slot_t = &child.*.slot;
        var x: f32 = undefined;
        var y: f32 = undefined;
        var width: f32 = undefined;
        var height: f32 = undefined;
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        rvn_canvas_axis(widget.*.rect.w, slot.*.anchors[0], slot.*.anchors[2], slot.*.position[0], slot.*.size[0], child.*.desired.x, slot.*.alignment[0], &x, &width);
        rvn_canvas_axis(widget.*.rect.h, slot.*.anchors[1], slot.*.anchors[3], slot.*.position[1], slot.*.size[1], child.*.desired.y, slot.*.alignment[1], &y, &height);
        widget_h.rvn_widget_arrange(child, x, y, width, height);
    }
}

export const rvn_class_canvas: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_CANVAS,
    .name = "Canvas",
    .size = @sizeOf(widget_h.rvn_widget_t),
    .flags = widget_h.RVN_CF_NO_HIT | widget_h.RVN_CF_OVERFLOW | widget_h.RVN_CF_NO_MIRROR,
    .measure = rvn_canvas_measure,
    .arrange = rvn_canvas_arrange,
});
