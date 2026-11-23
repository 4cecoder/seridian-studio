//! GNOME on Wayland backend. Mutter exposes no window control to clients, so
//! this talks to the Window Calls extension (org.gnome.Shell.Extensions.Windows)
//! over gdbus. If the extension is missing nothing is guessed.

const std = @import("std");
const t = @import("types.zig");

pub const unavailable_reason = "not available: install Window Calls or run an X11 session";

const dest = "org.gnome.Shell";
const path = "/org/gnome/Shell/Extensions/Windows";
const iface = "org.gnome.Shell.Extensions.Windows";

pub fn reason(op: t.Op) ?[]const u8 {
    return switch (op) {
        .float => "GNOME windows are already floating",
        else => null,
    };
}

/// Unwraps a gdbus text reply holding one string, e.g. `('[{"id":1}]',)`.
/// The result is allocated, with GVariant escapes (\' and \\) removed.
pub fn unwrapString(allocator: std.mem.Allocator, reply: []const u8) t.Error![]u8 {
    const text = std.mem.trim(u8, reply, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "(") or !std.mem.endsWith(u8, text, ",)")) return error.CommandFailed;
    const inner = text[1 .. text.len - 2];
    if (inner.len < 2) return error.CommandFailed;
    const quote = inner[0];
    if ((quote != '\'' and quote != '"') or inner[inner.len - 1] != quote) return error.CommandFailed;
    const body = inner[1 .. inner.len - 1];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) {
            i += 1;
            switch (body[i]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                else => try out.append(allocator, body[i]),
            }
        } else try out.append(allocator, body[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |x| x,
        else => null,
    };
}

fn intOf(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

/// Parses one `List` entry. Null when id (positive integer), wm_class
/// (non-empty string), x, y, width or height (positive) is missing or
/// malformed. `title` may be absent on older extension versions (the caller
/// fills it in), but when present it must be a string.
fn parseEntry(allocator: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!?t.Window {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const id = intOf(obj, "id") orelse return null;
    if (id <= 0) return null;
    const class = strOf(obj, "wm_class") orelse return null;
    if (class.len == 0) return null;
    const x = intOf(obj, "x") orelse return null;
    const y = intOf(obj, "y") orelse return null;
    const w = intOf(obj, "width") orelse return null;
    const h = intOf(obj, "height") orelse return null;
    if (!t.validGeometry(w, h)) return null;
    const title: []const u8 = if (obj.get("title")) |tv| switch (tv) {
        .string => |x2| x2,
        else => return null,
    } else "";
    var id_buf: [16]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return null;
    return try t.makeWindow(allocator, .{
        .id = id_text,
        .title = title,
        .class = class,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .floating = true,
    });
}

/// Parses the JSON array returned by Window Calls `List`. Entries with a
/// missing or malformed field are skipped and counted in `skipped`. Titles may
/// be empty on versions that do not include them; the caller fills them in.
pub fn parseList(allocator: std.mem.Allocator, json: []const u8, skipped: *usize) t.Error![]t.Window {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.CommandFailed,
    };

    var wins: std.ArrayList(t.Window) = .empty;
    errdefer {
        for (wins.items) |win| t.freeWindow(allocator, win);
        wins.deinit(allocator);
    }
    for (items) |item| {
        const win = (try parseEntry(allocator, item)) orelse {
            skipped.* += 1;
            continue;
        };
        errdefer t.freeWindow(allocator, win);
        try wins.append(allocator, win);
    }
    return wins.toOwnedSlice(allocator);
}

/// Runs a method on the extension. Unavailable when gdbus cannot be started.
/// The result is not checked; see `call` and `callVoid`.
fn run(allocator: std.mem.Allocator, method: []const u8, args: []const []const u8) t.Error!t.Captured {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const fixed = [_][]const u8{ "gdbus", "call", "--session", "--dest", dest, "--object-path", path, "--method" };
    try argv.appendSlice(allocator, &fixed);
    var method_buf: [96]u8 = undefined;
    const full = std.fmt.bufPrint(&method_buf, "{s}.{s}", .{ iface, method }) catch return error.CommandFailed;
    try argv.append(allocator, full);
    try argv.appendSlice(allocator, args);
    return t.capture(allocator, argv.items);
}

/// Query call. A non-zero exit (no Shell service, UnknownMethod) means the
/// extension is not reachable, which is Unavailable. Caller frees the reply.
fn call(allocator: std.mem.Allocator, method: []const u8, args: []const []const u8) t.Error![]u8 {
    const result = try run(allocator, method, args);
    if (!result.ok()) {
        result.deinit(allocator);
        return error.Unavailable;
    }
    return result.out;
}

pub fn list(allocator: std.mem.Allocator) t.Error![]t.Window {
    const reply = try call(allocator, "List", &.{});
    defer allocator.free(reply);
    const json = try unwrapString(allocator, reply);
    defer allocator.free(json);
    var skipped: usize = 0;
    const parsed = try parseList(allocator, json, &skipped);
    // `parsed` owns every window until it is moved into `wins` (or freed).
    defer allocator.free(parsed);
    var wins: std.ArrayList(t.Window) = .empty;
    errdefer {
        for (wins.items) |win| t.freeWindow(allocator, win);
        wins.deinit(allocator);
    }
    var next: usize = 0;
    errdefer for (parsed[next..]) |win| t.freeWindow(allocator, win);

    while (next < parsed.len) {
        const win = parsed[next];
        next += 1;
        var keep = win;
        if (win.title.len == 0) {
            const title = fetchTitle(allocator, win.id) catch |e| switch (e) {
                error.OutOfMemory => {
                    t.freeWindow(allocator, win);
                    return error.OutOfMemory;
                },
                else => {
                    t.freeWindow(allocator, win);
                    skipped += 1;
                    continue;
                },
            };
            allocator.free(win.title);
            keep.title = title;
        }
        wins.append(allocator, keep) catch {
            t.freeWindow(allocator, keep);
            return error.OutOfMemory;
        };
    }
    t.warnSkipped("gnome_wayland", skipped);
    return wins.toOwnedSlice(allocator);
}

fn fetchTitle(allocator: std.mem.Allocator, id: []const u8) t.Error![]u8 {
    const reply = try call(allocator, "GetTitle", &.{id});
    defer allocator.free(reply);
    const title = try unwrapString(allocator, reply);
    if (title.len == 0) {
        allocator.free(title);
        return error.CommandFailed;
    }
    return title;
}

pub fn float(_: std.mem.Allocator, _: t.Window) t.Error!void {}

/// Mutating call. gdbus exiting non-zero means the Move/Resize itself failed
/// (the extension was already found by `list`), which is CommandFailed.
fn callVoid(allocator: std.mem.Allocator, method: []const u8, args: []const []const u8) t.Error!void {
    const result = try run(allocator, method, args);
    defer result.deinit(allocator);
    try t.requireSuccess(result);
}

pub fn move(allocator: std.mem.Allocator, win: t.Window, x: i32, y: i32) t.Error!void {
    var xb: [16]u8 = undefined;
    var yb: [16]u8 = undefined;
    const xs = std.fmt.bufPrint(&xb, "{d}", .{x}) catch return error.CommandFailed;
    const ys = std.fmt.bufPrint(&yb, "{d}", .{y}) catch return error.CommandFailed;
    try callVoid(allocator, "Move", &.{ win.id, xs, ys });
}

pub fn resize(allocator: std.mem.Allocator, win: t.Window, w: i32, h: i32) t.Error!void {
    var wb: [16]u8 = undefined;
    var hb: [16]u8 = undefined;
    const ws = std.fmt.bufPrint(&wb, "{d}", .{w}) catch return error.CommandFailed;
    const hs = std.fmt.bufPrint(&hb, "{d}", .{h}) catch return error.CommandFailed;
    try callVoid(allocator, "Resize", &.{ win.id, ws, hs });
}

test "gdbus reply unwraps escaped json" {
    const reply = "('[{\"id\":7,\"title\":\"It\\'s fine\"}]',)\n";
    const json = try unwrapString(std.testing.allocator, reply);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[{\"id\":7,\"title\":\"It's fine\"}]", json);
}

test "gdbus reply rejects non-string replies" {
    try std.testing.expectError(error.CommandFailed, unwrapString(std.testing.allocator, "(uint32 5,)"));
    try std.testing.expectError(error.CommandFailed, unwrapString(std.testing.allocator, "oops"));
}

test "window calls list fixture parses" {
    const json =
        \\[{"id":4011,"wm_class":"raven","wm_class_instance":"raven","pid":4242,"focus":true,"title":"Seridian Studio","x":10,"y":20,"width":1900,"height":980},
        \\ {"id":4012,"wm_class":"firefox","pid":9,"focus":false,"x":0,"y":0,"width":5,"height":6}]
    ;
    var skipped: usize = 0;
    const wins = try parseList(std.testing.allocator, json, &skipped);
    defer t.freeWindows(std.testing.allocator, wins);
    try std.testing.expectEqual(@as(usize, 0), skipped);
    try std.testing.expectEqual(@as(usize, 2), wins.len);
    try std.testing.expectEqualStrings("4011", wins[0].id);
    try std.testing.expectEqualStrings("Seridian Studio", wins[0].title);
    try std.testing.expectEqualStrings("raven", wins[0].class);
    try std.testing.expectEqual(@as(i32, 1900), wins[0].w);
    try std.testing.expectEqualStrings("", wins[1].title);
}

test "window calls parser skips and counts entries with missing or malformed fields" {
    const good =
        \\{"id":1,"wm_class":"a","title":"t","x":0,"y":0,"width":5,"height":6}
    ;
    const cases = [_][]const u8{
        \\{"wm_class":"a","x":0,"y":0,"width":5,"height":6}
        ,
        \\{"id":0,"wm_class":"a","x":0,"y":0,"width":5,"height":6}
        ,
        \\{"id":"2","wm_class":"a","x":0,"y":0,"width":5,"height":6}
        ,
        \\{"id":2,"x":0,"y":0,"width":5,"height":6}
        ,
        \\{"id":2,"wm_class":"","x":0,"y":0,"width":5,"height":6}
        ,
        \\{"id":2,"wm_class":"a","y":0,"width":5,"height":6}
        ,
        \\{"id":2,"wm_class":"a","x":0,"width":5,"height":6}
        ,
        \\{"id":2,"wm_class":"a","x":0,"y":0,"height":6}
        ,
        \\{"id":2,"wm_class":"a","x":0,"y":0,"width":5}
        ,
        \\{"id":2,"wm_class":"a","x":0,"y":0,"width":0,"height":0}
        ,
        \\{"id":2,"wm_class":"a","x":"0","y":0,"width":5,"height":6}
        ,
        \\{"id":2,"wm_class":"a","title":7,"x":0,"y":0,"width":5,"height":6}
        ,
        "[]",
    };
    for (cases, 0..) |bad, n| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "[{s},{s}]", .{ good, bad });
        defer std.testing.allocator.free(json);
        var skipped: usize = 0;
        const wins = try parseList(std.testing.allocator, json, &skipped);
        defer t.freeWindows(std.testing.allocator, wins);
        std.testing.expectEqual(@as(usize, 1), wins.len) catch |e| {
            std.debug.print("case {d}\n", .{n});
            return e;
        };
        std.testing.expectEqual(@as(usize, 1), skipped) catch |e| {
            std.debug.print("case {d}\n", .{n});
            return e;
        };
    }
    var skipped: usize = 0;
    try std.testing.expectError(error.CommandFailed, parseList(std.testing.allocator, "{}", &skipped));
}
