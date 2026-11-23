// Translated to Zig from soundcraft/crates/clap-host/src/ffi/bundle.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Loading a CLAP binary and reading its plugin factory.
//!
//! Path-independent loading only. `openLibrary` takes the executable file itself.
//! Resolving a macOS `.clap` bundle to `Contents/MacOS/<exe>` belongs to the scan
//! step (clap-4), which hands this file the path.
//!
//! The test seam is `Bundle.fromEntry`: it runs `clap_plugin_entry.init` on any
//! entry pointer, so a test can register an in-process fixture entry without a
//! dylib.
//!
//! Control thread only: opening, init, descriptor reads and deinit never run on
//! the audio thread.
//!
//! Differences from ffi/bundle.rs, all deliberate:
//! - No process-wide cache of loaded binaries. The Rust code keeps each bundle
//!   mapped for the life of the process so no instance outlives its code. Here
//!   the owner of the `Bundle` (the registry) keeps that policy, and must not
//!   call `deinit` while an instance of the bundle is alive.
//! - The `clap_entry` symbol is the entry struct itself (the CLAP header declares
//!   `const clap_plugin_entry clap_entry`), so the dlsym address is used
//!   directly. The Rust code does the same: libloading's `*sym` for a
//!   `Symbol<*const T>` is the dlsym address itself, not a second dereference.
//! - Descriptors are written into a caller buffer. The strings borrow the
//!   plugin's memory, so nothing is allocated.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const abi = @import("abi.zig");

pub const LoadError = error{
    PathContainsNul,
    LoadFailed,
    NotAClapPlugin,
    UnsupportedVersion,
    IncompleteEntry,
    InitFailed,
    NoFactory,
};

const RTLD_NOW: c_int = 2;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: ?*anyopaque) c_int;

fn closeHandle(handle: *anyopaque) void {
    _ = dlclose(handle);
}

/// An open dynamic library and its exported `clap_entry`. Close it with `close`
/// unless it was handed to a `Bundle`.
pub const Library = struct {
    handle: *anyopaque,
    entry: *const abi.ClapPluginEntry,

    pub fn close(self: Library) void {
        closeHandle(self.handle);
    }
};

/// Opens a CLAP binary and finds its `clap_entry`. Nothing is initialised here;
/// `Bundle.fromEntry` does that. Loading runs the library's static initialisers,
/// which is inherent to hosting plugins: load only binaries the user chose or
/// found in a CLAP plugin folder.
pub fn openLibrary(path: [:0]const u8) LoadError!Library {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.PathContainsNul;
    const handle = dlopen(path.ptr, RTLD_NOW) orelse return error.LoadFailed;
    errdefer closeHandle(handle);
    const sym = dlsym(handle, "clap_entry") orelse return error.NotAClapPlugin;
    const entry: *const abi.ClapPluginEntry = @ptrCast(@alignCast(sym));
    return .{ .handle = handle, .entry = entry };
}

/// A plugin descriptor as the factory reports it. The strings borrow the plugin's
/// memory and are valid until the owning `Bundle` is deinitialised.
pub const RawDescriptor = struct {
    id: []const u8,
    name: []const u8,
    vendor: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    features: [abi.MAX_FEATURES][]const u8 = undefined,
    feature_count: usize = 0,

    pub fn featureList(self: *const RawDescriptor) []const []const u8 {
        return self.features[0..self.feature_count];
    }
};

/// Reads one descriptor. A missing or empty id gives null (skipped). A missing
/// name falls back to the id, and any other missing string is empty.
fn readDescriptor(d: abi.ClapPluginDescriptor) ?RawDescriptor {
    const id = abi.readCStr(d.id) orelse return null;
    if (id.len == 0) return null;
    var out: RawDescriptor = .{
        .id = id,
        .name = abi.readCStr(d.name) orelse id,
        .vendor = abi.readCStr(d.vendor) orelse "",
        .version = abi.readCStr(d.version) orelse "",
        .description = abi.readCStr(d.description) orelse "",
    };
    if (d.features) |list| {
        // The array is NULL-terminated; the cap bounds a plugin that never terminates it.
        var k: usize = 0;
        while (k < abi.MAX_FEATURES) : (k += 1) {
            const p = list[k] orelse break;
            if (abi.readCStr(p)) |s| {
                out.features[out.feature_count] = s;
                out.feature_count += 1;
            }
        }
    }
    return out;
}

/// A loaded, initialised CLAP entry and its plugin factory. The factory pointer
/// is valid while the entry is initialised (until `deinit`).
pub const Bundle = struct {
    entry: *const abi.ClapPluginEntry,
    factory: *const abi.ClapPluginFactory,
    /// The dlopen handle, or null for an entry registered in-process.
    handle: ?*anyopaque = null,

    /// Opens and initialises a `.clap` binary: `openLibrary`, then `fromEntry`.
    pub fn open(path: [:0]const u8) LoadError!Bundle {
        const lib = try openLibrary(path);
        errdefer lib.close();
        var b = try fromEntry(lib.entry, path);
        b.handle = lib.handle;
        return b;
    }

    /// Checks the entry's version and that `init` and `get_factory` are present,
    /// then runs `init(plugin_path)` and reads the factory. If `init` succeeded but
    /// no factory came back, `deinit` runs before the error returns.
    ///
    /// This is the in-process seam: a test passes an entry struct it built itself,
    /// with `""` for the path when the fixture does not need one.
    pub fn fromEntry(entry: *const abi.ClapPluginEntry, plugin_path: [:0]const u8) LoadError!Bundle {
        const e = entry.*;
        if (!abi.clapVersionIsCompatible(e.clap_version)) return error.UnsupportedVersion;
        const init_fn = e.init orelse return error.IncompleteEntry;
        const get_factory = e.get_factory orelse return error.IncompleteEntry;
        if (!init_fn(plugin_path.ptr)) return error.InitFailed;
        const raw = get_factory(abi.CLAP_PLUGIN_FACTORY_ID.ptr) orelse {
            if (e.deinit) |deinit_fn| deinit_fn();
            return error.NoFactory;
        };
        return .{ .entry = entry, .factory = @ptrCast(@alignCast(raw)) };
    }

    /// Calls the entry's `deinit` (balancing the successful init) and closes the
    /// library. Call it only when no instance of this bundle is still alive.
    pub fn deinit(self: *Bundle) void {
        if (self.entry.deinit) |deinit_fn| deinit_fn();
        if (self.handle) |h| closeHandle(h);
        self.handle = null;
    }

    /// Writes the plugins this binary provides into `out` and returns how many were
    /// written. At most `MAX_PLUGINS_PER_FACTORY` ids are read from the factory, and
    /// at most `out.len` descriptors are written. Null or invalid descriptors are
    /// skipped and do not use a slot. Control thread only.
    pub fn descriptors(self: *const Bundle, out: []RawDescriptor) usize {
        const f = self.factory;
        const count_fn = f.get_plugin_count orelse return 0;
        const get_fn = f.get_plugin_descriptor orelse return 0;
        const n: u32 = @min(count_fn(f), abi.MAX_PLUGINS_PER_FACTORY);
        var written: usize = 0;
        var i: u32 = 0;
        while (i < n and written < out.len) : (i += 1) {
            const d_ptr = get_fn(f, i) orelse continue;
            if (readDescriptor(d_ptr.*)) |d| {
                out[written] = d;
                written += 1;
            }
        }
        return written;
    }
};

// ---- tests -----------------------------------------------------------------------------------

/// An in-process fixture entry: no dylib, just function pointers and counters.
const Fixture = struct {
    var init_calls: u32 = 0;
    var deinit_calls: u32 = 0;

    fn reset() void {
        init_calls = 0;
        deinit_calls = 0;
    }

    fn init(path: [*:0]const u8) callconv(.c) bool {
        _ = path;
        init_calls += 1;
        return true;
    }

    fn failingInit(path: [*:0]const u8) callconv(.c) bool {
        _ = path;
        init_calls += 1;
        return false;
    }

    fn deinit() callconv(.c) void {
        deinit_calls += 1;
    }

    fn getFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        if (!std.mem.eql(u8, std.mem.span(factory_id), "clap.plugin-factory")) return null;
        return &factory;
    }

    fn noFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
        _ = factory_id;
        return null;
    }

    fn pluginCount(f: *const abi.ClapPluginFactory) callconv(.c) u32 {
        _ = f;
        // Four slots: a valid plugin, a null slot, a plugin with a null name, and one with an empty id.
        return 4;
    }

    fn pluginDescriptor(f: *const abi.ClapPluginFactory, index: u32) callconv(.c) ?*const abi.ClapPluginDescriptor {
        _ = f;
        return switch (index) {
            0 => &desc_a,
            2 => &desc_b,
            3 => &desc_empty_id,
            else => null,
        };
    }

    fn createPlugin(f: *const abi.ClapPluginFactory, host: *const abi.ClapHost, plugin_id: [*:0]const u8) callconv(.c) ?*const abi.ClapPlugin {
        _ = f;
        _ = host;
        _ = plugin_id;
        return null;
    }

    const factory: abi.ClapPluginFactory = .{
        .get_plugin_count = pluginCount,
        .get_plugin_descriptor = pluginDescriptor,
        .create_plugin = createPlugin,
    };

    const features_a = [_:null]?[*:0]const u8{ "audio-effect", "eq", null };

    const desc_a: abi.ClapPluginDescriptor = .{
        .clap_version = abi.CLAP_VERSION,
        .id = "soundcraft.test.alpha",
        .name = "Alpha",
        .vendor = "Seridian",
        .url = null,
        .manual_url = null,
        .support_url = null,
        .version = "1.0",
        .description = "fixture",
        .features = &features_a,
    };

    const desc_b: abi.ClapPluginDescriptor = .{
        .clap_version = abi.CLAP_VERSION,
        .id = "soundcraft.test.beta",
        .name = null,
        .vendor = null,
        .url = null,
        .manual_url = null,
        .support_url = null,
        .version = null,
        .description = null,
        .features = null,
    };

    const desc_empty_id: abi.ClapPluginDescriptor = .{
        .clap_version = abi.CLAP_VERSION,
        .id = "",
        .name = "Nameless",
        .vendor = null,
        .url = null,
        .manual_url = null,
        .support_url = null,
        .version = null,
        .description = null,
        .features = null,
    };

    const entry: abi.ClapPluginEntry = .{
        .clap_version = abi.CLAP_VERSION,
        .init = init,
        .deinit = deinit,
        .get_factory = getFactory,
    };
};

test "Bundle.fromEntry runs init and lists the valid descriptors" {
    Fixture.reset();
    var b = try Bundle.fromEntry(&Fixture.entry, "");
    defer b.deinit();
    try testing.expectEqual(@as(u32, 1), Fixture.init_calls);

    var buf: [8]RawDescriptor = undefined;
    const n = b.descriptors(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("soundcraft.test.alpha", buf[0].id);
    try testing.expectEqualStrings("Alpha", buf[0].name);
    try testing.expectEqualStrings("Seridian", buf[0].vendor);
    try testing.expectEqual(@as(usize, 2), buf[0].featureList().len);
    try testing.expectEqualStrings("eq", buf[0].featureList()[1]);
    try testing.expectEqualStrings("soundcraft.test.beta", buf[1].id);
    try testing.expectEqualStrings("soundcraft.test.beta", buf[1].name);
    try testing.expectEqualStrings("", buf[1].vendor);
    try testing.expectEqual(@as(usize, 0), buf[1].feature_count);
}

test "Bundle.descriptors stops at the caller's buffer" {
    Fixture.reset();
    var b = try Bundle.fromEntry(&Fixture.entry, "");
    defer b.deinit();
    var one: [1]RawDescriptor = undefined;
    try testing.expectEqual(@as(usize, 1), b.descriptors(&one));
    try testing.expectEqualStrings("soundcraft.test.alpha", one[0].id);
}

test "Bundle.deinit calls the entry deinit exactly once" {
    Fixture.reset();
    var b = try Bundle.fromEntry(&Fixture.entry, "");
    b.deinit();
    try testing.expectEqual(@as(u32, 1), Fixture.deinit_calls);
}

test "Bundle.fromEntry rejects an incompatible CLAP version before init" {
    Fixture.reset();
    var old: abi.ClapPluginEntry = Fixture.entry;
    old.clap_version = .{ .major = 0, .minor = 9, .revision = 0 };
    try testing.expectError(error.UnsupportedVersion, Bundle.fromEntry(&old, ""));
    try testing.expectEqual(@as(u32, 0), Fixture.init_calls);
}

test "Bundle.fromEntry reports a failed init without calling deinit" {
    Fixture.reset();
    var refused: abi.ClapPluginEntry = Fixture.entry;
    refused.init = Fixture.failingInit;
    try testing.expectError(error.InitFailed, Bundle.fromEntry(&refused, ""));
    try testing.expectEqual(@as(u32, 1), Fixture.init_calls);
    try testing.expectEqual(@as(u32, 0), Fixture.deinit_calls);
}

test "Bundle.fromEntry deinitialises when the factory is missing" {
    Fixture.reset();
    var no_factory: abi.ClapPluginEntry = Fixture.entry;
    no_factory.get_factory = Fixture.noFactory;
    try testing.expectError(error.NoFactory, Bundle.fromEntry(&no_factory, ""));
    try testing.expectEqual(@as(u32, 1), Fixture.deinit_calls);
}

test "Bundle.fromEntry rejects an entry without init or get_factory" {
    Fixture.reset();
    var bare: abi.ClapPluginEntry = Fixture.entry;
    bare.init = null;
    try testing.expectError(error.IncompleteEntry, Bundle.fromEntry(&bare, ""));
    try testing.expectEqual(@as(u32, 0), Fixture.init_calls);
}

test "openLibrary reports a missing file as LoadFailed" {
    try testing.expectError(error.LoadFailed, openLibrary("/nonexistent/soundcraft/none.clap"));
}

test "openLibrary rejects a path with an interior NUL" {
    const p: [:0]const u8 = "/usr/lib\x00/x";
    try testing.expectError(error.PathContainsNul, openLibrary(p));
}

test "openLibrary of a system library without clap_entry is NotAClapPlugin" {
    const name: [:0]const u8 = if (builtin.os.tag == .macos) "/usr/lib/libSystem.B.dylib" else "libc.so.6";
    try testing.expectError(error.NotAClapPlugin, openLibrary(name));
}
