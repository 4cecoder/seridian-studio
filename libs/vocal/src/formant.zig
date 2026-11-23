// Translated to Zig from pitchpure/crates/pitchpure_engine/src/formant.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Throat-length formant shifter: moves the spectral envelope, keeps the pitch.
//!
//! A "throat length" control shifts vocal-tract resonances (formants) without
//! changing the fundamental. Each hop takes a 2048-point Hann-windowed FFT,
//! separates a coarse spectral envelope with a cepstral-lite moving average
//! over log-magnitude, resamples that envelope by the shift ratio, reapplies
//! it to the original phases, then inverse-FFTs with weighted overlap-add.
//!
//! Envelope choice: short moving average (radius 8, window 17, about 365 Hz
//! at 44.1 kHz) over log-magnitude, exponentiated back to linear. Picked over
//! LPC order 12 because it is deterministic and needs only preallocated
//! scratch. The window is wide enough to smooth harmonic ripple into a coarse
//! envelope yet narrow enough that resampling still moves audible weight
//! between harmonics.
//!
//! Resampling convention: with `ratio = 2^(cents/1200)`, the shifted envelope
//! is `shifted[k] = env[k / ratio]` linearly interpolated with edge clamping.
//! That matches `resampler.linearResample` with `1/ratio` keeping the first
//! `N/2+1` bins (for `ratio >= 1`), with clamping standing in for the
//! crop/pad the stateless helper cannot do at a fixed length. It is done
//! inline here over preallocated buffers, so `process` never calls the
//! (allocating) resampler. A ratio above one moves formants up (shorter
//! throat); below one moves them down.
//!
//! Gain handling: `gain[k] = shifted[k] / (env[k] + eps)` clamped to
//! `0.5..=2.0` (about +/-6 dB) so valleys cannot blow up noise and pitch
//! tracking stays on the original harmonic lattice. Phases are untouched and
//! conjugate symmetry is restored before the inverse transform, so the output
//! stays real and periodic at the input fundamental.
//!
//! Realtime notes: every buffer is allocated in `FormantShifter.init`; the
//! internal radix-2 FFT uses precomputed bit-reversal and twiddle tables.
//! `process` and `reset` never allocate. A ratio within `1e-6` of one takes a
//! bit-transparent direct-copy fast path with zero delay. The analysis path
//! reports `2048 - 1024 = 1024` samples of latency.
//!
//! Seridian: the Rust panics on a block length mismatch; `processChecked`
//! returns `error.LengthMismatch` and `process` keeps the panic.

const std = @import("std");
const types = @import("types.zig");

const pi = std.math.pi;

/// FFT length: 2048 Hann-windowed samples per frame.
const fft_size: usize = 2048;
/// Hop between frames: 50 percent overlap.
const hop: usize = 1024;
/// Positive-frequency bins including DC and Nyquist (`2048/2 + 1`).
const half: usize = fft_size / 2 + 1;
/// Largest absolute shift in cents (one octave either way).
const max_cents: f32 = 1200.0;
/// Log-magnitude smoothing radius; window is `2*8+1 = 17` bins.
const smooth_radius: usize = 8;
/// Smoothing window length as float (`17.0`).
const smooth_len: f32 = 17.0;
/// Floor for magnitudes and envelope divisions.
const eps: f32 = 1e-7;
/// Ratios this close to one take the transparent copy fast path.
const unity_eps: f32 = 1e-6;
/// Minimum envelope gain (about -6 dB, keeps odd harmonics for YIN).
const gain_min: f32 = 0.5;
/// Maximum envelope gain (about +6 dB).
const gain_max: f32 = 2.0;
/// Overlap weight below which output is treated as uncovered.
const wsum_floor: f32 = 1e-6;

/// Throat-length formant shifter with same-length block processing.
///
/// Build once with `init`, pick a shift with `setShiftCents`, then call
/// `process` per block. All working storage is allocated in `init`, so
/// `process` and `reset` never allocate.
pub const FormantShifter = struct {
    sample_rate_: u32,
    cents: f32,
    ratio: f32,
    /// Backing storage for every `f32` buffer below (one allocation).
    store: []f32,
    window: []f32,
    in_buf: []f32,
    ola: []f32,
    wsum: []f32,
    fft_re: []f32,
    fft_im: []f32,
    bit_rev: []usize,
    tw_cos: []f32,
    tw_sin: []f32,
    logmag: []f32,
    env: []f32,
    shifted: []f32,

    /// Create a shifter, precomputing the Hann window and FFT tables.
    ///
    /// All scratch (`2048`-sample frame buffers plus three `1025`-sample
    /// envelope buffers, bit-reversal and twiddle tables) is allocated here.
    /// The initial shift is `0.0` cents (passthrough). Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32) error{OutOfMemory}!FormantShifter {
        const store_len = 6 * fft_size + 2 * (fft_size / 2) + 3 * half;
        const store = try gpa.alloc(f32, store_len);
        errdefer gpa.free(store);
        @memset(store, 0.0);
        const bit_rev = try gpa.alloc(usize, fft_size);
        errdefer gpa.free(bit_rev);

        var off: usize = 0;
        const window = carve(store, &off, fft_size);
        const in_buf = carve(store, &off, fft_size);
        const ola = carve(store, &off, fft_size);
        const wsum = carve(store, &off, fft_size);
        const fft_re = carve(store, &off, fft_size);
        const fft_im = carve(store, &off, fft_size);
        const tw_cos = carve(store, &off, fft_size / 2);
        const tw_sin = carve(store, &off, fft_size / 2);
        const logmag = carve(store, &off, half);
        const env = carve(store, &off, half);
        const shifted = carve(store, &off, half);
        std.debug.assert(off == store_len);

        const denom: f32 = @floatFromInt(fft_size - 1);
        for (window, 0..) |*slot, i| {
            const phase = 2.0 * @as(f32, pi) * @as(f32, @floatFromInt(i)) / denom;
            slot.* = 0.5 - 0.5 * @cos(phase);
        }
        for (bit_rev, 0..) |*slot, i| {
            var x = i;
            var y: usize = 0;
            for (0..11) |_| {
                y = (y << 1) | (x & 1);
                x >>= 1;
            }
            slot.* = y;
        }
        for (tw_cos, tw_sin, 0..) |*c, *s, k| {
            const ang = 2.0 * pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(fft_size));
            c.* = @floatCast(@cos(ang));
            s.* = @floatCast(@sin(ang));
        }
        return .{
            .sample_rate_ = sample_rate,
            .cents = 0.0,
            .ratio = 1.0,
            .store = store,
            .window = window,
            .in_buf = in_buf,
            .ola = ola,
            .wsum = wsum,
            .fft_re = fft_re,
            .fft_im = fft_im,
            .bit_rev = bit_rev,
            .tw_cos = tw_cos,
            .tw_sin = tw_sin,
            .logmag = logmag,
            .env = env,
            .shifted = shifted,
        };
    }

    fn carve(store: []f32, off: *usize, len: usize) []f32 {
        const s = store[off.* .. off.* + len];
        off.* += len;
        return s;
    }

    /// Free the buffers allocated by `init`.
    pub fn deinit(self: *FormantShifter, gpa: std.mem.Allocator) void {
        gpa.free(self.bit_rev);
        gpa.free(self.store);
        self.* = undefined;
    }

    /// Sample rate in Hz passed to `init`.
    pub fn sampleRate(self: *const FormantShifter) u32 {
        return self.sample_rate_;
    }

    /// Current shift in cents, clamped to `-1200..=1200`.
    pub fn shiftCents(self: *const FormantShifter) f32 {
        return self.cents;
    }

    /// Current shift ratio `2^(cents/1200)` (`0.5..=2.0`).
    pub fn shiftRatio(self: *const FormantShifter) f32 {
        return self.ratio;
    }

    /// Set the throat-length shift in cents, clamped to `+-1200`.
    ///
    /// Positive values shorten the throat (formants move up), negative values
    /// lengthen it (formants move down). `NaN` is ignored, leaving the
    /// previous setting in place; infinities clamp to the nearest rail.
    pub fn setShiftCents(self: *FormantShifter, cents: f32) void {
        if (std.math.isNan(cents)) return;
        const clamped = std.math.clamp(cents, -max_cents, max_cents);
        self.cents = clamped;
        self.ratio = std.math.pow(f32, 2.0, clamped / max_cents);
    }

    /// Clear frame history and overlap tails. Window, tables, and shift stay.
    pub fn reset(self: *FormantShifter) void {
        @memset(self.in_buf, 0.0);
        @memset(self.ola, 0.0);
        @memset(self.wsum, 0.0);
        @memset(self.fft_re, 0.0);
        @memset(self.fft_im, 0.0);
        @memset(self.logmag, 0.0);
        @memset(self.env, 0.0);
        @memset(self.shifted, 0.0);
    }

    /// Process one block with identical input/output lengths. Returns
    /// `error.LengthMismatch` if they differ.
    ///
    /// Ratios within `1e-6` of one copy input to output directly. Otherwise
    /// each `1024`-sample hop (plus a shorter tail hop when the block is not
    /// a multiple of the hop) is framed from a `2048`-sample history, Hann
    /// windowed, forward transformed, envelope shifted with original phases,
    /// inverse transformed, Hann windowed again, and overlap-added with
    /// squared-window normalization. Empty blocks are a no-op.
    pub fn processChecked(self: *FormantShifter, input: []const f32, output: []f32) error{LengthMismatch}!void {
        if (input.len != output.len) return error.LengthMismatch;
        const n = input.len;
        if (n == 0) return;
        if (@abs(self.ratio - 1.0) <= unity_eps) {
            @memcpy(output, input);
            if (n >= fft_size) {
                @memcpy(self.in_buf, input[n - fft_size ..]);
            } else {
                std.mem.copyForwards(f32, self.in_buf[0 .. fft_size - n], self.in_buf[n..fft_size]);
                @memcpy(self.in_buf[fft_size - n ..], input);
            }
            @memset(self.ola, 0.0);
            @memset(self.wsum, 0.0);
            return;
        }
        var pos: usize = 0;
        while (pos < n) {
            const h = @min(hop, n - pos);
            std.mem.copyForwards(f32, self.in_buf[0 .. fft_size - h], self.in_buf[h..fft_size]);
            @memcpy(self.in_buf[fft_size - h ..], input[pos .. pos + h]);
            for (0..fft_size) |i| {
                self.fft_re[i] = self.in_buf[i] * self.window[i];
                self.fft_im[i] = 0.0;
            }
            fftForward(self.fft_re, self.fft_im, self.bit_rev, self.tw_cos, self.tw_sin);
            for (0..half) |k| {
                const re = self.fft_re[k];
                const im = self.fft_im[k];
                const mag = @sqrt(re * re + im * im);
                self.logmag[k] = @log(mag + eps);
            }
            for (0..half) |k| {
                var sum: f32 = 0.0;
                var r: isize = -@as(isize, smooth_radius);
                while (r <= @as(isize, smooth_radius)) : (r += 1) {
                    const idx: usize = @intCast(std.math.clamp(@as(isize, @intCast(k)) + r, 0, @as(isize, half - 1)));
                    sum += self.logmag[idx];
                }
                self.env[k] = @exp(sum / smooth_len);
            }
            const ratio = self.ratio;
            const edge: f32 = @floatFromInt(half - 1);
            for (0..half) |k| {
                const src = @as(f32, @floatFromInt(k)) / ratio;
                const clamped = std.math.clamp(src, 0.0, edge);
                const lo: usize = @intFromFloat(@floor(clamped));
                const hi = @min(lo + 1, half - 1);
                const frac = clamped - @as(f32, @floatFromInt(lo));
                const a = self.env[lo];
                const b = self.env[hi];
                self.shifted[k] = a + (b - a) * frac;
            }
            for (0..half) |k| {
                const g = std.math.clamp(self.shifted[k] / (self.env[k] + eps), gain_min, gain_max);
                self.fft_re[k] *= g;
                self.fft_im[k] *= g;
            }
            for (1..fft_size / 2) |k| {
                const mir = fft_size - k;
                self.fft_re[mir] = self.fft_re[k];
                self.fft_im[mir] = -self.fft_im[k];
            }
            fftInverse(self.fft_re, self.fft_im, self.bit_rev, self.tw_cos, self.tw_sin);
            for (0..fft_size) |i| {
                const framed = self.fft_re[i] * self.window[i];
                self.ola[i] += framed;
                self.wsum[i] += self.window[i] * self.window[i];
            }
            for (0..h) |i| {
                const w = self.wsum[i];
                output[pos + i] = if (w > wsum_floor) self.ola[i] / w else 0.0;
            }
            std.mem.copyForwards(f32, self.ola[0 .. fft_size - h], self.ola[h..fft_size]);
            @memset(self.ola[fft_size - h ..], 0.0);
            std.mem.copyForwards(f32, self.wsum[0 .. fft_size - h], self.wsum[h..fft_size]);
            @memset(self.wsum[fft_size - h ..], 0.0);
            pos += h;
        }
    }

    /// Process one block with identical input/output lengths.
    ///
    /// Panics if `input.len != output.len`, like the Rust `assert_eq!`.
    pub fn process(self: *FormantShifter, input: []const f32, output: []f32) void {
        self.processChecked(input, output) catch
            @panic("input and output blocks must have equal length");
    }

    /// Overlap size (`2048 - 1024 = 1024`) in samples.
    pub fn latencySamples(self: *const FormantShifter) usize {
        _ = self;
        return fft_size - hop;
    }
};

comptime {
    types.assertProcessor(FormantShifter);
}

/// In-place radix-2 forward FFT over `re`/`im` using precomputed tables.
///
/// `bit_rev` holds 11-bit reversals for 2048 points; `cos_tab`/`sin_tab` hold
/// `cos(2*pi*k/N)`/`sin(2*pi*k/N)` for `k` in `0..N/2`. Forward twiddles use
/// the negative-exponent convention. No allocation.
fn fftForward(re: []f32, im: []f32, bit_rev: []const usize, cos_tab: []const f32, sin_tab: []const f32) void {
    butterflies(re, im, bit_rev, cos_tab, sin_tab, -1.0);
}

/// In-place radix-2 inverse FFT with `1/N` scaling.
///
/// Same table contract as `fftForward` but with the positive-exponent
/// convention, then every real/imaginary lane is scaled by `1/N`.
fn fftInverse(re: []f32, im: []f32, bit_rev: []const usize, cos_tab: []const f32, sin_tab: []const f32) void {
    butterflies(re, im, bit_rev, cos_tab, sin_tab, 1.0);
    const inv = 1.0 / @as(f32, @floatFromInt(re.len));
    for (re) |*v| v.* *= inv;
    for (im) |*v| v.* *= inv;
}

/// Shared bit-reversal plus butterfly passes. `sign` is `-1` (forward) or
/// `+1` (inverse); multiplying `sin` by `+-1` is exact, so this matches the
/// Rust's two hand-copied loops bit for bit.
fn butterflies(re: []f32, im: []f32, bit_rev: []const usize, cos_tab: []const f32, sin_tab: []const f32, sign: f32) void {
    const n = re.len;
    for (0..n) |i| {
        const j = bit_rev[i];
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const hl = len >> 1;
        const step = n / len;
        var base: usize = 0;
        while (base < n) : (base += len) {
            for (0..hl) |j| {
                const tab = j * step;
                const wr = cos_tab[tab];
                const wi = sign * sin_tab[tab];
                const ur = re[base + j];
                const ui = im[base + j];
                const ar = re[base + j + hl];
                const ai = im[base + j + hl];
                const vr = ar * wr - ai * wi;
                const vi = ar * wi + ai * wr;
                re[base + j] = ur + vr;
                im[base + j] = ui + vi;
                re[base + j + hl] = ur - vr;
                im[base + j + hl] = ui - vi;
            }
        }
    }
}

const testing = std.testing;
const Fft = @import("fft.zig").Fft;
const YinDetector = @import("detector_yin.zig").YinDetector;

/// Caller frees the result.
fn harmonicStack(gpa: std.mem.Allocator, sample_rate: u32, len: usize) ![]f32 {
    const tau: f32 = 2.0 * pi;
    const rate: f32 = @floatFromInt(sample_rate);
    const out = try gpa.alloc(f32, len);
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        s.* = 0.5 * @sin(tau * 440.0 * t) + 0.3 * @sin(tau * 880.0 * t) + 0.2 * @sin(tau * 1320.0 * t);
    }
    return out;
}

fn rmsError(a: []const f32, b: []const f32) !f32 {
    try testing.expectEqual(a.len, b.len);
    var sum: f32 = 0.0;
    for (a, b) |x, y| {
        const d = x - y;
        sum += d * d;
    }
    return @sqrt(sum / @as(f32, @floatFromInt(a.len)));
}

fn peakBin(gpa: std.mem.Allocator, samples: []const f32) !usize {
    const fft = try Fft.init(samples.len);
    const spec = try fft.forward(gpa, samples);
    defer gpa.free(spec);
    var best: usize = 0;
    var peak: f32 = 0.0;
    for (1..samples.len / 2 + 1) |i| {
        const mag = spec[i].re * spec[i].re + spec[i].im * spec[i].im;
        if (mag > peak) {
            peak = mag;
            best = i;
        }
    }
    return best;
}

test "zero_cents_passthrough_within_3_percent" {
    const gpa = testing.allocator;
    const rate: u32 = 44_100;
    const input = try harmonicStack(gpa, rate, 8192);
    defer gpa.free(input);
    var shifter = try FormantShifter.init(gpa, rate);
    defer shifter.deinit(gpa);
    shifter.setShiftCents(0.0);
    const output = try gpa.alloc(f32, input.len);
    defer gpa.free(output);
    @memset(output, 0.0);
    shifter.process(input, output);
    const err = try rmsError(input, output);
    try testing.expect(err < 0.03);
}

test "octave_up_shifts_formants_but_keeps_pitch" {
    const gpa = testing.allocator;
    const rate: u32 = 44_100;
    const input = try harmonicStack(gpa, rate, 8192);
    defer gpa.free(input);
    var shifter = try FormantShifter.init(gpa, rate);
    defer shifter.deinit(gpa);
    shifter.setShiftCents(1200.0);
    const output = try gpa.alloc(f32, input.len);
    defer gpa.free(output);
    @memset(output, 0.0);
    shifter.process(input, output);
    const tail_in = input[4096..];
    const tail_out = output[4096..];
    const in_peak = try peakBin(gpa, tail_in);
    const out_peak = try peakBin(gpa, tail_out);
    try testing.expect(in_peak != out_peak);
    var detector = try YinDetector.init(gpa, rate, 50.0, 2000.0);
    defer detector.deinit(gpa);
    const reading = detector.estimate(tail_out) orelse return error.YinMustDetectPitchAfterFormantShift;
    const rel = @abs(reading.freq_hz - 440.0) / 440.0;
    try testing.expect(rel <= 0.05);
}

test "shift_cents_clamps_to_octave" {
    const gpa = testing.allocator;
    var shifter = try FormantShifter.init(gpa, 44_100);
    defer shifter.deinit(gpa);
    shifter.setShiftCents(5000.0);
    try testing.expectEqual(@as(f32, 1200.0), shifter.shiftCents());
    try testing.expect(@abs(shifter.shiftRatio() - 2.0) <= 1e-5);
    shifter.setShiftCents(-5000.0);
    try testing.expectEqual(@as(f32, -1200.0), shifter.shiftCents());
    try testing.expect(@abs(shifter.shiftRatio() - 0.5) <= 1e-5);
    const before = shifter.shiftCents();
    shifter.setShiftCents(std.math.nan(f32));
    try testing.expectEqual(before, shifter.shiftCents());
}

test "process_checked_rejects_length_mismatch" {
    const gpa = testing.allocator;
    var shifter = try FormantShifter.init(gpa, 44_100);
    defer shifter.deinit(gpa);
    const in: [4]f32 = @splat(0.0);
    var out: [3]f32 = undefined;
    try testing.expectError(error.LengthMismatch, shifter.processChecked(&in, &out));
}
