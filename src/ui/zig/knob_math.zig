const std = @import("std");
const testing = std.testing;

pub const sweep_start_degrees: f64 = -135.0;
pub const sweep_degrees: f64 = 270.0;
pub const drag_pixels_full: f64 = 200.0;
pub const drag_pixels_fine: f64 = 1000.0;

/// Clamps to [0, 1]. NaN passes through unchanged, as in the C knob_math.h it was ported from.
pub fn clampUnit(value: f64) f64 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

/// Maps a value in [minimum, maximum] to [0, 1]. A zero-width or inverted range gives 0.
pub fn normalize(value: f32, minimum: f32, maximum: f32) f64 {
    if (maximum <= minimum) return 0.0;
    return clampUnit(@as(f64, value - minimum) / @as(f64, maximum - minimum));
}

/// Maps a normalized position (clamped to [0, 1]) to [minimum, maximum].
pub fn valueFromNormalized(normalized: f64, minimum: f32, maximum: f32) f32 {
    const span: f64 = @as(f64, maximum - minimum);
    return @as(f32, @floatCast(@as(f64, minimum) + clampUnit(normalized) * span));
}

/// Pointer angle in degrees, clockwise from 12 o'clock.
pub fn angleDegrees(normalized: f64) f64 {
    return sweep_start_degrees + sweep_degrees * clampUnit(normalized);
}

/// New normalized position after dragging by `dy` pixels (screen coordinates:
/// dragging up gives negative dy and raises the value). `fine` gives 1000 px per sweep.
pub fn dragNormalized(start_normalized: f64, dy: f64, fine: bool) f64 {
    const pixels = if (fine) drag_pixels_fine else drag_pixels_full;
    return clampUnit(start_normalized - dy / pixels);
}

/// A double click (clicks == 2) resets the knob to its default value.
pub fn isResetClick(clicks: c_int) bool {
    return clicks == 2;
}

/// Widget state logic (no Raven calls), mirrors KnobState in knob.c.
pub const Knob = struct {
    minimum: f32,
    maximum: f32,
    default_value: f32,
    value: f32,
    bipolar: bool = false,
    dragging: bool = false,
    drag_start_y: f32 = 0,
    drag_start_position: f64 = 0,
    changes: u32 = 0, // number of on_change notifications
    last_notified: f32 = 0,

    /// Returns true if the event was consumed. Left press starts a drag; clicks==2 resets.
    pub fn press(self: *Knob, left_button: bool, clicks: c_int, y: f32) bool {
        if (!left_button) return false;
        if (isResetClick(clicks)) {
            self.applyPosition(normalize(self.default_value, self.minimum, self.maximum));
            return true;
        }
        self.dragging = true;
        self.drag_start_y = y;
        self.drag_start_position = self.position();
        return true;
    }
    /// Window-level move while dragging. Returns true if consumed.
    pub fn move(self: *Knob, y: f32, shift: bool) bool {
        if (!self.dragging) return false;
        const dy: f64 = @as(f64, y - self.drag_start_y);
        self.applyPosition(dragNormalized(self.drag_start_position, dy, shift));
        return true;
    }
    /// Window-level release. Returns true if consumed.
    pub fn release(self: *Knob, left_button: bool) bool {
        if (!left_button) return false;
        self.dragging = false;
        return true;
    }
    /// Normalized position of the current value.
    pub fn position(self: *const Knob) f64 {
        return normalize(self.value, self.minimum, self.maximum);
    }
    /// Normalized origin of the value arc: 0.5 when bipolar, else 0.
    pub fn arcOrigin(self: *const Knob) f64 {
        return if (self.bipolar) 0.5 else 0.0;
    }

    /// Sets the value from a normalized position and notifies only on change.
    fn applyPosition(self: *Knob, normalized: f64) void {
        const next = valueFromNormalized(normalized, self.minimum, self.maximum);
        if (next == self.value) return;
        self.value = next;
        self.changes += 1;
        self.last_notified = next;
    }
};

/// Point on a circle at degrees clockwise from 12 o'clock (y grows downward).
pub const Point = struct { x: f32, y: f32 };
pub fn pointOnCircle(cx: f32, cy: f32, radius: f32, degrees: f64) Point {
    const radians = degrees * std.math.pi / 180.0;
    return .{
        .x = cx + radius * @as(f32, @floatCast(@sin(radians))),
        .y = cy - radius * @as(f32, @floatCast(@cos(radians))),
    };
}

/// Knob radius for a widget box: min(w,h)/2 - 3.
pub fn paintRadius(width: f32, height: f32) f32 {
    return @min(width, height) * 0.5 - 3.0;
}

fn expectClose(expected: f64, actual: f64) !void {
    try testing.expectApproxEqAbs(expected, actual, 1e-6);
}

fn newKnob(min: f32, max: f32, def: f32, value: f32) Knob {
    return .{ .minimum = min, .maximum = max, .default_value = def, .value = value };
}

test "clampUnit clamps and passes through" {
    try expectClose(0.0, clampUnit(-0.5));
    try expectClose(0.0, clampUnit(0.0));
    try expectClose(0.25, clampUnit(0.25));
    try expectClose(1.0, clampUnit(1.0));
    try expectClose(1.0, clampUnit(7.0));
    try expectClose(0.0, clampUnit(-std.math.inf(f64)));
    try expectClose(1.0, clampUnit(std.math.inf(f64)));
}

test "normalize maps range to unit interval" {
    try expectClose(0.0, normalize(-60, -60, 6));
    try expectClose(1.0, normalize(6, -60, 6));
    try expectClose(0.5, normalize(0, -1, 1));
    try expectClose(0.25, normalize(25, 0, 100));
}

test "normalize clamps out-of-range inputs" {
    try expectClose(0.0, normalize(-10, 0, 100));
    try expectClose(1.0, normalize(1000, 0, 100));
}

test "normalize zero-width and inverted ranges give 0" {
    try expectClose(0.0, normalize(5, 5, 5));
    try expectClose(0.0, normalize(7, 5, 5));
    try expectClose(0.0, normalize(3, 10, 0));
}

test "valueFromNormalized maps and clamps" {
    try testing.expectEqual(@as(f32, -60.0), valueFromNormalized(0.0, -60, 6));
    try testing.expectEqual(@as(f32, 6.0), valueFromNormalized(1.0, -60, 6));
    try testing.expectEqual(@as(f32, 50.0), valueFromNormalized(0.5, 0, 100));
    try testing.expectEqual(@as(f32, 0.0), valueFromNormalized(-3.0, 0, 100));
    try testing.expectEqual(@as(f32, 100.0), valueFromNormalized(3.0, 0, 100));
}

test "valueFromNormalized zero-width range returns minimum" {
    try testing.expectEqual(@as(f32, 4.0), valueFromNormalized(0.7, 4, 4));
}

test "normalize and valueFromNormalized round trip" {
    const v = valueFromNormalized(normalize(37.5, 0, 100), 0, 100);
    try testing.expectApproxEqAbs(@as(f32, 37.5), v, 1e-4);
}

test "angleDegrees sweep endpoints and centre" {
    try expectClose(-135.0, angleDegrees(0.0));
    try expectClose(0.0, angleDegrees(0.5));
    try expectClose(135.0, angleDegrees(1.0));
}

test "angleDegrees clamps out-of-range input" {
    try expectClose(-135.0, angleDegrees(-2.0));
    try expectClose(135.0, angleDegrees(9.0));
}

test "dragNormalized: dragging up raises value" {
    try expectClose(0.6, dragNormalized(0.5, -20.0, false));
    try expectClose(0.4, dragNormalized(0.5, 20.0, false));
}

test "dragNormalized: full sweep is 200px, fine is 1000px" {
    try expectClose(1.0, dragNormalized(0.0, -200.0, false));
    try expectClose(0.0, dragNormalized(1.0, 200.0, false));
    try expectClose(0.1, dragNormalized(0.0, -100.0, true));
    try expectClose(1.0, dragNormalized(0.0, -1000.0, true));
}

test "dragNormalized clamps beyond range and ignores zero movement" {
    try expectClose(1.0, dragNormalized(0.9, -500.0, false));
    try expectClose(0.0, dragNormalized(0.1, 500.0, false));
    try expectClose(0.3, dragNormalized(0.3, 0.0, false));
    try expectClose(1.0, dragNormalized(0.5, -std.math.inf(f64), true));
}

test "isResetClick only on double click" {
    try testing.expect(!isResetClick(0));
    try testing.expect(!isResetClick(1));
    try testing.expect(isResetClick(2));
    try testing.expect(!isResetClick(3));
    try testing.expect(!isResetClick(-2));
}

test "pointOnCircle: 12 o'clock is up, 90 is right" {
    const up = pointOnCircle(10, 10, 5, 0);
    try testing.expectApproxEqAbs(@as(f32, 10), up.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), up.y, 1e-4);
    const right = pointOnCircle(10, 10, 5, 90);
    try testing.expectApproxEqAbs(@as(f32, 15), right.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), right.y, 1e-4);
    const left = pointOnCircle(10, 10, 5, -90);
    try testing.expectApproxEqAbs(@as(f32, 5), left.x, 1e-4);
}

test "pointOnCircle zero radius is the centre" {
    const p = pointOnCircle(3, 4, 0, 45);
    try testing.expectEqual(@as(f32, 3), p.x);
    try testing.expectEqual(@as(f32, 4), p.y);
}

test "paintRadius uses the smaller side minus margin" {
    try testing.expectEqual(@as(f32, 17), paintRadius(40, 60));
    try testing.expectEqual(@as(f32, 17), paintRadius(60, 40));
    try testing.expectEqual(@as(f32, -3), paintRadius(0, 0));
}

test "arcOrigin is centre for bipolar, minimum otherwise" {
    var k = newKnob(-1, 1, 0, 0);
    try expectClose(0.0, k.arcOrigin());
    k.bipolar = true;
    try expectClose(0.5, k.arcOrigin());
}

test "position of knob value, including out-of-range value" {
    try expectClose(0.5, newKnob(0, 10, 0, 5).position());
    try expectClose(1.0, newKnob(0, 10, 0, 99).position());
    try expectClose(0.0, newKnob(2, 2, 2, 2).position());
}

test "press with left button starts drag and records start" {
    var k = newKnob(0, 100, 50, 25);
    try testing.expect(k.press(true, 1, 80));
    try testing.expect(k.dragging);
    try testing.expectEqual(@as(f32, 80), k.drag_start_y);
    try expectClose(0.25, k.drag_start_position);
    try testing.expectEqual(@as(u32, 0), k.changes);
}

test "press with other button is not consumed" {
    var k = newKnob(0, 100, 50, 25);
    try testing.expect(!k.press(false, 1, 80));
    try testing.expect(!k.dragging);
}

test "double click resets to default, notifies once, no drag" {
    var k = newKnob(0, 100, 50, 25);
    try testing.expect(k.press(true, 2, 10));
    try testing.expectEqual(@as(f32, 50), k.value);
    try testing.expectEqual(@as(u32, 1), k.changes);
    try testing.expectEqual(@as(f32, 50), k.last_notified);
    try testing.expect(!k.dragging);
}

test "double click at default does not notify" {
    var k = newKnob(0, 100, 50, 50);
    try testing.expect(k.press(true, 2, 10));
    try testing.expectEqual(@as(u32, 0), k.changes);
}

test "double click with out-of-range default clamps to maximum" {
    var k = newKnob(0, 100, 500, 25);
    _ = k.press(true, 2, 10);
    try testing.expectEqual(@as(f32, 100), k.value);
}

test "move drags value up and down, notifying on change" {
    var k = newKnob(0, 100, 50, 50);
    _ = k.press(true, 1, 100);
    try testing.expect(k.move(80, false)); // up 20px => +10%
    try testing.expectApproxEqAbs(@as(f32, 60), k.value, 1e-3);
    try testing.expectEqual(@as(u32, 1), k.changes);
    try testing.expect(k.move(120, false)); // down 20px => -10% from start
    try testing.expectApproxEqAbs(@as(f32, 40), k.value, 1e-3);
    try testing.expectEqual(@as(u32, 2), k.changes);
}

test "move with shift is fine (5x slower)" {
    var k = newKnob(0, 100, 50, 50);
    _ = k.press(true, 1, 100);
    _ = k.move(0, true); // 100px up fine => +10%
    try testing.expectApproxEqAbs(@as(f32, 60), k.value, 1e-3);
}

test "move clamps at the ends of the range" {
    var k = newKnob(0, 100, 50, 50);
    _ = k.press(true, 1, 100);
    _ = k.move(-5000, false);
    try testing.expectEqual(@as(f32, 100), k.value);
    _ = k.move(9000, false);
    try testing.expectEqual(@as(f32, 0), k.value);
}

test "move without change does not notify but is consumed" {
    var k = newKnob(0, 100, 50, 100);
    _ = k.press(true, 1, 100);
    try testing.expect(k.move(0, false));
    try testing.expectEqual(@as(u32, 0), k.changes);
}

test "move without active drag is not consumed" {
    var k = newKnob(0, 100, 50, 50);
    try testing.expect(!k.move(10, false));
    try testing.expectEqual(@as(f32, 50), k.value);
}

test "release ends drag only for left button" {
    var k = newKnob(0, 100, 50, 50);
    _ = k.press(true, 1, 100);
    try testing.expect(!k.release(false));
    try testing.expect(k.dragging);
    try testing.expect(k.release(true));
    try testing.expect(!k.dragging);
    try testing.expect(!k.move(10, false));
}

test "zero-width range knob never changes value" {
    var k = newKnob(5, 5, 5, 5);
    _ = k.press(true, 1, 100);
    _ = k.move(0, false);
    try testing.expectEqual(@as(f32, 5), k.value);
    try testing.expectEqual(@as(u32, 0), k.changes);
}
