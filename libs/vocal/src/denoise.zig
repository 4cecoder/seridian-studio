// Translated to Zig from pitchpure/crates/pitchpure_engine/src/denoise.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Spectral noise reduction: steady background noise out, voice kept.
//!
//! Clean-room implementation of textbook STFT denoising:
//!
//! * **Analysis/synthesis**: sqrt-Hann windows on both sides, 75 % overlap
//!   (hop = N/4), weighted overlap-add. The squared windows overlap-add to
//!   a constant, so with unity gains the chain reconstructs its input.
//! * **Noise estimate**: either a *learned profile* (the mean power
//!   spectrum over frames recorded between `SpectralDenoiser.startLearning`
//!   and `SpectralDenoiser.stopLearning`) or, without one, *minimum
//!   statistics* (Martin, 2001): the per-bin minimum of a recursively
//!   smoothed periodogram over ~1.5 s, tracked with sub-window minima and
//!   bias-compensated toward the mean.
//! * **Gain**: Wiener gain `ξ/(1+ξ)` from the decision-directed a-priori
//!   SNR (Ephraim & Malah, 1984), floored at `-reduction_db` so noise is
//!   turned down rather than gated.
//! * **Musical-noise control**: 3-bin smoothing across frequency, then a
//!   per-bin attack/release follower across time (gains rise fast, fall
//!   slowly).
//!
//! Latency is constant: `latencySamples` is always the FFT length, whatever
//! the reduction setting. At `reduction_db == 0` the output crossfades to a
//! pure delay line of the same length, so it is bit-exact delayed input, and
//! switching reduction on/off never shifts timing (the crossfade takes one
//! hop). Analysis keeps running at 0 dB so learning and
//! `SpectralDenoiser.noiseFloorDb` still work.
//!
//! Processing is per sample internally, so any block size gives identical
//! output. Every buffer is allocated in `SpectralDenoiser.init`; `process`
//! and `reset` never allocate.

const std = @import("std");
const types = @import("types.zig");

const pi: f32 = std.math.pi;

/// FFT length at 48 kHz; scaled with the rate to keep ~43 ms frames.
const base_fft: usize = 2048;
const base_rate: f32 = 48_000.0;
const min_fft: usize = 512;
const max_fft: usize = 8192;
/// Maximum reduction in dB.
const max_reduction_db: f32 = 40.0;
/// Periodogram smoothing for minimum statistics.
const psd_smooth: f32 = 0.85;
/// Minimum-statistics window length in seconds (split into sub-windows).
const minstat_seconds: f32 = 1.5;
const minstat_subwindows: usize = 8;
/// Minimum of a smoothed periodogram underestimates the noise mean.
const minstat_bias: f32 = 1.8;
/// Decision-directed weighting of the previous clean estimate.
const dd_alpha: f32 = 0.98;
/// Per-frame gain followers: rising (attack) and falling (release).
const gain_attack: f32 = 0.3;
const gain_release: f32 = 0.75;
/// Floors keep divisions and logs finite.
const eps: f32 = 1e-12;
const f32_max: f32 = std.math.floatMax(f32);

/// STFT spectral denoiser with learnable or adaptive noise profile.
///
/// Owns `storage` (every f32 buffer below is a slice of it) and `bitrev`;
/// free both with `deinit`.
pub const SpectralDenoiser = struct {
    n: usize,
    hop: usize,
    half: usize,
    storage: []f32,
    window: []f32,
    /// `1 / Σ window²` over overlapping frames (constant for sqrt-Hann).
    ola_norm: f32,
    /// `Σ window²` within one frame: converts bin power to sample variance.
    frame_energy: f32,
    // FFT plan.
    bitrev: []usize,
    tw_re: []f32,
    tw_im: []f32,
    re: []f32,
    im: []f32,
    // Streaming state.
    in_buf: []f32,
    ola: []f32,
    out_hop: []f32,
    pending: usize,
    delay: []f32,
    delay_pos: usize,
    wet: f32,
    // Spectral state (len = half).
    power: []f32,
    smoothed: []f32,
    cur_min: []f32,
    sub_mins: []f32,
    sub_frames: usize,
    sub_index: usize,
    sub_filled: usize,
    frames_seen: usize,
    noise: []f32,
    profile: []f32,
    learn_sum: []f32,
    learn_frames: usize,
    learning: bool,
    has_profile: bool,
    prev_clean: []f32,
    gain: []f32,
    gain_smooth: []f32,
    // Controls.
    reduction_db: f32,
    gain_floor: f32,
    noise_scale: f32,

    /// Build a denoiser for `sample_rate` (FFT ≈ 2048 at 48 kHz).
    pub fn init(gpa: std.mem.Allocator, sample_rate: types.SampleRateHz) !SpectralDenoiser {
        const rate: f32 = @floatFromInt(@max(sample_rate, 8_000));
        const target: usize = @intFromFloat(@as(f32, @floatFromInt(base_fft)) * rate / base_rate);
        const n = std.math.clamp(std.math.ceilPowerOfTwoAssert(usize, @max(target, 1)), min_fft, max_fft);
        const hop = n / 4;
        const half = n / 2 + 1;
        const nf: f32 = @floatFromInt(n);

        const total_f32 = n + // window
            n / 2 + n / 2 + // twiddles
            n + n + // re, im
            n + n + hop + n + // in_buf, ola, out_hop, delay
            half * (9 + minstat_subwindows); // spectral state
        const storage = try gpa.alloc(f32, total_f32);
        errdefer gpa.free(storage);
        const bitrev = try gpa.alloc(usize, n);
        errdefer gpa.free(bitrev);

        var off: usize = 0;
        const take = struct {
            fn f(s: []f32, o: *usize, len: usize, fill: f32) []f32 {
                const out = s[o.* .. o.* + len];
                o.* += len;
                @memset(out, fill);
                return out;
            }
        }.f;

        // Periodic sqrt-Hann: w² is a periodic Hann, which overlap-adds to
        // a constant 2.0 at 75 % overlap.
        const window = take(storage, &off, n, 0.0);
        for (window, 0..) |*w, i| {
            w.* = @sqrt(0.5 - 0.5 * @cos(2.0 * pi * @as(f32, @floatFromInt(i)) / nf));
        }
        var frame_energy: f32 = 0.0;
        for (window) |w| frame_energy += w * w;
        const ola_norm = @as(f32, @floatFromInt(hop)) / frame_energy;

        const bits: u32 = @ctz(n);
        const shift: u6 = @intCast(@bitSizeOf(usize) - bits);
        for (bitrev, 0..) |*b, i| b.* = @bitReverse(i) >> shift;
        const tw_re = take(storage, &off, n / 2, 0.0);
        for (tw_re, 0..) |*t, k| t.* = @cos(-2.0 * pi * @as(f32, @floatFromInt(k)) / nf);
        const tw_im = take(storage, &off, n / 2, 0.0);
        for (tw_im, 0..) |*t, k| t.* = @sin(-2.0 * pi * @as(f32, @floatFromInt(k)) / nf);

        const frames_per_sec = rate / @as(f32, @floatFromInt(hop));
        const total: usize = @intFromFloat(@round(minstat_seconds * frames_per_sec));
        const sub_frames = @max(total / minstat_subwindows, 1);

        var me: SpectralDenoiser = .{
            .n = n,
            .hop = hop,
            .half = half,
            .storage = storage,
            .window = window,
            .ola_norm = ola_norm,
            .frame_energy = frame_energy,
            .bitrev = bitrev,
            .tw_re = tw_re,
            .tw_im = tw_im,
            .re = take(storage, &off, n, 0.0),
            .im = take(storage, &off, n, 0.0),
            .in_buf = take(storage, &off, n, 0.0),
            .ola = take(storage, &off, n, 0.0),
            .out_hop = take(storage, &off, hop, 0.0),
            .pending = 0,
            .delay = take(storage, &off, n, 0.0),
            .delay_pos = 0,
            .wet = 0.0,
            .power = take(storage, &off, half, 0.0),
            .smoothed = take(storage, &off, half, 0.0),
            .cur_min = take(storage, &off, half, f32_max),
            .sub_mins = take(storage, &off, half * minstat_subwindows, f32_max),
            .sub_frames = sub_frames,
            .sub_index = 0,
            .sub_filled = 0,
            .frames_seen = 0,
            .noise = take(storage, &off, half, eps),
            .profile = take(storage, &off, half, eps),
            .learn_sum = take(storage, &off, half, 0.0),
            .learn_frames = 0,
            .learning = false,
            .has_profile = false,
            .prev_clean = take(storage, &off, half, 0.0),
            .gain = take(storage, &off, half, 1.0),
            .gain_smooth = take(storage, &off, half, 1.0),
            .reduction_db = 0.0,
            .gain_floor = 1.0,
            .noise_scale = 1.0,
        };
        std.debug.assert(off == storage.len);
        me.setSensitivity(0.5);
        return me;
    }

    pub fn deinit(self: *SpectralDenoiser, gpa: std.mem.Allocator) void {
        gpa.free(self.storage);
        gpa.free(self.bitrev);
        self.* = undefined;
    }

    /// Maximum noise attenuation, `0..=40` dB. `0` = transparent.
    pub fn setReductionDb(self: *SpectralDenoiser, db_in: f32) void {
        const db = if (std.math.isFinite(db_in)) std.math.clamp(db_in, 0.0, max_reduction_db) else 0.0;
        self.reduction_db = db;
        self.gain_floor = std.math.pow(f32, 10.0, -db / 20.0);
    }

    /// Current reduction in dB.
    pub fn getReductionDb(self: *const SpectralDenoiser) f32 {
        return self.reduction_db;
    }

    /// `0..=1`: how far above the noise estimate a bin must rise to count
    /// as signal. Scales the noise estimate from -6 dB (gentle) to +6 dB
    /// (aggressive); `0.5` uses it as is.
    pub fn setSensitivity(self: *SpectralDenoiser, s_in: f32) void {
        const s = if (std.math.isFinite(s_in)) std.math.clamp(s_in, 0.0, 1.0) else 0.5;
        self.noise_scale = std.math.pow(f32, 10.0, (s * 12.0 - 6.0) / 10.0);
    }

    /// Start averaging the incoming spectrum as the noise profile. Feed it
    /// noise only (no voice) until `stopLearning`.
    pub fn startLearning(self: *SpectralDenoiser) void {
        @memset(self.learn_sum, 0.0);
        self.learn_frames = 0;
        self.learning = true;
    }

    /// Freeze the learned profile. With no frames learned, nothing changes.
    pub fn stopLearning(self: *SpectralDenoiser) void {
        if (self.learning and self.learn_frames > 0) {
            const inv = 1.0 / @as(f32, @floatFromInt(self.learn_frames));
            for (self.profile, self.learn_sum) |*p, s| p.* = @max(s * inv, eps);
            self.has_profile = true;
        }
        self.learning = false;
    }

    pub fn isLearning(self: *const SpectralDenoiser) bool {
        return self.learning;
    }

    pub fn hasProfile(self: *const SpectralDenoiser) bool {
        return self.has_profile;
    }

    /// Forget the learned profile and go back to adaptive tracking.
    pub fn clearProfile(self: *SpectralDenoiser) void {
        self.has_profile = false;
        self.learning = false;
        @memset(self.profile, eps);
    }

    /// Broadband noise estimate as an RMS level in dBFS.
    pub fn noiseFloorDb(self: *const SpectralDenoiser) f32 {
        const src = if (self.has_profile) self.profile else self.noise;
        // Parseval over the one-sided spectrum: mean bin power / Σw² is the
        // per-sample variance for white noise.
        var sum: f32 = 0.0;
        for (src) |v| sum += v;
        const mean = sum / @as(f32, @floatFromInt(self.half));
        return 10.0 * std.math.log10(@max(mean / self.frame_energy, eps));
    }

    fn fft(self: *SpectralDenoiser, inverse: bool) void {
        const n = self.n;
        for (0..n) |i| {
            const j = self.bitrev[i];
            if (j > i) {
                std.mem.swap(f32, &self.re[i], &self.re[j]);
                std.mem.swap(f32, &self.im[i], &self.im[j]);
            }
        }
        const sign: f32 = if (inverse) -1.0 else 1.0;
        var len: usize = 2;
        while (len <= n) : (len <<= 1) {
            const step = n / len;
            var start: usize = 0;
            while (start < n) : (start += len) {
                for (0..len / 2) |k| {
                    const wr = self.tw_re[k * step];
                    const wi = sign * self.tw_im[k * step];
                    const a = start + k;
                    const b = a + len / 2;
                    const xr = self.re[b] * wr - self.im[b] * wi;
                    const xi = self.re[b] * wi + self.im[b] * wr;
                    self.re[b] = self.re[a] - xr;
                    self.im[b] = self.im[a] - xi;
                    self.re[a] += xr;
                    self.im[a] += xi;
                }
            }
        }
    }

    fn trackNoise(self: *SpectralDenoiser) void {
        self.frames_seen += 1;
        const first = self.frames_seen == 1;
        for (0..self.half) |k| {
            const s = if (first)
                self.power[k]
            else
                psd_smooth * self.smoothed[k] + (1.0 - psd_smooth) * self.power[k];
            self.smoothed[k] = s;
            self.cur_min[k] = @min(self.cur_min[k], s);
        }
        const sub_count = self.frames_seen % self.sub_frames;
        if (sub_count == 0) {
            const base = self.sub_index * self.half;
            @memcpy(self.sub_mins[base .. base + self.half], self.cur_min);
            self.sub_index = (self.sub_index + 1) % minstat_subwindows;
            self.sub_filled = @min(self.sub_filled + 1, minstat_subwindows);
            @memcpy(self.cur_min, self.smoothed);
        }
        for (0..self.half) |k| {
            var m = self.cur_min[k];
            for (0..self.sub_filled) |w| {
                m = @min(m, self.sub_mins[w * self.half + k]);
            }
            self.noise[k] = @max(m * minstat_bias, eps);
        }
    }

    fn processFrame(self: *SpectralDenoiser) void {
        const n = self.n;
        for (0..n) |i| {
            self.re[i] = self.in_buf[i] * self.window[i];
            self.im[i] = 0.0;
        }
        self.fft(false);
        for (0..self.half) |k| {
            self.power[k] = self.re[k] * self.re[k] + self.im[k] * self.im[k];
        }
        if (self.learning) {
            for (self.learn_sum, self.power) |*s, p| s.* += p;
            self.learn_frames += 1;
        }
        self.trackNoise();

        // Wiener gain from the decision-directed a-priori SNR.
        const scale = self.noise_scale;
        for (0..self.half) |k| {
            const base = if (self.has_profile) self.profile[k] else self.noise[k];
            const lambda = @max(base * scale, eps);
            const post = self.power[k] / lambda;
            const prio = dd_alpha * self.prev_clean[k] / lambda + (1.0 - dd_alpha) * @max(post - 1.0, 0.0);
            const g = prio / (1.0 + prio);
            self.gain[k] = @max(g, self.gain_floor);
        }
        // Smooth across frequency (3 bins), then across time.
        var prev = self.gain[0];
        for (0..self.half) |k| {
            const next = if (k + 1 < self.half) self.gain[k + 1] else self.gain[k];
            const cur = self.gain[k];
            const g = (prev + 2.0 * cur + next) * 0.25;
            prev = cur;
            const held = self.gain_smooth[k];
            const c = if (g > held) gain_attack else gain_release;
            const s = @min(@max(c * held + (1.0 - c) * g, self.gain_floor), 1.0);
            self.gain_smooth[k] = s;
            self.prev_clean[k] = s * s * self.power[k];
        }
        for (0..self.half) |k| {
            const g = self.gain_smooth[k];
            self.re[k] *= g;
            self.im[k] *= g;
            if (k > 0 and k < n / 2) {
                self.re[n - k] = self.re[k];
                self.im[n - k] = -self.im[k];
            }
        }
        self.fft(true);
        const inv_n = 1.0 / @as(f32, @floatFromInt(n));
        for (0..n) |i| {
            self.ola[i] += self.re[i] * inv_n * self.window[i];
        }
        for (0..self.hop) |i| {
            self.out_hop[i] = self.ola[i] * self.ola_norm;
        }
        const tail = n - self.hop;
        std.mem.copyForwards(f32, self.ola[0..tail], self.ola[self.hop..]);
        @memset(self.ola[tail..], 0.0);
        std.mem.copyForwards(f32, self.in_buf[0..tail], self.in_buf[self.hop..]);
    }

    pub fn reset(self: *SpectralDenoiser) void {
        @memset(self.in_buf, 0.0);
        @memset(self.ola, 0.0);
        @memset(self.out_hop, 0.0);
        self.pending = 0;
        @memset(self.delay, 0.0);
        self.delay_pos = 0;
        self.wet = if (self.reduction_db > 0.0) 1.0 else 0.0;
        @memset(self.smoothed, 0.0);
        @memset(self.cur_min, f32_max);
        @memset(self.sub_mins, f32_max);
        self.sub_index = 0;
        self.sub_filled = 0;
        self.frames_seen = 0;
        @memset(self.noise, eps);
        @memset(self.prev_clean, 0.0);
        @memset(self.gain, 1.0);
        @memset(self.gain_smooth, 1.0);
        // The learned profile and controls survive a reset on purpose.
    }

    pub fn process(self: *SpectralDenoiser, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);
        const target: f32 = if (self.reduction_db > 0.0) 1.0 else 0.0;
        const ramp = 1.0 / @as(f32, @floatFromInt(self.hop));
        const tail = self.n - self.hop;
        const len = @min(input.len, output.len);
        for (input[0..len], output[0..len]) |x_in, *y| {
            const x = if (std.math.isFinite(x_in)) x_in else 0.0;
            // Dry path: pure delay of exactly `n` samples.
            const dry = self.delay[self.delay_pos];
            self.delay[self.delay_pos] = x;
            self.delay_pos = (self.delay_pos + 1) % self.n;
            // Wet path: WOLA output, also `n` samples late.
            const wet = self.out_hop[self.pending];
            self.in_buf[tail + self.pending] = x;
            self.pending += 1;
            if (self.pending == self.hop) {
                self.pending = 0;
                self.processFrame();
            }
            if (self.wet < target) {
                self.wet = @min(self.wet + ramp, 1.0);
            } else if (self.wet > target) {
                self.wet = @max(self.wet - ramp, 0.0);
            }
            y.* = if (self.wet == 0.0)
                dry
            else if (self.wet == 1.0)
                wet
            else
                dry + (wet - dry) * self.wet;
        }
    }

    pub fn latencySamples(self: *const SpectralDenoiser) usize {
        return self.n;
    }
};

comptime {
    types.assertProcessor(SpectralDenoiser);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_rate: u32 = 48_000;

const TestRng = struct {
    state: u64,

    fn uniform(self: *TestRng) f32 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        return @as(f32, @floatFromInt(self.state >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }

    fn gauss(self: *TestRng) f32 {
        const u_1 = @max(self.uniform(), 1e-7);
        const u_2 = self.uniform();
        return @sqrt(-2.0 * @log(u_1)) * @cos(2.0 * pi * u_2);
    }
};

fn testNoise(gpa: std.mem.Allocator, len: usize, std_dev: f32, seed: u64) ![]f32 {
    var rng: TestRng = .{ .state = seed };
    const v = try gpa.alloc(f32, len);
    for (v) |*s| s.* = rng.gauss() * std_dev;
    return v;
}

fn testSine(gpa: std.mem.Allocator, len: usize, amp: f32, hz: f32) ![]f32 {
    const v = try gpa.alloc(f32, len);
    for (v, 0..) |*s, i| {
        s.* = amp * @sin(2.0 * pi * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_rate)));
    }
    return v;
}

/// Voice-like test melody: 250 ms notes, 150 ms rests, 10 ms fades.
/// (A constant tone is indistinguishable from stationary noise for
/// adaptive tracking, exactly as in any minimum-statistics denoiser.)
fn melody(gpa: std.mem.Allocator, len: usize, amp: f32) ![]f32 {
    const note: usize = test_rate / 4;
    const rest: usize = test_rate * 3 / 20;
    const fade: usize = test_rate / 100;
    const pitches = [_]f32{ 220.0, 247.0, 262.0, 294.0, 330.0 };
    var phase: f32 = 0.0;
    const v = try gpa.alloc(f32, len);
    for (v, 0..) |*s, i| {
        const slot = i / (note + rest);
        const t = i % (note + rest);
        const hz = pitches[slot % pitches.len];
        phase = @rem(phase + 2.0 * pi * hz / @as(f32, @floatFromInt(test_rate)), 2.0 * pi);
        if (t >= note) {
            s.* = 0.0;
            continue;
        }
        const env = @min(@as(f32, @floatFromInt(@min(t, note - t))) / @as(f32, @floatFromInt(fade)), 1.0);
        s.* = amp * env * @sin(phase);
    }
    return v;
}

fn testRun(gpa: std.mem.Allocator, d: *SpectralDenoiser, input: []const f32, block: usize) ![]f32 {
    const out = try gpa.alloc(f32, input.len);
    @memset(out, 0.0);
    var off: usize = 0;
    while (off < input.len) : (off += block) {
        const end = @min(off + block, input.len);
        d.process(input[off..end], out[off..end]);
    }
    return out;
}

fn power(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |v| sum += v * v;
    return sum / @as(f32, @floatFromInt(x.len));
}

/// SNR of `out` against `clean` delayed by `lat`, over `start..end` of `out`.
fn snrDb(out: []const f32, clean: []const f32, lat: usize, start: usize, end: usize) f32 {
    var sig: f32 = 0.0;
    var err: f32 = 0.0;
    for (start..end) |i| {
        const c = clean[i - lat];
        sig += c * c;
        err += (out[i] - c) * (out[i] - c);
    }
    return 10.0 * std.math.log10(sig / err);
}

/// Amplitude of the `hz` component of `x` (quadrature projection).
fn toneAmp(x: []const f32, hz: f32, offset: usize) f32 {
    var s: f64 = 0.0;
    var c: f64 = 0.0;
    for (x, 0..) |v, i| {
        const ph = 2.0 * std.math.pi * @as(f64, hz) * @as(f64, @floatFromInt(i + offset)) / @as(f64, @floatFromInt(test_rate));
        s += @as(f64, v) * @sin(ph);
        c += @as(f64, v) * @cos(ph);
    }
    return @floatCast(2.0 * @sqrt(s * s + c * c) / @as(f64, @floatFromInt(x.len)));
}

test "zero_reduction_is_exact_delay" {
    const gpa = testing.allocator;
    var d = try SpectralDenoiser.init(gpa, test_rate);
    defer d.deinit(gpa);
    const lat = d.latencySamples();
    try testing.expectEqual(@as(usize, 2048), lat);
    const x = try testNoise(gpa, test_rate, 0.2, 7);
    defer gpa.free(x);
    const y = try testRun(gpa, &d, x, 333);
    defer gpa.free(y);
    for (0..x.len) |i| {
        const want: f32 = if (i >= lat) x[i - lat] else 0.0;
        try testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(y[i])));
    }
    d.setReductionDb(30.0);
    // Latency must not depend on reduction.
    try testing.expectEqual(lat, d.latencySamples());
}

test "unity_gain_wola_reconstructs" {
    // Reduction on, but a huge "signal" vs a tiny learned noise floor:
    // gains sit at 1, so the STFT path itself must be transparent.
    const gpa = testing.allocator;
    var d = try SpectralDenoiser.init(gpa, test_rate);
    defer d.deinit(gpa);
    d.startLearning();
    const zeros = try gpa.alloc(f32, 8192);
    defer gpa.free(zeros);
    @memset(zeros, 0.0);
    const learn_out = try testRun(gpa, &d, zeros, 512);
    gpa.free(learn_out);
    d.stopLearning();
    d.reset();
    d.setReductionDb(20.0);
    const x = try testSine(gpa, test_rate, 0.5, 440.0);
    defer gpa.free(x);
    const y = try testRun(gpa, &d, x, 512);
    defer gpa.free(y);
    const lat = d.latencySamples();
    const snr = snrDb(y, x, lat, 8192, x.len);
    try testing.expect(snr > 60.0);
}

test "learned_profile_improves_snr" {
    const gpa = testing.allocator;
    var d = try SpectralDenoiser.init(gpa, test_rate);
    defer d.deinit(gpa);
    const len: usize = 3 * test_rate;
    const n = try testNoise(gpa, len, 0.05, 11);
    defer gpa.free(n);
    d.startLearning();
    const learn_out = try testRun(gpa, &d, n[0..test_rate], 512);
    gpa.free(learn_out);
    d.stopLearning();
    try testing.expect(d.hasProfile());
    const floor = d.noiseFloorDb();
    try testing.expect(@abs(floor - 20.0 * std.math.log10(@as(f32, 0.05))) < 1.5);

    d.reset();
    d.setReductionDb(30.0);
    const clean = try testSine(gpa, len, 0.3, 220.0);
    defer gpa.free(clean);
    const mixed = try gpa.alloc(f32, len);
    defer gpa.free(mixed);
    for (mixed, clean, n) |*m, a, b| m.* = a + b;
    const out = try testRun(gpa, &d, mixed, 512);
    defer gpa.free(out);
    const lat = d.latencySamples();
    const start: usize = test_rate;
    const end: usize = len;
    const snr_in = 10.0 * std.math.log10(power(clean[start..end]) / power(n[start..end]));
    const snr_out = snrDb(out, clean, lat, start, end);
    const amp_in = toneAmp(clean[start - lat .. end - lat], 220.0, start - lat);
    const amp_out = toneAmp(out[start..end], 220.0, start - lat);
    const tone_db = 20.0 * std.math.log10(amp_out / amp_in);
    try testing.expect(snr_out - snr_in >= 10.0);
    try testing.expect(@abs(tone_db) <= 2.0);
}

test "adaptive_tracking_improves_snr" {
    const gpa = testing.allocator;
    var d = try SpectralDenoiser.init(gpa, test_rate);
    defer d.deinit(gpa);
    d.setReductionDb(30.0);
    const len: usize = 3 * test_rate;
    const n = try testNoise(gpa, len, 0.05, 23);
    defer gpa.free(n);
    const clean = try melody(gpa, len, 0.3);
    defer gpa.free(clean);
    const mixed = try gpa.alloc(f32, len);
    defer gpa.free(mixed);
    for (mixed, clean, n) |*m, a, b| m.* = a + b;
    const out = try testRun(gpa, &d, mixed, 1024);
    defer gpa.free(out);
    const lat = d.latencySamples();
    const start: usize = 2 * test_rate;
    const snr_in = 10.0 * std.math.log10(power(clean[start..len]) / power(n[start..len]));
    const snr_out = snrDb(out, clean, lat, start, len);
    try testing.expect(snr_out - snr_in >= 6.0);
}

test "block_size_does_not_matter" {
    const gpa = testing.allocator;
    const s = try testSine(gpa, test_rate, 0.3, 300.0);
    defer gpa.free(s);
    const nz = try testNoise(gpa, test_rate, 0.05, 5);
    defer gpa.free(nz);
    const x = try gpa.alloc(f32, test_rate);
    defer gpa.free(x);
    for (x, s, nz) |*v, a, b| v.* = a + b;
    var d_ref = try SpectralDenoiser.init(gpa, test_rate);
    defer d_ref.deinit(gpa);
    d_ref.setReductionDb(25.0);
    const reference = try testRun(gpa, &d_ref, x, 1);
    defer gpa.free(reference);
    for ([_]usize{ 37, 512, 1024 }) |block| {
        var d = try SpectralDenoiser.init(gpa, test_rate);
        defer d.deinit(gpa);
        d.setReductionDb(25.0);
        const y = try testRun(gpa, &d, x, block);
        defer gpa.free(y);
        for (y, reference) |a, b| {
            try testing.expectEqual(@as(u32, @bitCast(b)), @as(u32, @bitCast(a)));
        }
    }
}

test "fft_size_scales_with_rate" {
    const gpa = testing.allocator;
    const cases = [_][2]usize{ .{ 44_100, 2048 }, .{ 96_000, 4096 }, .{ 16_000, 1024 } };
    for (cases) |c| {
        var d = try SpectralDenoiser.init(gpa, @intCast(c[0]));
        defer d.deinit(gpa);
        try testing.expectEqual(c[1], d.latencySamples());
    }
}

test "cpu_cost_report" {
    // The Rust test only times the loop and prints the cost (no assertion).
    // Libraries do not read clocks or print, so this runs the same workload
    // and checks nothing beyond completing without a panic.
    const gpa = testing.allocator;
    var d = try SpectralDenoiser.init(gpa, test_rate);
    defer d.deinit(gpa);
    d.setReductionDb(30.0);
    const x = try testNoise(gpa, test_rate * 4, 0.1, 3);
    defer gpa.free(x);
    const y = try testRun(gpa, &d, x, 1024);
    defer gpa.free(y);
}
