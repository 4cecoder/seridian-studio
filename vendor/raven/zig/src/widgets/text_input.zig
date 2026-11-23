// Translated to Zig from vendor/raven/src/widgets/text_input.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/text_input.c
// TextInput (Slate SEditableTextBox): single-line text field with caret,
// selection, clipboard and placeholder.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

/// typedef struct rvn_text_input_t { ... } rvn_text_input_t;
const rvn_text_input_t = extern struct {
    base: widget_h.rvn_widget_t,
    edit: common.rvn_textedit_t,
    placeholder: [*c]u8,
    changed: raven.RTextChangedCallback,
    changed_user: ?*anyopaque,
    committed: raven.RTextChangedCallback,
    committed_user: ?*anyopaque,
};

fn rvn_text_input_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    common.rvn_textedit_init(&input.*.edit);
    widget.*.cursor = raven.R_CURSOR_IBEAM;
}

fn rvn_text_input_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    common.rvn_textedit_free(&input.*.edit);
    base.rvn_free(input.*.placeholder);
}

fn rvn_text_input_area(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const px: f32 = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 0.7;
    return base.rvn_rect(px, 0.0, base.rvn_maxf(0.0, widget.*.rect.w - px * 2.0), widget.*.rect.h);
}

fn rvn_text_input_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    return base.rvn_vec2(140.0, ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT));
}

fn rvn_text_input_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const area = rvn_text_input_area(widget);
    const focused: c_int = @as(c_int, @intFromBool((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0));
    var fill = ext.rvn_widget_color(widget, raven.R_COLOR_INPUT);
    // the focus ring closes in on the field instead of just appearing
    const focus = ext.rvn_paint_spring(painter, &widget.*.press, if (focused != 0) 1.0 else 0.0, raven.R_MOTION_BOUNCY);
    const lit = base.rvn_clampf(focus, 0.0, 1.0);
    const outline = base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_BORDER), ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS), lit);

    if (dp.enabled == 0) fill = base.rvn_color_fade(fill, 0.5);
    if (widget_h.rvn_widget_glass(widget) != 0) {
        // a field of darker glass; the focus is a ring of the accent color
        const radius = common.rvn_control_radius(widget, rect.h);
        common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_INPUT, 0.0, 0.0);
        if (lit > 0.01) {
            const away = (1.0 - focus) * 5.0;
            ext.rvn_paint_box(painter, base.rvn_rect(rect.x - away, rect.y - away, rect.w + away * 2.0, rect.h + away * 2.0),
                radius + away, 0, 1.5, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS), lit));
        }
    } else {
        ext.rvn_paint_box(painter, rect, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), fill,
            ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), outline);
        if (lit > 0.01 and lit < 0.99) {
            const away = (1.0 - focus) * 4.0;
            ext.rvn_paint_box(painter, base.rvn_rect(rect.x - away, rect.y - away, rect.w + away * 2.0, rect.h + away * 2.0),
                ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) + away, 0, 1.0,
                base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS), lit * (1.0 - lit) * 2.0));
        }
    }
    if (input.*.edit.length == 0 and input.*.placeholder != null and focused == 0) {
        ext.rvn_paint_push_clip(painter, area);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), area, 0.0, input.*.placeholder, -1,
            ext.rvn_widget_color(widget, raven.R_COLOR_TEXT_PLACEHOLDER));
        ext.rvn_paint_pop_clip(painter);
        return;
    }
    common.rvn_textedit_paint(&input.*.edit, widget, painter, area, raven.R_INVALID_ID, 0.0,
        ext.rvn_widget_text_color(widget, painter), focused);
}

/// Calls back after an edit. The text is copied: the callback may change it.
fn rvn_text_input_notify(widget: [*c]widget_h.rvn_widget_t, flags: c_int) void {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    if ((flags & (common.RVN_TEXTEDIT_CHANGED | common.RVN_TEXTEDIT_COMMITTED)) == 0) return;
    const text = base.rvn_strdup(input.*.edit.text);
    if ((flags & common.RVN_TEXTEDIT_CHANGED) != 0) {
        if (input.*.changed) |changed| changed(widget.*.id, text, input.*.changed_user);
    }
    if ((flags & common.RVN_TEXTEDIT_COMMITTED) != 0 and common.rvn_widget_alive(widget) != 0) {
        if (input.*.committed) |committed| committed(widget.*.id, text, input.*.committed_user);
        if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    }
    base.rvn_free(text);
}

fn rvn_text_input_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    const area = rvn_text_input_area(widget);
    var flags: c_int = undefined;

    switch (event.*.@"type") {
        raven.R_EVENT_FOCUS_GAINED => {
            common.rvn_textedit_set_focused(&input.*.edit, widget, raven.R_TRUE);
            // reaching the field with Tab selects its content, like most toolkits
            if (widget.*.window != null and widget.*.window.*.focus_visible != 0) common.rvn_textedit_select_all(&input.*.edit);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_LOST => {
            common.rvn_textedit_set_focused(&input.*.edit, widget, raven.R_FALSE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            common.rvn_textedit_mouse_down(&input.*.edit, widget, raven.R_INVALID_ID, 0.0, event.*.local_x - area.x,
                event.*.clicks, @as(c_int, @intFromBool((event.*.modifiers & raven.R_MOD_SHIFT) != 0)));
            ext.rvn_widget_capture_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (input.*.edit.mouse_selecting == 0) return raven.R_FALSE;
            common.rvn_textedit_mouse_drag(&input.*.edit, widget, raven.R_INVALID_ID, 0.0, event.*.local_x - area.x);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            input.*.edit.mouse_selecting = raven.R_FALSE;
            ext.rvn_widget_release_mouse(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            flags = common.rvn_textedit_key(&input.*.edit, event);
            if (flags == 0) return raven.R_FALSE;
            ext.rvn_widget_invalidate_paint(widget);
            rvn_text_input_notify(widget, flags);
            return raven.R_TRUE;
        },
        raven.R_EVENT_TEXT => {
            flags = common.rvn_textedit_input(&input.*.edit, event.*.codepoint);
            if (flags == 0) return raven.R_FALSE;
            ext.rvn_widget_invalidate_paint(widget);
            rvn_text_input_notify(widget, flags);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_text_input_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Text") == 0) {
        _ = common.rvn_textedit_set_text(&input.*.edit, value);
    } else if (base.rvn_stricmp(name, "Placeholder") == 0) {
        _ = base.rvn_str_set(&input.*.placeholder, value);
    } else if (base.rvn_stricmp(name, "Password") == 0) {
        if (ext.rvn_parse_bool(value, &input.*.edit.password) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "ReadOnly") == 0) {
        if (ext.rvn_parse_bool(value, &input.*.edit.read_only) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "MaxLength") == 0) {
        if (ext.rvn_parse_int(value, &input.*.edit.max_chars) == 0) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

export const rvn_class_text_input: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_TEXT_INPUT,
    .name = "TextInput",
    .size = @sizeOf(rvn_text_input_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_text_input_init,
    .destroy = rvn_text_input_destroy,
    .measure = rvn_text_input_measure,
    .paint = rvn_text_input_paint,
    .event = rvn_text_input_event,
    .set_attribute = rvn_text_input_set_attribute,
});

export fn Rtext_input_set_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_text");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    if (common.rvn_textedit_set_text(&input.*.edit, text) != 0) ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_input_get_text(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_get_text");
    if (widget == null) return "";
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    return input.*.edit.text;
}

export fn Rtext_input_set_placeholder(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_placeholder");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    if (base.rvn_str_set(&input.*.placeholder, text) != 0) ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_input_set_password(id: raven.Rid, password: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_password");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    input.*.edit.password = @as(c_int, @intFromBool(password != 0));
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_input_is_password(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_is_password");
    if (widget == null) return raven.R_FALSE;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    return @as(c_int, @intFromBool(input.*.edit.password != 0));
}

export fn Rtext_input_is_read_only(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_is_read_only");
    if (widget == null) return raven.R_FALSE;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    return @as(c_int, @intFromBool(input.*.edit.read_only != 0));
}

export fn Rtext_input_set_read_only(id: raven.Rid, read_only: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_read_only");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    input.*.edit.read_only = @as(c_int, @intFromBool(read_only != 0));
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_input_set_max_length(id: raven.Rid, max_length: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_max_length");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    input.*.edit.max_chars = if (max_length > 0) max_length else 0;
}

export fn Rtext_input_select_all(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_select_all");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    common.rvn_textedit_select_all(&input.*.edit);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_input_set_changed_callback(id: raven.Rid, callback: raven.RTextChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_changed_callback");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    input.*.changed = callback;
    input.*.changed_user = user_data;
}

export fn Rtext_input_set_committed_callback(id: raven.Rid, callback: raven.RTextChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TEXT_INPUT, "Rtext_input_set_committed_callback");
    if (widget == null) return;
    const input: [*c]rvn_text_input_t = @ptrCast(widget);
    input.*.committed = callback;
    input.*.committed_user = user_data;
}
