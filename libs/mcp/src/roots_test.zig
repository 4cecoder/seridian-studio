// Translated to Zig from soundcraft/crates/automation/tests/it/automation_roots.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Integration tests: file confinement holds through the MCP server. Every file a command reads
//! stays inside the read root, every file it writes inside the write root.
//!
//! The Rust suite drives the headless `Engine` with real commands. This library cannot import the
//! engine (layering), so `MockBackend` below answers the same command ids with small file
//! operations of its own. Each one asks `file_access.checkRead` or `checkWrite` first and touches
//! the disk only after the check passes, as the engine does. The checks, their messages and the
//! MCP path through `Server` are the real ones; the session and the audio are stand-ins.
//!
//! Every Rust test is ported with the same inputs and the same assertions. None needs engine
//! output the mock cannot produce, so none is skipped; the one `SkipZigTest` is the Unix-only
//! link test on Windows, which the Rust file gates with `#[cfg(unix)]`.
//!
//! Fixtures are `std.testing.tmpDir` folders. `file_access` keeps the roots thread-local, and every
//! call here runs on the test thread.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const Result = backend_mod.Result;
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const file_access = @import("file_access.zig");
const AutomationRoots = file_access.AutomationRoots;

/// A marker that must never come back from a file outside the read root.
const secret = "TOP-SECRET-MARKER-5f3a";
/// How much of a loaded file a mock result reports (its head): what a leaked read would show.
const head_bytes = 64;
const max_file_bytes = 1 << 20;

// --- JSON helpers (test-side copies of the ones in server.zig) ---

const Pair = struct { []const u8, Value };

fn object(arena: Allocator, pairs: []const Pair) Allocator.Error!Value {
    var map: ObjectMap = .empty;
    for (pairs) |pair| try map.put(arena, pair[0], pair[1]);
    return .{ .object = map };
}

fn array(arena: Allocator, items: []const Value) Allocator.Error!Value {
    var list: std.json.Array = .empty;
    try list.appendSlice(arena, items);
    return .{ .array = list };
}

fn str(text: []const u8) Value {
    return .{ .string = text };
}

fn int(i: i64) Value {
    return .{ .integer = i };
}

fn boolean(b: bool) Value {
    return .{ .bool = b };
}

fn emptyObject() Value {
    return .{ .object = .empty };
}

fn field(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn stringField(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(v: Value, key: []const u8) ?bool {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

/// The elements of a JSON array, empty when the value is absent or not an array.
fn itemsOf(v: ?Value) []const Value {
    const value = v orelse return &.{};
    return switch (value) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn fmt(arena: Allocator, comptime f: []const u8, args: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, f, args);
}

// --- file operations of the mock (all after a check) ---

/// The refusal for `path` from `check` (`file_access.checkRead` or `checkWrite`), copied into
/// `arena`. `null` when the path may be used. The roots' own copy is freed here.
fn refusal(comptime check: anytype, arena: Allocator, path: []const u8) !?[]const u8 {
    const message = (try check(path)) orelse return null;
    defer file_access.current().?.gpa.free(message);
    return try arena.dupe(u8, message);
}

fn readAt(io: std.Io, arena: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes));
}

fn writeAt(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn makeDirAt(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// The kind of the entry at `path` (links followed), `null` when there is none.
fn kindAt(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.kind;
}

fn isFileAt(io: std.Io, path: []const u8) bool {
    return kindAt(io, path) == .file;
}

fn existsAt(io: std.Io, path: []const u8) bool {
    return kindAt(io, path) != null;
}

// --- MockBackend ---

/// The operations the mock runs. Each Rust command id the tests use maps onto one of them.
const Op = enum { session_new, track_new, session_save, session_open, load_media, mix_bounce };

/// Command id to operation. `session.save`, `audio.import`, `mix.bounce`, `session.open` and
/// `media.load` are the mock's own names; the other ids are the Rust ones. `mix.bounce` is the
/// mock's generic writer of one file or folder (the Rust export commands all write one).
const op_table = std.StaticStringMap(Op).initComptime(.{
    .{ "session.new", .session_new },
    .{ "track.new", .track_new },
    .{ "session.save", .session_save },
    .{ "session.save_as", .session_save },
    .{ "session.save_copy", .session_save },
    .{ "session.save_template", .session_save },
    .{ "file.export_selected_tracks_as_session", .session_save },
    .{ "session.open", .session_open },
    .{ "audio.import", .load_media },
    .{ "file.import_audio", .load_media },
    .{ "media.load", .load_media },
    .{ "file.import_midi", .load_media },
    .{ "file.import_video", .load_media },
    .{ "file.import_clip_groups", .load_media },
    .{ "file.import_session_data", .load_media },
    .{ "track.load_preset", .load_media },
    .{ "mix.sampler_load", .load_media },
    .{ "mix.bounce", .mix_bounce },
    .{ "file.bounce_mix", .mix_bounce },
    .{ "file.bounce_stems", .mix_bounce },
    .{ "file.export_midi", .mix_bounce },
    .{ "file.export_session_text", .mix_bounce },
    .{ "file.export_clips", .mix_bounce },
    .{ "file.export_sibelius", .mix_bounce },
    .{ "file.send_to_sibelius", .mix_bounce },
    .{ "file.print_score", .mix_bounce },
    .{ "file.export_clip_groups", .mix_bounce },
    .{ "track.save_preset", .mix_bounce },
});

/// A stand-in for the headless engine: a session in memory, and file commands that check their
/// path against the roots before they touch the disk. `roots` is in force on each call, through
/// `file_access.confine`, the same way the engine's backend would hold it.
const MockBackend = struct {
    io: std.Io,
    roots: ?*const AutomationRoots = null,
    /// Where a command given no path writes. Outside the write root in the tests, so that the
    /// default output is refused like any other.
    default_dir: []const u8,
    /// Storage for the session's strings and lists, owned by the harness.
    state: Allocator,
    name: []const u8 = "Untitled",
    tracks: std.ArrayList([]const u8) = .empty,
    sources: std.ArrayList(Source) = .empty,

    const Source = struct { path: []const u8, loaded: bool };

    pub fn call(self: *MockBackend, arena: Allocator, method: []const u8, params: Value) Result {
        return file_access.confine(self.roots, callScoped, .{ self, arena, method, params });
    }

    pub fn hasUi(self: *MockBackend) bool {
        _ = self;
        return false;
    }

    pub fn describe(self: *MockBackend, arena: Allocator) Allocator.Error![]const u8 {
        _ = self;
        return arena.dupe(u8, "mock session for the root tests");
    }

    fn callScoped(self: *MockBackend, arena: Allocator, method: []const u8, params: Value) Result {
        return self.dispatch(arena, method, params) catch .{ .err = "out of memory" };
    }

    fn dispatch(self: *MockBackend, arena: Allocator, method: []const u8, params: Value) !Result {
        if (std.mem.eql(u8, method, "session.inspect")) return .{ .ok = try self.inspect(arena) };
        if (!std.mem.eql(u8, method, "engine.execute")) {
            return .{ .err = try fmt(arena, "unknown method `{s}`", .{method}) };
        }
        const command = stringField(params, "command") orelse return .{ .err = "`command` required" };
        return self.execute(arena, command, field(params, "params") orelse emptyObject());
    }

    fn execute(self: *MockBackend, arena: Allocator, command: []const u8, args: Value) !Result {
        const op = op_table.get(command) orelse
            return .{ .err = try fmt(arena, "unknown command `{s}`", .{command}) };
        return switch (op) {
            .session_new => self.newSession(arena, args),
            .track_new => self.newTrack(arena, args),
            .session_save => self.save(arena, args),
            .session_open => self.open(arena, args),
            .load_media => self.load(arena, args),
            .mix_bounce => self.bounce(arena, args),
        };
    }

    fn newSession(self: *MockBackend, arena: Allocator, args: Value) !Result {
        self.name = try self.state.dupe(u8, stringField(args, "name") orelse "Untitled");
        self.tracks.clearRetainingCapacity();
        self.sources.clearRetainingCapacity();
        return .{ .ok = try object(arena, &.{.{ "name", str(self.name) }}) };
    }

    fn newTrack(self: *MockBackend, arena: Allocator, args: Value) !Result {
        const name = stringField(args, "name") orelse return .{ .err = "`name` required" };
        try self.tracks.append(self.state, try self.state.dupe(u8, name));
        return .{ .ok = try object(arena, &.{.{ "track", str(name) }}) };
    }

    /// Saves the session to `path`: checked for writing first, so a refusal says nothing about
    /// whether the file exists. Over an existing file only with `replace`.
    fn save(self: *MockBackend, arena: Allocator, args: Value) !Result {
        const path = stringField(args, "path") orelse return .{ .err = "`path` required" };
        if (try refusal(file_access.checkWrite, arena, path)) |message| return .{ .err = message };
        if (existsAt(self.io, path) and !(boolField(args, "replace") orelse false)) {
            return .{ .err = try fmt(arena, "`{s}` already exists; pass replace: true to save over it", .{path}) };
        }
        const text = try std.json.Stringify.valueAlloc(arena, try self.inspect(arena), .{});
        writeAt(self.io, path, text) catch |err|
            return .{ .err = try fmt(arena, "cannot write `{s}`: {s}", .{ path, @errorName(err) }) };
        // A save puts its audio in `Audio Files/` beside the session.
        if (std.fs.path.dirname(path)) |dir| {
            const audio_dir = try std.fs.path.join(arena, &.{ dir, "Audio Files" });
            makeDirAt(self.io, audio_dir) catch |err|
                return .{ .err = try fmt(arena, "cannot create `{s}`: {s}", .{ audio_dir, @errorName(err) }) };
        }
        return .{ .ok = try object(arena, &.{.{ "saved", str(path) }}) };
    }

    /// Opens a session file: the file is checked for reading, then each media file it names. A
    /// medium that is refused or cannot be read is listed in `missing` and not loaded.
    fn open(self: *MockBackend, arena: Allocator, args: Value) !Result {
        const path = stringField(args, "path") orelse return .{ .err = "`path` required" };
        if (try refusal(file_access.checkRead, arena, path)) |message| return .{ .err = message };
        const text = readAt(self.io, arena, path) catch |err|
            return .{ .err = try fmt(arena, "cannot read `{s}`: {s}", .{ path, @errorName(err) }) };
        const doc = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch
            return .{ .err = try fmt(arena, "`{s}` is not a session file", .{path}) };

        self.name = try self.state.dupe(u8, stringField(doc, "name") orelse "Untitled");
        self.tracks.clearRetainingCapacity();
        self.sources.clearRetainingCapacity();
        for (itemsOf(field(doc, "tracks"))) |t| switch (t) {
            .string => |s| try self.tracks.append(self.state, try self.state.dupe(u8, s)),
            else => {},
        };

        var missing: std.ArrayList(Value) = .empty;
        for (itemsOf(field(doc, "sources"))) |src| {
            const media = switch (src) {
                .string => |s| s,
                else => continue,
            };
            if (try refusal(file_access.checkRead, arena, media)) |message| {
                try missing.append(arena, str(message));
                try self.addSource(media, false);
                continue;
            }
            _ = readAt(self.io, arena, media) catch |err| {
                try missing.append(arena, str(try fmt(arena, "cannot read `{s}`: {s}", .{ media, @errorName(err) })));
                try self.addSource(media, false);
                continue;
            };
            try self.addSource(media, true);
        }
        return .{ .ok = try object(arena, &.{
            .{ "opened", str(path) },
            .{ "name", str(self.name) },
            .{ "missing", try array(arena, missing.items) },
        }) };
    }

    /// Loads one or more media files (`path`, or `paths`): all are checked first, then read. Nothing
    /// is loaded when any is refused.
    fn load(self: *MockBackend, arena: Allocator, args: Value) !Result {
        const paths = (try pathsOf(arena, args)) orelse return .{ .err = "`path` or `paths` required" };
        for (paths) |p| {
            if (try refusal(file_access.checkRead, arena, p)) |message| return .{ .err = message };
        }
        var loaded: std.ArrayList(Value) = .empty;
        for (paths) |p| {
            const data = readAt(self.io, arena, p) catch |err|
                return .{ .err = try fmt(arena, "cannot read `{s}`: {s}", .{ p, @errorName(err) }) };
            try loaded.append(arena, try object(arena, &.{
                .{ "path", str(p) },
                .{ "bytes", int(@intCast(data.len)) },
                .{ "head", str(data[0..@min(data.len, head_bytes)]) },
            }));
        }
        for (paths) |p| try self.addSource(p, true);
        return .{ .ok = try object(arena, &.{.{ "loaded", try array(arena, loaded.items) }}) };
    }

    /// Writes one file (`path`), or makes one folder (`dir`). With neither, the default output in
    /// `default_dir`.
    fn bounce(self: *MockBackend, arena: Allocator, args: Value) !Result {
        if (stringField(args, "dir")) |dir| {
            if (try refusal(file_access.checkWrite, arena, dir)) |message| return .{ .err = message };
            makeDirAt(self.io, dir) catch |err|
                return .{ .err = try fmt(arena, "cannot create `{s}`: {s}", .{ dir, @errorName(err) }) };
            return .{ .ok = try object(arena, &.{.{ "dir", str(dir) }}) };
        }
        var path: []const u8 = undefined;
        if (stringField(args, "path")) |p| {
            path = p;
        } else {
            path = try std.fs.path.join(arena, &.{ self.default_dir, "untitled.out" });
        }
        if (try refusal(file_access.checkWrite, arena, path)) |message| return .{ .err = message };
        writeAt(self.io, path, "RIFF mock output") catch |err|
            return .{ .err = try fmt(arena, "cannot write `{s}`: {s}", .{ path, @errorName(err) }) };
        return .{ .ok = try object(arena, &.{.{ "written", str(path) }}) };
    }

    /// The session as the mock holds it: what `session.inspect` returns and `save` writes.
    fn inspect(self: *MockBackend, arena: Allocator) Allocator.Error!Value {
        var tracks: std.ArrayList(Value) = .empty;
        for (self.tracks.items) |t| try tracks.append(arena, str(t));
        var sources: std.ArrayList(Value) = .empty;
        for (self.sources.items) |s| {
            try sources.append(arena, try object(arena, &.{
                .{ "path", str(s.path) },
                .{ "loaded", boolean(s.loaded) },
            }));
        }
        return object(arena, &.{
            .{ "name", str(self.name) },
            .{ "tracks", try array(arena, tracks.items) },
            .{ "sources", try array(arena, sources.items) },
        });
    }

    fn addSource(self: *MockBackend, path: []const u8, loaded: bool) Allocator.Error!void {
        try self.sources.append(self.state, .{ .path = try self.state.dupe(u8, path), .loaded = loaded });
    }
};

/// The `path` string, or the `paths` strings; `null` when neither is given.
fn pathsOf(arena: Allocator, args: Value) !?[]const []const u8 {
    if (stringField(args, "path")) |p| return try arena.dupe([]const u8, &.{p});
    const list = field(args, "paths") orelse return null;
    if (list != .array) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        switch (item) {
            .string => |s| try out.append(arena, s),
            else => return null,
        }
    }
    return try out.toOwnedSlice(arena);
}

// --- fixtures and harness ---

/// A fresh temporary folder with `in` (read root), `out` (write root) and `outside`. `in` and
/// `outside` each hold the same real files: a session with audio, a WAV, a MIDI file, a track
/// preset and a clip group file. `outside` also holds files with `secret` under the names a command
/// might open. Paths are built in an arena freed with the fixture.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// The real path of the temporary folder.
    base: []const u8,
    read: []const u8,
    write: []const u8,
    outside: []const u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const base = try arena.allocator().dupe(u8, buf[0..n]);
        var f: Fixture = .{ .tmp = tmp, .arena = arena, .base = base, .read = undefined, .write = undefined, .outside = undefined };
        f.read = try f.path("in");
        f.write = try f.path("out");
        f.outside = try f.path("outside");
        for ([_][]const u8{ "in", "out", "outside" }) |d| try tmp.dir.createDirPath(testing.io, d);

        const a = f.arena.allocator();
        for ([_][]const u8{ "in", "outside" }) |dir| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "tone.wav" }), .data = "WAV tone" });
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "keys.mid" }), .data = "MThd keys" });
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "bass.json" }), .data = "{\"preset\":\"Bass\"}" });
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "group.scgrp" }), .data = "group" });
            const tone = try std.fs.path.join(a, &.{ base, dir, "tone.wav" });
            const session = try sessionText(a, &.{tone});
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "song.scraft" }), .data = session });
        }
        for ([_][]const u8{ "secret.wav", "secret.mid", "secret.scraft", "secret.json", "secret.scgrp", "secret.mp4" }) |name| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ "outside", name }), .data = secret });
        }
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// The absolute path of `rel` inside the fixture (arena-owned).
    fn path(self: *Fixture, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.base, rel });
    }
};

/// A session file's text naming `sources`.
fn sessionText(arena: Allocator, sources: []const []const u8) ![]u8 {
    var list: std.ArrayList(Value) = .empty;
    for (sources) |s| try list.append(arena, str(s));
    const doc = try object(arena, &.{
        .{ "name", str("Song") },
        .{ "tracks", try array(arena, &.{str("Kick")}) },
        .{ "sources", try array(arena, list.items) },
    });
    return std.json.Stringify.valueAlloc(arena, doc, .{});
}

/// What one call answered: whether it failed and the text of its result.
const Reply = struct { failed: bool, text: []const u8 };

/// A server over a `MockBackend` with the given roots (`null`: no roots of that kind). The
/// server points into the harness, so a harness must not move after `init`.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    state: std.heap.ArenaAllocator,
    roots: ?AutomationRoots,
    mock: MockBackend,
    srv: Server,

    fn init(self: *Harness, read: ?[]const u8, write: ?[]const u8, default_dir: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena.deinit();
        self.state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.state.deinit();
        var read_buf: [1][]const u8 = undefined;
        var write_buf: [1][]const u8 = undefined;
        self.roots = try AutomationRoots.new(testing.allocator, testing.io, rootList(read, &read_buf), rootList(write, &write_buf), null);
        self.mock = .{
            .io = testing.io,
            .roots = if (self.roots) |*r| r else null,
            .default_dir = default_dir,
            .state = self.state.allocator(),
        };
        self.srv = Server.init(Backend.from(&self.mock));
    }

    fn deinit(self: *Harness) void {
        if (self.roots) |*r| r.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    /// One `tools/call` through the MCP server.
    fn toolCall(self: *Harness, name: []const u8, arguments: Value) !Reply {
        const a = self.arena.allocator();
        const msg = try object(a, &.{
            .{ "jsonrpc", str("2.0") },
            .{ "id", int(1) },
            .{ "method", str("tools/call") },
            .{ "params", try object(a, &.{ .{ "name", str(name) }, .{ "arguments", arguments } }) },
        });
        const reply = (try self.srv.handle(a, msg)) orelse return error.NoReply;
        const result = field(reply, "result") orelse return error.NoResult;
        const is_error = boolField(result, "isError") orelse return error.NoErrorFlag;
        const content = itemsOf(field(result, "content"));
        if (content.len == 0) return error.NoContent;
        const text = stringField(content[0], "text") orelse return error.NoText;
        return .{ .failed = is_error, .text = text };
    }

    /// One `execute` call: a command by id with its params.
    fn execute(self: *Harness, command: []const u8, params: Value) !Reply {
        const a = self.arena.allocator();
        return self.toolCall("execute", try object(a, &.{ .{ "command", str(command) }, .{ "params", params } }));
    }

    /// The session as `inspect_session` returns it, pretty JSON text.
    fn inspect(self: *Harness) ![]const u8 {
        const a = self.arena.allocator();
        const reply = try self.toolCall("inspect_session", try object(a, &.{.{ "detail", str("full") }}));
        try testing.expect(!reply.failed);
        return reply.text;
    }
};

fn rootList(path: ?[]const u8, buf: *[1][]const u8) []const []const u8 {
    const p = path orelse return buf[0..0];
    buf[0] = p;
    return buf[0..1];
}

/// The text of a successful `execute`; fails the test otherwise.
fn expectOk(h: *Harness, command: []const u8, params: Value) ![]const u8 {
    const reply = try h.execute(command, params);
    if (reply.failed) {
        std.debug.print("{s} failed: {s}\n", .{ command, reply.text });
        return error.TestUnexpectedFailure;
    }
    return reply.text;
}

/// A refused `execute`: it failed, its text names `needle`, and it leaks none of the secret.
fn expectRefused(h: *Harness, command: []const u8, params: Value, needle: []const u8) !void {
    const reply = try h.execute(command, params);
    if (!reply.failed) {
        std.debug.print("{s} must be refused, got: {s}\n", .{ command, reply.text });
        return error.TestExpectedRefusal;
    }
    if (std.mem.indexOf(u8, reply.text, needle) == null) {
        std.debug.print("{s}: `{s}` lacks `{s}`\n", .{ command, reply.text, needle });
        return error.TestWrongRefusal;
    }
    if (std.mem.indexOf(u8, reply.text, secret) != null) {
        std.debug.print("{s} leaked file contents: {s}\n", .{ command, reply.text });
        return error.TestLeakedSecret;
    }
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("`{s}` lacks `{s}`\n", .{ text, needle });
        return error.TestMissingText;
    }
}

/// The path `rel` below `dir`, arena-owned.
fn under(arena: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, rel });
}

/// The entries under `dir`, sorted, one per line: kind and path. Links to folders are walked, as
/// the Rust `is_dir` follows them, so a write through a link shows up where it lands.
fn listing(arena: Allocator, dir: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try walkInto(arena, dir, &lines);
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    return std.mem.join(arena, "\n", lines.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn walkInto(arena: Allocator, dir_path: []const u8, lines: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        try lines.append(arena, try fmt(arena, "{s} {s}", .{ @tagName(entry.kind), child }));
        const is_dir = switch (entry.kind) {
            .directory => true,
            .sym_link => kindAt(testing.io, child) == .directory,
            else => false,
        };
        if (is_dir) try walkInto(arena, child, lines);
    }
}

/// A file the command reads, named by `file`. With `secret_names`, the file is `secret.<ext>`: the
/// file holding the marker under the name the command would open.
const Names = struct {
    arena: Allocator,
    dir: []const u8,
    secret_names: bool,

    fn path(self: Names, file: []const u8) ![]const u8 {
        if (!self.secret_names) return under(self.arena, self.dir, file);
        const name = try fmt(self.arena, "secret{s}", .{std.fs.path.extension(file)});
        return under(self.arena, self.dir, name);
    }
};

const Call = struct { command: []const u8, params: Value };

/// Every command that reads a user-named file, with params for a file in `dir`.
fn reads(arena: Allocator, dir: []const u8, secret_names: bool) ![]Call {
    const n: Names = .{ .arena = arena, .dir = dir, .secret_names = secret_names };
    var list: std.ArrayList(Call) = .empty;
    try list.append(arena, .{ .command = "session.open", .params = try object(arena, &.{.{ "path", str(try n.path("song.scraft")) }}) });
    try list.append(arena, .{ .command = "file.import_audio", .params = try object(arena, &.{.{ "path", str(try n.path("tone.wav")) }}) });
    try list.append(arena, .{ .command = "file.import_audio", .params = try object(arena, &.{.{ "paths", try array(arena, &.{str(try n.path("tone.wav"))}) }}) });
    try list.append(arena, .{ .command = "file.import_midi", .params = try object(arena, &.{.{ "path", str(try n.path("keys.mid")) }}) });
    try list.append(arena, .{ .command = "file.import_video", .params = try object(arena, &.{.{ "path", str(try n.path("movie.mp4")) }}) });
    try list.append(arena, .{ .command = "file.import_clip_groups", .params = try object(arena, &.{.{ "path", str(try n.path("group.scgrp")) }}) });
    try list.append(arena, .{ .command = "file.import_session_data", .params = try object(arena, &.{.{ "path", str(try n.path("song.scraft")) }}) });
    try list.append(arena, .{ .command = "track.load_preset", .params = try object(arena, &.{
        .{ "path", str(try n.path("bass.json")) },
        .{ "tracks", try array(arena, &.{str("Bass")}) },
    }) });
    return list.items;
}

/// Every command that writes a user-named file or folder, with params for `dir`.
fn writes(arena: Allocator, dir: []const u8) ![]Call {
    const clip = int(1);
    var list: std.ArrayList(Call) = .empty;
    try list.append(arena, .{ .command = "session.save", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "a.scraft")) }}) });
    try list.append(arena, .{ .command = "session.save_as", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "b.scraft")) }}) });
    try list.append(arena, .{ .command = "session.save_copy", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "c.scraft")) }}) });
    try list.append(arena, .{ .command = "session.save_template", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "d.scraft")) }}) });
    try list.append(arena, .{ .command = "file.bounce_mix", .params = try object(arena, &.{
        .{ "path", str(try under(arena, dir, "e.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }) });
    try list.append(arena, .{ .command = "file.bounce_stems", .params = try object(arena, &.{
        .{ "dir", str(try under(arena, dir, "stems")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }) });
    try list.append(arena, .{ .command = "file.export_midi", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "f.mid")) }}) });
    try list.append(arena, .{ .command = "file.export_session_text", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "g.txt")) }}) });
    try list.append(arena, .{ .command = "file.export_clips", .params = try object(arena, &.{
        .{ "dir", str(try under(arena, dir, "clips")) },
        .{ "clips", try array(arena, &.{clip}) },
    }) });
    try list.append(arena, .{ .command = "file.export_selected_tracks_as_session", .params = try object(arena, &.{
        .{ "path", str(try under(arena, dir, "h.scraft")) },
        .{ "tracks", try array(arena, &.{str("Kick")}) },
    }) });
    try list.append(arena, .{ .command = "file.export_sibelius", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "i.musicxml")) }}) });
    try list.append(arena, .{ .command = "file.send_to_sibelius", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "j.musicxml")) }}) });
    try list.append(arena, .{ .command = "file.print_score", .params = try object(arena, &.{.{ "path", str(try under(arena, dir, "k.svg")) }}) });
    try list.append(arena, .{ .command = "file.export_clip_groups", .params = try object(arena, &.{
        .{ "path", str(try under(arena, dir, "l.scgrp")) },
        .{ "clips", try array(arena, &.{clip}) },
    }) });
    try list.append(arena, .{ .command = "track.save_preset", .params = try object(arena, &.{
        .{ "path", str(try under(arena, dir, "m.json")) },
        .{ "tracks", try array(arena, &.{str("Kick")}) },
    }) });
    return list.items;
}

// --- tests ---

test "automation roots: reads outside the read root are refused and nothing reaches the result" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(f.read, f.write, f.outside);
    defer h.deinit();

    _ = try expectOk(&h, "session.new", try object(a, &.{.{ "name", str("Work") }}));
    _ = try expectOk(&h, "track.new", try object(a, &.{ .{ "name", str("Bass") }, .{ "count", int(1) } }));
    _ = try expectOk(&h, "track.new", try object(a, &.{ .{ "name", str("Pads") }, .{ "count", int(1) }, .{ "kind", str("instrument") } }));
    const before = try h.inspect();
    // The secret files hold the marker under the names the commands read, so a read would show.
    for (try reads(a, f.outside, true)) |c| try expectRefused(&h, c.command, c.params, "outside the read root");
    try expectRefused(&h, "mix.sampler_load", try object(a, &.{
        .{ "track", str("Pads") },
        .{ "path", str(try under(a, f.outside, "secret.wav")) },
    }), "outside the read root");
    // The open session is exactly as it was: nothing was imported or opened.
    try testing.expectEqualStrings(before, try h.inspect());

    // The same commands work on files inside the root.
    _ = try expectOk(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.read, "tone.wav")) }}));
    _ = try expectOk(&h, "file.import_midi", try object(a, &.{.{ "path", str(try under(a, f.read, "keys.mid")) }}));
    _ = try expectOk(&h, "file.import_clip_groups", try object(a, &.{.{ "path", str(try under(a, f.read, "group.scgrp")) }}));
    _ = try expectOk(&h, "file.import_session_data", try object(a, &.{
        .{ "path", str(try under(a, f.read, "song.scraft")) },
        .{ "tracks", try array(a, &.{str("Kick")}) },
    }));
    _ = try expectOk(&h, "track.load_preset", try object(a, &.{
        .{ "path", str(try under(a, f.read, "bass.json")) },
        .{ "tracks", try array(a, &.{str("Bass")}) },
    }));
    _ = try expectOk(&h, "mix.sampler_load", try object(a, &.{
        .{ "track", str("Pads") },
        .{ "path", str(try under(a, f.read, "tone.wav")) },
    }));
    // A missing movie inside the root is an ordinary error, not a refusal.
    const movie = try h.execute("file.import_video", try object(a, &.{.{ "path", str(try under(a, f.read, "movie.mp4")) }}));
    try testing.expect(movie.failed);
    try testing.expect(std.mem.indexOf(u8, movie.text, "read root") == null);
    _ = try expectOk(&h, "session.open", try object(a, &.{.{ "path", str(try under(a, f.read, "song.scraft")) }}));

    // The typed tools take the same path through the same checks.
    const reply = try h.toolCall("open_session", try object(a, &.{.{ "path", str(try under(a, f.outside, "secret.scraft")) }}));
    try testing.expect(reply.failed);
    try expectContains(reply.text, "outside the read root");
}

test "automation roots: every writing command is refused outside the write root and writes nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(f.read, f.write, f.outside);
    defer h.deinit();

    const before = try listing(a, f.base);
    const outside_before = try listing(a, f.outside);
    for (try writes(a, f.outside)) |c| try expectRefused(&h, c.command, c.params, "outside the write root");
    // Not even the temporary file a save goes through, nor a folder.
    try testing.expectEqualStrings(before, try listing(a, f.base));
    // With no path, the default output goes outside the write root, so it is refused too.
    try expectRefused(&h, "file.send_to_sibelius", emptyObject(), "outside the write root");
    try expectRefused(&h, "file.print_score", emptyObject(), "outside the write root");
    try testing.expectEqualStrings(before, try listing(a, f.base));

    // Inside the write root every one of them works.
    for (try writes(a, f.write)) |c| {
        const text = try expectOk(&h, c.command, c.params);
        try testing.expect(text.len > 0);
    }
    try testing.expect(isFileAt(testing.io, try under(a, f.write, "e.wav")));
    try testing.expect(kindAt(testing.io, try under(a, f.write, "stems")) == .directory);
    try testing.expect(isFileAt(testing.io, try under(a, f.write, "l.scgrp")));
    // A save puts the audio in `Audio Files/` beside it, inside the root as well.
    try testing.expect(kindAt(testing.io, try under(a, f.write, "Audio Files")) == .directory);
    try testing.expectEqualStrings(outside_before, try listing(a, f.outside));
}

test "automation roots: saving over an existing file outside does not reveal that it exists" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(f.read, f.write, f.outside);
    defer h.deinit();

    // Without `replace`, an existing target is reported as existing: not for a path outside the root.
    const target = try under(a, f.outside, "song.scraft");
    const original = try readAt(testing.io, a, target);
    const reply = try h.execute("session.save_as", try object(a, &.{.{ "path", str(target) }}));
    try testing.expect(reply.failed);
    try expectContains(reply.text, "outside the write root");
    try testing.expect(std.mem.indexOf(u8, reply.text, "already exists") == null);
    try testing.expectEqualStrings(original, try readAt(testing.io, a, target));
}

test "automation roots: the typed bounce and save tools are confined" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(f.read, f.write, f.outside);
    defer h.deinit();

    const outside_wav = try under(a, f.outside, "x.wav");
    const outside_session = try under(a, f.outside, "x.scraft");
    var reply = try h.toolCall("bounce_mix", try object(a, &.{
        .{ "path", str(outside_wav) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }));
    try testing.expect(reply.failed);
    try expectContains(reply.text, "outside the write root");

    reply = try h.toolCall("save_session", try object(a, &.{.{ "path", str(outside_session) }}));
    try testing.expect(reply.failed);
    try expectContains(reply.text, "outside the write root");

    try testing.expect(!existsAt(testing.io, outside_wav) and !existsAt(testing.io, outside_session));
    reply = try h.toolCall("bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, f.write, "x.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }));
    try testing.expect(!reply.failed);
}

test "automation roots: one root grants only its own access" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();

    // Read root only: reads work, nothing can be written anywhere.
    var h: Harness = undefined;
    try h.init(f.read, null, f.outside);
    defer h.deinit();
    _ = try expectOk(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.read, "tone.wav")) }}));
    const before = try listing(a, f.base);
    for (try writes(a, f.write)) |c| try expectRefused(&h, c.command, c.params, "write authority is absent");
    for (try writes(a, f.read)) |c| try expectRefused(&h, c.command, c.params, "write authority is absent");
    try testing.expectEqualStrings(before, try listing(a, f.base));

    // Write root only: writes work, nothing can be read anywhere.
    var w: Harness = undefined;
    try w.init(null, f.write, f.outside);
    defer w.deinit();
    for (try writes(a, f.write)) |c| _ = try expectOk(&w, c.command, c.params);
    for (try reads(a, f.read, false)) |c| try expectRefused(&w, c.command, c.params, "read authority is absent");
    try expectRefused(&w, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.write, "e.wav")) }}), "read authority is absent");
}

test "automation roots: the same folder for both roots is compared by whole names" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(f.read, f.read, f.outside);
    defer h.deinit();

    _ = try expectOk(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.read, "tone.wav")) }}));
    _ = try expectOk(&h, "file.bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, f.read, "again.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }));
    // `in2` shares the prefix of `in` and is a different folder.
    try f.tmp.dir.createDirPath(testing.io, "in2");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "in2/tone.wav", .data = "WAV tone" });
    const sibling = try under(a, f.base, "in2");
    try expectRefused(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, sibling, "tone.wav")) }}), "outside the read root");
    try expectRefused(&h, "file.bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, sibling, "x.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }), "outside the write root");
    // `..` out of the root is outside it.
    const up = try fmt(a, "{s}/../outside/tone.wav", .{f.read});
    try expectRefused(&h, "file.import_audio", try object(a, &.{.{ "path", str(up) }}), "outside the read root");
}

test "automation roots: links out of the roots are refused" {
    // The Rust test is `#[cfg(unix)]`: Windows needs elevation to create the links.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const io = testing.io;

    try std.Io.Dir.symLinkAbsolute(io, try under(a, f.outside, "tone.wav"), try under(a, f.read, "leak.wav"), .{ .is_directory = false });
    try std.Io.Dir.symLinkAbsolute(io, f.outside, try under(a, f.write, "away"), .{ .is_directory = true });
    try std.Io.Dir.symLinkAbsolute(io, try under(a, f.outside, "not-yet.wav"), try under(a, f.write, "dangling.wav"), .{ .is_directory = false });

    var h: Harness = undefined;
    try h.init(f.read, f.write, f.outside);
    defer h.deinit();
    try expectRefused(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.read, "leak.wav")) }}), "outside the read root");
    const before = try listing(a, f.outside);
    try expectRefused(&h, "file.bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, f.write, "away/x.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }), "outside the write root");
    try expectRefused(&h, "file.bounce_stems", try object(a, &.{
        .{ "dir", str(try under(a, f.write, "away/stems")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }), "outside the write root");
    try expectRefused(&h, "session.save_as", try object(a, &.{.{ "path", str(try under(a, f.write, "away/x.scraft")) }}), "outside the write root");
    try expectRefused(&h, "file.bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, f.write, "dangling.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }), "a link that leads nowhere");
    try testing.expectEqualStrings(before, try listing(a, f.outside));
    try testing.expect(!existsAt(io, try under(a, f.outside, "not-yet.wav")));

    // A link to a folder inside the root stays inside it.
    try std.Io.Dir.symLinkAbsolute(io, try under(a, f.read, "."), try under(a, f.base, "in-alias"), .{ .is_directory = true });
    var via_alias: Harness = undefined;
    try via_alias.init(try under(a, f.base, "in-alias"), null, f.outside);
    defer via_alias.deinit();
    _ = try expectOk(&via_alias, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.read, "tone.wav")) }}));
}

test "automation roots: media a session names outside the read root is not loaded" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const session = try under(a, f.read, "song.scraft");

    // Point every source of the session at a file outside the read root.
    var doc = try std.json.parseFromSliceLeaky(Value, a, try readAt(testing.io, a, session), .{});
    try testing.expect(itemsOf(field(doc, "sources")).len > 0);
    const outside_wav = try under(a, f.outside, "tone.wav");
    try doc.object.put(a, "sources", try array(a, &.{str(outside_wav)}));
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = session, .data = try std.json.Stringify.valueAlloc(a, doc, .{}) });

    var h: Harness = undefined;
    try h.init(f.read, null, f.outside);
    defer h.deinit();
    const opened_text = try expectOk(&h, "session.open", try object(a, &.{.{ "path", str(session) }}));
    const opened = try std.json.parseFromSliceLeaky(Value, a, opened_text, .{});
    const missing = itemsOf(field(opened, "missing"));
    try testing.expect(missing.len > 0);
    for (missing) |m| try expectContains(m.string, "outside the read root");
    const inspected = try std.json.parseFromSliceLeaky(Value, a, try h.inspect(), .{});
    for (itemsOf(field(inspected, "sources"))) |src| {
        try testing.expect(boolField(src, "loaded") == false);
    }

    // The same session opened without roots does load the file it names.
    var free: Harness = undefined;
    try free.init(null, null, f.outside);
    defer free.deinit();
    _ = try expectOk(&free, "session.open", try object(a, &.{.{ "path", str(session) }}));
    const free_inspected = try std.json.parseFromSliceLeaky(Value, a, try free.inspect(), .{});
    const free_sources = itemsOf(field(free_inspected, "sources"));
    try testing.expect(free_sources.len > 0);
    for (free_sources) |src| {
        try testing.expect(boolField(src, "loaded") == true);
    }
}

test "automation roots: without roots nothing is confined" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    var h: Harness = undefined;
    try h.init(null, null, f.outside);
    defer h.deinit();

    _ = try expectOk(&h, "file.import_audio", try object(a, &.{.{ "path", str(try under(a, f.outside, "tone.wav")) }}));
    _ = try expectOk(&h, "file.bounce_mix", try object(a, &.{
        .{ "path", str(try under(a, f.outside, "free.wav")) },
        .{ "start", int(0) },
        .{ "end", int(4800) },
    }));
    try testing.expect(isFileAt(testing.io, try under(a, f.outside, "free.wav")));
}
