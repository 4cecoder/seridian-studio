// Translated to Zig from vendor/raven/src/widgets/tree_view.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/tree_view.c
// TreeView (Slate STreeView): hierarchy of text items that expand and
// collapse, with one selection or several (Rtree_view_set_multi_select),
// icons, a menu per item and items that can be dragged (Rdrag_begin). Like the list, it is virtualized: the
// expanded items are flattened into rows and only the visible rows are drawn.
//
// Items are objects with their own Rid handles (Rtree_view_add_item), so the
// application can keep references to them (scene nodes, assets, ...).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const rvn_tree_item_t = extern struct {
    id: raven.Rid,
    tree: [*c]rvn_tree_view_t,
    parent: [*c]rvn_tree_item_t,
    children: [*c][*c]rvn_tree_item_t,
    child_count: u32,
    child_cap: u32,
    text: [*c]u8,
    expanded: c_int,
    /// Nesting level, filled when the rows are rebuilt.
    depth: c_int,
    user_handle: ?*anyopaque,
    /// Icon drawn before the text (Rtree_item_set_icon), or R_INVALID_ID.
    icon: raven.Rid,
    icon_uv: [4]f32,
    /// Text color, 0 = the theme.
    color: base.rvn_color_t,
    /// Part of the selection (several selected items).
    selected: c_int,
};

const rvn_tree_view_t = extern struct {
    base: widget_h.rvn_widget_t,
    /// Invisible item holding the top-level items.
    root: rvn_tree_item_t,
    /// Items currently shown, top to bottom.
    rows: [*c][*c]rvn_tree_item_t,
    row_count: u32,
    row_cap: u32,
    rows_dirty: c_int,
    selected: [*c]rvn_tree_item_t,
    hot: c_int,
    bar: common.rvn_scrollbar_t,
    /// Top of the selection as drawn, in the coordinates of the content.
    select_y: raven.RSpring,
    selection_callback: raven.RTreeEventCallback,
    selection_user: ?*anyopaque,
    activated_callback: raven.RTreeEventCallback,
    activated_user: ?*anyopaque,
    context_callback: raven.RTreeContextCallback,
    context_user: ?*anyopaque,
    /// Several items can be selected (Ctrl toggles, Shift extends).
    multi: c_int,
    /// Where a Shift + click range starts.
    anchor: [*c]rvn_tree_item_t,
    /// Type given to Rdrag_begin when items are dragged, or NULL: no drag.
    drag_type: [*c]u8,
    /// Press that may become a drag.
    press_pending: c_int,
    press_x: f32,
    press_y: f32,
    /// A plain press on an item of a selection of several: on release without a drag, only that one stays.
    press_reduce: [*c]rvn_tree_item_t,
    /// Drop target highlighted by the application (Rtree_view_set_drop_highlight), or NULL.
    drop_item: [*c]rvn_tree_item_t,
    drop_root: c_int,
};

fn rvn_tree_clear_multi(item: [*c]rvn_tree_item_t) void {
    var i: u32 = 0;
    item.*.selected = raven.R_FALSE;
    while (i < item.*.child_count) : (i += 1) rvn_tree_clear_multi(item.*.children[i]);
}

fn rvn_tree_collect_selection(tree: [*c]const rvn_tree_view_t, item: [*c]const rvn_tree_item_t, out: [*c]raven.Rid, count: [*c]c_int, cap: c_int) void {
    var i: u32 = 0;
    while (i < item.*.child_count) : (i += 1) {
        const child: [*c]const rvn_tree_item_t = item.*.children[i];
        if (child.*.selected != 0 or (tree.*.multi == 0 and child == tree.*.selected)) {
            if (out != null and count.* < cap) out[@intCast(count.*)] = child.*.id;
            count.* += 1;
        }
        rvn_tree_collect_selection(tree, child, out, count, cap);
    }
}

// ---------------------------------------------------------------------------
//  Items
// ---------------------------------------------------------------------------

fn rvn_tree_item_get(id: raven.Rid) [*c]rvn_tree_item_t {
    return @ptrCast(@alignCast(ext.rvn_pool_get(&ext.g_rvn.tree_items, id)));
}

fn rvn_tree_item_check(id: raven.Rid, function: [*c]const u8) [*c]rvn_tree_item_t {
    if (ext.rvn_api_check(function) == 0) return null;
    const item = rvn_tree_item_get(id);
    if (item == null) base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "%s: invalid tree item handle 0x%08X", function, @as(c_uint, id));
    return item;
}

fn rvn_tree_changed(tree: [*c]rvn_tree_view_t) void {
    tree.*.rows_dirty = raven.R_TRUE;
    ext.rvn_widget_invalidate_layout(&tree.*.base);
}

fn rvn_tree_item_add(tree: [*c]rvn_tree_view_t, parent: [*c]rvn_tree_item_t, text: [*c]const u8) [*c]rvn_tree_item_t {
    const item: [*c]rvn_tree_item_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_tree_item_t))));
    item.*.tree = tree;
    item.*.icon = raven.R_INVALID_ID;
    item.*.parent = parent;
    const label: [*c]const u8 = if (text != null) text else "";
    item.*.text = base.rvn_strdup(label);
    item.*.id = ext.rvn_pool_add(&ext.g_rvn.tree_items, item);
    if (item.*.id == raven.R_INVALID_ID) {
        base.rvn_free(item.*.text);
        base.rvn_free(item);
        return null;
    }
    const needed_children: u32 = parent.*.child_count + 1;
    if (needed_children > parent.*.child_cap) {
        parent.*.children = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(parent.*.children), &parent.*.child_cap, needed_children, @sizeOf([*c]rvn_tree_item_t))));
    }
    parent.*.children[@intCast(parent.*.child_count)] = item;
    parent.*.child_count += 1;
    rvn_tree_changed(tree);
    return item;
}

fn rvn_tree_item_is_inside(item_: [*c]const rvn_tree_item_t, ancestor: [*c]const rvn_tree_item_t) c_int {
    var item = item_;
    while (item != null) : (item = item.*.parent) {
        if (item == ancestor) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

/// Releases the descendants of an item, and the item itself unless it is the root.
fn rvn_tree_item_free(item: [*c]rvn_tree_item_t) void {
    var i: u32 = 0;
    while (i < item.*.child_count) : (i += 1) rvn_tree_item_free(item.*.children[i]);
    base.rvn_free(@ptrCast(item.*.children));
    item.*.children = null;
    item.*.child_count = 0;
    item.*.child_cap = 0;
    if (item.*.id != 0) {
        ext.rvn_pool_remove(&ext.g_rvn.tree_items, item.*.id);
        base.rvn_free(item.*.text);
        base.rvn_free(item);
    }
}

fn rvn_tree_item_delete(item: [*c]rvn_tree_item_t) void {
    const tree = item.*.tree;
    const parent = item.*.parent;
    var i: u32 = 0;
    if (tree.*.selected != null and rvn_tree_item_is_inside(tree.*.selected, item) != 0) tree.*.selected = null;
    if (tree.*.anchor != null and rvn_tree_item_is_inside(tree.*.anchor, item) != 0) tree.*.anchor = null;
    if (tree.*.press_reduce != null and rvn_tree_item_is_inside(tree.*.press_reduce, item) != 0) tree.*.press_reduce = null;
    if (tree.*.drop_item != null and rvn_tree_item_is_inside(tree.*.drop_item, item) != 0) tree.*.drop_item = null;
    while (parent != null and i < parent.*.child_count) : (i += 1) {
        if (parent.*.children[i] != item) continue;
        _ = libc.memmove(@ptrCast(&parent.*.children[i]), @ptrCast(&parent.*.children[i + 1]), @sizeOf([*c]rvn_tree_item_t) * (parent.*.child_count - i - 1));
        parent.*.child_count -= 1;
        break;
    }
    rvn_tree_item_free(item);
    tree.*.hot = -1;
    rvn_tree_changed(tree);
}

// ---------------------------------------------------------------------------
//  Rows
// ---------------------------------------------------------------------------

fn rvn_tree_flatten(tree: [*c]rvn_tree_view_t, item: [*c]rvn_tree_item_t, depth: c_int) void {
    var i: u32 = 0;
    while (i < item.*.child_count) : (i += 1) {
        const child: [*c]rvn_tree_item_t = item.*.children[i];
        child.*.depth = depth;
        const needed_rows: u32 = tree.*.row_count + 1;
        if (needed_rows > tree.*.row_cap) {
            tree.*.rows = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(tree.*.rows), &tree.*.row_cap, needed_rows, @sizeOf([*c]rvn_tree_item_t))));
        }
        tree.*.rows[@intCast(tree.*.row_count)] = child;
        tree.*.row_count += 1;
        if (child.*.expanded != 0) rvn_tree_flatten(tree, child, depth + 1);
    }
}

fn rvn_tree_update_rows(tree: [*c]rvn_tree_view_t) void {
    if (tree.*.rows_dirty == 0) return;
    tree.*.rows_dirty = raven.R_FALSE;
    tree.*.row_count = 0;
    rvn_tree_flatten(tree, &tree.*.root, 0);
}

fn rvn_tree_row_of(tree: [*c]rvn_tree_view_t, item: [*c]const rvn_tree_item_t) c_int {
    var i: u32 = 0;
    rvn_tree_update_rows(tree);
    while (i < tree.*.row_count) : (i += 1) {
        if (tree.*.rows[i] == item) return @intCast(i);
    }
    return -1;
}

fn rvn_tree_row_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT);
}

// ---------------------------------------------------------------------------
//  Class
// ---------------------------------------------------------------------------

fn rvn_tree_view_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    tree.*.root.tree = tree;
    tree.*.root.expanded = raven.R_TRUE;
    tree.*.hot = -1;
}

fn rvn_tree_view_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_item_free(&tree.*.root);
    base.rvn_free(@ptrCast(tree.*.rows));
    base.rvn_free(tree.*.drag_type);
}

fn rvn_tree_view_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_update_rows(tree);
    return base.rvn_vec2(160.0, rvn_tree_row_height(widget) * @as(f32, @floatFromInt(base.rvn_clampi(@intCast(tree.*.row_count), 3, 10))) + 2.0);
}

fn rvn_tree_view_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_update_rows(tree);
    tree.*.bar.content = rvn_tree_row_height(widget) * @as(f32, @floatFromInt(tree.*.row_count));
    tree.*.bar.viewport = base.rvn_maxf(0.0, widget.*.rect.h - 2.0);
    _ = common.rvn_scrollbar_clamp(&tree.*.bar);
}

fn rvn_tree_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    return base.rvn_rect(widget.*.rect.w - bar - 1.0, 1.0, bar, base.rvn_maxf(0.0, widget.*.rect.h - 2.0));
}

fn rvn_tree_row_at(widget: [*c]widget_h.rvn_widget_t, y: f32) c_int {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (y < 1.0 or y >= widget.*.rect.h - 1.0) return -1;
    rvn_tree_update_rows(tree);
    const row: c_int = @intFromFloat(@floor((y - 1.0 + tree.*.bar.offset) / rvn_tree_row_height(widget)));
    return if (row >= 0 and row < @as(c_int, @intCast(tree.*.row_count))) row else -1;
}

fn rvn_tree_reveal(widget: [*c]widget_h.rvn_widget_t, row: c_int) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    const height = rvn_tree_row_height(widget);
    const top = height * @as(f32, @floatFromInt(row));
    if (row < 0) return;
    rvn_tree_view_arrange(widget);
    if (top < tree.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&tree.*.bar, top);
    } else if (top + height > tree.*.bar.offset + tree.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&tree.*.bar, top + height - tree.*.bar.viewport);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_tree_select_ex(widget: [*c]widget_h.rvn_widget_t, item: [*c]rvn_tree_item_t, notify: c_int, keep_others: c_int) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (tree.*.multi != 0 and keep_others == 0) {
        var count: c_int = 0;
        rvn_tree_collect_selection(tree, &tree.*.root, null, &count, 0);
        const others = count > 1 or (count == 1 and !(item != null and item.*.selected != 0));
        rvn_tree_clear_multi(&tree.*.root);
        if (item != null) item.*.selected = raven.R_TRUE;
        tree.*.anchor = item;
        if (others and tree.*.selected == item) {
            ext.rvn_widget_invalidate_paint(widget);
            if (notify != 0 and tree.*.selection_callback != null) {
                tree.*.selection_callback.?(widget.*.id, if (item != null) item.*.id else raven.R_INVALID_ID, tree.*.selection_user);
            }
            return;
        }
    }
    if (tree.*.selected == item) return;
    tree.*.selected = item;
    if (tree.*.multi == 0) tree.*.anchor = item;
    // an item hidden in a collapsed branch becomes visible
    var walk: [*c]rvn_tree_item_t = if (item != null) item.*.parent else null;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.expanded == 0) {
            walk.*.expanded = raven.R_TRUE;
            rvn_tree_changed(tree);
        }
    }
    if (item != null) rvn_tree_reveal(widget, rvn_tree_row_of(tree, item));
    ext.rvn_widget_invalidate_paint(widget);
    if (notify != 0 and tree.*.selection_callback != null) {
        tree.*.selection_callback.?(widget.*.id, if (item != null) item.*.id else raven.R_INVALID_ID, tree.*.selection_user);
    }
}

fn rvn_tree_select(widget: [*c]widget_h.rvn_widget_t, item: [*c]rvn_tree_item_t, notify: c_int) void {
    rvn_tree_select_ex(widget, item, notify, raven.R_FALSE);
}

/// Shift + click: every row between the anchor and `item`.
fn rvn_tree_select_range(widget: [*c]widget_h.rvn_widget_t, item: [*c]rvn_tree_item_t, add: c_int) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    var from: c_int = undefined;
    var to: c_int = undefined;
    var i: c_int = 0;
    if (tree.*.anchor == null) {
        rvn_tree_select(widget, item, raven.R_TRUE);
        return;
    }
    from = rvn_tree_row_of(tree, tree.*.anchor);
    to = rvn_tree_row_of(tree, item);
    if (from < 0 or to < 0) {
        rvn_tree_select(widget, item, raven.R_TRUE);
        return;
    }
    if (add == 0) rvn_tree_clear_multi(&tree.*.root);
    if (from > to) {
        i = from;
        from = to;
        to = i;
    }
    i = from;
    while (i <= to) : (i += 1) tree.*.rows[@intCast(i)].*.selected = raven.R_TRUE;
    tree.*.selected = null;
    rvn_tree_select_ex(widget, item, raven.R_TRUE, raven.R_TRUE);
    if (tree.*.selected == item) ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_tree_set_expanded(item: [*c]rvn_tree_item_t, expanded_: c_int) void {
    const tree = item.*.tree;
    const expanded: c_int = @intFromBool(expanded_ != 0);
    if (item.*.expanded == expanded) return;
    item.*.expanded = expanded;
    // the selection never stays inside a branch that is being closed
    if (expanded == 0 and tree.*.selected != null and tree.*.selected != item and rvn_tree_item_is_inside(tree.*.selected, item) != 0) {
        tree.*.selected = item;
    }
    rvn_tree_changed(tree);
}

fn rvn_tree_activate(widget: [*c]widget_h.rvn_widget_t) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (tree.*.selected == null) return;
    if (tree.*.activated_callback != null) tree.*.activated_callback.?(widget.*.id, tree.*.selected.*.id, tree.*.activated_user);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
}

fn rvn_tree_view_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const row = rvn_tree_row_height(widget);
    const indent = ext.rvn_widget_metric(widget, raven.R_METRIC_INDENT);
    const focused = (widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0;
    const offset = common.rvn_scrollbar_shown(&tree.*.bar, painter);
    const first: c_int = @intFromFloat(@floor(offset / row));
    var selected_row: c_int = -1;
    const content_width = rect.w - 2.0 - (if (common.rvn_scrollbar_needed(&tree.*.bar) != 0) ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE) else 0.0);
    const text = ext.rvn_widget_text_color(widget, painter);
    const selection = ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION);
    const origin = ext.rvn_widget_origin(widget);

    ext.rvn_paint_box(painter, rect, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), ext.rvn_widget_color(widget, raven.R_COLOR_INPUT),
        ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), ext.rvn_widget_color(widget, if (focused) raven.R_COLOR_FOCUS else raven.R_COLOR_BORDER));

    ext.rvn_paint_push_clip(painter, base.rvn_rect(1.0, 1.0, rect.w - 2.0, rect.h - 2.0));
    const last: c_int = base.rvn_mini(@intCast(tree.*.row_count), first + @as(c_int, @intFromFloat(tree.*.bar.viewport / row)) + 3);
    // the selection slides from the previous row to the new one (a row hidden in a closed branch shows none)
    {
        var i: c_int = 0;
        while (tree.*.selected != null and i < @as(c_int, @intCast(tree.*.row_count))) : (i += 1) {
            if (tree.*.rows[@intCast(i)] == tree.*.selected) {
                selected_row = i;
                break;
            }
        }
    }
    if (selected_row >= 0) {
        const y = ext.rvn_paint_spring(painter, &tree.*.select_y, row * @as(f32, @floatFromInt(selected_row)), raven.R_MOTION_SNAPPY);
        common.rvn_paint_row(painter, widget, base.rvn_rect(1.0, 1.0 + y - offset, content_width, row),
            if (focused) selection else base.rvn_color_mix(selection, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), 0.45));
    } else {
        tree.*.select_y.started = raven.R_FALSE;
    }
    {
        var i: c_int = base.rvn_maxi(first, 0);
        while (i < last) : (i += 1) {
            const item: [*c]rvn_tree_item_t = tree.*.rows[@intCast(i)];
            const line = base.rvn_rect(1.0, 1.0 + row * @as(f32, @floatFromInt(i)) - offset, content_width, row);
            const x = 4.0 + indent * @as(f32, @floatFromInt(item.*.depth));
            var text_x = x + indent;
            if (item == tree.*.selected) {
                // (drawn above)
            } else if (tree.*.multi != 0 and item.*.selected != 0) {
                common.rvn_paint_row(painter, widget, line,
                    if (focused) base.rvn_color_fade(selection, 0.75) else base.rvn_color_mix(selection, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), 0.55));
            } else if (i == tree.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0) {
                common.rvn_paint_row(painter, widget, line, ext.rvn_widget_color(widget, raven.R_COLOR_ROW_HOVERED));
            }
            if (item == tree.*.drop_item) {
                const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
                ext.rvn_paint_box(painter, base.rvn_rect(line.x + 1.0, line.y + 1.0, line.w - 2.0, line.h - 2.0), 4.0,
                    base.rvn_color_fade(accent, 0.18), 1.5, accent);
            }
            if (item.*.child_count > 0) {
                ext.rvn_paint_icon(painter, if (item.*.expanded != 0) draw_h.RVN_ICON_CHEVRON_DOWN else draw_h.RVN_ICON_CHEVRON_RIGHT,
                    x + indent * 0.5, line.y + row * 0.5, 7.0, base.rvn_color_fade(text, 0.75));
            }
            if (item.*.icon != raven.R_INVALID_ID) {
                const size = base.rvn_maxf(4.0, row - 6.0);
                ext.rvn_paint_image(painter, base.rvn_rect(text_x, line.y + (row - size) * 0.5, size, size), item.*.icon, &item.*.icon_uv,
                    base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.0);
                text_x += size + 5.0;
            }
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0),
                base.rvn_rect(text_x, line.y, base.rvn_maxf(0.0, line.w - text_x), row), 0.0, item.*.text, -1,
                if (base.rvn_color_a(item.*.color) != 0) item.*.color else text);
        }
    }
    if (tree.*.drop_root != 0) {
        const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
        ext.rvn_paint_box(painter, base.rvn_rect(2.0, 2.0, rect.w - 4.0, rect.h - 4.0), 5.0, 0, 1.5, accent);
    }
    ext.rvn_paint_pop_clip(painter);
    const mouse_x: f32 = if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0;
    const mouse_y: f32 = if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0;
    common.rvn_scrollbar_paint(&tree.*.bar, widget, painter, rvn_tree_track(widget), raven.R_TRUE, mouse_x, mouse_y);
}

fn rvn_tree_view_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    const indent = ext.rvn_widget_metric(widget, raven.R_METRIC_INDENT);
    var changed: c_int = raven.R_FALSE;
    var row: c_int = undefined;
    var page: c_int = undefined;
    var item: [*c]rvn_tree_item_t = undefined;

    if (event.*.@"type" == raven.R_EVENT_MOUSE_DOWN or event.*.@"type" == raven.R_EVENT_MOUSE_MOVE or event.*.@"type" == raven.R_EVENT_MOUSE_UP) {
        if (common.rvn_scrollbar_event(&tree.*.bar, widget, event, rvn_tree_track(widget), raven.R_TRUE, &changed) != 0) {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        }
    }
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            row = rvn_tree_row_at(widget, event.*.local_y);
            if (row != tree.*.hot) {
                tree.*.hot = row;
                ext.rvn_widget_invalidate_paint(widget);
            }
            // a press on an item that moves far enough drags the selection
            if (tree.*.press_pending != 0 and tree.*.drag_type != null and tree.*.selected != null and widget.*.window != null and
                (widget.*.window.*.buttons & (@as(u32, 1) << @as(u5, @intCast(raven.R_MOUSE_LEFT)))) != 0 and
                (@abs(event.*.x - tree.*.press_x) > 5.0 or @abs(event.*.y - tree.*.press_y) > 5.0))
            {
                var ids: [64]raven.Rid = undefined;
                var count: c_int = 0;
                var i2_: c_int = 0;
                var data: [64 * 12 + 1]u8 = undefined;
                var used: usize = 0;
                tree.*.press_pending = raven.R_FALSE;
                tree.*.press_reduce = null;
                rvn_tree_collect_selection(tree, &tree.*.root, &ids, &count, 64);
                if (count == 0) {
                    ids[0] = tree.*.selected.*.id;
                    count = 1;
                }
                data[0] = 0;
                while (i2_ < count and i2_ < 64) : (i2_ += 1) {
                    used += @as(usize, @intCast(libc.snprintf(&data[used], data.len - used, if (i2_ != 0) " %u" else "%u", @as(c_uint, ids[@intCast(i2_)]))));
                }
                {
                    var label: [160]u8 = undefined;
                    if (count > 1) {
                        _ = libc.snprintf(&label, label.len, "%s (+%d)", tree.*.selected.*.text, count - 1);
                    } else {
                        _ = libc.snprintf(&label, label.len, "%s", tree.*.selected.*.text);
                    }
                    _ = raven.Rdrag_begin(widget.*.id, tree.*.drag_type, &data, &label);
                }
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            tree.*.hot = -1;
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button == raven.R_MOUSE_LEFT and tree.*.press_pending != 0 and tree.*.press_reduce != null) {
                const keep = tree.*.press_reduce;
                tree.*.press_reduce = null;
                tree.*.press_pending = raven.R_FALSE;
                rvn_tree_select(widget, keep, raven.R_TRUE);
                return raven.R_TRUE;
            }
            tree.*.press_reduce = null;
            tree.*.press_pending = raven.R_FALSE;
            if (event.*.button == raven.R_MOUSE_RIGHT and tree.*.context_callback != null) {
                row = rvn_tree_row_at(widget, event.*.local_y);
                item = if (row >= 0) tree.*.rows[@intCast(row)] else null;
                // the menu acts on what is under the pointer
                if (item != null and !(item == tree.*.selected or (tree.*.multi != 0 and item.*.selected != 0))) rvn_tree_select(widget, item, raven.R_TRUE);
                if (common.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                tree.*.context_callback.?(widget.*.id, if (item != null) item.*.id else raven.R_INVALID_ID, event.*.x, event.*.y, tree.*.context_user);
                return raven.R_TRUE;
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button == raven.R_MOUSE_RIGHT and tree.*.context_callback != null) return raven.R_TRUE;
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            row = rvn_tree_row_at(widget, event.*.local_y);
            if (row < 0) {
                // a click in the empty space clears the selection
                if ((event.*.modifiers & (@as(u32, @intCast(raven.R_MOD_CTRL)) | @as(u32, @intCast(raven.R_MOD_SHIFT)))) == 0) {
                    rvn_tree_clear_multi(&tree.*.root);
                    tree.*.anchor = null;
                    if (tree.*.selected != null) rvn_tree_select(widget, null, raven.R_TRUE) else ext.rvn_widget_invalidate_paint(widget);
                }
                return raven.R_TRUE;
            }
            item = tree.*.rows[@intCast(row)];
            const arrow_x: f32 = 5.0 + indent * @as(f32, @floatFromInt(item.*.depth));
            if (item.*.child_count > 0 and event.*.local_x >= arrow_x and event.*.local_x < arrow_x + indent) {
                // the arrow only opens and closes the branch
                rvn_tree_set_expanded(item, @intFromBool(item.*.expanded == 0));
                return raven.R_TRUE;
            }
            tree.*.press_pending = raven.R_TRUE;
            tree.*.press_reduce = null;
            tree.*.press_x = event.*.x;
            tree.*.press_y = event.*.y;
            if (tree.*.multi != 0 and (event.*.modifiers & @as(u32, @intCast(raven.R_MOD_SHIFT))) != 0) {
                rvn_tree_select_range(widget, item, @intFromBool((event.*.modifiers & @as(u32, @intCast(raven.R_MOD_CTRL))) != 0));
                return raven.R_TRUE;
            }
            if (tree.*.multi != 0 and (event.*.modifiers & @as(u32, @intCast(raven.R_MOD_CTRL))) != 0) {
                item.*.selected = if (item.*.selected != 0) raven.R_FALSE else raven.R_TRUE;
                tree.*.anchor = item;
                if (item.*.selected != 0) {
                    tree.*.selected = null;
                    rvn_tree_select_ex(widget, item, raven.R_TRUE, raven.R_TRUE);
                } else {
                    var other: [*c]rvn_tree_item_t = null;
                    var r: u32 = 0;
                    while (r < tree.*.row_count) : (r += 1) {
                        if (tree.*.rows[r].*.selected != 0) other = tree.*.rows[r];
                    }
                    tree.*.selected = null;
                    rvn_tree_select_ex(widget, other, raven.R_TRUE, raven.R_TRUE);
                }
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            }
            // a press on a selected item keeps the others (the drag takes them all)
            if (tree.*.multi != 0 and item.*.selected != 0 and event.*.clicks == 1) {
                tree.*.press_reduce = item;
                if (tree.*.selected != item) {
                    tree.*.selected = null;
                    rvn_tree_select_ex(widget, item, raven.R_TRUE, raven.R_TRUE);
                }
                return raven.R_TRUE;
            }
            rvn_tree_select(widget, item, raven.R_TRUE);
            if (event.*.clicks == 2 and common.rvn_widget_alive(widget) != 0 and tree.*.selected == item) {
                if (item.*.child_count > 0) rvn_tree_set_expanded(item, @intFromBool(item.*.expanded == 0));
                rvn_tree_activate(widget);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if (common.rvn_scrollbar_wheel(&tree.*.bar, -event.*.wheel_y * rvn_tree_row_height(widget) * 3.0) == 0) {
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            }
            tree.*.hot = rvn_tree_row_at(widget, event.*.local_y);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_GAINED, raven.R_EVENT_FOCUS_LOST => {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_KEY_DOWN => {
            rvn_tree_update_rows(tree);
            if (tree.*.row_count == 0) return raven.R_FALSE;
            row = if (tree.*.selected != null) rvn_tree_row_of(tree, tree.*.selected) else -1;
            page = base.rvn_maxi(1, @as(c_int, @intFromFloat(tree.*.bar.viewport / rvn_tree_row_height(widget))) - 1);
            item = tree.*.selected;
            switch (event.*.key) {
                raven.R_KEY_UP => {
                    row = if (row < 0) @as(c_int, @intCast(tree.*.row_count)) - 1 else row - 1;
                },
                raven.R_KEY_DOWN => {
                    row = row + 1;
                },
                raven.R_KEY_PAGE_UP => {
                    row -= page;
                },
                raven.R_KEY_PAGE_DOWN => {
                    row += page;
                },
                raven.R_KEY_HOME => {
                    row = 0;
                },
                raven.R_KEY_END => {
                    row = @as(c_int, @intCast(tree.*.row_count)) - 1;
                },
                raven.R_KEY_LEFT => {
                    // close the branch, or go up to the parent
                    if (item == null) return raven.R_FALSE;
                    if (item.*.expanded != 0 and item.*.child_count > 0) {
                        rvn_tree_set_expanded(item, raven.R_FALSE);
                    } else if (item.*.parent != null and item.*.parent != &tree.*.root) {
                        rvn_tree_select(widget, item.*.parent, raven.R_TRUE);
                    }
                    return raven.R_TRUE;
                },
                raven.R_KEY_RIGHT => {
                    // open the branch, or go down to its first item
                    if (item == null or item.*.child_count == 0) return raven.R_FALSE;
                    if (item.*.expanded == 0) {
                        rvn_tree_set_expanded(item, raven.R_TRUE);
                    } else {
                        rvn_tree_select(widget, item.*.children[0], raven.R_TRUE);
                    }
                    return raven.R_TRUE;
                },
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
                    rvn_tree_activate(widget);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
            rvn_tree_select(widget, tree.*.rows[@intCast(base.rvn_clampi(row, 0, @as(c_int, @intCast(tree.*.row_count)) - 1))], raven.R_TRUE);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

/// <Item Text="..." Expanded="true"> ... nested <Item> ... </Item>
fn rvn_tree_xml_item(tree: [*c]rvn_tree_view_t, parent: [*c]rvn_tree_item_t, node: [*c]const xml_h.rvn_xml_node_t) c_int {
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    var flag: c_int = raven.R_FALSE;

    if (base.rvn_stricmp(node.*.name, "Item") != 0) return raven.R_FALSE;
    const text = ext.rvn_xml_attribute(node, "Text");
    const item = rvn_tree_item_add(tree, parent, if (text != null) text else node.*.text);
    if (item == null) return raven.R_FALSE;
    const expanded = ext.rvn_xml_attribute(node, "Expanded");
    if (expanded != null and ext.rvn_parse_bool(expanded, &flag) != 0) item.*.expanded = flag;
    child = node.*.first_child;
    while (child != null) : (child = child.*.next) {
        if (rvn_tree_xml_item(tree, item, child) == 0) return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

fn rvn_tree_view_xml_child(widget: [*c]widget_h.rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    return rvn_tree_xml_item(tree, &tree.*.root, node);
}

export const rvn_class_tree_view: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_TREE_VIEW,
    .name = "TreeView",
    .size = @sizeOf(rvn_tree_view_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_tree_view_init,
    .destroy = rvn_tree_view_destroy,
    .measure = rvn_tree_view_measure,
    .arrange = rvn_tree_view_arrange,
    .paint = rvn_tree_view_paint,
    .event = rvn_tree_view_event,
    .xml_child = rvn_tree_view_xml_child,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rtree_view_add_item(id: raven.Rid, parent_item: raven.Rid, text: [*c]const u8) raven.Rid {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_add_item");
    if (widget == null) return raven.R_INVALID_ID;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    var parent: [*c]rvn_tree_item_t = &tree.*.root;
    if (parent_item != raven.R_INVALID_ID) {
        parent = rvn_tree_item_check(parent_item, "Rtree_view_add_item");
        if (parent == null) return raven.R_INVALID_ID;
        if (parent.*.tree != tree) {
            base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtree_view_add_item: the parent item belongs to another tree");
            return raven.R_INVALID_ID;
        }
    }
    const item = rvn_tree_item_add(tree, parent, text);
    return if (item != null) item.*.id else raven.R_INVALID_ID;
}

export fn Rtree_item_destroy(id: raven.Rid) void {
    const item = rvn_tree_item_check(id, "Rtree_item_destroy");
    if (item != null) rvn_tree_item_delete(item);
}

export fn Rtree_view_clear_items(id: raven.Rid) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_clear_items");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_item_free(&tree.*.root);
    tree.*.selected = null;
    tree.*.anchor = null;
    tree.*.drop_item = null;
    tree.*.press_reduce = null;
    tree.*.hot = -1;
    tree.*.bar.offset = 0.0;
    rvn_tree_changed(tree);
}

export fn Rtree_item_is_valid(item: raven.Rid) c_int {
    const valid = ext.g_rvn.initialized != 0 and rvn_tree_item_get(item) != null;
    return if (valid) raven.R_TRUE else raven.R_FALSE;
}

export fn Rtree_item_set_text(id: raven.Rid, text: [*c]const u8) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_text");
    const label: [*c]const u8 = if (text != null) text else "";
    if (item != null and base.rvn_str_set(&item.*.text, label) != 0) ext.rvn_widget_invalidate_paint(&item.*.tree.*.base);
}

export fn Rtree_item_get_text(id: raven.Rid) [*c]const u8 {
    const item = rvn_tree_item_check(id, "Rtree_item_get_text");
    return if (item != null) item.*.text else "";
}

export fn Rtree_item_set_expanded(id: raven.Rid, expanded: c_int) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_expanded");
    if (item != null) rvn_tree_set_expanded(item, expanded);
}

export fn Rtree_item_is_expanded(id: raven.Rid) c_int {
    const item = rvn_tree_item_check(id, "Rtree_item_is_expanded");
    return if (item != null) item.*.expanded else raven.R_FALSE;
}

export fn Rtree_item_set_user_handle(id: raven.Rid, handle: ?*anyopaque) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_user_handle");
    if (item != null) item.*.user_handle = handle;
}

export fn Rtree_item_get_user_handle(id: raven.Rid) ?*anyopaque {
    const item = rvn_tree_item_check(id, "Rtree_item_get_user_handle");
    return if (item != null) item.*.user_handle else null;
}

export fn Rtree_view_get_item_count(id: raven.Rid) c_int {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_item_count");
    if (widget == null) return 0;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    return @intCast(tree.*.root.child_count);
}

export fn Rtree_view_get_item(id: raven.Rid, index: c_int) raven.Rid {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_item");
    if (widget == null) return raven.R_INVALID_ID;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (index < 0 or index >= @as(c_int, @intCast(tree.*.root.child_count))) return raven.R_INVALID_ID;
    return tree.*.root.children[@intCast(index)].*.id;
}

export fn Rtree_item_get_parent(id: raven.Rid) raven.Rid {
    const item = rvn_tree_item_check(id, "Rtree_item_get_parent");
    if (item == null or item.*.parent == null or item.*.parent == &item.*.tree.*.root) return raven.R_INVALID_ID;
    return item.*.parent.*.id;
}

export fn Rtree_item_get_child_count(id: raven.Rid) c_int {
    const item = rvn_tree_item_check(id, "Rtree_item_get_child_count");
    return if (item != null) @intCast(item.*.child_count) else 0;
}

export fn Rtree_item_get_child(id: raven.Rid, index: c_int) raven.Rid {
    const item = rvn_tree_item_check(id, "Rtree_item_get_child");
    if (item == null or index < 0 or index >= @as(c_int, @intCast(item.*.child_count))) return raven.R_INVALID_ID;
    return item.*.children[@intCast(index)].*.id;
}

export fn Rtree_view_set_selected_item(id: raven.Rid, item_id: raven.Rid) void {
    var item: [*c]rvn_tree_item_t = null;
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_selected_item");
    if (widget == null) return;
    if (item_id != raven.R_INVALID_ID) {
        item = rvn_tree_item_check(item_id, "Rtree_view_set_selected_item");
        if (item == null) return;
        const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
        if (item.*.tree != tree) {
            base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtree_view_set_selected_item: the item belongs to another tree");
            return;
        }
    }
    rvn_tree_select(widget, item, raven.R_FALSE);
}

export fn Rtree_view_get_selected_item(id: raven.Rid) raven.Rid {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_selected_item");
    if (widget == null) return raven.R_INVALID_ID;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    return if (tree.*.selected != null) tree.*.selected.*.id else raven.R_INVALID_ID;
}

export fn Rtree_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RTreeEventCallback, user_data: ?*anyopaque) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_selection_changed_callback");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    tree.*.selection_callback = callback;
    tree.*.selection_user = user_data;
}

export fn Rtree_view_set_activated_callback(id: raven.Rid, callback: raven.RTreeEventCallback, user_data: ?*anyopaque) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_activated_callback");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    tree.*.activated_callback = callback;
    tree.*.activated_user = user_data;
}

// ---------------------------------------------------------------------------
//  Icons, colors, several selected items, menus and drags
// ---------------------------------------------------------------------------

export fn Rtree_item_set_icon(id: raven.Rid, texture: raven.Rid, u0_: f32, v0: f32, u1_: f32, v1: f32) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_icon");
    if (item == null) return;
    item.*.icon = texture;
    item.*.icon_uv[0] = u0_;
    item.*.icon_uv[1] = v0;
    item.*.icon_uv[2] = u1_;
    item.*.icon_uv[3] = v1;
    ext.rvn_widget_invalidate_paint(&item.*.tree.*.base);
}

export fn Rtree_item_set_text_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_text_color");
    if (item == null) return;
    item.*.color = if (a > 0.0) base.rvn_rgba(r, g, b, a) else 0;
    ext.rvn_widget_invalidate_paint(&item.*.tree.*.base);
}

export fn Rtree_view_set_multi_select(id: raven.Rid, enabled: c_int) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_multi_select");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    tree.*.multi = if (enabled != 0) raven.R_TRUE else raven.R_FALSE;
    rvn_tree_clear_multi(&tree.*.root);
    if (tree.*.multi != 0 and tree.*.selected != null) tree.*.selected.*.selected = raven.R_TRUE;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtree_item_set_selected(id: raven.Rid, selected: c_int) void {
    const item = rvn_tree_item_check(id, "Rtree_item_set_selected");
    if (item == null) return;
    const tree = item.*.tree;
    if (tree.*.multi == 0) {
        if (selected != 0) {
            rvn_tree_select(&tree.*.base, item, raven.R_FALSE);
        } else if (tree.*.selected == item) {
            rvn_tree_select(&tree.*.base, null, raven.R_FALSE);
        }
        return;
    }
    item.*.selected = if (selected != 0) raven.R_TRUE else raven.R_FALSE;
    if (selected != 0 and tree.*.selected == null) tree.*.selected = item;
    if (selected == 0 and tree.*.selected == item) tree.*.selected = null;
    ext.rvn_widget_invalidate_paint(&tree.*.base);
}

export fn Rtree_item_is_selected(id: raven.Rid) c_int {
    const item = rvn_tree_item_check(id, "Rtree_item_is_selected");
    if (item == null) return raven.R_FALSE;
    if (item.*.tree.*.multi != 0) return item.*.selected;
    return if (item.*.tree.*.selected == item) raven.R_TRUE else raven.R_FALSE;
}

export fn Rtree_view_clear_selection(id: raven.Rid) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_clear_selection");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_clear_multi(&tree.*.root);
    tree.*.selected = null;
    tree.*.anchor = null;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtree_view_get_selection_count(id: raven.Rid) c_int {
    var count: c_int = 0;
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_selection_count");
    if (widget == null) return 0;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    rvn_tree_collect_selection(tree, &tree.*.root, null, &count, 0);
    return count;
}

export fn Rtree_view_get_selection(id: raven.Rid, index: c_int) raven.Rid {
    var count: c_int = 0;
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_selection");
    if (widget == null) return raven.R_INVALID_ID;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    var total: c_int = 0;
    rvn_tree_collect_selection(tree, &tree.*.root, null, &total, 0);
    if (index < 0 or index >= total) return raven.R_INVALID_ID;
    const all: [*c]raven.Rid = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(raven.Rid) * @as(usize, @intCast(total)))));
    rvn_tree_collect_selection(tree, &tree.*.root, all, &count, total);
    const result = all[@intCast(index)];
    base.rvn_free(all);
    return result;
}

export fn Rtree_view_set_context_callback(id: raven.Rid, callback: raven.RTreeContextCallback, user_data: ?*anyopaque) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_context_callback");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    tree.*.context_callback = callback;
    tree.*.context_user = user_data;
}

export fn Rtree_view_set_drag_type(id: raven.Rid, @"type": [*c]const u8) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_drag_type");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    base.rvn_free(tree.*.drag_type);
    tree.*.drag_type = if (@"type" != null and @"type"[0] != 0) base.rvn_strdup(@"type") else null;
}

export fn Rtree_view_get_item_at(id: raven.Rid, local_x: f32, local_y: f32) raven.Rid {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_get_item_at");
    if (widget == null) return raven.R_INVALID_ID;
    _ = local_x;
    const row = rvn_tree_row_at(widget, local_y);
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    return if (row >= 0) tree.*.rows[@intCast(row)].*.id else raven.R_INVALID_ID;
}

export fn Rtree_view_set_drop_highlight(id: raven.Rid, item_id: raven.Rid, whole_tree: c_int) void {
    var item: [*c]rvn_tree_item_t = null;
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_set_drop_highlight");
    if (widget == null) return;
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (item_id != raven.R_INVALID_ID) {
        item = rvn_tree_item_get(item_id);
        if (item != null and item.*.tree != tree) item = null;
    }
    const root_flag: c_int = @intFromBool(whole_tree != 0);
    if (tree.*.drop_item == item and tree.*.drop_root == root_flag) return;
    tree.*.drop_item = item;
    tree.*.drop_root = root_flag;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtree_view_scroll_to_item(id: raven.Rid, item_id: raven.Rid) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TREE_VIEW, "Rtree_view_scroll_to_item");
    if (widget == null) return;
    const item = rvn_tree_item_get(item_id);
    const tree: [*c]rvn_tree_view_t = @ptrCast(widget);
    if (item == null or item.*.tree != tree) return;
    rvn_tree_reveal(widget, rvn_tree_row_of(tree, item));
}
