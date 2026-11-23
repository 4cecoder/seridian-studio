// Translated to Zig from soundcraft/crates/vst3-host/src/scan.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Finding VST3 plugins on disk, resolving bundles to their binaries and mapping VST3
//! sub-categories to insert-menu categories.
//!
//! Control thread only (file I/O and allocation). Paths are byte strings; every list the
//! functions return is owned by the caller and released with `freePaths`. File access goes
//! through a caller-supplied `std.Io`, as libraries must not import the process-wide one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Category = @import("../plugin.zig").Category;

/// Directory recursion limit while scanning (vendors nest folders, never deeply).
pub const max_depth: usize = 8;
/// Upper bound on bundles collected by one scan (hostile or huge folders).
pub const max_bundles: usize = 4096;
/// Upper bound on directory entries visited by one scan.
pub const max_entries: usize = 100_000;

/// The operating systems whose VST3 bundle layouts we know.
pub const Os = enum {
    mac_os,
    windows,
    /// Linux and the BSDs (same bundle layout).
    unix,

    /// The OS this build runs on.
    pub fn current() Os {
        return switch (builtin.os.tag) {
            .macos => .mac_os,
            .windows => .windows,
            else => .unix,
        };
    }
};

/// Frees a list returned by this file (each path and the list itself).
pub fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn joinPath(gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, parts);
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

/// The standard VST3 search locations for this OS (existing or not), followed by every
/// entry of the `VST3_PATH` environment variable.
pub fn defaultSearchPaths(gpa: Allocator) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    const base = try osSearchPaths(gpa, Os.current(), envSlice("HOME"), envSlice("COMMONPROGRAMFILES"), envSlice("LOCALAPPDATA"));
    defer gpa.free(base);
    try list.appendSlice(gpa, base);
    if (envSlice("VST3_PATH")) |cp| {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var it = std.mem.splitScalar(u8, cp, sep);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const dup = try gpa.dupe(u8, entry);
            errdefer gpa.free(dup);
            try list.append(gpa, dup);
        }
    }
    return list.toOwnedSlice(gpa);
}

/// The OS-specific standard locations, given the relevant environment values.
pub fn osSearchPaths(gpa: Allocator, os: Os, home: ?[]const u8, common_program_files: ?[]const u8, local_app_data: ?[]const u8) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    switch (os) {
        .mac_os => {
            if (home) |h| try pushJoined(gpa, &list, &.{ h, "Library/Audio/Plug-Ins/VST3" });
            try pushJoined(gpa, &list, &.{"/Library/Audio/Plug-Ins/VST3"});
        },
        .windows => {
            if (common_program_files) |c| try pushJoined(gpa, &list, &.{ c, "VST3" });
            if (local_app_data) |l| try pushJoined(gpa, &list, &.{ l, "Programs", "Common", "VST3" });
        },
        .unix => {
            if (home) |h| try pushJoined(gpa, &list, &.{ h, ".vst3" });
            try pushJoined(gpa, &list, &.{"/usr/lib/vst3"});
            try pushJoined(gpa, &list, &.{"/usr/local/lib/vst3"});
        },
    }
    return list.toOwnedSlice(gpa);
}

fn pushJoined(gpa: Allocator, list: *std.ArrayList([]u8), parts: []const []const u8) Allocator.Error!void {
    const p = try joinPath(gpa, parts);
    errdefer gpa.free(p);
    try list.append(gpa, p);
}

/// True when the path names a VST3 plugin (`*.vst3`, case-insensitive).
pub fn isVst3Path(p: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(p), ".vst3");
}

fn statKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    // Follows symlinks (plugins are often symlinked in); errors mean "not there".
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.kind;
}

fn pathLess(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Recursively collects `.vst3` bundles and files under `dirs` (missing directories are
/// skipped). A `.vst3` directory is a bundle and is not descended into. The result is
/// sorted (bytewise) and deduplicated; release it with `freePaths`.
pub fn findBundles(gpa: Allocator, io: std.Io, dirs: []const []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var budget: usize = max_entries;
    for (dirs) |d| {
        if (isVst3Path(d) and statKind(io, d) != null) {
            const dup = try gpa.dupe(u8, d);
            errdefer gpa.free(dup);
            try out.append(gpa, dup);
        } else {
            try walk(gpa, io, d, 0, &out, &budget);
        }
    }
    std.mem.sort([]u8, out.items, {}, pathLess);
    // dedup adjacent
    var w: usize = 0;
    for (out.items) |p| {
        if (w > 0 and std.mem.eql(u8, out.items[w - 1], p)) {
            gpa.free(p);
        } else {
            out.items[w] = p;
            w += 1;
        }
    }
    out.items.len = w;
    while (out.items.len > max_bundles) gpa.free(out.pop().?);
    return out.toOwnedSlice(gpa);
}

fn walk(gpa: Allocator, io: std.Io, dir: []const u8, depth: usize, out: *std.ArrayList([]u8), budget: *usize) Allocator.Error!void {
    if (depth > max_depth or out.items.len >= max_bundles) return;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch return) |entry| {
        if (budget.* == 0 or out.items.len >= max_bundles) return;
        budget.* -= 1;
        const p = try joinPath(gpa, &.{ dir, entry.name });
        var keep = false;
        defer if (!keep) gpa.free(p);
        const kind = statKind(io, p) orelse continue;
        if (isVst3Path(p)) {
            try out.append(gpa, p);
            keep = true;
        } else if (kind == .directory) {
            try walk(gpa, io, p, depth + 1, out, budget);
        }
    }
}

/// The `Contents/<dir>` folder names that hold this machine's binaries, most specific first.
pub fn archDirs(os: Os) []const []const u8 {
    const arch = builtin.cpu.arch;
    return switch (os) {
        .mac_os => &.{"MacOS"},
        .windows => if (arch == .aarch64) &.{ "arm64-win", "arm64ec-win", "arm64x-win" } else if (arch == .x86) &.{"x86-win"} else &.{"x86_64-win"},
        .unix => if (arch == .aarch64) &.{"aarch64-linux"} else if (arch == .x86) &.{"i386-linux"} else &.{"x86_64-linux"},
    };
}

/// The loadable binary of a plugin for this OS: a single-file `.vst3` itself, or inside a
/// bundle directory `Contents/MacOS/<name>` (macOS), `Contents/x86_64-win/<name>.vst3`
/// (Windows) or `Contents/x86_64-linux/<name>.so` (Linux/BSD), falling back to the
/// only/first fitting file there. Caller frees the result.
pub fn bundleBinary(gpa: Allocator, io: std.Io, path: []const u8) Allocator.Error!?[]u8 {
    return bundleBinaryFor(gpa, io, Os.current(), path);
}

/// `bundleBinary` for a given OS layout (testable everywhere).
pub fn bundleBinaryFor(gpa: Allocator, io: std.Io, os: Os, path: []const u8) Allocator.Error!?[]u8 {
    const kind = statKind(io, path) orelse return null;
    if (kind == .file) return try gpa.dupe(u8, path);
    if (kind != .directory) return null;
    const stem = std.fs.path.stem(path);
    if (stem.len == 0) return null;
    const ext: ?[]const u8 = switch (os) {
        .mac_os => null,
        .windows => "vst3",
        .unix => "so",
    };
    for (archDirs(os)) |dir| {
        const folder = try joinPath(gpa, &.{ path, "Contents", dir });
        defer gpa.free(folder);
        // `named` = folder/stem with its extension replaced by `ext` (Rust set_extension).
        const base_stem = if (ext != null) stripExt(stem) else stem;
        const named_name = if (ext) |e| try std.fmt.allocPrint(gpa, "{s}.{s}", .{ base_stem, e }) else try gpa.dupe(u8, stem);
        defer gpa.free(named_name);
        const named = try joinPath(gpa, &.{ folder, named_name });
        if (statKind(io, named)) |k| {
            if (k == .file) return named;
        }
        gpa.free(named);
        const found = try firstFileIn(gpa, io, folder, ext);
        if (found) |f| return f;
    }
    return null;
}

fn stripExt(name: []const u8) []const u8 {
    const e = std.fs.path.extension(name);
    return name[0 .. name.len - e.len];
}

/// First regular file (sorted by path) among the first 64 directory entries that fit `ext`.
fn firstFileIn(gpa: Allocator, io: std.Io, folder: []const u8, ext: ?[]const u8) Allocator.Error!?[]u8 {
    var d = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |p| gpa.free(p);
        files.deinit(gpa);
    }
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (files.items.len >= 64) break;
        const p = try joinPath(gpa, &.{ folder, entry.name });
        var keep = false;
        defer if (!keep) gpa.free(p);
        if ((statKind(io, p) orelse continue) != .file) continue;
        if (ext) |e| {
            if (!hasExt(p, e)) continue;
        }
        try files.append(gpa, p);
        keep = true;
    }
    if (files.items.len == 0) return null;
    std.mem.sort([]u8, files.items, {}, pathLess);
    return try gpa.dupe(u8, files.items[0]);
}

fn hasExt(p: []const u8, e: []const u8) bool {
    const x = std.fs.path.extension(p);
    return x.len == e.len + 1 and std.ascii.eqlIgnoreCase(x[1..], e);
}

/// The `|`-separated VST3 sub-category tokens (`"Fx|Reverb"` gives `{"Fx", "Reverb"}`),
/// trimmed, empties dropped, at most 32. Each token is an owned copy; free with `freeSubCategories`.
pub fn splitSubCategories(gpa: Allocator, s: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |t| gpa.free(t);
        list.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t\r\n");
        if (t.len == 0) continue;
        if (list.items.len >= 32) break;
        const owned = try gpa.dupe(u8, t);
        errdefer gpa.free(owned);
        try list.append(gpa, owned);
    }
    return list.toOwnedSlice(gpa);
}

/// Frees a slice returned by `splitSubCategories`, tokens included.
pub fn freeSubCategories(gpa: Allocator, subs: []const []const u8) void {
    for (subs) |t| gpa.free(t);
    gpa.free(subs);
}

fn hasAny(subs: []const []const u8, names: []const []const u8) bool {
    for (subs) |f| {
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(f, n)) return true;
        }
    }
    return false;
}

/// Maps VST3 sub-categories (`Fx|EQ`, `Instrument|Synth`, ...) to an insert-menu category.
pub fn categoryFromSubCategories(subs: []const []const u8) Category {
    if (isInstrument(subs)) return .instrument;
    if (hasAny(subs, &.{ "EQ", "Filter" })) return .eq;
    if (hasAny(subs, &.{"Dynamics"})) return .dynamics;
    if (hasAny(subs, &.{"Reverb"})) return .reverb;
    if (hasAny(subs, &.{"Delay"})) return .delay;
    if (hasAny(subs, &.{"Modulation"})) return .modulation;
    if (hasAny(subs, &.{"Distortion"})) return .harmonic;
    if (hasAny(subs, &.{"Pitch Shift"})) return .pitch_shift;
    return .other;
}

/// True when the sub-categories mark an instrument (`Instrument`, `Instrument|Synth`, ...).
pub fn isInstrument(subs: []const []const u8) bool {
    return subs.len > 0 and std.ascii.eqlIgnoreCase(subs[0], "Instrument");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A fresh empty scratch directory (absolute path, caller frees) under the system tmp dir.
fn tmp(name: []const u8) ![]u8 {
    const io = testIo();
    const d = try std.fmt.allocPrint(testing.allocator, "/tmp/seridian-vst3-scan-{s}-{d}", .{ name, std.c.getpid() });
    errdefer testing.allocator.free(d);
    std.Io.Dir.cwd().deleteTree(io, d) catch {};
    try std.Io.Dir.cwd().createDirPath(io, d);
    return d;
}

fn rmTree(d: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testIo(), d) catch {};
}

fn mkdirs(root: []const u8, sub: []const u8) !void {
    const p = try joinPath(testing.allocator, &.{ root, sub });
    defer testing.allocator.free(p);
    try std.Io.Dir.cwd().createDirPath(testIo(), p);
}

fn writeFile(root: []const u8, sub: []const u8) !void {
    const p = try joinPath(testing.allocator, &.{ root, sub });
    defer testing.allocator.free(p);
    const f = try std.Io.Dir.cwd().createFile(testIo(), p, .{});
    defer f.close(testIo());
    try f.writeStreamingAll(testIo(), "x");
}

fn expectBinary(os: Os, root: []const u8, bundle: []const u8, want: ?[]const u8) !void {
    const p = try joinPath(testing.allocator, &.{ root, bundle });
    defer testing.allocator.free(p);
    const got = try bundleBinaryFor(testing.allocator, testIo(), os, p);
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| {
        const wp = try joinPath(testing.allocator, &.{ root, w });
        defer testing.allocator.free(wp);
        try testing.expect(got != null);
        try testing.expectEqualStrings(wp, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "finds_files_and_bundles_recursively_but_not_inside_bundles" {
    const gpa = testing.allocator;
    const io = testIo();
    const d = try tmp("find");
    defer gpa.free(d);
    defer rmTree(d);
    try writeFile(d, "a.vst3");
    try writeFile(d, "readme.txt");
    try mkdirs(d, "vendor/sub");
    try writeFile(d, "vendor/sub/B.VST3");
    try mkdirs(d, "c.vst3/Contents/MacOS");
    try writeFile(d, "c.vst3/Contents/MacOS/c");
    try writeFile(d, "c.vst3/Contents/inner.vst3");
    const missing = try joinPath(gpa, &.{ d, "missing" });
    defer gpa.free(missing);
    const found = try findBundles(gpa, io, &.{ d, missing });
    defer freePaths(gpa, found);
    const want = [_][]const u8{ "a.vst3", "c.vst3", "vendor/sub/B.VST3" };
    try testing.expectEqual(want.len, found.len);
    for (found, want) |f, w| {
        try testing.expect(std.mem.startsWith(u8, f, d));
        try testing.expectEqualStrings(w, f[d.len + 1 ..]);
    }
    const single = try joinPath(gpa, &.{ d, "a.vst3" });
    defer gpa.free(single);
    const one = try findBundles(gpa, io, &.{single});
    defer freePaths(gpa, one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings(single, one[0]);
}

test "bundles_resolve_per_os_layout" {
    const gpa = testing.allocator;
    const d = try tmp("layout");
    defer gpa.free(d);
    defer rmTree(d);
    // macOS
    try mkdirs(d, "M.vst3/Contents/MacOS");
    try writeFile(d, "M.vst3/Contents/MacOS/M");
    try writeFile(d, "M.vst3/Contents/MacOS/aaa");
    try expectBinary(.mac_os, d, "M.vst3", "M.vst3/Contents/MacOS/M");
    // macOS fallback: first file when the name differs.
    try mkdirs(d, "N.vst3/Contents/MacOS");
    try writeFile(d, "N.vst3/Contents/MacOS/other");
    try expectBinary(.mac_os, d, "N.vst3", "N.vst3/Contents/MacOS/other");
    // Windows
    const win = archDirs(.windows)[0];
    const wdir = try std.fmt.allocPrint(gpa, "W.vst3/Contents/{s}", .{win});
    defer gpa.free(wdir);
    try mkdirs(d, wdir);
    const w1 = try std.fmt.allocPrint(gpa, "{s}/W.vst3", .{wdir});
    defer gpa.free(w1);
    const w2 = try std.fmt.allocPrint(gpa, "{s}/helper.dll", .{wdir});
    defer gpa.free(w2);
    try writeFile(d, w1);
    try writeFile(d, w2);
    try expectBinary(.windows, d, "W.vst3", w1);
    // Linux
    const lin = archDirs(.unix)[0];
    const ldir = try std.fmt.allocPrint(gpa, "L.vst3/Contents/{s}", .{lin});
    defer gpa.free(ldir);
    try mkdirs(d, ldir);
    const l1 = try std.fmt.allocPrint(gpa, "{s}/notes.txt", .{ldir});
    defer gpa.free(l1);
    const l2 = try std.fmt.allocPrint(gpa, "{s}/Renamed.so", .{ldir});
    defer gpa.free(l2);
    const l3 = try std.fmt.allocPrint(gpa, "{s}/L.so", .{ldir});
    defer gpa.free(l3);
    try writeFile(d, l1);
    try expectBinary(.unix, d, "L.vst3", null); // only .so files qualify
    try writeFile(d, l2);
    try expectBinary(.unix, d, "L.vst3", l2);
    try writeFile(d, l3);
    try expectBinary(.unix, d, "L.vst3", l3);
    // Single-file plugin, wrong layout, missing.
    try writeFile(d, "single.vst3");
    try expectBinary(.windows, d, "single.vst3", "single.vst3");
    try expectBinary(.windows, d, "M.vst3", null);
    try expectBinary(.mac_os, d, "nope.vst3", null);
    try mkdirs(d, "Empty.vst3");
    const empty = try joinPath(gpa, &.{ d, "Empty.vst3" });
    defer gpa.free(empty);
    const none = try bundleBinary(gpa, testIo(), empty);
    try testing.expect(none == null);
}

test "os_paths_cover_the_standard_locations" {
    const gpa = testing.allocator;
    const mac = try osSearchPaths(gpa, .mac_os, "/Users/u", null, null);
    defer freePaths(gpa, mac);
    try testing.expectEqual(@as(usize, 2), mac.len);
    try testing.expectEqualStrings("/Users/u/Library/Audio/Plug-Ins/VST3", mac[0]);
    try testing.expectEqualStrings("/Library/Audio/Plug-Ins/VST3", mac[1]);
    const win = try osSearchPaths(gpa, .windows, null, "C:/CPF", "C:/LAD");
    defer freePaths(gpa, win);
    const want_win0 = try joinPath(gpa, &.{ "C:/CPF", "VST3" });
    defer gpa.free(want_win0);
    try testing.expectEqualStrings(want_win0, win[0]);
    try testing.expectEqual(@as(usize, 2), win.len);
    const unix = try osSearchPaths(gpa, .unix, "/home/u", null, null);
    defer freePaths(gpa, unix);
    try testing.expectEqual(@as(usize, 3), unix.len);
    try testing.expectEqualStrings("/home/u/.vst3", unix[0]);
    try testing.expectEqualStrings("/usr/lib/vst3", unix[1]);
    try testing.expectEqualStrings("/usr/local/lib/vst3", unix[2]);
    const def = try defaultSearchPaths(gpa);
    defer freePaths(gpa, def);
    try testing.expect(def.len != 0);
}

fn catOf(s: []const u8) !Category {
    const subs = try splitSubCategories(testing.allocator, s);
    defer freeSubCategories(testing.allocator, subs);
    return categoryFromSubCategories(subs);
}

test "sub_categories_map_to_categories" {
    try testing.expectEqual(Category.reverb, try catOf("Fx|Reverb"));
    try testing.expectEqual(Category.instrument, try catOf("Instrument|Synth"));
    try testing.expectEqual(Category.dynamics, try catOf("Fx|Dynamics"));
    try testing.expectEqual(Category.eq, try catOf("Fx|EQ"));
    try testing.expectEqual(Category.eq, try catOf("Fx|Filter"));
    try testing.expectEqual(Category.modulation, try catOf("Fx|Modulation"));
    try testing.expectEqual(Category.harmonic, try catOf("Fx|Distortion"));
    try testing.expectEqual(Category.pitch_shift, try catOf("Fx|Pitch Shift"));
    try testing.expectEqual(Category.delay, try catOf("Fx|Delay"));
    try testing.expectEqual(Category.other, try catOf("Fx"));
    try testing.expectEqual(Category.other, try catOf(""));
    const gpa = testing.allocator;
    const toks = try splitSubCategories(gpa, " Fx || Delay |");
    defer freeSubCategories(gpa, toks);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("Fx", toks[0]);
    try testing.expectEqualStrings("Delay", toks[1]);
    const a = try splitSubCategories(gpa, "Instrument|Sampler");
    defer freeSubCategories(gpa, a);
    try testing.expect(isInstrument(a));
    const b = try splitSubCategories(gpa, "Fx|Instrument");
    defer freeSubCategories(gpa, b);
    try testing.expect(!isInstrument(b));
}

// Not in the Rust source: the task asks that junk inputs yield nothing and never crash.
test "junk inputs yield no binaries and no crash" {
    const gpa = testing.allocator;
    const io = testIo();
    const d = try tmp("junk");
    defer gpa.free(d);
    defer rmTree(d);
    try mkdirs(d, "trunc.vst3");
    try writeFile(d, "trunc.vst3/Contents");
    try mkdirs(d, "weird.vst3/Contents/MacOS");
    try mkdirs(d, "nonbundle");
    try writeFile(d, "nonbundle/readme");
    try expectBinary(.mac_os, d, "trunc.vst3", null);
    try expectBinary(.mac_os, d, "weird.vst3", null);
    try expectBinary(.unix, d, "nonbundle", null);
    const none = try bundleBinaryFor(gpa, io, .mac_os, "");
    try testing.expect(none == null);
    const nodirs = try findBundles(gpa, io, &.{ "", "/definitely/not/here" });
    defer freePaths(gpa, nodirs);
    try testing.expectEqual(@as(usize, 0), nodirs.len);
    try testing.expect(isVst3Path("/x/Y.VsT3"));
    try testing.expect(!isVst3Path("/x/.vst3x"));
}
