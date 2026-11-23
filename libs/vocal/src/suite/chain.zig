// Translated to Zig from pitchpure/crates/pitchpure_suite/src/chain.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! The vocal chain shared by the live engine, the recorder and dropped
//! files: Isolate -> Tune -> Formant -> Harmony -> EQ -> De-ess -> Rider ->
//! Compressor -> Tape -> Delay -> Reverb -> mix/level -> Limiter.
//!
//! One `VocalChain` processes mono blocks with settings read from a
//! `Settings` snapshot, so a file rendered offline sounds exactly like the
//! live monitor with the same controls.
//!
//! Ownership: `init` allocates every stage and scratch buffer; `deinit`
//! frees them. `configure` and `process` never allocate, lock, log or do
//! I/O, so both may run on the audio thread.
//!
//! Seridian changes versus the Rust:
//! - The Rust chain only works with blocks of exactly `BLOCK` samples (it
//!   panics otherwise). `process` accepts any block of `1..=BLOCK` samples
//!   (identical output for `BLOCK`-sized blocks) and returns
//!   `error.LengthMismatch` / `error.BlockTooLarge` instead of panicking.
//!   Every stage is block-size agnostic except HARMONY, whose interval and
//!   shift ratio are control-rate values updated once per `process` call
//!   (as in the Rust): with harmony on, output depends on the block size,
//!   so use `BLOCK`-sized blocks where a render must match the live sound.
//! - The Rust `VecDeque` dry line becomes a fixed ring of exactly the wet
//!   path's delay (same FIFO output, no allocation after `init`).

const std = @import("std");
const suite = @import("../suite.zig");
const settings = @import("settings.zig");
const Settings = settings.Settings;
const Corrector = @import("../corrector.zig").Corrector;
const FormantShifter = @import("../formant.zig").FormantShifter;
const SpectralDenoiser = @import("../denoise.zig").SpectralDenoiser;
const SolaShifter = @import("../shifter_sola.zig").SolaShifter;
const voice_eq = @import("../voice_eq.zig");
const VoiceEq = voice_eq.VoiceEq;
const Band = voice_eq.Band;
const parametric_eq = @import("../parametric_eq.zig");
const ParametricEq = parametric_eq.ParametricEq;
const BAND_COUNT = parametric_eq.BAND_COUNT;
const VocalDeEsser = @import("../deesser.zig").VocalDeEsser;
const VocalRider = @import("../rider.zig").VocalRider;
const VocalCompressor = @import("../compressor.zig").VocalCompressor;
const TapeSaturator = @import("../tape.zig").TapeSaturator;
const DuckingDelay = @import("../delay.zig").DuckingDelay;
const VocalReverb = @import("../reverb.zig").VocalReverb;
const VocalLimiter = @import("../limiter.zig").VocalLimiter;

const BLOCK = suite.BLOCK;

/// Harmony shifter grain floor / crossfade (same geometry as the tuner's,
/// so harmony and lead share one latency and stay sample-aligned).
const HARMONY_FRAME: usize = 1024;
const HARMONY_XFADE: usize = 256;

pub const ProcessError = error{
    /// `input.len != out.len`, or an empty block.
    LengthMismatch,
    /// The block is longer than `BLOCK` samples.
    BlockTooLarge,
};

/// What one block did, for meters and the pitch graph.
pub const BlockReport = struct {
    /// Peak of the (gained) input.
    in_peak: f32 = 0.0,
    /// Peak of the processed output, before monitor muting.
    out_peak: f32 = 0.0,
    /// Detected input pitch in Hz (`0` = unvoiced).
    detected_hz: f32 = 0.0,
    /// Pitch ratio the tuner applied.
    ratio: f32 = 0.0,
    harmony_notes: [2]?i32 = @splat(null),
    rider_gain_db: f32 = 0.0,
    limiter_gr_db: f32 = 0.0,
    comp_gr_db: f32 = 0.0,
    comp_in_db: f32 = 0.0,
    deess_gr_db: f32 = 0.0,
    deess_level_db: f32 = 0.0,
};

pub const VocalChain = struct {
    tune: Corrector,
    formant: FormantShifter,
    denoiser: SpectralDenoiser,
    harmony: [2]SolaShifter,
    harmony_semitones: [2]i32,
    voice_eq: VoiceEq,
    parametric_eq: ParametricEq,
    deesser: VocalDeEsser,
    rider: VocalRider,
    compressor: VocalCompressor,
    tape: TapeSaturator,
    delay: DuckingDelay,
    reverb: VocalReverb,
    limiter: VocalLimiter,
    /// Dry input delayed to line up with the wet path, so MIX < 100% and
    /// BYPASS blend/switch without a slapback echo or a timing jump.
    /// A ring of exactly `wetDelay()` samples (Rust: a `VecDeque`).
    dry_line: []f32,
    dry_pos: usize,
    dry: []f32,
    clean: []f32,
    scratch: []f32,
    voice: []f32,
    eq_analyzer: []f32,

    /// Build every stage for `rate` Hz. Like the Rust `new`, this does not
    /// apply the stage settings: call `configure` before processing.
    pub fn init(gpa: std.mem.Allocator, rate: u32, cfg: *const Settings) !VocalChain {
        // Engine corrector: detects every ~10 ms on its own hop (brain
        // clocked at that decision rate) and shifts continuously, so
        // there is no block-rate buzz and ~26 ms of honest latency.
        var tune = try Corrector.init(gpa, rate, settings.makeParams(cfg.retune_ms, cfg.scale.mask(), cfg.root_note));
        errdefer tune.deinit(gpa);
        var formant = try FormantShifter.init(gpa, rate);
        errdefer formant.deinit(gpa);
        // Always runs (0 dB = delayed passthrough) so switching it
        // never shifts timing mid-take.
        var denoiser = try SpectralDenoiser.init(gpa, rate);
        errdefer denoiser.deinit(gpa);
        var harmony0 = try SolaShifter.init(gpa, rate, HARMONY_FRAME, HARMONY_XFADE);
        errdefer harmony0.deinit(gpa);
        var harmony1 = try SolaShifter.init(gpa, rate, HARMONY_FRAME, HARMONY_XFADE);
        errdefer harmony1.deinit(gpa);
        var tape = try TapeSaturator.init(gpa, rate);
        errdefer tape.deinit(gpa);
        var delay = try DuckingDelay.init(gpa, rate);
        errdefer delay.deinit(gpa);
        var reverb = try VocalReverb.init(gpa, rate);
        errdefer reverb.deinit(gpa);
        // Always runs (constant lookahead); "off" only raises the
        // ceiling to a 0 dBFS safety clip.
        var limiter = try VocalLimiter.init(gpa, rate);
        errdefer limiter.deinit(gpa);

        const wet_delay = denoiser.latencySamples() + tune.latencySamples();
        // Seridian: preallocated ring, Rust grew a VecDeque.
        const dry_line = try gpa.alloc(f32, wet_delay);
        errdefer gpa.free(dry_line);
        @memset(dry_line, 0.0);

        var bufs: [5][]f32 = undefined;
        var made: usize = 0;
        errdefer for (bufs[0..made]) |b| gpa.free(b);
        while (made < bufs.len) : (made += 1) {
            bufs[made] = try gpa.alloc(f32, BLOCK);
            @memset(bufs[made], 0.0);
        }

        return .{
            .tune = tune,
            .formant = formant,
            .denoiser = denoiser,
            .harmony = .{ harmony0, harmony1 },
            .harmony_semitones = @splat(0),
            .voice_eq = VoiceEq.init(rate),
            .parametric_eq = ParametricEq.init(rate),
            .deesser = VocalDeEsser.init(rate),
            .rider = VocalRider.init(rate),
            .compressor = VocalCompressor.init(rate),
            .tape = tape,
            .delay = delay,
            .reverb = reverb,
            .limiter = limiter,
            .dry_line = dry_line,
            .dry_pos = 0,
            .dry = bufs[0],
            .clean = bufs[1],
            .scratch = bufs[2],
            .voice = bufs[3],
            .eq_analyzer = bufs[4],
        };
    }

    pub fn deinit(self: *VocalChain, gpa: std.mem.Allocator) void {
        self.tune.deinit(gpa);
        self.formant.deinit(gpa);
        self.denoiser.deinit(gpa);
        for (&self.harmony) |*h| h.deinit(gpa);
        self.tape.deinit(gpa);
        self.delay.deinit(gpa);
        self.reverb.deinit(gpa);
        self.limiter.deinit(gpa);
        gpa.free(self.dry_line);
        gpa.free(self.dry);
        gpa.free(self.clean);
        gpa.free(self.scratch);
        gpa.free(self.voice);
        gpa.free(self.eq_analyzer);
        self.* = undefined;
    }

    /// Delay of the wet path before the limiter: denoiser + tuner. Every
    /// stage reports its exact delay (QA `qa_latency_and_take_alignment`).
    fn wetDelay(self: *const VocalChain) usize {
        return self.denoiser.latencySamples() + self.tune.latencySamples();
    }

    /// Samples between input and the aligned processed output.
    pub fn latencySamples(self: *const VocalChain) usize {
        return self.wetDelay() + self.limiter.latencySamples();
    }

    /// Clear every stage's state and the dry line (Seridian addition: the DAW
    /// resets inserts on stop and seek). Settings and a learned noise profile
    /// are kept as each stage's own `reset` keeps them. No allocation.
    pub fn reset(self: *VocalChain) void {
        self.tune.reset();
        self.formant.reset();
        self.denoiser.reset();
        for (&self.harmony) |*h| h.reset();
        self.voice_eq.reset();
        self.parametric_eq.reset();
        self.deesser.reset();
        self.rider.reset();
        self.compressor.reset();
        self.tape.reset();
        self.delay.reset();
        self.reverb.reset();
        self.limiter.reset();
        @memset(self.dry_line, 0.0);
        self.dry_pos = 0;
    }

    /// Rust `isolate_mut`: the noise-isolation stage (learn / clear profile).
    pub fn isolateMut(self: *VocalChain) *SpectralDenoiser {
        return &self.denoiser;
    }

    /// Rust `isolate`.
    pub fn isolate(self: *const VocalChain) *const SpectralDenoiser {
        return &self.denoiser;
    }

    pub fn eqGainDb(self: *const VocalChain, band: Band) f32 {
        return self.voice_eq.bandGainDb(band);
    }

    pub fn eqDynamicGainsDb(self: *const VocalChain) [BAND_COUNT]f32 {
        return self.parametric_eq.gainDb();
    }

    /// The voice as it entered the EQ in the last block (`BLOCK` samples;
    /// only the first `n` are fresh after a short block of `n` samples).
    pub fn eqAnalyzerSamples(self: *const VocalChain) []const f32 {
        return self.eq_analyzer;
    }

    /// Push the stage settings from `cfg`; cheap, call once per batch.
    pub fn configure(self: *VocalChain, cfg: *const Settings) void {
        self.formant.setShiftCents(cfg.formant_semis * 100.0);
        self.denoiser.setReductionDb(if (cfg.isolate_on) cfg.isolate_db else 0.0);
        self.denoiser.setSensitivity(cfg.isolate_sensitivity);
        self.voice_eq.setAmount(cfg.eq_amount);
        self.voice_eq.setLowCutHz(cfg.eq_low_cut_hz);
        self.voice_eq.setAirDb(cfg.eq_air_db);
        for (Band.ALL, cfg.eq_bands) |band, on| self.voice_eq.setBandEnabled(band, on);
        self.parametric_eq.configure(&cfg.eq_manual_bands);
        self.deesser.setFrequencyHz(cfg.deess_freq_hz);
        self.deesser.setThresholdDb(cfg.deess_threshold_db);
        self.deesser.setRangeDb(cfg.deess_range_db);
        self.deesser.setListen(cfg.deess_listen);
        self.compressor.setThresholdDb(cfg.comp_threshold_db);
        self.compressor.setRatio(cfg.comp_ratio);
        self.compressor.setKneeDb(cfg.comp_knee_db);
        self.compressor.setAttackMs(cfg.comp_attack_ms);
        self.compressor.setReleaseMs(cfg.comp_release_ms);
        self.compressor.setMakeupDb(cfg.comp_makeup_db);
        self.compressor.setMix(cfg.comp_mix);
        self.rider.setTargetDb(cfg.rider_target_db);
        self.rider.setRangeDb(cfg.rider_range_db);
        self.rider.setSpeed(cfg.rider_speed);
        self.tape.setDrive(cfg.tape_drive);
        self.tape.setWow(cfg.tape_wow);
        const limiting = cfg.dynamics_on and cfg.limiter_on;
        self.limiter.setCeilingDb(if (limiting) cfg.limiter_ceiling_db else 0.0);
        self.limiter.setInputGainDb(if (limiting) cfg.limiter_drive_db else 0.0);
        self.delay.setBpm(cfg.delay_bpm);
        self.delay.setDivision(cfg.delay_division);
        self.delay.setFeedback(cfg.delay_feedback);
        self.delay.setMix(cfg.delay_mix);
        self.delay.setDuck(cfg.delay_duck);
        self.delay.setTone(cfg.delay_tone);
        self.reverb.setMix(cfg.reverb_mix);
        self.reverb.setDecayS(cfg.reverb_decay_s);
        self.reverb.setPredelayMs(cfg.reverb_predelay_ms);
        self.reverb.setSize(cfg.reverb_size);
        self.reverb.setDuck(cfg.reverb_duck);
    }

    /// Run `stage` in place over `out` using the shared scratch buffer.
    fn run(scratch: []f32, out: []f32, stage: anytype) void {
        const s = scratch[0..out.len];
        @memcpy(s, out);
        stage.process(s, out);
    }

    /// Process one block: `input` is raw mic/file audio (input gain is
    /// applied here, in place), `out` receives the finished voice.
    /// `input.len == out.len`, `1 <= len <= BLOCK`.
    pub fn process(self: *VocalChain, input: []f32, out: []f32, cfg: *const Settings) ProcessError!BlockReport {
        if (input.len != out.len or input.len == 0) return error.LengthMismatch;
        if (input.len > BLOCK) return error.BlockTooLarge;
        const n = input.len;
        const dry = self.dry[0..n];
        const clean = self.clean[0..n];
        const scratch = self.scratch[0..n];
        const voice = self.voice[0..n];

        const eps = std.math.floatEps(f32);
        const in_gain = settings.dbToGain(cfg.input_gain_db);
        if (@abs(in_gain - 1.0) > eps) {
            for (input) |*sample| sample.* *= in_gain;
        }
        var in_peak: f32 = 0.0;
        for (input) |s| in_peak = @max(in_peak, @abs(s));
        // Delay the dry signal by the wet path's latency (no allocation).
        if (self.dry_line.len == 0) {
            @memcpy(dry, input);
        } else {
            for (input, dry) |x, *d| {
                d.* = self.dry_line[self.dry_pos];
                self.dry_line[self.dry_pos] = x;
                self.dry_pos += 1;
                if (self.dry_pos == self.dry_line.len) self.dry_pos = 0;
            }
        }
        const mask = cfg.scale.mask();
        var params = settings.makeParams(cfg.retune_ms, mask, cfg.root_note);
        params.humanize = cfg.humanize;
        params.transpose_cents = cfg.transpose_semis * 100.0;
        params.clampAll();

        // ISOLATE first so detection and every later stage hear clean voice.
        self.denoiser.process(input, clean);
        // TUNE off / bypass: correction depth 0 keeps the tuner (and its
        // latency) in the path, so switching never shifts timing.
        if (cfg.bypass or !cfg.tune_on) params.mix = 0.0;
        // Below the confidence floor the brain sees "unvoiced" and eases
        // back to no correction instead of chasing breath or noise.
        self.tune.setMinConfidence(cfg.tracking);
        try self.tune.processChecked(clean, out, &params);
        const detected_hz = self.tune.lastDetectedHz();
        const ratio = self.tune.lastRatio();
        if (!cfg.bypass and @abs(cfg.formant_semis) > 0.01) {
            @memcpy(scratch, out);
            try self.formant.processChecked(scratch, out);
        }

        // HARMONY: shifted copies of the tuned lead, a scale-aware interval
        // away from the note it is landing on.
        const lead_note: ?i32 = if (detected_hz > 20.0) blk: {
            const m = 69.0 + 12.0 * @log2(detected_hz / 440.0);
            const note = @round(m + 12.0 * @log2(@max(ratio, 1e-3)));
            // Rust `as i32` saturates (NaN -> 0).
            if (std.math.isNan(note)) break :blk 0;
            break :blk @intFromFloat(std.math.clamp(note, -2147483648.0, 2147483520.0));
        } else null;
        var harmony_notes: [2]?i32 = @splat(null);
        if (cfg.harmony_on and !cfg.bypass) {
            for (cfg.harmony_mode.voices(), 0..) |maybe_interval, v| {
                const interval = maybe_interval orelse continue;
                if (lead_note) |note| {
                    self.harmony_semitones[v] = settings.harmonySemis(note, interval, mask, cfg.root_note);
                    harmony_notes[v] = note + self.harmony_semitones[v];
                }
                // Shift the clean input straight to the harmony pitch (lead
                // correction x interval): same delay as the lead, so the
                // voices stay sample-aligned instead of trailing it.
                const shifter = &self.harmony[v];
                const semis: f32 = @floatFromInt(self.harmony_semitones[v]);
                shifter.setRatio(ratio * std.math.pow(f32, 2.0, semis / 12.0));
                try shifter.processChecked(clean, voice);
                for (out, voice) |*o, h| o.* += cfg.harmony_level * h;
            }
        }

        // Feed the non-realtime visualizer with the voice as it enters EQ.
        @memcpy(self.eq_analyzer[0..n], out);

        // EQ: adaptive vocal polish, then the user-shaped dynamic parametric
        // bands. Both remain downstream of pitch and harmony processing.
        if (cfg.eq_on and !cfg.bypass) {
            if (cfg.eq_auto_on) run(scratch, out, &self.voice_eq);
            if (cfg.eq_manual_on) run(scratch, out, &self.parametric_eq);
        }
        // DYNAMICS: tame the esses, ride the level to target, compress,
        // then warm it with tape.
        const dynamics = cfg.dynamics_on and !cfg.bypass;
        if (dynamics and cfg.deess_on) run(scratch, out, &self.deesser);
        if (dynamics and cfg.rider_on) run(scratch, out, &self.rider);
        if (dynamics and cfg.comp_on) run(scratch, out, &self.compressor);
        if (dynamics and cfg.tape_on) run(scratch, out, &self.tape);
        // SPACE: echoes and room, both ducked under the dry voice.
        const space = cfg.space_on and !cfg.bypass;
        if (space and cfg.delay_on) run(scratch, out, &self.delay);
        if (space and cfg.reverb_on) run(scratch, out, &self.reverb);
        if (cfg.bypass) {
            @memcpy(out, dry);
        } else if (@abs(cfg.mix - 1.0) > eps) {
            for (out, dry) |*o, d| o.* = cfg.mix * o.* + (1.0 - cfg.mix) * d;
        }
        const out_gain = settings.dbToGain(cfg.output_gain_db);
        if (@abs(out_gain - 1.0) > eps) {
            for (out) |*sample| sample.* *= out_gain;
        }
        // LIMITER last: nothing leaves the chain above the ceiling.
        run(scratch, out, &self.limiter);
        var out_peak: f32 = 0.0;
        for (out) |s| out_peak = @max(out_peak, @abs(s));
        return .{
            .rider_gain_db = if (dynamics and cfg.rider_on) self.rider.gainDb() else 0.0,
            .limiter_gr_db = self.limiter.gainReductionDb(),
            .comp_gr_db = if (dynamics and cfg.comp_on) self.compressor.gainReductionDb() else 0.0,
            .comp_in_db = self.compressor.inputLevelDb(),
            .deess_gr_db = if (dynamics and cfg.deess_on) self.deesser.gainReductionDb() else 0.0,
            .deess_level_db = self.deesser.sibilanceDb(),
            .in_peak = in_peak,
            .out_peak = out_peak,
            .detected_hz = detected_hz,
            .ratio = ratio,
            .harmony_notes = harmony_notes,
        };
    }
};

const testing = std.testing;

// Seridian: new tests (the Rust chain.rs has none) for the error paths added
// in place of Rust panics.
test "process rejects mismatched and oversized blocks" {
    const gpa = testing.allocator;
    const cfg: Settings = .{};
    var chain = try VocalChain.init(gpa, 48_000, &cfg);
    defer chain.deinit(gpa);
    chain.configure(&cfg);
    var in_buf: [BLOCK + 1]f32 = @splat(0.0);
    var out_buf: [BLOCK + 1]f32 = @splat(0.0);
    try testing.expectError(error.LengthMismatch, chain.process(in_buf[0..4], out_buf[0..5], &cfg));
    try testing.expectError(error.LengthMismatch, chain.process(in_buf[0..0], out_buf[0..0], &cfg));
    try testing.expectError(error.BlockTooLarge, chain.process(&in_buf, &out_buf, &cfg));
}

test "short blocks match full blocks sample for sample (harmony off)" {
    const gpa = testing.allocator;
    // Harmony updates its ratio once per call (block-rate control), so it
    // is excluded; every other stage must be bit-identical.
    const cfg: Settings = .{ .harmony_on = false, .delay_on = true, .deess_on = true, .comp_on = true, .eq_manual_on = true };
    var a = try VocalChain.init(gpa, 48_000, &cfg);
    defer a.deinit(gpa);
    var b = try VocalChain.init(gpa, 48_000, &cfg);
    defer b.deinit(gpa);
    a.configure(&cfg);
    b.configure(&cfg);
    const total = BLOCK * 6;
    const sig = try gpa.alloc(f32, total);
    defer gpa.free(sig);
    for (sig, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 48_000.0;
        s.* = 0.4 * @sin(std.math.tau * 220.0 * t);
    }
    const out_a = try gpa.alloc(f32, total);
    defer gpa.free(out_a);
    const out_b = try gpa.alloc(f32, total);
    defer gpa.free(out_b);
    var block_in: [BLOCK]f32 = undefined;
    var off: usize = 0;
    while (off < total) : (off += BLOCK) {
        @memcpy(&block_in, sig[off .. off + BLOCK]);
        _ = try a.process(&block_in, out_a[off .. off + BLOCK], &cfg);
    }
    // Same stream in 256-sample blocks.
    const small = 256;
    off = 0;
    while (off < total) : (off += small) {
        @memcpy(block_in[0..small], sig[off .. off + small]);
        _ = try b.process(block_in[0..small], out_b[off .. off + small], &cfg);
    }
    try testing.expectEqualSlices(f32, out_a, out_b);
}
