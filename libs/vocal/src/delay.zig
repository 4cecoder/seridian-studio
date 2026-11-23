// Translated to Zig from pitchpure/crates/pitchpure_engine/src/delay.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Tempo-synced vocal delay with sidechain ducking.
//!
//! * Time: `60 / bpm × beats(division)` seconds, at most 2.5 s. The read
//!   position glides toward a new time with a ~50 ms one-pole, so tempo or
//!   division changes pitch-bend smoothly instead of zippering. The first
//!   block after construction/reset snaps straight to the target.
//! * Repeats: linear-interpolated read → tone (one-pole highpass +
//!   lowpass; higher `tone` = darker, thinner repeats) → optional soft
//!   clip in the loop → `feedback` back into the line, so each echo gets a
//!   little darker and grittier than the last.
//! * Ducking: an envelope follower on the dry input (10 ms attack,
//!   250 ms release) turns the echoes down by up to 24 dB while the singer
//!   is singing, so they bloom in the gaps between phrases.
//!
//! Output is `dry + mix × wet`; `mix == 0` is a bit-exact passthrough.
//! Per-sample processing with continuous state: block size never changes
//! the result. Allocation only in `DuckingDelay.init`.

const std = @import("std");
const types = @import("types.zig");

const tau: f32 = 2.0 * std.math.pi;
const ln_10: f32 = std.math.ln10;

/// Longest delay the buffer supports, in seconds.
const max_delay_s: f32 = 2.5;
/// Delay-time glide time constant.
const glide_tau_s: f32 = 0.05;
/// Ducking envelope attack/release.
const duck_attack_s: f32 = 0.010;
const duck_release_s: f32 = 0.250;
/// Envelope level treated as "fully singing" for ducking.
const duck_full_level: f32 = 0.1;
/// Maximum ducking depth in dB at `duck = 1`.
const duck_max_db: f32 = 24.0;

/// Note value the delay time is synced to.
pub const Division = enum {
    quarter,
    eighth,
    dotted_eighth,
    sixteenth,
    quarter_triplet,

    pub const all = [_]Division{ .quarter, .eighth, .dotted_eighth, .sixteenth, .quarter_triplet };

    /// Length in quarter-note beats.
    pub fn beats(self: Division) f32 {
        return switch (self) {
            .quarter => 1.0,
            .eighth => 0.5,
            .dotted_eighth => 0.75,
            .sixteenth => 0.25,
            .quarter_triplet => 2.0 / 3.0,
        };
    }

    pub fn label(self: Division) []const u8 {
        return switch (self) {
            .quarter => "1/4",
            .eighth => "1/8",
            .dotted_eighth => "1/8.",
            .sixteenth => "1/16",
            .quarter_triplet => "1/4T",
        };
    }
};

/// Tempo-synced, ducking feedback delay. Owns `buf`; free it with `deinit`.
pub const DuckingDelay = struct {
    sample_rate: f32,
    buf: []f32,
    pos: usize,
    bpm: f32,
    division: Division,
    feedback: f32,
    mix: f32,
    tone: f32,
    duck: f32,
    saturation: f32,
    target: f32,
    current: f32,
    snap: bool,
    glide_coef: f32,
    lp_coef: f32,
    hp_coef: f32,
    lp: f32,
    hp_lp: f32,
    env: f32,
    attack_coef: f32,
    release_coef: f32,

    /// Delay at `sample_rate`: 120 bpm quarter notes, 35% feedback,
    /// 25% mix, half tone, half ducking, no saturation.
    pub fn init(gpa: std.mem.Allocator, sample_rate: types.SampleRateHz) !DuckingDelay {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        const len: usize = @as(usize, @intFromFloat(max_delay_s * sr)) + 4;
        const buf = try gpa.alloc(f32, len);
        @memset(buf, 0.0);
        var d: DuckingDelay = .{
            .sample_rate = sr,
            .buf = buf,
            .pos = 0,
            .bpm = 120.0,
            .division = .quarter,
            .feedback = 0.35,
            .mix = 0.25,
            .tone = 0.5,
            .duck = 0.5,
            .saturation = 0.0,
            .target = 0.0,
            .current = 0.0,
            .snap = true,
            .glide_coef = coef(glide_tau_s, sr),
            .lp_coef = 0.0,
            .hp_coef = 0.0,
            .lp = 0.0,
            .hp_lp = 0.0,
            .env = 0.0,
            .attack_coef = coef(duck_attack_s, sr),
            .release_coef = coef(duck_release_s, sr),
        };
        d.updateTime();
        d.setTone(0.5);
        return d;
    }

    pub fn deinit(self: *DuckingDelay, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// Tempo in BPM, clamped to `40..=240`.
    pub fn setBpm(self: *DuckingDelay, bpm: f32) void {
        self.bpm = std.math.clamp(finiteOr(bpm, 120.0), 40.0, 240.0);
        self.updateTime();
    }

    pub fn setDivision(self: *DuckingDelay, division: Division) void {
        self.division = division;
        self.updateTime();
    }

    /// Feedback `0..=0.9`.
    pub fn setFeedback(self: *DuckingDelay, fb: f32) void {
        self.feedback = std.math.clamp(finiteOr(fb, 0.35), 0.0, 0.9);
    }

    /// Wet amount `0..=1`.
    pub fn setMix(self: *DuckingDelay, mix: f32) void {
        self.mix = std.math.clamp(finiteOr(mix, 0.25), 0.0, 1.0);
    }

    /// Repeat colour `0..=1`: lowpass 12 kHz→2 kHz, highpass 60→400 Hz.
    pub fn setTone(self: *DuckingDelay, tone: f32) void {
        self.tone = std.math.clamp(finiteOr(tone, 0.5), 0.0, 1.0);
        const lp_hz = @min(12_000.0 + (2_000.0 - 12_000.0) * self.tone, 0.45 * self.sample_rate);
        const hp_hz = 60.0 + (400.0 - 60.0) * self.tone;
        self.lp_coef = 1.0 - @exp(-tau * lp_hz / self.sample_rate);
        self.hp_coef = 1.0 - @exp(-tau * hp_hz / self.sample_rate);
    }

    /// Sidechain ducking depth `0..=1`.
    pub fn setDuck(self: *DuckingDelay, duck: f32) void {
        self.duck = std.math.clamp(finiteOr(duck, 0.5), 0.0, 1.0);
    }

    /// Soft clip in the feedback loop `0..=1`.
    pub fn setSaturation(self: *DuckingDelay, sat: f32) void {
        self.saturation = std.math.clamp(finiteOr(sat, 0.0), 0.0, 1.0);
    }

    /// Current synced delay time in seconds.
    pub fn delaySeconds(self: *const DuckingDelay) f32 {
        return self.target / self.sample_rate;
    }

    pub fn getBpm(self: *const DuckingDelay) f32 {
        return self.bpm;
    }

    pub fn getDivision(self: *const DuckingDelay) Division {
        return self.division;
    }

    pub fn getMix(self: *const DuckingDelay) f32 {
        return self.mix;
    }

    fn updateTime(self: *DuckingDelay) void {
        const secs = 60.0 / self.bpm * self.division.beats();
        const max: f32 = @floatFromInt(self.buf.len - 3);
        self.target = std.math.clamp(secs * self.sample_rate, 1.0, max);
    }

    fn read(self: *const DuckingDelay, delay: f32) f32 {
        const len = self.buf.len;
        const r = @as(f32, @floatFromInt(self.pos)) + @as(f32, @floatFromInt(len)) - delay;
        const i_0 = @floor(r);
        const frac = r - i_0;
        const idx: usize = @intFromFloat(i_0);
        const a = self.buf[idx % len];
        const b = self.buf[(idx + 1) % len];
        return a + (b - a) * frac;
    }

    pub fn reset(self: *DuckingDelay) void {
        @memset(self.buf, 0.0);
        self.pos = 0;
        self.snap = true;
        self.lp = 0.0;
        self.hp_lp = 0.0;
        self.env = 0.0;
    }

    pub fn process(self: *DuckingDelay, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        if (self.snap) {
            self.current = self.target;
            self.snap = false;
        }
        const len = self.buf.len;
        const duck_ln = -duck_max_db * self.duck * ln_10 / 20.0;
        for (input[0..n], output[0..n]) |x, *y| {
            const dry = x;
            const s = if (std.math.isFinite(dry)) dry else 0.0;
            self.current += (self.target - self.current) * self.glide_coef;
            const echo = self.read(self.current);
            // Tone: highpass then lowpass on the repeat.
            self.hp_lp = flush(self.hp_lp + (echo - self.hp_lp) * self.hp_coef);
            const hp = echo - self.hp_lp;
            self.lp = flush(self.lp + (hp - self.lp) * self.lp_coef);
            var wet = self.lp;
            if (self.saturation > 0.0) {
                wet += self.saturation * (std.math.tanh(wet) - wet);
            }
            self.buf[self.pos] = flush(s + self.feedback * wet);
            self.pos = (self.pos + 1) % len;
            // Duck the echoes under the dry voice.
            const level = @abs(s);
            const c = if (level > self.env) self.attack_coef else self.release_coef;
            self.env = flush(self.env + (level - self.env) * c);
            const amount = @min(self.env / duck_full_level, 1.0);
            const gain: f32 = if (self.duck > 0.0) @exp(duck_ln * amount) else 1.0;
            y.* = dry + self.mix * wet * gain;
        }
    }
};

comptime {
    types.assertProcessor(DuckingDelay);
}

fn coef(tau_s: f32, sample_rate: f32) f32 {
    return 1.0 - @exp(-1.0 / (@max(tau_s, 1e-5) * sample_rate));
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

fn flush(v: f32) f32 {
    return if (@abs(v) < 1e-20) 0.0 else v;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_sr: u32 = 48_000;

fn testRun(gpa: std.mem.Allocator, d: *DuckingDelay, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var off: usize = 0;
    while (off < input.len) : (off += block) {
        const end = @min(off + block, input.len);
        d.process(input[off..end], out[off..end]);
    }
    return out;
}

fn impulse(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const v = try gpa.alloc(f32, n);
    @memset(v, 0.0);
    v[0] = 1.0;
    return v;
}

fn toneSignal(gpa: std.mem.Allocator, n: usize, hz: f32) ![]f32 {
    const v = try gpa.alloc(f32, n);
    for (v, 0..) |*s, i| {
        s.* = 0.3 * @sin(tau * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_sr)));
    }
    return v;
}

test "zero_mix_is_bit_exact" {
    const gpa = testing.allocator;
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setMix(0.0);
    const input = try gpa.alloc(f32, 20_000);
    defer gpa.free(input);
    for (input, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.01) * 0.5;
    const out = try testRun(gpa, &d, input, 256);
    defer gpa.free(out);
    try testing.expectEqualSlices(f32, input, out);
}

test "echo_lands_on_the_beat_and_decays" {
    const gpa = testing.allocator;
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setMix(1.0);
    d.setDuck(0.0);
    d.setTone(0.0);
    d.setFeedback(0.5);
    const imp = try impulse(gpa, test_sr * 2);
    defer gpa.free(imp);
    const out = try testRun(gpa, &d, imp, 512);
    defer gpa.free(out);
    const beat: usize = test_sr / 2; // 120 bpm quarter = 0.5 s
    // Rust `max_by` keeps the last of equal maxima, hence `>=`.
    var first: usize = 1;
    var i: usize = 1;
    while (i < test_sr) : (i += 1) {
        if (@abs(out[i]) >= @abs(out[first])) first = i;
    }
    const diff = if (first > beat) first - beat else beat - first;
    try testing.expect(diff <= 1);
    const peak = struct {
        fn f(o: []const f32, c: usize) f32 {
            var m: f32 = 0.0;
            for (o[c - 40 .. c + 40]) |s| m = @max(m, @abs(s));
            return m;
        }
    }.f;
    const e1 = peak(out, beat);
    const e2 = peak(out, 2 * beat);
    try testing.expect(e2 < e1 * 0.7 and e2 > 0.0);
}

test "dotted_eighth_time" {
    const gpa = testing.allocator;
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setDivision(.dotted_eighth);
    try testing.expect(@abs(d.delaySeconds() - 0.375) < 1e-4);
}

fn wetEnergy(gpa: std.mem.Allocator, tone: []const f32, duck: f32) !f32 {
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setMix(1.0);
    d.setDuck(duck);
    const out = try testRun(gpa, &d, tone, 512);
    defer gpa.free(out);
    var sum: f32 = 0.0;
    for (out[test_sr..], tone[test_sr..]) |o, x| sum += (o - x) * (o - x);
    return sum;
}

test "ducking_holds_echoes_down_while_singing" {
    const gpa = testing.allocator;
    const tone = try toneSignal(gpa, test_sr * 2, 220.0);
    defer gpa.free(tone);
    const open = try wetEnergy(gpa, tone, 0.0);
    const ducked = try wetEnergy(gpa, tone, 1.0);
    try testing.expect(ducked < open * 0.1);
}

fn makeBlockDelay(gpa: std.mem.Allocator) !DuckingDelay {
    var d = try DuckingDelay.init(gpa, test_sr);
    d.setBpm(97.0);
    d.setDivision(.quarter_triplet);
    d.setSaturation(0.6);
    return d;
}

test "block_sizes_match" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(f32, 30_000);
    defer gpa.free(input);
    for (input, 0..) |*v, i| {
        v.* = if (i % 7000 < 200) @sin(@as(f32, @floatFromInt(i)) * 0.3) else 0.0;
    }
    var d_ref = try makeBlockDelay(gpa);
    defer d_ref.deinit(gpa);
    const reference = try testRun(gpa, &d_ref, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var d = try makeBlockDelay(gpa);
        defer d.deinit(gpa);
        const out = try testRun(gpa, &d, input, block);
        defer gpa.free(out);
        try testing.expectEqualSlices(f32, reference, out);
    }
}

test "tempo_change_glides_without_jumps" {
    const gpa = testing.allocator;
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setMix(1.0);
    d.setDuck(0.0);
    const tone = try toneSignal(gpa, test_sr * 3, 200.0);
    defer gpa.free(tone);
    const split: usize = test_sr * 2;
    const out = try gpa.alloc(f32, tone.len);
    defer gpa.free(out);
    const a = try testRun(gpa, &d, tone[0..split], 512);
    defer gpa.free(a);
    d.setBpm(90.0);
    const b = try testRun(gpa, &d, tone[split..], 512);
    defer gpa.free(b);
    @memcpy(out[0..split], a);
    @memcpy(out[split..], b);
    var max_step: f32 = 0.0;
    var i: usize = 1;
    while (i < out.len) : (i += 1) max_step = @max(max_step, @abs(out[i] - out[i - 1]));
    try testing.expect(max_step < 0.2);
}

test "silence_after_burst_stays_clean" {
    const gpa = testing.allocator;
    var d = try DuckingDelay.init(gpa, test_sr);
    defer d.deinit(gpa);
    d.setFeedback(0.9);
    d.setSaturation(1.0);
    const burst_len: usize = 10_000;
    const input = try gpa.alloc(f32, burst_len + test_sr * 20);
    defer gpa.free(input);
    for (input[0..burst_len], 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05);
    @memset(input[burst_len..], 0.0);
    const out = try testRun(gpa, &d, input, 512);
    defer gpa.free(out);
    for (out) |s| {
        try testing.expect(std.math.isFinite(s) and (s == 0.0 or @abs(s) >= std.math.floatMin(f32)));
    }
}

test "bench_cpu" {
    // Rust marks this #[ignore] (benchmark, prints timing); not run here.
    return error.SkipZigTest;
}
