//! Monitor geometry for keeping a restored window on screen. The source of truth is `seridian wm monitors`
//! (the wm layer picks Hyprland, Sway or X11 itself); `parseListMonitors` remains for the X11 backend's xrandr output.
//!
//! The parsers are pure; `monitorContaining` asks the wm layer and returns null when the query fails, so callers
//! can leave a window where it is instead of guessing a rectangle.

const std = @import("std");
const sys = @import("../utils/sys.zig");

const log = std.log.scoped(.monitors);

/// A rectangle in screen coordinates.
pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    /// True when the point lies inside the rectangle.
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and
            @as(i64, px) < @as(i64, self.x) + self.width and
            @as(i64, py) < @as(i64, self.y) + self.height;
    }
};

/// Most monitors the parser keeps.
pub const max_monitors = 16;

pub const MonitorList = struct {
    items: [max_monitors]Rect = undefined,
    len: usize = 0,

    pub fn slice(self: *const MonitorList) []const Rect {
        return self.items[0..self.len];
    }
};

/// Parses a geometry token such as `2560/597x1440/336+0+0` or `1920/510x1080/287+-1920+0`.
fn parseGeometry(token: []const u8) ?Rect {
    const slash1 = std.mem.indexOfScalar(u8, token, '/') orelse return null;
    const width = std.fmt.parseInt(i32, token[0..slash1], 10) catch return null;
    const rest = token[slash1 + 1 ..];
    const x_sep = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    // Skip the millimetre width, then read "<height>/<mm>+<x>+<y>".
    const after_x = rest[x_sep + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, after_x, '/') orelse return null;
    const height = std.fmt.parseInt(i32, after_x[0..slash2], 10) catch return null;
    const tail = after_x[slash2 + 1 ..];
    const plus1 = std.mem.indexOfScalar(u8, tail, '+') orelse return null;
    const offsets = tail[plus1 + 1 ..];
    const plus2 = std.mem.indexOfScalarPos(u8, offsets, 0, '+') orelse return null;
    const x = std.fmt.parseInt(i32, offsets[0..plus2], 10) catch return null;
    const y = std.fmt.parseInt(i32, offsets[plus2 + 1 ..], 10) catch return null;
    if (width <= 0 or height <= 0) return null;
    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Parses the output of `xrandr --listmonitors`. Lines that are not monitor lines are skipped.
pub fn parseListMonitors(output: []const u8) MonitorList {
    var list: MonitorList = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (list.len == max_monitors) break;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const index = tokens.next() orelse continue; // "0:"
        if (index.len < 2 or index[index.len - 1] != ':') continue;
        _ = std.fmt.parseInt(u32, index[0 .. index.len - 1], 10) catch continue;
        _ = tokens.next() orelse continue; // flags and name, "+*DP-1"
        const geometry = tokens.next() orelse continue;
        const rect = parseGeometry(geometry) orelse continue;
        list.items[list.len] = rect;
        list.len += 1;
    }
    return list;
}

/// The monitor containing the point; null when none does.
pub fn findContaining(monitors: []const Rect, px: i32, py: i32) ?Rect {
    for (monitors) |monitor| {
        if (monitor.contains(px, py)) return monitor;
    }
    return null;
}

/// Asks the window-manager layer (`seridian wm monitors`) for the monitor containing the point. The layer
/// reports the active backend's own coordinates (Hyprland, Sway; xrandr only on X11). Null when the helper
/// is missing, fails, or no monitor contains the point.
pub fn monitorContaining(allocator: std.mem.Allocator, px: i32, py: i32) ?Rect {
    // run.sh sets SERIDIAN_CLI to the built CLI; PATH is only the fallback.
    const cli: []const u8 = sys.getenv("SERIDIAN_CLI") orelse "seridian";
    const output = sys.runCapture(allocator, &.{ cli, "wm", "monitors" }) catch |err| {
        log.warn("seridian wm monitors failed: {}", .{err});
        return null;
    };
    defer allocator.free(output);
    const list = parseWmMonitors(output);
    const hit = list.containing(px, py) orelse return null;
    return hit.rect;
}

/// Longest monitor name kept (bytes).
pub const max_name = 63;

pub const NamedMonitor = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    rect: Rect,

    pub fn name(self: *const NamedMonitor) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const NamedList = struct {
    items: [max_monitors]NamedMonitor = undefined,
    len: usize = 0,

    pub fn slice(self: *const NamedList) []const NamedMonitor {
        return self.items[0..self.len];
    }

    /// The monitor with exactly this name.
    pub fn find(self: *const NamedList, wanted: []const u8) ?NamedMonitor {
        for (self.slice()) |m| {
            if (std.mem.eql(u8, m.name(), wanted)) return m;
        }
        return null;
    }

    /// The monitor containing the point.
    pub fn containing(self: *const NamedList, px: i32, py: i32) ?NamedMonitor {
        for (self.slice()) |m| {
            if (m.rect.contains(px, py)) return m;
        }
        return null;
    }
};

/// True when `name` can be stored in popouts.conf and passed to `seridian wm place` as one argument:
/// 1 to `max_name` printable ASCII bytes without spaces.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| {
        if (c <= ' ' or c >= 0x7f) return false;
    }
    return true;
}

/// Parses the output of `seridian wm monitors`: one monitor per line, `<name> <x> <y> <width> <height>`
/// separated by whitespace. Lines that do not fit that shape are skipped.
pub fn parseWmMonitors(output: []const u8) NamedList {
    var list: NamedList = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (list.len == max_monitors) break;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = tokens.next() orelse continue;
        if (!isValidName(name)) continue;
        var v: [4]i32 = undefined;
        var ok = true;
        for (&v) |*slot| {
            const tok = tokens.next() orelse {
                ok = false;
                break;
            };
            slot.* = std.fmt.parseInt(i32, tok, 10) catch {
                ok = false;
                break;
            };
        }
        if (!ok or tokens.next() != null or v[2] <= 0 or v[3] <= 0) continue;
        var entry: NamedMonitor = .{ .rect = .{ .x = v[0], .y = v[1], .width = v[2], .height = v[3] } };
        @memcpy(entry.name_buf[0..name.len], name);
        entry.name_len = name.len;
        list.items[list.len] = entry;
        list.len += 1;
    }
    return list;
}

test "parseWmMonitors reads names and geometry and skips bad lines" {
    const list = parseWmMonitors("DP-1 0 0 2560 1440\nHDMI-1 -1920 0 1920 1080\nbad line\nX 1 2 0 5\nY 1 2 3 4 5\n");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("HDMI-1", list.items[1].name());
    try std.testing.expectEqual(Rect{ .x = -1920, .y = 0, .width = 1920, .height = 1080 }, list.items[1].rect);
    try std.testing.expect(list.find("DP-1") != null);
    try std.testing.expect(list.find("DP-2") == null);
    const hit = list.containing(-5, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HDMI-1", hit.name());
}

const sample =
    \\Monitors: 2
    \\ 0: +*DP-1 2560/597x1440/336+0+0  DP-1
    \\ 1: +HDMI-1 1920/510x1080/287+-1920+0  HDMI-1
    \\
;

test "parseListMonitors reads two monitors including a negative offset" {
    const list = parseListMonitors(sample);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 2560, .height = 1440 }, list.items[0]);
    try std.testing.expectEqual(Rect{ .x = -1920, .y = 0, .width = 1920, .height = 1080 }, list.items[1]);
}

test "parseListMonitors skips garbage and empty output" {
    try std.testing.expectEqual(@as(usize, 0), parseListMonitors("").len);
    try std.testing.expectEqual(@as(usize, 0), parseListMonitors("Monitors: 0\n").len);
    try std.testing.expectEqual(@as(usize, 0), parseListMonitors("Can't open display\n").len);
    try std.testing.expectEqual(@as(usize, 0), parseListMonitors(" 0: +*DP-1 banana/1xfoo/2+0+0  DP-1\n").len);
    try std.testing.expectEqual(@as(usize, 0), parseListMonitors(" 0: +*DP-1 0/0x0/0+0+0  DP-1\n").len);
}

test "findContaining picks the monitor holding the point" {
    const list = parseListMonitors(sample);
    const left = findContaining(list.slice(), -100, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, -1920), left.x);
    const main = findContaining(list.slice(), 2559, 1439) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 0), main.x);
    try std.testing.expect(findContaining(list.slice(), 2560, 0) == null);
    try std.testing.expect(findContaining(list.slice(), 0, -1) == null);
}
