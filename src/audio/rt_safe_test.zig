const std = @import("std");
const testing = std.testing;
const rt_safe = @import("rt_safe.zig");

test "RealTimeSafeAllocator - allows allocation off audio thread" {
    const allocator = rt_safe.init(testing.allocator);

    // Not an audio thread: should succeed
    rt_safe.is_audio_thread = false;
    const ptr = try allocator.alloc(u8, 1024);
    allocator.free(ptr);
}

test "rt_safe - thread local state tracking" {
    rt_safe.is_audio_thread = false;
    try testing.expect(!rt_safe.is_audio_thread);

    rt_safe.is_audio_thread = true;
    try testing.expect(rt_safe.is_audio_thread);

    rt_safe.is_audio_thread = false;
    try testing.expect(!rt_safe.is_audio_thread);
}

/// Wraps an allocator and counts every allocation, resize, remap and free that reaches it.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    calls: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.parent.rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.parent.rawResize(buf, alignment, len, ret);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.parent.rawRemap(buf, alignment, len, ret);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.parent.rawFree(buf, alignment, ret);
    }
};

test "AudioEngine.process allocates nothing with notes, clips, automation, effects and queued events" {
    const AudioEngine = @import("engine.zig").AudioEngine;
    const midi_clip = @import("../midi/midi_clip.zig");
    var counting: CountingAllocator = .{ .parent = testing.allocator };
    var engine = try AudioEngine.init(counting.allocator(), .{ .sample_rate = 48000, .buffer_size = 128, .backend_preference = "none" });
    defer engine.deinit();
    engine.setUseTestTones(false);

    // Everything the audio thread can meet: an instrument with clip notes, an audio clip,
    // latent and plain effects (PDC), every automation lane, queued and hardware notes.
    try engine.tracks[0].setInstrument(@import("../instruments/instruments.zig").getInstrumentType(0).?);
    midi_clip.midi_clip_clear(0);
    defer midi_clip.midi_clip_clear(0);
    midi_clip.midi_clip_set_start_beat(0, 0.0);
    for (0..16) |i| {
        try testing.expect(midi_clip.midi_clip_add_note(0, @as(f64, @floatFromInt(i)) * 0.0625, 0.05, @intCast(48 + i), 100) != 0);
    }
    var samples: [4096]f32 = @splat(0.25);
    try engine.tracks[1].loadFromBuffer(&samples, 2, 48000);
    _ = try engine.addTrackEffect(1, .reverb);
    _ = try engine.addTrackEffect(1, .vocal_tune);
    _ = try engine.addMasterEffect(.compressor);
    try engine.addAutomationPoint(.track_gain, 1, 0.0, 0.2);
    try engine.addAutomationPoint(.track_gain, 1, 1.0, 0.9);
    try engine.addAutomationPoint(.track_pan, 1, 0.0, -1.0);
    try engine.addAutomationPoint(.track_wet, 1, 0.0, 0.0);
    try engine.addAutomationPoint(.track_wet, 1, 1.0, 1.0);
    try engine.addAutomationPoint(.master_gain, 0, 0.0, 0.5);

    engine.playing.store(true, .monotonic);
    var output: [256]f32 = undefined;
    engine.process(&output); // warm-up block outside the measurement
    const before = counting.calls.load(.monotonic);
    rt_safe.is_audio_thread = true;
    defer rt_safe.is_audio_thread = false;
    for (0..400) |i| {
        if (i % 10 == 0) {
            try testing.expect(engine.queueNoteOn(0, 72, 90));
            try testing.expect(engine.queueNoteOff(0, 72));
            try testing.expect(engine.midi_ring.push(.{ .note = 60, .velocity = 80, .on = i % 20 == 0 }));
            engine.setTrackGain(0, if (i % 20 == 0) 0.3 else 0.8);
        }
        engine.process(&output);
    }
    try testing.expectEqual(before, counting.calls.load(.monotonic));
}
