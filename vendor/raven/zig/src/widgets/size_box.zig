// Translated to Zig from vendor/raven/src/widgets/size_box.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/size_box.c
// SizeBox (Slate SBox): one child with size constraints. The fixed, minimum
// and maximum sizes are the constraints every widget has (Rwidget_set_size
// ...); this panel adds a fixed aspect ratio, typically around a viewport.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const ext = @import("externs.zig");

const rvn_size_box_t = extern struct {
    base: widget_h.rvn_widget_t,
    /// Width / height. 0 = no constraint.
    aspect_ratio: f32,
};

fn rvn_size_box_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const box: [*c]rvn_size_box_t = @ptrCast(widget);
    var area = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    var child: [*c]widget_h.rvn_widget_t = undefined;

    if (widget.*.child_count == 0 or widget_h.rvn_widget_collapsed(widget.*.children[0]) != 0) return;
    child = widget.*.children[0];
    area = base.rvn_rect_inset(area, child.*.slot.padding);

    if (box.*.aspect_ratio > 0.0 and area.w > 0.0 and area.h > 0.0) {
        // largest rectangle of the requested ratio that fits, placed by the slot alignment
        var width: f32 = area.w;
        var height: f32 = area.w / box.*.aspect_ratio;
        var fx: f32 = 0.5;
        var fy: f32 = 0.5;
        if (height > area.h) {
            height = area.h;
            width = area.h * box.*.aspect_ratio;
        }
        if (child.*.slot.halign == raven.R_HALIGN_LEFT) {
            fx = 0.0;
        } else if (child.*.slot.halign == raven.R_HALIGN_RIGHT) {
            fx = 1.0;
        }
        if (child.*.slot.valign == raven.R_VALIGN_TOP) {
            fy = 0.0;
        } else if (child.*.slot.valign == raven.R_VALIGN_BOTTOM) {
            fy = 1.0;
        }
        ext.rvn_widget_arrange(child, area.x + (area.w - width) * fx, area.y + (area.h - height) * fy, width, height);
        return;
    }
    ext.rvn_widget_arrange_slot(child, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
}

fn rvn_size_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const box: [*c]rvn_size_box_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "AspectRatio") == 0) {
        var values: [2]f32 = undefined;
        const count = ext.rvn_parse_floats(value, &values, 2);
        // "1.777" or "16,9"
        if (count == 1) {
            box.*.aspect_ratio = values[0];
        } else if (count == 2 and values[1] > 0.0) {
            box.*.aspect_ratio = values[0] / values[1];
        } else {
            return raven.R_FALSE;
        }
        ext.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_size_box: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SIZE_BOX,
    .name = "SizeBox",
    .size = @sizeOf(rvn_size_box_t),
    .flags = widget_h.RVN_CF_SINGLE_CHILD | widget_h.RVN_CF_NO_HIT,
    .arrange = rvn_size_box_arrange,
    .set_attribute = rvn_size_box_set_attribute,
});

export fn Rsize_box_set_aspect_ratio(id: raven.Rid, ratio: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SIZE_BOX, "Rsize_box_set_aspect_ratio");
    if (widget == null) return;
    const box: [*c]rvn_size_box_t = @ptrCast(widget);
    box.*.aspect_ratio = if (ratio > 0.0) ratio else 0.0;
    ext.rvn_widget_invalidate_layout(widget);
}
