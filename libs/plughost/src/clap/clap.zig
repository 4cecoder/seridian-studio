// Translated to Zig from soundcraft/crates/clap-host/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Seridian's CLAP plugin host, public namespace.
//!
//! Scans the standard CLAP folders (plus `CLAP_PATH`), loads `.clap` binaries in-process and
//! exposes each plugin as a `plugin.zig` `Plugin` handle, so the mix engine treats third-party
//! plugins like the built-in ones. Plugin ids are `clap:<CLAP plugin id>`; parameter ids are the
//! dense indices of `PluginInfo.params`, with the CLAP ids as decimal strings.
//!
//! Differences from the Rust crate, all deliberate:
//! - The registry lives in `registry.zig` and is reached as `clap.registry.global`. Zig does not
//!   allow a function and a file namespace both called `scan`, so Rust's `scan`, `rescan`,
//!   `cached`, `scan_paths`, `load_bundle` and `add_search_dir` are methods on `Registry`.
//! - Every registry call takes the process `std.Io` (the registry lock and the file system need
//!   it) and the allocator that owns any list it returns. Free returned lists with
//!   `freeDescriptors` using that same allocator.
//! - `create` and `instantiate` return `*ClapPlugin`, not a `Plugin` handle: the handle has no
//!   destroy entry, and the owner must call `ClapPlugin.destroy`. Use `.plugin()` for the handle.
//! - `ClapError` is an error set. The Rust variants that carried text log their text at the
//!   point of failure instead (`std.log`, control thread only).
//! - The wasm32 stub module is dropped: this build hosts CLAP on macOS, Windows and Linux.
//! - The Rust `serde::Serialize` derive on `ClapDescriptor` is not translated.
//!
//! Control thread only. `PluginInfo` pointers returned by `pluginInfo` and every loaded binary
//! stay valid until `Registry.shutdown`; a plugin's factory pointer is valid until its bundle is
//! shut down, so shut down only after every plugin created from it is destroyed.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const plugin_api = @import("../plugin.zig");

pub const registry = @import("registry.zig");
pub const abi = @import("abi.zig");
pub const events = @import("events.zig");
pub const bundle = @import("bundle.zig");
pub const host = @import("host.zig");
pub const instance = @import("instance.zig");
pub const gui = @import("gui.zig");
pub const hostwin = @import("hostwin.zig");
pub const plugin = @import("plugin.zig");
pub const scan = @import("scan.zig");

pub const ClapPlugin = plugin.ClapPlugin;
pub const Category = plugin_api.Category;
pub const PluginInfo = plugin_api.PluginInfo;

/// Prefix of every hosted-CLAP plugin id.
pub const ID_PREFIX: []const u8 = "clap:";

/// Why a CLAP operation failed. Details (the path, the reason) are logged where they occur.
pub const ClapError = error{
    /// The binary could not be found, opened, initialised or given a factory (Rust `Load`).
    LoadFailed,
    /// No plugin with this id is in the scan (Rust `NotFound`).
    NotFound,
    /// The plugin could not be created or initialised (Rust `Instantiate`).
    InstantiateFailed,
    /// A process call failed (Rust `Process`). Not produced by the registry; kept for the API.
    ProcessFailed,
    /// Hosting is not available on this platform (Rust `Unsupported`). Not produced by this build.
    Unsupported,
    /// `Registry.registerEntry` was given a name that is already registered.
    AlreadyRegistered,
    OutOfMemory,
};

/// The CLAP plugin id inside a `clap:<id>` SoundCraft id (`null` for other ids or an empty id).
pub fn parseId(id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, id, ID_PREFIX)) return null;
    const rest = id[ID_PREFIX.len..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, 0) != null) return null;
    return rest;
}

/// One plugin found by a scan. Every string is owned by the descriptor (free it with `deinit`
/// or `freeDescriptors`).
pub const ClapDescriptor = struct {
    /// SoundCraft id: `clap:<plugin_id>`.
    id: []const u8,
    /// The CLAP plugin id (reverse-DNS, e.g. `com.vendor.reverb`), NUL-terminated for the ABI.
    plugin_id: [:0]const u8,
    name: []const u8,
    vendor: []const u8,
    version: []const u8,
    description: []const u8,
    features: []const []const u8,
    category: Category,
    is_instrument: bool,
    /// The `.clap` file or bundle it lives in, as the scan was given it.
    path: []const u8,

    pub fn deinit(self: *ClapDescriptor, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.plugin_id);
        gpa.free(self.name);
        gpa.free(self.vendor);
        gpa.free(self.version);
        gpa.free(self.description);
        gpa.free(self.path);
        freeStrings(gpa, self.features);
    }

    /// A deep copy owned by `gpa`.
    pub fn clone(self: *const ClapDescriptor, gpa: Allocator) Allocator.Error!ClapDescriptor {
        const id = try gpa.dupe(u8, self.id);
        errdefer gpa.free(id);
        const plugin_id = try dupeZ(gpa, self.plugin_id);
        errdefer gpa.free(plugin_id);
        const name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(name);
        const vendor = try gpa.dupe(u8, self.vendor);
        errdefer gpa.free(vendor);
        const version = try gpa.dupe(u8, self.version);
        errdefer gpa.free(version);
        const description = try gpa.dupe(u8, self.description);
        errdefer gpa.free(description);
        const path = try gpa.dupe(u8, self.path);
        errdefer gpa.free(path);
        const features = try dupeStrings(gpa, self.features);
        errdefer freeStrings(gpa, features);
        return .{
            .id = id,
            .plugin_id = plugin_id,
            .name = name,
            .vendor = vendor,
            .version = version,
            .description = description,
            .features = features,
            .category = self.category,
            .is_instrument = self.is_instrument,
            .path = path,
        };
    }
};

/// Frees a list returned by the registry (every descriptor, then the slice). `gpa` must be the
/// allocator the list was returned for.
pub fn freeDescriptors(gpa: Allocator, list: []ClapDescriptor) void {
    for (list) |*d| d.deinit(gpa);
    gpa.free(list);
}

/// A NUL-terminated copy of `s`, owned by `gpa` (free it with `gpa.free`).
pub fn dupeZ(gpa: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    const z = try gpa.allocSentinel(u8, s.len, 0);
    @memcpy(z, s);
    return z;
}

/// Deep copy of a list of strings (free with `freeStrings`).
pub fn dupeStrings(gpa: Allocator, src: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, src.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (src, 0..) |s, i| {
        out[i] = try gpa.dupe(u8, s);
        made = i + 1;
    }
    return out;
}

/// Frees a list from `dupeStrings`, and every string in it.
pub fn freeStrings(gpa: Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// Creates a plugin by `clap:<id>` on the process registry, prepared for 48 kHz stereo with
/// 1024-frame blocks. Destroy it with `ClapPlugin.destroy`.
pub fn instantiate(io: Io, id: []const u8) ClapError!*ClapPlugin {
    return registry.global.instantiate(io, id);
}

/// Creates a plugin by `clap:<id>`; `null` if the id is not a CLAP id, unknown, or it fails.
pub fn create(io: Io, id: []const u8) ?*ClapPlugin {
    return registry.global.create(io, id);
}

/// The description of a `clap:<id>` plugin, or `null`. The first call for a plugin type creates
/// one instance to read its parameters; the result is cached for the life of the process.
pub fn pluginInfo(io: Io, id: []const u8) ?*const PluginInfo {
    return registry.global.pluginInfo(io, id);
}

fn testIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

test {
    // Pulls in the test blocks of the registry, which the other tests reach only indirectly.
    _ = registry;
}

test "clap: ids_parse" {
    try testing.expectEqualStrings("com.u-he.diva", parseId("clap:com.u-he.diva").?);
    try testing.expect(parseId("clap:") == null);
    try testing.expect(parseId("eq_7band") == null);
    try testing.expect(parseId("CLAP:x") == null);
    try testing.expect(parseId("clap:a\x00b") == null);
}

test "clap: non_clap_ids_are_rejected_without_scanning" {
    const io = testIo();
    try testing.expect(create(io, "eq_7band") == null);
    try testing.expect(pluginInfo(io, "reverb") == null);
}

fn expectLoadFails(io: Io, path: []const u8) !void {
    const got = registry.global.loadBundle(io, testing.allocator, path);
    if (got) |list| {
        freeDescriptors(testing.allocator, list);
        return error.ExpectedLoadFailure;
    } else |_| {}
}

fn expectInstantiateFails(io: Io, id: []const u8) !void {
    if (instantiate(io, id)) |p| {
        p.destroy();
        return error.ExpectedInstantiateFailure;
    } else |_| {}
}

test "clap: garbage_files_are_errors_not_crashes" {
    const io = testIo();
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Bundle.clap/Contents/MacOS");
    try tmp.dir.writeFile(io, .{ .sub_path = "garbage.clap", .data = "\x7fELF this is not a plugin \x00\x01\x02" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.clap", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Bundle.clap/Contents/MacOS/Bundle", .data = &.{ 0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3 } });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    for ([_][]const u8{ "garbage.clap", "empty.clap", "Bundle.clap", "missing.clap" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(path);
        try expectLoadFails(io, path);
    }

    const found = try registry.global.scanPaths(io, gpa, &.{dir});
    defer freeDescriptors(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);
    try testing.expect(create(io, "clap:does.not.exist") == null);
    try testing.expect(pluginInfo(io, "clap:does.not.exist") == null);
    try expectInstantiateFails(io, "clap:does.not.exist");
}

test "clap: ClapDescriptor.clone owns its strings" {
    const gpa = testing.allocator;
    const features = [_][]const u8{ "audio-effect", "eq" };
    var src: ClapDescriptor = .{
        .id = "clap:x.y",
        .plugin_id = "x.y",
        .name = "Y",
        .vendor = "V",
        .version = "1",
        .description = "d",
        .features = &features,
        .category = .eq,
        .is_instrument = false,
        .path = "/p",
    };
    const copy = try src.clone(gpa);
    var owned = copy;
    defer owned.deinit(gpa);
    try testing.expectEqualStrings("clap:x.y", owned.id);
    try testing.expectEqualStrings("eq", owned.features[1]);
    try testing.expect(owned.id.ptr != src.id.ptr);
    try testing.expectEqual(Category.eq, owned.category);
    src.is_instrument = true;
    try testing.expect(!owned.is_instrument);
}
