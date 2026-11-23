// Translated to Zig from pitchpure/crates/pitchpure_engine/src/vibrato.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Sine vibrato LFO with delayed fade-in and deterministic humanize wander.
//!
//! `VibratoLfo` produces a per-sample pitch offset in cents. The main
//! oscillator is a sine at the configured rate scaled by the configured depth
//! and a delay/fade envelope that restarts on every `noteOn`. An optional
//! humanize wander adds a slow second motion built from a 0.37 Hz sine plus a
//! deterministic counter-hash noise source, so repeated runs are bit-identical.

const std = @import("std");

const tau: f32 = std.math.tau;

/// Maximum vibrato rate in Hz.
const max_rate_hz: f32 = 12.0;
/// Maximum vibrato depth in cents.
const max_depth_cents: f32 = 200.0;
/// Maximum onset delay in milliseconds.
const max_delay_ms: f32 = 2000.0;
/// Humanize second-LFO rate in Hz.
const human_rate_hz: f32 = 0.37;
/// Humanize peak wander in cents at amount `1.0`.
const human_max_cents: f32 = 8.0;
/// Linear fade-in length after the delay expires, in milliseconds.
const fade_ms: f32 = 500.0;
/// Smooth-noise interpolation block in samples (~46 ms at 44.1 kHz).
const noise_block: u64 = 2048;

/// Clamp a setter value to `0..=max`, mapping NaN to `0.0`.
fn clampUnit(value: f32, max: f32) f32 {
    if (std.math.isNan(value)) return 0.0;
    return std.math.clamp(value, 0.0, max);
}

/// Deterministic bipolar noise in `-1..=1` from a counter value
/// (SplitMix64 finalizer; the high 32 bits are scaled to `[-1, 1]`).
fn hashBipolar(n: u64) f32 {
    var z = n +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    const mixed = z ^ (z >> 31);
    const bits: u32 = @truncate(mixed >> 32);
    const max: f32 = @floatFromInt(std.math.maxInt(u32));
    return (@as(f32, @floatFromInt(bits)) / max) * 2.0 - 1.0;
}

/// Slowly varying noise in `-1..=1` by linearly interpolating hash values
/// over `noise_block`-sample segments.
fn smoothNoise(counter: u64) f32 {
    const block = counter / noise_block;
    const frac = @as(f32, @floatFromInt(counter % noise_block)) / @as(f32, @floatFromInt(noise_block));
    const a = hashBipolar(block);
    const b = hashBipolar(block +% 1);
    return a + (b - a) * frac;
}

/// Sine vibrato low-frequency oscillator rendering cents offsets.
/// Call `nextOffsetCents` once per sample.
pub const VibratoLfo = struct {
    sample_rate: u32,
    rate_hz: f32 = 0.0,
    depth_cents: f32 = 0.0,
    delay_ms: f32 = 0.0,
    humanize: f32 = 0.0,
    phase: f32 = 0.0,
    human_phase: f32 = 0.0,
    elapsed_samples: u64 = 0,

    /// Create a silent LFO (rate, depth, delay, humanize all 0). A
    /// `sample_rate` of 0 is treated as 1 internally.
    pub fn init(sample_rate: u32) VibratoLfo {
        return .{ .sample_rate = sample_rate };
    }

    /// Set the vibrato rate in Hz, clamped to `0..=12`. `0` disables the LFO.
    pub fn setRateHz(self: *VibratoLfo, hz: f32) void {
        self.rate_hz = clampUnit(hz, max_rate_hz);
    }

    /// Set the vibrato depth in cents, clamped to `0..=200`.
    pub fn setDepthCents(self: *VibratoLfo, cents: f32) void {
        self.depth_cents = clampUnit(cents, max_depth_cents);
    }

    /// Set the note-onset delay in milliseconds, clamped to `0..=2000`.
    /// Output stays 0 for the delay, then fades in linearly over 500 ms.
    pub fn setDelayMs(self: *VibratoLfo, ms: f32) void {
        self.delay_ms = clampUnit(ms, max_delay_ms);
    }

    /// Set the humanize amount, clamped to `0..=1` (up to +/-8 cents wander).
    pub fn setHumanize(self: *VibratoLfo, amount: f32) void {
        self.humanize = clampUnit(amount, 1.0);
    }

    /// Restart the note: reset main/human phase and the delay timer.
    pub fn noteOn(self: *VibratoLfo) void {
        self.phase = 0.0;
        self.human_phase = 0.0;
        self.elapsed_samples = 0;
    }

    fn sampleRateF(self: *const VibratoLfo) f32 {
        return @floatFromInt(@max(self.sample_rate, 1));
    }

    /// Current onset envelope in `0..=1`.
    fn envelope(self: *const VibratoLfo) f32 {
        if (self.delay_ms <= 0.0) return 1.0;
        const sr = self.sampleRateF();
        const delay_samples = self.delay_ms * sr / 1000.0;
        const fade_samples = fade_ms * sr / 1000.0;
        const elapsed: f32 = @floatFromInt(self.elapsed_samples);
        if (elapsed < delay_samples) return 0.0;
        if (elapsed >= delay_samples + fade_samples) return 1.0;
        return (elapsed - delay_samples) / fade_samples;
    }

    fn advancePhases(self: *VibratoLfo) void {
        const sr = self.sampleRateF();
        self.phase = @mod(self.phase + tau * self.rate_hz / sr, tau);
        self.human_phase = @mod(self.human_phase + tau * human_rate_hz / sr, tau);
        self.elapsed_samples +%= 1;
    }

    /// Render and advance one sample, returning the offset in cents.
    /// Returns exactly `0.0` while the rate is 0 or the envelope is in its
    /// delay hold.
    pub fn nextOffsetCents(self: *VibratoLfo) f32 {
        if (self.rate_hz <= 0.0) {
            self.elapsed_samples +%= 1;
            return 0.0;
        }
        const env = self.envelope();
        if (env <= 0.0) {
            self.advancePhases();
            return 0.0;
        }
        const main = @sin(self.phase) * self.depth_cents * env;
        const wander: f32 = if (self.humanize <= 0.0) 0.0 else blk: {
            const slow = @sin(self.human_phase);
            const noise = smoothNoise(self.elapsed_samples);
            break :blk self.humanize * human_max_cents * 0.5 * (slow + noise) * env;
        };
        self.advancePhases();
        return main + wander;
    }
};

const testing = std.testing;

test "rate_zero_always_zero" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(0.0);
    lfo.setDepthCents(100.0);
    lfo.noteOn();
    for (0..44100) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
}

test "rate_zero_with_humanize_still_zero" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(0.0);
    lfo.setDepthCents(100.0);
    lfo.setHumanize(1.0);
    lfo.noteOn();
    for (0..1024) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
}

test "five_half_hz_100cents_reaches_peaks" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(5.5);
    lfo.setDepthCents(100.0);
    lfo.noteOn();
    var min = std.math.inf(f32);
    var max = -std.math.inf(f32);
    for (0..44100) |_| {
        const v = lfo.nextOffsetCents();
        min = @min(min, v);
        max = @max(max, v);
    }
    try testing.expect(@abs(min + 100.0) <= 2.0);
    try testing.expect(@abs(max - 100.0) <= 2.0);
}

test "delay_500ms_first_04s_all_zeros" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(5.5);
    lfo.setDepthCents(100.0);
    lfo.setDelayMs(500.0);
    lfo.noteOn();
    const n: usize = @intFromFloat(@as(f32, 44100.0) * 0.4);
    for (0..n) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
}

test "delay_fades_in_after_hold" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(5.5);
    lfo.setDepthCents(100.0);
    lfo.setDelayMs(100.0);
    lfo.noteOn();
    const delay_n: usize = @intFromFloat(@as(f32, 44100.0) * 0.1);
    for (0..delay_n) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
    var nonzero = false;
    for (0..44100) |_| {
        if (lfo.nextOffsetCents() != 0.0) {
            nonzero = true;
            break;
        }
    }
    try testing.expect(nonzero);
}

test "humanize_makes_consecutive_periods_differ" {
    const gpa = testing.allocator;
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(5.5);
    lfo.setDepthCents(100.0);
    lfo.setHumanize(1.0);
    lfo.noteOn();
    const first = try gpa.alloc(f32, 44100);
    defer gpa.free(first);
    const second = try gpa.alloc(f32, 44100);
    defer gpa.free(second);
    for (first) |*v| v.* = lfo.nextOffsetCents();
    for (second) |*v| v.* = lfo.nextOffsetCents();
    var any = false;
    for (first, second) |a, b| {
        if (@abs(a - b) > 1e-3) {
            any = true;
            break;
        }
    }
    try testing.expect(any);
}

test "setters_clamp_to_documented_ranges" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(-3.0);
    lfo.setDepthCents(100.0);
    lfo.noteOn();
    for (0..64) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
    lfo.setRateHz(99.0);
    lfo.setDepthCents(500.0);
    lfo.setDelayMs(9999.0);
    lfo.setHumanize(99.0);
    lfo.noteOn();
    for (0..100) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
    var peak: f32 = 0.0;
    for (100..160000) |_| peak = @max(peak, @abs(lfo.nextOffsetCents()));
    try testing.expect(peak <= 208.0 + 1e-3);
    try testing.expect(peak > 50.0);
}

test "note_on_resets_delay_timer" {
    var lfo = VibratoLfo.init(44100);
    lfo.setRateHz(5.5);
    lfo.setDepthCents(100.0);
    lfo.setDelayMs(200.0);
    lfo.noteOn();
    for (0..44100) |_| _ = lfo.nextOffsetCents();
    lfo.noteOn();
    for (0..100) |_| try testing.expectEqual(@as(f32, 0.0), lfo.nextOffsetCents());
}
