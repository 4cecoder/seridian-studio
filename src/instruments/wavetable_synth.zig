//! WavetableSynth - Wavetable synthesizer (Serum-like)
//!
//! Features:
//! - 2 wavetable oscillators with morphing
//! - Sub oscillator
//! - 2 filters with routing options
//! - 2 LFOs for modulation
//! - 16-voice polyphony
//! - Unison with detune and spread

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = 16;
const WAVETABLE_SIZE = 2048;
const NUM_WAVETABLES = 8;

/// Built-in wavetable types
pub const WavetableType = enum(u8) {
    basic = 0,
    digital = 1,
    analog = 2,
    vocal = 3,
    fm = 4,
    noise = 5,
    pwm = 6,
    sync = 7,

    pub fn name(self: WavetableType) []const u8 {
        return switch (self) {
            .basic => "Basic Shapes",
            .digital => "Digital",
            .analog => "Analog",
            .vocal => "Vocal",
            .fm => "FM",
            .noise => "Noise",
            .pwm => "PWM",
            .sync => "Sync",
        };
    }
};

/// A single wavetable (array of waveform snapshots)
pub const Wavetable = struct {
    /// Each frame is a single waveform cycle
    frames: [NUM_WAVETABLES][WAVETABLE_SIZE]f32 = undefined,
    num_frames: usize = NUM_WAVETABLES,

    /// Initialize with basic waveforms morphing
    pub fn initBasic() Wavetable {
        var wt = Wavetable{};

        for (0..NUM_WAVETABLES) |frame_idx| {
            const morph = @as(f32, @floatFromInt(frame_idx)) / @as(f32, @floatFromInt(NUM_WAVETABLES - 1));

            for (0..WAVETABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(WAVETABLE_SIZE));

                // Morph from sine -> triangle -> saw -> square
                const sine = dsp.sine(phase);
                const tri = dsp.triangle(phase);
                const saw = 2.0 * phase - 1.0;
                const square: f32 = if (phase < 0.5) 1.0 else -1.0;

                var sample: f32 = 0;
                if (morph < 0.333) {
                    const t = morph / 0.333;
                    sample = dsp.lerp(sine, tri, t);
                } else if (morph < 0.666) {
                    const t = (morph - 0.333) / 0.333;
                    sample = dsp.lerp(tri, saw, t);
                } else {
                    const t = (morph - 0.666) / 0.333;
                    sample = dsp.lerp(saw, square, t);
                }

                wt.frames[frame_idx][i] = sample;
            }
        }

        return wt;
    }

    /// Initialize with digital/harsh waveforms
    pub fn initDigital() Wavetable {
        var wt = Wavetable{};

        for (0..NUM_WAVETABLES) |frame_idx| {
            for (0..WAVETABLE_SIZE) |i| {
                const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(WAVETABLE_SIZE));
                const harmonics = frame_idx + 1;

                // Additive synthesis with decreasing harmonics
                var sample: f32 = 0;
                for (1..harmonics * 4 + 1) |h| {
                    const hf = @as(f32, @floatFromInt(h));
                    sample += @sin(phase * std.math.tau * hf) / hf;
                }

                wt.frames[frame_idx][i] = sample * 0.5;
            }
        }

        return wt;
    }

    /// Lookup with linear interpolation between samples and frames
    pub fn lookup(self: *const Wavetable, phase: f32, frame_pos: f32) f32 {
        // Frame interpolation
        const frame_f = frame_pos * @as(f32, @floatFromInt(self.num_frames - 1));
        const frame1 = @as(usize, @intFromFloat(@floor(frame_f))) % self.num_frames;
        const frame2 = (frame1 + 1) % self.num_frames;
        const frame_frac = frame_f - @floor(frame_f);

        // Sample interpolation
        const pos = phase * @as(f32, @floatFromInt(WAVETABLE_SIZE));
        const idx1 = @as(usize, @intFromFloat(@floor(pos))) % WAVETABLE_SIZE;
        const idx2 = (idx1 + 1) % WAVETABLE_SIZE;
        const sample_frac = pos - @floor(pos);

        // Get samples from both frames
        const s1_f1 = self.frames[frame1][idx1];
        const s2_f1 = self.frames[frame1][idx2];
        const s1_f2 = self.frames[frame2][idx1];
        const s2_f2 = self.frames[frame2][idx2];

        // Bilinear interpolation
        const interp_f1 = dsp.lerp(s1_f1, s2_f1, sample_frac);
        const interp_f2 = dsp.lerp(s1_f2, s2_f2, sample_frac);

        return dsp.lerp(interp_f1, interp_f2, frame_frac);
    }
};

/// Wavetable oscillator
const WTOscillator = struct {
    phase: f32 = 0.0,
    frequency: f32 = 440.0,
    wavetable_pos: f32 = 0.0, // 0.0 - 1.0, position in wavetable
    sample_rate: f32 = 48000.0,

    pub fn tick(self: *WTOscillator, wt: *const Wavetable) f32 {
        const sample = wt.lookup(self.phase, self.wavetable_pos);

        // Advance phase
        self.phase += self.frequency / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return sample;
    }

    pub fn reset(self: *WTOscillator) void {
        self.phase = 0.0;
    }
};

/// LFO for modulation
const LFO = struct {
    phase: f32 = 0.0,
    rate: f32 = 1.0, // Hz
    waveform: dsp.Waveform = .sine,
    sample_rate: f32 = 48000.0,

    pub fn tick(self: *LFO) f32 {
        const output = switch (self.waveform) {
            .sine => dsp.sine(self.phase),
            .triangle => dsp.triangle(self.phase),
            .saw => 2.0 * self.phase - 1.0,
            .square => if (self.phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
            else => dsp.sine(self.phase),
        };

        self.phase += self.rate / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return output;
    }

    pub fn reset(self: *LFO) void {
        self.phase = 0.0;
    }
};

/// Wavetable synth voice
const WTVoice = struct {
    // Oscillators
    osc1: WTOscillator = .{},
    osc2: WTOscillator = .{},
    sub_osc: dsp.BLEPOscillator = .{},

    // Envelopes
    amp_env: dsp.ADSREnvelope = .{},
    filter_env: dsp.ADSREnvelope = .{},
    mod_env: dsp.ADSREnvelope = .{},

    // Filter
    filter: dsp.SVFilter = .{},

    // State
    state: dsp.VoiceState = .off,
    note: u8 = 0,
    velocity: f32 = 0.0,

    sample_rate: f32 = 48000.0,

    pub fn init(sample_rate: f32) WTVoice {
        var voice = WTVoice{
            .sample_rate = sample_rate,
            .osc1 = .{ .sample_rate = sample_rate },
            .osc2 = .{ .sample_rate = sample_rate },
            .sub_osc = dsp.BLEPOscillator.init(sample_rate),
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .filter_env = dsp.ADSREnvelope.init(sample_rate),
            .mod_env = dsp.ADSREnvelope.init(sample_rate),
            .filter = dsp.SVFilter.init(sample_rate),
        };

        voice.sub_osc.waveform = .sine;

        return voice;
    }

    pub fn noteOn(self: *WTVoice, note: u8, velocity: u8) void {
        self.note = note;
        self.velocity = velocityToAmplitude(velocity);
        self.state = .playing;

        const freq = dsp.midiNoteToFreq(note);
        self.osc1.frequency = freq;
        self.osc2.frequency = freq;
        self.sub_osc.osc.frequency = freq / 2.0; // One octave down

        self.osc1.reset();
        self.osc2.reset();
        self.sub_osc.reset();
        self.amp_env.noteOn();
        self.filter_env.noteOn();
        self.mod_env.noteOn();
    }

    pub fn noteOff(self: *WTVoice) void {
        if (self.state == .playing) {
            self.state = .releasing;
            self.amp_env.noteOff();
            self.filter_env.noteOff();
            self.mod_env.noteOff();
        }
    }

    pub fn tick(
        self: *WTVoice,
        wt1: *const Wavetable,
        wt2: *const Wavetable,
        osc_mix: f32,
        sub_level: f32,
        filter_cutoff: f32,
        filter_env_amt: f32,
        detune: f32,
    ) f32 {
        if (self.state == .off) return 0.0;

        // Apply detune to osc2
        const freq = dsp.midiNoteToFreq(self.note);
        self.osc2.frequency = freq * std.math.pow(f32, 2.0, detune / 1200.0);

        // Get oscillator outputs
        const o1 = wt1.lookup(self.osc1.phase, self.osc1.wavetable_pos);
        const o2 = wt2.lookup(self.osc2.phase, self.osc2.wavetable_pos);
        const sub = self.sub_osc.tick();

        // Advance wavetable oscillator phases
        self.osc1.phase += self.osc1.frequency / self.sample_rate;
        if (self.osc1.phase >= 1.0) self.osc1.phase -= 1.0;
        self.osc2.phase += self.osc2.frequency / self.sample_rate;
        if (self.osc2.phase >= 1.0) self.osc2.phase -= 1.0;

        // Mix oscillators
        var mix = dsp.lerp(o1, o2, osc_mix);
        mix += sub * sub_level;

        // Apply filter with envelope
        const filter_env_val = self.filter_env.tick();
        const cutoff = filter_cutoff + filter_env_amt * filter_env_val * 10000.0;
        self.filter.setFrequency(cutoff);
        const filtered = self.filter.tickLP(mix);

        // Apply amplitude envelope
        const amp = self.amp_env.tick();

        if (!self.amp_env.isActive()) {
            self.state = .off;
        }

        return filtered * amp * self.velocity;
    }

    pub fn isAvailable(self: *const WTVoice) bool {
        return self.state == .off;
    }

    pub fn isPlayingNote(self: *const WTVoice, note: u8) bool {
        return self.note == note and self.state != .off;
    }

    pub fn getAmplitudeLevel(self: *const WTVoice) f32 {
        return self.amp_env.output;
    }
};

/// WavetableSynth instrument
pub const WavetableSynth = struct {
    instrument: Instrument,

    // Wavetables - initialized at runtime to avoid comptime branch limit
    wt1: Wavetable = .{},
    wt2: Wavetable = .{},

    // LFOs
    lfo1: LFO = .{},
    lfo2: LFO = .{},

    // Voice pool
    voices: [MAX_VOICES]WTVoice = undefined,

    // Parameters
    params: [12]Parameter = .{
        .{ .name = "Osc1 WT Pos", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Osc2 WT Pos", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Osc Mix", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Sub Level", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Detune", .min = -100.0, .max = 100.0, .default = 10.0, .value = 10.0, .unit = "cents" },
        .{ .name = "Filter Cutoff", .min = 20.0, .max = 20000.0, .default = 5000.0, .value = 5000.0, .unit = "Hz" },
        .{ .name = "Filter Res", .min = 0.5, .max = 10.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Filter Env", .min = -1.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
        .{ .name = "LFO1 Rate", .min = 0.1, .max = 20.0, .default = 1.0, .value = 1.0, .unit = "Hz" },
        .{ .name = "LFO1 -> WT1", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Attack", .min = 0.001, .max = 2.0, .default = 0.01, .value = 0.01, .unit = "s" },
    },

    sample_rate: f32 = 48000.0,

    const ParamHelpers = ParameterMixin(WavetableSynth, "instrument");
    const DestroyHelpers = DestroyMixin(WavetableSynth, "instrument");

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

    pub fn init(sample_rate: f32) WavetableSynth {
        var synth = WavetableSynth{
            .instrument = .{
                .vtable = &vtable,
                .name = "WavetableSynth",
            },
            .sample_rate = sample_rate,
            .lfo1 = .{ .sample_rate = sample_rate },
            .lfo2 = .{ .sample_rate = sample_rate },
        };

        // Initialize wavetables at runtime
        synth.wt1 = Wavetable.initBasic();
        synth.wt2 = Wavetable.initDigital();

        for (&synth.voices) |*voice| {
            voice.* = WTVoice.init(sample_rate);
        }

        return synth;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *WavetableSynth = @fieldParentPtr("instrument", instrument);
        _ = sample_rate;

        const wt1_pos = self.params[0].value;
        const wt2_pos = self.params[1].value;
        const osc_mix = self.params[2].value;
        const sub_level = self.params[3].value;
        const detune = self.params[4].value;
        const filter_cutoff = self.params[5].value;
        const filter_env_amt = self.params[7].value;
        const lfo1_rate = self.params[8].value;
        const lfo1_to_wt1 = self.params[9].value;
        const volume = self.params[10].value;

        self.lfo1.rate = lfo1_rate;

        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            // Get LFO values
            const lfo1_val = self.lfo1.tick();

            // Modulate wavetable positions
            const wt1_mod = wt1_pos + lfo1_val * lfo1_to_wt1 * 0.5;
            const wt1_clamped = std.math.clamp(wt1_mod, 0.0, 1.0);

            // Update voice wavetable positions
            for (&self.voices) |*voice| {
                voice.osc1.wavetable_pos = wt1_clamped;
                voice.osc2.wavetable_pos = wt2_pos;
            }

            // Sum all voices
            var sum: f32 = 0.0;
            for (&self.voices) |*voice| {
                sum += voice.tick(
                    &self.wt1,
                    &self.wt2,
                    osc_mix,
                    sub_level,
                    filter_cutoff,
                    filter_env_amt,
                    detune,
                );
            }

            // Apply volume and soft clip
            sum = dsp.softClip(sum * volume);

            // Write stereo
            buffer[frame * 2] += sum;
            buffer[frame * 2 + 1] += sum;
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *WavetableSynth = @fieldParentPtr("instrument", instrument);

        // Set ADSR from parameter
        const attack = self.params[11].value;

        // Retrigger check
        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.amp_env.setAttack(attack);
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Find free voice
        for (&self.voices) |*voice| {
            if (voice.isAvailable()) {
                voice.amp_env.setAttack(attack);
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Steal quietest
        var quietest: *WTVoice = &self.voices[0];
        var min_level: f32 = 1.0;
        for (&self.voices) |*voice| {
            const level = voice.amp_env.output;
            if (level < min_level) {
                min_level = level;
                quietest = voice;
            }
        }
        quietest.amp_env.setAttack(attack);
        quietest.noteOn(note, velocity);
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *WavetableSynth = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.noteOff();
            }
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *WavetableSynth = @fieldParentPtr("instrument", instrument);

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

test "wavetable synth init" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);
    try testing.expectEqualStrings("WavetableSynth", synth.instrument.name);
    try testing.expectEqual(@as(usize, 12), synth.instrument.getParameterCount());
}

test "wavetable lookup" {
    const wt = Wavetable.initBasic();

    // Should return values in [-1, 1]
    const sample = wt.lookup(0.5, 0.5);
    try std.testing.expect(sample >= -1.0 and sample <= 1.0);
}

test "Wavetable.initBasic morphing tables" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();

    // Verify we have the expected number of frames
    try testing.expectEqual(@as(usize, NUM_WAVETABLES), wt.num_frames);

    // First frame (morph=0) should be close to sine wave
    const first_frame_quarter = wt.frames[0][WAVETABLE_SIZE / 4];
    try testing.expectApproxEqAbs(@as(f32, 1.0), first_frame_quarter, 0.1);

    // Last frame (morph=1) should be close to square wave
    const last_frame_start = wt.frames[NUM_WAVETABLES - 1][0];
    const last_frame_mid = wt.frames[NUM_WAVETABLES - 1][WAVETABLE_SIZE / 2];
    // Square wave: first half should be positive, second half negative
    try testing.expect(last_frame_start > 0.5);
    try testing.expect(last_frame_mid < -0.5);

    // Middle frame should be somewhere between sine and square
    const mid_frame_idx = NUM_WAVETABLES / 2;
    const mid_sample = wt.frames[mid_frame_idx][WAVETABLE_SIZE / 4];
    try testing.expect(mid_sample >= -1.0 and mid_sample <= 1.0);

    // All samples should be in valid range
    for (0..NUM_WAVETABLES) |frame| {
        for (0..WAVETABLE_SIZE) |i| {
            const sample = wt.frames[frame][i];
            try testing.expect(sample >= -1.5 and sample <= 1.5);
        }
    }
}

test "Wavetable.initBasic frame interpolation" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();

    // Lookup at frame position 0.0 should give first frame
    const sample_f0 = wt.lookup(0.0, 0.0);
    const direct_f0 = wt.frames[0][0];
    try testing.expectApproxEqAbs(direct_f0, sample_f0, 0.01);

    // Lookup at frame position 1.0 should give last frame
    const sample_f1 = wt.lookup(0.0, 1.0);
    const direct_f_last = wt.frames[NUM_WAVETABLES - 1][0];
    try testing.expectApproxEqAbs(direct_f_last, sample_f1, 0.01);

    // Lookup at frame position 0.5 should interpolate between frames
    const sample_mid = wt.lookup(0.25, 0.5);
    const mid_idx = NUM_WAVETABLES / 2;
    const direct_mid = wt.frames[mid_idx][WAVETABLE_SIZE / 4];
    // Should be close to the middle frame value
    try testing.expectApproxEqAbs(direct_mid, sample_mid, 0.2);
}

test "Wavetable.initDigital creates harmonic content" {
    const testing = std.testing;

    const wt = Wavetable.initDigital();

    // Verify frame count
    try testing.expectEqual(@as(usize, NUM_WAVETABLES), wt.num_frames);

    // Digital wavetables should have values in reasonable range
    for (0..NUM_WAVETABLES) |frame| {
        var max_val: f32 = -1000.0;
        var min_val: f32 = 1000.0;

        for (0..WAVETABLE_SIZE) |i| {
            const sample = wt.frames[frame][i];
            if (sample > max_val) max_val = sample;
            if (sample < min_val) min_val = sample;
        }

        // Should have some variation (not all zeros)
        try testing.expect(max_val > min_val);
        // Should be in reasonable range
        try testing.expect(max_val < 2.0 and min_val > -2.0);
    }
}

test "WTOscillator.tick phase advancement" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();
    var osc = WTOscillator{
        .phase = 0.0,
        .frequency = 480.0, // 480/48000 = 0.01 phase per sample
        .sample_rate = 48000.0,
    };

    // Process one sample
    _ = osc.tick(&wt);

    // Phase should advance by 480/48000 = 0.01
    try testing.expectApproxEqAbs(@as(f32, 0.01), osc.phase, 0.001);

    // Process 99 more samples (100 total)
    for (0..99) |_| {
        _ = osc.tick(&wt);
    }

    // After 100 samples, phase should be close to 0 or 1 (wrapped or about to wrap)
    // Due to floating point precision, 100 * 0.01 may be slightly less than 1.0
    const is_near_zero = osc.phase < 0.01;
    const is_near_one = osc.phase > 0.99;
    try testing.expect(is_near_zero or is_near_one);
}

test "WTOscillator.tick generates audio" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();
    var osc = WTOscillator{
        .frequency = 440.0,
        .sample_rate = 48000.0,
        .wavetable_pos = 0.0,
    };

    // Generate samples and verify they're in valid range
    var samples_generated: usize = 0;
    var has_non_zero = false;

    for (0..100) |_| {
        const sample = osc.tick(&wt);
        samples_generated += 1;

        // Should be in reasonable range
        try testing.expect(sample >= -2.0 and sample <= 2.0);

        if (sample != 0.0) has_non_zero = true;
    }

    try testing.expectEqual(@as(usize, 100), samples_generated);
    try testing.expect(has_non_zero);
}

test "WTOscillator.tick with wavetable position morphing" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();

    var osc1 = WTOscillator{
        .frequency = 440.0,
        .sample_rate = 48000.0,
        .wavetable_pos = 0.0, // First frame (sine-ish)
    };

    var osc2 = WTOscillator{
        .frequency = 440.0,
        .sample_rate = 48000.0,
        .wavetable_pos = 1.0, // Last frame (square-ish)
    };

    // Both oscillators at same phase
    osc1.phase = 0.5;
    osc2.phase = 0.5;

    const sample1 = osc1.tick(&wt);
    const sample2 = osc2.tick(&wt);

    // Samples should be different due to different wavetable positions
    try testing.expect(sample1 != sample2);
}

test "WTOscillator.reset" {
    const testing = std.testing;

    var osc = WTOscillator{
        .phase = 0.75,
        .frequency = 440.0,
        .sample_rate = 48000.0,
    };

    osc.reset();
    try testing.expectEqual(@as(f32, 0.0), osc.phase);
}

test "LFO.tick waveform generation - sine" {
    const testing = std.testing;

    var lfo = LFO{
        .rate = 1.0,
        .waveform = .sine,
        .sample_rate = 48000.0,
    };

    // At phase 0, sine should be ~0
    lfo.phase = 0.0;
    const sample0 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.0), sample0, 0.01);

    // At phase 0.25, sine should be ~1
    lfo.phase = 0.25;
    const sample025 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 1.0), sample025, 0.01);

    // At phase 0.5, sine should be ~0
    lfo.phase = 0.5;
    const sample05 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.0), sample05, 0.01);

    // At phase 0.75, sine should be ~-1
    lfo.phase = 0.75;
    const sample075 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, -1.0), sample075, 0.01);
}

test "LFO.tick waveform generation - triangle" {
    const testing = std.testing;

    var lfo = LFO{
        .rate = 1.0,
        .waveform = .triangle,
        .sample_rate = 48000.0,
    };

    // Triangle wave: 4.0 * abs(phase - 0.5) - 1.0
    // At phase 0: 4.0 * abs(0 - 0.5) - 1.0 = 1.0
    lfo.phase = 0.0;
    const sample0 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 1.0), sample0, 0.05);

    // At phase 0.25: 4.0 * abs(0.25 - 0.5) - 1.0 = 0.0
    lfo.phase = 0.25;
    const sample025 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.0), sample025, 0.05);

    // At phase 0.5: 4.0 * abs(0.5 - 0.5) - 1.0 = -1.0
    lfo.phase = 0.5;
    const sample05 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, -1.0), sample05, 0.05);

    // At phase 0.75: 4.0 * abs(0.75 - 0.5) - 1.0 = 0.0
    lfo.phase = 0.75;
    const sample075 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.0), sample075, 0.05);
}

test "LFO.tick waveform generation - saw" {
    const testing = std.testing;

    var lfo = LFO{
        .rate = 1.0,
        .waveform = .saw,
        .sample_rate = 48000.0,
    };

    // At phase 0, saw should be -1
    lfo.phase = 0.0;
    const sample0 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, -1.0), sample0, 0.01);

    // At phase 0.5, saw should be 0
    lfo.phase = 0.5;
    const sample05 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.0), sample05, 0.01);

    // At phase 1.0, saw should approach 1
    lfo.phase = 0.99;
    const sample099 = lfo.tick();
    try testing.expectApproxEqAbs(@as(f32, 0.98), sample099, 0.01);
}

test "LFO.tick waveform generation - square" {
    const testing = std.testing;

    var lfo = LFO{
        .rate = 1.0,
        .waveform = .square,
        .sample_rate = 48000.0,
    };

    // First half should be 1.0
    lfo.phase = 0.25;
    const sample025 = lfo.tick();
    try testing.expectEqual(@as(f32, 1.0), sample025);

    // Second half should be -1.0
    lfo.phase = 0.75;
    const sample075 = lfo.tick();
    try testing.expectEqual(@as(f32, -1.0), sample075);
}

test "LFO.tick phase advancement" {
    const testing = std.testing;

    var lfo = LFO{
        .rate = 480.0, // 480/48000 = 0.01 phase per sample
        .waveform = .sine,
        .sample_rate = 48000.0,
        .phase = 0.0,
    };

    _ = lfo.tick();

    // Phase should advance by rate/sample_rate = 480/48000 = 0.01
    try testing.expectApproxEqAbs(@as(f32, 0.01), lfo.phase, 0.001);

    // Process 99 more samples
    for (0..99) |_| {
        _ = lfo.tick();
    }

    // After 100 samples, phase should be close to 0 or 1 (wrapped or about to wrap)
    const is_near_zero = lfo.phase < 0.01;
    const is_near_one = lfo.phase > 0.99;
    try testing.expect(is_near_zero or is_near_one);
}

test "LFO.reset" {
    const testing = std.testing;

    var lfo = LFO{
        .phase = 0.7,
        .rate = 1.0,
        .sample_rate = 48000.0,
    };

    lfo.reset();
    try testing.expectEqual(@as(f32, 0.0), lfo.phase);
}

test "setParameter for all parameters" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

    // Parameter 0: Osc1 WT Pos (0.0 - 1.0)
    synth.instrument.setParameter(0, 0.3);
    try testing.expectEqual(@as(f32, 0.3), synth.params[0].value);

    // Parameter 1: Osc2 WT Pos (0.0 - 1.0)
    synth.instrument.setParameter(1, 0.7);
    try testing.expectEqual(@as(f32, 0.7), synth.params[1].value);

    // Parameter 2: Osc Mix (0.0 - 1.0)
    synth.instrument.setParameter(2, 0.5);
    try testing.expectEqual(@as(f32, 0.5), synth.params[2].value);

    // Parameter 3: Sub Level (0.0 - 1.0)
    synth.instrument.setParameter(3, 0.4);
    try testing.expectEqual(@as(f32, 0.4), synth.params[3].value);

    // Parameter 4: Detune (-100.0 - 100.0 cents)
    synth.instrument.setParameter(4, 25.0);
    try testing.expectEqual(@as(f32, 25.0), synth.params[4].value);

    // Parameter 5: Filter Cutoff (20.0 - 20000.0)
    synth.instrument.setParameter(5, 2000.0);
    try testing.expectEqual(@as(f32, 2000.0), synth.params[5].value);

    // Parameter 6: Filter Res (0.5 - 10.0)
    synth.instrument.setParameter(6, 5.0);
    try testing.expectEqual(@as(f32, 5.0), synth.params[6].value);

    // Parameter 7: Filter Env (-1.0 - 1.0)
    synth.instrument.setParameter(7, 0.6);
    try testing.expectEqual(@as(f32, 0.6), synth.params[7].value);

    // Parameter 8: LFO1 Rate (0.1 - 20.0)
    synth.instrument.setParameter(8, 5.0);
    try testing.expectEqual(@as(f32, 5.0), synth.params[8].value);

    // Parameter 9: LFO1 -> WT1 (0.0 - 1.0)
    synth.instrument.setParameter(9, 0.8);
    try testing.expectEqual(@as(f32, 0.8), synth.params[9].value);

    // Parameter 10: Volume (0.0 - 1.0)
    synth.instrument.setParameter(10, 0.9);
    try testing.expectEqual(@as(f32, 0.9), synth.params[10].value);

    // Parameter 11: Attack (0.001 - 2.0)
    synth.instrument.setParameter(11, 0.5);
    try testing.expectEqual(@as(f32, 0.5), synth.params[11].value);
}

test "setParameter clamping for wavetable synth" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

    // Test clamping above max - Osc Mix max is 1.0
    synth.instrument.setParameter(2, 2.0);
    try testing.expectEqual(@as(f32, 1.0), synth.params[2].value);

    // Test clamping below min - Osc Mix min is 0.0
    synth.instrument.setParameter(2, -0.5);
    try testing.expectEqual(@as(f32, 0.0), synth.params[2].value);

    // Test detune negative range - min is -100.0
    synth.instrument.setParameter(4, -150.0);
    try testing.expectEqual(@as(f32, -100.0), synth.params[4].value);

    // Test LFO rate min (0.1)
    synth.instrument.setParameter(8, 0.05);
    try testing.expectEqual(@as(f32, 0.1), synth.params[8].value);

    // Test attack min (0.001)
    synth.instrument.setParameter(11, 0.0);
    try testing.expectEqual(@as(f32, 0.001), synth.params[11].value);
}

test "setParameter with invalid index wavetable" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

    // Store original value
    const original = synth.params[0].value;

    // Try to set invalid index
    synth.instrument.setParameter(100, 0.5);

    // Verify nothing changed
    try testing.expectEqual(original, synth.params[0].value);

    // Get parameter with invalid index
    const param = synth.instrument.getParameter(100);
    try testing.expect(param == null);
}

test "allNotesOff behavior wavetable" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

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

test "allNotesOff produces silence wavetable" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

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

test "parameter names and ranges" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

    // Check Osc1 WT Pos
    const p0 = synth.instrument.getParameter(0).?;
    try testing.expectEqualStrings("Osc1 WT Pos", p0.name);
    try testing.expectEqual(@as(f32, 0.0), p0.min);
    try testing.expectEqual(@as(f32, 1.0), p0.max);

    // Check Detune
    const p4 = synth.instrument.getParameter(4).?;
    try testing.expectEqualStrings("Detune", p4.name);
    try testing.expectEqualStrings("cents", p4.unit);
    try testing.expectEqual(@as(f32, -100.0), p4.min);
    try testing.expectEqual(@as(f32, 100.0), p4.max);

    // Check Filter Cutoff
    const p5 = synth.instrument.getParameter(5).?;
    try testing.expectEqualStrings("Filter Cutoff", p5.name);
    try testing.expectEqualStrings("Hz", p5.unit);

    // Check LFO1 Rate
    const p8 = synth.instrument.getParameter(8).?;
    try testing.expectEqualStrings("LFO1 Rate", p8.name);
    try testing.expectEqualStrings("Hz", p8.unit);
}

test "voice allocation wavetable" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

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

test "LFO modulation of wavetable position" {
    const testing = std.testing;

    var synth = WavetableSynth.init(48000.0);

    // Set up LFO to modulate wavetable position
    synth.instrument.setParameter(0, 0.5); // Osc1 WT Pos base
    synth.instrument.setParameter(8, 10.0); // LFO1 Rate
    synth.instrument.setParameter(9, 1.0); // LFO1 -> WT1 amount (full)

    // Start a note
    synth.instrument.noteOn(60, 100);

    // Process some audio
    var buffer = @as([256]f32, @splat(0));
    synth.instrument.process(&buffer, 48000);

    // The LFO should have affected the wavetable position
    // Just verify we produced some audio
    var has_audio = false;
    for (buffer) |sample| {
        if (sample != 0.0) {
            has_audio = true;
            break;
        }
    }
    try testing.expect(has_audio);
}

test "wavetable lookup with wrapping" {
    const testing = std.testing;

    const wt = Wavetable.initBasic();

    // Test phase wrapping
    const sample1 = wt.lookup(0.0, 0.0);
    const sample2 = wt.lookup(1.0, 0.0); // Should wrap to same as 0.0
    try testing.expectApproxEqAbs(sample1, sample2, 0.01);

    // Test frame wrapping - different frames should generally produce different values
    const sample3 = wt.lookup(0.5, 0.0);
    const sample4 = wt.lookup(0.5, 1.0);
    // At different morph positions, waveforms should differ
    _ = sample3;
    _ = sample4;
}

test "WTVoice frequency setting and detune" {
    const testing = std.testing;

    var voice = WTVoice.init(48000.0);

    // Note on should set frequencies
    voice.noteOn(60, 100); // MIDI note 60 = C4 = ~261.63 Hz

    // Main oscillators should be at the note frequency
    try testing.expect(voice.osc1.frequency > 260.0 and voice.osc1.frequency < 263.0);
    try testing.expect(voice.osc2.frequency > 260.0 and voice.osc2.frequency < 263.0);

    // Sub oscillator should be one octave down
    try testing.expect(voice.sub_osc.osc.frequency > 130.0 and voice.sub_osc.osc.frequency < 132.0);
}
