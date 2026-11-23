// Translated to Zig from pitchpure/crates/pitchpure_engine/src/retune.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Per-block pitch-correction decision stage.
//!
//! `RetuneBrain` turns a tracked pitch estimate into the frequency ratio the
//! downstream shifter must realize. Each `RetuneBrain.targetRatio` call
//! represents one analysis block: parameters are smoothed, the detection is
//! quantized to the active scale, the correction is slew-limited by the
//! retune time, humanized with vibrato, and mixed toward dry.
//!
//! Detection and shifting stay decoupled: this stage outputs a plain ratio,
//! never audio. The `formant_cents` field of `FullParams` is reserved for
//! the downstream formant stage and does not affect the ratio.
//!
//! Realtime notes: no allocation, no syscalls after construction. Only
//! scalar math over already-owned state.

const std = @import("std");
const types = @import("types.zig");
const params_mod = @import("params.zig");
const FullParams = params_mod.FullParams;
const SmoothedParams = params_mod.SmoothedParams;
const TrackedPitch = @import("detector_track.zig").TrackedPitch;
const Quantizer = @import("quantizer.zig").Quantizer;
const SlewLimiter = @import("slew.zig").SlewLimiter;
const VibratoLfo = @import("vibrato.zig").VibratoLfo;

const tau: f32 = 2.0 * std.math.pi;

/// Minimum output ratio (`-2400` cents, two octaves down).
const min_ratio: f32 = 0.25;
/// Maximum output ratio (`+2400` cents, two octaves up).
const max_ratio: f32 = 4.0;
/// Peak depth of the internal vibrato sine in cents.
///
/// `humanize` acts as a depth multiplier over this fixed vibrato plus the
/// `VibratoLfo` output, so `humanize = 0` is exactly deterministic.
const internal_vibrato_cents: f32 = 30.0;
/// Internal vibrato rate in Hz.
const internal_vibrato_hz: f32 = 5.0;
/// Block rate assumed to advance the internal vibrato phase.
///
/// `targetRatio` is called once per analysis block; with the typical ~10 ms
/// hop this advances a 5 Hz vibrato correctly. The exact rate only affects
/// vibrato speed, never correction pitch.
const assumed_blocks_per_sec: f32 = 100.0;
/// Rate of the `VibratoLfo` supplying the extra humanize wander.
///
/// The LFO is configured with zero main depth, so it contributes only its
/// internal `+/-8`-cent wander at full humanize. It advances on every
/// `targetRatio` call, including unvoiced blocks, so its phase stays
/// continuous.
const lfo_rate_hz: f32 = 5.5;
/// Fraction of the remaining distance to `1.0` covered per unvoiced block.
///
/// `0.12` relaxes any in-range ratio to within `0.01` of `1.0` inside
/// 50 blocks while still audibly holding the last correction at first.
const none_drift_per_block: f32 = 0.12;
/// Fallback retune time in ms when the smoothed value is non-finite.
const default_retune_ms: f32 = 40.0;

/// Per-block correction decision: quantizer + slew + vibrato + mix.
///
/// Construct once with `init`, optionally mark note starts with `noteOn`,
/// then call `targetRatio` once per analysis block and hand the returned
/// ratio to the shifter.
pub const RetuneBrain = struct {
    smoother: SmoothedParams,
    slew: SlewLimiter,
    vibrato: VibratoLfo,
    quantizer: Quantizer,
    applied_cents: f32,
    last_ratio: f32,
    vib_phase: f32,

    /// Create a brain for `sample_rate` starting from `params`.
    ///
    /// The smoother snaps to `params` immediately, the slew starts at zero
    /// applied correction, the output starts at unity, and the vibrato LFO
    /// is fixed to a 5.5 Hz wander source with zero main depth.
    pub fn init(sample_rate: u32, params: FullParams) RetuneBrain {
        var smoother = SmoothedParams.init(sample_rate);
        smoother.reset(&params);
        var slew = SlewLimiter.init(sample_rate, saneRetuneMs(params.retune_ms));
        slew.reset(0.0);
        var vibrato = VibratoLfo.init(sample_rate);
        vibrato.setRateHz(lfo_rate_hz);
        vibrato.setDepthCents(0.0);
        vibrato.setDelayMs(0.0);
        vibrato.setHumanize(1.0);
        return .{
            .smoother = smoother,
            .slew = slew,
            .vibrato = vibrato,
            .quantizer = Quantizer.init(params.root_midi, params.scale_mask),
            .applied_cents = 0.0,
            .last_ratio = 1.0,
            .vib_phase = 0.0,
        };
    }

    /// Snap the parameter smoother and sub-stages to `p` immediately.
    ///
    /// Slew position and output ratio are intentionally kept so an explicit
    /// parameter change does not click; the smoother converges from `p`
    /// on subsequent `targetRatio` calls.
    pub fn setParams(self: *RetuneBrain, p: FullParams) void {
        self.smoother.reset(&p);
        self.slew.setRetuneMs(saneRetuneMs(p.retune_ms));
        self.quantizer.setRoot(p.root_midi);
        self.quantizer.setMask(p.scale_mask);
    }

    /// Mark a note start: restart vibrato phase and the LFO onset timer.
    ///
    /// Slew position is preserved so legato transitions keep gliding while
    /// fresh attacks get deterministic vibrato from phase zero.
    pub fn noteOn(self: *RetuneBrain) void {
        self.vibrato.noteOn();
        self.vib_phase = 0.0;
    }

    /// Decide the frequency ratio for one analysis block.
    ///
    /// `detected` is the tracker's estimate for this block and `params` the
    /// live target. Steps per call:
    ///
    /// 1. Smooth `params` and follow the smoothed scale root/mask,
    ///    retune time, humanize, transpose, and mix.
    /// 2. Advance the vibrato LFO and the internal vibrato phase. Both
    ///    always run, even on unvoiced blocks, to keep phase continuous.
    /// 3. `null` (or a non-positive/non-finite frequency): hold the last
    ///    ratio while drifting it toward `1.0` by `none_drift_per_block`,
    ///    reaching unity within 50 blocks.
    /// 4. Otherwise convert to MIDI, snap with the quantizer, add
    ///    `transpose_cents`, and slew-limit the resulting target cents by
    ///    `retune_ms`.
    /// 5. Add vibrato scaled by `humanize`: the fixed
    ///    `internal_vibrato_cents` sine plus the LFO wander.
    /// 6. Convert to a ratio and blend toward `1.0` by `mix`
    ///    (`1.0` = fully corrected, `0.0` = bypass).
    ///
    /// The returned ratio is clamped to `0.25..=4.0`. `formant_cents` and
    /// the detection `confidence` do not affect the ratio.
    pub fn targetRatio(self: *RetuneBrain, detected: ?TrackedPitch, params: *const FullParams) f32 {
        const smoothed = self.smoother.next(params);
        self.quantizer.setRoot(smoothed.root_midi);
        self.quantizer.setMask(smoothed.scale_mask);
        self.slew.setRetuneMs(saneRetuneMs(smoothed.retune_ms));
        const humanize = saneUnit(smoothed.humanize);
        const mix = saneUnit(smoothed.mix);
        const transpose = if (std.math.isFinite(smoothed.transpose_cents)) smoothed.transpose_cents else 0.0;

        const lfo_cents = self.vibrato.nextOffsetCents();
        self.vib_phase = @mod(self.vib_phase + tau * internal_vibrato_hz / assumed_blocks_per_sec, tau);

        const pitch = detected orelse return self.relax();
        const input_midi = types.hzToMidi(pitch.freq_hz) orelse return self.relax();
        if (!std.math.isFinite(input_midi)) return self.relax();
        const snapped_raw = self.quantizer.quantizeMidi(input_midi);
        const snapped = if (std.math.isFinite(snapped_raw)) snapped_raw else input_midi;
        const target_cents = (snapped - input_midi) * 100.0 + transpose;
        if (!std.math.isFinite(target_cents)) return self.relax();
        self.applied_cents = self.slew.next(self.applied_cents, target_cents);
        if (!std.math.isFinite(self.applied_cents)) self.applied_cents = 0.0;
        const lfo = if (std.math.isFinite(lfo_cents)) lfo_cents else 0.0;
        const vib_cents = humanize * (@sin(self.vib_phase) * internal_vibrato_cents + lfo);
        const full_raw = types.centsToRatio(self.applied_cents + vib_cents);
        const full = if (std.math.isFinite(full_raw)) full_raw else 1.0;
        const out = std.math.clamp(1.0 + (full - 1.0) * mix, min_ratio, max_ratio);
        self.last_ratio = out;
        return out;
    }

    /// Drift the held ratio one block toward unity.
    fn relax(self: *RetuneBrain) f32 {
        self.last_ratio = std.math.clamp(
            self.last_ratio + (1.0 - self.last_ratio) * none_drift_per_block,
            min_ratio,
            max_ratio,
        );
        return self.last_ratio;
    }
};

/// Clamp a `0..=1` control, mapping non-finite input to `0.0` (off).
fn saneUnit(value: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, 0.0, 1.0) else 0.0;
}

/// Clamp a retune time to `0..=1000` ms, mapping non-finite to the default.
fn saneRetuneMs(value: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, 0.0, 1000.0) else default_retune_ms;
}

const testing = std.testing;
const test_rate: u32 = 48_000;
const c_major_mask: u16 = 0x0AB5;

fn testParams() FullParams {
    return .{
        .retune_ms = 0.0,
        .humanize = 0.0,
        .transpose_cents = 0.0,
        .formant_cents = 0.0,
        .mix = 1.0,
        .scale_mask = 0x0FFF,
        .root_midi = 60,
    };
}

fn pitched(freq_hz: f32) ?TrackedPitch {
    return .{ .freq_hz = freq_hz, .confidence = 1.0 };
}

fn converge(brain: *RetuneBrain, freq_hz: f32, params: *const FullParams, calls: usize) f32 {
    var ratio: f32 = 1.0;
    for (0..calls) |_| ratio = brain.targetRatio(pitched(freq_hz), params);
    return ratio;
}

test "chromatic_440_is_unity" {
    const params = testParams();
    var brain = RetuneBrain.init(test_rate, params);
    const ratio = converge(&brain, 440.0, &params, 16);
    try testing.expect(@abs(ratio - 1.0) <= 0.01);
}

test "chromatic_445_stays_near_unity" {
    // Chromatic either passes through (ratio 1.0) or snaps 69.2 -> 69
    // (ratio 440/445 ~= 0.989); both sit within 0.02 of unity.
    const params = testParams();
    var brain = RetuneBrain.init(test_rate, params);
    const ratio = converge(&brain, 445.0, &params, 3000);
    try testing.expect(@abs(ratio - 1.0) <= 0.02);
}

test "c_major_466_pulls_to_neighbor" {
    var params = testParams();
    params.scale_mask = c_major_mask;
    var brain = RetuneBrain.init(test_rate, params);
    const ratio = converge(&brain, 466.16, &params, 3000);
    const down = types.midiToHz(69.0) / 466.16;
    const up = types.midiToHz(71.0) / 466.16;
    const near = @min(@abs(ratio - down), @abs(ratio - up));
    try testing.expect(near <= 0.03);
}

test "none_holds_last_then_relaxes_within_50_calls" {
    var params = testParams();
    params.scale_mask = c_major_mask;
    var brain = RetuneBrain.init(test_rate, params);
    const held = converge(&brain, 466.16, &params, 3000);
    const first = brain.targetRatio(null, &params);
    try testing.expect(@abs(first - held) <= 0.05);
    var ratio = first;
    for (1..50) |_| ratio = brain.targetRatio(null, &params);
    try testing.expect(@abs(ratio - 1.0) <= 0.01);
}

test "mix_zero_always_unity" {
    var params = testParams();
    params.mix = 0.0;
    params.scale_mask = c_major_mask;
    var brain = RetuneBrain.init(test_rate, params);
    for (0..20) |_| {
        const ratio = brain.targetRatio(pitched(466.16), &params);
        try testing.expect(@abs(ratio - 1.0) <= 1e-6);
    }
    for (0..5) |_| {
        const ratio = brain.targetRatio(null, &params);
        try testing.expect(@abs(ratio - 1.0) <= 1e-6);
    }
}

test "transpose_shifts_target" {
    var params = testParams();
    params.transpose_cents = 100.0;
    var brain = RetuneBrain.init(test_rate, params);
    const ratio = converge(&brain, 440.0, &params, 3000);
    const expected = types.centsToRatio(100.0);
    try testing.expect(@abs(ratio - expected) <= 0.02);
}

test "output_clamped_to_two_octaves" {
    var up = testParams();
    up.transpose_cents = 2400.0;
    var brain = RetuneBrain.init(test_rate, up);
    var ratio = converge(&brain, 440.0, &up, 3000);
    try testing.expect(ratio <= 4.0 and ratio >= 0.25);
    var down = testParams();
    down.transpose_cents = -2400.0;
    brain = RetuneBrain.init(test_rate, down);
    ratio = converge(&brain, 440.0, &down, 3000);
    try testing.expect(ratio <= 4.0 and ratio >= 0.25);
}

test "note_on_restarts_vibrato_without_stalling" {
    const params = testParams();
    var brain = RetuneBrain.init(test_rate, params);
    brain.noteOn();
    const ratio = converge(&brain, 440.0, &params, 16);
    try testing.expect(@abs(ratio - 1.0) <= 0.01);
    var changed = testParams();
    changed.scale_mask = c_major_mask;
    changed.mix = 0.5;
    brain.setParams(changed);
    const r2 = brain.targetRatio(pitched(440.0), &changed);
    try testing.expect(std.math.isFinite(r2) and r2 >= 0.25 and r2 <= 4.0);
}
