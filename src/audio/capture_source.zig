//! A source of live input audio for tracks. The engine pulls one block per input-enabled
//! track from it on the audio thread, so `read` must not allocate, lock, block or log.

/// Capture device provider.
pub const CaptureSource = struct {
    context: *anyopaque,
    /// Fill `out` (interleaved stereo) with the latest samples from capture `device`.
    /// Returns the number of samples written; the engine treats the rest of `out` as silence.
    read: *const fn (context: *anyopaque, device: i32, out: []f32) usize,
};
