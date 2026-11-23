// Translated to Zig from soundcraft/crates/audio-io/src/pcm.rs, soundcraft/crates/audio-io/tests/it/float_headroom.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Byte-level PCM helpers shared by the WAV, AIFF and FLAC code: bounded readers, sample
//! decoding to `f32`, and quantization (with optional TPDF dither) for encoding.
//!
//! Every byte read goes through a bounds-checked helper: all inputs are hostile.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const buffer = @import("buffer.zig");

const AudioError = types.AudioError;
const BitDepth = types.BitDepth;
const AudioBuffer = buffer.AudioBuffer;

/// Maximum number of decoded `f32` samples (all channels) we will produce: 4 GiB of output.
pub const MAX_DECODE_SAMPLES: u64 = (4 << 30) / 4;

/// The `n` bytes at `pos`, or null when they do not all lie inside `b`.
fn window(b: []const u8, pos: usize, comptime n: usize) ?*const [n]u8 {
    if (pos > b.len or b.len - pos < n) return null;
    return b[pos..][0..n];
}

/// Little-endian `u16` at `pos`.
pub fn leU16(b: []const u8, pos: usize) ?u16 {
    const w = window(b, pos, 2) orelse return null;
    return std.mem.readInt(u16, w, .little);
}

/// Little-endian `u32` at `pos`.
pub fn leU32(b: []const u8, pos: usize) ?u32 {
    const w = window(b, pos, 4) orelse return null;
    return std.mem.readInt(u32, w, .little);
}

/// Little-endian `u64` at `pos`.
pub fn leU64(b: []const u8, pos: usize) ?u64 {
    const w = window(b, pos, 8) orelse return null;
    return std.mem.readInt(u64, w, .little);
}

/// Big-endian `u16` at `pos`.
pub fn beU16(b: []const u8, pos: usize) ?u16 {
    const w = window(b, pos, 2) orelse return null;
    return std.mem.readInt(u16, w, .big);
}

/// Big-endian `u32` at `pos`.
pub fn beU32(b: []const u8, pos: usize) ?u32 {
    const w = window(b, pos, 4) orelse return null;
    return std.mem.readInt(u32, w, .big);
}

/// Big-endian `u64` at `pos`.
pub fn beU64(b: []const u8, pos: usize) ?u64 {
    const w = window(b, pos, 8) orelse return null;
    return std.mem.readInt(u64, w, .big);
}

/// Four-byte tag at `pos`.
pub fn tag(b: []const u8, pos: usize) ?[4]u8 {
    const w = window(b, pos, 4) orelse return null;
    return w.*;
}

/// How the samples in a PCM byte stream are encoded.
pub const PcmKind = union(enum) {
    /// Signed (or, for 1-byte WAV, unsigned) integers occupying `bytes` bytes each, left-justified.
    int: struct { bytes: usize, big_endian: bool, unsigned: bool },
    /// IEEE float, 4 or 8 bytes.
    float: struct { bytes: usize, big_endian: bool },

    pub fn byteCount(self: PcmKind) usize {
        return switch (self) {
            inline else => |k| k.bytes,
        };
    }
};

/// Decode one sample from exactly `kind.byteCount()` bytes. Returns 0 for a short slice, for a
/// malformed kind, and for a non-finite float.
pub fn decodeSample(s: []const u8, kind: PcmKind) f32 {
    switch (kind) {
        .int => |k| {
            if (k.bytes == 0 or k.bytes > 4 or s.len < k.bytes) return 0.0;
            var acc: u32 = 0;
            var i: usize = 0;
            while (i < k.bytes) : (i += 1) {
                const idx = if (k.big_endian) i else k.bytes - 1 - i;
                var byte: u8 = s[idx];
                if (k.unsigned and i == 0) byte ^= 0x80;
                acc = (acc << 8) | @as(u32, byte);
            }
            const sh: u5 = @intCast(32 - 8 * k.bytes);
            const shifted: u32 = acc << sh;
            const signed: i32 = @bitCast(shifted);
            const wide: f64 = @as(f64, @floatFromInt(signed)) / 2147483648.0;
            return @as(f32, @floatCast(wide));
        },
        .float => |k| {
            const endian: std.builtin.Endian = if (k.big_endian) .big else .little;
            const v: f32 = switch (k.bytes) {
                4 => blk: {
                    const w = window(s, 0, 4) orelse return 0.0;
                    break :blk @as(f32, @bitCast(std.mem.readInt(u32, w, endian)));
                },
                8 => blk: {
                    const w = window(s, 0, 8) orelse return 0.0;
                    const wide: f64 = @bitCast(std.mem.readInt(u64, w, endian));
                    break :blk @as(f32, @floatCast(wide));
                },
                else => 0.0,
            };
            return if (std.math.isFinite(v)) v else 0.0;
        },
    }
}

/// Deinterleave `frames` frames of `channels`-channel PCM from `data` into planar `f32`.
/// Returns one owned slice per channel (free with `freeChannels`).
pub fn deinterleave(gpa: std.mem.Allocator, data: []const u8, kind: PcmKind, channels: usize, frames: u64) AudioError![][]f32 {
    const bytes = kind.byteCount();
    const block = std.math.mul(usize, bytes, channels) catch return error.Malformed;
    if (block == 0) return error.Malformed;
    const available: u64 = @intCast(data.len / block);
    const n_frames = @min(frames, available);
    const total = std.math.mul(u64, n_frames, channels) catch return error.TooLarge;
    if (total > MAX_DECODE_SAMPLES) return error.TooLarge;
    const n: usize = std.math.cast(usize, n_frames) orelse return error.TooLarge;

    const out = try gpa.alloc([]f32, channels);
    errdefer gpa.free(out);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |c| gpa.free(c);
    }
    while (made < channels) : (made += 1) {
        out[made] = try gpa.alloc(f32, n);
    }

    for (0..n) |f| {
        const frame = data[f * block ..][0..block];
        for (0..channels) |c| {
            out[c][f] = decodeSample(frame[c * bytes ..][0..bytes], kind);
        }
    }
    return out;
}

/// Frees what `deinterleave` returned.
pub fn freeChannels(gpa: std.mem.Allocator, channels: [][]f32) void {
    for (channels) |c| gpa.free(c);
    gpa.free(channels);
}

/// Converts `f32` samples to integers of a given bit depth, clamping to [-1, 1] and optionally
/// adding triangular (TPDF) dither of +-1 LSB. The dither generator is a fixed-seed xorshift64*,
/// so the same channel always produces the same dither sequence.
pub const Quantizer = struct {
    bits: u32,
    dither: bool,
    rng: u64,

    /// A quantizer for one channel; each channel gets an independent dither sequence.
    pub fn init(bits: u32, dither: bool, channel: usize) Quantizer {
        const mixed: u64 = (@as(u64, channel) +% 1) *% 0xD1B5_4A32_D192_ED03;
        const seed: u64 = 0x9E37_79B9_7F4A_7C15 ^ mixed;
        return .{
            .bits = std.math.clamp(bits, 2, 32),
            .dither = dither,
            .rng = if (seed == 0) 1 else seed,
        };
    }

    /// One quantizer per channel, allocated with `gpa` (free the slice with `gpa.free`).
    pub fn perChannel(gpa: std.mem.Allocator, bits: u32, dither: bool, channels: usize) ![]Quantizer {
        const out = try gpa.alloc(Quantizer, channels);
        for (out, 0..) |*q, c| q.* = Quantizer.init(bits, dither, c);
        return out;
    }

    /// Uniform in [0, 1) from a xorshift64* generator (deterministic, no OS entropy needed).
    fn uniform(self: *Quantizer) f64 {
        var x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        const r = (x *% 0x2545_F491_4F6C_DD1D) >> 11;
        return @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    /// Quantizes one sample to a signed integer in `[-2^(bits-1), 2^(bits-1) - 1]`.
    pub fn quantize(self: *Quantizer, x: f32) i32 {
        const xc: f32 = if (std.math.isNan(x)) 0.0 else std.math.clamp(x, -1.0, 1.0);
        const scale: f64 = @floatFromInt(@as(u64, 1) << @as(u6, @intCast(self.bits - 1)));
        var v: f64 = @as(f64, xc) * scale;
        if (self.dither) {
            // Two draws in source order, as in the Rust `uniform() - uniform()`.
            const a = self.uniform();
            const b = self.uniform();
            v += a - b;
        }
        const max = scale - 1.0;
        return @intFromFloat(roundHalfAway(std.math.clamp(v, -scale, max)));
    }
};

/// Round to the nearest integer, halves away from zero, returned as f64. Mirrors the Rust
/// integer-cast algorithm (saturating cast, NaN maps to 0).
pub fn roundHalfAway(v: f64) f64 {
    if (std.math.isNan(v)) return 0.0;
    const t: i64 = if (v >= 9.223372036854775807e18)
        std.math.maxInt(i64)
    else if (v <= -9.223372036854775808e18)
        std.math.minInt(i64)
    else
        @intFromFloat(v);
    const f: f64 = v - @as(f64, @floatFromInt(t));
    const up: i64 = @intFromBool(f >= 0.5);
    const down: i64 = @intFromBool(f <= -0.5);
    return @floatFromInt(t + up - down);
}

/// Bits per sample and whether they are float.
pub const SampleBits = struct {
    bits: u16,
    is_float: bool,
};

/// Bits per sample at `depth`, and whether they are float.
pub fn sampleFormat(depth: BitDepth) SampleBits {
    return switch (depth) {
        .int16 => .{ .bits = 16, .is_float = false },
        .int24 => .{ .bits = 24, .is_float = false },
        .int32 => .{ .bits = 32, .is_float = false },
        .float32 => .{ .bits = 32, .is_float = true },
    };
}

/// Interleaves `frames` frames of planar audio (missing samples are silence) as `fmt` samples
/// and writes them to `out` (any value with `writeAll(bytes) !void`). Output is batched through
/// `scratch`, which must hold at least one frame; the batch size does not change the bytes.
pub fn writeInterleaved(
    out: anytype,
    scratch: []u8,
    block: []const []const f32,
    frames: usize,
    quantizers: []Quantizer,
    fmt: SampleBits,
    big_endian: bool,
) !void {
    if (quantizers.len == 0) return;
    const size: usize = fmt.bits / 8;
    const frame_bytes = size * quantizers.len;
    if (scratch.len < frame_bytes) return error.Encode;
    const chunk = @min(@as(usize, 4096), scratch.len / frame_bytes);
    const endian: std.builtin.Endian = if (big_endian) .big else .little;

    var start: usize = 0;
    while (start < frames) {
        const end = @min(frames, start + chunk);
        var pos: usize = 0;
        for (start..end) |f| {
            for (quantizers, 0..) |*q, c| {
                const s: f32 = if (c < block.len and f < block[c].len) block[c][f] else 0.0;
                var buf: [4]u8 = undefined;
                if (fmt.is_float) {
                    std.mem.writeInt(u32, &buf, @bitCast(sanitizeFloat(s)), endian);
                    @memcpy(scratch[pos..][0..4], &buf);
                    pos += 4;
                } else {
                    const v: u32 = @bitCast(q.quantize(s));
                    std.mem.writeInt(u32, &buf, v, endian);
                    // Little-endian keeps the low `size` bytes in order; big-endian keeps the
                    // last `size` bytes of the 4-byte big-endian form.
                    const part = if (big_endian) buf[4 - size ..] else buf[0..size];
                    @memcpy(scratch[pos..][0..size], part);
                    pos += size;
                }
            }
        }
        try out.writeAll(scratch[0..pos]);
        start = end;
    }
}

/// Preserve finite float samples, mapping NaN to 0 and infinities to their sign (+-1).
pub fn sanitizeFloat(x: f32) f32 {
    if (std.math.isFinite(x)) return x;
    if (std.math.isNan(x)) return 0.0;
    return if (x > 0) 1.0 else -1.0;
}

/// Check that a buffer is encodable: at least one channel and a non-zero sample rate.
pub fn validateBuffer(buf: *const AudioBuffer) AudioError!void {
    return validateLayout(buf.channels.len, buf.sample_rate);
}

/// Check that a stream is encodable: at least one channel and a non-zero sample rate.
pub fn validateLayout(channels: usize, sample_rate: u32) AudioError!void {
    if (channels == 0) return error.Encode;
    if (channels > std.math.maxInt(u16)) return error.Encode;
    if (sample_rate == 0) return error.Encode;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A writer for tests: collects every byte written.
const Sink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn writeAll(self: *Sink, bytes: []const u8) !void {
        try self.list.appendSlice(self.gpa, bytes);
    }

    fn deinit(self: *Sink) void {
        self.list.deinit(self.gpa);
    }
};

fn checkRound(v: f64) !void {
    try testing.expectEqual(@round(v), roundHalfAway(v));
    try testing.expectEqual(@as(i32, @intFromFloat(@round(v))), @as(i32, @intFromFloat(roundHalfAway(v))));
}

test "round_half_away matches f64 round on the quantizer range" {
    const edges = [_]f64{
        0.0,
        -0.0,
        0.5,
        -0.5,
        1.5,
        -1.5,
        2.5,
        0.499_999_999_999_999_94,
        -0.499_999_999_999_999_94,
        8_388_607.5,
        -8_388_608.0,
        2_147_483_647.0,
        -2_147_483_648.0,
    };
    for (edges) |v| try checkRound(v);

    var x: u64 = 0x2545_f491_4f6c_dd1d;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        const unit = @as(f64, @floatFromInt(x >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        try checkRound(unit * 4_294_967_295.0 - 2_147_483_648.0);
    }
}

// The four float_headroom.rs tests (whole_file_float32_preserves_finite_headroom,
// streaming_float32_preserves_finite_headroom, float32_keeps_non_finite_sample_handling,
// integer_pcm_still_clips_at_full_scale) live in codec.zig, where encode/decode/FileEncoder are.
// The tests below check the same sample encoding at PCM level.

test "float32 write keeps finite headroom bits (pcm level)" {
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
    const frames: usize = 4103;
    const gpa = testing.allocator;

    for ([_]bool{ false, true }) |dither| {
        for ([_]usize{ 1, 2 }) |channels| {
            var planes: [2][]f32 = undefined;
            for (0..channels) |c| {
                planes[c] = try gpa.alloc(f32, frames);
                for (planes[c], 0..) |*s, i| s.* = samples[(i + c) % samples.len];
            }
            defer for (0..channels) |c| gpa.free(planes[c]);
            const block: []const []const f32 = planes[0..channels];

            const qs = try Quantizer.perChannel(gpa, 24, dither, channels);
            defer gpa.free(qs);

            var sink: Sink = .{ .gpa = gpa };
            defer sink.deinit();
            var scratch: [4096 * 2 * 4]u8 = undefined;
            try writeInterleaved(&sink, &scratch, block, frames, qs, .{ .bits = 32, .is_float = true }, false);

            // Expected: every sample's own little-endian bits, frame-major.
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(gpa);
            for (0..frames) |f| {
                for (0..channels) |c| {
                    const bits: u32 = @bitCast(planes[c][f]);
                    try expected.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, bits)));
                }
            }
            try testing.expectEqualSlices(u8, expected.items, sink.list.items);
        }
    }
}

test "float32 non-finite samples are stored as 0, -1, 1" {
    const gpa = testing.allocator;
    var plane = [_]f32{ std.math.nan(f32), -std.math.inf(f32), std.math.inf(f32) };
    const block = [_][]const f32{&plane};
    var qs = [_]Quantizer{Quantizer.init(24, false, 0)};

    for ([_]bool{ false, true }) |big_endian| {
        var sink: Sink = .{ .gpa = gpa };
        defer sink.deinit();
        var scratch: [64]u8 = undefined;
        try writeInterleaved(&sink, &scratch, &block, plane.len, &qs, .{ .bits = 32, .is_float = true }, big_endian);
        const want = [_]f32{ 0.0, -1.0, 1.0 };
        var expected: [12]u8 = undefined;
        for (want, 0..) |v, i| {
            const bits: u32 = @bitCast(v);
            std.mem.writeInt(u32, expected[i * 4 ..][0..4], bits, if (big_endian) .big else .little);
        }
        try testing.expectEqualSlices(u8, &expected, sink.list.items);
    }
}

test "integer quantize clips at full scale" {
    const inputs = [_]f32{ -2.0, -1.25, -1.0, -0.5, 0.0, 0.5, 1.0, 1.25, 2.0 };
    for ([_]u32{ 16, 24, 32 }) |bits| {
        var q = Quantizer.init(bits, false, 0);
        const half: i64 = @as(i64, 1) << @as(u6, @intCast(bits - 1));
        const quarter: i64 = @as(i64, 1) << @as(u6, @intCast(bits - 2));
        const expected = [_]i64{ -half, -half, -half, -quarter, 0, quarter, half - 1, half - 1, half - 1 };
        for (inputs, expected) |x, want| {
            try testing.expectEqual(@as(i32, @intCast(want)), q.quantize(x));
        }
    }
}

test "quantize with NaN input is silence" {
    var q = Quantizer.init(16, false, 0);
    try testing.expectEqual(@as(i32, 0), q.quantize(std.math.nan(f32)));
}

test "dither sequence is deterministic per channel and differs between channels" {
    var a = Quantizer.init(16, true, 0);
    var b = Quantizer.init(16, true, 0);
    var c = Quantizer.init(16, true, 1);
    var same = true;
    var differs = false;
    for (0..64) |_| {
        const va = a.quantize(0.25);
        const vb = b.quantize(0.25);
        const vc = c.quantize(0.25);
        if (va != vb) same = false;
        if (va != vc) differs = true;
    }
    try testing.expect(same);
    try testing.expect(differs);
}

test "bounded readers return null out of bounds and read both byte orders" {
    const b = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
    try testing.expectEqual(@as(?u16, 0x0201), leU16(&b, 0));
    try testing.expectEqual(@as(?u16, 0x0102), beU16(&b, 0));
    try testing.expectEqual(@as(?u32, 0x0403_0201), leU32(&b, 0));
    try testing.expectEqual(@as(?u32, 0x0102_0304), beU32(&b, 0));
    try testing.expectEqual(@as(?u64, 0x0807_0605_0403_0201), leU64(&b, 0));
    try testing.expectEqual(@as(?u64, 0x0102_0304_0506_0708), beU64(&b, 0));
    try testing.expectEqual(@as(?u64, null), leU64(&b, 2));
    try testing.expectEqual(@as(?u16, null), beU16(&b, 8));
    try testing.expectEqual(@as(?u32, null), leU32(&b, std.math.maxInt(usize)));
    try testing.expectEqual(@as(?[4]u8, .{ 0x05, 0x06, 0x07, 0x08 }), tag(&b, 4));
    try testing.expectEqual(@as(?[4]u8, null), tag(&b, 6));
}

test "decode_sample handles int16 LE, unsigned 8-bit, float and short input" {
    const le16 = [_]u8{ 0x00, 0x40 };
    try testing.expectEqual(@as(f32, 0.5), decodeSample(&le16, .{ .int = .{ .bytes = 2, .big_endian = false, .unsigned = false } }));

    const u8_mid = [_]u8{0x80};
    try testing.expectEqual(@as(f32, 0.0), decodeSample(&u8_mid, .{ .int = .{ .bytes = 1, .big_endian = false, .unsigned = true } }));

    const f_one = @as([4]u8, @bitCast(std.mem.nativeToLittle(u32, @as(u32, @bitCast(@as(f32, 1.5))))));
    try testing.expectEqual(@as(f32, 1.5), decodeSample(&f_one, .{ .float = .{ .bytes = 4, .big_endian = false } }));

    const nan_bytes = @as([4]u8, @bitCast(std.mem.nativeToLittle(u32, @as(u32, @bitCast(std.math.nan(f32))))));
    try testing.expectEqual(@as(f32, 0.0), decodeSample(&nan_bytes, .{ .float = .{ .bytes = 4, .big_endian = false } }));

    try testing.expectEqual(@as(f32, 0.0), decodeSample(&le16, .{ .int = .{ .bytes = 4, .big_endian = false, .unsigned = false } }));
}

test "deinterleave splits two-channel int16 and rejects a zero-sized frame" {
    const gpa = testing.allocator;
    // Frame 0: L = 0x4000 (0.5), R = 0xC000 (-0.5). Frame 1: L = 0 (0.0), R = 0x8000 (-1.0).
    const data = [_]u8{ 0x00, 0x40, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x80 };
    const kind: PcmKind = .{ .int = .{ .bytes = 2, .big_endian = false, .unsigned = false } };

    const chans = try deinterleave(gpa, &data, kind, 2, 5); // asks for 5, only 2 are present
    defer freeChannels(gpa, chans);
    try testing.expectEqual(@as(usize, 2), chans.len);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.0 }, chans[0]);
    try testing.expectEqualSlices(f32, &.{ -0.5, -1.0 }, chans[1]);

    try testing.expectError(error.Malformed, deinterleave(gpa, &data, kind, 0, 1));
}

test "validate_layout rejects zero channels, zero rate and too many channels" {
    try validateLayout(2, 48_000);
    try testing.expectError(error.Encode, validateLayout(0, 48_000));
    try testing.expectError(error.Encode, validateLayout(1, 0));
    try testing.expectError(error.Encode, validateLayout(@as(usize, std.math.maxInt(u16)) + 1, 48_000));
}

test "sample_format maps depths to bits and float flag" {
    try testing.expectEqual(SampleBits{ .bits = 16, .is_float = false }, sampleFormat(.int16));
    try testing.expectEqual(SampleBits{ .bits = 24, .is_float = false }, sampleFormat(.int24));
    try testing.expectEqual(SampleBits{ .bits = 32, .is_float = false }, sampleFormat(.int32));
    try testing.expectEqual(SampleBits{ .bits = 32, .is_float = true }, sampleFormat(.float32));
}
