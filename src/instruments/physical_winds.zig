//! Physical-modeling wind instruments
//!
//! - ModelBrass: lip-reed brass. A Cook-style lip reed (resonant lip filter into
//!   a squared, clamped reed table driven by mouth pressure) feeds a bore
//!   waveguide. The loop holds a one-pole lowpass (bore/bell losses), a
//!   fractional allpass for tuning and a DC blocker. Radiation is a first-order
//!   high-pass on the output.
//! - ModelClarinet: single reed. A linear-with-clamp reed table (pressure
//!   difference across the reed) feeds a cylindrical bore delay line closed at
//!   the reed end (inverting reflection), which yields mostly odd harmonics.
//!
//! Real-time safe: all state is fixed-size, no allocation after construction.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = 8;
/// Delay line capacity in samples. Covers A1 (55 Hz) at 96 kHz for the brass
/// loop (T = sr / f), which is the longest loop we build.
const DELAY_SIZE = 2048 * 2;
const DELAY_MASK = DELAY_SIZE - 1;

const PARAM_VOLUME = 0;
const PARAM_BRIGHTNESS = 1;
const PARAM_ATTACK = 2;
const PARAM_EMBOUCHURE = 3;
const PARAM_NOISE = 4;
const PARAM_COUNT = 5;

// -----------------------------------------------------------------------------
// Shared waveguide pieces
// -----------------------------------------------------------------------------

/// Power-of-two ring buffer delay with an integer tap.
const Delay = struct {
    buf: [DELAY_SIZE]f32 = @splat(0.0),
    write: usize = 0,

    fn reset(self: *Delay) void {
        @memset(&self.buf, 0.0);
        self.write = 0;
    }

    /// Sample written `n` ticks ago (n >= 1 reads the oldest-written values).
    fn read(self: *const Delay, n: usize) f32 {
        return self.buf[(self.write +% DELAY_SIZE -% n) & DELAY_MASK];
    }

    /// Linearly interpolated read at a fractional tick count `n` (n >= 1).
    fn readFrac(self: *const Delay, n: f32) f32 {
        const whole: usize = @intFromFloat(n);
        const frac = n - @as(f32, @floatFromInt(whole));
        return self.read(whole) * (1.0 - frac) + self.read(whole + 1) * frac;
    }

    fn push(self: *Delay, x: f32) void {
        self.buf[self.write] = x;
        self.write = (self.write + 1) & DELAY_MASK;
    }
};

/// One-pole lowpass: y = (1 - a) x + a y1.
const LossFilter = struct {
    a: f32 = 0.3,
    y1: f32 = 0.0,

    fn setCutoff(self: *LossFilter, cutoff_hz: f32, sample_rate: f32) void {
        const c = std.math.clamp(cutoff_hz, 20.0, sample_rate * 0.45);
        self.a = std.math.exp(-2.0 * std.math.pi * c / sample_rate);
    }

    fn tick(self: *LossFilter, x: f32) f32 {
        self.y1 = (1.0 - self.a) * x + self.a * self.y1;
        return self.y1;
    }

    /// Phase delay in samples at normalized radian frequency w.
    fn phaseDelay(self: *const LossFilter, w: f32) f32 {
        const phase = std.math.atan2(self.a * @sin(w), 1.0 - self.a * @cos(w));
        return phase / w;
    }
};

/// First-order allpass for fractional delay.
const FracAllpass = struct {
    eta: f32 = 0.0,
    x1: f32 = 0.0,
    y1: f32 = 0.0,

    fn setDelay(self: *FracAllpass, d: f32) void {
        self.eta = (1.0 - d) / (1.0 + d);
    }

    fn tick(self: *FracAllpass, x: f32) f32 {
        const y = self.eta * x + self.x1 - self.eta * self.y1;
        self.x1 = x;
        self.y1 = y;
        return y;
    }
};

/// DC blocker / first-order high-pass: y = x - x1 + r y1.
const HighPass = struct {
    r: f32 = 0.995,
    x1: f32 = 0.0,
    y1: f32 = 0.0,

    fn setCutoff(self: *HighPass, cutoff_hz: f32, sample_rate: f32) void {
        self.r = std.math.exp(-2.0 * std.math.pi * cutoff_hz / sample_rate);
    }

    fn tick(self: *HighPass, x: f32) f32 {
        const y = x - self.x1 + self.r * self.y1;
        self.x1 = x;
        self.y1 = y;
        return y;
    }
};

/// Lip as a mass-spring resonator: two-pole lowpass with unity DC gain, so
/// the mouth pressure sets a steady lip opening while the resonance shapes the
/// response to bore pressure.
const LipFilter = struct {
    g: f32 = 1.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    fn setResonance(self: *LipFilter, freq: f32, q: f32, sample_rate: f32) void {
        const w = 2.0 * std.math.pi * freq / sample_rate;
        const r = std.math.exp(-w / (2.0 * q));
        self.a1 = -2.0 * r * @cos(w);
        self.a2 = r * r;
        self.g = 1.0 + self.a1 + self.a2;
    }

    fn tick(self: *LipFilter, x: f32) f32 {
        const y = self.g * x - self.a1 * self.y1 - self.a2 * self.y2;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

/// Linear attack / release gate for breath pressure.
const BreathEnvelope = struct {
    level: f32 = 0.0,
    target: f32 = 0.0,
    rate_up: f32 = 0.001,
    rate_down: f32 = 0.001,

    fn tick(self: *BreathEnvelope) f32 {
        if (self.level < self.target) {
            self.level = @min(self.level + self.rate_up, self.target);
        } else if (self.level > self.target) {
            self.level = @max(self.level - self.rate_down, self.target);
        }
        return self.level;
    }
};

/// Deterministic white noise in [-1, 1) (xorshift32), no allocation.
const Noise = struct {
    state: u32 = 0x9E3779B9,

    fn tick(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        const unit: f32 = @floatFromInt(x >> 8);
        return unit / 8388608.0 - 1.0;
    }
};

fn velocityToPressure(velocity: u8) f32 {
    return @as(f32, @floatFromInt(velocity)) / 127.0;
}

fn finiteOrZero(x: f32) f32 {
    return if (std.math.isFinite(x)) x else 0.0;
}

// -----------------------------------------------------------------------------
// Brass voice
// -----------------------------------------------------------------------------

const BrassVoice = struct {
    line: Delay = .{},
    loss: LossFilter = .{},
    /// Second bore lowpass: rolls off above roughly the 8th partial at low
    /// velocity and opens up as the player blows harder.
    tone: LossFilter = .{},
    tuning: FracAllpass = .{},
    dc: HighPass = .{},
    radiation: HighPass = .{},
    lip: LipFilter = .{},
    env: BreathEnvelope = .{},
    noise: Noise = .{},

    delay_len: usize = 64,
    last_out: f32 = 0.0,
    amp: f32 = 0.0,
    onset_comp: f32 = 0.0,
    pressure: f32 = 0.0,
    note: u8 = 0,
    active: bool = false,
    releasing: bool = false,
    sample_rate: f32 = 48000.0,

    const default_params = [PARAM_COUNT]Parameter{
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.6, .value = 0.6, .unit = "" },
        .{ .name = "Attack", .min = 0.005, .max = 0.5, .default = 0.06, .value = 0.06, .unit = "s" },
        .{ .name = "Lip Tension", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Breath Noise", .min = 0.0, .max = 1.0, .default = 0.1, .value = 0.1, .unit = "" },
    };

    fn init(sample_rate: f32) BrassVoice {
        var v = BrassVoice{ .sample_rate = sample_rate };
        v.radiation.setCutoff(60.0, sample_rate);
        v.dc.setCutoff(10.0, sample_rate);
        return v;
    }

    fn start(self: *BrassVoice, note: u8, velocity: u8, params: []const Parameter) void {
        const sr = self.sample_rate;
        const freq = dsp.midiNoteToFreq(note);
        const w = 2.0 * std.math.pi * freq / sr;

        self.line.reset();
        self.loss = .{};
        self.tone = .{};
        self.tuning = .{};
        self.dc.x1 = 0.0;
        self.dc.y1 = 0.0;
        self.radiation.x1 = 0.0;
        self.radiation.y1 = 0.0;
        self.lip = .{};
        self.last_out = 0.0;
        self.amp = 0.0;

        // Bore losses: brighter setting lets more harmonics survive each trip.
        const brightness = params[PARAM_BRIGHTNESS].value;
        self.loss.setCutoff(freq * (2.0 + 10.0 * brightness), sr);

        // Total loop delay = one acoustic period. Subtract the filter delays and
        // split the remainder into an integer line and a fractional allpass.
        const lip_tension = params[PARAM_EMBOUCHURE].value;
        // The lip sits below the played pitch so the loop is regenerative at
        // the bore resonance (response is roughly in anti-phase there).
        const lip_freq = freq / (1.25 + 0.2 * (lip_tension - 0.5));
        self.lip.setResonance(lip_freq, 5.0, sr);
        // Tone lowpass: cutoff in partials of the fundamental, 8 at velocity 60.
        const vel_unit = velocityToPressure(velocity);
        self.tone.setCutoff(freq * (TONE_BASE + TONE_SLOPE * vel_unit), sr);
        const total = sr / freq;
        const rest = total - self.loss.phaseDelay(w) - self.tone.phaseDelay(w) - loopTrim(freq, vel_unit);
        const int_part = @max(@floor(rest - 1.0), 1.0);
        const max_len: f32 = @floatFromInt(DELAY_SIZE - 2);
        self.delay_len = @intFromFloat(@min(int_part, max_len));
        self.tuning.setDelay(rest - @as(f32, @floatFromInt(self.delay_len)));

        self.onset_comp = ONSET_SHIFT_CENTS / 1731.234 * total;
        self.pressure = 0.3 + 0.6 * velocityToPressure(velocity);
        const attack_samples = @max(params[PARAM_ATTACK].value * sr, 1.0);
        self.env = .{
            .level = 0.0,
            .target = self.pressure,
            .rate_up = self.pressure / attack_samples,
            .rate_down = self.pressure / (0.08 * sr),
        };
        self.note = note;
        self.active = true;
        self.releasing = false;
    }

    fn release(self: *BrassVoice) void {
        self.env.target = 0.0;
        self.releasing = true;
    }

    fn tick(self: *BrassVoice, params: []const Parameter) f32 {
        if (!self.active) return 0.0;

        const breath = self.env.tick();
        const hiss = self.noise.tick() * params[PARAM_NOISE].value * 0.05 * breath;
        const mouth = breath + hiss;
        const bore = 0.9 * self.last_out;

        // Lip reed: pressure difference through the resonant lip, then squared
        // and clamped so the opening grows with drive.
        // The table is a soft saturation (s / (1 + s)) with a reduced slope,
        // not a hard clamp, so the reed does not slam shut and spray harmonics.
        const lip_out = self.lip.tick(mouth - bore);
        const s = REED_SLOPE * lip_out * lip_out;
        const delta = s / (1.0 + s);
        const reed_out = delta * mouth + (1.0 - delta) * bore;

        // While the oscillation is still small the reed loop runs sharp. Add a
        // little extra delay that fades out as the note reaches full level so
        // the pitch does not glide into place during the attack.
        const level = std.math.clamp(self.amp / @max(self.pressure, 0.05), 0.0, 1.0);
        const settle = std.math.clamp((level - SETTLE_LO) / (SETTLE_HI - SETTLE_LO), 0.0, 1.0);
        const extra = self.onset_comp * (1.0 - settle * settle * (3.0 - 2.0 * settle));
        const returned = self.line.readFrac(@as(f32, @floatFromInt(self.delay_len)) + extra);
        const filtered = self.tuning.tick(self.tone.tick(self.loss.tick(returned)));
        self.line.push(finiteOrZero(reed_out));
        self.last_out = finiteOrZero(self.dc.tick(filtered));
        self.amp += 0.004 * (@abs(self.last_out) - self.amp);

        if (self.releasing and self.env.level <= 0.0001) {
            self.active = false;
        }

        // Radiation: first-order high-pass of the bore pressure.
        return self.radiation.tick(self.last_out) * 3.0;
    }

    /// Tone lowpass cutoff = f0 * (TONE_BASE + TONE_SLOPE * velocity/127).
    const TONE_BASE: f32 = 4.0;
    const TONE_SLOPE: f32 = 9.0;
    /// Small-signal pitch excess (cents) removed during the attack.
    const ONSET_SHIFT_CENTS: f32 = 33.0;
    /// Oscillation level (fraction of breath pressure) over which it fades.
    const SETTLE_LO: f32 = 0.3;
    const SETTLE_HI: f32 = 0.5;
    /// Reed table slope (smaller is softer).
    const REED_SLOPE: f32 = 1.0;

    /// Empirical correction (samples) for the lip filter, DC blocker and reed
    /// nonlinearity phase, as a function of pitch and velocity (0..1).
    fn loopTrim(freq: f32, vel_unit: f32) f32 {
        // The fit covers about 220-880 Hz; hold the correction flat outside it.
        const k = std.math.clamp(freq / 1000.0, 0.2, 0.9);
        return TRIM_C0 + TRIM_F * k + TRIM_F2 * k * k + TRIM_F3 * k * k * k + TRIM_V * vel_unit;
    }
    const TRIM_C0: f32 = -12.9906;
    const TRIM_F: f32 = 53.5874;
    const TRIM_F2: f32 = -78.2356;
    const TRIM_F3: f32 = 39.3417;
    const TRIM_V: f32 = -1.0384;
};

// -----------------------------------------------------------------------------
// Clarinet voice
// -----------------------------------------------------------------------------

const ClarinetVoice = struct {
    line: Delay = .{},
    loss: LossFilter = .{},
    tuning: FracAllpass = .{},
    dc: HighPass = .{},
    radiation: HighPass = .{},
    env: BreathEnvelope = .{},
    noise: Noise = .{},

    delay_len: usize = 64,
    last_out: f32 = 0.0,
    pressure: f32 = 0.0,
    reed_slope: f32 = -0.3,
    note: u8 = 0,
    active: bool = false,
    releasing: bool = false,
    sample_rate: f32 = 48000.0,

    const default_params = [PARAM_COUNT]Parameter{
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Attack", .min = 0.005, .max = 0.5, .default = 0.03, .value = 0.03, .unit = "s" },
        .{ .name = "Reed Stiffness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Breath Noise", .min = 0.0, .max = 1.0, .default = 0.1, .value = 0.1, .unit = "" },
    };

    fn init(sample_rate: f32) ClarinetVoice {
        var v = ClarinetVoice{ .sample_rate = sample_rate };
        v.radiation.setCutoff(40.0, sample_rate);
        v.dc.setCutoff(10.0, sample_rate);
        return v;
    }

    fn start(self: *ClarinetVoice, note: u8, velocity: u8, params: []const Parameter) void {
        const sr = self.sample_rate;
        const freq = dsp.midiNoteToFreq(note);
        const w = 2.0 * std.math.pi * freq / sr;

        self.line.reset();
        self.loss = .{};
        self.tuning = .{};
        self.dc.x1 = 0.0;
        self.dc.y1 = 0.0;
        self.radiation.x1 = 0.0;
        self.radiation.y1 = 0.0;
        self.last_out = 0.0;

        const brightness = params[PARAM_BRIGHTNESS].value;
        self.loss.setCutoff(freq * (3.0 + 12.0 * brightness), sr);

        // The inverting closed-end reflection makes the loop delay a half
        // period: f = sr / (2 * delay).
        const total = sr / (2.0 * freq);
        const rest = total - self.loss.phaseDelay(w) - loop_trim;
        const int_part = @max(@floor(rest - 1.0), 1.0);
        const max_len: f32 = @floatFromInt(DELAY_SIZE - 2);
        self.delay_len = @intFromFloat(@min(int_part, max_len));
        self.tuning.setDelay(rest - @as(f32, @floatFromInt(self.delay_len)));

        self.reed_slope = -0.2 - 0.2 * params[PARAM_EMBOUCHURE].value;
        self.pressure = 0.3 + 0.5 * velocityToPressure(velocity);
        const attack_samples = @max(params[PARAM_ATTACK].value * sr, 1.0);
        self.env = .{
            .level = 0.0,
            .target = self.pressure,
            .rate_up = self.pressure / attack_samples,
            .rate_down = self.pressure / (0.05 * sr),
        };
        self.note = note;
        self.active = true;
        self.releasing = false;
    }

    fn release(self: *ClarinetVoice) void {
        self.env.target = 0.0;
        self.releasing = true;
    }

    fn tick(self: *ClarinetVoice, params: []const Parameter) f32 {
        if (!self.active) return 0.0;

        const breath = self.env.tick();
        const hiss = self.noise.tick() * params[PARAM_NOISE].value * 0.02 * breath;

        // Closed-end (reed side) reflection inverts the returning wave.
        const returned = self.line.read(self.delay_len);
        const filtered = self.tuning.tick(self.loss.tick(returned));
        const bore = -0.95 * filtered;

        // Single-reed table: opening is linear in pressure difference, clamped.
        const diff = bore - (breath + hiss);
        const opening = std.math.clamp(0.7 + self.reed_slope * diff, 0.0, 1.0);
        const into_bore = (breath + hiss) + diff * opening;

        self.line.push(finiteOrZero(into_bore));
        self.last_out = finiteOrZero(self.dc.tick(filtered));

        if (self.releasing and self.env.level <= 0.0001) {
            self.active = false;
        }
        return self.radiation.tick(self.last_out) * 1.5;
    }

    const loop_trim: f32 = 0.0;
};

// -----------------------------------------------------------------------------
// Generic polyphonic instrument wrapper
// -----------------------------------------------------------------------------

fn WindInstrument(comptime Voice: type, comptime display_name: []const u8) type {
    return struct {
        instrument: Instrument,
        voices: [MAX_VOICES]Voice = undefined,
        params: [PARAM_COUNT]Parameter = Voice.default_params,
        sample_rate: f32 = 48000.0,
        steal_next: usize = 0,

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
                .instrument = .{ .vtable = &vtable, .name = display_name },
                .sample_rate = sample_rate,
            };
            for (&self.voices) |*voice| {
                voice.* = Voice.init(sample_rate);
            }
            return self;
        }

        fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            _ = sample_rate;
            const volume = self.params[PARAM_VOLUME].value;
            const frames = buffer.len / 2;
            for (0..frames) |frame| {
                var sum: f32 = 0.0;
                for (&self.voices) |*voice| {
                    sum += voice.tick(&self.params);
                }
                const out = dsp.softClip(sum * volume);
                buffer[frame * 2] += out;
                buffer[frame * 2 + 1] += out;
            }
        }

        fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            if (velocity == 0) {
                noteOff(instrument, note);
                return;
            }
            for (&self.voices) |*voice| {
                if (voice.active and voice.note == note) {
                    voice.start(note, velocity, &self.params);
                    return;
                }
            }
            for (&self.voices) |*voice| {
                if (!voice.active) {
                    voice.start(note, velocity, &self.params);
                    return;
                }
            }
            // All busy: steal round-robin.
            const slot = self.steal_next % MAX_VOICES;
            self.steal_next = (slot + 1) % MAX_VOICES;
            self.voices[slot].start(note, velocity, &self.params);
        }

        fn noteOff(instrument: *Instrument, note: u8) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| {
                if (voice.active and !voice.releasing and voice.note == note) {
                    voice.release();
                }
            }
        }

        fn allNotesOff(instrument: *Instrument) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| {
                voice.active = false;
                voice.releasing = false;
                voice.env = .{};
            }
        }

        fn reset(instrument: *Instrument) void {
            allNotesOff(instrument);
        }
    };
}

/// Lip-reed brass physical model.
pub const ModelBrass = WindInstrument(BrassVoice, "ModelBrass");
/// Single-reed clarinet physical model.
pub const ModelClarinet = WindInstrument(ClarinetVoice, "ModelClarinet");

// =============================================================================
// Tests
// =============================================================================

const test_sr: u32 = 48000;

/// Render `seconds` of mono (left channel) output for one held note.
fn renderNote(allocator: std.mem.Allocator, instrument: *Instrument, note: u8, velocity: u8, seconds: f32) ![]f32 {
    const frames: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(test_sr)));
    const mono = try allocator.alloc(f32, frames);
    errdefer allocator.free(mono);
    var block: [1024]f32 = @splat(0.0);

    instrument.noteOn(note, velocity);
    var done: usize = 0;
    while (done < frames) {
        const n: usize = @min(frames - done, block.len / 2);
        @memset(block[0 .. n * 2], 0.0);
        instrument.process(block[0 .. n * 2], test_sr);
        for (0..n) |i| mono[done + i] = block[i * 2];
        done += n;
    }
    return mono;
}

/// Hann-windowed single-frequency DFT magnitude.
fn magnitudeAt(sig: []const f32, freq: f32) f32 {
    const sr: f64 = @floatFromInt(test_sr);
    const n_f: f64 = @floatFromInt(sig.len);
    const w = 2.0 * std.math.pi * @as(f64, freq) / sr;
    var re: f64 = 0.0;
    var im: f64 = 0.0;
    for (sig, 0..) |x, i| {
        const t: f64 = @floatFromInt(i);
        const hann = 0.5 - 0.5 * @cos(2.0 * std.math.pi * t / n_f);
        const v = @as(f64, x) * hann;
        re += v * @cos(w * t);
        im -= v * @sin(w * t);
    }
    return @floatCast(@sqrt(re * re + im * im));
}

/// Frequency of the strongest spectral peak in [lo, hi] (fine scan).
fn peakFrequency(sig: []const f32, lo: f32, hi: f32, step: f32) struct { freq: f32, mag: f32 } {
    var best_f = lo;
    var best_m: f32 = 0.0;
    var f = lo;
    while (f <= hi) : (f += step) {
        const m = magnitudeAt(sig, f);
        if (m > best_m) {
            best_m = m;
            best_f = f;
        }
    }
    return .{ .freq = best_f, .mag = best_m };
}

fn centsBetween(measured: f32, expected: f32) f32 {
    return 1200.0 * std.math.log2(measured / expected);
}

/// Energy-weighted spectral centroid over the first `count` harmonics of f0.
fn harmonicCentroid(sig: []const f32, f0: f32, count: usize) f32 {
    var num: f64 = 0.0;
    var den: f64 = 0.0;
    for (1..count + 1) |k| {
        const kf: f32 = @floatFromInt(k);
        const p = peakFrequency(sig, kf * f0 * 0.99, kf * f0 * 1.01, @max(kf * f0 * 0.001, 0.25));
        const e: f64 = @as(f64, p.mag) * @as(f64, p.mag);
        num += e * @as(f64, p.freq);
        den += e;
    }
    if (den <= 0.0) return 0.0;
    return @floatCast(num / den);
}

fn peakAbs(sig: []const f32) f32 {
    var m: f32 = 0.0;
    for (sig) |x| m = @max(m, @abs(x));
    return m;
}

fn allFinite(sig: []const f32) bool {
    for (sig) |x| if (!std.math.isFinite(x)) return false;
    return true;
}

test "ModelBrass init and parameters" {
    var brass = ModelBrass.init(48000.0);
    try std.testing.expectEqualStrings("ModelBrass", brass.instrument.name);
    try std.testing.expectEqual(@as(usize, PARAM_COUNT), brass.instrument.getParameterCount());
    brass.instrument.setParameter(0, 5.0);
    try std.testing.expectEqual(@as(f32, 1.0), brass.instrument.getParameter(0).?.value);
}

test "ModelClarinet init and parameters" {
    var clar = ModelClarinet.init(48000.0);
    try std.testing.expectEqualStrings("ModelClarinet", clar.instrument.name);
    try std.testing.expectEqual(@as(usize, PARAM_COUNT), clar.instrument.getParameterCount());
}

test "ModelBrass A3 pitch within 5 cents" {
    const a = std.testing.allocator;
    var brass = ModelBrass.init(48000.0);
    const sig = try renderNote(a, &brass.instrument, 57, 100, 1.5);
    defer a.free(sig);

    const analysis = sig[24000 .. 24000 + 32768];
    const peak = peakFrequency(analysis, 200.0, 240.0, 0.05);
    const cents = centsBetween(peak.freq, 220.0);
    std.debug.print("brass A3 peak {d:.2} Hz ({d:.2} cents)\n", .{ peak.freq, cents });
    try std.testing.expect(@abs(cents) <= 5.0);
}

test "ModelClarinet A3 pitch within 5 cents" {
    const a = std.testing.allocator;
    var clar = ModelClarinet.init(48000.0);
    const sig = try renderNote(a, &clar.instrument, 57, 100, 1.5);
    defer a.free(sig);

    const analysis = sig[24000 .. 24000 + 32768];
    const peak = peakFrequency(analysis, 200.0, 240.0, 0.05);
    const cents = centsBetween(peak.freq, 220.0);
    std.debug.print("clarinet A3 peak {d:.2} Hz ({d:.2} cents)\n", .{ peak.freq, cents });
    try std.testing.expect(@abs(cents) <= 5.0);
}

test "ModelBrass centroid rises with velocity" {
    const a = std.testing.allocator;
    var soft = ModelBrass.init(48000.0);
    var loud = ModelBrass.init(48000.0);
    const s = try renderNote(a, &soft.instrument, 57, 50, 1.5);
    defer a.free(s);
    const l = try renderNote(a, &loud.instrument, 57, 127, 1.5);
    defer a.free(l);

    const soft_win = s[24000 .. 24000 + 16384];
    const loud_win = l[24000 .. 24000 + 16384];
    const soft_f0 = peakFrequency(soft_win, 200.0, 240.0, 0.1).freq;
    const loud_f0 = peakFrequency(loud_win, 200.0, 240.0, 0.1).freq;
    const soft_c = harmonicCentroid(soft_win, soft_f0, 20);
    const loud_c = harmonicCentroid(loud_win, loud_f0, 20);
    std.debug.print("brass centroid soft {d:.1} Hz, loud {d:.1} Hz\n", .{ soft_c, loud_c });
    try std.testing.expect(peakAbs(soft_win) > 0.01);
    try std.testing.expect(peakAbs(loud_win) > 0.01);
    try std.testing.expect(loud_c > soft_c * 1.05);
}

test "ModelClarinet odd harmonics dominate even" {
    const a = std.testing.allocator;
    var clar = ModelClarinet.init(48000.0);
    const sig = try renderNote(a, &clar.instrument, 57, 100, 1.5);
    defer a.free(sig);

    const win = sig[24000 .. 24000 + 16384];
    var odd: f64 = 0.0;
    var even: f64 = 0.0;
    for (1..7) |k| {
        const kf: f32 = @floatFromInt(k);
        const p = peakFrequency(win, kf * 220.0 * 0.99, kf * 220.0 * 1.01, 0.25);
        const e: f64 = @as(f64, p.mag) * @as(f64, p.mag);
        if (k % 2 == 1) odd += e else even += e;
    }
    std.debug.print("clarinet odd energy {e:.3}, even energy {e:.3}\n", .{ odd, even });
    try std.testing.expect(odd > 0.0);
    try std.testing.expect(odd > even * 4.0);
}

test "outputs stay finite and below 1.5 peak" {
    const a = std.testing.allocator;
    const velocities = [_]u8{ 1, 64, 127 };
    const notes = [_]u8{ 36, 57, 84 };

    for (velocities) |vel| {
        for (notes) |note| {
            var brass = ModelBrass.init(48000.0);
            const b = try renderNote(a, &brass.instrument, note, vel, 0.5);
            defer a.free(b);
            try std.testing.expect(allFinite(b));
            try std.testing.expect(peakAbs(b) < 1.5);

            var clar = ModelClarinet.init(48000.0);
            const c = try renderNote(a, &clar.instrument, note, vel, 0.5);
            defer a.free(c);
            try std.testing.expect(allFinite(c));
            try std.testing.expect(peakAbs(c) < 1.5);
        }
    }
}

test "note off releases voice to silence" {
    const a = std.testing.allocator;
    var brass = ModelBrass.init(48000.0);
    const sig = try renderNote(a, &brass.instrument, 57, 100, 0.3);
    a.free(sig);
    brass.instrument.noteOff(57);
    var block: [1024]f32 = @splat(0.0);
    for (0..40) |_| {
        @memset(&block, 0.0);
        brass.instrument.process(&block, test_sr);
    }
    for (&brass.voices) |*v| try std.testing.expect(!v.active);
}

/// Pitches used by the arrangement's lead line (src/cli/song.zig).
const lead_notes = [_]u8{ 70, 72, 74, 75, 77, 79, 80 };

fn midiHz(note: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

test "ModelBrass lead notes within 5 cents at two velocities" {
    const a = std.testing.allocator;
    for ([_]u8{ 60, 110 }) |vel| {
        for (lead_notes) |note| {
            var brass = ModelBrass.init(48000.0);
            const sig = try renderNote(a, &brass.instrument, note, vel, 1.5);
            defer a.free(sig);
            const f = midiHz(note);
            // Two sustain windows: early and late in the held note.
            const starts = [_]usize{ 14400, 30000 };
            for (starts) |start| {
                const peak = peakFrequency(sig[start .. start + 16384], f * 0.97, f * 1.03, f * 0.0005);
                const cents = centsBetween(peak.freq, f);
                std.debug.print("brass note {d} vel {d} @{d}: {d:.2} cents\n", .{ note, vel, start, cents });
                try std.testing.expect(@abs(cents) <= 5.0);
            }
        }
    }
}

test "ModelBrass pitch is stable at onset" {
    const a = std.testing.allocator;
    for ([_]u8{ 60, 110 }) |vel| {
        for (lead_notes) |note| {
            var brass = ModelBrass.init(48000.0);
            const sig = try renderNote(a, &brass.instrument, note, vel, 1.5);
            defer a.free(sig);
            const f = midiHz(note);
            const sus = peakFrequency(sig[30000 .. 30000 + 16384], f * 0.97, f * 1.03, f * 0.0005);
            // Window starts 50 ms after note-on, covering the attack ramp.
            const onset = peakFrequency(sig[2400 .. 2400 + 8192], f * 0.97, f * 1.03, f * 0.0005);
            const glide = centsBetween(onset.freq, sus.freq);
            std.debug.print("brass note {d} vel {d} onset glide {d:.2} cents\n", .{ note, vel, glide });
            try std.testing.expect(@abs(glide) <= 10.0);
        }
    }
}

test "ModelBrass centroid is lower at velocity 60 than 110" {
    const a = std.testing.allocator;
    for (lead_notes) |note| {
        var soft = ModelBrass.init(48000.0);
        var loud = ModelBrass.init(48000.0);
        const s = try renderNote(a, &soft.instrument, note, 60, 1.0);
        defer a.free(s);
        const l = try renderNote(a, &loud.instrument, note, 110, 1.0);
        defer a.free(l);
        const f = midiHz(note);
        const soft_c = harmonicCentroid(s[24000 .. 24000 + 16384], f, 12);
        const loud_c = harmonicCentroid(l[24000 .. 24000 + 16384], f, 12);
        std.debug.print("brass note {d} centroid v60 {d:.1} Hz, v110 {d:.1} Hz\n", .{ note, soft_c, loud_c });
        try std.testing.expect(soft_c < loud_c);
    }
}
