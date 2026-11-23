//! Orchestra - orchestral instrument patches
//!
//! Four separate instruments, each implementing the Instrument VTable:
//! - Strings:  several detuned saws, slow attack (~0.3 s), lowpass
//! - Brass:    saw pair with a filter envelope and amplitude swell
//! - Woodwind: sine with a little breath noise
//! - Harp:     Karplus-Strong plucked string
//!
//! All processing is real-time safe: fixed-size voice pools, no allocation.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = inst.MAX_VOICES;

/// Cheap xorshift32 noise source (real-time safe).
const Noise = struct {
    state: u32 = 0x1234_5678,

    /// Returns a value in [-1, 1).
    fn next(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        const top: u32 = x >> 8; // 24 bits, exactly representable in f32
        return @as(f32, @floatFromInt(top)) / 8388608.0 - 1.0;
    }
};

/// Detune ratio for a number of cents.
fn centsRatio(cents: f32) f32 {
    return std.math.pow(f32, 2.0, cents / 1200.0);
}

// =============================================================================
// Generic polyphonic host. `V` is the voice type and provides:
//   init(sample_rate) V, noteOn(note, velocity, brightness), noteOff(),
//   tick(brightness) f32, kill(), isActive() bool, level() f32,
//   plus fields `note: u8` and `gate: bool`.
// Each public patch below is its own distinct struct type.
// =============================================================================

fn Patch(comptime V: type, comptime patch_name: []const u8, comptime default_brightness: f32) type {
    return struct {
        instrument: Instrument,
        voices: [MAX_VOICES]V = undefined,

        params: [2]Parameter = .{
            .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = default_brightness, .value = default_brightness, .unit = "" },
            .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        },

        sample_rate: f32 = 48000.0,

        const Self = @This();
        const ParamHelpers = ParameterMixin(Self, "instrument");
        const DestroyHelpers = DestroyMixin(Self, "instrument");

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

        pub fn init(sample_rate: f32) Self {
            var self = Self{
                .instrument = .{ .vtable = &vtable, .name = patch_name },
                .sample_rate = sample_rate,
            };
            for (&self.voices, 0..) |*voice, i| {
                voice.* = V.init(sample_rate);
                voice.noise.state +%= @as(u32, @intCast(i)) *% 0x9E37_79B9;
            }
            return self;
        }

        /// Apply a voice configuration to every voice and rename the instrument.
        /// Only available for voice types that declare `Config` and `configure`.
        pub fn configure(self: *Self, name: []const u8, cfg: V.Config) void {
            self.instrument.name = name;
            for (&self.voices) |*voice| voice.configure(cfg);
        }

        /// Allocate an instance on the heap; free with `instrument.destroy(allocator)`.
        pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*Self {
            const self = try allocator.create(Self);
            self.* = init(sample_rate);
            return self;
        }

        fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            _ = sample_rate;

            const brightness = self.params[0].value;
            const volume = self.params[1].value;
            const frames = buffer.len / 2;

            for (0..frames) |frame| {
                var left: f32 = 0.0;
                var right: f32 = 0.0;
                for (&self.voices) |*voice| {
                    if (comptime @hasDecl(V, "tickStereo")) {
                        const lr = voice.tickStereo(brightness);
                        left += lr[0];
                        right += lr[1];
                    } else {
                        const x = voice.tick(brightness);
                        left += x;
                        right += x;
                    }
                }
                buffer[frame * 2] += dsp.softClip(left * volume);
                buffer[frame * 2 + 1] += dsp.softClip(right * volume);
            }
        }

        fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            const brightness = self.params[0].value;

            // Retrigger same note
            for (&self.voices) |*voice| {
                if (voice.isActive() and voice.note == note) {
                    voice.noteOn(note, velocity, brightness);
                    return;
                }
            }
            // Free voice
            for (&self.voices) |*voice| {
                if (!voice.isActive()) {
                    voice.noteOn(note, velocity, brightness);
                    return;
                }
            }
            // Steal quietest
            var quietest: *V = &self.voices[0];
            var min_level: f32 = std.math.floatMax(f32);
            for (&self.voices) |*voice| {
                const lvl = voice.level();
                if (lvl < min_level) {
                    min_level = lvl;
                    quietest = voice;
                }
            }
            quietest.noteOn(note, velocity, brightness);
        }

        fn noteOff(instrument: *Instrument, note: u8) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| {
                if (voice.isActive() and voice.gate and voice.note == note) {
                    voice.noteOff();
                }
            }
        }

        fn allNotesOff(instrument: *Instrument) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| voice.kill();
        }

        fn reset(instrument: *Instrument) void {
            allNotesOff(instrument);
        }
    };
}

// =============================================================================
// Strings
// =============================================================================

const STRINGS_OSCS = 5;
const STRINGS_DETUNE_CENTS = [STRINGS_OSCS]f32{ -14.0, -7.0, 0.0, 7.0, 14.0 };
/// Stereo placement of each saw: flat saws sit left, sharp saws right, the
/// middle one centered. Fixed, so every note spreads the same way.
const STRINGS_OSC_PAN = [STRINGS_OSCS]f32{ -0.8, -0.4, 0.0, 0.4, 0.8 };

const StringsVoice = struct {
    pub const Config = struct {
        attack: f32 = 0.3,
        filter_base_hz: f32 = 800.0,
        filter_range_hz: f32 = 5000.0,
        detune_scale: f32 = 1.0,
    };

    cfg: Config = .{},
    oscs: [STRINGS_OSCS]dsp.BLEPOscillator = undefined,
    amp_env: dsp.ADSREnvelope = .{},
    filter: dsp.SVFilter = .{},
    filter_r: dsp.SVFilter = .{},
    noise: Noise = .{},
    note: u8 = 0,
    gate: bool = false,
    velocity: f32 = 0.0,

    fn init(sample_rate: f32) StringsVoice {
        var v = StringsVoice{
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .filter = dsp.SVFilter.init(sample_rate),
            .filter_r = dsp.SVFilter.init(sample_rate),
        };
        for (&v.oscs) |*o| {
            o.* = dsp.BLEPOscillator.init(sample_rate);
            o.waveform = .saw;
        }
        v.amp_env.decay = 0.3;
        v.amp_env.sustain = 0.85;
        v.amp_env.release = 0.5;
        v.configure(.{});
        return v;
    }

    fn configure(self: *StringsVoice, cfg: Config) void {
        self.cfg = cfg;
        self.amp_env.attack = cfg.attack;
        self.amp_env.updateCoefficients();
    }

    fn noteOn(self: *StringsVoice, note: u8, velocity: u8, brightness: f32) void {
        self.note = note;
        self.gate = true;
        self.velocity = velocityToAmplitude(velocity);
        const freq = dsp.midiNoteToFreq(note);
        for (&self.oscs, 0..) |*o, i| {
            o.setFrequency(freq * centsRatio(STRINGS_DETUNE_CENTS[i] * self.cfg.detune_scale));
            o.reset();
            // Spread start phases so the saws do not stack into a spike
            o.osc.phase = @as(f32, @floatFromInt(i)) / @as(f32, STRINGS_OSCS);
        }
        const cutoff = self.cfg.filter_base_hz + brightness * self.cfg.filter_range_hz;
        self.filter.setFrequency(cutoff);
        self.filter_r.setFrequency(cutoff);
        self.amp_env.noteOn();
    }

    fn noteOff(self: *StringsVoice) void {
        self.gate = false;
        self.amp_env.noteOff();
    }

    fn kill(self: *StringsVoice) void {
        self.gate = false;
        self.amp_env.kill();
    }

    fn tick(self: *StringsVoice, brightness: f32) f32 {
        _ = brightness;
        if (!self.amp_env.isActive()) return 0.0;
        var mix: f32 = 0.0;
        for (&self.oscs) |*o| mix += o.tick();
        mix *= 1.0 / @as(f32, STRINGS_OSCS);
        const filtered = self.filter.tickLP(mix);
        return filtered * self.amp_env.tick() * self.velocity;
    }

    /// Left and right through their own filters: the detuned saws are spread
    /// across the field, so the ensemble is wide without any added delay.
    pub fn tickStereo(self: *StringsVoice, brightness: f32) [2]f32 {
        _ = brightness;
        if (!self.amp_env.isActive()) return .{ 0.0, 0.0 };
        var left: f32 = 0.0;
        var right: f32 = 0.0;
        for (&self.oscs, STRINGS_OSC_PAN) |*o, pan| {
            const x = o.tick();
            left += x * (1.0 - pan);
            right += x * (1.0 + pan);
        }
        const scale = 0.5 / @as(f32, STRINGS_OSCS);
        const gain = self.amp_env.tick() * self.velocity;
        return .{
            self.filter.tickLP(left * scale) * gain,
            self.filter_r.tickLP(right * scale) * gain,
        };
    }

    fn isActive(self: *const StringsVoice) bool {
        return self.amp_env.isActive();
    }

    fn level(self: *const StringsVoice) f32 {
        return self.amp_env.output;
    }
};

/// Strings: detuned saw ensemble, slow attack, lowpass.
pub const Strings = Patch(StringsVoice, "Strings", 0.4);

/// Warm strings: same type as `Strings`, slower attack, lower cutoff, more detune.
pub fn initStringsWarm(sample_rate: f32) Strings {
    var s = Strings.init(sample_rate);
    s.configure("StringsWarm", .{
        .attack = 0.6,
        .filter_base_hz = 400.0,
        .filter_range_hz = 2500.0,
        .detune_scale = 1.8,
    });
    return s;
}

/// Bright strings: same type as `Strings`, faster attack, higher cutoff.
pub fn initStringsBright(sample_rate: f32) Strings {
    var s = Strings.init(sample_rate);
    s.configure("StringsBright", .{
        .attack = 0.1,
        .filter_base_hz = 1500.0,
        .filter_range_hz = 8000.0,
    });
    return s;
}

// =============================================================================
// Brass
// =============================================================================

const BrassVoice = struct {
    pub const Config = struct {
        amp_attack: f32 = 0.12,
        filter_attack: f32 = 0.18,
        filter_base_hz: f32 = 1500.0,
        filter_range_hz: f32 = 6000.0,
    };

    cfg: Config = .{},
    osc1: dsp.BLEPOscillator = .{},
    osc2: dsp.BLEPOscillator = .{},
    amp_env: dsp.ADSREnvelope = .{},
    filter_env: dsp.ADSREnvelope = .{},
    filter: dsp.SVFilter = .{},
    noise: Noise = .{},
    note: u8 = 0,
    gate: bool = false,
    velocity: f32 = 0.0,
    brightness: f32 = 0.5,

    fn init(sample_rate: f32) BrassVoice {
        var v = BrassVoice{
            .osc1 = dsp.BLEPOscillator.init(sample_rate),
            .osc2 = dsp.BLEPOscillator.init(sample_rate),
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .filter_env = dsp.ADSREnvelope.init(sample_rate),
            .filter = dsp.SVFilter.init(sample_rate),
        };
        v.osc1.waveform = .saw;
        v.osc2.waveform = .saw;
        // Amplitude swell: quick but not instant rise, then settle
        v.amp_env.decay = 0.2;
        v.amp_env.sustain = 0.8;
        v.amp_env.release = 0.25;
        // Filter opens with the swell, then closes a little
        v.filter_env.decay = 0.4;
        v.filter_env.sustain = 0.5;
        v.filter_env.release = 0.25;
        v.filter.setQ(1.2);
        v.configure(.{});
        return v;
    }

    fn configure(self: *BrassVoice, cfg: Config) void {
        self.cfg = cfg;
        self.amp_env.attack = cfg.amp_attack;
        self.amp_env.updateCoefficients();
        self.filter_env.attack = cfg.filter_attack;
        self.filter_env.updateCoefficients();
    }

    fn noteOn(self: *BrassVoice, note: u8, velocity: u8, brightness: f32) void {
        self.note = note;
        self.gate = true;
        self.velocity = velocityToAmplitude(velocity);
        self.brightness = brightness;
        const freq = dsp.midiNoteToFreq(note);
        self.osc1.setFrequency(freq * centsRatio(-4.0));
        self.osc2.setFrequency(freq * centsRatio(4.0));
        self.osc1.reset();
        self.osc2.reset();
        self.amp_env.noteOn();
        self.filter_env.noteOn();
    }

    fn noteOff(self: *BrassVoice) void {
        self.gate = false;
        self.amp_env.noteOff();
        self.filter_env.noteOff();
    }

    fn kill(self: *BrassVoice) void {
        self.gate = false;
        self.amp_env.kill();
        self.filter_env.kill();
    }

    fn tick(self: *BrassVoice, brightness: f32) f32 {
        if (!self.amp_env.isActive()) return 0.0;
        _ = brightness;
        const mix = (self.osc1.tick() + self.osc2.tick()) * 0.5;
        const fe = self.filter_env.tick();
        // Sample-rate-rate cutoff update is cheap enough for 16 voices at brass rates
        self.filter.setFrequency(250.0 + fe * (self.cfg.filter_base_hz + self.brightness * self.cfg.filter_range_hz) * (0.5 + 0.5 * self.velocity));
        const filtered = self.filter.tickLP(mix);
        const amp = self.amp_env.tick();
        return filtered * amp * self.velocity;
    }

    fn isActive(self: *const BrassVoice) bool {
        return self.amp_env.isActive();
    }

    fn level(self: *const BrassVoice) f32 {
        return self.amp_env.output;
    }
};

/// Brass: saw pair with filter envelope and amplitude swell.
pub const Brass = Patch(BrassVoice, "Brass", 0.5);

/// Trumpet: same type as `Brass`, brighter filter envelope, quicker swell.
pub fn initBrassTrumpet(sample_rate: f32) Brass {
    var b = Brass.init(sample_rate);
    b.configure("BrassTrumpet", .{
        .amp_attack = 0.06,
        .filter_attack = 0.08,
        .filter_base_hz = 2500.0,
        .filter_range_hz = 8000.0,
    });
    return b;
}

/// Horn: same type as `Brass`, darker, slower swell.
pub fn initBrassHorn(sample_rate: f32) Brass {
    var b = Brass.init(sample_rate);
    b.configure("BrassHorn", .{
        .amp_attack = 0.25,
        .filter_attack = 0.35,
        .filter_base_hz = 800.0,
        .filter_range_hz = 3000.0,
    });
    return b;
}

// =============================================================================
// Woodwind
// =============================================================================

const WoodwindVoice = struct {
    osc: dsp.BLEPOscillator = .{},
    osc2: dsp.BLEPOscillator = .{},
    amp_env: dsp.ADSREnvelope = .{},
    breath_filter: dsp.SVFilter = .{},
    noise: Noise = .{},
    note: u8 = 0,
    gate: bool = false,
    velocity: f32 = 0.0,

    fn init(sample_rate: f32) WoodwindVoice {
        var v = WoodwindVoice{
            .osc = dsp.BLEPOscillator.init(sample_rate),
            .osc2 = dsp.BLEPOscillator.init(sample_rate),
            .amp_env = dsp.ADSREnvelope.init(sample_rate),
            .breath_filter = dsp.SVFilter.init(sample_rate),
        };
        v.osc.waveform = .sine;
        v.osc2.waveform = .sine;
        v.amp_env.attack = 0.06;
        v.amp_env.decay = 0.1;
        v.amp_env.sustain = 0.9;
        v.amp_env.release = 0.25;
        v.amp_env.updateCoefficients();
        v.breath_filter.setFrequency(3000.0);
        return v;
    }

    fn noteOn(self: *WoodwindVoice, note: u8, velocity: u8, brightness: f32) void {
        self.note = note;
        self.gate = true;
        self.velocity = velocityToAmplitude(velocity);
        const freq = dsp.midiNoteToFreq(note);
        self.osc.setFrequency(freq);
        self.osc2.setFrequency(freq * 2.0); // a touch of 2nd harmonic
        self.osc.reset();
        self.osc2.reset();
        self.breath_filter.setFrequency(1500.0 + brightness * 5000.0);
        self.amp_env.noteOn();
    }

    fn noteOff(self: *WoodwindVoice) void {
        self.gate = false;
        self.amp_env.noteOff();
    }

    fn kill(self: *WoodwindVoice) void {
        self.gate = false;
        self.amp_env.kill();
    }

    fn tick(self: *WoodwindVoice, brightness: f32) f32 {
        _ = brightness;
        if (!self.amp_env.isActive()) return 0.0;
        const tone = self.osc.tick() * 0.85 + self.osc2.tick() * 0.15;
        const breath = self.breath_filter.tickLP(self.noise.next()) * 0.06;
        return (tone + breath) * self.amp_env.tick() * self.velocity;
    }

    fn isActive(self: *const WoodwindVoice) bool {
        return self.amp_env.isActive();
    }

    fn level(self: *const WoodwindVoice) f32 {
        return self.amp_env.output;
    }
};

/// Woodwind: sine with a little breath noise.
pub const Woodwind = Patch(WoodwindVoice, "Woodwind", 0.4);

// =============================================================================
// Harp (Karplus-Strong)
// =============================================================================

/// Delay line capacity. Notes below sample_rate / (HARP_BUF - 2) are clamped.
const HARP_BUF = 4096;

/// Widest harp placement either side of center.
pub const HARP_PAN_WIDTH: f32 = 0.6;
/// Notes per full left-right-left cycle (two octaves), so a rising run drifts
/// slowly across the field.
const HARP_PAN_PERIOD: f32 = 24.0;

/// Pan for a harp note from its position in pitch: a slow sine sweep. Pure
/// function of the note number, so it is deterministic.
pub fn harpPan(note: u8) f32 {
    const phase = @as(f32, @floatFromInt(note)) / HARP_PAN_PERIOD;
    return HARP_PAN_WIDTH * @sin(phase * 2.0 * std.math.pi);
}

const HarpVoice = struct {
    buf: [HARP_BUF]f32 = @splat(0.0),
    write: usize = 0,
    period: usize = 2, // integer delay length
    ap_coeff: f32 = 0.0, // fractional-delay allpass coefficient
    ap_x1: f32 = 0.0,
    ap_y1: f32 = 0.0,
    damping: f32 = 0.996, // per-pass loss
    amp_env: dsp.ADSREnvelope = .{},
    peak: f32 = 0.0,
    age: u32 = 0,
    sample_rate: f32 = 48000.0,
    noise: Noise = .{},
    note: u8 = 0,
    gate: bool = false,
    velocity: f32 = 0.0,
    active: bool = false,
    pan: f32 = 0.0,

    fn init(sample_rate: f32) HarpVoice {
        var v = HarpVoice{ .sample_rate = sample_rate };
        v.amp_env = dsp.ADSREnvelope.init(sample_rate);
        v.amp_env.attack = 0.001;
        v.amp_env.decay = 0.1;
        v.amp_env.sustain = 1.0;
        v.amp_env.release = 0.3;
        v.amp_env.updateCoefficients();
        return v;
    }

    fn noteOn(self: *HarpVoice, note: u8, velocity: u8, brightness: f32) void {
        self.note = note;
        self.gate = true;
        self.velocity = velocityToAmplitude(velocity);
        self.active = true;
        self.pan = harpPan(note);
        self.age = 0;
        self.peak = 1.0;

        const freq = dsp.midiNoteToFreq(note);
        // Averaging filter adds half a sample of delay; allpass handles the fraction.
        const max_delay: f32 = @floatFromInt(HARP_BUF - 2);
        const wanted = self.sample_rate / freq - 0.5;
        const delay = std.math.clamp(wanted, 2.0, max_delay);
        const whole = @floor(delay);
        const frac = delay - whole;
        self.period = @intFromFloat(whole);
        self.ap_coeff = (1.0 - frac) / (1.0 + frac);
        self.ap_x1 = 0.0;
        self.ap_y1 = 0.0;

        // Higher notes ring shorter, brighter setting rings longer
        self.damping = std.math.clamp(0.990 + brightness * 0.008, 0.98, 0.9985);

        // Pluck excitation: noise burst, one-pole smoothed (smoother = softer pluck)
        const smooth = 0.55 - 0.4 * self.velocity;
        var lp: f32 = 0.0;
        for (0..self.period + 1) |i| {
            const n = self.noise.next();
            lp += (n - lp) * (1.0 - smooth);
            self.buf[i] = lp * 1.4;
        }
        self.write = 0;

        self.amp_env.kill();
        self.amp_env.noteOn();
    }

    fn noteOff(self: *HarpVoice) void {
        self.gate = false;
        self.damping *= 0.97; // damp the string with a finger
        self.amp_env.noteOff();
    }

    fn kill(self: *HarpVoice) void {
        self.gate = false;
        self.active = false;
        self.amp_env.kill();
        self.peak = 0.0;
        @memset(&self.buf, 0.0);
    }

    fn tick(self: *HarpVoice, brightness: f32) f32 {
        _ = brightness;
        if (!self.active) return 0.0;

        const len = self.period + 1; // ring of period+1 samples
        const w = self.write;
        const r1 = w; // oldest sample
        const r2 = if (w + 1 >= len) 0 else w + 1;

        // Two-point average (lowpass) with loss
        const averaged = 0.5 * (self.buf[r1] + self.buf[r2]) * self.damping;
        // First-order allpass for fractional tuning
        const ap = self.ap_coeff * (averaged - self.ap_y1) + self.ap_x1;
        self.ap_x1 = averaged;
        self.ap_y1 = ap;

        const out = self.buf[r1];
        self.buf[w] = if (std.math.isFinite(ap)) ap else 0.0;
        self.write = r2;

        const amp = self.amp_env.tick();

        self.age += 1;
        self.peak = @max(@abs(out), self.peak * 0.9995);
        if (!self.amp_env.isActive() or (self.age > 2048 and self.peak < 0.0001)) {
            self.active = false;
            self.amp_env.kill();
        }

        return out * amp * self.velocity;
    }

    /// Mono string sound placed by the note's pitch position.
    pub fn tickStereo(self: *HarpVoice, brightness: f32) [2]f32 {
        const x = self.tick(brightness);
        return .{ x * (1.0 - self.pan), x * (1.0 + self.pan) };
    }

    fn isActive(self: *const HarpVoice) bool {
        return self.active;
    }

    fn level(self: *const HarpVoice) f32 {
        return self.peak * self.amp_env.output;
    }
};

/// Harp: Karplus-Strong plucked string.
pub const Harp = Patch(HarpVoice, "Harp", 0.6);

// =============================================================================
// Tests
// =============================================================================

const SR: u32 = 48000;

/// Render `frames` stereo frames, returning the peak; fails on non-finite samples.
fn renderPeak(instrument: *Instrument, frames: usize, scratch: []f32) !f32 {
    var peak: f32 = 0.0;
    var done: usize = 0;
    while (done < frames) {
        const n = @min(scratch.len / 2, frames - done);
        const block = scratch[0 .. n * 2];
        @memset(block, 0.0);
        instrument.process(block, SR);
        for (block) |s| {
            if (!std.math.isFinite(s)) return error.NonFiniteSample;
            peak = @max(peak, @abs(s));
        }
        done += n;
    }
    return peak;
}

fn expectPatchBehaves(comptime P: type, comptime expected_name: []const u8) !void {
    const testing = std.testing;
    const allocator = testing.allocator;

    const patch = try P.create(allocator, @floatFromInt(SR));
    defer patch.instrument.destroy(allocator);
    const instrument = &patch.instrument;

    var scratch: [512]f32 = undefined;

    try testing.expectEqualStrings(expected_name, instrument.name);
    try testing.expectEqual(@as(usize, 2), instrument.getParameterCount());

    // Non-silent and finite on a held note
    instrument.noteOn(60, 100);
    const held_peak = try renderPeak(instrument, SR, &scratch); // 1 s
    try testing.expect(held_peak > 0.01);
    try testing.expect(held_peak <= 1.0);

    // Release within 3 s: skip 3 s, then the final 0.1 s must be effectively silent
    instrument.noteOff(60);
    _ = try renderPeak(instrument, SR * 3, &scratch);
    const tail_peak = try renderPeak(instrument, SR / 10, &scratch);
    try testing.expect(tail_peak < 0.001);
    for (&patch.voices) |*voice| {
        try testing.expect(!voice.isActive());
    }
}

test "strings: output, finite, release" {
    try expectPatchBehaves(Strings, "Strings");
}

test "brass: output, finite, release" {
    try expectPatchBehaves(Brass, "Brass");
}

test "woodwind: output, finite, release" {
    try expectPatchBehaves(Woodwind, "Woodwind");
}

test "harp: output, finite, release" {
    try expectPatchBehaves(Harp, "Harp");
}

test "orchestra: finite across range, polyphony and extreme velocity" {
    inline for (.{ Strings, Brass, Woodwind, Harp }) |P| {
        const patch = try std.testing.allocator.create(P);
        defer std.testing.allocator.destroy(patch);
        patch.* = P.init(@floatFromInt(SR));
        const instrument = &patch.instrument;
        var scratch: [512]f32 = undefined;

        const notes = [_]u8{ 0, 12, 36, 60, 84, 108, 127 };
        // More notes than voices to exercise stealing
        for (0..20) |i| instrument.noteOn(notes[i % notes.len] +| @as(u8, @intCast(i % 3)), if (i % 2 == 0) 127 else 1);
        _ = try renderPeak(instrument, SR / 2, &scratch);

        instrument.allNotesOff();
        const silent = try renderPeak(instrument, 2048, &scratch);
        try std.testing.expectEqual(@as(f32, 0.0), silent);
    }
}

test "orchestra: parameters clamp" {
    var strings = Strings.init(48000.0);
    strings.instrument.setParameter(1, 5.0);
    try std.testing.expectEqual(@as(f32, 1.0), strings.instrument.getParameter(1).?.value);
    try std.testing.expect(strings.instrument.getParameter(2) == null);
}

test "orchestra variants: audible and different from base" {
    const samples = SR; // 0.5 s of interleaved stereo
    var scratch: [512]f32 = undefined;
    var base_out: [samples]f32 = undefined;
    var var_out: [samples]f32 = undefined;

    const sr: f32 = @floatFromInt(SR);
    var strings_base = Strings.init(sr);
    var brass_base = Brass.init(sr);
    var strings_warm = initStringsWarm(sr);
    var strings_bright = initStringsBright(sr);
    var brass_trumpet = initBrassTrumpet(sr);
    var brass_horn = initBrassHorn(sr);

    const variants = [_]*Instrument{
        &strings_warm.instrument,  &strings_bright.instrument,
        &brass_trumpet.instrument, &brass_horn.instrument,
    };
    const bases = [_]*Instrument{
        &strings_base.instrument, &strings_base.instrument,
        &brass_base.instrument,   &brass_base.instrument,
    };
    const names = [_][]const u8{ "StringsWarm", "StringsBright", "BrassTrumpet", "BrassHorn" };

    for (variants, bases, names) |v, b, name| {
        try std.testing.expectEqualStrings(name, v.name);

        // Audible over 1 s
        v.noteOn(60, 100);
        const peak = try renderPeak(v, SR, &scratch);
        try std.testing.expect(peak > 0.01);
        v.allNotesOff();
        _ = try renderPeak(v, 2048, &scratch);

        // Differs from base over the first 0.5 s
        b.allNotesOff();
        _ = try renderPeak(b, 2048, &scratch);
        b.noteOn(60, 100);
        v.noteOn(60, 100);
        @memset(&base_out, 0.0);
        @memset(&var_out, 0.0);
        var done: usize = 0;
        while (done < samples) {
            const n = @min(512, samples - done);
            b.process(base_out[done..][0..n], SR);
            v.process(var_out[done..][0..n], SR);
            done += n;
        }
        var diff: f32 = 0.0;
        for (base_out, var_out) |x, y| diff += @abs(x - y);
        try std.testing.expect(diff > 1.0);
        b.allNotesOff();
        v.allNotesOff();
    }
}

test "harp pan moves slowly and stays within its width" {
    var prev = harpPan(48);
    var note: u8 = 49;
    while (note < 96) : (note += 1) {
        const pan = harpPan(note);
        try std.testing.expect(@abs(pan) <= HARP_PAN_WIDTH + 1e-6);
        try std.testing.expect(@abs(pan - prev) < 0.3);
        prev = pan;
    }
    try std.testing.expectEqual(harpPan(60), harpPan(60));
}

test "warm strings are wider than mono: left and right differ" {
    var s = initStringsWarm(48000.0);
    s.instrument.noteOn(60, 100);
    var buf: [2 * 4800]f32 = @splat(0.0);
    s.instrument.process(&buf, 48000);
    var diff: f32 = 0.0;
    var energy: f32 = 0.0;
    for (0..buf.len / 2) |i| {
        diff += @abs(buf[i * 2] - buf[i * 2 + 1]);
        energy += @abs(buf[i * 2]) + @abs(buf[i * 2 + 1]);
    }
    try std.testing.expect(energy > 0.0);
    try std.testing.expect(diff > 0.0);
}
