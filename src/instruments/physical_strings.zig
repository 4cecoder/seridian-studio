//! Physical string models - bowed and plucked
//!
//! Two instruments built on one digital waveguide string:
//! - ModelStrings: bowed string. Two delay lines (nut side and bridge side of
//!   the bow), a one-pole loss filter and an inverting bridge reflection. The
//!   bow is a friction junction in the Smith/Serafin style: the bow velocity
//!   minus the string velocity goes through a friction curve. Bow speed and
//!   pressure come from note velocity, with a slow vibrato.
//! - ModelPluck: the same waveguide excited by a short lowpassed noise burst
//!   (Karplus-Strong style) with a brightness control.
//!
//! Up to 6 voices. Real-time safe: fixed buffers, no allocation, no I/O.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

/// Polyphony of both instruments.
pub const MAX_STRING_VOICES = 6;

/// Delay line length (power of two). Lowest playable pitch at 48 kHz is about 12 Hz.
const LINE_LEN = 4096;
const LINE_MASK = LINE_LEN - 1;

/// Where the bow sits along the string, as a fraction of its length from the bridge.
const BOW_POSITION = 0.127;

const Mode = enum { bowed, plucked };

/// Cheap xorshift32 noise source. Returns values in [-1, 1).
const Noise = struct {
    state: u32 = 0x9E37_79B9,

    fn next(self: *Noise) f32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        const top: u32 = x >> 8;
        return @as(f32, @floatFromInt(top)) / 8388608.0 - 1.0;
    }
};

/// Circular delay line with linearly interpolated fractional reads.
const Line = struct {
    buf: [LINE_LEN]f32 = @splat(0.0),
    w: usize = 0,

    fn clear(self: *Line) void {
        @memset(&self.buf, 0.0);
        self.w = 0;
    }

    fn write(self: *Line, x: f32) void {
        self.buf[self.w] = x;
        self.w = (self.w + 1) & LINE_MASK;
    }

    /// Sample written `d` writes ago (d >= 1; d == 1 is the newest sample).
    fn read(self: *const Line, d: f32) f32 {
        const whole: usize = @intFromFloat(d);
        const frac = d - @as(f32, @floatFromInt(whole));
        const a = self.buf[(self.w -% whole) & LINE_MASK];
        const b = self.buf[(self.w -% whole -% 1) & LINE_MASK];
        return a + (b - a) * frac;
    }
};

/// Phase delay in samples of H(z) = (1 - p) / (1 - p z^-1) at angular frequency w.
fn lowpassPhaseDelay(p: f32, w: f32) f32 {
    if (w <= 0.0) return p / (1.0 - p);
    return std.math.atan2(p * @sin(w), 1.0 - p * @cos(w)) / w;
}

/// Magnitude of the same filter at angular frequency w.
fn lowpassMagnitude(p: f32, w: f32) f32 {
    const d = 1.0 - 2.0 * p * @cos(w) + p * p;
    return (1.0 - p) / @sqrt(@max(d, 1.0e-9));
}

/// Friction curve between bow and string. `dv` is bow velocity minus string
/// velocity, `pressure` is 0..1. Returns the fraction of dv transferred to the string.
fn bowFriction(dv: f32, pressure: f32) f32 {
    const slope = 5.0 - 4.0 * pressure;
    const s = @abs(dv * slope) + 0.75;
    const s2 = s * s;
    return @min(1.0, 1.0 / (s2 * s2));
}

/// One waveguide string voice, used for either mode.
const StringVoice = struct {
    neck: Line = .{}, // nut side of the bow
    bridge: Line = .{}, // bridge side of the bow
    noise: Noise = .{},

    active: bool = false,
    gate: bool = false,
    note: u8 = 0,
    age: u64 = 0,
    sample_rate: f32 = 48000.0,

    // Tuning
    freq: f32 = 220.0,
    loss_delay: f32 = 0.0, // phase delay of the loss filter at the fundamental (samples)

    // Loss filter
    loss_p: f32 = 0.2,
    loss_gain: f32 = 0.99,
    loss_state: f32 = 0.0,

    // Bow
    bow_speed: f32 = 0.3,
    bow_pressure: f32 = 0.5,
    bow_env: f32 = 0.0,
    bow_attack: f32 = 0.0, // per-sample increment toward 1
    bow_release: f32 = 0.0, // per-sample multiplier

    // Pluck burst
    burst_left: u32 = 0,
    burst_amp: f32 = 0.0,
    burst_lp: f32 = 0.0,
    burst_coef: f32 = 1.0,

    // Vibrato
    vib_phase: f32 = 0.0,
    vib_age: u32 = 0,

    // Output
    out_gain: f32 = 0.0,
    out_gain_mul: f32 = 1.0,
    out_scale: f32 = 1.0,
    dc_x: f32 = 0.0,
    dc_y: f32 = 0.0,
    level: f32 = 0.0,

    fn start(
        self: *StringVoice,
        comptime mode: Mode,
        note: u8,
        velocity: u8,
        sample_rate: f32,
        brightness: f32,
        decay_or_attack: f32,
        age: u64,
    ) void {
        const v = @as(f32, @floatFromInt(velocity)) / 127.0;
        self.neck.clear();
        self.bridge.clear();
        self.loss_state = 0.0;
        self.dc_x = 0.0;
        self.dc_y = 0.0;
        self.level = 0.0;
        self.sample_rate = sample_rate;
        self.note = note;
        self.age = age;
        self.active = true;
        self.gate = true;
        self.vib_phase = 0.0;
        self.vib_age = 0;
        self.out_gain = 1.0;
        self.out_gain_mul = 1.0;
        self.noise.state ^= @as(u32, note) *% 2654435761 +% 1;
        if (self.noise.state == 0) self.noise.state = 0x9E37_79B9;

        const max_freq = sample_rate * 0.25;
        self.freq = std.math.clamp(dsp.midiNoteToFreq(note), 8.0, max_freq);
        const w = 2.0 * std.math.pi * self.freq / sample_rate;
        const period_s = 1.0 / self.freq;

        switch (mode) {
            .bowed => {
                self.loss_p = 0.5 - 0.4 * brightness; // 0.5 dark .. 0.1 bright
                const target = 0.9965; // round trip gain at the fundamental
                self.loss_gain = target / lowpassMagnitude(self.loss_p, w);
                self.bow_speed = 0.12 + 0.28 * v;
                self.bow_pressure = std.math.clamp(0.35 + 0.45 * v, 0.0, 1.0);
                const attack_s = std.math.clamp(decay_or_attack, 0.01, 1.0);
                self.bow_env = 0.0;
                self.bow_attack = 1.0 / (attack_s * sample_rate);
                self.bow_release = @exp(-1.0 / (0.08 * sample_rate));
                self.out_scale = 0.9 * (0.4 + 0.6 * v);
                self.burst_left = 0;
            },
            .plucked => {
                self.loss_p = 0.5 - 0.45 * brightness; // 0.5 dark .. 0.05 bright
                const t60 = std.math.clamp(decay_or_attack, 0.1, 20.0);
                const target = std.math.pow(f32, 10.0, -3.0 * period_s / t60);
                self.loss_gain = target / lowpassMagnitude(self.loss_p, w);
                self.bow_env = 0.0;
                self.bow_attack = 0.0;
                self.out_scale = 0.8 * (0.3 + 0.7 * v);
                self.burst_left = @intFromFloat(@ceil(sample_rate / self.freq));
                self.burst_amp = 3.0;
                self.burst_lp = 0.0;
                self.burst_coef = 0.04 + 0.96 * brightness;
            },
        }
        self.loss_delay = lowpassPhaseDelay(self.loss_p, w);
    }

    fn release(self: *StringVoice, comptime mode: Mode) void {
        self.gate = false;
        const t: f32 = switch (mode) {
            .bowed => 0.35,
            .plucked => 0.5,
        };
        self.out_gain_mul = @exp(-1.0 / (t * self.sample_rate));
    }

    fn kill(self: *StringVoice) void {
        self.active = false;
        self.gate = false;
        self.out_gain = 0.0;
        self.level = 0.0;
    }

    /// Render one sample. Returns mono output.
    fn tick(self: *StringVoice, comptime mode: Mode, vibrato_depth: f32) f32 {
        // Slow vibrato (about 5.3 Hz) that fades in after 0.25 s. Depth is up to +-30 cents.
        var freq = self.freq;
        if (mode == .bowed and vibrato_depth > 0.0) {
            const fade = std.math.clamp(
                (@as(f32, @floatFromInt(self.vib_age)) / self.sample_rate - 0.25) / 0.5,
                0.0,
                1.0,
            );
            self.vib_phase += 5.3 / self.sample_rate;
            if (self.vib_phase >= 1.0) self.vib_phase -= 1.0;
            const cents = 30.0 * vibrato_depth * fade * @sin(2.0 * std.math.pi * self.vib_phase);
            freq *= std.math.pow(f32, 2.0, cents / 1200.0);
        }
        self.vib_age +%= 1;

        // Total loop delay, minus the loss filter's phase delay.
        const total = std.math.clamp(
            self.sample_rate / freq - self.loss_delay,
            8.0,
            @as(f32, @floatFromInt(LINE_LEN - 4)),
        );
        const d_bridge = total * BOW_POSITION;
        const d_neck = total - d_bridge;

        const bridge_out = self.bridge.read(d_bridge);
        const neck_out = self.neck.read(d_neck);

        // Bridge reflection: lowpass loss, gain below one, inversion.
        const p = self.loss_p;
        self.loss_state = (1.0 - p) * bridge_out + p * self.loss_state;
        const bridge_refl = -self.loss_gain * self.loss_state;
        const nut_refl = -neck_out;

        var neck_in = bridge_refl;
        var bridge_in = nut_refl;

        switch (mode) {
            .bowed => {
                if (self.gate) {
                    self.bow_env = @min(1.0, self.bow_env + self.bow_attack);
                } else {
                    self.bow_env *= self.bow_release;
                }
                // A little bow noise keeps the stick-slip alive and natural.
                const bow_v = self.bow_speed * self.bow_env * (1.0 + 0.02 * self.noise.next());
                const pressure = self.bow_pressure * self.bow_env;
                const string_v = bridge_refl + nut_refl;
                const dv = bow_v - string_v;
                const new_v = dv * bowFriction(dv, pressure);
                neck_in += new_v;
                bridge_in += new_v;
            },
            .plucked => {
                if (self.burst_left > 0) {
                    self.burst_left -= 1;
                    self.burst_lp += self.burst_coef * (self.noise.next() - self.burst_lp);
                    neck_in += self.burst_amp * self.burst_lp;
                }
            },
        }

        self.neck.write(neck_in);
        self.bridge.write(bridge_in);

        // Output: string velocity at the bridge, DC blocked.
        const raw = bridge_out * self.out_scale;
        const y = raw - self.dc_x + 0.995 * self.dc_y;
        self.dc_x = raw;
        self.dc_y = y;

        if (!self.gate) self.out_gain *= self.out_gain_mul;
        const out = y * self.out_gain;

        self.level = @max(@abs(out), self.level * 0.9995);
        if (!std.math.isFinite(out)) {
            self.kill();
            return 0.0;
        }
        if ((!self.gate and self.out_gain < 1.0e-4) or (self.level < 1.0e-6 and self.age_settled())) {
            self.kill();
        }
        return out;
    }

    /// True once the excitation is over, so a silent string can be freed.
    fn age_settled(self: *const StringVoice) bool {
        return self.burst_left == 0 and self.bow_env == 0.0 and self.vib_age > 2048;
    }
};

fn paramList(comptime mode: Mode) [4]Parameter {
    return switch (mode) {
        .bowed => .{
            .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
            .{ .name = "Attack", .min = 0.01, .max = 1.0, .default = 0.08, .value = 0.08, .unit = "s" },
            .{ .name = "Vibrato", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
            .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        },
        .plucked => .{
            .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.6, .value = 0.6, .unit = "" },
            .{ .name = "Decay", .min = 0.1, .max = 20.0, .default = 3.0, .value = 3.0, .unit = "s" },
            .{ .name = "Unused", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
            .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        },
    };
}

/// Polyphonic host for a string model. One distinct type per mode.
fn StringInstrument(comptime mode: Mode, comptime display_name: []const u8) type {
    return struct {
        const Self = @This();

        instrument: Instrument,
        voices: [MAX_STRING_VOICES]StringVoice = @splat(.{}),
        params: [4]Parameter = paramList(mode),
        sample_rate: f32 = 48000.0,
        counter: u64 = 0,

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
            return .{
                .instrument = .{ .vtable = &vtable, .name = display_name },
                .sample_rate = sample_rate,
            };
        }

        fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            if (sample_rate != 0) self.sample_rate = @floatFromInt(sample_rate);
            const vibrato = if (mode == .bowed) self.params[2].value else 0.0;
            const volume = self.params[3].value;

            const frames = buffer.len / 2;
            for (0..frames) |frame| {
                var sum: f32 = 0.0;
                for (&self.voices) |*voice| {
                    if (voice.active) sum += voice.tick(mode, vibrato);
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
            self.counter +%= 1;

            // Retrigger the same note, else a free voice, else steal the quietest.
            var target: ?*StringVoice = null;
            for (&self.voices) |*voice| {
                if (voice.active and voice.note == note) target = voice;
            }
            if (target == null) {
                for (&self.voices) |*voice| {
                    if (!voice.active) {
                        target = voice;
                        break;
                    }
                }
            }
            if (target == null) {
                var best: *StringVoice = &self.voices[0];
                for (&self.voices) |*voice| {
                    const better_rel = !voice.gate and best.gate;
                    const same_rel = voice.gate == best.gate;
                    if (better_rel or (same_rel and voice.level < best.level)) best = voice;
                }
                target = best;
            }
            const voice = target orelse return;
            voice.start(mode, note, velocity, self.sample_rate, self.params[0].value, self.params[1].value, self.counter);
        }

        fn noteOff(instrument: *Instrument, note: u8) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| {
                if (voice.active and voice.gate and voice.note == note) voice.release(mode);
            }
        }

        fn allNotesOff(instrument: *Instrument) void {
            const self: *Self = @fieldParentPtr("instrument", instrument);
            for (&self.voices) |*voice| voice.kill();
        }

        fn reset(instrument: *Instrument) void {
            allNotesOff(instrument);
        }

        /// Number of voices currently sounding.
        pub fn activeVoices(self: *const Self) usize {
            var n: usize = 0;
            for (&self.voices) |*voice| {
                if (voice.active) n += 1;
            }
            return n;
        }
    };
}

/// Bowed string (waveguide with bow friction).
pub const ModelStrings = StringInstrument(.bowed, "ModelStrings");

/// Plucked string (waveguide with a noise burst).
pub const ModelPluck = StringInstrument(.plucked, "ModelPluck");

// =============================================================================
// Tests
// =============================================================================

const SR: u32 = 48000;

/// Render `seconds` of audio into a mono array (left channel), in 256-frame blocks.
fn renderMono(instrument: *Instrument, out: []f32) void {
    var block: [512]f32 = undefined;
    var pos: usize = 0;
    while (pos < out.len) {
        const n: usize = @min(@as(usize, 256), out.len - pos);
        @memset(block[0 .. n * 2], 0.0);
        instrument.process(block[0 .. n * 2], SR);
        for (0..n) |i| out[pos + i] = block[i * 2];
        pos += n;
    }
}

fn rms(x: []const f32) f32 {
    var s: f64 = 0.0;
    for (x) |v| s += @as(f64, v) * @as(f64, v);
    return @floatCast(@sqrt(s / @as(f64, @floatFromInt(x.len))));
}

fn rmsWindow(x: []const f32, t0: f32, t1: f32) f32 {
    const a: usize = @intFromFloat(t0 * @as(f32, @floatFromInt(SR)));
    const b: usize = @intFromFloat(t1 * @as(f32, @floatFromInt(SR)));
    return rms(x[a..b]);
}

/// Spectral peak (Hann windowed DFT scanned on a fine grid) in [lo, hi] Hz.
fn spectralPeak(x: []const f32, lo: f64, hi: f64) f64 {
    const n = x.len;
    const nf: f64 = @floatFromInt(n);
    const step = 0.02;
    var best_f: f64 = lo;
    var best_m: f64 = -1.0;
    var f = lo;
    while (f <= hi) : (f += step) {
        const w = 2.0 * std.math.pi * f / @as(f64, SR);
        var re: f64 = 0.0;
        var im: f64 = 0.0;
        // Rotating phasor avoids a sin/cos per sample.
        const cw = @cos(w);
        const sw = @sin(w);
        var c: f64 = 1.0;
        var s: f64 = 0.0;
        for (x, 0..) |v, i| {
            const hann = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / nf);
            const hv = hann * @as(f64, v);
            re += hv * c;
            im -= hv * s;
            const nc = c * cw - s * sw;
            s = s * cw + c * sw;
            c = nc;
        }
        const m = re * re + im * im;
        if (m > best_m) {
            best_m = m;
            best_f = f;
        }
    }
    return best_f;
}

fn centsBetween(a: f64, b: f64) f64 {
    return 1200.0 * @log2(a / b);
}

test "model strings init and parameters" {
    var s = ModelStrings.init(48000.0);
    try std.testing.expectEqualStrings("ModelStrings", s.instrument.name);
    try std.testing.expectEqual(@as(usize, 4), s.instrument.getParameterCount());
    s.instrument.setParameter(0, 5.0);
    try std.testing.expectEqual(@as(f32, 1.0), s.instrument.getParameter(0).?.value);
    const p = ModelPluck.init(48000.0);
    try std.testing.expectEqualStrings("ModelPluck", p.instrument.name);
}

test "model strings destroy through the vtable" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelStrings);
    s.* = ModelStrings.init(48000.0);
    s.instrument.noteOn(57, 100);
    s.instrument.deinit(alloc);
    s.instrument.destroy(alloc);
}

test "bowed A3 pitch within 5 cents" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelStrings);
    defer alloc.destroy(s);
    s.* = ModelStrings.init(48000.0);
    s.instrument.setParameter(2, 0.0); // vibrato off for a clean pitch reading
    s.instrument.noteOn(57, 100);

    const out = try alloc.alloc(f32, SR * 2);
    defer alloc.free(out);
    renderMono(&s.instrument, out);

    const a3 = 220.0;
    const peak = spectralPeak(out[SR / 2 .. SR / 2 + SR], a3 * 0.94, a3 * 1.06);
    const cents = centsBetween(peak, a3);
    std.debug.print("bowed A3 peak {d:.3} Hz ({d:.2} cents)\n", .{ peak, cents });
    try std.testing.expect(@abs(cents) <= 5.0);
}

test "plucked A3 pitch within 5 cents" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelPluck);
    defer alloc.destroy(s);
    s.* = ModelPluck.init(48000.0);
    s.instrument.noteOn(57, 100);

    const out = try alloc.alloc(f32, SR * 2);
    defer alloc.free(out);
    renderMono(&s.instrument, out);

    const a3 = 220.0;
    const peak = spectralPeak(out[SR / 10 .. SR / 10 + SR], a3 * 0.94, a3 * 1.06);
    const cents = centsBetween(peak, a3);
    std.debug.print("plucked A3 peak {d:.3} Hz ({d:.2} cents)\n", .{ peak, cents });
    try std.testing.expect(@abs(cents) <= 5.0);
}

test "bowed note sustains" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelStrings);
    defer alloc.destroy(s);
    s.* = ModelStrings.init(48000.0);
    s.instrument.noteOn(57, 100);

    const out = try alloc.alloc(f32, SR * 2);
    defer alloc.free(out);
    renderMono(&s.instrument, out);

    const early = rmsWindow(out, 0.1, 0.3);
    const late = rmsWindow(out, 0.5, 1.5);
    std.debug.print("bowed rms early {d:.4} late {d:.4}\n", .{ early, late });
    try std.testing.expect(early > 0.0);
    try std.testing.expect(late > 0.5 * early);
}

test "pluck decays" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelPluck);
    defer alloc.destroy(s);
    s.* = ModelPluck.init(48000.0);
    s.instrument.noteOn(57, 100);

    const out = try alloc.alloc(f32, SR * 3);
    defer alloc.free(out);
    renderMono(&s.instrument, out);

    const early = rmsWindow(out, 0.2, 0.3);
    const late = rmsWindow(out, 2.0, 2.1);
    std.debug.print("pluck rms at 0.2s {d:.4} at 2s {d:.4}\n", .{ early, late });
    try std.testing.expect(early > 0.001);
    try std.testing.expect(late < early);
}

test "output stays finite and below 1.5 for 10 seconds" {
    const alloc = std.testing.allocator;
    const out = try alloc.alloc(f32, SR * 10);
    defer alloc.free(out);

    const notes = [_]u8{ 40, 48, 57, 64, 72, 84, 45 };

    const bowed = try alloc.create(ModelStrings);
    defer alloc.destroy(bowed);
    bowed.* = ModelStrings.init(48000.0);
    bowed.instrument.setParameter(3, 1.0);
    // More notes than voices to exercise stealing, all at full velocity.
    for (notes) |n| bowed.instrument.noteOn(n, 127);
    renderMono(&bowed.instrument, out);
    var peak: f32 = 0.0;
    for (out) |v| {
        try std.testing.expect(std.math.isFinite(v));
        peak = @max(peak, @abs(v));
    }
    std.debug.print("bowed 10 s peak {d:.4}\n", .{peak});
    try std.testing.expect(peak < 1.5);
    try std.testing.expect(bowed.activeVoices() <= MAX_STRING_VOICES);

    const plucked = try alloc.create(ModelPluck);
    defer alloc.destroy(plucked);
    plucked.* = ModelPluck.init(48000.0);
    plucked.instrument.setParameter(3, 1.0);
    for (notes) |n| plucked.instrument.noteOn(n, 127);
    renderMono(&plucked.instrument, out);
    peak = 0.0;
    for (out) |v| {
        try std.testing.expect(std.math.isFinite(v));
        peak = @max(peak, @abs(v));
    }
    std.debug.print("pluck 10 s peak {d:.4}\n", .{peak});
    try std.testing.expect(peak < 1.5);
}

test "note off releases the voice" {
    const alloc = std.testing.allocator;
    const s = try alloc.create(ModelStrings);
    defer alloc.destroy(s);
    s.* = ModelStrings.init(48000.0);
    s.instrument.noteOn(60, 100);
    s.instrument.noteOn(64, 100);
    try std.testing.expectEqual(@as(usize, 2), s.activeVoices());
    s.instrument.noteOff(60);
    s.instrument.noteOff(64);
    const out = try alloc.alloc(f32, SR * 3);
    defer alloc.free(out);
    renderMono(&s.instrument, out);
    try std.testing.expectEqual(@as(usize, 0), s.activeVoices());
}
