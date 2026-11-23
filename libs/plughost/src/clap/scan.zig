// Translated to Zig from soundcraft/crates/clap-host/src/scan.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Finding CLAP plugins on disk, and mapping CLAP features to insert categories.
//!
//! Control thread only: the scanner touches the file system and allocates. Nothing
//! here loads a plugin binary. `bundle.zig` does that, and a junk or truncated file
//! is rejected there, so the scanner only decides which paths to try.
//!
//! Differences from scan.rs, all deliberate:
//! - Paths are owned `[]u8` slices from the caller's allocator; free a result with
//!   `freePaths`. Inputs are `[]const u8`.
//! - The environment is passed in as `Env`, so the OS branches are pure functions
//!   that tests drive with injected values. `envFromProcess` reads the real one
//!   through libc `getenv`.
//! - The file system is reached through the `std.Io` the caller passes in. The
//!   library never picks up a process-wide `Io` itself.
//! - Symbolic links are followed, as in Rust. A directory whose inode was already
//!   entered in this scan is not walked again, so a link loop ends at once. (The
//!   key is the inode alone: `std.Io.File.Stat` has no device number.)
//! - The sorted result uses Rust's `Path` order, component by component, so
//!   `a/b` sorts before `a.clap`.
//! - `bundleExecutable` and `findBundles` skip unreadable entries silently, as the
//!   Rust `flatten()` did. Allocation failure is the only error they return.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const plugin_mod = @import("../plugin.zig");
const bundle = @import("bundle.zig");

/// The insert-menu category a plugin is filed under.
pub const Category = plugin_mod.Category;

/// Directory recursion limit while scanning (CLAP folders may be nested, never deeply).
pub const MAX_DEPTH: usize = 8;
/// Upper bound on bundles collected by one scan (hostile or huge folders).
pub const MAX_BUNDLES: usize = 4096;
/// Upper bound on directory entries visited by one scan.
pub const MAX_ENTRIES: usize = 100_000;
/// Files a bundle's `Contents/MacOS` is read for when no executable has the bundle's name.
pub const MAX_FALLBACK_FILES: usize = 64;

/// The separator `CLAP_PATH` entries are split on (`std::env::split_paths`).
const PATH_LIST_DELIMITER: u8 = if (builtin.os.tag == .windows) ';' else ':';

/// Environment values the search paths depend on. Null when the variable is unset.
pub const Env = struct {
    home: ?[]const u8 = null,
    common_program_files: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    clap_path: ?[]const u8 = null,
};

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Reads the four variables from the process environment through libc. Control thread
/// only (libc's `getenv` is not safe against a concurrent `setenv`).
pub fn envFromProcess() Env {
    return .{
        .home = envValue("HOME"),
        .common_program_files = envValue("COMMONPROGRAMFILES"),
        .local_app_data = envValue("LOCALAPPDATA"),
        .clap_path = envValue("CLAP_PATH"),
    };
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

// ---- search paths -----------------------------------------------------------------------------

/// Frees a list returned by this file, and every path in it.
pub fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// The standard CLAP search locations for this host (existing or not), followed by every
/// non-empty entry of `CLAP_PATH`. Caller frees with `freePaths`.
pub fn defaultSearchPaths(gpa: Allocator) Allocator.Error![][]u8 {
    return defaultSearchPathsWith(gpa, builtin.os.tag, envFromProcess());
}

/// `defaultSearchPaths` with the OS and environment injected (tests and tools).
pub fn defaultSearchPathsWith(gpa: Allocator, os: std.Target.Os.Tag, env: Env) Allocator.Error![][]u8 {
    var list: Paths = .fromOwnedSlice(try osSearchPaths(gpa, os, env));
    errdefer freeList(gpa, &list);
    if (env.clap_path) |cp| {
        var it = std.mem.tokenizeScalar(u8, cp, PATH_LIST_DELIMITER);
        while (it.next()) |entry| try pushCopy(gpa, &list, entry);
    }
    return list.toOwnedSlice(gpa);
}

/// The OS-specific standard locations for the given OS and environment values, existing or
/// not. Caller frees with `freePaths`. Windows and the Unix-likes take different branches.
pub fn osSearchPaths(gpa: Allocator, os: std.Target.Os.Tag, env: Env) Allocator.Error![][]u8 {
    var list: Paths = .empty;
    errdefer freeList(gpa, &list);
    switch (os) {
        .macos => {
            if (env.home) |h| try pushJoined(gpa, &list, &.{ h, "Library/Audio/Plug-Ins/CLAP" });
            try pushCopy(gpa, &list, "/Library/Audio/Plug-Ins/CLAP");
        },
        .windows => {
            if (env.common_program_files) |c| try pushJoined(gpa, &list, &.{ c, "CLAP" });
            if (env.local_app_data) |l| try pushJoined(gpa, &list, &.{ l, "Programs", "Common", "CLAP" });
        },
        else => {
            if (env.home) |h| try pushJoined(gpa, &list, &.{ h, ".clap" });
            try pushCopy(gpa, &list, "/usr/lib/clap");
            try pushCopy(gpa, &list, "/usr/local/lib/clap");
        },
    }
    return list.toOwnedSlice(gpa);
}

// ---- path helpers -----------------------------------------------------------------------------

const Paths = std.ArrayList([]u8);

fn freeList(gpa: Allocator, list: *Paths) void {
    for (list.items) |p| gpa.free(p);
    list.deinit(gpa);
}

fn pushJoined(gpa: Allocator, list: *Paths, parts: []const []const u8) Allocator.Error!void {
    const p = try std.fs.path.join(gpa, parts);
    errdefer gpa.free(p);
    try list.append(gpa, p);
}

fn pushCopy(gpa: Allocator, list: *Paths, s: []const u8) Allocator.Error!void {
    const p = try gpa.dupe(u8, s);
    errdefer gpa.free(p);
    try list.append(gpa, p);
}

/// True for a separator of the host's path syntax.
fn isSeparator(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

/// The last component of `path`, ignoring trailing separators, as Rust's `file_name`.
/// Null for an empty path, `.`, `..`, or a path made only of separators.
fn fileName(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    const name = path[start..end];
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    return name;
}

/// Splits a file name at its last dot as Rust's `file_stem`/`extension` do. A leading dot
/// (".clap") is part of the stem, not an extension. The returned stem is the whole name when
/// there is no extension.
fn splitExtension(name: []const u8) struct { stem: []const u8, ext: ?[]const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .stem = name, .ext = null };
    if (dot == 0) return .{ .stem = name, .ext = null };
    return .{ .stem = name[0..dot], .ext = name[dot + 1 ..] };
}

/// True when the path names a CLAP plugin (`*.clap`, case-insensitive). Pure string test:
/// it does not touch the file system.
pub fn isClapPath(path: []const u8) bool {
    const name = fileName(path) orelse return false;
    const ext = splitExtension(name).ext orelse return false;
    return std.ascii.eqlIgnoreCase(ext, "clap");
}

/// Component-by-component path order, as Rust's `Path` `Ord`. Empty components are ignored.
pub fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeScalar(u8, a, '/');
    var ib = std.mem.tokenizeScalar(u8, b, '/');
    while (true) {
        const ca = ia.next();
        const cb = ib.next();
        if (ca == null) return cb != null;
        if (cb == null) return false;
        const order = std.mem.order(u8, ca.?, cb.?);
        if (order != .eq) return order == .lt;
    }
}

/// Path equality in the same component sense as `pathLessThan`.
fn pathsEqual(a: []const u8, b: []const u8) bool {
    return !pathLessThan({}, a, b) and !pathLessThan({}, b, a);
}

// ---- file system ------------------------------------------------------------------------------

/// The kind of the entry a path names, following symbolic links, or null when it cannot be
/// read (missing, no permission, dangling link).
fn kindOf(io: Io, path: []const u8) ?Io.File.Kind {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.kind;
}

fn isFile(io: Io, path: []const u8) bool {
    return kindOf(io, path) == .file;
}

fn isDir(io: Io, path: []const u8) bool {
    return kindOf(io, path) == .directory;
}

/// Recursively collects `.clap` files and bundles under `dirs`. Missing directories are
/// skipped. A `.clap` directory is a bundle and is not descended into. Symbolic links are
/// followed; a directory already entered in this scan is not walked again. The result is
/// sorted in `pathLessThan` order, deduplicated, and holds at most `MAX_BUNDLES` paths.
/// Caller frees with `freePaths`. Control thread only.
pub fn findBundles(gpa: Allocator, io: Io, dirs: []const []const u8) Allocator.Error![][]u8 {
    var scan: Scan = .{ .gpa = gpa, .io = io, .out = .empty, .budget = MAX_ENTRIES, .visited = .empty };
    defer scan.visited.deinit(gpa);
    errdefer freeList(gpa, &scan.out);

    for (dirs) |d| {
        if (isClapPath(d) and kindOf(io, d) != null) {
            try pushCopy(gpa, &scan.out, d);
        } else {
            try scan.walk(d, 0);
        }
    }

    std.mem.sort([]u8, scan.out.items, {}, sortedFirst);
    dedupSorted(gpa, &scan.out);
    while (scan.out.items.len > MAX_BUNDLES) {
        const p = scan.out.pop() orelse break;
        gpa.free(p);
    }
    return scan.out.toOwnedSlice(gpa);
}

fn sortedFirst(_: void, a: []u8, b: []u8) bool {
    return pathLessThan({}, a, b);
}

/// Removes adjacent duplicates from a sorted list, freeing the copies it drops.
fn dedupSorted(gpa: Allocator, list: *Paths) void {
    var w: usize = 0;
    for (list.items) |p| {
        if (w > 0 and pathsEqual(list.items[w - 1], p)) {
            gpa.free(p);
            continue;
        }
        list.items[w] = p;
        w += 1;
    }
    list.shrinkRetainingCapacity(w);
}

const Scan = struct {
    gpa: Allocator,
    io: Io,
    out: Paths,
    /// Directory entries left to visit in this scan.
    budget: usize,
    /// Inodes of the directories already entered (a link loop ends at the second visit).
    visited: std.AutoHashMapUnmanaged(Io.File.INode, void),

    fn full(self: *const Scan) bool {
        return self.out.items.len >= MAX_BUNDLES;
    }

    fn walk(self: *Scan, dir_path: []const u8, depth: usize) Allocator.Error!void {
        if (depth > MAX_DEPTH or self.full()) return;
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        const st = dir.stat(self.io) catch return;
        const seen = try self.visited.getOrPut(self.gpa, st.inode);
        if (seen.found_existing) return;

        var it = dir.iterate();
        while (true) {
            const maybe = it.next(self.io) catch break;
            const entry = maybe orelse break;
            if (self.budget == 0 or self.full()) return;
            self.budget -= 1;

            const child = try std.fs.path.join(self.gpa, &.{ dir_path, entry.name });
            var keep = false;
            defer if (!keep) self.gpa.free(child);

            // `statFile` follows symlinks, as Rust's `metadata` does. Unreadable entries are skipped.
            const child_st = dir.statFile(self.io, entry.name, .{}) catch continue;
            if (isClapPath(child)) {
                try self.out.append(self.gpa, child);
                keep = true;
            } else if (child_st.kind == .directory) {
                try self.walk(child, depth + 1);
            }
        }
    }
};

/// The loadable binary of a plugin: the file itself, or for a macOS bundle directory
/// `Contents/MacOS/<name>` (the executable named like the bundle, else the first of the
/// first `MAX_FALLBACK_FILES` files there in path order). Null when there is none. Caller
/// frees the returned path.
pub fn bundleExecutable(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?[]u8 {
    if (isFile(io, path)) return try gpa.dupe(u8, path);
    if (!isDir(io, path)) return null;

    const macos = try std.fs.path.join(gpa, &.{ path, "Contents", "MacOS" });
    defer gpa.free(macos);

    if (fileName(path)) |name| {
        const stem = splitExtension(name).stem;
        const candidate = try std.fs.path.join(gpa, &.{ macos, stem });
        if (isFile(io, candidate)) return candidate;
        gpa.free(candidate);
    }

    var dir = Io.Dir.cwd().openDir(io, macos, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]u8 = null;
    errdefer if (best) |b| gpa.free(b);
    var files: usize = 0;
    var it = dir.iterate();
    while (files < MAX_FALLBACK_FILES) {
        const maybe = it.next(io) catch break;
        const entry = maybe orelse break;
        const child = try std.fs.path.join(gpa, &.{ macos, entry.name });
        if (!isFile(io, child)) {
            gpa.free(child);
            continue;
        }
        files += 1;
        if (best) |b| {
            if (pathLessThan({}, child, b)) {
                gpa.free(b);
                best = child;
            } else {
                gpa.free(child);
            }
        } else {
            best = child;
        }
    }
    return best;
}

// ---- features ---------------------------------------------------------------------------------

/// True when any feature equals one of `names`, ignoring ASCII case.
fn hasAny(features: []const []const u8, names: []const []const u8) bool {
    for (features) |f| {
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(f, n)) return true;
        }
    }
    return false;
}

/// Maps CLAP feature strings to an insert-menu category. The first rule that matches wins,
/// in the order the Rust code checks them.
pub fn categoryFromFeatures(features: []const []const u8) Category {
    if (hasAny(features, &.{ "instrument", "synthesizer", "sampler", "drum", "drum-machine" })) return .instrument;
    if (hasAny(features, &.{ "equalizer", "filter" })) return .eq;
    if (hasAny(features, &.{ "compressor", "limiter", "expander", "gate", "de-esser", "transient-shaper" })) return .dynamics;
    if (hasAny(features, &.{"reverb"})) return .reverb;
    if (hasAny(features, &.{"delay"})) return .delay;
    if (hasAny(features, &.{ "chorus", "flanger", "phaser", "tremolo" })) return .modulation;
    if (hasAny(features, &.{"distortion"})) return .harmonic;
    if (hasAny(features, &.{ "pitch-shifter", "pitch-correction" })) return .pitch_shift;
    return .other;
}

/// True when the features mark an instrument (CLAP `instrument`).
pub fn isInstrument(features: []const []const u8) bool {
    return hasAny(features, &.{"instrument"});
}

// ---- tests ------------------------------------------------------------------------------------
// The first four tests are the Rust `#[cfg(test)]` tests of scan.rs, ported one for one.
// The rest are new: they cover the junk and truncated files, loops, depth and the injected
// environment, which the Rust suite did not reach.

/// A fresh scratch directory under the test cache, with its path relative to the working
/// directory (the Rust tests used `std::env::temp_dir`).
const Scratch = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init(gpa: Allocator) !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Scratch, gpa: Allocator) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// `root/rel`, owned by the caller.
    fn path(self: *const Scratch, gpa: Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, rel });
    }

    fn writeFile(self: *Scratch, rel: []const u8, data: []const u8) !void {
        const io = testIo();
        if (std.fs.path.dirname(rel)) |dir| try self.tmp.dir.createDirPath(io, dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    fn mkdir(self: *Scratch, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(testIo(), rel);
    }
};

/// A NUL-terminated copy of `s` for the C loader. Caller frees.
fn dupeZ(gpa: Allocator, s: []const u8) Allocator.Error![:0]u8 {
    const z = try gpa.allocSentinel(u8, s.len, 0);
    @memcpy(z, s);
    return z;
}

fn testIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The part of `path` after `root/`, with `/` separators.
fn relativeTo(root: []const u8, path: []const u8) ![]const u8 {
    try testing.expect(std.mem.startsWith(u8, path, root));
    try testing.expect(path.len > root.len and path[root.len] == '/');
    return path[root.len + 1 ..];
}

test "scan: finds files and bundles recursively but not inside bundles" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);

    try s.writeFile("a.clap", "x");
    try s.writeFile("readme.txt", "x");
    try s.writeFile("vendor/sub/B.CLAP", "x");
    try s.writeFile("c.clap/Contents/MacOS/c", "x");
    try s.writeFile("c.clap/Contents/inner.clap", "x");

    const d = s.root;
    const missing = try s.path(gpa, "missing");
    defer gpa.free(missing);

    const found = try findBundles(gpa, io, &.{ d, missing });
    defer freePaths(gpa, found);

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("a.clap", try relativeTo(d, found[0]));
    try testing.expectEqualStrings("c.clap", try relativeTo(d, found[1]));
    try testing.expectEqualStrings("vendor/sub/B.CLAP", try relativeTo(d, found[2]));

    const c_bundle = try s.path(gpa, "c.clap");
    defer gpa.free(c_bundle);
    const c_exec = try bundleExecutable(gpa, io, c_bundle);
    defer if (c_exec) |p| gpa.free(p);
    const want_c = try s.path(gpa, "c.clap/Contents/MacOS/c");
    defer gpa.free(want_c);
    try testing.expectEqualStrings(want_c, c_exec.?);

    const a_bundle = try s.path(gpa, "a.clap");
    defer gpa.free(a_bundle);
    const a_exec = try bundleExecutable(gpa, io, a_bundle);
    defer if (a_exec) |p| gpa.free(p);
    try testing.expectEqualStrings(a_bundle, a_exec.?);

    const nope = try s.path(gpa, "nope.clap");
    defer gpa.free(nope);
    try testing.expect((try bundleExecutable(gpa, io, nope)) == null);
}

test "scan: bundle_executable falls back to the first file" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);

    try s.writeFile("X.clap/Contents/MacOS/other", "x");
    try s.mkdir("Empty.clap");

    const x = try s.path(gpa, "X.clap");
    defer gpa.free(x);
    const exec = try bundleExecutable(gpa, io, x);
    defer if (exec) |p| gpa.free(p);
    const want = try s.path(gpa, "X.clap/Contents/MacOS/other");
    defer gpa.free(want);
    try testing.expectEqualStrings(want, exec.?);

    const empty = try s.path(gpa, "Empty.clap");
    defer gpa.free(empty);
    try testing.expect((try bundleExecutable(gpa, io, empty)) == null);
}

test "scan: os paths cover the standard locations" {
    const gpa = testing.allocator;
    const env: Env = .{ .home = "/home/u", .common_program_files = "C:/CPF", .local_app_data = "C:/LAD" };

    const mac = try osSearchPaths(gpa, .macos, env);
    defer freePaths(gpa, mac);
    try testing.expectEqual(@as(usize, 2), mac.len);
    try testing.expectEqualStrings("/home/u/Library/Audio/Plug-Ins/CLAP", mac[0]);
    try testing.expectEqualStrings("/Library/Audio/Plug-Ins/CLAP", mac[1]);

    const win = try osSearchPaths(gpa, .windows, env);
    defer freePaths(gpa, win);
    try testing.expectEqual(@as(usize, 2), win.len);
    try testing.expect(std.mem.endsWith(u8, win[0], "CLAP"));
    try testing.expect(std.mem.endsWith(u8, win[1], "CLAP"));

    const linux = try osSearchPaths(gpa, .linux, env);
    defer freePaths(gpa, linux);
    try testing.expectEqual(@as(usize, 3), linux.len);
    try testing.expectEqualStrings("/home/u/.clap", linux[0]);
    try testing.expectEqualStrings("/usr/lib/clap", linux[1]);
    try testing.expectEqualStrings("/usr/local/lib/clap", linux[2]);

    // The host-OS default, with the real environment. The Rust assertion is kept: at least
    // one fewer entry than the list built above for this OS.
    const host = try osSearchPaths(gpa, builtin.os.tag, env);
    defer freePaths(gpa, host);
    const default = try defaultSearchPaths(gpa);
    defer freePaths(gpa, default);
    try testing.expect(default.len >= host.len -| 1);
}

test "scan: features map to categories" {
    try testing.expectEqual(Category.reverb, categoryFromFeatures(&.{ "audio-effect", "reverb", "stereo" }));
    try testing.expectEqual(Category.instrument, categoryFromFeatures(&.{ "instrument", "synthesizer" }));
    try testing.expectEqual(Category.dynamics, categoryFromFeatures(&.{ "audio-effect", "Compressor" }));
    try testing.expectEqual(Category.eq, categoryFromFeatures(&.{ "audio-effect", "equalizer" }));
    try testing.expectEqual(Category.modulation, categoryFromFeatures(&.{"chorus"}));
    try testing.expectEqual(Category.harmonic, categoryFromFeatures(&.{"distortion"}));
    try testing.expectEqual(Category.pitch_shift, categoryFromFeatures(&.{"pitch-shifter"}));
    try testing.expectEqual(Category.delay, categoryFromFeatures(&.{"delay"}));
    try testing.expectEqual(Category.other, categoryFromFeatures(&.{}));
    try testing.expect(isInstrument(&.{"instrument"}));
    try testing.expect(!isInstrument(&.{"audio-effect"}));
}

test "scan: a clap extension is recognised case-insensitively and dot files are not plugins" {
    try testing.expect(isClapPath("/x/a.clap"));
    try testing.expect(isClapPath("/x/B.CLAP"));
    try testing.expect(isClapPath("/x/trailing.clap/"));
    try testing.expect(!isClapPath("/x/.clap"));
    try testing.expect(!isClapPath("/x/a.clap.txt"));
    try testing.expect(!isClapPath("/x/a."));
    try testing.expect(!isClapPath(""));
    try testing.expect(!isClapPath("/x/.."));
}

test "scan: sorted results compare path components, not bytes" {
    try testing.expect(pathLessThan({}, "a/b", "a.clap"));
    try testing.expect(!pathLessThan({}, "a.clap", "a/b"));
    try testing.expect(pathLessThan({}, "a", "a/b"));
    try testing.expect(!pathLessThan({}, "a/b", "a/b"));
    try testing.expect(pathsEqual("a//b", "a/b"));
}

test "scan: CLAP_PATH entries are appended and empty entries are dropped" {
    const gpa = testing.allocator;
    const paths = try defaultSearchPathsWith(gpa, .macos, .{ .home = "/h", .clap_path = "/a::/b:" });
    defer freePaths(gpa, paths);
    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expectEqualStrings("/a", paths[2]);
    try testing.expectEqualStrings("/b", paths[3]);
}

test "scan: a junk .clap file is found, is not a bundle directory, and yields no descriptor" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);
    try s.writeFile("junk.clap", "this is not a shared library\n");

    const d = s.root;
    const found = try findBundles(gpa, io, &.{d});
    defer freePaths(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);

    const exec = try bundleExecutable(gpa, io, found[0]);
    defer if (exec) |p| gpa.free(p);
    try testing.expectEqualStrings(found[0], exec.?);

    // The loader is the only place a descriptor is read: it must refuse the file and not crash.
    const z = try dupeZ(gpa, found[0]);
    defer gpa.free(z);
    if (bundle.Bundle.open(z)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "scan: zero-byte and truncated Mach-O .clap files are found and refused by the loader" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);
    try s.writeFile("empty.clap", "");
    // The first bytes of a 64-bit Mach-O header, then nothing: a download cut short.
    try s.writeFile("cut.clap", &.{ 0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01 });

    const d = s.root;
    const found = try findBundles(gpa, io, &.{d});
    defer freePaths(gpa, found);
    try testing.expectEqual(@as(usize, 2), found.len);

    for (found) |p| {
        const z = try dupeZ(gpa, p);
        defer gpa.free(z);
        if (bundle.Bundle.open(z)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "scan: a directory symbolic link loop ends, and the directory is walked once" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);
    try s.writeFile("plugins/one.clap", "x");
    // plugins/loop -> .. (the scan root): following it would revisit the same directories.
    s.tmp.dir.symLink(io, "..", "plugins/loop", .{ .is_directory = true }) catch return error.SkipZigTest;

    const d = try s.path(gpa, "plugins");
    defer gpa.free(d);
    const found = try findBundles(gpa, io, &.{d});
    defer freePaths(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("one.clap", try relativeTo(d, found[0]));
}

test "scan: directories deeper than MAX_DEPTH are not searched" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);

    var rel: std.ArrayList(u8) = .empty;
    defer rel.deinit(gpa);
    var depth: usize = 0;
    while (depth <= MAX_DEPTH + 1) : (depth += 1) {
        try rel.appendSlice(gpa, "d/");
    }
    try rel.appendSlice(gpa, "deep.clap");
    try s.writeFile(rel.items, "x");
    try s.writeFile("shallow.clap", "x");

    const d = s.root;
    const found = try findBundles(gpa, io, &.{d});
    defer freePaths(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("shallow.clap", try relativeTo(d, found[0]));
}

test "scan: a directory with no readable Contents/MacOS has no executable" {
    const gpa = testing.allocator;
    const io = testIo();
    var s = try Scratch.init(gpa);
    defer s.deinit(gpa);
    try s.writeFile("Plain.clap/Contents/readme.txt", "x");

    const p = try s.path(gpa, "Plain.clap");
    defer gpa.free(p);
    try testing.expect((try bundleExecutable(gpa, io, p)) == null);
}
