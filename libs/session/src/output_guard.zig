// Translated to Zig from soundcraft/crates/playback/src/callback.rs, soundcraft/crates/playback/src/lib.rs, soundcraft/crates/playback/src/tests.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Output-fault guard for the audio callback: a block that fails goes silent and stops the
//! transport, a lost or stalled device is reported once, and every sample sent to the device is
//! clamped (NaN and infinities become silence).

const std = @import("std");
const testing = std.testing;

// --- tests (ported first; the implementation below makes them pass) ---

test "a_block_that_panics_goes_silent_and_is_reported_once" {
    var shared_playing = std.atomic.Value(bool).init(true);
    var fault: Fault = .{};
    var out: [8]f32 = @splat(0.5);

    guardedBlock(&fault, &shared_playing, &out, @as(f32, 0.25), fillWith);
    try testing.expectEqual(@as(?OutputTrouble, null), fault.trouble(false));
    try testing.expectEqualSlices(f32, &@as([8]f32, @splat(0.25)), &out);

    // A fill that reports failure (Rust: a panic inside `fill`).
    guardedBlock(&fault, &shared_playing, &out, {}, failingFill);
    // Every later block is silent, even one whose fill would succeed.
    guardedBlock(&fault, &shared_playing, &out, @as(f32, 0.25), fillWith);
    try testing.expectEqualSlices(f32, &@as([8]f32, @splat(0.0)), &out);
    try testing.expect(!shared_playing.load(.monotonic));

    const first = fault.trouble(false);
    const second = fault.trouble(false);
    try testing.expectEqual(@as(?OutputTrouble, .bug), first);
    try testing.expectEqual(@as(?OutputTrouble, null), second);
    try testing.expectEqual(@as(u64, 3), fault.beats.load(.monotonic));
}

test "a_lost_or_stalled_device_is_reported_once" {
    const stall_ns: u64 = STALL_NS;
    // Start far enough from zero that subtracting STALL cannot underflow.
    const t0: u64 = 10 * stall_ns;

    var seen: ?Seen = null;
    try testing.expect(!stalled(&seen, 5, true, t0));
    // Pretend the last block was STALL ago.
    seen.?.since_ns = t0 - stall_ns;
    try testing.expect(stalled(&seen, 5, true, t0));
    try testing.expect(!stalled(&seen, 6, true, t0)); // it asked again
    seen.?.since_ns = t0 - stall_ns;
    try testing.expect(!stalled(&seen, 6, false, t0)); // stopped, so nothing to ask for

    var idle: Fault = .{};
    try testing.expectEqual(@as(?OutputTrouble, .stalled), idle.trouble(true));

    var gone: Fault = .{};
    gone.gone.store(true, .monotonic);
    const a = gone.trouble(false);
    const b = gone.trouble(true);
    try testing.expectEqual(@as(?OutputTrouble, .gone), a);
    try testing.expectEqual(@as(?OutputTrouble, null), b);
}

test "interpolation_overflow_between_huge_samples_never_reaches_the_device" {
    // The Rust test drives AudioState::fill end to end; that harness lives with the mix
    // unit, so here we check the property the guard owns: whatever the interpolation and
    // the fold-down produce, the device sees finite samples in [-1, 1].
    const huge: f32 = 3.4e38;
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const a: f32 = if (i % 2 == 0) -huge else huge;
        const b: f32 = if (i % 2 == 0) huge else -huge;
        var k: usize = 0;
        while (k <= 8) : (k += 1) {
            const fr: f32 = @as(f32, @floatFromInt(k)) / 8.0;
            const lerp = a * (1.0 - fr) + b * fr;
            const v = outSample(lerp);
            try testing.expect(std.math.isFinite(v));
            try testing.expect(v >= -1.0 and v <= 1.0);
        }
        // Fold-down sums several channels; the sum can overflow to inf or NaN.
        const folded = a * 0.7071 + b * 0.7071 + a + b;
        const f = outSample(folded);
        try testing.expect(std.math.isFinite(f));
        try testing.expect(f >= -1.0 and f <= 1.0);
    }
}

// --- implementation ---

/// What stopped the audio output.
pub const OutputTrouble = enum {
    /// A block failed; the output stays silent.
    bug,
    /// The device went away, or the stream was invalidated and must be rebuilt.
    gone,
    /// The device stopped asking for audio while playing.
    stalled,
};

/// How the audio output is doing, for the UI. Shared between the audio thread (writes
/// `failed`, `beats`) and the control thread (reads, sets `gone`, swaps `reported`). All
/// fields are atomics, so no lock is taken on the audio thread.
pub const Fault = struct {
    /// A block failed: output stays silent from then on.
    failed: std.atomic.Value(bool) = .init(false),
    /// The device went away or the stream was invalidated: only a reconnect can restore audio.
    gone: std.atomic.Value(bool) = .init(false),
    /// Blocks so far, to tell a device that stopped asking for audio.
    beats: std.atomic.Value(u64) = .init(0),
    /// The UI has been told.
    reported: std.atomic.Value(bool) = .init(false),

    /// What stopped the output, once. Returns null when there is nothing new to report.
    /// Control thread only (it is not called from the audio callback).
    pub fn trouble(self: *Fault, is_stalled: bool) ?OutputTrouble {
        const t: OutputTrouble = if (self.failed.load(.monotonic))
            .bug
        else if (self.gone.load(.monotonic))
            .gone
        else if (is_stalled)
            .stalled
        else
            return null;
        const was_reported = self.reported.swap(true, .monotonic);
        return if (was_reported) null else t;
    }
};

/// How long a playing output may go without a block before it counts as stalled (2 s).
pub const STALL_NS: u64 = 2 * std.time.ns_per_s;

/// The block count last seen by `stalled`, and when (monotonic nanoseconds) it was first seen.
pub const Seen = struct {
    beats: u64,
    since_ns: u64,
};

/// True once the block count `beats` has stood still for `STALL_NS` while playing. `seen` is
/// updated whenever the count changes or was never recorded. `now_ns` is a monotonic clock
/// reading supplied by the caller (control thread): library logic does not read clocks.
pub fn stalled(seen: *?Seen, beats: u64, playing: bool, now_ns: u64) bool {
    if (seen.*) |s| {
        if (playing and s.beats == beats) {
            return now_ns -| s.since_ns >= STALL_NS;
        }
    }
    seen.* = .{ .beats = beats, .since_ns = now_ns };
    return false;
}

/// Fill one block with `fill`. If `fill` reports failure, or a previous block already failed,
/// this block and every later one are silent and the transport stops, rather than the failure
/// taking the app down. `fill` must return an error union (`!void`). Audio thread: no
/// allocation, no logging, atomics only.
///
/// Zig cannot unwind, so a hard `@panic` still aborts the process; see `markBug` for the hook
/// that a panic handler or a plugin-fault path can use to mark the fault first.
pub fn guardedBlock(
    fault: *Fault,
    shared_playing: *std.atomic.Value(bool),
    out: []f32,
    ctx: anytype,
    comptime fill: fn (@TypeOf(ctx), []f32) anyerror!void,
) void {
    _ = fault.beats.fetchAdd(1, .monotonic);
    var failed = fault.failed.load(.monotonic);
    if (!failed) {
        fill(ctx, out) catch {
            failed = true;
        };
    }
    if (failed) {
        fault.failed.store(true, .monotonic);
        shared_playing.store(false, .monotonic);
        @memset(out, 0.0);
    }
}

/// Hook for a fault that happened outside `guardedBlock` (a panic handler that can reach the
/// fault, or a plugin-fault path). It sets the same flag, so the next block is silent and the
/// transport stops. It does NOT stop a hard panic: the process still aborts after the handler
/// returns. Process isolation for plugins is the real answer.
pub fn markBug(fault: *Fault) void {
    fault.failed.store(true, .monotonic);
}

/// Clamp to the device range, mapping NaN and infinities to silence. Every sample sent to the
/// device passes through here.
pub fn outSample(v: f32) f32 {
    if (std.math.isFinite(v)) return std.math.clamp(v, -1.0, 1.0);
    return 0.0;
}

// Test helpers.
fn fillWith(value: f32, out: []f32) anyerror!void {
    @memset(out, value);
}

fn failingFill(_: void, _: []f32) anyerror!void {
    return error.BlockFailed;
}

test {
    std.testing.refAllDecls(@This());
}
