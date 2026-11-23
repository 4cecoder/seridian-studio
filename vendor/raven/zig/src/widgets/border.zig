// Translated to Zig from vendor/raven/src/widgets/border.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/border.c
// Border (Slate SBorder): one child with a background, an optional outline,
// rounded corners, a drop shadow and inner padding.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_border_t = extern struct {
    base: widget_h.rvn_widget_t,
    padding: base.rvn_margin_t,
    radii: [4]f32,
    has_radii: c_int,
    outline_width: f32,
    outline_color: base.rvn_color_t,
    shadow_blur: f32,
    shadow_offset: base.rvn_vec2_t,
    /// an effect as the background (raven_shader.h), or R_INVALID_ID
    effect: raven.Rid,
    look: raven.RShaderLook,
    /// the parts of the look the XML gave (the others come from the effect)
    look_color: c_int,
    look_color2: c_int,
    look_params: c_int,
    params: [4]f32,
    param_count: c_int,
    /// Effect="file.spv": its path, and whether it reads what is behind
    effect_file: [*c]u8,
    effect_backdrop: c_int,
};

/// The look of the effect: the defaults of the effect, then what the XML or the code gave.
fn rvn_border_apply_look(border: [*c]rvn_border_t, given: [*c]const raven.RShaderLook) void {
    var look: raven.RShaderLook = undefined;
    var i: c_int = 0;
    raven.Rshader_look_defaults(border.*.effect, &look);
    if (given != null) {
        border.*.look = given.*;
        return;
    }
    if (border.*.look_color != 0) @memcpy(&look.color, &border.*.look.color);
    if (border.*.look_color2 != 0) @memcpy(&look.color2, &border.*.look.color2);
    i = 0;
    while (i < border.*.param_count and i < 4) : (i += 1) look.params[@intCast(i)] = border.*.params[@intCast(i)];
    look.animate = border.*.look.animate;
    look.pointer = border.*.look.pointer;
    border.*.look = look;
}

fn rvn_border_load_effect_file(border: [*c]rvn_border_t) void {
    if (border.*.effect_file == null) return;
    border.*.effect = ext.rvn_shader_from_file_cached(border.*.effect_file, @as(u32, raven.R_SHADER_ANIMATED) | (if (border.*.effect_backdrop != 0) @as(u32, raven.R_SHADER_BACKDROP) else 0));
    rvn_border_apply_look(border, null);
}

fn rvn_border_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    border.*.effect = raven.R_INVALID_ID;
    raven.Rshader_look_init(&border.*.look);
}

fn rvn_border_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    base.rvn_free(border.*.effect_file);
}

fn rvn_border_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    var desired = base.rvn_vec2(0.0, 0.0);
    if (widget.*.child_count > 0) desired = ext.rvn_widget_measure_slot(widget.*.children[0]);
    desired.x += border.*.padding.l + border.*.padding.r;
    desired.y += border.*.padding.t + border.*.padding.b;
    return desired;
}

fn rvn_border_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    if (widget.*.child_count > 0 and widget_h.rvn_widget_collapsed(widget.*.children[0]) == 0) {
        ext.rvn_widget_arrange_slot(widget.*.children[0], base.rvn_rect_inset(base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), border.*.padding));
    }
}

fn rvn_border_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    var radii: [4]f32 = undefined;
    var i: c_int = 0;

    // (a border without a color is only a padding)
    if (base.rvn_color_a(widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL)) == 0 and border.*.outline_width <= 0.0 and border.*.effect == raven.R_INVALID_ID) return;
    if (border.*.effect != raven.R_INVALID_ID and raven.Rshader_is_valid(border.*.effect) != 0) {
        // the effect is the background: corners as given (else those of a style), the outline over it
        i = 0;
        while (i < 4) : (i += 1) {
            radii[@intCast(i)] = if (border.*.has_radii != 0) border.*.radii[@intCast(i)] else (if (widget_h.rvn_widget_has_metric(widget, raven.R_METRIC_CORNER_RADIUS) != 0) widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) else 0.0);
        }
        if (border.*.shadow_blur > 0.0) {
            ext.rvn_paint_shadow(painter, base.rvn_rect(border.*.shadow_offset.x, border.*.shadow_offset.y, rect.w, rect.h), radii[0], border.*.shadow_blur, widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
        }
        if (widget_h.rvn_widget_has_color(widget, raven.R_COLOR_PANEL) != 0) ext.rvn_paint_box4(painter, rect, &radii, widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL), 0.0, 0);
        {
            // the pointer: over the border (or what it holds) and pressing it, eased
            var look: raven.RShaderLook = border.*.look;
            if (look.pointer != 0) {
                var px: f32 = 0.0;
                var py: f32 = 0.0;
                var buttons: u32 = 0;
                const over: c_int = if ((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0) 1 else 0;
                var down: c_int = 0;
                if (over != 0) {
                    const painter_state: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
                    if (painter_state.window != null and draw_h.rvn_window_pointer(painter_state.window, &px, &py, &buttons) != 0 and (buttons & (@as(u32, 1) << @as(u5, @intCast(raven.R_MOUSE_LEFT)))) != 0) down = 1;
                }
                if (look.hover < 0.0) look.hover = common.rvn_widget_hover(widget, painter, over);
                if (look.press < 0.0) look.press = common.rvn_widget_press(widget, painter, down);
            }
            ext.rvn_paint_shader(painter, rect, &radii, border.*.effect, &look);
        }
        if (border.*.outline_width > 0.0) ext.rvn_paint_box4(painter, rect, &radii, 0, border.*.outline_width, border.*.outline_color);
        return;
    }
    if (widget_h.rvn_widget_glass(widget) != 0) {
        var glass: common.rvn_glass_t = undefined;
        common.rvn_glass_style(widget, common.RVN_SURFACE_PANEL, 0.0, 0.0, &glass);
        // a panel of glass is rounded unless told otherwise
        i = 0;
        while (i < 4) : (i += 1) {
            radii[@intCast(i)] = if (border.*.has_radii != 0) border.*.radii[@intCast(i)] else (if (widget_h.rvn_widget_has_metric(widget, raven.R_METRIC_CORNER_RADIUS) != 0) widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) else 20.0);
        }
        glass.shadow = border.*.shadow_blur;
        ext.rvn_paint_glass(painter, rect, &radii, &glass);
        return;
    }
    // square unless it was given corners: its own, or those of a style ("card")
    i = 0;
    while (i < 4) : (i += 1) {
        radii[@intCast(i)] = if (border.*.has_radii != 0) border.*.radii[@intCast(i)] else (if (widget_h.rvn_widget_has_metric(widget, raven.R_METRIC_CORNER_RADIUS) != 0) widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) else 0.0);
    }
    if (border.*.shadow_blur > 0.0) {
        ext.rvn_paint_shadow(painter, base.rvn_rect(border.*.shadow_offset.x, border.*.shadow_offset.y, rect.w, rect.h), radii[0], border.*.shadow_blur, widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
    }
    ext.rvn_paint_box4(painter, rect, &radii, widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL), border.*.outline_width, if (border.*.outline_width > 0.0) border.*.outline_color else 0);
}

fn rvn_border_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const border: [*c]rvn_border_t = @ptrCast(widget);
    var color: base.rvn_color_t = undefined;
    var values: [4]f32 = undefined;
    var count: c_int = undefined;

    if (base.rvn_stricmp(name, "Padding") == 0) {
        if (widget_h.rvn_parse_margin(value, &border.*.padding) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (base.rvn_stricmp(name, "Background") == 0) {
        if (widget_h.rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_set_color(widget, raven.R_COLOR_PANEL, color);
    } else if (base.rvn_stricmp(name, "BorderColor") == 0) {
        if (widget_h.rvn_parse_color(value, &border.*.outline_color) == 0) return raven.R_FALSE;
        if (border.*.outline_width <= 0.0) border.*.outline_width = 1.0;
    } else if (base.rvn_stricmp(name, "BorderWidth") == 0) {
        if (widget_h.rvn_parse_float(value, &border.*.outline_width) == 0) return raven.R_FALSE;
        if (base.rvn_color_a(border.*.outline_color) == 0) border.*.outline_color = widget_h.rvn_widget_color(widget, raven.R_COLOR_BORDER);
    } else if (base.rvn_stricmp(name, "CornerRadius") == 0) {
        count = widget_h.rvn_parse_floats(value, &values, 4);
        if (count != 1 and count != 4) return raven.R_FALSE;
        border.*.radii[0] = values[0];
        border.*.radii[1] = if (count == 4) values[1] else values[0];
        border.*.radii[2] = if (count == 4) values[2] else values[0];
        border.*.radii[3] = if (count == 4) values[3] else values[0];
        border.*.has_radii = raven.R_TRUE;
    } else if (base.rvn_stricmp(name, "Effect") == 0) {
        base.rvn_free(border.*.effect_file);
        border.*.effect_file = null;
        if (value[0] == 0 or base.rvn_stricmp(value, "none") == 0) {
            border.*.effect = raven.R_INVALID_ID;
        } else {
            border.*.effect = raven.Reffect_find(value);
            if (border.*.effect == raven.R_INVALID_ID) {
                // a .spv file, from the folder of the XML file
                border.*.effect_file = ext.rvn_xml_resolve_path(value);
                rvn_border_load_effect_file(border);
                if (border.*.effect == raven.R_INVALID_ID) return raven.R_FALSE;
            }
            rvn_border_apply_look(border, null);
        }
    } else if (base.rvn_stricmp(name, "EffectColor") == 0 or base.rvn_stricmp(name, "EffectColor2") == 0) {
        const second: c_int = if (base.rvn_stricmp(name, "EffectColor2") == 0) 1 else 0;
        if (widget_h.rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        {
            const out: [*c]f32 = if (second != 0) &border.*.look.color2 else &border.*.look.color;
            base.rvn_color_to_floats(color, &out[0], &out[1], &out[2], &out[3]);
        }
        if (second != 0) border.*.look_color2 = raven.R_TRUE else border.*.look_color = raven.R_TRUE;
        if (border.*.effect != raven.R_INVALID_ID) rvn_border_apply_look(border, null);
    } else if (base.rvn_stricmp(name, "EffectParams") == 0) {
        border.*.param_count = widget_h.rvn_parse_floats(value, &border.*.params, 4);
        if (border.*.param_count < 1) return raven.R_FALSE;
        if (border.*.effect != raven.R_INVALID_ID) rvn_border_apply_look(border, null);
    } else if (base.rvn_stricmp(name, "EffectAnimate") == 0) {
        var animate: c_int = undefined;
        if (widget_h.rvn_parse_bool(value, &animate) == 0) return raven.R_FALSE;
        border.*.look.animate = animate;
    } else if (base.rvn_stricmp(name, "EffectPointer") == 0) {
        if (widget_h.rvn_parse_bool(value, &border.*.look.pointer) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "EffectBackdrop") == 0) {
        if (widget_h.rvn_parse_bool(value, &border.*.effect_backdrop) == 0) return raven.R_FALSE;
        rvn_border_load_effect_file(border);
    } else if (base.rvn_stricmp(name, "Shadow") == 0) {
        count = widget_h.rvn_parse_floats(value, &values, 3);
        if (count < 1) return raven.R_FALSE;
        border.*.shadow_blur = values[0];
        border.*.shadow_offset = base.rvn_vec2(if (count > 1) values[1] else 0.0, if (count > 2) values[2] else 2.0);
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_border: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_BORDER,
    .name = "Border",
    .size = @sizeOf(rvn_border_t),
    .flags = widget_h.RVN_CF_SINGLE_CHILD | widget_h.RVN_CF_SURFACE,
    .measure = rvn_border_measure,
    .arrange = rvn_border_arrange,
    .paint = rvn_border_paint,
    .set_attribute = rvn_border_set_attribute,
    .destroy = rvn_border_destroy,
    .init = rvn_border_init,
});

export fn Rborder_set_effect(id: raven.Rid, shader: raven.Rid, look: [*c]const raven.RShaderLook) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_effect");
    if (widget == null) return;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    base.rvn_free(border.*.effect_file);
    border.*.effect_file = null;
    border.*.effect = if (raven.Rshader_is_valid(shader) != 0) shader else raven.R_INVALID_ID;
    if (border.*.effect != raven.R_INVALID_ID) rvn_border_apply_look(border, look);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rborder_get_effect(id: raven.Rid) raven.Rid {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_get_effect");
    if (widget == null) return raven.R_INVALID_ID;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    return border.*.effect;
}

export fn Rborder_set_padding(id: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_padding");
    if (widget == null) return;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    border.*.padding = base.rvn_margin(left, top, right, bottom);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rborder_set_background(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_background");
    if (widget == null) return;
    widget_h.rvn_widget_set_color(widget, raven.R_COLOR_PANEL, base.rvn_rgba(r, g, b, a));
}

export fn Rborder_set_outline(id: raven.Rid, width: f32, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_outline");
    if (widget == null) return;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    border.*.outline_width = if (width > 0.0) width else 0.0;
    border.*.outline_color = base.rvn_rgba(r, g, b, a);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rborder_set_corner_radius(id: raven.Rid, top_left: f32, top_right: f32, bottom_right: f32, bottom_left: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_corner_radius");
    if (widget == null) return;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    border.*.radii[0] = top_left;
    border.*.radii[1] = top_right;
    border.*.radii[2] = bottom_right;
    border.*.radii[3] = bottom_left;
    border.*.has_radii = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rborder_set_material(id: raven.Rid, material: raven.RMaterial) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_material");
    if (widget == null) return;
    raven.Rwidget_set_material(id, material);
}

export fn Rborder_set_shadow(id: raven.Rid, blur: f32, offset_x: f32, offset_y: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BORDER, "Rborder_set_shadow");
    if (widget == null) return;
    const border: [*c]rvn_border_t = @ptrCast(widget);
    border.*.shadow_blur = if (blur > 0.0) blur else 0.0;
    border.*.shadow_offset = base.rvn_vec2(offset_x, offset_y);
    widget_h.rvn_widget_invalidate_paint(widget);
}
