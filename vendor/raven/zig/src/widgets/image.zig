// Translated to Zig from vendor/raven/src/widgets/image.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/image.c
// Image (Slate SImage): a texture, or a part of one, fitted in the widget.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_image_t = extern struct {
    base: widget_h.rvn_widget_t,
    texture: raven.Rid,
    tint: base.rvn_color_t,
    stretch: raven.RStretch,
    uv: [4]f32,
    radius: f32,
    /// R_TRUE: tinted with the text color (white glyphs that follow the theme), times `tint`.
    tint_text: c_int,
};

fn rvn_image_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.texture = raven.R_INVALID_ID;
    image.*.tint = 0xFFFFFFFF;
    image.*.stretch = raven.R_STRETCH_FIT;
    image.*.uv[2] = 1.0;
    image.*.uv[3] = 1.0;
}

/// Size of the shown part of the texture, in texels.
fn rvn_image_source_size(image: [*c]const rvn_image_t) base.rvn_vec2_t {
    const texture = ext.rvn_texture_get(image.*.texture);
    if (texture == null) return base.rvn_vec2(0.0, 0.0);
    return base.rvn_vec2(
        @as(f32, @floatFromInt(texture.*.width)) * @abs(image.*.uv[2] - image.*.uv[0]),
        @as(f32, @floatFromInt(texture.*.height)) * @abs(image.*.uv[3] - image.*.uv[1]),
    );
}

fn rvn_image_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    // one texel per logical unit unless the widget is given another size
    return rvn_image_source_size(@ptrCast(widget));
}

/// Computes where a source of `size` texels goes in a `width` x `height` area
/// and which part of it is visible. Shared with the viewport widget.
export fn rvn_image_fit(stretch: raven.RStretch, size: base.rvn_vec2_t, width: f32, height: f32, uv_in: [*c]const f32, rect: [*c]base.rvn_rect_t, uv_out: [*c]f32) void {
    var scale: f32 = undefined;
    @memcpy(uv_out[0..4], uv_in[0..4]);
    rect.* = base.rvn_rect(0.0, 0.0, width, height);
    if (size.x <= 0.0 or size.y <= 0.0 or width <= 0.0 or height <= 0.0) return;

    switch (stretch) {
        raven.R_STRETCH_FIT => {
            scale = base.rvn_minf(width / size.x, height / size.y);
            rect.*.w = size.x * scale;
            rect.*.h = size.y * scale;
            rect.*.x = (width - rect.*.w) * 0.5;
            rect.*.y = (height - rect.*.h) * 0.5;
        },
        raven.R_STRETCH_COVER => {
            // keep the whole area, show the centered part of the source that has its ratio
            const du = uv_in[2] - uv_in[0];
            const dv = uv_in[3] - uv_in[1];
            scale = base.rvn_maxf(width / size.x, height / size.y);
            const visible_u = width / (size.x * scale);
            const visible_v = height / (size.y * scale);
            uv_out[0] = uv_in[0] + du * (1.0 - visible_u) * 0.5;
            uv_out[2] = uv_in[2] - du * (1.0 - visible_u) * 0.5;
            uv_out[1] = uv_in[1] + dv * (1.0 - visible_v) * 0.5;
            uv_out[3] = uv_in[3] - dv * (1.0 - visible_v) * 0.5;
        },
        raven.R_STRETCH_NONE => {
            rect.*.w = size.x;
            rect.*.h = size.y;
            rect.*.x = @floor((width - size.x) * 0.5);
            rect.*.y = @floor((height - size.y) * 0.5);
        },
        raven.R_STRETCH_FILL => {},
        else => {},
    }
}

fn rvn_image_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const image: [*c]rvn_image_t = @ptrCast(widget);
    var rect: base.rvn_rect_t = undefined;
    var uv: [4]f32 = undefined;
    var tint = image.*.tint;

    if (image.*.texture == raven.R_INVALID_ID) return;
    rvn_image_fit(image.*.stretch, rvn_image_source_size(image), widget.*.rect.w, widget.*.rect.h, &image.*.uv, &rect, &uv);
    if (image.*.tint_text != 0) {
        const text = ext.rvn_widget_text_color(widget, painter);
        // the alpha of `tint` still applies
        tint = base.rvn_color_fade(text, @as(f32, @floatFromInt(base.rvn_color_a(image.*.tint))) / 255.0);
    }
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    if (dp.enabled == 0) tint = base.rvn_color_fade(tint, 0.4);
    // an unscaled image larger than the widget is cut at its bounds
    const clip = image.*.stretch == raven.R_STRETCH_NONE and (rect.w > widget.*.rect.w or rect.h > widget.*.rect.h);
    if (clip) ext.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
    ext.rvn_paint_image(painter, rect, image.*.texture, &uv, tint, image.*.radius);
    if (clip) ext.rvn_paint_pop_clip(painter);
}

export fn rvn_parse_stretch(value: [*c]const u8, stretch: [*c]raven.RStretch) c_int {
    if (base.rvn_stricmp(value, "Fill") == 0) {
        stretch.* = raven.R_STRETCH_FILL;
    } else if (base.rvn_stricmp(value, "Fit") == 0) {
        stretch.* = raven.R_STRETCH_FIT;
    } else if (base.rvn_stricmp(value, "Cover") == 0) {
        stretch.* = raven.R_STRETCH_COVER;
    } else if (base.rvn_stricmp(value, "None") == 0) {
        stretch.* = raven.R_STRETCH_NONE;
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

fn rvn_image_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const image: [*c]rvn_image_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Source") == 0) {
        image.*.texture = common.rvn_xml_texture(value);
        if (image.*.texture == raven.R_INVALID_ID) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Tint") == 0) {
        if (ext.rvn_parse_color(value, &image.*.tint) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "TintText") == 0) {
        if (ext.rvn_parse_bool(value, &image.*.tint_text) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Stretch") == 0) {
        if (rvn_parse_stretch(value, &image.*.stretch) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Region") == 0) {
        if (ext.rvn_parse_floats(value, &image.*.uv, 4) != 4) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "CornerRadius") == 0) {
        if (ext.rvn_parse_float(value, &image.*.radius) == 0) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_image: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_IMAGE,
    .name = "Image",
    .size = @sizeOf(rvn_image_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_NO_HIT,
    .init = rvn_image_init,
    .measure = rvn_image_measure,
    .paint = rvn_image_paint,
    .set_attribute = rvn_image_set_attribute,
});

export fn Rimage_set_texture(id: raven.Rid, texture: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_texture");
    if (widget == null) return;
    if (texture != raven.R_INVALID_ID and ext.rvn_texture_get(texture) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rimage_set_texture: invalid texture");
        return;
    }
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.texture = texture;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rimage_set_tint_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_tint_color");
    if (widget == null) return;
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.tint = base.rvn_rgba(r, g, b, a);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rimage_set_stretch(id: raven.Rid, stretch: raven.RStretch) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_stretch");
    if (widget == null) return;
    if (stretch < raven.R_STRETCH_FILL or stretch > raven.R_STRETCH_NONE) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rimage_set_stretch: invalid stretch mode");
        return;
    }
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.stretch = stretch;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rimage_set_region(id: raven.Rid, min_u: f32, min_v: f32, max_u: f32, max_v: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_region");
    if (widget == null) return;
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.uv[0] = min_u;
    image.*.uv[1] = min_v;
    image.*.uv[2] = max_u;
    image.*.uv[3] = max_v;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rimage_set_corner_radius(id: raven.Rid, radius: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_corner_radius");
    if (widget == null) return;
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.radius = if (radius > 0.0) radius else 0.0;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rimage_set_tint_text(id: raven.Rid, enabled: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_IMAGE, "Rimage_set_tint_text");
    if (widget == null) return;
    const image: [*c]rvn_image_t = @ptrCast(widget);
    image.*.tint_text = if (enabled != 0) raven.R_TRUE else raven.R_FALSE;
    widget_h.rvn_widget_invalidate_paint(widget);
}
