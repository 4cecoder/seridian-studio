// Translated to Zig from vendor/raven/src/widgets/button.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/button.c
// Button (Slate SButton): a clickable frame around one child, usually a label.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_button_t = extern struct {
    base: widget_h.rvn_widget_t,
    style: raven.RButtonStyle,
    /// While pressed: R_TRUE when the cursor is still over the button.
    armed: c_int,
    callback: raven.RButtonClickedCallback,
    user_data: ?*anyopaque,
};

fn rvn_button_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const button: [*c]rvn_button_t = @ptrCast(widget);
    button.*.style = raven.R_BUTTON_DEFAULT;
}

fn rvn_button_padding(widget: [*c]const widget_h.rvn_widget_t) base.rvn_margin_t {
    const px = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X);
    const py = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_Y);
    return base.rvn_margin(px, py, px, py);
}

fn rvn_button_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const padding = rvn_button_padding(widget);
    var desired = base.rvn_vec2(0.0, 0.0);
    if (widget.*.child_count > 0) desired = ext.rvn_widget_measure_slot(widget.*.children[0]);
    desired.x += padding.l + padding.r;
    desired.y = base.rvn_maxf(desired.y + padding.t + padding.b, ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT));
    return desired;
}

fn rvn_button_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    if (widget.*.child_count > 0 and widget_h.rvn_widget_collapsed(widget.*.children[0]) == 0) {
        ext.rvn_widget_arrange_slot(widget.*.children[0], base.rvn_rect_inset(base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), rvn_button_padding(widget)));
    }
}

fn rvn_button_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const button: [*c]rvn_button_t = @ptrCast(widget);
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    var rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    var radius = ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    const pressed: c_int = @as(c_int, @intFromBool((widget.*.flags & widget_h.RVN_WF_PRESSED) != 0 and button.*.armed != 0));
    const hovered: c_int = @as(c_int, @intFromBool((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0));
    var fill: base.rvn_color_t = undefined;
    var outline: base.rvn_color_t = 0;
    var hover: f32 = undefined;
    var press: f32 = undefined;

    // a button is soft: it flattens under the finger and springs back past its shape
    hover = common.rvn_widget_hover(widget, painter, hovered);
    press = common.rvn_widget_press(widget, painter, pressed);
    common.rvn_widget_squash(widget, press, if (widget_h.rvn_widget_glass(widget) != 0) 0.13 else 0.09);

    if (widget_h.rvn_widget_glass(widget) != 0) {
        // a capsule of glass that lights up under the pointer
        const opacity = dp.opacity;
        const lift = base.rvn_clampf(hover, 0.0, 1.0) * 0.6;
        rect = base.rvn_rect(-lift, -lift, rect.w + lift * 2.0, rect.h + lift * 2.0);
        radius = common.rvn_control_radius(widget, rect.h);
        if (button.*.style == raven.R_BUTTON_PRIMARY) {
            common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_ACCENT, hover, press);
            if (dp.enabled != 0) dp.text_color = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT);
        } else if (button.*.style == raven.R_BUTTON_FLAT) {
            // flat buttons only show their glass while they are used
            const shown = base.rvn_clampf(base.rvn_maxf(hover, press), 0.0, 1.0);
            if (shown > 0.01) {
                dp.opacity *= shown;
                common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_CONTROL, hover, press);
                dp.opacity = opacity;
            }
        } else {
            common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_CONTROL, hover, press);
        }
        return;
    }

    // flat themes: the colors of the three states blend with the same springs
    hover = base.rvn_clampf(hover, 0.0, 1.0);
    press = base.rvn_clampf(press, 0.0, 1.0);
    if (button.*.style == raven.R_BUTTON_PRIMARY) {
        fill = base.rvn_color_mix(base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT), ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_HOVERED), hover),
            ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_PRESSED), press);
        if (dp.enabled == 0) fill = base.rvn_color_fade(fill, 0.4);
        // the content of a primary button is drawn in the accent text color
        if (dp.enabled != 0) dp.text_color = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT);
    } else if (button.*.style == raven.R_BUTTON_FLAT) {
        fill = base.rvn_color_mix(base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_HOVERED), hover),
            ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED), press);
    } else {
        fill = base.rvn_color_mix(base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL), ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_HOVERED), hover),
            ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED), press);
        outline = ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_BORDER);
        if (dp.enabled == 0) {
            fill = base.rvn_color_fade(fill, 0.5);
            outline = base.rvn_color_fade(outline, 0.5);
        }
    }
    ext.rvn_paint_box(painter, rect, radius, fill, if (outline != 0) ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH) else 0.0, outline);
}

fn rvn_button_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, common.rvn_control_radius(widget, widget.*.rect.h));
}

fn rvn_button_click(widget: [*c]widget_h.rvn_widget_t) void {
    const button: [*c]rvn_button_t = @ptrCast(widget);
    // the release throws the button past its shape: it wobbles once before settling
    ext.rvn_spring_kick(&widget.*.press, -11.0);
    if (button.*.callback) |callback| callback(widget.*.id, button.*.user_data);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
}

fn rvn_button_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const button: [*c]rvn_button_t = @ptrCast(widget);
    const inside: c_int = @as(c_int, @intFromBool(event.*.local_x >= 0.0 and event.*.local_y >= 0.0 and
        event.*.local_x < widget.*.rect.w and event.*.local_y < widget.*.rect.h));

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            widget.*.flags |= widget_h.RVN_WF_PRESSED;
            button.*.armed = raven.R_TRUE;
            ext.rvn_widget_capture_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if ((widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            if (button.*.armed != inside) {
                button.*.armed = inside;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT or (widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            widget.*.flags &= ~widget_h.RVN_WF_PRESSED;
            ext.rvn_widget_release_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            // a click is a press and a release on the button
            if (inside != 0) rvn_button_click(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0 or event.*.repeat != 0) return raven.R_FALSE;
            if (event.*.key == raven.R_KEY_ENTER or event.*.key == raven.R_KEY_KP_ENTER or event.*.key == raven.R_KEY_SPACE) {
                rvn_button_click(widget);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_button_set_text(widget: [*c]widget_h.rvn_widget_t, text: [*c]const u8) void {
    // reuse the label when the content already is one
    if (widget.*.child_count > 0 and widget.*.children[0].*.cls.*.@"type" == raven.R_WIDGET_LABEL) {
        _ = ext.rvn_widget_set_attribute(widget.*.children[0], "Text", if (text != null) text else "");
        return;
    }
    const label = ext.rvn_widget_create(raven.R_WIDGET_LABEL);
    if (label == null) return;
    _ = ext.rvn_widget_set_attribute(label, "Text", if (text != null) text else "");
    label.*.slot.halign = raven.R_HALIGN_CENTER;
    label.*.slot.valign = raven.R_VALIGN_CENTER;
    ext.rvn_widget_add_child(widget, label, -1);
}

fn rvn_button_parse_style(value: [*c]const u8, style: [*c]raven.RButtonStyle) c_int {
    if (base.rvn_stricmp(value, "Default") == 0) {
        style.* = raven.R_BUTTON_DEFAULT;
    } else if (base.rvn_stricmp(value, "Primary") == 0) {
        style.* = raven.R_BUTTON_PRIMARY;
    } else if (base.rvn_stricmp(value, "Flat") == 0) {
        style.* = raven.R_BUTTON_FLAT;
    } else return raven.R_FALSE;
    return raven.R_TRUE;
}

fn rvn_button_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const button: [*c]rvn_button_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Text") == 0) {
        rvn_button_set_text(widget, value);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Style") == 0) {
        if (rvn_button_parse_style(value, &button.*.style) == raven.R_FALSE) return raven.R_FALSE;
        ext.rvn_widget_invalidate_paint(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_button: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_BUTTON,
    .name = "Button",
    .size = @sizeOf(rvn_button_t),
    .flags = widget_h.RVN_CF_SINGLE_CHILD | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_button_init,
    .measure = rvn_button_measure,
    .arrange = rvn_button_arrange,
    .paint = rvn_button_paint,
    .paint_overlay = rvn_button_paint_overlay,
    .event = rvn_button_event,
    .set_attribute = rvn_button_set_attribute,
});

export fn Rbutton_create(text: [*c]const u8) raven.Rid {
    if (ctx_h.rvn_api_check("Rbutton_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_BUTTON);
    if (widget == null) return raven.R_INVALID_ID;
    if (text != null) rvn_button_set_text(widget, text);
    return widget.*.id;
}

export fn Rbutton_set_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BUTTON, "Rbutton_set_text");
    if (widget == null) return;
    rvn_button_set_text(widget, text);
}

export fn Rbutton_set_style(id: raven.Rid, style: raven.RButtonStyle) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BUTTON, "Rbutton_set_style");
    if (widget == null) return;
    if (style < raven.R_BUTTON_DEFAULT or style > raven.R_BUTTON_FLAT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rbutton_set_style: invalid style");
        return;
    }
    const button: [*c]rvn_button_t = @ptrCast(widget);
    button.*.style = style;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rbutton_set_clicked_callback(id: raven.Rid, callback: raven.RButtonClickedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_BUTTON, "Rbutton_set_clicked_callback");
    if (widget == null) return;
    const button: [*c]rvn_button_t = @ptrCast(widget);
    button.*.callback = callback;
    button.*.user_data = user_data;
}
