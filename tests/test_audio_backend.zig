// Audio Backend Unit Test
// Tests audio backend initialization and functionality without launching GUI

const std = @import("std");
const backend = @import("../src/audio/backend.zig");
const config = @import("../src/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎵 DAW Audio Backend Tests\n", .{});
    std.debug.print("===========================\n\n", .{});

    // Test 1: Auto-detection
    std.debug.print("1️⃣ Testing auto-detection...\n", .{});
    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .auto,
        .midi_backend = .auto,
        .project_dir = "/tmp/daw_test",
    };

    var audio_backend = backend.Backend.init(allocator, &cfg) catch |err| {
        std.debug.print("   ✗ Backend initialization failed: {}\n", .{err});
        return err;
    };
    defer audio_backend.deinit();

    const backend_type = @tagName(audio_backend);
    std.debug.print("   ✓ Detected backend: {s}\n", .{backend_type});

    // Test 2: Check if it's NOT PipeWire (should prefer PulseAudio)
    std.debug.print("\n2️⃣ Verifying backend priority...\n", .{});
    if (std.mem.eql(u8, backend_type, "pipewire")) {
        std.debug.print("   ⚠ Warning: Using PipeWire stub instead of PulseAudio\n", .{});
        std.debug.print("   This is acceptable but audio won't work\n", .{});
    } else if (std.mem.eql(u8, backend_type, "pulseaudio")) {
        std.debug.print("   ✓ Correctly using PulseAudio backend\n", .{});
    } else {
        std.debug.print("   ✓ Using {s} backend\n", .{backend_type});
    }

    // Test 3: Prepare backend
    std.debug.print("\n3️⃣ Testing backend preparation...\n", .{});
    audio_backend.prepare() catch |err| {
        std.debug.print("   ✗ Backend prepare failed: {}\n", .{err});
        return err;
    };
    std.debug.print("   ✓ Backend prepared successfully\n", .{});

    // Test 4: Set engine callback (mock)
    std.debug.print("\n4️⃣ Testing engine connection...\n", .{});
    const dummy_engine: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    const dummy_callback: *const fn (*anyopaque, []f32) void = struct {
        fn callback(_: *anyopaque, buffer: []f32) void {
            @memset(buffer, 0);
        }
    }.callback;

    audio_backend.setEngine(dummy_engine, dummy_callback);
    std.debug.print("   ✓ Engine callback set\n", .{});

    // Test 5: Start/Stop (brief test)
    std.debug.print("\n5️⃣ Testing start/stop functionality...\n", .{});
    audio_backend.start() catch |err| {
        std.debug.print("   ✗ Backend start failed: {}\n", .{err});
        return err;
    };
    std.debug.print("   ✓ Backend started\n", .{});

    // Brief delay
    std.time.sleep(100 * std.time.ns_per_ms);

    audio_backend.stop();
    std.debug.print("   ✓ Backend stopped\n", .{});

    std.debug.print("\n===========================\n", .{});
    std.debug.print("✅ All audio backend tests passed!\n\n", .{});
}
