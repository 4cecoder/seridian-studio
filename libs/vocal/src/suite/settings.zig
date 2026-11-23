// Translated to Zig from pitchpure/crates/pitchpure_suite/src/settings.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Every audio-affecting setting of the vocal chain, plus the musical
//! helpers (scales, harmony intervals) the chain needs.
//!
//! `Settings` is plain data: the GUI edits it, the live engine and the
//! offline renderer read it, and Studio compares two of them to know when a
//! render is stale. Live-only routing (monitor on/off, devices) and
//! engine-published telemetry (`meters.Meters`) deliberately live
//! elsewhere so they never make a render look out of date.
//!
//! `Settings{}` is Rust's `Settings::default()`.

const std = @import("std");
const Division = @import("../delay.zig").Division;
const parametric_eq = @import("../parametric_eq.zig");
const DynamicEqBand = parametric_eq.DynamicEqBand;
const BAND_COUNT = parametric_eq.BAND_COUNT;
const FullParams = @import("../params.zig").FullParams;

pub const DEFAULT_RETUNE_MS: f32 = 40.0;
pub const DEFAULT_SCALE_MASK: u16 = 0x0FFF;
pub const DEFAULT_ROOT_MIDI: u8 = 60;
/// Default detector-confidence floor: rejects breath/noise, keeps voice.
pub const DEFAULT_TRACKING: f32 = 0.3;

pub const Settings = struct {
    retune_ms: f32 = DEFAULT_RETUNE_MS,
    humanize: f32 = 0.0,
    transpose_semis: f32 = 0.0,
    mix: f32 = 1.0,
    /// Pass the input through uncorrected (live A/B). Offline renders force
    /// it off, and `sameRender` ignores it.
    bypass: bool = false,
    scale: ScalePreset = .chromatic,
    root_note: u8 = DEFAULT_ROOT_MIDI,
    /// Mic pre-gain in dB before detection and correction.
    input_gain_db: f32 = 0.0,
    /// Output volume in dB.
    output_gain_db: f32 = 0.0,
    /// Formant ("throat") shift in semitones; 0 bypasses the stage.
    formant_semis: f32 = 0.0,
    /// Minimum detector confidence (`0..=1`) before a block is corrected.
    tracking: f32 = DEFAULT_TRACKING,
    // ---- vocal chain: isolate > tune > harmony > eq (each switchable)
    isolate_on: bool = true,
    /// Maximum noise reduction in dB (`0..=40`).
    isolate_db: f32 = 12.0,
    /// `0..=1`: how far above the noise floor counts as voice.
    isolate_sensitivity: f32 = 0.5,
    tune_on: bool = true,
    harmony_on: bool = false,
    harmony_mode: HarmonyMode = .third_above,
    /// Harmony voice level relative to the lead (`0..=1`).
    harmony_level: f32 = 0.5,
    eq_on: bool = true,
    eq_amount: f32 = 0.6,
    eq_low_cut_hz: f32 = 80.0,
    eq_air_db: f32 = 2.0,
    /// Per-band switches in `VoiceEq` band order.
    eq_bands: [5]bool = @splat(true),
    /// Keep the adaptive vocal polish separate from the manual graph EQ.
    eq_auto_on: bool = true,
    eq_manual_on: bool = false,
    eq_manual_bands: [BAND_COUNT]DynamicEqBand = DynamicEqBand.vocalDefaults(),
    // ---- dynamics: de-ess > rider > compressor > tape > (output) > limiter
    dynamics_on: bool = true,
    // Off by default: existing takes and renders sound unchanged.
    deess_on: bool = false,
    deess_freq_hz: f32 = 6500.0,
    deess_threshold_db: f32 = -30.0,
    deess_range_db: f32 = 8.0,
    /// Hear only what the de-esser is catching.
    deess_listen: bool = false,
    comp_on: bool = false,
    comp_threshold_db: f32 = -18.0,
    comp_ratio: f32 = 3.0,
    comp_knee_db: f32 = 6.0,
    comp_attack_ms: f32 = 10.0,
    comp_release_ms: f32 = 120.0,
    comp_makeup_db: f32 = 0.0,
    comp_mix: f32 = 1.0,
    rider_on: bool = true,
    rider_target_db: f32 = -18.0,
    rider_range_db: f32 = 6.0,
    rider_speed: f32 = 0.5,
    tape_on: bool = true,
    tape_drive: f32 = 0.2,
    tape_wow: f32 = 0.0,
    limiter_on: bool = true,
    limiter_ceiling_db: f32 = -1.0,
    limiter_drive_db: f32 = 0.0,
    // ---- space: delay + reverb
    space_on: bool = true,
    delay_on: bool = false,
    delay_bpm: f32 = 120.0,
    delay_division: Division = .eighth,
    delay_feedback: f32 = 0.35,
    delay_mix: f32 = 0.2,
    delay_duck: f32 = 0.6,
    delay_tone: f32 = 0.5,
    reverb_on: bool = true,
    reverb_mix: f32 = 0.15,
    reverb_decay_s: f32 = 1.8,
    reverb_predelay_ms: f32 = 30.0,
    reverb_size: f32 = 0.6,
    reverb_duck: f32 = 0.3,

    /// Field-wise equality, matching Rust's derived `PartialEq` (floats by
    /// `==`, so a NaN field never compares equal).
    pub fn eql(a: *const Settings, b: *const Settings) bool {
        return std.meta.eql(a.*, b.*);
    }

    /// Would rendering with `other` produce the same audio? (Bypass is a
    /// live monitoring switch; offline renders always process.)
    pub fn sameRender(self: *const Settings, other: *const Settings) bool {
        var a = self.*;
        var b = other.*;
        a.bypass = false;
        b.bypass = false;
        return a.eql(&b);
    }

    /// The `R` shortcut: put the tuning and level controls back to default
    /// (chain switches, EQ and FX are left as they are).
    pub fn resetControls(self: *Settings) void {
        const d: Settings = .{};
        self.retune_ms = d.retune_ms;
        self.humanize = d.humanize;
        self.transpose_semis = d.transpose_semis;
        self.mix = d.mix;
        self.bypass = d.bypass;
        self.input_gain_db = d.input_gain_db;
        self.output_gain_db = d.output_gain_db;
        self.formant_semis = d.formant_semis;
        self.tracking = d.tracking;
    }
};

/// Scale presets. Masks are relative to the root (bit `i` = `i` semitones
/// above it), so every preset works in any key; `custom` holds a hand-picked
/// mask from the on-screen keyboard.
pub const ScalePreset = union(enum) {
    chromatic,
    major,
    minor,
    harmonic_minor,
    major_pentatonic,
    minor_pentatonic,
    blues,
    dorian,
    mixolydian,
    custom: u16,

    pub const NAMED = [9]ScalePreset{
        .chromatic,
        .major,
        .minor,
        .harmonic_minor,
        .major_pentatonic,
        .minor_pentatonic,
        .blues,
        .dorian,
        .mixolydian,
    };

    pub fn mask(self: ScalePreset) u16 {
        return switch (self) {
            .chromatic => 0x0FFF,
            .major => 0x0AB5,
            .minor => 0x05AD,
            .harmonic_minor => 0x09AD,
            .major_pentatonic => 0x0295,
            .minor_pentatonic => 0x04A9,
            .blues => 0x04E9,
            .dorian => 0x06AD,
            .mixolydian => 0x06B5,
            .custom => |m| m & 0x0FFF,
        };
    }

    /// Named preset for `mask`, else `custom`; an empty mask falls back to
    /// chromatic because it would allow no notes at all.
    pub fn fromMask(mask_in: u16) ScalePreset {
        const m = mask_in & 0x0FFF;
        if (m == 0) return .chromatic;
        for (NAMED) |preset| {
            if (preset.mask() == m) return preset;
        }
        return .{ .custom = m };
    }

    pub fn name(self: ScalePreset) []const u8 {
        return switch (self) {
            .chromatic => "Chromatic",
            .major => "Major",
            .minor => "Minor",
            .harmonic_minor => "Harmonic Minor",
            .major_pentatonic => "Major Pentatonic",
            .minor_pentatonic => "Minor Pentatonic",
            .blues => "Blues",
            .dorian => "Dorian",
            .mixolydian => "Mixolydian",
            .custom => "Custom",
        };
    }
};

pub const RetunePreset = enum {
    fast,
    natural,
    slow,

    pub fn ms(self: RetunePreset) f32 {
        return switch (self) {
            .fast => 5.0,
            .natural => 40.0,
            .slow => 200.0,
        };
    }

    pub fn label(self: RetunePreset) []const u8 {
        return switch (self) {
            .fast => "Fast · 5ms",
            .natural => "Natural · 40ms",
            .slow => "Slow · 200ms",
        };
    }

    pub fn all() [3]RetunePreset {
        return .{ .fast, .natural, .slow };
    }
};

/// Harmony voicing; intervals are scale degrees in the current key, so a
/// "third" is major or minor as the scale demands.
pub const HarmonyMode = enum {
    third_above,
    third_below,
    third_and_fifth,
    fifth_above,
    octave_below,

    pub const ALL = [5]HarmonyMode{ .third_above, .third_below, .third_and_fifth, .fifth_above, .octave_below };

    pub fn label(self: HarmonyMode) []const u8 {
        return switch (self) {
            .third_above => "3RD UP",
            .third_below => "3RD DOWN",
            .third_and_fifth => "3RD + 5TH",
            .fifth_above => "5TH UP",
            .octave_below => "OCT DOWN",
        };
    }

    pub fn voices(self: HarmonyMode) [2]?Interval {
        return switch (self) {
            .third_above => .{ .{ .degrees = 2 }, null },
            .third_below => .{ .{ .degrees = -2 }, null },
            .third_and_fifth => .{ .{ .degrees = 2 }, .{ .degrees = 4 } },
            .fifth_above => .{ .{ .degrees = 4 }, null },
            .octave_below => .{ .{ .semis = -12 }, null },
        };
    }
};

/// One harmony voice's distance from the lead.
pub const Interval = union(enum) {
    /// Scale degrees (`2` = a third above, `-2` = a third below).
    degrees: i32,
    /// Fixed semitones regardless of scale.
    semis: i32,
};

/// Semitones from `note` to its harmony at `interval` within the scale
/// (`mask` relative to `root`). Chromatic has no diatonic thirds, so it
/// uses major-third / perfect-fifth shapes.
pub fn harmonySemis(note: i32, interval: Interval, mask_in: u16, root: u8) i32 {
    const degrees = switch (interval) {
        .semis => |semis| return semis,
        .degrees => |d| d,
    };
    const m = mask_in & 0x0FFF;
    if (m == 0x0FFF or m == 0) {
        return switch (degrees) {
            2 => 4,
            -2 => -3,
            4 => 7,
            -4 => -5,
            else => |d| d * 2,
        };
    }
    const root_class: i32 = root % 12;
    // Integer signum (Rust `i32::signum`: 0 for 0).
    const dir: i32 = if (degrees > 0) 1 else if (degrees < 0) -1 else 0;
    const target: i32 = @intCast(@abs(degrees));
    var step: i32 = 0;
    var found: i32 = 0;
    while (found < target and @abs(step) < 24) {
        step += dir;
        const class: u4 = @intCast(@mod(note + step - root_class, 12));
        if (m & (@as(u16, 1) << class) != 0) found += 1;
    }
    return step;
}

pub fn dbToGain(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

pub fn makeParams(retune_ms: f32, scale_mask: u16, root_midi: u8) FullParams {
    return .{
        .retune_ms = retune_ms,
        .humanize = 0.0,
        .transpose_cents = 0.0,
        .formant_cents = 0.0,
        .mix = 1.0,
        .scale_mask = scale_mask,
        .root_midi = root_midi,
    };
}

const testing = std.testing;

test "harmony_thirds_follow_the_scale" {
    const major = (ScalePreset{ .major = {} }).mask();
    const c4 = 60;
    // C major, root C: C->E is a major third, D->F and E->G minor thirds.
    try testing.expectEqual(@as(i32, 4), harmonySemis(c4, .{ .degrees = 2 }, major, 60));
    try testing.expectEqual(@as(i32, 3), harmonySemis(62, .{ .degrees = 2 }, major, 60));
    try testing.expectEqual(@as(i32, 3), harmonySemis(64, .{ .degrees = 2 }, major, 60));
    // Third below C is A; fifth above B is F (diminished, in key).
    try testing.expectEqual(@as(i32, -3), harmonySemis(c4, .{ .degrees = -2 }, major, 60));
    try testing.expectEqual(@as(i32, 6), harmonySemis(71, .{ .degrees = 4 }, major, 60));
    // Chromatic falls back to major third / perfect fifth shapes.
    try testing.expectEqual(@as(i32, 4), harmonySemis(61, .{ .degrees = 2 }, 0x0FFF, 60));
    try testing.expectEqual(@as(i32, 7), harmonySemis(61, .{ .degrees = 4 }, 0x0FFF, 60));
    try testing.expectEqual(@as(i32, -12), harmonySemis(61, .{ .semis = -12 }, major, 60));
}
