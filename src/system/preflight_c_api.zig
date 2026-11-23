//! C ABI for the system preflight, exported from libdaw-engine so the Raven
//! UI can show the report with the running engine's rate, buffer and
//! backend. Layouts are in preflight_types.zig.
//!
//! `daw_preflight_run` spawns short-lived tools and reads /proc; it takes
//! tens of milliseconds and must not run on the audio thread or block a frame.
//!
//! Ported from feat/overhaul 4914565 (src/system/preflight_c_api.zig).

const std = @import("std");
const preflight = @import("preflight.zig");
const types = @import("preflight_types.zig");
const desktop = @import("desktop.zig");
const audio = @import("../audio/engine.zig");
const sys = @import("../utils/sys.zig");

const log = std.log.scoped(.preflight);

pub const CReport = types.CReport;
pub const CCheck = types.CCheck;
pub const CEngineSnapshot = types.CEngineSnapshot;

fn optionsFor(engine: ?*anyopaque, exe_buf: []u8) preflight.Options {
    var opts = baseOptions(exe_buf);
    const eng: *audio.AudioEngine = @ptrCast(@alignCast(engine orelse return opts));
    opts.sample_rate = eng.config.sample_rate;
    opts.buffer_size = eng.config.buffer_size;
    opts.active_backend = @tagName(eng.backend);
    return opts;
}

fn baseOptions(exe_buf: []u8) preflight.Options {
    var opts: preflight.Options = .{};
    // Inside the app the running executable is seridian-studio itself.
    if (std.process.executablePath(sys.io(), exe_buf)) |len| {
        opts.studio_exe = exe_buf[0..len];
    } else |err| {
        log.info("executable path unavailable: {s}", .{@errorName(err)});
    }
    return opts;
}

/// Options from a snapshot. The returned backend slice borrows `snap`, which must outlive the run.
fn optionsFromSnapshot(snap: ?*const CEngineSnapshot, exe_buf: []u8) preflight.Options {
    var opts = baseOptions(exe_buf);
    const s = snap orelse return opts;
    if (s.has_engine == 0) return opts;
    opts.sample_rate = s.sample_rate;
    opts.buffer_size = s.buffer_size;
    opts.active_backend = std.mem.sliceTo(&s.backend, 0);
    return opts;
}

/// Copy the engine settings the preflight needs. Call on the thread that owns the engine (the UI thread);
/// a null engine gives `has_engine = 0`.
export fn daw_preflight_snapshot(engine: ?*anyopaque, out: *CEngineSnapshot) callconv(.c) void {
    out.* = std.mem.zeroes(CEngineSnapshot);
    const eng: *audio.AudioEngine = @ptrCast(@alignCast(engine orelse return));
    out.has_engine = 1;
    out.sample_rate = eng.config.sample_rate;
    out.buffer_size = eng.config.buffer_size;
    const name = @tagName(eng.backend);
    const n = @min(name.len, out.backend.len - 1);
    @memcpy(out.backend[0..n], name[0..n]);
}

/// Run every check with settings from `daw_preflight_snapshot` (null = defaults). Safe on any thread: it
/// never touches the engine. `snap` is borrowed for the call.
export fn daw_preflight_run_snapshot(out: *CReport, snap: ?*const CEngineSnapshot) callconv(.c) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const report = preflight.run(arena.allocator(), desktop.ProcessEnv{}, optionsFromSnapshot(snap, &exe_buf));
    types.fromReport(&report, out);
}

/// Run every check. `engine` (optional) supplies the sample rate, buffer
/// size and active backend; null uses the defaults.
export fn daw_preflight_run(out: *CReport, engine: ?*anyopaque) callconv(.c) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const report = preflight.run(arena.allocator(), desktop.ProcessEnv{}, optionsFor(engine, &exe_buf));
    types.fromReport(&report, out);
}

/// Apply an automatic fix. Returns 0 on success; `msg` (NUL-terminated,
/// truncated to `msg_len`) describes the change or the failure.
export fn daw_preflight_apply_fix(fix: u32, engine: ?*anyopaque, msg: [*]u8, msg_len: usize) callconv(.c) c_int {
    var text: preflight.FixMessage = .{};
    const result: c_int = blk: {
        const id = std.enums.fromInt(preflight.FixId, fix) orelse {
            text.print("Unknown fix {d}", .{fix});
            break :blk -1;
        };
        if (id == .none) {
            text.set("No fix selected");
            break :blk -1;
        }
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        preflight.applyFix(arena.allocator(), desktop.ProcessEnv{}, id, optionsFor(engine, &exe_buf), &text) catch |err| {
            text.print("{s} failed: {s}", .{ id.describe(), @errorName(err) });
            log.warn("{s}", .{text.slice()});
            break :blk -1;
        };
        log.info("{s}", .{text.slice()});
        break :blk 0;
    };
    if (msg_len > 0) {
        const n = @min(text.len, msg_len - 1);
        @memcpy(msg[0..n], text.slice()[0..n]);
        msg[n] = 0;
    }
    return result;
}

/// Human label for a fix id ("" for none or an unknown id).
export fn daw_preflight_fix_label(fix: u32) callconv(.c) [*:0]const u8 {
    const id = std.enums.fromInt(preflight.FixId, fix) orelse return "";
    return switch (id) {
        inline else => |tag| comptime describeZ(tag),
    };
}

fn describeZ(comptime id: preflight.FixId) [:0]const u8 {
    return id.describe() ++ "";
}

test "fix labels and unknown fixes" {
    try std.testing.expectEqualStrings("Allow lower PipeWire latency", std.mem.span(daw_preflight_fix_label(3)));
    try std.testing.expectEqualStrings("", std.mem.span(daw_preflight_fix_label(0)));
    try std.testing.expectEqualStrings("", std.mem.span(daw_preflight_fix_label(4)));
    try std.testing.expectEqualStrings("", std.mem.span(daw_preflight_fix_label(99)));

    var msg: [64]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), daw_preflight_apply_fix(99, null, &msg, msg.len));
    try std.testing.expectEqualStrings("Unknown fix 99", std.mem.sliceTo(&msg, 0));
    try std.testing.expectEqual(@as(c_int, -1), daw_preflight_apply_fix(0, null, &msg, msg.len));
    try std.testing.expectEqualStrings("No fix selected", std.mem.sliceTo(&msg, 0));
}

test "daw_preflight_run fills a report without an engine" {
    const report = try std.testing.allocator.create(CReport);
    defer std.testing.allocator.destroy(report);
    daw_preflight_run(report, null);
    try std.testing.expect(report.count > 0);
    try std.testing.expectEqualStrings("desktop_session", std.mem.sliceTo(&report.checks[0].key, 0));
}

test "snapshot without an engine uses defaults" {
    var snap: CEngineSnapshot = undefined;
    daw_preflight_snapshot(null, &snap);
    try std.testing.expectEqual(@as(u32, 0), snap.has_engine);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opts = optionsFromSnapshot(&snap, &exe_buf);
    try std.testing.expect(opts.active_backend == null);
}

test "snapshot settings reach the preflight options" {
    var snap = std.mem.zeroes(CEngineSnapshot);
    snap.has_engine = 1;
    snap.sample_rate = 96000;
    snap.buffer_size = 64;
    @memcpy(snap.backend[0..8], "pipewire");
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opts = optionsFromSnapshot(&snap, &exe_buf);
    try std.testing.expectEqual(@as(u32, 96000), opts.sample_rate);
    try std.testing.expectEqual(@as(u32, 64), opts.buffer_size);
    try std.testing.expectEqualStrings("pipewire", opts.active_backend.?);
}

test "daw_preflight_run_snapshot fills a report" {
    const report = try std.testing.allocator.create(CReport);
    defer std.testing.allocator.destroy(report);
    daw_preflight_run_snapshot(report, null);
    try std.testing.expect(report.count > 0);
}
