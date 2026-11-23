const std = @import("std");
const builtin = @import("builtin");

// libpulse-simple bindings (pulse/simple.h, pulse/error.h); the stubs keep
// other platforms compiling without the library.
const pa_types = struct {
    pub const pa_simple = opaque {};
    pub const pa_sample_spec = extern struct {
        format: c_int = 0,
        rate: u32 = 0,
        channels: u8 = 0,
    };
    pub const pa_buffer_attr = extern struct {
        maxlength: u32 = 0,
        tlength: u32 = 0,
        prebuf: u32 = 0,
        minreq: u32 = 0,
        fragsize: u32 = 0,
    };
    /// PA_SAMPLE_FLOAT32LE in enum pa_sample_format.
    pub const PA_SAMPLE_FLOAT32LE: c_int = 5;
    /// PA_STREAM_PLAYBACK in enum pa_stream_direction.
    pub const PA_STREAM_PLAYBACK: c_int = 1;
};

const c = if (builtin.os.tag == .linux) struct {
    pub const pa_simple = pa_types.pa_simple;
    pub const pa_sample_spec = pa_types.pa_sample_spec;
    pub const pa_buffer_attr = pa_types.pa_buffer_attr;
    pub const PA_SAMPLE_FLOAT32LE = pa_types.PA_SAMPLE_FLOAT32LE;
    pub const PA_STREAM_PLAYBACK = pa_types.PA_STREAM_PLAYBACK;
    pub extern "pulse-simple" fn pa_simple_new(server: ?[*:0]const u8, name: [*:0]const u8, dir: c_int, dev: ?[*:0]const u8, stream_name: [*:0]const u8, ss: *const pa_sample_spec, map: ?*const anyopaque, attr: ?*const pa_buffer_attr, err: ?*c_int) ?*pa_simple;
    pub extern "pulse-simple" fn pa_simple_free(s: *pa_simple) void;
    pub extern "pulse-simple" fn pa_simple_write(s: *pa_simple, data: *const anyopaque, bytes: usize, err: ?*c_int) c_int;
    pub extern "pulse" fn pa_strerror(err: c_int) [*:0]const u8;
} else struct {
    pub const pa_simple = pa_types.pa_simple;
    pub const pa_sample_spec = pa_types.pa_sample_spec;
    pub const pa_buffer_attr = pa_types.pa_buffer_attr;
    pub const PA_SAMPLE_FLOAT32LE = pa_types.PA_SAMPLE_FLOAT32LE;
    pub const PA_STREAM_PLAYBACK = pa_types.PA_STREAM_PLAYBACK;
    pub fn pa_simple_new(_: ?[*:0]const u8, _: [*:0]const u8, _: c_int, _: ?[*:0]const u8, _: [*:0]const u8, _: *const pa_sample_spec, _: ?*const anyopaque, _: ?*const pa_buffer_attr, _: ?*c_int) ?*pa_simple {
        return null;
    }
    pub fn pa_simple_free(_: *pa_simple) void {}
    pub fn pa_simple_write(_: *pa_simple, _: *const anyopaque, _: usize, _: ?*c_int) c_int {
        return -1;
    }
    pub fn pa_strerror(_: c_int) [*:0]const u8 {
        return "PulseAudio not available on this platform";
    }
};

const log = std.log.scoped(.pulseaudio);

pub const PulseAudioBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    pa_stream: ?*c.pa_simple = null,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    engine: std.atomic.Value(?*anyopaque) = .init(null),
    process_fn: ?*const fn (*anyopaque, []f32) void = null,
    render_buffer: []f32 = &.{},
    /// Sink name, NUL-terminated; all zero means the default sink (`dev = NULL`).
    device_name: [128]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, config: anytype) !PulseAudioBackend {
        log.info("Initializing PulseAudio backend", .{});

        var self = PulseAudioBackend{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
        };
        // Names of 128 bytes or longer cannot be stored with a terminator.
        if (config.device.len >= self.device_name.len) return error.DeviceNameTooLong;
        @memcpy(self.device_name[0..config.device.len], config.device);

        // Pre-initialize stream for low latency
        try self.prepare();

        return self;
    }

    fn prepare(self: *PulseAudioBackend) !void {
        var error_code: c_int = 0;

        const spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = self.sample_rate,
            .channels = self.channels,
        };

        const buffer_attr = c.pa_buffer_attr{
            .maxlength = @as(u32, @intCast(@sizeOf(f32) * self.buffer_size * self.channels)),
            .tlength = @as(u32, @intCast(@sizeOf(f32) * self.buffer_size * self.channels)),
            .prebuf = 0,
            .minreq = @as(u32, @intCast(@sizeOf(f32) * self.buffer_size * self.channels)),
            .fragsize = @as(u32, @intCast(@sizeOf(f32) * self.buffer_size * self.channels)),
        };

        const device: ?[*:0]const u8 = if (self.device_name[0] == 0) null else @ptrCast(&self.device_name);

        self.pa_stream = c.pa_simple_new(
            null, // Default server
            "DAW",
            c.PA_STREAM_PLAYBACK,
            device,
            "Audio Output",
            &spec,
            null, // Default channel map
            &buffer_attr,
            &error_code,
        ) orelse {
            const err_msg = c.pa_strerror(error_code);
            log.err("Failed to create PulseAudio stream: {s}", .{err_msg});
            return error.PulseAudioInitFailed;
        };

        log.info("PulseAudio stream created successfully", .{});
    }

    pub fn deinit(self: *PulseAudioBackend) void {
        self.stop();
        if (self.render_buffer.len > 0) self.allocator.free(self.render_buffer);
        self.render_buffer = &.{};
        if (self.pa_stream) |stream| {
            c.pa_simple_free(stream);
            self.pa_stream = null;
        }
        log.info("PulseAudio backend shut down", .{});
    }

    pub fn setEngine(self: *PulseAudioBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.process_fn = process_fn;
        self.engine.store(engine, .release);
    }

    /// Start the render thread: pull a block from the engine, then block in
    /// pa_simple_write until the server wants more (it paces the loop).
    pub fn start(self: *PulseAudioBackend) !void {
        if (self.running.load(.acquire)) return;
        if (self.pa_stream == null) return error.PulseAudioNotReady;
        // The stream sits idle while paused/stopped and underruns; on the next write the
        // server asks for the whole idle gap at once, so the render loop bursts through
        // seconds of audio and the engine position races ahead of real time. A fresh
        // stream starts with no underrun history.
        if (self.pa_stream) |stale| {
            c.pa_simple_free(stale);
            self.pa_stream = null;
        }
        try self.prepare();
        if (self.render_buffer.len == 0) {
            self.render_buffer = try self.allocator.alloc(f32, @as(usize, self.buffer_size) * self.channels);
        }
        log.info("Starting PulseAudio playback", .{});
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, renderLoop, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    pub fn stop(self: *PulseAudioBackend) void {
        if (!self.running.swap(false, .acq_rel)) return;
        log.info("Stopping PulseAudio playback", .{});
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn renderLoop(self: *PulseAudioBackend) void {
        while (self.running.load(.acquire)) {
            if (self.engine.load(.acquire)) |engine| {
                if (self.process_fn) |process| process(engine, self.render_buffer) else @memset(self.render_buffer, 0);
            } else {
                @memset(self.render_buffer, 0);
            }
            self.write(self.render_buffer) catch return;
        }
    }

    pub fn write(self: *PulseAudioBackend, buffer: []const f32) !void {
        if (self.pa_stream) |stream| {
            var error_code: c_int = 0;
            const result = c.pa_simple_write(
                stream,
                buffer.ptr,
                buffer.len * @sizeOf(f32),
                &error_code,
            );

            if (result < 0) {
                const err_msg = c.pa_strerror(error_code);
                log.err("Failed to write to PulseAudio: {s}", .{err_msg});
                return error.PulseAudioWriteFailed;
            }
        }
    }
};
