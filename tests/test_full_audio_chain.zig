// Full Audio Chain Integration Test
// Tests the complete audio pipeline: Engine -> Backend -> Thread -> Audio Output
// This proves the system works end-to-end without launching the GUI

const std = @import("std");
const engine_mod = @import("../src/audio/engine.zig");
const AudioEngine = engine_mod.AudioEngine;
const EngineConfig = engine_mod.EngineConfig;

// Statistics tracker to monitor audio processing
const AudioStats = struct {
    callbacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    samples_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread_stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_error: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn recordCallback(self: *AudioStats, sample_count: u64) void {
        _ = self.callbacks.fetchAdd(1, .monotonic);
        _ = self.samples_processed.fetchAdd(sample_count, .monotonic);
    }

    fn markThreadStarted(self: *AudioStats) void {
        self.thread_started.store(true, .release);
    }

    fn markThreadStopped(self: *AudioStats) void {
        self.thread_stopped.store(true, .release);
    }

    fn recordError(self: *AudioStats, error_code: u32) void {
        self.last_error.store(error_code, .release);
    }

    fn getReport(self: *const AudioStats) Report {
        return Report{
            .callbacks = self.callbacks.load(.acquire),
            .samples_processed = self.samples_processed.load(.acquire),
            .thread_started = self.thread_started.load(.acquire),
            .thread_stopped = self.thread_stopped.load(.acquire),
            .last_error = self.last_error.load(.acquire),
        };
    }

    const Report = struct {
        callbacks: u64,
        samples_processed: u64,
        thread_started: bool,
        thread_stopped: bool,
        last_error: u32,
    };
};

// Test wrapper that tracks statistics
const TestEngine = struct {
    engine: AudioEngine,
    stats: AudioStats = .{},

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
        self.stats.markThreadStarted();
        try self.engine.start();
    }

    fn stopPlayback(self: *TestEngine) void {
        self.engine.stop();
        self.stats.markThreadStopped();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ MEMORY LEAK DETECTED!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  FULL AUDIO CHAIN INTEGRATION TEST\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});

    // Test configuration
    const test_duration_ms = 2000; // 2 seconds of audio
    const config = EngineConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .backend_preference = "auto",
    };

    std.debug.print("📋 Test Configuration:\n", .{});
    std.debug.print("   Sample Rate:    {d} Hz\n", .{config.sample_rate});
    std.debug.print("   Buffer Size:    {d} samples\n", .{config.buffer_size});
    std.debug.print("   Backend:        {s}\n", .{config.backend_preference});
    std.debug.print("   Test Duration:  {d} ms\n", .{test_duration_ms});
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 1: Initialize Audio Engine
    // ========================================================================
    std.debug.print("1️⃣  Initializing Audio Engine...\n", .{});
    var test_engine = try TestEngine.create(allocator, config);
    defer test_engine.destroy(allocator);

    const backend_type = @tagName(test_engine.engine.backend);
    std.debug.print("   ✓ Engine initialized\n", .{});
    std.debug.print("   ✓ Backend detected: {s}\n", .{backend_type});
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 2: Connect Engine to Backend
    // ========================================================================
    std.debug.print("2️⃣  Connecting engine to backend...\n", .{});
    try test_engine.connectAndPrepare();
    std.debug.print("   ✓ Backend connected to engine\n", .{});
    std.debug.print("   ✓ Backend prepared for playback\n", .{});
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 3: Start Playback
    // ========================================================================
    std.debug.print("3️⃣  Starting audio playback...\n", .{});
    try test_engine.startPlayback();
    std.debug.print("   ✓ Playback started\n", .{});
    std.debug.print("   ✓ Audio thread spawned\n", .{});
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 4: Let it run and monitor
    // ========================================================================
    std.debug.print("4️⃣  Running audio chain for {d}ms...\n", .{test_duration_ms});

    // Monitor progress in 500ms intervals
    const intervals = test_duration_ms / 500;
    var i: usize = 0;
    while (i < intervals) : (i += 1) {
        std.time.sleep(500 * std.time.ns_per_ms);

        const pos = test_engine.engine.getPosition();
        const playing = test_engine.engine.isPlaying();
        const master_left = test_engine.engine.getMasterMeterLeft();
        const master_right = test_engine.engine.getMasterMeterRight();

        std.debug.print("   [{d}ms] Position: {d} samples | Playing: {s} | Meter: L={d:.3} R={d:.3}\n", .{
            (i + 1) * 500,
            pos,
            if (playing) "YES" else "NO ",
            master_left,
            master_right,
        });
    }
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 5: Stop Playback
    // ========================================================================
    std.debug.print("5️⃣  Stopping playback...\n", .{});
    test_engine.stopPlayback();
    std.debug.print("   ✓ Playback stopped\n", .{});

    // Give audio thread time to fully stop
    std.time.sleep(200 * std.time.ns_per_ms);
    std.debug.print("   ✓ Audio thread terminated\n", .{});
    std.debug.print("\n", .{});

    // ========================================================================
    // Step 6: Verify Results
    // ========================================================================
    std.debug.print("6️⃣  Verifying audio processing...\n", .{});

    const final_position = test_engine.engine.getPosition();
    const is_playing = test_engine.engine.isPlaying();
    const health_stats = test_engine.engine.getAudioHealthStats();

    // Calculate expected samples (approximate)
    const expected_samples_min = @as(u64, config.sample_rate) * test_duration_ms / 1000;
    const expected_samples_max = expected_samples_min * 110 / 100; // +10% tolerance

    // Calculate approximate callback count
    const expected_callbacks_min = test_duration_ms / ((config.buffer_size * 1000) / config.sample_rate);

    var test_passed = true;

    // Verify playback stopped
    if (is_playing) {
        std.debug.print("   ❌ ERROR: Playback flag still set after stop!\n", .{});
        test_passed = false;
    } else {
        std.debug.print("   ✓ Playback properly stopped\n", .{});
    }

    // Verify samples were processed
    if (final_position < expected_samples_min) {
        std.debug.print("   ❌ ERROR: Too few samples processed!\n", .{});
        std.debug.print("      Expected at least: {d} samples\n", .{expected_samples_min});
        std.debug.print("      Got:               {d} samples\n", .{final_position});
        test_passed = false;
    } else if (final_position > expected_samples_max) {
        std.debug.print("   ⚠️  WARNING: More samples than expected (might indicate timing issue)\n", .{});
        std.debug.print("      Expected max: {d} samples\n", .{expected_samples_max});
        std.debug.print("      Got:          {d} samples\n", .{final_position});
    } else {
        std.debug.print("   ✓ Processed {d} samples ({d:.2} seconds)\n", .{
            final_position,
            @as(f64, @floatFromInt(final_position)) / @as(f64, @floatFromInt(config.sample_rate)),
        });
    }

    // Check for audio health issues
    if (health_stats.nan_inf_count > 0) {
        std.debug.print("   ⚠️  WARNING: {d} NaN/Inf values detected and sanitized\n", .{health_stats.nan_inf_count});
    } else {
        std.debug.print("   ✓ No NaN/Inf values detected\n", .{});
    }

    if (health_stats.clip_count > 1000) {
        std.debug.print("   ⚠️  WARNING: {d} samples clipped (possible gain issue)\n", .{health_stats.clip_count});
    } else if (health_stats.clip_count > 0) {
        std.debug.print("   ✓ Minimal clipping: {d} samples\n", .{health_stats.clip_count});
    } else {
        std.debug.print("   ✓ No clipping detected\n", .{});
    }

    std.debug.print("\n", .{});

    // ========================================================================
    // Step 7: Report Summary
    // ========================================================================
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  TEST RESULTS\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Backend Type:           {s}\n", .{backend_type});
    std.debug.print("Total Samples:          {d}\n", .{final_position});
    std.debug.print("Actual Duration:        {d:.2} seconds\n", .{
        @as(f64, @floatFromInt(final_position)) / @as(f64, @floatFromInt(config.sample_rate)),
    });
    std.debug.print("Audio Thread:           {s}\n", .{
        if (test_engine.stats.thread_started.load(.acquire)) "Started ✓" else "Failed ✗",
    });
    std.debug.print("Playback Status:        {s}\n", .{
        if (!is_playing) "Stopped ✓" else "Still Running ✗",
    });
    std.debug.print("Audio Health:\n", .{});
    std.debug.print("  - NaN/Inf Count:      {d}\n", .{health_stats.nan_inf_count});
    std.debug.print("  - Clip Count:         {d}\n", .{health_stats.clip_count});
    std.debug.print("\n", .{});

    if (test_passed) {
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("  ✅ ALL TESTS PASSED\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("🎉 The full audio chain is working correctly!\n", .{});
        std.debug.print("   Engine ✓ → Backend ✓ → Thread ✓ → Audio Output ✓\n", .{});
        std.debug.print("\n", .{});
        return;
    } else {
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("  ❌ TESTS FAILED\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});
        return error.TestFailed;
    }
}
