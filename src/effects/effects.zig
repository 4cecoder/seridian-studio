//! DSP Effects Module
//!
//! Provides audio effects for the DAW:
//! - Gain/Volume with soft clipping
//! - Biquad Filter (LP, HP, BP, Notch, Peak, Shelves)
//! - Delay with feedback and stereo spread
//! - Compressor with attack/release and makeup gain
//!
//! Usage:
//!   const effects = @import("effects/effects.zig");
//!   var chain = effects.EffectsChain.init();
//!   _ = try chain.addEffect(.filter);
//!   chain.process(audio_buffer, sample_rate);

pub const effect = @import("effect.zig");
pub const gain = @import("gain.zig");
pub const filter = @import("filter.zig");
pub const delay = @import("delay.zig");
pub const compressor = @import("compressor.zig");
pub const reverb = @import("reverb.zig");
pub const chain = @import("chain.zig");
pub const wavefolder = @import("wavefolder.zig");
pub const bitcrusher = @import("bitcrusher.zig");
pub const saturator = @import("saturator.zig");
pub const moog_filter = @import("moog_filter.zig");
pub const formant_filter = @import("formant_filter.zig");
pub const tb303_filter = @import("tb303_filter.zig");
pub const limiter = @import("limiter.zig");
pub const gate = @import("gate.zig");
pub const transient = @import("transient.zig");
pub const freeverb = @import("freeverb.zig");
pub const plate_reverb = @import("plate_reverb.zig");
pub const spring_reverb = @import("spring_reverb.zig");
pub const stereo_width = @import("stereo_width.zig");
pub const stereo_enhancer = @import("stereo_enhancer.zig");
pub const auto_pan = @import("auto_pan.zig");
pub const pitch_shifter = @import("pitch_shifter.zig");
pub const freeze = @import("freeze.zig");
pub const parametric_eq = @import("parametric_eq.zig");
pub const pro_eq = @import("pro_eq.zig");
pub const eq_presets = @import("eq_presets.zig");
pub const vocal = @import("vocal.zig");

// Re-export main types
pub const Effect = effect.Effect;
pub const Parameter = effect.Parameter;
pub const Gain = gain.Gain;
pub const Filter = filter.Filter;
pub const FilterType = filter.FilterType;
pub const Delay = delay.Delay;
pub const Compressor = compressor.Compressor;
pub const Reverb = reverb.Reverb;
pub const EffectsChain = chain.EffectsChain;
pub const EffectSlot = chain.EffectSlot;
pub const EffectType = chain.EffectType;
pub const MAX_EFFECTS = chain.MAX_EFFECTS;
pub const Wavefolder = wavefolder.Wavefolder;
pub const Bitcrusher = bitcrusher.Bitcrusher;
pub const Saturator = saturator.Saturator;
pub const MoogFilter = moog_filter.MoogFilter;
pub const FormantFilterEffect = formant_filter.FormantFilterEffect;
pub const TB303FilterEffect = tb303_filter.TB303FilterEffect;
pub const LimiterEffect = limiter.LimiterEffect;
pub const GateEffect = gate.GateEffect;
pub const TransientEffect = transient.TransientEffect;
pub const FreeverbEffect = freeverb.FreeverbEffect;
pub const PlateReverbEffect = plate_reverb.PlateReverbEffect;
pub const SpringReverbEffect = spring_reverb.SpringReverbEffect;
pub const StereoWidthEffect = stereo_width.StereoWidthEffect;
pub const StereoEnhancerEffect = stereo_enhancer.StereoEnhancerEffect;
pub const AutoPanEffect = auto_pan.AutoPanEffect;
pub const PitchShifterEffect = pitch_shifter.PitchShifterEffect;
pub const FreezeEffect = freeze.FreezeEffect;
pub const ParametricEQ = parametric_eq.ParametricEQ;
pub const ProEQ = pro_eq.ProEQ;

test {
    // Run all effect tests
    @import("std").testing.refAllDecls(@This());
}
