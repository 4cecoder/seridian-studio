//! Plugin delay compensation (PDC).
//!
//! Effects such as the vocal tuner delay their track by their algorithmic
//! latency. The engine delays every other track by the difference to the
//! slowest one, so all tracks stay sample-aligned at the master bus.
//! `DelayLine` is a stereo ring buffer allocated once; `process` is
//! real-time safe (no allocation, locks, logging or I/O).

const std = @import("std");

/// Longest compensation in frames (about 0.68 s at 48 kHz, 0.34 s at 96 kHz).
/// Must be a power of two.
pub const MAX_DELAY_FRAMES: usize = 1 << 15;
const MASK = MAX_DELAY_FRAMES - 1;
const CHANNELS = 2;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(MAX_DELAY_FRAMES));
}

/// Stereo interleaved delay line with a per-block delay amount.
pub const DelayLine = struct {
    ring: []f32,
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !DelayLine {
        const ring = try allocator.alloc(f32, MAX_DELAY_FRAMES * CHANNELS);
        @memset(ring, 0.0);
        return .{ .ring = ring };
    }

    pub fn deinit(self: *DelayLine, allocator: std.mem.Allocator) void {
        allocator.free(self.ring);
        self.ring = &.{};
    }

    /// Forget all buffered audio (call when a track restarts after being silent).
    pub fn clear(self: *DelayLine) void {
        @memset(self.ring, 0.0);
        self.pos = 0;
    }

    /// Delay `buffer` (stereo interleaved) in place by `delay_frames`, clamped to
    /// MAX_DELAY_FRAMES - 1. A delay of 0 passes audio through unchanged.
    pub fn process(self: *DelayLine, buffer: []f32, delay_frames: usize) void {
        const delay = @min(delay_frames, MAX_DELAY_FRAMES - 1);
        const frames = buffer.len / CHANNELS;
        for (0..frames) |frame| {
            const w = self.pos * CHANNELS;
            self.ring[w] = buffer[frame * CHANNELS];
            self.ring[w + 1] = buffer[frame * CHANNELS + 1];
            const r = ((self.pos + MAX_DELAY_FRAMES - delay) & MASK) * CHANNELS;
            buffer[frame * CHANNELS] = self.ring[r];
            buffer[frame * CHANNELS + 1] = self.ring[r + 1];
            self.pos = (self.pos + 1) & MASK;
        }
    }
};

/// Compensation for one track: how much later its signal must arrive so it
/// lines up with the slowest track.
pub fn compensation(track_latency: usize, max_latency: usize) usize {
    return max_latency -| track_latency;
}

test "pdc: zero delay passes audio through" {
    var line = try DelayLine.init(std.testing.allocator);
    defer line.deinit(std.testing.allocator);
    var buf = [_]f32{ 1, -1, 2, -2, 3, -3 };
    const before = buf;
    line.process(&buf, 0);
    try std.testing.expectEqualSlices(f32, &before, &buf);
}

test "pdc: delays by exactly N frames across block boundaries" {
    var line = try DelayLine.init(std.testing.allocator);
    defer line.deinit(std.testing.allocator);
    const delay = 5;
    var produced: [40]f32 = undefined;
    // Feed a ramp in uneven blocks; output frame i must equal input frame i - delay.
    var frame: usize = 0;
    for ([_]usize{ 3, 7, 1, 9 }) |n| {
        var block: [2 * 9]f32 = undefined;
        for (0..n) |i| {
            const v: f32 = @floatFromInt(frame + i + 1);
            block[i * 2] = v;
            block[i * 2 + 1] = -v;
        }
        line.process(block[0 .. n * 2], delay);
        for (0..n) |i| {
            produced[(frame + i) * 2] = block[i * 2];
            produced[(frame + i) * 2 + 1] = block[i * 2 + 1];
        }
        frame += n;
    }
    for (0..frame) |i| {
        const expected: f32 = if (i < delay) 0.0 else @floatFromInt(i - delay + 1);
        try std.testing.expectEqual(expected, produced[i * 2]);
        try std.testing.expectEqual(-expected, produced[i * 2 + 1]);
    }
}

test "pdc: clear drops stale audio" {
    var line = try DelayLine.init(std.testing.allocator);
    defer line.deinit(std.testing.allocator);
    var buf = [_]f32{ 1, 1, 1, 1 };
    line.process(&buf, 2);
    line.clear();
    var silent = [_]f32{ 0, 0, 0, 0, 0, 0 };
    line.process(&silent, 2);
    for (silent) |s| try std.testing.expectEqual(@as(f32, 0.0), s);
}

test "pdc: oversized delays are clamped, not out of bounds" {
    var line = try DelayLine.init(std.testing.allocator);
    defer line.deinit(std.testing.allocator);
    var buf = [_]f32{ 1, 1 };
    line.process(&buf, MAX_DELAY_FRAMES * 4);
    try std.testing.expectEqual(@as(f32, 0.0), buf[0]);
}

test "pdc: compensation lines tracks up with the slowest" {
    try std.testing.expectEqual(@as(usize, 1000), compensation(0, 1000));
    try std.testing.expectEqual(@as(usize, 0), compensation(1000, 1000));
    try std.testing.expectEqual(@as(usize, 0), compensation(5, 0));
}
