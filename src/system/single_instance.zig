//! Single-instance rule for `seridian-studio`: one app owns the control socket
//! `$XDG_RUNTIME_DIR/seridian.sock`; a second launch must not open a window.
//!
//! `decide` is the pure rule, `probe` looks at the socket. The wiring is in src/main.zig.
//! There is no clean way to raise the running window: the wm layer (src/cli/wm) only lists,
//! floats, moves and resizes, and the control socket has no raise command, so the second
//! launch reports the pid and exits without raising.

const std = @import("std");
const builtin = @import("builtin");

/// What looking at the control socket found.
pub const Probe = enum {
    /// Nothing at the path.
    absent,
    /// A socket file exists and a process accepted a connection.
    live,
    /// A file exists but nobody listens (connect refused): left behind by a crash.
    stale,
};

pub const Decision = enum {
    /// Run normally.
    start,
    /// Another instance owns the socket: report it and exit 0.
    already_running,
    /// Remove the dead socket file, then run normally.
    replace_stale,
};

pub fn decide(probe_result: Probe) Decision {
    return switch (probe_result) {
        .absent => .start,
        .live => .already_running,
        .stale => .replace_stale,
    };
}

/// Result of `probe`: the state, and the owner's pid when it is live and the kernel told us.
pub const ProbeResult = struct {
    state: Probe,
    pid: ?i32 = null,
};

const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

/// Connects to the Unix socket at `path` and reports who owns it. A refused connect on an
/// existing file is `stale`; any other failure (no file, no permission, path too long) is
/// `absent`, so an unknown situation never deletes anything.
pub fn probe(path: []const u8) ProbeResult {
    if (comptime builtin.os.tag != .linux) return .{ .state = .absent };
    var address: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
    address.family = std.c.AF.UNIX;
    if (path.len == 0 or path.len >= address.path.len) return .{ .state = .absent };
    @memcpy(address.path[0..path.len], path);

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return .{ .state = .absent };
    defer _ = std.c.close(fd);

    if (std.c.connect(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)) != 0) {
        const code: std.c.E = @fromBackingInt(@intCast(std.c._errno().*));
        return .{ .state = if (code == .CONNREFUSED) .stale else .absent };
    }
    var cred: Ucred = .{ .pid = 0, .uid = 0, .gid = 0 };
    var length: std.c.socklen_t = @sizeOf(Ucred);
    if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.os.linux.SO.PEERCRED, &cred, &length) != 0 or cred.pid <= 0) {
        return .{ .state = .live };
    }
    return .{ .state = .live, .pid = cred.pid };
}

/// Removes a stale socket file. Returns false when it could not be removed.
pub fn removeStale(path: [:0]const u8) bool {
    return std.c.unlink(path.ptr) == 0;
}

test "single instance: decide maps each probe result to one outcome" {
    try std.testing.expectEqual(Decision.start, decide(.absent));
    try std.testing.expectEqual(Decision.already_running, decide(.live));
    try std.testing.expectEqual(Decision.replace_stale, decide(.stale));
}

fn bindSocket(path: []const u8, listening: bool) !std.c.fd_t {
    var address: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
    address.family = std.c.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)) != 0) return error.BindFailed;
    if (listening and std.c.listen(fd, 4) != 0) return error.ListenFailed;
    return fd;
}

test "single instance: probe reports absent, live (with our pid) and stale" {
    var buffer: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "/tmp/seridian-single-instance-{d}.sock", .{std.c.getpid()});
    buffer[text.len] = 0;
    const path: [:0]const u8 = buffer[0..text.len :0];
    _ = std.c.unlink(path.ptr);
    defer _ = std.c.unlink(path.ptr);

    try std.testing.expectEqual(Probe.absent, probe(path).state);

    const live_fd = try bindSocket(path, true);
    const live = probe(path);
    try std.testing.expectEqual(Probe.live, live.state);
    try std.testing.expectEqual(@as(?i32, std.c.getpid()), live.pid);
    _ = std.c.close(live_fd);

    // The file is still there but nobody listens: what a crashed run leaves behind.
    try std.testing.expectEqual(Probe.stale, probe(path).state);
    try std.testing.expect(removeStale(path));
    try std.testing.expectEqual(Probe.absent, probe(path).state);

    // A bound socket that never called listen refuses connections too.
    const idle_fd = try bindSocket(path, false);
    defer _ = std.c.close(idle_fd);
    try std.testing.expectEqual(Probe.stale, probe(path).state);
}
