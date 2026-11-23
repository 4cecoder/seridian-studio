// Translated to Zig from vendor/raven/src/widgets/box_panel.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/box_panel.c
// VBox and HBox: children stacked along one axis (Slate SVerticalBox /
// SHorizontalBox).
//
//   auto slot : takes the desired size of the child along the axis
//   fill slot : shares the remaining space in proportion to its coefficient
// Across the axis, every slot spans the whole panel and the child is placed
// in it according to its alignment.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

fn rvn_box_is_vertical(widget: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(widget.*.cls.*.type == raven.R_WIDGET_VBOX);
}

// Size of a child along the axis, slot padding excluded, limited by the slot maximum.
fn rvn_box_child_main(child: [*c]const widget_h.rvn_widget_t, vertical: c_int) f32 {
    var size: f32 = if (vertical != 0) child.*.desired.y else child.*.desired.x;
    if (child.*.slot.max_size > 0.0 and size > child.*.slot.max_size) size = child.*.slot.max_size;
    return size;
}

fn rvn_box_padding_main(child: [*c]const widget_h.rvn_widget_t, vertical: c_int) f32 {
    return if (vertical != 0) child.*.slot.padding.t + child.*.slot.padding.b else child.*.slot.padding.l + child.*.slot.padding.r;
}

fn rvn_box_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const panel: [*c]common.rvn_spaced_panel_t = @ptrCast(widget);
    const vertical = rvn_box_is_vertical(widget);
    var main: f32 = 0.0;
    var cross: f32 = 0.0;
    var i: u32 = 0;
    var visible: u32 = 0;

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        main += rvn_box_child_main(child, vertical) + rvn_box_padding_main(child, vertical);
        cross = base.rvn_maxf(cross, if (vertical != 0) size.x else size.y);
        visible += 1;
    }
    if (visible > 1) main += panel.*.spacing * @as(f32, @floatFromInt(visible - 1));
    return if (vertical != 0) base.rvn_vec2(cross, main) else base.rvn_vec2(main, cross);
}

fn rvn_box_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const panel: [*c]common.rvn_spaced_panel_t = @ptrCast(widget);
    const vertical = rvn_box_is_vertical(widget);
    const main_size: f32 = if (vertical != 0) widget.*.rect.h else widget.*.rect.w;
    const cross_size: f32 = if (vertical != 0) widget.*.rect.w else widget.*.rect.h;
    var fixed: f32 = 0.0;
    var fill_total: f32 = 0.0;
    var position: f32 = 0.0;
    var i: u32 = 0;
    var visible: u32 = 0;

    // first pass: space taken by the auto slots, the paddings and the gaps
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        fixed += rvn_box_padding_main(child, vertical);
        if (child.*.slot.is_fill != 0) {
            fill_total += child.*.slot.fill;
        } else {
            fixed += rvn_box_child_main(child, vertical);
        }
        visible += 1;
    }
    if (visible > 1) fixed += panel.*.spacing * @as(f32, @floatFromInt(visible - 1));
    const remaining: f32 = base.rvn_maxf(0.0, main_size - fixed);

    // second pass: place the children
    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const padding = rvn_box_padding_main(child, vertical);
        var size: f32 = undefined;
        if (child.*.slot.is_fill != 0) {
            size = if (fill_total > 0.0) remaining * child.*.slot.fill / fill_total else 0.0;
            if (child.*.slot.max_size > 0.0 and size > child.*.slot.max_size) size = child.*.slot.max_size;
        } else {
            size = rvn_box_child_main(child, vertical);
        }
        const slot: base.rvn_rect_t = if (vertical != 0)
            base.rvn_rect(0.0, position, cross_size, size + padding)
        else
            base.rvn_rect(position, 0.0, size + padding, cross_size);
        ext.rvn_widget_arrange_slot(child, slot);
        position += size + padding + panel.*.spacing;
    }
}

fn rvn_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const panel: [*c]common.rvn_spaced_panel_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &panel.*.spacing) == 0) return raven.R_FALSE;
        ext.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_vbox: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .type = raven.R_WIDGET_VBOX,
    .name = "VBox",
    .size = @sizeOf(common.rvn_spaced_panel_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .measure = rvn_box_measure,
    .arrange = rvn_box_arrange,
    .set_attribute = rvn_box_set_attribute,
});

export const rvn_class_hbox: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .type = raven.R_WIDGET_HBOX,
    .name = "HBox",
    .size = @sizeOf(common.rvn_spaced_panel_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .measure = rvn_box_measure,
    .arrange = rvn_box_arrange,
    .set_attribute = rvn_box_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API shared by the panels that have a spacing
// ---------------------------------------------------------------------------

export fn Rpanel_get_spacing(id: raven.Rid) f32 {
    const widget = widget_h.rvn_widget_check(id, 0, "Rpanel_get_spacing");
    if (widget == null) return 0.0;
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_VBOX,
        raven.R_WIDGET_HBOX,
        raven.R_WIDGET_WRAP_BOX,
        raven.R_WIDGET_GRID,
        raven.R_WIDGET_UNIFORM_GRID,
        raven.R_WIDGET_SCROLL_BOX,
        => {
            const panel: [*c]common.rvn_spaced_panel_t = @ptrCast(widget);
            return panel.*.spacing;
        },
        else => return 0.0,
    }
}

export fn Rpanel_set_spacing(id: raven.Rid, spacing: f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rpanel_set_spacing");
    if (widget == null) return;
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_VBOX,
        raven.R_WIDGET_HBOX,
        raven.R_WIDGET_WRAP_BOX,
        raven.R_WIDGET_GRID,
        raven.R_WIDGET_UNIFORM_GRID,
        raven.R_WIDGET_SCROLL_BOX,
        => {
            const panel: [*c]common.rvn_spaced_panel_t = @ptrCast(widget);
            panel.*.spacing = if (spacing > 0.0) spacing else 0.0;
            ext.rvn_widget_invalidate_layout(widget);
        },
        else => {
            base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rpanel_set_spacing: a %s has no spacing", widget.*.cls.*.name);
        },
    }
}
