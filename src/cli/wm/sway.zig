//! Sway backend, driven through `swaymsg`.

const std = @import("std");
const t = @import("types.zig");

pub const unavailable_reason = "not available: swaymsg failed; is Sway running and swaymsg on PATH?";

pub fn reason(_: t.Op) ?[]const u8 {
    return null;
}

fn field(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

/// A string field, or null when missing or not a string.
fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = field(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// An integer field that fits i32, or null when missing or malformed.
fn intField(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const v = field(obj, key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const text = s orelse return null;
    return if (text.len == 0) null else text;
}

fn arrayItems(obj: std.json.ObjectMap, key: []const u8) []const std.json.Value {
    const v = field(obj, key) orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// The window title. Sway reports `"name": null` for a window without a
/// title, which is the one legitimate null; a missing key or other type is
/// malformed.
fn titleField(obj: std.json.ObjectMap) ?[]const u8 {
    const v = field(obj, "name") orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => "",
        else => null,
    };
}

/// Builds a window from a leaf con. Null when any required field is missing or
/// malformed: id must be a positive integer, class (app_id or X11 class) must
/// be non-empty, rect must have integer x/y and positive width/height.
fn parseLeaf(allocator: std.mem.Allocator, obj: std.json.ObjectMap, floating: bool) std.mem.Allocator.Error!?t.Window {
    const id = intField(obj, "id") orelse return null;
    if (id <= 0) return null;
    var class = nonEmpty(stringField(obj, "app_id"));
    if (class == null) {
        if (field(obj, "window_properties")) |wp| switch (wp) {
            .object => |wo| class = nonEmpty(stringField(wo, "class")),
            else => {},
        };
    }
    const cls = class orelse return null;
    const title = titleField(obj) orelse return null;
    const rect = switch (field(obj, "rect") orelse return null) {
        .object => |ro| ro,
        else => return null,
    };
    const x = intField(rect, "x") orelse return null;
    const y = intField(rect, "y") orelse return null;
    const w = intField(rect, "width") orelse return null;
    const h = intField(rect, "height") orelse return null;
    if (!t.validGeometry(w, h)) return null;
    var id_buf: [16]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return null;
    return try t.makeWindow(allocator, .{
        .id = id_text,
        .title = title,
        .class = cls,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .floating = floating,
    });
}

fn walk(allocator: std.mem.Allocator, node: std.json.Value, floating: bool, out: *std.ArrayList(t.Window), skipped: *usize) std.mem.Allocator.Error!void {
    const obj = switch (node) {
        .object => |o| o,
        else => return,
    };
    const children = arrayItems(obj, "nodes");
    const float_children = arrayItems(obj, "floating_nodes");

    const kind = stringField(obj, "type") orelse "";
    const is_floating = floating or std.mem.eql(u8, kind, "floating_con");
    const is_container = std.mem.eql(u8, kind, "con") or std.mem.eql(u8, kind, "floating_con");
    // A window is a con with no children and an app identity (Wayland app_id or X11 class) or a pid.
    if (is_container and children.len == 0 and float_children.len == 0) {
        const has_identity = nonEmpty(stringField(obj, "app_id")) != null or field(obj, "pid") != null or
            (if (field(obj, "window_properties")) |wp| wp == .object else false);
        if (has_identity) {
            if (try parseLeaf(allocator, obj, is_floating)) |win| {
                errdefer t.freeWindow(allocator, win);
                try out.append(allocator, win);
            } else {
                skipped.* += 1;
            }
        }
    }
    for (children) |child| try walk(allocator, child, is_floating, out, skipped);
    for (float_children) |child| try walk(allocator, child, true, out, skipped);
}

/// Parses the subset of `swaymsg -t get_tree` output we need. Windows with a
/// missing or malformed field are skipped and counted in `skipped`. Caller
/// frees with t.freeWindows.
pub fn parseTree(allocator: std.mem.Allocator, json: []const u8, skipped: *usize) t.Error![]t.Window {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.CommandFailed;

    var found: std.ArrayList(t.Window) = .empty;
    errdefer {
        for (found.items) |win| t.freeWindow(allocator, win);
        found.deinit(allocator);
    }
    try walk(allocator, parsed.value, false, &found, skipped);
    return found.toOwnedSlice(allocator);
}

pub fn list(allocator: std.mem.Allocator) t.Error![]t.Window {
    const result = try t.capture(allocator, &.{ "swaymsg", "-t", "get_tree", "-r" });
    defer result.deinit(allocator);
    try t.requireSuccess(result);
    var skipped: usize = 0;
    const wins = try parseTree(allocator, result.out, &skipped);
    t.warnSkipped("sway", skipped);
    return wins;
}

/// Checks the JSON reply of a swaymsg command: a non-empty array in which
/// every element has `"success": true`. Otherwise CommandFailed, with the
/// reported `error` text (or the raw output) as the detail.
pub fn checkCommandOutput(allocator: std.mem.Allocator, output: []const u8) t.Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            t.setDetail(std.mem.trim(u8, output, " \t\r\n"));
            return error.CommandFailed;
        },
    };
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => {
            t.setDetail(std.mem.trim(u8, output, " \t\r\n"));
            return error.CommandFailed;
        },
    };
    if (items.len == 0) {
        t.setDetail("empty swaymsg reply");
        return error.CommandFailed;
    }
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                t.setDetail("malformed swaymsg reply");
                return error.CommandFailed;
            },
        };
        const success = switch (field(obj, "success") orelse .null) {
            .bool => |b| b,
            else => false,
        };
        if (!success) {
            t.setDetail(stringField(obj, "error") orelse "swaymsg reported failure");
            return error.CommandFailed;
        }
    }
}

fn msg(allocator: std.mem.Allocator, win: t.Window, comptime fmt: []const u8, args: anytype) t.Error!void {
    var sel_buf: [64]u8 = undefined;
    const sel = std.fmt.bufPrint(&sel_buf, "[con_id={s}]", .{win.id}) catch return error.CommandFailed;
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt, args) catch return error.CommandFailed;
    const result = try t.capture(allocator, &.{ "swaymsg", sel, cmd });
    defer result.deinit(allocator);
    // swaymsg prints the JSON reply even when it exits non-zero, so check the
    // reply first to report sway's own error text, then the exit status.
    try checkCommandOutput(allocator, result.out);
    try t.requireSuccess(result);
}

pub fn float(allocator: std.mem.Allocator, win: t.Window) t.Error!void {
    if (win.floating) return;
    try msg(allocator, win, "floating enable", .{});
}

pub fn move(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    try float(allocator, win);
    try msg(allocator, win, "move position {d} {d}", .{ x, y });
}

pub fn resize(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    try float(allocator, win);
    try msg(allocator, win, "resize set width {d} px height {d} px", .{ w, h });
}

const fixture =
    \\{"id":1,"type":"root","name":"root","nodes":[
    \\ {"id":2,"type":"output","name":"DP-1","nodes":[
    \\  {"id":3,"type":"workspace","name":"1","nodes":[
    \\   {"id":10,"type":"con","name":"Seridian Studio","app_id":"raven","pid":4242,
    \\    "rect":{"x":0,"y":30,"width":1900,"height":980},"nodes":[],"floating_nodes":[],"window_properties":null},
    \\   {"id":11,"type":"con","name":"Firefox","app_id":null,"pid":99,
    \\    "rect":{"x":5,"y":6,"width":700,"height":500},"nodes":[],"floating_nodes":[],
    \\    "window_properties":{"class":"firefox","instance":"Navigator"}}
    \\  ],"floating_nodes":[
    \\   {"id":12,"type":"floating_con","name":"pavucontrol","app_id":"pavucontrol","pid":7,
    \\    "rect":{"x":100,"y":120,"width":600,"height":400},"nodes":[],"floating_nodes":[]}
    \\  ]}
    \\ ]}
    \\]}
;

test "sway tree fixture parses tiled, xwayland and floating windows" {
    var skipped: usize = 0;
    const wins = try parseTree(std.testing.allocator, fixture, &skipped);
    defer t.freeWindows(std.testing.allocator, wins);
    try std.testing.expectEqual(@as(usize, 0), skipped);
    try std.testing.expectEqual(@as(usize, 3), wins.len);
    try std.testing.expectEqualStrings("10", wins[0].id);
    try std.testing.expectEqualStrings("raven", wins[0].class);
    try std.testing.expectEqualStrings("Seridian Studio", wins[0].title);
    try std.testing.expectEqual(@as(i32, 1900), wins[0].w);
    try std.testing.expect(!wins[0].floating);
    try std.testing.expectEqualStrings("firefox", wins[1].class);
    try std.testing.expectEqualStrings("12", wins[2].id);
    try std.testing.expect(wins[2].floating);
    try std.testing.expectEqual(@as(i32, 100), wins[2].x);
}

test "sway rejects malformed json" {
    var skipped: usize = 0;
    try std.testing.expectError(error.CommandFailed, parseTree(std.testing.allocator, "{", &skipped));
    try std.testing.expectError(error.CommandFailed, parseTree(std.testing.allocator, "[]", &skipped));
}

test "sway parser skips and counts windows with missing or malformed fields" {
    const prefix =
        \\{"id":1,"type":"root","nodes":[
    ;
    const good =
        \\{"id":10,"type":"con","name":"ok","app_id":"raven","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[],"floating_nodes":[]}
    ;
    const cases = [_]struct { name: []const u8, bad: []const u8 }{
        .{ .name = "id zero", .bad =
        \\{"id":0,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "id negative", .bad =
        \\{"id":-4,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "id missing", .bad =
        \\{"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "id a string", .bad =
        \\{"id":"7","type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "id a float", .bad =
        \\{"id":7.5,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "no class", .bad =
        \\{"id":7,"type":"con","name":"n","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "empty app_id and no window_properties", .bad =
        \\{"id":7,"type":"con","name":"n","app_id":"","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "no rect", .bad =
        \\{"id":7,"type":"con","name":"n","app_id":"a","pid":1,"nodes":[]}
        },
        .{ .name = "rect missing height", .bad =
        \\{"id":7,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10},"nodes":[]}
        },
        .{ .name = "rect zero size", .bad =
        \\{"id":7,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":0,"height":0},"nodes":[]}
        },
        .{ .name = "rect x a string", .bad =
        \\{"id":7,"type":"con","name":"n","app_id":"a","pid":1,"rect":{"x":"0","y":0,"width":10,"height":10},"nodes":[]}
        },
        .{ .name = "no name key", .bad =
        \\{"id":7,"type":"con","app_id":"a","pid":1,"rect":{"x":0,"y":0,"width":10,"height":10},"nodes":[]}
        },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{s}{s},{s}]}}", .{ prefix, good, case.bad });
        defer std.testing.allocator.free(json);
        var skipped: usize = 0;
        const wins = try parseTree(std.testing.allocator, json, &skipped);
        defer t.freeWindows(std.testing.allocator, wins);
        std.testing.expectEqual(@as(usize, 1), wins.len) catch |e| {
            std.debug.print("case: {s}\n", .{case.name});
            return e;
        };
        std.testing.expectEqual(@as(usize, 1), skipped) catch |e| {
            std.debug.print("case: {s}\n", .{case.name});
            return e;
        };
        try std.testing.expectEqualStrings("10", wins[0].id);
    }
}

test "sway window without a title (name null) is kept with an empty title" {
    const json =
        \\{"id":1,"type":"root","nodes":[{"id":5,"type":"con","name":null,"app_id":"a","pid":1,"rect":{"x":1,"y":2,"width":3,"height":4},"nodes":[]}]}
    ;
    var skipped: usize = 0;
    const wins = try parseTree(std.testing.allocator, json, &skipped);
    defer t.freeWindows(std.testing.allocator, wins);
    try std.testing.expectEqual(@as(usize, 0), skipped);
    try std.testing.expectEqual(@as(usize, 1), wins.len);
    try std.testing.expectEqualStrings("", wins[0].title);
}

test "sway command output must report success" {
    const cases = [_]struct { out: []const u8, ok: bool, detail: []const u8 = "" }{
        .{ .out = "[{\"success\":true}]", .ok = true },
        .{ .out = "[{\"success\":true},{\"success\":true}]\n", .ok = true },
        .{ .out = "[{\"success\":false,\"parse_error\":true,\"error\":\"Expected 'move'\"}]", .ok = false, .detail = "Expected 'move'" },
        .{ .out = "[{\"success\":true},{\"success\":false,\"error\":\"No matching node.\"}]", .ok = false, .detail = "No matching node." },
        .{ .out = "[{\"success\":false}]", .ok = false, .detail = "swaymsg reported failure" },
        .{ .out = "[{\"success\":\"true\"}]", .ok = false },
        .{ .out = "[{}]", .ok = false },
        .{ .out = "[]", .ok = false, .detail = "empty swaymsg reply" },
        .{ .out = "", .ok = false },
        .{ .out = "Failed to connect", .ok = false, .detail = "Failed to connect" },
        .{ .out = "{\"success\":true}", .ok = false },
    };
    for (cases) |case| {
        t.clearDetail();
        if (case.ok) {
            try checkCommandOutput(std.testing.allocator, case.out);
        } else {
            try std.testing.expectError(error.CommandFailed, checkCommandOutput(std.testing.allocator, case.out));
            if (case.detail.len > 0) try std.testing.expectEqualStrings(case.detail, t.detail());
        }
    }
    t.clearDetail();
}
