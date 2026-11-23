//! DSP Library
//!
//! Comprehensive digital signal processing library for audio synthesis, analysis, and effects.
//! All modules are designed for real-time, zero-allocation processing.
//!
//! ## Module Categories
//!
//! ### Synthesis
//! - **oscillator**: Band-limited oscillators and basic waveforms
//! - **wavetable**: Multi-octave band-limited wavetable oscillators
//! - **envelope**: ADSR and AR envelope generators
//! - **voice**: Polyphonic voice management
//! - **physical**: Karplus-Strong, waveguides, bowed strings
//! - **modal**: Modal synthesis (bells, bars, drums, plates)
//! - **granular**: Granular synthesis and freeze effects
//!
//! ### Filters
//! - **filter**: Biquad and state-variable filters
//! - **analog_filter**: Moog ladder, TB-303, formant filters
//!
//! ### Effects & Processing
//! - **distortion**: Wavefolder, soft clip, bitcrusher, slew limiter
//! - **dynamics**: Compressor, limiter, gate, expander, transient shaper
//! - **reverb**: Schroeder, Freeverb, plate, spring reverbs
//! - **stereo**: Width control, M/S processing, enhancer, auto-pan
//! - **pitch**: Pitch detection (YIN, autocorrelation) and correction
//! - **phase_vocoder**: STFT-based time stretching and pitch shifting
//! - **formant**: LPC-based formant analysis and preservation
//! - **resample**: High-quality sample rate conversion (sinc, cubic, linear)
//!
//! ### Analysis
//! - **spectral**: Spectral descriptors, MFCC, chroma features
//! - **onset**: Onset detection, beat tracking, tempo estimation
//! - **loop_tempo**: Loop classification and tempo estimation (Audacity algorithm)
//!
//! ### Utilities
//! - **core**: Ring buffers, windows, interpolation, smoothing
//!
//! ## Patent Status
//!
//! All algorithms implemented here are based on:
//! - Expired patents (e.g., US5973252A Auto-Tune, expired 2018)
//! - Public domain algorithms (PSOLA, phase vocoder, FFT, Karplus-Strong)
//! - Patent-free academic publications (YIN, MFCC, chroma)
//! - Explicitly unpatented works (WORLD vocoder)
//! - Open-source references (Mutable Instruments, STK, librosa, Essentia)
//!

// =============================================================================
// Core Modules
// =============================================================================

// Synthesis
pub const oscillator = @import("oscillator.zig");
pub const wavetable = @import("wavetable.zig");
pub const envelope = @import("envelope.zig");
pub const voice = @import("voice.zig");
pub const physical = @import("physical.zig");
pub const modal = @import("modal.zig");
pub const granular = @import("granular.zig");

// Filters
pub const filter = @import("filter.zig");
pub const analog_filter = @import("analog_filter.zig");

// Effects & Processing
pub const distortion = @import("distortion.zig");
pub const dynamics = @import("dynamics.zig");
pub const reverb = @import("reverb.zig");
pub const stereo = @import("stereo.zig");
pub const pitch = @import("pitch.zig");
pub const phase_vocoder = @import("phase_vocoder.zig");
pub const formant = @import("formant.zig");
pub const resample = @import("resample.zig");

// Analysis
pub const spectral = @import("spectral.zig");
pub const onset = @import("onset.zig");
pub const loop_tempo = @import("loop_tempo.zig");

// Utilities
pub const core = @import("core.zig");
pub const utils = @import("utils.zig");

// Re-export commonly used types
pub const Oscillator = oscillator.Oscillator;
pub const BLEPOscillator = oscillator.BLEPOscillator;
pub const Waveform = oscillator.Waveform;

pub const ADSREnvelope = envelope.ADSREnvelope;
pub const AREnvelope = envelope.AREnvelope;
pub const EnvelopeState = envelope.EnvelopeState;

pub const BiquadFilter = filter.BiquadFilter;
pub const SVFilter = filter.SVFilter;
pub const FilterType = filter.FilterType;

pub const Voice = voice.Voice;
pub const VoiceState = voice.VoiceState;
pub const VoicePool = voice.VoicePool;

// Pitch detection and correction
pub const Yin = pitch.Yin;
pub const Autocorrelation = pitch.Autocorrelation;
pub const TdPsola = pitch.TdPsola;
pub const PitchCorrector = pitch.PitchCorrector;
pub const Scale = pitch.Scale;

// Phase vocoder
pub const PhaseVocoder = phase_vocoder.PhaseVocoder;
pub const Complex = phase_vocoder.Complex;
pub const WindowType = phase_vocoder.WindowType;

// Formant processing
pub const LpcAnalyzer = formant.LpcAnalyzer;
pub const FormantTracker = formant.FormantTracker;
pub const FormantPreservingShifter = formant.FormantPreservingShifter;

// Pitch utilities
pub const freqToMidi = pitch.freqToMidi;
pub const midiToFreq = pitch.midiToFreq;
pub const freqToCents = pitch.freqToCents;
pub const centsToRatio = pitch.centsToRatio;
pub const nearestMidiNote = pitch.nearestMidiNote;

// Loop tempo estimation
pub const LoopTempoEstimator = loop_tempo.LoopTempoEstimator;
pub const LoopTempoResult = loop_tempo.LoopTempoResult;
pub const estimateLoopTempo = loop_tempo.estimateLoopTempo;
pub const snapToCommonTempo = loop_tempo.snapToCommonTempo;

// Analog filters
pub const MoogLadder = analog_filter.MoogLadder;
pub const MoogLadderHuovilainen = analog_filter.MoogLadderHuovilainen;
pub const TB303Filter = analog_filter.TB303Filter;
pub const FormantFilter = analog_filter.FormantFilter;
pub const OberheimSVF = analog_filter.OberheimSVF;
pub const Vowels = analog_filter.Vowels;

// Distortion
pub const Wavefolder = distortion.Wavefolder;
pub const SoftClipper = distortion.SoftClipper;
pub const HardClipper = distortion.HardClipper;
pub const Bitcrusher = distortion.Bitcrusher;
pub const SlewLimiter = distortion.SlewLimiter;
pub const TanhSaturator = distortion.TanhSaturator;
pub const ChebyshevShaper = distortion.ChebyshevShaper;

// Dynamics
pub const Compressor = dynamics.Compressor;
pub const Limiter = dynamics.Limiter;
pub const Gate = dynamics.Gate;
pub const Expander = dynamics.Expander;
pub const TransientShaper = dynamics.TransientShaper;
pub const EnvelopeFollower = dynamics.EnvelopeFollower;

// Reverb
pub const SchroederReverb = reverb.SchroederReverb;
pub const Freeverb = reverb.Freeverb;
pub const PlateReverb = reverb.PlateReverb;
pub const SpringReverb = reverb.SpringReverb;
pub const EarlyReflections = reverb.EarlyReflections;

// Stereo processing
pub const StereoSample = stereo.StereoSample;
pub const MidSideProcessor = stereo.MidSideProcessor;
pub const StereoWidth = stereo.StereoWidth;
pub const StereoEnhancer = stereo.StereoEnhancer;
pub const AutoPan = stereo.AutoPan;
pub const CorrelationMeter = stereo.CorrelationMeter;
pub const PanLaw = stereo.PanLaw;
pub const panGains = stereo.panGains;
pub const encodeMS = stereo.encodeMS;
pub const decodeMS = stereo.decodeMS;

// Granular processing
pub const GranularPitchShifter = granular.GranularPitchShifter;
pub const GranularTimeStretcher = granular.GranularTimeStretcher;
pub const GranularFreeze = granular.GranularFreeze;

// Wavetable synthesis
pub const WavetableOscillator = wavetable.WavetableOscillator;
pub const BandLimitedWave = wavetable.BandLimitedWave;
pub const PulseOscillator = wavetable.PulseOscillator;
pub const SuperSaw = wavetable.SuperSaw;
pub const WavetableBank = wavetable.WavetableBank;

// Utility functions
pub const midiNoteToFreq = oscillator.midiNoteToFreq;
pub const sine = oscillator.sine;
pub const triangle = oscillator.triangle;
pub const sawBL = oscillator.sawBL;
pub const squareBL = oscillator.squareBL;

// =============================================================================
// Common DSP utilities
// =============================================================================

/// Soft clip to prevent harsh distortion
pub fn softClip(x: f32) f32 {
    // Smooth tanh-like soft clipping
    if (x > 2.0) return 1.0;
    if (x < -2.0) return -1.0;

    const x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

/// Hard clip (limiting)
pub fn hardClip(x: f32, threshold: f32) f32 {
    return @max(-threshold, @min(threshold, x));
}

/// Linear interpolation
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Convert decibels to linear amplitude
pub const dbToLinear = utils.dbToLinear;

/// Convert linear amplitude to decibels
pub const linearToDb = utils.linearToDb;

/// Convert milliseconds to samples
pub fn msToSamples(ms: f32, sample_rate: f32) f32 {
    return ms * sample_rate / 1000.0;
}

/// Convert samples to milliseconds
pub fn samplesToMs(samples: f32, sample_rate: f32) f32 {
    return samples * 1000.0 / sample_rate;
}

/// Pan law: constant power panning
/// pan: -1.0 (left) to 1.0 (right)
/// Returns (left_gain, right_gain)
pub fn panConstantPower(pan: f32) struct { left: f32, right: f32 } {
    const std = @import("std");
    const angle = (pan + 1.0) * std.math.pi / 4.0; // 0 to pi/2
    return .{
        .left = @cos(angle),
        .right = @sin(angle),
    };
}

// =============================================================================
// Tests
// =============================================================================

// =============================================================================
// Comprehensive DSP Utility Function Tests
// =============================================================================

test "softClip - values within range are slightly saturated" {
    const testing = @import("std").testing;

    // Small values are almost transparent
    try testing.expectApproxEqAbs(@as(f32, 0.1), softClip(0.1), 0.01);

    // Middle values have slight saturation
    const s05 = softClip(0.5);
    try testing.expect(s05 < 0.5);
    try testing.expect(s05 > 0.4);

    // 1.0 is significantly saturated
    const s10 = softClip(1.0);
    try testing.expect(s10 < 1.0);
    try testing.expect(s10 > 0.7);
}

test "softClip - values above range are clipped smoothly" {
    const testing = @import("std").testing;

    // Test positive clipping behavior
    const clip1 = softClip(1.5);
    const clip2 = softClip(2.0);
    const clip3 = softClip(5.0);
    const clip4 = softClip(10.0);

    // All clipped values should be <= 1.0
    try testing.expect(clip1 <= 1.0);
    try testing.expect(clip2 <= 1.0);
    try testing.expect(clip3 <= 1.0);
    try testing.expect(clip4 <= 1.0);

    // Larger values should reach or stay at 1.0
    try testing.expect(clip4 >= clip3);
    try testing.expect(clip3 >= clip2);
    try testing.expect(clip2 > clip1);
}

test "softClip - values below range are clipped smoothly" {
    const testing = @import("std").testing;

    // Test negative clipping behavior
    const clip1 = softClip(-1.5);
    const clip2 = softClip(-2.0);
    const clip3 = softClip(-5.0);
    const clip4 = softClip(-10.0);

    // All clipped values should be >= -1.0
    try testing.expect(clip1 >= -1.0);
    try testing.expect(clip2 >= -1.0);
    try testing.expect(clip3 >= -1.0);
    try testing.expect(clip4 >= -1.0);

    // Larger negative values should reach or stay at -1.0
    try testing.expect(clip4 <= clip3);
    try testing.expect(clip3 <= clip2);
    try testing.expect(clip2 < clip1);
}

test "softClip - symmetry" {
    const testing = @import("std").testing;

    // Soft clip should be symmetric: softClip(x) = -softClip(-x)
    try testing.expectApproxEqAbs(softClip(0.5), -softClip(-0.5), 0.0001);
    try testing.expectApproxEqAbs(softClip(1.5), -softClip(-1.5), 0.0001);
    try testing.expectApproxEqAbs(softClip(2.0), -softClip(-2.0), 0.0001);
    try testing.expectApproxEqAbs(softClip(10.0), -softClip(-10.0), 0.0001);
}

test "hardClip - values within threshold pass through" {
    const testing = @import("std").testing;

    // Test with threshold of 1.0
    try testing.expectApproxEqAbs(@as(f32, 0.0), hardClip(0.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hardClip(0.5, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), hardClip(-0.5, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hardClip(1.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), hardClip(-1.0, 1.0), 0.0001);

    // Test with different threshold (0.5)
    try testing.expectApproxEqAbs(@as(f32, 0.25), hardClip(0.25, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.25), hardClip(-0.25, 0.5), 0.0001);
}

test "hardClip - values above threshold are clipped" {
    const testing = @import("std").testing;

    // Test positive clipping with threshold 1.0
    try testing.expectApproxEqAbs(@as(f32, 1.0), hardClip(1.5, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hardClip(2.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hardClip(10.0, 1.0), 0.0001);

    // Test with threshold 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), hardClip(0.75, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hardClip(1.0, 0.5), 0.0001);
}

test "hardClip - values below threshold are clipped" {
    const testing = @import("std").testing;

    // Test negative clipping with threshold 1.0
    try testing.expectApproxEqAbs(@as(f32, -1.0), hardClip(-1.5, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), hardClip(-2.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), hardClip(-10.0, 1.0), 0.0001);

    // Test with threshold 0.5
    try testing.expectApproxEqAbs(@as(f32, -0.5), hardClip(-0.75, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), hardClip(-1.0, 0.5), 0.0001);
}

test "hardClip - different thresholds" {
    const testing = @import("std").testing;

    const input: f32 = 2.0;
    try testing.expectApproxEqAbs(@as(f32, 0.1), hardClip(input, 0.1), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hardClip(input, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hardClip(input, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), hardClip(input, 2.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), hardClip(input, 5.0), 0.0001);
}

test "dbToLinear - common dB values" {
    const testing = @import("std").testing;

    // 0 dB = 1.0 (unity gain)
    try testing.expectApproxEqAbs(@as(f32, 1.0), dbToLinear(0.0), 0.0001);

    // -6.0206 dB ≈ 0.5 (half amplitude)
    try testing.expectApproxEqAbs(@as(f32, 0.5), dbToLinear(-6.0206), 0.001);

    // -12 dB ≈ 0.25 (quarter amplitude)
    try testing.expectApproxEqAbs(@as(f32, 0.25), dbToLinear(-12.04), 0.01);

    // -20 dB = 0.1 (one tenth amplitude)
    try testing.expectApproxEqAbs(@as(f32, 0.1), dbToLinear(-20.0), 0.001);

    // -40 dB = 0.01
    try testing.expectApproxEqAbs(@as(f32, 0.01), dbToLinear(-40.0), 0.0001);

    // -60 dB = 0.001
    try testing.expectApproxEqAbs(@as(f32, 0.001), dbToLinear(-60.0), 0.00001);

    // +6 dB ≈ 2.0 (double amplitude)
    try testing.expectApproxEqAbs(@as(f32, 2.0), dbToLinear(6.0206), 0.01);

    // +12 dB ≈ 4.0
    try testing.expectApproxEqAbs(@as(f32, 4.0), dbToLinear(12.04), 0.05);

    // +20 dB = 10.0
    try testing.expectApproxEqAbs(@as(f32, 10.0), dbToLinear(20.0), 0.01);
}

test "linearToDb - common linear values" {
    const testing = @import("std").testing;

    // 1.0 = 0 dB
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToDb(1.0), 0.0001);

    // 0.5 ≈ -6.02 dB
    try testing.expectApproxEqAbs(@as(f32, -6.0206), linearToDb(0.5), 0.01);

    // 0.25 ≈ -12.04 dB
    try testing.expectApproxEqAbs(@as(f32, -12.04), linearToDb(0.25), 0.05);

    // 0.1 = -20 dB
    try testing.expectApproxEqAbs(@as(f32, -20.0), linearToDb(0.1), 0.01);

    // 0.01 = -40 dB
    try testing.expectApproxEqAbs(@as(f32, -40.0), linearToDb(0.01), 0.01);

    // 2.0 ≈ +6.02 dB
    try testing.expectApproxEqAbs(@as(f32, 6.0206), linearToDb(2.0), 0.01);

    // 10.0 = +20 dB
    try testing.expectApproxEqAbs(@as(f32, 20.0), linearToDb(10.0), 0.01);
}

test "linearToDb - zero and negative values" {
    const testing = @import("std").testing;

    // Zero should return minimum dB (-120)
    try testing.expectApproxEqAbs(@as(f32, -120.0), linearToDb(0.0), 0.0001);

    // Negative values should return minimum dB (-120)
    try testing.expectApproxEqAbs(@as(f32, -120.0), linearToDb(-0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -120.0), linearToDb(-1.0), 0.0001);
}

test "dbToLinear and linearToDb - round trip conversion" {
    const testing = @import("std").testing;

    // Test round trip: dB -> linear -> dB
    try testing.expectApproxEqAbs(@as(f32, 0.0), linearToDb(dbToLinear(0.0)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -6.0), linearToDb(dbToLinear(-6.0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, -12.0), linearToDb(dbToLinear(-12.0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, -20.0), linearToDb(dbToLinear(-20.0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 6.0), linearToDb(dbToLinear(6.0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 12.0), linearToDb(dbToLinear(12.0)), 0.01);

    // Test round trip: linear -> dB -> linear
    try testing.expectApproxEqAbs(@as(f32, 1.0), dbToLinear(linearToDb(1.0)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dbToLinear(linearToDb(0.5)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), dbToLinear(linearToDb(0.1)), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), dbToLinear(linearToDb(2.0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10.0), dbToLinear(linearToDb(10.0)), 0.01);
}

test "msToSamples - at 44.1 kHz" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 44100.0;

    // 1 ms = 44.1 samples at 44.1 kHz
    try testing.expectApproxEqAbs(@as(f32, 44.1), msToSamples(1.0, sample_rate), 0.1);

    // 10 ms = 441 samples
    try testing.expectApproxEqAbs(@as(f32, 441.0), msToSamples(10.0, sample_rate), 0.1);

    // 100 ms = 4410 samples
    try testing.expectApproxEqAbs(@as(f32, 4410.0), msToSamples(100.0, sample_rate), 1.0);

    // 1000 ms (1 second) = 44100 samples
    try testing.expectApproxEqAbs(@as(f32, 44100.0), msToSamples(1000.0, sample_rate), 1.0);

    // 0.5 ms = 22.05 samples
    try testing.expectApproxEqAbs(@as(f32, 22.05), msToSamples(0.5, sample_rate), 0.1);
}

test "msToSamples - at 48 kHz" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 48000.0;

    // 1 ms = 48 samples at 48 kHz
    try testing.expectApproxEqAbs(@as(f32, 48.0), msToSamples(1.0, sample_rate), 0.1);

    // 10 ms = 480 samples
    try testing.expectApproxEqAbs(@as(f32, 480.0), msToSamples(10.0, sample_rate), 0.1);

    // 1000 ms (1 second) = 48000 samples
    try testing.expectApproxEqAbs(@as(f32, 48000.0), msToSamples(1000.0, sample_rate), 1.0);
}

test "msToSamples - at 96 kHz" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 96000.0;

    // 1 ms = 96 samples at 96 kHz
    try testing.expectApproxEqAbs(@as(f32, 96.0), msToSamples(1.0, sample_rate), 0.1);

    // 1000 ms (1 second) = 96000 samples
    try testing.expectApproxEqAbs(@as(f32, 96000.0), msToSamples(1000.0, sample_rate), 1.0);
}

test "msToSamples - zero and edge cases" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 44100.0;

    // 0 ms = 0 samples
    try testing.expectApproxEqAbs(@as(f32, 0.0), msToSamples(0.0, sample_rate), 0.0001);
}

test "samplesToMs - at 44.1 kHz" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 44100.0;

    // 44.1 samples = 1 ms at 44.1 kHz
    try testing.expectApproxEqAbs(@as(f32, 1.0), samplesToMs(44.1, sample_rate), 0.01);

    // 441 samples = 10 ms
    try testing.expectApproxEqAbs(@as(f32, 10.0), samplesToMs(441.0, sample_rate), 0.01);

    // 4410 samples = 100 ms
    try testing.expectApproxEqAbs(@as(f32, 100.0), samplesToMs(4410.0, sample_rate), 0.1);

    // 44100 samples = 1000 ms (1 second)
    try testing.expectApproxEqAbs(@as(f32, 1000.0), samplesToMs(44100.0, sample_rate), 1.0);

    // 22.05 samples = 0.5 ms
    try testing.expectApproxEqAbs(@as(f32, 0.5), samplesToMs(22.05, sample_rate), 0.01);
}

test "samplesToMs - at 48 kHz" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 48000.0;

    // 48 samples = 1 ms at 48 kHz
    try testing.expectApproxEqAbs(@as(f32, 1.0), samplesToMs(48.0, sample_rate), 0.01);

    // 480 samples = 10 ms
    try testing.expectApproxEqAbs(@as(f32, 10.0), samplesToMs(480.0, sample_rate), 0.01);

    // 48000 samples = 1000 ms (1 second)
    try testing.expectApproxEqAbs(@as(f32, 1000.0), samplesToMs(48000.0, sample_rate), 1.0);
}

test "samplesToMs - zero and edge cases" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 44100.0;

    // 0 samples = 0 ms
    try testing.expectApproxEqAbs(@as(f32, 0.0), samplesToMs(0.0, sample_rate), 0.0001);
}

test "msToSamples and samplesToMs - round trip conversion" {
    const testing = @import("std").testing;
    const sample_rate: f32 = 44100.0;

    // Test round trip: ms -> samples -> ms
    try testing.expectApproxEqAbs(@as(f32, 1.0), samplesToMs(msToSamples(1.0, sample_rate), sample_rate), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), samplesToMs(msToSamples(10.0, sample_rate), sample_rate), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100.0), samplesToMs(msToSamples(100.0, sample_rate), sample_rate), 0.1);
    try testing.expectApproxEqAbs(@as(f32, 1000.0), samplesToMs(msToSamples(1000.0, sample_rate), sample_rate), 1.0);

    // Test round trip: samples -> ms -> samples
    try testing.expectApproxEqAbs(@as(f32, 100.0), msToSamples(samplesToMs(100.0, sample_rate), sample_rate), 0.1);
    try testing.expectApproxEqAbs(@as(f32, 441.0), msToSamples(samplesToMs(441.0, sample_rate), sample_rate), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 4410.0), msToSamples(samplesToMs(4410.0, sample_rate), sample_rate), 1.0);
}

test "panConstantPower - center position" {
    const testing = @import("std").testing;

    // Center (pan = 0.0): equal power to both channels
    const center = panConstantPower(0.0);
    try testing.expectApproxEqAbs(center.left, center.right, 0.0001);

    // At center, each channel should be at ~0.707 (sqrt(0.5) for constant power)
    const std = @import("std");
    const expected_gain = @cos(std.math.pi / 4.0); // cos(45°) ≈ 0.707
    try testing.expectApproxEqAbs(expected_gain, center.left, 0.001);
    try testing.expectApproxEqAbs(expected_gain, center.right, 0.001);
}

test "panConstantPower - hard left" {
    const testing = @import("std").testing;

    // Hard left (pan = -1.0): all signal to left, none to right
    const left = panConstantPower(-1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left.right, 0.001);
}

test "panConstantPower - hard right" {
    const testing = @import("std").testing;

    // Hard right (pan = 1.0): none to left, all signal to right
    const right = panConstantPower(1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), right.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right.right, 0.001);
}

test "panConstantPower - intermediate positions" {
    const testing = @import("std").testing;

    // Slightly left (pan = -0.5)
    const slight_left = panConstantPower(-0.5);
    try testing.expect(slight_left.left > slight_left.right);
    try testing.expect(slight_left.left < 1.0);
    try testing.expect(slight_left.right > 0.0);

    // Slightly right (pan = 0.5)
    const slight_right = panConstantPower(0.5);
    try testing.expect(slight_right.right > slight_right.left);
    try testing.expect(slight_right.right < 1.0);
    try testing.expect(slight_right.left > 0.0);
}

test "panConstantPower - constant power law verification" {
    const testing = @import("std").testing;

    // Verify constant power: left^2 + right^2 should equal 1.0 for all pan positions
    const pan_positions = [_]f32{ -1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0 };

    for (pan_positions) |pan| {
        const gains = panConstantPower(pan);
        const total_power = gains.left * gains.left + gains.right * gains.right;
        try testing.expectApproxEqAbs(@as(f32, 1.0), total_power, 0.001);
    }
}

test "lerp - boundary values" {
    const testing = @import("std").testing;

    // t = 0.0 should return a
    try testing.expectApproxEqAbs(@as(f32, 10.0), lerp(10.0, 20.0, 0.0), 0.0001);

    // t = 1.0 should return b
    try testing.expectApproxEqAbs(@as(f32, 20.0), lerp(10.0, 20.0, 1.0), 0.0001);
}

test "lerp - midpoint" {
    const testing = @import("std").testing;

    // t = 0.5 should return midpoint
    try testing.expectApproxEqAbs(@as(f32, 15.0), lerp(10.0, 20.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), lerp(-10.0, 10.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50.0), lerp(0.0, 100.0, 0.5), 0.0001);
}

test "lerp - intermediate values" {
    const testing = @import("std").testing;

    // t = 0.25
    try testing.expectApproxEqAbs(@as(f32, 12.5), lerp(10.0, 20.0, 0.25), 0.0001);

    // t = 0.75
    try testing.expectApproxEqAbs(@as(f32, 17.5), lerp(10.0, 20.0, 0.75), 0.0001);

    // t = 0.1
    try testing.expectApproxEqAbs(@as(f32, 11.0), lerp(10.0, 20.0, 0.1), 0.0001);

    // t = 0.9
    try testing.expectApproxEqAbs(@as(f32, 19.0), lerp(10.0, 20.0, 0.9), 0.0001);
}

test "lerp - negative values" {
    const testing = @import("std").testing;

    // Lerp between negative values
    try testing.expectApproxEqAbs(@as(f32, -15.0), lerp(-20.0, -10.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -17.5), lerp(-20.0, -10.0, 0.25), 0.0001);

    // Lerp from negative to positive
    try testing.expectApproxEqAbs(@as(f32, 0.0), lerp(-10.0, 10.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -5.0), lerp(-10.0, 10.0, 0.25), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp(-10.0, 10.0, 0.75), 0.0001);
}

test "lerp - identity cases" {
    const testing = @import("std").testing;

    // Lerp between same values
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp(5.0, 5.0, 0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp(5.0, 5.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp(5.0, 5.0, 1.0), 0.0001);

    // Lerp from zero
    try testing.expectApproxEqAbs(@as(f32, 0.0), lerp(0.0, 10.0, 0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp(0.0, 10.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), lerp(0.0, 10.0, 1.0), 0.0001);
}
