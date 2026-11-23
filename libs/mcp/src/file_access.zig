// Translated to Zig from soundcraft/crates/engine/src/file_access.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The folders automation may read and write.
//!
//! `zig build run -- mcp --automation-read-root <dir> --automation-write-root <dir>` confines the
//! files an agent's commands reach; each flag may be given more than once. `AutomationRoots` holds
//! the folders of each kind. While they are in force, every path a command reads goes through
//! `checkRead` and every path it writes through `checkWrite`:
//!
//! - The path is made absolute against the working directory, as the file system reads it. Its
//!   links are followed: for a file that doesn't exist yet, the links of its nearest existing
//!   folder, the rest of the path being plain names (`..` below a missing folder is refused, and so
//!   is a link that leads nowhere).
//! - The result must lie inside one of the roots of its kind, compared by whole components
//!   (`/work2` isn't inside `/work`), without regard to case on Windows.
//! - Read and write access are separate: a root given alone grants only its own kind of access.
//!
//! Roots are in force on a thread inside `confine`, and in the whole process after
//! `confineProcess` (the MCP server), except inside `unconfined`. Without roots nothing is checked.
//!
//! A path is checked, then opened: a process that can change the folders in between (swapping in
//! a link) can still win that race. The roots keep an agent to the files it was given; they don't
//! guard against other programs on the computer.
//!
//! Denials are reported as messages. A check returns `null` when the path may be used, otherwise
//! an allocated message (owned by the caller, freed with the roots' allocator). The messages name
//! the path as the caller gave it and the roots; they never show a resolved path outside the roots.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Read access or write access.
pub const Access = enum { read, write };

/// Why a root could not be opened. `path` is the caller's input, borrowed for the call.
pub const RootFailure = struct {
    access: Access,
    path: []const u8,
    cause: anyerror,
};

/// Errors of `AutomationRoots.new`. The details go to the `RootFailure` out parameter.
pub const RootOpenError = error{CannotOpenRoot} || Allocator.Error;

/// The message for a `RootFailure`, owned by the caller.
pub fn rootFailureMessage(gpa: Allocator, failure: RootFailure) ![]u8 {
    return std.fmt.allocPrint(gpa, "cannot open the automation {s} root `{s}`: {s}", .{
        @tagName(failure.access), failure.path, @errorName(failure.cause),
    });
}

const Root = struct {
    /// The folder made absolute, links followed: what paths are compared with.
    resolved: []u8,
    /// The same without Windows' `\\?\` prefix, for people.
    shown: []u8,

    fn free(self: Root, gpa: Allocator) void {
        gpa.free(self.resolved);
        gpa.free(self.shown);
    }
};

fn freeRoots(gpa: Allocator, roots: []Root) void {
    for (roots) |r| r.free(gpa);
    gpa.free(roots);
}

/// The folders automation may read and write; a kind with no root grants no access of its kind.
/// The value owns its roots: `deinit` frees them. Scopes hold it by pointer, so it must not move
/// while it is in force.
pub const AutomationRoots = struct {
    gpa: Allocator,
    io: std.Io,
    read: []Root,
    write: []Root,

    /// The roots `read` and `write`, which must be existing folders (one given twice counts once).
    /// `null` when neither kind has any: nothing is confined then. On `error.CannotOpenRoot`,
    /// `failure` (if given) says which root and why.
    pub fn new(
        gpa: Allocator,
        io: std.Io,
        read: []const []const u8,
        write: []const []const u8,
        failure: ?*RootFailure,
    ) RootOpenError!?AutomationRoots {
        if (read.len == 0 and write.len == 0) return null;
        const read_roots = try openAll(gpa, io, read, .read, failure);
        errdefer freeRoots(gpa, read_roots);
        const write_roots = try openAll(gpa, io, write, .write, failure);
        return .{ .gpa = gpa, .io = io, .read = read_roots, .write = write_roots };
    }

    pub fn deinit(self: *AutomationRoots) void {
        freeRoots(self.gpa, self.read);
        freeRoots(self.gpa, self.write);
        self.* = undefined;
    }

    /// The roots for people: `read A, B; write C` (`none` for a kind without any). Owned by the caller.
    pub fn describe(self: *const AutomationRoots) ![]u8 {
        const read = try joinShown(self.gpa, self.read);
        defer self.gpa.free(read);
        const write = try joinShown(self.gpa, self.write);
        defer self.gpa.free(write);
        return std.fmt.allocPrint(self.gpa, "read {s}; write {s}", .{ read, write });
    }

    /// May the file or folder at `path` be used for `access`? It must lie inside one of the roots of
    /// that kind. `null`: yes. Otherwise the message says why not (owned by the caller).
    pub fn check(self: *const AutomationRoots, path: []const u8, access: Access) !?[]u8 {
        const gpa = self.gpa;
        const roots = switch (access) {
            .read => self.read,
            .write => self.write,
        };
        if (roots.len == 0) {
            return try std.fmt.allocPrint(gpa, "automation filesystem access is not granted: {s} authority is absent: {s}", .{ @tagName(access), path });
        }
        const resolved = switch (try resolve(self, path)) {
            .rejected => |message| return message,
            .resolved => |r| r,
        };
        defer gpa.free(resolved);
        for (roots) |r| {
            if (inside(resolved, r.resolved)) return null;
        }
        if (roots.len == 1) {
            return try std.fmt.allocPrint(gpa, "automation path rejected: outside the {s} root {s}: {s}", .{ @tagName(access), roots[0].shown, path });
        }
        const list = try joinShown(gpa, roots);
        defer gpa.free(list);
        return try std.fmt.allocPrint(gpa, "automation path rejected: outside the {s} roots {s}: {s}", .{ @tagName(access), list, path });
    }
};

/// Opens each path of one kind as a root, dropping duplicates (by resolved folder).
fn openAll(gpa: Allocator, io: std.Io, paths: []const []const u8, access: Access, failure: ?*RootFailure) RootOpenError![]Root {
    var list: std.ArrayList(Root) = .empty;
    errdefer {
        for (list.items) |r| r.free(gpa);
        list.deinit(gpa);
    }
    for (paths) |path| {
        const root = openRoot(gpa, io, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |cause| {
                if (failure) |f| f.* = .{ .access = access, .path = path, .cause = cause };
                return error.CannotOpenRoot;
            },
        };
        if (containsResolved(list.items, root.resolved)) {
            root.free(gpa);
            continue;
        }
        list.append(gpa, root) catch |err| {
            root.free(gpa);
            return err;
        };
    }
    return list.toOwnedSlice(gpa);
}

fn containsResolved(roots: []const Root, resolved: []const u8) bool {
    for (roots) |r| {
        if (std.mem.eql(u8, r.resolved, resolved)) return true;
    }
    return false;
}

/// The folder at `path`, which must exist and be a folder. Opening it fails for a file (NotDir) and
/// for a missing folder (FileNotFound); its real path comes from the open handle.
fn openRoot(gpa: Allocator, io: std.Io, path: []const u8) !Root {
    // As `canonicalize("")` does: nothing to open.
    if (path.len == 0) return error.FileNotFound;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    const resolved = try gpa.dupe(u8, buf[0..n]);
    errdefer gpa.free(resolved);
    const shown = try plain(gpa, resolved);
    return .{ .resolved = resolved, .shown = shown };
}

/// The roots of one kind for people, joined with `, `, or `none`. Owned by the caller.
fn joinShown(gpa: Allocator, roots: []const Root) ![]u8 {
    if (roots.len == 0) return gpa.dupe(u8, "none");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (roots, 0..) |r, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, r.shown);
    }
    return out.toOwnedSlice(gpa);
}

/// Where the roots are in force on a thread (`confine`, `unconfined`).
const Scope = union(enum) {
    confined: *const AutomationRoots,
    unconfined,
};

/// This thread's scope; `null`: the process's roots (`confineProcess`).
threadlocal var scope: ?Scope = null;

/// The roots in force in every thread outside `confine` and `unconfined`. Set once, for good.
var process_roots: std.atomic.Value(?*const AutomationRoots) = .init(null);

/// Put `roots` in force in the whole process, for good. `false` when roots were in force already
/// (they stay as they were). The roots must outlive the process.
pub fn confineProcess(roots: *const AutomationRoots) bool {
    return process_roots.cmpxchgStrong(null, roots, .acq_rel, .monotonic) == null;
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// Runs `f` with `new` as this thread's scope and puts the previous scope back when it returns,
/// also when it returns an error (Zig has no unwinding; `defer` is the restore).
fn withScope(new: ?Scope, comptime f: anytype, args: anytype) ReturnOf(f) {
    const previous = scope;
    scope = new;
    defer scope = previous;
    return @call(.auto, f, args);
}

/// Run `f` with `roots` in force on this thread (`null`: as things stand).
pub fn confine(roots: ?*const AutomationRoots, comptime f: anytype, args: anytype) ReturnOf(f) {
    const r = roots orelse return @call(.auto, f, args);
    return withScope(.{ .confined = r }, f, args);
}

/// Run `f` with no roots in force on this thread: what the person at the keyboard does, and the
/// app's own folders.
pub fn unconfined(comptime f: anytype, args: anytype) ReturnOf(f) {
    return withScope(.unconfined, f, args);
}

/// The roots in force on this thread, if any. The pointer is valid while the scope is.
pub fn current() ?*const AutomationRoots {
    if (scope) |s| {
        return switch (s) {
            .confined => |r| r,
            .unconfined => null,
        };
    }
    return process_roots.load(.acquire);
}

/// May `path` be read here? `null`: yes, always, without roots in force.
pub fn checkRead(path: []const u8) !?[]u8 {
    const r = current() orelse return null;
    return r.check(path, .read);
}

/// May `path` be written here? `null`: yes, always, without roots in force.
pub fn checkWrite(path: []const u8) !?[]u8 {
    const r = current() orelse return null;
    return r.check(path, .write);
}

const seps: []const u8 = if (builtin.os.tag == .windows) "/\\" else "/";
const sep: u8 = std.fs.path.sep;

fn isSep(c: u8) bool {
    return std.mem.indexOfScalar(u8, seps, c) != null;
}

fn componentsOf(s: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, s, seps);
}

/// `path` without Windows' `\\?\` prefix (which `canonicalize` adds), for people to read. Owned by
/// the caller; off Windows it is a copy.
fn plain(gpa: Allocator, path: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return gpa.dupe(u8, path);
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) return std.fmt.allocPrint(gpa, "\\\\{s}", .{path[8..]});
    if (std.mem.startsWith(u8, path, "\\\\?\\")) return gpa.dupe(u8, path[4..]);
    return gpa.dupe(u8, path);
}

const Resolution = union(enum) {
    /// Absolute, links followed (owned by the caller).
    resolved: []u8,
    /// Why the path is refused (owned by the caller).
    rejected: []u8,
};

fn reject(gpa: Allocator, comptime fmt: []const u8, args: anytype) !Resolution {
    return .{ .rejected = try std.fmt.allocPrint(gpa, fmt, args) };
}

/// `path` made absolute with its links followed; for a path that doesn't exist (yet), its nearest
/// existing folder's links followed and the rest appended.
fn resolve(self: *const AutomationRoots, path: []const u8) !Resolution {
    const gpa = self.gpa;
    if (path.len == 0) return reject(gpa, "automation path rejected: path is empty", .{});
    // Checked as given: making `…\NUL` absolute gives the device path `\\.\NUL` on Windows.
    if (builtin.os.tag == .windows) {
        var it = componentsOf(path);
        while (it.next()) |c| {
            if (isDeviceName(c)) return reject(gpa, "automation path rejected: reserved device names are not allowed: {s}", .{path});
        }
    }
    const absolute = absolutePath(gpa, self.io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return reject(gpa, "automation path rejected: cannot resolve {s}: {s}", .{ path, @errorName(e) }),
    };
    defer gpa.free(absolute);

    const cwd = std.Io.Dir.cwd();
    // The names below the nearest existing folder, last first.
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    var at: []const u8 = absolute;
    while (true) {
        var real_err: anyerror = undefined;
        if (cwd.realPathFileAlloc(self.io, at, gpa)) |real| {
            defer gpa.free(real);
            return .{ .resolved = try joinTail(gpa, real, missing.items) };
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            real_err = err;
        }
        if (cwd.statFile(self.io, at, .{ .follow_symlinks = false })) |meta| {
            if (meta.kind == .sym_link) {
                return reject(gpa, "automation path rejected: a link that leads nowhere: {s}", .{path});
            }
            // There, yet its real path can't be had (no permission): nothing to compare.
            return reject(gpa, "automation path rejected: cannot resolve {s}: {s}", .{ path, @errorName(real_err) });
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return reject(gpa, "automation path rejected: cannot resolve {s}: {s}", .{ path, @errorName(err) }),
        }
        const tail = splitTail(at) orelse
            return reject(gpa, "automation path rejected: cannot resolve {s}: {s}", .{ path, @errorName(error.FileNotFound) });
        if (std.mem.eql(u8, tail.name, "..")) {
            return reject(gpa, "automation path rejected: parent traversal below a folder that doesn't exist: {s}", .{path});
        }
        try missing.append(gpa, tail.name);
        at = tail.parent;
    }
}

const Tail = struct { parent: []const u8, name: []const u8 };

/// The last name of `at` and the path above it; `null` for a root (`/`, `C:\`).
fn splitTail(at: []const u8) ?Tail {
    const i = std.mem.lastIndexOfAny(u8, at, seps) orelse return null;
    const name = at[i + 1 ..];
    if (name.len == 0) return null;
    var parent = at[0..i];
    if (parent.len == 0) {
        parent = at[0..1];
    } else if (parent.len == 2 and parent[1] == ':') {
        parent = at[0 .. i + 1];
    }
    return .{ .parent = parent, .name = name };
}

/// `base` followed by the names, in order, each after a separator. Owned by the caller.
fn joinTail(gpa: Allocator, base: []const u8, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    var i = names.len;
    while (i > 0) {
        i -= 1;
        if (out.items.len == 0 or out.items[out.items.len - 1] != sep) try out.append(gpa, sep);
        try out.appendSlice(gpa, names[i]);
    }
    return out.toOwnedSlice(gpa);
}

/// `path` made absolute against the working directory, without touching the file system: `.`
/// dropped, `..` kept (the file system resolves it, after the links are followed). Owned by the caller.
fn absolutePath(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    if (!std.fs.path.isAbsolute(path)) {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        try raw.appendSlice(gpa, cwd);
        try raw.append(gpa, sep);
    }
    try raw.appendSlice(gpa, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (raw.items.len > 0 and isSep(raw.items[0])) try out.append(gpa, sep);
    var it = componentsOf(raw.items);
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != sep) try out.append(gpa, sep);
        try out.appendSlice(gpa, segment);
    }
    return out.toOwnedSlice(gpa);
}

/// Is `path` (resolved) `root` or inside it, component by component (without regard to case on
/// Windows, whose file systems ignore it)?
fn inside(path: []const u8, root: []const u8) bool {
    var p = componentsOf(path);
    var r = componentsOf(root);
    while (r.next()) |rc| {
        const pc = p.next() orelse return false;
        if (!sameComponent(pc, rc)) return false;
    }
    return true;
}

fn sameComponent(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (builtin.os.tag != .windows) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

/// A Windows device name (`CON`, `NUL`, `COM1`… also with an extension), which names no file.
fn isDeviceName(component: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, component, '.') orelse component.len;
    const stem = std.mem.trimEnd(u8, component[0..dot], " ");
    if (stem.len == 0 or stem.len > 8) return false;
    var buf: [8]u8 = undefined;
    const upper = std.ascii.upperString(buf[0..stem.len], stem);
    const fixed = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" };
    for (fixed) |name| {
        if (std.mem.eql(u8, upper, name)) return true;
    }
    if (upper.len == 4 and (std.mem.startsWith(u8, upper, "COM") or std.mem.startsWith(u8, upper, "LPT"))) {
        return upper[3] >= '1' and upper[3] <= '9';
    }
    return false;
}

// --- tests ---

/// A fresh temporary folder with `in` (read root), `in/sub`, `in2`, `out`, `out2` and `outside`,
/// holding `in/a.scraft`, `in2/b.scraft`, `outside/secret.scraft` and `parent.scraft`. Paths are
/// built in an arena (freed with the fixture); roots use `testing.allocator` so leaks are caught.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const base = try arena.allocator().dupe(u8, buf[0..n]);
        for ([_][]const u8{ "in/sub", "in2", "out", "out2", "outside" }) |d| {
            try tmp.dir.createDirPath(testing.io, d);
        }
        for ([_][]const u8{ "in/a.scraft", "in2/b.scraft", "outside/secret.scraft", "parent.scraft" }) |p| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = p, .data = "x" });
        }
        return .{ .tmp = tmp, .arena = arena, .base = base };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// The absolute path of `rel` inside the fixture (arena-owned).
    fn path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{c}{s}", .{ self.base, std.fs.path.sep, rel });
    }

    /// Roots given by fixture-relative paths.
    fn roots(self: *Fixture, read: []const []const u8, write: []const []const u8) !AutomationRoots {
        const a = self.arena.allocator();
        const r = try a.alloc([]const u8, read.len);
        for (read, r) |rel, *out| out.* = try self.path(rel);
        const w = try a.alloc([]const u8, write.len);
        for (write, w) |rel, *out| out.* = try self.path(rel);
        return (try AutomationRoots.new(testing.allocator, testing.io, r, w, null)).?;
    }
};

fn expectAllowed(roots: *const AutomationRoots, path: []const u8, access: Access) !void {
    const message = try roots.check(path, access);
    if (message) |m| {
        defer roots.gpa.free(m);
        std.debug.print("expected `{s}` to be allowed, got: {s}\n", .{ path, m });
        return error.TestUnexpectedDenial;
    }
}

fn expectDenied(roots: *const AutomationRoots, path: []const u8, access: Access, needle: []const u8) !void {
    const message = (try roots.check(path, access)) orelse {
        std.debug.print("expected `{s}` to be denied\n", .{path});
        return error.TestExpectedDenial;
    };
    defer roots.gpa.free(message);
    if (std.mem.indexOf(u8, message, needle) == null) {
        std.debug.print("denial of `{s}` lacks `{s}`: {s}\n", .{ path, needle, message });
        return error.TestWrongDenial;
    }
}

/// Creates a symbolic link (absolute target). `false` when the platform refuses (Windows without
/// Developer Mode or elevation); the caller then skips.
fn makeLink(target: []const u8, link_path: []const u8, is_dir: bool) bool {
    std.Io.Dir.symLinkAbsolute(testing.io, target, link_path, .{ .is_directory = is_dir }) catch return false;
    return true;
}

test "paths inside the roots pass and others don't" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{"out"});
    defer roots.deinit();
    try expectAllowed(&roots, try f.path("in/a.scraft"), .read);
    try expectAllowed(&roots, try f.path("in"), .read); // the root itself
    try expectAllowed(&roots, try f.path("in/sub/new.scraft"), .read); // missing files are checked by their folder
    try expectAllowed(&roots, try f.path("out/new/deeper/x.wav"), .write); // and by their nearest folder
    try expectDenied(&roots, try f.path("outside/secret.scraft"), .read, "outside the read root");
    // Read and write access are separate.
    try expectDenied(&roots, try f.path("in/a.scraft"), .write, "outside the write root");
    try expectDenied(&roots, try f.path("out/x.wav"), .read, "outside the read root");
}

test "a sibling with the same prefix is outside" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{});
    defer roots.deinit();
    try expectDenied(&roots, try f.path("in2/b.scraft"), .read, "outside the read root"); // in2 is not inside in
    const sibling = try std.fmt.allocPrint(f.arena.allocator(), "{s}2/c.scraft", .{try f.path("in")});
    try expectDenied(&roots, sibling, .read, "outside the read root");
}

test "parent traversal is resolved or refused" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{"out"});
    defer roots.deinit();
    try expectDenied(&roots, try f.path("in/../outside/secret.scraft"), .read, "outside the read root"); // `..` out of the root
    try expectAllowed(&roots, try f.path("in/sub/../a.scraft"), .read); // `..` that stays inside
    // Windows resolves `..` by name first (so does opening the file there): then it's outside.
    const missing = try f.path("out/nope/../../outside/x.scraft");
    const message = (try roots.check(missing, .write)) orelse return error.TestExpectedDenial;
    defer roots.gpa.free(message);
    const refused = std.mem.indexOf(u8, message, "parent traversal below a folder that doesn't exist") != null or
        std.mem.indexOf(u8, message, "outside the write root") != null;
    try testing.expect(refused);
}

test "relative paths resolve against the working directory" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{});
    defer roots.deinit();
    // The tests' working directory is the repository (or the test runner's): not inside the roots.
    try expectDenied(&roots, "a.scraft", .read, "outside the read root");
    try expectDenied(&roots, "", .read, "path is empty");
}

test "a missing root is an error and none is no confinement" {
    var f = try Fixture.init();
    defer f.deinit();
    var failure: RootFailure = undefined;
    try testing.expectError(error.CannotOpenRoot, AutomationRoots.new(testing.allocator, testing.io, &.{try f.path("nope")}, &.{}, &failure));
    try testing.expectEqual(Access.read, failure.access);
    const msg = try rootFailureMessage(testing.allocator, failure);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.startsWith(u8, msg, "cannot open the automation read root"));

    // A write root that is a file, not a folder.
    try testing.expectError(error.CannotOpenRoot, AutomationRoots.new(testing.allocator, testing.io, &.{}, &.{try f.path("in/a.scraft")}, &failure));
    try testing.expectEqual(Access.write, failure.access);
    const msg2 = try rootFailureMessage(testing.allocator, failure);
    defer testing.allocator.free(msg2);
    try testing.expect(std.mem.startsWith(u8, msg2, "cannot open the automation write root"));

    try testing.expectError(error.CannotOpenRoot, AutomationRoots.new(testing.allocator, testing.io, &.{""}, &.{}, &failure));
    const msg3 = try rootFailureMessage(testing.allocator, failure);
    defer testing.allocator.free(msg3);
    try testing.expect(std.mem.startsWith(u8, msg3, "cannot open the automation read root ``"));

    try testing.expect((try AutomationRoots.new(testing.allocator, testing.io, &.{}, &.{}, null)) == null);

    // One root alone grants only its own access.
    var read_only = try f.roots(&.{"in"}, &.{});
    defer read_only.deinit();
    try expectDenied(&read_only, try f.path("in/x.scraft"), .write, "write authority is absent");
}

test "links are followed before comparing" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{"out"});
    defer roots.deinit();
    // A file link out of the root. Windows needs Developer Mode or elevation to make links.
    if (!makeLink(try f.path("outside/secret.scraft"), try f.path("in/leak.scraft"), false)) return error.SkipZigTest;
    try expectDenied(&roots, try f.path("in/leak.scraft"), .read, "outside the read root");
    // A folder link out of the root.
    try testing.expect(makeLink(try f.path("outside"), try f.path("out/away"), true));
    try expectDenied(&roots, try f.path("out/away/new.wav"), .write, "outside the write root");
    // A link to a file that doesn't exist: writing would create the file outside.
    try testing.expect(makeLink(try f.path("outside/gone.scraft"), try f.path("out/dangling.wav"), false));
    try expectDenied(&roots, try f.path("out/dangling.wav"), .write, "a link that leads nowhere");
    // A link to a folder inside the root stays inside.
    try testing.expect(makeLink(try f.path("in/sub"), try f.path("in/alias"), true));
    try expectAllowed(&roots, try f.path("in/alias/x.scraft"), .read);
    // A root given through a link is the folder it leads to.
    try testing.expect(makeLink(try f.path("in"), try f.path("in-link"), true));
    var linked = (try AutomationRoots.new(testing.allocator, testing.io, &.{try f.path("in-link")}, &.{}, null)).?;
    defer linked.deinit();
    try expectAllowed(&linked, try f.path("in/a.scraft"), .read);
}

// Several roots of a kind: a path inside any of them passes, one inside none is refused naming
// them all, and read and write stay separate.
test "several roots of a kind each grant their access" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{ "in", "in2" }, &.{ "out", "out2" });
    defer roots.deinit();
    try expectAllowed(&roots, try f.path("in/a.scraft"), .read);
    try expectAllowed(&roots, try f.path("in2/b.scraft"), .read);
    try expectDenied(&roots, try f.path("outside/secret.scraft"), .read, "outside the read roots");
    // Two sibling roots don't make their parent a root.
    try expectDenied(&roots, try f.path("parent.scraft"), .read, "outside the read roots");
    try expectDenied(&roots, f.base, .read, "outside the read roots");
    try expectAllowed(&roots, try f.path("out/x.wav"), .write);
    try expectAllowed(&roots, try f.path("out2/new/x.wav"), .write);
    try expectDenied(&roots, try f.path("outside/x.wav"), .write, "outside the write roots");
    try expectDenied(&roots, try f.path("x.wav"), .write, "outside the write roots");
    try expectDenied(&roots, try f.path("in2/b.scraft"), .write, "outside the write roots");
    try expectDenied(&roots, try f.path("out2/x.wav"), .read, "outside the read roots");
    // `..` out of one root is outside, also when it lands next to another root.
    try expectDenied(&roots, try f.path("in2/../outside/secret.scraft"), .read, "outside the read roots");
    // `..` from one root into another stays inside.
    try expectAllowed(&roots, try f.path("in2/../in/a.scraft"), .read);
    // A folder given twice (here once through `..`) counts once.
    var twice = (try AutomationRoots.new(testing.allocator, testing.io, &.{ try f.path("in"), try f.path("in/sub/..") }, &.{}, null)).?;
    defer twice.deinit();
    const described = try twice.describe();
    defer testing.allocator.free(described);
    try testing.expect(std.mem.indexOf(u8, described, ", ") == null);
    try testing.expect(std.mem.endsWith(u8, described, "; write none"));
    // A missing folder among several is an error.
    var failure: RootFailure = undefined;
    try testing.expectError(error.CannotOpenRoot, AutomationRoots.new(testing.allocator, testing.io, &.{ try f.path("in"), try f.path("nope") }, &.{}, &failure));
    const msg = try rootFailureMessage(testing.allocator, failure);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.startsWith(u8, msg, "cannot open the automation read root"));
}

// A link inside one root that leads into another root of the same kind stays inside; one that
// leads out of all of them is outside.
test "links between several roots" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{ "in", "in2" }, &.{});
    defer roots.deinit();
    if (!makeLink(try f.path("in2/b.scraft"), try f.path("in/to-in2.scraft"), false)) return error.SkipZigTest;
    try testing.expect(makeLink(try f.path("outside/secret.scraft"), try f.path("in2/leak.scraft"), false));
    try testing.expect(makeLink(f.base, try f.path("in2/up"), true));
    try expectAllowed(&roots, try f.path("in/to-in2.scraft"), .read);
    try expectDenied(&roots, try f.path("in2/leak.scraft"), .read, "outside the read roots");
    try expectDenied(&roots, try f.path("in2/up/outside/secret.scraft"), .read, "outside the read roots");
}

test "windows ignores case and refuses device names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // Windows only, as in the Rust test
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{"out"});
    defer roots.deinit();
    try expectAllowed(&roots, try f.path("IN/a.scraft"), .read);
    try expectAllowed(&roots, try f.path("In/Sub/New.scraft"), .read);
    try expectDenied(&roots, try f.path("out/NUL"), .write, "reserved device names");
    try expectDenied(&roots, try f.path("out/com1.txt"), .write, "reserved device names");
    try expectAllowed(&roots, try f.path("out/console.txt"), .write);
}

fn readAllowed(path: []const u8) !bool {
    const message = (try checkRead(path)) orelse return true;
    testing.allocator.free(message);
    return false;
}

fn readAllowedInThread(path: []const u8, out: *bool) void {
    out.* = readAllowed(path) catch false;
}

fn checksWhileConfined(outside: []const u8) !void {
    try testing.expect(!try readAllowed(outside));
    try testing.expect(try unconfined(readAllowed, .{outside}));
    try testing.expect(!try readAllowed(outside)); // restored after unconfined
    // Another thread is not confined by this thread's scope.
    var there = false;
    const t = try std.Thread.spawn(.{}, readAllowedInThread, .{ outside, &there });
    t.join();
    try testing.expect(there);
}

// Zig has no unwinding: an error return plays the part of the Rust panic.
fn failsWhileConfined(outside: []const u8) !void {
    _ = outside;
    return error.Boom;
}

test "scopes nest and stay on their thread" {
    var f = try Fixture.init();
    defer f.deinit();
    var roots = try f.roots(&.{"in"}, &.{"out"});
    defer roots.deinit();
    const outside = try f.path("outside/secret.scraft");
    try testing.expect(try readAllowed(outside)); // nothing is confined by default
    try confine(&roots, checksWhileConfined, .{outside});
    try testing.expect(try readAllowed(outside)); // restored after confine
    try testing.expectError(error.Boom, confine(&roots, failsWhileConfined, .{outside}));
    try testing.expect(try readAllowed(outside)); // restored after the error
    try testing.expect(try confine(null, readAllowed, .{outside}));
}

test "device names" {
    for ([_][]const u8{ "CON", "nul", "Com1", "LPT9.txt", "aux.scraft", "NUL " }) |d| {
        try testing.expect(isDeviceName(d));
    }
    for ([_][]const u8{ "console", "com10", "COM0", "lpt", "a.scraft", "nul-x" }) |f| {
        try testing.expect(!isDeviceName(f));
    }
}

// Every file a command reads or writes by path goes through the checked helpers (`checkRead`,
// `checkWrite` and the file-system wrappers that call them), so engine code that reaches for the
// file system itself would bypass the roots. The session library's files may not, except the
// gateway and this module's own gateway files (`io.zig`, `file_access.zig`, `autosave.zig`).
// `autosave.zig` writes crash-recovery copies in the app's own data folder, which no command
// names. Files named `tests*.zig` are test-only.
//
// The session sources are found from the working directory upward (`libs/session/src`); the
// build does not pass the repository root to this test, so the test is skipped when the sources
// are not reachable from where the test runs.
test "commands do not touch the file system themselves" {
    const gpa = testing.allocator;
    const io = testing.io;
    const candidates = [_][]const u8{ "libs/session/src", "../libs/session/src", "../../libs/session/src", "../../../libs/session/src" };
    var src: ?std.Io.Dir = null;
    for (candidates) |c| {
        src = std.Io.Dir.cwd().openDir(io, c, .{ .iterate = true }) catch continue;
        break;
    }
    var session_src = src orelse return error.SkipZigTest;
    defer session_src.close(io);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try collectZig(gpa, io, session_src, "", &files);
    var found_root = false;
    var found_command = false;
    for (files.items) |f| {
        if (std.mem.eql(u8, f, "root.zig")) found_root = true;
        if (std.mem.eql(u8, f, "command.zig")) found_command = true;
    }
    try testing.expect(found_root and found_command);

    const touches = [_][]const u8{
        "std.fs",         "std.Io.Dir",  "openFile", "createFile", "openDir",
        "readFileAlloc",  "writeFile",   "realPath", "statFile",   "std.c.open",
        "std.posix.open", "std.c.fopen",
    };
    const allowed = [_][]const u8{ "io.zig", "file_access.zig", "autosave.zig" };
    var offenders: std.ArrayList(u8) = .empty;
    defer offenders.deinit(gpa);
    for (files.items) |rel| {
        if (std.mem.indexOfScalar(u8, rel, '/') == null) {
            var skip = false;
            for (allowed) |a| {
                if (std.mem.eql(u8, rel, a)) skip = true;
            }
            if (skip) continue;
        }
        if (std.mem.startsWith(u8, std.fs.path.basename(rel), "tests")) continue;
        const text = try session_src.readFileAlloc(io, rel, gpa, .limited(16 << 20));
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| : (line_no += 1) {
            // Inline test blocks come last in each file: stop at the first top-level one.
            if (std.mem.startsWith(u8, raw, "test ") or std.mem.startsWith(u8, raw, "test{")) break;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "//")) continue;
            for (touches) |w| {
                if (std.mem.indexOf(u8, line, w) != null) {
                    try offenders.print(gpa, "{s}:{d}: {s}\n", .{ rel, line_no + 1, line });
                    break;
                }
            }
        }
    }
    if (offenders.items.len > 0) {
        std.debug.print("use the checked helpers (checkRead, checkWrite): {s}", .{offenders.items});
    }
    try testing.expectEqual(@as(usize, 0), offenders.items.len);
}

/// Adds every `.zig` file below `dir` to `out` as a path relative to the session source folder.
fn collectZig(gpa: Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]u8)) anyerror!void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        defer gpa.free(rel);
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try collectZig(gpa, io, sub, rel, out);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) try out.append(gpa, try gpa.dupe(u8, rel));
            },
            else => {},
        }
    }
}
