// PulseAudio Integration Test
// Full integration test that verifies the engine and PulseAudio backend work together end-to-end
// This test:
//   1. Creates an AudioEngine
//   2. Creates a PulseAudio backend
//   3. Connects them together (setEngine)
//   4. Prepares the audio stream
//   5. Starts playback
//   6. Lets it run for 1 second
//   7. Verifies callbacks happened
//   8. Verifies samples were processed
//   9. Stops playback
//   10. Cleans up
// Prints detailed metrics and exits 0 on success

const std = @import("std");
const engine_mod = @import("audio/engine.zig");
const AudioEngine = engine_mod.AudioEngine;
const EngineConfig = engine_mod.EngineConfig;

// Metrics tracking structure
const IntegrationMetrics = struct {
    callbacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    samples_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    start_time_ns: i128 = 0,
    end_time_ns: i128 = 0,

    fn recordCallback(self: *IntegrationMetrics, sample_count: u64) void {
        _ = self.callbacks.fetchAdd(1, .monotonic);
        _ = self.samples_processed.fetchAdd(sample_count, .monotonic);
    }

    fn startTimer(self: *IntegrationMetrics) void {
        const instant = std.time.Instant.now() catch unreachable;
        if (@TypeOf(instant.timestamp) == @import("std").posix.timespec) {
            self.start_time_ns = @as(i128, instant.timestamp.sec) * 1_000_000_000 + instant.timestamp.nsec;
        } else {
            self.start_time_ns = @intCast(instant.timestamp);
        }
    }

    fn stopTimer(self: *IntegrationMetrics) void {
        const instant = std.time.Instant.now() catch unreachable;
        if (@TypeOf(instant.timestamp) == @import("std").posix.timespec) {
            self.end_time_ns = @as(i128, instant.timestamp.sec) * 1_000_000_000 + instant.timestamp.nsec;
        } else {
            self.end_time_ns = @intCast(instant.timestamp);
        }
    }

    fn getRuntimeMs(self: *const IntegrationMetrics) f64 {
        const duration_ns = self.end_time_ns - self.start_time_ns;
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    }

    fn getCallbackCount(self: *const IntegrationMetrics) u64 {
        return self.callbacks.load(.acquire);
    }

    fn getSamplesProcessed(self: *const IntegrationMetrics) u64 {
        return self.samples_processed.load(.acquire);
    }
};

// Test engine wrapper that tracks metrics
const TestEngine = struct {
    engine: AudioEngine,
    metrics: IntegrationMetrics = .{},

    fn create(allocator: std.mem.Allocator, config: EngineConfig) !*TestEngine {
        const self = try allocator.create(TestEngine);
        errdefer allocator.destroy(self);

        self.* = .{
            .engine = try AudioEngine.init(allocator, config),
        };

        return self;
    }

    fn destroy(self: *TestEngine, allocator: std.mem.Allocator) void {
        self.engine.deinit();
        allocator.destroy(self);
    }

    fn connectAndPrepare(self: *TestEngine) !void {
        // Connect backend to engine (now also calls prepare internally)
        try self.engine.connectBackend();
    }

    fn startPlayback(self: *TestEngine) !void {
        self.metrics.startTimer();
        try self.engine.start();
    }

    fn stopPlayback(self: *TestEngine) void {
        self.engine.stop();
        self.metrics.stopTimer();
    }
};

// Custom process wrapper that tracks metrics
fn processWithMetrics(engine_ptr: *anyopaque, output: []f32) void {
    const test_engine: *TestEngine = @ptrCast(@alignCast(engine_ptr));

    // Record metrics
    test_engine.metrics.recordCallback(output.len);

    // Call the actual engine process function
    test_engine.engine.process(output);
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

    // Print test header
    std.debug.print("\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("  PULSEAUDIO INTEGRATION TEST\n", .{});
    std.debug.print("  Engine + PulseAudio Backend Full Chain\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});

    // Test configuration
    const test_duration_ms = 2000; // 2 seconds
    const config = EngineConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .backend_preference = "pulseaudio",
    };

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Sample Rate:    {d} Hz\n", .{config.sample_rate});
    std.debug.print("  Buffer Size:    {d} samples\n", .{config.buffer_size});
    std.debug.print("  Backend:        {s}\n", .{config.backend_preference});
    std.debug.print("  Test Duration:  {d} ms\n", .{test_duration_ms});
    std.debug.print("\n", .{});

    // Step 1: Create engine
    std.debug.print("[1/6] Creating AudioEngine...\n", .{});
    var test_engine = TestEngine.create(allocator, config) catch |err| {
        std.debug.print("FAIL: Could not create AudioEngine: {}\n", .{err});
        std.debug.print("This test requires PulseAudio to be available.\n", .{});
        std.process.exit(1);
    };
    defer test_engine.destroy(allocator);

    const backend_type = @tagName(test_engine.engine.backend);
    std.debug.print("  SUCCESS: Engine created with {s} backend\n", .{backend_type});

    // Verify it's PulseAudio
    if (test_engine.engine.backend != .pulseaudio) {
        std.debug.print("FAIL: Expected PulseAudio backend, got {s}\n", .{backend_type});
        std.process.exit(1);
    }
    std.debug.print("\n", .{});

    // Step 2: Connect and prepare
    std.debug.print("[2/6] Connecting engine to backend...\n", .{});

    // Connect and prepare - but we'll override with our metrics wrapper
    test_engine.connectAndPrepare() catch |err| {
        std.debug.print("FAIL: Could not prepare backend: {}\n", .{err});
        std.debug.print("PulseAudio may not be running on this system.\n", .{});
        std.process.exit(1);
    };

    // Override the engine pointer with our metrics wrapper
    switch (test_engine.engine.backend) {
        .pulseaudio => |*pa| {
            pa.setEngine(@ptrCast(test_engine), processWithMetrics);
        },
        else => {},
    }

    std.debug.print("  SUCCESS: Backend connected and prepared\n", .{});
    std.debug.print("\n", .{});

    // Step 3: Start playback
    std.debug.print("[3/6] Starting playback...\n", .{});
    test_engine.startPlayback() catch |err| {
        std.debug.print("FAIL: Could not start playback: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("  SUCCESS: Playback started\n", .{});

    // Give the thread time to actually start
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
    std.debug.print("\n", .{});

    // Step 4: Let it run
    std.debug.print("[4/6] Running for {d} ms...\n", .{test_duration_ms});
    std.posix.nanosleep(0, test_duration_ms * std.time.ns_per_ms);
    std.debug.print("  SUCCESS: Completed run duration\n", .{});
    std.debug.print("\n", .{});

    // Step 5: Verify callbacks happened
    std.debug.print("[5/6] Verifying callbacks and sample processing...\n", .{});
    const callback_count = test_engine.metrics.getCallbackCount();
    const samples_processed = test_engine.metrics.getSamplesProcessed();

    if (callback_count == 0) {
        std.debug.print("FAIL: No callbacks were executed!\n", .{});
        std.debug.print("  Callbacks: {d}\n", .{callback_count});
        test_engine.stopPlayback();
        std.process.exit(1);
    }

    if (samples_processed == 0) {
        std.debug.print("FAIL: No samples were processed!\n", .{});
        std.debug.print("  Samples: {d}\n", .{samples_processed});
        test_engine.stopPlayback();
        std.process.exit(1);
    }

    // Calculate expected values
    const buffer_duration_ms = (@as(f64, @floatFromInt(config.buffer_size)) * 1000.0) / @as(f64, @floatFromInt(config.sample_rate));
    const expected_callbacks = @as(u64, @intFromFloat(@as(f64, @floatFromInt(test_duration_ms)) / buffer_duration_ms));
    const expected_samples = expected_callbacks * config.buffer_size * 2; // stereo

    std.debug.print("  Callback count:     {d} (expected ~{d})\n", .{ callback_count, expected_callbacks });
    std.debug.print("  Samples processed:  {d} (expected ~{d})\n", .{ samples_processed, expected_samples });

    // Verify callback count is reasonable
    // We just need SOME callbacks, not perfect timing
    const min_callbacks: u64 = 5; // At least a few callbacks
    if (callback_count < min_callbacks) {
        std.debug.print("FAIL: Too few callbacks!\n", .{});
        std.debug.print("  Expected at least: {d}\n", .{min_callbacks});
        test_engine.stopPlayback();
        std.process.exit(1);
    }

    std.debug.print("  SUCCESS: Callbacks and samples verified\n", .{});
    std.debug.print("\n", .{});

    // Step 6: Stop playback
    std.debug.print("[6/6] Stopping playback...\n", .{});
    test_engine.stopPlayback();

    // Wait a bit to ensure thread stopped
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    std.debug.print("  SUCCESS: Playback stopped\n", .{});
    std.debug.print("\n", .{});

    // Print detailed metrics
    const runtime_ms = test_engine.metrics.getRuntimeMs();
    std.debug.print("===========================================================\n", .{});
    std.debug.print("  INTEGRATION TEST PASSED\n", .{});
    std.debug.print("===========================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Detailed Metrics:\n", .{});
    std.debug.print("  Engine callbacks:      {d}\n", .{callback_count});
    std.debug.print("  Samples processed:     {d}\n", .{samples_processed});
    std.debug.print("  Runtime:               {d:.2} ms\n", .{runtime_ms});
    std.debug.print("  Average callback rate: {d:.2} Hz\n", .{@as(f64, @floatFromInt(callback_count)) / (runtime_ms / 1000.0)});
    std.debug.print("  Buffer size:           {d} frames ({d} samples stereo)\n", .{ config.buffer_size, config.buffer_size * 2 });
    std.debug.print("  Sample rate:           {d} Hz\n", .{config.sample_rate});
    std.debug.print("\n", .{});
    std.debug.print("This proves the engine and PulseAudio backend work together.\n", .{});
    std.debug.print("\n", .{});

    // Exit with success
    std.process.exit(0);
}
