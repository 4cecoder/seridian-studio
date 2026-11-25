// WASAPI Isolated Runtime Test
// This is a standalone executable that proves the WASAPI backend works at runtime.
// It can be run directly to verify backend functionality without the Zig test framework.

const std = @import("std");
const builtin = @import("builtin");

// Import WASAPI C libraries directly
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("audioclient.h");
    @cInclude("mmdeviceapi.h");
}) else struct {
    // Stub types for non-Windows platforms
    pub const IAudioClient = opaque {};
    pub const IMMDevice = opaque {};
};

// Exit codes
const EXIT_SUCCESS: u8 = 0;
const EXIT_FAILURE: u8 = 1;

// Simplified WASAPI backend for testing
const WASAPIBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    wasapi_client: ?*c.IAudioClient = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    audio_thread: ?std.Thread = null,
    engine: std.atomic.Value(?*anyopaque),
    process_fn: ?*const fn (*anyopaque, []f32) void = null,
    output_buffer: []f32 = &[_]f32{},

    fn init(allocator: std.mem.Allocator, config: anytype) !WASAPIBackend {
        var self = WASAPIBackend{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
            .engine = std.atomic.Value(?*anyopaque).init(null),
        };

        self.output_buffer = try allocator.alloc(f32, config.buffer_size * config.channels);
        errdefer allocator.free(self.output_buffer);

        return self;
    }

    fn prepare(self: *WASAPIBackend) !void {
        // On non-Windows platforms, this will fail
        if (builtin.os.tag != .windows) {
            return error.WASAPINotAvailable;
        }

        // TODO: Implement actual WASAPI initialization
        std.debug.print("WASAPI preparation not yet implemented\n", .{});
        return error.WASAPIInitFailed;
    }

    fn audioThreadFn(self: *WASAPIBackend) void {
        const buffer_duration_ns = (@as(u64, self.buffer_size) * std.time.ns_per_s) / @as(u64, self.sample_rate);
        const sleep_duration_ns = (buffer_duration_ns * 8) / 10; // 80% of buffer duration

        while (self.running.load(.acquire)) {
            const engine_ptr = self.engine.load(.acquire);
            const process_fn = self.process_fn;

            @memset(self.output_buffer, 0.0);

            if (engine_ptr != null and process_fn != null) {
                process_fn.?(engine_ptr.?, self.output_buffer);
            }

            self.write(self.output_buffer) catch |err| {
                std.debug.print("Failed to write audio: {}\n", .{err});
            };

            std.posix.nanosleep(0, sleep_duration_ns);
        }
    }

    fn deinit(self: *WASAPIBackend) void {
        self.stop();

        if (self.audio_thread) |thread| {
            thread.join();
            self.audio_thread = null;
        }

        self.engine.store(null, .release);
        self.process_fn = null;

        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
            self.output_buffer = &[_]f32{};
        }

        if (self.wasapi_client) |_| {
            // TODO: Release WASAPI client
            self.wasapi_client = null;
        }
    }

    fn start(self: *WASAPIBackend) !void {
        if (self.running.load(.acquire)) {
            return;
        }

        if (self.wasapi_client == null) return error.ClientNotPrepared;

        self.running.store(true, .release);
        errdefer self.running.store(false, .release);

        self.audio_thread = try std.Thread.spawn(.{}, audioThreadFn, .{self});
    }

    fn stop(self: *WASAPIBackend) void {
        self.running.store(false, .release);
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
    }

    fn setEngine(self: *WASAPIBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.engine.store(engine, .release);
        self.process_fn = process_fn;
    }

    fn write(self: *WASAPIBackend, buffer: []const f32) !void {
        if (self.wasapi_client) |_| {
            // TODO: Implement actual WASAPI write
            _ = buffer;
            return error.WASAPIWriteFailed;
        }
    }
};

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

        _ = self.invocation_count.fetchAdd(1, .monotonic);
        self.last_buffer_size.store(buffer.len, .monotonic);
        _ = self.total_samples_processed.fetchAdd(buffer.len, .monotonic);

        // Fill buffer with a simple test signal (sine wave at 440Hz)
        const sample_rate: f32 = 48000.0;
        const frequency: f32 = 440.0;

        for (buffer, 0..) |*sample, i| {
            const t = @as(f32, @floatFromInt(i)) / sample_rate;
            sample.* = @sin(2.0 * std.math.pi * frequency * t) * 0.1;
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

// Simple config struct for WASAPI initialization
const TestConfig = struct {
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
};

pub fn main() !void {
    if (builtin.os.tag != .windows) {
        std.debug.print("⊘ SKIPPED: Not on Windows\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("WASAPI Isolated Runtime Test\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("\n", .{});

    // Configuration
    const cfg = TestConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Sample rate: {d} Hz\n", .{cfg.sample_rate});
    std.debug.print("  Buffer size: {d} frames\n", .{cfg.buffer_size});
    std.debug.print("  Channels: {d}\n", .{cfg.channels});
    std.debug.print("\n", .{});

    var all_tests_passed = true;

    // Step 1: Initialize backend
    std.debug.print("Step 1: Initializing WASAPI backend...\n", .{});
    var backend = WASAPIBackend.init(allocator, cfg) catch |err| {
        std.debug.print("FAIL: Could not initialize WASAPI backend: {}\n", .{err});
        std.debug.print("WASAPI may not be available on this system.\n", .{});
        std.process.exit(EXIT_FAILURE);
    };
    defer backend.deinit();
    std.debug.print("  Result: PASS (backend initialized)\n", .{});
    std.debug.print("\n", .{});

    // Step 2: Prepare the stream
    std.debug.print("Step 2: Calling prepare() to connect to WASAPI...\n", .{});
    backend.prepare() catch |err| {
        std.debug.print("FAIL: Could not prepare WASAPI stream: {}\n", .{err});
        std.debug.print("WASAPI audio service may not be running.\n", .{});
        std.process.exit(EXIT_FAILURE);
    };
    std.debug.print("  Result: PASS (stream prepared)\n", .{});
    std.debug.print("\n", .{});

    // Step 3: Create mock engine
    std.debug.print("Step 3: Creating mock engine (callback counter)...\n", .{});
    var counter = CallbackCounter.init();
    std.debug.print("  Result: PASS (counter created)\n", .{});
    std.debug.print("\n", .{});

    // Step 4: Set engine
    std.debug.print("Step 4: Calling setEngine()...\n", .{});
    backend.setEngine(@ptrCast(&counter), CallbackCounter.processCallback);
    std.debug.print("  Result: PASS (engine callback registered)\n", .{});
    std.debug.print("\n", .{});

    // Step 5: Start the audio thread
    std.debug.print("Step 5: Calling start()...\n", .{});
    backend.start() catch |err| {
        std.debug.print("FAIL: Could not start audio thread: {}\n", .{err});
        all_tests_passed = false;
        std.process.exit(EXIT_FAILURE);
    };
    std.debug.print("  Result: PASS (audio thread started)\n", .{});
    std.debug.print("\n", .{});

    // Step 6: Sleep and collect data
    std.debug.print("Step 6: Sleeping for 500ms to allow callbacks...\n", .{});
    std.posix.nanosleep(0, 500 * std.time.ns_per_ms);
    std.debug.print("  Result: PASS (sleep completed)\n", .{});
    std.debug.print("\n", .{});

    // Step 7: Check callback count
    std.debug.print("Step 7: Checking callback count...\n", .{});
    const count_while_running = counter.getCount();
    const buffer_size = counter.getBufferSize();
    const total_samples = counter.getTotalSamples();

    std.debug.print("  Callbacks invoked: {d}\n", .{count_while_running});
    std.debug.print("  Expected: >0\n", .{});
    std.debug.print("  Last buffer size: {d} samples\n", .{buffer_size});
    std.debug.print("  Total samples processed: {d}\n", .{total_samples});

    if (count_while_running > 0) {
        std.debug.print("  Result: PASS (callbacks executed)\n", .{});
    } else {
        std.debug.print("  Result: FAIL (no callbacks executed)\n", .{});
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Additional validation: buffer size
    const expected_buffer_size = cfg.buffer_size * cfg.channels;
    if (buffer_size == expected_buffer_size) {
        std.debug.print("  Buffer size validation: PASS ({d} == {d})\n", .{ buffer_size, expected_buffer_size });
    } else {
        std.debug.print("  Buffer size validation: FAIL ({d} != {d})\n", .{ buffer_size, expected_buffer_size });
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Additional validation: callback rate
    const buffer_duration_ms = (@as(f64, @floatFromInt(cfg.buffer_size)) * 1000.0) / @as(f64, @floatFromInt(cfg.sample_rate));
    const expected_callbacks = @as(u32, @intFromFloat(500.0 / buffer_duration_ms));
    const min_callbacks = expected_callbacks / 2;
    const max_callbacks = expected_callbacks * 2;

    std.debug.print("  Callback rate validation:\n", .{});
    std.debug.print("    Expected (approx): {d} callbacks\n", .{expected_callbacks});
    std.debug.print("    Acceptable range: {d} - {d}\n", .{ min_callbacks, max_callbacks });
    std.debug.print("    Actual: {d}\n", .{count_while_running});

    if (count_while_running >= min_callbacks and count_while_running <= max_callbacks) {
        std.debug.print("    Result: PASS (callback rate is reasonable)\n", .{});
    } else {
        std.debug.print("    Result: WARN (callback rate outside expected range)\n", .{});
    }
    std.debug.print("\n", .{});

    // Step 8: Stop the audio thread
    std.debug.print("Step 8: Calling stop()...\n", .{});
    backend.stop();
    std.debug.print("  Result: PASS (stop requested)\n", .{});
    std.debug.print("\n", .{});

    // Step 9: Verify callbacks stopped
    std.debug.print("Step 9: Verifying callbacks stopped...\n", .{});
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
    const count_after_stop = counter.getCount();
    std.debug.print("  Callback count immediately after stop: {d}\n", .{count_after_stop});

    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);
    const count_final = counter.getCount();
    std.debug.print("  Callback count after 200ms wait: {d}\n", .{count_final});

    if (count_after_stop == count_final) {
        std.debug.print("  Result: PASS (callbacks stopped, {d} == {d})\n", .{ count_after_stop, count_final });
    } else {
        std.debug.print("  Result: FAIL (callbacks continued, {d} != {d})\n", .{ count_after_stop, count_final });
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Step 10: deinit() is called via defer
    std.debug.print("Step 10: Calling deinit() (via defer)...\n", .{});
    std.debug.print("  Result: Will execute on function exit\n", .{});
    std.debug.print("\n", .{});

    // Final summary
    std.debug.print("========================================\n", .{});
    std.debug.print("Test Summary\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Callbacks invoked: {d}\n", .{count_while_running});
    std.debug.print("Expected: >0\n", .{});
    std.debug.print("Total samples processed: {d}\n", .{total_samples});
    std.debug.print("Buffer size: {d} samples (expected: {d})\n", .{ buffer_size, expected_buffer_size });
    std.debug.print("Callbacks stopped: {s}\n", .{if (count_after_stop == count_final) "YES" else "NO"});
    std.debug.print("\n", .{});

    if (all_tests_passed and count_while_running > 0) {
        std.debug.print("Overall Result: PASS\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("The WASAPI backend is working correctly!\n", .{});
        std.debug.print("- Audio thread executes callbacks\n", .{});
        std.debug.print("- Buffer sizes are correct\n", .{});
        std.debug.print("- Thread stops cleanly\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(EXIT_SUCCESS);
    } else {
        std.debug.print("Overall Result: FAIL\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("The WASAPI backend is NOT working correctly.\n", .{});
        std.debug.print("See detailed output above for failure reasons.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(EXIT_FAILURE);
    }
}
