// Translated to Zig from soundcraft/crates/dsp/src/lib.rs, soundcraft/crates/dsp/src/util.rs, soundcraft/crates/dsp/tests/it/offline_meters.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Decibel helpers and sample-rate sanitising: the prerequisites of the BS.1770 loudness meter.
//!
//! Rust `db_to_gain`, `gain_to_db`, `MIN_DB` (from `dsp/src/lib.rs`) and `sane_sr` with its
//! constants (from `dsp/src/util.rs`). Pure functions, no state, no allocation: safe on the
//! audio thread.

const std = @import("std");
const testing = std.testing;

/// Default sample rate used when a host passes something unusable (Rust `FALLBACK_SR`).
pub const FALLBACK_SR: f32 = 48_000.0;

/// Silence floor used by the dB helpers.
pub const MIN_DB: f32 = -144.0;

/// Sanitizes a host sample rate into 1 kHz ..= 1.536 MHz; anything else becomes `FALLBACK_SR`.
pub fn saneSr(sr: f32) f32 {
    if (std.math.isFinite(sr) and sr >= 1000.0) return @min(sr, 1_536_000.0);
    return FALLBACK_SR;
}

/// Converts decibels to linear gain. Anything at or below `MIN_DB` (or NaN) is silence.
pub fn dbToGain(db: f32) f32 {
    if (std.math.isNan(db) or db <= MIN_DB) return 0.0;
    return std.math.pow(f32, 10.0, @min(db, 200.0) / 20.0);
}

/// Converts linear gain (sign ignored) to decibels, floored at `MIN_DB`.
pub fn gainToDb(g: f32) f32 {
    const a = @abs(g);
    if (std.math.isNan(a)) return MIN_DB;
    if (std.math.isInf(a)) return std.math.floatMax(f32);
    return @max(20.0 * @log10(a), MIN_DB);
}

// --- tests (ported from the Rust test suite) ---

test "db_helpers" {
    try testing.expectEqual(@as(f32, 0.0), dbToGain(-200.0));
    try testing.expectEqual(@as(f32, 0.0), dbToGain(std.math.nan(f32)));
    try testing.expect(@abs(dbToGain(-6.0206) - 0.5) < 1e-4);
    try testing.expectEqual(@as(f32, -144.0), gainToDb(0.0));
    try testing.expectEqual(@as(f32, -144.0), gainToDb(std.math.nan(f32)));
    try testing.expect(@abs(gainToDb(0.5) + 6.0206) < 1e-3);
    try testing.expect(@abs(gainToDb(-1.0)) < 1e-6);
}

test "saneSr clamps and falls back like util.rs" {
    try testing.expectEqual(@as(f32, FALLBACK_SR), saneSr(0.0));
    try testing.expectEqual(@as(f32, FALLBACK_SR), saneSr(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 44_100.0), saneSr(44_100.0));
    try testing.expectEqual(@as(f32, FALLBACK_SR), saneSr(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 1_536_000.0), saneSr(2_000_000.0));
}

test "gainToDb of infinity is f32::MAX" {
    try testing.expectEqual(std.math.floatMax(f32), gainToDb(std.math.inf(f32)));
}
