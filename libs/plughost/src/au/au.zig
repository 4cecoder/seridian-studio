// Translated to Zig from soundcraft/crates/au-host/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The public Audio Unit host API (`au` in `root.zig`): the namespace over the AUv2 files of this
//! directory, plus the `Host` value that replaces the Rust process-wide registry.
//!
//! Ids are `au:<type>:<subtype>:<manufacturer>` (`au:aufx:dely:appl`); see `registry.zig` for the
//! codec, the category rules and the descriptor. Off macOS nothing is listed and nothing can be
//! created: `isSupported()` is false and every lookup returns `null` or `error.Unsupported`/
//! `error.NotFound`.
//!
//! Ownership, differing from the Rust free functions (`scan()`, `create(id)`, ...):
//! - There is no hidden global. The caller owns one `Host` per process, usually in the session
//!   layer, and passes it to the calls. Control thread only.
//! - `Host.scan` and `Host.plugin_info` return slices and pointers valid until the next
//!   `rescan` or `Host.deinit`. Rust returned owned copies.
//! - `Host.instantiate` heap-allocates the `AuPlugin` so its `Plugin` handle has a stable
//!   address; release it with `Host.destroy`.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const plugin_mod = @import("../plugin.zig");
pub const instance = @import("instance.zig");
pub const plugin = @import("plugin.zig");
pub const registry = @import("registry.zig");

pub const AuPlugin = plugin.AuPlugin;
pub const Registry = registry.Registry;
pub const AuDescriptor = registry.AuDescriptor;
pub const AuError = registry.AuError;
pub const ParsedId = registry.ParsedId;

const Allocator = std.mem.Allocator;
const PluginInfo = plugin_mod.PluginInfo;
const testing = std.testing;
const log = std.log.scoped(.plughost_au);

/// Prefix of every hosted-Audio-Unit plugin id.
pub const ID_PREFIX = registry.ID_PREFIX;
/// `aufx`: an audio effect.
pub const TYPE_EFFECT = registry.TYPE_EFFECT;
/// `aumf`: a music effect (an effect that also takes MIDI).
pub const TYPE_MUSIC_EFFECT = registry.TYPE_MUSIC_EFFECT;
/// `aumu`: a music device (instrument).
pub const TYPE_INSTRUMENT = registry.TYPE_INSTRUMENT;
/// The component types SoundCraft hosts.
pub const SUPPORTED_TYPES = registry.SUPPORTED_TYPES;

/// True when a component type is one SoundCraft hosts (effects, music effects, instruments).
pub const isSupportedType = registry.isSupportedType;
/// Writes a four-char code into `buf` (see `registry.fourccText`).
pub const fourccText = registry.fourccText;
/// Parses one four-char code written by `fourccText`.
pub const parseFourcc = registry.parseFourcc;
/// The SoundCraft id of a component. Caller frees the string.
pub const formatId = registry.formatId;
/// The `(type, subtype, manufacturer)` codes of an `au:…` id, or `null`.
pub const parseId = registry.parseId;
/// The insert-menu category of a component, from its type, subtype and name.
pub const categoryFor = registry.categoryFor;
/// Splits a component name `"Vendor: Plugin"` into vendor and name.
pub const splitComponentName = registry.splitComponentName;

/// Whether this build can host Audio Units at all (macOS only).
pub fn isSupported() bool {
    return abi.is_macos;
}

/// The process's Audio Unit host: one `Registry` (component list, cached plugin infos) owned by
/// the caller. Control thread only; the plugins it creates are driven from the audio thread
/// through their `Plugin` handles.
pub const Host = struct {
    gpa: Allocator,
    registry: Registry,

    pub fn init(gpa: Allocator) Host {
        return .{ .gpa = gpa, .registry = Registry.init(gpa) };
    }

    /// Destroys the registry. Every `AuPlugin` made by `instantiate` must be `destroy`ed first.
    pub fn deinit(self: *Host) void {
        self.registry.deinit();
        self.* = undefined;
    }

    /// Every hostable Audio Unit (effects, music effects, instruments). Listed on the first call
    /// and cached; valid until the next `rescan` or `deinit`.
    pub fn scan(self: *Host) AuError![]const AuDescriptor {
        return self.registry.scan();
    }

    /// Forgets the cached scan (and remembered failures) and lists again. Slices returned by
    /// earlier calls are invalid afterwards.
    pub fn rescan(self: *Host) AuError![]const AuDescriptor {
        return self.registry.rescan();
    }

    /// Creates a plugin by `au:<type>:<subtype>:<manufacturer>`, prepared for 48 kHz stereo with
    /// 1024-frame blocks, with the reason when it fails. Release with `destroy`.
    pub fn instantiate(self: *Host, id: []const u8) AuError!*AuPlugin {
        const p = try self.gpa.create(AuPlugin);
        errdefer self.gpa.destroy(p);
        p.* = try self.registry.instantiatePlugin(id);
        return p;
    }

    /// Disposes a plugin made by `instantiate` and frees it. Invalidates its `Plugin` handle.
    pub fn destroy(self: *Host, p: *AuPlugin) void {
        p.deinit();
        self.gpa.destroy(p);
    }

    /// Creates a plugin by `au:…` id; `null` if the id is unknown or it fails to load (the reason
    /// is logged). Rust `create`.
    pub fn create(self: *Host, id: []const u8) ?*AuPlugin {
        if (parseId(id) == null) return null;
        return self.instantiate(id) catch |err| {
            log.warn("{s}: {s}", .{ id, @errorName(err) });
            return null;
        };
    }

    /// The description of an `au:…` plugin. The first call for a type instantiates it once to read
    /// its parameters; the result is cached. Valid until `deinit`.
    pub fn pluginInfo(self: *Host, id: []const u8) ?*const PluginInfo {
        return self.registry.pluginInfo(id);
    }
};

// --- tests (lib.rs inline tests, same inputs and expected values) ---

test "au: fourccs round trip" {
    var buf: [9]u8 = undefined;
    try testing.expectEqual(@as(?u32, registry.TYPE_EFFECT), parseFourcc("aufx"));
    try testing.expectEqualStrings("aumu", fourccText(TYPE_INSTRUMENT, &buf));
    const dls = std.mem.readInt(u32, "dls ", .big);
    try testing.expectEqualStrings("dls ", fourccText(dls, &buf));
    try testing.expectEqualStrings("#01020304", fourccText(0x0102_0304, &buf));
    try testing.expectEqual(@as(?u32, 0x0102_0304), parseFourcc("#01020304"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("#0102030"));
    try testing.expectEqual(@as(?u32, std.mem.readInt(u32, "#abc", .big)), parseFourcc("#abc"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("abc"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("abcde"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("ab\u{e9}"));
    try testing.expectEqual(@as(?u32, null), parseFourcc(""));
    const codes = [_]u32{ 0, 0x7f7f_7f7f, 0x2020_2020, std.math.maxInt(u32), std.mem.readInt(u32, "a:b:", .big) };
    for (codes) |code| {
        try testing.expectEqual(@as(?u32, code), parseFourcc(fourccText(code, &buf)));
    }
}

test "au: ids parse and format" {
    const alloc = testing.allocator;
    const dly = [3]u32{ TYPE_EFFECT, std.mem.readInt(u32, "dely", .big), std.mem.readInt(u32, "appl", .big) };
    const s1 = try formatId(alloc, dly[0], dly[1], dly[2]);
    defer alloc.free(s1);
    try testing.expectEqualStrings("au:aufx:dely:appl", s1);
    const p1 = parseId("au:aufx:dely:appl") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(dly[0], p1.ty);
    try testing.expectEqual(dly[1], p1.subtype);
    try testing.expectEqual(dly[2], p1.manufacturer);

    const p2 = parseId("au:aumu:dls :appl") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(TYPE_INSTRUMENT, p2.ty);
    try testing.expectEqual(std.mem.readInt(u32, "dls ", .big), p2.subtype);

    // Colons inside a code are fine: fields have fixed widths.
    const odd_sub = std.mem.readInt(u32, "a:b:", .big);
    const odd_manu: u32 = 0x0000_00FF;
    const s = try formatId(alloc, registry.TYPE_MUSIC_EFFECT, odd_sub, odd_manu);
    defer alloc.free(s);
    try testing.expectEqualStrings("au:aumf:a:b::#000000FF", s);
    const p3 = parseId(s) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(registry.TYPE_MUSIC_EFFECT, p3.ty);
    try testing.expectEqual(odd_sub, p3.subtype);
    try testing.expectEqual(odd_manu, p3.manufacturer);

    const bad = [_][]const u8{
        "au:",
        "au:aufx",
        "au:aufx:dely",
        "au:aufx:dely:",
        "au:aufx:dely:appl:",
        "au:aufx:dely:appl ",
        "au:aufxdelyappl",
        "au:aufx;dely;appl",
        "AU:aufx:dely:appl",
        "au:aufc:dely:appl",
        "au:auou:def :appl",
        "au:aufx:d\u{e9}:appl",
        "vst3:0123",
        "eq_7band",
        "",
    };
    for (bad) |b| {
        try testing.expect(parseId(b) == null);
    }
}

test "au: categories and names" {
    const c = struct {
        fn of(ty: []const u8, sub: []const u8, name: []const u8) plugin_mod.Category {
            return categoryFor(std.mem.readInt(u32, ty[0..4], .big), std.mem.readInt(u32, sub[0..4], .big), name);
        }
    }.of;
    try testing.expectEqual(plugin_mod.Category.instrument, c("aumu", "dls ", "DLSMusicDevice"));
    try testing.expectEqual(plugin_mod.Category.delay, c("aufx", "dely", "AUDelay"));
    try testing.expectEqual(plugin_mod.Category.eq, c("aufx", "lpas", "AULowpass"));
    try testing.expectEqual(plugin_mod.Category.dynamics, c("aufx", "dcmp", "AUDynamicsProcessor"));
    try testing.expectEqual(plugin_mod.Category.reverb, c("aufx", "mrev", "AUMatrixReverb"));
    try testing.expectEqual(plugin_mod.Category.reverb, c("aufx", "xxxx", "Big Plate Verb"));
    try testing.expectEqual(plugin_mod.Category.delay, c("aufx", "xxxx", "Tape Echo"));
    try testing.expectEqual(plugin_mod.Category.other, c("aufx", "xxxx", "Thing"));

    const apple = splitComponentName("Apple: AUDelay");
    try testing.expectEqualStrings("Apple", apple.vendor);
    try testing.expectEqualStrings("AUDelay", apple.name);
    const novendor = splitComponentName("NoVendor");
    try testing.expectEqualStrings("", novendor.vendor);
    try testing.expectEqualStrings("NoVendor", novendor.name);
    const odd = splitComponentName("Odd:");
    try testing.expectEqualStrings("", odd.vendor);
    try testing.expectEqualStrings("Odd:", odd.name);
}

test "au: foreign ids are rejected without scanning" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    try testing.expect(host.create("eq_7band") == null);
    try testing.expect(host.create("vst3:0123456789ABCDEF0123456789ABCDEF") == null);
    try testing.expect(host.pluginInfo("reverb") == null);
    try testing.expect(host.pluginInfo("au:aufx") == null);
    // No scan ran: the registry still has no list.
    try testing.expect(host.registry.scanned == null);
}

test "au: unknown components are errors, not crashes" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    const missing = "au:aufx:zzzz:zzzz";
    try testing.expect(host.create(missing) == null);
    try testing.expect(host.pluginInfo(missing) == null);
    try testing.expectError(error.NotFound, host.instantiate(missing));
}

test "au: isSupported is true only on macOS" {
    try testing.expectEqual(builtin.os.tag == .macos, isSupported());
}

test "au: the namespace re-exports the registry and plugin types" {
    try testing.expectEqualStrings("au:", ID_PREFIX);
    try testing.expectEqual(@as(usize, 3), SUPPORTED_TYPES.len);
    try testing.expect(isSupportedType(TYPE_MUSIC_EFFECT));
    try testing.expect(!isSupportedType(0));
}
