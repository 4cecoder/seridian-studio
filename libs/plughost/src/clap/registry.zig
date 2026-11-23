// Translated to Zig from soundcraft/crates/clap-host/src/registry.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The process-wide CLAP registry: the scan cache, the loaded binaries, one `PluginInfo` per
//! plugin type, and instantiation.
//!
//! Control thread only. Every entry point takes the registry lock (`std.Io.Mutex`), so the UI
//! and a background scan can share it; the lock is held across a scan, as in the Rust code.
//!
//! Ownership:
//! - Scan results (`scanned`) and the extra folders are owned by `gpa`, the registry's allocator
//!   (`std.heap.smp_allocator` for the process registry). Public calls return deep copies owned
//!   by the caller's allocator.
//! - Each loaded binary is cached by the path it was loaded under, and stays mapped until
//!   `shutdown`. This is the Rust `Bundle::load` policy: no instance outlives its code.
//! - Each plugin type's `PluginInfo` (with its parameter table and strings) lives in
//!   `infos_arena` for the life of the process, as the Rust code leaks it. `shutdown` frees it,
//!   so pointers from `pluginInfo` are dangling after `shutdown`.
//!
//! Differences from registry.rs, all deliberate:
//! - Parameter tables keep hidden and read-only parameters. `ClapPlugin.create` maps one
//!   `PluginInfo.param` per usable CLAP parameter and refuses a different count
//!   (`ParamMapMismatch`), so the Rust filter cannot be applied here without changing
//!   `instance.zig`. The UI sees those parameters.
//! - `pluginInfo` learns the parameters from a temporary instance that is destroyed right away;
//!   `ClapPlugin.create` takes the info, so it cannot share that instance. A plugin is initialised
//!   twice the first time its type is used.
//! - Plugin creation happens under the registry lock (Rust released it while loading).
//! - `scan`'s name sort compares ASCII case-insensitively; Rust's `to_lowercase` is Unicode.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.plughost_clap);
const clap = @import("clap.zig");
const abi = @import("abi.zig");
const bundle_mod = @import("bundle.zig");
const instance_mod = @import("instance.zig");
const plugin_clap = @import("plugin.zig");
const scan_files = @import("scan.zig");
const plugin_api = @import("../plugin.zig");
const params_mod = @import("../params.zig");
const test_fixture = @import("test_fixture.zig");

const ClapDescriptor = clap.ClapDescriptor;
const ClapError = clap.ClapError;
const ClapPlugin = plugin_clap.ClapPlugin;
const Instance = instance_mod.Instance;
const PluginInfo = plugin_api.PluginInfo;
const ParamInfo = params_mod.ParamInfo;
const Unit = params_mod.Unit;
const Taper = params_mod.Taper;

/// Most labels read for an enum parameter (`MAX_CHOICES` in registry.rs).
const MAX_CHOICES: f64 = 128.0;
/// Bytes of value text read per parameter label (`value_text` in ffi/instance.rs).
const VALUE_TEXT_CAP: usize = 128;
/// `CLAP_PARAM_IS_ENUM` from CLAP 1.2 `params.h`. Not in abi.zig yet; see test_fixture.zig.
const CLAP_PARAM_IS_ENUM: u32 = 1 << 16;
/// How a plugin is prepared before it is returned: 48 kHz stereo, 1024-frame blocks, as
/// `soundcraft_dsp::create` does.
const PREPARE_SAMPLE_RATE: f32 = 48_000.0;
const PREPARE_MAX_BLOCK: usize = 1024;
const PREPARE_CHANNELS: usize = 2;

/// The process registry. Its allocator is `smp_allocator`; its info arena is backed by
/// `page_allocator`, so nothing here depends on a hidden `Io`.
pub var global: Registry = .{
    .gpa = std.heap.smp_allocator,
    .infos_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
};

/// A registry instance. `global` is the one the public API uses; tests build their own.
pub const Registry = struct {
    gpa: Allocator,
    /// Owns every `PluginInfo`, its parameter table and its strings. Freed by `shutdown`.
    infos_arena: std.heap.ArenaAllocator,
    /// Serialises every call. Control thread only.
    mutex: Io.Mutex = .init,
    /// The last scan (`null` until something has scanned or registered a fixture).
    scanned: ?std.ArrayList(ClapDescriptor) = null,
    /// Folders added with `addSearchDir`, owned by `gpa`.
    extra_dirs: std.ArrayList([]const u8) = .empty,
    /// Loaded binaries by the path they were loaded under. Keys owned by `gpa`.
    bundles: std.StringHashMapUnmanaged(bundle_mod.Bundle) = .empty,
    /// One info per plugin id. Keys are the info's own id string (owned by the arena).
    infos: std.StringHashMapUnmanaged(*const PluginInfo) = .empty,
    /// Ids that failed to instantiate, so they are not retried every UI frame. Keys owned by `gpa`.
    failed: std.StringHashMapUnmanaged(void) = .empty,

    /// Every plugin in the standard CLAP folders, `CLAP_PATH` and folders added with
    /// `addSearchDir`. Scanned on the first call, then cached. The result is owned by `gpa`.
    pub fn scan(self: *Registry, io: Io, gpa: Allocator) ClapError![]ClapDescriptor {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const list = try self.ensureScannedLocked(io);
        return cloneList(gpa, list.items);
    }

    /// Forgets the cached scan and remembered failures, then scans again.
    pub fn rescan(self: *Registry, io: Io, gpa: Allocator) ClapError![]ClapDescriptor {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearScanned();
        self.clearFailed();
        const list = try self.ensureScannedLocked(io);
        return cloneList(gpa, list.items);
    }

    /// The plugins of the last scan without scanning. `null` until something has scanned.
    pub fn cached(self: *Registry, io: Io, gpa: Allocator) ClapError!?[]ClapDescriptor {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const list = if (self.scanned) |*l| l else return null;
        return try cloneList(gpa, list.items);
    }

    /// Adds a folder to the search path and merges its plugins into the cache. Returns how many
    /// plugins the folder holds. As in the Rust code, this creates an empty cache when nothing
    /// has scanned yet, so the default folders are then not scanned by `scan`.
    pub fn addSearchDir(self: *Registry, io: Io, dir: []const u8) ClapError!usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!containsPath(self.extra_dirs.items, dir)) {
            const owned = try self.gpa.dupe(u8, dir);
            errdefer self.gpa.free(owned);
            try self.extra_dirs.append(self.gpa, owned);
        }
        var found = try self.scanPathsLocked(io, &.{dir});
        defer freeList(self.gpa, &found);
        const n = found.items.len;
        const list = self.scannedOrEmpty();
        _ = try self.mergeDescriptors(list, &found);
        return n;
    }

    /// Scans `dirs` without touching the cache. Unloadable files are logged and skipped; the
    /// first plugin with a given id wins.
    pub fn scanPaths(self: *Registry, io: Io, gpa: Allocator, dirs: []const []const u8) ClapError![]ClapDescriptor {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var found = try self.scanPathsLocked(io, dirs);
        defer freeList(self.gpa, &found);
        return cloneList(gpa, found.items);
    }

    /// The plugins in one `.clap` file or bundle. Loads (and keeps mapped) the binary.
    pub fn loadBundle(self: *Registry, io: Io, gpa: Allocator, path: []const u8) ClapError![]ClapDescriptor {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const b = try self.bundleLocked(io, path);
        var found = try self.describe(&b, path);
        defer freeList(self.gpa, &found);
        return cloneList(gpa, found.items);
    }

    /// Test seam: registers an in-process CLAP entry (no dylib) under `name`, the path its
    /// plugins report, and merges its plugins into the cache so `cached` and `instantiate` see
    /// them. Returns how many plugins were added. Registering a name twice is an error.
    pub fn registerEntry(self: *Registry, io: Io, entry: *const abi.ClapPluginEntry, name: [:0]const u8) ClapError!usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.bundles.contains(name)) return error.AlreadyRegistered;
        const fresh = bundle_mod.Bundle.fromEntry(entry, name) catch |e| {
            log.warn("cannot register CLAP entry {s}: {s}", .{ name, @errorName(e) });
            return error.LoadFailed;
        };
        const stored = try self.storeBundle(name, fresh);
        var found = try self.describe(&stored, name);
        defer freeList(self.gpa, &found);
        const list = self.scannedOrEmpty();
        return self.mergeDescriptors(list, &found);
    }

    /// Creates a plugin by `clap:<id>`, prepared for 48 kHz stereo with 1024-frame blocks. The
    /// caller destroys it with `ClapPlugin.destroy`, before `shutdown`.
    pub fn instantiate(self: *Registry, io: Io, id: []const u8) ClapError!*ClapPlugin {
        if (clap.parseId(id) == null) return error.NotFound;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.failed.contains(id)) return error.InstantiateFailed;
        const desc = try self.findLocked(io, id);
        return self.createLocked(io, desc) catch |e| {
            self.rememberFailure(id);
            return e;
        };
    }

    /// Creates a plugin by `clap:<id>`; `null` if the id is not a CLAP id, is unknown, or fails.
    pub fn create(self: *Registry, io: Io, id: []const u8) ?*ClapPlugin {
        if (clap.parseId(id) == null) return null;
        return self.instantiate(io, id) catch |e| {
            log.warn("cannot create CLAP plugin {s}: {s}", .{ id, @errorName(e) });
            return null;
        };
    }

    /// The description of a `clap:<id>` plugin, cached for the life of the process. The first
    /// call for a plugin type creates one temporary instance to read its parameters.
    pub fn pluginInfo(self: *Registry, io: Io, id: []const u8) ?*const PluginInfo {
        if (clap.parseId(id) == null) return null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.infos.get(id)) |info| return info;
        if (self.failed.contains(id)) return null;
        const desc = self.findLocked(io, id) catch |e| {
            if (e != error.NotFound) log.warn("cannot read CLAP plugin {s}: {s}", .{ id, @errorName(e) });
            return null;
        };
        const b = self.bundleLocked(io, desc.path) catch {
            self.rememberFailure(id);
            return null;
        };
        return self.infoLocked(desc, b.factory) catch {
            self.rememberFailure(id);
            return null;
        };
    }

    /// Frees every loaded binary, cached scan, info and remembered failure. Plugins still alive
    /// become dangling: destroy them first.
    pub fn shutdown(self: *Registry, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearScanned();
        for (self.extra_dirs.items) |d| self.gpa.free(d);
        self.extra_dirs.deinit(self.gpa);
        self.extra_dirs = .empty;
        var bit = self.bundles.iterator();
        while (bit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.bundles.deinit(self.gpa);
        self.bundles = .empty;
        self.clearFailed();
        self.failed.deinit(self.gpa);
        self.failed = .empty;
        self.infos.deinit(self.gpa);
        self.infos = .empty;
        self.infos_arena.deinit();
        self.infos_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }

    // ---- locked helpers: the caller holds `mutex` --------------------------------------------

    fn ensureScannedLocked(self: *Registry, io: Io) ClapError!*std.ArrayList(ClapDescriptor) {
        if (self.scanned == null) {
            const defaults = try scan_files.defaultSearchPaths(self.gpa);
            defer scan_files.freePaths(self.gpa, defaults);
            var dirs: std.ArrayList([]const u8) = .empty;
            defer dirs.deinit(self.gpa);
            try dirs.ensureUnusedCapacity(self.gpa, defaults.len + self.extra_dirs.items.len);
            for (defaults) |d| dirs.appendAssumeCapacity(d);
            for (self.extra_dirs.items) |d| dirs.appendAssumeCapacity(d);
            self.scanned = try self.scanPathsLocked(io, dirs.items);
        }
        return &self.scanned.?;
    }

    /// The scan cache, created empty when it does not exist yet.
    fn scannedOrEmpty(self: *Registry) *std.ArrayList(ClapDescriptor) {
        if (self.scanned == null) self.scanned = .empty;
        return &self.scanned.?;
    }

    fn clearScanned(self: *Registry) void {
        if (self.scanned) |*list| freeList(self.gpa, list);
        self.scanned = null;
    }

    fn clearFailed(self: *Registry) void {
        var it = self.failed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.failed.clearRetainingCapacity();
    }

    fn rememberFailure(self: *Registry, id: []const u8) void {
        if (self.failed.contains(id)) return;
        const owned = self.gpa.dupe(u8, id) catch |e| {
            log.warn("cannot remember that CLAP plugin {s} failed: {s}", .{ id, @errorName(e) });
            return;
        };
        self.failed.put(self.gpa, owned, {}) catch |e| {
            self.gpa.free(owned);
            log.warn("cannot remember that CLAP plugin {s} failed: {s}", .{ id, @errorName(e) });
        };
    }

    fn findLocked(self: *Registry, io: Io, id: []const u8) ClapError!*const ClapDescriptor {
        const list = try self.ensureScannedLocked(io);
        for (list.items) |*d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return error.NotFound;
    }

    /// Scans `dirs`: every bundle is loaded and described, the first plugin with an id wins, and
    /// the result is sorted by name. Unloadable bundles are logged and skipped.
    fn scanPathsLocked(self: *Registry, io: Io, dirs: []const []const u8) ClapError!std.ArrayList(ClapDescriptor) {
        const paths = try scan_files.findBundles(self.gpa, io, dirs);
        defer scan_files.freePaths(self.gpa, paths);
        var out: std.ArrayList(ClapDescriptor) = .empty;
        errdefer freeList(self.gpa, &out);
        for (paths) |path| {
            const b = self.bundleLocked(io, path) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("cannot load CLAP plugin {s}: {s}", .{ path, @errorName(e) });
                    continue;
                },
            };
            var found = try self.describe(&b, path);
            defer freeList(self.gpa, &found);
            _ = try self.mergeDescriptors(&out, &found);
        }
        std.sort.block(ClapDescriptor, out.items, {}, lessByName);
        return out;
    }

    /// Appends the descriptors of `src` that `dst` does not hold yet, by id. Each entry of `src`
    /// is either moved into `dst` or freed; `src` is left empty. Returns how many were added.
    fn mergeDescriptors(self: *Registry, dst: *std.ArrayList(ClapDescriptor), src: *std.ArrayList(ClapDescriptor)) ClapError!usize {
        try dst.ensureUnusedCapacity(self.gpa, src.items.len);
        var added: usize = 0;
        for (src.items) |*d| {
            if (containsId(dst.items, d.id)) {
                d.deinit(self.gpa);
            } else {
                dst.appendAssumeCapacity(d.*);
                added += 1;
            }
        }
        src.clearRetainingCapacity();
        return added;
    }

    /// The loaded binary for `path`, opening it on first use.
    fn bundleLocked(self: *Registry, io: Io, path: []const u8) ClapError!bundle_mod.Bundle {
        if (self.bundles.get(path)) |b| return b;
        const opened = try self.openBundle(io, path);
        return self.storeBundle(path, opened);
    }

    /// Opens `path`: a `.clap` file, or a macOS bundle whose executable is found by the scan.
    fn openBundle(self: *Registry, io: Io, path: []const u8) ClapError!bundle_mod.Bundle {
        const exe = (try scan_files.bundleExecutable(self.gpa, io, path)) orelse {
            log.warn("cannot load CLAP plugin {s}: no loadable binary", .{path});
            return error.LoadFailed;
        };
        defer self.gpa.free(exe);
        const exe_z = try clap.dupeZ(self.gpa, exe);
        defer self.gpa.free(exe_z);
        const path_z = try clap.dupeZ(self.gpa, path);
        defer self.gpa.free(path_z);
        const lib = bundle_mod.openLibrary(exe_z) catch |e| {
            log.warn("cannot load CLAP plugin {s}: {s}", .{ path, @errorName(e) });
            return error.LoadFailed;
        };
        var b = bundle_mod.Bundle.fromEntry(lib.entry, path_z) catch |e| {
            lib.close();
            log.warn("cannot initialise CLAP plugin {s}: {s}", .{ path, @errorName(e) });
            return error.LoadFailed;
        };
        b.handle = lib.handle;
        return b;
    }

    /// Caches a loaded binary under `path`; the registry owns it from here.
    fn storeBundle(self: *Registry, path: []const u8, b: bundle_mod.Bundle) ClapError!bundle_mod.Bundle {
        var owned = b;
        const key = self.gpa.dupe(u8, path) catch |e| {
            owned.deinit();
            return e;
        };
        self.bundles.put(self.gpa, key, owned) catch |e| {
            owned.deinit();
            self.gpa.free(key);
            return e;
        };
        return owned;
    }

    /// The descriptors a loaded binary reports, owned by `self.gpa`. Each carries `path`.
    fn describe(self: *Registry, b: *const bundle_mod.Bundle, path: []const u8) ClapError!std.ArrayList(ClapDescriptor) {
        const raw = try self.gpa.alloc(bundle_mod.RawDescriptor, abi.MAX_PLUGINS_PER_FACTORY);
        defer self.gpa.free(raw);
        const n = b.descriptors(raw);
        var out: std.ArrayList(ClapDescriptor) = .empty;
        errdefer freeList(self.gpa, &out);
        try out.ensureUnusedCapacity(self.gpa, n);
        for (raw[0..n]) |r| {
            out.appendAssumeCapacity(try fromRaw(self.gpa, r, path));
        }
        return out;
    }

    /// Creates the plugin, with its cached info, from a descriptor's bundle.
    fn createLocked(self: *Registry, io: Io, desc: *const ClapDescriptor) ClapError!*ClapPlugin {
        const b = try self.bundleLocked(io, desc.path);
        const info = try self.infoLocked(desc, b.factory);
        const p = ClapPlugin.create(self.gpa, b.factory, desc.plugin_id, info) catch |e| return mapCreateError(e);
        p.plugin().prepare(PREPARE_SAMPLE_RATE, PREPARE_MAX_BLOCK, PREPARE_CHANNELS);
        return p;
    }

    /// The cached info for `desc`, built from a temporary instance on first use.
    fn infoLocked(self: *Registry, desc: *const ClapDescriptor, factory: *const abi.ClapPluginFactory) ClapError!*const PluginInfo {
        if (self.infos.get(desc.id)) |info| return info;
        const inst = Instance.create(self.gpa, factory, desc.plugin_id, null) catch |e| return mapCreateError(e);
        defer inst.destroy();
        const info = try self.buildInfo(desc, inst);
        try self.infos.put(self.gpa, info.id, info);
        return info;
    }

    fn buildInfo(self: *Registry, desc: *const ClapDescriptor, inst: *const Instance) ClapError!*const PluginInfo {
        const arena = self.infos_arena.allocator();
        const raw = try inst.readParams(self.gpa);
        defer instance_mod.freeParams(self.gpa, raw);
        const param_table = try arena.alloc(ParamInfo, raw.len);
        for (raw, param_table) |p, *out| out.* = try paramInfo(arena, inst, p);
        const info = try arena.create(PluginInfo);
        info.* = .{
            .id = try arena.dupe(u8, desc.id),
            .name = try arena.dupe(u8, desc.name),
            .short_name = try shortName(arena, desc.name),
            .category = desc.category,
            .params = param_table,
            .is_instrument = desc.is_instrument,
            .audiosuite = false,
        };
        return info;
    }
};

// ---- helpers ---------------------------------------------------------------------------------

fn mapCreateError(e: anyerror) ClapError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.InstantiateFailed;
}

fn containsId(list: []const ClapDescriptor, id: []const u8) bool {
    for (list) |d| {
        if (std.mem.eql(u8, d.id, id)) return true;
    }
    return false;
}

fn containsPath(list: []const []const u8, path: []const u8) bool {
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn lessByName(_: void, a: ClapDescriptor, b: ClapDescriptor) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Frees every descriptor in `list` and the list's buffer.
fn freeList(gpa: Allocator, list: *std.ArrayList(ClapDescriptor)) void {
    for (list.items) |*d| d.deinit(gpa);
    list.deinit(gpa);
}

/// A deep copy of `items`, owned by `gpa` (free with `clap.freeDescriptors`).
fn cloneList(gpa: Allocator, items: []const ClapDescriptor) Allocator.Error![]ClapDescriptor {
    const out = try gpa.alloc(ClapDescriptor, items.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |*d| d.deinit(gpa);
        gpa.free(out);
    }
    for (items, 0..) |*d, i| {
        out[i] = try d.clone(gpa);
        made = i + 1;
    }
    return out;
}

/// A descriptor built from what the factory reported. The id gets the `clap:` prefix.
fn fromRaw(gpa: Allocator, raw: bundle_mod.RawDescriptor, path: []const u8) Allocator.Error!ClapDescriptor {
    const features_in = raw.featureList();
    const id = try std.fmt.allocPrint(gpa, "{s}{s}", .{ clap.ID_PREFIX, raw.id });
    errdefer gpa.free(id);
    const plugin_id = try clap.dupeZ(gpa, raw.id);
    errdefer gpa.free(plugin_id);
    const name = try gpa.dupe(u8, raw.name);
    errdefer gpa.free(name);
    const vendor = try gpa.dupe(u8, raw.vendor);
    errdefer gpa.free(vendor);
    const version = try gpa.dupe(u8, raw.version);
    errdefer gpa.free(version);
    const description = try gpa.dupe(u8, raw.description);
    errdefer gpa.free(description);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const features = try clap.dupeStrings(gpa, features_in);
    errdefer clap.freeStrings(gpa, features);
    return .{
        .id = id,
        .plugin_id = plugin_id,
        .name = name,
        .vendor = vendor,
        .version = version,
        .description = description,
        .features = features,
        .category = scan_files.categoryFromFeatures(features_in),
        .is_instrument = scan_files.isInstrument(features_in),
        .path = owned_path,
    };
}

/// The `ParamInfo` for one CLAP parameter. Stepped 0..1 parameters are toggles; stepped 0..n
/// parameters (n up to `MAX_CHOICES`) are choices labelled by the plugin's own value text.
fn paramInfo(arena: Allocator, inst: *const Instance, p: instance_mod.RawParam) Allocator.Error!ParamInfo {
    const stepped = p.flags & abi.CLAP_PARAM_IS_STEPPED != 0;
    const is_enum = p.flags & CLAP_PARAM_IS_ENUM != 0;
    var unit: Unit = .none;
    var choices: []const []const u8 = &.{};
    if (stepped and p.min == 0.0 and p.max == 1.0 and !is_enum) {
        unit = .toggle;
    } else if (stepped and p.min == 0.0 and p.max >= 1.0 and p.max <= MAX_CHOICES) {
        const count: usize = @as(usize, @intFromFloat(p.max)) + 1;
        const labels = try arena.alloc([]const u8, count);
        for (labels, 0..) |*slot, i| {
            slot.* = try valueLabel(arena, inst, p.id, @intCast(i));
        }
        unit = .choice;
        choices = labels;
    }
    const name = if (p.name.len == 0)
        try std.fmt.allocPrint(arena, "Param {d}", .{p.id})
    else if (p.module.len == 0)
        try arena.dupe(u8, p.name)
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.module, p.name });
    return .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{p.id}),
        .name = name,
        .min = @floatCast(p.min),
        .max = @floatCast(p.max),
        .default = @floatCast(p.default),
        .unit = unit,
        .taper = Taper.linear,
        .choices = choices,
    };
}

/// The plugin's text for choice `index`, or the number itself when the plugin gives none.
fn valueLabel(arena: Allocator, inst: *const Instance, id: abi.ClapId, index: u32) Allocator.Error![]const u8 {
    var buf: [VALUE_TEXT_CAP]u8 = undefined;
    if (inst.valueText(id, @floatFromInt(index), &buf)) |text| return arena.dupe(u8, text);
    return std.fmt.allocPrint(arena, "{d}", .{index});
}

/// The first eight characters (code points) of `name`, for insert slots. Invalid UTF-8 bytes
/// count as one character each.
fn shortName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < name.len and count < 8) : (count += 1) {
        const len: usize = std.unicode.utf8ByteSequenceLength(name[end]) catch 1;
        end = @min(name.len, end + len);
    }
    return arena.dupe(u8, name[0..end]);
}

// ---- tests -----------------------------------------------------------------------------------

fn testIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

test "registry: registerEntry scans and instantiates an in-process fixture" {
    const io = testIo();
    test_fixture.reset();
    var reg: Registry = .{
        .gpa = testing.allocator,
        .infos_arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer reg.shutdown(io);

    const added = try reg.registerEntry(io, &test_fixture.entry, "in-process-fixture");
    try testing.expectEqual(@as(usize, 5), added);
    try testing.expectError(error.AlreadyRegistered, reg.registerEntry(io, &test_fixture.entry, "in-process-fixture"));

    const listed = (try reg.cached(io, testing.allocator)).?;
    defer clap.freeDescriptors(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 5), listed.len);
    try testing.expect(containsId(listed, "clap:org.soundcraft.test.gain"));
    try testing.expectEqualStrings("Fixture Gain", listed[0].name);
    try testing.expectEqualStrings("in-process-fixture", listed[0].path);

    const p = try reg.instantiate(io, "clap:org.soundcraft.test.gain");
    defer p.destroy();
    const plug = p.plugin();
    try testing.expectEqualStrings("clap:org.soundcraft.test.gain", plug.info().id);
    try testing.expectEqual(plug.info(), reg.pluginInfo(io, "clap:org.soundcraft.test.gain").?);

    var gain_param: ?ParamInfo = null;
    for (plug.info().params) |pi| {
        if (std.mem.eql(u8, pi.name, "Gain")) gain_param = pi;
    }
    const gp = gain_param orelse return error.MissingGainParam;
    try testing.expectEqual(@as(f32, 0.0), gp.min);
    try testing.expectEqual(@as(f32, 2.0), gp.max);
    try testing.expectEqual(@as(f32, 1.0), gp.default);
}

test "registry: an unknown id is NotFound and is not remembered as failed" {
    const io = testIo();
    var reg: Registry = .{
        .gpa = testing.allocator,
        .infos_arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer reg.shutdown(io);
    _ = try reg.registerEntry(io, &test_fixture.entry, "not-found-fixture");
    try testing.expectError(error.NotFound, reg.instantiate(io, "clap:does.not.exist"));
    try testing.expectError(error.NotFound, reg.instantiate(io, "eq_7band"));
    try testing.expectEqual(@as(u32, 0), reg.failed.count());
}
