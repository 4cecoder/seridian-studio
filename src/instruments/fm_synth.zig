//! FM Synth - Classic 4-operator FM synthesizer
//!
//! Features:
//! - 4 operators (carrier + 3 modulators)
//! - Classic DX7-style algorithms
//! - Individual operator envelopes
//! - Feedback on operator 4
//! - 16-voice polyphony

const std = @import("std");
const math = std.math;
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = 16;
const TWO_PI = 2.0 * math.pi;

/// FM Algorithm configurations
/// Op1 is always the carrier (output)
pub const FMAlgorithm = enum(u8) {
    /// Op4 -> Op3 -> Op2 -> Op1 (classic stack)
    stack = 0,
    /// Op4 -> Op3 -> Op2, Op2 -> Op1, Op3 -> Op1 (parallel modulators)
    parallel = 1,
    /// (Op4 -> Op3) + (Op2) -> Op1 (two modulator chains)
    dual = 2,
    /// Op4 -> Op3, Op4 -> Op2, all -> Op1 (branching)
    branch = 3,
    /// All operators as carriers (additive)
    additive = 4,

    pub fn name(self: FMAlgorithm) []const u8 {
        return switch (self) {
            .stack => "Stack",
            .parallel => "Parallel",
            .dual => "Dual",
            .branch => "Branch",
            .additive => "Additive",
        };
    }
};

/// Single FM operator
const FMOperator = struct {
    phase: f32 = 0.0,
    frequency: f32 = 440.0,
    ratio: f32 = 1.0, // Frequency ratio to fundamental
    level: f32 = 1.0, // Output level
    envelope: dsp.ADSREnvelope,
    feedback_sample: f32 = 0.0, // For feedback

    sample_rate: f32,

    pub fn init(sample_rate: f32) FMOperator {
        return .{
            .envelope = dsp.ADSREnvelope.init(sample_rate),
            .sample_rate = sample_rate,
        };
    }

    pub fn setFrequency(self: *FMOperator, base_freq: f32) void {
        self.frequency = base_freq * self.ratio;
    }

    pub fn tick(self: *FMOperator, phase_mod: f32) f32 {
        const env = self.envelope.tick();
        const modulated_phase = self.phase + phase_mod;
        const sample = @sin(modulated_phase * TWO_PI) * self.level * env;

        // Advance phase
        self.phase += self.frequency / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return sample;
    }

    pub fn tickWithFeedback(self: *FMOperator, feedback_amount: f32) f32 {
        const env = self.envelope.tick();
        const feedback = self.feedback_sample * feedback_amount;
        const modulated_phase = self.phase + feedback;
        const sample = @sin(modulated_phase * TWO_PI) * self.level * env;

        self.feedback_sample = sample;

        // Advance phase
        self.phase += self.frequency / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return sample;
    }

    pub fn reset(self: *FMOperator) void {
        self.phase = 0.0;
        self.feedback_sample = 0.0;
    }

    pub fn noteOn(self: *FMOperator) void {
        self.envelope.noteOn();
    }

    pub fn noteOff(self: *FMOperator) void {
        self.envelope.noteOff();
    }
};

/// FM Synth voice
const FMVoice = struct {
    // 4 operators
    ops: [4]FMOperator = undefined,

    // State
    state: dsp.VoiceState = .off,
    note: u8 = 0,
    velocity: f32 = 0.0,
    base_frequency: f32 = 440.0,

    sample_rate: f32,

    pub fn init(sample_rate: f32) FMVoice {
        var voice = FMVoice{
            .sample_rate = sample_rate,
        };

        for (&voice.ops) |*op| {
            op.* = FMOperator.init(sample_rate);
        }

        // Set default ratios (classic FM ratios)
        voice.ops[0].ratio = 1.0; // Carrier
        voice.ops[1].ratio = 1.0; // Modulator
        voice.ops[2].ratio = 2.0; // Modulator (octave up)
        voice.ops[3].ratio = 3.0; // Modulator (fifth + octave)

        return voice;
    }

    pub fn noteOn(self: *FMVoice, note: u8, velocity: u8) void {
        self.note = note;
        self.velocity = velocityToAmplitude(velocity);
        self.state = .playing;

        self.base_frequency = dsp.midiNoteToFreq(note);

        for (&self.ops) |*op| {
            op.setFrequency(self.base_frequency);
            op.reset();
            op.noteOn();
        }
    }

    pub fn noteOff(self: *FMVoice) void {
        if (self.state == .playing) {
            self.state = .releasing;
            for (&self.ops) |*op| {
                op.noteOff();
            }
        }
    }

    pub fn tick(
        self: *FMVoice,
        algorithm: FMAlgorithm,
        mod_depth: f32,
        feedback: f32,
        op_levels: [4]f32,
        op_ratios: [4]f32,
    ) f32 {
        if (self.state == .off) return 0.0;

        // Update operator settings
        for (&self.ops, 0..) |*op, i| {
            op.level = op_levels[i];
            op.ratio = op_ratios[i];
            op.setFrequency(self.base_frequency);
        }

        var output: f32 = 0.0;

        const m = mod_depth * 4.0; // Higher depth for more audible FM

        switch (algorithm) {
            .stack => {
                // Op4 -> Op3 -> Op2 -> Op1
                const op4 = self.ops[3].tickWithFeedback(feedback * 0.5);
                const op3 = self.ops[2].tick(op4 * m);
                const op2 = self.ops[1].tick(op3 * m);
                output = self.ops[0].tick(op2 * m);
            },
            .parallel => {
                // Op4 -> Op3, Op3 -> Op2, (Op2 + Op3) -> Op1
                const op4 = self.ops[3].tickWithFeedback(feedback * 0.5);
                const op3 = self.ops[2].tick(op4 * m);
                const op2 = self.ops[1].tick(op3 * m);
                output = self.ops[0].tick((op2 + op3) * m * 0.5);
            },
            .dual => {
                // (Op4 -> Op3) + Op2 -> Op1
                const op4 = self.ops[3].tickWithFeedback(feedback * 0.5);
                const op3 = self.ops[2].tick(op4 * m);
                const op2 = self.ops[1].tick(0);
                output = self.ops[0].tick((op3 + op2) * m * 0.5);
            },
            .branch => {
                // Op4 modulates both Op3 and Op2, all to Op1
                const op4 = self.ops[3].tickWithFeedback(feedback * 0.5);
                const op3 = self.ops[2].tick(op4 * m);
                const op2 = self.ops[1].tick(op4 * m);
                output = self.ops[0].tick((op3 + op2) * m * 0.5);
            },
            .additive => {
                // All operators as carriers (pure additive)
                _ = self.ops[3].tickWithFeedback(feedback * 0.5);
                const op4_out = self.ops[3].feedback_sample * 0.25;
                const op3_out = self.ops[2].tick(0) * 0.25;
                const op2_out = self.ops[1].tick(0) * 0.25;
                const op1_out = self.ops[0].tick(0) * 0.25;
                output = op1_out + op2_out + op3_out + op4_out;
            },
        }

        // Check if voice is done
        if (!self.ops[0].envelope.isActive()) {
            self.state = .off;
        }

        return output * self.velocity;
    }

    pub fn isAvailable(self: *const FMVoice) bool {
        return self.state == .off;
    }

    pub fn isPlayingNote(self: *const FMVoice, note: u8) bool {
        return self.note == note and self.state != .off;
    }

    pub fn getAmplitudeLevel(self: *const FMVoice) f32 {
        return self.ops[0].envelope.output;
    }
};

/// FM Synth instrument
pub const FMSynth = struct {
    instrument: Instrument,

    // Voice pool
    voices: [MAX_VOICES]FMVoice = undefined,

    // Current algorithm
    algorithm: FMAlgorithm = .stack,

    // Parameters
    params: [12]Parameter = .{
        .{ .name = "Algorithm", .min = 0.0, .max = 4.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Mod Depth", .min = 0.0, .max = 2.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Feedback", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Op2 Ratio", .min = 0.5, .max = 8.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Op3 Ratio", .min = 0.5, .max = 8.0, .default = 2.0, .value = 2.0, .unit = "" },
        .{ .name = "Op4 Ratio", .min = 0.5, .max = 8.0, .default = 3.0, .value = 3.0, .unit = "" },
        .{ .name = "Attack", .min = 0.001, .max = 2.0, .default = 0.01, .value = 0.01, .unit = "s" },
        .{ .name = "Decay", .min = 0.001, .max = 2.0, .default = 0.3, .value = 0.3, .unit = "s" },
        .{ .name = "Sustain", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Release", .min = 0.001, .max = 5.0, .default = 0.3, .value = 0.3, .unit = "s" },
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },

    sample_rate: f32 = 48000.0,

    const ParamHelpers = ParameterMixin(FMSynth, "instrument");
    const DestroyHelpers = DestroyMixin(FMSynth, "instrument");

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

    pub fn init(sample_rate: f32) FMSynth {
        var synth = FMSynth{
            .instrument = .{
                .vtable = &vtable,
                .name = "FM Synth",
            },
            .sample_rate = sample_rate,
        };

        for (&synth.voices) |*voice| {
            voice.* = FMVoice.init(sample_rate);
        }

        return synth;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *FMSynth = @fieldParentPtr("instrument", instrument);
        _ = sample_rate;

        // Safe conversion: clamp and validate before integer conversion
        const alg_value = self.params[0].value;
        const alg_int: u8 = if (std.math.isNan(alg_value) or std.math.isInf(alg_value))
            0
        else
            @intFromFloat(std.math.clamp(alg_value, 0.0, 4.0));
        const algorithm = @as(FMAlgorithm, @fromBackingInt(@intCast(alg_int)));
        const mod_depth = if (std.math.isNan(self.params[1].value)) 1.0 else self.params[1].value;
        const feedback = if (std.math.isNan(self.params[2].value)) 0.0 else self.params[2].value;
        const brightness = self.params[11].value;
        const volume = self.params[10].value;

        // Operator levels based on brightness - slightly higher defaults
        const op_levels = [4]f32{
            1.0, // Carrier always full
            0.6 + brightness * 0.4,
            0.4 + brightness * 0.4,
            0.3 + brightness * 0.3,
        };

        // Operator ratios from parameters
        const op_ratios = [4]f32{
            1.0, // Carrier ratio fixed
            self.params[3].value,
            self.params[4].value,
            self.params[5].value,
        };

        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            var sum: f32 = 0.0;

            for (&self.voices) |*voice| {
                sum += voice.tick(algorithm, mod_depth, feedback, op_levels, op_ratios);
            }

            // Apply volume and soft clip
            sum = dsp.softClip(sum * volume);

            // Write stereo
            buffer[frame * 2] += sum;
            buffer[frame * 2 + 1] += sum;
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *FMSynth = @fieldParentPtr("instrument", instrument);

        // Set ADSR from parameters
        const attack = self.params[6].value;
        const decay = self.params[7].value;
        const sustain = self.params[8].value;
        const release = self.params[9].value;

        // Retrigger check
        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                setVoiceEnvelopes(voice, attack, decay, sustain, release);
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Find free voice
        for (&self.voices) |*voice| {
            if (voice.isAvailable()) {
                setVoiceEnvelopes(voice, attack, decay, sustain, release);
                voice.noteOn(note, velocity);
                return;
            }
        }

        // Steal quietest
        var quietest: *FMVoice = &self.voices[0];
        var min_level: f32 = 1.0;
        for (&self.voices) |*voice| {
            const level = voice.ops[0].envelope.output;
            if (level < min_level) {
                min_level = level;
                quietest = voice;
            }
        }
        setVoiceEnvelopes(quietest, attack, decay, sustain, release);
        quietest.noteOn(note, velocity);
    }

    fn setVoiceEnvelopes(voice: *FMVoice, attack: f32, decay: f32, sustain: f32, release: f32) void {
        for (&voice.ops, 0..) |*op, i| {
            // Modulators have slightly faster envelopes
            const mod_factor: f32 = if (i == 0) 1.0 else 0.7;
            op.envelope.setAttack(attack * mod_factor);
            op.envelope.setDecay(decay * mod_factor);
            op.envelope.setSustain(sustain);
            op.envelope.setRelease(release * mod_factor);
            op.envelope.updateCoefficients();
        }
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *FMSynth = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.noteOff();
            }
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *FMSynth = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            voice.state = .off;
            for (&voice.ops) |*op| {
                op.envelope.kill();
            }
        }
    }

    fn reset(instrument: *Instrument) void {
        allNotesOff(instrument);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "fm synth init" {
    const testing = std.testing;

    var synth = FMSynth.init(48000.0);
    try testing.expectEqualStrings("FM Synth", synth.instrument.name);
    try testing.expectEqual(@as(usize, 12), synth.instrument.getParameterCount());
}

test "fm synth note on/off" {
    var synth = FMSynth.init(48000.0);

    synth.instrument.noteOn(60, 100);

    var buffer = @as([256]f32, @splat(0));
    synth.instrument.process(&buffer, 48000);

    synth.instrument.noteOff(60);
}

test "fm synth algorithms" {
    var synth = FMSynth.init(48000.0);

    // Test each algorithm
    for (0..5) |alg| {
        synth.instrument.setParameter(0, @as(f32, @floatFromInt(alg)));
        synth.instrument.noteOn(60, 100);

        var buffer = @as([256]f32, @splat(0));
        synth.instrument.process(&buffer, 48000);

        var max_val: f32 = 0.0;
        for (buffer) |s| {
            if (@abs(s) > max_val) max_val = @abs(s);
        }
        std.debug.print("Alg {d} max output: {d}\n", .{ alg, max_val });

        synth.instrument.noteOff(60);
        synth.instrument.allNotesOff();
    }
}
