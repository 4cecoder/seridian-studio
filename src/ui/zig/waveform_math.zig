const std = @import("std");
const testing = std.testing;

pub const Peak = struct { min: f32, max: f32 };
pub const Window = struct { start: f64, end: f64 };

/// Clamp a [start, end] seconds window to [0, clip_len]. Swapped bounds are
/// reordered; NaN is treated as 0; result always satisfies 0 <= start <= end <= clip_len.
/// NaN becomes 0 so comparisons below never see it.
fn sanitize(value: f64) f64 {
    return if (std.math.isNan(value)) 0.0 else value;
}

/// Usable clip length: finite and positive, otherwise 0 (an empty clip).
fn clipLength(clip_len: f64) f64 {
    if (!std.math.isFinite(clip_len) or clip_len <= 0.0) return 0.0;
    return clip_len;
}

pub fn clampWindow(start: f64, end: f64, clip_len: f64) Window {
    const len = clipLength(clip_len);
    var lo = sanitize(start);
    var hi = sanitize(end);
    if (lo > hi) std.mem.swap(f64, &lo, &hi);
    return .{
        .start = @min(@max(lo, 0.0), len),
        .end = @min(@max(hi, 0.0), len),
    };
}

/// Map `peaks` (evenly spaced over [0, clip_len]) onto `out.len` pixel columns
/// covering `win`. Each column holds the min/max over the peaks it overlaps.
/// Columns with no source data (outside the clip, or zero-width window) are {0, 0}.
pub fn peaksToColumns(peaks: []const Peak, clip_len: f64, win: Window, out: []Peak) void {
    for (out) |*column| column.* = .{ .min = 0.0, .max = 0.0 };

    const len = clipLength(clip_len);
    if (peaks.len == 0 or out.len == 0 or len <= 0.0) return;

    // The requested window is not clamped: columns past the clip end stay silent.
    var lo = sanitize(win.start);
    var hi = sanitize(win.end);
    if (lo > hi) std.mem.swap(f64, &lo, &hi);
    const width = hi - lo;
    if (!(width > 0.0) or !std.math.isFinite(width)) return;

    const peak_count: f64 = @floatFromInt(peaks.len);
    const peak_width = len / peak_count;
    const column_width = width / @as(f64, @floatFromInt(out.len));

    for (out, 0..) |*column, index| {
        const index_f: f64 = @floatFromInt(index);
        const t0 = lo + index_f * column_width;
        const t1 = lo + (index_f + 1.0) * column_width;

        // Only the part of the column inside the clip can hold data.
        const a = @max(t0, 0.0);
        const b = @min(t1, len);
        if (!(b > a)) continue;

        // Peak j covers [j * peak_width, (j + 1) * peak_width).
        const first_f = @min(@floor(a / peak_width), peak_count - 1.0);
        const last_f = @min(@ceil(b / peak_width) - 1.0, peak_count - 1.0);
        if (!(last_f >= first_f)) continue;

        const first: usize = @intFromFloat(first_f);
        const last: usize = @intFromFloat(last_f);
        const span = peaks[first .. last + 1];
        var min_v = span[0].min;
        var max_v = span[0].max;
        for (span[1..]) |p| {
            min_v = @min(min_v, p.min);
            max_v = @max(max_v, p.max);
        }
        column.* = .{ .min = min_v, .max = max_v };
    }
}

test "clampWindow: inside range is unchanged" {
    const w = clampWindow(1.0, 3.0, 10.0);
    try testing.expectEqual(@as(f64, 1.0), w.start);
    try testing.expectEqual(@as(f64, 3.0), w.end);
}

test "clampWindow: negative start clamps to 0" {
    const w = clampWindow(-5.0, 3.0, 10.0);
    try testing.expectEqual(@as(f64, 0.0), w.start);
    try testing.expectEqual(@as(f64, 3.0), w.end);
}

test "clampWindow: end past clip length clamps to clip_len" {
    const w = clampWindow(2.0, 99.0, 10.0);
    try testing.expectEqual(@as(f64, 2.0), w.start);
    try testing.expectEqual(@as(f64, 10.0), w.end);
}

test "clampWindow: fully out of range collapses to zero-width at boundary" {
    const hi = clampWindow(20.0, 30.0, 10.0);
    try testing.expectEqual(@as(f64, 10.0), hi.start);
    try testing.expectEqual(@as(f64, 10.0), hi.end);
    const lo = clampWindow(-30.0, -20.0, 10.0);
    try testing.expectEqual(@as(f64, 0.0), lo.start);
    try testing.expectEqual(@as(f64, 0.0), lo.end);
}

test "clampWindow: zero-width window preserved" {
    const w = clampWindow(4.0, 4.0, 10.0);
    try testing.expectEqual(@as(f64, 4.0), w.start);
    try testing.expectEqual(@as(f64, 4.0), w.end);
}

test "clampWindow: swapped bounds are reordered" {
    const w = clampWindow(7.0, 2.0, 10.0);
    try testing.expectEqual(@as(f64, 2.0), w.start);
    try testing.expectEqual(@as(f64, 7.0), w.end);
}

test "clampWindow: exact boundaries are kept" {
    const w = clampWindow(0.0, 10.0, 10.0);
    try testing.expectEqual(@as(f64, 0.0), w.start);
    try testing.expectEqual(@as(f64, 10.0), w.end);
}

test "clampWindow: zero-length clip gives empty window" {
    const w = clampWindow(1.0, 2.0, 0.0);
    try testing.expectEqual(@as(f64, 0.0), w.start);
    try testing.expectEqual(@as(f64, 0.0), w.end);
}

test "clampWindow: NaN and negative clip_len are safe" {
    const nan = std.math.nan(f64);
    const a = clampWindow(nan, nan, 10.0);
    try testing.expect(a.start >= 0.0 and a.start <= a.end and a.end <= 10.0);
    const b = clampWindow(1.0, 2.0, -3.0);
    try testing.expectEqual(@as(f64, 0.0), b.start);
    try testing.expectEqual(@as(f64, 0.0), b.end);
}

test "peaksToColumns: one peak per column maps 1:1" {
    const peaks = [_]Peak{
        .{ .min = -0.1, .max = 0.1 },
        .{ .min = -0.5, .max = 0.5 },
        .{ .min = -0.9, .max = 0.9 },
        .{ .min = -0.3, .max = 0.3 },
    };
    var out: [4]Peak = undefined;
    peaksToColumns(&peaks, 4.0, .{ .start = 0, .end = 4.0 }, &out);
    for (peaks, out) |p, c| {
        try testing.expectEqual(p.min, c.min);
        try testing.expectEqual(p.max, c.max);
    }
}

test "peaksToColumns: many peaks per column take min of mins and max of maxes" {
    const peaks = [_]Peak{
        .{ .min = -0.2, .max = 0.4 },
        .{ .min = -0.8, .max = 0.1 },
        .{ .min = -0.1, .max = 0.9 },
        .{ .min = -0.3, .max = 0.2 },
    };
    var out: [2]Peak = undefined;
    peaksToColumns(&peaks, 4.0, .{ .start = 0, .end = 4.0 }, &out);
    try testing.expectEqual(@as(f32, -0.8), out[0].min);
    try testing.expectEqual(@as(f32, 0.4), out[0].max);
    try testing.expectEqual(@as(f32, -0.3), out[1].min);
    try testing.expectEqual(@as(f32, 0.9), out[1].max);
}

test "peaksToColumns: zoomed window selects the right sub-range" {
    const peaks = [_]Peak{
        .{ .min = -0.1, .max = 0.1 },
        .{ .min = -0.2, .max = 0.2 },
        .{ .min = -0.3, .max = 0.3 },
        .{ .min = -0.4, .max = 0.4 },
    };
    var out: [2]Peak = undefined;
    peaksToColumns(&peaks, 4.0, .{ .start = 2.0, .end = 4.0 }, &out);
    try testing.expectEqual(@as(f32, -0.3), out[0].min);
    try testing.expectEqual(@as(f32, 0.3), out[0].max);
    try testing.expectEqual(@as(f32, -0.4), out[1].min);
    try testing.expectEqual(@as(f32, 0.4), out[1].max);
}

test "peaksToColumns: more columns than peaks repeats the covering peak" {
    const peaks = [_]Peak{ .{ .min = -0.5, .max = 0.5 }, .{ .min = -1.0, .max = 1.0 } };
    var out: [4]Peak = undefined;
    peaksToColumns(&peaks, 2.0, .{ .start = 0, .end = 2.0 }, &out);
    try testing.expectEqual(@as(f32, 0.5), out[0].max);
    try testing.expectEqual(@as(f32, 0.5), out[1].max);
    try testing.expectEqual(@as(f32, 1.0), out[2].max);
    try testing.expectEqual(@as(f32, 1.0), out[3].max);
}

test "peaksToColumns: window beyond clip end leaves trailing columns silent" {
    const peaks = [_]Peak{ .{ .min = -0.5, .max = 0.5 }, .{ .min = -0.5, .max = 0.5 } };
    var out: [4]Peak = undefined;
    peaksToColumns(&peaks, 2.0, .{ .start = 0, .end = 4.0 }, &out);
    try testing.expectEqual(@as(f32, 0.5), out[0].max);
    try testing.expectEqual(@as(f32, 0.5), out[1].max);
    try testing.expectEqual(@as(f32, 0.0), out[2].max);
    try testing.expectEqual(@as(f32, 0.0), out[3].min);
}

test "peaksToColumns: window entirely out of range gives all-zero columns" {
    const peaks = [_]Peak{.{ .min = -1, .max = 1 }};
    var out: [3]Peak = @splat(.{ .min = 9, .max = 9 });
    peaksToColumns(&peaks, 1.0, .{ .start = 5.0, .end = 8.0 }, &out);
    for (out) |c| {
        try testing.expectEqual(@as(f32, 0.0), c.min);
        try testing.expectEqual(@as(f32, 0.0), c.max);
    }
}

test "peaksToColumns: zero-width window does not divide by zero" {
    const peaks = [_]Peak{.{ .min = -1, .max = 1 }};
    var out: [2]Peak = @splat(.{ .min = 9, .max = 9 });
    peaksToColumns(&peaks, 1.0, .{ .start = 0.5, .end = 0.5 }, &out);
    for (out) |c| {
        try testing.expect(std.math.isFinite(c.min) and std.math.isFinite(c.max));
    }
}

test "peaksToColumns: empty peaks, empty out, zero clip_len are no-ops or silent" {
    var out: [2]Peak = @splat(.{ .min = 9, .max = 9 });
    peaksToColumns(&.{}, 1.0, .{ .start = 0, .end = 1 }, &out);
    try testing.expectEqual(@as(f32, 0.0), out[0].max);
    const peaks = [_]Peak{.{ .min = -1, .max = 1 }};
    var none: [0]Peak = .{};
    peaksToColumns(&peaks, 1.0, .{ .start = 0, .end = 1 }, &none);
    peaksToColumns(&peaks, 0.0, .{ .start = 0, .end = 1 }, &out);
    try testing.expectEqual(@as(f32, 0.0), out[1].max);
}

test "peaksToColumns: negative window start only shows data from 0" {
    const peaks = [_]Peak{ .{ .min = -0.5, .max = 0.5 }, .{ .min = -0.5, .max = 0.5 } };
    var out: [4]Peak = undefined;
    peaksToColumns(&peaks, 2.0, .{ .start = -2.0, .end = 2.0 }, &out);
    try testing.expectEqual(@as(f32, 0.0), out[0].max);
    try testing.expectEqual(@as(f32, 0.0), out[1].max);
    try testing.expectEqual(@as(f32, 0.5), out[2].max);
    try testing.expectEqual(@as(f32, 0.5), out[3].max);
}
