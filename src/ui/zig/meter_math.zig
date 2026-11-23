//! Stereo peak meter math (failing tests first; bodies are todo stubs).

const std = @import("std");
const testing = std.testing;

pub const min_db: f32 = -60.0;
pub const max_db: f32 = 6.0;

/// Linear amplitude to decibels. Zero, negative-zero and NaN map to min_db floor handling by caller.
pub fn linearToDb(linear: f32) f32 {
    const magnitude = @abs(linear);
    // Silence, NaN and anything that would fall below the floor all read as min_db.
    if (!(magnitude > 0.0)) return min_db;
    const db = 20.0 * std.math.log10(magnitude);
    return @max(db, min_db);
}

/// Maps dB into 0..1 across [lo, hi], clamped. Zero-width or inverted range returns 0.
pub fn dbToNormalized(db: f32, lo: f32, hi: f32) f32 {
    if (!(hi > lo)) return 0.0;
    if (std.math.isNan(db)) return 0.0;
    const t = (db - lo) / (hi - lo);
    return std.math.clamp(t, 0.0, 1.0);
}

/// Linear amplitude to normalized display position over -60..+6 dB.
pub fn levelToNormalized(linear: f32) f32 {
    return dbToNormalized(linearToDb(linear), min_db, max_db);
}

/// Peak hold in dB: jumps up to current_db, otherwise decays by rate_db_per_s * dt_s, never below min_db.
pub fn peakHoldDb(held_db: f32, current_db: f32, dt_s: f32, rate_db_per_s: f32) f32 {
    if (current_db >= held_db) return current_db;
    // Negative or NaN time/rate must not raise the hold, so they contribute no decay.
    const decay = if (dt_s > 0.0 and rate_db_per_s > 0.0) rate_db_per_s * dt_s else 0.0;
    return @max(held_db - decay, min_db);
}

/// Maps a non-finite sample (+inf, -inf, NaN) to silence (0.0) so one bad frame
/// cannot pin the peak hold or latch clip. Finite samples pass through unchanged.
pub fn sanitizeSample(sample: f32) f32 {
    return if (std.math.isFinite(sample)) sample else 0.0;
}

/// Clip latch: stays true once set; sets when |sample| > 1.0. Non-finite samples
/// are ignored, so they neither set nor clear the latch.
pub fn clipLatch(latched: bool, sample: f32) bool {
    if (!std.math.isFinite(sample)) return latched;
    return latched or @abs(sample) > 1.0;
}

const eps = 1e-4;

test "linearToDb reference points" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToDb(1.0), eps);
    try testing.expectApproxEqAbs(@as(f32, -6.0206), linearToDb(0.5), eps);
    try testing.expectApproxEqAbs(@as(f32, 6.0206), linearToDb(2.0), eps);
    try testing.expectApproxEqAbs(@as(f32, -20.0), linearToDb(0.1), eps);
}

test "linearToDb silence and invalid inputs floor at min_db" {
    try testing.expectEqual(min_db, linearToDb(0.0));
    try testing.expectEqual(min_db, linearToDb(-0.0));
    try testing.expectEqual(min_db, linearToDb(std.math.nan(f32)));
    try testing.expectEqual(min_db, linearToDb(1e-12));
}

test "linearToDb uses magnitude for negative samples" {
    try testing.expectApproxEqAbs(linearToDb(0.5), linearToDb(-0.5), eps);
}

test "dbToNormalized boundaries" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), dbToNormalized(-60.0, -60.0, 6.0), eps);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dbToNormalized(6.0, -60.0, 6.0), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dbToNormalized(-27.0, -60.0, 6.0), eps);
    try testing.expectApproxEqAbs(@as(f32, 60.0 / 66.0), dbToNormalized(0.0, -60.0, 6.0), eps);
}

test "dbToNormalized clamps out-of-range inputs" {
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(-200.0, -60.0, 6.0));
    try testing.expectEqual(@as(f32, 1.0), dbToNormalized(40.0, -60.0, 6.0));
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(-std.math.inf(f32), -60.0, 6.0));
    try testing.expectEqual(@as(f32, 1.0), dbToNormalized(std.math.inf(f32), -60.0, 6.0));
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(std.math.nan(f32), -60.0, 6.0));
}

test "dbToNormalized zero-width and inverted ranges return 0 without NaN" {
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(0.0, 0.0, 0.0));
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(5.0, 3.0, 3.0));
    try testing.expectEqual(@as(f32, 0.0), dbToNormalized(0.0, 6.0, -60.0));
}

test "levelToNormalized maps linear into the -60..+6 display range" {
    try testing.expectEqual(@as(f32, 0.0), levelToNormalized(0.0));
    try testing.expectEqual(@as(f32, 0.0), levelToNormalized(0.0001)); // -80 dB, below range
    try testing.expectApproxEqAbs(@as(f32, 60.0 / 66.0), levelToNormalized(1.0), eps);
    try testing.expectEqual(@as(f32, 1.0), levelToNormalized(2.0)); // +6.02 dB clamps to top
    try testing.expectEqual(@as(f32, 1.0), levelToNormalized(100.0));
    try testing.expectApproxEqAbs(@as(f32, 0.0), levelToNormalized(0.001), eps); // exactly -60 dB
}

test "levelToNormalized is monotonic" {
    var prev: f32 = -1.0;
    var v: f32 = 0.0005;
    while (v < 3.0) : (v *= 1.5) {
        const n = levelToNormalized(v);
        try testing.expect(n >= prev);
        try testing.expect(n >= 0.0 and n <= 1.0);
        prev = n;
    }
}

test "peakHoldDb rises instantly to a louder level" {
    try testing.expectEqual(@as(f32, -6.0), peakHoldDb(-30.0, -6.0, 0.016, 20.0));
}

test "peakHoldDb decays at a fixed dB per second" {
    try testing.expectApproxEqAbs(@as(f32, -10.0), peakHoldDb(0.0, -100.0, 0.5, 20.0), eps);
    try testing.expectApproxEqAbs(@as(f32, -20.0), peakHoldDb(0.0, -100.0, 1.0, 20.0), eps);
}

test "peakHoldDb decay does not depend on how time is sliced" {
    var held: f32 = 0.0;
    var i: usize = 0;
    while (i < 100) : (i += 1) held = peakHoldDb(held, -100.0, 0.01, 20.0);
    try testing.expectApproxEqAbs(@as(f32, -20.0), held, 1e-3);
}

test "peakHoldDb never drops below min_db" {
    try testing.expectEqual(min_db, peakHoldDb(-59.0, -100.0, 10.0, 20.0));
    try testing.expectEqual(min_db, peakHoldDb(min_db, -100.0, 1.0, 20.0));
}

test "peakHoldDb holds when decay is zero or time does not advance" {
    try testing.expectEqual(@as(f32, -12.0), peakHoldDb(-12.0, -100.0, 0.0, 20.0));
    try testing.expectEqual(@as(f32, -12.0), peakHoldDb(-12.0, -100.0, 1.0, 0.0));
}

test "peakHoldDb ignores negative dt and rate (no upward drift)" {
    try testing.expectEqual(@as(f32, -12.0), peakHoldDb(-12.0, -100.0, -1.0, 20.0));
    try testing.expectEqual(@as(f32, -12.0), peakHoldDb(-12.0, -100.0, 1.0, -20.0));
}

test "peakHoldDb equal current level keeps the hold" {
    try testing.expectEqual(@as(f32, -12.0), peakHoldDb(-12.0, -12.0, 1.0, 20.0));
}

test "clipLatch sets when sample exceeds 1.0" {
    try testing.expect(clipLatch(false, 1.0001));
    try testing.expect(clipLatch(false, -1.5));
}

test "non-finite samples (+inf, -inf, NaN) are treated as silence" {
    const pos_inf = std.math.inf(f32);
    const neg_inf = -std.math.inf(f32);
    const nan = std.math.nan(f32);

    // sanitizeSample maps every non-finite value to 0.0 and leaves finite values alone.
    try testing.expectEqual(@as(f32, 0.0), sanitizeSample(pos_inf));
    try testing.expectEqual(@as(f32, 0.0), sanitizeSample(neg_inf));
    try testing.expectEqual(@as(f32, 0.0), sanitizeSample(nan));
    try testing.expectEqual(@as(f32, 0.5), sanitizeSample(0.5));

    // Sanitized non-finite frames read as the silence floor, not +inf dB.
    try testing.expectEqual(min_db, linearToDb(sanitizeSample(pos_inf)));
    try testing.expectEqual(min_db, linearToDb(sanitizeSample(neg_inf)));
    try testing.expectEqual(min_db, linearToDb(sanitizeSample(nan)));

    // A +inf frame must not pin the hold: it decays like any silent frame.
    const held = peakHoldDb(-10.0, linearToDb(sanitizeSample(pos_inf)), 0.5, 20.0);
    try testing.expectApproxEqAbs(@as(f32, -20.0), held, eps);

    // Non-finite samples never set the clip latch, and never clear an existing one.
    try testing.expect(!clipLatch(false, pos_inf));
    try testing.expect(!clipLatch(false, neg_inf));
    try testing.expect(!clipLatch(false, nan));
    try testing.expect(clipLatch(true, pos_inf));
    try testing.expect(clipLatch(true, nan));
}

test "clipLatch does not set at or below full scale" {
    try testing.expect(!clipLatch(false, 1.0));
    try testing.expect(!clipLatch(false, -1.0));
    try testing.expect(!clipLatch(false, 0.0));
    try testing.expect(!clipLatch(false, std.math.nan(f32)));
}

test "clipLatch stays latched until externally cleared" {
    try testing.expect(clipLatch(true, 0.0));
    try testing.expect(clipLatch(true, 0.5));
    try testing.expect(clipLatch(true, 2.0));
}
