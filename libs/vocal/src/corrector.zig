// Translated to Zig from pitchpure/crates/pitchpure_engine/src/corrector.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Streaming pitch corrector: tracker -> retune brain -> shifter, decoupled
//! from the host's block size.
//!
//! Hosts call with any buffer size (32...8192 samples, varying call to
//! call). Detection needs a fixed window and the brain's slew/smoothing are
//! stepped once per decision, so both run on a fixed analysis hop
//! (`analysis_hop`) over a sliding window (`analysis_window`) of the most
//! recent input, independent of how the host slices audio. The continuous
//! `SolaShifter` runs per sample in between, so a host block boundary is
//! never audible and output does not depend on block size.
//!
//! Realtime-safe: all buffers are allocated in `Corrector.init`; `process`
//! does not allocate, lock or log.

const std = @import("std");
const PitchTracker = @import("detector_track.zig").PitchTracker;
const FullParams = @import("params.zig").FullParams;
const RetuneBrain = @import("retune.zig").RetuneBrain;
const shifter_sola = @import("shifter_sola.zig");
const SolaShifter = shifter_sola.SolaShifter;

/// Detector window in samples (enough for two periods of ~90 Hz at 48 kHz).
pub const analysis_window: usize = 1024;
/// Samples between pitch decisions (~10.7 ms at 48 kHz). Each decision
/// runs three detectors over the window, so this is the main CPU knob;
/// 512 keeps retune responsive while leaving realtime headroom.
pub const analysis_hop: usize = 512;
/// Shifter grain lower bound / crossfade passed to `SolaShifter.init`.
const shifter_frame: usize = 1024;
const shifter_xfade: usize = 256;

/// Mono streaming pitch corrector.
pub const Corrector = struct {
    tracker: PitchTracker,
    brain: RetuneBrain,
    shifter: SolaShifter,
    /// Circular history of the last `analysis_window` input samples.
    ring: []f32,
    ring_pos: usize,
    /// Contiguous copy of `ring` for the detector.
    frame: []f32,
    since_decision: usize,
    last_hz: f32,
    last_ratio: f32,
    /// Detector confidence below which a block is treated as unvoiced.
    min_confidence: f32,

    /// Build a corrector for `sample_rate` starting from `params`.
    /// Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, params: FullParams) error{OutOfMemory}!Corrector {
        // One brain step per decision, so it is clocked at the decision rate.
        const decision_rate = @max(sample_rate / @as(u32, analysis_hop), 1);
        var tracker = try PitchTracker.init(gpa, sample_rate);
        errdefer tracker.deinit(gpa);
        var shifter = try SolaShifter.init(gpa, sample_rate, shifter_frame, shifter_xfade);
        errdefer shifter.deinit(gpa);
        const ring = try gpa.alloc(f32, analysis_window);
        errdefer gpa.free(ring);
        @memset(ring, 0.0);
        const frame = try gpa.alloc(f32, analysis_window);
        errdefer gpa.free(frame);
        @memset(frame, 0.0);
        return .{
            .tracker = tracker,
            .brain = RetuneBrain.init(decision_rate, params),
            .shifter = shifter,
            .ring = ring,
            .ring_pos = 0,
            .frame = frame,
            .since_decision = 0,
            .last_hz = 0.0,
            .last_ratio = 1.0,
            .min_confidence = 0.0,
        };
    }

    /// Free every buffer allocated by `init`.
    pub fn deinit(self: *Corrector, gpa: std.mem.Allocator) void {
        gpa.free(self.frame);
        gpa.free(self.ring);
        self.shifter.deinit(gpa);
        self.tracker.deinit(gpa);
        self.* = undefined;
    }

    /// Latency of a corrector at `sample_rate`, without building one.
    pub fn latencyFor(sample_rate: u32) usize {
        return SolaShifter.latencyFor(sample_rate, shifter_frame, shifter_xfade);
    }

    /// Exact delay from input to corrected output in samples.
    pub fn latencySamples(self: *const Corrector) usize {
        return self.shifter.latencySamples();
    }

    /// Treat detections below `confidence` (`0..=1`) as unvoiced.
    pub fn setMinConfidence(self: *Corrector, confidence: f32) void {
        self.min_confidence = if (std.math.isFinite(confidence)) std.math.clamp(confidence, 0.0, 1.0) else 0.0;
    }

    /// Snap the brain to `params` (e.g. after a preset load).
    pub fn setParams(self: *Corrector, params: FullParams) void {
        self.brain.setParams(params);
    }

    /// Mark a note start (restarts vibrato phase).
    pub fn noteOn(self: *Corrector) void {
        self.brain.noteOn();
    }

    /// Last detected fundamental in Hz (`0` when unvoiced).
    pub fn lastDetectedHz(self: *const Corrector) f32 {
        return self.last_hz;
    }

    /// Ratio the shifter is currently applying.
    pub fn lastRatio(self: *const Corrector) f32 {
        return self.last_ratio;
    }

    /// Clear audio history (detector, window, shifter). Brain control state
    /// is kept so a transport reset does not jump the correction.
    pub fn reset(self: *Corrector) void {
        self.tracker.reset();
        self.shifter.reset();
        @memset(self.ring, 0.0);
        self.ring_pos = 0;
        self.since_decision = 0;
        self.last_hz = 0.0;
    }

    fn decide(self: *Corrector, params: *const FullParams) void {
        const tail = analysis_window - self.ring_pos;
        @memcpy(self.frame[0..tail], self.ring[self.ring_pos..]);
        @memcpy(self.frame[tail..], self.ring[0..self.ring_pos]);
        const detected = self.tracker.estimate(self.frame);
        self.last_hz = if (detected) |t| t.freq_hz else 0.0;
        const trusted = if (detected) |t| (if (t.confidence >= self.min_confidence) t else null) else null;
        const ratio = self.brain.targetRatio(trusted, params);
        self.last_ratio = if (std.math.isFinite(ratio)) ratio else 1.0;
        self.shifter.setRatio(self.last_ratio);
    }

    /// Correct one block of any length. Returns `error.LengthMismatch` if
    /// `input.len != output.len` (Seridian: the Rust panicked; `process`
    /// keeps that behaviour).
    pub fn processChecked(self: *Corrector, input: []const f32, output: []f32, params: *const FullParams) error{LengthMismatch}!void {
        if (input.len != output.len) return error.LengthMismatch;
        var offset: usize = 0;
        while (offset < input.len) {
            const n = @min(analysis_hop - self.since_decision, input.len - offset);
            const segment = input[offset .. offset + n];
            for (segment) |x| {
                self.ring[self.ring_pos] = x;
                self.ring_pos = (self.ring_pos + 1) % analysis_window;
            }
            // Shift with the ratio in force, then decide: a decision applies
            // from the next sample on, whatever the host block size.
            self.shifter.process(segment, output[offset .. offset + n]);
            self.since_decision += n;
            if (self.since_decision == analysis_hop) {
                self.since_decision = 0;
                self.decide(params);
            }
            offset += n;
        }
    }

    /// Correct one block of any length.
    ///
    /// Panics if `input.len != output.len`, like the Rust `assert_eq!`.
    pub fn process(self: *Corrector, input: []const f32, output: []f32, params: *const FullParams) void {
        self.processChecked(input, output, params) catch
            @panic("input and output blocks must have equal length");
    }
};

const testing = std.testing;
const ts = shifter_sola.test_support;
const test_rate: u32 = 48_000;

fn cMajor(retune_ms: f32) FullParams {
    return .{ .retune_ms = retune_ms, .scale_mask = 0x0AB5, .root_midi = 60 };
}

/// Caller frees the result.
fn run(gpa: std.mem.Allocator, c: *Corrector, input: []const f32, block: usize, params: *const FullParams) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var start: usize = 0;
    while (start < input.len) : (start += block) {
        const end = @min(start + block, input.len);
        c.process(input[start..end], out[start..end], params);
    }
    return out;
}

test "flat_voice_is_pulled_to_the_scale_note" {
    const gpa = testing.allocator;
    const cases = [_][2]f32{ .{ 220.0, 0.0 }, .{ 261.63, 40.0 }, .{ 329.63, 40.0 }, .{ 392.0, 0.0 } };
    for (cases) |case| {
        const target = case[0];
        const retune = case[1];
        const sung = target * std.math.pow(f32, 2.0, -30.0 / 1200.0);
        const input = try ts.voice(gpa, sung, test_rate, test_rate * 2);
        defer gpa.free(input);
        const params = cMajor(retune);
        var c = try Corrector.init(gpa, test_rate, params);
        defer c.deinit(gpa);
        const out = try run(gpa, &c, input, 512, &params);
        defer gpa.free(out);
        const got = try ts.measureF0(gpa, out[test_rate..], test_rate, target);
        const err = ts.cents(got, target);
        if (!(@abs(err) <= 8.0)) {
            std.debug.print("{d} Hz retune {d}: got {d:.2}, error {d:.2} c\n", .{ target, retune, got, err });
            return error.TestUnexpectedResult;
        }
    }
}

test "host_block_size_does_not_matter" {
    const gpa = testing.allocator;
    const input = try ts.voice(gpa, 250.0, test_rate, 40_000);
    defer gpa.free(input);
    const params = cMajor(20.0);
    var c0 = try Corrector.init(gpa, test_rate, params);
    defer c0.deinit(gpa);
    const reference = try run(gpa, &c0, input, 4096, &params);
    defer gpa.free(reference);
    for ([_]usize{ 1, 32, 37, 128, 512, 1000 }) |block| {
        var c = try Corrector.init(gpa, test_rate, params);
        defer c.deinit(gpa);
        const out = try run(gpa, &c, input, block, &params);
        defer gpa.free(out);
        try testing.expectEqualSlices(f32, reference, out);
    }
}

test "latency_is_rate_dependent_and_predictable" {
    const gpa = testing.allocator;
    for ([_]u32{ 44_100, 48_000, 96_000 }) |rate| {
        var c = try Corrector.init(gpa, rate, .{});
        defer c.deinit(gpa);
        try testing.expectEqual(Corrector.latencyFor(rate), c.latencySamples());
    }
}

test "process_checked_rejects_length_mismatch" {
    const gpa = testing.allocator;
    var c = try Corrector.init(gpa, test_rate, .{});
    defer c.deinit(gpa);
    const in: [4]f32 = @splat(0.0);
    var out: [3]f32 = undefined;
    try testing.expectError(error.LengthMismatch, c.processChecked(&in, &out, &.{}));
}
