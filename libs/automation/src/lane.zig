// Translated to Zig from soundcraft/crates/model/src/automation.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Breakpoint automation lanes: value lookup, point editing, range writes, thinning and shifting.
//!
//! Seridian changes from the Rust original:
//! - positions are f64 beats, not i64 samples; values are the parameter's natural range;
//! - each point carries a `Curve` (hold, linear, exponential, s_curve) for the segment to the next point;
//! - editing takes an allocator (control thread). `valueAt`/`evaluate` read a plain slice, so the
//!   audio thread can evaluate an immutable snapshot without touching the list.

const std = @import("std");
const testing = std.testing;
const modes = @import("modes.zig");
const AutoParam = modes.AutoParam;

// ---------------------------------------------------------------------------
// Tests (ported first; the implementation below was written to satisfy them)
// ---------------------------------------------------------------------------

/// Test grid: 100 Rust samples = 1 beat. A Rust sample position `s` becomes `beats(s)`.
fn beats(samples: f64) f64 {
    return samples / 100.0;
}

test "interpolation_and_steps" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, -3.0), l.valueAt(beats(10), -3.0));
    try l.setPoint(testing.allocator, beats(0), 0.0);
    try l.setPoint(testing.allocator, beats(100), -10.0);
    try testing.expect(@abs(l.valueAt(beats(50), 0.0) + 5.0) < 1e-6);
    try testing.expectEqual(@as(f32, -10.0), l.valueAt(beats(1000), 0.0));

    var m = AutomationLane.init(.mute);
    defer m.deinit(testing.allocator);
    try m.setPoint(testing.allocator, beats(0), 0.0);
    try m.setPoint(testing.allocator, beats(100), 1.0);
    // Mute lanes step: the value changes exactly at the second point.
    try testing.expectEqual(@as(f32, 0.0), m.valueAt(beats(99), 0.0));
    try testing.expectEqual(@as(f32, 1.0), m.valueAt(beats(100), 0.0));
}

test "write_range_keeps_point_right_after_end" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, beats(0), 0.0);
    try l.setPoint(testing.allocator, beats(11), -100.0);
    try l.writeRange(testing.allocator, beats(2), beats(10), -20.0, 0.0);
    try testing.expectEqual(@as(f32, -100.0), l.valueAt(beats(11), 0.0));
}

test "write_range_preserves_outside" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, beats(0), 0.0);
    try l.setPoint(testing.allocator, beats(1000), 0.0);
    try l.writeRange(testing.allocator, beats(200), beats(400), -20.0, 0.0);
    try testing.expectEqual(@as(f32, 0.0), l.valueAt(beats(100), 0.0));
    try testing.expectEqual(@as(f32, -20.0), l.valueAt(beats(300), 0.0));
    try testing.expectEqual(@as(f32, 0.0), l.valueAt(beats(600), 0.0));
}

test "thin_removes_collinear" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    for (0..11) |i| {
        const s: f64 = @floatFromInt(i * 10);
        try l.setPoint(testing.allocator, beats(s), -@as(f32, @floatFromInt(i)));
    }
    try testing.expectEqual(@as(usize, 9), try l.thin(testing.allocator, 0.01));
    try testing.expectEqual(@as(usize, 2), l.points.items.len);
}

test "thin_keeps_removed_points_within_tolerance" {
    for ([_]f32{ 1.0, -1.0 }) |direction| {
        var lane = AutomationLane.init(.volume);
        defer lane.deinit(testing.allocator);
        const pts = [_]struct { at: f64, value: f32 }{
            .{ .at = 0, .value = 0.0 },
            .{ .at = 100, .value = 0.0 },
            .{ .at = 200, .value = 0.0 },
            .{ .at = 300, .value = 0.12 },
            .{ .at = 400, .value = 0.26 },
        };
        for (pts) |p| try lane.setPoint(testing.allocator, beats(p.at), p.value * direction);
        const original = try testing.allocator.dupe(AutomationPoint, lane.points.items);
        defer testing.allocator.free(original);
        const tolerance: f32 = 0.1;
        try testing.expect((try lane.thin(testing.allocator, tolerance)) > 0);
        for (original) |point| {
            const err = @abs(lane.valueAt(point.at, 0.0) - point.value);
            try testing.expect(err <= tolerance);
        }
    }
}

test "thin_keeps_mute_changes_in_place" {
    for ([_]AutoParam{ .mute, .{ .send_mute = 0 } }) |param| {
        var lane = AutomationLane.init(param);
        defer lane.deinit(testing.allocator);
        for ([_]struct { at: f64, value: f32 }{ .{ .at = 0, .value = 0.0 }, .{ .at = 9000, .value = 1.0 }, .{ .at = 10000, .value = 1.0 } }) |p| {
            try lane.setPoint(testing.allocator, beats(p.at), p.value);
        }
        _ = try lane.thin(testing.allocator, 0.1);
        try testing.expectEqual(@as(f32, 0.0), lane.valueAt(beats(8999), 0.0));
        try testing.expectEqual(@as(f32, 1.0), lane.valueAt(beats(9000), 0.0));
    }
}

test "set_point_clamps_nan" {
    var l = AutomationLane.init(.{ .pan = 0 });
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, beats(0), std.math.nan(f32));
    try l.setPoint(testing.allocator, beats(1), 5.0);
    try testing.expectEqual(@as(f32, 0.0), l.points.items[0].value);
    try testing.expectEqual(@as(f32, 1.0), l.points.items[1].value);
}

// Seridian additions: curves, barriers, shifting and the snapshot read path.

test "curve: hold keeps the left value until the next point" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, 0.0, 0.0);
    try l.setPoint(testing.allocator, 1.0, -10.0);
    try testing.expect(l.setCurve(0.0, .hold));
    try testing.expectEqual(@as(f32, 0.0), l.valueAt(0.5, 0.0));
    try testing.expectEqual(@as(f32, -10.0), l.valueAt(1.0, 0.0));
}

test "curve: s_curve is smoothstep, linear is the straight line" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, 0.0, 0.0);
    try l.setPoint(testing.allocator, 1.0, -10.0);
    _ = l.setCurve(0.0, .s_curve);
    try testing.expect(@abs(l.valueAt(0.5, 0.0) + 5.0) < 1e-5);
    // smoothstep(0.25) = 0.25^2 * (3 - 2 * 0.25) = 0.15625
    try testing.expect(@abs(l.valueAt(0.25, 0.0) + 1.5625) < 1e-5);
    _ = l.setCurve(0.0, .linear);
    try testing.expect(@abs(l.valueAt(0.25, 0.0) + 2.5) < 1e-5);
}

test "curve: exponential eases in below the linear line" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, 0.0, 0.0);
    try l.setPoint(testing.allocator, 1.0, -10.0);
    _ = l.setCurve(0.0, .exponential);
    // (e^(4*0.5) - 1) / (e^4 - 1) = 0.119203, so the value is -1.19203.
    try testing.expect(@abs(l.valueAt(0.5, 0.0) + 1.19203) < 1e-3);
    try testing.expectEqual(@as(f32, 0.0), l.valueAt(0.0, 0.0));
    try testing.expectEqual(@as(f32, -10.0), l.valueAt(1.0, 0.0));
}

test "thin: a non-linear segment is a barrier and its points are kept" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    for (0..5) |i| try l.setPoint(testing.allocator, @floatFromInt(i), -@as(f32, @floatFromInt(i)));
    _ = l.setCurve(2.0, .s_curve);
    // Point 1 sits on a straight run from 0 to 2 and goes. Point 2 starts the s_curve and point 3
    // is entered by it, so both stay.
    try testing.expectEqual(@as(usize, 1), try l.thin(testing.allocator, 0.01));
    try testing.expectEqual(@as(usize, 4), l.points.items.len);
    try testing.expectEqual(@as(f64, 2.0), l.points.items[1].at);
    try testing.expectEqual(@as(f64, 3.0), l.points.items[2].at);
}

test "clear_range returns the removed count and keeps the end" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    for (0..4) |i| try l.setPoint(testing.allocator, @floatFromInt(i), 0.0);
    try testing.expectEqual(@as(usize, 2), l.clearRange(1.0, 3.0));
    try testing.expectEqual(@as(usize, 2), l.points.items.len);
    try testing.expectEqual(@as(f64, 0.0), l.points.items[0].at);
    try testing.expectEqual(@as(f64, 3.0), l.points.items[1].at);
}

test "shift_from clamps at zero and dedups keeping the earliest point" {
    var l = AutomationLane.init(.volume);
    defer l.deinit(testing.allocator);
    try l.setPoint(testing.allocator, 0.0, 1.0);
    try l.setPoint(testing.allocator, 0.5, 2.0);
    try l.setPoint(testing.allocator, 1.5, 3.0);
    l.shiftFrom(0.5, -1.0);
    try testing.expectEqual(@as(usize, 2), l.points.items.len);
    try testing.expectEqual(@as(f32, 1.0), l.points.items[0].value);
    try testing.expectEqual(@as(f64, 0.5), l.points.items[1].at);
    try testing.expectEqual(@as(f32, 3.0), l.points.items[1].value);
}

test "evaluate reads an immutable slice snapshot" {
    const snap = [_]AutomationPoint{ .{ .at = 0.0, .value = 0.0 }, .{ .at = 2.0, .value = -2.0 } };
    try testing.expectEqual(@as(f32, -1.0), evaluate(.volume, &snap, 1.0, 0.0));
    try testing.expectEqual(@as(f32, 0.0), evaluate(.volume, &.{}, 1.0, 0.0));
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Shape of the segment that starts at a point and ends at the next point.
pub const Curve = enum {
    /// Holds the left value until the next point (a step at the next point).
    hold,
    /// Straight line.
    linear,
    /// Ease-in: (e^(4t) - 1) / (e^4 - 1) on the normalised segment position t.
    exponential,
    /// Smoothstep: t^2 * (3 - 2t).
    s_curve,
};

pub const AutomationPoint = struct {
    /// Position in beats (Seridian: f64 beats, not i64 samples).
    at: f64,
    /// Value in the parameter's natural range.
    value: f32,
    /// Curve of the segment from this point to the next one.
    curve: Curve = .linear,
};

/// Gap between a written range and its anchors, in beats: 1/960 of a beat, the tick that
/// replaces the Rust one-sample anchor offset.
pub const anchor_gap_beats: f64 = 1.0 / 960.0;

/// Value at `at` for a sorted point slice. Pure and allocation-free, so the audio thread can call it
/// on an immutable snapshot. Returns `default` when there are no points; before the first point
/// it holds the first value; after the last it holds the last value.
pub fn evaluate(param: AutoParam, points: []const AutomationPoint, at: f64, default: f32) f32 {
    if (points.len == 0) return default;
    const first = points[0];
    if (at <= first.at) return first.value;
    // First index whose point lies strictly after `at`; it is >= 1 because `at` > first.at.
    var lo: usize = 0;
    var hi: usize = points.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (points[mid].at <= at) lo = mid + 1 else hi = mid;
    }
    if (lo == points.len) return points[points.len - 1].value;
    const a = points[lo - 1];
    const b = points[lo];
    if (!(b.at > a.at)) return a.value;
    // Step lanes (mute) and hold segments keep the left value.
    if (param.isStep() or a.curve == .hold) return a.value;
    const t: f32 = @floatCast((at - a.at) / (b.at - a.at));
    return a.value + (b.value - a.value) * shape(a.curve, t);
}

fn shape(curve: Curve, t: f32) f32 {
    return switch (curve) {
        .hold => 0.0,
        .linear => t,
        .exponential => (@exp(4.0 * t) - 1.0) / (@exp(@as(f32, 4.0)) - 1.0),
        .s_curve => t * t * (3.0 - 2.0 * t),
    };
}

/// A breakpoint automation lane. Points are kept sorted by time with unique positions.
/// Editing methods take the allocator and run on the control thread.
pub const AutomationLane = struct {
    param: AutoParam,
    points: std.ArrayList(AutomationPoint) = .empty,
    enabled: bool = true,

    pub fn init(param: AutoParam) AutomationLane {
        return .{ .param = param };
    }

    pub fn deinit(self: *AutomationLane, gpa: std.mem.Allocator) void {
        self.points.deinit(gpa);
    }

    /// Value at `at` (see `evaluate`).
    pub fn valueAt(self: *const AutomationLane, at: f64, default: f32) f32 {
        return evaluate(self.param, self.points.items, at, default);
    }

    /// Index of the first point whose position is >= `at`.
    fn lowerBound(self: *const AutomationLane, at: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.points.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.points.items[mid].at < at) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Index of the point exactly at `at`, if any.
    fn indexAt(self: *const AutomationLane, at: f64) ?usize {
        const idx = self.lowerBound(at);
        if (idx < self.points.items.len and self.points.items[idx].at == at) return idx;
        return null;
    }

    /// Inserts a breakpoint, or updates the value of the one at `at` (keeping its curve).
    /// NaN position becomes 0; NaN value becomes 0; the value is clamped to the parameter range.
    pub fn setPoint(self: *AutomationLane, gpa: std.mem.Allocator, at_in: f64, value_in: f32) std.mem.Allocator.Error!void {
        const at = if (std.math.isNan(at_in)) 0.0 else at_in;
        const r = self.param.range();
        const value = if (std.math.isNan(value_in)) 0.0 else std.math.clamp(value_in, r.min, r.max);
        if (self.indexAt(at)) |idx| {
            self.points.items[idx].value = value;
            return;
        }
        try self.points.insert(gpa, self.lowerBound(at), .{ .at = at, .value = value });
    }

    /// Sets the curve of the point at `at`. Returns false when there is no point there.
    pub fn setCurve(self: *AutomationLane, at: f64, curve: Curve) bool {
        const idx = self.indexAt(at) orelse return false;
        self.points.items[idx].curve = curve;
        return true;
    }

    /// Removes points in [start, end). Returns how many were removed. Allocation-free.
    pub fn clearRange(self: *AutomationLane, start: f64, end: f64) usize {
        const items = self.points.items;
        var w: usize = 0;
        for (items) |p| {
            if (p.at >= start and p.at < end) continue;
            items[w] = p;
            w += 1;
        }
        const removed = items.len - w;
        self.points.shrinkRetainingCapacity(w);
        return removed;
    }

    /// Writes a constant `value` over [start, end). The curve just before the range is pinned at
    /// `start - anchor_gap_beats`, the range is held, and the value after the range is pinned at
    /// `end + anchor_gap_beats`. A real point already at that anchor keeps its own value.
    pub fn writeRange(self: *AutomationLane, gpa: std.mem.Allocator, start: f64, end: f64, value: f32, default: f32) std.mem.Allocator.Error!void {
        if (!(end > start)) return;
        const gap = anchor_gap_beats;
        const pre = start - gap;
        const before = self.valueAt(@max(pre, 0.0), default);
        const after = self.valueAt(end, default);
        _ = self.clearRange(start, end + gap);
        if (pre >= 0.0) try self.setPoint(gpa, pre, before);
        try self.setPoint(gpa, start, value);
        // The range is constant; `hold` makes that explicit rather than relying on equal endpoints.
        _ = self.setCurve(start, .hold);
        try self.setPoint(gpa, end, value);
        const anchor = end + gap;
        if (self.indexAt(anchor) == null) try self.setPoint(gpa, anchor, after);
    }

    /// Thins the lane: removes points that the straight segment from the last kept point can
    /// reproduce within `tolerance` (SoundCraft's slope-window algorithm). Mute and step lanes are
    /// never thinned. A point is removable only if both segments touching it are linear, so
    /// hold and non-linear segments are barriers that are never removed. Returns the removed count.
    /// NaN tolerance removes nothing. Needs an allocator for the keep-mask.
    pub fn thin(self: *AutomationLane, gpa: std.mem.Allocator, tolerance: f32) std.mem.Allocator.Error!usize {
        const n = self.points.items.len;
        if (self.param.isStep() or n < 3 or std.math.isNan(tolerance)) return 0;
        const tol: f64 = tolerance;
        const pts = self.points.items;
        const keep = try gpa.alloc(bool, n);
        defer gpa.free(keep);
        @memset(keep, true);
        // Slopes from the last kept point that keep every point removed since then within `tol`.
        var last: usize = 0;
        var lo: f64 = -std.math.inf(f64);
        var hi: f64 = std.math.inf(f64);
        for (1..n - 1) |i| {
            if (!removable(pts, i)) {
                last = i;
                lo = -std.math.inf(f64);
                hi = std.math.inf(f64);
                continue;
            }
            const a = pts[last];
            const b = pts[i];
            const c = pts[i + 1];
            const dt = b.at - a.at;
            const rise = @as(f64, b.value) - @as(f64, a.value);
            lo = @max(lo, (rise - tol) / dt);
            hi = @min(hi, (rise + tol) / dt);
            const slope = (@as(f64, c.value) - @as(f64, a.value)) / (c.at - a.at);
            if (slope >= lo and slope <= hi) {
                keep[i] = false;
            } else {
                last = i;
                lo = -std.math.inf(f64);
                hi = std.math.inf(f64);
            }
        }
        var w: usize = 0;
        for (0..n) |r| {
            if (!keep[r]) continue;
            pts[w] = pts[r];
            w += 1;
        }
        self.points.shrinkRetainingCapacity(w);
        return n - w;
    }

    /// Both segments touching point `i` must be linear for it to be removable.
    fn removable(pts: []const AutomationPoint, i: usize) bool {
        return pts[i - 1].curve == .linear and pts[i].curve == .linear;
    }

    /// Shifts points at or after `from` by `delta` beats (Shuffle edits, Insert Time). Positions are
    /// clamped at 0. The list is re-sorted and duplicate positions are dropped, keeping the earliest.
    /// No allocation: the insertion sort is stable, and it is O(n) when only the moved block is out of order.
    pub fn shiftFrom(self: *AutomationLane, from: f64, delta: f64) void {
        const items = self.points.items;
        for (items) |*p| {
            if (p.at >= from) p.at = @max(p.at + delta, 0.0);
        }
        std.sort.insertion(AutomationPoint, items, {}, lessByAt);
        var w: usize = 0;
        for (0..items.len) |r| {
            if (w > 0 and items[w - 1].at == items[r].at) continue;
            items[w] = items[r];
            w += 1;
        }
        self.points.shrinkRetainingCapacity(w);
    }
};

fn lessByAt(_: void, a: AutomationPoint, b: AutomationPoint) bool {
    return a.at < b.at;
}
