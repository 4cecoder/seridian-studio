//! Root of libdaw-engine: the audio engine, DSP, instruments, effects, MIDI,
//! project and config systems, exposed to the GTK UI and the `daw`
//! executable through C ABI exports only.

const std = @import("std");

comptime {
    _ = @import("runtime.zig");
    _ = @import("audio/engine_c_api.zig");
    _ = @import("audio/clip_c_api.zig");
    _ = @import("audio/effects_c_api.zig");
    _ = @import("audio/scale_c_api.zig");
    _ = @import("audio/devices_c_api.zig");
    _ = @import("audio/export.zig");
    _ = @import("audio/recording.zig");
    _ = @import("config/settings_c_api.zig");
    _ = @import("config/audio_settings_c_api.zig");
    _ = @import("config/popout_settings_c_api.zig");
    _ = @import("system/system_c_api.zig");
    _ = @import("system/preflight_c_api.zig");
    _ = @import("project/project_c_api.zig");
    _ = @import("project/recovery.zig");
    _ = @import("core/undo.zig");
    _ = @import("midi/midi_recording.zig");
    _ = @import("midi/midi_clip.zig");
}

pub const std_options: std.Options = .{
    .log_level = .info,
};
