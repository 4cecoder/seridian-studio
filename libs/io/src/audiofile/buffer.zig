// Translated to Zig from soundcraft/crates/audio-io/src/buffer.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Planar `f32` audio buffer. The buffer owns its channel slices and remembers the allocator
//! that made them, so `deinit` needs no further arguments.

const std = @import("std");
const testing = std.testing;

/// Planar f32 audio.
///
/// Every channel is expected to hold the same number of frames; `frames()` reports the shortest
/// channel so a ragged buffer never causes out-of-bounds access.
pub const AudioBuffer = struct {
    /// Allocator that made `channels` and every channel slice.
    gpa: std.mem.Allocator,
    /// Sample rate in Hz.
    sample_rate: u32,
    /// One slice of samples per channel.
    channels: [][]f32,

    /// A silent buffer with `num_channels` channels of `frames` frames each.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, num_channels: usize, n_frames: usize) !AudioBuffer {
        const chans = try gpa.alloc([]f32, num_channels);
        errdefer gpa.free(chans);
        var made: usize = 0;
        errdefer {
            for (chans[0..made]) |c| gpa.free(c);
        }
        while (made < num_channels) : (made += 1) {
            chans[made] = try gpa.alloc(f32, n_frames);
            @memset(chans[made], 0);
        }
        return .{ .gpa = gpa, .sample_rate = sample_rate, .channels = chans };
    }

    /// Frees every channel and the channel list.
    pub fn deinit(self: *AudioBuffer) void {
        for (self.channels) |c| self.gpa.free(c);
        self.gpa.free(self.channels);
    }

    /// Number of frames: the length of the shortest channel, 0 when there are no channels.
    pub fn frames(self: *const AudioBuffer) usize {
        if (self.channels.len == 0) return 0;
        var m: usize = std.math.maxInt(usize);
        for (self.channels) |c| m = @min(m, c.len);
        return m;
    }

    /// Number of channels.
    pub fn numChannels(self: *const AudioBuffer) usize {
        return self.channels.len;
    }

    /// Duration in seconds (0 when the sample rate is 0).
    pub fn durationSecs(self: *const AudioBuffer) f64 {
        if (self.sample_rate == 0) return 0.0;
        return @as(f64, @floatFromInt(self.frames())) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Interleaved copy of the samples (frame-major: `L0 R0 L1 R1 ...`). The caller frees it
    /// with the same allocator the buffer was made with.
    pub fn interleaved(self: *const AudioBuffer) ![]f32 {
        const n = self.frames();
        const nch = self.channels.len;
        const out = try self.gpa.alloc(f32, n *| nch);
        for (0..n) |f| {
            for (self.channels, 0..) |ch, c| {
                out[f * nch + c] = ch[f];
            }
        }
        return out;
    }

    /// Builds a planar buffer from interleaved samples. A trailing partial frame is dropped;
    /// `num_channels == 0` yields an empty buffer.
    pub fn fromInterleaved(gpa: std.mem.Allocator, sample_rate: u32, num_channels: usize, data: []const f32) !AudioBuffer {
        if (num_channels == 0) {
            return .{ .gpa = gpa, .sample_rate = sample_rate, .channels = try gpa.alloc([]f32, 0) };
        }
        const n_frames = data.len / num_channels;
        const chans = try gpa.alloc([]f32, num_channels);
        errdefer gpa.free(chans);
        var made: usize = 0;
        errdefer {
            for (chans[0..made]) |c| gpa.free(c);
        }
        while (made < num_channels) : (made += 1) {
            chans[made] = try gpa.alloc(f32, n_frames);
        }
        for (chans, 0..) |ch, c| {
            for (0..n_frames) |f| {
                ch[f] = data[f * num_channels + c];
            }
        }
        return .{ .gpa = gpa, .sample_rate = sample_rate, .channels = chans };
    }

    /// Absolute peak over all channels. NaN samples are ignored (a comparison with NaN is false),
    /// matching Rust's `f32::max`.
    pub fn peak(self: *const AudioBuffer) f32 {
        var acc: f32 = 0.0;
        for (self.channels) |ch| {
            for (ch) |s| {
                const a = @abs(s);
                if (a > acc) acc = a;
            }
        }
        return acc;
    }
};

test "new buffer is silent with the shortest channel setting the frame count" {
    var buf = try AudioBuffer.init(testing.allocator, 44_100, 2, 10);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 2), buf.numChannels());
    try testing.expectEqual(@as(usize, 10), buf.frames());
    try testing.expectEqual(@as(f32, 0.0), buf.peak());

    // A ragged buffer reports the shortest channel.
    testing.allocator.free(buf.channels[1]);
    buf.channels[1] = try testing.allocator.alloc(f32, 4);
    try testing.expectEqual(@as(usize, 4), buf.frames());
}

test "interleaved and from_interleaved are inverses, dropping a partial frame" {
    const data = [_]f32{ 1, -1, 2, -2, 3, -3, 4 };
    var buf = try AudioBuffer.fromInterleaved(testing.allocator, 48_000, 2, &data);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 3), buf.frames());
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, buf.channels[0]);
    try testing.expectEqualSlices(f32, &.{ -1, -2, -3 }, buf.channels[1]);

    const back = try buf.interleaved();
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(f32, data[0..6], back);
}

test "from_interleaved with zero channels is empty" {
    var buf = try AudioBuffer.fromInterleaved(testing.allocator, 48_000, 0, &.{ 1, 2, 3 });
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 0), buf.numChannels());
    try testing.expectEqual(@as(usize, 0), buf.frames());
    try testing.expectEqual(@as(f64, 0.0), buf.durationSecs());
}

test "peak ignores NaN and reports absolute value" {
    var buf = try AudioBuffer.fromInterleaved(testing.allocator, 48_000, 1, &.{ 0.25, std.math.nan(f32), -0.75 });
    defer buf.deinit();
    try testing.expectEqual(@as(f32, 0.75), buf.peak());
}

test "duration is frames over sample rate" {
    var buf = try AudioBuffer.init(testing.allocator, 48_000, 1, 24_000);
    defer buf.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.5), buf.durationSecs(), 1e-12);
}
