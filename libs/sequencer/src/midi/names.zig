// Translated to Zig from soundcraft/crates/midi/src/names.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Display names for MIDI notes, General MIDI drum keys and General MIDI programs.
//!
//! The Rust `String` return of `note_name` becomes a fixed-size value type, so no
//! allocation is needed. The name tables are comptime constants.

const std = @import("std");
const testing = std.testing;

const pitch_classes = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// A note name such as "C3" or "C#-2". Longest possible name is 4 bytes; the
/// buffer is 8 so every `u8` pitch fits.
pub const NoteName = struct {
    buf: [8]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const NoteName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Note name using the Pro Tools convention where middle C (60) is "C3" (so 0 is "C-2").
pub fn noteName(pitch: u8) NoteName {
    var out: NoteName = .{};
    const class = pitch_classes[pitch % 12];
    const octave: i32 = @as(i32, pitch / 12) - 2;
    // The longest result ("C#-2" or "D#19") fits in 8 bytes, so this cannot fail.
    const written = std.fmt.bufPrint(&out.buf, "{s}{d}", .{ class, octave }) catch unreachable;
    out.len = written.len;
    return out;
}

const gm_drums = [47][]const u8{
    "Acoustic Bass Drum",
    "Bass Drum 1",
    "Side Stick",
    "Acoustic Snare",
    "Hand Clap",
    "Electric Snare",
    "Low Floor Tom",
    "Closed Hi-Hat",
    "High Floor Tom",
    "Pedal Hi-Hat",
    "Low Tom",
    "Open Hi-Hat",
    "Low-Mid Tom",
    "Hi-Mid Tom",
    "Crash Cymbal 1",
    "High Tom",
    "Ride Cymbal 1",
    "Chinese Cymbal",
    "Ride Bell",
    "Tambourine",
    "Splash Cymbal",
    "Cowbell",
    "Crash Cymbal 2",
    "Vibraslap",
    "Ride Cymbal 2",
    "Hi Bongo",
    "Low Bongo",
    "Mute Hi Conga",
    "Open Hi Conga",
    "Low Conga",
    "High Timbale",
    "Low Timbale",
    "High Agogo",
    "Low Agogo",
    "Cabasa",
    "Maracas",
    "Short Whistle",
    "Long Whistle",
    "Short Guiro",
    "Long Guiro",
    "Claves",
    "Hi Wood Block",
    "Low Wood Block",
    "Mute Cuica",
    "Open Cuica",
    "Mute Triangle",
    "Open Triangle",
};

/// General MIDI (level 1) percussion key-map name for a pitch on channel 10 (keys 35..=81).
pub fn gmDrumName(pitch: u8) ?[]const u8 {
    if (pitch < 35) return null;
    const idx: usize = pitch - 35;
    if (idx >= gm_drums.len) return null;
    return gm_drums[idx];
}

const gm_programs = [128][]const u8{
    "Acoustic Grand Piano",
    "Bright Acoustic Piano",
    "Electric Grand Piano",
    "Honky-tonk Piano",
    "Electric Piano 1",
    "Electric Piano 2",
    "Harpsichord",
    "Clavi",
    "Celesta",
    "Glockenspiel",
    "Music Box",
    "Vibraphone",
    "Marimba",
    "Xylophone",
    "Tubular Bells",
    "Dulcimer",
    "Drawbar Organ",
    "Percussive Organ",
    "Rock Organ",
    "Church Organ",
    "Reed Organ",
    "Accordion",
    "Harmonica",
    "Tango Accordion",
    "Acoustic Guitar (nylon)",
    "Acoustic Guitar (steel)",
    "Electric Guitar (jazz)",
    "Electric Guitar (clean)",
    "Electric Guitar (muted)",
    "Overdriven Guitar",
    "Distortion Guitar",
    "Guitar Harmonics",
    "Acoustic Bass",
    "Electric Bass (finger)",
    "Electric Bass (pick)",
    "Fretless Bass",
    "Slap Bass 1",
    "Slap Bass 2",
    "Synth Bass 1",
    "Synth Bass 2",
    "Violin",
    "Viola",
    "Cello",
    "Contrabass",
    "Tremolo Strings",
    "Pizzicato Strings",
    "Orchestral Harp",
    "Timpani",
    "String Ensemble 1",
    "String Ensemble 2",
    "SynthStrings 1",
    "SynthStrings 2",
    "Choir Aahs",
    "Voice Oohs",
    "Synth Voice",
    "Orchestra Hit",
    "Trumpet",
    "Trombone",
    "Tuba",
    "Muted Trumpet",
    "French Horn",
    "Brass Section",
    "SynthBrass 1",
    "SynthBrass 2",
    "Soprano Sax",
    "Alto Sax",
    "Tenor Sax",
    "Baritone Sax",
    "Oboe",
    "English Horn",
    "Bassoon",
    "Clarinet",
    "Piccolo",
    "Flute",
    "Recorder",
    "Pan Flute",
    "Blown Bottle",
    "Shakuhachi",
    "Whistle",
    "Ocarina",
    "Lead 1 (square)",
    "Lead 2 (sawtooth)",
    "Lead 3 (calliope)",
    "Lead 4 (chiff)",
    "Lead 5 (charang)",
    "Lead 6 (voice)",
    "Lead 7 (fifths)",
    "Lead 8 (bass + lead)",
    "Pad 1 (new age)",
    "Pad 2 (warm)",
    "Pad 3 (polysynth)",
    "Pad 4 (choir)",
    "Pad 5 (bowed)",
    "Pad 6 (metallic)",
    "Pad 7 (halo)",
    "Pad 8 (sweep)",
    "FX 1 (rain)",
    "FX 2 (soundtrack)",
    "FX 3 (crystal)",
    "FX 4 (atmosphere)",
    "FX 5 (brightness)",
    "FX 6 (goblins)",
    "FX 7 (echoes)",
    "FX 8 (sci-fi)",
    "Sitar",
    "Banjo",
    "Shamisen",
    "Koto",
    "Kalimba",
    "Bag pipe",
    "Fiddle",
    "Shanai",
    "Tinkle Bell",
    "Agogo",
    "Steel Drums",
    "Woodblock",
    "Taiko Drum",
    "Melodic Tom",
    "Synth Drum",
    "Reverse Cymbal",
    "Guitar Fret Noise",
    "Breath Noise",
    "Seashore",
    "Bird Tweet",
    "Telephone Ring",
    "Helicopter",
    "Applause",
    "Gunshot",
};

/// General MIDI (level 1) instrument name for a 0-based program number. Values above 127
/// return "Unknown".
pub fn gmProgramName(program: u8) []const u8 {
    if (program >= gm_programs.len) return "Unknown";
    return gm_programs[program];
}

test "names" {
    try testing.expectEqualStrings("C3", noteName(60).slice());
    try testing.expectEqualStrings("C-2", noteName(0).slice());
    try testing.expectEqualStrings("G8", noteName(127).slice());
    try testing.expectEqualStrings("C#3", noteName(61).slice());
    try testing.expectEqualStrings("Bass Drum 1", gmDrumName(36).?);
    try testing.expectEqualStrings("Open Triangle", gmDrumName(81).?);
    try testing.expect(gmDrumName(34) == null);
    try testing.expect(gmDrumName(82) == null);
    try testing.expectEqualStrings("Acoustic Grand Piano", gmProgramName(0));
    try testing.expectEqualStrings("Gunshot", gmProgramName(127));
    try testing.expectEqualStrings("Unknown", gmProgramName(200));
}

test "names: note name covers the full u8 range without overflow" {
    try testing.expectEqualStrings("C#-2", noteName(1).slice());
    try testing.expectEqualStrings("B-2", noteName(11).slice());
    try testing.expectEqualStrings("D#19", noteName(255).slice());
}

test "names: drum and program table sizes match the GM tables" {
    try testing.expectEqual(@as(usize, 47), gm_drums.len);
    try testing.expectEqual(@as(usize, 128), gm_programs.len);
}
