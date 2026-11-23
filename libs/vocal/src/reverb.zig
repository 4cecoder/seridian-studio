// Translated to Zig from pitchpure/crates/pitchpure_engine/src/reverb.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Lush algorithmic vocal reverb: pre-delay → input diffusion → modulated
//! 8-line feedback delay network.
//!
//! * Pre-delay `0..=200 ms` keeps the dry consonants clear of the tail.
//! * Input diffusion: four Schroeder allpasses (mutually prime lengths)
//!   smear the transient into a dense cloud before it enters the tank.
//! * Tank: 8 delay lines (≈30–75 ms, scaled by `size`) mixed through a
//!   normalised Hadamard matrix (fast Walsh–Hadamard transform), which is
//!   lossless, so decay comes only from the per-line gains
//!   `g = 10^(−3·len / (fs·RT60))` (Jot's design rule) and the per-line
//!   one-pole damping lowpass. Each line's read point is swept by its own
//!   slow sine LFO (0.13–0.9 Hz, a few samples deep): that breaks up
//!   metallic modes and gives the chorused, lush character.
//! * Outputs: even lines feed the left channel and odd lines the right,
//!   with alternating signs, giving two decorrelated tails.
//! * Wet low cut (one-pole highpass, default 200 Hz) keeps mud off the voice;
//!   sidechain ducking (as in the delay) lets the tail swell between lines.
//!
//! Mono `process` returns `dry + mix × duck × (L + R)/2`; `mix == 0` is a
//! bit-exact passthrough. All state is per sample, so block size never
//! changes the result. Allocation only in `VocalReverb.init` (one backing
//! buffer shared by every delay line).

const std = @import("std");
const types = @import("types.zig");

const tau: f32 = 2.0 * std.math.pi;
const ln_10: f32 = std.math.ln10;

const lines_n: usize = 8;
/// Tank line lengths in ms at `size = 1` (roughly prime ratios).
const line_ms = [lines_n]f32{ 29.7, 37.1, 41.1, 43.7, 53.0, 59.3, 67.1, 73.3 };
/// LFO rates (Hz) and depth (ms) for the tank lines.
const lfo_hz = [lines_n]f32{ 0.13, 0.21, 0.29, 0.37, 0.47, 0.59, 0.71, 0.89 };
const lfo_depth_ms: f32 = 0.25;
/// Input diffusers: lengths in ms and coefficient.
const diffuser_ms = [4]f32{ 4.77, 3.59, 12.7, 9.3 };
const diffusion: f32 = 0.7;
/// Size range: line-length scale at `size = 0` and `size = 1`.
const size_min: f32 = 0.35;
const size_max: f32 = 1.0;
const max_predelay_s: f32 = 0.2;
/// Size changes glide with this time constant (avoids clicks).
const size_glide_s: f32 = 0.1;
const duck_attack_s: f32 = 0.010;
const duck_release_s: f32 = 0.300;
const duck_full_level: f32 = 0.1;
const duck_max_db: f32 = 18.0;
/// Line gains are refreshed every this many samples (counted across
/// calls, so block size still never changes the output).
const gain_update: u32 = 16;

/// Delay line over a slice borrowed from `VocalReverb.storage`.
const Line = struct {
    buf: []f32,
    pos: usize = 0,

    fn write(self: *Line, x: f32) void {
        self.buf[self.pos] = x;
        self.pos = (self.pos + 1) % self.buf.len;
    }

    /// Value written `delay` samples ago (fractional, linear interp);
    /// call before `write` for this sample.
    fn read(self: *const Line, delay_in: f32) f32 {
        const len = self.buf.len;
        const delay = std.math.clamp(delay_in, 1.0, @as(f32, @floatFromInt(len - 2)));
        const r = @as(f32, @floatFromInt(self.pos)) + @as(f32, @floatFromInt(len)) - delay;
        const i_0 = @floor(r);
        const frac = r - i_0;
        const idx: usize = @intFromFloat(i_0);
        const a = self.buf[idx % len];
        const b = self.buf[(idx + 1) % len];
        return a + (b - a) * frac;
    }

    fn clear(self: *Line) void {
        @memset(self.buf, 0.0);
        self.pos = 0;
    }
};

/// Line length as in Rust `Line::new`: at least 4 samples.
fn lineLen(len: usize) usize {
    return @max(len, 4);
}

/// Stereo wet pair returned by `tick`.
const Wet = struct { l: f32, r: f32 };

/// Lush modulated FDN reverb for vocals. Owns `storage` (all line
/// buffers); free it with `deinit`.
pub const VocalReverb = struct {
    sample_rate: f32,
    storage: []f32,
    predelay: Line,
    predelay_samples: f32,
    diffusers: [4]Line,
    diffuser_len: [4]f32,
    lines: [lines_n]Line,
    size: f32,
    size_now: f32,
    size_coef: f32,
    decay_s: f32,
    damping: f32,
    mix: f32,
    duck: f32,
    low_cut_coef: f32,
    damp: [lines_n]f32,
    /// Quadrature LFOs (cos, sin) advanced by rotation: no trig per sample.
    lfo: [lines_n][2]f32,
    lfo_rot: [lines_n][2]f32,
    gains: [lines_n]f32,
    counter: u32,
    hp_l: f32,
    hp_r: f32,
    env: f32,
    attack_coef: f32,
    release_coef: f32,

    /// Reverb at `sample_rate`: 30 ms pre-delay, 2.2 s decay, size 0.7,
    /// damping 0.4, 20% mix, 200 Hz wet low cut, no ducking.
    pub fn init(gpa: std.mem.Allocator, sample_rate: types.SampleRateHz) !VocalReverb {
        const sr: f32 = @floatFromInt(@max(sample_rate, 1));
        const lfo_extra = msToSamples(lfo_depth_ms, sr) + 4;
        var diffuser_len: [4]f32 = undefined;
        for (&diffuser_len, diffuser_ms) |*d, m| d.* = m * 0.001 * sr;
        var lfo_rot: [lines_n][2]f32 = undefined;
        for (&lfo_rot, lfo_hz) |*p, hz| {
            const w = tau * hz / sr;
            p.* = .{ @cos(w), @sin(w) };
        }

        // Lengths of every line, then one backing allocation.
        const predelay_len = lineLen(@as(usize, @intFromFloat(max_predelay_s * sr)) + 4);
        var diff_lens: [4]usize = undefined;
        for (&diff_lens, diffuser_ms) |*l, m| l.* = lineLen(msToSamples(m, sr) + 4);
        var tank_lens: [lines_n]usize = undefined;
        for (&tank_lens, line_ms) |*l, m| l.* = lineLen(msToSamples(m * size_max, sr) + lfo_extra + 4);
        var total: usize = predelay_len;
        for (diff_lens) |l| total += l;
        for (tank_lens) |l| total += l;

        const storage = try gpa.alloc(f32, total);
        @memset(storage, 0.0);
        var off: usize = 0;
        const predelay: Line = .{ .buf = storage[off .. off + predelay_len] };
        off += predelay_len;
        var diffusers: [4]Line = undefined;
        for (&diffusers, diff_lens) |*d, l| {
            d.* = .{ .buf = storage[off .. off + l] };
            off += l;
        }
        var lines: [lines_n]Line = undefined;
        for (&lines, tank_lens) |*d, l| {
            d.* = .{ .buf = storage[off .. off + l] };
            off += l;
        }

        var r: VocalReverb = .{
            .sample_rate = sr,
            .storage = storage,
            .predelay = predelay,
            .predelay_samples = 0.0,
            .diffusers = diffusers,
            .diffuser_len = diffuser_len,
            .lines = lines,
            .size = 0.7,
            .size_now = 0.7,
            .size_coef = 1.0 - @exp(-1.0 / (size_glide_s * sr)),
            .decay_s = 2.2,
            .damping = 0.4,
            .mix = 0.2,
            .duck = 0.0,
            .low_cut_coef = 0.0,
            .damp = @splat(0.0),
            .lfo = initialLfo(),
            .lfo_rot = lfo_rot,
            .gains = @splat(0.0),
            .counter = 0,
            .hp_l = 0.0,
            .hp_r = 0.0,
            .env = 0.0,
            .attack_coef = 1.0 - @exp(-1.0 / (duck_attack_s * sr)),
            .release_coef = 1.0 - @exp(-1.0 / (duck_release_s * sr)),
        };
        r.setPredelayMs(30.0);
        r.setLowCutHz(200.0);
        return r;
    }

    pub fn deinit(self: *VocalReverb, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
        self.* = undefined;
    }

    /// Pre-delay `0..=200` ms.
    pub fn setPredelayMs(self: *VocalReverb, ms_in: f32) void {
        const ms = std.math.clamp(finiteOr(ms_in, 30.0), 0.0, max_predelay_s * 1000.0);
        self.predelay_samples = ms * 0.001 * self.sample_rate;
    }

    /// RT60 decay time `0.3..=8` s.
    pub fn setDecayS(self: *VocalReverb, s: f32) void {
        self.decay_s = std.math.clamp(finiteOr(s, 2.2), 0.3, 8.0);
    }

    /// Room size `0..=1` (scales the tank lines).
    pub fn setSize(self: *VocalReverb, size: f32) void {
        self.size = std.math.clamp(finiteOr(size, 0.7), 0.0, 1.0);
    }

    /// High-frequency damping `0..=1` (darker tail when higher).
    pub fn setDamping(self: *VocalReverb, d: f32) void {
        self.damping = std.math.clamp(finiteOr(d, 0.4), 0.0, 1.0);
    }

    /// Wet amount `0..=1`.
    pub fn setMix(self: *VocalReverb, mix: f32) void {
        self.mix = std.math.clamp(finiteOr(mix, 0.2), 0.0, 1.0);
    }

    /// Highpass on the wet signal, `20..=1000` Hz.
    pub fn setLowCutHz(self: *VocalReverb, hz_in: f32) void {
        const hz = std.math.clamp(finiteOr(hz_in, 200.0), 20.0, 1000.0);
        self.low_cut_coef = 1.0 - @exp(-tau * hz / self.sample_rate);
    }

    /// Sidechain ducking `0..=1`.
    pub fn setDuck(self: *VocalReverb, duck: f32) void {
        self.duck = std.math.clamp(finiteOr(duck, 0.0), 0.0, 1.0);
    }

    pub fn getMix(self: *const VocalReverb) f32 {
        return self.mix;
    }

    pub fn getDecayS(self: *const VocalReverb) f32 {
        return self.decay_s;
    }

    /// One sample: returns the wet left/right pair after low cut and duck.
    fn tick(self: *VocalReverb, x: f32) Wet {
        // Pre-delay.
        const pre = if (self.predelay_samples >= 1.0) blk: {
            const v = self.predelay.read(self.predelay_samples);
            self.predelay.write(x);
            break :blk v;
        } else blk: {
            self.predelay.write(x);
            break :blk x;
        };
        // Input diffusion (Schroeder allpasses).
        var d = pre;
        for (&self.diffusers, self.diffuser_len) |*ap, len| {
            const delayed = ap.read(len);
            const v = d + diffusion * delayed;
            ap.write(flush(v));
            d = delayed - diffusion * v;
        }
        // Tank.
        self.size_now += (self.size - self.size_now) * self.size_coef;
        const scale = size_min + (size_max - size_min) * self.size_now;
        const depth = lfo_depth_ms * 0.001 * self.sample_rate;
        const damp_coef = 0.05 + 0.85 * self.damping;
        if (self.counter % gain_update == 0) {
            // Jot: g = 10^(-3·len/(fs·RT60)), from the mean line length.
            const k = -3.0 * ln_10 / (self.sample_rate * self.decay_s);
            for (0..lines_n) |i| {
                const len = line_ms[i] * 0.001 * self.sample_rate * scale + depth;
                self.gains[i] = @exp(k * len);
            }
        }
        self.counter +%= 1;
        // Renormalise the rotating LFOs now and then against drift.
        const renorm = self.counter % 4096 == 0;
        var v: [lines_n]f32 = @splat(0.0);
        for (0..lines_n) |i| {
            const len = line_ms[i] * 0.001 * self.sample_rate * scale;
            const c = self.lfo[i][0];
            const s = self.lfo[i][1];
            const rc = self.lfo_rot[i][0];
            const rs = self.lfo_rot[i][1];
            var nc = c * rc - s * rs;
            var ns = s * rc + c * rs;
            if (renorm) {
                const m = @sqrt(nc * nc + ns * ns);
                nc /= m;
                ns /= m;
            }
            self.lfo[i] = .{ nc, ns };
            const delay = len + depth * (1.0 + ns);
            const raw = self.lines[i].read(delay) * self.gains[i];
            // One-pole lowpass damping inside the loop.
            self.damp[i] = flush(raw + (self.damp[i] - raw) * damp_coef * 0.9);
            v[i] = self.damp[i];
        }
        var l: f32 = 0.0;
        var r: f32 = 0.0;
        for (v, 0..) |s, i| {
            const sign: f32 = if ((i / 2) % 2 == 0) 1.0 else -1.0;
            if (i % 2 == 0) {
                l += sign * s;
            } else {
                r += sign * s;
            }
        }
        hadamard8(&v);
        for (&self.lines, 0..) |*line, i| {
            const sign: f32 = if (i % 2 == 0) 1.0 else -1.0;
            line.write(flush(v[i] + sign * d * 0.5));
        }
        l *= 0.5;
        r *= 0.5;
        // Wet low cut.
        self.hp_l = flush(self.hp_l + (l - self.hp_l) * self.low_cut_coef);
        self.hp_r = flush(self.hp_r + (r - self.hp_r) * self.low_cut_coef);
        var wl = l - self.hp_l;
        var wr = r - self.hp_r;
        // Duck under the dry voice.
        const level = @abs(x);
        const c = if (level > self.env) self.attack_coef else self.release_coef;
        self.env = flush(self.env + (level - self.env) * c);
        if (self.duck > 0.0) {
            const amount = @min(self.env / duck_full_level, 1.0);
            const gain = @exp(-duck_max_db * self.duck * amount * ln_10 / 20.0);
            wl *= gain;
            wr *= gain;
        }
        return .{ .l = wl, .r = wr };
    }

    /// Mono in, stereo out: `out = dry + mix × wet` per side.
    pub fn processStereo(self: *VocalReverb, input: []const f32, left: []f32, right: []f32) void {
        const n = @min(@min(input.len, left.len), right.len);
        for (0..n) |i| {
            const dry = input[i];
            const s = if (std.math.isFinite(dry)) dry else 0.0;
            const w = self.tick(s);
            left[i] = dry + self.mix * w.l;
            right[i] = dry + self.mix * w.r;
        }
    }

    pub fn reset(self: *VocalReverb) void {
        self.predelay.clear();
        for (&self.diffusers) |*d| d.clear();
        for (&self.lines) |*l| l.clear();
        self.damp = @splat(0.0);
        self.hp_l = 0.0;
        self.hp_r = 0.0;
        self.env = 0.0;
        self.size_now = self.size;
        self.lfo = initialLfo();
        self.counter = 0;
    }

    pub fn process(self: *VocalReverb, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        for (input[0..n], output[0..n]) |x, *y| {
            const dry = x;
            const s = if (std.math.isFinite(dry)) dry else 0.0;
            const w = self.tick(s);
            y.* = dry + self.mix * 0.5 * (w.l + w.r);
        }
    }
};

comptime {
    types.assertProcessor(VocalReverb);
}

/// Rust closure `ms(m) = (m * 0.001 * sr) as usize`.
fn msToSamples(m: f32, sr: f32) usize {
    return @intFromFloat(m * 0.001 * sr);
}

/// LFOs start spread evenly around the circle.
fn initialLfo() [lines_n][2]f32 {
    var lfo: [lines_n][2]f32 = undefined;
    for (&lfo, 0..) |*p, i| {
        const a = @as(f32, @floatFromInt(i)) * tau / @as(f32, @floatFromInt(lines_n));
        p.* = .{ @cos(a), @sin(a) };
    }
    return lfo;
}

/// In-place normalised 8-point Walsh–Hadamard transform (orthonormal).
fn hadamard8(v: *[lines_n]f32) void {
    var h: usize = 1;
    while (h < lines_n) : (h *= 2) {
        var i: usize = 0;
        while (i < lines_n) : (i += h * 2) {
            for (i..i + h) |j| {
                const a = v[j];
                const b = v[j + h];
                v[j] = a + b;
                v[j + h] = a - b;
            }
        }
    }
    const norm = 1.0 / @sqrt(@as(f32, @floatFromInt(lines_n)));
    for (v) |*x| x.* *= norm;
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

fn testRun(gpa: std.mem.Allocator, r: *VocalReverb, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var off: usize = 0;
    while (off < input.len) : (off += block) {
        const end = @min(off + block, input.len);
        r.process(input[off..end], out[off..end]);
    }
    return out;
}

fn impulse(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const v = try gpa.alloc(f32, n);
    @memset(v, 0.0);
    v[0] = 1.0;
    return v;
}

/// RT60 from the Schroeder energy decay curve, T20 fit (−5 → −25 dB).
fn rt60(gpa: std.mem.Allocator, ir: []const f32) !f32 {
    const edc = try gpa.alloc(f64, ir.len);
    defer gpa.free(edc);
    var acc: f64 = 0.0;
    var i: usize = ir.len;
    while (i > 0) {
        i -= 1;
        acc += @as(f64, ir[i]) * @as(f64, ir[i]);
        edc[i] = acc;
    }
    const total = edc[0];
    var t5: ?usize = null;
    var t25: ?usize = null;
    for (edc, 0..) |e, k| {
        const db = 10.0 * std.math.log10(e / total);
        if (t5 == null and db <= -5.0) t5 = k;
        if (t25 == null and db <= -25.0) t25 = k;
    }
    return 3.0 * @as(f32, @floatFromInt(t25.? - t5.?)) / @as(f32, @floatFromInt(test_sr));
}

test "zero_mix_is_bit_exact" {
    const gpa = testing.allocator;
    var r = try VocalReverb.init(gpa, test_sr);
    defer r.deinit(gpa);
    r.setMix(0.0);
    const input = try gpa.alloc(f32, 20_000);
    defer gpa.free(input);
    for (input, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.02) * 0.5;
    const out = try testRun(gpa, &r, input, 256);
    defer gpa.free(out);
    try testing.expectEqualSlices(f32, input, out);
}

test "decay_time_matches_setting" {
    const gpa = testing.allocator;
    for ([_]f32{ 1.0, 2.5 }) |decay| {
        var r = try VocalReverb.init(gpa, test_sr);
        defer r.deinit(gpa);
        r.setMix(1.0);
        r.setDamping(0.0);
        r.setLowCutHz(20.0);
        r.setDecayS(decay);
        const imp = try impulse(gpa, test_sr * 6);
        defer gpa.free(imp);
        const ir = try testRun(gpa, &r, imp, 1024);
        defer gpa.free(ir);
        const wet = ir[1..];
        for (wet) |s| try testing.expect(std.math.isFinite(s));
        const measured = try rt60(gpa, wet);
        try testing.expect(@abs(measured / decay - 1.0) < 0.3);
    }
}

test "stereo_tails_are_decorrelated" {
    const gpa = testing.allocator;
    var r = try VocalReverb.init(gpa, test_sr);
    defer r.deinit(gpa);
    r.setMix(1.0);
    const input = try impulse(gpa, test_sr * 2);
    defer gpa.free(input);
    const l_buf = try gpa.alloc(f32, input.len);
    defer gpa.free(l_buf);
    const r_buf = try gpa.alloc(f32, input.len);
    defer gpa.free(r_buf);
    @memset(l_buf, 0.0);
    @memset(r_buf, 0.0);
    r.processStereo(input, l_buf, r_buf);
    const l = l_buf[2000..];
    const rr = r_buf[2000..];
    var dot: f64 = 0.0;
    for (l, rr) |a, b| dot += @as(f64, a) * @as(f64, b);
    var nl: f64 = 0.0;
    for (l) |a| nl += @as(f64, a) * @as(f64, a);
    var nr: f64 = 0.0;
    for (rr) |a| nr += @as(f64, a) * @as(f64, a);
    const corr = dot / (@sqrt(nl) * @sqrt(nr));
    try testing.expect(@abs(corr) < 0.5);
}

fn makeBlockReverb(gpa: std.mem.Allocator) !VocalReverb {
    var r = try VocalReverb.init(gpa, test_sr);
    r.setDuck(0.5);
    r.setMix(0.5);
    return r;
}

test "block_sizes_match" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(f32, 20_000);
    defer gpa.free(input);
    for (input, 0..) |*v, i| {
        v.* = if (i < 3000) @sin(@as(f32, @floatFromInt(i)) * 0.07) else 0.0;
    }
    var r_ref = try makeBlockReverb(gpa);
    defer r_ref.deinit(gpa);
    const reference = try testRun(gpa, &r_ref, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var r = try makeBlockReverb(gpa);
        defer r.deinit(gpa);
        const out = try testRun(gpa, &r, input, block);
        defer gpa.free(out);
        try testing.expectEqualSlices(f32, reference, out);
    }
}

test "silence_after_burst_stays_clean" {
    const gpa = testing.allocator;
    var r = try VocalReverb.init(gpa, test_sr);
    defer r.deinit(gpa);
    r.setDecayS(8.0);
    r.setMix(1.0);
    const burst_len: usize = 10_000;
    const input = try gpa.alloc(f32, burst_len + test_sr * 30);
    defer gpa.free(input);
    for (input[0..burst_len], 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05);
    @memset(input[burst_len..], 0.0);
    const out = try testRun(gpa, &r, input, 512);
    defer gpa.free(out);
    var peak: f32 = 0.0;
    for (out) |s| {
        try testing.expect(std.math.isFinite(s) and (s == 0.0 or @abs(s) >= std.math.floatMin(f32)));
        peak = @max(peak, @abs(s));
    }
    try testing.expect(peak < 4.0);
}

test "bench_cpu" {
    // Rust marks this #[ignore] (benchmark, prints timing); not run here.
    return error.SkipZigTest;
}
