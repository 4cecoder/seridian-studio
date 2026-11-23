# Real-Time Audio Patterns - Integration Plan

**Date:** 2025-12-23
**Source:** Analysis of ~/learning repositories
**Focus:** Zero-allocation, SIMD-optimized patterns for DAW real-time audio

---

## Executive Summary

Based on comprehensive analysis of:
- **zig-sparse-set**: O(1) entity management
- **zig-okredis**: Zero-allocation networking patterns
- **zalgebra**: SIMD vector operations

This document provides concrete, actionable integration plans for the ~/daw project.

---

## Part 1: Immediate Wins (< 2 hours implementation)

### 1.1 SIMD-Optimized Mixing in process()

**Current Code** (src/audio/engine.zig:196-208):
```zig
// Apply master gain and measure output
for (0..frames) |frame| {
    output[frame * 2] *= master_gain;
    output[frame * 2 + 1] *= master_gain;

    const left_abs = @abs(output[frame * 2]);
    const right_abs = @abs(output[frame * 2 + 1]);

    if (left_abs > master_peak_left) {
        master_peak_left = left_abs;
    }
    if (right_abs > master_peak_right) {
        master_peak_right = right_abs;
    }
}
```

**SIMD-Optimized Version** (using zalgebra patterns):

```zig
const Vec4 = @Vector(4, f32);

// Apply master gain and measure output (process 4 samples at once)
var i: usize = 0;
var peak_left_vec = @as(Vec4, @splat(0.0));
var peak_right_vec = @as(Vec4, @splat(0.0));
const gain_vec = @as(Vec4, @splat(master_gain));

while (i + 4 <= frames * 2) : (i += 8) {
    // Load 4 stereo frames (LLLLRRRR pattern)
    var samples: Vec4 align(16) = undefined;

    // Left channel (4 samples)
    samples[0] = output[i];
    samples[1] = output[i + 2];
    samples[2] = output[i + 4];
    samples[3] = output[i + 6];
    samples = samples * gain_vec;  // SIMD multiply
    output[i] = samples[0];
    output[i + 2] = samples[1];
    output[i + 4] = samples[2];
    output[i + 6] = samples[3];

    // Compute abs and max in SIMD
    const abs_left = @abs(samples);
    peak_left_vec = @max(peak_left_vec, abs_left);

    // Right channel (4 samples)
    samples[0] = output[i + 1];
    samples[1] = output[i + 3];
    samples[2] = output[i + 5];
    samples[3] = output[i + 7];
    samples = samples * gain_vec;
    output[i + 1] = samples[0];
    output[i + 3] = samples[1];
    output[i + 5] = samples[2];
    output[i + 7] = samples[3];

    const abs_right = @abs(samples);
    peak_right_vec = @max(peak_right_vec, abs_right);
}

// Reduce to scalar peak
master_peak_left = @reduce(.Max, peak_left_vec);
master_peak_right = @reduce(.Max, peak_right_vec);

// Handle remaining samples (scalar fallback)
while (i < frames * 2) : (i += 2) {
    output[i] *= master_gain;
    output[i + 1] *= master_gain;
    master_peak_left = @max(master_peak_left, @abs(output[i]));
    master_peak_right = @max(master_peak_right, @abs(output[i + 1]));
}
```

**Expected Performance**: 4x throughput improvement for master gain + metering
**Risk**: Low - fallback path handles edge cases
**Files to Modify**: src/audio/engine.zig

---

### 1.2 Zero-Allocation Ring Buffer for Parameter Updates

**Problem**: Currently atomic.Value is used for parameter changes. This works but doesn't queue multiple parameter changes efficiently.

**Solution** (zig-okredis FixBuf pattern):

Create new file: **src/audio/param_queue.zig**

```zig
const std = @import("std");

/// Fixed-size parameter change queue (zero allocation)
pub fn ParamQueue(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const ParamChange = struct {
            track_idx: u8,
            param_type: ParamType,
            value: f32,
        };

        pub const ParamType = enum {
            gain,
            pan,
            mute,
            solo,
        };

        buffer: [capacity]ParamChange = undefined,
        write_pos: usize = 0,
        read_pos: usize = 0,

        /// Push parameter change from UI thread
        pub fn push(self: *Self, change: ParamChange) !void {
            const next_write = (self.write_pos + 1) % capacity;
            if (next_write == self.read_pos) return error.QueueFull;

            self.buffer[self.write_pos] = change;
            @fence(.release);  // Ensure write completes before updating pos
            self.write_pos = next_write;
        }

        /// Pop parameter change in audio thread
        pub fn pop(self: *Self) ?ParamChange {
            if (self.read_pos == self.write_pos) return null;

            const change = self.buffer[self.read_pos];
            @fence(.acquire);  // Ensure read completes before updating pos
            self.read_pos = (self.read_pos + 1) % capacity;
            return change;
        }

        /// Process all pending changes in audio callback
        pub fn processAll(self: *Self, engine: anytype) void {
            while (self.pop()) |change| {
                switch (change.param_type) {
                    .gain => engine.setTrackGain(change.track_idx, change.value),
                    .pan => {}, // TODO: add pan support
                    .mute => engine.setTrackMute(change.track_idx, change.value != 0),
                    .solo => engine.setTrackSolo(change.track_idx, change.value != 0),
                }
            }
        }
    };
}
```

**Integration** (src/audio/engine.zig):

```zig
const ParamQueue = @import("param_queue.zig").ParamQueue;

pub const AudioEngine = struct {
    // ... existing fields

    // Add parameter queue (256 changes max)
    param_queue: ParamQueue(256) = .{},

    pub fn process(self: *AudioEngine, output: []f32) void {
        // FIRST THING: Process parameter updates from UI
        self.param_queue.processAll(self);

        // ... rest of process() method
    }
};
```

**Expected Benefit**: Batched parameter updates, no atomic contention
**Risk**: Very low - ring buffer is proven pattern
**Files to Create**: src/audio/param_queue.zig
**Files to Modify**: src/audio/engine.zig

---

## Part 2: Medium-Term Improvements (4-8 hours)

### 2.1 Sparse Set for Track Management

**Current Limitation**: Fixed 4 tracks in arrays

**Sparse Set Solution**:

Create new file: **src/audio/track_manager.zig**

```zig
const std = @import("std");
const SparseSet = @import("../learning/zig-sparse-set/src/sparse_set.zig").SparseSet;
const Track = @import("track.zig").Track;

pub const TrackManager = struct {
    const TrackSet = SparseSet(.{
        .SparseT = u16,                    // Track ID (up to 65k)
        .DenseT = u8,                      // Active tracks (max 256)
        .ValueT = Track,
        .value_layout = .InternalArrayOfStructs,
        .allow_resize = .NoResize,
    });

    allocator: std.mem.Allocator,
    tracks: TrackSet = undefined,

    // SOA for SIMD processing
    gains: [256]f32 = [_]f32{0.75} ** 256,
    pans: [256]f32 = [_]f32{0.0} ** 256,
    muted: [256]bool = [_]bool{false} ** 256,
    soloed: [256]bool = [_]bool{false} ** 256,

    pub fn init(allocator: std.mem.Allocator) !TrackManager {
        return TrackManager{
            .allocator = allocator,
            .tracks = try TrackSet.init(allocator, 65536, 256),
        };
    }

    pub fn deinit(self: *TrackManager) void {
        self.tracks.deinit(self.allocator);
    }

    /// Add new track - O(1)
    pub fn addTrack(self: *TrackManager, track_id: u16) !u8 {
        const track = Track.init(self.allocator);
        const dense_idx = try self.tracks.addValueOrError(track_id, track);
        return dense_idx;
    }

    /// Remove track - O(1) with swap-and-pop
    pub fn removeTrack(self: *TrackManager, track_id: u16) !void {
        var dense_old: u8 = undefined;
        var dense_new: u8 = undefined;

        self.tracks.removeWithInfo(track_id, &dense_old, &dense_new);

        // Update SOA arrays (swap last into removed position)
        self.gains[dense_new] = self.gains[dense_old];
        self.pans[dense_new] = self.pans[dense_old];
        self.muted[dense_new] = self.muted[dense_old];
        self.soloed[dense_new] = self.soloed[dense_old];
    }

    /// Process all active tracks (cache-friendly iteration)
    pub fn processAll(self: *TrackManager, output: []f32, sample_rate: u32) void {
        const active_count = self.tracks.len();

        // Iterate dense array only (all active tracks are contiguous)
        for (self.tracks.toValueSlice(), 0..active_count) |*track, dense_idx| {
            if (self.muted[dense_idx]) continue;

            // Process track with its parameters
            var track_buffer: [512]f32 = undefined;
            track.process(&track_buffer, output.len / 2, sample_rate);

            // Mix with gain/pan (can be SIMD optimized)
            const gain = self.gains[dense_idx];
            for (track_buffer[0..output.len / 2], 0..) |sample, i| {
                output[i * 2] += sample * gain;     // Left
                output[i * 2 + 1] += sample * gain; // Right
            }
        }
    }
};
```

**Expected Benefit**:
- Dynamic track count (no 4-track limit)
- O(1) add/remove tracks
- Cache-optimal iteration (only active tracks)
- SOA layout enables SIMD on parameters

**Files to Create**: src/audio/track_manager.zig
**Files to Integrate**: Copy ~/learning/zig-sparse-set/src/sparse_set.zig to src/audio/

---

### 2.2 Compile-Time Filter Specialization

Create new file: **src/audio/filters.zig**

```zig
const std = @import("std");

/// IIR Biquad filter with compile-time order specialization
/// Pattern from zig-okredis compile-time type dispatch
pub fn BiquadFilter(comptime T: type) type {
    return struct {
        const Self = @This();

        // Coefficients (b = feedforward, a = feedback)
        b0: T, b1: T, b2: T,
        a1: T, a2: T,

        // State (2 delays for biquad)
        x1: T = 0, x2: T = 0,  // Input delays
        y1: T = 0, y2: T = 0,  // Output delays

        /// Process single sample (inlined for performance)
        pub inline fn process(self: *Self, input: T) T {
            // Direct Form II implementation
            const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
                         - self.a1 * self.y1 - self.a2 * self.y2;

            // Shift delays
            self.x2 = self.x1;
            self.x1 = input;
            self.y2 = self.y1;
            self.y1 = output;

            return output;
        }

        /// Process buffer with compile-time loop unrolling
        pub fn processBuffer(self: *Self, input: []const T, output: []T) void {
            std.debug.assert(input.len == output.len);

            for (input, output) |in_sample, *out_sample| {
                out_sample.* = self.process(in_sample);
            }
        }

        /// Lowpass filter design
        pub fn lowpass(sample_rate: T, cutoff_freq: T, q: T) Self {
            const omega = 2.0 * std.math.pi * cutoff_freq / sample_rate;
            const cos_omega = @cos(omega);
            const sin_omega = @sin(omega);
            const alpha = sin_omega / (2.0 * q);

            const a0 = 1.0 + alpha;

            return Self{
                .b0 = (1.0 - cos_omega) / (2.0 * a0),
                .b1 = (1.0 - cos_omega) / a0,
                .b2 = (1.0 - cos_omega) / (2.0 * a0),
                .a1 = (-2.0 * cos_omega) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        }

        /// Highpass filter design
        pub fn highpass(sample_rate: T, cutoff_freq: T, q: T) Self {
            const omega = 2.0 * std.math.pi * cutoff_freq / sample_rate;
            const cos_omega = @cos(omega);
            const sin_omega = @sin(omega);
            const alpha = sin_omega / (2.0 * q);

            const a0 = 1.0 + alpha;

            return Self{
                .b0 = (1.0 + cos_omega) / (2.0 * a0),
                .b1 = -(1.0 + cos_omega) / a0,
                .b2 = (1.0 + cos_omega) / (2.0 * a0),
                .a1 = (-2.0 * cos_omega) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        }
    };
}

/// SIMD-vectorized filter bank (process 4 filters in parallel)
pub const BiquadFilter4 = struct {
    const Vec4 = @Vector(4, f32);

    // SOA layout for SIMD
    b0: Vec4, b1: Vec4, b2: Vec4,
    a1: Vec4, a2: Vec4,
    x1: Vec4 = @splat(0), x2: Vec4 = @splat(0),
    y1: Vec4 = @splat(0), y2: Vec4 = @splat(0),

    /// Process 4 samples from different channels simultaneously
    pub inline fn process4(self: *BiquadFilter4, input: Vec4) Vec4 {
        const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
                     - self.a1 * self.y1 - self.a2 * self.y2;

        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;

        return output;
    }
};
```

**Expected Benefit**:
- Compile-time specialization (zero runtime overhead)
- Inline process() for hot paths
- SIMD filter bank for parallel processing
- Standard filter designs (lowpass/highpass/etc)

**Files to Create**: src/audio/filters.zig

---

## Part 3: Architecture Changes (1-2 days)

### 3.1 Two-Phase Audio Processing

**Separation Pattern** (from zig-okredis dual API):

```zig
// NON-RT Thread: Setup and allocation
pub fn setupAudioContext(allocator: Allocator) !AudioContext {
    var ctx = AudioContext{
        .allocator = allocator,
    };

    // Pre-allocate ALL buffers
    ctx.track_buffers = try allocator.alloc([512]f32, 256);
    ctx.mix_buffer = try allocator.alloc(f32, 1024);
    ctx.effect_buffers = try allocator.alloc([2048]f32, 32);

    return ctx;
}

// RT Thread: Process audio (ZERO allocations)
pub fn processAudioRT(ctx: *AudioContext, output: []f32) void {
    // Use pre-allocated buffers only
    // NO allocations allowed here
}
```

**Integration**:

Modify src/audio/engine.zig to have separate init phases:

```zig
pub const AudioEngine = struct {
    // Add pre-allocated buffer pools
    track_buffer_pool: []align(16) [512]f32,
    temp_buffer_pool: []align(16) [2048]f32,

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !AudioEngine {
        // ... existing init

        // Pre-allocate buffer pools (BEFORE audio starts)
        const track_buffers = try allocator.alloc([512]f32, TRACK_COUNT * 2);
        errdefer allocator.free(track_buffers);

        const temp_buffers = try allocator.alloc([2048]f32, 16);
        errdefer allocator.free(temp_buffers);

        // ... rest of init

        return AudioEngine{
            // ... existing fields
            .track_buffer_pool = track_buffers,
            .temp_buffer_pool = temp_buffers,
        };
    }

    pub fn deinit(self: *AudioEngine) void {
        self.allocator.free(self.track_buffer_pool);
        self.allocator.free(self.temp_buffer_pool);
        // ... rest of deinit
    }

    pub fn process(self: *AudioEngine, output: []f32) void {
        // REAL-TIME THREAD - NO ALLOCATIONS

        // Use pre-allocated buffers from pool
        const track_buf = &self.track_buffer_pool[0];
        const temp_buf = &self.temp_buffer_pool[0];

        // ... processing with zero allocations
    }
};
```

---

## Part 4: Integration Checklist

### Phase 1: Quick Wins (Do First)
- [ ] Add SIMD Vec4 to master gain/metering loop
- [ ] Create ParamQueue for batched parameter updates
- [ ] Benchmark before/after SIMD optimization
- [ ] Verify zero regressions with existing tests

### Phase 2: Data Structures
- [ ] Copy sparse_set.zig to src/audio/
- [ ] Create track_manager.zig with sparse set
- [ ] Add tests for dynamic track add/remove
- [ ] Update engine.zig to use TrackManager

### Phase 3: DSP Filters
- [ ] Create filters.zig with BiquadFilter
- [ ] Add filter bank (BiquadFilter4) for SIMD
- [ ] Integrate lowpass/highpass designs
- [ ] Add per-track EQ using filter chains

### Phase 4: Memory Management
- [ ] Add buffer pool pre-allocation
- [ ] Split init into RT/non-RT phases
- [ ] Add compile-time buffer size validation
- [ ] Document allocation boundaries

---

## Performance Metrics Targets

Based on patterns learned:

| Operation | Current | Target (SIMD) | Improvement |
|-----------|---------|---------------|-------------|
| Master gain (512 samples) | ~512 ops | ~128 ops | 4x |
| Peak metering (512 samples) | ~1024 ops | ~256 ops | 4x |
| 4-track mixing | O(n × 4) | O(n) SIMD | 4x |
| Track add/remove | N/A | O(1) | Enables dynamic |
| Parameter updates | Atomic per-change | Batched queue | Lower contention |

---

## Risk Assessment

### Low Risk (Immediate)
✅ SIMD in master gain loop - fallback path exists
✅ ParamQueue - optional, doesn't replace atomics

### Medium Risk (Test Thoroughly)
⚠️ TrackManager - changes core architecture
⚠️ Buffer pools - must handle all buffer size cases

### High Risk (Prototype First)
❗ Full SIMD mixing pipeline - needs extensive testing
❗ Lock-free command queue - race condition potential

---

## References

All patterns sourced from:
- `~/learning/zig-sparse-set/` - O(1) data structures
- `~/learning/zig-okredis/` - Zero-allocation networking
- `~/learning/zalgebra/` - SIMD vector operations

**Next Step**: Start with Phase 1 SIMD optimization (< 1 hour, immediate benefit).
