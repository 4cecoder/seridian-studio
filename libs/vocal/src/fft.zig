// Translated to Zig from pitchpure/crates/pitchpure_engine/src/fft.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Radix-2 Cooley-Tukey FFT over real frames, from first principles.
//!
//! `Fft` owns a fixed power-of-two transform length (`>= 32`) and offers a
//! real-to-complex `Fft.forward` plus a complex-to-real `Fft.inverse`
//! that scales by `1/N`. Also provides the `hannWindow` taper and the
//! `magnitudeDb` helper.
//!
//! `forward`, `inverse` and `hannWindow` allocate their results (control
//! thread only; the caller frees). Real-time callers preallocate `f64`
//! scratch and use `Fft.transformInPlace`, which never allocates.
//!
//! Seridian: the Rust panics on invalid sizes and length mismatches; here
//! they are returned as errors (`error.InvalidSize`, `error.LengthMismatch`).

const std = @import("std");

/// One complex bin, the Rust `(re, im)` tuple.
pub const Complex = struct {
    re: f32,
    im: f32,
};

pub const Error = error{
    /// Size is not a power of two or is below 32.
    InvalidSize,
    /// A buffer length differs from `Fft.size`.
    LengthMismatch,
};

/// Fixed-size radix-2 FFT plan.
///
/// Holds only the transform length; twiddle factors are recomputed per call
/// so the plan is tiny, copyable, and safe to share between threads.
pub const Fft = struct {
    size_: usize,

    /// Create a plan for `size` complex bins.
    /// Returns `error.InvalidSize` unless `size` is a power of two and at least 32.
    pub fn init(n: usize) Error!Fft {
        if (!(n >= 32 and std.math.isPowerOfTwo(n))) return error.InvalidSize;
        return .{ .size_ = n };
    }

    /// Transform length this plan was built for.
    pub fn size(self: Fft) usize {
        return self.size_;
    }

    /// Forward real-to-complex transform.
    ///
    /// `real` must hold exactly `size()` samples; returns `size` complex bins
    /// with the standard negative-exponent convention. Caller frees the result.
    pub fn forward(self: Fft, gpa: std.mem.Allocator, real: []const f32) (Error || std.mem.Allocator.Error)![]Complex {
        if (real.len != self.size_) return error.LengthMismatch;
        const n = self.size_;
        const re = try gpa.alloc(f64, n);
        defer gpa.free(re);
        const im = try gpa.alloc(f64, n);
        defer gpa.free(im);
        for (real, re, im) |v, *r, *i| {
            r.* = @as(f64, v);
            i.* = 0.0;
        }
        const out = try gpa.alloc(Complex, n);
        errdefer gpa.free(out);
        transform(re, im, false);
        for (out, re, im) |*o, r, i| {
            o.* = .{ .re = @floatCast(r), .im = @floatCast(i) };
        }
        return out;
    }

    /// Inverse complex-to-real transform, scaled back by `1/N`.
    ///
    /// `spec` must hold exactly `size()` bins; returns `size` real samples
    /// (the imaginary residual is discarded). Caller frees the result.
    pub fn inverse(self: Fft, gpa: std.mem.Allocator, spec: []const Complex) (Error || std.mem.Allocator.Error)![]f32 {
        if (spec.len != self.size_) return error.LengthMismatch;
        const n = self.size_;
        const re = try gpa.alloc(f64, n);
        defer gpa.free(re);
        const im = try gpa.alloc(f64, n);
        defer gpa.free(im);
        for (spec, re, im) |c, *r, *i| {
            r.* = @as(f64, c.re);
            i.* = @as(f64, c.im);
        }
        const out = try gpa.alloc(f32, n);
        errdefer gpa.free(out);
        transform(re, im, true);
        for (out, re) |*o, r| o.* = @floatCast(r);
        return out;
    }

    /// Allocation-free in-place complex transform over caller-owned buffers
    /// (each exactly `size()` long). `invert` runs the inverse and scales by
    /// `1/N`. For realtime callers that preallocate scratch.
    pub fn transformInPlace(self: Fft, re: []f64, im: []f64, invert: bool) Error!void {
        if (re.len != self.size_ or im.len != self.size_) return error.LengthMismatch;
        transform(re, im, invert);
    }

    /// Convenience alias for the free `hannWindow` function.
    pub const hannWindow = hannWindowImpl;

    /// Convenience alias for the free `magnitudeDb` function.
    pub const magnitudeDb = magnitudeDbImpl;
};

/// Hann taper of length `n`: `0.5 * (1 - cos(2*pi*i / (n-1)))`.
///
/// Returns an empty slice for `n == 0` and `{1.0}` for `n == 1`. Otherwise
/// endpoints are `0.0` and the centre tap is `1.0` (exactly for odd `n`,
/// within float error for even `n`). Caller frees the result.
pub const hannWindow = hannWindowImpl;

/// Complex magnitude in decibels: `20 * log10(sqrt(re*re + im*im))`.
/// Returns negative infinity for a zero-magnitude input.
pub const magnitudeDb = magnitudeDbImpl;

fn hannWindowImpl(gpa: std.mem.Allocator, n: usize) std.mem.Allocator.Error![]f32 {
    const w = try gpa.alloc(f32, n);
    if (n == 0) return w;
    if (n == 1) {
        w[0] = 1.0;
        return w;
    }
    const denom: f64 = @floatFromInt(n - 1);
    for (w, 0..) |*v, i| {
        const fi: f64 = @floatFromInt(i);
        v.* = @floatCast(0.5 * (1.0 - @cos(2.0 * std.math.pi * fi / denom)));
    }
    return w;
}

fn magnitudeDbImpl(re: f32, im: f32) f32 {
    const mag = @sqrt(re * re + im * im);
    if (mag <= 0.0) return -std.math.inf(f32);
    return 20.0 * @log10(mag);
}

/// In-place radix-2 decimation-in-time transform over `re`/`im`.
///
/// `invert == false` uses the `-2*pi/len` (forward) twiddle; `true` uses
/// `+2*pi/len` and scales both halves by `1/N`. Caller must guarantee
/// `re.len == im.len` is a power of two.
fn transform(re: []f64, im: []f64, invert: bool) void {
    const n = re.len;
    std.debug.assert(std.math.isPowerOfTwo(n));
    std.debug.assert(re.len == im.len);

    var j: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const sign: f64 = if (invert) 1.0 else -1.0;
        const ang: f64 = 2.0 * std.math.pi / @as(f64, @floatFromInt(len)) * sign;
        const wlen_re = @cos(ang);
        const wlen_im = @sin(ang);
        const half = len >> 1;
        var start: usize = 0;
        while (start < n) : (start += len) {
            var w_re: f64 = 1.0;
            var w_im: f64 = 0.0;
            for (0..half) |k| {
                const a = start + k;
                const b = a + half;
                const u_re = re[a];
                const u_im = im[a];
                const v_re = re[b] * w_re - im[b] * w_im;
                const v_im = re[b] * w_im + im[b] * w_re;
                re[a] = u_re + v_re;
                im[a] = u_im + v_im;
                re[b] = u_re - v_re;
                im[b] = u_im - v_im;
                const next_re = w_re * wlen_re - w_im * wlen_im;
                const next_im = w_re * wlen_im + w_im * wlen_re;
                w_re = next_re;
                w_im = next_im;
            }
        }
    }

    if (invert) {
        const inv_n = 1.0 / @as(f64, @floatFromInt(n));
        for (re) |*v| v.* *= inv_n;
        for (im) |*v| v.* *= inv_n;
    }
}

const testing = std.testing;

fn deterministicData(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    var state: u32 = 0x1234_5678;
    for (out) |*v| {
        state = state *% 1664525 +% 1013904223;
        const max: f32 = @floatFromInt(std.math.maxInt(u32));
        v.* = @mulAdd(f32, @as(f32, @floatFromInt(state)) / max, 2.0, -1.0);
    }
    return out;
}

test "roundtrip_restores_input" {
    const gpa = testing.allocator;
    const fft = try Fft.init(256);
    const input = try deterministicData(gpa, fft.size());
    defer gpa.free(input);
    const spec = try fft.forward(gpa, input);
    defer gpa.free(spec);
    try testing.expectEqual(input.len, spec.len);
    const output = try fft.inverse(gpa, spec);
    defer gpa.free(output);
    try testing.expectEqual(input.len, output.len);
    for (input, output) |a, b| {
        try testing.expect(@abs(a - b) <= 1e-4);
    }
}

test "sine_440hz_peaks_near_expected_bin" {
    const gpa = testing.allocator;
    const n: usize = 4096;
    const sample_rate: f32 = 44_100.0;
    const pi_f32: f32 = std.math.pi;
    const fft = try Fft.init(n);
    const input = try gpa.alloc(f32, n);
    defer gpa.free(input);
    for (input, 0..) |*v, i| {
        const fi: f32 = @floatFromInt(i);
        v.* = @sin(2.0 * pi_f32 * 440.0 * fi / sample_rate);
    }
    const spec = try fft.forward(gpa, input);
    defer gpa.free(spec);
    const nf: f32 = @floatFromInt(n);
    const expected: isize = @intFromFloat(@round(440.0 * nf / sample_rate));
    var peak: usize = 0;
    var best: f32 = -std.math.inf(f32);
    for (1..n / 2 + 1) |i| {
        const c = spec[i];
        const mag = c.re * c.re + c.im * c.im;
        if (mag > best) {
            best = mag;
            peak = i;
        }
    }
    try testing.expect(@abs(@as(isize, @intCast(peak)) - expected) <= 2);
}

test "hann_endpoints_zero_center_one" {
    const gpa = testing.allocator;
    const n: usize = 1024;
    const w = try hannWindow(gpa, n);
    defer gpa.free(w);
    try testing.expectEqual(n, w.len);
    try testing.expect(@abs(w[0]) < 1e-6);
    try testing.expect(@abs(w[n - 1]) < 1e-6);
    var max: f32 = -std.math.inf(f32);
    for (w) |x| max = @max(max, x);
    try testing.expect(@abs(max - 1.0) < 1e-3);

    const odd = try hannWindow(gpa, 65);
    defer gpa.free(odd);
    try testing.expectEqual(@as(usize, 65), odd.len);
    try testing.expect(@abs(odd[32] - 1.0) < 1e-6);
}

test "associated_helpers_match_free_functions" {
    const gpa = testing.allocator;
    const a = try Fft.hannWindow(gpa, 64);
    defer gpa.free(a);
    const b = try hannWindow(gpa, 64);
    defer gpa.free(b);
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expect(@abs(x - y) < 1e-7);
    try testing.expectEqual(magnitudeDb(3.0, 4.0), Fft.magnitudeDb(3.0, 4.0));
    try testing.expect(@abs(magnitudeDb(1.0, 0.0)) < 1e-5);
    try testing.expect(@abs(magnitudeDb(3.0, 4.0) - 20.0 * @log10(@as(f32, 5.0))) < 1e-4);
    try testing.expectEqual(-std.math.inf(f32), magnitudeDb(0.0, 0.0));
}

// Rust #[should_panic]; Seridian returns an error instead.
test "new_rejects_non_power_of_two" {
    try testing.expectError(error.InvalidSize, Fft.init(100));
}

// Rust #[should_panic]; Seridian returns an error instead.
test "new_rejects_too_small" {
    try testing.expectError(error.InvalidSize, Fft.init(16));
}
