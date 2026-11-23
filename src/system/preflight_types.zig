//! C layout of a preflight report plus text/JSON rendering.
//!
//! No engine state, so the `seridian` CLI imports it for `seridian doctor`
//! and the engine library's C API (preflight_c_api.zig) shares the layout.
//!
//! Ported from feat/overhaul 4914565 (src/system/preflight_types.zig); the
//! GTK header that mirrored it (preflight_gtk.h, 72deebd) is not ported.

const std = @import("std");
const preflight = @import("preflight.zig");

pub const max_checks = 32;

pub const status_ok: u32 = 0;
pub const status_info: u32 = 1;
pub const status_warn: u32 = 2;
pub const status_fail: u32 = 3;

pub const CCheck = extern struct {
    /// preflight.CheckId.
    id: u32,
    /// 0 ok, 1 info, 2 warn, 3 fail.
    status: u32,
    /// preflight.FixId; 0 = no automatic fix.
    fix: u32,
    /// Stable machine name ("audio_server").
    key: [32]u8,
    title: [64]u8,
    detail: [256]u8,
    hint: [256]u8,
};

/// The engine settings a check needs, copied on the thread that owns the engine (the UI thread) by
/// `daw_preflight_snapshot`, so the worker running `daw_preflight_run_snapshot` never reads the live engine.
pub const CEngineSnapshot = extern struct {
    /// 0 = no engine: the preflight uses its defaults.
    has_engine: u32,
    sample_rate: u32,
    buffer_size: u32,
    /// Active backend name ("pipewire"), NUL-terminated.
    backend: [16]u8,
};

pub const CReport = extern struct {
    desktop: [32]u8,
    session: [16]u8,
    desktop_version: [32]u8,
    count: u32,
    checks: [max_checks]CCheck,

    pub fn items(self: *const CReport) []const CCheck {
        return self.checks[0..@min(self.count, max_checks)];
    }

    pub fn worst(self: *const CReport) u32 {
        var w: u32 = status_ok;
        for (self.items()) |c| w = @max(w, c.status);
        return w;
    }

    /// Number of checks with exactly `status`.
    pub fn countStatus(self: *const CReport, status: u32) u32 {
        var n: u32 = 0;
        for (self.items()) |c| {
            if (c.status == status) n += 1;
        }
        return n;
    }
};

/// Copy `src` into `dest` NUL-terminated, truncating to fit.
fn copyZ(dest: []u8, src: []const u8) void {
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

/// Convert a report into its C layout.
pub fn fromReport(report: *const preflight.Report, out: *CReport) void {
    out.* = std.mem.zeroes(CReport);
    copyZ(&out.desktop, report.info.desktopName());
    copyZ(&out.session, report.info.session.name());
    copyZ(&out.desktop_version, report.desktop_version.slice());
    for (report.items()) |c| {
        if (out.count == max_checks) break;
        const dst = &out.checks[out.count];
        dst.id = @backingInt(c.id);
        dst.status = @backingInt(c.status);
        dst.fix = @backingInt(c.fix);
        copyZ(&dst.key, @tagName(c.id));
        copyZ(&dst.title, c.title);
        copyZ(&dst.detail, c.detail.slice());
        copyZ(&dst.hint, c.hint.slice());
        out.count += 1;
    }
}

fn z(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// Bracketed label, in the same vocabulary as the rest of `seridian doctor`.
pub fn statusLabel(status: u32) []const u8 {
    return switch (status) {
        status_ok => "PASS",
        status_info => "INFO",
        status_warn => "WARN",
        else => "FAIL",
    };
}

fn statusName(status: u32) []const u8 {
    return switch (status) {
        status_ok => "ok",
        status_info => "info",
        status_warn => "warn",
        else => "fail",
    };
}

/// Human-readable section, as printed by `seridian doctor`. `fix_name` maps
/// a fix id to its `--fix` argument ("" when there is none).
pub fn writeText(w: *std.Io.Writer, r: *const CReport, fix_name: *const fn (u32) []const u8) std.Io.Writer.Error!void {
    try w.print("Realtime audio: {s}", .{z(&r.desktop)});
    if (z(&r.desktop_version).len > 0) try w.print(" {s}", .{z(&r.desktop_version)});
    try w.print(" on {s}\n", .{z(&r.session)});
    for (r.items()) |c| {
        try w.print("  [{s}] {s}: {s}\n", .{ statusLabel(c.status), z(&c.title), z(&c.detail) });
        if (c.status == status_ok) continue;
        if (z(&c.hint).len > 0) try w.print("         hint: {s}\n", .{z(&c.hint)});
        const name = fix_name(c.fix);
        if (name.len > 0) try w.print("         fix:  seridian doctor --fix {s}\n", .{name});
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// Machine-readable report.
pub fn writeJson(w: *std.Io.Writer, r: *const CReport) std.Io.Writer.Error!void {
    try w.writeAll("{\"desktop\":");
    try writeJsonString(w, z(&r.desktop));
    try w.writeAll(",\"desktop_version\":");
    try writeJsonString(w, z(&r.desktop_version));
    try w.writeAll(",\"session\":");
    try writeJsonString(w, z(&r.session));
    try w.print(",\"worst\":\"{s}\",\"checks\":[", .{statusName(r.worst())});
    for (r.items(), 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try writeJsonString(w, z(&c.key));
        try w.print(",\"status\":\"{s}\",\"title\":", .{statusName(c.status)});
        try writeJsonString(w, z(&c.title));
        try w.writeAll(",\"detail\":");
        try writeJsonString(w, z(&c.detail));
        try w.writeAll(",\"hint\":");
        try writeJsonString(w, z(&c.hint));
        try w.print(",\"fix\":{d}}}", .{c.fix});
    }
    try w.writeAll("]}\n");
}

fn testCheck(key: []const u8, status: u32, detail: []const u8, hint: []const u8, fix: u32) CCheck {
    var c = std.mem.zeroes(CCheck);
    c.status = status;
    c.fix = fix;
    @memcpy(c.key[0..key.len], key);
    @memcpy(c.title[0..key.len], key);
    @memcpy(c.detail[0..detail.len], detail);
    @memcpy(c.hint[0..hint.len], hint);
    return c;
}

fn testFixName(fix: u32) []const u8 {
    return if (fix == 2) "desktop-entry" else "";
}

test "text and JSON rendering" {
    var r = std.mem.zeroes(CReport);
    @memcpy(r.desktop[0..8], "Hyprland");
    @memcpy(r.session[0..7], "Wayland");
    r.checks[0] = testCheck("audio_server", status_ok, "PipeWire", "", 0);
    r.checks[1] = testCheck("desktop_entry", status_warn, "No \"seridian-studio.desktop\"", "Docks show\ta generic icon", 2);
    r.count = 2;
    try std.testing.expectEqual(status_warn, r.worst());
    try std.testing.expectEqual(@as(u32, 1), r.countStatus(status_warn));
    try std.testing.expectEqual(@as(u32, 0), r.countStatus(status_fail));

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(&w, &r, testFixName);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "Realtime audio: Hyprland on Wayland\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [PASS] audio_server: PipeWire\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [WARN] desktop_entry: No \"seridian-studio.desktop\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "         hint: Docks show\ta generic icon\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "         fix:  seridian doctor --fix desktop-entry\n") != null);

    var jbuf: [2048]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&jbuf);
    try writeJson(&jw, &r);
    const json = jw.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("warn", parsed.value.object.get("worst").?.string);
    const second = parsed.value.object.get("checks").?.array.items[1].object;
    try std.testing.expectEqualStrings("No \"seridian-studio.desktop\"", second.get("detail").?.string);
    try std.testing.expectEqualStrings("Docks show\ta generic icon", second.get("hint").?.string);
}

test "status labels match the doctor vocabulary" {
    try std.testing.expectEqualStrings("PASS", statusLabel(status_ok));
    try std.testing.expectEqualStrings("INFO", statusLabel(status_info));
    try std.testing.expectEqualStrings("WARN", statusLabel(status_warn));
    try std.testing.expectEqualStrings("FAIL", statusLabel(status_fail));
}

test "fromReport copies checks with terminators" {
    var r: preflight.Report = .{ .info = .{ .desktop = .hyprland, .session = .wayland } };
    r.desktop_version.set("0.56.2");
    var c: preflight.Check = .{ .id = .realtime, .status = .warn, .title = "Realtime scheduling", .fix = .pipewire_clock };
    c.detail.set("detail");
    r.add(c);
    var out: CReport = undefined;
    fromReport(&r, &out);
    try std.testing.expectEqual(@as(u32, 1), out.count);
    try std.testing.expectEqualStrings("Hyprland", std.mem.sliceTo(&out.desktop, 0));
    try std.testing.expectEqualStrings("Wayland", std.mem.sliceTo(&out.session, 0));
    try std.testing.expectEqualStrings("0.56.2", std.mem.sliceTo(&out.desktop_version, 0));
    try std.testing.expectEqualStrings("realtime", std.mem.sliceTo(&out.checks[0].key, 0));
    try std.testing.expectEqualStrings("detail", std.mem.sliceTo(&out.checks[0].detail, 0));
    try std.testing.expectEqual(@as(u32, 2), out.checks[0].status);
    try std.testing.expectEqual(@as(u32, 3), out.checks[0].fix);

    var long: [100]u8 = @splat('x');
    var tiny: [4]u8 = undefined;
    copyZ(&tiny, &long);
    try std.testing.expectEqualStrings("xxx", std.mem.sliceTo(&tiny, 0));
}
