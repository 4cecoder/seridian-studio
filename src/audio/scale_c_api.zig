//! Scale/Key Lock C API for GTK UI
//!
//! Exposes scale/key functionality to C code for keyboard input filtering
//! and piano roll visualization.

const std = @import("std");
const pitch = @import("../dsp/pitch.zig");
const Scale = pitch.Scale;

// =============================================================================
// Scale Type Enumeration
// =============================================================================

/// Scale types available to the UI (matches dropdown order)
pub const ScaleType = enum(c_int) {
    chromatic = 0,
    major = 1,
    natural_minor = 2,
    harmonic_minor = 3,
    melodic_minor = 4,
    pentatonic_major = 5,
    pentatonic_minor = 6,
    blues = 7,
    dorian = 8,
    phrygian = 9,
    lydian = 10,
    mixolydian = 11,
};

/// Scale names for UI display
const scale_names = [_][*:0]const u8{
    "Chromatic",
    "Major",
    "Natural Minor",
    "Harmonic Minor",
    "Melodic Minor",
    "Pentatonic Major",
    "Pentatonic Minor",
    "Blues",
    "Dorian",
    "Phrygian",
    "Lydian",
    "Mixolydian",
};

/// Note names for root selection
const note_names = [_][*:0]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
};

fn getScaleByType(scale_type: ScaleType) Scale {
    return switch (scale_type) {
        .chromatic => Scale.chromatic,
        .major => Scale.major,
        .natural_minor => Scale.natural_minor,
        .harmonic_minor => Scale.harmonic_minor,
        .melodic_minor => Scale.melodic_minor,
        .pentatonic_major => Scale.pentatonic_major,
        .pentatonic_minor => Scale.pentatonic_minor,
        .blues => Scale.blues,
        .dorian => Scale.dorian,
        .phrygian => Scale.phrygian,
        .lydian => Scale.lydian,
        .mixolydian => Scale.mixolydian,
    };
}

// =============================================================================
// C API Exports
// =============================================================================

/// Get the number of available scales
export fn scale_get_count() callconv(.c) c_int {
    return scale_names.len;
}

/// Get scale name by index
export fn scale_get_name(index: c_int) callconv(.c) [*:0]const u8 {
    if (index < 0 or index >= scale_names.len) return "Unknown";
    return scale_names[@intCast(index)];
}

/// Get the number of root notes (always 12)
export fn scale_get_root_count() callconv(.c) c_int {
    return 12;
}

/// Get root note name by index (0-11)
export fn scale_get_root_name(index: c_int) callconv(.c) [*:0]const u8 {
    if (index < 0 or index >= 12) return "?";
    return note_names[@intCast(index)];
}

/// Check if a MIDI note is in the given scale
/// @param scale_type Scale type (0-11, see ScaleType enum)
/// @param root_note Root note (0-11, where 0=C, 1=C#, etc.)
/// @param midi_note MIDI note to check (0-127)
/// @return 1 if note is in scale, 0 if not
export fn scale_contains_note(scale_type: c_int, root_note: c_int, midi_note: c_int) callconv(.c) c_int {
    if (scale_type < 0 or scale_type >= scale_names.len) return 0;
    if (root_note < 0 or root_note > 11) return 0;
    if (midi_note < 0 or midi_note > 127) return 0;

    const scale = getScaleByType(@fromBackingInt(@intCast(scale_type)));
    const contains = scale.containsNote(@intCast(root_note), @intCast(midi_note));
    return if (contains) 1 else 0;
}

/// Quantize a MIDI note to the nearest note in scale
/// @param scale_type Scale type (0-11)
/// @param root_note Root note (0-11)
/// @param midi_note Input MIDI note (0-127)
/// @return Quantized MIDI note (0-127)
export fn scale_quantize_note(scale_type: c_int, root_note: c_int, midi_note: c_int) callconv(.c) c_int {
    if (scale_type < 0 or scale_type >= scale_names.len) return midi_note;
    if (root_note < 0 or root_note > 11) return midi_note;
    if (midi_note < 0 or midi_note > 127) return midi_note;

    const scale = getScaleByType(@fromBackingInt(@intCast(scale_type)));
    const freq = pitch.midiToFreq(@floatFromInt(midi_note));
    const result = scale.quantizeToScale(@intCast(root_note), freq);
    return @intCast(result.midi);
}

/// Get the number of notes in a scale (degrees)
export fn scale_get_degree_count(scale_type: c_int) callconv(.c) c_int {
    if (scale_type < 0 or scale_type >= scale_names.len) return 12;
    const scale = getScaleByType(@fromBackingInt(@intCast(scale_type)));
    return @intCast(scale.intervals.len);
}

/// Get scale degree interval (semitones from root)
export fn scale_get_degree_interval(scale_type: c_int, degree: c_int) callconv(.c) c_int {
    if (scale_type < 0 or scale_type >= scale_names.len) return 0;
    const scale = getScaleByType(@fromBackingInt(@intCast(scale_type)));
    if (degree < 0 or degree >= scale.intervals.len) return 0;
    return @intCast(scale.intervals[@intCast(degree)]);
}

/// Map a scale degree (0-6 for 7-note scales) to MIDI note in a given octave
/// @param scale_type Scale type
/// @param root_note Root note (0-11)
/// @param degree Scale degree (0 = root, 1 = second, etc.)
/// @param octave MIDI octave (0-10)
/// @return MIDI note number
export fn scale_degree_to_midi(scale_type: c_int, root_note: c_int, degree: c_int, octave: c_int) callconv(.c) c_int {
    if (scale_type < 0 or scale_type >= scale_names.len) return 60;
    if (root_note < 0 or root_note > 11) return 60;
    if (octave < 0 or octave > 10) return 60;

    const scale = getScaleByType(@fromBackingInt(@intCast(scale_type)));
    const num_degrees: i32 = @intCast(scale.intervals.len);

    // Handle degrees beyond one octave
    const octave_offset = @divFloor(degree, num_degrees);
    const degree_in_octave = @mod(degree, num_degrees);

    if (degree_in_octave < 0 or degree_in_octave >= num_degrees) return 60;

    const interval: i32 = @intCast(scale.intervals[@intCast(degree_in_octave)]);
    const midi: i32 = root_note + (octave + octave_offset) * 12 + interval;

    // Clamp to valid MIDI range
    if (midi < 0) return 0;
    if (midi > 127) return 127;
    return midi;
}
