//! Piano roll note-editing rules: hit testing, rectangle selection, move and
//! resize snapping, shift-click selection. Pure functions, no allocation, no
//! globals, no UI dependencies.

const std = @import("std");
const testing = std.testing;

/// Smallest resize length when snapping is off (grid <= 0).
pub const min_free_length: f64 = 1.0 / 64.0;

/// Width in pixels of the resize zone at a note's right edge.
pub const edge_zone_px: f32 = 6.0;

/// Axis-aligned rectangle in window pixels (x, y = top-left).
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Which part of a note a point landed on.
pub const Zone = enum { body, right_edge };

/// Result of a hit test: index into the note slice and the zone hit.
pub const Hit = struct { index: usize, zone: Zone };

/// Selection state after a click on a note.
pub const ClickSelection = struct { selected: bool, clear_others: bool };

/// Returns the topmost note under (px, py). Later entries in `notes` are drawn
/// on top, so the last matching rectangle wins. The rightmost `edge_zone_px`
/// pixels (clamped to the note width) are the right-edge zone. Rectangles
/// include their left/top edges and exclude right/bottom.
pub fn hitTest(notes: []const Rect, px: f32, py: f32) ?Hit {
    var i: usize = notes.len;
    while (i > 0) {
        i -= 1;
        const r = notes[i];
        if (px < r.x or px >= r.x + r.w or py < r.y or py >= r.y + r.h) continue;
        const zone_w = @min(edge_zone_px, r.w);
        const zone: Zone = if (px >= r.x + r.w - zone_w) .right_edge else .body;
        return .{ .index = i, .zone = zone };
    }
    return null;
}

/// Builds a positive-size rectangle from two drag corners in any direction.
pub fn normalizeRect(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    return .{
        .x = @min(x0, x1),
        .y = @min(y0, y1),
        .w = @abs(x1 - x0),
        .h = @abs(y1 - y0),
    };
}

/// Beat delta to apply to a selection whose earliest note starts at
/// `earliest_start`. The earliest note's new start is snapped to `grid_beats`
/// and clamped so no note starts before beat 0. Grid <= 0 means no snapping
/// (still clamped).
pub fn snapMoveDelta(earliest_start: f64, raw_delta: f64, grid_beats: f64) f64 {
    const target = @max(earliest_start + raw_delta, 0.0);
    return snapBeat(target, grid_beats) - earliest_start;
}

/// Snaps `beat` to the nearest multiple of `grid_beats`; no snapping when the grid is <= 0.
fn snapBeat(beat: f64, grid_beats: f64) f64 {
    if (!(grid_beats > 0)) return beat;
    return @round(beat / grid_beats) * grid_beats;
}

/// New note length after dragging the right edge by `raw_delta` beats. The
/// end is snapped to the grid; length never drops below one grid step.
pub fn resizeLength(start: f64, length: f64, raw_delta: f64, grid_beats: f64) f64 {
    const end = snapBeat(start + length + raw_delta, grid_beats);
    const min_length: f64 = if (grid_beats > 0) grid_beats else min_free_length;
    return @max(end - start, min_length);
}

/// Selection result of clicking a note. Plain click selects it and clears the
/// rest; shift-click toggles it and keeps the rest.
pub fn clickSelection(was_selected: bool, shift: bool) ClickSelection {
    if (!shift) return .{ .selected = true, .clear_others = true };
    return .{ .selected = !was_selected, .clear_others = false };
}

// ---- tests ------------------------------------------------------------------

test "hitTest: miss returns null" {
    const notes = [_]Rect{.{ .x = 10, .y = 10, .w = 40, .h = 12 }};
    try testing.expect(hitTest(&notes, 5, 15) == null);
    try testing.expect(hitTest(&notes, 20, 30) == null);
    try testing.expect(hitTest(&.{}, 20, 15) == null);
}

test "hitTest: body hit" {
    const notes = [_]Rect{.{ .x = 10, .y = 10, .w = 40, .h = 12 }};
    const h = hitTest(&notes, 20, 15).?;
    try testing.expectEqual(@as(usize, 0), h.index);
    try testing.expectEqual(Zone.body, h.zone);
}

test "hitTest: topmost (last) note wins on overlap" {
    const notes = [_]Rect{
        .{ .x = 10, .y = 10, .w = 40, .h = 12 },
        .{ .x = 20, .y = 10, .w = 40, .h = 12 },
    };
    try testing.expectEqual(@as(usize, 1), hitTest(&notes, 30, 15).?.index);
    try testing.expectEqual(@as(usize, 0), hitTest(&notes, 12, 15).?.index);
}

test "hitTest: right-edge zone is 6 px" {
    const notes = [_]Rect{.{ .x = 10, .y = 10, .w = 40, .h = 12 }};
    try testing.expectEqual(Zone.right_edge, hitTest(&notes, 49.5, 15).?.zone);
    try testing.expectEqual(Zone.right_edge, hitTest(&notes, 44, 15).?.zone);
    try testing.expectEqual(Zone.body, hitTest(&notes, 43.9, 15).?.zone);
    try testing.expect(hitTest(&notes, 50, 15) == null);
}

test "hitTest: narrow note is all edge zone, never outside the rect" {
    const notes = [_]Rect{.{ .x = 10, .y = 10, .w = 4, .h = 12 }};
    try testing.expectEqual(Zone.right_edge, hitTest(&notes, 10, 15).?.zone);
    try testing.expect(hitTest(&notes, 9.9, 15) == null);
}

test "normalizeRect: any drag direction gives the same rectangle" {
    const want = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expectEqual(want, normalizeRect(10, 20, 40, 60));
    try testing.expectEqual(want, normalizeRect(40, 60, 10, 20));
    try testing.expectEqual(want, normalizeRect(40, 20, 10, 60));
    try testing.expectEqual(want, normalizeRect(10, 60, 40, 20));
}

test "normalizeRect: zero-size drag" {
    const r = normalizeRect(5, 5, 5, 5);
    try testing.expectEqual(@as(f32, 0), r.w);
    try testing.expectEqual(@as(f32, 0), r.h);
}

test "snapMoveDelta: new start snaps to grid" {
    try testing.expectApproxEqAbs(@as(f64, 0.5), snapMoveDelta(1.0, 0.4, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), snapMoveDelta(1.0, 0.3, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.25), snapMoveDelta(1.0, -0.2, 0.25), 1e-9);
}

test "snapMoveDelta: off-grid note lands on grid" {
    // start 1.1 + 0.0 snaps to 1.0, so delta is -0.1
    try testing.expectApproxEqAbs(@as(f64, -0.1), snapMoveDelta(1.1, 0.0, 0.25), 1e-9);
}

test "snapMoveDelta: no note may start before beat 0" {
    try testing.expectApproxEqAbs(@as(f64, -1.0), snapMoveDelta(1.0, -5.0, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), snapMoveDelta(0.0, -0.4, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.0), snapMoveDelta(1.0, -5.0, 0.0), 1e-9);
}

test "snapMoveDelta: grid <= 0 disables snapping" {
    try testing.expectApproxEqAbs(@as(f64, 0.37), snapMoveDelta(1.0, 0.37, 0.0), 1e-9);
}

test "resizeLength: end snaps to grid" {
    try testing.expectApproxEqAbs(@as(f64, 1.5), resizeLength(0.0, 1.0, 0.4, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), resizeLength(0.0, 1.0, 0.1, 0.25), 1e-9);
}

test "resizeLength: minimum is one grid step" {
    try testing.expectApproxEqAbs(@as(f64, 0.25), resizeLength(0.0, 1.0, -5.0, 0.25), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), resizeLength(2.0, 1.0, -0.9, 0.5), 1e-9);
}

test "resizeLength: grid <= 0 still keeps a positive length" {
    try testing.expect(resizeLength(0.0, 1.0, -5.0, 0.0) > 0.0);
    try testing.expectApproxEqAbs(@as(f64, 1.3), resizeLength(0.0, 1.0, 0.3, 0.0), 1e-9);
}

test "clickSelection: plain click selects only that note" {
    try testing.expectEqual(ClickSelection{ .selected = true, .clear_others = true }, clickSelection(false, false));
    try testing.expectEqual(ClickSelection{ .selected = true, .clear_others = true }, clickSelection(true, false));
}

test "clickSelection: shift-click toggles and keeps others" {
    try testing.expectEqual(ClickSelection{ .selected = true, .clear_others = false }, clickSelection(false, true));
    try testing.expectEqual(ClickSelection{ .selected = false, .clear_others = false }, clickSelection(true, true));
}
