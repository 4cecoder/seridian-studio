// Audio Engine Runtime Test
// Tests that the audio engine processes buffers correctly in isolation (no backend)

const std = @import("std");

// Create a local module that can import from parent paths
const audio_engine = @import("audio/engine.zig");
const AudioEngine = audio_engine.AudioEngine;
const EngineConfig = audio_engine.EngineConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎵 Audio Engine Runtime Tests\n", .{});
    std.debug.print("==============================\n\n", .{});

    // Test 1: Engine initialization
    std.debug.print("1. Testing engine initialization...\n", .{});
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();
    std.debug.print("   ✓ Engine initialized (48000 Hz, 512 samples)\n", .{});

    // Test 2: Initial state verification
    std.debug.print("\n2. Verifying initial state...\n", .{});
    try std.testing.expectEqual(@as(u64, 0), engine.getPosition());
    try std.testing.expect(!engine.isPlaying());
    try std.testing.expect(!engine.isRecording());
    std.debug.print("   ✓ Position: 0, Playing: false, Recording: false\n", .{});

    // Test 3: Process with empty engine (silent output)
    std.debug.print("\n3. Testing process() with empty engine...\n", .{});
    var output_buffer = @as([1024]f32, @splat(999.0)); // 512 stereo frames, pre-filled with non-zero
    engine.process(&output_buffer);

    // Verify output is silent
    var has_non_zero = false;
    for (output_buffer) |sample| {
        if (@abs(sample) > 0.001) {
            has_non_zero = true;
            break;
        }
    }
    try std.testing.expect(!has_non_zero);
    std.debug.print("   ✓ Output is silent (all zeros)\n", .{});

    // Test 4: Position advances when playing
    std.debug.print("\n4. Testing transport position advancement...\n", .{});
    engine.playing.store(false, .monotonic);
    engine.process(&output_buffer);
    try std.testing.expectEqual(@as(u64, 0), engine.getPosition());
    std.debug.print("   ✓ Position stays at 0 when not playing\n", .{});

    engine.playing.store(true, .monotonic);
    engine.process(&output_buffer);
    try std.testing.expectEqual(@as(u64, 512), engine.getPosition());
    std.debug.print("   ✓ Position advanced to 512 when playing\n", .{});

    engine.process(&output_buffer);
    try std.testing.expectEqual(@as(u64, 1024), engine.getPosition());
    std.debug.print("   ✓ Position advanced to 1024 after second buffer\n", .{});

    engine.playing.store(false, .monotonic);
    engine.resetTracks();
    std.debug.print("   ✓ Position reset to 0\n", .{});

    // Test 5: Add audio data to track and verify processing
    std.debug.print("\n5. Testing with audio data on track...\n", .{});

    // Create test audio: simple sine-like pattern
    const num_frames: usize = 1000;
    var test_samples = try allocator.alloc(f32, num_frames * 2); // Stereo
    defer allocator.free(test_samples);

    for (0..num_frames) |i| {
        const phase: f32 = @as(f32, @floatFromInt(i)) / 100.0;
        const sample = @sin(phase) * 0.5; // 50% amplitude
        test_samples[i * 2] = sample; // Left
        test_samples[i * 2 + 1] = sample; // Right
    }

    // Load audio into track 0
    try engine.tracks[0].loadFromBuffer(test_samples, 2, 48000);
    std.debug.print("   ✓ Loaded {} stereo frames into track 0\n", .{num_frames});

    // Process and verify output contains audio
    engine.playing.store(true, .monotonic);
    var audio_output = @as([1024]f32, @splat(0.0)); // 512 stereo frames
    engine.process(&audio_output);

    var peak: f32 = 0.0;
    for (audio_output) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak) peak = abs_sample;
    }

    try std.testing.expect(peak > 0.1); // Should have significant audio
    std.debug.print("   ✓ Output contains audio (peak: {d:.3})\n", .{peak});

    // Test 6: Verify gain controls affect output
    std.debug.print("\n6. Testing gain controls...\n", .{});

    // Reset track position
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();

    // Process with default gain (0.75 track * 0.75 master = 0.5625)
    var output_normal = @as([1024]f32, @splat(0.0));
    engine.process(&output_normal);
    var peak_normal: f32 = 0.0;
    for (output_normal) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_normal) peak_normal = abs_sample;
    }

    // Reset and process with master gain at 0
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();
    engine.setMasterGain(0.0);
    var output_silent = @as([1024]f32, @splat(0.0));
    engine.process(&output_silent);
    var peak_silent: f32 = 0.0;
    for (output_silent) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_silent) peak_silent = abs_sample;
    }

    try std.testing.expect(peak_normal > 0.1);
    try std.testing.expect(peak_silent < 0.001);
    std.debug.print("   ✓ Normal gain peak: {d:.3}\n", .{peak_normal});
    std.debug.print("   ✓ Zero gain peak: {d:.6} (silent)\n", .{peak_silent});

    // Restore gain
    engine.setMasterGain(0.75);

    // Test 7: Test mute functionality
    std.debug.print("\n7. Testing mute controls...\n", .{});
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();

    // Process with track unmuted
    var output_unmuted = @as([1024]f32, @splat(0.0));
    engine.process(&output_unmuted);
    var peak_unmuted: f32 = 0.0;
    for (output_unmuted) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_unmuted) peak_unmuted = abs_sample;
    }

    // Reset and mute track
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();
    engine.setTrackMute(0, true);
    var output_muted = @as([1024]f32, @splat(0.0));
    engine.process(&output_muted);
    var peak_muted: f32 = 0.0;
    for (output_muted) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_muted) peak_muted = abs_sample;
    }

    try std.testing.expect(peak_unmuted > 0.1);
    try std.testing.expect(peak_muted < 0.001);
    std.debug.print("   ✓ Unmuted peak: {d:.3}\n", .{peak_unmuted});
    std.debug.print("   ✓ Muted peak: {d:.6} (silent)\n", .{peak_muted});

    engine.setTrackMute(0, false);

    // Test 8: Test with different buffer sizes
    std.debug.print("\n8. Testing with different buffer sizes...\n", .{});

    const buffer_sizes = [_]usize{ 64, 128, 256, 512, 1024, 2048 };
    for (buffer_sizes) |size| {
        if (engine.tracks[0].getClip()) |clip| {
            clip.reset();
        }
        engine.resetTracks();

        const test_buffer = try allocator.alloc(f32, size * 2); // Stereo
        defer allocator.free(test_buffer);
        @memset(test_buffer, 0.0);

        engine.process(test_buffer);

        var buffer_peak: f32 = 0.0;
        for (test_buffer) |sample| {
            const abs_sample = @abs(sample);
            if (abs_sample > buffer_peak) buffer_peak = abs_sample;
        }

        try std.testing.expect(buffer_peak > 0.05);
        std.debug.print("   ✓ Buffer size {d:4}: peak = {d:.3}\n", .{ size, buffer_peak });
    }

    // Test 9: Verify metering
    std.debug.print("\n9. Testing metering...\n", .{});
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();

    var meter_output = @as([1024]f32, @splat(0.0));
    engine.process(&meter_output);

    const track0_meter = engine.getTrackMeter(0);
    const master_left = engine.getMasterMeterLeft();
    const master_right = engine.getMasterMeterRight();

    try std.testing.expect(track0_meter > 0.05);
    try std.testing.expect(master_left > 0.05);
    try std.testing.expect(master_right > 0.05);
    std.debug.print("   ✓ Track 0 meter: {d:.3}\n", .{track0_meter});
    std.debug.print("   ✓ Master L meter: {d:.3}\n", .{master_left});
    std.debug.print("   ✓ Master R meter: {d:.3}\n", .{master_right});

    // Test 10: Test solo functionality
    std.debug.print("\n10. Testing solo controls...\n", .{});

    // Add audio to track 1 as well
    try engine.tracks[1].loadFromBuffer(test_samples, 2, 48000);

    // Reset both tracks
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    if (engine.tracks[1].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();

    // Process with no solo - both tracks should be audible
    var output_no_solo = @as([1024]f32, @splat(0.0));
    engine.process(&output_no_solo);
    var peak_no_solo: f32 = 0.0;
    for (output_no_solo) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_no_solo) peak_no_solo = abs_sample;
    }

    // Reset and solo track 0
    if (engine.tracks[0].getClip()) |clip| {
        clip.reset();
    }
    if (engine.tracks[1].getClip()) |clip| {
        clip.reset();
    }
    engine.resetTracks();
    engine.setTrackSolo(0, true);

    var output_solo = @as([1024]f32, @splat(0.0));
    engine.process(&output_solo);
    var peak_solo: f32 = 0.0;
    for (output_solo) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_solo) peak_solo = abs_sample;
    }

    const track1_meter = engine.getTrackMeter(1);

    try std.testing.expect(peak_no_solo > 0.1);
    try std.testing.expect(peak_solo > 0.05);
    try std.testing.expect(track1_meter < 0.001); // Track 1 should be silent (not soloed)
    std.debug.print("   ✓ Both tracks peak: {d:.3}\n", .{peak_no_solo});
    std.debug.print("   ✓ Track 0 solo peak: {d:.3}\n", .{peak_solo});
    std.debug.print("   ✓ Track 1 meter (should be silent): {d:.6}\n", .{track1_meter});

    engine.setTrackSolo(0, false);

    // Test 11: Audio health monitoring
    std.debug.print("\n11. Testing audio health monitoring...\n", .{});
    const stats = engine.getAudioHealthStats();
    std.debug.print("   ✓ NaN/Inf count: {d}\n", .{stats.nan_inf_count});
    std.debug.print("   ✓ Clip count: {d}\n", .{stats.clip_count});

    // Reset stats
    engine.resetAudioHealthStats();
    const stats_after = engine.getAudioHealthStats();
    try std.testing.expectEqual(@as(u64, 0), stats_after.nan_inf_count);
    try std.testing.expectEqual(@as(u64, 0), stats_after.clip_count);
    std.debug.print("   ✓ Stats reset successfully\n", .{});

    // Test 12: Playback start/stop
    std.debug.print("\n12. Testing playback start/stop...\n", .{});
    engine.playing.store(false, .monotonic);
    try std.testing.expect(!engine.isPlaying());
    std.debug.print("   ✓ Playback stopped\n", .{});

    engine.playing.store(true, .monotonic);
    try std.testing.expect(engine.isPlaying());
    std.debug.print("   ✓ Playback started\n", .{});

    engine.playing.store(false, .monotonic);
    try std.testing.expect(!engine.isPlaying());
    std.debug.print("   ✓ Playback stopped again\n", .{});

    std.debug.print("\n==============================\n", .{});
    std.debug.print("✅ All audio engine runtime tests passed!\n\n", .{});

    std.debug.print("Summary:\n", .{});
    std.debug.print("  - Engine processes buffers correctly\n", .{});
    std.debug.print("  - Transport position advances properly\n", .{});
    std.debug.print("  - Audio data flows through tracks\n", .{});
    std.debug.print("  - Gain controls work correctly\n", .{});
    std.debug.print("  - Mute/Solo functions properly\n", .{});
    std.debug.print("  - Multiple buffer sizes supported\n", .{});
    std.debug.print("  - Metering functions correctly\n", .{});
    std.debug.print("  - Health monitoring works\n", .{});
    std.debug.print("\n✓ Audio engine is backend-independent and functional!\n\n", .{});
}
