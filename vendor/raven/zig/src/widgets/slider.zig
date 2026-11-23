// Translated to Zig from vendor/raven/src/widgets/slider.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/slider.c
// Slider (Slate SSlider): a value picked by dragging a handle along a track.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_slider_t = extern struct {
    base: widget_h.rvn_widget_t,
    minimum: f32,
    maximum: f32,
    value: f32,
    step: f32,
    orientation: raven.ROrientation,
    callback: raven.RSliderChangedCallback,
    user_data: ?*anyopaque,
    /// Where the knob is drawn, 0 .. 1: it follows the hand exactly, and flies to a value set otherwise.
    shown: raven.RSpring,
    /// The pointer moved since the press: the knob is under the hand.
    dragging: c_int,
};

fn rvn_slider_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    slider.*.maximum = 1.0;
    slider.*.orientation = raven.R_HORIZONTAL;
}

fn rvn_slider_fraction(slider: [*c]const rvn_slider_t) f32 {
    const range = slider.*.maximum - slider.*.minimum;
    return if (range != 0.0) base.rvn_clampf((slider.*.value - slider.*.minimum) / range, 0.0, 1.0) else 0.0;
}

fn rvn_slider_snap(slider: [*c]const rvn_slider_t, value: f32) f32 {
    const low = base.rvn_minf(slider.*.minimum, slider.*.maximum);
    const high = base.rvn_maxf(slider.*.minimum, slider.*.maximum);
    var value_ = value;
    if (slider.*.step > 0.0) value_ = slider.*.minimum + @floor((value - slider.*.minimum) / slider.*.step + 0.5) * slider.*.step;
    return base.rvn_clampf(value_, low, high);
}

fn rvn_slider_set(widget: [*c]widget_h.rvn_widget_t, value: f32, notify: c_int) void {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    const value_ = rvn_slider_snap(slider, value);
    if (value_ == slider.*.value) return;
    slider.*.value = value_;
    widget_h.rvn_widget_invalidate_paint(widget);
    if (notify != 0) {
        if (slider.*.callback) |callback| callback(widget.*.id, value_, slider.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    }
}

/// Length of the knob along the track: a disc, or an elongated capsule with a glass theme.
fn rvn_slider_handle(widget: [*c]const widget_h.rvn_widget_t) f32 {
    const size = ext.rvn_widget_metric(widget, raven.R_METRIC_SLIDER_HANDLE_SIZE);
    return if (widget_h.rvn_widget_glass(widget) != 0) @floor(size * 1.5) else size;
}

fn rvn_slider_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    const thickness = base.rvn_maxf(ext.rvn_widget_metric(widget, raven.R_METRIC_SLIDER_HANDLE_SIZE) + 4.0, ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT));
    return if (slider.*.orientation == raven.R_HORIZONTAL) base.rvn_vec2(120.0, thickness) else base.rvn_vec2(thickness, 120.0);
}

fn rvn_slider_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    var handle = rvn_slider_handle(widget);
    const thickness = ext.rvn_widget_metric(widget, raven.R_METRIC_SLIDER_HANDLE_SIZE);
    const track: f32 = if (widget_h.rvn_widget_glass(widget) != 0) 6.0 else 4.0;
    var fraction = rvn_slider_fraction(slider);
    const held: c_int = @intFromBool((widget.*.flags & widget_h.RVN_WF_PRESSED) != 0);
    const hot: c_int = @intFromBool(((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 or held != 0) and dp.enabled != 0);
    const press = common.rvn_widget_press(widget, painter, held);
    const hover = common.rvn_widget_hover(widget, painter, hot);
    // the knob swells when it is picked up and bounces when it is let go
    const swell = 2.5 * press + 1.0 * base.rvn_clampf(hover, 0.0, 1.0);
    var fill = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    var knob = ext.rvn_widget_color(widget, if (hot != 0) raven.R_COLOR_ACCENT_HOVERED else raven.R_COLOR_ACCENT);
    const back = ext.rvn_widget_color(widget, raven.R_COLOR_TRACK);

    if (dp.enabled == 0) {
        fill = base.rvn_color_fade(fill, 0.4);
        knob = ext.rvn_widget_color(widget, raven.R_COLOR_HANDLE);
    }
    if (slider.*.dragging != 0) ext.rvn_spring_set(&slider.*.shown, fraction);
    fraction = base.rvn_clampf(ext.rvn_paint_spring(painter, &slider.*.shown, fraction, raven.R_MOTION_BOUNCY), 0.0, 1.0);
    if (slider.*.orientation == raven.R_HORIZONTAL) {
        const travel = base.rvn_maxf(0.0, widget.*.rect.w - handle);
        const center = handle * 0.5 + travel * fraction;
        const y = @floor((widget.*.rect.h - track) * 0.5);
        ext.rvn_paint_box(painter, base.rvn_rect(handle * 0.5, y, travel, track), track * 0.5, back, 0.0, 0);
        ext.rvn_paint_box(painter, base.rvn_rect(handle * 0.5, y, travel * fraction, track), track * 0.5, fill, 0.0, 0);
        if (widget_h.rvn_widget_glass(widget) != 0) {
            common.rvn_paint_knob(painter, widget, base.rvn_rect(center - handle * 0.5, (widget.*.rect.h - thickness) * 0.5, handle, thickness), press);
            return;
        }
        handle += swell;
        ext.rvn_paint_box(painter, base.rvn_rect(center - handle * 0.5, (widget.*.rect.h - handle) * 0.5, handle, handle), handle * 0.5, knob, 2.0, ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT));
    } else {
        // a vertical slider grows upwards
        const travel = base.rvn_maxf(0.0, widget.*.rect.h - handle);
        const center = handle * 0.5 + travel * (1.0 - fraction);
        const x = @floor((widget.*.rect.w - track) * 0.5);
        ext.rvn_paint_box(painter, base.rvn_rect(x, handle * 0.5, track, travel), track * 0.5, back, 0.0, 0);
        ext.rvn_paint_box(painter, base.rvn_rect(x, center, track, handle * 0.5 + travel - center), track * 0.5, fill, 0.0, 0);
        if (widget_h.rvn_widget_glass(widget) != 0) {
            common.rvn_paint_knob(painter, widget, base.rvn_rect((widget.*.rect.w - thickness) * 0.5, center - handle * 0.5, thickness, handle), press);
            return;
        }
        handle += swell;
        ext.rvn_paint_box(painter, base.rvn_rect((widget.*.rect.w - handle) * 0.5, center - handle * 0.5, handle, handle), handle * 0.5, knob, 2.0, ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT));
    }
}

fn rvn_slider_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, if (widget_h.rvn_widget_glass(widget) != 0) 10.0 else 4.0);
}

fn rvn_slider_value_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) f32 {
    const slider: [*c]const rvn_slider_t = @ptrCast(widget);
    const handle = rvn_slider_handle(widget);
    var fraction: f32 = undefined;
    if (slider.*.orientation == raven.R_HORIZONTAL) {
        const travel = widget.*.rect.w - handle;
        fraction = if (travel > 0.0) (x - handle * 0.5) / travel else 0.0;
    } else {
        const travel = widget.*.rect.h - handle;
        fraction = if (travel > 0.0) 1.0 - (y - handle * 0.5) / travel else 0.0;
    }
    return slider.*.minimum + (slider.*.maximum - slider.*.minimum) * base.rvn_clampf(fraction, 0.0, 1.0);
}

fn rvn_slider_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    const step: f32 = if (slider.*.step > 0.0) slider.*.step else (slider.*.maximum - slider.*.minimum) / 100.0;

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            widget.*.flags |= widget_h.RVN_WF_PRESSED;
            widget_h.rvn_widget_capture_mouse(widget);
            rvn_slider_set(widget, rvn_slider_value_at(widget, event.*.local_x, event.*.local_y), raven.R_TRUE);
            if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if ((widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            slider.*.dragging = raven.R_TRUE;
            rvn_slider_set(widget, rvn_slider_value_at(widget, event.*.local_x, event.*.local_y), raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT or (widget.*.flags & widget_h.RVN_WF_PRESSED) == 0) return raven.R_FALSE;
            widget.*.flags &= ~widget_h.RVN_WF_PRESSED;
            slider.*.dragging = raven.R_FALSE;
            widget_h.rvn_widget_release_mouse(widget);
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0) return raven.R_FALSE;
            switch (event.*.key) {
                raven.R_KEY_LEFT, raven.R_KEY_DOWN => {
                    rvn_slider_set(widget, slider.*.value - step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_RIGHT, raven.R_KEY_UP => {
                    rvn_slider_set(widget, slider.*.value + step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_HOME => {
                    rvn_slider_set(widget, slider.*.minimum, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_END => {
                    rvn_slider_set(widget, slider.*.maximum, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_slider_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    var number: f32 = undefined;
    if (base.rvn_stricmp(name, "Orientation") == 0) {
        if (ext.rvn_parse_orientation(value, &slider.*.orientation) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
    if (base.rvn_stricmp(name, "Min") == 0) {
        slider.*.minimum = number;
    } else if (base.rvn_stricmp(name, "Max") == 0) {
        slider.*.maximum = number;
    } else if (base.rvn_stricmp(name, "Step") == 0) {
        slider.*.step = if (number > 0.0) number else 0.0;
    } else if (base.rvn_stricmp(name, "Value") == 0) {
        rvn_slider_set(widget, number, raven.R_FALSE);
        return raven.R_TRUE;
    } else {
        return raven.R_FALSE;
    }
    slider.*.value = rvn_slider_snap(slider, slider.*.value);
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_slider: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_SLIDER,
    .name = "Slider",
    .size = @sizeOf(rvn_slider_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_slider_init,
    .measure = rvn_slider_measure,
    .paint = rvn_slider_paint,
    .paint_overlay = rvn_slider_paint_overlay,
    .event = rvn_slider_event,
    .set_attribute = rvn_slider_set_attribute,
});

export fn Rslider_set_range(id: raven.Rid, minimum: f32, maximum: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_set_range");
    if (widget == null) return;
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    slider.*.minimum = minimum;
    slider.*.maximum = maximum;
    slider.*.value = rvn_slider_snap(slider, slider.*.value);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rslider_set_value(id: raven.Rid, value: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_set_value");
    if (widget == null) return;
    rvn_slider_set(widget, value, raven.R_FALSE);
}

export fn Rslider_get_value(id: raven.Rid) f32 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_get_value");
    if (widget == null) return 0.0;
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    return slider.*.value;
}

export fn Rslider_get_range(id: raven.Rid, minimum: [*c]f32, maximum: [*c]f32, step: [*c]f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_get_range");
    if (widget == null) return;
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    if (minimum != null) minimum.* = slider.*.minimum;
    if (maximum != null) maximum.* = slider.*.maximum;
    if (step != null) step.* = slider.*.step;
}

export fn Rslider_set_step(id: raven.Rid, step: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_set_step");
    if (widget == null) return;
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    slider.*.step = if (step > 0.0) step else 0.0;
}

export fn Rslider_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_set_orientation");
    if (widget == null) return;
    if (orientation != raven.R_HORIZONTAL and orientation != raven.R_VERTICAL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rslider_set_orientation: invalid orientation");
        return;
    }
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    slider.*.orientation = orientation;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rslider_set_changed_callback(id: raven.Rid, callback: raven.RSliderChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_SLIDER, "Rslider_set_changed_callback");
    if (widget == null) return;
    const slider: [*c]rvn_slider_t = @ptrCast(widget);
    slider.*.callback = callback;
    slider.*.user_data = user_data;
}
