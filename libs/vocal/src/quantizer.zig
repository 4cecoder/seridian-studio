// Translated to Zig from pitchpure/crates/pitchpure_engine/src/quantizer.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Scale quantizer: snaps fractional MIDI notes to the nearest allowed scale degree.
//!
//! The scale is defined by a root MIDI note and a 12-bit mask. Mask bit `i`
//! allows the pitch class `i` semitones above the root (mod 12). Only the
//! low twelve bits of the mask are used.

const std = @import("std");

/// Snaps fractional MIDI note numbers to the nearest allowed semitone.
///
/// Pitch class of a candidate `c` is `(c - root_midi) mod 12` (Euclidean);
/// the candidate is allowed when `(mask >> class) & 1 == 1`.
pub const Quantizer = struct {
    root_midi_: u8,
    scale_mask_: u16,

    /// All twelve pitch classes allowed.
    pub const chromatic: u16 = 0xFFF;
    /// Major scale intervals `0, 2, 4, 5, 7, 9, 11`.
    pub const major: u16 = 0xAB5;
    /// Natural minor scale intervals `0, 2, 3, 5, 7, 8, 10`.
    pub const minor: u16 = 0x5AD;

    const mask_bits: u16 = 0xFFF;
    const midi_min: f32 = 0.0;
    const midi_max: f32 = 127.0;

    /// Build a quantizer from a root MIDI note and a 12-bit scale mask.
    /// A zero mask means bypass.
    pub fn init(root_midi: u8, scale_mask: u16) Quantizer {
        return .{ .root_midi_ = root_midi, .scale_mask_ = scale_mask };
    }

    /// Replace the scale mask. Only the low twelve bits are used.
    pub fn setMask(self: *Quantizer, mask: u16) void {
        self.scale_mask_ = mask;
    }

    /// Replace the scale root MIDI note.
    pub fn setRoot(self: *Quantizer, root: u8) void {
        self.root_midi_ = root;
    }

    /// Current root MIDI note.
    pub fn rootMidi(self: Quantizer) u8 {
        return self.root_midi_;
    }

    /// Current raw scale mask (including any bits above the low twelve).
    pub fn scaleMask(self: Quantizer) u16 {
        return self.scale_mask_;
    }

    fn isAllowed(self: Quantizer, allowed: u16, candidate: i32) bool {
        const class: u4 = @intCast(@mod(candidate - @as(i32, self.root_midi_), 12));
        return (allowed >> class) & 1 == 1;
    }

    /// Snap fractional `midi` to the nearest allowed semitone in `0..=127`.
    /// Exact ties resolve toward the lower note. Returns the input unchanged
    /// when the masked scale is empty or the input is non-finite.
    pub fn quantizeMidi(self: Quantizer, midi: f32) f32 {
        const allowed = self.scale_mask_ & mask_bits;
        if (allowed == 0 or !std.math.isFinite(midi)) return midi;
        const target = std.math.clamp(midi, midi_min, midi_max);
        var best: i32 = 0;
        var best_dist = std.math.inf(f32);
        var found = false;
        var candidate: i32 = 0;
        while (candidate <= 127) : (candidate += 1) {
            if (!self.isAllowed(allowed, candidate)) continue;
            const dist = @abs(@as(f32, @floatFromInt(candidate)) - target);
            if (dist < best_dist) {
                best_dist = dist;
                best = candidate;
                found = true;
            }
        }
        return if (found) @floatFromInt(best) else midi;
    }
};

const testing = std.testing;

fn cMajor() Quantizer {
    return Quantizer.init(60, Quantizer.major);
}

test "scale_masks_match_spec" {
    try testing.expectEqual(@as(u16, 0xFFF), Quantizer.chromatic);
    try testing.expectEqual(@as(u16, 0xAB5), Quantizer.major);
    try testing.expectEqual(@as(u16, 0x5AD), Quantizer.minor);
}

test "e_stays_in_c_major" {
    const q = cMajor();
    try testing.expect(@abs(q.quantizeMidi(64.4) - 64.0) < 1e-6);
}

test "c_sharp_snaps_down_in_c_major" {
    try testing.expectEqual(@as(f32, 60.0), cMajor().quantizeMidi(61.0));
}

test "snaps_up_to_nearest_in_c_major" {
    try testing.expectEqual(@as(f32, 62.0), cMajor().quantizeMidi(61.6));
}

test "chromatic_keeps_every_semitone" {
    const q = Quantizer.init(60, Quantizer.chromatic);
    var note: i32 = 0;
    while (note <= 127) : (note += 1) {
        const f: f32 = @floatFromInt(note);
        try testing.expectEqual(f, q.quantizeMidi(f));
    }
}

test "chromatic_rounds_fractional_to_nearest_tie_down" {
    const q = Quantizer.init(60, Quantizer.chromatic);
    try testing.expectEqual(@as(f32, 64.0), q.quantizeMidi(64.4));
    try testing.expectEqual(@as(f32, 65.0), q.quantizeMidi(64.6));
    try testing.expectEqual(@as(f32, 64.0), q.quantizeMidi(64.5));
}

test "empty_mask_passes_through" {
    const q = Quantizer.init(60, 0);
    try testing.expectEqual(@as(f32, 61.3), q.quantizeMidi(61.3));
    try testing.expectEqual(@as(f32, 64.4), q.quantizeMidi(64.4));
}

test "d_major_allows_c_sharp" {
    const q = Quantizer.init(62, Quantizer.major);
    try testing.expectEqual(@as(f32, 61.0), q.quantizeMidi(61.0));
}

test "setters_take_effect" {
    var q = cMajor();
    q.setRoot(62);
    try testing.expectEqual(@as(f32, 61.0), q.quantizeMidi(61.0));
    q.setMask(0);
    try testing.expectEqual(@as(f32, 61.3), q.quantizeMidi(61.3));
    q.setMask(Quantizer.chromatic);
    try testing.expectEqual(@as(f32, 61.0), q.quantizeMidi(61.3));
}

test "ties_go_down_and_output_clamped" {
    const q = cMajor();
    try testing.expectEqual(@as(f32, 60.0), q.quantizeMidi(61.0));
    try testing.expect(q.quantizeMidi(-10.0) >= 0.0);
    try testing.expect(q.quantizeMidi(200.0) <= 127.0);
    try testing.expectEqual(q.quantizeMidi(0.0), q.quantizeMidi(-10.0));
}

test "minor_mask_has_expected_degrees" {
    const q = Quantizer.init(60, Quantizer.minor);
    for ([_]f32{ 60.0, 62.0, 63.0, 65.0, 67.0, 68.0, 70.0 }) |allowed| {
        try testing.expectEqual(allowed, q.quantizeMidi(allowed));
    }
    try testing.expectEqual(@as(f32, 60.0), q.quantizeMidi(61.0));
}
