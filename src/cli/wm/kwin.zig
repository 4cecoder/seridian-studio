//! KDE Plasma (KWin) backend, driven through `kdotool`. `qdbus` alone cannot
//! enumerate windows, so without kdotool every operation reports unavailable.

const std = @import("std");
const t = @import("types.zig");
const x11 = @import("x11.zig");

pub const unavailable_reason = "not available: install kdotool (qdbus alone cannot list or move KWin windows)";

pub fn reason(op: t.Op) ?[]const u8 {
    return switch (op) {
        .float => "KWin does not tile by default; windows are already floating",
        else => null,
    };
}

/// Parses `kdotool search` output: one window UUID per line, usually in
/// braces. A non-empty line that is not a UUID is counted in `skipped`.
/// Returns slices of `text` in a newly allocated list.
pub fn parseIds(allocator: std.mem.Allocator, text: []const u8, skipped: *usize) std.mem.Allocator.Error![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!looksLikeUuid(line)) {
            skipped.* += 1;
            continue;
        }
        try ids.append(allocator, line);
    }
    return ids.toOwnedSlice(allocator);
}

fn looksLikeUuid(line: []const u8) bool {
    const inner = std.mem.trim(u8, line, "{}");
    if (inner.len != 36) return false;
    for (inner, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// kdotool geometry output has the same shape as xdotool's plain output.
pub fn parseGeometry(text: []const u8) ?x11.Geometry {
    return x11.parseGeometryPlain(text);
}

/// Reads one window. Null when title, class or geometry is missing or
/// malformed (including the window vanishing between search and query).
fn describe(allocator: std.mem.Allocator, id: []const u8) std.mem.Allocator.Error!?t.Window {
    const title = t.captureTrimmed(allocator, &.{ "kdotool", "getwindowname", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(title);
    const class = t.captureTrimmed(allocator, &.{ "kdotool", "getwindowclassname", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(class);
    const geo_out = t.capture(allocator, &.{ "kdotool", "getwindowgeometry", id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer geo_out.deinit(allocator);
    if (!geo_out.ok()) return null;
    const geo = parseGeometry(geo_out.out) orelse return null;
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

pub fn list(allocator: std.mem.Allocator) t.Error![]t.Window {
    if (!t.haveTool("kdotool")) return error.Unavailable;
    const found = try t.capture(allocator, &.{ "kdotool", "search", "--name", "." });
    defer found.deinit(allocator);
    try t.requireSuccess(found);
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
    t.warnSkipped("kwin", skipped);
    return wins.toOwnedSlice(allocator);
}

pub fn float(_: std.mem.Allocator, _: t.Window) t.Error!void {}

pub fn move(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    var xb: [16]u8 = undefined;
    var yb: [16]u8 = undefined;
    const xs = std.fmt.bufPrint(&xb, "{d}", .{x}) catch return error.CommandFailed;
    const ys = std.fmt.bufPrint(&yb, "{d}", .{y}) catch return error.CommandFailed;
    try t.runChecked(allocator, &.{ "kdotool", "windowmove", win.id, xs, ys });
}

pub fn resize(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    var wb: [16]u8 = undefined;
    var hb: [16]u8 = undefined;
    const ws = std.fmt.bufPrint(&wb, "{d}", .{w}) catch return error.CommandFailed;
    const hs = std.fmt.bufPrint(&hb, "{d}", .{h}) catch return error.CommandFailed;
    try t.runChecked(allocator, &.{ "kdotool", "windowsize", win.id, ws, hs });
}

test "kdotool search output parses uuids and counts noise" {
    const text = "{3f0c1a2e-0b1d-4c5e-9a7f-1234567890ab}\n{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}\nnot a uuid\n{short}\n";
    var skipped: usize = 0;
    const ids = try parseIds(std.testing.allocator, text, &skipped);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(@as(usize, 2), skipped);
    try std.testing.expectEqualStrings("{3f0c1a2e-0b1d-4c5e-9a7f-1234567890ab}", ids[0]);
}

test "kdotool geometry output parses" {
    const g = parseGeometry("Window {3f0c1a2e-0b1d-4c5e-9a7f-1234567890ab}\n  Position: 100,200\n  Geometry: 1280x720\n").?;
    try std.testing.expectEqual(@as(i32, 100), g.x);
    try std.testing.expectEqual(@as(i32, 200), g.y);
    try std.testing.expectEqual(@as(i32, 1280), g.w);
    try std.testing.expectEqual(@as(i32, 720), g.h);
}

test "kdotool geometry is strict" {
    const bad = [_][]const u8{
        "garbage",
        "",
        "Position: 100,200\n",
        "Geometry: 1280x720\n",
        "Position: 100,200\nGeometry: 0x0\n",
        "Position: 100;200\nGeometry: 1280x720\n",
        "Position: 100,200\nGeometry: 1280\n",
    };
    for (bad) |text| try std.testing.expect(parseGeometry(text) == null);
}
