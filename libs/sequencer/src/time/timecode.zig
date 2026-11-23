// Translated to Zig from soundcraft/crates/time/src/timecode.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! SMPTE timecode and Feet+Frames.
//!
//! Pure arithmetic: no allocation except `Timecode.format`, which returns an owned
//! string built with the allocator the caller passes (control thread, not audio).
//! Drop-frame arithmetic is done in i128 so extreme frame counts never overflow.

const std = @import("std");
const time = @import("time.zig");

const Samples = time.Samples;
const SampleRate = time.SampleRate;
const TimeError = time.TimeError;

/// Session timecode rates.
pub const FrameRate = enum {
    fps_23_976,
    fps_24,
    fps_25,
    fps_29_97,
    fps_29_97_drop,
    fps_30,
    fps_47_952,
    fps_48,
    fps_50,
    fps_59_94,
    fps_59_94_drop,
    fps_60,
    fps_100,
    fps_119_88,
    fps_120,

    pub const default: FrameRate = .fps_24;

    /// Every rate, in the Rust `FrameRate::ALL` order.
    pub const all = [_]FrameRate{
        .fps_23_976,     .fps_24,     .fps_25,  .fps_29_97,  .fps_29_97_drop,
        .fps_30,         .fps_47_952, .fps_48,  .fps_50,     .fps_59_94,
        .fps_59_94_drop, .fps_60,     .fps_100, .fps_119_88, .fps_120,
    };

    /// A rational frame rate: `num / den` frames per second.
    pub const Rational = struct { num: i64, den: i64 };

    /// Real frames per second as a rational.
    pub fn rational(self: FrameRate) Rational {
        return switch (self) {
            .fps_23_976 => .{ .num = 24_000, .den = 1001 },
            .fps_24 => .{ .num = 24, .den = 1 },
            .fps_25 => .{ .num = 25, .den = 1 },
            .fps_29_97, .fps_29_97_drop => .{ .num = 30_000, .den = 1001 },
            .fps_30 => .{ .num = 30, .den = 1 },
            .fps_47_952 => .{ .num = 48_000, .den = 1001 },
            .fps_48 => .{ .num = 48, .den = 1 },
            .fps_50 => .{ .num = 50, .den = 1 },
            .fps_59_94, .fps_59_94_drop => .{ .num = 60_000, .den = 1001 },
            .fps_60 => .{ .num = 60, .den = 1 },
            .fps_100 => .{ .num = 100, .den = 1 },
            .fps_119_88 => .{ .num = 120_000, .den = 1001 },
            .fps_120 => .{ .num = 120, .den = 1 },
        };
    }

    /// Frames per labelled second (the counting base), rounded to nearest.
    pub fn nominal(self: FrameRate) i64 {
        const r = self.rational();
        return @divTrunc(r.num + @divTrunc(r.den, 2), r.den);
    }

    pub fn isDrop(self: FrameRate) bool {
        return self == .fps_29_97_drop or self == .fps_59_94_drop;
    }

    pub fn label(self: FrameRate) []const u8 {
        return switch (self) {
            .fps_23_976 => "23.976",
            .fps_24 => "24",
            .fps_25 => "25",
            .fps_29_97 => "29.97",
            .fps_29_97_drop => "29.97 Drop",
            .fps_30 => "30",
            .fps_47_952 => "47.952",
            .fps_48 => "48",
            .fps_50 => "50",
            .fps_59_94 => "59.94",
            .fps_59_94_drop => "59.94 Drop",
            .fps_60 => "60",
            .fps_100 => "100",
            .fps_119_88 => "119.88",
            .fps_120 => "120",
        };
    }

    /// Whole frame index at a sample position (floored).
    pub fn framesAt(self: FrameRate, s: Samples, sr: SampleRate) i64 {
        const r = self.rational();
        const num: i128 = @as(i128, s) * @as(i128, r.num);
        const den: i128 = @as(i128, sr.hz()) * @as(i128, r.den);
        if (den == 0) return 0;
        // `den` is always positive here (sample rate and denominator are > 0), so
        // floor division equals Rust's `div_euclid`.
        const q = @divFloor(num, den);
        return std.math.cast(i64, q) orelse 0;
    }

    /// Sample position of the start of frame `f`.
    pub fn samplesAtFrame(self: FrameRate, f: i64, sr: SampleRate) Samples {
        const r = self.rational();
        if (r.num == 0) return 0;
        // Round half away from zero so negative frames mirror positive ones.
        const mag_u: u64 = @abs(f);
        const num: i128 = @as(i128, r.num);
        const mag: i128 = @divTrunc(@as(i128, mag_u) * @as(i128, sr.hz()) * @as(i128, r.den) + @divTrunc(num, 2), num);
        const v: i128 = if (f < 0) -mag else mag;
        return std.math.cast(i64, v) orelse if (v < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }

    /// Samples per frame (fractional).
    pub fn samplesPerFrame(self: FrameRate, sr: SampleRate) f64 {
        const r = self.rational();
        return sr.asF64() * @as(f64, @floatFromInt(r.den)) / @as(f64, @floatFromInt(r.num));
    }
};

/// A timecode label.
pub const Timecode = struct {
    negative: bool,
    hours: i64,
    minutes: i64,
    seconds: i64,
    frames: i64,

    /// Label for an absolute frame count.
    pub fn fromFrames(frames: i64, rate: FrameRate) Timecode {
        const negative = frames < 0;
        // Drop-frame labels can exceed i64 even when the frame count fits, so work in
        // i128 and take the magnitude there (i64::MIN is represented exactly).
        var f: i128 = @as(i128, frames);
        if (f < 0) f = -f;
        const base: i128 = @max(@as(i128, rate.nominal()), 1);
        if (rate.isDrop()) {
            // Drop 2 (or 4) labels each minute except every tenth.
            const drop: i128 = if (base >= 60) 4 else 2;
            const per_10min = base * 600 - drop * 9;
            const per_min = base * 60 - drop;
            const tens = @divTrunc(f, per_10min);
            const rest = @rem(f, per_10min);
            const extra = if (rest > drop)
                drop * 9 * tens + drop * @divTrunc(rest - drop, per_min)
            else
                drop * 9 * tens;
            f += extra;
        }
        const frames_l = @rem(f, base);
        const total_secs = @divTrunc(f, base);
        return .{
            .negative = negative,
            .hours = std.math.cast(i64, @divTrunc(total_secs, 3600)) orelse std.math.maxInt(i64),
            .minutes = std.math.cast(i64, @rem(@divTrunc(total_secs, 60), 60)) orelse 0,
            .seconds = std.math.cast(i64, @rem(total_secs, 60)) orelse 0,
            .frames = std.math.cast(i64, frames_l) orelse 0,
        };
    }

    /// Absolute frame count of this label (saturated to i64).
    pub fn toFrames(self: Timecode, rate: FrameRate) i64 {
        const base: i128 = @max(@as(i128, rate.nominal()), 1);
        const total_min: i128 = @as(i128, self.hours) * 60 + @as(i128, self.minutes);
        var f: i128 = (total_min * 60 + @as(i128, self.seconds)) * base + @as(i128, self.frames);
        if (rate.isDrop()) {
            const drop: i128 = if (base >= 60) 4 else 2;
            f -= drop * (total_min - @divTrunc(total_min, 10));
        }
        if (self.negative) f = -f;
        return std.math.cast(i64, f) orelse if (f < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }

    pub fn fromSamples(s: Samples, rate: FrameRate, sr: SampleRate) Timecode {
        return fromFrames(rate.framesAt(s, sr), rate);
    }

    pub fn toSamples(self: Timecode, rate: FrameRate, sr: SampleRate) Samples {
        return rate.samplesAtFrame(self.toFrames(rate), sr);
    }

    /// Format as `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop-frame rates. The caller
    /// owns the returned string.
    pub fn format(self: Timecode, rate: FrameRate, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const sep: u8 = if (rate.isDrop()) ';' else ':';
        const sign: []const u8 = if (self.negative) "-" else "";
        var b_h: [24]u8 = undefined;
        var b_m: [24]u8 = undefined;
        var b_s: [24]u8 = undefined;
        var b_f: [24]u8 = undefined;
        return std.fmt.allocPrint(gpa, "{s}{s}:{s}:{s}{c}{s}", .{
            sign,
            pad2(&b_h, self.hours),
            pad2(&b_m, self.minutes),
            pad2(&b_s, self.seconds),
            sep,
            pad2(&b_f, self.frames),
        });
    }

    /// Rust `{:02}`: decimal with at least two digits, zero-filled on the left.
    /// Written by hand because this toolchain prints a `+` for any integer that
    /// has a width specifier.
    fn pad2(buf: *[24]u8, v: i64) []const u8 {
        const digits = std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
        if (digits.len >= 2) return digits;
        // A one-character result is a non-negative single digit.
        buf[1] = buf[0];
        buf[0] = '0';
        return buf[0..2];
    }

    /// Parse `HH:MM:SS:FF` (also `;` and `.` separators, and fewer fields,
    /// right-aligned). Allocation free.
    pub fn parse(text: []const u8) TimeError!Timecode {
        const t0 = std.mem.trim(u8, text, &std.ascii.whitespace);
        var negative = false;
        var t = t0;
        if (std.mem.startsWith(u8, t0, "-")) {
            negative = true;
            t = t0[1..];
        }
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitAny(u8, t, ":;.");
        while (it.next()) |p| {
            if (count == 4) return error.Parse; // more than four fields
            parts[count] = p;
            count += 1;
        }
        var nums = [_]i64{ 0, 0, 0, 0 };
        const offset = 4 - count;
        for (parts[0..count], 0..) |p, i| {
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, p, &std.ascii.whitespace), 10) catch return error.Parse;
            if (v < 0) return error.Parse;
            nums[offset + i] = v;
        }
        return .{
            .negative = negative,
            .hours = nums[0],
            .minutes = nums[1],
            .seconds = nums[2],
            .frames = nums[3],
        };
    }
};

/// Feet and frames for 35 mm film (16 frames per foot).
pub const FeetFrames = struct { feet: i64, frames: i64 };

/// Feet+Frames at sample `s`, with `start` frames already elapsed at sample 0.
pub fn feetFrames(s: Samples, rate: FrameRate, sr: SampleRate, start: i64) FeetFrames {
    const f = rate.framesAt(s, sr) +| start;
    return .{ .feet = @divFloor(f, 16), .frames = @mod(f, 16) };
}

fn expectFormat(expected: []const u8, tc: Timecode, rate: FrameRate) !void {
    const s = try tc.format(rate, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "non_drop_round_trip" {
    const sr = SampleRate.hz_48000;
    const tc = Timecode.fromSamples(48_000 * 3661, .fps_25, sr);
    try expectFormat("01:01:01:00", tc, .fps_25);
    try std.testing.expectEqual(@as(Samples, 48_000 * 3661), tc.toSamples(.fps_25, sr));
}

test "negative_timecode_rounds_symmetrically" {
    const sr = SampleRate.hz_48000;
    const tc = try Timecode.parse("-00:00:01:00");
    try std.testing.expectEqual(@as(Samples, -48_000), tc.toSamples(.fps_25, sr));
    const rates = [_]FrameRate{ .fps_25, .fps_29_97, .fps_29_97_drop, .fps_23_976 };
    const frames = [_]i64{ 1, 7, 25, 1799, 107_892 };
    for (rates) |r| {
        for (frames) |f| {
            try std.testing.expectEqual(-r.samplesAtFrame(f, sr), r.samplesAtFrame(-f, sr));
        }
    }
}

test "drop_frame_labels" {
    const r = FrameRate.fps_29_97_drop;
    // Frame 1800 is the first frame of minute 1, labelled 00:01:00;02.
    try expectFormat("00:01:00;02", Timecode.fromFrames(1800, r), r);
    try expectFormat("00:00:59;29", Timecode.fromFrames(1799, r), r);
    // Minute 10 keeps its labels.
    try expectFormat("00:10:00;00", Timecode.fromFrames(17_982, r), r);
    const frames = [_]i64{ 0, 1, 1799, 1800, 1801, 17_981, 17_982, 107_892, 500_000 };
    for (frames) |f| {
        try std.testing.expectEqual(f, Timecode.fromFrames(f, r).toFrames(r));
    }
}

test "huge_timecode_saturates_instead_of_overflowing" {
    const sr = SampleRate.hz_48000;
    for ([_]FrameRate{ .fps_30, .fps_29_97_drop }) |r| {
        const tc = try Timecode.parse("9223372036854775807:00:00:00");
        try std.testing.expectEqual(@as(Samples, std.math.maxInt(Samples)), tc.toSamples(r, sr));
        const tc2 = try Timecode.parse("-9223372036854775807:00:00:00");
        try std.testing.expectEqual(@as(Samples, std.math.minInt(Samples)), tc2.toSamples(r, sr));
    }
    const tc = try Timecode.parse("01:02:03:04");
    try std.testing.expectEqual(@as(Samples, 178_710_400), tc.toSamples(.fps_30, sr));
}

test "extreme_frame_counts_round_trip_at_every_rate" {
    const frames_list = [_]i64{
        std.math.minInt(i64),
        std.math.minInt(i64) + 1,
        -1,
        0,
        1,
        std.math.maxInt(i64) - 1,
        std.math.maxInt(i64),
    };
    for (FrameRate.all) |rate| {
        for (frames_list) |frames| {
            const tc = Timecode.fromFrames(frames, rate);
            try std.testing.expectEqual(frames, tc.toFrames(rate));
            try std.testing.expectEqual(frames < 0, tc.negative);
            try std.testing.expect(tc.minutes >= 0 and tc.minutes < 60);
            try std.testing.expect(tc.seconds >= 0 and tc.seconds < 60);
            try std.testing.expect(tc.frames >= 0 and tc.frames < rate.nominal());
            const s = try tc.format(rate, std.testing.allocator);
            defer std.testing.allocator.free(s);
            try std.testing.expectEqual(tc, try Timecode.parse(s));
        }
    }
}

test "extreme_drop_frame_labels_do_not_overflow" {
    for ([_]FrameRate{ .fps_29_97_drop, .fps_59_94_drop }) |rate| {
        try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), Timecode.fromFrames(std.math.maxInt(i64), rate).toFrames(rate));
    }
}

test "parse_variants" {
    const tc = try Timecode.parse("01:02:03:04");
    try std.testing.expectEqual(@as(i64, 1), tc.hours);
    try std.testing.expectEqual(@as(i64, 2), tc.minutes);
    try std.testing.expectEqual(@as(i64, 3), tc.seconds);
    try std.testing.expectEqual(@as(i64, 4), tc.frames);
    const short = try Timecode.parse("3:04");
    try std.testing.expectEqual(@as(i64, 3), short.seconds);
    try std.testing.expectEqual(@as(i64, 4), short.frames);
    try std.testing.expectError(error.Parse, Timecode.parse("a:b"));
    try std.testing.expectError(error.Parse, Timecode.parse("1:2:3:4:5"));
}

test "feet_and_frames" {
    const sr = SampleRate.hz_48000;
    const ff = feetFrames(48_000, .fps_24, sr, 0);
    try std.testing.expectEqual(@as(i64, 1), ff.feet);
    try std.testing.expectEqual(@as(i64, 8), ff.frames);
}

test "frame_rate_helpers" {
    try std.testing.expectEqual(@as(i64, 24), FrameRate.fps_23_976.nominal());
    try std.testing.expectEqual(@as(i64, 30), FrameRate.fps_29_97.nominal());
    try std.testing.expectEqual(@as(i64, 60), FrameRate.fps_59_94_drop.nominal());
    try std.testing.expect(FrameRate.fps_29_97_drop.isDrop() and !FrameRate.fps_29_97.isDrop());
    try std.testing.expectEqualStrings("29.97 Drop", FrameRate.fps_29_97_drop.label());
    try std.testing.expectEqual(@as(usize, 15), FrameRate.all.len);
}
