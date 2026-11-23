// Translated to Zig from soundcraft/crates/example/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Module documentation goes right after the header comment.

const std = @import("std");

pub fn db_to_gain(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

test "db_to_gain: 0 dB is unity, -20 dB is 0.1" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), db_to_gain(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), db_to_gain(-20), 1e-6);
}
