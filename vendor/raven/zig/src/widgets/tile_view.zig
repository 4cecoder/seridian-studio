// Translated to Zig from vendor/raven/src/widgets/tile_view.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/tile_view.c
// TileView (Slate STileView): a grid of tiles, an icon over a name, that
// scrolls vertically. The tiles come from the application
// (Rtile_view_set_items) and only the visible ones are asked for and drawn:
// a folder of ten thousand files costs what a folder of ten does.
//
// Selection of several tiles (Ctrl, Shift, a rubber band from the empty
// space, Ctrl + A), activation (double click, Enter), a menu per tile and
// tiles that can be dragged (Rdrag_begin).
//
// The callbacks of the application run while painting: the class paints on
// the UI thread (RVN_CF_UI_PAINT).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const rvn_tile_view_t = extern struct {
    base: widget_h.rvn_widget_t,
    count: c_int,
    item_callback: raven.RTileItemCallback,
    item_user: ?*anyopaque,

    tile_w: f32,
    tile_h: f32,
    icon_size: f32,
    spacing: f32,
    /// Layout="Rows": one item per line, as wide as the view, icon on the left
    rows: c_int,

    /// One flag per tile (count of them).
    selected: [*c]u8,
    selected_cap: c_int,
    current: c_int,
    anchor: c_int,
    hot: c_int,
    bar: common.rvn_scrollbar_t,

    /// press that may become a click, a drag or a rubber band
    press_pending: c_int,
    press_index: c_int,
    press_x: f32,
    press_y: f32,
    press_reduce: c_int,
    band_active: c_int,
    band_x0: f32,
    band_y0: f32,
    band_x1: f32,
    band_y1: f32,
    band_base: [*c]u8,

    drag_type: [*c]u8,
    drag_data_callback: raven.RTileDragDataCallback,
    drag_data_user: ?*anyopaque,
    drop_index: c_int,

    selection_callback: raven.RTileEventCallback,
    selection_user: ?*anyopaque,
    activated_callback: raven.RTileEventCallback,
    activated_user: ?*anyopaque,
    context_callback: raven.RTileContextCallback,
    context_user: ?*anyopaque,
    empty_text: [*c]u8,
};

fn rvn_tile_view_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.tile_w = 112.0;
    tiles.*.tile_h = 112.0;
    tiles.*.icon_size = 64.0;
    tiles.*.spacing = 8.0;
    tiles.*.current = -1;
    tiles.*.anchor = -1;
    tiles.*.hot = -1;
    tiles.*.press_index = -1;
    tiles.*.drop_index = -1;
}

fn rvn_tile_view_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    base.rvn_free(tiles.*.selected);
    base.rvn_free(tiles.*.band_base);
    base.rvn_free(tiles.*.drag_type);
    base.rvn_free(tiles.*.empty_text);
}

fn rvn_tile_reserve(tiles: [*c]rvn_tile_view_t) void {
    if (tiles.*.count <= tiles.*.selected_cap) return;
    tiles.*.selected = @ptrCast(base.rvn_realloc(tiles.*.selected, @intCast(tiles.*.count)));
    const old: usize = @intCast(tiles.*.selected_cap);
    const new: usize = @intCast(tiles.*.count);
    @memset(tiles.*.selected[old..new], 0);
    tiles.*.selected_cap = tiles.*.count;
}

fn rvn_tile_width(widget: [*c]const widget_h.rvn_widget_t) f32 {
    const tiles: [*c]const rvn_tile_view_t = @ptrCast(widget);
    if (tiles.*.rows != 0) {
        const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
        return base.rvn_maxf(16.0, widget.*.rect.w - tiles.*.spacing * 2.0 - bar);
    }
    return tiles.*.tile_w;
}

fn rvn_tile_columns(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const tiles: [*c]const rvn_tile_view_t = @ptrCast(widget);
    if (tiles.*.rows != 0) return 1;
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    const width = widget.*.rect.w - tiles.*.spacing - bar;
    const columns: c_int = @intFromFloat(@floor(width / (tiles.*.tile_w + tiles.*.spacing)));
    return if (columns < 1) 1 else columns;
}

fn rvn_tile_pitch_y(tiles: [*c]const rvn_tile_view_t) f32 {
    return tiles.*.tile_h + tiles.*.spacing;
}

fn rvn_tile_view_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    return base.rvn_vec2(tiles.*.tile_w * 2.0 + tiles.*.spacing * 3.0, tiles.*.tile_h * 2.0 + tiles.*.spacing * 3.0);
}

fn rvn_tile_view_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    const columns = rvn_tile_columns(widget);
    const rows: c_int = @divTrunc(tiles.*.count + columns - 1, columns);
    tiles.*.bar.content = rvn_tile_pitch_y(tiles) * @as(f32, @floatFromInt(rows)) + tiles.*.spacing;
    tiles.*.bar.viewport = base.rvn_maxf(0.0, widget.*.rect.h);
    _ = common.rvn_scrollbar_clamp(&tiles.*.bar);
}

fn rvn_tile_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    return base.rvn_rect(widget.*.rect.w - bar - 1.0, 1.0, bar, base.rvn_maxf(0.0, widget.*.rect.h - 2.0));
}

/// Rectangle of a tile in widget coordinates, for a scroll offset.
fn rvn_tile_rect(widget: [*c]const widget_h.rvn_widget_t, index: c_int, offset: f32) base.rvn_rect_t {
    const tiles: [*c]const rvn_tile_view_t = @ptrCast(widget);
    const columns = rvn_tile_columns(widget);
    const column = @rem(index, columns);
    const row = @divTrunc(index, columns);
    const tile_w = rvn_tile_width(widget);
    return base.rvn_rect(tiles.*.spacing + (tile_w + tiles.*.spacing) * @as(f32, @floatFromInt(column)), tiles.*.spacing + rvn_tile_pitch_y(tiles) * @as(f32, @floatFromInt(row)) - offset, tile_w, tiles.*.tile_h);
}

fn rvn_tile_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const tiles: [*c]const rvn_tile_view_t = @ptrCast(widget);
    const columns = rvn_tile_columns(widget);
    const cx = x - tiles.*.spacing;
    const cy = y + tiles.*.bar.offset - tiles.*.spacing;
    if (cx < 0.0 or cy < 0.0) return -1;
    const column: c_int = @intFromFloat(@floor(cx / (rvn_tile_width(widget) + tiles.*.spacing)));
    const row: c_int = @intFromFloat(@floor(cy / rvn_tile_pitch_y(tiles)));
    if (column >= columns) return -1;
    // the gaps between the tiles are empty space
    if (cx - @as(f32, @floatFromInt(column)) * (rvn_tile_width(widget) + tiles.*.spacing) > rvn_tile_width(widget)) return -1;
    if (cy - @as(f32, @floatFromInt(row)) * rvn_tile_pitch_y(tiles) > tiles.*.tile_h) return -1;
    const index = row * columns + column;
    return if (index < tiles.*.count) index else -1;
}

fn rvn_tile_reveal(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    if (index < 0) return;
    rvn_tile_view_arrange(widget);
    const rect = rvn_tile_rect(widget, index, 0.0);
    if (rect.y - tiles.*.spacing < tiles.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&tiles.*.bar, rect.y - tiles.*.spacing);
    } else if (rect.y + rect.h + tiles.*.spacing > tiles.*.bar.offset + tiles.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&tiles.*.bar, rect.y + rect.h + tiles.*.spacing - tiles.*.bar.viewport);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_tile_notify(widget: [*c]widget_h.rvn_widget_t) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    ext.rvn_widget_invalidate_paint(widget);
    if (tiles.*.selection_callback) |callback| callback(widget.*.id, tiles.*.current, tiles.*.selection_user);
}

fn rvn_tile_select_only(widget: [*c]widget_h.rvn_widget_t, index_in: c_int, notify: c_int) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    var index = index_in;
    rvn_tile_reserve(tiles);
    if (tiles.*.count > 0) @memset(tiles.*.selected[0..@intCast(tiles.*.count)], 0);
    if (index >= 0 and index < tiles.*.count) {
        tiles.*.selected[@intCast(index)] = 1;
    } else {
        index = -1;
    }
    tiles.*.current = index;
    tiles.*.anchor = index;
    rvn_tile_reveal(widget, index);
    if (notify != 0) rvn_tile_notify(widget) else ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_tile_activate(widget: [*c]widget_h.rvn_widget_t) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    if (tiles.*.current < 0) return;
    if (tiles.*.activated_callback) |callback| callback(widget.*.id, tiles.*.current, tiles.*.activated_user);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
}

fn rvn_tile_view_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const offset = common.rvn_scrollbar_shown(&tiles.*.bar, painter);
    const columns = rvn_tile_columns(widget);
    const pitch = rvn_tile_pitch_y(tiles);
    const first_row: c_int = @intFromFloat(@floor((offset - tiles.*.spacing) / pitch));
    const last_row: c_int = @as(c_int, @intFromFloat(@floor((offset + widget.*.rect.h) / pitch))) + 1;
    const first: c_int = base.rvn_maxi(0, first_row * columns);
    const last: c_int = base.rvn_mini(tiles.*.count, (last_row + 1) * columns);
    var i: c_int = undefined;
    const focused = (widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0;
    const radius = ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    const font_size = common.rvn_widget_font_size(widget, 0.0);
    const text = ext.rvn_widget_text_color(widget, painter);
    const selection = ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION);
    const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    const origin = ext.rvn_widget_origin(widget);

    rvn_tile_reserve(tiles);
    ext.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));

    if (tiles.*.count == 0 and tiles.*.empty_text != null and tiles.*.empty_text[0] != 0) {
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size, base.rvn_rect(0.0, 0.0, widget.*.rect.w, font_size * 3.0), 0.5,
            tiles.*.empty_text, -1, ext.rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED));
    }

    i = first;
    while (i < last) : (i += 1) {
        var item = std.mem.zeroes(raven.RTileItem);
        const rect = rvn_tile_rect(widget, i, offset);
        const is_selected = tiles.*.selected[@intCast(i)] != 0;
        var icon: f32 = undefined;
        var label_y: f32 = undefined;
        item.icon = raven.R_INVALID_ID;
        item.tint[0] = 1.0;
        item.tint[1] = 1.0;
        item.tint[2] = 1.0;
        item.tint[3] = 1.0;
        item.uv[2] = 1.0;
        item.uv[3] = 1.0;
        if (tiles.*.item_callback) |callback| callback(widget.*.id, i, &item, tiles.*.item_user);
        if (common.rvn_widget_alive(widget) == 0) break;

        if (is_selected) {
            ext.rvn_paint_box(painter, rect, radius, if (focused) base.rvn_color_fade(selection, 0.85) else base.rvn_color_fade(selection, 0.5),
                if (i == tiles.*.current) 2.0 else 0.0, accent);
        } else if (i == tiles.*.drop_index) {
            ext.rvn_paint_box(painter, rect, radius, base.rvn_color_fade(accent, 0.15), 1.5, accent);
        } else if (i == tiles.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0) {
            ext.rvn_paint_box(painter, rect, radius, ext.rvn_widget_color(widget, raven.R_COLOR_ROW_HOVERED), 0.0, 0);
        }

        if (tiles.*.rows != 0) {
            const label: [*c]const u8 = if (item.text != null) item.text else "";
            const has_detail = item.detail != null and item.detail[0] != 0;
            icon = base.rvn_minf(tiles.*.icon_size, rect.h - 6.0);
            if (item.icon != raven.R_INVALID_ID and icon >= 4.0)
                ext.rvn_paint_image(painter, base.rvn_rect(@floor(rect.x + 6.0), @floor(rect.y + (rect.h - icon) * 0.5), icon, icon),
                    item.icon, &item.uv, base.rvn_rgba(item.tint[0], item.tint[1], item.tint[2], item.tint[3]), item.icon_radius);
            const text_x: f32 = rect.x + 6.0 + (if (item.icon != raven.R_INVALID_ID) icon + 10.0 else 0.0);
            const text_h: f32 = font_size + 4.0 + (if (has_detail) font_size * 0.85 + 6.0 else 0.0);
            label_y = @floor(rect.y + (rect.h - text_h) * 0.5);
            ext.rvn_paint_push_clip(painter, base.rvn_rect(text_x, rect.y, rect.x + rect.w - text_x - 4.0, rect.h));
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size, base.rvn_rect(text_x, label_y, rect.x + rect.w - text_x - 8.0, font_size + 4.0),
                0.0, label, -1, if (item.text_color[3] > 0.0)
                    base.rvn_rgba(item.text_color[0], item.text_color[1], item.text_color[2], item.text_color[3]) else text);
            if (has_detail)
                ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size * 0.85,
                    base.rvn_rect(text_x, label_y + font_size + 6.0, rect.x + rect.w - text_x - 8.0, font_size + 2.0), 0.0,
                    item.detail, -1, if (is_selected) text else ext.rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED));
            if (item.badge != null and item.badge[0] != 0)
                ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size * 0.85,
                    base.rvn_rect(rect.x, label_y, rect.w - 8.0, font_size + 4.0), 1.0, item.badge, -1, base.rvn_color_fade(text, 0.7));
            ext.rvn_paint_pop_clip(painter);
            continue;
        }

        icon = base.rvn_minf(tiles.*.icon_size, base.rvn_minf(rect.w - 8.0, rect.h - font_size - 14.0));
        if (icon < 4.0) icon = 4.0;
        if (item.icon != raven.R_INVALID_ID) {
            // a small hop when hovered
            const hop: f32 = if (i == tiles.*.hot and tiles.*.band_active == 0) -2.0 else 0.0;
            ext.rvn_paint_image(painter, base.rvn_rect(@floor(rect.x + (rect.w - icon) * 0.5), @floor(rect.y + 5.0 + hop), icon, icon),
                item.icon, &item.uv, base.rvn_rgba(item.tint[0], item.tint[1], item.tint[2], item.tint[3]), item.icon_radius);
        }
        if (item.badge != null and item.badge[0] != 0) {
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size * 0.8,
                base.rvn_rect(rect.x + 4.0, rect.y + 2.0, rect.w - 8.0, font_size), 1.0, item.badge, -1,
                base.rvn_color_fade(text, 0.7));
        }
        label_y = rect.y + 5.0 + icon + 2.0;
        ext.rvn_paint_push_clip(painter, base.rvn_rect(rect.x + 3.0, label_y, rect.w - 6.0, rect.y + rect.h - label_y));
        {
            const font = ext.rvn_font_resolve(raven.R_INVALID_ID);
            const label: [*c]const u8 = if (item.text != null) item.text else "";
            const width: f32 = if (font != null) ext.rvn_text_width(font, font_size, label, -1) else 0.0;
            // a name too long starts at the left (its beginning is what tells the files apart)
            const align_: f32 = if (width > rect.w - 8.0) 0.0 else 0.5;
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size, base.rvn_rect(rect.x + 4.0, label_y, rect.w - 8.0, font_size + 6.0),
                align_, label, -1, if (item.text_color[3] > 0.0)
                    base.rvn_rgba(item.text_color[0], item.text_color[1], item.text_color[2], item.text_color[3]) else text);
            if (item.detail != null and item.detail[0] != 0) {
                ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size * 0.85,
                    base.rvn_rect(rect.x + 4.0, label_y + font_size + 4.0, rect.w - 8.0, font_size + 4.0), 0.5,
                    item.detail, -1, ext.rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED));
            }
        }
        ext.rvn_paint_pop_clip(painter);
    }

    if (tiles.*.band_active != 0) {
        const x0 = base.rvn_minf(tiles.*.band_x0, tiles.*.band_x1);
        const x1 = base.rvn_maxf(tiles.*.band_x0, tiles.*.band_x1);
        const y0 = base.rvn_minf(tiles.*.band_y0, tiles.*.band_y1) - offset;
        const y1 = base.rvn_maxf(tiles.*.band_y0, tiles.*.band_y1) - offset;
        ext.rvn_paint_box(painter, base.rvn_rect(x0, y0, x1 - x0, y1 - y0), 2.0, base.rvn_color_fade(accent, 0.18), 1.0, base.rvn_color_fade(accent, 0.9));
    }
    ext.rvn_paint_pop_clip(painter);
    common.rvn_scrollbar_paint(&tiles.*.bar, widget, painter, rvn_tile_track(widget), raven.R_TRUE,
        if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0,
        if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0);
}

/// The tiles inside the rubber band (content coordinates) join the base selection.
fn rvn_tile_band_update(widget: [*c]widget_h.rvn_widget_t) void {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    const x0 = base.rvn_minf(tiles.*.band_x0, tiles.*.band_x1);
    const x1 = base.rvn_maxf(tiles.*.band_x0, tiles.*.band_x1);
    const y0 = base.rvn_minf(tiles.*.band_y0, tiles.*.band_y1);
    const y1 = base.rvn_maxf(tiles.*.band_y0, tiles.*.band_y1);
    var i: c_int = 0;
    var last_inside: c_int = -1;
    rvn_tile_reserve(tiles);
    while (i < tiles.*.count) : (i += 1) {
        const rect = rvn_tile_rect(widget, i, 0.0);
        const inside = rect.x <= x1 and rect.x + rect.w >= x0 and rect.y <= y1 and rect.y + rect.h >= y0;
        const k: usize = @intCast(i);
        tiles.*.selected[k] = @intFromBool(inside or (tiles.*.band_base != null and tiles.*.band_base[k] != 0));
        if (inside) last_inside = i;
    }
    if (last_inside >= 0) tiles.*.current = last_inside;
    rvn_tile_notify(widget);
}

fn rvn_tile_view_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    var changed: c_int = raven.R_FALSE;
    var index: c_int = undefined;

    if (event.*.@"type" == raven.R_EVENT_MOUSE_DOWN or event.*.@"type" == raven.R_EVENT_MOUSE_MOVE or event.*.@"type" == raven.R_EVENT_MOUSE_UP) {
        if (tiles.*.band_active == 0 and common.rvn_scrollbar_event(&tiles.*.bar, widget, event, rvn_tile_track(widget), raven.R_TRUE, &changed) != 0) {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        }
    }
    rvn_tile_reserve(tiles);
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            index = rvn_tile_at(widget, event.*.local_x, event.*.local_y);
            if (index != tiles.*.hot) {
                tiles.*.hot = index;
                ext.rvn_widget_invalidate_paint(widget);
            }
            if (tiles.*.band_active != 0) {
                const bottom = widget.*.rect.h;
                tiles.*.band_x1 = base.rvn_clampf(event.*.local_x, 0.0, widget.*.rect.w);
                // past the top or the bottom: the grid scrolls
                if (event.*.local_y < 0.0) {
                    _ = common.rvn_scrollbar_set(&tiles.*.bar, tiles.*.bar.offset + event.*.local_y * 0.3);
                } else if (event.*.local_y > bottom) {
                    _ = common.rvn_scrollbar_set(&tiles.*.bar, tiles.*.bar.offset + (event.*.local_y - bottom) * 0.3);
                }
                tiles.*.band_y1 = base.rvn_clampf(event.*.local_y, 0.0, bottom) + tiles.*.bar.offset;
                rvn_tile_band_update(widget);
                return raven.R_TRUE;
            }
            if (tiles.*.press_pending != 0 and tiles.*.press_index >= 0 and tiles.*.drag_type != null and widget.*.window != null and
                (widget.*.window.*.buttons & (@as(u32, 1) << @as(u5, @intCast(raven.R_MOUSE_LEFT)))) != 0 and
                (@abs(event.*.x - tiles.*.press_x) > 5.0 or @abs(event.*.y - tiles.*.press_y) > 5.0))
            {
                var data: [*c]u8 = undefined;
                var cap: usize = 16;
                var used: usize = 0;
                var i: c_int = 0;
                var count: c_int = 0;
                var item = std.mem.zeroes(raven.RTileItem);
                var label: [192]u8 = undefined;
                tiles.*.press_pending = raven.R_FALSE;
                tiles.*.press_reduce = raven.R_FALSE;
                data = @ptrCast(base.rvn_alloc(cap));
                data[0] = 0;
                while (i < tiles.*.count) : (i += 1) {
                    var number: [16]u8 = undefined;
                    if (tiles.*.selected[@intCast(i)] == 0) continue;
                    const fmt: [*c]const u8 = if (count != 0) " %d" else "%d";
                    const length: usize = @intCast(libc.snprintf(&number, number.len, fmt, i));
                    if (used + length + 1 > cap) {
                        while (used + length + 1 > cap) cap *= 2;
                        data = @ptrCast(base.rvn_realloc(data, cap));
                    }
                    @memcpy((data + used)[0 .. length + 1], number[0 .. length + 1]);
                    used += length;
                    count += 1;
                }
                // the application may give its own data (paths...) instead of the indices
                if (tiles.*.drag_data_callback) |callback| {
                    const given = callback(widget.*.id, tiles.*.drag_data_user);
                    if (common.rvn_widget_alive(widget) == 0) {
                        base.rvn_free(data);
                        return raven.R_TRUE;
                    }
                    if (given != null) {
                        base.rvn_free(data);
                        data = base.rvn_strdup(given);
                    }
                }
                item.icon = raven.R_INVALID_ID;
                if (tiles.*.item_callback) |callback| callback(widget.*.id, tiles.*.press_index, &item, tiles.*.item_user);
                const text: [*c]const u8 = if (item.text != null) item.text else "";
                if (count > 1) {
                    _ = libc.snprintf(&label, label.len, "%s (+%d)", text, count - 1);
                } else {
                    _ = libc.snprintf(&label, label.len, "%s", text);
                }
                if (common.rvn_widget_alive(widget) != 0) _ = raven.Rdrag_begin(widget.*.id, tiles.*.drag_type, data, &label);
                base.rvn_free(data);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            tiles.*.hot = -1;
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button == raven.R_MOUSE_RIGHT and tiles.*.context_callback != null) return raven.R_TRUE;
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            ext.rvn_widget_capture_mouse(widget);
            index = rvn_tile_at(widget, event.*.local_x, event.*.local_y);
            tiles.*.press_pending = raven.R_TRUE;
            tiles.*.press_index = index;
            tiles.*.press_reduce = raven.R_FALSE;
            tiles.*.press_x = event.*.x;
            tiles.*.press_y = event.*.y;
            if (index < 0) {
                // the empty space: a rubber band (Ctrl / Shift keep what is selected)
                const keep = (event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_SHIFT)) != 0;
                base.rvn_free(tiles.*.band_base);
                tiles.*.band_base = null;
                if (keep and tiles.*.count > 0) {
                    const n: usize = @intCast(tiles.*.count);
                    tiles.*.band_base = @ptrCast(base.rvn_alloc(n));
                    @memcpy(tiles.*.band_base[0..n], tiles.*.selected[0..n]);
                } else {
                    rvn_tile_select_only(widget, -1, raven.R_TRUE);
                }
                tiles.*.band_active = raven.R_TRUE;
                tiles.*.band_x0 = event.*.local_x;
                tiles.*.band_x1 = event.*.local_x;
                tiles.*.band_y0 = event.*.local_y + tiles.*.bar.offset;
                tiles.*.band_y1 = event.*.local_y + tiles.*.bar.offset;
                return raven.R_TRUE;
            }
            if (event.*.clicks == 2 and index == tiles.*.current) {
                tiles.*.press_pending = raven.R_FALSE;
                rvn_tile_activate(widget);
                return raven.R_TRUE;
            }
            if ((event.*.modifiers & raven.R_MOD_SHIFT) != 0) {
                var from: c_int = if (tiles.*.anchor >= 0) tiles.*.anchor else index;
                var to: c_int = index;
                var i: c_int = undefined;
                if ((event.*.modifiers & raven.R_MOD_CTRL) == 0) @memset(tiles.*.selected[0..@intCast(tiles.*.count)], 0);
                if (from > to) {
                    i = from;
                    from = to;
                    to = i;
                }
                i = from;
                while (i <= to) : (i += 1) tiles.*.selected[@intCast(i)] = 1;
                tiles.*.current = index;
                rvn_tile_notify(widget);
            } else if ((event.*.modifiers & raven.R_MOD_CTRL) != 0) {
                const k: usize = @intCast(index);
                tiles.*.selected[k] = @intFromBool(tiles.*.selected[k] == 0);
                tiles.*.anchor = index;
                tiles.*.current = if (tiles.*.selected[k] != 0) index else -1;
                if (tiles.*.current < 0) {
                    var i: c_int = 0;
                    while (i < tiles.*.count) : (i += 1) {
                        if (tiles.*.selected[@intCast(i)] != 0) tiles.*.current = i;
                    }
                }
                rvn_tile_notify(widget);
            } else if (tiles.*.selected[@intCast(index)] != 0) {
                // a press on a selected tile keeps the others (a drag takes them all)
                tiles.*.press_reduce = raven.R_TRUE;
                if (tiles.*.current != index) {
                    tiles.*.current = index;
                    rvn_tile_notify(widget);
                }
            } else {
                rvn_tile_select_only(widget, index, raven.R_TRUE);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button == raven.R_MOUSE_RIGHT and tiles.*.context_callback != null) {
                index = rvn_tile_at(widget, event.*.local_x, event.*.local_y);
                if (index >= 0 and tiles.*.selected[@intCast(index)] == 0) rvn_tile_select_only(widget, index, raven.R_TRUE);
                if (common.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                tiles.*.context_callback.?(widget.*.id, index, event.*.x, event.*.y, tiles.*.context_user);
                return raven.R_TRUE;
            }
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            ext.rvn_widget_release_mouse(widget);
            if (tiles.*.band_active != 0) {
                tiles.*.band_active = raven.R_FALSE;
                base.rvn_free(tiles.*.band_base);
                tiles.*.band_base = null;
                ext.rvn_widget_invalidate_paint(widget);
            } else if (tiles.*.press_pending != 0 and tiles.*.press_reduce != 0 and tiles.*.press_index >= 0) {
                rvn_tile_select_only(widget, tiles.*.press_index, raven.R_TRUE);
            }
            tiles.*.press_pending = raven.R_FALSE;
            tiles.*.press_reduce = raven.R_FALSE;
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if ((event.*.modifiers & raven.R_MOD_CTRL) != 0) return raven.R_FALSE; // left to the application (zoom)
            if (common.rvn_scrollbar_wheel(&tiles.*.bar, -event.*.wheel_y * rvn_tile_pitch_y(tiles) * 0.75) == 0) {
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            }
            tiles.*.hot = rvn_tile_at(widget, event.*.local_x, event.*.local_y);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_GAINED, raven.R_EVENT_FOCUS_LOST => {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_KEY_DOWN => {
            const columns = rvn_tile_columns(widget);
            var next: c_int = tiles.*.current;
            if (tiles.*.count == 0) return raven.R_FALSE;
            switch (event.*.key) {
                raven.R_KEY_LEFT => next = if (next < 0) 0 else next - 1,
                raven.R_KEY_RIGHT => next = next + 1,
                raven.R_KEY_UP => next = if (next < 0) 0 else next - columns,
                raven.R_KEY_DOWN => next = if (next < 0) 0 else next + columns,
                raven.R_KEY_HOME => next = 0,
                raven.R_KEY_END => next = tiles.*.count - 1,
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
                    rvn_tile_activate(widget);
                    return raven.R_TRUE;
                },
                raven.R_KEY_A => {
                    if ((event.*.modifiers & raven.R_MOD_CTRL) == 0) return raven.R_FALSE;
                    @memset(tiles.*.selected[0..@intCast(tiles.*.count)], 1);
                    if (tiles.*.current < 0) tiles.*.current = 0;
                    rvn_tile_notify(widget);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
            next = base.rvn_clampi(next, 0, tiles.*.count - 1);
            rvn_tile_select_only(widget, next, raven.R_TRUE);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_tile_view_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    var number: f32 = undefined;
    if (base.rvn_stricmp(name, "TileWidth") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        tiles.*.tile_w = base.rvn_maxf(16.0, number);
    } else if (base.rvn_stricmp(name, "Layout") == 0) {
        if (base.rvn_stricmp(value, "Rows") == 0) {
            tiles.*.rows = raven.R_TRUE;
        } else if (base.rvn_stricmp(value, "Tiles") == 0) {
            tiles.*.rows = raven.R_FALSE;
        } else {
            return raven.R_FALSE;
        }
        ext.rvn_widget_invalidate_layout(widget);
    } else if (base.rvn_stricmp(name, "TileHeight") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        tiles.*.tile_h = base.rvn_maxf(16.0, number);
    } else if (base.rvn_stricmp(name, "IconSize") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        tiles.*.icon_size = base.rvn_maxf(4.0, number);
    } else if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        tiles.*.spacing = base.rvn_maxf(0.0, number);
    } else if (base.rvn_stricmp(name, "EmptyText") == 0) {
        _ = base.rvn_str_set(&tiles.*.empty_text, value);
    } else if (base.rvn_stricmp(name, "DragType") == 0) {
        base.rvn_free(tiles.*.drag_type);
        tiles.*.drag_type = if (value != null and value[0] != 0) base.rvn_strdup(value) else null;
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_tile_view: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_TILE_VIEW,
    .name = "TileView",
    .size = @sizeOf(rvn_tile_view_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_UI_PAINT,
    .init = rvn_tile_view_init,
    .destroy = rvn_tile_view_destroy,
    .measure = rvn_tile_view_measure,
    .arrange = rvn_tile_view_arrange,
    .paint = rvn_tile_view_paint,
    .event = rvn_tile_view_event,
    .set_attribute = rvn_tile_view_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rtile_view_set_items(id: raven.Rid, count: c_int, callback: raven.RTileItemCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_items");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.count = if (count < 0) 0 else count;
    tiles.*.item_callback = callback;
    tiles.*.item_user = user_data;
    rvn_tile_reserve(tiles);
    // other items: the selection does not carry over
    if (tiles.*.selected_cap > 0) @memset(tiles.*.selected[0..@intCast(tiles.*.selected_cap)], 0);
    tiles.*.current = -1;
    tiles.*.anchor = -1;
    tiles.*.hot = -1;
    tiles.*.press_index = -1;
    tiles.*.drop_index = -1;
    tiles.*.press_pending = raven.R_FALSE;
    tiles.*.band_active = raven.R_FALSE;
    base.rvn_free(tiles.*.band_base);
    tiles.*.band_base = null;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rtile_view_refresh(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_refresh");
    if (widget == null) return;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtile_view_get_count(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_get_count");
    if (widget == null) return 0;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    return tiles.*.count;
}

export fn Rtile_view_set_tile_size(id: raven.Rid, width: f32, height: f32, icon_size: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_tile_size");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.tile_w = base.rvn_maxf(16.0, width);
    tiles.*.tile_h = base.rvn_maxf(16.0, height);
    tiles.*.icon_size = base.rvn_maxf(4.0, icon_size);
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rtile_view_set_empty_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_empty_text");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    _ = base.rvn_str_set(&tiles.*.empty_text, text);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtile_view_set_selected(id: raven.Rid, index: c_int, selected: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_selected");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    if (index < 0 or index >= tiles.*.count) return;
    rvn_tile_reserve(tiles);
    tiles.*.selected[@intCast(index)] = @intFromBool(selected != 0);
    if (selected != 0) {
        tiles.*.current = index;
    } else if (tiles.*.current == index) {
        tiles.*.current = -1;
    }
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtile_view_is_selected(id: raven.Rid, index: c_int) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_is_selected");
    if (widget == null) return raven.R_FALSE;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    if (index < 0 or index >= tiles.*.count or index >= tiles.*.selected_cap) return raven.R_FALSE;
    return @intFromBool(tiles.*.selected[@intCast(index)] != 0);
}

export fn Rtile_view_clear_selection(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_clear_selection");
    if (widget == null) return;
    rvn_tile_select_only(widget, -1, raven.R_FALSE);
}

export fn Rtile_view_select_only(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_select_only");
    if (widget == null) return;
    rvn_tile_select_only(widget, index, raven.R_FALSE);
}

export fn Rtile_view_get_current(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_get_current");
    if (widget == null) return -1;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    return tiles.*.current;
}

export fn Rtile_view_get_selection_count(id: raven.Rid) c_int {
    var i: c_int = 0;
    var count: c_int = 0;
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_get_selection_count");
    if (widget == null) return 0;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    while (i < tiles.*.count and i < tiles.*.selected_cap) : (i += 1) {
        count += @as(c_int, @intFromBool(tiles.*.selected[@intCast(i)] != 0));
    }
    return count;
}

export fn Rtile_view_get_selection(id: raven.Rid, nth: c_int) c_int {
    var i: c_int = 0;
    var count: c_int = 0;
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_get_selection");
    if (widget == null) return -1;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    while (i < tiles.*.count and i < tiles.*.selected_cap) : (i += 1) {
        if (tiles.*.selected[@intCast(i)] == 0) continue;
        const old = count;
        count += 1;
        if (old == nth) return i;
    }
    return -1;
}

export fn Rtile_view_scroll_to(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_scroll_to");
    if (widget == null) return;
    rvn_tile_reveal(widget, index);
}

export fn Rtile_view_get_item_at(id: raven.Rid, local_x: f32, local_y: f32) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_get_item_at");
    if (widget == null) return -1;
    return rvn_tile_at(widget, local_x, local_y);
}

export fn Rtile_view_set_drop_highlight(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_drop_highlight");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    if (tiles.*.drop_index == index) return;
    tiles.*.drop_index = index;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtile_view_set_drag_type(id: raven.Rid, type_: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_drag_type");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    base.rvn_free(tiles.*.drag_type);
    tiles.*.drag_type = if (type_ != null and type_[0] != 0) base.rvn_strdup(type_) else null;
}

export fn Rtile_view_set_drag_data_callback(id: raven.Rid, callback: raven.RTileDragDataCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_drag_data_callback");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.drag_data_callback = callback;
    tiles.*.drag_data_user = user_data;
}

export fn Rtile_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RTileEventCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_selection_changed_callback");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.selection_callback = callback;
    tiles.*.selection_user = user_data;
}

export fn Rtile_view_set_activated_callback(id: raven.Rid, callback: raven.RTileEventCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_activated_callback");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.activated_callback = callback;
    tiles.*.activated_user = user_data;
}

export fn Rtile_view_set_context_callback(id: raven.Rid, callback: raven.RTileContextCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TILE_VIEW, "Rtile_view_set_context_callback");
    if (widget == null) return;
    const tiles: [*c]rvn_tile_view_t = @ptrCast(widget);
    tiles.*.context_callback = callback;
    tiles.*.context_user = user_data;
}
