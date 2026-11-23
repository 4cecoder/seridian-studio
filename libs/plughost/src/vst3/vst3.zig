// Translated to Zig from soundcraft/crates/vst3-host/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! SoundCraft's VST3 plugin host: the namespace file of the `vst3` directory.
//!
//! Scans the standard VST3 folders (plus `VST3_PATH`), loads `.vst3` bundles in-process and
//! exposes each "Audio Module Class" as a plug-0 `Plugin`, so the mix engine treats third-party
//! plugins exactly like the built-in ones. Plugin ids are `vst3:<class id hex>` (32 upper-case
//! hex digits of the component's class id); parameter ids are VST3 `ParamID`s as decimal
//! strings, with titles, units and plain ranges from the edit controller in `PluginInfo.params`.
//! Values are plain (display) values; the host converts to and from the VST3 normalized 0..1
//! values. Stepped parameters become toggles or choices.
//!
//! Isolation. The Rust crate denies `unsafe` everywhere except its private `ffi` module and
//! has a stub for `wasm32`. Here the COM and `dlopen` code lives in the `vst3/*.zig` files and
//! this namespace exposes the safe surface: every function returns an error set or an optional
//! and never panics on plugin behaviour. Limits of in-process hosting: a plugin that crashes
//! (segfault) takes the process down with it; native code cannot be sandboxed here.
//!
//! `PluginInfo` must stay valid for the life of the process: the registry keeps exactly one
//! `PluginInfo` (with its param table) per plugin class the first time that class is
//! instantiated, in an arena it owns. Loaded binaries likewise stay mapped for the life of the
//! process (module exit functions run only through `shutdownPluginHosts`).
//!
//! Not hosted (as in the Rust crate): `IMessage` creation through the host, sidechain (aux
//! buses are kept inactive), 64-bit processing, and Linux (X11) editor windows.
//! Differences from the Rust crate, all deliberate:
//! * Functions that return owned data take the allocator that owns the result (`gpa`).
//! * Errors are the error set `Error`. The Rust variants that carried a string are logged
//!   with `std.log` at the point of failure instead of being attached to the error.
//! * `Vst3Error::Process` is not here: the processing errors belong to `instance.zig`.
//! * `create` and `instantiate` both return the concrete `*Vst3Plugin` (the Rust crate returned
//!   `Box<dyn Plugin>` and had a separate `instantiate_plugin`). Free it with `destroyPlugin`.

const std = @import("std");
const builtin = @import("builtin");
const plug = @import("../plugin.zig");

pub const module = @import("module.zig");
pub const host = @import("host.zig");
pub const process = @import("process.zig");
pub const instance = @import("instance.zig");
pub const editor = @import("editor.zig");
pub const window = if (builtin.os.tag == .macos) @import("window_macos.zig") else @import("window_other.zig");
pub const scan = @import("scan.zig");
pub const plugin = @import("plugin.zig");
pub const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const Vst3Plugin = plugin.Vst3Plugin;
const PluginInfo = plug.PluginInfo;

pub const abi = @import("abi.zig");

/// Prefix of every hosted-VST3 plugin id.
pub const ID_PREFIX: []const u8 = "vst3:";

/// The factory class category of audio processors (the only classes SoundCraft lists).
pub const AUDIO_MODULE_CLASS: []const u8 = "Audio Module Class";

/// Why a VST3 operation failed. The Rust variants carried a message; the reason is logged
/// where it happened.
pub const Error = error{
    /// No plugin with that id is known (also for ids that do not parse).
    NotFound,
    /// The bundle could not be loaded (missing binary, `dlopen` failure, not a VST3 module).
    Load,
    /// The class could not be created or set up, or it failed earlier and is not retried.
    Instantiate,
    /// Plugin hosting is not available on this platform (Windows, for now).
    Unsupported,
    OutOfMemory,
};

/// The 16-byte class id inside a `vst3:<32 hex digits>` SoundCraft id (`null` for other ids).
/// Accepts upper- and lower-case digits, and a leading `+` in each byte (as Rust's
/// `u8::from_str_radix` does).
pub fn parseId(id: []const u8) ?[16]u8 {
    if (!std.mem.startsWith(u8, id, ID_PREFIX)) return null;
    const hex = id[ID_PREFIX.len..];
    if (hex.len != 32) return null;
    for (hex) |c| {
        if (!std.ascii.isAscii(c)) return null;
    }
    var out: [16]u8 = undefined;
    for (&out, 0..) |*o, i| {
        o.* = hexPair(hex[i * 2 .. i * 2 + 2]) orelse return null;
    }
    return out;
}

/// One byte from two hex digits, with an optional leading `+`.
fn hexPair(pair: []const u8) ?u8 {
    var s = pair;
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len == 0) return null;
    var v: u8 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        v = v * 16 + d;
    }
    return v;
}

/// One plugin found by a scan. Every string and the sub-category list are owned: free them
/// with `deinit` (or a whole list with `freeList`).
pub const Descriptor = struct {
    /// SoundCraft id: `vst3:<class_id>`.
    id: []u8,
    /// The component's class id as 32 upper-case hex digits.
    class_id: []u8,
    name: []u8,
    vendor: []u8,
    version: []u8,
    /// The VST3 SDK version the plugin was built with (when reported).
    sdk_version: []u8,
    /// The `|`-separated sub-categories, split (`["Fx", "Reverb"]`).
    sub_categories: []const []const u8,
    category: plug.Category,
    is_instrument: bool,
    /// The `.vst3` bundle or file it lives in.
    path: []u8,

    /// Frees every string of this descriptor.
    pub fn deinit(self: *Descriptor, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.class_id);
        gpa.free(self.name);
        gpa.free(self.vendor);
        gpa.free(self.version);
        gpa.free(self.sdk_version);
        for (self.sub_categories) |s| gpa.free(s);
        gpa.free(self.sub_categories);
        gpa.free(self.path);
        self.* = undefined;
    }

    /// A deep copy, owned by `gpa`. Frees everything again on failure.
    pub fn clone(self: *const Descriptor, gpa: Allocator) Allocator.Error!Descriptor {
        var d: Descriptor = .{
            .id = &.{},
            .class_id = &.{},
            .name = &.{},
            .vendor = &.{},
            .version = &.{},
            .sdk_version = &.{},
            .sub_categories = &.{},
            .category = self.category,
            .is_instrument = self.is_instrument,
            .path = &.{},
        };
        errdefer d.deinit(gpa);
        d.id = try gpa.dupe(u8, self.id);
        d.class_id = try gpa.dupe(u8, self.class_id);
        d.name = try gpa.dupe(u8, self.name);
        d.vendor = try gpa.dupe(u8, self.vendor);
        d.version = try gpa.dupe(u8, self.version);
        d.sdk_version = try gpa.dupe(u8, self.sdk_version);
        d.path = try gpa.dupe(u8, self.path);
        const subs = try gpa.alloc([]const u8, self.sub_categories.len);
        var n: usize = 0;
        errdefer {
            for (subs[0..n]) |s| gpa.free(s);
            gpa.free(subs);
        }
        for (self.sub_categories) |s| {
            subs[n] = try gpa.dupe(u8, s);
            n += 1;
        }
        d.sub_categories = subs;
        return d;
    }

    /// Frees a list returned by one of the functions below, and the list itself.
    pub fn freeList(gpa: Allocator, list: []Descriptor) void {
        for (list) |*d| d.deinit(gpa);
        gpa.free(list);
    }
};

/// The descriptor of a class with its strings copied out of `c` (not owned by it).
pub fn descriptorFromClass(gpa: Allocator, c: *const module.RawClass, path: []const u8) Allocator.Error!Descriptor {
    const class_hex = abi.hex(&c.cid);
    var d: Descriptor = .{
        .id = &.{},
        .class_id = &.{},
        .name = &.{},
        .vendor = &.{},
        .version = &.{},
        .sdk_version = &.{},
        .sub_categories = &.{},
        .category = .other,
        .is_instrument = false,
        .path = &.{},
    };
    errdefer d.deinit(gpa);
    d.class_id = try gpa.dupe(u8, &class_hex);
    d.id = try std.fmt.allocPrint(gpa, "{s}{s}", .{ ID_PREFIX, d.class_id });
    const name_src: []const u8 = if (c.name.len == 0) "VST3 plugin" else c.name;
    d.name = try gpa.dupe(u8, name_src);
    d.vendor = try gpa.dupe(u8, c.vendor);
    d.version = try gpa.dupe(u8, c.version);
    d.sdk_version = try gpa.dupe(u8, c.sdk_version);
    d.path = try gpa.dupe(u8, path);
    // The split strings and the list move into `d` (freed by `deinit`).
    const subs = try scan.splitSubCategories(gpa, c.sub_categories);
    d.sub_categories = subs;
    d.category = scan.categoryFromSubCategories(subs);
    d.is_instrument = scan.isInstrument(subs);
    return d;
}

/// Plugin hosting entry points. The process-wide registry (scan cache, instance cache and the
/// in-process factories) is behind these; see `registry.zig`.
pub const Registry = registry.Registry;

/// Every plugin in the standard VST3 folders, `VST3_PATH` and folders added with
/// `addSearchDir`. Scanned on first call (loads each binary and reads its factory, but creates
/// no plugin instances), then cached in memory. The caller frees the result with
/// `Descriptor.freeList`.
pub fn scanAll(gpa: Allocator) Error![]Descriptor {
    return registry.globalRegistry().scan(gpa);
}

/// Forgets the cached scan (and remembered failures) and scans again.
pub fn rescan(gpa: Allocator) Error![]Descriptor {
    return registry.globalRegistry().rescan(gpa);
}

/// Adds a folder to the search path and merges its plugins into the cache. Returns how many
/// plugins the folder holds.
pub fn addSearchDir(dir: []const u8) Error!usize {
    return registry.globalRegistry().addSearchDir(dir);
}

/// Scans the given folders without touching the cache. Free the result with `Descriptor.freeList`.
pub fn scanPaths(gpa: Allocator, dirs: []const []const u8) Error![]Descriptor {
    return registry.scanPaths(gpa, dirs);
}

/// The plugins of the last scan, without scanning: `null` until something has scanned.
/// Free the result with `Descriptor.freeList`.
pub fn cached(gpa: Allocator) Error!?[]Descriptor {
    return registry.globalRegistry().cached(gpa);
}

/// Shuts plugin hosting down: runs the module exit of every loaded binary that has no live
/// instance left, each on the thread that loaded it; later loads fail. Call it on the main
/// thread once the plugin instances are gone, before the process exits. Without it the exits
/// run from an exit handler, by which time some plugins have already torn down state they need
/// (HALion Sonic crashes in its module exit after it has been used). The engine calls this from
/// its own shutdown (the Rust engine's `shutdown_plugin_hosts`).
pub fn shutdownPluginHosts() void {
    module.exitModules();
}

/// The audio module classes in one `.vst3` bundle or file. Free the result with `Descriptor.freeList`.
pub fn loadBundle(gpa: Allocator, path: []const u8) Error![]Descriptor {
    return registry.loadDescriptors(gpa, path);
}

/// Creates a plugin by `vst3:<class id>`, prepared for 48 kHz stereo with 1024-frame blocks
/// (like `soundcraft_dsp::create`), with the reason logged when it fails. The caller frees it
/// with `destroyPlugin`.
pub fn instantiate(gpa: Allocator, id: []const u8) Error!*Vst3Plugin {
    return registry.globalRegistry().instantiate(gpa, id);
}

/// Creates a plugin by `vst3:<class id>`; `null` if unknown or it fails to load. The caller
/// frees it with `destroyPlugin`.
pub fn create(gpa: Allocator, id: []const u8) ?*Vst3Plugin {
    if (parseId(id) == null) return null;
    return instantiate(gpa, id) catch |e| {
        std.log.scoped(.plughost_vst3).warn("cannot create {s}: {s}", .{ id, @errorName(e) });
        return null;
    };
}

/// Destroys a plugin made by `create` or `instantiate`: the instance first, then the memory.
/// Control thread.
pub fn destroyPlugin(p: *Vst3Plugin) void {
    const gpa = p.gpa;
    p.deinit();
    gpa.destroy(p);
}

/// The description of a `vst3:<class id>` plugin. The first call for a class instantiates it
/// once to read its parameters; the result is cached for the life of the process.
pub fn pluginInfo(id: []const u8) ?*const PluginInfo {
    return registry.globalRegistry().pluginInfo(id);
}

/// Registers an in-process factory as the bundle `path`, as if the file had been loaded from
/// disk: `Bundle.create` and `loadBundle` then see it, and its classes join the scan cache. This
/// is the test seam for fixtures written in Zig (no binary is loaded). The registry takes over
/// `factory`'s reference and runs `exit_fn` (if given) at `shutdownPluginHosts`. `path` must not
/// name a bundle that is already loaded.
pub fn registerFactory(path: []const u8, factory: *abi.IPluginFactory, exit_fn: ?module.ModuleExit) Error!void {
    return registry.globalRegistry().registerFactory(path, factory, exit_fn);
}

test {
    std.testing.refAllDecls(@This());
}

// ---- tests (ported from lib.rs) -----------------------------------------------------------

const testing = std.testing;

test "ids_parse" {
    const id = "vst3:0123456789ABCDEFfedcba9876543210";
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 }, &parseId(id).?);
    try testing.expect(parseId("vst3:") == null);
    try testing.expect(parseId("vst3:0123") == null);
    try testing.expect(parseId("vst3:0123456789ABCDEF0123456789ABCDEG") == null);
    try testing.expect(parseId("vst3:ééééééééééééééééé") == null);
    try testing.expect(parseId("VST3:0123456789ABCDEF0123456789ABCDEF") == null);
    try testing.expect(parseId("clap:x") == null);
    try testing.expect(parseId("eq_7band") == null);
}

test "non_vst3_ids_are_rejected_without_scanning" {
    const gpa = testing.allocator;
    try testing.expect(create(gpa, "eq_7band") == null);
    try testing.expect(create(gpa, "clap:com.x") == null);
    try testing.expect(pluginInfo("reverb") == null);
}

/// A fresh empty scratch directory (absolute path, caller frees) under the system tmp dir.
fn scratchDir(name: []const u8) ![]u8 {
    const io = registry.globalRegistry().io;
    const d = try std.fmt.allocPrint(testing.allocator, "/tmp/seridian-vst3-{s}-{d}", .{ name, std.c.getpid() });
    errdefer testing.allocator.free(d);
    std.Io.Dir.cwd().deleteTree(io, d) catch {};
    try std.Io.Dir.cwd().createDirPath(io, d);
    return d;
}

fn joinPath(gpa: Allocator, root: []const u8, sub: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
}

fn writeScratchFile(root: []const u8, sub: []const u8, bytes: []const u8) !void {
    const io = registry.globalRegistry().io;
    const p = try joinPath(testing.allocator, root, sub);
    defer testing.allocator.free(p);
    const f = try std.Io.Dir.cwd().createFile(io, p, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "garbage_files_are_errors_not_crashes" {
    const gpa = testing.allocator;
    const io = registry.globalRegistry().io;
    const d = try scratchDir("garbage");
    defer {
        std.Io.Dir.cwd().deleteTree(io, d) catch {};
        gpa.free(d);
    }
    const arch: []const u8 = switch (builtin.os.tag) {
        .macos => "MacOS",
        .windows => "x86_64-win",
        else => "x86_64-linux",
    };
    const exe: []const u8 = switch (builtin.os.tag) {
        .macos => "Bundle",
        .windows => "Bundle.vst3",
        else => "Bundle.so",
    };
    try writeScratchFile(d, "garbage.vst3", "\x7fELF this is not a plugin \x00\x01\x02");
    try writeScratchFile(d, "empty.vst3", "");
    const contents = try joinPath(gpa, d, "Bundle.vst3/Contents");
    defer gpa.free(contents);
    const arch_dir = try joinPath(gpa, contents, arch);
    defer gpa.free(arch_dir);
    try std.Io.Dir.cwd().createDirPath(io, arch_dir);
    const bin_sub = try std.fmt.allocPrint(gpa, "Bundle.vst3/Contents/{s}/{s}", .{ arch, exe });
    defer gpa.free(bin_sub);
    try writeScratchFile(d, bin_sub, &.{ 0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3 });
    const nobin = try joinPath(gpa, d, "NoBinary.vst3/Contents");
    defer gpa.free(nobin);
    try std.Io.Dir.cwd().createDirPath(io, nobin);

    for ([_][]const u8{ "garbage.vst3", "empty.vst3", "Bundle.vst3", "NoBinary.vst3", "missing.vst3" }) |f| {
        const p = try joinPath(gpa, d, f);
        defer gpa.free(p);
        const r = loadBundle(gpa, p);
        try testing.expectError(error.Load, r);
    }

    const dirs = [_][]const u8{d};
    const found = try scanPaths(gpa, &dirs);
    defer Descriptor.freeList(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);

    const missing = "vst3:00000000000000000000000000000000";
    try testing.expect(create(gpa, missing) == null);
    try testing.expect(pluginInfo(missing) == null);
    try testing.expectError(error.NotFound, instantiate(gpa, missing));
}

test "a_real_library_without_the_vst3_export_is_rejected" {
    // Unix only: the test points a ".vst3" at a system library through a symlink. macOS system
    // libraries exist only in the dyld shared cache, so there is nothing to point at (skipped,
    // where the Rust test passed without checking anything).
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = registry.globalRegistry().io;
    const candidates = [_][]const u8{ "/lib/x86_64-linux-gnu/libz.so.1", "/usr/lib/libz.so.1", "/lib64/libz.so.1" };
    var lib: ?[]const u8 = null;
    for (candidates) |c| {
        std.Io.Dir.cwd().access(io, c, .{}) catch continue;
        lib = c;
        break;
    }
    const target = lib orelse return error.SkipZigTest;
    const d = try scratchDir("nolib");
    defer {
        std.Io.Dir.cwd().deleteTree(io, d) catch {};
        testing.allocator.free(d);
    }
    const link = try joinPath(testing.allocator, d, "z.vst3");
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(io, target, link, .{});
    try testing.expectError(error.Load, loadBundle(testing.allocator, link));
}
