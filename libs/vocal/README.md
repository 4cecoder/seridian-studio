# vocal (L2)

Realtime vocal processing for Seridian Studio, translated from PitchPure
(`pitchpure/crates/pitchpure_engine`, std-only Rust, MIT, same owner).

Pipeline: input -> router -> detectors (YIN, ACF, MPM) -> tracker -> retune brain
(quantizer + slew + vibrato) -> shifter (SOLA / phase vocoder) -> formant -> output,
followed by the vocal chain: EQ -> de-ess -> rider -> compressor -> tape -> space -> limiter.

Every stage follows the Processor contract in `types.zig`: preallocate in `init`,
`process` never allocates, locks, logs or does I/O.

`zig build test-vocal`
