// Translated to Zig from soundcraft/crates/audio-io/src/aiff.rs, soundcraft/crates/audio-io/tests/it/malformed.rs, soundcraft/crates/audio-io/tests/it/roundtrip.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Native AIFF / AIFF-C reader and writer (Apple "Audio Interchange File Format" 1.3 and the
//! AIFF-C draft: big-endian IFF chunks, 80-bit IEEE extended sample rate).
//!
//! Reading is `parse` (headers only, returns an `AiffLayout`) followed by `decode`
//! (samples). Writing is `encode` for a whole buffer, or `Writer` for block-by-block output
//! into any sink that provides the methods listed on `Writer`. Everything is bounds-checked;
//! the input bytes are hostile.
//!
//! Threading: parsing, decoding and writing allocate and do file-style I/O, so they belong on
//! the control or file thread, never the audio thread.
//!
//! Compressed AIFF-C streams (ulaw, alaw, ima4, ...) are reported as `.foreign`: the Rust
//! code handed them to symphonia, which is not translated yet.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const pcm = @import("pcm.zig");
const buffer = @import("buffer.zig");

const AudioError = types.AudioError;
const BitDepth = types.BitDepth;
const AudioBuffer = buffer.AudioBuffer;

/// AIFF-C version 1 timestamp for the FVER chunk.
const AIFC_VERSION_1: u32 = 0xA280_5140;
const MAX_SAMPLE_RATE: f64 = 10_000_000.0;
/// Chunks read before the walk gives up (hostile files can chain millions of tiny chunks).
const max_chunks: usize = 100_000;
/// Bytes the writer batches samples through (at least one frame of the widest sample size). The
/// batch size does not change the bytes written; sizing by frames instead would make a
/// 32767-channel writer allocate half a gigabyte before writing a sample.
const scratch_bytes: usize = 16 * 1024;
/// Largest header we build: an AIFC float header is 84 bytes; 96 leaves room to spare.
const max_header_len: usize = 96;

/// Layout of a native (uncompressed) AIFF stream, as found by `parse`.
pub const AiffLayout = struct {
    info: types.AudioInfo,
    kind: pcm.PcmKind,
    /// Byte offset of the first sample inside the input.
    data_start: usize,
    /// Bytes of sample data available from `data_start` (clipped to the input by `decode`).
    data_len: usize,
};

/// Result of `parse`: a native layout, or a compressed AIFF-C stream this code does not decode.
pub const AiffParse = union(enum) {
    native: AiffLayout,
    /// Compressed AIFF-C (ulaw, alaw, ima4, ...): handed to symphonia in the Rust code.
    foreign,
};

/// True when `b` starts like an AIFF or AIFF-C file (`FORM` then `AIFF` or `AIFC`).
pub fn isAiff(b: []const u8) bool {
    if (!tagIs(b, 0, "FORM")) return false;
    return tagIs(b, 8, "AIFF") or tagIs(b, 8, "AIFC");
}

fn tagIs(b: []const u8, pos: usize, want: []const u8) bool {
    const t = pcm.tag(b, pos) orelse return false;
    return std.mem.eql(u8, &t, want);
}

/// Decodes an 80-bit IEEE 754 extended-precision float (big-endian, 10 bytes). Returns null for
/// an input shorter than 10 bytes or an infinite or NaN exponent.
pub fn extendedToF64(b: []const u8) ?f64 {
    const se = pcm.beU16(b, 0) orelse return null;
    const hi: u64 = pcm.beU32(b, 2) orelse return null;
    const lo: u64 = pcm.beU32(b, 6) orelse return null;
    const mant: u64 = (hi << 32) | lo;
    if (mant == 0) return 0.0;
    const exp: i32 = @as(i32, se & 0x7FFF);
    if (exp == 0x7FFF) return null; // inf / NaN
    // Exact power-of-two scaling, same value as the Rust `2f64.powi(exp - 16383 - 63)` product.
    const v = std.math.ldexp(@as(f64, @floatFromInt(mant)), exp - 16383 - 63);
    return if ((se & 0x8000) != 0) -v else v;
}

/// Encodes a positive integer as an 80-bit IEEE 754 extended float (exact for any `u32`).
/// Zero encodes as all zero bytes.
pub fn u32ToExtended(r: u32) [10]u8 {
    var out: [10]u8 = @splat(0);
    if (r == 0) return out;
    const e: u32 = std.math.log2_int(u32, r);
    const exp: u16 = @intCast(16383 + e);
    const shift: u6 = @intCast(63 - e);
    const mant: u64 = @as(u64, r) << shift;
    std.mem.writeInt(u16, out[0..2], exp, .big);
    std.mem.writeInt(u64, out[2..10], mant, .big);
    return out;
}

/// Walks the IFF chunks of `b` and returns where the samples are, or `.foreign` for a
/// compressed AIFF-C stream. Errors are `error.Malformed` (not AIFF, no or bad COMM chunk,
/// zero channels, sample rate outside 1 Hz .. 10 MHz) and `error.Unsupported` (sample size
/// outside 1..32 bits).
pub fn parse(b: []const u8) AudioError!AiffParse {
    if (!isAiff(b)) return error.Malformed;
    const is_aifc = tagIs(b, 8, "AIFC");
    var comm: ?Comm = null;
    var ssnd: ?Span = null;

    var pos: usize = 12;
    var chunks: usize = 0;
    while (true) {
        const id = pcm.tag(b, pos) orelse break;
        const size32 = pcm.beU32(b, pos + 4) orelse break;
        chunks += 1;
        if (chunks > max_chunks) break;
        const body = std.math.add(usize, pos, 8) catch return error.Malformed;
        const remaining = b.len -| body;
        const declared: usize = std.math.cast(usize, size32) orelse std.math.maxInt(usize);
        const len = @min(declared, remaining);
        // `pos + 8 <= b.len` holds here (the tag and size reads succeeded), so `body` is in range.
        const c = b[body..][0..len];

        if (std.mem.eql(u8, &id, "COMM")) {
            const channels: i16 = @bitCast(pcm.beU16(c, 0) orelse return error.Malformed);
            const frames: u32 = pcm.beU32(c, 2) orelse return error.Malformed;
            const bits: i16 = @bitCast(pcm.beU16(c, 6) orelse return error.Malformed);
            if (c.len < 18) return error.Malformed;
            const rate = extendedToF64(c[8..18]) orelse return error.Malformed;
            const compression: [4]u8 = if (is_aifc)
                (pcm.tag(c, 18) orelse return error.Malformed)
            else
                "NONE".*;
            comm = .{ .channels = channels, .frames = frames, .bits = bits, .rate = rate, .compression = compression };
        } else if (std.mem.eql(u8, &id, "SSND") and ssnd == null) {
            const offset: usize = std.math.cast(usize, pcm.beU32(c, 0) orelse 0) orelse std.math.maxInt(usize);
            const start = @min(body +| 8 +| offset, b.len);
            const data_len = (len -| 8) -| offset;
            ssnd = .{ .start = start, .len = data_len };
        }

        if (declared > remaining) break;
        const after = std.math.add(usize, body, declared) catch break;
        pos = std.math.add(usize, after, declared & 1) catch break;
    }

    const cm = comm orelse return error.Malformed;
    if (cm.channels <= 0) return error.Malformed;
    // Written as `!(lo..=hi).contains(..)` so that NaN is rejected too.
    if (!(cm.rate >= 1.0 and cm.rate <= MAX_SAMPLE_RATE)) return error.Malformed;
    const sample_rate: u32 = @intFromFloat(@round(cm.rate));

    const picked = (try pickKind(cm.compression, cm.bits)) orelse return .foreign;
    const sp: Span = ssnd orelse .{ .start = b.len, .len = 0 };
    const channels: usize = @intCast(cm.channels);
    const block = @max(picked.kind.byteCount() *| channels, 1);
    const avail: u64 = @intCast(sp.len / block);
    const frames = @min(@as(u64, cm.frames), avail);

    return .{ .native = .{
        .info = .{
            .format = .aiff,
            .sample_format = picked.sample_format,
            .sample_rate = sample_rate,
            .channels = @intCast(cm.channels),
            .frames = frames,
            .bwf = null,
        },
        .kind = picked.kind,
        .data_start = sp.start,
        .data_len = sp.len,
    } };
}

/// Decodes the samples described by `layout` from `b` into planar `f32`. The caller frees the
/// result with `deinit`. Samples past the end of `b` are dropped (fewer frames than declared).
pub fn decode(gpa: std.mem.Allocator, b: []const u8, layout: AiffLayout) AudioError!AudioBuffer {
    const end = @min(layout.data_start +| layout.data_len, b.len);
    const data: []const u8 = if (layout.data_start <= end) b[layout.data_start..end] else &.{};
    const channels = try pcm.deinterleave(gpa, data, layout.kind, @as(usize, layout.info.channels), layout.info.frames);
    return .{ .gpa = gpa, .sample_rate = layout.info.sample_rate, .channels = channels };
}

/// Encodes a whole buffer as AIFF (integer depths) or AIFF-C `fl32` (`.float32`). The caller
/// frees the returned bytes with `gpa`.
pub fn encode(gpa: std.mem.Allocator, buf: *const AudioBuffer, depth: BitDepth, dither: bool) AudioError![]u8 {
    try pcm.validateBuffer(buf);
    const frames = buf.frames();
    const channels = buf.channels.len;
    const head_len = (try header(channels, buf.sample_rate, depth, @intCast(frames))).len;
    const bytes_per_sample: usize = pcm.sampleFormat(depth).bits / 8;
    const data_len = (bytes_per_sample *| channels) *| frames;
    const total = head_len +| data_len +| 1;

    var sink: MemSink = .{ .gpa = gpa };
    errdefer sink.deinit();
    sink.list.ensureTotalCapacityPrecise(gpa, total) catch return error.TooLarge;

    var w = try Writer(MemSink).init(gpa, &sink, channels, buf.sample_rate, depth, dither);
    defer w.deinit();
    const views = try gpa.alloc([]const f32, channels);
    defer gpa.free(views);
    for (buf.channels, views) |src, *v| v.* = src;
    try w.write(views, frames);
    try w.finish();
    return try sink.list.toOwnedSlice(gpa);
}

/// An AIFF written block by block: a placeholder header first, then the real one (the same
/// length) written over it by `finish`.
///
/// `W` is a sink, held by pointer, that provides:
///   `writeAll(bytes: []const u8) !void`, `seekTo(pos: u64) !void`, `seekToEnd() !void`,
///   `tell() !u64`, `flush() !void`.
/// Writes are not audio-thread code: `init` allocates the quantizers and the scratch block.
pub fn Writer(comptime W: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        out: *W,
        start: u64,
        channels: usize,
        sample_rate: u32,
        depth: BitDepth,
        quantizers: []pcm.Quantizer,
        scratch: []u8,
        /// Frames written so far (the header is rewritten with this count by `finish`).
        frames: u64 = 0,
        /// Set when a block write has failed: the sink may hold a prefix of that block while
        /// `frames` does not count it, so the writer refuses every later call.
        failed: bool = false,

        pub fn init(gpa: std.mem.Allocator, out: *W, channels: usize, sample_rate: u32, depth: BitDepth, dither: bool) AudioError!Self {
            try pcm.validateLayout(channels, sample_rate);
            const start = out.tell() catch return error.Io;
            const head = try header(channels, sample_rate, depth, 0);
            const quantizers = try pcm.Quantizer.perChannel(gpa, pcm.sampleFormat(depth).bits, dither, channels);
            errdefer gpa.free(quantizers);
            // Seridian: preallocated, Rust grew its `bytes` Vec on demand inside `write`.
            const scratch = try gpa.alloc(u8, @max(channels * 4, scratch_bytes));
            errdefer gpa.free(scratch);
            out.writeAll(head.slice()) catch return error.Io;
            return .{
                .gpa = gpa,
                .out = out,
                .start = start,
                .channels = channels,
                .sample_rate = sample_rate,
                .depth = depth,
                .quantizers = quantizers,
                .scratch = scratch,
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.quantizers);
            self.gpa.free(self.scratch);
        }

        /// The frame count after `frames` more, or an error when AIFF can't hold that many (4 GiB).
        pub fn checkRoom(self: *const Self, frames: u64) AudioError!u64 {
            const total = self.frames +| frames;
            _ = try header(self.channels, self.sample_rate, self.depth, total);
            return total;
        }

        /// Appends `frames` frames of planar audio (missing samples are silence), unless they don't
        /// fit (see `checkRoom`).
        pub fn write(self: *Self, block: []const []const f32, frames: usize) AudioError!void {
            if (self.failed) return error.Encode;
            const total = try self.checkRoom(@intCast(frames));
            pcm.writeInterleaved(self.out, self.scratch, block, frames, self.quantizers, pcm.sampleFormat(self.depth), true) catch {
                self.failed = true;
                return error.Io;
            };
            self.frames = total;
        }

        /// Pads an odd data length, then rewrites the header with the final frame count and returns
        /// the sink at its end. The sink is borrowed: the caller still owns it.
        pub fn finish(self: *Self) AudioError!void {
            if (self.failed) return error.Encode;
            const sf = pcm.sampleFormat(self.depth);
            const data_len: u64 = (@as(u64, sf.bits / 8) *| @as(u64, @intCast(self.channels))) *| self.frames;
            if (data_len % 2 == 1) self.out.writeAll(&.{0}) catch return error.Io;
            const head = try header(self.channels, self.sample_rate, self.depth, self.frames);
            self.out.seekTo(self.start) catch return error.Io;
            self.out.writeAll(head.slice()) catch return error.Io;
            self.out.seekToEnd() catch return error.Io;
            self.out.flush() catch return error.Io;
        }
    };
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

const Comm = struct {
    channels: i16,
    frames: u32,
    bits: i16,
    rate: f64,
    compression: [4]u8,
};

/// Start and length of the sample data inside the input.
const Span = struct {
    start: usize,
    len: usize,
};

const Kinded = struct {
    kind: pcm.PcmKind,
    sample_format: types.SampleFormat,
};

/// Maps the COMM compression code to a sample kind. Null means a compressed stream this code
/// does not decode (`.foreign`).
fn pickKind(compression: [4]u8, bits: i16) AudioError!?Kinded {
    if (std.mem.eql(u8, &compression, "NONE") or std.mem.eql(u8, &compression, "twos")) {
        return try intKind(bits, true);
    }
    if (std.mem.eql(u8, &compression, "sowt")) return try intKind(bits, false);
    if (std.mem.eql(u8, &compression, "fl32") or std.mem.eql(u8, &compression, "FL32")) {
        return .{ .kind = .{ .float = .{ .bytes = 4, .big_endian = true } }, .sample_format = .float32 };
    }
    if (std.mem.eql(u8, &compression, "fl64") or std.mem.eql(u8, &compression, "FL64")) {
        return .{ .kind = .{ .float = .{ .bytes = 8, .big_endian = true } }, .sample_format = .float64 };
    }
    return null;
}

fn intKind(bits: i16, big_endian: bool) AudioError!Kinded {
    if (bits < 1 or bits > 32) return error.Unsupported;
    const n: usize = @intCast(bits);
    const sf: types.SampleFormat = if (n <= 8) .int8 else if (n <= 16) .int16 else if (n <= 24) .int24 else .int32;
    return .{
        .kind = .{ .int = .{ .bytes = (n + 7) / 8, .big_endian = big_endian, .unsigned = false } },
        .sample_format = sf,
    };
}

/// Big-endian bytes of an integer.
fn beBytes(comptime T: type, v: T) [@sizeOf(T)]u8 {
    return @bitCast(std.mem.nativeToBig(T, v));
}

/// A fixed-capacity byte builder: the header and the COMM body are built in place, so checking
/// a frame count never allocates.
const Bytes = struct {
    buf: [max_header_len]u8 = undefined,
    len: usize = 0,

    fn put(self: *Bytes, bytes: []const u8) void {
        std.debug.assert(self.len + bytes.len <= self.buf.len);
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn putBe(self: *Bytes, comptime T: type, v: T) void {
        self.put(&beBytes(T, v));
    }

    /// An IFF chunk: id, big-endian size, body, and a pad byte when the body length is odd.
    fn pushChunk(self: *Bytes, id: []const u8, body: []const u8) void {
        self.put(id);
        self.putBe(u32, @intCast(body.len));
        self.put(body);
        if (body.len % 2 == 1) self.put(&.{0});
    }

    fn slice(self: *const Bytes) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Everything before the sample data of an AIFF holding `frames` frames; its length doesn't
/// depend on `frames`.
fn header(channels: usize, sample_rate: u32, depth: BitDepth, frames: u64) AudioError!Bytes {
    const channels_i16 = std.math.cast(i16, channels) orelse return error.Encode;
    const frames_u32 = std.math.cast(u32, frames) orelse return error.TooLarge;
    const sf = pcm.sampleFormat(depth);
    const data_len: u64 = (@as(u64, sf.bits / 8) *| @as(u64, @intCast(channels))) *| frames;

    var comm: Bytes = .{};
    comm.putBe(i16, channels_i16);
    comm.putBe(u32, frames_u32);
    comm.putBe(u16, sf.bits);
    comm.put(&u32ToExtended(sample_rate));
    if (sf.is_float) {
        const name = "32-bit float";
        comm.put("fl32");
        comm.put(&.{@as(u8, name.len)});
        comm.put(name);
        if ((name.len + 1) % 2 == 1) comm.put(&.{0});
    }

    var head: Bytes = .{};
    head.put("FORM");
    head.put(&.{ 0, 0, 0, 0 }); // patched below
    head.put(if (sf.is_float) "AIFC" else "AIFF");
    if (sf.is_float) head.pushChunk("FVER", &beBytes(u32, AIFC_VERSION_1));
    head.pushChunk("COMM", comm.slice());
    head.put("SSND");
    const ssnd_len = std.math.cast(u32, data_len +| 8) orelse return error.TooLarge;
    head.putBe(u32, ssnd_len);
    const zeros: [8]u8 = @splat(0);
    head.put(&zeros); // offset, blockSize

    const total: u64 = @as(u64, @intCast(head.len)) +| data_len +| (data_len & 1);
    const form_len = std.math.cast(u32, total - 8) orelse return error.TooLarge;
    std.mem.writeInt(u32, head.buf[4..8], form_len, .big);
    return head;
}

/// In-memory sink for `encode` and the tests. Writes at `pos` and grows as needed.
const MemSink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn deinit(self: *MemSink) void {
        self.list.deinit(self.gpa);
    }

    pub fn writeAll(self: *MemSink, bytes: []const u8) !void {
        const end = self.pos + bytes.len;
        if (end > self.list.items.len) try self.list.resize(self.gpa, end);
        @memcpy(self.list.items[self.pos..end], bytes);
        self.pos = end;
    }

    pub fn seekTo(self: *MemSink, pos: u64) !void {
        self.pos = @intCast(pos);
    }

    pub fn seekToEnd(self: *MemSink) !void {
        self.pos = self.list.items.len;
    }

    pub fn tell(self: *MemSink) !u64 {
        return @intCast(self.pos);
    }

    pub fn flush(self: *MemSink) !void {
        _ = self;
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from malformed.rs and roundtrip.rs, AIFF cases; the container-level
// encode/probe/decode of lib.rs is not translated yet, so these call the AIFF functions)
// ---------------------------------------------------------------------------

/// A planar buffer of sine waves at `sr`, one frequency per channel (roundtrip.rs `sine`).
fn sine(gpa: std.mem.Allocator, sr: u32, channels: usize, frames: usize) !AudioBuffer {
    const b = try AudioBuffer.init(gpa, sr, channels, frames);
    for (b.channels, 0..) |ch, c| {
        const f: f32 = 220.0 * (@as(f32, @floatFromInt(c)) + 1.0);
        for (ch, 0..) |*s, i| {
            const phase = 2.0 * std.math.pi * f * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr)) + @as(f32, @floatFromInt(c));
            s.* = 0.8 * @sin(phase);
        }
    }
    return b;
}

/// 300 frames at 44.1 kHz of a sine ramp, the same on every channel (malformed.rs `small`).
fn smallBuffer(gpa: std.mem.Allocator, channels: usize) !AudioBuffer {
    const b = try AudioBuffer.init(gpa, 44_100, channels, 300);
    for (b.channels) |ch| {
        for (ch, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    }
    return b;
}

fn tolerance(depth: BitDepth, dither: bool) f32 {
    const lsb: f32 = switch (depth) {
        .int16 => 1.0 / 32768.0,
        .int24 => 1.0 / 8_388_608.0,
        .int32 => 1e-7,
        .float32 => 0.0,
    };
    const factor: f32 = if (dither) 1.6 else 0.6;
    return lsb * factor + 1e-7;
}

fn maxErr(a: *const AudioBuffer, b: *const AudioBuffer) !f32 {
    try testing.expectEqual(a.numChannels(), b.numChannels());
    try testing.expectEqual(a.frames(), b.frames());
    var m: f32 = 0.0;
    for (a.channels, b.channels) |x, y| {
        for (x, y) |p, q| {
            const d = @abs(p - q);
            if (d > m) m = d;
        }
    }
    return m;
}

const depths = [_]BitDepth{ .int16, .int24, .int32, .float32 };

fn expectedSf(d: BitDepth) types.SampleFormat {
    return switch (d) {
        .int16 => .int16,
        .int24 => .int24,
        .int32 => .int32,
        .float32 => .float32,
    };
}

fn expectNative(p: AiffParse) !AiffLayout {
    return switch (p) {
        .native => |l| l,
        .foreign => error.TestUnexpectedResult,
    };
}

fn appendChunk(gpa: std.mem.Allocator, list: *std.ArrayList(u8), id: []const u8, body: []const u8) !void {
    try list.appendSlice(gpa, id);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try list.appendSlice(gpa, &len);
    try list.appendSlice(gpa, body);
}

test "isAiff accepts FORM with AIFF or AIFC and rejects other magic" {
    try testing.expect(isAiff("FORM\x00\x00\x00\x04AIFF"));
    try testing.expect(isAiff("FORM\x00\x00\x00\x04AIFC"));
    try testing.expect(!isAiff("FORM\x00\x00\x00\x04WAVE"));
    try testing.expect(!isAiff("RIFF\x00\x00\x00\x04AIFF"));
    try testing.expect(!isAiff("FORM"));
}

test "80-bit extended encoding of 44100, 48000, 96000 and 192000 matches the known bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0 }, &u32ToExtended(44_100));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0 }, &u32ToExtended(48_000));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0xBB, 0x80, 0, 0, 0, 0, 0, 0 }, &u32ToExtended(96_000));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x10, 0xBB, 0x80, 0, 0, 0, 0, 0, 0 }, &u32ToExtended(192_000));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &u32ToExtended(0));
}

test "80-bit extended conversion round-trips common and unusual rates exactly" {
    const rates = [_]u32{ 1, 8_000, 11_025, 22_050, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 768_000, 10_000_000 };
    for (rates) |r| {
        const bytes = u32ToExtended(r);
        const back = extendedToF64(&bytes) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(f64, @floatFromInt(r)), back);
    }
}

test "extendedToF64 decodes zero and the sign bit, rejects infinity and NaN" {
    var zero: [10]u8 = @splat(0);
    try testing.expectEqual(@as(?f64, 0.0), extendedToF64(&zero));

    var neg = u32ToExtended(44_100);
    neg[0] |= 0x80;
    try testing.expectEqual(@as(?f64, -44_100.0), extendedToF64(&neg));

    const inf = [_]u8{ 0x7F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(?f64, null), extendedToF64(&inf));
    const nan = [_]u8{ 0x7F, 0xFF, 0xC0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(?f64, null), extendedToF64(&nan));
    try testing.expectEqual(@as(?f64, null), extendedToF64(zero[0..9]));
}

test "parse rejects input that is not AIFF" {
    try testing.expectError(error.Malformed, parse("FORM\x00\x00\x00\x04WAVE"));
    try testing.expectError(error.Malformed, parse("nope"));
}

test "aiff roundtrips all depths and layouts within the Rust tolerance" {
    const gpa = testing.allocator;
    for (depths) |depth| {
        for ([_]usize{ 1, 2, 6 }) |channels| {
            for ([_]bool{ false, true }) |dither| {
                var src = try sine(gpa, 48_000, channels, 4801);
                defer src.deinit();
                const bytes = try encode(gpa, &src, depth, dither);
                defer gpa.free(bytes);
                try testing.expect(isAiff(bytes));
                const layout = try expectNative(try parse(bytes));
                try testing.expectEqual(types.FileFormat.aiff, layout.info.format);
                try testing.expectEqual(@as(u32, 48_000), layout.info.sample_rate);
                try testing.expectEqual(channels, @as(usize, layout.info.channels));
                try testing.expectEqual(@as(u64, 4801), layout.info.frames);
                try testing.expectEqual(expectedSf(depth), layout.info.sample_format);
                var out = try decode(gpa, bytes, layout);
                defer out.deinit();
                try testing.expectEqual(@as(u32, 48_000), out.sample_rate);
                const err = try maxErr(&src, &out);
                try testing.expect(err <= tolerance(depth, dither));
            }
        }
    }
}

test "aiff_sowt_little_endian: a hand-built AIFC/sowt file decodes to the same samples" {
    const gpa = testing.allocator;
    var src = try smallBuffer(gpa, 2);
    defer src.deinit();
    const be = try encode(gpa, &src, .int16, false);
    defer gpa.free(be);
    const be_layout = try expectNative(try parse(be));
    var want = try decode(gpa, be, be_layout);
    defer want.deinit();

    // Rebuild as AIFC/sowt by hand.
    const comm = std.mem.indexOf(u8, be, "COMM") orelse return error.TestUnexpectedResult;
    const ssnd = std.mem.indexOf(u8, be, "SSND") orelse return error.TestUnexpectedResult;
    var comm_body: std.ArrayList(u8) = .empty;
    defer comm_body.deinit(gpa);
    try comm_body.appendSlice(gpa, be[comm + 8 .. comm + 26]);
    try comm_body.appendSlice(gpa, "sowt");
    try comm_body.appendSlice(gpa, &.{ 0, 0 }); // empty pstring, padded

    var ssnd_body: std.ArrayList(u8) = .empty;
    defer ssnd_body.deinit(gpa);
    try ssnd_body.appendSlice(gpa, be[ssnd + 8 ..]);
    // Swap each 16-bit sample after the offset and blockSize words.
    var i: usize = 8;
    while (i + 1 < ssnd_body.items.len) : (i += 2) {
        std.mem.swap(u8, &ssnd_body.items[i], &ssnd_body.items[i + 1]);
    }

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "FORM");
    try file.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // patched below
    try file.appendSlice(gpa, "AIFC");
    try appendChunk(gpa, &file, "COMM", comm_body.items);
    try appendChunk(gpa, &file, "SSND", ssnd_body.items);
    std.mem.writeInt(u32, file.items[4..8], @intCast(file.items.len - 8), .big);

    const layout = try expectNative(try parse(file.items));
    try testing.expectEqual(types.SampleFormat.int16, layout.info.sample_format);
    var got = try decode(gpa, file.items, layout);
    defer got.deinit();
    try testing.expectEqual(want.sample_rate, got.sample_rate);
    try testing.expectEqual(want.numChannels(), got.numChannels());
    for (want.channels, got.channels) |w, g| {
        try testing.expectEqualSlices(f32, w, g);
    }
}

test "aiff float is AIFC with fl32, integer depths are plain AIFF" {
    const gpa = testing.allocator;
    var src = try sine(gpa, 44_100, 2, 10);
    defer src.deinit();

    const f = try encode(gpa, &src, .float32, false);
    defer gpa.free(f);
    try testing.expectEqualStrings("AIFC", f[8..12]);
    try testing.expect(std.mem.indexOf(u8, f, "fl32") != null);

    const i = try encode(gpa, &src, .int24, false);
    defer gpa.free(i);
    try testing.expectEqualStrings("AIFF", i[8..12]);
    const form = std.mem.readInt(u32, i[4..8], .big);
    try testing.expectEqual(@as(usize, form) + 8, i.len);
}

test "unusual sample rates survive the aiff round trip" {
    const gpa = testing.allocator;
    const rates = [_]u32{ 1, 8_000, 11_025, 22_050, 44_100, 88_200, 176_400, 192_000, 352_800, 384_000, 768_000 };
    for (rates) |sr| {
        var src = try sine(gpa, sr, 1, 8);
        defer src.deinit();
        const bytes = try encode(gpa, &src, .int24, false);
        defer gpa.free(bytes);
        const layout = try expectNative(try parse(bytes));
        try testing.expectEqual(sr, layout.info.sample_rate);
    }
}

test "encode rejects empty channel lists and zero sample rates" {
    const gpa = testing.allocator;
    var no_channels: [0][]f32 = .{};
    const empty: AudioBuffer = .{ .gpa = gpa, .sample_rate = 48_000, .channels = &no_channels };
    try testing.expectError(error.Encode, encode(gpa, &empty, .int24, false));

    var zero_rate = try AudioBuffer.init(gpa, 0, 2, 10);
    defer zero_rate.deinit();
    try testing.expectError(error.Encode, encode(gpa, &zero_rate, .int16, false));
}

test "non-finite samples are sanitized and integer output clips finite samples (aiff)" {
    const gpa = testing.allocator;
    var b = try AudioBuffer.init(gpa, 48_000, 1, 4);
    defer b.deinit();
    @memcpy(b.channels[0], &[_]f32{ std.math.nan(f32), std.math.inf(f32), -5.0, 0.5 });

    for (depths) |depth| {
        const bytes = try encode(gpa, &b, depth, false);
        defer gpa.free(bytes);
        const layout = try expectNative(try parse(bytes));
        var out = try decode(gpa, bytes, layout);
        defer out.deinit();
        try testing.expectEqual(@as(f32, 0.0), out.channels[0][0]);
        try testing.expect(out.channels[0][1] > 0.99 and out.channels[0][1] <= 1.0);
        const want: f32 = if (depth == .float32) -5.0 else -1.0;
        try testing.expectEqual(want, out.channels[0][2]);
    }
}

test "ragged channel buffers encode the common length (aiff)" {
    const gpa = testing.allocator;
    var ragged = try AudioBuffer.init(gpa, 48_000, 2, 10);
    defer ragged.deinit();
    @memset(ragged.channels[0], 0.1);
    gpa.free(ragged.channels[1]);
    ragged.channels[1] = try gpa.alloc(f32, 7);
    @memset(ragged.channels[1], 0.2);

    const bytes = try encode(gpa, &ragged, .int16, false);
    defer gpa.free(bytes);
    const layout = try expectNative(try parse(bytes));
    var out = try decode(gpa, bytes, layout);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 7), out.frames());
}

test "zero-frame AIFF writes and reads back with no samples" {
    const gpa = testing.allocator;
    for ([_]BitDepth{ .int16, .int24 }) |depth| {
        for ([_]usize{ 1, 2 }) |channels| {
            var src = try AudioBuffer.init(gpa, 48_000, channels, 0);
            defer src.deinit();
            const bytes = try encode(gpa, &src, depth, false);
            defer gpa.free(bytes);
            const layout = try expectNative(try parse(bytes));
            try testing.expectEqual(expectedSf(depth), layout.info.sample_format);
            try testing.expectEqual(@as(u32, 48_000), layout.info.sample_rate);
            try testing.expectEqual(@as(u64, 0), layout.info.frames);
            try testing.expectEqual(channels, @as(usize, layout.info.channels));
            var out = try decode(gpa, bytes, layout);
            defer out.deinit();
            try testing.expectEqual(@as(usize, 0), out.frames());
            try testing.expectEqual(channels, out.numChannels());
        }
    }
}

test "every truncation of an AIFF file parses or fails cleanly without overrunning" {
    const gpa = testing.allocator;
    const configs = [_]struct { depth: BitDepth, channels: usize }{
        .{ .depth = .int24, .channels = 1 },
        .{ .depth = .float32, .channels = 2 },
    };
    for (configs) |cfg| {
        var src = try smallBuffer(gpa, cfg.channels);
        defer src.deinit();
        const file = try encode(gpa, &src, cfg.depth, false);
        defer gpa.free(file);
        for (0..file.len) |n| {
            const cut = file[0..n];
            const p = parse(cut) catch continue;
            switch (p) {
                .native => |l| {
                    var out = try decode(gpa, cut, l);
                    defer out.deinit();
                    try testing.expectEqual(@as(usize, l.info.channels), out.numChannels());
                    try testing.expectEqual(l.info.frames, @as(u64, @intCast(out.frames())));
                },
                .foreign => {},
            }
        }
    }
}

test "absurd COMM frame count and SSND offset are clamped, not trusted" {
    const gpa = testing.allocator;
    var src = try smallBuffer(gpa, 1);
    defer src.deinit();
    const file = try encode(gpa, &src, .int16, false);
    defer gpa.free(file);

    const comm = std.mem.indexOf(u8, file, "COMM") orelse return error.TestUnexpectedResult;
    std.mem.writeInt(u32, file[comm + 10 ..][0..4], std.math.maxInt(u32), .big);
    const l1 = try expectNative(try parse(file));
    try testing.expectEqual(@as(u64, 300), l1.info.frames);
    var out1 = try decode(gpa, file, l1);
    defer out1.deinit();
    try testing.expectEqual(@as(usize, 300), out1.frames());

    const ssnd = std.mem.indexOf(u8, file, "SSND") orelse return error.TestUnexpectedResult;
    std.mem.writeInt(u32, file[ssnd + 8 ..][0..4], std.math.maxInt(u32), .big);
    const l2 = try expectNative(try parse(file));
    try testing.expectEqual(@as(u64, 0), l2.info.frames);
    var out2 = try decode(gpa, file, l2);
    defer out2.deinit();
    try testing.expectEqual(@as(usize, 0), out2.frames());
}

test "zero channels, zero sample rate and an infinite exponent are malformed" {
    const gpa = testing.allocator;
    var src = try smallBuffer(gpa, 1);
    defer src.deinit();

    const zero_ch = try encode(gpa, &src, .int16, false);
    defer gpa.free(zero_ch);
    const comm = std.mem.indexOf(u8, zero_ch, "COMM") orelse return error.TestUnexpectedResult;
    zero_ch[comm + 8] = 0;
    zero_ch[comm + 9] = 0;
    try testing.expectError(error.Malformed, parse(zero_ch));

    const zero_rate = try encode(gpa, &src, .int16, false);
    defer gpa.free(zero_rate);
    const comm2 = std.mem.indexOf(u8, zero_rate, "COMM") orelse return error.TestUnexpectedResult;
    @memset(zero_rate[comm2 + 16 .. comm2 + 26], 0);
    try testing.expectError(error.Malformed, parse(zero_rate));

    const inf_rate = try encode(gpa, &src, .int16, false);
    defer gpa.free(inf_rate);
    const comm3 = std.mem.indexOf(u8, inf_rate, "COMM") orelse return error.TestUnexpectedResult;
    inf_rate[comm3 + 16] = 0x7F;
    inf_rate[comm3 + 17] = 0xFF;
    try testing.expectError(error.Malformed, parse(inf_rate));
}

test "unsupported sample sizes are refused" {
    const gpa = testing.allocator;
    var src = try smallBuffer(gpa, 1);
    defer src.deinit();
    const file = try encode(gpa, &src, .int16, false);
    defer gpa.free(file);
    const comm = std.mem.indexOf(u8, file, "COMM") orelse return error.TestUnexpectedResult;
    std.mem.writeInt(u16, file[comm + 14 ..][0..2], 0, .big);
    try testing.expectError(error.Unsupported, parse(file));
}

test "dithered AIFF output is deterministic and differs from undithered output" {
    const gpa = testing.allocator;
    var src = try sine(gpa, 48_000, 2, 500);
    defer src.deinit();
    const a = try encode(gpa, &src, .int16, true);
    defer gpa.free(a);
    const b = try encode(gpa, &src, .int16, true);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
    const plain = try encode(gpa, &src, .int16, false);
    defer gpa.free(plain);
    try testing.expect(!std.mem.eql(u8, a, plain));
}

test "block-by-block Writer output equals the one-shot encode" {
    const gpa = testing.allocator;
    var src = try sine(gpa, 48_000, 2, 1000);
    defer src.deinit();

    var sink: MemSink = .{ .gpa = gpa };
    defer sink.deinit();
    var w = try Writer(MemSink).init(gpa, &sink, 2, 48_000, .int24, false);
    defer w.deinit();
    const first: [2][]const f32 = .{ src.channels[0][0..400], src.channels[1][0..400] };
    const second: [2][]const f32 = .{ src.channels[0][400..], src.channels[1][400..] };
    try w.write(&first, 400);
    try w.write(&second, 600);
    try w.finish();

    const one_shot = try encode(gpa, &src, .int24, false);
    defer gpa.free(one_shot);
    try testing.expectEqualSlices(u8, one_shot, sink.list.items);
}

test "writer scratch stays small for the widest channel count and still writes whole frames" {
    const gpa = testing.allocator;
    var sink: MemSink = .{ .gpa = gpa };
    defer sink.deinit();
    const channels: usize = std.math.maxInt(i16);
    var w = try Writer(MemSink).init(gpa, &sink, channels, 48_000, .float32, false);
    defer w.deinit();
    try testing.expect(w.scratch.len <= 1 << 20);
    try testing.expect(w.scratch.len >= channels * 4);
    const plane = try gpa.alloc(f32, 3);
    defer gpa.free(plane);
    @memcpy(plane, &[_]f32{ 0.25, 0.5, -0.5 });
    const planes = try gpa.alloc([]const f32, channels);
    defer gpa.free(planes);
    for (planes) |*p| p.* = plane;
    try w.write(planes, 3);
    try w.finish();
    // Header (84 bytes for AIFC float) then 3 frames of 32767 big-endian floats.
    try testing.expectEqual(@as(usize, 84 + 3 * channels * 4), sink.list.items.len);
    const first = std.mem.readInt(u32, sink.list.items[84..][0..4], .big);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.25))), first);
    const last_frame_first = std.mem.readInt(u32, sink.list.items[84 + 2 * channels * 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, -0.5))), last_frame_first);
}

test "header is 54 bytes for integer AIFF and 84 for AIFC float" {
    try testing.expectEqual(@as(usize, 54), (try header(2, 48_000, .int24, 0)).len);
    try testing.expectEqual(@as(usize, 84), (try header(2, 48_000, .float32, 0)).len);
}

test "header refuses frame and channel counts AIFF cannot hold" {
    try testing.expectError(error.TooLarge, header(1, 48_000, .int16, @as(u64, std.math.maxInt(u32)) + 1));
    try testing.expectError(error.TooLarge, header(2, 48_000, .int32, std.math.maxInt(u32)));
    try testing.expectError(error.Encode, header(40_000, 48_000, .int16, 0));
}
