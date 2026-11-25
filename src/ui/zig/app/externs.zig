//! C functions the Seridian Studio window calls outside Raven: the engine's C ABI (libdaw-engine), and the
//! Zig widgets that are built as separate static libraries with C exports (piano roll, knob, keymap).
//!
//! Translated from the declaration block of src/ui/raven_app.c. There is no @cImport in this toolchain, so
//! every prototype is hand-written; each one must match the exporting `export fn` exactly (a wrong type links
//! fine and fails at run time). Pointers are C pointers, as in the C file.

const raven = @import("raven");

pub extern fn audio_engine_start(engine: ?*anyopaque) c_int;
pub extern fn audio_engine_stop(engine: ?*anyopaque) void;
pub extern fn audio_engine_is_playing(engine: ?*anyopaque) c_int;
pub extern fn audio_engine_set_position(engine: ?*anyopaque, position: u64) void;
pub extern fn audio_engine_get_position(engine: ?*anyopaque) u64;
pub extern fn audio_engine_get_sample_rate(engine: ?*anyopaque) u32;
pub extern fn audio_engine_set_tempo(engine: ?*anyopaque, bpm: f32) void;
pub extern fn audio_engine_get_tempo(engine: ?*anyopaque) f32;
pub extern fn audio_engine_set_track_gain(engine: ?*anyopaque, track: c_int, gain: f32) void;
pub extern fn audio_engine_get_track_gain(engine: ?*anyopaque, track: c_int) f32;
pub extern fn audio_engine_set_track_pan(engine: ?*anyopaque, track: c_int, pan: f32) void;
pub extern fn audio_engine_get_track_pan(engine: ?*anyopaque, track: c_int) f32;
pub extern fn audio_engine_set_track_arm(engine: ?*anyopaque, track: c_int, armed: c_int) void;
pub extern fn audio_engine_get_track_arm(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn audio_engine_set_master_gain(engine: ?*anyopaque, gain: f32) void;
pub extern fn audio_engine_automation_add(engine: ?*anyopaque, target: c_int, track: c_int, beat: f64, value: f32) c_int;
pub extern fn audio_engine_automation_clear(engine: ?*anyopaque, target: c_int, track: c_int) c_int;
pub extern fn audio_engine_track_has_reverb(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn audio_engine_set_track_reverb(engine: ?*anyopaque, track: c_int, on: c_int) c_int;
pub extern fn audio_engine_get_track_reverb_wet(engine: ?*anyopaque, track: c_int) f32;
pub extern fn audio_engine_set_track_reverb_wet(engine: ?*anyopaque, track: c_int, wet: f32) c_int;
pub extern fn audio_engine_eq_preset(engine: ?*anyopaque, track: c_int, name: [*c]const u8) c_int;
pub extern fn audio_engine_eq_master_tilt(engine: ?*anyopaque, on: c_int) c_int;
pub extern fn audio_engine_set_track_mute(engine: ?*anyopaque, track: c_int, muted: c_int) void;
pub extern fn audio_engine_get_track_mute(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn audio_engine_set_track_solo(engine: ?*anyopaque, track: c_int, soloed: c_int) void;
pub extern fn audio_engine_get_track_solo(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn audio_engine_get_track_meter(engine: ?*anyopaque, track: c_int) f32;
pub extern fn audio_engine_get_master_meter_left(engine: ?*anyopaque) f32;
pub extern fn audio_engine_get_master_meter_right(engine: ?*anyopaque) f32;

pub extern fn track_get_clip_count(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn track_get_clip_id(engine: ?*anyopaque, track: c_int, clip_idx: c_int) u64;
pub extern fn track_get_clip_start(engine: ?*anyopaque, track: c_int, clip_id: u64) f64;
pub extern fn track_get_clip_duration(engine: ?*anyopaque, track: c_int, clip_id: u64) f64;
pub extern fn track_get_clip_name(engine: ?*anyopaque, track: c_int, clip_id: u64) [*c]const u8;
pub extern fn track_set_clip_position(engine: ?*anyopaque, track: c_int, clip_id: u64, start_time: f64) c_int;
pub extern fn track_set_clip_duration(engine: ?*anyopaque, track: c_int, clip_id: u64, duration: f64) c_int;
pub extern fn track_remove_clip(engine: ?*anyopaque, track: c_int, clip_id: u64) c_int;
pub extern fn track_split_clip(engine: ?*anyopaque, track: c_int, clip_id: u64, split_time: f64) u64;
pub extern fn track_get_clip_gain(engine: ?*anyopaque, track: c_int, clip_id: u64) f32;
pub extern fn track_set_clip_gain(engine: ?*anyopaque, track: c_int, clip_id: u64, gain: f32) c_int;
pub extern fn track_get_clip_fade_in(engine: ?*anyopaque, track: c_int, clip_id: u64) f32;
pub extern fn track_set_clip_fade_in(engine: ?*anyopaque, track: c_int, clip_id: u64, fade_in: f32) c_int;
pub extern fn track_get_clip_fade_out(engine: ?*anyopaque, track: c_int, clip_id: u64) f32;
pub extern fn track_set_clip_fade_out(engine: ?*anyopaque, track: c_int, clip_id: u64, fade_out: f32) c_int;
pub extern fn track_get_clip_muted(engine: ?*anyopaque, track: c_int, clip_id: u64) c_int;
pub extern fn track_set_clip_muted(engine: ?*anyopaque, track: c_int, clip_id: u64, muted: c_int) c_int;
pub extern fn audio_engine_clear_track_audio(engine: ?*anyopaque, track: c_int) void;

pub extern fn get_effect_type_count() c_int;
pub extern fn get_effect_type_name(index: c_int) [*c]const u8;
pub extern fn track_get_effect_count(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn track_get_effect_name(engine: ?*anyopaque, track: c_int, slot: c_int) [*c]const u8;
pub extern fn track_get_effect_bypassed(engine: ?*anyopaque, track: c_int, slot: c_int) c_int;
pub extern fn track_add_effect(engine: ?*anyopaque, track: c_int, effect_type: c_int) c_int;
pub extern fn track_remove_effect(engine: ?*anyopaque, track: c_int, slot: c_int) c_int;
pub extern fn track_set_effect_bypass(engine: ?*anyopaque, track: c_int, slot: c_int, bypassed: c_int) void;
pub extern fn effect_get_param_count(engine: ?*anyopaque, track: c_int, slot: c_int) c_int;
pub extern fn effect_get_param_name(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) [*c]const u8;
pub extern fn effect_get_param_value(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) f32;
pub extern fn effect_get_param_min(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) f32;
pub extern fn effect_get_param_max(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int) f32;
pub extern fn effect_set_param_value(engine: ?*anyopaque, track: c_int, slot: c_int, param: c_int, value: f32) void;

pub extern fn audio_engine_get_instrument_type_count() c_int;
pub extern fn audio_engine_get_instrument_type_name(index: c_int) [*c]const u8;
pub extern fn audio_engine_find_instrument_type(name: [*c]const u8) c_int;
pub extern fn audio_engine_set_track_instrument(engine: ?*anyopaque, track: c_int, instrument_type: c_int) c_int;
pub extern fn audio_engine_remove_track_instrument(engine: ?*anyopaque, track: c_int) void;
pub extern fn audio_engine_track_has_instrument(engine: ?*anyopaque, track: c_int) c_int;
pub extern fn audio_engine_get_track_instrument_name(engine: ?*anyopaque, track: c_int) [*c]const u8;
pub extern fn audio_engine_get_track_instrument_type(engine: ?*anyopaque, track: c_int) c_int;

pub extern fn project_get_name() [*c]const u8;
pub extern fn project_capture_engine(engine: ?*anyopaque) c_int;
pub extern fn project_apply_engine(engine: ?*anyopaque) c_int;
pub extern fn project_engine_signature(engine: ?*anyopaque) u64;
pub extern fn project_last_error() [*c]const u8;
pub extern fn project_set_track_name(track: c_int, name: [*c]const u8) void;
pub extern fn project_get_track_name(track: c_int) [*c]const u8;

// Engine note input (engine_c_api.zig).
pub extern fn audio_engine_note_on(engine: ?*anyopaque, track: c_int, note: c_int, velocity: c_int) void;
pub extern fn audio_engine_note_off(engine: ?*anyopaque, track: c_int, note: c_int) void;

// Per-track MIDI clip (midi_clip.zig, exported from libdaw-engine).
pub extern fn midi_clip_get_note_count(track: c_int) c_int;
pub extern fn midi_clip_get_note(track: c_int, index: c_int, out_id: [*c]u32, out_start_beat: [*c]f64, out_duration: [*c]f64, out_pitch: [*c]u8, out_velocity: [*c]u8, out_selected: [*c]c_int) c_int;
pub extern fn midi_clip_add_note(track: c_int, start_beat: f64, duration: f64, pitch: u8, velocity: u8) u32;
pub extern fn midi_clip_remove_note(track: c_int, note_id: u32) c_int;
pub extern fn midi_clip_set_note_selected(track: c_int, note_id: u32, selected: c_int) c_int;
pub extern fn midi_clip_resize_note(track: c_int, note_id: u32, new_duration: f64) c_int;
pub extern fn midi_clip_move_selected(track: c_int, delta_beat: f64, delta_pitch: c_int) void;
pub extern fn midi_clip_select_in_rect(track: c_int, beat_start: f64, beat_end: f64, pitch_low: u8, pitch_high: u8, add_to_selection: c_int) void;
pub extern fn midi_clip_deselect_all(track: c_int) void;

/// `void (*)(int, int, int, int, int, float, float, uint64_t)`: the engine undo stack's apply callback.
pub const UndoApplyFn = ?*const fn (c_int, c_int, c_int, c_int, c_int, f32, f32, u64) callconv(.c) void;
pub extern fn undo_init() c_int;
pub extern fn undo_undo() c_int;
pub extern fn undo_redo() c_int;
pub extern fn undo_record_clip(action_type: c_int, track: c_int, clip_id: u64, description: [*c]const u8) c_int;
pub extern fn undo_clear() void;
pub extern fn undo_set_apply_callback(callback: UndoApplyFn) void;
pub extern fn midi_clip_clear(track: c_int) void;
pub extern fn audio_export_wav(engine: ?*anyopaque, path: [*c]const u8, duration_seconds: f64, bit_depth: c_int) c_int;
pub extern fn midi_clip_select_all(track: c_int) void;
pub extern fn midi_clip_delete_selected(track: c_int) c_int;

// Piano roll widget (src/ui/zig/piano_roll.zig). Layout matches PianoRollConfig there.
pub const SeridianPianoRollChanged = ?*const fn (kind: c_int, pitch: c_int, start_beat: f64, length_beats: f64, user_data: ?*anyopaque) callconv(.c) void;
/// Selection and edit gestures (EditCommand in piano_roll.zig; layout matches it field for field).
pub const PianoRollEditCommand = extern struct {
    kind: c_int,
    pitch: c_int,
    pitch_high: c_int,
    delta_pitch: c_int,
    selected: c_int,
    additive: c_int,
    start_beat: f64,
    length_beats: f64,
    delta_beats: f64,
};
pub const PIANO_CMD_SELECT_NOTE: c_int = 0;
pub const PIANO_CMD_SELECT_RECT: c_int = 1;
pub const PIANO_CMD_MOVE_SELECTED: c_int = 2;
pub const PIANO_CMD_RESIZE_SELECTED: c_int = 3;
pub const PIANO_CMD_DELETE_SELECTED: c_int = 4;
pub const PIANO_CMD_SELECT_ALL: c_int = 5;
pub const SeridianPianoRollEdit = ?*const fn (command: [*c]const PianoRollEditCommand, user_data: ?*anyopaque) callconv(.c) void;
pub const PianoRollConfig = extern struct {
    view_start_beat: f64,
    px_per_beat: f64,
    top_pitch: c_int,
    base_pitch: c_int,
    row_height: f32,
    grid_index: c_int,
    width: f32,
    height: f32,
    on_key: ?*const fn (pitch: c_int, down: c_int, user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};
pub extern fn piano_roll_create(config: [*c]const PianoRollConfig) raven.Rid;
pub extern fn piano_roll_set_on_change(widget: raven.Rid, callback: SeridianPianoRollChanged, user_data: ?*anyopaque) void;
pub extern fn piano_roll_set_on_edit(widget: raven.Rid, callback: SeridianPianoRollEdit, user_data: ?*anyopaque) void;
pub extern fn piano_roll_set_grid(widget: raven.Rid, index: c_int) void;
pub extern fn piano_roll_set_base_pitch(widget: raven.Rid, pitch: c_int) void;
pub extern fn piano_roll_set_key_lit(widget: raven.Rid, pitch: c_int, lit: c_int) void;
pub extern fn piano_roll_add_note(widget: raven.Rid, pitch: c_int, start_beat: f64, length_beats: f64, selected: c_int) c_int;
pub extern fn piano_roll_clear_notes(widget: raven.Rid) void;
pub extern fn piano_roll_set_playhead(widget: raven.Rid, beat: f64, follow: c_int) void;

pub extern fn project_set_bpm(bpm: f32) void;
pub extern fn project_get_bpm() f32;
pub extern fn project_set_master_volume(volume: f32) void;
pub extern fn project_get_master_volume() f32;
pub extern fn project_set_track_pan(track: c_int, pan: f32) void;
pub extern fn project_set_track_volume(track: c_int, volume: f32) void;
pub extern fn project_get_track_volume(track: c_int) f32;
pub extern fn project_get_track_pan(track: c_int) f32;
pub extern fn project_set_track_muted(track: c_int, muted: c_int) void;
pub extern fn project_get_track_muted(track: c_int) c_int;
pub extern fn project_set_track_solo(track: c_int, solo: c_int) void;
pub extern fn project_get_track_solo(track: c_int) c_int;
pub extern fn project_set_track_armed(track: c_int, armed: c_int) void;
pub extern fn project_get_track_armed(track: c_int) c_int;
pub extern fn project_set_track_instrument(track: c_int, instrument_type: c_int) void;
pub extern fn project_get_track_instrument(track: c_int) c_int;
pub extern fn project_get_time_sig_num() c_int;
pub extern fn project_new() c_int;
pub extern fn project_save(folder_path: [*c]const u8) c_int;
pub extern fn project_save_as(folder_path: [*c]const u8) c_int;
pub extern fn audio_export_last_peak() f32;
pub extern fn project_load(folder_path: [*c]const u8) c_int;
pub extern fn project_save_copy(folder_path: [*c]const u8) c_int;
pub extern fn project_load_unsaved(folder_path: [*c]const u8) c_int;

// Autosave and crash recovery (project/recovery.zig).
pub extern fn recovery_pending() c_int;
pub extern fn recovery_mark_running() c_int;
pub extern fn recovery_mark_clean() c_int;
pub extern fn recovery_discard() c_int;
pub extern fn recovery_session_path() [*c]const u8;
pub extern fn project_has_save_location() c_int;
pub extern fn project_get_folder_path() [*c]const u8;

// Audio device enumeration (src/audio/devices_c_api.zig). Returned pointers are valid until the next enumeration.
pub extern fn audio_init_devices(allocator: ?*anyopaque) void;
pub extern fn audio_enumerate_output_devices() c_int;
pub extern fn audio_enumerate_input_devices() c_int;
pub extern fn audio_get_output_device_name(index: c_int) [*c]const u8;
pub extern fn audio_get_output_device_description(index: c_int) [*c]const u8;
pub extern fn audio_get_input_device_name(index: c_int) [*c]const u8;
pub extern fn audio_get_input_device_description(index: c_int) [*c]const u8;

// Supported sample rates and buffer sizes (src/system/system_c_api.zig).
pub const SampleRateList = extern struct {
    rates: [8]u32,
    count: u32,
};
pub const BufferSizeList = extern struct {
    sizes: [8]u32,
    count: u32,
};
pub extern fn system_get_available_sample_rates() SampleRateList;
pub extern fn system_get_available_buffer_sizes() BufferSizeList;

// Engine device, buffer and backend settings. Setters return 0 on success, see docs/development/audio-settings.md.
pub extern fn audio_engine_get_output_device(engine: ?*anyopaque, out_buf: [*c]u8, len: usize) c_int;
pub extern fn audio_engine_get_input_device(engine: ?*anyopaque, out_buf: [*c]u8, len: usize) c_int;
pub extern fn audio_engine_get_backend(engine: ?*anyopaque, out_buf: [*c]u8, len: usize) c_int;
pub extern fn audio_engine_get_buffer_size(engine: ?*anyopaque) u32;
// Persisted device selection (src/config/audio_settings_c_api.zig): audio.conf in the XDG config dir.
pub extern fn seridian_audio_settings_load(engine: ?*anyopaque) c_int;
pub extern fn seridian_audio_settings_save(engine: ?*anyopaque) c_int;

// Persisted Piano Roll popout (src/config/popout_settings_c_api.zig): popouts.conf in the XDG config dir.
pub extern fn seridian_popout_load(x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int, monitor: [*c]u8, monitor_capacity: usize, dx: [*c]c_int, dy: [*c]c_int) c_int;
pub extern fn seridian_popout_save(open: c_int, x: c_int, y: c_int, width: c_int, height: c_int, monitor: [*c]const u8, dx: c_int, dy: c_int) c_int;
pub extern fn seridian_popout_locate(text: [*c]const u8, text_len: usize, px: c_int, py: c_int, name: [*c]u8, name_capacity: usize, origin_x: [*c]c_int, origin_y: [*c]c_int) c_int;
pub extern fn seridian_popout_plan(text: [*c]const u8, text_len: usize, saved_monitor: [*c]const u8, saved_x: c_int, saved_y: c_int, saved_dx: c_int, saved_dy: c_int, main_cx: c_int, main_cy: c_int, name: [*c]u8, name_capacity: usize, dx: [*c]c_int, dy: [*c]c_int, width: [*c]c_int, height: [*c]c_int) c_int;
/// Geometry to restore with, clamped to the monitor holding (center_x, center_y). 1: clamped; 0: monitor unknown,
/// size sanitised only (do not move the window); -1: bad argument.
pub extern fn seridian_popout_restore(x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int, center_x: c_int, center_y: c_int) c_int;
// Persisted Mixer popout: mixerpopout.conf in the XDG config dir, the same format as popouts.conf.
pub extern fn seridian_mixer_popout_load(x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int, monitor: [*c]u8, monitor_capacity: usize, dx: [*c]c_int, dy: [*c]c_int) c_int;
pub extern fn seridian_mixer_popout_save(open: c_int, x: c_int, y: c_int, width: c_int, height: c_int, monitor: [*c]const u8, dx: c_int, dy: c_int) c_int;
pub extern fn audio_engine_set_output_device(engine: ?*anyopaque, name: [*c]const u8) c_int;
pub extern fn audio_engine_set_backend(engine: ?*anyopaque, name: [*c]const u8) c_int;
pub extern fn audio_engine_get_backend_preference(engine: ?*anyopaque, out_buf: [*c]u8, len: usize) c_int;
pub extern fn audio_engine_set_input_device(engine: ?*anyopaque, name: [*c]const u8) c_int;
pub extern fn audio_engine_set_sample_rate(engine: ?*anyopaque, rate: u32) c_int;
pub extern fn audio_engine_set_buffer_size(engine: ?*anyopaque, frames: u32) c_int;
pub extern fn audio_engine_midi_input_count(engine: ?*anyopaque) c_int;
/// Copies input `index`'s name into buf (NUL-terminated); returns its length or -1.
pub extern fn audio_engine_midi_input_name(engine: ?*anyopaque, index: c_int, buf: [*c]u8, buf_len: c_int) c_int;
pub extern fn audio_engine_midi_input_set_enabled(engine: ?*anyopaque, index: c_int, enabled: c_int) c_int;

// ---- Rotary knob (src/ui/zig/knob.zig, was knob.h) ----

pub const SeridianKnobChanged = ?*const fn (value: f32, user_data: ?*anyopaque) callconv(.c) void;
pub const SeridianKnobConfig = extern struct {
    minimum: f32,
    maximum: f32,
    value: f32,
    default_value: f32,
    diameter: f32,
    /// Bipolar knobs (pan) draw their value arc from the centre, not the minimum.
    bipolar: c_int,
    on_change: SeridianKnobChanged,
    user_data: ?*anyopaque,
};
/// Creates a knob widget. The widget owns its state and frees it on destroy.
pub extern fn seridian_knob_create(config: [*c]const SeridianKnobConfig) raven.Rid;

// ---- Keymap (src/ui/zig/keymap.zig, was keymap.h). The tags must stay in the order of the Zig Action enum. ----

/// `SeridianAction` (a C enum): used as a plain c_int, like the constants below.
pub const SeridianAction = c_int;
pub const SERIDIAN_ACTION_NONE: c_int = 0;
pub const SERIDIAN_ACTION_PLAY_STOP: c_int = 1;
pub const SERIDIAN_ACTION_STOP_AND_REWIND: c_int = 2;
pub const SERIDIAN_ACTION_UNDO: c_int = 3;
pub const SERIDIAN_ACTION_REDO: c_int = 4;
pub const SERIDIAN_ACTION_SELECT_ALL: c_int = 5;
pub const SERIDIAN_ACTION_COPY: c_int = 6;
pub const SERIDIAN_ACTION_CUT: c_int = 7;
pub const SERIDIAN_ACTION_PASTE: c_int = 8;
pub const SERIDIAN_ACTION_DUPLICATE: c_int = 9;
pub const SERIDIAN_ACTION_DELETE: c_int = 10;
pub const SERIDIAN_ACTION_SPLIT_AT_PLAYHEAD: c_int = 11;
pub const SERIDIAN_ACTION_FILE_NEW: c_int = 12;
pub const SERIDIAN_ACTION_FILE_OPEN: c_int = 13;
pub const SERIDIAN_ACTION_FILE_SAVE: c_int = 14;
pub const SERIDIAN_ACTION_FILE_SAVE_AS: c_int = 15;
pub const SERIDIAN_ACTION_VIEW_ARRANGEMENT: c_int = 16;
pub const SERIDIAN_ACTION_VIEW_PIANO_ROLL: c_int = 17;
pub const SERIDIAN_ACTION_ZOOM_IN: c_int = 18;
pub const SERIDIAN_ACTION_ZOOM_OUT: c_int = 19;
pub const SERIDIAN_ACTION_POPOUT_PIANO_ROLL: c_int = 20;
pub const SERIDIAN_ACTION_POPOUT_MIXER: c_int = 21;
pub const SERIDIAN_ACTION_FILE_EXPORT_WAV: c_int = 22;
pub const SERIDIAN_ACTION_TOGGLE_FULLSCREEN: c_int = 23;
/// Help text and status-bar hint rendered from the keymap table for this platform; NUL-terminated into `out`.
/// Return the length, or -1 when `capacity` is too small.
pub extern fn seridian_keymap_help(out: [*]u8, capacity: usize) c_int;
pub extern fn seridian_keymap_hint(out: [*]u8, capacity: usize) c_int;
/// Key text of an action's first binding ("Ctrl+Shift+S"), NUL-terminated into `out`; -1 when unbound or too small.
pub extern fn seridian_keymap_shortcut(action: c_int, out: [*]u8, capacity: usize) c_int;
/// 1 when F11 should restore a window that is maximized, 0 when it should maximize it.
pub extern fn seridian_keymap_restore_on_f11(is_maximized: c_int) c_int;
/// Action for an RKey code and RModifier bits, or SERIDIAN_ACTION_NONE.
pub extern fn seridian_keymap_lookup(key: c_int, modifiers: c_uint) c_int;

test "keymap action tags match the Zig Action enum" {
    const std = @import("std");
    const keymap = @import("../keymap.zig");
    try std.testing.expectEqual(@as(c_int, @backingInt(keymap.Action.popout_mixer)), SERIDIAN_ACTION_POPOUT_MIXER);
    try std.testing.expectEqual(@as(c_int, @backingInt(keymap.Action.play_stop)), SERIDIAN_ACTION_PLAY_STOP);
    try std.testing.expectEqual(@as(c_int, @backingInt(keymap.Action.toggle_fullscreen)), SERIDIAN_ACTION_TOGGLE_FULLSCREEN);
    try std.testing.expectEqual(@as(usize, @intCast(SERIDIAN_ACTION_TOGGLE_FULLSCREEN)) + 1, @typeInfo(keymap.Action).@"enum".field_names.len);
}

// ---- System preflight (src/system/preflight_c_api.zig, exported from libdaw-engine) ----

const preflight_report = @import("../preflight_report.zig");
/// Runs every check, reading the live engine; only safe on the UI thread, which owns the engine settings. The
/// window uses `daw_preflight_snapshot` (UI thread) + `daw_preflight_run_snapshot` (worker) instead.
pub extern fn daw_preflight_run(out: *preflight_report.CReport, engine: ?*anyopaque) void;
pub extern fn daw_preflight_snapshot(engine: ?*anyopaque, out: *preflight_report.CEngineSnapshot) void;
pub extern fn daw_preflight_run_snapshot(out: *preflight_report.CReport, snap: ?*const preflight_report.CEngineSnapshot) void;
/// Applies an automatic fix; returns 0 on success. `msg` receives a NUL-terminated description (truncated to
/// `msg_len`).
pub extern fn daw_preflight_apply_fix(fix: u32, engine: ?*anyopaque, msg: [*]u8, msg_len: usize) c_int;
/// Human label for a fix id ("" for none or unknown). Static storage.
pub extern fn daw_preflight_fix_label(fix: u32) [*:0]const u8;
