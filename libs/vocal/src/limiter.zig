// Translated to Zig from pitchpure/crates/pitchpure_engine/src/limiter.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Lookahead peak limiter for the end of the vocal chain.
//!
//! Per sample (continuous state, so block size never matters):
//!
//! 1. Input drive (`0..=18` dB).
//! 2. Peak estimate with inter-sample margin: `|x[n]|` plus the peaks of a
//!    4x Catmull-Rom interpolation between `x[n-1]` and `x[n]`, which
//!    catches most overs a DAC's reconstruction would add ("true-peak-ish").
//! 3. Required gain `min(1, ceiling / peak)` goes through a min-hold over
//!    the lookahead window `L`, then an `L`-sample box average. The audio is
//!    delayed by `L - 1`, so the averaged gain reaches the needed value
//!    exactly when the peak arrives and the attack is a smooth linear-ish
//!    ramp (no clicks).
//! 4. Release: the gain recovers with a one-pole of `release_ms`; it never
//!    rises faster than that and never sits above the box-averaged gain.
//! 5. A final clamp to +-ceiling guards against float rounding.
//!
//! Latency is constant: `L - 1` samples with `L ~ 1.5 ms` (71 samples at
//! 48 kHz), reported by `latencySamples`. When the signal stays below the
//! ceiling with 0 dB drive, the output is the input delayed by exactly that
//! latency, bit for bit. Allocation only in `VocalLimiter.init`; the caller
//! frees with `deinit` using the same allocator.

const std = @import("std");
const types = @import("types.zig");

/// Lookahead window in seconds.
const LOOKAHEAD_S: f32 = 0.0015;
/// `ln(10) / 20`.
const DB_TO_LN: f32 = std.math.ln10 / 20.0;

/// Lookahead brick-wall limiter. Owns three `window`-sized buffers.
pub const VocalLimiter = struct {
    sample_rate: f32,
    ceiling: f32,
    ceiling_db: f32,
    release_ms: f32,
    release_coef: f64,
    drive_db: f32,
    drive: f32,
    window: usize,
    delay: []f32,
    required: []f32,
    held: []f64,
    held_sum: f64,
    pos: usize,
    hist: [3]f32,
    /// Applied gain; f64 so the slow release can reach exactly 1.0
    /// (in f32 the per-sample step underflows ~1e-4 below unity).
    env: f64,

    /// Limiter at `sample_rate`: -1 dBFS ceiling, 80 ms release, no drive.
    pub fn init(gpa: std.mem.Allocator, sample_rate: types.SampleRateHz) std.mem.Allocator.Error!VocalLimiter {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        const window: usize = @max(@as(usize, @intFromFloat(@round(LOOKAHEAD_S * sr))), 2);
        const delay = try gpa.alloc(f32, window);
        errdefer gpa.free(delay);
        const required = try gpa.alloc(f32, window);
        errdefer gpa.free(required);
        const held = try gpa.alloc(f64, window);
        errdefer gpa.free(held);
        @memset(delay, 0.0);
        @memset(required, 1.0);
        @memset(held, 1.0);
        var l: VocalLimiter = .{
            .sample_rate = sr,
            .ceiling = 1.0,
            .ceiling_db = 0.0,
            .release_ms = 80.0,
            .release_coef = 0.0,
            .drive_db = 0.0,
            .drive = 1.0,
            .window = window,
            .delay = delay,
            .required = required,
            .held = held,
            .held_sum = @floatFromInt(window),
            .pos = 0,
            .hist = @splat(0.0),
            .env = 1.0,
        };
        l.setCeilingDb(-1.0);
        l.setReleaseMs(80.0);
        return l;
    }

    pub fn deinit(self: *VocalLimiter, gpa: std.mem.Allocator) void {
        gpa.free(self.delay);
        gpa.free(self.required);
        gpa.free(self.held);
        self.* = undefined;
    }

    /// Deep copy (Rust `#[derive(Clone)]`); free the result with `deinit`.
    pub fn clone(self: *const VocalLimiter, gpa: std.mem.Allocator) std.mem.Allocator.Error!VocalLimiter {
        var c = self.*;
        c.delay = try gpa.dupe(f32, self.delay);
        errdefer gpa.free(c.delay);
        c.required = try gpa.dupe(f32, self.required);
        errdefer gpa.free(c.required);
        c.held = try gpa.dupe(f64, self.held);
        return c;
    }

    /// Output ceiling in dBFS, `-12..=0`.
    pub fn setCeilingDb(self: *VocalLimiter, db: f32) void {
        self.ceiling_db = std.math.clamp(finiteOr(db, -1.0), -12.0, 0.0);
        self.ceiling = @exp(self.ceiling_db * DB_TO_LN);
    }

    /// Release time `10..=500` ms.
    pub fn setReleaseMs(self: *VocalLimiter, ms: f32) void {
        self.release_ms = std.math.clamp(finiteOr(ms, 80.0), 10.0, 500.0);
        self.release_coef = 1.0 - @exp(-1.0 / (@as(f64, self.release_ms) * 0.001 * @as(f64, self.sample_rate)));
    }

    /// Drive into the limiter `0..=18` dB.
    pub fn setInputGainDb(self: *VocalLimiter, db: f32) void {
        self.drive_db = std.math.clamp(finiteOr(db, 0.0), 0.0, 18.0);
        self.drive = if (self.drive_db == 0.0) 1.0 else @exp(self.drive_db * DB_TO_LN);
    }

    /// Current gain reduction in dB (positive = reducing).
    pub fn gainReductionDb(self: *const VocalLimiter) f32 {
        if (self.env >= 1.0) return 0.0;
        return @floatCast(-20.0 * @log10(@max(self.env, 1e-6)));
    }

    pub fn ceilingDb(self: *const VocalLimiter) f32 {
        return self.ceiling_db;
    }

    pub fn releaseMs(self: *const VocalLimiter) f32 {
        return self.release_ms;
    }

    pub fn inputGainDb(self: *const VocalLimiter) f32 {
        return self.drive_db;
    }

    /// Peak of `x[n]` and the 4x interpolated segment from `x[n-1]`.
    fn truePeak(self: *VocalLimiter, x: f32) f32 {
        const p0 = self.hist[0];
        const p1 = self.hist[1];
        const p2 = self.hist[2];
        // Catmull-Rom through p0, p1, p2, x; segment p1 -> p2 is the newest
        // complete one with both neighbours known.
        var pk = @max(@abs(x), @abs(p2));
        for ([_]f32{ 0.25, 0.5, 0.75 }) |t| {
            const t2 = t * t;
            const t3 = t2 * t;
            const v = 0.5 *
                ((2.0 * p1) +
                    (-p0 + p2) * t +
                    (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - x) * t2 +
                    (-p0 + 3.0 * p1 - 3.0 * p2 + x) * t3);
            pk = @max(pk, @abs(v));
        }
        self.hist = .{ p1, p2, x };
        return pk;
    }

    pub fn reset(self: *VocalLimiter) void {
        @memset(self.delay, 0.0);
        @memset(self.required, 1.0);
        @memset(self.held, 1.0);
        self.held_sum = @floatFromInt(self.window);
        self.pos = 0;
        self.hist = @splat(0.0);
        self.env = 1.0;
    }

    /// Processes `min(input.len, output.len)` samples. No allocation.
    pub fn process(self: *VocalLimiter, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        const w = self.window;
        const w_f: f64 = @floatFromInt(w);
        for (input[0..n], output[0..n]) |x, *y| {
            const s: f32 = if (std.math.isFinite(x)) x * self.drive else 0.0;
            const pk = self.truePeak(s);
            const need: f32 = if (pk > self.ceiling) self.ceiling / pk else 1.0;
            self.required[self.pos] = need;
            // Min-hold over the window, then box average of the holds.
            var hold: f32 = 1.0;
            for (self.required) |r| hold = @min(hold, r);
            self.held_sum += @as(f64, hold) - self.held[self.pos];
            self.held[self.pos] = hold;
            const smooth: f64 = if (self.held_sum >= w_f) 1.0 else self.held_sum / w_f;
            // Release: rise slowly, fall instantly to the smoothed gain.
            self.env = if (smooth < self.env)
                smooth
            else
                self.env + (smooth - self.env) * self.release_coef;
            if (self.env > 1.0 - 1e-9 and smooth >= 1.0) self.env = 1.0;
            // Delayed audio: the slot about to be overwritten is L samples
            // old; read the one written L-1 samples ago.
            const read = (self.pos + 1) % w;
            const delayed = self.delay[read];
            self.delay[self.pos] = s;
            self.pos = (self.pos + 1) % w;
            const out: f32 = if (self.env >= 1.0) delayed else delayed * @as(f32, @floatCast(self.env));
            y.* = std.math.clamp(out, -self.ceiling, self.ceiling);
        }
    }

    pub fn latencySamples(self: *const VocalLimiter) usize {
        return self.window - 1;
    }
};

comptime {
    types.assertProcessor(VocalLimiter);
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const SR: u32 = 48_000;
const TAU: f32 = std.math.tau;

fn run(gpa: std.mem.Allocator, l: *VocalLimiter, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var start: usize = 0;
    while (start < input.len) : (start += block) {
        const end = @min(start + block, input.len);
        l.process(input[start..end], out[start..end]);
    }
    return out;
}

/// `hot()` signal followed by `extra` zeros.
fn hotPadded(gpa: std.mem.Allocator, extra: usize) ![]f32 {
    const len: usize = SR;
    const v = try gpa.alloc(f32, len + extra);
    @memset(v, 0.0);
    for (v[0..len], 0..) |*s, i| {
        s.* = 1.6 * @sin(TAU * 997.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    var k: usize = 5000;
    while (k < len) : (k += 9000) {
        v[k] = 4.0;
        v[k + 1] = -3.5;
    }
    return v;
}

fn hot(gpa: std.mem.Allocator) ![]f32 {
    return hotPadded(gpa, 0);
}

test "never_exceeds_ceiling" {
    const gpa = testing.allocator;
    var l = try VocalLimiter.init(gpa, SR);
    defer l.deinit(gpa);
    l.setInputGainDb(6.0);
    const input = try hot(gpa);
    defer gpa.free(input);
    const out = try run(gpa, &l, input, 256);
    defer gpa.free(out);
    const ceiling = std.math.pow(f32, 10.0, -1.0 / 20.0);
    var peak: f32 = 0.0;
    for (out) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak <= ceiling + 1e-6);
    try testing.expect(l.gainReductionDb() > 3.0);
}

test "gain_is_smooth_without_clicks" {
    const gpa = testing.allocator;
    // Quiet tone then a loud one: the gain ramp must not step.
    const input = try gpa.alloc(f32, 48_000);
    defer gpa.free(input);
    for (input[0..24_000], 0..) |*s, i| {
        s.* = 0.2 * @sin(TAU * 300.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    for (input[24_000..], 0..) |*s, i| {
        s.* = 2.0 * @sin(TAU * 300.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SR)));
    }
    var l = try VocalLimiter.init(gpa, SR);
    defer l.deinit(gpa);
    const out = try run(gpa, &l, input, 512);
    defer gpa.free(out);
    var max_step: f32 = 0.0;
    for (out[0 .. out.len - 1], out[1..]) |a, b| max_step = @max(max_step, @abs(b - a));
    const natural = 0.9 * TAU * 300.0 / @as(f32, @floatFromInt(SR));
    try testing.expect(max_step < natural * 1.6);
}

test "transparent_below_ceiling_is_delayed_copy" {
    const gpa = testing.allocator;
    var l = try VocalLimiter.init(gpa, SR);
    defer l.deinit(gpa);
    const lat = l.latencySamples();
    try testing.expectEqual(@as(usize, 71), lat);
    const input = try gpa.alloc(f32, 20_000);
    defer gpa.free(input);
    for (input, 0..) |*s, i| s.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.03);
    const out = try run(gpa, &l, input, 100);
    defer gpa.free(out);
    for (out[0..lat]) |s| try testing.expect(s == 0.0);
    try testing.expectEqualSlices(f32, input[0 .. input.len - lat], out[lat..]);
}

test "block_sizes_match" {
    const gpa = testing.allocator;
    const input = try hot(gpa);
    defer gpa.free(input);
    var ref_l = try VocalLimiter.init(gpa, SR);
    defer ref_l.deinit(gpa);
    const reference = try run(gpa, &ref_l, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var l = try VocalLimiter.init(gpa, SR);
        defer l.deinit(gpa);
        const got = try run(gpa, &l, input, block);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, reference, got);
    }
}

test "silence_is_clean" {
    const gpa = testing.allocator;
    var l = try VocalLimiter.init(gpa, SR);
    defer l.deinit(gpa);
    const input = try hotPadded(gpa, SR * 5);
    defer gpa.free(input);
    const out = try run(gpa, &l, input, 512);
    defer gpa.free(out);
    for (out) |s| {
        try testing.expect(std.math.isFinite(s) and (s == 0.0 or @abs(s) >= std.math.floatMin(f32)));
    }
    try testing.expectEqual(@as(f32, 0.0), l.gainReductionDb());
}

test "bench_cpu" {
    // Rust marks this #[ignore] (benchmark that only prints a timing, run
    // with --ignored --nocapture). Libraries must not print, so it is skipped.
    return error.SkipZigTest;
}
