//! Silent output used when no audio server is reachable (headless CI, a
//! stopped PipeWire). A timer thread still pulls the engine at the real-time
//! rate, so transport, meters and recording-to-timeline keep working.

const std = @import("std");
const sys = @import("../utils/sys.zig");

const log = std.log.scoped(.null_backend);

pub const NullBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    buffer: []f32,
    engine: std.atomic.Value(?*anyopaque) = .init(null),
    process_fn: ?*const fn (*anyopaque, []f32) void = null,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, config: anytype) !NullBackend {
        log.warn("No audio output available; running silently", .{});
        return .{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
            .buffer = try allocator.alloc(f32, @as(usize, config.buffer_size) * config.channels),
        };
    }

    pub fn deinit(self: *NullBackend) void {
        self.stop();
        self.allocator.free(self.buffer);
    }

    pub fn setEngine(self: *NullBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.process_fn = process_fn;
        self.engine.store(engine, .release);
    }

    pub fn start(self: *NullBackend) !void {
        if (self.running.swap(true, .acq_rel)) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    pub fn stop(self: *NullBackend) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(self: *NullBackend) void {
        const period_ns: u64 = @as(u64, self.buffer_size) * std.time.ns_per_s / self.sample_rate;
        var next = sys.nanoTimestamp();
        while (self.running.load(.acquire)) {
            if (self.engine.load(.acquire)) |engine| {
                if (self.process_fn) |process| process(engine, self.buffer);
            }
            next += period_ns;
            const now = sys.nanoTimestamp();
            if (next > now) sys.sleepNs(@intCast(next - now)) else next = now;
        }
    }
};

test "null backend renders at the requested rate" {
    const Counter = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn process(ctx: *anyopaque, out: []f32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memset(out, 0);
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    };
    var counter: Counter = .{};
    var backend = try NullBackend.init(std.testing.allocator, .{ .sample_rate = 48000, .buffer_size = 480, .channels = 2 });
    defer backend.deinit();
    backend.setEngine(&counter, Counter.process);
    try backend.start();
    sys.sleepNs(55 * std.time.ns_per_ms); // ~5 periods of 10 ms
    backend.stop();
    const calls = counter.calls.load(.monotonic);
    try std.testing.expect(calls >= 3 and calls <= 8);
}
