/// MIDI PLAYBACK DIAGNOSTIC TEST
///
/// This test verifies that MIDI notes trigger the Keys instrument and produce audible output.
/// It plays a simple C major chord for 3 seconds.
const std = @import("std");
const engine_mod = @import("audio/engine.zig");
const AudioEngine = engine_mod.AudioEngine;

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
    std.debug.print("  MIDI PLAYBACK DIAGNOSTIC TEST\n", .{});
    std.debug.print("  Testing Keys instrument with C major chord\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});

    const sample_rate: u32 = 48000;
    const buffer_size: u32 = 512;

    // Initialize audio engine
    std.debug.print("[1/5] Initializing AudioEngine...\n", .{});
    var engine = AudioEngine.init(allocator, .{
        .sample_rate = sample_rate,
        .buffer_size = buffer_size,
        .backend_preference = "pulseaudio",
    }) catch |err| {
        std.debug.print("FAIL: Could not initialize AudioEngine: {}\n", .{err});
        std.process.exit(1);
    };
    defer engine.deinit();
    std.debug.print("  SUCCESS: Engine initialized\n\n", .{});

    // Connect backend
    std.debug.print("[2/5] Connecting backend...\n", .{});
    engine.connectBackend() catch |err| {
        std.debug.print("FAIL: Could not connect backend: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("  SUCCESS: Backend connected\n\n", .{});

    // Set up track 0 with Keys instrument and unmute
    std.debug.print("[3/5] Setting up track 0 with Keys instrument...\n", .{});
    engine.setTrackMute(0, false);
    engine.setTrackGain(0, 1.0); // Max gain
    engine.setMasterGain(1.0); // Max master gain
    std.debug.print("  Track 0: gain=1.0, muted=false\n", .{});
    std.debug.print("  Master: gain=1.0\n\n", .{});

    // Start playback
    std.debug.print("[4/5] Starting playback...\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  ╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ║  Playing C major chord (C-E-G) for 3 seconds...         ║\n", .{});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ║  If you hear a chord, MIDI playback is WORKING!         ║\n", .{});
    std.debug.print("  ║                                                          ║\n", .{});
    std.debug.print("  ╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    try engine.start();

    // Trigger C major chord (C4=60, E4=64, G4=67)
    std.debug.print("  >> Triggering notes: C4(60), E4(64), G4(67)\n", .{});
    engine.tracks[0].noteOn(60, 100); // C4
    engine.tracks[0].noteOn(64, 90); // E4
    engine.tracks[0].noteOn(67, 85); // G4

    // Play for 3 seconds
    const playback_seconds: u64 = 3;
    std.posix.nanosleep(playback_seconds, 0);

    // Release notes
    std.debug.print("  >> Releasing notes\n", .{});
    engine.tracks[0].noteOff(60);
    engine.tracks[0].noteOff(64);
    engine.tracks[0].noteOff(67);

    // Let the release tail play out (1 second)
    std.posix.nanosleep(1, 0);

    std.debug.print("\n", .{});

    // Stop playback
    std.debug.print("[5/5] Stopping playback...\n", .{});
    engine.stop();
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
    std.debug.print("  SUCCESS: Playback stopped\n\n", .{});

    // Print summary
    std.debug.print("===========================================================\n", .{});
    std.debug.print("  TEST COMPLETED\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("If you heard a C major chord:\n", .{});
    std.debug.print("  ✓ Keys instrument is working\n", .{});
    std.debug.print("  ✓ MIDI note triggering works\n", .{});
    std.debug.print("  ✓ MIDI playback is functional\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("If you heard NOTHING:\n", .{});
    std.debug.print("  ✗ Check your audio output device selection\n", .{});
    std.debug.print("  ✗ Check your system volume\n", .{});
    std.debug.print("  ✗ Try: pactl list sinks short\n", .{});
    std.debug.print("\n", .{});

    std.process.exit(0);
}
