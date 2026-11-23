// Translated to Zig from vendor/raven/src/widgets/combo_box.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/combo_box.c
// ComboBox (Slate SComboBox): a button showing the selected item, and a
// popup list to pick another one.
//
// The list is a private widget class shown through the popup layer of the
// window; it is owned by the combo box and is not one of its children.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const RVN_COMBO_MAX_ROWS = 10;

const rvn_combo_box_t = extern struct {
    base: widget_h.rvn_widget_t,
    items: [*c][*c]u8,
    count: u32,
    cap: u32,
    selected: c_int,
    list: [*c]widget_h.rvn_widget_t,
    callback: raven.RComboBoxChangedCallback,
    user_data: ?*anyopaque,
};

const rvn_combo_list_t = extern struct {
    base: widget_h.rvn_widget_t,
    combo: [*c]rvn_combo_box_t,
    hot: c_int,
    bar: common.rvn_scrollbar_t,
    /// Top of the highlighted row as drawn.
    hot_y: raven.RSpring,
};

/// `RVN_ATTR(literal)` of widgets/common.h: case-insensitive comparison of the attribute name.
inline fn RVN_ATTR(name: [*c]const u8, literal: [*c]const u8) bool {
    return base.rvn_stricmp(name, literal) == 0;
}

fn rvn_combo_box_select(widget: [*c]widget_h.rvn_widget_t, index: c_int, notify: c_int) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    // `index` is a parameter in C, reassigned below: a local copy here.
    var index_ = index;
    if (index_ < -1 or index_ >= @as(c_int, @intCast(combo.*.count))) index_ = -1;
    if (combo.*.selected == index_) return;
    combo.*.selected = index_;
    widget_h.rvn_widget_invalidate_paint(widget);
    if (notify != 0) {
        if (combo.*.callback) |callback| callback(widget.*.id, index_, combo.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    }
}

// ===========================================================================
//  Popup list
// ===========================================================================

fn rvn_combo_row_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return widget_h.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT);
}

/// Space between the edge of the list and its rows: more with the rounded popups of the glass themes.
fn rvn_combo_list_pad(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return if (widget_h.rvn_widget_glass(widget) != 0) 5.0 else 1.0;
}

fn rvn_combo_list_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    const combo = list.*.combo;
    var width: f32 = 0.0;
    const row = rvn_combo_row_height(widget);
    const rows: u32 = base.rvn_minu(combo.*.count, RVN_COMBO_MAX_ROWS);
    var i: u32 = 0;
    while (i < combo.*.count) : (i += 1) {
        width = base.rvn_maxf(width, common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, combo.*.items[i]));
    }
    width += widget_h.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 2.0;
    if (combo.*.count > RVN_COMBO_MAX_ROWS) width += widget_h.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    return base.rvn_vec2(@ceil(width), row * @as(f32, @floatFromInt(base.rvn_maxu(rows, 1))) + rvn_combo_list_pad(widget) * 2.0);
}

fn rvn_combo_list_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    list.*.bar.content = rvn_combo_row_height(widget) * @as(f32, @floatFromInt(list.*.combo.*.count));
    list.*.bar.viewport = base.rvn_maxf(0.0, widget.*.rect.h - rvn_combo_list_pad(widget) * 2.0);
    _ = common.rvn_scrollbar_clamp(&list.*.bar);
}

fn rvn_combo_list_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const bar = widget_h.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    const pad = rvn_combo_list_pad(widget);
    return base.rvn_rect(widget.*.rect.w - bar - pad, pad, bar, widget.*.rect.h - pad * 2.0);
}

fn rvn_combo_list_row_at(widget: [*c]const widget_h.rvn_widget_t, y: f32) c_int {
    const list: [*c]const rvn_combo_list_t = @ptrCast(widget);
    const row: c_int = @intFromFloat(@floor((y - rvn_combo_list_pad(widget) + list.*.bar.offset) / rvn_combo_row_height(widget)));
    return if (row >= 0 and row < @as(c_int, @intCast(list.*.combo.*.count))) row else -1;
}

fn rvn_combo_list_reveal(widget: [*c]widget_h.rvn_widget_t, row: c_int) void {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    const height = rvn_combo_row_height(widget);
    const top = height * @as(f32, @floatFromInt(row));
    if (row < 0) return;
    if (top < list.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top);
    } else if (top + height > list.*.bar.offset + list.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top + height - list.*.bar.viewport);
    }
}

fn rvn_combo_list_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    const combo = list.*.combo;
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const row = rvn_combo_row_height(widget);
    const padding = widget_h.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X);
    const radius = widget_h.rvn_widget_metric(widget, raven.R_METRIC_POPUP_RADIUS);
    const pad = rvn_combo_list_pad(widget);
    const text = widget_h.rvn_widget_color(widget, raven.R_COLOR_TEXT);
    const offset = common.rvn_scrollbar_shown(&list.*.bar, painter);
    const first: c_int = @intFromFloat(@floor(offset / row));
    const origin = widget_h.rvn_widget_origin(widget);

    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_POPUP, 0.0, 0.0);
    } else {
        ext.rvn_paint_shadow(painter, base.rvn_rect(0.0, 3.0, rect.w, rect.h), radius, 12.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
        ext.rvn_paint_box(painter, rect, radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP), 1.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP_BORDER));
    }

    ext.rvn_paint_push_clip(painter, base.rvn_rect(1.0, pad, rect.w - 2.0, rect.h - pad * 2.0));
    const last: c_int = base.rvn_mini(@intCast(combo.*.count), first + @as(c_int, @intFromFloat(list.*.bar.viewport / row)) + 3);
    if (list.*.hot >= 0) {
        // the highlight slides under the pointer from row to row
        const y = ext.rvn_paint_spring(painter, &list.*.hot_y, row * @as(f32, @floatFromInt(list.*.hot)), raven.R_MOTION_SNAPPY);
        common.rvn_paint_row(painter, widget, base.rvn_rect(1.0, pad + y - offset, rect.w - 2.0, row), widget_h.rvn_widget_color(widget, raven.R_COLOR_SELECTION));
    } else {
        list.*.hot_y.started = raven.R_FALSE;
    }
    var i: c_int = base.rvn_maxi(first, 0);
    while (i < last) : (i += 1) {
        const line = base.rvn_rect(1.0, pad + row * @as(f32, @floatFromInt(i)) - offset, rect.w - 2.0, row);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), base.rvn_rect(padding, line.y, rect.w - padding * 2.0, row), 0.0, combo.*.items[@intCast(i)], -1, if (i == combo.*.selected) widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT_HOVERED) else text);
    }
    ext.rvn_paint_pop_clip(painter);
    common.rvn_scrollbar_paint(&list.*.bar, widget, painter, rvn_combo_list_track(widget), raven.R_TRUE, if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0, if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0);
}

fn rvn_combo_list_pick(widget: [*c]widget_h.rvn_widget_t, row: c_int) void {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    const combo: [*c]widget_h.rvn_widget_t = &list.*.combo.*.base;
    const window = widget.*.window;
    // close first: the callback may open something else, or delete the combo box
    if (window != null) widget_h.rvn_window_close_popup(window, widget);
    if (row >= 0) rvn_combo_box_select(combo, row, raven.R_TRUE);
}

fn rvn_combo_list_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    var changed: c_int = raven.R_FALSE;
    var row: c_int = undefined;

    if (event.*.@"type" == raven.R_EVENT_MOUSE_DOWN or event.*.@"type" == raven.R_EVENT_MOUSE_MOVE or event.*.@"type" == raven.R_EVENT_MOUSE_UP) {
        if (common.rvn_scrollbar_event(&list.*.bar, widget, event, rvn_combo_list_track(widget), raven.R_TRUE, &changed) != 0) {
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        }
    }
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            row = rvn_combo_list_row_at(widget, event.*.local_y);
            if (row != list.*.hot and row >= 0) {
                list.*.hot = row;
                widget_h.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_DOWN => return raven.R_TRUE,
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_TRUE;
            row = rvn_combo_list_row_at(widget, event.*.local_y);
            if (row >= 0 and event.*.local_x >= 0.0 and event.*.local_x < widget.*.rect.w) rvn_combo_list_pick(widget, row);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if (common.rvn_scrollbar_wheel(&list.*.bar, -event.*.wheel_y * rvn_combo_row_height(widget) * 2.0) != 0) {
                widget_h.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            switch (event.*.key) {
                raven.R_KEY_UP => list.*.hot = base.rvn_maxi(list.*.hot - 1, 0),
                raven.R_KEY_DOWN => list.*.hot = base.rvn_mini(list.*.hot + 1, @as(c_int, @intCast(list.*.combo.*.count)) - 1),
                raven.R_KEY_HOME => list.*.hot = 0,
                raven.R_KEY_END => list.*.hot = @as(c_int, @intCast(list.*.combo.*.count)) - 1,
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER, raven.R_KEY_SPACE => {
                    rvn_combo_list_pick(widget, list.*.hot);
                    return raven.R_TRUE;
                },
                // Escape is left to the window, which closes the popup
                else => return raven.R_FALSE,
            }
            rvn_combo_list_reveal(widget, list.*.hot);
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_combo_list_closed(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_combo_list_t = @ptrCast(widget);
    list.*.bar.dragging = raven.R_FALSE;
    widget_h.rvn_widget_invalidate_paint(&list.*.combo.*.base);
}

// static const in C (private class of the popup list, not exported).
const rvn_class_combo_list: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = common.RVN_WIDGET_INTERNAL_COMBO_LIST,
    .name = "ComboBoxList",
    .size = @sizeOf(rvn_combo_list_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_SURFACE,
    .measure = rvn_combo_list_measure,
    .arrange = rvn_combo_list_arrange,
    .paint = rvn_combo_list_paint,
    .event = rvn_combo_list_event,
    .popup_closed = rvn_combo_list_closed,
});

// ===========================================================================
//  ComboBox
// ===========================================================================

fn rvn_combo_box_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    combo.*.selected = -1;
    combo.*.list = widget_h.rvn_widget_create_class(&rvn_class_combo_list);
    if (combo.*.list != null) {
        const list: [*c]rvn_combo_list_t = @ptrCast(combo.*.list);
        list.*.combo = combo;
        combo.*.list.*.flags |= widget_h.RVN_WF_INTERNAL;
    }
}

fn rvn_combo_box_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    if (combo.*.list != null) widget_h.rvn_widget_destroy(combo.*.list);
    var i: u32 = 0;
    while (i < combo.*.count) : (i += 1) base.rvn_free(combo.*.items[i]);
    base.rvn_free(@ptrCast(combo.*.items));
}

fn rvn_combo_box_is_open(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const combo: [*c]const rvn_combo_box_t = @ptrCast(widget);
    return @intFromBool(combo.*.list != null and (combo.*.list.*.flags & widget_h.RVN_WF_POPUP) != 0);
}

fn rvn_combo_box_open(widget: [*c]widget_h.rvn_widget_t) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    const list: [*c]rvn_combo_list_t = @ptrCast(combo.*.list);
    if (widget.*.window == null or list == null or combo.*.count == 0 or rvn_combo_box_is_open(widget) != 0) return;
    const origin = widget_h.rvn_widget_origin(widget);
    list.*.hot = combo.*.selected;
    list.*.hot_y.started = raven.R_FALSE;
    // the list is made of what its button is made of
    list.*.base.material = widget.*.material;
    widget_h.rvn_window_open_popup(widget.*.window, &list.*.base, widget, base.rvn_rect(origin.x, origin.y, widget.*.rect.w, widget.*.rect.h + 2.0), widget_h.RVN_POPUP_BELOW, widget.*.rect.w);
    // lay the list out now so that the selected row can be scrolled into view
    widget_h.rvn_window_layout(widget.*.window);
    rvn_combo_list_reveal(&list.*.base, combo.*.selected);
}

fn rvn_combo_box_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    const height = widget_h.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT);
    var width: f32 = 0.0;
    var i: u32 = 0;
    while (i < combo.*.count) : (i += 1) {
        width = base.rvn_maxf(width, common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, combo.*.items[i]));
    }
    // text + padding + room for the arrow
    return base.rvn_vec2(@ceil(base.rvn_maxf(width, 40.0) + widget_h.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 2.0 + height * 0.7), height);
}

fn rvn_combo_box_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const padding = widget_h.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X);
    const arrow = widget.*.rect.h * 0.7;
    const open = rvn_combo_box_is_open(widget);
    const hovered: c_int = @intFromBool((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0);
    var fill = widget_h.rvn_widget_color(widget, if (open != 0) raven.R_COLOR_CONTROL_PRESSED else if (hovered != 0) raven.R_COLOR_CONTROL_HOVERED else raven.R_COLOR_CONTROL);
    var outline = widget_h.rvn_widget_color(widget, raven.R_COLOR_CONTROL_BORDER);
    const text = widget_h.rvn_widget_text_color(widget, painter);

    if (dp.enabled == 0) {
        fill = base.rvn_color_fade(fill, 0.5);
        outline = base.rvn_color_fade(outline, 0.5);
    }
    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(painter, widget, rect, common.rvn_control_radius(widget, rect.h), common.RVN_SURFACE_CONTROL, common.rvn_widget_hover(widget, painter, hovered), common.rvn_widget_press(widget, painter, open));
    } else {
        ext.rvn_paint_box(painter, rect, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), fill, widget_h.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), outline);
    }
    if (combo.*.selected >= 0 and combo.*.selected < @as(c_int, @intCast(combo.*.count))) {
        const area = base.rvn_rect(padding, 0.0, base.rvn_maxf(0.0, rect.w - padding - arrow), rect.h);
        ext.rvn_paint_push_clip(painter, area);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), area, 0.0, combo.*.items[@intCast(combo.*.selected)], -1, text);
        ext.rvn_paint_pop_clip(painter);
    }
    ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CHEVRON_DOWN, rect.w - arrow * 0.5 - 2.0, rect.h * 0.5, 7.0, text);
}

fn rvn_combo_box_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    common.rvn_paint_focus(widget, painter, common.rvn_control_radius(widget, widget.*.rect.h));
}

fn rvn_combo_box_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            // when the list is open, the click that closes it never reaches us
            rvn_combo_box_open(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0) return raven.R_FALSE;
            switch (event.*.key) {
                raven.R_KEY_UP => {
                    if (combo.*.selected > 0) rvn_combo_box_select(widget, combo.*.selected - 1, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_DOWN => {
                    if (combo.*.selected + 1 < @as(c_int, @intCast(combo.*.count))) rvn_combo_box_select(widget, combo.*.selected + 1, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER, raven.R_KEY_SPACE => {
                    rvn_combo_box_open(widget);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_combo_box_add(widget: [*c]widget_h.rvn_widget_t, text: [*c]const u8) c_int {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    // RVN_ARRAY_RESERVE(combo->items, combo->cap, combo->count + 1), expanded by hand: the items are char**
    if (combo.*.count + 1 > combo.*.cap) combo.*.items = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(combo.*.items), &combo.*.cap, combo.*.count + 1, @sizeOf([*c]u8))));
    combo.*.items[combo.*.count] = base.rvn_strdup(if (text != null) text else "");
    combo.*.count += 1;
    widget_h.rvn_widget_invalidate_layout(widget);
    if (combo.*.list != null) widget_h.rvn_widget_invalidate_layout(combo.*.list);
    return @as(c_int, @intCast(combo.*.count)) - 1;
}

fn rvn_combo_box_clear(widget: [*c]widget_h.rvn_widget_t) void {
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    if (widget.*.window != null and combo.*.list != null) widget_h.rvn_window_close_popup(widget.*.window, combo.*.list);
    var i: u32 = 0;
    while (i < combo.*.count) : (i += 1) base.rvn_free(combo.*.items[i]);
    combo.*.count = 0;
    combo.*.selected = -1;
    widget_h.rvn_widget_invalidate_layout(widget);
}

fn rvn_combo_box_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    if (RVN_ATTR(name, "Items")) {
        // "First|Second|Third"
        rvn_combo_box_clear(widget);
        var value_ = value;
        while (value_[0] != 0) {
            const length = libc.strcspn(value_, "|");
            const item = base.rvn_strndup(value_, length);
            _ = rvn_combo_box_add(widget, item);
            base.rvn_free(item);
            value_ += length;
            if (value_[0] == '|') value_ += 1;
        }
        return raven.R_TRUE;
    }
    if (RVN_ATTR(name, "Selected")) {
        var index: c_int = undefined;
        if (widget_h.rvn_parse_int(value, &index) == 0) return raven.R_FALSE;
        rvn_combo_box_select(widget, index, raven.R_FALSE);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_combo_box_xml_child(widget: [*c]widget_h.rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    if (base.rvn_stricmp(node.*.name, "Item") != 0) return raven.R_FALSE;
    const text = xml_h.rvn_xml_attribute(node, "Text");
    _ = rvn_combo_box_add(widget, if (text != null) text else node.*.text);
    return raven.R_TRUE;
}

export const rvn_class_combo_box: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_COMBO_BOX,
    .name = "ComboBox",
    .size = @sizeOf(rvn_combo_box_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_combo_box_init,
    .destroy = rvn_combo_box_destroy,
    .measure = rvn_combo_box_measure,
    .paint = rvn_combo_box_paint,
    .paint_overlay = rvn_combo_box_paint_overlay,
    .event = rvn_combo_box_event,
    .set_attribute = rvn_combo_box_set_attribute,
    .xml_child = rvn_combo_box_xml_child,
});

export fn Rcombo_box_add_item(id: raven.Rid, text: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_add_item");
    if (widget == null) return -1;
    return rvn_combo_box_add(widget, text);
}

export fn Rcombo_box_clear_items(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_clear_items");
    if (widget == null) return;
    rvn_combo_box_clear(widget);
}

export fn Rcombo_box_get_item_count(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_get_item_count");
    if (widget == null) return 0;
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    return @intCast(combo.*.count);
}

export fn Rcombo_box_get_item_text(id: raven.Rid, index: c_int) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_get_item_text");
    if (widget == null) return "";
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    return if (index >= 0 and index < @as(c_int, @intCast(combo.*.count))) combo.*.items[@intCast(index)] else "";
}

export fn Rcombo_box_set_selected(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_set_selected");
    if (widget == null) return;
    rvn_combo_box_select(widget, index, raven.R_FALSE);
}

export fn Rcombo_box_get_selected(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_get_selected");
    if (widget == null) return -1;
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    return combo.*.selected;
}

export fn Rcombo_box_set_changed_callback(id: raven.Rid, callback: raven.RComboBoxChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_COMBO_BOX, "Rcombo_box_set_changed_callback");
    if (widget == null) return;
    const combo: [*c]rvn_combo_box_t = @ptrCast(widget);
    combo.*.callback = callback;
    combo.*.user_data = user_data;
}
