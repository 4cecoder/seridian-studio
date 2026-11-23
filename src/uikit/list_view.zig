//! uikit/list_view: Rlist_view (R_WIDGET_LIST_VIEW).
//!
//! Mode: retained. The widget is created with Rwidget_create (or the Rxxx_create
//! shortcut) and placed in the tree; nothing here repaints per frame, so no
//! immediate-mode paint callback is used.
//! Raven calls (declared below, by hand, no @cImport): Rwidget_create(list_view),
//! Rlist_view_add_item, Rlist_view_get_item_count, Rlist_view_set_virtual_items,
//! Rlist_view_set_selected, Rlist_view_get_selected, Rlist_view_scroll_to_item,
//! Rlist_view_set_selection_changed_callback, Rlist_view_set_activated_callback.
//! Behaviour: scrollable rows, single selection, keyboard Up/Down move the
//! selection, double click (or Enter) fires the activated callback.
//! Liquid glass: translucent layered fill (theme.glassAlpha), 1 px top highlight,
//! soft shadow, corner radius in [10, 14], accent colour for the active row,
//! text never below 12 px.
//! State transitions use Raven's own springs; theme.transition_ms (120 ms) is
//! the target feel, see docs/development/uikit.md.
//!
//! Status: configuration rules, pure index maths, and the retained Raven widget
//! glue (create / applyConfig / moveSelection and the callback setters). The
//! glue is only analysed when called, so `zig test` on this file needs no Raven
//! library linked.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

// ---------------------------------------------------------------------------
// Raven externs (hand-declared, matching vendor/raven/include/raven/raven_controls.h).
// ---------------------------------------------------------------------------

/// Row-text callback for virtual mode. The returned string must stay valid until the next call.
pub const ItemTextCallback = *const fn (list_view: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) ?[*:0]const u8;
/// Selection-changed and activated callbacks share this shape (index is -1 when nothing is selected).
pub const EventCallback = *const fn (list_view: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void;

pub extern fn Rlist_view_add_item(list_view: raven.Rid, text: [*:0]const u8) c_int;
pub extern fn Rlist_view_get_item_count(list_view: raven.Rid) c_int;
pub extern fn Rlist_view_set_virtual_items(list_view: raven.Rid, count: c_int, callback: ?ItemTextCallback, user_data: ?*anyopaque) void;
pub extern fn Rlist_view_set_selected(list_view: raven.Rid, index: c_int) void;
pub extern fn Rlist_view_get_selected(list_view: raven.Rid) c_int;
pub extern fn Rlist_view_scroll_to_item(list_view: raven.Rid, index: c_int) void;
pub extern fn Rlist_view_set_selection_changed_callback(list_view: raven.Rid, cb: ?EventCallback, user_data: ?*anyopaque) void;
pub extern fn Rlist_view_set_activated_callback(list_view: raven.Rid, cb: ?EventCallback, user_data: ?*anyopaque) void;

/// R_WIDGET_LIST_VIEW (raven_widget.h). The RWidgetType enum starts at
/// R_WIDGET_VBOX = 0x0200 and counts up; LIST_VIEW is the 26th entry (0x0219).
/// Checked against the CHECKBOX..SEPARATOR values already in raven.zig.
pub const widget_kind: raven.WidgetType = @fromBackingInt(@intCast(0x0219));

/// Creates the retained list widget with a sanitized configuration applied.
/// Returns raven.invalid if Raven could not create the widget.
pub fn create(cfg: Config) raven.Rid {
    const rid = raven.Rwidget_create(widget_kind);
    if (rid == raven.invalid) return rid;
    applyConfig(rid, cfg);
    return rid;
}

/// Pushes the (sanitized) configuration into Raven's style API. Idempotent.
/// Colours and materials come from theme tokens; nothing is painted per frame.
pub fn applyConfig(rid: raven.Rid, cfg: Config) void {
    const c = sanitize(cfg);
    const fill = theme.withAlpha(theme.bg_panel, theme.glassAlpha(c.glass_layer));
    const sel = rowFill(true);
    raven.Rwidget_set_enabled(rid, @intFromBool(c.enabled));
    raven.Rwidget_set_focusable(rid, 1);
    raven.Rwidget_set_material(rid, .glass);
    raven.Rwidget_set_metric(rid, .font_size, c.font_px);
    raven.Rwidget_set_metric(rid, .corner_radius, c.radius_px);
    raven.Rwidget_set_metric(rid, .row_height, c.row_height_px);
    raven.Rwidget_set_metric(rid, .glass_rim, theme.highlight_px);
    raven.Rwidget_set_metric(rid, .glass_shadow, theme.shadow_blur_px);
    raven.Rwidget_set_metric(rid, .blur_radius, theme.blur_radius_px);
    raven.Rwidget_set_color(rid, .panel, fill.r, fill.g, fill.b, fill.a);
    raven.Rwidget_set_color(rid, .text, theme.text.r, theme.text.g, theme.text.b, theme.text.a);
    raven.Rwidget_set_color(rid, .accent, c.accent.r, c.accent.g, c.accent.b, c.accent.a);
    raven.Rwidget_set_color(rid, .selection, sel.r, sel.g, sel.b, sel.a);
}

/// Keyboard Up/Down: step is +1 (Down) or -1 (Up). Moves the selection with
/// stepSelection, then scrolls the new row into view.
pub fn moveSelection(rid: raven.Rid, step: i32) void {
    const count_raw = Rlist_view_get_item_count(rid);
    const count: usize = if (count_raw > 0) @intCast(count_raw) else 0;
    const current: i32 = @intCast(Rlist_view_get_selected(rid));
    const next = stepSelection(current, step, count);
    Rlist_view_set_selected(rid, @intCast(next));
    if (next >= 0) Rlist_view_scroll_to_item(rid, @intCast(next));
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const SelectionMode = enum { none, single };

/// Padding added above and below the text when computing the minimum row height.
pub const row_padding_px: f32 = 8.0;
/// Smallest row height the widget will use (logical px), regardless of font.
pub const min_row_height_px: f32 = 20.0;
pub const default_row_height_px: f32 = 28.0;
/// Double-click window bounds (ms).
pub const min_double_click_ms: u32 = 150;
pub const max_double_click_ms: u32 = 1000;
pub const default_double_click_ms: u32 = 400;

pub const Config = struct {
    row_height_px: f32 = default_row_height_px,
    font_px: f32 = theme.font_body_px,
    radius_px: f32 = theme.radius_control,
    glass_layer: theme.GlassLayer = .base,
    accent: theme.Color = theme.accent,
    selection: SelectionMode = .single,
    enabled: bool = true,
    double_click_ms: u32 = default_double_click_ms,
};

/// Returns a copy of `cfg` with every rule applied:
///   - font_px is raised to at least theme.min_font_px (12); NaN gives 12
///   - radius_px is clamped into [theme.radius_min, theme.radius_max]; NaN gives radius_min
///   - row_height_px is at least max(min_row_height_px, font_px + row_padding_px); NaN gives that floor
///   - double_click_ms is clamped into [min_double_click_ms, max_double_click_ms]
/// selection, enabled, glass_layer and accent are passed through unchanged.
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.radius_px = theme.clampRadius(cfg.radius_px);
    const floor_px = @max(min_row_height_px, out.font_px + row_padding_px);
    // Written as a negated >= so that NaN takes the floor.
    out.row_height_px = if (!(cfg.row_height_px >= floor_px)) floor_px else cfg.row_height_px;
    out.double_click_ms = std.math.clamp(cfg.double_click_ms, min_double_click_ms, max_double_click_ms);
    return out;
}

test "list_view configuration: defaults" {
    const cfg = Config{};
    try testing.expectEqual(@as(f32, 28.0), cfg.row_height_px);
    try testing.expectEqual(@as(f32, 13.0), cfg.font_px);
    try testing.expectEqual(theme.radius_control, cfg.radius_px);
    try testing.expectEqual(theme.GlassLayer.base, cfg.glass_layer);
    try testing.expectEqual(theme.accent, cfg.accent);
    try testing.expectEqual(SelectionMode.single, cfg.selection);
    try testing.expect(cfg.enabled);
    try testing.expectEqual(@as(u32, 400), cfg.double_click_ms);
    // Defaults must already satisfy every rule, so sanitize is a no-op on them.
    try testing.expectEqual(cfg, sanitize(cfg));
}

test "list_view configuration: font never below 12 px" {
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .font_px = 11.0 }).font_px);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .font_px = 0.0 }).font_px);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .font_px = std.math.nan(f32) }).font_px);
    try testing.expectEqual(@as(f32, 16.0), sanitize(.{ .font_px = 16.0 }).font_px);
}

test "list_view configuration: radius clamped to 10..14" {
    try testing.expectEqual(@as(f32, 10.0), sanitize(.{ .radius_px = 2.0 }).radius_px);
    try testing.expectEqual(@as(f32, 14.0), sanitize(.{ .radius_px = 20.0 }).radius_px);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .radius_px = 12.0 }).radius_px);
    try testing.expectEqual(@as(f32, 10.0), sanitize(.{ .radius_px = std.math.nan(f32) }).radius_px);
}

test "list_view configuration: row height floor follows font" {
    // Small row is raised to min_row_height_px (20) when font is 13 (13 + 8 = 21, so 21 wins).
    try testing.expectEqual(@as(f32, 21.0), sanitize(.{ .row_height_px = 10.0, .font_px = 13.0 }).row_height_px);
    // Large font raises the floor above min_row_height_px: 16 + 8 = 24.
    try testing.expectEqual(@as(f32, 24.0), sanitize(.{ .row_height_px = 18.0, .font_px = 16.0 }).row_height_px);
    // A row already tall enough is kept.
    try testing.expectEqual(@as(f32, 40.0), sanitize(.{ .row_height_px = 40.0, .font_px = 13.0 }).row_height_px);
    // NaN gives the floor.
    try testing.expectEqual(@as(f32, 21.0), sanitize(.{ .row_height_px = std.math.nan(f32), .font_px = 13.0 }).row_height_px);
}

test "list_view configuration: double-click window clamped" {
    try testing.expectEqual(@as(u32, 150), sanitize(.{ .double_click_ms = 0 }).double_click_ms);
    try testing.expectEqual(@as(u32, 1000), sanitize(.{ .double_click_ms = 5000 }).double_click_ms);
    try testing.expectEqual(@as(u32, 400), sanitize(.{ .double_click_ms = 400 }).double_click_ms);
}

test "list_view configuration: sanitize keeps selection, enabled, glass and accent" {
    const in = Config{
        .selection = .none,
        .enabled = false,
        .glass_layer = .overlay,
        .accent = theme.accent_magenta,
    };
    const out = sanitize(in);
    try testing.expectEqual(SelectionMode.none, out.selection);
    try testing.expect(!out.enabled);
    try testing.expectEqual(theme.GlassLayer.overlay, out.glass_layer);
    try testing.expectEqual(theme.accent_magenta, out.accent);
}

// ---------------------------------------------------------------------------
// Pure index maths
// ---------------------------------------------------------------------------

/// Clamps a row index to the valid selection range. Returns -1 (nothing selected)
/// when row_count is 0 or index is negative. Indices past the end give the last row.
pub fn clampSelection(index: i32, row_count: usize) i32 {
    const last = lastRow(row_count);
    if (last < 0 or index < 0) return -1;
    return @min(index, last);
}

/// Index of the last row, or -1 when there are no rows. Counts above i32 max are capped.
fn lastRow(row_count: usize) i32 {
    if (row_count == 0) return -1;
    const n: usize = @min(row_count, std.math.maxInt(i32));
    return @intCast(n - 1);
}

/// Keyboard step. `step` is +1 for Down, -1 for Up (any integer works).
/// No wrap-around: the result stays in [0, row_count - 1].
/// From no selection (-1), a positive step selects the first row and a negative
/// step selects the last row. step == 0 returns clampSelection(current, row_count).
/// row_count == 0 always returns -1.
pub fn stepSelection(current: i32, step: i32, row_count: usize) i32 {
    const last = lastRow(row_count);
    if (last < 0) return -1;
    const cur = clampSelection(current, row_count);
    if (step == 0) return cur;
    if (cur < 0) return if (step > 0) 0 else last;
    const target = @as(i64, cur) + @as(i64, step);
    if (target < 0) return 0;
    if (target > last) return last;
    return @intCast(target);
}

/// Total scrollable content height in logical px.
pub fn contentHeight(row_count: usize, row_height: f32) f32 {
    if (!(row_height > 0.0)) return 0.0;
    return @as(f32, @floatFromInt(row_count)) * row_height;
}

/// Largest valid scroll offset: max(0, content height - viewport height).
pub fn maxScroll(row_count: usize, row_height: f32, viewport_height: f32) f32 {
    const overflow = contentHeight(row_count, row_height) - viewport_height;
    if (!(overflow > 0.0)) return 0.0;
    return overflow;
}

/// Clamps a scroll offset into [0, maxScroll]. NaN gives 0.
pub fn clampScroll(scroll_y: f32, row_count: usize, row_height: f32, viewport_height: f32) f32 {
    // Negated >= so that NaN takes the 0 floor.
    if (!(scroll_y >= 0.0)) return 0.0;
    return @min(scroll_y, maxScroll(row_count, row_height, viewport_height));
}

/// Hit test. y is in viewport coordinates (0 at the top of the visible area).
/// Returns the row index under y, or -1 for a point above the list, below the
/// last row, or when row_height <= 0.
pub fn rowAtPoint(y: f32, scroll_y: f32, row_height: f32, row_count: usize) i32 {
    if (!(row_height > 0.0)) return -1;
    const content_y = y + scroll_y;
    if (!(content_y >= 0.0)) return -1;
    const row = @floor(content_y / row_height);
    const count_f = @as(f32, @floatFromInt(row_count));
    const max_f = @as(f32, @floatFromInt(std.math.maxInt(i32)));
    // Negated >= so that NaN is rejected before the float-to-int cast.
    if (!(row >= 0.0) or row >= count_f or row >= max_f) return -1;
    return @intFromFloat(row);
}

/// Smallest scroll offset change that makes row `index` fully visible, returned
/// as the new (clamped) scroll offset. A negative index leaves scroll unchanged
/// (clamped).
pub fn scrollToReveal(index: i32, scroll_y: f32, row_count: usize, row_height: f32, viewport_height: f32) f32 {
    const current = clampScroll(scroll_y, row_count, row_height, viewport_height);
    const row = clampSelection(index, row_count);
    if (row < 0) return current;
    const top = @as(f32, @floatFromInt(row)) * row_height;
    const bottom = top + row_height;
    var next = current;
    if (top < current) {
        next = top;
    } else if (bottom > current + viewport_height) {
        next = bottom - viewport_height;
    }
    return clampScroll(next, row_count, row_height, viewport_height);
}

/// True when `row` is the same row as `prev_row` (both >= 0) and the second click
/// arrived within `window_ms` (inclusive) of the first.
pub fn isDoubleClick(prev_row: i32, row: i32, elapsed_ms: u32, window_ms: u32) bool {
    return prev_row >= 0 and row >= 0 and prev_row == row and elapsed_ms <= window_ms;
}

/// Selection fill of a row: the accent at low alpha when selected (the active
/// state), fully transparent otherwise. Alpha stays in [0, 1].
pub fn rowFill(selected: bool) theme.Color {
    return theme.withAlpha(theme.accent, if (selected) 0.18 else 0.0);
}

test "list_view selection: clampSelection" {
    try testing.expectEqual(@as(i32, -1), clampSelection(0, 0));
    try testing.expectEqual(@as(i32, -1), clampSelection(5, 0));
    try testing.expectEqual(@as(i32, -1), clampSelection(-1, 5));
    try testing.expectEqual(@as(i32, -1), clampSelection(-7, 5));
    try testing.expectEqual(@as(i32, 0), clampSelection(0, 5));
    try testing.expectEqual(@as(i32, 4), clampSelection(4, 5));
    try testing.expectEqual(@as(i32, 4), clampSelection(9, 5));
}

test "list_view selection: keyboard up/down" {
    // Down from nothing selects the first row, Up from nothing selects the last.
    try testing.expectEqual(@as(i32, 0), stepSelection(-1, 1, 3));
    try testing.expectEqual(@as(i32, 2), stepSelection(-1, -1, 3));
    // Normal movement.
    try testing.expectEqual(@as(i32, 1), stepSelection(0, 1, 3));
    try testing.expectEqual(@as(i32, 0), stepSelection(1, -1, 3));
    // No wrap at either end.
    try testing.expectEqual(@as(i32, 2), stepSelection(2, 1, 3));
    try testing.expectEqual(@as(i32, 0), stepSelection(0, -1, 3));
    // Single row list stays put.
    try testing.expectEqual(@as(i32, 0), stepSelection(0, 1, 1));
    try testing.expectEqual(@as(i32, 0), stepSelection(0, -1, 1));
    // Zero step and empty list.
    try testing.expectEqual(@as(i32, 0), stepSelection(0, 0, 3));
    try testing.expectEqual(@as(i32, -1), stepSelection(-1, 0, 3));
    try testing.expectEqual(@as(i32, -1), stepSelection(0, 1, 0));
    try testing.expectEqual(@as(i32, -1), stepSelection(-1, -1, 0));
}

test "list_view scroll: content height and max scroll" {
    try testing.expectApproxEqAbs(@as(f32, 200.0), contentHeight(10, 20.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), contentHeight(0, 20.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80.0), maxScroll(10, 20.0, 120.0), 0.001);
    // Viewport taller than content: nothing to scroll.
    try testing.expectApproxEqAbs(@as(f32, 0.0), maxScroll(10, 20.0, 300.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), maxScroll(0, 20.0, 120.0), 0.001);
}

test "list_view scroll: clampScroll" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), clampScroll(-5.0, 10, 20.0, 120.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30.0), clampScroll(30.0, 10, 20.0, 120.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80.0), clampScroll(500.0, 10, 20.0, 120.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), clampScroll(std.math.nan(f32), 10, 20.0, 120.0), 0.001);
}

test "list_view hit test: rowAtPoint" {
    // Scroll 0, row height 20, 10 rows (0..200).
    try testing.expectEqual(@as(i32, 0), rowAtPoint(0.0, 0.0, 20.0, 10));
    try testing.expectEqual(@as(i32, 0), rowAtPoint(19.9, 0.0, 20.0, 10));
    try testing.expectEqual(@as(i32, 1), rowAtPoint(20.0, 0.0, 20.0, 10));
    try testing.expectEqual(@as(i32, 9), rowAtPoint(199.9, 0.0, 20.0, 10));
    // Past the last row, above the list, or zero row height.
    try testing.expectEqual(@as(i32, -1), rowAtPoint(200.0, 0.0, 20.0, 10));
    try testing.expectEqual(@as(i32, -1), rowAtPoint(-1.0, 0.0, 20.0, 10));
    try testing.expectEqual(@as(i32, -1), rowAtPoint(5.0, 0.0, 0.0, 10));
    // Scrolled by 45 px: viewport y 0 is content y 45, which is row 2.
    try testing.expectEqual(@as(i32, 2), rowAtPoint(0.0, 45.0, 20.0, 10));
    try testing.expectEqual(@as(i32, 4), rowAtPoint(35.0, 45.0, 20.0, 10));
}

test "list_view scroll: scrollToReveal keeps the row visible" {
    // 10 rows of 20 px, viewport 60 px, max scroll 140.
    // Row above the visible top: scroll up to its top edge.
    try testing.expectApproxEqAbs(@as(f32, 0.0), scrollToReveal(0, 40.0, 10, 20.0, 60.0), 0.001);
    // Row below the visible area: scroll so its bottom edge meets the viewport bottom.
    try testing.expectApproxEqAbs(@as(f32, 60.0), scrollToReveal(5, 0.0, 10, 20.0, 60.0), 0.001);
    // Row already fully visible: no change.
    try testing.expectApproxEqAbs(@as(f32, 0.0), scrollToReveal(1, 0.0, 10, 20.0, 60.0), 0.001);
    // Last row is clamped to max scroll.
    try testing.expectApproxEqAbs(@as(f32, 140.0), scrollToReveal(9, 0.0, 10, 20.0, 60.0), 0.001);
    // Negative index: scroll is only clamped.
    try testing.expectApproxEqAbs(@as(f32, 140.0), scrollToReveal(-1, 500.0, 10, 20.0, 60.0), 0.001);
}

test "list_view activation: double-click window" {
    try testing.expect(isDoubleClick(3, 3, 300, 400));
    // Window bound is inclusive.
    try testing.expect(isDoubleClick(3, 3, 400, 400));
    try testing.expect(!isDoubleClick(3, 3, 401, 400));
    // Different row, or no previous row, is never a double click.
    try testing.expect(!isDoubleClick(3, 4, 100, 400));
    try testing.expect(!isDoubleClick(-1, 3, 100, 400));
    // Nothing-selected click is never a double click.
    try testing.expect(!isDoubleClick(-1, -1, 0, 400));
}
