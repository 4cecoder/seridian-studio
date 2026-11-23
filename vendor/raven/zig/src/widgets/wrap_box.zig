// Translated to Zig from vendor/raven/src/widgets/wrap_box.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/wrap_box.c
// WrapBox (Slate SWrapBox): children flow left to right and continue on a
// new line when the width is used up.
//
// The height depends on the width the panel receives, which is only known
// when it is arranged: the panel remembers that width and, when it changes,
// asks for one more layout pass.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const ext = @import("externs.zig");

/// Width received at the last arrange; 0 before the first one.
const rvn_wrap_box_t = extern struct {
    base: widget_h.rvn_widget_t,
    spacing: f32,
    wrap_width: f32,
};

/// Walks the children as they flow in `width`. With `place`, gives them their
/// bounds. Returns the size used.
fn rvn_wrap_box_flow(widget: [*c]widget_h.rvn_widget_t, width: f32, place: c_int) base.rvn_vec2_t {
    const box: [*c]rvn_wrap_box_t = @ptrCast(widget);
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    var line_height: f32 = 0.0;
    var used_width: f32 = 0.0;
    var i: u32 = 0;

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        if (x > 0.0 and width > 0.0 and x + size.x > width + 0.01) {
            x = 0.0;
            y += line_height + box.*.spacing;
            line_height = 0.0;
        }
        if (place != 0) ext.rvn_widget_arrange_slot(child, base.rvn_rect(x, y, size.x, size.y));
        x += size.x;
        used_width = base.rvn_maxf(used_width, x);
        x += box.*.spacing;
        line_height = base.rvn_maxf(line_height, size.y);
    }
    return base.rvn_vec2(used_width, y + line_height);
}

fn rvn_wrap_box_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const box: [*c]rvn_wrap_box_t = @ptrCast(widget);
    return rvn_wrap_box_flow(widget, box.*.wrap_width, raven.R_FALSE);
}

fn rvn_wrap_box_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const box: [*c]rvn_wrap_box_t = @ptrCast(widget);
    if (box.*.wrap_width != widget.*.rect.w) {
        box.*.wrap_width = widget.*.rect.w;
        // the height we announced was computed for another width
        ext.rvn_widget_invalidate_layout(widget);
    }
    _ = rvn_wrap_box_flow(widget, widget.*.rect.w, raven.R_TRUE);
}

fn rvn_wrap_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const box: [*c]rvn_wrap_box_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &box.*.spacing) == 0) return raven.R_FALSE;
        ext.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_wrap_box: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .type = raven.R_WIDGET_WRAP_BOX,
    .name = "WrapBox",
    .size = @sizeOf(rvn_wrap_box_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .measure = rvn_wrap_box_measure,
    .arrange = rvn_wrap_box_arrange,
    .set_attribute = rvn_wrap_box_set_attribute,
});
