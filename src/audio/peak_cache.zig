// =============================================================================
// Waveform Peak Cache
// =============================================================================
// Pre-computes min/max peaks for audio data at various zoom levels.
// Used for efficient waveform rendering in the timeline.

const std = @import("std");
const log = std.log.scoped(.peak_cache);

/// Peak data for a single column (pixel)
pub const Peak = struct {
    min: f32,
    max: f32,
};

/// Multi-resolution peak cache
/// Stores peaks at different resolutions for efficient zooming
pub const PeakCache = struct {
    allocator: std.mem.Allocator,

    /// Original audio data reference
    samples: []const f32,
    num_channels: u8,
    sample_rate: u32,

    /// Pre-computed peaks at base resolution
    /// Each peak represents samples_per_peak samples
    peaks: []Peak,
    samples_per_peak: u32,

    /// Total number of audio frames
    total_frames: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        samples: []const f32,
        num_channels: u8,
        sample_rate: u32,
    ) !PeakCache {
        const total_frames = samples.len / num_channels;

        // Base resolution: ~100 peaks per second of audio
        // This gives good detail while being efficient
        const peaks_per_second: u32 = 100;
        const samples_per_peak = sample_rate / peaks_per_second;
        const num_peaks = (total_frames + samples_per_peak - 1) / samples_per_peak;

        var peaks = try allocator.alloc(Peak, num_peaks);
        errdefer allocator.free(peaks);

        // Compute peaks
        var peak_idx: usize = 0;
        var sample_idx: usize = 0;

        while (peak_idx < num_peaks) : (peak_idx += 1) {
            var min_val: f32 = 1.0;
            var max_val: f32 = -1.0;

            const end_sample = @min(sample_idx + samples_per_peak, total_frames);

            while (sample_idx < end_sample) : (sample_idx += 1) {
                // Mix all channels to mono for peak calculation
                var sum: f32 = 0.0;
                for (0..num_channels) |ch| {
                    const idx = sample_idx * num_channels + ch;
                    if (idx < samples.len) {
                        sum += samples[idx];
                    }
                }
                const mono_sample = sum / @as(f32, @floatFromInt(num_channels));

                min_val = @min(min_val, mono_sample);
                max_val = @max(max_val, mono_sample);
            }

            peaks[peak_idx] = .{
                .min = min_val,
                .max = max_val,
            };
        }

        log.info("Created peak cache: {} peaks for {} frames ({} samples/peak)", .{
            num_peaks,
            total_frames,
            samples_per_peak,
        });

        return PeakCache{
            .allocator = allocator,
            .samples = samples,
            .num_channels = num_channels,
            .sample_rate = sample_rate,
            .peaks = peaks,
            .samples_per_peak = samples_per_peak,
            .total_frames = total_frames,
        };
    }

    pub fn deinit(self: *PeakCache) void {
        self.allocator.free(self.peaks);
    }

    /// Get peaks for a time range, resampled to fit the requested number of output peaks
    /// Returns the number of peaks actually written
    pub fn getPeaksForRange(
        self: *const PeakCache,
        start_time: f64,
        end_time: f64,
        output: []Peak,
    ) usize {
        if (output.len == 0) return 0;
        if (start_time >= end_time) return 0;

        const duration = end_time - start_time;
        const samples_in_range = @as(u64, @intFromFloat(duration * @as(f64, @floatFromInt(self.sample_rate))));

        // Calculate which cached peaks cover this range
        const start_peak = @as(usize, @intFromFloat(start_time * @as(f64, @floatFromInt(self.sample_rate)) / @as(f64, @floatFromInt(self.samples_per_peak))));
        const end_peak = @min(
            @as(usize, @intFromFloat(end_time * @as(f64, @floatFromInt(self.sample_rate)) / @as(f64, @floatFromInt(self.samples_per_peak)))) + 1,
            self.peaks.len,
        );

        if (start_peak >= self.peaks.len) return 0;

        const source_peaks = end_peak - start_peak;

        // If we have fewer source peaks than output slots, interpolate
        // If we have more, downsample by taking min/max
        if (source_peaks <= output.len) {
            // Upsampling or 1:1 - just copy with interpolation
            for (output, 0..) |*out, i| {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(output.len));
                const src_idx = start_peak + @as(usize, @intFromFloat(t * @as(f64, @floatFromInt(source_peaks))));
                const clamped_idx = @min(src_idx, self.peaks.len - 1);
                out.* = self.peaks[clamped_idx];
            }
            return output.len;
        } else {
            // Downsampling - combine multiple source peaks
            const peaks_per_output = @as(f64, @floatFromInt(source_peaks)) / @as(f64, @floatFromInt(output.len));

            for (output, 0..) |*out, i| {
                const src_start = start_peak + @as(usize, @intFromFloat(@as(f64, @floatFromInt(i)) * peaks_per_output));
                const src_end = @min(
                    start_peak + @as(usize, @intFromFloat(@as(f64, @floatFromInt(i + 1)) * peaks_per_output)),
                    self.peaks.len,
                );

                var min_val: f32 = 1.0;
                var max_val: f32 = -1.0;

                for (src_start..src_end) |j| {
                    min_val = @min(min_val, self.peaks[j].min);
                    max_val = @max(max_val, self.peaks[j].max);
                }

                out.* = .{ .min = min_val, .max = max_val };
            }
            return output.len;
        }

        _ = samples_in_range;
    }

    /// Get peaks as flat f32 array (for C API)
    /// Output format: [min0, max0, min1, max1, ...]
    pub fn getPeaksFlat(
        self: *const PeakCache,
        start_time: f64,
        end_time: f64,
        output: []f32,
    ) usize {
        const num_peaks = output.len / 2;
        if (num_peaks == 0) return 0;

        // Use stack buffer for peaks
        var peak_buf: [512]Peak = undefined;
        const peaks_to_get = @min(num_peaks, peak_buf.len);

        const actual = self.getPeaksForRange(start_time, end_time, peak_buf[0..peaks_to_get]);

        for (0..actual) |i| {
            output[i * 2] = peak_buf[i].min;
            output[i * 2 + 1] = peak_buf[i].max;
        }

        return actual;
    }

    /// Get total duration in seconds
    pub fn getDuration(self: *const PeakCache) f64 {
        return @as(f64, @floatFromInt(self.total_frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "peak cache basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create test audio: 1 second of stereo sine wave
    const sample_rate: u32 = 44100;
    const num_channels: u8 = 2;
    const num_frames = sample_rate;
    var samples = try allocator.alloc(f32, num_frames * num_channels);
    defer allocator.free(samples);

    // Generate sine wave
    for (0..num_frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const val = @sin(t * 2.0 * std.math.pi * 440.0); // 440 Hz
        samples[i * 2] = val;
        samples[i * 2 + 1] = val;
    }

    var cache = try PeakCache.init(allocator, samples, num_channels, sample_rate);
    defer cache.deinit();

    // Check duration
    try testing.expectApproxEqAbs(@as(f64, 1.0), cache.getDuration(), 0.01);

    // Get peaks for full duration
    var peaks: [100]Peak = undefined;
    const count = cache.getPeaksForRange(0.0, 1.0, &peaks);
    try testing.expect(count > 0);

    // Peaks should be in valid range
    for (peaks[0..count]) |p| {
        try testing.expect(p.min >= -1.0 and p.min <= 1.0);
        try testing.expect(p.max >= -1.0 and p.max <= 1.0);
        try testing.expect(p.min <= p.max);
    }
}
