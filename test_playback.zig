/// Test program to verify WAV playback functionality
/// Usage: zig run test_playback.zig -- <path-to-wav-file>
const std = @import("std");
const AudioEngine = @import("src/audio/engine.zig").AudioEngine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get WAV file path from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path-to-wav-file>\n", .{args[0]});
        return error.MissingArgument;
    }

    const wav_path = args[1];

    // Initialize audio engine
    std.debug.print("Initializing audio engine...\n", .{});
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
        .backend_preference = "auto",
    });
    defer engine.deinit();

    // Load WAV file into track 0
    std.debug.print("Loading WAV file: {s}\n", .{wav_path});
    try engine.loadTrackFile(0, wav_path);

    std.debug.print("\nWAV file loaded successfully!\n", .{});
    std.debug.print("Track 0 ready for playback\n", .{});
    std.debug.print("\nTo actually hear audio, integrate with the UI or add audio thread callback.\n", .{});
    std.debug.print("This demonstrates that the WAV loading infrastructure works.\n", .{});
}
