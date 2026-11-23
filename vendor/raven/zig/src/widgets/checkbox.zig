// Translated to Zig from vendor/raven/src/widgets/checkbox.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/checkbox.c
// Checkbox (Slate SCheckBox): a two-state mark with a text, drawn as a check
// box, a radio button or an on / off switch.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

/// typedef struct rvn_checkbox_t { ... } rvn_checkbox_t;
const rvn_checkbox_t = extern struct {
    base: widget_h.rvn_widget_t,
    text: [*c]u8,
    checked: c_int,
    armed: c_int,
    style: raven.RCheckboxStyle,
    callback: raven.RCheckboxChangedCallback,
    user_data: ?*anyopaque,
    /// 0 = off .. 1 = on, with the overshoot of its spring.
    on: raven.RSpring,
};

fn rvn_checkbox_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    checkbox.*.style = raven.R_CHECKBOX_CHECK;
}

fn rvn_checkbox_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    base.rvn_free(checkbox.*.text);
}

/// Size of the mark: a square, or a wider pill for the switch style.
fn rvn_checkbox_mark(widget: [*c]const widget_h.rvn_widget_t) base.rvn_vec2_t {
    const size = ext.rvn_widget_metric(widget, raven.R_METRIC_CHECK_SIZE);
    const checkbox: [*c]const rvn_checkbox_t = @ptrCast(widget);
    if (checkbox.*.style == raven.R_CHECKBOX_SWITCH) {
        // the switch of the glass themes is a long capsule with an elongated knob
        if (widget_h.rvn_widget_glass(widget) != 0) return base.rvn_vec2(@floor((size + 6.0) * 2.1), size + 6.0);
        return base.rvn_vec2(@floor(size * 1.9), size);
    }
    return base.rvn_vec2(size, size);
}

fn rvn_checkbox_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    const mark = rvn_checkbox_mark(widget);
    var desired = mark;
    if (checkbox.*.text != null and checkbox.*.text[0] != 0) {
        desired.x += ext.rvn_widget_metric(widget, raven.R_METRIC_SPACING) +
            @ceil(common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, checkbox.*.text));
        desired.y = base.rvn_maxf(desired.y, @ceil(common.rvn_widget_line_height(widget, raven.R_INVALID_ID, 0.0)));
    }
    desired.y = base.rvn_maxf(desired.y, ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT));
    return desired;
}

fn rvn_checkbox_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const mark = rvn_checkbox_mark(widget);
    const box = base.rvn_rect(0.0, @floor((widget.*.rect.h - mark.y) * 0.5), mark.x, mark.y);
    const hovered: c_int = @as(c_int, @intFromBool((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0));
    const pressed: c_int = @as(c_int, @intFromBool((widget.*.flags & widget_h.RVN_WF_PRESSED) != 0 and checkbox.*.armed != 0));
    const glass = widget_h.rvn_widget_glass(widget);
    var accent = ext.rvn_widget_color(widget, if (hovered != 0) raven.R_COLOR_ACCENT_HOVERED else raven.R_COLOR_ACCENT);
    var off = ext.rvn_widget_color(widget, if (pressed != 0) raven.R_COLOR_CONTROL_PRESSED else if (hovered != 0) raven.R_COLOR_CONTROL_HOVERED else raven.R_COLOR_CONTROL);
    var outline = ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_BORDER);
    const on_mark = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT);
    const border = ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH);
    // the state is a spring: it runs a little past 0 or 1, and that is what makes the mark bounce
    const on = ext.rvn_paint_spring(painter, &checkbox.*.on, if (checkbox.*.checked != 0) 1.0 else 0.0, raven.R_MOTION_BOUNCY);
    const mix = base.rvn_clampf(on, 0.0, 1.0);
    const press = common.rvn_widget_press(widget, painter, pressed);
    const held = base.rvn_clampf(press, 0.0, 1.0);

    if (dp.enabled == 0) {
        accent = base.rvn_color_fade(accent, 0.4);
        off = base.rvn_color_fade(off, 0.5);
        outline = base.rvn_color_fade(outline, 0.5);
    }

    if (checkbox.*.style == raven.R_CHECKBOX_SWITCH) {
        // the knob slides, stretched by its speed and by the finger holding it, and bounces on arrival
        const inset: f32 = 2.0;
        const knob_h: f32 = mark.y - inset * 2.0;
        var knob_w: f32 = if (glass != 0) @floor(knob_h * 1.45) else knob_h;
        const stretch = base.rvn_minf(@abs(checkbox.*.on.velocity) * 0.035, 0.45) * knob_h + held * knob_h * 0.28;
        const travel = mark.x - knob_w - inset * 2.0;
        var knob_x: f32 = box.x + inset + travel * base.rvn_clampf(on, -0.06, 1.06);
        const track_off = if (glass != 0) ext.rvn_widget_color(widget, raven.R_COLOR_TRACK) else off;
        const track_on = if (glass != 0) ext.rvn_widget_color(widget, raven.R_COLOR_SWITCH) else accent;
        var track = base.rvn_color_mix(track_off, track_on, mix);
        // the stretch grows toward where the knob is going, and never leaves the track
        knob_w += stretch;
        knob_x -= stretch * mix;
        knob_x = base.rvn_clampf(knob_x, box.x + inset - 1.5, box.x + mark.x - inset - knob_w + 1.5);
        if (dp.enabled == 0) track = base.rvn_color_fade(track, 0.5);
        ext.rvn_paint_box(painter, box, mark.y * 0.5, track, if (glass != 0) 0.0 else border * (1.0 - mix), outline);
        if (glass != 0) {
            common.rvn_paint_knob(painter, widget, base.rvn_rect(knob_x, box.y + inset, knob_w, knob_h), held);
        } else {
            ext.rvn_paint_box(painter, base.rvn_rect(knob_x, box.y + inset, knob_w, knob_h), knob_h * 0.5,
                base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_HANDLE_HOVERED), on_mark, mix), 0.0, 0);
        }
    } else {
        // check boxes and radio buttons: the box dips under the finger, the mark pops into it
        const radius: f32 = if (glass != 0 or checkbox.*.style == raven.R_CHECKBOX_RADIO) mark.y * 0.5 else 3.0;
        const dip = held * 1.5;
        const body = base.rvn_rect(box.x + dip, box.y + dip, box.w - dip * 2.0, box.h - dip * 2.0);
        ext.rvn_paint_box(painter, body, radius, base.rvn_color_mix(off, accent, mix),
            (if (glass != 0) 1.5 else border) * (1.0 - mix), base.rvn_color_mix(outline, accent, mix));
        if (on > 0.05) {
            const opacity = dp.opacity;
            // `on` peaks above 1 before settling: the mark arrives too large and shrinks back
            const pop = 0.4 + 0.6 * on;
            dp.opacity *= base.rvn_clampf(on * 2.0, 0.0, 1.0);
            if (checkbox.*.style == raven.R_CHECKBOX_RADIO) {
                const dot = mark.y * @as(f32, if (glass != 0) 0.38 else 0.4) * pop;
                ext.rvn_paint_box(painter, base.rvn_rect(box.x + (mark.x - dot) * 0.5, box.y + (mark.y - dot) * 0.5, dot, dot),
                    dot * 0.5, on_mark, 0.0, 0);
            } else {
                ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CHECK, box.x + mark.x * 0.5, box.y + mark.y * 0.5,
                    mark.y * @as(f32, if (glass != 0) 0.5 else 0.55) * pop, on_mark);
            }
            dp.opacity = opacity;
        }
    }
    if (checkbox.*.text != null and checkbox.*.text[0] != 0) {
        const x = mark.x + ext.rvn_widget_metric(widget, raven.R_METRIC_SPACING);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0),
            base.rvn_rect(x, 0.0, base.rvn_maxf(0.0, widget.*.rect.w - x), widget.*.rect.h), 0.0, checkbox.*.text, -1,
            ext.rvn_widget_text_color(widget, painter));
    }
}

fn rvn_checkbox_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, if (widget_h.rvn_widget_glass(widget) != 0) 10.0 else 3.0);
}

fn rvn_checkbox_set(widget: [*c]widget_h.rvn_widget_t, checked_in: c_int, notify: c_int) void {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    const checked: c_int = @as(c_int, @intFromBool(checked_in != 0));
    if (checkbox.*.checked == checked) return;
    checkbox.*.checked = checked;
    ext.rvn_widget_invalidate_paint(widget);

    // radio boxes of one parent are exclusive
    if (checked != 0 and checkbox.*.style == raven.R_CHECKBOX_RADIO and widget.*.parent != null) {
        var i: u32 = 0;
        while (i < widget.*.parent.*.child_count) : (i += 1) {
            const sibling: [*c]widget_h.rvn_widget_t = widget.*.parent.*.children[i];
            if (sibling != widget and sibling.*.cls.*.@"type" == raven.R_WIDGET_CHECKBOX and
                @as([*c]rvn_checkbox_t, @ptrCast(sibling)).*.style == raven.R_CHECKBOX_RADIO)
            {
                rvn_checkbox_set(sibling, raven.R_FALSE, notify);
            }
        }
    }
    if (notify != 0 and common.rvn_widget_alive(widget) != 0) {
        if (checkbox.*.callback) |callback| callback(widget.*.id, checked, checkbox.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    }
}

fn rvn_checkbox_toggle(widget: [*c]widget_h.rvn_widget_t) void {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    // a radio box can only be unchecked by checking another one
    if (checkbox.*.style == raven.R_CHECKBOX_RADIO and checkbox.*.checked != 0) return;
    rvn_checkbox_set(widget, @as(c_int, @intFromBool(checkbox.*.checked == 0)), raven.R_TRUE);
}

fn rvn_checkbox_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    const inside: c_int = @as(c_int, @intFromBool(event.*.local_x >= 0.0 and event.*.local_y >= 0.0 and
        event.*.local_x < widget.*.rect.w and event.*.local_y < widget.*.rect.h));

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            widget.*.flags |= widget_h.RVN_WF_PRESSED;
            checkbox.*.armed = raven.R_TRUE;
            ext.rvn_widget_capture_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if ((widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            if (checkbox.*.armed != inside) {
                checkbox.*.armed = inside;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT or (widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            widget.*.flags &= ~widget_h.RVN_WF_PRESSED;
            ext.rvn_widget_release_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            if (inside != 0) rvn_checkbox_toggle(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0 or event.*.repeat != 0) return raven.R_FALSE;
            if (event.*.key == raven.R_KEY_SPACE or event.*.key == raven.R_KEY_ENTER) {
                rvn_checkbox_toggle(widget);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_checkbox_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Text") == 0) {
        _ = base.rvn_str_set(&checkbox.*.text, value);
    } else if (base.rvn_stricmp(name, "Checked") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_checkbox_set(widget, flag, raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "Style") == 0) {
        if (base.rvn_stricmp(value, "Check") == 0) {
            checkbox.*.style = raven.R_CHECKBOX_CHECK;
        } else if (base.rvn_stricmp(value, "Radio") == 0) {
            checkbox.*.style = raven.R_CHECKBOX_RADIO;
        } else if (base.rvn_stricmp(value, "Switch") == 0) {
            checkbox.*.style = raven.R_CHECKBOX_SWITCH;
        } else return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_checkbox: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_CHECKBOX,
    .name = "Checkbox",
    .size = @sizeOf(rvn_checkbox_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_checkbox_init,
    .destroy = rvn_checkbox_destroy,
    .measure = rvn_checkbox_measure,
    .paint = rvn_checkbox_paint,
    .paint_overlay = rvn_checkbox_paint_overlay,
    .event = rvn_checkbox_event,
    .set_attribute = rvn_checkbox_set_attribute,
});

export fn Rcheckbox_create(text: [*c]const u8) raven.Rid {
    if (ctx_h.rvn_api_check("Rcheckbox_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_CHECKBOX);
    if (widget == null) return raven.R_INVALID_ID;
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    checkbox.*.text = base.rvn_strdup(text);
    return widget.*.id;
}

export fn Rcheckbox_set_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_set_text");
    if (widget == null) return;
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    if (base.rvn_str_set(&checkbox.*.text, text) != 0) ext.rvn_widget_invalidate_layout(widget);
}

export fn Rcheckbox_get_text(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_get_text");
    if (widget == null) return "";
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    return if (checkbox.*.text != null) checkbox.*.text else "";
}

export fn Rcheckbox_set_checked(id: raven.Rid, checked: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_set_checked");
    if (widget == null) return;
    rvn_checkbox_set(widget, checked, raven.R_FALSE);
}

export fn Rcheckbox_is_checked(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_is_checked");
    if (widget == null) return raven.R_FALSE;
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    return checkbox.*.checked;
}

export fn Rcheckbox_set_style(id: raven.Rid, style: raven.RCheckboxStyle) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_set_style");
    if (widget == null) return;
    if (style < raven.R_CHECKBOX_CHECK or style > raven.R_CHECKBOX_SWITCH) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rcheckbox_set_style: invalid style");
        return;
    }
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    checkbox.*.style = style;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rcheckbox_set_changed_callback(id: raven.Rid, callback: raven.RCheckboxChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_CHECKBOX, "Rcheckbox_set_changed_callback");
    if (widget == null) return;
    const checkbox: [*c]rvn_checkbox_t = @ptrCast(widget);
    checkbox.*.callback = callback;
    checkbox.*.user_data = user_data;
}
