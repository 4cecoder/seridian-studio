//! Tests for per-track input sources (TDD: written before the implementation).
//!
//! Expected API:
//!   Track.input_device: i32 = -1 (none), Track.input_enabled: bool = false
//!   project.TrackState.input_device: u8 = 0 (0 = none, n = capture device index + 1)
//!   audio/capture_source.zig: CaptureSource { context, read } and AudioEngine.setCaptureSource

const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;
const Track = @import("track.zig").Track;
const capture_source = @import("capture_source.zig");
const project_mod = @import("../project/project.zig");
const persistence = @import("../project/persistence.zig");
const sys = @import("../utils/sys.zig");

test "Track input: defaults to none and setters round-trip" {
    const testing = std.testing;
    var track = Track.init(testing.allocator);
    defer track.deinit();

    try testing.expectEqual(@as(i32, -1), track.input_device);
    try testing.expect(!track.input_enabled);

    track.input_device = 3;
    track.input_enabled = true;
    try testing.expectEqual(@as(i32, 3), track.input_device);
    try testing.expect(track.input_enabled);

    track.input_device = -1;
    track.input_enabled = false;
    try testing.expectEqual(@as(i32, -1), track.input_device);
    try testing.expect(!track.input_enabled);
}

test "Track input: saved and loaded with the project, 0 meaning none" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var project = project_mod.Project.init();
    try testing.expectEqual(@as(u8, 0), project.tracks[0].input_device);
    project.tracks[1].input_device = 2;
    project.tracks[5].input_device = 7;

    const dir = "persistence_input_tmp";
    try sys.makePath(dir);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), dir) catch {};
    try persistence.saveProject(allocator, &project, dir);
    const loaded = try persistence.loadProject(allocator, dir);

    try testing.expectEqual(@as(u8, 0), loaded.tracks[0].input_device);
    try testing.expectEqual(@as(u8, 2), loaded.tracks[1].input_device);
    try testing.expectEqual(@as(u8, 7), loaded.tracks[5].input_device);
}

/// Fake capture device: every read returns the same constant sample.
const ConstantCapture = struct {
    value: f32,

    fn read(context: *anyopaque, device: i32, out: []f32) usize {
        _ = device;
        const self: *ConstantCapture = @ptrCast(@alignCast(context));
        @memset(out, self.value);
        return out.len;
    }

    fn source(self: *ConstantCapture) capture_source.CaptureSource {
        return .{ .context = self, .read = read };
    }
};

fn peakOf(buf: []const f32) f32 {
    var peak: f32 = 0.0;
    for (buf) |s| peak = @max(peak, @abs(s));
    return peak;
}

test "AudioEngine: audio track with input enabled mixes the captured block" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 64 });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    engine.setMasterGain(1.0);
    engine.setTrackGain(2, 1.0);

    var fake = ConstantCapture{ .value = 0.5 };
    engine.setCaptureSource(fake.source());

    // Input not enabled yet: the track stays silent.
    engine.tracks[2].input_device = 0;
    var silent: [128]f32 = @splat(0.0);
    engine.process(&silent);
    try testing.expect(peakOf(&silent) < 0.001);

    engine.tracks[2].input_enabled = true;
    var output: [128]f32 = @splat(0.0);
    engine.process(&output);
    try testing.expect(peakOf(&output) > 0.1);
    try testing.expect(engine.getTrackMeter(2) > 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0.0), engine.getTrackMeter(0), 0.001);
}

/// Fake capture device: device 0 delivers a single unit impulse on its first read.
const ImpulseCapture = struct {
    fired: bool = false,

    fn read(context: *anyopaque, device: i32, out: []f32) usize {
        const self: *ImpulseCapture = @ptrCast(@alignCast(context));
        @memset(out, 0.0);
        if (device == 0 and !self.fired and out.len >= 2) {
            out[0] = 1.0;
            out[1] = 1.0;
            self.fired = true;
        }
        return out.len;
    }

    fn source(self: *ImpulseCapture) capture_source.CaptureSource {
        return .{ .context = self, .read = read };
    }
};

test "AudioEngine: delay compensation lines a plain track up with a delayed one" {
    const testing = std.testing;
    var engine = try AudioEngine.init(testing.allocator, .{ .sample_rate = 48000, .buffer_size = 64 });
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    engine.setMasterGain(1.0);
    engine.setTrackGain(0, 1.0);

    // Track 1 carries a latency-adding effect but is muted: track 0 must still be
    // delayed by exactly that latency so the two would line up at the master bus.
    _ = try engine.getTrackEffects(1).?.addEffect(.vocal_tune);
    engine.setTrackMute(1, true);
    const latency = engine.getTrackEffects(1).?.latencySamples();
    try testing.expect(latency > 0);
    try testing.expectEqual(latency, engine.effectsLatencyFrames());

    var impulse = ImpulseCapture{};
    engine.setCaptureSource(impulse.source());
    engine.tracks[0].input_device = 0;
    engine.tracks[0].input_enabled = true;

    const block = 64;
    const total = latency + 4 * block;
    const left = try testing.allocator.alloc(f32, total);
    defer testing.allocator.free(left);
    var done: usize = 0;
    while (done < total) : (done += block) {
        var out: [block * 2]f32 = @splat(0.0);
        engine.process(&out);
        const n = @min(block, total - done);
        for (0..n) |i| left[done + i] = out[i * 2];
    }

    var peak_at: usize = 0;
    for (left, 0..) |s, i| {
        if (@abs(s) > @abs(left[peak_at])) peak_at = i;
    }
    try testing.expectEqual(latency, peak_at);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left[peak_at], 1e-6);
}
