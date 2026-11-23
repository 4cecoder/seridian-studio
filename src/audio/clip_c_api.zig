// =============================================================================
// Clip C API Bridge
// =============================================================================
// Exposes clip functionality to C code (GTK UI)

const std = @import("std");
const clip = @import("clip.zig");
const engine = @import("engine.zig");
const peak_cache = @import("peak_cache.zig");

const ClipList = clip.ClipList;
const Clip = clip.Clip;
const ClipId = clip.ClipId;
const AudioEngine = engine.AudioEngine;
const PeakCache = peak_cache.PeakCache;

// =============================================================================
// Track Clip Management
// =============================================================================

/// Get number of clips on a track
export fn track_get_clip_count(engine_ptr: ?*anyopaque, track_idx: c_int) callconv(.c) c_int {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];
    return @intCast(track.clips.count());
}

/// Get clip ID by index
export fn track_get_clip_id(engine_ptr: ?*anyopaque, track_idx: c_int, clip_idx: c_int) callconv(.c) u64 {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];
    if (track.clips.getByIndex(@intCast(clip_idx))) |c| {
        return c.id;
    }
    return 0;
}

/// Get clip start time
export fn track_get_clip_start(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f64 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0.0;
    return c.start_time;
}

/// Get clip duration
export fn track_get_clip_duration(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f64 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0.0;
    return c.duration;
}

/// Get clip color
export fn track_get_clip_color(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) u32 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0x7aa2f7;
    return c.color;
}

/// Get clip name (returns pointer to internal buffer)
export fn track_get_clip_name(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) [*:0]const u8 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return "Clip";
    return @ptrCast(&c.name);
}

/// Check if clip is muted
export fn track_get_clip_muted(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) c_int {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0;
    return if (c.muted) 1 else 0;
}

// =============================================================================
// Clip Modification
// =============================================================================

/// Set clip position
export fn track_set_clip_position(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, start_time: f64) callconv(.c) c_int {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];
    return if (track.clips.moveClip(clip_id, start_time)) 1 else 0;
}

/// Set clip duration
export fn track_set_clip_duration(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, duration: f64) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.duration = if (duration < 0.01) 0.01 else duration;
    return 1;
}

/// Set clip color
export fn track_set_clip_color(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, color: u32) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.color = color;
    return 1;
}

/// Set clip muted state
export fn track_set_clip_muted(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, muted: c_int) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.muted = muted != 0;
    return 1;
}

// =============================================================================
// Clip Editing (Trim, Fade, Split)
// =============================================================================

/// Get clip fade in duration (seconds)
export fn track_get_clip_fade_in(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f32 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0.0;
    return c.fade_in;
}

/// Get clip fade out duration (seconds)
export fn track_get_clip_fade_out(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f32 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0.0;
    return c.fade_out;
}

/// Set clip fade in duration (seconds)
export fn track_set_clip_fade_in(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, fade_in: f32) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    // Clamp fade to clip duration
    c.fade_in = @min(@max(0.0, fade_in), @as(f32, @floatCast(c.duration)));
    return 1;
}

/// Set clip fade out duration (seconds)
export fn track_set_clip_fade_out(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, fade_out: f32) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    // Clamp fade to clip duration
    c.fade_out = @min(@max(0.0, fade_out), @as(f32, @floatCast(c.duration)));
    return 1;
}

/// Get clip source offset (for trimmed clips)
export fn track_get_clip_source_offset(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f64 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0.0;
    return c.source_offset;
}

/// Trim clip from the start (moves start time forward, adjusts source offset)
export fn track_trim_clip_start(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, new_start: f64) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.setStartTime(new_start);
    return 1;
}

/// Trim clip from the end (sets new end time)
export fn track_trim_clip_end(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, new_end: f64) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.setEndTime(new_end);
    return 1;
}

/// Split clip at a given time, returns new clip ID or 0 on failure
export fn track_split_clip(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, split_time: f64) callconv(.c) u64 {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];
    const new_id = track.clips.splitClip(clip_id, split_time) catch return 0;
    return new_id orelse 0;
}

/// Get clip gain (volume multiplier)
export fn track_get_clip_gain(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) f32 {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 1.0;
    return c.gain;
}

/// Set clip gain (volume multiplier, 0.0 to 2.0)
export fn track_set_clip_gain(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64, gain: f32) callconv(.c) c_int {
    const c = getClipPtrMut(engine_ptr, track_idx, clip_id) orelse return 0;
    c.gain = @min(@max(0.0, gain), 2.0);
    return 1;
}

// =============================================================================
// Clip Creation/Deletion
// =============================================================================

/// Create a new clip on a track
export fn track_add_clip(
    engine_ptr: ?*anyopaque,
    track_idx: c_int,
    start_time: f64,
    duration: f64,
    name: [*:0]const u8,
    color: u32,
) callconv(.c) u64 {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];

    var new_clip = Clip{
        .id = 0, // Will be assigned
        .start_time = start_time,
        .duration = duration,
        .color = color,
    };

    // Copy name
    const name_slice = std.mem.sliceTo(name, 0);
    new_clip.setName(name_slice);

    return track.clips.addClip(new_clip) catch 0;
}

/// Remove a clip from a track
export fn track_remove_clip(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) callconv(.c) c_int {
    const eng = getEngine(engine_ptr) orelse return 0;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return 0;

    const track = &eng.tracks[@intCast(track_idx)];
    return if (track.clips.removeClip(clip_id)) 1 else 0;
}

// =============================================================================
// Waveform Peaks
// =============================================================================

/// Get waveform peaks for a clip (for visualization)
/// Returns number of peaks written to output buffer
/// Output format: [min0, max0, min1, max1, ...]
export fn track_get_clip_peaks(
    engine_ptr: ?*anyopaque,
    track_idx: c_int,
    clip_id: u64,
    start_time: f64,
    end_time: f64,
    num_peaks: c_int,
    peaks_out: [*]f32,
) callconv(.c) c_int {
    const c = getClipPtr(engine_ptr, track_idx, clip_id) orelse return 0;
    if (num_peaks <= 0) return 0;
    const count: usize = @intCast(num_peaks);

    // Priority 1: Use PeakCache if available (best quality)
    if (c.peak_cache_ptr) |cache| {
        const out_slice = peaks_out[0 .. count * 2];
        return @intCast(cache.getPeaksFlat(start_time, end_time, out_slice));
    }

    // Priority 2: Use legacy flat peaks array if available
    if (c.peaks) |peaks| {
        // Calculate which peaks to use based on time range
        const clip_duration = c.duration;
        if (clip_duration <= 0) return 0;

        const peaks_per_sec = @as(f64, @floatFromInt(c.peaks_per_second));
        const start_idx = @as(usize, @intFromFloat(@max(0.0, (start_time - c.start_time)) * peaks_per_sec));
        const end_idx = @as(usize, @intFromFloat((end_time - c.start_time) * peaks_per_sec));

        if (start_idx * 2 >= peaks.len) return 0;

        const available_peaks = (peaks.len / 2) - start_idx;
        const peaks_to_copy = @min(count, @min(available_peaks, end_idx - start_idx));

        for (0..peaks_to_copy) |i| {
            const src_idx = (start_idx + i) * 2;
            if (src_idx + 1 < peaks.len) {
                peaks_out[i * 2] = peaks[src_idx];
                peaks_out[i * 2 + 1] = peaks[src_idx + 1];
            }
        }
        return @intCast(peaks_to_copy);
    }

    // Priority 3: Generate from raw audio samples if available
    if (c.audio_samples) |samples| {
        const num_channels = c.audio_channels;
        const sample_rate = c.audio_sample_rate;
        const total_frames = samples.len / num_channels;

        // Map time range to sample range
        const clip_start = c.start_time;
        const offset_in_clip = @max(0.0, start_time - clip_start) + c.source_offset;
        const range_duration = end_time - start_time;

        const start_frame = @as(usize, @intFromFloat(offset_in_clip * @as(f64, @floatFromInt(sample_rate))));
        const frames_in_range = @as(usize, @intFromFloat(range_duration * @as(f64, @floatFromInt(sample_rate))));

        if (start_frame >= total_frames) return 0;

        const actual_frames = @min(frames_in_range, total_frames - start_frame);
        const samples_per_peak = @max(1, actual_frames / count);

        var peaks_written: usize = 0;
        var frame_idx = start_frame;

        while (peaks_written < count and frame_idx < total_frames) : (peaks_written += 1) {
            var min_val: f32 = 1.0;
            var max_val: f32 = -1.0;

            const end_frame = @min(frame_idx + samples_per_peak, total_frames);
            while (frame_idx < end_frame) : (frame_idx += 1) {
                // Mix channels to mono
                var sum: f32 = 0.0;
                for (0..num_channels) |ch| {
                    const idx = frame_idx * num_channels + ch;
                    if (idx < samples.len) {
                        sum += samples[idx];
                    }
                }
                const mono = sum / @as(f32, @floatFromInt(num_channels));
                min_val = @min(min_val, mono);
                max_val = @max(max_val, mono);
            }

            peaks_out[peaks_written * 2] = min_val;
            peaks_out[peaks_written * 2 + 1] = max_val;
        }

        return @intCast(peaks_written);
    }

    // Fallback: Generate placeholder waveform
    for (0..count) |i| {
        const t: f32 = @floatFromInt(i);
        const normalized_t = t / @as(f32, @floatFromInt(count));
        const phase = normalized_t * 20.0 + @as(f32, @floatCast(c.start_time * 5.0));

        // Create a more interesting waveform shape
        const wave1 = @sin(phase);
        const wave2 = @sin(phase * 2.3) * 0.5;
        const wave3 = @sin(phase * 0.7) * 0.3;
        const combined = (wave1 + wave2 + wave3) / 1.8;

        const amplitude: f32 = 0.2 + 0.6 * @abs(combined);
        peaks_out[i * 2] = -amplitude;
        peaks_out[i * 2 + 1] = amplitude;
    }

    return @intCast(count);
}

// =============================================================================
// Helper Functions
// =============================================================================

fn getEngine(engine_ptr: ?*anyopaque) ?*AudioEngine {
    if (engine_ptr) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    return null;
}

fn getClipPtr(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) ?*const Clip {
    const eng = getEngine(engine_ptr) orelse return null;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return null;

    const track = &eng.tracks[@intCast(track_idx)];
    return track.clips.getClip(clip_id);
}

fn getClipPtrMut(engine_ptr: ?*anyopaque, track_idx: c_int, clip_id: u64) ?*Clip {
    const eng = getEngine(engine_ptr) orelse return null;
    if (track_idx < 0 or track_idx >= AudioEngine.TRACK_COUNT) return null;

    const track = &eng.tracks[@intCast(track_idx)];
    return track.clips.getClip(clip_id);
}
