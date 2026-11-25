// Isolated Audio Engine Test
// Tests the audio engine in complete isolation - NO backend required
// This proves the engine's core processing logic works independently

const std = @import("std");
const AudioEngine = @import("audio/engine.zig").AudioEngine;
const EngineConfig = @import("audio/engine.zig").EngineConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ISOLATED AUDIO ENGINE TEST ===\n", .{});
    std.debug.print("Testing engine WITHOUT any backend\n\n", .{});

    // Test 1: Create engine
    std.debug.print("[1] Creating engine...\n", .{});
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();
    std.debug.print("    ✓ Engine created (48000 Hz, 512 samples)\n", .{});

    // Test 2: Add test audio data to a track
    std.debug.print("\n[2] Loading test audio data...\n", .{});

    const num_frames: usize = 2000;
    var test_samples = try allocator.alloc(f32, num_frames * 2); // Stereo
    defer allocator.free(test_samples);

    // Generate sine wave test tone at 440 Hz
    const frequency: f32 = 440.0;
    const sample_rate: f32 = 48000.0;
    for (0..num_frames) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / sample_rate;
        const sample = @sin(2.0 * std.math.pi * frequency * t) * 0.5;
        test_samples[i * 2] = sample; // Left
        test_samples[i * 2 + 1] = sample; // Right
    }

    try engine.tracks[0].loadFromBuffer(test_samples, 2, 48000);
    std.debug.print("    ✓ Loaded {d} stereo frames (440 Hz sine wave)\n", .{num_frames});

    // Test 3: Process buffer directly (no backend)
    std.debug.print("\n[3] Calling process() directly...\n", .{});

    var output_buffer: [1024]f32 = undefined; // 512 stereo frames
    @memset(&output_buffer, 0.0);

    // Enable playback
    engine.playing.store(true, .monotonic);

    // Call process() directly - this is what the backend would call
    engine.process(&output_buffer);

    // Test 4: Verify buffer got filled with audio
    std.debug.print("\n[4] Verifying output buffer...\n", .{});

    var peak: f32 = 0.0;
    var non_zero_count: usize = 0;
    for (output_buffer) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak) peak = abs_sample;
        if (abs_sample > 0.001) non_zero_count += 1;
    }

    const samples_generated = non_zero_count;

    if (peak < 0.01) {
        std.debug.print("    ✗ FAIL: Output is silent (peak = {d:.6})\n", .{peak});
        return error.NoAudioGenerated;
    }

    std.debug.print("    ✓ Buffer filled with audio\n", .{});
    std.debug.print("    ✓ Peak level: {d:.3}\n", .{peak});
    std.debug.print("    ✓ Non-zero samples: {d}/{d}\n", .{ non_zero_count, output_buffer.len });

    // Test 5: Test transport (start/stop)
    std.debug.print("\n[5] Testing transport controls...\n", .{});

    // Verify playing state
    if (!engine.isPlaying()) {
        std.debug.print("    ✗ FAIL: Engine should be playing\n", .{});
        return error.TransportError;
    }
    std.debug.print("    ✓ Engine is playing\n", .{});

    // Stop
    engine.playing.store(false, .monotonic);
    if (engine.isPlaying()) {
        std.debug.print("    ✗ FAIL: Engine should be stopped\n", .{});
        return error.TransportError;
    }
    std.debug.print("    ✓ Engine stopped\n", .{});

    // Start again
    engine.playing.store(true, .monotonic);
    if (!engine.isPlaying()) {
        std.debug.print("    ✗ FAIL: Engine should be playing\n", .{});
        return error.TransportError;
    }
    std.debug.print("    ✓ Engine started again\n", .{});

    // Test 6: Test seek functionality
    std.debug.print("\n[6] Testing seek...\n", .{});

    engine.resetTracks(); // Reset to position 0
    const initial_pos = engine.getPosition();
    if (initial_pos != 0) {
        std.debug.print("    ✗ FAIL: Position should be 0 after reset\n", .{});
        return error.SeekError;
    }
    std.debug.print("    ✓ Reset to position 0\n", .{});

    // Seek to specific position
    engine.position.store(24000, .monotonic); // 0.5 seconds at 48kHz
    const new_pos = engine.getPosition();
    if (new_pos != 24000) {
        std.debug.print("    ✗ FAIL: Seek failed (pos = {d})\n", .{new_pos});
        return error.SeekError;
    }
    std.debug.print("    ✓ Seek to position 24000\n", .{});

    // Test 7: Verify position advances correctly
    std.debug.print("\n[7] Testing position advancement...\n", .{});

    engine.resetTracks();
    const start_pos = engine.getPosition();

    // Process buffer (position should advance by buffer_size)
    engine.playing.store(true, .monotonic);
    @memset(&output_buffer, 0.0);
    engine.process(&output_buffer);

    const pos_after_one = engine.getPosition();
    const advance_one = pos_after_one - start_pos;

    // Process another buffer
    @memset(&output_buffer, 0.0);
    engine.process(&output_buffer);

    const pos_after_two = engine.getPosition();
    const advance_two = pos_after_two - pos_after_one;

    if (advance_one != 512 or advance_two != 512) {
        std.debug.print("    ✗ FAIL: Position should advance by 512 each time\n", .{});
        std.debug.print("    First advance: {d}, Second advance: {d}\n", .{ advance_one, advance_two });
        return error.PositionAdvanceError;
    }

    const total_beats = @as(f64, @floatFromInt(pos_after_two)) / 48000.0 * (120.0 / 60.0);

    std.debug.print("    ✓ Position advanced correctly\n", .{});
    std.debug.print("    ✓ After 1st buffer: {d} samples\n", .{pos_after_one});
    std.debug.print("    ✓ After 2nd buffer: {d} samples\n", .{pos_after_two});
    std.debug.print("    ✓ Total beats (120 BPM): {d:.4}\n", .{total_beats});

    // Test 8: Verify position does NOT advance when stopped
    std.debug.print("\n[8] Testing position when stopped...\n", .{});

    engine.playing.store(false, .monotonic);
    const pos_before = engine.getPosition();

    @memset(&output_buffer, 0.0);
    engine.process(&output_buffer);

    const pos_after = engine.getPosition();

    if (pos_before != pos_after) {
        std.debug.print("    ✗ FAIL: Position should not advance when stopped\n", .{});
        return error.PositionAdvanceError;
    }
    std.debug.print("    ✓ Position unchanged when stopped ({d} samples)\n", .{pos_after});

    // Test 9: Test multiple buffers generate continuous audio
    std.debug.print("\n[9] Testing continuous audio generation...\n", .{});

    engine.resetTracks();
    engine.playing.store(true, .monotonic);

    var total_samples_generated: usize = 0;
    var buffers_processed: usize = 0;

    for (0..5) |_| {
        @memset(&output_buffer, 0.0);
        engine.process(&output_buffer);

        var buffer_non_zero: usize = 0;
        for (output_buffer) |sample| {
            if (@abs(sample) > 0.001) buffer_non_zero += 1;
        }

        total_samples_generated += buffer_non_zero;
        buffers_processed += 1;
    }

    if (total_samples_generated < 100) {
        std.debug.print("    ✗ FAIL: Not enough samples generated\n", .{});
        return error.AudioGenerationError;
    }

    std.debug.print("    ✓ Processed {d} buffers continuously\n", .{buffers_processed});
    std.debug.print("    ✓ Total non-zero samples: {d}\n", .{total_samples_generated});

    // Test 10: Test gain controls affect output
    std.debug.print("\n[10] Testing gain controls...\n", .{});

    engine.resetTracks();
    engine.setMasterGain(1.0);
    engine.setTrackGain(0, 1.0);

    @memset(&output_buffer, 0.0);
    engine.process(&output_buffer);

    var peak_full: f32 = 0.0;
    for (output_buffer) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_full) peak_full = abs_sample;
    }

    // Now with zero gain
    engine.resetTracks();
    engine.setMasterGain(0.0);

    @memset(&output_buffer, 0.0);
    engine.process(&output_buffer);

    var peak_zero: f32 = 0.0;
    for (output_buffer) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak_zero) peak_zero = abs_sample;
    }

    if (peak_full < 0.1 or peak_zero > 0.001) {
        std.debug.print("    ✗ FAIL: Gain controls not working properly\n", .{});
        std.debug.print("    Full gain peak: {d:.3}, Zero gain peak: {d:.6}\n", .{ peak_full, peak_zero });
        return error.GainControlError;
    }

    std.debug.print("    ✓ Full gain peak: {d:.3}\n", .{peak_full});
    std.debug.print("    ✓ Zero gain peak: {d:.6} (silent)\n", .{peak_zero});

    // Final summary
    std.debug.print("\n=== SUMMARY ===\n", .{});
    std.debug.print("Samples generated: {d}\n", .{samples_generated});
    std.debug.print("Position advanced: {d:.4} beats\n", .{total_beats});
    std.debug.print("Result: PASS\n", .{});
    std.debug.print("\n✓ Engine works INDEPENDENTLY of any backend!\n", .{});
    std.debug.print("✓ All isolated tests passed!\n", .{});

    return;
}
