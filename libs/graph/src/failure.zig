// Translated to Zig from soundcraft/crates/mix/src/strip.rs, soundcraft/crates/mix/src/instances.rs, soundcraft/crates/mix/src/tests.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Failure containment for graph plugin slots.
//!
//! A plugin that puts out NaN or infinity must not poison the mix. The strip render
//! calls [`containFailure`] on the slot's output block. A non-finite block is silenced
//! and the caller marks the slot failed (`SlotTable.recordFailure`), which counts it.
//! A failed slot is bypassed until the next reset (`SlotTable.reset`) and reports no
//! latency, so delay compensation stops waiting for it ([`insertLatency`],
//! [`stripLatency`], [`instrumentLatency`]). The same rule applies to inserts,
//! instruments and master inserts.
//!
//! Latency policy: [`capLatency`] is the single definition of the MAX_LATENCY clamp on a
//! reported plugin latency. `pdc.zig` must call it instead of a private copy.
//!
//! What is not here:
//! - Panic containment. SoundCraft wraps plugin calls in `catch_unwind`. Zig cannot
//!   unwind, so this file does not emulate it. A plugin that crashes the process needs
//!   process isolation (a future sandbox host).
//! - The stall and fault flag. That belongs to session-guard.
//!
//! Real-time rules: every function the audio thread calls here ([`containFailure`],
//! [`outputIsFinite`], [`silence`], [`insertLatency`], [`stripLatency`],
//! [`instrumentLatency`], [`capLatency`], [`AtomicFailures.record`]) takes no allocator
//! and does no locking, logging or I/O. The failure count is atomic so the control thread
//! can read and log it without a lock.

const std = @import("std");
const proc_mod = @import("processor.zig");
const slot = @import("slot.zig");
const delay_line = @import("delay_line.zig");
const topology = @import("topology.zig");
const pdc = @import("pdc.zig");

pub const Processor = proc_mod.Processor;
pub const PluginFailures = slot.PluginFailures;
pub const INSTRUMENT_SLOT = slot.INSTRUMENT_SLOT;
pub const MAX_LATENCY = delay_line.MAX_LATENCY;

/// Caps one reported latency at `MAX_LATENCY` (Rust `strip.latency.min(MAX_LATENCY)`).
/// The graph's only latency cap.
pub fn capLatency(n: usize) usize {
    return @min(n, MAX_LATENCY);
}

/// True when every sample of the first `frames` of every channel is finite. As in Rust
/// (`c.get(..frames).unwrap_or(c)`), a channel shorter than `frames` is scanned whole.
/// The fold is branch-free on purpose, so it vectorises.
pub fn outputIsFinite(io: []const []f32, frames: usize) bool {
    var ok: u1 = 1;
    for (io) |ch| {
        const n = @min(frames, ch.len);
        for (ch[0..n]) |x| ok &= @intFromBool(std.math.isFinite(x));
    }
    return ok == 1;
}

/// Zeroes the first `frames` samples of every channel.
pub fn silence(io: [][]f32, frames: usize) void {
    for (io) |ch| @memset(ch[0..@min(frames, ch.len)], 0);
}

/// Rust `contain_failure`, output half. Returns false and leaves `io` alone when the block
/// is finite. Otherwise it silences the block and returns true. The caller then marks the
/// slot failed and counts it (`SlotTable.recordFailure`), so the slot is bypassed until the
/// next reset.
pub fn containFailure(io: [][]f32, frames: usize) bool {
    if (outputIsFinite(io, frames)) return false;
    silence(io, frames);
    return true;
}

/// Failure count for the control thread to log. The audio thread writes it; the control
/// thread reads it with [`snapshot`]. Single writer.
pub const AtomicFailures = struct {
    count: std.atomic.Value(u32) = .init(0),
    last: std.atomic.Value(usize) = .init(0),

    /// Audio thread. Counts one failure in `slot_index`. Wraps, as Rust does.
    pub fn record(self: *AtomicFailures, slot_index: usize) void {
        self.last.store(slot_index, .release);
        _ = self.count.fetchAdd(1, .release);
    }

    /// Control thread. Reads `count` first, then `last`. Under a concurrent `record`, `last`
    /// may already belong to a later failure than `count`.
    pub fn snapshot(self: *const AtomicFailures) PluginFailures {
        const count = self.count.load(.acquire);
        const last = self.last.load(.acquire);
        return .{ .count = count, .last = last };
    }
};

/// Latency one insert adds to its strip this block. An inactive or bypassed insert adds
/// nothing, and neither does one that failed (Rust `run_inserts` `continue` and
/// `note_insert_latency`). `reported` is the plugin's own latency, unclamped.
pub fn insertLatency(active: bool, bypass: bool, failed: bool, reported: usize) usize {
    if (!active or bypass or failed) return 0;
    return reported;
}

/// A strip's latency: the saturating sum of its inserts' contributions, capped at
/// `MAX_LATENCY` (Rust `strip.latency = latency.min(MAX_LATENCY)`).
pub fn stripLatency(contributions: []const usize) usize {
    var sum: usize = 0;
    for (contributions) |c| sum +|= c;
    return capLatency(sum);
}

/// The latency an instrument reports to delay compensation. A failed instrument reports
/// none. SoundCraft does not add instrument latency at all; graph does (see `pdc.zig`),
/// so this is that term.
pub fn instrumentLatency(failed: bool, reported: usize) usize {
    if (failed) return 0;
    return capLatency(reported);
}

test "outputIsFinite: NaN, +inf and -inf are not finite, a finite block is" {
    var ok_buf = [_]f32{ 0.5, -1.0, 0.0 };
    var nan_buf = [_]f32{ 0.5, std.math.nan(f32), 0.0 };
    var inf_buf = [_]f32{ 0.5, std.math.inf(f32), 0.0 };
    var neg_buf = [_]f32{ -std.math.inf(f32), 0.5, 0.0 };
    var ok_ch = [_][]f32{&ok_buf};
    var nan_ch = [_][]f32{&nan_buf};
    var inf_ch = [_][]f32{&inf_buf};
    var neg_ch = [_][]f32{&neg_buf};
    try testing.expect(outputIsFinite(&ok_ch, 3));
    try testing.expect(!outputIsFinite(&nan_ch, 3));
    try testing.expect(!outputIsFinite(&inf_ch, 3));
    try testing.expect(!outputIsFinite(&neg_ch, 3));
}

test "containFailure only scans the first frames samples and silences only those" {
    var a = [_]f32{ 0.25, 0.25, std.math.nan(f32), 0.25 };
    var b = [_]f32{ 0.25, 0.25, 0.25, 0.25 };
    var chans = [_][]f32{ &a, &b };
    // The NaN sits past `frames`: the block is finite as far as the slot's output goes.
    try testing.expect(!containFailure(&chans, 2));
    try testing.expectEqual(@as(f32, 0.25), a[1]);
    // Now the NaN is inside the frames: silence the first `frames` samples only.
    try testing.expect(containFailure(&chans, 4));
    for (chans) |ch| {
        try testing.expectEqual(@as(f32, 0.0), ch[0]);
        try testing.expectEqual(@as(f32, 0.0), ch[3]);
    }
}

test "AtomicFailures: counts every failure and remembers the latest slot" {
    var f: AtomicFailures = .{};
    try testing.expectEqual(PluginFailures{}, f.snapshot());
    f.record(2);
    f.record(INSTRUMENT_SLOT);
    try testing.expectEqual(PluginFailures{ .count = 2, .last = INSTRUMENT_SLOT }, f.snapshot());
}

test "a plugin's bogus latency is capped at MAX_LATENCY" {
    try testing.expectEqual(MAX_LATENCY, capLatency(std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 48), capLatency(48));
    try testing.expectEqual(MAX_LATENCY, stripLatency(&.{ std.math.maxInt(usize), 5 }));
    try testing.expectEqual(MAX_LATENCY, instrumentLatency(false, std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 0), instrumentLatency(true, 48));
}

test "insertLatency: inactive, bypassed and failed inserts report nothing" {
    try testing.expectEqual(@as(usize, 48), insertLatency(true, false, false, 48));
    try testing.expectEqual(@as(usize, 0), insertLatency(false, false, false, 48));
    try testing.expectEqual(@as(usize, 0), insertLatency(true, true, false, 48));
    try testing.expectEqual(@as(usize, 0), insertLatency(true, false, true, 240));
}

// --- Test fake and render harness -------------------------------------------------------
//
// The Rust tests render a whole session through MixEngine. Here a small harness stands in
// for one strip: the instrument first, then the inserts in slot order, containment after
// each slot, and the strip latency, all through the real `SlotTable` from slot.zig. Sends,
// clips and the fader are not modelled. The fake Processor below replaces the graph-3 test
// fake (its Probe is private to processor.zig) and can emit NaN, +inf, or pass audio
// through a real delay line with a chosen reported latency.

const testing = std.testing;

/// Channels the harness renders (stereo, like the Rust fixtures).
const max_ch: usize = 2;
/// Largest block the harness renders (the Rust fixtures render at 512 here).
const max_frames: usize = 512;
const Buf = [max_ch][max_frames]f32;
/// Track rows and queue capacity of the test table; enough for every test below.
const Table = slot.SlotTable(8, slot.INSERT_SLOTS, 8);
const TrackId = slot.TrackId;

/// Test fake. `nan` and `inf` overwrite the block; `delay` delays it by its delay line and
/// reports `reported` as its latency, true or bogus. Control-thread setup only: the line is
/// prepared by the test.
const Fake = struct {
    mode: Mode,
    reported: usize = 0,
    line: delay_line.DelayLine = .{},
    resets: usize = 0,

    const Mode = enum { nan, inf, delay };
    const max_ch_fake = 2;

    const vtable: Processor.VTable = .{
        .prepare = prepare,
        .reset = reset,
        .process = process,
        .latency_samples = latency,
        .tail_samples = tail,
        .set_transport = transport,
        .all_notes_off = notesOff,
        .destroy = destroy,
    };

    fn processor(self: *Fake) Processor {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }
    fn prepare(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
        _ = ptr;
        _ = sample_rate;
        _ = max_block;
        _ = channels;
    }
    fn reset(ptr: *anyopaque) void {
        const f = of(ptr);
        f.resets += 1;
        f.line.clear();
    }
    fn process(ptr: *anyopaque, io: [][]f32, frames: usize, events: []const proc_mod.MidiEvent) void {
        const f = of(ptr);
        _ = events;
        switch (f.mode) {
            .nan => {
                for (io) |ch| @memset(ch[0..@min(frames, ch.len)], std.math.nan(f32));
            },
            .inf => {
                for (io) |ch| @memset(ch[0..@min(frames, ch.len)], std.math.inf(f32));
            },
            .delay => {
                var ptrs: [max_ch_fake][*]f32 = undefined;
                const n = @min(io.len, max_ch_fake);
                for (io[0..n], 0..) |ch, c| ptrs[c] = ch.ptr;
                f.line.process(ptrs[0..n], frames);
            },
        }
    }
    fn latency(ptr: *anyopaque) usize {
        return of(ptr).reported;
    }
    fn tail(ptr: *anyopaque) usize {
        _ = ptr;
        return 0;
    }
    fn transport(ptr: *anyopaque, t: *const proc_mod.Transport) void {
        _ = ptr;
        _ = t;
    }
    fn notesOff(ptr: *anyopaque) void {
        _ = ptr;
    }
    fn destroy(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// Rows of a stereo buffer, the first `frames` samples of each channel.
fn rows(buf: *Buf, frames: usize) [max_ch][]f32 {
    var r: [max_ch][]f32 = undefined;
    for (0..max_ch) |c| r[c] = buf[c][0..frames];
    return r;
}

/// Runs one slot over `buf` and returns the latency it adds. Same order as Rust: a failed
/// slot is skipped, a slot is processed and then contained, and only a healthy slot reports
/// its latency.
fn runSlot(table: *Table, track: TrackId, idx: usize, buf: [][]f32, frames: usize) usize {
    const p = table.lookup(track, idx) orelse return 0;
    if (table.isFailed(track, idx)) return 0;
    const proc = p.*;
    proc.process(buf, frames, &.{});
    if (containFailure(buf, frames)) {
        _ = table.recordFailure(track, idx);
        return 0;
    }
    return insertLatency(true, false, false, proc.latencySamples());
}

/// One strip over `buf` (already holding its input): the instrument first, then the inserts
/// in slot order. Returns the strip latency, capped.
fn runStrip(table: *Table, track: TrackId, buf: [][]f32, frames: usize) usize {
    // The instrument's own latency is not part of the strip's insert latency.
    _ = runSlot(table, track, INSTRUMENT_SLOT, buf, frames);
    var reports: [slot.INSERT_SLOTS]usize = @splat(0);
    for (0..slot.INSERT_SLOTS) |i| reports[i] = runSlot(table, track, i, buf, frames);
    return stripLatency(&reports);
}

/// One source of a mix: a track and the samples it plays this block.
const Src = struct { track: TrackId, samples: []const f32 };

/// One block of a mix. Each source runs its strip over a copy of its samples, the strips
/// are summed into `out`, and the master (if any) runs its inserts over the sum.
fn mixBlock(table: *Table, srcs: []const Src, master: ?TrackId, frames: usize, out: *Buf, scratch: *Buf) void {
    table.service();
    for (0..max_ch) |c| @memset(out[c][0..frames], 0);
    var sr = rows(scratch, frames);
    var orow = rows(out, frames);
    for (srcs) |src| {
        for (0..max_ch) |c| @memcpy(scratch[c][0..frames], src.samples[0..frames]);
        _ = runStrip(table, src.track, sr[0..], frames);
        for (0..max_ch) |c| {
            for (out[c][0..frames], scratch[c][0..frames]) |*d, x| d.* += x;
        }
    }
    if (master) |m| _ = runStrip(table, m, orow[0..], frames);
}

test "an_insert_that_puts_out_nan_is_taken_out_until_the_next_reset" {
    // Rust: tests.rs::an_insert_that_puts_out_nan_is_taken_out_until_the_next_reset
    const a: TrackId = 1;
    const b: TrackId = 2;
    const frames = 512;
    const half: [max_frames]f32 = @splat(0.5);
    const srcs = [_]Src{ .{ .track = a, .samples = &half }, .{ .track = b, .samples = &half } };

    var table: Table = .{};
    try testing.expect(table.configure(a, 2, 2));
    var out: Buf = undefined;
    var scratch: Buf = undefined;

    mixBlock(&table, &srcs, null, frames, &out, &scratch);
    const both = out[0][0];
    try testing.expect(@abs(both - 1.0) < 1e-6);

    var nan_p: Fake = .{ .mode = .nan, .reported = 240 };
    try table.adopt(.{ .track = a, .slot = 2, .processor = nan_p.processor(), .channels = 2 });
    mixBlock(&table, &srcs, null, frames, &out, &scratch);
    const only_b = out[0][0];
    try testing.expect(only_b > 0.3 and @abs(only_b - both / 2.0) < 1e-6);
    try testing.expectEqual(PluginFailures{ .count = 1, .last = 2 }, table.failuresOf(a));
    try testing.expectEqual(PluginFailures{}, table.failuresOf(b));

    // Still bypassed in the next block: track a plays its dry signal again.
    mixBlock(&table, &srcs, null, frames, &out, &scratch);
    try testing.expectEqual(both, out[0][0]);

    // The reset retries the plugin once, which fails again.
    table.reset();
    mixBlock(&table, &srcs, null, frames, &out, &scratch);
    try testing.expectEqual(only_b, out[0][0]);
    try testing.expectEqual(@as(u32, 2), table.failuresOf(a).count);
}

test "nan_from_an_instrument_or_a_master_insert_is_contained" {
    // Rust: tests.rs::nan_from_an_instrument_or_a_master_insert_is_contained
    const synth: TrackId = 1;
    const b: TrackId = 2;
    const m: TrackId = 3;
    const frames = 512;
    const silent: [max_frames]f32 = @splat(0.0);
    const half: [max_frames]f32 = @splat(0.5);
    const srcs = [_]Src{ .{ .track = synth, .samples = &silent }, .{ .track = b, .samples = &half } };

    var table: Table = .{};
    try testing.expect(table.configure(synth, INSTRUMENT_SLOT, 2));
    var nan_inst: Fake = .{ .mode = .nan };
    try table.adopt(.{ .track = synth, .slot = INSTRUMENT_SLOT, .processor = nan_inst.processor(), .channels = 2 });
    var out: Buf = undefined;
    var scratch: Buf = undefined;

    mixBlock(&table, &srcs, null, frames, &out, &scratch);
    const only_b = out[0][0];
    try testing.expect(only_b > 0.3);
    try testing.expectEqual(PluginFailures{ .count = 1, .last = INSTRUMENT_SLOT }, table.failuresOf(synth));
    try testing.expectEqual(PluginFailures{}, table.failuresOf(b));

    // A NaN master insert silences the whole mix for one block, then is bypassed.
    try testing.expect(table.configure(m, 0, 2));
    var nan_master: Fake = .{ .mode = .nan };
    try table.adopt(.{ .track = m, .slot = 0, .processor = nan_master.processor(), .channels = 2 });
    mixBlock(&table, &srcs, m, frames, &out, &scratch);
    try testing.expectEqual(@as(f32, 0.0), out[0][0]);
    try testing.expectEqual(PluginFailures{ .count = 1, .last = 0 }, table.failuresOf(m));
    mixBlock(&table, &srcs, m, frames, &out, &scratch);
    try testing.expectEqual(only_b, out[0][0]);
}

test "an_infinite_output_is_contained_like_nan" {
    // Not a Rust test: the Rust check is `is_finite`, which covers +inf as well as NaN.
    const a: TrackId = 1;
    const half: [max_frames]f32 = @splat(0.5);
    const srcs = [_]Src{.{ .track = a, .samples = &half }};
    var table: Table = .{};
    try testing.expect(table.configure(a, 0, 2));
    var inf_p: Fake = .{ .mode = .inf };
    try table.adopt(.{ .track = a, .slot = 0, .processor = inf_p.processor(), .channels = 2 });
    var out: Buf = undefined;
    var scratch: Buf = undefined;
    mixBlock(&table, &srcs, null, 64, &out, &scratch);
    try testing.expectEqual(@as(f32, 0.0), out[0][0]);
    try testing.expectEqual(PluginFailures{ .count = 1, .last = 0 }, table.failuresOf(a));
}

test "failed_inserts_stop_contributing_latency_until_reset" {
    // Rust: tests.rs::failed_inserts_stop_contributing_latency_until_reset
    // Per track kind and block size: a NaN insert reporting 240 samples (5 ms at 48 kHz)
    // sits in slot 0 and a healthy 48-sample delay in slot 1. The failed insert must stop
    // contributing latency; the delay stays at 48 and is not compensated for in the strip.
    const kinds = [_]topology.Kind{ .track, .aux, .folder, .master };
    const blocks = [_]usize{ 64, 512 };
    const healthy_latency: usize = 48;
    const bogus_latency: usize = 240;

    for (kinds) |kind| {
        for (blocks) |block| {
            // The Audio case: source and target are the same track. The others: the source
            // has no inserts, so the target strip processes the source's samples.
            const target: TrackId = if (kind == .track) 1 else 2;
            var input: [max_frames * 6]f32 = @splat(0.0);
            for ([_]usize{ block, block * 2, block * 4 }) |at| input[at] = 0.25;

            var table: Table = .{};
            try testing.expect(table.configure(target, 0, 2));
            try testing.expect(table.configure(target, 1, 2));
            var nan_p: Fake = .{ .mode = .nan, .reported = bogus_latency };
            var delay: Fake = .{ .mode = .delay, .reported = healthy_latency };
            try delay.line.prepare(testing.allocator, healthy_latency, 2);
            defer delay.line.deinit(testing.allocator);
            try testing.expect(delay.line.setDelay(healthy_latency));
            try table.adopt(.{ .track = target, .slot = 0, .processor = nan_p.processor(), .channels = 2 });
            try table.adopt(.{ .track = target, .slot = 1, .processor = delay.processor(), .channels = 2 });

            var out: Buf = undefined;
            var last_latency: usize = 0;
            // Pass 0: the NaN is caught; the strip's output is silent.
            last_latency = renderPass(&table, target, input[0..], 0, block, &out);
            for (0..max_ch) |c| for (out[c][0..block]) |x| try testing.expectEqual(@as(f32, 0.0), x);
            try testing.expectEqual(@as(u32, 1), table.failuresOf(target).count);

            for ([_]usize{ 1, 2, 4 }) |b| {
                if (b == 4) {
                    // Reset retries the failed plugin once; the next block must drop its
                    // latency again while the healthy delay keeps its 48 samples.
                    table.reset();
                    _ = renderPass(&table, target, input[0..], 3, block, &out);
                    try testing.expectEqual(@as(u32, 2), table.failuresOf(target).count);
                }
                last_latency = renderPass(&table, target, input[0..], b, block, &out);
                try testing.expectEqual(healthy_latency, last_latency);
                for (0..max_ch) |c| {
                    for (out[c][0..block], 0..) |x, i| {
                        if (i == healthy_latency) {
                            try testing.expectEqual(@as(f32, 0.25), x);
                        } else {
                            try testing.expectEqual(@as(f32, 0.0), x);
                        }
                    }
                }
            }

            // The strip's reported latency is what delay compensation sees. The failed
            // insert's 240 must not appear in the plan.
            var topo = topology.Topology.init();
            _ = try topo.addNode(.{ .kind = kind });
            const lat = [_]pdc.NodeLatency{.{ .inserts = last_latency }};
            var plan: pdc.PdcPlan = .{};
            pdc.computePlan(&plan, &topo, &lat, true);
            try testing.expectEqual(healthy_latency, plan.latency);
        }
    }
}

/// Renders the block at timeline index `b` for the strip `target`: its samples come from
/// `input`, the target runs its strip, and the output lands in `out`. Returns the latency.
fn renderPass(table: *Table, target: TrackId, input: []const f32, b: usize, block: usize, out: *Buf) usize {
    table.service();
    for (0..max_ch) |c| @memcpy(out[c][0..block], input[b * block ..][0..block]);
    var orow = rows(out, block);
    return runStrip(table, target, orow[0..], block);
}

/// Counts every allocation it forwards. Lets the test show that setup allocates and the
/// audio-side passes do not.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocations: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
    }
};

test "failure containment does not allocate on the audio path" {
    // Setup (delay line storage, table) goes through the counting allocator. The audio-side
    // blocks take no allocator at all, so the count must not move while they run. Zig has no
    // global allocator to hook, so this pins the setup/steady-state split rather than
    // catching every hidden allocation.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();
    var delay: Fake = .{ .mode = .delay, .reported = 48 };
    try delay.line.prepare(gpa, 48, 2);
    defer delay.line.deinit(gpa);
    try testing.expect(delay.line.setDelay(48));
    var nan_p: Fake = .{ .mode = .nan, .reported = 240 };

    var table: Table = .{};
    try testing.expect(table.configure(1, 0, 2));
    try testing.expect(table.configure(1, 1, 2));
    try table.adopt(.{ .track = 1, .slot = 0, .processor = nan_p.processor(), .channels = 2 });
    try table.adopt(.{ .track = 1, .slot = 1, .processor = delay.processor(), .channels = 2 });
    try testing.expect(counting.allocations > 0);

    const half: [max_frames]f32 = @splat(0.5);
    const srcs = [_]Src{.{ .track = 1, .samples = &half }};
    var out: Buf = undefined;
    var scratch: Buf = undefined;
    const before = counting.allocations;
    for (0..8) |_| mixBlock(&table, &srcs, null, 128, &out, &scratch);
    try testing.expectEqual(before, counting.allocations);
}
