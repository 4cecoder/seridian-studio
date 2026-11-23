//! Piano roll geometry, grid and keyboard rules (ported from tests/ui/piano_math_test.c, every assertion kept).
//! The C names map to src/ui/zig/piano_math.zig as piano_beat_to_x -> beatToX, piano_x_to_beat -> xToBeat,
//! piano_pitch_to_y -> pitchToY, piano_y_to_pitch -> yToPitch, piano_is_black_key -> isBlackKey (int -> bool),
//! piano_snap_beat -> snapBeat, piano_grid_beats -> gridBeats, piano_key_to_pitch -> keyToPitch,
//! piano_shift_octave -> shiftOctave, piano_note_width -> noteWidth, PIANO_MIN_NOTE_PX -> min_note_px.

const std = @import("std");
const piano = @import("ui_impl").piano_math;
const expect = std.testing.expect;

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

// ---- beat <-> x ----

test "beat to x scales by zoom" {
    // 40 px per beat, view starts at beat 4: beat 6 is 2 beats in, 80 px.
    try expectNear(piano.beatToX(6.0, 4.0, 40.0), 80.0, 1e-6);
    try expectNear(piano.beatToX(4.0, 4.0, 40.0), 0.0, 1e-6);
}

test "x to beat is inverse" {
    const beats = [_]f64{ 0.0, 1.5, 7.25, 31.0 };
    for (beats) |beat| {
        // `const float x = piano_beat_to_x(...)`: the C narrows to float.
        const x: f32 = @floatCast(piano.beatToX(beat, 2.0, 37.0));
        try expectNear(piano.xToBeat(x, 2.0, 37.0), beat, 1e-4);
    }
}

test "x before view start is negative beat" {
    // Scrolled past: a point left of the view maps to a beat before the view.
    try expect(piano.xToBeat(-40.0, 4.0, 40.0) < 4.0);
}

// ---- pitch <-> y ----

test "top pitch is row zero" {
    try expectNear(piano.pitchToY(84, 84, 12.0), 0.0, 1e-6);
    try expectNear(piano.pitchToY(83, 84, 12.0), 12.0, 1e-6);
}

test "y to pitch round trips" {
    var pitch: i32 = 36;
    while (pitch <= 96) : (pitch += 7) {
        const y = piano.pitchToY(pitch, 96, 12.0) + 6.0; // centre of row
        try expect(piano.yToPitch(y, 96, 12.0) == pitch);
    }
}

test "y to pitch clamps to midi range" {
    try expect(piano.yToPitch(-500.0, 100, 12.0) == 127);
    try expect(piano.yToPitch(5000.0, 10, 12.0) == 0);
}

test "black keys" {
    // C#, D#, F#, G#, A# are black; C, D, E, F, G, A, B are white.
    try expect(piano.isBlackKey(61) == true);
    try expect(piano.isBlackKey(70) == true);
    try expect(piano.isBlackKey(60) == false);
    try expect(piano.isBlackKey(64) == false);
    try expect(piano.isBlackKey(71) == false);
}

// ---- snapping ----

test "snap rounds to grid" {
    try expectNear(piano.snapBeat(1.3, 0.5), 1.5, 1e-9);
    try expectNear(piano.snapBeat(1.2, 0.5), 1.0, 1e-9);
    try expectNear(piano.snapBeat(2.0, 0.25), 2.0, 1e-9);
}

test "snap never goes negative" {
    try expectNear(piano.snapBeat(-0.4, 1.0), 0.0, 1e-9);
}

test "snap disabled grid is identity" {
    try expectNear(piano.snapBeat(1.37, 0.0), 1.37, 1e-9);
}

test "grid choices" {
    try expectNear(piano.gridBeats(0), 1.0, 1e-9); // 1/4
    try expectNear(piano.gridBeats(1), 0.5, 1e-9); // 1/8
    try expectNear(piano.gridBeats(2), 0.25, 1e-9); // 1/16
    try expectNear(piano.gridBeats(3), 0.125, 1e-9); // 1/32
    try expectNear(piano.gridBeats(99), 1.0, 1e-9); // out of range -> default
}

// ---- computer keyboard -> notes ----

test "home row plays white keys from base" {
    // a s d f g h j k are C D E F G A B C in the base octave.
    try expect(piano.keyToPitch('a', 60) == 60);
    try expect(piano.keyToPitch('s', 60) == 62);
    try expect(piano.keyToPitch('d', 60) == 64);
    try expect(piano.keyToPitch('j', 60) == 71);
}

test "upper row plays black keys" {
    // w e t y u are C# D# F# G# A#.
    try expect(piano.keyToPitch('w', 60) == 61);
    try expect(piano.keyToPitch('e', 60) == 63);
    try expect(piano.keyToPitch('u', 60) == 70);
}

test "unmapped key is negative" {
    try expect(piano.keyToPitch('q', 60) < 0);
    try expect(piano.keyToPitch('1', 60) < 0);
}

test "key pitch is clamped to midi" {
    try expect(piano.keyToPitch('k', 125) == -1); // 137 is outside MIDI, so unmapped
    try expect(piano.keyToPitch('a', 0) == 0);
}

test "octave shift clamps" {
    try expect(piano.shiftOctave(60, -1) == 48);
    try expect(piano.shiftOctave(60, 1) == 72);
    try expect(piano.shiftOctave(5, -1) == 0);
    try expect(piano.shiftOctave(125, 1) == 127);
}

// ---- note geometry ----

test "note width is never below minimum" {
    try expectNear(piano.noteWidth(0.001, 40.0), piano.min_note_px, 1e-6);
    try expectNear(piano.noteWidth(1.0, 40.0), 40.0, 1e-6);
}
