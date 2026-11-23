// Translated to Zig from soundcraft/crates/automation/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! `Remote`: a TCP client for a running app's JSON-lines control channel. A request is one line of
//! `{"id", "method", "params"}`; a reply is one line of `{"id", "ok", "result" | "error"}`.
//!
//! The connection is opened lazily. A request whose connection was lost is sent once more on a fresh
//! connection only when it only reads state; a state-changing request is never repeated after its
//! line went out, because the app may already have run it (`RemoteError.Unconfirmed`).
//!
//! Sockets are plain blocking POSIX sockets through `std.c` (`std.net` is not in this toolchain;
//! `std.Io.net` needs an `Io` this library does not own). `socket` and `close` are declared here
//! because `std.c` only declares them for some targets. Control thread only: this does socket I/O
//! and JSON parsing, and allocates.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const backend = @import("backend.zig");
const control_target = @import("control_target.zig");
const ControlTarget = control_target.ControlTarget;
const Result = backend.Result;

/// The longest reply line accepted. A broken or hostile peer cannot make the client buffer more
/// (plus one read chunk, the last recv that may overshoot it).
pub const max_line_bytes: usize = 64 * 1024 * 1024;
const read_chunk_bytes: usize = 16 * 1024;
const connect_timeout_ms: c_int = 800;
const read_timeout_sec: c_long = 120;
const detail_max_bytes: usize = 512;

const fd_t = std.c.fd_t;

// Hand-declared: these two are declared inside target-specific blocks of std.c.
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: fd_t) c_int;

/// Non-blocking mode for `fcntl`; the value differs between Linux and the BSD/Darwin family.
const o_nonblock: c_int = if (builtin.os.tag == .linux) 0o4000 else 0x0004;

/// Why a `Remote` request failed. The details (host, app message, errno name) are kept in the
/// `Remote` and read with `errorMessage`.
pub const RemoteError = error{
    OutOfMemory,
    /// The host name didn't resolve.
    Resolve,
    /// The host name resolved to no address.
    NoAddress,
    /// No address accepted the connection.
    Unreachable,
    /// Reading or writing the connection failed for another reason.
    Io,
    ConnectionReset,
    BrokenPipe,
    ConnectionAborted,
    /// The app closed the connection before it replied.
    Closed,
    /// The reply is not JSON, or it is longer than `max_line_bytes`.
    Reply,
    /// The app refused the request; its message is in `errorMessage`.
    App,
    /// The connection was lost after a state-changing request went out: it isn't repeated, since
    /// the app may already have executed it.
    Unconfirmed,
};

/// The connection went away, so a fresh one may succeed.
pub fn isLostConnection(err: RemoteError) bool {
    return switch (err) {
        error.Closed, error.ConnectionReset, error.BrokenPipe, error.ConnectionAborted => true,
        else => false,
    };
}

/// Methods that only read state, so repeating them after a lost reply is harmless.
pub fn isReadOnly(method: []const u8) bool {
    const read_only = [_][]const u8{
        "session.inspect", "document.inspect", "engine.commands", "engine.parity", "ui.inspect", "ui.menu.list",
    };
    for (read_only) |name| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return false;
}

/// A TCP client for a running app's control channel. Keep it at a fixed address once it is used:
/// `Backend.from(&remote)` stores the pointer.
pub const Remote = struct {
    gpa: Allocator,
    /// The target. Its host is owned by this `Remote` (copied in `init`).
    target: ControlTarget,
    /// The open socket, when connected.
    conn: ?fd_t = null,
    next_id: u64 = 1,
    /// Bytes read from the socket past the last complete line.
    rbuf: std.ArrayList(u8) = .empty,
    /// The human-readable detail of the last failure, read with `errorMessage`.
    detail_buf: [detail_max_bytes]u8 = undefined,
    detail_len: usize = 0,

    /// A client for the app at `target`. It connects on the first request.
    pub fn init(gpa: Allocator, target: ControlTarget) Allocator.Error!Remote {
        const host: ?[]const u8 = if (target.host) |h| try gpa.dupe(u8, h) else null;
        return .{ .gpa = gpa, .target = .{ .host = host, .port = target.port } };
    }

    pub fn deinit(self: *Remote) void {
        self.dropConnection();
        self.rbuf.deinit(self.gpa);
        if (self.target.host) |h| self.gpa.free(h);
        self.* = undefined;
    }

    /// The detail of a failure returned by `request`: the app's own message, the reason a connection
    /// failed, or the error name when no detail was recorded. Valid until the next request.
    pub fn errorMessage(self: *const Remote, err: RemoteError) []const u8 {
        if (self.detail_len > 0) return self.detail_buf[0..self.detail_len];
        return @errorName(err);
    }

    /// Calls `method` with `params` and returns the reply's `result`, allocated in `arena`. A request
    /// lost with its connection is sent once more on a fresh one when it only reads state.
    pub fn request(self: *Remote, arena: Allocator, method: []const u8, params: std.json.Value) RemoteError!std.json.Value {
        var sent = false;
        const first_err = if (self.roundtrip(arena, method, params, &sent)) |v| return v else |e| e;
        if (!isLostConnection(first_err)) return first_err;
        self.dropConnection();
        if (sent and !isReadOnly(method)) {
            const inner = try arena.dupe(u8, self.errorMessage(first_err));
            self.setDetail("{s}; `{s}` may or may not have been executed, check the session before repeating it", .{ inner, method });
            return error.Unconfirmed;
        }
        var sent_again = false;
        return self.roundtrip(arena, method, params, &sent_again);
    }

    /// The `Backend` methods: `call` is `request` with the error turned into text.
    pub fn call(self: *Remote, arena: Allocator, method: []const u8, params: std.json.Value) Result {
        const value = self.request(arena, method, params) catch |err| {
            const text = arena.dupe(u8, self.errorMessage(err)) catch return .{ .err = "out of memory" };
            return .{ .err = text };
        };
        return .{ .ok = value };
    }

    pub fn hasUi(self: *Remote) bool {
        _ = self;
        return true;
    }

    pub fn describe(self: *Remote, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "SoundCraft app at {f}", .{self.target});
    }

    /// One request/reply exchange. `sent` is set when the request line was written completely, so the
    /// app may have executed it even though the reply was lost.
    fn roundtrip(self: *Remote, arena: Allocator, method: []const u8, params: std.json.Value, sent: *bool) RemoteError!std.json.Value {
        sent.* = false;
        self.detail_len = 0;
        const id = self.next_id;
        self.next_id += 1;
        const line = std.json.Stringify.valueAlloc(self.gpa, .{ .id = id, .method = method, .params = params }, .{}) catch return error.OutOfMemory;
        defer self.gpa.free(line);

        const fd = try self.connection();
        try self.sendAll(fd, line);
        try self.sendAll(fd, "\n");
        sent.* = true;

        const reply = try self.readLine(fd, arena);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.setDetail("invalid JSON reply", .{});
                return error.Reply;
            },
        };
        if (parsed == .object) {
            const o = parsed.object;
            if (o.get("ok")) |ok| {
                if (ok == .bool and ok.bool) return o.get("result") orelse .null;
            }
            if (o.get("error")) |e| {
                if (e == .string) return self.appError(e.string);
            }
        }
        return self.appError("error");
    }

    /// Records the app's message (truncated to the detail buffer) and reports `App`.
    fn appError(self: *Remote, message: []const u8) RemoteError {
        const n = @min(message.len, self.detail_buf.len);
        @memcpy(self.detail_buf[0..n], message[0..n]);
        self.detail_len = n;
        return error.App;
    }

    fn setDetail(self: *Remote, comptime fmt: []const u8, args: anytype) void {
        self.detail_len = if (std.fmt.bufPrint(&self.detail_buf, fmt, args)) |text| text.len else |_| 0;
    }

    fn dropConnection(self: *Remote) void {
        if (self.conn) |fd| _ = close(fd);
        self.conn = null;
        self.rbuf.clearRetainingCapacity();
    }

    /// The open socket, connecting first when there is none.
    fn connection(self: *Remote) RemoteError!fd_t {
        if (self.conn) |fd| return fd;
        const fd = try self.connect();
        self.conn = fd;
        return fd;
    }

    /// Connects to the target, trying each address it resolves to, the first that accepts wins.
    fn connect(self: *Remote) RemoteError!fd_t {
        const host = self.target.host orelse "127.0.0.1";
        const host_z = try self.gpa.allocSentinel(u8, host.len, 0);
        defer self.gpa.free(host_z);
        @memcpy(host_z, host);
        var port_buf: [8:0]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{self.target.port}) catch unreachable;
        port_buf[port_text.len] = 0;
        const port_z: [:0]const u8 = port_buf[0..port_text.len :0];

        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = std.c.AF.UNSPEC;
        hints.socktype = std.c.SOCK.STREAM;
        var res: ?*std.c.addrinfo = null;
        const gai = std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res);
        if (@backingInt(gai) != 0 or res == null) {
            self.setDetail("cannot resolve {f}", .{self.target});
            return error.Resolve;
        }
        defer std.c.freeaddrinfo(res.?);

        var reason: []const u8 = "no addresses found";
        var any = false;
        var cur = res;
        while (cur) |ai| : (cur = ai.next) {
            any = true;
            if (tryAddress(ai, &reason)) |fd| return fd;
        }
        if (!any) {
            self.setDetail("cannot reach SoundCraft at {f}: no addresses found", .{self.target});
            return error.NoAddress;
        }
        self.setDetail("cannot reach SoundCraft at {f}: {s}", .{ self.target, reason });
        return error.Unreachable;
    }

    /// Connects to one address with a bounded connect timeout, then makes the socket blocking with a
    /// read timeout. On failure `reason` names why (a fixed string).
    fn tryAddress(ai: *std.c.addrinfo, reason: *[]const u8) ?fd_t {
        const fd = socket(ai.family, ai.socktype, ai.protocol);
        if (fd < 0) {
            reason.* = "socket failed";
            return null;
        }
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags | o_nonblock);
        const addr = ai.addr orelse {
            _ = close(fd);
            reason.* = "no address";
            return null;
        };
        const rc = std.c.connect(fd, addr, ai.addrlen);
        if (rc != 0) {
            if (std.c.errno(rc) != .INPROGRESS) {
                _ = close(fd);
                reason.* = "connection refused";
                return null;
            }
            var pfd = std.c.pollfd{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 };
            const ready = std.c.poll(@ptrCast(&pfd), 1, connect_timeout_ms);
            if (ready == 0) {
                _ = close(fd);
                reason.* = "timed out";
                return null;
            }
            var so_error: c_int = 0;
            var so_len: std.c.socklen_t = @sizeOf(c_int);
            const got = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &so_error, &so_len);
            if (ready < 0 or got != 0 or so_error != 0) {
                _ = close(fd);
                reason.* = "connection refused";
                return null;
            }
        }
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags);

        var tv = std.mem.zeroes(std.c.timeval);
        tv.sec = read_timeout_sec;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
        if (builtin.os.tag.isDarwin()) {
            // No SIGPIPE on write: the error comes back as EPIPE, as in the Rust client.
            var one: c_int = 1;
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        }
        return fd;
    }

    /// Maps a failed socket call to the error set. Records the detail.
    fn ioError(self: *Remote, e: std.c.E) RemoteError {
        switch (e) {
            .CONNRESET => {
                self.setDetail("connection reset by peer", .{});
                return error.ConnectionReset;
            },
            .PIPE => {
                self.setDetail("broken pipe", .{});
                return error.BrokenPipe;
            },
            .CONNABORTED => {
                self.setDetail("connection aborted", .{});
                return error.ConnectionAborted;
            },
            else => {
                self.setDetail("I/O error (errno {d})", .{@backingInt(e)});
                return error.Io;
            },
        }
    }

    fn sendFlags() c_int {
        return if (builtin.os.tag == .linux) 0x4000 else 0; // MSG_NOSIGNAL on Linux
    }

    fn sendAll(self: *Remote, fd: fd_t, bytes: []const u8) RemoteError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.c.send(fd, bytes[off..].ptr, bytes.len - off, @intCast(sendFlags()));
            if (rc < 0) {
                const e = std.c.errno(rc);
                if (e == .INTR) continue;
                return self.ioError(e);
            }
            off += @intCast(rc);
        }
    }

    /// One recv into `buf`; returns 0 at end of stream.
    fn recvSome(self: *Remote, fd: fd_t, buf: []u8) RemoteError!usize {
        while (true) {
            const rc = std.c.recv(fd, buf.ptr, buf.len, 0);
            if (rc >= 0) return @intCast(rc);
            const e = std.c.errno(rc);
            if (e != .INTR) return self.ioError(e);
        }
    }

    /// The next reply line, without its newline, copied into `arena`. A line longer than
    /// `max_line_bytes` drops the connection and is reported as `Reply`.
    fn readLine(self: *Remote, fd: fd_t, arena: Allocator) RemoteError![]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.rbuf.items, '\n')) |i| {
                if (i > max_line_bytes) return self.tooLarge();
                const line = try arena.dupe(u8, self.rbuf.items[0..i]);
                const rest = self.rbuf.items[i + 1 ..];
                std.mem.copyForwards(u8, self.rbuf.items[0..rest.len], rest);
                self.rbuf.shrinkRetainingCapacity(rest.len);
                return line;
            }
            if (self.rbuf.items.len > max_line_bytes) return self.tooLarge();
            try self.rbuf.ensureUnusedCapacity(self.gpa, read_chunk_bytes);
            const n = try self.recvSome(fd, self.rbuf.unusedCapacitySlice());
            if (n == 0) {
                // End of stream: a partial line is returned as it is, as read_line does.
                if (self.rbuf.items.len == 0) {
                    self.setDetail("connection closed", .{});
                    return error.Closed;
                }
                const line = try arena.dupe(u8, self.rbuf.items);
                self.rbuf.clearRetainingCapacity();
                return line;
            }
            self.rbuf.items.len += n;
        }
    }

    fn tooLarge(self: *Remote) RemoteError {
        self.dropConnection();
        self.setDetail("reply longer than {d} MiB", .{max_line_bytes / (1024 * 1024)});
        return error.Reply;
    }
};

// ---------------------------------------------------------------------------------------------
// Tests. A fake app runs on a thread: it listens on 127.0.0.1 port 0 and answers one connection per
// entry of its script; `true` answers ok, `false` drops the connection after reading the request.

const Listener = struct {
    fd: fd_t,
    port: u16,
};

/// A listening socket on 127.0.0.1, on a port the kernel picks.
fn listenLoopback() !Listener {
    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.INET;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    const gai = std.c.getaddrinfo("127.0.0.1", "0", &hints, &res);
    if (@backingInt(gai) != 0 or res == null) return error.TestSetup;
    defer std.c.freeaddrinfo(res.?);
    const ai = res.?;
    const fd = socket(ai.family, ai.socktype, ai.protocol);
    if (fd < 0) return error.TestSetup;
    errdefer _ = close(fd);
    if (std.c.bind(fd, ai.addr.?, ai.addrlen) != 0) return error.TestSetup;
    if (std.c.listen(fd, 8) != 0) return error.TestSetup;
    var name: [128]u8 align(8) = undefined;
    var name_len: std.c.socklen_t = name.len;
    if (std.c.getsockname(fd, @ptrCast(&name), &name_len) != 0) return error.TestSetup;
    // The port is at byte 2 of a sockaddr_in, big-endian, on Linux and Darwin alike.
    const port = std.mem.readInt(u16, name[2..4], .big);
    return .{ .fd = fd, .port = port };
}

/// Serves one connection per entry: reads one request line, counts it, and either answers ok or
/// drops the connection.
fn serveFake(listen_fd: fd_t, answers: [2]bool, seen: *std.atomic.Value(usize)) void {
    for (answers) |answer| {
        const fd = std.c.accept(listen_fd, null, null);
        if (fd < 0) return;
        defer _ = close(fd);
        var got_line = false;
        while (true) {
            var b: [1]u8 = undefined;
            const r = std.c.recv(fd, &b, 1, 0);
            if (r <= 0) break;
            got_line = true;
            if (b[0] == '\n') break;
        }
        if (!got_line) continue;
        _ = seen.fetchAdd(1, .seq_cst);
        if (answer) {
            const reply = "{\"id\":1,\"ok\":true,\"result\":{\"done\":true}}\n";
            _ = std.c.send(fd, reply.ptr, reply.len, 0);
        }
    }
}

fn startFake(answers: [2]bool, seen: *std.atomic.Value(usize)) !Listener {
    const l = try listenLoopback();
    const t = try std.Thread.spawn(.{}, serveFake, .{ l.fd, answers, seen });
    t.detach();
    return l;
}

fn parseJson(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "remote_reports_unreachable" {
    var r = try Remote.init(testing.allocator, .{ .host = "127.0.0.1", .port = 1 });
    defer r.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const err = if (r.request(arena, "session.inspect", .null)) |_| return error.TestUnexpectedResult else |e| e;
    try testing.expectEqual(RemoteError.Unreachable, err);
    try testing.expect(std.mem.startsWith(u8, r.errorMessage(err), "cannot reach SoundCraft at 127.0.0.1:1: "));
}

test "remote_resolves_hostnames" {
    const l = try listenLoopback();
    defer _ = close(l.fd);
    var r = try Remote.init(testing.allocator, .{ .host = "localhost", .port = l.port });
    defer r.deinit();
    _ = try r.connection();
    try testing.expect(r.conn != null);
}

test "remote_does_not_repeat_a_mutation_after_a_lost_reply" {
    var seen = std.atomic.Value(usize).init(0);
    const fake = try startFake(.{ false, true }, &seen);
    defer _ = close(fake.fd);
    var r = try Remote.init(testing.allocator, .{ .host = null, .port = fake.port });
    defer r.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = try parseJson(arena, "{\"command\":\"track.new\"}");
    switch (r.call(arena, "engine.execute", params)) {
        .err => |text| try testing.expect(std.mem.indexOf(u8, text, "may or may not have been executed") != null),
        .ok => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), seen.load(.seq_cst));
}

test "remote_retries_a_read_after_a_lost_reply" {
    var seen = std.atomic.Value(usize).init(0);
    const fake = try startFake(.{ false, true }, &seen);
    defer _ = close(fake.fd);
    var r = try Remote.init(testing.allocator, .{ .host = null, .port = fake.port });
    defer r.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (r.call(arena, "session.inspect", .null)) {
        .ok => |v| try testing.expect(v == .object),
        .err => |text| {
            std.debug.print("unexpected error: {s}\n", .{text});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 2), seen.load(.seq_cst));
}

test "is_read_only classifies the read-only control methods" {
    try testing.expect(isReadOnly("session.inspect"));
    try testing.expect(isReadOnly("ui.menu.list"));
    try testing.expect(!isReadOnly("engine.execute"));
    try testing.expect(!isReadOnly("command"));
    try testing.expect(!isReadOnly("ui.click"));
}

test "a lost connection is recognised, other failures are not" {
    try testing.expect(isLostConnection(error.Closed));
    try testing.expect(isLostConnection(error.BrokenPipe));
    try testing.expect(isLostConnection(error.ConnectionReset));
    try testing.expect(!isLostConnection(error.Unreachable));
    try testing.expect(!isLostConnection(error.Io));
    try testing.expect(!isLostConnection(error.App));
}
