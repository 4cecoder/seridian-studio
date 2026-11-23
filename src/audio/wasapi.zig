// WASAPI backend for Windows - STUB IMPLEMENTATION

const std = @import("std");
const builtin = @import("builtin");

const WASAPI_AVAILABLE = builtin.os.tag == .windows;

const log = std.log.scoped(.wasapi);

pub const WASAPIBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Engine pointer for audio callback
    engine: std.atomic.Value(?*anyopaque),
    process_fn: ?*const fn (*anyopaque, []f32) void = null,

    // Audio buffer (allocated once, reused in process callback)
    output_buffer: []f32 = &[_]f32{},

    pub fn init(allocator: std.mem.Allocator, config: anytype) !WASAPIBackend {
        if (!WASAPI_AVAILABLE) {
            log.err("WASAPI backend is only available on Windows", .{});
            return error.Unsupported;
        }

        var self = WASAPIBackend{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
            .engine = std.atomic.Value(?*anyopaque).init(null),
        };

        // Allocate output buffer
        self.output_buffer = try allocator.alloc(f32, config.buffer_size * config.channels);
        errdefer allocator.free(self.output_buffer);

        log.info("WASAPI backend initialized (sample_rate={d}, buffer_size={d}, channels={d})", .{ config.sample_rate, config.buffer_size, config.channels });
        return self;
    }

    pub fn prepare(self: *WASAPIBackend) !void {
        _ = self;
        if (!WASAPI_AVAILABLE) {
            return error.Unsupported;
        }
        log.err("WASAPI prepare() not implemented", .{});
        return error.Unsupported;
    }

    pub fn deinit(self: *WASAPIBackend) void {
        log.info("WASAPI backend shutting down...", .{});

        // Stop the audio thread
        self.stop();

        // Clear the engine pointer atomically
        self.engine.store(null, .release);
        self.process_fn = null;

        // Free the output buffer
        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
            self.output_buffer = &[_]f32{};
        }

        log.info("WASAPI backend shut down successfully", .{});
    }

    pub fn start(self: *WASAPIBackend) !void {
        _ = self;
        if (!WASAPI_AVAILABLE) {
            return error.Unsupported;
        }
        log.err("WASAPI start() not implemented", .{});
        return error.Unsupported;
    }

    pub fn stop(self: *WASAPIBackend) void {
        log.info("Stopping WASAPI playback", .{});

        // Clear running flag
        self.running.store(false, .release);

        log.info("WASAPI playback stopped", .{});
    }

    /// Set the audio engine and its process function
    /// IMPORTANT: This MUST be called before start() to avoid data races.
    /// Once the audio thread is running, this function must not be called.
    /// The process_fn is not atomic, so calling this while the thread is running
    /// would create undefined behavior.
    pub fn setEngine(self: *WASAPIBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.engine.store(engine, .release);
        self.process_fn = process_fn;
        log.info("Audio engine registered with WASAPI backend", .{});
    }
};
