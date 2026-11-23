// Translated to Zig from soundcraft/crates/dsp/src/biquad.rs, soundcraft/crates/dsp/src/util.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Second-order IIR filters designed from the RBJ "Audio EQ Cookbook" formulas, plus first-order
//! low/high-pass sections (bilinear transform) for 6 dB/oct slopes.
//!
//! Realtime safety: `Biquad.processSample` and `Biquad.processBlock` take caller slices and
//! never allocate, lock, log or do I/O. The design functions (`Coeffs.design`) are pure
//! arithmetic and are meant for the control thread; they are allocation free too.
//! `flush` is the denormal/non-finite guard from `util.rs`, copied here so this file stays
//! self-contained (the Rust original is `pub(crate)` in its crate).

const std = @import("std");
const testing = std.testing;
const db = @import("db.zig");

/// Filter response shapes.
pub const FilterType = enum {
    low_pass,
    high_pass,
    band_pass,
    notch,
    peak,
    low_shelf,
    high_shelf,
    all_pass,
    /// First-order (6 dB/oct) low-pass; `q` and `gain_db` are ignored.
    low_pass1,
    /// First-order (6 dB/oct) high-pass; `q` and `gain_db` are ignored.
    high_pass1,
};

/// Normalized biquad coefficients (`a0 = 1`). The defaults are `IDENTITY`.
pub const Coeffs = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    /// Passes the signal unchanged.
    pub const IDENTITY: Coeffs = .{};

    /// Designs a filter. All inputs are sanitized: frequency is clamped to 1 Hz .. 0.49·sr,
    /// Q to 0.025 .. 100 and gain to ±48 dB.
    pub fn design(kind: FilterType, freq: f32, q: f32, gain_db: f32, sample_rate: f32) Coeffs {
        const sr: f64 = @floatCast(db.saneSr(sample_rate));
        const f: f64 = if (std.math.isFinite(freq)) std.math.clamp(@as(f64, freq), 1.0, sr * 0.49) else 1000.0;
        const q64: f64 = if (std.math.isFinite(q)) std.math.clamp(@as(f64, q), 0.025, 100.0) else std.math.sqrt1_2;
        const g: f64 = if (std.math.isFinite(gain_db)) std.math.clamp(@as(f64, gain_db), -48.0, 48.0) else 0.0;
        const w0 = 2.0 * std.math.pi * f / sr;
        const sw = @sin(w0);
        const cw = @cos(w0);
        const alpha = sw / (2.0 * q64);
        const a = std.math.pow(f64, 10.0, g / 40.0);

        // Unnormalized (b0, b1, b2, a0, a1, a2), in the order of the Rust match arms.
        const raw: Raw = switch (kind) {
            .low_pass => .{
                .b0 = (1.0 - cw) / 2.0,
                .b1 = 1.0 - cw,
                .b2 = (1.0 - cw) / 2.0,
                .a0 = 1.0 + alpha,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha,
            },
            .high_pass => .{
                .b0 = (1.0 + cw) / 2.0,
                .b1 = -(1.0 + cw),
                .b2 = (1.0 + cw) / 2.0,
                .a0 = 1.0 + alpha,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha,
            },
            .band_pass => .{
                .b0 = alpha,
                .b1 = 0.0,
                .b2 = -alpha,
                .a0 = 1.0 + alpha,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha,
            },
            .notch => .{
                .b0 = 1.0,
                .b1 = -2.0 * cw,
                .b2 = 1.0,
                .a0 = 1.0 + alpha,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha,
            },
            .all_pass => .{
                .b0 = 1.0 - alpha,
                .b1 = -2.0 * cw,
                .b2 = 1.0 + alpha,
                .a0 = 1.0 + alpha,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha,
            },
            .peak => .{
                .b0 = 1.0 + alpha * a,
                .b1 = -2.0 * cw,
                .b2 = 1.0 - alpha * a,
                .a0 = 1.0 + alpha / a,
                .a1 = -2.0 * cw,
                .a2 = 1.0 - alpha / a,
            },
            .low_shelf => blk: {
                const s = 2.0 * @sqrt(a) * alpha;
                break :blk .{
                    .b0 = a * ((a + 1.0) - (a - 1.0) * cw + s),
                    .b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cw),
                    .b2 = a * ((a + 1.0) - (a - 1.0) * cw - s),
                    .a0 = (a + 1.0) + (a - 1.0) * cw + s,
                    .a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cw),
                    .a2 = (a + 1.0) + (a - 1.0) * cw - s,
                };
            },
            .high_shelf => blk: {
                const s = 2.0 * @sqrt(a) * alpha;
                break :blk .{
                    .b0 = a * ((a + 1.0) + (a - 1.0) * cw + s),
                    .b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cw),
                    .b2 = a * ((a + 1.0) + (a - 1.0) * cw - s),
                    .a0 = (a + 1.0) - (a - 1.0) * cw + s,
                    .a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cw),
                    .a2 = (a + 1.0) - (a - 1.0) * cw - s,
                };
            },
            .low_pass1, .high_pass1 => {
                // Bilinear transform of 1/(s+1) with prewarped cutoff. Not normalized by the
                // finiteness check below, exactly as in the Rust original.
                const k = @tan(w0 / 2.0);
                const norm = 1.0 / (1.0 + k);
                const a1 = (k - 1.0) * norm;
                return if (kind == .low_pass1)
                    .{ .b0 = @floatCast(k * norm), .b1 = @floatCast(k * norm), .b2 = 0.0, .a1 = @floatCast(a1), .a2 = 0.0 }
                else
                    .{ .b0 = @floatCast(norm), .b1 = @floatCast(-norm), .b2 = 0.0, .a1 = @floatCast(a1), .a2 = 0.0 };
            },
        };
        const c: Coeffs = .{
            .b0 = @floatCast(raw.b0 / raw.a0),
            .b1 = @floatCast(raw.b1 / raw.a0),
            .b2 = @floatCast(raw.b2 / raw.a0),
            .a1 = @floatCast(raw.a1 / raw.a0),
            .a2 = @floatCast(raw.a2 / raw.a0),
        };
        if (std.math.isFinite(c.b0) and std.math.isFinite(c.b1) and std.math.isFinite(c.b2) and
            std.math.isFinite(c.a1) and std.math.isFinite(c.a2))
        {
            return c;
        }
        return IDENTITY;
    }

    /// Magnitude response in dB at `freq` Hz.
    pub fn magnitudeDb(self: Coeffs, freq: f32, sample_rate: f32) f32 {
        const sr: f64 = @floatCast(db.saneSr(sample_rate));
        const f: f64 = if (std.math.isFinite(freq)) std.math.clamp(@as(f64, freq), 0.0, sr * 0.5) else 0.0;
        const w = 2.0 * std.math.pi * f / sr;
        const s1 = @sin(w);
        const c1 = @cos(w);
        const s2 = @sin(2.0 * w);
        const c2 = @cos(2.0 * w);
        const b0: f64 = self.b0;
        const b1: f64 = self.b1;
        const b2: f64 = self.b2;
        const a1: f64 = self.a1;
        const a2: f64 = self.a2;
        const nr = b0 + b1 * c1 + b2 * c2;
        const ni = -(b1 * s1 + b2 * s2);
        const dr = 1.0 + a1 * c1 + a2 * c2;
        const di = -(a1 * s1 + a2 * s2);
        const num = nr * nr + ni * ni;
        const den = maxNan(dr * dr + di * di, 1e-30);
        const level_db = 10.0 * @log10(maxNan(num / den, 1e-30));
        return @floatCast(maxNan(level_db, -300.0));
    }
};

/// Unnormalized coefficients, before division by `a0`.
const Raw = struct { b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64 };

/// A biquad section with its own state (transposed direct form II).
pub const Biquad = struct {
    coeffs: Coeffs = Coeffs.IDENTITY,
    z1: f32 = 0.0,
    z2: f32 = 0.0,

    pub fn init(coeffs: Coeffs) Biquad {
        return .{ .coeffs = coeffs, .z1 = 0.0, .z2 = 0.0 };
    }

    /// Designs a new filter (see `Coeffs.design`).
    pub fn design(kind: FilterType, freq: f32, q: f32, gain_db: f32, sample_rate: f32) Biquad {
        return init(Coeffs.design(kind, freq, q, gain_db, sample_rate));
    }

    /// Re-designs the coefficients, keeping the state (for smooth sweeps).
    pub fn set(self: *Biquad, kind: FilterType, freq: f32, q: f32, gain_db: f32, sample_rate: f32) void {
        self.coeffs = Coeffs.design(kind, freq, q, gain_db, sample_rate);
    }

    pub fn reset(self: *Biquad) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    pub fn processSample(self: *Biquad, x: f32) f32 {
        const c = self.coeffs;
        const y = c.b0 * x + self.z1;
        self.z1 = flush(c.b1 * x - c.a1 * y + self.z2);
        self.z2 = flush(c.b2 * x - c.a2 * y);
        if (std.math.isFinite(y)) return y;
        self.reset();
        return 0.0;
    }

    /// In-place processing of a caller-owned buffer. No allocation.
    pub fn processBlock(self: *Biquad, buf: []f32) void {
        for (buf) |*s| s.* = self.processSample(s.*);
    }

    /// Magnitude response in dB at `freq` Hz, for drawing curves.
    pub fn magnitudeDb(self: *const Biquad, freq: f32, sample_rate: f32) f32 {
        return self.coeffs.magnitudeDb(freq, sample_rate);
    }
};

/// Butterworth Q values for cascaded sections making an `order`-th order filter (2, 4).
pub fn butterworthQs(order: usize) []const f32 {
    return switch (order) {
        4 => &.{ 0.5411961, 1.306563 },
        else => &.{@as(f32, std.math.sqrt1_2)},
    };
}

/// Flushes denormals and non-finite values in feedback paths to zero (`util.rs` `flush`).
fn flush(x: f32) f32 {
    const a = @abs(x);
    return if ((a > 1.0e-25) and (a < std.math.inf(f32))) x else 0.0;
}

/// `f64::max` as Rust defines it: a NaN operand is ignored, the other operand wins.
fn maxNan(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return b;
    if (std.math.isNan(b)) return a;
    return @max(a, b);
}

// --- tests (ported from the Rust inline tests) ---

test "peak_gain_at_center" {
    const c = Coeffs.design(.peak, 1000.0, 1.0, 6.0, 48_000.0);
    try testing.expect(@abs(c.magnitudeDb(1000.0, 48_000.0) - 6.0) < 0.01);
    try testing.expect(@abs(c.magnitudeDb(20.0, 48_000.0)) < 0.1);
}

test "lowpass_minus3_at_cutoff" {
    const c = Coeffs.design(.low_pass, 1000.0, std.math.sqrt1_2, 0.0, 48_000.0);
    try testing.expect(@abs(c.magnitudeDb(1000.0, 48_000.0) + 3.01) < 0.05);
    const c1 = Coeffs.design(.high_pass1, 1000.0, 0.0, 0.0, 48_000.0);
    try testing.expect(@abs(c1.magnitudeDb(1000.0, 48_000.0) + 3.01) < 0.05);
}

test "hostile_inputs" {
    const c = Coeffs.design(.peak, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 0.0);
    try testing.expect(std.math.isFinite(c.b0));
    var b = Biquad.init(c);
    try testing.expect(b.processSample(std.math.nan(f32)) == 0.0);
}

test "Coeffs default is identity and passes samples unchanged" {
    var b = Biquad{};
    try testing.expectEqual(@as(f32, 0.25), b.processSample(0.25));
    try testing.expectEqual(Coeffs.IDENTITY, Coeffs{});
}

test "butterworthQs: 2nd order is one section at 1/sqrt(2), 4th order is two" {
    try testing.expectEqual(@as(usize, 1), butterworthQs(2).len);
    try testing.expectApproxEqAbs(@as(f32, std.math.sqrt1_2), butterworthQs(2)[0], 1e-6);
    try testing.expectEqual(@as(usize, 2), butterworthQs(4).len);
}

test "flush matches the finite and magnitude test (util.rs)" {
    const edge: u32 = @bitCast(@as(f32, 1.0e-25));
    const special = [_]u32{ 0, 0x8000_0000, 1, edge - 1, edge, edge + 1, 0x7f7f_ffff, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xffc0_0001 };
    for (special) |b| {
        try expectFlushMatches(b);
        try expectFlushMatches(b | 0x8000_0000);
    }
    var b: u64 = 0;
    while (b <= std.math.maxInt(u32)) : (b += 997) try expectFlushMatches(@intCast(b));
}

fn expectFlushMatches(bits: u32) !void {
    const x: f32 = @bitCast(bits);
    const want: f32 = if (std.math.isFinite(x) and @abs(x) > 1.0e-25) x else 0.0;
    try testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(flush(x))));
}
