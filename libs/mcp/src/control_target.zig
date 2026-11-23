// Translated to Zig from soundcraft/crates/automation/src/lib.rs, soundcraft/crates/automation/src/args.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Where a running app's control channel listens: the `ControlTarget` value (`host:port`, or a bare
//! port) and the parser that reads it from a command-line or environment value. The clap wiring of
//! args.rs (`long_version`, `blank_env_is_unset`, `name_env_vars`, `conflict`) is not translated.

const std = @import("std");
const testing = std.testing;

/// The error of `parse`: the text is neither a port nor `host:port`.
/// The Rust message is "expected a port, 0-65535, or host:port".
pub const NotATarget = error{NotATarget};

/// Where a running app's control channel listens.
pub const ControlTarget = struct {
    /// As given: a name, an IPv4 address, or an IPv6 address in brackets (`[::1]`). `null` means
    /// 127.0.0.1. Borrowed: the owner of the text keeps it alive.
    host: ?[]const u8 = null,
    port: u16,

    /// Can the desktop app's control server, which listens on 127.0.0.1 only, serve this target?
    /// True for no host, `127.0.0.1` and `localhost`; `[::1]` is another address.
    pub fn isLoopback(self: ControlTarget) bool {
        const host = self.host orelse return true;
        return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
    }

    /// `host:port`, as a socket address is written. Use with `{f}`.
    pub fn format(self: ControlTarget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}:{d}", .{ self.host orelse "127.0.0.1", self.port });
    }
};

/// Parses `PORT` or `HOST:PORT` (surrounding whitespace ignored), as `args::control_target` does.
/// The returned host borrows from `s`.
pub fn parse(s: []const u8) NotATarget!ControlTarget {
    const hp = try hostAndPort(std.mem.trim(u8, s, " \t\r\n"));
    return .{ .host = hp.host, .port = hp.port };
}

const HostPort = struct { host: ?[]const u8, port: u16 };

/// `PORT` or `HOST:PORT`, split. An IPv6 host goes in brackets (`[::1]:7979`), as a socket address
/// is written: in `::1:7979` the host and port can't be told apart.
fn hostAndPort(s: []const u8) NotATarget!HostPort {
    var host: ?[]const u8 = null;
    var port_text = s;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        const left = s[0..colon];
        if (left.len == 0) return error.NotATarget;
        const bracketed = left[0] == '[' and left[left.len - 1] == ']';
        if (std.mem.indexOfScalar(u8, left, ':') != null and !bracketed) return error.NotATarget;
        host = left;
        port_text = s[colon + 1 ..];
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.NotATarget;
    return .{ .host = host, .port = port };
}

fn expectTarget(host: ?[]const u8, port: u16, got: NotATarget!ControlTarget) !void {
    const t = try got;
    if (host) |h| {
        try testing.expect(t.host != null);
        try testing.expectEqualStrings(h, t.host.?);
    } else {
        try testing.expect(t.host == null);
    }
    try testing.expectEqual(port, t.port);
}

test "control_target_is_a_port_or_host_and_port" {
    try expectTarget(null, 7979, parse("7979"));
    try expectTarget(null, 0, parse(" 0 "));
    try expectTarget("localhost", 7979, parse("localhost:7979 "));
    try expectTarget("10.0.0.5", 1, parse("10.0.0.5:1"));
    try expectTarget("[::1]", 7979, parse("[::1]:7979"));
    const bad = [_][]const u8{ "", "x", "78787", ":7979", "host:", "host:x", "-1", "::1:7979", "[::1:7979" };
    for (bad) |text| {
        testing.expectError(error.NotATarget, parse(text)) catch |e| {
            std.debug.print("control_target({q}) should be NotATarget\n", .{text});
            return e;
        };
    }
}

// The control server listens on 127.0.0.1 only: `[::1]` is another address.
test "a_loopback_target_is_a_port_127_0_0_1_or_localhost" {
    const loopback = [_][]const u8{ "50494", "127.0.0.1:7979", "localhost:7979" };
    for (loopback) |text| {
        const t = try parse(text);
        try testing.expect(t.isLoopback());
    }
    const remote = [_][]const u8{ "10.0.0.5:7979", "example.com:7979", "[::1]:7979" };
    for (remote) |text| {
        const t = try parse(text);
        try testing.expect(!t.isLoopback());
    }
}

test "a_control_target_displays_as_a_socket_address" {
    const cases = [_][2][]const u8{
        .{ "7979", "127.0.0.1:7979" },
        .{ "localhost:1", "localhost:1" },
        .{ "[::1]:7979", "[::1]:7979" },
    };
    var buf: [128]u8 = undefined;
    for (cases) |c| {
        const t = try parse(c[0]);
        const shown = try std.fmt.bufPrint(&buf, "{f}", .{t});
        try testing.expectEqualStrings(c[1], shown);
    }
}

// The three clap-only tests of args.rs (name_env_vars, blank_env_is_unset, conflict) test functions
// that are not translated: they need clap's Command and ArgMatches. Kept as skips so the count of
// Rust tests stays visible.
test "name_env_vars_names_the_variable_only_when_the_flag_was_not_given" {
    return error.SkipZigTest;
}

test "blank_env_is_unset_keeps_an_unset_variable" {
    return error.SkipZigTest;
}

test "conflict_is_a_clap_usage_error_naming_both_flags" {
    return error.SkipZigTest;
}
