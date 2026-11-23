//! Native PipeWire playback backend.
//!
//! The stream itself is in pw_stream.zig (libpipewire through hand-written
//! declarations, the SPA format POD built by spa_pod.zig). This side adapts PipeWire's variable-size requests to the engine, which
//! always renders exactly `buffer_size` frames per call: `BlockAdapter` renders
//! whole engine blocks and hands out as many frames as PipeWire asks for, so
//! the transport position stays sample-accurate at any graph quantum.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.pipewire_backend);

/// The PipeWire stream on Linux; elsewhere a stand-in that never opens, so nothing links
/// against libpipewire.
const pw = if (builtin.os.tag == .linux) @import("pw_stream.zig") else struct {
    pub const RenderFn = *const fn (ctx: ?*anyopaque, out: [*]f32, frames: u32) void;
    pub const Stream = struct {
        pub fn open(_: std.mem.Allocator, _: u32, _: u32, _: u32, _: RenderFn, _: ?*anyopaque) error{Unsupported}!*Stream {
            return error.Unsupported;
        }
        pub fn setActive(_: *Stream, _: bool) c_int {
            return -1;
        }
        pub fn close(_: *Stream) void {}
    };
};
const PwStream = pw.Stream;

pub const ProcessFn = *const fn (*anyopaque, []f32) void;

/// Re-blocks a fixed-size block renderer into arbitrary-size reads.
/// Real-time safe: no allocation after init.
pub const BlockAdapter = struct {
    block: []f32,
    /// Interleaved channels per frame.
    channels: usize,
    /// Next unread sample in `block`; `block.len` means the block is used up.
    read_pos: usize,
    engine: std.atomic.Value(?*anyopaque) = .init(null),
    process_fn: std.atomic.Value(?ProcessFn) = .init(null),

    pub fn init(allocator: std.mem.Allocator, block_frames: usize, channels: usize) !BlockAdapter {
        const block = try allocator.alloc(f32, block_frames * channels);
        return .{ .block = block, .channels = channels, .read_pos = block.len };
    }

    pub fn deinit(self: *BlockAdapter, allocator: std.mem.Allocator) void {
        allocator.free(self.block);
    }

    /// Fill `out` completely, rendering new blocks as needed.
    pub fn fill(self: *BlockAdapter, out: []f32) void {
        var written: usize = 0;
        while (written < out.len) {
            if (self.read_pos == self.block.len) {
                const engine = self.engine.load(.acquire);
                const process = self.process_fn.load(.acquire);
                if (engine != null and process != null) process.?(engine.?, self.block) else @memset(self.block, 0);
                self.read_pos = 0;
            }
            const n = @min(out.len - written, self.block.len - self.read_pos);
            @memcpy(out[written..][0..n], self.block[self.read_pos..][0..n]);
            written += n;
            self.read_pos += n;
        }
    }
};

pub const PipeWireBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    /// Heap-allocated so its address stays fixed while the backend value moves.
    adapter: *BlockAdapter,
    stream: *PwStream,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, config: anytype) !PipeWireBackend {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        log.info("Initializing PipeWire backend", .{});

        const adapter = try allocator.create(BlockAdapter);
        errdefer allocator.destroy(adapter);
        adapter.* = try BlockAdapter.init(allocator, config.buffer_size, config.channels);
        errdefer adapter.deinit(allocator);

        const stream = PwStream.open(allocator, config.sample_rate, config.channels, config.buffer_size, render, adapter) catch |err| {
            log.warn("PipeWire stream unavailable: {}", .{err});
            return error.ConnectFailed;
        };

        log.info("PipeWire backend initialized: {d}Hz, {d} channels, buffer={d}", .{ config.sample_rate, config.channels, config.buffer_size });
        return .{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
            .adapter = adapter,
            .stream = stream,
        };
    }

    pub fn deinit(self: *PipeWireBackend) void {
        self.stop();
        self.stream.close();
        self.adapter.deinit(self.allocator);
        self.allocator.destroy(self.adapter);
        log.info("PipeWire backend shut down", .{});
    }

    pub fn start(self: *PipeWireBackend) !void {
        if (self.running.swap(true, .acq_rel)) return;
        const res = self.stream.setActive(true);
        if (res < 0) {
            self.running.store(false, .release);
            log.err("Could not start the PipeWire stream ({d})", .{res});
            return error.StreamStartFailed;
        }
        log.info("PipeWire playback started", .{});
    }

    pub fn stop(self: *PipeWireBackend) void {
        if (!self.running.swap(false, .acq_rel)) return;
        const res = self.stream.setActive(false);
        if (res < 0) log.warn("Could not pause the PipeWire stream ({d})", .{res});
        log.info("PipeWire playback stopped", .{});
    }

    pub fn setEngine(self: *PipeWireBackend, engine: *anyopaque, process_fn: ProcessFn) void {
        self.adapter.process_fn.store(process_fn, .release);
        self.adapter.engine.store(engine, .release);
    }

    pub fn isRunning(self: *const PipeWireBackend) bool {
        return self.running.load(.acquire);
    }

    /// PipeWire data-thread callback.
    fn render(ctx: ?*anyopaque, out: [*]f32, frames: u32) void {
        const rt_safe = @import("rt_safe.zig");
        rt_safe.is_audio_thread = true;
        defer rt_safe.is_audio_thread = false;

        const adapter: *BlockAdapter = @ptrCast(@alignCast(ctx.?));
        adapter.fill(out[0 .. @as(usize, frames) * adapter.channels]);
    }
};

const TestCounter = struct {
    calls: usize = 0,

    fn process(ctx: *anyopaque, block: []f32) void {
        const self: *TestCounter = @ptrCast(@alignCast(ctx));
        for (block, 0..) |*s, i| s.* = @floatFromInt(self.calls * block.len + i);
        self.calls += 1;
    }
};

test "BlockAdapter re-blocks without losing or repeating samples" {
    var adapter = try BlockAdapter.init(std.testing.allocator, 4, 2);
    defer adapter.deinit(std.testing.allocator);
    var counter: TestCounter = .{};
    adapter.engine.store(&counter, .release);
    adapter.process_fn.store(TestCounter.process, .release);

    // Odd-sized reads across block boundaries must yield a continuous ramp.
    var out: [64]f32 = undefined;
    var offset: usize = 0;
    for ([_]usize{ 3, 5, 13, 1, 22, 20 }) |n| {
        adapter.fill(out[offset..][0..n]);
        offset += n;
    }
    for (out, 0..) |s, i| try std.testing.expectEqual(@as(f32, @floatFromInt(i)), s);
    try std.testing.expectEqual(@as(usize, 8), counter.calls);
}

test "BlockAdapter outputs silence without an engine" {
    var adapter = try BlockAdapter.init(std.testing.allocator, 2, 2);
    defer adapter.deinit(std.testing.allocator);
    var out: [10]f32 = @splat(1.0);
    adapter.fill(&out);
    for (out) |s| try std.testing.expectEqual(@as(f32, 0), s);
}
