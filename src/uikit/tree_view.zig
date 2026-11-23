//! uikit/tree_view: Rtree_view (R_WIDGET_TREE_VIEW, raven_widget.h).
//!
//! Mode: retained. The widget is created with Rwidget_create(R_WIDGET_TREE_VIEW)
//! and its items are added with Rtree_view_add_item / Rtree_item_* calls. Nothing
//! here repaints per frame, so there is no immediate-mode code in this file.
//! Raven calls (to be declared by hand in raven.zig when the widget is built, not
//! declared yet): Rtree_view_add_item, Rtree_item_set_expanded,
//! Rtree_item_is_expanded, Rtree_item_get_child_count, Rtree_item_get_parent,
//! Rtree_view_set_selected_item, Rtree_view_set_multi_select,
//! Rtree_item_set_selected, Rtree_view_get_item_at, Rtree_view_set_selection_changed_callback,
//! Rtree_view_set_activated_callback, Rtree_view_set_context_callback,
//! Rtree_view_set_drag_type, Rtree_view_scroll_to_item, Rwidget_set_color,
//! Rwidget_set_metric.
//! State transitions use Raven's own springs; theme.transition_ms (120 ms) is
//! the target feel, see docs/development/uikit.md.
//!
//! The pure index and selection maths below works on plain slices, so it is
//! testable without Raven. Selection state is owned by the caller as a `[]bool`
//! with one entry per node (in the same order as the `Node` slice).
//!
//! Liquid glass: translucent layered fills (theme.glassAlpha), a 1 px top
//! highlight, a soft shadow, radius in 10..14, the accent colour marks the active
//! (selected) row, and text is never drawn below theme.min_font_px (12 px).
//!
//! Status: configuration and pure index/selection logic implemented; the tests
//! below pin the behaviour. The Raven externs are declared by hand further down
//! (matching vendor/raven/include/raven/raven_controls.h); the widget build step
//! that calls them lives with the rest of the uikit wiring.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

// ---------------------------------------------------------------------------
// Raven externs (hand-declared, matching vendor/raven/include/raven/raven_controls.h).
// ---------------------------------------------------------------------------

/// Selection-changed and activated callbacks: (tree_view, item, user_data).
pub const TreeEventCallback = *const fn (tree_view: raven.Rid, item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void;
/// Context-menu callback: (tree_view, item, x, y, user_data).
pub const TreeContextCallback = *const fn (tree_view: raven.Rid, item: raven.Rid, x: f32, y: f32, user_data: ?*anyopaque) callconv(.c) void;

pub extern fn Rtree_view_add_item(tree_view: raven.Rid, parent_item: raven.Rid, text: [*:0]const u8) raven.Rid;
pub extern fn Rtree_item_set_expanded(item: raven.Rid, expanded: c_int) void;
pub extern fn Rtree_item_is_expanded(item: raven.Rid) c_int;
pub extern fn Rtree_item_get_parent(item: raven.Rid) raven.Rid;
pub extern fn Rtree_item_get_child_count(item: raven.Rid) c_int;
pub extern fn Rtree_view_set_selected_item(tree_view: raven.Rid, item: raven.Rid) void;
pub extern fn Rtree_view_get_selected_item(tree_view: raven.Rid) raven.Rid;
pub extern fn Rtree_view_set_multi_select(tree_view: raven.Rid, enabled: c_int) void;
pub extern fn Rtree_view_get_item_at(tree_view: raven.Rid, local_x: f32, local_y: f32) raven.Rid;
pub extern fn Rtree_view_scroll_to_item(tree_view: raven.Rid, item: raven.Rid) void;
pub extern fn Rtree_view_set_selection_changed_callback(tree_view: raven.Rid, cb: ?TreeEventCallback, user_data: ?*anyopaque) void;
pub extern fn Rtree_view_set_activated_callback(tree_view: raven.Rid, cb: ?TreeEventCallback, user_data: ?*anyopaque) void;
pub extern fn Rtree_view_set_context_callback(tree_view: raven.Rid, cb: ?TreeContextCallback, user_data: ?*anyopaque) void;
pub extern fn Rtree_view_set_drag_type(tree_view: raven.Rid, type_name: [*:0]const u8) void;

/// Extra vertical padding a row needs above its text, in logical px.
pub const min_row_padding_px: f32 = 4.0;
/// Upper bound for the per-level indentation, in logical px.
pub const max_indent_px: f32 = 64.0;

pub const Config = struct {
    /// Indentation added per tree level, in logical px.
    indent_px: f32 = 16.0,
    /// Height of one row, in logical px. Raised to fit the text (see clampConfig).
    row_height_px: f32 = 24.0,
    /// Row text size, in logical px. Never below theme.min_font_px.
    font_px: f32 = theme.font_body_px,
    /// Corner radius of the tree surface and of the active row, in [10, 14].
    radius_px: f32 = theme.radius_control,
    /// Ctrl/Shift click build a multi-selection when true.
    multi_select: bool = false,
};

/// One item of the tree, in a flat slice. A node with `parent == null` is a root.
pub const Node = struct {
    parent: ?u32 = null,
    has_children: bool = false,
    expanded: bool = false,
};

/// Returns a Config with every field repaired into its valid range:
/// indent in [0, max_indent_px] (NaN gives 0), font via theme.clampFontSize,
/// radius via theme.clampRadius, row height at least font_px + min_row_padding_px.
pub fn clampConfig(cfg: Config) Config {
    var out = cfg;
    // Negated comparisons so that NaN takes the floor.
    if (!(cfg.indent_px >= 0.0)) {
        out.indent_px = 0.0;
    } else if (cfg.indent_px > max_indent_px) {
        out.indent_px = max_indent_px;
    }
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.radius_px = theme.clampRadius(cfg.radius_px);
    const min_row = out.font_px + min_row_padding_px;
    if (!(cfg.row_height_px >= min_row)) out.row_height_px = min_row;
    return out;
}

/// True when `nodes[index]` is drawn: every ancestor is expanded.
/// A parent index outside the slice is treated as "no parent" (a root).
/// The walk is bounded by nodes.len so a malformed cycle cannot loop forever;
/// a cycle is reported as hidden.
fn isVisible(nodes: []const Node, index: usize) bool {
    var cur = index;
    var hops: usize = 0;
    while (nodes[cur].parent) |p| {
        if (p >= nodes.len) return true;
        if (hops >= nodes.len) return false;
        if (!nodes[p].expanded) return false;
        cur = p;
        hops += 1;
    }
    return true;
}

/// Number of ancestors of `nodes[index]`. Roots have depth 0.
/// Out-of-range index gives 0.
pub fn depthOf(nodes: []const Node, index: u32) u32 {
    const start: usize = index;
    if (start >= nodes.len) return 0;
    var depth: u32 = 0;
    var cur = start;
    var hops: usize = 0;
    while (nodes[cur].parent) |p| {
        if (p >= nodes.len or hops >= nodes.len) break;
        depth += 1;
        cur = p;
        hops += 1;
    }
    return depth;
}

/// Number of rows drawn: a node is visible when every ancestor is expanded.
pub fn visibleRowCount(nodes: []const Node) usize {
    var count: usize = 0;
    for (0..nodes.len) |i| {
        if (isVisible(nodes, i)) count += 1;
    }
    return count;
}

/// Visible row index of `nodes[index]`, or null if the node is hidden under a
/// collapsed ancestor or the index is out of range.
pub fn rowIndexOf(nodes: []const Node, index: u32) ?usize {
    const target: usize = index;
    if (target >= nodes.len or !isVisible(nodes, target)) return null;
    var row: usize = 0;
    for (0..target) |i| {
        if (isVisible(nodes, i)) row += 1;
    }
    return row;
}

/// Node index drawn at visible row `row`, or null if `row` is out of range.
/// Inverse of rowIndexOf for visible nodes.
pub fn nodeAtRow(nodes: []const Node, row: usize) ?u32 {
    var seen: usize = 0;
    for (0..nodes.len) |i| {
        if (!isVisible(nodes, i)) continue;
        if (seen == row) return @intCast(i);
        seen += 1;
    }
    return null;
}

/// Horizontal offset of the content of a node at `depth`, in logical px.
pub fn indentOffsetPx(cfg: Config, depth: u32) f32 {
    const indent = clampConfig(cfg).indent_px;
    return indent * @as(f32, @floatFromInt(depth));
}

/// Visible row under a point `y_px` measured from the top of the rows (scroll
/// included). Negative or NaN y gives null, as does y past the last row.
/// The row boundary is inclusive at the top: y == row_height_px is row 1.
pub fn rowAtY(cfg: Config, y_px: f32, row_count: usize) ?usize {
    if (!(y_px >= 0.0)) return null;
    const row_h = clampConfig(cfg).row_height_px;
    const row_f = @floor(y_px / row_h);
    if (!(row_f < @as(f32, @floatFromInt(row_count)))) return null;
    return @intFromFloat(row_f);
}

/// Flips the expanded state of `nodes[index]`. A node without children, or an
/// out-of-range index, is left unchanged.
pub fn toggleExpanded(nodes: []Node, index: u32) void {
    const i: usize = index;
    if (i >= nodes.len) return;
    if (!nodes[i].has_children) return;
    nodes[i].expanded = !nodes[i].expanded;
}

/// Fill of a row: the accent at low alpha when selected (the active state),
/// fully transparent otherwise. Alpha stays in [0, 1].
pub fn rowFill(selected: bool) theme.Color {
    const alpha: f32 = if (selected) 0.24 else 0.0;
    return theme.withAlpha(theme.accent, alpha);
}

/// Makes `index` the only selected entry. Out-of-range index leaves `selected` unchanged.
pub fn selectSingle(selected: []bool, index: u32) void {
    const i: usize = index;
    if (i >= selected.len) return;
    @memset(selected, false);
    selected[i] = true;
}

/// Ctrl+click: flips `index` and leaves the other entries as they are.
/// Out-of-range index is a no-op.
pub fn toggleMulti(selected: []bool, index: u32) void {
    const i: usize = index;
    if (i >= selected.len) return;
    selected[i] = !selected[i];
}

/// Shift+click: selects every entry from `anchor` to `index` inclusive, in either
/// direction, and leaves other entries as they are. Out-of-range ends are a no-op.
pub fn selectRange(selected: []bool, anchor: u32, index: u32) void {
    const a: usize = anchor;
    const b: usize = index;
    if (a >= selected.len or b >= selected.len) return;
    const lo = @min(a, b);
    const hi = @max(a, b);
    for (lo..hi + 1) |i| selected[i] = true;
}

/// Number of selected entries.
pub fn selectionCount(selected: []const bool) usize {
    var count: usize = 0;
    for (selected) |s| {
        if (s) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests. Each one specifies behaviour; all are @panic("todo") via the functions
// above until implemented.
// ---------------------------------------------------------------------------

fn approx(a: f32, b: f32) !void {
    try testing.expectApproxEqAbs(a, b, 1e-3);
}

test "tree view configuration: defaults" {
    const cfg = Config{};
    try approx(cfg.indent_px, 16.0);
    try approx(cfg.row_height_px, 24.0);
    try approx(cfg.font_px, theme.font_body_px);
    try approx(cfg.radius_px, theme.radius_control);
    try testing.expect(!cfg.multi_select);
    // Defaults must already be valid.
    const fixed = clampConfig(cfg);
    try approx(fixed.font_px, cfg.font_px);
    try approx(fixed.row_height_px, cfg.row_height_px);
}

test "tree view configuration: font never below 12 px" {
    const small = clampConfig(Config{ .font_px = 8.0 });
    try approx(small.font_px, theme.min_font_px);
    const nan = clampConfig(Config{ .font_px = std.math.nan(f32) });
    try approx(nan.font_px, theme.min_font_px);
}

test "tree view configuration: radius clamped into 10..14" {
    try approx(clampConfig(Config{ .radius_px = 2.0 }).radius_px, theme.radius_min);
    try approx(clampConfig(Config{ .radius_px = 12.0 }).radius_px, 12.0);
    try approx(clampConfig(Config{ .radius_px = 40.0 }).radius_px, theme.radius_max);
}

test "tree view configuration: indent clamped into 0..64" {
    try approx(clampConfig(Config{ .indent_px = -5.0 }).indent_px, 0.0);
    try approx(clampConfig(Config{ .indent_px = std.math.nan(f32) }).indent_px, 0.0);
    try approx(clampConfig(Config{ .indent_px = 200.0 }).indent_px, max_indent_px);
    try approx(clampConfig(Config{ .indent_px = 20.0 }).indent_px, 20.0);
}

test "tree view configuration: row height fits the text" {
    // Row must be at least font + min_row_padding_px (13 + 4 = 17 by default font).
    const cfg = clampConfig(Config{ .row_height_px = 10.0, .font_px = 13.0 });
    try approx(cfg.row_height_px, 13.0 + min_row_padding_px);
    const tall = clampConfig(Config{ .row_height_px = 30.0, .font_px = 13.0 });
    try approx(tall.row_height_px, 30.0);
}

test "tree view depth: roots are 0, children and grandchildren count ancestors" {
    const nodes = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = true }, // 0 root
        .{ .parent = 0, .has_children = true, .expanded = true }, // 1 child
        .{ .parent = 1 }, // 2 grandchild
    };
    try testing.expectEqual(@as(u32, 0), depthOf(&nodes, 0));
    try testing.expectEqual(@as(u32, 1), depthOf(&nodes, 1));
    try testing.expectEqual(@as(u32, 2), depthOf(&nodes, 2));
    try testing.expectEqual(@as(u32, 0), depthOf(&nodes, 99));
}

test "tree view visible rows: collapsed parents hide their subtree" {
    const collapsed = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = false }, // 0
        .{ .parent = 0 }, // 1 hidden
        .{ .parent = null }, // 2
    };
    try testing.expectEqual(@as(usize, 2), visibleRowCount(&collapsed));

    const open = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = true }, // 0
        .{ .parent = 0, .has_children = true, .expanded = false }, // 1 visible, collapsed
        .{ .parent = 1 }, // 2 hidden under collapsed 1
        .{ .parent = null }, // 3
    };
    try testing.expectEqual(@as(usize, 3), visibleRowCount(&open));
}

test "tree view row index: visible nodes map to rows, hidden nodes map to null" {
    const nodes = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = true }, // 0 -> row 0
        .{ .parent = 0 }, // 1 -> row 1
        .{ .parent = null, .has_children = true, .expanded = false }, // 2 -> row 2
        .{ .parent = 2 }, // 3 hidden
    };
    try testing.expectEqual(@as(?usize, 0), rowIndexOf(&nodes, 0));
    try testing.expectEqual(@as(?usize, 1), rowIndexOf(&nodes, 1));
    try testing.expectEqual(@as(?usize, 2), rowIndexOf(&nodes, 2));
    try testing.expectEqual(@as(?usize, null), rowIndexOf(&nodes, 3));
    try testing.expectEqual(@as(?usize, null), rowIndexOf(&nodes, 42));
}

test "tree view row lookup: nodeAtRow is the inverse of rowIndexOf" {
    const nodes = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = true }, // 0
        .{ .parent = 0 }, // 1
        .{ .parent = null }, // 2
    };
    try testing.expectEqual(@as(?u32, 0), nodeAtRow(&nodes, 0));
    try testing.expectEqual(@as(?u32, 1), nodeAtRow(&nodes, 1));
    try testing.expectEqual(@as(?u32, 2), nodeAtRow(&nodes, 2));
    try testing.expectEqual(@as(?u32, null), nodeAtRow(&nodes, 3));
    for (0..3) |row| {
        const idx = nodeAtRow(&nodes, row) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(?usize, row), rowIndexOf(&nodes, idx));
    }
}

test "tree view indentation: offset is depth times indent" {
    const cfg = Config{ .indent_px = 16.0 };
    try approx(indentOffsetPx(cfg, 0), 0.0);
    try approx(indentOffsetPx(cfg, 1), 16.0);
    try approx(indentOffsetPx(cfg, 3), 48.0);
}

test "tree view hit test: rowAtY maps points to rows" {
    const cfg = Config{ .row_height_px = 24.0 };
    try testing.expectEqual(@as(?usize, 0), rowAtY(cfg, 0.0, 5));
    try testing.expectEqual(@as(?usize, 0), rowAtY(cfg, 23.9, 5));
    try testing.expectEqual(@as(?usize, 1), rowAtY(cfg, 24.0, 5));
    try testing.expectEqual(@as(?usize, 4), rowAtY(cfg, 119.0, 5));
    try testing.expectEqual(@as(?usize, null), rowAtY(cfg, 120.0, 5));
    try testing.expectEqual(@as(?usize, null), rowAtY(cfg, -1.0, 5));
    try testing.expectEqual(@as(?usize, null), rowAtY(cfg, std.math.nan(f32), 5));
}

test "tree view expand: toggleExpanded flips parents and ignores leaves" {
    var nodes = [_]Node{
        .{ .parent = null, .has_children = true, .expanded = false }, // 0
        .{ .parent = 0 }, // 1 leaf
    };
    toggleExpanded(&nodes, 0);
    try testing.expect(nodes[0].expanded);
    toggleExpanded(&nodes, 0);
    try testing.expect(!nodes[0].expanded);
    toggleExpanded(&nodes, 1);
    try testing.expect(!nodes[1].expanded);
    toggleExpanded(&nodes, 77);
}

test "tree view row fill: selected row uses the accent, others are clear" {
    const active = rowFill(true);
    try approx(active.r, theme.accent.r);
    try approx(active.g, theme.accent.g);
    try approx(active.b, theme.accent.b);
    try testing.expect(active.a > 0.0 and active.a < 1.0);
    try approx(rowFill(false).a, 0.0);
}

test "tree view selection: single select clears the others" {
    var sel = [_]bool{ true, false, true, false };
    selectSingle(&sel, 1);
    try testing.expect(!sel[0] and sel[1] and !sel[2] and !sel[3]);
    try testing.expectEqual(@as(usize, 1), selectionCount(&sel));
    selectSingle(&sel, 9);
    try testing.expectEqual(@as(usize, 1), selectionCount(&sel));
}

test "tree view selection: ctrl click toggles one entry" {
    var sel = [_]bool{ false, false, false, false };
    toggleMulti(&sel, 0);
    toggleMulti(&sel, 2);
    try testing.expect(sel[0] and !sel[1] and sel[2] and !sel[3]);
    toggleMulti(&sel, 0);
    try testing.expect(!sel[0] and sel[2]);
    toggleMulti(&sel, 50);
    try testing.expectEqual(@as(usize, 1), selectionCount(&sel));
}

test "tree view selection: shift click selects an inclusive range in either direction" {
    var forward = [_]bool{ false, false, false, false, false };
    selectRange(&forward, 1, 3);
    try testing.expect(!forward[0] and forward[1] and forward[2] and forward[3] and !forward[4]);

    var backward = [_]bool{ false, false, false, false, false };
    selectRange(&backward, 3, 1);
    try testing.expect(!backward[0] and backward[1] and backward[2] and backward[3] and !backward[4]);

    var bad = [_]bool{ false, false, false };
    selectRange(&bad, 0, 9);
    try testing.expectEqual(@as(usize, 0), selectionCount(&bad));
}

test "tree view selection: count of an empty selection is zero" {
    const none = [_]bool{ false, false, false };
    try testing.expectEqual(@as(usize, 0), selectionCount(&none));
}
