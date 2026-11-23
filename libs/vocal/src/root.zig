//! vocal (layer L2): realtime vocal processing translated from PitchPure:
//! pitch detection and correction, formant-preserving shifting, vocal EQ,
//! dynamics, de-essing, denoise, and space effects. No dependencies.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "vocal";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const chain = @import("chain.zig");
pub const compressor = @import("compressor.zig");
pub const corrector = @import("corrector.zig");
pub const deesser = @import("deesser.zig");
pub const delay = @import("delay.zig");
pub const denoise = @import("denoise.zig");
pub const detector_acf = @import("detector_acf.zig");
pub const detector_mpm = @import("detector_mpm.zig");
pub const detector_track = @import("detector_track.zig");
pub const detector_yin = @import("detector_yin.zig");
pub const fft = @import("fft.zig");
pub const formant = @import("formant.zig");
pub const host_params = @import("host_params.zig");
pub const keydetect = @import("keydetect.zig");
pub const limiter = @import("limiter.zig");
pub const parametric_eq = @import("parametric_eq.zig");
pub const params = @import("params.zig");
pub const quantizer = @import("quantizer.zig");
pub const resampler = @import("resampler.zig");
pub const retune = @import("retune.zig");
pub const reverb = @import("reverb.zig");
pub const rider = @import("rider.zig");
pub const router = @import("router.zig");
pub const shifter_pv = @import("shifter_pv.zig");
pub const shifter_sola = @import("shifter_sola.zig");
pub const simd = @import("simd.zig");
pub const slew = @import("slew.zig");
pub const suite = @import("suite.zig");
pub const tape = @import("tape.zig");
pub const types = @import("types.zig");
pub const vibrato = @import("vibrato.zig");
pub const voice_eq = @import("voice_eq.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("vocal", lib_name);
}
