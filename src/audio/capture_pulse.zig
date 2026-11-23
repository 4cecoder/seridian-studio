//! Linux audio input for recording: a capture thread on the PulseAudio
//! "simple" API, which PipeWire also serves (pipewire-pulse).
//!
//! The thread blocks in `pa_simple_read`, so it never touches the real-time
//! playback thread; each chunk is handed to `sink` as interleaved stereo f32.

const std = @import("std");

const log = std.log.scoped(.capture);

const pa_simple = opaque {};
const pa_sample_spec = extern struct {
    format: c_int,
    rate: u32,
    channels: u8,
};
const pa_buffer_attr = extern struct {
    maxlength: u32,
    tlength: u32,
    prebuf: u32,
    minreq: u32,
    fragsize: u32,
};
/// PA_SAMPLE_FLOAT32LE in enum pa_sample_format.
const PA_SAMPLE_FLOAT32LE: c_int = 5;
/// PA_STREAM_RECORD in enum pa_stream_direction.
const PA_STREAM_RECORD: c_int = 2;

extern "pulse-simple" fn pa_simple_new(server: ?[*:0]const u8, name: [*:0]const u8, dir: c_int, dev: ?[*:0]const u8, stream_name: [*:0]const u8, ss: *const pa_sample_spec, map: ?*const anyopaque, attr: ?*const pa_buffer_attr, err: ?*c_int) ?*pa_simple;
extern "pulse-simple" fn pa_simple_free(s: *pa_simple) void;
extern "pulse-simple" fn pa_simple_read(s: *pa_simple, data: *anyopaque, bytes: usize, err: ?*c_int) c_int;
extern "pulse" fn pa_strerror(err: c_int) [*:0]const u8;

/// Frames per read: 10 ms at 48 kHz keeps latency low without busy looping.
const chunk_frames = 480;

pub const Sink = struct {
    context: *anyopaque,
    /// Receives interleaved stereo samples (L, R, L, R, ...).
    write: *const fn (context: *anyopaque, stereo: []const f32) void,
};

pub const PulseCapture = struct {
    stream: *pa_simple,
    thread: std.Thread,
    running: std.atomic.Value(bool) = .init(true),
    sink: Sink,

    /// Open input `device` (null means the default source) at `sample_rate` (stereo, f32)
    /// and start reading.
    pub fn start(allocator: std.mem.Allocator, sample_rate: u32, sink: Sink, device: ?[*:0]const u8) !*PulseCapture {
        const spec: pa_sample_spec = .{ .format = PA_SAMPLE_FLOAT32LE, .rate = sample_rate, .channels = 2 };
        // fragsize bounds capture latency; the rest are server defaults.
        const attr: pa_buffer_attr = .{
            .maxlength = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = chunk_frames * 2 * @sizeOf(f32),
        };
        var err: c_int = 0;
        const stream = pa_simple_new(null, "DAW", PA_STREAM_RECORD, device, "Recording", &spec, null, &attr, &err) orelse {
            log.err("Could not open audio input: {s}", .{pa_strerror(err)});
            return error.AudioInputUnavailable;
        };
        errdefer pa_simple_free(stream);

        const self = try allocator.create(PulseCapture);
        errdefer allocator.destroy(self);
        self.* = .{ .stream = stream, .thread = undefined, .sink = sink };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        log.info("Audio input open ({d} Hz stereo)", .{sample_rate});
        return self;
    }

    /// Stop reading, close the device, and free `self`.
    pub fn stop(self: *PulseCapture, allocator: std.mem.Allocator) void {
        self.running.store(false, .release);
        self.thread.join();
        pa_simple_free(self.stream);
        allocator.destroy(self);
    }

    fn run(self: *PulseCapture) void {
        var chunk: [chunk_frames * 2]f32 = undefined;
        while (self.running.load(.acquire)) {
            var err: c_int = 0;
            if (pa_simple_read(self.stream, &chunk, @sizeOf(@TypeOf(chunk)), &err) < 0) {
                log.err("Audio input read failed: {s}", .{pa_strerror(err)});
                return;
            }
            self.sink.write(self.sink.context, &chunk);
        }
    }
};
