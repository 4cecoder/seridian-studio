// Translated to Zig from vendor/raven/src/widgets/list_view.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/list_view.c
// ListView (Slate SListView): a scrollable list of text rows with one
// selection. Rows are virtualized: only the visible ones are measured and
// drawn, so a list of a million rows costs the same as a list of ten.
//
// The rows are either stored by the list (Rlist_view_add_item) or pulled from the
// application when they are drawn (Rlist_view_set_virtual_items).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const rvn_list_view_t = extern struct {
    base: widget_h.rvn_widget_t,
    items: [*c][*c]u8,
    count: u32,
    cap: u32,
    // virtual mode
    is_virtual: c_int,
    virtual_count: c_int,
    text_callback: raven.RListItemTextCallback,
    text_user: ?*anyopaque,

    selected: c_int,
    hot: c_int,
    bar: common.rvn_scrollbar_t,
    /// Top of the selection as drawn, in the coordinates of the content.
    select_y: raven.RSpring,
    selection_callback: raven.RListEventCallback,
    selection_user: ?*anyopaque,
    activated_callback: raven.RListEventCallback,
    activated_user: ?*anyopaque,
};

fn rvn_list_view_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    list.*.selected = -1;
    list.*.hot = -1;
}

fn rvn_list_view_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    var i: u32 = 0;
    while (i < list.*.count) : (i += 1) base.rvn_free(list.*.items[i]);
    base.rvn_free(@ptrCast(list.*.items));
}

fn rvn_list_count(list: [*c]const rvn_list_view_t) c_int {
    return if (list.*.is_virtual != 0) list.*.virtual_count else @as(c_int, @bitCast(list.*.count));
}

fn rvn_list_text(list: [*c]rvn_list_view_t, index: c_int) [*c]const u8 {
    var text: [*c]const u8 = undefined;
    if (index < 0 or index >= rvn_list_count(list)) return "";
    if (list.*.is_virtual == 0) return list.*.items[@intCast(index)];
    text = if (list.*.text_callback) |callback| callback(list.*.base.id, index, list.*.text_user) else null;
    return if (text != null) text else "";
}

fn rvn_list_row_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT);
}

fn rvn_list_view_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    // a list is usually given its size by a fill slot; this is only a sensible default
    return base.rvn_vec2(160.0, rvn_list_row_height(widget) * @as(f32, @floatFromInt(base.rvn_clampi(rvn_list_count(list), 3, 8))) + 2.0);
}

fn rvn_list_view_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    list.*.bar.content = rvn_list_row_height(widget) * @as(f32, @floatFromInt(rvn_list_count(list)));
    list.*.bar.viewport = base.rvn_maxf(0.0, widget.*.rect.h - 2.0);
    _ = common.rvn_scrollbar_clamp(&list.*.bar);
}

fn rvn_list_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    return base.rvn_rect(widget.*.rect.w - bar - 1.0, 1.0, bar, base.rvn_maxf(0.0, widget.*.rect.h - 2.0));
}

fn rvn_list_row_at(widget: [*c]const widget_h.rvn_widget_t, y: f32) c_int {
    const list: [*c]const rvn_list_view_t = @ptrCast(widget);
    if (y < 1.0 or y >= widget.*.rect.h - 1.0) return -1;
    const row: c_int = @intFromFloat(@floor((y - 1.0 + list.*.bar.offset) / rvn_list_row_height(widget)));
    return if (row >= 0 and row < rvn_list_count(list)) row else -1;
}

fn rvn_list_reveal(widget: [*c]widget_h.rvn_widget_t, row: c_int) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    const height = rvn_list_row_height(widget);
    const top = height * @as(f32, @floatFromInt(row));
    if (row < 0) return;
    // the content length may have changed since the last arrange
    rvn_list_view_arrange(widget);
    if (top < list.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top);
    } else if (top + height > list.*.bar.offset + list.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top + height - list.*.bar.viewport);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_list_select(widget: [*c]widget_h.rvn_widget_t, index: c_int, notify: c_int) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    var index_ = index;
    if (index_ < -1 or index_ >= rvn_list_count(list)) index_ = -1;
    if (list.*.selected == index_) return;
    list.*.selected = index_;
    rvn_list_reveal(widget, index_);
    ext.rvn_widget_invalidate_paint(widget);
    if (notify != 0) {
        if (list.*.selection_callback) |callback| callback(widget.*.id, index_, list.*.selection_user);
    }
}

fn rvn_list_activate(widget: [*c]widget_h.rvn_widget_t) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    if (list.*.selected < 0) return;
    if (list.*.activated_callback) |callback| callback(widget.*.id, list.*.selected, list.*.activated_user);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
}

fn rvn_list_view_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const row = rvn_list_row_height(widget);
    const padding = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 0.8;
    const focused = (widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0;
    const count = rvn_list_count(list);
    const offset = common.rvn_scrollbar_shown(&list.*.bar, painter);
    const first: c_int = @intFromFloat(@floor(offset / row));
    const content_width = rect.w - 2.0 - (if (common.rvn_scrollbar_needed(&list.*.bar) != 0) ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE) else 0.0);
    const text = ext.rvn_widget_text_color(widget, painter);
    const selection = ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION);
    const origin = ext.rvn_widget_origin(widget);
    // only the painter's enabled flag is read from the draw-side layout
    const dp: ?*const draw_h.RPainter = if (painter) |p| @ptrCast(@alignCast(p)) else null;

    ext.rvn_paint_box(painter, rect, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), ext.rvn_widget_color(widget, raven.R_COLOR_INPUT),
        ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), ext.rvn_widget_color(widget, if (focused) raven.R_COLOR_FOCUS else raven.R_COLOR_BORDER));

    ext.rvn_paint_push_clip(painter, base.rvn_rect(1.0, 1.0, rect.w - 2.0, rect.h - 2.0));
    const last: c_int = base.rvn_mini(count, first + @as(c_int, @intFromFloat(list.*.bar.viewport / row)) + 3);
    if (list.*.selected >= 0) {
        // the selection slides from the previous row to the new one; a list without the keyboard focus shows it dimmer
        const y = ext.rvn_paint_spring(painter, &list.*.select_y, row * @as(f32, @floatFromInt(list.*.selected)), raven.R_MOTION_SNAPPY);
        common.rvn_paint_row(painter, widget, base.rvn_rect(1.0, 1.0 + y - offset, content_width, row),
            if (focused) selection else base.rvn_color_mix(selection, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), 0.45));
    } else {
        list.*.select_y.started = raven.R_FALSE;
    }
    var i: c_int = base.rvn_maxi(first, 0);
    while (i < last) : (i += 1) {
        const line = base.rvn_rect(1.0, 1.0 + row * @as(f32, @floatFromInt(i)) - offset, content_width, row);
        if (i == list.*.selected) {
            // (drawn above)
        } else if (i == list.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp != null and dp.?.enabled != 0) {
            common.rvn_paint_row(painter, widget, line, ext.rvn_widget_color(widget, raven.R_COLOR_ROW_HOVERED));
        }
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0),
            base.rvn_rect(line.x + padding, line.y, base.rvn_maxf(0.0, line.w - padding * 2.0), row), 0.0, rvn_list_text(list, i), -1, text);
    }
    ext.rvn_paint_pop_clip(painter);
    common.rvn_scrollbar_paint(&list.*.bar, widget, painter, rvn_list_track(widget), raven.R_TRUE,
        if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0,
        if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0);
}

fn rvn_list_view_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    const count = rvn_list_count(list);
    var changed: c_int = raven.R_FALSE;
    var row: c_int = undefined;

    if (event.*.@"type" == raven.R_EVENT_MOUSE_DOWN or event.*.@"type" == raven.R_EVENT_MOUSE_MOVE or event.*.@"type" == raven.R_EVENT_MOUSE_UP) {
        if (common.rvn_scrollbar_event(&list.*.bar, widget, event, rvn_list_track(widget), raven.R_TRUE, &changed) != 0) {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        }
    }
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            row = rvn_list_row_at(widget, event.*.local_y);
            if (row != list.*.hot) {
                list.*.hot = row;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            list.*.hot = -1;
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            row = rvn_list_row_at(widget, event.*.local_y);
            if (row >= 0) {
                rvn_list_select(widget, row, raven.R_TRUE);
                if (event.*.clicks == 2 and common.rvn_widget_alive(widget) != 0) rvn_list_activate(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if (common.rvn_scrollbar_wheel(&list.*.bar, -event.*.wheel_y * rvn_list_row_height(widget) * 3.0) == 0) {
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            }
            list.*.hot = rvn_list_row_at(widget, event.*.local_y);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_GAINED, raven.R_EVENT_FOCUS_LOST => {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if (count == 0) return raven.R_FALSE;
            const page = base.rvn_maxi(1, @as(c_int, @intFromFloat(list.*.bar.viewport / rvn_list_row_height(widget))) - 1);
            switch (event.*.key) {
                raven.R_KEY_UP => {
                    row = if (list.*.selected < 0) count - 1 else list.*.selected - 1;
                },
                raven.R_KEY_DOWN => {
                    row = list.*.selected + 1;
                },
                raven.R_KEY_PAGE_UP => {
                    row = list.*.selected - page;
                },
                raven.R_KEY_PAGE_DOWN => {
                    row = list.*.selected + page;
                },
                raven.R_KEY_HOME => {
                    row = 0;
                },
                raven.R_KEY_END => {
                    row = count - 1;
                },
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
                    rvn_list_activate(widget);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
            rvn_list_select(widget, base.rvn_clampi(row, 0, count - 1), raven.R_TRUE);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_list_add(widget: [*c]widget_h.rvn_widget_t, text: [*c]const u8) c_int {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    // RVN_ARRAY_RESERVE(list->items, list->cap, list->count + 1), expanded by hand: the items are char**
    if (list.*.count + 1 > list.*.cap) list.*.items = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(list.*.items), &list.*.cap, list.*.count + 1, @sizeOf([*c]u8))));
    list.*.items[list.*.count] = base.rvn_strdup(if (text != null) text else "");
    list.*.count += 1;
    ext.rvn_widget_invalidate_layout(widget);
    return @as(c_int, @bitCast(list.*.count)) - 1;
}

fn rvn_list_clear(widget: [*c]widget_h.rvn_widget_t) void {
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    var i: u32 = 0;
    while (i < list.*.count) : (i += 1) base.rvn_free(list.*.items[i]);
    list.*.count = 0;
    list.*.selected = -1;
    list.*.hot = -1;
    list.*.bar.offset = 0.0;
    ext.rvn_widget_invalidate_layout(widget);
}

fn rvn_list_view_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    if (base.rvn_stricmp(name, "Items") == 0) {
        rvn_list_clear(widget);
        var value_ = value;
        while (value_[0] != 0) {
            const length = libc.strcspn(value_, "|");
            const item = base.rvn_strndup(value_, length);
            _ = rvn_list_add(widget, item);
            base.rvn_free(item);
            value_ += length;
            if (value_[0] == '|') value_ += 1;
        }
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Selected") == 0) {
        var index: c_int = undefined;
        if (ext.rvn_parse_int(value, &index) == 0) return raven.R_FALSE;
        rvn_list_select(widget, index, raven.R_FALSE);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_list_view_xml_child(widget: [*c]widget_h.rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    if (base.rvn_stricmp(node.*.name, "Item") != 0) return raven.R_FALSE;
    const text = ext.rvn_xml_attribute(node, "Text");
    _ = rvn_list_add(widget, if (text != null) text else node.*.text);
    return raven.R_TRUE;
}

export const rvn_class_list_view: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_LIST_VIEW,
    .name = "ListView",
    .size = @sizeOf(rvn_list_view_t),
    // the text of a virtual row comes from an application callback
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_UI_PAINT | widget_h.RVN_CF_SURFACE,
    .init = rvn_list_view_init,
    .destroy = rvn_list_view_destroy,
    .measure = rvn_list_view_measure,
    .arrange = rvn_list_view_arrange,
    .paint = rvn_list_view_paint,
    .event = rvn_list_view_event,
    .set_attribute = rvn_list_view_set_attribute,
    .xml_child = rvn_list_view_xml_child,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rlist_view_add_item(id: raven.Rid, text: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_add_item");
    if (widget == null) return -1;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    if (list.*.is_virtual != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rlist_view_add_item: the list is in virtual mode");
        return -1;
    }
    return rvn_list_add(widget, text);
}

export fn Rlist_view_set_item_text(id: raven.Rid, index: c_int, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_set_item_text");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    if (list.*.is_virtual != 0 or index < 0 or index >= @as(c_int, @bitCast(list.*.count))) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlist_view_set_item_text: invalid index %d", index);
        return;
    }
    if (base.rvn_str_set(&list.*.items[@intCast(index)], if (text != null) text else "") != 0) ext.rvn_widget_invalidate_paint(widget);
}

export fn Rlist_view_get_item_text(id: raven.Rid, index: c_int) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_get_item_text");
    if (widget == null) return "";
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    return rvn_list_text(list, index);
}

export fn Rlist_view_remove_item(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_remove_item");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    if (list.*.is_virtual != 0 or index < 0 or index >= @as(c_int, @bitCast(list.*.count))) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlist_view_remove_item: invalid index %d", index);
        return;
    }
    base.rvn_free(list.*.items[@intCast(index)]);
    _ = libc.memmove(@ptrCast(&list.*.items[@intCast(index)]), @ptrCast(&list.*.items[@intCast(index + 1)]), @sizeOf([*c]u8) * @as(usize, list.*.count - @as(u32, @bitCast(index)) - 1));
    list.*.count -= 1;
    // the selection follows the item it was on
    if (list.*.selected == index) {
        list.*.selected = -1;
    } else if (list.*.selected > index) {
        list.*.selected -= 1;
    }
    list.*.hot = -1;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rlist_view_clear_items(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_clear_items");
    if (widget == null) return;
    rvn_list_clear(widget);
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    list.*.virtual_count = 0;
}

export fn Rlist_view_get_item_count(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_get_item_count");
    if (widget == null) return 0;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    return rvn_list_count(list);
}

export fn Rlist_view_set_virtual_items(id: raven.Rid, count: c_int, callback: raven.RListItemTextCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_set_virtual_items");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    const selected = list.*.selected;
    const offset = list.*.bar.offset;
    rvn_list_clear(widget);
    list.*.is_virtual = @intFromBool(callback != null);
    list.*.virtual_count = if (callback != null and count > 0) count else 0;
    list.*.text_callback = callback;
    list.*.text_user = user_data;
    // refreshing the count of a live list keeps its selection and scroll position
    if (selected < list.*.virtual_count) list.*.selected = selected;
    list.*.bar.offset = offset;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rlist_view_set_selected(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_set_selected");
    if (widget == null) return;
    rvn_list_select(widget, index, raven.R_FALSE);
}

export fn Rlist_view_get_selected(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_get_selected");
    if (widget == null) return -1;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    return list.*.selected;
}

export fn Rlist_view_scroll_to_item(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_scroll_to_item");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    if (index < 0 or index >= rvn_list_count(list)) return;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) ext.rvn_window_layout(widget.*.window);
    rvn_list_reveal(widget, index);
}

export fn Rlist_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RListEventCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_set_selection_changed_callback");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    list.*.selection_callback = callback;
    list.*.selection_user = user_data;
}

export fn Rlist_view_set_activated_callback(id: raven.Rid, callback: raven.RListEventCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LIST_VIEW, "Rlist_view_set_activated_callback");
    if (widget == null) return;
    const list: [*c]rvn_list_view_t = @ptrCast(widget);
    list.*.activated_callback = callback;
    list.*.activated_user = user_data;
}
