//! Process-wide system helpers for the Zig `std.Io` API.
//!
//! The DAW does blocking file I/O (config, projects, WAV import/export) from
//! the UI thread only, so one single-threaded `Io` instance is enough. The
//! audio thread must never call into these helpers.

const std = @import("std");

var io_configured: bool = false;

/// The process `Io` used for file-system access and process spawning.
pub fn io() std.Io {
    const threaded = std.Io.Threaded.global_single_threaded;
    if (!io_configured) {
        // The global Io starts with a failing allocator, which makes process
        // spawning fail with OutOfMemory (so audio-server detection silently found nothing and the
        // engine fell back to the null backend). Give it the C allocator once.
        threaded.allocator = std.heap.c_allocator;
        // It also starts with an empty environment, and spawned children inherit
        // exactly that. pactl then had no XDG_RUNTIME_DIR or PULSE_SERVER, could not
        // find the sound server, and exited 1. Hand it the real process environment.
        const c_environ = std.c.environ;
        var count: usize = 0;
        while (c_environ[count] != null) : (count += 1) {}
        const block: std.process.Environ.Block = .{ .slice = c_environ[0..count :null] };
        threaded.environ = .{ .process_environ = .{ .block = block } };
        threaded.environ_initialized = block.isEmpty();
        io_configured = true;
    }
    return threaded.io();
}

/// Give the global `Io` an allocator (needed for process spawning).
/// Call once at startup before any I/O.
pub fn setIoAllocator(allocator: std.mem.Allocator) void {
    std.Io.Threaded.global_single_threaded.allocator = allocator;
}

/// Read an environment variable from libc's environment.
pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Monotonic clock in nanoseconds.
pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Monotonic clock in milliseconds.
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

/// Wall clock (Unix epoch) in seconds.
pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// Sleep the calling thread (never call on the audio thread).
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (std.c.nanosleep(&req, &req) != 0) {}
}

/// Short-critical-section lock shared by the UI and audio threads.
/// The audio thread should use `tryLock` and skip work when contended.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn tryLock(self: *SpinLock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *SpinLock) void {
        while (!self.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

test "spin lock excludes" {
    var l: SpinLock = .{};
    try std.testing.expect(l.tryLock());
    try std.testing.expect(!l.tryLock());
    l.unlock();
    try std.testing.expect(l.tryLock());
}

test "getenv reads the environment" {
    try std.testing.expect(getenv("TALKIES_DAW_SURELY_UNSET_VAR") == null);
}

/// Run a command to completion with no stdio; true when it exits 0.
pub fn runSucceeds(argv: []const []const u8) bool {
    var child = std.process.spawn(io(), .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io()) catch return false;
    return term.success();
}

/// Run a command and return its stdout (caller frees). Fails on a non-zero exit.
pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.spawn(io(), .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch |err| {
        std.debug.print("runCapture: spawn of {s} failed: {}\n", .{ argv[0], err });
        return err;
    };
    const stdout = child.stdout orelse return error.NoStdout;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(io(), &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try output.appendSlice(allocator, buffer[0..n]);
    }
    const term = try child.wait(io());
    if (!term.success()) {
        std.debug.print("runCapture: {s} terminated abnormally: {any} (stdout {d} bytes)\n", .{ argv[0], term, output.items.len });
        return error.CommandFailed;
    }
    return output.toOwnedSlice(allocator);
}

/// Read a whole file into memory (caller frees).
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(max_bytes));
}

/// Write `data` to `path`, replacing it atomically.
pub fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = data });
}

/// mkdir -p
pub fn makePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), path);
}

test "runSucceeds can spawn a child process without setup" {
    try std.testing.expect(runSucceeds(&.{"true"}));
    try std.testing.expect(!runSucceeds(&.{"false"}));
}
