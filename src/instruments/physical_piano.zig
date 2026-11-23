//! ModelPiano - physically modelled piano
//!
//! Every note is three slightly detuned strings. Each string is a digital
//! waveguide: a delay line closed into a loop through
//!   - a two-pole low-pass loss filter (high partials die faster than low ones),
//!   - a chain of first-order allpass filters whose delay falls with frequency
//!     (string stiffness: partials land sharp of the harmonic series),
//!   - a fractional-delay allpass that tunes the loop to the exact pitch.
//! The loop delay is computed from the analytic phase delay of the filters at
//! the fundamental, so the note lands on pitch despite the dispersion.
//!
//! The hammer is a half-sine force pulse whose contact time shortens with
//! velocity (harder strike, brighter spectrum). It is injected as a pulse minus
//! a delayed copy, which models the strike position and keeps DC out of the loop.
//!
//! No allocation after construction, no sample files, no sustain pedal.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;
const velocityToAmplitude = inst.velocityToAmplitude;

/// Polyphony
pub const MAX_VOICES = inst.MAX_VOICES;

/// Strings per note
const STRINGS = 3;
/// Delay line length per string (power of two)
const BUF_LEN = 2048;
const BUF_MASK = BUF_LEN - 1;
/// Longest dispersion allpass chain
const MAX_DISP = 4;
/// Strike position as a fraction of the string length
const STRIKE_POS = 0.19;
/// Excitation gain (tuned so a full velocity note peaks near 0.5 at default volume)
const EXC_GAIN = 0.16;
/// Reference hammer contact time for the amplitude normalisation, seconds
const REF_CONTACT = 0.003;
/// Unison detune shape, in units of the Detune parameter (cents)
const DETUNE_SHAPE = [STRINGS]f64{ -1.0, 0.2, 1.0 };
/// Per-string gains into left and right
const MIX_L = [STRINGS]f32{ 0.6, 0.5, 0.4 };
const MIX_R = [STRINGS]f32{ 0.4, 0.5, 0.6 };
/// Voice goes silent below this level
const SILENCE = 1.0e-6;

/// Parameter indices
const P_VOLUME = 0;
const P_HARDNESS = 1;
const P_DECAY = 2;
const P_INHARM = 3;
const P_DETUNE = 4;

// =============================================================================
// Phase delay helpers (f64, used only when a note starts)
// =============================================================================

/// Phase delay in samples of (a + z^-1) / (1 + a z^-1) at angular frequency w
fn allpassPhaseDelay(a: f64, w: f64) f64 {
    const s = @sin(w);
    const c = @cos(w);
    return (std.math.atan2(s, a + c) - std.math.atan2(a * s, 1.0 + a * c)) / w;
}

/// Phase delay in samples of y = (1 - p) x + p y1 at angular frequency w
fn onePolePhaseDelay(p: f64, w: f64) f64 {
    return std.math.atan2(p * @sin(w), 1.0 - p * @cos(w)) / w;
}

// =============================================================================
// String
// =============================================================================

const String = struct {
    buf: [BUF_LEN]f32 = @splat(0.0),
    w: usize = 0,
    /// Integer part of the loop delay
    m: usize = 1,
    frac_a: f32 = 0.0,
    frac_z: f32 = 0.0,
    disp_a: f32 = 0.0,
    disp_z: [MAX_DISP]f32 = @splat(0.0),
    n_disp: usize = 0,
    lp_p: f32 = 0.0,
    lp_z: [2]f32 = .{ 0.0, 0.0 },
    /// Loop gain at DC (sets the fundamental decay)
    gain: f32 = 0.0,
    /// Extra loop gain while the damper is down
    damper: f32 = 1.0,
    damped: bool = false,
    /// Strike-position offset in samples
    strike_off: i64 = 0,

    const Settings = struct {
        freq: f64,
        sample_rate: f64,
        /// Dispersion allpass magnitude (coefficient is -c)
        disp: f64,
        /// Loss pole
        loss_p: f64,
        /// Fundamental T60 in seconds
        t60: f64,
    };

    fn setup(self: *String, s: Settings) void {
        @memset(&self.buf, 0.0);
        self.w = 0;
        self.frac_z = 0.0;
        self.disp_z = @splat(0.0);
        self.lp_z = .{ 0.0, 0.0 };
        self.damped = false;

        const w0 = 2.0 * std.math.pi * s.freq / s.sample_rate;
        const period = s.sample_rate / s.freq;
        const c = std.math.clamp(s.disp, 0.0, 0.85);

        const pd_loss = 2.0 * onePolePhaseDelay(s.loss_p, w0);
        const pd_stage = allpassPhaseDelay(-c, w0);

        // Drop dispersion stages until the loop has room for them (top octaves).
        var n: usize = MAX_DISP;
        var target = period - pd_loss - @as(f64, @floatFromInt(n)) * pd_stage;
        while (n > 0 and target < 3.0) {
            n -= 1;
            target = period - pd_loss - @as(f64, @floatFromInt(n)) * pd_stage;
        }
        if (target < 3.0) target = 3.0;

        // Integer delay plus fractional allpass delay in [1, 2).
        const whole = @floor(target) - 1.0;
        const want = target - whole;
        var lo: f64 = -0.5;
        var hi: f64 = 0.2;
        for (0..40) |_| {
            const mid = 0.5 * (lo + hi);
            if (allpassPhaseDelay(mid, w0) > want) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        const frac = 0.5 * (lo + hi);

        const max_m: f64 = BUF_LEN - 1;
        self.m = @intFromFloat(std.math.clamp(whole, 1.0, max_m));
        self.frac_a = @floatCast(frac);
        self.n_disp = n;
        self.disp_a = @floatCast(-c);
        self.lp_p = @floatCast(s.loss_p);

        const loop_gain = std.math.pow(f64, 10.0, -3.0 / (s.t60 * s.freq));
        self.gain = @floatCast(@min(loop_gain, 0.99995));
        // Damper: about a quarter second to silence
        self.damper = @floatCast(std.math.pow(f64, 10.0, -3.0 / (0.25 * s.freq)));
        self.strike_off = @intFromFloat(@round(STRIKE_POS * period));
    }

    inline fn tick(self: *String, excitation: f32) f32 {
        const d = self.buf[(self.w + BUF_LEN - self.m) & BUF_MASK];

        // Two-pole loss filter
        const p = self.lp_p;
        var s = (1.0 - p) * d + p * self.lp_z[0];
        self.lp_z[0] = s;
        s = (1.0 - p) * s + p * self.lp_z[1];
        self.lp_z[1] = s;
        s *= if (self.damped) self.gain * self.damper else self.gain;

        // Dispersion allpass chain
        const a = self.disp_a;
        for (0..self.n_disp) |i| {
            const y = a * s + self.disp_z[i];
            self.disp_z[i] = s - a * y;
            s = y;
        }

        // Fractional delay allpass
        const fa = self.frac_a;
        const y = fa * s + self.frac_z;
        self.frac_z = s - fa * y;

        self.buf[self.w] = y + excitation;
        self.w = (self.w + 1) & BUF_MASK;
        return d;
    }
};

// =============================================================================
// Voice
// =============================================================================

const Voice = struct {
    strings: [STRINGS]String = .{ .{}, .{}, .{} },
    state: dsp.VoiceState = .off,
    note: u8 = 0,
    age: u32 = 0,
    /// Hammer pulse length in samples and peak force
    hammer_len: u32 = 0,
    hammer_amp: f32 = 0.0,
    level: f32 = 0.0,

    const Params = struct {
        hardness: f32,
        decay: f32,
        inharmonicity: f32,
        detune: f32,
    };

    fn noteOn(self: *Voice, sample_rate: f32, note: u8, velocity: u8, p: Params) void {
        const fs: f64 = sample_rate;
        const lowest = fs / @as(f64, BUF_LEN - 64);
        const highest = fs / 6.0;
        const f0 = std.math.clamp(@as(f64, dsp.midiNoteToFreq(note)), lowest, highest);
        const t = std.math.clamp((@as(f64, @floatFromInt(note)) - 21.0) / 87.0, 0.0, 1.0);

        const v = @as(f64, @floatFromInt(velocity)) / 127.0;
        const contact = std.math.lerp(4.5e-3, 2.0e-3, @as(f64, p.hardness)) * (1.0 - 0.65 * v);
        const len = @max(4.0, @round(contact * fs));
        self.hammer_len = @intFromFloat(len);
        self.hammer_amp = @floatCast(EXC_GAIN * @as(f64, velocityToAmplitude(velocity)) * (REF_CONTACT / contact));

        const disp = (0.62 + 0.20 * t) * 2.0 * @as(f64, p.inharmonicity);
        const loss_p = 0.08 + 0.16 * t;
        const t60 = std.math.lerp(3.0, 16.0, @as(f64, p.decay)) * std.math.pow(f64, 110.0 / f0, 0.35);

        for (&self.strings, 0..) |*str, i| {
            const cents = DETUNE_SHAPE[i] * @as(f64, p.detune);
            str.setup(.{
                .freq = f0 * std.math.pow(f64, 2.0, cents / 1200.0),
                .sample_rate = fs,
                .disp = disp,
                .loss_p = loss_p,
                .t60 = t60,
            });
        }

        self.note = note;
        self.age = 0;
        self.level = 0.0;
        self.state = .playing;
    }

    fn noteOff(self: *Voice) void {
        if (self.state != .playing) return;
        self.state = .releasing;
        for (&self.strings) |*str| str.damped = true;
    }

    fn kill(self: *Voice) void {
        self.state = .off;
        self.level = 0.0;
    }

    inline fn pulse(self: *const Voice, n: i64) f32 {
        if (n < 0 or n >= self.hammer_len) return 0.0;
        const x = std.math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(self.hammer_len));
        return self.hammer_amp * @sin(x);
    }

    /// One frame, returns left and right
    inline fn tick(self: *Voice) [2]f32 {
        const n: i64 = self.age;
        const hammering = n < @as(i64, self.hammer_len) + self.strings[0].strike_off + 4;
        var l: f32 = 0.0;
        var r: f32 = 0.0;
        for (&self.strings, 0..) |*str, i| {
            const ex = if (hammering) self.pulse(n) - self.pulse(n - str.strike_off) else 0.0;
            const o = str.tick(ex);
            l += o * MIX_L[i];
            r += o * MIX_R[i];
        }
        if (self.age < std.math.maxInt(u32)) self.age += 1;

        self.level = @max(@abs(l) + @abs(r), self.level * 0.9997);
        if (self.age > 8192 and self.level < SILENCE) self.state = .off;
        return .{ l, r };
    }
};

// =============================================================================
// Instrument
// =============================================================================

/// Physically modelled piano with up to 16 voices
pub const ModelPiano = struct {
    instrument: Instrument,
    voices: [MAX_VOICES]Voice,
    params: [5]Parameter,
    sample_rate: f32,

    const ParamHelpers = ParameterMixin(ModelPiano, "instrument");
    const DestroyHelpers = DestroyMixin(ModelPiano, "instrument");

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

    /// Build a piano by value. The struct is a few hundred KB; prefer
    /// `create` or `setup` on heap storage where stack space is tight.
    pub fn init(sample_rate: f32) ModelPiano {
        var piano: ModelPiano = undefined;
        piano.setup(sample_rate);
        return piano;
    }

    /// Allocate and initialise a piano. Free with `instrument.destroy(allocator)`.
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*ModelPiano {
        const piano = try allocator.create(ModelPiano);
        piano.setup(sample_rate);
        return piano;
    }

    /// Initialise in place
    pub fn setup(self: *ModelPiano, sample_rate: f32) void {
        self.instrument = .{ .vtable = &vtable, .name = "Model Piano" };
        self.sample_rate = sample_rate;
        self.params = .{
            .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
            .{ .name = "Hardness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
            .{ .name = "Decay", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
            .{ .name = "Inharmonicity", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
            .{ .name = "Detune", .min = 0.0, .max = 4.0, .default = 1.0, .value = 1.0, .unit = "cents" },
        };
        for (&self.voices) |*voice| voice.* = .{};
    }

    fn voiceParams(self: *const ModelPiano) Voice.Params {
        return .{
            .hardness = self.params[P_HARDNESS].value,
            .decay = self.params[P_DECAY].value,
            .inharmonicity = self.params[P_INHARM].value,
            .detune = self.params[P_DETUNE].value,
        };
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *ModelPiano = @fieldParentPtr("instrument", instrument);
        if (sample_rate != 0) self.sample_rate = @floatFromInt(sample_rate);

        const volume = self.params[P_VOLUME].value;
        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            var l: f32 = 0.0;
            var r: f32 = 0.0;
            for (&self.voices) |*voice| {
                if (voice.state == .off) continue;
                const o = voice.tick();
                l += o[0];
                r += o[1];
            }
            buffer[frame * 2] += dsp.softClip(l * volume);
            buffer[frame * 2 + 1] += dsp.softClip(r * volume);
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *ModelPiano = @fieldParentPtr("instrument", instrument);
        if (velocity == 0) {
            noteOff(instrument, note);
            return;
        }
        const vp = self.voiceParams();

        // Retrigger the same note on its own voice
        for (&self.voices) |*voice| {
            if (voice.state != .off and voice.note == note) {
                voice.noteOn(self.sample_rate, note, velocity, vp);
                return;
            }
        }
        for (&self.voices) |*voice| {
            if (voice.state == .off) {
                voice.noteOn(self.sample_rate, note, velocity, vp);
                return;
            }
        }

        // Steal: prefer the quietest released voice, else the quietest overall
        var pick: *Voice = &self.voices[0];
        var pick_released = pick.state == .releasing;
        for (&self.voices) |*voice| {
            const released = voice.state == .releasing;
            if ((released and !pick_released) or (released == pick_released and voice.level < pick.level)) {
                pick = voice;
                pick_released = released;
            }
        }
        pick.noteOn(self.sample_rate, note, velocity, vp);
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *ModelPiano = @fieldParentPtr("instrument", instrument);
        for (&self.voices) |*voice| {
            if (voice.state == .playing and voice.note == note) voice.noteOff();
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *ModelPiano = @fieldParentPtr("instrument", instrument);
        for (&self.voices) |*voice| voice.kill();
    }

    fn reset(instrument: *Instrument) void {
        allNotesOff(instrument);
    }

    /// Number of voices currently sounding
    pub fn activeVoices(self: *const ModelPiano) usize {
        var count: usize = 0;
        for (&self.voices) |*voice| {
            if (voice.state != .off) count += 1;
        }
        return count;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TEST_RATE: u32 = 48000;

fn newPiano() !*ModelPiano {
    return ModelPiano.create(testing.allocator, @floatFromInt(TEST_RATE));
}

/// Play one note and capture the left channel
fn renderNote(piano: *ModelPiano, note: u8, velocity: u8, out: []f32) !void {
    piano.instrument.reset();
    piano.instrument.noteOn(note, velocity);
    var block: [1024]f32 = undefined;
    var pos: usize = 0;
    while (pos < out.len) {
        const n: usize = @min(512, out.len - pos);
        @memset(block[0 .. n * 2], 0.0);
        piano.instrument.process(block[0 .. n * 2], TEST_RATE);
        for (0..n) |i| out[pos + i] = block[i * 2];
        pos += n;
    }
}

/// Hann-windowed single-bin DFT magnitude at an arbitrary frequency
fn binMagnitude(x: []const f32, freq: f64, fs: f64) f64 {
    var re: f64 = 0.0;
    var im: f64 = 0.0;
    const n: f64 = @floatFromInt(x.len);
    const w = 2.0 * std.math.pi * freq / fs;
    for (x, 0..) |sample, i| {
        const fi: f64 = @floatFromInt(i);
        const win = 0.5 - 0.5 * @cos(2.0 * std.math.pi * fi / n);
        const v = @as(f64, sample) * win;
        re += v * @cos(w * fi);
        im -= v * @sin(w * fi);
    }
    return @sqrt(re * re + im * im);
}

/// Strongest spectral peak in [lo, hi] Hz: coarse scan, then a fine scan around it
fn peakFrequency(x: []const f32, lo: f64, hi: f64, coarse: f64, fs: f64) f64 {
    var best_f = lo;
    var best_m: f64 = -1.0;
    var f = lo;
    while (f <= hi) : (f += coarse) {
        const m = binMagnitude(x, f, fs);
        if (m > best_m) {
            best_m = m;
            best_f = f;
        }
    }
    const fine = coarse / 20.0;
    var g = best_f - coarse;
    best_m = -1.0;
    var refined = best_f;
    while (g <= best_f + coarse) : (g += fine) {
        const m = binMagnitude(x, g, fs);
        if (m > best_m) {
            best_m = m;
            refined = g;
        }
    }
    return refined;
}

fn centsBetween(a: f64, b: f64) f64 {
    return 1200.0 * std.math.log2(a / b);
}

fn rms(x: []const f32) f64 {
    var sum: f64 = 0.0;
    for (x) |s| sum += @as(f64, s) * @as(f64, s);
    return @sqrt(sum / @as(f64, @floatFromInt(x.len)));
}

/// In-place radix-2 FFT
fn fft(re: []f64, im: []f64) void {
    const n = re.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        var start: usize = 0;
        while (start < n) : (start += len) {
            for (0..len / 2) |k| {
                const wr = @cos(ang * @as(f64, @floatFromInt(k)));
                const wi = @sin(ang * @as(f64, @floatFromInt(k)));
                const a = start + k;
                const b = a + len / 2;
                const tr = re[b] * wr - im[b] * wi;
                const ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}

fn spectralCentroidHz(x: []const f32, fs: f64) f64 {
    const n = 16384;
    var re: [n]f64 = undefined;
    var im: [n]f64 = @splat(0.0);
    for (0..n) |i| {
        const fi: f64 = @floatFromInt(i);
        const win = 0.5 - 0.5 * @cos(2.0 * std.math.pi * fi / n);
        re[i] = @as(f64, x[i]) * win;
    }
    fft(&re, &im);
    var num: f64 = 0.0;
    var den: f64 = 0.0;
    for (1..n / 2) |k| {
        const mag = @sqrt(re[k] * re[k] + im[k] * im[k]);
        num += mag * fs * @as(f64, @floatFromInt(k)) / n;
        den += mag;
    }
    return if (den > 0.0) num / den else 0.0;
}

test "model piano init and parameters" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    try testing.expectEqualStrings("Model Piano", piano.instrument.name);
    try testing.expectEqual(@as(usize, 5), piano.instrument.getParameterCount());
    piano.instrument.setParameter(0, 5.0);
    try testing.expectEqual(@as(f32, 1.0), piano.instrument.getParameter(0).?.value);
}

test "model piano A3 pitch within 5 cents" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    const out = try testing.allocator.alloc(f32, TEST_RATE * 11 / 10);
    defer testing.allocator.free(out);
    try renderNote(piano, 57, 100, out);

    const seg = out[TEST_RATE / 10 ..][0..TEST_RATE];
    const f1 = peakFrequency(seg, 205.0, 235.0, 0.5, TEST_RATE);
    const cents = centsBetween(f1, 220.0);
    std.debug.print("A3 fundamental {d:.3} Hz ({d:.2} cents)\n", .{ f1, cents });
    try testing.expect(@abs(cents) < 5.0);
}

test "model piano partial 8 is inharmonic (sharp)" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    const out = try testing.allocator.alloc(f32, TEST_RATE * 11 / 10);
    defer testing.allocator.free(out);
    try renderNote(piano, 57, 110, out);

    const seg = out[TEST_RATE / 10 ..][0..TEST_RATE];
    const f1 = peakFrequency(seg, 205.0, 235.0, 0.5, TEST_RATE);
    const f8 = peakFrequency(seg, 8.0 * f1 * 0.98, 8.0 * f1 * 1.06, 0.5, TEST_RATE);
    const sharp = centsBetween(f8, 8.0 * f1);
    std.debug.print("partial 8 {d:.2} Hz vs 8*f1 {d:.2} Hz: {d:.2} cents sharp\n", .{ f8, 8.0 * f1, sharp });
    try testing.expect(sharp > 3.0);
}

test "model piano louder velocity is brighter" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    const soft = try testing.allocator.alloc(f32, 16384);
    defer testing.allocator.free(soft);
    const loud = try testing.allocator.alloc(f32, 16384);
    defer testing.allocator.free(loud);
    try renderNote(piano, 57, 30, soft);
    try renderNote(piano, 57, 120, loud);

    const c_soft = spectralCentroidHz(soft, TEST_RATE);
    const c_loud = spectralCentroidHz(loud, TEST_RATE);
    std.debug.print("centroid vel 30: {d:.1} Hz, vel 120: {d:.1} Hz\n", .{ c_soft, c_loud });
    try testing.expect(c_soft > 0.0);
    try testing.expect(c_loud > c_soft);
}

test "model piano decays over time" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    const out = try testing.allocator.alloc(f32, TEST_RATE * 31 / 10);
    defer testing.allocator.free(out);
    try renderNote(piano, 57, 100, out);

    const early = rms(out[TEST_RATE * 15 / 100 ..][0 .. TEST_RATE / 10]);
    const late = rms(out[TEST_RATE * 295 / 100 ..][0 .. TEST_RATE / 10]);
    std.debug.print("rms at 0.2 s: {d:.5}, at 3 s: {d:.5}\n", .{ early, late });
    try testing.expect(early > 0.0);
    try testing.expect(late < early);
}

test "model piano output is finite and bounded across the keyboard" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    const out = try testing.allocator.alloc(f32, TEST_RATE);
    defer testing.allocator.free(out);

    const notes = [_]u8{ 0, 21, 33, 45, 57, 69, 81, 93, 108, 120, 127 };
    var worst: f32 = 0.0;
    for (notes) |note| {
        for ([_]u8{ 1, 64, 127 }) |vel| {
            try renderNote(piano, note, vel, out);
            for (out) |s| {
                try testing.expect(std.math.isFinite(s));
                worst = @max(worst, @abs(s));
            }
        }
    }
    std.debug.print("worst peak across keyboard: {d:.3}\n", .{worst});
    try testing.expect(worst < 1.5);
}

test "model piano polyphony caps at 16 and stays bounded" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    for (0..20) |i| piano.instrument.noteOn(@intCast(48 + i * 2), 127);
    try testing.expectEqual(@as(usize, 16), piano.activeVoices());

    var block: [1024]f32 = undefined;
    var peak: f32 = 0.0;
    for (0..100) |_| {
        @memset(&block, 0.0);
        piano.instrument.process(&block, TEST_RATE);
        for (block) |s| {
            try testing.expect(std.math.isFinite(s));
            peak = @max(peak, @abs(s));
        }
    }
    std.debug.print("16-voice chord peak: {d:.3}\n", .{peak});
    try testing.expect(peak < 1.5);

    piano.instrument.allNotesOff();
    try testing.expectEqual(@as(usize, 0), piano.activeVoices());
}

test "model piano note off damps the string" {
    const piano = try newPiano();
    defer piano.instrument.destroy(testing.allocator);

    var block: [1024]f32 = undefined;
    piano.instrument.noteOn(60, 100);
    for (0..20) |_| {
        @memset(&block, 0.0);
        piano.instrument.process(&block, TEST_RATE);
    }
    const before = rms(&block);
    piano.instrument.noteOff(60);
    for (0..100) |_| {
        @memset(&block, 0.0);
        piano.instrument.process(&block, TEST_RATE);
    }
    try testing.expect(rms(&block) < before * 0.1);
}
