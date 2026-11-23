//! Platform-aware test runner for actual backend tests
//!
//! This runner integrates with the existing backend tests and runs them
//! in a platform-aware manner, automatically skipping tests for unavailable
//! backends.
//!
//! Run with: zig build run-platform-tests
//!
//! This demonstrates a real-world usage pattern where existing tests can be
//! wrapped in platform-aware logic without rewriting them.

const std = @import("std");
const platform_config = @import("platform_config.zig");
const builtin = @import("builtin");

// Import backend modules (conditionally based on platform)
const backend = @import("../src/audio/backend.zig");

// =============================================================================
// Backend-specific test wrappers
// =============================================================================

fn testPulseAudioBackendInit() !void {
    try platform_config.requireBackend(.pulseaudio);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "pulseaudio");
    defer audio_backend.deinit();

    // Verify we got PulseAudio
    if (@as(backend.BackendType, audio_backend) != .pulseaudio) {
        return error.WrongBackend;
    }
}

fn testPulseAudioBackendStartStop() !void {
    try platform_config.requireBackend(.pulseaudio);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "pulseaudio");
    defer audio_backend.deinit();

    // Mock engine callback
    const MockEngine = struct {
        fn processCallback(_: *anyopaque, buffer: []f32) void {
            @memset(buffer, 0.0);
        }
    };

    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    audio_backend.setEngine(dummy_engine, MockEngine.processCallback);

    try audio_backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    audio_backend.stop();
}

fn testPipeWireBackendInit() !void {
    try platform_config.requireBackend(.pipewire);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "pipewire");
    defer audio_backend.deinit();

    // Verify we got PipeWire
    if (@as(backend.BackendType, audio_backend) != .pipewire) {
        return error.WrongBackend;
    }
}

fn testPipeWireBackendStartStop() !void {
    try platform_config.requireBackend(.pipewire);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "pipewire");
    defer audio_backend.deinit();

    // Mock engine callback
    const MockEngine = struct {
        fn processCallback(_: *anyopaque, buffer: []f32) void {
            @memset(buffer, 0.0);
        }
    };

    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    audio_backend.setEngine(dummy_engine, MockEngine.processCallback);

    try audio_backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    audio_backend.stop();
}

fn testCoreAudioBackendInit() !void {
    try platform_config.requireBackend(.coreaudio);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "coreaudio");
    defer audio_backend.deinit();

    // Verify we got CoreAudio
    if (@as(backend.BackendType, audio_backend) != .coreaudio) {
        return error.WrongBackend;
    }
}

fn testCoreAudioBackendStartStop() !void {
    try platform_config.requireBackend(.coreaudio);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "coreaudio");
    defer audio_backend.deinit();

    // Mock engine callback
    const MockEngine = struct {
        fn processCallback(_: *anyopaque, buffer: []f32) void {
            @memset(buffer, 0.0);
        }
    };

    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    audio_backend.setEngine(dummy_engine, MockEngine.processCallback);

    try audio_backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    audio_backend.stop();
}

fn testAutoDetection() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = backend.BackendConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    var audio_backend = try backend.Backend.init(allocator, config, "auto");
    defer audio_backend.deinit();

    // Verify we got a valid backend for this platform
    const backend_type = @as(backend.BackendType, audio_backend);

    const platform = platform_config.Platform.current();
    switch (platform) {
        .linux => {
            // Should be either PulseAudio or PipeWire
            if (backend_type != .pulseaudio and backend_type != .pipewire) {
                return error.UnexpectedBackend;
            }
        },
        .macos => {
            // Should be CoreAudio
            if (backend_type != .coreaudio) {
                return error.UnexpectedBackend;
            }
        },
        .windows => {
            // Should be WASAPI (when implemented)
            // For now, this will fail on Windows
            return error.WindowsNotImplemented;
        },
        .unknown => {
            return error.UnsupportedPlatform;
        },
    }
}

fn testBackendDetection() !void {
    // Test that detection functions work correctly
    const platform = platform_config.Platform.current();

    const backends_to_test = platform_config.getCurrentPlatformTests();

    var found_available = false;
    for (backends_to_test) |test_backend| {
        if (test_backend.detectRuntime()) {
            found_available = true;
            break;
        }
    }

    // At least one backend should be available on this platform
    if (!found_available and platform != .unknown) {
        return error.NoBackendAvailable;
    }
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

    // Register cross-platform tests
    try runner.addTest("Auto-detection selects appropriate backend", .pulseaudio, testAutoDetection);
    try runner.addTest("Backend detection functions work", .pulseaudio, testBackendDetection);

    // Register Linux-specific tests
    try runner.addTest("PulseAudio: Backend initialization", .pulseaudio, testPulseAudioBackendInit);
    try runner.addTest("PulseAudio: Start and stop", .pulseaudio, testPulseAudioBackendStartStop);
    try runner.addTest("PipeWire: Backend initialization", .pipewire, testPipeWireBackendInit);
    try runner.addTest("PipeWire: Start and stop", .pipewire, testPipeWireBackendStartStop);

    // Register macOS-specific tests
    try runner.addTest("CoreAudio: Backend initialization", .coreaudio, testCoreAudioBackendInit);
    try runner.addTest("CoreAudio: Start and stop", .coreaudio, testCoreAudioBackendStartStop);

    // Run all tests (platform-aware)
    runner.run();

    // Print summary
    runner.printReport();
}
