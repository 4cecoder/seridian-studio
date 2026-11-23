//! X11 backend, driven through `xdotool`. Also used for X11 clients under
//! XWayland on GNOME and KDE, and for real X11 sessions.

const std = @import("std");
const t = @import("types.zig");

pub const unavailable_reason = "not available: xdotool failed; install xdotool and make sure DISPLAY is set";

pub fn reason(op: t.Op) ?[]const u8 {
    return switch (op) {
        .float => "X11 windows are not tiled; there is nothing to float",
        else => null,
    };
}

pub const Geometry = struct { x: i32, y: i32, w: i32, h: i32 };

/// Parses `xdotool search` output: one decimal window id per line. A
/// non-empty line that is not a positive decimal id is counted in `skipped`.
/// Returns the ids as slices of `text` in a newly allocated list.
pub fn parseIds(allocator: std.mem.Allocator, text: []const u8, skipped: *usize) std.mem.Allocator.Error![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const id = std.fmt.parseInt(u64, line, 10) catch {
            skipped.* += 1;
            continue;
        };
        if (id == 0) {
            skipped.* += 1;
            continue;
        }
        try ids.append(allocator, line);
    }
    return ids.toOwnedSlice(allocator);
}

/// Parses `xdotool getwindowgeometry --shell` output (X=, Y=, WIDTH=, HEIGHT=).
pub fn parseGeometryShell(text: []const u8) ?Geometry {
    var g: Geometry = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var seen: u8 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.fmt.parseInt(i32, line[eq + 1 ..], 10) catch continue;
        const key = line[0..eq];
        if (std.mem.eql(u8, key, "X")) {
            g.x = value;
            seen |= 1;
        } else if (std.mem.eql(u8, key, "Y")) {
            g.y = value;
            seen |= 2;
        } else if (std.mem.eql(u8, key, "WIDTH")) {
            g.w = value;
            seen |= 4;
        } else if (std.mem.eql(u8, key, "HEIGHT")) {
            g.h = value;
            seen |= 8;
        }
    }
    if (seen != 15 or !t.validGeometry(g.w, g.h)) return null;
    return g;
}

/// Parses the default (non --shell) `xdotool getwindowgeometry` output:
///   Window 123
///     Position: 10,20 (screen: 0)
///     Geometry: 800x600
pub fn parseGeometryPlain(text: []const u8) ?Geometry {
    var pos: ?[2]i32 = null;
    var size: ?[2]i32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Position:")) {
            const rest = std.mem.trim(u8, line["Position:".len..], " ");
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            pos = parsePair(rest[0..end], ',');
        } else if (std.mem.startsWith(u8, line, "Geometry:")) {
            size = parsePair(std.mem.trim(u8, line["Geometry:".len..], " "), 'x');
        }
    }
    const p = pos orelse return null;
    const s = size orelse return null;
    if (!t.validGeometry(s[0], s[1])) return null;
    return .{ .x = p[0], .y = p[1], .w = s[0], .h = s[1] };
}

pub fn parsePair(text: []const u8, sep: u8) ?[2]i32 {
    const i = std.mem.indexOfScalar(u8, text, sep) orelse return null;
    const a = std.fmt.parseInt(i32, text[0..i], 10) catch return null;
    const b = std.fmt.parseInt(i32, text[i + 1 ..], 10) catch return null;
    return .{ a, b };
}

/// Reads one window. Null when any of title, class or geometry is missing or
/// malformed (including the window vanishing between search and query).
fn describe(allocator: std.mem.Allocator, id: []const u8) std.mem.Allocator.Error!?t.Window {
    const title = t.captureTrimmed(allocator, &.{ "xdotool", "getwindowname", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(title);
    const class = t.captureTrimmed(allocator, &.{ "xdotool", "getwindowclassname", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(class);
    const geo_out = t.capture(allocator, &.{ "xdotool", "getwindowgeometry", "--shell", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer geo_out.deinit(allocator);
    if (!geo_out.ok()) return null;
    const geo = parseGeometryShell(geo_out.out) orelse return null;
    return try t.makeWindow(allocator, .{
        .id = id,
        .title = title,
        .class = class,
        .x = geo.x,
        .y = geo.y,
        .w = geo.w,
        .h = geo.h,
        .floating = true,
    });
}

/// Interprets a finished `xdotool search`. Exit status 1 with no output means
/// nothing matched, which is NotFound rather than a failure.
pub fn checkSearch(result: t.Captured) t.Error!void {
    if (result.ok()) return;
    if (result.status() == 1 and std.mem.trim(u8, result.out, " \t\r\n").len == 0) return error.NotFound;
    try t.requireSuccess(result);
}

pub fn list(allocator: std.mem.Allocator) t.Error![]t.Window {
    const found = try t.capture(allocator, &.{ "xdotool", "search", "--onlyvisible", "--name", "." });
    defer found.deinit(allocator);
    try checkSearch(found);
    var skipped: usize = 0;
    const ids = try parseIds(allocator, found.out, &skipped);
    defer allocator.free(ids);
    if (ids.len == 0 and skipped == 0) return error.NotFound;

    var wins: std.ArrayList(t.Window) = .empty;
    errdefer {
        for (wins.items) |win| t.freeWindow(allocator, win);
        wins.deinit(allocator);
    }
    for (ids) |id| {
        const win = (try describe(allocator, id)) orelse {
            skipped += 1;
            continue;
        };
        errdefer t.freeWindow(allocator, win);
        try wins.append(allocator, win);
    }
    t.warnSkipped("x11", skipped);
    return wins.toOwnedSlice(allocator);
}

pub fn float(_: std.mem.Allocator, _: t.Window) t.Error!void {}

pub fn move(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    var xb: [16]u8 = undefined;
    var yb: [16]u8 = undefined;
    const xs = std.fmt.bufPrint(&xb, "{d}", .{x}) catch return error.CommandFailed;
    const ys = std.fmt.bufPrint(&yb, "{d}", .{y}) catch return error.CommandFailed;
    try t.runChecked(allocator, &.{ "xdotool", "windowmove", win.id, xs, ys });
}

pub fn resize(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    var wb: [16]u8 = undefined;
    var hb: [16]u8 = undefined;
    const ws = std.fmt.bufPrint(&wb, "{d}", .{w}) catch return error.CommandFailed;
    const hs = std.fmt.bufPrint(&hb, "{d}", .{h}) catch return error.CommandFailed;
    try t.runChecked(allocator, &.{ "xdotool", "windowsize", win.id, ws, hs });
}

test "xdotool search output parses ids and counts noise" {
    var skipped: usize = 0;
    const ids = try parseIds(std.testing.allocator, "44040194\n 62914563 \n\nwarning: x\n0\n-5\n", &skipped);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("44040194", ids[0]);
    try std.testing.expectEqualStrings("62914563", ids[1]);
    try std.testing.expectEqual(@as(usize, 3), skipped);
}

test "xdotool search exit status: no match is NotFound, other failures are CommandFailed" {
    const cases = [_]struct { exit: t.Exit, out: []const u8, want: ?t.Error }{
        .{ .exit = .{ .code = 0 }, .out = "1\n", .want = null },
        .{ .exit = .{ .code = 1 }, .out = "", .want = error.NotFound },
        .{ .exit = .{ .code = 1 }, .out = "\n", .want = error.NotFound },
        .{ .exit = .{ .code = 1 }, .out = "123\n", .want = error.CommandFailed },
        .{ .exit = .{ .code = 2 }, .out = "", .want = error.CommandFailed },
        .{ .exit = .{ .code = 127 }, .out = "", .want = error.CommandFailed },
        .{ .exit = .abnormal, .out = "", .want = error.CommandFailed },
    };
    for (cases) |case| {
        const result: t.Captured = .{ .out = @constCast(case.out), .exit = case.exit };
        if (case.want) |err| {
            try std.testing.expectError(err, checkSearch(result));
        } else {
            try checkSearch(result);
        }
    }
    t.clearDetail();
}

test "xdotool shell geometry parses" {
    const g = parseGeometryShell("WINDOW=44040194\nX=1930\nY=90\nWIDTH=1900\nHEIGHT=980\nSCREEN=0\n").?;
    try std.testing.expectEqual(@as(i32, 1930), g.x);
    try std.testing.expectEqual(@as(i32, 90), g.y);
    try std.testing.expectEqual(@as(i32, 1900), g.w);
    try std.testing.expectEqual(@as(i32, 980), g.h);
}

test "xdotool geometry is strict: missing, malformed or empty-size fields are rejected" {
    const shell_bad = [_][]const u8{
        "X=1\nY=2\n",
        "X=1\nY=2\nWIDTH=3\n",
        "X=1\nY=2\nWIDTH=abc\nHEIGHT=4\n",
        "X=\nY=2\nWIDTH=3\nHEIGHT=4\n",
        "X=1\nY=2\nWIDTH=0\nHEIGHT=0\n",
        "X=1\nY=2\nWIDTH=-3\nHEIGHT=4\n",
        "",
    };
    for (shell_bad) |text| try std.testing.expect(parseGeometryShell(text) == null);
    const plain_bad = [_][]const u8{
        "Window 1\n  Position: 10,20 (screen: 0)\n",
        "Window 1\n  Geometry: 800x600\n",
        "Window 1\n  Position: 10;20\n  Geometry: 800x600\n",
        "Window 1\n  Position: 10,20\n  Geometry: 0x0\n",
        "Window 1\n  Position: 10,20\n  Geometry: axb\n",
        "",
    };
    for (plain_bad) |text| try std.testing.expect(parseGeometryPlain(text) == null);
}

test "xdotool plain geometry parses" {
    const g = parseGeometryPlain("Window 44040194\n  Position: 10,-20 (screen: 0)\n  Geometry: 800x600\n").?;
    try std.testing.expectEqual(@as(i32, 10), g.x);
    try std.testing.expectEqual(@as(i32, -20), g.y);
    try std.testing.expectEqual(@as(i32, 800), g.w);
    try std.testing.expectEqual(@as(i32, 600), g.h);
}
