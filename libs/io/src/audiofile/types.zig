// Translated to Zig from soundcraft/crates/audio-io/src/lib.rs (lines 1-300), soundcraft/crates/audio-io/tests/it/file_format.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Audio file types: the error set, container formats and their extension tables, sample
//! formats, BWF metadata, probe results and encode options. No I/O and no parsing here; the
//! readers and writers that use these types live in the other audiofile files.

const std = @import("std");
const testing = std.testing;

/// Errors from probing, decoding and encoding. The Rust enum carried a message per variant;
/// a Zig error set carries only the kind, so the message is not kept (see the translation notes).
pub const AudioError = error{
    /// The format, codec or option is valid but not supported.
    Unsupported,
    /// The input is corrupt or not what it claims to be.
    Malformed,
    /// The input (or requested output) exceeds a size limit.
    TooLarge,
    /// Encoding failed (for example an empty buffer).
    Encode,
    /// Writing the output failed.
    Io,
    /// An allocation failed.
    OutOfMemory,
};

/// Container / codec family of an audio file.
pub const FileFormat = enum {
    wav,
    aiff,
    flac,
    mp3,
    ogg,
    aac,
    alac,
    caf,
    /// Any other container the codec layer reads: Matroska and WebM by name.
    other,

    /// The formats `decode` reads, found by extension. Contents decide when they disagree.
    pub const read_formats: []const FileFormat = &.{ .wav, .aiff, .flac, .mp3, .ogg, .aac, .caf, .other };
    /// The formats `encode` writes.
    pub const write_formats: []const FileFormat = &.{ .wav, .aiff, .flac };

    /// The extensions that name this format, lower case and without the dot; the first is the
    /// one a new file gets. ALAC shares AAC's MP4 container, so a `.m4a` name reads as AAC until
    /// the contents say otherwise.
    pub fn extensions(self: FileFormat) []const []const u8 {
        return switch (self) {
            .wav => &.{ "wav", "wave", "bwf", "rf64" },
            .aiff => &.{ "aif", "aiff", "aifc" },
            .flac => &.{"flac"},
            .mp3 => &.{ "mp3", "mp2", "mp1" },
            .ogg => &.{ "ogg", "oga" },
            .aac => &.{ "m4a", "m4b", "aac", "mp4", "adts" },
            .alac => &.{"m4a"},
            .caf => &.{"caf"},
            .other => &.{ "mkv", "webm" },
        };
    }

    /// The name people know the format by, as menus show it.
    pub fn name(self: FileFormat) []const u8 {
        return switch (self) {
            .wav => "WAV",
            .aiff => "AIFF",
            .flac => "FLAC",
            .mp3 => "MP3",
            .ogg => "Ogg Vorbis",
            .aac => "AAC",
            .alac => "ALAC",
            .caf => "CAF",
            .other => "Other",
        };
    }

    /// The media type a file of this format is served or downloaded as.
    pub fn mimeType(self: FileFormat) []const u8 {
        return switch (self) {
            .wav => "audio/wav",
            .aiff => "audio/aiff",
            .flac => "audio/flac",
            .mp3 => "audio/mpeg",
            .ogg => "audio/ogg",
            .aac, .alac => "audio/mp4",
            .caf => "audio/x-caf",
            .other => "application/octet-stream",
        };
    }

    /// The extension a new file of this format gets.
    pub fn defaultExtension(self: FileFormat) []const u8 {
        const exts = self.extensions();
        return if (exts.len > 0) exts[0] else "bin";
    }

    /// The readable format an extension or format name names (`wav`, `.AIFF`; ASCII
    /// case-insensitive), or null when nothing reads it.
    pub fn fromExtension(ext: []const u8) ?FileFormat {
        const e = std.mem.trimStart(u8, ext, ".");
        for (read_formats) |f| {
            for (f.extensions()) |x| {
                if (std.ascii.eqlIgnoreCase(x, e)) return f;
            }
        }
        return null;
    }

    /// The readable format the extension of `path` names, or null without a known extension.
    /// Only the last path component counts; a leading dot (`.wav`) is not an extension.
    pub fn fromPath(path: []const u8) ?FileFormat {
        var trimmed = path;
        while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        const base = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        if (dot == 0) return null;
        return fromExtension(base[dot + 1 ..]);
    }

    /// The extensions `encode` writes this format under: the names whose readers expect what it
    /// writes. RF64 and AIFF-C names are left out because `encode` writes plain RIFF and AIFF
    /// headers for them.
    pub fn writeExtensions(self: FileFormat) []const []const u8 {
        return switch (self) {
            .wav => &.{ "wav", "wave", "bwf" },
            .aiff => &.{ "aif", "aiff" },
            .flac => &.{"flac"},
            else => &.{},
        };
    }

    /// The format `encode` writes for an extension or format name (ASCII case-insensitive), or
    /// null when it writes none.
    pub fn fromWriteExtension(ext: []const u8) ?FileFormat {
        const e = std.mem.trimStart(u8, ext, ".");
        for (write_formats) |f| {
            for (f.writeExtensions()) |x| {
                if (std.ascii.eqlIgnoreCase(x, e)) return f;
            }
        }
        return null;
    }

    /// Every extension of `read_formats`, in order: what file pickers and browsers filter by.
    pub fn readableExtensions() []const []const u8 {
        return readable_list;
    }

    /// Every extension of `write_formats`, in order: what save dialogs, help and errors list.
    pub fn writableExtensions() []const []const u8 {
        return writable_list;
    }
};

/// Flattens the extension lists of `formats` at compile time (`write` selects the write lists).
fn collectExtensions(comptime formats: []const FileFormat, comptime write: bool) []const []const u8 {
    comptime {
        var n: usize = 0;
        for (formats) |f| n += if (write) f.writeExtensions().len else f.extensions().len;
        var out: [n][]const u8 = undefined;
        var i: usize = 0;
        for (formats) |f| {
            const exts = if (write) f.writeExtensions() else f.extensions();
            for (exts) |e| {
                out[i] = e;
                i += 1;
            }
        }
        const final = out;
        return &final;
    }
}

const readable_list = collectExtensions(FileFormat.read_formats, false);
const writable_list = collectExtensions(FileFormat.write_formats, true);

/// Stored sample representation.
pub const SampleFormat = enum {
    int8,
    int16,
    int24,
    int32,
    float32,
    float64,
    /// A lossy codec (MP3, AAC, Vorbis, ...): no fixed bit depth.
    compressed,
};

/// Broadcast Wave (`bext`) metadata. The strings are borrowed: the owner of the containing
/// memory keeps them alive.
pub const BwfInfo = struct {
    description: []const u8 = "",
    originator: []const u8 = "",
    originator_reference: []const u8 = "",
    /// `yyyy-mm-dd`.
    origination_date: []const u8 = "",
    /// `hh:mm:ss`.
    origination_time: []const u8 = "",
    /// Sample count since midnight of the first sample (the timestamp Pro Tools spots to).
    time_reference: u64 = 0,
};

/// What probing learns about a file without decoding all of it.
pub const AudioInfo = struct {
    format: FileFormat,
    sample_format: SampleFormat,
    sample_rate: u32,
    channels: u16,
    frames: u64,
    bwf: ?BwfInfo = null,

    /// Duration in seconds (0 when the sample rate is 0).
    pub fn durationSecs(self: AudioInfo) f64 {
        if (self.sample_rate == 0) return 0.0;
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Bit depth for `encode`.
pub const BitDepth = enum {
    int16,
    int24,
    int32,
    /// Preserve finite samples, including values above full scale; map NaN to 0 and
    /// infinities to +-1.
    float32,
};

/// Options for `encode`.
pub const EncodeOptions = struct {
    /// `wav`, `aiff` or `flac`; anything else is `error.Unsupported`.
    format: FileFormat = .wav,
    bit_depth: BitDepth = .int24,
    /// Add TPDF dither when quantizing to an integer depth.
    dither: bool = false,
    /// Write a BWF `bext` chunk (WAV only; ignored for other formats).
    bwf: ?BwfInfo = null,
};

test "every_read_and_write_format_round_trips_through_its_extensions" {
    for (FileFormat.read_formats) |format| {
        try testing.expect(format.extensions().len > 0);
        for (format.extensions()) |ext| {
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromExtension(ext));

            var upper_buf: [32]u8 = undefined;
            upper_buf[0] = '.';
            const upper = std.ascii.upperString(upper_buf[1..], ext);
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromExtension(upper_buf[0 .. upper.len + 1]));

            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "dir.x/Take 1.{s}", .{ext});
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromPath(path));
        }
    }
    for (FileFormat.write_formats) |format| {
        try testing.expect(format.writeExtensions().len > 0);
        for (format.writeExtensions()) |ext| {
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromWriteExtension(ext));

            var upper_buf: [32]u8 = undefined;
            const upper = std.ascii.upperString(&upper_buf, ext);
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromWriteExtension(upper));
            // What is written reads back.
            try testing.expectEqual(@as(?FileFormat, format), FileFormat.fromExtension(ext));
        }
        var contains_default = false;
        for (format.writeExtensions()) |ext| {
            if (std.mem.eql(u8, ext, format.defaultExtension())) contains_default = true;
        }
        try testing.expect(contains_default);
    }
}

test "only_names_whose_readers_expect_the_encoder_output_are_writable" {
    try testing.expectEqualSlices(
        []const u8,
        &.{ "wav", "wave", "bwf", "aif", "aiff", "flac" },
        FileFormat.writableExtensions(),
    );
    for ([_][]const u8{ "rf64", "aifc", "mp3", "ogg", "m4a", "mkv" }) |read_only| {
        try testing.expect(FileFormat.fromExtension(read_only) != null);
        try testing.expectEqual(@as(?FileFormat, null), FileFormat.fromWriteExtension(read_only));
    }
    for ([_][]const u8{ "xyz", "", "mid" }) |unknown| {
        try testing.expectEqual(@as(?FileFormat, null), FileFormat.fromExtension(unknown));
    }
    try testing.expectEqual(@as(?FileFormat, null), FileFormat.fromPath("no-extension"));
    try testing.expectEqualStrings("aif", FileFormat.aiff.defaultExtension());
}

test "readable extension list follows READ order and ALAC is not a read format" {
    try testing.expectEqualStrings("wav", FileFormat.readableExtensions()[0]);
    try testing.expectEqual(@as(?FileFormat, .aac), FileFormat.fromExtension("m4a"));
    try testing.expectEqual(@as(?FileFormat, .other), FileFormat.fromExtension(".WEBM"));
}

test "fromPath uses only the last component and ignores a leading dot" {
    try testing.expectEqual(@as(?FileFormat, .flac), FileFormat.fromPath("/a.b/c.FLAC"));
    try testing.expectEqual(@as(?FileFormat, null), FileFormat.fromPath(".wav"));
    try testing.expectEqual(@as(?FileFormat, null), FileFormat.fromPath("dir.wav/noext"));
    try testing.expectEqual(@as(?FileFormat, .wav), FileFormat.fromPath("dir/take.v2.wav/"));
}

test "AudioInfo duration is frames over sample rate, zero for rate 0" {
    const info: AudioInfo = .{ .format = .wav, .sample_format = .int16, .sample_rate = 48_000, .channels = 2, .frames = 24_000 };
    try testing.expectApproxEqAbs(@as(f64, 0.5), info.durationSecs(), 1e-12);
    var silent = info;
    silent.sample_rate = 0;
    try testing.expectEqual(@as(f64, 0.0), silent.durationSecs());
}

test "EncodeOptions defaults to 24-bit WAV without dither or BWF" {
    const opts: EncodeOptions = .{};
    try testing.expectEqual(FileFormat.wav, opts.format);
    try testing.expectEqual(BitDepth.int24, opts.bit_depth);
    try testing.expect(!opts.dither);
    try testing.expect(opts.bwf == null);
}
