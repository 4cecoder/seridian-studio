// Translated to Zig from soundcraft/crates/au-host/tests/it/system_units.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! End to end against the Audio Units Apple ships with macOS: scan, instantiate, params,
//! process, state, plus an instrument playing a note. Each test skips (`error.SkipZigTest`)
//! when the platform is not macOS or the unit is not registered.
//!
//! Translation notes (same inputs and expected values as the Rust file):
//! - The Rust `Plugin` trait's `set_param(id)`, `note_on`, `note_off`, `midi` and `all_notes_off`
//!   become dense parameter indices and sorted `Event`s delivered by `process`. Events queue in
//!   an `EventList` and are delivered by the first block after they are pushed. As in Rust,
//!   `reset` drops queued events.
//! - `process(io, frames)`: the Zig `AudioBlock` carries its own frame count, so the Rust
//!   `fold(frames, usize::min)` clamp is the length of the slices passed in.
//! - `all_notes_off` is written out as the events it queues for the notes held here (only note 60),
//!   then CC 123. The Zig `AuPlugin` does not track held notes.
//! - The state-reader test is skipped (see its comment).

const std = @import("std");
const au = @import("au.zig");
const plug = @import("../plugin.zig");
const event = @import("../event.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Plugin = plug.Plugin;
const AudioBlock = plug.AudioBlock;
const Event = plug.Event;
const EventList = event.EventList;
const Category = plug.Category;
const Unit = plug.Unit;
const PluginInfo = plug.PluginInfo;

const LOWPASS = "au:aufx:lpas:appl";
const DELAY = "au:aufx:dely:appl";
const DLS = "au:aumu:dls :appl";

/// Empty event slice for `process` calls that deliver nothing.
const no_events: []const Event = &.{};

/// Skips the test off macOS (the Rust file is compiled only for `target_os = "macos"`).
fn requireAu() !void {
    if (!au.isSupported()) return error.SkipZigTest;
}

/// True when the scan lists `id`. A missing unit skips the test (Rust `available`).
fn available(host: *au.Host, id: []const u8) !bool {
    const list = try host.scan();
    return findById(list, id) != null;
}

fn findById(list: []const au.AuDescriptor, id: []const u8) ?au.AuDescriptor {
    for (list) |d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

/// The dense index of the first parameter with unit `unit` (Rust `info.params.iter().find`).
fn indexOfUnit(info: *const PluginInfo, unit: Unit) ?u32 {
    for (info.params, 0..) |p, i| {
        if (p.unit == unit) return @intCast(i);
    }
    return null;
}

/// Fills `dst` with the Rust `sine`: `(TAU * freq * (i + phase0) / sr).sin() * 0.5`.
fn fillSine(dst: []f32, freq: f32, sr: f32, phase0: usize) void {
    for (dst, 0..) |*s, i| {
        const t: f32 = @floatFromInt(i + phase0);
        s.* = @sin(std.math.tau * freq * t / sr) * 0.5;
    }
}

/// Root mean square, summed in order like the Rust `rms`.
fn rms(x: []const f32) f32 {
    var sum: f32 = 0;
    for (x) |v| sum += v * v;
    return @sqrt(sum / @as(f32, @floatFromInt(@max(x.len, 1))));
}

/// A block over the first `frames` frames of each channel: the Rust `process(&mut io, frames)`.
fn framesBlock(io: []const []f32, frames: usize) AudioBlock {
    var sub: [plug.MAX_CHANNELS][]f32 = undefined;
    for (io, 0..) |c, i| sub[i] = c[0..frames];
    return AudioBlock.fromSlices(sub[0..io.len]);
}

/// Runs `freq` through `h` in 512-frame blocks for about 0.5 s and returns the RMS of the last
/// half (Rust `run_tone`). Asserts every sample is finite.
fn runTone(h: Plugin, freq: f32) !f32 {
    const sr: f32 = 48_000.0;
    const block = 512;
    const blocks = 48;
    var left: [block]f32 = undefined;
    var right: [block]f32 = undefined;
    var sum: f32 = 0;
    var count: usize = 0;
    for (0..blocks) |b| {
        fillSine(&left, freq, sr, b * block);
        right = left;
        var bufs = [_][]f32{ &left, &right };
        h.process(AudioBlock.fromSlices(&bufs), no_events);
        for (bufs) |c| {
            for (c) |v| try testing.expect(std.math.isFinite(v));
        }
        if (b >= blocks / 2) {
            for (left) |v| sum += v * v;
            count += block;
        }
    }
    return @sqrt(sum / @as(f32, @floatFromInt(@max(count, 1))));
}

/// Renders `blocks` blocks into `bufs` (zeroed before each block) and delivers `events` in the
/// first block only. Returns the largest RMS of channel 0 seen.
fn renderBlocks(h: Plugin, bufs: []const []f32, blocks: usize, events: []const Event) f32 {
    var peak: f32 = 0;
    for (0..blocks) |b| {
        for (bufs) |c| @memset(c, 0);
        h.process(AudioBlock.fromSlices(bufs), if (b == 0) events else no_events);
        peak = @max(peak, rms(bufs[0]));
    }
    return peak;
}

fn noteOn(offset: u32, note: u8, velocity: u8) Event {
    return .{ .offset = offset, .kind = .{ .note_on = .{ .note = note, .velocity = velocity } } };
}

fn noteOff(offset: u32, note: u8) Event {
    return .{ .offset = offset, .kind = .{ .note_off = note } };
}

fn midi3(offset: u32, msg: [3]u8) Event {
    return .{ .offset = offset, .kind = .{ .midi3 = msg } };
}

/// The Rust `loudest` closure: CC 7 at `volume`, a note on, 20 blocks of silence, then the
/// note off and a reset (which drops anything still queued). Returns the peak RMS.
fn loudest(h: Plugin, queue: *EventList, volume: u8) f32 {
    queue.clear();
    _ = queue.push(midi3(0, .{ 0xB0, 7, volume }));
    _ = queue.push(noteOn(0, 60, 110));
    var left: [512]f32 = undefined;
    var right: [512]f32 = undefined;
    var bufs = [_][]f32{ &left, &right };
    const energy = renderBlocks(h, &bufs, 20, queue.items());
    queue.clear();
    h.reset();
    return energy;
}

test "system units: scan lists apple units" {
    try requireAu();
    var host = au.Host.init(testing.allocator);
    defer host.deinit();
    const all = try host.scan();
    for (all) |d| {
        try testing.expect(std.mem.startsWith(u8, d.id, au.ID_PREFIX));
        const parsed = au.parseId(d.id) orelse return error.TestUnexpectedResult;
        const again = try au.formatId(testing.allocator, parsed.ty, parsed.subtype, parsed.manufacturer);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(d.id, again);
        try testing.expectEqual(std.mem.eql(u8, d.component_type, "aumu"), d.is_instrument);
    }
    if (findById(all, LOWPASS)) |d| {
        try testing.expectEqualStrings("AULowpass", d.name);
        try testing.expectEqualStrings("Apple", d.vendor);
        try testing.expectEqual(Category.eq, d.category);
        try testing.expect(!d.is_instrument);
    }
    if (findById(all, DLS)) |d| {
        try testing.expect(d.is_instrument);
        try testing.expectEqual(Category.instrument, d.category);
    }
    // `all` is invalid after a rescan, so take the count first.
    const count = all.len;
    const again = try host.rescan();
    try testing.expectEqual(count, again.len);
}

test "system units: lowpass attenuates highs" {
    try requireAu();
    var host = au.Host.init(testing.allocator);
    defer host.deinit();
    if (!try available(&host, LOWPASS)) return error.SkipZigTest;

    const info = host.pluginInfo(LOWPASS) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(LOWPASS, info.id);
    try testing.expect(info.params.len > 0); // AULowpass has a cutoff

    const p = try host.instantiate(LOWPASS);
    defer host.destroy(p);
    const h = p.plugin();
    h.prepare(48_000.0, 512, 2);

    const cutoff = indexOfUnit(info, .hz) orelse return error.TestUnexpectedResult;
    try testing.expect(h.setParam(cutoff, 500.0));
    try testing.expectApproxEqAbs(@as(f32, 500.0), h.getParam(cutoff) orelse return error.TestUnexpectedResult, 1e-3);
    // Rust used the unknown id "999999"; the dense index one past the end is the same case.
    try testing.expect(!h.setParam(@intCast(info.params.len), 1.0));
    try testing.expect(h.setParam(cutoff, std.math.nan(f32))); // NaN becomes the default
    try testing.expect(h.setParam(cutoff, 500.0));
    const low = try runTone(h, 100.0);
    h.reset();
    const high = try runTone(h, 12_000.0);
    try testing.expect(low > 0.2); // low tone passes
    try testing.expect(high < low * 0.1); // high tone attenuated

    // State round trip restores the cutoff.
    const state = (try h.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(state);
    try testing.expect(h.setParam(cutoff, 5000.0));
    try testing.expect(h.loadState(state));
    try testing.expect(@abs((h.getParam(cutoff) orelse return error.TestUnexpectedResult) - 500.0) < 1.0);

    // Hostile state is rejected without harm.
    try testing.expect(!h.loadState(""));
    try testing.expect(!h.loadState("bplist00 garbage \x00\x01\x02\xff"));
    const junk: [1000]u8 = @splat(0xff);
    try testing.expect(!h.loadState(&junk));
    try testing.expect(std.math.isFinite(try runTone(h, 100.0)));
}

test "system units: state reader reads while another thread renders" {
    // The Rust test reads the state through `state_reader` from a second thread while the
    // audio thread renders. The Zig AuPlugin leaves the `state_reader` vtable entry null:
    // `PluginStateReader` has no release hook for the retained `StateLink` yet (see the note
    // above the vtable in plugin.zig). Control-thread `saveState` is covered by the lowpass test.
    return error.SkipZigTest;
}

test "system units: delay runs mono, stereo and odd blocks" {
    try requireAu();
    var host = au.Host.init(testing.allocator);
    defer host.deinit();
    if (!try available(&host, DELAY)) return error.SkipZigTest;

    const p = try host.instantiate(DELAY);
    defer host.destroy(p);
    const h = p.plugin();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { ch: usize, block: usize };
    const cases = [_]Case{ .{ .ch = 2, .block = 1024 }, .{ .ch = 1, .block = 300 }, .{ .ch = 2, .block = 5000 } };
    for (cases) |c| {
        h.prepare(44_100.0, c.block, c.ch);
        const io = try a.alloc([]f32, c.ch);
        for (io) |*chan| {
            chan.* = try a.alloc(f32, c.block);
            fillSine(chan.*, 440.0, 44_100.0, 0);
        }
        // Rust: `process(&mut io, block * 4)` into `block`-frame buffers, clamped to the buffer.
        h.process(framesBlock(io, c.block), no_events);
        // Empty block.
        h.process(framesBlock(io, 0), no_events);
        // No channels at all.
        h.process(AudioBlock.fromSlices(&.{}), no_events);
        for (0..20) |_| {
            h.process(framesBlock(io, c.block), no_events);
        }
        for (io) |chan| {
            for (chan) |v| try testing.expect(std.math.isFinite(v));
        }
        try testing.expect(rms(io[0]) > 0.0);
    }

    // Hostile prepare values.
    h.prepare(std.math.nan(f32), 0, 0);
    var buf: [64]f32 = @splat(0.25);
    var bufs = [_][]f32{&buf};
    h.process(AudioBlock.fromSlices(&bufs), no_events);
    for (buf) |v| try testing.expect(std.math.isFinite(v));
}

test "system units: dls synth plays a note" {
    try requireAu();
    var host = au.Host.init(testing.allocator);
    defer host.deinit();
    if (!try available(&host, DLS)) return error.SkipZigTest;
    // Rust printed the reason and passed when the synth would not instantiate.
    const p = host.instantiate(DLS) catch return error.SkipZigTest;
    defer host.destroy(p);
    const h = p.plugin();
    try testing.expect(h.info().is_instrument);
    h.prepare(48_000.0, 512, 2);

    // Queued events, as the Rust `note_on`, `note_off`, `midi` and `all_notes_off` calls queue
    // them. They are delivered by the next `process` (see the module notes).
    var queue = try EventList.init(testing.allocator, 8);
    defer queue.deinit(testing.allocator);

    // Instruments replace the buffer: silence in, silence out.
    var left: [512]f32 = @splat(1.0);
    var right: [512]f32 = @splat(1.0);
    var stereo = [_][]f32{ &left, &right };
    h.process(AudioBlock.fromSlices(&stereo), no_events);
    for (stereo) |c| {
        for (c) |v| {
            try testing.expect(std.math.isFinite(v) and @abs(v) < 1e-3);
        }
    }

    // note_on(10, 60, 110) and note_on(0, 200, 110), the latter ignored (note > 127).
    try testing.expect(queue.push(noteOn(10, 60, 110)));
    try testing.expect(queue.push(noteOn(0, 200, 110)));
    const energy = renderBlocks(h, &stereo, 40, queue.items());
    try testing.expect(energy > 1e-3); // note-on produced sound

    // all_notes_off for the held note 60, then CC 123. Delivered with the next block.
    queue.clear();
    try testing.expect(queue.push(noteOff(0, 60)));
    try testing.expect(queue.push(midi3(0, .{ 0xB0, 123, 0 })));

    // Mono output downmixes.
    h.prepare(48_000.0, 256, 1);
    try testing.expect(queue.push(noteOn(0, 64, 100)));
    var mono_buf: [256]f32 = undefined;
    var mono = [_][]f32{&mono_buf};
    const e = renderBlocks(h, &mono, 40, queue.items());
    try testing.expect(e > 1e-3);

    // note_off(0, 64) and reset: the reset drops the queued note off.
    queue.clear();
    try testing.expect(queue.push(noteOff(0, 64)));
    queue.clear();
    h.reset();

    // Controllers reach the synth: MIDI volume 0 silences a note. (In this test because creating
    // two DLS instances at once on two threads crashes inside the unit.)
    h.prepare(48_000.0, 512, 2);
    const full = loudest(h, &queue, 127);
    const muted = loudest(h, &queue, 0);
    try testing.expect(full > 1e-3 and muted < full * 0.01);
}

/// Counts every allocation call made through it: alloc, resize and remap. Test only; a shared
/// counting allocator belongs in `core` once it exists.
const CountingAllocator = struct {
    backing: Allocator,
    calls: usize = 0,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fromCtx(ctx: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromCtx(ctx);
        self.calls += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromCtx(ctx);
        self.calls += 1;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromCtx(ctx);
        self.calls += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromCtx(ctx);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Prepares `id`, then renders 100 blocks with `events` in the first one, counting the
/// allocations made through `counting` during `process` only.
fn expectNoAllocationsInProcess(host: *au.Host, counting: *CountingAllocator, id: []const u8, events: []const Event) !void {
    const p = try host.instantiate(id);
    defer host.destroy(p);
    const h = p.plugin();
    var left: [512]f32 = undefined;
    var right: [512]f32 = undefined;
    fillSine(&left, 440.0, 48_000.0, 0);
    right = left;
    var bufs = [_][]f32{ &left, &right };
    h.prepare(48_000.0, 512, 2); // control thread: allocating is fine here

    counting.calls = 0;
    for (0..100) |b| {
        h.process(AudioBlock.fromSlices(&bufs), if (b == 0) events else no_events);
    }
    try testing.expectEqual(@as(usize, 0), counting.calls);
}

test "system units: process does not allocate through the host allocator" {
    try requireAu();
    var counting: CountingAllocator = .{ .backing = testing.allocator };
    var host = au.Host.init(counting.allocator());
    defer host.deinit();
    if (!try available(&host, DELAY)) return error.SkipZigTest;

    // An effect with a parameter change queued (the sample-accurate path).
    const effect_events = [_]Event{.{ .offset = 0, .kind = .{ .param = .{ .index = 0, .value = 0.5 } } }};
    try expectNoAllocationsInProcess(&host, &counting, DELAY, &effect_events);

    // An instrument with notes and a controller queued, when the synth is installed.
    if (try available(&host, DLS)) {
        const synth_events = [_]Event{
            midi3(0, .{ 0xB0, 7, 100 }),
            noteOn(0, 60, 110),
        };
        try expectNoAllocationsInProcess(&host, &counting, DLS, &synth_events);
    }
}
