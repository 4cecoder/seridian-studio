// Translated to Zig from soundcraft/crates/mix/src/strip.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Multichannel PDC delay line: Rust `DelayLine` and `MAX_LATENCY` from
//! `crates/mix/src/strip.rs`, adapted for the audio thread.
//!
//! The Rust version grows its rings inside `set` and `process` (`Vec::resize_with`,
//! `Vec::with_capacity`), which allocates on the audio thread. Here every ring is
//! allocated once in `prepare` on the control thread, sized to a caller-chosen
//! maximum delay. `setDelay`, `process` and `clear` only move an index or write
//! into the existing storage: they never allocate, lock, log or do I/O.
//!
//! Memory cost: `channels * (capacity + 1) * 4` bytes. `MAX_LATENCY` (2^20
//! samples) at 2 channels is about 8 MiB, so the owner should pass a smaller,
//! project-specific cap. If a strip needs more delay than its capacity, the
//! control thread builds a new `DelayLine` and swaps it in (handoff belongs to
//! graph-3, not here).

const std = @import("std");

/// Most latency delay compensation handles: 2^20 samples, about 22 s at 48 kHz.
/// A strip reports at most this, whatever its plugins claim.
pub const MAX_LATENCY: usize = 1 << 20;

pub const DelayLine = struct {
    /// All rings back to back: channel `c` owns `storage[c * ring_len ..][0..ring_len]`.
    /// Allocated by `prepare`, freed by `deinit`. Empty until prepared.
    storage: []f32 = &.{},
    /// Number of rings in `storage`, fixed by `prepare`.
    channels: usize = 0,
    /// Samples per ring: `capacity + 1`. The extra slot lets a delay of exactly
    /// `capacity` be read from a ring that was just written.
    ring_len: usize = 0,
    /// Largest delay `setDelay` accepts (samples).
    capacity: usize = 0,
    /// Write position, the same in every ring.
    idx: usize = 0,
    /// Current delay (samples). 0 means bypass.
    len: usize = 0,

    /// Control thread. Allocates all storage for `max_channels` rings that can
    /// each delay up to `max_delay` samples (clamped to `MAX_LATENCY`). Calling
    /// it again frees the previous storage, so `gpa` must be the same allocator
    /// that was used before.
    pub fn prepare(self: *DelayLine, gpa: std.mem.Allocator, max_delay: usize, max_channels: usize) !void {
        const capacity = @min(max_delay, MAX_LATENCY);
        const ring_len = capacity + 1;
        const total = try std.math.mul(usize, ring_len, max_channels);
        const storage = try gpa.alloc(f32, total);
        @memset(storage, 0);
        self.deinit(gpa);
        self.* = .{
            .storage = storage,
            .channels = max_channels,
            .ring_len = ring_len,
            .capacity = capacity,
        };
    }

    /// Control thread. Frees the storage and resets to the unprepared state.
    pub fn deinit(self: *DelayLine, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
        self.* = .{};
    }

    /// Audio thread. Sets the delay to `len` samples, which keeps the storage and
    /// the held samples. Returns `false` when `len` exceeds `capacity`; the delay is
    /// then clamped to `capacity` (Rust clamps to `MAX_LATENCY`).
    pub fn setDelay(self: *DelayLine, len: usize) bool {
        if (len <= self.capacity) {
            self.len = len;
            return true;
        }
        self.len = self.capacity;
        return false;
    }

    /// Audio thread. Delays the first `min(io.len, channels)` channels in place by
    /// `len` samples. Every channel pointer must address at least `frames` samples.
    /// Channels beyond the prepared count pass through unchanged, as in Rust. With
    /// `len == 0` this is a no-op and the write position does not move.
    pub fn process(self: *DelayLine, io: []const [*]f32, frames: usize) void {
        if (self.len == 0) return;
        const n = @min(io.len, self.channels);
        if (n == 0) return;
        const rl = self.ring_len;
        const start = self.idx;
        for (0..n) |c| {
            const ring = self.storage[c * rl ..][0..rl];
            const x = io[c];
            var w = start;
            // len <= capacity = rl - 1, so the read slot never equals the write slot.
            var r = (start + rl - self.len) % rl;
            for (0..frames) |f| {
                ring[w] = x[f];
                x[f] = ring[r];
                w += 1;
                if (w == rl) w = 0;
                r += 1;
                if (r == rl) r = 0;
            }
        }
        self.idx = (start + frames % rl) % rl;
    }

    /// Audio thread. Zeroes all held samples. Delay, write position and storage
    /// are kept (Rust `clear`).
    pub fn clear(self: *DelayLine) void {
        @memset(self.storage, 0);
    }
};

test "delay_line_change_keeps_buffers_and_history" {
    // #889: a latency change must not reallocate or zero the delay line in the callback.
    const gpa = std.testing.allocator;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 480, 2);
    try std.testing.expect(d.setDelay(480));
    const ptr = @intFromPtr(d.storage.ptr);

    var a: [480]f32 = undefined;
    var b: [480]f32 = undefined;
    for (0..480) |i| {
        a[i] = @floatFromInt(i + 1);
        b[i] = @floatFromInt(i + 1);
    }
    var chans = [_][*]f32{ &a, &b };
    d.process(chans[0..], 480);
    for (0..480) |i| {
        try std.testing.expectEqual(@as(f32, 0.0), a[i]);
        try std.testing.expectEqual(@as(f32, 0.0), b[i]);
    }

    // Shorter delay: the line keeps its storage and outputs what it already holds.
    try std.testing.expect(d.setDelay(240));
    try std.testing.expectEqual(ptr, @intFromPtr(d.storage.ptr));
    var c: [240]f32 = @splat(0);
    var e: [240]f32 = @splat(0);
    var chans2 = [_][*]f32{ &c, &e };
    d.process(chans2[0..], 240);
    var want: [240]f32 = undefined;
    for (0..240) |i| want[i] = @floatFromInt(241 + i);
    try std.testing.expectEqualSlices(f32, &want, &c);
    try std.testing.expectEqualSlices(f32, &want, &e);

    // Back to the longer delay: still the same storage.
    try std.testing.expect(d.setDelay(480));
    try std.testing.expectEqual(ptr, @intFromPtr(d.storage.ptr));
}

test "one-sample delay shifts the signal by one frame" {
    const gpa = std.testing.allocator;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 4, 1);
    try std.testing.expect(d.setDelay(1));
    var x = [_]f32{ 1, 2, 3, 4, 5 };
    var chans = [_][*]f32{&x};
    d.process(chans[0..], x.len);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 0, 1, 2, 3, 4 }, &x);
}

test "delay of zero is bypass: audio and write position untouched" {
    const gpa = std.testing.allocator;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 16, 2);
    var a = [_]f32{ 0.25, -0.5, 0.75 };
    var b = [_]f32{ 1, 2, 3 };
    var chans = [_][*]f32{ &a, &b };
    d.process(chans[0..], 3);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 0.25, -0.5, 0.75 }, &a);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, &b);
    try std.testing.expectEqual(@as(usize, 0), d.idx);
}

test "process matches a full-history reference bit for bit across delay changes" {
    const gpa = std.testing.allocator;
    const cap: usize = 300;
    const channels = 2;
    const blocks = 64;
    const max_frames = 700;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, cap, channels);

    // Reference: every sample ever written (delay > 0 frames only), per channel.
    // Output for write number k is hist[k - len] when k >= len, else 0.
    const total = blocks * max_frames;
    const hist = try gpa.alloc(f32, channels * total);
    defer gpa.free(hist);
    @memset(hist, 0);
    var written: usize = 0;

    var prng = std.Random.DefaultPrng.init(0x5eed_d31a);
    const rnd = prng.random();

    var input: [channels][max_frames]f32 = undefined;
    var dut: [channels][max_frames]f32 = undefined;
    var want: [channels][max_frames]f32 = undefined;
    var ptrs: [channels][*]f32 = undefined;
    for (0..channels) |c| ptrs[c] = &dut[c];

    for (0..blocks) |b| {
        const frames = rnd.intRangeAtMost(usize, 1, max_frames);
        const len: usize = switch (b % 5) {
            0 => 0,
            1 => cap,
            2 => 1,
            else => rnd.intRangeAtMost(usize, 1, cap),
        };
        for (0..channels) |c| {
            for (0..frames) |f| input[c][f] = rnd.float(f32) * 2.0 - 1.0;
            @memcpy(dut[c][0..frames], input[c][0..frames]);
        }

        try std.testing.expect(d.setDelay(len));
        d.process(ptrs[0..], frames);

        if (len == 0) {
            for (0..channels) |c| @memcpy(want[c][0..frames], input[c][0..frames]);
        } else {
            for (0..frames) |f| {
                const k = written + f;
                for (0..channels) |c| {
                    want[c][f] = if (k >= len) hist[c * total + k - len] else 0;
                    hist[c * total + k] = input[c][f];
                }
            }
            written += frames;
        }

        for (0..channels) |c| {
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(want[c][0..frames]),
                std.mem.sliceAsBytes(dut[c][0..frames]),
            );
        }
    }
}

test "setDelay reports requests beyond capacity and clamps them" {
    const gpa = std.testing.allocator;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 100, 1);
    try std.testing.expect(d.setDelay(100));
    try std.testing.expectEqual(@as(usize, 100), d.len);
    try std.testing.expect(!d.setDelay(101));
    try std.testing.expectEqual(@as(usize, 100), d.len);
    try std.testing.expect(d.setDelay(0));
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "prepare sizes storage as channels * (capacity + 1) and clamps to MAX_LATENCY" {
    const gpa = std.testing.allocator;
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 100, 3);
    try std.testing.expectEqual(@as(usize, 3 * 101), d.storage.len);
    try std.testing.expectEqual(@as(usize, 100), d.capacity);

    try d.prepare(gpa, MAX_LATENCY + 5, 0);
    try std.testing.expectEqual(MAX_LATENCY, d.capacity);
    try std.testing.expectEqual(@as(usize, 0), d.storage.len);
}

test "prepare, setDelay, process and clear allocate nothing after prepare" {
    // Counting allocator: prepare is the only call that takes an allocator.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = counting.allocator();
    var d: DelayLine = .{};
    defer d.deinit(gpa);
    try d.prepare(gpa, 1024, 2);

    const allocs_before = counting.allocations;
    const frees_before = counting.deallocations;

    var a: [256]f32 = @splat(0.5);
    var b: [256]f32 = @splat(-0.5);
    var chans = [_][*]f32{ &a, &b };
    for (0..100) |i| {
        try std.testing.expect(d.setDelay((i * 37) % 1025));
        d.process(chans[0..], 256);
    }
    d.clear();

    try std.testing.expectEqual(allocs_before, counting.allocations);
    try std.testing.expectEqual(frees_before, counting.deallocations);
}
