//! SPA POD building for the PipeWire stream, by hand.
//!
//! SPA's builders (`spa_pod_builder_*`, `spa_format_audio_raw_build`) are static inline C, so
//! they are not in libpipewire and cannot be called from Zig. This builds the one POD the
//! engine needs: an `EnumFormat` object describing raw audio, laid out exactly as
//! `spa_format_audio_raw_build` lays it out (SPA 1.x wire format, native byte order):
//!
//!   pod     = u32 body size, u32 type, body, zero padding to 8 bytes
//!   object  = pod(type Object) { u32 object type, u32 id, property... }
//!   property= u32 key, u32 flags, pod
//!   array   = pod(type Array) { u32 child size, u32 child type, child values... }
//!
//! Constants are from spa/utils/type.h, spa/param/param.h, spa/param/format.h and
//! spa/param/audio/raw.h.

const std = @import("std");

pub const TYPE_ID: u32 = 3;
pub const TYPE_INT: u32 = 4;
pub const TYPE_ARRAY: u32 = 13;
pub const TYPE_OBJECT: u32 = 15;
pub const TYPE_OBJECT_FORMAT: u32 = 0x40003;

pub const PARAM_ENUM_FORMAT: u32 = 3;

pub const FORMAT_MEDIA_TYPE: u32 = 1;
pub const FORMAT_MEDIA_SUBTYPE: u32 = 2;
pub const FORMAT_AUDIO_FORMAT: u32 = 0x10001;
pub const FORMAT_AUDIO_RATE: u32 = 0x10003;
pub const FORMAT_AUDIO_CHANNELS: u32 = 0x10004;
pub const FORMAT_AUDIO_POSITION: u32 = 0x10005;

pub const MEDIA_TYPE_AUDIO: u32 = 1;
pub const MEDIA_SUBTYPE_RAW: u32 = 1;

/// SPA_AUDIO_FORMAT_F32 (native float; F32_LE on little-endian hosts).
pub const AUDIO_FORMAT_F32: u32 = 283;
pub const AUDIO_CHANNEL_MONO: u32 = 2;
pub const AUDIO_CHANNEL_FL: u32 = 3;
pub const AUDIO_CHANNEL_FR: u32 = 4;

/// SPA_AUDIO_MAX_CHANNELS: positions beyond this are not described.
pub const AUDIO_MAX_CHANNELS = 64;

comptime {
    // The wire format below is little-endian, like every host the engine builds for.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

/// Raw audio description (the fields of `spa_audio_info_raw` that the builder reads).
pub const AudioInfoRaw = struct {
    format: u32,
    rate: u32,
    channels: u32,
    /// Channel positions; null means unpositioned (SPA_AUDIO_FLAG_UNPOSITIONED): none are sent.
    positions: ?[]const u32,
};

pub const Error = error{
    /// The output buffer cannot hold the POD.
    NoSpace,
    /// More positions given than channels, or more than SPA can describe.
    InvalidPositions,
};

/// Appends little-endian words to a fixed buffer.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn word(self: *Writer, value: u32) Error!void {
        if (self.len + 4 > self.buf.len) return Error.NoSpace;
        std.mem.writeInt(u32, self.buf[self.len..][0..4], value, .little);
        self.len += 4;
    }

    /// Zero padding up to the next 8-byte boundary.
    fn pad(self: *Writer) Error!void {
        while (self.len % 8 != 0) {
            if (self.len >= self.buf.len) return Error.NoSpace;
            self.buf[self.len] = 0;
            self.len += 1;
        }
    }

    /// Property `key` holding a 4-byte scalar pod (Id or Int).
    fn scalarProperty(self: *Writer, key: u32, pod_type: u32, value: u32) Error!void {
        try self.word(key);
        try self.word(0); // property flags
        try self.word(4); // body size
        try self.word(pod_type);
        try self.word(value);
        try self.pad();
    }
};

/// Builds the `id` (e.g. `PARAM_ENUM_FORMAT`) Format object for `info` into `buf` and returns
/// the POD bytes (a prefix of `buf`, 8-byte aligned in size). Byte-for-byte what
/// `spa_format_audio_raw_build` produces for the same description.
pub fn buildAudioRawFormat(buf: []u8, id: u32, info: AudioInfoRaw) Error![]const u8 {
    if (info.positions) |positions| {
        if (positions.len != info.channels or positions.len > AUDIO_MAX_CHANNELS) return Error.InvalidPositions;
    }
    var w: Writer = .{ .buf = buf };
    try w.word(0); // object body size, patched below
    try w.word(TYPE_OBJECT);
    try w.word(TYPE_OBJECT_FORMAT);
    try w.word(id);
    try w.scalarProperty(FORMAT_MEDIA_TYPE, TYPE_ID, MEDIA_TYPE_AUDIO);
    try w.scalarProperty(FORMAT_MEDIA_SUBTYPE, TYPE_ID, MEDIA_SUBTYPE_RAW);
    if (info.format != 0) try w.scalarProperty(FORMAT_AUDIO_FORMAT, TYPE_ID, info.format);
    if (info.rate != 0) try w.scalarProperty(FORMAT_AUDIO_RATE, TYPE_INT, info.rate);
    if (info.channels != 0) {
        try w.scalarProperty(FORMAT_AUDIO_CHANNELS, TYPE_INT, info.channels);
        if (info.positions) |positions| {
            try w.word(FORMAT_AUDIO_POSITION);
            try w.word(0); // property flags
            try w.word(@intCast(8 + 4 * positions.len)); // array body: child header + values
            try w.word(TYPE_ARRAY);
            try w.word(4); // child size
            try w.word(TYPE_ID); // child type
            for (positions) |p| try w.word(p);
            try w.pad();
        }
    }
    // The object's body size excludes its own 8-byte header; it is already a multiple of 8.
    std.mem.writeInt(u32, buf[0..4], @intCast(w.len - 8), .little);
    return buf[0..w.len];
}

/// Positions SPA uses for a channel count: FL/FR for stereo, MONO for mono, and unpositioned
/// otherwise (the same choice the old C stream made).
pub fn defaultPositions(channels: u32) ?[]const u32 {
    return switch (channels) {
        1 => &[_]u32{AUDIO_CHANNEL_MONO},
        2 => &[_]u32{ AUDIO_CHANNEL_FL, AUDIO_CHANNEL_FR },
        else => null,
    };
}

test "spa_pod: rejects mismatched positions and short buffers" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(Error.InvalidPositions, buildAudioRawFormat(&buf, PARAM_ENUM_FORMAT, .{
        .format = AUDIO_FORMAT_F32,
        .rate = 48000,
        .channels = 3,
        .positions = &[_]u32{ AUDIO_CHANNEL_FL, AUDIO_CHANNEL_FR },
    }));
    var tiny: [40]u8 = undefined;
    try std.testing.expectError(Error.NoSpace, buildAudioRawFormat(&tiny, PARAM_ENUM_FORMAT, .{
        .format = AUDIO_FORMAT_F32,
        .rate = 48000,
        .channels = 2,
        .positions = defaultPositions(2),
    }));
}

test "spa_pod: stereo F32 48 kHz EnumFormat is byte-identical to SPA's C builder" {
    // Words captured from spa_format_audio_raw_build (pipewire 1.6.9) for exactly this
    // description, before pw_stream.c was removed (see the commit that added this builder,
    // where both were compiled and compared for stereo, mono, 6, 64 and 0 channels).
    const expected = [_]u32{
        0x000000a0, 0x0000000f, 0x00040003, 0x00000003, 0x00000001, 0x00000000, 0x00000004, 0x00000003,
        0x00000001, 0x00000000, 0x00000002, 0x00000000, 0x00000004, 0x00000003, 0x00000001, 0x00000000,
        0x00010001, 0x00000000, 0x00000004, 0x00000003, 0x0000011b, 0x00000000, 0x00010003, 0x00000000,
        0x00000004, 0x00000004, 0x0000bb80, 0x00000000, 0x00010004, 0x00000000, 0x00000004, 0x00000004,
        0x00000002, 0x00000000, 0x00010005, 0x00000000, 0x00000010, 0x0000000d, 0x00000004, 0x00000003,
        0x00000003, 0x00000004,
    };
    var buf: [1024]u8 = undefined;
    const pod = try buildAudioRawFormat(&buf, PARAM_ENUM_FORMAT, .{
        .format = AUDIO_FORMAT_F32,
        .rate = 48000,
        .channels = 2,
        .positions = defaultPositions(2),
    });
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), pod);
}
