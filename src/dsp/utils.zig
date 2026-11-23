//! Common DSP Utility Functions
//!
//! Shared utilities used across multiple DSP modules.
//! This file exists to avoid circular dependencies.

const std = @import("std");
const math = std.math;

/// Convert decibels to linear amplitude
pub fn dbToLinear(db: f32) f32 {
    return math.pow(f32, 10.0, db / 20.0);
}

/// Convert linear amplitude to decibels
pub fn linearToDb(linear: f32) f32 {
    if (linear <= 0.0) return -120.0;
    return 20.0 * @log10(linear);
}
