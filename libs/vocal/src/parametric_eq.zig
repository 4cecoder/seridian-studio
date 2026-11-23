// Translated to Zig from pitchpure/crates/pitchpure_engine/src/parametric_eq.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Low-latency, voice-oriented parametric EQ with per-band downward dynamics.
//!
//! Each band is a fixed-state RBJ biquad (or a four-section Butterworth
//! high/low pass). Dynamic bands use a pre-filter band-pass detector, so the
//! detector does not chase the band's own gain changes. Parameters are
//! configured outside the sample loop; coefficients and gain move in small
//! sub-blocks to avoid zipper noise. Processing performs no allocation.

const std = @import("std");
const types = @import("types.zig");

const pi: f64 = std.math.pi;

pub const BAND_COUNT: usize = 6;
const SUB_BLOCK: usize = 32;
const FLUSH: f32 = 1e-20;

/// Filter family for one parametric band.
pub const FilterShape = enum {
    bell,
    low_cut,
    high_cut,
    low_shelf,
    high_shelf,
    notch,

    pub const ALL = [6]FilterShape{ .bell, .low_cut, .high_cut, .low_shelf, .high_shelf, .notch };

    pub fn label(self: FilterShape) []const u8 {
        return switch (self) {
            .bell => "Bell",
            .low_cut => "Low cut",
            .high_cut => "High cut",
            .low_shelf => "Low shelf",
            .high_shelf => "High shelf",
            .notch => "Notch",
        };
    }

    fn isCutOrNotch(self: FilterShape) bool {
        return switch (self) {
            .low_cut, .high_cut, .notch => true,
            .bell, .low_shelf, .high_shelf => false,
        };
    }
};

/// User settings for one band. `range_db` is a maximum dynamic cut when the
/// detector rises above `threshold_db`; static gain remains in effect below
/// the threshold.
pub const DynamicEqBand = struct {
    enabled: bool,
    shape: FilterShape,
    frequency_hz: f32,
    gain_db: f32,
    q: f32,
    slope_db_oct: u8,
    dynamic: bool,
    threshold_db: f32,
    range_db: f32,
    attack_ms: f32,
    release_ms: f32,

    /// Six starting points aimed at common vocal cleanup and tone shaping.
    pub fn vocalDefaults() [BAND_COUNT]DynamicEqBand {
        return .{
            .{ .enabled = true, .shape = .low_cut, .frequency_hz = 75.0, .gain_db = 0.0, .q = 0.707, .slope_db_oct = 24, .dynamic = false, .threshold_db = -24.0, .range_db = -6.0, .attack_ms = 8.0, .release_ms = 120.0 },
            .{ .enabled = true, .shape = .bell, .frequency_hz = 180.0, .gain_db = -1.5, .q = 1.0, .slope_db_oct = 12, .dynamic = false, .threshold_db = -24.0, .range_db = -4.0, .attack_ms = 15.0, .release_ms = 180.0 },
            .{ .enabled = false, .shape = .bell, .frequency_hz = 420.0, .gain_db = 0.0, .q = 1.2, .slope_db_oct = 12, .dynamic = false, .threshold_db = -24.0, .range_db = -4.0, .attack_ms = 12.0, .release_ms = 160.0 },
            .{ .enabled = true, .shape = .bell, .frequency_hz = 2800.0, .gain_db = 1.0, .q = 1.0, .slope_db_oct = 12, .dynamic = false, .threshold_db = -24.0, .range_db = -4.0, .attack_ms = 8.0, .release_ms = 120.0 },
            .{ .enabled = true, .shape = .bell, .frequency_hz = 6500.0, .gain_db = 0.0, .q = 2.0, .slope_db_oct = 12, .dynamic = true, .threshold_db = -30.0, .range_db = -6.0, .attack_ms = 4.0, .release_ms = 90.0 },
            .{ .enabled = true, .shape = .high_shelf, .frequency_hz = 12000.0, .gain_db = 1.0, .q = 0.707, .slope_db_oct = 12, .dynamic = false, .threshold_db = -24.0, .range_db = -4.0, .attack_ms = 12.0, .release_ms = 160.0 },
        };
    }

    /// Field-wise equality, matching Rust's derived `PartialEq` (floats by `==`).
    pub fn eql(a: DynamicEqBand, b: DynamicEqBand) bool {
        return a.enabled == b.enabled and
            a.shape == b.shape and
            a.frequency_hz == b.frequency_hz and
            a.gain_db == b.gain_db and
            a.q == b.q and
            a.slope_db_oct == b.slope_db_oct and
            a.dynamic == b.dynamic and
            a.threshold_db == b.threshold_db and
            a.range_db == b.range_db and
            a.attack_ms == b.attack_ms and
            a.release_ms == b.release_ms;
    }

    fn sanitized(self: DynamicEqBand, sample_rate: f32) DynamicEqBand {
        var s = self;
        s.frequency_hz = if (std.math.isFinite(s.frequency_hz))
            std.math.clamp(s.frequency_hz, 20.0, @min(sample_rate * 0.45, 20_000.0))
        else
            1000.0;
        s.gain_db = if (std.math.isFinite(s.gain_db)) std.math.clamp(s.gain_db, -18.0, 18.0) else 0.0;
        s.q = if (std.math.isFinite(s.q)) std.math.clamp(s.q, 0.3, 12.0) else 0.707;
        s.slope_db_oct = switch (s.slope_db_oct) {
            12, 24, 36, 48 => s.slope_db_oct,
            else => 12,
        };
        s.threshold_db = if (std.math.isFinite(s.threshold_db)) std.math.clamp(s.threshold_db, -72.0, 0.0) else -24.0;
        s.range_db = if (std.math.isFinite(s.range_db)) std.math.clamp(s.range_db, -18.0, 0.0) else -6.0;
        s.attack_ms = if (std.math.isFinite(s.attack_ms)) std.math.clamp(s.attack_ms, 0.1, 200.0) else 8.0;
        s.release_ms = if (std.math.isFinite(s.release_ms)) std.math.clamp(s.release_ms, 5.0, 2000.0) else 120.0;
        return s;
    }
};

const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,

    const IDENTITY: Biquad = .{ .b0 = 1.0, .b1 = 0.0, .b2 = 0.0, .a1 = 0.0, .a2 = 0.0, .z1 = 0.0, .z2 = 0.0 };

    fn set(self: *Biquad, b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64) void {
        self.b0 = @floatCast(b0 / a0);
        self.b1 = @floatCast(b1 / a0);
        self.b2 = @floatCast(b2 / a0);
        self.a1 = @floatCast(a1 / a0);
        self.a2 = @floatCast(a2 / a0);
    }

    inline fn tick(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }

    fn clear(self: *Biquad) void {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    fn flush(self: *Biquad) void {
        if (@abs(self.z1) < FLUSH) self.z1 = 0.0;
        if (@abs(self.z2) < FLUSH) self.z2 = 0.0;
    }

    fn responseDb(self: *const Biquad, hz: f32, sample_rate: f32) f32 {
        const w = 2.0 * pi * @as(f64, @max(hz, 1.0)) / @as(f64, @max(sample_rate, 1.0));
        const c = @cos(w);
        const s = -@sin(w);
        const c2 = @cos(2.0 * w);
        const s2 = -@sin(2.0 * w);
        const b0: f64 = self.b0;
        const b1: f64 = self.b1;
        const b2: f64 = self.b2;
        const a1: f64 = self.a1;
        const a2: f64 = self.a2;
        const nr = b0 + b1 * c + b2 * c2;
        const ni = b1 * s + b2 * s2;
        const dr = 1.0 + a1 * c + a2 * c2;
        const di = a1 * s + a2 * s2;
        const numerator = std.math.hypot(nr, ni);
        const denominator = @max(std.math.hypot(dr, di), 1e-15);
        return @floatCast(20.0 * @log10(@max(numerator / denominator, 1e-12)));
    }
};

const Terms = struct { c: f64, s: f64, q: f64 };

const Design = struct {
    sample_rate: f64,

    fn terms(self: *const Design, hz_in: f32, q_in: f32) Terms {
        const hz = std.math.clamp(@as(f64, hz_in), 10.0, self.sample_rate * 0.45);
        const q = std.math.clamp(@as(f64, q_in), 0.3, 12.0);
        const w0 = 2.0 * pi * hz / self.sample_rate;
        return .{ .c = @cos(w0), .s = @sin(w0), .q = q };
    }

    fn bell(self: *const Design, f: *Biquad, hz: f32, q_in: f32, db: f32) void {
        const t = self.terms(hz, q_in);
        const alpha = t.s / (2.0 * t.q);
        const a = std.math.pow(f64, 10.0, @as(f64, db) / 40.0);
        f.set(1.0 + alpha * a, -2.0 * t.c, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * t.c, 1.0 - alpha / a);
    }

    fn notch(self: *const Design, f: *Biquad, hz: f32, q_in: f32) void {
        const t = self.terms(hz, q_in);
        const alpha = t.s / (2.0 * t.q);
        f.set(1.0, -2.0 * t.c, 1.0, 1.0 + alpha, -2.0 * t.c, 1.0 - alpha);
    }

    fn bandpass(self: *const Design, f: *Biquad, hz: f32, q_in: f32) void {
        const t = self.terms(hz, q_in);
        const alpha = t.s / (2.0 * t.q);
        f.set(alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * t.c, 1.0 - alpha);
    }

    fn lowHigh(self: *const Design, f: *Biquad, hz: f32, q_in: f32, high_pass: bool) void {
        const t = self.terms(hz, q_in);
        const c = t.c;
        const alpha = t.s / (2.0 * t.q);
        // f64::midpoint(1.0, c): both operands are small, so (a + b) / 2.
        const half = (1.0 + c) / 2.0;
        if (high_pass) {
            f.set(half, -(1.0 + c), half, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
        } else {
            f.set(half, 1.0 + c, half, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
        }
    }

    fn shelf(self: *const Design, f: *Biquad, hz: f32, q_in: f32, db: f32, high: bool) void {
        const t = self.terms(hz, q_in);
        const c = t.c;
        const a = std.math.pow(f64, 10.0, @as(f64, db) / 40.0);
        const slope = std.math.clamp(1.0 / t.q, 0.2, 2.0);
        const radicand = @max((a + 1.0 / a) * (1.0 / slope - 1.0) + 2.0, 0.0);
        const alpha = t.s * 0.5 * @sqrt(radicand);
        const beta = 2.0 * @sqrt(a) * alpha;
        if (high) {
            f.set(
                a * ((a + 1.0) + (a - 1.0) * c + beta),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * c),
                a * ((a + 1.0) + (a - 1.0) * c - beta),
                (a + 1.0) - (a - 1.0) * c + beta,
                2.0 * ((a - 1.0) - (a + 1.0) * c),
                (a + 1.0) - (a - 1.0) * c - beta,
            );
        } else {
            f.set(
                a * ((a + 1.0) - (a - 1.0) * c + beta),
                2.0 * a * ((a - 1.0) - (a + 1.0) * c),
                a * ((a + 1.0) - (a - 1.0) * c - beta),
                (a + 1.0) + (a - 1.0) * c + beta,
                -2.0 * ((a - 1.0) + (a + 1.0) * c),
                (a + 1.0) + (a - 1.0) * c - beta,
            );
        }
    }

    const Q_12 = [_]f32{std.math.sqrt1_2};
    const Q_24 = [_]f32{ 0.541_196_1, 1.306_563 };
    const Q_36 = [_]f32{ 0.517_638, std.math.sqrt1_2, 1.931_852 };
    const Q_48 = [_]f32{ 0.509_795_6, 0.601_344_9, 0.899_976_2, 2.562_915 };

    fn design(self: *const Design, filters: *[4]Biquad, count: *usize, spec: DynamicEqBand, gain_db: f32) void {
        count.* = 1;
        switch (spec.shape) {
            .bell => self.bell(&filters[0], spec.frequency_hz, spec.q, gain_db),
            .notch => self.notch(&filters[0], spec.frequency_hz, spec.q),
            .low_shelf => self.shelf(&filters[0], spec.frequency_hz, spec.q, gain_db, false),
            .high_shelf => self.shelf(&filters[0], spec.frequency_hz, spec.q, gain_db, true),
            .low_cut, .high_cut => {
                const q_values: []const f32 = switch (spec.slope_db_oct) {
                    24 => &Q_24,
                    36 => &Q_36,
                    48 => &Q_48,
                    else => &Q_12,
                };
                count.* = q_values.len;
                for (filters[0..q_values.len], q_values) |*filter, q| {
                    self.lowHigh(filter, spec.frequency_hz, q, spec.shape == .low_cut);
                }
            },
        }
    }
};

const RuntimeBand = struct {
    settings: DynamicEqBand,
    filters: [4]Biquad,
    filter_count: usize,
    detector: Biquad,
    power: f32,
    dynamic_db: f32,
    effective_db: f32,
    attack: f32,
    release: f32,
    detector_attack: f32,
    detector_release: f32,

    fn init(sample_rate: f32) RuntimeBand {
        return .{
            .settings = .{
                .enabled = false,
                .shape = .bell,
                .frequency_hz = 0.0,
                .gain_db = 0.0,
                .q = 0.707,
                .slope_db_oct = 12,
                .dynamic = false,
                .threshold_db = -24.0,
                .range_db = -6.0,
                .attack_ms = 8.0,
                .release_ms = 120.0,
            },
            .filters = @splat(Biquad.IDENTITY),
            .filter_count = 1,
            .detector = Biquad.IDENTITY,
            .power = 0.0,
            .dynamic_db = 0.0,
            .effective_db = std.math.nan(f32),
            .attack = 1.0 - @exp(-1.0 / (0.008 * sample_rate)),
            .release = 1.0 - @exp(-1.0 / (0.120 * sample_rate)),
            .detector_attack = 1.0 - @exp(-1.0 / (0.004 * sample_rate)),
            .detector_release = 1.0 - @exp(-1.0 / (0.090 * sample_rate)),
        };
    }
};

/// Six-band parametric vocal EQ. Holds no heap memory.
pub const ParametricEq = struct {
    design: Design,
    sample_rate: f32,
    bands: [BAND_COUNT]RuntimeBand,
    counter: usize,
    gain_db_values: [BAND_COUNT]f32,

    pub fn init(sample_rate_hz: types.SampleRateHz) ParametricEq {
        const sample_rate: f32 = @floatFromInt(@max(sample_rate_hz, 8000));
        var eq: ParametricEq = .{
            .design = .{ .sample_rate = sample_rate },
            .sample_rate = sample_rate,
            .bands = @splat(RuntimeBand.init(sample_rate)),
            .counter = 0,
            .gain_db_values = @splat(0.0),
        };
        const defaults = DynamicEqBand.vocalDefaults();
        eq.configure(&defaults);
        return eq;
    }

    /// Update user settings without allocation. Call outside the sample loop.
    pub fn configure(self: *ParametricEq, settings: *const [BAND_COUNT]DynamicEqBand) void {
        for (&self.bands, settings) |*runtime, raw| {
            const spec = raw.sanitized(self.sample_rate);
            if (runtime.settings.eql(spec)) continue;
            const enabled_changed = runtime.settings.enabled != spec.enabled;
            const filter_changed = runtime.settings.shape != spec.shape or
                @abs(runtime.settings.frequency_hz - spec.frequency_hz) > 0.01 or
                @abs(runtime.settings.q - spec.q) > 0.0001 or
                runtime.settings.slope_db_oct != spec.slope_db_oct;
            runtime.settings = spec;
            runtime.attack = 1.0 - @exp(-1.0 / (spec.attack_ms * 0.001 * self.sample_rate));
            runtime.release = 1.0 - @exp(-1.0 / (spec.release_ms * 0.001 * self.sample_rate));
            runtime.detector_attack = 1.0 - @exp(-1.0 / (spec.attack_ms * 0.001 * self.sample_rate));
            runtime.detector_release = 1.0 - @exp(-1.0 / (spec.release_ms * 0.001 * self.sample_rate));
            if (filter_changed or enabled_changed) {
                self.design.design(&runtime.filters, &runtime.filter_count, spec, spec.gain_db);
                self.design.bandpass(&runtime.detector, spec.frequency_hz, spec.q);
                for (&runtime.filters) |*f| f.clear();
                runtime.detector.clear();
                runtime.power = 0.0;
                runtime.dynamic_db = 0.0;
                runtime.effective_db = spec.gain_db;
            }
            if (!spec.dynamic) {
                runtime.power = 0.0;
                runtime.dynamic_db = 0.0;
            }
        }
    }

    /// Current dynamic gain offset per band in dB.
    pub fn gainDb(self: *const ParametricEq) [BAND_COUNT]f32 {
        return self.gain_db_values;
    }

    fn control(self: *ParametricEq) void {
        for (&self.bands, 0..) |*runtime, index| {
            const spec = runtime.settings;
            if (!spec.enabled) {
                self.gain_db_values[index] = 0.0;
                continue;
            }
            if (spec.dynamic) {
                const level_db = 10.0 * @log10(@max(runtime.power, 1e-12));
                const target: f32 = if (level_db > spec.threshold_db)
                    spec.range_db * std.math.clamp((level_db - spec.threshold_db) / 12.0, 0.0, 1.0)
                else
                    0.0;
                const k = if (target < runtime.dynamic_db) runtime.attack else runtime.release;
                runtime.dynamic_db += k * (target - runtime.dynamic_db);
                if (@abs(target - runtime.dynamic_db) < 0.001) runtime.dynamic_db = target;
            } else {
                runtime.dynamic_db = 0.0;
            }
            const gain = spec.gain_db + runtime.dynamic_db;
            // effective_db starts as NaN: |gain - NaN| > 0.01 is false, as in Rust.
            if (!spec.shape.isCutOrNotch() and @abs(gain - runtime.effective_db) > 0.01) {
                runtime.effective_db = gain;
                self.design.design(&runtime.filters, &runtime.filter_count, spec, gain);
            }
            self.gain_db_values[index] = runtime.dynamic_db;
            for (&runtime.filters) |*f| f.flush();
            runtime.detector.flush();
            if (runtime.power < FLUSH) runtime.power = 0.0;
        }
    }

    pub fn reset(self: *ParametricEq) void {
        self.counter = 0;
        self.gain_db_values = @splat(0.0);
        for (&self.bands) |*band| {
            band.power = 0.0;
            band.dynamic_db = 0.0;
            for (&band.filters) |*f| f.clear();
            band.detector.clear();
        }
    }

    /// Processes `min(input.len, output.len)` samples (Rust `zip` semantics).
    pub fn process(self: *ParametricEq, input: []const f32, output: []f32) void {
        const n = @min(input.len, output.len);
        for (input[0..n], output[0..n]) |sample, *out| {
            if (self.counter == 0) self.control();
            self.counter = (self.counter + 1) % SUB_BLOCK;
            const clean: f32 = if (std.math.isFinite(sample)) sample else 0.0;
            var x = clean;
            for (&self.bands) |*band| {
                const spec = band.settings;
                if (!spec.enabled) continue;
                if (spec.dynamic) {
                    const detector = band.detector.tick(clean);
                    const power = detector * detector;
                    const k = if (power > band.power) band.detector_attack else band.detector_release;
                    band.power += k * (power - band.power);
                }
                for (band.filters[0..band.filter_count]) |*filter| {
                    x = filter.tick(x);
                }
            }
            out.* = x;
        }
    }
};

/// Exact magnitude response for a band, used by the editor's response graph.
pub fn bandResponseDb(spec_in: DynamicEqBand, sample_rate: f32, hz: f32, dynamic_db: f32) f32 {
    const spec = spec_in.sanitized(@max(sample_rate, 8000.0));
    const design: Design = .{ .sample_rate = @max(sample_rate, 8000.0) };
    var filters: [4]Biquad = @splat(Biquad.IDENTITY);
    var count: usize = 1;
    const gain: f32 = if (spec.shape.isCutOrNotch())
        0.0
    else
        spec.gain_db + std.math.clamp(dynamic_db, -18.0, 0.0);
    design.design(&filters, &count, spec, gain);
    var sum: f32 = 0.0;
    for (filters[0..count]) |*f| sum += f.responseDb(hz, sample_rate);
    return sum;
}

comptime {
    types.assertProcessor(ParametricEq);
}

// The Rust file has no #[cfg(test)] tests. The tests below are Seridian
// additions that only pin basic behaviour.

test "parametric_eq: flat bell is transparent and output stays finite" {
    var eq = ParametricEq.init(48_000);
    var bands = DynamicEqBand.vocalDefaults();
    for (&bands) |*b| b.enabled = false;
    eq.configure(&bands);
    const input = [_]f32{ 0.5, -0.25, 0.125, std.math.nan(f32), 1.0 };
    var output: [5]f32 = undefined;
    eq.process(&input, &output);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -0.25, 0.125, 0.0, 1.0 }, &output);

    eq = ParametricEq.init(48_000);
    var buf: [4096]f32 = undefined;
    var sig: [4096]f32 = undefined;
    for (&sig, 0..) |*s, i| s.* = 0.5 * @sin(2.0 * std.math.pi * 6500.0 * @as(f32, @floatFromInt(i)) / 48_000.0);
    eq.process(&sig, &buf);
    for (buf) |s| try std.testing.expect(std.math.isFinite(s));
    try std.testing.expect(eq.gainDb()[4] < 0.0);
}

test "parametric_eq: band response of a 6 dB bell at its centre" {
    var spec = DynamicEqBand.vocalDefaults()[1];
    spec.gain_db = 6.0;
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), bandResponseDb(spec, 48_000.0, 180.0, 0.0), 0.01);
    const low_cut = DynamicEqBand.vocalDefaults()[0];
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), bandResponseDb(low_cut, 48_000.0, 75.0, 0.0), 0.1);
}
