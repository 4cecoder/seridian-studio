// Translated to Zig from vendor/raven/src/widgets/dock_area.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/dock_area.c
// DockArea: panels that the user arranges, side by side or behind tabs.
//
// Every child of the area is a panel. Where the panels are is a binary tree:
// a node is either a group (panels sharing a bar of tabs, one of them shown)
// or a split (two nodes next to each other, or one above the other, and the
// share of the first). Closing the last panel of a group removes the group
// and gives its place to its neighbour.
//
// The tree gives each group a rectangle; the group is drawn in a rectangle of
// its own that runs after it on four springs. That is the whole animation:
// when a panel is dropped somewhere, its new group starts where the preview
// of the drop was and the others glide to the places the tree now gives them.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const libc = @import("../sys/libc.zig");
const draw_h = @import("../render/draw_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const ext = @import("externs.zig");
const common = @import("common_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;
const rvn_widget_class_t = widget_h.rvn_widget_class_t;
const rvn_rect_t = base.rvn_rect_t;
const rvn_vec2_t = base.rvn_vec2_t;
const rvn_color_t = base.rvn_color_t;
const RSpring = raven.RSpring;
const Rid = raven.Rid;

/// A panel is not squeezed below this size by its neighbours.
const RVN_DOCK_MIN: f32 = 72.0;
/// Distance the pointer travels with a tab before the panel comes off.
const RVN_DOCK_DRAG_START: f32 = 6.0;
/// Bands along the edges of the area that dock a panel against the whole area.
const RVN_DOCK_EDGE: f32 = 22.0;
/// How far out of the area a tab is dragged before its panel comes off into a window of its own.
const RVN_DOCK_TEAR: f32 = 28.0;

// typedef enum rvn_dock_drop_t {...} rvn_dock_drop_t;   (a C enum is an int)
const rvn_dock_drop_t = c_int;
const RVN_DOCK_DROP_NONE: rvn_dock_drop_t = 0;
const RVN_DOCK_DROP_LEFT: rvn_dock_drop_t = 1;
const RVN_DOCK_DROP_RIGHT: rvn_dock_drop_t = 2;
const RVN_DOCK_DROP_TOP: rvn_dock_drop_t = 3;
const RVN_DOCK_DROP_BOTTOM: rvn_dock_drop_t = 4;
const RVN_DOCK_DROP_TAB: rvn_dock_drop_t = 5;
/// Out of the area, over nothing that docks: a window of its own (tearing).
const RVN_DOCK_DROP_FLOAT: rvn_dock_drop_t = 6;
/// Over another area of the same family (the home area, a floating one): its drop fields say where.
const RVN_DOCK_DROP_ELSEWHERE: rvn_dock_drop_t = 7;

const rvn_dock_node_t = extern struct {
    parent: [*c]rvn_dock_node_t,
    // split (a != NULL)
    a: [*c]rvn_dock_node_t,
    b: [*c]rvn_dock_node_t,
    /// R_TRUE: `a` is above `b`. R_FALSE: `a` is left of `b`.
    vertical: c_int,
    /// Share of `a`, 0..1.
    ratio: f32,
    // group (a == NULL)
    panels: [*c][*c]rvn_widget_t,
    count: u32,
    cap: u32,
    active: c_int,
    /// Where the tree puts the node, in the coordinates of the area.
    rect: rvn_rect_t,
    /// Groups: where the group is drawn; it moves to `rect`.
    x: RSpring,
    y: RSpring,
    w: RSpring,
    h: RSpring,
    placed: c_int,
    /// The targets the window was asked to move the four springs to.
    chasing: [4]c_int,
    goal: [4]f32,
    /// Groups: the mark of the shown tab slides from tab to tab.
    mark_x: RSpring,
    mark_w: RSpring,
};

// A hidden panel and where it goes back when it is opened again.
const rvn_dock_hidden_t = extern struct {
    panel: [*c]rvn_widget_t,
    where: rvn_dock_drop_t,
    /// Panel it was against (may be gone or hidden by then), or NULL: the whole area.
    relative: [*c]rvn_widget_t,
    size: f32,
};

const rvn_dock_area_t = extern struct {
    base: rvn_widget_t,
    root: [*c]rvn_dock_node_t,
    locked: c_int,
    /// The size the groups were last arranged for: a resized area does not animate.
    last_w: f32,
    last_h: f32,
    snap: c_int,
    /// Set by Rdock_area_add_panel around the insertion of the child: the panel to dock against.
    pending_relative: [*c]rvn_widget_t,
    pending_valid: c_int,
    /// R_TRUE while the area itself changes its children.
    syncing: c_int,

    // the tab under the pointer
    hot_node: [*c]rvn_dock_node_t,
    hot_tab: c_int,
    hot_close: c_int,
    // a press on a tab; it becomes a drag when the pointer moves away
    press_node: [*c]rvn_dock_node_t,
    press_panel: [*c]rvn_widget_t,
    /// Panel whose tab got the middle button down: released on the same tab, it closes.
    middle_panel: [*c]rvn_widget_t,
    press_close: c_int,
    press_x: f32,
    press_y: f32,
    dragging: c_int,
    pointer_x: f32,
    pointer_y: f32,
    // where the dragged panel would go
    drop: rvn_dock_drop_t,
    drop_node: [*c]rvn_dock_node_t,
    drop_index: c_int,
    drop_rect: rvn_rect_t,
    preview_x: RSpring,
    preview_y: RSpring,
    preview_w: RSpring,
    preview_h: RSpring,
    preview_shown: RSpring,
    // the tab that follows the pointer, and goes on fading where it was dropped
    chip_panel: [*c]rvn_widget_t,
    chip_x: RSpring,
    chip_y: RSpring,
    chip_shown: RSpring,
    // a border between two nodes being dragged
    resize_node: [*c]rvn_dock_node_t,
    resize_grab: f32,

    close_callback: raven.RDockCloseCallback,
    close_user: ?*anyopaque,
    changed_callback: raven.RDockChangedCallback,
    changed_user: ?*anyopaque,
    layout_text: [*c]u8,

    // panels that are children of the area but not in the tree (Rdock_area_hide_panel)
    hidden: [*c]rvn_dock_hidden_t,
    hidden_count: u32,
    hidden_cap: u32,
    /// R_TRUE: the close button of a tab hides the panel instead of deleting it.
    close_hides: c_int,

    // Tearing. A panel dragged out of the area goes to a window of its own:
    // a floating area, whose `home` is the area it came from. The home area
    // keeps its floating areas; a floating area keeps where each of its
    // panels goes back to in the home area. A tab dragged from one area of
    // the family over another shows the drop there, and is docked there.
    tearable: c_int,
    home: Rid,
    float_window: Rid,
    floats: [*c]Rid,
    float_count: u32,
    float_cap: u32,
    returns: [*c]rvn_dock_hidden_t,
    return_count: u32,
    return_cap: u32,
    /// A panel of another area of the family is dragged over this one: the preview is drawn here.
    foreign_panel: [*c]rvn_widget_t,
    /// While dragging, RVN_DOCK_DROP_ELSEWHERE: the area where the panel would be dropped.
    drop_area: Rid,
    /// The only tab of a floating window is dragged: the window follows the pointer.
    moving_window: c_int,
    grab_x: f32,
    grab_y: f32,
    /// The window of this floating area is closing: it must not be closed again.
    closing: c_int,
};

// ---------------------------------------------------------------------------
//  Tree
// ---------------------------------------------------------------------------

fn rvn_dock_is_split(node: [*c]const rvn_dock_node_t) c_int {
    return @intFromBool(node.*.a != null);
}

fn rvn_dock_group_new() [*c]rvn_dock_node_t {
    return @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_dock_node_t))));
}

// Releases one node (not its children).
fn rvn_dock_node_free(widget: [*c]rvn_widget_t, node: [*c]rvn_dock_node_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    // (the window may be advancing these springs)
    widget_h.rvn_widget_forget_layout_spring(widget, &node.*.x);
    widget_h.rvn_widget_forget_layout_spring(widget, &node.*.y);
    widget_h.rvn_widget_forget_layout_spring(widget, &node.*.w);
    widget_h.rvn_widget_forget_layout_spring(widget, &node.*.h);
    if (area.*.hot_node == node) area.*.hot_node = null;
    if (area.*.press_node == node) area.*.press_node = null;
    if (area.*.drop_node == node) {
        area.*.drop_node = null;
        area.*.drop = RVN_DOCK_DROP_NONE;
    }
    if (area.*.resize_node == node) area.*.resize_node = null;
    base.rvn_free(@ptrCast(node.*.panels));
    base.rvn_free(node);
}

fn rvn_dock_tree_free(widget: [*c]rvn_widget_t, node: [*c]rvn_dock_node_t) void {
    if (node == null) return;
    rvn_dock_tree_free(widget, node.*.a);
    rvn_dock_tree_free(widget, node.*.b);
    rvn_dock_node_free(widget, node);
}

// Group holding a panel, or NULL.
fn rvn_dock_find(node: [*c]rvn_dock_node_t, panel: [*c]const rvn_widget_t, index: [*c]c_int) [*c]rvn_dock_node_t {
    if (node == null) return null;
    if (rvn_dock_is_split(node) != 0) {
        const found = rvn_dock_find(node.*.a, panel, index);
        return if (found != null) found else rvn_dock_find(node.*.b, panel, index);
    }
    var i: u32 = 0;
    while (i < node.*.count) : (i += 1) {
        if (node.*.panels[i] == panel) {
            if (index != null) index.* = @intCast(i);
            return node;
        }
    }
    return null;
}

fn rvn_dock_first_group(node_in: [*c]rvn_dock_node_t) [*c]rvn_dock_node_t {
    var node = node_in;
    while (node != null and rvn_dock_is_split(node) != 0) node = node.*.a;
    return node;
}

// Puts `with` where `node` is in the tree.
fn rvn_dock_replace(area: [*c]rvn_dock_area_t, node: [*c]rvn_dock_node_t, with: [*c]rvn_dock_node_t) void {
    const parent = node.*.parent;
    with.*.parent = parent;
    if (parent == null) {
        area.*.root = with;
    } else if (parent.*.a == node) {
        parent.*.a = with;
    } else {
        parent.*.b = with;
    }
}

fn rvn_dock_group_insert(group: [*c]rvn_dock_node_t, panel: [*c]rvn_widget_t, index_in: c_int) void {
    var index = index_in;
    if (index < 0 or index > @as(c_int, @intCast(group.*.count))) index = @intCast(group.*.count);
    // C: RVN_ARRAY_RESERVE(&group->panels, &group->cap, group->count + 1) — written out here because
    // the header-unit macro passes the array through as ?*anyopaque, which a pointer-element array
    // (rvn_widget_t**) needs an explicit cast for.
    if (@as(u32, @intCast(group.*.count + 1)) > group.*.cap) {
        group.*.panels = @ptrCast(@alignCast(base.rvn_array_grow_(
            @ptrCast(group.*.panels),
            &group.*.cap,
            @intCast(group.*.count + 1),
            @sizeOf([*c]rvn_widget_t),
        )));
    }
    _ = libc.memmove(
        @ptrCast(&group.*.panels[@intCast(index + 1)]),
        @ptrCast(&group.*.panels[@intCast(index)]),
        @sizeOf([*c]rvn_widget_t) * @as(usize, group.*.count - @as(u32, @intCast(index))),
    );
    group.*.panels[@intCast(index)] = panel;
    group.*.count += 1;
    group.*.active = index;
}

// Takes a panel out of the tree. A group left empty disappears and its neighbour takes its place.
fn rvn_dock_remove(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var index: c_int = 0;
    const group = rvn_dock_find(area.*.root, panel, &index);
    if (group == null) return;
    _ = libc.memmove(
        @ptrCast(&group.*.panels[@intCast(index)]),
        @ptrCast(&group.*.panels[@intCast(index + 1)]),
        @sizeOf([*c]rvn_widget_t) * @as(usize, group.*.count - @as(u32, @intCast(index)) - 1),
    );
    group.*.count -= 1;
    if (group.*.active > index or group.*.active >= @as(c_int, @intCast(group.*.count))) group.*.active -= 1;
    if (group.*.active < 0 and group.*.count > 0) group.*.active = 0;
    if (group.*.count > 0) return;

    if (group.*.parent == null) {
        area.*.root = null;
    } else {
        const split = group.*.parent;
        const other = if (split.*.a == group) split.*.b else split.*.a;
        rvn_dock_replace(area, split, other);
        rvn_dock_node_free(widget, split);
    }
    rvn_dock_node_free(widget, group);
}

// Puts a panel in the tree: behind the tabs of `target` (a group; `index` is
// its place among the tabs, -1 for the end), or in a new group on a side of
// `target` (any node; NULL is the whole area), which gets `size` of the room.
// Returns the group of the panel.
fn rvn_dock_insert(
    widget: [*c]rvn_widget_t,
    panel: [*c]rvn_widget_t,
    where: rvn_dock_drop_t,
    target_in: [*c]rvn_dock_node_t,
    size_in: f32,
    index: c_int,
) [*c]rvn_dock_node_t {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var target = target_in;
    var size = size_in;
    var group: [*c]rvn_dock_node_t = undefined;
    var split: [*c]rvn_dock_node_t = undefined;

    if (area.*.root == null) {
        group = rvn_dock_group_new();
        rvn_dock_group_insert(group, panel, 0);
        area.*.root = group;
        return group;
    }
    if (where == RVN_DOCK_DROP_TAB or where == RVN_DOCK_DROP_NONE) {
        group = if (target != null and rvn_dock_is_split(target) == 0) target else rvn_dock_first_group(if (target != null) target else area.*.root);
        rvn_dock_group_insert(group, panel, index);
        return group;
    }
    if (target == null) target = area.*.root;
    if (size <= 0.0 or size >= 1.0) size = if (target == area.*.root and rvn_dock_is_split(target) != 0) 0.25 else 0.5;

    group = rvn_dock_group_new();
    rvn_dock_group_insert(group, panel, 0);
    split = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_dock_node_t))));
    split.*.vertical = @intFromBool(where == RVN_DOCK_DROP_TOP or where == RVN_DOCK_DROP_BOTTOM);
    rvn_dock_replace(area, target, split);
    if (where == RVN_DOCK_DROP_LEFT or where == RVN_DOCK_DROP_TOP) {
        split.*.a = group;
        split.*.b = target;
        split.*.ratio = size;
    } else {
        split.*.a = target;
        split.*.b = group;
        split.*.ratio = 1.0 - size;
    }
    target.*.parent = split;
    group.*.parent = split;
    return group;
}

// ---------------------------------------------------------------------------
//  Geometry
// ---------------------------------------------------------------------------

fn rvn_dock_gap(widget: [*c]const rvn_widget_t) f32 {
    return base.rvn_maxf(ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_SPLITTER_SIZE)), 4.0) +
        (if (widget_h.rvn_widget_glass(widget) != 0) @as(f32, 4.0) else @as(f32, 0.0));
}

fn rvn_dock_bar_height(widget: [*c]const rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_CONTROL_HEIGHT)) +
        (if (widget_h.rvn_widget_glass(widget) != 0) @as(f32, 10.0) else @as(f32, 2.0));
}

fn rvn_dock_title(panel: [*c]const rvn_widget_t) [*c]const u8 {
    return if (panel.*.slot.title != null and panel.*.slot.title[0] != 0) panel.*.slot.title else "Panel";
}

// Length of the first part of a split of `length`, the border between the two parts excluded.
fn rvn_dock_first_length(widget: [*c]const rvn_widget_t, split: [*c]const rvn_dock_node_t, length: f32) f32 {
    const room = base.rvn_maxf(0.0, length - rvn_dock_gap(widget));
    const minimum = base.rvn_minf(RVN_DOCK_MIN, room * 0.5);
    return @floor(base.rvn_clampf(room * split.*.ratio, minimum, room - minimum));
}

// Gives every node its rectangle.
fn rvn_dock_layout(widget: [*c]const rvn_widget_t, node: [*c]rvn_dock_node_t, rect: rvn_rect_t) void {
    const gap = rvn_dock_gap(widget);
    node.*.rect = rect;
    if (rvn_dock_is_split(node) == 0) return;
    if (node.*.vertical != 0) {
        const first = rvn_dock_first_length(widget, node, rect.h);
        rvn_dock_layout(widget, node.*.a, base.rvn_rect(rect.x, rect.y, rect.w, first));
        rvn_dock_layout(widget, node.*.b, base.rvn_rect(rect.x, rect.y + first + gap, rect.w, base.rvn_maxf(0.0, rect.h - first - gap)));
    } else {
        const first = rvn_dock_first_length(widget, node, rect.w);
        rvn_dock_layout(widget, node.*.a, base.rvn_rect(rect.x, rect.y, first, rect.h));
        rvn_dock_layout(widget, node.*.b, base.rvn_rect(rect.x + first + gap, rect.y, base.rvn_maxf(0.0, rect.w - first - gap), rect.h));
    }
}

// Where a group is drawn now.
fn rvn_dock_shown(group: [*c]const rvn_dock_node_t) rvn_rect_t {
    if (group.*.placed == 0) return group.*.rect;
    return base.rvn_rect(group.*.x.value, group.*.y.value, base.rvn_maxf(group.*.w.value, 0.0), base.rvn_maxf(group.*.h.value, 0.0));
}

// Moves the rectangle a group is drawn in toward the one the tree gave it.
fn rvn_dock_chase(widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, snap: c_int) void {
    var springs: [4][*c]RSpring = undefined;
    var targets: [4]f32 = undefined;
    springs[0] = &group.*.x;
    springs[1] = &group.*.y;
    springs[2] = &group.*.w;
    springs[3] = &group.*.h;
    targets[0] = group.*.rect.x;
    targets[1] = group.*.rect.y;
    targets[2] = group.*.rect.w;
    targets[3] = group.*.rect.h;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (snap != 0 or group.*.placed == 0) {
            group.*.chasing[i] = raven.R_FALSE;
            if (springs[i].*.started != 0 and springs[i].*.value == targets[i] and springs[i].*.velocity == 0.0) continue;
            widget_h.rvn_widget_forget_layout_spring(widget, springs[i]);
            ext.rvn_spring_set(springs[i], targets[i]);
        } else if (ext.rvn_spring_moving(springs[i], targets[i]) == 0) {
            group.*.chasing[i] = raven.R_FALSE;
        } else if (group.*.chasing[i] == 0 or group.*.goal[i] != targets[i]) {
            // (asked once per target: each request gives the window one more layout pass)
            group.*.chasing[i] = raven.R_TRUE;
            group.*.goal[i] = targets[i];
            widget_h.rvn_widget_animate_layout(widget, springs[i], targets[i], @intCast(raven.R_MOTION_SNAPPY));
        }
    }
    group.*.placed = raven.R_TRUE;
}

const rvn_dock_visit_t = *const fn (widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, context: ?*anyopaque) callconv(.c) void;

fn rvn_dock_each_group(widget: [*c]rvn_widget_t, node: [*c]rvn_dock_node_t, visit: rvn_dock_visit_t, context: ?*anyopaque) void {
    if (node == null) return;
    if (rvn_dock_is_split(node) != 0) {
        rvn_dock_each_group(widget, node.*.a, visit, context);
        rvn_dock_each_group(widget, node.*.b, visit, context);
    } else {
        visit(widget, node, context);
    }
}

fn rvn_dock_group_at(node: [*c]rvn_dock_node_t, x: f32, y: f32) [*c]rvn_dock_node_t {
    if (node == null) return null;
    if (rvn_dock_is_split(node) != 0) {
        const found = rvn_dock_group_at(node.*.a, x, y);
        return if (found != null) found else rvn_dock_group_at(node.*.b, x, y);
    }
    return if (base.rvn_rect_contains(rvn_dock_shown(node), x, y) != 0) node else null;
}

// The border of a split under a point, or NULL.
fn rvn_dock_split_at(widget: [*c]const rvn_widget_t, node: [*c]rvn_dock_node_t, x: f32, y: f32) [*c]rvn_dock_node_t {
    var border: rvn_rect_t = undefined;
    const slack: f32 = 2.0;
    if (node == null or rvn_dock_is_split(node) == 0) return null;
    const gap = rvn_dock_gap(widget);
    if (node.*.vertical != 0) {
        border = base.rvn_rect(node.*.rect.x, node.*.a.*.rect.y + node.*.a.*.rect.h - slack, node.*.rect.w, gap + slack * 2.0);
    } else {
        border = base.rvn_rect(node.*.a.*.rect.x + node.*.a.*.rect.w - slack, node.*.rect.y, gap + slack * 2.0, node.*.rect.h);
    }
    if (base.rvn_rect_contains(border, x, y) != 0) return node;
    const found = rvn_dock_split_at(widget, node.*.a, x, y);
    return if (found != null) found else rvn_dock_split_at(widget, node.*.b, x, y);
}

const RVN_DOCK_ICON_SIZE: f32 = 14.0;
const RVN_DOCK_ICON_GAP: f32 = 6.0;

fn rvn_dock_tab_natural_width(widget: [*c]const rvn_widget_t, panel: [*c]const rvn_widget_t) f32 {
    return common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, rvn_dock_title(panel)) +
        ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_PADDING_X)) * 2.0 + (if (panel.*.slot.dock_fixed != 0) @as(f32, 4.0) else @as(f32, 22.0)) +
        (if (panel.*.slot.has_icon != 0) RVN_DOCK_ICON_SIZE + RVN_DOCK_ICON_GAP else @as(f32, 0.0));
}

// The icon of a panel at (x, centre y), in the color of its title; returns the width it takes.
fn rvn_dock_paint_panel_icon(painter: [*c]draw_h.RPainter, panel: [*c]const rvn_widget_t, x: f32, cy: f32, color: rvn_color_t) f32 {
    if (panel.*.slot.has_icon == 0) return 0.0;
    const tint: rvn_color_t = if (panel.*.slot.icon_tint != 0) color else base.rvn_rgba(1.0, 1.0, 1.0, @as(f32, @floatFromInt(base.rvn_color_a(color))) / 255.0);
    draw_h.rvn_paint_image(painter, base.rvn_rect(x, @floor(cy - RVN_DOCK_ICON_SIZE * 0.5), RVN_DOCK_ICON_SIZE, RVN_DOCK_ICON_SIZE),
        panel.*.slot.icon, &panel.*.slot.icon_uv, tint, 0.0);
    return RVN_DOCK_ICON_SIZE + RVN_DOCK_ICON_GAP;
}

// Where a tab is, in the coordinates of the area, for a group drawn in `shown`.
fn rvn_dock_tab_rect(widget: [*c]const rvn_widget_t, group: [*c]const rvn_dock_node_t, shown: rvn_rect_t, index: c_int) rvn_rect_t {
    const inset: f32 = if (widget_h.rvn_widget_glass(widget) != 0) 8.0 else 0.0;
    const bar = rvn_dock_bar_height(widget);
    const room = base.rvn_maxf(0.0, shown.w - inset * 2.0);
    var total: f32 = 0.0;
    var x: f32 = shown.x + inset;
    var scale: f32 = 1.0;
    var width: f32 = 0.0;
    var i: u32 = 0;
    while (i < group.*.count) : (i += 1) total += rvn_dock_tab_natural_width(widget, group.*.panels[i]);
    // too many tabs for the bar: they all give some of their width
    if (total > room and total > 0.0) scale = room / total;
    i = 0;
    while (i < group.*.count) : (i += 1) {
        width = rvn_dock_tab_natural_width(widget, group.*.panels[i]) * scale;
        if (@as(c_int, @intCast(i)) == index) break;
        x += width;
    }
    if (widget_h.rvn_widget_glass(widget) != 0) return base.rvn_rect(x, shown.y + 6.0, width, bar - 10.0);
    return base.rvn_rect(x, shown.y, width, bar);
}

fn rvn_dock_close_rect(tab: rvn_rect_t) rvn_rect_t {
    return base.rvn_rect(tab.x + tab.w - 20.0, tab.y + @floor((tab.h - 16.0) * 0.5), 16.0, 16.0);
}

// Tab of a group under a point, or -1; *on_close tells whether the point is on its close button.
fn rvn_dock_tab_at(widget: [*c]const rvn_widget_t, group: [*c]const rvn_dock_node_t, x: f32, y: f32, on_close: [*c]c_int) c_int {
    const shown = rvn_dock_shown(group);
    var i: u32 = 0;
    if (on_close != null) on_close.* = raven.R_FALSE;
    if (y < shown.y or y >= shown.y + rvn_dock_bar_height(widget)) return -1;
    while (i < group.*.count) : (i += 1) {
        const tab = rvn_dock_tab_rect(widget, group, shown, @intCast(i));
        if (x < tab.x or x >= tab.x + tab.w) continue;
        if (on_close != null and group.*.panels[i].*.slot.dock_fixed == 0 and tab.w >= 44.0) {
            on_close.* = base.rvn_rect_contains(rvn_dock_close_rect(tab), x, y);
        }
        return @intCast(i);
    }
    return -1;
}

// ---------------------------------------------------------------------------
//  Children
// ---------------------------------------------------------------------------

fn rvn_dock_drop_from_side(side: raven.RDockSide) rvn_dock_drop_t {
    return switch (side) {
        @intCast(raven.R_DOCK_LEFT) => RVN_DOCK_DROP_LEFT,
        @intCast(raven.R_DOCK_RIGHT) => RVN_DOCK_DROP_RIGHT,
        @intCast(raven.R_DOCK_TOP) => RVN_DOCK_DROP_TOP,
        @intCast(raven.R_DOCK_BOTTOM) => RVN_DOCK_DROP_BOTTOM,
        else => RVN_DOCK_DROP_TAB,
    };
}

fn rvn_dock_child_by_name(widget: [*c]const rvn_widget_t, name: [*c]const u8) [*c]rvn_widget_t {
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget.*.children[i].*.name != null and libc.strcmp(widget.*.children[i].*.name, name) == 0) return widget.*.children[i];
    }
    return null;
}

// Docks a child that is not in the tree yet, as its slot says.
fn rvn_dock_place(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const where = rvn_dock_drop_from_side(panel.*.slot.dock);
    var relative: [*c]rvn_widget_t = null;
    var target: [*c]rvn_dock_node_t = null;

    if (area.*.pending_valid != 0) {
        relative = area.*.pending_relative;
    } else if (panel.*.slot.dock_to != null) {
        relative = rvn_dock_child_by_name(widget, panel.*.slot.dock_to);
    }
    if (relative != null and relative != panel) target = rvn_dock_find(area.*.root, relative, null);
    _ = rvn_dock_insert(widget, panel, where, target, panel.*.slot.dock_size, -1);
}

fn rvn_dock_prune(widget: [*c]rvn_widget_t, node: [*c]rvn_dock_node_t) void {
    if (node == null) return;
    if (rvn_dock_is_split(node) != 0) {
        // (removing a panel may free `node`: its children are walked first)
        const a = node.*.a;
        const b = node.*.b;
        rvn_dock_prune(widget, a);
        rvn_dock_prune(widget, b);
        return;
    }
    var i: u32 = node.*.count;
    while (i > 0) : (i -= 1) {
        const panel = node.*.panels[i - 1];
        const last: c_int = @intFromBool(node.*.count == 1);
        if (widget_h.rvn_widget_child_index(widget, panel) >= 0) continue;
        rvn_dock_remove(widget, panel);
        if (last != 0) return;
    }
}

// Brings the tree in line with the children: the ones that left are removed, the new ones are docked.
fn rvn_dock_sync(widget: [*c]rvn_widget_t) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var i: u32 = 0;
    if (area.*.syncing != 0) return;
    rvn_dock_prune(widget, area.*.root);
    rvn_dock_hidden_prune(widget);
    while (i < widget.*.child_count) : (i += 1) {
        widget.*.children[i].*.flags |= widget_h.RVN_WF_CLIP; // a panel cuts what it holds at its edges
        if (rvn_dock_hidden_index(area, widget.*.children[i]) >= 0) continue;
        if (rvn_dock_find(area.*.root, widget.*.children[i], null) == null) rvn_dock_place(widget, widget.*.children[i]);
    }
    if (area.*.press_panel != null and widget_h.rvn_widget_child_index(widget, area.*.press_panel) < 0) {
        area.*.press_panel = null;
        area.*.dragging = raven.R_FALSE;
        area.*.drop = RVN_DOCK_DROP_NONE;
    }
    if (area.*.chip_panel != null and widget_h.rvn_widget_child_index(widget, area.*.chip_panel) < 0) area.*.chip_panel = null;
    if (area.*.middle_panel != null and widget_h.rvn_widget_child_index(widget, area.*.middle_panel) < 0) area.*.middle_panel = null;
    widget_h.rvn_widget_invalidate_layout(widget);
}

fn rvn_dock_changed(widget: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    widget_h.rvn_widget_invalidate_layout(widget);
    if (area.*.changed_callback) |callback| callback(widget.*.id, area.*.changed_user);
}

fn rvn_dock_hidden_index(area: [*c]const rvn_dock_area_t, panel: [*c]const rvn_widget_t) c_int {
    var i: u32 = 0;
    while (i < area.*.hidden_count) : (i += 1) {
        if (area.*.hidden[i].panel == panel) return @intCast(i);
    }
    return -1;
}

fn rvn_dock_hidden_remove(area: [*c]rvn_dock_area_t, index: c_int) void {
    if (index < 0) return;
    area.*.hidden_count -= 1;
    area.*.hidden[@intCast(index)] = area.*.hidden[area.*.hidden_count];
}

// Hidden panels that left the area are forgotten; references to them as places to go back to are cleared.
fn rvn_dock_hidden_prune(widget: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var i: u32 = area.*.hidden_count;
    while (i > 0) : (i -= 1) {
        if (widget_h.rvn_widget_child_index(widget, area.*.hidden[i - 1].panel) < 0) rvn_dock_hidden_remove(area, @as(c_int, @intCast(i)) - 1);
    }
    i = 0;
    while (i < area.*.hidden_count) : (i += 1) {
        if (area.*.hidden[i].relative != null and widget_h.rvn_widget_child_index(widget, area.*.hidden[i].relative) < 0) area.*.hidden[i].relative = null;
    }
}

// Shows a panel of a group.
fn rvn_dock_activate(widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, index: c_int) void {
    if (index < 0 or index >= @as(c_int, @intCast(group.*.count)) or index == group.*.active) return;
    const previous: [*c]rvn_widget_t = if (group.*.active >= 0 and group.*.active < @as(c_int, @intCast(group.*.count)))
        group.*.panels[@intCast(group.*.active)]
    else
        null;
    if (previous != null and widget.*.window != null) widget_h.rvn_window_forget_widget(widget.*.window, previous);
    widget_h.rvn_widget_play_transition(
        group.*.panels[@intCast(index)],
        @intCast(if (index > group.*.active) raven.R_TRANSITION_SLIDE_LEFT else raven.R_TRANSITION_SLIDE_RIGHT),
        0.0,
    );
    group.*.active = index;
    widget_h.rvn_widget_invalidate_layout(widget);
}

// ---------------------------------------------------------------------------
//  Class: lifetime and layout
// ---------------------------------------------------------------------------

fn rvn_dock_area_init(widget: [*c]rvn_widget_t) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.hot_tab = -1;
    area.*.tearable = raven.R_TRUE;
    area.*.home = raven.R_INVALID_ID;
    area.*.float_window = raven.R_INVALID_ID;
    area.*.drop_area = raven.R_INVALID_ID;
}

fn rvn_dock_area_destroy(widget: [*c]rvn_widget_t) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    rvn_dock_tree_free(widget, area.*.root);
    area.*.root = null;
    base.rvn_free(area.*.layout_text);
    base.rvn_free(area.*.hidden);
    // the floating windows of a home area that goes away go with it
    {
        var i: u32 = 0;
        while (i < area.*.float_count) : (i += 1) {
            const floating = widget_h.rvn_widget_get(area.*.floats[i]);
            if (floating != null and floating.*.cls == &rvn_class_dock_area) {
                const other: [*c]rvn_dock_area_t = @ptrCast(floating);
                const window = other.*.float_window;
                other.*.home = raven.R_INVALID_ID;
                if (raven.Rwindow_is_valid(window) != 0) raven.Rwindow_destroy(window);
            }
        }
    }
    base.rvn_free(area.*.floats);
    base.rvn_free(area.*.returns);
}

fn rvn_dock_measure_node(widget: [*c]rvn_widget_t, node: [*c]rvn_dock_node_t) rvn_vec2_t {
    const gap = rvn_dock_gap(widget);
    if (rvn_dock_is_split(node) == 0) {
        // every panel is measured: its own layout must be ready when its tab is chosen.
        // But the area does not grow with them: a panel gets the room of its cell and
        // what does not fit is cut (the area asks only for its minimum, so it never
        // pushes out of the window).
        var i: u32 = 0;
        while (i < node.*.count) : (i += 1) _ = widget_h.rvn_widget_measure_slot(node.*.panels[i]);
        return base.rvn_vec2(RVN_DOCK_MIN, RVN_DOCK_MIN + rvn_dock_bar_height(widget));
    }
    const a = rvn_dock_measure_node(widget, node.*.a);
    const b = rvn_dock_measure_node(widget, node.*.b);
    if (node.*.vertical != 0) return base.rvn_vec2(base.rvn_maxf(a.x, b.x), a.y + b.y + gap);
    return base.rvn_vec2(a.x + b.x + gap, base.rvn_maxf(a.y, b.y));
}

fn rvn_dock_area_measure(widget: [*c]rvn_widget_t) callconv(.c) rvn_vec2_t {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    if (area.*.root == null) return base.rvn_vec2(RVN_DOCK_MIN, RVN_DOCK_MIN);
    return rvn_dock_measure_node(widget, area.*.root);
}

fn rvn_dock_arrange_group(widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, context: ?*anyopaque) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const bar = rvn_dock_bar_height(widget);
    const pad: f32 = if (widget_h.rvn_widget_glass(widget) != 0) 6.0 else 1.0;
    _ = context;
    rvn_dock_chase(widget, group, area.*.snap);
    const shown = rvn_dock_shown(group);
    const content = base.rvn_rect(shown.x + pad, shown.y + bar, base.rvn_maxf(0.0, shown.w - pad * 2.0), base.rvn_maxf(0.0, shown.h - bar - pad));
    var i: u32 = 0;
    while (i < group.*.count) : (i += 1) {
        const panel = group.*.panels[i];
        if (widget_h.rvn_widget_collapsed(panel) != 0) continue;
        widget_h.rvn_widget_arrange_slot(panel, content);
        // a panel never goes out of its cell (a fixed size, a minimum bigger than the room):
        // it is put back inside, and what it holds is cut at its edges (RVN_WF_CLIP)
        {
            const r = panel.*.rect;
            const x0 = base.rvn_maxf(r.x, content.x);
            const y0 = base.rvn_maxf(r.y, content.y);
            const x1 = base.rvn_minf(r.x + r.w, content.x + content.w);
            const y1 = base.rvn_minf(r.y + r.h, content.y + content.h);
            if (x0 != r.x or y0 != r.y or x1 != r.x + r.w or y1 != r.y + r.h)
                widget_h.rvn_widget_arrange(panel, x0, y0, base.rvn_maxf(0.0, x1 - x0), base.rvn_maxf(0.0, y1 - y0));
        }
        panel.*.flags |= widget_h.RVN_WF_CLIP;
    }
}

fn rvn_dock_area_arrange(widget: [*c]rvn_widget_t) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    if (area.*.root == null) return;
    // the area itself changed size: the groups follow at once
    if (area.*.last_w != widget.*.rect.w or area.*.last_h != widget.*.rect.h) area.*.snap = raven.R_TRUE;
    area.*.last_w = widget.*.rect.w;
    area.*.last_h = widget.*.rect.h;
    rvn_dock_layout(widget, area.*.root, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
    rvn_dock_each_group(widget, area.*.root, rvn_dock_arrange_group, null);
    area.*.snap = raven.R_FALSE;
}

fn rvn_dock_area_child_active(widget: [*c]rvn_widget_t, child: [*c]rvn_widget_t) callconv(.c) c_int {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var index: c_int = 0;
    const group = rvn_dock_find(area.*.root, child, &index);
    return @intFromBool(group != null and group.*.active == index);
}

// ---------------------------------------------------------------------------
//  Dragging a panel
// ---------------------------------------------------------------------------

// Where `panel` would go if it were dropped at (x, y) in the area. The panel
// may be one of this area (a tab dragged here) or of another area of the
// family (a tab dragged from another window: `source` is then NULL).
fn rvn_dock_compute_drop(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t, x: f32, y: f32) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const bar = rvn_dock_bar_height(widget);
    const source = rvn_dock_find(area.*.root, panel, null);
    const old = area.*.drop_rect;
    const previous = area.*.drop;
    const alone: c_int = @intFromBool(source != null and source.*.count == 1);

    area.*.drop = RVN_DOCK_DROP_NONE;
    area.*.drop_node = null;
    area.*.drop_index = -1;
    if (x < 0.0 or y < 0.0 or x >= widget.*.rect.w or y >= widget.*.rect.h) return;
    done: {
        // an empty area takes the panel as its first one
        if (area.*.root == null) {
            if (source != null) return;
            area.*.drop = RVN_DOCK_DROP_TAB;
            area.*.drop_rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
            break :done;
        }

        // along the edges of the area: against everything else
        if (rvn_dock_is_split(area.*.root) != 0) {
            const all = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
            if (x < RVN_DOCK_EDGE) {
                area.*.drop = RVN_DOCK_DROP_LEFT;
                area.*.drop_rect = base.rvn_rect(0.0, 0.0, all.w * 0.25, all.h);
            } else if (x >= all.w - RVN_DOCK_EDGE) {
                area.*.drop = RVN_DOCK_DROP_RIGHT;
                area.*.drop_rect = base.rvn_rect(all.w * 0.75, 0.0, all.w * 0.25, all.h);
            } else if (y >= all.h - RVN_DOCK_EDGE) {
                area.*.drop = RVN_DOCK_DROP_BOTTOM;
                area.*.drop_rect = base.rvn_rect(0.0, all.h * 0.75, all.w, all.h * 0.25);
            }
            if (area.*.drop != RVN_DOCK_DROP_NONE) break :done;
        }

        const group = rvn_dock_group_at(area.*.root, x, y);
        if (group == null) return;
        const shown = rvn_dock_shown(group);
        if (y < shown.y + bar) {
            // on the bar of tabs: a place among them
            var index: c_int = @intCast(group.*.count);
            var i: u32 = 0;
            while (i < group.*.count) : (i += 1) {
                const tab = rvn_dock_tab_rect(widget, group, shown, @intCast(i));
                if (x < tab.x + tab.w * 0.5) {
                    index = @intCast(i);
                    break;
                }
            }
            if (group == source) {
                var own: c_int = 0;
                _ = rvn_dock_find(group, panel, &own);
                // next to itself: nothing would move
                if (index == own or index == own + 1) return;
            }
            area.*.drop = RVN_DOCK_DROP_TAB;
            area.*.drop_node = group;
            area.*.drop_index = index;
            {
                const width = base.rvn_minf(rvn_dock_tab_natural_width(widget, panel), shown.w * 0.5);
                const at: f32 = if (index < @as(c_int, @intCast(group.*.count)))
                    rvn_dock_tab_rect(widget, group, shown, index).x
                else if (group.*.count != 0)
                    rvn_dock_tab_rect(widget, group, shown, @as(c_int, @intCast(group.*.count)) - 1).x +
                        rvn_dock_tab_rect(widget, group, shown, @as(c_int, @intCast(group.*.count)) - 1).w
                else
                    shown.x;
                area.*.drop_rect = base.rvn_rect(
                    base.rvn_clampf(at - width * 0.5, shown.x, base.rvn_maxf(shown.x, shown.x + shown.w - width)),
                    shown.y + 2.0,
                    width,
                    bar - 4.0,
                );
            }
        } else {
            const fx: f32 = if (shown.w > 0.0) (x - shown.x) / shown.w else 0.5;
            const fy: f32 = if (shown.h > bar) (y - shown.y - bar) / (shown.h - bar) else 0.5;
            const nearest = base.rvn_minf(base.rvn_minf(fx, 1.0 - fx), base.rvn_minf(fy, 1.0 - fy));
            if (nearest > 0.27) {
                if (group == source) return;
                area.*.drop = RVN_DOCK_DROP_TAB;
                area.*.drop_rect = shown;
            } else {
                // a panel alone in its group cannot be put beside itself
                if (group == source and alone != 0) return;
                if (nearest == fx) {
                    area.*.drop = RVN_DOCK_DROP_LEFT;
                    area.*.drop_rect = base.rvn_rect(shown.x, shown.y, shown.w * 0.5, shown.h);
                } else if (nearest == 1.0 - fx) {
                    area.*.drop = RVN_DOCK_DROP_RIGHT;
                    area.*.drop_rect = base.rvn_rect(shown.x + shown.w * 0.5, shown.y, shown.w * 0.5, shown.h);
                } else if (nearest == fy) {
                    area.*.drop = RVN_DOCK_DROP_TOP;
                    area.*.drop_rect = base.rvn_rect(shown.x, shown.y, shown.w, shown.h * 0.5);
                } else {
                    area.*.drop = RVN_DOCK_DROP_BOTTOM;
                    area.*.drop_rect = base.rvn_rect(shown.x, shown.y + shown.h * 0.5, shown.w, shown.h * 0.5);
                }
            }
            area.*.drop_node = group;
        }
    }

    // done: the preview appears where it is needed, then glides from place to place
    if (previous == RVN_DOCK_DROP_NONE and area.*.preview_shown.value < 0.05) {
        ext.rvn_spring_set(&area.*.preview_x, area.*.drop_rect.x + area.*.drop_rect.w * 0.5);
        ext.rvn_spring_set(&area.*.preview_y, area.*.drop_rect.y + area.*.drop_rect.h * 0.5);
        ext.rvn_spring_set(&area.*.preview_w, area.*.drop_rect.w * 0.6);
        ext.rvn_spring_set(&area.*.preview_h, area.*.drop_rect.h * 0.6);
    }
    _ = old;
}

// Moves a panel: out of its group, and into the tree where `where` says.
fn rvn_dock_move(
    widget: [*c]rvn_widget_t,
    panel: [*c]rvn_widget_t,
    where: rvn_dock_drop_t,
    target_in: [*c]rvn_dock_node_t,
    size: f32,
    index_in: c_int,
    from: [*c]const rvn_rect_t,
) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var own: c_int = 0;
    const source = rvn_dock_find(area.*.root, panel, &own);
    var target = target_in;
    var index = index_in;
    var anchor: [*c]rvn_widget_t = null;

    if (source == null or where == RVN_DOCK_DROP_NONE) return;
    if (target == source) {
        if (where == RVN_DOCK_DROP_TAB) {
            // another place in the same bar
            if (index < 0) index = @intCast(source.*.count);
            if (index > own) index -= 1;
        } else if (source.*.count == 1) {
            return;
        }
    }
    // (the group of the panel may disappear, and its neighbours move up in the tree: the target is found again)
    if (target != null and rvn_dock_is_split(target) == 0 and target != source) {
        anchor = target.*.panels[0];
    } else if (target == source and source.*.count > 1) {
        anchor = source.*.panels[if (own == 0) 1 else 0];
    }
    rvn_dock_remove(widget, panel);
    target = if (anchor != null) rvn_dock_find(area.*.root, anchor, null) else null;
    const group = rvn_dock_insert(widget, panel, where, target, size, index);
    if (from != null and group.*.count == 1) {
        // a new group grows from where the preview of the drop was
        ext.rvn_spring_set(&group.*.x, from.*.x);
        ext.rvn_spring_set(&group.*.y, from.*.y);
        ext.rvn_spring_set(&group.*.w, from.*.w);
        ext.rvn_spring_set(&group.*.h, from.*.h);
        group.*.placed = raven.R_TRUE;
    }
    if (widget.*.window != null) widget_h.rvn_window_forget_widget(widget.*.window, panel);
    rvn_dock_changed(widget);
}

fn rvn_dock_close(widget: [*c]rvn_widget_t, panel_in: [*c]rvn_widget_t, ask: c_int) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const id = widget.*.id;
    const panel_id = panel_in.*.id;
    if (ask != 0) {
        if (area.*.close_callback) |callback| {
            if (callback(id, panel_id, area.*.close_user) == 0) return;
        }
    }
    // (the callback may have deleted anything)
    if (widget_h.rvn_widget_get(id) == null) return;
    const panel = widget_h.rvn_widget_get(panel_id);
    if (ask != 0 and area.*.close_hides != 0 and panel != null and panel.*.parent == widget) {
        const home = rvn_dock_area_of(area.*.home);
        if (home != null) {
            // a floating panel that hides goes back home, hidden: opening it shows it where it was
            _ = rvn_dock_return(widget, panel);
            rvn_dock_hide(&home.*.base, panel);
            return;
        }
        rvn_dock_hide(widget, panel);
        return;
    }
    if (panel != null and panel.*.parent == widget) widget_h.rvn_widget_destroy(panel);
    rvn_dock_changed(widget);
    // the last panel of a floating window is gone: the window goes too
    rvn_dock_float_close_if_empty(widget);
}

// Takes a panel out of the tree, keeping it as a child, and notes where it was.
fn rvn_dock_hide(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var entry: rvn_dock_hidden_t = undefined;
    if (rvn_dock_find(area.*.root, panel, null) == null or rvn_dock_hidden_index(area, panel) >= 0) return;
    rvn_dock_where(widget, panel, &entry);
    if (area.*.press_panel == panel) rvn_dock_end_press(widget);
    if (area.*.chip_panel == panel) area.*.chip_panel = null;
    base.RVN_ARRAY_RESERVE(&area.*.hidden, &area.*.hidden_cap, area.*.hidden_count + 1);
    area.*.hidden[area.*.hidden_count] = entry;
    area.*.hidden_count += 1;
    rvn_dock_remove(widget, panel);
    if (widget.*.window != null) widget_h.rvn_window_forget_widget(widget.*.window, panel);
    rvn_dock_changed(widget);
}

// Puts a hidden panel back where it was, and shows its tab.
fn rvn_dock_open(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const hidden = rvn_dock_hidden_index(area, panel);
    var index: c_int = 0;
    if (hidden >= 0) {
        const entry = area.*.hidden[@intCast(hidden)];
        var target: [*c]rvn_dock_node_t = null;
        rvn_dock_hidden_remove(area, hidden);
        if (entry.relative != null and rvn_dock_hidden_index(area, entry.relative) < 0) target = rvn_dock_find(area.*.root, entry.relative, null);
        if (target == null and entry.where == RVN_DOCK_DROP_TAB) {
            // what it was against is gone: where its slot says
            rvn_dock_place(widget, panel);
        } else {
            _ = rvn_dock_insert(widget, panel, entry.where, target, entry.size, -1);
        }
        widget_h.rvn_widget_play_transition(panel, @intCast(raven.R_TRANSITION_FADE), 0.0);
    }
    const group = rvn_dock_find(area.*.root, panel, &index);
    if (group != null) rvn_dock_activate(widget, group, index);
    rvn_dock_changed(widget);
}

// ---------------------------------------------------------------------------
//  Tearing: panels in windows of their own
// ---------------------------------------------------------------------------

fn rvn_dock_area_of(id: Rid) [*c]rvn_dock_area_t {
    const widget: [*c]rvn_widget_t = if (id != raven.R_INVALID_ID) widget_h.rvn_widget_get(id) else null;
    if (widget != null and widget.*.cls == &rvn_class_dock_area) {
        const area: [*c]rvn_dock_area_t = @ptrCast(widget);
        return area;
    }
    return null;
}

// The home of the family of an area: itself, unless it is floating.
fn rvn_dock_home_of(widget: [*c]rvn_widget_t) [*c]rvn_widget_t {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const home = rvn_dock_area_of(area.*.home);
    if (home != null) return @ptrCast(&home.*.base);
    return widget;
}

// The areas of a family, the floating ones first (they are usually above the home window).
fn rvn_dock_family(widget: [*c]rvn_widget_t, out: [*c][*c]rvn_widget_t, max: c_int) c_int {
    const home = rvn_dock_home_of(widget);
    const h: [*c]rvn_dock_area_t = @ptrCast(home);
    var count: c_int = 0;
    var i: u32 = 0;
    while (i < h.*.float_count and count < max - 1) : (i += 1) {
        const floating = rvn_dock_area_of(h.*.floats[i]);
        if (floating != null) {
            out[@intCast(count)] = @ptrCast(&floating.*.base);
            count += 1;
        }
    }
    out[@intCast(count)] = home;
    count += 1;
    return count;
}

// A point of the area, on the screen (logical units, as Rwindow_get_position).
fn rvn_dock_to_screen(widget: [*c]rvn_widget_t, x: f32, y: f32, sx: [*c]f32, sy: [*c]f32) c_int {
    var wx: c_int = 0;
    var wy: c_int = 0;
    if (widget.*.window == null or widget.*.window.*.dead != 0) return raven.R_FALSE;
    raven.Rwindow_get_position(widget.*.window.*.id, &wx, &wy);
    const origin = widget_h.rvn_widget_origin(widget);
    sx.* = @as(f32, @floatFromInt(wx)) + origin.x + x;
    sy.* = @as(f32, @floatFromInt(wy)) + origin.y + y;
    return raven.R_TRUE;
}

// The area of the family (other than `except`) under a point of the screen, and the point in it.
fn rvn_dock_area_under(widget: [*c]rvn_widget_t, except: [*c]rvn_widget_t, sx: f32, sy: f32, lx: [*c]f32, ly: [*c]f32) [*c]rvn_widget_t {
    var family: [32][*c]rvn_widget_t = undefined;
    const count = rvn_dock_family(widget, &family[0], 32);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        var ox: f32 = 0.0;
        var oy: f32 = 0.0;
        const fam = family[@intCast(i)];
        if (fam == except or widget_h.rvn_widget_is_shown(fam) == 0) continue;
        if (rvn_dock_to_screen(fam, 0.0, 0.0, &ox, &oy) == 0) continue;
        if (sx >= ox and sy >= oy and sx < ox + fam.*.rect.w and sy < oy + fam.*.rect.h) {
            lx.* = sx - ox;
            ly.* = sy - oy;
            return fam;
        }
    }
    return null;
}

// The previews other areas of the family show for a tab dragged from `widget` go away (except in `keep`).
fn rvn_dock_clear_foreign(widget: [*c]rvn_widget_t, keep: [*c]rvn_widget_t) void {
    var family: [32][*c]rvn_widget_t = undefined;
    const count = rvn_dock_family(widget, &family[0], 32);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const other: [*c]rvn_dock_area_t = @ptrCast(family[@intCast(i)]);
        if (family[@intCast(i)] == widget or family[@intCast(i)] == keep or other.*.foreign_panel == null) continue;
        other.*.foreign_panel = null;
        other.*.drop = RVN_DOCK_DROP_NONE;
        other.*.drop_node = null;
        widget_h.rvn_widget_invalidate_paint(family[@intCast(i)]);
    }
}

// Where the dragged panel would go: here, in another window of the family, or in a window of its own.
fn rvn_dock_update_drop(widget: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const x = area.*.pointer_x;
    const y = area.*.pointer_y;
    var sx: f32 = 0.0;
    var sy: f32 = 0.0;
    var lx: f32 = 0.0;
    var ly: f32 = 0.0;
    const inside = x >= 0.0 and y >= 0.0 and x < widget.*.rect.w and y < widget.*.rect.h;
    const outside = x < -RVN_DOCK_TEAR or y < -RVN_DOCK_TEAR or x >= widget.*.rect.w + RVN_DOCK_TEAR or y >= widget.*.rect.h + RVN_DOCK_TEAR;
    var other: [*c]rvn_widget_t = null;

    area.*.drop_area = raven.R_INVALID_ID;
    if (area.*.tearable != 0 and rvn_dock_to_screen(widget, x, y, &sx, &sy) != 0) {
        // a floating window over the home window; from a floating window, what is under it once out of it
        if (area.*.home == raven.R_INVALID_ID or !inside or area.*.moving_window != 0) other = rvn_dock_area_under(widget, widget, sx, sy, &lx, &ly);
    }
    if (other != null) {
        const target: [*c]rvn_dock_area_t = @ptrCast(other);
        target.*.foreign_panel = area.*.press_panel;
        target.*.pointer_x = lx;
        target.*.pointer_y = ly;
        rvn_dock_compute_drop(other, area.*.press_panel, lx, ly);
        widget_h.rvn_widget_invalidate_paint(other);
        rvn_dock_clear_foreign(widget, other);
        if (target.*.drop != RVN_DOCK_DROP_NONE) {
            area.*.drop = RVN_DOCK_DROP_ELSEWHERE;
            area.*.drop_area = other.*.id;
            return;
        }
    } else {
        rvn_dock_clear_foreign(widget, null);
    }
    if (area.*.moving_window != 0) {
        area.*.drop = RVN_DOCK_DROP_NONE;
        return;
    }
    if (area.*.tearable != 0 and outside) {
        area.*.drop = RVN_DOCK_DROP_FLOAT;
        area.*.drop_node = null;
        return;
    }
    rvn_dock_compute_drop(widget, area.*.press_panel, x, y);
}

// Where a panel of the tree would go back if it left (beside what it shares its place with).
fn rvn_dock_where(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t, entry: [*c]rvn_dock_hidden_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var index: c_int = 0;
    const group = rvn_dock_find(area.*.root, panel, &index);
    entry.* = std.mem.zeroes(rvn_dock_hidden_t);
    entry.*.panel = panel;
    entry.*.where = RVN_DOCK_DROP_TAB;
    if (group == null) return;
    if (group.*.count > 1) {
        // it shared its tabs: it comes back behind them
        entry.*.relative = group.*.panels[if (index == 0) 1 else 0];
    } else if (group.*.parent != null) {
        const split = group.*.parent;
        const other = if (split.*.a == group) split.*.b else split.*.a;
        const first = rvn_dock_first_group(other);
        const first_side = split.*.a == group;
        entry.*.relative = if (first != null and first.*.count > 0) first.*.panels[0] else null;
        entry.*.where = if (split.*.vertical != 0)
            (if (first_side) RVN_DOCK_DROP_TOP else RVN_DOCK_DROP_BOTTOM)
        else
            (if (first_side) RVN_DOCK_DROP_LEFT else RVN_DOCK_DROP_RIGHT);
        entry.*.size = if (first_side) split.*.ratio else 1.0 - split.*.ratio;
        // the sibling was a whole subtree: going back against the whole of it would need the subtree; the area is close enough
        if (rvn_dock_is_split(other) != 0 and split.*.parent == null) entry.*.relative = null;
    }
}

fn rvn_dock_return_index(area: [*c]const rvn_dock_area_t, panel: [*c]const rvn_widget_t) c_int {
    var i: u32 = 0;
    while (i < area.*.return_count) : (i += 1) {
        if (area.*.returns[i].panel == panel) return @intCast(i);
    }
    return -1;
}

// Takes the place a panel of a floating area goes back to (a tab of the home area when none was kept).
fn rvn_dock_take_return(area: [*c]rvn_dock_area_t, panel: [*c]rvn_widget_t, entry: [*c]rvn_dock_hidden_t) void {
    const index = rvn_dock_return_index(area, panel);
    if (index >= 0) {
        const at: usize = @intCast(index);
        entry.* = area.*.returns[at];
        area.*.return_count -= 1;
        area.*.returns[at] = area.*.returns[area.*.return_count];
    } else {
        entry.* = std.mem.zeroes(rvn_dock_hidden_t);
        entry.*.where = RVN_DOCK_DROP_TAB;
    }
    entry.*.panel = panel;
}

fn rvn_dock_forget_float(home_widget: [*c]rvn_widget_t, floating: Rid) void {
    const home: [*c]rvn_dock_area_t = @ptrCast(home_widget);
    var i: u32 = 0;
    while (i < home.*.float_count) : (i += 1) {
        if (home.*.floats[i] == floating) {
            home.*.float_count -= 1;
            home.*.floats[i] = home.*.floats[home.*.float_count];
            return;
        }
    }
}

// A floating area that has no panel left: its window closes (the last thing done with it).
fn rvn_dock_float_close_if_empty(widget: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const home = rvn_dock_home_of(widget);
    const window = area.*.float_window;
    if (home == widget or widget.*.child_count > 0 or area.*.closing != 0) return;
    rvn_dock_forget_float(home, widget.*.id);
    area.*.home = raven.R_INVALID_ID;
    if (raven.Rwindow_is_valid(window) != 0) raven.Rwindow_destroy(window);
}

// Puts a panel of the home area where an entry says (the way Rdock_area_open_panel puts back a hidden one).
fn rvn_dock_put_back(home: [*c]rvn_widget_t, panel: [*c]rvn_widget_t, entry: [*c]const rvn_dock_hidden_t) void {
    const h: [*c]rvn_dock_area_t = @ptrCast(home);
    const target = if (entry.*.relative != null) rvn_dock_find(h.*.root, entry.*.relative, null) else null;
    var index: c_int = 0;
    if (target == null and entry.*.where == RVN_DOCK_DROP_TAB) {
        rvn_dock_place(home, panel);
    } else {
        _ = rvn_dock_insert(home, panel, entry.*.where, target, entry.*.size, -1);
    }
    const group = rvn_dock_find(h.*.root, panel, &index);
    if (group != null) rvn_dock_activate(home, group, index);
    widget_h.rvn_widget_play_transition(panel, @intCast(raven.R_TRANSITION_FADE), 0.0);
}

// A panel of a floating area goes back to its home area, where it was.
fn rvn_dock_return(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t) c_int {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const home = rvn_dock_area_of(area.*.home);
    var entry: rvn_dock_hidden_t = undefined;
    if (home == null or panel.*.parent != widget) return raven.R_FALSE;
    rvn_dock_take_return(area, panel, &entry);
    if (area.*.press_panel == panel) rvn_dock_end_press(widget);
    if (area.*.chip_panel == panel) area.*.chip_panel = null;
    rvn_dock_remove(widget, panel);
    home.*.syncing = raven.R_TRUE;
    widget_h.rvn_widget_add_child(&home.*.base, panel, -1);
    home.*.syncing = raven.R_FALSE;
    rvn_dock_put_back(&home.*.base, panel, &entry);
    rvn_dock_changed(&home.*.base);
    rvn_dock_changed(widget);
    rvn_dock_float_close_if_empty(widget);
    return raven.R_TRUE;
}

// A panel leaves for a window of its own, whose top left corner is at
// (x, y) on the screen. Returns the window.
fn rvn_dock_tear(widget: [*c]rvn_widget_t, panel: [*c]rvn_widget_t, x: f32, y: f32) Rid {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const home = rvn_dock_home_of(widget);
    const h: [*c]rvn_dock_area_t = @ptrCast(home);
    const group = rvn_dock_find(area.*.root, panel, null);
    const shown = if (group != null) rvn_dock_shown(group) else base.rvn_rect(0.0, 0.0, 480.0, 360.0);
    var entry: rvn_dock_hidden_t = undefined;
    var floating: [*c]rvn_dock_area_t = undefined;
    var window: Rid = undefined;
    var floating_id: Rid = undefined;

    if (panel.*.parent != widget) return raven.R_INVALID_ID;
    // where it will go back
    if (home == widget) rvn_dock_where(widget, panel, &entry) else rvn_dock_take_return(area, panel, &entry);

    window = raven.Rwindow_create(
        rvn_dock_title(panel),
        @intFromFloat(base.rvn_clampf(shown.w, 260.0, 1600.0)),
        @intFromFloat(base.rvn_clampf(shown.h, 180.0, 1200.0)),
        @intCast(raven.R_WINDOW_DEFAULT),
    );
    if (window == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    raven.Rwindow_set_position(window, @intFromFloat(x), @intFromFloat(y));
    floating_id = raven.Rwidget_create(@intCast(raven.R_WIDGET_DOCK_AREA));
    floating = rvn_dock_area_of(floating_id);
    if (floating == null) {
        raven.Rwindow_destroy(window);
        return raven.R_INVALID_ID;
    }
    floating.*.home = home.*.id;
    floating.*.float_window = window;
    floating.*.tearable = h.*.tearable;
    floating.*.locked = h.*.locked;
    floating.*.close_hides = h.*.close_hides;
    floating.*.close_callback = h.*.close_callback;
    floating.*.close_user = h.*.close_user;
    raven.Rwindow_set_content(window, floating_id);
    raven.Rwindow_set_close_callback(window, rvn_dock_float_closing, @ptrFromInt(@as(usize, floating_id)));

    if (area.*.press_panel == panel) rvn_dock_end_press(widget);
    if (area.*.chip_panel == panel) area.*.chip_panel = null;
    rvn_dock_remove(widget, panel);
    base.RVN_ARRAY_RESERVE(&floating.*.returns, &floating.*.return_cap, floating.*.return_count + 1);
    entry.panel = panel;
    floating.*.returns[floating.*.return_count] = entry;
    floating.*.return_count += 1;
    // (it becomes the first tab of the new area)
    panel.*.slot.dock_to = null;
    widget_h.rvn_widget_add_child(&floating.*.base, panel, -1);
    base.RVN_ARRAY_RESERVE(&h.*.floats, &h.*.float_cap, h.*.float_count + 1);
    h.*.floats[h.*.float_count] = floating_id;
    h.*.float_count += 1;
    rvn_dock_changed(widget);
    if (home != widget) rvn_dock_float_close_if_empty(widget);
    return window;
}

// A tab dropped on another area of the family: its panel moves there.
fn rvn_dock_transfer(
    from: [*c]rvn_widget_t,
    to: [*c]rvn_widget_t,
    panel: [*c]rvn_widget_t,
    where: rvn_dock_drop_t,
    target_in: [*c]rvn_dock_node_t,
    index: c_int,
    rect: [*c]const rvn_rect_t,
) void {
    const src: [*c]rvn_dock_area_t = @ptrCast(from);
    const dst: [*c]rvn_dock_area_t = @ptrCast(to);
    const home = rvn_dock_home_of(from);
    var target = target_in;
    const anchor: [*c]rvn_widget_t = if (target != null and rvn_dock_is_split(target) == 0 and target.*.count != 0) target.*.panels[0] else null;
    var entry: rvn_dock_hidden_t = undefined;
    var keep_entry: c_int = raven.R_FALSE;
    var group: [*c]rvn_dock_node_t = undefined;

    if (panel.*.parent != from) return;
    // where it goes back to: carried from floating window to floating window, taken when it leaves home
    if (from != home) {
        rvn_dock_take_return(src, panel, &entry);
        keep_entry = @intFromBool(to != home);
    } else if (to != home) {
        rvn_dock_where(from, panel, &entry);
        keep_entry = raven.R_TRUE;
    }
    if (src.*.chip_panel == panel) src.*.chip_panel = null;
    rvn_dock_remove(from, panel);
    dst.*.syncing = raven.R_TRUE;
    widget_h.rvn_widget_add_child(to, panel, -1);
    dst.*.syncing = raven.R_FALSE;
    target = if (anchor != null) rvn_dock_find(dst.*.root, anchor, null) else null;
    group = rvn_dock_insert(to, panel, where, target, 0.0, index);
    if (group != null and rect != null and group.*.count == 1) {
        ext.rvn_spring_set(&group.*.x, rect.*.x);
        ext.rvn_spring_set(&group.*.y, rect.*.y);
        ext.rvn_spring_set(&group.*.w, rect.*.w);
        ext.rvn_spring_set(&group.*.h, rect.*.h);
        group.*.placed = raven.R_TRUE;
    }
    if (keep_entry != 0) {
        entry.panel = panel;
        base.RVN_ARRAY_RESERVE(&dst.*.returns, &dst.*.return_cap, dst.*.return_count + 1);
        dst.*.returns[dst.*.return_count] = entry;
        dst.*.return_count += 1;
    }
    if (to.*.window != null) widget_h.rvn_window_forget_widget(to.*.window, panel);
    rvn_dock_changed(to);
    rvn_dock_changed(from);
    if (from != home) rvn_dock_float_close_if_empty(from);
}

// The window of a floating area is closed: its panels go back home first.
fn rvn_dock_float_closing(window: Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    const id: Rid = @truncate(@intFromPtr(user_data));
    var area = rvn_dock_area_of(id);
    _ = window;
    if (area == null) return raven.R_TRUE;
    // (the window closes by itself: the area must not close it a second time)
    area.*.closing = raven.R_TRUE;
    while (true) {
        area = rvn_dock_area_of(id);
        if (!(area != null and area.*.base.child_count > 0 and rvn_dock_area_of(area.*.home) != null)) break;
        _ = rvn_dock_return(&area.*.base, area.*.base.children[0]);
    }
    area = rvn_dock_area_of(id);
    if (area != null and rvn_dock_area_of(area.*.home) != null) {
        const home_widget: [*c]rvn_widget_t = @ptrCast(&rvn_dock_area_of(area.*.home).*.base);
        rvn_dock_forget_float(home_widget, id);
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Paint
// ---------------------------------------------------------------------------

fn rvn_dock_paint_group(widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, context: ?*anyopaque) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const painter: [*c]draw_h.RPainter = @ptrCast(@alignCast(context));
    const shown = rvn_dock_shown(group);
    const bar = rvn_dock_bar_height(widget);
    const font = common.rvn_widget_font_size(widget, 0.0);
    const text = widget_h.rvn_widget_text_color(widget, @ptrCast(painter));
    var active = base.rvn_rect(shown.x, shown.y, 0.0, bar);
    var mark_x: f32 = undefined;
    var mark_w: f32 = undefined;
    var stretch: f32 = undefined;
    var i: u32 = 0;

    if (shown.w < 2.0 or shown.h < 2.0) return;
    if (group.*.active >= 0 and group.*.active < @as(c_int, @intCast(group.*.count))) active = rvn_dock_tab_rect(widget, group, shown, group.*.active);

    // the mark of the shown tab is kept relative to the group, which may be moving
    mark_x = shown.x + draw_h.rvn_paint_spring(painter, &group.*.mark_x, active.x - shown.x, @intCast(raven.R_MOTION_BOUNCY));
    mark_w = draw_h.rvn_paint_spring(painter, &group.*.mark_w, active.w, @intCast(raven.R_MOTION_BOUNCY));
    stretch = base.rvn_minf(@abs(group.*.mark_x.velocity) * 0.018, mark_w * 0.35);
    mark_x -= stretch * 0.5;
    mark_w += stretch;

    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(@ptrCast(painter), widget, shown, 18.0, @intCast(common.RVN_SURFACE_PANEL), 0.0, 0.0);
        if (mark_w > 6.0) {
            const pill = base.rvn_rect(mark_x + 2.0, active.y, mark_w - 4.0, active.h);
            common.rvn_paint_surface(@ptrCast(painter), widget, pill, pill.h * 0.5, @intCast(common.RVN_SURFACE_CONTROL), 1.0, 0.6);
        }
    } else {
        const radius = ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_CORNER_RADIUS));
        var radii: [4]f32 = undefined;
        radii[0] = radius;
        radii[1] = radius;
        radii[2] = 0.0;
        radii[3] = 0.0;
        draw_h.rvn_paint_box(painter, shown, radius, widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_PANEL)),
            ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_BORDER_WIDTH)), widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_BORDER)));
        draw_h.rvn_paint_box4(painter, base.rvn_rect(shown.x + 1.0, shown.y + 1.0, shown.w - 2.0, bar - 1.0), &radii,
            widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_HEADER)), 0.0, 0);
        draw_h.rvn_paint_rect(painter, base.rvn_rect(shown.x + 1.0, shown.y + bar - 1.0, shown.w - 2.0, 1.0), widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_SEPARATOR)));
        if (mark_w > 0.0) {
            draw_h.rvn_paint_rect(painter, base.rvn_rect(mark_x, shown.y + 1.0, mark_w, bar - 1.0), widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_TAB_ACTIVE)));
            draw_h.rvn_paint_rect(painter, base.rvn_rect(mark_x, shown.y + 1.0, mark_w, 2.0), widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_ACCENT)));
        }
    }

    draw_h.rvn_paint_push_clip(painter, base.rvn_rect(shown.x + 1.0, shown.y, shown.w - 2.0, bar));
    while (i < group.*.count) : (i += 1) {
        const panel = group.*.panels[i];
        const tab = rvn_dock_tab_rect(widget, group, shown, @intCast(i));
        const is_active = @as(c_int, @intCast(i)) == group.*.active;
        const is_hot = area.*.hot_node == group and area.*.hot_tab == @as(c_int, @intCast(i)) and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and area.*.dragging == 0;
        const closable = panel.*.slot.dock_fixed == 0 and tab.w >= 44.0;
        const padding = ext.rvn_widget_metric(widget, @intCast(raven.R_METRIC_PADDING_X));
        const opacity = painter.*.opacity;
        const color = if (is_active) text else base.rvn_color_fade(text, 0.62);

        // the tab being dragged is in the hand of the user, not here
        if (area.*.dragging != 0 and panel == area.*.press_panel) painter.*.opacity *= 0.3;
        if (!is_active and is_hot) {
            if (widget_h.rvn_widget_glass(widget) != 0) {
                draw_h.rvn_paint_box(painter, base.rvn_rect(tab.x + 2.0, tab.y, tab.w - 4.0, tab.h), tab.h * 0.5,
                    widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_HEADER_HOVERED)), 0.0, 0);
            } else {
                draw_h.rvn_paint_rect(painter, base.rvn_rect(tab.x, tab.y + 1.0, tab.w, tab.h - 1.0), widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_HEADER_HOVERED)));
            }
        }
        draw_h.rvn_paint_push_clip(painter, base.rvn_rect(tab.x, tab.y, base.rvn_maxf(0.0, tab.w - (if (closable) @as(f32, 20.0) else @as(f32, 4.0))), tab.h));
        {
            const icon_w = rvn_dock_paint_panel_icon(painter, panel, tab.x + padding, tab.y + tab.h * 0.5, color);
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, font, base.rvn_rect(tab.x + padding + icon_w, tab.y, tab.w, tab.h), 0.0,
                rvn_dock_title(panel), -1, color);
        }
        draw_h.rvn_paint_pop_clip(painter);
        if (closable and (is_active or is_hot)) {
            const close = rvn_dock_close_rect(tab);
            const over = is_hot and area.*.hot_close != 0;
            if (over) draw_h.rvn_paint_box(painter, close, 8.0, widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_CONTROL_PRESSED)), 0.0, 0);
            draw_h.rvn_paint_icon(painter, @intCast(draw_h.RVN_ICON_CROSS), close.x + 8.0, close.y + 8.0, 7.0,
                if (over) text else base.rvn_color_fade(text, 0.6));
        }
        painter.*.opacity = opacity;
    }
    draw_h.rvn_paint_pop_clip(painter);
}

fn rvn_dock_area_paint(widget: [*c]rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const dp: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    if (area.*.root == null) {
        draw_h.rvn_paint_text_in(dp, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0),
            base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), 0.5, "No panel", -1,
            base.rvn_color_fade(widget_h.rvn_widget_text_color(widget, painter), 0.4));
        return;
    }
    rvn_dock_each_group(widget, area.*.root, rvn_dock_paint_group, painter);
}

// Above the panels: where the dragged panel would land, and its tab in the hand of the user.
fn rvn_dock_area_paint_overlay(widget: [*c]rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const dp: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const accent = widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_ACCENT));
    // a drop here (a tab of this area, or of another window of the family dragged over it); not a window of its own
    const previewing = (area.*.dragging != 0 or area.*.foreign_panel != null) and area.*.drop != RVN_DOCK_DROP_NONE and
        area.*.drop != RVN_DOCK_DROP_FLOAT and area.*.drop != RVN_DOCK_DROP_ELSEWHERE;

    if (area.*.dragging == 0 and area.*.foreign_panel == null and area.*.preview_shown.started == 0 and area.*.chip_shown.started == 0) return;

    const shown = draw_h.rvn_paint_spring_from(dp, &area.*.preview_shown, if (previewing) 1.0 else 0.0,
        if (previewing) @as(raven.RMotion, @intCast(raven.R_MOTION_BOUNCY)) else @as(raven.RMotion, @intCast(raven.R_MOTION_SNAPPY)));
    if (shown > 0.01) {
        var rect: rvn_rect_t = undefined;
        const inset: f32 = 5.0;
        const opacity = base.rvn_clampf(shown, 0.0, 1.0);
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        if (previewing) {
            // the frame chases the place of the drop, center and size apart: it wobbles into place
            x = draw_h.rvn_paint_spring(dp, &area.*.preview_x, area.*.drop_rect.x + area.*.drop_rect.w * 0.5, @intCast(raven.R_MOTION_BOUNCY));
            y = draw_h.rvn_paint_spring(dp, &area.*.preview_y, area.*.drop_rect.y + area.*.drop_rect.h * 0.5, @intCast(raven.R_MOTION_BOUNCY));
            w = draw_h.rvn_paint_spring(dp, &area.*.preview_w, area.*.drop_rect.w, @intCast(raven.R_MOTION_BOUNCY));
            h = draw_h.rvn_paint_spring(dp, &area.*.preview_h, area.*.drop_rect.h, @intCast(raven.R_MOTION_BOUNCY));
        } else {
            x = area.*.preview_x.value;
            y = area.*.preview_y.value;
            w = area.*.preview_w.value;
            h = area.*.preview_h.value;
        }
        w = base.rvn_maxf(w * (0.9 + 0.1 * shown) - inset * 2.0, 4.0);
        h = base.rvn_maxf(h * (0.9 + 0.1 * shown) - inset * 2.0, 4.0);
        rect = base.rvn_rect(x - w * 0.5, y - h * 0.5, w, h);
        if (widget_h.rvn_widget_glass(widget) != 0) {
            var glass: draw_h.rvn_glass_t = undefined;
            var radii: [4]f32 = undefined;
            const saved = dp.*.opacity;
            common.rvn_glass_style(widget, @intCast(common.RVN_SURFACE_ACCENT), 0.0, 0.0, &glass);
            glass.tint = base.rvn_color_fade(accent, 0.42);
            glass.shadow = 16.0;
            radii[0] = base.rvn_minf(18.0, base.rvn_minf(w, h) * 0.5);
            radii[1] = radii[0];
            radii[2] = radii[0];
            radii[3] = radii[0];
            dp.*.opacity *= opacity;
            draw_h.rvn_paint_glass(dp, rect, &radii, &glass);
            dp.*.opacity = saved;
        } else {
            draw_h.rvn_paint_box(dp, rect, base.rvn_minf(8.0, base.rvn_minf(w, h) * 0.5), base.rvn_color_fade(accent, 0.22 * opacity),
                2.0, base.rvn_color_fade(accent, 0.9 * opacity));
        }
    }

    const lifted = draw_h.rvn_paint_spring_from(dp, &area.*.chip_shown, if (area.*.dragging != 0) 1.0 else 0.0,
        if (area.*.dragging != 0) @as(raven.RMotion, @intCast(raven.R_MOTION_BOUNCY)) else @as(raven.RMotion, @intCast(raven.R_MOTION_SNAPPY)));
    if (lifted > 0.02 and area.*.chip_panel != null) {
        const title = rvn_dock_title(area.*.chip_panel);
        const font = common.rvn_widget_font_size(widget, 0.0);
        const icon_w: f32 = if (area.*.chip_panel.*.slot.has_icon != 0) RVN_DOCK_ICON_SIZE + RVN_DOCK_ICON_GAP else 0.0;
        const width = common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, title) + 28.0 + icon_w;
        const height = rvn_dock_bar_height(widget) - 4.0;
        // the tab trails behind the pointer and stretches the way it goes
        const x = if (area.*.dragging != 0) draw_h.rvn_paint_spring(dp, &area.*.chip_x, area.*.pointer_x, @intCast(raven.R_MOTION_BOUNCY)) else area.*.chip_x.value;
        const y = if (area.*.dragging != 0) draw_h.rvn_paint_spring(dp, &area.*.chip_y, area.*.pointer_y, @intCast(raven.R_MOTION_BOUNCY)) else area.*.chip_y.value;
        const speed_x = base.rvn_clampf(@abs(area.*.chip_x.velocity) * 0.00035, 0.0, 0.3);
        const speed_y = base.rvn_clampf(@abs(area.*.chip_y.velocity) * 0.00035, 0.0, 0.3);
        const chip = base.rvn_rect(x - width * 0.5, y - height * 0.5 + 4.0, width, height);
        const first_instance = dp.*.list.*.instance_count;
        const first_command = dp.*.list.*.command_count;
        const saved = dp.*.opacity;
        const text = widget_h.rvn_widget_text_color(widget, @ptrCast(dp));

        dp.*.opacity *= base.rvn_clampf(lifted * 1.5, 0.0, 1.0);
        if (widget_h.rvn_widget_glass(widget) != 0) {
            common.rvn_paint_surface(@ptrCast(dp), widget, chip, height * 0.5, @intCast(common.RVN_SURFACE_POPUP), 1.0, 0.0);
        } else {
            draw_h.rvn_paint_shadow(dp, base.rvn_rect(chip.x, chip.y + 4.0, chip.w, chip.h), 6.0, 14.0, widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_SHADOW)));
            draw_h.rvn_paint_box(dp, chip, 6.0, widget_h.rvn_widget_color(widget, @intCast(raven.R_COLOR_TAB_ACTIVE)), 1.0, accent);
        }
        if (icon_w > 0.0) {
            _ = rvn_dock_paint_panel_icon(dp, area.*.chip_panel, chip.x + 14.0, chip.y + chip.h * 0.5, text);
            draw_h.rvn_paint_text_in(dp, raven.R_INVALID_ID, font, base.rvn_rect(chip.x + icon_w, chip.y, chip.w - icon_w, chip.h), 0.5, title, -1, text);
        } else {
            draw_h.rvn_paint_text_in(dp, raven.R_INVALID_ID, font, chip, 0.5, title, -1, text);
        }
        dp.*.opacity = saved;
        draw_h.rvn_drawlist_transform(dp.*.list, first_instance, first_command,
            (0.6 + 0.4 * lifted) * (1.0 + speed_x - speed_y * 0.5), (0.6 + 0.4 * lifted) * (1.0 + speed_y - speed_x * 0.5),
            (dp.*.ox + x) * dp.*.scale, (dp.*.oy + y) * dp.*.scale, 0.0, 0.0, dp.*.clip);
    }
    if (area.*.dragging == 0 and area.*.foreign_panel == null and lifted <= 0.02 and shown <= 0.01) {
        area.*.preview_shown.started = raven.R_FALSE;
        area.*.chip_shown.started = raven.R_FALSE;
    }
}

// ---------------------------------------------------------------------------
//  Events
// ---------------------------------------------------------------------------

fn rvn_dock_set_hot(widget: [*c]rvn_widget_t, group: [*c]rvn_dock_node_t, tab: c_int, on_close: c_int) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    if (area.*.hot_node == group and area.*.hot_tab == tab and area.*.hot_close == on_close) return;
    area.*.hot_node = group;
    area.*.hot_tab = tab;
    area.*.hot_close = on_close;
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_dock_end_press(widget: [*c]rvn_widget_t) void {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.press_node = null;
    area.*.press_panel = null;
    area.*.press_close = raven.R_FALSE;
    area.*.dragging = raven.R_FALSE;
    area.*.drop = RVN_DOCK_DROP_NONE;
    area.*.drop_node = null;
    area.*.drop_area = raven.R_INVALID_ID;
    area.*.moving_window = raven.R_FALSE;
    rvn_dock_clear_foreign(widget, null);
    widget_h.rvn_widget_release_mouse(widget);
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_dock_area_event(widget: [*c]rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const own = event.*.target == widget.*.id;
    const x = event.*.local_x;
    const y = event.*.local_y;

    switch (event.*.type) {
        @intCast(raven.R_EVENT_MOUSE_MOVE) => {
            area.*.pointer_x = x;
            area.*.pointer_y = y;
            if (area.*.resize_node != null) {
                const split = area.*.resize_node;
                const length = if (split.*.vertical != 0) split.*.rect.h else split.*.rect.w;
                const room = base.rvn_maxf(1.0, length - rvn_dock_gap(widget));
                const position = (if (split.*.vertical != 0) y - split.*.rect.y else x - split.*.rect.x) - area.*.resize_grab;
                const minimum = base.rvn_minf(RVN_DOCK_MIN, room * 0.5);
                split.*.ratio = base.rvn_clampf(position, minimum, room - minimum) / room;
                // the border follows the hand, not a spring
                area.*.snap = raven.R_TRUE;
                widget_h.rvn_widget_invalidate_layout(widget);
                return raven.R_TRUE;
            }
            if (area.*.press_panel != null) {
                if (area.*.dragging == 0 and area.*.locked == 0 and area.*.press_close == 0 and
                    (@abs(x - area.*.press_x) > RVN_DOCK_DRAG_START or @abs(y - area.*.press_y) > RVN_DOCK_DRAG_START))
                {
                    area.*.dragging = raven.R_TRUE;
                    // the only tab of a floating window: dragging it moves the window (and docks it when it comes over home)
                    if (area.*.home != raven.R_INVALID_ID and area.*.root != null and rvn_dock_is_split(area.*.root) == 0 and area.*.root.*.count == 1 and area.*.tearable != 0) {
                        const origin = widget_h.rvn_widget_origin(widget);
                        area.*.moving_window = raven.R_TRUE;
                        area.*.grab_x = origin.x + area.*.press_x;
                        area.*.grab_y = origin.y + area.*.press_y;
                    }
                    area.*.chip_panel = if (area.*.moving_window != 0) null else area.*.press_panel;
                    ext.rvn_spring_set(&area.*.chip_x, area.*.press_x);
                    ext.rvn_spring_set(&area.*.chip_y, area.*.press_y);
                    area.*.chip_shown = std.mem.zeroes(RSpring);
                    area.*.drop = RVN_DOCK_DROP_NONE;
                }
                if (area.*.dragging != 0 and area.*.moving_window != 0) {
                    var sx: f32 = 0.0;
                    var sy: f32 = 0.0;
                    if (rvn_dock_to_screen(widget, x, y, &sx, &sy) != 0) raven.Rwindow_set_position(area.*.float_window, @intFromFloat(sx - area.*.grab_x), @intFromFloat(sy - area.*.grab_y));
                }
                if (area.*.dragging != 0) rvn_dock_update_drop(widget);
                widget_h.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            }
            if (own) {
                const split = rvn_dock_split_at(widget, area.*.root, x, y);
                const group = if (split != null) null else rvn_dock_group_at(area.*.root, x, y);
                var on_close: c_int = raven.R_FALSE;
                const tab = if (group != null) rvn_dock_tab_at(widget, group, x, y, &on_close) else -1;
                widget.*.cursor = if (split != null)
                    (if (split.*.vertical != 0) @as(raven.RCursor, @intCast(raven.R_CURSOR_RESIZE_V)) else @as(raven.RCursor, @intCast(raven.R_CURSOR_RESIZE_H)))
                else
                    @as(raven.RCursor, 0);
                rvn_dock_set_hot(widget, if (tab >= 0) group else null, tab, on_close);
            } else {
                widget.*.cursor = 0;
                rvn_dock_set_hot(widget, null, -1, raven.R_FALSE);
            }
            return raven.R_FALSE;
        },
        @intCast(raven.R_EVENT_MOUSE_LEAVE) => {
            if (area.*.press_panel == null and area.*.resize_node == null) {
                widget.*.cursor = 0;
                rvn_dock_set_hot(widget, null, -1, raven.R_FALSE);
            }
            return raven.R_FALSE;
        },
        @intCast(raven.R_EVENT_MOUSE_DOWN) => {
            var on_close: c_int = raven.R_FALSE;
            if (own and event.*.button == @as(raven.RMouseButton, @intCast(raven.R_MOUSE_MIDDLE))) {
                // middle click on a tab closes its panel (on release, over the same tab)
                if (area.*.press_panel != null or area.*.resize_node != null) return raven.R_TRUE;
                if (rvn_dock_split_at(widget, area.*.root, x, y) != null) return raven.R_TRUE;
                const group = rvn_dock_group_at(area.*.root, x, y);
                const tab = if (group != null) rvn_dock_tab_at(widget, group, x, y, null) else -1;
                if (tab < 0 or group.*.panels[@intCast(tab)].*.slot.dock_fixed != 0) return raven.R_FALSE;
                area.*.middle_panel = group.*.panels[@intCast(tab)];
                widget_h.rvn_widget_capture_mouse(widget);
                return raven.R_TRUE;
            }
            if (!own or event.*.button != @as(raven.RMouseButton, @intCast(raven.R_MOUSE_LEFT))) return raven.R_FALSE;
            const split = rvn_dock_split_at(widget, area.*.root, x, y);
            if (split != null) {
                area.*.resize_node = split;
                area.*.resize_grab = (if (split.*.vertical != 0) y - split.*.rect.y else x - split.*.rect.x) -
                    (if (split.*.vertical != 0) split.*.a.*.rect.h else split.*.a.*.rect.w);
                widget_h.rvn_widget_capture_mouse(widget);
                return raven.R_TRUE;
            }
            const group = rvn_dock_group_at(area.*.root, x, y);
            const tab = if (group != null) rvn_dock_tab_at(widget, group, x, y, &on_close) else -1;
            if (tab < 0) return raven.R_TRUE;
            if (event.*.clicks >= 2 and on_close == 0 and area.*.home != raven.R_INVALID_ID and rvn_dock_area_of(area.*.home) != null) {
                // (the area may be gone after this: nothing of it is touched)
                _ = rvn_dock_return(widget, group.*.panels[@intCast(tab)]);
                return raven.R_TRUE;
            }
            area.*.press_node = group;
            area.*.press_panel = group.*.panels[@intCast(tab)];
            area.*.press_close = on_close;
            area.*.press_x = x;
            area.*.pointer_x = x;
            area.*.press_y = y;
            area.*.pointer_y = y;
            widget_h.rvn_widget_capture_mouse(widget);
            if (on_close == 0 and tab != group.*.active) {
                rvn_dock_activate(widget, group, tab);
                rvn_dock_changed(widget);
            }
            return raven.R_TRUE;
        },
        @intCast(raven.R_EVENT_MOUSE_UP) => {
            if (event.*.button == @as(raven.RMouseButton, @intCast(raven.R_MOUSE_MIDDLE)) and area.*.middle_panel != null) {
                const panel = area.*.middle_panel;
                const group = rvn_dock_group_at(area.*.root, x, y);
                const tab = if (group != null) rvn_dock_tab_at(widget, group, x, y, null) else -1;
                area.*.middle_panel = null;
                if (area.*.press_panel == null and area.*.resize_node == null) widget_h.rvn_widget_release_mouse(widget);
                if (tab >= 0 and group.*.panels[@intCast(tab)] == panel) rvn_dock_close(widget, panel, raven.R_TRUE);
                return raven.R_TRUE;
            }
            if (event.*.button != @as(raven.RMouseButton, @intCast(raven.R_MOUSE_LEFT))) return raven.R_FALSE;
            if (area.*.resize_node != null) {
                area.*.resize_node = null;
                widget_h.rvn_widget_release_mouse(widget);
                rvn_dock_changed(widget);
                return raven.R_TRUE;
            }
            if (area.*.press_panel == null) return raven.R_FALSE;
            if (area.*.dragging != 0) {
                const panel = area.*.press_panel;
                const drop = area.*.drop;
                const target = area.*.drop_node;
                const from = area.*.drop_rect;
                const index = area.*.drop_index;
                if (drop == RVN_DOCK_DROP_ELSEWHERE) {
                    // the drop of the other area, read before the previews go
                    const other = rvn_dock_area_of(area.*.drop_area);
                    const other_drop = if (other != null) other.*.drop else RVN_DOCK_DROP_NONE;
                    const other_target = if (other != null) other.*.drop_node else null;
                    const other_rect = if (other != null) other.*.drop_rect else from;
                    const other_index = if (other != null) other.*.drop_index else -1;
                    rvn_dock_end_press(widget);
                    if (other != null and other_drop != RVN_DOCK_DROP_NONE) rvn_dock_transfer(widget, &other.*.base, panel, other_drop, other_target, other_index, &other_rect);
                } else if (drop == RVN_DOCK_DROP_FLOAT) {
                    var sx: f32 = 0.0;
                    var sy: f32 = 0.0;
                    const ok = rvn_dock_to_screen(widget, x, y, &sx, &sy);
                    rvn_dock_end_press(widget);
                    // the window opens under the pointer, its tab where the hand is
                    if (ok != 0) _ = rvn_dock_tear(widget, panel, sx - 60.0, sy - 14.0);
                } else {
                    rvn_dock_end_press(widget);
                    if (drop != RVN_DOCK_DROP_NONE) rvn_dock_move(widget, panel, drop, target, 0.0, index, &from);
                }
            } else if (area.*.press_close != 0) {
                const panel = area.*.press_panel;
                var on_close: c_int = raven.R_FALSE;
                const group = rvn_dock_group_at(area.*.root, x, y);
                const tab = if (group != null) rvn_dock_tab_at(widget, group, x, y, &on_close) else -1;
                rvn_dock_end_press(widget);
                if (tab >= 0 and on_close != 0 and group.*.panels[@intCast(tab)] == panel) rvn_dock_close(widget, panel, raven.R_TRUE);
            } else {
                rvn_dock_end_press(widget);
            }
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

// ---------------------------------------------------------------------------
//  Saved layouts
//
//    layout := split | group
//    split  := ('H' | 'V') '(' share ',' layout ',' layout ')'
//    group  := 'T' '(' shown ';' name { ',' name } ')'
//
//  H puts its two parts side by side, V one above the other; `share` is the
//  part of the room taken by the first, in thousandths. Names are the names
//  of the panels, with anything but letters, digits, '_', '-' and '.'
//  written as %XX.
// ---------------------------------------------------------------------------

const rvn_dock_text_t = extern struct {
    data: [*c]u8,
    length: u32,
    cap: u32,
};

fn rvn_dock_text_add(text: [*c]rvn_dock_text_t, piece: [*c]const u8) void {
    const length: u32 = @intCast(libc.strlen(piece));
    base.RVN_ARRAY_RESERVE(&text.*.data, &text.*.cap, text.*.length + length + 1);
    _ = libc.memcpy(text.*.data + @as(usize, text.*.length), piece, @as(usize, length) + 1);
    text.*.length += length;
}

fn rvn_dock_save_node(node: [*c]const rvn_dock_node_t, text: [*c]rvn_dock_text_t) void {
    var buffer: [16]u8 = undefined;
    var first = true;
    if (rvn_dock_is_split(node) != 0) {
        _ = libc.snprintf(&buffer, buffer.len, "%c(%d,",
            @as(c_int, if (node.*.vertical != 0) 'V' else 'H'),
            @as(c_int, @intFromFloat(base.rvn_clampf(node.*.ratio, 0.0, 1.0) * 1000.0 + 0.5)));
        rvn_dock_text_add(text, &buffer);
        rvn_dock_save_node(node.*.a, text);
        rvn_dock_text_add(text, ",");
        rvn_dock_save_node(node.*.b, text);
        rvn_dock_text_add(text, ")");
        return;
    }
    _ = libc.snprintf(&buffer, buffer.len, "T(%d;", node.*.active);
    rvn_dock_text_add(text, &buffer);
    var i: u32 = 0;
    while (i < node.*.count) : (i += 1) {
        const name_start = node.*.panels[i].*.name;
        if (name_start == null or name_start[0] == 0) continue;
        if (!first) rvn_dock_text_add(text, ",");
        first = false;
        var name = name_start;
        while (name[0] != 0) : (name += 1) {
            const c: u8 = name[0];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.') {
                buffer[0] = c;
                buffer[1] = 0;
            } else {
                _ = libc.snprintf(&buffer, buffer.len, "%%%02X", @as(c_uint, c));
            }
            rvn_dock_text_add(text, &buffer);
        }
    }
    rvn_dock_text_add(text, ")");
}

fn rvn_dock_hex(c: u8) c_int {
    if (c >= '0' and c <= '9') return @as(c_int, c - '0');
    if (c >= 'a' and c <= 'f') return @as(c_int, c - 'a') + 10;
    if (c >= 'A' and c <= 'F') return @as(c_int, c - 'A') + 10;
    return -1;
}

// Returns the byte at the cursor and moves past it (the C `*text++`).
fn rvn_dock_next_byte(p: *[*c]const u8) u8 {
    const c = p.*[0];
    p.* += 1;
    return c;
}

// Reads one node. Returns NULL with *ok cleared when the text is wrong, and
// NULL with *ok kept when the node holds no panel of the area (it is then
// simply left out).
fn rvn_dock_load_node(widget: [*c]rvn_widget_t, cursor: [*c][*c]const u8, used: [*c]u8, ok: [*c]c_int, depth: c_int) [*c]rvn_dock_node_t {
    var text: [*c]const u8 = cursor.*;

    if (depth > 64) {
        ok.* = raven.R_FALSE;
        return null;
    }
    if ((text[0] == 'H' or text[0] == 'V') and text[1] == '(') {
        const vertical: c_int = @intFromBool(text[0] == 'V');
        var share: c_int = 0;
        text += 2;
        if (text[0] < '0' or text[0] > '9') {
            ok.* = raven.R_FALSE;
            return null;
        }
        while (text[0] >= '0' and text[0] <= '9' and share < 100000) {
            share = share * 10 + @as(c_int, text[0] - '0');
            text += 1;
        }
        if (rvn_dock_next_byte(&text) != ',') {
            ok.* = raven.R_FALSE;
            return null;
        }
        const a = rvn_dock_load_node(widget, &text, used, ok, depth + 1);
        if (ok.* != 0 and rvn_dock_next_byte(&text) != ',') ok.* = raven.R_FALSE;
        const b = if (ok.* != 0) rvn_dock_load_node(widget, &text, used, ok, depth + 1) else null;
        if (ok.* != 0 and rvn_dock_next_byte(&text) != ')') ok.* = raven.R_FALSE;
        if (ok.* == 0) {
            rvn_dock_tree_free(widget, a);
            rvn_dock_tree_free(widget, b);
            return null;
        }
        cursor.* = text;
        // a side that has no panel left gives its place to the other
        if (a == null or b == null) return if (a != null) a else b;
        const node: [*c]rvn_dock_node_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_dock_node_t))));
        node.*.vertical = vertical;
        node.*.ratio = base.rvn_clampf(@as(f32, @floatFromInt(share)) / 1000.0, 0.02, 0.98);
        node.*.a = a;
        node.*.b = b;
        a.*.parent = node;
        b.*.parent = node;
        return node;
    }
    if (text[0] == 'T' and text[1] == '(') {
        var shown: c_int = 0;
        var shown_index: c_int = -1;
        var position: c_int = 0;
        text += 2;
        while (text[0] >= '0' and text[0] <= '9' and shown < 100000) {
            shown = shown * 10 + @as(c_int, text[0] - '0');
            text += 1;
        }
        if (rvn_dock_next_byte(&text) != ';') {
            ok.* = raven.R_FALSE;
            return null;
        }
        const node = rvn_dock_group_new();
        while (text[0] != 0 and text[0] != ')') {
            var name: [256]u8 = undefined;
            var length: usize = 0;
            while (text[0] != 0 and text[0] != ',' and text[0] != ')') {
                var c: u8 = rvn_dock_next_byte(&text);
                if (c == '%') {
                    const high = rvn_dock_hex(text[0]);
                    const low: c_int = if (high >= 0) rvn_dock_hex(text[1]) else -1;
                    if (low < 0) {
                        ok.* = raven.R_FALSE;
                        break;
                    }
                    c = @intCast(high * 16 + low);
                    text += 2;
                }
                if (length + 1 < name.len) {
                    name[length] = c;
                    length += 1;
                }
            }
            if (ok.* == 0) break;
            name[length] = 0;
            if (text[0] == ',') text += 1;
            var i: u32 = 0;
            while (i < widget.*.child_count) : (i += 1) {
                const panel = widget.*.children[i];
                if (used[i] != 0 or panel.*.name == null or libc.strcmp(panel.*.name, &name) != 0) continue;
                used[i] = 1;
                if (position == shown) shown_index = @intCast(node.*.count);
                rvn_dock_group_insert(node, panel, -1);
                break;
            }
            position += 1;
        }
        if (ok.* != 0 and rvn_dock_next_byte(&text) != ')') ok.* = raven.R_FALSE;
        if (ok.* == 0 or node.*.count == 0) {
            rvn_dock_node_free(widget, node);
            if (ok.* != 0) cursor.* = text;
            return null;
        }
        node.*.active = if (shown_index >= 0) shown_index else 0;
        cursor.* = text;
        return node;
    }
    ok.* = raven.R_FALSE;
    return null;
}

fn rvn_dock_load(widget: [*c]rvn_widget_t, layout: [*c]const u8) c_int {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const used_size: usize = if (widget.*.child_count != 0) widget.*.child_count else 1;
    const used: [*c]u8 = @ptrCast(@alignCast(base.rvn_calloc(used_size)));
    var cursor: [*c]const u8 = layout;
    var ok: c_int = raven.R_TRUE;
    var i: u32 = 0;

    while (cursor[0] == ' ') cursor += 1;
    const root = rvn_dock_load_node(widget, &cursor, used, &ok, 0);
    while (ok != 0 and cursor[0] == ' ') cursor += 1;
    if (ok != 0 and cursor[0] != 0) ok = raven.R_FALSE;
    if (ok == 0) {
        rvn_dock_tree_free(widget, root);
        base.rvn_free(used);
        return raven.R_FALSE;
    }
    rvn_dock_tree_free(widget, area.*.root);
    area.*.root = root;
    rvn_dock_end_press(widget);
    // the panels the description does not know keep a place: behind the first tabs (a hidden one stays hidden)
    while (i < widget.*.child_count) : (i += 1) {
        const hidden = rvn_dock_hidden_index(area, widget.*.children[i]);
        if (used[i] != 0) {
            rvn_dock_hidden_remove(area, hidden);
        } else if (hidden < 0) {
            _ = rvn_dock_insert(widget, widget.*.children[i], RVN_DOCK_DROP_TAB, null, 0.0, -1);
        }
    }
    base.rvn_free(used);
    if (widget.*.window != null) {
        // what was shown may be hidden now
        i = 0;
        while (i < widget.*.child_count) : (i += 1) {
            if (rvn_dock_area_child_active(widget, widget.*.children[i]) == 0) widget_h.rvn_window_forget_widget(widget.*.window, widget.*.children[i]);
        }
    }
    widget_h.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

fn rvn_dock_area_set_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var flag: c_int = 0;
    if (base.rvn_stricmp(name, "Movable") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        area.*.locked = @intFromBool(flag == 0);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Layout") == 0) return rvn_dock_load(widget, value);
    if (base.rvn_stricmp(name, "Tearable") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        area.*.tearable = flag;
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "CloseHides") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        area.*.close_hides = flag;
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_dock_area: rvn_widget_class_t = .{
    .type = @intCast(raven.R_WIDGET_DOCK_AREA),
    .name = "DockArea",
    .size = @sizeOf(rvn_dock_area_t),
    .flags = widget_h.RVN_CF_CLIP | widget_h.RVN_CF_SURFACE,
    .init = rvn_dock_area_init,
    .destroy = rvn_dock_area_destroy,
    .measure = rvn_dock_area_measure,
    .arrange = rvn_dock_area_arrange,
    .paint = rvn_dock_area_paint,
    .paint_overlay = rvn_dock_area_paint_overlay,
    .event = rvn_dock_area_event,
    .set_attribute = rvn_dock_area_set_attribute,
    .child_active = rvn_dock_area_child_active,
    .child_at = null,
    .children_changed = rvn_dock_sync,
    .xml_child = null,
    .popup_closed = null,
    .window_drag_at = null,
};

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rdock_area_create() raven.Rid {
    if (ctx_h.rvn_api_check("Rdock_area_create") == 0) return raven.R_INVALID_ID;
    const widget = widget_h.rvn_widget_create(@intCast(raven.R_WIDGET_DOCK_AREA));
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

// Checks the arguments shared by the functions that dock a panel.
fn rvn_dock_check_place(widget: [*c]rvn_widget_t, side: raven.RDockSide, relative_id: Rid, relative: [*c][*c]rvn_widget_t, function: [*c]const u8) c_int {
    relative.* = null;
    if (side < @as(raven.RDockSide, @intCast(raven.R_DOCK_LEFT)) or side > @as(raven.RDockSide, @intCast(raven.R_DOCK_TAB))) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "%s: invalid side", function);
        return raven.R_FALSE;
    }
    if (relative_id == raven.R_INVALID_ID) return raven.R_TRUE;
    relative.* = widget_h.rvn_widget_check(relative_id, 0, function);
    if (relative.* == null) return raven.R_FALSE;
    if (relative.*.*.parent != widget) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: the relative widget is not a panel of this dock area", function);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// The panel of an area. A panel that went to a floating window of the area
// is still its panel: `widget` becomes the floating area that holds it.
fn rvn_dock_check_panel_in(widget_io: [*c][*c]rvn_widget_t, panel_id: Rid, function: [*c]const u8) [*c]rvn_widget_t {
    const widget = widget_io.*;
    const panel = widget_h.rvn_widget_check(panel_id, 0, function);
    if (panel == null) return null;
    if (panel.*.parent != widget and panel.*.parent != null and panel.*.parent.*.cls == &rvn_class_dock_area and
        @as([*c]rvn_dock_area_t, @ptrCast(panel.*.parent)).*.home == rvn_dock_home_of(widget).*.id)
    {
        widget_io.* = panel.*.parent;
        return panel;
    }
    if (panel.*.parent != widget) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: the widget is not a panel of this dock area", function);
        return null;
    }
    return panel;
}

export fn Rdock_area_move_panel(id: Rid, panel_id: Rid, side: raven.RDockSide, relative_id: Rid, size: f32) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_move_panel");
    if (widget == null) return;
    const home = widget;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_move_panel");
    if (panel == null) return;
    // a floating panel comes back home first, then moves
    if (widget != home) {
        _ = rvn_dock_return(widget, panel);
        widget = home;
    }
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var relative: [*c]rvn_widget_t = null;
    if (rvn_dock_check_place(widget, side, relative_id, &relative, "Rdock_area_move_panel") == 0) return;
    if (relative == panel) return;
    var target: [*c]rvn_dock_node_t = if (relative != null) rvn_dock_find(area.*.root, relative, null) else null;
    if (target == null and side == @as(raven.RDockSide, @intCast(raven.R_DOCK_TAB))) target = rvn_dock_first_group(area.*.root);
    // alone in the area: there is nothing to be put against
    if (target == null and area.*.root != null and rvn_dock_is_split(area.*.root) == 0 and area.*.root.*.count == 1) return;
    rvn_dock_move(widget, panel, rvn_dock_drop_from_side(side), target, size, -1, null);
}

export fn Rdock_area_add_panel(id: Rid, panel_id: Rid, title: [*c]const u8, side: raven.RDockSide, relative_id: Rid, size: f32) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_add_panel");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const panel = widget_h.rvn_widget_check(panel_id, 0, "Rdock_area_add_panel");
    var relative: [*c]rvn_widget_t = null;
    if (panel == null or rvn_dock_check_place(widget, side, relative_id, &relative, "Rdock_area_add_panel") == 0) return;
    if (widget_h.rvn_widget_is_inside(widget, panel) != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rdock_area_add_panel: a widget cannot be docked inside itself");
        return;
    }
    if (title != null) _ = base.rvn_str_set(&panel.*.slot.title, title);
    if (panel.*.parent == widget) {
        Rdock_area_move_panel(id, panel_id, side, relative_id, size);
        return;
    }
    panel.*.slot.dock = side;
    panel.*.slot.dock_size = if (size > 0.0 and size < 1.0) size else 0.0;
    area.*.pending_relative = relative;
    area.*.pending_valid = raven.R_TRUE;
    widget_h.rvn_widget_add_child(widget, panel, -1);
    area.*.pending_relative = null;
    area.*.pending_valid = raven.R_FALSE;
}

export fn Rdock_area_close_panel(id: Rid, panel_id: Rid) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_close_panel");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_close_panel");
    if (panel != null) rvn_dock_close(widget, panel, raven.R_FALSE);
}

export fn Rdock_area_set_panel_title(id: Rid, panel_id: Rid, title: [*c]const u8) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_panel_title");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_set_panel_title");
    if (panel != null and base.rvn_str_set(&panel.*.slot.title, title) != 0) widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rdock_area_set_panel_icon(id: Rid, panel_id: Rid, texture: Rid, u0_: f32, v0_: f32, u1_: f32, v1_: f32, tint: c_int) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_panel_icon");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_set_panel_icon");
    if (panel == null) return;
    panel.*.slot.has_icon = @intFromBool(texture != raven.R_INVALID_ID);
    panel.*.slot.icon = texture;
    panel.*.slot.icon_uv[0] = u0_;
    panel.*.slot.icon_uv[1] = v0_;
    panel.*.slot.icon_uv[2] = u1_;
    panel.*.slot.icon_uv[3] = v1_;
    panel.*.slot.icon_tint = @intFromBool(tint != 0);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rdock_area_set_panel_closable(id: Rid, panel_id: Rid, closable: c_int) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_panel_closable");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_set_panel_closable");
    if (panel == null) return;
    panel.*.slot.dock_fixed = @intFromBool(closable == 0);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rdock_area_show_panel(id: Rid, panel_id: Rid) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_show_panel");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_show_panel");
    if (panel == null) return;
    var index: c_int = 0;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    const group = rvn_dock_find(area.*.root, panel, &index);
    if (group != null) rvn_dock_activate(widget, group, index);
}

export fn Rdock_area_is_panel_shown(id: Rid, panel_id: Rid) c_int {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_is_panel_shown");
    if (widget == null) return raven.R_FALSE;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_is_panel_shown");
    return @intFromBool(panel != null and rvn_dock_area_child_active(widget, panel) != 0);
}

export fn Rdock_area_set_movable(id: Rid, movable: c_int) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_movable");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.locked = @intFromBool(movable == 0);
}

export fn Rdock_area_save_layout(id: Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_save_layout");
    if (widget == null) return "";
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    var text: rvn_dock_text_t = std.mem.zeroes(rvn_dock_text_t);
    rvn_dock_text_add(&text, "");
    if (area.*.root != null) rvn_dock_save_node(area.*.root, &text);
    base.rvn_free(area.*.layout_text);
    area.*.layout_text = text.data;
    return area.*.layout_text;
}

export fn Rdock_area_load_layout(id: Rid, layout: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_load_layout");
    if (widget == null) return raven.R_FALSE;
    if (layout == null) return raven.R_FALSE;
    return rvn_dock_load(widget, layout);
}

export fn Rdock_area_set_close_callback(id: Rid, callback: raven.RDockCloseCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_close_callback");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.close_callback = callback;
    area.*.close_user = user_data;
}

export fn Rdock_area_set_changed_callback(id: Rid, callback: raven.RDockChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_changed_callback");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.changed_callback = callback;
    area.*.changed_user = user_data;
}

export fn Rdock_area_hide_panel(id: Rid, panel_id: Rid) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_hide_panel");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_hide_panel");
    if (panel != null) rvn_dock_hide(widget, panel);
}

export fn Rdock_area_open_panel(id: Rid, panel_id: Rid) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_open_panel");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_open_panel");
    if (panel != null) rvn_dock_open(widget, panel);
}

export fn Rdock_area_is_panel_open(id: Rid, panel_id: Rid) c_int {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_is_panel_open");
    if (widget == null) return raven.R_FALSE;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_is_panel_open");
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    return @intFromBool(panel != null and rvn_dock_find(area.*.root, panel, null) != null);
}

export fn Rdock_area_set_close_hides(id: Rid, hides: c_int) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_close_hides");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.close_hides = @intFromBool(hides != 0);
}

// ---------------------------------------------------------------------------
//  Tearing (public)
// ---------------------------------------------------------------------------

export fn Rdock_area_set_tearable(id: Rid, tearable: c_int) void {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_set_tearable");
    if (widget == null) return;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    area.*.tearable = @intFromBool(tearable != 0);
}

export fn Rdock_area_is_tearable(id: Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_is_tearable");
    if (widget == null) return raven.R_FALSE;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    return area.*.tearable;
}

export fn Rdock_area_float_panel(id: Rid, panel_id: Rid, x: c_int, y: c_int) Rid {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_float_panel");
    if (widget == null) return raven.R_INVALID_ID;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_float_panel");
    if (panel == null) return raven.R_INVALID_ID;
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    // (already floating alone: its window moves)
    if (area.*.home != raven.R_INVALID_ID and widget.*.child_count == 1) {
        const window = area.*.float_window;
        raven.Rwindow_set_position(window, x, y);
        return window;
    }
    // a hidden panel is shown first
    if (rvn_dock_find(area.*.root, panel, null) == null) rvn_dock_open(widget, panel);
    return rvn_dock_tear(widget, panel, @floatFromInt(x), @floatFromInt(y));
}

export fn Rdock_area_dock_panel(id: Rid, panel_id: Rid) void {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_dock_panel");
    if (widget == null) return;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_dock_panel");
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    if (panel != null and area.*.home != raven.R_INVALID_ID) _ = rvn_dock_return(widget, panel);
}

export fn Rdock_area_get_panel_window(id: Rid, panel_id: Rid) Rid {
    var widget = widget_h.rvn_widget_check(id, @intCast(raven.R_WIDGET_DOCK_AREA), "Rdock_area_get_panel_window");
    if (widget == null) return raven.R_INVALID_ID;
    const panel = rvn_dock_check_panel_in(&widget, panel_id, "Rdock_area_get_panel_window");
    const area: [*c]rvn_dock_area_t = @ptrCast(widget);
    if (panel == null or area.*.home == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    return area.*.float_window;
}
