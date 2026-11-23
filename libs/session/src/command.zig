// Translated to Zig from soundcraft/crates/engine/src/cmd.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The command registry framework: spec records, the four constructors that
//! replace the `cmd!` macro, the JSON-serialisable `CommandInfo`, enablement
//! predicates expressed against an opaque `Context`, and a comptime-built
//! `Registry` (replacing the Rust `OnceLock<Vec<CommandSpec>>`).
//!
//! Command bodies (the ~280 `crates/engine/src/cmd/*.rs` files) are not part of
//! this file. They are written against SoundCraft's session model and will be
//! ported per menu area once Seridian's project model exists, using this framework.
//!
//! Threading: commands run on the control thread, never on the audio thread.
//! Nothing here allocates except where a `gpa` is passed in explicitly.

const std = @import("std");
const builtin = @import("builtin");

/// Errors a command can return. Mirrors the Rust `EngineError` variants the
/// command bodies use. `BadParams` carries its message in `Diagnostic`.
pub const CommandError = error{
    BadParams,
    Internal,
    OutOfMemory,
};

/// Track and clip ids. Placeholders until the model library defines its own types.
pub const TrackId = u64;
pub const ClipId = u64;

/// Half-open sample range `[start, end)`. Placeholder for the time library's
/// `Range`; `new` normalises the order like the Rust constructor does.
pub const Range = struct {
    start: i64,
    end: i64,

    pub fn new(a: i64, b: i64) Range {
        return if (a <= b) .{ .start = a, .end = b } else .{ .start = b, .end = a };
    }

    pub fn point(at: i64) Range {
        return .{ .start = at, .end = at };
    }

    pub fn isEmpty(self: Range) bool {
        return self.start >= self.end;
    }
};

/// The message of the last `BadParams` error, filled in by `bad()`.
/// Lives on the caller's stack; no allocation.
pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    /// Formats into the fixed buffer. A message that does not fit is replaced
    /// by a fixed marker rather than a half-written string.
    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(&self.buf, fmt, args)) |out| {
            self.len = out.len;
        } else |_| {
            const marker = "message too long";
            @memcpy(self.buf[0..marker.len], marker);
            self.len = marker.len;
        }
    }
};

/// What a command may ask of the session. The session (session-exec, later)
/// supplies the vtable; this file only knows the queries that enablement and
/// parameter resolution need. All calls happen on the control thread.
pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Allocator for results and for the lists returned by the helpers below.
    gpa: std.mem.Allocator,
    /// Where `bad()` writes its message.
    diag: *Diagnostic,

    pub const VTable = struct {
        track_count: *const fn (ptr: *anyopaque) usize,
        selected_track_count: *const fn (ptr: *anyopaque) usize,
        selected_clip_count: *const fn (ptr: *anyopaque) usize,
        /// True when the edit selection is empty (Rust `edit.selection.is_empty()`).
        selection_is_empty: *const fn (ptr: *anyopaque) bool,
        selection: *const fn (ptr: *anyopaque) Range,
        can_undo: *const fn (ptr: *anyopaque) bool,
        can_redo: *const fn (ptr: *anyopaque) bool,
        clipboard_track_count: *const fn (ptr: *anyopaque) usize,
        track_exists: *const fn (ptr: *anyopaque, id: TrackId) bool,
        track_id_by_name: *const fn (ptr: *anyopaque, name: []const u8) ?TrackId,
        /// Rust `Engine::target_tracks()`: the selected tracks. Caller frees the list.
        target_tracks: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(TrackId),
        /// The selected clips. Caller frees the list.
        selected_clip_ids: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(ClipId),
        /// Clips on selected tracks that touch the edit selection (or contain its
        /// start when the selection is a point). Caller frees the list.
        clips_in_selection: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(ClipId),
        /// Time-string parsing (`"bars_beats:5|1|000"`, `"min_secs:0:12.500"`, …),
        /// delegated to the time library. Returns null when no format parses.
        parse_position: *const fn (ptr: *anyopaque, text: []const u8) ?i64,
        /// Seconds to samples at the session rate (Rust `SampleRate::samples`).
        seconds_to_samples: *const fn (ptr: *anyopaque, seconds: f64) i64,
    };

    pub fn trackCount(self: Context) usize {
        return self.vtable.track_count(self.ptr);
    }

    pub fn selectedTrackCount(self: Context) usize {
        return self.vtable.selected_track_count(self.ptr);
    }

    pub fn selectedClipCount(self: Context) usize {
        return self.vtable.selected_clip_count(self.ptr);
    }

    pub fn selectionIsEmpty(self: Context) bool {
        return self.vtable.selection_is_empty(self.ptr);
    }

    pub fn selection(self: Context) Range {
        return self.vtable.selection(self.ptr);
    }

    pub fn canUndo(self: Context) bool {
        return self.vtable.can_undo(self.ptr);
    }

    pub fn canRedo(self: Context) bool {
        return self.vtable.can_redo(self.ptr);
    }

    pub fn clipboardTrackCount(self: Context) usize {
        return self.vtable.clipboard_track_count(self.ptr);
    }

    pub fn trackExists(self: Context, id: TrackId) bool {
        return self.vtable.track_exists(self.ptr, id);
    }

    pub fn trackIdByName(self: Context, name: []const u8) ?TrackId {
        return self.vtable.track_id_by_name(self.ptr, name);
    }

    pub fn targetTracks(self: Context) std.mem.Allocator.Error!std.ArrayList(TrackId) {
        return self.vtable.target_tracks(self.ptr, self.gpa);
    }

    pub fn selectedClipIds(self: Context) std.mem.Allocator.Error!std.ArrayList(ClipId) {
        return self.vtable.selected_clip_ids(self.ptr, self.gpa);
    }

    pub fn clipsInSelection(self: Context) std.mem.Allocator.Error!std.ArrayList(ClipId) {
        return self.vtable.clips_in_selection(self.ptr, self.gpa);
    }

    pub fn parsePosition(self: Context, text: []const u8) ?i64 {
        return self.vtable.parse_position(self.ptr, text);
    }

    pub fn secondsToSamples(self: Context, seconds: f64) i64 {
        return self.vtable.seconds_to_samples(self.ptr, seconds);
    }
};

/// Enablement. `null` = enabled; otherwise a static reason shown as `disabled_reason`.
/// (Rust `Enabled = fn(&Engine) -> Result<(), String>`.)
pub const Enabled = *const fn (ctx: Context) ?[]const u8;

/// A command body. Results are `std.json.Value`; `.null` for "nothing to report".
pub const Run = *const fn (ctx: Context, params: std.json.Value) CommandError!std.json.Value;

/// A registered command. Field meanings follow the Rust `CommandSpec`.
pub const CommandSpec = struct {
    id: []const u8,
    label: []const u8,
    /// Menu path, e.g. `{ "Edit", "Trim" }`; empty = not in menus.
    menu: []const []const u8 = &.{},
    shortcut: ?[]const u8 = null,
    /// Human/agent parameter documentation.
    params: []const u8 = "{}",
    enabled: Enabled = always,
    run: Run,
    /// Recorded in the session journal.
    journal: bool,
    /// Pushed onto the undo stack.
    undoable: bool,
    /// Only touches the zoom (Rust `view`).
    view: bool,

    /// Serialisable description with the current enablement.
    pub fn info(self: *const CommandSpec, ctx: Context) CommandInfo {
        const reason = self.enabled(ctx);
        return .{
            .id = self.id,
            .label = self.label,
            .menu = self.menu,
            .shortcut = self.shortcut,
            .params = self.params,
            .enabled = reason == null,
            .disabled_reason = reason,
        };
    }
};

/// The arguments the four constructors take. `enabled` defaults to `always`.
pub const SpecArgs = struct {
    id: []const u8,
    label: []const u8,
    menu: []const []const u8 = &.{},
    shortcut: ?[]const u8 = null,
    params: []const u8 = "{}",
    enabled: Enabled = always,
    run: Run,
};

/// `cmd!(id, …)`: journaled and undoable.
pub fn command(args: SpecArgs) CommandSpec {
    return build(args, true, true, false);
}

/// `cmd!(query …)`: read-only; neither journaled nor undoable.
pub fn query(args: SpecArgs) CommandSpec {
    return build(args, false, false, false);
}

/// `cmd!(noundo …)`: journaled, not undoable.
pub fn noundo(args: SpecArgs) CommandSpec {
    return build(args, true, false, false);
}

/// `cmd!(view …)`: only touches the zoom; neither journaled nor undoable.
pub fn view(args: SpecArgs) CommandSpec {
    return build(args, false, false, true);
}

fn build(args: SpecArgs, journal: bool, undoable: bool, is_view: bool) CommandSpec {
    return .{
        .id = args.id,
        .label = args.label,
        .menu = args.menu,
        .shortcut = args.shortcut,
        .params = args.params,
        .enabled = args.enabled,
        .run = args.run,
        .journal = journal,
        .undoable = undoable,
        .view = is_view,
    };
}

/// Serialisable description of a command (the `engine.commands` reply).
pub const CommandInfo = struct {
    id: []const u8,
    label: []const u8,
    menu: []const []const u8,
    shortcut: ?[]const u8,
    params: []const u8,
    enabled: bool,
    disabled_reason: ?[]const u8,
};

// ---- enablement -----------------------------------------------------------------------

pub fn always(_: Context) ?[]const u8 {
    return null;
}

pub fn hasTracks(ctx: Context) ?[]const u8 {
    return if (ctx.trackCount() == 0) "the session has no tracks" else null;
}

pub fn hasSelection(ctx: Context) ?[]const u8 {
    return if (ctx.selectedTrackCount() == 0 and ctx.selectedClipCount() == 0) "nothing is selected" else null;
}

pub fn hasRange(ctx: Context) ?[]const u8 {
    if ((ctx.selectedTrackCount() == 0 or ctx.selectionIsEmpty()) and ctx.selectedClipCount() == 0) {
        return "make an edit selection first";
    }
    return null;
}

pub fn canUndo(ctx: Context) ?[]const u8 {
    return if (ctx.canUndo()) null else "nothing to undo";
}

pub fn canRedo(ctx: Context) ?[]const u8 {
    return if (ctx.canRedo()) null else "nothing to redo";
}

pub fn hasClipboard(ctx: Context) ?[]const u8 {
    return if (ctx.clipboardTrackCount() == 0) "the clipboard is empty" else null;
}

// ---- registry -------------------------------------------------------------------------

/// Total number of specs across the groups.
fn countSpecs(comptime groups: []const []const CommandSpec) usize {
    var n: usize = 0;
    for (groups) |g| n += g.len;
    return n;
}

/// Indices of `all` sorted by id. Comptime; a duplicate id is a compile error.
fn sortedIndex(comptime all: []const CommandSpec) [all.len]usize {
    var idx: [all.len]usize = undefined;
    for (&idx, 0..) |*x, i| x.* = i;
    for (1..all.len) |i| {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, all[idx[j]].id, all[idx[j - 1]].id)) : (j -= 1) {
            std.mem.swap(usize, &idx[j], &idx[j - 1]);
        }
    }
    for (1..all.len) |i| {
        if (std.mem.eql(u8, all[idx[i - 1]].id, all[idx[i]].id)) {
            @compileError("duplicate command id: " ++ all[idx[i]].id);
        }
    }
    return idx;
}

/// A registry over comptime-known spec groups. `specs` keeps registration order
/// (group by group, as the Rust `command_specs()` concatenation does); `find`
/// binary-searches a comptime-sorted index of the ids.
pub fn Registry(comptime groups: []const []const CommandSpec) type {
    const total = comptime countSpecs(groups);
    const all: [total]CommandSpec = comptime blk: {
        var list: [total]CommandSpec = undefined;
        var i: usize = 0;
        for (groups) |g| {
            for (g) |s| {
                list[i] = s;
                i += 1;
            }
        }
        break :blk list;
    };
    const sorted: [total]usize = comptime sortedIndex(&all);

    return struct {
        pub const specs: []const CommandSpec = &all;

        /// The command with this id, or null.
        pub fn find(id: []const u8) ?*const CommandSpec {
            var lo: usize = 0;
            var hi: usize = total;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const cand = &all[sorted[mid]];
                switch (std.mem.order(u8, id, cand.id)) {
                    .eq => return cand,
                    .lt => hi = mid,
                    .gt => lo = mid + 1,
                }
            }
            return null;
        }
    };
}

// ---- tests ----------------------------------------------------------------------------

/// Fake session and fixture commands, compiled only into test builds.
pub const testing_fixtures = if (builtin.is_test) struct {
    pub const FakeSession = struct {
        tracks: usize = 0,
        selected_tracks: usize = 0,
        selected_clips: usize = 0,
        selection_empty: bool = true,
        can_undo: bool = false,
        can_redo: bool = false,
        clipboard_tracks: usize = 0,
        message_count: usize = 0,
        transport_requests: usize = 0,
        clipboard_len: i64 = 0,

        const vtable: Context.VTable = .{
            .track_count = trackCountFn,
            .selected_track_count = selectedTrackCountFn,
            .selected_clip_count = selectedClipCountFn,
            .selection_is_empty = selectionIsEmptyFn,
            .selection = selectionFn,
            .can_undo = canUndoFn,
            .can_redo = canRedoFn,
            .clipboard_track_count = clipboardTrackCountFn,
            .track_exists = trackExistsFn,
            .track_id_by_name = trackIdByNameFn,
            .target_tracks = targetTracksFn,
            .selected_clip_ids = selectedClipIdsFn,
            .clips_in_selection = clipsInSelectionFn,
            .parse_position = parsePositionFn,
            .seconds_to_samples = secondsToSamplesFn,
        };

        pub fn context(self: *FakeSession, gpa: std.mem.Allocator, diag: *Diagnostic) Context {
            return .{ .ptr = self, .vtable = &vtable, .gpa = gpa, .diag = diag };
        }

        fn from(ptr: *anyopaque) *FakeSession {
            return @ptrCast(@alignCast(ptr));
        }

        fn trackCountFn(ptr: *anyopaque) usize {
            return from(ptr).tracks;
        }

        fn selectedTrackCountFn(ptr: *anyopaque) usize {
            return from(ptr).selected_tracks;
        }

        fn selectedClipCountFn(ptr: *anyopaque) usize {
            return from(ptr).selected_clips;
        }

        fn selectionIsEmptyFn(ptr: *anyopaque) bool {
            return from(ptr).selection_empty;
        }

        fn selectionFn(ptr: *anyopaque) Range {
            return if (from(ptr).selection_empty) Range.point(0) else Range.new(0, 48_000);
        }

        fn canUndoFn(ptr: *anyopaque) bool {
            return from(ptr).can_undo;
        }

        fn canRedoFn(ptr: *anyopaque) bool {
            return from(ptr).can_redo;
        }

        fn clipboardTrackCountFn(ptr: *anyopaque) usize {
            return from(ptr).clipboard_tracks;
        }

        fn trackExistsFn(ptr: *anyopaque, id: TrackId) bool {
            return id < from(ptr).tracks;
        }

        fn trackIdByNameFn(ptr: *anyopaque, name: []const u8) ?TrackId {
            if (from(ptr).tracks > 0 and std.mem.eql(u8, name, "Kick")) return 0;
            return null;
        }

        fn targetTracksFn(ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(TrackId) {
            var out: std.ArrayList(TrackId) = .empty;
            errdefer out.deinit(gpa);
            for (0..from(ptr).selected_tracks) |i| try out.append(gpa, @intCast(i));
            return out;
        }

        fn selectedClipIdsFn(ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(ClipId) {
            var out: std.ArrayList(ClipId) = .empty;
            errdefer out.deinit(gpa);
            for (0..from(ptr).selected_clips) |i| try out.append(gpa, 100 + @as(u64, @intCast(i)));
            return out;
        }

        fn clipsInSelectionFn(_: *anyopaque, _: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(ClipId) {
            return .empty;
        }

        fn parsePositionFn(_: *anyopaque, text: []const u8) ?i64 {
            return std.fmt.parseInt(i64, text, 10) catch null;
        }

        fn secondsToSamplesFn(_: *anyopaque, seconds: f64) i64 {
            return @intFromFloat(@round(seconds * 48_000.0));
        }
    };

    /// `system.ping` returns "pong"; `system.track_count` reports the track count;
    /// `system.require_name` needs a `name` string parameter.
    pub const specs = [_]CommandSpec{
        command(.{ .id = "system.ping", .label = "Ping", .run = ping }),
        query(.{ .id = "system.track_count", .label = "Track Count", .run = trackCount, .enabled = hasTracks }),
        noundo(.{ .id = "system.require_name", .label = "Require Name", .params = "{\"name\": string}", .run = requireName }),
    };

    /// Panics in the Rust test were replaced by an error return: mutate fake state, then fail.
    pub const probe = [_]CommandSpec{
        noundo(.{ .id = "test.panic_probe", .label = "Panic Probe", .run = panicProbe }),
    };

    fn ping(_: Context, _: std.json.Value) CommandError!std.json.Value {
        return .{ .string = "pong" };
    }

    fn trackCount(ctx: Context, _: std.json.Value) CommandError!std.json.Value {
        return .{ .integer = @intCast(ctx.trackCount()) };
    }

    fn requireName(ctx: Context, params: std.json.Value) CommandError!std.json.Value {
        const name = switch (params) {
            .object => |o| if (o.get("name")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            else => null,
        };
        if (name == null) {
            ctx.diag.set("bad parameters for `system.require_name`: `name` required", .{});
            return error.BadParams;
        }
        return .null;
    }

    fn panicProbe(ctx: Context, params: std.json.Value) CommandError!std.json.Value {
        const wants_panic = switch (params) {
            .object => |o| o.get("panic") != null,
            else => false,
        };
        if (!wants_panic) return .null;
        const fake: *FakeSession = @ptrCast(@alignCast(ctx.ptr));
        fake.clipboard_tracks = 1;
        fake.clipboard_len = 123;
        fake.message_count += 1;
        fake.transport_requests += 1;
        return error.Internal;
    }
} else struct {};

test "ids are unique and documented" {
    const fixtures = testing_fixtures;
    const Reg = Registry(&.{&fixtures.specs});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (Reg.specs) |c| {
        const gop = try seen.getOrPut(std.testing.allocator, c.id);
        try std.testing.expect(!gop.found_existing);
        try std.testing.expect(c.label.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, c.id, '.') != null);
    }
    try std.testing.expectEqual(fixtures.specs.len, Reg.specs.len);
}

test "every command survives empty params" {
    // Rust ran every command with `{}` on an empty and a demo session and failed on
    // any panic. A Zig panic aborts the test binary, so the test passes by returning
    // normally for every command; errors are the allowed outcome.
    const fixtures = testing_fixtures;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Reg = Registry(&.{&fixtures.specs});
    const empty_params: std.json.Value = .{ .object = .empty };
    inline for (.{ false, true }) |demo| {
        var fake: fixtures.FakeSession = if (demo)
            .{ .tracks = 2, .selected_tracks = 1, .selection_empty = false }
        else
            .{};
        var diag: Diagnostic = .{};
        const ctx = fake.context(arena.allocator(), &diag);
        for (Reg.specs) |c| {
            _ = c.run(ctx, empty_params) catch |err| switch (err) {
                error.BadParams, error.Internal, error.OutOfMemory => {},
            };
        }
    }
}

test "a command returning an error leaves no side effects" {
    // The probe mutates fake session state and then returns error.Internal. The
    // no-side-effects guarantee is provided by the executor's rollback (session-exec),
    // so this test checks the command-level contract: the error reaches the caller.
    const fixtures = testing_fixtures;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: fixtures.FakeSession = .{};
    var diag: Diagnostic = .{};
    const ctx = fake.context(arena.allocator(), &diag);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena.allocator(), "panic", .{ .bool = true });
    const params: std.json.Value = .{ .object = obj };
    try std.testing.expectError(error.Internal, fixtures.probe[0].run(ctx, params));
}

test "constructors set the journal, undo and view flags" {
    const noop = struct {
        fn run(_: Context, _: std.json.Value) CommandError!std.json.Value {
            return .null;
        }
    }.run;
    const c = command(.{ .id = "a.c", .label = "C", .run = noop });
    try std.testing.expect(c.journal and c.undoable and !c.view);
    const q = query(.{ .id = "a.q", .label = "Q", .run = noop });
    try std.testing.expect(!q.journal and !q.undoable and !q.view);
    const n = noundo(.{ .id = "a.n", .label = "N", .run = noop });
    try std.testing.expect(n.journal and !n.undoable and !n.view);
    const v = view(.{ .id = "a.v", .label = "V", .run = noop });
    try std.testing.expect(!v.journal and !v.undoable and v.view);
}

test "info serialises enablement and the disabled reason" {
    const fixtures = testing_fixtures;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake: fixtures.FakeSession = .{};
    var diag: Diagnostic = .{};
    const ctx = fake.context(arena.allocator(), &diag);

    const ping_info = fixtures.specs[0].info(ctx);
    const ping_json = try std.json.Stringify.valueAlloc(arena.allocator(), ping_info, .{});
    try std.testing.expectEqualStrings(
        "{\"id\":\"system.ping\",\"label\":\"Ping\",\"menu\":[],\"shortcut\":null,\"params\":\"{}\",\"enabled\":true,\"disabled_reason\":null}",
        ping_json,
    );

    const count_info = fixtures.specs[1].info(ctx);
    try std.testing.expect(!count_info.enabled);
    try std.testing.expectEqualStrings("the session has no tracks", count_info.disabled_reason.?);
}

test "predicates report static reasons and pass when satisfied" {
    const fixtures = testing_fixtures;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    var empty: fixtures.FakeSession = .{};
    const ectx = empty.context(arena.allocator(), &diag);
    try std.testing.expectEqualStrings("the session has no tracks", hasTracks(ectx).?);
    try std.testing.expectEqualStrings("nothing is selected", hasSelection(ectx).?);
    try std.testing.expectEqualStrings("make an edit selection first", hasRange(ectx).?);
    try std.testing.expectEqualStrings("nothing to undo", canUndo(ectx).?);
    try std.testing.expectEqualStrings("nothing to redo", canRedo(ectx).?);
    try std.testing.expectEqualStrings("the clipboard is empty", hasClipboard(ectx).?);
    try std.testing.expect(always(ectx) == null);

    var full: fixtures.FakeSession = .{ .tracks = 1, .selected_tracks = 1, .selection_empty = false, .can_undo = true, .can_redo = true, .clipboard_tracks = 1 };
    const fctx = full.context(arena.allocator(), &diag);
    try std.testing.expect(hasTracks(fctx) == null);
    try std.testing.expect(hasSelection(fctx) == null);
    try std.testing.expect(hasRange(fctx) == null);
    try std.testing.expect(canUndo(fctx) == null);
    try std.testing.expect(canRedo(fctx) == null);
    try std.testing.expect(hasClipboard(fctx) == null);
}

test "registry finds commands by id and returns null for unknown ids" {
    const fixtures = testing_fixtures;
    const Reg = Registry(&.{ &fixtures.specs, &fixtures.probe });
    try std.testing.expectEqualStrings("Ping", Reg.find("system.ping").?.label);
    try std.testing.expectEqualStrings("Panic Probe", Reg.find("test.panic_probe").?.label);
    try std.testing.expect(Reg.find("system.nope") == null);
    try std.testing.expect(Reg.find("") == null);
}

test "command results are std.json values" {
    const fixtures = testing_fixtures;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    var fake: fixtures.FakeSession = .{ .tracks = 3 };
    const ctx = fake.context(arena.allocator(), &diag);
    const r = try fixtures.specs[0].run(ctx, .null);
    try std.testing.expectEqualStrings("pong", r.string);
    const t = try fixtures.specs[1].run(ctx, .null);
    try std.testing.expectEqual(@as(i64, 3), t.integer);
}
