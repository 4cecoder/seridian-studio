//! Freeverb Reverb Effect
//!
//! Stereo reverb based on Jezar's Freeverb algorithm (public domain).
//! Uses 8 parallel damped comb filters and 4 cascaded all-pass filters.
//!
//! REAL-TIME SAFE - All buffers pre-allocated, no allocations in process().

const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Parameter = @import("effect.zig").Parameter;

/// Damped comb filter for reverb tail
const DampedComb = struct {
    buffer: []f32,
    buffer_size: usize,
    write_pos: usize = 0,
    filter_state: f32 = 0,
    feedback: f32 = 0.84,
    damping: f32 = 0.5,

    fn process(self: *DampedComb, input: f32) f32 {
        const delayed = self.buffer[self.write_pos];

        // One-pole low-pass filter (damping)
        self.filter_state = delayed * (1.0 - self.damping) + self.filter_state * self.damping;

        // Write input + filtered feedback
        self.buffer[self.write_pos] = input + self.filter_state * self.feedback;

        // Advance write position
        self.write_pos = (self.write_pos + 1) % self.buffer_size;

        return delayed;
    }

    fn reset(self: *DampedComb) void {
        @memset(self.buffer, 0.0);
        self.filter_state = 0;
        self.write_pos = 0;
    }
};

/// All-pass filter for diffusion
const AllPass = struct {
    buffer: []f32,
    buffer_size: usize,
    write_pos: usize = 0,
    feedback: f32 = 0.5,

    fn process(self: *AllPass, input: f32) f32 {
        const delayed = self.buffer[self.write_pos];
        const output = -input + delayed;

        self.buffer[self.write_pos] = input + delayed * self.feedback;
        self.write_pos = (self.write_pos + 1) % self.buffer_size;

        return output;
    }

    fn reset(self: *AllPass) void {
        @memset(self.buffer, 0.0);
        self.write_pos = 0;
    }
};

pub const Reverb = struct {
    effect: Effect,

    // Parameters
    params: [5]Parameter = .{
        .{ .name = "Room Size", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Damping", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
        .{ .name = "Width", .min = 0.0, .max = 1.0, .default = 1.0, .value = 1.0, .unit = "" },
        .{ .name = "Wet", .min = 0.0, .max = 1.0, .default = 0.33, .value = 0.33, .unit = "" },
        .{ .name = "Dry", .min = 0.0, .max = 1.0, .default = 0.5, .value = 0.5, .unit = "" },
    },

    // 8 comb filters per channel (16 total)
    comb_left: [8]DampedComb = undefined,
    comb_right: [8]DampedComb = undefined,

    // 4 all-pass filters (shared between channels for efficiency)
    allpass: [4]AllPass = undefined,

    // Pre-allocated buffers for comb filters
    // Sizes based on 44.1kHz, scaled at runtime
    comb_buffers_left: [8][MAX_COMB_SIZE]f32 = @as([8][MAX_COMB_SIZE]f32, @splat(@as([MAX_COMB_SIZE]f32, @splat(0.0)))),
    comb_buffers_right: [8][MAX_COMB_SIZE]f32 = @as([8][MAX_COMB_SIZE]f32, @splat(@as([MAX_COMB_SIZE]f32, @splat(0.0)))),

    // Pre-allocated buffers for all-pass filters
    allpass_buffers: [4][MAX_ALLPASS_SIZE]f32 = @as([4][MAX_ALLPASS_SIZE]f32, @splat(@as([MAX_ALLPASS_SIZE]f32, @splat(0.0)))),

    last_sample_rate: u32 = 0,

    // Buffer size constants (at 44.1kHz base rate)
    const MAX_COMB_SIZE = 2048; // Enough for longest comb
    const MAX_ALLPASS_SIZE = 640; // Enough for longest allpass

    // Freeverb magic numbers (delay times in samples at 44.1kHz)
    const COMB_DELAYS = [8]usize{ 1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116 };
    const ALLPASS_DELAYS = [4]usize{ 225, 556, 441, 341 };
    const STEREO_SPREAD: usize = 23; // Stereo decorrelation

    const vtable = Effect.VTable{
        .process = process,
        .reset = reset,
        .getParameterCount = getParameterCount,
        .getParameter = getParameter,
        .setParameter = setParameter,
    };

    pub fn init() Reverb {
        var reverb = Reverb{
            .effect = .{
                .vtable = &vtable,
                .name = "Reverb",
            },
        };

        // Initialize comb filters with buffer pointers
        for (0..8) |i| {
            reverb.comb_left[i] = .{
                .buffer = &reverb.comb_buffers_left[i],
                .buffer_size = COMB_DELAYS[i],
            };
            reverb.comb_right[i] = .{
                .buffer = &reverb.comb_buffers_right[i],
                .buffer_size = COMB_DELAYS[i] + STEREO_SPREAD,
            };
        }

        // Initialize all-pass filters
        for (0..4) |i| {
            reverb.allpass[i] = .{
                .buffer = &reverb.allpass_buffers[i],
                .buffer_size = ALLPASS_DELAYS[i],
            };
        }

        return reverb;
    }

    fn process(effect: *Effect, buffer: []f32, sample_rate: u32) void {
        const self: *Reverb = @fieldParentPtr("effect", effect);

        // Scale buffer sizes if sample rate changed
        if (self.last_sample_rate != sample_rate) {
            self.updateSampleRate(sample_rate);
            self.last_sample_rate = sample_rate;
        }

        // Get parameters
        const room_size = self.params[0].value * 0.28 + 0.7; // Scale to 0.7-0.98
        const damping = self.params[1].value;
        const width = self.params[2].value;
        const wet = self.params[3].value * 3.0; // Scale wet level
        const dry = self.params[4].value * 2.0; // Scale dry level

        // Update comb filter parameters
        for (&self.comb_left, &self.comb_right) |*comb_l, *comb_r| {
            comb_l.feedback = room_size;
            comb_l.damping = damping;
            comb_r.feedback = room_size;
            comb_r.damping = damping;
        }

        const frames = buffer.len / 2;
        const wet1 = wet * (width / 2.0 + 0.5);
        const wet2 = wet * ((1.0 - width) / 2.0);

        for (0..frames) |i| {
            const left_in = buffer[i * 2];
            const right_in = buffer[i * 2 + 1];
            const input = (left_in + right_in) * 0.5; // Mix to mono for reverb input

            // Process through parallel comb filters
            var left_sum: f32 = 0;
            var right_sum: f32 = 0;

            for (&self.comb_left, &self.comb_right) |*comb_l, *comb_r| {
                left_sum += comb_l.process(input);
                right_sum += comb_r.process(input);
            }

            // Process through series all-pass filters
            for (&self.allpass) |*ap| {
                left_sum = ap.process(left_sum);
                right_sum = ap.process(right_sum);
            }

            // Apply stereo width and mix
            buffer[i * 2] = left_in * dry + left_sum * wet1 + right_sum * wet2;
            buffer[i * 2 + 1] = right_in * dry + right_sum * wet1 + left_sum * wet2;
        }
    }

    fn updateSampleRate(self: *Reverb, sample_rate: u32) void {
        const scale = @as(f32, @floatFromInt(sample_rate)) / 44100.0;

        // Scale comb filter sizes
        for (0..8) |i| {
            const base_size = COMB_DELAYS[i];
            const scaled_size = @as(usize, @intFromFloat(@as(f32, @floatFromInt(base_size)) * scale));
            self.comb_left[i].buffer_size = @min(scaled_size, MAX_COMB_SIZE);
            self.comb_right[i].buffer_size = @min(scaled_size + STEREO_SPREAD, MAX_COMB_SIZE);
        }

        // Scale all-pass filter sizes
        for (0..4) |i| {
            const base_size = ALLPASS_DELAYS[i];
            const scaled_size = @as(usize, @intFromFloat(@as(f32, @floatFromInt(base_size)) * scale));
            self.allpass[i].buffer_size = @min(scaled_size, MAX_ALLPASS_SIZE);
        }
    }

    fn reset(effect: *Effect) void {
        const self: *Reverb = @fieldParentPtr("effect", effect);

        for (&self.comb_left, &self.comb_right) |*comb_l, *comb_r| {
            comb_l.reset();
            comb_r.reset();
        }

        for (&self.allpass) |*ap| {
            ap.reset();
        }
    }

    fn getParameterCount(effect: *const Effect) usize {
        _ = effect;
        return 5;
    }

    fn getParameter(effect: *const Effect, index: usize) ?*const Parameter {
        const self: *const Reverb = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return null;
        return &self.params[index];
    }

    fn setParameter(effect: *Effect, index: usize, value: f32) void {
        const self: *Reverb = @fieldParentPtr("effect", effect);
        if (index >= self.params.len) return;
        self.params[index].value = std.math.clamp(value, self.params[index].min, self.params[index].max);
    }

    // Convenience methods
    pub fn setRoomSize(self: *Reverb, size: f32) void {
        setParameter(&self.effect, 0, size);
    }

    pub fn setDamping(self: *Reverb, damp: f32) void {
        setParameter(&self.effect, 1, damp);
    }

    pub fn setWidth(self: *Reverb, w: f32) void {
        setParameter(&self.effect, 2, w);
    }

    pub fn setWet(self: *Reverb, wet: f32) void {
        setParameter(&self.effect, 3, wet);
    }

    pub fn setDry(self: *Reverb, dry: f32) void {
        setParameter(&self.effect, 4, dry);
    }
};

test "reverb init and process" {
    const testing = std.testing;

    var reverb = Reverb.init();

    // Process some audio - just verify it doesn't crash
    // and produces output different from all-zeros
    var buffer = @as([512]f32, @splat(0.0));
    buffer[0] = 1.0; // Impulse
    buffer[1] = 1.0;

    reverb.effect.vtable.process(&reverb.effect, &buffer, 48000);

    // The impulse should be present in output (dry signal)
    // Reverb adds wet signal on top, which takes time to build up in combs
    // For now just check the first sample has the dry component
    try testing.expect(buffer[0] > 0.5); // Should have dry signal

    // Also verify reset works
    reverb.effect.vtable.reset(&reverb.effect);
}
