// Translated to Zig from vendor/raven/src/widgets/color_picker.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/color_picker.c
// ColorPicker: a square of saturation and value, a strip of hues, a strip
// of opacity, the color before and the color now, a code, numbers, swatches.
//
// The color is kept as hue, saturation, value and opacity: red, green and
// blue are worked out from them, so that the hue of a gray and the
// saturation of black are not lost while the user drags.
//
// The square and the strips are drawn with three small textures that never
// change (a fade of white, a fade of black, the rainbow of hues): the square
// is the pure hue, under white that fades from left to right, under black
// that grows from top to bottom.
//
// The code and the numbers are ordinary widgets (a text input, spin boxes, a
// button) that the picker owns as children and places itself.
//
// With Popup, the widget is a swatch: it owns a second picker, shown in a
// popup, and the two keep each other up to date.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const libc = @import("../sys/libc.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const RVN_CP_STRIP: f32 = 16.0;
const RVN_CP_GAP: f32 = 10.0;
const RVN_CP_SWATCH: f32 = 20.0;
const RVN_CP_CHECK_WIDTH: c_int = 512;
const RVN_CP_CHECK_CELL: c_int = 8;

const RVN_CP_DRAG_NONE: c_int = 0;
const RVN_CP_DRAG_SQUARE: c_int = 1;
const RVN_CP_DRAG_HUE: c_int = 2;
const RVN_CP_DRAG_ALPHA: c_int = 3;

const rvn_color_picker_t = extern struct {
    base: widget_h.rvn_widget_t,
    /// Hue 0..360, the rest 0..1.
    h: f32,
    s: f32,
    v: f32,
    a: f32,
    previous: [4]f32,
    no_alpha: c_int,
    compact: c_int,
    popup_mode: c_int,
    hsv_fields: c_int,
    swatches: [*c]f32,
    swatch_count: u32,
    swatch_cap: u32,

    // the code and the numbers (NULL in popup mode)
    hex: [*c]widget_h.rvn_widget_t,
    mode: [*c]widget_h.rvn_widget_t,
    fields: [4][*c]widget_h.rvn_widget_t,
    /// The fields are being filled from the color: their callbacks must not answer.
    syncing: c_int,

    drag: c_int,
    hot_swatch: c_int,
    // where things are, from the last arrange
    square: base.rvn_rect_t,
    hue_strip: base.rvn_rect_t,
    alpha_strip: base.rvn_rect_t,
    preview: base.rvn_rect_t,
    swatch_area: base.rvn_rect_t,

    // popup mode: the panel shown in the popup and the picker inside it
    panel: [*c]widget_h.rvn_widget_t,
    inner: [*c]widget_h.rvn_widget_t,
    /// The swatch a picker shown in a popup belongs to, or 0.
    owner: raven.Rid,

    callback: raven.RColorChangedCallback,
    user_data: ?*anyopaque,
    hex_text: [16]u8,
};

// ---------------------------------------------------------------------------
//  Colors
// ---------------------------------------------------------------------------

export fn Rcolor_hsv_to_rgb(hue: f32, saturation: f32, value: f32, r: [*c]f32, g: [*c]f32, b: [*c]f32) void {
    var h: f32 = libc.fmodf(hue, 360.0);
    var rr: f32 = 0.0;
    var gg: f32 = 0.0;
    var bb: f32 = 0.0;
    if (h < 0.0) h += 360.0;
    const sat = base.rvn_clampf(saturation, 0.0, 1.0);
    const val = base.rvn_clampf(value, 0.0, 1.0);
    const c = val * sat;
    const x = c * (1.0 - @abs(libc.fmodf(h / 60.0, 2.0) - 1.0));
    const m = val - c;
    const sector: c_int = @rem(@as(c_int, @intFromFloat(h / 60.0)), 6);
    switch (sector) {
        0 => {
            rr = c;
            gg = x;
        },
        1 => {
            rr = x;
            gg = c;
        },
        2 => {
            gg = c;
            bb = x;
        },
        3 => {
            gg = x;
            bb = c;
        },
        4 => {
            rr = x;
            bb = c;
        },
        else => {
            rr = c;
            bb = x;
        },
    }
    if (r != null) r.* = rr + m;
    if (g != null) g.* = gg + m;
    if (b != null) b.* = bb + m;
}

export fn Rcolor_rgb_to_hsv(r: f32, g: f32, b: f32, hue: [*c]f32, saturation: [*c]f32, value: [*c]f32) void {
    const high = base.rvn_maxf(r, base.rvn_maxf(g, b));
    const low = base.rvn_minf(r, base.rvn_minf(g, b));
    const delta = high - low;
    var h: f32 = 0.0;
    if (delta > 1e-6) {
        if (high == r) {
            h = 60.0 * libc.fmodf((g - b) / delta, 6.0);
        } else if (high == g) {
            h = 60.0 * ((b - r) / delta + 2.0);
        } else {
            h = 60.0 * ((r - g) / delta + 4.0);
        }
        if (h < 0.0) h += 360.0;
    }
    if (hue != null) hue.* = h;
    if (saturation != null) saturation.* = if (high > 1e-6) delta / high else 0.0;
    if (value != null) value.* = high;
}

fn rvn_cp_rgb(picker: [*c]const rvn_color_picker_t, rgb: *[3]f32) void {
    Rcolor_hsv_to_rgb(picker.*.h, picker.*.s, picker.*.v, &rgb[0], &rgb[1], &rgb[2]);
}

fn rvn_cp_color(picker: [*c]const rvn_color_picker_t, with_alpha: c_int) base.rvn_color_t {
    var rgb: [3]f32 = undefined;
    rvn_cp_rgb(picker, &rgb);
    return base.rvn_rgba(rgb[0], rgb[1], rgb[2], if (with_alpha != 0 and picker.*.no_alpha == 0) picker.*.a else 1.0);
}

/// Takes red, green and blue, keeping the hue and the saturation they cannot tell.
fn rvn_cp_take_rgb(picker: [*c]rvn_color_picker_t, r: f32, g: f32, b: f32) void {
    const rc = base.rvn_clampf(r, 0.0, 1.0);
    const gc = base.rvn_clampf(g, 0.0, 1.0);
    const bc = base.rvn_clampf(b, 0.0, 1.0);
    var h: f32 = undefined;
    var s: f32 = undefined;
    var v: f32 = undefined;
    Rcolor_rgb_to_hsv(rc, gc, bc, &h, &s, &v);
    if (v > 1e-5) {
        if (s > 1e-5) picker.*.h = h;
        picker.*.s = s;
    }
    picker.*.v = v;
}

/// `painter->enabled`: the field is in draw.h, the painter is opaque to this file.
fn cpPainterEnabled(painter: ?*raven.RPainter) bool {
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    return dp.enabled != 0;
}

// ---------------------------------------------------------------------------
//  Textures shared by every picker
// ---------------------------------------------------------------------------

const CpTextures = extern struct {
    white_fade: raven.Rid,
    black_fade: raven.Rid,
    hues: raven.Rid,
    checker: raven.Rid,
};

var g_cp: CpTextures = std.mem.zeroes(CpTextures);

fn rvn_cp_textures() void {
    if (ext.rvn_texture_get(g_cp.white_fade) != null and ext.rvn_texture_get(g_cp.black_fade) != null and ext.rvn_texture_get(g_cp.hues) != null and ext.rvn_texture_get(g_cp.checker) != null) return;
    {
        var i: c_int = 0;
        // white that fades from left to right
        const pixels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(256 * 4)));
        while (i < 256) : (i += 1) {
            const k: usize = @intCast(i * 4);
            pixels[k + 0] = 255;
            pixels[k + 1] = 255;
            pixels[k + 2] = 255;
            pixels[k + 3] = @intCast(255 - i);
        }
        g_cp.white_fade = ext.rvn_texture_create_raw(256, 1, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
    }
    {
        var i: c_int = 0;
        // black that grows from top to bottom
        const pixels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(256 * 4)));
        while (i < 256) : (i += 1) {
            const k: usize = @intCast(i * 4);
            pixels[k + 0] = 0;
            pixels[k + 1] = 0;
            pixels[k + 2] = 0;
            pixels[k + 3] = @intCast(i);
        }
        g_cp.black_fade = ext.rvn_texture_create_raw(1, 256, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
    }
    {
        var i: c_int = 0;
        const pixels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(360 * 4)));
        while (i < 360) : (i += 1) {
            var r: f32 = undefined;
            var g: f32 = undefined;
            var b: f32 = undefined;
            Rcolor_hsv_to_rgb(@floatFromInt(i), 1.0, 1.0, &r, &g, &b);
            const k: usize = @intCast(i * 4);
            pixels[k + 0] = @intFromFloat(r * 255.0 + 0.5);
            pixels[k + 1] = @intFromFloat(g * 255.0 + 0.5);
            pixels[k + 2] = @intFromFloat(b * 255.0 + 0.5);
            pixels[k + 3] = 255;
        }
        g_cp.hues = ext.rvn_texture_create_raw(360, 1, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
    }
    {
        // the checkerboard that shows through colors that are not opaque: one texel per logical unit
        var x: c_int = 0;
        var y: c_int = 0;
        const height: c_int = RVN_CP_CHECK_CELL * 8;
        const width_u: usize = @intCast(RVN_CP_CHECK_WIDTH);
        const pixels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(width_u * @as(usize, @intCast(height)) * 4)));
        while (y < height) : (y += 1) {
            x = 0;
            while (x < RVN_CP_CHECK_WIDTH) : (x += 1) {
                const shade: u8 = if (@rem(@divTrunc(x, RVN_CP_CHECK_CELL) + @divTrunc(y, RVN_CP_CHECK_CELL), 2) != 0) 150 else 215;
                const out: [*c]u8 = pixels + ((@as(usize, @intCast(y)) * width_u + @as(usize, @intCast(x))) * 4);
                out[0] = shade;
                out[1] = shade;
                out[2] = shade;
                out[3] = 255;
            }
        }
        g_cp.checker = ext.rvn_texture_create_raw(RVN_CP_CHECK_WIDTH, height, raven.R_TEXTURE_RGBA8, raven.R_FILTER_NEAREST, pixels);
    }
}

/// The checkerboard under a rectangle, its cells the same size everywhere.
fn rvn_cp_paint_checker(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radius: f32) void {
    var uv: [4]f32 = undefined;
    uv[0] = 0.0;
    uv[1] = 0.0;
    uv[2] = base.rvn_minf(rect.w / @as(f32, @floatFromInt(RVN_CP_CHECK_WIDTH)), 1.0);
    uv[3] = base.rvn_minf(rect.h / @as(f32, @floatFromInt(RVN_CP_CHECK_CELL * 8)), 1.0);
    ext.rvn_paint_image(painter, rect, g_cp.checker, &uv, base.rvn_hex(0xFFFFFF, 255), radius);
}

/// A color that may not be opaque, over the checkerboard when it is not.
fn rvn_cp_paint_swatch(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radius: f32, color: base.rvn_color_t, border: base.rvn_color_t) void {
    if (base.rvn_color_a(color) < 255) rvn_cp_paint_checker(painter, rect, radius);
    ext.rvn_paint_box(painter, rect, radius, color, if (border != 0) 1.0 else 0.0, border);
}

// ---------------------------------------------------------------------------
//  The code and the numbers
// ---------------------------------------------------------------------------

fn rvn_cp_hex(picker: [*c]rvn_color_picker_t) [*c]const u8 {
    var rgb: [3]f32 = undefined;
    rvn_cp_rgb(picker, &rgb);
    const r: c_uint = @intFromFloat(rgb[0] * 255.0 + 0.5);
    const g: c_uint = @intFromFloat(rgb[1] * 255.0 + 0.5);
    const b: c_uint = @intFromFloat(rgb[2] * 255.0 + 0.5);
    const a: c_uint = @intFromFloat(picker.*.a * 255.0 + 0.5);
    if (picker.*.no_alpha == 0 and a < 255) {
        _ = libc.snprintf(&picker.*.hex_text, picker.*.hex_text.len, "#%02X%02X%02X%02X", r, g, b, a);
    } else {
        _ = libc.snprintf(&picker.*.hex_text, picker.*.hex_text.len, "#%02X%02X%02X", r, g, b);
    }
    return &picker.*.hex_text;
}

/// Writes the color into the code and the numbers. `except`: the field the user is typing in, left alone.
fn rvn_cp_sync_fields(picker: [*c]rvn_color_picker_t, except: [*c]const widget_h.rvn_widget_t) void {
    var rgb: [3]f32 = undefined;
    if (picker.*.hex == null) return;
    picker.*.syncing = raven.R_TRUE;
    rvn_cp_rgb(picker, &rgb);
    if (picker.*.hex != except) raven.Rtext_input_set_text(picker.*.hex.*.id, rvn_cp_hex(picker));
    if (picker.*.hsv_fields != 0) {
        if (picker.*.fields[0] != except) raven.Rspin_box_set_value(picker.*.fields[0].*.id, @floor(@as(f64, picker.*.h) + 0.5));
        if (picker.*.fields[1] != except) raven.Rspin_box_set_value(picker.*.fields[1].*.id, @floor(@as(f64, picker.*.s) * 100.0 + 0.5));
        if (picker.*.fields[2] != except) raven.Rspin_box_set_value(picker.*.fields[2].*.id, @floor(@as(f64, picker.*.v) * 100.0 + 0.5));
    } else {
        var i: c_int = 0;
        while (i < 3) : (i += 1) {
            const k: usize = @intCast(i);
            if (picker.*.fields[k] != except) raven.Rspin_box_set_value(picker.*.fields[k].*.id, @floor(@as(f64, rgb[k]) * 255.0 + 0.5));
        }
    }
    if (picker.*.fields[3] != except) raven.Rspin_box_set_value(picker.*.fields[3].*.id, @floor(@as(f64, picker.*.a) * 100.0 + 0.5));
    picker.*.syncing = raven.R_FALSE;
}

const rgb_tips = [4][*c]const u8{ "Red, 0 to 255", "Green, 0 to 255", "Blue, 0 to 255", "Opacity, in percent" };
const hsv_tips = [4][*c]const u8{ "Hue, 0 to 360 degrees", "Saturation, in percent", "Value, in percent", "Opacity, in percent" };

fn rvn_cp_field_ranges(picker: [*c]rvn_color_picker_t) void {
    if (picker.*.hex == null) return;
    picker.*.syncing = raven.R_TRUE;
    var i: c_int = 0;
    while (i < 4) : (i += 1) {
        const k: usize = @intCast(i);
        const high: f64 = if (i == 3) 100.0 else if (picker.*.hsv_fields != 0) (if (i == 0) 360.0 else 100.0) else 255.0;
        raven.Rspin_box_set_range(picker.*.fields[k].*.id, 0.0, high);
        _ = base.rvn_str_set(&picker.*.fields[k].*.tooltip, if (picker.*.hsv_fields != 0) hsv_tips[k] else rgb_tips[k]);
    }
    raven.Rbutton_set_text(picker.*.mode.*.id, if (picker.*.hsv_fields != 0) "HSV" else "RGB");
    picker.*.syncing = raven.R_FALSE;
}

fn rvn_cp_from_child(user_data: ?*anyopaque) [*c]rvn_color_picker_t {
    const widget = ext.rvn_widget_get(@truncate(@intFromPtr(user_data)));
    if (widget != null and widget.*.cls.*.@"type" == raven.R_WIDGET_COLOR_PICKER) return @ptrCast(widget);
    return null;
}

fn rvn_cp_hex_typed(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const picker = rvn_cp_from_child(user_data);
    var color: base.rvn_color_t = undefined;
    var buffer: [20]u8 = undefined;
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    if (picker == null or picker.*.syncing != 0 or text == null) return;
    var text_ = text;
    while (text_[0] == ' ') text_ += 1;
    const prefix: [*c]const u8 = if (text_[0] == '#') "" else "#";
    _ = libc.snprintf(&buffer, buffer.len, "%s%.15s", prefix, text_);
    if (ext.rvn_parse_color(&buffer, &color) == 0 and ext.rvn_parse_color(text_, &color) == 0) return;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    rvn_cp_take_rgb(picker, r, g, b);
    // (a code without opacity keeps the one there is)
    if (picker.*.no_alpha == 0 and libc.strlen(&buffer) == 9) picker.*.a = a;
    rvn_cp_changed(&picker.*.base, ext.rvn_widget_get(input), raven.R_TRUE);
}

fn rvn_cp_hex_committed(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const picker = rvn_cp_from_child(user_data);
    _ = input;
    _ = text;
    // what was typed is written back as a proper code
    if (picker != null) rvn_cp_sync_fields(picker, null);
}

fn rvn_cp_field_changed(spin: raven.Rid, value: f64, user_data: ?*anyopaque) callconv(.c) void {
    const picker = rvn_cp_from_child(user_data);
    const field = ext.rvn_widget_get(spin);
    var index: c_int = 0;
    if (picker == null or picker.*.syncing != 0 or field == null) return;
    while (index < 4 and picker.*.fields[@intCast(index)] != field) : (index += 1) {}
    if (index == 4) return;
    if (index == 3) {
        picker.*.a = @floatCast(value / 100.0);
    } else if (picker.*.hsv_fields != 0) {
        if (index == 0) {
            picker.*.h = @floatCast(value);
        } else if (index == 1) {
            picker.*.s = @floatCast(value / 100.0);
        } else {
            picker.*.v = @floatCast(value / 100.0);
        }
    } else {
        var rgb: [3]f32 = undefined;
        rvn_cp_rgb(picker, &rgb);
        rgb[@intCast(index)] = @floatCast(value / 255.0);
        rvn_cp_take_rgb(picker, rgb[0], rgb[1], rgb[2]);
    }
    rvn_cp_changed(&picker.*.base, field, raven.R_TRUE);
}

fn rvn_cp_mode_clicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const picker = rvn_cp_from_child(user_data);
    _ = button;
    if (picker == null) return;
    picker.*.hsv_fields = @intFromBool(picker.*.hsv_fields == 0);
    rvn_cp_field_ranges(picker);
    rvn_cp_sync_fields(picker, null);
}

/// Creates the code and the numbers.
fn rvn_cp_make_fields(widget: [*c]widget_h.rvn_widget_t) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const self: ?*anyopaque = @ptrFromInt(@as(usize, widget.*.id));
    if (picker.*.hex != null) return;
    picker.*.hex = ext.rvn_widget_create(raven.R_WIDGET_TEXT_INPUT);
    picker.*.mode = ext.rvn_widget_create(raven.R_WIDGET_BUTTON);
    ext.rvn_widget_add_child(widget, picker.*.hex, -1);
    ext.rvn_widget_add_child(widget, picker.*.mode, -1);
    raven.Rtext_input_set_max_length(picker.*.hex.*.id, 9);
    raven.Rtext_input_set_changed_callback(picker.*.hex.*.id, &rvn_cp_hex_typed, self);
    raven.Rtext_input_set_committed_callback(picker.*.hex.*.id, &rvn_cp_hex_committed, self);
    _ = base.rvn_str_set(&picker.*.hex.*.tooltip, "Code of the color: #RRGGBB or #RRGGBBAA");
    raven.Rbutton_set_clicked_callback(picker.*.mode.*.id, &rvn_cp_mode_clicked, self);
    _ = base.rvn_str_set(&picker.*.mode.*.tooltip, "Numbers as red, green, blue or as hue, saturation, value");
    var i: c_int = 0;
    while (i < 4) : (i += 1) {
        const k: usize = @intCast(i);
        picker.*.fields[k] = ext.rvn_widget_create(raven.R_WIDGET_SPIN_BOX);
        ext.rvn_widget_add_child(widget, picker.*.fields[k], -1);
        raven.Rspin_box_set_decimals(picker.*.fields[k].*.id, 0);
        raven.Rspin_box_set_step(picker.*.fields[k].*.id, 1.0);
        raven.Rspin_box_set_changed_callback(picker.*.fields[k].*.id, &rvn_cp_field_changed, self);
    }
    rvn_cp_field_ranges(picker);
    rvn_cp_sync_fields(picker, null);
}

fn rvn_cp_remove_fields(picker: [*c]rvn_color_picker_t) void {
    if (picker.*.hex == null) return;
    ext.rvn_widget_destroy(picker.*.hex);
    ext.rvn_widget_destroy(picker.*.mode);
    var i: c_int = 0;
    while (i < 4) : (i += 1) {
        const k: usize = @intCast(i);
        ext.rvn_widget_destroy(picker.*.fields[k]);
        picker.*.fields[k] = null;
    }
    picker.*.hex = null;
    picker.*.mode = null;
}

// ---------------------------------------------------------------------------
//  Changes
// ---------------------------------------------------------------------------

fn rvn_cp_copy_look(to: [*c]rvn_color_picker_t, from: [*c]const rvn_color_picker_t) void {
    var i: u32 = 0;
    to.*.h = from.*.h;
    to.*.s = from.*.s;
    to.*.v = from.*.v;
    to.*.a = from.*.a;
    to.*.no_alpha = from.*.no_alpha;
    to.*.swatch_count = 0;
    while (i < from.*.swatch_count) : (i += 1) {
        base.RVN_ARRAY_RESERVE(&to.*.swatches, &to.*.swatch_cap, (to.*.swatch_count + 1) * 4);
        const dst: usize = @as(usize, to.*.swatch_count) * 4;
        const src: usize = @as(usize, i) * 4;
        @memcpy(to.*.swatches[dst .. dst + 4], from.*.swatches[src .. src + 4]);
        to.*.swatch_count += 1;
    }
}

/// The color changed: the fields, the other half of a popup pair, and the application are told.
fn rvn_cp_changed(widget: [*c]widget_h.rvn_widget_t, except: [*c]const widget_h.rvn_widget_t, notify: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const owner = ext.rvn_widget_get(picker.*.owner);
    picker.*.h = base.rvn_clampf(picker.*.h, 0.0, 360.0);
    picker.*.s = base.rvn_clampf(picker.*.s, 0.0, 1.0);
    picker.*.v = base.rvn_clampf(picker.*.v, 0.0, 1.0);
    picker.*.a = if (picker.*.no_alpha != 0) 1.0 else base.rvn_clampf(picker.*.a, 0.0, 1.0);
    rvn_cp_sync_fields(picker, except);
    ext.rvn_widget_invalidate_paint(widget);

    if (picker.*.inner != null) {
        // a swatch: the picker of its popup follows
        const inner: [*c]rvn_color_picker_t = @ptrCast(picker.*.inner);
        inner.*.h = picker.*.h;
        inner.*.s = picker.*.s;
        inner.*.v = picker.*.v;
        inner.*.a = picker.*.a;
        rvn_cp_sync_fields(inner, null);
        ext.rvn_widget_invalidate_paint(picker.*.inner);
    }
    var widget_ = widget;
    var picker_ = picker;
    if (owner != null and owner.*.cls.*.@"type" == raven.R_WIDGET_COLOR_PICKER) {
        // the picker of a popup: its swatch takes the color, and is the one that tells the application
        const swatch: [*c]rvn_color_picker_t = @ptrCast(owner);
        swatch.*.h = picker.*.h;
        swatch.*.s = picker.*.s;
        swatch.*.v = picker.*.v;
        swatch.*.a = picker.*.a;
        ext.rvn_widget_invalidate_paint(owner);
        widget_ = owner;
        picker_ = swatch;
    }
    if (notify != 0) {
        var rgb: [3]f32 = undefined;
        rvn_cp_rgb(picker_, &rgb);
        if (picker_.*.callback) |callback| callback(widget_.*.id, rgb[0], rgb[1], rgb[2], picker_.*.a, picker_.*.user_data);
        if (common.rvn_widget_alive(widget_) != 0) ext.rvn_widget_fire_action(widget_);
    }
}

// ---------------------------------------------------------------------------
//  Popup mode
// ---------------------------------------------------------------------------

fn rvn_cp_make_popup(widget: [*c]widget_h.rvn_widget_t) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    if (picker.*.panel != null) return;
    picker.*.panel = ext.rvn_widget_create(raven.R_WIDGET_BORDER);
    picker.*.inner = ext.rvn_widget_create(raven.R_WIDGET_COLOR_PICKER);
    if (picker.*.panel == null or picker.*.inner == null) return;
    picker.*.panel.*.flags |= widget_h.RVN_WF_INTERNAL;
    _ = ext.rvn_widget_set_attribute(picker.*.panel, "Padding", "12");
    _ = ext.rvn_widget_set_attribute(picker.*.panel, "CornerRadius", "14");
    _ = ext.rvn_widget_set_attribute(picker.*.panel, "Shadow", "24,0,8");
    _ = ext.rvn_widget_set_attribute(picker.*.panel, "BorderWidth", "1");
    ext.rvn_widget_add_child(picker.*.panel, picker.*.inner, -1);
    const inner: [*c]rvn_color_picker_t = @ptrCast(picker.*.inner);
    inner.*.owner = widget.*.id;
    inner.*.base.fixed_size.x = 252.0;
}

fn rvn_cp_open(widget: [*c]widget_h.rvn_widget_t) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    var rgb: [3]f32 = undefined;
    if (widget.*.window == null) return;
    rvn_cp_make_popup(widget);
    if (picker.*.panel == null or (picker.*.panel.*.flags & widget_h.RVN_WF_POPUP) != 0) return;
    const inner: [*c]rvn_color_picker_t = @ptrCast(picker.*.inner);
    rvn_cp_copy_look(inner, picker);
    inner.*.compact = picker.*.compact;
    if (inner.*.compact != 0) {
        rvn_cp_remove_fields(inner);
    } else {
        rvn_cp_make_fields(picker.*.inner);
    }
    // what the color was when the popup opened is there to come back to
    rvn_cp_rgb(picker, &rgb);
    inner.*.previous[0] = rgb[0];
    inner.*.previous[1] = rgb[1];
    inner.*.previous[2] = rgb[2];
    inner.*.previous[3] = picker.*.a;
    rvn_cp_sync_fields(inner, null);
    // the panel is a surface of the theme, as a menu is
    ext.rvn_widget_set_color(picker.*.panel, raven.R_COLOR_PANEL, ext.rvn_widget_color(widget, raven.R_COLOR_POPUP));
    const origin = ext.rvn_widget_origin(widget);
    ext.rvn_window_open_popup(widget.*.window, picker.*.panel, widget, base.rvn_rect(origin.x, origin.y, widget.*.rect.w, widget.*.rect.h + 4.0), widget_h.RVN_POPUP_BELOW, 0.0);
}

// ---------------------------------------------------------------------------
//  Widget
// ---------------------------------------------------------------------------

fn rvn_color_picker_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    picker.*.h = 217.0;
    picker.*.s = 0.76;
    picker.*.v = 0.96;
    picker.*.a = 1.0;
    Rcolor_hsv_to_rgb(picker.*.h, picker.*.s, picker.*.v, &picker.*.previous[0], &picker.*.previous[1], &picker.*.previous[2]);
    picker.*.previous[3] = 1.0;
    picker.*.hot_swatch = -1;
    rvn_cp_make_fields(widget);
}

fn rvn_color_picker_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    if (picker.*.panel != null) {
        if (picker.*.panel.*.window != null and ext.g_rvn.initialized != 0) ext.rvn_window_close_popup(picker.*.panel.*.window, picker.*.panel);
        ext.rvn_widget_destroy(picker.*.panel);
    }
    base.rvn_free(picker.*.swatches);
}

fn rvn_cp_swatch_rows(picker: [*c]const rvn_color_picker_t, width: f32) f32 {
    if (picker.*.swatch_count == 0) return 0.0;
    const per_row: c_int = base.rvn_maxi(1, @intFromFloat((width + 6.0) / (RVN_CP_SWATCH + 6.0)));
    const pr: u32 = @intCast(per_row);
    return @floatFromInt((picker.*.swatch_count + pr - 1) / pr);
}

/// Height of everything under the square, for a width.
fn rvn_cp_below(picker: [*c]const rvn_color_picker_t, width: f32) f32 {
    const control = ext.rvn_widget_metric(&picker.*.base, raven.R_METRIC_CONTROL_HEIGHT);
    var height: f32 = RVN_CP_GAP + (if (picker.*.no_alpha != 0) RVN_CP_STRIP + 12.0 else RVN_CP_STRIP * 2.0 + 8.0);
    const rows = rvn_cp_swatch_rows(picker, width);
    if (picker.*.compact == 0) height += RVN_CP_GAP + control * 2.0 + 6.0;
    if (rows > 0.0) height += RVN_CP_GAP + rows * RVN_CP_SWATCH + (rows - 1.0) * 6.0;
    return height;
}

fn rvn_color_picker_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const control = ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT);
    var i: u32 = 0;
    rvn_cp_textures();
    // (the children are placed by hand, but still have to know their own size)
    while (i < widget.*.child_count) : (i += 1) _ = ext.rvn_widget_measure(widget.*.children[i]);
    if (picker.*.popup_mode != 0) return base.rvn_vec2(@floor(control * 1.7), control);
    return base.rvn_vec2(252.0, 150.0 + rvn_cp_below(picker, 252.0));
}

fn rvn_color_picker_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const width = widget.*.rect.w;
    const control = ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT);
    const below = rvn_cp_below(picker, width);
    const preview_width: f32 = 46.0;
    var y: f32 = undefined;
    var strips: f32 = undefined;

    if (picker.*.popup_mode != 0) return;
    // the square takes what the rest leaves
    picker.*.square = base.rvn_rect(0.0, 0.0, width, base.rvn_maxf(40.0, widget.*.rect.h - below));
    y = picker.*.square.h + RVN_CP_GAP;
    strips = if (picker.*.no_alpha != 0) RVN_CP_STRIP + 12.0 else RVN_CP_STRIP * 2.0 + 8.0;
    picker.*.preview = base.rvn_rect(0.0, y, preview_width, strips);
    picker.*.hue_strip = base.rvn_rect(preview_width + 12.0, if (picker.*.no_alpha != 0) y + 6.0 else y, base.rvn_maxf(20.0, width - preview_width - 12.0), RVN_CP_STRIP);
    picker.*.alpha_strip = if (picker.*.no_alpha != 0)
        base.rvn_rect(0.0, 0.0, 0.0, 0.0)
    else
        base.rvn_rect(picker.*.hue_strip.x, y + RVN_CP_STRIP + 8.0, picker.*.hue_strip.w, RVN_CP_STRIP);
    y += strips;

    if (picker.*.hex != null) {
        var i: c_int = 0;
        const gap: f32 = 6.0;
        const mode_width: f32 = 58.0;
        const count: c_int = if (picker.*.no_alpha != 0) 3 else 4;
        const field = @floor((width - gap * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count)));
        y += RVN_CP_GAP;
        ext.rvn_widget_arrange(picker.*.hex, 0.0, y, base.rvn_maxf(40.0, width - mode_width - gap), control);
        ext.rvn_widget_arrange(picker.*.mode, width - mode_width, y, mode_width, control);
        y += control + gap;
        while (i < 4) : (i += 1) {
            const k: usize = @intCast(i);
            if (i == 3 and picker.*.no_alpha != 0) {
                picker.*.fields[k].*.visibility = raven.R_COLLAPSED;
                continue;
            }
            picker.*.fields[k].*.visibility = raven.R_VISIBLE;
            ext.rvn_widget_arrange(picker.*.fields[k], (field + gap) * @as(f32, @floatFromInt(i)), y, if (i == count - 1) width - (field + gap) * @as(f32, @floatFromInt(i)) else field, control);
        }
        y += control;
    }
    picker.*.swatch_area = base.rvn_rect(0.0, y + RVN_CP_GAP, width, base.rvn_maxf(0.0, widget.*.rect.h - y - RVN_CP_GAP));
}

fn rvn_cp_swatch_rect(picker: [*c]const rvn_color_picker_t, index: u32) base.rvn_rect_t {
    const per_row: c_int = base.rvn_maxi(1, @intFromFloat((picker.*.swatch_area.w + 6.0) / (RVN_CP_SWATCH + 6.0)));
    const index_i: c_int = @bitCast(index);
    const row = @divTrunc(index_i, per_row);
    const column = @rem(index_i, per_row);
    return base.rvn_rect(picker.*.swatch_area.x + @as(f32, @floatFromInt(column)) * (RVN_CP_SWATCH + 6.0), picker.*.swatch_area.y + @as(f32, @floatFromInt(row)) * (RVN_CP_SWATCH + 6.0), RVN_CP_SWATCH, RVN_CP_SWATCH);
}

fn rvn_cp_swatch_at(picker: [*c]const rvn_color_picker_t, x: f32, y: f32) c_int {
    var i: u32 = 0;
    while (i < picker.*.swatch_count) : (i += 1) {
        if (base.rvn_rect_contains(rvn_cp_swatch_rect(picker, i), x, y) != 0) return @bitCast(i);
    }
    return -1;
}

/// The knob of a strip: a white pill with a thin dark edge, that shows the color it is on.
fn rvn_cp_paint_knob(painter: ?*raven.RPainter, strip: base.rvn_rect_t, fraction: f32, color: base.rvn_color_t, held: c_int) void {
    const width: f32 = if (held != 0) 12.0 else 10.0;
    const x = strip.x + base.rvn_clampf(fraction, 0.0, 1.0) * strip.w;
    const knob = base.rvn_rect(x - width * 0.5, strip.y - 3.0, width, strip.h + 6.0);
    ext.rvn_paint_shadow(painter, base.rvn_rect(knob.x, knob.y + 1.0, knob.w, knob.h), width * 0.5, 5.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.4));
    ext.rvn_paint_box(painter, knob, width * 0.5, base.rvn_hex(0xFFFFFF, 255), 0.0, 0);
    ext.rvn_paint_box(painter, base.rvn_rect(knob.x + 2.5, knob.y + 2.5, knob.w - 5.0, knob.h - 5.0), (width - 5.0) * 0.5, color, 0.0, 0);
}

fn rvn_color_picker_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const edge = ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_BORDER);
    const color = rvn_cp_color(picker, raven.R_TRUE);
    const opaque_ = rvn_cp_color(picker, raven.R_FALSE);

    if (picker.*.popup_mode != 0) {
        const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
        const open = picker.*.panel != null and (picker.*.panel.*.flags & widget_h.RVN_WF_POPUP) != 0;
        const radius = common.rvn_control_radius(widget, rect.h);
        const hover = common.rvn_widget_hover(widget, painter, @intFromBool(((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 or open) and cpPainterEnabled(painter)));
        const press = common.rvn_widget_press(widget, painter, @intFromBool((widget.*.flags & widget_h.RVN_WF_PRESSED) != 0));
        const inner = base.rvn_rect(3.0, 3.0, rect.w - 6.0, rect.h - 6.0);
        // a frame of the theme around the color, like a button around its text
        if (widget_h.rvn_widget_glass(widget) != 0) {
            common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_CONTROL, hover, press);
        } else {
            ext.rvn_paint_box(painter, rect, radius, base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL), ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_HOVERED), base.rvn_clampf(hover, 0.0, 1.0)), 1.0, edge);
        }
        rvn_cp_paint_swatch(painter, inner, base.rvn_maxf(radius - 3.0, 2.0), if (cpPainterEnabled(painter)) color else base.rvn_color_fade(color, 0.4), 0);
        common.rvn_widget_squash(widget, press, 0.04);
        return;
    }

    // the square: the pure hue, whitened to the left, darkened to the bottom
    var rgb: [3]f32 = undefined;
    Rcolor_hsv_to_rgb(picker.*.h, 1.0, 1.0, &rgb[0], &rgb[1], &rgb[2]);
    const pure = base.rvn_rgba(rgb[0], rgb[1], rgb[2], 1.0);
    ext.rvn_paint_box(painter, picker.*.square, 9.0, pure, 0.0, 0);
    ext.rvn_paint_image(painter, picker.*.square, g_cp.white_fade, null, base.rvn_hex(0xFFFFFF, 255), 9.0);
    ext.rvn_paint_image(painter, picker.*.square, g_cp.black_fade, null, base.rvn_hex(0xFFFFFF, 255), 9.0);
    ext.rvn_paint_box(painter, picker.*.square, 9.0, 0, 1.0, base.rvn_color_fade(edge, 0.7));
    {
        // where the color is in it: a ring that shows it
        const held = picker.*.drag == RVN_CP_DRAG_SQUARE;
        const size: f32 = if (held) 20.0 else 16.0;
        const x = picker.*.square.x + picker.*.s * picker.*.square.w;
        const y = picker.*.square.y + (1.0 - picker.*.v) * picker.*.square.h;
        const ring = base.rvn_rect(x - size * 0.5, y - size * 0.5, size, size);
        ext.rvn_paint_push_clip(painter, base.rvn_rect(picker.*.square.x - 12.0, picker.*.square.y - 12.0, picker.*.square.w + 24.0, picker.*.square.h + 24.0));
        ext.rvn_paint_shadow(painter, base.rvn_rect(ring.x, ring.y + 1.0, ring.w, ring.h), size * 0.5, 6.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.45));
        ext.rvn_paint_box(painter, ring, size * 0.5, opaque_, 2.5, base.rvn_hex(0xFFFFFF, 255));
        ext.rvn_paint_pop_clip(painter);
    }

    // before and now, side by side
    {
        const left = base.rvn_rect(picker.*.preview.x, picker.*.preview.y, picker.*.preview.w * 0.5, picker.*.preview.h);
        const right = base.rvn_rect(picker.*.preview.x + picker.*.preview.w * 0.5, picker.*.preview.y, picker.*.preview.w * 0.5, picker.*.preview.h);
        const before = base.rvn_rgba(picker.*.previous[0], picker.*.previous[1], picker.*.previous[2], if (picker.*.no_alpha != 0) 1.0 else picker.*.previous[3]);
        const radii_left = [4]f32{ 8.0, 0.0, 0.0, 8.0 };
        const radii_right = [4]f32{ 0.0, 8.0, 8.0, 0.0 };
        if (base.rvn_color_a(before) < 255 or base.rvn_color_a(color) < 255) rvn_cp_paint_checker(painter, picker.*.preview, 8.0);
        ext.rvn_paint_box4(painter, left, &radii_left, before, 0.0, 0);
        ext.rvn_paint_box4(painter, right, &radii_right, color, 0.0, 0);
        ext.rvn_paint_box(painter, picker.*.preview, 8.0, 0, 1.0, edge);
    }

    // the hues
    ext.rvn_paint_image(painter, picker.*.hue_strip, g_cp.hues, null, base.rvn_hex(0xFFFFFF, 255), RVN_CP_STRIP * 0.5);
    ext.rvn_paint_box(painter, picker.*.hue_strip, RVN_CP_STRIP * 0.5, 0, 1.0, base.rvn_color_fade(edge, 0.7));
    rvn_cp_paint_knob(painter, picker.*.hue_strip, picker.*.h / 360.0, pure, @intFromBool(picker.*.drag == RVN_CP_DRAG_HUE));

    // the opacity: the color fading in over the checkerboard
    if (picker.*.no_alpha == 0) {
        rvn_cp_paint_checker(painter, picker.*.alpha_strip, RVN_CP_STRIP * 0.5);
        var uv: [4]f32 = undefined;
        uv[0] = 1.0;
        uv[1] = 0.0;
        uv[2] = 0.0;
        uv[3] = 1.0;
        ext.rvn_paint_image(painter, picker.*.alpha_strip, g_cp.white_fade, &uv, opaque_, RVN_CP_STRIP * 0.5);
        ext.rvn_paint_box(painter, picker.*.alpha_strip, RVN_CP_STRIP * 0.5, 0, 1.0, base.rvn_color_fade(edge, 0.7));
        rvn_cp_paint_knob(painter, picker.*.alpha_strip, picker.*.a, color, @intFromBool(picker.*.drag == RVN_CP_DRAG_ALPHA));
    }

    var i: u32 = 0;
    while (i < picker.*.swatch_count) : (i += 1) {
        const swatch: [*c]const f32 = picker.*.swatches + @as(usize, i) * 4;
        var rect = rvn_cp_swatch_rect(picker, i);
        const swatch_color = base.rvn_rgba(swatch[0], swatch[1], swatch[2], if (picker.*.no_alpha != 0) 1.0 else swatch[3]);
        if (@as(c_int, @bitCast(i)) == picker.*.hot_swatch and cpPainterEnabled(painter)) rect = base.rvn_rect(rect.x - 2.0, rect.y - 2.0, rect.w + 4.0, rect.h + 4.0);
        rvn_cp_paint_swatch(painter, rect, 6.0, swatch_color, base.rvn_color_fade(edge, 0.8));
    }
}

fn rvn_color_picker_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    if (picker.*.popup_mode != 0) common.rvn_paint_focus(widget, painter, common.rvn_control_radius(widget, widget.*.rect.h));
}

fn rvn_cp_drag_to(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    switch (picker.*.drag) {
        RVN_CP_DRAG_SQUARE => {
            picker.*.s = base.rvn_clampf((x - picker.*.square.x) / base.rvn_maxf(picker.*.square.w, 1.0), 0.0, 1.0);
            picker.*.v = 1.0 - base.rvn_clampf((y - picker.*.square.y) / base.rvn_maxf(picker.*.square.h, 1.0), 0.0, 1.0);
        },
        RVN_CP_DRAG_HUE => {
            picker.*.h = base.rvn_clampf((x - picker.*.hue_strip.x) / base.rvn_maxf(picker.*.hue_strip.w, 1.0), 0.0, 1.0) * 360.0;
        },
        RVN_CP_DRAG_ALPHA => {
            picker.*.a = base.rvn_clampf((x - picker.*.alpha_strip.x) / base.rvn_maxf(picker.*.alpha_strip.w, 1.0), 0.0, 1.0);
        },
        else => return,
    }
    rvn_cp_changed(widget, null, raven.R_TRUE);
}

fn rvn_color_picker_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const x = event.*.local_x;
    const y = event.*.local_y;

    if (picker.*.popup_mode != 0) {
        switch (event.*.@"type") {
            raven.R_EVENT_MOUSE_DOWN => {
                if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
                widget.*.flags |= widget_h.RVN_WF_PRESSED;
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            },
            raven.R_EVENT_MOUSE_UP => {
                if (event.*.button != raven.R_MOUSE_LEFT or (widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
                widget.*.flags &= ~widget_h.RVN_WF_PRESSED;
                ext.rvn_widget_invalidate_paint(widget);
                if (x >= 0.0 and y >= 0.0 and x < widget.*.rect.w and y < widget.*.rect.h) rvn_cp_open(widget);
                return raven.R_TRUE;
            },
            raven.R_EVENT_KEY_DOWN => {
                if (event.*.key == raven.R_KEY_SPACE or event.*.key == raven.R_KEY_ENTER) {
                    rvn_cp_open(widget);
                    return raven.R_TRUE;
                }
                return raven.R_FALSE;
            },
            raven.R_EVENT_MOUSE_ENTER, raven.R_EVENT_MOUSE_LEAVE => {
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            },
            else => return raven.R_FALSE,
        }
    }

    var swatch: c_int = undefined;
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT or event.*.target != widget.*.id) return raven.R_FALSE;
            // (a little around the strips counts: their knobs stick out)
            if (base.rvn_rect_contains(picker.*.square, x, y) != 0) {
                picker.*.drag = RVN_CP_DRAG_SQUARE;
            } else if (base.rvn_rect_contains(base.rvn_rect(picker.*.hue_strip.x - 6.0, picker.*.hue_strip.y - 4.0, picker.*.hue_strip.w + 12.0, picker.*.hue_strip.h + 8.0), x, y) != 0) {
                picker.*.drag = RVN_CP_DRAG_HUE;
            } else if (picker.*.no_alpha == 0 and base.rvn_rect_contains(base.rvn_rect(picker.*.alpha_strip.x - 6.0, picker.*.alpha_strip.y - 4.0, picker.*.alpha_strip.w + 12.0, picker.*.alpha_strip.h + 8.0), x, y) != 0) {
                picker.*.drag = RVN_CP_DRAG_ALPHA;
            }
            if (picker.*.drag != 0) {
                ext.rvn_widget_capture_mouse(widget);
                rvn_cp_drag_to(widget, x, y);
                return raven.R_TRUE;
            }
            if (base.rvn_rect_contains(base.rvn_rect(picker.*.preview.x, picker.*.preview.y, picker.*.preview.w * 0.5, picker.*.preview.h), x, y) != 0) {
                // back to the color before
                rvn_cp_take_rgb(picker, picker.*.previous[0], picker.*.previous[1], picker.*.previous[2]);
                if (picker.*.no_alpha == 0) picker.*.a = picker.*.previous[3];
                rvn_cp_changed(widget, null, raven.R_TRUE);
                return raven.R_TRUE;
            }
            swatch = rvn_cp_swatch_at(picker, x, y);
            if (swatch >= 0) {
                const values: [*c]const f32 = picker.*.swatches + @as(usize, @intCast(swatch)) * 4;
                rvn_cp_take_rgb(picker, values[0], values[1], values[2]);
                if (picker.*.no_alpha == 0) picker.*.a = values[3];
                rvn_cp_changed(widget, null, raven.R_TRUE);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (picker.*.drag != 0) {
                rvn_cp_drag_to(widget, x, y);
                return raven.R_TRUE;
            }
            swatch = rvn_cp_swatch_at(picker, x, y);
            if (swatch != picker.*.hot_swatch) {
                picker.*.hot_swatch = swatch;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT or picker.*.drag == 0) return raven.R_FALSE;
            picker.*.drag = RVN_CP_DRAG_NONE;
            ext.rvn_widget_release_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            if (picker.*.hot_swatch >= 0) {
                picker.*.hot_swatch = -1;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_cp_add_swatch(picker: [*c]rvn_color_picker_t, r: f32, g: f32, b: f32, a: f32) void {
    base.RVN_ARRAY_RESERVE(&picker.*.swatches, &picker.*.swatch_cap, (picker.*.swatch_count + 1) * 4);
    const swatch: [*c]f32 = picker.*.swatches + @as(usize, picker.*.swatch_count) * 4;
    swatch[0] = base.rvn_clampf(r, 0.0, 1.0);
    swatch[1] = base.rvn_clampf(g, 0.0, 1.0);
    swatch[2] = base.rvn_clampf(b, 0.0, 1.0);
    swatch[3] = base.rvn_clampf(a, 0.0, 1.0);
    picker.*.swatch_count += 1;
}

fn rvn_cp_set_compact(widget: [*c]widget_h.rvn_widget_t, compact: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    picker.*.compact = @intFromBool(compact != 0);
    if (picker.*.compact != 0 or picker.*.popup_mode != 0) {
        rvn_cp_remove_fields(picker);
    } else {
        rvn_cp_make_fields(widget);
    }
    ext.rvn_widget_invalidate_layout(widget);
}

fn rvn_cp_set_popup(widget: [*c]widget_h.rvn_widget_t, popup: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    const on: c_int = @intFromBool(popup != 0);
    if (picker.*.popup_mode == on) return;
    picker.*.popup_mode = on;
    if (on != 0) {
        rvn_cp_remove_fields(picker);
        widget.*.flags |= widget_h.RVN_WF_FOCUSABLE;
    } else {
        if (picker.*.compact == 0) rvn_cp_make_fields(widget);
        widget.*.flags &= ~widget_h.RVN_WF_FOCUSABLE;
    }
    ext.rvn_widget_invalidate_layout(widget);
}

fn rvn_color_picker_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const picker: [*c]rvn_color_picker_t = @ptrCast(widget);
    var color: base.rvn_color_t = undefined;
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    var flag: c_int = undefined;

    if (base.rvn_stricmp(name, "Color") == 0 or base.rvn_stricmp(name, "Value") == 0) {
        if (ext.rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        base.rvn_color_to_floats(color, &r, &g, &b, &a);
        rvn_cp_take_rgb(picker, r, g, b);
        picker.*.a = a;
        // (the color it is given at first is also the one to compare with)
        picker.*.previous[0] = r;
        picker.*.previous[1] = g;
        picker.*.previous[2] = b;
        picker.*.previous[3] = a;
        rvn_cp_changed(widget, null, raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "Previous") == 0 or base.rvn_stricmp(name, "PreviousColor") == 0) {
        if (ext.rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        base.rvn_color_to_floats(color, &picker.*.previous[0], &picker.*.previous[1], &picker.*.previous[2], &picker.*.previous[3]);
    } else if (base.rvn_stricmp(name, "Alpha") == 0 or base.rvn_stricmp(name, "Opacity.Enabled") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        picker.*.no_alpha = @intFromBool(flag == 0);
        rvn_cp_changed(widget, null, raven.R_FALSE);
        ext.rvn_widget_invalidate_layout(widget);
    } else if (base.rvn_stricmp(name, "Popup") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_cp_set_popup(widget, flag);
    } else if (base.rvn_stricmp(name, "Compact") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_cp_set_compact(widget, flag);
    } else if (base.rvn_stricmp(name, "Numbers") == 0) {
        if (base.rvn_stricmp(value, "HSV") == 0) {
            picker.*.hsv_fields = raven.R_TRUE;
        } else if (base.rvn_stricmp(value, "RGB") == 0) {
            picker.*.hsv_fields = raven.R_FALSE;
        } else {
            return raven.R_FALSE;
        }
        rvn_cp_field_ranges(picker);
        rvn_cp_sync_fields(picker, null);
    } else if (base.rvn_stricmp(name, "Swatches") == 0) {
        // "#F00, #00FF00, blue"
        var cursor: [*c]const u8 = value;
        picker.*.swatch_count = 0;
        while (cursor[0] != 0) {
            var word: [24]u8 = undefined;
            var length: usize = 0;
            while (cursor[0] == ' ' or cursor[0] == ',') cursor += 1;
            while (cursor[length] != 0 and cursor[length] != ',' and cursor[length] != ' ' and length + 1 < word.len) length += 1;
            if (length == 0) break;
            @memcpy(word[0..length], cursor[0..length]);
            word[length] = 0;
            cursor += length;
            if (ext.rvn_parse_color(&word, &color) == 0) return raven.R_FALSE;
            base.rvn_color_to_floats(color, &r, &g, &b, &a);
            rvn_cp_add_swatch(picker, r, g, b, a);
        }
        ext.rvn_widget_invalidate_layout(widget);
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_color_picker: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_COLOR_PICKER,
    .name = "ColorPicker",
    .size = @sizeOf(rvn_color_picker_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_NO_MIRROR,
    .init = rvn_color_picker_init,
    .destroy = rvn_color_picker_destroy,
    .measure = rvn_color_picker_measure,
    .arrange = rvn_color_picker_arrange,
    .paint = rvn_color_picker_paint,
    .paint_overlay = rvn_color_picker_paint_overlay,
    .event = rvn_color_picker_event,
    .set_attribute = rvn_color_picker_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rcolor_picker_create() raven.Rid {
    if (ext.rvn_api_check("Rcolor_picker_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_COLOR_PICKER);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rcolor_picker_set_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_color"));
    if (picker == null) return;
    rvn_cp_take_rgb(picker, r, g, b);
    picker.*.a = a;
    rvn_cp_changed(&picker.*.base, null, raven.R_FALSE);
}

export fn Rcolor_picker_get_color(id: raven.Rid, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_get_color"));
    var rgb: [3]f32 = .{ 0.0, 0.0, 0.0 };
    if (picker != null) rvn_cp_rgb(picker, &rgb);
    if (r != null) r.* = rgb[0];
    if (g != null) g.* = rgb[1];
    if (b != null) b.* = rgb[2];
    if (a != null) a.* = if (picker != null) picker.*.a else 0.0;
}

export fn Rcolor_picker_set_hsv(id: raven.Rid, hue: f32, saturation: f32, value: f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_hsv"));
    if (picker == null) return;
    picker.*.h = if (hue < 0.0) libc.fmodf(hue, 360.0) + 360.0 else if (hue > 360.0) libc.fmodf(hue, 360.0) else hue;
    picker.*.s = saturation;
    picker.*.v = value;
    rvn_cp_changed(&picker.*.base, null, raven.R_FALSE);
}

export fn Rcolor_picker_get_hsv(id: raven.Rid, hue: [*c]f32, saturation: [*c]f32, value: [*c]f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_get_hsv"));
    if (hue != null) hue.* = if (picker != null) picker.*.h else 0.0;
    if (saturation != null) saturation.* = if (picker != null) picker.*.s else 0.0;
    if (value != null) value.* = if (picker != null) picker.*.v else 0.0;
}

export fn Rcolor_picker_set_hex(id: raven.Rid, text: [*c]const u8) c_int {
    var color: base.rvn_color_t = undefined;
    var buffer: [20]u8 = undefined;
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_hex"));
    if (picker == null) return raven.R_FALSE;
    if (text == null) return raven.R_FALSE;
    var text_ = text;
    while (text_[0] == ' ') text_ += 1;
    const prefix: [*c]const u8 = if (text_[0] == '#') "" else "#";
    _ = libc.snprintf(&buffer, buffer.len, "%s%.15s", prefix, text_);
    if (ext.rvn_parse_color(&buffer, &color) == 0) {
        if (ext.rvn_parse_color(text_, &color) == 0) return raven.R_FALSE;
        buffer[0] = 0;
    }
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    rvn_cp_take_rgb(picker, r, g, b);
    if (libc.strlen(&buffer) == 9 or libc.strlen(&buffer) == 5) picker.*.a = a;
    rvn_cp_changed(&picker.*.base, null, raven.R_FALSE);
    return raven.R_TRUE;
}

export fn Rcolor_picker_get_hex(id: raven.Rid) [*c]const u8 {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_get_hex"));
    if (picker == null) return "";
    return rvn_cp_hex(picker);
}

export fn Rcolor_picker_set_alpha_enabled(id: raven.Rid, enabled: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_alpha_enabled"));
    if (picker == null) return;
    picker.*.no_alpha = @intFromBool(enabled == 0);
    rvn_cp_changed(&picker.*.base, null, raven.R_FALSE);
    ext.rvn_widget_invalidate_layout(&picker.*.base);
}

export fn Rcolor_picker_set_previous_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_previous_color"));
    if (picker == null) return;
    picker.*.previous[0] = base.rvn_clampf(r, 0.0, 1.0);
    picker.*.previous[1] = base.rvn_clampf(g, 0.0, 1.0);
    picker.*.previous[2] = base.rvn_clampf(b, 0.0, 1.0);
    picker.*.previous[3] = base.rvn_clampf(a, 0.0, 1.0);
    ext.rvn_widget_invalidate_paint(&picker.*.base);
}

export fn Rcolor_picker_add_swatch(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_add_swatch"));
    if (picker == null) return;
    rvn_cp_add_swatch(picker, r, g, b, a);
    ext.rvn_widget_invalidate_layout(&picker.*.base);
}

export fn Rcolor_picker_clear_swatches(id: raven.Rid) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_clear_swatches"));
    if (picker == null) return;
    picker.*.swatch_count = 0;
    picker.*.hot_swatch = -1;
    ext.rvn_widget_invalidate_layout(&picker.*.base);
}

export fn Rcolor_picker_get_swatch_count(id: raven.Rid) c_int {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_get_swatch_count"));
    if (picker == null) return 0;
    return @bitCast(picker.*.swatch_count);
}

export fn Rcolor_picker_set_popup(id: raven.Rid, popup: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_popup"));
    if (picker == null) return;
    rvn_cp_set_popup(&picker.*.base, popup);
}

export fn Rcolor_picker_set_compact(id: raven.Rid, compact: c_int) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_compact"));
    if (picker == null) return;
    rvn_cp_set_compact(&picker.*.base, compact);
}

export fn Rcolor_picker_set_changed_callback(id: raven.Rid, callback: raven.RColorChangedCallback, user_data: ?*anyopaque) void {
    const picker: [*c]rvn_color_picker_t = @ptrCast(ext.rvn_widget_check(id, raven.R_WIDGET_COLOR_PICKER, "Rcolor_picker_set_changed_callback"));
    if (picker == null) return;
    picker.*.callback = callback;
    picker.*.user_data = user_data;
}
