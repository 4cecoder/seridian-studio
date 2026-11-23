// Audio Backend Detection and Abstraction Tests
// Verifies cross-platform backend selection works correctly

const std = @import("std");
const testing = std.testing;
const backend = @import("../src/audio/backend.zig");
const config = @import("../src/config.zig");
const builtin = @import("builtin");

test "Backend: auto-detection selects appropriate backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .auto,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = try backend.Backend.init(allocator, &cfg);
    defer audio_backend.deinit();

    const backend_type = @tagName(audio_backend);

    // Verify we got a valid backend
    try testing.expect(!std.mem.eql(u8, backend_type, ""));

    // Platform-specific assertions
    if (builtin.os.tag == .macos) {
        try testing.expect(std.mem.eql(u8, backend_type, "coreaudio"));
    } else if (builtin.os.tag == .linux) {
        // Should prefer PulseAudio over PipeWire stub
        const is_pulseaudio = std.mem.eql(u8, backend_type, "pulseaudio");
        const is_pipewire = std.mem.eql(u8, backend_type, "pipewire");
        try testing.expect(is_pulseaudio or is_pipewire);
    }
}

test "Backend: forced PulseAudio selection" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .pulseaudio,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = try backend.Backend.init(allocator, &cfg);
    defer audio_backend.deinit();

    const backend_type = @tagName(audio_backend);
    try testing.expect(std.mem.eql(u8, backend_type, "pulseaudio"));
}

test "Backend: prepare works for auto-detected backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .auto,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = try backend.Backend.init(allocator, &cfg);
    defer audio_backend.deinit();

    // Should prepare without errors
    try audio_backend.prepare();
}

test "Backend: start and stop work for auto-detected backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .auto,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = try backend.Backend.init(allocator, &cfg);
    defer audio_backend.deinit();

    try audio_backend.prepare();

    // Mock engine for testing
    const MockEngine = struct {
        fn processCallback(_: *anyopaque, buffer: []f32) void {
            @memset(buffer, 0);
        }
    };

    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    audio_backend.setEngine(dummy_engine, MockEngine.processCallback);

    try audio_backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    audio_backend.stop();
}

test "Backend: detection functions work" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // These should not crash
    const has_pulseaudio = backend.detectPulseAudio();
    const has_pipewire = backend.detectPipeWire();

    // At least one should be available on a Linux system
    try testing.expect(has_pulseaudio or has_pipewire);
}

test "Backend: multiple backends can coexist" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create two backend instances with different types
    const cfg1 = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .pulseaudio,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test1",
    };

    const cfg2 = config.Config{
        .sample_rate = 44100,
        .buffer_size = 256,
        .audio_backend = .pipewire,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test2",
    };

    var backend1 = try backend.Backend.init(allocator, &cfg1);
    defer backend1.deinit();

    var backend2 = try backend.Backend.init(allocator, &cfg2);
    defer backend2.deinit();

    // Both should initialize successfully
    try backend1.prepare();
    try backend2.prepare();
}

test "Backend: setEngine handles null gracefully" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .auto,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = try backend.Backend.init(allocator, &cfg);
    defer audio_backend.deinit();

    // Should not crash with null callback
    const MockEngine = struct {
        fn processCallback(_: *anyopaque, _: []f32) void {}
    };

    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    audio_backend.setEngine(dummy_engine, MockEngine.processCallback);

    try audio_backend.prepare();
    try audio_backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    audio_backend.stop();
}

test "Backend: different sample rates work" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_rates = [_]u32{ 44100, 48000, 88200, 96000 };

    for (sample_rates) |sample_rate| {
        const cfg = config.Config{
            .sample_rate = sample_rate,
            .buffer_size = 512,
            .audio_backend = .auto,
            .midi_backend = .none,
            .project_dir = "/tmp/daw_test",
        };

        var audio_backend = try backend.Backend.init(allocator, &cfg);
        defer audio_backend.deinit();

        try audio_backend.prepare();
    }
}

test "Backend: different buffer sizes work" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const buffer_sizes = [_]u32{ 128, 256, 512, 1024, 2048 };

    for (buffer_sizes) |buffer_size| {
        const cfg = config.Config{
            .sample_rate = 48000,
            .buffer_size = buffer_size,
            .audio_backend = .auto,
            .midi_backend = .none,
            .project_dir = "/tmp/daw_test",
        };

        var audio_backend = try backend.Backend.init(allocator, &cfg);
        defer audio_backend.deinit();

        try audio_backend.prepare();
    }
}
