// Translated to Zig from soundcraft/crates/midi/src/rng.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Small deterministic PRNG (xorshift64*) used for randomize and humanize, so results
//! are reproducible for a given seed. The arithmetic is bit-exact with the Rust version:
//! shifts discard overflowed bits, the output multiply wraps, and the float conversion
//! uses the same 53-bit unit mapping.

const std = @import("std");
const testing = std.testing;

pub const XorShift = struct {
    state: u64,

    /// Replaces a zero seed with this fixed non-zero constant.
    pub const zero_seed_replacement: u64 = 0x9E37_79B9_7F4A_7C15;

    /// Creates a generator. A zero seed is replaced by a fixed non-zero constant.
    pub fn init(seed: u64) XorShift {
        return .{ .state = if (seed == 0) zero_seed_replacement else seed };
    }

    /// Next raw 64-bit value.
    pub fn nextU64(self: *XorShift) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_F491_4F6C_DD1D;
    }

    /// Uniform value in `[-1.0, 1.0)`.
    pub fn nextSigned(self: *XorShift) f64 {
        // 53 random bits -> [0,1)
        const bits: u64 = self.nextU64() >> 11;
        const unit: f64 = @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        return unit * 2.0 - 1.0;
    }
};

// Golden values were derived from an independent reimplementation of the same
// recurrence (seed 1, and the zero-seed replacement), so they pin the bit pattern.

test "XorShift: seed 1 known answers for nextU64" {
    var rng = XorShift.init(1);
    try testing.expectEqual(@as(u64, 5180492295206395165), rng.nextU64());
    try testing.expectEqual(@as(u64, 12380297144915551517), rng.nextU64());
    try testing.expectEqual(@as(u64, 13389498078930870103), rng.nextU64());
}

test "XorShift: seed 1 known answers for nextSigned" {
    var rng = XorShift.init(1);
    try testing.expectEqual(@as(f64, -0.43832989989928106), rng.nextSigned());
    try testing.expectEqual(@as(f64, 0.34227450605335275), rng.nextSigned());
    try testing.expectEqual(@as(f64, 0.45169229056673355), rng.nextSigned());
}

test "XorShift: zero seed uses the fixed replacement constant" {
    var zero = XorShift.init(0);
    var explicit = XorShift.init(XorShift.zero_seed_replacement);
    try testing.expectEqual(explicit.nextU64(), zero.nextU64());
    var fresh = XorShift.init(0);
    try testing.expectEqual(@as(u64, 973819730272012410), fresh.nextU64());
}

test "XorShift: nextSigned stays in [-1, 1)" {
    var rng = XorShift.init(0xC0FFEE);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const v = rng.nextSigned();
        try testing.expect(v >= -1.0 and v < 1.0);
    }
}

test "XorShift: same seed gives the same stream" {
    var a = XorShift.init(42);
    var b = XorShift.init(42);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(a.nextU64(), b.nextU64());
    }
}
