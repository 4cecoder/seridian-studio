//! Reverb Algorithms
//!
//! Various reverb implementations for spatial effects:
//! - Schroeder Reverb (classic 4 comb + 2 allpass)
//! - Freeverb (improved Schroeder with stereo)
//! - Plate Reverb (dense, metallic character)
//! - Room Simulation (early reflections + late reverb)
//!
//! Based on algorithms from:
//! - Schroeder "Natural Sounding Artificial Reverberation" (1962)
//! - Jezar's Freeverb (public domain)
//! - LMMS ReverbSC plugin
//! - Dattorro "Effect Design Part 1: Reverberator" (1997)

const std = @import("std");
const math = std.math;

// =============================================================================
// Delay Line (internal)
// =============================================================================

fn DelayLine(comptime max_size: usize) type {
    return struct {
        buffer: [max_size]f32 = @as([max_size]f32, @splat(0)),
        write_pos: usize = 0,
        delay: usize = 100,

        const Self = @This();

        pub fn setDelay(self: *Self, samples: usize) void {
            self.delay = @min(samples, max_size - 1);
        }

        pub fn read(self: *Self) f32 {
            const read_pos = (self.write_pos + max_size - self.delay) % max_size;
            return self.buffer[read_pos];
        }

        pub fn readAt(self: *Self, offset: usize) f32 {
            const read_pos = (self.write_pos + max_size - offset) % max_size;
            return self.buffer[read_pos];
        }

        pub fn write(self: *Self, sample: f32) void {
            self.buffer[self.write_pos] = sample;
            self.write_pos = (self.write_pos + 1) % max_size;
        }

        pub fn tap(self: *Self, input: f32) f32 {
            const output = self.read();
            self.write(input);
            return output;
        }

        pub fn clear(self: *Self) void {
            @memset(&self.buffer, 0);
        }
    };
}

// =============================================================================
// Comb Filter (for reverb)
// =============================================================================

fn CombFilter(comptime max_size: usize) type {
    return struct {
        delay: DelayLine(max_size) = .{},
        feedback: f32 = 0.5,
        damp: f32 = 0.5,
        filter_state: f32 = 0,

        const Self = @This();

        pub fn setFeedback(self: *Self, fb: f32) void {
            self.feedback = fb;
        }

        pub fn setDamp(self: *Self, d: f32) void {
            self.damp = d;
        }

        pub fn process(self: *Self, input: f32) f32 {
            const output = self.delay.read();

            // Lowpass filter in feedback (damping)
            self.filter_state = output * (1.0 - self.damp) + self.filter_state * self.damp;

            // Write input + filtered feedback
            self.delay.write(input + self.filter_state * self.feedback);

            return output;
        }

        pub fn clear(self: *Self) void {
            self.delay.clear();
            self.filter_state = 0;
        }
    };
}

// =============================================================================
// Allpass Filter (for reverb)
// =============================================================================

fn AllpassFilter(comptime max_size: usize) type {
    return struct {
        delay: DelayLine(max_size) = .{},
        feedback: f32 = 0.5,

        const Self = @This();

        pub fn setFeedback(self: *Self, fb: f32) void {
            self.feedback = fb;
        }

        pub fn process(self: *Self, input: f32) f32 {
            const delayed = self.delay.read();
            const output = -input + delayed;
            self.delay.write(input + delayed * self.feedback);
            return output;
        }

        pub fn clear(self: *Self) void {
            self.delay.clear();
        }
    };
}

// =============================================================================
// Schroeder Reverb
// =============================================================================

/// Classic Schroeder reverberator
/// 4 parallel comb filters -> 2 series allpass filters
pub const SchroederReverb = struct {
    // 4 parallel comb filters
    comb1: CombFilter(2048) = .{},
    comb2: CombFilter(2048) = .{},
    comb3: CombFilter(2048) = .{},
    comb4: CombFilter(2048) = .{},

    // 2 series allpass filters
    allpass1: AllpassFilter(512) = .{},
    allpass2: AllpassFilter(512) = .{},

    // Parameters
    room_size: f32 = 0.5,
    damping: f32 = 0.5,
    mix: f32 = 0.3,

    sample_rate: f32,

    const Self = @This();

    // Prime number delay times for less metallic sound
    const COMB_DELAYS = [4]usize{ 1116, 1188, 1277, 1356 };
    const ALLPASS_DELAYS = [2]usize{ 225, 341 };

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.updateDelays();
        self.updateFeedback();
        return self;
    }

    /// Set room size (0.0 - 1.0)
    pub fn setRoomSize(self: *Self, size: f32) void {
        self.room_size = math.clamp(size, 0, 1);
        self.updateFeedback();
    }

    /// Set damping (0.0 - 1.0, higher = darker)
    pub fn setDamping(self: *Self, damp: f32) void {
        self.damping = math.clamp(damp, 0, 1);
        self.comb1.setDamp(self.damping);
        self.comb2.setDamp(self.damping);
        self.comb3.setDamp(self.damping);
        self.comb4.setDamp(self.damping);
    }

    /// Set wet/dry mix (0.0 - 1.0)
    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    fn updateDelays(self: *Self) void {
        // Scale delays for sample rate (reference: 44100)
        const scale = self.sample_rate / 44100.0;

        self.comb1.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_DELAYS[0])) * scale)));
        self.comb2.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_DELAYS[1])) * scale)));
        self.comb3.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_DELAYS[2])) * scale)));
        self.comb4.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_DELAYS[3])) * scale)));

        self.allpass1.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_DELAYS[0])) * scale)));
        self.allpass2.delay.setDelay(@as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_DELAYS[1])) * scale)));
    }

    fn updateFeedback(self: *Self) void {
        const feedback = 0.7 + self.room_size * 0.28; // 0.7 to 0.98
        self.comb1.setFeedback(feedback);
        self.comb2.setFeedback(feedback);
        self.comb3.setFeedback(feedback);
        self.comb4.setFeedback(feedback);

        self.allpass1.setFeedback(0.5);
        self.allpass2.setFeedback(0.5);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Parallel comb filters
        var comb_sum = self.comb1.process(input);
        comb_sum += self.comb2.process(input);
        comb_sum += self.comb3.process(input);
        comb_sum += self.comb4.process(input);

        // Series allpass filters for diffusion
        var output = self.allpass1.process(comb_sum);
        output = self.allpass2.process(output);

        // Mix dry/wet
        return input * (1.0 - self.mix) + output * self.mix * 0.25;
    }

    pub fn reset(self: *Self) void {
        self.comb1.clear();
        self.comb2.clear();
        self.comb3.clear();
        self.comb4.clear();
        self.allpass1.clear();
        self.allpass2.clear();
    }
};

// =============================================================================
// Freeverb (Stereo)
// =============================================================================

/// Freeverb - improved Schroeder reverb with stereo output
/// Based on Jezar's public domain implementation
pub const Freeverb = struct {
    // 8 comb filters per channel (L/R with offset delays)
    comb_l: [8]CombFilter(2048) = @as([8]CombFilter(2048), @splat(.{})),
    comb_r: [8]CombFilter(2048) = @as([8]CombFilter(2048), @splat(.{})),

    // 4 allpass filters per channel
    allpass_l: [4]AllpassFilter(1024) = @as([4]AllpassFilter(1024), @splat(.{})),
    allpass_r: [4]AllpassFilter(1024) = @as([4]AllpassFilter(1024), @splat(.{})),

    // Parameters
    room_size: f32 = 0.5,
    damping: f32 = 0.5,
    width: f32 = 1.0,
    mix: f32 = 0.3,

    // Derived
    wet1: f32 = 0.5,
    wet2: f32 = 0.5,

    sample_rate: f32,

    const Self = @This();

    // Delay times (samples at 44100)
    const COMB_TUNING = [8]usize{ 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
    const ALLPASS_TUNING = [4]usize{ 556, 441, 341, 225 };
    const STEREO_SPREAD = 23;

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.updateDelays();
        self.updateParameters();
        return self;
    }

    pub fn setRoomSize(self: *Self, size: f32) void {
        self.room_size = math.clamp(size, 0, 1);
        self.updateParameters();
    }

    pub fn setDamping(self: *Self, damp: f32) void {
        self.damping = math.clamp(damp, 0, 1);
        self.updateParameters();
    }

    pub fn setWidth(self: *Self, width: f32) void {
        self.width = math.clamp(width, 0, 1);
        self.wet1 = (1.0 + self.width) / 2.0;
        self.wet2 = (1.0 - self.width) / 2.0;
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    fn updateDelays(self: *Self) void {
        const scale = self.sample_rate / 44100.0;

        for (0..8) |i| {
            const base_delay = @as(usize, @intFromFloat(@as(f32, @floatFromInt(COMB_TUNING[i])) * scale));
            self.comb_l[i].delay.setDelay(base_delay);
            self.comb_r[i].delay.setDelay(base_delay + STEREO_SPREAD);
        }

        for (0..4) |i| {
            const base_delay = @as(usize, @intFromFloat(@as(f32, @floatFromInt(ALLPASS_TUNING[i])) * scale));
            self.allpass_l[i].delay.setDelay(base_delay);
            self.allpass_r[i].delay.setDelay(base_delay + STEREO_SPREAD);
        }
    }

    fn updateParameters(self: *Self) void {
        const feedback = 0.7 + self.room_size * 0.28;

        for (0..8) |i| {
            self.comb_l[i].setFeedback(feedback);
            self.comb_l[i].setDamp(self.damping);
            self.comb_r[i].setFeedback(feedback);
            self.comb_r[i].setDamp(self.damping);
        }

        for (0..4) |i| {
            self.allpass_l[i].setFeedback(0.5);
            self.allpass_r[i].setFeedback(0.5);
        }
    }

    pub fn process(self: *Self, left: f32, right: f32) struct { left: f32, right: f32 } {
        const input = (left + right) * 0.5;

        // Parallel comb filters
        var out_l: f32 = 0;
        var out_r: f32 = 0;

        for (0..8) |i| {
            out_l += self.comb_l[i].process(input);
            out_r += self.comb_r[i].process(input);
        }

        // Series allpass for diffusion
        for (0..4) |i| {
            out_l = self.allpass_l[i].process(out_l);
            out_r = self.allpass_r[i].process(out_r);
        }

        // Stereo width
        const wet_l = out_l * self.wet1 + out_r * self.wet2;
        const wet_r = out_r * self.wet1 + out_l * self.wet2;

        // Mix
        const scale = 0.1; // Output scaling
        return .{
            .left = left * (1.0 - self.mix) + wet_l * self.mix * scale,
            .right = right * (1.0 - self.mix) + wet_r * self.mix * scale,
        };
    }

    pub fn reset(self: *Self) void {
        for (0..8) |i| {
            self.comb_l[i].clear();
            self.comb_r[i].clear();
        }
        for (0..4) |i| {
            self.allpass_l[i].clear();
            self.allpass_r[i].clear();
        }
    }
};

// =============================================================================
// Early Reflections
// =============================================================================

/// Early reflections simulator for room character
pub const EarlyReflections = struct {
    // Tap delays (simulating wall reflections)
    delay_line: DelayLine(8192) = .{},
    tap_times: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    tap_gains: [8]f32 = .{ 0.5, 0.4, 0.35, 0.3, 0.25, 0.2, 0.15, 0.1 },

    mix: f32 = 0.3,
    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setRoomSize(30); // 30ms room
        return self;
    }

    /// Set room size in milliseconds (affects reflection times)
    pub fn setRoomSize(self: *Self, ms: f32) void {
        const base = ms * self.sample_rate / 1000.0;

        // Reflection pattern simulating rectangular room
        self.tap_times[0] = @as(usize, @intFromFloat(base * 0.1));
        self.tap_times[1] = @as(usize, @intFromFloat(base * 0.2));
        self.tap_times[2] = @as(usize, @intFromFloat(base * 0.35));
        self.tap_times[3] = @as(usize, @intFromFloat(base * 0.5));
        self.tap_times[4] = @as(usize, @intFromFloat(base * 0.65));
        self.tap_times[5] = @as(usize, @intFromFloat(base * 0.8));
        self.tap_times[6] = @as(usize, @intFromFloat(base * 0.9));
        self.tap_times[7] = @as(usize, @intFromFloat(base * 1.0));
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Write to delay line
        self.delay_line.write(input);

        // Sum taps
        var wet: f32 = 0;
        for (self.tap_times, self.tap_gains) |time, gain| {
            if (time > 0) {
                wet += self.delay_line.readAt(time) * gain;
            }
        }

        return input * (1.0 - self.mix) + wet * self.mix;
    }

    pub fn reset(self: *Self) void {
        self.delay_line.clear();
    }
};

// =============================================================================
// Plate Reverb
// =============================================================================

/// Plate reverb - dense, metallic character
/// Simplified Dattorro plate design with stability improvements
pub const PlateReverb = struct {
    // Input diffusion (4 allpass)
    input_ap: [4]AllpassFilter(1024) = @as([4]AllpassFilter(1024), @splat(.{})),

    // Tank (cross-coupled delay networks)
    tank_delay_l: DelayLine(4096) = .{},
    tank_delay_r: DelayLine(4096) = .{},
    tank_ap_l: [2]AllpassFilter(1024) = @as([2]AllpassFilter(1024), @splat(.{})),
    tank_ap_r: [2]AllpassFilter(1024) = @as([2]AllpassFilter(1024), @splat(.{})),

    // Damping filters
    damp_l: f32 = 0,
    damp_r: f32 = 0,

    // Parameters
    decay: f32 = 0.5,
    damping: f32 = 0.5,
    mix: f32 = 0.3,

    sample_rate: f32,

    const Self = @This();

    // Soft clipping to prevent runaway feedback
    fn softClip(x: f32) f32 {
        // tanh-like soft clipper
        if (x > 1.0) return 1.0 - 1.0 / (1.0 + (x - 1.0));
        if (x < -1.0) return -1.0 + 1.0 / (1.0 - (x + 1.0));
        return x;
    }

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setupDelays();
        self.updateDecay();
        return self;
    }

    fn setupDelays(self: *Self) void {
        const scale = self.sample_rate / 44100.0;

        // Input diffusion (moderate feedback for stability)
        self.input_ap[0].delay.setDelay(@as(usize, @intFromFloat(142.0 * scale)));
        self.input_ap[1].delay.setDelay(@as(usize, @intFromFloat(107.0 * scale)));
        self.input_ap[2].delay.setDelay(@as(usize, @intFromFloat(379.0 * scale)));
        self.input_ap[3].delay.setDelay(@as(usize, @intFromFloat(277.0 * scale)));

        for (&self.input_ap) |*ap| {
            ap.setFeedback(0.625); // Reduced from 0.75 for stability
        }

        // Tank delays
        self.tank_delay_l.setDelay(@as(usize, @intFromFloat(672.0 * scale)));
        self.tank_delay_r.setDelay(@as(usize, @intFromFloat(908.0 * scale)));

        // Tank allpass
        self.tank_ap_l[0].delay.setDelay(@as(usize, @intFromFloat(1800.0 * scale)));
        self.tank_ap_l[1].delay.setDelay(@as(usize, @intFromFloat(2656.0 * scale)));
        self.tank_ap_r[0].delay.setDelay(@as(usize, @intFromFloat(1944.0 * scale)));
        self.tank_ap_r[1].delay.setDelay(@as(usize, @intFromFloat(2424.0 * scale)));
    }

    pub fn setDecay(self: *Self, decay: f32) void {
        self.decay = math.clamp(decay, 0, 0.95); // Reduced max from 0.99 for stability
        self.updateDecay();
    }

    pub fn setDamping(self: *Self, damp: f32) void {
        self.damping = math.clamp(damp, 0, 1);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    fn updateDecay(self: *Self) void {
        // Reduced feedback range: 0.4 to 0.7 (was 0.5 to 0.95)
        const fb = 0.4 + self.decay * 0.3;
        for (&self.tank_ap_l) |*ap| ap.setFeedback(fb);
        for (&self.tank_ap_r) |*ap| ap.setFeedback(fb);
    }

    pub fn process(self: *Self, left: f32, right: f32) struct { left: f32, right: f32 } {
        const input = (left + right) * 0.5;

        // Input diffusion with soft clipping
        var diffused = input;
        for (&self.input_ap) |*ap| {
            diffused = ap.process(diffused);
        }
        diffused = softClip(diffused);

        // Read from tank (cross-coupled)
        const tank_l = self.tank_delay_l.read();
        const tank_r = self.tank_delay_r.read();

        // Damping (one-pole lowpass)
        self.damp_l = tank_r * (1.0 - self.damping) + self.damp_l * self.damping;
        self.damp_r = tank_l * (1.0 - self.damping) + self.damp_r * self.damping;

        // Process through tank allpass with decay and soft clipping
        var proc_l = softClip(self.damp_l) * self.decay;
        var proc_r = softClip(self.damp_r) * self.decay;

        for (&self.tank_ap_l) |*ap| proc_l = ap.process(proc_l);
        for (&self.tank_ap_r) |*ap| proc_r = ap.process(proc_r);

        // Soft clip processed signals
        proc_l = softClip(proc_l);
        proc_r = softClip(proc_r);

        // Write back to tank with input (reduced feedback contribution)
        self.tank_delay_l.write(diffused * 0.5 + proc_l * 0.5);
        self.tank_delay_r.write(diffused * 0.5 + proc_r * 0.5);

        // Output taps (reduced wet signal level)
        const out_l = tank_l * 0.5 + proc_l * 0.25;
        const out_r = tank_r * 0.5 + proc_r * 0.25;

        return .{
            .left = left * (1.0 - self.mix) + out_l * self.mix,
            .right = right * (1.0 - self.mix) + out_r * self.mix,
        };
    }

    pub fn reset(self: *Self) void {
        for (&self.input_ap) |*ap| ap.clear();
        for (&self.tank_ap_l) |*ap| ap.clear();
        for (&self.tank_ap_r) |*ap| ap.clear();
        self.tank_delay_l.clear();
        self.tank_delay_r.clear();
        self.damp_l = 0;
        self.damp_r = 0;
    }
};

// =============================================================================
// Simple Spring Reverb
// =============================================================================

/// Spring reverb emulation
pub const SpringReverb = struct {
    // Two cascaded allpass chains with modulation
    allpass: [6]AllpassFilter(512) = @as([6]AllpassFilter(512), @splat(.{})),

    // Chirp filter (characteristic spring sound)
    chirp_delay: DelayLine(256) = .{},
    chirp_feedback: f32 = 0.7,

    // Modulation
    mod_phase: f32 = 0,
    mod_rate: f32 = 0.5, // Hz

    mix: f32 = 0.3,
    sample_rate: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        var self = Self{ .sample_rate = sample_rate };
        self.setup();
        return self;
    }

    fn setup(self: *Self) void {
        // Allpass delays (irregular spacing for less metallic sound)
        const delays = [6]usize{ 113, 179, 233, 311, 401, 487 };
        for (&self.allpass, delays) |*ap, d| {
            ap.delay.setDelay(d);
            ap.setFeedback(0.6);
        }

        self.chirp_delay.setDelay(73);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0, 1);
    }

    pub fn setTension(self: *Self, tension: f32) void {
        // Tension affects allpass feedback and chirp
        const t = math.clamp(tension, 0, 1);
        const fb = 0.5 + t * 0.35;
        for (&self.allpass) |*ap| {
            ap.setFeedback(fb);
        }
        self.chirp_feedback = 0.6 + t * 0.25;
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Modulation
        self.mod_phase += self.mod_rate / self.sample_rate;
        if (self.mod_phase >= 1.0) self.mod_phase -= 1.0;

        // Chirp section
        const chirp_out = self.chirp_delay.read();
        self.chirp_delay.write(input + chirp_out * self.chirp_feedback);

        // Allpass chain
        var signal = input + chirp_out * 0.5;
        for (&self.allpass) |*ap| {
            signal = ap.process(signal);
        }

        return input * (1.0 - self.mix) + signal * self.mix * 0.5;
    }

    pub fn reset(self: *Self) void {
        for (&self.allpass) |*ap| ap.clear();
        self.chirp_delay.clear();
        self.mod_phase = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "schroeder reverb basic" {
    const testing = std.testing;

    var reverb = SchroederReverb.init(44100);
    reverb.setRoomSize(0.5);
    reverb.setDamping(0.5);
    reverb.setMix(0.5);

    // Process impulse
    var output = reverb.process(1.0);
    try testing.expect(output != 0);

    // Process silence, should decay
    for (0..10000) |_| {
        output = reverb.process(0);
    }
}

test "freeverb stereo" {
    const testing = std.testing;

    var reverb = Freeverb.init(44100);
    reverb.setRoomSize(0.7);
    reverb.setWidth(1.0);

    const result = reverb.process(1.0, 1.0);
    try testing.expect(result.left != 0 or result.right != 0);
}

test "plate reverb" {
    var rev = PlateReverb.init(44100);
    rev.setDecay(0.8);

    const result = rev.process(1.0, 0.0);
    _ = result;

    // Process more samples
    for (0..1000) |_| {
        _ = rev.process(0, 0);
    }
}
