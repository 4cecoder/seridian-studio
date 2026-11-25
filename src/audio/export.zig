//! Audio Export Module - Offline rendering to WAV files
//!
//! Renders the project mix to a WAV file without needing real-time playback.

const std = @import("std");
const mastering = @import("mastering.zig");
const wav = @import("wav.zig");
const AudioEngine = @import("engine.zig").AudioEngine;
const midi_clip = @import("../midi/midi_clip.zig");
const sys = @import("../utils/sys.zig");
const file_error = @import("../utils/file_error.zig");

const log = std.log.scoped(.audio_export);

pub const ExportFormat = enum {
    wav_16bit,
    wav_24bit,
};

pub const ExportConfig = struct {
    sample_rate: u32 = 48000,
    format: ExportFormat = .wav_16bit,
    start_time: f64 = 0.0, // seconds
    end_time: f64 = 0.0, // seconds (0 = auto-detect from clips)
    normalize: bool = false,
};

pub const ExportProgress = struct {
    current_frame: u64,
    total_frames: u64,
    percent: f32,
    done: bool,
};

var g_last_peak: f32 = 0.0;

/// Absolute peak of the most recent export, 0..1+ (1.0 is full scale).
export fn audio_export_last_peak() callconv(.c) f32 {
    return g_last_peak;
}

/// Export engine mix to WAV file
/// Returns number of frames written, or error
pub fn exportToWav(
    engine: *AudioEngine,
    path: []const u8,
    config: ExportConfig,
) !u64 {
    const sample_rate = config.sample_rate;
    const buffer_size: usize = 1024; // Process in chunks

    // Calculate duration
    var end_time = config.end_time;
    if (end_time <= config.start_time) {
        // Auto-detect from clips - find latest clip end
        end_time = getProjectDuration(engine);
        if (end_time <= 0) {
            log.warn("No clips found, exporting 10 seconds of silence/instruments", .{});
            end_time = 10.0;
        }
    }

    const duration = end_time - config.start_time;
    const total_frames: u64 = @intFromFloat(duration * @as(f64, @floatFromInt(sample_rate)));

    log.info("Exporting {d:.2}s ({} frames) to: {s}", .{ duration, total_frames, path });

    // Create WAV writer
    const bits = switch (config.format) {
        .wav_16bit => @as(u16, 16),
        .wav_24bit => @as(u16, 24),
    };

    var writer = try wav.WavWriter.create(path, sample_rate, 2, bits);
    errdefer writer.abort();

    // Allocate render buffer (stereo interleaved)
    var buffer: [buffer_size * 2]f32 = undefined;

    // Rewind clip cursors and silence instruments so the export starts at the
    // export start time, then restore everything afterwards. The real transport
    // (position/playing) is never touched.
    const saved = engine.beginOfflineRender();
    defer engine.endOfflineRender(saved);

    const start_frame: u64 = @intFromFloat(@max(0.0, config.start_time) * @as(f64, @floatFromInt(sample_rate)));

    var frames_written: u64 = 0;
    var peak: f32 = 0.0;
    var dither = wav.TpdfDither{};

    // First pass: render and optionally find peak for normalization
    // The mastering limiter delays the signal by its lookahead, and effects such as the
    // vocal tuner by their algorithmic latency (tracks are compensated to the slowest).
    // Render that many extra frames and drop the first ones so the file is aligned
    // with the timeline.
    const latency: u64 = engine.masteringLatencyFrames() + engine.effectsLatencyFrames();
    var rendered: u64 = 0;

    while (frames_written < total_frames) {
        const frames_remaining = total_frames + latency - rendered;
        // @min with a comptime-known bound yields a narrow type (u11); widen before multiplying.
        const frames_to_render: usize = @intCast(@min(@as(u64, buffer_size), frames_remaining));
        const samples_to_render: usize = frames_to_render * 2;

        // Clear buffer
        @memset(&buffer, 0.0);

        // Render from engine (same MIDI triggering and mixing as playback, transport untouched)
        engine.renderOffline(buffer[0..samples_to_render], start_frame + rendered);

        // Skip the latency frames at the start
        const skip: usize = @intCast(@min(latency -| rendered, @as(u64, frames_to_render)));
        const out = buffer[skip * 2 .. samples_to_render];

        // Always track the peak of what is written (it is logged, and used for normalization)
        peak = @max(peak, bufferPeak(out));

        // Write to file (16-bit gets TPDF dither)
        switch (config.format) {
            .wav_16bit => try writer.writeSamplesDithered(out, &dither),
            .wav_24bit => try writer.writeSamples24(out),
        }

        frames_written += frames_to_render - skip;
        rendered += frames_to_render;
    }

    try writer.close();
    g_last_peak = peak;

    log.info("Export complete: {} frames, peak: {d:.3}", .{ frames_written, peak });

    return frames_written;
}

/// Absolute peak of a sample buffer.
fn bufferPeak(samples: []const f32) f32 {
    var p: f32 = 0.0;
    for (samples) |s| p = @max(p, @abs(s));
    return p;
}

test "bufferPeak finds absolute maximum" {
    try std.testing.expectEqual(@as(f32, 0.0), bufferPeak(&.{}));
    try std.testing.expectEqual(@as(f32, 0.5), bufferPeak(&.{ 0.1, -0.5, 0.25 }));
}

/// Get project duration by finding the latest audio clip end or MIDI note end (in seconds)
fn getProjectDuration(engine: *AudioEngine) f64 {
    var max_end: f64 = 0.0;

    // MIDI: note end = clip start beat + note end beat, converted with the project BPM
    const beats_to_seconds: f64 = 60.0 / @as(f64, engine.getTempo());
    for (0..engine.tracks.len) |i| {
        const track: c_int = @intCast(i);
        if (midi_clip.midi_clip_has_notes(track) == 0) continue;
        const end_beat = midi_clip.midi_clip_get_start_beat(track) + midi_clip.midi_clip_get_duration(track);
        max_end = @max(max_end, end_beat * beats_to_seconds);
    }

    for (&engine.tracks) |*track| {
        for (track.clips.clips.items) |clip| {
            const clip_end = clip.start_time + clip.duration;
            if (clip_end > max_end) {
                max_end = clip_end;
            }
        }
    }

    return max_end;
}

// =============================================================================
// C API for GTK
// =============================================================================

var g_export_progress: ExportProgress = .{
    .current_frame = 0,
    .total_frames = 0,
    .percent = 0.0,
    .done = false,
};

/// Export project to WAV file
/// Returns 0 on success, -1 on error
export fn audio_export_wav(
    engine_ptr: ?*anyopaque,
    path_ptr: [*:0]const u8,
    duration_seconds: f64,
    bit_depth: c_int,
) callconv(.c) c_int {
    const engine: *AudioEngine = @ptrCast(@alignCast(engine_ptr orelse return -1));
    const path = std.mem.span(path_ptr);

    const format: ExportFormat = if (bit_depth == 24) .wav_24bit else .wav_16bit;

    const config = ExportConfig{
        .sample_rate = engine.config.sample_rate,
        .format = format,
        .end_time = duration_seconds,
    };

    g_export_progress = .{
        .current_frame = 0,
        .total_frames = 0,
        .percent = 0.0,
        .done = false,
    };

    const frames = exportToWav(engine, path, config) catch |err| {
        log.warn("Export failed: {}", .{err});
        file_error.record(err);
        return -1;
    };

    g_export_progress.total_frames = frames;
    g_export_progress.current_frame = frames;
    g_export_progress.percent = 100.0;
    g_export_progress.done = true;

    return 0;
}

/// Get export progress (0-100)
export fn audio_export_get_progress() callconv(.c) f32 {
    return g_export_progress.percent;
}

/// Check if export is done
export fn audio_export_is_done() callconv(.c) c_int {
    return if (g_export_progress.done) 1 else 0;
}

// =============================================================================
// Tests
// =============================================================================

test "export config defaults" {
    const testing = std.testing;

    const config = ExportConfig{};

    try testing.expectEqual(@as(u32, 48000), config.sample_rate);
    try testing.expectEqual(ExportFormat.wav_16bit, config.format);
    try testing.expectApproxEqAbs(@as(f64, 0.0), config.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), config.end_time, 0.001);
    try testing.expect(!config.normalize);
}

test "export config custom" {
    const testing = std.testing;

    const config = ExportConfig{
        .sample_rate = 96000,
        .format = .wav_24bit,
        .start_time = 1.0,
        .end_time = 30.0,
        .normalize = true,
    };

    try testing.expectEqual(@as(u32, 96000), config.sample_rate);
    try testing.expectEqual(ExportFormat.wav_24bit, config.format);
    try testing.expectApproxEqAbs(@as(f64, 1.0), config.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 30.0), config.end_time, 0.001);
    try testing.expect(config.normalize);
}

test "export progress struct" {
    const testing = std.testing;

    var progress = ExportProgress{
        .current_frame = 0,
        .total_frames = 48000,
        .percent = 0.0,
        .done = false,
    };

    try testing.expectEqual(@as(u64, 0), progress.current_frame);
    try testing.expectEqual(@as(u64, 48000), progress.total_frames);
    try testing.expect(!progress.done);

    // Simulate progress
    progress.current_frame = 24000;
    progress.percent = 50.0;

    try testing.expectEqual(@as(u64, 24000), progress.current_frame);
    try testing.expectApproxEqAbs(@as(f32, 50.0), progress.percent, 0.001);

    // Complete
    progress.current_frame = 48000;
    progress.percent = 100.0;
    progress.done = true;

    try testing.expect(progress.done);
}

test "export format enum" {
    const testing = std.testing;

    const fmt_16 = ExportFormat.wav_16bit;
    const fmt_24 = ExportFormat.wav_24bit;

    try testing.expect(fmt_16 != fmt_24);
}

// Reads the data chunk size of a 16-bit stereo export and returns all samples.
fn readExport(path: []const u8, out: []f32) !struct { data_size: u32, frames: u64 } {
    var file = try wav.WavFile.open(std.testing.allocator, path);
    defer file.close();
    const frames = file.getTotalFrames();
    _ = try file.readSamples(out, @min(frames, out.len / 2));
    return .{ .data_size = file.header.data_size, .frames = frames };
}

test "export WAV data size equals frames * channels * 2" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();

    const path = "test_export_size.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), path) catch {};

    // 1500 frames: one full 1024 chunk plus a partial chunk
    const frames = try exportToWav(&engine, path, .{ .sample_rate = 48000, .start_time = 0.0, .end_time = 1500.0 / 48000.0 });
    try testing.expect(frames >= 1499 and frames <= 1500);

    var out: [8]f32 = undefined;
    const info = try readExport(path, &out);
    try testing.expectEqual(info.frames, frames);
    try testing.expectEqual(@as(u32, @intCast(frames * 2 * 2)), info.data_size);
}

test "export renders MIDI instruments without moving the transport" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();

    const track: usize = 5;
    try engine.tracks[track].setInstrument(.keys);
    midi_clip.midi_clip_clear(@intCast(track));
    defer midi_clip.midi_clip_clear(@intCast(track));
    try testing.expect(midi_clip.midi_clip_add_note(@intCast(track), 0.0, 1.0, 60, 100) != 0);

    const path = "test_export_midi.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), path) catch {};

    const frames = try exportToWav(&engine, path, .{ .sample_rate = 48000, .end_time = 4096.0 / 48000.0 });
    try testing.expect(frames > 0);

    var out: [8192]f32 = undefined;
    _ = try readExport(path, &out);
    var peak: f32 = 0.0;
    for (out) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.001);

    // Transport untouched
    try testing.expect(!engine.isPlaying());
    try testing.expectEqual(@as(u64, 0), engine.getPosition());
}

test "export rewinds clip cursors and restores them afterwards" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();

    var samples: [4000]f32 = @splat(0.5); // 2000 stereo frames
    try engine.tracks[0].loadFromBuffer(&samples, 2, 48000);
    engine.setUseTestTones(false);

    // Simulate partial playback: cursor at the very end would export silence without a rewind
    engine.tracks[0].clip.?.seek(2000);
    engine.position.store(777, .monotonic);

    const path = "test_export_rewind.wav";
    defer std.Io.Dir.cwd().deleteFile(sys.io(), path) catch {};

    _ = try exportToWav(&engine, path, .{ .sample_rate = 48000, .end_time = 300.0 / 48000.0 });

    var out: [8]f32 = undefined;
    _ = try readExport(path, &out);
    // 0.5 * track gain 0.75 * master gain 0.75
    const makeup = std.math.pow(f32, 10.0, mastering.makeup_db / 20.0);
    try testing.expectApproxEqAbs(@as(f32, 0.28125) * makeup, out[0], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.28125) * makeup, out[1], 0.02);

    // Cursor and transport restored
    try testing.expectEqual(@as(u64, 2000), engine.tracks[0].clip.?.position);
    try testing.expectEqual(@as(u64, 777), engine.getPosition());
    try testing.expect(!engine.isPlaying());
}

test "project duration includes MIDI note end times" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();

    const track: usize = 6;
    midi_clip.midi_clip_clear(@intCast(track));
    defer midi_clip.midi_clip_clear(@intCast(track));
    engine.setTempo(120.0);
    try testing.expect(midi_clip.midi_clip_add_note(@intCast(track), 0.0, 2.0, 60, 100) != 0);

    // 2 beats at 120 BPM = 1 second
    try testing.expectApproxEqAbs(@as(f64, 1.0), getProjectDuration(&engine), 1e-9);
}

test "a failed export leaves its cause for the control socket" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 512 });
    defer engine.deinit();
    // /proc/version is a file, so nothing can be created below it.
    try testing.expectEqual(@as(c_int, -1), audio_export_wav(@ptrCast(&engine), "/proc/version/out.wav", 0.01, 16));
    try testing.expectEqualStrings("not a directory", std.mem.span(file_error.lastCause()));
}
