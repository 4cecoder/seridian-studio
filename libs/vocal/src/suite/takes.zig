// Translated to Zig from pitchpure/crates/pitchpure_suite/src/takes.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Recording takes and processing dropped vocal files.
//!
//! Everything lands in `<home>/Music/PitchPure/` as 32-bit float WAV:
//! * a live take saves `take-<stamp>.wav` (processed, latency-aligned) and
//!   `take-<stamp>-raw.wav` (the untouched mic) so it can be redone later;
//! * a dropped file saves `<name>-pitchpure.wav`, rendered offline through
//!   the same `VocalChain` and settings as the live monitor.
//!
//! Seridian changes versus the Rust: the library reads no environment
//! variables and no clocks. `$HOME` is a `home` parameter, the wall-clock
//! time for the take stamp is a `unix_secs` parameter, and every file
//! operation takes the caller's `std.Io` plus a base `std.Io.Dir` that
//! relative paths resolve against. Rust's `HOME_LOCK` (tests serialising
//! `$HOME` changes) is therefore unnecessary and not translated. Rust's
//! `String` errors become Zig errors. Control thread only, except
//! `Take.pushAssumeCapacity`.

const std = @import("std");
const suite = @import("../suite.zig");
const BLOCK = suite.BLOCK;
const VocalChain = @import("chain.zig").VocalChain;
const Settings = @import("settings.zig").Settings;
const wav = @import("wav.zig");
const WavAudio = wav.WavAudio;

/// Where takes and processed files go: `<home>/Music/PitchPure` (`home`
/// is `$HOME`; `null` means the current directory, like the Rust).
/// Caller owns the returned path.
pub fn takesDir(gpa: std.mem.Allocator, home: ?[]const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home orelse ".", "Music", "PitchPure" });
}

/// Length of a `stamp` string.
pub const STAMP_LEN: usize = 15;

/// `YYYYMMDD-HHMMSS` (UTC) for `unix_secs` seconds since the epoch
/// (negative clamps to 0, like the Rust `map_or(0, ..)`), written into
/// `buf`. Years past 9999 do not fit and return `error.NoSpaceLeft`.
pub fn stamp(buf: *[STAMP_LEN]u8, unix_secs: i64) error{NoSpaceLeft}![]const u8 {
    const secs: i64 = @max(unix_secs, 0);
    const days = @divTrunc(secs, 86_400);
    const rem = @rem(secs, 86_400);
    // Civil-from-days (Howard Hinnant's algorithm).
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, @intFromBool(month <= 2));
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u64, @intCast(year)),
        @as(u64, @intCast(month)),
        @as(u64, @intCast(day)),
        @as(u64, @intCast(@divTrunc(rem, 3600))),
        @as(u64, @intCast(@rem(@divTrunc(rem, 60), 60))),
        @as(u64, @intCast(@rem(rem, 60))),
    });
}

fn saveMono(io: std.Io, dir: std.Io.Dir, path: []const u8, rate: u32, samples: []f32) !void {
    const audio: WavAudio = .{ .sample_rate = rate, .channels = 1, .samples = samples };
    try wav.writeWav(io, dir, path, &audio);
}

/// A take being recorded by the live loop. Owns both buffers; free with
/// `deinit`.
pub const Take = struct {
    rate: u32,
    latency: usize,
    raw: std.ArrayList(f32),
    wet: std.ArrayList(f32),

    pub fn init(gpa: std.mem.Allocator, rate: u32, latency: usize) !Take {
        // Reserve a minute up front so typical takes never reallocate.
        const cap = @as(usize, rate) * 60;
        var raw: std.ArrayList(f32) = .empty;
        errdefer raw.deinit(gpa);
        try raw.ensureTotalCapacity(gpa, cap);
        var wet: std.ArrayList(f32) = .empty;
        errdefer wet.deinit(gpa);
        try wet.ensureTotalCapacity(gpa, cap);
        return .{ .rate = rate, .latency = latency, .raw = raw, .wet = wet };
    }

    pub fn deinit(self: *Take, gpa: std.mem.Allocator) void {
        self.raw.deinit(gpa);
        self.wet.deinit(gpa);
        self.* = undefined;
    }

    /// Append one block of raw and processed audio. Allocates once the
    /// reserved minute is used up, so it is not audio-thread safe; see
    /// `pushAssumeCapacity`.
    pub fn push(self: *Take, gpa: std.mem.Allocator, raw: []const f32, wet_block: []const f32) !void {
        try self.raw.appendSlice(gpa, raw);
        try self.wet.appendSlice(gpa, wet_block);
    }

    /// Room left (in samples of each stream) before `push` must allocate.
    pub fn remainingCapacity(self: *const Take) usize {
        return @min(self.raw.capacity - self.raw.items.len, self.wet.capacity - self.wet.items.len);
    }

    /// Real-time `push`: never allocates. Returns `error.TakeFull` (and
    /// appends nothing) when the reserved capacity would be exceeded.
    pub fn pushAssumeCapacity(self: *Take, raw: []const f32, wet_block: []const f32) error{TakeFull}!void {
        if (self.raw.capacity - self.raw.items.len < raw.len or
            self.wet.capacity - self.wet.items.len < wet_block.len) return error.TakeFull;
        self.raw.appendSliceAssumeCapacity(raw);
        self.wet.appendSliceAssumeCapacity(wet_block);
    }

    pub fn seconds(self: *const Take) f32 {
        return @as(f32, @floatFromInt(self.raw.items.len)) / @as(f32, @floatFromInt(self.rate));
    }

    /// Write both files into `dir_path` (created if missing; relative to
    /// `dir`), stamped with `unix_secs`; returns the processed take's path
    /// (caller owns it). Like the Rust (which consumes the take), this
    /// trims the processed buffer in place; `deinit` the take afterwards.
    pub fn save(self: *Take, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, dir_path: []const u8, unix_secs: i64) ![]u8 {
        try dir.createDirPath(io, dir_path);
        var stamp_buf: [STAMP_LEN]u8 = undefined;
        const st = try stamp(&stamp_buf, unix_secs);
        // Shift the processed take back by the chain latency so it lines up
        // with the raw take sample-for-sample.
        const skip = @min(self.latency, self.wet.items.len);
        self.wet.replaceRangeAssumeCapacity(0, skip, &.{});
        // Keep both files the same length (the processed tail that was
        // still in flight when REC stopped is silence).
        const raw_len = self.raw.items.len;
        if (self.wet.items.len > raw_len) {
            self.wet.shrinkRetainingCapacity(raw_len);
        } else {
            try self.wet.appendNTimes(gpa, 0.0, raw_len - self.wet.items.len);
        }
        const wet_name = try std.fmt.allocPrint(gpa, "take-{s}.wav", .{st});
        defer gpa.free(wet_name);
        const raw_name = try std.fmt.allocPrint(gpa, "take-{s}-raw.wav", .{st});
        defer gpa.free(raw_name);
        const wet_path = try std.fs.path.join(gpa, &.{ dir_path, wet_name });
        errdefer gpa.free(wet_path);
        const raw_path = try std.fs.path.join(gpa, &.{ dir_path, raw_name });
        defer gpa.free(raw_path);
        try saveMono(io, dir, wet_path, self.rate, self.wet.items);
        try saveMono(io, dir, raw_path, self.rate, self.raw.items);
        return wet_path;
    }
};

/// One analysis block of a processed file, for the pitch graph.
pub const FilePitch = struct {
    detected_hz: f32,
    ratio: f32,
};

/// Result of rendering a dropped file. Owns every slice; free with `deinit`.
pub const Rendered = struct {
    out_path: []u8,
    seconds: f32,
    pitch: []FilePitch,
    /// Waveform overviews (peak per bucket, at most `PEAK_BUCKETS` long).
    in_peaks: []f32,
    out_peaks: []f32,

    pub fn deinit(self: *Rendered, gpa: std.mem.Allocator) void {
        gpa.free(self.out_path);
        gpa.free(self.pitch);
        gpa.free(self.in_peaks);
        gpa.free(self.out_peaks);
        self.* = undefined;
    }
};

/// Resolution of the before/after waveform overviews.
pub const PEAK_BUCKETS: usize = 1200;

fn peaks(gpa: std.mem.Allocator, samples: []const f32) ![]f32 {
    const per = @max(std.math.divCeil(usize, samples.len, PEAK_BUCKETS) catch unreachable, 1);
    const count = std.math.divCeil(usize, samples.len, per) catch unreachable;
    const out = try gpa.alloc(f32, count);
    for (out, 0..) |*p, i| {
        const chunk = samples[i * per .. @min((i + 1) * per, samples.len)];
        var m: f32 = 0.0;
        for (chunk) |s| m = @max(m, @abs(s));
        p.* = m;
    }
    return out;
}

/// Render `input_path` through the vocal chain with `cfg` (monitor/bypass
/// ignored) into `takesDir(home)`. `progress` receives permille done for
/// the UI. (Rust: test-only `process_file`, which read `$HOME`.)
pub fn processFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    input_path: []const u8,
    home: ?[]const u8,
    cfg: *const Settings,
    progress: *std.atomic.Value(u32),
) !Rendered {
    const out_dir = try takesDir(gpa, home);
    defer gpa.free(out_dir);
    return processFileTo(gpa, io, dir, input_path, out_dir, cfg, progress);
}

/// `processFile` writing `<name>-pitchpure.wav` into `out_dir_path`. Paths
/// are relative to `dir` (or absolute).
pub fn processFileTo(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    input_path: []const u8,
    out_dir_path: []const u8,
    cfg_in: *const Settings,
    progress: *std.atomic.Value(u32),
) !Rendered {
    var audio = try wav.readWav(gpa, io, dir, input_path);
    defer audio.deinit(gpa);
    const channels = @max(audio.channels, 1);
    const frames = audio.samples.len / channels;
    if (frames == 0) return error.NoAudio;
    // Fold to mono (average): the chain is a single vocal voice.
    const mono = try gpa.alloc(f32, frames);
    defer gpa.free(mono);
    const ch_f: f32 = @floatFromInt(channels);
    for (mono, 0..) |*m, f| {
        var sum: f32 = 0.0;
        for (audio.samples[f * channels .. (f + 1) * channels]) |s| sum += s;
        m.* = sum / ch_f;
    }
    var cfg = cfg_in.*;
    cfg.bypass = false;
    var chain = try VocalChain.init(gpa, audio.sample_rate, &cfg);
    defer chain.deinit(gpa);
    chain.configure(&cfg);
    const latency = chain.latencySamples();
    // Run past the end by the latency so the tail comes out, then trim.
    const total = frames + latency;
    const blocks = std.math.divCeil(usize, total, BLOCK) catch unreachable;
    const out = try gpa.alloc(f32, blocks * BLOCK);
    defer gpa.free(out);
    var pitch: std.ArrayList(FilePitch) = .empty;
    defer pitch.deinit(gpa);
    try pitch.ensureTotalCapacity(gpa, blocks);
    var block_in: [BLOCK]f32 = undefined;
    for (0..blocks) |b| {
        const start = b * BLOCK;
        @memset(&block_in, 0.0);
        if (start < frames) {
            const n = @min(frames - start, BLOCK);
            @memcpy(block_in[0..n], mono[start .. start + n]);
        }
        const report = try chain.process(&block_in, out[start .. start + BLOCK], &cfg);
        if (start < frames) {
            pitch.appendAssumeCapacity(.{ .detected_hz = report.detected_hz, .ratio = report.ratio });
        }
        progress.store(@intCast((b + 1) * 1000 / blocks), .monotonic);
    }
    const trimmed = out[latency .. latency + frames];
    const in_peaks = try peaks(gpa, mono);
    errdefer gpa.free(in_peaks);
    const out_peaks = try peaks(gpa, trimmed);
    errdefer gpa.free(out_peaks);
    try dir.createDirPath(io, out_dir_path);
    const base = std.fs.path.stem(input_path);
    const file_name = try std.fmt.allocPrint(gpa, "{s}-pitchpure.wav", .{if (base.len == 0) "vocal" else base});
    defer gpa.free(file_name);
    const out_path = try std.fs.path.join(gpa, &.{ out_dir_path, file_name });
    errdefer gpa.free(out_path);
    try saveMono(io, dir, out_path, audio.sample_rate, trimmed);
    const pitch_owned = try pitch.toOwnedSlice(gpa);
    return .{
        .out_path = out_path,
        .seconds = @as(f32, @floatFromInt(frames)) / @as(f32, @floatFromInt(audio.sample_rate)),
        .pitch = pitch_owned,
        .in_peaks = in_peaks,
        .out_peaks = out_peaks,
    };
}

const testing = std.testing;

test "stamp_is_sortable_and_sized" {
    const now = std.Io.Clock.real.now(testing.io).toSeconds();
    var buf: [STAMP_LEN]u8 = undefined;
    const s = try stamp(&buf, now);
    try testing.expectEqual(@as(usize, 15), s.len);
    try testing.expect(std.mem.startsWith(u8, s, "20"));
    try testing.expectEqualStrings("-", s[8..9]);
}

// Seridian: known-answer check for the civil-from-days port.
test "stamp known dates" {
    var buf: [STAMP_LEN]u8 = undefined;
    try testing.expectEqualStrings("19700101-000000", try stamp(&buf, 0));
    try testing.expectEqualStrings("20000229-235959", try stamp(&buf, 951_868_799));
    try testing.expectEqualStrings("19700101-000000", try stamp(&buf, -5));
}

test "dropped_file_renders_same_length_aligned" {
    const gpa = testing.allocator;
    const io = testing.io;
    const rate: u32 = 48_000;
    const n: usize = rate; // 1 s of 220 Hz
    const samples = try gpa.alloc(f32, n);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| {
        s.* = 0.4 * @sin(std.math.tau * 220.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate)));
    }
    // Rust: a temp dir that also stands in for `$HOME`.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try wav.writeWav(io, tmp.dir, "vox.wav", &.{ .sample_rate = rate, .channels = 1, .samples = samples });
    var progress = std.atomic.Value(u32).init(0);
    const cfg: Settings = .{};
    var rendered = try processFile(gpa, io, tmp.dir, "vox.wav", ".", &cfg, &progress);
    defer rendered.deinit(gpa);
    try testing.expectEqual(@as(u32, 1000), progress.load(.monotonic));
    var out = try wav.readWav(gpa, io, tmp.dir, rendered.out_path);
    defer out.deinit(gpa);
    try testing.expectEqual(n, out.samples.len);
    for (out.samples) |s| try testing.expect(std.math.isFinite(s));
    var sum: f32 = 0.0;
    for (out.samples[n / 2 ..]) |s| sum += s * s;
    const rms = @sqrt(sum / @as(f32, @floatFromInt(n / 2)));
    try testing.expect(rms > 0.05);
    var found = false;
    for (rendered.pitch) |p| {
        if (@abs(p.detected_hz - 220.0) < 5.0) found = true;
    }
    try testing.expect(found);
}
