// Translated to Zig from soundcraft/crates/engine/src/cmd.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Parameter helpers shared by command bodies: JSON field readers with defaults,
//! and resolvers for tracks, clips, positions and ranges. Each resolver takes the
//! `Context` (for session queries and the diagnostic) and the command name (for
//! error messages). Lists returned to the caller are allocated from `ctx.gpa`
//! and owned by the caller.

const std = @import("std");
const command = @import("command.zig");

const Context = command.Context;
const CommandError = command.CommandError;
const TrackId = command.TrackId;
const ClipId = command.ClipId;
const Range = command.Range;

/// Positions are clamped to +/- this many samples (Rust `soundcraft_time::MAX_POSITION`).
pub const MAX_POSITION: i64 = 1 << 40;

/// Records a `BadParams` message in `ctx.diag` ("bad parameters for `cmd`: …") and returns the error.
pub fn bad(ctx: Context, cmd: []const u8, comptime fmt: []const u8, args: anytype) CommandError {
    var tmp: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&tmp, fmt, args) catch "message too long";
    ctx.diag.set("bad parameters for `{s}`: {s}", .{ cmd, msg });
    return error.BadParams;
}

/// The value at `key` when `p` is an object; null otherwise.
fn field(p: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (p) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// Non-negative integers only (serde `as_u64`).
fn asU64(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        else => null,
    };
}

/// Integers and floats (serde `as_f64`).
fn asF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => null,
    };
}

/// Float to `i64` with NaN -> 0 and saturation (Rust `soundcraft_time::to_samples`).
fn toSamples(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    if (v >= 9.223372036854775807e18) return std.math.maxInt(i64);
    if (v <= -9.223372036854775808e18) return std.math.minInt(i64);
    return @intFromFloat(@round(v));
}

/// A finite number at `key`, else `d`.
pub fn f64Or(p: std.json.Value, key: []const u8, d: f64) f64 {
    const v = field(p, key) orelse return d;
    const f = asF64(v) orelse return d;
    return if (std.math.isFinite(f)) f else d;
}

pub fn f32Or(p: std.json.Value, key: []const u8, d: f32) f32 {
    return @floatCast(f64Or(p, key, @floatCast(d)));
}

/// An integer at `key`; a finite float is rounded; anything else gives `d`.
pub fn i64Or(p: std.json.Value, key: []const u8, d: i64) i64 {
    const v = field(p, key) orelse return d;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) toSamples(f) else d,
        else => d,
    };
}

pub fn boolOr(p: std.json.Value, key: []const u8, d: bool) bool {
    const v = field(p, key) orelse return d;
    return switch (v) {
        .bool => |b| b,
        else => d,
    };
}

pub fn strParam(p: std.json.Value, key: []const u8) ?[]const u8 {
    const v = field(p, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Resolve one track reference: an id that exists, or a name.
fn resolveTrack(ctx: Context, v: std.json.Value) ?TrackId {
    if (asU64(v)) |n| return if (ctx.trackExists(n)) n else null;
    return switch (v) {
        .string => |name| ctx.trackIdByName(name),
        else => null,
    };
}

fn unknownTrack(ctx: Context, cmd: []const u8, v: std.json.Value) CommandError {
    return switch (v) {
        .integer => |i| bad(ctx, cmd, "unknown track {d}", .{i}),
        .string => |s| bad(ctx, cmd, "unknown track `{s}`", .{s}),
        else => bad(ctx, cmd, "unknown track entry", .{}),
    };
}

/// A single track from `key` (id number or name). Null when the key is absent.
pub fn trackParam(ctx: Context, cmd: []const u8, p: std.json.Value, key: []const u8) CommandError!?TrackId {
    const v = field(p, key) orelse return null;
    if (asU64(v)) |n| {
        if (ctx.trackExists(n)) return n;
        return bad(ctx, cmd, "no track with id {d}", .{n});
    }
    switch (v) {
        .string => |name| {
            if (ctx.trackIdByName(name)) |id| return id;
            return bad(ctx, cmd, "no track named `{s}`", .{name});
        },
        else => return bad(ctx, cmd, "`{s}` must be a track id or name", .{key}),
    }
}

/// Tracks to act on: `tracks` (an array of ids or names, duplicates dropped), else
/// `track`, else the selected tracks. Caller frees the list with `ctx.gpa`.
pub fn tracksParam(ctx: Context, cmd: []const u8, p: std.json.Value) CommandError!std.ArrayList(TrackId) {
    if (field(p, "tracks")) |tv| {
        switch (tv) {
            .array => |arr| return tracksFromArray(ctx, cmd, arr.items),
            else => {},
        }
    }
    if (try trackParam(ctx, cmd, p, "track")) |t| {
        var out: std.ArrayList(TrackId) = .empty;
        errdefer out.deinit(ctx.gpa);
        try out.append(ctx.gpa, t);
        return out;
    }
    return ctx.targetTracks();
}

fn tracksFromArray(ctx: Context, cmd: []const u8, items: []const std.json.Value) CommandError!std.ArrayList(TrackId) {
    var out: std.ArrayList(TrackId) = .empty;
    errdefer out.deinit(ctx.gpa);
    var seen: std.AutoHashMapUnmanaged(TrackId, void) = .empty;
    defer seen.deinit(ctx.gpa);
    for (items) |v| {
        const id = resolveTrack(ctx, v) orelse return unknownTrack(ctx, cmd, v);
        // Duplicates multiply the work (each entry renders and keeps its own result),
        // so repeated ids are dropped instead of letting them blow the budget.
        const gop = try seen.getOrPut(ctx.gpa, id);
        if (!gop.found_existing) try out.append(ctx.gpa, id);
    }
    return out;
}

/// Like `tracksParam` but an error when the result is empty.
pub fn tracksRequired(ctx: Context, cmd: []const u8, p: std.json.Value) CommandError!std.ArrayList(TrackId) {
    var t = try tracksParam(ctx, cmd, p);
    if (t.items.len == 0) {
        t.deinit(ctx.gpa);
        return bad(ctx, cmd, "no tracks: pass `track`/`tracks` or select tracks", .{});
    }
    return t;
}

fn positionParamRaw(ctx: Context, cmd: []const u8, p: std.json.Value, key: []const u8) CommandError!?i64 {
    const v = field(p, key) orelse return null;
    switch (v) {
        .integer => |n| return n,
        .float => |f| return toSamples(f),
        .object => |o| {
            if (o.get("seconds")) |sv| {
                if (asF64(sv)) |secs| return ctx.secondsToSamples(secs);
            }
        },
        .string => |text| {
            if (ctx.parsePosition(text)) |n| return n;
            return bad(ctx, cmd, "cannot parse position `{s}`", .{text});
        },
        else => {},
    }
    return bad(ctx, cmd, "`{s}` must be samples, {{seconds}}, or a time string", .{key});
}

/// A position from `key`: a number of samples, `{"seconds": x}`, or a time string
/// (parsed by the context). Clamped to +/- `MAX_POSITION`. Null when the key is absent.
pub fn positionParam(ctx: Context, cmd: []const u8, p: std.json.Value, key: []const u8) CommandError!?i64 {
    const raw = (try positionParamRaw(ctx, cmd, p, key)) orelse return null;
    return std.math.clamp(raw, -MAX_POSITION, MAX_POSITION);
}

/// A range from `start` plus `end` or `length`; `start` alone is a point; with no
/// `start` the edit selection is used.
pub fn rangeParam(ctx: Context, cmd: []const u8, p: std.json.Value) CommandError!Range {
    const st = try positionParam(ctx, cmd, p, "start");
    const en = try positionParam(ctx, cmd, p, "end");
    const len = try positionParam(ctx, cmd, p, "length");
    if (st) |a| {
        if (en) |b| return Range.new(a, b);
        if (len) |l| return Range.new(a, a +| l);
        return Range.point(a);
    }
    return ctx.selection();
}

/// The `clip` id; an error when it is missing or not a non-negative integer.
pub fn clipId(ctx: Context, cmd: []const u8, p: std.json.Value) CommandError!ClipId {
    const v = field(p, "clip") orelse return bad(ctx, cmd, "`clip` id required", .{});
    return asU64(v) orelse bad(ctx, cmd, "`clip` id required", .{});
}

/// Clips to act on: `clips` (an array of ids; non-numbers are skipped), else `clip`,
/// else the selected clips, else the clips on selected tracks that touch the
/// edit selection. Caller frees the list with `ctx.gpa`.
pub fn clipIdsParam(ctx: Context, p: std.json.Value) CommandError!std.ArrayList(ClipId) {
    if (field(p, "clips")) |cv| {
        switch (cv) {
            .array => |arr| return clipsFromArray(ctx, arr.items),
            else => {},
        }
    }
    if (field(p, "clip")) |cv| {
        if (asU64(cv)) |n| {
            var out: std.ArrayList(ClipId) = .empty;
            errdefer out.deinit(ctx.gpa);
            try out.append(ctx.gpa, n);
            return out;
        }
    }
    const selected = try ctx.selectedClipIds();
    if (selected.items.len > 0) return selected;
    var empty_selected = selected;
    empty_selected.deinit(ctx.gpa);
    return ctx.clipsInSelection();
}

fn clipsFromArray(ctx: Context, items: []const std.json.Value) CommandError!std.ArrayList(ClipId) {
    var out: std.ArrayList(ClipId) = .empty;
    errdefer out.deinit(ctx.gpa);
    for (items) |v| {
        if (asU64(v)) |n| try out.append(ctx.gpa, n);
    }
    return out;
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;
const fixtures = command.testing_fixtures;

/// Parses JSON into an arena that the test owns.
fn parse(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "bad names the command in the diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .tracks = 1 };
    const ctx = fake.context(arena.allocator(), &diag);
    const err = bad(ctx, "mix.volume", "no track with id {d}", .{9});
    try testing.expectEqual(error.BadParams, err);
    try testing.expectEqualStrings("bad parameters for `mix.volume`: no track with id 9", diag.message());
}

test "f64Or, f32Or, i64Or and boolOr fall back on missing or wrong types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{\"x\":1.5,\"n\":3,\"r\":2.6,\"s\":\"nope\",\"b\":true}");
    try testing.expectEqual(@as(f64, 1.5), f64Or(p, "x", 0));
    try testing.expectEqual(@as(f64, 3.0), f64Or(p, "n", 0));
    try testing.expectEqual(@as(f64, 7.0), f64Or(p, "missing", 7.0));
    try testing.expectEqual(@as(f64, 7.0), f64Or(p, "s", 7.0));
    try testing.expectEqual(@as(f32, 1.5), f32Or(p, "x", 0));
    try testing.expectEqual(@as(i64, 3), i64Or(p, "n", 0));
    try testing.expectEqual(@as(i64, 3), i64Or(p, "r", 0));
    try testing.expectEqual(@as(i64, -1), i64Or(p, "s", -1));
    try testing.expect(boolOr(p, "b", false));
    try testing.expect(!boolOr(p, "n", false));
    try testing.expect(boolOr(p, "missing", true));
}

test "f64Or ignores non-finite values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena.allocator(), "x", .{ .float = std.math.nan(f64) });
    try testing.expectEqual(@as(f64, 2.0), f64Or(.{ .object = obj }, "x", 2.0));
}

test "strParam returns only string values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{\"name\":\"Kick\",\"n\":1}");
    try testing.expectEqualStrings("Kick", strParam(p, "name").?);
    try testing.expect(strParam(p, "n") == null);
    try testing.expect(strParam(p, "missing") == null);
}

test "trackParam resolves a track by id or name and reports misses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .tracks = 2 };
    const ctx = fake.context(arena.allocator(), &diag);

    const by_id = try parse(arena.allocator(), "{\"track\":1}");
    try testing.expectEqual(@as(?TrackId, 1), try trackParam(ctx, "t.cmd", by_id, "track"));

    const by_name = try parse(arena.allocator(), "{\"track\":\"Kick\"}");
    try testing.expectEqual(@as(?TrackId, 0), try trackParam(ctx, "t.cmd", by_name, "track"));

    const absent = try parse(arena.allocator(), "{}");
    try testing.expectEqual(@as(?TrackId, null), try trackParam(ctx, "t.cmd", absent, "track"));

    const missing_id = try parse(arena.allocator(), "{\"track\":9}");
    try testing.expectError(error.BadParams, trackParam(ctx, "t.cmd", missing_id, "track"));
    try testing.expectEqualStrings("bad parameters for `t.cmd`: no track with id 9", diag.message());

    const missing_name = try parse(arena.allocator(), "{\"track\":\"Nope\"}");
    try testing.expectError(error.BadParams, trackParam(ctx, "t.cmd", missing_name, "track"));
    try testing.expectEqualStrings("bad parameters for `t.cmd`: no track named `Nope`", diag.message());

    const wrong_type = try parse(arena.allocator(), "{\"track\":true}");
    try testing.expectError(error.BadParams, trackParam(ctx, "t.cmd", wrong_type, "track"));
    try testing.expectEqualStrings("bad parameters for `t.cmd`: `track` must be a track id or name", diag.message());
}

test "tracksParam resolves arrays, drops duplicates and falls back to the selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .tracks = 2, .selected_tracks = 2 };
    const ctx = fake.context(arena.allocator(), &diag);

    const arr = try parse(arena.allocator(), "{\"tracks\":[0,\"Kick\",1,1]}");
    var from_array = try tracksParam(ctx, "t.cmd", arr);
    defer from_array.deinit(arena.allocator());
    try testing.expectEqualSlices(TrackId, &.{ 0, 1 }, from_array.items);

    const bad_entry = try parse(arena.allocator(), "{\"tracks\":[\"Nope\"]}");
    try testing.expectError(error.BadParams, tracksParam(ctx, "t.cmd", bad_entry));
    try testing.expectEqualStrings("bad parameters for `t.cmd`: unknown track `Nope`", diag.message());

    const none = try parse(arena.allocator(), "{}");
    var selected = try tracksParam(ctx, "t.cmd", none);
    defer selected.deinit(arena.allocator());
    try testing.expectEqualSlices(TrackId, &.{ 0, 1 }, selected.items);
}

test "tracksRequired errors when no track is selected or named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .tracks = 1, .selected_tracks = 0 };
    const ctx = fake.context(arena.allocator(), &diag);
    const none = try parse(arena.allocator(), "{}");
    try testing.expectError(error.BadParams, tracksRequired(ctx, "mix.volume", none));
    try testing.expectEqualStrings("bad parameters for `mix.volume`: no tracks: pass `track`/`tracks` or select tracks", diag.message());

    fake.selected_tracks = 1;
    var one = try tracksRequired(ctx, "mix.volume", none);
    defer one.deinit(arena.allocator());
    try testing.expectEqual(@as(usize, 1), one.items.len);
}

test "positionParam accepts samples, seconds and time strings, and clamps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{};
    const ctx = fake.context(arena.allocator(), &diag);

    const samples = try parse(arena.allocator(), "{\"at\":96000}");
    try testing.expectEqual(@as(?i64, 96000), try positionParam(ctx, "p.cmd", samples, "at"));

    const secs = try parse(arena.allocator(), "{\"at\":{\"seconds\":2.5}}");
    try testing.expectEqual(@as(?i64, 120_000), try positionParam(ctx, "p.cmd", secs, "at"));

    const text = try parse(arena.allocator(), "{\"at\":\"123\"}");
    try testing.expectEqual(@as(?i64, 123), try positionParam(ctx, "p.cmd", text, "at"));

    const huge = try parse(arena.allocator(), "{\"at\":1099511627776000}");
    try testing.expectEqual(@as(?i64, MAX_POSITION), try positionParam(ctx, "p.cmd", huge, "at"));

    const neg_huge = try parse(arena.allocator(), "{\"at\":-1099511627776000}");
    try testing.expectEqual(@as(?i64, -MAX_POSITION), try positionParam(ctx, "p.cmd", neg_huge, "at"));

    const bad_text = try parse(arena.allocator(), "{\"at\":\"x\"}");
    try testing.expectError(error.BadParams, positionParam(ctx, "p.cmd", bad_text, "at"));
    try testing.expectEqualStrings("bad parameters for `p.cmd`: cannot parse position `x`", diag.message());

    const wrong = try parse(arena.allocator(), "{\"at\":[1]}");
    try testing.expectError(error.BadParams, positionParam(ctx, "p.cmd", wrong, "at"));

    const absent = try parse(arena.allocator(), "{}");
    try testing.expectEqual(@as(?i64, null), try positionParam(ctx, "p.cmd", absent, "at"));
}

test "rangeParam uses start and end, start and length, or the selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .selection_empty = false };
    const ctx = fake.context(arena.allocator(), &diag);

    const both = try parse(arena.allocator(), "{\"start\":10,\"end\":5}");
    try testing.expectEqual(Range.new(5, 10), try rangeParam(ctx, "r.cmd", both));

    const len = try parse(arena.allocator(), "{\"start\":10,\"length\":5}");
    try testing.expectEqual(Range.new(10, 15), try rangeParam(ctx, "r.cmd", len));

    const point = try parse(arena.allocator(), "{\"start\":7}");
    try testing.expectEqual(Range.point(7), try rangeParam(ctx, "r.cmd", point));

    const none = try parse(arena.allocator(), "{}");
    try testing.expectEqual(Range.new(0, 48_000), try rangeParam(ctx, "r.cmd", none));
}

test "clipId requires a clip id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{};
    const ctx = fake.context(arena.allocator(), &diag);
    const ok = try parse(arena.allocator(), "{\"clip\":4}");
    try testing.expectEqual(@as(ClipId, 4), try clipId(ctx, "c.cmd", ok));
    const none = try parse(arena.allocator(), "{}");
    try testing.expectError(error.BadParams, clipId(ctx, "c.cmd", none));
    try testing.expectEqualStrings("bad parameters for `c.cmd`: `clip` id required", diag.message());
}

test "clipIdsParam: array, single, selected, then selection overlap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: command.Diagnostic = .{};
    var fake: fixtures.FakeSession = .{};
    const ctx = fake.context(arena.allocator(), &diag);

    const arr = try parse(arena.allocator(), "{\"clips\":[1,\"x\",3]}");
    var from_array = try clipIdsParam(ctx, arr);
    defer from_array.deinit(arena.allocator());
    try testing.expectEqualSlices(ClipId, &.{ 1, 3 }, from_array.items);

    const single = try parse(arena.allocator(), "{\"clip\":9}");
    var from_single = try clipIdsParam(ctx, single);
    defer from_single.deinit(arena.allocator());
    try testing.expectEqualSlices(ClipId, &.{9}, from_single.items);

    fake.selected_clips = 2;
    const none = try parse(arena.allocator(), "{}");
    var from_selected = try clipIdsParam(ctx, none);
    defer from_selected.deinit(arena.allocator());
    try testing.expectEqualSlices(ClipId, &.{ 100, 101 }, from_selected.items);

    fake.selected_clips = 0;
    var from_overlap = try clipIdsParam(ctx, none);
    defer from_overlap.deinit(arena.allocator());
    try testing.expectEqual(@as(usize, 0), from_overlap.items.len);
}

test "MAX_POSITION is 2^40 samples" {
    try testing.expectEqual(@as(i64, 1 << 40), MAX_POSITION);
}
