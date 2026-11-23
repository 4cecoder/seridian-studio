//! High-Quality Audio Resampling
//!
//! Sample rate conversion algorithms:
//! - Linear interpolation (fast, low quality)
//! - Cubic interpolation (faster, medium quality)
//! - Windowed sinc interpolation (slower, high quality)
//! - Polyphase filter implementation
//!
//! Based on public domain algorithms:
//! - Julius O. Smith "Digital Audio Resampling"
//! - libsamplerate (Secret Rabbit Code) concepts
//!
//! Design goals:
//! - Zero-allocation real-time operation
//! - Configurable quality/speed tradeoff
//! - Support for arbitrary rate conversion

const std = @import("std");
const math = std.math;
const core = @import("core.zig");
const dsp = @import("dsp.zig");

// =============================================================================
// Interpolation Quality Levels
// =============================================================================

pub const Quality = enum {
    /// Fastest, lowest quality (linear)
    fastest,

    /// Fast, acceptable quality (cubic)
    fast,

    /// Good quality (8-point sinc)
    good,

    /// High quality (16-point sinc)
    high,

    /// Best quality (32-point sinc)
    best,

    pub fn getKernelSize(self: Quality) usize {
        return switch (self) {
            .fastest => 2,
            .fast => 4,
            .good => 8,
            .high => 16,
            .best => 32,
        };
    }
};

// =============================================================================
// Simple Resamplers (Stateless)
// =============================================================================

/// Resample using linear interpolation (fastest, lowest quality)
pub fn resampleLinear(input: []const f32, output: []f32) void {
    if (input.len == 0 or output.len == 0) return;
    if (input.len == output.len) {
        @memcpy(output, input);
        return;
    }

    const ratio = @as(f32, @floatFromInt(input.len - 1)) / @as(f32, @floatFromInt(output.len - 1));

    for (0..output.len) |i| {
        const src_pos = @as(f32, @floatFromInt(i)) * ratio;
        const src_idx = @as(usize, @intFromFloat(src_pos));
        const frac = src_pos - @as(f32, @floatFromInt(src_idx));

        if (src_idx + 1 < input.len) {
            output[i] = dsp.lerp(input[src_idx], input[src_idx + 1], frac);
        } else {
            output[i] = input[src_idx];
        }
    }
}

/// Resample using linear interpolation with explicit sample rates
/// input_rate: Source sample rate
/// output_rate: Target sample rate
/// Ratio is calculated as output_rate / input_rate
pub fn resampleLinearByRate(input: []const f32, output: []f32, input_rate: u32, output_rate: u32) void {
    if (input.len == 0 or output.len == 0) return;

    // Same rate - just copy
    if (input_rate == output_rate) {
        const copy_len = @min(input.len, output.len);
        @memcpy(output[0..copy_len], input[0..copy_len]);
        return;
    }

    const ratio = @as(f32, @floatFromInt(input_rate)) / @as(f32, @floatFromInt(output_rate));

    for (0..output.len) |i| {
        const src_pos = @as(f32, @floatFromInt(i)) * ratio;
        const src_idx = @as(usize, @intFromFloat(src_pos));
        const frac = src_pos - @as(f32, @floatFromInt(src_idx));

        if (src_idx + 1 < input.len) {
            output[i] = dsp.lerp(input[src_idx], input[src_idx + 1], frac);
        } else {
            output[i] = input[src_idx];
        }
    }
}

/// Resample using cubic interpolation (fast, medium quality)
pub fn resampleCubic(input: []const f32, output: []f32) void {
    if (input.len < 4 or output.len == 0) {
        resampleLinear(input, output);
        return;
    }

    const ratio = @as(f32, @floatFromInt(input.len - 1)) / @as(f32, @floatFromInt(output.len - 1));

    for (0..output.len) |i| {
        const src_pos = @as(f32, @floatFromInt(i)) * ratio;
        const src_idx = @as(usize, @intFromFloat(src_pos));
        const frac = src_pos - @as(f32, @floatFromInt(src_idx));

        // Get 4 samples for cubic interpolation
        const y0 = if (src_idx > 0) input[src_idx - 1] else input[0];
        const y1 = input[src_idx];
        const y2 = if (src_idx + 1 < input.len) input[src_idx + 1] else input[input.len - 1];
        const y3 = if (src_idx + 2 < input.len) input[src_idx + 2] else input[input.len - 1];

        output[i] = core.cubicInterpolate(y0, y1, y2, y3, frac);
    }
}

// =============================================================================
// Windowed Sinc Resampler
// =============================================================================

/// High-quality windowed sinc resampler
pub const SincResampler = struct {
    /// Number of zero crossings on each side
    num_zeros: usize,

    /// Samples per zero crossing (oversampling of kernel)
    samples_per_zero: usize,

    /// Precomputed sinc table
    sinc_table: []f32,

    /// Window function for sinc
    window_type: WindowType = .kaiser,

    /// Kaiser beta parameter
    kaiser_beta: f32 = 6.0,

    allocator: std.mem.Allocator,

    pub const WindowType = enum {
        kaiser,
        blackman,
        hann,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        quality: Quality,
    ) !SincResampler {
        const num_zeros = quality.getKernelSize() / 2;
        const samples_per_zero: usize = 128; // High resolution

        const table_size = num_zeros * samples_per_zero * 2 + 1;
        const sinc_table = try allocator.alloc(f32, table_size);

        var self = SincResampler{
            .num_zeros = num_zeros,
            .samples_per_zero = samples_per_zero,
            .sinc_table = sinc_table,
            .allocator = allocator,
        };

        self.buildTable();

        return self;
    }

    pub fn deinit(self: *SincResampler) void {
        self.allocator.free(self.sinc_table);
    }

    /// Build sinc lookup table
    fn buildTable(self: *SincResampler) void {
        const half_len = self.num_zeros * self.samples_per_zero;
        const center = half_len;

        for (0..self.sinc_table.len) |i| {
            const offset = @as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(center))));
            const x = offset / @as(f32, @floatFromInt(self.samples_per_zero));

            // Sinc function
            var sinc_val: f32 = undefined;
            if (@abs(x) < 1e-6) {
                sinc_val = 1.0;
            } else {
                const px = math.pi * x;
                sinc_val = @sin(px) / px;
            }

            // Window function
            const t = offset / @as(f32, @floatFromInt(half_len));
            const window = switch (self.window_type) {
                .kaiser => kaiserWindow(t, self.kaiser_beta),
                .blackman => blackmanWindow(t),
                .hann => hannWindow(t),
            };

            self.sinc_table[i] = sinc_val * window;
        }
    }

    /// Resample input to output at given ratio
    pub fn resample(self: *const SincResampler, input: []const f32, output: []f32, ratio: f32) void {
        if (input.len == 0 or output.len == 0) return;

        // For upsampling (ratio < 1), use sinc directly
        // For downsampling (ratio > 1), need to widen the filter
        const filter_scale = if (ratio > 1.0) ratio else 1.0;
        const amp_scale = if (ratio > 1.0) 1.0 / ratio else 1.0;

        for (0..output.len) |i| {
            const src_pos = @as(f32, @floatFromInt(i)) * ratio;
            const src_idx = @as(isize, @intFromFloat(src_pos));
            const frac = src_pos - @as(f32, @floatFromInt(src_idx));

            var sum: f32 = 0.0;

            // Convolve with sinc kernel
            const kernel_half = @as(isize, @intCast(self.num_zeros));

            var j: isize = -kernel_half;
            while (j <= kernel_half) : (j += 1) {
                const sample_idx = src_idx + j;

                if (sample_idx >= 0 and sample_idx < input.len) {
                    // Distance from center in filter samples
                    const filter_pos = (@as(f32, @floatFromInt(j)) - frac) * filter_scale;

                    // Look up in sinc table
                    const table_pos = filter_pos * @as(f32, @floatFromInt(self.samples_per_zero)) +
                        @as(f32, @floatFromInt(self.num_zeros * self.samples_per_zero));

                    const sinc_val = self.lookupSinc(table_pos);
                    sum += input[@intCast(sample_idx)] * sinc_val;
                }
            }

            output[i] = sum * amp_scale;
        }
    }

    /// Lookup sinc value with linear interpolation
    fn lookupSinc(self: *const SincResampler, pos: f32) f32 {
        if (pos < 0.0 or pos >= @as(f32, @floatFromInt(self.sinc_table.len - 1))) {
            return 0.0;
        }

        const idx = @as(usize, @intFromFloat(pos));
        const frac = pos - @as(f32, @floatFromInt(idx));

        return self.sinc_table[idx] * (1.0 - frac) + self.sinc_table[idx + 1] * frac;
    }

    /// Resample by sample rate ratio
    pub fn resampleByRate(
        self: *const SincResampler,
        input: []const f32,
        output: []f32,
        input_rate: u32,
        output_rate: u32,
    ) void {
        const ratio = @as(f32, @floatFromInt(input_rate)) / @as(f32, @floatFromInt(output_rate));
        self.resample(input, output, ratio);
    }
};

// =============================================================================
// Streaming Resampler
// =============================================================================

/// Streaming resampler for real-time use
pub const StreamingResampler = struct {
    /// Internal sinc resampler
    sinc: SincResampler,

    /// Ring buffer for input history
    history: []f32,
    history_pos: usize = 0,
    history_filled: bool = false,

    /// Current fractional position
    frac_pos: f32 = 0.0,

    /// Resampling ratio (input_rate / output_rate)
    ratio: f32 = 1.0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, quality: Quality) !StreamingResampler {
        const sinc = try SincResampler.init(allocator, quality);
        const history_size = sinc.num_zeros * 4;
        const history = try allocator.alloc(f32, history_size);
        @memset(history, 0.0);

        return .{
            .sinc = sinc,
            .history = history,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamingResampler) void {
        self.sinc.deinit();
        self.allocator.free(self.history);
    }

    /// Set resampling ratio
    pub fn setRatio(self: *StreamingResampler, input_rate: u32, output_rate: u32) void {
        self.ratio = @as(f32, @floatFromInt(input_rate)) / @as(f32, @floatFromInt(output_rate));
    }

    /// Process a block of input samples, produce output samples
    /// Returns number of output samples produced
    pub fn process(
        self: *StreamingResampler,
        input: []const f32,
        output: []f32,
    ) usize {
        var output_count: usize = 0;

        // Add input to history
        for (input) |sample| {
            self.history[self.history_pos] = sample;
            self.history_pos = (self.history_pos + 1) % self.history.len;

            if (!self.history_filled and self.history_pos == 0) {
                self.history_filled = true;
            }

            // Generate output samples
            while (self.frac_pos < 1.0 and output_count < output.len) {
                if (self.history_filled or self.history_pos > self.sinc.num_zeros) {
                    output[output_count] = self.interpolateSample();
                    output_count += 1;
                }
                self.frac_pos += self.ratio;
            }
            self.frac_pos -= 1.0;
        }

        return output_count;
    }

    /// Interpolate one output sample from history
    fn interpolateSample(self: *StreamingResampler) f32 {
        var sum: f32 = 0.0;
        const kernel_half = @as(isize, @intCast(self.sinc.num_zeros));
        const filter_scale = if (self.ratio > 1.0) self.ratio else 1.0;

        var j: isize = -kernel_half;
        while (j <= kernel_half) : (j += 1) {
            // Calculate position in history buffer
            const hist_offset = @as(isize, @intCast(self.history_pos)) - 1 + j;
            const hist_idx = @mod(hist_offset, @as(isize, @intCast(self.history.len)));

            // Calculate filter position
            const filter_pos = (@as(f32, @floatFromInt(j)) - self.frac_pos) * filter_scale;
            const table_pos = filter_pos * @as(f32, @floatFromInt(self.sinc.samples_per_zero)) +
                @as(f32, @floatFromInt(self.sinc.num_zeros * self.sinc.samples_per_zero));

            const sinc_val = self.sinc.lookupSinc(table_pos);
            sum += self.history[@intCast(hist_idx)] * sinc_val;
        }

        if (self.ratio > 1.0) {
            sum /= self.ratio;
        }

        return sum;
    }

    /// Reset state
    pub fn reset(self: *StreamingResampler) void {
        @memset(self.history, 0.0);
        self.history_pos = 0;
        self.history_filled = false;
        self.frac_pos = 0.0;
    }
};

// =============================================================================
// Window Functions for Sinc
// =============================================================================

/// Kaiser window
fn kaiserWindow(t: f32, beta: f32) f32 {
    if (@abs(t) >= 1.0) return 0.0;

    const arg = beta * @sqrt(1.0 - t * t);
    return core.besselI0(arg) / core.besselI0(beta);
}

/// Blackman window
fn blackmanWindow(t: f32) f32 {
    if (@abs(t) >= 1.0) return 0.0;

    const x = (t + 1.0) * math.pi;
    return 0.42 + 0.5 * @cos(x) + 0.08 * @cos(2.0 * x);
}

/// Hann window
fn hannWindow(t: f32) f32 {
    if (@abs(t) >= 1.0) return 0.0;

    const x = (t + 1.0) * math.pi;
    return 0.5 * (1.0 + @cos(x));
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate output length for given input length and ratio
pub fn calculateOutputLength(input_len: usize, input_rate: u32, output_rate: u32) usize {
    return @as(usize, @intFromFloat(
        @as(f32, @floatFromInt(input_len)) *
            @as(f32, @floatFromInt(output_rate)) /
            @as(f32, @floatFromInt(input_rate)),
    ));
}

/// Common sample rate conversions
pub const SampleRates = struct {
    pub const CD: u32 = 44100;
    pub const DAT: u32 = 48000;
    pub const HD: u32 = 96000;
    pub const DSD: u32 = 192000;
};

// =============================================================================
// Tests
// =============================================================================

test "linear resample" {
    const testing = std.testing;

    var input: [10]f32 = undefined;
    for (0..10) |i| {
        input[i] = @floatFromInt(i);
    }

    // Upsample 2x
    var output: [20]f32 = undefined;
    resampleLinear(&input, &output);

    // First and last should match
    try testing.expectApproxEqAbs(input[0], output[0], 0.001);
    try testing.expectApproxEqAbs(input[9], output[19], 0.001);

    // Endpoints are aligned, so output i maps to input i * 9/19.
    try testing.expectApproxEqAbs(@as(f32, 81.0 / 19.0), output[9], 0.001);
}

test "cubic resample" {
    const testing = std.testing;

    var input: [10]f32 = undefined;
    for (0..10) |i| {
        input[i] = @sin(@as(f32, @floatFromInt(i)) * 0.5);
    }

    var output: [20]f32 = undefined;
    resampleCubic(&input, &output);

    // Should produce smooth output
    try testing.expect(output[0] != 0.0 or output[1] != 0.0);
}

test "sinc resampler init" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sinc = try SincResampler.init(allocator, .good);
    defer sinc.deinit();

    const testing = std.testing;
    try testing.expect(sinc.sinc_table.len > 0);

    // Center of table should be ~1.0 (sinc(0) = 1)
    const center = sinc.sinc_table.len / 2;
    try testing.expectApproxEqAbs(@as(f32, 1.0), sinc.sinc_table[center], 0.01);
}

test "output length calculation" {
    const testing = std.testing;

    // 44100 -> 48000: should increase length
    const out_len = calculateOutputLength(44100, 44100, 48000);
    try testing.expect(out_len > 44100);

    // 48000 -> 44100: should decrease length
    const out_len2 = calculateOutputLength(48000, 48000, 44100);
    try testing.expect(out_len2 < 48000);
}
