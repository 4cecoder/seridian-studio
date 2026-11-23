//! Desktop environment and display session detection for the preflight.
//!
//! Detection is pure over an environment (anything with a
//! `get(name) ?[]const u8` method, the same interface `wm.detect` takes) and a
//! file-system probe (`exists`, `findEntryWith`), so every heuristic is unit
//! tested. Fallbacks matter: an app launched from a terminal multiplexer, a
//! systemd unit or an IDE often inherits an incomplete environment (no
//! XDG_CURRENT_DESKTOP, no WAYLAND_DISPLAY), so the compositor's runtime
//! sockets are checked too.
//!
//! The window-manager layer (src/cli/wm/wm.zig) picks the backend that moves
//! windows; this module names the desktop and session for the report. They
//! share the rule for a live Hyprland instance (`wm.hyprlandSocketPath`) and
//! the file-system probe (`wm.FsProbe`).
//!
//! Ported from feat/overhaul 4914565 (src/system/desktop.zig).

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../utils/sys.zig");
const wm = @import("../cli/wm/wm.zig");

/// X11 WM_CLASS (res_name and res_class) of every Seridian Studio window.
/// The UI sets it with Raven's `Rset_window_class("seridian-studio", NULL)`
/// before it creates a window (vendored Raven defaults to "raven"). Under
/// XWayland the compositor reports res_class as the window's class / app id,
/// so Hyprland rules (`match:class`), GNOME's wm_class and the desktop entry's
/// StartupWMClass all name it.
pub const app_wm_class = "seridian-studio";

pub const Desktop = enum(u8) {
    hyprland,
    kde,
    gnome,
    sway,
    cosmic,
    xfce,
    cinnamon,
    other,
    macos,
    unknown,

    pub fn name(self: Desktop) []const u8 {
        return switch (self) {
            .hyprland => "Hyprland",
            .kde => "KDE Plasma",
            .gnome => "GNOME",
            .sway => "Sway",
            .cosmic => "COSMIC",
            .xfce => "Xfce",
            .cinnamon => "Cinnamon",
            .other => "Other desktop",
            .macos => "macOS",
            .unknown => "Unknown",
        };
    }
};

pub const Session = enum(u8) {
    wayland,
    x11,
    tty,
    quartz,
    unknown,

    pub fn name(self: Session) []const u8 {
        return switch (self) {
            .wayland => "Wayland",
            .x11 => "X11",
            .tty => "TTY",
            .quartz => "Quartz",
            .unknown => "Unknown",
        };
    }
};

/// What detection found, plus the evidence later checks reuse.
pub const Info = struct {
    desktop: Desktop,
    session: Session,
    /// Raw XDG_CURRENT_DESKTOP (or the session fallback) when an unlisted
    /// desktop was detected, for display.
    desktop_label: Text(32) = .{},
    /// Live Hyprland instance signature, from the environment or the runtime dir.
    hypr_signature: Text(128) = .{},
    /// True when the Hyprland signature came from the runtime directory, not
    /// the environment (hyprctl then needs `--instance`).
    hypr_signature_from_socket: bool = false,
    /// A Wayland compositor socket is reachable.
    wayland_socket: bool = false,
    /// DISPLAY is set (X11 or XWayland available).
    has_x_display: bool = false,

    /// The desktop's display name (the raw label for an unlisted desktop).
    pub fn desktopName(self: *const Info) []const u8 {
        return if (self.desktop == .other) self.desktop_label.slice() else self.desktop.name();
    }
};

/// Small fixed-capacity string (no allocation; copies are cheap).
pub fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init(s: []const u8) Self {
            var t: Self = .{};
            t.set(s);
            return t;
        }

        /// Copy `s`, truncating to capacity.
        pub fn set(self: *Self, s: []const u8) void {
            self.len = @min(s.len, cap);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        /// Format into the buffer, truncating on overflow.
        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const written = std.fmt.bufPrint(&self.buf, fmt, args) catch |err| switch (err) {
                error.NoSpaceLeft => {
                    self.len = cap;
                    return;
                },
            };
            self.len = written.len;
        }

        /// Append formatted text; returns false (and leaves the text as it
        /// was) when it does not fit.
        pub fn append(self: *Self, comptime fmt: []const u8, args: anytype) bool {
            const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch |err| switch (err) {
                error.NoSpaceLeft => return false,
            };
            self.len += written.len;
            return true;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// Environment over libc's `getenv`, for callers without an
/// `std.process.Environ.Map` (the engine library's C API).
pub const ProcessEnv = struct {
    pub fn get(_: ProcessEnv, name: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        return sys.getenv(buf[0..name.len :0]);
    }
};

/// File-system probe over the real file system.
pub const FsProbe = struct {
    pub fn exists(_: FsProbe, path: []const u8) bool {
        if (!std.fs.path.isAbsolute(path)) return false;
        return (wm.FsProbe{}).exists(path);
    }

    /// Name of the first directory entry of `dir_path` that contains `file`,
    /// copied to `buf`; null when there is none or `dir_path` can't be read.
    pub fn findEntryWith(self: FsProbe, dir_path: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
        if (!std.fs.path.isAbsolute(dir_path)) return null;
        var dir = std.Io.Dir.openDirAbsolute(sys.io(), dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(sys.io());
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(sys.io()) catch return null) orelse return null;
            if (entry.kind != .directory) continue;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ dir_path, entry.name, file }) catch continue;
            if (!self.exists(path)) continue;
            if (entry.name.len > buf.len) continue;
            @memcpy(buf[0..entry.name.len], entry.name);
            return buf[0..entry.name.len];
        }
    }
};

fn nonEmpty(env: anytype, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// Detect the desktop and session from `env` and the real file system.
pub fn detect(env: anytype) Info {
    return detectWith(env, FsProbe{}, builtin.os.tag);
}

/// `detect` with an injectable probe (`exists`, `findEntryWith`) and OS.
pub fn detectWith(env: anytype, probe: anytype, os: std.Target.Os.Tag) Info {
    if (os == .macos) return .{ .desktop = .macos, .session = .quartz };

    var info: Info = .{ .desktop = .unknown, .session = .unknown };
    const runtime_dir = nonEmpty(env, "XDG_RUNTIME_DIR");

    // Hyprland: a signature counts only when its socket exists (the same rule
    // as wm.detect), so a stale variable in a long-lived tmux session is not
    // trusted. Without a usable one, a live instance socket still proves it.
    if (runtime_dir) |rd| {
        var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (nonEmpty(env, "HYPRLAND_INSTANCE_SIGNATURE")) |sig| {
            if (wm.hyprlandSocketPath(&sock_buf, rd, sig)) |sock| {
                if (probe.exists(sock)) info.hypr_signature.set(sig);
            } else |err| switch (err) {
                error.NoSpaceLeft => {},
            }
        }
        if (info.hypr_signature.len == 0) {
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            var sig_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&dir_buf, "{s}/hypr", .{rd})) |hypr_dir| {
                if (probe.findEntryWith(hypr_dir, ".socket.sock", &sig_buf)) |sig| {
                    info.hypr_signature.set(sig);
                    info.hypr_signature_from_socket = true;
                }
            } else |err| switch (err) {
                error.NoSpaceLeft => {},
            }
        }
    }

    info.desktop = desktopFromEnv(env, probe, &info.desktop_label);
    if (info.desktop == .unknown and info.hypr_signature.len > 0) info.desktop = .hyprland;

    // Session type.
    info.has_x_display = nonEmpty(env, "DISPLAY") != null;
    if (nonEmpty(env, "WAYLAND_DISPLAY")) |wd| {
        info.wayland_socket = waylandSocketExists(probe, runtime_dir, wd);
    } else if (runtime_dir) |rd| {
        // No WAYLAND_DISPLAY: look for the default compositor sockets.
        for ([_][]const u8{ "wayland-0", "wayland-1" }) |name| {
            if (info.wayland_socket) break;
            info.wayland_socket = waylandSocketExists(probe, rd, name);
        }
    }

    const session_type = nonEmpty(env, "XDG_SESSION_TYPE");
    info.session = if (session_type) |t| sessionFromString(t) else .unknown;
    if (info.session == .unknown or info.session == .tty) {
        // A compositor socket or a Wayland-only desktop beats a missing or
        // stale XDG_SESSION_TYPE (common under terminal multiplexers).
        if (info.wayland_socket or info.desktop == .hyprland or info.desktop == .sway) {
            info.session = .wayland;
        } else if (info.has_x_display) {
            info.session = .x11;
        } else if (session_type == null) {
            info.session = .tty;
        }
    }
    return info;
}

fn waylandSocketExists(probe: anytype, runtime_dir: ?[]const u8, wayland_display: []const u8) bool {
    if (std.fs.path.isAbsolute(wayland_display)) return probe.exists(wayland_display);
    const rd = runtime_dir orelse return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rd, wayland_display }) catch |err| switch (err) {
        error.NoSpaceLeft => return false,
    };
    return probe.exists(path);
}

fn sessionFromString(s: []const u8) Session {
    if (std.ascii.eqlIgnoreCase(s, "wayland")) return .wayland;
    if (std.ascii.eqlIgnoreCase(s, "x11")) return .x11;
    if (std.ascii.eqlIgnoreCase(s, "tty")) return .tty;
    return .unknown;
}

fn desktopFromEnv(env: anytype, probe: anytype, label: *Text(32)) Desktop {
    // XDG_CURRENT_DESKTOP is a colon list ("ubuntu:GNOME", "KDE",
    // "X-Cinnamon"); the first recognized token wins.
    const vars = [_][]const u8{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" };
    for (vars) |v| {
        const value = nonEmpty(env, v) orelse continue;
        var it = std.mem.tokenizeScalar(u8, value, ':');
        while (it.next()) |token| {
            if (desktopFromToken(token)) |d| return d;
        }
        if (label.len == 0) label.set(value);
    }
    if (nonEmpty(env, "KDE_FULL_SESSION") != null) return .kde;
    if (nonEmpty(env, "GNOME_DESKTOP_SESSION_ID") != null) return .gnome;
    // As in wm.detect, SWAYSOCK counts only when the socket exists.
    if (nonEmpty(env, "SWAYSOCK")) |sock| {
        if (probe.exists(sock)) return .sway;
    }
    return if (label.len > 0) .other else .unknown;
}

fn desktopFromToken(raw: []const u8) ?Desktop {
    // Session names like "plasmawayland" or "/usr/share/xsessions/plasma".
    const token = std.fs.path.basename(raw);
    const Entry = struct { []const u8, Desktop };
    const table = [_]Entry{
        .{ "hyprland", .hyprland },
        .{ "kde", .kde },
        .{ "plasma", .kde },
        .{ "gnome", .gnome },
        .{ "ubuntu", .gnome },
        .{ "pop", .gnome },
        .{ "sway", .sway },
        .{ "cosmic", .cosmic },
        .{ "xfce", .xfce },
        .{ "cinnamon", .cinnamon },
        .{ "x-cinnamon", .cinnamon },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(token, e[0])) return e[1];
    }
    // Prefix forms: "plasmawayland", "gnome-xorg", "hyprland-uwsm".
    for (table) |e| {
        if (token.len > e[0].len and std.ascii.startsWithIgnoreCase(token, e[0])) return e[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test environment and file system.
const FakeEnv = struct {
    vars: []const [2][]const u8 = &.{},
    files: []const []const u8 = &.{},
    /// (dir, entry-with-file) pairs for findEntryWith.
    entries: []const [2][]const u8 = &.{},

    pub fn get(self: *const FakeEnv, name: []const u8) ?[]const u8 {
        for (self.vars) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
    pub fn exists(self: *const FakeEnv, path: []const u8) bool {
        for (self.files) |f| if (std.mem.eql(u8, f, path)) return true;
        return false;
    }
    pub fn findEntryWith(self: *const FakeEnv, dir: []const u8, _: []const u8, buf: []u8) ?[]const u8 {
        for (self.entries) |e| if (std.mem.eql(u8, e[0], dir)) {
            @memcpy(buf[0..e[1].len], e[1]);
            return buf[0..e[1].len];
        };
        return null;
    }
};

fn detectFake(env: *const FakeEnv, os: std.Target.Os.Tag) Info {
    return detectWith(env, env, os);
}

test "Hyprland from the environment" {
    const env: FakeEnv = .{ .vars = &.{
        .{ "XDG_CURRENT_DESKTOP", "Hyprland" },
        .{ "XDG_SESSION_TYPE", "wayland" },
        .{ "HYPRLAND_INSTANCE_SIGNATURE", "abc_123" },
        .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
        .{ "WAYLAND_DISPLAY", "wayland-1" },
    }, .files = &.{ "/run/user/1000/wayland-1", "/run/user/1000/hypr/abc_123/.socket.sock" } };
    const info = detectFake(&env, .linux);
    try testing.expectEqual(Desktop.hyprland, info.desktop);
    try testing.expectEqual(Session.wayland, info.session);
    try testing.expectEqualStrings("abc_123", info.hypr_signature.slice());
    try testing.expect(!info.hypr_signature_from_socket);
    try testing.expect(info.wayland_socket);
}

test "a stale Hyprland signature is replaced by the live instance socket" {
    const env: FakeEnv = .{
        .vars = &.{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "stale" }, .{ "XDG_RUNTIME_DIR", "/run/user/1000" } },
        .entries = &.{.{ "/run/user/1000/hypr", "live_1" }},
    };
    const info = detectFake(&env, .linux);
    try testing.expectEqual(Desktop.hyprland, info.desktop);
    try testing.expectEqualStrings("live_1", info.hypr_signature.slice());
    try testing.expect(info.hypr_signature_from_socket);

    const dead: FakeEnv = .{ .vars = &.{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "stale" }, .{ "XDG_RUNTIME_DIR", "/run/user/1000" } } };
    const d = detectFake(&dead, .linux);
    try testing.expectEqual(Desktop.unknown, d.desktop);
    try testing.expectEqual(@as(usize, 0), d.hypr_signature.len);
}

test "Hyprland found through its runtime socket with a bare environment" {
    // e.g. launched from tmux started before the compositor exported vars.
    const env: FakeEnv = .{
        .vars = &.{.{ "XDG_RUNTIME_DIR", "/run/user/1001" }},
        .files = &.{"/run/user/1001/wayland-1"},
        .entries = &.{.{ "/run/user/1001/hypr", "efb5_1791" }},
    };
    const info = detectFake(&env, .linux);
    try testing.expectEqual(Desktop.hyprland, info.desktop);
    try testing.expectEqual(Session.wayland, info.session);
    try testing.expectEqualStrings("efb5_1791", info.hypr_signature.slice());
    try testing.expect(info.hypr_signature_from_socket);
}

test "colon lists and session names" {
    const ubuntu: FakeEnv = .{ .vars = &.{ .{ "XDG_CURRENT_DESKTOP", "ubuntu:GNOME" }, .{ "XDG_SESSION_TYPE", "x11" }, .{ "DISPLAY", ":0" } } };
    const u = detectFake(&ubuntu, .linux);
    try testing.expectEqual(Desktop.gnome, u.desktop);
    try testing.expectEqual(Session.x11, u.session);

    const plasma: FakeEnv = .{ .vars = &.{.{ "DESKTOP_SESSION", "/usr/share/wayland-sessions/plasmawayland" }} };
    try testing.expectEqual(Desktop.kde, detectFake(&plasma, .linux).desktop);

    const kde_only: FakeEnv = .{ .vars = &.{.{ "KDE_FULL_SESSION", "true" }} };
    try testing.expectEqual(Desktop.kde, detectFake(&kde_only, .linux).desktop);

    const cinnamon: FakeEnv = .{ .vars = &.{.{ "XDG_CURRENT_DESKTOP", "X-Cinnamon" }} };
    try testing.expectEqual(Desktop.cinnamon, detectFake(&cinnamon, .linux).desktop);

    const sway: FakeEnv = .{ .vars = &.{.{ "SWAYSOCK", "/run/user/1000/sway-ipc.sock" }}, .files = &.{"/run/user/1000/sway-ipc.sock"} };
    const s = detectFake(&sway, .linux);
    try testing.expectEqual(Desktop.sway, s.desktop);
    try testing.expectEqual(Session.wayland, s.session);

    const stale_sway: FakeEnv = .{ .vars = &.{.{ "SWAYSOCK", "/run/user/1000/sway-ipc.sock" }} };
    try testing.expectEqual(Desktop.unknown, detectFake(&stale_sway, .linux).desktop);
}

test "unlisted desktop keeps its label; nothing set means a TTY" {
    const lxqt: FakeEnv = .{ .vars = &.{ .{ "XDG_CURRENT_DESKTOP", "LXQt" }, .{ "DISPLAY", ":0" } } };
    const l = detectFake(&lxqt, .linux);
    try testing.expectEqual(Desktop.other, l.desktop);
    try testing.expectEqualStrings("LXQt", l.desktop_label.slice());
    try testing.expectEqualStrings("LXQt", l.desktopName());
    try testing.expectEqual(Session.x11, l.session);

    const bare: FakeEnv = .{};
    const b = detectFake(&bare, .linux);
    try testing.expectEqual(Desktop.unknown, b.desktop);
    try testing.expectEqual(Session.tty, b.session);
    try testing.expectEqualStrings("Unknown", b.desktopName());
}

test "stale XDG_SESSION_TYPE=tty is corrected by a live Wayland socket" {
    const env: FakeEnv = .{
        .vars = &.{ .{ "XDG_SESSION_TYPE", "tty" }, .{ "XDG_RUNTIME_DIR", "/run/user/7" }, .{ "XDG_CURRENT_DESKTOP", "GNOME" } },
        .files = &.{"/run/user/7/wayland-0"},
    };
    const info = detectFake(&env, .linux);
    try testing.expectEqual(Session.wayland, info.session);
    try testing.expectEqual(Desktop.gnome, info.desktop);
}

test "macOS" {
    const env: FakeEnv = .{};
    const info = detectFake(&env, .macos);
    try testing.expectEqual(Desktop.macos, info.desktop);
    try testing.expectEqual(Session.quartz, info.session);
}

test "Text truncates instead of failing and appends only when it fits" {
    var t: Text(4) = .{};
    t.print("{s}", .{"abcdef"});
    try testing.expectEqualStrings("abcd", t.slice());
    t.set("xy");
    try testing.expectEqualStrings("xy", t.slice());
    try testing.expect(t.append("{s}", .{"z"}));
    try testing.expectEqualStrings("xyz", t.slice());
    try testing.expect(!t.append("{s}", .{"zz"}));
    try testing.expectEqualStrings("xyz", t.slice());
    try testing.expectEqualStrings("q", Text(8).init("q").slice());
}

test "ProcessEnv reads libc's environment" {
    const env: ProcessEnv = .{};
    try testing.expect(env.get("SERIDIAN_PREFLIGHT_SURELY_UNSET_VAR") == null);
    const long_name: [200]u8 = @splat('A');
    try testing.expect(env.get(&long_name) == null);
}

test "FsProbe answers for real paths and rejects relative ones" {
    const probe: FsProbe = .{};
    try testing.expect(probe.exists("/"));
    try testing.expect(!probe.exists("relative/path"));
    try testing.expect(!probe.exists("/nonexistent-seridian-preflight-path"));
    var buf: [64]u8 = undefined;
    try testing.expect(probe.findEntryWith("relative", "x", &buf) == null);
    try testing.expect(probe.findEntryWith("/nonexistent-seridian-preflight-path", "x", &buf) == null);
}

test "detect runs against the live environment" {
    const info = detect(ProcessEnv{});
    try testing.expect(info.desktopName().len > 0 or info.desktop == .other);
}

test "app window class is Seridian Studio's own, not Raven's default" {
    try std.testing.expectEqualStrings("seridian-studio", app_wm_class);
    try std.testing.expect(!std.mem.eql(u8, app_wm_class, "raven"));
}
