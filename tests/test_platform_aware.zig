//! Platform-aware test runner example
//!
//! This demonstrates how to use the platform_config.zig framework to run
//! backend-specific tests only when the backend is available.
//!
//! Run with: zig build test-platform-aware
//!
//! Expected behavior:
//! - On Linux: runs PulseAudio and PipeWire tests (if available)
//! - On macOS: runs CoreAudio tests only
//! - On Windows: runs WASAPI tests only (when implemented)
//!
//! Tests are automatically skipped if the backend is not available.

const std = @import("std");
const platform_config = @import("platform_config.zig");

// =============================================================================
// Example test functions for each backend
// =============================================================================

fn testPulseAudioInit() !void {
    // Simulate a PulseAudio initialization test
    std.debug.print("Testing PulseAudio initialization...\n", .{});
    // In a real test, this would initialize the PulseAudio backend
}

fn testPulseAudioPlayback() !void {
    // Simulate a PulseAudio playback test
    std.debug.print("Testing PulseAudio playback...\n", .{});
    // In a real test, this would test audio playback
}

fn testPulseAudioRecording() !void {
    // Simulate a PulseAudio recording test
    std.debug.print("Testing PulseAudio recording...\n", .{});
    // In a real test, this would test audio recording
}

fn testPipeWireInit() !void {
    // Simulate a PipeWire initialization test
    std.debug.print("Testing PipeWire initialization...\n", .{});
    // In a real test, this would initialize the PipeWire backend
}

fn testPipeWirePlayback() !void {
    // Simulate a PipeWire playback test
    std.debug.print("Testing PipeWire playback...\n", .{});
    // In a real test, this would test audio playback
}

fn testPipeWireRecording() !void {
    // Simulate a PipeWire recording test
    std.debug.print("Testing PipeWire recording...\n", .{});
    // In a real test, this would test audio recording
}

fn testCoreAudioInit() !void {
    // Simulate a CoreAudio initialization test
    std.debug.print("Testing CoreAudio initialization...\n", .{});
    // In a real test, this would initialize the CoreAudio backend
}

fn testCoreAudioPlayback() !void {
    // Simulate a CoreAudio playback test
    std.debug.print("Testing CoreAudio playback...\n", .{});
    // In a real test, this would test audio playback
}

fn testCoreAudioRecording() !void {
    // Simulate a CoreAudio recording test
    std.debug.print("Testing CoreAudio recording...\n", .{});
    // In a real test, this would test audio recording
}

fn testWASAPIInit() !void {
    // Simulate a WASAPI initialization test
    std.debug.print("Testing WASAPI initialization...\n", .{});
    // In a real test, this would initialize the WASAPI backend
}

fn testWASAPIPlayback() !void {
    // Simulate a WASAPI playback test
    std.debug.print("Testing WASAPI playback...\n", .{});
    // In a real test, this would test audio playback
}

fn testWASAPIRecording() !void {
    // Simulate a WASAPI recording test
    std.debug.print("Testing WASAPI recording...\n", .{});
    // In a real test, this would test audio recording
}

// =============================================================================
// Main test runner
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runner = try platform_config.TestRunner.init(allocator);
    defer runner.deinit();

    // Register Linux tests
    try runner.addTest("PulseAudio: Initialization", .pulseaudio, testPulseAudioInit);
    try runner.addTest("PulseAudio: Playback", .pulseaudio, testPulseAudioPlayback);
    try runner.addTest("PulseAudio: Recording", .pulseaudio, testPulseAudioRecording);

    try runner.addTest("PipeWire: Initialization", .pipewire, testPipeWireInit);
    try runner.addTest("PipeWire: Playback", .pipewire, testPipeWirePlayback);
    try runner.addTest("PipeWire: Recording", .pipewire, testPipeWireRecording);

    // Register macOS tests
    try runner.addTest("CoreAudio: Initialization", .coreaudio, testCoreAudioInit);
    try runner.addTest("CoreAudio: Playback", .coreaudio, testCoreAudioPlayback);
    try runner.addTest("CoreAudio: Recording", .coreaudio, testCoreAudioRecording);

    // Register Windows tests
    try runner.addTest("WASAPI: Initialization", .wasapi, testWASAPIInit);
    try runner.addTest("WASAPI: Playback", .wasapi, testWASAPIPlayback);
    try runner.addTest("WASAPI: Recording", .wasapi, testWASAPIRecording);

    // Run all tests (platform-aware)
    runner.run();

    // Print summary
    runner.printReport();
}
