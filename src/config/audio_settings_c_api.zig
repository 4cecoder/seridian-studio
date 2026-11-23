//! C ABI for the persisted audio device and backend selection (`$XDG_CONFIG_HOME/seridian/daw/audio.conf`).
//! Called from the Raven UI: load once at startup, save after the Settings dialog applies.

const std = @import("std");
const AudioEngine = @import("../audio/engine.zig").AudioEngine;
const audio_settings = @import("audio_settings.zig");
const sys = @import("../utils/sys.zig");

const log = std.log.scoped(.audio_settings);

inline fn castEngine(engine: ?*anyopaque) ?*AudioEngine {
    return if (engine) |eng| @ptrCast(@alignCast(eng)) else null;
}

/// Reads the saved settings and applies them with the engine setters. A missing or corrupt
/// file applies the defaults. Returns 0, or -1 for a null engine or an unusable settings path.
/// Setters that the engine refuses are logged and skipped; the engine keeps its current value.
/// The backend is applied first because switching it resets the output device.
pub export fn seridian_audio_settings_load(engine: ?*anyopaque) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const allocator = std.heap.c_allocator;

    const path = audio_settings.defaultPath(allocator) catch |err| {
        log.warn("cannot resolve the audio settings path: {}", .{err});
        return -1;
    };
    defer allocator.free(path);

    var settings = audio_settings.loadFrom(allocator, path) catch |err| {
        log.warn("cannot load audio settings from {s}: {}", .{ path, err });
        return -1;
    };
    defer settings.deinit(allocator);

    log.info("loaded audio settings from {s}: backend={s} output='{s}' input='{s}' sample_rate={d} buffer_size={d}", .{
        path, settings.backend, settings.output_device, settings.input_device, settings.sample_rate, settings.buffer_size,
    });

    // DAW_AUDIO_BACKEND overrides the saved backend, as it overrides the config at startup.
    const backend = sys.getenv("DAW_AUDIO_BACKEND") orelse settings.backend;
    eng.setBackend(backend) catch |err| log.warn("backend '{s}' not applied: {}", .{ backend, err });
    eng.setBufferSize(settings.buffer_size) catch |err| log.warn("saved buffer size {d} not applied: {}", .{ settings.buffer_size, err });
    eng.setSampleRate(settings.sample_rate) catch |err| log.warn("saved sample rate {d} not applied: {}", .{ settings.sample_rate, err });
    eng.setOutputDevice(settings.output_device) catch |err| log.warn("saved output device '{s}' not applied: {}", .{ settings.output_device, err });
    eng.setInputDevice(settings.input_device) catch |err| log.warn("saved input device '{s}' not applied: {}", .{ settings.input_device, err });
    return 0;
}

/// Writes the engine's current backend, output and input device, sample rate and buffer size to the
/// settings file, atomically. Returns 0, or -1 for a null engine or a failed write.
pub export fn seridian_audio_settings_save(engine: ?*anyopaque) callconv(.c) c_int {
    const eng = castEngine(engine) orelse return -1;
    const allocator = std.heap.c_allocator;

    const path = audio_settings.defaultPath(allocator) catch |err| {
        log.warn("cannot resolve the audio settings path: {}", .{err});
        return -1;
    };
    defer allocator.free(path);

    const settings: audio_settings.AudioSettings = .{
        .output_device = eng.outputDeviceName(),
        .input_device = eng.inputDeviceName(),
        .sample_rate = eng.config.sample_rate,
        .buffer_size = eng.config.buffer_size,
        .backend = eng.backendPreference(),
    };
    audio_settings.saveTo(allocator, path, settings) catch |err| {
        log.warn("cannot save audio settings to {s}: {}", .{ path, err });
        return -1;
    };

    log.info("saved audio settings to {s}: backend={s} output='{s}' input='{s}' sample_rate={d} buffer_size={d}", .{
        path, settings.backend, settings.output_device, settings.input_device, settings.sample_rate, settings.buffer_size,
    });
    return 0;
}
