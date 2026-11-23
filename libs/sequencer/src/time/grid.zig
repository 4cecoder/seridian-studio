// Translated to Zig from soundcraft/crates/time/src/grid.rs, soundcraft/crates/time/tests/it/meter_grid_contract.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Grid and Nudge values: musical or absolute step sizes, grid lines and snapping.
//!
//! Every function here is pure arithmetic over a `tempo.View` and a `FrameRate`.
//! Pass `TempoMap.view()` on the control thread and `Snapshot.view()` on the audio
//! thread. Nothing here allocates except `GridValue.label`, which returns an owned
//! string (control thread only). `lines` writes into a caller-owned buffer, so it is
//! safe on the audio thread.
//!
//! Rust takes `&TempoMap`; here the functions take the borrowed `View` instead, so
//! the same code serves the editable map and the audio-thread snapshot.

const std = @import("std");
const time = @import("time.zig");
const tempo = @import("tempo.zig");
const timecode = @import("timecode.zig");

const Samples = time.Samples;
const SampleRate = time.SampleRate;
const toSamples = time.toSamples;
const TempoMap = tempo.TempoMap;
const View = tempo.View;
const FrameRate = timecode.FrameRate;
const ticks_per_quarter = tempo.ticks_per_quarter;

/// Rust `f as i64`: truncates toward zero, NaN becomes 0, out-of-range values saturate.
fn floatToI64(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    const hi: f64 = @floatFromInt(std.math.maxInt(i64));
    const lo: f64 = @floatFromInt(std.math.minInt(i64));
    if (v >= hi) return std.math.maxInt(i64);
    if (v <= lo) return std.math.minInt(i64);
    return @intFromFloat(v);
}

/// Frame-based grid steps are clamped to 1..=1_000_000 frames.
fn clampFrames(f: i64) i64 {
    return std.math.clamp(f, 1, 1_000_000);
}

/// The exact (fractional) Seconds step in samples, at least one sample.
fn secondsStep(s: f64, sr: SampleRate) f64 {
    return @max(std.math.clamp(s, 0.000_01, 3600.0) * sr.asF64(), 1.0);
}

/// Note values for Bars|Beats grids.
pub const NoteValue = enum {
    bar,
    half,
    quarter,
    eighth,
    sixteenth,
    thirty_second,
    sixty_fourth,

    pub const all = [_]NoteValue{ .bar, .half, .quarter, .eighth, .sixteenth, .thirty_second, .sixty_fourth };

    pub fn ticks(self: NoteValue) i64 {
        return switch (self) {
            .bar => ticks_per_quarter * 4,
            .half => ticks_per_quarter * 2,
            .quarter => ticks_per_quarter,
            .eighth => ticks_per_quarter / 2,
            .sixteenth => ticks_per_quarter / 4,
            .thirty_second => ticks_per_quarter / 8,
            .sixty_fourth => ticks_per_quarter / 16,
        };
    }

    pub fn label(self: NoteValue) []const u8 {
        return switch (self) {
            .bar => "1 bar",
            .half => "1/2 note",
            .quarter => "1/4 note",
            .eighth => "1/8 note",
            .sixteenth => "1/16 note",
            .thirty_second => "1/32 note",
            .sixty_fourth => "1/64 note",
        };
    }
};

/// A musical grid step: a note value, optionally dotted or triplet.
pub const Note = struct {
    value: NoteValue,
    dotted: bool = false,
    triplet: bool = false,
};

/// A grid or nudge step.
pub const GridValue = union(enum) {
    /// Musical: note value, optionally dotted or triplet.
    note: Note,
    /// Absolute seconds (Min:Secs grids: 0.001 ... 10 s).
    seconds: f64,
    /// Frames at the session timecode rate.
    frames: i64,
    /// Raw samples.
    samples: i64,

    pub const default: GridValue = .{ .note = .{ .value = .sixteenth, .dotted = false, .triplet = false } };

    /// Human label. Returns an owned string built with `gpa` (control thread only).
    pub fn label(self: GridValue, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .note => |n| std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
                n.value.label(),
                if (n.dotted) " dotted" else "",
                if (n.triplet) " triplet" else "",
            }),
            .seconds => |s| std.fmt.allocPrint(gpa, "{d:.3} sec", .{s}),
            .frames => |f| std.fmt.allocPrint(gpa, "{d} frame{s}", .{ f, if (f == 1) "" else "s" }),
            .samples => |n| std.fmt.allocPrint(gpa, "{d} samples", .{n}),
        };
    }

    /// The next larger or smaller value of the same kind, or `self` at either end.
    /// Note values keep their dot or triplet; seconds, frames and samples step along
    /// fixed ladders.
    pub fn stepped(self: GridValue, larger: bool) GridValue {
        return switch (self) {
            .note => |n| blk: {
                const i: usize = std.mem.indexOfScalar(NoteValue, &NoteValue.all, n.value) orelse 0;
                const j: ?usize = if (larger) (if (i == 0) null else i - 1) else i + 1;
                if (j) |jj| {
                    if (jj < NoteValue.all.len) break :blk .{ .note = .{ .value = NoteValue.all[jj], .dotted = n.dotted, .triplet = n.triplet } };
                }
                break :blk self;
            },
            .seconds => |s| if (nextInLadder(f64, &[_]f64{ 0.001, 0.01, 0.1, 1.0, 10.0 }, s, larger)) |v| .{ .seconds = v } else self,
            .frames => |f| if (nextInLadder(i64, &[_]i64{ 1, 10, 100 }, f, larger)) |v| .{ .frames = v } else self,
            .samples => |n| if (nextInLadder(i64, &[_]i64{ 1, 10, 100, 1_000, 10_000, 100_000 }, n, larger)) |v| .{ .samples = v } else self,
        };
    }

    /// The step in samples at position `at` (musical steps depend on tempo).
    pub fn stepSamples(self: GridValue, at: Samples, sr: SampleRate, map: View, rate: FrameRate) Samples {
        return switch (self) {
            .note => |n| blk: {
                const t0 = map.samplesToTicks(at, sr);
                const dt = noteTicks(n.value, n.dotted, n.triplet, map, t0);
                break :blk @max(map.tickToSamples(t0 + dt, sr) - map.tickToSamples(t0, sr), 1);
            },
            .seconds => |s| @max(sr.samples(std.math.clamp(s, 0.000_01, 3600.0)), 1),
            .frames => |f| @max(toSamples(rate.samplesPerFrame(sr) * @as(f64, @floatFromInt(clampFrames(f)))), 1),
            .samples => |n| @max(n, 1),
        };
    }

    /// Nearest grid line to `pos`.
    pub fn snap(self: GridValue, pos: Samples, sr: SampleRate, map: View, rate: FrameRate) Samples {
        const lo = self.lineAtOrBefore(pos, sr, map, rate);
        const hi = self.nextLine(lo, sr, map, rate);
        return if ((pos - lo) <= (hi - pos)) lo else hi;
    }

    /// The grid line at or before `pos`.
    pub fn lineAtOrBefore(self: GridValue, pos: Samples, sr: SampleRate, map: View, rate: FrameRate) Samples {
        switch (self) {
            .note => |n| {
                // Float ticks can land a hair either side of a line's own tick.
                var t = floatToI64(@floor(map.samplesToTicksF(pos, sr)));
                if (map.tickToSamples(t, sr) > pos) {
                    t -|= 1;
                } else if (map.tickToSamples(t +| 1, sr) <= pos) {
                    t +|= 1;
                }
                // Grid lines restart at each bar line so odd meters stay aligned.
                const bb = map.barBeatAtTick(t);
                const bar_tick = map.barStartTick(bb.bar);
                const step = noteTicks(n.value, n.dotted, n.triplet, map, bar_tick);
                const k = @divFloor(t - bar_tick, step);
                return map.tickToSamples(bar_tick + k * step, sr);
            },
            else => return self.absLine(self.absIndexAtOrBefore(pos, sr, rate), sr, rate),
        }
    }

    /// The first grid line strictly after `line`.
    pub fn nextLine(self: GridValue, line: Samples, sr: SampleRate, map: View, rate: FrameRate) Samples {
        switch (self) {
            .note => {
                const step = self.stepSamples(line, sr, map, rate);
                const candidate = self.lineAtOrBefore(line +| step, sr, map, rate);
                return if (candidate > line) candidate else line +| step;
            },
            else => {
                const next = self.absLine(self.absIndexAtOrBefore(line, sr, rate) +| 1, sr, rate);
                return if (next > line) next else line +| 1;
            },
        }
    }

    /// All grid lines within `[start, end)`. Writes into `out` and returns how many were
    /// written; at most `out.len` lines (Rust's `max`). Allocation free.
    pub fn lines(self: GridValue, start: Samples, end: Samples, sr: SampleRate, map: View, rate: FrameRate, out: []Samples) usize {
        var n: usize = 0;
        var p = self.lineAtOrBefore(start, sr, map, rate);
        while (p < end and n < out.len) {
            if (p >= start) {
                out[n] = p;
                n += 1;
            }
            const next = self.nextLine(p, sr, map, rate);
            if (next <= p) break;
            p = next;
        }
        return n;
    }

    /// Position of absolute grid line `k` (Seconds, Frames, Samples), at an exact multiple of
    /// the step rounded once, so rounding never accumulates from line to line.
    fn absLine(self: GridValue, k: i64, sr: SampleRate, rate: FrameRate) Samples {
        return switch (self) {
            .seconds => |s| toSamples(@as(f64, @floatFromInt(k)) * secondsStep(s, sr)),
            .frames => |f| rate.samplesAtFrame(k *| clampFrames(f), sr),
            .samples => |n| k *| @max(n, 1),
            .note => 0,
        };
    }

    /// Index of the absolute grid line at or before `pos`.
    fn absIndexAtOrBefore(self: GridValue, pos: Samples, sr: SampleRate, rate: FrameRate) i64 {
        var k: i64 = switch (self) {
            .seconds => |s| floatToI64(@floor(@as(f64, @floatFromInt(pos)) / secondsStep(s, sr))),
            .frames => |f| @divFloor(rate.framesAt(pos, sr), clampFrames(f)),
            .samples => |n| return @divFloor(pos, @max(n, 1)),
            .note => return 0,
        };
        // Lines are rounded to whole samples, so the floored index can be one off either way.
        if (self.absLine(k, sr, rate) > pos) {
            k -|= 1;
        } else if (self.absLine(k +| 1, sr, rate) <= pos) {
            k +|= 1;
        }
        return k;
    }
};

/// Ticks in one step of `value` at `at_tick`. Bars follow the meter in effect there.
fn noteTicks(value: NoteValue, dotted: bool, triplet: bool, map: View, at_tick: i64) i64 {
    const base: i64 = if (value == .bar) map.meterAtTick(at_tick).ticksPerBar() else value.ticks();
    var t = base;
    if (dotted) t = @divTrunc(t * 3, 2);
    if (triplet) t = @divTrunc(t * 2, 3);
    return @max(t, 1);
}

/// The next element of an ascending ladder strictly above `v` (or strictly below, when
/// `larger` is false), or null at either end.
fn nextInLadder(comptime T: type, ladder: []const T, v: T, larger: bool) ?T {
    if (larger) {
        for (ladder) |x| {
            if (x > v) return x;
        }
        return null;
    }
    var i: usize = ladder.len;
    while (i > 0) {
        i -= 1;
        if (ladder[i] < v) return ladder[i];
    }
    return null;
}

// --- tests -----------------------------------------------------------------

fn noteGrid(value: NoteValue, dotted: bool, triplet: bool) GridValue {
    return .{ .note = .{ .value = value, .dotted = dotted, .triplet = triplet } };
}

const MeterBar = struct { bar: i64, numerator: u32, denominator: u32 };

/// The meters of `map` as (bar, numerator, denominator). Every meter must sit on a bar line.
fn expectMeterBars(map: *const TempoMap, want: []const MeterBar) !void {
    var got: [16]MeterBar = undefined;
    var n: usize = 0;
    for (map.meters()) |m| {
        const bb = map.barBeatAtTick(m.tick);
        try std.testing.expectEqual(@as(i64, 1), bb.beat);
        try std.testing.expectEqual(@as(i64, 0), bb.tick);
        got[n] = .{ .bar = bb.bar, .numerator = m.numerator, .denominator = m.denominator };
        n += 1;
    }
    try std.testing.expectEqualSlices(MeterBar, want, got[0..n]);
}

/// Every beat of every bar 1..=5 round-trips through tick and bar|beat.
fn expectPositionsRoundTrip(map: *const TempoMap) !void {
    var bar: i64 = 1;
    while (bar <= 5) : (bar += 1) {
        const meter = map.meterAtTick(map.barStartTick(bar));
        var beat: i64 = 1;
        while (beat <= @as(i64, meter.numerator)) : (beat += 1) {
            const position = tempo.BarBeat{ .bar = bar, .beat = beat, .tick = 0 };
            try std.testing.expectEqual(position, map.barBeatAtTick(map.tickAtBarBeat(position)));
        }
    }
}

fn meterTickWithNumerator(map: *const TempoMap, numerator: u32) ?i64 {
    for (map.meters()) |m| {
        if (m.numerator == numerator) return m.tick;
    }
    return null;
}

test "grid lines are their own line at odd tempos" {
    const gpa = std.testing.allocator;
    const g = GridValue.default;
    const sr = SampleRate.hz_48000;
    for ([_]f64{ 90.0, 95.0, 110.0, 130.0, 140.0 }) |bpm| {
        var map = try TempoMap.init(gpa, bpm, 4, 4);
        defer map.deinit(gpa);
        var line: Samples = 0;
        for (0..64) |_| {
            try std.testing.expectEqual(line, g.lineAtOrBefore(line, sr, map.view(), .fps_30));
            line = g.nextLine(line, sr, map.view(), .fps_30);
        }
    }
}

test "sixteenth grid at 120" {
    const gpa = std.testing.allocator;
    const g = GridValue.default;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    try std.testing.expectEqual(@as(Samples, 6000), g.stepSamples(0, sr, v, .fps_30));
    try std.testing.expectEqual(@as(Samples, 0), g.snap(2900, sr, v, .fps_30));
    try std.testing.expectEqual(@as(Samples, 6000), g.snap(3100, sr, v, .fps_30));
    var buf: [100]Samples = undefined;
    const n = g.lines(0, 24_000, sr, v, .fps_30, &buf);
    const want = [_]Samples{ 0, 6000, 12000, 18000 };
    try std.testing.expectEqualSlices(Samples, &want, buf[0..n]);
}

test "absolute grids" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_25;
    try std.testing.expectEqual(@as(Samples, 48_000), (GridValue{ .seconds = 1.0 }).snap(70_000, sr, v, rate));
    try std.testing.expectEqual(@as(Samples, 1920), (GridValue{ .frames = 1 }).stepSamples(0, sr, v, rate));
    try std.testing.expectEqual(@as(Samples, 1), (GridValue{ .samples = 0 }).stepSamples(0, sr, v, rate));
}

test "seconds grid lines land on whole seconds" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_44100;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    for ([_]f64{ 0.001, 0.01 }) |secs| {
        const g = GridValue{ .seconds = secs };
        var n: Samples = 0;
        while (n < 20) : (n += 1) {
            const s = n * 44_100;
            try std.testing.expectEqual(s, g.snap(s, sr, v, .fps_30));
            try std.testing.expectEqual(s, g.lineAtOrBefore(s, sr, v, .fps_30));
        }
    }
}

test "frame grid lines land on frame starts" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    for ([_]FrameRate{ .fps_29_97, .fps_23_976 }) |rate| {
        for ([_]i64{ 1, 10 }) |f| {
            const g = GridValue{ .frames = f };
            var k: i64 = 0;
            while (k < 5000) : (k += 37) {
                const s = rate.samplesAtFrame(k, sr);
                const line = rate.samplesAtFrame(@divFloor(k, f) * f, sr);
                try std.testing.expectEqual(line, g.lineAtOrBefore(s, sr, v, rate));
                if (@rem(k, f) == 0) {
                    try std.testing.expectEqual(s, g.snap(s, sr, v, rate));
                }
            }
            const start = rate.samplesAtFrame(4000, sr);
            const end = rate.samplesAtFrame(4000 + 20 * f, sr);
            var want: [20]Samples = undefined;
            for (&want, 0..) |*w, i| {
                w.* = rate.samplesAtFrame(4000 + @as(i64, @intCast(i)) * f, sr);
            }
            var buf: [100]Samples = undefined;
            const n = g.lines(start, end, sr, v, rate, &buf);
            try std.testing.expectEqualSlices(Samples, &want, buf[0..n]);
        }
    }
}

test "lines are capped" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    var buf: [50]Samples = undefined;
    const n = (GridValue{ .samples = 1 }).lines(0, 1_000_000, sr, map.view(), .fps_25, &buf);
    try std.testing.expectEqual(@as(usize, 50), n);
}

test "triplets and dots" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const t = noteGrid(.quarter, false, true);
    try std.testing.expectEqual(@as(Samples, 16_000), t.stepSamples(0, sr, v, .fps_25));
    const d = noteGrid(.quarter, true, false);
    try std.testing.expectEqual(@as(Samples, 36_000), d.stepSamples(0, sr, v, .fps_25));
}

test "values step to the next larger or smaller" {
    try std.testing.expectEqual(noteGrid(.eighth, false, false), noteGrid(.sixteenth, false, false).stepped(true));
    try std.testing.expectEqual(noteGrid(.sixteenth, false, true), noteGrid(.eighth, false, true).stepped(false));
    try std.testing.expectEqual(noteGrid(.bar, false, false), noteGrid(.bar, false, false).stepped(true));
    try std.testing.expectEqual(noteGrid(.sixty_fourth, false, false), noteGrid(.sixty_fourth, false, false).stepped(false));
    try std.testing.expectEqual(GridValue{ .seconds = 0.1 }, (GridValue{ .seconds = 0.01 }).stepped(true));
    try std.testing.expectEqual(GridValue{ .seconds = 0.1 }, (GridValue{ .seconds = 0.5 }).stepped(false));
    try std.testing.expectEqual(GridValue{ .seconds = 10.0 }, (GridValue{ .seconds = 10.0 }).stepped(true));
    try std.testing.expectEqual(GridValue{ .frames = 10 }, (GridValue{ .frames = 1 }).stepped(true));
    try std.testing.expectEqual(GridValue{ .samples = 10 }, (GridValue{ .samples = 100 }).stepped(false));
    try std.testing.expectEqual(GridValue{ .samples = 1 }, (GridValue{ .samples = 1 }).stepped(false));
}

test "earlier meter edit preserves bar positions" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const at = map.samplesToTicks(192_000, sr);
    try std.testing.expectEqual(@as(i64, 7680), at);
    try map.setMeter(gpa, at, 3, 4);
    try expectPositionsRoundTrip(&map);
    try map.setMeter(gpa, 0, 6, 4);
    try expectPositionsRoundTrip(&map);
    // The 3/4 change stays at bar 3, now two 6/4 bars in.
    try expectMeterBars(&map, &[_]MeterBar{ .{ .bar = 1, .numerator = 6, .denominator = 4 }, .{ .bar = 3, .numerator = 3, .denominator = 4 } });
    try std.testing.expectEqual(@as(i64, 2 * 5760), map.meters()[1].tick);
}

test "inserting and removing meters keeps later bars" {
    const gpa = std.testing.allocator;
    var map = try TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    try map.setMeter(gpa, map.barStartTick(5), 5, 4);
    try map.setMeter(gpa, map.barStartTick(3), 3, 4);
    try expectMeterBars(&map, &[_]MeterBar{
        .{ .bar = 1, .numerator = 4, .denominator = 4 },
        .{ .bar = 3, .numerator = 3, .denominator = 4 },
        .{ .bar = 5, .numerator = 5, .denominator = 4 },
    });
    // Inserting 7/8 at bar 2 keeps 3/4 at bar 3 and 5/4 at bar 5.
    try map.setMeter(gpa, map.barStartTick(2), 7, 8);
    try expectMeterBars(&map, &[_]MeterBar{
        .{ .bar = 1, .numerator = 4, .denominator = 4 },
        .{ .bar = 2, .numerator = 7, .denominator = 8 },
        .{ .bar = 3, .numerator = 3, .denominator = 4 },
        .{ .bar = 5, .numerator = 5, .denominator = 4 },
    });
    try expectPositionsRoundTrip(&map);
    // Removing 3/4 leaves 5/4 at bar 5.
    const three_four = meterTickWithNumerator(&map, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try map.removeMeter(gpa, three_four));
    try expectMeterBars(&map, &[_]MeterBar{
        .{ .bar = 1, .numerator = 4, .denominator = 4 },
        .{ .bar = 2, .numerator = 7, .denominator = 8 },
        .{ .bar = 5, .numerator = 5, .denominator = 4 },
    });
    try expectPositionsRoundTrip(&map);
}

test "initial meter first and restoring controls" {
    const gpa = std.testing.allocator;
    // Setting the initial meter first, then the later change at the same raw tick, snaps to a bar line.
    {
        var map = try TempoMap.initDefault(gpa);
        defer map.deinit(gpa);
        try map.setMeter(gpa, 0, 6, 4);
        try map.setMeter(gpa, 7680, 3, 4);
        try std.testing.expect(map.meters().len >= 2);
        try std.testing.expectEqual(tempo.MeterEvent{ .tick = 5760, .numerator = 3, .denominator = 4 }, map.meters()[1]);
        try expectPositionsRoundTrip(&map);
    }
    // Restoring 4/4 after the edit puts the 3/4 change back where it started.
    {
        var map = try TempoMap.initDefault(gpa);
        defer map.deinit(gpa);
        try map.setMeter(gpa, 7680, 3, 4);
        try map.setMeter(gpa, 0, 6, 4);
        try map.setMeter(gpa, 0, 4, 4);
        try std.testing.expect(map.meters().len >= 2);
        try std.testing.expectEqual(tempo.MeterEvent{ .tick = 7680, .numerator = 3, .denominator = 4 }, map.meters()[1]);
        try expectPositionsRoundTrip(&map);
    }
}
