// Translated to Zig from pitchpure/crates/pitchpure_engine/src/shifter_sola.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Continuous time-domain pitch shifter (delay-line granular with
//! correlation-aligned splices: the SOLA idea applied to a moving read
//! head).
//!
//! Input is written into a circular delay line. The output is read from it
//! by a tap that moves at `ratio` samples per output sample, so its delay
//! behind the write head drifts by `1 - ratio` per sample: shrinking for an
//! up-shift, growing for a down-shift. When the delay leaves its window the
//! tap is re-seated one grain (plus or minus a pitch period) back or
//! forward, and the old and new taps are crossfaded. The re-seat offset is
//! chosen by normalized cross-correlation so the two taps play in-phase
//! waveform (no comb/phasing at the splice), which is what keeps voices
//! clean.
//!
//! Properties the engine relies on:
//! * state persists across `process` calls and decisions are per sample, so
//!   any block partition produces bit-identical output;
//! * all storage is allocated in `SolaShifter.init`; `process`/`reset`
//!   never allocate;
//! * `latencySamples` is the tap's resting delay; at ratio `1.0` the output
//!   is the input delayed by exactly that many samples, and shifted output
//!   is centred on it.
//!
//! Implements the `types.zig` Processor contract (`reset`, `process`,
//! `latencySamples`).

const std = @import("std");
const types = @import("types.zig");

/// Smallest supported shift ratio (two octaves down).
const min_shift: f32 = 0.25;
/// Largest supported shift ratio (two octaves up).
const max_shift: f32 = 4.0;
/// Ratios this close to `1.0` count as unity (no drift, no splices).
const unity_tol: f32 = 1e-6;
/// Shortest grain, as a fraction of a second (covers two periods of a
/// low ~70 Hz voice).
const min_grain_s: f32 = 0.030;
/// Lowest voice the splice search aligns to (sets the search span).
const lowest_hz: f32 = 70.0;
/// Samples of headroom the 4-point interpolator needs behind the write head.
const interp_guard: f64 = 3.0;

/// Rust `f32 as usize` / `f64 as usize`: truncates toward zero, saturates,
/// NaN maps to 0.
fn floatToUsizeSat(x: anytype) usize {
    if (!(x > 0.0)) return 0;
    if (x >= 18446744073709551616.0) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// Grain/window sizes derived from the construction arguments.
const Geometry = struct {
    grain: usize,
    xfade: usize,
    corr_win: usize,
    search: usize,
    margin: usize,
    rest: usize,

    fn init(sample_rate: u32, frame_len: usize, hop: usize) Geometry {
        const rate: f32 = @floatFromInt(@max(sample_rate, 8_000));
        const grain = @max(@max(frame_len, floatToUsizeSat(rate * min_grain_s)), 64) & ~@as(usize, 1);
        const xfade = std.math.clamp(hop, 16, grain / 2);
        const corr_win = @max(grain / 8, 16);
        const search = @max(@min(floatToUsizeSat(rate / lowest_hz / 2.0), grain / 4), 8);
        // The window [rest - grain/2, rest + grain/2] must leave room below
        // for the correlation window and the down-shift re-seat (-search).
        const margin = search + corr_win + 8;
        const rest = grain / 2 + margin;
        return .{
            .grain = grain,
            .xfade = xfade,
            .corr_win = corr_win,
            .search = search,
            .margin = margin,
            .rest = rest,
        };
    }
};

/// Continuous pitch shifter with same-length block processing.
pub const SolaShifter = struct {
    sample_rate: u32,
    /// Grain: how far the tap is re-seated at each splice.
    grain: usize,
    /// Nominal crossfade length (shortened for big up-shifts).
    xfade: usize,
    /// Correlation window for splice alignment.
    corr_win: usize,
    /// Half-width of the splice offset search.
    search: usize,
    /// Resting delay of the tap = reported latency.
    rest: usize,
    /// Lower edge of the delay window (`rest - grain/2`).
    low: f64,
    /// Upper edge of the delay window (`rest + grain/2`).
    high: f64,
    shift_ratio: f32,
    /// Circular delay line, power-of-two length; owned, freed in `deinit`.
    buf: []f32,
    mask: usize,
    /// Index of the next write (monotonic; wrapped with `mask` on access).
    write: usize,
    /// Delay of the main tap behind the newest sample.
    delay: f64,
    /// Crossfade in progress: delay of the incoming tap.
    fade_delay: f64,
    fade_pos: usize,
    fade_len: usize,

    /// Build a shifter. `frame_len` is a lower bound for the grain (the
    /// grain is at least 30 ms so low voices keep two periods per grain);
    /// `hop` sets the nominal crossfade length (clamped to half a grain).
    /// The initial ratio is `1.0`. Allocates the delay line.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, frame_len: usize, hop_len: usize) error{OutOfMemory}!SolaShifter {
        const g = Geometry.init(sample_rate, frame_len, hop_len);
        const span = std.math.add(usize, g.grain, g.margin) catch return error.OutOfMemory;
        const span2 = std.math.add(usize, span, g.xfade) catch return error.OutOfMemory;
        const span3 = std.math.add(usize, span2, g.search) catch return error.OutOfMemory;
        const want = std.math.mul(usize, 4, span3) catch return error.OutOfMemory;
        const size = std.math.ceilPowerOfTwo(usize, want) catch return error.OutOfMemory;
        const buf = try gpa.alloc(f32, size);
        @memset(buf, 0.0);
        return .{
            .sample_rate = sample_rate,
            .grain = g.grain,
            .xfade = g.xfade,
            .corr_win = g.corr_win,
            .search = g.search,
            .rest = g.rest,
            .low = @floatFromInt(g.rest - g.grain / 2),
            .high = @floatFromInt(g.rest + g.grain / 2),
            .shift_ratio = 1.0,
            .buf = buf,
            .mask = size - 1,
            .write = 0,
            .delay = @floatFromInt(g.rest),
            .fade_delay = 0.0,
            .fade_pos = 0,
            .fade_len = 0,
        };
    }

    pub fn deinit(self: *SolaShifter, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// Latency a shifter built with these arguments reports, without
    /// building one (pure arithmetic; safe on any thread, no allocation).
    pub fn latencyFor(sample_rate: u32, frame_len: usize, hop_len: usize) usize {
        return Geometry.init(sample_rate, frame_len, hop_len).rest;
    }

    /// Sample rate in Hz passed to `init`.
    pub fn sampleRate(self: *const SolaShifter) u32 {
        return self.sample_rate;
    }

    /// Grain length in samples (the splice re-seat distance).
    pub fn frameLen(self: *const SolaShifter) usize {
        return self.grain;
    }

    /// Nominal crossfade length in samples.
    pub fn hop(self: *const SolaShifter) usize {
        return self.xfade;
    }

    /// Current pitch shift ratio (`>1` shifts up, `<1` shifts down).
    pub fn ratio(self: *const SolaShifter) f32 {
        return self.shift_ratio;
    }

    /// Set the pitch shift ratio, clamped to `0.25..=4.0`. Non-finite or
    /// non-positive values are ignored.
    pub fn setRatio(self: *SolaShifter, r: f32) void {
        if (std.math.isFinite(r) and r > 0.0) {
            self.shift_ratio = std.math.clamp(r, min_shift, max_shift);
        }
    }

    inline fn at(self: *const SolaShifter, index: usize) f32 {
        return self.buf[index & self.mask];
    }

    /// Sample `delay` samples behind the newest written sample (4-point
    /// Hermite interpolation; exact at integer delays).
    inline fn read(self: *const SolaShifter, delay: f64) f32 {
        // Positions before the first write wrap into the zeroed history.
        const newest = @as(f64, @floatFromInt(self.write)) - 1.0;
        const pos = newest - delay;
        const base = @floor(pos);
        const t: f32 = @floatCast(pos - base);
        // Rust `base as i64 as usize`: negative positions wrap.
        const i: usize = @bitCast(@as(i64, @intFromFloat(base)));
        const y0 = self.at(i -% 1);
        const y1 = self.at(i);
        const y2 = self.at(i +% 1);
        const y3 = self.at(i +% 2);
        if (t == 0.0) return y1;
        const c1 = 0.5 * (y2 - y0);
        const c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
        const c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
        return ((c3 * t + c2) * t + c1) * t + y1;
    }

    fn score(self: *const SolaShifter, start: usize, offset: usize, sign: f64) f32 {
        const cand = if (sign > 0.0) start -% offset else start +% offset;
        var dot: f32 = 0.0;
        var energy: f32 = 1e-9;
        for (0..self.corr_win) |i| {
            const a = self.at(start +% i);
            const b = self.at(cand +% i);
            dot += a * b;
            energy += b * b;
        }
        return dot / @sqrt(energy);
    }

    /// Re-seat offset in `grain +- search` whose waveform best matches the
    /// tap at `delay` (normalized cross-correlation; coarse step 2, then a
    /// +-1 refine). `sign` is +1 to look further back (up-shift), -1 forward.
    fn bestOffset(self: *const SolaShifter, delay: f64, sign: f64) f64 {
        const newest = self.write -% 1;
        const start = newest -% floatToUsizeSat(@round(delay));
        const lo = self.grain - self.search;
        const hi = self.grain + self.search;
        var best = self.grain;
        var best_score = -std.math.inf(f32);
        var offset = lo;
        while (offset <= hi) : (offset += 2) {
            const s = self.score(start, offset, sign);
            if (s > best_score) {
                best_score = s;
                best = offset;
            }
        }
        const refine = [2]usize{ best -| 1, best + 1 };
        for (refine) |o| {
            if (o >= lo and o <= hi) {
                const s = self.score(start, o, sign);
                if (s > best_score) {
                    best_score = s;
                    best = o;
                }
            }
        }
        return @floatFromInt(best);
    }

    /// Start a splice if the main tap left its delay window.
    fn maybeSplice(self: *SolaShifter) void {
        const drift = 1.0 - @as(f64, self.shift_ratio);
        if (drift < 0.0 and self.delay < self.low) {
            // Up-shift: the tap is catching the write head; re-seat it a
            // grain further back. The old tap keeps shrinking during the
            // fade, so cap the fade to what is left above the guard.
            const room = @max(self.delay - interp_guard, 1.0);
            const max_len = floatToUsizeSat(@floor(room / -drift));
            self.fade_len = @max(@min(self.xfade, max_len), 1);
            self.fade_delay = self.delay + self.bestOffset(self.delay, 1.0);
            self.fade_pos = 0;
        } else if (drift > 0.0 and self.delay > self.high) {
            // Down-shift: the tap is falling behind; re-seat it a grain
            // forward (never closer than the guard).
            const offset = self.bestOffset(self.delay, -1.0);
            self.fade_delay = @max(self.delay - offset, interp_guard + @as(f64, @floatFromInt(self.corr_win)));
            self.fade_len = self.xfade;
            self.fade_pos = 0;
        }
    }

    fn tick(self: *SolaShifter, x: f32) f32 {
        const slot = self.write & self.mask;
        self.buf[slot] = x;
        self.write += 1;
        const unity = @abs(self.shift_ratio - 1.0) <= unity_tol;
        if (self.fade_len == 0 and !unity) self.maybeSplice();
        var out: f32 = undefined;
        if (self.fade_len > 0) {
            const g = (@as(f32, @floatFromInt(self.fade_pos)) + 0.5) / @as(f32, @floatFromInt(self.fade_len));
            out = (1.0 - g) * self.read(self.delay) + g * self.read(self.fade_delay);
            self.fade_pos += 1;
            if (self.fade_pos >= self.fade_len) {
                self.delay = self.fade_delay;
                self.fade_len = 0;
            }
        } else {
            out = self.read(self.delay);
        }
        if (!unity) {
            const drift = 1.0 - @as(f64, self.shift_ratio);
            self.delay = @max(self.delay + drift, interp_guard);
            if (self.fade_len > 0) {
                self.fade_delay = @max(self.fade_delay + drift, interp_guard);
            }
        }
        return out;
    }

    /// Clear the delay line and re-centre the tap. Ratio is kept.
    pub fn reset(self: *SolaShifter) void {
        @memset(self.buf, 0.0);
        self.write = 0;
        self.delay = @floatFromInt(self.rest);
        self.fade_len = 0;
        self.fade_pos = 0;
    }

    /// Shift one block of mono audio (any length). Returns
    /// `error.LengthMismatch` if `input.len != output.len` (Seridian: the
    /// Rust panicked; `process` keeps that behaviour).
    pub fn processChecked(self: *SolaShifter, input: []const f32, output: []f32) error{LengthMismatch}!void {
        if (input.len != output.len) return error.LengthMismatch;
        for (output, input) |*o, x| o.* = self.tick(x);
    }

    /// Shift one block of mono audio (any length).
    ///
    /// Panics if `input.len != output.len`, like the Rust `assert_eq!`.
    pub fn process(self: *SolaShifter, input: []const f32, output: []f32) void {
        self.processChecked(input, output) catch
            @panic("input and output blocks must have equal length");
    }

    /// Resting delay of the read tap: the exact delay at ratio `1.0`, and
    /// the centre of the delay window while shifting.
    pub fn latencySamples(self: *const SolaShifter) usize {
        return self.rest;
    }
};

comptime {
    types.assertProcessor(SolaShifter);
}

/// Test helpers shared with other files' tests (Rust `pub(crate) mod
/// tests`: `voice`, `measure_f0`, `cents`). Allocating; tests only.
pub const test_support = struct {
    /// Harmonic "voice": f0 plus four decaying harmonics, peak ~0.5.
    /// Caller owns the result.
    pub fn voice(gpa: std.mem.Allocator, f0: f32, rate: u32, len: usize) ![]f32 {
        const out = try gpa.alloc(f32, len);
        for (out, 0..) |*s, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate));
            var sum: f32 = -0.0;
            for (1..6) |h| {
                const hf: f32 = @floatFromInt(h);
                sum += @sin(std.math.tau * f0 * hf * t) / hf;
            }
            s.* = sum * 0.22;
        }
        return out;
    }

    /// Fundamental by normalized autocorrelation with parabolic peak
    /// refinement, averaged (median) over windows of `x`.
    pub fn measureF0(gpa: std.mem.Allocator, x: []const f32, rate: u32, near_hz: f32) !f32 {
        const win: usize = 4096;
        const lag0 = @as(f32, @floatFromInt(rate)) / near_hz;
        const lo = floatToUsizeSat(lag0 * 0.8);
        const hi = floatToUsizeSat(lag0 * 1.25) + 2;
        var lags: std.ArrayList(f32) = .empty;
        defer lags.deinit(gpa);
        var start: usize = 0;
        while (start + win + hi + 2 <= x.len) {
            const frame = x[start .. start + win + hi + 2];
            var best = lo;
            var best_v = -std.math.inf(f32);
            var lag = lo;
            while (lag <= hi) : (lag += 1) {
                const v = ac(frame, win, lag);
                if (v > best_v) {
                    best_v = v;
                    best = lag;
                }
            }
            const a = ac(frame, win, best - 1);
            const b = best_v;
            const c = ac(frame, win, best + 1);
            const denom = a - 2.0 * b + c;
            const shift: f32 = if (@abs(denom) > 1e-9) 0.5 * (a - c) / denom else 0.0;
            try lags.append(gpa, @as(f32, @floatFromInt(best)) + shift);
            start += win / 2;
        }
        for (lags.items) |l| if (std.math.isNan(l)) return error.NanLag;
        std.mem.sort(f32, lags.items, {}, std.sort.asc(f32));
        if (lags.items.len == 0) return error.InputTooShort;
        return @as(f32, @floatFromInt(rate)) / lags.items[lags.items.len / 2];
    }

    fn ac(frame: []const f32, win: usize, lag: usize) f32 {
        var d: f32 = 0.0;
        var e0: f32 = 1e-12;
        var e1: f32 = 1e-12;
        for (0..win) |i| {
            d += frame[i] * frame[i + lag];
            e0 += frame[i] * frame[i];
            e1 += frame[i + lag] * frame[i + lag];
        }
        return d / @sqrt(e0 * e1);
    }

    pub fn cents(a: f32, b: f32) f32 {
        return 1200.0 * std.math.log2(a / b);
    }
};

const test_rate: u32 = 48_000;

fn testRms(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |s| sum += s * s;
    return @sqrt(sum / @as(f32, @floatFromInt(x.len)));
}

fn run(gpa: std.mem.Allocator, shifter: *SolaShifter, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var i: usize = 0;
    while (i < input.len) : (i += block) {
        const end = @min(i + block, input.len);
        shifter.process(input[i..end], out[i..end]);
    }
    return out;
}

/// Goertzel power at `freq` over `x` (Hann-weighted).
fn tonePower(x: []const f32, rate: u32, freq: f32) f32 {
    const n = x.len;
    const w = std.math.tau * freq / @as(f32, @floatFromInt(rate));
    var re: f64 = 0.0;
    var im: f64 = 0.0;
    for (x, 0..) |s, i| {
        const fi: f32 = @floatFromInt(i);
        const hann = 0.5 - 0.5 * @cos(std.math.tau * fi / @as(f32, @floatFromInt(n)));
        const v: f64 = s * hann;
        re += v * @as(f64, @cos(w * fi));
        im -= v * @as(f64, @sin(w * fi));
    }
    return @floatCast(re * re + im * im);
}

test "unity_is_exact_delay_by_latency" {
    const gpa = std.testing.allocator;
    var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
    defer s.deinit(gpa);
    const input = try test_support.voice(gpa, 220.0, test_rate, 8000);
    defer gpa.free(input);
    const out = try run(gpa, &s, input, 333);
    defer gpa.free(out);
    const lat = s.latencySamples();
    try std.testing.expect(lat > 0 and lat < 2_400);
    for (lat..input.len) |i| {
        try std.testing.expectEqual(input[i - lat], out[i]);
    }
    for (out[0..lat]) |v| try std.testing.expectEqual(@as(f32, 0.0), v);
}

test "latency_for_matches_built_shifter" {
    const gpa = std.testing.allocator;
    for ([_]u32{ 22_050, 44_100, 48_000, 96_000, 192_000 }) |rate| {
        var s = try SolaShifter.init(gpa, rate, 1024, 256);
        defer s.deinit(gpa);
        try std.testing.expectEqual(s.latencySamples(), SolaShifter.latencyFor(rate, 1024, 256));
    }
}

test "measured_delay_equals_latency" {
    const gpa = std.testing.allocator;
    var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
    defer s.deinit(gpa);
    var input: [4000]f32 = @splat(0.0);
    input[100] = 1.0;
    const out = try run(gpa, &s, &input, 64);
    defer gpa.free(out);
    // max_by: the last maximal element wins ties.
    var peak: usize = 0;
    for (out, 0..) |v, i| {
        if (@abs(v) >= @abs(out[peak])) peak = i;
    }
    try std.testing.expectEqual(s.latencySamples(), peak - 100);
}

test "shifts_pitch_accurately_across_range" {
    const gpa = std.testing.allocator;
    const f0: f32 = 220.0;
    const input = try test_support.voice(gpa, f0, test_rate, test_rate * 2);
    defer gpa.free(input);
    for ([_]f32{ -1200.0, -500.0, -100.0, -30.0, 30.0, 100.0, 700.0, 1200.0 }) |cents_shift| {
        const r = std.math.pow(f32, 2.0, cents_shift / 1200.0);
        var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
        defer s.deinit(gpa);
        s.setRatio(r);
        const out = try run(gpa, &s, input, 512);
        defer gpa.free(out);
        const got = try test_support.measureF0(gpa, out[test_rate / 4 ..], test_rate, f0 * r);
        const err = test_support.cents(got, f0 * r);
        try std.testing.expect(@abs(err) <= 5.0);
    }
}

test "level_is_preserved" {
    const gpa = std.testing.allocator;
    const input = try test_support.voice(gpa, 196.0, test_rate, test_rate * 2);
    defer gpa.free(input);
    const reference = testRms(input[test_rate / 2 ..]);
    for ([_]f32{ 0.5, 0.8, 1.02, 1.25, 1.5, 2.0 }) |r| {
        var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
        defer s.deinit(gpa);
        s.setRatio(r);
        const out = try run(gpa, &s, input, 1024);
        defer gpa.free(out);
        const db = 20.0 * std.math.log10(testRms(out[test_rate / 2 ..]) / reference);
        try std.testing.expect(@abs(db) <= 1.0);
    }
}

test "no_block_rate_buzz_on_small_corrections" {
    // The old block-wise shifter buzzed at rate/1024 ~ 47 Hz sidebands.
    const gpa = std.testing.allocator;
    const f: f32 = 220.0;
    const r = std.math.pow(f32, 2.0, 30.0 / 1200.0);
    const input = try gpa.alloc(f32, test_rate * 2);
    defer gpa.free(input);
    for (input, 0..) |*x, i| {
        x.* = 0.5 * @sin(std.math.tau * f * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_rate)));
    }
    var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
    defer s.deinit(gpa);
    s.setRatio(r);
    const out = try run(gpa, &s, input, 1024);
    defer gpa.free(out);
    const tail = out[test_rate / 2 ..];
    const fout = f * r;
    const main = tonePower(tail, test_rate, fout);
    const side = @as(f32, @floatFromInt(test_rate)) / 1024.0;
    for ([_]f32{ fout - side, fout + side }) |sb| {
        const rel = 10.0 * std.math.log10(tonePower(tail, test_rate, sb) / main);
        try std.testing.expect(rel < -40.0);
    }
}

test "any_block_partition_is_bit_identical" {
    const gpa = std.testing.allocator;
    const input = try test_support.voice(gpa, 180.0, test_rate, 30_000);
    defer gpa.free(input);
    var ref_shifter = try SolaShifter.init(gpa, test_rate, 1024, 256);
    defer ref_shifter.deinit(gpa);
    ref_shifter.setRatio(1.37);
    const reference = try run(gpa, &ref_shifter, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512, 1024 }) |block| {
        var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
        defer s.deinit(gpa);
        s.setRatio(1.37);
        const out = try run(gpa, &s, input, block);
        defer gpa.free(out);
        try std.testing.expectEqualSlices(f32, reference, out);
    }
}

test "ratio_clamps_and_ignores_garbage" {
    const gpa = std.testing.allocator;
    var s = try SolaShifter.init(gpa, 44_100, 1024, 256);
    defer s.deinit(gpa);
    s.setRatio(99.0);
    try std.testing.expectEqual(@as(f32, 4.0), s.ratio());
    s.setRatio(0.01);
    try std.testing.expectEqual(@as(f32, 0.25), s.ratio());
    for ([_]f32{ 0.0, std.math.nan(f32), -2.0 }) |bad| {
        s.setRatio(bad);
        try std.testing.expectEqual(@as(f32, 0.25), s.ratio());
    }
}

test "extreme_ratios_stay_finite_and_bounded" {
    const gpa = std.testing.allocator;
    const input = try test_support.voice(gpa, 110.0, test_rate, 40_000);
    defer gpa.free(input);
    for ([_]f32{ 0.25, 4.0 }) |r| {
        var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
        defer s.deinit(gpa);
        s.setRatio(r);
        const out = try run(gpa, &s, input, 256);
        defer gpa.free(out);
        for (out) |v| try std.testing.expect(std.math.isFinite(v) and @abs(v) < 2.0);
    }
}

// Rust #[should_panic(expected = "equal length")]: `process` still panics;
// the panic path is tested through `processChecked`, which it wraps.
test "mismatched_lengths_panic" {
    const gpa = std.testing.allocator;
    var s = try SolaShifter.init(gpa, 44_100, 1024, 256);
    defer s.deinit(gpa);
    const in: [64]f32 = @splat(0.0);
    var out: [63]f32 = @splat(0.0);
    try std.testing.expectError(error.LengthMismatch, s.processChecked(&in, &out));
}

test "reset_restores_initial_behaviour" {
    const gpa = std.testing.allocator;
    const input = try test_support.voice(gpa, 220.0, test_rate, 6000);
    defer gpa.free(input);
    var s = try SolaShifter.init(gpa, test_rate, 1024, 256);
    defer s.deinit(gpa);
    s.setRatio(1.5);
    const a = try run(gpa, &s, input, 256);
    defer gpa.free(a);
    s.reset();
    const b = try run(gpa, &s, input, 256);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(f32, a, b);
}
