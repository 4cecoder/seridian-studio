//! Effects Chain
//!
//! A container for processing audio through multiple effects in series.
//! Effects are heap-allocated to avoid stack overflow from large effect buffers.
//! Designed for real-time audio processing - NO allocations during process().

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Gain = @import("gain.zig").Gain;
const Filter = @import("filter.zig").Filter;
const Delay = @import("delay.zig").Delay;
const Compressor = @import("compressor.zig").Compressor;
const Reverb = @import("reverb.zig").Reverb;
const WavefolderEffect = @import("wavefolder.zig").Wavefolder;
const BitcrusherEffect = @import("bitcrusher.zig").Bitcrusher;
const Saturator = @import("saturator.zig").Saturator;
const MoogFilter = @import("moog_filter.zig").MoogFilter;
const FormantFilterEffect = @import("formant_filter.zig").FormantFilterEffect;
const TB303FilterEffect = @import("tb303_filter.zig").TB303FilterEffect;
const LimiterEffect = @import("limiter.zig").LimiterEffect;
const GateEffect = @import("gate.zig").GateEffect;
const TransientEffect = @import("transient.zig").TransientEffect;
const FreeverbEffect = @import("freeverb.zig").FreeverbEffect;
const PlateReverbEffect = @import("plate_reverb.zig").PlateReverbEffect;
const SpringReverbEffect = @import("spring_reverb.zig").SpringReverbEffect;
const StereoWidthEffect = @import("stereo_width.zig").StereoWidthEffect;
const StereoEnhancerEffect = @import("stereo_enhancer.zig").StereoEnhancerEffect;
const AutoPanEffect = @import("auto_pan.zig").AutoPanEffect;
const PitchShifterEffect = @import("pitch_shifter.zig").PitchShifterEffect;
const FreezeEffect = @import("freeze.zig").FreezeEffect;
const ParametricEQ = @import("parametric_eq.zig").ParametricEQ;
const ProEQ = @import("pro_eq.zig").ProEQ;
const vocal_fx = @import("vocal.zig");

const log = std.log.scoped(.effects_chain);

/// Maximum effects per chain
pub const MAX_EFFECTS = 8;

/// Effect slot - heap-allocated effect storage
pub const EffectSlot = struct {
    effect_type: EffectType,
    // Use a union of pointers - small and stack-safe
    ptr: EffectPtr,

    const EffectPtr = union(EffectType) {
        none: void,
        gain: *Gain,
        filter: *Filter,
        delay: *Delay,
        compressor: *Compressor,
        reverb: *Reverb,
        wavefolder: *WavefolderEffect,
        bitcrusher: *BitcrusherEffect,
        saturator: *Saturator,
        moog_filter: *MoogFilter,
        formant_filter: *FormantFilterEffect,
        tb303_filter: *TB303FilterEffect,
        limiter: *LimiterEffect,
        gate: *GateEffect,
        transient: *TransientEffect,
        freeverb: *FreeverbEffect,
        plate_reverb: *PlateReverbEffect,
        spring_reverb: *SpringReverbEffect,
        stereo_width: *StereoWidthEffect,
        stereo_enhancer: *StereoEnhancerEffect,
        auto_pan: *AutoPanEffect,
        pitch_shifter: *PitchShifterEffect,
        freeze: *FreezeEffect,
        parametric_eq: *ParametricEQ,
        pro_eq: *ProEQ,
        de_esser: *vocal_fx.DeEsserEffect,
        vocal_rider: *vocal_fx.RiderEffect,
        denoise: *vocal_fx.DenoiseEffect,
        tape: *vocal_fx.TapeEffect,
        vocal_tune: *vocal_fx.TuneEffect,
        vocal_strip: *vocal_fx.StripEffect,
    };

    pub fn getEffect(self: *EffectSlot) ?*Effect {
        return switch (self.ptr) {
            .none => null,
            .gain => |g| &g.effect,
            .filter => |f| &f.effect,
            .delay => |d| &d.effect,
            .compressor => |c| &c.effect,
            .reverb => |r| &r.effect,
            .wavefolder => |w| &w.effect,
            .bitcrusher => |b| &b.effect,
            .saturator => |s| &s.effect,
            .moog_filter => |m| &m.effect,
            .formant_filter => |ff| &ff.effect,
            .tb303_filter => |t| &t.effect,
            .limiter => |l| &l.effect,
            .gate => |gt| &gt.effect,
            .transient => |tr| &tr.effect,
            .freeverb => |fv| &fv.effect,
            .plate_reverb => |pr| &pr.effect,
            .spring_reverb => |sr| &sr.effect,
            .stereo_width => |sw| &sw.effect,
            .stereo_enhancer => |se| &se.effect,
            .auto_pan => |ap| &ap.effect,
            .pitch_shifter => |ps| &ps.effect,
            .freeze => |fr| &fr.effect,
            .parametric_eq => |eq| &eq.effect,
            .pro_eq => |peq| &peq.effect,
            .de_esser => |des| &des.effect,
            .vocal_rider => |vr| &vr.effect,
            .denoise => |dn| &dn.effect,
            .tape => |tp| &tp.effect,
            .vocal_tune => |vt| &vt.effect,
            .vocal_strip => |vs| &vs.effect,
        };
    }

    pub fn getEffectConst(self: *const EffectSlot) ?*const Effect {
        return switch (self.ptr) {
            .none => null,
            .gain => |g| &g.effect,
            .filter => |f| &f.effect,
            .delay => |d| &d.effect,
            .compressor => |c| &c.effect,
            .reverb => |r| &r.effect,
            .wavefolder => |w| &w.effect,
            .bitcrusher => |b| &b.effect,
            .saturator => |s| &s.effect,
            .moog_filter => |m| &m.effect,
            .formant_filter => |ff| &ff.effect,
            .tb303_filter => |t| &t.effect,
            .limiter => |l| &l.effect,
            .gate => |gt| &gt.effect,
            .transient => |tr| &tr.effect,
            .freeverb => |fv| &fv.effect,
            .plate_reverb => |pr| &pr.effect,
            .spring_reverb => |sr| &sr.effect,
            .stereo_width => |sw| &sw.effect,
            .stereo_enhancer => |se| &se.effect,
            .auto_pan => |ap| &ap.effect,
            .pitch_shifter => |ps| &ps.effect,
            .freeze => |fr| &fr.effect,
            .parametric_eq => |eq| &eq.effect,
            .pro_eq => |peq| &peq.effect,
            .de_esser => |des| &des.effect,
            .vocal_rider => |vr| &vr.effect,
            .denoise => |dn| &dn.effect,
            .tape => |tp| &tp.effect,
            .vocal_tune => |vt| &vt.effect,
            .vocal_strip => |vs| &vs.effect,
        };
    }

    pub fn getName(self: *const EffectSlot) []const u8 {
        return switch (self.effect_type) {
            .none => "Empty",
            .gain => "Gain",
            .filter => "Filter",
            .delay => "Delay",
            .compressor => "Compressor",
            .reverb => "Reverb",
            .wavefolder => "Wavefolder",
            .bitcrusher => "Bitcrusher",
            .saturator => "Saturator",
            .moog_filter => "Moog Filter",
            .formant_filter => "Formant",
            .tb303_filter => "TB-303",
            .limiter => "Limiter",
            .gate => "Gate",
            .transient => "Transient",
            .freeverb => "Freeverb",
            .plate_reverb => "Plate Reverb",
            .spring_reverb => "Spring Reverb",
            .stereo_width => "Stereo Width",
            .stereo_enhancer => "Stereo Enhancer",
            .auto_pan => "Auto Pan",
            .pitch_shifter => "Pitch Shifter",
            .freeze => "Freeze",
            .parametric_eq => "Parametric EQ",
            .pro_eq => "Pro EQ",
            .de_esser => "De-esser",
            .vocal_rider => "Vocal Rider",
            .denoise => "Denoise",
            .tape => "Tape",
            .vocal_tune => "Vocal Tune",
            .vocal_strip => "Vocal Strip",
        };
    }

    pub fn deinit(self: *EffectSlot, allocator: std.mem.Allocator) void {
        switch (self.ptr) {
            .none => {},
            .gain => |g| allocator.destroy(g),
            .filter => |f| allocator.destroy(f),
            .delay => |d| allocator.destroy(d),
            .compressor => |c| allocator.destroy(c),
            .reverb => |r| allocator.destroy(r),
            .wavefolder => |w| allocator.destroy(w),
            .bitcrusher => |b| allocator.destroy(b),
            .saturator => |s| allocator.destroy(s),
            .moog_filter => |m| allocator.destroy(m),
            .formant_filter => |ff| allocator.destroy(ff),
            .tb303_filter => |t| allocator.destroy(t),
            .limiter => |l| allocator.destroy(l),
            .gate => |gt| allocator.destroy(gt),
            .transient => |tr| allocator.destroy(tr),
            .freeverb => |fv| allocator.destroy(fv),
            .plate_reverb => |pr| allocator.destroy(pr),
            .spring_reverb => |sr| allocator.destroy(sr),
            .stereo_width => |sw| allocator.destroy(sw),
            .stereo_enhancer => |se| allocator.destroy(se),
            .auto_pan => |ap| allocator.destroy(ap),
            .pitch_shifter => |ps| {
                ps.deinit(); // Clean up internal processor
                allocator.destroy(ps);
            },
            .freeze => |fr| {
                fr.deinit(); // Clean up internal processor
                allocator.destroy(fr);
            },
            .parametric_eq => |eq| allocator.destroy(eq),
            .pro_eq => |peq| allocator.destroy(peq),
            .de_esser => |des| {
                des.deinit();
                allocator.destroy(des);
            },
            .vocal_rider => |vr| {
                vr.deinit();
                allocator.destroy(vr);
            },
            .denoise => |dn| {
                dn.deinit();
                allocator.destroy(dn);
            },
            .tape => |tp| {
                tp.deinit();
                allocator.destroy(tp);
            },
            .vocal_tune => |vt| {
                vt.deinit();
                allocator.destroy(vt);
            },
            .vocal_strip => |vs| {
                vs.deinit();
                allocator.destroy(vs);
            },
        }
        self.ptr = .{ .none = {} };
        self.effect_type = .none;
    }
};

/// Effect type for creating new effects
pub const EffectType = enum {
    none,
    gain,
    filter,
    delay,
    compressor,
    reverb,
    wavefolder,
    bitcrusher,
    saturator,
    moog_filter,
    formant_filter,
    tb303_filter,
    limiter,
    gate,
    transient,
    freeverb,
    plate_reverb,
    spring_reverb,
    stereo_width,
    stereo_enhancer,
    auto_pan,
    pitch_shifter,
    freeze,
    parametric_eq,
    pro_eq,
    // Vocal effects (libs/vocal). Append only: projects store the index.
    de_esser,
    vocal_rider,
    denoise,
    tape,
    vocal_tune,
    vocal_strip,
};

/// Effects chain - processes audio through multiple effects in series
pub const EffectsChain = struct {
    /// Allocator for heap-allocated effects
    allocator: std.mem.Allocator,

    /// Effect slots (pointers, not inline storage)
    slots: [MAX_EFFECTS]EffectSlot = @as([MAX_EFFECTS]EffectSlot, @splat(.{
        .effect_type = .none,
        .ptr = .{ .none = {} },
    })),

    /// Number of active effects
    count: usize = 0,

    /// Chain bypassed
    bypassed: bool = false,

    /// Sample rate that newly added effects are built for. Vocal effects are
    /// fixed to it; the engine sets it before adding effects.
    sample_rate: u32 = 48000,

    /// Initialize empty chain
    pub fn init(allocator: std.mem.Allocator) EffectsChain {
        return .{ .allocator = allocator };
    }

    /// Deinitialize chain and free all effects
    pub fn deinit(self: *EffectsChain) void {
        for (&self.slots) |*slot| {
            slot.deinit(self.allocator);
        }
        self.count = 0;
    }

    /// Move the chain to a new sample rate: effects added later are built for it
    /// and existing vocal effects are rebuilt. Control thread only, with the audio
    /// callback stopped. An effect that cannot be rebuilt is logged and keeps its
    /// old rate (it passes audio through); the others still move.
    pub fn setSampleRate(self: *EffectsChain, rate: u32) void {
        self.sample_rate = rate;
        for (self.slots[0..self.count]) |*slot| {
            const result = switch (slot.ptr) {
                .de_esser => |e| e.rebuild(rate),
                .vocal_rider => |e| e.rebuild(rate),
                .denoise => |e| e.rebuild(rate),
                .tape => |e| e.rebuild(rate),
                .vocal_tune => |e| e.rebuild(rate),
                .vocal_strip => |e| e.rebuild(rate),
                else => {},
            };
            result catch |err| log.warn("{s} not rebuilt for {d} Hz: {}", .{ slot.getName(), rate, err });
        }
    }

    /// Add an effect to the chain
    pub fn addEffect(self: *EffectsChain, effect_type: EffectType) !usize {
        if (self.count >= MAX_EFFECTS) {
            return error.ChainFull;
        }
        if (effect_type == .none) {
            return error.InvalidEffectType;
        }

        const slot_index = self.count;

        // Allocate and initialize the effect
        switch (effect_type) {
            .none => unreachable,
            .gain => {
                const g = try self.allocator.create(Gain);
                g.* = Gain.init();
                self.slots[slot_index] = .{
                    .effect_type = .gain,
                    .ptr = .{ .gain = g },
                };
            },
            .filter => {
                const f = try self.allocator.create(Filter);
                f.* = Filter.init();
                self.slots[slot_index] = .{
                    .effect_type = .filter,
                    .ptr = .{ .filter = f },
                };
            },
            .delay => {
                const d = try self.allocator.create(Delay);
                d.* = Delay.init();
                self.slots[slot_index] = .{
                    .effect_type = .delay,
                    .ptr = .{ .delay = d },
                };
            },
            .compressor => {
                const c = try self.allocator.create(Compressor);
                c.* = Compressor.init();
                self.slots[slot_index] = .{
                    .effect_type = .compressor,
                    .ptr = .{ .compressor = c },
                };
            },
            .reverb => {
                const r = try self.allocator.create(Reverb);
                r.* = Reverb.init();
                self.slots[slot_index] = .{
                    .effect_type = .reverb,
                    .ptr = .{ .reverb = r },
                };
            },
            .wavefolder => {
                const w = try self.allocator.create(WavefolderEffect);
                w.* = WavefolderEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .wavefolder,
                    .ptr = .{ .wavefolder = w },
                };
            },
            .bitcrusher => {
                const b = try self.allocator.create(BitcrusherEffect);
                b.* = BitcrusherEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .bitcrusher,
                    .ptr = .{ .bitcrusher = b },
                };
            },
            .saturator => {
                const s = try self.allocator.create(Saturator);
                s.* = Saturator.init();
                self.slots[slot_index] = .{
                    .effect_type = .saturator,
                    .ptr = .{ .saturator = s },
                };
            },
            .moog_filter => {
                const m = try self.allocator.create(MoogFilter);
                m.* = MoogFilter.init();
                self.slots[slot_index] = .{
                    .effect_type = .moog_filter,
                    .ptr = .{ .moog_filter = m },
                };
            },
            .formant_filter => {
                const ff = try self.allocator.create(FormantFilterEffect);
                ff.* = FormantFilterEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .formant_filter,
                    .ptr = .{ .formant_filter = ff },
                };
            },
            .tb303_filter => {
                const t = try self.allocator.create(TB303FilterEffect);
                t.* = TB303FilterEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .tb303_filter,
                    .ptr = .{ .tb303_filter = t },
                };
            },
            .limiter => {
                const l = try self.allocator.create(LimiterEffect);
                l.* = LimiterEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .limiter,
                    .ptr = .{ .limiter = l },
                };
            },
            .gate => {
                const gt = try self.allocator.create(GateEffect);
                gt.* = GateEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .gate,
                    .ptr = .{ .gate = gt },
                };
            },
            .transient => {
                const tr = try self.allocator.create(TransientEffect);
                tr.* = TransientEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .transient,
                    .ptr = .{ .transient = tr },
                };
            },
            .freeverb => {
                const fv = try self.allocator.create(FreeverbEffect);
                fv.* = FreeverbEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .freeverb,
                    .ptr = .{ .freeverb = fv },
                };
            },
            .plate_reverb => {
                const pr = try self.allocator.create(PlateReverbEffect);
                pr.* = PlateReverbEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .plate_reverb,
                    .ptr = .{ .plate_reverb = pr },
                };
            },
            .spring_reverb => {
                const sr = try self.allocator.create(SpringReverbEffect);
                sr.* = SpringReverbEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .spring_reverb,
                    .ptr = .{ .spring_reverb = sr },
                };
            },
            .stereo_width => {
                const sw = try self.allocator.create(StereoWidthEffect);
                sw.* = StereoWidthEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .stereo_width,
                    .ptr = .{ .stereo_width = sw },
                };
            },
            .stereo_enhancer => {
                const se = try self.allocator.create(StereoEnhancerEffect);
                se.* = StereoEnhancerEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .stereo_enhancer,
                    .ptr = .{ .stereo_enhancer = se },
                };
            },
            .auto_pan => {
                const ap = try self.allocator.create(AutoPanEffect);
                ap.* = AutoPanEffect.init();
                self.slots[slot_index] = .{
                    .effect_type = .auto_pan,
                    .ptr = .{ .auto_pan = ap },
                };
            },
            .pitch_shifter => {
                const ps = try self.allocator.create(PitchShifterEffect);
                ps.* = PitchShifterEffect.init(self.allocator);
                self.slots[slot_index] = .{
                    .effect_type = .pitch_shifter,
                    .ptr = .{ .pitch_shifter = ps },
                };
            },
            .freeze => {
                const fr = try self.allocator.create(FreezeEffect);
                fr.* = FreezeEffect.init(self.allocator);
                self.slots[slot_index] = .{
                    .effect_type = .freeze,
                    .ptr = .{ .freeze = fr },
                };
            },
            .parametric_eq => {
                const eq = try self.allocator.create(ParametricEQ);
                eq.* = ParametricEQ.init();
                self.slots[slot_index] = .{
                    .effect_type = .parametric_eq,
                    .ptr = .{ .parametric_eq = eq },
                };
            },
            .pro_eq => {
                const peq = try self.allocator.create(ProEQ);
                peq.* = ProEQ.init();
                self.slots[slot_index] = .{
                    .effect_type = .pro_eq,
                    .ptr = .{ .pro_eq = peq },
                };
            },
            .de_esser => {
                const des = try self.allocator.create(vocal_fx.DeEsserEffect);
                errdefer self.allocator.destroy(des);
                try des.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .de_esser,
                    .ptr = .{ .de_esser = des },
                };
            },
            .vocal_rider => {
                const vr = try self.allocator.create(vocal_fx.RiderEffect);
                errdefer self.allocator.destroy(vr);
                try vr.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .vocal_rider,
                    .ptr = .{ .vocal_rider = vr },
                };
            },
            .denoise => {
                const dn = try self.allocator.create(vocal_fx.DenoiseEffect);
                errdefer self.allocator.destroy(dn);
                try dn.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .denoise,
                    .ptr = .{ .denoise = dn },
                };
            },
            .tape => {
                const tp = try self.allocator.create(vocal_fx.TapeEffect);
                errdefer self.allocator.destroy(tp);
                try tp.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .tape,
                    .ptr = .{ .tape = tp },
                };
            },
            .vocal_tune => {
                const vt = try self.allocator.create(vocal_fx.TuneEffect);
                errdefer self.allocator.destroy(vt);
                try vt.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .vocal_tune,
                    .ptr = .{ .vocal_tune = vt },
                };
            },
            .vocal_strip => {
                const vs = try self.allocator.create(vocal_fx.StripEffect);
                errdefer self.allocator.destroy(vs);
                try vs.init(self.allocator, self.sample_rate);
                self.slots[slot_index] = .{
                    .effect_type = .vocal_strip,
                    .ptr = .{ .vocal_strip = vs },
                };
            },
        }
        self.count += 1;

        log.info("Added {s} effect at slot {d}", .{ self.slots[slot_index].getName(), slot_index });
        return slot_index;
    }

    /// Remove effect at index
    pub fn removeEffect(self: *EffectsChain, index: usize) void {
        if (index >= self.count) return;

        // Free the effect being removed
        self.slots[index].deinit(self.allocator);

        // Shift effects down
        var i = index;
        while (i < self.count - 1) : (i += 1) {
            self.slots[i] = self.slots[i + 1];
        }
        self.slots[self.count - 1] = .{
            .effect_type = .none,
            .ptr = .{ .none = {} },
        };
        self.count -= 1;

        log.info("Removed effect at slot {d}", .{index});
    }

    /// Swap two effects
    pub fn swapEffects(self: *EffectsChain, index_a: usize, index_b: usize) void {
        if (index_a >= self.count or index_b >= self.count) return;
        const tmp = self.slots[index_a];
        self.slots[index_a] = self.slots[index_b];
        self.slots[index_b] = tmp;
    }

    /// Get effect at index
    pub fn getEffect(self: *EffectsChain, index: usize) ?*Effect {
        if (index >= self.count) return null;
        return self.slots[index].getEffect();
    }

    /// Get effect slot at index
    pub fn getSlot(self: *EffectsChain, index: usize) ?*EffectSlot {
        if (index >= self.count) return null;
        return &self.slots[index];
    }

    /// Process audio through the chain
    /// REAL-TIME SAFE - NO ALLOCATIONS
    pub fn process(self: *EffectsChain, buffer: []f32, sample_rate: u32) void {
        if (self.bypassed) return;

        for (0..self.count) |i| {
            if (self.slots[i].getEffect()) |effect| {
                effect.process(buffer, sample_rate);
            }
        }
    }

    /// Total delay of the chain in frames (effects run in series, so latencies add).
    pub fn latencySamples(self: *const EffectsChain) usize {
        if (self.bypassed) return 0;
        var total: usize = 0;
        for (self.slots[0..self.count]) |*slot| {
            if (slot.getEffectConst()) |effect| total += effect.latencySamples();
        }
        return total;
    }

    /// Reset all effects in chain
    pub fn reset(self: *EffectsChain) void {
        for (0..self.count) |i| {
            if (self.slots[i].getEffect()) |effect| {
                effect.reset();
            }
        }
    }

    /// Set bypass for entire chain
    pub fn setBypass(self: *EffectsChain, bypassed: bool) void {
        self.bypassed = bypassed;
    }

    /// Clear all effects (frees memory)
    pub fn clear(self: *EffectsChain) void {
        for (&self.slots) |*slot| {
            slot.deinit(self.allocator);
        }
        self.count = 0;
    }
};

test "effects chain basic" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    // Add some effects
    const gain_idx = try chain.addEffect(.gain);
    const filter_idx = try chain.addEffect(.filter);

    try testing.expectEqual(@as(usize, 0), gain_idx);
    try testing.expectEqual(@as(usize, 1), filter_idx);
    try testing.expectEqual(@as(usize, 2), chain.count);

    // Process some audio
    var buffer = [_]f32{ 0.5, 0.5, -0.5, -0.5 };
    chain.process(&buffer, 48000);

    // Remove effect
    chain.removeEffect(0);
    try testing.expectEqual(@as(usize, 1), chain.count);
}

test "effects chain swap" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.gain);
    _ = try chain.addEffect(.filter);
    _ = try chain.addEffect(.delay);

    // Verify initial order
    try testing.expectEqual(EffectType.gain, chain.slots[0].effect_type);
    try testing.expectEqual(EffectType.filter, chain.slots[1].effect_type);
    try testing.expectEqual(EffectType.delay, chain.slots[2].effect_type);

    // Swap first and last
    chain.swapEffects(0, 2);

    try testing.expectEqual(EffectType.delay, chain.slots[0].effect_type);
    try testing.expectEqual(EffectType.filter, chain.slots[1].effect_type);
    try testing.expectEqual(EffectType.gain, chain.slots[2].effect_type);

    // Invalid swap (out of bounds) - should not crash
    chain.swapEffects(0, 10);
    try testing.expectEqual(EffectType.delay, chain.slots[0].effect_type);
}

test "effects chain bypass" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.gain);

    // Initial state - not bypassed
    try testing.expect(!chain.bypassed);

    // Set bypass
    chain.setBypass(true);
    try testing.expect(chain.bypassed);

    // Process with bypass - buffer should be unchanged
    var buffer = [_]f32{ 0.5, 0.5 };
    const original = buffer;
    chain.process(&buffer, 48000);
    try testing.expectEqual(original[0], buffer[0]);
    try testing.expectEqual(original[1], buffer[1]);

    // Disable bypass
    chain.setBypass(false);
    try testing.expect(!chain.bypassed);
}

test "effects chain clear" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.gain);
    _ = try chain.addEffect(.filter);
    _ = try chain.addEffect(.compressor);

    try testing.expectEqual(@as(usize, 3), chain.count);

    // Clear all effects
    chain.clear();

    try testing.expectEqual(@as(usize, 0), chain.count);
    try testing.expectEqual(EffectType.none, chain.slots[0].effect_type);
    try testing.expectEqual(EffectType.none, chain.slots[1].effect_type);
}

test "effects chain full" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    // Fill chain
    for (0..MAX_EFFECTS) |_| {
        _ = try chain.addEffect(.gain);
    }

    try testing.expectEqual(MAX_EFFECTS, chain.count);

    // Should error when full
    const result = chain.addEffect(.filter);
    try testing.expectError(error.ChainFull, result);
}

test "effects chain invalid effect type" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    // Cannot add .none effect
    const result = chain.addEffect(.none);
    try testing.expectError(error.InvalidEffectType, result);
}

test "effects chain get slot and effect" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.gain);

    // Get slot
    const slot = chain.getSlot(0);
    try testing.expect(slot != null);
    try testing.expectEqual(EffectType.gain, slot.?.effect_type);

    // Get effect
    const effect = chain.getEffect(0);
    try testing.expect(effect != null);

    // Invalid index
    try testing.expect(chain.getSlot(10) == null);
    try testing.expect(chain.getEffect(10) == null);
}

test "effects chain reset" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.delay);

    // Process some audio to build up state
    var buffer: [200]f32 = undefined;
    for (&buffer, 0..) |*sample, i| sample.* = if (i % 2 == 0) 1.0 else 0.0;
    chain.process(&buffer, 48000);

    // Reset should not crash
    chain.reset();
}

test "effect slot names" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    _ = try chain.addEffect(.gain);
    _ = try chain.addEffect(.compressor);
    _ = try chain.addEffect(.reverb);

    try testing.expectEqualStrings("Gain", chain.slots[0].getName());
    try testing.expectEqualStrings("Compressor", chain.slots[1].getName());
    try testing.expectEqualStrings("Reverb", chain.slots[2].getName());

    // Empty slot
    try testing.expectEqualStrings("Empty", chain.slots[7].getName());
}

test "effects chain multiple effect types" {
    const testing = std.testing;

    var chain = EffectsChain.init(testing.allocator);
    defer chain.deinit();

    // Test various effect types can be created
    _ = try chain.addEffect(.gain);
    _ = try chain.addEffect(.filter);
    _ = try chain.addEffect(.compressor);
    _ = try chain.addEffect(.limiter);
    _ = try chain.addEffect(.saturator);

    try testing.expectEqual(@as(usize, 5), chain.count);

    // Process through all
    var buffer = [_]f32{ 0.5, -0.5, 0.3, -0.3 };
    chain.process(&buffer, 48000);
}

test "effects chain setSampleRate rebuilds vocal effects" {
    var chain = EffectsChain.init(std.testing.allocator);
    defer chain.deinit();
    _ = try chain.addEffect(.gain);
    const idx = try chain.addEffect(.vocal_tune);
    try std.testing.expectEqual(@as(u32, 48000), chain.slots[idx].ptr.vocal_tune.rate);

    chain.setSampleRate(44100);
    try std.testing.expectEqual(@as(u32, 44100), chain.sample_rate);
    try std.testing.expectEqual(@as(u32, 44100), chain.slots[idx].ptr.vocal_tune.rate);

    // Effects added after the change are built at the new rate.
    const later = try chain.addEffect(.de_esser);
    try std.testing.expectEqual(@as(u32, 44100), chain.slots[later].ptr.de_esser.rate);
}

test "effects chain latency sums effects and ignores bypassed ones" {
    var chain = EffectsChain.init(std.testing.allocator);
    defer chain.deinit();
    _ = try chain.addEffect(.gain);
    try std.testing.expectEqual(@as(usize, 0), chain.latencySamples());

    const tune = try chain.addEffect(.vocal_tune);
    const tune_latency = chain.slots[tune].ptr.vocal_tune.latencySamples();
    try std.testing.expect(tune_latency > 0);
    try std.testing.expectEqual(tune_latency, chain.latencySamples());

    chain.slots[tune].getEffect().?.setBypass(true);
    try std.testing.expectEqual(@as(usize, 0), chain.latencySamples());
    chain.slots[tune].getEffect().?.setBypass(false);

    chain.setBypass(true);
    try std.testing.expectEqual(@as(usize, 0), chain.latencySamples());
}
