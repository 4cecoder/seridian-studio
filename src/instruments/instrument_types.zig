//! The instrument type table: one list of names shared by the engine, the app's control socket and
//! the `seridian` CLI. It imports nothing but `std`, so the CLI can use it without the audio code.

const std = @import("std");

/// Available instrument types
pub const InstrumentType = enum(u8) {
    keys = 0,
    wavetable_synth = 1,
    supersaw_synth = 2,
    fm_synth = 3,
    drum_kit = 4,
    strings = 5,
    brass = 6,
    woodwind = 7,
    harp = 8,
    drum_kit_808 = 9,
    drum_kit_909 = 10,
    strings_warm = 11,
    strings_bright = 12,
    brass_trumpet = 13,
    brass_horn = 14,
    model_strings = 15,
    model_pluck = 16,
    model_brass = 17,
    model_clarinet = 18,
    model_piano = 19,
    model_percussion = 20,

    pub fn name(self: InstrumentType) []const u8 {
        return switch (self) {
            .keys => "Keys",
            .wavetable_synth => "WavetableSynth",
            .supersaw_synth => "SuperSaw",
            .fm_synth => "FMSynth",
            .drum_kit => "DrumKit",
            .strings => "Strings",
            .brass => "Brass",
            .woodwind => "Woodwind",
            .harp => "Harp",
            .drum_kit_808 => "DrumKit808",
            .drum_kit_909 => "DrumKit909",
            .strings_warm => "StringsWarm",
            .strings_bright => "StringsBright",
            .brass_trumpet => "BrassTrumpet",
            .brass_horn => "BrassHorn",
            .model_strings => "ModelStrings",
            .model_pluck => "ModelPluck",
            .model_brass => "ModelBrass",
            .model_clarinet => "ModelClarinet",
            .model_piano => "ModelPiano",
            .model_percussion => "ModelPercussion",
        };
    }
};

/// Number of instrument types.
pub const count: usize = std.meta.fieldNames(InstrumentType).len;

/// The type a name selects, or null. Case is ignored and spaces are skipped on both sides, so the
/// displayed name ("Model Piano") selects the same type as "ModelPiano".
pub fn fromName(text: []const u8) ?InstrumentType {
    for (0..count) |i| {
        const candidate: InstrumentType = @fromBackingInt(@intCast(i));
        if (eqlIgnoringSpaces(text, candidate.name())) return candidate;
    }
    return null;
}

fn eqlIgnoringSpaces(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == ' ') i += 1;
        while (j < b.len and b[j] == ' ') j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len and a.len > 0;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// Writes every name, separated by `separator`, into `buf`. Returns the text, or null when it does not fit.
pub fn joinNames(buf: []u8, separator: []const u8) ?[]const u8 {
    var used: usize = 0;
    for (0..count) |i| {
        const piece_name = (@as(InstrumentType, @fromBackingInt(@intCast(i)))).name();
        const sep = if (i == 0) "" else separator;
        if (used + sep.len + piece_name.len > buf.len) return null;
        @memcpy(buf[used..][0..sep.len], sep);
        used += sep.len;
        @memcpy(buf[used..][0..piece_name.len], piece_name);
        used += piece_name.len;
    }
    return buf[0..used];
}

test "instrument_types: names are unique, have no spaces and round-trip" {
    const testing = std.testing;
    var seen: [count][]const u8 = undefined;
    for (0..count) |i| {
        const t: InstrumentType = @fromBackingInt(@intCast(i));
        const n = t.name();
        try testing.expect(std.mem.indexOfScalar(u8, n, ' ') == null);
        for (seen[0..i]) |other| try testing.expect(!std.mem.eql(u8, other, n));
        seen[i] = n;
        try testing.expectEqual(@as(?InstrumentType, t), fromName(n));
    }
}

test "instrument_types: a displayed name matches ignoring case and spaces" {
    const testing = std.testing;
    try testing.expectEqual(@as(?InstrumentType, .model_piano), fromName("Model Piano"));
    try testing.expectEqual(@as(?InstrumentType, .model_piano), fromName("modelpiano"));
    try testing.expectEqual(@as(?InstrumentType, .fm_synth), fromName("FM Synth"));
    try testing.expectEqual(@as(?InstrumentType, .fm_synth), fromName("fmsynth"));
    try testing.expectEqual(@as(?InstrumentType, .supersaw_synth), fromName("SUPERSAW"));
    try testing.expectEqual(@as(?InstrumentType, null), fromName(""));
    try testing.expectEqual(@as(?InstrumentType, null), fromName("   "));
    try testing.expectEqual(@as(?InstrumentType, null), fromName("Nope"));
    try testing.expectEqual(@as(?InstrumentType, null), fromName("Keysx"));
}

test "instrument_types: joinNames lists every name" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    const text = joinNames(&buf, ", ") orelse return error.TestUnexpectedResult;
    var it = std.mem.splitSequence(u8, text, ", ");
    var n: usize = 0;
    while (it.next()) |name| : (n += 1) {
        try testing.expectEqualStrings((@as(InstrumentType, @fromBackingInt(@intCast(n)))).name(), name);
    }
    try testing.expectEqual(count, n);
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), joinNames(&tiny, ", "));
}
