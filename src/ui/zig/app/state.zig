//! Constants, types and file-scope state of the Seridian Studio window.
//!
//! Translated from src/ui/raven_app.c: every `#define`, `typedef` and file-scope `static` variable of that file
//! lives here, so the files that hold the functions (see fns.zig) share one copy. C globals are zero-initialized;
//! each `var` here spells its C initial value. Ownership: everything is process-global and touched only from the
//! UI thread (Raven's main loop), as in the C.

const std = @import("std");
const raven = @import("raven");
const palette = @import("../palette.zig");

const Rid = raven.Rid;

/// The engine has TRACK_COUNT = 8 (src/audio/engine.zig) but exports no getter, so this mirrors it.
pub const SERIDIAN_TRACK_COUNT = 8;
/// Tracks the project model (project.zig TRACK_COUNT) stores names and mixer state for.
pub const SERIDIAN_PROJECT_TRACKS = 8;
pub const SERIDIAN_CLIP_CAPACITY = 512;
pub const SERIDIAN_FX_POOL_CAPACITY = 256;
pub const SERIDIAN_TRACK_HEIGHT: f32 = 96.0;
pub const SERIDIAN_PAN_KNOB_DIAMETER: f32 = 34.0;
pub const STATE_SNAPSHOT_EVERY_FRAMES: c_uint = 8;
pub const SERIDIAN_MIN_VIEW_SECONDS: f64 = 2.0;
pub const SERIDIAN_DEFAULT_VIEW_SECONDS: f64 = 24.0;
pub const SERIDIAN_FIT_MIN_SECONDS: f64 = 8.0;
pub const SERIDIAN_TAB_SESSION: c_int = 0;
pub const SERIDIAN_TAB_CLIP: c_int = 1;
pub const SERIDIAN_TAB_TRACK_FX: c_int = 2;
pub const SERIDIAN_MAIN_TAB_ARRANGEMENT: c_int = 0;
pub const SERIDIAN_MAIN_TAB_PIANO_ROLL: c_int = 1;
pub const PIANO_ROLL_TOP_PITCH: c_int = 84;
pub const PIANO_ROLL_ROW_HEIGHT: f32 = 12.0;
pub const PIANO_ROLL_PX_PER_BEAT: f64 = 40.0;
pub const PIANO_ROLL_DEFAULT_GRID: c_int = 1;
pub const PIANO_ROLL_DEFAULT_BASE_PITCH: c_int = 60;
pub const PIANO_ROLL_WIDTH: f32 = 640.0;
pub const PIANO_ROLL_HEIGHT: f32 = 480.0;
pub const PIANO_NOTE_VELOCITY: c_int = 100;
pub const PIANO_HELD_SLOTS = 256;
pub const PIANO_CHANGE_ADDED: c_int = 0;
pub const PIANO_CHANGE_REMOVED: c_int = 1;
pub const POPOUT_DEFAULT_WIDTH: c_int = 900;
pub const POPOUT_DEFAULT_HEIGHT: c_int = 600;
pub const POPOUT_MIN_WIDTH: c_int = 480;
pub const POPOUT_MIN_HEIGHT: c_int = 320;
pub const POPOUT_TITLE_CAPACITY = 128;
pub const POPOUT_WINDOW_TITLE_MATCH = "Piano Roll";
pub const POPOUT_MONITOR_NAME_CAPACITY = 64;
pub const WM_OUTPUT_CAPACITY = 2048;
/// A timeout is treated as "no monitor list".
pub const WM_QUERY_TIMEOUT_MS: c_int = 100;
/// Place anyway when the window never reports focus.
pub const POPOUT_PLACE_TIMEOUT_FRAMES: c_uint = 30;
pub const MIXER_POPOUT_DEFAULT_WIDTH: c_int = 1480;
pub const MIXER_POPOUT_DEFAULT_HEIGHT: c_int = 420;
pub const MIXER_POPOUT_MIN_WIDTH: c_int = 640;
pub const MIXER_POPOUT_MIN_HEIGHT: c_int = 340;
pub const MIXER_POPOUT_TITLE = "Mixer";
pub const MIXER_VIEW_DOCK = 0;
pub const MIXER_VIEW_POPOUT = 1;
pub const MIXER_VIEW_COUNT = 2;
/// A knob this close to the engine's pan is left alone (it may be mid-drag).
pub const MIXER_PAN_EPSILON: f32 = 0.002;
/// A moved popout is saved once it has stood still this many frames.
pub const POPOUT_SAVE_SETTLE_FRAMES: c_uint = 8;

pub const ClipBinding = extern struct {
    timeline_item: c_int,
    track: c_int,
    engine_clip: u64,
};

pub const TrackBinding = extern struct {
    track: c_int,
    gain_readout: Rid,
    pan_readout: Rid,
    /// The mixer (docked or popout) this strip belongs to.
    view: [*c]MixerView,
};

/// What one mixer view last showed for a track; the sync loop compares it with the engine.
pub const MixerShown = extern struct {
    valid: c_int,
    gain: f32,
    pan: f32,
    muted: c_int,
    soloed: c_int,
    armed: c_int,
    /// Combo index: 0 is "No instrument".
    instrument: c_int,
    name: [64]u8,
};

/// The track strips plus master strip of one mixer: the docked panel and the popout window each have one,
/// bound to the same engine state. Widgets are R_INVALID_ID while the view does not exist.
pub const MixerView = extern struct {
    window: Rid,
    root: Rid,
    menu: Rid,
    menu_item: Rid,
    /// "Pop out" / "Dock" in the header.
    toggle_button: Rid,
    /// Holds the header menu as its context menu.
    header_title: Rid,
    /// Right-click menus of the name labels; Raven does not own them.
    color_menus: [SERIDIAN_TRACK_COUNT]Rid,
    pan_rows: [SERIDIAN_TRACK_COUNT]Rid,
    name_labels: [SERIDIAN_TRACK_COUNT]Rid,
    color_bars: [SERIDIAN_TRACK_COUNT]Rid,
    instrument_combos: [SERIDIAN_TRACK_COUNT]Rid,
    arm_buttons: [SERIDIAN_TRACK_COUNT]Rid,
    mute_buttons: [SERIDIAN_TRACK_COUNT]Rid,
    solo_buttons: [SERIDIAN_TRACK_COUNT]Rid,
    pan_knobs: [SERIDIAN_TRACK_COUNT]Rid,
    gain_faders: [SERIDIAN_TRACK_COUNT]Rid,
    track_meters: [SERIDIAN_TRACK_COUNT]Rid,
    master_fader: Rid,
    master_meter: Rid,
    master_gain_readout: Rid,
    bindings: [SERIDIAN_TRACK_COUNT]TrackBinding,
    shown: [SERIDIAN_TRACK_COUNT]MixerShown,
    master_shown_valid: c_int,
    master_shown: f32,
};

pub const FxBinding = extern struct {
    track: c_int,
    slot: c_int,
    param: c_int,
};

/// A computer key that is sounding a note. pitch is -1 when the slot is free.
pub const PianoHeldNote = extern struct {
    pitch: c_int,
    track: c_int,
};

pub const SeridianApp = extern struct {
    engine: ?*anyopaque,
    window: Rid,
    timeline: Rid,
    play_button: Rid,
    stop_button: Rid,
    record_button: Rid,
    state_pill: Rid,
    clock_label: Rid,
    position_label: Rid,
    status_label: Rid,
    engine_status: Rid,
    project_label: Rid,
    empty_hint: Rid,
    /// [MIXER_VIEW_DOCK] is the docked panel, [MIXER_VIEW_POPOUT] the Mixer window.
    mixers: [MIXER_VIEW_COUNT]MixerView,
    /// Set from inside the Mixer window; the main loop closes it.
    mixer_dock_requested: c_int,
    /// The `wm size` / `wm place` step waits for the window to map.
    mixer_place_pending: c_int,
    mixer_place_size_only: c_int,
    mixer_place_frames: c_uint,
    mixer_place_monitor: [POPOUT_MONITOR_NAME_CAPACITY]u8,
    mixer_place_dx: c_int,
    mixer_place_dy: c_int,
    mixer_place_w: c_int,
    mixer_place_h: c_int,
    mixer_place_pid: std.c.pid_t,
    mixer_place_argv: [320]u8,
    mixer_seen: [4]c_int,
    mixer_seen_valid: c_int,
    /// The user moved or resized the Mixer window since it opened.
    mixer_user_placed: c_int,
    mixer_stable_frames: c_uint,
    modal_depth: c_int,
    track_color_index: [SERIDIAN_TRACK_COUNT]c_int,
    master_gain: f32,
    state_path: [512]u8,
    bpm_input: Rid,
    tab_view: Rid,
    clip_empty_hint: Rid,
    clip_controls: Rid,
    clip_title: Rid,
    clip_range: Rid,
    clip_gain: Rid,
    clip_gain_readout: Rid,
    clip_fade_in: Rid,
    clip_fade_out: Rid,
    clip_mute: Rid,
    fx_track_combo: Rid,
    fx_type_combo: Rid,
    fx_slots: Rid,
    main_tab_view: Rid,
    piano_roll: Rid,
    piano_track_combo: Rid,
    midi_header_label: Rid,
    midi_status_label: Rid,
    midi_port_combo: Rid,
    midi_track_combo: Rid,
    piano_grid_combo: Rid,
    /// R_INVALID_ID while the Piano Roll is docked.
    popout_window: Rid,
    popout_roll: Rid,
    popout_grid_combo: Rid,
    /// "Pop out" / "Dock" in the Piano Roll tab toolbar.
    popout_toggle_button: Rid,
    /// Set by the popout's key handler; the main loop closes the window.
    popout_dock_requested: c_int,
    /// Output of `seridian wm monitors`, read when the popout opens.
    wm_monitors: [WM_OUTPUT_CAPACITY]u8,
    /// 0 when the helper is missing or failed.
    wm_monitors_len: usize,
    /// A `wm place` waits for the window to map.
    popout_place_pending: c_int,
    /// The pending step is `wm size` (the window manager places the window).
    popout_place_size_only: c_int,
    popout_place_frames: c_uint,
    popout_place_monitor: [POPOUT_MONITOR_NAME_CAPACITY]u8,
    popout_place_dx: c_int,
    popout_place_dy: c_int,
    popout_place_w: c_int,
    popout_place_h: c_int,
    /// Detached `wm place` child, reaped by poll, close and quit.
    popout_place_pid: std.c.pid_t,
    /// The child's command line, for the runtime log.
    popout_place_argv: [320]u8,
    /// Geometry on the previous frame: x, y, width, height.
    popout_seen: [4]c_int,
    /// Geometry in popouts.conf.
    popout_saved: [4]c_int,
    popout_seen_valid: c_int,
    popout_saved_valid: c_int,
    popout_dirty: c_int,
    /// The user moved or resized the popout since it opened.
    popout_user_placed: c_int,
    popout_stable_frames: c_uint,
    piano_track: c_int,
    piano_base_pitch: c_int,
    piano_held: [PIANO_HELD_SLOTS]PianoHeldNote,
    clips: [SERIDIAN_CLIP_CAPACITY]ClipBinding,
    clip_count: usize,
    selected_item: c_int,
    fx_track: c_int,
    syncing: c_int,
    closing: c_int,
};

pub var app: SeridianApp = std.mem.zeroes(SeridianApp);
pub var fx_pool: [SERIDIAN_FX_POOL_CAPACITY]FxBinding = std.mem.zeroes([SERIDIAN_FX_POOL_CAPACITY]FxBinding);
pub var fx_pool_used: usize = 0;

pub const accent_cyan = [3]f32{ 0.000, 0.941, 1.000 };
pub const accent_magenta = [3]f32{ 1.000, 0.169, 0.839 };
pub const muted_text = [3]f32{ 0.420, 0.478, 0.600 };
/// #E6F7FF, time readout and track names.
pub const color_readout = [3]f32{ 0.902, 0.969, 1.000 };
/// #05060D, text on bright fills.
pub const color_ink = [3]f32{ 0.020, 0.024, 0.051 };
/// #2ECC71
pub const color_play_green = [3]f32{ 0.180, 0.800, 0.443 };
/// #FF4D4D
pub const color_stop_red = [3]f32{ 1.000, 0.302, 0.302 };
/// #FF3B3B
pub const color_record_red = [3]f32{ 1.000, 0.231, 0.231 };
/// #FFB020
pub const color_mute_amber = [3]f32{ 1.000, 0.690, 0.125 };
/// #C8E833
pub const color_solo_lime = [3]f32{ 0.784, 0.910, 0.200 };
pub const color_idle_grey = [3]f32{ 0.300, 0.330, 0.400 };
pub const color_fader_track = [3]f32{ 0.055, 0.060, 0.068 };
pub const SERIDIAN_STRIP_WIDTH: f32 = 148.0;
pub const SERIDIAN_FADER_WIDTH: f32 = 28.0;
pub const SERIDIAN_FADER_HEIGHT: f32 = 120.0;
pub const SERIDIAN_METER_WIDTH: f32 = 10.0;
pub const SERIDIAN_METER_PEAK_HOLD_FRAMES: c_int = 45;
pub const SERIDIAN_BPM_MIN: f64 = 20.0;
pub const SERIDIAN_BPM_MAX: f64 = 300.0;
pub const SERIDIAN_TAP_WINDOW_SECONDS: f64 = 2.0;
pub const SERIDIAN_TAP_HISTORY = 4;

/// Peak-holding level state for one vertical meter; the paint callback reads it.
pub const MeterView = extern struct {
    level: f32,
    peak: f32,
    peak_age: c_int,
};

/// Last entry is the master meter.
pub var meter_views: [SERIDIAN_TRACK_COUNT + 1]MeterView = std.mem.zeroes([SERIDIAN_TRACK_COUNT + 1]MeterView);
pub var tap_times: [SERIDIAN_TAP_HISTORY]f64 = std.mem.zeroes([SERIDIAN_TAP_HISTORY]f64);
pub var tap_count: c_int = 0;
pub var transport_visual_state: c_int = -1;
/// Widget setters run by the mixer sync must not act as user edits.
pub var mixer_syncing: c_int = 0;

/// Index into palette_track_colors for each track; changed from the track menu.
pub const default_track_color_index = [SERIDIAN_TRACK_COUNT]c_int{ 0, 1, 2, 3, 4, 5, 6, 7 };

pub const TrackColorChoice = extern struct {
    track: c_int,
    color_index: c_int,
};

pub var track_color_choices: [SERIDIAN_TRACK_COUNT][palette.PALETTE_TRACK_COLOR_COUNT]TrackColorChoice =
    std.mem.zeroes([SERIDIAN_TRACK_COUNT][palette.PALETTE_TRACK_COLOR_COUNT]TrackColorChoice);

/// Arrangement blocks for MIDI parts: one per track with notes, from its first note to the end of its last. They
/// have no engine clip binding, so the clip handlers ignore them; the Piano Roll is where they are edited.
pub const MidiBlock = extern struct {
    track: c_int,
    item: c_int,
    timeline_track: c_int,
};
pub var midi_blocks: [SERIDIAN_TRACK_COUNT]MidiBlock = std.mem.zeroes([SERIDIAN_TRACK_COUNT]MidiBlock);
pub var midi_block_count: c_int = 0;

// ---- Session save prompt ----

pub const SAVE_NAME_CAPACITY = 256;
pub const SAVE_PATH_CAPACITY = 1024;
pub const SAVE_DEFAULT_NAME = "Untitled Session";

/// State of the open "Name this session" prompt. Valid only while the dialog is open.
pub const SavePrompt = extern struct {
    input: Rid,
    error_label: Rid,
    parent: [SAVE_PATH_CAPACITY]u8,
    name: [SAVE_NAME_CAPACITY]u8,
    path: [SAVE_PATH_CAPACITY]u8,
};
pub var save_prompt: SavePrompt = std.mem.zeroes(SavePrompt);

// ---- Autosave ----

pub const AUTOSAVE_INTERVAL_SECONDS: f64 = 120.0;
pub var autosave_baseline: u64 = 0;
pub var autosave_next_time: f64 = 0;

// ---- Audio settings dialog ----

/// "System default", the current device, and up to 30 enumerated devices.
pub const SETTINGS_DEVICE_CHOICES = 32;
/// The engine refuses names of 128 bytes or longer.
pub const SETTINGS_DEVICE_NAME_CAPACITY = 128;
/// Up to 8 supported values plus the current one.
pub const SETTINGS_VALUE_CHOICES = 9;
pub const SETTINGS_SYSTEM_LIST_CAPACITY = 8;
pub const SETTINGS_FAILURE_CAPACITY = 192;

pub const DeviceEnumerateFn = ?*const fn () callconv(.c) c_int;
pub const DeviceTextFn = ?*const fn (index: c_int) callconv(.c) [*c]const u8;

pub const SettingsDeviceChoices = extern struct {
    combo: Rid,
    count: c_int,
    names: [SETTINGS_DEVICE_CHOICES][SETTINGS_DEVICE_NAME_CAPACITY]u8,
};

pub const SettingsValueChoices = extern struct {
    combo: Rid,
    count: c_int,
    values: [SETTINGS_VALUE_CHOICES]u32,
};

/// Backend choices: the label shown and the preference name the engine understands (audio_engine_set_backend).
pub const SETTINGS_BACKEND_CHOICES = 4;
pub const SETTINGS_BACKEND_NAME_CAPACITY = 16;
pub const settings_backend_labels = [SETTINGS_BACKEND_CHOICES][*c]const u8{
    "Auto", "PulseAudio", "PipeWire (experimental)", "Silent (no audio)",
};
pub const settings_backend_names = [SETTINGS_BACKEND_CHOICES][*c]const u8{ "auto", "pulse", "pipewire", "none" };

pub const AudioSettingsPanel = extern struct {
    output: SettingsDeviceChoices,
    input: SettingsDeviceChoices,
    rate: SettingsValueChoices,
    buffer: SettingsValueChoices,
    backend_combo: Rid,
};

pub var audio_settings: AudioSettingsPanel = std.mem.zeroes(AudioSettingsPanel);
pub var audio_devices_initialized: c_int = 0;

// ---- MIDI input ----

pub const MIDI_INPUT_MAX_PORTS = 32;
pub const MIDI_INPUT_NAME_CAPACITY = 96;
pub const MIDI_INPUT_REFRESH_SECONDS: f64 = 1.0;

pub var midi_port_names: [MIDI_INPUT_MAX_PORTS][MIDI_INPUT_NAME_CAPACITY]u8 = std.mem.zeroes([MIDI_INPUT_MAX_PORTS][MIDI_INPUT_NAME_CAPACITY]u8);
pub var midi_port_count: c_int = 0;
/// -1 = all ports, otherwise the port index.
pub var midi_port_selected: c_int = -1;
pub var midi_ui_syncing: c_int = 0;
pub var midi_next_refresh: f64 = 0;

// ---- Piano roll undo ----
// Each edit stores the whole note list of the track before and after; the engine undo stack (core/undo.zig) holds
// one clip action whose clip_id names that pair, and the apply callback restores the matching list.

/// ActionType.move_clip in core/undo.zig.
pub const UNDO_ACTION_MOVE_CLIP: c_int = 7;
/// More than the undo stack depth (100).
pub const PIANO_UNDO_SLOTS = 128;

pub const UndoNote = extern struct {
    start_beat: f64,
    duration: f64,
    pitch: u8,
    velocity: u8,
    selected: c_int,
};

/// `notes` is owned (calloc'd) by the snapshot and released by snapshot_free.
pub const NoteSnapshot = extern struct {
    notes: [*c]UndoNote,
    count: c_int,
};

pub const PianoUndoEntry = extern struct {
    id: u64,
    track: c_int,
    before: NoteSnapshot,
    after: NoteSnapshot,
};

pub var piano_undo_entries: [PIANO_UNDO_SLOTS]PianoUndoEntry = std.mem.zeroes([PIANO_UNDO_SLOTS]PianoUndoEntry);
pub var piano_undo_next_id: u64 = 1;
pub var piano_undo_restore_failed: c_int = 0;

pub const PIANO_MIN_LENGTH_BEATS: f64 = 1.0 / 64.0;

// ---- Piano clipboard: selected notes copied with their start relative to the earliest copied note. ----

pub const PIANO_CLIP_CAPACITY = 512;
pub const PianoClipNote = extern struct {
    pitch: c_int,
    start_beat: f64,
    length_beats: f64,
};
pub var piano_clipboard: [PIANO_CLIP_CAPACITY]PianoClipNote = std.mem.zeroes([PIANO_CLIP_CAPACITY]PianoClipNote);
pub var piano_clipboard_count: c_int = 0;
pub var piano_clipboard_span: f64 = 0.0;

// ---- Command socket ----

pub const CONTROL_MAX_CLIENTS = 8;
pub const CONTROL_LINE_CAPACITY = 128;
/// About 3 seconds at 30 frames per second.
pub const CONTROL_CLIENT_MAX_FRAMES: c_int = 90;
pub const CONTROL_BPM_MIN: f64 = 20.0;
pub const CONTROL_BPM_MAX: f64 = 300.0;
pub const CONTROL_GAIN_MAX: f64 = 1.5;

pub const ControlClient = extern struct {
    fd: c_int,
    length: c_int,
    frames: c_int,
    line: [CONTROL_LINE_CAPACITY]u8,
};

/// `sizeof(((struct sockaddr_un *)0)->sun_path)`.
pub const SUN_PATH_CAPACITY = @typeInfo(@FieldType(std.c.sockaddr.un, "path")).array.len;

pub var control_listen_fd: c_int = -1;
pub var control_path: [SUN_PATH_CAPACITY]u8 = std.mem.zeroes([SUN_PATH_CAPACITY]u8);
pub var control_clients: [CONTROL_MAX_CLIENTS]ControlClient = std.mem.zeroes([CONTROL_MAX_CLIENTS]ControlClient);

/// Automation targets, matching audio_engine_automation_add.
pub const AUTO_TRACK_GAIN: c_int = 0;
pub const AUTO_TRACK_PAN: c_int = 1;
pub const AUTO_TRACK_WET: c_int = 2;
pub const AUTO_MASTER_GAIN: c_int = 3;

/// Longest path the socket accepts: the line holds the command word and one space as well.
pub const CONTROL_PATH_MAX = CONTROL_LINE_CAPACITY - 8;

/// Extra text for the next "ok" reply, such as the export peak. Empty when there is none.
pub var control_ok_detail: [48]u8 = std.mem.zeroes([48]u8);
