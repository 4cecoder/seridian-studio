//! Piano roll geometry, pitch, grid and keyboard rules. Port of
//! src/ui/piano_math.h; tests mirror tests/ui/piano_math_test.c plus edge cases.
//! Piano roll geometry, pitch, grid and keyboard rules. Port of
//! src/ui/piano_math.h; tests mirror tests/ui/piano_math_test.c plus edge cases.
//! Pure math: no allocation, no globals, no UI dependencies.

const std = @import("std");
const testing = std.testing;

pub const min_note_px: f64 = 4.0;
pub const pitch_min: i32 = 0;
pub const pitch_max: i32 = 127;

/// Clamps a 64-bit integer into the MIDI pitch range 0..127.
pub fn clampPitch64(pitch: i64) i32 {
    if (pitch < pitch_min) return pitch_min;
    if (pitch > pitch_max) return pitch_max;
    return @intCast(pitch);
}

/// Horizontal pixel position of `beat` for a view starting at `view_start_beat`.
pub fn beatToX(beat: f64, view_start_beat: f64, px_per_beat: f64) f64 {
    return (beat - view_start_beat) * px_per_beat;
}

/// Inverse of beatToX. Points left of the view give beats before the view start.
/// A zero zoom divides by zero and yields +/-inf or NaN; it never traps.
pub fn xToBeat(x: f32, view_start_beat: f64, px_per_beat: f64) f64 {
    return view_start_beat + @as(f64, x) / px_per_beat;
}

/// Vertical position of a pitch row. The top pitch is row 0; rows run downward.
pub fn pitchToY(pitch: i32, top_pitch: i32, row_height: f32) f32 {
    // Widen before subtracting so extreme i32 pitches cannot overflow.
    const row: i64 = @as(i64, top_pitch) - @as(i64, pitch);
    return @as(f32, @floatFromInt(row)) * row_height;
}

/// Pitch under vertical position `y`. Division and floor happen in f64 and the
/// result is clamped before the integer conversion, so extreme `y` cannot trap.
/// A NaN `y` maps to the lowest pitch.
pub fn yToPitch(y: f32, top_pitch: i32, row_height: f32) i32 {
    const row = @floor(@as(f64, y) / @as(f64, row_height));
    if (std.math.isNan(row)) return pitch_min;
    const pitch = @as(f64, @floatFromInt(top_pitch)) - row;
    if (pitch < @as(f64, @floatFromInt(pitch_min))) return pitch_min;
    if (pitch > @as(f64, @floatFromInt(pitch_max))) return pitch_max;
    return @intFromFloat(pitch);
}

/// True for C#, D#, F#, G#, A# (pitch classes 1, 3, 6, 8, 10). Works for any i32.
pub fn isBlackKey(pitch: i32) bool {
    const pitch_class = @mod(pitch, 12);
    return switch (pitch_class) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// Rounds `beat` to the nearest multiple of `grid_beats` (halves away from zero),
/// never below zero. A non-positive grid disables snapping and returns `beat` unchanged.
pub fn snapBeat(beat: f64, grid_beats: f64) f64 {
    if (grid_beats <= 0.0) return beat;
    const snapped = @round(beat / grid_beats) * grid_beats;
    return if (snapped < 0.0) 0.0 else snapped;
}

/// Grid size for a menu index: 0 = 1/4, 1 = 1/8, 2 = 1/16, 3 = 1/32. Others give 1/4.
pub fn gridBeats(index: i32) f64 {
    return switch (index) {
        0 => 1.0,
        1 => 0.5,
        2 => 0.25,
        3 => 0.125,
        else => 1.0,
    };
}

/// Semitone offset for a lowercase computer keyboard key, or -1 if unmapped.
pub fn keyOffset(key: i32) i32 {
    return switch (key) {
        // White keys: a s d f g h j k l ;
        'a' => 0,
        's' => 2,
        'd' => 4,
        'f' => 5,
        'g' => 7,
        'h' => 9,
        'j' => 11,
        'k' => 12,
        'l' => 14,
        ';' => 16,
        // Black keys: w e t y u o p
        'w' => 1,
        'e' => 3,
        't' => 6,
        'y' => 8,
        'u' => 10,
        'o' => 13,
        'p' => 15,
        else => -1,
    };
}

/// RModifier bits from vendor/raven/include/raven/raven_window.h. Shift is not listed:
/// it does not change what a computer key means.
pub const modifier_ctrl: u32 = 1 << 1;
pub const modifier_alt: u32 = 1 << 2;
pub const modifier_super: u32 = 1 << 3;

/// True when computer keys may play notes or shift the octave: no Ctrl, Alt or Super
/// held. With any of those held the key belongs to a shortcut (Ctrl+Z, Ctrl+A, ...).
pub fn keyboardPlayAllowed(modifiers: u32) bool {
    return (modifiers & (modifier_ctrl | modifier_alt | modifier_super)) == 0;
}

/// MIDI pitch for a keyboard key played from `base_pitch`. Returns -1 when the key
/// is unmapped or the resulting pitch falls outside 0..127.
pub fn keyToPitch(key: i32, base_pitch: i32) i32 {
    const offset = keyOffset(key);
    if (offset < 0) return -1;
    const pitch = @as(i64, base_pitch) + @as(i64, offset);
    if (pitch < pitch_min or pitch > pitch_max) return -1;
    return @intCast(pitch);
}

/// Moves a pitch by whole octaves, clamped to 0..127.
pub fn shiftOctave(pitch: i32, octaves: i32) i32 {
    const shifted = @as(i64, pitch) + 12 * @as(i64, octaves);
    return clampPitch64(shifted);
}

/// On-screen note width, never narrower than min_note_px so the note stays clickable.
pub fn noteWidth(length_beats: f64, px_per_beat: f64) f64 {
    const width = length_beats * px_per_beat;
    return if (width < min_note_px) min_note_px else width;
}

// ---- keyboard column labels ----

/// Largest key-label font size in pixels; keeps labels readable without dominating the key.
pub const key_label_max_px: f32 = 14.0;
/// Smallest key-label font size that still reads. Below this a key is left unlabelled.
pub const key_label_min_px: f32 = 6.0;
/// Horizontal gap kept between a label and the key edge on each side.
pub const key_label_pad_px: f32 = 2.0;
/// Approximate advance width of one label glyph as a fraction of its font size.
pub const key_label_advance: f32 = 0.6;
/// Label size as a fraction of the key height, leaving room above and below.
const key_label_height_ratio: f32 = 0.7;
/// Widest label on a key: a two-character note name ("C#") plus the computer-key letter.
const key_label_max_glyphs: f32 = 3.0;

/// Sharp names are spelled with '#'. Each name is NUL-terminated so it can be passed to a C text call.
pub const note_names = [12][:0]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// Computer-key letters in keyOffset order (offsets 0..16). Each plays a fixed offset from the base pitch.
pub const key_letters = "asdfghjkl;wetyuop";

/// Note name for a MIDI pitch, e.g. "C#" for 61. Works for any i32 (floored modulo).
pub fn noteName(pitch: i32) [:0]const u8 {
    const pitch_class: usize = @intCast(@mod(pitch, 12));
    return note_names[pitch_class];
}

/// Upper-case computer-key letter that plays `pitch` from `base_pitch`, or null when no
/// mapped key does. Pitches outside 0..127 never have a letter.
pub fn keyLetterFor(base_pitch: i32, pitch: i32) ?u8 {
    if (pitch < pitch_min or pitch > pitch_max) return null;
    for (key_letters) |letter| {
        if (keyToPitch(@as(i32, letter), base_pitch) == pitch) return std.ascii.toUpper(letter);
    }
    return null;
}

/// Font size and origins of a key's labels, relative to the key face's top-left corner.
/// `note_x` is the left edge of the note name; `letter_x` is the left edge of the computer-key letter.
pub const KeyLabelBox = struct { size: f32, note_x: f32, letter_x: f32, y: f32 };

/// Places a key's labels inside a key face of `key_width` by `row_height`. The note name
/// sits at the left edge and the computer-key letter at the right edge, both vertically
/// centred. The size is limited by the key height, by the width needed for the widest
/// label (note plus letter, with padding) and by key_label_max_px. Every key in a column
/// uses the same size. Returns null when the key is too small for the minimum readable
/// size, or when a dimension is zero, negative or NaN.
pub fn keyLabelBox(key_width: f32, row_height: f32) ?KeyLabelBox {
    if (!(key_width > 0.0) or !(row_height > 0.0)) return null;
    const max_by_height = row_height * key_label_height_ratio;
    const max_by_width = (key_width - 2.0 * key_label_pad_px) / (key_label_advance * key_label_max_glyphs);
    const size = @min(max_by_height, max_by_width, key_label_max_px);
    if (!(size >= key_label_min_px)) return null;
    const glyph_w = size * key_label_advance;
    return .{
        .size = size,
        .note_x = key_label_pad_px,
        .letter_x = key_width - key_label_pad_px - glyph_w,
        .y = (row_height - size) * 0.5,
    };
}

// ---- clamp ----

test "clampPitch64 clamps to 0..127 including extreme 64-bit values" {
    try testing.expectEqual(@as(i32, 0), clampPitch64(-1));
    try testing.expectEqual(@as(i32, 0), clampPitch64(std.math.minInt(i64)));
    try testing.expectEqual(@as(i32, 0), clampPitch64(0));
    try testing.expectEqual(@as(i32, 64), clampPitch64(64));
    try testing.expectEqual(@as(i32, 127), clampPitch64(127));
    try testing.expectEqual(@as(i32, 127), clampPitch64(128));
    try testing.expectEqual(@as(i32, 127), clampPitch64(std.math.maxInt(i64)));
}

// ---- beat <-> x ----

test "beatToX scales by zoom" {
    try testing.expectApproxEqAbs(@as(f64, 80.0), beatToX(6.0, 4.0, 40.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), beatToX(4.0, 4.0, 40.0), 1e-6);
}

test "beatToX before view start is negative, zero zoom collapses to 0" {
    try testing.expectApproxEqAbs(@as(f64, -80.0), beatToX(2.0, 4.0, 40.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), beatToX(100.0, 4.0, 0.0), 1e-9);
}

test "xToBeat is the inverse of beatToX" {
    const beats = [_]f64{ 0.0, 1.5, 7.25, 31.0 };
    for (beats) |b| {
        const x: f32 = @floatCast(beatToX(b, 2.0, 37.0));
        try testing.expectApproxEqAbs(b, xToBeat(x, 2.0, 37.0), 1e-4);
    }
}

test "xToBeat left of view gives beat before view start" {
    try testing.expect(xToBeat(-40.0, 4.0, 40.0) < 4.0);
    try testing.expectApproxEqAbs(@as(f64, 3.0), xToBeat(-40.0, 4.0, 40.0), 1e-9);
}

test "xToBeat at x=0 is the view start" {
    try testing.expectApproxEqAbs(@as(f64, 4.0), xToBeat(0.0, 4.0, 40.0), 1e-9);
}

test "xToBeat with zero px_per_beat is infinite, not a crash" {
    try testing.expect(std.math.isInf(xToBeat(10.0, 0.0, 0.0)));
}

// ---- pitch <-> y ----

test "top pitch is row zero" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), pitchToY(84, 84, 12.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 12.0), pitchToY(83, 84, 12.0), 1e-6);
}

test "pitchToY above the top pitch is negative" {
    try testing.expectApproxEqAbs(@as(f32, -24.0), pitchToY(86, 84, 12.0), 1e-6);
}

test "yToPitch round trips through row centres" {
    var pitch: i32 = 36;
    while (pitch <= 96) : (pitch += 7) {
        const y = pitchToY(pitch, 96, 12.0) + 6.0;
        try testing.expectEqual(pitch, yToPitch(y, 96, 12.0));
    }
}

test "yToPitch row boundaries floor" {
    try testing.expectEqual(@as(i32, 84), yToPitch(0.0, 84, 12.0));
    try testing.expectEqual(@as(i32, 84), yToPitch(11.999, 84, 12.0));
    try testing.expectEqual(@as(i32, 83), yToPitch(12.0, 84, 12.0));
    // Just above the top edge is the row above.
    try testing.expectEqual(@as(i32, 85), yToPitch(-0.001, 84, 12.0));
}

test "yToPitch clamps to MIDI range" {
    try testing.expectEqual(@as(i32, 127), yToPitch(-500.0, 100, 12.0));
    try testing.expectEqual(@as(i32, 0), yToPitch(5000.0, 10, 12.0));
}

test "yToPitch survives extreme y without overflow" {
    try testing.expectEqual(@as(i32, 127), yToPitch(-std.math.floatMax(f32), 60, 12.0));
    try testing.expectEqual(@as(i32, 0), yToPitch(std.math.floatMax(f32), 60, 12.0));
    try testing.expectEqual(@as(i32, 127), yToPitch(-std.math.inf(f32), 60, 12.0));
    try testing.expectEqual(@as(i32, 0), yToPitch(std.math.inf(f32), 60, 12.0));
}

test "yToPitch with zero row height clamps by sign of y" {
    try testing.expectEqual(@as(i32, 0), yToPitch(10.0, 60, 0.0));
    try testing.expectEqual(@as(i32, 127), yToPitch(-10.0, 60, 0.0));
}

test "yToPitch with out-of-range top pitch still clamps" {
    try testing.expectEqual(@as(i32, 127), yToPitch(0.0, 500, 12.0));
    try testing.expectEqual(@as(i32, 0), yToPitch(0.0, -500, 12.0));
}

test "isBlackKey identifies sharps" {
    try testing.expect(isBlackKey(61));
    try testing.expect(isBlackKey(70));
    try testing.expect(!isBlackKey(60));
    try testing.expect(!isBlackKey(64));
    try testing.expect(!isBlackKey(71));
}

test "isBlackKey covers all pitch classes" {
    const expected = [12]bool{ false, true, false, true, false, false, true, false, true, false, true, false };
    for (expected, 0..) |e, pc| {
        try testing.expectEqual(e, isBlackKey(@intCast(pc)));
    }
}

test "isBlackKey works for negative and huge pitches" {
    try testing.expect(isBlackKey(-11)); // pitch class 1
    try testing.expect(!isBlackKey(-12)); // pitch class 0
    try testing.expect(isBlackKey(-2)); // pitch class 10
    try testing.expect(isBlackKey(1 + 12 * 1000));
}

// ---- snapping ----

test "snapBeat rounds to nearest grid line" {
    try testing.expectApproxEqAbs(@as(f64, 1.5), snapBeat(1.3, 0.5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), snapBeat(1.2, 0.5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), snapBeat(2.0, 0.25), 1e-9);
}

test "snapBeat halfway rounds away from zero like C round()" {
    try testing.expectApproxEqAbs(@as(f64, 1.0), snapBeat(0.5, 1.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), snapBeat(1.5, 1.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), snapBeat(2.5, 1.0), 1e-9);
}

test "snapBeat never goes negative" {
    try testing.expectApproxEqAbs(@as(f64, 0.0), snapBeat(-0.4, 1.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), snapBeat(-100.0, 0.25), 1e-9);
}

test "snapBeat with disabled or negative grid is identity" {
    try testing.expectApproxEqAbs(@as(f64, 1.37), snapBeat(1.37, 0.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.37), snapBeat(1.37, -0.5), 1e-9);
    // Identity means negatives pass through unclamped, as in C.
    try testing.expectApproxEqAbs(@as(f64, -2.5), snapBeat(-2.5, 0.0), 1e-9);
}

test "gridBeats menu choices" {
    try testing.expectApproxEqAbs(@as(f64, 1.0), gridBeats(0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), gridBeats(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), gridBeats(2), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.125), gridBeats(3), 1e-9);
}

test "gridBeats out of range defaults to quarter" {
    try testing.expectApproxEqAbs(@as(f64, 1.0), gridBeats(99), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), gridBeats(-1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), gridBeats(4), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), gridBeats(std.math.minInt(i32)), 1e-9);
}

// ---- computer keyboard -> notes ----

test "keyOffset full map" {
    const map = [_]struct { u8, i32 }{
        .{ 'a', 0 },  .{ 's', 2 },  .{ 'd', 4 },  .{ 'f', 5 },  .{ 'g', 7 },
        .{ 'h', 9 },  .{ 'j', 11 }, .{ 'k', 12 }, .{ 'l', 14 }, .{ ';', 16 },
        .{ 'w', 1 },  .{ 'e', 3 },  .{ 't', 6 },  .{ 'y', 8 },  .{ 'u', 10 },
        .{ 'o', 13 }, .{ 'p', 15 },
    };
    for (map) |m| try testing.expectEqual(m[1], keyOffset(m[0]));
}

test "keyOffset unmapped keys are -1" {
    try testing.expectEqual(@as(i32, -1), keyOffset('q'));
    try testing.expectEqual(@as(i32, -1), keyOffset('1'));
    try testing.expectEqual(@as(i32, -1), keyOffset(0));
    try testing.expectEqual(@as(i32, -1), keyOffset(-1));
    try testing.expectEqual(@as(i32, -1), keyOffset(' '));
    // Uppercase is not mapped: input is expected lowercase.
    try testing.expectEqual(@as(i32, -1), keyOffset('A'));
    try testing.expectEqual(@as(i32, -1), keyOffset(std.math.maxInt(i32)));
}

test "home row plays white keys from base" {
    try testing.expectEqual(@as(i32, 60), keyToPitch('a', 60));
    try testing.expectEqual(@as(i32, 62), keyToPitch('s', 60));
    try testing.expectEqual(@as(i32, 64), keyToPitch('d', 60));
    try testing.expectEqual(@as(i32, 71), keyToPitch('j', 60));
}

test "upper row plays black keys" {
    try testing.expectEqual(@as(i32, 61), keyToPitch('w', 60));
    try testing.expectEqual(@as(i32, 63), keyToPitch('e', 60));
    try testing.expectEqual(@as(i32, 70), keyToPitch('u', 60));
}

test "keyToPitch unmapped key is negative" {
    try testing.expect(keyToPitch('q', 60) < 0);
    try testing.expect(keyToPitch('1', 60) < 0);
}

test "keyToPitch out of MIDI range is -1, boundaries inclusive" {
    try testing.expectEqual(@as(i32, -1), keyToPitch('k', 125)); // 137
    try testing.expectEqual(@as(i32, 0), keyToPitch('a', 0));
    try testing.expectEqual(@as(i32, 127), keyToPitch('a', 127));
    try testing.expectEqual(@as(i32, -1), keyToPitch('s', 127)); // 129
    try testing.expectEqual(@as(i32, 127), keyToPitch('s', 125));
    try testing.expectEqual(@as(i32, -1), keyToPitch('a', -1));
    try testing.expectEqual(@as(i32, 0), keyToPitch('s', -2));
    try testing.expectEqual(@as(i32, -1), keyToPitch('s', -3));
}

test "keyToPitch does not overflow with extreme base" {
    try testing.expectEqual(@as(i32, -1), keyToPitch(';', std.math.maxInt(i32)));
    try testing.expectEqual(@as(i32, -1), keyToPitch('a', std.math.minInt(i32)));
}

test "shiftOctave moves by 12 and clamps" {
    try testing.expectEqual(@as(i32, 48), shiftOctave(60, -1));
    try testing.expectEqual(@as(i32, 72), shiftOctave(60, 1));
    try testing.expectEqual(@as(i32, 60), shiftOctave(60, 0));
    try testing.expectEqual(@as(i32, 0), shiftOctave(5, -1));
    try testing.expectEqual(@as(i32, 127), shiftOctave(125, 1));
}

test "shiftOctave handles extreme octave counts" {
    try testing.expectEqual(@as(i32, 127), shiftOctave(60, std.math.maxInt(i32)));
    try testing.expectEqual(@as(i32, 0), shiftOctave(60, std.math.minInt(i32)));
    try testing.expectEqual(@as(i32, 127), shiftOctave(std.math.maxInt(i32), std.math.maxInt(i32)));
    try testing.expectEqual(@as(i32, 0), shiftOctave(std.math.minInt(i32), std.math.minInt(i32)));
}

test "keyboardPlayAllowed is true with no modifiers or Shift only" {
    try testing.expect(keyboardPlayAllowed(0));
    try testing.expect(keyboardPlayAllowed(1 << 0)); // Shift
}

test "keyboardPlayAllowed is false when Ctrl, Alt or Super is held" {
    try testing.expect(!keyboardPlayAllowed(modifier_ctrl));
    try testing.expect(!keyboardPlayAllowed(modifier_alt));
    try testing.expect(!keyboardPlayAllowed(modifier_super));
    try testing.expect(!keyboardPlayAllowed(modifier_ctrl | 1)); // Ctrl+Shift
    try testing.expect(!keyboardPlayAllowed(modifier_ctrl | modifier_alt | modifier_super | 1));
}

test "Ctrl+Z and Ctrl+A are blocked from the keyboard, plain Z and A are not" {
    // Ctrl+Z must not shift the octave and Ctrl+A must not play 'a'.
    // Plain 'a' still maps to offset 0 and plain Z/A pass the modifier rule.
    try testing.expect(!keyboardPlayAllowed(modifier_ctrl));
    try testing.expectEqual(@as(i32, 0), keyOffset('a'));
    try testing.expect(keyboardPlayAllowed(0));
}

// ---- note geometry ----

test "noteWidth never below minimum" {
    try testing.expectApproxEqAbs(min_note_px, noteWidth(0.001, 40.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 40.0), noteWidth(1.0, 40.0), 1e-6);
}

test "noteWidth boundary, zero and negative inputs" {
    try testing.expectApproxEqAbs(@as(f64, 4.0), noteWidth(0.1, 40.0), 1e-9); // exactly min
    try testing.expectApproxEqAbs(min_note_px, noteWidth(0.0, 40.0), 1e-9);
    try testing.expectApproxEqAbs(min_note_px, noteWidth(-3.0, 40.0), 1e-9);
    try testing.expectApproxEqAbs(min_note_px, noteWidth(4.0, 0.0), 1e-9);
}

// ---- keyboard label placement ----

test "keyLabelBox fits a white key and stays inside it" {
    const key_w: f32 = 54.0;
    const key_h: f32 = 12.0;
    const box = keyLabelBox(key_w, key_h) orelse return error.TestUnexpectedResult;
    try testing.expect(box.size >= key_label_min_px and box.size <= key_label_max_px);
    try testing.expect(box.size <= key_h * 0.7 + 1e-5);
    try testing.expect(box.note_x >= key_label_pad_px - 1e-5);
    try testing.expect(box.letter_x + box.size * 0.6 <= key_w - key_label_pad_px + 1e-5);
    try testing.expect(box.y >= 0.0 and box.y + box.size <= key_h + 1e-5);
}

test "keyLabelBox is vertically centred and right-aligns the letter" {
    const key_w: f32 = 54.0;
    const box = keyLabelBox(key_w, 12.0) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 12.0), 2.0 * box.y + box.size, 1e-4);
    try testing.expectApproxEqAbs(key_w - key_label_pad_px, box.letter_x + box.size * 0.6, 1e-4);
}

test "keyLabelBox fits a narrow black key with note and letter side by side" {
    const black_w: f32 = 34.0;
    const box = keyLabelBox(black_w, 12.0) orelse return error.TestUnexpectedResult;
    try testing.expect(box.note_x >= key_label_pad_px - 1e-5);
    try testing.expect(box.letter_x + box.size * 0.6 <= black_w - key_label_pad_px + 1e-5);
    // Two-character note name must end before the letter starts.
    try testing.expect(box.note_x + 2.0 * box.size * 0.6 <= box.letter_x + 1e-5);
}

test "keyLabelBox caps the size at key_label_max_px on tall keys" {
    const box = keyLabelBox(200.0, 40.0) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(key_label_max_px, box.size, 1e-6);
}

test "keyLabelBox returns null when the key is too small to read" {
    try testing.expect(keyLabelBox(54.0, 8.0) == null); // 0.7 * 8 < minimum
    try testing.expect(keyLabelBox(6.0, 12.0) == null); // too narrow for pad + glyph
    try testing.expect(keyLabelBox(4.0, 12.0) == null);
}

test "keyLabelBox rejects zero, negative and NaN dimensions" {
    try testing.expect(keyLabelBox(0.0, 12.0) == null);
    try testing.expect(keyLabelBox(54.0, 0.0) == null);
    try testing.expect(keyLabelBox(-54.0, 12.0) == null);
    try testing.expect(keyLabelBox(54.0, -12.0) == null);
    try testing.expect(keyLabelBox(std.math.nan(f32), 12.0) == null);
    try testing.expect(keyLabelBox(54.0, std.math.nan(f32)) == null);
}

test "keyLabelBox size grows with the row height up to the cap" {
    const small = keyLabelBox(54.0, 10.0) orelse return error.TestUnexpectedResult;
    const large = keyLabelBox(54.0, 16.0) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 7.0), small.size, 1e-4); // 0.7 * 10
    try testing.expectApproxEqAbs(@as(f32, 11.2), large.size, 1e-4); // 0.7 * 16, under the cap
    try testing.expect(large.size > small.size);
}

test "every key in an octave gets a non-empty note name" {
    var pitch: i32 = 60;
    while (pitch < 72) : (pitch += 1) {
        try testing.expect(noteName(pitch).len > 0);
    }
    try testing.expectEqualStrings("C", noteName(60));
    try testing.expectEqualStrings("C#", noteName(61));
    try testing.expectEqualStrings("A#", noteName(70));
    try testing.expectEqualStrings("B", noteName(71));
    try testing.expectEqualStrings("C", noteName(72));
    try testing.expectEqualStrings("A#", noteName(-2));
}

test "every key in an octave has a label box at the default row height" {
    // The default piano-roll row is 12 px, so every key face (white 55 px, black 34 px) must fit a label.
    const white = keyLabelBox(55.0, 11.0) orelse return error.TestUnexpectedResult;
    const black = keyLabelBox(34.0, 11.0) orelse return error.TestUnexpectedResult;
    try testing.expect(white.size >= key_label_min_px);
    try testing.expectApproxEqAbs(white.size, black.size, 1e-6);
}

test "mapped keys in an octave include their computer-key letter" {
    const base: i32 = 60;
    var mapped: usize = 0;
    var pitch: i32 = base;
    while (pitch < base + 17) : (pitch += 1) {
        if (keyLetterFor(base, pitch)) |letter| {
            mapped += 1;
            try testing.expect((letter >= 'A' and letter <= 'Z') or letter == ';');
            try testing.expectEqual(pitch, keyToPitch(std.ascii.toLower(letter), base));
        }
    }
    try testing.expectEqual(@as(usize, 17), mapped);
}

test "every key letter maps back to its upper-case label" {
    for (key_letters) |letter| {
        const pitch = keyToPitch(letter, 60);
        try testing.expect(pitch >= 0);
        try testing.expectEqual(std.ascii.toUpper(letter), keyLetterFor(60, pitch) orelse return error.TestUnexpectedResult);
    }
}

test "keyLetterFor is null for unmapped and out-of-range pitches" {
    try testing.expect(keyLetterFor(60, 60 + 17) == null); // one past the 17-key span
    try testing.expect(keyLetterFor(0, -1) == null);
    try testing.expect(keyLetterFor(125, 128) == null);
}
