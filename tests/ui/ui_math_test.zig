//! UI math rules (ported from tests/ui/ui_math_test.c, every assertion kept).

const std = @import("std");
const ui_math = @import("ui_impl").ui_math;
const expect = std.testing.expect;

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

fn expectStr(actual: [*:0]const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, std.mem.span(actual));
}

test "format pan center" {
    var text: [16]u8 = undefined;
    ui_math.ui_format_pan(0.0, &text, text.len);
    try expectStr(@ptrCast(&text), "C");
    ui_math.ui_format_pan(0.001, &text, text.len);
    try expectStr(@ptrCast(&text), "C");
}

test "format pan sides" {
    var text: [16]u8 = undefined;
    ui_math.ui_format_pan(-0.25, &text, text.len);
    try expectStr(@ptrCast(&text), "L25");
    ui_math.ui_format_pan(0.4, &text, text.len);
    try expectStr(@ptrCast(&text), "R40");
    ui_math.ui_format_pan(-1.0, &text, text.len);
    try expectStr(@ptrCast(&text), "L100");
}

test "format gain silence and unity" {
    var text: [24]u8 = undefined;
    ui_math.ui_format_gain(0.0, &text, text.len);
    try expectStr(@ptrCast(&text), "−∞ dB");
    ui_math.ui_format_gain(1.0, &text, text.len);
    try expectStr(@ptrCast(&text), "0.0 dB");
}

test "format gain half is minus six" {
    var text: [24]u8 = undefined;
    ui_math.ui_format_gain(0.5, &text, text.len);
    try expectStr(@ptrCast(&text), "-6.0 dB");
}

test "zoom in halves span around center" {
    var start: f64 = 0.0;
    var end: f64 = 0.0;
    // Visible 0..24s, center 12s, zoom in x0.5 -> 12s span centered on 12s.
    ui_math.ui_zoom_view(0.0, 24.0, 0.5, 180.0, &start, &end);
    try expectNear(end - start, 12.0, 1e-9);
    try expectNear(start, 6.0, 1e-9);
    try expectNear(end, 18.0, 1e-9);
}

test "zoom out clamps to duration" {
    var start: f64 = 0.0;
    var end: f64 = 0.0;
    ui_math.ui_zoom_view(100.0, 150.0, 4.0, 180.0, &start, &end);
    try expectNear(end - start, 180.0, 1e-9);
    try expectNear(start, 0.0, 1e-9);
    try expectNear(end, 180.0, 1e-9);
}

test "zoom never goes below minimum span" {
    var start: f64 = 0.0;
    var end: f64 = 0.0;
    ui_math.ui_zoom_view(10.0, 12.0, 0.01, 180.0, &start, &end);
    try expectNear(end - start, ui_math.UI_MIN_VIEW_SECONDS, 1e-9);
}

test "zoom keeps view inside timeline" {
    var start: f64 = 0.0;
    var end: f64 = 0.0;
    ui_math.ui_zoom_view(170.0, 180.0, 0.5, 180.0, &start, &end);
    try expect(start >= 0.0);
    try expect(end <= 180.0);
    try expect(end > start);
}

test "time inside clip is strict" {
    // Clip 4s..8s (start 4, duration 4). The edges must not count as "inside",
    // otherwise a split on a boundary would create a zero-length clip.
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 6.0) == 1);
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 4.5) == 1);
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 4.0) == 0);
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 8.0) == 0);
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 3.9) == 0);
    try expect(ui_math.ui_time_splits_clip(4.0, 4.0, 8.1) == 0);
}

test "time inside clip rejects zero length" {
    try expect(ui_math.ui_time_splits_clip(5.0, 0.0, 5.0) == 0);
    try expect(ui_math.ui_time_splits_clip(5.0, -1.0, 5.0) == 0);
}

test "bar beat at start" {
    var bar: c_int = 0;
    var beat: c_int = 0;
    ui_math.ui_bar_beat(0.0, 120.0, 4, &bar, &beat);
    try expect(bar == 1);
    try expect(beat == 1);
}

test "bar beat advances per beat and bar" {
    var bar: c_int = 0;
    var beat: c_int = 0;
    // 120 BPM -> 0.5s per beat. 2.0s = beat 5 = bar 2, beat 1 in 4/4.
    ui_math.ui_bar_beat(2.0, 120.0, 4, &bar, &beat);
    try expect(bar == 2);
    try expect(beat == 1);
    ui_math.ui_bar_beat(0.5, 120.0, 4, &bar, &beat);
    try expect(bar == 1);
    try expect(beat == 2);
}

test "bar beat rejects invalid tempo" {
    var bar: c_int = 99;
    var beat: c_int = 99;
    ui_math.ui_bar_beat(3.0, 0.0, 4, &bar, &beat);
    try expect(bar == 0);
    try expect(beat == 0);
}
