// Translated to Zig from vendor/raven/src/widget/widget.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/widget.c
// Widget lifetime, tree structure and the public functions common to all
// widgets (raven_widget.h).

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const handle_h = @import("../core/handle_h.zig");
const libc = @import("../sys/libc.zig");
const widget_h = @import("widget_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;
const rvn_window_t = widget_h.rvn_window_t;

/// RVN_ARRAY_RESERVE (core/base.h) for an array of pointers. The macro is expanded here because
/// base_h.RVN_ARRAY_RESERVE cannot take a pointer to a pointer (its `data.*` is not coercible to anyopaque).
fn reserveArrayOfPointers(comptime T: type, data: *[*c]T, cap: [*c]u32, needed: u32) void {
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(T))));
}

// ---------------------------------------------------------------------------
//  Lookup
// ---------------------------------------------------------------------------

export fn rvn_widget_get(id: raven.Rid) [*c]rvn_widget_t {
    return @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.widgets, id)));
}

export fn rvn_widget_check(id: raven.Rid, @"type": raven.RWidgetType, function: [*c]const u8) [*c]rvn_widget_t {
    if (ctx_h.rvn_api_check(function) == 0) return null;
    const widget = rvn_widget_get(id);
    if (widget == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "%s: invalid widget handle 0x%08X", function, @as(c_uint, id));
        return null;
    }
    if (@"type" != 0 and widget.*.cls.*.type != @"type") {
        const expected = widget_h.rvn_widget_class_by_type(@"type");
        const expected_name: [*c]const u8 = if (expected != null) expected.*.name else "?";
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: expected a %s, got a %s", function, expected_name, widget.*.cls.*.name);
        return null;
    }
    return widget;
}

// ---------------------------------------------------------------------------
//  Creation and destruction
// ---------------------------------------------------------------------------

export fn rvn_widget_create(@"type": raven.RWidgetType) [*c]rvn_widget_t {
    const cls = widget_h.rvn_widget_class_by_type(@"type");
    if (cls == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "unknown widget type 0x%04X", @as(c_uint, @"type"));
        return null;
    }
    return rvn_widget_create_class(cls);
}

export fn rvn_widget_create_class(cls: [*c]const widget_h.rvn_widget_class_t) [*c]rvn_widget_t {
    const widget: [*c]rvn_widget_t = @ptrCast(@alignCast(base.rvn_calloc(cls.*.size)));
    widget.*.cls = cls;
    widget.*.flags = widget_h.RVN_WF_LAYOUT_DIRTY;
    if ((cls.*.flags & widget_h.RVN_CF_NO_HIT) != 0) widget.*.flags |= widget_h.RVN_WF_NO_HIT;
    if ((cls.*.flags & widget_h.RVN_CF_FOCUSABLE) != 0) widget.*.flags |= widget_h.RVN_WF_FOCUSABLE;
    if ((cls.*.flags & widget_h.RVN_CF_CLIP) != 0) widget.*.flags |= widget_h.RVN_WF_CLIP;
    widget.*.visibility = raven.R_VISIBLE;
    widget.*.fixed_size = base.rvn_vec2(-1.0, -1.0);
    widget.*.min_size = base.rvn_vec2(-1.0, -1.0);
    widget.*.max_size = base.rvn_vec2(-1.0, -1.0);
    widget.*.opacity = 1.0;
    widget.*.slot.halign = raven.R_HALIGN_FILL;
    widget.*.slot.valign = raven.R_VALIGN_FILL;
    widget.*.slot.fill = 1.0;
    widget.*.slot.column_span = 1;
    widget.*.slot.row_span = 1;
    widget.*.context_menu = raven.R_INVALID_ID;
    widget.*.subtree_count = 1;
    widget.*.ui_paint_count = if ((cls.*.flags & widget_h.RVN_CF_UI_PAINT) != 0) 1 else 0;
    widget.*.id = handle_h.rvn_pool_add(&ctx_h.g_rvn.widgets, widget);
    if (widget.*.id == raven.R_INVALID_ID) {
        base.rvn_free(widget);
        return null;
    }
    if (cls.*.init) |init_fn| init_fn(widget);
    return widget;
}

/// First phase of a destruction: the subtree loses its handles and is marked dead.
fn rvn_widget_kill(widget: [*c]rvn_widget_t) void {
    widget.*.flags |= widget_h.RVN_WF_DEAD;
    handle_h.rvn_pool_remove(&ctx_h.g_rvn.widgets, widget.*.id);
    widget.*.window = null;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) rvn_widget_kill(widget.*.children[i]);
}

/// Second phase: the memory of the subtree is released.
fn rvn_widget_free(widget: [*c]rvn_widget_t) void {
    if (widget.*.cls.*.destroy) |destroy_fn| destroy_fn(widget);
    // (the handle names nothing any more: it only tells the widgets apart)
    if (widget.*.destroy_callback) |destroy_callback| destroy_callback(widget.*.id, widget.*.destroy_user);
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) rvn_widget_free(widget.*.children[i]);
    base.rvn_free(@ptrCast(widget.*.children));
    base.rvn_free(widget.*.style);
    base.rvn_free(widget.*.fx);
    base.rvn_free(widget.*.name);
    base.rvn_free(widget.*.classes);
    base.rvn_free(widget.*.tooltip);
    base.rvn_free(widget.*.action);
    base.rvn_free(widget.*.slot.title);
    base.rvn_free(widget.*.slot.dock_to);
    widget_h.rvn_a11y_widget_destroyed(widget);
    base.rvn_free(widget);
}

export fn rvn_widget_destroy(widget: [*c]rvn_widget_t) void {
    if (widget == null or (widget.*.flags & widget_h.RVN_WF_DEAD) != 0) return;
    widget_h.rvn_a11y_structure_changed();
    rvn_widget_detach(widget);
    rvn_widget_kill(widget);
    if (ctx_h.g_rvn.dispatch_depth > 0) {
        // application code up the call stack may still hold this pointer
        reserveArrayOfPointers(?*anyopaque, &ctx_h.g_rvn.dead_widgets, &ctx_h.g_rvn.dead_widget_cap, ctx_h.g_rvn.dead_widget_count + 1);
        const index = ctx_h.g_rvn.dead_widget_count;
        ctx_h.g_rvn.dead_widget_count += 1;
        ctx_h.g_rvn.dead_widgets[index] = widget;
    } else {
        rvn_widget_free(widget);
    }
}

export fn rvn_widgets_collect() void {
    // destroy callbacks may delete more widgets: the array can grow while we walk it
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.dead_widget_count) : (i += 1) {
        const dead: [*c]rvn_widget_t = @ptrCast(@alignCast(ctx_h.g_rvn.dead_widgets[i]));
        rvn_widget_free(dead);
    }
    ctx_h.g_rvn.dead_widget_count = 0;
}

// ---------------------------------------------------------------------------
//  Tree
// ---------------------------------------------------------------------------

export fn rvn_widget_set_window(widget: [*c]rvn_widget_t, window: [*c]rvn_window_t) void {
    widget.*.window = window;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) rvn_widget_set_window(widget.*.children[i], window);
}

export fn rvn_widget_child_index(parent: [*c]const rvn_widget_t, child: [*c]const rvn_widget_t) c_int {
    var i: u32 = 0;
    while (i < parent.*.child_count) : (i += 1) {
        if (parent.*.children[i] == child) return @intCast(i);
    }
    return -1;
}

export fn rvn_widget_is_inside(widget_: [*c]const rvn_widget_t, ancestor: [*c]const rvn_widget_t) c_int {
    var widget = widget_;
    while (widget != null) : (widget = widget.*.parent) {
        if (widget == ancestor) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_widget_add_counts(from: [*c]rvn_widget_t, subtree: c_int, ui_paint: c_int) void {
    var walk = from;
    while (walk != null) : (walk = walk.*.parent) {
        walk.*.subtree_count = @bitCast(@as(c_int, @bitCast(walk.*.subtree_count)) + subtree);
        walk.*.ui_paint_count = @bitCast(@as(c_int, @bitCast(walk.*.ui_paint_count)) + ui_paint);
    }
}

export fn rvn_widget_detach(widget: [*c]rvn_widget_t) void {
    const parent = widget.*.parent;
    const window = widget.*.window;

    if (window != null) {
        widget_h.rvn_window_forget_widget(window, widget);
        widget_h.rvn_window_release_natives(window, widget);
        if (window.*.root == widget) window.*.root = null;
        if (window.*.island == widget) window.*.island = null;
        window.*.needs_layout = raven.R_TRUE;
        window.*.needs_paint = raven.R_TRUE;
    }
    if (parent != null) {
        const index = rvn_widget_child_index(parent, widget);
        if (index >= 0) {
            const count_after: usize = parent.*.child_count - @as(u32, @intCast(index)) - 1;
            _ = libc.memmove(
                @ptrCast(&parent.*.children[@intCast(index)]),
                @ptrCast(&parent.*.children[@intCast(index + 1)]),
                @sizeOf([*c]rvn_widget_t) * count_after,
            );
            parent.*.child_count -= 1;
        }
        rvn_widget_add_counts(parent, -@as(c_int, @bitCast(widget.*.subtree_count)), -@as(c_int, @bitCast(widget.*.ui_paint_count)));
        widget.*.parent = null;
    }
    if (window != null) rvn_widget_set_window(widget, null);
    if (parent != null) {
        if (parent.*.cls.*.children_changed) |children_changed| children_changed(parent);
        widget_h.rvn_widget_invalidate_layout(parent);
    }
}

export fn rvn_widget_add_child(parent: [*c]rvn_widget_t, child: [*c]rvn_widget_t, index_: c_int) void {
    var index = index_;
    widget_h.rvn_a11y_structure_changed();
    if (child.*.parent != null or child.*.window != null) rvn_widget_detach(child);

    if ((parent.*.cls.*.flags & widget_h.RVN_CF_SINGLE_CHILD) != 0 and parent.*.child_count > 0) {
        while (parent.*.child_count > 0) rvn_widget_destroy(parent.*.children[parent.*.child_count - 1]);
    }
    if (index < 0 or index > @as(c_int, @intCast(parent.*.child_count))) index = @intCast(parent.*.child_count);
    reserveArrayOfPointers([*c]rvn_widget_t, &parent.*.children, &parent.*.child_cap, parent.*.child_count + 1);
    const count_after: usize = parent.*.child_count - @as(u32, @intCast(index));
    _ = libc.memmove(
        @ptrCast(&parent.*.children[@intCast(index + 1)]),
        @ptrCast(&parent.*.children[@intCast(index)]),
        @sizeOf([*c]rvn_widget_t) * count_after,
    );
    parent.*.children[@intCast(index)] = child;
    parent.*.child_count += 1;
    child.*.parent = parent;
    widget_h.rvn_widget_inherit_theme(child, parent.*.theme);
    rvn_widget_add_counts(parent, @intCast(child.*.subtree_count), @intCast(child.*.ui_paint_count));
    rvn_widget_set_window(child, parent.*.window);
    widget_h.rvn_widget_appear(child);
    if (parent.*.cls.*.children_changed) |children_changed| children_changed(parent);
    widget_h.rvn_widget_invalidate_layout(parent);
}

export fn rvn_widget_is_shown(widget: [*c]const rvn_widget_t) c_int {
    if (widget.*.window == null) return raven.R_FALSE;
    var walk: [*c]const rvn_widget_t = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk.*.visibility != raven.R_VISIBLE) return raven.R_FALSE;
        // an open popup is shown whatever its place in the tree
        if ((walk.*.flags & widget_h.RVN_WF_POPUP) != 0) return raven.R_TRUE;
        if (walk.*.parent != null) {
            if (walk.*.parent.*.cls.*.child_active) |child_active| {
                if (child_active(walk.*.parent, @constCast(walk)) == 0) return raven.R_FALSE;
            }
        }
    }
    return raven.R_TRUE;
}

export fn rvn_widget_is_enabled(widget_: [*c]const rvn_widget_t) c_int {
    var widget = widget_;
    while (widget != null) : (widget = widget.*.parent) {
        if ((widget.*.flags & widget_h.RVN_WF_DISABLED) != 0) return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_widget_origin(widget_: [*c]const rvn_widget_t) base.rvn_vec2_t {
    var widget = widget_;
    var origin = base.rvn_vec2(0.0, 0.0);
    while (widget != null) : (widget = widget.*.parent) {
        origin.x += widget.*.rect.x;
        origin.y += widget.*.rect.y;
        if ((widget.*.flags & widget_h.RVN_WF_POPUP) != 0) break;
    }
    return origin;
}

export fn rvn_widget_to_virtual(widget: [*c]const rvn_widget_t, x: [*c]f32, y: [*c]f32) void {
    const parent = if (widget != null) widget.*.parent else null;
    if (parent == null or (widget.*.flags & widget_h.RVN_WF_POPUP) != 0) return;
    // from the outside in
    rvn_widget_to_virtual(parent, x, y);
    if (parent.*.child_scale > 0.0 and parent.*.child_scale != 1.0) {
        const origin = rvn_widget_origin(parent);
        x.* = origin.x + (x.* - origin.x) / parent.*.child_scale;
        y.* = origin.y + (y.* - origin.y) / parent.*.child_scale;
    }
}

export fn rvn_widget_from_virtual(widget: [*c]const rvn_widget_t, x: [*c]f32, y: [*c]f32) void {
    // from the inside out
    var walk: [*c]const rvn_widget_t = widget;
    while (walk != null and walk.*.parent != null and (walk.*.flags & widget_h.RVN_WF_POPUP) == 0) : (walk = walk.*.parent) {
        const parent = walk.*.parent;
        if (parent.*.child_scale > 0.0 and parent.*.child_scale != 1.0) {
            const origin = rvn_widget_origin(parent);
            x.* = origin.x + (x.* - origin.x) * parent.*.child_scale;
            y.* = origin.y + (y.* - origin.y) * parent.*.child_scale;
        }
    }
}

// ---------------------------------------------------------------------------
//  Public API: creation and tree
// ---------------------------------------------------------------------------

export fn Rwidget_create(@"type": raven.RWidgetType) raven.Rid {
    if (ctx_h.rvn_api_check("Rwidget_create") == 0) return raven.R_INVALID_ID;
    const widget = rvn_widget_create(@"type");
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rwidget_destroy(id: raven.Rid) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_destroy");
    if (widget == null) return;
    rvn_widget_destroy(widget);
}

export fn Rwidget_is_valid(widget: raven.Rid) c_int {
    return @intFromBool(ctx_h.g_rvn.initialized != 0 and rvn_widget_get(widget) != null);
}

export fn Rwidget_get_type(id: raven.Rid) raven.RWidgetType {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_type");
    if (widget == null) return 0;
    return widget.*.cls.*.type;
}

export fn Rwidget_insert_child(parent_id: raven.Rid, child_id: raven.Rid, index: c_int) raven.Rid {
    const parent = rvn_widget_check(parent_id, 0, "Rwidget_insert_child");
    if (parent == null) return raven.R_INVALID_ID;
    const child = rvn_widget_check(child_id, 0, "Rwidget_insert_child");
    if (child == null) return raven.R_INVALID_ID;
    if ((parent.*.cls.*.flags & widget_h.RVN_CF_NO_CHILDREN) != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rwidget_add_child: a %s cannot have children", parent.*.cls.*.name);
        return raven.R_INVALID_ID;
    }
    if (rvn_widget_is_inside(parent, child) != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rwidget_add_child: a widget cannot be added to itself or to one of its descendants");
        return raven.R_INVALID_ID;
    }
    rvn_widget_add_child(parent, child, index);
    return child_id;
}

export fn Rwidget_add_child(parent: raven.Rid, child: raven.Rid) raven.Rid {
    return Rwidget_insert_child(parent, child, -1);
}

export fn Rwidget_remove_child(parent_id: raven.Rid, child_id: raven.Rid) void {
    const parent = rvn_widget_check(parent_id, 0, "Rwidget_remove_child");
    if (parent == null) return;
    const child = rvn_widget_check(child_id, 0, "Rwidget_remove_child");
    if (child == null) return;
    if (child.*.parent != parent) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rwidget_remove_child: the widget is not a child of this parent");
        return;
    }
    rvn_widget_detach(child);
}

export fn Rwidget_clear_children(parent_id: raven.Rid) void {
    const parent = rvn_widget_check(parent_id, 0, "Rwidget_clear_children");
    if (parent == null) return;
    while (parent.*.child_count > 0) rvn_widget_destroy(parent.*.children[parent.*.child_count - 1]);
}

export fn Rwidget_get_parent(id: raven.Rid) raven.Rid {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_parent");
    if (widget == null) return raven.R_INVALID_ID;
    return if (widget.*.parent != null) widget.*.parent.*.id else raven.R_INVALID_ID;
}

export fn Rwidget_get_child_count(id: raven.Rid) c_int {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_child_count");
    if (widget == null) return 0;
    return @intCast(widget.*.child_count);
}

export fn Rwidget_get_child(id: raven.Rid, index: c_int) raven.Rid {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_child");
    if (widget == null) return raven.R_INVALID_ID;
    if (index < 0 or index >= @as(c_int, @intCast(widget.*.child_count))) return raven.R_INVALID_ID;
    return widget.*.children[@intCast(index)].*.id;
}

export fn Rwidget_get_window(id: raven.Rid) raven.Rid {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_window");
    if (widget == null) return raven.R_INVALID_ID;
    return if (widget.*.window != null) widget.*.window.*.id else raven.R_INVALID_ID;
}

export fn Rwidget_set_name(id: raven.Rid, name: [*c]const u8) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_name");
    if (widget == null) return;
    _ = base.rvn_str_set(&widget.*.name, name);
}

export fn Rwidget_get_name(id: raven.Rid) [*c]const u8 {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_name");
    if (widget == null) return "";
    return if (widget.*.name != null) @as([*c]const u8, widget.*.name) else "";
}

fn rvn_widget_find(widget: [*c]rvn_widget_t, name: [*c]const u8) [*c]rvn_widget_t {
    if (widget.*.name != null and libc.strcmp(widget.*.name, name) == 0) return widget;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const found = rvn_widget_find(widget.*.children[i], name);
        if (found != null) return found;
    }
    return null;
}

export fn Rwidget_find(scope: raven.Rid, name: [*c]const u8) raven.Rid {
    var root: [*c]rvn_widget_t = undefined;
    var found: [*c]rvn_widget_t = undefined;
    if (ctx_h.rvn_api_check("Rwidget_find") == 0) return raven.R_INVALID_ID;
    if (name == null) return raven.R_INVALID_ID;
    if (handle_h.rvn_handle_type(scope) == handle_h.RVN_HANDLE_WINDOW) {
        const window = widget_h.rvn_window_check(scope, "Rwidget_find");
        root = if (window != null) window.*.root else null;
        // the island of a window is part of the window
        found = if (root != null) rvn_widget_find(root, name) else null;
        if (found == null and window != null and window.*.island != null) found = rvn_widget_find(window.*.island, name);
        return if (found != null) found.*.id else raven.R_INVALID_ID;
    } else {
        root = rvn_widget_check(scope, 0, "Rwidget_find");
    }
    found = if (root != null) rvn_widget_find(root, name) else null;
    return if (found != null) found.*.id else raven.R_INVALID_ID;
}

// ---------------------------------------------------------------------------
//  Public API: slot
// ---------------------------------------------------------------------------

/// A slot change concerns the layout of the parent.
fn rvn_slot_changed(child: [*c]rvn_widget_t) void {
    widget_h.rvn_widget_invalidate_layout(if (child.*.parent != null) child.*.parent else child);
}

export fn Rslot_set_padding(id: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_padding");
    if (child == null) return;
    child.*.slot.padding = base.rvn_margin(left, top, right, bottom);
    rvn_slot_changed(child);
}

export fn Rslot_set_halign(id: raven.Rid, @"align": raven.RHAlign) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_halign");
    if (child == null) return;
    if (@"align" < raven.R_HALIGN_FILL or @"align" > raven.R_HALIGN_RIGHT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rslot_set_halign: invalid alignment");
        return;
    }
    child.*.slot.halign = @"align";
    rvn_slot_changed(child);
}

export fn Rslot_set_valign(id: raven.Rid, @"align": raven.RVAlign) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_valign");
    if (child == null) return;
    if (@"align" < raven.R_VALIGN_FILL or @"align" > raven.R_VALIGN_BOTTOM) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rslot_set_valign: invalid alignment");
        return;
    }
    child.*.slot.valign = @"align";
    rvn_slot_changed(child);
}

export fn Rslot_set_auto(id: raven.Rid) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_auto");
    if (child == null) return;
    child.*.slot.is_fill = raven.R_FALSE;
    rvn_slot_changed(child);
}

export fn Rslot_set_fill(id: raven.Rid, coefficient: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_fill");
    if (child == null) return;
    child.*.slot.is_fill = raven.R_TRUE;
    child.*.slot.fill = if (coefficient > 0.0) coefficient else 0.0;
    rvn_slot_changed(child);
}

export fn Rslot_set_max_size(id: raven.Rid, max_size: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_max_size");
    if (child == null) return;
    child.*.slot.max_size = if (max_size > 0.0) max_size else 0.0;
    rvn_slot_changed(child);
}

export fn Rslot_set_grid(id: raven.Rid, column: c_int, row: c_int) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_grid");
    if (child == null) return;
    child.*.slot.column = base.rvn_clampi(column, 0, 4095);
    child.*.slot.row = base.rvn_clampi(row, 0, 4095);
    rvn_slot_changed(child);
}

export fn Rslot_set_grid_span(id: raven.Rid, column_span: c_int, row_span: c_int) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_grid_span");
    if (child == null) return;
    child.*.slot.column_span = base.rvn_clampi(column_span, 1, 4096);
    child.*.slot.row_span = base.rvn_clampi(row_span, 1, 4096);
    rvn_slot_changed(child);
}

export fn Rslot_set_anchors(id: raven.Rid, min_x: f32, min_y: f32, max_x: f32, max_y: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_anchors");
    if (child == null) return;
    child.*.slot.anchors[0] = min_x;
    child.*.slot.anchors[1] = min_y;
    child.*.slot.anchors[2] = base.rvn_maxf(min_x, max_x);
    child.*.slot.anchors[3] = base.rvn_maxf(min_y, max_y);
    rvn_slot_changed(child);
}

export fn Rslot_set_position(id: raven.Rid, x: f32, y: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_position");
    if (child == null) return;
    child.*.slot.position[0] = x;
    child.*.slot.position[1] = y;
    rvn_slot_changed(child);
}

export fn Rslot_set_size(id: raven.Rid, width: f32, height: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_size");
    if (child == null) return;
    child.*.slot.size[0] = width;
    child.*.slot.size[1] = height;
    rvn_slot_changed(child);
}

export fn Rslot_set_alignment(id: raven.Rid, x: f32, y: f32) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_alignment");
    if (child == null) return;
    child.*.slot.alignment[0] = x;
    child.*.slot.alignment[1] = y;
    rvn_slot_changed(child);
}

export fn Rslot_set_title(id: raven.Rid, title: [*c]const u8) void {
    const child = rvn_widget_check(id, 0, "Rslot_set_title");
    if (child == null) return;
    if (base.rvn_str_set(&child.*.slot.title, title) != 0) rvn_slot_changed(child);
}

// ---------------------------------------------------------------------------
//  Public API: common properties
// ---------------------------------------------------------------------------

export fn Rwidget_set_visibility(id: raven.Rid, visibility: raven.RVisibility) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_visibility");
    if (widget == null) return;
    if (visibility < raven.R_VISIBLE or visibility > raven.R_COLLAPSED) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_visibility: invalid visibility");
        return;
    }
    if (widget.*.visibility == visibility) return;
    widget.*.visibility = visibility;
    if (visibility != raven.R_VISIBLE and widget.*.window != null) widget_h.rvn_window_forget_widget(widget.*.window, widget);
    if (visibility == raven.R_VISIBLE) widget_h.rvn_widget_appear(widget);
    widget_h.rvn_widget_invalidate_layout(if (widget.*.parent != null) widget.*.parent else widget);
}

export fn Rwidget_get_visibility(id: raven.Rid) raven.RVisibility {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_visibility");
    if (widget == null) return raven.R_COLLAPSED;
    return widget.*.visibility;
}

export fn Rwidget_set_enabled(id: raven.Rid, enabled: c_int) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_enabled");
    if (widget == null) return;
    if (((widget.*.flags & widget_h.RVN_WF_DISABLED) == 0) == (enabled != 0)) return;
    if (enabled != 0) {
        widget.*.flags &= ~widget_h.RVN_WF_DISABLED;
    } else {
        widget.*.flags |= widget_h.RVN_WF_DISABLED;
        if (widget.*.window != null and widget.*.window.*.focus != null and rvn_widget_is_inside(widget.*.window.*.focus, widget) != 0) {
            widget_h.rvn_window_set_focus(widget.*.window, null);
        }
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rwidget_is_enabled(id: raven.Rid) c_int {
    const widget = rvn_widget_check(id, 0, "Rwidget_is_enabled");
    if (widget == null) return raven.R_FALSE;
    return @intFromBool((widget.*.flags & widget_h.RVN_WF_DISABLED) == 0);
}

export fn Rwidget_set_hit_testable(id: raven.Rid, hit_testable: c_int) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_hit_testable");
    if (widget == null) return;
    if (hit_testable != 0) widget.*.flags &= ~widget_h.RVN_WF_NO_HIT else widget.*.flags |= widget_h.RVN_WF_NO_HIT;
}

export fn Rwidget_set_opacity(id: raven.Rid, opacity: f32) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_opacity");
    if (widget == null) return;
    widget.*.opacity = base.rvn_clampf(opacity, 0.0, 1.0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rwidget_set_clipping(id: raven.Rid, clip: c_int) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_clipping");
    if (widget == null) return;
    if (clip != 0) widget.*.flags |= widget_h.RVN_WF_CLIP else widget.*.flags &= ~widget_h.RVN_WF_CLIP;
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rwidget_set_tooltip(id: raven.Rid, text: [*c]const u8) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_tooltip");
    if (widget == null) return;
    const value: [*c]const u8 = if (text != null and text[0] != 0) text else null;
    _ = base.rvn_str_set(&widget.*.tooltip, value);
}

export fn Rwidget_get_tooltip(id: raven.Rid) [*c]const u8 {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_tooltip");
    if (widget == null) return "";
    return if (widget.*.tooltip != null) @as([*c]const u8, widget.*.tooltip) else "";
}

export fn Rwidget_set_cursor(id: raven.Rid, cursor: raven.RCursor) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_cursor");
    if (widget == null) return;
    widget.*.cursor = cursor;
}

export fn Rwidget_set_size(id: raven.Rid, width: f32, height: f32) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_size");
    if (widget == null) return;
    widget.*.fixed_size = base.rvn_vec2(width, height);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_set_min_size(id: raven.Rid, width: f32, height: f32) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_min_size");
    if (widget == null) return;
    widget.*.min_size = base.rvn_vec2(width, height);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_set_max_size(id: raven.Rid, width: f32, height: f32) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_max_size");
    if (widget == null) return;
    widget.*.max_size = base.rvn_vec2(width, height);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_get_rect(id: raven.Rid, x: [*c]f32, y: [*c]f32, width: [*c]f32, height: [*c]f32) void {
    if (x != null) x.* = 0.0;
    if (y != null) y.* = 0.0;
    if (width != null) width.* = 0.0;
    if (height != null) height.* = 0.0;
    const widget = rvn_widget_check(id, 0, "Rwidget_get_rect");
    if (widget == null) return;
    // answer with an up-to-date layout, even right after the tree was built
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) widget_h.rvn_window_layout(widget.*.window);
    const origin = rvn_widget_origin(widget);
    if (x != null) x.* = origin.x;
    if (y != null) y.* = origin.y;
    if (width != null) width.* = widget.*.rect.w;
    if (height != null) height.* = widget.*.rect.h;
}

export fn Rwidget_get_desired_size(id: raven.Rid, width: [*c]f32, height: [*c]f32) void {
    if (width != null) width.* = 0.0;
    if (height != null) height.* = 0.0;
    const widget = rvn_widget_check(id, 0, "Rwidget_get_desired_size");
    if (widget == null) return;
    const desired = widget_h.rvn_widget_measure(widget);
    if (width != null) width.* = desired.x;
    if (height != null) height.* = desired.y;
}

export fn Rwidget_is_hovered(id: raven.Rid) c_int {
    const widget = rvn_widget_check(id, 0, "Rwidget_is_hovered");
    if (widget == null) return raven.R_FALSE;
    return @intFromBool((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0);
}

export fn Rwidget_set_focusable(id: raven.Rid, focusable: c_int) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_focusable");
    if (widget == null) return;
    if (focusable != 0) {
        widget.*.flags |= widget_h.RVN_WF_FOCUSABLE;
    } else {
        widget.*.flags &= ~widget_h.RVN_WF_FOCUSABLE;
        if (widget.*.window != null and widget.*.window.*.focus == widget) widget_h.rvn_window_set_focus(widget.*.window, null);
    }
}

export fn Rwidget_focus(id: raven.Rid) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_focus");
    if (widget == null) return;
    widget_h.rvn_widget_focus(widget);
}

export fn Rwidget_is_focused(id: raven.Rid) c_int {
    const widget = rvn_widget_check(id, 0, "Rwidget_is_focused");
    if (widget == null) return raven.R_FALSE;
    return @intFromBool((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0);
}

export fn Rwidget_set_destroy_callback(id: raven.Rid, callback: raven.RWidgetDestroyCallback, user_data: ?*anyopaque) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_destroy_callback");
    if (widget == null) return;
    widget.*.destroy_callback = callback;
    widget.*.destroy_user = user_data;
}

export fn Rwidget_set_user_handle(id: raven.Rid, handle: ?*anyopaque) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_user_handle");
    if (widget == null) return;
    widget.*.user_handle = handle;
}

export fn Rwidget_get_user_handle(id: raven.Rid) ?*anyopaque {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_user_handle");
    if (widget == null) return null;
    return widget.*.user_handle;
}

export fn Rwidget_set_event_callback(id: raven.Rid, callback: raven.RWidgetEventCallback, user_data: ?*anyopaque) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_event_callback");
    if (widget == null) return;
    widget.*.event_callback = callback;
    widget.*.event_user = user_data;
}

export fn Rwidget_set_action(id: raven.Rid, action: [*c]const u8) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_action");
    if (widget == null) return;
    const value: [*c]const u8 = if (action != null and action[0] != 0) action else null;
    _ = base.rvn_str_set(&widget.*.action, value);
}

export fn Rwidget_get_action(id: raven.Rid) [*c]const u8 {
    const widget = rvn_widget_check(id, 0, "Rwidget_get_action");
    if (widget == null) return "";
    return if (widget.*.action != null) @as([*c]const u8, widget.*.action) else "";
}

export fn Rwidget_set_context_menu(id: raven.Rid, menu: raven.Rid) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_context_menu");
    if (widget == null) return;
    if (menu != raven.R_INVALID_ID and rvn_widget_check(menu, raven.R_WIDGET_MENU, "Rwidget_set_context_menu") == null) return;
    widget.*.context_menu = menu;
}

export fn Rwidget_set_drop_callback(id: raven.Rid, callback: raven.RDropCallback, user_data: ?*anyopaque) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_drop_callback");
    if (widget == null) return;
    widget.*.drop_callback = callback;
    widget.*.drop_user = user_data;
    if (callback == null and widget.*.window != null and widget.*.window.*.drop_target == widget) {
        widget.*.window.*.drop_target = null;
        widget.*.window.*.drop_accepted = raven.R_FALSE;
    }
}

export fn Rwidget_set_window_drag(id: raven.Rid, enabled: c_int) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_set_window_drag");
    if (widget == null) return;
    if (enabled != 0) {
        // (a title is usually a label, which lets the mouse through)
        widget.*.flags |= widget_h.RVN_WF_WINDOW_DRAG;
        widget.*.flags &= ~widget_h.RVN_WF_NO_HIT;
    } else {
        widget.*.flags &= ~widget_h.RVN_WF_WINDOW_DRAG;
        if ((widget.*.cls.*.flags & widget_h.RVN_CF_NO_HIT) != 0) widget.*.flags |= widget_h.RVN_WF_NO_HIT;
    }
}

export fn Rwidget_hit_test(id: raven.Rid, x: f32, y: f32) raven.Rid {
    const widget = rvn_widget_check(id, 0, "Rwidget_hit_test");
    if (widget == null) return raven.R_INVALID_ID;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) widget_h.rvn_window_layout(widget.*.window);
    // (rvn_widget_hit_test takes a point in the space of the parent of the widget)
    const origin = rvn_widget_origin(widget);
    const hit = widget_h.rvn_widget_hit_test(widget, x - origin.x + widget.*.rect.x, y - origin.y + widget.*.rect.y);
    return if (hit != null) hit.*.id else raven.R_INVALID_ID;
}

/// (x, y) in the space of the parent of the widget, as rvn_widget_hit_test.
fn rvn_widget_pick(widget: [*c]rvn_widget_t, x: f32, y: f32) [*c]rvn_widget_t {
    const local_x = x - widget.*.rect.x;
    const local_y = y - widget.*.rect.y;
    const inside = local_x >= 0.0 and local_y >= 0.0 and local_x < widget.*.rect.w and local_y < widget.*.rect.h;
    if (widget.*.visibility != raven.R_VISIBLE) return null;
    if (!inside and ((widget.*.flags & widget_h.RVN_WF_CLIP) != 0 or (widget.*.cls.*.flags & widget_h.RVN_CF_OVERFLOW) == 0)) return null;
    var i: u32 = widget.*.child_count;
    while (i > 0) : (i -= 1) {
        const child = widget.*.children[i - 1];
        if (widget.*.cls.*.child_active) |child_active| {
            if (child_active(widget, child) == 0) continue;
        }
        const hit = rvn_widget_pick(child, local_x, local_y);
        if (hit != null) return hit;
    }
    return if (inside) widget else null;
}

export fn Rwidget_pick(id: raven.Rid, x: f32, y: f32) raven.Rid {
    const widget = rvn_widget_check(id, 0, "Rwidget_pick");
    if (widget == null) return raven.R_INVALID_ID;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) widget_h.rvn_window_layout(widget.*.window);
    const origin = rvn_widget_origin(widget);
    const hit = rvn_widget_pick(widget, x - origin.x + widget.*.rect.x, y - origin.y + widget.*.rect.y);
    return if (hit != null) hit.*.id else raven.R_INVALID_ID;
}

export fn Rwidget_invalidate(id: raven.Rid) void {
    const widget = rvn_widget_check(id, 0, "Rwidget_invalidate");
    if (widget == null) return;
    widget_h.rvn_widget_invalidate_layout(widget);
}
