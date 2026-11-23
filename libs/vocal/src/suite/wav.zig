// Translated to Zig from pitchpure/crates/pitchpure_suite/src/wav.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Minimal WAV I/O (PCM 16-bit int and 32-bit float in; 32-bit float out).
//! Shared by takes, offline rendering and the QA suite.
//!
//! Control thread only: these functions allocate and do file I/O. The
//! caller supplies the `std.Io`, the directory paths are relative to, and
//! the allocator. Rust's `String` error messages become the `WavError` set.

const std = @import("std");

pub const WavError = error{
    /// Fewer than 12 bytes: cannot be RIFF/WAVE.
    TooShort,
    MissingRiff,
    MissingWave,
    /// A chunk extends past the end of the file.
    Truncated,
    /// `fmt ` chunk shorter than 16 bytes.
    FmtTooShort,
    /// Channel count is 0 (in a file, or in audio passed to `writeWav`).
    ZeroChannels,
    /// Sample rate is 0 (in a file, or in audio passed to `writeWav`).
    ZeroSampleRate,
    ZeroBlockAlign,
    MissingFmt,
    MissingData,
    /// Only PCM-16 (tag 1) and float-32 (tag 3) are supported.
    UnsupportedFormat,
    TooManyChannels,
    /// `samples.len` is not a multiple of `channels`.
    RaggedSamples,
    DataTooLarge,
    SampleRateTooLarge,
};

/// Decoded audio. Owns `samples` (interleaved); free with `deinit`.
pub const WavAudio = struct {
    sample_rate: u32,
    channels: usize,
    samples: []f32,

    pub fn deinit(self: *WavAudio, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
        self.* = undefined;
    }
};

fn getU16(bytes: []const u8, at: usize) ?u16 {
    if (at + 1 >= bytes.len) return null;
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

fn getU32(bytes: []const u8, at: usize) ?u32 {
    if (at + 3 >= bytes.len) return null;
    var value: u32 = 0;
    for (0..4) |i| value |= @as(u32, bytes[at + i]) << @intCast(8 * i);
    return value;
}

fn getF32(bytes: []const u8, at: usize) ?f32 {
    const raw = getU32(bytes, at) orelse return null;
    return @bitCast(raw);
}

const WavFormat = struct {
    tag: u16,
    channels: usize,
    sample_rate: u32,
    block_align: usize,
    bits: u16,
};

fn parseFmt(chunk: []const u8) WavError!WavFormat {
    if (chunk.len < 16) return error.FmtTooShort;
    const tag = getU16(chunk, 0) orelse 0;
    const channels: usize = getU16(chunk, 2) orelse 0;
    const sample_rate = getU32(chunk, 4) orelse 0;
    const block_align: usize = getU16(chunk, 12) orelse 0;
    const bits = getU16(chunk, 14) orelse 0;
    if (channels == 0) return error.ZeroChannels;
    if (sample_rate == 0) return error.ZeroSampleRate;
    if (block_align == 0) return error.ZeroBlockAlign;
    return .{ .tag = tag, .channels = channels, .sample_rate = sample_rate, .block_align = block_align, .bits = bits };
}

/// Decode a whole WAV file held in memory. Caller owns the result.
pub fn decodeWav(gpa: std.mem.Allocator, bytes: []const u8) (WavError || std.mem.Allocator.Error)!WavAudio {
    if (bytes.len < 12) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.MissingRiff;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.MissingWave;
    var format: ?WavFormat = null;
    var data: ?[2]usize = null;
    var off: usize = 12;
    while (off + 8 <= bytes.len) {
        const size: usize = getU32(bytes, off + 4) orelse 0;
        const start = off + 8;
        const end = start +| size;
        if (end > bytes.len) return error.Truncated;
        const id = bytes[off .. off + 4];
        if (std.mem.eql(u8, id, "fmt ") and format == null) {
            format = try parseFmt(bytes[start..end]);
        } else if (std.mem.eql(u8, id, "data") and data == null) {
            data = .{ start, end };
        }
        off = end + (size & 1);
    }
    const fmt = format orelse return error.MissingFmt;
    const range = data orelse return error.MissingData;
    const payload = bytes[range[0]..range[1]];
    const frames = payload.len / fmt.block_align;
    if (fmt.tag == 1 and fmt.bits == 16) {
        const samples = try gpa.alloc(f32, frames * fmt.channels);
        for (0..frames) |frame| {
            const base = frame * fmt.block_align;
            for (0..fmt.channels) |channel| {
                const raw: i16 = @bitCast(getU16(payload, base + channel * 2) orelse 0);
                samples[frame * fmt.channels + channel] = @as(f32, @floatFromInt(raw)) / 32768.0;
            }
        }
        return .{ .sample_rate = fmt.sample_rate, .channels = fmt.channels, .samples = samples };
    }
    if (fmt.tag == 3 and fmt.bits == 32) {
        const samples = try gpa.alloc(f32, frames * fmt.channels);
        for (0..frames) |frame| {
            const base = frame * fmt.block_align;
            for (0..fmt.channels) |channel| {
                samples[frame * fmt.channels + channel] = getF32(payload, base + channel * 4) orelse 0.0;
            }
        }
        return .{ .sample_rate = fmt.sample_rate, .channels = fmt.channels, .samples = samples };
    }
    return error.UnsupportedFormat;
}

/// Read and decode `path` (relative to `dir`, or absolute).
pub fn readWav(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !WavAudio {
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return decodeWav(gpa, bytes);
}

/// Write `audio` as 32-bit float WAV to `path` (relative to `dir`).
pub fn writeWav(io: std.Io, dir: std.Io.Dir, path: []const u8, audio: *const WavAudio) !void {
    if (audio.channels == 0) return error.ZeroChannels;
    if (audio.channels > std.math.maxInt(u16)) return error.TooManyChannels;
    if (audio.sample_rate == 0) return error.ZeroSampleRate;
    if (audio.samples.len % audio.channels != 0) return error.RaggedSamples;
    const channels_u16: u16 = @intCast(audio.channels);
    const data_bytes = std.math.mul(usize, audio.samples.len, 4) catch return error.DataTooLarge;
    // Rust checks `data_bytes <= u32::MAX`, then writes `36 + data_bytes as
    // u32` (which would overflow near the limit); reject that case too.
    if (data_bytes > std.math.maxInt(u32) - 36) return error.DataTooLarge;
    const block_align = std.math.cast(u16, @as(u32, channels_u16) * 4) orelse return error.TooManyChannels;
    const byte_rate = std.math.cast(u32, @as(u64, audio.sample_rate) * channels_u16 * 4) orelse return error.SampleRateTooLarge;

    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + @as(u32, @intCast(data_bytes)), .little);
    try w.writeAll("WAVE");
    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 3, .little);
    try w.writeInt(u16, channels_u16, .little);
    try w.writeInt(u32, audio.sample_rate, .little);
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, block_align, .little);
    try w.writeInt(u16, 32, .little);
    try w.writeAll("data");
    try w.writeInt(u32, @intCast(data_bytes), .little);
    for (audio.samples) |s| try w.writeInt(u32, @bitCast(s), .little);
    try w.flush();
}

const testing = std.testing;

// Seridian: new tests (the Rust wav.rs has none).
test "float wav round-trips through a file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var samples = [_]f32{ 0.0, 0.5, -0.25, 1.0, -1.0, 0.125 };
    const audio: WavAudio = .{ .sample_rate = 44_100, .channels = 2, .samples = &samples };
    try writeWav(io, tmp.dir, "x.wav", &audio);
    var back = try readWav(gpa, io, tmp.dir, "x.wav");
    defer back.deinit(gpa);
    try testing.expectEqual(@as(u32, 44_100), back.sample_rate);
    try testing.expectEqual(@as(usize, 2), back.channels);
    try testing.expectEqualSlices(f32, &samples, back.samples);
}

test "decode rejects malformed headers and decodes pcm16" {
    const gpa = testing.allocator;
    try testing.expectError(error.TooShort, decodeWav(gpa, "RIFF"));
    try testing.expectError(error.MissingRiff, decodeWav(gpa, "RIFX\x00\x00\x00\x00WAVE"));
    try testing.expectError(error.MissingWave, decodeWav(gpa, "RIFF\x00\x00\x00\x00WAVX"));
    try testing.expectError(error.MissingFmt, decodeWav(gpa, "RIFF\x00\x00\x00\x00WAVE"));
    const pcm = "RIFF\x00\x00\x00\x00WAVE" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\xbb\x00\x00\x00\x77\x01\x00\x02\x00\x10\x00" ++
        "data\x04\x00\x00\x00\x00\x40\x00\xc0";
    var a = try decodeWav(gpa, pcm);
    defer a.deinit(gpa);
    try testing.expectEqualSlices(f32, &.{ 0.5, -0.5 }, a.samples);
}
