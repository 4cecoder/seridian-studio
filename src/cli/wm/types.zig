//! Shared types and helpers for the window-manager backends.
//!
//! Every backend module exposes the same small interface:
//!   pub fn list(allocator) Error![]Window
//!   pub fn float(allocator, Window) Error!void
//!   pub fn move(allocator, Window, x, y) Error!void
//!   pub fn resize(allocator, Window, w, h) Error!void
//!   pub fn reason(Op) ?[]const u8     // why the op is not supported here
//!   pub const unavailable_reason: []const u8
//! Parsers are pure functions so they can be tested against fixtures.

const std = @import("std");
const sys = @import("../../utils/sys.zig");

pub const Op = enum { list, float, move, resize };

pub const Error = error{
    /// The backend's tooling or extension is missing. See `unavailable_reason`.
    Unavailable,
    /// A tool ran but exited non-zero, reported failure, or printed something unparseable.
    CommandFailed,
    /// The query ran fine but nothing matched (e.g. xdotool search with no hits).
    NotFound,
    /// The backend has no way to do this (for example KWin and GNOME cannot list monitors).
    Unsupported,
    OutOfMemory,
};

pub const Window = struct {
    /// Backend-specific id (hyprland address, sway con_id, X11 id, kwin uuid, gnome id). Never empty.
    id: []const u8,
    title: []const u8,
    class: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    floating: bool = false,
    grouped: bool = false,
    /// Owning process id when the backend reports it (Hyprland only); null otherwise.
    pid: ?i64 = null,
};

pub fn freeWindow(allocator: std.mem.Allocator, win: Window) void {
    allocator.free(win.id);
    allocator.free(win.title);
    allocator.free(win.class);
}

pub fn freeWindows(allocator: std.mem.Allocator, wins: []Window) void {
    for (wins) |win| freeWindow(allocator, win);
    allocator.free(wins);
}

/// Builds a Window that owns copies of its strings.
pub fn makeWindow(allocator: std.mem.Allocator, template: Window) std.mem.Allocator.Error!Window {
    const id = try allocator.dupe(u8, template.id);
    errdefer allocator.free(id);
    const title = try allocator.dupe(u8, template.title);
    errdefer allocator.free(title);
    const class = try allocator.dupe(u8, template.class);
    var out = template;
    out.id = id;
    out.title = title;
    out.class = class;
    return out;
}

/// How a captured process ended.
pub const Exit = union(enum) {
    /// Normal exit with this status code.
    code: u8,
    /// Killed by a signal, stopped, or otherwise abnormal.
    abnormal,
};

/// Output and exit status of a finished process. Free with `deinit`.
pub const Captured = struct {
    out: []u8,
    exit: Exit,

    pub fn deinit(self: Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.out);
    }

    /// True when the process exited with status 0.
    pub fn ok(self: Captured) bool {
        return switch (self.exit) {
            .code => |c| c == 0,
            .abnormal => false,
        };
    }

    /// The exit status, or null for an abnormal end.
    pub fn status(self: Captured) ?u8 {
        return switch (self.exit) {
            .code => |c| c,
            .abnormal => null,
        };
    }
};

/// Runs argv and captures stdout together with the exit status.
/// Unavailable means the tool could not be started at all (not installed or
/// not executable). A tool that ran and exited non-zero is reported through
/// `Captured.exit`, so callers can tell the two apart.
pub fn capture(allocator: std.mem.Allocator, argv: []const []const u8) Error!Captured {
    var child = std.process.spawn(sys.io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unavailable,
    };
    const stdout = child.stdout orelse return error.CommandFailed;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(sys.io(), &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.CommandFailed,
        };
        if (n == 0) break;
        try output.appendSlice(allocator, buffer[0..n]);
    }
    const term = child.wait(sys.io()) catch return error.CommandFailed;
    const exit: Exit = switch (term) {
        .exited => |c| .{ .code = c },
        else => .abnormal,
    };
    return .{ .out = try output.toOwnedSlice(allocator), .exit = exit };
}

/// Maps a finished process to success or CommandFailed (recording the exit
/// status as the detail). The caller keeps ownership of `result`.
pub fn requireSuccess(result: Captured) Error!void {
    if (result.ok()) return;
    var buf: [64]u8 = undefined;
    const text = if (result.status()) |c|
        std.fmt.bufPrint(&buf, "exit status {d}", .{c}) catch "non-zero exit"
    else
        "terminated abnormally";
    setDetail(text);
    return error.CommandFailed;
}

/// Runs argv and requires exit status 0. Output is discarded.
/// Unavailable when the tool cannot be started, CommandFailed on non-zero exit.
pub fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) Error!void {
    const result = try capture(allocator, argv);
    defer result.deinit(allocator);
    try requireSuccess(result);
}

/// Runs argv, requires exit 0 and returns trimmed stdout (caller frees).
/// Empty output is CommandFailed.
pub fn captureTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) Error![]u8 {
    const result = try capture(allocator, argv);
    defer result.deinit(allocator);
    try requireSuccess(result);
    const trimmed = std.mem.trim(u8, result.out, " \t\r\n");
    if (trimmed.len == 0) return error.CommandFailed;
    return allocator.dupe(u8, trimmed);
}

// ---------------------------------------------------------------------------
// Failure detail and diagnostics
// ---------------------------------------------------------------------------

var detail_buf: [512]u8 = undefined;
var detail_len: usize = 0;

/// Records the text behind the most recent CommandFailed (tool output or exit
/// status). The CLI is single-threaded, so one slot is enough.
pub fn setDetail(text: []const u8) void {
    const n = @min(text.len, detail_buf.len);
    @memcpy(detail_buf[0..n], text[0..n]);
    detail_len = n;
}

/// The recorded detail, or an empty string.
pub fn detail() []const u8 {
    return detail_buf[0..detail_len];
}

pub fn clearDetail() void {
    detail_len = 0;
}

/// Prints the counted warning for windows dropped by a strict parser.
pub fn warnSkipped(backend: []const u8, skipped: usize) void {
    if (skipped == 0) return;
    std.debug.print("seridian wm: warning: {s}: skipped {d} window(s) with missing or malformed fields\n", .{ backend, skipped });
}

/// Writes `text` with control characters made visible, so a window title can
/// never inject newlines or terminal escape sequences. Backslash is doubled.
/// C1 controls (U+0080..U+009F) and invalid bytes >= 0x80 that are not part of
/// a well-formed UTF-8 sequence are written as \xNN.
pub fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            0x1b => try w.writeAll("\\e"),
            0...8, 11, 12, 14...0x1a, 0x1c...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
            0x20...0x5b, 0x5d...0x7e => try w.writeByte(c),
            else => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch {
                    try w.print("\\x{x:0>2}", .{c});
                    i += 1;
                    continue;
                };
                if (i + len > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + len])) {
                    try w.print("\\x{x:0>2}", .{c});
                    i += 1;
                    continue;
                }
                if (c == 0xc2 and text[i + 1] < 0xa0) {
                    try w.print("\\x{x:0>2}\\x{x:0>2}", .{ c, text[i + 1] });
                } else {
                    try w.writeAll(text[i .. i + len]);
                }
                i += len;
                continue;
            },
        }
        i += 1;
    }
}

/// Geometry that a window manager could really report.
pub fn validGeometry(w: i32, h: i32) bool {
    return w > 0 and h > 0;
}

/// True when `name` is found on PATH.
pub fn haveTool(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const script = std.fmt.bufPrint(&buf, "command -v {s}", .{name}) catch return false;
    return sys.runSucceeds(&.{ "sh", "-c", script });
}

/// Case-insensitive substring test.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

/// True when `needle` is a case-insensitive substring of the title or class.
pub fn matches(win: Window, needle: []const u8) bool {
    return containsIgnoreCase(win.title, needle) or containsIgnoreCase(win.class, needle);
}

test "matches is case-insensitive over title and class" {
    const win: Window = .{ .id = "1", .title = "Seridian Studio", .class = "raven" };
    try std.testing.expect(matches(win, "seridian"));
    try std.testing.expect(matches(win, "RAV"));
    try std.testing.expect(!matches(win, "firefox"));
}

fn expectEscaped(input: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEscaped(&w, input);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "writeEscaped makes control characters visible" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "plain title", .out = "plain title" },
        .{ .in = "", .out = "" },
        .{ .in = "a\nb", .out = "a\\nb" },
        .{ .in = "a\tb", .out = "a\\tb" },
        .{ .in = "a\rb", .out = "a\\rb" },
        .{ .in = "\x1b[31mred\x1b[0m", .out = "\\e[31mred\\e[0m" },
        .{ .in = "\x00\x01\x07\x08\x0b\x0c\x1f", .out = "\\x00\\x01\\x07\\x08\\x0b\\x0c\\x1f" },
        .{ .in = "del\x7f", .out = "del\\x7f" },
        .{ .in = "back\\slash", .out = "back\\\\slash" },
        .{ .in = "caf\xc3\xa9 \xe2\x9c\x93", .out = "caf\xc3\xa9 \xe2\x9c\x93" },
        .{ .in = "c1\xc2\x9b[2J", .out = "c1\\xc2\\x9b[2J" },
        .{ .in = "bad\xffbyte", .out = "bad\\xffbyte" },
        .{ .in = "trunc\xe2\x9c", .out = "trunc\\xe2\\x9c" },
    };
    for (cases) |case| try expectEscaped(case.in, case.out);
}

test "writeEscaped never emits a raw control byte" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEscaped(&w, &all);
    for (w.buffered()) |c| try std.testing.expect(c >= 0x20 and c != 0x7f);
}

test "requireSuccess maps exit status to CommandFailed with detail" {
    clearDetail();
    var empty: [0]u8 = .{};
    const ok: Captured = .{ .out = &empty, .exit = .{ .code = 0 } };
    try requireSuccess(ok);
    const fail: Captured = .{ .out = &empty, .exit = .{ .code = 3 } };
    try std.testing.expectError(error.CommandFailed, requireSuccess(fail));
    try std.testing.expectEqualStrings("exit status 3", detail());
    const killed: Captured = .{ .out = &empty, .exit = .abnormal };
    try std.testing.expectError(error.CommandFailed, requireSuccess(killed));
    clearDetail();
}

test "capture: missing tool is Unavailable, failing tool is CommandFailed-class, true is ok" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Unavailable, capture(a, &.{"seridian-no-such-tool-xyz"}));
    const bad = try capture(a, &.{ "sh", "-c", "exit 7" });
    defer bad.deinit(a);
    try std.testing.expectEqual(@as(?u8, 7), bad.status());
    try std.testing.expect(!bad.ok());
    const good = try capture(a, &.{ "sh", "-c", "printf hi" });
    defer good.deinit(a);
    try std.testing.expect(good.ok());
    try std.testing.expectEqualStrings("hi", good.out);
    try std.testing.expectError(error.CommandFailed, runChecked(a, &.{ "sh", "-c", "exit 1" }));
    try std.testing.expectError(error.Unavailable, runChecked(a, &.{"seridian-no-such-tool-xyz"}));
    clearDetail();
}
