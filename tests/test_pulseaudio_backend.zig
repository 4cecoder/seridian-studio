// Comprehensive PulseAudio Backend Tests
// Uses TDD principles to verify functionality

const std = @import("std");
const testing = std.testing;
const pulseaudio = @import("../src/audio/pulseaudio.zig");
const config = @import("../src/config.zig");

// Mock audio engine for testing
const MockEngine = struct {
    process_count: usize = 0,
    last_buffer_size: usize = 0,

    fn processCallback(ctx: *anyopaque, buffer: []f32) void {
        const self: *MockEngine = @ptrCast(@alignCast(ctx));
        self.process_count += 1;
        self.last_buffer_size = buffer.len;

        // Fill with test tone (440Hz sine wave for verification)
        const sample_rate: f32 = 48000.0;
        const frequency: f32 = 440.0;
        for (buffer, 0..) |*sample, i| {
            const t = @as(f32, @floatFromInt(i)) / sample_rate;
            sample.* = @sin(2.0 * std.math.pi * frequency * t) * 0.1;
        }
    }
};

test "PulseAudio: init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    const cfg = config.Config{
        .sample_rate = 48000,
        .buffer_size = 512,
        .audio_backend = .pulseaudio,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    // Verify initialization state
    try testing.expect(!backend.running.load(.seq_cst));
    try testing.expect(backend.stream == null); // Not prepared yet
}

test "PulseAudio: prepare creates stream" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    // Verify stream was created
    try testing.expect(backend.stream != null);
}

test "PulseAudio: setEngine stores callback" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    var mock_engine = MockEngine{};

    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    // Verify engine was set (using atomics)
    const engine_ptr = backend.engine.load(.seq_cst);
    try testing.expect(engine_ptr != null);
}

test "PulseAudio: start spawns thread" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    var mock_engine = MockEngine{};
    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    try backend.start();
    defer backend.stop();

    // Verify thread was spawned
    try testing.expect(backend.audio_thread != null);
    try testing.expect(backend.running.load(.seq_cst));

    // Let it run briefly to process some buffers
    std.time.sleep(200 * std.time.ns_per_ms);

    // Verify callbacks were invoked
    try testing.expect(mock_engine.process_count > 0);
    try testing.expect(mock_engine.last_buffer_size == 512 * 2); // stereo
}

test "PulseAudio: stop halts thread" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    var mock_engine = MockEngine{};
    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);

    const count_before_stop = mock_engine.process_count;

    backend.stop();

    // Verify running flag is cleared
    try testing.expect(!backend.running.load(.seq_cst));

    // Wait to ensure thread actually stopped
    std.time.sleep(100 * std.time.ns_per_ms);

    // Process count should not increase after stop
    try testing.expect(mock_engine.process_count == count_before_stop);
}

test "PulseAudio: multiple start/stop cycles" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    var mock_engine = MockEngine{};
    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    // Cycle 1
    try backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    backend.stop();

    const count1 = mock_engine.process_count;
    try testing.expect(count1 > 0);

    // Cycle 2
    try backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    backend.stop();

    const count2 = mock_engine.process_count;
    try testing.expect(count2 > count1);

    // Cycle 3
    try backend.start();
    std.time.sleep(50 * std.time.ns_per_ms);
    backend.stop();

    const count3 = mock_engine.process_count;
    try testing.expect(count3 > count2);
}

test "PulseAudio: buffer size matches configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_buffer_size: u32 = 256;

    const cfg = config.Config{
        .sample_rate = 44100,
        .buffer_size = test_buffer_size,
        .audio_backend = .pulseaudio,
        .midi_backend = .none,
        .project_dir = "/tmp/daw_test",
    };

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    var mock_engine = MockEngine{};
    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    backend.stop();

    // Verify buffer size (stereo = 2 channels)
    try testing.expectEqual(test_buffer_size * 2, mock_engine.last_buffer_size);
}

test "PulseAudio: no callbacks without setEngine" {
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

    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    // Start without setting engine
    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    backend.stop();

    // Should complete without crashing (thread handles null engine gracefully)
}
