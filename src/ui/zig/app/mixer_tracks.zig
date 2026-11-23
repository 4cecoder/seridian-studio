//! Translated to Zig from src/ui/raven_app.c lines 1012-1476: clip and track callbacks, state snapshot, meters, split and zoom. Seridian Studio window, 1:1 translation.

const std = @import("std");
const raven = @import("raven");
const st = @import("state.zig");
const ext = @import("externs.zig");
const libc = @import("libc.zig");
const fns = @import("fns.zig");
const palette = @import("../palette.zig");
const ui_math = @import("../ui_math.zig");
const piano_math = @import("../piano_math.zig");
const ui_state = @import("../ui_state.zig");
const window_input = @import("../window_input.zig");

const app = &st.app;

pub fn on_clip_gain(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    _ = user_data;
    if (app.syncing != 0) return;
    const binding: [*c]const st.ClipBinding = fns.selected_clip_binding();
    if (binding == null) return;
    _ = ext.track_set_clip_gain(app.engine, binding.*.track, binding.*.engine_clip, value);
    var text: [24]u8 = undefined;
    ui_math.ui_format_gain(value, &text, text.len);
    raven.Rlabel_set_text(app.clip_gain_readout, &text);
}

pub fn on_clip_fade_in(spin_box: raven.Rid, value: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = spin_box;
    _ = user_data;
    if (app.syncing != 0) return;
    const binding: [*c]const st.ClipBinding = fns.selected_clip_binding();
    if (binding == null) return;
    _ = ext.track_set_clip_fade_in(app.engine, binding.*.track, binding.*.engine_clip, @floatCast(value));
    fns.set_status("Fade in updated");
}

pub fn on_clip_fade_out(spin_box: raven.Rid, value: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = spin_box;
    _ = user_data;
    if (app.syncing != 0) return;
    const binding: [*c]const st.ClipBinding = fns.selected_clip_binding();
    if (binding == null) return;
    _ = ext.track_set_clip_fade_out(app.engine, binding.*.track, binding.*.engine_clip, @floatCast(value));
    fns.set_status("Fade out updated");
}

pub fn on_clip_mute(checkbox: raven.Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = checkbox;
    _ = user_data;
    if (app.syncing != 0) return;
    const binding: [*c]const st.ClipBinding = fns.selected_clip_binding();
    if (binding == null) return;
    _ = ext.track_set_clip_muted(app.engine, binding.*.track, binding.*.engine_clip, if (checked != 0) 1 else 0);
    fns.set_status(if (checked != 0) "Clip muted" else "Clip unmuted");
}

pub fn on_track_gain(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    if (st.mixer_syncing != 0) return;
    const binding: [*c]st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return; // the popout this strip belonged to is gone
    ext.audio_engine_set_track_gain(app.engine, binding.*.track, value);
    binding.*.view.*.shown[@intCast(binding.*.track)].gain = value;
    var text: [24]u8 = undefined;
    ui_math.ui_format_gain(value, &text, text.len);
    raven.Rlabel_set_text(binding.*.gain_readout, &text);
    var message: [64]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Track %d volume: %s", binding.*.track + 1, &text);
    fns.set_status(&message);
}

pub fn apply_track_pan(binding: [*c]st.TrackBinding, value: f32) void {
    if (st.mixer_syncing != 0) return;
    if (binding.*.view == null) return; // the popout this strip belonged to is gone
    ext.audio_engine_set_track_pan(app.engine, binding.*.track, value);
    ext.project_set_track_pan(binding.*.track, value);
    binding.*.view.*.shown[@intCast(binding.*.track)].pan = value;
    var text: [16]u8 = undefined;
    ui_math.ui_format_pan(value, &text, text.len);
    raven.Rlabel_set_text(binding.*.pan_readout, &text);
    var message: [64]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Track %d pan: %s", binding.*.track + 1, &text);
    fns.set_status(&message);
}

pub fn on_track_pan(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    apply_track_pan(@ptrCast(@alignCast(user_data)), value);
}

pub fn on_track_pan_knob(value: f32, user_data: ?*anyopaque) callconv(.c) void {
    apply_track_pan(@ptrCast(@alignCast(user_data)), value);
}

pub fn on_master_gain(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    if (st.mixer_syncing != 0) return;
    const view: [*c]st.MixerView = @ptrCast(@alignCast(user_data));
    if (view == null or view.*.window == raven.R_INVALID_ID) return; // the popout this strip belonged to is gone
    app.master_gain = value;
    ext.audio_engine_set_master_gain(app.engine, value);
    view.*.master_shown = value;
    var text: [24]u8 = undefined;
    ui_math.ui_format_gain(value, &text, text.len);
    raven.Rlabel_set_text(view.*.master_gain_readout, &text);
    var message: [64]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Master volume: %s", &text);
    fns.set_status(&message);
}

pub fn on_track_mute(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const binding: [*c]const st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return;
    const muted: c_int = @intFromBool(ext.audio_engine_get_track_mute(app.engine, binding.*.track) == 0);
    ext.audio_engine_set_track_mute(app.engine, binding.*.track, muted);
    binding.*.view.*.shown[@intCast(binding.*.track)].muted = muted;
    fns.style_toggle_button(button, muted, &st.color_mute_amber);
    raven.Rwidget_set_tooltip(button, if (muted != 0) "Track muted — click to unmute" else "Mute this track");
    var message: [48]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Track %d %s", binding.*.track + 1, @as([*c]const u8, if (muted != 0) "muted" else "unmuted"));
    fns.set_status(&message);
}

pub fn on_track_solo(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const binding: [*c]const st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return;
    const soloed: c_int = @intFromBool(ext.audio_engine_get_track_solo(app.engine, binding.*.track) == 0);
    ext.audio_engine_set_track_solo(app.engine, binding.*.track, soloed);
    binding.*.view.*.shown[@intCast(binding.*.track)].soloed = soloed;
    fns.style_toggle_button(button, soloed, &st.color_solo_lime);
    raven.Rwidget_set_tooltip(button, if (soloed != 0) "Track soloed — click to unsolo" else "Solo this track");
    var message: [48]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Track %d %s", binding.*.track + 1, @as([*c]const u8, if (soloed != 0) "soloed" else "unsoloed"));
    fns.set_status(&message);
}

/// Combo index of the track's instrument: 0 is "No instrument", n is instrument type n - 1.
pub fn instrument_combo_index(track: c_int) c_int {
    if (ext.audio_engine_track_has_instrument(app.engine, track) == 0) return 0;
    // Use the engine type, not the display name: "Model Piano" differs from the type name "ModelPiano".
    const type_ = ext.audio_engine_get_track_instrument_type(app.engine, track);
    return if (type_ >= 0) type_ + 1 else 0;
}

/// Instrument picker: item 0 is "No instrument", item n is instrument type n - 1.
pub fn on_track_instrument(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    if (st.mixer_syncing != 0) return;
    const binding: [*c]st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return;
    if (index <= 0) {
        ext.audio_engine_remove_track_instrument(app.engine, binding.*.track);
        binding.*.view.*.shown[@intCast(binding.*.track)].instrument = 0;
        fns.set_status("Instrument removed");
        return;
    }
    if (ext.audio_engine_set_track_instrument(app.engine, binding.*.track, index - 1) == 0) {
        binding.*.view.*.shown[@intCast(binding.*.track)].instrument = index;
        var message: [96]u8 = undefined;
        _ = libc.snprintf(&message, message.len, "Track %d instrument: %s", binding.*.track + 1, ext.audio_engine_get_track_instrument_name(app.engine, binding.*.track));
        fns.set_status(&message);
    } else {
        fns.set_status("Could not load that instrument");
    }
}

pub fn build_instrument_picker(view: [*c]st.MixerView, track: c_int) raven.Rid {
    const combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    _ = raven.Rcombo_box_add_item(combo, "No instrument");
    const type_count = ext.audio_engine_get_instrument_type_count();
    var type_: c_int = 0;
    while (type_ < type_count) : (type_ += 1) {
        const name: [*c]const u8 = ext.audio_engine_get_instrument_type_name(type_);
        _ = raven.Rcombo_box_add_item(combo, name);
    }
    raven.Rcombo_box_set_selected(combo, instrument_combo_index(track));
    raven.Rcombo_box_set_changed_callback(combo, &on_track_instrument, &view.*.bindings[@intCast(track)]);
    raven.Rwidget_set_size(combo, st.SERIDIAN_STRIP_WIDTH - 16.0, -1.0);
    raven.Rwidget_set_tooltip(combo, "Instrument for this track (MIDI input)");
    view.*.instrument_combos[@intCast(track)] = combo;
    return combo;
}

pub fn on_track_arm(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const binding: [*c]const st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return;
    const armed: c_int = @intFromBool(ext.audio_engine_get_track_arm(app.engine, binding.*.track) == 0);
    ext.audio_engine_set_track_arm(app.engine, binding.*.track, armed);
    binding.*.view.*.shown[@intCast(binding.*.track)].armed = armed;
    fns.style_toggle_button(button, armed, &st.color_record_red);
    raven.Rwidget_set_tooltip(button, if (armed != 0) "Armed for recording — click to disarm" else "Arm this track for recording");
    var message: [48]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Track %d %s", binding.*.track + 1, @as([*c]const u8, if (armed != 0) "armed" else "disarmed"));
    fns.set_status(&message);
}

pub fn apply_track_color(track: c_int) void {
    const color: [*c]const palette.SeridianTrackColor = fns.track_color(track);
    if (color == null) return;
    raven.Rtimeline_set_track_color(app.timeline, track, color.*.color.r, color.*.color.g, color.*.color.b);
    var i: usize = 0;
    while (i < app.clip_count) : (i += 1) {
        if (app.clips[i].track != track) continue;
        raven.Rtimeline_set_item_color(app.timeline, app.clips[i].timeline_item, color.*.color.r, color.*.color.g, color.*.color.b);
    }
    var view: c_int = 0;
    while (view < st.MIXER_VIEW_COUNT) : (view += 1) {
        const label: raven.Rid = app.mixers[@intCast(view)].name_labels[@intCast(track)];
        if (label != raven.R_INVALID_ID) raven.Rlabel_set_color(label, color.*.color.r, color.*.color.g, color.*.color.b, 1.0);
        const bar: raven.Rid = app.mixers[@intCast(view)].color_bars[@intCast(track)];
        if (bar != raven.R_INVALID_ID) raven.Rborder_set_background(bar, color.*.color.r, color.*.color.g, color.*.color.b, 1.0);
    }
}

pub fn on_track_color_picked(item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = item;
    const choice: [*c]const st.TrackColorChoice = @ptrCast(@alignCast(user_data));
    app.track_color_index[@intCast(choice.*.track)] = choice.*.color_index;
    apply_track_color(choice.*.track);
    const color: [*c]const palette.SeridianTrackColor = fns.track_color(choice.*.track);
    if (color != null) {
        var message: [96]u8 = undefined;
        _ = libc.snprintf(&message, message.len, "Track %d color set to %s", choice.*.track + 1, color.*.name);
        fns.set_status(&message);
    }
}

pub fn on_track_popout_picked(item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = item;
    const binding: [*c]const st.TrackBinding = @ptrCast(@alignCast(user_data));
    if (binding.*.view == null) return;
    fns.popout_open(binding.*.track, 0, 0, 0, 0, 0, null, 0, 0);
}

/// Right-click menu on a track name: the palette's track colors, then the Piano Roll popout.
pub fn build_track_color_menu(view: [*c]st.MixerView, track: c_int) raven.Rid {
    const menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    var choice: c_int = 0;
    while (choice < palette.PALETTE_TRACK_COLOR_COUNT) : (choice += 1) {
        const color: [*c]const palette.SeridianTrackColor = palette.palette_track_color_at(choice);
        if (color == null) continue;
        const slot: *st.TrackColorChoice = &st.track_color_choices[@intCast(track)][@intCast(choice)];
        slot.* = .{ .track = track, .color_index = choice };
        const item = raven.Rmenu_add_item(menu, color.*.name);
        raven.Rmenu_item_set_clicked_callback(item, &on_track_color_picked, slot);
    }
    _ = raven.Rmenu_add_separator(menu);
    const popout = raven.Rmenu_add_item(menu, "Pop out Piano Roll (Ctrl+Shift+P)");
    raven.Rmenu_item_set_clicked_callback(popout, &on_track_popout_picked, &view.*.bindings[@intCast(track)]);
    return menu;
}

pub fn resolve_state_path() void {
    const runtime_dir: [*c]const u8 = libc.getenv("XDG_RUNTIME_DIR");
    if (runtime_dir != null and runtime_dir[0] != 0) {
        _ = libc.snprintf(&app.state_path, app.state_path.len, "%s/seridian-state.json", runtime_dir);
    } else {
        _ = libc.snprintf(&app.state_path, app.state_path.len, "/tmp/seridian-state.json");
    }
}

/// Writes the observable mixer and transport state for the seridian CLI and tests.
pub fn write_state_snapshot() void {
    var state = std.mem.zeroes(ui_state.UiState);
    state.playing = if (ext.audio_engine_is_playing(app.engine) != 0) 1 else 0;
    const rate: u32 = ext.audio_engine_get_sample_rate(app.engine);
    state.position_seconds = if (rate > 0)
        @as(f64, @floatFromInt(ext.audio_engine_get_position(app.engine))) / @as(f64, @floatFromInt(rate))
    else
        0.0;
    state.bpm = ext.audio_engine_get_tempo(app.engine);
    state.master_gain = app.master_gain;
    if (ext.audio_engine_get_output_device(app.engine, &state.audio.output_device, state.audio.output_device.len) < 0) {
        state.audio.output_device[0] = 0;
    }
    state.audio.sample_rate = rate;
    state.audio.buffer_size = ext.audio_engine_get_buffer_size(app.engine);
    if (ext.audio_engine_get_backend(app.engine, &state.audio.backend, state.audio.backend.len) < 0) {
        _ = libc.snprintf(&state.audio.backend, state.audio.backend.len, "unknown");
    }
    // The snapshot format holds UI_STATE_MAX_TRACKS tracks; the mixer shows SERIDIAN_TRACK_COUNT.
    state.track_count = if (st.SERIDIAN_TRACK_COUNT < ui_state.UI_STATE_MAX_TRACKS) st.SERIDIAN_TRACK_COUNT else ui_state.UI_STATE_MAX_TRACKS;

    // Notes of the piano roll track, read from the engine so `selected` reflects the engine.
    state.piano_track = app.piano_track;
    var piano_count: c_int = ext.midi_clip_get_note_count(app.piano_track);
    var piano_captured: c_int = 0;
    var index: c_int = 0;
    while (index < piano_count and piano_captured < ui_state.UI_STATE_MAX_NOTES) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(app.piano_track, index, &id, &start, &duration, &pitch, &velocity, &selected) != 1) {
            piano_count = piano_captured; // Read failed: report only the notes read so far.
            break;
        }
        const note: *ui_state.UiNoteState = &state.piano_notes[@intCast(piano_captured)];
        piano_captured += 1;
        note.pitch = @as(c_int, pitch);
        note.start_beat = start;
        note.length_beats = duration;
        note.selected = if (selected != 0) 1 else 0;
    }
    state.piano_note_count = piano_count;

    var track: c_int = 0;
    while (track < state.track_count) : (track += 1) {
        const out: *ui_state.UiTrackState = &state.tracks[@intCast(track)];
        var fallback_name: [16]u8 = undefined;
        _ = libc.snprintf(&out.name, out.name.len, "%s", fns.track_display_name(track, &fallback_name, fallback_name.len));
        out.gain = ext.audio_engine_get_track_gain(app.engine, track);
        out.pan = ext.audio_engine_get_track_pan(app.engine, track);
        out.muted = if (ext.audio_engine_get_track_mute(app.engine, track) != 0) 1 else 0;
        out.soloed = if (ext.audio_engine_get_track_solo(app.engine, track) != 0) 1 else 0;
        out.armed = if (ext.audio_engine_get_track_arm(app.engine, track) != 0) 1 else 0;
        out.midi_notes = ext.midi_clip_get_note_count(track);
        if (app.mixers[st.MIXER_VIEW_DOCK].pan_knobs[@intCast(track)] != raven.R_INVALID_ID) {
            var knob_x: f32 = 0.0;
            var knob_y: f32 = 0.0;
            var knob_w: f32 = 0.0;
            var knob_h: f32 = 0.0;
            raven.Rwidget_get_rect(app.mixers[st.MIXER_VIEW_DOCK].pan_knobs[@intCast(track)], &knob_x, &knob_y, &knob_w, &knob_h);
            out.pan_knob_x = knob_x + knob_w * 0.5;
            out.pan_knob_y = knob_y + knob_h * 0.5;
        }
        if (ext.audio_engine_track_has_instrument(app.engine, track) != 0) {
            const instrument: [*c]const u8 = ext.audio_engine_get_track_instrument_name(app.engine, track);
            _ = libc.snprintf(&out.instrument, out.instrument.len, "%s", @as([*c]const u8, if (instrument != null) instrument else ""));
        }
    }

    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    if (ui_state.ui_state_format(&state, &json, json.len) < 0) return;
    _ = ui_state.ui_state_write_file(&app.state_path, &json);
}

/// Pushes one level into a meter view: holds the peak for a short time, then lets it fall.
pub fn meter_view_update(view_index: c_int, widget: raven.Rid, level: f32) void {
    // C assigns to the `level` parameter; Zig parameters are immutable, so it is copied into `level_`.
    var level_ = level;
    if (!libc.isfinite(level_)) level_ = 0.0;
    const meter: *st.MeterView = &st.meter_views[@intCast(view_index)];
    meter.level = libc.fminf(libc.fmaxf(level_, 0.0), 1.0);
    if (meter.level >= meter.peak) {
        meter.peak = meter.level;
        meter.peak_age = 0;
    } else {
        meter.peak_age += 1;
        if (meter.peak_age > st.SERIDIAN_METER_PEAK_HOLD_FRAMES) {
            meter.peak = libc.fmaxf(meter.level, meter.peak - 0.02);
        }
    }
    if (widget != raven.R_INVALID_ID) raven.Rwidget_invalidate(widget);
}

pub fn update_track_meters() void {
    var i: c_int = 0;
    while (i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        meter_view_update(i, app.mixers[st.MIXER_VIEW_DOCK].track_meters[@intCast(i)], ext.audio_engine_get_track_meter(app.engine, i));
        const popout_meter: raven.Rid = app.mixers[st.MIXER_VIEW_POPOUT].track_meters[@intCast(i)];
        if (popout_meter != raven.R_INVALID_ID) raven.Rwidget_invalidate(popout_meter);
    }
    const left = ext.audio_engine_get_master_meter_left(app.engine);
    const right = ext.audio_engine_get_master_meter_right(app.engine);
    meter_view_update(st.SERIDIAN_TRACK_COUNT, app.mixers[st.MIXER_VIEW_DOCK].master_meter, libc.fmaxf(left, right));
    const popout_master: raven.Rid = app.mixers[st.MIXER_VIEW_POPOUT].master_meter;
    if (popout_master != raven.R_INVALID_ID) raven.Rwidget_invalidate(popout_master);
}

pub fn any_track_armed() c_int {
    var i: c_int = 0;
    while (i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        if (ext.audio_engine_get_track_arm(app.engine, i) != 0) return 1;
    }
    return 0;
}

/// Transport colours follow the engine: green Play while playing, red Stop, and a state pill.
/// REC means playing with at least one armed track; the pill pulses while REC.
pub fn sync_transport_visuals(frame_count: c_uint) void {
    const playing: c_int = if (ext.audio_engine_is_playing(app.engine) != 0) 1 else 0;
    const recording: c_int = @intFromBool(playing != 0 and any_track_armed() != 0);
    const state: c_int = if (recording != 0) 2 else playing;
    const pulse_on: c_int = @intFromBool(recording != 0 and ((frame_count / 8) % 2 == 0));
    if (state == st.transport_visual_state and recording == 0) return;
    if (state != st.transport_visual_state) {
        fns.style_fill_button(app.play_button, if (playing != 0) &st.color_play_green else &st.accent_cyan, &st.color_ink);
        raven.Rbutton_set_text(app.play_button, if (playing != 0) "Ⅱ  Pause" else "▶  Play");
        raven.Rwidget_set_tooltip(app.play_button, if (playing != 0)
            "Playing: click to pause (Space)"
        else
            "Start playback from the playhead; click again to pause (Space)");
        raven.Rlabel_set_text(app.engine_status, if (recording != 0) "REC" else (if (playing != 0) "PLAYING" else "STOPPED"));
        const text: [*c]const f32 = if (state == 0) &st.color_readout else &st.color_ink;
        raven.Rlabel_set_color(app.engine_status, text[0], text[1], text[2], 1.0);
        st.transport_visual_state = state;
    }
    const pill: [*c]const f32 = if (state == 2) &st.color_stop_red else (if (state == 1) &st.color_play_green else &st.color_idle_grey);
    const dim: f32 = if (recording != 0 and pulse_on == 0) 0.55 else 1.0;
    raven.Rborder_set_background(app.state_pill, pill[0] * dim, pill[1] * dim, pill[2] * dim, 1.0);
}

pub fn try_split(track: c_int, clip_id: u64, time: f64) c_int {
    const start = ext.track_get_clip_start(app.engine, track, clip_id);
    const duration = ext.track_get_clip_duration(app.engine, track, clip_id);
    if (ui_math.ui_time_splits_clip(start, duration, time) == 0) return 0;
    return @intFromBool(ext.track_split_clip(app.engine, track, clip_id, time) != 0);
}

pub fn split_at_playhead() void {
    const time = raven.Rtimeline_get_time(app.timeline);
    var splits: c_int = 0;
    const selected: [*c]const st.ClipBinding = fns.selected_clip_binding();
    if (selected != null) {
        splits += try_split(selected.*.track, selected.*.engine_clip, time);
    } else {
        var track: c_int = 0;
        while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
            var found: c_int = 1;
            while (found != 0) {
                found = 0;
                const count = ext.track_get_clip_count(app.engine, track);
                var index: c_int = 0;
                while (index < count and found == 0) : (index += 1) {
                    const clip_id: u64 = ext.track_get_clip_id(app.engine, track, index);
                    if (try_split(track, clip_id, time) != 0) {
                        splits += 1;
                        found = 1;
                    }
                }
            }
        }
    }

    if (splits == 0) {
        fns.set_status("Playhead is not over a clip — move it onto a clip, then split");
        return;
    }
    fns.populate_timeline();
    var message: [96]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Split %d clip%s at %.2f s", splits, @as([*c]const u8, if (splits == 1) "" else "s"), time);
    fns.set_status(&message);
}

pub fn on_split_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    split_at_playhead();
}

pub fn zoom_timeline(factor: f64) void {
    var start: f64 = 0.0;
    var end: f64 = 0.0;
    raven.Rtimeline_get_view(app.timeline, &start, &end);
    var new_start: f64 = 0.0;
    var new_end: f64 = 0.0;
    ui_math.ui_zoom_view(start, end, factor, raven.Rtimeline_get_duration(app.timeline), &new_start, &new_end);
    raven.Rtimeline_set_view(app.timeline, new_start, new_end);
}

pub fn fit_timeline() void {
    var longest: f64 = 0.0;
    var i: usize = 0;
    while (i < app.clip_count) : (i += 1) {
        const binding: *const st.ClipBinding = &app.clips[i];
        const end = ext.track_get_clip_start(app.engine, binding.track, binding.engine_clip) +
            ext.track_get_clip_duration(app.engine, binding.track, binding.engine_clip);
        if (end > longest) longest = end;
    }
    var span = longest * 1.05;
    if (span < st.SERIDIAN_FIT_MIN_SECONDS) span = st.SERIDIAN_FIT_MIN_SECONDS;
    raven.Rtimeline_set_view(app.timeline, 0.0, span);
}

pub fn on_zoom_in(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    zoom_timeline(0.5);
}

pub fn on_zoom_out(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    zoom_timeline(2.0);
}

pub fn on_zoom_fit(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    fit_timeline();
}
