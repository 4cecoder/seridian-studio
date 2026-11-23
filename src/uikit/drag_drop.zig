//! uikit/drag_drop: drag a payload from one widget and drop it on another,
//! with a drop highlight (Raven drag and drop inside the application).
//!
//! Mode: retained. The source and the target are widgets in the Raven tree;
//! nothing here repaints per frame, so no immediate-mode code is used.
//!
//! Raven calls, declared by hand in this file from vendor/raven/include/raven/
//! raven_window.h (no @cImport). Shared Raven declarations (Rwidget_create,
//! Rborder_*, Rlabel_create) come from raven.zig:
//!   - Rdrag_begin(source, type, data, label): starts a drag from a widget,
//!     called while the button is held after the pointer has moved a little.
//!   - Rdrag_get_type(window): type of the drag in progress, or NULL.
//!   - Rdrag_cancel(window): ends a drag without dropping.
//!   - Rwidget_set_drop_callback(target, RDropCallback, user_data): the drop
//!     callbacks receive R_DROP_ENTER / MOVE / LEAVE / DROPPED, with
//!     RDropEvent.drag_type. Returning non-zero accepts; the target is
//!     highlighted by Raven while it would accept.
//!
//! Mode: retained. The source and the target are widgets in the Raven tree
//! (surfaces built by createSurface); nothing here repaints per frame, so no
//! immediate-mode code is used.
//!
//! Liquid glass (theme.zig, applied through style.zig): translucent layered
//! fill (GlassLayer alpha), a soft shadow, corner radius 10-14 px, the accent
//! colour for the active (drop-target) state, and text never below 12 px. The
//! 1 px top highlight is an all-round outline in Raven's border API (there is
//! no top-edge-only outline), so it is drawn on all four edges.
//!
//! Lifetime: the payload type stored by attachTarget is referenced by the
//! widget, so it must be a string that outlives the widget (a literal or a
//! long-lived buffer).
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");
const style = @import("style.zig");

const Rid = raven.Rid;

// raven_window.h: RDropPhase (sequential from R_DROP_ENTER).
pub const DropPhase = enum(c_int) {
    enter = 0x00E0,
    move = 0x00E1,
    leave = 0x00E2,
    dropped = 0x00E3,
    _,
};

// raven_window.h: RDropEvent.
pub const DropEvent = extern struct {
    phase: DropPhase,
    window: Rid,
    x: f32,
    y: f32,
    local_x: f32,
    local_y: f32,
    paths: ?[*]const [*:0]const u8,
    path_count: c_int,
    text: ?[*:0]const u8,
    drag_type: ?[*:0]const u8,
    drag_source: Rid,
};

// raven_window.h: RDropCallback.
pub const DropCallback = *const fn (target: Rid, event: *const DropEvent, user_data: ?*anyopaque) callconv(.c) c_int;

// raven_window.h: in-application drag and drop.
extern fn Rdrag_begin(source: Rid, drag_type: [*:0]const u8, data: [*:0]const u8, label: [*:0]const u8) c_int;
extern fn Rdrag_get_type(window: Rid) ?[*:0]const u8;
extern fn Rdrag_cancel(window: Rid) void;

// raven_widget.h: Rwidget_set_drop_callback.
extern fn Rwidget_set_drop_callback(widget: Rid, callback: ?DropCallback, user_data: ?*anyopaque) void;

/// Configuration of a drag and drop widget (source or target, or both).
/// Defaults follow the liquid-glass rules in theme.zig.
pub const Config = struct {
    /// Payload type, matched against the drop target's accepted type.
    /// Empty: the widget is not a drag source.
    payload_type: [:0]const u8 = "",
    /// Text shown on the drag label that follows the pointer.
    label: [:0]const u8 = "",
    /// Corner radius in px; sanitize() clamps it into [10, 14].
    radius: f32 = theme.radius_control,
    /// Text size in px; sanitize() raises it to at least 12.
    font_px: f32 = theme.font_body_px,
    /// Glass layer the fill is drawn on.
    glass_layer: theme.GlassLayer = .raised,
    /// Colour of the drop highlight and the active state.
    highlight_color: theme.Color = theme.accent,
    /// False: the widget neither starts drags nor accepts drops.
    enabled: bool = true,
};

/// Returns `cfg` with radius clamped into [radius_min, radius_max] and
/// font_px raised to min_font_px. NaN radius or font gives the floor.
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    out.radius = theme.clampRadius(cfg.radius);
    out.font_px = theme.clampFontSize(cfg.font_px);
    return out;
}

/// True when a drag of `dragged` type may be dropped on a target that accepts
/// `accepted`. A null drag, or an empty accepted type, never matches.
pub fn acceptsDrop(accepted: []const u8, dragged: ?[]const u8) bool {
    const d = dragged orelse return false;
    if (accepted.len == 0) return false;
    return std.mem.eql(u8, accepted, d);
}

/// Selected index clamped into a list of `count` items. Null when count is 0.
pub fn clampSelection(index: usize, count: usize) ?usize {
    if (count == 0) return null;
    return @min(index, count - 1);
}

/// Insertion slot (0..count) for a drop at pointer `pointer_y` over a list of
/// `count` rows of height `row_height`. The slot is the nearest row boundary:
/// the upper half of a row drops before it, the lower half after it.
/// Positions above the list give 0, below it give count. row_height <= 0 or
/// NaN give 0.
pub fn dropSlot(pointer_y: f32, row_height: f32, count: usize) usize {
    // Written as negated comparisons so that NaN takes the zero branch.
    if (!(row_height > 0.0) or !(pointer_y >= 0.0)) return 0;
    const slot_f = @floor(pointer_y / row_height + 0.5);
    const limit: f32 = @floatFromInt(count);
    if (!(slot_f < limit)) return count;
    return @intFromFloat(slot_f);
}

/// Index of the item `from` after it is moved to insertion slot `slot` in a
/// list of `count` items (slot in 0..count). Moving down shifts the target by
/// one because the item leaves its old place first. A drop onto its own slot
/// or the one after it leaves it in place.
pub fn indexAfterMove(from: usize, slot: usize, count: usize) usize {
    if (count == 0) return 0;
    const s = @min(slot, count);
    if (s <= from) return s;
    // Dropping just below itself: the item stays where it is.
    if (s == from + 1) return from;
    return s - 1;
}

// ---- retained widgets (Raven tree) ----

/// Starts a drag of `data` from `source` with the payload type and label of
/// `cfg`. Call it while the button is held after the pointer has moved a
/// little. Returns false when the widget is disabled or has no payload type.
pub fn beginDrag(source: Rid, cfg: Config, data: [:0]const u8) bool {
    if (!cfg.enabled or cfg.payload_type.len == 0) return false;
    return Rdrag_begin(source, cfg.payload_type.ptr, data.ptr, cfg.label.ptr) != 0;
}

/// Type of the drag in progress in `window`, or null when none is.
pub fn activeDragType(window: Rid) ?[]const u8 {
    const t = Rdrag_get_type(window) orelse return null;
    return std.mem.span(t);
}

/// Ends the drag in progress in `window` without dropping.
pub fn cancelDrag(window: Rid) void {
    Rdrag_cancel(window);
}

/// Creates a glass surface (a Raven Border) for a drag and drop widget, with
/// its label when `cfg.label` is not empty. The label is at least 12 px.
pub fn createSurface(cfg: Config) Rid {
    const c = sanitize(cfg);
    const surface = raven.Rwidget_create(.border);
    style.styleGlassBorder(surface, c.glass_layer, c.radius);
    setDropHighlight(surface, false);
    if (c.label.len > 0) {
        const lbl = raven.Rlabel_create(c.label.ptr);
        style.styleLabel(lbl, c.font_px);
        _ = raven.Rwidget_add_child(surface, lbl);
    }
    return surface;
}

/// Shows the drop highlight on a surface: the accent outline when `on`, the
/// 1 px top-edge highlight colour otherwise.
pub fn setDropHighlight(surface: Rid, on: bool) void {
    const c = if (on) theme.accent else theme.highlight;
    raven.Rborder_set_outline(surface, theme.highlight_px, c.r, c.g, c.b, c.a);
}

/// Makes `target` a drop target that accepts drags whose type equals
/// `cfg.payload_type`. Raven highlights the target while a drop would be
/// accepted; this callback also draws the accent highlight on enter and clears
/// it on leave or drop. A disabled config removes the callback.
pub fn attachTarget(target: Rid, cfg: Config) void {
    const c = sanitize(cfg);
    if (!c.enabled) {
        Rwidget_set_drop_callback(target, null, null);
        return;
    }
    const ud: ?*anyopaque = @ptrCast(@constCast(c.payload_type.ptr));
    Rwidget_set_drop_callback(target, onDrop, ud);
}

/// Drop callback. `user_data` is the NUL-terminated accepted payload type
/// passed by attachTarget.
fn onDrop(target: Rid, event: *const DropEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const raw = user_data orelse return 0;
    const accepted = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    const dragged: ?[]const u8 = if (event.drag_type) |t| std.mem.span(t) else null;
    const ok = acceptsDrop(accepted, dragged);
    switch (event.phase) {
        .enter, .move => setDropHighlight(target, ok),
        .leave, .dropped => setDropHighlight(target, false),
        _ => {},
    }
    return @intFromBool(ok);
}

test "drag_drop configuration: defaults" {
    const cfg = Config{};
    try testing.expectEqualStrings("", cfg.payload_type);
    try testing.expectEqualStrings("", cfg.label);
    try testing.expectEqual(theme.radius_control, cfg.radius);
    try testing.expectEqual(theme.font_body_px, cfg.font_px);
    try testing.expectEqual(theme.GlassLayer.raised, cfg.glass_layer);
    try testing.expect(cfg.enabled);
}

test "drag_drop configuration: radius is clamped into 10..14" {
    var cfg = Config{ .radius = 3.0 };
    try testing.expectEqual(theme.radius_min, sanitize(cfg).radius);
    cfg.radius = 40.0;
    try testing.expectEqual(theme.radius_max, sanitize(cfg).radius);
    cfg.radius = 12.0;
    try testing.expectEqual(@as(f32, 12.0), sanitize(cfg).radius);
    cfg.radius = std.math.nan(f32);
    try testing.expectEqual(theme.radius_min, sanitize(cfg).radius);
}

test "drag_drop configuration: text never below 12 px" {
    var cfg = Config{ .font_px = 9.0 };
    try testing.expectEqual(theme.min_font_px, sanitize(cfg).font_px);
    cfg.font_px = 16.0;
    try testing.expectEqual(@as(f32, 16.0), sanitize(cfg).font_px);
}

test "drag_drop configuration: sanitize keeps the other fields" {
    const cfg = Config{
        .payload_type = "clip",
        .label = "Kick",
        .glass_layer = .overlay,
        .enabled = false,
    };
    const out = sanitize(cfg);
    try testing.expectEqualStrings("clip", out.payload_type);
    try testing.expectEqualStrings("Kick", out.label);
    try testing.expectEqual(theme.GlassLayer.overlay, out.glass_layer);
    try testing.expect(!out.enabled);
}

test "drag_drop acceptance: matching type only" {
    try testing.expect(acceptsDrop("clip", "clip"));
    try testing.expect(!acceptsDrop("clip", "sample"));
    try testing.expect(!acceptsDrop("clip", null));
}

test "drag_drop acceptance: empty accepted type accepts nothing" {
    try testing.expect(!acceptsDrop("", ""));
    try testing.expect(!acceptsDrop("", "clip"));
}

test "drag_drop selection: clamped into the list" {
    try testing.expectEqual(@as(?usize, 0), clampSelection(0, 3));
    try testing.expectEqual(@as(?usize, 2), clampSelection(2, 3));
    try testing.expectEqual(@as(?usize, 2), clampSelection(9, 3));
}

test "drag_drop selection: empty list has no selection" {
    try testing.expectEqual(@as(?usize, null), clampSelection(0, 0));
    try testing.expectEqual(@as(?usize, null), clampSelection(5, 0));
}

test "drag_drop index maths: drop slot is the nearest row boundary" {
    // Rows of 20 px, 4 rows. Upper half of row 1 is slot 1, lower half slot 2.
    try testing.expectEqual(@as(usize, 0), dropSlot(4.0, 20.0, 4));
    try testing.expectEqual(@as(usize, 1), dropSlot(26.0, 20.0, 4));
    try testing.expectEqual(@as(usize, 2), dropSlot(34.0, 20.0, 4));
}

test "drag_drop index maths: drop slot is clamped to the list" {
    try testing.expectEqual(@as(usize, 0), dropSlot(-50.0, 20.0, 4));
    try testing.expectEqual(@as(usize, 4), dropSlot(500.0, 20.0, 4));
    try testing.expectEqual(@as(usize, 0), dropSlot(10.0, 0.0, 4));
    try testing.expectEqual(@as(usize, 0), dropSlot(std.math.nan(f32), 20.0, 4));
}

test "drag_drop index maths: index after a move" {
    // Moving down: the item leaves its place, so the target shifts by one.
    try testing.expectEqual(@as(usize, 2), indexAfterMove(1, 3, 5));
    // Moving up: no shift.
    try testing.expectEqual(@as(usize, 1), indexAfterMove(3, 1, 5));
    // Dropping onto its own slot or the one after it: stays in place.
    try testing.expectEqual(@as(usize, 2), indexAfterMove(2, 2, 5));
    try testing.expectEqual(@as(usize, 2), indexAfterMove(2, 3, 5));
    // Last item moved to the end stays last.
    try testing.expectEqual(@as(usize, 4), indexAfterMove(0, 5, 5));
}
