//! Knob value and angle rules (ported from tests/ui/knob_math_test.c, every assertion kept). The C header
//! knob_math.h and src/ui/zig/knob_math.zig share these rules; the C names map to the Zig ones as
//! knob_normalize -> normalize, knob_value_from_normalized -> valueFromNormalized, knob_angle_degrees ->
//! angleDegrees, knob_drag_normalized -> dragNormalized (fine: int -> bool), knob_is_reset_click -> isResetClick
//! (int -> bool).

const std = @import("std");
const knob = @import("ui_impl").knob_math;
const expect = std.testing.expect;

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "normalize maps range to unit" {
    try expectNear(knob.normalize(0.0, 0.0, 1.0), 0.0, 1e-9);
    try expectNear(knob.normalize(0.5, 0.0, 1.0), 0.5, 1e-9);
    try expectNear(knob.normalize(1.0, 0.0, 1.0), 1.0, 1e-9);
}

test "normalize handles bipolar range" {
    // Pan runs -1..1: centre must map to 0.5 so the arc starts at 12 o'clock.
    try expectNear(knob.normalize(0.0, -1.0, 1.0), 0.5, 1e-9);
    try expectNear(knob.normalize(-1.0, -1.0, 1.0), 0.0, 1e-9);
}

test "normalize clamps out of range" {
    try expectNear(knob.normalize(-5.0, 0.0, 1.0), 0.0, 1e-9);
    try expectNear(knob.normalize(9.0, 0.0, 1.0), 1.0, 1e-9);
}

test "normalize degenerate range is zero" {
    // A zero-width range must not divide by zero.
    try expectNear(knob.normalize(3.0, 2.0, 2.0), 0.0, 1e-9);
}

test "value round trips through normalize" {
    const values = [_]f32{ -1.0, -0.25, 0.0, 0.6, 1.0 };
    for (values) |value| {
        const n = knob.normalize(value, -1.0, 1.0);
        try expectNear(knob.valueFromNormalized(n, -1.0, 1.0), value, 1e-6);
    }
}

test "angle sweeps from min to max" {
    // The sweep is 270 degrees, from -135 (7:30) to +135 (4:30), clockwise.
    try expectNear(knob.angleDegrees(0.0), -135.0, 1e-9);
    try expectNear(knob.angleDegrees(0.5), 0.0, 1e-9);
    try expectNear(knob.angleDegrees(1.0), 135.0, 1e-9);
}

test "angle is clamped" {
    try expectNear(knob.angleDegrees(-2.0), -135.0, 1e-9);
    try expectNear(knob.angleDegrees(2.0), 135.0, 1e-9);
}

test "drag up increases value" {
    // Dragging up (negative dy in screen coordinates) raises the value.
    const n = knob.dragNormalized(0.5, -50.0, false);
    try expect(n > 0.5);
}

test "drag down decreases value" {
    const n = knob.dragNormalized(0.5, 50.0, false);
    try expect(n < 0.5);
}

test "drag is clamped to unit range" {
    try expectNear(knob.dragNormalized(0.9, -10000.0, false), 1.0, 1e-9);
    try expectNear(knob.dragNormalized(0.1, 10000.0, false), 0.0, 1e-9);
}

test "fine drag moves slower than coarse" {
    // Shift-drag gives precision: the same movement changes the value less.
    const coarse = knob.dragNormalized(0.5, -40.0, false);
    const fine = knob.dragNormalized(0.5, -40.0, true);
    try expect(fine - 0.5 < coarse - 0.5);
    try expect(fine > 0.5);
}

test "full sweep is 200 pixels coarse" {
    // Calibrated on the running app: a 60 px drag moves a -1..1 pan knob by 0.6.
    try expectNear(knob.dragNormalized(0.0, -200.0, false), 1.0, 1e-9);
    try expectNear(knob.dragNormalized(0.0, -60.0, false), 0.3, 1e-9);
}

test "full sweep is 1000 pixels fine" {
    // Calibrated on the running app: a 60 px shift-drag moves pan by 0.12.
    try expectNear(knob.dragNormalized(0.0, -1000.0, true), 1.0, 1e-9);
    try expectNear(knob.dragNormalized(0.0, -60.0, true), 0.06, 1e-9);
}

test "double click resets to default" {
    try expect(knob.isResetClick(2) == true);
    try expect(knob.isResetClick(3) == false);
    try expect(knob.isResetClick(1) == false);
}
