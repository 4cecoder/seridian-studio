//! ModelPercussion - modal physical-model percussion
//!
//! Toms, cymbals, a cowbell-like metal and a tuned mallet, all built from
//! banks of exponentially decaying resonators (dsp.modal.Mode). No samples.
//!
//! MIDI map:
//!   41, 43, 45  toms (low, mid, high), fundamental at the MIDI pitch
//!   49          crash cymbal
//!   51          ride cymbal
//!   56          cowbell-like metal
//!   60..72      tuned mallet (bar modes), fundamental at the MIDI pitch
//!
//! Real-time safe: fixed voice pool, no allocation, no locks.

const std = @import("std");
const dsp = @import("../dsp/dsp.zig");
const inst = @import("instrument.zig");
const Instrument = inst.Instrument;
const Parameter = inst.Parameter;
const velocityToAmplitude = inst.velocityToAmplitude;
const ParameterMixin = inst.ParameterMixin;
const DestroyMixin = inst.DestroyMixin;

const Mode = dsp.modal.Mode;
const ModalPresets = dsp.modal.ModalPresets;
const DecayPresets = dsp.modal.DecayPresets;
const AmplitudePresets = dsp.modal.AmplitudePresets;

/// Voices in the pool
pub const MAX_PERC_VOICES = 16;
/// Resonators per voice
pub const MAX_PERC_MODES = 16;

/// Kind of struck object
pub const Kind = enum(u8) {
    tom,
    crash,
    ride,
    metal,
    mallet,

    /// Map a MIDI note to a kind, or null if the note is not mapped
    pub fn fromNote(note: u8) ?Kind {
        return switch (note) {
            41, 43, 45 => .tom,
            49 => .crash,
            51 => .ride,
            56 => .metal,
            60...72 => .mallet,
            else => null,
        };
    }
};

// Inharmonic partial ratios (measured-style cymbal spacing, not harmonic)
const crash_ratios = [MAX_PERC_MODES]f32{ 1.0, 1.47, 2.09, 2.76, 3.52, 4.37, 5.21, 6.58, 8.1, 9.7, 11.9, 14.3, 17.1, 20.5, 24.3, 28.1 };
const ride_ratios = [MAX_PERC_MODES]f32{ 1.0, 1.35, 1.93, 2.51, 3.18, 4.02, 5.07, 6.2, 7.6, 9.2, 11.0, 13.1, 15.6, 18.4, 21.7, 25.2 };
// Cowbell: two dominant inharmonic tones (about 1.48 apart) plus overtones
const metal_ratios = [6]f32{ 1.0, 1.4835, 2.01, 2.97, 4.12, 5.6 };

const Voice = struct {
    modes: [MAX_PERC_MODES]Mode = @splat(.{}),
    count: usize = 0,
    note: u8 = 0,
    kind: Kind = .tom,
    active: bool = false,
    age: u32 = 0,
    samples: u32 = 0,

    fn isSilent(self: *const Voice) bool {
        for (self.modes[0..self.count]) |*m| {
            if (m.getEnergy() > 1.0e-5) return false;
        }
        return true;
    }

    fn tick(self: *Voice) f32 {
        if (!self.active) return 0.0;
        var sum: f32 = 0.0;
        for (self.modes[0..self.count]) |*m| sum += m.process();
        self.samples +%= 1;
        if (self.samples & 127 == 0 and self.isSilent()) self.active = false;
        return sum;
    }
};

/// Modal percussion instrument
pub const ModelPercussion = struct {
    instrument: Instrument,

    voices: [MAX_PERC_VOICES]Voice = @splat(.{}),

    params: [3]Parameter = .{
        .{ .name = "Volume", .min = 0.0, .max = 1.0, .default = 0.7, .value = 0.7, .unit = "" },
        .{ .name = "Decay", .min = 0.2, .max = 2.0, .default = 1.0, .value = 1.0, .unit = "x" },
        .{ .name = "Brightness", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },

    sample_rate: f32 = 48000.0,
    rng: u32 = 0x9E3779B9,
    clock: u32 = 0,

    const ParamHelpers = ParameterMixin(ModelPercussion, "instrument");
    const DestroyHelpers = DestroyMixin(ModelPercussion, "instrument");

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

    pub fn init(sample_rate: f32) ModelPercussion {
        return .{
            .instrument = .{
                .vtable = &vtable,
                .name = "ModelPercussion",
            },
            .sample_rate = sample_rate,
        };
    }

    /// Heap-allocate an instance; free with instrument.destroy(allocator)
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*ModelPercussion {
        const self = try allocator.create(ModelPercussion);
        self.* = init(sample_rate);
        return self;
    }

    /// Deterministic phase noise in [0, 2 pi)
    fn nextPhase(self: *ModelPercussion) f32 {
        self.rng = self.rng *% 1664525 +% 1013904223;
        const u = @as(f32, @floatFromInt(self.rng >> 8)) / 16777216.0;
        return u * 2.0 * std.math.pi;
    }

    fn process(instrument: *Instrument, buffer: []f32, sample_rate: u32) void {
        const self: *ModelPercussion = @fieldParentPtr("instrument", instrument);
        if (sample_rate > 0) self.sample_rate = @floatFromInt(sample_rate);
        const volume = self.params[0].value;
        const frames = buffer.len / 2;

        for (0..frames) |frame| {
            var sum: f32 = 0.0;
            for (&self.voices) |*v| sum += v.tick();
            sum = dsp.softClip(sum * volume);
            buffer[frame * 2] += sum;
            buffer[frame * 2 + 1] += sum;
        }
    }

    fn addMode(v: *Voice, freq: f32, decay: f32, amp: f32, sr: u32) void {
        // Keep partials below Nyquist (with margin); they would alias otherwise
        if (v.count >= MAX_PERC_MODES) return;
        if (freq <= 0.0 or freq >= 0.45 * @as(f32, @floatFromInt(sr))) return;
        v.modes[v.count] = Mode.init(freq, decay, amp, sr);
        v.count += 1;
    }

    fn voiceSetup(self: *ModelPercussion, v: *Voice, note: u8, kind: Kind, vel: f32) void {
        const sr: u32 = @intFromFloat(self.sample_rate);
        const decay_scale = self.params[1].value;
        const bright = self.params[2].value;
        v.count = 0;
        v.note = note;
        v.kind = kind;
        v.samples = 0;

        switch (kind) {
            .tom => {
                const f0 = dsp.midiNoteToFreq(note);
                // Lower toms ring longer
                const base = (0.9 - 0.012 * (f0 - 87.0)) * decay_scale;
                for (0..ModalPresets.membrane.len) |i| {
                    const amp = if (i == 0) 1.0 else AmplitudePresets.natural[i] * (0.4 + 1.2 * bright);
                    addMode(v, f0 * ModalPresets.membrane[i], @max(base, 0.1) * DecayPresets.damped[i] * 1.5, amp, sr);
                }
            },
            .crash => {
                const f0: f32 = 520.0;
                for (0..MAX_PERC_MODES) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const amp = 0.45 + 0.35 * bright - 0.012 * fi;
                    addMode(v, f0 * crash_ratios[i], (2.2 - 0.07 * fi) * decay_scale, amp, sr);
                }
            },
            .ride => {
                const f0: f32 = 640.0;
                for (0..MAX_PERC_MODES) |i| {
                    const fi: f32 = @floatFromInt(i);
                    // The bell tone (modes 1-2) stands out; the wash is quieter than a crash
                    const emphasis: f32 = if (i == 1 or i == 2) 1.0 else 0.5;
                    const amp = emphasis * (0.5 + 0.3 * bright) - 0.01 * fi;
                    addMode(v, f0 * ride_ratios[i], (2.6 - 0.09 * fi) * decay_scale, amp, sr);
                }
            },
            .metal => {
                const f0: f32 = 562.0;
                for (0..metal_ratios.len) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const amp: f32 = if (i < 2) 1.0 else (0.35 + 0.3 * bright) / (1.0 + 0.4 * fi);
                    addMode(v, f0 * metal_ratios[i], (0.45 - 0.05 * fi) * decay_scale, amp, sr);
                }
            },
            .mallet => {
                const f0 = dsp.midiNoteToFreq(note);
                for (0..ModalPresets.bar.len) |i| {
                    const fi: f32 = @floatFromInt(i);
                    // Harder mallet: more upper-mode energy
                    const amp = AmplitudePresets.natural[i] * (1.0 + (bright - 0.5) * fi * 0.6);
                    addMode(v, f0 * ModalPresets.bar[i], 1.4 * DecayPresets.natural[i] * decay_scale, @max(amp, 0.0), sr);
                }
            },
        }

        // Normalise by RMS of amplitudes so loudness is similar across kinds
        var sumsq: f32 = 0.0;
        for (v.modes[0..v.count]) |m| sumsq += m.amplitude * m.amplitude;
        const norm = if (sumsq > 0.0) 0.8 / @sqrt(sumsq) else 0.0;

        for (v.modes[0..v.count]) |*m| {
            // Cos phase gives a clean stick onset for tuned bodies; random phase
            // for metal gives the dense noisy attack.
            const phase: f32 = switch (kind) {
                .tom, .mallet => 0.0,
                .crash, .ride, .metal => self.nextPhase(),
            };
            m.exciteWithPhase(vel * norm, phase);
        }
        v.active = v.count > 0;
    }

    fn noteOn(instrument: *Instrument, note: u8, velocity: u8) void {
        const self: *ModelPercussion = @fieldParentPtr("instrument", instrument);
        const kind = Kind.fromNote(note) orelse return;
        if (velocity == 0) return;
        const vel = velocityToAmplitude(velocity);

        self.clock +%= 1;
        for (&self.voices) |*v| v.age +%= 1;

        // Retrigger the same note, else a free voice, else steal the oldest
        var target: *Voice = &self.voices[0];
        var found = false;
        for (&self.voices) |*v| {
            if (v.active and v.note == note) {
                target = v;
                found = true;
                break;
            }
        }
        if (!found) {
            for (&self.voices) |*v| {
                if (!v.active) {
                    target = v;
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            var oldest: u32 = 0;
            for (&self.voices) |*v| {
                if (v.age >= oldest) {
                    oldest = v.age;
                    target = v;
                }
            }
        }
        target.age = 0;
        for (&target.modes) |*m| m.reset();
        self.voiceSetup(target, note, kind, vel);
    }

    fn noteOff(instrument: *Instrument, note: u8) void {
        const self: *ModelPercussion = @fieldParentPtr("instrument", instrument);
        const sr: u32 = @intFromFloat(self.sample_rate);
        // Only the mallet is damped on release; drums and cymbals ring out
        for (&self.voices) |*v| {
            if (v.active and v.note == note and v.kind == .mallet) {
                for (v.modes[0..v.count]) |*m| m.setDecay(0.12, sr);
            }
        }
    }

    fn allNotesOff(instrument: *Instrument) void {
        const self: *ModelPercussion = @fieldParentPtr("instrument", instrument);
        for (&self.voices) |*v| {
            v.active = false;
            for (&v.modes) |*m| m.reset();
        }
    }

    fn reset(instrument: *Instrument) void {
        allNotesOff(instrument);
    }

    /// Number of voices currently sounding
    pub fn activeVoices(self: *const ModelPercussion) usize {
        var n: usize = 0;
        for (&self.voices) |*v| {
            if (v.active) n += 1;
        }
        return n;
    }
};

// =============================================================================
// Tests
// =============================================================================

const test_sr: u32 = 48000;

fn render(p: *ModelPercussion, out: []f32) void {
    @memset(out, 0.0);
    p.instrument.process(out, test_sr);
}

/// Hann-windowed Goertzel power of the left channel (stereo interleaved) at freq
fn powerAt(stereo: []const f32, freq: f64) f64 {
    const n = stereo.len / 2;
    const w = 2.0 * std.math.pi * freq / @as(f64, test_sr);
    const coeff = 2.0 * @cos(w);
    var s1: f64 = 0.0;
    var s2: f64 = 0.0;
    const nf: f64 = @floatFromInt(n);
    for (0..n) |i| {
        const hann = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / nf);
        const s = @as(f64, stereo[i * 2]) * hann + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

fn centsFrom(f: f64, ref: f64) f64 {
    return 1200.0 * std.math.log2(f / ref);
}

/// Find the spectral peak near ref (+-1200 cents) with a coarse then fine scan
fn peakNear(stereo: []const f32, ref: f64) f64 {
    var best_cents: f64 = 0.0;
    var best: f64 = -1.0;
    var c: f64 = -1200.0;
    while (c <= 1200.0) : (c += 2.0) {
        const p = powerAt(stereo, ref * std.math.pow(f64, 2.0, c / 1200.0));
        if (p > best) {
            best = p;
            best_cents = c;
        }
    }
    var fine_best: f64 = -1.0;
    var fine_cents = best_cents;
    var d: f64 = -3.0;
    while (d <= 3.0) : (d += 0.05) {
        const p = powerAt(stereo, ref * std.math.pow(f64, 2.0, (best_cents + d) / 1200.0));
        if (p > fine_best) {
            fine_best = p;
            fine_cents = best_cents + d;
        }
    }
    return ref * std.math.pow(f64, 2.0, fine_cents / 1200.0);
}

fn energyAbove(stereo: []const f32, lo: f64) f64 {
    var total: f64 = 0.0;
    var f = lo;
    while (f < 20000.0) : (f += 25.0) total += powerAt(stereo, f);
    return total;
}

test "note map" {
    try std.testing.expectEqual(@as(?Kind, .tom), Kind.fromNote(41));
    try std.testing.expectEqual(@as(?Kind, .crash), Kind.fromNote(49));
    try std.testing.expectEqual(@as(?Kind, .ride), Kind.fromNote(51));
    try std.testing.expectEqual(@as(?Kind, .metal), Kind.fromNote(56));
    try std.testing.expectEqual(@as(?Kind, .mallet), Kind.fromNote(60));
    try std.testing.expectEqual(@as(?Kind, .mallet), Kind.fromNote(72));
    try std.testing.expectEqual(@as(?Kind, null), Kind.fromNote(40));
    try std.testing.expectEqual(@as(?Kind, null), Kind.fromNote(73));
}

test "interface, parameters and create/destroy" {
    const p = try ModelPercussion.create(std.testing.allocator, 48000.0);
    defer p.instrument.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("ModelPercussion", p.instrument.name);
    try std.testing.expectEqual(@as(usize, 3), p.instrument.getParameterCount());
    p.instrument.setParameter(0, 5.0);
    try std.testing.expectEqual(@as(f32, 1.0), p.instrument.getParameter(0).?.value);
}

test "tom fundamental within 5 cents of its MIDI pitch" {
    const notes = [_]u8{ 41, 43, 45 };
    var buf: [test_sr * 2]f32 = undefined; // 1 s stereo
    for (notes) |note| {
        var p = ModelPercussion.init(48000.0);
        p.instrument.noteOn(note, 110);
        render(&p, &buf);
        const ref: f64 = dsp.midiNoteToFreq(note);
        const peak = peakNear(&buf, ref);
        const cents = centsFrom(peak, ref);
        std.debug.print("tom {d}: ref {d:.3} Hz peak {d:.3} Hz error {d:.3} cents\n", .{ note, ref, peak, cents });
        try std.testing.expect(@abs(cents) < 5.0);
    }
}

test "tuned mallet fundamental within 5 cents" {
    var buf: [test_sr * 2]f32 = undefined;
    for ([_]u8{ 60, 72 }) |note| {
        var p = ModelPercussion.init(48000.0);
        p.instrument.noteOn(note, 100);
        render(&p, &buf);
        const ref: f64 = dsp.midiNoteToFreq(note);
        const peak = peakNear(&buf, ref);
        const cents = centsFrom(peak, ref);
        std.debug.print("mallet {d}: error {d:.3} cents\n", .{ note, cents });
        try std.testing.expect(@abs(cents) < 5.0);
    }
}

test "crash has more energy above 5 kHz than the tom" {
    var buf: [test_sr]f32 = undefined; // 0.5 s stereo
    var crash = ModelPercussion.init(48000.0);
    crash.instrument.noteOn(49, 110);
    render(&crash, &buf);
    const crash_hi = energyAbove(&buf, 5000.0);

    for ([_]u8{ 41, 43, 45 }) |note| {
        var tom = ModelPercussion.init(48000.0);
        tom.instrument.noteOn(note, 110);
        render(&tom, &buf);
        const tom_hi = energyAbove(&buf, 5000.0);
        std.debug.print("hf energy crash {e:.3} tom{d} {e:.3}\n", .{ crash_hi, note, tom_hi });
        try std.testing.expect(crash_hi > tom_hi);
    }
}

test "output stays finite and below 1.5 peak" {
    var p = ModelPercussion.init(48000.0);
    const notes = [_]u8{ 41, 43, 45, 49, 51, 56, 60, 64, 67, 72 };
    var buf: [test_sr * 2]f32 = undefined;
    @memset(&buf, 0.0);
    var peak: f32 = 0.0;

    // Hammer every voice repeatedly at full velocity, including voice stealing
    for (0..4) |round| {
        for (notes) |n| p.instrument.noteOn(n, 127);
        for ([_]u8{ 42, 44, 46, 48, 50, 52, 61, 62, 63, 65 }) |n| p.instrument.noteOn(n, 127);
        p.instrument.setParameter(2, if (round % 2 == 0) 1.0 else 0.0);
        p.instrument.setParameter(0, 1.0);
        render(&p, &buf);
        for (buf) |s| {
            try std.testing.expect(std.math.isFinite(s));
            peak = @max(peak, @abs(s));
        }
    }
    std.debug.print("max peak {d:.4}\n", .{peak});
    try std.testing.expect(peak < 1.5);
    try std.testing.expect(peak > 0.1);
}

test "voices fall silent and allNotesOff clears" {
    var p = ModelPercussion.init(48000.0);
    p.instrument.noteOn(56, 100); // short metal
    try std.testing.expectEqual(@as(usize, 1), p.activeVoices());
    var buf: [test_sr * 2]f32 = undefined;
    for (0..4) |_| render(&p, &buf);
    try std.testing.expectEqual(@as(usize, 0), p.activeVoices());

    p.instrument.noteOn(49, 100);
    p.instrument.noteOn(45, 100);
    p.instrument.allNotesOff();
    try std.testing.expectEqual(@as(usize, 0), p.activeVoices());
}

test "unmapped notes are ignored and mallet noteOff damps" {
    var p = ModelPercussion.init(48000.0);
    p.instrument.noteOn(10, 100);
    try std.testing.expectEqual(@as(usize, 0), p.activeVoices());
    p.instrument.noteOn(60, 100);
    p.instrument.noteOff(60);
    var buf: [test_sr * 2]f32 = undefined;
    for (0..2) |_| render(&p, &buf);
    try std.testing.expectEqual(@as(usize, 0), p.activeVoices());
}

test "MIDI 41 is audible within 0.3 s at default settings, even at moderate velocity" {
    // Velocity maps through a quadratic curve, so 40 is quiet but must still clear 0.05.
    for ([_]u8{ 40, 100 }) |vel| {
        var p = ModelPercussion.init(@floatFromInt(test_sr));
        p.instrument.noteOn(41, vel);
        var out: [2 * 14400]f32 = undefined; // 0.3 s at 48 kHz
        render(&p, &out);
        var peak: f32 = 0.0;
        for (out) |s| peak = @max(peak, @abs(s));
        try std.testing.expect(peak > 0.05);
    }
}
