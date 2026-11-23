// Translated to Zig from soundcraft/crates/dsp/src/util.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Small realtime building blocks shared by the plugins.
//!
//! Everything here runs on the audio thread: no allocation, locking, logging
//! or I/O. [`DelayLine`] is the one type that owns memory; allocate it in
//! `init`/`prepare` and give `process` no allocator.

const std = @import("std");
const testing = std.testing;

/// Default sample rate used when a host passes something unusable.
pub const fallback_sr: f32 = 48_000.0;

/// Sanitizes a host sample rate into 1 kHz ..= 1.536 MHz.
pub fn saneSr(sr: f32) f32 {
    if (std.math.isFinite(sr) and sr >= 1000.0) return @min(sr, 1_536_000.0);
    return fallback_sr;
}

/// Upper bound on channels any plugin will allocate state for.
pub const max_channels: usize = 64;

pub fn saneChannels(ch: usize) usize {
    return @min(ch, max_channels);
}

/// Converts milliseconds to (fractional) samples, never negative or non-finite.
pub inline fn msToSamples(ms: f32, sr: f32) f32 {
    const s = ms * 0.001 * sr;
    if (std.math.isFinite(s)) return @max(s, 0.0);
    return 0.0;
}

/// One-pole coefficient for a time constant in milliseconds.
pub inline fn timeCoef(ms: f32, sr: f32) f32 {
    const n = msToSamples(ms, sr);
    if (n < 1.0e-3) return 0.0;
    return @exp(-1.0 / n);
}

/// Flushes denormals and non-finite values in feedback paths to zero.
pub inline fn flush(x: f32) f32 {
    const a = @abs(x);
    if (a > 1.0e-25 and a < std.math.inf(f32)) return x;
    return 0.0;
}

/// Number of frames a plugin may safely touch: the smallest plane length in
/// `io[0..channels]`, capped by `frames`.
pub fn framesIn(io: []const []const f32, frames: usize, channels: usize) usize {
    var n = frames;
    const limit = @min(channels, io.len);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        n = @min(n, io[i].len);
    }
    return n;
}

/// One-pole exponential parameter smoother (no zipper noise).
pub const Smoother = struct {
    cur: f32,
    target: f32,
    coef: f32,

    pub fn init(v: f32) Smoother {
        return .{ .cur = v, .target = v, .coef = 0.0 };
    }

    /// Sets the time constant (default ~20 ms is typical).
    pub fn setTime(self: *Smoother, ms: f32, sr: f32) void {
        self.coef = timeCoef(ms, sr);
    }

    pub fn set(self: *Smoother, v: f32) void {
        if (std.math.isFinite(v)) {
            self.target = v;
        }
    }

    pub fn snap(self: *Smoother) void {
        self.cur = self.target;
    }

    pub fn value(self: *const Smoother) f32 {
        return self.cur;
    }

    pub fn settling(self: *const Smoother) bool {
        return self.cur != self.target;
    }

    pub inline fn next(self: *Smoother) f32 {
        if (self.cur != self.target) {
            self.cur = self.target + (self.cur - self.target) * self.coef;
            if (@abs(self.cur - self.target) <= 1.0e-6 * (1.0 + @abs(self.target))) {
                self.cur = self.target;
            }
        }
        return self.cur;
    }

    /// Advances `n` samples at once (used for block-rate coefficient updates).
    /// Rust used `powi`; the integer exponent keeps the same contract.
    pub fn advance(self: *Smoother, n: usize) f32 {
        if (self.cur != self.target) {
            const steps: i32 = @intCast(@min(n, std.math.maxInt(i32)));
            const k = std.math.pow(f32, self.coef, @as(f32, @floatFromInt(steps)));
            self.cur = self.target + (self.cur - self.target) * k;
            if (@abs(self.cur - self.target) <= 1.0e-6 * (1.0 + @abs(self.target))) {
                self.cur = self.target;
            }
        }
        return self.cur;
    }
};

/// Power-of-two circular delay line with fractional reads.
pub const DelayLine = struct {
    buf: []f32 = &.{},
    mask: usize = 0,
    pos: usize = 0,

    /// Frees the buffer. Call once; `allocate` may be called again afterwards.
    pub fn deinit(self: *DelayLine, gpa: std.mem.Allocator) void {
        if (self.buf.len > 0) gpa.free(self.buf);
        self.buf = &.{};
        self.mask = 0;
        self.pos = 0;
    }

    /// Allocates room for at least `max_delay` samples of delay. Replaces any
    /// previous buffer, like the Rust `Vec` assignment did.
    pub fn allocate(self: *DelayLine, gpa: std.mem.Allocator, max_delay: usize) error{OutOfMemory}!void {
        const wanted = std.math.clamp(max_delay +| 4, 4, 1 << 26);
        const len = std.math.ceilPowerOfTwo(usize, wanted) catch unreachable;
        const buf = try gpa.alloc(f32, len);
        @memset(buf, 0.0);
        if (self.buf.len > 0) gpa.free(self.buf);
        self.buf = buf;
        self.mask = len - 1;
        self.pos = 0;
    }

    pub fn clear(self: *DelayLine) void {
        @memset(self.buf, 0.0);
    }

    /// Largest delay (in samples) that `read` supports.
    pub fn maxDelay(self: *const DelayLine) f32 {
        return @as(f32, @floatFromInt(self.buf.len -| 3));
    }

    pub inline fn push(self: *DelayLine, x: f32) void {
        if (self.pos < self.buf.len) {
            self.buf[self.pos] = x;
        }
        self.pos = (self.pos + 1) & self.mask;
    }

    /// Reads the sample written `d` pushes ago (`d = 1` is the last written sample).
    pub inline fn tap(self: *const DelayLine, d: usize) f32 {
        const idx = (self.pos -% d) & self.mask;
        if (idx < self.buf.len) return self.buf[idx];
        return 0.0;
    }

    /// Linear-interpolated read `d` samples back (clamped to 1..=max_delay).
    pub fn read(self: *const DelayLine, d: f32) f32 {
        const dist = if (std.math.isFinite(d))
            std.math.clamp(d, 1.0, @max(self.maxDelay(), 1.0))
        else
            1.0;
        const i = usizeFromF32Sat(dist);
        const f = dist - @as(f32, @floatFromInt(i));
        const a = self.tap(i);
        const b = self.tap(i + 1);
        return a + (b - a) * f;
    }

    /// Cubic (Hermite) interpolated read, for modulated delays.
    pub fn readCubic(self: *const DelayLine, d: f32) f32 {
        const dist = if (std.math.isFinite(d))
            std.math.clamp(d, 2.0, @max(self.maxDelay() - 1.0, 2.0))
        else
            2.0;
        const i = usizeFromF32Sat(dist);
        const f = dist - @as(f32, @floatFromInt(i));
        const xm1 = self.tap(i - 1);
        const x0 = self.tap(i);
        const x1 = self.tap(i + 1);
        const x2 = self.tap(i + 2);
        const c1 = 0.5 * (x1 - xm1);
        const c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
        const c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
        return ((c3 * f + c2) * f + c1) * f + x0;
    }
};

/// Rust `value as usize`: NaN and negatives give 0, huge values saturate.
fn usizeFromF32Sat(v: f32) usize {
    if (!(v > 0.0)) return 0;
    if (v >= @as(f32, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(v);
}

/// Xorshift32 noise source (deterministic, allocation free).
pub const Rng = struct {
    state: u32,

    pub fn init(seed: u32) Rng {
        return .{ .state = if (seed == 0) 0x9E37_79B9 else seed };
    }

    pub fn nextU32(self: *Rng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// Uniform white noise in -1..1.
    pub fn bipolar(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.nextU32() >> 8)) * (2.0 / 16_777_216.0) - 1.0;
    }
};

/// Pink noise via a sum of first-order filtered white noise (Kellet-style economy filter).
pub const PinkNoise = struct {
    b: [7]f32 = @splat(0.0),

    pub fn init() PinkNoise {
        return .{};
    }

    pub fn next(self: *PinkNoise, white: f32) f32 {
        const b = &self.b;
        b[0] = 0.99886 * b[0] + white * 0.0555179;
        b[1] = 0.99332 * b[1] + white * 0.0750759;
        b[2] = 0.96900 * b[2] + white * 0.153_852;
        b[3] = 0.86650 * b[3] + white * 0.3104856;
        b[4] = 0.55000 * b[4] + white * 0.5329522;
        b[5] = -0.7616 * b[5] - white * 0.016_898;
        const out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362;
        b[6] = white * 0.115926;
        return out * 0.11;
    }
};

/// Sine LFO with phase in 0..1.
pub const Lfo = struct {
    phase: f32,

    pub fn init() Lfo {
        return .{ .phase = 0.0 };
    }

    pub fn reset(self: *Lfo) void {
        self.phase = 0.0;
    }

    /// Advances by `inc` cycles and returns the new phase (use [`Lfo.sinAt`] to read it;
    /// pass an `offset` phase for stereo spread).
    pub fn tick(self: *Lfo, inc: f32) f32 {
        const step = if (std.math.isFinite(inc)) std.math.clamp(inc, 0.0, 0.5) else 0.0;
        self.phase += step;
        if (self.phase >= 1.0) {
            self.phase -= 1.0;
        }
        return self.phase;
    }

    pub fn sinAt(phase: f32) f32 {
        return @sin(phase * std.math.tau);
    }
};

/// DC blocking one-pole high-pass.
pub const DcBlocker = struct {
    r: f32,
    x1: f32,
    y1: f32,

    pub fn init(cutoff_hz: f32, sr: f32) DcBlocker {
        var d = DcBlocker{ .r = 0.995, .x1 = 0.0, .y1 = 0.0 };
        d.setCutoff(cutoff_hz, sr);
        return d;
    }

    pub fn setCutoff(self: *DcBlocker, cutoff_hz: f32, sr: f32) void {
        const fc = if (std.math.isFinite(cutoff_hz)) std.math.clamp(cutoff_hz, 0.1, 1000.0) else 5.0;
        self.r = @exp(-std.math.tau * fc / saneSr(sr));
    }

    pub fn reset(self: *DcBlocker) void {
        self.x1 = 0.0;
        self.y1 = 0.0;
    }

    pub fn process(self: *DcBlocker, x: f32) f32 {
        const y = x - self.x1 + self.r * self.y1;
        self.x1 = x;
        self.y1 = flush(y);
        return self.y1;
    }
};

/// Sorts pending note events by offset in place (insertion sort; tiny lists, no
/// allocation). Stable: equal keys keep their order. `key` returns the sort
/// offset of an event.
pub fn sortEvents(comptime T: type, ev: []T, context: anytype, comptime key: fn (@TypeOf(context), *const T) usize) void {
    var i: usize = 1;
    while (i < ev.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            if (key(context, &ev[j - 1]) <= key(context, &ev[j])) break;
            std.mem.swap(T, &ev[j - 1], &ev[j]);
            j -= 1;
        }
    }
}

/// Converts a MIDI note number to Hz (A4 = 440).
pub inline fn noteHz(note: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (note - 69.0) / 12.0);
}

fn expectFlushBits(b: u32) !void {
    const x: f32 = @bitCast(b);
    const want: f32 = if (std.math.isFinite(x) and @abs(x) > 1.0e-25) x else 0.0;
    try testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(flush(x))));
}

test "flush_matches_the_finite_and_magnitude_test" {
    // Ported verbatim from the Rust test of the same name.
    const edge: u32 = @bitCast(@as(f32, 1.0e-25));
    const special = [_]u32{
        0,           0x8000_0000, 1,           edge - 1,    edge,        edge + 1,
        0x7f7f_ffff, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xffc0_0001,
    };
    var b: u64 = 0;
    while (b <= std.math.maxInt(u32)) : (b += 997) {
        try expectFlushBits(@intCast(b));
    }
    for (special) |bits| {
        try expectFlushBits(bits);
        try expectFlushBits(bits | 0x8000_0000);
    }
}

test "saneSr_clamps_to_1k_1p536M_and_sanitizes" {
    try testing.expectEqual(@as(f32, 48_000.0), saneSr(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 48_000.0), saneSr(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 48_000.0), saneSr(-1.0));
    try testing.expectEqual(@as(f32, 48_000.0), saneSr(999.0));
    try testing.expectEqual(@as(f32, 1_000.0), saneSr(1_000.0));
    try testing.expectEqual(@as(f32, 96_000.0), saneSr(96_000.0));
    try testing.expectEqual(@as(f32, 1_536_000.0), saneSr(2_000_000.0));
}

test "saneChannels_caps_at_max_channels" {
    try testing.expectEqual(@as(usize, 2), saneChannels(2));
    try testing.expectEqual(max_channels, saneChannels(1_000));
}

test "msToSamples_and_timeCoef_edges" {
    try testing.expectEqual(@as(f32, 48_000.0), msToSamples(1_000.0, 48_000.0));
    try testing.expectEqual(@as(f32, 0.0), msToSamples(-5.0, 48_000.0));
    try testing.expectEqual(@as(f32, 0.0), msToSamples(std.math.nan(f32), 48_000.0));
    // 20 ms at 48 kHz is 960 samples; coef = exp(-1/960).
    try testing.expectEqual(@as(f32, 0.0), timeCoef(0.0, 48_000.0));
    try testing.expectApproxEqAbs(@as(f32, @exp(-1.0 / 960.0)), timeCoef(20.0, 48_000.0), 1e-6);
}

test "framesIn_takes_the_smallest_plane" {
    const pa: [10]f32 = @splat(0.0);
    const pb: [20]f32 = @splat(0.0);
    const pc: [30]f32 = @splat(0.0);
    const io = [_][]const f32{ &pa, &pb, &pc };
    try testing.expectEqual(@as(usize, 10), framesIn(&io, 15, 2));
    try testing.expectEqual(@as(usize, 10), framesIn(&io, 15, 5));
    try testing.expectEqual(@as(usize, 15), framesIn(&io, 15, 0));
    try testing.expectEqual(@as(usize, 5), framesIn(&io, 5, 3));
}

test "Smoother_set_snap_settling_and_convergence" {
    var s = Smoother.init(0.5);
    try testing.expect(!s.settling());
    try testing.expectEqual(@as(f32, 0.5), s.value());
    s.setTime(20.0, 48_000.0);
    s.set(1.0);
    try testing.expect(s.settling());
    // NaN targets are ignored.
    s.set(std.math.nan(f32));
    var i: usize = 0;
    while (i < 100_000) : (i += 1) _ = s.next();
    // In f32 the per-step move shrinks below half an ULP of `cur` before the
    // 1e-6 snap band is reached, so `next` stalls just short of the target —
    // the same stall the Rust code has. `snap` finishes the job.
    try testing.expect(s.value() > 0.9999);
    try testing.expect(s.settling());
    s.snap();
    try testing.expectEqual(@as(f32, 1.0), s.value());
    try testing.expect(!s.settling());
    s.set(0.0);
    s.snap();
    try testing.expectEqual(@as(f32, 0.0), s.value());
    try testing.expect(!s.settling());
}

test "Smoother_advance_jumps_ahead_of_single_steps" {
    var fast = Smoother.init(0.0);
    fast.setTime(20.0, 48_000.0);
    fast.set(1.0);
    _ = fast.advance(20_000);
    try testing.expectEqual(@as(f32, 1.0), fast.value());
    try testing.expect(!fast.settling());

    var slow = Smoother.init(0.0);
    slow.setTime(20.0, 48_000.0);
    slow.set(1.0);
    _ = slow.next();
    try testing.expect(slow.settling());
}

test "DelayLine_tap_read_and_readCubic" {
    const gpa = testing.allocator;
    var dl = DelayLine{};
    defer dl.deinit(gpa);
    try dl.allocate(gpa, 1_000);
    // next_power_of_two(clamp(1000 + 4)) = next_power_of_two(1004) = 1024.
    try testing.expectEqual(@as(usize, 1024), dl.buf.len);
    try testing.expectEqual(@as(f32, 1021.0), dl.maxDelay());

    // Cleared lines read zero.
    dl.clear();
    try testing.expectEqual(@as(f32, 0.0), dl.read(1.0));

    // Push 0, 1, 2 ... 63; the newest sample is at tap(1).
    var k: f32 = 0;
    while (k < 64.0) : (k += 1) dl.push(k);
    try testing.expectEqual(@as(f32, 63.0), dl.tap(1));
    try testing.expectEqual(@as(f32, 62.0), dl.tap(2));
    try testing.expectEqual(@as(f32, 63.0), dl.read(1.0));
    // Halfway between taps 40 (=24) and 41 (=23).
    try testing.expectEqual(@as(f32, 23.5), dl.read(40.5));
    // Hermite over linear data reproduces the tap exactly.
    try testing.expectEqual(@as(f32, 61.0), dl.readCubic(3.0));
    // Reads clamp into 1..=max_delay; beyond the written data lies silence.
    try testing.expectEqual(@as(f32, 63.0), dl.read(0.0));
    try testing.expectEqual(@as(f32, 0.0), dl.read(9_999.0));
    try testing.expectEqual(@as(f32, 63.0), dl.read(std.math.nan(f32)));
}

test "Rng_is_deterministic_and_seed0_uses_the_golden_constant" {
    var a = Rng.init(1);
    // Hand-computed: 1 ^ (1<<13) = 0x2001; >>17 is 0; ^ (0x2001<<5) = 0x42021.
    try testing.expectEqual(@as(u32, 0x42021), a.nextU32());
    // Two generators with the same seed stay in lockstep.
    var b1 = Rng.init(1);
    var b2 = Rng.init(1);
    try testing.expectEqual(b1.nextU32(), b2.nextU32());
    try testing.expectEqual(b1.nextU32(), b2.nextU32());
    var zero = Rng.init(0);
    var golden = Rng.init(0x9E37_79B9);
    try testing.expectEqual(golden.nextU32(), zero.nextU32());
    var r = Rng.init(42);
    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        const v = r.bipolar();
        try testing.expect(v >= -1.0 and v < 1.0);
    }
}

test "PinkNoise_is_deterministic_and_bounded" {
    var p1 = PinkNoise.init();
    var p2 = PinkNoise.init();
    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        const v1 = p1.next(0.5);
        const v2 = p2.next(0.5);
        try testing.expectEqual(v1, v2);
        try testing.expect(std.math.isFinite(v1));
        try testing.expect(@abs(v1) < 4.0);
    }
}

test "Lfo_wraps_clamps_and_sinAt" {
    var l = Lfo.init();
    try testing.expectEqual(@as(f32, 0.25), l.tick(0.25));
    try testing.expectEqual(@as(f32, 0.5), l.tick(0.25));
    try testing.expectEqual(@as(f32, 0.75), l.tick(0.25));
    try testing.expectEqual(@as(f32, 0.0), l.tick(0.25));
    // Over-large and non-finite increments clamp to 0.
    try testing.expectEqual(@as(f32, 0.5), l.tick(1.0));
    try testing.expectEqual(@as(f32, 0.5), l.tick(std.math.nan(f32)));
    l.reset();
    try testing.expectEqual(@as(f32, 0.0), l.phase);
    try testing.expectApproxEqAbs(@as(f32, 1.0), Lfo.sinAt(0.25), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), Lfo.sinAt(0.5), 1e-6);
}

test "DcBlocker_kills_dc_and_reset_clears_state" {
    var d = DcBlocker.init(10.0, 48_000.0);
    var i: usize = 0;
    while (i < 8_000) : (i += 1) _ = d.process(1.0);
    try testing.expect(@abs(d.process(1.0)) < 1.0e-4);
    d.reset();
    try testing.expectEqual(@as(f32, 0.0), d.process(0.0));
    // A hot cutoff is clamped to 1 kHz; a non-finite one falls back to 5 Hz.
    d.setCutoff(10_000.0, 48_000.0);
    d.setCutoff(std.math.nan(f32), 48_000.0);
}

test "sortEvents_orders_by_key_and_keeps_equal_keys_stable" {
    const Ev = struct { off: usize, id: usize };
    const Ctx = struct {
        fn key(_: void, e: *const Ev) usize {
            return e.off;
        }
    };
    var evs = [_]Ev{
        .{ .off = 3, .id = 0 },
        .{ .off = 1, .id = 1 },
        .{ .off = 3, .id = 2 },
        .{ .off = 1, .id = 3 },
    };
    sortEvents(Ev, &evs, {}, Ctx.key);
    try testing.expectEqual(@as(usize, 1), evs[0].off);
    try testing.expectEqual(@as(usize, 1), evs[1].off);
    try testing.expectEqual(@as(usize, 3), evs[2].off);
    try testing.expectEqual(@as(usize, 3), evs[3].off);
    // Stable: within equal offsets the original order survives.
    try testing.expectEqual(@as(usize, 1), evs[0].id);
    try testing.expectEqual(@as(usize, 3), evs[1].id);
    try testing.expectEqual(@as(usize, 0), evs[2].id);
    try testing.expectEqual(@as(usize, 2), evs[3].id);
}

test "noteHz_a4_is_440_and_octaves_double" {
    try testing.expectApproxEqAbs(@as(f32, 440.0), noteHz(69.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 880.0), noteHz(81.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 220.0), noteHz(57.0), 1e-4);
}
