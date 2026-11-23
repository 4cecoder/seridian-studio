// Translated to Zig from soundcraft/crates/audio-io/src/flac.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! A small FLAC encoder (RFC 9639): fixed blocksize, independent channels, and per subframe the
//! cheapest of CONSTANT, VERBATIM or FIXED (orders 0-4) prediction with partitioned Rice-coded
//! residuals. Decoding is symphonia's, after `checkMetadata`; the test-only decoder at the end of
//! this file exists only so the round-trip tests can check what the encoder writes.
//!
//! Control-thread code: encoding allocates and writes to a sink. Nothing here runs on the audio
//! thread.

const std = @import("std");
const testing = std.testing;
const pcm = @import("pcm.zig");
const types = @import("types.zig");
const buffer = @import("buffer.zig");

const AudioError = types.AudioError;
const AudioInfo = types.AudioInfo;
const AudioBuffer = buffer.AudioBuffer;
const BitDepth = types.BitDepth;
const FileFormat = types.FileFormat;
const SampleFormat = types.SampleFormat;

const block_size: usize = 4096;
const max_partition_order: u32 = 6;
const max_partitions: usize = 1 << max_partition_order;

/// Reads a big- or little-endian u32 at a position, or null when it does not fit in `b`.
const ReadU32 = *const fn (b: []const u8, pos: usize) ?u32;

fn mapWriteErr(err: anyerror) AudioError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

// ---------------------------------------------------------------------------
// Bit packing and checksums
// ---------------------------------------------------------------------------

/// MSB-first bit packer over a growable byte list. Bytes are allocated with `gpa`.
const BitWriter = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    nbits: u32 = 0,

    fn init(gpa: std.mem.Allocator) BitWriter {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *BitWriter) void {
        self.out.deinit(self.gpa);
    }

    /// Write the low `n_in` (<= 32) bits of `v`, MSB first.
    fn write(self: *BitWriter, v: u64, n_in: u32) AudioError!void {
        if (n_in == 0) return;
        const n = @min(n_in, 32);
        const mask: u64 = (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
        self.acc = (self.acc << @as(u6, @intCast(n))) | (v & mask);
        self.nbits += n;
        while (self.nbits >= 8) {
            self.nbits -= 8;
            try self.out.append(self.gpa, @truncate(self.acc >> @as(u6, @intCast(self.nbits))));
        }
        self.acc &= (@as(u64, 1) << @as(u6, @intCast(self.nbits))) - 1;
    }

    fn writeSigned(self: *BitWriter, v: i64, n: u32) AudioError!void {
        try self.write(@as(u64, @bitCast(v)), n);
    }

    /// `q` zero bits followed by a one bit.
    fn writeUnary(self: *BitWriter, q_in: u64) AudioError!void {
        var q = q_in;
        while (q >= 32) {
            try self.write(0, 32);
            q -= 32;
        }
        try self.write(1, @as(u32, @intCast(q)) + 1);
    }

    fn alignByte(self: *BitWriter) AudioError!void {
        if (self.nbits > 0) try self.write(0, 8 - self.nbits);
    }

    /// Pads to a byte boundary and returns the bytes. The caller frees them with `gpa`; the
    /// writer is empty afterwards.
    fn intoBytes(self: *BitWriter) AudioError![]u8 {
        try self.alignByte();
        return self.out.toOwnedSlice(self.gpa);
    }
};

fn crc8(data: []const u8) u8 {
    var crc: u8 = 0;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| {
            crc = if ((crc & 0x80) != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
    }
    return crc;
}

fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        crc ^= @as(u16, b) << 8;
        for (0..8) |_| {
            crc = if ((crc & 0x8000) != 0) (crc << 1) ^ 0x8005 else crc << 1;
        }
    }
    return crc;
}

/// FLAC's UTF-8-like variable-length integer coding (up to 36 bits).
fn writeUtf8Number(w: *BitWriter, v: u64) AudioError!void {
    if (v < 0x80) return w.write(v, 8);
    // Payload bits available for an n-byte coding: 5n + 1 (n = 2..=6), 36 for n = 7.
    var n: u32 = 2;
    while (n < 7 and v >= (@as(u64, 1) << @as(u6, @intCast(5 * n + 1)))) : (n += 1) {}
    const cont_bits: u32 = 6 * (n - 1);
    const lead_payload: u32 = if (n == 7) 0 else 7 - n;
    const prefix: u64 = (@as(u64, 0xFF) << @as(u6, @intCast(8 - n))) & 0xFF;
    const payload_mask = (@as(u64, 1) << @as(u6, @intCast(lead_payload))) - 1;
    const lead = prefix | ((v >> @as(u6, @intCast(cont_bits))) & payload_mask);
    try w.write(lead, 8);
    var i: u32 = n - 1;
    while (i > 0) {
        i -= 1;
        try w.write(0x80 | ((v >> @as(u6, @intCast(6 * i))) & 0x3F), 8);
    }
}

// ---------------------------------------------------------------------------
// Frame and stream header fields
// ---------------------------------------------------------------------------

const SrExtra = struct { value: u64, bits: u32 };
const SrCode = struct { code: u64, extra: ?SrExtra = null };

fn sampleRateCode(r: u32) SrCode {
    return switch (r) {
        88_200 => SrCode{ .code = 1 },
        176_400 => SrCode{ .code = 2 },
        192_000 => SrCode{ .code = 3 },
        8_000 => SrCode{ .code = 4 },
        16_000 => SrCode{ .code = 5 },
        22_050 => SrCode{ .code = 6 },
        24_000 => SrCode{ .code = 7 },
        32_000 => SrCode{ .code = 8 },
        44_100 => SrCode{ .code = 9 },
        48_000 => SrCode{ .code = 10 },
        96_000 => SrCode{ .code = 11 },
        else => blk: {
            if (r % 1000 == 0 and r / 1000 <= 255) {
                break :blk SrCode{ .code = 12, .extra = .{ .value = r / 1000, .bits = 8 } };
            }
            if (r <= 65_535) break :blk SrCode{ .code = 13, .extra = .{ .value = r, .bits = 16 } };
            if (r % 10 == 0 and r / 10 <= 65_535) {
                break :blk SrCode{ .code = 14, .extra = .{ .value = r / 10, .bits = 16 } };
            }
            break :blk SrCode{ .code = 0 };
        },
    };
}

fn bpsCode(bps: u32) u64 {
    return switch (bps) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        else => 0, // from STREAMINFO
    };
}

fn zigzag(r: i64) u64 {
    return @as(u64, @bitCast((r << 1) ^ (r >> 63)));
}

// ---------------------------------------------------------------------------
// Subframes
// ---------------------------------------------------------------------------

/// Fixed-predictor residuals of `order`, zigzag-coded, or null when any residual leaves the
/// i32 range (the caller then drops that order). The caller frees the slice.
fn fixedResidualZigzag(gpa: std.mem.Allocator, x: []const i64, order: usize) AudioError!?[]u64 {
    const len = x.len -| order;
    const res = try gpa.alloc(u64, len);
    for (0..len) |j| {
        const n = order + j;
        const g = struct {
            fn at(s: []const i64, i: usize, k: usize) i64 {
                return s[i - k];
            }
        }.at;
        const r: i64 = switch (order) {
            0 => g(x, n, 0),
            1 => g(x, n, 0) - g(x, n, 1),
            2 => g(x, n, 0) - 2 * g(x, n, 1) + g(x, n, 2),
            3 => g(x, n, 0) - 3 * g(x, n, 1) + 3 * g(x, n, 2) - g(x, n, 3),
            else => g(x, n, 0) - 4 * g(x, n, 1) + 6 * g(x, n, 2) - 4 * g(x, n, 3) + g(x, n, 4),
        };
        if (r < std.math.minInt(i32) or r > std.math.maxInt(i32)) {
            gpa.free(res);
            return null;
        }
        res[j] = zigzag(r);
    }
    return res;
}

/// Best Rice parameter and its cost in bits for one partition.
const Rice = struct { k: u32, cost: u64 };

fn bestRice(part: []const u64) Rice {
    if (part.len == 0) return .{ .k = 0, .cost = 0 };
    var sum: u64 = 0;
    for (part) |u| sum += u;
    const mean = sum / part.len;
    const guess: u32 = if (mean == 0) 0 else 63 - @clz(mean);
    var best: Rice = .{ .k = 0, .cost = std.math.maxInt(u64) };
    // Rust: `guess.saturating_sub(1)..=(guess + 1).min(30)`, which is empty when start > end.
    const start = guess -| 1;
    const end = @min(guess + 1, 30);
    var k = start;
    while (k <= end) : (k += 1) {
        var cost: u64 = @as(u64, part.len) * @as(u64, k + 1);
        for (part) |u| cost += u >> @as(u6, @intCast(k));
        if (cost < best.cost) best = .{ .k = k, .cost = cost };
    }
    return best;
}

/// Residual coding plan: partition order, per-partition parameters, total bits. The parameters
/// live inline (at most 64 partitions), so a plan needs no allocation.
const RicePlan = struct {
    order: u32 = 0,
    params: [max_partitions]u32 = @splat(0),
    bits: u64 = std.math.maxInt(u64),
    wide: bool = false,
};

/// `s[start..start+len]`, or an empty slice when that range does not exist (Rust's
/// `get(..).unwrap_or_default()`).
fn subslice(s: []const u64, start: usize, len: usize) []const u64 {
    if (start > s.len or len > s.len - start) return &.{};
    return s[start .. start + len];
}

fn planResidual(u: []const u64, block_len: usize, pred_order: usize) RicePlan {
    var best: ?RicePlan = null;
    var p: u32 = 0;
    while (p <= max_partition_order) : (p += 1) {
        const parts: usize = @as(usize, 1) << @as(u6, @intCast(p));
        if (block_len % parts != 0 or block_len / parts <= pred_order) break;
        const per = block_len / parts;
        var plan: RicePlan = .{ .order = p };
        var bits: u64 = 0;
        var start: usize = 0;
        for (0..parts) |i| {
            const len = if (i == 0) per - pred_order else per;
            const r = bestRice(subslice(u, start, len));
            start += len;
            plan.params[i] = r.k;
            bits += r.cost;
        }
        var wide = false;
        for (plan.params[0..parts]) |k| {
            if (k > 14) wide = true;
        }
        plan.wide = wide;
        bits += 6 + @as(u64, parts) * (if (wide) @as(u64, 5) else @as(u64, 4));
        plan.bits = bits;
        if (best == null or bits < best.?.bits) best = plan;
    }
    return best orelse RicePlan{};
}

fn writeResidual(w: *BitWriter, u: []const u64, block_len: usize, pred_order: usize, plan: RicePlan) AudioError!void {
    try w.write(@intFromBool(plan.wide), 2);
    try w.write(plan.order, 4);
    const parts: usize = @as(usize, 1) << @as(u6, @intCast(plan.order));
    const per = block_len / parts;
    var start: usize = 0;
    for (0..parts) |i| {
        const len = if (i == 0) per - pred_order else per;
        const k = plan.params[i];
        try w.write(k, if (plan.wide) 5 else 4);
        for (subslice(u, start, len)) |v| {
            try w.writeUnary(v >> @as(u6, @intCast(k)));
            try w.write(v, k);
        }
        start += len;
    }
}

fn writeSubframe(gpa: std.mem.Allocator, w: *BitWriter, x: []const i64, bps: u32) AudioError!void {
    const n = x.len;
    const first: i64 = if (n > 0) x[0] else 0;
    var constant = true;
    for (x) |s| {
        if (s != first) {
            constant = false;
            break;
        }
    }
    if (constant) {
        try w.write(0, 1);
        try w.write(0, 6);
        try w.write(0, 1);
        try w.writeSigned(first, bps);
        return;
    }
    const verbatim_bits: u64 = @as(u64, n) * @as(u64, bps);
    const Candidate = struct { order: usize, u: []u64, plan: RicePlan, total: u64 };
    var best: ?Candidate = null;
    defer if (best) |b| gpa.free(b.u);
    const max_order = @min(@as(usize, 4), n -| 1);
    var order: usize = 0;
    while (order <= max_order) : (order += 1) {
        const u = (try fixedResidualZigzag(gpa, x, order)) orelse continue;
        const plan = planResidual(u, n, order);
        const bits = plan.bits +| @as(u64, order) * @as(u64, bps);
        const better = bits < verbatim_bits and (best == null or bits < best.?.total);
        if (!better) {
            gpa.free(u);
            continue;
        }
        if (best) |b| gpa.free(b.u);
        best = .{ .order = order, .u = u, .plan = plan, .total = bits };
    }
    if (best) |b| {
        try w.write(0, 1);
        try w.write(8 + @as(u64, b.order), 6);
        try w.write(0, 1);
        for (x[0..b.order]) |s| try w.writeSigned(s, bps);
        try writeResidual(w, b.u, n, b.order, b.plan);
    } else {
        try w.write(0, 1);
        try w.write(1, 6);
        try w.write(0, 1);
        for (x) |s| try w.writeSigned(s, bps);
    }
}

// ---------------------------------------------------------------------------
// Stream setup
// ---------------------------------------------------------------------------

/// Checks that FLAC can hold the layout; returns the bits per sample.
fn check(channels: usize, sample_rate: u32, depth: BitDepth) AudioError!u32 {
    try pcm.validateLayout(channels, sample_rate);
    if (channels > 8) return error.Unsupported;
    if (sample_rate > 655_350) return error.Unsupported;
    return switch (depth) {
        .int16 => 16,
        .int24 => 24,
        .int32 => 32,
        .float32 => error.Unsupported,
    };
}

/// The STREAMINFO block (metadata header included): 38 bytes. The MD5 signature is written as
/// zeros (unknown), as the Rust encoder does.
fn streamInfo(gpa: std.mem.Allocator, channels: usize, sample_rate: u32, bps: u32, total: u64) AudioError![]u8 {
    var si = BitWriter.init(gpa);
    defer si.deinit();
    try si.write(1, 1); // last metadata block
    try si.write(0, 7); // STREAMINFO
    try si.write(34, 24);
    try si.write(block_size, 16);
    try si.write(block_size, 16);
    try si.write(0, 24);
    try si.write(0, 24);
    try si.write(sample_rate, 20);
    try si.write(channels - 1, 3);
    try si.write(bps - 1, 5);
    try si.write(total >> 32, 4);
    try si.write(total & 0xFFFF_FFFF, 32);
    for (0..4) |_| try si.write(0, 32); // MD5 unknown
    return si.intoBytes();
}

/// A FLAC stream written block by block into `out`, which must be seekable: the header is
/// written first with a zero sample count, and `finish` seeks back to patch the STREAMINFO.
///
/// `W` supplies `writeAll(bytes) !void`, `seekTo(pos: u64) !void`, `seekToEnd() !void`,
/// `tell() u64` and `flush() !void`; any error from them becomes `error.Io`.
pub fn Writer(comptime W: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        out: *W,
        start: u64,
        channels: usize,
        sample_rate: u32,
        bps: u32,
        quantizers: []pcm.Quantizer,
        pending: []std.ArrayList(i64),
        frames: u64 = 0,
        frame_no: u64 = 0,
        /// Set when a frame write has failed: `writeFrame` clears the pending samples before
        /// writing, so a failed frame is lost while `frames` still counts it; the writer refuses
        /// every later call.
        failed: bool = false,

        pub fn init(gpa: std.mem.Allocator, out: *W, channels: usize, sample_rate: u32, depth: BitDepth, dither: bool) AudioError!Self {
            const bps = try check(channels, sample_rate, depth);
            const start = out.tell();
            try ioWrite(out, "fLaC");
            const info = try streamInfo(gpa, channels, sample_rate, bps, 0);
            defer gpa.free(info);
            try ioWrite(out, info);

            const quantizers = try pcm.Quantizer.perChannel(gpa, bps, dither, channels);
            errdefer gpa.free(quantizers);
            const pending = try gpa.alloc(std.ArrayList(i64), channels);
            errdefer gpa.free(pending);
            @memset(pending, .empty);
            errdefer for (pending) |*p| p.deinit(gpa);
            for (pending) |*p| try p.ensureTotalCapacity(gpa, block_size);

            return .{
                .gpa = gpa,
                .out = out,
                .start = start,
                .channels = channels,
                .sample_rate = sample_rate,
                .bps = bps,
                .quantizers = quantizers,
                .pending = pending,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.pending) |*p| p.deinit(self.gpa);
            self.gpa.free(self.pending);
            self.gpa.free(self.quantizers);
        }

        /// The frame count after `frames` more, or an error past what FLAC can count (2^36 frames).
        pub fn checkRoom(self: *const Self, frames: u64) AudioError!u64 {
            const total = self.frames +| frames;
            if (total >= (@as(u64, 1) << 36)) return error.TooLarge;
            return total;
        }

        /// Appends `frames` frames of planar audio (missing samples are silence).
        pub fn write(self: *Self, block: []const []const f32, frames: usize) AudioError!void {
            if (self.failed) return error.Encode;
            const total = try self.checkRoom(frames);
            var done: usize = 0;
            while (done < frames) {
                const held = self.pending[0].items.len;
                const n = @min(block_size - held, frames - done);
                for (self.pending, self.quantizers, 0..) |*p, *q, c| {
                    const src: []const f32 = if (c < block.len and done <= block[c].len) block[c][done..] else &.{};
                    for (0..n) |i| {
                        const s: f32 = if (i < src.len) src[i] else 0.0;
                        try p.append(self.gpa, q.quantize(s));
                    }
                }
                done += n;
                if (held + n == block_size) {
                    self.writeFrame() catch |e| {
                        self.failed = true;
                        return e;
                    };
                }
            }
            self.frames = total;
        }

        fn writeFrame(self: *Self) AudioError!void {
            const len = self.pending[0].items.len;
            if (len == 0) return;
            const sr = sampleRateCode(self.sample_rate);

            var hw = BitWriter.init(self.gpa);
            defer hw.deinit();
            try hw.write(0x3FFE, 14);
            try hw.write(0, 1);
            try hw.write(0, 1); // fixed blocksize stream
            try hw.write(7, 4); // 16-bit (blocksize-1) follows
            try hw.write(sr.code, 4);
            try hw.write(self.channels - 1, 4);
            try hw.write(bpsCode(self.bps), 3);
            try hw.write(0, 1);
            try writeUtf8Number(&hw, self.frame_no);
            try hw.write(len - 1, 16);
            if (sr.extra) |e| try hw.write(e.value, e.bits);
            const header = try hw.intoBytes();
            defer self.gpa.free(header);

            var fw = BitWriter.init(self.gpa);
            defer fw.deinit();
            for (header) |b| try fw.write(b, 8);
            try fw.write(crc8(header), 8);
            for (self.pending) |*p| {
                try writeSubframe(self.gpa, &fw, p.items, self.bps);
                p.clearRetainingCapacity();
            }
            const body = try fw.intoBytes();
            defer self.gpa.free(body);

            const frame = try self.gpa.alloc(u8, body.len + 2);
            defer self.gpa.free(frame);
            @memcpy(frame[0..body.len], body);
            std.mem.writeInt(u16, frame[body.len..][0..2], crc16(body), .big);
            try ioWrite(self.out, frame);
            self.frame_no += 1;
        }

        /// Writes the last partial frame and patches the STREAMINFO sample count and frame sizes.
        pub fn finish(self: *Self) AudioError!void {
            if (self.failed) return error.Encode;
            try self.writeFrame();
            const info = try streamInfo(self.gpa, self.channels, self.sample_rate, self.bps, self.frames);
            defer self.gpa.free(info);
            try ioSeek(self.out, self.start + 4);
            try ioWrite(self.out, info);
            try ioSeekEnd(self.out);
            try ioFlush(self.out);
        }

        fn ioWrite(out: *W, bytes: []const u8) AudioError!void {
            out.writeAll(bytes) catch |e| return mapWriteErr(e);
        }

        fn ioSeek(out: *W, pos: u64) AudioError!void {
            out.seekTo(pos) catch |e| return mapWriteErr(e);
        }

        fn ioSeekEnd(out: *W) AudioError!void {
            out.seekToEnd() catch |e| return mapWriteErr(e);
        }

        fn ioFlush(out: *W) AudioError!void {
            out.flush() catch |e| return mapWriteErr(e);
        }
    };
}

/// In-memory `Writer` target that can seek, standing in for Rust's `Cursor<Vec<u8>>`.
pub const MemSink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    pub fn writeAll(self: *MemSink, bytes: []const u8) AudioError!void {
        const end = std.math.add(usize, self.pos, bytes.len) catch return error.TooLarge;
        if (end > self.buf.items.len) try self.buf.appendNTimes(self.gpa, 0, end - self.buf.items.len);
        @memcpy(self.buf.items[self.pos..end], bytes);
        self.pos = end;
    }

    pub fn seekTo(self: *MemSink, pos: u64) AudioError!void {
        self.pos = std.math.cast(usize, pos) orelse return error.TooLarge;
    }

    pub fn seekToEnd(self: *MemSink) AudioError!void {
        self.pos = self.buf.items.len;
    }

    pub fn tell(self: *const MemSink) u64 {
        return self.pos;
    }

    pub fn flush(self: *MemSink) AudioError!void {
        _ = self;
    }

    pub fn deinit(self: *MemSink) void {
        self.buf.deinit(self.gpa);
    }
};

/// Encodes a whole buffer as FLAC. The caller frees the returned bytes with `gpa`.
pub fn encode(gpa: std.mem.Allocator, buf: *const AudioBuffer, depth: BitDepth, dither: bool) AudioError![]u8 {
    try pcm.validateBuffer(buf);
    const bps = try check(buf.channels.len, buf.sample_rate, depth);
    const frames = buf.frames();

    var sink: MemSink = .{ .gpa = gpa };
    errdefer sink.deinit();
    // Rust reserves frames * channels * bytes / 2 up front and maps a failure to TooLarge.
    const want = (frames *| buf.channels.len *| (bps / 8)) / 2;
    sink.buf.ensureTotalCapacity(gpa, want) catch return error.TooLarge;

    var w = try Writer(MemSink).init(gpa, &sink, buf.channels.len, buf.sample_rate, depth, dither);
    defer w.deinit();
    const block = try gpa.alloc([]const f32, buf.channels.len);
    defer gpa.free(block);
    for (buf.channels, block) |ch, *b| b.* = ch;
    try w.write(block, frames);
    try w.finish();
    return sink.buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Metadata validators (hostile input: every length is untrusted)
// ---------------------------------------------------------------------------

/// Reads one length-prefixed field at `at.*`: its u32 length must fit in `end` for the field to
/// be checked. Returns true when the length runs past `end`, false when it fits, and null when
/// the field cannot be read (the Rust code returns "no overrun" in that case).
fn lengthField(b: []const u8, at: *usize, end: usize, read: ReadU32) ?bool {
    const n: usize = read(b, at.*) orelse return null;
    if (at.* +| 4 > end) return null;
    at.* += 4;
    if (n > end - at.*) return true;
    at.* += n;
    return false;
}

/// Whether one of the length-prefixed fields from `start` claims more than `end` leaves; `gaps`
/// are the bytes skipped before each length.
fn overruns(b: []const u8, start: usize, end: usize, read: ReadU32, gaps: []const usize) bool {
    var at = start;
    for (gaps) |gap| {
        at +|= gap;
        const over = lengthField(b, &at, end, read) orelse return false;
        if (over) return true;
    }
    return false;
}

/// Whether a comment in a (little-endian) Vorbis comment block claims more than the block holds.
/// The vendor string is skipped unread.
fn commentsOverrun(b: []const u8, body: usize, end: usize) bool {
    const vendor = pcm.leU32(b, body) orelse return false;
    const at = (body +| 4) +| @as(usize, vendor);
    const count = pcm.leU32(b, at) orelse return false;
    if (at +| 4 > end) return false;
    var pos = at + 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const over = lengthField(b, &pos, end, pcm.leU32) orelse return false;
        if (over) return true;
    }
    return false;
}

/// Refuse the FLAC stream at `at` if a comment or picture field claims more bytes than its
/// metadata block holds: symphonia allocates each field's length before reading it.
pub fn checkMetadata(b: []const u8, at: usize) AudioError!void {
    var pos = std.math.add(usize, at, 4) catch return error.Malformed;
    while (pcm.beU32(b, pos)) |head| {
        const body = pos + 4;
        const len: usize = head & 0x00ff_ffff;
        const end = @min(body +| len, b.len);
        const bad = switch ((head >> 24) & 0x7f) {
            4 => commentsOverrun(b, body, end),
            // Picture: type, MIME type, description, four size fields, data.
            6 => overruns(b, body + 4, end, pcm.beU32, &.{ 0, 0, 16 }),
            else => false,
        };
        if (bad) return error.Malformed;
        if ((head >> 31) == 1) break;
        pos = body +| len;
    }
}

/// The info of a FLAC stream with no audio frames at all: STREAMINFO declares 0 samples and
/// nothing follows the metadata blocks. Symphonia's reader fails on these, as it looks for a
/// first frame, so the caller answers them itself. `at` is the offset of the `fLaC` marker.
pub fn emptyStreamInfo(b: []const u8, at: usize) ?AudioInfo {
    var pos = std.math.add(usize, at, 4) catch return null;
    var first = true;
    while (true) {
        const head = pcm.beU32(b, pos) orelse return null;
        const body = std.math.add(usize, pos, 4) catch return null;
        const len: usize = head & 0x00ff_ffff;
        const end = std.math.add(usize, body, len) catch return null;
        if (end > b.len) return null;
        if (first and (((head >> 24) & 0x7f) != 0 or len != 34)) return null;
        first = false;
        if ((head >> 31) == 1) {
            if (end != b.len) return null;
            break;
        }
        pos = end;
    }
    // STREAMINFO, from the sample rate on: 20 bits rate, 3 channels - 1, 5 bits per sample - 1,
    // 36 bits total.
    const si = std.math.add(usize, at, 4 + 4 + 10) catch return null;
    const si_end = std.math.add(usize, si, 8) catch return null;
    if (si_end > b.len) return null;
    const packed_bits = std.mem.readInt(u64, b[si..][0..8], .big);
    const sample_rate: u32 = @intCast(packed_bits >> 44);
    const channels: u16 = @intCast(((packed_bits >> 41) & 0x7) + 1);
    const bps: u32 = @intCast(((packed_bits >> 36) & 0x1f) + 1);
    if ((packed_bits & 0xf_ffff_ffff) != 0 or sample_rate == 0) return null;
    const sample_format: SampleFormat = switch (bps) {
        1...8 => .int8,
        9...16 => .int16,
        17...24 => .int24,
        else => .int32,
    };
    return .{
        .format = FileFormat.flac,
        .sample_format = sample_format,
        .sample_rate = sample_rate,
        .channels = channels,
        .frames = 0,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The UTF-8-style coding of `v`, as bytes the caller frees.
fn utf8Bytes(gpa: std.mem.Allocator, v: u64) AudioError![]u8 {
    var w = BitWriter.init(gpa);
    defer w.deinit();
    try writeUtf8Number(&w, v);
    return w.intoBytes();
}

test "crc_known_values" {
    // CRC-8/SMBUS and CRC-16/UMTS (FLAC's polynomials) of "123456789".
    try testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
    try testing.expectEqual(@as(u16, 0xFEE8), crc16("123456789"));
}

test "utf8_numbers" {
    const a = try utf8Bytes(testing.allocator, 0x7F);
    defer testing.allocator.free(a);
    try testing.expectEqualSlices(u8, &.{0x7F}, a);

    const b = try utf8Bytes(testing.allocator, 0x80);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, &.{ 0xC2, 0x80 }, b);

    const c = try utf8Bytes(testing.allocator, 0x800);
    defer testing.allocator.free(c);
    try testing.expectEqualSlices(u8, &.{ 0xE0, 0xA0, 0x80 }, c);

    // The largest 36-bit value takes seven bytes: 0xFE lead, six continuation bytes.
    const d = try utf8Bytes(testing.allocator, (@as(u64, 1) << 36) - 1);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 7), d.len);
    try testing.expectEqual(@as(u8, 0xFE), d[0]);
}

test "bit writer packs MSB first and masks each field" {
    var w = BitWriter.init(testing.allocator);
    defer w.deinit();
    try w.write(0b101, 3);
    try w.write(0xFF, 4); // only the low 4 bits of 0xFF are written
    const bytes = try w.intoBytes();
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{0xBE}, bytes);
}

/// `frames` frames of a sine per channel at `sr`, the same signal the Rust tests build.
fn sineBuffer(gpa: std.mem.Allocator, sr: u32, channels: usize, frames: usize) !AudioBuffer {
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

/// Asserts that a decoded FLAC stream holds exactly what the PCM quantizer produces for `src`
/// (the sample values a WAV of the same depth would store). The Rust tests compare two decodes;
/// here the reference is the quantizer, which is the step both paths share.
fn expectMatchesQuantized(src: *const AudioBuffer, dec: *const TestDecoded, bits: u32, dither: bool) !void {
    try testing.expectEqual(src.channels.len, dec.channels.len);
    try testing.expectEqual(src.frames(), dec.frames());
    for (src.channels, 0..) |ch, c| {
        var q = pcm.Quantizer.init(bits, dither, c);
        for (ch, 0..) |s, i| {
            try testing.expectEqual(@as(i64, q.quantize(s)), dec.channels[c].items[i]);
        }
    }
}

test "flac_roundtrip_is_lossless_vs_wav" {
    const gpa = testing.allocator;
    for ([_]BitDepth{ .int16, .int24, .int32 }) |depth| {
        for ([_]usize{ 1, 2, 6 }) |channels| {
            // Spans several blocks plus a short final block.
            var src = try sineBuffer(gpa, 44_100, channels, 4096 * 2 + 17);
            defer src.deinit();
            const flac = try encode(gpa, &src, depth, false);
            defer gpa.free(flac);

            var dec = try decodeForTest(gpa, flac);
            defer dec.deinit();
            try testing.expectEqual(@as(u32, 44_100), dec.sample_rate);
            try expectMatchesQuantized(&src, &dec, bitsOf(depth), false);

            // The Rust test also checks the FLAC is smaller than the WAV; the WAV header is at least
            // 0 bytes beyond the PCM payload, so this bound is the stronger form.
            if (depth != .int32) {
                const payload = src.frames() * channels * (bitsOf(depth) / 8);
                try testing.expect(flac.len < payload);
            }
        }
    }
}

test "flac_handles_silence_noise_full_scale_and_odd_rates" {
    const gpa = testing.allocator;
    const frames: usize = 10_000;
    var b = try AudioBuffer.init(gpa, 37_123, 3, frames);
    defer b.deinit();
    var seed: u32 = 1;
    for (0..frames) |i| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        // White noise, then a clipped full-scale square.
        b.channels[1][i] = @as(f32, @floatFromInt(seed)) / @as(f32, @floatFromInt(std.math.maxInt(u32))) * 2.0 - 1.0;
        b.channels[2][i] = if (i % 2 == 0) 1.5 else -1.5;
    }
    for ([_]BitDepth{ .int16, .int24, .int32 }) |depth| {
        for ([_]bool{ false, true }) |dither| {
            const flac = try encode(gpa, &b, depth, dither);
            defer gpa.free(flac);
            var dec = try decodeForTest(gpa, flac);
            defer dec.deinit();
            try testing.expectEqual(@as(u32, 37_123), dec.sample_rate);
            try expectMatchesQuantized(&b, &dec, bitsOf(depth), dither);
        }
    }
}

test "flac_rejects_unsupported_layouts" {
    const gpa = testing.allocator;
    var stereo = try sineBuffer(gpa, 48_000, 2, 10);
    defer stereo.deinit();
    try testing.expectError(error.Unsupported, encode(gpa, &stereo, .float32, false));

    var nine = try sineBuffer(gpa, 48_000, 9, 10);
    defer nine.deinit();
    try testing.expectError(error.Unsupported, encode(gpa, &nine, .int16, false));

    var fast = try sineBuffer(gpa, 700_000, 1, 10);
    defer fast.deinit();
    try testing.expectError(error.Unsupported, encode(gpa, &fast, .int16, false));

    // Tiny buffers still encode and decode.
    var one = try sineBuffer(gpa, 48_000, 2, 1);
    defer one.deinit();
    const bytes = try encode(gpa, &one, .int16, false);
    defer gpa.free(bytes);
    var dec = try decodeForTest(gpa, bytes);
    defer dec.deinit();
    try testing.expectEqual(@as(usize, 1), dec.frames());
}

test "zero_frame_flac_round_trips_like_wav_and_aiff" {
    const gpa = testing.allocator;
    for ([_]BitDepth{ .int16, .int24 }) |depth| {
        for ([_]usize{ 1, 2 }) |channels| {
            var empty = try AudioBuffer.init(gpa, 48_000, channels, 0);
            defer empty.deinit();
            const bytes = try encode(gpa, &empty, depth, false);
            defer gpa.free(bytes);
            const info = emptyStreamInfo(bytes, 0) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(FileFormat.flac, info.format);
            try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
            try testing.expectEqual(channels, @as(usize, info.channels));
            try testing.expectEqual(@as(u64, 0), info.frames);
            const want: SampleFormat = if (depth == .int16) .int16 else .int24;
            try testing.expectEqual(want, info.sample_format);

            var dec = try decodeForTest(gpa, bytes);
            defer dec.deinit();
            try testing.expectEqual(@as(usize, 0), dec.frames());
            try testing.expectEqual(channels, dec.channels.len);
        }
    }
}

test "flac_claiming_frames_but_holding_none_still_errors" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 2, 0);
    defer empty.deinit();
    const bytes = try encode(gpa, &empty, .int16, false);
    defer gpa.free(bytes);
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[25] = 1; // STREAMINFO total samples (low byte of the 36-bit field) = 1
    // The Rust test asserts that the whole decode fails; here the empty-stream answer is refused
    // and the test decoder reports the frame-count mismatch.
    try testing.expectEqual(@as(?AudioInfo, null), emptyStreamInfo(bad, 0));
    try testing.expectError(error.Malformed, decodeForTest(gpa, bad));
}

/// An ID3v2.4 tag around `body`, as the Rust helper builds it (syncsafe size field).
fn id3Tag(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const size: u32 = @intCast(body.len);
    const out = try gpa.alloc(u8, 10 + body.len);
    @memcpy(out[0..6], &[_]u8{ 'I', 'D', '3', 4, 0, 0 });
    out[6] = @intCast((size >> 21) & 0x7F);
    out[7] = @intCast((size >> 14) & 0x7F);
    out[8] = @intCast((size >> 7) & 0x7F);
    out[9] = @intCast(size & 0x7F);
    @memcpy(out[10..], body);
    return out;
}

test "zero_frame_flac_after_a_prefix_is_still_empty" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac = try encode(gpa, &empty, .int16, false);
    defer gpa.free(flac);

    const tag = try id3Tag(gpa, "tag");
    defer gpa.free(tag);
    const junk: [16]u8 = @splat(0x7A);

    // Arbitrary bytes, then an ID3 tag with junk, then two ID3 tags: each case gives the offset
    // of the `fLaC` marker, which is where the empty-stream answer starts.
    const prefix_a: [64]u8 = @splat(0x7A);

    const case_a = try concat(gpa, &.{ &prefix_a, flac });
    defer gpa.free(case_a);
    try expectEmptyAt(gpa, case_a, prefix_a.len);

    const case_b = try concat(gpa, &.{ tag, &junk, flac });
    defer gpa.free(case_b);
    try expectEmptyAt(gpa, case_b, tag.len + junk.len);

    const case_c = try concat(gpa, &.{ tag, tag, flac });
    defer gpa.free(case_c);
    try expectEmptyAt(gpa, case_c, tag.len * 2);
}

test "zero_frame_flac_after_a_false_mpeg_sync_is_still_empty" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac = try encode(gpa, &empty, .int16, false);
    defer gpa.free(flac);

    const junks = [_][]const u8{
        &.{ 0xFF, 0xE0, 0x00 },
        &.{ 0xFF, 0xF0, 0x00 },
        &.{ 0xFF, 0xFB, 0xF0, 0x00 },
    };
    for (junks) |junk| {
        const f = try concat(gpa, &.{ junk, flac });
        defer gpa.free(f);
        try expectEmptyAt(gpa, f, junk.len);
    }
}

/// Asserts that `emptyStreamInfo` answers an empty 48 kHz mono FLAC at `at`, and that the test
/// decoder reads it as zero frames.
fn expectEmptyAt(gpa: std.mem.Allocator, f: []const u8, at: usize) !void {
    const info = emptyStreamInfo(f, at) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(FileFormat.flac, info.format);
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u16, 1), info.channels);
    try testing.expectEqual(@as(u64, 0), info.frames);
    var dec = try decodeForTest(gpa, f[at..]);
    defer dec.deinit();
    try testing.expectEqual(@as(usize, 0), dec.frames());
}

fn concat(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const out = try gpa.alloc(u8, total);
    var at: usize = 0;
    for (parts) |p| {
        @memcpy(out[at..][0..p.len], p);
        at += p.len;
    }
    return out;
}

/// The FLAC stream of `frames` mono 16-bit frames with `tag` as its only metadata block.
fn flacWithBlock(gpa: std.mem.Allocator, kind: u8, body: []const u8) ![]u8 {
    var src = try AudioBuffer.init(gpa, 44_100, 1, 300);
    defer src.deinit();
    for (src.channels[0], 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    const f = try encode(gpa, &src, .int16, false);
    defer gpa.free(f);
    // Clear the "last block" bit of STREAMINFO, then insert the new block as the last one.
    const head: u32 = ((@as(u32, 0x80) | kind) << 24) | @as(u32, @intCast(body.len));
    var head_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &head_bytes, head, .big);
    var first = try gpa.dupe(u8, f[0..5]);
    defer gpa.free(first);
    first[4] &= 0x7f;
    return concat(gpa, &.{ first, f[5..42], &head_bytes, body, f[42..] });
}

test "flac_metadata_fields_beyond_their_block_are_refused" {
    const gpa = testing.allocator;

    // A picture whose data field (3 bytes) fits its block.
    const picture_ok = try concat(gpa, &.{
        &.{ 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0 },
        &(@as([16]u8, @splat(0))),
        &.{ 0, 0, 0, 3 },
        &.{ 1, 2, 3 },
    });
    defer gpa.free(picture_ok);
    const ok = try flacWithBlock(gpa, 6, picture_ok);
    defer gpa.free(ok);
    try checkMetadata(ok, 0);

    // A picture claiming a 0x7fff_fff0-byte data field, and a comment claiming u32::MAX entries.
    const picture_bad = try concat(gpa, &.{
        &.{ 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0 },
        &(@as([16]u8, @splat(0))),
        &.{ 0x7f, 0xff, 0xff, 0xf0 },
        &.{ 1, 2, 3 },
    });
    defer gpa.free(picture_bad);
    const bad_picture = try flacWithBlock(gpa, 6, picture_bad);
    defer gpa.free(bad_picture);
    try testing.expectError(error.Malformed, checkMetadata(bad_picture, 0));

    const comment = try concat(gpa, &.{
        &.{ 0, 0, 0, 0 }, // vendor length 0
        &.{ 1, 0, 0, 0 }, // one comment
        &.{ 0xff, 0xff, 0xff, 0xff }, // its length: u32::MAX
    });
    defer gpa.free(comment);
    const bad_comment = try flacWithBlock(gpa, 4, comment);
    defer gpa.free(bad_comment);
    try testing.expectError(error.Malformed, checkMetadata(bad_comment, 0));
}

test "empty_stream_info refuses a STREAMINFO that is not the first block" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 0);
    defer empty.deinit();
    const flac = try encode(gpa, &empty, .int16, false);
    defer gpa.free(flac);
    // A first block of the wrong type cannot be the STREAMINFO.
    const wrong = try gpa.dupe(u8, flac);
    defer gpa.free(wrong);
    wrong[4] = 0x84; // last block, type 4 (VORBIS_COMMENT)
    try testing.expectEqual(@as(?AudioInfo, null), emptyStreamInfo(wrong, 0));
}

test "integer_pcm_still_clips_at_full_scale (flac)" {
    // The FLAC leg of float_headroom.rs `integer_pcm_still_clips_at_full_scale`, read back with
    // the test decoder as integers: full scale is -2^(bits-1) .. 2^(bits-1) - 1.
    const gpa = testing.allocator;
    var audio = try AudioBuffer.init(gpa, 48_000, 1, 9);
    defer audio.deinit();
    @memcpy(audio.channels[0], &[_]f32{ -2.0, -1.25, -1.0, -0.5, 0.0, 0.5, 1.0, 1.25, 2.0 });
    for ([_]BitDepth{ .int16, .int24, .int32 }) |depth| {
        const bits = bitsOf(depth);
        const half: i64 = @as(i64, 1) << @as(u6, @intCast(bits - 1));
        const quarter: i64 = half >> 1;
        const want = [_]i64{ -half, -half, -half, -quarter, 0, quarter, half - 1, half - 1, half - 1 };
        const bytes = try encode(gpa, &audio, depth, false);
        defer gpa.free(bytes);
        var dec = try decodeForTest(gpa, bytes);
        defer dec.deinit();
        try testing.expectEqualSlices(i64, &want, dec.channels[0].items);
    }
}

test "random_audio_roundtrips_through_flac" {
    // Port of the proptest: 200 deterministic cases, 1-3 channels, samples in [-1.2, 1.2) (so
    // clipping is exercised), lengths 1..3000 values. Cases with no whole frame are skipped, as
    // `prop_assume!` does.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_F1AC);
    const rng = prng.random();
    var checked: usize = 0;
    var case: usize = 0;
    while (case < 200) : (case += 1) {
        const channels = rng.intRangeAtMost(usize, 1, 3);
        const len = rng.intRangeAtMost(usize, 1, 3000);
        const samples = try gpa.alloc(f32, len);
        defer gpa.free(samples);
        for (samples) |*s| s.* = rng.float(f32) * 2.4 - 1.2;

        var buf = try AudioBuffer.fromInterleaved(gpa, 48_000, channels, samples);
        defer buf.deinit();
        if (buf.frames() == 0) continue;
        checked += 1;

        const flac = try encode(gpa, &buf, .int24, false);
        defer gpa.free(flac);
        var dec = try decodeForTest(gpa, flac);
        defer dec.deinit();
        try expectMatchesQuantized(&buf, &dec, 24, false);
    }
    try testing.expect(checked > 150);
}

test "encoder output is a stable FLAC stream for a deterministic ramp" {
    // Regression pin, NOT a byte-identity check against the Rust encoder: the SoundCraft crate
    // was not built or run here (it is read-only source material), so the expected values come
    // from this translation. They were checked outside the test: the reference `flac` 1.5.0
    // decoder accepts the stream (all frame CRCs pass) and returns the 5000 ramp frames. The
    // length and FNV-1a hash guard the bit layout against accidental change.
    const gpa = testing.allocator;
    var ramp = try AudioBuffer.init(gpa, 48_000, 2, 5000);
    defer ramp.deinit();
    for (0..5000) |i| {
        const x: f32 = @as(f32, @floatFromInt(i)) / 2500.0 - 1.0;
        ramp.channels[0][i] = x * 0.9;
        ramp.channels[1][i] = -x * 0.5;
    }
    const bytes = try encode(gpa, &ramp, .int16, false);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 2554), bytes.len);
    try testing.expectEqual(@as(u64, 0x2341_a9ef_0f2b_f748), fnv1a64(bytes));
}

test "streaming writer patches the header the same as one write" {
    const gpa = testing.allocator;
    var src = try sineBuffer(gpa, 48_000, 1, 10_000);
    defer src.deinit();
    const whole = try encode(gpa, &src, .int24, false);
    defer gpa.free(whole);

    var sink: MemSink = .{ .gpa = gpa };
    defer sink.deinit();
    var w = try Writer(MemSink).init(gpa, &sink, 1, 48_000, .int24, false);
    defer w.deinit();
    var at: usize = 0;
    while (at < src.frames()) {
        const n = @min(777, src.frames() - at);
        const chunk = [_][]const f32{src.channels[0][at..][0..n]};
        try w.write(&chunk, n);
        at += n;
    }
    try w.finish();
    try testing.expectEqualSlices(u8, whole, sink.buf.items);
}

fn bitsOf(depth: BitDepth) u32 {
    return switch (depth) {
        .int16 => 16,
        .int24 => 24,
        .int32 => 32,
        .float32 => 32,
    };
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h;
}

// ---------------------------------------------------------------------------
// Test-only FLAC decoder
// ---------------------------------------------------------------------------
//
// Test support, not production code. It decodes only what this encoder writes: CONSTANT,
// VERBATIM and FIXED subframes, partitioned Rice residuals without escapes, no wasted bits,
// independent channels, fixed blocksize. Production decoding is symphonia's. It checks each
// frame's CRC-8 header and CRC-16 footer, so the encoder's checksums are verified too.

const TestDecoded = struct {
    gpa: std.mem.Allocator,
    sample_rate: u32,
    channels: []std.ArrayList(i64),

    fn deinit(self: *TestDecoded) void {
        for (self.channels) |*c| c.deinit(self.gpa);
        self.gpa.free(self.channels);
    }

    fn frames(self: *const TestDecoded) usize {
        return if (self.channels.len == 0) 0 else self.channels[0].items.len;
    }
};

const BitReader = struct {
    b: []const u8,
    bit: usize = 0,

    fn read(self: *BitReader, n: u32) AudioError!u64 {
        var v: u64 = 0;
        for (0..n) |_| {
            if (self.bit >= self.b.len * 8) return error.Malformed;
            const byte = self.b[self.bit >> 3];
            const shift: u3 = @intCast(7 - (self.bit & 7));
            v = (v << 1) | @as(u64, (byte >> shift) & 1);
            self.bit += 1;
        }
        return v;
    }

    fn readSigned(self: *BitReader, n: u32) AudioError!i64 {
        const u = try self.read(n);
        if (n == 0) return 0;
        const sh: u6 = @intCast(64 - n);
        return @as(i64, @bitCast(u << sh)) >> sh;
    }

    fn readUnary(self: *BitReader) AudioError!u64 {
        var q: u64 = 0;
        while ((try self.read(1)) == 0) q += 1;
        return q;
    }
};

/// Fixed-predictor coefficients: row = order, column = lag - 1; x[n] = residual + sum(c * x[n-lag]).
const pred_coef = [5][4]i64{
    .{ 0, 0, 0, 0 },
    .{ 1, 0, 0, 0 },
    .{ 2, -1, 0, 0 },
    .{ 3, -3, 1, 0 },
    .{ 4, -6, 4, -1 },
};

fn decodeResidual(r: *BitReader, res: []i64, n: usize, order: usize) AudioError!void {
    const method = try r.read(2);
    const param_bits: u32 = switch (method) {
        0 => 4,
        1 => 5,
        else => return error.Unsupported,
    };
    const part_order = try r.read(4);
    if (part_order > max_partition_order) return error.Malformed;
    const parts: usize = @as(usize, 1) << @as(u6, @intCast(part_order));
    if (n % parts != 0 or n / parts <= order) return error.Malformed;
    const per = n / parts;
    var idx: usize = 0;
    for (0..parts) |p| {
        const count = if (p == 0) per - order else per;
        const k = try r.read(param_bits);
        if (k == (@as(u64, 1) << @as(u6, @intCast(param_bits))) - 1) return error.Unsupported; // escape
        for (0..count) |_| {
            const q = try r.readUnary();
            const low = try r.read(@as(u32, @intCast(k)));
            const u = (q << @as(u6, @intCast(k))) | low;
            res[idx] = if ((u & 1) == 0)
                @as(i64, @intCast(u >> 1))
            else
                -@as(i64, @intCast((u >> 1) + 1));
            idx += 1;
        }
    }
}

fn decodeSubframe(gpa: std.mem.Allocator, r: *BitReader, bps: u32, out: []i64) AudioError!void {
    if ((try r.read(1)) != 0) return error.Malformed;
    const kind = try r.read(6);
    if ((try r.read(1)) != 0) return error.Unsupported; // wasted bits
    const n = out.len;
    switch (kind) {
        0 => {
            const v = try r.readSigned(bps);
            @memset(out, v);
        },
        1 => {
            for (out) |*s| s.* = try r.readSigned(bps);
        },
        8...12 => {
            const order: usize = @intCast(kind - 8);
            if (order > n) return error.Malformed;
            for (0..order) |i| out[i] = try r.readSigned(bps);
            const res = try gpa.alloc(i64, n - order);
            defer gpa.free(res);
            try decodeResidual(r, res, n, order);
            for (order..n) |i| {
                var pred: i64 = 0;
                for (1..order + 1) |lag| pred += pred_coef[order][lag - 1] * out[i - lag];
                out[i] = res[i - order] + pred;
            }
        },
        else => return error.Unsupported,
    }
}

/// Decodes the frame at byte offset `start`; returns the offset just past its CRC-16.
fn decodeFrame(out: *TestDecoded, b: []const u8, start: usize, si_bps: u32) AudioError!usize {
    if (start + 2 > b.len or b[start] != 0xFF or b[start + 1] != 0xF8) return error.Malformed;
    var r = BitReader{ .b = b, .bit = start * 8 };
    _ = try r.read(16); // sync, reserved, blocking strategy
    const bs_code = try r.read(4);
    const sr_code = try r.read(4);
    const ch_code = try r.read(4);
    const bps_code_v = try r.read(3);
    _ = try r.read(1);

    // Frame number: UTF-8-style, one lead byte with `ones` leading one bits, then ones - 1 bytes.
    const lead = try r.read(8);
    var ones: u32 = 0;
    var m: u8 = @intCast(lead);
    while ((m & 0x80) != 0) : (m <<= 1) ones += 1;
    if (ones == 1 or ones > 7) return error.Malformed;
    if (ones == 0) {} else {
        for (0..ones - 1) |_| _ = try r.read(8);
    }

    const n: usize = switch (bs_code) {
        7 => @as(usize, @intCast(try r.read(16))) + 1,
        6 => @as(usize, @intCast(try r.read(8))) + 1,
        else => return error.Unsupported,
    };
    const sr: u32 = switch (sr_code) {
        0 => out.sample_rate,
        1 => 88_200,
        2 => 176_400,
        3 => 192_000,
        4 => 8_000,
        5 => 16_000,
        6 => 22_050,
        7 => 24_000,
        8 => 32_000,
        9 => 44_100,
        10 => 48_000,
        11 => 96_000,
        12 => @intCast((try r.read(8)) * 1000),
        13 => @intCast(try r.read(16)),
        14 => @intCast((try r.read(16)) * 10),
        else => return error.Unsupported,
    };
    if (sr != out.sample_rate) return error.Malformed;
    if (ch_code > 7) return error.Unsupported;
    const nch: usize = @as(usize, ch_code) + 1;
    if (nch != out.channels.len) return error.Malformed;
    const bps: u32 = switch (bps_code_v) {
        0 => si_bps,
        1 => 8,
        2 => 12,
        4 => 16,
        5 => 20,
        6 => 24,
        else => return error.Unsupported,
    };

    if (r.bit % 8 != 0) return error.Malformed;
    const header = b[start .. r.bit / 8];
    if (try r.read(8) != crc8(header)) return error.Malformed;

    for (0..nch) |c| {
        const samples = try out.gpa.alloc(i64, n);
        defer out.gpa.free(samples);
        try decodeSubframe(out.gpa, &r, bps, samples);
        try out.channels[c].appendSlice(out.gpa, samples);
    }

    const body_end = (r.bit + 7) / 8;
    if (body_end + 2 > b.len) return error.Malformed;
    const stored = std.mem.readInt(u16, b[body_end..][0..2], .big);
    if (crc16(b[start..body_end]) != stored) return error.Malformed;
    return body_end + 2;
}

fn decodeForTest(gpa: std.mem.Allocator, b: []const u8) AudioError!TestDecoded {
    if (b.len < 8 or !std.mem.eql(u8, b[0..4], "fLaC")) return error.Malformed;
    var pos: usize = 4;
    var sample_rate: u32 = 0;
    var channel_count: usize = 0;
    var si_bps: u32 = 0;
    var total: u64 = 0;
    while (true) {
        const head = pcm.beU32(b, pos) orelse return error.Malformed;
        const last = (head >> 31) == 1;
        const len: usize = head & 0x00ff_ffff;
        const body = pos + 4;
        if (body + len > b.len) return error.Malformed;
        if (pos == 4) {
            if (len != 34) return error.Malformed;
            const packed_bits = std.mem.readInt(u64, b[body + 10 ..][0..8], .big);
            sample_rate = @intCast(packed_bits >> 44);
            channel_count = @intCast(((packed_bits >> 41) & 0x7) + 1);
            si_bps = @intCast(((packed_bits >> 36) & 0x1f) + 1);
            total = packed_bits & 0xf_ffff_ffff;
        }
        pos = body + len;
        if (last) break;
    }

    var out: TestDecoded = .{
        .gpa = gpa,
        .sample_rate = sample_rate,
        .channels = try gpa.alloc(std.ArrayList(i64), channel_count),
    };
    @memset(out.channels, .empty);
    errdefer out.deinit();

    while (pos < b.len) pos = try decodeFrame(&out, b, pos, si_bps);
    if (total != out.frames()) return error.Malformed;
    return out;
}

test "test decoder rejects a corrupted frame CRC" {
    const gpa = testing.allocator;
    var empty = try AudioBuffer.init(gpa, 48_000, 1, 100);
    defer empty.deinit();
    const good = try encode(gpa, &empty, .int16, false);
    defer gpa.free(good);
    // Flip a bit in the frame body (not the header); the footer CRC must catch it.
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    bad[bad.len - 3] ^= 0x01;
    try testing.expectError(error.Malformed, decodeForTest(gpa, bad));
}
