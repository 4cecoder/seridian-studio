//! Translated to Zig from src/ui/raven_app.c lines 2076-2810: audio settings dialog, header, transport, MIDI input and inspector tabs. Seridian Studio window, 1:1 translation.

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
const scroll_wrap = @import("../scroll_wrap.zig");

const app = &st.app;

pub fn settings_add_device(choices: [*c]st.SettingsDeviceChoices, text: [*c]const u8, name: [*c]const u8) void {
    _ = libc.snprintf(&choices.*.names[@intCast(choices.*.count)], st.SETTINGS_DEVICE_NAME_CAPACITY, "%s", name);
    _ = raven.Rcombo_box_add_item(choices.*.combo, text);
    choices.*.count += 1;
}

pub fn settings_device_index(choices: [*c]const st.SettingsDeviceChoices, name: [*c]const u8) c_int {
    var i: c_int = 0;
    while (i < choices.*.count) : (i += 1) {
        if (libc.strcmp(&choices.*.names[@intCast(i)], name) == 0) return i;
    }
    return -1;
}

pub fn ends_with(text: [*c]const u8, suffix: [*c]const u8) c_int {
    const text_len: usize = libc.strlen(text);
    const suffix_len: usize = libc.strlen(suffix);
    return @intFromBool(text_len >= suffix_len and libc.strcmp(text + (text_len - suffix_len), suffix) == 0);
}

/// Enumerates devices into the combo. Item 0 is the system default (name ""). The live device is always
/// present and selected so that Apply never changes a device the user did not touch.
pub fn fill_device_choices(choices: [*c]st.SettingsDeviceChoices, enumerate: st.DeviceEnumerateFn, name_at: st.DeviceTextFn, description_at: st.DeviceTextFn, skip_monitors: c_int, live: [*c]const u8) void {
    choices.*.count = 0;
    settings_add_device(choices, "System default", "");
    const found: c_int = enumerate.?();
    var i: c_int = 0;
    while (found > 0 and i < found and choices.*.count < st.SETTINGS_DEVICE_CHOICES - 1) : (i += 1) {
        const name: [*c]const u8 = name_at.?(i);
        if (name == null or name[0] == 0 or libc.strlen(name) >= st.SETTINGS_DEVICE_NAME_CAPACITY) continue;
        if (skip_monitors != 0 and ends_with(name, ".monitor") != 0) continue;
        const description: [*c]const u8 = description_at.?(i);
        settings_add_device(choices, if (description != null and description[0] != 0) description else name, name);
    }
    if (settings_device_index(choices, live) < 0) {
        var text: [st.SETTINGS_DEVICE_NAME_CAPACITY + 16]u8 = undefined;
        _ = libc.snprintf(&text, text.len, "%s (current)", live);
        settings_add_device(choices, &text, live);
    }
    raven.Rcombo_box_set_selected(choices.*.combo, settings_device_index(choices, live));
}

pub fn add_value_item(choices: [*c]st.SettingsValueChoices, value: u32, is_rate: c_int, is_current: c_int) void {
    var text: [48]u8 = undefined;
    _ = libc.snprintf(&text, text.len, "%u %s%s", @as(c_uint, value), @as([*c]const u8, if (is_rate != 0) "Hz" else "samples"), @as([*c]const u8, if (is_current != 0) " (current)" else ""));
    _ = raven.Rcombo_box_add_item(choices.*.combo, &text);
    choices.*.values[@intCast(choices.*.count)] = value;
    choices.*.count += 1;
}

/// Fills a rate or buffer combo from a system list. The live value is always present and selected.
pub fn fill_value_choices(choices: [*c]st.SettingsValueChoices, list: [*c]const u32, list_count: u32, live: u32, is_rate: c_int) void {
    choices.*.count = 0;
    const capped: u32 = if (list_count < st.SETTINGS_SYSTEM_LIST_CAPACITY) list_count else st.SETTINGS_SYSTEM_LIST_CAPACITY;
    var live_index: c_int = -1;
    var i: u32 = 0;
    while (i < capped) : (i += 1) {
        if (list[i] == live) live_index = @intCast(i);
        add_value_item(choices, list[i], is_rate, 0);
    }
    if (live_index < 0) {
        live_index = choices.*.count;
        add_value_item(choices, live, is_rate, 1);
    }
    raven.Rcombo_box_set_selected(choices.*.combo, live_index);
}

/// Index of the selected item of a settings combo, or -1 when nothing valid is selected.
pub fn settings_selected(combo: raven.Rid, count: c_int) c_int {
    const index: c_int = raven.Rcombo_box_get_selected(combo);
    return if (index >= 0 and index < count) index else -1;
}

pub fn note_setting_failure(failed: [*c]c_int, message: [*c]u8, message_len: usize, what: [*c]const u8, code: c_int) void {
    if (failed.* != 0) return;
    failed.* = 1;
    _ = libc.snprintf(message, message_len, "Could not apply %s (%d); kept the previous %s", what, code, what);
}

/// Applies the selections that differ from the live engine. Order: backend, buffer, rate, output, input.
/// The backend goes first because switching it resets the output device.
pub fn apply_audio_settings() void {
    var failed: c_int = 0;
    var message: [st.SETTINGS_FAILURE_CAPACITY]u8 = undefined;
    message[0] = 0;

    var live_backend = std.mem.zeroes([st.SETTINGS_BACKEND_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_backend_preference(app.engine, &live_backend, live_backend.len) < 0) live_backend[0] = 0;
    const backend_index: c_int = settings_selected(st.audio_settings.backend_combo, st.SETTINGS_BACKEND_CHOICES);
    if (backend_index >= 0 and libc.strcmp(st.settings_backend_names[@intCast(backend_index)], &live_backend) != 0) {
        var output_before = std.mem.zeroes([st.SETTINGS_DEVICE_NAME_CAPACITY]u8);
        if (ext.audio_engine_get_output_device(app.engine, &output_before, output_before.len) < 0) output_before[0] = 0;
        const rc: c_int = ext.audio_engine_set_backend(app.engine, st.settings_backend_names[@intCast(backend_index)]);
        if (rc != 0) {
            note_setting_failure(&failed, &message, message.len, "backend", rc);
        } else {
            // The engine reset the output to the system default. An output the user left on the
            // previous live device goes back to the default too, so Apply does not try to keep it.
            const output_index: c_int = settings_selected(st.audio_settings.output.combo, st.audio_settings.output.count);
            if (output_index >= 0 and libc.strcmp(&st.audio_settings.output.names[@intCast(output_index)], &output_before) == 0) {
                raven.Rcombo_box_set_selected(st.audio_settings.output.combo, 0);
            }
        }
    }

    const buffer_index: c_int = settings_selected(st.audio_settings.buffer.combo, st.audio_settings.buffer.count);
    if (buffer_index >= 0) {
        const wanted: u32 = st.audio_settings.buffer.values[@intCast(buffer_index)];
        if (wanted != ext.audio_engine_get_buffer_size(app.engine)) {
            const rc: c_int = ext.audio_engine_set_buffer_size(app.engine, wanted);
            if (rc != 0) note_setting_failure(&failed, &message, message.len, "buffer size", rc);
        }
    }

    const rate_index: c_int = settings_selected(st.audio_settings.rate.combo, st.audio_settings.rate.count);
    if (rate_index >= 0) {
        const wanted: u32 = st.audio_settings.rate.values[@intCast(rate_index)];
        if (wanted != ext.audio_engine_get_sample_rate(app.engine)) {
            const rc: c_int = ext.audio_engine_set_sample_rate(app.engine, wanted);
            if (rc != 0) note_setting_failure(&failed, &message, message.len, "sample rate", rc);
        }
    }

    var live_output = std.mem.zeroes([st.SETTINGS_DEVICE_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_output_device(app.engine, &live_output, live_output.len) < 0) live_output[0] = 0;
    const output_index: c_int = settings_selected(st.audio_settings.output.combo, st.audio_settings.output.count);
    if (output_index >= 0 and libc.strcmp(&st.audio_settings.output.names[@intCast(output_index)], &live_output) != 0) {
        const rc: c_int = ext.audio_engine_set_output_device(app.engine, &st.audio_settings.output.names[@intCast(output_index)]);
        if (rc != 0) note_setting_failure(&failed, &message, message.len, "output device", rc);
    }

    var live_input = std.mem.zeroes([st.SETTINGS_DEVICE_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_input_device(app.engine, &live_input, live_input.len) < 0) live_input[0] = 0;
    const input_index: c_int = settings_selected(st.audio_settings.input.combo, st.audio_settings.input.count);
    if (input_index >= 0 and libc.strcmp(&st.audio_settings.input.names[@intCast(input_index)], &live_input) != 0) {
        const rc: c_int = ext.audio_engine_set_input_device(app.engine, &st.audio_settings.input.names[@intCast(input_index)]);
        if (rc != 0) note_setting_failure(&failed, &message, message.len, "input device", rc);
    }

    // Save the live values, so a failed setter keeps the device that is actually in use.
    const save_failed: c_int = @intFromBool(ext.seridian_audio_settings_save(app.engine) != 0);

    if (failed != 0) {
        fns.set_status(&message);
    } else if (save_failed != 0) {
        fns.set_status("Audio settings applied, but they could not be saved");
    } else {
        fns.set_status("Audio settings applied");
    }
    fns.write_state_snapshot();
}

pub fn on_settings_closed(content: raven.Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = content;
    _ = user_data;
    // The window deletes the content after this callback; the combos are read here while they still exist.
    if (result == 1) apply_audio_settings();
    st.audio_settings = std.mem.zeroes(st.AudioSettingsPanel);
}

pub fn on_settings_cancel(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rdialog_close(button, 0);
}

pub fn on_settings_apply(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rdialog_close(button, 1);
}

pub fn settings_combo_create() raven.Rid {
    const combo: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    raven.Rwidget_set_size(combo, 320.0, -1.0);
    return combo;
}

pub fn settings_row(label_text: [*c]const u8, control: raven.Rid) raven.Rid {
    const row: raven.Rid = fns.make_row(12.0);
    const label: raven.Rid = fns.make_label(label_text, 11.0, &st.muted_text);
    raven.Rwidget_set_size(label, 110.0, -1.0);
    _ = raven.Rwidget_add_child(row, label);
    _ = raven.Rwidget_add_child(row, control);
    return row;
}

pub fn on_open_settings(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    if (raven.Rwindow_has_dialog(app.window) != 0) return;
    if (st.audio_devices_initialized == 0) {
        ext.audio_init_devices(null);
        st.audio_devices_initialized = 1;
    }
    st.audio_settings = std.mem.zeroes(st.AudioSettingsPanel);

    var live_output = std.mem.zeroes([st.SETTINGS_DEVICE_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_output_device(app.engine, &live_output, live_output.len) < 0) live_output[0] = 0;
    var live_input = std.mem.zeroes([st.SETTINGS_DEVICE_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_input_device(app.engine, &live_input, live_input.len) < 0) live_input[0] = 0;
    var live_backend = std.mem.zeroes([st.SETTINGS_BACKEND_NAME_CAPACITY]u8);
    if (ext.audio_engine_get_backend_preference(app.engine, &live_backend, live_backend.len) < 0) live_backend[0] = 0;

    st.audio_settings.output.combo = settings_combo_create();
    fill_device_choices(&st.audio_settings.output, &ext.audio_enumerate_output_devices, &ext.audio_get_output_device_name, &ext.audio_get_output_device_description, 0, &live_output);
    st.audio_settings.input.combo = settings_combo_create();
    fill_device_choices(&st.audio_settings.input, &ext.audio_enumerate_input_devices, &ext.audio_get_input_device_name, &ext.audio_get_input_device_description, 1, &live_input);

    const rates: ext.SampleRateList = ext.system_get_available_sample_rates();
    st.audio_settings.rate.combo = settings_combo_create();
    fill_value_choices(&st.audio_settings.rate, &rates.rates, rates.count, ext.audio_engine_get_sample_rate(app.engine), 1);

    const buffers: ext.BufferSizeList = ext.system_get_available_buffer_sizes();
    st.audio_settings.buffer.combo = settings_combo_create();
    fill_value_choices(&st.audio_settings.buffer, &buffers.sizes, buffers.count, ext.audio_engine_get_buffer_size(app.engine), 0);

    st.audio_settings.backend_combo = settings_combo_create();
    var backend_selected: c_int = 0;
    var i: c_int = 0;
    while (i < st.SETTINGS_BACKEND_CHOICES) : (i += 1) {
        _ = raven.Rcombo_box_add_item(st.audio_settings.backend_combo, st.settings_backend_labels[@intCast(i)]);
        if (libc.strcmp(st.settings_backend_names[@intCast(i)], &live_backend) == 0) backend_selected = i;
    }
    raven.Rcombo_box_set_selected(st.audio_settings.backend_combo, backend_selected);

    const column: raven.Rid = fns.make_column(12.0);
    _ = raven.Rwidget_add_child(column, fns.make_label("Audio settings", 15.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, settings_row("Output", st.audio_settings.output.combo));
    _ = raven.Rwidget_add_child(column, settings_row("Input", st.audio_settings.input.combo));
    _ = raven.Rwidget_add_child(column, settings_row("Sample rate", st.audio_settings.rate.combo));
    _ = raven.Rwidget_add_child(column, settings_row("Buffer size", st.audio_settings.buffer.combo));
    _ = raven.Rwidget_add_child(column, settings_row("Backend", st.audio_settings.backend_combo));

    const buttons: raven.Rid = fns.make_row(10.0);
    _ = fns.add_button(buttons, "Cancel", &on_settings_cancel, null, raven.R_BUTTON_FLAT);
    _ = fns.add_button(buttons, "Apply", &on_settings_apply, null, raven.R_BUTTON_PRIMARY);
    _ = raven.Rwidget_add_child(column, buttons);

    const panel: raven.Rid = fns.make_panel(column, 16.0);
    raven.Rwidget_set_size(panel, 480.0, -1.0);
    raven.Rdialog_open(app.window, panel, &on_settings_closed, null);
}

pub fn build_header() raven.Rid {
    const row: raven.Rid = fns.make_row(18.0);
    const brand: raven.Rid = fns.make_column(2.0);
    const brand_name: raven.Rid = fns.make_label("SERIDIAN", 17.0, &st.accent_cyan);
    const brand_subtitle: raven.Rid = fns.make_label("STUDIO  ·  SERIDIAN.DEV", 12.0, &st.muted_text);
    _ = raven.Rwidget_add_child(brand, brand_name);
    _ = raven.Rwidget_add_child(brand, brand_subtitle);
    _ = raven.Rwidget_add_child(row, brand);

    const divider: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_SEPARATOR);
    _ = raven.Rwidget_add_child(row, divider);

    app.project_label = fns.make_label(ext.project_get_name(), 15.0, null);
    raven.Rwidget_set_tooltip(app.project_label, ext.project_get_folder_path());
    raven.Rslot_set_fill(app.project_label, 1.0);
    raven.Rslot_set_valign(app.project_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(row, app.project_label);

    app.midi_header_label = fns.make_label("MIDI input: none connected", 12.0, &st.muted_text);
    raven.Rwidget_set_tooltip(app.midi_header_label, "Connected MIDI input device; choose the port on the Session tab");
    raven.Rslot_set_valign(app.midi_header_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(row, app.midi_header_label);

    const new_button: raven.Rid = fns.add_button(row, "New", &fns.on_new_project, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(new_button, "Create an empty session (Ctrl+N). Current mixer contents will be cleared");
    const open_button: raven.Rid = fns.add_button(row, "Open session", &fns.on_open_project, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(open_button, "Open a saved Seridian Studio session folder (Ctrl+O)");
    const save_button: raven.Rid = fns.add_button(row, "Save", &fns.on_save_project, null, raven.R_BUTTON_DEFAULT);
    raven.Rwidget_set_tooltip(save_button, "Save this session to its current folder (Ctrl+S)");
    const save_as_button: raven.Rid = fns.add_button(row, "Save As", &on_save_as_button, null, raven.R_BUTTON_FLAT);
    set_shortcut_tooltip(save_as_button, "Save this session to a new folder", ext.SERIDIAN_ACTION_FILE_SAVE_AS);
    const export_button: raven.Rid = fns.add_button(row, "Export WAV", &on_export_button, null, raven.R_BUTTON_FLAT);
    set_shortcut_tooltip(export_button, "Render the mix to a WAV file", ext.SERIDIAN_ACTION_FILE_EXPORT_WAV);
    const settings_button: raven.Rid = fns.add_button(row, "Settings", &on_open_settings, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(settings_button, "Audio devices, sample rate and buffer size");
    fns.build_preflight_indicator(row);
    return fns.make_panel(row, 12.0);
}

/// Tooltip "<what> (<shortcut>)", the shortcut text coming from the keymap table.
fn set_shortcut_tooltip(widget: raven.Rid, what: [*c]const u8, action: ext.SeridianAction) void {
    var keys: [32]u8 = undefined;
    var text: [96]u8 = undefined;
    if (ext.seridian_keymap_shortcut(action, &keys, keys.len) < 0) {
        raven.Rwidget_set_tooltip(widget, what);
        return;
    }
    _ = libc.snprintf(&text, text.len, "%s (%s)", what, @as([*c]const u8, &keys));
    raven.Rwidget_set_tooltip(widget, &text);
}

fn on_save_as_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    fns.run_action(ext.SERIDIAN_ACTION_FILE_SAVE_AS);
}

fn on_export_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    fns.run_action(ext.SERIDIAN_ACTION_FILE_EXPORT_WAV);
}

pub fn bpm_apply(bpm: f64) void {
    const clamped: f64 = libc.fmin(libc.fmax(bpm, st.SERIDIAN_BPM_MIN), st.SERIDIAN_BPM_MAX);
    raven.Rspin_box_set_value(app.bpm_input, clamped);
    fns.on_bpm_changed(app.bpm_input, clamped, null);
}

pub fn on_bpm_down(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    bpm_apply(raven.Rspin_box_get_value(app.bpm_input) - 1.0);
}

pub fn on_bpm_up(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    bpm_apply(raven.Rspin_box_get_value(app.bpm_input) + 1.0);
}

/// Tap tempo: the average interval of the last taps, reset after a pause.
pub fn on_tap_tempo(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    var now_spec: libc.timespec = undefined;
    if (libc.timespec_get(&now_spec, libc.TIME_UTC) == 0) {
        fns.set_status("Tap tempo is unavailable: no clock");
        return;
    }
    const now: f64 = @as(f64, @floatFromInt(now_spec.sec)) + @as(f64, @floatFromInt(now_spec.nsec)) * 1e-9;
    if (st.tap_count > 0 and now - st.tap_times[@intCast(st.tap_count - 1)] > st.SERIDIAN_TAP_WINDOW_SECONDS) st.tap_count = 0;
    if (st.tap_count == st.SERIDIAN_TAP_HISTORY) {
        _ = libc.memmove(&st.tap_times, &st.tap_times[1], @sizeOf(f64) * (st.SERIDIAN_TAP_HISTORY - 1));
        st.tap_count = st.SERIDIAN_TAP_HISTORY - 1;
    }
    st.tap_times[@intCast(st.tap_count)] = now;
    st.tap_count += 1;
    if (st.tap_count < 2) {
        fns.set_status("Tap again to set the tempo");
        return;
    }
    const average_interval: f64 = (st.tap_times[@intCast(st.tap_count - 1)] - st.tap_times[0]) / @as(f64, @floatFromInt(st.tap_count - 1));
    if (average_interval <= 0.0) return;
    const bpm: f64 = libc.round(60.0 / average_interval);
    bpm_apply(bpm);
    var message: [48]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Tapped tempo: %.0f BPM", bpm);
    fns.set_status(&message);
}

pub fn make_bpm_step_button(text: [*c]const u8, tooltip: [*c]const u8, callback: raven.RButtonClickedCallback) raven.Rid {
    const button: raven.Rid = fns.make_fixed_button(text, 28.0, 32.0);
    raven.Rbutton_set_clicked_callback(button, callback, null);
    raven.Rwidget_set_tooltip(button, tooltip);
    return button;
}

pub fn build_transport() raven.Rid {
    const bar: raven.Rid = fns.make_row(24.0);

    // Group 1: transport buttons, 44 px tall, with icon and label.
    const transport: raven.Rid = fns.make_row(8.0);
    app.play_button = fns.make_fixed_button("▶  Play", 104.0, 44.0);
    raven.Rbutton_set_clicked_callback(app.play_button, &fns.on_play, null);
    _ = raven.Rwidget_add_child(transport, app.play_button);
    app.stop_button = fns.make_fixed_button("■  Stop", 104.0, 44.0);
    raven.Rbutton_set_clicked_callback(app.stop_button, &fns.on_stop, null);
    raven.Rwidget_set_tooltip(app.stop_button, "Stop playback and return to the beginning (Enter)");
    fns.style_fill_button(app.stop_button, &st.color_stop_red, &st.color_readout);
    _ = raven.Rwidget_add_child(transport, app.stop_button);
    app.record_button = fns.make_fixed_button("●", 44.0, 44.0);
    raven.Rwidget_set_metric(app.record_button, raven.R_METRIC_CORNER_RADIUS, 22.0);
    fns.style_fill_button(app.record_button, &st.color_record_red, &st.color_readout);
    raven.Rwidget_set_tooltip(app.record_button, "Record is not available yet: the audio engine has no record control to call from the UI");
    raven.Rwidget_set_enabled(app.record_button, 0);
    _ = raven.Rwidget_add_child(transport, app.record_button);
    const split_button: raven.Rid = fns.make_fixed_button("✂  Split", 104.0, 44.0);
    raven.Rbutton_set_clicked_callback(split_button, &fns.on_split_button, null);
    raven.Rwidget_set_tooltip(split_button, "Split the selected clip, or every clip under the playhead, at the playhead (Ctrl+E, Cmd+E on macOS)");
    _ = raven.Rwidget_add_child(transport, split_button);
    _ = raven.Rwidget_add_child(bar, transport);

    // Group 2: time readout, large, with Bar and Beat beneath.
    const time_group: raven.Rid = fns.make_column(2.0);
    app.clock_label = fns.make_label("00:00.000", 40.0, &st.color_readout);
    raven.Rlabel_set_font(app.clock_label, raven.Rfont_get_variant(raven.Rfont_get_monospace(), raven.R_FONT_BOLD));
    raven.Rwidget_set_size(app.clock_label, 220.0, 56.0);
    raven.Rwidget_set_tooltip(app.clock_label, "Playhead time (minutes:seconds.milliseconds)");
    _ = raven.Rwidget_add_child(time_group, app.clock_label);
    app.position_label = fns.make_label("Bar 1 · Beat 1", 16.0, &st.muted_text);
    raven.Rwidget_set_size(app.position_label, 220.0, -1.0);
    raven.Rwidget_set_tooltip(app.position_label, "Playhead position in bars and beats");
    _ = raven.Rwidget_add_child(time_group, app.position_label);
    _ = raven.Rwidget_add_child(bar, time_group);

    // Group 3: tempo field with steppers and tap tempo.
    const tempo: raven.Rid = fns.make_row(6.0);
    const tempo_label: raven.Rid = fns.make_label("BPM", 12.0, &st.muted_text);
    raven.Rslot_set_valign(tempo_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(tempo, tempo_label);
    _ = raven.Rwidget_add_child(tempo, make_bpm_step_button("−", "Lower tempo by 1 BPM", &on_bpm_down));
    app.bpm_input = raven.Rwidget_create(raven.R_WIDGET_SPIN_BOX);
    raven.Rspin_box_set_range(app.bpm_input, st.SERIDIAN_BPM_MIN, st.SERIDIAN_BPM_MAX);
    raven.Rspin_box_set_step(app.bpm_input, 1.0);
    raven.Rspin_box_set_decimals(app.bpm_input, 0);
    raven.Rspin_box_set_value(app.bpm_input, ext.audio_engine_get_tempo(app.engine));
    raven.Rspin_box_set_changed_callback(app.bpm_input, &fns.on_bpm_changed, null);
    raven.Rwidget_set_tooltip(app.bpm_input, "Session tempo in beats per minute");
    raven.Rwidget_set_size(app.bpm_input, 64.0, 32.0);
    _ = raven.Rwidget_add_child(tempo, app.bpm_input);
    _ = raven.Rwidget_add_child(tempo, make_bpm_step_button("+", "Raise tempo by 1 BPM", &on_bpm_up));
    const tap: raven.Rid = fns.make_fixed_button("Tap", 52.0, 32.0);
    raven.Rbutton_set_clicked_callback(tap, &on_tap_tempo, null);
    raven.Rbutton_set_style(tap, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(tap, "Tap in time with the music to set the tempo");
    _ = raven.Rwidget_add_child(tempo, tap);
    _ = raven.Rwidget_add_child(bar, tempo);

    const spacer: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_SPACER);
    raven.Rslot_set_fill(spacer, 1.0);
    _ = raven.Rwidget_add_child(bar, spacer);

    // Engine state pill: grey STOPPED, green PLAYING, red REC.
    app.engine_status = fns.make_label("STOPPED", 13.0, &st.color_readout);
    raven.Rlabel_set_font(app.engine_status, raven.Rfont_get_variant(raven.Rfont_get_default(), raven.R_FONT_BOLD));
    raven.Rwidget_set_tooltip(app.engine_status, "Audio engine state");
    raven.Rslot_set_valign(app.engine_status, raven.R_VALIGN_CENTER);
    app.state_pill = fns.make_panel(app.engine_status, 6.0);
    raven.Rborder_set_background(app.state_pill, st.color_idle_grey[0], st.color_idle_grey[1], st.color_idle_grey[2], 1.0);
    raven.Rborder_set_corner_radius(app.state_pill, 14.0, 14.0, 14.0, 14.0);
    _ = raven.Rwidget_add_child(bar, app.state_pill);
    return fns.make_panel(bar, 10.0);
}

// ---- MIDI input ----------------------------------------------------------

/// Enables the chosen port (or every port for -1) and disables the others.
pub fn midi_apply_selection() void {
    var i: c_int = 0;
    while (i < st.midi_port_count) : (i += 1) {
        const enabled: c_int = @intFromBool(st.midi_port_selected < 0 or st.midi_port_selected == i);
        _ = ext.audio_engine_midi_input_set_enabled(app.engine, i, enabled);
    }
}

pub fn midi_update_labels() void {
    var text: [st.MIDI_INPUT_NAME_CAPACITY + 24]u8 = undefined;
    if (st.midi_port_count <= 0) {
        _ = libc.snprintf(&text, text.len, "MIDI input: none connected");
    } else if (st.midi_port_selected >= 0 and st.midi_port_selected < st.midi_port_count) {
        _ = libc.snprintf(&text, text.len, "MIDI input: %s", @as([*c]const u8, &st.midi_port_names[@intCast(st.midi_port_selected)]));
    } else if (st.midi_port_count == 1) {
        _ = libc.snprintf(&text, text.len, "MIDI input: %s", @as([*c]const u8, &st.midi_port_names[0]));
    } else {
        _ = libc.snprintf(&text, text.len, "MIDI input: %d ports", st.midi_port_count);
    }
    if (app.midi_status_label != raven.R_INVALID_ID) raven.Rlabel_set_text(app.midi_status_label, &text);
    if (app.midi_header_label != raven.R_INVALID_ID) raven.Rlabel_set_text(app.midi_header_label, &text);
}

pub fn midi_fill_port_combo() void {
    st.midi_ui_syncing = 1;
    raven.Rcombo_box_clear_items(app.midi_port_combo);
    _ = raven.Rcombo_box_add_item(app.midi_port_combo, "All ports");
    var i: c_int = 0;
    while (i < st.midi_port_count) : (i += 1) _ = raven.Rcombo_box_add_item(app.midi_port_combo, &st.midi_port_names[@intCast(i)]);
    raven.Rcombo_box_set_selected(app.midi_port_combo, st.midi_port_selected + 1);
    st.midi_ui_syncing = 0;
}

/// Re-reads the port list; rebuilds the combo only when the list changed.
pub fn midi_refresh_ports() void {
    var names: [st.MIDI_INPUT_MAX_PORTS][st.MIDI_INPUT_NAME_CAPACITY]u8 = undefined;
    var count: c_int = ext.audio_engine_midi_input_count(app.engine);
    if (count < 0) count = 0;
    if (count > st.MIDI_INPUT_MAX_PORTS) count = st.MIDI_INPUT_MAX_PORTS;
    {
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            if (ext.audio_engine_midi_input_name(app.engine, i, &names[@intCast(i)], st.MIDI_INPUT_NAME_CAPACITY) <= 0) {
                _ = libc.snprintf(&names[@intCast(i)], st.MIDI_INPUT_NAME_CAPACITY, "%s", "MIDI port");
            }
        }
    }
    var changed: c_int = @intFromBool(count != st.midi_port_count);
    {
        var i: c_int = 0;
        while (changed == 0 and i < count) : (i += 1) changed = @intFromBool(libc.strcmp(&names[@intCast(i)], &st.midi_port_names[@intCast(i)]) != 0);
    }
    if (changed != 0) {
        var selected_name = std.mem.zeroes([st.MIDI_INPUT_NAME_CAPACITY]u8);
        if (st.midi_port_selected >= 0 and st.midi_port_selected < st.midi_port_count) {
            _ = libc.snprintf(&selected_name, selected_name.len, "%s", @as([*c]const u8, &st.midi_port_names[@intCast(st.midi_port_selected)]));
        }
        st.midi_port_count = count;
        {
            var i: c_int = 0;
            while (i < count) : (i += 1) @memcpy(&st.midi_port_names[@intCast(i)], &names[@intCast(i)]);
        }
        st.midi_port_selected = -1;
        {
            var i: c_int = 0;
            while (selected_name[0] != 0 and i < count) : (i += 1) {
                if (libc.strcmp(&st.midi_port_names[@intCast(i)], &selected_name) == 0) st.midi_port_selected = i;
            }
        }
        midi_apply_selection();
        if (app.midi_port_combo != raven.R_INVALID_ID) midi_fill_port_combo();
    }
    midi_update_labels();
}

/// Frame hook: refreshes the list about once a second, not every frame.
pub fn midi_refresh_tick() void {
    const now: f64 = fns.monotonic_seconds();
    if (now < st.midi_next_refresh) return;
    st.midi_next_refresh = now + st.MIDI_INPUT_REFRESH_SECONDS;
    midi_refresh_ports();
}

pub fn on_midi_port_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    if (st.midi_ui_syncing != 0 or index < 0 or index > st.midi_port_count) return;
    st.midi_port_selected = index - 1;
    midi_apply_selection();
    midi_update_labels();
    fns.set_status(if (st.midi_port_selected < 0) "MIDI input: all ports" else "MIDI input port selected");
}

pub fn on_midi_track_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    if (st.midi_ui_syncing != 0 or index < 0 or index >= st.SERIDIAN_TRACK_COUNT) return;
    fns.on_piano_track_changed(combo, index, user_data);
    if (app.piano_track_combo != raven.R_INVALID_ID) raven.Rcombo_box_set_selected(app.piano_track_combo, app.piano_track);
}

pub fn build_session_tab() raven.Rid {
    const column: raven.Rid = fns.make_column(12.0);
    _ = raven.Rwidget_add_child(column, fns.make_label("QUICK START", 12.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, fns.make_label("Build your session", 17.0, null));
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label("Open a saved session to load its tracks and clips. Create a blank session with New.", 12.0, &st.muted_text));
    const open_button: raven.Rid = fns.add_button(column, "Open session folder", &fns.on_open_project, null, raven.R_BUTTON_PRIMARY);
    raven.Rwidget_set_tooltip(open_button, "Choose a folder containing a saved Seridian Studio session");

    _ = raven.Rwidget_add_child(column, raven.Rwidget_create(raven.R_WIDGET_SEPARATOR));
    _ = raven.Rwidget_add_child(column, raven.Rwidget_create(raven.R_WIDGET_SEPARATOR));
    _ = raven.Rwidget_add_child(column, fns.make_label("MIDI INPUT", 12.0, &st.accent_cyan));
    app.midi_status_label = fns.make_label("MIDI input: none connected", 12.0, &st.muted_text);
    raven.Rwidget_set_tooltip(app.midi_status_label, "The MIDI keyboard or controller the engine is listening to");
    _ = raven.Rwidget_add_child(column, app.midi_status_label);

    const midi_port_row: raven.Rid = fns.make_row(8.0);
    const midi_port_label: raven.Rid = fns.make_label("MIDI in", 11.0, &st.muted_text);
    raven.Rwidget_set_size(midi_port_label, 60.0, -1.0);
    raven.Rslot_set_valign(midi_port_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(midi_port_row, midi_port_label);
    app.midi_port_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    _ = raven.Rcombo_box_add_item(app.midi_port_combo, "All ports");
    raven.Rcombo_box_set_selected(app.midi_port_combo, 0);
    raven.Rcombo_box_set_changed_callback(app.midi_port_combo, &on_midi_port_changed, null);
    raven.Rslot_set_fill(app.midi_port_combo, 1.0);
    raven.Rwidget_set_tooltip(app.midi_port_combo, "Which MIDI input port to listen to; All ports listens to every connected device");
    _ = raven.Rwidget_add_child(midi_port_row, app.midi_port_combo);
    _ = raven.Rwidget_add_child(column, midi_port_row);

    const midi_track_row: raven.Rid = fns.make_row(8.0);
    const midi_track_label: raven.Rid = fns.make_label("Play on", 11.0, &st.muted_text);
    raven.Rwidget_set_size(midi_track_label, 60.0, -1.0);
    raven.Rslot_set_valign(midi_track_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(midi_track_row, midi_track_label);
    app.midi_track_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    fns.add_track_combo_items(app.midi_track_combo);
    raven.Rcombo_box_set_selected(app.midi_track_combo, app.piano_track);
    raven.Rcombo_box_set_changed_callback(app.midi_track_combo, &on_midi_track_changed, null);
    raven.Rslot_set_fill(app.midi_track_combo, 1.0);
    raven.Rwidget_set_tooltip(app.midi_track_combo, "The MIDI track that plays live from the keyboard; also the piano roll track");
    _ = raven.Rwidget_add_child(midi_track_row, app.midi_track_combo);
    _ = raven.Rwidget_add_child(column, midi_track_row);

    _ = raven.Rwidget_add_child(column, raven.Rwidget_create(raven.R_WIDGET_SEPARATOR));
    _ = raven.Rwidget_add_child(column, fns.make_label("EDITING", 12.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label("Drag the playhead to seek. Drag a clip to move it, or pull either edge to trim it. Click a clip to edit it.", 12.0, &st.muted_text));

    _ = raven.Rwidget_add_child(column, fns.make_label("MIX", 12.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label("Mute silences a track. Solo plays only tracks marked Solo. Arm a track to record into it. Pan sets the stereo position.", 12.0, &st.muted_text));

    _ = raven.Rwidget_add_child(column, fns.make_label("SHORTCUTS", 12.0, &st.accent_cyan));
    var help: [2048]u8 = undefined;
    // Rendered from the keymap table, so it cannot drift from the real bindings.
    if (ext.seridian_keymap_help(&help, help.len) < 0) {
        help[0] = 0;
        fns.set_status("Shortcut help is unavailable");
    }
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label(&help, 12.0, &st.muted_text));

    const foot: raven.Rid = fns.make_column(5.0);
    _ = raven.Rwidget_add_child(foot, fns.make_label("A SERIDIAN PRODUCT", 12.0, &st.accent_magenta));
    _ = raven.Rwidget_add_child(foot, fns.make_label("seridian.dev", 11.0, &st.muted_text));
    raven.Rslot_set_fill(foot, 1.0);
    raven.Rslot_set_valign(foot, raven.R_VALIGN_BOTTOM);
    _ = raven.Rwidget_add_child(column, foot);
    // Scrollable: at small window sizes the MIDI input rows used to be clipped with no way to reach them (QA U11).
    return fns.make_panel(scroll_wrap.wrap(RavenScrollApi{}, column), 14.0);
}

/// Raven calls behind `scroll_wrap.wrap`.
const RavenScrollApi = struct {
    pub fn createScrollBox(_: RavenScrollApi) raven.Rid {
        return raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    }
    pub fn addChild(_: RavenScrollApi, parent: raven.Rid, child: raven.Rid) void {
        _ = raven.Rwidget_add_child(parent, child);
    }
    pub fn setFill(_: RavenScrollApi, widget: raven.Rid, weight: f32) void {
        raven.Rslot_set_fill(widget, weight);
    }
};

pub fn build_clip_tab() raven.Rid {
    const column: raven.Rid = fns.make_column(12.0);
    app.clip_empty_hint = fns.make_wrapped_label("Select a clip on the arrangement to edit its gain, fades and mute here.", 12.0, &st.muted_text);
    _ = raven.Rwidget_add_child(column, app.clip_empty_hint);

    app.clip_controls = fns.make_column(12.0);
    raven.Rwidget_set_visibility(app.clip_controls, raven.R_COLLAPSED);
    app.clip_title = fns.make_label("Audio clip", 15.0, null);
    _ = raven.Rwidget_add_child(app.clip_controls, app.clip_title);
    app.clip_range = fns.make_wrapped_label("", 11.0, &st.muted_text);
    _ = raven.Rwidget_add_child(app.clip_controls, app.clip_range);

    const gain_row: raven.Rid = fns.make_row(8.0);
    const gain_label: raven.Rid = fns.make_label("Gain", 11.0, &st.muted_text);
    raven.Rwidget_set_size(gain_label, 60.0, -1.0);
    raven.Rslot_set_valign(gain_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(gain_row, gain_label);
    app.clip_gain = fns.make_slider(0.0, 2.0, 1.0, 0.01, &fns.on_clip_gain, null, 150.0);
    raven.Rslot_set_fill(app.clip_gain, 1.0);
    raven.Rwidget_set_tooltip(app.clip_gain, "Clip volume (up to +6 dB)");
    _ = raven.Rwidget_add_child(gain_row, app.clip_gain);
    app.clip_gain_readout = fns.make_label("0.0 dB", 12.0, &st.muted_text);
    raven.Rwidget_set_size(app.clip_gain_readout, 66.0, -1.0);
    _ = raven.Rwidget_add_child(gain_row, app.clip_gain_readout);
    _ = raven.Rwidget_add_child(app.clip_controls, gain_row);

    const fade_in_row: raven.Rid = fns.make_row(8.0);
    const fade_in_label: raven.Rid = fns.make_label("Fade in", 11.0, &st.muted_text);
    raven.Rwidget_set_size(fade_in_label, 60.0, -1.0);
    raven.Rslot_set_valign(fade_in_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(fade_in_row, fade_in_label);
    app.clip_fade_in = raven.Rwidget_create(raven.R_WIDGET_SPIN_BOX);
    raven.Rspin_box_set_range(app.clip_fade_in, 0.0, 0.0);
    raven.Rspin_box_set_step(app.clip_fade_in, 0.05);
    raven.Rspin_box_set_decimals(app.clip_fade_in, 2);
    raven.Rspin_box_set_changed_callback(app.clip_fade_in, &fns.on_clip_fade_in, null);
    raven.Rwidget_set_size(app.clip_fade_in, 110.0, -1.0);
    raven.Rwidget_set_tooltip(app.clip_fade_in, "Fade-in length in seconds");
    _ = raven.Rwidget_add_child(fade_in_row, app.clip_fade_in);
    _ = raven.Rwidget_add_child(fade_in_row, fns.make_label("seconds", 12.0, &st.muted_text));
    _ = raven.Rwidget_add_child(app.clip_controls, fade_in_row);

    const fade_out_row: raven.Rid = fns.make_row(8.0);
    const fade_out_label: raven.Rid = fns.make_label("Fade out", 11.0, &st.muted_text);
    raven.Rwidget_set_size(fade_out_label, 60.0, -1.0);
    raven.Rslot_set_valign(fade_out_label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(fade_out_row, fade_out_label);
    app.clip_fade_out = raven.Rwidget_create(raven.R_WIDGET_SPIN_BOX);
    raven.Rspin_box_set_range(app.clip_fade_out, 0.0, 0.0);
    raven.Rspin_box_set_step(app.clip_fade_out, 0.05);
    raven.Rspin_box_set_decimals(app.clip_fade_out, 2);
    raven.Rspin_box_set_changed_callback(app.clip_fade_out, &fns.on_clip_fade_out, null);
    raven.Rwidget_set_size(app.clip_fade_out, 110.0, -1.0);
    raven.Rwidget_set_tooltip(app.clip_fade_out, "Fade-out length in seconds");
    _ = raven.Rwidget_add_child(fade_out_row, app.clip_fade_out);
    _ = raven.Rwidget_add_child(fade_out_row, fns.make_label("seconds", 12.0, &st.muted_text));
    _ = raven.Rwidget_add_child(app.clip_controls, fade_out_row);

    app.clip_mute = raven.Rcheckbox_create("Mute this clip");
    raven.Rcheckbox_set_changed_callback(app.clip_mute, &fns.on_clip_mute, null);
    _ = raven.Rwidget_add_child(app.clip_controls, app.clip_mute);

    _ = raven.Rwidget_add_child(column, app.clip_controls);
    return fns.make_panel(column, 14.0);
}

pub fn build_track_fx_tab() raven.Rid {
    const column: raven.Rid = fns.make_column(10.0);

    const track_row: raven.Rid = fns.make_row(8.0);
    _ = raven.Rwidget_add_child(track_row, fns.make_label("Track", 11.0, &st.muted_text));
    app.fx_track_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        var fallback: [16]u8 = undefined;
        const name: [*c]const u8 = fns.track_display_name(track, &fallback, fallback.len);
        _ = raven.Rcombo_box_add_item(app.fx_track_combo, name);
    }
    raven.Rcombo_box_set_selected(app.fx_track_combo, app.fx_track);
    raven.Rcombo_box_set_changed_callback(app.fx_track_combo, &fns.on_fx_track_changed, null);
    raven.Rslot_set_fill(app.fx_track_combo, 1.0);
    _ = raven.Rwidget_add_child(track_row, app.fx_track_combo);
    _ = raven.Rwidget_add_child(column, track_row);

    const add_row: raven.Rid = fns.make_row(8.0);
    _ = raven.Rwidget_add_child(add_row, fns.make_label("Effect", 11.0, &st.muted_text));
    app.fx_type_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    const effect_types: c_int = ext.get_effect_type_count();
    var type_: c_int = 0;
    while (type_ < effect_types) : (type_ += 1) {
        _ = raven.Rcombo_box_add_item(app.fx_type_combo, ext.get_effect_type_name(type_));
    }
    if (effect_types > 0) raven.Rcombo_box_set_selected(app.fx_type_combo, 0);
    raven.Rslot_set_fill(app.fx_type_combo, 1.0);
    _ = raven.Rwidget_add_child(add_row, app.fx_type_combo);
    _ = fns.add_button(add_row, "Add", &fns.on_fx_add, null, raven.R_BUTTON_PRIMARY);
    _ = raven.Rwidget_add_child(column, add_row);

    const scroll: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    app.fx_slots = fns.make_column(10.0);
    _ = raven.Rwidget_add_child(scroll, app.fx_slots);
    raven.Rslot_set_fill(scroll, 1.0);
    _ = raven.Rwidget_add_child(column, scroll);
    raven.Rslot_set_fill(column, 1.0);
    fns.rebuild_fx_slots();
    return fns.make_panel(column, 14.0);
}

pub fn build_inspector() raven.Rid {
    app.tab_view = raven.Rwidget_create(raven.R_WIDGET_TAB_VIEW);
    raven.Rwidget_set_size(app.tab_view, 300.0, -1.0);
    _ = raven.Rtab_view_add_tab(app.tab_view, "Session", build_session_tab());
    _ = raven.Rtab_view_add_tab(app.tab_view, "Clip", build_clip_tab());
    _ = raven.Rtab_view_add_tab(app.tab_view, "Track FX", build_track_fx_tab());
    raven.Rtab_view_set_active(app.tab_view, st.SERIDIAN_TAB_SESSION);
    return fns.make_panel(app.tab_view, 4.0);
}
