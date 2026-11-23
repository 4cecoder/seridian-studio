//! Translated to Zig from src/ui/raven_app.c lines 2811-3459: piano roll, note undo, clipboard and computer-keyboard notes. Seridian Studio window, 1:1 translation.

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

// ---- Piano roll ----------------------------------------------------------

pub fn piano_held_reset() void {
    var slot: c_int = 0;
    while (slot < st.PIANO_HELD_SLOTS) : (slot += 1) {
        app.piano_held[@intCast(slot)].pitch = -1;
        app.piano_held[@intCast(slot)].track = 0;
    }
}

/// Lights or unlights a key on the docked Piano Roll and on the popout, when it is open.
pub fn piano_set_key_lit_all(pitch: c_int, lit: c_int) void {
    if (app.piano_roll != raven.R_INVALID_ID) ext.piano_roll_set_key_lit(app.piano_roll, pitch, lit);
    if (app.popout_roll != raven.R_INVALID_ID) ext.piano_roll_set_key_lit(app.popout_roll, pitch, lit);
}

/// Sends a note-off for every computer key that is sounding.
pub fn piano_release_all_held() void {
    var slot: c_int = 0;
    while (slot < st.PIANO_HELD_SLOTS) : (slot += 1) {
        const held = &app.piano_held[@intCast(slot)];
        if (held.pitch < 0) continue;
        ext.audio_engine_note_off(app.engine, held.track, held.pitch);
        piano_set_key_lit_all(held.pitch, 0);
        held.pitch = -1;
    }
}

pub fn add_track_combo_items(combo: raven.Rid) void {
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        var fallback: [16]u8 = undefined;
        _ = raven.Rcombo_box_add_item(combo, fns.track_display_name(track, &fallback, fallback.len));
    }
}

/// Replaces the notes of one piano roll widget with the engine notes of the selected track.
pub fn piano_roll_fill(widget: raven.Rid) void {
    if (widget == raven.R_INVALID_ID) return;
    ext.piano_roll_clear_notes(widget);
    const count = ext.midi_clip_get_note_count(app.piano_track);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(app.piano_track, index, &id, &start, &duration, &pitch, &velocity, &selected) != 1) continue;
        _ = ext.piano_roll_add_note(widget, @as(c_int, pitch), start, duration, selected);
    }
}

/// Title of the popout names the track it shows.
pub fn popout_refresh_title() void {
    if (app.popout_window == raven.R_INVALID_ID) return;
    var fallback: [16]u8 = undefined;
    var title: [st.POPOUT_TITLE_CAPACITY]u8 = undefined;
    _ = libc.snprintf(&title, title.len, "Piano Roll - %s", fns.track_display_name(app.piano_track, &fallback, fallback.len));
    const current = raven.Rwindow_get_title(app.popout_window);
    if (current == null or libc.strcmp(current, &title) != 0) raven.Rwindow_set_title(app.popout_window, &title);
}

/// Reloads the docked Piano Roll and the popout from the engine. The engine is the source of truth.
pub fn piano_roll_reload() void {
    piano_roll_fill(app.piano_roll);
    piano_roll_fill(app.popout_roll);
    popout_refresh_title();
    fns.refresh_midi_blocks();
}

/// Moves the playhead line of both piano rolls to the engine position (beats = seconds * bpm / 60). Hidden when stopped;
/// while playing the roll scrolls to keep it in view.
pub fn update_piano_playhead() void {
    var beat: f64 = -1.0;
    if (ext.audio_engine_is_playing(app.engine) != 0) {
        const rate: u32 = ext.audio_engine_get_sample_rate(app.engine);
        const bpm: f64 = ext.audio_engine_get_tempo(app.engine);
        if (rate > 0 and bpm > 0.0) {
            beat = @as(f64, @floatFromInt(ext.audio_engine_get_position(app.engine))) / @as(f64, @floatFromInt(rate)) * bpm / 60.0;
        }
    }
    if (app.piano_roll != raven.R_INVALID_ID) ext.piano_roll_set_playhead(app.piano_roll, beat, 1);
    if (app.popout_roll != raven.R_INVALID_ID) ext.piano_roll_set_playhead(app.popout_roll, beat, 1);
}

/// After an edit made in one widget (`source` is the address of its app field), reloads the other one.
pub fn piano_roll_reload_other(source: ?*const anyopaque) void {
    if (source == @as(?*const anyopaque, &app.piano_roll)) {
        piano_roll_fill(app.popout_roll);
    } else if (source == @as(?*const anyopaque, &app.popout_roll)) {
        piano_roll_fill(app.piano_roll);
    }
    fns.refresh_midi_blocks();
}

/// Engine id of the note matching pitch, start and length, or 0 when none matches.
pub fn find_engine_note_id(track: c_int, pitch: c_int, start_beat: f64, length_beats: f64) u32 {
    const count = ext.midi_clip_get_note_count(track);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var note_pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(track, index, &id, &start, &duration, &note_pitch, &velocity, &selected) != 1) continue;
        if (@as(c_int, note_pitch) != pitch) continue;
        if (libc.fabs(start - start_beat) <= 1e-6 and libc.fabs(duration - length_beats) <= 1e-6) return id;
    }
    return 0;
}

// Piano roll undo. Each edit stores the whole note list of the track before and after; the engine undo
// stack (core/undo.zig) holds one clip action whose clip_id names that pair, and the apply callback
// restores the matching list. (UNDO_ACTION_MOVE_CLIP, PIANO_UNDO_SLOTS, UndoNote, NoteSnapshot, PianoUndoEntry and
// the piano_undo_* statics live in state.zig.)

/// Releases the calloc'd notes of the snapshot (libc.free) and leaves it empty.
pub fn snapshot_free(snapshot: [*c]st.NoteSnapshot) void {
    libc.free(snapshot.*.notes);
    snapshot.*.notes = null;
    snapshot.*.count = 0;
}

/// Copies every note of `track`. Returns 0 on success, -1 when memory ran out.
/// On return `out.notes` is either null or a libc.calloc block owned by `out` (release it with snapshot_free).
pub fn snapshot_take(track: c_int, out: [*c]st.NoteSnapshot) c_int {
    out.*.notes = null;
    out.*.count = 0;
    const count = ext.midi_clip_get_note_count(track);
    if (count <= 0) return 0;
    out.*.notes = @ptrCast(@alignCast(libc.calloc(@intCast(count), @sizeOf(st.UndoNote))));
    if (out.*.notes == null) return -1;
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        var id: u32 = 0;
        const note = &out.*.notes[@intCast(out.*.count)];
        if (ext.midi_clip_get_note(track, index, &id, &note.*.start_beat, &note.*.duration, &note.*.pitch, &note.*.velocity, &note.*.selected) != 1) continue;
        out.*.count += 1;
    }
    return 0;
}

/// Same notes at the same places; selection is not part of an edit.
pub fn snapshot_equal(a: [*c]const st.NoteSnapshot, b: [*c]const st.NoteSnapshot) c_int {
    if (a.*.count != b.*.count) return 0;
    var i: c_int = 0;
    while (i < a.*.count) : (i += 1) {
        if (a.*.notes[@intCast(i)].pitch != b.*.notes[@intCast(i)].pitch or a.*.notes[@intCast(i)].velocity != b.*.notes[@intCast(i)].velocity or
            libc.fabs(a.*.notes[@intCast(i)].start_beat - b.*.notes[@intCast(i)].start_beat) > 1e-9 or
            libc.fabs(a.*.notes[@intCast(i)].duration - b.*.notes[@intCast(i)].duration) > 1e-9) return 0;
    }
    return 1;
}

/// Replaces the notes of `track` with the snapshot. Returns 0 on success.
pub fn snapshot_restore(track: c_int, snapshot: [*c]const st.NoteSnapshot) c_int {
    var failed: c_int = 0;
    ext.midi_clip_clear(track);
    var i: c_int = 0;
    while (i < snapshot.*.count) : (i += 1) {
        const note: [*c]const st.UndoNote = &snapshot.*.notes[@intCast(i)];
        const id: u32 = ext.midi_clip_add_note(track, note.*.start_beat, note.*.duration, note.*.pitch, note.*.velocity);
        if (id == 0) {
            failed = 1;
            continue;
        }
        if (note.*.selected != 0) _ = ext.midi_clip_set_note_selected(track, id, 1);
    }
    return if (failed != 0) -1 else 0;
}

/// Called by undo_undo / undo_redo for every recorded action.
pub fn piano_undo_apply(action_type: c_int, track: c_int, is_undo: c_int, old_int: c_int, new_int: c_int, old_float: f32, new_float: f32, clip_id: u64) callconv(.c) void {
    _ = track;
    _ = old_int;
    _ = new_int;
    _ = old_float;
    _ = new_float;
    if (action_type != st.UNDO_ACTION_MOVE_CLIP) return;
    var slot: c_int = 0;
    while (slot < st.PIANO_UNDO_SLOTS) : (slot += 1) {
        const entry: *const st.PianoUndoEntry = &st.piano_undo_entries[@intCast(slot)];
        if (entry.id != clip_id or clip_id == 0) continue;
        if (snapshot_restore(entry.track, if (is_undo != 0) &entry.before else &entry.after) != 0) {
            st.piano_undo_restore_failed = 1;
        }
        return;
    }
    st.piano_undo_restore_failed = 1;
}

/// Starts an undoable edit: `before` must be passed to piano_undo_commit once the edit is done.
pub fn piano_undo_begin(track: c_int, before: [*c]st.NoteSnapshot) void {
    if (snapshot_take(track, before) != 0) {
        snapshot_free(before);
        before.*.count = -1; // marks "before" as not captured so commit records nothing
        fns.set_status("Not enough memory to record undo for this edit");
    }
}

/// Records the finished edit and takes ownership of `before`. Edits that changed no note record nothing.
pub fn piano_undo_commit(track: c_int, before: [*c]st.NoteSnapshot, description: [*c]const u8) void {
    var after: st.NoteSnapshot = undefined;
    if (before.*.count < 0) {
        before.*.count = 0;
        return;
    }
    if (snapshot_take(track, &after) != 0) {
        snapshot_free(&after);
        snapshot_free(before);
        fns.set_status("Not enough memory to record undo for this edit");
        return;
    }
    if (snapshot_equal(before, &after) != 0) {
        snapshot_free(before);
        snapshot_free(&after);
        return;
    }
    const id: u64 = st.piano_undo_next_id;
    st.piano_undo_next_id += 1;
    const entry: *st.PianoUndoEntry = &st.piano_undo_entries[@intCast(id % st.PIANO_UNDO_SLOTS)];
    snapshot_free(&entry.before);
    snapshot_free(&entry.after);
    entry.id = id;
    entry.track = track;
    // Ownership: the calloc'd note arrays of `before` and `after` move into the entry; the entry frees them with
    // snapshot_free when the slot is reused, on piano_undo_reset, or just below when recording fails.
    entry.before = before.*;
    entry.after = after;
    before.*.notes = null;
    before.*.count = 0;
    if (ext.undo_record_clip(st.UNDO_ACTION_MOVE_CLIP, track, id, description) != 0) {
        entry.id = 0;
        snapshot_free(&entry.before);
        snapshot_free(&entry.after);
        fns.set_status("Could not record undo for this edit");
    }
}

/// Drops all piano roll undo history, after the session changed under it.
pub fn piano_undo_reset() void {
    ext.undo_clear();
    var slot: c_int = 0;
    while (slot < st.PIANO_UNDO_SLOTS) : (slot += 1) {
        snapshot_free(&st.piano_undo_entries[@intCast(slot)].before);
        snapshot_free(&st.piano_undo_entries[@intCast(slot)].after);
        st.piano_undo_entries[@intCast(slot)].id = 0;
    }
}

/// Mirrors a user edit in the widget into the engine clip of the selected track.
pub fn on_piano_roll_changed(kind: c_int, pitch: c_int, start_beat: f64, length_beats: f64, user_data: ?*anyopaque) callconv(.c) void {
    const track = app.piano_track;
    if (kind == st.PIANO_CHANGE_ADDED) {
        var before: st.NoteSnapshot = undefined;
        piano_undo_begin(track, &before);
        if (ext.midi_clip_add_note(track, start_beat, length_beats, @truncate(@as(c_uint, @bitCast(pitch))), st.PIANO_NOTE_VELOCITY) == 0) {
            snapshot_free(&before);
            fns.set_status("Could not add that note — the piano roll was reloaded from the track");
            piano_roll_reload();
            return;
        }
        // piano_undo_commit takes ownership of the calloc'd notes in `before`.
        piano_undo_commit(track, &before, "Add note");
        piano_roll_reload_other(user_data);
        return;
    }
    if (kind == st.PIANO_CHANGE_REMOVED) {
        var before: st.NoteSnapshot = undefined;
        piano_undo_begin(track, &before);
        const id = find_engine_note_id(track, pitch, start_beat, length_beats);
        if (id == 0 or ext.midi_clip_remove_note(track, id) != 1) {
            snapshot_free(&before);
            fns.set_status("Could not remove that note — the piano roll was reloaded from the track");
            piano_roll_reload();
            return;
        }
        piano_undo_commit(track, &before, "Delete note");
        piano_roll_reload_other(user_data);
    }
}

// Smallest note length a resize may leave, in beats (the widget's free-grid floor): st.PIANO_MIN_LENGTH_BEATS.

/// Changes the length of every selected note on `track` by delta_beats.
pub fn resize_selected_notes(track: c_int, delta_beats: f64) void {
    const count = ext.midi_clip_get_note_count(track);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(track, index, &id, &start, &duration, &pitch, &velocity, &selected) != 1) continue;
        if (selected == 0) continue;
        var length: f64 = duration + delta_beats;
        if (length < st.PIANO_MIN_LENGTH_BEATS) length = st.PIANO_MIN_LENGTH_BEATS;
        _ = ext.midi_clip_resize_note(track, id, length);
    }
}

/// Applies one selection or edit gesture from the piano roll to the engine clip of the selected track.
pub fn on_piano_roll_edit(command: [*c]const ext.PianoRollEditCommand, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    const track = app.piano_track;
    switch (command.*.kind) {
        ext.PIANO_CMD_SELECT_NOTE => {
            if (command.*.additive == 0) ext.midi_clip_deselect_all(track);
            const id = find_engine_note_id(track, command.*.pitch, command.*.start_beat, command.*.length_beats);
            if (id != 0) _ = ext.midi_clip_set_note_selected(track, id, command.*.selected);
        },
        ext.PIANO_CMD_SELECT_RECT => {
            ext.midi_clip_select_in_rect(track, command.*.start_beat, command.*.start_beat + command.*.length_beats, @truncate(@as(c_uint, @bitCast(command.*.pitch))), @truncate(@as(c_uint, @bitCast(command.*.pitch_high))), command.*.additive);
        },
        ext.PIANO_CMD_MOVE_SELECTED => {
            var before: st.NoteSnapshot = undefined;
            piano_undo_begin(track, &before);
            ext.midi_clip_move_selected(track, command.*.delta_beats, command.*.delta_pitch);
            piano_undo_commit(track, &before, "Move notes");
        },
        ext.PIANO_CMD_RESIZE_SELECTED => {
            var before: st.NoteSnapshot = undefined;
            piano_undo_begin(track, &before);
            resize_selected_notes(track, command.*.delta_beats);
            piano_undo_commit(track, &before, "Resize notes");
        },
        ext.PIANO_CMD_DELETE_SELECTED => {
            var before: st.NoteSnapshot = undefined;
            piano_undo_begin(track, &before);
            _ = ext.midi_clip_delete_selected(track);
            piano_undo_commit(track, &before, "Delete notes");
        },
        ext.PIANO_CMD_SELECT_ALL => {
            ext.midi_clip_select_all(track);
        },
        else => return,
    }
    piano_roll_reload();
}

// Piano clipboard: selected notes copied with their start relative to the earliest copied note.
// (PIANO_CLIP_CAPACITY, PianoClipNote, piano_clipboard, piano_clipboard_count and piano_clipboard_span live in
// state.zig.)

/// Copies the selected notes of `track` into the clipboard. Returns the number copied.
pub fn piano_clipboard_copy_selected(track: c_int) c_int {
    const count = ext.midi_clip_get_note_count(track);
    var earliest: f64 = 0.0;
    var latest: f64 = 0.0;
    st.piano_clipboard_count = 0;
    var index: c_int = 0;
    while (index < count and st.piano_clipboard_count < st.PIANO_CLIP_CAPACITY) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(track, index, &id, &start, &duration, &pitch, &velocity, &selected) != 1) continue;
        if (selected == 0) continue;
        const note: *st.PianoClipNote = &st.piano_clipboard[@intCast(st.piano_clipboard_count)];
        note.pitch = @as(c_int, pitch);
        note.start_beat = start;
        note.length_beats = duration;
        if (st.piano_clipboard_count == 0 or start < earliest) earliest = start;
        if (st.piano_clipboard_count == 0 or start + duration > latest) latest = start + duration;
        st.piano_clipboard_count += 1;
    }
    var i: c_int = 0;
    while (i < st.piano_clipboard_count) : (i += 1) st.piano_clipboard[@intCast(i)].start_beat -= earliest;
    st.piano_clipboard_span = if (st.piano_clipboard_count > 0) latest - earliest else 0.0;
    return st.piano_clipboard_count;
}

/// Adds the clipboard notes to `track`, moved right by offset_beats. Returns the number added.
pub fn piano_clipboard_paste(track: c_int, offset_beats: f64) c_int {
    var added: c_int = 0;
    var i: c_int = 0;
    while (i < st.piano_clipboard_count) : (i += 1) {
        const note: *const st.PianoClipNote = &st.piano_clipboard[@intCast(i)];
        if (ext.midi_clip_add_note(track, note.start_beat + offset_beats, note.length_beats, @truncate(@as(c_uint, @bitCast(note.pitch))), st.PIANO_NOTE_VELOCITY) != 0) {
            added += 1;
        }
    }
    return added;
}

pub fn piano_edit_select_all() void {
    ext.midi_clip_select_all(app.piano_track);
    piano_roll_reload();
    fns.set_status("Selected all notes");
}

pub fn piano_edit_delete() void {
    var before: st.NoteSnapshot = undefined;
    piano_undo_begin(app.piano_track, &before);
    if (ext.midi_clip_delete_selected(app.piano_track) == 0) {
        fns.set_status("Select notes to delete");
    }
    piano_undo_commit(app.piano_track, &before, "Delete notes");
    piano_roll_reload();
}

pub fn piano_edit_copy() void {
    const copied = piano_clipboard_copy_selected(app.piano_track);
    if (copied == 0) {
        fns.set_status("Select notes to copy");
        return;
    }
    var message: [64]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Copied %d note%s", copied, @as([*c]const u8, if (copied == 1) "" else "s"));
    fns.set_status(&message);
}

pub fn piano_edit_cut() void {
    const copied = piano_clipboard_copy_selected(app.piano_track);
    if (copied == 0) {
        fns.set_status("Select notes to cut");
        return;
    }
    var before: st.NoteSnapshot = undefined;
    piano_undo_begin(app.piano_track, &before);
    _ = ext.midi_clip_delete_selected(app.piano_track);
    piano_undo_commit(app.piano_track, &before, "Cut notes");
    piano_roll_reload();
    fns.set_status("Cut notes");
}

/// Paste and duplicate both place the block right after its own extent.
pub fn piano_edit_paste() void {
    if (st.piano_clipboard_count == 0) {
        fns.set_status("Nothing to paste — copy notes first");
        return;
    }
    var before: st.NoteSnapshot = undefined;
    piano_undo_begin(app.piano_track, &before);
    const added = piano_clipboard_paste(app.piano_track, st.piano_clipboard_span);
    piano_undo_commit(app.piano_track, &before, "Paste notes");
    piano_roll_reload();
    fns.set_status(@as([*c]const u8, if (added == st.piano_clipboard_count) "Pasted notes" else "Some notes could not be pasted"));
}

pub fn piano_edit_duplicate() void {
    if (piano_clipboard_copy_selected(app.piano_track) == 0) {
        fns.set_status("Select notes to duplicate");
        return;
    }
    var before: st.NoteSnapshot = undefined;
    piano_undo_begin(app.piano_track, &before);
    const added = piano_clipboard_paste(app.piano_track, st.piano_clipboard_span);
    piano_undo_commit(app.piano_track, &before, "Duplicate notes");
    piano_roll_reload();
    fns.set_status(@as([*c]const u8, if (added == st.piano_clipboard_count) "Duplicated notes" else "Some notes could not be duplicated"));
}

pub fn on_piano_track_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    if (index < 0 or index >= st.SERIDIAN_TRACK_COUNT or index == app.piano_track) return;
    piano_release_all_held();
    app.piano_track = index;
    piano_roll_reload();
    fns.set_status("Piano roll switched track");
}

pub fn on_piano_grid_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    if (index < 0 or index > 3) return;
    if (app.piano_roll != raven.R_INVALID_ID) ext.piano_roll_set_grid(app.piano_roll, index);
    if (app.popout_roll != raven.R_INVALID_ID) ext.piano_roll_set_grid(app.popout_roll, index);
    // Keep the two grid selectors showing the same value.
    if (app.piano_grid_combo != raven.R_INVALID_ID and raven.Rcombo_box_get_selected(app.piano_grid_combo) != index)
        raven.Rcombo_box_set_selected(app.piano_grid_combo, index);
    if (app.popout_grid_combo != raven.R_INVALID_ID and raven.Rcombo_box_get_selected(app.popout_grid_combo) != index)
        raven.Rcombo_box_set_selected(app.popout_grid_combo, index);
}

/// Click on the labelled keyboard: audition the note on the selected track while the key is held.
pub fn on_piano_roll_key(pitch: c_int, down: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (down == 0) {
        ext.audio_engine_note_off(app.engine, app.piano_track, pitch);
        return;
    }
    if (ext.audio_engine_track_has_instrument(app.engine, app.piano_track) == 0) {
        fns.set_status("Pick an instrument for this track");
        return;
    }
    ext.audio_engine_note_on(app.engine, app.piano_track, pitch, st.PIANO_NOTE_VELOCITY);
}

/// Creates one piano roll widget bound to the selected track. `source` is the address of the app field that
/// will hold the widget; edits report it so the other window can be reloaded.
pub fn create_piano_roll_widget(source: [*c]const raven.Rid) raven.Rid {
    // Computer keys are played by the window key handlers; on_key handles clicks on the keyboard column.
    var config: ext.PianoRollConfig = undefined;
    config.view_start_beat = 0.0;
    config.px_per_beat = st.PIANO_ROLL_PX_PER_BEAT;
    config.top_pitch = st.PIANO_ROLL_TOP_PITCH;
    config.base_pitch = app.piano_base_pitch;
    config.row_height = st.PIANO_ROLL_ROW_HEIGHT;
    config.grid_index = st.PIANO_ROLL_DEFAULT_GRID;
    config.width = st.PIANO_ROLL_WIDTH;
    config.height = st.PIANO_ROLL_HEIGHT;
    config.on_key = &on_piano_roll_key;
    config.user_data = null;
    const widget = ext.piano_roll_create(&config);
    if (widget != raven.R_INVALID_ID) {
        ext.piano_roll_set_on_change(widget, &on_piano_roll_changed, @ptrCast(@constCast(source)));
        ext.piano_roll_set_on_edit(widget, &on_piano_roll_edit, @ptrCast(@constCast(source)));
    }
    return widget;
}

pub fn on_piano_popout_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    fns.popout_toggle();
}

pub fn build_piano_roll_tab() raven.Rid {
    const column = fns.make_column(10.0);

    const header = fns.make_row(8.0);
    _ = raven.Rwidget_add_child(header, fns.make_label("Track", 11.0, &st.muted_text));
    app.piano_track_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    add_track_combo_items(app.piano_track_combo);
    raven.Rcombo_box_set_selected(app.piano_track_combo, app.piano_track);
    raven.Rcombo_box_set_changed_callback(app.piano_track_combo, &on_piano_track_changed, null);
    _ = raven.Rwidget_add_child(header, app.piano_track_combo);

    _ = raven.Rwidget_add_child(header, fns.make_label("Grid", 11.0, &st.muted_text));
    app.piano_grid_combo = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    _ = raven.Rcombo_box_add_item(app.piano_grid_combo, "1/4");
    _ = raven.Rcombo_box_add_item(app.piano_grid_combo, "1/8");
    _ = raven.Rcombo_box_add_item(app.piano_grid_combo, "1/16");
    _ = raven.Rcombo_box_add_item(app.piano_grid_combo, "1/32");
    raven.Rcombo_box_set_selected(app.piano_grid_combo, st.PIANO_ROLL_DEFAULT_GRID);
    raven.Rcombo_box_set_changed_callback(app.piano_grid_combo, &on_piano_grid_changed, null);
    _ = raven.Rwidget_add_child(header, app.piano_grid_combo);
    const spacer = fns.make_label("", 11.0, &st.muted_text);
    raven.Rslot_set_fill(spacer, 1.0);
    _ = raven.Rwidget_add_child(header, spacer);
    app.popout_toggle_button = fns.add_button(header, "Pop out", &on_piano_popout_button, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(app.popout_toggle_button, "Open the piano roll in its own window (Ctrl+Shift+P)");
    _ = raven.Rwidget_add_child(column, header);

    app.piano_roll = create_piano_roll_widget(&app.piano_roll);
    if (app.piano_roll != raven.R_INVALID_ID) {
        raven.Rslot_set_fill(app.piano_roll, 1.0);
        _ = raven.Rwidget_add_child(column, app.piano_roll);
        piano_roll_reload();
    }
    raven.Rslot_set_fill(column, 1.0);
    return column;
}

/// Computer keys play the selected track. In the main window they are consumed only while the Piano Roll tab is
/// active; the popout is always a Piano Roll. Releases always run.
pub fn piano_key_down(event: [*c]const raven.REvent, from_popout: c_int) c_int {
    if ((event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_ALT | raven.R_MOD_SUPER)) != 0) return 0;
    if (from_popout == 0 and raven.Rtab_view_get_active(app.main_tab_view) != st.SERIDIAN_MAIN_TAB_PIANO_ROLL) return 0;

    var key: c_int = @bitCast(event.*.key);
    if (key >= 'A' and key <= 'Z') key += 'a' - 'A';
    const repeat: c_int = @intFromBool(event.*.repeat != 0);
    if (key == 'z' or key == 'x') {
        if (repeat == 0) {
            app.piano_base_pitch = piano_math.shiftOctave(app.piano_base_pitch, if (key == 'z') -1 else 1);
            if (app.piano_roll != raven.R_INVALID_ID) ext.piano_roll_set_base_pitch(app.piano_roll, app.piano_base_pitch);
            if (app.popout_roll != raven.R_INVALID_ID) ext.piano_roll_set_base_pitch(app.popout_roll, app.piano_base_pitch);
        }
        return 1;
    }

    const pitch = piano_math.keyToPitch(key, app.piano_base_pitch);
    if (pitch < 0) return 0;
    if (event.*.key < 0 or event.*.key >= st.PIANO_HELD_SLOTS) return 0;
    const held = &app.piano_held[@intCast(event.*.key)];
    if (repeat != 0 or held.pitch >= 0) return 1;

    if (ext.audio_engine_track_has_instrument(app.engine, app.piano_track) == 0) {
        fns.set_status("Pick an instrument for this track");
        return 1;
    }
    held.pitch = pitch;
    held.track = app.piano_track;
    ext.audio_engine_note_on(app.engine, app.piano_track, pitch, st.PIANO_NOTE_VELOCITY);
    piano_set_key_lit_all(pitch, 1);
    return 1;
}

pub fn piano_key_up(event: [*c]const raven.REvent) c_int {
    if (event.*.key < 0 or event.*.key >= st.PIANO_HELD_SLOTS) return 0;
    const held = &app.piano_held[@intCast(event.*.key)];
    if (held.pitch < 0) return 0;
    ext.audio_engine_note_off(app.engine, held.track, held.pitch);
    piano_set_key_lit_all(held.pitch, 0);
    held.pitch = -1;
    return 1;
}

/// Handler on the shared window dispatcher. Returns non-zero when the event was consumed.
pub fn piano_key_handler(context: ?*anyopaque, raw_event: ?*const anyopaque) callconv(.c) c_int {
    _ = context;
    const event: [*c]const raven.REvent = @ptrCast(@alignCast(raw_event));
    switch (event.*.type) {
        raven.R_EVENT_KEY_DOWN => return piano_key_down(event, 0),
        raven.R_EVENT_KEY_UP => return piano_key_up(event),
        raven.R_EVENT_FOCUS_LOST => {
            piano_release_all_held();
            return 0;
        },
        else => return 0,
    }
}

pub fn piano_roll_active() c_int {
    return @intFromBool(raven.Rtab_view_get_active(app.main_tab_view) == st.SERIDIAN_MAIN_TAB_PIANO_ROLL);
}
