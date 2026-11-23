// Translated to Zig from vendor/raven/src/widgets/background_blur.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/background_blur.c
// BackgroundBlur: one child over a blurred view of what is behind it, in one
// of four looks (RBlurStyle): plain, frosted, glass, or the blur of the OS.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

/// `RVN_ATTR(literal)` of widgets/common.h: case-insensitive comparison of the attribute name.
inline fn RVN_ATTR(name: [*c]const u8, literal: [*c]const u8) bool {
    return base.rvn_stricmp(name, literal) == 0;
}

const rvn_background_blur_t = extern struct {
    base: widget_h.rvn_widget_t,
    style: raven.RBlurStyle,
    /// Negative: the one of the theme.
    radius: f32,
    has_tint: c_int,
    tint: base.rvn_color_t,
    /// Negative: the ones of the style.
    saturation: f32,
    grain: f32,
    radii: [4]f32,
    has_radii: c_int,
    padding: base.rvn_margin_t,
    shadow: f32,
};

fn rvn_background_blur_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.style = raven.R_BLUR_FROSTED;
    blur.*.radius = -1.0;
    blur.*.saturation = -1.0;
    blur.*.grain = -1.0;
}

fn rvn_background_blur_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    var desired = base.rvn_vec2(0.0, 0.0);
    if (widget.*.child_count > 0) desired = ext.rvn_widget_measure_slot(widget.*.children[0]);
    desired.x += blur.*.padding.l + blur.*.padding.r;
    desired.y += blur.*.padding.t + blur.*.padding.b;
    return desired;
}

fn rvn_background_blur_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    if (widget.*.child_count > 0 and widget_h.rvn_widget_collapsed(widget.*.children[0]) == 0) {
        ext.rvn_widget_arrange_slot(widget.*.children[0], base.rvn_rect_inset(base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), blur.*.padding));
    }
}

// The veil of the styles that have one: the tint of the widget, else the panel color of the theme, never opaque.
fn rvn_background_blur_veil(blur: [*c]const rvn_background_blur_t, strength: f32) base.rvn_color_t {
    if (blur.*.has_tint != 0) return blur.*.tint;
    const color = widget_h.rvn_widget_color(&blur.*.base, raven.R_COLOR_PANEL);
    // (a palette made for solid panels would hide the blur: the veil keeps to its share)
    const alpha = base.rvn_clampf(@as(f32, @floatFromInt(base.rvn_color_a(color))) / 255.0, 0.0, 1.0);
    return (color & 0x00FFFFFF) | (@as(u32, @intFromFloat(base.rvn_minf(alpha, 1.0) * strength * 255.0 + 0.5)) << 24);
}

fn rvn_background_blur_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    const theme = widget_h.rvn_widget_theme(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const radius = if (blur.*.radius >= 0.0) blur.*.radius else widget_h.rvn_widget_metric(widget, raven.R_METRIC_BLUR_RADIUS);
    const hairline = base.rvn_rgba(1.0, 1.0, 1.0, if (theme.*.dark != 0) 0.14 else 0.55);
    var style = blur.*.style;
    var look = std.mem.zeroes(draw_h.rvn_blur_t);
    var radii: [4]f32 = undefined;
    var i: usize = 0;

    while (i < 4) : (i += 1) {
        radii[i] = if (blur.*.has_radii != 0) blur.*.radii[i] else widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    }
    // the blur of the OS only exists behind a window that is seen through
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    if (style == raven.R_BLUR_NATIVE) {
        const window: [*c]const widget_h.rvn_window_t = @ptrCast(@alignCast(dp.window));
        if (!(dp.window != null and ext.rvn_window_see_through(window) != 0)) style = raven.R_BLUR_FROSTED;
    }

    look.radius = radius;
    look.saturation = if (blur.*.saturation >= 0.0) blur.*.saturation else 1.0;
    look.grain = if (blur.*.grain >= 0.0) blur.*.grain else 0.0;
    look.shadow = blur.*.shadow;
    look.shadow_color = widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW);

    switch (style) {
        raven.R_BLUR_GLASS => {
            var glass: draw_h.rvn_glass_t = undefined;
            common.rvn_glass_style(widget, common.RVN_SURFACE_PANEL, 0.0, 0.0, &glass);
            // (in a solid theme the widget still is glass: it is what was asked for)
            if (widget_h.rvn_widget_glass(widget) == 0) {
                glass.tint = rvn_background_blur_veil(blur, 0.4);
                glass.rim = base.rvn_rgba(1.0, 1.0, 1.0, if (theme.*.dark != 0) 0.5 else 0.8);
            }
            if (blur.*.has_tint != 0) glass.tint = blur.*.tint;
            glass.frost = base.rvn_clampf(radius / 22.0, 0.0, 1.0);
            if (blur.*.saturation >= 0.0) glass.saturation = blur.*.saturation;
            glass.shadow = blur.*.shadow;
            ext.rvn_paint_glass(painter, rect, &radii, &glass);
        },
        raven.R_BLUR_NATIVE => {
            // a hole in everything the window drew there, then a light veil and a hairline over what the OS shows
            if (blur.*.shadow > 0.0) ext.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + blur.*.shadow * 0.25, rect.w, rect.h), radii[0], blur.*.shadow, look.shadow_color);
            ext.rvn_paint_erase(painter, rect, &radii, 1.0);
            ext.rvn_paint_box4(painter, rect, &radii, rvn_background_blur_veil(blur, 0.3), 1.0, hairline);
        },
        raven.R_BLUR_PLAIN => {
            look.tint = if (blur.*.has_tint != 0) blur.*.tint else 0;
            ext.rvn_paint_blur(painter, rect, &radii, &look);
        },
        // case R_BLUR_FROSTED: default:
        else => {
            look.tint = rvn_background_blur_veil(blur, 0.52);
            if (blur.*.saturation < 0.0) look.saturation = 1.35;
            if (blur.*.grain < 0.0) look.grain = 0.55;
            look.light = if (theme.*.dark != 0) 0.01 else 0.03;
            look.border_width = 1.0;
            look.border = hairline;
            ext.rvn_paint_blur(painter, rect, &radii, &look);
        },
    }
}

fn rvn_parse_blur_style(value: [*c]const u8, style: [*c]raven.RBlurStyle) c_int {
    const names = [_]struct { name: [*c]const u8, style: raven.RBlurStyle }{
        .{ .name = "Plain", .style = raven.R_BLUR_PLAIN },
        .{ .name = "Gaussian", .style = raven.R_BLUR_PLAIN },
        .{ .name = "Frosted", .style = raven.R_BLUR_FROSTED },
        .{ .name = "Glass", .style = raven.R_BLUR_GLASS },
        .{ .name = "Glassy", .style = raven.R_BLUR_GLASS },
        .{ .name = "Native", .style = raven.R_BLUR_NATIVE },
        .{ .name = "System", .style = raven.R_BLUR_NATIVE },
    };
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        if (base.rvn_stricmp(value, names[i].name) == 0) {
            style.* = names[i].style;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

fn rvn_background_blur_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    var values: [4]f32 = undefined;
    var count: c_int = undefined;

    if (RVN_ATTR(name, "Style") or RVN_ATTR(name, "Kind")) {
        if (rvn_parse_blur_style(value, &blur.*.style) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Radius") or RVN_ATTR(name, "Blur")) {
        if (ext.rvn_parse_float(value, &blur.*.radius) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Tint")) {
        if (ext.rvn_parse_color(value, &blur.*.tint) == 0) return raven.R_FALSE;
        blur.*.has_tint = raven.R_TRUE;
    } else if (RVN_ATTR(name, "Saturation")) {
        if (ext.rvn_parse_float(value, &blur.*.saturation) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Grain")) {
        if (ext.rvn_parse_float(value, &blur.*.grain) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Shadow")) {
        if (ext.rvn_parse_float(value, &blur.*.shadow) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Padding")) {
        if (ext.rvn_parse_margin(value, &blur.*.padding) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "CornerRadius")) {
        count = ext.rvn_parse_floats(value, &values, 4);
        if (count != 1 and count != 4) return raven.R_FALSE;
        blur.*.radii[0] = values[0];
        blur.*.radii[1] = if (count == 4) values[1] else values[0];
        blur.*.radii[2] = if (count == 4) values[2] else values[0];
        blur.*.radii[3] = if (count == 4) values[3] else values[0];
        blur.*.has_radii = raven.R_TRUE;
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_background_blur: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_BACKGROUND_BLUR,
    .name = "BackgroundBlur",
    .size = @sizeOf(rvn_background_blur_t),
    .flags = widget_h.RVN_CF_SINGLE_CHILD | widget_h.RVN_CF_SURFACE,
    .init = rvn_background_blur_init,
    .measure = rvn_background_blur_measure,
    .arrange = rvn_background_blur_arrange,
    .paint = rvn_background_blur_paint,
    .set_attribute = rvn_background_blur_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rbackground_blur_create() raven.Rid {
    if (ext.rvn_api_check("Rbackground_blur_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_BACKGROUND_BLUR);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rbackground_blur_set_style(id: raven.Rid, style: raven.RBlurStyle) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_style");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    if (style < raven.R_BLUR_PLAIN or style > raven.R_BLUR_NATIVE) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rbackground_blur_set_style: invalid style");
        return;
    }
    blur.*.style = style;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_get_style(id: raven.Rid) raven.RBlurStyle {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_get_style");
    if (widget == null) return raven.R_BLUR_FROSTED;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    return blur.*.style;
}

export fn Rbackground_blur_set_radius(id: raven.Rid, radius: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_radius");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.radius = radius;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_get_radius(id: raven.Rid) f32 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_get_radius");
    if (widget == null) return 0.0;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    return if (blur.*.radius >= 0.0) blur.*.radius else widget_h.rvn_widget_metric(&blur.*.base, raven.R_METRIC_BLUR_RADIUS);
}

export fn Rbackground_blur_set_tint(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_tint");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.tint = base.rvn_rgba(r, g, b, a);
    blur.*.has_tint = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_clear_tint(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_clear_tint");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.has_tint = raven.R_FALSE;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_set_saturation(id: raven.Rid, saturation: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_saturation");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.saturation = saturation;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_set_grain(id: raven.Rid, grain: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_grain");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.grain = grain;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_set_corner_radius(id: raven.Rid, top_left: f32, top_right: f32, bottom_right: f32, bottom_left: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_corner_radius");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.radii[0] = top_left;
    blur.*.radii[1] = top_right;
    blur.*.radii[2] = bottom_right;
    blur.*.radii[3] = bottom_left;
    blur.*.has_radii = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}

export fn Rbackground_blur_set_padding(id: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_padding");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.padding = base.rvn_margin(left, top, right, bottom);
    widget_h.rvn_widget_invalidate_layout(&blur.*.base);
}

export fn Rbackground_blur_set_shadow(id: raven.Rid, shadow_blur: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BACKGROUND_BLUR, "Rbackground_blur_set_shadow");
    if (widget == null) return;
    const blur: [*c]rvn_background_blur_t = @ptrCast(widget);
    blur.*.shadow = if (shadow_blur > 0.0) shadow_blur else 0.0;
    widget_h.rvn_widget_invalidate_paint(&blur.*.base);
}
