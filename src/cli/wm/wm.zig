//! Window-manager layer for the `seridian wm ...` commands.
//!
//! `detect` is pure: it takes anything with a `get(name) ?[]const u8` method
//! (std.process.Environ.Map in production, a test map in tests) and picks a
//! backend. Each backend module has the same small interface, see types.zig.

const std = @import("std");
const sys = @import("../../utils/sys.zig");
const t = @import("types.zig");
const hyprland = @import("hyprland.zig");
const sway = @import("sway.zig");
const kwin = @import("kwin.zig");
const x11 = @import("x11.zig");
const gnome_wayland = @import("gnome_wayland.zig");
const monitors = @import("monitors.zig");

pub const Window = t.Window;
pub const Op = t.Op;

pub const Backend = enum { hyprland, sway, kwin, x11, gnome_wayland, none };

pub const Detection = struct {
    backend: Backend,
    /// Static, human-readable explanation of why this backend was chosen.
    reason: []const u8,
};

pub const DetectError = error{InvalidOverride};

pub fn parseBackend(name: []const u8) ?Backend {
    return std.meta.stringToEnum(Backend, name);
}

fn nonEmpty(env: anytype, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// Real file-system probe used by `detect`.
pub const FsProbe = struct {
    pub fn exists(_: FsProbe, path: []const u8) bool {
        std.Io.Dir.accessAbsolute(sys.io(), path, .{}) catch return false;
        return true;
    }
};

/// Hyprland's IPC socket for instance `sig`: `<runtime>/hypr/<sig>/.socket.sock`.
/// A signature counts as live only when this path exists; `detectWith` and
/// the preflight's desktop detection (src/system/desktop.zig) share the rule.
pub fn hyprlandSocketPath(buf: []u8, runtime: []const u8, sig: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/hypr/{s}/.socket.sock", .{ runtime, sig });
}

test "hyprlandSocketPath joins the runtime dir and signature" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/1000/hypr/abc/.socket.sock", try hyprlandSocketPath(&buf, "/run/user/1000", "abc"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, hyprlandSocketPath(&tiny, "/run/user/1000", "abc"));
}

/// Picks the window-manager backend from the environment. This is the only
/// detector: `seridian wm` and `seridian doctor` both call it.
pub fn detect(env: anytype) DetectError!Detection {
    return detectWith(env, FsProbe{});
}

/// `detect` with an injectable `probe.exists(path) bool`, so tests can model
/// live and stale sockets.
///
/// Order: SERIDIAN_WM, Hyprland, Sway, KDE, GNOME on Wayland, X11, none.
/// Hyprland is chosen only when HYPRLAND_INSTANCE_SIGNATURE is set and
/// $XDG_RUNTIME_DIR/hypr/<sig>/.socket.sock exists; Sway only when SWAYSOCK is
/// set and that path exists. A stale variable falls through to the next check.
pub fn detectWith(env: anytype, probe: anytype) DetectError!Detection {
    if (nonEmpty(env, "SERIDIAN_WM")) |name| {
        const backend = parseBackend(name) orelse return error.InvalidOverride;
        return .{ .backend = backend, .reason = "chosen by SERIDIAN_WM" };
    }
    if (nonEmpty(env, "HYPRLAND_INSTANCE_SIGNATURE")) |sig| {
        if (nonEmpty(env, "XDG_RUNTIME_DIR")) |runtime| {
            var buf: [std.posix.PATH_MAX]u8 = undefined;
            if (hyprlandSocketPath(&buf, runtime, sig)) |sock| {
                if (probe.exists(sock)) {
                    return .{ .backend = .hyprland, .reason = "HYPRLAND_INSTANCE_SIGNATURE is set and its socket exists" };
                }
            } else |_| {}
        }
    }
    if (nonEmpty(env, "SWAYSOCK")) |sock| {
        if (probe.exists(sock)) {
            return .{ .backend = .sway, .reason = "SWAYSOCK is set and the socket exists" };
        }
    }
    const desktop = nonEmpty(env, "XDG_CURRENT_DESKTOP");
    if (nonEmpty(env, "KDE_FULL_SESSION") != null) {
        return .{ .backend = .kwin, .reason = "KDE_FULL_SESSION is set (uses kdotool; qdbus alone cannot list windows)" };
    }
    if (desktop) |d| {
        if (t.containsIgnoreCase(d, "KDE")) {
            return .{ .backend = .kwin, .reason = "XDG_CURRENT_DESKTOP contains KDE (uses kdotool; qdbus alone cannot list windows)" };
        }
        if (t.containsIgnoreCase(d, "GNOME") and nonEmpty(env, "WAYLAND_DISPLAY") != null) {
            return .{ .backend = .gnome_wayland, .reason = "GNOME on Wayland (needs the Window Calls extension)" };
        }
    }
    if (nonEmpty(env, "DISPLAY") != null) {
        return .{ .backend = .x11, .reason = "DISPLAY is set (X11, or XWayland clients; uses xdotool)" };
    }
    return .{ .backend = .none, .reason = "no supported window manager or display found" };
}

const none_reason = "no window manager backend detected; set SERIDIAN_WM or run in a supported session";

/// Why `op` is not supported on `backend`, or null when it is.
pub fn reason(backend: Backend, op: Op) ?[]const u8 {
    return switch (backend) {
        .hyprland => hyprland.reason(op),
        .sway => sway.reason(op),
        .kwin => kwin.reason(op),
        .x11 => x11.reason(op),
        .gnome_wayland => gnome_wayland.reason(op),
        .none => none_reason,
    };
}

fn unavailableReason(backend: Backend) []const u8 {
    return switch (backend) {
        .hyprland => hyprland.unavailable_reason,
        .sway => sway.unavailable_reason,
        .kwin => kwin.unavailable_reason,
        .x11 => x11.unavailable_reason,
        .gnome_wayland => gnome_wayland.unavailable_reason,
        .none => none_reason,
    };
}

pub fn list(allocator: std.mem.Allocator, backend: Backend) t.Error![]Window {
    return switch (backend) {
        .hyprland => hyprland.list(allocator),
        .sway => sway.list(allocator),
        .kwin => kwin.list(allocator),
        .x11 => x11.list(allocator),
        .gnome_wayland => gnome_wayland.list(allocator),
        .none => error.Unavailable,
    };
}

pub fn float(allocator: std.mem.Allocator, backend: Backend, win: Window) t.Error!void {
    return switch (backend) {
        .hyprland => hyprland.float(allocator, win),
        .sway => sway.float(allocator, win),
        .kwin => kwin.float(allocator, win),
        .x11 => x11.float(allocator, win),
        .gnome_wayland => gnome_wayland.float(allocator, win),
        .none => error.Unavailable,
    };
}

pub fn move(allocator: std.mem.Allocator, backend: Backend, win: Window, x: i32, y: i32) t.Error!void {
    return switch (backend) {
        .hyprland => hyprland.move(allocator, win, x, y),
        .sway => sway.move(allocator, win, x, y),
        .kwin => kwin.move(allocator, win, x, y),
        .x11 => x11.move(allocator, win, x, y),
        .gnome_wayland => gnome_wayland.move(allocator, win, x, y),
        .none => error.Unavailable,
    };
}

pub fn resize(allocator: std.mem.Allocator, backend: Backend, win: Window, w: i32, h: i32) t.Error!void {
    return switch (backend) {
        .hyprland => hyprland.resize(allocator, win, w, h),
        .sway => sway.resize(allocator, win, w, h),
        .kwin => kwin.resize(allocator, win, w, h),
        .x11 => x11.resize(allocator, win, w, h),
        .gnome_wayland => gnome_wayland.resize(allocator, win, w, h),
        .none => error.Unavailable,
    };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

pub const usage_detect = "seridian wm detect";
pub const usage_list = "seridian wm list";
pub const usage_float = "seridian wm float <match>";
pub const usage_move = "seridian wm move <match> <x> <y>";
pub const usage_resize = "seridian wm resize <match> <w> <h>";

pub const usage_size = "seridian wm size <match> <w> <h> [--pid <n>]";

pub const usage_monitors = "seridian wm monitors";
pub const usage_place = "seridian wm place <match> <monitor-name> <dx> <dy> <w> <h> [--pid <n>]";

pub const usage_all =
    "seridian wm detect | list | monitors | float <match> | move <match> <x> <y> | resize <match> <w> <h> | size <match> <w> <h> [--pid <n>] | place <match> <monitor-name> <dx> <dy> <w> <h> [--pid <n>]";

/// Entry point for `seridian wm <args...>`. Returns the process exit code.
/// Normal output goes to `out`, diagnostics to `err`.
pub fn run(
    allocator: std.mem.Allocator,
    env: anytype,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try err.print("usage: {s}\n", .{usage_all});
        return 1;
    }
    const sub = args[0];
    const rest = args[1..];

    const detection = detect(env) catch {
        try err.writeAll("seridian wm: invalid SERIDIAN_WM '");
        try t.writeEscaped(err, env.get("SERIDIAN_WM") orelse "");
        try err.writeAll("'; valid: hyprland, sway, kwin, x11, gnome_wayland, none\n");
        return 1;
    };
    const backend = detection.backend;

    if (std.mem.eql(u8, sub, "detect")) {
        if (rest.len != 0) return usageError(err, usage_detect);
        try out.print("backend: {s}\nreason: {s}\n", .{ @tagName(backend), detection.reason });
        if (backend == .kwin) {
            try out.print("tools: kdotool={s} qdbus={s}\n", .{ yesNo(t.haveTool("kdotool")), yesNo(t.haveTool("qdbus")) });
        }
        return if (backend == .none) 1 else 0;
    }
    if (std.mem.eql(u8, sub, "list")) {
        if (rest.len != 0) return usageError(err, usage_list);
        const wins = (try listOrReport(allocator, backend, err)) orelse return 1;
        defer t.freeWindows(allocator, wins);
        for (wins) |win| try printWindow(out, win);
        return 0;
    }
    if (std.mem.eql(u8, sub, "monitors")) {
        if (rest.len != 0) return usageError(err, usage_monitors);
        if (monitorsReason(backend)) |why| {
            try err.print("not supported here: {s}\n", .{why});
            return 1;
        }
        const active = monitorsForActiveBackend(allocator, env) catch |e| {
            switch (e) {
                error.InvalidOverride => try err.writeAll("seridian wm: invalid SERIDIAN_WM\n"),
                else => |te| try reportError(err, backend, te),
            }
            return 1;
        };
        defer active.deinit(allocator);
        for (active.monitors) |m| try printMonitor(out, m);
        return 0;
    }
    if (std.mem.eql(u8, sub, "place")) {
        const parsed = parsePlaceArgs(rest) orelse return usageError(err, usage_place);
        return place(allocator, backend, parsed.needle, parsed.monitor, parsed.nums, parsed.pid, out, err);
    }
    if (std.mem.eql(u8, sub, "float")) {
        if (rest.len != 1) return usageError(err, usage_float);
        return act(allocator, backend, .float, rest[0], .{ 0, 0 }, out, err);
    }
    if (std.mem.eql(u8, sub, "move")) {
        if (rest.len != 3) return usageError(err, usage_move);
        const a = parseI32(rest[1]) orelse return usageError(err, usage_move);
        const b = parseI32(rest[2]) orelse return usageError(err, usage_move);
        return act(allocator, backend, .move, rest[0], .{ a, b }, out, err);
    }
    if (std.mem.eql(u8, sub, "size")) {
        const parsed = parseSizeArgs(rest) orelse return usageError(err, usage_size);
        return sizeWindow(allocator, backend, parsed.needle, parsed.w, parsed.h, parsed.pid, out, err);
    }
    if (std.mem.eql(u8, sub, "resize")) {
        if (rest.len != 3) return usageError(err, usage_resize);
        const a = parseI32(rest[1]) orelse return usageError(err, usage_resize);
        const b = parseI32(rest[2]) orelse return usageError(err, usage_resize);
        if (a <= 0 or b <= 0) return usageError(err, usage_resize);
        return act(allocator, backend, .resize, rest[0], .{ a, b }, out, err);
    }
    try err.print("seridian wm: unknown subcommand '{s}'\nusage: {s}\n", .{ sub, usage_all });
    return 1;
}

pub const SizeArgs = struct { needle: []const u8, w: i32, h: i32, pid: ?i64 = null };

pub const PlaceArgs = struct {
    needle: []const u8,
    monitor: []const u8,
    nums: [4]i32,
    pid: ?i64 = null,
};

const max_positional = 8;

/// Positional arguments left after `--pid <n>` is pulled out.
const Split = struct {
    items: [max_positional][]const u8 = undefined,
    len: usize = 0,
    pid: ?i64 = null,

    fn slice(self: *const Split) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// Removes `--pid <n>` (n a positive integer, given at most once) from
/// anywhere in `rest`. Null on a malformed, repeated or dangling flag, or on
/// more positionals than any subcommand takes.
fn splitPid(rest: []const []const u8) ?Split {
    var sp: Split = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--pid")) {
            if (sp.pid != null or i + 1 >= rest.len) return null;
            i += 1;
            const n = std.fmt.parseInt(i64, rest[i], 10) catch return null;
            if (n <= 0) return null;
            sp.pid = n;
            continue;
        }
        if (sp.len == max_positional) return null;
        sp.items[sp.len] = rest[i];
        sp.len += 1;
    }
    return sp;
}

/// Parses the arguments after `wm size`: `<match> <w> <h>` with w, h > 0 and
/// an optional `--pid <n>` anywhere.
pub fn parseSizeArgs(rest: []const []const u8) ?SizeArgs {
    const sp = splitPid(rest) orelse return null;
    const pos = sp.slice();
    if (pos.len != 3) return null;
    const w = parseI32(pos[1]) orelse return null;
    const h = parseI32(pos[2]) orelse return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .needle = pos[0], .w = w, .h = h, .pid = sp.pid };
}

/// Parses the arguments after `wm place`: `<match> <monitor> <dx> <dy> <w> <h>`
/// with w, h > 0 and an optional `--pid <n>` anywhere.
pub fn parsePlaceArgs(rest: []const []const u8) ?PlaceArgs {
    const sp = splitPid(rest) orelse return null;
    const pos = sp.slice();
    if (pos.len != 6) return null;
    const dx = parseI32(pos[2]) orelse return null;
    const dy = parseI32(pos[3]) orelse return null;
    const w = parseI32(pos[4]) orelse return null;
    const h = parseI32(pos[5]) orelse return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .needle = pos[0], .monitor = pos[1], .nums = .{ dx, dy, w, h }, .pid = sp.pid };
}

/// Whether `--pid` can be honoured: only backends whose window list carries a pid.
pub fn pidSupported(backend: Backend) bool {
    return backend == .hyprland;
}

pub const pid_unsupported = "pid filter not supported here";

/// A match needs the needle in title or class and, when `pid` is given, the
/// same owning process.
pub fn windowMatches(win: Window, needle: []const u8, pid: ?i64) bool {
    if (pid) |want| {
        const have = win.pid orelse return false;
        if (have != want) return false;
    }
    return t.matches(win, needle);
}

/// Total time `wm size` / `wm place` wait for the window to appear.
pub const find_timeout_ms: u64 = 3000;
pub const find_interval_ms: u64 = 100;
/// One initial attempt plus one per interval.
pub const find_max_attempts: usize = find_timeout_ms / find_interval_ms + 1;
/// Readback after resizing: the compositor may apply the size a moment later.
pub const verify_max_attempts: usize = 11;

/// Production actions: the real backend and a real sleep. Tests substitute a
/// fake with the same methods so no test sleeps or spawns processes.
const RealOps = struct {
    backend: Backend,

    fn list(self: RealOps, allocator: std.mem.Allocator) t.Error![]Window {
        return list_(allocator, self.backend);
    }
    fn float(self: RealOps, allocator: std.mem.Allocator, win: Window) t.Error!void {
        return float_(allocator, self.backend, win);
    }
    fn ungroup(_: RealOps, allocator: std.mem.Allocator, win: Window) t.Error!void {
        return hyprland.ungroup(allocator, win);
    }
    // Hyprland uses the exact dispatchers so float/ungroup are not repeated.
    fn move(self: RealOps, allocator: std.mem.Allocator, win: Window, x: i32, y: i32) t.Error!void {
        if (self.backend == .hyprland) return hyprland.moveExact(allocator, win, x, y);
        return move_(allocator, self.backend, win, x, y);
    }
    fn resize(self: RealOps, allocator: std.mem.Allocator, win: Window, w: i32, h: i32) t.Error!void {
        if (self.backend == .hyprland) return hyprland.resizeExact(allocator, win, w, h);
        return resize_(allocator, self.backend, win, w, h);
    }
    fn sleepMs(_: RealOps, ms: u64) void {
        sys.sleepNs(ms * std.time.ns_per_ms);
    }
};

/// Windows plus the indices that matched. Free with `deinit`.
const Found = struct {
    wins: []Window,
    hits: []usize,

    fn deinit(self: Found, allocator: std.mem.Allocator) void {
        allocator.free(self.hits);
        t.freeWindows(allocator, self.wins);
    }
};

/// Lists windows until at least one matches, sleeping `find_interval_ms`
/// between attempts and giving up after `find_max_attempts` lists (about
/// 3 s). Zero hits in the result means the wait timed out. Listing errors
/// are not retried. Silent: nothing is printed per attempt.
fn pollForWindow(allocator: std.mem.Allocator, ops: anytype, needle: []const u8, pid: ?i64) t.Error!Found {
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        const wins = try ops.list(allocator);
        var hits: std.ArrayList(usize) = .empty;
        errdefer hits.deinit(allocator);
        for (wins, 0..) |win, i| {
            if (windowMatches(win, needle, pid)) hits.append(allocator, i) catch |e| {
                t.freeWindows(allocator, wins);
                return e;
            };
        }
        if (hits.items.len > 0 or attempt >= find_max_attempts) {
            const owned = hits.toOwnedSlice(allocator) catch |e| {
                t.freeWindows(allocator, wins);
                return e;
            };
            return .{ .wins = wins, .hits = owned };
        }
        hits.deinit(allocator);
        t.freeWindows(allocator, wins);
        ops.sleepMs(find_interval_ms);
    }
}

/// Reads the window `id` back until it reports w x h or the attempts run out.
/// Returns the last observed size, or null when the window is gone.
fn readBackSize(allocator: std.mem.Allocator, ops: anytype, id: []const u8, w: i32, h: i32) t.Error!?[2]i32 {
    var attempt: usize = 0;
    var last: ?[2]i32 = null;
    while (attempt < verify_max_attempts) : (attempt += 1) {
        if (attempt > 0) ops.sleepMs(find_interval_ms);
        const wins = try ops.list(allocator);
        defer t.freeWindows(allocator, wins);
        last = null;
        for (wins) |win| {
            if (std.mem.eql(u8, win.id, id)) {
                last = .{ win.w, win.h };
                break;
            }
        }
        if (last) |sz| {
            if (sz[0] == w and sz[1] == h) return last;
        }
    }
    return last;
}

/// Reports the readback and returns the exit code: 0 only when the size matches.
fn verifySize(
    allocator: std.mem.Allocator,
    ops: anytype,
    id: []const u8,
    w: i32,
    h: i32,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    backend: Backend,
) !u8 {
    const got = readBackSize(allocator, ops, id, w, h) catch |e| {
        try out.writeAll("step verify: FAILED\n");
        try reportError(err, backend, e);
        return 1;
    };
    const sz = got orelse {
        try out.writeAll("step verify: FAILED\n");
        try err.writeAll("window disappeared before its size could be read back\n");
        return 1;
    };
    if (sz[0] != w or sz[1] != h) {
        try out.print("step verify: FAILED size {d}x{d}\n", .{ sz[0], sz[1] });
        try err.print("size mismatch: requested {d}x{d}, window reports {d}x{d}\n", .{ w, h, sz[0], sz[1] });
        return 1;
    }
    try out.print("step verify: ok size {d}x{d}\n", .{ sz[0], sz[1] });
    return 0;
}

/// Prints why the poll found nothing or too much; returns false to stop.
fn requireSingle(
    found: Found,
    backend: Backend,
    needle: []const u8,
    pid: ?i64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !bool {
    if (found.hits.len == 0) {
        try out.writeAll("step find: FAILED\n");
        try reportError(err, backend, error.NotFound);
        try err.writeAll("no window matches '");
        try t.writeEscaped(err, needle);
        try err.writeByte('\'');
        if (pid) |p| try err.print(" with pid {d}", .{p});
        try err.print(" after {d} ms\n", .{find_timeout_ms});
        return false;
    }
    if (found.hits.len > 1) {
        try err.writeByte('\'');
        try t.writeEscaped(err, needle);
        try err.print("' matches {d} windows; be more specific:\n", .{found.hits.len});
        for (found.hits) |i| try printWindow(err, found.wins[i]);
        return false;
    }
    return true;
}

fn sizeWindow(
    allocator: std.mem.Allocator,
    backend: Backend,
    needle: []const u8,
    w: i32,
    h: i32,
    pid: ?i64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    return sizeWith(allocator, RealOps{ .backend = backend }, backend, needle, w, h, pid, out, err);
}

/// Waits for the single window matching `needle` (and `pid`), floats it if
/// needed, resizes it to w x h without moving it, then reads the size back.
/// Exit 1 if the size differs.
fn sizeWith(
    allocator: std.mem.Allocator,
    ops: anytype,
    backend: Backend,
    needle: []const u8,
    w: i32,
    h: i32,
    pid: ?i64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    if (pid != null and !pidSupported(backend)) {
        try err.print("{s}\n", .{pid_unsupported});
        return 1;
    }
    if (reason(backend, .resize)) |why| {
        try err.print("not supported here: {s}\n", .{why});
        return 1;
    }
    if (reason(backend, .list)) |why| {
        try err.print("not supported here: {s}\n", .{why});
        return 1;
    }
    const found = pollForWindow(allocator, ops, needle, pid) catch |e| {
        try reportError(err, backend, e);
        return 1;
    };
    defer found.deinit(allocator);
    if (!try requireSingle(found, backend, needle, pid, out, err)) return 1;
    var win = found.wins[found.hits[0]];

    if (reason(backend, .float)) |why| {
        try stepSkipped(out, "float", why);
    } else if (win.floating) {
        try stepSkipped(out, "float", "already floating");
    } else {
        if (!try stepResult(out, err, backend, "float", ops.float(allocator, win))) return 1;
        win.floating = true;
    }
    if (!try stepResult(out, err, backend, "resize", ops.resize(allocator, win, w, h))) return 1;
    return verifySize(allocator, ops, win.id, w, h, out, err, backend);
}

fn yesNo(v: bool) []const u8 {
    return if (v) "yes" else "no";
}

fn usageError(err: *std.Io.Writer, usage: []const u8) !u8 {
    try err.print("usage: {s}\n", .{usage});
    return 1;
}

fn parseI32(text: []const u8) ?i32 {
    return std.fmt.parseInt(i32, text, 10) catch null;
}

/// Prints one tab-separated row. Every field that came from a window manager
/// is escaped, so a title cannot inject newlines, tabs or terminal escapes.
fn printWindow(out: *std.Io.Writer, win: Window) !void {
    try t.writeEscaped(out, win.id);
    try out.writeByte('\t');
    if (win.class.len == 0) try out.writeByte('-') else try t.writeEscaped(out, win.class);
    try out.print("\t{s}\t{d},{d} {d}x{d}\t", .{
        if (win.floating) "floating" else "tiled",
        win.x,
        win.y,
        win.w,
        win.h,
    });
    try t.writeEscaped(out, win.title);
    try out.writeByte('\n');
}

/// Lists windows, or prints why that is not possible and returns null.
fn listOrReport(allocator: std.mem.Allocator, backend: Backend, err: *std.Io.Writer) !?[]Window {
    if (reason(backend, .list)) |why| {
        try err.print("not supported here: {s}\n", .{why});
        return null;
    }
    return list(allocator, backend) catch |e| {
        try reportError(err, backend, e);
        return null;
    };
}

fn reportError(err: *std.Io.Writer, backend: Backend, e: t.Error) !void {
    switch (e) {
        error.Unavailable => try err.print("{s}: {s}\n", .{ @tagName(backend), unavailableReason(backend) }),
        error.CommandFailed => {
            try err.print("{s}: a window-manager command failed", .{@tagName(backend)});
            if (t.detail().len > 0) {
                try err.writeAll(": ");
                try t.writeEscaped(err, t.detail());
            }
            try err.writeByte('\n');
        },
        error.NotFound => try err.print("{s}: no windows found\n", .{@tagName(backend)}),
        error.Unsupported => try err.print("{s}: not supported\n", .{@tagName(backend)}),
        error.OutOfMemory => try err.print("out of memory\n", .{}),
    }
    t.clearDetail();
}

/// Why monitors cannot be listed on `backend`, or null when they can.
pub fn monitorsReason(backend: Backend) ?[]const u8 {
    return switch (backend) {
        .kwin => "monitor listing is not supported on KWin (kdotool and qdbus do not report monitor geometry)",
        .gnome_wayland => "monitor listing is not supported on GNOME Wayland (Window Calls does not report monitor geometry)",
        .none => none_reason,
        .hyprland, .sway, .x11 => null,
    };
}

/// Monitors as the active backend reports them, plus which backend that was.
pub const ActiveMonitors = struct {
    backend: Backend,
    monitors: []monitors.Monitor,

    pub fn deinit(self: ActiveMonitors, allocator: std.mem.Allocator) void {
        monitors.freeMonitors(allocator, self.monitors);
    }
};

/// The single source of monitor truth: detects the backend, then lists monitors with
/// that backend's own tool and coordinates (hyprctl, swaymsg; xrandr only on X11).
pub fn monitorsForActiveBackend(allocator: std.mem.Allocator, env: anytype) (DetectError || t.Error)!ActiveMonitors {
    const detection = try detect(env);
    const found = try listMonitors(allocator, detection.backend);
    return .{ .backend = detection.backend, .monitors = found };
}

pub fn listMonitors(allocator: std.mem.Allocator, backend: Backend) t.Error![]monitors.Monitor {
    return switch (backend) {
        .hyprland => monitors.listHyprland(allocator),
        .sway => monitors.listSway(allocator),
        .x11 => monitors.listX11(allocator),
        .kwin, .gnome_wayland => error.Unsupported,
        .none => error.Unavailable,
    };
}

/// Prints one tab-separated row: name, x, y, width, height.
fn printMonitor(out: *std.Io.Writer, m: monitors.Monitor) !void {
    try t.writeEscaped(out, m.name);
    try out.print("\t{d}\t{d}\t{d}\t{d}\n", .{ m.x, m.y, m.w, m.h });
}

fn monitorsOrReport(allocator: std.mem.Allocator, backend: Backend, err: *std.Io.Writer) !?[]monitors.Monitor {
    if (monitorsReason(backend)) |why| {
        try err.print("not supported here: {s}\n", .{why});
        return null;
    }
    return listMonitors(allocator, backend) catch |e| {
        try reportError(err, backend, e);
        return null;
    };
}

/// Prints "step <name>: ok|skipped|FAILED" and returns whether to continue.
fn stepResult(out: *std.Io.Writer, err: *std.Io.Writer, backend: Backend, name: []const u8, result: t.Error!void) !bool {
    result catch |e| {
        try out.print("step {s}: FAILED\n", .{name});
        try reportError(err, backend, e);
        return false;
    };
    try out.print("step {s}: ok\n", .{name});
    return true;
}

fn stepSkipped(out: *std.Io.Writer, name: []const u8, why: []const u8) !void {
    try out.print("step {s}: skipped ({s})\n", .{ name, why });
}

fn place(
    allocator: std.mem.Allocator,
    backend: Backend,
    needle: []const u8,
    monitor_name: []const u8,
    nums: [4]i32,
    pid: ?i64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    if (pid != null and !pidSupported(backend)) {
        try err.print("{s}\n", .{pid_unsupported});
        return 1;
    }
    if (reason(backend, .move)) |why| {
        try err.print("not supported here: {s}\n", .{why});
        return 1;
    }
    const mons = (try monitorsOrReport(allocator, backend, err)) orelse return 1;
    defer monitors.freeMonitors(allocator, mons);
    const mon = monitors.find(mons, monitor_name) catch {
        try err.writeAll("unknown monitor '");
        try t.writeEscaped(err, monitor_name);
        try err.writeAll("'; known:");
        for (mons) |m| {
            try err.writeByte(' ');
            try t.writeEscaped(err, m.name);
        }
        try err.writeByte('\n');
        return 1;
    };
    const tgt = monitors.target(mon, nums[0], nums[1], nums[2], nums[3]) catch {
        try err.writeAll("placement is out of range\n");
        return 1;
    };
    return placeWith(allocator, RealOps{ .backend = backend }, backend, needle, mon, tgt, pid, out, err);
}

/// Waits for the single window matching `needle` (and `pid`), then floats,
/// moves and resizes it to `tgt` and reads the size back. Exit 1 if it differs.
fn placeWith(
    allocator: std.mem.Allocator,
    ops: anytype,
    backend: Backend,
    needle: []const u8,
    mon: monitors.Monitor,
    tgt: anytype,
    pid: ?i64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    const found = pollForWindow(allocator, ops, needle, pid) catch |e| {
        try reportError(err, backend, e);
        return 1;
    };
    defer found.deinit(allocator);
    if (!try requireSingle(found, backend, needle, pid, out, err)) return 1;
    var win = found.wins[found.hits[0]];

    try out.writeAll("placing ");
    try t.writeEscaped(out, win.id);
    try out.writeAll(" on ");
    try t.writeEscaped(out, mon.name);
    try out.print(" ({d},{d}) at {d},{d} size {d}x{d}\n", .{ mon.x, mon.y, tgt.x, tgt.y, tgt.w, tgt.h });

    // Step 1: float.
    if (reason(backend, .float)) |why| {
        try stepSkipped(out, "float", why);
    } else if (win.floating) {
        try stepSkipped(out, "float", "already floating");
    } else {
        if (!try stepResult(out, err, backend, "float", ops.float(allocator, win))) return 1;
        win.floating = true;
    }
    // Step 2 (Hyprland only): leave the group so the window moves alone.
    if (backend == .hyprland) {
        if (win.grouped) {
            if (!try stepResult(out, err, backend, "moveoutofgroup", ops.ungroup(allocator, win))) return 1;
        } else {
            try stepSkipped(out, "moveoutofgroup", "not grouped");
        }
    }
    // Steps 3 and 4: move, then resize; then read the size back.
    if (!try stepResult(out, err, backend, "move", ops.move(allocator, win, tgt.x, tgt.y))) return 1;
    if (!try stepResult(out, err, backend, "resize", ops.resize(allocator, win, tgt.w, tgt.h))) return 1;
    return verifySize(allocator, ops, win.id, tgt.w, tgt.h, out, err, backend);
}

/// Finds windows whose title or class contains `needle` (case-insensitive).
/// Returns indices into `wins`; caller frees.
pub fn findMatches(allocator: std.mem.Allocator, wins: []const Window, needle: []const u8) ![]usize {
    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(allocator);
    for (wins, 0..) |win, i| {
        if (t.matches(win, needle)) try found.append(allocator, i);
    }
    return found.toOwnedSlice(allocator);
}

fn act(
    allocator: std.mem.Allocator,
    backend: Backend,
    op: Op,
    needle: []const u8,
    nums: [2]i32,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    if (reason(backend, op)) |why| {
        if (op == .float and backend != .none) {
            try out.print("nothing to do: {s}\n", .{why});
            return 0;
        }
        try err.print("not supported here: {s}\n", .{why});
        return 1;
    }
    const wins = (try listOrReport(allocator, backend, err)) orelse return 1;
    defer t.freeWindows(allocator, wins);

    const hits = try findMatches(allocator, wins, needle);
    defer allocator.free(hits);
    if (hits.len == 0) {
        try err.writeAll("no window matches '");
        try t.writeEscaped(err, needle);
        try err.writeAll("'\n");
        return 1;
    }
    if (hits.len > 1) {
        try err.writeByte('\'');
        try t.writeEscaped(err, needle);
        try err.print("' matches {d} windows; be more specific:\n", .{hits.len});
        for (hits) |i| try printWindow(err, wins[i]);
        return 1;
    }
    const win = wins[hits[0]];
    const result = switch (op) {
        .float => float(allocator, backend, win),
        .move => move(allocator, backend, win, nums[0], nums[1]),
        .resize => resize(allocator, backend, win, nums[0], nums[1]),
        .list => unreachable,
    };
    result catch |e| {
        try reportError(err, backend, e);
        return 1;
    };
    switch (op) {
        .float => {
            try out.writeAll("floated ");
            try t.writeEscaped(out, win.id);
            try out.writeAll(" (");
            try t.writeEscaped(out, win.title);
            try out.writeAll(")\n");
        },
        .move => {
            try out.writeAll("moved ");
            try t.writeEscaped(out, win.id);
            try out.print(" to {d},{d}\n", .{ nums[0], nums[1] });
        },
        .resize => {
            try out.writeAll("resized ");
            try t.writeEscaped(out, win.id);
            try out.print(" to {d}x{d}\n", .{ nums[0], nums[1] });
        },
        .list => unreachable,
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = std.process.Environ.Map;

fn testEnv(pairs: []const [2][]const u8) !TestEnv {
    var map = TestEnv.init(std.testing.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

/// Probe that treats exactly the listed paths as existing sockets.
const FakeProbe = struct {
    live: []const []const u8 = &.{},

    pub fn exists(self: FakeProbe, path: []const u8) bool {
        for (self.live) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

fn expectBackendWith(expected: Backend, pairs: []const [2][]const u8, live: []const []const u8) !void {
    var env = try testEnv(pairs);
    defer env.deinit();
    const got = try detectWith(&env, FakeProbe{ .live = live });
    try std.testing.expectEqual(expected, got.backend);
    try std.testing.expect(got.reason.len > 0);
}

fn expectBackend(expected: Backend, pairs: []const [2][]const u8) !void {
    try expectBackendWith(expected, pairs, &.{});
}

const hypr_sock = "/run/user/1000/hypr/abc123/.socket.sock";
const hypr_env = [_][2][]const u8{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "abc123" }, .{ "XDG_RUNTIME_DIR", "/run/user/1000" } };

test "detect: SERIDIAN_WM override selects every backend, even over live sockets" {
    const names = [_]struct { name: []const u8, want: Backend }{
        .{ .name = "hyprland", .want = .hyprland },
        .{ .name = "sway", .want = .sway },
        .{ .name = "kwin", .want = .kwin },
        .{ .name = "x11", .want = .x11 },
        .{ .name = "gnome_wayland", .want = .gnome_wayland },
        .{ .name = "none", .want = .none },
    };
    for (names) |case| {
        // Nothing else in the environment: the override alone decides.
        try expectBackend(case.want, &.{.{ "SERIDIAN_WM", case.name }});
        // Live Hyprland and Sway sockets plus DISPLAY do not outrank it.
        try expectBackendWith(case.want, &(hypr_env ++ [_][2][]const u8{
            .{ "SERIDIAN_WM", case.name }, .{ "SWAYSOCK", "/run/sway.sock" }, .{ "DISPLAY", ":0" },
        }), &.{ hypr_sock, "/run/sway.sock" });
    }
}

test "detect: invalid SERIDIAN_WM is an error" {
    var env = try testEnv(&.{ .{ "SERIDIAN_WM", "i3" }, .{ "DISPLAY", ":0" } });
    defer env.deinit();
    try std.testing.expectError(error.InvalidOverride, detectWith(&env, FakeProbe{}));
    var env2 = try testEnv(&.{.{ "SERIDIAN_WM", "X11" }});
    defer env2.deinit();
    try std.testing.expectError(error.InvalidOverride, detectWith(&env2, FakeProbe{}));
}

test "detect: empty SERIDIAN_WM is ignored" {
    try expectBackend(.x11, &.{ .{ "SERIDIAN_WM", "" }, .{ "DISPLAY", ":0" } });
}

test "detect: sockets must exist, stale variables fall through" {
    const Case = struct {
        name: []const u8,
        env: []const [2][]const u8,
        live: []const []const u8,
        want: Backend,
    };
    const cases = [_]Case{
        .{ .name = "hyprland live", .env = &hypr_env, .live = &.{hypr_sock}, .want = .hyprland },
        .{ .name = "hyprland live beats live sway", .env = &(hypr_env ++ [_][2][]const u8{.{ "SWAYSOCK", "/s" }}), .live = &.{ hypr_sock, "/s" }, .want = .hyprland },
        .{ .name = "hyprland stale, nothing else", .env = &hypr_env, .live = &.{}, .want = .none },
        .{ .name = "hyprland stale falls to x11", .env = &(hypr_env ++ [_][2][]const u8{.{ "DISPLAY", ":0" }}), .live = &.{}, .want = .x11 },
        .{ .name = "hyprland stale falls to live sway", .env = &(hypr_env ++ [_][2][]const u8{.{ "SWAYSOCK", "/s" }}), .live = &.{"/s"}, .want = .sway },
        .{ .name = "hyprland socket in a different signature dir is stale", .env = &(hypr_env ++ [_][2][]const u8{.{ "DISPLAY", ":0" }}), .live = &.{"/run/user/1000/hypr/other/.socket.sock"}, .want = .x11 },
        .{ .name = "hyprland without XDG_RUNTIME_DIR cannot be validated", .env = &.{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "abc123" }, .{ "DISPLAY", ":0" } }, .live = &.{hypr_sock}, .want = .x11 },
        .{ .name = "empty signature is not set", .env = &.{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "" }, .{ "XDG_RUNTIME_DIR", "/run/user/1000" }, .{ "DISPLAY", ":0" } }, .live = &.{"/run/user/1000/hypr//.socket.sock"}, .want = .x11 },
        .{ .name = "sway live", .env = &.{ .{ "SWAYSOCK", "/run/sway.sock" }, .{ "DISPLAY", ":0" } }, .live = &.{"/run/sway.sock"}, .want = .sway },
        .{ .name = "sway stale falls to x11", .env = &.{ .{ "SWAYSOCK", "/run/sway.sock" }, .{ "DISPLAY", ":0" } }, .live = &.{}, .want = .x11 },
        .{ .name = "sway stale falls to kwin", .env = &.{ .{ "SWAYSOCK", "/gone" }, .{ "XDG_CURRENT_DESKTOP", "KDE" } }, .live = &.{}, .want = .kwin },
        .{ .name = "sway stale, nothing else", .env = &.{.{ "SWAYSOCK", "/gone" }}, .live = &.{}, .want = .none },
        .{ .name = "empty SWAYSOCK is not set", .env = &.{ .{ "SWAYSOCK", "" }, .{ "DISPLAY", ":0" } }, .live = &.{""}, .want = .x11 },
        .{ .name = "both stale", .env = &(hypr_env ++ [_][2][]const u8{ .{ "SWAYSOCK", "/gone" }, .{ "DISPLAY", ":1" } }), .live = &.{}, .want = .x11 },
    };
    for (cases) |case| {
        expectBackendWith(case.want, case.env, case.live) catch |e| {
            std.debug.print("case: {s}\n", .{case.name});
            return e;
        };
    }
}

test "detect: stale sockets on the real file system fall through" {
    var env = try testEnv(&.{
        .{ "HYPRLAND_INSTANCE_SIGNATURE", "no-such-signature" },
        .{ "XDG_RUNTIME_DIR", "/nonexistent-seridian-test-dir" },
        .{ "SWAYSOCK", "/nonexistent-seridian-test-dir/sway.sock" },
        .{ "DISPLAY", ":0" },
    });
    defer env.deinit();
    const got = try detect(&env);
    try std.testing.expectEqual(Backend.x11, got.backend);
}

test "detect: kwin via KDE_FULL_SESSION" {
    try expectBackend(.kwin, &.{ .{ "KDE_FULL_SESSION", "true" }, .{ "DISPLAY", ":0" } });
}

test "detect: kwin via XDG_CURRENT_DESKTOP containing KDE" {
    try expectBackend(.kwin, &.{ .{ "XDG_CURRENT_DESKTOP", "KDE" }, .{ "WAYLAND_DISPLAY", "wayland-0" } });
    try expectBackend(.kwin, &.{ .{ "XDG_CURRENT_DESKTOP", "ubuntu:kde" }, .{ "DISPLAY", ":0" } });
}

test "detect: gnome on wayland needs WAYLAND_DISPLAY" {
    try expectBackend(.gnome_wayland, &.{ .{ "XDG_CURRENT_DESKTOP", "ubuntu:GNOME" }, .{ "WAYLAND_DISPLAY", "wayland-0" }, .{ "DISPLAY", ":0" } });
}

test "detect: gnome without wayland falls through to x11" {
    try expectBackend(.x11, &.{ .{ "XDG_CURRENT_DESKTOP", "GNOME" }, .{ "DISPLAY", ":0" } });
}

test "detect: x11" {
    try expectBackend(.x11, &.{.{ "DISPLAY", ":1" }});
}

test "detect: none" {
    try expectBackend(.none, &.{});
    try expectBackend(.none, &.{.{ "XDG_CURRENT_DESKTOP", "GNOME" }});
}

test "detector parity: `wm detect` reports exactly what detect returns" {
    const envs = [_][]const [2][]const u8{
        &.{},
        &.{.{ "DISPLAY", ":0" }},
        &.{ .{ "SERIDIAN_WM", "kwin" }, .{ "DISPLAY", ":0" } },
        &.{ .{ "SWAYSOCK", "/nonexistent-seridian-test-dir/s" }, .{ "DISPLAY", ":0" } },
        &.{.{ "XDG_CURRENT_DESKTOP", "KDE" }},
        &.{ .{ "XDG_CURRENT_DESKTOP", "GNOME" }, .{ "WAYLAND_DISPLAY", "w" } },
    };
    for (envs) |pairs| {
        var env = try testEnv(pairs);
        defer env.deinit();
        const want = try detect(&env);
        var buf: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var err_buf: [256]u8 = undefined;
        var err: std.Io.Writer = .fixed(&err_buf);
        _ = try run(std.testing.allocator, &env, &.{"detect"}, &out, &err);
        var expected_buf: [1024]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "backend: {s}\nreason: {s}\n", .{ @tagName(want.backend), want.reason });
        try std.testing.expect(std.mem.startsWith(u8, out.buffered(), expected));
    }
}

test "printWindow escapes control characters in every field" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try printWindow(&out, .{
        .id = "1\n2",
        .class = "cl\tass",
        .title = "evil\x1b[2J\nfake\ttitle\r\x07",
        .x = 1,
        .y = 2,
        .w = 3,
        .h = 4,
    });
    const line = out.buffered();
    try std.testing.expectEqualStrings("1\\n2\tcl\\tass\ttiled\t1,2 3x4\tevil\\e[2J\\nfake\\ttitle\\r\\x07\n", line);
    // Exactly one raw newline (the row terminator), and no raw ESC or BEL.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x07) == null);
}

test "reportError: kinds are distinguishable and detail is escaped" {
    var buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&buf);
    t.setDetail("bad\x1b[0m\nnews");
    try reportError(&err, .hyprland, error.CommandFailed);
    try std.testing.expectEqualStrings("hyprland: a window-manager command failed: bad\\e[0m\\nnews\n", err.buffered());
    try std.testing.expectEqual(@as(usize, 0), t.detail().len);

    var buf2: [512]u8 = undefined;
    var err2: std.Io.Writer = .fixed(&buf2);
    try reportError(&err2, .x11, error.NotFound);
    try std.testing.expectEqualStrings("x11: no windows found\n", err2.buffered());
    var buf3: [512]u8 = undefined;
    var err3: std.Io.Writer = .fixed(&buf3);
    try reportError(&err3, .x11, error.Unavailable);
    try std.testing.expect(std.mem.indexOf(u8, err3.buffered(), "install xdotool") != null);
}

test "monitors: kwin and gnome are Unsupported, none is Unavailable" {
    try std.testing.expectError(error.Unsupported, listMonitors(std.testing.allocator, .kwin));
    try std.testing.expectError(error.Unsupported, listMonitors(std.testing.allocator, .gnome_wayland));
    try std.testing.expectError(error.Unavailable, listMonitors(std.testing.allocator, .none));
    try std.testing.expect(monitorsReason(.kwin) != null);
    try std.testing.expect(monitorsReason(.gnome_wayland) != null);
    try std.testing.expect(monitorsReason(.hyprland) == null);
    var buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&buf);
    try reportError(&err, .kwin, error.Unsupported);
    try std.testing.expectEqualStrings("kwin: not supported\n", err.buffered());
}

test "printMonitor row" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try printMonitor(&out, .{ .name = "DP\n1", .x = -5, .y = 6, .w = 7, .h = 8 });
    try std.testing.expectEqualStrings("DP\\n1\t-5\t6\t7\t8\n", out.buffered());
}

test "backend names round-trip" {
    try std.testing.expectEqual(Backend.gnome_wayland, parseBackend("gnome_wayland").?);
    try std.testing.expect(parseBackend("GNOME") == null);
}

test "findMatches is a case-insensitive substring over title or class" {
    const wins = [_]Window{
        .{ .id = "1", .title = "Seridian Studio", .class = "raven" },
        .{ .id = "2", .title = "Terminal", .class = "foot" },
        .{ .id = "3", .title = "notes", .class = "Seridian-notes" },
    };
    const hits = try findMatches(std.testing.allocator, &wins, "SERIDIAN");
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(usize, 0), hits[0]);
    try std.testing.expectEqual(@as(usize, 2), hits[1]);
}

test "parseSizeArgs: table" {
    const Case = struct { args: []const []const u8, ok: bool, w: i32 = 0, h: i32 = 0 };
    const cases = [_]Case{
        .{ .args = &.{ "raven", "800", "600" }, .ok = true, .w = 800, .h = 600 },
        .{ .args = &.{ "a b", "1", "1" }, .ok = true, .w = 1, .h = 1 },
        .{ .args = &.{}, .ok = false },
        .{ .args = &.{"raven"}, .ok = false },
        .{ .args = &.{ "raven", "800" }, .ok = false },
        .{ .args = &.{ "raven", "800", "600", "1" }, .ok = false },
        .{ .args = &.{ "raven", "0", "600" }, .ok = false },
        .{ .args = &.{ "raven", "800", "-5" }, .ok = false },
        .{ .args = &.{ "raven", "abc", "600" }, .ok = false },
        .{ .args = &.{ "raven", "800", "6.5" }, .ok = false },
        .{ .args = &.{ "raven", "99999999999", "600" }, .ok = false },
    };
    for (cases) |c| {
        const got = parseSizeArgs(c.args);
        try std.testing.expectEqual(c.ok, got != null);
        if (got) |g| {
            try std.testing.expectEqual(c.w, g.w);
            try std.testing.expectEqual(c.h, g.h);
            try std.testing.expectEqualStrings(c.args[0], g.needle);
        }
    }
}

test "parseSizeArgs: --pid anywhere after the subcommand" {
    const Case = struct { args: []const []const u8, ok: bool, pid: ?i64 = null, w: i32 = 0 };
    const cases = [_]Case{
        .{ .args = &.{ "raven", "800", "600", "--pid", "42" }, .ok = true, .pid = 42, .w = 800 },
        .{ .args = &.{ "--pid", "42", "raven", "800", "600" }, .ok = true, .pid = 42, .w = 800 },
        .{ .args = &.{ "raven", "--pid", "7", "800", "600" }, .ok = true, .pid = 7, .w = 800 },
        .{ .args = &.{ "raven", "800", "600" }, .ok = true, .pid = null, .w = 800 },
        .{ .args = &.{ "raven", "800", "600", "--pid" }, .ok = false },
        .{ .args = &.{ "raven", "800", "600", "--pid", "abc" }, .ok = false },
        .{ .args = &.{ "raven", "800", "600", "--pid", "0" }, .ok = false },
        .{ .args = &.{ "raven", "800", "600", "--pid", "-3" }, .ok = false },
        .{ .args = &.{ "raven", "800", "600", "--pid", "1", "--pid", "2" }, .ok = false },
        .{ .args = &.{ "--pid", "42", "800", "600" }, .ok = false },
    };
    for (cases) |c| {
        const got = parseSizeArgs(c.args);
        try std.testing.expectEqual(c.ok, got != null);
        if (got) |g| {
            try std.testing.expectEqual(c.pid, g.pid);
            try std.testing.expectEqual(c.w, g.w);
            try std.testing.expectEqualStrings("raven", g.needle);
        }
    }
}

test "parsePlaceArgs: table" {
    const Case = struct { args: []const []const u8, ok: bool, pid: ?i64 = null };
    const cases = [_]Case{
        .{ .args = &.{ "raven", "DP-1", "10", "-20", "800", "600" }, .ok = true },
        .{ .args = &.{ "raven", "DP-1", "10", "-20", "800", "600", "--pid", "9" }, .ok = true, .pid = 9 },
        .{ .args = &.{ "--pid", "9", "raven", "DP-1", "10", "-20", "800", "600" }, .ok = true, .pid = 9 },
        .{ .args = &.{ "raven", "DP-1", "--pid", "9", "10", "-20", "800", "600" }, .ok = true, .pid = 9 },
        .{ .args = &.{ "raven", "DP-1", "10", "-20", "800" }, .ok = false },
        .{ .args = &.{ "raven", "DP-1", "10", "-20", "0", "600" }, .ok = false },
        .{ .args = &.{ "raven", "DP-1", "x", "-20", "800", "600" }, .ok = false },
        .{ .args = &.{ "raven", "DP-1", "10", "-20", "800", "600", "--pid" }, .ok = false },
    };
    for (cases) |c| {
        const got = parsePlaceArgs(c.args);
        try std.testing.expectEqual(c.ok, got != null);
        if (got) |g| {
            try std.testing.expectEqual(c.pid, g.pid);
            try std.testing.expectEqual(@as(i32, 800), g.nums[2]);
            try std.testing.expectEqualStrings("DP-1", g.monitor);
        }
    }
}

test "windowMatches: pid filter" {
    const Case = struct { win_pid: ?i64, want: ?i64, needle: []const u8, ok: bool };
    const cases = [_]Case{
        .{ .win_pid = 5, .want = null, .needle = "raven", .ok = true },
        .{ .win_pid = null, .want = null, .needle = "raven", .ok = true },
        .{ .win_pid = 5, .want = 5, .needle = "raven", .ok = true },
        .{ .win_pid = 5, .want = 6, .needle = "raven", .ok = false },
        .{ .win_pid = null, .want = 5, .needle = "raven", .ok = false },
        .{ .win_pid = 5, .want = 5, .needle = "firefox", .ok = false },
    };
    for (cases) |c| {
        const win: Window = .{ .id = "1", .title = "Seridian", .class = "raven", .pid = c.win_pid };
        try std.testing.expectEqual(c.ok, windowMatches(win, c.needle, c.want));
    }
}

test "pid filter is supported only where the backend reports pids" {
    try std.testing.expect(pidSupported(.hyprland));
    try std.testing.expect(!pidSupported(.sway));
    try std.testing.expect(!pidSupported(.x11));
    try std.testing.expect(!pidSupported(.kwin));
    try std.testing.expect(!pidSupported(.gnome_wayland));
    try std.testing.expect(!pidSupported(.none));
}

/// Scripted backend: `list` returns the next snapshot (the last one repeats)
/// and `sleepMs` only counts, so tests never wait.
const FakeOps = struct {
    /// Each snapshot is the windows visible on that list call.
    snapshots: []const []const Window,
    /// Size the window reports after a resize; null means it applies the request.
    applied: ?[2]i32 = null,
    lists: usize = 0,
    sleeps: usize = 0,
    slept_ms: u64 = 0,
    resized: ?[2]i32 = null,
    moved: ?[2]i32 = null,
    floated: bool = false,

    fn list(self: *FakeOps, allocator: std.mem.Allocator) t.Error![]Window {
        const idx = @min(self.lists, self.snapshots.len - 1);
        self.lists += 1;
        const src = self.snapshots[idx];
        const out = try allocator.alloc(Window, src.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |w| t.freeWindow(allocator, w);
            allocator.free(out);
        }
        for (src) |w| {
            var copy = w;
            if (self.resized) |r| {
                const sz = self.applied orelse r;
                copy.w = sz[0];
                copy.h = sz[1];
            }
            out[n] = try t.makeWindow(allocator, copy);
            n += 1;
        }
        return out;
    }
    fn float(self: *FakeOps, _: std.mem.Allocator, _: Window) t.Error!void {
        self.floated = true;
    }
    fn ungroup(_: *FakeOps, _: std.mem.Allocator, _: Window) t.Error!void {}
    fn move(self: *FakeOps, _: std.mem.Allocator, _: Window, x: i32, y: i32) t.Error!void {
        self.moved = .{ x, y };
    }
    fn resize(self: *FakeOps, _: std.mem.Allocator, _: Window, w: i32, h: i32) t.Error!void {
        self.resized = .{ w, h };
    }
    fn sleepMs(self: *FakeOps, ms: u64) void {
        self.sleeps += 1;
        self.slept_ms += ms;
    }
};

const raven_win: Window = .{ .id = "0xa", .title = "Seridian", .class = "raven", .w = 100, .h = 100, .floating = true, .pid = 42 };
const other_pid_win: Window = .{ .id = "0xb", .title = "Seridian", .class = "raven", .w = 100, .h = 100, .floating = true, .pid = 99 };

test "pollForWindow: bounded retries when nothing matches" {
    const empty: []const Window = &.{};
    var ops: FakeOps = .{ .snapshots = &.{empty} };
    const found = try pollForWindow(std.testing.allocator, &ops, "raven", null);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), found.hits.len);
    try std.testing.expectEqual(find_max_attempts, ops.lists);
    try std.testing.expectEqual(find_max_attempts - 1, ops.sleeps);
    try std.testing.expectEqual(@as(u64, 3000), ops.slept_ms);
}

test "pollForWindow: stops as soon as the window appears" {
    const empty: []const Window = &.{};
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{ empty, empty, present } };
    const found = try pollForWindow(std.testing.allocator, &ops, "raven", null);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), found.hits.len);
    try std.testing.expectEqual(@as(usize, 3), ops.lists);
    try std.testing.expectEqual(@as(usize, 2), ops.sleeps);
}

test "pollForWindow: a window with the wrong pid never matches" {
    const wrong: []const Window = &.{other_pid_win};
    var ops: FakeOps = .{ .snapshots = &.{wrong} };
    const found = try pollForWindow(std.testing.allocator, &ops, "raven", 42);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), found.hits.len);
    try std.testing.expectEqual(find_max_attempts, ops.lists);
}

test "pollForWindow: pid picks one of two otherwise identical windows" {
    const both: []const Window = &.{ other_pid_win, raven_win };
    var ops: FakeOps = .{ .snapshots = &.{both} };
    const found = try pollForWindow(std.testing.allocator, &ops, "raven", 42);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), found.hits.len);
    try std.testing.expectEqualStrings("0xa", found.wins[found.hits[0]].id);
    try std.testing.expectEqual(@as(usize, 0), ops.sleeps);
}

fn runSize(ops: *FakeOps, backend: Backend, pid: ?i64, w: i32, h: i32, out_buf: []u8, err_buf: []u8) !struct { code: u8, out: []const u8, err: []const u8 } {
    var out: std.Io.Writer = .fixed(out_buf);
    var err: std.Io.Writer = .fixed(err_buf);
    const code = try sizeWith(std.testing.allocator, ops, backend, "raven", w, h, pid, &out, &err);
    return .{ .code = code, .out = out.buffered(), .err = err.buffered() };
}

test "sizeWith: exit 0 when the readback matches" {
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{present} };
    var ob: [512]u8 = undefined;
    var eb: [512]u8 = undefined;
    const r = try runSize(&ops, .hyprland, 42, 800, 600, &ob, &eb);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "step verify: ok size 800x600") != null);
    try std.testing.expectEqual(@as([2]i32, .{ 800, 600 }), ops.resized.?);
}

test "sizeWith: exit 1 and bounded readback when the size differs" {
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{present}, .applied = .{ 640, 480 } };
    var ob: [512]u8 = undefined;
    var eb: [512]u8 = undefined;
    const r = try runSize(&ops, .hyprland, null, 800, 600, &ob, &eb);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "size mismatch: requested 800x600, window reports 640x480") != null);
    // 1 find list + verify_max_attempts readbacks, sleeping between readbacks only.
    try std.testing.expectEqual(1 + verify_max_attempts, ops.lists);
    try std.testing.expectEqual(verify_max_attempts - 1, ops.sleeps);
}

test "sizeWith: NotFound after the bounded wait, exit 1" {
    const empty: []const Window = &.{};
    var ops: FakeOps = .{ .snapshots = &.{empty} };
    var ob: [512]u8 = undefined;
    var eb: [512]u8 = undefined;
    const r = try runSize(&ops, .hyprland, null, 800, 600, &ob, &eb);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqual(find_max_attempts, ops.lists);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "no windows found") != null);
    try std.testing.expect(ops.resized == null);
}

test "sizeWith: --pid on a backend without pids is an error and does no work" {
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{present} };
    var ob: [512]u8 = undefined;
    var eb: [512]u8 = undefined;
    const r = try runSize(&ops, .sway, 42, 800, 600, &ob, &eb);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("pid filter not supported here\n", r.err);
    try std.testing.expectEqual(@as(usize, 0), ops.lists);
}

test "placeWith: moves, resizes and verifies" {
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{present} };
    var ob: [1024]u8 = undefined;
    var eb: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    const mon: monitors.Monitor = .{ .name = "DP-1", .x = 1920, .y = 0, .w = 1920, .h = 1080 };
    const code = try placeWith(std.testing.allocator, &ops, .hyprland, "raven", mon, .{ .x = 1930, .y = 10, .w = 800, .h = 600 }, 42, &out, &err);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as([2]i32, .{ 1930, 10 }), ops.moved.?);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "step verify: ok size 800x600") != null);
}

test "placeWith: size mismatch exits 1" {
    const present: []const Window = &.{raven_win};
    var ops: FakeOps = .{ .snapshots = &.{present}, .applied = .{ 700, 600 } };
    var ob: [1024]u8 = undefined;
    var eb: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&ob);
    var err: std.Io.Writer = .fixed(&eb);
    const mon: monitors.Monitor = .{ .name = "DP-1", .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const code = try placeWith(std.testing.allocator, &ops, .hyprland, "raven", mon, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, null, &out, &err);
    try std.testing.expectEqual(@as(u8, 1), code);
}

test "none backend reports unsupported for every op" {
    try std.testing.expect(reason(.none, .list) != null);
    try std.testing.expect(reason(.hyprland, .move) == null);
    try std.testing.expect(reason(.x11, .float) != null);
}

test {
    _ = hyprland;
    _ = sway;
    _ = kwin;
    _ = x11;
    _ = gnome_wayland;
    _ = monitors;
    _ = t;
}

const list_ = list;
const float_ = float;
const move_ = move;
const resize_ = resize;
