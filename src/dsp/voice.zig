//! Voice - Complete synthesizer voice
//!
//! Combines oscillator + envelope + filter into a single playable voice.
//! Designed for polyphonic synthesizers.

const std = @import("std");
const osc = @import("oscillator.zig");
const env = @import("envelope.zig");
const flt = @import("filter.zig");
const inst = @import("../instruments/instrument.zig");

const velocityToAmplitude = inst.velocityToAmplitude;

/// Voice state
pub const VoiceState = enum(u8) {
    off,
    playing,
    releasing,
};

/// Synth voice with oscillator, amplitude envelope, and filter
pub const Voice = struct {
    // Oscillators (2 for detuning/unison)
    osc1: osc.BLEPOscillator = .{},
    osc2: osc.BLEPOscillator = .{},

    // Envelopes
    amp_env: env.ADSREnvelope = .{},
    filter_env: env.ADSREnvelope = .{},

    // Filter
    filter: flt.SVFilter = .{},

    // Voice state
    state: VoiceState = .off,
    note: u8 = 0,
    velocity: f32 = 0.0,

    // Parameters
    osc_mix: f32 = 0.5, // 0.0 = osc1 only, 1.0 = osc2 only
    osc2_detune: f32 = 0.0, // Cents
    filter_cutoff: f32 = 5000.0,
    filter_env_amount: f32 = 0.0, // How much envelope affects filter

    sample_rate: f32 = 48000.0,

    pub fn init(sample_rate: f32) Voice {
        return .{
            .osc1 = osc.BLEPOscillator.init(sample_rate),
            .osc2 = osc.BLEPOscillator.init(sample_rate),
            .amp_env = env.ADSREnvelope.init(sample_rate),
            .filter_env = env.ADSREnvelope.init(sample_rate),
            .filter = flt.SVFilter.init(sample_rate),
            .sample_rate = sample_rate,
        };
    }

    /// Trigger note on
    pub fn noteOn(self: *Voice, note: u8, velocity: u8) void {
        self.note = note;
        self.velocity = velocityToAmplitude(velocity);
        self.state = .playing;

        // Set oscillator frequencies
        const freq = osc.midiNoteToFreq(note);
        self.osc1.osc.frequency = freq;

        // Apply detune to osc2
        const detune_mult = std.math.pow(f32, 2.0, self.osc2_detune / 1200.0);
        self.osc2.osc.frequency = freq * detune_mult;

        // Trigger envelopes
        self.amp_env.noteOn();
        self.filter_env.noteOn();
    }

    /// Trigger note off
    pub fn noteOff(self: *Voice) void {
        if (self.state == .playing) {
            self.state = .releasing;
            self.amp_env.noteOff();
            self.filter_env.noteOff();
        }
    }

    /// Force voice off immediately
    pub fn kill(self: *Voice) void {
        self.state = .off;
        self.amp_env.kill();
        self.filter_env.kill();
        self.osc1.reset();
        self.osc2.reset();
        self.filter.reset();
    }

    /// Process one sample
    pub fn tick(self: *Voice) f32 {
        if (self.state == .off) return 0.0;

        // Get oscillator outputs
        const o1 = self.osc1.tick();
        const o2 = self.osc2.tick();

        // Mix oscillators
        const osc_out = o1 * (1.0 - self.osc_mix) + o2 * self.osc_mix;

        // Update filter cutoff with envelope
        const filter_env_val = self.filter_env.tick();
        const cutoff = self.filter_cutoff + self.filter_env_amount * filter_env_val * 10000.0;
        self.filter.setFrequency(cutoff);

        // Apply filter
        const filtered = self.filter.tickLP(osc_out);

        // Apply amplitude envelope
        const amp = self.amp_env.tick();

        // Check if voice finished
        if (!self.amp_env.isActive()) {
            self.state = .off;
        }

        return filtered * amp * self.velocity;
    }

    /// Check if voice is available for new note
    pub fn isAvailable(self: *const Voice) bool {
        return self.state == .off;
    }

    /// Check if voice is playing this note
    pub fn isPlayingNote(self: *const Voice, note: u8) bool {
        return self.note == note and self.state != .off;
    }

    /// Get current amplitude envelope level (for voice stealing)
    pub fn getEnvelopeLevel(self: *const Voice) f32 {
        return self.amp_env.output;
    }

    /// Get current amplitude level (alias for getEnvelopeLevel - for generic interface)
    pub fn getAmplitudeLevel(self: *const Voice) f32 {
        return self.getEnvelopeLevel();
    }
};

/// Voice pool for polyphonic synths
pub fn VoicePool(comptime max_voices: usize) type {
    return struct {
        const Self = @This();

        voices: [max_voices]Voice = undefined,

        pub fn init(sample_rate: f32) Self {
            var pool: Self = .{};
            for (&pool.voices) |*voice| {
                voice.* = Voice.init(sample_rate);
            }
            return pool;
        }

        /// Find and allocate a voice for a note
        pub fn noteOn(self: *Self, note: u8, velocity: u8) void {
            // First, check if this note is already playing (retrigger)
            for (&self.voices) |*voice| {
                if (voice.isPlayingNote(note)) {
                    voice.noteOn(note, velocity);
                    return;
                }
            }

            // Find a free voice
            for (&self.voices) |*voice| {
                if (voice.isAvailable()) {
                    voice.noteOn(note, velocity);
                    return;
                }
            }

            // Voice stealing: find quietest voice
            var quietest: *Voice = &self.voices[0];
            var min_level: f32 = 1.0;
            for (&self.voices) |*voice| {
                const level = voice.getEnvelopeLevel();
                if (level < min_level) {
                    min_level = level;
                    quietest = voice;
                }
            }
            quietest.noteOn(note, velocity);
        }

        /// Release all voices playing this note
        pub fn noteOff(self: *Self, note: u8) void {
            for (&self.voices) |*voice| {
                if (voice.isPlayingNote(note)) {
                    voice.noteOff();
                }
            }
        }

        /// Release all voices
        pub fn allNotesOff(self: *Self) void {
            for (&self.voices) |*voice| {
                voice.noteOff();
            }
        }

        /// Kill all voices immediately
        pub fn panic(self: *Self) void {
            for (&self.voices) |*voice| {
                voice.kill();
            }
        }

        /// Process one sample (sum all voices)
        pub fn tick(self: *Self) f32 {
            var sum: f32 = 0.0;
            for (&self.voices) |*voice| {
                sum += voice.tick();
            }
            return sum;
        }

        /// Set waveform for all voices
        pub fn setWaveform(self: *Self, waveform: osc.Waveform) void {
            for (&self.voices) |*voice| {
                voice.osc1.waveform = waveform;
                voice.osc2.waveform = waveform;
            }
        }

        /// Set ADSR for all voices
        pub fn setADSR(self: *Self, attack: f32, decay: f32, sustain: f32, release: f32) void {
            for (&self.voices) |*voice| {
                voice.amp_env.setAttack(attack);
                voice.amp_env.setDecay(decay);
                voice.amp_env.setSustain(sustain);
                voice.amp_env.setRelease(release);
            }
        }

        /// Set filter cutoff for all voices
        pub fn setFilterCutoff(self: *Self, cutoff: f32) void {
            for (&self.voices) |*voice| {
                voice.filter_cutoff = cutoff;
            }
        }

        /// Set osc2 detune for all voices
        pub fn setDetune(self: *Self, cents: f32) void {
            for (&self.voices) |*voice| {
                voice.osc2_detune = cents;
            }
        }
    };
}

// =============================================================================
// Generic Voice Pool
// =============================================================================

/// Compile-time interface validation for voice types
/// Checks that a type has all required methods with correct signatures
fn VoiceInterface(comptime V: type) void {
    comptime {
        const type_info = @typeInfo(V);
        if (type_info != .@"struct") {
            @compileError("Voice type must be a struct");
        }

        // Check required methods exist
        if (!@hasDecl(V, "isAvailable")) {
            @compileError("Voice type must have 'isAvailable() bool' method");
        }
        if (!@hasDecl(V, "isPlayingNote")) {
            @compileError("Voice type must have 'isPlayingNote(note: u8) bool' method");
        }
        if (!@hasDecl(V, "getAmplitudeLevel")) {
            @compileError("Voice type must have 'getAmplitudeLevel() f32' method");
        }
        if (!@hasDecl(V, "noteOn")) {
            @compileError("Voice type must have 'noteOn(note: u8, velocity: u8) void' method");
        }
        if (!@hasDecl(V, "noteOff")) {
            @compileError("Voice type must have 'noteOff() void' method");
        }

        // Validate method signatures
        const isAvailable_info = @typeInfo(@TypeOf(V.isAvailable));
        if (isAvailable_info != .@"fn") {
            @compileError("isAvailable must be a function");
        }

        const isPlayingNote_info = @typeInfo(@TypeOf(V.isPlayingNote));
        if (isPlayingNote_info != .@"fn") {
            @compileError("isPlayingNote must be a function");
        }

        const getAmplitudeLevel_info = @typeInfo(@TypeOf(V.getAmplitudeLevel));
        if (getAmplitudeLevel_info != .@"fn") {
            @compileError("getAmplitudeLevel must be a function");
        }

        const noteOn_info = @typeInfo(@TypeOf(V.noteOn));
        if (noteOn_info != .@"fn") {
            @compileError("noteOn must be a function");
        }

        const noteOff_info = @typeInfo(@TypeOf(V.noteOff));
        if (noteOff_info != .@"fn") {
            @compileError("noteOff must be a function");
        }
    }
}

/// Generic voice pool that works with any voice type implementing the voice interface
///
/// The voice type must implement:
/// - isAvailable() bool - Check if voice is free
/// - isPlayingNote(note: u8) bool - Check if voice is playing a specific note
/// - getAmplitudeLevel() f32 - Get current amplitude for voice stealing
/// - noteOn(note: u8, velocity: u8) void - Trigger note
/// - noteOff() void - Release note
///
/// Example:
/// ```zig
/// const MyVoicePool = GenericVoicePool(MyVoiceType, 8);
/// var pool = MyVoicePool.init(sample_rate);
/// pool.noteOn(60, 100);
/// ```
pub fn GenericVoicePool(comptime VoiceType: type, comptime max_voices: usize) type {
    // Validate at compile time
    VoiceInterface(VoiceType);

    return struct {
        const Self = @This();

        voices: [max_voices]VoiceType,

        /// Find and allocate a voice for a note
        ///
        /// Algorithm:
        /// 1. Check for retrigger - if note already playing, retrigger it
        /// 2. Find free voice if available
        /// 3. Steal quietest voice if all voices busy
        pub fn noteOn(self: *Self, note: u8, velocity: u8) void {
            // 1. Retrigger check - if this note is already playing, retrigger it
            for (&self.voices) |*voice| {
                if (voice.isPlayingNote(note)) {
                    voice.noteOn(note, velocity);
                    return;
                }
            }

            // 2. Find free voice
            for (&self.voices) |*voice| {
                if (voice.isAvailable()) {
                    voice.noteOn(note, velocity);
                    return;
                }
            }

            // 3. Voice stealing: find quietest voice
            var quietest: *VoiceType = &self.voices[0];
            var min_level: f32 = 1.0;
            for (&self.voices) |*voice| {
                const level = voice.getAmplitudeLevel();
                if (level < min_level) {
                    min_level = level;
                    quietest = voice;
                }
            }
            quietest.noteOn(note, velocity);
        }

        /// Release all voices playing this note
        pub fn noteOff(self: *Self, note: u8) void {
            for (&self.voices) |*voice| {
                if (voice.isPlayingNote(note)) {
                    voice.noteOff();
                }
            }
        }

        /// Release all voices
        pub fn allNotesOff(self: *Self) void {
            for (&self.voices) |*voice| {
                if (!voice.isAvailable()) {
                    voice.noteOff();
                }
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "voice lifecycle" {
    const testing = std.testing;

    var voice = Voice.init(48000.0);

    try testing.expectEqual(VoiceState.off, voice.state);
    try testing.expect(voice.isAvailable());

    voice.noteOn(60, 100); // Middle C
    try testing.expectEqual(VoiceState.playing, voice.state);
    try testing.expect(!voice.isAvailable());

    // Process some samples
    for (0..100) |_| {
        _ = voice.tick();
    }

    voice.noteOff();
    try testing.expectEqual(VoiceState.releasing, voice.state);

    // Run until voice finishes
    for (0..100000) |_| {
        _ = voice.tick();
        if (voice.state == .off) break;
    }
    try testing.expectEqual(VoiceState.off, voice.state);
}

test "voice pool polyphony" {
    const testing = std.testing;

    var pool = VoicePool(8).init(48000.0);

    // Play a chord
    pool.noteOn(60, 100); // C
    pool.noteOn(64, 100); // E
    pool.noteOn(67, 100); // G

    // All three should be playing
    var playing: usize = 0;
    for (&pool.voices) |*voice| {
        if (!voice.isAvailable()) playing += 1;
    }
    try testing.expectEqual(@as(usize, 3), playing);

    pool.allNotesOff();
}

test "generic voice pool with Voice type" {
    const testing = std.testing;

    // Create a generic pool using the Voice type
    const GenericPool = GenericVoicePool(Voice, 4);
    var pool: GenericPool = .{
        .voices = [_]Voice{
            Voice.init(48000.0),
            Voice.init(48000.0),
            Voice.init(48000.0),
            Voice.init(48000.0),
        },
    };

    // Test note on
    pool.noteOn(60, 100);
    pool.noteOn(64, 100);

    // Check that 2 voices are active
    var active: usize = 0;
    for (&pool.voices) |*voice| {
        if (!voice.isAvailable()) active += 1;
    }
    try testing.expectEqual(@as(usize, 2), active);

    // Test retrigger - should retrigger same note, not allocate new voice
    pool.noteOn(60, 80);
    active = 0;
    for (&pool.voices) |*voice| {
        if (!voice.isAvailable()) active += 1;
    }
    try testing.expectEqual(@as(usize, 2), active);

    // Test note off
    pool.noteOff(60);

    // Test all notes off
    pool.allNotesOff();

    // Process to let voices finish
    for (0..100000) |_| {
        var all_off = true;
        for (&pool.voices) |*voice| {
            _ = voice.tick();
            if (!voice.isAvailable()) all_off = false;
        }
        if (all_off) break;
    }

    // All voices should be available now
    for (&pool.voices) |*voice| {
        try testing.expect(voice.isAvailable());
    }
}

test "generic voice pool voice stealing" {
    const testing = std.testing;

    const GenericPool = GenericVoicePool(Voice, 2);
    var pool: GenericPool = .{
        .voices = [_]Voice{
            Voice.init(48000.0),
            Voice.init(48000.0),
        },
    };

    // Fill all voices
    pool.noteOn(60, 100);
    pool.noteOn(64, 100);

    // Process some samples so first voice gets quieter
    for (0..10000) |_| {
        _ = pool.voices[0].tick();
        _ = pool.voices[1].tick();
    }

    // Add another note - should steal quietest voice
    pool.noteOn(67, 100);

    // Should still have only 2 active voices
    var active: usize = 0;
    for (&pool.voices) |*voice| {
        if (!voice.isAvailable()) active += 1;
    }
    try testing.expectEqual(@as(usize, 2), active);
}
