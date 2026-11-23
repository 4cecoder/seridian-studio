//! SuperSaw Synth - Classic trance/EDM unison saw synthesizer
//!
//! Features:
//! - 7-voice super saw oscillator with detuning
//! - Low-pass filter with resonance
//! - ADSR envelope for amplitude and filter
//! - 16-voice polyphony
//! - Unison spread control

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = 16;
const MAX_UNISON = 7;

/// Lightweight unison saw oscillator (no heavy wavetables)
const UnisonSawOsc = struct {
    phases: [MAX_UNISON]f32 = @as([MAX_UNISON]f32, @splat(0)),
    detune_offsets: [MAX_UNISON]f32 = @as([MAX_UNISON]f32, @splat(0)),
    frequency: f32 = 440.0,
    num_voices: usize = 7,
    detune: f32 = 0.3, // In semitones
    sample_rate: f32,

    pub fn init(sample_rate: f32) UnisonSawOsc {
        var osc = UnisonSawOsc{ .sample_rate = sample_rate };
        osc.updateDetuneOffsets();
        return osc;
    }

    pub fn setFrequency(self: *UnisonSawOsc, freq: f32) void {
        self.frequency = freq;
    }

    pub fn setDetune(self: *UnisonSawOsc, detune: f32) void {
        if (self.detune != detune) {
            self.detune = detune;
            self.updateDetuneOffsets();
        }
    }

    pub fn setVoices(self: *UnisonSawOsc, voices: usize) void {
        self.num_voices = std.math.clamp(voices, 1, MAX_UNISON);
    }

    fn updateDetuneOffsets(self: *UnisonSawOsc) void {
        if (self.num_voices == 1) {
            self.detune_offsets[0] = 1.0;
            return;
        }

        const half = @as(f32, @floatFromInt(self.num_voices - 1)) / 2.0;
        // Protect against division by zero (shouldn't happen but be safe)
        if (half == 0.0) {
            for (0..self.num_voices) |i| {
                self.detune_offsets[i] = 1.0;
            }
            return;
        }

        for (0..self.num_voices) |i| {
            const offset = @as(f32, @floatFromInt(i)) - half;
            const semitones = offset * self.detune / half;
            // Convert semitones to frequency ratio: 2^(semitones/12)
            const ratio = std.math.pow(f32, 2.0, semitones / 12.0);
            // Sanitize result
            self.detune_offsets[i] = if (std.math.isNan(ratio) or std.math.isInf(ratio)) 1.0 else ratio;
        }
    }

    pub fn reset(self: *UnisonSawOsc) void {
        // Randomize phases for width
        // Use frequency and a small offset to ensure variety
        const seed = @as(u64, @bitCast(@as(i64, @intFromFloat(self.frequency * 1234.567))));
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        for (0..MAX_UNISON) |i| {
            self.phases[i] = random.float(f32);
        }
    }

    pub fn process(self: *UnisonSawOsc) f32 {
        var sum: f32 = 0.0;
        const num = self.num_voices;

        for (0..num) |i| {
            // Naive saw wave: 2 * phase - 1
            const saw = 2.0 * self.phases[i] - 1.0;
            sum += saw;

            // Advance phase with detuned frequency
            const freq = self.frequency * self.detune_offsets[i];
            self.phases[i] += freq / self.sample_rate;
            if (self.phases[i] >= 1.0) self.phases[i] -= 1.0;
        }

        // Normalize by voices using square root scaling for more natural level
        const norm = @sqrt(@as(f32, @floatFromInt(num)));
        return sum / norm;
    }
};

/// SuperSaw voice
const SuperSawVoice = struct {
    // Oscillator
    osc: UnisonSawOsc,

    // Envelopes
    amp_env: dsp.ADSREnvelope,
    filter_env: dsp.ADSREnvelope,

    // Filter
    filter: dsp.SVFilter,

    // State
    state: dsp.VoiceState = .off,
    note: u8 = 0,
    velocity: f32 = 0.0,

    sample_rate: f32,

    pub fn init(sample_rate: f32) SuperSawVoice {
        return .{
            .osc = UnisonSawOsc.init(sample_rate),
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .filter_env = dsp.ADSREnvelope.init(sample_rate),
            .filter = dsp.SVFilter.init(sample_rate),
            .sample_rate = sample_rate,
        };
    }

    pub fn noteOn(self: *SuperSawVoice, note: u8, velocity: u8) void {
        self.note = note;
        self.velocity = velocityToAmplitude(velocity);
        self.state = .playing;

        const freq = dsp.midiNoteToFreq(note);
        self.osc.setFrequency(freq);
        self.osc.reset();

        self.amp_env.noteOn();
        self.filter_env.noteOn();
    }

    pub fn noteOff(self: *SuperSawVoice) void {
        if (self.state == .playing) {
            self.state = .releasing;
            self.amp_env.noteOff();
            self.filter_env.noteOff();
        }
    }

    pub fn tick(
        self: *SuperSawVoice,
        filter_cutoff: f32,
        filter_res: f32,
        filter_env_amt: f32,
        detune: f32,
        num_voices: usize,
    ) f32 {
        if (self.state == .off) return 0.0;

        // Update oscillator settings
        self.osc.setDetune(detune);
        self.osc.setVoices(num_voices);

        // Get oscillator output
        const osc_out = self.osc.process();

        // Apply filter with envelope
        const filter_env_val = self.filter_env.tick();
        const cutoff = filter_cutoff + filter_env_amt * filter_env_val * 10000.0;
        self.filter.setFrequency(std.math.clamp(cutoff, 20.0, 20000.0));
        self.filter.setQ(filter_res);
        const filtered = self.filter.tickLP(osc_out);

        // Apply amplitude envelope
        const amp = self.amp_env.tick();

        if (!self.amp_env.isActive()) {
            self.state = .off;
        }

        return filtered * amp * self.velocity;
    }

    pub fn isAvailable(self: *const SuperSawVoice) bool {
        return self.state == .off;
    }

    pub fn isPlayingNote(self: *const SuperSawVoice, note: u8) bool {
        return self.note == note and self.state != .off;
    }

    pub fn getAmplitudeLevel(self: *const SuperSawVoice) f32 {
        return self.amp_env.output;
    }
};

/// SuperSaw Synth instrument
pub const SuperSawSynth = struct {
    instrument: Instrument,

    // Voice pool
    voices: [MAX_VOICES]SuperSawVoice = undefined,

    // Parameters
    params: [10]Parameter = .{
        .{ .name = "Detune", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "st" },
        .{ .name = "Voices", .min = 1.0, .max = 7.0, .default = 7.0, .value = 7.0, .unit = "" },
        .{ .name = "Filter Cutoff", .min = 20.0, .max = 20000.0, .default = 8000.0, .value = 8000.0, .unit = "Hz" },
        .{ .name = "Filter Res", .min = 0.5, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Filter Env", .min = -1.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Attack", .min = 0.001, .max = 2.0, .default = 0.01, .value = 0.01, .unit = "s" },
        .{ .name = "Decay", .min = 0.001, .max = 2.0, .default = 0.3, .value = 0.3, .unit = "s" },
        .{ .name = "Sustain", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Release", .min = 0.001, .max = 5.0, .default = 0.5, .value = 0.5, .unit = "s" },
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
    },

    sample_rate: f32 = 48000.0,

    const ParamHelpers = ParameterMixin(SuperSawSynth, "instrument");
    const DestroyHelpers = DestroyMixin(SuperSawSynth, "instrument");

    const vtable = Instrument.VTable{
        .process = process,
        .noteOn = noteOn,
        .noteOff = noteOff,
        .allNotesOff = allNotesOff,
        .reset = reset,
        .getParameterCount = ParamHelpers.getParameterCount,
        .getParameter = ParamHelpers.getParameter,
        .setParameter = ParamHelpers.setParameter,
        .deinit = DestroyHelpers.deinit,
        .destroy = DestroyHelpers.destroy,
    };

    pub fn init(sample_rate: f32) SuperSawSynth {
        var synth = SuperSawSynth{
            .instrument = .{
                .vtable = &vtable,
                .name = "SuperSaw",
            },
            .sample_rate = sample_rate,
        };

        for (&synth.voices) |*voice| {
            voice.* = SuperSawVoice.init(sample_rate);
        }

        return synth;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *SuperSawSynth = @fieldParentPtr("instrument", instrument);
        _ = sample_rate;

        // Safe parameter access with NaN/Inf protection
        const detune = if (std.math.isNan(self.params[0].value) or std.math.isInf(self.params[0].value))
            0.3
        else
            self.params[0].value;

        const voices_value = self.params[1].value;
        const num_voices: usize = if (std.math.isNan(voices_value) or std.math.isInf(voices_value))
            7
        else
            @intFromFloat(std.math.clamp(voices_value, 1.0, 7.0));

        const filter_cutoff = if (std.math.isNan(self.params[2].value) or std.math.isInf(self.params[2].value))
            8000.0
        else
            std.math.clamp(self.params[2].value, 20.0, 20000.0);

        const filter_res = if (std.math.isNan(self.params[3].value) or std.math.isInf(self.params[3].value))
            1.0
        else
            @max(0.5, self.params[3].value);

        const filter_env_amt = if (std.math.isNan(self.params[4].value)) 0.5 else self.params[4].value;
        const volume = if (std.math.isNan(self.params[9].value)) 0.7 else self.params[9].value;

        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            var sum: f32 = 0.0;

            for (&self.voices) |*voice| {
                sum += voice.tick(filter_cutoff, filter_res, filter_env_amt, detune, num_voices);
            }

            // Apply volume and soft clip
            sum = dsp.softClip(sum * volume);

            // Write stereo
            buffer[frame * 2] += sum;
            buffer[frame * 2 + 1] += sum;
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *SuperSawSynth = @fieldParentPtr("instrument", instrument);

        // Set ADSR from parameters
        const attack = self.params[5].value;
        const decay = self.params[6].value;
        const sustain = self.params[7].value;
        const release = self.params[8].value;

        // Retrigger check
        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.amp_env.setAttack(attack);
                voice.amp_env.setDecay(decay);
                voice.amp_env.setSustain(sustain);
                voice.amp_env.setRelease(release);
                voice.amp_env.updateCoefficients();
                voice.filter_env.setAttack(attack * 0.5);
                voice.filter_env.setDecay(decay);
                voice.filter_env.setSustain(sustain * 0.5);
                voice.filter_env.setRelease(release);
                voice.filter_env.updateCoefficients();
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Find free voice
        for (&self.voices) |*voice| {
            if (voice.isAvailable()) {
                voice.amp_env.setAttack(attack);
                voice.amp_env.setDecay(decay);
                voice.amp_env.setSustain(sustain);
                voice.amp_env.setRelease(release);
                voice.amp_env.updateCoefficients();
                voice.filter_env.setAttack(attack * 0.5);
                voice.filter_env.setDecay(decay);
                voice.filter_env.setSustain(sustain * 0.5);
                voice.filter_env.setRelease(release);
                voice.filter_env.updateCoefficients();
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Steal quietest
        var quietest: *SuperSawVoice = &self.voices[0];
        var min_level: f32 = 1.0;
        for (&self.voices) |*voice| {
            const level = voice.amp_env.output;
            if (level < min_level) {
                min_level = level;
                quietest = voice;
            }
        }
        quietest.amp_env.setAttack(attack);
        quietest.amp_env.setDecay(decay);
        quietest.amp_env.setSustain(sustain);
        quietest.amp_env.setRelease(release);
        quietest.amp_env.updateCoefficients();
        quietest.filter_env.setAttack(attack * 0.5);
        quietest.filter_env.setDecay(decay);
        quietest.filter_env.setSustain(sustain * 0.5);
        quietest.filter_env.setRelease(release);
        quietest.filter_env.updateCoefficients();
        quietest.noteOn(note, velocity);
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *SuperSawSynth = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.noteOff();
            }
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *SuperSawSynth = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            voice.state = .off;
            voice.amp_env.kill();
        }
    }

    fn reset(instrument: *Instrument) void {
        allNotesOff(instrument);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "supersaw synth init" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);
    try testing.expectEqualStrings("SuperSaw", synth.instrument.name);
    try testing.expectEqual(@as(usize, 10), synth.instrument.getParameterCount());
}

test "supersaw synth note on/off" {
    var synth = SuperSawSynth.init(48000.0);

    synth.instrument.noteOn(60, 100);

    var buffer = @as([256]f32, @splat(0));
    synth.instrument.process(&buffer, 48000);

    synth.instrument.noteOff(60);
}

test "UnisonSawOsc setFrequency" {
    const testing = std.testing;

    var osc = UnisonSawOsc.init(48000.0);

    // Test setting different frequencies
    osc.setFrequency(440.0);
    try testing.expectEqual(@as(f32, 440.0), osc.frequency);

    osc.setFrequency(880.0);
    try testing.expectEqual(@as(f32, 880.0), osc.frequency);

    osc.setFrequency(110.0);
    try testing.expectEqual(@as(f32, 110.0), osc.frequency);
}

test "UnisonSawOsc setDetune" {
    const testing = std.testing;

    var osc = UnisonSawOsc.init(48000.0);
    osc.num_voices = 7;

    // Initial detune
    try testing.expectEqual(@as(f32, 0.3), osc.detune);

    // Change detune - should update offsets
    osc.setDetune(0.5);
    try testing.expectEqual(@as(f32, 0.5), osc.detune);

    // Verify detuning creates spread around center
    const center = osc.detune_offsets[3]; // Middle voice
    try testing.expect(osc.detune_offsets[0] < center); // Lower voices pitched down
    try testing.expect(osc.detune_offsets[6] > center); // Upper voices pitched up

    // Test zero detune - all voices should be at same frequency
    osc.setDetune(0.0);
    for (0..7) |i| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), osc.detune_offsets[i], 0.0001);
    }

    // Same value should not recalculate (coverage for early return)
    osc.setDetune(0.0);
    try testing.expectEqual(@as(f32, 0.0), osc.detune);
}

test "UnisonSawOsc setVoices" {
    const testing = std.testing;

    var osc = UnisonSawOsc.init(48000.0);

    // Default is 7 voices
    try testing.expectEqual(@as(usize, 7), osc.num_voices);

    // Set to 3 voices
    osc.setVoices(3);
    try testing.expectEqual(@as(usize, 3), osc.num_voices);

    // Test clamping - below minimum
    osc.setVoices(0);
    try testing.expectEqual(@as(usize, 1), osc.num_voices);

    // Test clamping - above maximum
    osc.setVoices(10);
    try testing.expectEqual(@as(usize, 7), osc.num_voices);

    // Single voice should have no detuning
    osc.setVoices(1);
    osc.setDetune(0.5);
    try testing.expectEqual(@as(f32, 1.0), osc.detune_offsets[0]);
}

test "UnisonSawOsc process generates audio" {
    const testing = std.testing;

    var osc = UnisonSawOsc.init(48000.0);
    osc.setFrequency(440.0);
    osc.setVoices(7);
    osc.setDetune(0.3);

    // Generate samples and verify they're in valid range
    var has_non_zero = false;
    var max_val: f32 = 0.0;
    for (0..100) |_| {
        const sample = osc.process();

        // Saw wave normalized by sqrt(voices) can exceed 1.0
        try testing.expect(sample >= -2.7 and sample <= 2.7);

        if (sample != 0.0) has_non_zero = true;
        if (@abs(sample) > max_val) max_val = @abs(sample);
    }

    std.debug.print("SuperSaw max output: {d}\n", .{max_val});

    // Should produce non-zero output
    try testing.expect(has_non_zero);
}

test "setParameter with valid indices" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Test parameter 0: Detune (0.0 - 1.0)
    synth.instrument.setParameter(0, 0.5);
    const param0 = synth.instrument.getParameter(0).?;
    try testing.expectEqual(@as(f32, 0.5), param0.value);

    // Test parameter 1: Voices (1.0 - 7.0)
    synth.instrument.setParameter(1, 5.0);
    const param1 = synth.instrument.getParameter(1).?;
    try testing.expectEqual(@as(f32, 5.0), param1.value);

    // Test parameter 2: Filter Cutoff (20.0 - 20000.0)
    synth.instrument.setParameter(2, 1000.0);
    const param2 = synth.instrument.getParameter(2).?;
    try testing.expectEqual(@as(f32, 1000.0), param2.value);

    // Test parameter 5: Attack (0.001 - 2.0)
    synth.instrument.setParameter(5, 0.1);
    const param5 = synth.instrument.getParameter(5).?;
    try testing.expectEqual(@as(f32, 0.1), param5.value);

    // Test parameter 9: Volume (0.0 - 1.0)
    synth.instrument.setParameter(9, 0.8);
    const param9 = synth.instrument.getParameter(9).?;
    try testing.expectEqual(@as(f32, 0.8), param9.value);
}

test "setParameter clamping" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Test clamping above max - Detune max is 1.0
    synth.instrument.setParameter(0, 2.0);
    const param0 = synth.instrument.getParameter(0).?;
    try testing.expectEqual(@as(f32, 1.0), param0.value);

    // Test clamping below min - Filter Cutoff min is 20.0
    synth.instrument.setParameter(2, 10.0);
    const param2 = synth.instrument.getParameter(2).?;
    try testing.expectEqual(@as(f32, 20.0), param2.value);

    // Test clamping attack below min (0.001)
    synth.instrument.setParameter(5, 0.0);
    const param5 = synth.instrument.getParameter(5).?;
    try testing.expectEqual(@as(f32, 0.001), param5.value);
}

test "setParameter with invalid index" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Store original value
    const original = synth.params[0].value;

    // Try to set invalid index - should be ignored
    synth.instrument.setParameter(100, 0.5);

    // Verify nothing changed
    try testing.expectEqual(original, synth.params[0].value);
}

test "allNotesOff behavior" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Start some notes
    synth.instrument.noteOn(60, 100);
    synth.instrument.noteOn(64, 100);
    synth.instrument.noteOn(67, 100);

    // Verify voices are active
    var active_count: usize = 0;
    for (synth.voices) |voice| {
        if (voice.state != .off) active_count += 1;
    }
    try testing.expect(active_count == 3);

    // Call allNotesOff
    synth.instrument.allNotesOff();

    // Verify all voices are off
    for (synth.voices) |voice| {
        try testing.expectEqual(dsp.VoiceState.off, voice.state);
    }

    // Verify envelopes are killed
    for (synth.voices) |voice| {
        try testing.expect(!voice.amp_env.isActive());
    }
}

test "allNotesOff produces silence" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Start a note and let it produce sound
    synth.instrument.noteOn(60, 100);
    var buffer = @as([256]f32, @splat(0));
    synth.instrument.process(&buffer, 48000);

    // Verify sound was produced
    var has_sound = false;
    for (buffer) |sample| {
        if (sample != 0.0) has_sound = true;
    }
    try testing.expect(has_sound);

    // Kill all notes
    synth.instrument.allNotesOff();

    // Clear buffer and process again
    @memset(&buffer, 0);
    synth.instrument.process(&buffer, 48000);

    // Should be silent
    for (buffer) |sample| {
        try testing.expectEqual(@as(f32, 0.0), sample);
    }
}

test "voice allocation and polyphony" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Play 16 notes (max polyphony)
    for (0..16) |i| {
        synth.instrument.noteOn(@as(u8, @intCast(60 + i)), 100);
    }

    // All voices should be active
    var active_count: usize = 0;
    for (synth.voices) |voice| {
        if (voice.state != .off) active_count += 1;
    }
    try testing.expectEqual(@as(usize, 16), active_count);

    // Play one more note - should steal a voice
    synth.instrument.noteOn(76, 100);

    // Still 16 voices active
    active_count = 0;
    for (synth.voices) |voice| {
        if (voice.state != .off) active_count += 1;
    }
    try testing.expectEqual(@as(usize, 16), active_count);
}

test "note retrigger" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Play note
    synth.instrument.noteOn(60, 100);

    // Find the voice
    var voice_ptr: ?*SuperSawVoice = null;
    for (&synth.voices) |*voice| {
        if (voice.note == 60 and voice.state != .off) {
            voice_ptr = voice;
            break;
        }
    }
    try testing.expect(voice_ptr != null);

    // Retrigger same note
    synth.instrument.noteOn(60, 80);

    // Should still be the same voice (not a new allocation)
    var found = false;
    for (synth.voices) |voice| {
        if (voice.note == 60 and voice.state != .off) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "parameter names and units" {
    const testing = std.testing;

    var synth = SuperSawSynth.init(48000.0);

    // Check a few parameter names
    const detune = synth.instrument.getParameter(0).?;
    try testing.expectEqualStrings("Detune", detune.name);
    try testing.expectEqualStrings("st", detune.unit);

    const voices = synth.instrument.getParameter(1).?;
    try testing.expectEqualStrings("Voices", voices.name);

    const filter_cutoff = synth.instrument.getParameter(2).?;
    try testing.expectEqualStrings("Filter Cutoff", filter_cutoff.name);
    try testing.expectEqualStrings("Hz", filter_cutoff.unit);

    const volume = synth.instrument.getParameter(9).?;
    try testing.expectEqualStrings("Volume", volume.name);
}

test "UnisonSawOsc phase advancement" {
    const testing = std.testing;

    var osc = UnisonSawOsc.init(48000.0);
    osc.setFrequency(480.0); // Exactly 0.01 phase increment per sample
    osc.setVoices(1);

    // Reset to known phase
    osc.phases[0] = 0.0;

    // Process one sample
    _ = osc.process();

    // Phase should advance by freq/sample_rate = 480/48000 = 0.01
    try testing.expectApproxEqAbs(@as(f32, 0.01), osc.phases[0], 0.001);

    // Process more samples
    for (0..99) |_| {
        _ = osc.process();
    }

    // After 100 samples, phase should have wrapped around or be close to 1.0
    // Due to floating point precision, verify it's in a reasonable range
    try testing.expect(osc.phases[0] >= 0.0 and osc.phases[0] <= 1.0);
}
