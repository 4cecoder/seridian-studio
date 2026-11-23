// Translated to Zig from soundcraft/crates/model/src/automation.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Automation modes, the global manual-override flag, and the automatable parameter ids.
//!
//! Test grid: the Rust tests place points on a sample axis. Here positions are beats (f64),
//! and the tests use 100 Rust samples = 1 beat (see `beats` in lane.zig for the same mapping).

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Tests (ported first; the implementation below was written to satisfy them)
// ---------------------------------------------------------------------------

test "pan_label_max_does_not_overflow" {
    var buf: [48]u8 = undefined;
    // Rust: AutoParam::Pan(255).label() == "pan 256". The label is 1-based, computed in u16.
    try testing.expectEqualStrings("pan 256", try (AutoParam{ .pan = 255 }).label(&buf));
    try testing.expectEqualStrings("pan", try (AutoParam{ .pan = 0 }).label(&buf));
    try testing.expectEqualStrings("pan 2", try (AutoParam{ .pan = 1 }).label(&buf));
}

test "param_ids" {
    // Seridian grammar: "send:B" is send level of slot B; "plug:a:7" is plugin param index 7 of slot A.
    try testing.expect(AutoParam.parse("send:B").?.eql(.{ .send_level = 1 }));
    // Rust form kept as an alias: "send_b_level" == SendLevel(1).
    try testing.expect(AutoParam.parse("send_b_level").?.eql(.{ .send_level = 1 }));
    // Rust: parse("plugin:a:threshold") == Plugin { slot: 0, param: "threshold" }. Plugin params
    // are identified by u32 index at runtime, so the name in that test becomes index 7.
    try testing.expect(AutoParam.parse("plugin:a:7").?.eql(.{ .plugin = .{ .slot = 0, .param = 7 } }));
    try testing.expect(AutoParam.parse("plug:a:7").?.eql(.{ .plugin = .{ .slot = 0, .param = 7 } }));
    try testing.expect(AutoParam.parse("nope") == null);
    try testing.expectEqual(AutomationMode.touch_latch, AutomationMode.fromId("touch/latch").?);
}

test "parse: volume, pan indices, mute and send forms" {
    try testing.expect(AutoParam.parse("vol").?.eql(.volume));
    try testing.expect(AutoParam.parse("volume").?.eql(.volume));
    try testing.expect(AutoParam.parse("pan").?.eql(.{ .pan = 0 }));
    // Seridian: pan indices are 0-based in ids ("pan1" is the right-hand panner). Rust's "pan2" was 1-based.
    try testing.expect(AutoParam.parse("pan0").?.eql(.{ .pan = 0 }));
    try testing.expect(AutoParam.parse("pan1").?.eql(.{ .pan = 1 }));
    try testing.expect(AutoParam.parse("mute").?.eql(.mute));
    try testing.expect(AutoParam.parse("send:C:pan").?.eql(.{ .send_pan = 2 }));
    try testing.expect(AutoParam.parse("send:D:mute").?.eql(.{ .send_mute = 3 }));
    try testing.expect(AutoParam.parse("  VOL ").?.eql(.volume));
    try testing.expect(AutoParam.parse("plug:B:12").?.eql(.{ .plugin = .{ .slot = 1, .param = 12 } }));
    try testing.expect(AutoParam.parse("plug:B:x") == null);
}

test "label: send, plugin and range" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("send B level", try (AutoParam{ .send_level = 1 }).label(&buf));
    try testing.expectEqualStrings("insert A param 7", try (AutoParam{ .plugin = .{ .slot = 0, .param = 7 } }).label(&buf));
    const r = (AutoParam{ .volume = {} }).range();
    try testing.expectEqual(@as(f32, -144.0), r.min);
    try testing.expectEqual(@as(f32, 12.0), r.max);
    try testing.expectEqual(@as(f32, 0.0), r.default);
    const m = (AutoParam{ .mute = {} }).range();
    try testing.expectEqual(@as(f32, 1.0), m.max);
}

test "from_id accepts label, tag and Rust Debug forms, case-insensitively" {
    try testing.expectEqual(AutomationMode.touch_latch, AutomationMode.fromId("touch_latch").?);
    try testing.expectEqual(AutomationMode.touch_latch, AutomationMode.fromId("TouchLatch").?);
    try testing.expectEqual(AutomationMode.touch_latch, AutomationMode.fromId("TOUCH/LATCH").?);
    try testing.expectEqual(AutomationMode.trim, AutomationMode.fromId("Trim").?);
    try testing.expectEqual(AutomationMode.read, AutomationMode.default);
    try testing.expect(AutomationMode.fromId("bogus") == null);
    try testing.expect(!AutomationMode.off.reads());
    try testing.expect(AutomationMode.trim.reads());
    try testing.expectEqual(@as(usize, 7), AutomationMode.all.len);
}

test "override: a read-mode lane is suppressed while the override is active" {
    const on: Override = .{ .active = true };
    const off: Override = .{};
    try testing.expectEqual(AutomationMode.off, effectiveMode(.read, on));
    try testing.expectEqual(AutomationMode.read, effectiveMode(.read, off));
    // Override only touches Read; the write-side modes are unchanged.
    try testing.expectEqual(AutomationMode.touch, effectiveMode(.touch, on));
    try testing.expectEqual(AutomationMode.write, effectiveMode(.write, on));
    var o: Override = .{};
    o.engage();
    try testing.expect(o.active);
    o.reEnable();
    try testing.expect(!o.active);
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Automation modes (per track). Off, Read, Touch, Latch, Write and Trim come from SoundCraft;
/// `touch_latch` is SoundCraft's TouchLatch, kept as its own mode.
pub const AutomationMode = enum {
    off,
    read,
    touch,
    latch,
    touch_latch,
    write,
    trim,

    pub const all = [_]AutomationMode{ .off, .read, .touch, .latch, .touch_latch, .write, .trim };
    pub const default: AutomationMode = .read;

    /// Display label, as in SoundCraft.
    pub fn label(self: AutomationMode) []const u8 {
        return switch (self) {
            .off => "off",
            .read => "read",
            .touch => "touch",
            .latch => "latch",
            .touch_latch => "touch/latch",
            .write => "write",
            .trim => "trim",
        };
    }

    /// Parses a UI or MCP id. Accepts the label ("touch/latch"), the tag name ("touch_latch")
    /// and the Rust Debug name ("TouchLatch"), case-insensitively. '/' and '_' are ignored.
    pub fn fromId(s: []const u8) ?AutomationMode {
        for (all) |m| {
            if (idEq(s, m.label()) or idEq(s, @tagName(m))) return m;
        }
        return null;
    }

    /// True for every mode that reads its lane (everything except Off).
    pub fn reads(self: AutomationMode) bool {
        return self != .off;
    }
};

/// Seridian global manual-override flag (live-performance.md §C.6): moving a control in Read
/// mode overrides its lane until the user re-enables automation with one global action.
pub const Override = struct {
    active: bool = false,

    /// A control was moved in Read mode.
    pub fn engage(self: *Override) void {
        self.active = true;
    }

    /// The global "Re-enable automation" action.
    pub fn reEnable(self: *Override) void {
        self.active = false;
    }
};

/// The mode that actually applies: while the override is active a Read lane is suppressed
/// (treated as Off). The other modes are unchanged because the override only targets Read.
pub fn effectiveMode(mode: AutomationMode, override: Override) AutomationMode {
    if (override.active and mode == .read) return .off;
    return mode;
}

/// Which parameter an automation lane controls. Plugin parameters are identified by a u32
/// index; names are for UI and MCP only and are resolved to an index outside the audio thread.
pub const AutoParam = union(enum) {
    /// Fader level, dB.
    volume,
    /// Pan, -1..1. Index: which panner of a stereo track (0 left, 1 right).
    pan: u8,
    /// Mute (0/1).
    mute,
    /// Send level, dB.
    send_level: u8,
    send_pan: u8,
    send_mute: u8,
    /// Insert slot and parameter index.
    plugin: Plugin,

    pub const Plugin = struct {
        slot: u8,
        param: u32,
    };

    pub const Range = struct {
        min: f32,
        max: f32,
        default: f32,
    };

    pub fn eql(a: AutoParam, b: AutoParam) bool {
        return std.meta.eql(a, b);
    }

    /// UI label. Writes into `buf` (48 bytes is enough for every variant).
    pub fn label(self: AutoParam, buf: []u8) ![]const u8 {
        switch (self) {
            .volume => return "volume",
            .pan => |i| {
                if (i == 0) return "pan";
                // Labels are 1-based; widen before adding so 255 becomes 256 without overflow.
                return std.fmt.bufPrint(buf, "pan {d}", .{@as(u16, i) + 1});
            },
            .mute => return "mute",
            .send_level => |i| return std.fmt.bufPrint(buf, "send {c} level", .{slotLetter(i)}),
            .send_pan => |i| return std.fmt.bufPrint(buf, "send {c} pan", .{slotLetter(i)}),
            .send_mute => |i| return std.fmt.bufPrint(buf, "send {c} mute", .{slotLetter(i)}),
            .plugin => |p| return std.fmt.bufPrint(buf, "insert {c} param {d}", .{ slotLetter(p.slot), p.param }),
        }
    }

    /// Parses an id. Seridian grammar:
    ///   vol | volume, mute, pan | pan0 (0-based panner index, panN for any N),
    ///   send:X | send:X:pan | send:X:mute   (X a slot letter A.. or a decimal index),
    ///   plug:X:N | plugin:X:N               (N = plugin parameter index).
    /// Rust's underscore send form ("send_b_level", "send_b_pan", "send_b_mute") is accepted too.
    /// Matching ignores ASCII case and surrounding whitespace.
    pub fn parse(input: []const u8) ?AutoParam {
        const s = std.mem.trim(u8, input, " \t\r\n");
        if (eqlIc(s, "vol") or eqlIc(s, "volume")) return .volume;
        if (eqlIc(s, "mute")) return .mute;
        if (eqlIc(s, "pan")) return .{ .pan = 0 };
        if (startsWithIc(s, "pan")) {
            const n = std.fmt.parseInt(u8, s[3..], 10) catch return null;
            return .{ .pan = n };
        }
        if (startsWithIc(s, "send:") or startsWithIc(s, "send_")) {
            const sep = s[4];
            var it = std.mem.splitScalar(u8, s[5..], sep);
            const slot = slotIndex(it.next() orelse return null) orelse return null;
            const field = it.next() orelse "level";
            if (it.next() != null) return null;
            if (eqlIc(field, "level")) return .{ .send_level = slot };
            if (eqlIc(field, "pan")) return .{ .send_pan = slot };
            if (eqlIc(field, "mute")) return .{ .send_mute = slot };
            return null;
        }
        const plug_prefix_len: usize = if (startsWithIc(s, "plugin:")) 7 else if (startsWithIc(s, "plug:")) 5 else return null;
        var it = std.mem.splitScalar(u8, s[plug_prefix_len..], ':');
        const slot = slotIndex(it.next() orelse return null) orelse return null;
        const param_text = it.next() orelse return null;
        if (it.next() != null) return null;
        const param = std.fmt.parseInt(u32, param_text, 10) catch return null;
        return .{ .plugin = .{ .slot = slot, .param = param } };
    }

    /// Value range and default: (min, max, default), in the parameter's natural units.
    pub fn range(self: AutoParam) Range {
        return switch (self) {
            .volume, .send_level => .{ .min = -144.0, .max = 12.0, .default = 0.0 },
            .pan, .send_pan => .{ .min = -1.0, .max = 1.0, .default = 0.0 },
            .mute, .send_mute => .{ .min = 0.0, .max = 1.0, .default = 0.0 },
            .plugin => .{ .min = -std.math.floatMax(f32), .max = std.math.floatMax(f32), .default = 0.0 },
        };
    }

    /// Mute-like lanes step at each point instead of ramping.
    pub fn isStep(self: AutoParam) bool {
        return switch (self) {
            .mute, .send_mute => true,
            else => false,
        };
    }
};

/// Slot letter for display: 0 is 'A'. Indices past 25 clamp to 'Z', as in SoundCraft.
pub fn slotLetter(i: u8) u8 {
    const clamped: u8 = @min(i, 25);
    return 'A' + clamped;
}

/// A single ASCII letter is a slot ('a' or 'A' is 0); anything else is a decimal index.
fn slotIndex(s: []const u8) ?u8 {
    if (s.len == 1 and std.ascii.isAlphabetic(s[0])) return std.ascii.toLower(s[0]) - 'a';
    return std.fmt.parseInt(u8, s, 10) catch null;
}

fn isSep(c: u8) bool {
    return c == '/' or c == '_';
}

/// Case-insensitive equality that ignores '/' and '_' on both sides.
fn idEq(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and isSep(a[i])) i += 1;
        while (j < b.len and isSep(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn eqlIc(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIc(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}
