// Translated to Zig from vendor/raven/src/widgets/spin_box.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/spin_box.c
// SpinBox (Slate SSpinBox): numeric field. Drag it sideways to scrub the
// value, click it to type, use the arrow keys or the wheel to step.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const RVN_SPIN_DRAG_THRESHOLD: f32 = 3.0;
const RVN_SPIN_PIXELS_PER_STEP: f32 = 4.0;

const rvn_spin_box_t = extern struct {
    base: widget_h.rvn_widget_t,
    edit: common.rvn_textedit_t,
    value: f64,
    minimum: f64,
    maximum: f64,
    step: f64,
    decimals: c_int,
    editing: c_int,
    dragging: c_int,
    press_x: f32,
    press_value: f64,
    callback: raven.RSpinBoxChangedCallback,
    user_data: ?*anyopaque,
};

fn rvn_spin_box_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    common.rvn_textedit_init(&spin.*.edit);
    spin.*.minimum = -1e30;
    spin.*.maximum = 1e30;
    spin.*.step = 1.0;
    spin.*.decimals = 2;
    widget.*.cursor = @intCast(raven.R_CURSOR_RESIZE_H);
}

fn rvn_spin_box_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    common.rvn_textedit_free(&spin.*.edit);
}

fn rvn_spin_box_format(spin: [*c]const rvn_spin_box_t, buffer: [*c]u8, size: usize) void {
    _ = libc.snprintf(buffer, size, "%.*f", spin.*.decimals, spin.*.value);
}

fn rvn_spin_box_set(widget: [*c]widget_h.rvn_widget_t, value_in: f64, notify: c_int) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    var value = value_in;
    const low = if (spin.*.minimum < spin.*.maximum) spin.*.minimum else spin.*.maximum;
    const high = if (spin.*.minimum < spin.*.maximum) spin.*.maximum else spin.*.minimum;
    if (value != value) return; // NaN
    if (value < low) value = low;
    if (value > high) value = high;
    if (value == spin.*.value) return;
    spin.*.value = value;
    widget_h.rvn_widget_invalidate_paint(widget);
    if (notify != 0) {
        if (spin.*.callback) |callback| callback(widget.*.id, value, spin.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    }
}

fn rvn_spin_box_area(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const px: f32 = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 0.7;
    return base.rvn_rect(px, 0.0, base.rvn_maxf(0.0, widget.*.rect.w - px * 2.0), widget.*.rect.h);
}

fn rvn_spin_box_begin_edit(widget: [*c]widget_h.rvn_widget_t, select_all: c_int) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    var buffer: [64]u8 = undefined;
    if (spin.*.editing != 0) return;
    rvn_spin_box_format(spin, &buffer, buffer.len);
    _ = common.rvn_textedit_set_text(&spin.*.edit, &buffer);
    if (select_all != 0) {
        common.rvn_textedit_select_all(&spin.*.edit);
    } else {
        spin.*.edit.anchor = 0;
        spin.*.edit.caret = 0;
    }
    common.rvn_textedit_set_focused(&spin.*.edit, widget, raven.R_TRUE);
    spin.*.editing = raven.R_TRUE;
    widget.*.cursor = @intCast(raven.R_CURSOR_IBEAM);
}

fn rvn_spin_box_end_edit(widget: [*c]widget_h.rvn_widget_t, apply: c_int) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    if (spin.*.editing == 0) return;
    spin.*.editing = raven.R_FALSE;
    widget.*.cursor = @intCast(raven.R_CURSOR_RESIZE_H);
    common.rvn_textedit_set_focused(&spin.*.edit, widget, raven.R_FALSE);
    if (apply != 0) {
        var end: [*c]u8 = null;
        var value: f64 = undefined;
        // accept a decimal comma as well
        const text = base.rvn_strdup(spin.*.edit.text);
        const comma = libc.strchr(text, ',');
        if (comma != null) comma.* = '.';
        value = libc.strtod(text, &end);
        if (end != text) rvn_spin_box_set(widget, value, raven.R_TRUE);
        base.rvn_free(text);
    }
    if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_spin_box_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    return base.rvn_vec2(80.0, ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT));
}

fn rvn_spin_box_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const focused: c_int = @intFromBool((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0);
    var fill = ext.rvn_widget_color(widget, raven.R_COLOR_INPUT);
    const text = ext.rvn_widget_text_color(widget, painter);
    var buffer: [64]u8 = undefined;

    if (dp.enabled == 0) fill = base.rvn_color_fade(fill, 0.5);
    if (widget_h.rvn_widget_glass(widget) != 0) {
        const radius = common.rvn_control_radius(widget, rect.h);
        common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_INPUT, 0.0, 0.0);
        if (focused != 0) ext.rvn_paint_box(painter, rect, radius, 0, 1.5, ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS));
    } else {
        ext.rvn_paint_box(painter, rect, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), fill, ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), ext.rvn_widget_color(widget, if (focused != 0) raven.R_COLOR_FOCUS else raven.R_COLOR_BORDER));
    }
    if (spin.*.editing != 0) {
        common.rvn_textedit_paint(&spin.*.edit, widget, painter, rvn_spin_box_area(widget), raven.R_INVALID_ID, 0.0, text, raven.R_TRUE);
        return;
    }
    rvn_spin_box_format(spin, &buffer, buffer.len);
    ext.rvn_paint_push_clip(painter, rect);
    ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), rect, 0.5, &buffer, -1, text);
    ext.rvn_paint_pop_clip(painter);
}

fn rvn_spin_box_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    const area = rvn_spin_box_area(widget);
    var flags: c_int = undefined;

    switch (event.*.@"type") {
        raven.R_EVENT_FOCUS_GAINED => {
            // reaching the field with Tab starts typing right away
            if (widget.*.window != null and widget.*.window.*.focus_visible != 0) rvn_spin_box_begin_edit(widget, raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_LOST => {
            rvn_spin_box_end_edit(widget, raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            widget_h.rvn_widget_capture_mouse(widget);
            if (spin.*.editing != 0) {
                common.rvn_textedit_mouse_down(&spin.*.edit, widget, raven.R_INVALID_ID, 0.0, event.*.local_x - area.x, event.*.clicks, @intFromBool((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_SHIFT))) != 0));
            } else {
                widget.*.flags |= widget_h.RVN_WF_PRESSED;
                spin.*.dragging = raven.R_FALSE;
                spin.*.press_x = event.*.x;
                spin.*.press_value = spin.*.value;
            }
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (spin.*.editing != 0) {
                if (spin.*.edit.mouse_selecting == 0) return raven.R_FALSE;
                common.rvn_textedit_mouse_drag(&spin.*.edit, widget, raven.R_INVALID_ID, 0.0, event.*.local_x - area.x);
                widget_h.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            }
            if ((widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            if (spin.*.dragging == 0 and @abs(event.*.x - spin.*.press_x) > RVN_SPIN_DRAG_THRESHOLD) spin.*.dragging = raven.R_TRUE;
            if (spin.*.dragging != 0) {
                // Shift scrubs ten times finer
                const scale: f64 = if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_SHIFT))) != 0) 0.1 else 1.0;
                const steps = @floor(@as(f64, event.*.x - spin.*.press_x) / @as(f64, RVN_SPIN_PIXELS_PER_STEP));
                rvn_spin_box_set(widget, spin.*.press_value + steps * spin.*.step * scale, raven.R_TRUE);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            widget_h.rvn_widget_release_mouse(widget);
            if (spin.*.editing != 0) {
                spin.*.edit.mouse_selecting = raven.R_FALSE;
                return raven.R_TRUE;
            }
            if ((widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            widget.*.flags &= ~widget_h.RVN_WF_PRESSED;
            // a click without a drag switches to typing
            if (spin.*.dragging == 0) rvn_spin_box_begin_edit(widget, raven.R_TRUE);
            spin.*.dragging = raven.R_FALSE;
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            // only a focused field steps with the wheel: it must not hijack the scrolling of a panel
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0 or spin.*.editing != 0 or event.*.wheel_y == 0.0) return raven.R_FALSE;
            rvn_spin_box_set(widget, spin.*.value + (if (event.*.wheel_y > 0.0) spin.*.step else -spin.*.step), raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if (spin.*.editing != 0) {
                if (event.*.key == raven.R_KEY_ESCAPE) {
                    rvn_spin_box_end_edit(widget, raven.R_FALSE);
                    return raven.R_TRUE;
                }
                flags = common.rvn_textedit_key(&spin.*.edit, event);
                if ((flags & common.RVN_TEXTEDIT_COMMITTED) != 0) {
                    rvn_spin_box_end_edit(widget, raven.R_TRUE);
                } else if (flags != 0) {
                    widget_h.rvn_widget_invalidate_paint(widget);
                }
                return @intFromBool(flags != 0);
            }
            switch (event.*.key) {
                raven.R_KEY_UP, raven.R_KEY_RIGHT => {
                    rvn_spin_box_set(widget, spin.*.value + spin.*.step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_DOWN, raven.R_KEY_LEFT => {
                    rvn_spin_box_set(widget, spin.*.value - spin.*.step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
                    rvn_spin_box_begin_edit(widget, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
        },
        raven.R_EVENT_TEXT => {
            // typing a number starts an edit that replaces the value
            if (spin.*.editing == 0) {
                const c: u32 = event.*.codepoint;
                if (!((c >= '0' and c <= '9') or c == '-' or c == '.' or c == ',')) return raven.R_FALSE;
                rvn_spin_box_begin_edit(widget, raven.R_TRUE);
            }
            if (common.rvn_textedit_input(&spin.*.edit, event.*.codepoint) != 0) widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_spin_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    var number: f32 = undefined;
    if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
    if (base.rvn_stricmp(name, "Min") == 0) {
        spin.*.minimum = number;
    } else if (base.rvn_stricmp(name, "Max") == 0) {
        spin.*.maximum = number;
    } else if (base.rvn_stricmp(name, "Step") == 0) {
        spin.*.step = number;
    } else if (base.rvn_stricmp(name, "Decimals") == 0) {
        spin.*.decimals = base.rvn_clampi(@intFromFloat(number), 0, 9);
    } else if (base.rvn_stricmp(name, "Value") == 0) {
        rvn_spin_box_set(widget, number, raven.R_FALSE);
        return raven.R_TRUE;
    } else {
        return raven.R_FALSE;
    }
    rvn_spin_box_set(widget, spin.*.value, raven.R_FALSE);
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_spin_box: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SPIN_BOX,
    .name = "SpinBox",
    .size = @sizeOf(rvn_spin_box_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_spin_box_init,
    .destroy = rvn_spin_box_destroy,
    .measure = rvn_spin_box_measure,
    .paint = rvn_spin_box_paint,
    .event = rvn_spin_box_event,
    .set_attribute = rvn_spin_box_set_attribute,
});

export fn Rspin_box_set_range(id: raven.Rid, minimum: f64, maximum: f64) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_set_range");
    if (widget == null) return;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    spin.*.minimum = minimum;
    spin.*.maximum = maximum;
    rvn_spin_box_set(widget, spin.*.value, raven.R_FALSE);
}

export fn Rspin_box_set_value(id: raven.Rid, value: f64) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_set_value");
    if (widget == null) return;
    rvn_spin_box_set(widget, value, raven.R_FALSE);
}

export fn Rspin_box_get_value(id: raven.Rid) f64 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_get_value");
    if (widget == null) return 0.0;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    return spin.*.value;
}

export fn Rspin_box_get_range(id: raven.Rid, minimum: [*c]f64, maximum: [*c]f64, step: [*c]f64) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_get_range");
    if (widget == null) return;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    if (minimum != null) minimum.* = spin.*.minimum;
    if (maximum != null) maximum.* = spin.*.maximum;
    if (step != null) step.* = spin.*.step;
}

export fn Rspin_box_set_step(id: raven.Rid, step: f64) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_set_step");
    if (widget == null) return;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    spin.*.step = step;
}

export fn Rspin_box_set_decimals(id: raven.Rid, decimals: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_set_decimals");
    if (widget == null) return;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    spin.*.decimals = base.rvn_clampi(decimals, 0, 9);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rspin_box_set_changed_callback(id: raven.Rid, callback: raven.RSpinBoxChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SPIN_BOX, "Rspin_box_set_changed_callback");
    if (widget == null) return;
    const spin: [*c]rvn_spin_box_t = @ptrCast(widget);
    spin.*.callback = callback;
    spin.*.user_data = user_data;
}
