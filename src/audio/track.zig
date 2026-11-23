/// Audio track - manages playback of audio clips and instruments
const std = @import("std");
const wav = @import("wav.zig");
const instruments = @import("../instruments/instruments.zig");
const clip_module = @import("clip.zig");
const midi_clip = @import("../midi/midi_clip.zig");
/// A note on or off at a frame inside the block being rendered.
pub const ClipEvent = midi_clip.ClipEvent;
const Instrument = instruments.Instrument;
const ClipList = clip_module.ClipList;

const log = std.log.scoped(.track);

pub const AudioClip = struct {
    allocator: std.mem.Allocator,
    samples: []f32, // Interleaved samples
    num_channels: u16,
    sample_rate: u32,
    num_frames: u64,
    position: u64 = 0, // Current playback position in frames

    /// Load audio clip from WAV file
    pub fn fromWav(allocator: std.mem.Allocator, path: []const u8) !AudioClip {
        var wav_file = try wav.WavFile.open(allocator, path);
        defer wav_file.close();

        const total_frames = wav_file.getTotalFrames();
        const num_channels = wav_file.header.num_channels;
        const total_samples = total_frames * num_channels;

        // Allocate buffer for all samples
        const samples = try allocator.alloc(f32, total_samples);
        errdefer allocator.free(samples);

        // Read all samples at once
        const samples_read = try wav_file.readSamples(samples, total_frames);
        if (samples_read != total_samples) {
            log.warn("Expected {} samples but read {}", .{ total_samples, samples_read });
        }

        log.info("Loaded audio clip: {} frames, {} channels, {}Hz", .{
            total_frames,
            num_channels,
            wav_file.header.sample_rate,
        });

        return AudioClip{
            .allocator = allocator,
            .samples = samples,
            .num_channels = num_channels,
            .sample_rate = wav_file.header.sample_rate,
            .num_frames = total_frames,
        };
    }

    pub fn deinit(self: *AudioClip) void {
        self.allocator.free(self.samples);
    }

    /// Read frames from clip (converts to output sample rate if needed)
    /// Output buffer is stereo interleaved
    pub fn read(self: *AudioClip, output: []f32, num_frames: usize, output_sample_rate: u32) usize {
        const frames_available = self.num_frames - self.position;
        const frames_to_read = @min(num_frames, frames_available);

        if (frames_to_read == 0) return 0;

        // Simple case: same sample rate, just copy
        if (self.sample_rate == output_sample_rate) {
            const start_sample = self.position * self.num_channels;

            if (self.num_channels == 1) {
                // Mono to stereo
                for (0..frames_to_read) |i| {
                    const sample = self.samples[start_sample + i];
                    output[i * 2] = sample;
                    output[i * 2 + 1] = sample;
                }
            } else if (self.num_channels == 2) {
                // Stereo to stereo
                const samples_to_copy = frames_to_read * 2;
                @memcpy(output[0..samples_to_copy], self.samples[start_sample..][0..samples_to_copy]);
            } else {
                // Multi-channel to stereo (downmix)
                for (0..frames_to_read) |i| {
                    var left: f32 = 0;
                    var right: f32 = 0;

                    const frame_start = start_sample + (i * self.num_channels);
                    for (0..self.num_channels) |ch| {
                        const sample = self.samples[frame_start + ch];
                        if (ch % 2 == 0) {
                            left += sample;
                        } else {
                            right += sample;
                        }
                    }

                    output[i * 2] = left / @as(f32, @floatFromInt((self.num_channels + 1) / 2));
                    output[i * 2 + 1] = right / @as(f32, @floatFromInt(self.num_channels / 2));
                }
            }

            self.position += frames_to_read;
            return frames_to_read;
        }

        // TODO: Sample rate conversion (for now, just handle same rate)
        log.warn("Sample rate conversion not yet implemented ({} -> {})", .{
            self.sample_rate,
            output_sample_rate,
        });
        return 0;
    }

    /// Seek to position (in frames)
    pub fn seek(self: *AudioClip, position: u64) void {
        self.position = @min(position, self.num_frames);
    }

    /// Reset to beginning
    pub fn reset(self: *AudioClip) void {
        self.position = 0;
    }

    /// Check if playback is finished
    pub fn isFinished(self: *const AudioClip) bool {
        return self.position >= self.num_frames;
    }
};

pub const Track = struct {
    allocator: std.mem.Allocator,
    clip: ?AudioClip = null,
    // Instrument pointer must be accessed atomically to prevent race with audio thread
    instrument_ptr: std.atomic.Value(?*Instrument) = std.atomic.Value(?*Instrument).init(null),
    // Old instrument pending destruction (destroyed on next setInstrument or deinit)
    pending_destroy: ?*Instrument = null,
    /// Engine type of the current instrument (null when none). Name matching is unreliable because
    /// an instrument can register a display name that differs from its enum name (e.g. "Model Piano").
    instrument_type: ?instruments.InstrumentType = null,
    volume: f32 = 0.75,
    pan: f32 = 0.0, // -1.0 (left) to 1.0 (right)
    is_active: bool = false,
    /// Capture device index feeding this track (-1 = none).
    input_device: i32 = -1,
    /// Whether the track mixes its capture input.
    input_enabled: bool = false,

    /// Timeline clips (multiple clips with position/duration)
    clips: ClipList = undefined,
    clips_initialized: bool = false,

    /// Manual pan; written by control threads, read by the audio thread.
    pub fn setPan(self: *Track, pan: f32) void {
        @atomicStore(f32, &self.pan, pan, .monotonic);
    }

    pub fn getPan(self: *const Track) f32 {
        return @atomicLoad(f32, &self.pan, .monotonic);
    }

    /// Get current instrument (for non-RT access)
    pub fn getInstrument(self: *const Track) ?*Instrument {
        return self.instrument_ptr.load(.acquire);
    }

    pub fn init(allocator: std.mem.Allocator) Track {
        var track = Track{
            .allocator = allocator,
        };
        track.clips = ClipList.init(allocator);
        track.clips_initialized = true;
        return track;
    }

    pub fn deinit(self: *Track) void {
        if (self.clip) |*clip| {
            clip.deinit();
        }
        // Destroy any pending instrument first
        if (self.pending_destroy) |inst| {
            inst.destroy(self.allocator);
            self.pending_destroy = null;
        }
        // Then destroy current instrument
        if (self.instrument_ptr.load(.acquire)) |inst| {
            inst.destroy(self.allocator);
            self.instrument_ptr.store(null, .release);
        }
        if (self.clips_initialized) {
            self.clips.deinit();
        }
    }

    /// Load audio file into track
    pub fn loadFile(self: *Track, path: []const u8) !void {
        // Free existing clip if any
        if (self.clip) |*clip| {
            clip.deinit();
        }

        self.clip = try AudioClip.fromWav(self.allocator, path);
        log.info("Loaded file into track: {s}", .{path});
    }

    /// Load audio from a buffer (copies data)
    pub fn loadFromBuffer(self: *Track, samples: []const f32, num_channels: u8, sample_rate: u32) !void {
        // Free existing clip if any
        if (self.clip) |*clip| {
            clip.deinit();
        }

        // Copy the samples
        const owned_samples = try self.allocator.dupe(f32, samples);
        const num_frames = samples.len / num_channels;

        self.clip = AudioClip{
            .allocator = self.allocator,
            .samples = owned_samples,
            .num_channels = num_channels,
            .sample_rate = sample_rate,
            .num_frames = num_frames,
        };

        log.info("Loaded {} samples from buffer into track ({} frames, {} ch, {}Hz)", .{
            samples.len, num_frames, num_channels, sample_rate,
        });
    }

    /// Set instrument on this track (thread-safe)
    pub fn setInstrument(self: *Track, instrument_type: instruments.InstrumentType) !void {
        // First, destroy any previously pending instrument (safe, not used by audio thread)
        if (self.pending_destroy) |old_pending| {
            old_pending.destroy(self.allocator);
            self.pending_destroy = null;
        }

        // Create the new instrument
        const new_instrument = try instruments.createInstrument(self.allocator, instrument_type);
        self.instrument_type = instrument_type;

        // Atomically swap in the new instrument and get the old one
        const old_instrument = self.instrument_ptr.swap(new_instrument, .acq_rel);

        // Schedule old instrument for destruction on next call
        // This gives the audio thread time to stop using it
        if (old_instrument) |old| {
            self.pending_destroy = old;
        }

        log.info("Set instrument on track: {s}", .{new_instrument.name});
    }

    /// Remove instrument from track (thread-safe)
    pub fn removeInstrument(self: *Track) void {
        // Destroy pending first
        if (self.pending_destroy) |old_pending| {
            old_pending.destroy(self.allocator);
            self.pending_destroy = null;
        }

        // Atomically remove current instrument
        const old_instrument = self.instrument_ptr.swap(null, .acq_rel);
        self.instrument_type = null;
        if (old_instrument) |old| {
            self.pending_destroy = old;
        }
    }

    /// Process audio for this track (called from audio thread)
    /// Output buffer is stereo interleaved, already cleared by caller
    pub fn process(self: *Track, output: []f32, sample_rate: u32) void {
        self.processPanned(output, sample_rate, null, &.{});
    }

    /// Same as `process`, but `pan_curve` (one pan value per frame) replaces the manual pan, and
    /// `events` (sorted by frame) are played on their own frames: the instrument is rendered in
    /// sub-blocks split at each event, so timing does not depend on the block size.
    pub fn processPanned(self: *Track, output: []f32, sample_rate: u32, pan_curve: ?[]const f32, events: []const ClipEvent) void {
        const num_frames = output.len / 2;

        // Process instrument if present (atomic load for thread safety)
        if (self.instrument_ptr.load(.acquire)) |inst| {
            var cursor: usize = 0;
            for (events) |event| {
                const at = @min(@as(usize, event.frame), num_frames);
                if (at > cursor) {
                    inst.process(output[cursor * 2 .. at * 2], sample_rate);
                    cursor = at;
                }
                if (event.on) {
                    inst.noteOn(event.pitch, event.velocity);
                    self.is_active = true;
                } else {
                    inst.noteOff(event.pitch);
                }
            }
            if (cursor < num_frames) inst.process(output[cursor * 2 ..], sample_rate);
        }

        // Process audio clip if present (mixes with instrument)
        if (self.clip) |*clip| {
            // Temporary buffer for clip audio
            var clip_buffer: [4096]f32 = undefined;
            const clip_buf = clip_buffer[0 .. num_frames * 2];
            @memset(clip_buf, 0.0);

            const frames_read = clip.read(clip_buf, num_frames, sample_rate);

            // Mix clip into output
            for (0..frames_read * 2) |i| {
                output[i] += clip_buf[i];
            }
        }

        if (pan_curve) |curve| {
            for (0..num_frames) |i| {
                const pan = curve[i];
                output[i * 2] *= 1.0 - @max(0.0, pan);
                output[i * 2 + 1] *= 1.0 + @min(0.0, pan);
            }
            return;
        }

        // Apply pan (volume is applied by engine)
        const pan = self.getPan();
        const left_gain = 1.0 - @max(0.0, pan);
        const right_gain = 1.0 + @min(0.0, pan);

        for (0..num_frames) |i| {
            output[i * 2] *= left_gain;
            output[i * 2 + 1] *= right_gain;
        }
    }

    /// Reset playback to beginning
    pub fn reset(self: *Track) void {
        if (self.clip) |*clip| {
            clip.reset();
        }
    }

    /// Send MIDI note to instrument
    pub fn noteOn(self: *Track, note: u8, velocity: u8) void {
        if (self.instrument_ptr.load(.acquire)) |inst| {
            inst.noteOn(note, velocity);
            self.is_active = true;
        }
    }

    pub fn noteOff(self: *Track, note: u8) void {
        if (self.instrument_ptr.load(.acquire)) |inst| {
            inst.noteOff(note);
        }
    }

    /// Check if the track has active content
    pub fn hasActiveContent(self: *const Track) bool {
        // Check if instrument has active voices
        if (self.instrument_ptr.load(.acquire)) |inst| {
            // Instruments are active if they have non-idle voices
            // For now, assume instrument is active if it exists
            _ = inst;
        }

        // Check if any clips are currently playing
        for (self.clips.clips.items) |clip| {
            // A clip is active if we're within its time range
            // This would need the current playback position
            _ = clip;
        }

        return self.is_active;
    }
};

test "audio clip basic" {
    const testing = std.testing;

    const sample_data = [_]f32{ 1.0, 0.5, -0.5, -1.0 }; // 2 stereo frames
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 2,
    };

    try testing.expectEqual(@as(u64, 0), clip.position);
    try testing.expect(!clip.isFinished());

    clip.seek(1);
    try testing.expectEqual(@as(u64, 1), clip.position);

    clip.seek(10); // Beyond end
    try testing.expectEqual(@as(u64, 2), clip.position);
    try testing.expect(clip.isFinished());
}

// =============================================================================
// Comprehensive Tests
// =============================================================================

test "AudioClip - reset position" {
    const testing = std.testing;

    const sample_data = [_]f32{ 1.0, 0.5, -0.5, -1.0 };
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 2,
    };

    clip.seek(2);
    try testing.expect(clip.isFinished());

    clip.reset();
    try testing.expectEqual(@as(u64, 0), clip.position);
    try testing.expect(!clip.isFinished());
}

test "AudioClip - mono to stereo conversion" {
    const testing = std.testing;

    // Mono clip: 4 frames
    const sample_data = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 1,
        .sample_rate = 48000,
        .num_frames = 4,
    };

    var output: [8]f32 = undefined; // 4 frames * 2 channels
    const frames_read = clip.read(&output, 4, 48000);

    try testing.expectEqual(@as(usize, 4), frames_read);
    try testing.expectEqual(@as(u64, 4), clip.position);

    // Each mono sample should be duplicated to L+R
    try testing.expectApproxEqAbs(@as(f32, 0.1), output[0], 0.001); // L
    try testing.expectApproxEqAbs(@as(f32, 0.1), output[1], 0.001); // R
    try testing.expectApproxEqAbs(@as(f32, 0.2), output[2], 0.001); // L
    try testing.expectApproxEqAbs(@as(f32, 0.2), output[3], 0.001); // R
}

test "AudioClip - stereo to stereo copy" {
    const testing = std.testing;

    // Stereo clip: 2 frames
    const sample_data = [_]f32{ 0.1, 0.2, 0.3, 0.4 }; // L1, R1, L2, R2
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 2,
    };

    var output: [4]f32 = undefined;
    const frames_read = clip.read(&output, 2, 48000);

    try testing.expectEqual(@as(usize, 2), frames_read);
    try testing.expectApproxEqAbs(@as(f32, 0.1), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), output[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), output[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), output[3], 0.001);
}

test "AudioClip - multi-channel downmix to stereo" {
    const testing = std.testing;

    // 4-channel clip: 1 frame (L, R, C, LFE)
    const sample_data = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 4,
        .sample_rate = 48000,
        .num_frames = 1,
    };

    var output: [2]f32 = undefined;
    const frames_read = clip.read(&output, 1, 48000);

    try testing.expectEqual(@as(usize, 1), frames_read);

    // Left: average of ch0 and ch2: (0.1 + 0.3) / 2 = 0.2
    // Right: average of ch1 and ch3: (0.2 + 0.4) / 2 = 0.3
    try testing.expectApproxEqAbs(@as(f32, 0.2), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), output[1], 0.001);
}

test "AudioClip - read at end returns zero" {
    const testing = std.testing;

    const sample_data = [_]f32{ 1.0, 0.5 };
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 1,
    };

    clip.seek(1); // Move to end
    var output: [2]f32 = undefined;
    const frames_read = clip.read(&output, 1, 48000);

    try testing.expectEqual(@as(usize, 0), frames_read);
}

test "AudioClip - partial read at end" {
    const testing = std.testing;

    const sample_data = [_]f32{ 1.0, 0.5, -0.5, -1.0, 0.0, 0.0 }; // 3 stereo frames
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = @constCast(&sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 3,
    };

    clip.seek(2); // Position at frame 2 (last frame)
    var output: [8]f32 = undefined;
    const frames_read = clip.read(&output, 4, 48000); // Request 4 frames, only 1 available

    try testing.expectEqual(@as(usize, 1), frames_read);
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), output[1], 0.001);
}

test "Track - initialization" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    try testing.expectEqual(@as(?AudioClip, null), track.clip);
    try testing.expectEqual(@as(?*Instrument, null), track.getInstrument());
    try testing.expectApproxEqAbs(@as(f32, 0.75), track.volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), track.pan, 0.001);
    try testing.expect(track.clips_initialized);
}

test "Track - pan application left" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    track.pan = -1.0; // Full left

    // Manually calculate pan gains
    const left_gain = 1.0 - @max(0.0, track.pan); // 1.0 - 0.0 = 1.0
    const right_gain = 1.0 + @min(0.0, track.pan); // 1.0 + (-1.0) = 0.0

    try testing.expectApproxEqAbs(@as(f32, 1.0), left_gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), right_gain, 0.001);
}

test "Track - pan application right" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    track.pan = 1.0; // Full right

    const left_gain = 1.0 - @max(0.0, track.pan); // 1.0 - 1.0 = 0.0
    const right_gain = 1.0 + @min(0.0, track.pan); // 1.0 + 0.0 = 1.0

    try testing.expectApproxEqAbs(@as(f32, 0.0), left_gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right_gain, 0.001);
}

test "Track - pan application center" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    track.pan = 0.0; // Center

    const left_gain = 1.0 - @max(0.0, track.pan); // 1.0 - 0.0 = 1.0
    const right_gain = 1.0 + @min(0.0, track.pan); // 1.0 + 0.0 = 1.0

    try testing.expectApproxEqAbs(@as(f32, 1.0), left_gain, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right_gain, 0.001);
}

test "Track - reset" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    // Add a clip and advance it (use dupe since deinit will free it)
    const sample_data = [_]f32{ 1.0, 0.5, -0.5, -1.0 };
    var clip = AudioClip{
        .allocator = testing.allocator,
        .samples = try testing.allocator.dupe(f32, &sample_data),
        .num_channels = 2,
        .sample_rate = 48000,
        .num_frames = 2,
    };
    clip.seek(1);
    track.clip = clip;

    try testing.expectEqual(@as(u64, 1), track.clip.?.position);

    track.reset();
    try testing.expectEqual(@as(u64, 0), track.clip.?.position);
}

test "Track - process with no clip or instrument" {
    const testing = std.testing;

    var track = Track.init(testing.allocator);
    defer track.deinit();

    var output = @as([128]f32, @splat(0.0)); // 64 stereo frames
    track.process(&output, 48000);

    // With no clip/instrument and pan=0, output should remain zeros (after pan application)
    // Actually the pan gains are both 1.0 at center, so 0 * 1.0 = 0
    for (output) |sample| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), sample, 0.001);
    }
}

test "Track - instruments produce audible output after noteOn" {
    const testing = std.testing;
    const types = [_]instruments.InstrumentType{ .keys, .wavetable_synth };
    for (types) |t| {
        var track = Track.init(testing.allocator);
        defer track.deinit();
        try track.setInstrument(t);
        track.noteOn(60, 100);

        var buf: [1024]f32 = @splat(0.0); // 512 stereo frames
        track.process(&buf, 48000);

        var peak: f32 = 0.0;
        for (buf) |s| peak = @max(peak, @abs(s));
        std.debug.print("{s}: peak={d}\n", .{ t.name(), peak });
        try testing.expect(peak > 0.001);
    }
}
