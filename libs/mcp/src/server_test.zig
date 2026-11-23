// Translated to Zig from soundcraft/crates/automation/src/mcp.rs (inline tests), soundcraft/crates/automation/tests/it/agent_tasks.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Tests for server.zig: the Rust protocol tests (mcp.rs and agent_tasks.rs), run against a
//! `MockBackend` instead of the Rust `Headless` engine. Headless wraps the in-process engine, which
//! this library cannot import (layering), so the protocol is checked here against a small mock
//! session with the same command ids the agent flow uses. The mock is a stand-in for the protocol,
//! not for the audio: `file.bounce_mix` records a placeholder WAV header and a fixed peak, and
//! saves and opens keep the session in memory.
//!
//! Tests added for the Zig port (not in the Rust suite) are marked "Seridian:" in their names.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const Result = backend_mod.Result;
const server_mod = @import("server.zig");
const Server = server_mod.Server;

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

fn flt(f: f64) Value {
    return .{ .float = f };
}

fn int(i: anytype) Value {
    return .{ .integer = @intCast(i) };
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

fn intField(v: Value, key: []const u8) ?i64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        else => null,
    };
}

fn floatField(v: Value, key: []const u8) ?f64 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .float => |x| x,
        .integer => |i| @floatFromInt(i),
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

/// Test accessor: the field must exist (a missing one fails the test by panicking, like the Rust
/// `unwrap` in agent_tasks.rs).
fn fieldOf(v: Value, key: []const u8) Value {
    return v.object.get(key).?;
}

/// A JSON number as f64. `std.json.Stringify` writes whole floats like `-6.0` as `-6`, so a value
/// that went through text comes back as an integer.
fn asF64(v: Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => std.math.nan(f64),
    };
}

fn arr(v: Value, key: []const u8) []const Value {
    return fieldOf(v, key).array.items;
}

// --- MockBackend ---

const max_name = 48;
const max_tracks = 16;
const max_inserts = 8;
const max_sends = 4;
const max_lanes = 4;
const max_markers = 8;

/// A short, fixed-capacity name. Session values hold names inline so a snapshot is a plain copy.
const Name = struct {
    buf: [max_name]u8 = @splat(0),
    len: usize = 0,

    fn set(self: *Name, text: []const u8) void {
        const n = @min(text.len, max_name);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    fn get(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

const Insert = struct {
    used: bool = false,
    plugin: Name = .{},
    bypass: bool = false,
};

const Send = struct {
    used: bool = false,
    bus: Name = .{},
    level_db: f64 = 0,
};

const Track = struct {
    name: Name = .{},
    input: Name = .{},
    volume_db: f64 = 0,
    pan: f64 = 0,
    selected: bool = false,
    clips: usize = 0,
    inserts: [max_inserts]Insert = @splat(.{}),
    sends: [max_sends]Send = @splat(.{}),
    lanes: [max_lanes]Name = @splat(.{}),
    lane_count: usize = 0,
};

const Session = struct {
    name: Name = .{},
    tracks: [max_tracks]Track = @splat(.{}),
    track_count: usize = 0,
    markers: [max_markers]Name = @splat(.{}),
    marker_count: usize = 0,
    tempo_bpm: f64 = 120,
    selection_active: bool = false,
};

/// The command ids the mock answers through `engine.execute`.
const Command = enum {
    @"session.new",
    @"session.format_time",
    @"session.save",
    @"session.open",
    @"track.new",
    @"track.input",
    @"mix.volume",
    @"mix.pan",
    @"mix.insert",
    @"mix.insert_bypass",
    @"mix.send",
    @"edit.select",
    @"edit.cut",
    @"edit.undo",
    @"markers.add",
    @"event.tempo",
    @"automation.write_range",
    @"file.bounce_mix",
};

const demo_tracks = [_][]const u8{ "Kick", "Snare", "Hats", "Bass", "Keys", "Lead", "Pad", "Strings", "Vocal" };

const Error = error{ Refused, OutOfMemory };

/// A stand-in backend. `call` answers the command ids of `Command`, keeps an undo history of
/// session snapshots, and refuses `ui.*` methods unless `has_ui` is set (then `ui.screenshot`
/// answers a fixed PNG). Methods and commands it does not know are refused with a message, the
/// way the Rust backend reports them.
const Mock = struct {
    gpa: Allocator,
    has_ui: bool = false,
    session: Session = .{},
    history: std.ArrayList(Session) = .empty,
    saved: std.StringHashMapUnmanaged(Session) = .empty,
    files: std.StringHashMapUnmanaged([]u8) = .empty,
    /// How many `engine.execute` calls reached a command (the Rust tests check the journal).
    executed: usize = 0,
    refusal: []const u8 = "",

    fn init(gpa: Allocator) Mock {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Mock) void {
        self.history.deinit(self.gpa);
        var saved_it = self.saved.iterator();
        while (saved_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.saved.deinit(self.gpa);
        var file_it = self.files.iterator();
        while (file_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit(self.gpa);
    }

    /// The `Backend` view of this mock. The mock must outlive the returned value.
    fn backend(self: *Mock) Backend {
        return .from(self);
    }

    pub fn call(self: *Mock, arena: Allocator, method: []const u8, params: Value) Result {
        const value = self.run(arena, method, params) catch |err| switch (err) {
            error.Refused => return .{ .err = self.refusal },
            error.OutOfMemory => return .{ .err = "out of memory" },
        };
        return .{ .ok = value };
    }

    pub fn hasUi(self: *Mock) bool {
        return self.has_ui;
    }

    pub fn describe(self: *Mock, arena: Allocator) Allocator.Error![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "mock backend", .{});
    }

    fn refuse(self: *Mock, arena: Allocator, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.refusal = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
        return error.Refused;
    }

    fn run(self: *Mock, arena: Allocator, method: []const u8, params: Value) Error!Value {
        if (std.mem.eql(u8, method, "engine.execute")) {
            const command = stringField(params, "command") orelse return self.refuse(arena, "`command` required", .{});
            const p = field(params, "params") orelse emptyObject();
            self.executed += 1;
            return self.execute(arena, command, p);
        }
        if (std.mem.eql(u8, method, "engine.commands")) return commandList(arena);
        if (std.mem.eql(u8, method, "session.inspect")) return self.inspect(arena);
        if (std.mem.eql(u8, method, "ui.screenshot") and self.has_ui) {
            return object(arena, &.{.{ "png_base64", str("iVBORw0KGgo=") }});
        }
        if (std.mem.startsWith(u8, method, "ui.")) return self.refuse(arena, "`{s}` needs the desktop app", .{method});
        return self.refuse(arena, "unknown method `{s}`", .{method});
    }

    fn execute(self: *Mock, arena: Allocator, command: []const u8, p: Value) Error!Value {
        const cmd = std.meta.stringToEnum(Command, command) orelse
            return self.refuse(arena, "unknown command `{s}`", .{command});
        return switch (cmd) {
            .@"session.new" => self.sessionNew(arena, p),
            .@"session.format_time" => self.formatTime(arena, p),
            .@"session.save" => self.sessionSave(arena, p),
            .@"session.open" => self.sessionOpen(arena, p),
            .@"track.new" => self.trackNew(arena, p),
            .@"track.input" => self.trackInput(arena, p),
            .@"mix.volume" => self.mixVolume(arena, p),
            .@"mix.pan" => self.mixPan(arena, p),
            .@"mix.insert" => self.mixInsert(arena, p),
            .@"mix.insert_bypass" => self.mixInsertBypass(arena, p),
            .@"mix.send" => self.mixSend(arena, p),
            .@"edit.select" => self.editSelect(arena, p),
            .@"edit.cut" => self.editCut(arena),
            .@"edit.undo" => self.editUndo(arena),
            .@"markers.add" => self.markersAdd(arena, p),
            .@"event.tempo" => self.eventTempo(arena, p),
            .@"automation.write_range" => self.automationWriteRange(arena, p),
            .@"file.bounce_mix" => self.bounceMix(arena, p),
        };
    }

    fn commandList(arena: Allocator) Error!Value {
        const names = @typeInfo(Command).@"enum".field_names;
        var items: [names.len]Value = undefined;
        inline for (names, 0..) |name, i| items[i] = str(name);
        return object(arena, &.{.{ "commands", try array(arena, &items) }});
    }

    fn checkpoint(self: *Mock) Allocator.Error!void {
        try self.history.append(self.gpa, self.session);
    }

    fn appendTrack(self: *Mock, name: []const u8, clips: usize) void {
        var track: Track = .{ .clips = clips };
        track.name.set(name);
        self.session.tracks[self.session.track_count] = track;
        self.session.track_count += 1;
    }

    fn trackIndex(self: *Mock, arena: Allocator, name: []const u8) Error!usize {
        for (self.session.tracks[0..self.session.track_count], 0..) |track, i| {
            if (std.mem.eql(u8, track.name.get(), name)) return i;
        }
        return self.refuse(arena, "no track `{s}`", .{name});
    }

    fn trackParam(self: *Mock, arena: Allocator, p: Value) Error!usize {
        const name = stringField(p, "track") orelse return self.refuse(arena, "`track` required", .{});
        return self.trackIndex(arena, name);
    }

    fn sessionNew(self: *Mock, arena: Allocator, p: Value) Error!Value {
        self.session = .{};
        self.session.name.set(stringField(p, "name") orelse "Untitled");
        self.history.clearRetainingCapacity();
        if (stringField(p, "template")) |template| {
            if (std.mem.eql(u8, template, "demo")) {
                for (demo_tracks) |name| self.appendTrack(name, 2);
            }
        }
        return object(arena, &.{.{ "name", str(self.session.name.get()) }});
    }

    fn formatTime(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const at = intField(p, "at") orelse return self.refuse(arena, "`at` must be an integer", .{});
        const text = try std.fmt.allocPrint(arena, "{d}", .{at});
        return object(arena, &.{.{ "text", str(text) }});
    }

    fn sessionSave(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const path = stringField(p, "path") orelse return self.refuse(arena, "`path` required", .{});
        const replace = boolField(p, "replace") orelse false;
        if (self.saved.contains(path) and !replace) {
            return self.refuse(arena, "`{s}` already exists; pass replace: true to save over it", .{path});
        }
        if (self.saved.getPtr(path)) |slot| {
            slot.* = self.session;
        } else {
            const owned = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(owned);
            try self.saved.put(self.gpa, owned, self.session);
        }
        return object(arena, &.{.{ "path", str(path) }});
    }

    fn sessionOpen(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const path = stringField(p, "path") orelse return self.refuse(arena, "`path` required", .{});
        const opened = self.saved.get(path) orelse return self.refuse(arena, "no session file at `{s}`", .{path});
        self.session = opened;
        self.history.clearRetainingCapacity();
        return object(arena, &.{.{ "name", str(self.session.name.get()) }});
    }

    fn trackNew(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const count = intField(p, "count") orelse 1;
        const room: i64 = @intCast(max_tracks - self.session.track_count);
        if (count < 1 or count > room) {
            return self.refuse(arena, "`count` must be 1 to {d} tracks", .{room});
        }
        const base = stringField(p, "name") orelse "Track";
        try self.checkpoint();
        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            const name = if (count == 1) base else try std.fmt.allocPrint(arena, "{s} {d}", .{ base, i + 1 });
            self.appendTrack(name, 0);
        }
        return object(arena, &.{.{ "created", int(count) }});
    }

    fn trackInput(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const input = stringField(p, "input") orelse return self.refuse(arena, "`input` required", .{});
        try self.checkpoint();
        self.session.tracks[idx].input.set(input);
        return emptyObject();
    }

    fn mixVolume(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const db = floatField(p, "db") orelse return self.refuse(arena, "`db` required", .{});
        try self.checkpoint();
        self.session.tracks[idx].volume_db = db;
        return emptyObject();
    }

    fn mixPan(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const pan = floatField(p, "pan") orelse return self.refuse(arena, "`pan` required", .{});
        try self.checkpoint();
        self.session.tracks[idx].pan = pan;
        return emptyObject();
    }

    fn mixInsert(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const plugin = stringField(p, "plugin") orelse return self.refuse(arena, "`plugin` required", .{});
        const inserts = &self.session.tracks[idx].inserts;
        const slot = if (field(p, "slot")) |v|
            (slotOf(v, max_inserts) orelse return self.refuse(arena, "`slot` must be an index or a letter", .{}))
        else
            (firstFreeInsert(inserts) orelse return self.refuse(arena, "no free insert slot", .{}));
        if (inserts[slot].used) return self.refuse(arena, "slot {d} is taken", .{slot});
        try self.checkpoint();
        inserts[slot] = .{ .used = true };
        inserts[slot].plugin.set(plugin);
        return object(arena, &.{.{ "slot", int(slot) }});
    }

    fn mixInsertBypass(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const slot_value = field(p, "slot") orelse return self.refuse(arena, "`slot` required", .{});
        const slot = slotOf(slot_value, max_inserts) orelse return self.refuse(arena, "`slot` must be an index or a letter", .{});
        const insert = &self.session.tracks[idx].inserts[slot];
        if (!insert.used) return self.refuse(arena, "no plugin in slot {d}", .{slot});
        try self.checkpoint();
        insert.bypass = boolField(p, "bypass") orelse true;
        return emptyObject();
    }

    fn mixSend(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const bus = stringField(p, "bus") orelse return self.refuse(arena, "`bus` required", .{});
        const level = floatField(p, "level_db") orelse 0;
        const sends = &self.session.tracks[idx].sends;
        const slot = if (field(p, "slot")) |v|
            (slotOf(v, max_sends) orelse return self.refuse(arena, "`slot` must be an index", .{}))
        else
            (firstFreeSend(sends) orelse return self.refuse(arena, "no free send slot", .{}));
        try self.checkpoint();
        sends[slot] = .{ .used = true, .level_db = level };
        sends[slot].bus.set(bus);
        return object(arena, &.{.{ "slot", int(slot) }});
    }

    fn editSelect(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const names = switch (field(p, "tracks") orelse .null) {
            .array => |list| list.items,
            else => return self.refuse(arena, "`tracks` must be an array", .{}),
        };
        for (names) |n| {
            const name = switch (n) {
                .string => |s| s,
                else => return self.refuse(arena, "track names must be strings", .{}),
            };
            _ = try self.trackIndex(arena, name);
        }
        for (self.session.tracks[0..self.session.track_count]) |*track| track.selected = false;
        for (names) |n| {
            const idx = try self.trackIndex(arena, n.string);
            self.session.tracks[idx].selected = true;
        }
        self.session.selection_active = true;
        return emptyObject();
    }

    fn editCut(self: *Mock, arena: Allocator) Error!Value {
        if (!self.session.selection_active) return self.refuse(arena, "nothing is selected", .{});
        try self.checkpoint();
        for (self.session.tracks[0..self.session.track_count]) |*track| {
            if (track.selected and track.clips > 0) track.clips -= 1;
        }
        return emptyObject();
    }

    fn editUndo(self: *Mock, arena: Allocator) Error!Value {
        const previous = self.history.pop() orelse return self.refuse(arena, "nothing to undo", .{});
        self.session = previous;
        return emptyObject();
    }

    fn markersAdd(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const name = stringField(p, "name") orelse return self.refuse(arena, "`name` required", .{});
        if (self.session.marker_count == max_markers) return self.refuse(arena, "too many markers", .{});
        try self.checkpoint();
        self.session.markers[self.session.marker_count].set(name);
        self.session.marker_count += 1;
        return emptyObject();
    }

    fn eventTempo(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const bpm = floatField(p, "bpm") orelse return self.refuse(arena, "`bpm` required", .{});
        try self.checkpoint();
        self.session.tempo_bpm = bpm;
        return emptyObject();
    }

    fn automationWriteRange(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const idx = try self.trackParam(arena, p);
        const param = stringField(p, "param") orelse return self.refuse(arena, "`param` required", .{});
        const track = &self.session.tracks[idx];
        for (track.lanes[0..track.lane_count]) |lane| {
            if (std.mem.eql(u8, lane.get(), param)) return emptyObject();
        }
        if (track.lane_count == max_lanes) return self.refuse(arena, "too many automation lanes", .{});
        try self.checkpoint();
        track.lanes[track.lane_count].set(param);
        track.lane_count += 1;
        return emptyObject();
    }

    /// Records a placeholder file (a RIFF header and zeros) and a fixed peak. No audio is rendered.
    fn bounceMix(self: *Mock, arena: Allocator, p: Value) Error!Value {
        const path = stringField(p, "path") orelse return self.refuse(arena, "`path` required", .{});
        const bytes = try self.gpa.alloc(u8, 48);
        errdefer self.gpa.free(bytes);
        @memset(bytes, 0);
        @memcpy(bytes[0..4], "RIFF");
        if (self.files.getPtr(path)) |slot| {
            self.gpa.free(slot.*);
            slot.* = bytes;
        } else {
            const owned = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(owned);
            try self.files.put(self.gpa, owned, bytes);
        }
        return object(arena, &.{ .{ "peak_db", flt(-6.0) }, .{ "lufs", flt(-14.0) } });
    }

    fn inspect(self: *Mock, arena: Allocator) Error!Value {
        var tracks: std.ArrayList(Value) = .empty;
        var sources: std.ArrayList(Value) = .empty;
        for (self.session.tracks[0..self.session.track_count]) |*track| {
            try tracks.append(arena, try trackValue(arena, track));
            if (track.clips > 0) {
                try sources.append(arena, try object(arena, &.{ .{ "name", str(track.name.get()) }, .{ "loaded", boolean(true) } }));
            }
        }
        var markers: std.ArrayList(Value) = .empty;
        for (self.session.markers[0..self.session.marker_count]) |*marker| {
            try markers.append(arena, try object(arena, &.{.{ "name", str(marker.get()) }}));
        }
        var tempo = [_]Value{try object(arena, &.{.{ "bpm", flt(self.session.tempo_bpm) }})};
        return object(arena, &.{
            .{ "name", str(self.session.name.get()) },
            .{ "tracks", try array(arena, tracks.items) },
            .{ "markers", try array(arena, markers.items) },
            .{ "tempo", try array(arena, &tempo) },
            .{ "sources", try array(arena, sources.items) },
        });
    }
};

/// The JSON of one track. Strings point into the session, so they stay valid while it does.
fn trackValue(arena: Allocator, track: *const Track) Error!Value {
    var inserts: std.ArrayList(Value) = .empty;
    for (&track.inserts, 0..) |*insert, slot| {
        if (!insert.used) continue;
        try inserts.append(arena, try object(arena, &.{
            .{ "slot", int(slot) },
            .{ "plugin", str(insert.plugin.get()) },
            .{ "bypass", boolean(insert.bypass) },
        }));
    }
    var sends: std.ArrayList(Value) = .empty;
    for (&track.sends, 0..) |*send, slot| {
        if (!send.used) continue;
        try sends.append(arena, try object(arena, &.{
            .{ "slot", int(slot) },
            .{ "bus", str(send.bus.get()) },
            .{ "level_db", flt(send.level_db) },
        }));
    }
    var clips: std.ArrayList(Value) = .empty;
    for (0..track.clips) |id| try clips.append(arena, try object(arena, &.{.{ "id", int(id) }}));
    var lanes: std.ArrayList(Value) = .empty;
    for (track.lanes[0..track.lane_count]) |*lane| {
        try lanes.append(arena, try object(arena, &.{.{ "param", str(lane.get()) }}));
    }
    var pan = [_]Value{ flt(track.pan), flt(track.pan) };
    return object(arena, &.{
        .{ "name", str(track.name.get()) },
        .{ "input", if (track.input.len > 0) str(track.input.get()) else .null },
        .{ "volume_db", flt(track.volume_db) },
        .{ "pan", try array(arena, &pan) },
        .{ "selected", boolean(track.selected) },
        .{ "inserts", try array(arena, inserts.items) },
        .{ "sends", try array(arena, sends.items) },
        .{ "clips", try array(arena, clips.items) },
        .{ "automation", try array(arena, lanes.items) },
    });
}

/// A slot given as an index (`2`) or a letter (`"c"`), below `limit`.
fn slotOf(v: Value, limit: usize) ?usize {
    return switch (v) {
        .integer => |i| if (i >= 0 and i < limit) @intCast(i) else null,
        .string => |s| if (s.len == 1 and s[0] >= 'a' and s[0] < 'a' + limit) s[0] - 'a' else null,
        else => null,
    };
}

fn firstFreeInsert(inserts: *const [max_inserts]Insert) ?usize {
    for (inserts, 0..) |insert, i| {
        if (!insert.used) return i;
    }
    return null;
}

fn firstFreeSend(sends: *const [max_sends]Send) ?usize {
    for (sends, 0..) |send, i| {
        if (!send.used) return i;
    }
    return null;
}

// --- Harness: drives a Server through JSON-RPC, like a client ---

const Harness = struct {
    arena: Allocator,
    srv: Server,

    /// One request; the reply, or `null` for a notification.
    fn send(self: *Harness, id: i64, method: []const u8, params: []const u8) !?Value {
        const text = try std.fmt.allocPrint(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        const msg = try std.json.parseFromSliceLeaky(Value, self.arena, text, .{});
        return self.srv.handle(self.arena, msg);
    }

    fn rpc(self: *Harness, id: i64, method: []const u8, params: []const u8) !Value {
        return (try self.send(id, method, params)) orelse error.NoReply;
    }

    /// A `tools/call` reply, without checking it.
    fn callRaw(self: *Harness, name: []const u8, args: []const u8) !Value {
        const params = try std.fmt.allocPrint(self.arena, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, args });
        return self.rpc(1, "tools/call", params);
    }

    /// A tool call that must succeed; returns its payload (the JSON text it carries, parsed when it
    /// is JSON, else the text itself).
    fn tool(self: *Harness, name: []const u8, args: []const u8) !Value {
        const reply = try self.callRaw(name, args);
        const res = fieldOf(reply, "result");
        try testing.expect(!fieldOf(res, "isError").bool);
        return payload(self.arena, res);
    }

    fn session(self: *Harness) !Value {
        return self.tool("inspect_session", "{\"detail\":\"full\"}");
    }
};

fn payload(arena: Allocator, res: Value) !Value {
    const text = fieldOf(fieldOf(res, "content").array.items[0], "text").string;
    return std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch .{ .string = text };
}

fn isError(reply: Value) bool {
    return fieldOf(fieldOf(reply, "result"), "isError").bool;
}

fn textOf(reply: Value) []const u8 {
    return fieldOf(fieldOf(fieldOf(reply, "result"), "content").array.items[0], "text").string;
}

fn trackOf(sess: Value, name: []const u8) !Value {
    for (arr(sess, "tracks")) |track| {
        if (std.mem.eql(u8, stringField(track, "name") orelse "", name)) return track;
    }
    return error.NoSuchTrack;
}

fn clipCount(track: Value) usize {
    return arr(track, "clips").len;
}

fn countInserts(track: Value, plugin: []const u8) usize {
    var n: usize = 0;
    for (arr(track, "inserts")) |insert| {
        if (std.mem.eql(u8, stringField(insert, "plugin") orelse "", plugin)) n += 1;
    }
    return n;
}

fn insertAt(track: Value, slot: i64) !Value {
    for (arr(track, "inserts")) |insert| {
        if (intField(insert, "slot") == slot) return insert;
    }
    return error.NoSuchSlot;
}

fn sendAt(track: Value, slot: i64) !Value {
    for (arr(track, "sends")) |send| {
        if (intField(send, "slot") == slot) return send;
    }
    return error.NoSuchSlot;
}

fn hasNamed(items: []const Value, key: []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, stringField(item, key) orelse "", name)) return true;
    }
    return false;
}

/// A `Server` over a fresh mock, and the arena and harness the test uses.
fn setup(arena: Allocator, mock: *Mock) Harness {
    return .{ .arena = arena, .srv = Server.init(mock.backend()) };
}

/// Serves `input` through `serve` and returns the reply bytes (owned by the caller).
fn serveText(gpa: Allocator, srv: *Server, input: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try srv.serve(gpa, &reader, &out.writer);
    return out.toOwnedSlice();
}

// --- The Rust protocol tests ---

test "invalid requests get an invalid request error" {
    // mcp.rs: invalid_requests_get_an_invalid_request_error
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var srv = Server.init(mock.backend());
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "[]", "42", "[1]", "\"x\"" }) |input| {
        const text = try serveText(testing.allocator, &srv, input);
        defer testing.allocator.free(text);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
        const v = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
        const e = switch (v) {
            .array => |items| items.items[0],
            else => v,
        };
        const err = fieldOf(e, "error");
        try testing.expectEqual(@as(i64, -32600), intField(err, "code").?);
        try testing.expect(std.meta.activeTag(fieldOf(e, "id")) == .null);
    }
}

test "notifications still get no reply" {
    // mcp.rs: notifications_still_get_no_reply
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var srv = Server.init(mock.backend());

    const text = try serveText(testing.allocator, &srv, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);

    const ping = try serveText(testing.allocator, &srv, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    defer testing.allocator.free(ping);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena_state.allocator(), std.mem.trim(u8, ping, "\n"), .{});
    try testing.expectEqual(@as(i64, 1), intField(v, "id").?);
}

// --- agent_tasks.rs: protocol-level tests ---

test "handshake and tool list" {
    // agent_tasks.rs: handshake_and_tool_list (serverInfo name renamed to seridian)
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const init_reply = try h.rpc(1, "initialize", "{\"protocolVersion\":\"2025-06-18\"}");
    try testing.expectEqualStrings("seridian", stringField(fieldOf(fieldOf(init_reply, "result"), "serverInfo"), "name").?);

    const list = try h.rpc(2, "tools/list", "{}");
    const tools = arr(fieldOf(list, "result"), "tools");
    try testing.expect(tools.len >= 10);
    var batch_tool: ?Value = null;
    for (tools) |tool_value| {
        if (std.mem.eql(u8, stringField(tool_value, "name") orelse "", "batch")) batch_tool = tool_value;
    }
    const batch_schema = fieldOf(fieldOf(batch_tool.?, "inputSchema"), "properties");
    try testing.expectEqual(@as(i64, 1000), intField(fieldOf(batch_schema, "calls"), "maxItems").?);

    const note = try h.srv.handle(h.arena, try std.json.parseFromSliceLeaky(Value, h.arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", .{}));
    try testing.expect(note == null);

    const unknown = try h.rpc(3, "nope", "{}");
    try testing.expectEqual(@as(i64, -32601), intField(fieldOf(unknown, "error"), "code").?);
}

test "agent builds and mixes a session" {
    // agent_tasks.rs: agent_builds_and_mixes_a_session, as the same sequence of tool calls
    // against the mock backend.
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    // 1. New demo session.
    _ = try h.tool("new_session", "{\"name\":\"Agent Mix\",\"template\":\"demo\"}");
    var sess = try h.session();
    try testing.expectEqualStrings("Agent Mix", fieldOf(sess, "name").string);
    try testing.expect(arr(sess, "tracks").len >= 9);

    // 2. Turn the kick down and pan the hats.
    _ = try h.tool("execute", "{\"command\":\"mix.volume\",\"params\":{\"track\":\"Kick\",\"db\":-8.5}}");
    _ = try h.tool("execute", "{\"command\":\"mix.pan\",\"params\":{\"track\":\"Hats\",\"pan\":-0.5}}");
    sess = try h.session();
    try testing.expectEqual(@as(f64, -8.5), asF64(fieldOf(try trackOf(sess, "Kick"), "volume_db")));
    try testing.expectEqual(@as(f64, -0.5), asF64(arr(try trackOf(sess, "Hats"), "pan")[0]));

    // 3. Put an EQ on the bass with a low-shelf boost, then bypass it.
    const inserted = try h.tool("execute", "{\"command\":\"mix.insert\",\"params\":{\"track\":\"Bass\",\"slot\":\"c\",\"plugin\":\"eq_7band\"}}");
    try testing.expectEqual(@as(i64, 2), intField(inserted, "slot").?);
    sess = try h.session();
    try testing.expectEqual(@as(usize, 1), countInserts(try trackOf(sess, "Bass"), "eq_7band"));
    _ = try h.tool("execute", "{\"command\":\"mix.insert_bypass\",\"params\":{\"track\":\"Bass\",\"slot\":2}}");
    sess = try h.session();
    try testing.expect(fieldOf(try insertAt(try trackOf(sess, "Bass"), 2), "bypass").bool);

    // 4. New stereo aux fed from a send.
    _ = try h.tool("batch",
        \\{"calls": [
        \\  {"command": "track.new", "params": {"kind": "aux", "format": "stereo", "name": "Delay"}},
        \\  {"command": "track.input", "params": {"track": "Delay", "input": "DelayBus"}},
        \\  {"command": "mix.insert", "params": {"track": "Delay", "plugin": "mod_delay"}},
        \\  {"command": "mix.send", "params": {"track": "Lead", "slot": 1, "bus": "DelayBus", "level_db": -6}}
        \\]}
    );
    sess = try h.session();
    const lead = try trackOf(sess, "Lead");
    try testing.expectEqual(@as(f64, -6.0), asF64(fieldOf(try sendAt(lead, 1), "level_db")));

    // 5. Edit: select bars 6-9 on Snare, cut, undo, verify the clip count is restored.
    const before = clipCount(try trackOf(try h.session(), "Snare"));
    _ = try h.tool("execute", "{\"command\":\"edit.select\",\"params\":{\"tracks\":[\"Snare\"],\"start\":\"bars_beats:6|1|000\",\"end\":\"bars_beats:9|1|000\"}}");
    _ = try h.tool("execute", "{\"command\":\"edit.cut\",\"params\":{}}");
    const mid = clipCount(try trackOf(try h.session(), "Snare"));
    try testing.expect(mid != before);
    _ = try h.tool("execute", "{\"command\":\"edit.undo\",\"params\":{}}");
    try testing.expectEqual(before, clipCount(try trackOf(try h.session(), "Snare")));

    // 6. Markers and tempo.
    _ = try h.tool("execute", "{\"command\":\"markers.add\",\"params\":{\"name\":\"Bridge\",\"at\":{\"seconds\":30.0}}}");
    _ = try h.tool("execute", "{\"command\":\"event.tempo\",\"params\":{\"bpm\":110.0}}");
    sess = try h.session();
    try testing.expect(hasNamed(arr(sess, "markers"), "name", "Bridge"));
    try testing.expectEqual(@as(f64, 110.0), asF64(fieldOf(arr(sess, "tempo")[0], "bpm")));

    // 7. Volume automation ride on the pad.
    _ = try h.tool("execute", "{\"command\":\"automation.write_range\",\"params\":{\"track\":\"Pad\",\"param\":\"volume\",\"start\":{\"seconds\":10.0},\"end\":{\"seconds\":12.0},\"value\":-20.0}}");
    const pad = try trackOf(try h.session(), "Pad");
    try testing.expect(hasNamed(arr(pad, "automation"), "param", "volume"));

    // 8. Bounce 4 seconds and check the file is a WAV with a sane peak.
    const bounce_path = "/mock/agent-mix/bounce.wav";
    const bounced = try h.tool("bounce_mix", "{\"path\":\"/mock/agent-mix/bounce.wav\",\"start\":{\"seconds\":10.0},\"end\":{\"seconds\":14.0},\"bit_depth\":\"24\"}");
    try testing.expect(asF64(fieldOf(bounced, "peak_db")) > -40.0);
    const bytes = mock.files.get(bounce_path) orelse return error.NoFile;
    try testing.expectEqualStrings("RIFF", bytes[0..4]);

    // 9. Save, reopen, and the mix survives.
    _ = try h.tool("save_session", "{\"path\":\"/mock/agent-mix/Agent Mix/Agent Mix.seridian\"}");
    _ = try h.tool("new_session", "{}");
    _ = try h.tool("open_session", "{\"path\":\"/mock/agent-mix/Agent Mix/Agent Mix.seridian\"}");
    sess = try h.session();
    try testing.expectEqual(@as(f64, -8.5), asF64(fieldOf(try trackOf(sess, "Kick"), "volume_db")));
    try testing.expect(arr(sess, "sources").len >= 5);
}

test "errors are reported, not panics" {
    // agent_tasks.rs: errors_are_reported_not_panics
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const r = try h.rpc(1, "tools/call", "{\"name\":\"execute\",\"arguments\":{\"command\":\"mix.volume\",\"params\":{\"track\":\"Nope\",\"db\":0}}}");
    try testing.expect(isError(r));
    const r2 = try h.rpc(2, "tools/call", "{\"name\":\"screenshot\",\"arguments\":{}}");
    try testing.expect(isError(r2));
}

test "batch keep_going still sets isError on partial failure" {
    // agent_tasks.rs: batch_keep_going_still_sets_is_error_on_partial_failure
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const r = try h.rpc(1, "tools/call",
        \\{"name": "batch", "arguments": {"keep_going": true, "calls": [
        \\  {"command": "track.new", "params": {"count": 1, "name": "Kept"}},
        \\  {"command": "mix.volume", "params": {"track": "Nope", "db": -6}},
        \\  {"command": "track.new", "params": {"count": 1, "name": "After"}}
        \\]}}
    );
    try testing.expect(isError(r));
    const results = try std.json.parseFromSliceLeaky(Value, h.arena, textOf(r), .{});
    const items = results.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expect(fieldOf(items[0], "ok").bool);
    try testing.expect(!fieldOf(items[1], "ok").bool);
    try testing.expect(fieldOf(items[2], "ok").bool);
    const sess = try h.session();
    try testing.expect(hasNamed(arr(sess, "tracks"), "name", "Kept"));
    try testing.expect(hasNamed(arr(sess, "tracks"), "name", "After"));
}

test "batch rejects non-array calls" {
    // agent_tasks.rs: batch_rejects_non_array_calls
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const r = try h.callRaw("batch", "{\"calls\":{\"command\":\"track.new\"}}");
    try testing.expect(isError(r));
    try testing.expect(std.mem.indexOf(u8, textOf(r), "`calls` must be an array") != null);
    try testing.expectEqual(@as(usize, 0), arr(try h.session(), "tracks").len);
}

test "batch rejects oversize calls before any mutation" {
    // agent_tasks.rs: batch_rejects_oversize_calls_before_any_mutation
    for ([_]bool{ false, true }) |keep_going| {
        var mock = Mock.init(testing.allocator);
        defer mock.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var h = setup(arena, &mock);

        const before = mock.session;
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(arena, "{\"command\":\"track.new\",\"params\":{\"name\":\"Must not be created\"}}");
        for (1..1001) |_| try parts.append(arena, "{\"command\":\"engine.history\"}");
        const calls = try std.mem.join(arena, ",", parts.items);
        const args = try std.fmt.allocPrint(arena, "{{\"keep_going\":{s},\"calls\":[{s}]}}", .{ if (keep_going) "true" else "false", calls });

        const r = try h.callRaw("batch", args);
        try testing.expectEqual(before, mock.session);
        try testing.expectEqual(@as(usize, 0), mock.executed);
        try testing.expectEqual(@as(usize, 0), mock.history.items.len);
        try testing.expect(isError(r));
        try testing.expect(std.mem.indexOf(u8, textOf(r), "1000") != null);
    }
}

test "batch accepts empty and limit-sized calls in order" {
    // agent_tasks.rs: batch_accepts_empty_and_limit_sized_calls_in_order
    for ([_]usize{ 0, 1000 }) |count| {
        var mock = Mock.init(testing.allocator);
        defer mock.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var h = setup(arena, &mock);

        var parts: std.ArrayList([]const u8) = .empty;
        for (0..count) |at| {
            try parts.append(arena, try std.fmt.allocPrint(arena, "{{\"command\":\"session.format_time\",\"params\":{{\"at\":{d},\"format\":\"samples\"}}}}", .{at}));
        }
        const calls = try std.mem.join(arena, ",", parts.items);
        const results = try h.tool("batch", try std.fmt.allocPrint(arena, "{{\"calls\":[{s}]}}", .{calls}));
        const items = results.array.items;
        try testing.expectEqual(count, items.len);
        for (items, 0..) |item, at| {
            try testing.expect(fieldOf(item, "ok").bool);
            const expected = try std.fmt.allocPrint(arena, "{d}", .{at});
            try testing.expectEqualStrings(expected, stringField(fieldOf(item, "result"), "text").?);
        }
    }
}

// --- Seridian: tests added for the port ---

test "Seridian: screenshot returns image content when the backend has a UI" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    mock.has_ui = true;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const r = try h.callRaw("screenshot", "{}");
    try testing.expect(!isError(r));
    const item = fieldOf(fieldOf(r, "result"), "content").array.items[0];
    try testing.expectEqualStrings("image", stringField(item, "type").?);
    try testing.expectEqualStrings("image/png", stringField(item, "mimeType").?);
    try testing.expectEqualStrings("iVBORw0KGgo=", stringField(item, "data").?);
}

test "Seridian: parity is dropped and is an unknown tool" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const list = try h.rpc(1, "tools/list", "{}");
    for (arr(fieldOf(list, "result"), "tools")) |tool_value| {
        try testing.expect(!std.mem.eql(u8, stringField(tool_value, "name") orelse "", "parity"));
    }
    const r = try h.callRaw("parity", "{}");
    try testing.expect(isError(r));
    try testing.expect(std.mem.indexOf(u8, textOf(r), "unknown tool") != null);
}

test "Seridian: tool table names are dispatchable and carry no SoundCraft branding" {
    for (server_mod.tool_defs) |def| {
        try testing.expect(std.meta.stringToEnum(server_mod.ToolName, def.name) != null);
        try testing.expect(std.mem.indexOf(u8, def.description, "SoundCraft") == null);
        try testing.expect(std.mem.indexOf(u8, def.description, "soundcraft") == null);
        try testing.expect(std.mem.indexOf(u8, def.description, ".scraft") == null);
    }
    try testing.expectEqual(@as(usize, 16), server_mod.tool_defs.len);
}

test "Seridian: initialize keeps a supported version and falls back to the default" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);

    const old = try h.rpc(1, "initialize", "{\"protocolVersion\":\"2024-11-05\"}");
    try testing.expectEqualStrings("2024-11-05", stringField(fieldOf(old, "result"), "protocolVersion").?);
    const unknown = try h.rpc(2, "initialize", "{\"protocolVersion\":\"1999-01-01\"}");
    try testing.expectEqualStrings("2025-06-18", stringField(fieldOf(unknown, "result"), "protocolVersion").?);
    const instructions = stringField(fieldOf(unknown, "result"), "instructions").?;
    try testing.expect(std.mem.indexOf(u8, instructions, "Seridian") != null);
    try testing.expect(std.mem.indexOf(u8, instructions, "SoundCraft") == null);
    try testing.expect(std.mem.indexOf(u8, instructions, "Backend: mock backend.") != null);
}

test "Seridian: resources/read returns the session as JSON text" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var h = setup(arena_state.allocator(), &mock);
    _ = try h.tool("new_session", "{\"name\":\"Read Me\",\"template\":\"demo\"}");

    const r = try h.rpc(1, "resources/read", "{\"uri\":\"seridian://session\"}");
    const contents = fieldOf(fieldOf(r, "result"), "contents").array.items[0];
    const session = try std.json.parseFromSliceLeaky(Value, h.arena, stringField(contents, "text").?, .{});
    try testing.expectEqualStrings("Read Me", stringField(session, "name").?);
}

test "Seridian: a serve batch array is answered as an array and notifications are dropped" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var srv = Server.init(mock.backend());

    const text = try serveText(testing.allocator, &srv,
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"}]
        \\
    );
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena_state.allocator(), std.mem.trim(u8, text, "\n"), .{});
    try testing.expectEqual(@as(usize, 1), v.array.items.len);
    try testing.expectEqual(@as(i64, 1), intField(v.array.items[0], "id").?);
}

test "Seridian: blank lines are skipped and unparseable input gets a parse error" {
    var mock = Mock.init(testing.allocator);
    defer mock.deinit();
    var srv = Server.init(mock.backend());

    const text = try serveText(testing.allocator, &srv, "\n   \n{not json}\n");
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena_state.allocator(), std.mem.trim(u8, text, "\n"), .{});
    try testing.expectEqual(@as(i64, -32700), intField(fieldOf(v, "error"), "code").?);
    try testing.expect(std.meta.activeTag(fieldOf(v, "id")) == .null);
}
