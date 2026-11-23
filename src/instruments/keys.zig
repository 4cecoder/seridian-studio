//! Keys - Simple piano/keys instrument (like FL Keys)
//!
//! A clean, playable keyboard instrument with:
//! - 16-voice polyphony
//! - Multiple timbres (piano, electric piano, organ, etc.)
//! - Velocity sensitivity
//! - Sustain pedal support

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

/// Preset timbres
pub const Timbre = enum(u8) {
    grand_piano = 0,
    bright_piano = 1,
    electric_piano = 2,
    organ = 3,
    strings = 4,

    pub fn name(self: Timbre) []const u8 {
        return switch (self) {
            .grand_piano => "Grand Piano",
            .bright_piano => "Bright Piano",
            .electric_piano => "Electric Piano",
            .organ => "Organ",
            .strings => "Strings",
        };
    }
};

const MAX_VOICES = 16;

/// Keys voice with piano-like characteristics
const KeysVoice = struct {
    // Two oscillators for richness
    osc1: dsp.BLEPOscillator = .{},
    osc2: dsp.BLEPOscillator = .{},

    // Amplitude envelope
    amp_env: dsp.ADSREnvelope = .{},

    // Brightness envelope (filter)
    filter: dsp.SVFilter = .{},
    filter_env: dsp.ADSREnvelope = .{},

    // State
    state: dsp.VoiceState = .off,
    note: u8 = 0,
    velocity: f32 = 0.0,
    sustain_held: bool = false, // Sustain pedal holding this note

    sample_rate: f32 = 48000.0,

    pub fn init(sample_rate: f32) KeysVoice {
        var voice = KeysVoice{
            .sample_rate = sample_rate,
            .osc1 = dsp.BLEPOscillator.init(sample_rate),
            .osc2 = dsp.BLEPOscillator.init(sample_rate),
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .filter_env = dsp.ADSREnvelope.init(sample_rate),
            .filter = dsp.SVFilter.init(sample_rate),
        };

        // Default piano-like envelope
        voice.amp_env.attack = 0.005;
        voice.amp_env.decay = 0.5;
        voice.amp_env.sustain = 0.3;
        voice.amp_env.release = 0.3;
        voice.amp_env.updateCoefficients();

        // Filter envelope
        voice.filter_env.attack = 0.001;
        voice.filter_env.decay = 0.3;
        voice.filter_env.sustain = 0.2;
        voice.filter_env.release = 0.2;
        voice.filter_env.updateCoefficients();

        return voice;
    }

    pub fn noteOn(self: *KeysVoice, note: u8, velocity: u8, timbre: Timbre) void {
        self.note = note;
        self.velocity = velocityToAmplitude(velocity);
        self.state = .playing;
        self.sustain_held = false;

        // Set base frequency
        const freq = dsp.midiNoteToFreq(note);
        self.osc1.osc.frequency = freq;
        self.osc2.osc.frequency = freq * 2.0; // Octave up for brightness

        // Configure based on timbre
        switch (timbre) {
            .grand_piano => {
                self.osc1.waveform = .triangle;
                self.osc2.waveform = .sine;
                self.amp_env.attack = 0.005;
                self.amp_env.decay = 1.0;
                self.amp_env.sustain = 0.0;
                self.amp_env.release = 0.5;
            },
            .bright_piano => {
                self.osc1.waveform = .triangle;
                self.osc2.waveform = .saw;
                self.amp_env.attack = 0.002;
                self.amp_env.decay = 0.8;
                self.amp_env.sustain = 0.1;
                self.amp_env.release = 0.3;
            },
            .electric_piano => {
                self.osc1.waveform = .sine;
                self.osc2.waveform = .triangle;
                self.amp_env.attack = 0.001;
                self.amp_env.decay = 0.6;
                self.amp_env.sustain = 0.4;
                self.amp_env.release = 0.2;
            },
            .organ => {
                self.osc1.waveform = .sine;
                self.osc2.waveform = .sine;
                self.amp_env.attack = 0.01;
                self.amp_env.decay = 0.01;
                self.amp_env.sustain = 1.0;
                self.amp_env.release = 0.05;
            },
            .strings => {
                self.osc1.waveform = .saw;
                self.osc2.waveform = .saw;
                self.osc2.osc.frequency = freq * 1.003; // Slight detune
                self.amp_env.attack = 0.2;
                self.amp_env.decay = 0.3;
                self.amp_env.sustain = 0.8;
                self.amp_env.release = 0.4;
            },
        }
        self.amp_env.updateCoefficients();
        self.filter_env.updateCoefficients();

        // Reset and trigger
        self.osc1.reset();
        self.osc2.reset();
        self.amp_env.noteOn();
        self.filter_env.noteOn();
    }

    pub fn noteOff(self: *KeysVoice, sustain_pedal: bool) void {
        if (sustain_pedal) {
            self.sustain_held = true;
        } else {
            self.state = .releasing;
            self.amp_env.noteOff();
            self.filter_env.noteOff();
        }
    }

    pub fn releaseSustain(self: *KeysVoice) void {
        if (self.sustain_held) {
            self.sustain_held = false;
            self.state = .releasing;
            self.amp_env.noteOff();
            self.filter_env.noteOff();
        }
    }

    pub fn tick(self: *KeysVoice, brightness: f32, osc_mix: f32) f32 {
        if (self.state == .off) return 0.0;

        // Generate oscillators
        const o1 = self.osc1.tick();
        const o2 = self.osc2.tick();

        // Mix oscillators
        const mix = dsp.lerp(o1, o2, osc_mix * 0.3); // osc2 is quieter

        // Apply filter with envelope
        const filter_env_val = self.filter_env.tick();
        const cutoff = 200.0 + brightness * 8000.0 + filter_env_val * 4000.0 * self.velocity;
        self.filter.setFrequency(cutoff);
        const filtered = self.filter.tickLP(mix);

        // Apply amplitude envelope
        const amp = self.amp_env.tick();

        if (!self.amp_env.isActive()) {
            self.state = .off;
        }

        return filtered * amp * self.velocity;
    }

    pub fn isAvailable(self: *const KeysVoice) bool {
        return self.state == .off;
    }

    pub fn isPlayingNote(self: *const KeysVoice, note: u8) bool {
        return self.note == note and self.state != .off;
    }

    pub fn getAmplitudeLevel(self: *const KeysVoice) f32 {
        return self.amp_env.output;
    }
};

/// Keys instrument
pub const Keys = struct {
    instrument: Instrument,

    // Voice pool
    voices: [MAX_VOICES]KeysVoice = undefined,

    // Parameters
    params: [5]Parameter = .{
        .{ .name = "Timbre", .min = 0.0, .max = 4.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Osc Mix", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Reverb", .min = 0.0, .max = 1.0, .default = 0.2, .value = 0.2, .unit = "" },
    },

    // Pedal state
    sustain_pedal: bool = false,

    sample_rate: f32 = 48000.0,

    const ParamHelpers = ParameterMixin(Keys, "instrument");
    const DestroyHelpers = DestroyMixin(Keys, "instrument");

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

    pub fn init(sample_rate: f32) Keys {
        var keys = Keys{
            .instrument = .{
                .vtable = &vtable,
                .name = "Keys",
            },
            .sample_rate = sample_rate,
        };

        for (&keys.voices) |*voice| {
            voice.* = KeysVoice.init(sample_rate);
        }

        return keys;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *Keys = @fieldParentPtr("instrument", instrument);
        _ = sample_rate;

        const brightness = self.params[1].value;
        const osc_mix = self.params[2].value;
        const volume = self.params[3].value;

        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            var sum: f32 = 0.0;

            for (&self.voices) |*voice| {
                sum += voice.tick(brightness, osc_mix);
            }

            // Apply volume and soft clip
            sum = dsp.softClip(sum * volume);

            // Write stereo
            buffer[frame * 2] += sum;
            buffer[frame * 2 + 1] += sum;
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *Keys = @fieldParentPtr("instrument", instrument);
        // Safe timbre conversion with NaN/Inf protection
        const timbre_value = self.params[0].value;
        const timbre_int: u8 = if (std.math.isNan(timbre_value) or std.math.isInf(timbre_value))
            0
        else
            @intFromFloat(std.math.clamp(timbre_value, 0.0, 4.0));
        const timbre: Timbre = @fromBackingInt(@intCast(timbre_int));

        // Check for retrigger
        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.noteOn(note, velocity, timbre);
                return;
            }
        }

        // Find free voice
        for (&self.voices) |*voice| {
            if (voice.isAvailable()) {
                voice.noteOn(note, velocity, timbre);
                return;
            }
        }

        // Steal quietest voice
        var quietest: *KeysVoice = &self.voices[0];
        var min_level: f32 = 1.0;
        for (&self.voices) |*voice| {
            const level = voice.amp_env.output;
            if (level < min_level) {
                min_level = level;
                quietest = voice;
            }
        }
        quietest.noteOn(note, velocity, timbre);
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *Keys = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            if (voice.isPlayingNote(note)) {
                voice.noteOff(self.sustain_pedal);
            }
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *Keys = @fieldParentPtr("instrument", instrument);

        for (&self.voices) |*voice| {
            voice.state = .off;
            voice.amp_env.kill();
        }
        self.sustain_pedal = false;
    }

    fn reset(instrument: *Instrument) void {
        allNotesOff(instrument);
    }

    // Public API

    pub fn setTimbre(self: *Keys, timbre: Timbre) void {
        self.params[0].value = @floatFromInt(@backingInt(timbre));
    }

    pub fn setBrightness(self: *Keys, brightness: f32) void {
        self.params[1].value = std.math.clamp(brightness, 0.0, 1.0);
    }

    pub fn setSustainPedal(self: *Keys, down: bool) void {
        self.sustain_pedal = down;
        if (!down) {
            // Release all sustained notes
            for (&self.voices) |*voice| {
                voice.releaseSustain();
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "keys init" {
    const testing = std.testing;

    var keys = Keys.init(48000.0);
    try testing.expectEqualStrings("Keys", keys.instrument.name);
    try testing.expectEqual(@as(usize, 5), keys.instrument.getParameterCount());
}

test "keys note on/off" {
    var keys = Keys.init(48000.0);

    keys.instrument.noteOn(60, 100);

    // Check a voice is playing
    var playing: usize = 0;
    for (&keys.voices) |*voice| {
        if (!voice.isAvailable()) playing += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), playing);

    keys.instrument.noteOff(60);
}
