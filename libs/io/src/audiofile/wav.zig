// Translated to Zig from soundcraft/crates/audio-io/src/wav.rs, soundcraft/crates/audio-io/tests/it/wav_empty_data.rs, soundcraft/crates/audio-io/tests/it/malformed.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Native WAV / BWF / RF64 reader and writer (RIFF chunk layout per the Microsoft multimedia
//! specification, `bext` per EBU Tech 3285, `ds64` per EBU Tech 3306).
//!
//! Inputs are hostile: every offset and length read from a file is bounds-checked, and chunk
//! walks are bounded. Readers borrow the input bytes (BWF strings point into them). The writer
//! borrows the BWF strings it is given, which must outlive it. `decode` and `encode` allocate
//! their output; the writer allocates its buffers in `init` and never again.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const pcm = @import("pcm.zig");
const buffer = @import("buffer.zig");

const AudioError = types.AudioError;
const AudioBuffer = buffer.AudioBuffer;
const log = std.log.scoped(.wav);

const WAVE_FORMAT_PCM: u16 = 1;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;
/// Tail of the KSDATAFORMAT_SUBTYPE_* GUIDs (bytes 2..16); bytes 0..2 hold the format tag.
const GUID_TAIL = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
/// Tail of the Ambisonic subtype GUIDs {0000000x-0721-11D3-8644-C8C1CA000000}: PCM (x = 1) and float (x = 3) as well.
const AMBISONIC_TAIL = [_]u8{ 0x00, 0x00, 0x21, 0x07, 0xD3, 0x11, 0x86, 0x44, 0xC8, 0xC1, 0xCA, 0x00, 0x00, 0x00 };
const BEXT_MIN_LEN: usize = 602;
/// Chunks the reader looks at before it gives up, so a file of tiny chunks terminates.
const MAX_CHUNKS: usize = 100_000;
/// Largest header the writer builds: bext + fmt + fact + RIFF/ds64 framing is under 800 bytes.
const HEADER_MAX: usize = 1024;
/// Scratch bytes the writer batches samples through (at least one frame).
const SCRATCH_BYTES: usize = 16 * 1024;

/// Parsed WAV layout (no sample data decoded yet).
pub const WavLayout = struct {
    info: types.AudioInfo,
    kind: pcm.PcmKind,
    data_start: usize,
    data_len: usize,
};

/// Outcome of parsing a WAV header.
pub const WavParse = union(enum) {
    /// A PCM / float layout read natively.
    native: WavLayout,
    /// A valid WAV whose codec is left to the foreign decoder (ADPCM, A-law, ...).
    foreign: struct { bwf: ?types.BwfInfo },
};

const Fmt = struct {
    tag: u16,
    channels: u16,
    sample_rate: u32,
    block_align: u16,
    bits: u16,
    valid_bits: u16,
};

fn parseFmt(c: []const u8) AudioError!Fmt {
    var fmt = Fmt{
        .tag = pcm.leU16(c, 0) orelse return error.Malformed,
        .channels = pcm.leU16(c, 2) orelse return error.Malformed,
        .sample_rate = pcm.leU32(c, 4) orelse return error.Malformed,
        .block_align = pcm.leU16(c, 12) orelse return error.Malformed,
        .bits = pcm.leU16(c, 14) orelse 0,
        .valid_bits = 0,
    };
    fmt.valid_bits = fmt.bits;
    if (fmt.tag == WAVE_FORMAT_EXTENSIBLE) {
        // cbSize(2) validBits(2) channelMask(4) subFormat GUID(16)
        const cb_size = pcm.leU16(c, 16) orelse return error.Malformed;
        const valid = pcm.leU16(c, 18) orelse return error.Malformed;
        const sub = pcm.leU16(c, 24) orelse return error.Malformed;
        if (c.len < 40) return error.Malformed;
        const tail = c[26..40];
        if (cb_size < 22) return error.Malformed;
        if (valid > fmt.bits) return error.Malformed;
        if (valid != 0) fmt.valid_bits = valid;
        // A subtype outside the KSDATAFORMAT_SUBTYPE_* family is not PCM/float, whatever its first two
        // bytes say: keep the extensible tag so the file goes to the foreign decoder.
        if (std.mem.eql(u8, tail, &GUID_TAIL) or std.mem.eql(u8, tail, &AMBISONIC_TAIL)) fmt.tag = sub;
    }
    return fmt;
}

/// A NUL-padded ASCII field, borrowed from `b`, without its NUL padding and trailing blanks.
/// Seridian: the Rust code decodes it lossily as UTF-8; here the bytes are kept as they are.
fn fixedStr(b: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, b, 0) orelse b.len;
    return std.mem.trimEnd(u8, b[0..end], " \t\r\n\x0b\x0c");
}

fn parseBext(c: []const u8) ?types.BwfInfo {
    if (c.len < 346) return null;
    const lo = @as(u64, pcm.leU32(c, 338) orelse return null);
    const hi = @as(u64, pcm.leU32(c, 342) orelse return null);
    return .{
        .description = fixedStr(c[0..256]),
        .originator = fixedStr(c[256..288]),
        .originator_reference = fixedStr(c[288..320]),
        .origination_date = fixedStr(c[320..330]),
        .origination_time = fixedStr(c[330..338]),
        .time_reference = (hi << 32) | lo,
    };
}

/// True when the four bytes at `pos` are `want`.
fn isTag(b: []const u8, pos: usize, want: *const [4]u8) bool {
    const got = pcm.tag(b, pos) orelse return false;
    return std.mem.eql(u8, &got, want);
}

/// Refuse the WAVE file whose RIFF header is at `at` if an INFO entry claims more bytes than the
/// file holds: a reader allocates each entry's length. Chunks are walked where those readers read
/// them: after the bytes a chunk's parser uses, not its declared length.
pub fn checkInfo(b: []const u8, at: usize) AudioError!void {
    if (!isTag(b, at +| 8, "WAVE")) return;
    var pos: usize = at +| 12;
    while (pcm.tag(b, pos)) |id| {
        const len: usize = pcm.leU32(b, pos + 4) orelse break;
        const body = pos + 8;
        const used = (try chunkUsed(b, id, body, len)) orelse break;
        pos = body +| used +| (len & 1);
    }
}

/// The bytes a chunk's reader uses, or null when the walk stops at this chunk.
fn chunkUsed(b: []const u8, id: [4]u8, body: usize, len: usize) AudioError!?usize {
    if (std.mem.eql(u8, &id, "data")) return null;
    if (std.mem.eql(u8, &id, "fmt ")) return fmtUsed(b, body, len);
    if (std.mem.eql(u8, &id, "LIST")) {
        if (len < 4) return null;
        const entries: usize = if (isTag(b, body, "INFO")) try infoEntries(b, body + 4, len - 4) else 0;
        // The list pads itself, then the chunk is padded again.
        return @max(entries, len - 4) +| 4 +| (len & 1);
    }
    return len;
}

/// The bytes a reader uses of a `fmt ` chunk: some formats' parsers go by their own extra size.
fn fmtUsed(b: []const u8, body: usize, len: usize) usize {
    const t = pcm.leU16(b, body) orelse return len;
    return switch (t) {
        2, 6, 7, 0x11 => if (pcm.leU16(b, body + 16)) |extra| 18 + @as(usize, extra) else len,
        0xfffe => 40,
        else => len,
    };
}

/// Checks the INFO entries in the `len` bytes from `start`; returns the bytes read of them, with
/// the pad read after an odd entry.
fn infoEntries(b: []const u8, start: usize, len: usize) AudioError!usize {
    var used: usize = 0;
    while (used +| 8 <= len) {
        const n: usize = pcm.leU32(b, start +| used +| 4) orelse break;
        const avail = b.len -| (start +| used +| 8);
        if (n > avail) return error.Malformed;
        used = used +| 8 +| n;
        used = used +| (used & 1);
    }
    return used;
}

/// True when the bytes start like a RIFF/RF64/BW64 WAVE file.
pub fn isWav(b: []const u8) bool {
    const form = pcm.tag(b, 0) orelse return false;
    const known = std.mem.eql(u8, &form, "RIFF") or std.mem.eql(u8, &form, "RF64") or std.mem.eql(u8, &form, "BW64");
    return known and isTag(b, 8, "WAVE");
}

/// True when everything from `from` to the end of the file is whole RIFF chunks (four printable
/// ASCII id bytes, a size that fits, the pad byte after an odd size; the last chunk's pad may be
/// missing): the metadata of a finished file, not samples.
fn onlyChunksFollow(b: []const u8, from: usize) bool {
    var pos = from;
    while (pos < b.len) {
        const id = pcm.tag(b, pos) orelse return false;
        const size32 = pcm.leU32(b, pos + 4) orelse return false;
        for (id) |c| {
            if (c < 0x20 or c >= 0x7f) return false;
        }
        const size: usize = size32;
        const body = std.math.add(usize, pos, 8) catch return false;
        const end = std.math.add(usize, body, size) catch return false;
        if (end > b.len) return false;
        const next = end + (size & 1);
        if (end == b.len or next == b.len) return true;
        pos = next;
    }
    return false;
}

/// A `data` chunk header as found in the file, for `dataChunkLen`.
const DataChunk = struct {
    body: usize,
    size32: u32,
    is_rf64: bool,
    remaining: usize,
    declared: usize,
};

/// Bytes of audio a `data` chunk holds: leniently, whatever is present when the size is wrong or
/// the recording was never finalised.
fn dataChunkLen(b: []const u8, c: DataChunk) usize {
    const riff_size: u64 = pcm.leU32(b, 4) orelse 0;
    const finished = riff_size + 8 == @as(u64, b.len);
    const empty = c.size32 == 0 and !c.is_rf64 and finished and onlyChunksFollow(b, c.body);
    if (c.size32 == 0 and !c.is_rf64 and !empty) return c.remaining;
    return @min(c.declared, c.remaining);
}

const Layout = struct {
    kind: pcm.PcmKind,
    sample_format: types.SampleFormat,
};

/// The sample layout of a `fmt` chunk, null for a format this unit does not read natively.
fn pcmLayout(fmt: Fmt) AudioError!?Layout {
    if (fmt.tag == WAVE_FORMAT_PCM and fmt.bits >= 1 and fmt.bits <= 32) {
        const bytes: usize = (fmt.bits + 7) / 8;
        const sf: types.SampleFormat = switch (@min(fmt.valid_bits, fmt.bits)) {
            0...8 => .int8,
            9...16 => .int16,
            17...24 => .int24,
            else => .int32,
        };
        return .{
            .kind = .{ .int = .{ .bytes = bytes, .big_endian = false, .unsigned = bytes == 1 } },
            .sample_format = sf,
        };
    }
    if (fmt.tag == WAVE_FORMAT_IEEE_FLOAT and fmt.bits == 32) {
        return .{ .kind = .{ .float = .{ .bytes = 4, .big_endian = false } }, .sample_format = .float32 };
    }
    if (fmt.tag == WAVE_FORMAT_IEEE_FLOAT and fmt.bits == 64) {
        return .{ .kind = .{ .float = .{ .bytes = 8, .big_endian = false } }, .sample_format = .float64 };
    }
    if (fmt.tag == WAVE_FORMAT_PCM or fmt.tag == WAVE_FORMAT_IEEE_FLOAT) return error.Unsupported;
    return null;
}

const DataSpan = struct { start: usize, len: usize };

/// Parses a WAV header. The result borrows `b` (BWF strings point into it).
pub fn parse(b: []const u8) AudioError!WavParse {
    if (!isWav(b)) return error.Malformed;
    const head = pcm.tag(b, 0) orelse return error.Malformed;
    const is_rf64 = !std.mem.eql(u8, &head, "RIFF");
    var ds64_data: ?u64 = null;
    var fmt: ?Fmt = null;
    var bwf: ?types.BwfInfo = null;
    var data: ?DataSpan = null;

    var pos: usize = 12;
    var chunks: usize = 0;
    while (pcm.tag(b, pos)) |id| {
        const size32 = pcm.leU32(b, pos + 4) orelse break;
        chunks += 1;
        if (chunks > MAX_CHUNKS) break;
        const body = std.math.add(usize, pos, 8) catch return error.Malformed;
        const remaining = b.len -| body;
        const is_data = std.mem.eql(u8, &id, "data");
        var size: u64 = size32;
        if (is_data and is_rf64 and size32 == std.math.maxInt(u32)) {
            size = ds64_data orelse @as(u64, @intCast(remaining));
        }
        const declared: usize = std.math.cast(usize, size) orelse std.math.maxInt(usize);
        if (is_data) {
            // Lenient: a truncated recording (or a streaming writer's 0 / 0xFFFFFFFF size) still
            // yields whatever audio is actually present.
            const len = dataChunkLen(b, .{
                .body = body,
                .size32 = size32,
                .is_rf64 = is_rf64,
                .remaining = remaining,
                .declared = declared,
            });
            if (data == null) data = .{ .start = body, .len = len };
            if (declared > remaining) break;
        } else {
            // A truncated non-audio chunk at the end of the file: stop scanning.
            if (declared > remaining) break;
            const c = b[body..][0..declared];
            if (std.mem.eql(u8, &id, "fmt ")) {
                fmt = try parseFmt(c);
            } else if (std.mem.eql(u8, &id, "bext")) {
                bwf = parseBext(c);
            } else if (std.mem.eql(u8, &id, "ds64")) {
                ds64_data = pcm.leU64(c, 8);
            }
        }
        const padded = declared +| (declared & 1);
        pos = std.math.add(usize, body, padded) catch break;
    }

    const f = fmt orelse return error.Malformed;
    if (f.channels == 0) return error.Malformed;
    if (f.sample_rate == 0) return error.Malformed;
    const channels: usize = f.channels;
    const layout = (try pcmLayout(f)) orelse return .{ .foreign = .{ .bwf = bwf } };
    const bytes = layout.kind.byteCount();
    const block = std.math.mul(usize, bytes, channels) catch return error.Malformed;
    if (@as(usize, f.block_align) != block) {
        log.debug("WAV block_align {d} disagrees with computed {d}; using computed", .{ f.block_align, block });
    }
    const span = data orelse return error.Malformed;
    const frames: u64 = @intCast(span.len / block);
    return .{ .native = .{
        .info = .{
            .format = .wav,
            .sample_format = layout.sample_format,
            .sample_rate = f.sample_rate,
            .channels = f.channels,
            .frames = frames,
            .bwf = bwf,
        },
        .kind = layout.kind,
        .data_start = span.start,
        .data_len = span.len,
    } };
}

/// Decodes the samples of a natively read WAV into planar `f32`. The buffer owns its channels
/// (free with `AudioBuffer.deinit`). The sample budget is `pcm.MAX_DECODE_SAMPLES`, enforced by
/// `pcm.deinterleave`.
pub fn decode(gpa: std.mem.Allocator, b: []const u8, layout: WavLayout) AudioError!AudioBuffer {
    const end = @min(layout.data_start +| layout.data_len, b.len);
    const data: []const u8 = if (layout.data_start <= end) b[layout.data_start..end] else &.{};
    const chans = try pcm.deinterleave(gpa, data, layout.kind, layout.info.channels, layout.info.frames);
    return .{ .gpa = gpa, .sample_rate = layout.info.sample_rate, .channels = chans };
}

/// Default speaker mask for a channel count (callers that know the layout pass their own):
/// mono, stereo, LCR, quad, 5.0, 5.1, 6.1, 7.1 (sides + rears), 7.1.4.
fn channelMask(channels: usize) u32 {
    return switch (channels) {
        1 => 0x4,
        2 => 0x3,
        3 => 0x7,
        4 => 0x33,
        5 => 0x37,
        6 => 0x3F,
        7 => 0x13F,
        8 => 0x63F,
        // L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr (7.1.4).
        12 => 0x2D63F,
        else => if (channels <= 18) (@as(u32, 1) << @as(u5, @intCast(channels))) - 1 else 0,
    };
}

/// The `dwChannelMask` of a WAVE_FORMAT_EXTENSIBLE file (null for plain PCM/float headers).
pub fn readChannelMask(b: []const u8) ?u32 {
    if (!isWav(b)) return null;
    var pos: usize = 12;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const id = pcm.tag(b, pos) orelse return null;
        const size: usize = pcm.leU32(b, pos + 4) orelse return null;
        if (std.mem.eql(u8, &id, "fmt ")) {
            const t = pcm.leU16(b, pos + 8) orelse return null;
            if (t != WAVE_FORMAT_EXTENSIBLE) return null;
            return pcm.leU32(b, pos + 8 + 20);
        }
        pos = std.math.add(usize, pos, 8) catch return null;
        pos = std.math.add(usize, pos, size) catch return null;
        pos = std.math.add(usize, pos, size & 1) catch return null;
    }
    return null;
}

/// Little-endian bytes of an integer.
fn leBytes(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .little);
    return out;
}

/// A fixed-capacity byte buffer for building headers without allocating.
const Header = struct {
    bytes: [HEADER_MAX]u8 = undefined,
    len: usize = 0,

    fn put(self: *Header, s: []const u8) void {
        @memcpy(self.bytes[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn u16le(self: *Header, v: u16) void {
        self.put(&leBytes(u16, v));
    }

    fn u32le(self: *Header, v: u32) void {
        self.put(&leBytes(u32, v));
    }

    fn u64le(self: *Header, v: u64) void {
        self.put(&leBytes(u64, v));
    }

    fn zeros(self: *Header, n: usize) void {
        @memset(self.bytes[self.len..][0..n], 0);
        self.len += n;
    }

    fn slice(self: *const Header) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Appends a RIFF chunk: id, size, body, and a pad byte after an odd body.
fn pushChunk(out: *Header, id: *const [4]u8, body: []const u8) void {
    out.put(id);
    out.u32le(std.math.cast(u32, body.len) orelse std.math.maxInt(u32));
    out.put(body);
    if (body.len % 2 == 1) out.zeros(1);
}

/// A fixed-width, NUL-padded string field; a cut that would split a UTF-8 sequence backs off.
fn putFixedStr(out: *Header, s: []const u8, len: usize) void {
    var n = @min(s.len, len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    out.put(s[0..n]);
    out.zeros(len - n);
}

/// The 602-byte `bext` body (version 1, no coding history).
fn bextBody(out: *Header, bwf: types.BwfInfo) void {
    putFixedStr(out, bwf.description, 256);
    putFixedStr(out, bwf.originator, 32);
    putFixedStr(out, bwf.originator_reference, 32);
    putFixedStr(out, bwf.origination_date, 10);
    putFixedStr(out, bwf.origination_time, 8);
    out.u32le(@truncate(bwf.time_reference));
    out.u32le(@truncate(bwf.time_reference >> 32));
    out.u16le(1); // version 1
    out.zeros(BEXT_MIN_LEN - out.len); // UMID, loudness, reserved; no coding history
}

/// Everything before the sample data of a WAV holding `frames` frames.
fn header(
    channels: usize,
    sample_rate: u32,
    format: pcm.SampleBits,
    bwf: ?types.BwfInfo,
    mask: ?u32,
    frames: u64,
    force_rf64: bool,
) AudioError!Header {
    const bits = format.bits;
    const block = std.math.mul(usize, @as(usize, bits / 8), channels) catch return error.TooLarge;
    const block_align = std.math.cast(u16, block) orelse return error.Encode;
    const data_len = std.math.mul(u64, @as(u64, block_align), frames) catch return error.TooLarge;
    const extensible = channels > 2 or bits > 16 or (if (mask) |m| m != channelMask(channels) else false);
    const fmt_tag: u16 = if (format.is_float) WAVE_FORMAT_IEEE_FLOAT else WAVE_FORMAT_PCM;
    const channels16 = std.math.cast(u16, channels) orelse return error.Encode;

    var fmt: Header = .{};
    fmt.u16le(if (extensible) WAVE_FORMAT_EXTENSIBLE else fmt_tag);
    fmt.u16le(channels16);
    fmt.u32le(sample_rate);
    fmt.u32le(sample_rate *| @as(u32, block_align));
    fmt.u16le(block_align);
    fmt.u16le(bits);
    if (extensible) {
        fmt.u16le(22);
        fmt.u16le(bits);
        fmt.u32le(mask orelse channelMask(channels));
        fmt.u16le(fmt_tag);
        fmt.put(&GUID_TAIL);
    }

    var meta: Header = .{};
    if (bwf) |info| {
        var bext: Header = .{};
        bextBody(&bext, info);
        pushChunk(&meta, "bext", bext.slice());
    }
    pushChunk(&meta, "fmt ", fmt.slice());
    if (format.is_float) {
        const fact = leBytes(u32, std.math.cast(u32, frames) orelse std.math.maxInt(u32));
        pushChunk(&meta, "fact", &fact);
    }

    const rf64_body_len: u64 = 28;
    const framing: u64 = 4 + (8 + rf64_body_len) + @as(u64, meta.len) + 8;
    const total = std.math.add(u64, framing, data_len) catch return error.TooLarge;
    const total_padded = std.math.add(u64, total, data_len & 1) catch return error.TooLarge;
    const rf64 = force_rf64 or std.math.cast(u32, total_padded) == null;

    var head: Header = .{};
    if (rf64) {
        head.put("RF64");
        head.u32le(std.math.maxInt(u32));
        head.put("WAVE");
        var ds64: Header = .{};
        ds64.u64le(total_padded);
        ds64.u64le(data_len);
        ds64.u64le(frames);
        ds64.u32le(0);
        pushChunk(&head, "ds64", ds64.slice());
    } else {
        head.put("RIFF");
        head.u32le(@truncate(total_padded));
        head.put("WAVE");
        // Reserve room for ds64 as JUNK, so a later writer could upgrade in place.
        var junk: Header = .{};
        junk.zeros(28);
        pushChunk(&head, "JUNK", junk.slice());
    }
    head.put(meta.slice());
    head.put("data");
    head.u32le(if (rf64) std.math.maxInt(u32) else @truncate(data_len));
    return head;
}

/// The header of a 32-bit float WAV holding `frames` frames (little-endian samples follow it).
/// Its length does not depend on `frames`, so a recorder can rewrite it in place as the file
/// grows; it switches to RF64 above 4 GiB. The caller frees the result with `gpa`.
pub fn floatHeader(gpa: std.mem.Allocator, channels: usize, sample_rate: u32, frames: u64) AudioError![]u8 {
    if (channels == 0 or sample_rate == 0) return error.Encode;
    const head = try header(channels, sample_rate, .{ .bits = 32, .is_float = true }, null, null, frames, false);
    return gpa.dupe(u8, head.slice());
}

/// Optional header parts of a WAV file: BWF metadata, speaker mask, and whether to force RF64.
/// The BWF strings are borrowed; the caller keeps them alive while the writer lives.
pub const HeaderExtras = struct {
    bwf: ?types.BwfInfo = null,
    mask: ?u32 = null,
    force_rf64: bool = false,
};

/// A WAV written block by block: a placeholder header first, then the real one (the same length,
/// RF64 above 4 GiB, or always when `force_rf64`) written over it by `finish`.
///
/// `W` is a pointer to a sink with `writeAll(bytes) !void`, `position() u64`, `seekTo(pos) !void`
/// and `flush() !void`. A sink writing to a file or a buffer implements those four methods.
/// The writer keeps the sink's position as its start, so the sink must already hold any bytes the
/// caller wrote before it.
pub fn Writer(comptime W: type) type {
    comptime {
        if (@typeInfo(W) != .pointer) @compileError("wav.Writer: W must be a pointer to a sink");
    }
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        out: W,
        start: u64,
        channels: usize,
        sample_rate: u32,
        format: pcm.SampleBits,
        bwf: ?types.BwfInfo,
        mask: ?u32,
        force_rf64: bool,
        quantizers: []pcm.Quantizer,
        frames: u64,
        scratch: []u8,
        /// Set when a block write has failed: the sink may hold a prefix of that block while
        /// `frames` does not count it, so the writer refuses every later call.
        failed: bool,

        /// Writes the placeholder header and makes the buffers the writer needs. Every block
        /// written afterwards reuses them.
        pub fn init(
            gpa: std.mem.Allocator,
            out: W,
            channels: usize,
            sample_rate: u32,
            depth: types.BitDepth,
            dither: bool,
            extras: HeaderExtras,
        ) AudioError!Self {
            try pcm.validateLayout(channels, sample_rate);
            const format = pcm.sampleFormat(depth);
            const frame_bytes = @as(usize, format.bits / 8) * channels;
            const quantizers = try pcm.Quantizer.perChannel(gpa, format.bits, dither, channels);
            errdefer gpa.free(quantizers);
            const scratch = try gpa.alloc(u8, @max(frame_bytes, SCRATCH_BYTES));
            errdefer gpa.free(scratch);

            var self: Self = .{
                .gpa = gpa,
                .out = out,
                .start = 0,
                .channels = channels,
                .sample_rate = sample_rate,
                .format = format,
                .bwf = extras.bwf,
                .mask = extras.mask,
                .force_rf64 = extras.force_rf64,
                .quantizers = quantizers,
                .frames = 0,
                .scratch = scratch,
                .failed = false,
            };
            self.start = self.out.position();
            const head = try self.headerFor(0);
            self.out.writeAll(head.slice()) catch return error.Io;
            return self;
        }

        /// Frees the writer's buffers. Safe to call after `finish`, and more than once.
        pub fn deinit(self: *Self) void {
            self.releaseBuffers();
        }

        fn releaseBuffers(self: *Self) void {
            self.gpa.free(self.quantizers);
            self.quantizers = &.{};
            self.gpa.free(self.scratch);
            self.scratch = &.{};
        }

        fn headerFor(self: *const Self, frames: u64) AudioError!Header {
            return header(self.channels, self.sample_rate, self.format, self.bwf, self.mask, frames, self.force_rf64);
        }

        /// The frame count after `frames` more (RF64 has room for any bounce).
        pub fn checkRoom(self: *const Self, frames: u64) AudioError!u64 {
            const total = self.frames +| frames;
            _ = try self.headerFor(total);
            return total;
        }

        /// Appends `frames` frames of planar audio (missing samples are silence).
        pub fn write(self: *Self, block: []const []const f32, frames: usize) AudioError!void {
            if (self.failed) return error.Encode;
            const total = try self.checkRoom(@intCast(frames));
            pcm.writeInterleaved(self.out, self.scratch, block, frames, self.quantizers, self.format, false) catch |e| {
                self.failed = true;
                return if (e == error.Encode) error.Encode else error.Io;
            };
            self.frames = total;
        }

        /// Writes the real header over the placeholder, then returns the sink positioned at the
        /// end of the data. Consumes the writer's buffers, also on error.
        pub fn finish(self: *Self) AudioError!W {
            defer self.releaseBuffers();
            if (self.failed) return error.Encode;
            const data_len = (@as(u64, self.format.bits / 8) *| @as(u64, self.channels)) *| self.frames;
            if (data_len % 2 == 1) self.out.writeAll(&.{0}) catch return error.Io;
            const head = try self.headerFor(self.frames);
            const end = self.out.position();
            self.out.seekTo(self.start) catch return error.Io;
            self.out.writeAll(head.slice()) catch return error.Io;
            self.out.seekTo(end) catch return error.Io;
            self.out.flush() catch return error.Io;
            return self.out;
        }
    };
}

/// An in-memory sink: a growable byte buffer with a position, for `encode` and the tests.
pub const MemSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    pub fn deinit(self: *MemSink) void {
        self.bytes.deinit(self.gpa);
    }

    pub fn position(self: *const MemSink) u64 {
        return self.pos;
    }

    pub fn seekTo(self: *MemSink, pos: u64) !void {
        self.pos = std.math.cast(usize, pos) orelse return error.Io;
    }

    pub fn writeAll(self: *MemSink, data: []const u8) !void {
        const end = self.pos + data.len;
        if (end > self.bytes.items.len) {
            const old = self.bytes.items.len;
            try self.bytes.resize(self.gpa, end);
            @memset(self.bytes.items[old..], 0);
        }
        @memcpy(self.bytes.items[self.pos..end], data);
        self.pos = end;
    }

    pub fn flush(_: *MemSink) !void {}
};

/// Encodes a WAV file. `force_rf64` writes the RF64 layout even for small files (for tests);
/// it is used automatically when the file would exceed 4 GiB. `mask` overrides the speaker mask
/// derived from the channel count. Caller frees the result with `gpa`.
pub fn encode(
    gpa: std.mem.Allocator,
    buf: *const AudioBuffer,
    depth: types.BitDepth,
    dither: bool,
    bwf: ?types.BwfInfo,
    force_rf64: bool,
    mask: ?u32,
) AudioError![]u8 {
    try pcm.validateBuffer(buf);
    const channels = buf.channels.len;
    const frames = buf.frames();
    const format = pcm.sampleFormat(depth);
    const head = try header(channels, buf.sample_rate, format, bwf, mask, @intCast(frames), force_rf64);
    const bytes_per_frame = std.math.mul(usize, @as(usize, format.bits / 8), channels) catch return error.TooLarge;
    const data_len = std.math.mul(usize, bytes_per_frame, frames) catch return error.TooLarge;

    var sink: MemSink = .{ .gpa = gpa };
    errdefer sink.deinit();
    const reserve = std.math.add(usize, data_len, head.len + 1) catch return error.TooLarge;
    sink.bytes.ensureTotalCapacity(gpa, reserve) catch return error.TooLarge;

    const planes = try gpa.alloc([]const f32, channels);
    defer gpa.free(planes);
    for (buf.channels, planes) |src, *dst| dst.* = src;

    var w = try Writer(*MemSink).init(gpa, &sink, channels, buf.sample_rate, depth, dither, .{
        .bwf = bwf,
        .mask = mask,
        .force_rf64 = force_rf64,
    });
    errdefer w.deinit();
    try w.write(planes, frames);
    _ = try w.finish();
    return sink.bytes.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Allocator = std.mem.Allocator;

const ZERO4: [4]u8 = @splat(0);
const ZERO8: [8]u8 = @splat(0);
const ZERO16: [16]u8 = @splat(0);
const ZERO_602: [602]u8 = @splat(0);
const TEN_80: [10]u8 = @splat(0x80);
const D5_800: [800]u8 = @splat(0xD5);

/// A RIFF chunk: id, little-endian size, body, and the pad byte after an odd body.
fn chunk(a: Allocator, id: *const [4]u8, body: []const u8) ![]u8 {
    const size = leBytes(u32, @intCast(body.len));
    const pad: []const u8 = if (body.len % 2 == 1) &.{0} else &.{};
    return std.mem.concat(a, u8, &.{ id, &size, body, pad });
}

/// A RIFF file from a complete body (everything after the RIFF size field, starting with WAVE).
fn riffRaw(a: Allocator, body: []const u8) ![]u8 {
    const size = leBytes(u32, @intCast(body.len));
    return std.mem.concat(a, u8, &.{ "RIFF", &size, body });
}

/// A finished RIFF/WAVE file of the given complete chunks, with the right RIFF size.
fn riffOf(a: Allocator, parts: []const []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "WAVE");
    for (parts) |p| try body.appendSlice(a, p);
    return riffRaw(a, body.items);
}

/// The 16-byte `fmt ` body of a plain format (no extension).
fn fmtBody(a: Allocator, tag: u16, channels: u16, sr: u32, bits: u16) ![]u8 {
    const align_bytes = channels * ((bits + 7) / 8);
    var f: std.ArrayList(u8) = .empty;
    try f.appendSlice(a, &leBytes(u16, tag));
    try f.appendSlice(a, &leBytes(u16, channels));
    try f.appendSlice(a, &leBytes(u32, sr));
    try f.appendSlice(a, &leBytes(u32, sr * @as(u32, align_bytes)));
    try f.appendSlice(a, &leBytes(u16, align_bytes));
    try f.appendSlice(a, &leBytes(u16, bits));
    return f.items;
}

/// An extensible `fmt ` body: cbSize, valid bits, mask, then the 16-byte subtype GUID.
fn extensibleFmt(a: Allocator, cb_size: u16, valid_bits: u16, guid: []const u8) ![]u8 {
    var f: std.ArrayList(u8) = .empty;
    try f.appendSlice(a, try fmtBody(a, 0xFFFE, 1, 44_100, 16));
    try f.appendSlice(a, &leBytes(u16, cb_size));
    try f.appendSlice(a, &leBytes(u16, valid_bits));
    try f.appendSlice(a, &leBytes(u32, 4));
    try f.appendSlice(a, guid);
    return f.items;
}

/// A `LIST` chunk of one INFO entry, INAM = "Silence".
fn listInfo(a: Allocator) ![]u8 {
    const inam = try chunk(a, "INAM", "Silence");
    const body = try std.mem.concat(a, u8, &.{ "INFO", inam });
    return chunk(a, "LIST", body);
}

/// A mono/stereo PCM WAV of 300 frames of a sine, as `encode` writes it.
fn small(gpa: Allocator, depth: types.BitDepth, channels: usize) ![]u8 {
    var b = try AudioBuffer.init(gpa, 44_100, channels, 300);
    defer b.deinit();
    for (b.channels) |ch| {
        for (ch, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    }
    return encode(gpa, &b, depth, false, null, false, null);
}

const Decoded = struct {
    info: types.AudioInfo,
    buf: AudioBuffer,
};

/// Parse and decode a WAV that must be read natively (the probe + decode of the Rust tests).
fn decodeNative(gpa: Allocator, b: []const u8) !Decoded {
    const layout = switch (try parse(b)) {
        .native => |l| l,
        .foreign => return error.Unsupported,
    };
    return .{ .info = layout.info, .buf = try decode(gpa, b, layout) };
}

fn probeNative(b: []const u8) !types.AudioInfo {
    return switch (try parse(b)) {
        .native => |l| l.info,
        .foreign => error.Unsupported,
    };
}

fn isForeign(b: []const u8) !bool {
    return switch (try parse(b)) {
        .foreign => true,
        .native => false,
    };
}

test "an_empty_data_chunk_followed_by_metadata_has_no_frames" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const file = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 48_000, 16)),
        try chunk(a, "data", ""),
        try listInfo(a),
        try chunk(a, "bext", &ZERO_602),
    });
    const info = try probeNative(file);
    try testing.expectEqual(@as(u64, 0), info.frames); // the LIST and bext chunks are not samples
    var d = try decodeNative(gpa, file);
    defer d.buf.deinit();
    try testing.expectEqual(@as(u64, 0), d.info.frames);
    try testing.expectEqual(@as(usize, 0), d.buf.frames());

    // The same with the metadata first.
    const file2 = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 1, 44_100, 16)),
        try listInfo(a),
        try chunk(a, "data", ""),
    });
    try testing.expectEqual(@as(u64, 0), (try probeNative(file2)).frames);

    // And with a single trailing chunk of odd size and no pad byte at the very end.
    var file3 = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 1, 44_100, 16)),
        try chunk(a, "data", ""),
        try chunk(a, "note", "abc"),
    });
    file3 = file3[0 .. file3.len - 1];
    std.mem.writeInt(u32, file3[4..8], @intCast(file3.len - 8), .little);
    try testing.expectEqual(@as(u64, 0), (try probeNative(file3)).frames);
}

test "a_recording_that_was_never_finalised_still_gives_its_audio" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var samples: [800]u8 = undefined;
    for (0..400) |i| std.mem.writeInt(i16, samples[i * 2 ..][0..2], @intCast(i * 40), .little);

    // RIFF size and data size both left at 0, as a recorder writes them until it finishes.
    var file = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 48_000, 16)),
        try chunk(a, "data", ""),
    });
    file = try std.mem.concat(a, u8, &.{ file, &samples });
    std.mem.writeInt(u32, file[4..8], 0, .little);
    var d = try decodeNative(gpa, file);
    defer d.buf.deinit();
    try testing.expectEqual(@as(u64, 200), d.info.frames);
    try testing.expectEqual(@as(usize, 200), d.buf.frames());

    // Even if the RIFF size is the file's, audio that is not a run of chunks is still audio.
    file = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 48_000, 16)),
        try chunk(a, "data", ""),
    });
    file = try std.mem.concat(a, u8, &.{ file, &samples });
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);
    try testing.expectEqual(@as(u64, 200), (try probeNative(file)).frames);
}

test "a_data_chunk_with_audio_is_unchanged" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var samples: [200]u8 = undefined;
    for (0..100) |i| std.mem.writeInt(i16, samples[i * 2 ..][0..2], @intCast(i), .little);
    const file = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 1, 44_100, 16)),
        try chunk(a, "data", &samples),
        try listInfo(a),
    });
    try testing.expectEqual(@as(u64, 100), (try probeNative(file)).frames);
}

test "truncated_data_chunk_yields_partial_audio" {
    const gpa = testing.allocator;
    const file = try small(gpa, .int16, 2);
    defer gpa.free(file);
    var d = try decodeNative(gpa, file[0 .. file.len - 400]);
    defer d.buf.deinit();
    try testing.expectEqual(@as(u64, 200), d.info.frames);
    try testing.expectEqual(@as(usize, 200), d.buf.frames());
}

test "zero_channels_is_malformed" {
    // The WAV half of the Rust test; its AIFF half belongs to the AIFF unit.
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wav = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 0, 44_100, 16)),
        try chunk(a, "data", &ZERO16),
    });
    try testing.expectError(error.Malformed, parse(wav));
    try testing.expectError(error.Malformed, probeNative(wav));
}

test "zero_sample_rate_is_malformed" {
    // The WAV half of the Rust test; its AIFF half belongs to the AIFF unit.
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wav = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 0, 16)),
        try chunk(a, "data", &ZERO16),
    });
    try testing.expectError(error.Malformed, parse(wav));
}

test "absurd_chunk_sizes" {
    // The WAV parts of the Rust test; its AIFF COMM/SSND parts belong to the AIFF unit.
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // fmt chunk claims 4 GiB.
    var wav = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 44_100, 16)),
        try chunk(a, "data", &ZERO16),
    });
    std.mem.writeInt(u32, wav[16..20], std.math.maxInt(u32), .little);
    try testing.expectError(error.Malformed, decodeNative(gpa, wav));

    // data chunk claims 4 GiB: lenient read of what's there.
    var wav2 = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 44_100, 16)),
        try chunk(a, "data", &ZERO16),
    });
    const d_pos = std.mem.indexOf(u8, wav2, "data").?;
    std.mem.writeInt(u32, wav2[d_pos + 4 ..][0..4], std.math.maxInt(u32), .little);
    var d = try decodeNative(gpa, wav2);
    defer d.buf.deinit();
    try testing.expectEqual(@as(u64, 4), d.info.frames);
    try testing.expectEqual(@as(usize, 4), d.buf.frames());

    // An unknown chunk with an absurd size before fmt.
    var wav3 = try riffOf(a, &.{
        try chunk(a, "junk", &ZERO4),
        try chunk(a, "fmt ", try fmtBody(a, 1, 2, 44_100, 16)),
        try chunk(a, "data", &ZERO16),
    });
    std.mem.writeInt(u32, wav3[16..20], 0xFFFF_FFF0, .little);
    try testing.expectError(error.Malformed, decodeNative(gpa, wav3));

    // RF64 with a ds64 claiming an exabyte of data.
    const ds64 = try a.alloc(u8, 28);
    @memset(ds64[0..24], 0xFF);
    @memset(ds64[24..], 0);
    var rf = try riffOf(a, &.{
        try chunk(a, "ds64", ds64),
        try chunk(a, "fmt ", try fmtBody(a, 1, 1, 8_000, 8)),
        try chunk(a, "data", &TEN_80),
    });
    @memcpy(rf[0..4], "RF64");
    const rd = std.mem.lastIndexOf(u8, rf, "data").?;
    std.mem.writeInt(u32, rf[rd + 4 ..][0..4], std.math.maxInt(u32), .little);
    var rd_dec = try decodeNative(gpa, rf);
    defer rd_dec.buf.deinit();
    try testing.expectEqual(@as(u64, 10), rd_dec.info.frames);
    try testing.expectEqual(@as(usize, 10), rd_dec.buf.frames());
}

/// An A-law file (format 6, read by the foreign decoder) whose INFO list is `info_len` long.
fn alawFile(a: Allocator, info_len: u32) ![]u8 {
    const info = try std.mem.concat(a, u8, &.{ "INFO", "INAM", &leBytes(u32, info_len), "hi" });
    const fmt_body = try std.mem.concat(a, u8, &.{ try fmtBody(a, 6, 1, 8_000, 8), &leBytes(u16, 0) });
    return riffOf(a, &.{
        try chunk(a, "fmt ", fmt_body),
        try chunk(a, "LIST", info),
        try chunk(a, "data", &D5_800),
    });
}

test "wav_info_entries_beyond_the_file_are_refused" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The foreign decoder reads this file (800 frames in the Rust test); here its INFO check passes.
    const ok = try alawFile(a, 2);
    try checkInfo(ok, 0);
    try testing.expect(try isForeign(ok));

    var f = try alawFile(a, 0x7fff_fff0);
    std.mem.writeInt(u32, f[4..8], std.math.maxInt(u32), .little);
    const list = std.mem.indexOf(u8, f, "LIST").?;
    std.mem.writeInt(u32, f[list + 4 ..][0..4], 0x7fff_fffc, .little);
    try testing.expectError(error.Malformed, checkInfo(f, 0));
}

test "a_wave_behind_another_riff_form_is_checked" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const info = try std.mem.concat(a, u8, &.{ "INFO", "INAM", &leBytes(u32, 0x7fff_fff0), "hi" });
    const fmt_body = try std.mem.concat(a, u8, &.{ try fmtBody(a, 6, 1, 8_000, 8), &leBytes(u16, 0) });
    var wav = try riffOf(a, &.{
        try chunk(a, "fmt ", fmt_body),
        try chunk(a, "LIST", info),
        try chunk(a, "data", &D5_800),
    });
    std.mem.writeInt(u32, wav[4..8], std.math.maxInt(u32), .little);
    const list = std.mem.indexOf(u8, wav, "LIST").?;
    std.mem.writeInt(u32, wav[list + 4 ..][0..4], 0x7fff_fffc, .little);
    // The probe skips the AVI form and reads the WAVE behind it, whose RIFF header is at 12.
    const f = try std.mem.concat(a, u8, &.{ "RIFF", &leBytes(u32, 4), "AVI ", wav });
    try testing.expectError(error.Malformed, checkInfo(f, 12));
}

test "wav_info_entries_are_found_where_symphonia_reads_them" {
    // Same intent as the Rust test, without symphonia: the INFO walk must find the entries where
    // the foreign reader would read them, not where the chunk lengths say.
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try std.mem.concat(a, u8, &.{
        "LIST",
        &leBytes(u32, 0x7fff_fffc),
        "INFO",
        "INAM",
        &leBytes(u32, 0x7fff_fff0),
        "hi",
    });
    // A-law's extra bytes are read past its chunk; an odd list is padded twice.
    const alaw_fmt = struct {
        fn body(aa: Allocator, extra: u16) ![]u8 {
            return std.mem.concat(aa, u8, &.{ try fmtBody(aa, 6, 1, 8_000, 8), &leBytes(u16, extra) });
        }
    }.body;
    const file1 = try riffOf(a, &.{
        try chunk(a, "fmt ", try alaw_fmt(a, 12)),
        try chunk(a, "JUNK", try std.mem.concat(a, u8, &.{ &ZERO4, list })),
    });
    const file2_head = try riffOf(a, &.{
        try chunk(a, "fmt ", try alaw_fmt(a, 0)),
        try chunk(a, "LIST", "adtl\x00"),
    });
    const file2 = try std.mem.concat(a, u8, &.{ file2_head, &[_]u8{0}, list });

    for ([_][]u8{ file1, file2 }) |f| {
        std.mem.writeInt(u32, f[4..8], std.math.maxInt(u32), .little);
        try testing.expectError(error.Malformed, checkInfo(f, 0));
    }
}

test "many_tiny_chunks_terminate" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "WAVE");
    try body.appendSlice(a, try chunk(a, "fmt ", try fmtBody(a, 1, 1, 8_000, 16)));
    const pad_chunk = try chunk(a, "pad ", "");
    for (0..200_000) |_| try body.appendSlice(a, pad_chunk);
    const wav = try riffRaw(a, body.items);
    // No data chunk within the scan limit.
    try testing.expectError(error.Malformed, parse(wav));
}

test "hand_built_wav_variants" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 8-bit unsigned.
    const wav8 = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 1, 1, 8_000, 8)),
        try chunk(a, "data", &[_]u8{ 0x80, 0xFF, 0x00 }),
    });
    var d8 = try decodeNative(gpa, wav8);
    defer d8.buf.deinit();
    try testing.expectEqual(types.SampleFormat.int8, d8.info.sample_format);
    const want8 = [_]f32{ 0.0, 127.0 / 128.0, -1.0 };
    try testing.expectEqualSlices(f32, &want8, d8.buf.channels[0]);

    // 64-bit float, with NaN replaced by silence.
    var data64: [24]u8 = undefined;
    const vals = [_]f64{ 0.25, -0.5, std.math.nan(f64) };
    for (vals, 0..) |v, i| std.mem.writeInt(u64, data64[i * 8 ..][0..8], @bitCast(v), .little);
    const wav64 = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 3, 1, 8_000, 64)),
        try chunk(a, "data", &data64),
    });
    var d64 = try decodeNative(gpa, wav64);
    defer d64.buf.deinit();
    try testing.expectEqual(types.SampleFormat.float64, d64.info.sample_format);
    const want64 = [_]f32{ 0.25, -0.5, 0.0 };
    try testing.expectEqualSlices(f32, &want64, d64.buf.channels[0]);

    // Unsupported PCM width.
    const wav_bad = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 3, 1, 8_000, 16)),
        try chunk(a, "data", &[_]u8{ 0, 0, 0, 0 }),
    });
    try testing.expectError(error.Unsupported, parse(wav_bad));

    // No data chunk / no fmt chunk.
    try testing.expectError(error.Malformed, parse(try riffOf(a, &.{try chunk(a, "fmt ", try fmtBody(a, 1, 1, 8_000, 16))})));
    try testing.expectError(error.Malformed, parse(try riffOf(a, &.{try chunk(a, "data", &[_]u8{ 0, 0, 0, 0 })})));

    // Short fmt chunk.
    const short_fmt = try riffOf(a, &.{
        try chunk(a, "fmt ", &[_]u8{ 1, 0, 1 }),
        try chunk(a, "data", &[_]u8{ 0, 0, 0, 0 }),
    });
    try testing.expectError(error.Malformed, parse(short_fmt));

    // Unknown codec tag goes to the foreign decoder.
    const unknown = try riffOf(a, &.{
        try chunk(a, "fmt ", try fmtBody(a, 0x1234, 1, 8_000, 16)),
        try chunk(a, "data", &[_]u8{ 0, 0, 0, 0 }),
    });
    try testing.expect(try isForeign(unknown));
}

test "extensible_fmt_is_checked_in_full" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const pcm_guid = [_]u8{ 1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71 };

    const good = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 22, 16, &pcm_guid)),
        try chunk(a, "data", &ZERO8),
    });
    try testing.expectEqual(types.SampleFormat.int16, (try probeNative(good)).sample_format);

    // Subtype GUID cut short after the format code.
    const cut = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 22, 16, pcm_guid[0..4])),
        try chunk(a, "data", &ZERO8),
    });
    try testing.expectError(error.Malformed, parse(cut));
    try testing.expectError(error.Malformed, decodeNative(gpa, cut));

    // cbSize too small for the extension.
    const small_cb = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 0, 16, &pcm_guid)),
        try chunk(a, "data", &ZERO8),
    });
    try testing.expectError(error.Malformed, parse(small_cb));

    // More valid bits than the 16-bit container holds.
    const wide = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 22, 24, &pcm_guid)),
        try chunk(a, "data", &ZERO8),
    });
    try testing.expectError(error.Malformed, parse(wide));

    // PCM-like prefix but a foreign GUID tail is not read as native PCM.
    var foreign_guid = pcm_guid;
    foreign_guid[15] ^= 0xFF;
    const foreign = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 22, 16, &foreign_guid)),
        try chunk(a, "data", &ZERO8),
    });
    if (parse(foreign)) |p| {
        switch (p) {
            .native => |l| try testing.expect(l.info.sample_format != .int16),
            .foreign => {},
        }
    } else |_| {}

    // The Ambisonic PCM subtype is PCM.
    const ambi_guid = [_]u8{ 1, 0, 0, 0, 0x21, 0x07, 0xD3, 0x11, 0x86, 0x44, 0xC8, 0xC1, 0xCA, 0, 0, 0 };
    const ambi = try riffOf(a, &.{
        try chunk(a, "fmt ", try extensibleFmt(a, 22, 16, &ambi_guid)),
        try chunk(a, "data", &ZERO8),
    });
    try testing.expectEqual(types.SampleFormat.int16, (try probeNative(ambi)).sample_format);
}

test "encode output parses back with its layout and channel mask" {
    const gpa = testing.allocator;
    var b = try AudioBuffer.init(gpa, 48_000, 6, 16);
    defer b.deinit();
    const bytes = try encode(gpa, &b, .int24, false, null, false, null);
    defer gpa.free(bytes);
    const info = try probeNative(bytes);
    try testing.expectEqual(@as(u16, 6), info.channels);
    try testing.expectEqual(types.SampleFormat.int24, info.sample_format);
    try testing.expectEqual(@as(u64, 16), info.frames);
    try testing.expectEqual(@as(?u32, 0x3F), readChannelMask(bytes));
}

test "float32 round trips exactly, and RF64 is written when forced" {
    const gpa = testing.allocator;
    var b = try AudioBuffer.init(gpa, 48_000, 2, 3);
    defer b.deinit();
    const ch0 = [_]f32{ 0.25, -0.5, 1.0 };
    const ch1 = [_]f32{ 0.0, 0.75, -1.0 };
    @memcpy(b.channels[0], &ch0);
    @memcpy(b.channels[1], &ch1);

    const bytes = try encode(gpa, &b, .float32, false, null, false, null);
    defer gpa.free(bytes);
    var d = try decodeNative(gpa, bytes);
    defer d.buf.deinit();
    try testing.expectEqual(types.SampleFormat.float32, d.info.sample_format);
    try testing.expectEqualSlices(f32, &ch0, d.buf.channels[0]);
    try testing.expectEqualSlices(f32, &ch1, d.buf.channels[1]);

    const rf = try encode(gpa, &b, .int16, false, null, true, null);
    defer gpa.free(rf);
    try testing.expectEqualStrings("RF64", rf[0..4]);
    try testing.expectEqualStrings("ds64", rf[12..16]);
    try testing.expectEqual(@as(u64, 3), (try probeNative(rf)).frames);
}

test "streaming writer produces the same bytes as encode" {
    const gpa = testing.allocator;
    var b = try AudioBuffer.init(gpa, 44_100, 2, 300);
    defer b.deinit();
    for (b.channels) |ch| {
        for (ch, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    }
    const expected = try encode(gpa, &b, .int16, false, null, false, null);
    defer gpa.free(expected);

    var sink: MemSink = .{ .gpa = gpa };
    defer sink.deinit();
    var w = try Writer(*MemSink).init(gpa, &sink, 2, 44_100, .int16, false, .{});
    defer w.deinit();
    const first = [_][]const f32{ b.channels[0][0..150], b.channels[1][0..150] };
    const second = [_][]const f32{ b.channels[0][150..], b.channels[1][150..] };
    try w.write(&first, 150);
    try w.write(&second, 150);
    _ = try w.finish();
    try testing.expectEqualSlices(u8, expected, sink.bytes.items);
}
