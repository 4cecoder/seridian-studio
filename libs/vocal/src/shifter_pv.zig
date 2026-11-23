// Translated to Zig from pitchpure/crates/pitchpure_engine/src/shifter_pv.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Streaming phase-vocoder pitch shifter (bin-shifting PV, std only).
//!
//! Classic frequency-domain pitch shift: every `hop` samples the last
//! `fft_size` inputs are windowed and analysed; each bin's true frequency
//! comes from its phase advance since the previous frame; each spectral
//! peak's lobe is moved rigidly to the bin nearest `peak*ratio`, its phase
//! re-accumulated from the scaled true frequency (identity phase locking
//! keeps the lobe coherent), and the frame is resynthesised with weighted
//! overlap-add. Time is never stretched, so there is no resampling stage and
//! no block-boundary discontinuity.
//!
//! * Realtime-safe: every buffer is allocated in `PvShifter.init`; the FFT
//!   runs in place over preallocated scratch. `process` never allocates.
//! * Honest latency: output is the input delayed by exactly `fft_size`
//!   samples (bit-for-bit modulo float rounding at ratio `1.0`, where the
//!   analysis phases are reused unmodified).
//! * Level: OLA is normalised by the exact summed squared window, and
//!   shifted bins accumulate magnitude, so level holds within ~1 dB.
//!
//! Seridian: the Rust panics on an invalid `fft_size`/`hop` and on block
//! length mismatch; `init` returns `error.InvalidFftSize`/`error.InvalidHop`
//! and `processChecked` returns `error.LengthMismatch`.

const std = @import("std");
const types = @import("types.zig");
const Fft = @import("fft.zig").Fft;

const pi = std.math.pi;
const unity_tol: f32 = 1e-6;

pub const InitError = error{ InvalidFftSize, InvalidHop } || std.mem.Allocator.Error;

/// Phase-vocoder pitch shifter.
pub const PvShifter = struct {
    sample_rate_: u32,
    fft_size: usize,
    hop: usize,
    ratio_: f32,
    fft: Fft,
    /// Backing storage for every `f64` buffer below (one allocation).
    f64_store: []f64,
    /// Backing storage for both `f32` FIFOs (one allocation).
    f32_store: []f32,
    /// Periodic Hann (analysis and synthesis).
    window: []f64,
    /// Inverse of the summed squared window over one hop period.
    norm: f64,
    in_fifo: []f32,
    out_fifo: []f32,
    accum: []f64,
    rover: usize,
    last_phase: []f64,
    sum_phase: []f64,
    ana_mag: []f64,
    ana_freq: []f64,
    ana_phase: []f64,
    acc_im: []f64,
    acc_re: []f64,
    re: []f64,
    im: []f64,

    /// Create a shifter. `fft_size` must be a power of two >= 64 and `hop`
    /// must divide it with at least 4x overlap for clean output.
    ///
    /// Returns `error.InvalidFftSize` on a non-power-of-two or too small
    /// `fft_size`, `error.InvalidHop` for a `hop` outside `1..=fft_size`.
    /// Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, fft_size: usize, hop: usize) InitError!PvShifter {
        if (!(fft_size >= 64 and std.math.isPowerOfTwo(fft_size))) return error.InvalidFftSize;
        if (!(hop > 0 and hop <= fft_size)) return error.InvalidHop;
        const bins = fft_size / 2 + 1;
        const fft = Fft.init(fft_size) catch return error.InvalidFftSize;

        // window n, accum 2n, re n, im n, seven per-bin arrays.
        const f64_len = 5 * fft_size + 7 * bins;
        const f64_store = try gpa.alloc(f64, f64_len);
        errdefer gpa.free(f64_store);
        @memset(f64_store, 0.0);
        const f32_store = try gpa.alloc(f32, 2 * fft_size);
        errdefer gpa.free(f32_store);
        @memset(f32_store, 0.0);

        var off: usize = 0;
        const window = carve(f64_store, &off, fft_size);
        const accum = carve(f64_store, &off, 2 * fft_size);
        const re = carve(f64_store, &off, fft_size);
        const im = carve(f64_store, &off, fft_size);
        const last_phase = carve(f64_store, &off, bins);
        const sum_phase = carve(f64_store, &off, bins);
        const ana_mag = carve(f64_store, &off, bins);
        const ana_freq = carve(f64_store, &off, bins);
        const ana_phase = carve(f64_store, &off, bins);
        const acc_im = carve(f64_store, &off, bins);
        const acc_re = carve(f64_store, &off, bins);
        std.debug.assert(off == f64_len);

        const n_f: f64 = @floatFromInt(fft_size);
        for (window, 0..) |*w, i| {
            const i_f: f64 = @floatFromInt(i);
            w.* = 0.5 - 0.5 * @cos(2.0 * pi * i_f / n_f);
        }
        // Sum of w^2 over all frames covering one output sample; constant for
        // a periodic Hann when hop divides fft_size.
        var wsum: f64 = 0.0;
        var i: usize = 0;
        while (i < fft_size) : (i += hop) wsum += window[i] * window[i];

        return .{
            .sample_rate_ = sample_rate,
            .fft_size = fft_size,
            .hop = hop,
            .ratio_ = 1.0,
            .fft = fft,
            .f64_store = f64_store,
            .f32_store = f32_store,
            .window = window,
            .norm = if (wsum > 0.0) 1.0 / wsum else 0.0,
            .in_fifo = f32_store[0..fft_size],
            .out_fifo = f32_store[fft_size .. 2 * fft_size],
            .accum = accum,
            .rover = fft_size - hop,
            .last_phase = last_phase,
            .sum_phase = sum_phase,
            .ana_mag = ana_mag,
            .ana_freq = ana_freq,
            .ana_phase = ana_phase,
            .acc_im = acc_im,
            .acc_re = acc_re,
            .re = re,
            .im = im,
        };
    }

    fn carve(store: []f64, off: *usize, len: usize) []f64 {
        const s = store[off.* .. off.* + len];
        off.* += len;
        return s;
    }

    /// Free the buffers allocated by `init`.
    pub fn deinit(self: *PvShifter, gpa: std.mem.Allocator) void {
        gpa.free(self.f32_store);
        gpa.free(self.f64_store);
        self.* = undefined;
    }

    /// Shift ratio (1.0 = identity). Clamped to 0.25..=4.0; NaN/non-positive ignored.
    pub fn setRatio(self: *PvShifter, r: f32) void {
        if (std.math.isFinite(r) and r > 0.0) self.ratio_ = std.math.clamp(r, 0.25, 4.0);
    }

    /// Current ratio.
    pub fn ratio(self: *const PvShifter) f32 {
        return self.ratio_;
    }

    /// Sample rate in Hz.
    pub fn sampleRate(self: *const PvShifter) u32 {
        return self.sample_rate_;
    }

    /// Analyse the current input frame, shift, resynthesise one hop.
    fn processFrame(self: *PvShifter) void {
        const n = self.fft_size;
        const bins = n / 2 + 1;
        const hop: f64 = @floatFromInt(self.hop);
        const osamp = @as(f64, @floatFromInt(n)) / hop;
        const expected = 2.0 * pi / osamp;
        for (0..n) |i| {
            self.re[i] = @as(f64, self.in_fifo[i]) * self.window[i];
            self.im[i] = 0.0;
        }
        // re/im were allocated with exactly fft_size elements in init.
        self.fft.transformInPlace(self.re, self.im, false) catch unreachable;

        for (0..bins) |k| {
            const r = self.re[k];
            const im = self.im[k];
            const k_f: f64 = @floatFromInt(k);
            const mag = @sqrt(r * r + im * im);
            const phase = std.math.atan2(im, r);
            var delta = phase - self.last_phase[k] - k_f * expected;
            self.last_phase[k] = phase;
            delta -= 2.0 * pi * @round(delta / (2.0 * pi));
            self.ana_mag[k] = mag;
            self.ana_phase[k] = phase;
            // True frequency in (fractional) bins.
            self.ana_freq[k] = k_f + delta * osamp / (2.0 * pi);
        }

        const unity = @abs(self.ratio_ - 1.0) <= unity_tol;
        if (unity) {
            // Exact reconstruction: reuse analysis phases and keep the
            // synthesis accumulator in step for a click-free switch later.
            for (0..bins) |k| {
                self.re[k] = self.ana_mag[k] * @cos(self.ana_phase[k]);
                self.im[k] = self.ana_mag[k] * @sin(self.ana_phase[k]);
                self.sum_phase[k] = self.ana_phase[k];
            }
        } else {
            const ratio_f: f64 = self.ratio_;
            @memset(self.acc_im, 0.0);
            @memset(self.acc_re, 0.0);
            // Identity phase locking (Laroche-Dolson): each spectral peak's
            // target bin accumulates phase from the peak's true frequency;
            // every bin in that peak's region keeps its analysed phase
            // offset from the peak, so partials stay coherent.
            var region_start: usize = 0;
            var k: usize = 0;
            while (k < bins) {
                // Find the next peak at or after k.
                var peak = k;
                while (peak + 1 < bins and self.ana_mag[peak + 1] >= self.ana_mag[peak]) peak += 1;
                // Region ends at the valley after the peak.
                var end = peak;
                while (end + 1 < bins and self.ana_mag[end + 1] < self.ana_mag[end]) end += 1;
                const peak_f: f64 = @floatFromInt(peak);
                // peak * ratio is finite and non-negative (ratio in 0.25..=4).
                const tp: usize = @intFromFloat(@round(peak_f * ratio_f));
                if (tp < bins) {
                    const tp_f: f64 = @floatFromInt(tp);
                    const advance = (self.ana_freq[peak] * ratio_f - tp_f) * 2.0 * pi / osamp + tp_f * expected;
                    self.sum_phase[tp] = @rem(self.sum_phase[tp] + advance, 2.0 * pi);
                    const base = self.sum_phase[tp] - self.ana_phase[peak];
                    // Move the whole lobe rigidly: window lobes have a fixed
                    // width in bins, so scaling bin indices would tear them.
                    const shift = @as(i64, @intCast(tp)) - @as(i64, @intCast(peak));
                    for (region_start..end + 1) |b| {
                        const t = @as(i64, @intCast(b)) + shift;
                        if (t >= 0 and @as(usize, @intCast(t)) < bins) {
                            const tu: usize = @intCast(t);
                            const re = self.ana_mag[b] * @cos(base + self.ana_phase[b]);
                            const im = self.ana_mag[b] * @sin(base + self.ana_phase[b]);
                            self.acc_re[tu] += re;
                            self.acc_im[tu] += im;
                        }
                    }
                }
                region_start = end + 1;
                k = end + 1;
            }
            for (0..bins) |t| {
                self.re[t] = self.acc_re[t];
                self.im[t] = self.acc_im[t];
            }
        }
        // Conjugate-symmetric upper half so the inverse is real.
        for (bins..n) |k| {
            self.re[k] = self.re[n - k];
            self.im[k] = -self.im[n - k];
        }
        self.im[0] = 0.0;
        self.im[n / 2] = 0.0;
        self.fft.transformInPlace(self.re, self.im, true) catch unreachable;

        for (0..n) |i| self.accum[i] += self.window[i] * self.re[i] * self.norm;
        const step = self.hop;
        for (0..step) |i| self.out_fifo[i] = @floatCast(self.accum[i]);
        std.mem.copyForwards(f64, self.accum[0 .. self.accum.len - step], self.accum[step..]);
        @memset(self.accum[self.accum.len - step ..], 0.0);
        std.mem.copyForwards(f32, self.in_fifo[0 .. n - step], self.in_fifo[step..]);
    }

    /// Clear all audio state. The ratio is kept.
    pub fn reset(self: *PvShifter) void {
        @memset(self.in_fifo, 0.0);
        @memset(self.out_fifo, 0.0);
        @memset(self.accum, 0.0);
        @memset(self.last_phase, 0.0);
        @memset(self.sum_phase, 0.0);
        self.rover = self.fft_size - self.hop;
    }

    /// Shift one block of mono audio (any length). Returns
    /// `error.LengthMismatch` if `input.len != output.len`.
    pub fn processChecked(self: *PvShifter, input: []const f32, output: []f32) error{LengthMismatch}!void {
        if (input.len != output.len) return error.LengthMismatch;
        const latency = self.fft_size - self.hop;
        for (output, input) |*o, x| {
            // Net delay is a full frame: `latency` in the FIFO plus the hop
            // that is emitted after each frame completes.
            self.in_fifo[self.rover] = x;
            o.* = self.out_fifo[self.rover - latency];
            self.rover += 1;
            if (self.rover >= self.fft_size) {
                self.rover = latency;
                self.processFrame();
            }
        }
    }

    /// Shift one block of mono audio (any length).
    ///
    /// Panics if `input.len != output.len`, like the Rust `assert_eq!`.
    pub fn process(self: *PvShifter, input: []const f32, output: []f32) void {
        self.processChecked(input, output) catch @panic("equal lengths required");
    }

    /// Exactly `fft_size` samples (measured: a unit impulse comes out
    /// `fft_size` samples later at unit gain).
    pub fn latencySamples(self: *const PvShifter) usize {
        return self.fft_size;
    }
};

comptime {
    types.assertProcessor(PvShifter);
}

const testing = std.testing;
const ts = @import("shifter_sola.zig").test_support;
const test_rate: u32 = 48_000;

/// Caller frees the result.
fn run(gpa: std.mem.Allocator, pv: *PvShifter, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var start: usize = 0;
    while (start < input.len) : (start += block) {
        const end = @min(start + block, input.len);
        pv.process(input[start..end], out[start..end]);
    }
    return out;
}

test "identity_is_delay_by_latency" {
    const gpa = testing.allocator;
    var pv = try PvShifter.init(gpa, test_rate, 2048, 512);
    defer pv.deinit(gpa);
    const input = try ts.voice(gpa, 220.0, test_rate, 20_000);
    defer gpa.free(input);
    const out = try run(gpa, &pv, input, 333);
    defer gpa.free(out);
    const lat = pv.latencySamples();
    try testing.expectEqual(@as(usize, 2048), lat);
    var err: f32 = 0.0;
    for (4096..input.len) |i| err = @max(err, @abs(out[i] - input[i - lat]));
    try testing.expect(err < 1e-4);
}

test "shifts_pitch_accurately" {
    const gpa = testing.allocator;
    const f0: f32 = 220.0;
    const input = try ts.voice(gpa, f0, test_rate, test_rate * 2);
    defer gpa.free(input);
    for ([_]f32{ -700.0, -100.0, -30.0, 30.0, 100.0, 700.0, 1200.0 }) |cents_shift| {
        const r = std.math.pow(f32, 2.0, cents_shift / 1200.0);
        var pv = try PvShifter.init(gpa, test_rate, 2048, 512);
        defer pv.deinit(gpa);
        pv.setRatio(r);
        const out = try run(gpa, &pv, input, 1024);
        defer gpa.free(out);
        const got = try ts.measureF0(gpa, out[test_rate / 2 ..], test_rate, f0 * r);
        const err = ts.cents(got, f0 * r);
        if (!(@abs(err) <= 5.0)) {
            std.debug.print("shift {d} c: {d:.2} Hz, error {d:.2} c\n", .{ cents_shift, got, err });
            return error.TestUnexpectedResult;
        }
    }
}

test "level_is_preserved_up_and_down" {
    const gpa = testing.allocator;
    const input = try ts.voice(gpa, 196.0, test_rate, test_rate * 2);
    defer gpa.free(input);
    const reference = types.rms(input[test_rate / 2 ..]);
    for ([_]f32{ 0.75, 1.06, 1.5, 2.0 }) |r| {
        var pv = try PvShifter.init(gpa, test_rate, 2048, 512);
        defer pv.deinit(gpa);
        pv.setRatio(r);
        const out = try run(gpa, &pv, input, 1024);
        defer gpa.free(out);
        const db = 20.0 * std.math.log10(types.rms(out[test_rate / 2 ..]) / reference);
        if (!(@abs(db) <= 1.0)) {
            std.debug.print("ratio {d}: level {d:.2} dB\n", .{ r, db });
            return error.TestUnexpectedResult;
        }
    }
}

test "any_block_partition_is_identical" {
    const gpa = testing.allocator;
    const input = try ts.voice(gpa, 180.0, test_rate, 20_000);
    defer gpa.free(input);
    var reference_pv = try PvShifter.init(gpa, test_rate, 1024, 256);
    defer reference_pv.deinit(gpa);
    reference_pv.setRatio(1.3);
    const reference = try run(gpa, &reference_pv, input, input.len);
    defer gpa.free(reference);
    for ([_]usize{ 1, 37, 512 }) |block| {
        var pv = try PvShifter.init(gpa, test_rate, 1024, 256);
        defer pv.deinit(gpa);
        pv.setRatio(1.3);
        const out = try run(gpa, &pv, input, block);
        defer gpa.free(out);
        try testing.expectEqualSlices(f32, reference, out);
    }
}

test "reset_is_idempotent" {
    const gpa = testing.allocator;
    var pv = try PvShifter.init(gpa, 44_100, 1024, 256);
    defer pv.deinit(gpa);
    pv.setRatio(1.2);
    const input = try ts.voice(gpa, 220.0, 44_100, 4096);
    defer gpa.free(input);
    const a = try run(gpa, &pv, input, 512);
    defer gpa.free(a);
    pv.reset();
    const b = try run(gpa, &pv, input, 512);
    defer gpa.free(b);
    try testing.expectEqualSlices(f32, a, b);
}

test "ratio_clamps" {
    const gpa = testing.allocator;
    var pv = try PvShifter.init(gpa, 44_100, 1024, 256);
    defer pv.deinit(gpa);
    pv.setRatio(99.0);
    try testing.expectEqual(@as(f32, 4.0), pv.ratio());
    pv.setRatio(std.math.nan(f32));
    try testing.expectEqual(@as(f32, 4.0), pv.ratio());
}

test "init_rejects_bad_sizes" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidFftSize, PvShifter.init(gpa, 48_000, 1000, 250));
    try testing.expectError(error.InvalidFftSize, PvShifter.init(gpa, 48_000, 32, 8));
    try testing.expectError(error.InvalidHop, PvShifter.init(gpa, 48_000, 1024, 0));
    try testing.expectError(error.InvalidHop, PvShifter.init(gpa, 48_000, 1024, 2048));
}
