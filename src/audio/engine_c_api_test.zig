const std = @import("std");
const AudioEngine = @import("engine.zig").AudioEngine;
const capi = @import("engine_c_api.zig");

test "C API - Engine Control Sanity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 1. Initialize engine
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 44100,
        .buffer_size = 256,
    });
    defer engine.deinit();

    // The C API expects a *anyopaque (void*)
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    // 2. Test play/stop toggling via C API
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_is_playing(engine_ptr));

    // We can't easily call audio_engine_start because it tries to init the hardware backend
    // but we can manually trigger the atomic flag that the C API reads
    engine.playing.store(true, .monotonic);
    try testing.expectEqual(@as(c_int, 1), capi.audio_engine_is_playing(engine_ptr));

    engine.playing.store(false, .monotonic);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_is_playing(engine_ptr));

    // 3. Test parameter setting via C API (gain/pan)
    capi.audio_engine_set_track_gain(engine_ptr, 0, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.getTrackGain(0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), capi.audio_engine_get_track_gain(engine_ptr, 0), 0.001);

    capi.audio_engine_set_track_pan(engine_ptr, 1, -0.75);
    try testing.expectApproxEqAbs(@as(f32, -0.75), engine.getTrackPan(1), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.75), capi.audio_engine_get_track_pan(engine_ptr, 1), 0.001);

    capi.audio_engine_set_master_gain(engine_ptr, 0.9);
    try testing.expectApproxEqAbs(@as(f32, 0.9), engine.getMasterGain(), 0.001);

    // 4. Test mute/solo via C API
    capi.audio_engine_set_track_mute(engine_ptr, 2, 1);
    try testing.expect(engine.getTrackMute(2));
    try testing.expectEqual(@as(c_int, 1), capi.audio_engine_get_track_mute(engine_ptr, 2));

    capi.audio_engine_set_track_solo(engine_ptr, 3, 1);
    try testing.expect(engine.getTrackSolo(3));
    try testing.expectEqual(@as(c_int, 1), capi.audio_engine_get_track_solo(engine_ptr, 3));
}

test "C API - MIDI Helpers" {
    const testing = std.testing;

    // C keys are white
    try testing.expectEqual(@as(c_int, 0), capi.midi_is_black_key(60)); // C4
    try testing.expectEqual(@as(c_int, 0), capi.midi_is_black_key(62)); // D4

    // Sharps are black
    try testing.expectEqual(@as(c_int, 1), capi.midi_is_black_key(61)); // C#4
    try testing.expectEqual(@as(c_int, 1), capi.midi_is_black_key(63)); // D#4
}

// Settings tests use the "none" backend so no audio server is needed.
fn newNoneEngine(allocator: std.mem.Allocator) !AudioEngine {
    return AudioEngine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 256,
        .backend_preference = "none",
    });
}

test "C API - invalid buffer size is rejected and old value kept" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    for ([_]u32{ 0, 100, 300, 4096 }) |frames| {
        try testing.expectEqual(@as(c_int, -2), capi.audio_engine_set_buffer_size(engine_ptr, frames));
        try testing.expectEqual(@as(u32, 256), capi.audio_engine_get_buffer_size(engine_ptr));
        try testing.expectEqual(@as(u32, 256), engine.config.buffer_size);
    }
}

test "C API - valid buffer size is reported by the getter" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    for ([_]u32{ 64, 128, 256, 512, 1024, 2048 }) |frames| {
        try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_buffer_size(engine_ptr, frames));
        try testing.expectEqual(frames, capi.audio_engine_get_buffer_size(engine_ptr));
        try testing.expectEqual(frames, engine.config.buffer_size);
    }
}

test "C API - invalid sample rate is rejected and old value kept" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    for ([_]u32{ 0, 22050, 192000 }) |rate| {
        try testing.expectEqual(@as(c_int, -2), capi.audio_engine_set_sample_rate(engine_ptr, rate));
        try testing.expectEqual(@as(u32, 48000), capi.audio_engine_get_sample_rate(engine_ptr));
    }
}

test "C API - valid sample rate is reported and position is rescaled" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    capi.audio_engine_set_position(engine_ptr, 48000);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_sample_rate(engine_ptr, 96000));
    try testing.expectEqual(@as(u32, 96000), capi.audio_engine_get_sample_rate(engine_ptr));
    try testing.expectEqual(@as(u64, 96000), capi.audio_engine_get_position(engine_ptr));
}

test "C API - settings change keeps the transport state" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    // Stopped engine: setters must leave it stopped.
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_buffer_size(engine_ptr, 128));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_is_playing(engine_ptr));

    // Playing engine: the backend is rebuilt and restarted, playback continues.
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_start(engine_ptr));
    defer capi.audio_engine_stop(engine_ptr);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_buffer_size(engine_ptr, 64));
    try testing.expectEqual(@as(c_int, 1), capi.audio_engine_is_playing(engine_ptr));
    try testing.expectEqual(@as(u32, 64), capi.audio_engine_get_buffer_size(engine_ptr));
}

test "C API - output device" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    var buf: [128]u8 = @splat(0xAA);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_get_output_device(engine_ptr, &buf, buf.len));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    // Default sink is always accepted.
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_output_device(engine_ptr, ""));

    // The none backend cannot route to a named sink.
    try testing.expectEqual(@as(c_int, -3), capi.audio_engine_set_output_device(engine_ptr, "alsa_output.fake"));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_get_output_device(engine_ptr, &buf, buf.len));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    // 128 bytes or longer is rejected before the backend is consulted.
    var long_name: [128:0]u8 = @splat('a');
    try testing.expectEqual(@as(c_int, -2), capi.audio_engine_set_output_device(engine_ptr, &long_name));

    // An empty name fits a one-byte buffer (just the NUL).
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_get_output_device(engine_ptr, &buf, 1));

    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_set_output_device(engine_ptr, null));
}

test "C API - input device" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    var buf: [128]u8 = @splat(0xAA);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_get_input_device(engine_ptr, &buf, buf.len));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    // Input capture does not depend on the playback backend, so a named source is stored.
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_input_device(engine_ptr, "alsa_input.fake"));
    try testing.expectEqual(@as(c_int, 15), capi.audio_engine_get_input_device(engine_ptr, &buf, buf.len));
    try testing.expectEqualStrings("alsa_input.fake", buf[0..15]);
    try testing.expectEqual(@as(u8, 0), buf[15]);

    // The name plus NUL must fit: 15 chars need 16 bytes.
    try testing.expectEqual(@as(c_int, -2), capi.audio_engine_get_input_device(engine_ptr, &buf, 15));
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(c_int, -2), capi.audio_engine_get_input_device(engine_ptr, &buf, 1));

    var long_name: [128:0]u8 = @splat('a');
    try testing.expectEqual(@as(c_int, -2), capi.audio_engine_set_input_device(engine_ptr, &long_name));
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_set_input_device(engine_ptr, null));

    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_input_device(engine_ptr, ""));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_get_input_device(engine_ptr, &buf, buf.len));
}

test "C API - setters refuse while recording" {
    // A real capture needs a PulseAudio/PipeWire input, which this test does not have. The engine
    // refuses on its own `recording` flag, so the flag is set directly to exercise that guard.
    // The module-level recording state (recording_is_active) is not covered here.
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    engine.recording.store(true, .monotonic);
    defer engine.recording.store(false, .monotonic);

    try testing.expectEqual(@as(c_int, -5), capi.audio_engine_set_output_device(engine_ptr, ""));
    try testing.expectEqual(@as(c_int, -5), capi.audio_engine_set_input_device(engine_ptr, ""));
    try testing.expectEqual(@as(c_int, -5), capi.audio_engine_set_buffer_size(engine_ptr, 128));
    try testing.expectEqual(@as(c_int, -5), capi.audio_engine_set_sample_rate(engine_ptr, 96000));

    try testing.expectEqual(@as(u32, 256), capi.audio_engine_get_buffer_size(engine_ptr));
    try testing.expectEqual(@as(u32, 48000), capi.audio_engine_get_sample_rate(engine_ptr));
}

test "C API - backend name" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    var buf: [32]u8 = @splat(0xAA);
    try testing.expectEqual(@as(c_int, 4), capi.audio_engine_get_backend(engine_ptr, &buf, buf.len));
    try testing.expectEqualStrings("none", buf[0..4]);
    try testing.expectEqual(@as(u8, 0), buf[4]);
}

test "C API - track instrument type survives display names that differ from the type name" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_get_track_instrument_type(engine_ptr, 1));
    // ModelPiano (19) registers the display name "Model Piano"; the type must still come back as 19.
    const types = [_]c_int{ 19, 15, 16, 17 };
    for (types) |t| {
        try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_instrument(engine_ptr, 1, t));
        try testing.expectEqual(t, capi.audio_engine_get_track_instrument_type(engine_ptr, 1));
    }
    engine.tracks[1].removeInstrument();
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_get_track_instrument_type(engine_ptr, 1));
}

test "C API - instrument names round-trip: what set accepts is what state reports" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    const count = capi.audio_engine_get_instrument_type_count();
    var type_: c_int = 0;
    while (type_ < count) : (type_ += 1) {
        const listed = capi.audio_engine_get_instrument_type_name(type_);
        try testing.expectEqual(type_, capi.audio_engine_find_instrument_type(listed));
        try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_instrument(engine_ptr, 2, type_));
        // The name state reports for the track is the listed name, not the instrument's display name.
        try testing.expectEqualStrings(std.mem.span(listed), std.mem.span(capi.audio_engine_get_track_instrument_name(engine_ptr, 2)));
    }
    try testing.expectEqual(@as(c_int, 19), capi.audio_engine_find_instrument_type("Model Piano"));
    try testing.expectEqual(@as(c_int, 19), capi.audio_engine_find_instrument_type("modelpiano"));
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_find_instrument_type("Nope"));
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_find_instrument_type(""));
}

test "C API - track reverb on, wet and off" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    const engine_ptr: *anyopaque = @ptrCast(&engine);

    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_track_has_reverb(engine_ptr, 3));
    try testing.expect(capi.audio_engine_get_track_reverb_wet(engine_ptr, 3) < 0.0);
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_set_track_reverb_wet(engine_ptr, 3, 0.4));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_reverb(engine_ptr, 3, 1));
    try testing.expectEqual(@as(c_int, 1), capi.audio_engine_track_has_reverb(engine_ptr, 3));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_reverb_wet(engine_ptr, 3, 0.4));
    try testing.expectApproxEqAbs(@as(f32, 0.4), capi.audio_engine_get_track_reverb_wet(engine_ptr, 3), 0.001);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_reverb(engine_ptr, 3, 0));
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_track_has_reverb(engine_ptr, 3));
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_set_track_reverb(engine_ptr, 99, 1));
    try testing.expectEqual(@as(c_int, -1), capi.audio_engine_set_track_reverb(engine_ptr, -1, 1));
}

fn peakOf(buf: []const f32) f32 {
    var peak: f32 = 0.0;
    for (buf) |s| peak = @max(peak, @abs(s));
    return peak;
}

test "C API - note on/off from a control thread are applied by the audio thread, not by the caller" {
    const testing = std.testing;
    var engine = try newNoneEngine(testing.allocator);
    defer engine.deinit();
    engine.setUseTestTones(false);
    engine.setMasteringEnabled(false);
    const engine_ptr: *anyopaque = @ptrCast(&engine);
    try testing.expectEqual(@as(c_int, 0), capi.audio_engine_set_track_instrument(engine_ptr, 0, 0));

    // The caller (UI, CLI socket or MIDI thread) must not touch voice state: the audio thread
    // renders those voices at the same time.
    capi.audio_engine_note_on(engine_ptr, 0, 60, 100);
    try testing.expect(!engine.tracks[0].is_active);

    var output: [1024]f32 = @splat(0.0);
    engine.process(&output);
    try testing.expect(engine.tracks[0].is_active);
    try testing.expect(peakOf(&output) > 0.001);

    // All notes off is deferred the same way, then silences the track's voices.
    capi.audio_engine_all_notes_off(engine_ptr, 0);
    capi.audio_engine_note_off(engine_ptr, 0, 60);
    for (0..200) |_| engine.process(&output);
    try testing.expect(peakOf(&output) < 0.0001);

    // Out-of-range tracks are refused instead of indexing past the track array.
    capi.audio_engine_note_on(engine_ptr, -1, 60, 100);
    capi.audio_engine_note_on(engine_ptr, 99, 60, 100);
    engine.process(&output);
}
