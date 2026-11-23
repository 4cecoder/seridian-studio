// Translated to Zig from pitchpure/crates/pitchpure_suite/src/meters.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Engine-published telemetry: what the chain is doing right now. Written
//! by the live engine, read by the GUI; never part of `settings.Settings`.
//!
//! `Meters{}` is Rust's `Meters::default()`.

const std = @import("std");
const BAND_COUNT = @import("../parametric_eq.zig").BAND_COUNT;

/// Size of the analyzer snapshot handed to the EQ display.
pub const ANALYZER_LEN: usize = 1024;

pub const Meters = struct {
    input_peak: f32 = 0.0,
    output_peak: f32 = 0.0,
    detected_hz: f32 = 0.0,
    applied_ratio: f32 = 1.0,
    /// Noise isolation: currently learning / has a learned profile / floor.
    noise_learning: bool = false,
    noise_profile: bool = false,
    noise_floor_db: f32 = -120.0,
    /// Notes the harmony voices are singing.
    harmony_notes: [2]?i32 = @splat(null),
    /// Smart voice EQ: live gain per band in dB.
    eq_gains: [5]f32 = @splat(0.0),
    /// Graph EQ: dynamic attenuation currently applied by each band.
    eq_dynamic_gains_db: [BAND_COUNT]f32 = @splat(0.0),
    /// Last processed block for the non-realtime analyzer display.
    eq_analyzer_samples: [ANALYZER_LEN]f32 = @splat(0.0),
    rider_gain_db: f32 = 0.0,
    limiter_gr_db: f32 = 0.0,
    /// Compressor reduction (dB, <= 0) and smoothed input peak (dBFS).
    comp_gr_db: f32 = 0.0,
    comp_in_db: f32 = -120.0,
    /// De-esser high-band reduction (dB, <= 0) and detected sibilance (dBFS).
    deess_gr_db: f32 = 0.0,
    deess_level_db: f32 = -120.0,
    /// Length of the take in progress.
    rec_seconds: f32 = 0.0,

    /// Field-wise equality, matching Rust's derived `PartialEq`.
    pub fn eql(a: *const Meters, b: *const Meters) bool {
        return std.meta.eql(a.*, b.*);
    }
};
