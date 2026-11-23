//! Hyprland backend, driven through `hyprctl`.

const std = @import("std");
const t = @import("types.zig");

pub const unavailable_reason = "not available: hyprctl failed; is Hyprland running and hyprctl on PATH?";

pub fn reason(_: t.Op) ?[]const u8 {
    return null;
}

/// Reads `key` as a string, or null when missing or not a string.
fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn i32Of(v: std.json.Value) ?i32 {
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

/// The client's pid, or null when absent, not an integer, or not positive.
fn pidField(obj: std.json.ObjectMap) ?i64 {
    const v = obj.get("pid") orelse return null;
    return switch (v) {
        .integer => |i| if (i > 0) i else null,
        else => null,
    };
}

fn pairField(obj: std.json.ObjectMap, key: []const u8) ?[2]i32 {
    const v = obj.get(key) orelse return null;
    const items = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    if (items.len != 2) return null;
    const a = i32Of(items[0]) orelse return null;
    const b = i32Of(items[1]) orelse return null;
    return .{ a, b };
}

/// Parses one client object. Null when any field is missing or malformed.
fn parseClient(allocator: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!?t.Window {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const address = strField(obj, "address") orelse return null;
    if (address.len == 0) return null;
    const title = strField(obj, "title") orelse return null;
    const class = strField(obj, "class") orelse return null;
    const at = pairField(obj, "at") orelse return null;
    const size = pairField(obj, "size") orelse return null;
    if (!t.validGeometry(size[0], size[1])) return null;
    const floating = switch (obj.get("floating") orelse return null) {
        .bool => |b| b,
        else => return null,
    };
    const grouped = switch (obj.get("grouped") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    for (grouped) |g| switch (g) {
        .string => {},
        else => return null,
    };
    return try t.makeWindow(allocator, .{
        .id = address,
        .title = title,
        .class = class,
        .x = at[0],
        .y = at[1],
        .w = size[0],
        .h = size[1],
        .floating = floating,
        .grouped = grouped.len > 1,
        .pid = pidField(obj),
    });
}

/// Parses `hyprctl -j clients` output. A client with a missing or malformed
/// field is skipped and counted in `skipped`. Caller frees with t.freeWindows.
pub fn parseClients(allocator: std.mem.Allocator, json: []const u8, skipped: *usize) t.Error![]t.Window {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.CommandFailed,
    };

    var found: std.ArrayList(t.Window) = .empty;
    errdefer {
        for (found.items) |win| t.freeWindow(allocator, win);
        found.deinit(allocator);
    }
    for (items) |item| {
        const win = (try parseClient(allocator, item)) orelse {
            skipped.* += 1;
            continue;
        };
        errdefer t.freeWindow(allocator, win);
        try found.append(allocator, win);
    }
    return found.toOwnedSlice(allocator);
}

pub fn list(allocator: std.mem.Allocator) t.Error![]t.Window {
    const result = try t.capture(allocator, &.{ "hyprctl", "-j", "clients" });
    defer result.deinit(allocator);
    try t.requireSuccess(result);
    var skipped: usize = 0;
    const wins = try parseClients(allocator, result.out, &skipped);
    t.warnSkipped("hyprland", skipped);
    return wins;
}

/// Hyprland dispatchers print "ok" on success and an error message otherwise,
/// usually with exit status 0. Anything but "ok" (case-insensitive, trimmed)
/// is a failure and the output becomes the detail.
pub fn checkDispatchOutput(output: []const u8) t.Error!void {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "ok")) return;
    t.setDetail(if (trimmed.len == 0) "empty dispatch output" else trimmed);
    return error.CommandFailed;
}

fn dispatch(allocator: std.mem.Allocator, command: []const u8, args: []const u8) t.Error!void {
    const argv = [_][]const u8{ "hyprctl", "dispatch", command, args };
    const result = try t.capture(allocator, &argv);
    defer result.deinit(allocator);
    try t.requireSuccess(result);
    try checkDispatchOutput(result.out);
}

/// Builds the `exact` argument text, e.g. "exact 100 200,address:0xabc".
pub fn pixelArgs(buf: []u8, x: i32, y: i32, address: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "exact {d} {d},address:{s}", .{ x, y, address });
}

fn selector(buf: []u8, address: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "address:{s}", .{address});
}

pub fn float(allocator: std.mem.Allocator, win: t.Window) t.Error!void {
    if (win.floating) return;
    var buf: [128]u8 = undefined;
    const sel = selector(&buf, win.id) catch return error.CommandFailed;
    try dispatch(allocator, "togglefloating", sel);
}

/// Moves a grouped window out of its group. Only call for grouped windows.
pub fn ungroup(allocator: std.mem.Allocator, win: t.Window) t.Error!void {
    var buf: [128]u8 = undefined;
    const sel = selector(&buf, win.id) catch return error.CommandFailed;
    try dispatch(allocator, "moveoutofgroup", sel);
}

fn prepare(allocator: std.mem.Allocator, win: t.Window) t.Error!void {
    try float(allocator, win);
    if (win.grouped) try ungroup(allocator, win);
}

/// `movewindowpixel exact x y` with no float/ungroup preparation.
pub fn moveExact(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    var buf: [160]u8 = undefined;
    const args = pixelArgs(&buf, x, y, win.id) catch return error.CommandFailed;
    try dispatch(allocator, "movewindowpixel", args);
}

/// `resizewindowpixel exact w h` with no float/ungroup preparation.
pub fn resizeExact(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    var buf: [160]u8 = undefined;
    const args = pixelArgs(&buf, w, h, win.id) catch return error.CommandFailed;
    try dispatch(allocator, "resizewindowpixel", args);
}

pub fn move(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    try prepare(allocator, win);
    try moveExact(allocator, win, x, y);
}

pub fn resize(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    try prepare(allocator, win);
    try resizeExact(allocator, win, w, h);
}

const fixture =
    \\[{"address":"0x5581a0c3b2f0","mapped":true,"hidden":false,"at":[1930,90],"size":[1900,980],
    \\"workspace":{"id":2,"name":"2"},"floating":false,"monitor":1,"class":"raven","title":"Seridian Studio",
    \\"pid":4242,"xwayland":false,"pinned":false,"grouped":[],"tags":[]},
    \\{"address":"0x5581a0c3c100","at":[10,20],"size":[800,600],"floating":true,"class":"foot","title":"~ : zsh",
    \\"grouped":["0x5581a0c3c100","0x5581a0c3c200"]}]
;

test "hyprland clients fixture parses" {
    var skipped: usize = 0;
    const wins = try parseClients(std.testing.allocator, fixture, &skipped);
    defer t.freeWindows(std.testing.allocator, wins);
    try std.testing.expectEqual(@as(usize, 0), skipped);
    try std.testing.expectEqual(@as(usize, 2), wins.len);
    try std.testing.expectEqualStrings("0x5581a0c3b2f0", wins[0].id);
    try std.testing.expectEqualStrings("Seridian Studio", wins[0].title);
    try std.testing.expectEqualStrings("raven", wins[0].class);
    try std.testing.expectEqual(@as(i32, 1930), wins[0].x);
    try std.testing.expectEqual(@as(i32, 980), wins[0].h);
    try std.testing.expect(!wins[0].floating);
    try std.testing.expect(!wins[0].grouped);
    try std.testing.expect(wins[1].floating);
    try std.testing.expect(wins[1].grouped);
    try std.testing.expectEqual(@as(?i64, 4242), wins[0].pid);
    try std.testing.expectEqual(@as(?i64, null), wins[1].pid);
}

test "hyprland rejects malformed json" {
    var skipped: usize = 0;
    try std.testing.expectError(error.CommandFailed, parseClients(std.testing.allocator, "not json", &skipped));
    try std.testing.expectError(error.CommandFailed, parseClients(std.testing.allocator, "{}", &skipped));
}

test "hyprland parser skips and counts clients with missing or malformed fields" {
    const good =
        \\{"address":"0x1","at":[1,2],"size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
    ;
    const cases = [_]struct { name: []const u8, bad: []const u8 }{
        .{ .name = "no address", .bad =
        \\{"at":[1,2],"size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "empty address", .bad =
        \\{"address":"","at":[1,2],"size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "no at", .bad =
        \\{"address":"0x2","size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "no size", .bad =
        \\{"address":"0x2","at":[1,2],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "zero size", .bad =
        \\{"address":"0x2","at":[1,2],"size":[0,0],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "at has a string", .bad =
        \\{"address":"0x2","at":["1",2],"size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "at too long", .bad =
        \\{"address":"0x2","at":[1,2,3],"size":[3,4],"floating":false,"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "no class", .bad =
        \\{"address":"0x2","at":[1,2],"size":[3,4],"floating":false,"title":"t","grouped":[]}
        },
        .{ .name = "class not a string", .bad =
        \\{"address":"0x2","at":[1,2],"size":[3,4],"floating":false,"class":5,"title":"t","grouped":[]}
        },
        .{ .name = "no title", .bad =
        \\{"address":"0x2","at":[1,2],"size":[3,4],"floating":false,"class":"a","grouped":[]}
        },
        .{ .name = "no floating", .bad =
        \\{"address":"0x2","at":[1,2],"size":[3,4],"class":"a","title":"t","grouped":[]}
        },
        .{ .name = "no grouped", .bad =
        \\{"address":"0x2","at":[1,2],"size":[3,4],"floating":false,"class":"a","title":"t"}
        },
        .{ .name = "not an object", .bad = "42" },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "[{s},{s}]", .{ good, case.bad });
        defer std.testing.allocator.free(json);
        var skipped: usize = 0;
        const wins = try parseClients(std.testing.allocator, json, &skipped);
        defer t.freeWindows(std.testing.allocator, wins);
        std.testing.expectEqual(@as(usize, 1), wins.len) catch |e| {
            std.debug.print("case: {s}\n", .{case.name});
            return e;
        };
        std.testing.expectEqual(@as(usize, 1), skipped) catch |e| {
            std.debug.print("case: {s}\n", .{case.name});
            return e;
        };
        try std.testing.expectEqualStrings("0x1", wins[0].id);
    }
}

test "hyprland dispatch output must be ok" {
    const cases = [_]struct { out: []const u8, ok: bool }{
        .{ .out = "ok", .ok = true },
        .{ .out = "ok\n", .ok = true },
        .{ .out = "  OK \r\n", .ok = true },
        .{ .out = "Ok", .ok = true },
        .{ .out = "", .ok = false },
        .{ .out = "\n", .ok = false },
        .{ .out = "Window not found", .ok = false },
        .{ .out = "invalid dispatcher", .ok = false },
        .{ .out = "ok but not really", .ok = false },
        .{ .out = "okay", .ok = false },
    };
    for (cases) |case| {
        t.clearDetail();
        if (case.ok) {
            try checkDispatchOutput(case.out);
        } else {
            try std.testing.expectError(error.CommandFailed, checkDispatchOutput(case.out));
            const want = std.mem.trim(u8, case.out, " \t\r\n");
            if (want.len > 0) try std.testing.expectEqualStrings(want, t.detail());
        }
    }
    t.clearDetail();
}

test "hyprland exact pixel args" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("exact 100 -20,address:0xabc", try pixelArgs(&buf, 100, -20, "0xabc"));
}
