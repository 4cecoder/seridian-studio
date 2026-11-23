// Translated to Zig from pitchpure/crates/pitchpure_engine/src/tape.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Warm tape-style saturation for vocals.
//!
//! Signal path per sample (all state continuous, so block size never
//! changes the result):
//!
//! 1. Pre-emphasis: a first-order high-shelf (`x + e·(x − lowpass(x))`)
//!    so the top end hits the "tape" a little harder, like record EQ.
//! 2. 2× oversampling around the nonlinearity: zero-stuff, then two
//!    cascaded RBJ biquad lowpasses at 0.45·fs (base rate) for both the
//!    anti-imaging and anti-alias filters. IIR on purpose: no FIR delay,
//!    so the stage reports zero latency.
//! 3. Asymmetric soft clip `tanh(g·(x + b)) − tanh(g·b)`: the DC-free bias
//!    `b` skews the curve so even harmonics appear, as on real tape.
//! 4. De-emphasis (the inverse shelf) and a drive-dependent HF rolloff
//!    (16 kHz down to 12 kHz) for the familiar softened top.
//! 5. Auto-gain: slow mean-square followers on the stage input and output
//!    set a make-up gain so turning up drive adds colour, not volume.
//! 6. Optional wow/flutter: a short modulated delay (0.6 Hz wow + 6.5 Hz
//!    flutter). With `wow > 0` the wet path carries a fixed 5 ms delay.
//!
//! `drive == 0 && wow == 0` (or `mix == 0`) is a bit-exact passthrough.
//! Allocation happens only in `TapeSaturator.init`; `process` never allocates.

const std = @import("std");
const types = @import("types.zig");

const tau: f32 = 2.0 * std.math.pi;

/// Bias for even-order harmonics (fraction of full scale, before drive).
const bias: f32 = 0.18;
/// Maximum drive gain into the curve (≈ +18 dB at drive 1).
const max_drive_gain: f32 = 8.0;
/// Pre-emphasis shelf amount at full drive (+6 dB above the corner).
const emphasis: f32 = 1.0;
/// Emphasis shelf corner in Hz.
const emphasis_hz: f32 = 3000.0;
/// Auto-gain detector time constant.
const autogain_tau_s: f32 = 0.2;
/// Wow/flutter delay: centre and maximum excursion.
const wow_center_s: f32 = 0.005;
const wow_depth_s: f32 = 0.0008;
const flutter_depth_s: f32 = 0.00012;
const wow_hz: f32 = 0.6;
const flutter_hz: f32 = 6.5;

/// RBJ biquad in transposed direct form II.
const Biquad = struct {
    b0: f32 = 0,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn lowpass(sample_rate: f32, hz: f32, q: f32) Biquad {
        const w0 = tau * hz / sample_rate;
        const sin = @sin(w0);
        const cos = @cos(w0);
        const alpha = sin / (2.0 * q);
        const a0 = 1.0 + alpha;
        return .{
            .b0 = (1.0 - cos) / 2.0 / a0,
            .b1 = (1.0 - cos) / a0,
            .b2 = (1.0 - cos) / 2.0 / a0,
            .a1 = -2.0 * cos / a0,
            .a2 = (1.0 - alpha) / a0,
        };
    }

    fn tick(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = flush(self.b1 * x - self.a1 * y + self.z2);
        self.z2 = flush(self.b2 * x - self.a2 * y);
        return y;
    }

    fn clear(self: *Biquad) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
};

/// Two cascaded Butterworth-Q biquads (4th order).
const Lowpass4 = struct {
    a: Biquad = .{},
    b: Biquad = .{},

    fn init(sample_rate: f32, hz: f32) Lowpass4 {
        return .{
            .a = Biquad.lowpass(sample_rate, hz, 0.5411961),
            .b = Biquad.lowpass(sample_rate, hz, 1.306563),
        };
    }

    fn tick(self: *Lowpass4, x: f32) f32 {
        return self.b.tick(self.a.tick(x));
    }

    fn clear(self: *Lowpass4) void {
        self.a.clear();
        self.b.clear();
    }
};

/// Tape-style saturator. See the module docs for the signal path.
/// Owns `wow_buf`; free it with `deinit`.
pub const TapeSaturator = struct {
    sample_rate: f32,
    drive: f32,
    mix: f32,
    wow: f32,
    emphasis_coef: f32,
    pre_lp: f32,
    de_lp: f32,
    rolloff_coef: f32,
    rolloff: f32,
    up: Lowpass4,
    down: Lowpass4,
    autogain_coef: f32,
    in_ms: f32,
    out_ms: f32,
    makeup: f32,
    wow_buf: []f32,
    wow_pos: usize,
    wow_phase: f32,
    flutter_phase: f32,

    /// Saturator at `sample_rate`; starts transparent (drive 0, wow 0, mix 1).
    pub fn init(gpa: std.mem.Allocator, sample_rate: types.SampleRateHz) !TapeSaturator {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        const os = sr * 2.0;
        const aa_hz = @min(0.45 * sr, 0.45 * os);
        const wow_len: usize = @as(usize, @intFromFloat((wow_center_s + wow_depth_s + flutter_depth_s) * sr)) + 4;
        const wow_buf = try gpa.alloc(f32, @max(wow_len, 8));
        @memset(wow_buf, 0.0);
        var tape: TapeSaturator = .{
            .sample_rate = sr,
            .drive = 0.0,
            .mix = 1.0,
            .wow = 0.0,
            .emphasis_coef = 1.0 - @exp(-tau * emphasis_hz / sr),
            .pre_lp = 0.0,
            .de_lp = 0.0,
            .rolloff_coef = 1.0,
            .rolloff = 0.0,
            .up = Lowpass4.init(os, aa_hz),
            .down = Lowpass4.init(os, aa_hz),
            .autogain_coef = 1.0 - @exp(-1.0 / (autogain_tau_s * sr)),
            .in_ms = 0.0,
            .out_ms = 0.0,
            .makeup = 1.0,
            .wow_buf = wow_buf,
            .wow_pos = 0,
            .wow_phase = 0.0,
            .flutter_phase = 0.0,
        };
        tape.setDrive(0.0);
        return tape;
    }

    pub fn deinit(self: *TapeSaturator, gpa: std.mem.Allocator) void {
        gpa.free(self.wow_buf);
        self.* = undefined;
    }

    /// Drive `0..=1`; 0 bypasses the saturation entirely.
    pub fn setDrive(self: *TapeSaturator, drive: f32) void {
        self.drive = std.math.clamp(finiteOr(drive, 0.0), 0.0, 1.0);
        // HF rolloff corner slides from 16 kHz to 12 kHz with drive.
        const hz = @min(16_000.0 - 4_000.0 * self.drive, 0.45 * self.sample_rate);
        self.rolloff_coef = 1.0 - @exp(-tau * hz / self.sample_rate);
    }

    /// Dry/wet `0..=1`.
    pub fn setMix(self: *TapeSaturator, mix: f32) void {
        self.mix = std.math.clamp(finiteOr(mix, 1.0), 0.0, 1.0);
    }

    /// Wow/flutter depth `0..=1` (0 = off, no added delay).
    pub fn setWow(self: *TapeSaturator, wow: f32) void {
        self.wow = std.math.clamp(finiteOr(wow, 0.0), 0.0, 1.0);
    }

    pub fn getDrive(self: *const TapeSaturator) f32 {
        return self.drive;
    }

    pub fn getMix(self: *const TapeSaturator) f32 {
        return self.mix;
    }

    pub fn getWow(self: *const TapeSaturator) f32 {
        return self.wow;
    }

    fn curve(self: *const TapeSaturator, x: f32) f32 {
        const g = 1.0 + (max_drive_gain - 1.0) * self.drive;
        const b = bias * self.drive;
        return (std.math.tanh(g * (x + b)) - std.math.tanh(g * b)) / g;
    }

    fn saturate(self: *TapeSaturator, x: f32) f32 {
        // Pre-emphasis shelf.
        self.pre_lp = flush(self.pre_lp + (x - self.pre_lp) * self.emphasis_coef);
        const e = emphasis * self.drive;
        const pre = x + e * (x - self.pre_lp);
        // 2x oversampled nonlinearity: zero-stuff (×2 gain), filter, clip,
        // filter, keep every other sample.
        const u_0 = self.up.tick(2.0 * pre);
        const u_1 = self.up.tick(0.0);
        const s0 = self.curve(u_0);
        const s1 = self.curve(u_1);
        const d = self.down.tick(s0);
        _ = self.down.tick(s1);
        // De-emphasis (inverse shelf) and HF rolloff.
        self.de_lp = flush(self.de_lp + (d - self.de_lp) * self.emphasis_coef);
        const de = self.de_lp + (d - self.de_lp) / (1.0 + e);
        self.rolloff = flush(self.rolloff + (de - self.rolloff) * self.rolloff_coef);
        // Auto-gain toward the input loudness.
        self.in_ms = flush(self.in_ms + (x * x - self.in_ms) * self.autogain_coef);
        self.out_ms = flush(self.out_ms + (self.rolloff * self.rolloff - self.out_ms) * self.autogain_coef);
        if (self.out_ms > 1e-10 and self.in_ms > 1e-10) {
            const want = std.math.clamp(@sqrt(self.in_ms / self.out_ms), 0.25, 4.0);
            self.makeup += (want - self.makeup) * self.autogain_coef;
        }
        return self.rolloff * self.makeup;
    }

    fn wowFlutter(self: *TapeSaturator, x: f32) f32 {
        const len = self.wow_buf.len;
        self.wow_buf[self.wow_pos] = x;
        const delay_s = wow_center_s +
            self.wow * (wow_depth_s * @sin(self.wow_phase) + flutter_depth_s * @sin(self.flutter_phase));
        self.wow_phase = @rem(self.wow_phase + tau * wow_hz / self.sample_rate, tau);
        self.flutter_phase = @rem(self.flutter_phase + tau * flutter_hz / self.sample_rate, tau);
        const delay = std.math.clamp(delay_s * self.sample_rate, 1.0, @as(f32, @floatFromInt(len - 2)));
        const read = @as(f32, @floatFromInt(self.wow_pos)) + @as(f32, @floatFromInt(len)) - delay;
        const i_0 = @floor(read);
        const frac = read - i_0;
        const idx: usize = @intFromFloat(i_0);
        const a = self.wow_buf[idx % len];
        const b = self.wow_buf[(idx + 1) % len];
        self.wow_pos = (self.wow_pos + 1) % len;
        return a + (b - a) * frac;
    }

    pub fn reset(self: *TapeSaturator) void {
        self.pre_lp = 0.0;
        self.de_lp = 0.0;
        self.rolloff = 0.0;
        self.up.clear();
        self.down.clear();
        self.in_ms = 0.0;
        self.out_ms = 0.0;
        self.makeup = 1.0;
        @memset(self.wow_buf, 0.0);
        self.wow_pos = 0;
        self.wow_phase = 0.0;
        self.flutter_phase = 0.0;
    }

    pub fn process(self: *TapeSaturator, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        const transparent = self.drive == 0.0 and self.wow == 0.0;
        for (input[0..n], output[0..n]) |x, *y| {
            if (transparent) {
                y.* = x;
                continue;
            }
            const dry = x;
            const s = if (std.math.isFinite(dry)) dry else 0.0;
            var wet = if (self.drive > 0.0) self.saturate(s) else s;
            if (self.wow > 0.0) {
                wet = self.wowFlutter(wet);
            }
            y.* = dry + self.mix * (wet - dry);
        }
    }
};

comptime {
    types.assertProcessor(TapeSaturator);
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

fn testSine(gpa: std.mem.Allocator, amp: f32, hz: f32, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*v, i| {
        v.* = amp * @sin(tau * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_sr)));
    }
    return out;
}

fn testRun(gpa: std.mem.Allocator, t: *TapeSaturator, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var off: usize = 0;
    while (off < input.len) : (off += block) {
        const end = @min(off + block, input.len);
        t.process(input[off..end], out[off..end]);
    }
    return out;
}

/// Goertzel magnitude of `hz` in `x`.
fn toneMag(x: []const f32, hz: f32) f32 {
    const w = tau * hz / @as(f32, @floatFromInt(test_sr));
    const coeff = 2.0 * @cos(w);
    var s1: f32 = 0.0;
    var s2: f32 = 0.0;
    for (x) |v| {
        const s0 = v + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return @sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2);
}

fn thd(x: []const f32) f32 {
    const f = toneMag(x, 1000.0);
    var h: f32 = 0.0;
    var k: u32 = 2;
    while (k <= 6) : (k += 1) {
        const m = toneMag(x, 1000.0 * @as(f32, @floatFromInt(k)));
        h += m * m;
    }
    return @sqrt(h) / f;
}

fn testRms(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |s| sum += s * s;
    return @sqrt(sum / @as(f32, @floatFromInt(x.len)));
}

test "zero_drive_is_bit_exact" {
    const gpa = testing.allocator;
    const input = try testSine(gpa, 0.5, 440.0, 10_000);
    defer gpa.free(input);
    var t = try TapeSaturator.init(gpa, test_sr);
    defer t.deinit(gpa);
    const out = try testRun(gpa, &t, input, 100);
    defer gpa.free(out);
    try testing.expectEqualSlices(f32, input, out);
}

test "zero_mix_is_bit_exact" {
    const gpa = testing.allocator;
    var t = try TapeSaturator.init(gpa, test_sr);
    defer t.deinit(gpa);
    t.setDrive(0.8);
    t.setWow(0.5);
    t.setMix(0.0);
    const input = try testSine(gpa, 0.5, 440.0, 10_000);
    defer gpa.free(input);
    const out = try testRun(gpa, &t, input, 100);
    defer gpa.free(out);
    try testing.expectEqualSlices(f32, input, out);
}

test "drive_adds_harmonics_and_keeps_level" {
    const gpa = testing.allocator;
    const n: usize = test_sr * 2;
    const input = try testSine(gpa, 0.3, 1000.0, n);
    defer gpa.free(input);
    var t_clean = try TapeSaturator.init(gpa, test_sr);
    defer t_clean.deinit(gpa);
    const clean = try testRun(gpa, &t_clean, input, 512);
    defer gpa.free(clean);
    var t = try TapeSaturator.init(gpa, test_sr);
    defer t.deinit(gpa);
    t.setDrive(0.7);
    const warm = try testRun(gpa, &t, input, 512);
    defer gpa.free(warm);
    const tail = n / 2;
    const thd_clean = thd(clean[tail..]);
    const thd_warm = thd(warm[tail..]);
    try testing.expect(thd_warm > thd_clean * 10.0 and thd_warm > 0.01);
    const db = 20.0 * std.math.log10(testRms(warm[tail..]) / testRms(input[tail..]));
    try testing.expect(@abs(db) < 2.0);
}

fn makeBlockTape(gpa: std.mem.Allocator) !TapeSaturator {
    var t = try TapeSaturator.init(gpa, test_sr);
    t.setDrive(0.6);
    t.setWow(0.4);
    t.setMix(0.8);
    return t;
}

test "block_sizes_match" {
    const gpa = testing.allocator;
    const input = try testSine(gpa, 0.6, 523.0, 20_000);
    defer gpa.free(input);
    var t_ref = try makeBlockTape(gpa);
    defer t_ref.deinit(gpa);
    const reference = try testRun(gpa, &t_ref, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var t = try makeBlockTape(gpa);
        defer t.deinit(gpa);
        const out = try testRun(gpa, &t, input, block);
        defer gpa.free(out);
        try testing.expectEqualSlices(f32, reference, out);
    }
}

test "silence_after_burst_stays_clean" {
    const gpa = testing.allocator;
    var t = try TapeSaturator.init(gpa, test_sr);
    defer t.deinit(gpa);
    t.setDrive(1.0);
    t.setWow(1.0);
    const burst_len: usize = 10_000;
    const input = try gpa.alloc(f32, burst_len + test_sr * 10);
    defer gpa.free(input);
    const burst = try testSine(gpa, 0.9, 300.0, burst_len);
    defer gpa.free(burst);
    @memcpy(input[0..burst_len], burst);
    @memset(input[burst_len..], 0.0);
    const out = try testRun(gpa, &t, input, 512);
    defer gpa.free(out);
    for (out) |s| {
        try testing.expect(std.math.isFinite(s) and (s == 0.0 or @abs(s) >= std.math.floatMin(f32)));
    }
}

test "bench_cpu" {
    // Rust marks this #[ignore] (benchmark, prints timing); not run here.
    return error.SkipZigTest;
}
