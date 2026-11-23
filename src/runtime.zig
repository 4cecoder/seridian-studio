//! Engine-side startup and shutdown, exported as a small C ABI.
//!
//! `libdaw-engine` owns every piece of engine state (audio engine, MIDI,
//! project system, config). The `daw` executable and `libdaw-ui` only ever
//! hold the opaque pointers returned here, so no Zig globals are duplicated
//! across the shared-library boundary.

const std = @import("std");
const audio = @import("audio/engine.zig");
const midi = @import("midi/midi.zig");
const midi_recording = @import("midi/midi_recording.zig");
const config = @import("config/config.zig");
const project_c_api = @import("project/project_c_api.zig");
const sys = @import("utils/sys.zig");

const log = std.log.scoped(.runtime);

/// Startup stages reported to the splash screen (values match
/// splash_screen_gtk.h).
pub const Stage = enum(c_int) {
    config = 1,
    audio_engine = 2,
    audio_backend = 3,
    midi = 4,
    project = 5,
};

/// Progress callback: stage plus an optional detail string (valid only for
/// the duration of the call).
pub const ProgressFn = *const fn (stage: c_int, detail: ?[*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;

const Runtime = struct {
    gpa: std.heap.DebugAllocator(.{}),
    cfg: config.Config,
    engine: audio.AudioEngine,
    midi_backend: midi.MIDIBackend,
    /// project_init keeps this pointer for the lifetime of the project system.
    allocator_holder: std.mem.Allocator,
    project_ready: bool,
};

fn report(progress: ?ProgressFn, user_data: ?*anyopaque, stage: Stage, detail: ?[]const u8) void {
    const cb = progress orelse return;
    var buf: [256]u8 = undefined;
    const detail_z: ?[*:0]const u8 = if (detail) |d|
        (std.fmt.bufPrintSentinel(&buf, "{s}", .{d[0..@min(d.len, buf.len - 1)]}, 0) catch unreachable).ptr
    else
        null;
    cb(@backingInt(stage), detail_z, user_data);
}

/// MIDI event callback - routes MIDI to armed tracks and records if active.
/// Runs on the MIDI backend's thread, so notes are queued for the audio thread
/// instead of touching voices that the audio thread is rendering.
fn midiEventCallback(event: midi.MIDIEvent, user_data: ?*anyopaque) void {
    const engine: *audio.AudioEngine = @ptrCast(@alignCast(user_data orelse return));

    // First armed track, else track 0.
    var target_track: usize = 0;
    for (0..audio.AudioEngine.TRACK_COUNT) |i| {
        if (engine.getTrackArm(i)) {
            target_track = i;
            break;
        }
    }

    switch (event.message) {
        .note_on => |note| {
            if (!engine.queueNoteOn(target_track, note.note, note.velocity)) log.warn("MIDI note dropped: event queue full", .{});
            midi_recording.midi_recording_note_on(event.timestamp, event.channel, note.note, note.velocity);
        },
        .note_off => |note| {
            if (!engine.queueNoteOff(target_track, note.note)) log.warn("MIDI note off dropped: event queue full", .{});
            midi_recording.midi_recording_note_off(event.timestamp, event.channel, note.note, note.velocity);
        },
        else => {},
    }
}

/// Load config, start the audio engine and MIDI, and initialize the project
/// system. Returns null on failure (details are logged).
export fn daw_runtime_create(progress: ?ProgressFn, user_data: ?*anyopaque) callconv(.c) ?*Runtime {
    return create(progress, user_data) catch |err| {
        log.err("Startup failed: {}", .{err});
        return null;
    };
}

fn create(progress: ?ProgressFn, user_data: ?*anyopaque) !*Runtime {
    const rt = try std.heap.c_allocator.create(Runtime);
    errdefer std.heap.c_allocator.destroy(rt);
    rt.gpa = .init;
    errdefer _ = rt.gpa.deinit();
    const allocator = rt.gpa.allocator();
    rt.allocator_holder = allocator;
    rt.project_ready = false;

    report(progress, user_data, .config, null);
    rt.cfg = config.Config.load(allocator) catch |err| blk: {
        log.warn("Failed to load config: {}, using defaults", .{err});
        break :blk config.Config.default();
    };
    errdefer rt.cfg.deinit(allocator);
    // DAW_AUDIO_BACKEND (auto/pipewire/pulse/none) overrides the config,
    // for test harnesses and troubleshooting.
    const backend_preference = sys.getenv("DAW_AUDIO_BACKEND") orelse rt.cfg.audio.backend;
    log.info("Audio backend: {s}, {d} Hz, buffer {d}", .{ backend_preference, rt.cfg.audio.sample_rate, rt.cfg.audio.buffer_size });

    report(progress, user_data, .audio_engine, null);
    rt.engine = try audio.AudioEngine.init(allocator, .{
        .sample_rate = rt.cfg.audio.sample_rate,
        .buffer_size = rt.cfg.audio.buffer_size,
        .backend_preference = backend_preference,
    });
    errdefer rt.engine.deinit();

    report(progress, user_data, .audio_backend, @tagName(rt.engine.backend));
    rt.engine.connectBackend();
    log.info("Audio engine initialized: {s}", .{@tagName(rt.engine.backend)});

    // MIDI is optional; continue without it.
    report(progress, user_data, .midi, null);
    rt.midi_backend = midi.MIDIBackend.init(allocator) catch |err| blk: {
        log.warn("MIDI initialization failed: {}, continuing without MIDI", .{err});
        break :blk midi.MIDIBackend{ .none = {} };
    };
    errdefer rt.midi_backend.deinit();
    if (rt.midi_backend.isAvailable()) {
        rt.midi_backend.connectAllSources() catch |err| log.warn("Failed to connect MIDI sources: {}", .{err});
        rt.midi_backend.setEventCallback(midiEventCallback, &rt.engine);
        log.info("MIDI initialized: {d} sources, {d} destinations", .{
            rt.midi_backend.getSourceCount(),
            rt.midi_backend.getDestinationCount(),
        });
    }

    report(progress, user_data, .project, null);
    if (project_c_api.project_init(@ptrCast(&rt.allocator_holder)) != 0) return error.ProjectInitFailed;
    rt.project_ready = true;

    return rt;
}

/// The engine pointer the UI passes to the audio_engine_* C API.
export fn daw_runtime_engine(rt: *Runtime) callconv(.c) *anyopaque {
    return &rt.engine;
}

/// Stop audio and MIDI, shut down the project system, and free everything.
export fn daw_runtime_destroy(rt: *Runtime) callconv(.c) void {
    if (rt.project_ready) project_c_api.project_deinit();
    rt.midi_backend.deinit();
    rt.engine.deinit();
    rt.cfg.deinit(rt.gpa.allocator());
    if (rt.gpa.deinit() == .leak) log.warn("Engine allocator reported leaks", .{});
    std.heap.c_allocator.destroy(rt);
}
