/// Playback Diagnostics Test Program
/// Monitors audio system health with detailed real-time reporting
/// Usage: zig run tests/test_playback_diagnostics.zig

const std = @import("std");
const AudioEngine = @import("../src/audio/engine.zig").AudioEngine;

/// Diagnostic data collected during playback
const DiagnosticStats = struct {
    callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    samples_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_callback_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    start_time: i64 = 0,

    /// Check if callbacks are being invoked regularly
    fn isCallbackActive(self: *const DiagnosticStats) bool {
        const now = std.time.milliTimestamp();
        const last_cb = self.last_callback_time.load(.acquire);

        // If no callback in last 100ms, consider inactive
        return (now - last_cb) < 100;
    }

    /// Calculate samples per second throughput
    fn getSamplesPerSecond(self: *const DiagnosticStats) f64 {
        const now = std.time.milliTimestamp();
        const elapsed_ms = @max(1, now - self.start_time);
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const total_samples: f64 = @floatFromInt(self.samples_processed.load(.acquire));

        return total_samples / elapsed_s;
    }

    /// Calculate callback rate (callbacks per second)
    fn getCallbackRate(self: *const DiagnosticStats) f64 {
        const now = std.time.milliTimestamp();
        const elapsed_ms = @max(1, now - self.start_time);
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const total_callbacks: f64 = @floatFromInt(self.callback_count.load(.acquire));

        return total_callbacks / elapsed_s;
    }
};

var global_stats = DiagnosticStats{};

/// Wrapper to intercept audio callbacks and collect diagnostics
fn diagnosticProcessWrapper(engine_ptr: *anyopaque, output: []f32) void {
    const engine: *AudioEngine = @ptrCast(@alignCast(engine_ptr));

    // Update diagnostics
    _ = global_stats.callback_count.fetchAdd(1, .monotonic);
    _ = global_stats.samples_processed.fetchAdd(output.len, .monotonic);
    global_stats.last_callback_time.store(std.time.milliTimestamp(), .release);

    // Call original process function
    engine.process(output);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    printHeader();

    // ==================================================================
    // STEP 1: Initialize Audio Engine
    // ==================================================================
    printStep(1, "Initializing Audio Engine");

    const config = .{
        .sample_rate = 48000,
        .buffer_size = 512,
        .backend_preference = "auto",
    };

    printConfig(config);

    var engine = AudioEngine.init(allocator, config) catch |err| {
        printError("Engine initialization failed", err);
        return err;
    };
    defer engine.deinit();

    printSuccess("Engine initialized successfully");

    // ==================================================================
    // STEP 2: Connect Backend
    // ==================================================================
    printStep(2, "Connecting Audio Backend");

    const backend_type = @tagName(engine.backend);
    printInfo("Backend type", backend_type);

    // Set up our diagnostic wrapper instead of direct connection
    engine.backend.setEngine(&engine, diagnosticProcessWrapper);
    printSuccess("Backend connected with diagnostic wrapper");

    // ==================================================================
    // STEP 3: Verify Initial State
    // ==================================================================
    printStep(3, "Verifying Initial State");

    printBool("Engine playing", engine.isPlaying());
    printBool("Engine recording", engine.isRecording());
    printValue("Position (samples)", engine.getPosition());
    printValue("Master gain", engine.getMasterGain());
    printValue("Tempo (BPM)", engine.getTempo());

    printSuccess("Initial state verified");

    // ==================================================================
    // STEP 4: Start Playback
    // ==================================================================
    printStep(4, "Starting Playback");

    global_stats.start_time = std.time.milliTimestamp();

    engine.start() catch |err| {
        printError("Failed to start playback", err);
        return err;
    };

    printSuccess("Playback started");

    // Wait a moment for thread to spin up
    std.time.sleep(50 * std.time.ns_per_ms);

    // ==================================================================
    // STEP 5: Monitor Playback (3 seconds with updates every 500ms)
    // ==================================================================
    printStep(5, "Monitoring Playback (3 seconds)");
    printSeparator();

    const monitoring_duration_ms = 3000;
    const update_interval_ms = 500;
    const iterations = monitoring_duration_ms / update_interval_ms;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        std.time.sleep(update_interval_ms * std.time.ns_per_ms);

        const elapsed = (i + 1) * update_interval_ms;
        printMonitoringUpdate(elapsed, &engine, &global_stats);
    }

    printSeparator();

    // ==================================================================
    // STEP 6: Stop Playback
    // ==================================================================
    printStep(6, "Stopping Playback");

    engine.stop();
    printSuccess("Playback stopped");

    // Wait for thread to finish any pending work
    std.time.sleep(100 * std.time.ns_per_ms);

    // ==================================================================
    // STEP 7: Final Statistics
    // ==================================================================
    printStep(7, "Final Statistics");
    printFinalStats(&engine, &global_stats, config);

    // ==================================================================
    // Summary
    // ==================================================================
    printSummary(&global_stats);
}

fn printHeader() void {
    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("                    AUDIO PLAYBACK DIAGNOSTICS TEST\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("\n", .{});
}

fn printStep(num: usize, description: []const u8) void {
    std.debug.print("\n[STEP {d}] {s}\n", .{ num, description });
    std.debug.print("--------------------------------------------------------------------------------\n", .{});
}

fn printSeparator() void {
    std.debug.print("--------------------------------------------------------------------------------\n", .{});
}

fn printConfig(config: anytype) void {
    std.debug.print("  Sample Rate:     {d} Hz\n", .{config.sample_rate});
    std.debug.print("  Buffer Size:     {d} samples\n", .{config.buffer_size});
    std.debug.print("  Backend:         {s}\n", .{config.backend_preference});
}

fn printSuccess(msg: []const u8) void {
    std.debug.print("  [OK] {s}\n", .{msg});
}

fn printError(msg: []const u8, err: anytype) void {
    std.debug.print("  [ERROR] {s}: {}\n", .{ msg, err });
}

fn printInfo(label: []const u8, value: []const u8) void {
    std.debug.print("  {s}: {s}\n", .{ label, value });
}

fn printValue(label: []const u8, value: anytype) void {
    std.debug.print("  {s}: {any}\n", .{ label, value });
}

fn printBool(label: []const u8, value: bool) void {
    const str = if (value) "YES" else "NO";
    std.debug.print("  {s}: {s}\n", .{ label, str });
}

fn printMonitoringUpdate(elapsed_ms: usize, engine: *const AudioEngine, stats: *const DiagnosticStats) void {
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    std.debug.print("\n[{d:.1f}s] Status Update:\n", .{elapsed_s});

    // Engine state
    const is_playing = engine.isPlaying();
    const position = engine.getPosition();
    const position_s: f64 = @as(f64, @floatFromInt(position)) / 48000.0;

    std.debug.print("  Engine State:\n", .{});
    std.debug.print("    Playing:              {s}\n", .{if (is_playing) "YES" else "NO"});
    std.debug.print("    Position:             {d} samples ({d:.2f}s)\n", .{ position, position_s });

    // Callback diagnostics
    const callback_active = stats.isCallbackActive();
    const callback_count = stats.callback_count.load(.acquire);
    const callback_rate = stats.getCallbackRate();

    std.debug.print("  Audio Thread:\n", .{});
    std.debug.print("    Callbacks Active:     {s}\n", .{if (callback_active) "YES" else "NO"});
    std.debug.print("    Total Callbacks:      {d}\n", .{callback_count});
    std.debug.print("    Callback Rate:        {d:.1f} callbacks/sec\n", .{callback_rate});

    // Sample throughput
    const samples_processed = stats.samples_processed.load(.acquire);
    const samples_per_sec = stats.getSamplesPerSecond();
    const expected_rate = 48000.0 * 2.0; // stereo
    const throughput_pct = (samples_per_sec / expected_rate) * 100.0;

    std.debug.print("  Sample Throughput:\n", .{});
    std.debug.print("    Total Samples:        {d}\n", .{samples_processed});
    std.debug.print("    Samples/sec:          {d:.0f}\n", .{samples_per_sec});
    std.debug.print("    Expected Rate:        {d:.0f} samples/sec\n", .{expected_rate});
    std.debug.print("    Throughput:           {d:.1f}%\n", .{throughput_pct});

    // Metering
    const master_left = engine.getMasterMeterLeft();
    const master_right = engine.getMasterMeterRight();

    std.debug.print("  Audio Levels:\n", .{});
    std.debug.print("    Master L:             {d:.3f}\n", .{master_left});
    std.debug.print("    Master R:             {d:.3f}\n", .{master_right});

    // Track meters
    std.debug.print("    Track Meters:         ", .{});
    var track: usize = 0;
    while (track < 4) : (track += 1) {
        const meter = engine.getTrackMeter(track);
        std.debug.print("{d:.3f} ", .{meter});
    }
    std.debug.print("\n", .{});

    // Audio health
    const health = engine.getAudioHealthStats();
    if (health.nan_inf_count > 0 or health.clip_count > 0) {
        std.debug.print("  Audio Health:\n", .{});
        if (health.nan_inf_count > 0) {
            std.debug.print("    [WARNING] NaN/Inf:    {d} samples sanitized\n", .{health.nan_inf_count});
        }
        if (health.clip_count > 0) {
            std.debug.print("    [WARNING] Clipping:   {d} samples clipped\n", .{health.clip_count});
        }
    }
}

fn printFinalStats(engine: *const AudioEngine, stats: *const DiagnosticStats, config: anytype) void {
    const total_callbacks = stats.callback_count.load(.acquire);
    const total_samples = stats.samples_processed.load(.acquire);
    const callback_rate = stats.getCallbackRate();
    const samples_per_sec = stats.getSamplesPerSecond();

    std.debug.print("\n", .{});
    std.debug.print("  Total Runtime:         ~3.0 seconds\n", .{});
    std.debug.print("  Total Callbacks:       {d}\n", .{total_callbacks});
    std.debug.print("  Average Callback Rate: {d:.1f} callbacks/sec\n", .{callback_rate});
    std.debug.print("  Total Samples:         {d}\n", .{total_samples});
    std.debug.print("  Average Throughput:    {d:.0f} samples/sec\n", .{samples_per_sec});

    const health = engine.getAudioHealthStats();
    std.debug.print("  NaN/Inf Count:         {d}\n", .{health.nan_inf_count});
    std.debug.print("  Clip Count:            {d}\n", .{health.clip_count});

    // Calculate expected values
    const buffer_samples = config.buffer_size * 2; // stereo
    const expected_callbacks = callback_rate * 3.0;
    const expected_samples = samples_per_sec * 3.0;

    std.debug.print("\n  Expected vs Actual:\n", .{});
    std.debug.print("    Expected callbacks:  ~{d:.0f}\n", .{expected_callbacks});
    std.debug.print("    Expected samples:    ~{d:.0f}\n", .{expected_samples});
    std.debug.print("    Buffer size:         {d} samples\n", .{buffer_samples});
}

fn printSummary(stats: *const DiagnosticStats) void {
    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("                              SUMMARY\n", .{});
    std.debug.print("================================================================================\n", .{});

    const callback_count = stats.callback_count.load(.acquire);
    const samples_processed = stats.samples_processed.load(.acquire);
    const callback_active = stats.isCallbackActive();

    if (callback_count == 0) {
        std.debug.print("\n  [FAIL] No audio callbacks were invoked!\n", .{});
        std.debug.print("  Possible issues:\n", .{});
        std.debug.print("    - Audio thread failed to start\n", .{});
        std.debug.print("    - Backend not properly initialized\n", .{});
        std.debug.print("    - System audio driver issue\n", .{});
    } else if (callback_count < 10) {
        std.debug.print("\n  [WARNING] Very few callbacks ({d})\n", .{callback_count});
        std.debug.print("  Audio system may be struggling\n", .{});
    } else if (!callback_active) {
        std.debug.print("\n  [WARNING] Callbacks stopped during test\n", .{});
        std.debug.print("  Total callbacks: {d}\n", .{callback_count});
        std.debug.print("  Audio thread may have crashed or stalled\n", .{});
    } else {
        std.debug.print("\n  [SUCCESS] Audio system is working correctly!\n", .{});
        std.debug.print("  - Callbacks active:      YES\n", .{});
        std.debug.print("  - Total callbacks:       {d}\n", .{callback_count});
        std.debug.print("  - Total samples:         {d}\n", .{samples_processed});
        std.debug.print("  - Samples/sec:           {d:.0f}\n", .{stats.getSamplesPerSecond()});

        const expected_rate = 48000.0 * 2.0; // stereo
        const actual_rate = stats.getSamplesPerSecond();
        const deviation = @abs(actual_rate - expected_rate) / expected_rate * 100.0;

        if (deviation < 5.0) {
            std.debug.print("  - Throughput accuracy:   Excellent ({d:.1f}% deviation)\n", .{deviation});
        } else if (deviation < 15.0) {
            std.debug.print("  - Throughput accuracy:   Good ({d:.1f}% deviation)\n", .{deviation});
        } else {
            std.debug.print("  - Throughput accuracy:   Poor ({d:.1f}% deviation)\n", .{deviation});
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("================================================================================\n", .{});
    std.debug.print("\n", .{});
}
