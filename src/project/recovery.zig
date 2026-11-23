//! Autosave and crash recovery paths and marker logic.
//!
//! Layout, under $XDG_CONFIG_HOME/seridian/daw/recovery (fallback ~/.config/...):
//!   session/   the autosaved project, written with the normal project save code
//!   clean      marker written on a normal quit
//!
//! The marker is removed at startup ("running"), so a crash leaves a session copy
//! with no marker. A pending recovery is: session/project.daw exists and no marker.
//! The user's own session folder is never touched.

const std = @import("std");
const sys = @import("../utils/sys.zig");

const log = std.log.scoped(.recovery);

pub const SUBDIR = "seridian/daw/recovery";
pub const SESSION_DIR = "session";
pub const MARKER_FILE = "clean";
pub const PROJECT_FILE = "project.daw";

pub const Error = error{ NoHomeDirectory, PathTooLong };

/// Recovery directory inside the given config directory.
pub fn recoveryDirIn(allocator: std.mem.Allocator, config_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ config_dir, SUBDIR });
}

/// Recovery directory for this user. An empty or relative XDG_CONFIG_HOME is ignored per the XDG spec.
pub fn recoveryDir(allocator: std.mem.Allocator) ![]u8 {
    if (sys.getenv("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) return recoveryDirIn(allocator, xdg);
    }
    const home = sys.getenv("HOME") orelse return error.NoHomeDirectory;
    const config = try std.fs.path.join(allocator, &.{ home, ".config" });
    defer allocator.free(config);
    return recoveryDirIn(allocator, config);
}

pub fn sessionPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir, SESSION_DIR });
}

pub fn markerPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir, MARKER_FILE });
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(sys.io(), path, .{}) catch return false;
    return true;
}

/// True when a recovery copy exists and the clean-exit marker is absent.
pub fn isPending(allocator: std.mem.Allocator, dir: []const u8) !bool {
    const project = try std.fs.path.join(allocator, &.{ dir, SESSION_DIR, PROJECT_FILE });
    defer allocator.free(project);
    const marker = try markerPath(allocator, dir);
    defer allocator.free(marker);
    return exists(project) and !exists(marker);
}

/// Creates the session folder (and parents) and returns its path. Caller frees.
pub fn prepareSession(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const session = try sessionPath(allocator, dir);
    errdefer allocator.free(session);
    try sys.makePath(session);
    return session;
}

/// Startup: the app is running, so the clean marker no longer applies.
pub fn markRunning(allocator: std.mem.Allocator, dir: []const u8) !void {
    const marker = try markerPath(allocator, dir);
    defer allocator.free(marker);
    std.Io.Dir.cwd().deleteFile(sys.io(), marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Deletes the recovery copy. Missing is not an error.
pub fn discard(allocator: std.mem.Allocator, dir: []const u8) !void {
    const session = try sessionPath(allocator, dir);
    defer allocator.free(session);
    try std.Io.Dir.cwd().deleteTree(sys.io(), session);
}

/// Normal quit: delete the recovery copy, then write the marker.
pub fn markClean(allocator: std.mem.Allocator, dir: []const u8) !void {
    try discard(allocator, dir);
    try sys.makePath(dir);
    const marker = try markerPath(allocator, dir);
    defer allocator.free(marker);
    try sys.writeFileAtomic(marker, "clean\n");
}

// =============================================================================
// C API. Paths are returned in static buffers; the UI thread is the only caller.
// =============================================================================

var g_session_buf: [1024]u8 = undefined;

fn withDir(comptime T: type, comptime failure: T, comptime f: fn (std.mem.Allocator, []const u8) anyerror!T) T {
    const allocator = std.heap.page_allocator;
    const dir = recoveryDir(allocator) catch |err| {
        log.warn("recovery directory unavailable: {}", .{err});
        return failure;
    };
    defer allocator.free(dir);
    return f(allocator, dir) catch |err| {
        log.warn("recovery operation failed: {}", .{err});
        return failure;
    };
}

fn pendingFn(a: std.mem.Allocator, dir: []const u8) anyerror!c_int {
    return if (try isPending(a, dir)) 1 else 0;
}
fn runningFn(a: std.mem.Allocator, dir: []const u8) anyerror!c_int {
    try markRunning(a, dir);
    return 0;
}
fn cleanFn(a: std.mem.Allocator, dir: []const u8) anyerror!c_int {
    try markClean(a, dir);
    return 0;
}
fn discardFn(a: std.mem.Allocator, dir: []const u8) anyerror!c_int {
    try discard(a, dir);
    return 0;
}
fn sessionFn(a: std.mem.Allocator, dir: []const u8) anyerror!c_int {
    const session = try prepareSession(a, dir);
    defer a.free(session);
    if (session.len >= g_session_buf.len) return error.PathTooLong;
    @memcpy(g_session_buf[0..session.len], session);
    g_session_buf[session.len] = 0;
    return 0;
}

/// 1 when a recovery copy exists and the previous run did not exit cleanly, else 0.
pub export fn recovery_pending() callconv(.c) c_int {
    return withDir(c_int, 0, pendingFn);
}

/// Removes the clean marker at startup. Returns 0 on success.
pub export fn recovery_mark_running() callconv(.c) c_int {
    return withDir(c_int, -1, runningFn);
}

/// Deletes the recovery copy and writes the clean marker. Returns 0 on success.
pub export fn recovery_mark_clean() callconv(.c) c_int {
    return withDir(c_int, -1, cleanFn);
}

/// Deletes the recovery copy. Returns 0 on success.
pub export fn recovery_discard() callconv(.c) c_int {
    return withDir(c_int, -1, discardFn);
}

/// Creates the recovery session folder and returns its path (valid until the next call), or NULL.
pub export fn recovery_session_path() callconv(.c) ?[*:0]const u8 {
    if (withDir(c_int, -1, sessionFn) != 0) return null;
    return @ptrCast(&g_session_buf);
}

// =============================================================================
// Tests
// =============================================================================

fn tmpRoot(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(sys.io(), ".", allocator);
}

test "recoveryDirIn appends the seridian/daw/recovery subpath" {
    const dir = try recoveryDirIn(std.testing.allocator, "/home/u/.config");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/home/u/.config/seridian/daw/recovery", dir);
}

test "session and marker paths live inside the recovery directory" {
    const a = std.testing.allocator;
    const s = try sessionPath(a, "/r");
    defer a.free(s);
    const m = try markerPath(a, "/r");
    defer a.free(m);
    try std.testing.expectEqualStrings("/r/session", s);
    try std.testing.expectEqualStrings("/r/clean", m);
}

fn writeFakeSession(a: std.mem.Allocator, dir: []const u8) !void {
    const session = try prepareSession(a, dir);
    defer a.free(session);
    const project = try std.fs.path.join(a, &.{ session, PROJECT_FILE });
    defer a.free(project);
    try sys.writeFileAtomic(project, "x");
}

test "not pending when nothing exists" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    const dir = try recoveryDirIn(a, root);
    defer a.free(dir);
    try std.testing.expect(!try isPending(a, dir));
}

test "a session copy without the marker is pending" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    const dir = try recoveryDirIn(a, root);
    defer a.free(dir);
    try writeFakeSession(a, dir);
    try std.testing.expect(try isPending(a, dir));
}

test "a session copy with the marker is not pending" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    const dir = try recoveryDirIn(a, root);
    defer a.free(dir);
    try writeFakeSession(a, dir);
    const marker = try markerPath(a, dir);
    defer a.free(marker);
    try sys.writeFileAtomic(marker, "clean\n");
    try std.testing.expect(!try isPending(a, dir));
}

test "markClean deletes the copy and writes the marker; markRunning removes it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    const dir = try recoveryDirIn(a, root);
    defer a.free(dir);
    try writeFakeSession(a, dir);

    try markClean(a, dir);
    const session = try sessionPath(a, dir);
    defer a.free(session);
    const marker = try markerPath(a, dir);
    defer a.free(marker);
    try std.testing.expect(!exists(session));
    try std.testing.expect(exists(marker));
    try std.testing.expect(!try isPending(a, dir));

    try markRunning(a, dir);
    try std.testing.expect(!exists(marker));
    // Idempotent when already absent.
    try markRunning(a, dir);
}

test "a crash after markRunning leaves a pending copy; discard clears it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    const dir = try recoveryDirIn(a, root);
    defer a.free(dir);

    try markClean(a, dir); // previous run quit cleanly
    try markRunning(a, dir); // this run starts
    try writeFakeSession(a, dir); // autosave, then crash
    try std.testing.expect(try isPending(a, dir));

    try discard(a, dir);
    try std.testing.expect(!try isPending(a, dir));
    try discard(a, dir); // missing is fine
}
