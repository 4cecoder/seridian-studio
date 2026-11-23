/// ACTUAL AUDIO PLAYBACK TEST
///
/// This test verifies that audio ACTUALLY plays through the speakers, not just that callbacks happen.
///
/// What it does:
/// 1. Initializes the full audio engine with PulseAudio backend
/// 2. Generates a 440Hz sine wave (A4 note) and loads it into track 0
/// 3. Starts playback for 3 seconds
/// 4. Prints "If you hear a 440Hz tone, playback is WORKING"
/// 5. Stops and cleans up
///
/// Run as: zig build-exe tests/test_actual_playback.zig -lc -lpulse -I/usr/include && ./test_actual_playback
/// Or: zig run tests/test_actual_playback.zig -lc -lpulse -I/usr/include

const std = @import("std");
const engine_mod = @import("audio/engine.zig");
const AudioEngine = engine_mod.AudioEngine;
const EngineConfig = engine_mod.EngineConfig;

/// Generate a sine wave test tone
fn generateSineWave(allocator: std.mem.Allocator, frequency: f32, duration_seconds: f32, sample_rate: u32) ![]f32 {
    const num_frames = @as(usize, @intFromFloat(duration_seconds * @as(f32, @floatFromInt(sample_rate))));
    const num_samples = num_frames * 2; // stereo

    const samples = try allocator.alloc(f32, num_samples);

    const sample_rate_f: f32 = @floatFromInt(sample_rate);
    const two_pi = 2.0 * std.math.pi;
    const phase_increment = (two_pi * frequency) / sample_rate_f;

    var phase: f32 = 0.0;
    var i: usize = 0;
    while (i < num_frames) : (i += 1) {
        const sample = @sin(phase) * 0.3; // 0.3 amplitude to avoid clipping
        samples[i * 2] = sample;      // Left channel
        samples[i * 2 + 1] = sample;  // Right channel
        phase += phase_increment;

        // Wrap phase to prevent accumulation errors
        if (phase >= two_pi) {
            phase -= two_pi;
        }
    }

    return samples;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("ERROR: Memory leak detected!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("  ACTUAL AUDIO PLAYBACK TEST\n", .{});
    std.debug.print("  Testing end-to-end audio output to speakers\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});

    // Configuration
    const sample_rate: u32 = 48000;
    const buffer_size: u32 = 512;
    const tone_frequency: f32 = 440.0; // A4 note
    const tone_duration: f32 = 5.0; // Generate 5 seconds of audio
    const playback_duration_ms: u64 = 3000; // Play for 3 seconds

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Sample Rate:      {d} Hz\n", .{sample_rate});
    std.debug.print("  Buffer Size:      {d} samples\n", .{buffer_size});
    std.debug.print("  Test Tone:        {d} Hz (A4)\n", .{tone_frequency});
    std.debug.print("  Playback Duration: {d} seconds\n", .{playback_duration_ms / 1000});
    std.debug.print("\n", .{});

    // Step 1: Generate test tone
    std.debug.print("[1/6] Generating {d}Hz sine wave...\n", .{tone_frequency});
    const test_tone = try generateSineWave(allocator, tone_frequency, tone_duration, sample_rate);
    defer allocator.free(test_tone);

    const num_frames = test_tone.len / 2;
    std.debug.print("  SUCCESS: Generated {d} frames ({d:.2} seconds)\n", .{
        num_frames,
        @as(f32, @floatFromInt(num_frames)) / @as(f32, @floatFromInt(sample_rate))
    });
    std.debug.print("\n", .{});

    // Step 2: Initialize audio engine
    std.debug.print("[2/6] Initializing AudioEngine with PulseAudio...\n", .{});
    var engine = AudioEngine.init(allocator, .{
        .sample_rate = sample_rate,
        .buffer_size = buffer_size,
        .backend_preference = "pulseaudio",
    }) catch |err| {
        std.debug.print("FAIL: Could not initialize AudioEngine: {}\n", .{err});
        std.debug.print("This test requires PulseAudio to be available.\n", .{});
        std.process.exit(1);
    };
    defer engine.deinit();

    const backend_type = @tagName(engine.backend);
    std.debug.print("  SUCCESS: Engine initialized with {s} backend\n", .{backend_type});

    // Verify it's PulseAudio
    if (engine.backend != .pulseaudio) {
        std.debug.print("FAIL: Expected PulseAudio backend, got {s}\n", .{backend_type});
        std.process.exit(1);
    }
    std.debug.print("\n", .{});

    // Step 3: Connect backend to engine (also prepares the stream)
    std.debug.print("[3/6] Connecting backend to engine...\n", .{});
    engine.connectBackend() catch |err| {
        std.debug.print("FAIL: Could not connect and prepare backend: {}\n", .{err});
        std.debug.print("Audio backend may not be running on this system.\n", .{});
        std.process.exit(1);
    };

    std.debug.print("  SUCCESS: Backend connected and prepared\n", .{});
    std.debug.print("\n", .{});

    // Step 4: Load test tone into track 0
    std.debug.print("[4/6] Loading test tone into track 0...\n", .{});
    try engine.tracks[0].loadFromBuffer(test_tone, 2, sample_rate);

    // Unmute track 0 and set reasonable gain
    engine.setTrackMute(0, false);
    engine.setTrackGain(0, 0.75);
    engine.setMasterGain(0.75);

    std.debug.print("  SUCCESS: Test tone loaded into track 0\n", .{});
    std.debug.print("  Track 0: gain={d:.2}, muted={}\n", .{
        engine.getTrackGain(0),
        engine.getTrackMute(0),
    });
    std.debug.print("  Master: gain={d:.2}\n", .{engine.getMasterGain()});
    std.debug.print("\n", .{});

    // Step 5: Start playback
    std.debug.print("[5/6] Starting playback...\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  ╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ║  If you hear a 440Hz tone, playback is WORKING!         ║\n", .{});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ║  (Playing for {d} seconds...)                              ║\n", .{playback_duration_ms / 1000});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    try engine.start();

    std.debug.print("DEBUG: About to sleep for {d}ms\n", .{playback_duration_ms});

    // Let it play for the specified duration
    // Note: nanosleep requires nanoseconds < 1 billion, so we need to split into seconds + nanoseconds
    const sleep_seconds = playback_duration_ms / 1000;
    const sleep_ns = (playback_duration_ms % 1000) * std.time.ns_per_ms;
    std.posix.nanosleep(sleep_seconds, sleep_ns);

    std.debug.print("DEBUG: Sleep completed after {d} seconds\n", .{sleep_seconds});
    std.debug.print("\n", .{});

    // Step 6: Stop playback
    std.debug.print("[6/6] Stopping playback...\n", .{});
    engine.stop();

    // Wait a bit for cleanup
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    std.debug.print("  SUCCESS: Playback stopped\n", .{});
    std.debug.print("\n", .{});

    // Print summary
    std.debug.print("===========================================================\n", .{});
    std.debug.print("  TEST COMPLETED\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("If you heard a clear 440Hz tone (musical note A4), then:\n", .{});
    std.debug.print("  ✓ Audio engine initialization works\n", .{});
    std.debug.print("  ✓ PulseAudio backend initialization works\n", .{});
    std.debug.print("  ✓ Engine-to-backend connection works\n", .{});
    std.debug.print("  ✓ Audio buffer loading works\n", .{});
    std.debug.print("  ✓ Playback start/stop works\n", .{});
    std.debug.print("  ✓ ACTUAL audio output to speakers works\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("This proves end-to-end audio playback is functional!\n", .{});
    std.debug.print("\n", .{});

    std.process.exit(0);
}
