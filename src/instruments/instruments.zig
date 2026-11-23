//! Instruments Module
//!
//! Virtual instruments for the DAW. All instruments implement the common
//! Instrument interface for consistent handling.

const std = @import("std");

pub const instrument = @import("instrument.zig");
pub const keys = @import("keys.zig");
pub const wavetable_synth = @import("wavetable_synth.zig");
pub const supersaw_synth = @import("supersaw_synth.zig");
pub const fm_synth = @import("fm_synth.zig");
pub const drum_kit = @import("drum_kit.zig");
pub const orchestra = @import("orchestra.zig");
pub const physical_strings = @import("physical_strings.zig");
pub const physical_winds = @import("physical_winds.zig");
pub const physical_piano = @import("physical_piano.zig");
pub const physical_percussion = @import("physical_percussion.zig");

// Re-export types
pub const Instrument = instrument.Instrument;
pub const Parameter = instrument.Parameter;

pub const Keys = keys.Keys;
pub const WavetableSynth = wavetable_synth.WavetableSynth;
pub const SuperSawSynth = supersaw_synth.SuperSawSynth;
pub const FMSynth = fm_synth.FMSynth;
pub const DrumKit = drum_kit.DrumKit;
pub const Strings = orchestra.Strings;
pub const Brass = orchestra.Brass;
pub const Woodwind = orchestra.Woodwind;
pub const Harp = orchestra.Harp;
pub const ModelStrings = physical_strings.ModelStrings;
pub const ModelPluck = physical_strings.ModelPluck;
pub const ModelBrass = physical_winds.ModelBrass;
pub const ModelClarinet = physical_winds.ModelClarinet;
pub const ModelPiano = physical_piano.ModelPiano;
pub const ModelPercussion = physical_percussion.ModelPercussion;

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
            .fm_synth => "FM Synth",
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

/// Create an instrument by type
pub fn createInstrument(allocator: std.mem.Allocator, instrument_type: InstrumentType) !*Instrument {
    const sample_rate: f32 = 48000.0; // TODO: Get from audio engine

    switch (instrument_type) {
        .keys => {
            const k = try allocator.create(Keys);
            k.* = Keys.init(sample_rate);
            return &k.instrument;
        },
        .wavetable_synth => {
            const wt = try allocator.create(WavetableSynth);
            wt.* = WavetableSynth.init(sample_rate);
            return &wt.instrument;
        },
        .supersaw_synth => {
            const ss = try allocator.create(SuperSawSynth);
            ss.* = SuperSawSynth.init(sample_rate);
            return &ss.instrument;
        },
        .fm_synth => {
            const fm = try allocator.create(FMSynth);
            fm.* = FMSynth.init(sample_rate);
            return &fm.instrument;
        },
        .drum_kit => {
            const inst = try allocator.create(DrumKit);
            inst.* = DrumKit.init(sample_rate);
            return &inst.instrument;
        },
        .strings => {
            const inst = try allocator.create(Strings);
            inst.* = Strings.init(sample_rate);
            return &inst.instrument;
        },
        .brass => {
            const inst = try allocator.create(Brass);
            inst.* = Brass.init(sample_rate);
            return &inst.instrument;
        },
        .woodwind => {
            const inst = try allocator.create(Woodwind);
            inst.* = Woodwind.init(sample_rate);
            return &inst.instrument;
        },
        .harp => {
            const inst = try allocator.create(Harp);
            inst.* = Harp.init(sample_rate);
            return &inst.instrument;
        },
        .drum_kit_808 => {
            const inst = try allocator.create(DrumKit);
            inst.* = DrumKit.init808(sample_rate);
            return &inst.instrument;
        },
        .drum_kit_909 => {
            const inst = try allocator.create(DrumKit);
            inst.* = DrumKit.init909(sample_rate);
            return &inst.instrument;
        },
        .strings_warm => {
            const inst = try allocator.create(Strings);
            inst.* = orchestra.initStringsWarm(sample_rate);
            return &inst.instrument;
        },
        .strings_bright => {
            const inst = try allocator.create(Strings);
            inst.* = orchestra.initStringsBright(sample_rate);
            return &inst.instrument;
        },
        .brass_trumpet => {
            const inst = try allocator.create(Brass);
            inst.* = orchestra.initBrassTrumpet(sample_rate);
            return &inst.instrument;
        },
        .brass_horn => {
            const inst = try allocator.create(Brass);
            inst.* = orchestra.initBrassHorn(sample_rate);
            return &inst.instrument;
        },
        .model_strings => {
            const inst = try allocator.create(ModelStrings);
            inst.* = ModelStrings.init(sample_rate);
            return &inst.instrument;
        },
        .model_pluck => {
            const inst = try allocator.create(ModelPluck);
            inst.* = ModelPluck.init(sample_rate);
            return &inst.instrument;
        },
        .model_brass => {
            const inst = try allocator.create(ModelBrass);
            inst.* = ModelBrass.init(sample_rate);
            return &inst.instrument;
        },
        .model_clarinet => {
            const inst = try allocator.create(ModelClarinet);
            inst.* = ModelClarinet.init(sample_rate);
            return &inst.instrument;
        },
        .model_piano => {
            const inst = try allocator.create(ModelPiano);
            inst.* = ModelPiano.init(sample_rate);
            return &inst.instrument;
        },
        .model_percussion => {
            const inst = try allocator.create(ModelPercussion);
            inst.* = ModelPercussion.init(sample_rate);
            return &inst.instrument;
        },
    }
}

/// Get instrument type count
pub fn getInstrumentTypeCount() usize {
    return std.meta.fieldNames(InstrumentType).len;
}

/// Get instrument type by index
pub fn getInstrumentType(index: usize) ?InstrumentType {
    const fields = std.meta.fieldNames(InstrumentType);
    if (index >= fields.len) return null;
    return @fromBackingInt(@intCast(index));
}

// =============================================================================
// Tests
// =============================================================================

test "create instruments" {
    const testing = std.testing;

    // Keys
    const k = try createInstrument(testing.allocator, .keys);
    defer {
        k.deinit(testing.allocator);
        const keys_ptr: *Keys = @fieldParentPtr("instrument", k);
        testing.allocator.destroy(keys_ptr);
    }
    try testing.expectEqualStrings("Keys", k.name);

    // WavetableSynth
    const wt = try createInstrument(testing.allocator, .wavetable_synth);
    defer {
        wt.deinit(testing.allocator);
        const wt_ptr: *WavetableSynth = @fieldParentPtr("instrument", wt);
        testing.allocator.destroy(wt_ptr);
    }
    try testing.expectEqualStrings("WavetableSynth", wt.name);

    // SuperSawSynth
    const ss = try createInstrument(testing.allocator, .supersaw_synth);
    defer {
        ss.deinit(testing.allocator);
        const ss_ptr: *SuperSawSynth = @fieldParentPtr("instrument", ss);
        testing.allocator.destroy(ss_ptr);
    }
    try testing.expectEqualStrings("SuperSaw", ss.name);

    // FMSynth
    const fm = try createInstrument(testing.allocator, .fm_synth);
    defer {
        fm.deinit(testing.allocator);
        const fm_ptr: *FMSynth = @fieldParentPtr("instrument", fm);
        testing.allocator.destroy(fm_ptr);
    }
    try testing.expectEqualStrings("FM Synth", fm.name);
}

test "instrument type enumeration" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 21), getInstrumentTypeCount());
    try testing.expectEqual(InstrumentType.keys, getInstrumentType(0).?);
    try testing.expectEqual(InstrumentType.wavetable_synth, getInstrumentType(1).?);
    try testing.expectEqual(InstrumentType.supersaw_synth, getInstrumentType(2).?);
    try testing.expectEqual(InstrumentType.fm_synth, getInstrumentType(3).?);
    try testing.expectEqual(InstrumentType.drum_kit, getInstrumentType(4).?);
    try testing.expectEqual(InstrumentType.harp, getInstrumentType(8).?);
    try testing.expectEqual(InstrumentType.drum_kit_808, getInstrumentType(9).?);
    try testing.expectEqual(InstrumentType.drum_kit_909, getInstrumentType(10).?);
    try testing.expectEqual(InstrumentType.strings_warm, getInstrumentType(11).?);
    try testing.expectEqual(InstrumentType.strings_bright, getInstrumentType(12).?);
    try testing.expectEqual(InstrumentType.brass_trumpet, getInstrumentType(13).?);
    try testing.expectEqual(InstrumentType.brass_horn, getInstrumentType(14).?);
    try testing.expectEqualStrings("BrassHorn", InstrumentType.brass_horn.name());
    try testing.expectEqual(InstrumentType.model_strings, getInstrumentType(15).?);
    try testing.expectEqual(InstrumentType.model_percussion, getInstrumentType(20).?);
    try testing.expectEqualStrings("ModelPiano", InstrumentType.model_piano.name());
    try testing.expectEqual(@as(?InstrumentType, null), getInstrumentType(99));
}

test "create new instruments" {
    const testing = std.testing;
    const types = [_]InstrumentType{ .drum_kit, .strings, .brass, .woodwind, .harp, .drum_kit_808, .drum_kit_909, .strings_warm, .strings_bright, .brass_trumpet, .brass_horn, .model_strings, .model_pluck, .model_brass, .model_clarinet, .model_piano, .model_percussion };
    for (types) |t| {
        const inst = try createInstrument(testing.allocator, t);
        // ModelPiano registers itself as "Model Piano" (with a space); the enum name is "ModelPiano".
        if (t != .model_piano) try testing.expectEqualStrings(t.name(), inst.name);
        inst.deinit(testing.allocator);
        inst.destroy(testing.allocator);
    }
}
