// Translated to Zig from pitchpure/crates/pitchpure_engine/src/simd.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! SIMD-accelerated helpers for `f32` audio frames.
//!
//! The Rust uses NEON (`float32x4_t`, four lanes plus a scalar tail) on
//! `aarch64` and a scalar loop elsewhere. Seridian: this file uses the
//! four-lane algorithm on every target via `@Vector(4, f32)`, so results are
//! identical to the Rust `aarch64` path (same lane accumulation, same
//! lane-combine order, same scalar tail). Loads go through slices copied into
//! vectors, so any alignment is sound.
//!
//! `maxAbsSimd` compares with `>` (as the scalar Rust does), so a NaN sample
//! never becomes the peak.

const std = @import("std");

const V4 = @Vector(4, f32);

pub const Error = error{
    /// `dst.len != src.len`.
    LengthMismatch,
};

/// Root-mean-square level of `samples`. Returns `0.0` for empty input.
pub fn rmsSimd(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;
    const n4 = samples.len / 4 * 4;
    var acc: V4 = @splat(0.0);
    var i: usize = 0;
    while (i < n4) : (i += 4) {
        const v: V4 = samples[i..][0..4].*;
        acc = acc + v * v;
    }
    var sum = ((acc[0] + acc[1]) + acc[2]) + acc[3];
    for (samples[n4..]) |x| sum += x * x;
    const n: f32 = @floatFromInt(samples.len);
    return @sqrt(sum / n);
}

/// Maximum absolute sample value in `samples`. Returns `0.0` for empty input.
pub fn maxAbsSimd(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;
    const n4 = samples.len / 4 * 4;
    var acc: V4 = @splat(0.0);
    var i: usize = 0;
    while (i < n4) : (i += 4) {
        const v: V4 = samples[i..][0..4].*;
        const a = @abs(v);
        acc = @select(f32, a > acc, a, acc);
    }
    var peak = acc[0];
    inline for (1..4) |lane| {
        if (acc[lane] > peak) peak = acc[lane];
    }
    for (samples[n4..]) |x| {
        const a = @abs(x);
        if (a > peak) peak = a;
    }
    return peak;
}

/// Accumulate `src` into `dst` with a scalar gain: `dst[i] += src[i] * gain`.
/// Returns `error.LengthMismatch` if `dst.len != src.len` (the Rust panics).
pub fn addAssignScaled(dst: []f32, src: []const f32, gain: f32) Error!void {
    if (dst.len != src.len) return error.LengthMismatch;
    const n4 = dst.len / 4 * 4;
    const g: V4 = @splat(gain);
    var i: usize = 0;
    while (i < n4) : (i += 4) {
        const vd: V4 = dst[i..][0..4].*;
        const vs: V4 = src[i..][0..4].*;
        dst[i..][0..4].* = vd + vs * g;
    }
    for (dst[n4..], src[n4..]) |*d, s| d.* += s * gain;
}

const testing = std.testing;

fn makeData(gpa: std.mem.Allocator, len: usize, seed: u32) ![]f32 {
    const out = try gpa.alloc(f32, len);
    var st: u32 = if (seed == 0) 0x9E37_79B9 else seed;
    for (out) |*v| {
        st ^= st << 13;
        st ^= st >> 17;
        st ^= st << 5;
        const u = @as(f32, @floatFromInt(st >> 8)) * (1.0 / 16_777_216.0);
        v.* = u * 2.0 - 1.0;
    }
    return out;
}

fn rmsRef(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (samples) |s| sum += s * s;
    const n: f32 = @floatFromInt(samples.len);
    return @sqrt(sum / n);
}

fn maxAbsRef(samples: []const f32) f32 {
    var peak: f32 = 0.0;
    for (samples) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    return peak;
}

const lengths = [_]usize{ 0, 1, 3, 4, 5, 16, 17, 1000 };

test "rms_matches_scalar_reference" {
    const gpa = testing.allocator;
    for (lengths) |len| {
        const data = try makeData(gpa, len, 0x1234_5678);
        defer gpa.free(data);
        try testing.expect(@abs(rmsSimd(data) - rmsRef(data)) <= 1e-5);
    }
}

test "max_abs_matches_scalar_reference" {
    const gpa = testing.allocator;
    for (lengths) |len| {
        const data = try makeData(gpa, len, 0x8765_4321);
        defer gpa.free(data);
        try testing.expect(@abs(maxAbsSimd(data) - maxAbsRef(data)) <= 1e-6);
    }
}

test "add_assign_matches_scalar_reference" {
    const gpa = testing.allocator;
    for (lengths) |len| {
        const dst = try makeData(gpa, len, 0x1111_1111);
        defer gpa.free(dst);
        const src = try makeData(gpa, len, 0x2222_2222);
        defer gpa.free(src);
        const want = try gpa.dupe(f32, dst);
        defer gpa.free(want);
        const gain: f32 = 0.371;
        for (want, src) |*d, s| d.* += s * gain;
        try addAssignScaled(dst, src, gain);
        for (dst, want) |d, w| try testing.expect(@abs(d - w) <= 1e-6);
    }
}

test "misaligned_subslices_match_scalar" {
    const gpa = testing.allocator;
    const backing = try makeData(gpa, 1042, 0xABCD_EF01);
    defer gpa.free(backing);
    const src_backing = try makeData(gpa, 1042, 0x1357_2468);
    defer gpa.free(src_backing);
    for ([_]usize{ 3, 5, 17, 1000 }) |len| {
        for ([_]usize{ 0, 1, 2, 3 }) |off| {
            const slice = backing[off .. off + len];
            try testing.expect(@abs(rmsSimd(slice) - rmsRef(slice)) <= 1e-5);
            try testing.expect(@abs(maxAbsSimd(slice) - maxAbsRef(slice)) <= 1e-6);
            const dst = try gpa.dupe(f32, slice);
            defer gpa.free(dst);
            const src = src_backing[off .. off + len];
            const want = try gpa.dupe(f32, dst);
            defer gpa.free(want);
            for (want, src) |*d, s| d.* += s * 1.7;
            try addAssignScaled(dst, src, 1.7);
            for (dst, want) |d, w| try testing.expect(@abs(d - w) <= 1e-6);
        }
    }
}

// Rust #[should_panic]; Seridian returns an error instead.
test "add_assign_panics_on_length_mismatch" {
    var dst = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const src = [_]f32{ 0.0, 0.0, 0.0 };
    try testing.expectError(error.LengthMismatch, addAssignScaled(&dst, &src, 1.0));
}
