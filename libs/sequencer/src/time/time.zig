// Translated to Zig from soundcraft/crates/time/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! SoundCraft timebases: the shared sample type, `SampleRate`, `Range` and the
//! float-to-sample conversion. `timecode` (SMPTE, Feet+Frames) and `tempo` (the
//! tick grid, tempo and meter maps) are re-exported from here.
//!
//! Every position in a session is an absolute sample index (`Samples`, i64) at the
//! session sample rate. Everything in this file is pure arithmetic: it never
//! allocates, locks, logs or does I/O, so it is safe on the audio thread.
//!
//! Realtime note: `tempo.TempoMap` is edited on the control thread (it owns
//! allocator-backed lists). The audio thread reads an immutable `tempo.Snapshot`
//! through `Snapshot.view()`, which only borrows slices.

const std = @import("std");

pub const timecode = @import("timecode.zig");
pub const tempo = @import("tempo.zig");
pub const grid = @import("grid.zig");
pub const format = @import("format.zig");

/// A position or length in samples.
pub const Samples = i64;

/// Largest position accepted from parameters and files: 2^40 samples (about 265
/// days at 48 kHz). Clamping there keeps later additions and subtractions far from
/// overflow.
pub const max_position: Samples = 1 << 40;

/// Errors from parsing or converting time values. The Rust `TimeError` carries the
/// offending value; a Zig error set carries no payload, so callers that need the
/// value must re-check their input.
pub const TimeError = error{ Parse, SampleRate, Tempo, Meter };

/// Sample rates supported by sessions (Pro Tools offers 44.1 k - 192 k; we accept
/// 8 k - 768 k).
pub const SampleRate = struct {
    hz_value: u32,

    pub const hz_44100: SampleRate = .{ .hz_value = 44_100 };
    pub const hz_48000: SampleRate = .{ .hz_value = 48_000 };
    pub const default: SampleRate = hz_48000;
    pub const common = [_]u32{ 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000 };

    pub fn init(hz_in: u32) TimeError!SampleRate {
        if (hz_in >= 8_000 and hz_in <= 768_000) return .{ .hz_value = hz_in };
        return error.SampleRate;
    }

    pub fn hz(self: SampleRate) u32 {
        return self.hz_value;
    }

    pub fn asF64(self: SampleRate) f64 {
        return @floatFromInt(self.hz_value);
    }

    /// Samples -> seconds.
    pub fn seconds(self: SampleRate, s: Samples) f64 {
        return @as(f64, @floatFromInt(s)) / self.asF64();
    }

    /// Seconds -> samples, rounded to nearest and saturated.
    pub fn samples(self: SampleRate, secs: f64) Samples {
        return toSamples(secs * self.asF64());
    }
};

/// Round a float sample count to `Samples`, mapping NaN to 0 and saturating
/// infinities and out-of-range values.
pub fn toSamples(v: f64) Samples {
    if (std.math.isNan(v)) return 0;
    const hi: f64 = @floatFromInt(std.math.maxInt(Samples));
    const lo: f64 = @floatFromInt(std.math.minInt(Samples));
    if (v >= hi) return std.math.maxInt(Samples);
    if (v <= lo) return std.math.minInt(Samples);
    // In (lo, hi) the rounded value is always representable.
    return @intFromFloat(@round(v));
}

/// A half-open sample range `[start, end)`. Always normalised so `start <= end`
/// when built with `init`.
pub const Range = struct {
    start: Samples,
    end: Samples,

    pub fn init(a: Samples, b: Samples) Range {
        if (a <= b) return .{ .start = a, .end = b };
        return .{ .start = b, .end = a };
    }

    pub fn point(at: Samples) Range {
        return .{ .start = at, .end = at };
    }

    pub fn len(self: Range) Samples {
        return self.end -| self.start;
    }

    pub fn isEmpty(self: Range) bool {
        return self.end <= self.start;
    }

    pub fn contains(self: Range, s: Samples) bool {
        return s >= self.start and s < self.end;
    }

    pub fn overlaps(self: Range, o: Range) bool {
        return self.start < o.end and o.start < self.end;
    }

    pub fn intersect(self: Range, o: Range) ?Range {
        const s = @max(self.start, o.start);
        const e = @min(self.end, o.end);
        if (s < e) return .{ .start = s, .end = e };
        return null;
    }

    pub fn shifted(self: Range, by: Samples) Range {
        return .{ .start = self.start +| by, .end = self.end +| by };
    }
};

test "sample_rate_bounds" {
    _ = try SampleRate.init(48_000);
    try std.testing.expectError(error.SampleRate, SampleRate.init(0));
    try std.testing.expectError(error.SampleRate, SampleRate.init(10_000_000));
}

test "seconds_round_trip" {
    const sr = SampleRate.hz_44100;
    try std.testing.expectEqual(@as(Samples, 44_100), sr.samples(1.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sr.seconds(22_050), 1e-12);
}

test "to_samples_is_total" {
    try std.testing.expectEqual(@as(Samples, 0), toSamples(std.math.nan(f64)));
    try std.testing.expectEqual(@as(Samples, std.math.maxInt(i64)), toSamples(std.math.inf(f64)));
    try std.testing.expectEqual(@as(Samples, std.math.minInt(i64)), toSamples(-std.math.inf(f64)));
}

test "range_ops" {
    const a = Range.init(10, 0);
    try std.testing.expectEqual(Range{ .start = 0, .end = 10 }, a);
    const i = a.intersect(Range.init(5, 20)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Range.init(5, 10), i);
    try std.testing.expect(a.intersect(Range.init(10, 20)) == null);
    try std.testing.expect(a.contains(9) and !a.contains(10));
}

test "range_helpers" {
    const r = Range.init(4, 9);
    try std.testing.expectEqual(@as(Samples, 5), r.len());
    try std.testing.expect(!r.isEmpty());
    try std.testing.expect(Range.point(3).isEmpty());
    try std.testing.expect(r.overlaps(Range.init(8, 12)));
    try std.testing.expect(!r.overlaps(Range.init(9, 12)));
    try std.testing.expectEqual(Range.init(14, 19), r.shifted(10));
    // Saturating shift: never wraps.
    try std.testing.expectEqual(std.math.maxInt(Samples), r.shifted(std.math.maxInt(Samples)).start);
}

test {
    _ = timecode;
    _ = tempo;
}
