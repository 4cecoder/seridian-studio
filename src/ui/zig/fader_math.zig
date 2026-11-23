//! Value rules for the volume fader. Pure math, no Raven calls.
//!
//! Three scales: linear gain (0 = silence, 1 = unity), dB (-inf .. +6) and a
//! normalized slider position in [0, 1] (0 = bottom = -inf, 1 = +6 dB).
//! Unity (0 dB) sits at `unity_position`. Mirrors knob_math.zig for
//! drag (200 px full, 1000 px with shift) and double-click reset.
const std = @import("std");
const testing = std.testing;

pub const max_db: f64 = 6.0;
pub const unity_position: f64 = 0.75;
pub const drag_pixels_full: f64 = 200.0;
pub const drag_pixels_fine: f64 = 1000.0;
/// Lowest dB a non-zero position reaches; position 0 is -inf.
const floor_db: f64 = -60.0;

pub fn clampUnit(value: f64) f64 {
    if (!(value > 0.0)) return 0.0;
    if (value >= 1.0) return 1.0;
    return value;
}

/// Linear gain to dB. Gain <= 0 (and NaN) gives -inf.
pub fn gainToDb(gain: f64) f64 {
    if (!(gain > 0.0)) return -std.math.inf(f64);
    return 20.0 * std.math.log10(gain);
}

/// dB to linear gain. -inf gives 0; values above max_db clamp to max_db.
pub fn dbToGain(db: f64) f64 {
    if (!(db > -std.math.inf(f64))) return 0.0;
    const clamped = @min(db, max_db);
    return std.math.pow(f64, 10.0, clamped / 20.0);
}

/// dB to position in [0, 1]. -inf and below the floor give 0, above +6 give 1.
pub fn dbToPosition(db: f64) f64 {
    if (std.math.isNan(db) or db <= floor_db) return 0.0;
    if (db >= max_db) return 1.0;
    if (db <= 0.0) return unity_position * (db - floor_db) / -floor_db;
    return unity_position + (1.0 - unity_position) * db / max_db;
}

/// Position (clamped to [0, 1]) to dB. 0 gives -inf, 1 gives +6.
pub fn positionToDb(position: f64) f64 {
    if (!(position > 0.0)) return -std.math.inf(f64);
    const p = clampUnit(position);
    if (p <= unity_position) return floor_db * (1.0 - p / unity_position);
    return max_db * (p - unity_position) / (1.0 - unity_position);
}

pub fn gainToPosition(gain: f64) f64 {
    return dbToPosition(gainToDb(gain));
}

pub fn positionToGain(position: f64) f64 {
    return dbToGain(positionToDb(position));
}

/// New position after a vertical drag of dy pixels (screen coords, up is negative).
pub fn dragPosition(start: f64, dy: f64, fine: bool) f64 {
    const pixels = if (fine) drag_pixels_fine else drag_pixels_full;
    return clampUnit(start - dy / pixels);
}

/// Double click resets to 0 dB.
pub fn isResetClick(clicks: i32) bool {
    return clicks == 2;
}

/// Position the fader jumps to on reset (unity gain).
pub fn resetPosition() f64 {
    return unity_position;
}

fn expectNear(expected: f64, actual: f64) !void {
    try testing.expectApproxEqAbs(expected, actual, 1e-9);
}

test "clampUnit clamps and handles non-finite" {
    try expectNear(0.0, clampUnit(-0.5));
    try expectNear(0.0, clampUnit(0.0));
    try expectNear(0.5, clampUnit(0.5));
    try expectNear(1.0, clampUnit(1.0));
    try expectNear(1.0, clampUnit(7.0));
    try expectNear(0.0, clampUnit(-std.math.inf(f64)));
    try expectNear(1.0, clampUnit(std.math.inf(f64)));
    try expectNear(0.0, clampUnit(std.math.nan(f64)));
}

test "gainToDb known values" {
    try expectNear(0.0, gainToDb(1.0));
    try expectNear(-6.020599913279624, gainToDb(0.5));
    try expectNear(6.020599913279624, gainToDb(2.0));
    try expectNear(-20.0, gainToDb(0.1));
}

test "gainToDb zero, negative and NaN are -inf" {
    try testing.expect(std.math.isNegativeInf(gainToDb(0.0)));
    try testing.expect(std.math.isNegativeInf(gainToDb(-1.0)));
    try testing.expect(std.math.isNegativeInf(gainToDb(-0.0)));
    try testing.expect(std.math.isNegativeInf(gainToDb(std.math.nan(f64))));
}

test "dbToGain known values" {
    try expectNear(1.0, dbToGain(0.0));
    try expectNear(0.5011872336272722, dbToGain(-6.0));
    try expectNear(0.1, dbToGain(-20.0));
    try expectNear(0.0, dbToGain(-std.math.inf(f64)));
}

test "dbToGain clamps above +6 dB and treats NaN as silence" {
    try expectNear(dbToGain(6.0), dbToGain(12.0));
    try expectNear(dbToGain(6.0), dbToGain(std.math.inf(f64)));
    try expectNear(0.0, dbToGain(std.math.nan(f64)));
}

test "gain and dB round trip" {
    const gains = [_]f64{ 0.001, 0.01, 0.1, 0.5, 1.0, 1.5, 1.99 };
    for (gains) |g| try testing.expectApproxEqRel(g, dbToGain(gainToDb(g)), 1e-9);
}

test "position boundaries" {
    try expectNear(0.0, gainToPosition(0.0));
    try expectNear(1.0, dbToPosition(max_db));
    try testing.expect(std.math.isNegativeInf(positionToDb(0.0)));
    try expectNear(max_db, positionToDb(1.0));
    try expectNear(0.0, dbToPosition(-std.math.inf(f64)));
}

test "unity gain sits at unity_position" {
    try expectNear(unity_position, dbToPosition(0.0));
    try expectNear(unity_position, gainToPosition(1.0));
    try expectNear(0.0, positionToDb(unity_position));
    try expectNear(1.0, positionToGain(unity_position));
}

test "out of range inputs clamp" {
    try expectNear(1.0, dbToPosition(20.0));
    try expectNear(1.0, dbToPosition(std.math.inf(f64)));
    try expectNear(0.0, dbToPosition(-1000.0));
    try expectNear(0.0, dbToPosition(std.math.nan(f64)));
    try expectNear(max_db, positionToDb(3.0));
    try testing.expect(std.math.isNegativeInf(positionToDb(-2.0)));
    try testing.expect(std.math.isNegativeInf(positionToDb(std.math.nan(f64))));
    try expectNear(0.0, positionToGain(-1.0));
    try expectNear(dbToGain(max_db), positionToGain(5.0));
    try expectNear(1.0, gainToPosition(100.0));
    try expectNear(0.0, gainToPosition(-3.0));
}

test "position is monotonic in dB and gain" {
    var prev_pos: f64 = -1.0;
    var prev_gain: f64 = -1.0;
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        const p = @as(f64, @floatFromInt(i)) / 100.0;
        const g = positionToGain(p);
        try testing.expect(p >= prev_pos);
        try testing.expect(g > prev_gain or (g == 0.0 and prev_gain <= 0.0));
        prev_pos = p;
        prev_gain = g;
    }
}

test "position round trips through dB and gain" {
    const positions = [_]f64{ 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0 };
    for (positions) |p| {
        try testing.expectApproxEqAbs(p, dbToPosition(positionToDb(p)), 1e-9);
        try testing.expectApproxEqAbs(p, gainToPosition(positionToGain(p)), 1e-9);
    }
}

test "dragPosition full range: 200 px sweeps the whole fader" {
    try expectNear(0.5, dragPosition(0.5, 0.0, false));
    try expectNear(1.0, dragPosition(0.0, -200.0, false));
    try expectNear(0.0, dragPosition(1.0, 200.0, false));
    try expectNear(0.6, dragPosition(0.5, -20.0, false));
}

test "dragPosition fine: 1000 px sweeps the whole fader" {
    try expectNear(1.0, dragPosition(0.0, -1000.0, true));
    try expectNear(0.0, dragPosition(1.0, 1000.0, true));
    try expectNear(0.52, dragPosition(0.5, -20.0, true));
}

test "dragPosition clamps and tolerates bad input" {
    try expectNear(1.0, dragPosition(0.9, -10000.0, false));
    try expectNear(0.0, dragPosition(0.1, 10000.0, true));
    try expectNear(1.0, dragPosition(2.0, 0.0, false));
    try expectNear(0.0, dragPosition(-2.0, 0.0, false));
    try expectNear(0.0, dragPosition(std.math.nan(f64), 0.0, false));
}

test "dragPosition fine moves five times less than coarse" {
    const coarse = dragPosition(0.5, -10.0, false) - 0.5;
    const fine = dragPosition(0.5, -10.0, true) - 0.5;
    try expectNear(5.0, coarse / fine);
}

test "double click resets to 0 dB" {
    try testing.expect(isResetClick(2));
    try testing.expect(!isResetClick(0));
    try testing.expect(!isResetClick(1));
    try testing.expect(!isResetClick(3));
    try testing.expect(!isResetClick(-1));
    try expectNear(unity_position, resetPosition());
    try expectNear(1.0, positionToGain(resetPosition()));
}
