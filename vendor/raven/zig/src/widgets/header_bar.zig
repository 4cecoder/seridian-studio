// Translated to Zig from vendor/raven/src/widgets/header_bar.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/header_bar.c
// HeaderBar: the title bar of a window that draws its own (R_WINDOW_CUSTOM_HEADER).
//
// The bar is one widget: it paints the title and the window buttons itself and
// lays out its children like a horizontal box, from the left and, for those
// aligned to the right, from the right. Moving the window is not done here:
// the bar only says which of its points drag (rvn_widget_class_t::window_drag_at)
// and the window, or the window system, does the rest.
//
// TitleStyle="Notch": the title sits in a dark tab hanging from the top edge,
// in the middle of the window (its sides slant, its bottom corners are round).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

// indexes of the window buttons
const RVN_HB_CLOSE = 0;
const RVN_HB_MINIMIZE = 1;
const RVN_HB_MAXIMIZE = 2;
const RVN_HB_COUNT = 3;

const rvn_header_bar_t = extern struct {
    base: widget_h.rvn_widget_t,
    /// NULL: the title of the window.
    title: [*c]u8,
    buttons: raven.Ruint,
    /// R_HALIGN_RIGHT: glyph buttons (Windows). R_HALIGN_LEFT: colored lights (macOS).
    side: raven.RHAlign,
    title_align: raven.RHAlign,
    no_background: c_int,
    /// R_TRUE: the title is in a dark tab hanging from the top (TitleStyle="Notch").
    notch: c_int,
    /// Button under the pointer and button being pressed, or -1.
    hot: c_int,
    down: c_int,
    hover: [RVN_HB_COUNT]raven.RSpring,
    press: [RVN_HB_COUNT]raven.RSpring,
    /// Lights: their glyphs show while the pointer is on one of them.
    glyphs: raven.RSpring,
    /// Space left free by the children, where the title goes (set by arrange).
    gap_x0: f32,
    gap_x1: f32,
};

const RVN_HB_SPACING: f32 = 6.0;
const RVN_HB_PADDING: f32 = 8.0;

fn rvn_header_bar_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.buttons = raven.R_HEADER_ALL_BUTTONS;
    bar.*.side = raven.R_HALIGN_RIGHT;
    bar.*.title_align = raven.R_HALIGN_CENTER;
    bar.*.hot = -1;
    bar.*.down = -1;
    widget.*.flags |= widget_h.RVN_WF_WINDOW_DRAG;
}

fn rvn_header_bar_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    base.rvn_free(bar.*.title);
}

// ---------------------------------------------------------------------------
//  Window buttons
// ---------------------------------------------------------------------------

fn rvn_header_bar_has(widget: [*c]const widget_h.rvn_widget_t, button: c_int) c_int {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    const masks = [RVN_HB_COUNT]raven.Ruint{ raven.R_HEADER_CLOSE, raven.R_HEADER_MINIMIZE, raven.R_HEADER_MAXIMIZE };
    if ((bar.*.buttons & masks[@intCast(button)]) == 0) return raven.R_FALSE;
    // a window that cannot be resized cannot be maximized
    if (button == RVN_HB_MAXIMIZE and widget.*.window != null and (widget.*.window.*.window_flags & raven.R_WINDOW_NO_RESIZE) != 0) return raven.R_FALSE;
    return raven.R_TRUE;
}

// The buttons from left to right. Returns how many there are.
fn rvn_header_bar_order(widget: [*c]const widget_h.rvn_widget_t, order: [*c]c_int) c_int {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    const right = [RVN_HB_COUNT]c_int{ RVN_HB_MINIMIZE, RVN_HB_MAXIMIZE, RVN_HB_CLOSE };
    const left = [RVN_HB_COUNT]c_int{ RVN_HB_CLOSE, RVN_HB_MINIMIZE, RVN_HB_MAXIMIZE };
    const from: *const [RVN_HB_COUNT]c_int = if (bar.*.side == raven.R_HALIGN_LEFT) &left else &right;
    var count: c_int = 0;
    var i: c_int = 0;
    while (i < RVN_HB_COUNT) : (i += 1) {
        if (rvn_header_bar_has(widget, from[@intCast(i)]) != 0) {
            order[@intCast(count)] = from[@intCast(i)];
            count += 1;
        }
    }
    return count;
}

// Width and gap of one button for the current side and theme.
fn rvn_header_bar_button_metrics(widget: [*c]const widget_h.rvn_widget_t, size: [*c]f32, gap: [*c]f32, margin: [*c]f32) void {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    if (bar.*.side == raven.R_HALIGN_LEFT) {
        size.* = 13.0;
        gap.* = 8.0;
        margin.* = 14.0;
    } else if (widget_h.rvn_widget_glass(widget) != 0) {
        size.* = 28.0;
        gap.* = 6.0;
        margin.* = 10.0;
    } else {
        size.* = 46.0;
        gap.* = 0.0;
        margin.* = 0.0;
    }
}

// Width the buttons take at their end of the bar.
fn rvn_header_bar_buttons_width(widget: [*c]const widget_h.rvn_widget_t) f32 {
    var order: [RVN_HB_COUNT]c_int = undefined;
    const count = rvn_header_bar_order(widget, &order);
    var size: f32 = undefined;
    var gap: f32 = undefined;
    var margin: f32 = undefined;
    if (count == 0) return 0.0;
    rvn_header_bar_button_metrics(widget, &size, &gap, &margin);
    return margin + size * @as(f32, @floatFromInt(count)) + gap * @as(f32, @floatFromInt(count - 1)) + (if (margin > 0.0) @as(f32, 4.0) else @as(f32, 0.0));
}

// Where a button is drawn. R_FALSE when the bar does not show it.
fn rvn_header_bar_button_rect(widget: [*c]const widget_h.rvn_widget_t, button: c_int, rect: [*c]base.rvn_rect_t) c_int {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    var order: [RVN_HB_COUNT]c_int = undefined;
    const count = rvn_header_bar_order(widget, &order);
    var i: c_int = undefined;
    var size: f32 = undefined;
    var gap: f32 = undefined;
    var margin: f32 = undefined;
    var x: f32 = undefined;

    rvn_header_bar_button_metrics(widget, &size, &gap, &margin);
    x = if (bar.*.side == raven.R_HALIGN_LEFT) margin else widget.*.rect.w - margin - size * @as(f32, @floatFromInt(count)) - gap * @as(f32, @floatFromInt(count - 1));
    i = 0;
    while (i < count) : (i += 1) {
        if (order[@intCast(i)] == button) {
            if (bar.*.side != raven.R_HALIGN_LEFT and widget_h.rvn_widget_glass(widget) == 0) {
                rect.* = base.rvn_rect(x, 0.0, size, widget.*.rect.h);
            } else {
                rect.* = base.rvn_rect(x, @floor((widget.*.rect.h - size) * 0.5), size, size);
            }
            return raven.R_TRUE;
        }
        x += size + gap;
    }
    return raven.R_FALSE;
}

fn rvn_header_bar_button_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    // small round buttons are easier to hit a little outside of their circle
    const slack: f32 = if (bar.*.side == raven.R_HALIGN_LEFT or widget_h.rvn_widget_glass(widget) != 0) 3.0 else 0.0;
    var i: c_int = 0;
    while (i < RVN_HB_COUNT) : (i += 1) {
        var rect: base.rvn_rect_t = undefined;
        if (rvn_header_bar_button_rect(widget, i, &rect) == 0) continue;
        if (x >= rect.x - slack and x < rect.x + rect.w + slack and y >= rect.y - slack and y < rect.y + rect.h + slack) return i;
    }
    return -1;
}

fn rvn_header_bar_drag_at(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) callconv(.c) c_int {
    return @intFromBool(rvn_header_bar_button_at(widget, x, y) < 0);
}

// ---------------------------------------------------------------------------
//  Layout
// ---------------------------------------------------------------------------

fn rvn_header_bar_title(widget: [*c]const widget_h.rvn_widget_t) [*c]const u8 {
    const bar: [*c]const rvn_header_bar_t = @ptrCast(widget);
    if (bar.*.title != null) return bar.*.title;
    if (widget.*.window != null and widget.*.window.*.title != null) return widget.*.window.*.title;
    return "";
}

fn rvn_header_bar_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    var width: f32 = RVN_HB_PADDING * 2.0 + rvn_header_bar_buttons_width(widget);
    var height: f32 = widget_h.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT) + (if (widget_h.rvn_widget_glass(widget) != 0) @as(f32, 16.0) else @as(f32, 10.0));
    const title = rvn_header_bar_title(widget);
    var i: u32 = 0;

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = widget_h.rvn_widget_measure_slot(child);
        width += size.x + RVN_HB_SPACING;
        height = base.rvn_maxf(height, size.y + 8.0);
    }
    if (title[0] != 0) width += common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, title) + 24.0;
    return base.rvn_vec2(width, height);
}

fn rvn_header_bar_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    const buttons = rvn_header_bar_buttons_width(widget);
    const x0: f32 = RVN_HB_PADDING + (if (bar.*.side == raven.R_HALIGN_LEFT) buttons else 0.0);
    const x1: f32 = widget.*.rect.w - RVN_HB_PADDING - (if (bar.*.side == raven.R_HALIGN_LEFT) 0.0 else buttons);
    var fixed: f32 = 0.0;
    var fill_total: f32 = 0.0;
    var right_width: f32 = 0.0;
    var x: f32 = undefined;
    var i: u32 = 0;
    var visible: u32 = 0;
    var pass: c_int = undefined;

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        fixed += child.*.slot.padding.l + child.*.slot.padding.r;
        if (child.*.slot.is_fill != 0) {
            fill_total += child.*.slot.fill;
        } else {
            fixed += child.*.desired.x;
        }
        visible += 1;
    }
    if (visible > 1) fixed += RVN_HB_SPACING * @as(f32, @floatFromInt(visible - 1));
    const remaining = base.rvn_maxf(0.0, x1 - x0 - fixed);

    // the children packed at the right keep their order: their total width is needed first
    pass = 0;
    while (pass < 2) : (pass += 1) {
        x = if (pass == 0) x0 else x1 - right_width;
        i = 0;
        while (i < widget.*.child_count) : (i += 1) {
            const child = widget.*.children[i];
            const at_right = child.*.slot.halign == raven.R_HALIGN_RIGHT;
            if (widget_h.rvn_widget_collapsed(child) != 0) continue;
            var width: f32 = if (child.*.slot.is_fill != 0) (if (fill_total > 0.0) remaining * child.*.slot.fill / fill_total else 0.0) else child.*.desired.x;
            if (child.*.slot.max_size > 0.0 and width > child.*.slot.max_size) width = child.*.slot.max_size;
            const slot_width = width + child.*.slot.padding.l + child.*.slot.padding.r;
            if (at_right != (pass == 1)) {
                if (pass == 0) right_width += slot_width + RVN_HB_SPACING;
                continue;
            }
            // a control keeps its height and sits in the middle of the bar
            const height = base.rvn_minf(child.*.desired.y + child.*.slot.padding.t + child.*.slot.padding.b, widget.*.rect.h);
            if (child.*.slot.valign == raven.R_VALIGN_FILL) {
                widget_h.rvn_widget_arrange_slot(child, base.rvn_rect(x, @floor((widget.*.rect.h - height) * 0.5), slot_width, height));
            } else {
                widget_h.rvn_widget_arrange_slot(child, base.rvn_rect(x, 0.0, slot_width, widget.*.rect.h));
            }
            x += slot_width + RVN_HB_SPACING;
        }
        if (pass == 0) {
            bar.*.gap_x0 = x;
            if (right_width > 0.0) right_width -= RVN_HB_SPACING;
            bar.*.gap_x1 = x1 - right_width - (if (right_width > 0.0) RVN_HB_SPACING else 0.0);
        }
    }
}

// ---------------------------------------------------------------------------
//  Paint
// ---------------------------------------------------------------------------

fn rvn_header_bar_glyph(painter: ?*raven.RPainter, button: c_int, maximized: c_int, light: c_int, cx: f32, cy: f32, size: f32, color: base.rvn_color_t) void {
    const half = size * 0.5;
    const thickness: f32 = if (light != 0) 1.3 else 1.1;
    switch (button) {
        RVN_HB_CLOSE => {
            ext.rvn_paint_line(painter, cx - half, cy - half, cx + half, cy + half, thickness, color);
            ext.rvn_paint_line(painter, cx - half, cy + half, cx + half, cy - half, thickness, color);
        },
        RVN_HB_MINIMIZE => {
            ext.rvn_paint_line(painter, cx - half, cy, cx + half, cy, thickness, color);
        },
        else => {
            if (light != 0) {
                // a plus, as on the green light
                ext.rvn_paint_line(painter, cx - half, cy, cx + half, cy, thickness, color);
                ext.rvn_paint_line(painter, cx, cy - half, cx, cy + half, thickness, color);
            } else if (maximized != 0) {
                // two windows one behind the other: "restore"
                const inset = size * 0.22;
                ext.rvn_paint_box(painter, base.rvn_rect(cx - half + inset, cy - half, size - inset, size - inset), 1.5, 0, thickness, color);
                ext.rvn_paint_box(painter, base.rvn_rect(cx - half, cy - half + inset, size - inset, size - inset), 1.5, 0, thickness, color);
            } else {
                ext.rvn_paint_box(painter, base.rvn_rect(cx - half, cy - half, size, size), 1.5, 0, thickness, color);
            }
        },
    }
}

fn rvn_header_bar_paint_button(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, button: c_int) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    const window = widget.*.window;
    var rect: base.rvn_rect_t = undefined;
    var text = widget_h.rvn_widget_text_color(widget, painter);
    const red = base.rvn_hex(0xE5484D, 255);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    var first_instance: u32 = dp.list.*.instance_count;
    var first_command: u32 = dp.list.*.command_count;
    const maximized: c_int = @intFromBool(window != null and window.*.state == plat_h.RVN_PWINDOW_MAXIMIZED);
    const active: c_int = @intFromBool(window == null or window.*.active != 0);
    var hover: f32 = undefined;
    var press: f32 = undefined;
    var cx: f32 = undefined;
    var cy: f32 = undefined;
    var scale: f32 = undefined;

    if (rvn_header_bar_button_rect(widget, button, &rect) == 0) return;
    const idx: usize = @intCast(button);
    hover = ext.rvn_paint_spring(painter, &bar.*.hover[idx], if (bar.*.hot == button and dp.enabled != 0) 1.0 else 0.0, raven.R_MOTION_BOUNCY);
    press = ext.rvn_paint_spring(painter, &bar.*.press[idx], if (bar.*.down == button and bar.*.hot == button) 1.0 else 0.0, raven.R_MOTION_SNAPPY);
    cx = rect.x + rect.w * 0.5;
    cy = rect.y + rect.h * 0.5;

    if (bar.*.side == raven.R_HALIGN_LEFT) {
        // three lights: red, yellow, green; grey while the window is in the background
        const colors = [RVN_HB_COUNT]u32{ 0xFF5F57, 0xFEBC2E, 0x28C840 };
        const glyphs = base.rvn_clampf(bar.*.glyphs.value, 0.0, 1.0);
        const fill = if (active != 0) base.rvn_hex(colors[idx], 255) else base.rvn_color_fade(text, 0.22);
        ext.rvn_paint_box(painter, rect, rect.w * 0.5, fill, 0.5, base.rvn_rgba(0.0, 0.0, 0.0, 0.18));
        if (glyphs > 0.02) {
            rvn_header_bar_glyph(painter, button, maximized, raven.R_TRUE, cx, cy, if (button == RVN_HB_CLOSE) 5.0 else 6.5, base.rvn_rgba(0.0, 0.0, 0.0, 0.6 * glyphs));
        }
        scale = 1.0 + 0.26 * hover - 0.2 * press;
    } else if (widget_h.rvn_widget_glass(widget) != 0) {
        // a bead of glass; the one that closes turns red under the pointer
        const mix = base.rvn_clampf(hover, 0.0, 1.0);
        common.rvn_paint_surface(painter, widget, rect, rect.w * 0.5, common.RVN_SURFACE_CONTROL, hover, press);
        if (button == RVN_HB_CLOSE and mix > 0.01) {
            ext.rvn_paint_box(painter, rect, rect.w * 0.5, base.rvn_color_fade(red, 0.88 * mix), 0.0, 0);
            text = base.rvn_color_mix(text, base.rvn_hex(0xFFFFFF, 255), mix);
        }
        rvn_header_bar_glyph(painter, button, maximized, raven.R_FALSE, cx, cy, 9.0, text);
        scale = 1.0 + 0.14 * hover - 0.16 * press;
    } else {
        const mix = base.rvn_clampf(hover, 0.0, 1.0);
        const pressed = base.rvn_clampf(press, 0.0, 1.0);
        var fill: base.rvn_color_t = undefined;
        if (button == RVN_HB_CLOSE) {
            fill = base.rvn_color_fade(base.rvn_color_mix(red, base.rvn_hex(0xB3262B, 255), pressed), mix);
            text = base.rvn_color_mix(text, base.rvn_hex(0xFFFFFF, 255), mix);
        } else {
            fill = base.rvn_color_mix(
                base.rvn_color_fade(widget_h.rvn_widget_color(widget, raven.R_COLOR_CONTROL_HOVERED), mix),
                widget_h.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED),
                pressed,
            );
        }
        ext.rvn_paint_rect(painter, rect, fill);
        // only the glyph moves: the button itself is a part of the bar
        first_instance = dp.list.*.instance_count;
        first_command = dp.list.*.command_count;
        rvn_header_bar_glyph(painter, button, maximized, raven.R_FALSE, cx, cy, 10.0, if (active != 0) text else base.rvn_color_fade(text, 0.55));
        scale = 1.0 + 0.22 * hover - 0.28 * press;
    }
    if (scale < 0.999 or scale > 1.001) {
        ext.rvn_drawlist_transform(dp.list, first_instance, first_command, scale, scale, (dp.ox + cx) * dp.scale, (dp.oy + cy) * dp.scale, 0.0, 0.0, dp.clip);
    }
}

fn rvn_header_bar_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const title = rvn_header_bar_title(widget);
    const active: c_int = @intFromBool(widget.*.window == null or widget.*.window.*.active != 0);
    var i: c_int = 0;

    if (bar.*.no_background == 0) {
        if (widget_h.rvn_widget_glass(widget) != 0) {
            common.rvn_paint_surface(painter, widget, rect, 0.0, common.RVN_SURFACE_BAR, 0.0, 0.0);
        } else {
            ext.rvn_paint_rect(painter, rect, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER));
            ext.rvn_paint_rect(painter, base.rvn_rect(0.0, rect.h - 1.0, rect.w, 1.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
        }
    }

    if (title[0] != 0 and bar.*.gap_x1 - bar.*.gap_x0 > 24.0) {
        const color = widget_h.rvn_widget_text_color(widget, painter);
        const width = common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, title);
        const gap = bar.*.gap_x1 - bar.*.gap_x0 - 16.0;
        var x: f32 = undefined;
        if (bar.*.title_align == raven.R_HALIGN_LEFT) {
            x = bar.*.gap_x0 + 8.0;
        } else {
            // in the middle of the window when it fits there, else in the middle of the room left
            // (a notch needs room for its sides too)
            const room: f32 = if (bar.*.notch != 0) 30.0 else 8.0;
            x = @floor((rect.w - width) * 0.5);
            if (x < bar.*.gap_x0 + room or x + width > bar.*.gap_x1 - room) x = bar.*.gap_x0 + 8.0 + base.rvn_maxf(0.0, @floor((gap - width) * 0.5));
        }
        ext.rvn_paint_push_clip(painter, base.rvn_rect(bar.*.gap_x0 + 8.0, 0.0, gap, rect.h));
        if (bar.*.notch != 0) {
            // a dark tab hanging from the top edge: slanted sides, round bottom corners
            const pad: f32 = 18.0;
            const slant: f32 = 9.0;
            const radius: f32 = 7.0;
            const height = base.rvn_maxf(16.0, base.rvn_minf(rect.h - 5.0, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT) + 4.0));
            const nx = x - pad;
            const nw = width + pad * 2.0;
            const radii = [4]f32{ 0.0, 0.0, radius, radius };
            var fill = base.rvn_color_mix(widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER), base.rvn_rgba(0.04, 0.04, 0.05, 1.0), 0.9);
            const edge = base.rvn_color_fade(base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.07);
            var text = base.rvn_rgba(0.94, 0.94, 0.96, 1.0);
            if (active == 0) {
                fill = base.rvn_color_mix(fill, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER), 0.35);
                text = base.rvn_color_fade(text, 0.6);
            }
            ext.rvn_paint_shadow(painter, base.rvn_rect(nx, -radius, nw, height + radius), radius, 8.0, base.rvn_color_fade(base.rvn_rgba(0.0, 0.0, 0.0, 1.0), if (active != 0) 0.28 else 0.12));
            ext.rvn_paint_box4(painter, base.rvn_rect(nx, -1.0, nw, height + 1.0), &radii, fill, 0.0, 0);
            // the slanted sides
            ext.rvn_paint_triangle(painter, nx - slant, -1.0, nx + 0.5, -1.0, nx + 0.5, height - radius, fill);
            ext.rvn_paint_triangle(painter, nx + nw - 0.5, -1.0, nx + nw + slant, -1.0, nx + nw - 0.5, height - radius, fill);
            // a faint light on its lower edge
            ext.rvn_paint_rect(painter, base.rvn_rect(nx + radius, height - 1.0, nw - radius * 2.0, 1.0), edge);
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, 0.0, base.rvn_rect(x, 0.0, width + 2.0, height), 0.0, title, -1, text);
        } else {
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, 0.0, base.rvn_rect(x, 0.0, width + 2.0, rect.h), 0.0, title, -1, if (active != 0) color else base.rvn_color_fade(color, 0.5));
        }
        ext.rvn_paint_pop_clip(painter);
    }

    if (bar.*.side == raven.R_HALIGN_LEFT) _ = ext.rvn_paint_spring(painter, &bar.*.glyphs, if (bar.*.hot >= 0) 1.0 else 0.0, raven.R_MOTION_SNAPPY);
    while (i < RVN_HB_COUNT) : (i += 1) rvn_header_bar_paint_button(widget, painter, i);
}

// ---------------------------------------------------------------------------
//  Events
// ---------------------------------------------------------------------------

fn rvn_header_bar_trigger(widget: [*c]widget_h.rvn_widget_t, button: c_int) void {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    const window = widget.*.window;
    if (window == null) return;
    // the button springs back past its size
    ext.rvn_spring_kick(&bar.*.hover[@intCast(button)], 6.0);
    switch (button) {
        RVN_HB_CLOSE => {
            widget_h.rvn_window_request_close(window);
        },
        RVN_HB_MINIMIZE => {
            const plat: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
            plat.*.window_set_state.?(window.*.platform, plat_h.RVN_PWINDOW_MINIMIZED);
        },
        else => {
            widget_h.rvn_window_toggle_maximized(window);
        },
    }
}

fn rvn_header_bar_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    var at = rvn_header_bar_button_at(widget, event.*.local_x, event.*.local_y);

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            // (the event bubbles up from the children: the pointer is then on one of them, not on a button)
            if (event.*.target != widget.*.id and bar.*.down < 0) at = -1;
            if (bar.*.hot != at) {
                bar.*.hot = at;
                widget_h.rvn_widget_invalidate_paint(widget);
            }
            return @intFromBool(bar.*.down >= 0);
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            if (bar.*.hot >= 0 and bar.*.down < 0) {
                bar.*.hot = -1;
                widget_h.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT or event.*.target != widget.*.id or at < 0) return raven.R_FALSE;
            bar.*.down = at;
            bar.*.hot = at;
            widget_h.rvn_widget_capture_mouse(widget);
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            const down = bar.*.down;
            if (event.*.button != raven.R_MOUSE_LEFT or down < 0) return raven.R_FALSE;
            bar.*.down = -1;
            bar.*.hot = at;
            widget_h.rvn_widget_release_mouse(widget);
            widget_h.rvn_widget_invalidate_paint(widget);
            if (at == down) rvn_header_bar_trigger(widget, down);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_header_bar_parse_buttons(value: [*c]const u8, buttons: [*c]raven.Ruint) c_int {
    var cursor: [*c]const u8 = value;
    var result: raven.Ruint = 0;
    if (base.rvn_stricmp(value, "None") == 0) {
        buttons.* = 0;
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(value, "All") == 0) {
        buttons.* = raven.R_HEADER_ALL_BUTTONS;
        return raven.R_TRUE;
    }
    // "Close,Minimize"
    while (cursor[0] != 0) {
        var end = cursor;
        while (end[0] != 0 and end[0] != ',' and end[0] != '|') end += 1;
        while (cursor < end and (cursor[0] == ' ' or cursor[0] == '\t')) cursor += 1;
        var length: usize = @intCast(end - cursor);
        while (length > 0 and (cursor[length - 1] == ' ' or cursor[length - 1] == '\t')) length -= 1;
        if (length == 5 and base.rvn_strnicmp(cursor, "Close", 5) == 0) {
            result |= raven.R_HEADER_CLOSE;
        } else if (length == 8 and base.rvn_strnicmp(cursor, "Minimize", 8) == 0) {
            result |= raven.R_HEADER_MINIMIZE;
        } else if (length == 8 and base.rvn_strnicmp(cursor, "Maximize", 8) == 0) {
            result |= raven.R_HEADER_MAXIMIZE;
        } else {
            return raven.R_FALSE;
        }
        cursor = if (end[0] != 0) end + 1 else end;
    }
    buttons.* = result;
    return raven.R_TRUE;
}

fn rvn_header_bar_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Title") == 0 or base.rvn_stricmp(name, "Text") == 0) {
        _ = base.rvn_str_set(&bar.*.title, value);
    } else if (base.rvn_stricmp(name, "Buttons") == 0) {
        if (rvn_header_bar_parse_buttons(value, &bar.*.buttons) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "ButtonSide") == 0) {
        if (base.rvn_stricmp(value, "Left") == 0) {
            bar.*.side = raven.R_HALIGN_LEFT;
        } else if (base.rvn_stricmp(value, "Right") == 0) {
            bar.*.side = raven.R_HALIGN_RIGHT;
        } else {
            return raven.R_FALSE;
        }
    } else if (base.rvn_stricmp(name, "TitleAlign") == 0) {
        if (base.rvn_stricmp(value, "Left") == 0) {
            bar.*.title_align = raven.R_HALIGN_LEFT;
        } else if (base.rvn_stricmp(value, "Center") == 0) {
            bar.*.title_align = raven.R_HALIGN_CENTER;
        } else {
            return raven.R_FALSE;
        }
    } else if (base.rvn_stricmp(name, "Background") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        bar.*.no_background = @intFromBool(flag == 0);
    } else if (base.rvn_stricmp(name, "TitleStyle") == 0) {
        if (base.rvn_stricmp(value, "Notch") == 0) {
            bar.*.notch = raven.R_TRUE;
        } else if (base.rvn_stricmp(value, "Plain") == 0) {
            bar.*.notch = raven.R_FALSE;
        } else {
            return raven.R_FALSE;
        }
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_header_bar: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_HEADER_BAR,
    .name = "HeaderBar",
    .size = @sizeOf(rvn_header_bar_t),
    .flags = widget_h.RVN_CF_SURFACE,
    .init = rvn_header_bar_init,
    .destroy = rvn_header_bar_destroy,
    .measure = rvn_header_bar_measure,
    .arrange = rvn_header_bar_arrange,
    .paint = rvn_header_bar_paint,
    .event = rvn_header_bar_event,
    .set_attribute = rvn_header_bar_set_attribute,
    .window_drag_at = rvn_header_bar_drag_at,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rheader_bar_create(title: [*c]const u8) raven.Rid {
    if (ctx_h.rvn_api_check("Rheader_bar_create") == 0) return raven.R_INVALID_ID;
    const widget = widget_h.rvn_widget_create(raven.R_WIDGET_HEADER_BAR);
    if (widget == null) return raven.R_INVALID_ID;
    if (title != null) {
        const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
        bar.*.title = base.rvn_strdup(title);
    }
    return widget.*.id;
}

export fn Rheader_bar_set_title(id: raven.Rid, title: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_title");
    if (widget == null) return;
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    if (base.rvn_str_set(&bar.*.title, title) != 0) widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rheader_bar_set_buttons(id: raven.Rid, buttons: raven.Ruint) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_buttons");
    if (widget == null) return;
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.buttons = buttons & raven.R_HEADER_ALL_BUTTONS;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rheader_bar_set_button_side(id: raven.Rid, side: raven.RHAlign) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_button_side");
    if (widget == null) return;
    if (side != raven.R_HALIGN_LEFT and side != raven.R_HALIGN_RIGHT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rheader_bar_set_button_side: expected R_HALIGN_LEFT or R_HALIGN_RIGHT");
        return;
    }
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.side = side;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rheader_bar_set_title_align(id: raven.Rid, @"align": raven.RHAlign) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_title_align");
    if (widget == null) return;
    if (@"align" != raven.R_HALIGN_LEFT and @"align" != raven.R_HALIGN_CENTER) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rheader_bar_set_title_align: expected R_HALIGN_LEFT or R_HALIGN_CENTER");
        return;
    }
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.title_align = @"align";
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rheader_bar_set_background(id: raven.Rid, enabled: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_background");
    if (widget == null) return;
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.no_background = @intFromBool(enabled == 0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rheader_bar_set_title_notch(id: raven.Rid, notch: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_HEADER_BAR, "Rheader_bar_set_title_notch");
    if (widget == null) return;
    const bar: [*c]rvn_header_bar_t = @ptrCast(widget);
    bar.*.notch = @intFromBool(notch != 0);
    widget_h.rvn_widget_invalidate_paint(widget);
}
