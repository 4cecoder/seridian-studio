// Translated to Zig from soundcraft/crates/vst3-host/src/registry.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The process-wide VST3 registry: the scan cache, the one `PluginInfo` per plugin class
//! (kept for the life of the process in an arena the registry owns), instantiation, and the
//! in-process factory seam used by fixtures.
//!
//! Threading. Everything here is control-thread code: it takes the registry mutex, scans
//! folders, loads binaries (`dlopen`) and creates instances. Nothing in this file runs on the
//! audio thread. The mutex is held across scans and instantiation, as in the Rust code.
//!
//! Differences from the Rust code, all deliberate:
//! * `Mutex<Registry>` with a `OnceLock` becomes one `Registry` value, `global`, whose `io` is
//!   bound on first use (the same pattern as `module.zig`). Bundle loading goes through
//!   `module.globalRegistry()` in every case, so the binary cache is shared by all users.
//! * Leaked `&'static PluginInfo` values become arena allocations of `Registry.arena`.
//! * Functions that return owned lists take the allocator that owns the result (`gpa`).
//! * `unit_from_label` is `instance.zig`'s `unitFromLabel`; it is the same mapping and is
//!   reused here, not copied.
//! * `PluginInfo.short_name` takes the first eight Unicode code points (as Rust's
//!   `chars().take(8)`), counting a malformed UTF-8 byte as one code point.

const std = @import("std");
const abi = @import("abi.zig");
const module = @import("module.zig");
const scan_mod = @import("scan.zig");
const inst_mod = @import("instance.zig");
const vst3_plugin = @import("plugin.zig");
const api = @import("vst3.zig");
const plug = @import("../plugin.zig");
const params = @import("../params.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Descriptor = api.Descriptor;
const Error = api.Error;
const Instance = inst_mod.Instance;
const Vst3Plugin = vst3_plugin.Vst3Plugin;
const PluginInfo = plug.PluginInfo;
const ParamInfo = params.ParamInfo;

const log = std.log.scoped(.plughost_vst3);

/// Most labels read for a stepped parameter (more steps are shown as a plain range).
const MAX_CHOICES: i32 = inst_mod.MAX_CHOICES;

/// Sample rate, block size and channel count a fresh plugin is prepared for.
const PREPARE_SAMPLE_RATE: f32 = 48_000.0;
const PREPARE_MAX_BLOCK: usize = 1024;
const PREPARE_CHANNELS: usize = 2;

/// Characters of a plugin's short name (insert slots).
const SHORT_NAME_CHARS: usize = 8;

/// The registry state. One process-wide value, `global`; see the module docs.
pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// The scan cache: `null` until something scanned. The list owns its descriptors.
    scanned: ?std.ArrayList(Descriptor) = null,
    /// Folders added with `addSearchDir`. Owned strings.
    extra_dirs: std.ArrayList([]u8) = .empty,
    /// One `PluginInfo` per plugin class that was instantiated. Keys are the info's own id
    /// string, which lives in `arena`.
    infos: std.StringHashMapUnmanaged(*const PluginInfo) = .empty,
    /// Ids that failed to instantiate (not retried every UI frame). Owned keys.
    failed: std.StringHashMapUnmanaged(void) = .empty,
    /// Storage of every `PluginInfo` and its strings. Created on first use; never freed.
    arena: ?std.heap.ArenaAllocator = null,

    /// Locks the registry. Pair with `unlock`.
    fn lock(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }

    /// The arena that owns every `PluginInfo`.
    fn infoArena(self: *Registry) Allocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(self.gpa);
        return self.arena.?.allocator();
    }

    /// The scan cache, filled on first use. Caller holds the lock (the Rust `ensure_scanned`).
    fn ensureScanned(self: *Registry) Error!*std.ArrayList(Descriptor) {
        if (self.scanned == null) {
            const defaults = try scan_mod.defaultSearchPaths(self.gpa);
            defer scan_mod.freePaths(self.gpa, defaults);
            var dirs: std.ArrayList([]const u8) = .empty;
            defer dirs.deinit(self.gpa);
            for (defaults) |d| try dirs.append(self.gpa, d);
            for (self.extra_dirs.items) |d| try dirs.append(self.gpa, d);
            const found = try scanPathsIn(self.gpa, self.io, dirs.items);
            var list: std.ArrayList(Descriptor) = .empty;
            errdefer list.deinit(self.gpa);
            try list.appendSlice(self.gpa, found);
            self.gpa.free(found);
            self.scanned = list;
        }
        return &self.scanned.?;
    }

    /// Every plugin, scanning on first use. Returns a copy owned by `gpa`.
    pub fn scan(self: *Registry, gpa: Allocator) Error![]Descriptor {
        self.lock();
        defer self.unlock();
        return cloneList(gpa, (try self.ensureScanned()).items);
    }

    /// Forgets the cached scan and the remembered failures, then scans again.
    pub fn rescan(self: *Registry, gpa: Allocator) Error![]Descriptor {
        self.lock();
        defer self.unlock();
        self.dropScanned();
        self.clearFailed();
        return cloneList(gpa, (try self.ensureScanned()).items);
    }

    /// The cached plugins without scanning; `null` until something has scanned.
    pub fn cached(self: *Registry, gpa: Allocator) Error!?[]Descriptor {
        self.lock();
        defer self.unlock();
        const list = self.scanned orelse return null;
        return try cloneList(gpa, list.items);
    }

    /// Adds `dir` to the search path and merges the plugins it holds into the cache (the Rust
    /// `add_search_dir`). Returns how many plugins `dir` holds.
    pub fn addSearchDir(self: *Registry, dir: []const u8) Error!usize {
        self.lock();
        defer self.unlock();
        if (!containsPath(self.extra_dirs.items, dir)) {
            const owned = try self.gpa.dupe(u8, dir);
            errdefer self.gpa.free(owned);
            try self.extra_dirs.append(self.gpa, owned);
        }
        const found = try scanPathsIn(self.gpa, self.io, &.{dir});
        const n = found.len;
        if (self.scanned == null) self.scanned = .empty;
        try mergeDescriptors(self.gpa, &self.scanned.?, found);
        return n;
    }

    /// The description of a `vst3:<class id>` plugin. The first call for a class instantiates
    /// it once to read its parameters (the value is cached); `null` if unknown or failing.
    pub fn pluginInfo(self: *Registry, id: []const u8) ?*const PluginInfo {
        if (api.parseId(id) == null) return null;
        {
            self.lock();
            defer self.unlock();
            if (self.infos.get(id)) |info| return info;
            if (self.failed.contains(id)) return null;
        }
        // Instantiate once to learn the parameters (VST3 exposes them only on a live controller).
        const raw = self.instantiateRaw(id) catch return null;
        raw.inst.destroy();
        return raw.info;
    }

    /// Creates a plugin by `vst3:<class id>`, prepared for 48 kHz stereo with 1024-frame blocks.
    /// Caller frees it with `api.destroyPlugin`.
    pub fn instantiate(self: *Registry, gpa: Allocator, id: []const u8) Error!*Vst3Plugin {
        const raw = try self.instantiateRaw(id);
        const p = gpa.create(Vst3Plugin) catch {
            raw.inst.destroy();
            return error.OutOfMemory;
        };
        p.* = Vst3Plugin.init(gpa, raw.inst, raw.info) catch |e| {
            // `Vst3Plugin.init` destroyed the instance on failure.
            gpa.destroy(p);
            log.warn("cannot set up {s}: {s}", .{ id, @errorName(e) });
            return error.Instantiate;
        };
        p.prepare(PREPARE_SAMPLE_RATE, PREPARE_MAX_BLOCK, PREPARE_CHANNELS);
        return p;
    }

    /// Registers an in-process factory as the bundle `path` (see `api.registerFactory`).
    pub fn registerFactory(self: *Registry, path: []const u8, factory: *abi.IPluginFactory, exit_fn: ?module.ModuleExit) Error!void {
        const gpa = self.gpa;
        const owned_path = gpa.dupe(u8, path) catch {
            _ = abi.comRelease(factory);
            return error.OutOfMemory;
        };
        errdefer gpa.free(owned_path);
        const b = gpa.create(module.Bundle) catch {
            _ = abi.comRelease(factory);
            return error.OutOfMemory;
        };
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .path = owned_path, .factory = factory, .exit_fn = exit_fn, .entered_on = .main };
        // From here the bundle is owned by the module registry (its factory and exit too).
        module.globalRegistry().adopt(b) catch |e| {
            _ = abi.comRelease(factory);
            return e;
        };
        self.lock();
        defer self.unlock();
        const found = try descriptorsOf(gpa, b, path);
        if (self.scanned == null) self.scanned = .empty;
        try mergeDescriptors(gpa, &self.scanned.?, found);
    }

    /// Drops the scan cache (and its descriptors). Caller holds the lock.
    fn dropScanned(self: *Registry) void {
        if (self.scanned) |*list| {
            for (list.items) |*d| d.deinit(self.gpa);
            list.deinit(self.gpa);
        }
        self.scanned = null;
    }

    /// Forgets the remembered instantiation failures. Caller holds the lock.
    fn clearFailed(self: *Registry) void {
        var it = self.failed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.failed.clearRetainingCapacity();
    }

    /// Remembers that `id` failed, so it is not retried. Best effort: out of memory just means
    /// it is retried next time. Caller holds the lock.
    fn markFailed(self: *Registry, id: []const u8) void {
        if (self.failed.contains(id)) return;
        const key = self.gpa.dupe(u8, id) catch return;
        self.failed.put(self.gpa, key, {}) catch self.gpa.free(key);
    }

    /// The instance and its (cached) info. The instance is owned by the caller.
    const Raw = struct { inst: *Instance, info: *const PluginInfo };

    /// Finds the descriptor, loads its binary and creates an instance plus its (cached) info.
    fn instantiateRaw(self: *Registry, id: []const u8) Error!Raw {
        const cid = api.parseId(id) orelse return error.NotFound;
        var desc: Descriptor = undefined;
        {
            self.lock();
            defer self.unlock();
            if (self.failed.contains(id)) return error.Instantiate;
            const list = try self.ensureScanned();
            const found = findById(list.items, id) orelse return error.NotFound;
            desc = try found.clone(self.gpa);
        }
        defer desc.deinit(self.gpa);

        const bundle = module.loadBundle(desc.path) catch |e| {
            log.warn("cannot load {s}: {s}", .{ desc.path, @errorName(e) });
            self.lock();
            defer self.unlock();
            self.markFailed(id);
            return error.Load;
        };
        defer bundle.release();

        const made = Instance.create(self.gpa, bundle, &cid) catch |e| {
            log.warn("cannot create {s}: {s}", .{ id, @errorName(e) });
            self.lock();
            defer self.unlock();
            self.markFailed(id);
            return error.Instantiate;
        };

        self.lock();
        defer self.unlock();
        if (self.infos.get(id)) |info| return .{ .inst = made, .info = info };
        const info = self.buildInfo(&desc, made) catch {
            made.destroy();
            return error.OutOfMemory;
        };
        return .{ .inst = made, .info = info };
    }

    /// Builds and stores the `PluginInfo` of one plugin type. Called at most once per id.
    /// Caller holds the lock.
    fn buildInfo(self: *Registry, desc: *const Descriptor, inst: *Instance) Error!*const PluginInfo {
        const gpa = self.gpa;
        const arena = self.infoArena();
        const raw = try inst.params(gpa);
        defer inst_mod.freeParams(gpa, raw);

        var list: std.ArrayList(ParamInfo) = .empty;
        defer list.deinit(gpa);
        for (raw) |*p| {
            if ((p.flags & (inst_mod.PARAM_HIDDEN | inst_mod.PARAM_READ_ONLY | inst_mod.PARAM_BYPASS)) != 0) continue;
            try list.append(gpa, try paramInfo(gpa, arena, inst, p));
        }
        const params_owned = try arena.dupe(ParamInfo, list.items);

        const id = try arena.dupe(u8, desc.id);
        const name = try arena.dupe(u8, desc.name);
        const short = try shortName(arena, desc.name);
        const info = try arena.create(PluginInfo);
        info.* = .{
            .id = id,
            .name = name,
            .short_name = short,
            .category = desc.category,
            .params = params_owned,
            .is_instrument = desc.is_instrument,
            .audiosuite = false,
        };
        try self.infos.put(self.gpa, id, info);
        return info;
    }
};

/// The process-wide registry used by the host. Its `io` is bound on first use.
pub var global: Registry = .{ .gpa = std.heap.smp_allocator, .io = undefined };
var global_ready = std.atomic.Value(bool).init(false);

/// The process-wide registry (its `Io` is bound on first use).
pub fn globalRegistry() *Registry {
    if (!global_ready.load(.acquire)) {
        global.io = module.globalRegistry().io;
        global_ready.store(true, .release);
    }
    return &global;
}

/// Scans the folders of `dirs` (uncached) and returns the descriptors, owned by `gpa`.
fn scanPathsIn(gpa: Allocator, io: Io, dirs: []const []const u8) Error![]Descriptor {
    const paths = try scan_mod.findBundles(gpa, io, dirs);
    defer scan_mod.freePaths(gpa, paths);
    var out: std.ArrayList(Descriptor) = .empty;
    errdefer {
        for (out.items) |*d| d.deinit(gpa);
        out.deinit(gpa);
    }
    for (paths) |path| {
        const ds = loadDescriptors(gpa, path) catch continue; // already logged
        try mergeDescriptors(gpa, &out, ds);
    }
    // Stable sort by name (the Rust `sort_by_key` is stable), ASCII case-insensitive.
    std.sort.insertion(Descriptor, out.items, {}, lessByName);
    return out.toOwnedSlice(gpa);
}

/// Scans the given folders without touching the cache. Owned by `gpa`.
pub fn scanPaths(gpa: Allocator, dirs: []const []const u8) Error![]Descriptor {
    return scanPathsIn(gpa, globalRegistry().io, dirs);
}

/// The audio module classes of one already loaded bundle (the Rust `load_bundle` after `Bundle::load`).
fn descriptorsOf(gpa: Allocator, b: *module.Bundle, path: []const u8) Error![]Descriptor {
    const classes = try b.classes(gpa);
    defer module.freeClasses(gpa, classes);
    var out: std.ArrayList(Descriptor) = .empty;
    errdefer {
        for (out.items) |*d| d.deinit(gpa);
        out.deinit(gpa);
    }
    for (classes) |*c| {
        if (!std.mem.eql(u8, c.category, api.AUDIO_MODULE_CLASS)) continue;
        var d = try api.descriptorFromClass(gpa, c, path);
        errdefer d.deinit(gpa);
        try out.append(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

/// The audio module classes in one `.vst3` bundle or file. Owned by `gpa`. Loads the bundle
/// through the module registry and releases its reference again.
pub fn loadDescriptors(gpa: Allocator, path: []const u8) Error![]Descriptor {
    const b = module.loadBundle(path) catch |e| {
        log.warn("cannot load {s}: {s}", .{ path, @errorName(e) });
        return error.Load;
    };
    defer b.release();
    return descriptorsOf(gpa, b, path);
}

/// Adds each descriptor whose id is new to `list`, frees the rest, and frees the slice `ds`.
fn mergeDescriptors(gpa: Allocator, list: *std.ArrayList(Descriptor), ds: []Descriptor) Allocator.Error!void {
    defer gpa.free(ds);
    var i: usize = 0;
    // On failure the descriptors not yet handed to `list` are freed.
    errdefer for (ds[i..]) |*d| d.deinit(gpa);
    while (i < ds.len) : (i += 1) {
        const d = &ds[i];
        if (findById(list.items, d.id) != null) {
            d.deinit(gpa);
            continue;
        }
        try list.append(gpa, d.*);
    }
}

/// The copy of every descriptor, owned by `gpa`.
fn cloneList(gpa: Allocator, items: []const Descriptor) Allocator.Error![]Descriptor {
    const out = try gpa.alloc(Descriptor, items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |*d| d.deinit(gpa);
        gpa.free(out);
    }
    for (items) |*d| {
        out[n] = try d.clone(gpa);
        n += 1;
    }
    return out;
}

fn findById(items: []const Descriptor, id: []const u8) ?*const Descriptor {
    for (items) |*d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

fn containsPath(items: []const []u8, dir: []const u8) bool {
    for (items) |d| {
        if (std.mem.eql(u8, d, dir)) return true;
    }
    return false;
}

fn lessByName(_: void, a: Descriptor, b: Descriptor) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// The first `SHORT_NAME_CHARS` code points of `name`, copied into `arena`.
fn shortName(arena: Allocator, name: []const u8) Allocator.Error![]u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < name.len and count < SHORT_NAME_CHARS) : (count += 1) {
        const n = std.unicode.utf8ByteSequenceLength(name[end]) catch 1;
        end = @min(name.len, end + n);
    }
    return arena.dupe(u8, name[0..end]);
}

/// Converts a wide `f64` to `f32` the way Rust's `as` does: rounding, infinities kept, NaN kept.
fn toF32(x: f64) f32 {
    return @floatCast(x);
}

/// One parameter as plug-0 `ParamInfo`: a toggle, a choice (labels read from the controller), or
/// a continuous range with the unit and taper the controller reports. Strings are copied into
/// `arena`; `gpa` holds the temporary value texts.
fn paramInfo(gpa: Allocator, arena: Allocator, inst: *Instance, p: *const inst_mod.RawParam) Error!ParamInfo {
    const name = if (p.title.len == 0)
        try std.fmt.allocPrint(arena, "Param {d}", .{p.id})
    else
        try arena.dupe(u8, p.title);
    const id_text = try std.fmt.allocPrint(arena, "{d}", .{p.id});
    const base: ParamInfo = .{
        .id = id_text,
        .name = name,
        .min = 0.0,
        .max = 1.0,
        .default = 0.0,
        .unit = .none,
        .taper = .linear,
        .choices = &.{},
    };

    if (p.step_count == 1) {
        var r = base;
        r.unit = .toggle;
        r.default = toF32(@round(p.default_normalized));
        return r;
    }
    if (p.step_count >= 2 and p.step_count <= MAX_CHOICES) {
        const steps: f64 = @floatFromInt(p.step_count);
        const count: usize = @intCast(p.step_count + 1);
        const labels = try arena.alloc([]const u8, count);
        for (labels, 0..) |*slot, i| {
            const n = @as(f64, @floatFromInt(i)) / steps;
            const text = try inst.valueText(gpa, p.id, n);
            defer if (text) |t| gpa.free(t);
            slot.* = if (text) |t|
                try arena.dupe(u8, t)
            else
                try std.fmt.allocPrint(arena, "{d}", .{i});
        }
        var r = base;
        r.max = @floatFromInt(p.step_count);
        r.default = toF32(@round(p.default_normalized * steps));
        r.unit = .choice;
        r.choices = labels;
        return r;
    }

    // Continuous (or too many steps for a menu): a plain range from the controller.
    const unit = inst_mod.unitFromLabel(p.units);
    const lo_opt = inst.toPlain(p.id, 0.0);
    const hi_opt = inst.toPlain(p.id, 1.0);
    if (lo_opt) |lo| {
        if (hi_opt) |hi| {
            const lo32 = toF32(lo);
            const hi32 = toF32(hi);
            if (hi > lo and std.math.isFinite(lo32) and std.math.isFinite(hi32) and hi32 > lo32) {
                const default_plain: f64 = if (inst.toPlain(p.id, p.default_normalized)) |d|
                    std.math.clamp(d, lo, hi)
                else
                    lo;
                // A logarithmic plugin mapping (frequency knobs) shows its geometric mean at mid travel.
                const taper: plug.Taper = blk: {
                    const mid = inst.toPlain(p.id, 0.5) orelse break :blk .linear;
                    const geo = @sqrt(lo * hi);
                    if (lo > 0.0 and @abs(mid - geo) <= 0.01 * geo and @abs(mid - (lo + hi) / 2.0) > 0.01 * (hi - lo)) {
                        break :blk .log;
                    }
                    break :blk .linear;
                };
                var r = base;
                r.min = lo32;
                r.max = hi32;
                r.default = toF32(default_plain);
                r.unit = unit;
                r.taper = taper;
                return r;
            }
        }
    }
    var r = base;
    r.default = toF32(p.default_normalized);
    r.unit = unit;
    return r;
}

// ---- tests (ported from registry.rs) ------------------------------------------------------

const testing = std.testing;

test "unit_labels_map" {
    try testing.expectEqual(params.Unit.db, inst_mod.unitFromLabel("dB"));
    try testing.expectEqual(params.Unit.hz, inst_mod.unitFromLabel(" Hz "));
    try testing.expectEqual(params.Unit.percent, inst_mod.unitFromLabel("%"));
    try testing.expectEqual(params.Unit.ms, inst_mod.unitFromLabel("ms"));
    try testing.expectEqual(params.Unit.seconds, inst_mod.unitFromLabel("sec"));
    try testing.expectEqual(params.Unit.cents, inst_mod.unitFromLabel("cents"));
    try testing.expectEqual(params.Unit.semitones, inst_mod.unitFromLabel("st"));
    try testing.expectEqual(params.Unit.none, inst_mod.unitFromLabel("furlongs"));
}

test "shortName keeps the first eight code points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Reverb12", try shortName(arena.allocator(), "Reverb123456"));
    try testing.expectEqualStrings("short", try shortName(arena.allocator(), "short"));
    // Nine code points of two bytes each: the first eight are kept (16 bytes).
    try testing.expectEqualStrings("éééééééé", try shortName(arena.allocator(), "ééééééééé"));
}
