// Translated to Zig from pitchpure/crates/pitchpure_engine/src/params.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Full parameter set and sample-rate smoothing.
//!
//! `FullParams` is the user-facing control block for the engine pipeline.
//! `SmoothedParams` tracks a `FullParams` target with a one-pole lowpass
//! per continuous field so automation and UI gestures do not zipper.

const std = @import("std");

/// User-facing pitch-correction parameters. Defaults (`.{}`): 40 ms retune,
/// no humanization, no transpose, no formant shift, fully corrected mix,
/// chromatic scale, root C4.
pub const FullParams = struct {
    /// Pitch-glide time in milliseconds, `0..=1000`.
    retune_ms: f32 = 40.0,
    /// Humanization amount, `0..=1` (`0` = fully quantized, deterministic).
    humanize: f32 = 0.0,
    /// Global pitch shift in cents, `-2400..=2400` (+/- two octaves).
    transpose_cents: f32 = 0.0,
    /// Formant shift in cents, `-1200..=1200` (+/- one octave).
    formant_cents: f32 = 0.0,
    /// Dry/wet mix, `0..=1` (`1.0` = fully corrected).
    mix: f32 = 1.0,
    /// Scale semitone mask; bit `i` allows semitone class `i`, measured as
    /// `(midi_note - root_midi) mod 12`. Only the low twelve bits are used.
    scale_mask: u16 = 0x0FFF,
    /// MIDI note acting as the scale root (default C4 = 60).
    root_midi: u8 = 60,

    /// Clamp every continuous field to its legal range in place.
    /// The discrete `scale_mask` and `root_midi` fields are left untouched.
    pub fn clampAll(self: *FullParams) void {
        self.retune_ms = std.math.clamp(self.retune_ms, 0.0, 1000.0);
        self.humanize = std.math.clamp(self.humanize, 0.0, 1.0);
        self.transpose_cents = std.math.clamp(self.transpose_cents, -2400.0, 2400.0);
        self.formant_cents = std.math.clamp(self.formant_cents, -1200.0, 1200.0);
        self.mix = std.math.clamp(self.mix, 0.0, 1.0);
    }
};

/// Time constant in seconds for `SmoothedParams` one-pole smoothing.
const smooth_tau_s: f32 = 0.01;

/// Sample-accurate one-pole smoother over `FullParams`.
///
/// Each call to `next` advances every continuous field one sample toward the
/// target with a ~10 ms time constant. `scale_mask` and `root_midi` snap to
/// the target immediately.
pub const SmoothedParams = struct {
    current: FullParams,
    alpha: f32,

    /// Create a smoother at its default state for the given sample rate.
    /// A `sample_rate` of zero disables smoothing.
    pub fn init(sample_rate: u32) SmoothedParams {
        return .{ .current = .{}, .alpha = coeff(sample_rate) };
    }

    /// Snap the smoother state to `p` immediately.
    pub fn reset(self: *SmoothedParams, p: *const FullParams) void {
        self.current = p.*;
    }

    /// Advance one sample toward `target` and return the smoothed state.
    pub fn next(self: *SmoothedParams, target: *const FullParams) FullParams {
        const a = self.alpha;
        self.current.retune_ms += a * (target.retune_ms - self.current.retune_ms);
        self.current.humanize += a * (target.humanize - self.current.humanize);
        self.current.transpose_cents += a * (target.transpose_cents - self.current.transpose_cents);
        self.current.formant_cents += a * (target.formant_cents - self.current.formant_cents);
        self.current.mix += a * (target.mix - self.current.mix);
        self.current.scale_mask = target.scale_mask;
        self.current.root_midi = target.root_midi;
        return self.current;
    }

    fn coeff(sample_rate: u32) f32 {
        if (sample_rate == 0) return 1.0;
        const sr: f32 = @floatFromInt(sample_rate);
        return 1.0 - @exp(-1.0 / (smooth_tau_s * sr));
    }
};

const testing = std.testing;

test "defaults_match_spec" {
    const p: FullParams = .{};
    try testing.expectEqual(@as(f32, 40.0), p.retune_ms);
    try testing.expectEqual(@as(f32, 0.0), p.humanize);
    try testing.expectEqual(@as(f32, 0.0), p.transpose_cents);
    try testing.expectEqual(@as(f32, 0.0), p.formant_cents);
    try testing.expectEqual(@as(f32, 1.0), p.mix);
    try testing.expectEqual(@as(u16, 0x0FFF), p.scale_mask);
    try testing.expectEqual(@as(u8, 60), p.root_midi);
}

test "clamp_all_fixes_out_of_range" {
    var p: FullParams = .{
        .retune_ms = 5000.0,
        .humanize = 5.0,
        .transpose_cents = -5000.0,
        .formant_cents = 3000.0,
        .mix = -1.0,
    };
    p.clampAll();
    try testing.expectEqual(@as(f32, 1000.0), p.retune_ms);
    try testing.expectEqual(@as(f32, 1.0), p.humanize);
    try testing.expectEqual(@as(f32, -2400.0), p.transpose_cents);
    try testing.expectEqual(@as(f32, 1200.0), p.formant_cents);
    try testing.expectEqual(@as(f32, 0.0), p.mix);
}

test "smoothing_converges_within_50ms" {
    const sample_rate: u32 = 48_000;
    var smoother = SmoothedParams.init(sample_rate);
    smoother.reset(&.{});
    const target: FullParams = .{ .retune_ms = 100.0 };
    const steps: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * 0.05);
    var out: FullParams = .{};
    for (0..steps) |_| out = smoother.next(&target);
    const err = @abs(out.retune_ms - target.retune_ms) / target.retune_ms;
    try testing.expect(err < 0.05);
}

test "mask_changes_apply_immediately" {
    var smoother = SmoothedParams.init(48_000);
    smoother.reset(&.{});
    const target: FullParams = .{ .scale_mask = 0x0AB5, .root_midi = 62 };
    const out = smoother.next(&target);
    try testing.expectEqual(@as(u16, 0x0AB5), out.scale_mask);
    try testing.expectEqual(@as(u8, 62), out.root_midi);
}
