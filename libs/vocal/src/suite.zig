// Translated to Zig from pitchpure/crates/pitchpure_suite/src/lib.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! The PitchPure vocal suite without a GUI: settings, the full vocal
//! chain, recording takes, offline rendering and WAV I/O.
//!
//! Re-exports `suite/*.zig`. The QA gate (`suite/qa_tests.zig`) is test-only.

const std = @import("std");

/// Maximum samples per chain block (the live engine and offline renderer
/// both process in blocks of this size; `VocalChain.process` also accepts
/// shorter blocks).
pub const BLOCK: usize = 1024;

pub const chain = @import("suite/chain.zig");
pub const meters = @import("suite/meters.zig");
pub const settings = @import("suite/settings.zig");
pub const takes = @import("suite/takes.zig");
pub const wav = @import("suite/wav.zig");

pub const BlockReport = chain.BlockReport;
pub const VocalChain = chain.VocalChain;
pub const Meters = meters.Meters;

// Rust `pub use settings::*`.
pub const Settings = settings.Settings;
pub const ScalePreset = settings.ScalePreset;
pub const RetunePreset = settings.RetunePreset;
pub const HarmonyMode = settings.HarmonyMode;
pub const Interval = settings.Interval;
pub const harmonySemis = settings.harmonySemis;
pub const dbToGain = settings.dbToGain;
pub const makeParams = settings.makeParams;
pub const DEFAULT_RETUNE_MS = settings.DEFAULT_RETUNE_MS;
pub const DEFAULT_SCALE_MASK = settings.DEFAULT_SCALE_MASK;
pub const DEFAULT_ROOT_MIDI = settings.DEFAULT_ROOT_MIDI;
pub const DEFAULT_TRACKING = settings.DEFAULT_TRACKING;

pub const readWav = wav.readWav;
pub const writeWav = wav.writeWav;
pub const WavAudio = wav.WavAudio;

test {
    std.testing.refAllDecls(@This());
    _ = @import("suite/qa_tests.zig");
}
