//! Translated to Zig from src/ui/raven_app.c lines 1477-2075: track FX, sessions (new, save, open, export), autosave and recovery. Seridian Studio window, 1:1 translation.

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

pub fn on_fx_track_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    app.fx_track = index;
    rebuild_fx_slots();
}

pub fn on_fx_add(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    const type_ = raven.Rcombo_box_get_selected(app.fx_type_combo);
    if (type_ < 0) return;
    const slot = ext.track_add_effect(app.engine, app.fx_track, type_);
    if (slot < 0) {
        fns.set_status("Could not add effect — the chain may be full");
        return;
    }
    rebuild_fx_slots();
    var message: [96]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Added %s to Track %d", ext.get_effect_type_name(type_), app.fx_track + 1);
    fns.set_status(&message);
}

pub fn on_fx_enabled(checkbox: raven.Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = checkbox;
    const binding: [*c]const st.FxBinding = @ptrCast(@alignCast(user_data));
    ext.track_set_effect_bypass(app.engine, binding.*.track, binding.*.slot, if (checked != 0) 0 else 1);
}

pub fn on_fx_remove(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const binding: [*c]const st.FxBinding = @ptrCast(@alignCast(user_data));
    if (ext.track_remove_effect(app.engine, binding.*.track, binding.*.slot) == 0) {
        rebuild_fx_slots();
        fns.set_status("Effect removed");
    } else {
        fns.set_status("Could not remove effect");
    }
}

pub fn on_fx_param(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    const binding: [*c]const st.FxBinding = @ptrCast(@alignCast(user_data));
    ext.effect_set_param_value(app.engine, binding.*.track, binding.*.slot, binding.*.param, value);
}

pub fn rebuild_fx_slots() void {
    raven.Rwidget_clear_children(app.fx_slots);
    st.fx_pool_used = 0;
    const track = app.fx_track;
    const slot_count = ext.track_get_effect_count(app.engine, track);
    if (slot_count <= 0) {
        _ = raven.Rwidget_add_child(app.fx_slots, fns.make_wrapped_label("No effects on this track yet. Choose one above and press Add.", 12.0, &st.muted_text));
        return;
    }

    var slot: c_int = 0;
    while (slot < slot_count) : (slot += 1) {
        const card = fns.make_column(6.0);
        const header = fns.make_row(8.0);
        const name = ext.track_get_effect_name(app.engine, track, slot);
        const title = fns.make_label(if (name != null) name else "Effect", 12.0, &st.accent_magenta);
        raven.Rslot_set_fill(title, 1.0);
        raven.Rslot_set_valign(title, raven.R_VALIGN_CENTER);
        _ = raven.Rwidget_add_child(header, title);

        const enabled = raven.Rcheckbox_create("On");
        raven.Rcheckbox_set_checked(enabled, @intFromBool(ext.track_get_effect_bypassed(app.engine, track, slot) == 0));
        const enabled_binding = fns.fx_alloc(track, slot, -1);
        if (enabled_binding != null) raven.Rcheckbox_set_changed_callback(enabled, &on_fx_enabled, enabled_binding);
        _ = raven.Rwidget_add_child(header, enabled);

        const remove_binding = fns.fx_alloc(track, slot, -1);
        if (remove_binding != null) _ = fns.add_button(header, "✕", &on_fx_remove, remove_binding, raven.R_BUTTON_FLAT);
        _ = raven.Rwidget_add_child(card, header);

        const param_count = ext.effect_get_param_count(app.engine, track, slot);
        var param: c_int = 0;
        while (param < param_count) : (param += 1) {
            const param_binding = fns.fx_alloc(track, slot, param);
            if (param_binding == null) break;
            const minimum = ext.effect_get_param_min(app.engine, track, slot, param);
            const maximum = ext.effect_get_param_max(app.engine, track, slot, param);
            const step: f32 = if (maximum > minimum) (maximum - minimum) / 200.0 else 0.01;

            const row = fns.make_row(8.0);
            const param_label = fns.make_label(ext.effect_get_param_name(app.engine, track, slot, param), 12.0, &st.muted_text);
            raven.Rwidget_set_size(param_label, 110.0, -1.0);
            raven.Rslot_set_valign(param_label, raven.R_VALIGN_CENTER);
            _ = raven.Rwidget_add_child(row, param_label);
            const slider = fns.make_slider(minimum, maximum, ext.effect_get_param_value(app.engine, track, slot, param), step, &on_fx_param, param_binding, 140.0);
            raven.Rslot_set_fill(slider, 1.0);
            _ = raven.Rwidget_add_child(row, slider);
            _ = raven.Rwidget_add_child(card, row);
        }
        _ = raven.Rwidget_add_child(app.fx_slots, fns.make_panel(card, 10.0));
    }
}

/// Shows the session name in the header; "Untitled Session" when the project has none.
pub fn update_project_title() void {
    var name = ext.project_get_name();
    if (name == null or name[0] == 0 or libc.strcmp(name, "Untitled") == 0) name = "Untitled Session";
    raven.Rlabel_set_text(app.project_label, name);
}

/// mkdir -p: creates `path` and any missing parents. Returns 0 on success.
pub fn make_directory_tree(path: [*c]const u8) c_int {
    var buffer: [1024]u8 = undefined;
    const length = libc.strlen(path);
    if (length == 0 or length >= buffer.len) return -1;
    @memcpy(buffer[0 .. length + 1], path[0 .. length + 1]);
    var i: usize = 1;
    while (i < length) : (i += 1) {
        if (buffer[i] != '/') continue;
        buffer[i] = 0;
        if (libc.mkdir(&buffer, 0o755) != 0 and libc.errno() != libc.EEXIST) return -1;
        buffer[i] = '/';
    }
    if (libc.mkdir(&buffer, 0o755) != 0 and libc.errno() != libc.EEXIST) return -1;
    var info: libc.Stat = undefined;
    if (libc.stat(&buffer, &info) != 0 or !libc.S_ISDIR(info.st_mode)) return -1;
    return 0;
}

/// True while a modal dialog or confirmation is open. File commands must not stack another.
pub fn modal_dialog_open() c_int {
    return @intFromBool(app.modal_depth > 0 or raven.Rwindow_has_dialog(app.window) != 0);
}

pub fn on_new_project(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    if (fns.session_has_content() != 0) {
        app.modal_depth += 1;
        const answer: c_int = @bitCast(raven.Rmessage_box(app.window, "Create a new session?", "This clears the current session from the mixer. Save first if you want to keep it.", raven.R_MESSAGE_YES_NO));
        app.modal_depth -= 1;
        if (answer != raven.R_MESSAGE_RESULT_YES) {
            fns.set_status("New session cancelled");
            return;
        }
    }
    ext.audio_engine_stop(app.engine);
    ext.audio_engine_set_position(app.engine, 0);
    {
        var track: c_int = 0;
        while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
            const count = ext.track_get_clip_count(app.engine, track);
            var clip_index: c_int = count - 1;
            while (clip_index >= 0) : (clip_index -= 1) {
                const clip_id = ext.track_get_clip_id(app.engine, track, clip_index);
                _ = ext.track_remove_clip(app.engine, track, clip_id);
            }
            ext.audio_engine_clear_track_audio(app.engine, track);
        }
    }
    if (ext.project_new() == 0) {
        var track: c_int = 0;
        while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) ext.midi_clip_clear(track);
        fns.piano_undo_reset();
        fns.piano_roll_reload();
        fns.populate_timeline();
        rebuild_fx_slots();
        update_project_title();
        raven.Rbutton_set_text(app.play_button, "▶  Play");
        raven.Rspin_box_set_value(app.bpm_input, ext.audio_engine_get_tempo(app.engine));
        autosave_reset_baseline();
        fns.set_status("New session created");
    } else {
        fns.set_status("Could not create a new session");
    }
}

// SAVE_NAME_CAPACITY, SAVE_PATH_CAPACITY, SAVE_DEFAULT_NAME and the `save_prompt` state of the open "Name this
// session" prompt live in state.zig.

/// Checks a session folder name and, when valid, builds save_prompt.path. Returns NULL or an error message.
pub fn validate_session_name(name: [*c]const u8) [*c]const u8 {
    if (name == null or name[0] == 0) return "Enter a name for the session";
    var c: [*c]const u8 = name;
    while (c.* != 0) : (c += 1) {
        if (c.* == '/' or c.* == '\\') return "The name cannot contain / or \\";
    }
    if (name[0] == '.') return "The name cannot start with a dot";
    if (libc.strlen(name) >= st.SAVE_NAME_CAPACITY) return "The name is too long";
    var parent_length = libc.strlen(&st.save_prompt.parent);
    while (parent_length > 1 and st.save_prompt.parent[parent_length - 1] == '/') parent_length -= 1;
    const written = libc.snprintf(&st.save_prompt.path, st.save_prompt.path.len, "%.*s/%s", @as(c_int, @intCast(if (parent_length == 1) 0 else parent_length)), @as([*c]const u8, &st.save_prompt.parent), name);
    if (written < 0 or @as(usize, @intCast(written)) >= st.save_prompt.path.len) return "The folder path is too long";
    var info: libc.Stat = undefined;
    if (libc.lstat(&st.save_prompt.path, &info) == 0) return "A folder with that name already exists";
    if (libc.errno() != libc.ENOENT) return "Could not check the folder name";
    return null;
}

/// The engine is the source of truth for the mixer, so its per-track state is copied into the project model
/// right before every save. The instrument is stored as its engine type, or -1 for none.
pub fn project_capture_mixer() void {
    ext.project_set_master_volume(app.master_gain);
    var i: c_int = 0;
    while (i < st.SERIDIAN_PROJECT_TRACKS and i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        ext.project_set_track_volume(i, ext.audio_engine_get_track_gain(app.engine, i));
        ext.project_set_track_pan(i, ext.audio_engine_get_track_pan(app.engine, i));
        ext.project_set_track_muted(i, if (ext.audio_engine_get_track_mute(app.engine, i) != 0) 1 else 0);
        ext.project_set_track_solo(i, if (ext.audio_engine_get_track_solo(app.engine, i) != 0) 1 else 0);
        ext.project_set_track_armed(i, if (ext.audio_engine_get_track_arm(app.engine, i) != 0) 1 else 0);
        const combo = fns.instrument_combo_index(i);
        ext.project_set_track_instrument(i, if (combo > 0) combo - 1 else -1);
    }
}

/// Applies the loaded project's per-track state through the same engine calls the mixer uses, then redraws it.
pub fn project_apply_mixer() void {
    app.master_gain = ext.project_get_master_volume();
    ext.audio_engine_set_master_gain(app.engine, app.master_gain);
    var i: c_int = 0;
    while (i < st.SERIDIAN_PROJECT_TRACKS and i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        const instrument = ext.project_get_track_instrument(i);
        if (instrument < 0 or ext.audio_engine_set_track_instrument(app.engine, i, instrument) != 0) {
            ext.audio_engine_remove_track_instrument(app.engine, i);
        }
        ext.audio_engine_set_track_gain(app.engine, i, ext.project_get_track_volume(i));
        ext.audio_engine_set_track_pan(app.engine, i, ext.project_get_track_pan(i));
        ext.audio_engine_set_track_mute(app.engine, i, ext.project_get_track_muted(i));
        ext.audio_engine_set_track_solo(app.engine, i, ext.project_get_track_solo(i));
        ext.audio_engine_set_track_arm(app.engine, i, ext.project_get_track_armed(i));
    }
    fns.mixer_sync_all();
}

/// Runs when the prompt closes. The content is still alive here, so the typed name is read first.
pub fn on_save_prompt_closed(content: raven.Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = content;
    _ = user_data;
    app.modal_depth -= 1;
    if (result != 1) {
        fns.set_status("Save cancelled");
        return;
    }
    if (make_directory_tree(&st.save_prompt.path) != 0) {
        var message: [st.SAVE_PATH_CAPACITY + 96]u8 = undefined;
        _ = libc.snprintf(&message, message.len, "Could not create folder %s: %s", @as([*c]const u8, &st.save_prompt.path), libc.strerror(libc.errno()));
        fns.set_status(&message);
        return;
    }
    project_capture_mixer();
    if (ext.project_save_as(&st.save_prompt.path) == 0) {
        update_project_title();
        autosave_reset_baseline();
        fns.set_status("Session saved");
    } else {
        fns.set_status("Could not save session");
    }
}

pub fn on_save_prompt_cancel(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rdialog_close(button, 0);
}

/// Validates the name; on any problem the error is shown and the prompt stays open.
pub fn confirm_save_prompt(widget: raven.Rid) void {
    const typed = raven.Rtext_input_get_text(st.save_prompt.input);
    _ = libc.snprintf(&st.save_prompt.name, st.save_prompt.name.len, "%s", @as([*c]const u8, if (typed != null) typed else ""));
    const problem = validate_session_name(&st.save_prompt.name);
    if (problem != null) {
        raven.Rlabel_set_text(st.save_prompt.error_label, problem);
        fns.set_status(problem);
        return;
    }
    raven.Rdialog_close(widget, 1);
}

pub fn on_save_prompt_ok(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    confirm_save_prompt(button);
}

pub fn on_save_prompt_committed(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = text;
    _ = user_data;
    confirm_save_prompt(input);
}

/// Step 2 of Save As: asks for the new session folder's name inside the chosen parent folder.
pub fn open_save_name_prompt() void {
    st.save_prompt.input = raven.Rwidget_create(raven.R_WIDGET_TEXT_INPUT);
    raven.Rwidget_set_size(st.save_prompt.input, 360.0, -1.0);
    raven.Rtext_input_set_max_length(st.save_prompt.input, st.SAVE_NAME_CAPACITY - 1);
    raven.Rtext_input_set_text(st.save_prompt.input, st.SAVE_DEFAULT_NAME);
    raven.Rtext_input_set_committed_callback(st.save_prompt.input, &on_save_prompt_committed, null);
    st.save_prompt.error_label = fns.make_wrapped_label("", 11.0, &st.color_stop_red);

    var location: [st.SAVE_PATH_CAPACITY + 16]u8 = undefined;
    _ = libc.snprintf(&location, location.len, "Inside %s", @as([*c]const u8, &st.save_prompt.parent));

    const column = fns.make_column(12.0);
    _ = raven.Rwidget_add_child(column, fns.make_label("Name this session", 15.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label(&location, 11.0, &st.muted_text));
    _ = raven.Rwidget_add_child(column, st.save_prompt.input);
    _ = raven.Rwidget_add_child(column, st.save_prompt.error_label);

    const buttons = fns.make_row(10.0);
    _ = fns.add_button(buttons, "Cancel", &on_save_prompt_cancel, null, raven.R_BUTTON_FLAT);
    _ = fns.add_button(buttons, "OK", &on_save_prompt_ok, null, raven.R_BUTTON_PRIMARY);
    _ = raven.Rwidget_add_child(column, buttons);

    const panel = fns.make_panel(column, 16.0);
    raven.Rwidget_set_size(panel, 420.0, -1.0);
    app.modal_depth += 1;
    raven.Rdialog_open(app.window, panel, &on_save_prompt_closed, null);
    raven.Rwidget_focus(st.save_prompt.input);
    raven.Rtext_input_select_all(st.save_prompt.input);
}

/// Save As: pick an existing parent folder, then name the new session folder created inside it.
pub fn choose_save_location() void {
    var dialog = std.mem.zeroes(raven.RFileDialogDesc);
    dialog.parent = app.window;
    dialog.title = "Choose where to create the session folder";
    dialog.flags = raven.R_FILE_DIALOG_RAVEN;
    app.modal_depth += 1;
    const folder = raven.Rfile_dialog_select_folder(&dialog);
    app.modal_depth -= 1;
    if (folder == null or folder[0] == 0) {
        fns.set_status("Save cancelled");
        return;
    }
    if (libc.strlen(folder) >= st.save_prompt.parent.len) {
        fns.set_status("That folder path is too long");
        return;
    }
    _ = libc.snprintf(&st.save_prompt.parent, st.save_prompt.parent.len, "%s", folder);
    open_save_name_prompt();
}

/// Saves to the session folder, or asks for one when `choose_folder` is set or none is known yet.
pub fn save_session(choose_folder: c_int) void {
    if (choose_folder == 0 and ext.project_has_save_location() != 0) {
        project_capture_mixer();
        if (ext.project_save(null) == 0) {
            update_project_title();
            autosave_reset_baseline();
            fns.set_status("Session saved");
        } else {
            fns.set_status("Could not save session");
        }
        return;
    }
    choose_save_location();
}

/// Renders the mix to a WAV file the user picks. The engine takes the length from the clips.
pub fn export_wav() void {
    if (ext.audio_engine_is_playing(app.engine) != 0) {
        fns.set_status("Stop playback before exporting");
        return;
    }
    const filters = [_]raven.RFileFilter{.{ .name = "WAV audio", .patterns = "*.wav" }};
    var dialog = std.mem.zeroes(raven.RFileDialogDesc);
    dialog.parent = app.window;
    dialog.title = "Export WAV";
    dialog.file_name = "mix.wav";
    dialog.filters = &filters;
    dialog.filter_count = 1;
    dialog.default_extension = "wav";
    dialog.flags = raven.R_FILE_DIALOG_RAVEN;
    app.modal_depth += 1;
    const path = raven.Rfile_dialog_save(&dialog);
    app.modal_depth -= 1;
    if (path == null or path[0] == 0) {
        fns.set_status("Export cancelled");
        return;
    }
    fns.set_status("Exporting WAV...");
    if (ext.audio_export_wav(app.engine, path, 0.0, 16) == 0) {
        var message: [320]u8 = undefined;
        _ = libc.snprintf(&message, message.len, "Exported WAV to %s", path);
        fns.set_status(&message);
    } else {
        fns.set_status("Could not export WAV");
    }
}

pub fn on_save_project(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    save_session(0);
}

/// Redraws every view from the freshly loaded project.
pub fn refresh_after_load() void {
    project_apply_mixer();
    fns.piano_undo_reset();
    fns.piano_roll_reload();
    fns.populate_timeline();
    rebuild_fx_slots();
    update_project_title();
    // The loaded tempo goes to the engine and the spin box only: routing it through bpm_apply would mark the
    // freshly opened project as modified.
    const bpm: f32 = ext.project_get_bpm();
    ext.audio_engine_set_tempo(app.engine, bpm);
    raven.Rspin_box_set_value(app.bpm_input, ext.audio_engine_get_tempo(app.engine));
    raven.Rbutton_set_text(app.play_button, "▶  Play");
}

/// Loads the session in folder and refreshes every view from it. Shared by Ctrl+O and the "open" socket command.
/// Returns 0 on success.
pub fn open_session_folder(folder: [*c]const u8) c_int {
    ext.audio_engine_stop(app.engine);
    if (ext.project_load(folder) != 0) return -1;
    refresh_after_load();
    autosave_reset_baseline();
    return 0;
}

// Autosave: every AUTOSAVE_INTERVAL_SECONDS, when the session differs from the last saved or opened state, a copy
// goes to the recovery folder (never the user's session folder). The engine has no change counter, so "changed" is
// a hash of the mixer, tempo, clips and MIDI notes.
// (AUTOSAVE_INTERVAL_SECONDS, autosave_baseline and autosave_next_time live in state.zig.)

pub fn hash_bytes(hash: u64, data: ?*const anyopaque, length: usize) u64 {
    var hash_ = hash;
    const bytes: [*c]const u8 = @ptrCast(data);
    var i: usize = 0;
    while (i < length) : (i += 1) {
        hash_ ^= bytes[i];
        hash_ *%= 1099511628211;
    }
    return hash_;
}

pub fn session_signature() u64 {
    var hash: u64 = 14695981039346656037;
    const tempo = ext.audio_engine_get_tempo(app.engine);
    hash = hash_bytes(hash, &tempo, @sizeOf(@TypeOf(tempo)));
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        const gain = ext.audio_engine_get_track_gain(app.engine, track);
        const pan = ext.audio_engine_get_track_pan(app.engine, track);
        const flags: c_int = (if (ext.audio_engine_get_track_mute(app.engine, track) != 0) @as(c_int, 1) else 0) |
            (if (ext.audio_engine_get_track_solo(app.engine, track) != 0) @as(c_int, 2) else 0) |
            (if (ext.audio_engine_get_track_arm(app.engine, track) != 0) @as(c_int, 4) else 0);
        const instrument = fns.instrument_combo_index(track);
        hash = hash_bytes(hash, &gain, @sizeOf(@TypeOf(gain)));
        hash = hash_bytes(hash, &pan, @sizeOf(@TypeOf(pan)));
        hash = hash_bytes(hash, &flags, @sizeOf(@TypeOf(flags)));
        hash = hash_bytes(hash, &instrument, @sizeOf(@TypeOf(instrument)));
        const clips = ext.track_get_clip_count(app.engine, track);
        hash = hash_bytes(hash, &clips, @sizeOf(@TypeOf(clips)));
        {
            var i: c_int = 0;
            while (i < clips) : (i += 1) {
                const id = ext.track_get_clip_id(app.engine, track, i);
                hash = hash_bytes(hash, &id, @sizeOf(@TypeOf(id)));
            }
        }
        const notes = ext.midi_clip_get_note_count(track);
        hash = hash_bytes(hash, &notes, @sizeOf(@TypeOf(notes)));
        {
            var i: c_int = 0;
            while (i < notes) : (i += 1) {
                var id: u32 = 0;
                var start: f64 = 0.0;
                var duration: f64 = 0.0;
                var pitch: u8 = 0;
                var velocity: u8 = 0;
                var selected: c_int = 0;
                if (ext.midi_clip_get_note(track, i, &id, &start, &duration, &pitch, &velocity, &selected) != 1) continue; // returns 1 on success
                hash = hash_bytes(hash, &id, @sizeOf(@TypeOf(id)));
                hash = hash_bytes(hash, &start, @sizeOf(@TypeOf(start)));
                hash = hash_bytes(hash, &duration, @sizeOf(@TypeOf(duration)));
                hash = hash_bytes(hash, &pitch, @sizeOf(@TypeOf(pitch)));
                hash = hash_bytes(hash, &velocity, @sizeOf(@TypeOf(velocity)));
            }
        }
    }
    return hash;
}

pub fn monotonic_seconds() f64 {
    var now: libc.timespec = undefined;
    _ = libc.clock_gettime(libc.CLOCK_MONOTONIC, &now);
    return @as(f64, @floatFromInt(now.sec)) + @as(f64, @floatFromInt(now.nsec)) / 1e9;
}

/// The session was just saved, opened or cleared: nothing is unsaved, so the recovery copy is stale.
pub fn autosave_reset_baseline() void {
    st.autosave_baseline = session_signature();
    st.autosave_next_time = monotonic_seconds() + st.AUTOSAVE_INTERVAL_SECONDS;
    _ = ext.recovery_discard();
}

pub fn autosave_tick() void {
    const now = monotonic_seconds();
    if (now < st.autosave_next_time) return;
    st.autosave_next_time = now + st.AUTOSAVE_INTERVAL_SECONDS;
    if (modal_dialog_open() != 0) return;
    const signature = session_signature();
    if (signature == st.autosave_baseline) return;
    const path = ext.recovery_session_path();
    if (path == null) return;
    project_capture_mixer();
    if (ext.project_save_copy(path) == 0) {
        fns.set_status("Autosaved a recovery copy");
    } else {
        fns.set_status("Autosave failed");
    }
}

/// Startup: a recovery copy with no clean-exit marker means the last run ended abruptly.
pub fn on_recovery_choice(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    raven.Rdialog_close(button, @truncate(@as(isize, @bitCast(@intFromPtr(user_data)))));
}

pub fn offer_recovery() void {
    const pending = ext.recovery_pending();
    _ = ext.recovery_mark_running();
    if (pending == 0) return;

    const column = fns.make_column(12.0);
    _ = raven.Rwidget_add_child(column, fns.make_label("Restore unsaved work?", 15.0, &st.accent_cyan));
    _ = raven.Rwidget_add_child(column, fns.make_wrapped_label("Seridian Studio did not close cleanly last time. An automatic recovery copy of your session was found.", 12.0, &st.muted_text));
    const buttons = fns.make_row(10.0);
    _ = fns.add_button(buttons, "Discard", &on_recovery_choice, @ptrFromInt(2), raven.R_BUTTON_FLAT);
    _ = fns.add_button(buttons, "Restore", &on_recovery_choice, @ptrFromInt(1), raven.R_BUTTON_PRIMARY);
    _ = raven.Rwidget_add_child(column, buttons);
    const panel = fns.make_panel(column, 16.0);
    raven.Rwidget_set_size(panel, 440.0, -1.0);

    app.modal_depth += 1;
    const answer = raven.Rdialog_run(app.window, panel);
    app.modal_depth -= 1;
    if (answer == 2) {
        _ = ext.recovery_discard();
        fns.set_status("Recovery copy discarded");
        return;
    }
    // Restore, or the dialog was dismissed: never throw work away without an explicit Discard.
    const path = ext.recovery_session_path();
    ext.audio_engine_stop(app.engine);
    if (path != null and ext.project_load_unsaved(path) == 0) {
        refresh_after_load();
        fns.set_status("Restored unsaved work. Use Save to keep it");
    } else {
        fns.set_status("Could not restore the recovery copy");
    }
}

pub fn on_open_project(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    var dialog = std.mem.zeroes(raven.RFileDialogDesc);
    dialog.parent = app.window;
    dialog.title = "Open a Seridian Studio session folder";
    dialog.flags = raven.R_FILE_DIALOG_RAVEN;
    app.modal_depth += 1;
    const folder = raven.Rfile_dialog_select_folder(&dialog);
    app.modal_depth -= 1;
    if (folder != null and folder[0] != 0) {
        if (fns.session_has_content() != 0) {
            app.modal_depth += 1;
            const answer: c_int = @bitCast(raven.Rmessage_box(app.window, "Open this session?", "Opening a session replaces the current mixer contents. Save first if you want to keep them.", raven.R_MESSAGE_YES_NO));
            app.modal_depth -= 1;
            if (answer != raven.R_MESSAGE_RESULT_YES) {
                fns.set_status("Open cancelled");
                return;
            }
        }
        if (open_session_folder(folder) == 0) {
            fns.set_status("Session opened");
        } else {
            fns.set_status("Could not open this session");
        }
    } else {
        fns.set_status("Open cancelled");
    }
}

pub fn on_window_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    ext.audio_engine_stop(app.engine);
    fns.piano_undo_reset();
    _ = ext.recovery_mark_clean();
    app.closing = 1;
    if (app.popout_window != raven.R_INVALID_ID and raven.Rwindow_is_valid(app.popout_window) != 0) {
        fns.popout_save_state_on_quit();
    }
    if (app.mixers[st.MIXER_VIEW_POPOUT].window != raven.R_INVALID_ID and raven.Rwindow_is_valid(app.mixers[st.MIXER_VIEW_POPOUT].window) != 0) {
        fns.mixer_popout_save_on_quit();
    } else {
        fns.mixer_save_keep_position(0); // docked: keep the stored geometry, write only open=0
    }
    raven.Rquit(0);
    return raven.R_TRUE;
}
