/// WAV file decoder - handles reading and parsing WAV audio files
/// Supports PCM formats (8-bit, 16-bit, 24-bit, 32-bit) and IEEE float
const std = @import("std");
const sys = @import("../utils/sys.zig");

const File = std.Io.File;
const log = std.log.scoped(.wav);

pub const WavFormat = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
    extensible = 0xFFFE,
};

pub const WavHeader = struct {
    format: WavFormat,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    data_size: u32,
    data_offset: u64,
};

pub const WavFile = struct {
    allocator: std.mem.Allocator,
    header: WavHeader,
    file: File,
    /// Read position in bytes (reads are positional; the OS file offset is unused).
    pos: u64,

    /// Open and parse a WAV file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !WavFile {
        const file = try std.Io.Dir.cwd().openFile(sys.io(), path, .{});
        errdefer file.close(sys.io());

        const header = try parseHeader(file);

        log.info("Opened WAV: {s}", .{path});
        log.info("  Format: {s}", .{@tagName(header.format)});
        log.info("  Channels: {any}", .{header.num_channels});
        log.info("  Sample Rate: {any}", .{header.sample_rate});
        log.info("  Bits/Sample: {any}", .{header.bits_per_sample});
        log.info("  Duration: {d:.2}s", .{@as(f64, @floatFromInt(header.data_size)) /
            @as(f64, @floatFromInt(header.byte_rate))});

        return WavFile{
            .allocator = allocator,
            .header = header,
            .file = file,
            .pos = header.data_offset,
        };
    }

    pub fn close(self: *WavFile) void {
        self.file.close(sys.io());
    }

    /// Read samples as f32 (converted from any format)
    /// Output buffer must be pre-allocated: frames * channels
    pub fn readSamples(self: *WavFile, output: []f32, num_frames: usize) !usize {
        const channels = self.header.num_channels;
        const bytes_per_sample = self.header.bits_per_sample / 8;
        const bytes_needed = num_frames * channels * bytes_per_sample;

        // Allocate temp buffer for raw data
        const raw_buffer = try self.allocator.alloc(u8, bytes_needed);
        defer self.allocator.free(raw_buffer);

        // Read raw bytes
        const data_end = self.header.data_offset + self.header.data_size;
        const want = @min(raw_buffer.len, data_end -| self.pos);
        const bytes_read = try self.file.readPositionalAll(sys.io(), raw_buffer[0..want], self.pos);
        if (bytes_read == 0) return 0; // EOF
        self.pos += bytes_read;

        const samples_read = bytes_read / bytes_per_sample;

        // Convert to f32 based on format
        switch (self.header.format) {
            .pcm => {
                switch (self.header.bits_per_sample) {
                    8 => try convertPcm8(raw_buffer[0..bytes_read], output[0..samples_read]),
                    16 => try convertPcm16(raw_buffer[0..bytes_read], output[0..samples_read]),
                    24 => try convertPcm24(raw_buffer[0..bytes_read], output[0..samples_read]),
                    32 => try convertPcm32(raw_buffer[0..bytes_read], output[0..samples_read]),
                    else => return error.UnsupportedBitDepth,
                }
            },
            .ieee_float => {
                if (self.header.bits_per_sample == 32) {
                    try convertFloat32(raw_buffer[0..bytes_read], output[0..samples_read]);
                } else {
                    return error.UnsupportedBitDepth;
                }
            },
            else => return error.UnsupportedFormat,
        }

        return samples_read;
    }

    /// Seek to a specific frame position
    pub fn seekToFrame(self: *WavFile, frame: u64) !void {
        const bytes_per_sample = self.header.bits_per_sample / 8;
        const offset = self.header.data_offset + (frame * self.header.num_channels * bytes_per_sample);
        self.pos = offset;
    }

    /// Get total number of frames in file
    pub fn getTotalFrames(self: *const WavFile) u64 {
        const bytes_per_sample = self.header.bits_per_sample / 8;
        return self.header.data_size / (self.header.num_channels * bytes_per_sample);
    }

    /// Get current frame position
    pub fn getCurrentFrame(self: *WavFile) !u64 {
        const pos = self.pos;
        const bytes_per_sample = self.header.bits_per_sample / 8;
        const bytes_from_start = pos - self.header.data_offset;
        return bytes_from_start / (self.header.num_channels * bytes_per_sample);
    }
};

fn parseHeader(file: File) !WavHeader {
    const io = sys.io();
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var r = &reader.interface;

    // RIFF header
    var riff_id: [4]u8 = undefined;
    try r.readSliceAll(&riff_id);
    if (!std.mem.eql(u8, &riff_id, "RIFF")) {
        return error.InvalidWavFile;
    }

    const chunk_size = try r.takeInt(u32, .little);
    _ = chunk_size;

    var wave_id: [4]u8 = undefined;
    try r.readSliceAll(&wave_id);
    if (!std.mem.eql(u8, &wave_id, "WAVE")) {
        return error.InvalidWavFile;
    }

    // Find fmt chunk
    var format: WavFormat = undefined;
    var num_channels: u16 = undefined;
    var sample_rate: u32 = undefined;
    var byte_rate: u32 = undefined;
    var block_align: u16 = undefined;
    var bits_per_sample: u16 = undefined;

    while (true) {
        var chunk_id: [4]u8 = undefined;
        try r.readSliceAll(&chunk_id);
        const size = try r.takeInt(u32, .little);

        if (std.mem.eql(u8, &chunk_id, "fmt ")) {
            format = @fromBackingInt(@intCast(try r.takeInt(u16, .little)));
            num_channels = try r.takeInt(u16, .little);
            sample_rate = try r.takeInt(u32, .little);
            byte_rate = try r.takeInt(u32, .little);
            block_align = try r.takeInt(u16, .little);
            bits_per_sample = try r.takeInt(u16, .little);

            // Skip any extra format bytes
            const extra_size = size - 16;
            if (extra_size > 0) {
                try reader.seekBy(@intCast(extra_size));
            }
            break;
        } else {
            // Skip unknown chunk
            try reader.seekBy(@intCast(size));
        }
    }

    // Find data chunk
    var data_size: u32 = undefined;
    var data_offset: u64 = undefined;

    while (true) {
        var chunk_id: [4]u8 = undefined;
        try r.readSliceAll(&chunk_id);
        const size = try r.takeInt(u32, .little);

        if (std.mem.eql(u8, &chunk_id, "data")) {
            data_size = size;
            data_offset = reader.logicalPos();
            break;
        } else {
            // Skip unknown chunk
            try reader.seekBy(@intCast(size));
        }
    }

    return WavHeader{
        .format = format,
        .num_channels = num_channels,
        .sample_rate = sample_rate,
        .byte_rate = byte_rate,
        .block_align = block_align,
        .bits_per_sample = bits_per_sample,
        .data_size = data_size,
        .data_offset = data_offset,
    };
}

// Conversion functions from PCM to f32

fn convertPcm8(input: []const u8, output: []f32) !void {
    if (input.len != output.len) return error.BufferSizeMismatch;

    for (input, 0..) |sample, i| {
        // 8-bit PCM is unsigned (0-255), convert to -1.0 to 1.0
        const signed = @as(i16, sample) - 128;
        output[i] = @as(f32, @floatFromInt(signed)) / 128.0;
    }
}

fn convertPcm16(input: []const u8, output: []f32) !void {
    if (input.len != output.len * 2) return error.BufferSizeMismatch;

    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const sample = std.mem.readInt(i16, input[i * 2 ..][0..2], .little);
        output[i] = @as(f32, @floatFromInt(sample)) / 32768.0;
    }
}

fn convertPcm24(input: []const u8, output: []f32) !void {
    if (input.len != output.len * 3) return error.BufferSizeMismatch;

    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        // Read 24-bit as 3 bytes, sign-extend to i32
        const byte1 = input[i * 3];
        const byte2 = input[i * 3 + 1];
        const byte3 = input[i * 3 + 2];

        var sample: i32 = @as(i32, byte1) |
            (@as(i32, byte2) << 8) |
            (@as(i32, byte3) << 16);

        // Sign extend from 24-bit to 32-bit
        if ((sample & 0x800000) != 0) {
            sample |= @as(i32, @bitCast(@as(u32, 0xFF000000)));
        }

        output[i] = @as(f32, @floatFromInt(sample)) / 8388608.0;
    }
}

fn convertPcm32(input: []const u8, output: []f32) !void {
    if (input.len != output.len * 4) return error.BufferSizeMismatch;

    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const sample = std.mem.readInt(i32, input[i * 4 ..][0..4], .little);
        output[i] = @as(f32, @floatFromInt(sample)) / 2147483648.0;
    }
}

fn convertFloat32(input: []const u8, output: []f32) !void {
    if (input.len != output.len * 4) return error.BufferSizeMismatch;

    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const bytes: *const [4]u8 = input[i * 4 ..][0..4];
        output[i] = @bitCast(std.mem.readInt(u32, bytes, .little));
    }
}

test "wav header parsing" {
    // Basic structure test - actual file tests would need test fixtures
    const testing = std.testing;

    // Test format enum
    try testing.expectEqual(@as(u16, 1), @backingInt(WavFormat.pcm));
    try testing.expectEqual(@as(u16, 3), @backingInt(WavFormat.ieee_float));
}

test "pcm conversions" {
    const testing = std.testing;

    // Test 16-bit conversion
    var input: [4]u8 = .{ 0x00, 0x00, 0xFF, 0x7F }; // 0, 32767
    var output: [2]f32 = undefined;

    try convertPcm16(&input, &output);
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[1], 0.001);
}

// =============================================================================
// WAV Writer
// =============================================================================

pub const WavWriter = struct {
    file: File,
    sample_rate: u32,
    num_channels: u16,
    bits_per_sample: u16,
    data_size: u32,
    /// Bytes are staged here and flushed in large positional writes.
    buf: [buffer_len]u8 = undefined,
    buf_len: usize = 0,
    /// File offset where `buf` will be written.
    pos: u64 = 0,

    const buffer_len = 64 * 1024;
    const header_len = 44;

    /// Create a new WAV file for writing
    pub fn create(path: []const u8, sample_rate: u32, num_channels: u16, bits_per_sample: u16) !WavWriter {
        const file = try std.Io.Dir.cwd().createFile(sys.io(), path, .{});
        errdefer file.close(sys.io());

        var writer = WavWriter{
            .file = file,
            .sample_rate = sample_rate,
            .num_channels = num_channels,
            .bits_per_sample = bits_per_sample,
            .data_size = 0,
        };
        // Placeholder header; close() rewrites it with the final sizes.
        var header: [header_len]u8 = undefined;
        writer.encodeHeader(&header);
        try writer.file.writePositionalAll(sys.io(), &header, 0);
        writer.pos = header_len;
        return writer;
    }

    fn encodeHeader(self: *const WavWriter, out: *[header_len]u8) void {
        const bytes_per_sample = self.bits_per_sample / 8;
        const byte_rate = self.sample_rate * self.num_channels * bytes_per_sample;
        const block_align = self.num_channels * bytes_per_sample;
        @memcpy(out[0..4], "RIFF");
        std.mem.writeInt(u32, out[4..8], 36 + self.data_size, .little); // file size - 8
        @memcpy(out[8..12], "WAVE");
        @memcpy(out[12..16], "fmt ");
        std.mem.writeInt(u32, out[16..20], 16, .little); // fmt chunk size
        std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
        std.mem.writeInt(u16, out[22..24], self.num_channels, .little);
        std.mem.writeInt(u32, out[24..28], self.sample_rate, .little);
        std.mem.writeInt(u32, out[28..32], byte_rate, .little);
        std.mem.writeInt(u16, out[32..34], block_align, .little);
        std.mem.writeInt(u16, out[34..36], self.bits_per_sample, .little);
        @memcpy(out[36..40], "data");
        std.mem.writeInt(u32, out[40..44], self.data_size, .little);
    }

    fn put(self: *WavWriter, bytes: []const u8) !void {
        if (self.buf_len + bytes.len > self.buf.len) try self.flush();
        @memcpy(self.buf[self.buf_len..][0..bytes.len], bytes);
        self.buf_len += bytes.len;
    }

    fn flush(self: *WavWriter) !void {
        if (self.buf_len == 0) return;
        try self.file.writePositionalAll(sys.io(), self.buf[0..self.buf_len], self.pos);
        self.pos += self.buf_len;
        self.buf_len = 0;
    }

    /// Write f32 samples as 16-bit PCM (most common export format)
    pub fn writeSamples(self: *WavWriter, samples: []const f32) !void {
        for (samples) |sample| {
            const clamped = @max(-1.0, @min(1.0, sample));
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(i16, &bytes, @intFromFloat(clamped * 32767.0), .little);
            try self.put(&bytes);
        }
        self.data_size += @intCast(samples.len * 2);
    }

    /// Write f32 samples as 16-bit PCM with TPDF dither (use for exports).
    pub fn writeSamplesDithered(self: *WavWriter, samples: []const f32, dither: *TpdfDither) !void {
        for (samples) |sample| {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(i16, &bytes, dither.quantize16(sample), .little);
            try self.put(&bytes);
        }
        self.data_size += @intCast(samples.len * 2);
    }

    /// Write f32 samples as 24-bit PCM (high quality export)
    pub fn writeSamples24(self: *WavWriter, samples: []const f32) !void {
        for (samples) |sample| {
            const clamped = @max(-1.0, @min(1.0, sample));
            var bytes: [3]u8 = undefined;
            std.mem.writeInt(i24, &bytes, @intFromFloat(clamped * 8388607.0), .little);
            try self.put(&bytes);
        }
        self.data_size += @intCast(samples.len * 3);
    }

    /// Finalize the WAV file (flushes and rewrites the header with the real sizes).
    pub fn close(self: *WavWriter) !void {
        defer self.file.close(sys.io());
        try self.flush();
        var header: [header_len]u8 = undefined;
        self.encodeHeader(&header);
        try self.file.writePositionalAll(sys.io(), &header, 0);
    }

    /// Close without finalizing (use on error paths).
    pub fn abort(self: *WavWriter) void {
        self.file.close(sys.io());
    }
};

/// Triangular (TPDF) dither for 16-bit quantization: the sum of two uniform
/// random values in [-0.5, 0.5) LSB, so the noise spans +-1 LSB. Deterministic
/// (xorshift32) so exports are reproducible.
pub const TpdfDither = struct {
    state: u32 = 0x9E3779B9,

    fn nextUniform(self: *TpdfDither) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        // 24 random bits -> [0, 1)
        return @as(f32, @floatFromInt(x >> 8)) / 16777216.0;
    }

    /// Quantize a sample in [-1, 1] to i16 with TPDF dither.
    pub fn quantize16(self: *TpdfDither, sample: f32) i16 {
        const clamped = @max(-1.0, @min(1.0, sample));
        const noise = (self.nextUniform() - 0.5) + (self.nextUniform() - 0.5);
        const scaled = clamped * 32767.0 + noise;
        const rounded = @round(scaled);
        return @intFromFloat(@max(-32768.0, @min(32767.0, rounded)));
    }
};

test "TpdfDither: silence stays within 1 LSB of zero" {
    var d = TpdfDither{};
    var nonzero: usize = 0;
    for (0..100_000) |_| {
        const q = d.quantize16(0.0);
        try std.testing.expect(q >= -1 and q <= 1);
        if (q != 0) nonzero += 1;
    }
    // Dither is actually active (about half the samples toggle)
    try std.testing.expect(nonzero > 10_000);
}

test "TpdfDither: mean error is near zero for a DC level" {
    var d = TpdfDither{};
    const level: f32 = 0.25003; // not on an LSB boundary
    var sum: f64 = 0;
    const n = 200_000;
    for (0..n) |_| sum += @as(f64, @floatFromInt(d.quantize16(level)));
    const mean = sum / n;
    try std.testing.expect(@abs(mean - @as(f64, level) * 32767.0) < 0.05);
}

test "wav writer" {
    const testing = std.testing;
    _ = testing;

    // Would need to test with actual file writes
    // For now, just verify struct creation compiles
}

// =============================================================================
// Comprehensive Tests
// =============================================================================

test "convertPcm8 - unsigned to signed conversion" {
    const testing = std.testing;

    // 8-bit PCM: 0 = -1.0, 128 = 0.0, 255 = ~1.0
    var input: [4]u8 = .{ 0, 128, 255, 64 };
    var output: [4]f32 = undefined;

    try convertPcm8(&input, &output);

    // 0 -> -128 -> -1.0
    try testing.expectApproxEqAbs(@as(f32, -1.0), output[0], 0.01);
    // 128 -> 0 -> 0.0
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[1], 0.01);
    // 255 -> 127 -> ~0.99
    try testing.expectApproxEqAbs(@as(f32, 0.99), output[2], 0.01);
    // 64 -> -64 -> -0.5
    try testing.expectApproxEqAbs(@as(f32, -0.5), output[3], 0.01);
}

test "convertPcm8 - buffer size mismatch" {
    const testing = std.testing;

    var input: [4]u8 = .{ 0, 128, 255, 64 };
    var output: [3]f32 = undefined;

    try testing.expectError(error.BufferSizeMismatch, convertPcm8(&input, &output));
}

test "convertPcm16 - full range conversion" {
    const testing = std.testing;

    // Test extreme values: -32768, 0, 32767, -16384
    var input: [8]u8 = .{
        0x00, 0x80, // -32768
        0x00, 0x00, // 0
        0xFF, 0x7F, // 32767
        0x00, 0xC0, // -16384
    };
    var output: [4]f32 = undefined;

    try convertPcm16(&input, &output);

    try testing.expectApproxEqAbs(@as(f32, -1.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), output[3], 0.001);
}

test "convertPcm16 - buffer size mismatch" {
    const testing = std.testing;

    var input: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var output: [3]f32 = undefined;

    try testing.expectError(error.BufferSizeMismatch, convertPcm16(&input, &output));
}

test "convertPcm24 - 24-bit sign extension" {
    const testing = std.testing;

    // 24-bit values (little-endian):
    // 0x000000 = 0
    // 0x7FFFFF = 8388607 (max positive)
    // 0x800000 = -8388608 (max negative)
    // 0x400000 = 4194304 (half positive)
    var input: [12]u8 = .{
        0x00, 0x00, 0x00, // 0
        0xFF, 0xFF, 0x7F, // 8388607
        0x00, 0x00, 0x80, // -8388608
        0x00, 0x00, 0x40, // 4194304
    };
    var output: [4]f32 = undefined;

    try convertPcm24(&input, &output);

    try testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), output[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), output[3], 0.001);
}

test "convertPcm24 - negative value sign extension" {
    const testing = std.testing;

    // Test sign extension for negative values
    // 0xFFFFFF should be -1 in 24-bit, which extends to 0xFFFFFFFF in 32-bit
    var input: [3]u8 = .{ 0xFF, 0xFF, 0xFF };
    var output: [1]f32 = undefined;

    try convertPcm24(&input, &output);

    // -1 / 8388608.0 ≈ -0.000000119
    try testing.expect(output[0] < 0.0);
}

test "convertPcm24 - buffer size mismatch" {
    const testing = std.testing;

    var input: [12]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var output: [3]f32 = undefined;

    try testing.expectError(error.BufferSizeMismatch, convertPcm24(&input, &output));
}

test "convertPcm32 - full range conversion" {
    const testing = std.testing;

    var input: [8]u8 = .{
        0x00, 0x00, 0x00, 0x80, // -2147483648 (min i32)
        0xFF, 0xFF, 0xFF, 0x7F, // 2147483647 (max i32)
    };
    var output: [2]f32 = undefined;

    try convertPcm32(&input, &output);

    try testing.expectApproxEqAbs(@as(f32, -1.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[1], 0.001);
}

test "convertFloat32 - direct float conversion" {
    const testing = std.testing;

    // Create float values as bytes
    var input: [12]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], @bitCast(@as(f32, 0.5)), .little);
    std.mem.writeInt(u32, input[4..8], @bitCast(@as(f32, -0.75)), .little);
    std.mem.writeInt(u32, input[8..12], @bitCast(@as(f32, 1.0)), .little);

    var output: [3]f32 = undefined;

    try convertFloat32(&input, &output);

    try testing.expectApproxEqAbs(@as(f32, 0.5), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.75), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[2], 0.001);
}

test "WavHeader - format enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 1), @backingInt(WavFormat.pcm));
    try testing.expectEqual(@as(u16, 3), @backingInt(WavFormat.ieee_float));
    try testing.expectEqual(@as(u16, 6), @backingInt(WavFormat.alaw));
    try testing.expectEqual(@as(u16, 7), @backingInt(WavFormat.mulaw));
    try testing.expectEqual(@as(u16, 0xFFFE), @backingInt(WavFormat.extensible));
}

test "WavHeader - structure layout" {
    const testing = std.testing;

    const header = WavHeader{
        .format = .pcm,
        .num_channels = 2,
        .sample_rate = 44100,
        .byte_rate = 176400, // 44100 * 2 * 2
        .block_align = 4,
        .bits_per_sample = 16,
        .data_size = 88200, // 0.5 seconds
        .data_offset = 44,
    };

    try testing.expectEqual(WavFormat.pcm, header.format);
    try testing.expectEqual(@as(u16, 2), header.num_channels);
    try testing.expectEqual(@as(u32, 44100), header.sample_rate);
    try testing.expectEqual(@as(u16, 4), header.block_align);
}

test "WavWriter - sample clamping in writeSamples" {
    const testing = std.testing;

    // Create a temp file
    const tmp_path = "test_wav_writer.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), tmp_path) catch {};

    var writer = try WavWriter.create(tmp_path, 44100, 2, 16);

    // Test samples including out-of-range values
    const samples = [_]f32{ 0.5, -0.5, 1.5, -1.5, 0.0 }; // 1.5 and -1.5 should clamp
    try writer.writeSamples(&samples);

    try testing.expectEqual(@as(u32, 10), writer.data_size); // 5 samples * 2 bytes

    try writer.close();
}

test "WavWriter - 24-bit write" {
    const testing = std.testing;

    const tmp_path = "test_wav_writer_24.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), tmp_path) catch {};

    var writer = try WavWriter.create(tmp_path, 48000, 2, 24);

    const samples = [_]f32{ 1.0, -1.0, 0.0 };
    try writer.writeSamples24(&samples);

    try testing.expectEqual(@as(u32, 9), writer.data_size); // 3 samples * 3 bytes

    try writer.close();
}

test "WavWriter - header fields" {
    const testing = std.testing;

    const tmp_path = "test_wav_header.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), tmp_path) catch {};

    var writer = try WavWriter.create(tmp_path, 48000, 1, 16);

    try testing.expectEqual(@as(u32, 48000), writer.sample_rate);
    try testing.expectEqual(@as(u16, 1), writer.num_channels);
    try testing.expectEqual(@as(u16, 16), writer.bits_per_sample);
    try testing.expectEqual(@as(u32, 0), writer.data_size);

    try writer.close();
}

test "WavWriter round-trips through WavFile" {
    const testing = std.testing;
    const tmp_path = "test_wav_roundtrip.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), tmp_path) catch {};

    var writer = try WavWriter.create(tmp_path, 48000, 2, 16);
    const samples = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    try writer.writeSamples(&samples);
    try writer.close();

    var file = try WavFile.open(testing.allocator, tmp_path);
    defer file.close();
    try testing.expectEqual(@as(u32, 48000), file.header.sample_rate);
    try testing.expectEqual(@as(u64, 2), file.getTotalFrames());
    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try file.readSamples(&out, 2));
    for (samples, out) |want, got| try testing.expectApproxEqAbs(want, got, 1.0 / 16384.0);
    try testing.expectEqual(@as(usize, 0), try file.readSamples(&out, 2));
}
