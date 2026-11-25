//! Test entry point - runs all unit tests without GTK dependencies
//!
//! This file imports all testable modules for unit testing.

const std = @import("std");

// Core audio modules
pub const clip = @import("audio/clip.zig");
pub const wav = @import("audio/wav.zig");
pub const peak_cache = @import("audio/peak_cache.zig");
pub const device_parse = @import("audio/device_parse.zig");
pub const devices = @import("audio/devices.zig");

pub const config = @import("config/config.zig");
pub const audio_settings = @import("config/audio_settings.zig");
pub const monitors = @import("config/monitors.zig");
pub const popout_settings = @import("config/popout_settings.zig");

// DSP modules
pub const dsp = @import("dsp/dsp.zig");

// Effects
pub const effects = @import("effects/effects.zig");

// Instruments
pub const instruments = @import("instruments/instruments.zig");

// MIDI
pub const coremidi = @import("midi/coremidi.zig");
pub const note_ring = @import("midi/note_ring.zig");
pub const event_queue = @import("audio/event_queue.zig");
pub const alsa_seq = @import("midi/alsa_seq.zig");
pub const midi_recording = @import("midi/midi_recording.zig");

// Core
pub const sys = @import("utils/sys.zig");
pub const recording = @import("audio/recording.zig");
pub const null_backend = @import("audio/null_backend.zig");
pub const pdc = @import("audio/pdc.zig");
pub const pipewire = @import("audio/pipewire.zig");
pub const spa_pod = @import("audio/spa_pod.zig");
pub const pw_stream = if (@import("builtin").os.tag == .linux) @import("audio/pw_stream.zig") else struct {};
pub const undo = @import("core/undo.zig");

// Project & Persistence
pub const project = @import("project/project.zig");
pub const persistence = @import("project/persistence.zig");
pub const persistence_test = @import("project/persistence_integration_test.zig");
pub const recovery = @import("project/recovery.zig");
pub const project_c_api = @import("project/project_c_api.zig");

// Audio & C API
pub const audio_engine = @import("audio/engine.zig");
pub const engine_c_api = @import("audio/engine_c_api.zig");
pub const engine_c_api_test = @import("audio/engine_c_api_test.zig");
pub const mastering = @import("audio/mastering.zig");
pub const rt_safe_test = @import("audio/rt_safe_test.zig");
pub const track_input_test = @import("audio/track_input_test.zig");

// System preflight (`seridian doctor`); ported from feat/overhaul 4914565
pub const file_error = @import("utils/file_error.zig");
pub const desktop = @import("system/desktop.zig");
pub const preflight = @import("system/preflight.zig");
pub const preflight_types = @import("system/preflight_types.zig");
pub const preflight_c_api = @import("system/preflight_c_api.zig");
pub const single_instance = @import("system/single_instance.zig");
// The UI library's hand-written mirrors of engine C ABI structs.
pub const ui_abi_test = @import("ui_abi_test.zig");

// Run all tests
test {
    std.testing.refAllDecls(@This());
}
