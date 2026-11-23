// Translated to Zig from soundcraft/crates/audio-io/src/lib.rs, soundcraft/crates/audio-io/tests/it/roundtrip.rs, soundcraft/crates/audio-io/tests/it/stream.rs, soundcraft/crates/audio-io/tests/it/decode_read_list.rs, soundcraft/crates/audio-io/tests/it/malformed.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Top-level audio file API: detect a file's format from its magic bytes (or an extension
//! hint), probe it, decode it to planar `f32`, and encode buffers or stream blocks to WAV/BWF,
//! RF64, AIFF/AIFF-C or FLAC. Bytes in, bytes out; no filesystem access.
//!
//! Dispatch goes to the native readers and writers only (`wav.zig`, `aiff.zig`, `flac.zig`).
//! MP3, Ogg, AAC/ALAC, CAF and Matroska/WebM are detected and answer `error.Unsupported`: the
//! Rust crate decodes them through symphonia, which is not ported. Compressed WAV/AIFF codecs
//! (ADPCM, A-law, ...) answer `error.Unsupported` the same way. FLAC sample decoding is also
//! `error.Unsupported` for now: `flac.zig` only has a test-only decoder. Empty FLAC streams
//! (zero frames) do decode.
//!
//! Control-thread code: everything here allocates or writes to a sink. Nothing runs on the audio
//! thread.

const std = @import("std");
const testing = std.testing;
pub const types = @import("types.zig");
pub const pcm = @import("pcm.zig");
pub const buffer = @import("buffer.zig");
pub const wav = @import("wav.zig");
pub const aiff = @import("aiff.zig");
pub const flac = @import("flac.zig");

pub const AudioError = types.AudioError;
pub const AudioBuffer = buffer.AudioBuffer;
pub const FileFormat = types.FileFormat;
pub const SampleFormat = types.SampleFormat;
pub const BwfInfo = types.BwfInfo;
pub const AudioInfo = types.AudioInfo;
pub const BitDepth = types.BitDepth;
pub const EncodeOptions = types.EncodeOptions;

/// A decoded file: what `probe` reports, and the samples. Free the samples with `buffer.deinit()`.
pub const Decoded = struct {
    info: AudioInfo,
    buffer: AudioBuffer,
};

/// Identifies a file by its magic bytes, falling back to the extension hint (`"wav"`, `".flac"`).
pub fn detectFormat(bytes: []const u8, ext_hint: ?[]const u8) FileFormat {
    if (detectByMagic(bytes, 0)) |f| return f;
    if (ext_hint) |h| {
        if (FileFormat.fromExtension(h)) |f| return f;
    }
    return .other;
}

/// Reads a file's format, sample rate, channel count, length and BWF metadata without decoding
/// the samples. Allocates nothing; the result borrows `bytes` for its BWF strings.
pub fn probe(bytes: []const u8, ext_hint: ?[]const u8) AudioError!AudioInfo {
    return switch (detectFormat(bytes, ext_hint)) {
        .wav => (try wavLayout(bytes)).info,
        .aiff => (try aiffLayout(bytes)).info,
        .flac => try flacInfo(bytes, try locateFlac(bytes, error.Malformed)),
        .mp3, .ogg, .aac, .alac, .caf, .other => try flacInfo(bytes, try locateFlac(bytes, error.Unsupported)),
    };
}

/// Decodes a whole file to planar `f32`. The caller frees `result.buffer` with `deinit`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, ext_hint: ?[]const u8) AudioError!Decoded {
    switch (detectFormat(bytes, ext_hint)) {
        .wav => {
            const layout = try wavLayout(bytes);
            return withBuffer(layout.info, try wav.decode(gpa, bytes, layout));
        },
        .aiff => {
            const layout = try aiffLayout(bytes);
            return withBuffer(layout.info, try aiff.decode(gpa, bytes, layout));
        },
        .flac => return decodeFlac(gpa, bytes, try locateFlac(bytes, error.Malformed)),
        .mp3, .ogg, .aac, .alac, .caf, .other => return decodeFlac(gpa, bytes, try locateFlac(bytes, error.Unsupported)),
    }
}

/// Encodes `buf` as WAV/BWF, AIFF/AIFF-C or FLAC. Samples are clamped to [-1, 1] for integer
/// depths. The caller frees the result with `gpa`.
pub fn encode(gpa: std.mem.Allocator, buf: *const AudioBuffer, opts: EncodeOptions) AudioError![]u8 {
    return switch (opts.format) {
        .wav => try wav.encode(gpa, buf, opts.bit_depth, opts.dither, opts.bwf, false, null),
        .aiff => try aiff.encode(gpa, buf, opts.bit_depth, opts.dither),
        .flac => try flac.encode(gpa, buf, opts.bit_depth, opts.dither),
        else => return error.Unsupported,
    };
}

/// Encodes a WAV file in the RF64 layout regardless of size (normally used only above 4 GiB).
pub fn encodeWavRf64(gpa: std.mem.Allocator, buf: *const AudioBuffer, opts: EncodeOptions) AudioError![]u8 {
    return wav.encode(gpa, buf, opts.bit_depth, opts.dither, opts.bwf, true, null);
}

/// Like `encode`, with an explicit WAV speaker mask (`dwChannelMask`, e.g. 0x60F) for layouts a
/// channel count alone cannot identify (7.0 vs 6.1, 5.1.4 vs 7.1.2, Ambisonics = 0). AIFF and
/// FLAC have fixed channel orders and ignore it.
pub fn encodeWithChannelMask(gpa: std.mem.Allocator, buf: *const AudioBuffer, opts: EncodeOptions, mask: u32) AudioError![]u8 {
    return switch (opts.format) {
        .wav => try wav.encode(gpa, buf, opts.bit_depth, opts.dither, opts.bwf, false, mask),
        else => try encode(gpa, buf, opts),
    };
}

/// The WAVE_FORMAT_EXTENSIBLE speaker mask of a WAV file, if it has one.
pub fn wavChannelMask(bytes: []const u8) ?u32 {
    return wav.readChannelMask(bytes);
}

/// The header of a 32-bit float WAV holding `frames` frames (little-endian samples follow it). Its
/// length doesn't depend on `frames`, so a recorder can rewrite it in place as the file grows; it
/// switches to RF64 above 4 GiB. The caller frees the result with `gpa`.
pub fn wavFloatHeader(gpa: std.mem.Allocator, channels: usize, sample_rate: u32, frames: u64) AudioError![]u8 {
    return wav.floatHeader(gpa, channels, sample_rate, frames);
}

// ---------------------------------------------------------------------------
// Streaming encoder
// ---------------------------------------------------------------------------

/// Turns the caller's sink into what the format writers need. Every write, seek and seekToEnd is
/// forwarded and the position is tracked here, so `position` and `tell` never touch the sink.
/// `fallible_tell` selects whether `tell` returns an error union: `aiff.Writer` catches it,
/// `flac.Writer` does not. The sink must provide `writeAll`, `seekTo`, `seekToEnd` and `flush`
/// returning error unions, and `tell` returning `u64` or an error union of it.
fn View(comptime S: type, comptime fallible_tell: bool) type {
    return struct {
        const Self = @This();

        sink: *S,
        pos: u64,

        pub fn writeAll(self: *Self, bytes: []const u8) AudioError!void {
            self.sink.writeAll(bytes) catch return error.Io;
            self.pos += @as(u64, bytes.len);
        }

        pub fn seekTo(self: *Self, pos: u64) AudioError!void {
            self.sink.seekTo(pos) catch return error.Io;
            self.pos = pos;
        }

        pub fn seekToEnd(self: *Self) AudioError!void {
            self.sink.seekToEnd() catch return error.Io;
            self.pos = try tellOf(self.sink);
        }

        pub fn flush(self: *Self) AudioError!void {
            self.sink.flush() catch return error.Io;
        }

        /// Current position (WAV's writer reads it as `position`).
        pub fn position(self: *const Self) u64 {
            return self.pos;
        }

        pub fn tell(self: *const Self) if (fallible_tell) AudioError!u64 else u64 {
            return self.pos;
        }
    };
}

/// `sink.tell()` as a `u64`, whether or not the sink reports it fallibly.
fn tellOf(sink: anytype) AudioError!u64 {
    const r = sink.tell();
    return if (@typeInfo(@TypeOf(r)) == .error_union) (r catch return error.Io) else r;
}

/// Writes a file block by block, producing the same bytes `encode` would for the whole buffer.
/// The header is a placeholder until `finish` rewrites it with the final frame count. The sink
/// is borrowed: it must outlive the encoder and already hold any bytes written before the file.
///
/// Initialise in place (`var enc: FileEncoder(S) = undefined; try enc.init(...)`): the format
/// writer keeps a pointer into this struct, so the struct must not move after `init`.
pub fn FileEncoder(comptime S: type) type {
    return struct {
        const Self = @This();
        const PlainView = View(S, false);
        const FallibleView = View(S, true);
        const Inner = union(enum) {
            wav: wav.Writer(*PlainView),
            aiff: aiff.Writer(FallibleView),
            flac: flac.Writer(PlainView),
        };

        sink: *S,
        plain: PlainView,
        fallible: FallibleView,
        inner: Inner,

        /// Starts a file at the current position of `sink`. `mask` overrides the WAV speaker mask
        /// derived from the channel count (ignored by AIFF and FLAC). Fails for formats `encode`
        /// does not write.
        pub fn init(self: *Self, gpa: std.mem.Allocator, sink: *S, opts: EncodeOptions, channels: usize, sample_rate: u32, mask: ?u32) AudioError!void {
            const start = try tellOf(sink);
            self.sink = sink;
            self.plain = .{ .sink = sink, .pos = start };
            self.fallible = .{ .sink = sink, .pos = start };
            self.inner = switch (opts.format) {
                .wav => .{ .wav = try wav.Writer(*PlainView).init(gpa, &self.plain, channels, sample_rate, opts.bit_depth, opts.dither, .{
                    .bwf = opts.bwf,
                    .mask = mask,
                    .force_rf64 = false,
                }) },
                .aiff => .{ .aiff = try aiff.Writer(FallibleView).init(gpa, &self.fallible, channels, sample_rate, opts.bit_depth, opts.dither) },
                .flac => .{ .flac = try flac.Writer(PlainView).init(gpa, &self.plain, channels, sample_rate, opts.bit_depth, opts.dither) },
                else => return error.Unsupported,
            };
        }

        /// Fails, without writing anything, when `frames` more frames would not fit the format
        /// (an AIFF holds 4 GiB, a FLAC 2^36 frames).
        pub fn checkRoom(self: *const Self, frames: u64) AudioError!void {
            switch (self.inner) {
                .wav => |*w| {
                    _ = try w.checkRoom(frames);
                },
                .aiff => |*w| {
                    _ = try w.checkRoom(frames);
                },
                .flac => |*w| {
                    _ = try w.checkRoom(frames);
                },
            }
        }

        /// Appends the first `frames` frames of `block`, one slice per channel (missing samples
        /// are silence), unless they don't fit (see `checkRoom`). Once a write has failed the
        /// encoder is unusable: every later `write` and `finish` returns `error.Encode`.
        pub fn write(self: *Self, block: []const []const f32, frames: usize) AudioError!void {
            switch (self.inner) {
                .wav => |*w| {
                    try w.write(block, frames);
                },
                .aiff => |*w| {
                    try w.write(block, frames);
                },
                .flac => |*w| {
                    try w.write(block, frames);
                },
            }
        }

        /// Completes the header and returns the sink, positioned at the end of the file. Call
        /// `deinit` afterwards (also on error) to release the writer's buffers.
        pub fn finish(self: *Self) AudioError!*S {
            switch (self.inner) {
                .wav => |*w| {
                    _ = try w.finish();
                },
                .aiff => |*w| try w.finish(),
                .flac => |*w| try w.finish(),
            }
            return self.sink;
        }

        /// Releases the writer's buffers. Safe after `finish`; call it once `init` has succeeded.
        pub fn deinit(self: *Self) void {
            switch (self.inner) {
                .wav => |*w| w.deinit(),
                .aiff => |*w| w.deinit(),
                .flac => |*w| w.deinit(),
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Format dispatch
// ---------------------------------------------------------------------------

/// Pairs decoded samples with the info that describes them; the frame count is the buffer's.
fn withBuffer(info: AudioInfo, buf: AudioBuffer) Decoded {
    var out = info;
    out.frames = @intCast(buf.frames());
    return .{ .info = out, .buffer = buf };
}

fn wavLayout(bytes: []const u8) AudioError!wav.WavLayout {
    return switch (try wav.parse(bytes)) {
        .native => |l| l,
        .foreign => error.Unsupported,
    };
}

fn aiffLayout(bytes: []const u8) AudioError!aiff.AiffLayout {
    return switch (try aiff.parse(bytes)) {
        .native => |l| l,
        .foreign => error.Unsupported,
    };
}

/// Size of an ID3v2 tag at the start of `b`, if there is one. The 10-byte footer flag (`0x10`)
/// exists only in ID3v2.4; in v2.2/v2.3 that bit is reserved and must not extend the skip.
fn id3v2Len(b: []const u8) ?usize {
    if (b.len < 10) return null;
    if (!std.mem.eql(u8, b[0..3], "ID3")) return null;
    const version = b[3];
    const flags = b[5];
    var size: usize = 0;
    for (b[6..10]) |x| size = (size << 7) | (x & 0x7F);
    const footer = version == 4 and (flags & 0x10) != 0;
    return 10 + size + (if (footer) @as(usize, 10) else 0);
}

/// The first byte after any ID3v2 tags at the start of `b`. The tags are skipped, not read.
fn skipId3v2(b: []const u8) usize {
    var at: usize = 0;
    while (at <= b.len) {
        const n = id3v2Len(b[at..]) orelse break;
        if (n == 0) break;
        at +|= n;
    }
    return at;
}

/// How far past the leading tags the scan for a stream marker looks (symphonia's probe scans
/// the same 1 MiB).
const max_prefix_scan: usize = 1 << 20;

/// Whether `rest` starts with an MPEG audio or ADTS frame header that is valid enough to be the
/// start of an audio stream rather than two stray bytes. The Rust code asks symphonia's readers
/// to score the candidate; this checks the header fields, and for ADTS that the next frame
/// follows (or the data ends) where the frame length says.
fn plausibleAudioSync(rest: []const u8) bool {
    if (rest.len < 4 or rest[0] != 0xFF or (rest[1] & 0xE0) != 0xE0) return false;
    const b1 = rest[1];
    const b2 = rest[2];
    const version = (b1 >> 3) & 3;
    const layer = (b1 >> 1) & 3;
    if (version != 1 and layer != 0) {
        // MPEG audio: bitrate index 15 and sample-rate index 3 are reserved.
        return (b2 >> 4) != 0xF and ((b2 >> 2) & 3) != 3;
    }
    if ((b1 & 0xF6) != 0xF0 or rest.len < 7) return false;
    // ADTS: sampling-frequency index below 13, then a 13-bit frame length that includes the header.
    if (((b2 >> 2) & 0xF) >= 13) return false;
    const len = (@as(usize, rest[3] & 3) << 11) | (@as(usize, rest[4]) << 3) | @as(usize, rest[5] >> 5);
    if (len < 7) return false;
    if (len == rest.len) return true;
    return len + 2 <= rest.len and rest[len] == 0xFF and (rest[len + 1] & 0xF6) == 0xF0;
}

/// Where a FLAC stream starts in `b`: after any leading ID3v2 tags, the first stream marker
/// within the first MiB must be `fLaC` (junk, tags and false MPEG syncs may come before it; the
/// marker of another container ends the search). Returns null when there is none.
fn findFlac(b: []const u8, start: usize) ?usize {
    const end = @min(b.len, start +| max_prefix_scan);
    var at = start;
    while (at +| 4 <= end) : (at += 1) {
        const rest = b[at..];
        if (std.mem.startsWith(u8, rest, "fLaC")) return at;
        if (std.mem.startsWith(u8, rest, "caff") or std.mem.startsWith(u8, rest, "OggS")) return null;
        if (std.mem.startsWith(u8, rest, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) return null;
        if (aiff.isAiff(rest) or wav.isWav(rest)) return null;
        if (plausibleAudioSync(rest)) return null;
        if (rest.len >= 8 and std.mem.eql(u8, rest[4..8], "ftyp")) return null;
    }
    return null;
}

/// The offset of the `fLaC` marker of the stream in `b`, for formats whose reader this port does
/// not have (they may still hold a FLAC stream behind tags or junk). `missing` is the error when
/// there is none. A complete ID3v2 tag with nothing after it, or a tag running past the end of
/// the data, is `error.Malformed` whatever the format.
fn locateFlac(b: []const u8, missing: AudioError) AudioError!usize {
    const start = skipId3v2(b);
    if (start > 0 and start >= b.len) return error.Malformed;
    return findFlac(b, start) orelse missing;
}

fn detectByMagic(b: []const u8, depth: u32) ?FileFormat {
    if (wav.isWav(b)) return .wav;
    if (aiff.isAiff(b)) return .aiff;
    if (b.len < 4) return null;
    const head = b[0..4];
    if (std.mem.eql(u8, head, "fLaC")) return .flac;
    if (std.mem.eql(u8, head, "OggS")) return .ogg;
    if (std.mem.eql(u8, head, "caff")) return .caf;
    if (std.mem.eql(u8, head, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) return .other;
    if (b.len >= 8 and std.mem.eql(u8, b[4..8], "ftyp")) {
        // MP4 / M4A: the sample entry inside `stsd` names the codec.
        if (std.mem.indexOf(u8, b, "stsd")) |p| {
            if (p + 20 <= b.len and std.mem.eql(u8, b[p + 16 .. p + 20], "alac")) return .alac;
        }
        return .aac;
    }
    if (id3v2Len(b)) |len| {
        if (depth == 0 and len <= b.len) {
            if (detectByMagic(b[len..], 1)) |f| return f;
        }
        return .mp3;
    }
    if (b.len < 2) return null;
    const b0 = b[0];
    const b1 = b[1];
    if (b0 == 0xFF and (b1 & 0xE0) == 0xE0) {
        const layer = (b1 >> 1) & 0x3;
        if ((b1 & 0xF0) == 0xF0 and layer == 0) return .aac; // ADTS
        if (layer != 0) return .mp3;
    }
    return null;
}

fn sampleFormatOfBits(bps: u32) SampleFormat {
    return switch (bps) {
        1...8 => .int8,
        9...16 => .int16,
        17...24 => .int24,
        else => .int32,
    };
}

/// The info of a FLAC stream from its metadata: the container preflight (`checkMetadata`), then
/// STREAMINFO, which must be the first block. Empty streams go through `emptyStreamInfo`, which
/// reads them without looking for a first frame.
fn flacInfo(bytes: []const u8, at: usize) AudioError!AudioInfo {
    if (!std.mem.startsWith(u8, bytes[at..], "fLaC")) return error.Malformed;
    try flac.checkMetadata(bytes, at);
    if (flac.emptyStreamInfo(bytes, at)) |info| return info;
    const head = pcm.beU32(bytes, at + 4) orelse return error.Malformed;
    if (((head >> 24) & 0x7f) != 0 or (head & 0x00ff_ffff) != 34) return error.Malformed;
    // STREAMINFO from the sample rate on: 20 bits rate, 3 bits channels - 1, 5 bits bits per
    // sample - 1, 36 bits total samples.
    const packed_bits = pcm.beU64(bytes, at + 18) orelse return error.Malformed;
    const sample_rate: u32 = @intCast(packed_bits >> 44);
    if (sample_rate == 0) return error.Malformed;
    const channels: u16 = @intCast(((packed_bits >> 41) & 0x7) + 1);
    const bps: u32 = @intCast(((packed_bits >> 36) & 0x1f) + 1);
    return .{
        .format = .flac,
        .sample_format = sampleFormatOfBits(bps),
        .sample_rate = sample_rate,
        .channels = channels,
        .frames = packed_bits & 0xf_ffff_ffff,
    };
}

/// Empty FLAC streams decode to an empty buffer. Streams with samples need a FLAC sample decoder
/// that libs/io does not have yet, so they answer `error.Unsupported`.
fn decodeFlac(gpa: std.mem.Allocator, bytes: []const u8, at: usize) AudioError!Decoded {
    const info = try flacInfo(bytes, at);
    if (info.frames != 0) return error.Unsupported;
    const buf = try AudioBuffer.init(gpa, info.sample_rate, @as(usize, info.channels), 0);
    return .{ .info = info, .buffer = buf };
}

// ---------------------------------------------------------------------------
// Tests (ported from roundtrip.rs, stream.rs, decode_read_list.rs and malformed.rs)
// ---------------------------------------------------------------------------

/// Largest channel count the stream tests feed the encoder.
const max_test_channels = 16;

/// A planar sine buffer at `sr`, one frequency per channel (roundtrip.rs `sine`).
fn sine(gpa: std.mem.Allocator, sr: u32, channels: usize, frames: usize) !AudioBuffer {
    const b = try AudioBuffer.init(gpa, sr, channels, frames);
    for (b.channels, 0..) |ch, c| {
        const f: f32 = 220.0 * (@as(f32, @floatFromInt(c)) + 1.0);
        const phase: f32 = @floatFromInt(c);
        for (ch, 0..) |*s, i| {
            const t: f32 = 2.0 * std.math.pi * f * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
            s.* = 0.8 * @sin(t + phase);
        }
    }
    return b;
}

/// The tone of stream.rs `tone`: a different sine per channel, peaking above full scale.
fn tone(gpa: std.mem.Allocator, channels: usize, frames: usize) !AudioBuffer {
    const b = try AudioBuffer.init(gpa, 44_100, channels, frames);
    for (b.channels, 0..) |ch, c| {
        for (ch, 0..) |*s, i| {
            s.* = @sin(@as(f32, @floatFromInt(i * (c + 3))) * 0.013) * 1.2;
        }
    }
    return b;
}

/// The hostile-input fixture: 300 frames of a 0.5 sine (malformed.rs `small`). Caller frees.
fn smallFile(gpa: std.mem.Allocator, format: FileFormat, depth: BitDepth, channels: usize) ![]u8 {
    var b = try AudioBuffer.init(gpa, 44_100, channels, 300);
    defer b.deinit();
    for (b.channels) |ch| {
        for (ch, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    }
    return encode(gpa, &b, .{ .format = format, .bit_depth = depth, .dither = false, .bwf = null });
}

fn tolerance(depth: BitDepth, dither: bool) f32 {
    const lsb: f32 = switch (depth) {
        .int16 => 1.0 / 32768.0,
        .int24 => 1.0 / 8_388_608.0,
        .int32 => 1e-7,
        .float32 => 0.0,
    };
    return lsb * (if (dither) @as(f32, 1.6) else @as(f32, 0.6)) + 1e-7;
}

fn maxErr(a: *const AudioBuffer, b: *const AudioBuffer) !f32 {
    try testing.expectEqual(a.numChannels(), b.numChannels());
    try testing.expectEqual(a.frames(), b.frames());
    var worst: f32 = 0.0;
    for (a.channels, b.channels) |x, y| {
        for (x, y) |p, q| worst = @max(worst, @abs(p - q));
    }
    return worst;
}

fn expectBuffersEqual(a: *const AudioBuffer, b: *const AudioBuffer) !void {
    try testing.expectEqual(a.numChannels(), b.numChannels());
    try testing.expectEqual(a.frames(), b.frames());
    for (a.channels, b.channels) |x, y| try testing.expectEqualSlices(f32, x, y);
}

fn bwfEqual(a: ?BwfInfo, b: ?BwfInfo) bool {
    if (a == null or b == null) return a == null and b == null;
    const x = a.?;
    const y = b.?;
    return std.mem.eql(u8, x.description, y.description) and
        std.mem.eql(u8, x.originator, y.originator) and
        std.mem.eql(u8, x.originator_reference, y.originator_reference) and
        std.mem.eql(u8, x.origination_date, y.origination_date) and
        std.mem.eql(u8, x.origination_time, y.origination_time) and
        x.time_reference == y.time_reference;
}

fn expectInfoEqual(a: AudioInfo, b: AudioInfo) !void {
    try testing.expectEqual(a.format, b.format);
    try testing.expectEqual(a.sample_format, b.sample_format);
    try testing.expectEqual(a.sample_rate, b.sample_rate);
    try testing.expectEqual(a.channels, b.channels);
    try testing.expectEqual(a.frames, b.frames);
    try testing.expect(bwfEqual(a.bwf, b.bwf));
}

/// The planar view of `buf` that `write` takes, held in `out`.
fn planesOf(buf: *const AudioBuffer, out: *[max_test_channels][]const f32) []const []const f32 {
    for (buf.channels, 0..) |ch, c| out[c] = ch;
    return out[0..buf.numChannels()];
}

fn expectedSf(d: BitDepth) SampleFormat {
    return switch (d) {
        .int16 => .int16,
        .int24 => .int24,
        .int32 => .int32,
        .float32 => .float32,
    };
}

const depths = [_]BitDepth{ .int16, .int24, .int32, .float32 };

test "wav_and_aiff_roundtrip_all_depths_and_layouts" {
    const gpa = testing.allocator;
    for ([_]FileFormat{ .wav, .aiff }) |format| {
        for (depths) |depth| {
            for ([_]usize{ 1, 2, 6 }) |channels| {
                for ([_]bool{ false, true }) |dither| {
                    var src = try sine(gpa, 48_000, channels, 4801);
                    defer src.deinit();
                    const opts: EncodeOptions = .{ .format = format, .bit_depth = depth, .dither = dither, .bwf = null };
                    const bytes = try encode(gpa, &src, opts);
                    defer gpa.free(bytes);
                    try testing.expectEqual(format, detectFormat(bytes, null));
                    const info = try probe(bytes, null);
                    try testing.expectEqual(format, info.format);
                    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
                    try testing.expectEqual(channels, @as(usize, info.channels));
                    try testing.expectEqual(@as(u64, 4801), info.frames);
                    try testing.expectEqual(expectedSf(depth), info.sample_format);
                    var dec = try decode(gpa, bytes, null);
                    defer dec.buffer.deinit();
                    try expectInfoEqual(dec.info, info);
                    try testing.expectEqual(@as(u32, 48_000), dec.buffer.sample_rate);
                    const err = try maxErr(&src, &dec.buffer);
                    try testing.expect(err <= tolerance(depth, dither));
                }
            }
        }
    }
}

test "flac_roundtrip_is_lossless_vs_wav" {
    const gpa = testing.allocator;
    for ([_]BitDepth{ .int16, .int24, .int32 }) |depth| {
        for ([_]usize{ 1, 2, 6 }) |channels| {
            // Spans several blocks plus a short final block.
            var src = try sine(gpa, 44_100, channels, 4096 * 2 + 17);
            defer src.deinit();
            const wav_bytes = try encode(gpa, &src, .{ .format = .wav, .bit_depth = depth, .dither = false, .bwf = null });
            defer gpa.free(wav_bytes);
            const flac_bytes = try encode(gpa, &src, .{ .format = .flac, .bit_depth = depth, .dither = false, .bwf = null });
            defer gpa.free(flac_bytes);
            try testing.expectEqual(FileFormat.flac, detectFormat(flac_bytes, null));
            const info = try probe(flac_bytes, null);
            try testing.expectEqual(FileFormat.flac, info.format);
            try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
            try testing.expectEqual(channels, @as(usize, info.channels));
            try testing.expectEqual(@as(u64, @intCast(src.frames())), info.frames);
            try testing.expectEqual(expectedSf(depth), info.sample_format);
            var from_wav = try decode(gpa, wav_bytes, null);
            defer from_wav.buffer.deinit();
            if (depth != .int32) try testing.expect(flac_bytes.len < wav_bytes.len);
        }
    }
    // The sample comparison (`decode(flac) == decode(wav)`) needs a FLAC sample decoder; see the
    // module doc. Every check above ran.
    return error.SkipZigTest;
}

test "flac_handles_silence_noise_full_scale_and_odd_rates" {
    const gpa = testing.allocator;
    const frames = 10_000;
    var b = try AudioBuffer.init(gpa, 37_123, 3, frames);
    defer b.deinit();
    var seed: u32 = 1;
    for (0..frames) |i| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        b.channels[1][i] = (@as(f32, @floatFromInt(seed)) / @as(f32, @floatFromInt(std.math.maxInt(u32)))) * 2.0 - 1.0; // white noise
        b.channels[2][i] = if (i % 2 == 0) 1.5 else -1.5; // clipped full-scale square
    }
    for ([_]BitDepth{ .int16, .int24, .int32 }) |depth| {
        for ([_]bool{ false, true }) |dither| {
            const flac_bytes = try encode(gpa, &b, .{ .format = .flac, .bit_depth = depth, .dither = dither, .bwf = null });
            defer gpa.free(flac_bytes);
            const info = try probe(flac_bytes, null);
            try testing.expectEqual(@as(u32, 37_123), info.sample_rate);
            try testing.expectEqual(@as(u64, frames), info.frames);
        }
    }
    // Decoded samples against the WAV decode need a FLAC sample decoder (see the module doc).
    return error.SkipZigTest;
}

test "flac_rejects_unsupported_layouts" {
    const gpa = testing.allocator;
    var stereo = try sine(gpa, 48_000, 2, 10);
    defer stereo.deinit();
    try testing.expectError(error.Unsupported, encode(gpa, &stereo, .{ .format = .flac, .bit_depth = .float32, .dither = false, .bwf = null }));
    var nine = try sine(gpa, 48_000, 9, 10);
    defer nine.deinit();
    try testing.expect(std.meta.isError(encode(gpa, &nine, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null })));
    var fast = try sine(gpa, 700_000, 1, 10);
    defer fast.deinit();
    try testing.expect(std.meta.isError(encode(gpa, &fast, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null })));
    // Tiny buffers still encode; their one frame is counted by the probe.
    var one = try sine(gpa, 48_000, 2, 1);
    defer one.deinit();
    const bytes = try encode(gpa, &one, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null });
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u64, 1), (try probe(bytes, null)).frames);
    // Decoding the one frame needs a FLAC sample decoder (see the module doc).
    return error.SkipZigTest;
}

test "bwf_roundtrip" {
    const gpa = testing.allocator;
    const bwf: BwfInfo = .{
        .description = "Scene 12 take 3",
        .originator = "SoundCraft",
        .originator_reference = "SC-0001",
        .origination_date = "2026-10-06",
        .origination_time = "12:34:56",
        .time_reference = 0x1_2345_6789, // > 32 bits
    };
    var src = try sine(gpa, 96_000, 2, 1000);
    defer src.deinit();
    for (depths) |depth| {
        const opts: EncodeOptions = .{ .format = .wav, .bit_depth = depth, .dither = false, .bwf = bwf };
        const bytes = try encode(gpa, &src, opts);
        defer gpa.free(bytes);
        const info = try probe(bytes, null);
        try testing.expect(bwfEqual(info.bwf, bwf));
        var dec = try decode(gpa, bytes, null);
        defer dec.buffer.deinit();
        try testing.expect(bwfEqual(dec.info.bwf, bwf));
        // RF64 layout reads back identically.
        const rf64 = try encodeWavRf64(gpa, &src, opts);
        defer gpa.free(rf64);
        try testing.expectEqualSlices(u8, "RF64", rf64[0..4]);
        var rdec = try decode(gpa, rf64, null);
        defer rdec.buffer.deinit();
        try testing.expect(bwfEqual(rdec.info.bwf, bwf));
        try testing.expectEqual(@as(u64, 1000), rdec.info.frames);
        try expectBuffersEqual(&rdec.buffer, &dec.buffer);
    }
    // Overlong strings are truncated to the field width, not an error.
    const long = try gpa.alloc(u8, 400);
    defer gpa.free(long);
    @memset(long, 'x');
    const bytes = try encode(gpa, &src, .{ .bwf = .{ .description = long } });
    defer gpa.free(bytes);
    const info = try probe(bytes, null);
    try testing.expectEqual(@as(usize, 256), info.bwf.?.description.len);
}

test "wav_header_layout" {
    const gpa = testing.allocator;
    var s2 = try sine(gpa, 44_100, 2, 10);
    defer s2.deinit();
    const b16 = try encode(gpa, &s2, .{ .bit_depth = .int16 });
    defer gpa.free(b16);
    // Plain PCM for 16-bit stereo; extensible otherwise.
    const fmt16 = std.mem.indexOf(u8, b16, "fmt ").?;
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b16[fmt16 + 8 ..][0..2], .little));
    const b24 = try encode(gpa, &s2, .{});
    defer gpa.free(b24);
    const fmt24 = std.mem.indexOf(u8, b24, "fmt ").?;
    try testing.expectEqual(@as(u16, 0xFFFE), std.mem.readInt(u16, b24[fmt24 + 8 ..][0..2], .little));
    const riff = std.mem.readInt(u32, b24[4..8], .little);
    try testing.expectEqual(@as(usize, riff) + 8, b24.len);
    // Odd data length (24-bit mono, odd frames) gets a pad byte.
    var s1 = try sine(gpa, 44_100, 1, 3);
    defer s1.deinit();
    const odd = try encode(gpa, &s1, .{});
    defer gpa.free(odd);
    try testing.expectEqual(@as(usize, 0), odd.len % 2);
    var dec = try decode(gpa, odd, null);
    defer dec.buffer.deinit();
    try testing.expectEqual(@as(usize, 3), dec.buffer.frames());
}

test "aiff_float_is_aifc" {
    const gpa = testing.allocator;
    var s = try sine(gpa, 44_100, 2, 10);
    defer s.deinit();
    const f = try encode(gpa, &s, .{ .format = .aiff, .bit_depth = .float32 });
    defer gpa.free(f);
    try testing.expectEqualSlices(u8, "AIFC", f[8..12]);
    try testing.expect(std.mem.indexOf(u8, f, "fl32") != null);
    const i = try encode(gpa, &s, .{ .format = .aiff });
    defer gpa.free(i);
    try testing.expectEqualSlices(u8, "AIFF", i[8..12]);
    const form = std.mem.readInt(u32, i[4..8], .big);
    try testing.expectEqual(@as(usize, form) + 8, i.len);
}

test "unusual_sample_rates_roundtrip" {
    const gpa = testing.allocator;
    const rates = [_]u32{ 1, 8_000, 11_025, 22_050, 44_100, 88_200, 176_400, 192_000, 352_800, 384_000, 768_000 };
    for (rates) |sr| {
        for ([_]FileFormat{ .wav, .aiff }) |format| {
            var src = try sine(gpa, sr, 1, 8);
            defer src.deinit();
            const bytes = try encode(gpa, &src, .{ .format = format });
            defer gpa.free(bytes);
            try testing.expectEqual(sr, (try probe(bytes, null)).sample_rate);
        }
    }
}

test "encode_rejects_bad_buffers_and_formats" {
    const gpa = testing.allocator;
    // A buffer with no channels (AudioBuffer::default in Rust).
    var empty: AudioBuffer = .{ .gpa = gpa, .sample_rate = 0, .channels = &.{} };
    try testing.expect(std.meta.isError(encode(gpa, &empty, .{})));
    var zero_rate = try AudioBuffer.init(gpa, 0, 2, 10);
    defer zero_rate.deinit();
    try testing.expect(std.meta.isError(encode(gpa, &zero_rate, .{})));
    var s = try sine(gpa, 48_000, 1, 10);
    defer s.deinit();
    for ([_]FileFormat{ .mp3, .ogg, .aac, .alac, .caf, .other }) |f| {
        try testing.expectError(error.Unsupported, encode(gpa, &s, .{ .format = f }));
    }
    // Non-finite samples are sanitized; only integer output clips finite samples.
    var b = try AudioBuffer.init(gpa, 48_000, 1, 4);
    defer b.deinit();
    b.channels[0][0] = std.math.nan(f32);
    b.channels[0][1] = std.math.inf(f32);
    b.channels[0][2] = -5.0;
    b.channels[0][3] = 0.5;
    for ([_]FileFormat{ .wav, .aiff, .flac }) |format| {
        for (depths) |depth| {
            if (format == .flac and depth == .float32) continue;
            const bytes = try encode(gpa, &b, .{ .format = format, .bit_depth = depth });
            defer gpa.free(bytes);
            // FLAC samples are checked once a FLAC sample decoder exists (see the module doc).
            if (format == .flac) continue;
            var dec = try decode(gpa, bytes, null);
            defer dec.buffer.deinit();
            try testing.expectEqual(@as(f32, 0.0), dec.buffer.channels[0][0]);
            try testing.expect(dec.buffer.channels[0][1] > 0.99 and dec.buffer.channels[0][1] <= 1.0);
            const want: f32 = if (depth == .float32) -5.0 else -1.0;
            try testing.expectEqual(want, dec.buffer.channels[0][2]);
        }
    }
    // Ragged channels encode the common length.
    var ragged = try AudioBuffer.init(gpa, 48_000, 2, 10);
    defer ragged.deinit();
    for (ragged.channels[0]) |*x| x.* = 0.1;
    ragged.channels[1] = try gpa.realloc(ragged.channels[1], 7);
    @memset(ragged.channels[1], 0.2);
    const bytes = try encode(gpa, &ragged, .{});
    defer gpa.free(bytes);
    var dec = try decode(gpa, bytes, null);
    defer dec.buffer.deinit();
    try testing.expectEqual(@as(usize, 7), dec.buffer.frames());
}

test "audio_buffer_helpers" {
    const gpa = testing.allocator;
    var b = try AudioBuffer.fromInterleaved(gpa, 48_000, 2, &.{ 0.1, -0.2, 0.3, -0.4, 0.5 });
    defer b.deinit();
    try testing.expectEqual(@as(usize, 2), b.frames());
    try testing.expectEqual(@as(usize, 2), b.numChannels());
    const inter = try b.interleaved();
    defer gpa.free(inter);
    try testing.expectEqualSlices(f32, &.{ 0.1, -0.2, 0.3, -0.4 }, inter);
    try testing.expectApproxEqAbs(@as(f32, 0.4), b.peak(), 1e-7);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 48_000.0), b.durationSecs(), 1e-12);
    var mono = try AudioBuffer.fromInterleaved(gpa, 1, 0, &.{1.0});
    defer mono.deinit();
    try testing.expectEqual(@as(usize, 0), mono.numChannels());
    var silent = try AudioBuffer.init(gpa, 0, 1, 5);
    defer silent.deinit();
    try testing.expectEqual(@as(f64, 0.0), silent.durationSecs());
}

test "serde_types_roundtrip" {
    // Rust derives serde on the option and info types. Zig structs need no serializer for this
    // port; nothing here reads or writes JSON, so there is nothing to check.
    return error.SkipZigTest;
}

test "multichannel_wav_speaker_masks" {
    const gpa = testing.allocator;
    const opts: EncodeOptions = .{ .format = .wav, .bit_depth = .int24, .dither = false, .bwf = null };
    for ([_]struct { n: usize, mask: u32 }{ .{ .n = 6, .mask = 0x3F }, .{ .n = 8, .mask = 0x63F }, .{ .n = 12, .mask = 0x2_D63F } }) |case| {
        var b = try AudioBuffer.init(gpa, 48_000, case.n, 64);
        defer b.deinit();
        for (b.channels, 0..) |ch, c| @memset(ch, 0.01 * @as(f32, @floatFromInt(c)));
        const bytes = try encode(gpa, &b, opts);
        defer gpa.free(bytes);
        try testing.expectEqual(@as(?u32, case.mask), wavChannelMask(bytes));
        var dec = try decode(gpa, bytes, "wav");
        defer dec.buffer.deinit();
        try testing.expectEqual(case.n, dec.buffer.numChannels());
    }
    // Explicit masks: 7.0 (sides + rears, no LFE) and Ambisonics (no positions).
    var seven = try AudioBuffer.init(gpa, 48_000, 7, 64);
    defer seven.deinit();
    const b7 = try encodeWithChannelMask(gpa, &seven, opts, 0x637);
    defer gpa.free(b7);
    try testing.expectEqual(@as(?u32, 0x637), wavChannelMask(b7));
    var four = try AudioBuffer.init(gpa, 48_000, 4, 64);
    defer four.deinit();
    const b4 = try encodeWithChannelMask(gpa, &four, opts, 0);
    defer gpa.free(b4);
    try testing.expectEqual(@as(?u32, 0), wavChannelMask(b4));
    // Plain 16-bit stereo stays a plain PCM header.
    var stereo = try AudioBuffer.init(gpa, 48_000, 2, 64);
    defer stereo.deinit();
    const o16: EncodeOptions = .{ .format = .wav, .bit_depth = .int16, .dither = false, .bwf = null };
    const b2 = try encodeWithChannelMask(gpa, &stereo, o16, 0x3);
    defer gpa.free(b2);
    try testing.expectEqual(@as(?u32, null), wavChannelMask(b2));
}

test "float_wav_header_is_rewritten_in_place_as_the_file_grows" {
    const gpa = testing.allocator;
    var take = try sine(gpa, 48_000, 2, 1_000);
    defer take.deinit();
    const head0 = try wavFloatHeader(gpa, 2, 48_000, 0);
    defer gpa.free(head0);
    const len = head0.len;

    const inter = try take.interleaved();
    defer gpa.free(inter);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, head0);
    for (inter) |v| {
        const bits: u32 = @bitCast(v);
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, bits)));
    }
    {
        var dec = try decode(gpa, file.items, null);
        defer dec.buffer.deinit();
        try testing.expectEqual(@as(usize, 1_000), dec.buffer.frames());
    }
    for ([_]u64{ 600, 1_000 }) |frames| {
        const head = try wavFloatHeader(gpa, 2, 48_000, frames);
        defer gpa.free(head);
        try testing.expectEqual(len, head.len);
        @memcpy(file.items[0..len], head);
        var dec = try decode(gpa, file.items, null);
        defer dec.buffer.deinit();
        try testing.expectEqual(@as(usize, @intCast(frames)), dec.buffer.frames());
    }
    const whole = try encode(gpa, &take, .{ .bit_depth = .float32 });
    defer gpa.free(whole);
    try testing.expectEqualSlices(u8, whole, file.items);

    const big = try wavFloatHeader(gpa, 2, 48_000, 600_000_000);
    defer gpa.free(big);
    try testing.expectEqualSlices(u8, "RF64", big[0..4]);
    try testing.expectEqual(len, big.len);
    try testing.expectError(error.Encode, wavFloatHeader(gpa, 0, 48_000, 0));
    try testing.expectError(error.Encode, wavFloatHeader(gpa, 2, 0, 0));
}

test "float_wav_header_rejects_a_frame_count_whose_total_size_overflows" {
    // 4 bytes per frame: the data length fits in u64, but adding the header to it does not.
    const frames: u64 = std.math.maxInt(u64) / 4;
    try testing.expectError(error.TooLarge, wavFloatHeader(testing.allocator, 1, 48_000, frames));
}

test "zero_frame_flac_round_trips_like_wav_and_aiff" {
    const gpa = testing.allocator;
    for ([_]FileFormat{ .wav, .aiff, .flac }) |format| {
        for ([_]BitDepth{ .int16, .int24 }) |depth| {
            for ([_]usize{ 1, 2 }) |channels| {
                const opts: EncodeOptions = .{ .format = format, .bit_depth = depth };
                var empty = try AudioBuffer.init(gpa, 48_000, channels, 0);
                defer empty.deinit();
                const bytes = try encode(gpa, &empty, opts);
                defer gpa.free(bytes);
                const info = try probe(bytes, null);
                try testing.expectEqual(format, info.format);
                try testing.expectEqual(expectedSf(depth), info.sample_format);
                try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
                try testing.expectEqual(@as(u64, 0), info.frames);
                try testing.expectEqual(channels, @as(usize, info.channels));
                var dec = try decode(gpa, bytes, null);
                defer dec.buffer.deinit();
                try testing.expectEqual(@as(u64, 0), dec.info.frames);
                try testing.expectEqual(@as(usize, 0), dec.buffer.frames());
                try testing.expectEqual(channels, dec.buffer.numChannels());
            }
        }
    }
}

test "flac_claiming_frames_but_holding_none_still_errors" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 2, 0);
    defer empty.deinit();
    const bytes = try encode(gpa, &empty, .{ .format = .flac, .bit_depth = .int16 });
    defer gpa.free(bytes);
    // STREAMINFO total samples (low byte of the 36-bit field) = 1.
    bytes[25] = 1;
    try testing.expectEqual(@as(u64, 1), (try probe(bytes, null)).frames);
    // Frames the file does not hold: refused (by `Unsupported` today; the sample decoder is
    // missing, and this stream would fail on the missing frame otherwise).
    try testing.expect(std.meta.isError(decode(gpa, bytes, null)));
}

test "bwf_truncation_keeps_utf8_boundaries" {
    const gpa = testing.allocator;
    var src = try sine(gpa, 48_000, 1, 10);
    defer src.deinit();
    const a31 = try gpa.alloc(u8, 31);
    defer gpa.free(a31);
    @memset(a31, 'a');
    const originator = try std.mem.concat(gpa, u8, &.{ a31, "é" });
    defer gpa.free(originator);
    const d255 = try gpa.alloc(u8, 255);
    defer gpa.free(d255);
    @memset(d255, 'd');
    const description = try std.mem.concat(gpa, u8, &.{ d255, "é" });
    defer gpa.free(description);
    const bytes = try encode(gpa, &src, .{ .format = .wav, .bwf = .{ .originator = originator, .description = description } });
    defer gpa.free(bytes);
    const out = (try probe(bytes, null)).bwf.?;
    try testing.expectEqualSlices(u8, a31, out.originator);
    try testing.expectEqualSlices(u8, d255, out.description);
}

// --- stream.rs ---

/// A `Write + Seek` sink for the stream tests: an in-memory byte buffer with a position and an
/// optional byte budget. A write past the budget stores a prefix and fails (FailAfter in Rust).
const TestSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    budget: usize = std.math.maxInt(usize),

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(self.gpa);
    }

    pub fn writeAll(self: *TestSink, data: []const u8) !void {
        const n = @min(data.len, self.budget);
        self.budget -= n;
        const end = self.pos + n;
        if (end > self.bytes.items.len) try self.bytes.appendNTimes(self.gpa, 0, end - self.bytes.items.len);
        @memcpy(self.bytes.items[self.pos..end], data[0..n]);
        self.pos = end;
        if (n < data.len) return error.SinkFull;
    }

    pub fn seekTo(self: *TestSink, pos: u64) !void {
        self.pos = std.math.cast(usize, pos) orelse return error.SeekOutOfRange;
    }

    pub fn seekToEnd(self: *TestSink) !void {
        self.pos = self.bytes.items.len;
    }

    pub fn tell(self: *const TestSink) !u64 {
        return @intCast(self.pos);
    }

    pub fn flush(self: *TestSink) !void {
        _ = self;
    }
};

/// Streams `buf` through a FileEncoder in blocks of 1, 7, 4095, 4097, 333 frames (cycled) into a
/// sink that already holds "pre". Returns the sink's bytes; caller frees.
fn streamed(gpa: std.mem.Allocator, buf: *const AudioBuffer, opts: EncodeOptions, mask: ?u32) ![]u8 {
    var sink: TestSink = .{ .gpa = gpa };
    defer sink.deinit();
    try sink.bytes.appendSlice(gpa, "pre");
    sink.pos = 3;
    var enc: FileEncoder(TestSink) = undefined;
    try enc.init(gpa, &sink, opts, buf.numChannels(), buf.sample_rate, mask);
    defer enc.deinit();
    const lens = [_]usize{ 1, 7, 4095, 4097, 333 };
    var planes_buf: [max_test_channels][]const f32 = undefined;
    var start: usize = 0;
    var i: usize = 0;
    while (start < buf.frames()) : (i += 1) {
        const len = @min(lens[i % lens.len], buf.frames() - start);
        for (buf.channels, 0..) |ch, c| planes_buf[c] = ch[start .. start + len];
        try enc.write(planes_buf[0..buf.numChannels()], len);
        start += len;
    }
    _ = try enc.finish();
    return gpa.dupe(u8, sink.bytes.items);
}

test "streamed_files_match_whole_buffer_encodes" {
    const gpa = testing.allocator;
    const bwf: BwfInfo = .{ .description = "take", .time_reference = 123_456 };
    const Case = struct { format: FileFormat, depth: BitDepth, dither: bool, bwf: ?BwfInfo, mask: ?u32 };
    const cases = [_]Case{
        .{ .format = .wav, .depth = .int24, .dither = true, .bwf = null, .mask = null },
        .{ .format = .wav, .depth = .float32, .dither = false, .bwf = null, .mask = null },
        .{ .format = .wav, .depth = .int16, .dither = true, .bwf = bwf, .mask = 0x60F },
        .{ .format = .aiff, .depth = .int24, .dither = true, .bwf = null, .mask = null },
        .{ .format = .aiff, .depth = .float32, .dither = false, .bwf = null, .mask = null },
        .{ .format = .flac, .depth = .int16, .dither = true, .bwf = null, .mask = null },
        .{ .format = .flac, .depth = .int24, .dither = false, .bwf = null, .mask = null },
    };
    for (cases) |c| {
        const opts: EncodeOptions = .{ .format = c.format, .bit_depth = c.depth, .dither = c.dither, .bwf = c.bwf };
        for ([_]usize{ 1, 6 }) |channels| {
            var buf = try tone(gpa, channels, 20_001);
            defer buf.deinit();
            const whole = if (c.mask) |m| try encodeWithChannelMask(gpa, &buf, opts, m) else try encode(gpa, &buf, opts);
            defer gpa.free(whole);
            const streamed_bytes = try streamed(gpa, &buf, opts, c.mask);
            defer gpa.free(streamed_bytes);
            const expected = try std.mem.concat(gpa, u8, &.{ "pre", whole });
            defer gpa.free(expected);
            try testing.expectEqualSlices(u8, expected, streamed_bytes);
        }
    }
}

test "a_failed_write_poisons_the_encoder" {
    const gpa = testing.allocator;
    var buf = try tone(gpa, 2, 20_001);
    defer buf.deinit();
    var planes_buf: [max_test_channels][]const f32 = undefined;
    for ([_]FileFormat{ .wav, .aiff, .flac }) |format| {
        const opts: EncodeOptions = .{ .format = format, .bit_depth = .int16, .dither = false, .bwf = null };
        // The sink accepts 256 bytes (header and a prefix of the first block), then fails.
        var sink: TestSink = .{ .gpa = gpa, .budget = 256 };
        defer sink.deinit();
        var enc: FileEncoder(TestSink) = undefined;
        try enc.init(gpa, &sink, opts, 2, buf.sample_rate, null);
        defer enc.deinit();
        // The first write fails partway through the sink.
        if (enc.write(planesOf(&buf, &planes_buf), buf.frames())) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
        // Later calls must not claim success: the bytes on the sink no longer match the counters.
        try testing.expectError(error.Encode, enc.write(planesOf(&buf, &planes_buf), 16));
        try testing.expectError(error.Encode, enc.finish());
    }
}

test "blocks_past_a_format_limit_are_refused_before_anything_is_written" {
    const gpa = testing.allocator;
    var buf = try tone(gpa, 2, 100);
    defer buf.deinit();
    var planes_buf: [max_test_channels][]const f32 = undefined;
    const cases = [_]struct { format: FileFormat, limit: u64 }{
        .{ .format = .aiff, .limit = 1 << 30 },
        .{ .format = .flac, .limit = 1 << 36 },
    };
    for (cases) |c| {
        const opts: EncodeOptions = .{ .format = c.format, .bit_depth = .int16, .dither = false, .bwf = null };
        var sink: TestSink = .{ .gpa = gpa };
        defer sink.deinit();
        var enc: FileEncoder(TestSink) = undefined;
        try enc.init(gpa, &sink, opts, 2, buf.sample_rate, null);
        defer enc.deinit();
        try enc.write(planesOf(&buf, &planes_buf), 100);
        try enc.checkRoom(c.limit / 2);
        try testing.expectError(error.TooLarge, enc.checkRoom(c.limit));
        if (std.math.cast(usize, c.limit)) |frames| {
            const none: []const []const f32 = &.{};
            try testing.expectError(error.TooLarge, enc.write(none, frames));
        }
        _ = try enc.finish();
        const whole = try encode(gpa, &buf, opts);
        defer gpa.free(whole);
        try testing.expectEqualSlices(u8, whole, sink.bytes.items);
    }
}

// --- float_headroom.rs ---

/// `audio` encoded whole, or streamed in blocks of 4097 frames to cross the writer's 4096-frame
/// scratch boundary (float_headroom.rs `encoded`). The caller frees the result.
fn encodedFloat(gpa: std.mem.Allocator, audio: *const AudioBuffer, opts: EncodeOptions, streaming: bool) ![]u8 {
    if (!streaming) return encode(gpa, audio, opts);
    var sink: TestSink = .{ .gpa = gpa };
    defer sink.deinit();
    var enc: FileEncoder(TestSink) = undefined;
    try enc.init(gpa, &sink, opts, audio.numChannels(), audio.sample_rate, null);
    defer enc.deinit();
    var planes_buf: [max_test_channels][]const f32 = undefined;
    var start: usize = 0;
    while (start < audio.frames()) {
        const end = @min(start + 4097, audio.frames());
        for (audio.channels, 0..) |ch, c| planes_buf[c] = ch[start..end];
        try enc.write(planes_buf[0..audio.numChannels()], end - start);
        start = end;
    }
    _ = try enc.finish();
    return gpa.dupe(u8, sink.bytes.items);
}

fn assertFloatHeadroom(streaming: bool) !void {
    const gpa = testing.allocator;
    const samples = [_]f32{
        -std.math.floatMax(f32),
        -2.0,
        -1.25,
        -1.0,
        -0.5,
        -std.math.floatMin(f32),
        -@as(f32, @bitCast(@as(u32, 1))),
        -0.0,
        0.0,
        @as(f32, @bitCast(@as(u32, 1))),
        std.math.floatMin(f32),
        0.5,
        1.0,
        1.25,
        2.0,
        std.math.floatMax(f32),
    };
    const frames = 4103;
    for ([_]FileFormat{ .wav, .aiff }) |format| {
        for ([_]bool{ false, true }) |dither| {
            for ([_]usize{ 1, 2 }) |channels| {
                var audio = try AudioBuffer.init(gpa, 48_000, channels, frames);
                defer audio.deinit();
                for (audio.channels, 0..) |ch, c| {
                    for (ch, 0..) |*s, i| s.* = samples[(i + c) % samples.len];
                }
                const opts: EncodeOptions = .{ .format = format, .bit_depth = .float32, .dither = dither, .bwf = null };
                const bytes = try encodedFloat(gpa, &audio, opts, streaming);
                defer gpa.free(bytes);

                // The stored bytes are exactly each sample's own bits, frame-major.
                const inter = try audio.interleaved();
                defer gpa.free(inter);
                const pcm_bytes = try gpa.alloc(u8, inter.len * 4);
                defer gpa.free(pcm_bytes);
                for (inter, 0..) |v, i| {
                    const bits: u32 = @bitCast(v);
                    std.mem.writeInt(u32, pcm_bytes[i * 4 ..][0..4], bits, if (format == .wav) .little else .big);
                }
                try testing.expect(std.mem.endsWith(u8, bytes, pcm_bytes));

                var dec = try decode(gpa, bytes, null);
                defer dec.buffer.deinit();
                try testing.expectEqual(SampleFormat.float32, dec.info.sample_format);
                try testing.expectEqual(@as(u32, 48_000), dec.buffer.sample_rate);
                try testing.expectEqual(channels, dec.buffer.numChannels());
                try testing.expectEqual(@as(usize, frames), dec.buffer.frames());
                for (dec.buffer.channels, audio.channels) |actual, expected| {
                    for (actual, expected) |a, e| {
                        try testing.expectEqual(@as(u32, @bitCast(e)), @as(u32, @bitCast(a)));
                    }
                }
            }
        }
    }
}

test "whole_file_float32_preserves_finite_headroom" {
    try assertFloatHeadroom(false);
}

test "streaming_float32_preserves_finite_headroom" {
    try assertFloatHeadroom(true);
}

test "float32_keeps_non_finite_sample_handling" {
    const gpa = testing.allocator;
    var audio = try AudioBuffer.init(gpa, 48_000, 1, 3);
    defer audio.deinit();
    audio.channels[0][0] = std.math.nan(f32);
    audio.channels[0][1] = -std.math.inf(f32);
    audio.channels[0][2] = std.math.inf(f32);
    const expected = [_]f32{ 0.0, -1.0, 1.0 };
    for ([_]FileFormat{ .wav, .aiff }) |format| {
        for ([_]bool{ false, true }) |streaming| {
            const opts: EncodeOptions = .{ .format = format, .bit_depth = .float32, .dither = false, .bwf = null };
            const bytes = try encodedFloat(gpa, &audio, opts, streaming);
            defer gpa.free(bytes);
            // Inspect the stored samples too: the decoder itself replaces non-finite values.
            var pcm_bytes: [12]u8 = undefined;
            for (expected, 0..) |v, i| {
                const bits: u32 = @bitCast(v);
                std.mem.writeInt(u32, pcm_bytes[i * 4 ..][0..4], bits, if (format == .wav) .little else .big);
            }
            try testing.expect(std.mem.endsWith(u8, bytes, &pcm_bytes));
            var dec = try decode(gpa, bytes, null);
            defer dec.buffer.deinit();
            try testing.expectEqualSlices(f32, &expected, dec.buffer.channels[0]);
        }
    }
}

test "integer_pcm_still_clips_at_full_scale" {
    const gpa = testing.allocator;
    var audio = try AudioBuffer.init(gpa, 48_000, 1, 9);
    defer audio.deinit();
    @memcpy(audio.channels[0], &[_]f32{ -2.0, -1.25, -1.0, -0.5, 0.0, 0.5, 1.0, 1.25, 2.0 });
    const Case = struct { depth: BitDepth, max: f32 };
    const cases = [_]Case{
        .{ .depth = .int16, .max = 32767.0 / 32768.0 },
        .{ .depth = .int24, .max = 8_388_607.0 / 8_388_608.0 },
        .{ .depth = .int32, .max = 1.0 },
    };
    for (cases) |case| {
        // FLAC samples cannot be decoded here (see the module doc); WAV and AIFF can.
        for ([_]FileFormat{ .wav, .aiff }) |format| {
            for ([_]bool{ false, true }) |streaming| {
                const opts: EncodeOptions = .{ .format = format, .bit_depth = case.depth, .dither = false, .bwf = null };
                const bytes = try encodedFloat(gpa, &audio, opts, streaming);
                defer gpa.free(bytes);
                var dec = try decode(gpa, bytes, null);
                defer dec.buffer.deinit();
                const want = [_]f32{ -1.0, -1.0, -1.0, -0.5, 0.0, 0.5, case.max, case.max, case.max };
                try testing.expectEqualSlices(f32, &want, dec.buffer.channels[0]);
            }
        }
    }
}

// --- decode_read_list.rs ---

/// A tiny AIFC file whose compression is `ulaw`: a native reader does not decode it.
const aifc_ulaw = "FORM\x00\x00\x00\x33AIFC" ++
    "COMM\x00\x00\x00\x16\x00\x01\x00\x00\x00\x01\x00\x08\x40\x0B\xFA\x00\x00\x00\x00\x00\x00\x00ulaw" ++
    "SSND\x00\x00\x00\x09\x00\x00\x00\x00\x80";

test "every_read_extension_probes_and_decodes" {
    const gpa = testing.allocator;
    // Tone at 8 kHz, 800 frames, as decode_read_list.rs generates.
    var tone8 = try AudioBuffer.init(gpa, 8_000, 1, 800);
    defer tone8.deinit();
    for (tone8.channels[0], 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    for (FileFormat.read_formats) |format| {
        for (format.extensions()) |ext| {
            // The formats this port reads natively: WAV, AIFF and FLAC (FLAC probe only, see below).
            // `.aifc` names compressed AIFF-C, which is answered `Unsupported` like the other codecs.
            const native = switch (format) {
                .wav, .aiff, .flac => !std.mem.eql(u8, ext, "aifc"),
                else => false,
            };
            if (!native) {
                // Detected from the hint (or the magic) and answered `Unsupported`, never guessed.
                const junk = [_]u8{ 0, 1, 2, 3 };
                const bytes: []const u8 = if (std.mem.eql(u8, ext, "aifc")) aifc_ulaw else &junk;
                try testing.expectError(error.Unsupported, probe(bytes, ext));
                try testing.expectError(error.Unsupported, decode(gpa, bytes, ext));
                continue;
            }
            const bytes: []u8 = blk: {
                if (std.mem.eql(u8, ext, "rf64")) {
                    break :blk try encodeWavRf64(gpa, &tone8, .{ .format = .wav, .bit_depth = .int16, .dither = false, .bwf = null });
                }
                const f: FileFormat = if (format == .wav) .wav else if (format == .aiff) .aiff else .flac;
                break :blk try encode(gpa, &tone8, .{ .format = f, .bit_depth = .int16, .dither = false, .bwf = null });
            };
            defer gpa.free(bytes);
            const info = try probe(bytes, ext);
            try testing.expect(info.channels >= 1);
            // FLAC sample decode is pending (see the module doc): probe only for it.
            if (format == .flac) continue;
            var dec = try decode(gpa, bytes, ext);
            defer dec.buffer.deinit();
            try testing.expect(dec.buffer.frames() > 0);
        }
    }
}

// --- malformed.rs (adapted to WAV, AIFF and FLAC) ---

test "detect_format_by_magic_and_hint" {
    const gpa = testing.allocator;
    const w = try smallFile(gpa, .wav, .int16, 1);
    defer gpa.free(w);
    try testing.expectEqual(FileFormat.wav, detectFormat(w, "mp3"));
    const a = try smallFile(gpa, .aiff, .int16, 1);
    defer gpa.free(a);
    try testing.expectEqual(FileFormat.aiff, detectFormat(a, null));
    const f = try smallFile(gpa, .flac, .int16, 1);
    defer gpa.free(f);
    try testing.expectEqual(FileFormat.flac, detectFormat(f, null));
    try testing.expectEqual(FileFormat.ogg, detectFormat("OggS\x00\x02rest", null));
    try testing.expectEqual(FileFormat.caf, detectFormat("caff\x00\x01\x00\x00", null));
    try testing.expectEqual(FileFormat.mp3, detectFormat("ID3\x04\x00\x00\x00\x00\x00\x00", null));
    try testing.expectEqual(FileFormat.flac, detectFormat("ID3\x04\x00\x00\x00\x00\x00\x02xxfLaC", null));
    try testing.expectEqual(FileFormat.mp3, detectFormat(&[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }, null));
    try testing.expectEqual(FileFormat.aac, detectFormat(&[_]u8{ 0xFF, 0xF1, 0x50, 0x80 }, null));
    try testing.expectEqual(FileFormat.alac, detectFormat("\x00\x00\x00\x20ftypM4A ....stsd\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x24alac", null));
    try testing.expectEqual(FileFormat.aac, detectFormat("\x00\x00\x00\x20ftypM4A ", null));
    try testing.expectEqual(FileFormat.wav, detectFormat("", ".WAV"));
    try testing.expectEqual(FileFormat.aiff, detectFormat("zz", "aif"));
    try testing.expectEqual(FileFormat.aac, detectFormat("zz", "m4a"));
    try testing.expectEqual(FileFormat.aac, detectFormat("zz", "M4B"));
    try testing.expectEqual(FileFormat.flac, detectFormat("zz", "flac"));
    try testing.expectEqual(FileFormat.other, detectFormat("zz", "xyz"));
    try testing.expectEqual(FileFormat.other, detectFormat("zz", null));
    try testing.expectEqual(FileFormat.other, detectFormat("", null));
}

test "every_truncation_is_handled" {
    const gpa = testing.allocator;
    const specs = [_]struct { format: FileFormat, depth: BitDepth, channels: usize }{
        .{ .format = .wav, .depth = .int16, .channels = 2 },
        .{ .format = .wav, .depth = .float32, .channels = 6 },
        .{ .format = .aiff, .depth = .int24, .channels = 1 },
        .{ .format = .aiff, .depth = .float32, .channels = 2 },
        .{ .format = .flac, .depth = .int16, .channels = 2 },
        .{ .format = .flac, .depth = .int24, .channels = 1 },
    };
    for (specs) |s| {
        const file = try smallFile(gpa, s.format, s.depth, s.channels);
        defer gpa.free(file);
        for (0..file.len) |n| {
            const cut = file[0..n];
            _ = probe(cut, null) catch null;
            if (decode(gpa, cut, null)) |dec_val| {
                var dec = dec_val;
                defer dec.buffer.deinit();
                try testing.expectEqual(@as(usize, dec.info.channels), dec.buffer.numChannels());
                try testing.expectEqual(dec.info.frames, @as(u64, @intCast(dec.buffer.frames())));
            } else |_| {}
        }
    }
}

test "every_single_byte_corruption_is_handled" {
    const gpa = testing.allocator;
    const specs = [_]struct { format: FileFormat, depth: BitDepth, channels: usize }{
        .{ .format = .wav, .depth = .int24, .channels = 2 },
        .{ .format = .aiff, .depth = .int16, .channels = 2 },
        .{ .format = .flac, .depth = .int16, .channels = 1 },
    };
    for (specs) |s| {
        const file = try smallFile(gpa, s.format, s.depth, s.channels);
        defer gpa.free(file);
        const f = try gpa.dupe(u8, file);
        defer gpa.free(f);
        for (0..file.len) |i| {
            const original = f[i];
            for ([_]u8{ 0x00, 0xFF, 0x7F, 0x80 }) |v| {
                f[i] = v;
                _ = probe(f, null) catch null;
                if (decode(gpa, f, null)) |dec_val| {
                    var dec = dec_val;
                    dec.buffer.deinit();
                } else |_| {}
            }
            f[i] = original;
        }
    }
}

test "garbage_in_compressed_containers_errors" {
    const gpa = testing.allocator;
    var garbage: [4096]u8 = undefined;
    for (&garbage, 0..) |*g, i| {
        const v: u32 = @as(u32, @intCast(i)) *% 2_654_435_761;
        g.* = @truncate(v >> 13);
    }
    const hints = [_]?[]const u8{ null, "mp3", "ogg", "flac", "m4a", "caf", "aac", "mkv", "wav", "aiff" };
    for (hints) |hint| {
        try testing.expect(std.meta.isError(decode(gpa, &garbage, hint)));
        try testing.expect(std.meta.isError(probe(&garbage, hint)));
    }
    const magics = [_][]const u8{ "fLaC", "OggS", "caff", "ID3\x03\x00\x00\x00\x00\x00\x00", &[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }, "\x00\x00\x00\x20ftypM4A " };
    for (magics) |magic| {
        const f = try std.mem.concat(gpa, u8, &.{ magic, &garbage });
        defer gpa.free(f);
        _ = probe(f, null) catch null;
        if (decode(gpa, f, null)) |dec_val| {
            var dec = dec_val;
            defer dec.buffer.deinit();
            try testing.expect(dec.buffer.frames() < 1_000_000);
        } else |_| {}
    }
    try testing.expect(std.meta.isError(decode(gpa, "", null)));
}

test "a_probed_container_that_disagrees_with_the_checked_marker_is_refused" {
    // Rust: the junk byte hides both magics, so the hint picks FLAC, and the probe reads the WAVE
    // behind it and refuses with "probed container". Without a symphonia probe there is no
    // WAVE-behind-junk reader, so the FLAC path sees no `fLaC` at offset 0 and answers Malformed.
    const gpa = testing.allocator;
    const wav_bytes = try smallFile(gpa, .wav, .int24, 2);
    defer gpa.free(wav_bytes);
    const flac_bytes = try smallFile(gpa, .flac, .int24, 2);
    defer gpa.free(flac_bytes);
    const bytes = try std.mem.concat(gpa, u8, &.{ &[_]u8{0}, wav_bytes, flac_bytes });
    defer gpa.free(bytes);
    try testing.expectError(error.Malformed, decode(gpa, bytes, "flac"));
}

/// An ID3v2.4 header whose syncsafe size field declares `size` bytes of tag body (malformed.rs
/// `id3_header`).
fn id3Header(size: u32) [10]u8 {
    return .{ 'I', 'D', '3', 4, 0, 0, @intCast((size >> 21) & 0x7F), @intCast((size >> 14) & 0x7F), @intCast((size >> 7) & 0x7F), @intCast(size & 0x7F) };
}

/// `body` wrapped in an ID3v2.4 tag (malformed.rs `id3_tag`). The caller frees it.
fn id3Tag(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const head = id3Header(@intCast(body.len));
    return std.mem.concat(gpa, u8, &.{ &head, body });
}

fn expectEmptyFlac(f: []const u8) !void {
    const gpa = testing.allocator;
    const info = try probe(f, null);
    try testing.expectEqual(FileFormat.flac, info.format);
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u16, 1), info.channels);
    try testing.expectEqual(@as(u64, 0), info.frames);
    var dec = try decode(gpa, f, null);
    defer dec.buffer.deinit();
    try testing.expectEqual(@as(usize, 0), dec.buffer.frames());
}

test "zero_frame_flac_after_a_prefix_is_still_empty" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac_bytes = try encode(gpa, &empty, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null });
    defer gpa.free(flac_bytes);
    const tag_bytes = try id3Tag(gpa, "tag");
    defer gpa.free(tag_bytes);
    const junk64: [64]u8 = @splat(0x7A);
    const junk16: [16]u8 = @splat(0x7A);
    const Case = struct { parts: []const []const u8, detected: FileFormat };
    const cases = [_]Case{
        .{ .parts = &.{ &junk64, flac_bytes }, .detected = .other },
        .{ .parts = &.{ tag_bytes, &junk16, flac_bytes }, .detected = .mp3 },
        .{ .parts = &.{ tag_bytes, tag_bytes, flac_bytes }, .detected = .mp3 },
        .{ .parts = &.{ tag_bytes, flac_bytes }, .detected = .flac },
    };
    for (cases) |c| {
        const f = try std.mem.concat(gpa, u8, c.parts);
        defer gpa.free(f);
        try testing.expectEqual(c.detected, detectFormat(f, null));
        try expectEmptyFlac(f);
    }
}

test "zero_frame_flac_after_a_false_mpeg_sync_is_still_empty" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac_bytes = try encode(gpa, &empty, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null });
    defer gpa.free(flac_bytes);
    const junks = [_][]const u8{ &.{ 0xFF, 0xE0, 0x00 }, &.{ 0xFF, 0xF0, 0x00 }, &.{ 0xFF, 0xFB, 0xF0, 0x00 } };
    for (junks) |junk| {
        const f = try std.mem.concat(gpa, u8, &.{ junk, flac_bytes });
        defer gpa.free(f);
        try expectEmptyFlac(f);
    }
}

test "a FLAC behind real MPEG audio is not found" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac_bytes = try encode(gpa, &empty, .{ .format = .flac, .bit_depth = .int16, .dither = false, .bwf = null });
    defer gpa.free(flac_bytes);
    // A valid MPEG-1 layer III header (128 kbit/s, 44.1 kHz) comes first: this is MP3 audio that
    // merely contains `fLaC` bytes later, so it is not read as a FLAC.
    const mp3_then_flac = try std.mem.concat(gpa, u8, &.{ &[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }, flac_bytes });
    defer gpa.free(mp3_then_flac);
    try testing.expectError(error.Unsupported, probe(mp3_then_flac, null));
    try testing.expectError(error.Unsupported, decode(gpa, mp3_then_flac, null));
}

test "truncated_or_oversized_id3_tags_are_malformed" {
    const gpa = testing.allocator;
    const short = try std.mem.concat(gpa, u8, &.{ &id3Header(100), "xx" });
    defer gpa.free(short);
    const huge = id3Header(0x0FFF_FFFF);
    const complete = try id3Tag(gpa, "tag");
    defer gpa.free(complete);
    for ([_][]const u8{ short, &huge, complete }) |f| {
        try testing.expectError(error.Malformed, probe(f, null));
        try testing.expectError(error.Malformed, decode(gpa, f, null));
    }
}

test "random_bytes_never_panic" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rng = prng.random();
    const hints = [_]?[]const u8{ null, "wav", "aiff", "flac", "mp3", "ogg" };
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const len = rng.uintLessThan(usize, 2048);
        const bytes = try gpa.alloc(u8, len);
        defer gpa.free(bytes);
        rng.bytes(bytes);
        const hint = hints[i % hints.len];
        _ = detectFormat(bytes, hint);
        _ = probe(bytes, hint) catch null;
        if (decode(gpa, bytes, hint)) |dec_val| {
            var dec = dec_val;
            dec.buffer.deinit();
        } else |_| {}
    }
}

test "random_bodies_behind_valid_headers_never_panic" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0002);
    const rng = prng.random();
    const headers = [_][]const u8{ "RIFF\xff\xff\xff\xffWAVE", "RF64\xff\xff\xff\xffWAVE", "FORM\xff\xff\xff\xffAIFC", "FORM\xff\xff\xff\xffAIFF" };
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const body_len = rng.uintLessThan(usize, 1024);
        const f = try gpa.alloc(u8, headers[i % headers.len].len + body_len);
        defer gpa.free(f);
        @memcpy(f[0..headers[i % headers.len].len], headers[i % headers.len]);
        rng.bytes(f[headers[i % headers.len].len..]);
        _ = probe(f, null) catch null;
        if (decode(gpa, f, null)) |dec_val| {
            var dec = dec_val;
            dec.buffer.deinit();
        } else |_| {}
    }
}

test "random_audio_roundtrips_through_flac" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0003);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const channels = 1 + rng.uintLessThan(usize, 3);
        const frames = rng.uintLessThan(usize, 3000);
        if (frames == 0) continue;
        var buf = try AudioBuffer.init(gpa, 48_000, channels, frames);
        defer buf.deinit();
        for (buf.channels) |ch| {
            for (ch) |*s| s.* = rng.float(f32) * 2.4 - 1.2;
        }
        const bytes = try encode(gpa, &buf, .{ .format = .flac, .bit_depth = .int24, .dither = false, .bwf = null });
        defer gpa.free(bytes);
        const info = try probe(bytes, null);
        try testing.expectEqual(@as(u64, frames), info.frames);
        try testing.expectEqual(channels, @as(usize, info.channels));
    }
    // Decoded FLAC equal to the WAV decode needs a FLAC sample decoder (see the module doc).
    return error.SkipZigTest;
}
