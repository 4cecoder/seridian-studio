//! Vocal effects: PitchPure stages (libs/vocal) behind the engine's Effect interface.
//!
//! PitchPure stages are mono and fixed to one sample rate for their lifetime.
//! `VocalEffect` runs one stage instance per channel of the engine's
//! interleaved stereo buffer, through preallocated scratch, so `process`
//! never allocates. Stages are built at the chain's sample rate. When the
//! engine changes rate it calls `rebuild` while no audio callback runs; until
//! then a rate mismatch passes audio through untouched.

const std = @import("std");
const vocal = @import("vocal");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

/// Frames processed per inner chunk; larger engine blocks are split.
pub const CHUNK_FRAMES = 1024;
const CHANNELS = 2;

/// Static description of one vocal effect.
fn Spec(comptime Stage: type, comptime param_count: usize) type {
    return struct {
        name: []const u8,
        params: [param_count]Parameter,
        create: *const fn (gpa: std.mem.Allocator, rate: u32) anyerror!Stage,
        destroy: *const fn (stage: *Stage, gpa: std.mem.Allocator) void,
        /// Push parameter values into a stage (control or audio thread; must not allocate).
        apply: *const fn (stage: *Stage, params: []const Parameter) void,
    };
}

/// Build an Effect type around a mono vocal stage.
pub fn VocalEffect(comptime Stage: type, comptime param_count: usize, comptime spec: Spec(Stage, param_count)) type {
    vocal.types.assertProcessor(Stage);
    return struct {
        const Self = @This();

        effect: Effect,
        allocator: std.mem.Allocator,
        rate: u32,
        stages: [CHANNELS]Stage,
        params: [param_count]Parameter = spec.params,
        dirty: bool = true,
        scratch_in: [CHUNK_FRAMES]f32 = undefined,
        scratch_out: [CHUNK_FRAMES]f32 = undefined,

        const vtable = Effect.VTable{
            .process = process,
            .reset = reset,
            .getParameterCount = getParameterCount,
            .getParameter = getParameter,
            .setParameter = setParameter,
            .latency = latencyOf,
        };

        /// Initialise in place (the struct is large; it lives on the heap).
        pub fn init(self: *Self, allocator: std.mem.Allocator, rate: u32) !void {
            self.* = .{
                .effect = .{ .vtable = &vtable, .name = spec.name },
                .allocator = allocator,
                .rate = rate,
                .stages = undefined,
            };
            var built: usize = 0;
            errdefer for (self.stages[0..built]) |*s| spec.destroy(s, allocator);
            for (&self.stages) |*s| {
                s.* = try spec.create(allocator, rate);
                built += 1;
            }
            self.applyParams();
        }

        pub fn deinit(self: *Self) void {
            for (&self.stages) |*s| spec.destroy(s, self.allocator);
        }

        /// Rebuild the stages for a new sample rate, keeping parameter values.
        /// Control thread only, with the audio callback stopped. The new stages
        /// are built before the old ones are freed, so on error nothing changes.
        pub fn rebuild(self: *Self, rate: u32) !void {
            if (rate == self.rate) return;
            var fresh: [CHANNELS]Stage = undefined;
            var built: usize = 0;
            errdefer for (fresh[0..built]) |*s| spec.destroy(s, self.allocator);
            for (&fresh) |*s| {
                s.* = try spec.create(self.allocator, rate);
                built += 1;
            }
            for (&self.stages) |*s| spec.destroy(s, self.allocator);
            self.stages = fresh;
            self.rate = rate;
            self.applyParams();
        }

        fn applyParams(self: *Self) void {
            for (&self.stages) |*s| spec.apply(s, &self.params);
            self.dirty = false;
        }

        fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
            const self: *Self = @fieldParentPtr("effect", effect);
            if (sample_rate != self.rate) return;
            if (self.dirty) self.applyParams();

            const frames = buffer.len / CHANNELS;
            var start: usize = 0;
            while (start < frames) {
                const n = @min(CHUNK_FRAMES, frames - start);
                for (&self.stages, 0..) |*stage, ch| {
                    for (0..n) |i| self.scratch_in[i] = buffer[(start + i) * CHANNELS + ch];
                    stage.process(self.scratch_in[0..n], self.scratch_out[0..n]);
                    for (0..n) |i| buffer[(start + i) * CHANNELS + ch] = self.scratch_out[i];
                }
                start += n;
            }
        }

        fn reset(effect: *Effect) void {
            const self: *Self = @fieldParentPtr("effect", effect);
            for (&self.stages) |*s| s.reset();
        }

        fn getParameterCount(effect: *const Effect) usize {
            _ = effect;
            return param_count;
        }

        fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
            const self: *const Self = @fieldParentPtr("effect", effect);
            if (index >= param_count) return null;
            return &self.params[index];
        }

        fn setParameter(effect: *Effect, index: usize, value: f32) void {
            const self: *Self = @fieldParentPtr("effect", effect);
            if (index >= param_count) return;
            const p = &self.params[index];
            p.value = std.math.clamp(value, p.min, p.max);
            self.dirty = true;
        }

        /// Algorithmic delay in samples (for plugin delay compensation).
        pub fn latencySamples(self: *const Self) usize {
            return vocal.types.latencySamples(&self.stages[0]);
        }

        fn latencyOf(effect: *const Effect) usize {
            const self: *const Self = @fieldParentPtr("effect", effect);
            return self.latencySamples();
        }
    };
}

// --- De-esser ---------------------------------------------------------------

fn deesserCreate(_: std.mem.Allocator, rate: u32) anyerror!vocal.deesser.VocalDeEsser {
    return vocal.deesser.VocalDeEsser.init(rate);
}
fn deesserDestroy(_: *vocal.deesser.VocalDeEsser, _: std.mem.Allocator) void {}
fn deesserApply(s: *vocal.deesser.VocalDeEsser, p: []const Parameter) void {
    s.setFrequencyHz(p[0].value);
    s.setThresholdDb(p[1].value);
    s.setRangeDb(p[2].value);
}

pub const DeEsserEffect = VocalEffect(vocal.deesser.VocalDeEsser, 3, .{
    .name = "De-esser",
    .params = .{
        .{ .name = "Frequency", .min = 2000.0, .max = 12000.0, .default = 6500.0, .value = 6500.0, .unit = "Hz" },
        .{ .name = "Threshold", .min = -60.0, .max = 0.0, .default = -30.0, .value = -30.0, .unit = "dB" },
        .{ .name = "Range", .min = 0.0, .max = 24.0, .default = 8.0, .value = 8.0, .unit = "dB" },
    },
    .create = deesserCreate,
    .destroy = deesserDestroy,
    .apply = deesserApply,
});

// --- Vocal rider --------------------------------------------------------------

fn riderCreate(_: std.mem.Allocator, rate: u32) anyerror!vocal.rider.VocalRider {
    return vocal.rider.VocalRider.init(rate);
}
fn riderDestroy(_: *vocal.rider.VocalRider, _: std.mem.Allocator) void {}
fn riderApply(s: *vocal.rider.VocalRider, p: []const Parameter) void {
    s.setTargetDb(p[0].value);
    s.setRangeDb(p[1].value);
    s.setSpeed(p[2].value);
}

pub const RiderEffect = VocalEffect(vocal.rider.VocalRider, 3, .{
    .name = "Vocal Rider",
    .params = .{
        .{ .name = "Target", .min = -30.0, .max = -6.0, .default = -18.0, .value = -18.0, .unit = "dB" },
        .{ .name = "Range", .min = 0.0, .max = 12.0, .default = 6.0, .value = 6.0, .unit = "dB" },
        .{ .name = "Speed", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },
    .create = riderCreate,
    .destroy = riderDestroy,
    .apply = riderApply,
});

// --- Spectral denoise -------------------------------------------------------

fn denoiseCreate(gpa: std.mem.Allocator, rate: u32) anyerror!vocal.denoise.SpectralDenoiser {
    return vocal.denoise.SpectralDenoiser.init(gpa, rate);
}
fn denoiseDestroy(s: *vocal.denoise.SpectralDenoiser, gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
fn denoiseApply(s: *vocal.denoise.SpectralDenoiser, p: []const Parameter) void {
    s.setReductionDb(p[0].value);
    s.setSensitivity(p[1].value);
}

pub const DenoiseEffect = VocalEffect(vocal.denoise.SpectralDenoiser, 2, .{
    .name = "Denoise",
    .params = .{
        .{ .name = "Reduction", .min = 0.0, .max = 40.0, .default = 12.0, .value = 12.0, .unit = "dB" },
        .{ .name = "Sensitivity", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },
    .create = denoiseCreate,
    .destroy = denoiseDestroy,
    .apply = denoiseApply,
});

// --- Tape saturation --------------------------------------------------------

fn tapeCreate(gpa: std.mem.Allocator, rate: u32) anyerror!vocal.tape.TapeSaturator {
    return vocal.tape.TapeSaturator.init(gpa, rate);
}
fn tapeDestroy(s: *vocal.tape.TapeSaturator, gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
fn tapeApply(s: *vocal.tape.TapeSaturator, p: []const Parameter) void {
    s.setDrive(p[0].value);
    s.setWow(p[1].value);
    s.setMix(p[2].value);
}

pub const TapeEffect = VocalEffect(vocal.tape.TapeSaturator, 3, .{
    .name = "Tape",
    .params = .{
        .{ .name = "Drive", .min = 0.0, .max = 1.0, .default = 0.3, .value = 0.3, .unit = "" },
        .{ .name = "Wow", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Mix", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
    },
    .create = tapeCreate,
    .destroy = tapeDestroy,
    .apply = tapeApply,
});

// --- Vocal tune (pitch correction + formant) --------------------------------

/// Corrector plus formant shifter as one Processor. The corrector takes its
/// parameters on every call, so the stage holds them.
/// Matches the unity check in libs/vocal/src/formant.zig.
const formant_unity_eps: f32 = 1e-6;

pub const TuneStage = struct {
    corrector: vocal.corrector.Corrector,
    formant: vocal.formant.FormantShifter,
    params: vocal.params.FullParams,
    /// Corrector output, formant input. Sized for one wrapper chunk.
    mid: [CHUNK_FRAMES]f32 = undefined,

    pub fn init(gpa: std.mem.Allocator, rate: u32) !TuneStage {
        const params: vocal.params.FullParams = .{};
        var corrector = try vocal.corrector.Corrector.init(gpa, rate, params);
        errdefer corrector.deinit(gpa);
        const formant = try vocal.formant.FormantShifter.init(gpa, rate);
        return .{ .corrector = corrector, .formant = formant, .params = params };
    }

    pub fn deinit(self: *TuneStage, gpa: std.mem.Allocator) void {
        self.formant.deinit(gpa);
        self.corrector.deinit(gpa);
    }

    pub fn reset(self: *TuneStage) void {
        self.corrector.reset();
        self.formant.reset();
    }

    /// `input.len` must be <= CHUNK_FRAMES and equal `output.len` (the wrapper guarantees both).
    pub fn process(self: *TuneStage, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len, CHUNK_FRAMES);
        self.corrector.process(input[0..n], self.mid[0..n], &self.params);
        self.formant.process(self.mid[0..n], output[0..n]);
    }

    /// The formant shifter passes audio through undelayed at unity ratio, so it
    /// only adds its latency while it is actually shifting.
    pub fn latencySamples(self: *const TuneStage) usize {
        const formant_active = @abs(self.formant.ratio - 1.0) > formant_unity_eps;
        const formant_latency = if (formant_active) vocal.types.latencySamples(&self.formant) else 0;
        return self.corrector.latencySamples() + formant_latency;
    }
};

fn tuneCreate(gpa: std.mem.Allocator, rate: u32) anyerror!TuneStage {
    return TuneStage.init(gpa, rate);
}
fn tuneDestroy(s: *TuneStage, gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
fn tuneApply(s: *TuneStage, p: []const Parameter) void {
    const hp = vocal.host_params;
    // Parameter indices 0..5 follow the host_params ids (retune, key, scale,
    // humanize, transpose, mix); every id is known, so `set` cannot fail.
    for (p[0..hp.all.len], 0..) |param, id| _ = hp.set(&s.params, @intCast(id), param.value);
    s.params.formant_cents = p[6].value;
    s.params.clampAll();
    s.formant.setShiftCents(s.params.formant_cents);
}

pub const TuneEffect = VocalEffect(TuneStage, 7, .{
    .name = "Vocal Tune",
    .params = .{
        .{ .name = "Retune", .min = 0.0, .max = 1000.0, .default = 40.0, .value = 40.0, .unit = "ms" },
        .{ .name = "Key", .min = 0.0, .max = 11.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Scale", .min = 0.0, .max = 8.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Humanize", .min = 0.0, .max = 100.0, .default = 0.0, .value = 0.0, .unit = "%" },
        .{ .name = "Transpose", .min = -12.0, .max = 12.0, .default = 0.0, .value = 0.0, .unit = "st" },
        .{ .name = "Mix", .min = 0.0, .max = 100.0, .default = 100.0, .value = 100.0, .unit = "%" },
        .{ .name = "Formant", .min = -1200.0, .max = 1200.0, .default = 0.0, .value = 0.0, .unit = "ct" },
    },
    .create = tuneCreate,
    .destroy = tuneDestroy,
    .apply = tuneApply,
});

// --- Vocal strip (the full PitchPure chain) ----------------------------------

const suite = vocal.suite;

/// Frames the Vocal Strip hands its chain per call, whatever the host block size.
pub const STRIP_BLOCK_FRAMES = 1024;

/// PitchPure's whole vocal chain as one Processor: isolate, tune, formant,
/// harmony, EQ, de-ess, rider, compressor, tape, delay, reverb and limiter.
///
/// The chain's output (harmony above all) depends on the size of the blocks it
/// is given, so the stage re-blocks: input collects in a FIFO and the chain
/// always runs on exactly `STRIP_BLOCK_FRAMES` frames. That adds a fixed
/// `STRIP_BLOCK_FRAMES` of delay on top of the chain's own latency (about
/// 70 ms); both are reported for delay compensation. Output is then identical
/// for any host block size, offline or live.
pub const StripStage = struct {
    chain: suite.VocalChain,
    settings: suite.Settings,
    /// Input waiting for the next chain block (the chain also applies input gain here in place).
    pending: [STRIP_BLOCK_FRAMES]f32 = @splat(0.0),
    /// Output of the last chain block, handed out one frame per input frame.
    ready: [STRIP_BLOCK_FRAMES]f32 = @splat(0.0),
    /// Frames collected in `pending` (and already handed out of `ready`).
    fill: usize = 0,

    comptime {
        std.debug.assert(STRIP_BLOCK_FRAMES <= suite.BLOCK);
    }

    pub fn init(gpa: std.mem.Allocator, rate: u32) !StripStage {
        const settings: suite.Settings = .{};
        var chain = try suite.VocalChain.init(gpa, rate, &settings);
        chain.configure(&settings);
        return .{ .chain = chain, .settings = settings };
    }

    pub fn deinit(self: *StripStage, gpa: std.mem.Allocator) void {
        self.chain.deinit(gpa);
    }

    pub fn reset(self: *StripStage) void {
        self.chain.reset();
        self.pending = @splat(0.0);
        self.ready = @splat(0.0);
        self.fill = 0;
    }

    /// Any length; `output.len` must equal `input.len` (the wrapper guarantees it). Each output
    /// frame is the chain's output for the input `STRIP_BLOCK_FRAMES` frames earlier.
    pub fn process(self: *StripStage, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        var done: usize = 0;
        while (done < n) {
            const take = @min(n - done, STRIP_BLOCK_FRAMES - self.fill);
            @memcpy(output[done..][0..take], self.ready[self.fill..][0..take]);
            @memcpy(self.pending[self.fill..][0..take], input[done..][0..take]);
            self.fill += take;
            done += take;
            if (self.fill == STRIP_BLOCK_FRAMES) {
                self.runChain();
                self.fill = 0;
            }
        }
    }

    /// One fixed-size chain block from `pending` into `ready`.
    fn runChain(self: *StripStage) void {
        _ = self.chain.process(&self.pending, &self.ready, &self.settings) catch {
            // Unreachable for a STRIP_BLOCK_FRAMES block; never leave the output undefined.
            @memcpy(&self.ready, &self.pending);
        };
    }

    pub fn latencySamples(self: *const StripStage) usize {
        return self.chain.latencySamples() + STRIP_BLOCK_FRAMES;
    }
};

fn stripCreate(gpa: std.mem.Allocator, rate: u32) anyerror!StripStage {
    return StripStage.init(gpa, rate);
}
fn stripDestroy(s: *StripStage, gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
fn stripApply(s: *StripStage, p: []const Parameter) void {
    const cfg = &s.settings;
    cfg.root_note = suite.DEFAULT_ROOT_MIDI + @as(u8, @intFromFloat(@round(p[0].value)));
    cfg.scale = suite.ScalePreset.NAMED[@intFromFloat(@round(p[1].value))];
    cfg.retune_ms = p[2].value;
    cfg.mix = p[3].value / 100.0;
    const harmony: usize = @intFromFloat(@round(p[4].value));
    cfg.harmony_on = harmony > 0;
    if (harmony > 0) cfg.harmony_mode = suite.HarmonyMode.ALL[harmony - 1];
    cfg.deess_on = p[5].value >= 0.5;
    cfg.comp_on = p[6].value >= 0.5;
    cfg.reverb_mix = p[7].value;
    cfg.output_gain_db = p[8].value;
    s.chain.configure(cfg);
}

pub const StripEffect = VocalEffect(StripStage, 9, .{
    .name = "Vocal Strip",
    .params = .{
        .{ .name = "Key", .min = 0.0, .max = 11.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Scale", .min = 0.0, .max = 8.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Retune", .min = 0.0, .max = 1000.0, .default = 40.0, .value = 40.0, .unit = "ms" },
        .{ .name = "Mix", .min = 0.0, .max = 100.0, .default = 100.0, .value = 100.0, .unit = "%" },
        .{ .name = "Harmony", .min = 0.0, .max = 5.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "De-ess", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Compressor", .min = 0.0, .max = 1.0, .default = 0.0, .value = 0.0, .unit = "" },
        .{ .name = "Reverb", .min = 0.0, .max = 1.0, .default = 0.15, .value = 0.15, .unit = "" },
        .{ .name = "Output", .min = -24.0, .max = 12.0, .default = 0.0, .value = 0.0, .unit = "dB" },
    },
    .create = stripCreate,
    .destroy = stripDestroy,
    .apply = stripApply,
});

// =============================================================================
// Tests
// =============================================================================

fn sineStereo(buf: []f32, hz: f32, rate: f32, amp: f32) void {
    const frames = buf.len / CHANNELS;
    for (0..frames) |i| {
        const v = amp * @sin(2.0 * std.math.pi * hz * @as(f32, @floatFromInt(i)) / rate);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
}

fn expectFinite(buf: []const f32) !void {
    for (buf) |s| try std.testing.expect(std.math.isFinite(s));
}

test "vocal effects: every wrapper processes stereo blocks and stays finite" {
    const gpa = std.testing.allocator;
    inline for (.{ DeEsserEffect, RiderEffect, DenoiseEffect, TapeEffect, TuneEffect, StripEffect }) |T| {
        const fx = try gpa.create(T);
        defer gpa.destroy(fx);
        try fx.init(gpa, 48000);
        defer fx.deinit();

        // Larger than CHUNK_FRAMES to exercise chunking.
        var buf: [3000 * 2]f32 = undefined;
        sineStereo(&buf, 220.0, 48000.0, 0.5);
        for (0..4) |_| fx.effect.process(&buf, 48000);
        try expectFinite(&buf);

        // Parameter round trip with clamping.
        const count = fx.effect.getParameterCount();
        try std.testing.expect(count > 0);
        fx.effect.setParameter(0, 1e9);
        try std.testing.expectEqual(fx.effect.getParameter(0).?.max, fx.effect.getParameter(0).?.value);
        try std.testing.expect(fx.effect.getParameter(count) == null);
        fx.effect.reset();
    }
}

test "vocal effects: wrong sample rate passes audio through untouched" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(TapeEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();

    var buf: [256 * 2]f32 = undefined;
    sineStereo(&buf, 440.0, 44100.0, 0.5);
    const before = buf;
    fx.effect.process(&buf, 44100);
    try std.testing.expectEqualSlices(f32, &before, &buf);
}

test "vocal effects: channels are processed independently" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(DeEsserEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();

    // Left silent, right loud: silence must stay silence.
    var buf: [512 * 2]f32 = undefined;
    for (0..512) |i| {
        buf[i * 2] = 0.0;
        buf[i * 2 + 1] = 0.5 * @sin(2.0 * std.math.pi * 7000.0 * @as(f32, @floatFromInt(i)) / 48000.0);
    }
    fx.effect.process(&buf, 48000);
    for (0..512) |i| try std.testing.expectEqual(@as(f32, 0.0), buf[i * 2]);
}

test "vocal tune: a flat note is pulled onto the scale" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(TuneEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();
    fx.effect.setParameter(0, 0.0); // fastest retune

    // A4 pulled 40 cents flat; chromatic correction should land near 440 Hz.
    const rate: f32 = 48000.0;
    const hz: f32 = 440.0 * std.math.pow(f32, 2.0, -40.0 / 1200.0);
    const frames = 48000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / rate;
        const v = 0.4 * @sin(2.0 * std.math.pi * hz * t) + 0.2 * @sin(4.0 * std.math.pi * hz * t);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    var off: usize = 0;
    while (off < frames) : (off += 512) {
        const n = @min(512, frames - off);
        fx.effect.process(buf[off * 2 .. (off + n) * 2], 48000);
    }
    try expectFinite(buf);
    const ratio = fx.stages[0].corrector.lastRatio();
    // 40 cents up is a ratio of about 1.0234.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0234), ratio, 0.006);
}

test "vocal effects: rebuild moves to a new rate and keeps parameters" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(TapeEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();
    fx.effect.setParameter(0, 0.9);

    try fx.rebuild(44100);
    try std.testing.expectEqual(@as(u32, 44100), fx.rate);
    try std.testing.expectEqual(@as(f32, 0.9), fx.effect.getParameter(0).?.value);
    try std.testing.expectEqual(@as(f32, 0.9), fx.stages[0].getDrive());

    // Now processes at 44.1 kHz instead of passing through.
    var buf: [256 * 2]f32 = undefined;
    sineStereo(&buf, 440.0, 44100.0, 0.8);
    const before = buf;
    fx.effect.process(&buf, 44100);
    try std.testing.expect(!std.mem.eql(f32, &before, &buf));
}

test "vocal tune: formant latency only counts while shifting" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(TuneEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();

    var buf: [64 * 2]f32 = @splat(0.0);
    fx.effect.process(&buf, 48000);
    const base = fx.effect.latencySamples();
    try std.testing.expectEqual(fx.stages[0].corrector.latencySamples(), base);

    fx.effect.setParameter(6, 200.0); // formant +200 cents
    fx.effect.process(&buf, 48000); // applies the parameter
    try std.testing.expectEqual(base + vocal.types.latencySamples(&fx.stages[0].formant), fx.effect.latencySamples());
}

/// Runs a voiced, gliding tone through a fresh Vocal Strip with harmony on, in host blocks of
/// `block` frames. Returns the interleaved output (caller frees).
fn renderStrip(gpa: std.mem.Allocator, block: usize, frames: usize) ![]f32 {
    const fx = try gpa.create(StripEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();
    fx.effect.setParameter(4, 2.0); // harmony on
    fx.effect.setParameter(6, 1.0); // compressor on

    const buf = try gpa.alloc(f32, frames * 2);
    errdefer gpa.free(buf);
    var phase: f32 = 0.0;
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        phase += 2.0 * std.math.pi * (196.0 + 40.0 * t) / 48000.0;
        const v = 0.3 * @sin(phase) + 0.12 * @sin(2.0 * phase) + 0.05 * @sin(3.0 * phase);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    var off: usize = 0;
    while (off < frames) : (off += block) {
        const n = @min(block, frames - off);
        fx.effect.process(buf[off * 2 .. (off + n) * 2], 48000);
    }
    return buf;
}

test "vocal strip: output is bit-identical whatever the host block size" {
    const gpa = std.testing.allocator;
    const frames = 24000;
    const reference = try renderStrip(gpa, 1024, frames);
    defer gpa.free(reference);
    try expectFinite(reference);
    for ([_]usize{ 64, 128, 512, 1000 }) |block| {
        const rendered = try renderStrip(gpa, block, frames);
        defer gpa.free(rendered);
        try std.testing.expectEqualSlices(f32, reference, rendered);
    }
}

test "vocal strip: reports the chain latency and keeps a voiced signal alive" {
    const gpa = std.testing.allocator;
    const fx = try gpa.create(StripEffect);
    defer gpa.destroy(fx);
    try fx.init(gpa, 48000);
    defer fx.deinit();

    const latency = fx.effect.latencySamples();
    // The chain's own latency plus the fixed re-blocking delay.
    try std.testing.expectEqual(fx.stages[0].chain.latencySamples() + STRIP_BLOCK_FRAMES, latency);
    try std.testing.expect(latency > 1000);

    // Half a second of a voiced tone: after the latency the strip must output sound.
    const frames = 24000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        const v = 0.3 * @sin(2.0 * std.math.pi * 220.0 * t) + 0.1 * @sin(4.0 * std.math.pi * 220.0 * t);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    var off: usize = 0;
    while (off < frames) : (off += 512) {
        const n = @min(512, frames - off);
        fx.effect.process(buf[off * 2 .. (off + n) * 2], 48000);
    }
    try expectFinite(buf);
    var tail_peak: f32 = 0.0;
    for (buf[(latency + 2048) * 2 ..]) |s| tail_peak = @max(tail_peak, @abs(s));
    try std.testing.expect(tail_peak > 0.05);

    // Every switch combination applies without trouble.
    fx.effect.setParameter(4, 2.0); // harmony: third below
    fx.effect.setParameter(5, 1.0);
    fx.effect.setParameter(6, 1.0);
    fx.effect.process(buf[0..1024], 48000);
    try expectFinite(buf[0..1024]);
}
