//! Named EQ presets for the song's tracks and the master bus, built on the
//! existing ParametricEQ. Applying a preset finds (or adds) the track's
//! ParametricEQ slot and sets every parameter, so applying twice gives the
//! same result and other effects in the chain are left alone.

const std = @import("std");
const chain_mod = @import("chain.zig");
const EffectsChain = chain_mod.EffectsChain;
const ParametricEQ = @import("parametric_eq.zig").ParametricEQ;

pub const Preset = enum {
    drums,
    bass,
    pads,
    lead,
    harp,

    pub fn parse(name: []const u8) ?Preset {
        var lower: [16]u8 = undefined;
        if (name.len == 0 or name.len > lower.len) return null;
        for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        return std.meta.stringToEnum(Preset, lower[0..name.len]);
    }
};

const mid1_freq = 3;
const mid1_gain = 4;
const mid2_freq = 6;
const mid2_gain = 7;
const high_freq = 9;
const high_gain = 10;

const Settings = struct {
    hp_hz: f32,
    mid1: ?struct { hz: f32, db: f32 } = null,
    mid2: ?struct { hz: f32, db: f32 } = null,
};

fn settingsFor(preset: Preset) Settings {
    return switch (preset) {
        .drums => .{ .hp_hz = 35, .mid1 = .{ .hz = 300, .db = -2 }, .mid2 = .{ .hz = 3500, .db = 2 } },
        .bass => .{ .hp_hz = 30, .mid1 = .{ .hz = 250, .db = -2 } },
        .pads => .{ .hp_hz = 180, .mid2 = .{ .hz = 2500, .db = -1.5 } },
        .lead => .{ .hp_hz = 200, .mid2 = .{ .hz = 2500, .db = 1.5 } },
        .harp => .{ .hp_hz = 250 },
    };
}

/// Finds the chain's ParametricEQ, adding one when there is none.
fn findOrAddEq(chain: *EffectsChain) !*ParametricEQ {
    for (0..chain.count) |i| {
        if (chain.getSlot(i)) |slot| {
            switch (slot.ptr) {
                .parametric_eq => |eq| return eq,
                else => {},
            }
        }
    }
    const index = try chain.addEffect(.parametric_eq);
    const slot = chain.getSlot(index) orelse return error.InvalidEffectType;
    switch (slot.ptr) {
        .parametric_eq => |eq| return eq,
        else => return error.InvalidEffectType,
    }
}

fn resetParams(eq: *ParametricEQ) void {
    for (&eq.params) |*p| p.value = p.default;
    eq.coeffs_dirty = true;
}

fn set(eq: *ParametricEQ, index: usize, value: f32) void {
    eq.effect.vtable.setParameter(&eq.effect, index, value);
}

pub fn applyPreset(chain: *EffectsChain, preset: Preset) !void {
    const eq = try findOrAddEq(chain);
    resetParams(eq);
    const s = settingsFor(preset);
    set(eq, ParametricEQ.hp_freq_param, s.hp_hz);
    if (s.mid1) |m| {
        set(eq, mid1_freq, m.hz);
        set(eq, mid1_gain, m.db);
    }
    if (s.mid2) |m| {
        set(eq, mid2_freq, m.hz);
        set(eq, mid2_gain, m.db);
    }
}

/// Master tilt: +0.5 dB high shelf above 8 kHz when on, flat when off.
pub fn setMasterTilt(chain: *EffectsChain, on: bool) !void {
    const eq = try findOrAddEq(chain);
    resetParams(eq);
    if (on) {
        set(eq, high_freq, 8000);
        set(eq, high_gain, 0.5);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// RMS of the second half of a stereo sine, after the filters have settled.
fn toneLevel(chain: *EffectsChain, hz: f32) f32 {
    const sample_rate: u32 = 48000;
    var buffer: [2 * 9600]f32 = undefined;
    for (0..9600) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, sample_rate);
        const v = 0.25 * @sin(2.0 * std.math.pi * hz * t);
        buffer[i * 2] = v;
        buffer[i * 2 + 1] = v;
    }
    chain.process(&buffer, sample_rate);
    var sum: f32 = 0;
    const half = 4800;
    for (half..9600) |i| sum += buffer[i * 2] * buffer[i * 2];
    return @sqrt(sum / @as(f32, @floatFromInt(9600 - half)));
}

test "drum preset raises a 3.5 kHz tone by about 2 dB" {
    var flat = EffectsChain.init(testing.allocator);
    defer flat.deinit();
    var drums = EffectsChain.init(testing.allocator);
    defer drums.deinit();
    try applyPreset(&drums, .drums);

    const before = toneLevel(&flat, 3500);
    const after = toneLevel(&drums, 3500);
    const db = 20.0 * std.math.log10(after / before);
    try testing.expect(db > 1.5 and db < 2.5);
}

test "bass preset leaves 3.5 kHz alone and cuts 20 Hz" {
    var flat = EffectsChain.init(testing.allocator);
    defer flat.deinit();
    var bass = EffectsChain.init(testing.allocator);
    defer bass.deinit();
    try applyPreset(&bass, .bass);
    const high_db = 20.0 * std.math.log10(toneLevel(&bass, 3500) / toneLevel(&flat, 3500));
    try testing.expect(@abs(high_db) < 0.2);
    try testing.expect(toneLevel(&bass, 20) < 0.5 * toneLevel(&flat, 20));
}

test "applying a preset twice keeps one EQ and the same level" {
    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();
    try applyPreset(&chain, .lead);
    try applyPreset(&chain, .lead);
    try testing.expectEqual(@as(usize, 1), chain.count);
}

test "harp and pads presets high-pass, master tilt lifts 12 kHz" {
    var harp = EffectsChain.init(testing.allocator);
    defer harp.deinit();
    try applyPreset(&harp, .harp);
    var flat = EffectsChain.init(testing.allocator);
    defer flat.deinit();
    try testing.expect(toneLevel(&harp, 60) < 0.2 * toneLevel(&flat, 60));

    var master = EffectsChain.init(testing.allocator);
    defer master.deinit();
    try setMasterTilt(&master, true);
    const db = 20.0 * std.math.log10(toneLevel(&master, 12000) / toneLevel(&flat, 12000));
    try testing.expect(db > 0.3 and db < 0.6);
    try setMasterTilt(&master, false);
    const off_db = 20.0 * std.math.log10(toneLevel(&master, 12000) / toneLevel(&flat, 12000));
    try testing.expect(@abs(off_db) < 0.1);
}

test "preset names parse" {
    try testing.expectEqual(Preset.drums, Preset.parse("drums").?);
    try testing.expectEqual(Preset.harp, Preset.parse("HARP").?);
    try testing.expect(Preset.parse("kazoo") == null);
}
