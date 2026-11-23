//! Persistence of the Piano Roll popout window: whether it was open, and its position and size.
//!
//! File: `$XDG_CONFIG_HOME/seridian/daw/popouts.conf`, plain `key = value` lines. A missing or invalid
//! file means "no popout": loading never fails because of file contents.
//!
//! Versions: files without a `version` key (version 0) hold absolute screen coordinates only. Version 2
//! files also hold `piano_roll_monitor` (a monitor name from `seridian wm monitors`) with `piano_roll_dx`
//! and `piano_roll_dy`, the offset from that monitor's origin; the absolute x and y are still written as
//! the fallback for when no monitor is known. Every save writes the current version, so an old file is
//! converted on the next save.
//!
//! The Mixer popout uses the same format in `mixerpopout.conf`, with the keys prefixed `mixer_` instead of
//! `piano_roll_` (`Window.mixer`).

const std = @import("std");
const sys = @import("../utils/sys.zig");
const xdg = @import("xdg.zig");
const monitors = @import("monitors.zig");

const log = std.log.scoped(.popout_settings);

/// Upper bound on the size of a settings file we are willing to read.
const max_file_bytes: usize = 4 * 1024;
const min_extent: i32 = 100;
const max_extent: i32 = 16384;
const max_coordinate: i32 = 65536;

/// Version written by `saveTo`.
pub const current_version: u8 = 2;

/// The popout windows that persist their state. Each has its own file and key prefix, and the same format.
pub const Window = enum {
    piano_roll,
    mixer,

    /// Prefix of every key in the window's file.
    fn prefix(comptime self: Window) []const u8 {
        return switch (self) {
            .piano_roll => "piano_roll_",
            .mixer => "mixer_",
        };
    }

    fn fileName(self: Window) []const u8 {
        return switch (self) {
            .piano_roll => "popouts.conf",
            .mixer => "mixerpopout.conf",
        };
    }

    fn title(self: Window) []const u8 {
        return switch (self) {
            .piano_roll => "Piano Roll",
            .mixer => "Mixer",
        };
    }
};

pub const PopoutSettings = struct {
    /// True when the popout was open when the settings were written.
    open: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 900,
    height: i32 = 600,
    /// Monitor the popout was on (`monitors.max_name` bytes at most); empty when unknown.
    monitor_buf: [monitors.max_name]u8 = undefined,
    monitor_len: usize = 0,
    /// Offset from the monitor's origin; meaningful only when `monitor_len > 0`.
    dx: i32 = 0,
    dy: i32 = 0,

    pub fn monitor(self: *const PopoutSettings) []const u8 {
        return self.monitor_buf[0..self.monitor_len];
    }

    /// Stores the monitor name; false (and no monitor) when the name is not storable.
    pub fn setMonitor(self: *PopoutSettings, name: []const u8) bool {
        if (!monitors.isValidName(name)) {
            self.monitor_len = 0;
            return false;
        }
        @memcpy(self.monitor_buf[0..name.len], name);
        self.monitor_len = name.len;
        return true;
    }

    /// True when the geometry is something a window can be created with.
    pub fn isValid(self: PopoutSettings) bool {
        return self.width >= min_extent and self.width <= max_extent and
            self.height >= min_extent and self.height <= max_extent and
            self.x >= -max_coordinate and self.x <= max_coordinate and
            self.y >= -max_coordinate and self.y <= max_coordinate and
            (self.monitor_len == 0 or (self.dx >= -max_coordinate and self.dx <= max_coordinate and
                self.dy >= -max_coordinate and self.dy <= max_coordinate));
    }
};

/// Where and how large to place the popout through `seridian wm place`.
pub const Plan = struct {
    monitor_buf: [monitors.max_name]u8 = undefined,
    monitor_len: usize = 0,
    dx: i32,
    dy: i32,
    width: i32,
    height: i32,
    /// True when the saved monitor was found; false when the main window's monitor was used instead.
    saved_monitor: bool,

    pub fn monitor(self: *const Plan) []const u8 {
        return self.monitor_buf[0..self.monitor_len];
    }
};

/// Decides the placement from the current monitor list. The saved monitor is used when it is in the list
/// (offset from its origin); otherwise the monitor containing (`main_cx`, `main_cy`), the centre of the main
/// window, with the saved offset (or the saved absolute position for a file without a monitor). The result
/// goes through `restoreGeometry`, so the size minimum and the clamp still apply. Null when no monitor is
/// usable. Pure.
pub fn plan(list: *const monitors.NamedList, saved: *const PopoutSettings, main_cx: i32, main_cy: i32) ?Plan {
    var saved_monitor = false;
    var target: monitors.NamedMonitor = undefined;
    if (saved.monitor_len > 0 and list.find(saved.monitor()) != null) {
        target = list.find(saved.monitor()).?;
        saved_monitor = true;
    } else {
        target = list.containing(main_cx, main_cy) orelse return null;
    }
    const abs_x: i32 = if (saved.monitor_len > 0) target.rect.x +| saved.dx else saved.x;
    const abs_y: i32 = if (saved.monitor_len > 0) target.rect.y +| saved.dy else saved.y;
    const r = restoreGeometry(.{ .x = abs_x, .y = abs_y, .width = saved.width, .height = saved.height }, target.rect);
    var out: Plan = .{
        .dx = r.rect.x - target.rect.x,
        .dy = r.rect.y - target.rect.y,
        .width = r.rect.width,
        .height = r.rect.height,
        .saved_monitor = saved_monitor,
    };
    @memcpy(out.monitor_buf[0..target.name_len], target.name());
    out.monitor_len = target.name_len;
    return out;
}

/// The monitor a window centre lies on, as the active window-manager backend names it.
pub const Located = struct {
    monitor_buf: [monitors.max_name]u8 = undefined,
    monitor_len: usize = 0,
    /// Origin of the monitor in the backend's coordinates.
    origin_x: i32,
    origin_y: i32,

    pub fn monitor(self: *const Located) []const u8 {
        return self.monitor_buf[0..self.monitor_len];
    }
};

/// The monitor of `list` containing the point; null when none does. Pure.
pub fn locateIn(list: *const monitors.NamedList, px: i32, py: i32) ?Located {
    const hit = list.containing(px, py) orelse return null;
    var out: Located = .{ .origin_x = hit.rect.x, .origin_y = hit.rect.y };
    @memcpy(out.monitor_buf[0..hit.name_len], hit.name());
    out.monitor_len = hit.name_len;
    return out;
}

/// Names the monitor under the point with `seridian wm monitors` (Hyprland, Sway or X11, whichever the wm
/// layer detects), so the name and the origin come from the same backend that `seridian wm place` uses.
/// Null when the helper is missing or fails or no monitor contains the point: the caller then saves nothing
/// monitor-relative. xrandr is never consulted here, its names (`HDMI-1`) differ from Hyprland's (`HDMI-A-1`).
pub fn locateFromBackend(allocator: std.mem.Allocator, px: i32, py: i32) ?Located {
    const cli: []const u8 = sys.getenv("SERIDIAN_CLI") orelse "seridian";
    const output = sys.runCapture(allocator, &.{ cli, "wm", "monitors" }) catch |err| {
        log.warn("seridian wm monitors failed, saving no monitor: {}", .{err});
        return null;
    };
    defer allocator.free(output);
    const list = monitors.parseWmMonitors(output);
    return locateIn(&list, px, py);
}

/// A rectangle in screen coordinates.
pub const Rect = monitors.Rect;

/// Smallest popout size restored from settings; a smaller saved size falls back to the default size.
pub const min_restore_width: i32 = 480;
pub const min_restore_height: i32 = 320;
pub const default_width: i32 = 900;
pub const default_height: i32 = 600;
/// Height reserved for the window manager's title bar.
pub const title_bar_height: i32 = 40;

/// Result of `restoreGeometry`.
pub const Restored = struct {
    rect: Rect,
    /// False when no monitor is known: the size is usable but the window must not be moved.
    place: bool,
};

/// Geometry to restore a popout with. A saved size below the minimum is replaced by the default size.
/// With a monitor, the client rectangle is then clamped so that it plus `title_bar_height` stays inside
/// the monitor (`y` is the top of the decorated window; the monitor wins when it is smaller than the
/// window). Without a monitor the position is kept as saved and `place` is false. Pure.
pub fn restoreGeometry(saved: Rect, monitor: ?Rect) Restored {
    var width = saved.width;
    var height = saved.height;
    if (width < min_restore_width or height < min_restore_height) {
        width = default_width;
        height = default_height;
    }
    const mon = monitor orelse return .{ .rect = .{ .x = saved.x, .y = saved.y, .width = width, .height = height }, .place = false };
    if (mon.width <= 0 or mon.height <= 0) {
        return .{ .rect = .{ .x = saved.x, .y = saved.y, .width = width, .height = height }, .place = false };
    }
    width = @min(width, mon.width);
    height = @max(@min(height, mon.height - title_bar_height), 1);
    const x = std.math.clamp(saved.x, mon.x, @max(mon.x, mon.x + mon.width - width));
    const y = std.math.clamp(saved.y, mon.y, @max(mon.y, mon.y + mon.height - height - title_bar_height));
    return .{ .rect = .{ .x = x, .y = y, .width = width, .height = height }, .place = true };
}

/// Path of the settings file: `$XDG_CONFIG_HOME/seridian/daw/popouts.conf`, falling back to
/// `~/.config/seridian/daw/popouts.conf` (caller frees).
pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    return defaultPathFor(allocator, .piano_roll);
}

/// Path of the settings file of `window` (`popouts.conf`, or `mixerpopout.conf` for the Mixer); caller frees.
pub fn defaultPathFor(allocator: std.mem.Allocator, window: Window) ![]u8 {
    const config_dir = try xdg.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "seridian", "daw", window.fileName() });
}

/// Write `s` to `path`, creating parent directories. The file is written to a temporary sibling
/// and renamed over `path`, so a reader never sees a partial file.
pub fn saveTo(allocator: std.mem.Allocator, path: []const u8, s: PopoutSettings) !void {
    return saveToFor(allocator, .piano_roll, path, s);
}

/// `saveTo` for the settings of `window`.
pub fn saveToFor(allocator: std.mem.Allocator, comptime window: Window, path: []const u8, s: PopoutSettings) !void {
    const p = comptime window.prefix();
    const base = try std.fmt.allocPrint(
        allocator,
        "# Seridian " ++ comptime window.title() ++ " popout, written when the popout is moved, resized, closed or the app quits.\n" ++
            "version = {d}\n" ++ p ++ "open = {d}\n" ++ p ++ "x = {d}\n" ++ p ++ "y = {d}\n" ++ p ++ "width = {d}\n" ++ p ++ "height = {d}\n",
        .{ current_version, @intFromBool(s.open), s.x, s.y, s.width, s.height },
    );
    defer allocator.free(base);
    const monitor_lines = if (s.monitor_len > 0)
        try std.fmt.allocPrint(allocator, p ++ "monitor = {s}\n" ++ p ++ "dx = {d}\n" ++ p ++ "dy = {d}\n", .{ s.monitor(), s.dx, s.dy })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(monitor_lines);
    const content = try std.mem.concat(allocator, u8, &.{ base, monitor_lines });
    defer allocator.free(content);

    if (std.fs.path.dirname(path)) |dir| try sys.makePath(dir);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(sys.io(), .{ .sub_path = tmp_path, .data = content });
    std.Io.Dir.rename(cwd, tmp_path, cwd, path, sys.io()) catch |err| {
        cwd.deleteFile(sys.io(), tmp_path) catch |del_err| {
            log.warn("could not remove {s} after a failed save: {}", .{ tmp_path, del_err });
        };
        return err;
    };
}

const ParseError = error{CorruptSettings};

/// Parses the whole file. Any malformed line, missing key or out-of-range geometry makes it corrupt.
fn parseContent(comptime window: Window, content: []const u8) ParseError!PopoutSettings {
    const p = comptime window.prefix();
    var result: PopoutSettings = .{};
    var seen: u5 = 0;
    var monitor_name: []const u8 = "";
    var have_dx = false;
    var have_dy = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.CorruptSettings;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, p ++ "open")) {
            const flag = std.fmt.parseInt(u8, value, 10) catch return error.CorruptSettings;
            if (flag > 1) return error.CorruptSettings;
            result.open = flag == 1;
            seen |= 1;
        } else if (std.mem.eql(u8, key, p ++ "x")) {
            result.x = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            seen |= 2;
        } else if (std.mem.eql(u8, key, p ++ "y")) {
            result.y = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            seen |= 4;
        } else if (std.mem.eql(u8, key, p ++ "width")) {
            result.width = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            seen |= 8;
        } else if (std.mem.eql(u8, key, p ++ "height")) {
            result.height = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            seen |= 16;
        } else if (std.mem.eql(u8, key, "version")) {
            // Version 0 (no key) is absolute only; any version this build knows or a newer one reads the same keys.
            _ = std.fmt.parseInt(u8, value, 10) catch return error.CorruptSettings;
        } else if (std.mem.eql(u8, key, p ++ "monitor")) {
            monitor_name = value;
        } else if (std.mem.eql(u8, key, p ++ "dx")) {
            result.dx = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            have_dx = true;
        } else if (std.mem.eql(u8, key, p ++ "dy")) {
            result.dy = std.fmt.parseInt(i32, value, 10) catch return error.CorruptSettings;
            have_dy = true;
        }
        // Unknown keys are ignored so that newer files still load.
    }

    // A monitor without both offsets, or with an unusable name, is dropped: the absolute position is used.
    if (have_dx and have_dy) _ = result.setMonitor(monitor_name);
    if (seen != 31 or !result.isValid()) return error.CorruptSettings;
    return result;
}

/// Read settings from `path`. A missing, unreadable or corrupt file gives the defaults (`open = false`).
pub fn loadFrom(allocator: std.mem.Allocator, path: []const u8) !PopoutSettings {
    return loadFromFor(allocator, .piano_roll, path);
}

/// `loadFrom` for the settings of `window`.
pub fn loadFromFor(allocator: std.mem.Allocator, comptime window: Window, path: []const u8) !PopoutSettings {
    const content = sys.readFileAlloc(allocator, path, max_file_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err != error.FileNotFound) log.warn("cannot read {s}, no popout: {}", .{ path, err });
        return .{};
    };
    defer allocator.free(content);

    return parseContent(window, content) catch |err| switch (err) {
        error.CorruptSettings => {
            log.warn("ignoring corrupt popout settings in {s}", .{path});
            return .{};
        },
    };
}

const test_dir = "/tmp/seridian-popout-settings-test";

fn testPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    try sys.makePath(test_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{d}.conf", .{ test_dir, name, sys.nanoTimestamp() });
}

fn removeIfPresent(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(sys.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "popout settings round-trip through a file" {
    const a = std.testing.allocator;
    const path = try testPath(a, "roundtrip");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const want: PopoutSettings = .{ .open = true, .x = -40, .y = 120, .width = 1000, .height = 700 };
    try saveTo(a, path, want);
    const got = try loadFrom(a, path);
    try std.testing.expect(got.open);
    try std.testing.expectEqual(@as(i32, -40), got.x);
    try std.testing.expectEqual(@as(i32, 700), got.height);
    try std.testing.expectEqual(@as(usize, 0), got.monitor_len);
}

test "popout settings: monitor and offsets round-trip, and the file carries a version" {
    const a = std.testing.allocator;
    const path = try testPath(a, "monitor");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    var want: PopoutSettings = .{ .open = true, .x = -1820, .y = 80, .width = 1000, .height = 700, .dx = 100, .dy = 80 };
    try std.testing.expect(want.setMonitor("HDMI-1"));
    try saveTo(a, path, want);
    const text = try sys.readFileAlloc(a, path, max_file_bytes);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "version = 2\n") != null);
    const got = try loadFrom(a, path);
    try std.testing.expectEqualStrings("HDMI-1", got.monitor());
    try std.testing.expectEqual(@as(i32, 100), got.dx);
    try std.testing.expectEqual(@as(i32, 80), got.dy);
}

test "popout settings: a version-less file loads as absolute and is converted by the next save" {
    const a = std.testing.allocator;
    const path = try testPath(a, "legacy");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    try sys.writeFileAtomic(path, "piano_roll_open = 1\npiano_roll_x = 30\npiano_roll_y = 40\npiano_roll_width = 900\npiano_roll_height = 600\n");
    const got = try loadFrom(a, path);
    try std.testing.expect(got.open);
    try std.testing.expectEqual(@as(usize, 0), got.monitor_len);
    try saveTo(a, path, got);
    const text = try sys.readFileAlloc(a, path, max_file_bytes);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "version = 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "piano_roll_x = 30\n") != null);
}

test "popout settings: a monitor without offsets or with a bad name is dropped" {
    const a = std.testing.allocator;
    const path = try testPath(a, "dropmon");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const head = "version = 2\npiano_roll_open = 1\npiano_roll_x = 1\npiano_roll_y = 2\npiano_roll_width = 900\npiano_roll_height = 600\n";
    try sys.writeFileAtomic(path, head ++ "piano_roll_monitor = DP-1\n");
    try std.testing.expectEqual(@as(usize, 0), (try loadFrom(a, path)).monitor_len);
    try sys.writeFileAtomic(path, head ++ "piano_roll_monitor = a b\npiano_roll_dx = 1\npiano_roll_dy = 2\n");
    const got = try loadFrom(a, path);
    try std.testing.expect(got.open);
    try std.testing.expectEqual(@as(usize, 0), got.monitor_len);
}

test "mixer popout settings: round-trip with monitor, version and mixer_ keys" {
    const a = std.testing.allocator;
    const path = try testPath(a, "mixer");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    var want: PopoutSettings = .{ .open = true, .x = 10, .y = 20, .width = 1200, .height = 420, .dx = 5, .dy = 6 };
    try std.testing.expect(want.setMonitor("DP-1"));
    try saveToFor(a, .mixer, path, want);
    const text = try sys.readFileAlloc(a, path, max_file_bytes);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "version = 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mixer_open = 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mixer_monitor = DP-1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "piano_roll_") == null);
    const got = try loadFromFor(a, .mixer, path);
    try std.testing.expect(got.open);
    try std.testing.expectEqual(@as(i32, 1200), got.width);
    try std.testing.expectEqual(@as(i32, 420), got.height);
    try std.testing.expectEqualStrings("DP-1", got.monitor());
    // A Piano Roll reader does not take a Mixer file, and the other way round.
    try std.testing.expect(!(try loadFrom(a, path)).open);
}

test "mixer popout settings: missing, corrupt and invalid files mean no popout" {
    const a = std.testing.allocator;
    const path = try testPath(a, "mixerbad");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    try removeIfPresent(path);
    try std.testing.expect(!(try loadFromFor(a, .mixer, path)).open);
    const bad = [_][]const u8{
        "\x00\xff\xfe garbage\n",
        "mixer_open = 1\nmixer_x = banana\n",
        "mixer_open = 1\nmixer_x = 0\nmixer_y = 0\nmixer_width = 1\nmixer_height = 420\n",
        "mixer_open = 1\nmixer_x = 0\n",
        "mixer_open = 2\nmixer_x = 0\nmixer_y = 0\nmixer_width = 900\nmixer_height = 420\n",
        "",
    };
    for (bad) |content| {
        try sys.writeFileAtomic(path, content);
        try std.testing.expect(!(try loadFromFor(a, .mixer, path)).open);
    }
}

test "mixer popout settings: defaultPathFor is seridian/daw/mixerpopout.conf" {
    const a = std.testing.allocator;
    const path = try defaultPathFor(a, .mixer);
    defer a.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "seridian/daw/mixerpopout.conf"));
}

const plan_list = "DP-1 0 0 2560 1440\nHDMI-1 -1920 0 1920 1080\n";

test "locateIn: a Hyprland list names the monitor under the window centre, not the xrandr name" {
    // Shape printed by `seridian wm monitors` on Hyprland: DP-3 on the left, HDMI-A-1 to its right.
    const list = monitors.parseWmMonitors("DP-3 0 0 2560 1440\nHDMI-A-1 2560 0 1920 1080\n");
    const on_dp = locateIn(&list, 1000 + 450, 300) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("DP-3", on_dp.monitor());
    try std.testing.expectEqual(@as(i32, 0), on_dp.origin_x);
    const on_hdmi = locateIn(&list, 3000, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HDMI-A-1", on_hdmi.monitor());
    try std.testing.expectEqual(@as(i32, 2560), on_hdmi.origin_x);
    // A point on no monitor, or an empty list (failed query), gives nothing to save.
    try std.testing.expect(locateIn(&list, 99999, 0) == null);
    const empty = monitors.parseWmMonitors("");
    try std.testing.expect(locateIn(&empty, 10, 10) == null);
    // The name is storable as the saved mixer monitor.
    var saved: PopoutSettings = .{};
    try std.testing.expect(saved.setMonitor(on_dp.monitor()));
    try std.testing.expectEqualStrings("DP-3", saved.monitor());
}

test "plan: saved monitor present gives its offset" {
    const list = monitors.parseWmMonitors(plan_list);
    var saved: PopoutSettings = .{ .open = true, .dx = 100, .dy = 80, .width = 900, .height = 600 };
    _ = saved.setMonitor("HDMI-1");
    const p = plan(&list, &saved, 1000, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(p.saved_monitor);
    try std.testing.expectEqualStrings("HDMI-1", p.monitor());
    try std.testing.expectEqual(@as(i32, 100), p.dx);
    try std.testing.expectEqual(@as(i32, 80), p.dy);
}

test "plan: missing monitor falls back to the main window's monitor, clamped" {
    const list = monitors.parseWmMonitors(plan_list);
    var saved: PopoutSettings = .{ .open = true, .dx = 5000, .dy = 5000, .width = 900, .height = 600 };
    _ = saved.setMonitor("DP-9");
    const p = plan(&list, &saved, 1000, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!p.saved_monitor);
    try std.testing.expectEqualStrings("DP-1", p.monitor());
    try std.testing.expectEqual(@as(i32, 2560 - 900), p.dx);
    try std.testing.expectEqual(@as(i32, 1440 - 600 - title_bar_height), p.dy);
}

test "plan: no usable monitor gives null" {
    const list = monitors.parseWmMonitors(plan_list);
    const saved: PopoutSettings = .{ .open = true };
    try std.testing.expect(plan(&list, &saved, 99999, 0) == null);
}

test "popout settings: missing file means no popout" {
    const a = std.testing.allocator;
    const path = try testPath(a, "missing");
    defer a.free(path);
    try removeIfPresent(path);

    const got = try loadFrom(a, path);
    try std.testing.expect(!got.open);
}

test "popout settings: corrupt or invalid files mean no popout" {
    const a = std.testing.allocator;
    const path = try testPath(a, "corrupt");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const bad = [_][]const u8{
        "\x00\xff\xfe garbage\n",
        "piano_roll_open = 1\npiano_roll_x = banana\n",
        "piano_roll_open = 1\npiano_roll_x = 0\npiano_roll_y = 0\npiano_roll_width = 1\npiano_roll_height = 600\n",
        "piano_roll_open = 1\npiano_roll_x = 0\n",
        "",
    };
    for (bad) |content| {
        try sys.writeFileAtomic(path, content);
        const got = try loadFrom(a, path);
        try std.testing.expect(!got.open);
    }
}

test "popout settings: defaultPath is seridian/daw/popouts.conf" {
    const a = std.testing.allocator;
    const path = try defaultPath(a);
    defer a.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "seridian/daw/popouts.conf"));
}

const test_monitor: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

test "restoreGeometry: normal geometry is unchanged" {
    const g: Rect = .{ .x = 100, .y = 80, .width = 900, .height = 600 };
    const r = restoreGeometry(g, test_monitor);
    try std.testing.expectEqual(g, r.rect);
    try std.testing.expect(r.place);
}

test "restoreGeometry: bottom edge leaves room for the title bar" {
    const r = restoreGeometry(.{ .x = 100, .y = 1000, .width = 900, .height = 600 }, test_monitor);
    // 1080 - 600 - 40
    try std.testing.expectEqual(Rect{ .x = 100, .y = 440, .width = 900, .height = 600 }, r.rect);
    try std.testing.expect(r.rect.y + r.rect.height + title_bar_height <= test_monitor.height);
}

test "restoreGeometry: height is limited by the title bar" {
    const r = restoreGeometry(.{ .x = 0, .y = 0, .width = 900, .height = 1080 }, test_monitor);
    try std.testing.expectEqual(@as(i32, 1040), r.rect.height);
    try std.testing.expectEqual(@as(i32, 0), r.rect.y);
}

test "restoreGeometry: right edge" {
    const r = restoreGeometry(.{ .x = 1800, .y = 50, .width = 900, .height = 600 }, test_monitor);
    try std.testing.expectEqual(Rect{ .x = 1020, .y = 50, .width = 900, .height = 600 }, r.rect);
}

test "restoreGeometry: too small falls back to the default size" {
    const r = restoreGeometry(.{ .x = 10, .y = 10, .width = 479, .height = 700 }, test_monitor);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 900, .height = 600 }, r.rect);
    const r2 = restoreGeometry(.{ .x = 10, .y = 10, .width = 900, .height = 319 }, test_monitor);
    try std.testing.expectEqual(@as(i32, 600), r2.rect.height);
    const exact = restoreGeometry(.{ .x = 10, .y = 10, .width = 480, .height = 320 }, test_monitor);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 480, .height = 320 }, exact.rect);
}

test "restoreGeometry: too small is replaced by the default and then clamped to a small monitor" {
    const small: Rect = .{ .x = 0, .y = 0, .width = 800, .height = 500 };
    const r = restoreGeometry(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, small);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 800, .height = 460 }, r.rect);
}

test "restoreGeometry: negative position and monitor not at the origin" {
    const r = restoreGeometry(.{ .x = -700, .y = -20, .width = 900, .height = 600 }, test_monitor);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 900, .height = 600 }, r.rect);
    const mon: Rect = .{ .x = -1920, .y = 0, .width = 1920, .height = 1080 };
    const r2 = restoreGeometry(.{ .x = 100, .y = 700, .width = 900, .height = 600 }, mon);
    try std.testing.expectEqual(Rect{ .x = -900, .y = 440, .width = 900, .height = 600 }, r2.rect);
}

test "restoreGeometry: no monitor keeps the position and does not place" {
    const r = restoreGeometry(.{ .x = 5000, .y = -300, .width = 700, .height = 500 }, null);
    try std.testing.expect(!r.place);
    try std.testing.expectEqual(Rect{ .x = 5000, .y = -300, .width = 700, .height = 500 }, r.rect);
    const r2 = restoreGeometry(.{ .x = 5, .y = 6, .width = 10, .height = 10 }, null);
    try std.testing.expect(!r2.place);
    try std.testing.expectEqual(@as(i32, 900), r2.rect.width);
}
