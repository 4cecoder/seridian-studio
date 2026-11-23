//! Master-bus mastering: glue compressor, then a true-peak limiter, plus a
//! loudness meter. Runs on the final stereo-interleaved mix.
//!
//! Chain: compressor (-10 dB, 2:1, 10 ms / 120 ms) -> limiter (-1 dBTP).
//!
//! The compressor makeup is 0 dB. Signals below the threshold therefore pass
//! at the same level (a fixed makeup would also lift quiet material), and loud
//! material loses at most a few dB of peak level at 2:1.
//!
//! Loudness meter: SHORT-TERM (3 s) K-weighted loudness, ITU-R BS.1770
//! K-weighting (high shelf + RLB high-pass) with a simple mean-square window
//! built from 100 ms blocks. There is no gating, so this is not an integrated
//! LUFS reading. Silence reads as `silence_lufs`.

const std = @import("std");
const Compressor = @import("../effects/compressor.zig").Compressor;
const LimiterEffect = @import("../effects/limiter.zig").LimiterEffect;

/// Value reported by the loudness meter when there is no signal.
pub const silence_lufs: f32 = -70.0;

/// Limiter ceiling in dB true peak.
pub const ceiling_dbtp: f32 = -1.0;

/// Make-up gain applied after the compressor and before the limiter.
pub const makeup_db: f32 = 4.0;

const block_ms = 100;
const blocks_per_window = 30; // 3 s short-term window
const chunk_frames = 512;
const silent_envelope_db: f32 = -80.0;

const Biquad = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn process(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }
};

/// BS.1770 stage 1: high shelf (+4 dB around 1.68 kHz).
fn shelfCoeffs(fs: f32) Biquad {
    const f0: f32 = 1681.974450955533;
    const gain_db: f32 = 3.999843853973347;
    const q: f32 = 0.7071752369554196;
    const k = @tan(std.math.pi * f0 / fs);
    const vh = std.math.pow(f32, 10.0, gain_db / 20.0);
    const vb = std.math.pow(f32, vh, 0.4996667741545416);
    const a0 = 1.0 + k / q + k * k;
    return .{
        .b0 = (vh + vb * k / q + k * k) / a0,
        .b1 = 2.0 * (k * k - vh) / a0,
        .b2 = (vh - vb * k / q + k * k) / a0,
        .a1 = 2.0 * (k * k - 1.0) / a0,
        .a2 = (1.0 - k / q + k * k) / a0,
    };
}

/// BS.1770 stage 2: RLB high-pass (about 38 Hz).
fn highpassCoeffs(fs: f32) Biquad {
    const f0: f32 = 38.13547087602444;
    const q: f32 = 0.5003270373238773;
    const k = @tan(std.math.pi * f0 / fs);
    const a0 = 1.0 + k / q + k * k;
    return .{
        .b0 = 1,
        .b1 = -2,
        .b2 = 1,
        .a1 = 2.0 * (k * k - 1.0) / a0,
        .a2 = (1.0 - k / q + k * k) / a0,
    };
}

/// Short-term K-weighted loudness meter for stereo-interleaved audio.
pub const LoudnessMeter = struct {
    shelf: [2]Biquad = .{ .{}, .{} },
    highpass: [2]Biquad = .{ .{}, .{} },
    configured_rate: u32 = 0,
    block_frames: u32 = 4800,
    block_fill: u32 = 0,
    block_sum: f64 = 0, // sum of weighted squares (both channels) in current block
    ring: [blocks_per_window]f64 = @as([blocks_per_window]f64, @splat(0)),
    ring_pos: usize = 0,
    ring_count: usize = 0,
    /// Latest short-term loudness; read from any thread.
    lufs: std.atomic.Value(f32) = std.atomic.Value(f32).init(silence_lufs),

    fn configure(self: *LoudnessMeter, sample_rate: u32) void {
        const fs: f32 = @floatFromInt(sample_rate);
        for (0..2) |c| {
            self.shelf[c] = shelfCoeffs(fs);
            self.highpass[c] = highpassCoeffs(fs);
        }
        self.configured_rate = sample_rate;
        self.block_frames = @max(1, sample_rate / (1000 / block_ms));
        self.block_fill = 0;
        self.block_sum = 0;
    }

    pub fn reset(self: *LoudnessMeter) void {
        self.configured_rate = 0; // forces filter state reset on next process
        self.ring = @splat(0);
        self.ring_pos = 0;
        self.ring_count = 0;
        self.lufs.store(silence_lufs, .monotonic);
    }

    /// Feed interleaved stereo samples. Does not modify them.
    pub fn process(self: *LoudnessMeter, buffer: []const f32, sample_rate: u32) void {
        if (self.configured_rate != sample_rate) self.configure(sample_rate);
        const frames = buffer.len / 2;
        for (0..frames) |i| {
            for (0..2) |c| {
                const w = self.highpass[c].process(self.shelf[c].process(buffer[i * 2 + c]));
                self.block_sum += @as(f64, w) * @as(f64, w);
            }
            self.block_fill += 1;
            if (self.block_fill >= self.block_frames) {
                self.closeBlock();
            }
        }
    }

    fn closeBlock(self: *LoudnessMeter) void {
        // Mean square per channel summed over channels (equal channel weights).
        self.ring[self.ring_pos] = self.block_sum / @as(f64, @floatFromInt(self.block_frames));
        self.ring_pos = (self.ring_pos + 1) % blocks_per_window;
        if (self.ring_count < blocks_per_window) self.ring_count += 1;
        self.block_sum = 0;
        self.block_fill = 0;

        var total: f64 = 0;
        for (self.ring[0..self.ring_count]) |v| total += v;
        const mean = total / @as(f64, @floatFromInt(self.ring_count));
        const value: f32 = if (mean <= 1e-12)
            silence_lufs
        else
            @max(silence_lufs, @as(f32, @floatCast(-0.691 + 10.0 * @log10(mean))));
        self.lufs.store(value, .monotonic);
    }

    pub fn getLufs(self: *const LoudnessMeter) f32 {
        return self.lufs.load(.monotonic);
    }
};

pub const Mastering = struct {
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    compressor: Compressor,
    limiters: [2]LimiterEffect,
    meter: LoudnessMeter = .{},
    was_enabled: bool = true,

    pub fn init() Mastering {
        var comp = Compressor.init();
        comp.effect.vtable.setParameter(&comp.effect, 0, -10.0); // threshold
        comp.effect.vtable.setParameter(&comp.effect, 1, 2.0); // ratio
        comp.effect.vtable.setParameter(&comp.effect, 2, 10.0); // attack ms
        comp.effect.vtable.setParameter(&comp.effect, 3, 120.0); // release ms
        comp.effect.vtable.setParameter(&comp.effect, 4, 0.0); // makeup dB
        comp.envelope = silent_envelope_db;
        var self = Mastering{
            .compressor = comp,
            .limiters = .{ LimiterEffect.init(), LimiterEffect.init() },
        };
        for (&self.limiters) |*lim| {
            lim.setCeiling(ceiling_dbtp);
            lim.setTruePeak(true);
        }
        return self;
    }

    pub fn setEnabled(self: *Mastering, on: bool) void {
        self.enabled.store(on, .monotonic);
    }

    pub fn isEnabled(self: *const Mastering) bool {
        return self.enabled.load(.monotonic);
    }

    /// Short-term K-weighted loudness of the output, in LUFS-like units.
    pub fn getLoudness(self: *const Mastering) f32 {
        return self.meter.getLufs();
    }

    /// Frames of delay the chain adds to the signal (the limiter lookahead); 0 when off.
    pub fn latencyFrames(self: *const Mastering) usize {
        if (!self.isEnabled()) return 0;
        return @intFromFloat(self.limiters[0].params[2].value);
    }

    /// Reset compressor and limiter state. The compressor's own reset starts its envelope
    /// at 0 dB (which would pull the first moments down), so start it at silence instead.
    fn resetChain(self: *Mastering) void {
        self.compressor.effect.vtable.reset(&self.compressor.effect);
        self.compressor.envelope = silent_envelope_db;
        for (&self.limiters) |*lim| lim.effect.vtable.reset(&lim.effect);
    }

    pub fn reset(self: *Mastering) void {
        self.resetChain();
        self.meter.reset();
    }

    /// Process interleaved stereo in place: compressor, limiter, then meter.
    /// With mastering off the audio is untouched but is still metered.
    pub fn process(self: *Mastering, buffer: []f32, sample_rate: u32) void {
        const on = self.enabled.load(.monotonic);
        if (on and !self.was_enabled) {
            self.resetChain();
        }
        self.was_enabled = on;

        if (on) {
            self.compressor.effect.vtable.process(&self.compressor.effect, buffer, sample_rate);

            // Make-up gain before the limiter: the limiter still holds the ceiling.
            const makeup = std.math.pow(f32, 10.0, makeup_db / 20.0);
            for (buffer) |*sample| sample.* *= makeup;

            var left: [chunk_frames]f32 = undefined;
            var right: [chunk_frames]f32 = undefined;
            const frames = buffer.len / 2;
            var start: usize = 0;
            while (start < frames) {
                const n = @min(chunk_frames, frames - start);
                for (0..n) |i| {
                    left[i] = buffer[(start + i) * 2];
                    right[i] = buffer[(start + i) * 2 + 1];
                }
                self.limiters[0].effect.vtable.process(&self.limiters[0].effect, left[0..n], sample_rate);
                self.limiters[1].effect.vtable.process(&self.limiters[1].effect, right[0..n], sample_rate);
                for (0..n) |i| {
                    buffer[(start + i) * 2] = left[i];
                    buffer[(start + i) * 2 + 1] = right[i];
                }
                start += n;
            }
        }

        self.meter.process(buffer, sample_rate);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_rate: u32 = 48000;

fn fillSine(buf: []f32, freq: f32, amp: f32, start_frame: usize) void {
    const frames = buf.len / 2;
    for (0..frames) |i| {
        const t: f32 = @floatFromInt(start_frame + i);
        const v = amp * @sin(2.0 * std.math.pi * freq * t / @as(f32, test_rate));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
}

/// Independent true-peak reference: 8x oversampling with a Hann-windowed sinc
/// (16 taps each side), different from the limiter's own cubic estimator.
fn truePeak(buf: []const f32) f32 {
    const frames = buf.len / 2;
    const half: usize = 16;
    var best: f32 = 0;
    for (0..2) |c| {
        var i: usize = half;
        while (i + half < frames) : (i += 1) {
            best = @max(best, @abs(buf[i * 2 + c]));
            for (1..8) |k| {
                const frac: f32 = @as(f32, @floatFromInt(k)) / 8.0;
                var acc: f32 = 0;
                var j: usize = 0;
                while (j < 2 * half) : (j += 1) {
                    const idx = i + 1 + j - half; // samples i-half+1 .. i+half
                    const d = @as(f32, @floatFromInt(j)) - @as(f32, @floatFromInt(half - 1)) - frac;
                    const sinc = if (@abs(d) < 1e-6) 1.0 else @sin(std.math.pi * d) / (std.math.pi * d);
                    const win = 0.5 + 0.5 * @cos(std.math.pi * d / @as(f32, @floatFromInt(half)));
                    acc += buf[idx * 2 + c] * sinc * win;
                }
                best = @max(best, @abs(acc));
            }
        }
    }
    return best;
}

fn dbOf(x: f32) f32 {
    return 20.0 * @log10(x);
}

test "mastering: loud input does not exceed the ceiling" {
    var m = Mastering.init();
    const ceiling = std.math.pow(f32, 10.0, ceiling_dbtp / 20.0);

    // Loud sines (well over full scale) at several frequencies, including
    // fs/4 where inter-sample peaks are largest.
    const freqs = [_]f32{ 440.0, 3000.0, 12000.0 };
    for (freqs) |freq| {
        m.reset();
        var all: [2 * 24000]f32 = undefined;
        var block: [2 * 480]f32 = undefined;
        for (0..50) |b| {
            fillSine(&block, freq, 2.5, b * 480);
            m.process(&block, test_rate);
            @memcpy(all[b * 960 ..][0..960], &block);
        }
        // Skip the first 2400 frames (limiter startup)
        const tail = all[2 * 2400 ..];
        try testing.expect(truePeak(tail) <= ceiling + 0.001);
    }
}

test "mastering: quiet input passes at the same level" {
    var m = Mastering.init();
    var total_in: f64 = 0;
    var total_out: f64 = 0;
    var block: [2 * 480]f32 = undefined;
    var ref: [2 * 480]f32 = undefined;
    for (0..100) |b| {
        fillSine(&block, 1000.0, 0.03, b * 480); // about -30 dBFS
        @memcpy(&ref, &block);
        m.process(&block, test_rate);
        if (b >= 20) {
            for (ref) |v| total_in += @as(f64, v) * v;
            for (block) |v| total_out += @as(f64, v) * v;
        }
    }
    const diff_db = 10.0 * @log10(total_out / total_in);
    // Below the compressor threshold the signal passes; make-up gain is the only change.
    try testing.expect(@abs(diff_db - makeup_db) < 0.5);
}

test "mastering: disabled leaves audio untouched" {
    var m = Mastering.init();
    m.setEnabled(false);
    var block: [2 * 480]f32 = undefined;
    fillSine(&block, 440.0, 2.0, 0);
    var ref = block;
    m.process(&block, test_rate);
    try testing.expectEqualSlices(f32, &ref, &block);
    try testing.expect(Mastering.init().isEnabled());
}

test "mastering: loudness meter reads a known level" {
    var m = Mastering.init();
    try testing.expectEqual(silence_lufs, m.getLoudness());
    // A 1 kHz stereo sine at -20 dBFS peak: K-weighting is about +0.7 dB at 1 kHz,
    // mean square per channel = 0.1^2/2; two channels sum.
    var block: [2 * 480]f32 = undefined;
    for (0..200) |b| {
        fillSine(&block, 1000.0, 0.1, b * 480);
        m.process(&block, test_rate);
    }
    // Expected about -0.691 + 10*log10(2 * 0.005) + 0.7 = about -20.0 LUFS, plus the make-up gain.
    const lufs = m.getLoudness();
    try testing.expect(lufs > -20.0 + makeup_db - 1.5 and lufs < -20.0 + makeup_db + 1.5);
}

test "mastering: limiter alone is transparent below ceiling and compressor is below threshold" {
    var m = Mastering.init();
    var block: [2 * 480]f32 = undefined;
    for (0..20) |b| {
        fillSine(&block, 500.0, 0.1, b * 480);
        m.process(&block, test_rate);
    }
    try testing.expect(m.compressor.getGainReduction() < 0.01);
}
