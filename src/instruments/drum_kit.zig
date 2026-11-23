//! DrumKit - Synthesized General-MIDI-style drum instrument
//!
//! Each MIDI note selects a synthesized voice:
//!   36 kick (pitch-swept sine)
//!   38, 40 snare (two-sine body, band-passed noise snap, short click)
//!   39 clap (bursts of noise)
//!   42 closed hat, 46 open hat (filtered noise, longer decay for open)
//!   41, 43, 45 low, mid, high toms (sine with pitch drop)
//! Notes without a voice are silent. Velocity scales loudness.
//! Up to 16 simultaneous voices. The render loop performs no allocation.

const std = @import("std");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const MAX_VOICES = inst.MAX_VOICES;
const TWO_PI: f32 = 2.0 * std.math.pi;

/// Drum voice kinds
pub const DrumType = enum {
    kick,
    snare,
    clap,
    closed_hat,
    open_hat,
    tom_low,
    tom_mid,
    tom_high,
};

/// Map a MIDI note to a drum voice, or null if the note is unmapped.
pub fn drumForNote(note: u8) ?DrumType {
    return switch (note) {
        36 => .kick,
        38, 40 => .snare,
        39 => .clap,
        42 => .closed_hat,
        46 => .open_hat,
        41 => .tom_low,
        43 => .tom_mid,
        45 => .tom_high,
        else => null,
    };
}

/// Per-kit voicing. The defaults reproduce the base DrumKit exactly; variants
/// such as the 808 and 909 are the same type with different values.
pub const Voicing = struct {
    kick_start_hz: f32 = 160.0,
    kick_end_hz: f32 = 45.0,
    kick_amp_tau: f32 = 0.18,
    kick_click_level: f32 = 0.3,
    kick_click_tau: f32 = 0.002,
    kick_length: f32 = 1.2,
    snare_tone_level: f32 = 0.7,
    snare_noise_level: f32 = 2.5,
    snare_hp_coeff: f32 = 0.85,
    snare_decay_mul: f32 = 1.0,
    /// Centre of the band-pass that shapes the snare snap noise.
    snare_bp_hz: f32 = 3500.0,
    snare_bp_q: f32 = 0.9,
    snare_click_level: f32 = 0.5,
    hat_hp_coeff: f32 = 0.93,
    hat_decay_mul: f32 = 1.0,
};

/// Fixed stereo placement, deterministic. Hats alternate left and right on
/// each hat hit (`hat_index` counts hat triggers, so eighth-note hats swing
/// -0.4, 0.4, ...). Toms spread from low (-0.5) through mid (0) to high (0.5).
/// Everything else stays centered; the track pan places the kit as a whole.
pub const hat_pan_width: f32 = 0.4;

pub fn drumPan(kind: DrumType, hat_index: u32) f32 {
    return switch (kind) {
        .closed_hat, .open_hat => if (hat_index % 2 == 0) -hat_pan_width else hat_pan_width,
        .tom_low => -0.5,
        .tom_mid => 0.0,
        .tom_high => 0.5,
        .kick, .snare, .clap => 0.0,
    };
}

/// Linear balance gains: the louder side stays at unity, so center is unchanged.
fn panGains(pan: f32) [2]f32 {
    const p = std.math.clamp(pan, -1.0, 1.0);
    return .{ @min(1.0, 1.0 - p), @min(1.0, 1.0 + p) };
}

/// One drum voice. Fully self-contained, no allocation.
const DrumVoice = struct {
    active: bool = false,
    kind: DrumType = .kick,
    note: u8 = 0,
    velocity: f32 = 0.0,
    pan: f32 = 0.0,

    age: u32 = 0, // samples since trigger
    phase: f32 = 0.0,
    noise_state: u32 = 0x1234_5678,
    hp_prev_in: f32 = 0.0,
    hp_prev_out: f32 = 0.0,
    lp_state: f32 = 0.0,
    phase2: f32 = 0.0, // second body sine (snare)
    svf_low: f32 = 0.0, // state-variable band-pass (snare)
    svf_band: f32 = 0.0,

    fn nextNoise(self: *DrumVoice) f32 {
        // xorshift32 -> [-1, 1)
        var x = self.noise_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.noise_state = x;
        const u: f32 = @floatFromInt(x >> 8); // 24 bits
        return u / 8388608.0 - 1.0;
    }

    fn trigger(self: *DrumVoice, note: u8, kind: DrumType, vel: u8, seed: u32, pan: f32) void {
        self.active = true;
        self.pan = pan;
        self.kind = kind;
        self.note = note;
        self.velocity = velocityToAmplitude(vel);
        self.age = 0;
        self.phase = 0.0;
        self.hp_prev_in = 0.0;
        self.hp_prev_out = 0.0;
        self.lp_state = 0.0;
        self.phase2 = 0.0;
        self.svf_low = 0.0;
        self.svf_band = 0.0;
        self.noise_state = (seed *% 2654435761) | 1;
    }

    /// Sine with exponential pitch drop and exponential amplitude decay.
    fn sweptSine(self: *DrumVoice, t: f32, sr: f32, f_start: f32, f_end: f32, pitch_tau: f32, amp_tau: f32) f32 {
        const freq = f_end + (f_start - f_end) * @exp(-t / pitch_tau);
        self.phase += freq / sr;
        if (self.phase >= 1.0) self.phase -= 1.0;
        return @sin(self.phase * TWO_PI) * @exp(-t / amp_tau);
    }

    fn highpass(self: *DrumVoice, x: f32, coeff: f32) f32 {
        const y = coeff * (self.hp_prev_out + x - self.hp_prev_in);
        self.hp_prev_in = x;
        self.hp_prev_out = y;
        return y;
    }

    /// Chamberlin state-variable band-pass with unity gain at the centre.
    fn bandpass(self: *DrumVoice, x: f32, sr: f32, hz: f32, q: f32) f32 {
        const f = 2.0 * @sin(std.math.pi * hz / sr);
        const damp = 1.0 / q;
        self.svf_low += f * self.svf_band;
        const high = x - self.svf_low - damp * self.svf_band;
        self.svf_band += f * high;
        return self.svf_band * damp;
    }

    fn lowpass(self: *DrumVoice, x: f32, coeff: f32) f32 {
        self.lp_state += coeff * (x - self.lp_state);
        return self.lp_state;
    }

    fn tick(self: *DrumVoice, sr: f32, decay_scale: f32, v: *const Voicing) f32 {
        if (!self.active) return 0.0;

        const t = @as(f32, @floatFromInt(self.age)) / sr;
        var out: f32 = 0.0;
        var length: f32 = 0.5;

        switch (self.kind) {
            .kick => {
                out = self.sweptSine(t, sr, v.kick_start_hz, v.kick_end_hz, 0.03, v.kick_amp_tau * decay_scale);
                // short click
                out += self.nextNoise() * @exp(-t / v.kick_click_tau) * v.kick_click_level;
                length = v.kick_length * decay_scale;
            },
            .snare => {
                const sd = decay_scale * v.snare_decay_mul;
                // Body: two sines (180 and 230 Hz), each dropping 40 Hz in ~30 ms
                const drop = @exp(-t / 0.01);
                self.phase += (180.0 + 40.0 * drop) / sr;
                if (self.phase >= 1.0) self.phase -= 1.0;
                self.phase2 += (230.0 + 40.0 * drop) / sr;
                if (self.phase2 >= 1.0) self.phase2 -= 1.0;
                const body = (@sin(self.phase * TWO_PI) + @sin(self.phase2 * TWO_PI)) * 0.5 * @exp(-t / (0.18 * sd));
                // Snap: high-passed noise through a band-pass, 60 ms decay
                const raw = self.nextNoise();
                const snap = self.bandpass(self.highpass(raw, v.snare_hp_coeff), sr, v.snare_bp_hz, v.snare_bp_q) * @exp(-t / (0.06 * sd));
                // Click: under 3 ms
                const click = self.nextNoise() * @exp(-t / 0.0006) * v.snare_click_level;
                out = body * v.snare_tone_level + snap * v.snare_noise_level + click;
                length = 0.8 * sd;
            },
            .clap => {
                const n = self.lowpass(self.highpass(self.nextNoise(), 0.9), 0.5);
                // three short bursts then a tail
                const burst_period: f32 = 0.011;
                var env: f32 = 0.0;
                if (t < burst_period * 3.0) {
                    const local = @mod(t, burst_period);
                    env = @exp(-local / 0.002);
                } else {
                    env = @exp(-(t - burst_period * 3.0) / (0.09 * decay_scale));
                }
                out = n * env * 1.2;
                length = 0.6 * decay_scale;
            },
            .closed_hat => {
                const hd = decay_scale * v.hat_decay_mul;
                const n = self.highpass(self.nextNoise(), v.hat_hp_coeff);
                out = n * @exp(-t / (0.03 * hd)) * 0.8;
                length = 0.25 * hd;
            },
            .open_hat => {
                const hd = decay_scale * v.hat_decay_mul;
                const n = self.highpass(self.nextNoise(), v.hat_hp_coeff);
                out = n * @exp(-t / (0.2 * hd)) * 0.8;
                length = 1.2 * hd;
            },
            .tom_low => {
                out = self.sweptSine(t, sr, 140.0, 85.0, 0.05, 0.25 * decay_scale);
                length = 1.2 * decay_scale;
            },
            .tom_mid => {
                out = self.sweptSine(t, sr, 190.0, 120.0, 0.05, 0.22 * decay_scale);
                length = 1.1 * decay_scale;
            },
            .tom_high => {
                out = self.sweptSine(t, sr, 260.0, 165.0, 0.05, 0.2 * decay_scale);
                length = 1.0 * decay_scale;
            },
        }

        self.age += 1;
        if (t > length) self.active = false;

        return out * self.velocity;
    }
};

/// DrumKit instrument
pub const DrumKit = struct {
    instrument: Instrument,

    voices: [MAX_VOICES]DrumVoice = @splat(.{}),

    params: [2]Parameter = .{
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.8, .value = 0.8, .unit = "" },
        .{ .name = "Decay", .min = 0.5, .max = 2.0, .default = 1.0, .value = 1.0, .unit = "" },
    },

    voicing: Voicing = .{},
    sample_rate: f32 = 48000.0,
    trigger_count: u32 = 0,
    hat_count: u32 = 0,

    const ParamHelpers = ParameterMixin(DrumKit, "instrument");
    const DestroyHelpers = DestroyMixin(DrumKit, "instrument");

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

    pub fn init(sample_rate: f32) DrumKit {
        return .{
            .instrument = .{
                .vtable = &vtable,
                .name = "DrumKit",
            },
            .sample_rate = sample_rate,
        };
    }

    /// Same DrumKit type, configured with `voicing` and a variant name.
    pub fn initWith(sample_rate: f32, name: []const u8, voicing: Voicing) DrumKit {
        var kit = init(sample_rate);
        kit.instrument.name = name;
        kit.voicing = voicing;
        return kit;
    }

    /// 808 style: long, low kick; short snares.
    pub fn init808(sample_rate: f32) DrumKit {
        return initWith(sample_rate, "DrumKit808", .{
            .kick_start_hz = 110.0,
            .kick_end_hz = 36.0,
            .kick_amp_tau = 0.45,
            .kick_click_level = 0.1,
            .kick_length = 2.0,
            .snare_decay_mul = 0.7,
            .snare_tone_level = 1.2,
            .snare_noise_level = 1.8,
        });
    }

    /// 909 style: sharp click kick; brighter, noisier snare; tight hats.
    pub fn init909(sample_rate: f32) DrumKit {
        return initWith(sample_rate, "DrumKit909", .{
            .kick_start_hz = 200.0,
            .kick_end_hz = 50.0,
            .kick_amp_tau = 0.15,
            .kick_click_level = 0.8,
            .kick_click_tau = 0.004,
            .snare_tone_level = 0.5,
            .snare_noise_level = 3.5,
            .snare_hp_coeff = 0.75,
            .snare_bp_hz = 5000.0,
            .snare_bp_q = 0.7,
            .hat_hp_coeff = 0.9,
            .hat_decay_mul = 0.6,
        });
    }

    /// Allocate a DrumKit on the heap; free with instrument.destroy(allocator).
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*DrumKit {
        const self = try allocator.create(DrumKit);
        self.* = init(sample_rate);
        return self;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *DrumKit = @fieldParentPtr("instrument", instrument);
        const sr: f32 = if (sample_rate > 0) @floatFromInt(sample_rate) else self.sample_rate;
        const volume = self.params[0].value;
        const decay = self.params[1].value;

        const frames = buffer.len / 2;
        for (0..frames) |frame| {
            var left: f32 = 0.0;
            var right: f32 = 0.0;
            for (&self.voices) |*voice| {
                const x = voice.tick(sr, decay, &self.voicing);
                const g = panGains(voice.pan);
                left += x * g[0];
                right += x * g[1];
            }
            buffer[frame * 2] += left * volume;
            buffer[frame * 2 + 1] += right * volume;
        }
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *DrumKit = @fieldParentPtr("instrument", instrument);
        const kind = drumForNote(note) orelse return;
        if (velocity == 0) return;

        self.trigger_count +%= 1;
        const pan = drumPan(kind, self.hat_count);
        if (kind == .closed_hat or kind == .open_hat) self.hat_count +%= 1;

        // Retrigger same note, else free voice, else steal oldest.
        var target: ?*DrumVoice = null;
        for (&self.voices) |*v| {
            if (v.active and v.note == note) {
                target = v;
                break;
            }
        }
        if (target == null) {
            for (&self.voices) |*v| {
                if (!v.active) {
                    target = v;
                    break;
                }
            }
        }
        if (target == null) {
            var oldest: *DrumVoice = &self.voices[0];
            for (&self.voices) |*v| {
                if (v.age > oldest.age) oldest = v;
            }
            target = oldest;
        }
        if (target) |v| v.trigger(note, kind, velocity, self.trigger_count, pan);
    }

    /// Drums are one-shots: note off does not cut the sound.
    fn noteOff(instrument: *Instrument, note: u8) void {
        _ = instrument;
        _ = note;
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *DrumKit = @fieldParentPtr("instrument", instrument);
        for (&self.voices) |*v| v.active = false;
    }

    fn reset(instrument: *Instrument) void {
        const self: *DrumKit = @fieldParentPtr("instrument", instrument);
        self.hat_count = 0;
        allNotesOff(instrument);
    }
};

// =============================================================================
// Tests
// =============================================================================

const mapped_notes = [_]u8{ 36, 38, 39, 40, 41, 42, 43, 45, 46 };

fn peakOf(buf: []const f32) f32 {
    var p: f32 = 0.0;
    for (buf) |s| p = @max(p, @abs(s));
    return p;
}

test "drumkit init" {
    var kit = DrumKit.init(48000.0);
    try std.testing.expectEqualStrings("DrumKit", kit.instrument.name);
    try std.testing.expectEqual(@as(usize, 2), kit.instrument.getParameterCount());
}

test "each mapped note is audible within 0.5s" {
    var buf: [48000]f32 = undefined; // 0.5 s stereo at 48 kHz = 24000 frames
    for (mapped_notes) |note| {
        var kit = DrumKit.init(48000.0);
        @memset(&buf, 0.0);
        kit.instrument.noteOn(note, 100);
        kit.instrument.process(&buf, 48000);
        const p = peakOf(&buf);
        try std.testing.expect(p > 0.01);
        try std.testing.expect(std.math.isFinite(p));
    }
}

test "unmapped notes are silent" {
    var buf: [48000]f32 = undefined;
    const unmapped = [_]u8{ 0, 35, 37, 44, 47, 60, 127 };
    for (unmapped) |note| {
        var kit = DrumKit.init(48000.0);
        @memset(&buf, 0.0);
        kit.instrument.noteOn(note, 127);
        kit.instrument.process(&buf, 48000);
        try std.testing.expectEqual(@as(f32, 0.0), peakOf(&buf));
    }
}

test "two simultaneous notes do not exceed 4.0 peak" {
    var buf: [48000]f32 = undefined;
    for (mapped_notes) |a| {
        for (mapped_notes) |b| {
            var kit = DrumKit.init(48000.0);
            @memset(&buf, 0.0);
            kit.instrument.noteOn(a, 127);
            kit.instrument.noteOn(b, 127);
            kit.instrument.process(&buf, 48000);
            try std.testing.expect(peakOf(&buf) <= 4.0);
        }
    }
}

test "velocity scales loudness" {
    var soft_buf: [9600]f32 = undefined;
    var loud_buf: [9600]f32 = undefined;
    var soft = DrumKit.init(48000.0);
    var loud = DrumKit.init(48000.0);
    @memset(&soft_buf, 0.0);
    @memset(&loud_buf, 0.0);
    soft.instrument.noteOn(36, 40);
    loud.instrument.noteOn(36, 127);
    soft.instrument.process(&soft_buf, 48000);
    loud.instrument.process(&loud_buf, 48000);
    try std.testing.expect(peakOf(&loud_buf) > peakOf(&soft_buf));
}

test "more than 16 hits steal voices without overflow" {
    var kit = DrumKit.init(48000.0);
    var buf: [2048]f32 = undefined;
    @memset(&buf, 0.0);
    for (0..40) |i| {
        kit.instrument.noteOn(mapped_notes[i % mapped_notes.len], 100);
    }
    kit.instrument.process(&buf, 48000);
    try std.testing.expect(peakOf(&buf) <= 4.0);
    kit.instrument.allNotesOff();
    @memset(&buf, 0.0);
    kit.instrument.process(&buf, 48000);
    try std.testing.expectEqual(@as(f32, 0.0), peakOf(&buf));
}

test "create and destroy via vtable" {
    const kit = try DrumKit.create(std.testing.allocator, 48000.0);
    kit.instrument.destroy(std.testing.allocator);
}

const VariantInit = *const fn (f32) DrumKit;

test "kit variants: audible and different from base" {
    const names = [_][]const u8{ "DrumKit808", "DrumKit909" };
    const inits = [_]VariantInit{ DrumKit.init808, DrumKit.init909 };
    // Notes whose voicing the variant changes (the 808 leaves hats alone)
    const changed = [_][]const u8{ &.{ 36, 38 }, &.{ 36, 38, 42 } };
    const half_second_frames = 24000;
    var base_buf: [half_second_frames * 2]f32 = undefined;
    var var_buf: [half_second_frames * 2]f32 = undefined;

    for (inits, names, changed) |initFn, name, notes| {
        var variant = initFn(48000.0);
        try std.testing.expectEqualStrings(name, variant.instrument.name);
        try std.testing.expectEqual(@as(usize, 2), variant.instrument.getParameterCount());

        // Every mapped note is audible
        for (mapped_notes) |note| {
            var k = initFn(48000.0);
            @memset(&var_buf, 0.0);
            k.instrument.noteOn(note, 100);
            k.instrument.process(&var_buf, 48000);
            const p = peakOf(&var_buf);
            try std.testing.expect(p > 0.01);
            try std.testing.expect(std.math.isFinite(p));
        }

        // Each changed voice differs from the base kit
        for (notes) |note| {
            var base = DrumKit.init(48000.0);
            var k = initFn(48000.0);
            @memset(&base_buf, 0.0);
            @memset(&var_buf, 0.0);
            base.instrument.noteOn(note, 100);
            k.instrument.noteOn(note, 100);
            base.instrument.process(&base_buf, 48000);
            k.instrument.process(&var_buf, 48000);
            var diff: f32 = 0.0;
            for (base_buf, var_buf) |a, b| diff += @abs(a - b);
            try std.testing.expect(diff > 1.0);
        }
    }
}

/// Sum of Goertzel power over [lo, hi] Hz in 50 Hz steps (left channel of a stereo buffer).
fn bandEnergy(stereo: []const f32, sr: f32, lo: f32, hi: f32) f32 {
    const n = stereo.len / 2;
    var total: f32 = 0.0;
    var hz = lo;
    while (hz <= hi) : (hz += 50.0) {
        const w = TWO_PI * hz / sr;
        const coeff = 2.0 * @cos(w);
        var s1: f32 = 0.0;
        var s2: f32 = 0.0;
        for (0..n) |i| {
            const s0 = stereo[i * 2] + coeff * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
        total += power / @as(f32, @floatFromInt(n * n));
    }
    return total;
}

fn renderSnare(kit: *DrumKit, buf: []f32) void {
    @memset(buf, 0.0);
    kit.instrument.noteOn(38, 110);
    kit.instrument.process(buf, 48000);
}

test "808 snare: body (150-250 Hz) outweighs 2-6 kHz" {
    var buf: [24000]f32 = undefined;
    var kit = DrumKit.init808(48000.0);
    renderSnare(&kit, &buf);
    const body = bandEnergy(&buf, 48000.0, 150.0, 250.0);
    const hi = bandEnergy(&buf, 48000.0, 2000.0, 6000.0);
    std.debug.print("808 snare body={d:.6} 2-6k={d:.6}\n", .{ body, hi });
    try std.testing.expect(body > hi);
}

test "909 snare has more energy above 3 kHz than 808" {
    var b808: [24000]f32 = undefined;
    var b909: [24000]f32 = undefined;
    var k808 = DrumKit.init808(48000.0);
    var k909 = DrumKit.init909(48000.0);
    renderSnare(&k808, &b808);
    renderSnare(&k909, &b909);
    const e808 = bandEnergy(&b808, 48000.0, 3000.0, 20000.0);
    const e909 = bandEnergy(&b909, 48000.0, 3000.0, 20000.0);
    std.debug.print("snare >3k 808={d:.6} 909={d:.6}\n", .{ e808, e909 });
    try std.testing.expect(e909 > e808);
}
