//! Monitor listing and placement math for `seridian wm monitors` / `wm place`.
//!
//! Parsers are pure and tested against fixtures. Each backend reports monitors in
//! its own coordinate space (Hyprland and Sway layout coordinates, X11 root
//! coordinates); `place` uses those numbers unchanged. xrandr is consulted only
//! for the X11 backend (see `wm.monitorsForActiveBackend`).

const std = @import("std");
const t = @import("types.zig");
const xrandr = @import("../../config/monitors.zig");

pub const Monitor = struct {
    /// Output name as the backend reports it, e.g. "DP-1". Owned.
    name: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn freeMonitors(allocator: std.mem.Allocator, mons: []Monitor) void {
    for (mons) |m| allocator.free(m.name);
    allocator.free(mons);
}

fn freeList(allocator: std.mem.Allocator, found: *std.ArrayList(Monitor)) void {
    for (found.items) |m| allocator.free(m.name);
    found.deinit(allocator);
}

fn intOf(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn parseJsonArray(allocator: std.mem.Allocator, json: []const u8) t.Error!std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    if (parsed.value != .array) {
        parsed.deinit();
        return error.CommandFailed;
    }
    return parsed;
}

fn append(allocator: std.mem.Allocator, found: *std.ArrayList(Monitor), name: []const u8, x: i32, y: i32, w: i32, h: i32) std.mem.Allocator.Error!void {
    const copy = try allocator.dupe(u8, name);
    errdefer allocator.free(copy);
    try found.append(allocator, .{ .name = copy, .x = x, .y = y, .w = w, .h = h });
}

/// Parses `hyprctl -j monitors`. Entries with missing or malformed fields are
/// skipped and counted. Caller frees with `freeMonitors`.
pub fn parseHyprland(allocator: std.mem.Allocator, json: []const u8, skipped: *usize) t.Error![]Monitor {
    const parsed = try parseJsonArray(allocator, json);
    defer parsed.deinit();
    var found: std.ArrayList(Monitor) = .empty;
    errdefer freeList(allocator, &found);
    for (parsed.value.array.items) |item| {
        const ok = blk: {
            const obj = switch (item) {
                .object => |o| o,
                else => break :blk false,
            };
            const name = strOf(obj, "name") orelse break :blk false;
            const x = intOf(obj, "x") orelse break :blk false;
            const y = intOf(obj, "y") orelse break :blk false;
            const w = intOf(obj, "width") orelse break :blk false;
            const h = intOf(obj, "height") orelse break :blk false;
            if (!t.validGeometry(w, h)) break :blk false;
            try append(allocator, &found, name, x, y, w, h);
            break :blk true;
        };
        if (!ok) skipped.* += 1;
    }
    return found.toOwnedSlice(allocator);
}

/// Parses `swaymsg -t get_outputs` (raw JSON). Inactive outputs are left out.
pub fn parseSway(allocator: std.mem.Allocator, json: []const u8, skipped: *usize) t.Error![]Monitor {
    const parsed = try parseJsonArray(allocator, json);
    defer parsed.deinit();
    var found: std.ArrayList(Monitor) = .empty;
    errdefer freeList(allocator, &found);
    for (parsed.value.array.items) |item| {
        const ok = blk: {
            const obj = switch (item) {
                .object => |o| o,
                else => break :blk false,
            };
            const name = strOf(obj, "name") orelse break :blk false;
            if (obj.get("active")) |a| switch (a) {
                .bool => |b| if (!b) break :blk true, // inactive: neither listed nor malformed
                else => break :blk false,
            };
            const rect = switch (obj.get("rect") orelse break :blk false) {
                .object => |r| r,
                else => break :blk false,
            };
            const x = intOf(rect, "x") orelse break :blk false;
            const y = intOf(rect, "y") orelse break :blk false;
            const w = intOf(rect, "width") orelse break :blk false;
            const h = intOf(rect, "height") orelse break :blk false;
            if (!t.validGeometry(w, h)) break :blk false;
            try append(allocator, &found, name, x, y, w, h);
            break :blk true;
        };
        if (!ok) skipped.* += 1;
    }
    return found.toOwnedSlice(allocator);
}

/// Parses `xrandr --listmonitors`, reusing the geometry parser in
/// src/config/monitors.zig (one line at a time) and taking the output name
/// from the last column. Lines that are not monitor lines are ignored.
pub fn parseXrandr(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]Monitor {
    var found: std.ArrayList(Monitor) = .empty;
    errdefer freeList(allocator, &found);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const one = xrandr.parseListMonitors(line);
        if (one.len != 1) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        var last: []const u8 = "";
        var flags_name: []const u8 = "";
        var i: usize = 0;
        while (tokens.next()) |tok| : (i += 1) {
            if (i == 1) flags_name = tok;
            last = tok;
        }
        var name = last;
        if (i <= 3) name = std.mem.trimStart(u8, flags_name, "+*");
        if (name.len == 0) continue;
        const r = one.items[0];
        try append(allocator, &found, name, r.x, r.y, r.width, r.height);
    }
    return found.toOwnedSlice(allocator);
}

/// A resolved placement rectangle in the backend's own coordinates.
pub const Target = struct { x: i32, y: i32, w: i32, h: i32 };

/// Finds a monitor by exact name. NotFound when no monitor has that name.
pub fn find(mons: []const Monitor, name: []const u8) t.Error!Monitor {
    for (mons) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return error.NotFound;
}

/// A point resolved to the monitor containing it, with the offset from that monitor's origin.
pub const Located = struct { monitor: Monitor, dx: i32, dy: i32 };

/// The monitor containing the point (px, py) in the backend's own coordinates, and the
/// offset of the point from that monitor's origin. Null when no monitor contains it.
pub fn locate(mons: []const Monitor, px: i32, py: i32) ?Located {
    for (mons) |m| {
        const inside = @as(i64, px) >= m.x and @as(i64, py) >= m.y and
            @as(i64, px) < @as(i64, m.x) + m.w and @as(i64, py) < @as(i64, m.y) + m.h;
        if (inside) return .{ .monitor = m, .dx = px - m.x, .dy = py - m.y };
    }
    return null;
}

/// Monitor origin plus offset. CommandFailed when the sum does not fit i32 or
/// the size is not positive.
pub fn target(m: Monitor, dx: i32, dy: i32, w: i32, h: i32) t.Error!Target {
    if (!t.validGeometry(w, h)) return error.CommandFailed;
    const x = std.math.add(i32, m.x, dx) catch return error.CommandFailed;
    const y = std.math.add(i32, m.y, dy) catch return error.CommandFailed;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// Runs `hyprctl -j monitors`.
pub fn listHyprland(allocator: std.mem.Allocator) t.Error![]Monitor {
    const r = try t.capture(allocator, &.{ "hyprctl", "-j", "monitors" });
    defer r.deinit(allocator);
    try t.requireSuccess(r);
    var skipped: usize = 0;
    const mons = try parseHyprland(allocator, r.out, &skipped);
    t.warnSkipped("hyprland", skipped);
    return mons;
}

/// Runs `swaymsg -t get_outputs -r`.
pub fn listSway(allocator: std.mem.Allocator) t.Error![]Monitor {
    const r = try t.capture(allocator, &.{ "swaymsg", "-t", "get_outputs", "-r" });
    defer r.deinit(allocator);
    try t.requireSuccess(r);
    var skipped: usize = 0;
    const mons = try parseSway(allocator, r.out, &skipped);
    t.warnSkipped("sway", skipped);
    return mons;
}

/// Runs `xrandr --listmonitors` (X11 and XWayland).
pub fn listX11(allocator: std.mem.Allocator) t.Error![]Monitor {
    const r = try t.capture(allocator, &.{ "xrandr", "--listmonitors" });
    defer r.deinit(allocator);
    try t.requireSuccess(r);
    return parseXrandr(allocator, r.out);
}

const hypr_fixture =
    \\[{"id":0,"name":"DP-1","description":"X","x":0,"y":0,"width":2560,"height":1440,"scale":1.0,"focused":true},
    \\ {"id":1,"name":"HDMI-A-1","x":-1920,"y":-200,"width":1920,"height":1080,"scale":1.0},
    \\ {"id":2,"name":"","x":0,"y":0,"width":10,"height":10},
    \\ {"id":3,"name":"BAD","x":0,"y":0,"width":0,"height":10},
    \\ 7]
;

const sway_fixture =
    \\[{"name":"DP-1","active":true,"rect":{"x":0,"y":0,"width":2560,"height":1440},"current_mode":{"width":2560,"height":1440}},
    \\ {"name":"HDMI-A-1","active":true,"rect":{"x":2560,"y":-120,"width":1920,"height":1080}},
    \\ {"name":"eDP-1","active":false,"rect":{"x":0,"y":0,"width":0,"height":0}},
    \\ {"name":"NORECT","active":true}]
;

const xrandr_fixture =
    \\Monitors: 2
    \\ 0: +*DP-1 2560/597x1440/336+0+0  DP-1
    \\ 1: +HDMI-1 1920/510x1080/287+-1920+0  HDMI-1
    \\
;

fn expectMon(m: Monitor, name: []const u8, x: i32, y: i32, w: i32, h: i32) !void {
    try std.testing.expectEqualStrings(name, m.name);
    try std.testing.expectEqual(x, m.x);
    try std.testing.expectEqual(y, m.y);
    try std.testing.expectEqual(w, m.w);
    try std.testing.expectEqual(h, m.h);
}

test "parse hyprland monitors" {
    var skipped: usize = 0;
    const mons = try parseHyprland(std.testing.allocator, hypr_fixture, &skipped);
    defer freeMonitors(std.testing.allocator, mons);
    try std.testing.expectEqual(@as(usize, 2), mons.len);
    try std.testing.expectEqual(@as(usize, 3), skipped);
    try expectMon(mons[0], "DP-1", 0, 0, 2560, 1440);
    try expectMon(mons[1], "HDMI-A-1", -1920, -200, 1920, 1080);
}

test "parse sway outputs skips inactive and malformed" {
    var skipped: usize = 0;
    const mons = try parseSway(std.testing.allocator, sway_fixture, &skipped);
    defer freeMonitors(std.testing.allocator, mons);
    try std.testing.expectEqual(@as(usize, 2), mons.len);
    try std.testing.expectEqual(@as(usize, 1), skipped);
    try expectMon(mons[0], "DP-1", 0, 0, 2560, 1440);
    try expectMon(mons[1], "HDMI-A-1", 2560, -120, 1920, 1080);
}

test "parse xrandr listmonitors" {
    const mons = try parseXrandr(std.testing.allocator, xrandr_fixture);
    defer freeMonitors(std.testing.allocator, mons);
    try std.testing.expectEqual(@as(usize, 2), mons.len);
    try expectMon(mons[0], "DP-1", 0, 0, 2560, 1440);
    try expectMon(mons[1], "HDMI-1", -1920, 0, 1920, 1080);
}

test "parse xrandr line without trailing output column uses the flags name" {
    const mons = try parseXrandr(std.testing.allocator, " 0: +*eDP-1 1920/344x1080/194+0+0\n");
    defer freeMonitors(std.testing.allocator, mons);
    try std.testing.expectEqual(@as(usize, 1), mons.len);
    try std.testing.expectEqualStrings("eDP-1", mons[0].name);
}

test "monitor parsers reject malformed input" {
    var skipped: usize = 0;
    try std.testing.expectError(error.CommandFailed, parseHyprland(std.testing.allocator, "nope", &skipped));
    try std.testing.expectError(error.CommandFailed, parseSway(std.testing.allocator, "{}", &skipped));
    const none = try parseXrandr(std.testing.allocator, "Can't open display\n");
    defer freeMonitors(std.testing.allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "place coordinate math: monitor origin plus offset" {
    const mons = [_]Monitor{
        .{ .name = "DP-1", .x = 0, .y = 0, .w = 2560, .h = 1440 },
        .{ .name = "HDMI-A-1", .x = -1920, .y = -200, .w = 1920, .h = 1080 },
        .{ .name = "DP-2", .x = 2560, .y = 120, .w = 1920, .h = 1080 },
    };
    const Case = struct { mon: []const u8, dx: i32, dy: i32, want: ?Target, err: ?t.Error = null };
    const cases = [_]Case{
        .{ .mon = "DP-1", .dx = 10, .dy = 20, .want = .{ .x = 10, .y = 20, .w = 800, .h = 600 } },
        .{ .mon = "HDMI-A-1", .dx = 100, .dy = 50, .want = .{ .x = -1820, .y = -150, .w = 800, .h = 600 } },
        .{ .mon = "DP-2", .dx = 0, .dy = 0, .want = .{ .x = 2560, .y = 120, .w = 800, .h = 600 } },
        .{ .mon = "DP-2", .dx = -60, .dy = -20, .want = .{ .x = 2500, .y = 100, .w = 800, .h = 600 } },
        .{ .mon = "dp-1", .dx = 0, .dy = 0, .want = null, .err = error.NotFound },
        .{ .mon = "eDP-9", .dx = 0, .dy = 0, .want = null, .err = error.NotFound },
        .{ .mon = "", .dx = 0, .dy = 0, .want = null, .err = error.NotFound },
    };
    for (cases) |c| {
        const got = blk: {
            const m = find(&mons, c.mon) catch |e| {
                try std.testing.expectEqual(c.err.?, e);
                continue;
            };
            break :blk try target(m, c.dx, c.dy, 800, 600);
        };
        try std.testing.expectEqual(c.want.?, got);
    }
}

test "place target rejects overflow and non-positive size" {
    const m: Monitor = .{ .name = "A", .x = std.math.maxInt(i32), .y = 0, .w = 1, .h = 1 };
    try std.testing.expectError(error.CommandFailed, target(m, 1, 0, 10, 10));
    try std.testing.expectError(error.CommandFailed, target(m, 0, 0, 0, 10));
    try std.testing.expectError(error.CommandFailed, target(m, 0, 0, 10, -1));
}

test "hyprland layout: window at x=2220 is on HDMI-A-1 with dx=300" {
    const json =
        \\[{"id":0,"name":"DP-3","x":0,"y":0,"width":1920,"height":1080,"scale":1.0,"focused":true},
        \\ {"id":1,"name":"HDMI-A-1","x":1920,"y":0,"width":1920,"height":1080,"scale":1.0}]
    ;
    var skipped: usize = 0;
    const mons = try parseHyprland(std.testing.allocator, json, &skipped);
    defer freeMonitors(std.testing.allocator, mons);
    try std.testing.expectEqual(@as(usize, 0), skipped);
    const hit = locate(mons, 2220, 150) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HDMI-A-1", hit.monitor.name);
    try std.testing.expectEqual(@as(i32, 300), hit.dx);
    try std.testing.expectEqual(@as(i32, 150), hit.dy);
    const first = locate(mons, 1919, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("DP-3", first.monitor.name);
    try std.testing.expect(locate(mons, 3840, 0) == null);
}
