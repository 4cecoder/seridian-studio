// Translated to Zig from pitchpure/crates/pitchpure_engine/src/host_params.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Host-facing parameter table shared by plug-in shells and the DAW.
//!
//! Hosts show (and automate) exactly the parameters a plug-in publishes, so
//! this table is what makes key, scale and the other controls visible. Every
//! shell maps its ABI calls onto it so formats can never disagree about ids,
//! ranges or labels.
//!
//! Ids are part of saved host sessions and automation: never renumber,
//! only append. `retune` stays id 0 because earlier builds shipped it alone.

const std = @import("std");
const params = @import("params.zig");
const FullParams = params.FullParams;

pub const retune: u32 = 0;
pub const key: u32 = 1;
pub const scale: u32 = 2;
pub const humanize: u32 = 3;
pub const transpose: u32 = 4;
pub const mix: u32 = 5;

/// Unit a host should display next to the value.
pub const Unit = enum {
    milliseconds,
    percent,
    semitones,
    /// Value is an index into `HostParam.values`.
    indexed,
};

/// A named scale preset: root-relative semitone mask.
pub const ScalePreset = struct {
    name: []const u8,
    mask: u16,
};

/// One automatable parameter, in plain (display) units.
pub const HostParam = struct {
    id: u32,
    name: []const u8,
    short: []const u8,
    unit: Unit,
    min: f32,
    max: f32,
    default: f32,
    /// Discrete step count (`max - min`) for stepped/indexed params, else 0.
    steps: u32,
    /// Value names for `Unit.indexed`; empty otherwise.
    values: []const []const u8,

    /// Clamp, and snap stepped params to whole steps.
    pub fn sanitize(self: *const HostParam, plain: f32) f32 {
        const v0 = if (std.math.isFinite(plain)) plain else self.default;
        const v = std.math.clamp(v0, self.min, self.max);
        return if (self.steps > 0) @round(v) else v;
    }

    /// Plain value to the `0..=1` range VST3 hosts automate.
    pub fn toNormalized(self: *const HostParam, plain: f32) f64 {
        const v = self.sanitize(plain);
        const lo: f64 = self.min;
        const hi: f64 = self.max;
        return (@as(f64, v) - lo) / (hi - lo);
    }

    /// `0..=1` back to a (snapped) plain value.
    pub fn fromNormalized(self: *const HostParam, norm: f64) f32 {
        const n = if (std.math.isFinite(norm)) std.math.clamp(norm, 0.0, 1.0) else 0.0;
        const lo: f64 = self.min;
        const span = @as(f64, self.max) - lo;
        return self.sanitize(@floatCast(lo + n * span));
    }

    /// Host display string, e.g. `"40 ms"`, `"G"`, `"+3 st"`, written into
    /// `buf` (Rust returned an owned `String`). Returns a slice of `buf`, or
    /// `error.NoSpaceLeft` when `buf` is too small. 32 bytes is always enough.
    pub fn display(self: *const HostParam, plain: f32, buf: []u8) error{NoSpaceLeft}![]const u8 {
        const v = self.sanitize(plain);
        return switch (self.unit) {
            .milliseconds => std.fmt.bufPrint(buf, "{d:.0} ms", .{v}),
            .percent => std.fmt.bufPrint(buf, "{d:.0} %", .{v}),
            .semitones => if (v > 0.0)
                std.fmt.bufPrint(buf, "+{d:.0} st", .{v})
            else
                std.fmt.bufPrint(buf, "{d:.0} st", .{v}),
            .indexed => blk: {
                // v is finite, clamped to >= min (0 for indexed params) and rounded.
                const i: usize = @intFromFloat(@max(v, 0.0));
                const name = if (i < self.values.len) self.values[i] else "?";
                if (name.len > buf.len) return error.NoSpaceLeft;
                @memcpy(buf[0..name.len], name);
                break :blk buf[0..name.len];
            },
        };
    }

    /// Parse a host-typed string (value name or number) to a plain value.
    pub fn parse(self: *const HostParam, text: []const u8) ?f32 {
        const t = std.mem.trim(u8, text, &std.ascii.whitespace);
        for (self.values, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, t)) return @floatFromInt(i);
        }
        var end: usize = 0;
        while (end < t.len) : (end += 1) {
            const c = t[end];
            if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+')) break;
        }
        const v = std.fmt.parseFloat(f32, t[0..end]) catch return null;
        return self.sanitize(v);
    }
};

pub const key_names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// Scale presets as root-relative semitone masks, in host index order.
pub const scales = [9]ScalePreset{
    .{ .name = "Chromatic", .mask = 0x0FFF },
    .{ .name = "Major", .mask = 0x0AB5 },
    .{ .name = "Minor", .mask = 0x05AD },
    .{ .name = "Harmonic Minor", .mask = 0x09AD },
    .{ .name = "Major Pentatonic", .mask = 0x0295 },
    .{ .name = "Minor Pentatonic", .mask = 0x04A9 },
    .{ .name = "Blues", .mask = 0x04E9 },
    .{ .name = "Dorian", .mask = 0x06AD },
    .{ .name = "Mixolydian", .mask = 0x06B5 },
};

const scale_names: [9][]const u8 = blk: {
    var names: [9][]const u8 = undefined;
    for (scales, 0..) |s, i| names[i] = s.name;
    break :blk names;
};

/// Root octave used when a key index becomes `root_midi` (C4 = 60).
const root_base_midi: u8 = 60;

pub const all = [6]HostParam{
    .{ .id = retune, .name = "Retune Speed", .short = "Retune", .unit = .milliseconds, .min = 0.0, .max = 1000.0, .default = 40.0, .steps = 0, .values = &.{} },
    .{ .id = key, .name = "Key", .short = "Key", .unit = .indexed, .min = 0.0, .max = 11.0, .default = 0.0, .steps = 11, .values = &key_names },
    .{ .id = scale, .name = "Scale", .short = "Scale", .unit = .indexed, .min = 0.0, .max = 8.0, .default = 0.0, .steps = 8, .values = &scale_names },
    .{ .id = humanize, .name = "Humanize", .short = "Human", .unit = .percent, .min = 0.0, .max = 100.0, .default = 0.0, .steps = 0, .values = &.{} },
    .{ .id = transpose, .name = "Transpose", .short = "Transp", .unit = .semitones, .min = -12.0, .max = 12.0, .default = 0.0, .steps = 24, .values = &.{} },
    .{ .id = mix, .name = "Mix", .short = "Mix", .unit = .percent, .min = 0.0, .max = 100.0, .default = 100.0, .steps = 0, .values = &.{} },
};

/// Look up a parameter by id.
pub fn find(id: u32) ?*const HostParam {
    for (&all) |*p| {
        if (p.id == id) return p;
    }
    return null;
}

/// Index of the named scale matching `mask`, if any.
pub fn scaleIndex(mask: u16) ?usize {
    for (scales, 0..) |s, i| {
        if (s.mask == mask & 0x0FFF) return i;
    }
    return null;
}

/// Read parameter `id` from engine params as a plain value.
pub fn get(p: *const FullParams, id: u32) ?f32 {
    return switch (id) {
        retune => p.retune_ms,
        key => @floatFromInt(p.root_midi % 12),
        scale => @floatFromInt(scaleIndex(p.scale_mask) orelse 0),
        humanize => p.humanize * 100.0,
        transpose => p.transpose_cents / 100.0,
        mix => p.mix * 100.0,
        else => null,
    };
}

/// Write plain value `v` for parameter `id` into engine params.
/// Returns `false` for an unknown id.
pub fn set(p: *FullParams, id: u32, v_in: f32) bool {
    const info = find(id) orelse return false;
    const v = info.sanitize(v_in);
    switch (id) {
        retune => p.retune_ms = v,
        // sanitize clamped to 0..=11 and rounded.
        key => p.root_midi = root_base_midi + @as(u8, @intFromFloat(v)),
        // sanitize clamped to 0..=8 and rounded.
        scale => p.scale_mask = scales[@as(usize, @intFromFloat(v))].mask,
        humanize => p.humanize = v / 100.0,
        transpose => p.transpose_cents = v * 100.0,
        mix => p.mix = v / 100.0,
        else => return false,
    }
    return true;
}

const testing = std.testing;

test "ids_are_dense_and_retune_is_zero" {
    for (all, 0..) |p, i| {
        try testing.expectEqual(i, @as(usize, p.id));
    }
    const d: FullParams = .{};
    try testing.expectEqual(d.retune_ms, find(retune).?.default);
}

test "defaults_match_engine_defaults" {
    const d: FullParams = .{};
    for (all) |p| {
        try testing.expectEqual(@as(?f32, p.default), get(&d, p.id));
    }
}

test "set_get_round_trip" {
    var fp: FullParams = .{};
    try testing.expect(set(&fp, key, 7.0));
    try testing.expect(set(&fp, scale, 2.0));
    try testing.expect(set(&fp, transpose, -3.4));
    try testing.expectEqual(@as(u8, 67), fp.root_midi);
    try testing.expectEqual(@as(u16, 0x05AD), fp.scale_mask);
    try testing.expectEqual(@as(f32, -300.0), fp.transpose_cents);
    try testing.expectEqual(@as(?f32, 7.0), get(&fp, key));
    try testing.expectEqual(@as(?f32, 2.0), get(&fp, scale));
    try testing.expect(!set(&fp, 99, 1.0));
}

test "normalized_round_trip_and_display" {
    var buf: [32]u8 = undefined;
    const k = find(key).?;
    try testing.expectEqual(@as(f32, 9.0), k.fromNormalized(k.toNormalized(9.0)));
    try testing.expectEqualStrings("A", try k.display(9.0, &buf));
    const tr = find(transpose).?;
    try testing.expectEqual(@as(f64, 0.5), tr.toNormalized(0.0));
    try testing.expectEqualStrings("+3 st", try tr.display(3.0, &buf));
    try testing.expectEqualStrings("40 ms", try find(retune).?.display(40.0, &buf));
    try testing.expectEqual(@as(?f32, 2.0), find(scale).?.parse("minor"));
    try testing.expectEqual(@as(?f32, 55.0), find(mix).?.parse("55 %"));
}
