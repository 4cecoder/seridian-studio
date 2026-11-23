// Translated to Zig from soundcraft/crates/time/src/format.rs, soundcraft/crates/time/tests/it/min_secs_exact_ms.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Formatting and parsing positions in the five timebases.
//!
//! `formatPosition` and `formatLength` return owned strings built with the caller's
//! allocator (control thread: counters and rulers). `parsePosition` is allocation
//! free. Nothing here is called from the audio thread.
//!
//! Integers are padded by hand (`Writer.int`) instead of with a `{d:0>2}` width
//! specifier: this toolchain prints a `+` for width-specified integers.

const std = @import("std");
const time = @import("time.zig");
const tempo = @import("tempo.zig");
const timecode = @import("timecode.zig");

const Samples = time.Samples;
const SampleRate = time.SampleRate;
const TimeError = time.TimeError;
const FrameRate = timecode.FrameRate;
const Timecode = timecode.Timecode;
const View = tempo.View;

/// The counters' and rulers' timebases.
pub const TimeFormat = enum {
    bars_beats,
    min_secs,
    timecode,
    feet_frames,
    samples,

    pub const default: TimeFormat = .min_secs;

    pub const all = [_]TimeFormat{ .bars_beats, .min_secs, .timecode, .feet_frames, .samples };

    pub fn label(self: TimeFormat) []const u8 {
        return switch (self) {
            .bars_beats => "Bars|Beats",
            .min_secs => "Min:Secs",
            .timecode => "Timecode",
            .feet_frames => "Feet+Frames",
            .samples => "Samples",
        };
    }

    pub fn id(self: TimeFormat) []const u8 {
        return switch (self) {
            .bars_beats => "bars_beats",
            .min_secs => "min_secs",
            .timecode => "timecode",
            .feet_frames => "feet_frames",
            .samples => "samples",
        };
    }

    /// Match by id (exact) or by label (ASCII case-insensitive).
    pub fn fromId(text: []const u8) ?TimeFormat {
        for (all) |f| {
            if (std.mem.eql(u8, f.id(), text) or std.ascii.eqlIgnoreCase(f.label(), text)) return f;
        }
        return null;
    }
};

/// Fixed-capacity text builder for the formatters. Every output is far below `cap`.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn str(self: *Writer, s: []const u8) void {
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    /// Rust `{:0width$}` for an i64: the sign comes first, then zeros up to `width`
    /// characters. Written by hand because of the `+` quirk noted in the header.
    fn int(self: *Writer, v: i64, width: usize) void {
        var tmp: [24]u8 = undefined;
        const digits = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        const sign: usize = if (v < 0) 1 else 0;
        if (sign == 1) self.str("-");
        var zeros: usize = if (digits.len < width) width - digits.len else 0;
        while (zeros > 0) : (zeros -= 1) self.str("0");
        self.str(digits[sign..]);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Min:Secs text for `s`, written into `buf` (at least 64 bytes). Integer maths: a float
/// `seconds * 1000` lands just below exact millisecond positions.
fn minSecsText(buf: []u8, s: Samples, sr: SampleRate) []const u8 {
    const wide: i128 = s;
    const mag: i128 = if (wide < 0) -wide else wide;
    const hz: i128 = @max(@as(i128, sr.hz()), 1);
    const ms_total: i64 = std.math.cast(i64, @divTrunc(mag * 1000, hz)) orelse std.math.maxInt(i64);
    var w = Writer{ .buf = buf };
    if (s < 0) w.str("-");
    w.int(@divTrunc(ms_total, 60_000), 0);
    w.str(":");
    w.int(@rem(@divTrunc(ms_total, 1000), 60), 2);
    w.str(".");
    w.int(@rem(ms_total, 1000), 3);
    return w.slice();
}

/// Format an absolute position. `tc_start` is the timecode of sample 0 in samples,
/// `ff_start` the feet+frames reading of sample 0 in frames. Owned result.
pub fn formatPosition(
    gpa: std.mem.Allocator,
    s: Samples,
    fmt: TimeFormat,
    sr: SampleRate,
    map: View,
    rate: FrameRate,
    tc_start: Samples,
    ff_start: i64,
) std.mem.Allocator.Error![]u8 {
    var buf: [128]u8 = undefined;
    switch (fmt) {
        .samples => {
            var w = Writer{ .buf = &buf };
            w.int(s, 0);
            return gpa.dupe(u8, w.slice());
        },
        .min_secs => {
            var b: [64]u8 = undefined;
            return gpa.dupe(u8, minSecsText(&b, s, sr));
        },
        .timecode => return Timecode.fromSamples(s +| tc_start, rate, sr).format(rate, gpa),
        .feet_frames => {
            const ff = timecode.feetFrames(s, rate, sr, ff_start);
            var w = Writer{ .buf = &buf };
            w.int(ff.feet, 0);
            w.str("+");
            w.int(ff.frames, 2);
            return gpa.dupe(u8, w.slice());
        },
        .bars_beats => {
            const bb = map.barBeatAt(s, sr);
            var w = Writer{ .buf = &buf };
            w.int(bb.bar, 0);
            w.str("| ");
            w.int(bb.beat, 0);
            w.str("| ");
            w.int(bb.tick, 3);
            return gpa.dupe(u8, w.slice());
        },
    }
}

/// Format a length starting at `start` (Bars|Beats lengths count from 0|0|000).
/// Timecode and the other formats read the length itself, not a position. Owned result.
pub fn formatLength(
    gpa: std.mem.Allocator,
    start: Samples,
    len: Samples,
    fmt: TimeFormat,
    sr: SampleRate,
    map: View,
    rate: FrameRate,
) std.mem.Allocator.Error![]u8 {
    switch (fmt) {
        .bars_beats => {
            const t0 = map.samplesToTicks(start, sr);
            const t1 = map.samplesToTicks(start +| len, sr);
            const m = map.meterAtTick(t0);
            const d = @max(t1 - t0, 0);
            const per_bar = @max(m.ticksPerBar(), 1);
            const per_beat = @max(m.ticksPerBeat(), 1);
            const bars = @divTrunc(d, per_bar);
            const rem = @rem(d, per_bar);
            var buf: [128]u8 = undefined;
            var w = Writer{ .buf = &buf };
            w.int(bars, 0);
            w.str("| ");
            w.int(@divTrunc(rem, per_beat), 0);
            w.str("| ");
            w.int(@rem(rem, per_beat), 3);
            return gpa.dupe(u8, w.slice());
        },
        .timecode => return Timecode.fromSamples(len, rate, sr).format(rate, gpa),
        else => return formatPosition(gpa, len, fmt, sr, map, rate, 0, 0),
    }
}

/// Parse a plain i64 the way Rust's `str::parse::<i64>` does after `replace([',', '_'], "")`:
/// an optional sign, then digits, with ',' and '_' ignored anywhere. Allocation free.
fn parseSamplesText(t: []const u8) TimeError!Samples {
    var rest = t;
    var neg = false;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        neg = rest[0] == '-';
        rest = rest[1..];
    }
    var acc: u128 = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c == ',' or c == '_') continue;
        if (c < '0' or c > '9') return error.Parse;
        // Past 2^64 the value cannot fit in an i64 whatever follows, so stop early.
        if (acc > std.math.maxInt(u64)) return error.Parse;
        acc = acc * 10 + (c - '0');
        digits += 1;
    }
    if (digits == 0) return error.Parse;
    const signed: i128 = if (neg) -@as(i128, @intCast(acc)) else @as(i128, @intCast(acc));
    return std.math.cast(Samples, signed) orelse error.Parse;
}

/// Parse a Min:Secs value: optional leading '-', then `secs` or `min:secs`, fractions allowed.
fn parseMinSecs(t: []const u8, sr: SampleRate) TimeError!Samples {
    const neg = std.mem.startsWith(u8, t, "-");
    const body = if (neg) t[1..] else t;
    var m: f64 = 0.0;
    var s: f64 = undefined;
    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        m = try parseFloatText(body[0..colon]);
        s = try parseFloatText(body[colon + 1 ..]);
    } else {
        s = try parseFloatText(body);
    }
    if (!std.math.isFinite(m) or !std.math.isFinite(s) or m < 0.0 or s < 0.0) return error.Parse;
    const v = sr.samples(m * 60.0 + s);
    return if (neg) -v else v;
}

fn parseFloatText(text: []const u8) TimeError!f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, text, &std.ascii.whitespace)) catch error.Parse;
}

fn parseIntText(text: []const u8) TimeError!i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, &std.ascii.whitespace), 10) catch error.Parse;
}

/// Parse a position typed into a counter or dialog. `tc_start` and `ff_start` mean the
/// same as in `formatPosition`. Errors carry no payload: callers that need the offending
/// text must keep their own copy of the input.
pub fn parsePosition(
    text: []const u8,
    fmt: TimeFormat,
    sr: SampleRate,
    map: View,
    rate: FrameRate,
    tc_start: Samples,
    ff_start: i64,
) TimeError!Samples {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    switch (fmt) {
        .samples => return parseSamplesText(t),
        .min_secs => return parseMinSecs(t, sr),
        .timecode => {
            const tc = try Timecode.parse(t);
            if (tc.minutes >= 60 or tc.seconds >= 60 or tc.frames >= @max(rate.nominal(), 1)) return error.Parse;
            return tc.toSamples(rate, sr) -| tc_start;
        },
        .feet_frames => {
            const plus = std.mem.indexOfScalar(u8, t, '+') orelse return error.Parse;
            const ft = try parseIntText(t[0..plus]);
            const fr = try parseIntText(t[plus + 1 ..]);
            return rate.samplesAtFrame((ft *| 16) +| fr -| ff_start, sr);
        },
        .bars_beats => {
            var parts = [_]i64{ 0, 0, 0 };
            var count: usize = 0;
            var it = std.mem.tokenizeAny(u8, t, "|. ");
            while (it.next()) |tok| {
                const v = std.fmt.parseInt(i64, tok, 10) catch return error.Parse;
                if (count < parts.len) parts[count] = v;
                count += 1;
            }
            if (count == 0) return error.Parse;
            const bb = tempo.BarBeat{
                .bar = parts[0],
                .beat = if (count > 1) @max(parts[1], 1) else 1,
                .tick = if (count > 2) @max(parts[2], 0) else 0,
            };
            return map.samplesAtBarBeat(bb, sr);
        },
    }
}

// --- tests -----------------------------------------------------------------

fn expectFormatted(want: []const u8, s: Samples, fmt: TimeFormat, sr: SampleRate, map: View, rate: FrameRate) !void {
    const got = try formatPosition(std.testing.allocator, s, fmt, sr, map, rate, 0, 0);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "huge typed positions parse without overflowing" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const rate = FrameRate.fps_30;
    const cases = [_]struct { text: []const u8, fmt: TimeFormat }{
        .{ .text = "999999999999999999:0", .fmt = .timecode },
        .{ .text = "100000000000000:00:00:00", .fmt = .timecode },
        .{ .text = "-9223372036854775808", .fmt = .bars_beats },
    };
    for (cases) |c| {
        // The point is that none of these panics; the result is ignored, as in Rust.
        _ = parsePosition(c.text, c.fmt, sr, map.view(), rate, 0, 0) catch {};
    }
}

test "formats like Pro Tools counters" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_30;
    try expectFormatted("0:00.000", 0, .min_secs, sr, v, rate);
    try expectFormatted("1:15.500", 48_000 * 75 + 24_000, .min_secs, sr, v, rate);
    try expectFormatted("1| 1| 000", 0, .bars_beats, sr, v, rate);
    try expectFormatted("00:00:01:00", 48_000, .timecode, sr, v, rate);
    try expectFormatted("12345", 12345, .samples, sr, v, rate);
}

test "minimum bar parses without overflow" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_30;
    const p = struct {
        fn parse(text: []const u8, view: View, r: SampleRate, f: FrameRate) TimeError!Samples {
            return parsePosition(text, .bars_beats, r, view, f, 0, 0);
        }
    }.parse;
    const min_bar = try p("-9223372036854775808|01|000", v, sr, rate);
    try std.testing.expect(min_bar < 0);
    try std.testing.expectEqual(@as(Samples, 144_000), try p("2|3|000", v, sr, rate));
    try std.testing.expectEqual(@as(Samples, -96_000), try p("0|1|000", v, sr, rate));
}

test "parse round trips" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_30;
    for (TimeFormat.all) |fmt| {
        for ([_]Samples{ 0, 48_000, 96_000 * 3, 1_440_000 }) |s| {
            const text = try formatPosition(gpa, s, fmt, sr, v, rate, 0, 0);
            defer gpa.free(text);
            const back = try parsePosition(text, fmt, sr, v, rate, 0, 0);
            try std.testing.expect(@abs(back - s) <= 48);
        }
    }
}

test "parse round trips timecode negative" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_25;
    for ([_]TimeFormat{ .timecode, .feet_frames }) |fmt| {
        for ([_]Samples{ -48_000, -96_000 * 3, -1_440_000 }) |s| {
            const text = try formatPosition(gpa, s, fmt, sr, v, rate, 0, 0);
            defer gpa.free(text);
            const back = try parsePosition(text, fmt, sr, v, rate, 0, 0);
            try std.testing.expectEqual(s, back);
        }
    }
}

test "parse rejects garbage" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const v = map.view();
    const rate = FrameRate.fps_30;
    try std.testing.expectError(error.Parse, parsePosition("abc", .samples, sr, v, rate, 0, 0));
    try std.testing.expectError(error.Parse, parsePosition("1:x", .min_secs, sr, v, rate, 0, 0));
    try std.testing.expectError(error.Parse, parsePosition("", .bars_beats, sr, v, rate, 0, 0));
}

test "bar lengths" {
    const gpa = std.testing.allocator;
    const sr = SampleRate.hz_48000;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    const got = try formatLength(gpa, 0, 96_000 + 24_000, .bars_beats, sr, map.view(), FrameRate.fps_30);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("1| 1| 000", got);
}

// Integration test ported from tests/it/min_secs_exact_ms.rs: Min:Secs shows exact
// millisecond positions exactly (no float-floor off-by-one).

fn minSecsAt(s: Samples, sr: SampleRate) ![]u8 {
    var map = try tempo.TempoMap.initDefault(std.testing.allocator);
    defer map.deinit(std.testing.allocator);
    return formatPosition(std.testing.allocator, s, .min_secs, sr, map.view(), FrameRate.default, 0, 0);
}

test "min:secs known positions at 44100" {
    const sr = SampleRate.hz_44100;
    const a = try minSecsAt(88_641, sr);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("0:02.010", a);
    const b = try minSecsAt(89_523, sr);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("0:02.030", b);
}

test "min:secs negative position at 44100" {
    const got = try minSecsAt(-88_641, SampleRate.hz_44100);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("-0:02.010", got);
}

test "min:secs every exact millisecond displays exactly" {
    const gpa = std.testing.allocator;
    var map = try tempo.TempoMap.initDefault(gpa);
    defer map.deinit(gpa);
    for ([_]SampleRate{ SampleRate.hz_44100, SampleRate.hz_48000 }) |sr| {
        const hz: i64 = sr.hz();
        var ms: i64 = 0;
        while (ms <= 600_000) : (ms += 1) {
            if (@rem(ms * hz, 1000) != 0) continue;
            const s = @divTrunc(ms * hz, 1000);
            // A fixed buffer keeps the sweep (about 660k positions) off the debug
            // allocator, which records a stack trace per allocation.
            var store: [64]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&store);
            const got = try formatPosition(fba.allocator(), s, .min_secs, sr, map.view(), FrameRate.default, 0, 0);
            // Oracle: whole minutes, seconds padded to two digits, milliseconds to three.
            const mins = @divTrunc(ms, 60_000);
            const secs = @rem(@divTrunc(ms, 1000), 60);
            const frac = @rem(ms, 1000);
            var want_buf: [64]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "{d}:{s}{d}.{s}{d}", .{
                mins,
                if (secs < 10) "0" else "",
                secs,
                if (frac < 100) (if (frac < 10) "00" else "0") else "",
                frac,
            });
            try std.testing.expectEqualStrings(want, got);
        }
    }
}
