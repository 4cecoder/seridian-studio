//! `seridian song [PATH]`: writes a fixed, arranged demo song into the running
//! app through its command socket, then optionally saves it. The arrangement
//! lives here as code; nothing is a file format. The app can be a GUI or a
//! headless instance: both answer the same line protocol.

const std = @import("std");
const drum_kit = @import("../instruments/drum_kit.zig");

pub const usage = "seridian song [PATH]";

const bpm = 120;
const beats_per_bar = 4;
const total_bars = 88;
const max_notes = 2048;
const max_reply_bytes: usize = 4096;
const max_failures_shown = 5;

pub const Section = enum { intro, verse, chorus, bridge, outro };

const SectionSpan = struct { section: Section, first_bar: u32, bars: u32 };

/// Bar layout: intro 0-7, verse 8-23, chorus 24-39, verse 40-55, bridge 56-63,
/// chorus 64-79, outro 80-87.
pub const layout = [_]SectionSpan{
    .{ .section = .intro, .first_bar = 0, .bars = 8 },
    .{ .section = .verse, .first_bar = 8, .bars = 16 },
    .{ .section = .chorus, .first_bar = 24, .bars = 16 },
    .{ .section = .verse, .first_bar = 40, .bars = 16 },
    .{ .section = .bridge, .first_bar = 56, .bars = 8 },
    .{ .section = .chorus, .first_bar = 64, .bars = 16 },
    .{ .section = .outro, .first_bar = 80, .bars = 8 },
};

pub fn sectionAt(bar: u32) Section {
    for (layout) |span| {
        if (bar >= span.first_bar and bar < span.first_bar + span.bars) return span.section;
    }
    return .outro;
}

const TrackSpec = struct { instrument: []const u8, gain: []const u8, pan: []const u8, eq: []const u8 };

/// Tracks 1..5 in order: pads, bass, drums, lead, harp. Track pans place each
/// part; the hats, toms, strings width and harp movement are added inside the
/// instruments (see drum_kit.drumPan, orchestra.harpPan), all deterministic.
const track_specs = [_]TrackSpec{
    .{ .instrument = "StringsWarm", .gain = "0.6", .pan = "0", .eq = "pads" },
    .{ .instrument = "WavetableSynth", .gain = "0.8", .pan = "-0.1", .eq = "bass" },
    .{ .instrument = "DrumKit909", .gain = "0.8", .pan = "0", .eq = "drums" },
    .{ .instrument = "BrassTrumpet", .gain = "0.7", .pan = "0.2", .eq = "lead" },
    .{ .instrument = "Harp", .gain = "0.5", .pan = "-0.25", .eq = "harp" },
};

const Chord = struct {
    pad: [3]u8,
    bass: u8,
    lead: [4]u8,
};

/// Cm, Ab, Eb, Bb: one chord per bar, repeated.
const progression = [_]Chord{
    .{ .pad = .{ 60, 63, 67 }, .bass = 36, .lead = .{ 72, 75, 79, 75 } },
    .{ .pad = .{ 56, 60, 63 }, .bass = 32, .lead = .{ 72, 75, 80, 75 } },
    .{ .pad = .{ 55, 58, 63 }, .bass = 39, .lead = .{ 70, 75, 79, 75 } },
    .{ .pad = .{ 53, 58, 62 }, .bass = 34, .lead = .{ 74, 77, 74, 70 } },
};

const track_pads: u8 = 1;
const track_bass: u8 = 2;
const track_drums: u8 = 3;
const track_lead: u8 = 4;
const track_harp: u8 = 5;

const kick: u8 = 36;
const snare: u8 = 38;
const hat: u8 = 42;

pub const Note = struct {
    track: u8,
    pitch: u8,
    start: f32,
    length: f32,
    velocity: u8,
};

pub const Arrangement = struct {
    notes: [max_notes]Note = undefined,
    len: usize = 0,

    fn add(self: *Arrangement, track: u8, pitch: u8, start: f32, length: f32, velocity: u8) void {
        std.debug.assert(self.len < max_notes);
        self.notes[self.len] = .{ .track = track, .pitch = pitch, .start = start, .length = length, .velocity = velocity };
        self.len += 1;
    }

    pub fn slice(self: *const Arrangement) []const Note {
        return self.notes[0..self.len];
    }
};

/// Builds every note of the song. Start and length are in beats.
pub fn build() Arrangement {
    var song = Arrangement{};
    var bar: u32 = 0;
    while (bar < total_bars) : (bar += 1) {
        const origin: f32 = @floatFromInt(bar * beats_per_bar);
        const chord = progression[bar % progression.len];
        const section = sectionAt(bar);
        const groove = section == .verse or section == .chorus;

        for (chord.pad) |pitch| song.add(track_pads, pitch, origin, 4, 78);

        if (groove) {
            var step: u32 = 0;
            while (step < 8) : (step += 1) {
                const at = origin + @as(f32, @floatFromInt(step)) * 0.5;
                song.add(track_bass, chord.bass, at, 0.5, 100);
                song.add(track_drums, hat, at, 0.25, 70);
            }
            song.add(track_drums, kick, origin, 0.5, 110);
            song.add(track_drums, snare, origin + 1, 0.5, 100);
            song.add(track_drums, kick, origin + 2, 0.5, 110);
            song.add(track_drums, snare, origin + 3, 0.5, 100);
        } else if (section == .intro and bar >= 4) {
            var beat: u32 = 0;
            while (beat < beats_per_bar) : (beat += 1) {
                song.add(track_drums, hat, origin + @as(f32, @floatFromInt(beat)), 0.25, 45);
            }
        }

        if (section == .chorus) {
            for (chord.lead, 0..) |pitch, i| {
                song.add(track_lead, pitch, origin + @as(f32, @floatFromInt(i)), 1, 96);
            }
        }

        if (section == .intro or section == .bridge) {
            const order = [8]usize{ 0, 1, 2, 1, 0, 1, 2, 1 };
            for (order, 0..) |tone, i| {
                song.add(track_harp, chord.pad[tone] + 12, origin + @as(f32, @floatFromInt(i)) * 0.5, 0.5, 80);
            }
        }
    }
    return song;
}

/// One line per command, one connection each, same as `seridian note` etc.
const Sender = struct {
    io: std.Io,
    path: []const u8,
    sent: usize = 0,
    failed: usize = 0,
    shown: usize = 0,

    fn exchange(self: *Sender, line: []const u8) !bool {
        const address = try std.Io.net.UnixAddress.init(self.path);
        const stream = try address.connect(self.io);
        defer stream.close(self.io);

        var write_buf: [64]u8 = undefined;
        var writer = stream.writer(self.io, &write_buf);
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();

        var read_buf: [max_reply_bytes]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        const raw = try reader.interface.takeDelimiterExclusive('\n');
        const reply = std.mem.trim(u8, raw, " \r\t");
        return std.mem.eql(u8, reply, "ok") or std.mem.startsWith(u8, reply, "ok ");
    }

    /// Sends one line and counts it. Returns false on failure.
    fn send(self: *Sender, line: []const u8) !bool {
        const accepted = self.exchange(line) catch |err| {
            try self.noteFailure(line, @errorName(err));
            return false;
        };
        if (!accepted) {
            try self.noteFailure(line, "rejected");
            return false;
        }
        self.sent += 1;
        return true;
    }

    fn noteFailure(self: *Sender, line: []const u8, why: []const u8) !void {
        self.failed += 1;
        if (self.shown >= max_failures_shown) return;
        self.shown += 1;
        try printErr(self.io, "failed ({s}): {s}\n", .{ why, line });
    }
};

fn printErr(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, fmt_args);
    try w.interface.flush();
}

fn printOut(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, fmt_args);
    try w.interface.flush();
}

/// Runs `seridian song [PATH]` against the socket at `socket_path`.
/// Exit 0 when every command was accepted, 1 otherwise.
pub fn run(io: std.Io, socket_path: []const u8, args: []const []const u8) !u8 {
    if (args.len > 1) {
        try printErr(io, "usage: {s}\n", .{usage});
        return 1;
    }
    if (args.len == 1) {
        const p = args[0];
        var ok = p.len > 0 and p.len <= 120;
        for (p) |c| if (c <= ' ' or c == 0x7f) {
            ok = false;
        };
        if (!ok) {
            try printErr(io, "usage: {s}\n", .{usage});
            return 1;
        }
    }

    var sender = Sender{ .io = io, .path = socket_path };
    var line_buf: [256]u8 = undefined;

    // Setup: a refused first command means the app is not there; stop early.
    const first = try std.fmt.bufPrint(&line_buf, "clear 1", .{});
    if (!try sender.send(first)) {
        try printErr(io, "app is not running or refused the connection\n", .{});
        return 1;
    }
    for (1..track_specs.len + 1) |track| {
        if (track > 1) {
            _ = try sender.send(try std.fmt.bufPrint(&line_buf, "clear {d}", .{track}));
        }
    }
    _ = try sender.send(try std.fmt.bufPrint(&line_buf, "bpm {d}", .{bpm}));
    for (track_specs, 1..) |spec, track| {
        _ = try sender.send(try std.fmt.bufPrint(&line_buf, "set {d} instrument {s}", .{ track, spec.instrument }));
        _ = try sender.send(try std.fmt.bufPrint(&line_buf, "set {d} gain {s}", .{ track, spec.gain }));
        _ = try sender.send(try std.fmt.bufPrint(&line_buf, "set {d} pan {s}", .{ track, spec.pan }));
        _ = try sender.send(try std.fmt.bufPrint(&line_buf, "eq {d} preset {s}", .{ track, spec.eq }));
    }

    _ = try sender.send(try std.fmt.bufPrint(&line_buf, "eq master tilt on", .{}));

    const song = build();
    var notes_sent: usize = 0;
    for (song.slice()) |n| {
        const line = try std.fmt.bufPrint(&line_buf, "note {d} {d} {d} {d} {d}", .{ n.track, n.pitch, n.start, n.length, n.velocity });
        if (try sender.send(line)) notes_sent += 1;
    }

    if (args.len == 1) {
        _ = try sender.send(try std.fmt.bufPrint(&line_buf, "save {s}", .{args[0]}));
    }

    try printOut(io, "notes sent: {d} of {d}; commands ok: {d}; failures: {d}\n", .{ notes_sent, song.len, sender.sent, sender.failed });
    return if (sender.failed == 0) 0 else 1;
}

test "arrangement has the expected note count per section" {
    const song = build();
    var counts = @as([5]usize, @splat(0));
    var per_track = @as([6]usize, @splat(0));
    for (song.slice()) |n| {
        const bar: u32 = @intFromFloat(n.start / beats_per_bar);
        counts[@backingInt(sectionAt(bar))] += 1;
        per_track[n.track] += 1;
    }
    // Per bar: pads 3. Verse/chorus add bass 8 + hats 8 + kick/snare 4 = 20.
    // Chorus adds lead 4. Intro/bridge add harp 8. Intro bars 4-7 add 4 hats.
    try std.testing.expectEqual(@as(usize, 8 * 3 + 8 * 8 + 4 * 4), counts[@backingInt(Section.intro)]);
    try std.testing.expectEqual(@as(usize, 32 * (3 + 20)), counts[@backingInt(Section.verse)]);
    try std.testing.expectEqual(@as(usize, 32 * (3 + 20 + 4)), counts[@backingInt(Section.chorus)]);
    try std.testing.expectEqual(@as(usize, 8 * (3 + 8)), counts[@backingInt(Section.bridge)]);
    try std.testing.expectEqual(@as(usize, 8 * 3), counts[@backingInt(Section.outro)]);
    try std.testing.expectEqual(@as(usize, 88 * 3), per_track[track_pads]);
    try std.testing.expectEqual(@as(usize, 64 * 8), per_track[track_bass]);
    try std.testing.expectEqual(@as(usize, 128), per_track[track_lead]);
}

test "track pans are within range and the kit's hat and tom pans stay in range" {
    for (track_specs) |spec| {
        const pan = try std.fmt.parseFloat(f32, spec.pan);
        try std.testing.expect(pan >= -1.0 and pan <= 1.0);
    }

    // Hats in song order alternate sides; each hat's final pan (track pan plus
    // the kit's hat pan) stays in [-1, 1].
    const drum_pan = try std.fmt.parseFloat(f32, track_specs[track_drums - 1].pan);
    var hat_index: u32 = 0;
    var last: f32 = 0.0;
    const song = build();
    for (song.slice()) |n| {
        if (n.track != track_drums or n.pitch != hat) continue;
        const kind = drum_kit.drumForNote(n.pitch).?;
        const pan = drum_kit.drumPan(kind, hat_index);
        try std.testing.expect(pan != 0.0);
        if (hat_index > 0) try std.testing.expect(pan * last < 0.0);
        try std.testing.expect(@abs(pan + drum_pan) <= 1.0);
        last = pan;
        hat_index += 1;
    }
    try std.testing.expect(hat_index > 0);

    const toms = [_]u8{ 41, 43, 45 };
    var prev: f32 = -1.0;
    for (toms) |note| {
        const pan = drum_kit.drumPan(drum_kit.drumForNote(note).?, 0);
        try std.testing.expect(pan >= -0.5 and pan <= 0.5);
        try std.testing.expect(pan > prev);
        prev = pan;
    }
}
