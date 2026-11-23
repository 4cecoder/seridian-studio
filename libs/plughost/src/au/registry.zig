// Translated to Zig from soundcraft/crates/au-host/src/registry.rs, soundcraft/crates/au-host/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The Audio Unit registry: component enumeration (aufx, aumf, aumu), the `au:` id codec,
//! `AuDescriptor`, parameter mapping, and one cached `PluginInfo` per plugin type.
//!
//! Ownership, replacing the Rust process-wide `Mutex<Registry>` and leaked `PluginInfo`s:
//! - `Registry` is a value the caller owns. It is control-thread only (no internal locks).
//!   Keep one per process in the session layer, not as a hidden global.
//! - `info_arena` owns every `PluginInfo`, its parameter table and its strings. It lives until
//!   `Registry.deinit`, so an `*const PluginInfo` (and any `AuPlugin` using it) must not outlive
//!   its registry.
//! - `scan_arena` owns the descriptors. `rescan` resets it, so slices returned by `scan` and
//!   `rescan` are valid until the next `rescan` or `deinit`. (Rust returned owned clones.)
//!
//! TODO(au-2): the id codec, `category_for`, `split_component_name`, `AuError` and the
//! four-char code helpers are the `au-host` lib.rs unit. That unit is not in the tree yet, so
//! they are translated here with their tests; move them to `au/mod.zig` (or wherever au-2 lands)
//! and import them when it does.

const std = @import("std");
const abi = @import("abi.zig");
const instance = @import("instance.zig");
const au_plugin = @import("plugin.zig");
const plugin = @import("../plugin.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const PluginInfo = plugin.PluginInfo;
const ParamInfo = plugin.ParamInfo;

/// Prefix of every hosted-Audio-Unit plugin id.
pub const ID_PREFIX = "au:";

/// Most labels for an indexed parameter shown as a choice (more become a plain range).
pub const MAX_CHOICES: f32 = 128.0;

/// AudioUnitParameterUnit values that are mapped.
const U_BOOLEAN: u32 = 2;
const U_PERCENT: u32 = 3;
const U_SECONDS: u32 = 4;
const U_HERTZ: u32 = 8;
const U_CENTS: u32 = 9;
const U_SEMITONES: u32 = 10;
const U_DECIBELS: u32 = 13;
const U_METERS: u32 = 19;
const U_ABSOLUTE_CENTS: u32 = 20;
const U_MILLISECONDS: u32 = 24;
const U_RATIO: u32 = 25;

/// Host defaults for the instance `plugin_info` and `instantiatePlugin` prepare with.
const DEFAULT_SAMPLE_RATE: f32 = 48_000.0;
const DEFAULT_BLOCK: usize = 1024;
const DEFAULT_CHANNELS: usize = 2;

/// Longest short name shown in an insert slot, in code points.
const SHORT_NAME_CODE_POINTS: usize = 8;

/// Four-char code from a string literal: `fourCC("aufx")`.
pub fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// `aufx`: an audio effect.
pub const TYPE_EFFECT: u32 = fourCC("aufx");
/// `aumf`: a music effect (an effect that also takes MIDI).
pub const TYPE_MUSIC_EFFECT: u32 = fourCC("aumf");
/// `aumu`: a music device (instrument).
pub const TYPE_INSTRUMENT: u32 = fourCC("aumu");
/// The component types SoundCraft hosts.
pub const SUPPORTED_TYPES = [_]u32{ TYPE_EFFECT, TYPE_MUSIC_EFFECT, TYPE_INSTRUMENT };

/// True when a component type is one SoundCraft hosts.
pub fn isSupportedType(ty: u32) bool {
    for (SUPPORTED_TYPES) |t| {
        if (t == ty) return true;
    }
    return false;
}

/// Writes a four-char code the way `fourcc_string` does: its four characters when all are
/// printable ASCII (`"dls "`), else `#` followed by 8 upper-case hex digits. `buf` holds the
/// result (at most 9 bytes); the returned slice points into it.
pub fn fourccText(code: u32, buf: *[9]u8) []const u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, code, .big);
    if (isPrintableCode(&b)) {
        @memcpy(buf[0..4], &b);
        return buf[0..4];
    }
    return std.fmt.bufPrint(buf, "#{X:0>8}", .{code}) catch unreachable;
}

fn isPrintableCode(b: []const u8) bool {
    for (b) |c| {
        if (c < 0x20 or c > 0x7e) return false;
    }
    return true;
}

/// Parses one four-char code written by `fourccText`.
pub fn parseFourcc(s: []const u8) ?u32 {
    const f = parseField(s) orelse return null;
    return if (f.rest.len == 0) f.code else null;
}

const Field = struct {
    code: u32,
    rest: []const u8,
};

/// Parses one code at the start of `s`, returning it and the rest.
fn parseField(s: []const u8) ?Field {
    // `#XXXXXXXX`, only when followed by the end or a field separator (a printable code may
    // itself start with `#`).
    if (s.len >= 9 and s[0] == '#' and (s.len == 9 or s[9] == ':')) {
        if (isHex8(s[1..9])) {
            const code = std.fmt.parseInt(u32, s[1..9], 16) catch return null;
            return .{ .code = code, .rest = s[9..] };
        }
    }
    if (s.len < 4) return null;
    const four = s[0..4];
    if (!isPrintableCode(four)) return null;
    return .{ .code = std.mem.readInt(u32, four, .big), .rest = s[4..] };
}

fn isHex8(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Writes `ty` as an owned string in `alloc` (the `fourcc_string` form).
fn fourccAlloc(alloc: Allocator, code: u32) Allocator.Error![]u8 {
    var buf: [9]u8 = undefined;
    return alloc.dupe(u8, fourccText(code, &buf));
}

/// The SoundCraft id of a component: `au:<type>:<subtype>:<manufacturer>`.
pub fn formatId(alloc: Allocator, ty: u32, subtype: u32, manufacturer: u32) Allocator.Error![]u8 {
    var b1: [9]u8 = undefined;
    var b2: [9]u8 = undefined;
    var b3: [9]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}{s}:{s}:{s}", .{
        ID_PREFIX,
        fourccText(ty, &b1),
        fourccText(subtype, &b2),
        fourccText(manufacturer, &b3),
    });
}

/// The four codes of an `au:…` id.
pub const ParsedId = struct {
    ty: u32,
    subtype: u32,
    manufacturer: u32,
};

/// The `(type, subtype, manufacturer)` codes of an `au:…` id (`null` for other ids or a
/// component type SoundCraft does not host).
pub fn parseId(id: []const u8) ?ParsedId {
    if (!std.mem.startsWith(u8, id, ID_PREFIX)) return null;
    const t = parseField(id[ID_PREFIX.len..]) orelse return null;
    if (t.rest.len == 0 or t.rest[0] != ':') return null;
    const s = parseField(t.rest[1..]) orelse return null;
    if (s.rest.len == 0 or s.rest[0] != ':') return null;
    const m = parseField(s.rest[1..]) orelse return null;
    if (m.rest.len != 0 or !isSupportedType(t.code)) return null;
    return .{ .ty = t.code, .subtype = s.code, .manufacturer = m.code };
}

/// Insert-menu category rules keyed by subtype (the Rust `match` on the four bytes).
const SubtypeRule = struct {
    code: [4]u8,
    category: plugin.Category,
};

const subtype_rules = [_]SubtypeRule{
    .{ .code = "dely".*, .category = .delay },
    .{ .code = "sdly".*, .category = .delay },
    .{ .code = "mdly".*, .category = .delay },
    .{ .code = "lpas".*, .category = .eq },
    .{ .code = "hpas".*, .category = .eq },
    .{ .code = "bpas".*, .category = .eq },
    .{ .code = "hshf".*, .category = .eq },
    .{ .code = "lshf".*, .category = .eq },
    .{ .code = "pmeq".*, .category = .eq },
    .{ .code = "nbeq".*, .category = .eq },
    .{ .code = "geq ".*, .category = .eq },
    .{ .code = "dcmp".*, .category = .dynamics },
    .{ .code = "mcmp".*, .category = .dynamics },
    .{ .code = "lmtr".*, .category = .dynamics },
    .{ .code = "xpnd".*, .category = .dynamics },
    .{ .code = "ngte".*, .category = .dynamics },
    .{ .code = "rvb2".*, .category = .reverb },
    .{ .code = "mrev".*, .category = .reverb },
    .{ .code = "dist".*, .category = .harmonic },
    .{ .code = "tmpt".*, .category = .pitch_shift },
    .{ .code = "pitc".*, .category = .pitch_shift },
    .{ .code = "nutp".*, .category = .pitch_shift },
};

/// The insert-menu category of a component, from its type, subtype and name.
pub fn categoryFor(ty: u32, subtype: u32, name: []const u8) plugin.Category {
    if (ty == TYPE_INSTRUMENT) return .instrument;
    var sb: [4]u8 = undefined;
    std.mem.writeInt(u32, &sb, subtype, .big);
    for (subtype_rules) |r| {
        if (std.mem.eql(u8, &r.code, &sb)) return r.category;
    }
    const has = struct {
        fn any(haystack: []const u8, words: []const []const u8) bool {
            for (words) |w| {
                if (std.ascii.findIgnoreCase(haystack, w) != null) return true;
            }
            return false;
        }
    }.any;
    if (has(name, &.{ "reverb", "verb", "room", "hall", "plate" })) return .reverb;
    if (has(name, &.{ "delay", "echo" })) return .delay;
    if (has(name, &.{ "eq", "filter", "lowpass", "highpass", "bandpass", "shelf" })) return .eq;
    if (has(name, &.{ "compress", "limit", "gate", "expand", "dynamic", "de-ess" })) return .dynamics;
    if (has(name, &.{ "chorus", "flang", "phase", "tremolo", "vibrato", "rotary", "ring mod" })) return .modulation;
    if (has(name, &.{ "distort", "satur", "overdrive", "fuzz", "bitcrush" })) return .harmonic;
    if (has(name, &.{ "pitch", "tune", "shift" })) return .pitch_shift;
    return .other;
}

/// Splits a component name `"Vendor: Plugin"` into vendor and name. Both point into `full`.
pub fn splitComponentName(full: []const u8) struct { vendor: []const u8, name: []const u8 } {
    if (std.mem.indexOfScalar(u8, full, ':')) |i| {
        const name = std.mem.trim(u8, full[i + 1 ..], std.ascii.whitespace[0..]);
        if (name.len != 0) {
            return .{ .vendor = std.mem.trim(u8, full[0..i], std.ascii.whitespace[0..]), .name = name };
        }
    }
    return .{ .vendor = "", .name = std.mem.trim(u8, full, std.ascii.whitespace[0..]) };
}

/// Why an Audio Unit operation failed. Rust carried the id and a message; the message is
/// logged at the failure site instead.
pub const AuError = error{
    NotFound,
    InstantiateFailed,
    Unsupported,
    OutOfMemory,
};

/// One Audio Unit found by a scan.
pub const AuDescriptor = struct {
    /// SoundCraft id: `au:<type>:<subtype>:<manufacturer>`.
    id: []const u8,
    name: []const u8,
    vendor: []const u8,
    /// `major.minor.bugfix` from the component version.
    version: []const u8,
    /// The four-char codes as written in the id.
    component_type: []const u8,
    subtype: []const u8,
    manufacturer: []const u8,
    category: plugin.Category,
    is_instrument: bool,
};

/// `AudioUnitParameterUnit` and the custom unit label to a SoundCraft display unit.
pub fn unitFor(unit: u32, custom: []const u8) plugin.Unit {
    return switch (unit) {
        U_DECIBELS => .db,
        U_HERTZ => .hz,
        U_MILLISECONDS => .ms,
        U_PERCENT => .percent,
        U_SECONDS => .seconds,
        U_SEMITONES => .semitones,
        U_CENTS, U_ABSOLUTE_CENTS => .cents,
        U_RATIO => .ratio,
        abi.unit_custom => customUnit(custom),
        else => .none,
    };
}

fn customUnit(custom: []const u8) plugin.Unit {
    const t = std.mem.trim(u8, custom, std.ascii.whitespace[0..]);
    if (std.ascii.eqlIgnoreCase(t, "db")) return .db;
    if (std.ascii.eqlIgnoreCase(t, "hz")) return .hz;
    if (std.ascii.eqlIgnoreCase(t, "ms")) return .ms;
    if (std.ascii.eqlIgnoreCase(t, "%")) return .percent;
    if (std.ascii.eqlIgnoreCase(t, "s") or std.ascii.eqlIgnoreCase(t, "sec") or std.ascii.eqlIgnoreCase(t, "secs")) return .seconds;
    return .none;
}

/// The SoundCraft description of one parameter, or `null` for read-only, meter and broken ones.
/// Strings are allocated in `arena`.
pub fn paramInfo(arena: Allocator, p: *const abi.RawParam) Allocator.Error!?ParamInfo {
    if ((p.flags & abi.param_flag_writable) == 0 or (p.flags & abi.param_flag_meter_read_only) != 0 or p.unit == U_METERS) {
        return null;
    }
    if (!(std.math.isFinite(p.min) and std.math.isFinite(p.max) and p.max > p.min)) return null;
    const trimmed = std.mem.trim(u8, p.name, std.ascii.whitespace[0..]);
    const name = if (trimmed.len == 0)
        try std.fmt.allocPrint(arena, "Param {d}", .{p.id})
    else
        try arena.dupe(u8, trimmed);
    const default = if (std.math.isFinite(p.default)) std.math.clamp(p.default, p.min, p.max) else p.min;
    var pi: ParamInfo = .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{p.id}),
        .name = name,
        .min = p.min,
        .max = p.max,
        .default = default,
        .unit = .none,
        .taper = .linear,
    };

    if (p.unit == U_BOOLEAN and p.min == 0.0 and p.max == 1.0) {
        pi.unit = .toggle;
        pi.default = @round(default);
        return pi;
    }
    if (p.unit == abi.unit_indexed and p.min == 0.0 and @trunc(p.max) == p.max and p.max <= MAX_CHOICES) {
        const n: usize = @intFromFloat(p.max);
        const labels = try arena.alloc([]const u8, n + 1);
        for (labels, 0..) |*label, i| {
            label.* = if (i < p.value_strings.len and p.value_strings[i].len != 0)
                try arena.dupe(u8, p.value_strings[i])
            else
                try std.fmt.allocPrint(arena, "{d}", .{i});
        }
        pi.unit = .choice;
        pi.default = @round(default);
        pi.choices = labels;
        return pi;
    }

    const unit = unitFor(p.unit, p.custom_unit);
    const is_log = p.min > 0.0 and ((p.flags & abi.param_flag_display_log) != 0 or
        (unit == .hz and p.max / p.min >= 10.0));
    pi.unit = unit;
    pi.taper = if (is_log) .log else .linear;
    return pi;
}

/// `major.minor.bugfix` from a packed component version. Owned by `alloc`.
pub fn versionString(alloc: Allocator, v: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ v >> 16, (v >> 8) & 0xff, v & 0xff });
}

/// The first `SHORT_NAME_CODE_POINTS` code points of `name` (a prefix of `name`).
fn shortName(name: []const u8) []const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < name.len and count < SHORT_NAME_CODE_POINTS) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(name[end]) catch 1;
        end = @min(name.len, end + len);
    }
    return name[0..end];
}

/// Errors from the Instance create call, mapped to registry errors.
fn mapCreateError(e: instance.CreateError) AuError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.InstantiateFailed,
    };
}

/// The Audio Unit registry. Control thread only; see the module docs for ownership.
pub const Registry = struct {
    gpa: Allocator,
    /// Owns the descriptors of the last scan. Reset by `rescan`.
    scan_arena: std.heap.ArenaAllocator,
    /// Owns every `PluginInfo`, its parameter table and its id strings. Lives until `deinit`.
    info_arena: std.heap.ArenaAllocator,
    /// The descriptors of the last scan, or null before the first one.
    scanned: ?[]const AuDescriptor = null,
    /// One `PluginInfo` per plugin id that was instantiated. Keys live in `info_arena`.
    infos: std.StringHashMapUnmanaged(*const PluginInfo) = .empty,
    /// Ids that failed to instantiate (not retried every UI frame). Keys live in `info_arena`.
    failed: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: Allocator) Registry {
        return .{
            .gpa = gpa,
            .scan_arena = std.heap.ArenaAllocator.init(gpa),
            .info_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.infos.deinit(self.gpa);
        self.failed.deinit(self.gpa);
        self.scan_arena.deinit();
        self.info_arena.deinit();
        self.* = undefined;
    }

    /// Every hostable Audio Unit (effects, music effects, instruments). Listed on the first call
    /// (reads the component registry, creates no instances), then cached.
    pub fn scan(self: *Registry) AuError![]const AuDescriptor {
        return self.ensureScanned();
    }

    /// Forgets the cached scan and remembered failures, then lists again. Invalidates the slices
    /// returned earlier.
    pub fn rescan(self: *Registry) AuError![]const AuDescriptor {
        self.scanned = null;
        self.failed.clearRetainingCapacity();
        _ = self.scan_arena.reset(.free_all);
        return self.ensureScanned();
    }

    fn ensureScanned(self: *Registry) AuError![]const AuDescriptor {
        if (self.scanned) |list| return list;
        const list = try self.listComponents();
        self.scanned = list;
        return list;
    }

    fn listComponents(self: *Registry) AuError![]const AuDescriptor {
        const alloc = self.scan_arena.allocator();
        var out: std.ArrayList(AuDescriptor) = .empty;
        for (SUPPORTED_TYPES) |ty| {
            const comps = try abi.components(self.gpa, ty);
            defer abi.freeComponents(self.gpa, comps);
            for (comps) |c| {
                const id = try formatId(alloc, c.ty, c.subtype, c.manufacturer);
                if (containsId(out.items, id)) continue;
                const split = splitComponentName(c.name);
                const name = if (split.name.len == 0) "Audio Unit" else split.name;
                try out.append(alloc, .{
                    .id = id,
                    .name = try alloc.dupe(u8, name),
                    .vendor = try alloc.dupe(u8, split.vendor),
                    .version = try versionString(alloc, c.version),
                    .component_type = try fourccAlloc(alloc, c.ty),
                    .subtype = try fourccAlloc(alloc, c.subtype),
                    .manufacturer = try fourccAlloc(alloc, c.manufacturer),
                    .category = categoryFor(c.ty, c.subtype, name),
                    .is_instrument = c.ty == TYPE_INSTRUMENT,
                });
            }
        }
        // Stable sort by lower-cased name, as the Rust `sort_by_key` did.
        std.sort.block(AuDescriptor, out.items, {}, byName);
        return out.items;
    }

    /// The `PluginInfo` for `id` if it is already known or can be learned by instantiating it
    /// once (the instance is then disposed). `null` for foreign ids, unknown components and
    /// components that fail to load.
    pub fn pluginInfo(self: *Registry, id: []const u8) ?*const PluginInfo {
        _ = parseId(id) orelse return null;
        if (self.infos.get(id)) |info| return info;
        if (self.failed.contains(id)) return null;
        const made = self.instantiateRaw(id) catch |err| {
            log.warn("plugin info for {s}: {s}", .{ id, @errorName(err) });
            return null;
        };
        made.inst.destroy();
        return made.info;
    }

    /// A prepared plugin for `id` (48 kHz, 1024-frame blocks, stereo). The returned value owns the
    /// unit: call `deinit` on it, and keep it at a stable address before taking `plugin()`.
    pub fn instantiatePlugin(self: *Registry, id: []const u8) AuError!au_plugin.AuPlugin {
        const made = try self.instantiateRaw(id);
        const has_input = made.ty == TYPE_EFFECT or made.ty == TYPE_MUSIC_EFFECT;
        const takes_midi = made.ty == TYPE_INSTRUMENT or made.ty == TYPE_MUSIC_EFFECT;
        var p = try au_plugin.AuPlugin.init(self.gpa, made.inst, made.info, has_input, takes_midi);
        p.prepare(DEFAULT_SAMPLE_RATE, DEFAULT_BLOCK, DEFAULT_CHANNELS);
        return p;
    }

    const Made = struct {
        inst: *instance.Instance,
        info: *const PluginInfo,
        ty: u32,
    };

    /// Finds the descriptor, creates an instance, and returns it with its (cached) info. The
    /// caller owns `inst`.
    fn instantiateRaw(self: *Registry, id: []const u8) AuError!Made {
        const ids = parseId(id) orelse return error.NotFound;
        if (self.failed.contains(id)) return error.InstantiateFailed;
        const desc = try self.findDescriptor(id);
        const has_input = ids.ty == TYPE_EFFECT or ids.ty == TYPE_MUSIC_EFFECT;
        const inst = instance.Instance.create(self.gpa, ids.ty, ids.subtype, ids.manufacturer, has_input) catch |err| {
            self.markFailed(id) catch |mark_err| return mark_err;
            log.warn("cannot create Audio Unit {s}: {s}", .{ id, @errorName(err) });
            return mapCreateError(err);
        };
        errdefer inst.destroy();
        if (self.infos.get(id)) |cached| return .{ .inst = inst, .info = cached, .ty = ids.ty };
        const info = try self.buildInfo(desc, inst);
        const key = try self.info_arena.allocator().dupe(u8, id);
        try self.infos.put(self.gpa, key, info);
        return .{ .inst = inst, .info = info, .ty = ids.ty };
    }

    fn findDescriptor(self: *Registry, id: []const u8) AuError!*const AuDescriptor {
        for (try self.ensureScanned()) |*d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return error.NotFound;
    }

    fn markFailed(self: *Registry, id: []const u8) AuError!void {
        if (self.failed.contains(id)) return;
        const key = try self.info_arena.allocator().dupe(u8, id);
        try self.failed.put(self.gpa, key, {});
    }

    /// Builds and stores the `PluginInfo` for one plugin type from the unit's parameter list.
    /// Duplicate parameter ids are dropped (first wins), then `paramInfo` filters the rest.
    fn buildInfo(self: *Registry, d: *const AuDescriptor, inst: *instance.Instance) AuError!*const PluginInfo {
        const arena = self.info_arena.allocator();
        const raw = try inst.params(self.gpa);
        defer instance.Instance.freeParams(self.gpa, raw);
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(self.gpa);
        var list: std.ArrayList(ParamInfo) = .empty;
        for (raw) |*p| {
            const gop = try seen.getOrPut(self.gpa, p.id);
            if (gop.found_existing) continue;
            if (try paramInfo(arena, p)) |pi| try list.append(arena, pi);
        }
        const info = try arena.create(PluginInfo);
        info.* = .{
            .id = try arena.dupe(u8, d.id),
            .name = try arena.dupe(u8, d.name),
            .short_name = try arena.dupe(u8, shortName(d.name)),
            .category = d.category,
            .params = try list.toOwnedSlice(arena),
            .is_instrument = d.is_instrument,
            .audiosuite = false,
        };
        return info;
    }
};

fn byName(_: void, a: AuDescriptor, b: AuDescriptor) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn containsId(list: []const AuDescriptor, id: []const u8) bool {
    for (list) |d| {
        if (std.mem.eql(u8, d.id, id)) return true;
    }
    return false;
}

const log = std.log.scoped(.plughost_au);

// --- tests (registry.rs and lib.rs inline tests, same inputs and expected values) ---

/// Arguments for a test parameter. The rest of the `RawParam` is fixed: id 7, name "Cutoff",
/// and the writable and readable flags the Rust helper always set.
const RawSpec = struct {
    unit: u32,
    min: f32,
    max: f32,
    default: f32,
    flags: u32 = 0,
    custom: []const u8 = "",
    values: []const []const u8 = &.{},
};

/// Builds a `RawParam` whose strings live in `a` (tests use an arena and skip `deinit`).
fn rawParam(a: Allocator, s: RawSpec) !abi.RawParam {
    const vs = try a.alloc([]u8, s.values.len);
    for (s.values, 0..) |v, i| vs[i] = try a.dupe(u8, v);
    return .{
        .id = 7,
        .name = try a.dupe(u8, "Cutoff"),
        .unit = s.unit,
        .custom_unit = try a.dupe(u8, s.custom),
        .min = s.min,
        .max = s.max,
        .default = s.default,
        .flags = s.flags | abi.param_flag_writable | abi.param_flag_readable,
        .value_strings = vs,
    };
}

test "au registry: units_map" {
    try testing.expectEqual(plugin.Unit.db, unitFor(U_DECIBELS, ""));
    try testing.expectEqual(plugin.Unit.hz, unitFor(U_HERTZ, ""));
    try testing.expectEqual(plugin.Unit.ms, unitFor(U_MILLISECONDS, ""));
    try testing.expectEqual(plugin.Unit.cents, unitFor(U_CENTS, ""));
    try testing.expectEqual(plugin.Unit.db, unitFor(abi.unit_custom, " dB "));
    try testing.expectEqual(plugin.Unit.none, unitFor(abi.unit_custom, "furlongs"));
    try testing.expectEqual(plugin.Unit.none, unitFor(999, ""));
}

test "au registry: params_map_and_hostile_ones_are_dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cutoff = try rawParam(a, .{ .unit = U_HERTZ, .min = 10.0, .max = 22_050.0, .default = 6900.0 });
    const p = (try paramInfo(a, &cutoff)).?;
    try testing.expectEqualStrings("7", p.id);
    try testing.expectEqualStrings("Cutoff", p.name);
    try testing.expectEqual(plugin.Unit.hz, p.unit);
    try testing.expectEqual(plugin.Taper.log, p.taper);
    try testing.expectEqual(@as(f32, 6900.0), p.default);

    var toggle = try rawParam(a, .{ .unit = U_BOOLEAN, .min = 0.0, .max = 1.0, .default = 1.0 });
    try testing.expectEqual(plugin.Unit.toggle, (try paramInfo(a, &toggle)).?.unit);

    var ix = try rawParam(a, .{ .unit = abi.unit_indexed, .min = 0.0, .max = 2.0, .default = 1.0, .values = &.{ "Low", "" } });
    const c = (try paramInfo(a, &ix)).?;
    try testing.expectEqual(plugin.Unit.choice, c.unit);
    try testing.expectEqual(@as(usize, 3), c.choices.len);
    try testing.expectEqualStrings("Low", c.choices[0]);
    try testing.expectEqualStrings("1", c.choices[1]);
    try testing.expectEqualStrings("2", c.choices[2]);

    // Indexed not starting at 0 stays a plain range.
    var ix_range = try rawParam(a, .{ .unit = abi.unit_indexed, .min = 1.0, .max = 4.0, .default = 1.0 });
    try testing.expectEqual(plugin.Unit.none, (try paramInfo(a, &ix_range)).?.unit);

    // Hostile defaults clamp; broken ranges, meters and read-only params are skipped.
    var nan_default = try rawParam(a, .{ .unit = U_DECIBELS, .min = -20.0, .max = 20.0, .default = std.math.nan(f32) });
    try testing.expectEqual(@as(f32, -20.0), (try paramInfo(a, &nan_default)).?.default);
    var high_default = try rawParam(a, .{ .unit = U_DECIBELS, .min = -20.0, .max = 20.0, .default = 99.0 });
    try testing.expectEqual(@as(f32, 20.0), (try paramInfo(a, &high_default)).?.default);

    var equal_range = try rawParam(a, .{ .unit = U_DECIBELS, .min = 1.0, .max = 1.0, .default = 1.0 });
    try testing.expect((try paramInfo(a, &equal_range)) == null);
    var neg_inf = try rawParam(a, .{ .unit = U_DECIBELS, .min = -std.math.inf(f32), .max = 0.0, .default = 0.0 });
    try testing.expect((try paramInfo(a, &neg_inf)) == null);
    var nan_max = try rawParam(a, .{ .unit = U_DECIBELS, .min = 0.0, .max = std.math.nan(f32), .default = 0.0 });
    try testing.expect((try paramInfo(a, &nan_max)) == null);
    var meter = try rawParam(a, .{ .unit = U_METERS, .min = 0.0, .max = 1.0, .default = 0.0 });
    try testing.expect((try paramInfo(a, &meter)) == null);
    var meter_flag = try rawParam(a, .{ .unit = U_DECIBELS, .min = 0.0, .max = 1.0, .default = 0.0, .flags = abi.param_flag_meter_read_only });
    try testing.expect((try paramInfo(a, &meter_flag)) == null);
    var read_only = try rawParam(a, .{ .unit = U_DECIBELS, .min = 0.0, .max = 1.0, .default = 0.0 });
    read_only.flags &= ~abi.param_flag_writable;
    try testing.expect((try paramInfo(a, &read_only)) == null);

    const v = try versionString(testing.allocator, 0x0001_0203);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1.2.3", v);
}

test "au registry: fourccs_round_trip" {
    var buf: [9]u8 = undefined;
    try testing.expectEqual(@as(?u32, TYPE_EFFECT), parseFourcc("aufx"));
    try testing.expectEqualStrings("aumu", fourccText(TYPE_INSTRUMENT, &buf));
    try testing.expectEqualStrings("dls ", fourccText(fourCC("dls "), &buf));
    try testing.expectEqualStrings("#01020304", fourccText(0x0102_0304, &buf));
    try testing.expectEqual(@as(?u32, 0x0102_0304), parseFourcc("#01020304"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("#0102030"));
    try testing.expectEqual(@as(?u32, fourCC("#abc")), parseFourcc("#abc"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("abc"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("abcde"));
    try testing.expectEqual(@as(?u32, null), parseFourcc("ab\xc3\xa9"));
    try testing.expectEqual(@as(?u32, null), parseFourcc(""));
    const codes = [_]u32{ 0, 0x7f7f_7f7f, 0x2020_2020, std.math.maxInt(u32), fourCC("a:b:") };
    for (codes) |code| {
        try testing.expectEqual(@as(?u32, code), parseFourcc(fourccText(code, &buf)));
    }
}

test "au registry: ids_parse_and_format" {
    const dly: ParsedId = .{ .ty = TYPE_EFFECT, .subtype = fourCC("dely"), .manufacturer = fourCC("appl") };
    const s = try formatId(testing.allocator, dly.ty, dly.subtype, dly.manufacturer);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("au:aufx:dely:appl", s);
    try testing.expectEqualDeep(@as(?ParsedId, dly), parseId("au:aufx:dely:appl"));

    const dls: ParsedId = .{ .ty = TYPE_INSTRUMENT, .subtype = fourCC("dls "), .manufacturer = fourCC("appl") };
    try testing.expectEqualDeep(@as(?ParsedId, dls), parseId("au:aumu:dls :appl"));

    // Colons inside a code are fine: fields have fixed widths.
    const odd: ParsedId = .{ .ty = TYPE_MUSIC_EFFECT, .subtype = fourCC("a:b:"), .manufacturer = 0x0000_00FF };
    const os = try formatId(testing.allocator, odd.ty, odd.subtype, odd.manufacturer);
    defer testing.allocator.free(os);
    try testing.expectEqualStrings("au:aumf:a:b::#000000FF", os);
    try testing.expectEqualDeep(@as(?ParsedId, odd), parseId(os));

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
        "au:aufx:d\xc3\xa9:appl",
        "vst3:0123",
        "eq_7band",
        "",
    };
    for (bad) |b| {
        try testing.expect(parseId(b) == null);
    }
}

test "au registry: categories_and_names" {
    try testing.expectEqual(plugin.Category.instrument, categoryFor(fourCC("aumu"), fourCC("dls "), "DLSMusicDevice"));
    try testing.expectEqual(plugin.Category.delay, categoryFor(fourCC("aufx"), fourCC("dely"), "AUDelay"));
    try testing.expectEqual(plugin.Category.eq, categoryFor(fourCC("aufx"), fourCC("lpas"), "AULowpass"));
    try testing.expectEqual(plugin.Category.dynamics, categoryFor(fourCC("aufx"), fourCC("dcmp"), "AUDynamicsProcessor"));
    try testing.expectEqual(plugin.Category.reverb, categoryFor(fourCC("aufx"), fourCC("mrev"), "AUMatrixReverb"));
    try testing.expectEqual(plugin.Category.reverb, categoryFor(fourCC("aufx"), fourCC("xxxx"), "Big Plate Verb"));
    try testing.expectEqual(plugin.Category.delay, categoryFor(fourCC("aufx"), fourCC("xxxx"), "Tape Echo"));
    try testing.expectEqual(plugin.Category.other, categoryFor(fourCC("aufx"), fourCC("xxxx"), "Thing"));

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

test "au registry: foreign_ids_are_rejected_without_scanning" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expect(parseId("eq_7band") == null);
    try testing.expect(parseId("vst3:0123456789ABCDEF0123456789ABCDEF") == null);
    try testing.expect(reg.pluginInfo("reverb") == null);
    try testing.expect(parseId("au:aufx") == null);
    try testing.expect(reg.pluginInfo("au:aufx") == null);
}

test "au registry: unknown_components_are_errors_not_crashes" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const missing = "au:aufx:zzzz:zzzz";
    try testing.expect(reg.pluginInfo(missing) == null);
    // Off macOS the scan is empty and the component is missing; on macOS it is not registered.
    try testing.expectError(error.NotFound, reg.instantiatePlugin(missing));
}
