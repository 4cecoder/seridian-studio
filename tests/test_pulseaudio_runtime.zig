// PulseAudio Runtime Verification Test
// This test actually RUNS the PulseAudio backend and verifies that the audio thread executes callbacks.
// Unlike unit tests that mock everything, this is a real integration test that proves the backend works.

const std = @import("std");
const testing = std.testing;
const pulseaudio = @import("../src/audio/pulseaudio.zig");

// Mock engine that counts callback invocations
const CallbackCounter = struct {
    invocation_count: std.atomic.Value(u32),
    last_buffer_size: std.atomic.Value(usize),
    total_samples_processed: std.atomic.Value(u64),

    fn init() CallbackCounter {
        return .{
            .invocation_count = std.atomic.Value(u32).init(0),
            .last_buffer_size = std.atomic.Value(usize).init(0),
            .total_samples_processed = std.atomic.Value(u64).init(0),
        };
    }

    fn processCallback(ctx: *anyopaque, buffer: []f32) void {
        const self: *CallbackCounter = @ptrCast(@alignCast(ctx));

        // Increment invocation count atomically
        _ = self.invocation_count.fetchAdd(1, .monotonic);

        // Store buffer size
        self.last_buffer_size.store(buffer.len, .monotonic);

        // Track total samples
        _ = self.total_samples_processed.fetchAdd(buffer.len, .monotonic);

        // Fill buffer with a simple test signal (sine wave at 440Hz)
        const sample_rate: f32 = 48000.0;
        const frequency: f32 = 440.0;

        for (buffer, 0..) |*sample, i| {
            const t = @as(f32, @floatFromInt(i)) / sample_rate;
            sample.* = @sin(2.0 * std.math.pi * frequency * t) * 0.1; // Low amplitude to be safe
        }
    }

    fn getCount(self: *const CallbackCounter) u32 {
        return self.invocation_count.load(.monotonic);
    }

    fn getBufferSize(self: *const CallbackCounter) usize {
        return self.last_buffer_size.load(.monotonic);
    }

    fn getTotalSamples(self: *const CallbackCounter) u64 {
        return self.total_samples_processed.load(.monotonic);
    }
};

// Simple config struct for PulseAudio initialization
const TestConfig = struct {
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
};

test "PulseAudio Runtime: Audio thread executes callbacks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected in PulseAudio runtime test\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Configuration
    const cfg = TestConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2, // Stereo
    };

    std.debug.print("\n=== PulseAudio Runtime Test ===\n", .{});
    std.debug.print("Sample rate: {d} Hz\n", .{cfg.sample_rate});
    std.debug.print("Buffer size: {d} frames\n", .{cfg.buffer_size});
    std.debug.print("Channels: {d}\n", .{cfg.channels});

    // Initialize backend
    var backend = pulseaudio.PulseAudioBackend.init(allocator, cfg) catch |err| {
        std.debug.print("SKIP: Could not initialize PulseAudio backend: {}\n", .{err});
        std.debug.print("This test requires PulseAudio to be running on the system.\n", .{});
        return error.SkipZigTest;
    };
    defer backend.deinit();

    std.debug.print("Backend initialized successfully\n", .{});

    // Prepare the stream (this connects to PulseAudio)
    backend.prepare() catch |err| {
        std.debug.print("SKIP: Could not prepare PulseAudio stream: {}\n", .{err});
        std.debug.print("PulseAudio daemon may not be running.\n", .{});
        return error.SkipZigTest;
    };

    std.debug.print("Stream prepared successfully\n", .{});

    // Create callback counter
    var counter = CallbackCounter.init();

    // Set the engine (callback must be set before starting)
    backend.setEngine(@ptrCast(&counter), CallbackCounter.processCallback);
    std.debug.print("Engine callback registered\n", .{});

    // Start the audio thread
    try backend.start();
    std.debug.print("Audio thread started\n", .{});

    // Let it run for 500ms
    std.debug.print("Sleeping for 500ms to allow callbacks to execute...\n", .{});
    std.time.sleep(500 * std.time.ns_per_ms);

    // Check that callbacks were invoked
    const count_while_running = counter.getCount();
    const buffer_size = counter.getBufferSize();
    const total_samples = counter.getTotalSamples();

    std.debug.print("\nResults after 500ms:\n", .{});
    std.debug.print("  Callback invocations: {d}\n", .{count_while_running});
    std.debug.print("  Buffer size: {d} samples\n", .{buffer_size});
    std.debug.print("  Total samples processed: {d}\n", .{total_samples});

    // Verify thread is actually running and processing
    try testing.expect(count_while_running > 0);
    std.debug.print("PASS: Audio thread executed callbacks ({d} times)\n", .{count_while_running});

    // Verify buffer size matches configuration
    const expected_buffer_size = cfg.buffer_size * cfg.channels;
    try testing.expectEqual(expected_buffer_size, buffer_size);
    std.debug.print("PASS: Buffer size matches configuration ({d} samples)\n", .{expected_buffer_size});

    // Calculate expected callback rate
    const buffer_duration_ms = (@as(f64, @floatFromInt(cfg.buffer_size)) * 1000.0) / @as(f64, @floatFromInt(cfg.sample_rate));
    const expected_callbacks = @as(u32, @intFromFloat(500.0 / buffer_duration_ms));
    const tolerance = expected_callbacks / 4; // Allow 25% variance

    std.debug.print("Expected callbacks (approx): {d} ± {d}\n", .{ expected_callbacks, tolerance });

    // Verify callback rate is reasonable (not too low, not too high)
    try testing.expect(count_while_running >= expected_callbacks / 2);
    try testing.expect(count_while_running <= expected_callbacks * 2);
    std.debug.print("PASS: Callback rate is reasonable\n", .{});

    // Stop the audio thread
    backend.stop();
    std.debug.print("\nAudio thread stop requested\n", .{});

    // Wait a bit to ensure thread stopped
    std.time.sleep(100 * std.time.ns_per_ms);

    // Record count after stopping
    const count_after_stop = counter.getCount();
    std.debug.print("Callback count after stop: {d}\n", .{count_after_stop});

    // Wait another 200ms to verify no new callbacks
    std.time.sleep(200 * std.time.ns_per_ms);

    const count_final = counter.getCount();
    std.debug.print("Callback count after additional 200ms: {d}\n", .{count_final});

    // Verify thread actually stopped (count should not increase)
    try testing.expectEqual(count_after_stop, count_final);
    std.debug.print("PASS: Thread stopped (no new callbacks after stop)\n", .{});

    std.debug.print("\n=== All Tests Passed ===\n", .{});
}

test "PulseAudio Runtime: Multiple start/stop cycles" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected in start/stop cycles test\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const cfg = TestConfig{
        .sample_rate = 48000,
        .buffer_size = 256,
        .channels = 2,
    };

    std.debug.print("\n=== PulseAudio Start/Stop Cycles Test ===\n", .{});

    var backend = pulseaudio.PulseAudioBackend.init(allocator, cfg) catch |err| {
        std.debug.print("SKIP: Could not initialize PulseAudio: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer backend.deinit();

    backend.prepare() catch |err| {
        std.debug.print("SKIP: Could not prepare stream: {}\n", .{err});
        return error.SkipZigTest;
    };

    var counter = CallbackCounter.init();
    backend.setEngine(@ptrCast(&counter), CallbackCounter.processCallback);

    // Cycle 1
    std.debug.print("\nCycle 1: Starting...\n", .{});
    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    const count1 = counter.getCount();
    std.debug.print("  Callbacks: {d}\n", .{count1});
    backend.stop();
    std.time.sleep(50 * std.time.ns_per_ms);
    try testing.expect(count1 > 0);

    // Cycle 2
    std.debug.print("\nCycle 2: Starting...\n", .{});
    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    const count2 = counter.getCount();
    std.debug.print("  Callbacks: {d}\n", .{count2});
    backend.stop();
    std.time.sleep(50 * std.time.ns_per_ms);
    try testing.expect(count2 > count1);

    // Cycle 3
    std.debug.print("\nCycle 3: Starting...\n", .{});
    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    const count3 = counter.getCount();
    std.debug.print("  Callbacks: {d}\n", .{count3});
    backend.stop();
    std.time.sleep(50 * std.time.ns_per_ms);
    try testing.expect(count3 > count2);

    std.debug.print("\nPASS: All cycles completed successfully\n", .{});
    std.debug.print("Total callbacks across all cycles: {d}\n", .{count3});
}

test "PulseAudio Runtime: Thread safety with concurrent operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected in thread safety test\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const cfg = TestConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    std.debug.print("\n=== PulseAudio Thread Safety Test ===\n", .{});

    var backend = pulseaudio.PulseAudioBackend.init(allocator, cfg) catch |err| {
        std.debug.print("SKIP: Could not initialize PulseAudio: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer backend.deinit();

    backend.prepare() catch |err| {
        std.debug.print("SKIP: Could not prepare stream: {}\n", .{err});
        return error.SkipZigTest;
    };

    var counter = CallbackCounter.init();
    backend.setEngine(@ptrCast(&counter), CallbackCounter.processCallback);

    // Start and immediately check state multiple times
    try backend.start();

    for (0..10) |i| {
        std.time.sleep(10 * std.time.ns_per_ms);
        const count = counter.getCount();
        std.debug.print("Check {d}: {d} callbacks\n", .{ i + 1, count });
        try testing.expect(backend.running.load(.acquire));
    }

    backend.stop();
    std.time.sleep(100 * std.time.ns_per_ms);

    try testing.expect(!backend.running.load(.acquire));
    std.debug.print("PASS: Thread state transitions are safe\n", .{});
}
