// Translated to Zig from soundcraft/crates/mix/src/automation.rs, soundcraft/crates/mix/tests/it/strip_mute_automation.rs, soundcraft/docs/strip-mute-automation.md (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Audio-thread evaluation of automation lanes, and strip-mute gating.
//!
//! Every function here is pure over an immutable `Snapshot` (one track's automation mode and
//! lanes). Lane positions are f64 beats (see lane.zig). The caller supplies a `SegmentPlan` per
//! block that maps block frames to beats, so this file does not depend on the sequencer library.
//! Nothing here allocates, locks, logs or does I/O: safe on the audio thread once the lanes exist.
//!
//! Seridian changes from the Rust original:
//! - `transport_at` is not translated (it needs the SoundCraft Session).
//! - Rust sample positions become block-relative frames through `SegmentPlan`. The pan grid is
//!   defined on the absolute timeline, so the plan also carries the block's `start_sample`.
//! - `gateMute` takes the whole `Snapshot` (mode check and lane lookup in one place) instead of a
//!   bare lane, so the "first lane of this parameter is authoritative" rule lives in one function.

const std = @import("std");
const testing = std.testing;
const dsp_db = @import("analysis").db;
const lane_mod = @import("lane.zig");
const AutomationLane = lane_mod.AutomationLane;
const modes = @import("modes.zig");
const AutomationMode = modes.AutomationMode;
const AutoParam = modes.AutoParam;

/// A mute lane value at or above this silences the strip (Rust `>= 0.5`).
pub const mute_threshold: f32 = 0.5;

/// Pan automation is read on an absolute-sample grid of this many samples, so playback and
/// bounces with different block sizes pan identically (Rust `PAN_STEP`).
pub const pan_step: i64 = 64;

/// Frame-to-beat mapping for one block, supplied by the caller (the sequencer owns tempo).
/// Frame `f` of the block sits at beat `start_beat + f / samples_per_beat`.
pub const SegmentPlan = struct {
    /// Absolute timeline sample of frame 0 (used only for the pan grid).
    start_sample: i64,
    /// Beat position of frame 0.
    start_beat: f64,
    /// Samples per beat at this block. Must be finite and > 0.
    samples_per_beat: f64,

    /// Beat position of a block frame. `frame` may be negative (a grid point before the block).
    pub fn beatAt(self: SegmentPlan, frame: f64) f64 {
        return self.start_beat + frame / self.samples_per_beat;
    }

    /// Block-relative frame of the first sample whose beat is at or after `beat`.
    /// Positions within `frame_snap_eps` of a sample boundary snap to it, so the answer does not
    /// depend on how the timeline was split into blocks.
    pub fn frameOfBeat(self: SegmentPlan, beat: f64) i64 {
        const x = (beat - self.start_beat) * self.samples_per_beat;
        if (std.math.isNan(x)) return 0;
        const clamped = std.math.clamp(x, -frame_limit, frame_limit);
        return @intFromFloat(@ceil(clamped - frame_snap_eps));
    }
};

/// Snapping tolerance for beat-to-frame conversion, in samples.
pub const frame_snap_eps: f64 = 1e-6;
const frame_limit: f64 = 4503599627370496.0; // 2^52: keeps the float-to-int conversion in range.

/// Immutable view of one track's automation: its mode and its lanes.
pub const Snapshot = struct {
    mode: AutomationMode,
    lanes: []const AutomationLane,

    /// The first lane for `param`, empty or not (Rust `Track::lane`).
    pub fn find(self: Snapshot, param: AutoParam) ?*const AutomationLane {
        for (self.lanes) |*lane| {
            if (lane.param.eql(param)) return lane;
        }
        return null;
    }
};

/// Default pan of a panner: the left one is centred, the others sit right.
pub fn defaultPan(idx: usize) f32 {
    return if (idx == 0) 0.0 else 1.0;
}

/// Fader level in dB at `frame`. Write mode does not read the fader lane (Rust `volume_db_at`).
pub fn volumeDbAt(snap: Snapshot, base_db: f32, plan: SegmentPlan, frame: usize) f32 {
    if (snap.mode.reads() and snap.mode != .write) {
        if (snap.find(.volume)) |lane| {
            if (lane.points.items.len > 0) {
                return lane.valueAt(plan.beatAt(@floatFromInt(frame)), base_db);
            }
        }
    }
    return base_db;
}

/// Pan of panner `idx` at block frame `frame`, which may be a grid point before the block
/// (see `panSegment`). `base` is the mixer's pan for `idx` (see `defaultPan`).
pub fn panAt(snap: Snapshot, idx: usize, base: f32, plan: SegmentPlan, frame: i64) f32 {
    const pi: u8 = std.math.cast(u8, idx) orelse 0;
    if (snap.mode.reads()) {
        if (snap.find(.{ .pan = pi })) |lane| {
            if (lane.points.items.len > 0) {
                return lane.valueAt(plan.beatAt(@floatFromInt(frame)), base);
            }
        }
    }
    return base;
}

/// Frames that share one pan reading: the reading frame may be before the block, and the segment
/// is `[start, end)` of the block.
pub const PanSegment = struct {
    read_frame: i64,
    end: usize,
};

/// True when the mode reads and some pan lane has points (Rust `pan_segment` test).
pub fn panAutomated(snap: Snapshot) bool {
    if (!snap.mode.reads()) return false;
    for (snap.lanes) |lane| {
        if (std.meta.activeTag(lane.param) == .pan and lane.points.items.len > 0) return true;
    }
    return false;
}

/// Splits a block where the pan changes. Without pan automation the whole block shares one pan.
/// With it, the reading is taken at the last `pan_step` grid point on the absolute timeline at or
/// before the frame `start`, and the segment ends at the next grid point or at `frames`.
pub fn panSegment(snap: Snapshot, plan: SegmentPlan, start: usize, frames: usize) PanSegment {
    if (!panAutomated(snap)) return .{ .read_frame = 0, .end = frames };
    const here = plan.start_sample +| @as(i64, @intCast(start));
    const at = @divFloor(here, pan_step) *| pan_step;
    const left: usize = @intCast(@max(1, at +| pan_step -| here));
    return .{
        .read_frame = at -| plan.start_sample,
        .end = @min(frames, start +| left),
    };
}

/// Send level in dB at `frame` (Rust `send_level`; no write-mode exclusion).
pub fn sendLevelAt(snap: Snapshot, slot: usize, base_db: f32, plan: SegmentPlan, frame: usize) f32 {
    const si: u8 = std.math.cast(u8, slot) orelse 0;
    if (snap.mode.reads()) {
        if (snap.find(.{ .send_level = si })) |lane| {
            if (lane.points.items.len > 0) {
                return lane.valueAt(plan.beatAt(@floatFromInt(frame)), base_db);
            }
        }
    }
    return base_db;
}

/// Per-sample dB-linear gain ramp between two dB values over `n` samples (Rust `GainRamp`).
pub const GainRamp = struct {
    g0: f32,
    g1: f32,
    n: usize,

    pub fn init(db0: f32, db1: f32, n: usize) GainRamp {
        return .{ .g0 = dsp_db.dbToGain(db0), .g1 = dsp_db.dbToGain(db1), .n = n };
    }

    /// Gain at sample `i` of the ramp; `g0` when the ramp is empty.
    pub fn at(self: GainRamp, i: usize) f32 {
        if (self.n == 0) return self.g0;
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.n));
        return self.g0 + (self.g1 - self.g0) * t;
    }
};

/// Strip-mute gating, sample accurate, without splitting the block.
///
/// Walks the mute lane's points once with an index cursor and zeroes every frame whose mute value
/// is at or above `mute_threshold`, in all of `out`'s channels. Frames `[0, frames)` are covered.
/// Does nothing when the mode does not read, when the first mute lane is empty, or when there is
/// no mute lane (the first lane for `.mute` is authoritative, as in Rust). Allocation-free.
pub fn gateMute(snap: Snapshot, plan: SegmentPlan, out: [][]f32, frames: usize) void {
    if (!snap.mode.reads()) return;
    const lane = snap.find(.mute) orelse return;
    const pts = lane.points.items;
    if (pts.len == 0) return;

    var n = frames;
    for (out) |ch| n = @min(n, ch.len);
    const n_i: i64 = @intCast(n);

    var cur: usize = 0;
    // Before the first point the lane holds the first value (matches lane.evaluate).
    var value: f32 = pts[0].value;
    var i: usize = 0;
    while (i < n) {
        const i_i: i64 = @intCast(i);
        // Apply every point that takes effect at or before frame `i`; the last one wins.
        while (cur < pts.len) {
            if (plan.frameOfBeat(pts[cur].at) > i_i) break;
            value = pts[cur].value;
            cur += 1;
        }
        // The next change is the first frame of the next point (or the end of the block).
        var next: usize = n;
        if (cur < pts.len) {
            next = @intCast(@min(plan.frameOfBeat(pts[cur].at), n_i));
        }
        if (value >= mute_threshold) {
            for (out) |ch| @memset(ch[i..next], 0.0);
        }
        i = next;
    }
}

// ---------------------------------------------------------------------------
// Tests (ported from strip_mute_automation.rs; the Rust MixEngine is not in this library, so the
// render harness below stands in for it: constant 0.25 signal on two channels, pan, volume lane,
// then mute gating from the same snapshot.)
// ---------------------------------------------------------------------------

/// Samples per beat of the test grid. 100 Rust samples = 1 beat, as in lane.zig.
const spb: f64 = 100.0;
const LEN: usize = 768;
const signal: f32 = 0.25;
/// Pan of the two channels in the fixture (Rust `tr.mixer.pan = vec![-1.0, 1.0]`).
const pan_base = [2]f32{ -1.0, 1.0 };
const Rendered = [2][LEN]f32;

fn beatOf(sample: i64) f64 {
    return @as(f64, @floatFromInt(sample)) / spb;
}

fn planAt(pos: usize) SegmentPlan {
    return .{ .start_sample = @intCast(pos), .start_beat = beatOf(@intCast(pos)), .samples_per_beat = spb };
}

/// Constant-power-free test pan law: pan -1 is full left, +1 is full right.
fn panGain(pan: f32, channel: usize) f32 {
    const angle = (pan + 1.0) * (std.math.pi / 4.0);
    return if (channel == 0) @cos(angle) else @sin(angle);
}

fn applyLevels(snap: Snapshot, plan: SegmentPlan, view: [][]f32, frames: usize) void {
    var s: usize = 0;
    while (s < frames) {
        const seg = panSegment(snap, plan, s, frames);
        var gains: [2]f32 = undefined;
        for (0..2) |c| {
            gains[c] = panGain(panAt(snap, c, pan_base[c], plan, seg.read_frame), c);
        }
        var i = s;
        while (i < seg.end) : (i += 1) {
            const vol = dsp_db.dbToGain(volumeDbAt(snap, 0.0, plan, i));
            view[0][i] = signal * vol * gains[0];
            view[1][i] = signal * vol * gains[1];
        }
        s = seg.end;
    }
}

/// Renders the fixture in blocks of `block` frames, gating each block after its levels.
fn renderBlocks(snap: Snapshot, block: usize) Rendered {
    var out: Rendered = undefined;
    var pos: usize = 0;
    while (pos < LEN) : (pos += block) {
        const frames = @min(block, LEN - pos);
        const plan = planAt(pos);
        var view = [2][]f32{ out[0][pos .. pos + frames], out[1][pos .. pos + frames] };
        applyLevels(snap, plan, view[0..], frames);
        gateMute(snap, plan, view[0..], frames);
    }
    return out;
}

fn anyAudible(r: *const Rendered) bool {
    for (r) |ch| {
        for (ch) |x| {
            if (@abs(x) > 0.01) return true;
        }
    }
    return false;
}

/// Rust `gated()`: frames in [start, end) are exactly silent, all others equal the reference.
fn expectGated(actual: *const Rendered, reference: *const Rendered, start: usize, end: usize) !void {
    try testing.expect(anyAudible(reference));
    for (0..2) |c| {
        for (0..LEN) |i| {
            const want: f32 = if (i >= start and i < end) 0.0 else reference[c][i];
            testing.expectEqual(want, actual[c][i]) catch |err| {
                std.debug.print("frame {d} channel {d}\n", .{ i, c });
                return err;
            };
        }
    }
}

fn expectRenderedEqual(a: *const Rendered, b: *const Rendered) !void {
    for (0..2) |c| {
        for (0..LEN) |i| {
            testing.expectEqual(b[c][i], a[c][i]) catch |err| {
                std.debug.print("frame {d} channel {d}\n", .{ i, c });
                return err;
            };
        }
    }
}

/// Rust `mute(s, t, start, end)`: a held 0 before the edges, 1 inside, 0 after.
fn muteEdges(gpa: std.mem.Allocator, lane: *AutomationLane, start: i64, end: i64) !void {
    const points = [_]struct { at: i64, value: f32 }{
        .{ .at = 0, .value = 0.0 },
        .{ .at = start - 1, .value = 0.0 },
        .{ .at = start, .value = 1.0 },
        .{ .at = end - 1, .value = 1.0 },
        .{ .at = end, .value = 0.0 },
    };
    for (points) |p| try lane.setPoint(gpa, beatOf(p.at), p.value);
}

/// Three lanes in Rust order: volume, pan 0 and an empty mute lane.
/// Volume goes from -12 dB to -3 dB and pan 0 from -1 to 0.5 over the whole fixture.
fn scheduleLanes(gpa: std.mem.Allocator, store: *[3]AutomationLane) !void {
    store[0] = AutomationLane.init(.volume);
    store[1] = AutomationLane.init(.{ .pan = 0 });
    store[2] = AutomationLane.init(.mute);
    try store[0].setPoint(gpa, 0.0, -12.0);
    try store[0].setPoint(gpa, beatOf(LEN), -3.0);
    try store[1].setPoint(gpa, 0.0, -1.0);
    try store[1].setPoint(gpa, beatOf(LEN), 0.5);
}

test "mute threshold: 0.49 stays unmuted, 0.5 mutes" {
    const gpa = testing.allocator;
    var store = [_]AutomationLane{AutomationLane.init(.mute)};
    defer store[0].deinit(gpa);
    try store[0].setPoint(gpa, 0.0, 0.49);
    try store[0].setPoint(gpa, beatOf(10), 0.5);
    var out: [20]f32 = @splat(signal);
    var view = [_][]f32{out[0..]};
    gateMute(.{ .mode = .read, .lanes = &store }, planAt(0), view[0..], 20);
    // 0.49 at frame 0..9 is unmuted; the 0.5 point at beat 0.1 (frame 10) mutes.
    try testing.expectEqual(signal, out[9]);
    try testing.expectEqual(@as(f32, 0.0), out[10]);
}

test "gateMute: internal and exact block edges are partition independent" {
    const gpa = testing.allocator;
    const empty: Snapshot = .{ .mode = .read, .lanes = &.{} };
    const reference = renderBlocks(empty, 512);
    try testing.expect(anyAudible(&reference));
    for ([_][2]i64{ .{ 101, 200 }, .{ 128, 256 }, .{ 1, 767 } }) |edge| {
        var store = [_]AutomationLane{AutomationLane.init(.mute)};
        defer store[0].deinit(gpa);
        try muteEdges(gpa, &store[0], edge[0], edge[1]);
        const snap: Snapshot = .{ .mode = .read, .lanes = &store };
        for ([_]usize{ 16, 63, 128, 512, 1024 }) |block| {
            const got = renderBlocks(snap, block);
            try expectGated(&got, &reference, @intCast(edge[0]), @intCast(edge[1]));
        }
    }
}

test "gateMute: existing held mute curve and threshold are preserved" {
    const gpa = testing.allocator;
    const reference = renderBlocks(.{ .mode = .read, .lanes = &.{} }, 512);
    var store = [_]AutomationLane{AutomationLane.init(.mute)};
    defer store[0].deinit(gpa);
    try store[0].setPoint(gpa, 0.0, 0.49);
    try store[0].setPoint(gpa, beatOf(200), 0.5);
    const got = renderBlocks(.{ .mode = .read, .lanes = &store }, 512);
    try expectGated(&got, &reference, 200, LEN);
}

test "gateMute: reading modes retain existing policy" {
    const gpa = testing.allocator;
    const reference = renderBlocks(.{ .mode = .read, .lanes = &.{} }, 512);
    for (AutomationMode.all) |mode| {
        if (!mode.reads()) continue;
        var store = [_]AutomationLane{AutomationLane.init(.mute)};
        defer store[0].deinit(gpa);
        try muteEdges(gpa, &store[0], 101, 200);
        const got = renderBlocks(.{ .mode = mode, .lanes = &store }, 512);
        try expectGated(&got, &reference, 101, 200);
    }
}

test "gateMute: off, empty and first-empty lane keep exact unautomated PCM" {
    const gpa = testing.allocator;
    const reference = renderBlocks(.{ .mode = .read, .lanes = &.{} }, 512);

    // An empty mute lane changes nothing.
    var store = [_]AutomationLane{AutomationLane.init(.mute)};
    defer store[0].deinit(gpa);
    try expectRenderedEqual(&renderBlocks(.{ .mode = .read, .lanes = &store }, 512), &reference);

    // The first empty lane stays authoritative over a later non-empty mute lane.
    var two = [_]AutomationLane{ AutomationLane.init(.mute), AutomationLane.init(.mute) };
    defer for (&two) |*l| l.deinit(gpa);
    try two[1].setPoint(gpa, 0.0, 1.0);
    try expectRenderedEqual(&renderBlocks(.{ .mode = .read, .lanes = &two }, 512), &reference);

    // With points in the first lane, Off mode still leaves the PCM unchanged.
    try muteEdges(gpa, &store[0], 101, 200);
    try expectRenderedEqual(&renderBlocks(.{ .mode = .off, .lanes = &store }, 512), &reference);
}

test "gateMute: no active mute lane preserves fader and pan schedules exactly" {
    const gpa = testing.allocator;
    var store: [3]AutomationLane = undefined;
    try scheduleLanes(gpa, &store);
    defer for (&store) |*l| l.deinit(gpa);
    for ([_]usize{ 63, 256, 512 }) |block| {
        const reference = renderBlocks(.{ .mode = .read, .lanes = store[0..2] }, block);
        try store[2].setPoint(gpa, 0.0, 0.0);
        try expectRenderedEqual(&renderBlocks(.{ .mode = .read, .lanes = store[0..3] }, block), &reference);
        const with_lane = renderBlocks(.{ .mode = .off, .lanes = store[0..3] }, block);
        const no_lane = renderBlocks(.{ .mode = .off, .lanes = store[0..2] }, block);
        try expectRenderedEqual(&with_lane, &no_lane);
    }
}

test "volume and pan schedules are partition independent" {
    const gpa = testing.allocator;
    var store: [3]AutomationLane = undefined;
    try scheduleLanes(gpa, &store);
    defer for (&store) |*l| l.deinit(gpa);
    const snap: Snapshot = .{ .mode = .read, .lanes = store[0..2] };
    const reference = renderBlocks(snap, 512);
    for ([_]usize{ 16, 63, 128, 1024 }) |block| {
        try expectRenderedEqual(&renderBlocks(snap, block), &reference);
    }
}

test "panSegment splits on the 64-sample absolute grid" {
    const gpa = testing.allocator;
    var store = [_]AutomationLane{AutomationLane.init(.{ .pan = 0 })};
    defer store[0].deinit(gpa);
    try store[0].setPoint(gpa, 0.0, 0.5);
    const snap: Snapshot = .{ .mode = .read, .lanes = &store };
    // Absolute sample 50 is frame 0: the first segment reads grid point 0 and ends at 64 (frame 14).
    const plan: SegmentPlan = .{ .start_sample = 50, .start_beat = beatOf(50), .samples_per_beat = spb };
    const first = panSegment(snap, plan, 0, 200);
    try testing.expectEqual(@as(i64, -50), first.read_frame);
    try testing.expectEqual(@as(usize, 14), first.end);
    const second = panSegment(snap, plan, first.end, 200);
    try testing.expectEqual(@as(i64, 14), second.read_frame);
    try testing.expectEqual(@as(usize, 78), second.end);
    // Without pan automation the whole block shares one reading.
    const plain: Snapshot = .{ .mode = .off, .lanes = store[0..0] };
    const whole = panSegment(plain, plan, 0, 200);
    try testing.expectEqual(@as(i64, 0), whole.read_frame);
    try testing.expectEqual(@as(usize, 200), whole.end);
}

test "volumeDbAt: write mode does not read the fader lane" {
    const gpa = testing.allocator;
    var store = [_]AutomationLane{AutomationLane.init(.volume)};
    defer store[0].deinit(gpa);
    try store[0].setPoint(gpa, 0.0, -6.0);
    const plan = planAt(0);
    try testing.expectEqual(@as(f32, -3.0), volumeDbAt(.{ .mode = .write, .lanes = &store }, -3.0, plan, 0));
    try testing.expectEqual(@as(f32, -6.0), volumeDbAt(.{ .mode = .read, .lanes = &store }, -3.0, plan, 0));
}

test "GainRamp: dB-linear gain between the endpoints" {
    const ramp = GainRamp.init(0.0, -20.0, 10);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ramp.at(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), ramp.at(10), 1e-6);
    const empty = GainRamp.init(-6.0, 0.0, 0);
    try testing.expectEqual(ramp.at(0), ramp.at(0));
    try testing.expectApproxEqAbs(dsp_db.dbToGain(-6.0), empty.at(5), 1e-6);
}

test "gateMute and the level readers never allocate" {
    // The render path takes no allocator. The lanes are built through a counting allocator, and the
    // count must not move while the audio-side functions run.
    var counting = CountingAllocator{ .backing = testing.allocator };
    const gpa = counting.allocator();
    var store: [3]AutomationLane = undefined;
    try scheduleLanes(gpa, &store);
    defer for (&store) |*l| l.deinit(gpa);
    try muteEdges(gpa, &store[2], 101, 200);
    const before = counting.allocs;
    const r = renderBlocks(.{ .mode = .read, .lanes = &store }, 63);
    try testing.expect(anyAudible(&r));
    try testing.expectEqual(before, counting.allocs);
}

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        const b = self.backing;
        return b.vtable.alloc(b.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const b = self.backing;
        return b.vtable.resize(b.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        const b = self.backing;
        return b.vtable.remap(b.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const b = self.backing;
        b.vtable.free(b.ptr, memory, alignment, ret_addr);
    }
};

// --- Skipped: these need the MixEngine (routing, sends, solo, VCA, hosted processors), which is not
// part of this library. The gating they exercise is covered by the harness tests above.

test "gateMute: pre and post-fader send audio share the track mute gate" {
    // SKIP: needs the Rust send routing (SendSlot, Aux track input). Port with the mix library.
    return error.SkipZigTest;
}

test "gateMute: aux and folder inputs gate their audio inside the block" {
    // SKIP: needs bus routing between tracks (mix library).
    return error.SkipZigTest;
}

test "gateMute: static mute and solo suppression cannot be reopened by automation" {
    // SKIP: static mute and solo are the mixer's decision, made before gating (mix library).
    return error.SkipZigTest;
}

test "gateMute: static VCA mute remains dominant over member mute automation" {
    // SKIP: VCA groups live in the mix library.
    return error.SkipZigTest;
}

test "gateMute: hosted processing keeps the caller's blocks and unmuted PCM" {
    // SKIP: needs a hosted processor adopted into MixEngine. Gating does not change block sizes
    // (gateMute never splits or re-enters the caller's block), and that is covered by the partition test.
    return error.SkipZigTest;
}
