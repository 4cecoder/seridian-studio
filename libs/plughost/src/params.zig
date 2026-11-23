// Translated to Zig from soundcraft/crates/dsp/src/params.rs, soundcraft/crates/dsp/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Parameter descriptions: units, tapers, the value mapping of `ParamInfo`
//! (clamp, normalize, denormalize) and comptime-friendly const constructors for
//! static parameter tables. Tables are built at comptime or in `init`; nothing here
//! allocates. Format strings (`ParamInfo::format`) are not translated: they build
//! `String`s for the UI and belong with the UI layer.

const std = @import("std");
const testing = std.testing;

/// Display unit of a parameter.
pub const Unit = enum { none, db, hz, ms, percent, ratio, semitones, cents, seconds, toggle, choice };

/// How a control maps its 0..1 travel onto the parameter range.
pub const Taper = enum { linear, log };

/// Static description of one plugin parameter. `choices` labels `Unit.choice`
/// parameters; the value is the index.
pub const ParamInfo = struct {
    id: []const u8,
    name: []const u8,
    min: f32,
    max: f32,
    default: f32,
    unit: Unit,
    taper: Taper,
    choices: []const []const u8 = &.{},

    /// Clamps any value (including NaN and infinities) into the legal range.
    /// NaN becomes the default; toggles and choices round to whole numbers.
    pub fn clamp(self: ParamInfo, value: f32) f32 {
        const v0 = if (std.math.isNan(value)) self.default else value;
        const v = std.math.clamp(v0, self.min, self.max);
        return switch (self.unit) {
            .toggle, .choice => std.math.clamp(@round(v), self.min, self.max),
            else => v,
        };
    }

    /// Maps a value to 0..1 control travel, honoring the taper.
    pub fn toNormalized(self: ParamInfo, value: f32) f32 {
        const v = self.clamp(value);
        const span = self.max - self.min;
        if (span <= 0.0) return 0.0;
        if (self.taper == .log and self.min > 0.0) {
            return std.math.clamp(@log(v / self.min) / @log(self.max / self.min), 0.0, 1.0);
        }
        return std.math.clamp((v - self.min) / span, 0.0, 1.0);
    }

    /// Maps 0..1 control travel back to a value, honoring the taper.
    pub fn fromNormalized(self: ParamInfo, t_in: f32) f32 {
        const t = if (std.math.isNan(t_in)) 0.0 else std.math.clamp(t_in, 0.0, 1.0);
        const v = if (self.taper == .log and self.min > 0.0)
            self.min * std.math.pow(f32, self.max / self.min, t)
        else
            self.min + (self.max - self.min) * t;
        return self.clamp(v);
    }
};

/// A continuous parameter.
pub fn p(id: []const u8, name: []const u8, min: f32, max: f32, default: f32, unit: Unit, taper: Taper) ParamInfo {
    return .{ .id = id, .name = name, .min = min, .max = max, .default = default, .unit = unit, .taper = taper };
}

/// A linear-taper parameter.
pub fn lin(id: []const u8, name: []const u8, min: f32, max: f32, default: f32, unit: Unit) ParamInfo {
    return p(id, name, min, max, default, unit, .linear);
}

/// A log-taper parameter (frequencies, times, ratios).
pub fn log(id: []const u8, name: []const u8, min: f32, max: f32, default: f32, unit: Unit) ParamInfo {
    return p(id, name, min, max, default, unit, .log);
}

/// An on/off switch.
pub fn toggle(id: []const u8, name: []const u8, default_on: bool) ParamInfo {
    return .{
        .id = id,
        .name = name,
        .min = 0.0,
        .max = 1.0,
        .default = if (default_on) 1.0 else 0.0,
        .unit = .toggle,
        .taper = .linear,
    };
}

/// A list choice; the value is the index into `choices`.
pub fn choice(id: []const u8, name: []const u8, choices: []const []const u8, default: usize) ParamInfo {
    const max: f32 = if (choices.len == 0) 0.0 else @floatFromInt(choices.len - 1);
    return .{
        .id = id,
        .name = name,
        .min = 0.0,
        .max = max,
        .default = @as(f32, @floatFromInt(default)),
        .unit = .choice,
        .taper = .linear,
        .choices = choices,
    };
}

test "const constructors fill every field" {
    const cutoff = log("cutoff", "Cutoff", 20.0, 20000.0, 1000.0, .hz);
    try testing.expectEqualStrings("cutoff", cutoff.id);
    try testing.expectEqualStrings("Cutoff", cutoff.name);
    try testing.expectEqual(Taper.log, cutoff.taper);
    try testing.expectEqual(Unit.hz, cutoff.unit);
    try testing.expectEqual(@as(usize, 0), cutoff.choices.len);

    const gain = lin("gain", "Gain", -12.0, 12.0, 0.0, .db);
    try testing.expectEqual(Taper.linear, gain.taper);
    try testing.expectEqual(Unit.db, gain.unit);

    const on = toggle("bypass", "Bypass", true);
    try testing.expectEqual(@as(f32, 1.0), on.default);
    try testing.expectEqual(@as(f32, 0.0), on.min);
    try testing.expectEqual(@as(f32, 1.0), on.max);
    try testing.expectEqual(Unit.toggle, on.unit);
    try testing.expectEqual(@as(f32, 0.0), toggle("x", "X", false).default);

    const names = [_][]const u8{ "Sine", "Saw", "Square" };
    const wave = choice("wave", "Wave", &names, 1);
    try testing.expectEqual(@as(f32, 2.0), wave.max);
    try testing.expectEqual(@as(f32, 1.0), wave.default);
    try testing.expectEqual(Unit.choice, wave.unit);
    try testing.expectEqual(@as(usize, 3), wave.choices.len);
    try testing.expectEqual(@as(f32, 0.0), choice("e", "E", &.{}, 0).max);
}

test "clamp: NaN becomes the default, out-of-range values clamp" {
    const p_gain = lin("gain", "Gain", -12.0, 12.0, 3.0, .db);
    try testing.expectEqual(@as(f32, 3.0), p_gain.clamp(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 12.0), p_gain.clamp(100.0));
    try testing.expectEqual(@as(f32, -12.0), p_gain.clamp(-std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 12.0), p_gain.clamp(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0.5), p_gain.clamp(0.5));
}

test "clamp: toggles and choices round to whole numbers" {
    const on = toggle("bypass", "Bypass", false);
    try testing.expectEqual(@as(f32, 1.0), on.clamp(0.7));
    try testing.expectEqual(@as(f32, 0.0), on.clamp(0.4));
    try testing.expectEqual(@as(f32, 1.0), on.clamp(5.0));

    const names = [_][]const u8{ "A", "B", "C" };
    const c = choice("mode", "Mode", &names, 0);
    try testing.expectEqual(@as(f32, 2.0), c.clamp(1.6));
    try testing.expectEqual(@as(f32, 0.0), c.clamp(-3.0));
    try testing.expectEqual(@as(f32, 0.0), c.clamp(std.math.nan(f32)));
}

test "log taper: normalize and denormalize round trip" {
    const freq = log("cutoff", "Cutoff", 20.0, 20000.0, 1000.0, .hz);

    try testing.expectApproxEqAbs(@as(f32, 0.0), freq.toNormalized(20.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), freq.toNormalized(20000.0), 1e-6);

    // The geometric midpoint sqrt(20 * 20000) is the centre of the travel.
    try testing.expectApproxEqAbs(@as(f32, 0.5), freq.toNormalized(632.455532), 1e-4);
    try testing.expectApproxEqRel(@as(f32, 632.455532), freq.fromNormalized(0.5), 1e-4);

    try testing.expectApproxEqAbs(@as(f32, 20.0), freq.fromNormalized(0.0), 1e-3);
    try testing.expectApproxEqRel(@as(f32, 20000.0), freq.fromNormalized(1.0), 1e-5);

    var t: f32 = 0.0;
    while (t <= 1.0) : (t += 0.125) {
        const v = freq.fromNormalized(t);
        try testing.expectApproxEqAbs(t, freq.toNormalized(v), 1e-4);
    }
}

test "linear taper: normalize and denormalize round trip" {
    const gain = lin("gain", "Gain", -12.0, 12.0, 0.0, .db);
    try testing.expectApproxEqAbs(@as(f32, 0.0), gain.toNormalized(-12.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), gain.toNormalized(0.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6.0), gain.fromNormalized(0.75), 1e-5);
}

test "log taper falls back to linear when min is not positive" {
    const q = log("q", "Q", 0.0, 10.0, 1.0, .none);
    try testing.expectApproxEqAbs(@as(f32, 0.1), q.toNormalized(1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5.0), q.fromNormalized(0.5), 1e-6);
}

test "degenerate ranges and NaN travel" {
    const fixed = lin("fixed", "Fixed", 3.0, 3.0, 3.0, .none);
    try testing.expectEqual(@as(f32, 0.0), fixed.toNormalized(3.0));

    const freq = log("cutoff", "Cutoff", 20.0, 20000.0, 1000.0, .hz);
    try testing.expectEqual(@as(f32, 20.0), freq.fromNormalized(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 20000.0), freq.fromNormalized(7.0));
}
