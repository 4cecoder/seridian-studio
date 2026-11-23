// Translated to Zig from soundcraft/crates/midi/src/smf.rs, soundcraft/crates/midi/tests/it/smf.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Standard MIDI File reading and writing (from the public SMF 1.0 specification).
//!
//! Control thread only: parsing and writing allocate through the caller's allocator and
//! are never run from the audio thread. The reader treats its input as hostile: every
//! length is checked, variable-length quantities are bounded, and event and track counts
//! are capped (`MAX_EVENTS`, `MAX_TRACKS`). Truncated or malformed files return an error;
//! they never panic.
//!
//! Error payloads from the Rust version (byte offsets, reasons) are not carried: the error
//! set in midi.zig is payload-free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const midi = @import("midi.zig");
const MidiError = midi.MidiError;
const Note = midi.Note;
const CtrlEvent = midi.CtrlEvent;
const CtrlKind = midi.CtrlKind;
const Sequence = midi.Sequence;
const PPQ = midi.PPQ;

/// Maximum number of events (across all tracks) `readSmf` will parse.
pub const MAX_EVENTS: usize = 5_000_000;
/// Maximum number of track chunks `readSmf` will accept.
pub const MAX_TRACKS: usize = 4096;

/// Release velocity used when a note ends with a note-on of velocity 0 (per the spec, a
/// note-on with velocity 0 is a note-off with velocity 64).
const DEFAULT_RELEASE: u8 = 64;

/// Errors from reading or writing a Standard MIDI File: the MIDI error set, plus allocation.
pub const SmfError = MidiError || Allocator.Error;

// ---------------------------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------------------------

/// One track of a Standard MIDI File. `name` is owned by the allocator that built the Smf
/// (empty and unowned when it is a literal ""), and is freed by `deinit`.
pub const SmfTrack = struct {
    /// Name from the first Sequence/Track Name meta event (empty if none).
    name: []const u8 = "",
    sequence: Sequence = .{},

    pub fn deinit(self: *SmfTrack, gpa: Allocator) void {
        gpa.free(self.name);
        self.sequence.deinit(gpa);
    }
};

/// Tempo change: `bpm` beats per minute from `tick` on.
pub const Tempo = struct { tick: i64, bpm: f64 };
/// Time signature change, e.g. 6/8 is `numerator = 6, denominator = 8`.
pub const Meter = struct { tick: i64, numerator: u8, denominator: u8 };
/// Marker meta event. `text` is owned by the Smf.
pub const Marker = struct { tick: i64, text: []const u8 };
/// Key signature: `sharps` is sharps (+) or flats (-), -7..=7; `minor` selects minor mode.
pub const KeySig = struct { tick: i64, sharps: i8, minor: bool };

/// A Standard MIDI File in model terms. All ticks are at `PPQ` (960) per quarter note.
pub const Smf = struct {
    /// Format of the source file (0, 1 or 2). `writeSmf` always writes format 1.
    format: u16 = 0,
    tracks: std.ArrayList(SmfTrack) = .empty,
    tempos: std.ArrayList(Tempo) = .empty,
    meters: std.ArrayList(Meter) = .empty,
    markers: std.ArrayList(Marker) = .empty,
    key_sigs: std.ArrayList(KeySig) = .empty,

    pub fn deinit(self: *Smf, gpa: Allocator) void {
        for (self.tracks.items) |*t| t.deinit(gpa);
        self.tracks.deinit(gpa);
        for (self.markers.items) |m| gpa.free(m.text);
        self.markers.deinit(gpa);
        self.tempos.deinit(gpa);
        self.meters.deinit(gpa);
        self.key_sigs.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------------------------

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn isEmpty(self: *const Cursor) bool {
        return self.pos >= self.data.len;
    }

    /// Takes the next `n` bytes; `Truncated` when fewer remain (no partial read).
    fn take(self: *Cursor, n: usize) MidiError![]const u8 {
        if (n > self.data.len - self.pos) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn peek(self: *const Cursor) MidiError!u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        return self.data[self.pos];
    }

    fn readU8(self: *Cursor) MidiError!u8 {
        const b = try self.take(1);
        return b[0];
    }

    fn readU16(self: *Cursor) MidiError!u16 {
        const b = try self.take(2);
        return std.mem.readInt(u16, b[0..2], .big);
    }

    fn readU32(self: *Cursor) MidiError!u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    /// Variable-length quantity: at most 4 bytes (28 bits) per the spec.
    fn readVlq(self: *Cursor) MidiError!u32 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const b = try self.readU8();
            v = (v << 7) | (b & 0x7F);
            if ((b & 0x80) == 0) return v;
        }
        return error.VlqTooLong;
    }
};

/// Converts file ticks to model ticks: `model = file * num / den` (rounded).
const TickConv = struct {
    num: i128,
    den: i128,

    fn fromDivision(division: u16) MidiError!TickConv {
        if ((division & 0x8000) == 0) {
            if (division == 0) return error.Invalid;
            return .{ .num = PPQ, .den = division };
        }
        // SMPTE: high byte is negative frames/sec (two's complement), low byte ticks/frame.
        // Approximated at 120 bpm: one quarter note = 0.5 s, so model = file / ticks_per_sec * 2 * PPQ.
        const hi: u8 = @truncate(division >> 8);
        const lo: u8 = @truncate(division);
        const fps: i128 = -@as(i128, @as(i8, @bitCast(hi)));
        const tpf: i128 = lo;
        if (!(fps == 24 or fps == 25 or fps == 29 or fps == 30) or tpf == 0) return error.Invalid;
        const two_ppq: i128 = 2 * @as(i128, PPQ);
        if (fps == 29) {
            // 29.97 drop-frame: ticks/sec = 30000/1001 * tpf
            return .{ .num = two_ppq * 1001, .den = 30000 * tpf };
        }
        return .{ .num = two_ppq, .den = fps * tpf };
    }

    fn convert(self: TickConv, file_tick: u64) i64 {
        const scaled = @as(i128, file_tick) * self.num + @divTrunc(self.den, 2);
        const v = @divTrunc(scaled, self.den);
        return std.math.cast(i64, v) orelse std.math.maxInt(i64);
    }
};

/// Decodes bytes as UTF-8, replacing each invalid maximal subpart with U+FFFD: the same
/// result as Rust's `String::from_utf8_lossy`. Returns an owned copy.
fn lossyUtf8(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const b0 = bytes[i];
        if (b0 < 0x80) {
            try out.append(gpa, b0);
            i += 1;
            continue;
        }
        var need: usize = 0;
        var lo: u8 = 0x80;
        var hi: u8 = 0xBF;
        switch (b0) {
            0xC2...0xDF => need = 2,
            0xE0 => {
                need = 3;
                lo = 0xA0;
            },
            0xE1...0xEC, 0xEE...0xEF => need = 3,
            0xED => {
                need = 3;
                hi = 0x9F;
            },
            0xF0 => {
                need = 4;
                lo = 0x90;
            },
            0xF1...0xF3 => need = 4,
            0xF4 => {
                need = 4;
                hi = 0x8F;
            },
            else => {},
        }
        // `k` counts the bytes of this sequence that are valid so far (the lead byte included).
        var k: usize = 1;
        if (need != 0) {
            while (k < need) : (k += 1) {
                if (i + k >= bytes.len) break;
                const c = bytes[i + k];
                const l: u8 = if (k == 1) lo else 0x80;
                const h: u8 = if (k == 1) hi else 0xBF;
                if (c < l or c > h) break;
            }
        }
        if (need != 0 and k == need) {
            try out.appendSlice(gpa, bytes[i .. i + need]);
            i += need;
        } else {
            try out.appendSlice(gpa, "\xEF\xBF\xBD");
            i += k;
        }
    }
    return out.toOwnedSlice(gpa);
}

const OpenNote = struct { start: i64, velocity: u8 };

/// FIFO of open note-ons for one (channel, pitch). `head` indexes the oldest entry; the
/// storage is reset when the queue drains, so it does not grow without bound on balanced input.
const OpenQueue = struct {
    items: std.ArrayList(OpenNote) = .empty,
    head: usize = 0,

    fn push(self: *OpenQueue, gpa: Allocator, n: OpenNote) Allocator.Error!void {
        try self.items.append(gpa, n);
    }

    fn popFront(self: *OpenQueue) ?OpenNote {
        if (self.head >= self.items.items.len) return null;
        const v = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        return v;
    }

    fn deinit(self: *OpenQueue, gpa: Allocator) void {
        self.items.deinit(gpa);
    }
};

/// Closes the oldest open note-on for (channel, pitch) at `tick`. An unmatched note-off is ignored.
fn closeNote(open: []OpenQueue, notes: *std.ArrayList(Note), gpa: Allocator, channel: u8, pitch: u8, tick: i64, release: u8) Allocator.Error!void {
    const key = @as(usize, channel & 0x0F) * 128 + @as(usize, pitch & 0x7F);
    const on = open[key].popFront() orelse return;
    try notes.append(gpa, .{
        .pitch = pitch,
        .velocity = on.velocity,
        .release_velocity = release,
        .channel = channel,
        .start = on.start,
        .length = @max(tick -| on.start, 1),
    });
}

/// Stable sort by `tick` (equal ticks keep file order), as Rust's `sort_by_key`.
fn sortByTick(comptime T: type, items: []T) void {
    const Less = struct {
        fn lessThan(_: void, x: T, y: T) bool {
            return x.tick < y.tick;
        }
    };
    std.mem.sort(T, items, {}, Less.lessThan);
}

/// Parses one MTrk body. Global meta events (tempo, meter, key, marker) go into `smf`.
fn readTrack(gpa: Allocator, smf: *Smf, body: []const u8, conv: TickConv, budget: *usize) SmfError!SmfTrack {
    var cur: Cursor = .{ .data = body };
    var name: ?[]u8 = null;
    errdefer if (name) |n| gpa.free(n);
    var seq: Sequence = .{};
    errdefer seq.deinit(gpa);

    const open = try gpa.alloc(OpenQueue, 16 * 128);
    defer gpa.free(open);
    for (open) |*q| q.* = .{};
    defer for (open) |*q| q.deinit(gpa);

    var file_tick: u64 = 0;
    var tick: i64 = 0;
    var running: ?u8 = null;

    loop: while (!cur.isEmpty()) {
        if (budget.* == 0) return error.TooManyEvents;
        budget.* -= 1;

        const delta = try cur.readVlq();
        file_tick = file_tick +| @as(u64, delta);
        tick = conv.convert(file_tick);

        const first = try cur.peek();
        var status: u8 = undefined;
        if ((first & 0x80) != 0) {
            cur.pos += 1;
            status = first;
        } else {
            status = running orelse return error.Invalid; // data byte without running status
        }

        switch (status) {
            0xFF => {
                running = null;
                const meta_kind = try cur.readU8();
                const len = try cur.readVlq();
                const data = try cur.take(@intCast(len));
                switch (meta_kind) {
                    0x2F => break :loop, // End of Track
                    0x03 => {
                        if (name == null) name = try lossyUtf8(gpa, data);
                    },
                    0x06 => {
                        const text = try lossyUtf8(gpa, data);
                        errdefer gpa.free(text);
                        try smf.markers.append(gpa, .{ .tick = tick, .text = text });
                    },
                    0x51 => {
                        if (data.len == 3) {
                            const us: u32 = (@as(u32, data[0]) << 16) | (@as(u32, data[1]) << 8) | @as(u32, data[2]);
                            if (us > 0) {
                                try smf.tempos.append(gpa, .{ .tick = tick, .bpm = 60_000_000.0 / @as(f64, @floatFromInt(us)) });
                            }
                        }
                    },
                    0x58 => {
                        if (data.len >= 2 and data[0] > 0 and data[1] <= 7) {
                            const den: u8 = @as(u8, 1) << @as(u3, @intCast(data[1]));
                            try smf.meters.append(gpa, .{ .tick = tick, .numerator = data[0], .denominator = den });
                        }
                    },
                    0x59 => {
                        if (data.len >= 2) {
                            const sf: i8 = @bitCast(data[0]);
                            if (sf >= -7 and sf <= 7) {
                                try smf.key_sigs.append(gpa, .{ .tick = tick, .sharps = sf, .minor = data[1] == 1 });
                            }
                        }
                    },
                    else => {},
                }
            },
            0xF0, 0xF7 => {
                // System exclusive: skipped, length-checked.
                running = null;
                const len = try cur.readVlq();
                _ = try cur.take(@intCast(len));
            },
            0x80...0xEF => {
                running = status;
                const channel: u8 = status & 0x0F;
                const kind = status & 0xF0;
                const d1 = try cur.readU8();
                if ((d1 & 0x80) != 0) return error.Invalid;
                const needs_two = !(kind == 0xC0 or kind == 0xD0);
                var d2: u8 = 0;
                if (needs_two) {
                    d2 = try cur.readU8();
                    if ((d2 & 0x80) != 0) return error.Invalid;
                }
                switch (kind) {
                    0x80 => try closeNote(open, &seq.notes, gpa, channel, d1, tick, d2),
                    0x90 => {
                        if (d2 == 0) {
                            // Note-on with velocity 0 is a note-off.
                            try closeNote(open, &seq.notes, gpa, channel, d1, tick, DEFAULT_RELEASE);
                        } else {
                            const key = @as(usize, channel) * 128 + @as(usize, d1);
                            try open[key].push(gpa, .{ .start = tick, .velocity = d2 });
                        }
                    },
                    0xA0 => try seq.ctrls.append(gpa, .{ .tick = tick, .channel = channel, .kind = .{ .poly_pressure = d1 }, .value = d2 }),
                    0xB0 => try seq.ctrls.append(gpa, .{ .tick = tick, .channel = channel, .kind = .{ .cc = d1 }, .value = d2 }),
                    0xC0 => try seq.ctrls.append(gpa, .{ .tick = tick, .channel = channel, .kind = .program, .value = d1 }),
                    0xD0 => try seq.ctrls.append(gpa, .{ .tick = tick, .channel = channel, .kind = .channel_pressure, .value = d1 }),
                    else => {
                        // 0xE0 pitch bend: LSB then MSB, centred on 8192.
                        const v: i32 = ((@as(i32, d2) << 7) | @as(i32, d1)) - 8192;
                        try seq.ctrls.append(gpa, .{ .tick = tick, .channel = channel, .kind = .pitch_bend, .value = v });
                    },
                }
            },
            else => return error.Invalid, // system real-time/common status inside a track
        }
    }

    // Close hanging notes at the end of the track.
    for (open, 0..) |*stack, key| {
        const channel: u8 = @intCast(key / 128);
        const pitch: u8 = @intCast(key % 128);
        while (stack.popFront()) |on| {
            try seq.notes.append(gpa, .{
                .pitch = pitch,
                .velocity = on.velocity,
                .release_velocity = DEFAULT_RELEASE,
                .channel = channel,
                .start = on.start,
                .length = @max(tick -| on.start, 1),
            });
        }
    }
    seq.sort();

    var track_name: []const u8 = "";
    if (name) |n| track_name = n;
    name = null; // ownership passes to the track
    return .{ .name = track_name, .sequence = seq };
}

/// Parses a Standard MIDI File. Returns an owned `Smf`; call `deinit`.
pub fn readSmf(gpa: Allocator, bytes: []const u8) SmfError!Smf {
    var cur: Cursor = .{ .data = bytes };
    const magic = cur.take(4) catch return error.NotSmf;
    if (!std.mem.eql(u8, magic, "MThd")) return error.NotSmf;
    const header_len = try cur.readU32();
    if (header_len < 6) return error.Invalid;
    const hdr = cur.take(@intCast(header_len)) catch return error.BadChunkLength;
    var hc: Cursor = .{ .data = hdr };
    const format = try hc.readU16();
    _ = try hc.readU16(); // ntrks: informational only, chunks are read regardless
    const division = try hc.readU16();
    if (format > 2) return error.Unsupported;
    const conv = try TickConv.fromDivision(division);

    var smf: Smf = .{ .format = format };
    errdefer smf.deinit(gpa);
    var budget: usize = MAX_EVENTS;

    while (!cur.isEmpty()) {
        const id = try cur.take(4);
        const len = try cur.readU32();
        const remaining = bytes.len -| cur.pos;
        if (@as(u64, len) > remaining) return error.BadChunkLength;
        const body = try cur.take(@intCast(len));
        if (!std.mem.eql(u8, id, "MTrk")) continue; // unknown chunk types are ignored
        if (smf.tracks.items.len >= MAX_TRACKS) return error.TooManyTracks;
        var track = try readTrack(gpa, &smf, body, conv, &budget);
        errdefer track.deinit(gpa);
        try smf.tracks.append(gpa, track);
    }

    // Format 1: a leading conductor track without notes or controllers is folded into the global lists.
    const globals_present = smf.tempos.items.len != 0 or smf.meters.items.len != 0 or smf.markers.items.len != 0 or smf.key_sigs.items.len != 0;
    if (format == 1 and smf.tracks.items.len > 0 and (smf.tracks.items.len > 1 or globals_present)) {
        const first = smf.tracks.items[0];
        if (first.sequence.notes.items.len == 0 and first.sequence.ctrls.items.len == 0 and (smf.tracks.items.len > 1 or first.name.len == 0)) {
            var removed = smf.tracks.orderedRemove(0);
            removed.deinit(gpa);
        }
    }

    sortByTick(Tempo, smf.tempos.items);
    sortByTick(Meter, smf.meters.items);
    sortByTick(Marker, smf.markers.items);
    sortByTick(KeySig, smf.key_sigs.items);
    return smf;
}

// ---------------------------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------------------------

const MAX_VLQ: u64 = 0x0FFF_FFFF;

fn pushBe16(gpa: Allocator, out: *std.ArrayList(u8), v: u16) Allocator.Error!void {
    try out.appendSlice(gpa, &[_]u8{ @truncate(v >> 8), @truncate(v) });
}

fn pushBe32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    try out.appendSlice(gpa, &[_]u8{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
}

/// Appends a variable-length quantity (1 to 4 bytes). Values above 28 bits are an error.
fn pushVlq(gpa: Allocator, out: *std.ArrayList(u8), v: u64) SmfError!void {
    if (v > MAX_VLQ) return error.Write;
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        buf[n] = @truncate(x & 0x7F);
        n += 1;
        x >>= 7;
        if (x == 0 or n == 4) break;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        const b = buf[i];
        try out.append(gpa, if (i > 0) b | 0x80 else b);
    }
}

/// One event of a chunk. Its bytes live in `Writer.pool` at `off..off + len`.
/// `order` breaks ties at one tick: conductor 0 tempo, 1 meter, 2 key, 3 marker; track
/// 0 name, 1 note-off, 2 controller, 3 note-on (note-offs first, then controllers, then note-ons).
const WEvent = struct {
    tick: u64,
    order: u8,
    off: usize,
    len: usize,
};

const Writer = struct {
    gpa: Allocator,
    pool: std.ArrayList(u8) = .empty,
    events: std.ArrayList(WEvent) = .empty,

    fn deinit(self: *Writer) void {
        self.pool.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    fn reset(self: *Writer) void {
        self.pool.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
    }

    fn add(self: *Writer, tick: u64, order: u8, bytes: []const u8) SmfError!void {
        const off = self.pool.items.len;
        try self.pool.appendSlice(self.gpa, bytes);
        try self.events.append(self.gpa, .{ .tick = tick, .order = order, .off = off, .len = bytes.len });
    }

    /// Meta event `FF kind len data`.
    fn addMeta(self: *Writer, tick: u64, order: u8, kind: u8, data: []const u8) SmfError!void {
        const off = self.pool.items.len;
        try self.pool.append(self.gpa, 0xFF);
        try self.pool.append(self.gpa, kind);
        try pushVlq(self.gpa, &self.pool, @as(u64, data.len));
        try self.pool.appendSlice(self.gpa, data);
        try self.events.append(self.gpa, .{ .tick = tick, .order = order, .off = off, .len = self.pool.items.len - off });
    }
};

fn clampTick(t: i64) u64 {
    return @intCast(@max(t, 0));
}

fn clampData7(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 127));
}

/// Writes one MTrk chunk from the events in `w`, with running status for channel messages.
fn writeTrack(gpa: Allocator, out: *std.ArrayList(u8), w: *Writer) SmfError!void {
    std.mem.sort(WEvent, w.events.items, {}, struct {
        fn lessThan(_: void, a: WEvent, b: WEvent) bool {
            return a.tick < b.tick or (a.tick == b.tick and a.order < b.order);
        }
    }.lessThan);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var last_tick: u64 = 0;
    var running: ?u8 = null;
    for (w.events.items) |e| {
        try pushVlq(gpa, &body, e.tick - last_tick);
        last_tick = e.tick;
        const bytes = w.pool.items[e.off .. e.off + e.len];
        const status: u8 = if (bytes.len > 0) bytes[0] else 0;
        if (status >= 0x80 and status <= 0xEF) {
            if (running != null and running.? == status) {
                try body.appendSlice(gpa, bytes[1..]);
            } else {
                try body.appendSlice(gpa, bytes);
            }
            running = status;
        } else {
            running = null;
            try body.appendSlice(gpa, bytes);
        }
    }
    // End of Track.
    try body.appendSlice(gpa, &[_]u8{ 0x00, 0xFF, 0x2F, 0x00 });
    const len = std.math.cast(u32, body.items.len) orelse return error.Write;
    try out.appendSlice(gpa, "MTrk");
    try pushBe32(gpa, out, len);
    try out.appendSlice(gpa, body.items);
}

/// The conductor track: tempos, meters, key signatures and markers.
fn writeConductor(w: *Writer, smf: *const Smf) SmfError!void {
    for (smf.tempos.items) |t| {
        if (!std.math.isFinite(t.bpm) or t.bpm <= 0.0) return error.Write;
        const us_f = std.math.clamp(@round(60_000_000.0 / t.bpm), 1.0, 16_777_215.0);
        const us: u32 = @intFromFloat(us_f);
        const data = [_]u8{ @truncate(us >> 16), @truncate(us >> 8), @truncate(us) };
        try w.addMeta(clampTick(t.tick), 0, 0x51, &data);
    }
    for (smf.meters.items) |m| {
        if (m.denominator == 0 or @popCount(m.denominator) != 1) return error.Write;
        const dd: u8 = @truncate(@ctz(m.denominator));
        const data = [_]u8{ m.numerator, dd, 24, 8 };
        try w.addMeta(clampTick(m.tick), 1, 0x58, &data);
    }
    for (smf.key_sigs.items) |k| {
        const sf: i8 = std.math.clamp(k.sharps, -7, 7);
        const data = [_]u8{ @bitCast(sf), @intFromBool(k.minor) };
        try w.addMeta(clampTick(k.tick), 2, 0x59, &data);
    }
    for (smf.markers.items) |mk| try w.addMeta(clampTick(mk.tick), 3, 0x06, mk.text);
}

const OverlapCtx = struct { notes: []const Note, ends: []const u64 };

/// Order for `trimOverlaps`: (channel, pitch, start), then the longest (latest end) first.
fn overlapLess(ctx: OverlapCtx, a: usize, b: usize) bool {
    const na = ctx.notes[a];
    const nb = ctx.notes[b];
    const ca = na.channel & 0x0F;
    const cb = nb.channel & 0x0F;
    if (ca != cb) return ca < cb;
    const pa = @min(na.pitch, 127);
    const pb = @min(nb.pitch, 127);
    if (pa != pb) return pa < pb;
    const sa = clampTick(na.start);
    const sb = clampTick(nb.start);
    if (sa != sb) return sa < sb;
    return ctx.ends[a] > ctx.ends[b];
}

/// Trim notes still sounding when the next same-pitch note starts, and drop duplicates.
/// The reader pairs offs with ons first-in first-out, so a note still sounding when the next
/// same-pitch note starts would swap ends with it: it is trimmed to that start. When two
/// same-pitch notes start on the same tick they cannot be told apart, so only the longer one
/// is written.
fn trimOverlaps(gpa: Allocator, notes: []const Note, ends: []u64, dropped: []bool) SmfError!void {
    const order = try gpa.alloc(usize, notes.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, OverlapCtx{ .notes = notes, .ends = ends }, overlapLess);

    var prev: ?usize = null;
    for (order) |b| {
        if (prev) |a| {
            const na = notes[a];
            const nb = notes[b];
            if ((na.channel & 0x0F) == (nb.channel & 0x0F) and @min(na.pitch, 127) == @min(nb.pitch, 127)) {
                const sa = clampTick(na.start);
                const sb = clampTick(nb.start);
                if (sa == sb) {
                    dropped[b] = true;
                    continue;
                }
                if (sb < ends[a]) ends[a] = sb;
            }
        }
        prev = b;
    }
}

/// Note and controller events of one track into `w`.
fn writeTrackEvents(gpa: Allocator, w: *Writer, track: SmfTrack) SmfError!void {
    const notes = track.sequence.notes.items;
    const ends = try gpa.alloc(u64, notes.len);
    defer gpa.free(ends);
    const dropped = try gpa.alloc(bool, notes.len);
    defer gpa.free(dropped);
    @memset(dropped, false);
    for (notes, 0..) |n, i| {
        ends[i] = @max(clampTick(n.end()), clampTick(n.start) +| 1);
    }
    try trimOverlaps(gpa, notes, ends, dropped);

    for (notes, 0..) |n, i| {
        if (dropped[i]) continue;
        const ch: u8 = n.channel & 0x0F;
        const pitch: u8 = @min(n.pitch, 127);
        try w.add(clampTick(n.start), 3, &[_]u8{ 0x90 | ch, pitch, std.math.clamp(n.velocity, 1, 127) });
        try w.add(ends[i], 1, &[_]u8{ 0x80 | ch, pitch, @min(n.release_velocity, 127) });
    }
    for (track.sequence.ctrls.items) |c| {
        const ch: u8 = c.channel & 0x0F;
        const tick = clampTick(c.tick);
        switch (c.kind) {
            .cc => |num| try w.add(tick, 2, &[_]u8{ 0xB0 | ch, @min(num, 127), clampData7(c.value) }),
            .program => try w.add(tick, 2, &[_]u8{ 0xC0 | ch, clampData7(c.value) }),
            .channel_pressure => try w.add(tick, 2, &[_]u8{ 0xD0 | ch, clampData7(c.value) }),
            .poly_pressure => |p| try w.add(tick, 2, &[_]u8{ 0xA0 | ch, @min(p, 127), clampData7(c.value) }),
            .pitch_bend => {
                const v: u16 = @intCast(std.math.clamp(c.value +| 8192, 0, 16383));
                try w.add(tick, 2, &[_]u8{ 0xE0 | ch, @truncate(v & 0x7F), @truncate((v >> 7) & 0x7F) });
            },
        }
    }
}

/// Serialises `smf` as a format-1 Standard MIDI File at `PPQ` ticks per quarter note.
///
/// Track 1 is a conductor track holding tempos, meters, key signatures and markers (omitted
/// when there is nothing to put in it and no content tracks); every `SmfTrack` follows as its
/// own track. Negative ticks are clamped to 0, data values are clamped to their MIDI ranges,
/// and note-on velocity 0 is written as 1 (0 would mean note-off).
///
/// Errors: `Write` for an invalid tempo (non-finite or <= 0 bpm), a meter denominator that is
/// not a power of two, more than 65535 tracks, a value that does not fit the 28-bit VLQ delta,
/// or a chunk larger than 4 GiB. The returned bytes are owned by `gpa`.
pub fn writeSmf(gpa: Allocator, smf: *const Smf) SmfError![]u8 {
    const has_conductor = !(smf.tempos.items.len == 0 and smf.meters.items.len == 0 and smf.key_sigs.items.len == 0 and smf.markers.items.len == 0 and smf.tracks.items.len == 0);
    const ntrks_count = smf.tracks.items.len + @intFromBool(has_conductor);
    const ntrks = std.math.cast(u16, ntrks_count) orelse return error.Write;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "MThd");
    try pushBe32(gpa, &out, 6);
    try pushBe16(gpa, &out, 1);
    try pushBe16(gpa, &out, ntrks);
    try pushBe16(gpa, &out, @intCast(PPQ));

    var w: Writer = .{ .gpa = gpa };
    defer w.deinit();
    if (has_conductor) {
        try writeConductor(&w, smf);
        try writeTrack(gpa, &out, &w);
        w.reset();
    }
    for (smf.tracks.items) |track| {
        if (track.name.len > 0) try w.addMeta(0, 0, 0x03, track.name);
        try writeTrackEvents(gpa, &w, track);
        try writeTrack(gpa, &out, &w);
        w.reset();
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------------
// Tests. Ported from the Rust crate: 4 inline tests (src/smf.rs) and 19 integration tests
// (tests/it/smf.rs, the 3 proptest cases as seeded loops). One extra test (random mutations)
// has no Rust counterpart and is marked as such.
// ---------------------------------------------------------------------------------------------

fn noteOf(pitch: u8, velocity: u8, release: u8, channel: u8, start: i64, length: i64) Note {
    return .{ .pitch = pitch, .velocity = velocity, .release_velocity = release, .channel = channel, .start = start, .length = length };
}

/// Note on channel 0, velocity 100, release 64, as the Rust tests' `note` helper.
fn note(pitch: u8, start: i64, length: i64) Note {
    return noteOf(pitch, 100, 64, 0, start, length);
}

/// Test input bytes come from an arena (never freed one by one); library results are freed.
/// Concatenates byte parts into one slice.
fn cat(a: Allocator, parts: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    inline for (parts) |p| try list.appendSlice(a, p);
    return list.items;
}

/// Independent VLQ encoder for building test input (the Rust test helper `vlq`).
fn vlq(a: Allocator, v: u32) ![]u8 {
    var digits: [5]u8 = undefined;
    var n: usize = 0;
    var x = v;
    digits[n] = @truncate(x & 0x7F);
    n += 1;
    x >>= 7;
    while (x > 0) : (x >>= 7) {
        digits[n] = @as(u8, @truncate(x & 0x7F)) | 0x80;
        n += 1;
    }
    const out = try a.alloc(u8, n);
    for (0..n) |i| out[i] = digits[n - 1 - i];
    return out;
}

fn appendBe16(a: Allocator, list: *std.ArrayList(u8), v: u16) !void {
    const b = [2]u8{ @truncate(v >> 8), @truncate(v) };
    try list.appendSlice(a, &b);
}

fn appendBe32(a: Allocator, list: *std.ArrayList(u8), v: u32) !void {
    const b = [4]u8{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
    try list.appendSlice(a, &b);
}

fn appendHeader(a: Allocator, list: *std.ArrayList(u8), format: u16, ntrks: u16, division: u16) !void {
    try list.appendSlice(a, "MThd");
    try appendBe32(a, list, 6);
    try appendBe16(a, list, format);
    try appendBe16(a, list, ntrks);
    try appendBe16(a, list, division);
}

fn header(a: Allocator, format: u16, ntrks: u16, division: u16) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try appendHeader(a, &list, format, ntrks, division);
    return list.items;
}

fn appendTrack(a: Allocator, list: *std.ArrayList(u8), body: []const u8) !void {
    try list.appendSlice(a, "MTrk");
    try appendBe32(a, list, @intCast(body.len));
    try list.appendSlice(a, body);
}

/// A complete file: header with `bodies.len` tracks, then each body as an MTrk chunk.
fn file(a: Allocator, format: u16, division: u16, bodies: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try appendHeader(a, &list, format, @intCast(bodies.len), division);
    for (bodies) |body| try appendTrack(a, &list, body);
    return list.items;
}

/// A meta event at delta 0: `00 FF kind len data`.
fn metaEvent(a: Allocator, kind: u8, data: []const u8) ![]u8 {
    return cat(a, .{ &[_]u8{ 0, 0xFF, kind }, try vlq(a, @intCast(data.len)), data });
}

fn writeRead(gpa: Allocator, smf: *const Smf) !Smf {
    const bytes = try writeSmf(gpa, smf);
    defer gpa.free(bytes);
    return readSmf(gpa, bytes);
}

fn expectSequenceEqual(want: *const Sequence, got: *const Sequence) !void {
    try testing.expectEqualSlices(Note, want.notes.items, got.notes.items);
    try testing.expectEqualSlices(CtrlEvent, want.ctrls.items, got.ctrls.items);
}

/// The sequence used by the Rust `round_trip` test (sorted, owned by the caller).
fn pianoSequence(gpa: Allocator) !Sequence {
    var seq: Sequence = .{};
    errdefer seq.deinit(gpa);
    try seq.notes.appendSlice(gpa, &[_]Note{
        note(60, 0, 480),
        noteOf(64, 90, 30, 3, 480, 960),
        note(67, 960, 1),
        note(60, 1920, 240),
    });
    try seq.ctrls.appendSlice(gpa, &[_]CtrlEvent{
        .{ .tick = 0, .channel = 0, .kind = .program, .value = 5 },
        .{ .tick = 10, .channel = 0, .kind = .{ .cc = 7 }, .value = 100 },
        .{ .tick = 20, .channel = 1, .kind = .pitch_bend, .value = -8192 },
        .{ .tick = 30, .channel = 1, .kind = .pitch_bend, .value = 8191 },
        .{ .tick = 40, .channel = 1, .kind = .pitch_bend, .value = 0 },
        .{ .tick = 50, .channel = 2, .kind = .channel_pressure, .value = 77 },
        .{ .tick = 60, .channel = 2, .kind = .{ .poly_pressure = 61 }, .value = 12 },
    });
    seq.sort();
    return seq;
}

fn pairLess(_: void, a: [2]i64, b: [2]i64) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

fn tripleLess(_: void, a: [3]i64, b: [3]i64) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    if (a[1] != b[1]) return a[1] < b[1];
    return a[2] < b[2];
}

// --- inline tests (Rust src/smf.rs) ---

test "vlq_round_trip" {
    const values = [_]u64{ 0, 0x40, 0x7F, 0x80, 0x2000, 0x3FFF, 0x4000, 0x1F_FFFF, 0x20_0000, MAX_VLQ };
    for (values) |v| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try pushVlq(testing.allocator, &out, v);
        var c: Cursor = .{ .data = out.items };
        try testing.expectEqual(v, @as(u64, try c.readVlq()));
        try testing.expect(c.isEmpty());
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Write, pushVlq(testing.allocator, &out, MAX_VLQ + 1));
}

test "empty_smf_round_trips_with_no_tracks" {
    const gpa = testing.allocator;
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        var r = try writeRead(gpa, &smf);
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), r.tracks.items.len);
    }
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tracks.append(gpa, .{});
        var r = try writeRead(gpa, &smf);
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), r.tracks.items.len);
    }
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tempos.append(gpa, .{ .tick = 0, .bpm = 90.0 });
        var r = try writeRead(gpa, &smf);
        defer r.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), r.tracks.items.len);
        try testing.expectEqual(@as(usize, 1), r.tempos.items.len);
    }
}

test "spec_vlq_examples" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try pushVlq(testing.allocator, &out, 0x0800_0000);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0x80, 0x80, 0x00 }, out.items);
    out.clearRetainingCapacity();
    try pushVlq(testing.allocator, &out, 0x2000);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0x00 }, out.items);
}

test "same_pitch_overlaps_do_not_swap_ends" {
    const gpa = testing.allocator;
    var smf: Smf = .{};
    defer smf.deinit(gpa);
    try smf.tracks.append(gpa, .{});
    const seq = &smf.tracks.items[0].sequence;
    try seq.notes.appendSlice(gpa, &[_]Note{
        note(60, 0, 1000),
        note(60, 100, 200),
        note(60, 1000, 100),
        note(60, 2000, 500),
        note(60, 2000, 900),
    });

    var back = try writeRead(gpa, &smf);
    defer back.deinit(gpa);
    var got: std.ArrayList([2]i64) = .empty;
    defer got.deinit(gpa);
    for (back.tracks.items) |t| {
        for (t.sequence.notes.items) |n| try got.append(gpa, .{ n.start, n.length });
    }
    std.mem.sort([2]i64, got.items, {}, pairLess);
    // The earlier note is trimmed to the start of the next same-pitch note; later notes keep
    // their length; of two notes starting together only the longer survives.
    try testing.expectEqualSlices([2]i64, &[_][2]i64{ .{ 0, 100 }, .{ 100, 200 }, .{ 1000, 100 }, .{ 2000, 900 } }, got.items);
}

// --- integration tests (Rust tests/it/smf.rs) ---

test "round_trip" {
    const gpa = testing.allocator;
    var smf: Smf = .{ .format = 1 };
    defer smf.deinit(gpa);
    try smf.tracks.append(gpa, .{ .name = try gpa.dupe(u8, "Piano"), .sequence = try pianoSequence(gpa) });
    try smf.tracks.append(gpa, .{ .name = try gpa.dupe(u8, "Bass ♪") });
    try smf.tracks.items[1].sequence.notes.append(gpa, note(36, 100, 50));
    try smf.tempos.appendSlice(gpa, &[_]Tempo{ .{ .tick = 0, .bpm = 120.0 }, .{ .tick = 3840, .bpm = 90.0 } });
    try smf.meters.appendSlice(gpa, &[_]Meter{ .{ .tick = 0, .numerator = 4, .denominator = 4 }, .{ .tick = 3840, .numerator = 6, .denominator = 8 } });
    try smf.markers.append(gpa, .{ .tick = 0, .text = try gpa.dupe(u8, "Intro") });
    try smf.markers.append(gpa, .{ .tick = 7680, .text = try gpa.dupe(u8, "Verse") });
    try smf.key_sigs.appendSlice(gpa, &[_]KeySig{ .{ .tick = 0, .sharps = -3, .minor = true }, .{ .tick = 3840, .sharps = 2, .minor = false } });

    const bytes = try writeSmf(gpa, &smf);
    defer gpa.free(bytes);
    var back = try readSmf(gpa, bytes);
    defer back.deinit(gpa);

    try testing.expectEqual(@as(u16, 1), back.format);
    try testing.expectEqual(@as(usize, 2), back.tracks.items.len);
    try testing.expectEqualStrings("Piano", back.tracks.items[0].name);
    var expected_piano = try pianoSequence(gpa);
    defer expected_piano.deinit(gpa);
    try expectSequenceEqual(&expected_piano, &back.tracks.items[0].sequence);
    try testing.expectEqualStrings("Bass ♪", back.tracks.items[1].name);
    try testing.expectEqualSlices(Note, &[_]Note{note(36, 100, 50)}, back.tracks.items[1].sequence.notes.items);
    try testing.expectEqual(@as(usize, 2), back.tempos.items.len);
    try testing.expectApproxEqAbs(@as(f64, 120.0), back.tempos.items[0].bpm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90.0), back.tempos.items[1].bpm, 1e-3);
    try testing.expectEqual(@as(i64, 3840), back.tempos.items[1].tick);
    try testing.expectEqualSlices(Meter, smf.meters.items, back.meters.items);
    try testing.expectEqual(smf.markers.items.len, back.markers.items.len);
    for (smf.markers.items, back.markers.items) |want, got| {
        try testing.expectEqual(want.tick, got.tick);
        try testing.expectEqualStrings(want.text, got.text);
    }
    try testing.expectEqualSlices(KeySig, smf.key_sigs.items, back.key_sigs.items);

    // Writing again is byte-identical (with the original tempo map, as in the Rust test).
    // `again` borrows back's storage and is never deinitialised.
    const again: Smf = .{
        .format = back.format,
        .tracks = back.tracks,
        .tempos = smf.tempos,
        .meters = back.meters,
        .markers = back.markers,
        .key_sigs = back.key_sigs,
    };
    const bytes2 = try writeSmf(gpa, &again);
    defer gpa.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);
}

test "first_track_name_wins_and_ignored_meta_preserves_following_notes" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The raw name bytes and the expected (lossy UTF-8) name.
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "First", .want = "First" },
        .{ .raw = "", .want = "" },
        .{ .raw = &[_]u8{0xFF}, .want = "\xEF\xBF\xBD" },
    };
    for (cases) |c| {
        const body = try cat(a, .{
            try metaEvent(a, 0x03, c.raw),
            try metaEvent(a, 0x03, "Second"),
            try metaEvent(a, 0x7F, &[_]u8{ 0x03, 0xFF, 0x2F }), // Unhandled metadata must remain ignored.
            &[_]u8{ 0, 0x90, 60, 100, 16, 0x80, 60, 64, 0, 0xFF, 0x2F, 0 },
        });
        const bytes = try file(a, 0, 960, &[_][]const u8{body});
        var smf = try readSmf(gpa, bytes);
        defer smf.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), smf.tracks.items.len);
        try testing.expectEqualStrings(c.want, smf.tracks.items[0].name);
        try testing.expectEqualSlices(Note, &[_]Note{note(60, 0, 16)}, smf.tracks.items[0].sequence.notes.items);
    }
}

test "write_rejects_bad_values" {
    const gpa = testing.allocator;
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tempos.append(gpa, .{ .tick = 0, .bpm = 0.0 });
        try testing.expectError(error.Write, writeSmf(gpa, &smf));
    }
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tempos.append(gpa, .{ .tick = 0, .bpm = std.math.nan(f64) });
        try testing.expectError(error.Write, writeSmf(gpa, &smf));
    }
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.meters.append(gpa, .{ .tick = 0, .numerator = 4, .denominator = 3 });
        try testing.expectError(error.Write, writeSmf(gpa, &smf));
    }
    {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tracks.append(gpa, .{});
        try smf.tracks.items[0].sequence.notes.append(gpa, note(60, 0x1000_0000, 10));
        try testing.expectError(error.Write, writeSmf(gpa, &smf));
    }
}

test "division_conversion_480_to_960" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Note at tick 480 (one quarter at 480 PPQ), length 240.
    const body = try cat(a, .{ try vlq(a, 480), &[_]u8{ 0x90, 60, 100 }, try vlq(a, 240), &[_]u8{ 0x80, 60, 0 }, &[_]u8{ 0, 0xFF, 0x2F, 0 } });
    const bytes = try file(a, 0, 480, &[_][]const u8{body});
    var smf = try readSmf(gpa, bytes);
    defer smf.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), smf.tracks.items.len);
    try testing.expectEqualSlices(Note, &[_]Note{noteOf(60, 100, 0, 0, 960, 480)}, smf.tracks.items[0].sequence.notes.items);
}

test "division_conversion_96_and_smpte" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const body = try cat(a, .{ try vlq(a, 96), &[_]u8{ 0x90, 60, 100 }, try vlq(a, 48), &[_]u8{ 0x80, 60, 64 } });
        const bytes = try file(a, 0, 96, &[_][]const u8{body});
        var smf = try readSmf(gpa, bytes);
        defer smf.deinit(gpa);
        const n = smf.tracks.items[0].sequence.notes.items[0];
        try testing.expectEqual(@as(i64, 960), n.start);
        try testing.expectEqual(@as(i64, 480), n.length);
    }
    {
        // SMPTE 25 fps, 40 ticks/frame = 1000 ticks/s; at 120 bpm 0.5 s = 960 ticks.
        // Division high byte is -25 as two's complement (0xE7), low byte 40.
        const division: u16 = 0xE728;
        const body = try cat(a, .{ try vlq(a, 500), &[_]u8{ 0x90, 60, 100 }, try vlq(a, 250), &[_]u8{ 0x80, 60, 64 } });
        const bytes = try file(a, 0, division, &[_][]const u8{body});
        var smf = try readSmf(gpa, bytes);
        defer smf.deinit(gpa);
        const n = smf.tracks.items[0].sequence.notes.items[0];
        try testing.expectEqual(@as(i64, 960), n.start);
        try testing.expectEqual(@as(i64, 480), n.length);
    }
}

test "smpte_division_rejects_undefined_frame_rates" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0, 0x90, 60, 100, 40, 0x80, 60, 64, 0, 0xFF, 0x2F, 0 };
    // High bytes for -24, -25, -29, -30 as two's complement: 0xE8, 0xE7, 0xE3, 0xE2.
    for (0x80..0x100) |h| {
        const high: u8 = @intCast(h);
        if (high == 0xE8 or high == 0xE7 or high == 0xE3 or high == 0xE2) continue;
        const division: u16 = (@as(u16, high) << 8) | 40;
        const bytes = try file(a, 0, division, &[_][]const u8{&body});
        try testing.expectError(error.Invalid, readSmf(gpa, bytes));
    }
}

test "smpte_division_keeps_all_four_standard_frame_rates" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { fps: i8, file_ticks: u32, model_ticks: i64 }{
        .{ .fps = 24, .file_ticks = 960, .model_ticks = 1920 },
        .{ .fps = 25, .file_ticks = 1000, .model_ticks = 1920 },
        .{ .fps = 29, .file_ticks = 1200, .model_ticks = 1922 },
        .{ .fps = 30, .file_ticks = 1200, .model_ticks = 1920 },
    };
    for (cases) |c| {
        const body = try cat(a, .{ &[_]u8{ 0, 0x90, 60, 100 }, try vlq(a, c.file_ticks), &[_]u8{ 0x80, 60, 64, 0, 0xFF, 0x2F, 0 } });
        const hi: u8 = @bitCast(-c.fps);
        const division: u16 = (@as(u16, hi) << 8) | 40;
        {
            const bytes = try file(a, 0, division, &[_][]const u8{body});
            var smf = try readSmf(gpa, bytes);
            defer smf.deinit(gpa);
            try testing.expectEqualSlices(Note, &[_]Note{note(60, 0, c.model_ticks)}, smf.tracks.items[0].sequence.notes.items);
        }
        // Zero ticks per frame is invalid.
        const zero_tpf = try file(a, 0, @as(u16, hi) << 8, &[_][]const u8{body});
        try testing.expectError(error.Invalid, readSmf(gpa, zero_tpf));
    }
}

test "running_status_and_velocity_zero_note_off" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Note-on with running status for both on and off (velocity 0).
    const body = try cat(a, .{
        &[_]u8{ 0x00, 0x91, 60, 100 }, // on C3 ch1
        &[_]u8{ 0x00, 64, 90 }, // running: on E3
        try vlq(a, 960),
        &[_]u8{ 60, 0 }, // running: note-on vel 0 = off C3
        &[_]u8{ 0x00, 64, 0 },
        &[_]u8{ 0x00, 0xB1, 7, 100 }, // CC7
        &[_]u8{ 0x10, 10, 64 }, // running CC10
    });
    const bytes = try file(a, 0, 960, &[_][]const u8{body});
    var smf = try readSmf(gpa, bytes);
    defer smf.deinit(gpa);
    const seq = &smf.tracks.items[0].sequence;
    try testing.expectEqualSlices(Note, &[_]Note{
        noteOf(60, 100, 64, 1, 0, 960),
        noteOf(64, 90, 64, 1, 0, 960),
    }, seq.notes.items);
    try testing.expectEqualSlices(CtrlEvent, &[_]CtrlEvent{
        .{ .tick = 960, .channel = 1, .kind = .{ .cc = 7 }, .value = 100 },
        .{ .tick = 976, .channel = 1, .kind = .{ .cc = 10 }, .value = 64 },
    }, seq.ctrls.items);
}

test "meta_cancels_running_status" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try cat(a, .{
        &[_]u8{ 0x00, 0x90, 60, 100 },
        &[_]u8{ 0x00, 0xFF, 0x01, 0x01, 'x' },
        &[_]u8{ 0x00, 60, 0 },
    });
    const bytes = try file(a, 0, 960, &[_][]const u8{body});
    try testing.expectError(error.Invalid, readSmf(gpa, bytes));
}

test "unmatched_note_off_ignored_and_hanging_notes_closed" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try cat(a, .{
        &[_]u8{ 0x00, 0x80, 50, 0 }, // unmatched off
        &[_]u8{ 0x00, 0x90, 60, 100 }, // hanging
        try vlq(a, 100),
        &[_]u8{ 0x90, 62, 100 },
        try vlq(a, 100),
        &[_]u8{ 0x80, 62, 10 },
        try vlq(a, 800),
        &[_]u8{ 0xFF, 0x2F, 0x00 },
    });
    const bytes = try file(a, 0, 960, &[_][]const u8{body});
    var smf = try readSmf(gpa, bytes);
    defer smf.deinit(gpa);
    try testing.expectEqualSlices(Note, &[_]Note{
        noteOf(60, 100, 64, 0, 0, 1000),
        noteOf(62, 100, 10, 0, 100, 100),
    }, smf.tracks.items[0].sequence.notes.items);
}

test "overlapping_same_pitch_fifo_and_zero_length" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try cat(a, .{
        &[_]u8{ 0x00, 0x90, 60, 100 },
        &[_]u8{ 0x10, 0x90, 60, 80 },
        &[_]u8{ 0x10, 0x80, 60, 0 },
        &[_]u8{ 0x10, 0x80, 60, 0 },
        &[_]u8{ 0x00, 0x90, 70, 1 },
        &[_]u8{ 0x00, 0x80, 70, 0 },
    });
    const bytes = try file(a, 0, 960, &[_][]const u8{body});
    var smf = try readSmf(gpa, bytes);
    defer smf.deinit(gpa);
    const notes = smf.tracks.items[0].sequence.notes.items;
    try testing.expectEqual(@as(usize, 3), notes.len);
    try testing.expectEqual(@as(i64, 0), notes[0].start);
    try testing.expectEqual(@as(i64, 32), notes[0].length);
    try testing.expectEqual(@as(u8, 100), notes[0].velocity);
    try testing.expectEqual(@as(i64, 16), notes[1].start);
    try testing.expectEqual(@as(i64, 32), notes[1].length);
    try testing.expectEqual(@as(u8, 80), notes[1].velocity);
    try testing.expectEqual(@as(u8, 70), notes[2].pitch);
    try testing.expectEqual(@as(i64, 1), notes[2].length);
}

test "format1_conductor_folded_and_unknown_chunks_skipped" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const conductor = try cat(a, .{
        &[_]u8{ 0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20 }, // 500000 us = 120 bpm
        &[_]u8{ 0x00, 0xFF, 0x58, 0x04, 3, 2, 24, 8 }, // 3/4
        &[_]u8{ 0x00, 0xFF, 0x2F, 0x00 },
    });
    const t1 = try cat(a, .{
        &[_]u8{ 0x00, 0xFF, 0x03, 0x03, 'O', 'r', 'g' },
        &[_]u8{ 0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0 },
    });
    var bytes: std.ArrayList(u8) = .empty;
    try appendHeader(a, &bytes, 1, 2, 960);
    try appendTrack(a, &bytes, conductor);
    try bytes.appendSlice(a, "XFIH\x00\x00\x00\x03abc");
    try appendTrack(a, &bytes, t1);
    var smf = try readSmf(gpa, bytes.items);
    defer smf.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), smf.tracks.items.len);
    try testing.expectEqualStrings("Org", smf.tracks.items[0].name);
    try testing.expectEqual(@as(usize, 1), smf.tempos.items.len);
    try testing.expectEqual(@as(i64, 0), smf.tempos.items[0].tick);
    try testing.expectApproxEqAbs(@as(f64, 120.0), smf.tempos.items[0].bpm, 1e-9);
    try testing.expectEqualSlices(Meter, &[_]Meter{.{ .tick = 0, .numerator = 3, .denominator = 4 }}, smf.meters.items);
}

test "sysex_skipped" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try cat(a, .{
        &[_]u8{ 0x00, 0xF0, 0x03, 0x7E, 0x7F, 0xF7 },
        &[_]u8{ 0x00, 0x90, 60, 100, 0x10, 0x80, 60, 0 },
    });
    const bytes = try file(a, 0, 960, &[_][]const u8{body});
    var smf = try readSmf(gpa, bytes);
    defer smf.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), smf.tracks.items[0].sequence.notes.items.len);
}

test "malformed_inputs_are_errors" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.NotSmf, readSmf(gpa, ""));
    try testing.expectError(error.NotSmf, readSmf(gpa, "RIFF\x00\x00\x00\x06"));
    // Header truncated.
    try testing.expectError(error.BadChunkLength, readSmf(gpa, "MThd\x00\x00\x00\x06\x00\x01"));
    // Header length < 6.
    try testing.expectError(error.Invalid, readSmf(gpa, "MThd\x00\x00\x00\x02\x00\x01"));
    // Division 0.
    try testing.expectError(error.Invalid, readSmf(gpa, try header(a, 0, 0, 0)));
    // Format 3.
    try testing.expectError(error.Unsupported, readSmf(gpa, try header(a, 3, 0, 96)));
    // Chunk length larger than the data.
    {
        const b = try cat(a, .{ try header(a, 0, 1, 96), "MTrk\xFF\xFF\xFF\xF0\x00\x90" });
        try testing.expectError(error.BadChunkLength, readSmf(gpa, b));
    }
    // Truncated chunk header.
    {
        const b = try cat(a, .{ try header(a, 0, 1, 96), "MTr" });
        try testing.expectError(error.Truncated, readSmf(gpa, b));
    }
    // Huge VLQ (4 continuation bytes).
    {
        const body = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x90, 60, 100 };
        const b = try file(a, 0, 96, &[_][]const u8{&body});
        try testing.expectError(error.VlqTooLong, readSmf(gpa, b));
    }
    // Meta length past the end of the track.
    {
        const body = [_]u8{ 0x00, 0xFF, 0x03, 0x7F, 'a' };
        const b = try file(a, 0, 96, &[_][]const u8{&body});
        try testing.expectError(error.Truncated, readSmf(gpa, b));
    }
    // Truncated channel message.
    {
        const body = [_]u8{ 0x00, 0x90, 60 };
        const b = try file(a, 0, 96, &[_][]const u8{&body});
        try testing.expectError(error.Truncated, readSmf(gpa, b));
    }
    // Data byte with no running status.
    {
        const body = [_]u8{ 0x00, 60, 100 };
        const b = try file(a, 0, 96, &[_][]const u8{&body});
        try testing.expectError(error.Invalid, readSmf(gpa, b));
    }
    // System common inside a track.
    {
        const body = [_]u8{ 0x00, 0xF2, 0, 0 };
        const b = try file(a, 0, 96, &[_][]const u8{&body});
        try testing.expectError(error.Invalid, readSmf(gpa, b));
    }
    // Header only (no tracks) is fine.
    {
        var smf = try readSmf(gpa, try header(a, 1, 0, 96));
        defer smf.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), smf.tracks.items.len);
    }
}

test "event_cap_reached_is_error" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // One program change, then MAX_EVENTS one-byte running-status program changes: MAX_EVENTS + 1 events.
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, &[_]u8{ 0x00, 0xC0, 0x00 });
    try body.ensureTotalCapacity(a, MAX_EVENTS * 2);
    for (0..MAX_EVENTS) |_| try body.appendSlice(a, &[_]u8{ 0x00, 0x01 });
    const bytes = try file(a, 0, 96, &[_][]const u8{body.items});
    try testing.expectError(error.TooManyEvents, readSmf(gpa, bytes));
}

test "random_bytes_never_panic" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rng = prng.random();
    var buf: [512]u8 = undefined;
    for (0..512) |_| {
        const len = rng.uintLessThan(usize, 512);
        rng.bytes(buf[0..len]);
        if (readSmf(gpa, buf[0..len])) |ok| {
            var s = ok;
            s.deinit(gpa);
        } else |_| {}
    }
}

test "random_track_bodies_never_panic" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x5EED_0002);
    const rng = prng.random();
    var body_buf: [512]u8 = undefined;
    for (0..512) |_| {
        const len = rng.uintLessThan(usize, 512);
        rng.bytes(body_buf[0..len]);
        const div = rng.int(u16);
        const fmt = rng.uintLessThan(u16, 4);
        const bytes = try file(a, fmt, div, &[_][]const u8{body_buf[0..len]});
        if (readSmf(gpa, bytes)) |ok| {
            var s = ok;
            s.deinit(gpa);
        } else |_| {}
    }
}

test "written_files_read_back" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0003);
    const rng = prng.random();
    for (0..256) |_| {
        var smf: Smf = .{ .format = 1 };
        defer smf.deinit(gpa);
        try smf.tracks.append(gpa, .{ .name = try gpa.dupe(u8, "t") });
        const seq = &smf.tracks.items[0].sequence;
        const n = rng.uintLessThan(usize, 64);
        for (0..n) |_| {
            try seq.notes.append(gpa, .{
                .pitch = rng.uintLessThan(u8, 128),
                .velocity = 1 + rng.uintLessThan(u8, 127),
                .release_velocity = 64,
                .channel = rng.uintLessThan(u8, 16),
                .start = rng.intRangeLessThan(i64, 0, 100_000),
                .length = rng.intRangeLessThan(i64, 1, 10_000),
            });
        }
        _ = seq.removeDuplicates();

        const bytes = try writeSmf(gpa, &smf);
        defer gpa.free(bytes);
        var back = try readSmf(gpa, bytes);
        defer back.deinit(gpa);
        const got: []const Note = if (back.tracks.items.len > 0) back.tracks.items[0].sequence.notes.items else &[_]Note{};

        // Overlapping same-pitch notes may re-pair, but count and starts survive.
        try testing.expectEqual(seq.notes.items.len, got.len);
        var a_list: std.ArrayList([3]i64) = .empty;
        defer a_list.deinit(gpa);
        var b_list: std.ArrayList([3]i64) = .empty;
        defer b_list.deinit(gpa);
        for (got) |x| try a_list.append(gpa, .{ x.start, x.pitch, x.channel });
        for (seq.notes.items) |x| try b_list.append(gpa, .{ x.start, x.pitch, x.channel });
        std.mem.sort([3]i64, a_list.items, {}, tripleLess);
        std.mem.sort([3]i64, b_list.items, {}, tripleLess);
        try testing.expectEqualSlices([3]i64, b_list.items, a_list.items);
    }
}

// #472: out-of-range pitches, release velocities and controller numbers clamp to 127 instead of
// wrapping into other notes and controllers (128 & 0x7F would be 0).
test "writer_clamps_out_of_range_data_bytes" {
    const gpa = testing.allocator;
    for ([_]u8{ 127, 128, 255 }) |raw| {
        var smf: Smf = .{};
        defer smf.deinit(gpa);
        try smf.tracks.append(gpa, .{});
        const seq = &smf.tracks.items[0].sequence;
        try seq.notes.append(gpa, .{ .pitch = raw, .velocity = 100, .release_velocity = raw, .channel = 0, .start = 0, .length = 960 });
        try seq.ctrls.append(gpa, .{ .tick = 0, .channel = 0, .kind = .{ .cc = raw }, .value = 64 });
        try seq.ctrls.append(gpa, .{ .tick = 0, .channel = 0, .kind = .{ .poly_pressure = raw }, .value = 64 });

        var back = try writeRead(gpa, &smf);
        defer back.deinit(gpa);
        const s = &back.tracks.items[back.tracks.items.len - 1].sequence;
        try testing.expectEqual(@as(u8, 127), s.notes.items[0].pitch);
        try testing.expectEqual(@as(u8, 127), s.notes.items[0].release_velocity);
        var saw_cc = false;
        var saw_poly = false;
        for (s.ctrls.items) |c| switch (c.kind) {
            .cc => |v| {
                if (v == 127) saw_cc = true;
            },
            .poly_pressure => |v| {
                if (v == 127) saw_poly = true;
            },
            else => {},
        };
        try testing.expect(saw_cc and saw_poly);
    }
}

// --- extra test, no Rust counterpart: random mutations of a valid file must not panic ---

test "random mutations of a valid file never panic" {
    const gpa = testing.allocator;
    var smf: Smf = .{ .format = 1 };
    defer smf.deinit(gpa);
    try smf.tempos.append(gpa, .{ .tick = 0, .bpm = 120.0 });
    try smf.meters.append(gpa, .{ .tick = 0, .numerator = 3, .denominator = 4 });
    try smf.key_sigs.append(gpa, .{ .tick = 0, .sharps = -2, .minor = false });
    try smf.markers.append(gpa, .{ .tick = 960, .text = try gpa.dupe(u8, "A") });
    try smf.tracks.append(gpa, .{ .name = try gpa.dupe(u8, "lead") });
    try smf.tracks.items[0].sequence.notes.appendSlice(gpa, &[_]Note{ note(60, 0, 480), note(64, 480, 480) });
    try smf.tracks.items[0].sequence.ctrls.append(gpa, .{ .tick = 10, .channel = 0, .kind = .{ .cc = 7 }, .value = 100 });
    const valid = try writeSmf(gpa, &smf);
    defer gpa.free(valid);

    const buf = try gpa.alloc(u8, valid.len);
    defer gpa.free(buf);
    var prng = std.Random.DefaultPrng.init(0x5EED_0004);
    const rng = prng.random();
    for (0..512) |_| {
        @memcpy(buf, valid);
        const edits = 1 + rng.uintLessThan(usize, 8);
        for (0..edits) |_| buf[rng.uintLessThan(usize, buf.len)] = rng.int(u8);
        var len = buf.len;
        if (rng.uintLessThan(u8, 8) == 0) len = rng.uintLessThan(usize, buf.len + 1);
        if (readSmf(gpa, buf[0..len])) |ok| {
            var s = ok;
            s.deinit(gpa);
        } else |_| {}
    }
}
