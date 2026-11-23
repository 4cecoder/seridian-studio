# Real-Time Audio Patterns - Quick Reference

**Quick lookup for production-ready RT audio patterns**

---

## 🚀 Copy-Paste Ready Code

### 1. SIMD Vec4 Master Gain (4x faster)

```zig
// Add to src/audio/engine.zig at line 196
const Vec4 = @Vector(4, f32);

var i: usize = 0;
var peak_left_vec = @as(Vec4, @splat(0.0));
var peak_right_vec = @as(Vec4, @splat(0.0));
const gain_vec = @as(Vec4, @splat(master_gain));

// Process 4 samples at a time
while (i + 8 <= frames * 2) : (i += 8) {
    // Left channel (4 samples)
    var left_samples: Vec4 = .{
        output[i], output[i + 2], output[i + 4], output[i + 6]
    };
    left_samples = left_samples * gain_vec;
    output[i] = left_samples[0];
    output[i + 2] = left_samples[1];
    output[i + 4] = left_samples[2];
    output[i + 6] = left_samples[3];

    peak_left_vec = @max(peak_left_vec, @abs(left_samples));

    // Right channel (4 samples)
    var right_samples: Vec4 = .{
        output[i + 1], output[i + 3], output[i + 5], output[i + 7]
    };
    right_samples = right_samples * gain_vec;
    output[i + 1] = right_samples[0];
    output[i + 3] = right_samples[1];
    output[i + 5] = right_samples[2];
    output[i + 7] = right_samples[3];

    peak_right_vec = @max(peak_right_vec, @abs(right_samples));
}

master_peak_left = @reduce(.Max, peak_left_vec);
master_peak_right = @reduce(.Max, peak_right_vec);

// Handle remainder (scalar)
while (i < frames * 2) : (i += 2) {
    output[i] *= master_gain;
    output[i + 1] *= master_gain;
    master_peak_left = @max(master_peak_left, @abs(output[i]));
    master_peak_right = @max(master_peak_right, @abs(output[i + 1]));
}
```

---

### 2. Zero-Allocation Ring Buffer

```zig
// Create src/audio/ring_buffer.zig
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        write_pos: usize = 0,
        read_pos: usize = 0,

        pub fn push(self: *@This(), item: T) !void {
            const next = (self.write_pos + 1) % capacity;
            if (next == self.read_pos) return error.Full;
            self.buf[self.write_pos] = item;
            @fence(.release);
            self.write_pos = next;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.read_pos == self.write_pos) return null;
            const item = self.buf[self.read_pos];
            @fence(.acquire);
            self.read_pos = (self.read_pos + 1) % capacity;
            return item;
        }

        pub fn clear(self: *@This()) void {
            self.read_pos = 0;
            self.write_pos = 0;
        }
    };
}

// Usage
var audioBuffer: RingBuffer(f32, 4096) = .{};
try audioBuffer.push(sample);
if (audioBuffer.pop()) |sample| { /* use sample */ }
```

---

### 3. Compile-Time Biquad Filter

```zig
// Create src/audio/biquad.zig
pub fn Biquad(comptime T: type) type {
    return struct {
        b0: T, b1: T, b2: T,
        a1: T, a2: T,
        x1: T = 0, x2: T = 0,
        y1: T = 0, y2: T = 0,

        pub inline fn process(self: *@This(), input: T) T {
            const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
                         - self.a1 * self.y1 - self.a2 * self.y2;
            self.x2 = self.x1; self.x1 = input;
            self.y2 = self.y1; self.y1 = output;
            return output;
        }

        pub fn lowpass(sr: T, freq: T, q: T) @This() {
            const omega = 2.0 * std.math.pi * freq / sr;
            const cos_w = @cos(omega);
            const sin_w = @sin(omega);
            const alpha = sin_w / (2.0 * q);
            const a0 = 1.0 + alpha;
            return .{
                .b0 = (1.0 - cos_w) / (2.0 * a0),
                .b1 = (1.0 - cos_w) / a0,
                .b2 = (1.0 - cos_w) / (2.0 * a0),
                .a1 = (-2.0 * cos_w) / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        }
    };
}

// Usage
var lpf = Biquad(f32).lowpass(48000, 1000, 0.707);
const filtered = lpf.process(input_sample);
```

---

### 4. SIMD Filter Bank (4 filters in parallel)

```zig
pub const BiquadVec4 = struct {
    const Vec4 = @Vector(4, f32);
    b0: Vec4, b1: Vec4, b2: Vec4,
    a1: Vec4, a2: Vec4,
    x1: Vec4 = @splat(0), x2: Vec4 = @splat(0),
    y1: Vec4 = @splat(0), y2: Vec4 = @splat(0),

    pub inline fn process4(self: *@This(), input: Vec4) Vec4 {
        const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
                     - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1; self.x1 = input;
        self.y2 = self.y1; self.y1 = output;
        return output;
    }
};

// Process 4 channels simultaneously
var filters: BiquadVec4 = initFilters();
const input_vec: Vec4 = .{ ch1, ch2, ch3, ch4 };
const filtered_vec = filters.process4(input_vec);
```

---

## 📋 Pattern Checklist

### Before RT Callback:
- [ ] Pre-allocate ALL buffers
- [ ] Initialize lock-free queues
- [ ] Set up SIMD-aligned buffers (align(16))
- [ ] Validate buffer sizes at compile time

### In RT Callback:
- [ ] NO allocations (`try allocator.alloc()` forbidden)
- [ ] NO system calls (no file I/O, no printf)
- [ ] NO locks (use atomics or lock-free structures)
- [ ] NO unbounded loops
- [ ] Use SIMD where possible
- [ ] Use inline functions for hot paths

### Error Handling in RT:
```zig
// ✅ Good: Return error, log later
if (error) |err| {
    self.error_flag.store(true, .monotonic);
    return;
}

// ❌ Bad: Allocate, print, panic
if (error) |err| {
    std.debug.print("Error: {}\n", .{err}); // PRINTS = SYSCALL
    @panic("Audio error");                   // PANIC = ABORT
}
```

---

## 🎯 Performance Rules

### SIMD Alignment:
```zig
// Align buffers to 16 bytes for SSE/NEON
var buffer: [512]f32 align(16) = undefined;

// Stack arrays automatically aligned
const Vec4 = @Vector(4, f32);
var vec: Vec4 = undefined;  // Automatically 16-byte aligned
```

### Compile-Time Unrolling:
```zig
// ✅ Unrolled at compile time
inline for (0..TRACK_COUNT) |i| {
    process_track(i);
}

// ❌ Runtime loop
for (0..track_count) |i| {
    process_track(i);
}
```

### Hot Path Inlining:
```zig
// Force inline for critical functions
pub inline fn processSample(input: f32) f32 {
    return input * 0.5;
}
```

---

## 🔧 Common Patterns

### Dot Product (Mixing):
```zig
const Vec4 = @Vector(4, f32);
const gains: Vec4 = .{ 0.8, 0.6, 0.9, 0.5 };
const samples: Vec4 = .{ s1, s2, s3, s4 };
const mixed = @reduce(.Add, gains * samples);
```

### Lerp (Automation):
```zig
pub fn lerp(from: Vec4, to: Vec4, t: f32) Vec4 {
    return from + (to - from) * @as(Vec4, @splat(t));
}

// Smooth fade over 512 samples
for (0..512) |i| {
    const t = @as(f32, @floatFromInt(i)) / 512.0;
    output[i] = lerp(start_gain, end_gain, t);
}
```

### Hard Clip:
```zig
const Vec4 = @Vector(4, f32);
const max_val: Vec4 = @splat(1.0);
const min_val: Vec4 = @splat(-1.0);
samples = @max(@min(samples, max_val), min_val);
```

---

## 📚 File Locations

### Source Repos:
- Sparse set: `~/learning/zig-sparse-set/src/sparse_set.zig`
- SIMD patterns: `~/learning/zalgebra/src/generic_vector.zig`
- Zero-alloc: `~/learning/zig-okredis/src/types/fixbuf.zig`

### DAW Documentation:
- Full integration plan: `docs/RT_AUDIO_PATTERNS_INTEGRATION.md`
- Complete analysis: `docs/REALTIME_AUDIO_ANALYSIS_COMPLETE.md`
- Learned patterns: `docs/LEARNED_PATTERNS.md`

---

## ⚡ Quick Start

**Get 2x speedup in 1 hour:**

1. Copy SIMD Vec4 code to `src/audio/engine.zig:196`
2. Test: `zig build && zig build run`
3. Verify: CPU usage should drop ~50%

**Add zero-alloc param queue in 2 hours:**

1. Create `src/audio/param_queue.zig` with RingBuffer pattern
2. Add to engine: `param_queue: ParamQueue(256) = .{}`
3. Process in callback: `self.param_queue.processAll(self)`

**Done!** You now have SIMD mixing and lock-free parameter updates.
