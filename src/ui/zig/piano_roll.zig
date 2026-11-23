//! Piano roll widget glue for Raven. Geometry, pitch, grid and keyboard rules
//! come from piano_math.zig; this file owns the widget state, the paint and
//! event callbacks, and the C-ABI exports. Mirrors src/ui/knob.c: a CUSTOM
//! widget created with Rwidget_create(R_WIDGET_CUSTOM), painted through
//! Rcustom_set_paint_callback and driven through Rwidget_set_event_callback.
//!
//! Interaction:
//!   - left press on a note selects it (shift toggles); a press on a selected
//!     note drags every selected note; a press in the right-edge zone resizes
//!     them. A press on empty grid starts a rectangle selection (shift keeps the
//!     current selection). Double click on empty grid adds a note snapped to the
//!     grid.
//!   - right click removes the note under the pointer.
//!   - Delete and Backspace delete the selection; Ctrl+A selects all.
//!   - Selection and edits are reported through the edit callback; the app applies
//!     them to the engine and reloads the widget, so the engine stays the source of
//!     truth.
//!   - QWERTY keys play notes from the base pitch (see piano_math.keyOffset);
//!     z and x shift the base octave down and up.
//!   - The left key column is a labelled keyboard: each key shows its note name, and
//!     a key that the computer keyboard plays from the base pitch also shows that
//!     letter. A key lights while held (from the
//!     keyboard or a click). A left click on a key sends on_key(pitch, 1) and
//!     on_key(pitch, 0) on release, so the app can audition the note.
//!   - A held key sends a note-off when released, when the widget loses focus,
//!     and when it is destroyed, so no note sticks.
//!
//! Raven is declared by hand (no @cImport). Numeric enum values were checked
//! against vendor/raven/include/raven/*.h with a C probe: R_WIDGET_CUSTOM = 543,
//! REventType values 194..203 for mouse down / key down / key up / focus lost.

const std = @import("std");
const pm = @import("piano_math.zig");
const edit = @import("piano_edit.zig");

// ---- Raven API (hand-declared) ----------------------------------------------

/// Rid is uint32_t in raven_core.h; R_INVALID_ID is (Rid)-1.
pub const Rid = u32;
const r_invalid_id: Rid = std.math.maxInt(u32);
const r_false: c_int = 0;
const r_true: c_int = 1;

const r_widget_custom: c_int = 543;
const r_mouse_left: c_int = 0;
const r_mouse_right: c_int = 1;
const r_event_mouse_down: c_int = 194;
const r_event_key_down: c_int = 199;
const r_event_key_up: c_int = 200;
const r_event_focus_lost: c_int = 203;
const r_event_mouse_move: c_int = 193;
const r_event_mouse_up: c_int = 195;
const r_key_a: c_int = 65;
const r_key_backspace: c_int = 259;
const r_key_delete: c_int = 261;
const r_mod_shift: u32 = 1 << 0;

/// Opaque painter (RPainter in raven_draw.h).
const RPainter = opaque {};

/// Mirrors REvent in raven_window.h field for field.
const REvent = extern struct {
    type: c_int,
    window: Rid,
    target: Rid,
    x: f32,
    y: f32,
    local_x: f32,
    local_y: f32,
    delta_x: f32,
    delta_y: f32,
    wheel_x: f32,
    wheel_y: f32,
    button: c_int,
    clicks: c_int,
    key: c_int,
    modifiers: u32,
    repeat: c_int,
    codepoint: u32,
};

const RPaintCallback = *const fn (Rid, *RPainter, f32, f32, ?*anyopaque) callconv(.c) void;
const RWidgetEventCallback = *const fn (Rid, *const REvent, ?*anyopaque) callconv(.c) c_int;
const RWidgetDestroyCallback = *const fn (Rid, ?*anyopaque) callconv(.c) void;

extern fn Rwidget_create(widget_type: c_int) Rid;
extern fn Rwidget_is_valid(widget: Rid) c_int;
extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) void;
extern fn Rwidget_set_focusable(widget: Rid, focusable: c_int) void;
extern fn Rwidget_focus(widget: Rid) void;
extern fn Rwidget_invalidate(widget: Rid) void;
extern fn Rwidget_set_user_handle(widget: Rid, handle: ?*anyopaque) void;
extern fn Rwidget_get_user_handle(widget: Rid) ?*anyopaque;
extern fn Rwidget_set_event_callback(widget: Rid, callback: RWidgetEventCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_set_destroy_callback(widget: Rid, callback: RWidgetDestroyCallback, user_data: ?*anyopaque) void;
extern fn Rcustom_set_paint_callback(widget: Rid, callback: RPaintCallback, user_data: ?*anyopaque) void;
extern fn Rdraw_rect(painter: *RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_line(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_text(painter: *RPainter, font: Rid, size: f32, x: f32, y: f32, text: [*:0]const u8, r: f32, g: f32, b: f32, a: f32) void;

// ---- Palette (mirrors src/ui/zig/palette.zig; this file is built as its own library) ----

const Color = struct { r: f32, g: f32, b: f32, a: f32 };

const color_deep: Color = .{ .r = 0.039, .g = 0.043, .b = 0.102, .a = 1.0 }; // palette_deep
const color_panel: Color = .{ .r = 0.063, .g = 0.071, .b = 0.165, .a = 1.0 }; // palette_panel
const color_neon_cyan: Color = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 }; // palette_neon_cyan
const color_violet: Color = .{ .r = 0.482, .g = 0.184, .b = 1.000, .a = 1.0 }; // palette_violet
const color_muted: Color = .{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 }; // palette_muted
const color_selected: Color = .{ .r = 1.000, .g = 1.000, .b = 1.000, .a = 1.0 }; // selected notes
const color_key_white: Color = .{ .r = 0.860, .g = 0.890, .b = 0.940, .a = 1.0 };
const color_key_black: Color = .{ .r = 0.100, .g = 0.110, .b = 0.200, .a = 1.0 };
const color_ink_dark: Color = .{ .r = 0.040, .g = 0.040, .b = 0.100, .a = 1.0 };
const color_ink_light: Color = .{ .r = 0.910, .g = 0.930, .b = 0.950, .a = 1.0 };

// ---- State ------------------------------------------------------------------

const max_notes = 512;
const key_slots = 256;
const max_grid_lines = 4096;
/// Width of the labelled keyboard column at the left edge. The grid starts right of it.
pub const key_column_px: f32 = 56.0;
/// Width of a black key face in the keyboard column. White keys fill the column.
const key_black_width_px: f32 = 34.0;

/// Called when a keyboard key starts (down = 1) or stops (down = 0) a note.
pub const KeyCallback = *const fn (pitch: c_int, down: c_int, user_data: ?*anyopaque) callconv(.c) void;

/// Configuration passed to piano_roll_create. Layout of this struct is the C ABI.
pub const PianoRollConfig = extern struct {
    view_start_beat: f64,
    px_per_beat: f64,
    top_pitch: c_int,
    base_pitch: c_int,
    row_height: f32,
    grid_index: c_int,
    width: f32,
    height: f32,
    on_key: ?KeyCallback,
    user_data: ?*anyopaque,
};

/// A note as seen by C callers.
pub const NoteView = extern struct {
    pitch: c_int,
    start_beat: f64,
    length_beats: f64,
};

const Note = struct {
    pitch: i32,
    start_beat: f64,
    length_beats: f64,
    selected: bool = false,
};

/// Command kinds reported through EditCallback.
pub const edit_select_note: c_int = 0;
pub const edit_select_rect: c_int = 1;
pub const edit_move_selected: c_int = 2;
pub const edit_resize_selected: c_int = 3;
pub const edit_delete_selected: c_int = 4;
pub const edit_select_all: c_int = 5;

/// One selection or edit request. Field meanings depend on `kind`:
///   select_note:      pitch, start_beat, length_beats, selected, additive
///   select_rect:      pitch (lowest), pitch_high, start_beat, length_beats (span), additive
///   move_selected:    delta_beats, delta_pitch
///   resize_selected:  delta_beats (change in length)
///   delete_selected, select_all: no fields
/// additive = 0 means the other selections are cleared first.
pub const EditCommand = extern struct {
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

/// Called for every selection or edit gesture that completes.
pub const EditCallback = *const fn (command: *const EditCommand, user_data: ?*anyopaque) callconv(.c) void;

/// Kinds passed to a ChangeCallback.
pub const change_added: c_int = 0;
pub const change_removed: c_int = 1;

/// Called after a user pointer edit adds (kind 0) or removes (kind 1) a note.
/// Start and length are in beats, as stored in the widget.
pub const ChangeCallback = *const fn (kind: c_int, pitch: c_int, start_beat: f64, length_beats: f64, user_data: ?*anyopaque) callconv(.c) void;

/// Copy of one change event, used by the tests.
const ChangeRecord = struct {
    kind: c_int,
    pitch: c_int,
    start_beat: f64,
    length_beats: f64,
};

/// Widget state, heap-allocated per widget and freed by the destroy callback.
const State = struct {
    view_start_beat: f64,
    px_per_beat: f64,
    top_pitch: i32,
    row_height: f32,
    grid_index: i32,
    base_pitch: i32,
    on_key: ?KeyCallback,
    key_user_data: ?*anyopaque,
    on_change: ?ChangeCallback = null,
    change_user_data: ?*anyopaque = null,
    on_edit: ?EditCallback = null,
    edit_user_data: ?*anyopaque = null,
    gesture: Gesture = .{},
    notes: [max_notes]Note = undefined,
    note_count: usize = 0,
    /// Sounding pitch per RKey value, -1 when the key holds no note.
    /// Set to -1 with initHeld before use.
    held: [key_slots]i32 = undefined,
    /// Lit count per MIDI pitch: a key is drawn lit while the count is above zero.
    /// Each press or click adds one and each release removes one, so nested sources balance.
    lit: [128]u8 = @splat(0),
    /// Pitch of the keyboard key the pointer is holding, or -1.
    click_pitch: i32 = -1,
    /// Playback position in beats, or a negative value when the playhead is hidden.
    playhead_beat: f64 = -1,
    /// Widget width at the last paint, used to find the right edge when following.
    last_width: f32 = 640,
};

/// Pointer gesture between press and release. Coordinates are widget-local pixels.
const GestureKind = enum { none, move, resize, rect };

const Gesture = struct {
    kind: GestureKind = .none,
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,
    cur_x: f32 = 0,
    cur_y: f32 = 0,
    shift: bool = false,
    /// The note the press landed on (move and resize only).
    grab_pitch: i32 = 0,
    grab_start: f64 = 0,
    grab_length: f64 = 0,
    /// A release without a drag selects only the grabbed note (press on an already selected note).
    select_only_on_release: bool = false,
};

/// Beat, pitch and length change the active gesture applies to the selection.
const GestureDelta = struct { beat: f64 = 0, pitch: i32 = 0, length: f64 = 0 };

const NoteStorageError = error{NoteStorageFull};

fn gridStep(state: *const State) f64 {
    return pm.gridBeats(state.grid_index);
}

/// Folds an RKey letter (A..Z = 65..90) to the lowercase character piano_math expects.
fn toCharKey(key: i32) i32 {
    if (key >= 'A' and key <= 'Z') return key + ('a' - 'A');
    return key;
}

fn slotOf(key: i32) ?usize {
    if (key < 0 or key >= key_slots) return null;
    return @intCast(key);
}

/// Reports a pointer edit to the app. Only pointerDown calls this.
fn notifyChange(state: *const State, kind: c_int, note: Note) void {
    const callback = state.on_change orelse return;
    callback(kind, @intCast(note.pitch), note.start_beat, note.length_beats, state.change_user_data);
}

fn setOnChange(state: *State, callback: ?ChangeCallback, user_data: ?*anyopaque) void {
    state.on_change = callback;
    state.change_user_data = user_data;
}

fn notify(state: *const State, pitch: i32, down: bool) void {
    const callback = state.on_key orelse return;
    callback(@intCast(pitch), if (down) 1 else 0, state.key_user_data);
}

/// Adds (on) or removes (off) one lit count for `pitch`. Out-of-range pitches are ignored.
fn setLit(state: *State, pitch: i32, on: bool) void {
    if (pitch < pm.pitch_min or pitch > pm.pitch_max) return;
    const slot = &state.lit[@intCast(pitch)];
    slot.* = if (on) slot.* +| 1 else slot.* -| 1;
}

/// Pointer press on the keyboard column: lights the key and starts an audition note.
fn keyColumnDown(state: *State, local_y: f32) void {
    if (state.click_pitch >= 0) return;
    const pitch = pm.yToPitch(local_y, state.top_pitch, state.row_height);
    state.click_pitch = pitch;
    setLit(state, pitch, true);
    notify(state, pitch, true);
}

/// Releases the clicked key, if any. Returns true when a click was ended.
fn keyColumnUp(state: *State) bool {
    if (state.click_pitch < 0) return false;
    const pitch = state.click_pitch;
    state.click_pitch = -1;
    setLit(state, pitch, false);
    notify(state, pitch, false);
    return true;
}

/// Index of the note covering (pitch, beat), or null. Uses the unsnapped beat
/// so a click anywhere inside a note hits it.
fn noteAt(state: *const State, pitch: i32, beat: f64) ?usize {
    for (state.notes[0..state.note_count], 0..) |note, i| {
        if (note.pitch == pitch and beat >= note.start_beat and beat < note.start_beat + note.length_beats) {
            return i;
        }
    }
    return null;
}

fn appendNote(state: *State, note: Note) NoteStorageError!void {
    if (state.note_count >= max_notes) return error.NoteStorageFull;
    state.notes[state.note_count] = note;
    state.note_count += 1;
}

/// Swap-removes note `index`; order of the other notes is not kept.
fn removeNoteAt(state: *State, index: usize) void {
    state.note_count -= 1;
    state.notes[index] = state.notes[state.note_count];
}

/// Adds a one-grid-cell note at the snapped position of `raw_beat`.
fn addNoteAtPointer(state: *State, pitch: i32, raw_beat: f64) NoteStorageError!void {
    const step = gridStep(state);
    return appendNote(state, .{
        .pitch = pitch,
        .start_beat = pm.snapBeat(raw_beat, step),
        .length_beats = step,
    });
}

/// Sends one selection or edit command to the app.
fn emitEdit(state: *const State, command: EditCommand) void {
    const callback = state.on_edit orelse return;
    callback(&command, state.edit_user_data);
}

fn simpleCommand(kind: c_int) EditCommand {
    var command = std.mem.zeroes(EditCommand);
    command.kind = kind;
    return command;
}

fn selectNoteCommand(pitch: i32, start: f64, length: f64, additive: bool, selected: bool) EditCommand {
    var command = simpleCommand(edit_select_note);
    command.pitch = @intCast(pitch);
    command.start_beat = start;
    command.length_beats = length;
    command.additive = @intFromBool(additive);
    command.selected = @intFromBool(selected);
    return command;
}

/// Window rectangle of every note, using the geometry paintCallback draws.
fn noteRects(state: *const State, out: *[max_notes]edit.Rect) []const edit.Rect {
    for (state.notes[0..state.note_count], 0..) |note, i| {
        out[i] = .{
            .x = @floatCast(pm.beatToX(note.start_beat, state.view_start_beat, state.px_per_beat)),
            .y = pm.pitchToY(note.pitch, state.top_pitch, state.row_height),
            .w = @floatCast(pm.noteWidth(note.length_beats, state.px_per_beat)),
            .h = state.row_height,
        };
    }
    return out[0..state.note_count];
}

/// Topmost note under the widget-local point, and the zone it landed in.
fn hitNote(state: *const State, x: f32, y: f32) ?edit.Hit {
    var rects: [max_notes]edit.Rect = undefined;
    return edit.hitTest(noteRects(state, &rects), x, y);
}

/// Earliest start among the selected notes, or null when nothing is selected.
fn earliestSelectedStart(state: *const State) ?f64 {
    var earliest: ?f64 = null;
    for (state.notes[0..state.note_count]) |note| {
        if (!note.selected) continue;
        earliest = if (earliest) |e| @min(e, note.start_beat) else note.start_beat;
    }
    return earliest;
}

/// Clamps a pitch shift so that no selected note leaves the 0..127 range.
fn clampPitchDelta(state: *const State, delta: i32) i32 {
    var lowest: i32 = pm.pitch_max;
    var highest: i32 = pm.pitch_min;
    var has_selection = false;
    for (state.notes[0..state.note_count]) |note| {
        if (!note.selected) continue;
        has_selection = true;
        lowest = @min(lowest, note.pitch);
        highest = @max(highest, note.pitch);
    }
    if (!has_selection) return 0;
    return std.math.clamp(delta, pm.pitch_min - lowest, pm.pitch_max - highest);
}

/// Smallest note length the grid allows; a note is never shorter than this.
fn minNoteLength(state: *const State) f64 {
    const grid = gridStep(state);
    return if (grid > 0) grid else edit.min_free_length;
}

/// Change the active move or resize gesture applies to the selection, snapped to the grid.
fn gestureDelta(state: *const State) GestureDelta {
    const g = state.gesture;
    if (!(state.px_per_beat > 0)) return .{};
    const raw_beats = (@as(f64, g.cur_x) - @as(f64, g.anchor_x)) / state.px_per_beat;
    const grid = gridStep(state);
    switch (g.kind) {
        .move => {
            const earliest = earliestSelectedStart(state) orelse return .{};
            const pitch_raw = pm.yToPitch(g.cur_y, state.top_pitch, state.row_height) -
                pm.yToPitch(g.anchor_y, state.top_pitch, state.row_height);
            return .{
                .beat = edit.snapMoveDelta(earliest, raw_beats, grid),
                .pitch = clampPitchDelta(state, pitch_raw),
            };
        },
        .resize => {
            const new_length = edit.resizeLength(g.grab_start, g.grab_length, raw_beats, grid);
            return .{ .length = new_length - g.grab_length };
        },
        .none, .rect => return .{},
    }
}

/// `note` as drawn while a gesture is in progress: selected notes follow the gesture.
fn previewNote(state: *const State, note: Note, delta: GestureDelta) Note {
    if (!note.selected) return note;
    var shown = note;
    switch (state.gesture.kind) {
        .move => {
            shown.start_beat += delta.beat;
            shown.pitch += delta.pitch;
        },
        .resize => shown.length_beats = @max(note.length_beats + delta.length, minNoteLength(state)),
        .none, .rect => {},
    }
    return shown;
}

/// Applies a click to note `index`: shift toggles it, a plain click selects only it. Reports to the app.
fn applySelectionClick(state: *State, index: usize, shift: bool) void {
    const note = state.notes[index];
    const sel = edit.clickSelection(note.selected, shift);
    if (sel.clear_others) {
        for (state.notes[0..state.note_count]) |*other| other.selected = false;
    }
    state.notes[index].selected = sel.selected;
    emitEdit(state, selectNoteCommand(note.pitch, note.start_beat, note.length_beats, !sel.clear_others, sel.selected));
}

/// Rectangle selection command for the finished drag.
fn rectCommand(state: *const State, g: Gesture) EditCommand {
    const rect = edit.normalizeRect(g.anchor_x, g.anchor_y, g.cur_x, g.cur_y);
    const first = pm.yToPitch(rect.y, state.top_pitch, state.row_height);
    const last = pm.yToPitch(rect.y + rect.h, state.top_pitch, state.row_height);
    const start = pm.xToBeat(rect.x, state.view_start_beat, state.px_per_beat);
    const end = pm.xToBeat(rect.x + rect.w, state.view_start_beat, state.px_per_beat);
    var command = simpleCommand(edit_select_rect);
    command.pitch = @intCast(@min(first, last));
    command.pitch_high = @intCast(@max(first, last));
    command.start_beat = start;
    command.length_beats = end - start;
    command.additive = @intFromBool(g.shift);
    return command;
}

/// Ends the gesture on release and reports what it did to the app.
fn finishGesture(state: *State) void {
    const g = state.gesture;
    const delta = gestureDelta(state);
    state.gesture = .{};
    switch (g.kind) {
        .none => {},
        .move => {
            if (delta.beat != 0 or delta.pitch != 0) {
                var command = simpleCommand(edit_move_selected);
                command.delta_beats = delta.beat;
                command.delta_pitch = @intCast(delta.pitch);
                emitEdit(state, command);
            } else if (g.select_only_on_release) {
                emitEdit(state, selectNoteCommand(g.grab_pitch, g.grab_start, g.grab_length, false, true));
            }
        },
        .resize => {
            if (delta.length != 0) {
                var command = simpleCommand(edit_resize_selected);
                command.delta_beats = delta.length;
                emitEdit(state, command);
            }
        },
        .rect => emitEdit(state, rectCommand(state, g)),
    }
}

/// Delete and Backspace delete the selection; Ctrl+A selects all. Returns true when consumed.
fn editKey(state: *State, key: i32, modifiers: u32) bool {
    const shortcut_mods = pm.modifier_ctrl | pm.modifier_alt | pm.modifier_super;
    if (key == r_key_delete or key == r_key_backspace) {
        if ((modifiers & shortcut_mods) != 0) return false;
        emitEdit(state, simpleCommand(edit_delete_selected));
        return true;
    }
    if (key == r_key_a and (modifiers & shortcut_mods) == pm.modifier_ctrl) {
        emitEdit(state, simpleCommand(edit_select_all));
        return true;
    }
    return false;
}

/// Pointer press. Left press on a note selects it (shift toggles) and starts a
/// move, or a resize in the right-edge zone. Left press on empty grid starts a
/// rectangle selection; a double click there adds a note. Right press removes the
/// note under the pointer. Only single clicks start gestures. Returns true when
/// the event is consumed.
fn pointerDown(state: *State, local_x: f32, local_y: f32, button: c_int, clicks: c_int, shift: bool) bool {
    if (button != r_mouse_left and button != r_mouse_right) return false;
    const hit = hitNote(state, local_x, local_y);

    if (button == r_mouse_right) {
        if (clicks != 1) return true;
        if (hit) |h| {
            const removed = state.notes[h.index];
            removeNoteAt(state, h.index);
            notifyChange(state, change_removed, removed);
        }
        return true;
    }

    const pitch = pm.yToPitch(local_y, state.top_pitch, state.row_height);
    const beat = pm.xToBeat(local_x, state.view_start_beat, state.px_per_beat);
    if (clicks == 2) {
        if (hit == null) {
            addNoteAtPointer(state, pitch, beat) catch return false;
            notifyChange(state, change_added, state.notes[state.note_count - 1]);
        }
        return true;
    }
    if (clicks != 1) return true;

    const h = hit orelse {
        state.gesture = .{
            .kind = .rect,
            .anchor_x = local_x,
            .anchor_y = local_y,
            .cur_x = local_x,
            .cur_y = local_y,
            .shift = shift,
        };
        return true;
    };

    const note = state.notes[h.index];
    if (shift) {
        applySelectionClick(state, h.index, true);
        return true;
    }
    if (!note.selected) applySelectionClick(state, h.index, false);

    const resizing = h.zone == .right_edge;
    state.gesture = .{
        .kind = if (resizing) .resize else .move,
        .anchor_x = local_x,
        .anchor_y = local_y,
        .cur_x = local_x,
        .cur_y = local_y,
        .grab_pitch = note.pitch,
        .grab_start = note.start_beat,
        .grab_length = note.length_beats,
        .select_only_on_release = note.selected and !resizing,
    };
    return true;
}

/// Key press. Returns true when the key is consumed by the piano roll. With Ctrl,
/// Alt or Super held the key is left alone so shortcuts (Ctrl+Z, Ctrl+A) keep working.
fn keyPressed(state: *State, key: i32, modifiers: u32, repeat: bool) bool {
    if (!pm.keyboardPlayAllowed(modifiers)) return false;
    const char_key = toCharKey(key);
    if (char_key == 'z' or char_key == 'x') {
        if (!repeat) {
            const octaves: i32 = if (char_key == 'z') -1 else 1;
            state.base_pitch = pm.shiftOctave(state.base_pitch, octaves);
        }
        return true;
    }

    const pitch = pm.keyToPitch(char_key, state.base_pitch);
    if (pitch < 0) return false;
    const slot = slotOf(key) orelse return false;
    if (repeat or state.held[slot] >= 0) return true;

    state.held[slot] = pitch;
    setLit(state, pitch, true);
    notify(state, pitch, true);
    return true;
}

/// Key release. Returns true when the key was holding a note.
fn keyReleased(state: *State, key: i32) bool {
    const slot = slotOf(key) orelse return false;
    const pitch = state.held[slot];
    if (pitch < 0) return false;
    state.held[slot] = -1;
    setLit(state, pitch, false);
    notify(state, pitch, false);
    return true;
}

/// Marks every key slot as holding no note.
fn initHeld(state: *State) void {
    @memset(&state.held, -1);
}

/// Sends a note-off for every held key and ends any click audition.
fn releaseAllHeld(state: *State) void {
    for (&state.held) |*pitch| {
        if (pitch.* >= 0) {
            setLit(state, pitch.*, false);
            notify(state, pitch.*, false);
            pitch.* = -1;
        }
    }
    _ = keyColumnUp(state);
}

// ---- Raven callbacks --------------------------------------------------------

fn stateOf(user_data: ?*anyopaque) ?*State {
    const raw = user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn stateOfWidget(widget: Rid) ?*State {
    if (Rwidget_is_valid(widget) == r_false) return null;
    return stateOf(Rwidget_get_user_handle(widget));
}

/// Draws one key per pitch row: white keys fill the column, black keys are narrower
/// and sit on a dark strip. Every key shows its note name (left); a key that has a
/// computer-key letter also shows that letter (right). Sizes and positions come from
/// piano_math.keyLabelBox so both labels stay inside the key face.
fn paintKeyboard(state: *const State, painter: *RPainter, height: f32) void {
    const row_height = state.row_height;
    if (!(row_height > 0)) return;
    const face_h = row_height - 1;
    var pitch: i32 = pm.pitch_max;
    while (pitch >= pm.pitch_min) : (pitch -= 1) {
        const y = pm.pitchToY(pitch, state.top_pitch, row_height);
        if (y + row_height < 0 or y >= height) continue;
        const black = pm.isBlackKey(pitch);
        const lit = state.lit[@intCast(pitch)] > 0;
        const column_w = key_column_px - 1;
        if (black) Rdraw_rect(painter, 0, y, column_w, face_h, 0, color_deep.r, color_deep.g, color_deep.b, color_deep.a);
        const face_w: f32 = if (black) key_black_width_px else column_w;
        const fill = if (lit) color_neon_cyan else if (black) color_key_black else color_key_white;
        Rdraw_rect(painter, 0, y, face_w, face_h, 2, fill.r, fill.g, fill.b, fill.a);
        const box = pm.keyLabelBox(face_w, face_h) orelse continue;
        const ink = if (lit or !black) color_ink_dark else color_ink_light;
        const note = pm.noteName(pitch);
        Rdraw_text(painter, r_invalid_id, box.size, box.note_x, y + box.y, note.ptr, ink.r, ink.g, ink.b, ink.a);
        if (pm.keyLetterFor(state.base_pitch, pitch)) |letter| {
            var text: [2:0]u8 = .{ letter, 0 };
            Rdraw_text(painter, r_invalid_id, box.size, box.letter_x, y + box.y, &text, ink.r, ink.g, ink.b, ink.a);
        }
    }
}

fn paintCallback(widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;
    state.last_width = width;
    // Grid geometry is in grid space; `ox` moves it right of the keyboard column.
    const ox = key_column_px;
    const grid_width = @max(width - ox, 0);

    Rdraw_rect(painter, 0, 0, width, height, 0, color_deep.r, color_deep.g, color_deep.b, color_deep.a);

    // Pitch rows: one per MIDI pitch, black-key rows drawn on the panel colour.
    const row_height = state.row_height;
    if (row_height > 0) {
        var pitch: i32 = pm.pitch_max;
        while (pitch >= pm.pitch_min) : (pitch -= 1) {
            const y = pm.pitchToY(pitch, state.top_pitch, row_height);
            if (y + row_height < 0 or y >= height) continue;
            const row = if (pm.isBlackKey(pitch)) color_deep else color_panel;
            Rdraw_rect(painter, ox, y, grid_width, row_height, 0, row.r, row.g, row.b, row.a);
        }
    }

    // Vertical grid lines; bars (every 4 beats) are drawn brighter. Skipped
    // when the grid is narrower than 2 px, where lines would only blur.
    const grid = gridStep(state);
    const px_per_beat = state.px_per_beat;
    if (grid > 0 and px_per_beat > 0 and grid * px_per_beat >= 2) {
        var index: f64 = @floor(state.view_start_beat / grid);
        for (0..max_grid_lines) |_| {
            const beat = index * grid;
            const x = pm.beatToX(beat, state.view_start_beat, px_per_beat);
            if (!(x <= grid_width)) break; // also stops on NaN
            if (x >= 0) {
                const line = if (@mod(beat, 4.0) == 0) color_violet else color_muted;
                const alpha: f32 = if (@mod(beat, 4.0) == 0) 0.5 else 0.25;
                const xf: f32 = @as(f32, @floatCast(x)) + ox;
                Rdraw_line(painter, xf, 0, xf, height, 1, line.r, line.g, line.b, alpha);
            }
            index += 1;
        }
    }

    // Notes, culled against the widget bounds. Selected notes are drawn white and
    // follow an active move or resize gesture.
    const note_height = @max(row_height - 2, 1);
    const delta = gestureDelta(state);
    for (state.notes[0..state.note_count]) |stored| {
        const note = previewNote(state, stored, delta);
        const y = pm.pitchToY(note.pitch, state.top_pitch, row_height);
        if (y + row_height < 0 or y >= height) continue;
        const x = @as(f32, @floatCast(pm.beatToX(note.start_beat, state.view_start_beat, px_per_beat))) + ox;
        const w: f32 = @floatCast(pm.noteWidth(note.length_beats, px_per_beat));
        if (x + w < ox or x >= width) continue;
        const color = if (note.selected) color_selected else color_neon_cyan;
        Rdraw_rect(painter, x, y + 1, w, note_height, 2, color.r, color.g, color.b, color.a);
    }

    // Rectangle selection while the pointer drags on empty grid.
    if (state.gesture.kind == .rect) {
        const g = state.gesture;
        const rect = edit.normalizeRect(g.anchor_x, g.anchor_y, g.cur_x, g.cur_y);
        Rdraw_rect(painter, rect.x + ox, rect.y, rect.w, rect.h, 0, color_neon_cyan.r, color_neon_cyan.g, color_neon_cyan.b, 0.15);
    }

    // Playhead: one line, only when it falls inside the visible grid.
    if (state.playhead_beat >= 0 and px_per_beat > 0) {
        const px = pm.beatToX(state.playhead_beat, state.view_start_beat, px_per_beat);
        if (px >= 0 and px <= grid_width) {
            const xf: f32 = @as(f32, @floatCast(px)) + ox;
            Rdraw_line(painter, xf, 0, xf, height, 2, color_neon_cyan.r, color_neon_cyan.g, color_neon_cyan.b, 0.9);
        }
    }

    // Labelled keyboard last, so it sits above any note that scrolls under it.
    paintKeyboard(state, painter, height);
}

fn handleEvent(widget: Rid, event: *const REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const state = stateOf(user_data) orelse return r_false;
    // Event coordinates are widget-local; the grid starts right of the keyboard column.
    const ox = key_column_px;

    if (event.type == r_event_mouse_down) {
        if (event.local_x < ox) {
            if (event.button != r_mouse_left) return r_false;
            keyColumnDown(state, event.local_y);
            Rwidget_invalidate(widget);
            return r_true;
        }
        if (event.button == r_mouse_left) Rwidget_focus(widget);
        const shift = (event.modifiers & r_mod_shift) != 0;
        const handled = pointerDown(state, event.local_x - ox, event.local_y, event.button, event.clicks, shift);
        if (!handled) return r_false;
        Rwidget_invalidate(widget);
        return r_true;
    }
    if (event.type == r_event_mouse_move) {
        if (state.gesture.kind == .none) return r_false;
        state.gesture.cur_x = event.local_x - ox;
        state.gesture.cur_y = event.local_y;
        Rwidget_invalidate(widget);
        return r_true;
    }
    if (event.type == r_event_mouse_up) {
        if (event.button == r_mouse_left and keyColumnUp(state)) {
            Rwidget_invalidate(widget);
            return r_true;
        }
        if (event.button != r_mouse_left or state.gesture.kind == .none) return r_false;
        finishGesture(state);
        Rwidget_invalidate(widget);
        return r_true;
    }
    if (event.type == r_event_key_down) {
        if (editKey(state, event.key, event.modifiers)) {
            Rwidget_invalidate(widget);
            return r_true;
        }
        const handled = keyPressed(state, event.key, event.modifiers, event.repeat != 0);
        return if (handled) r_true else r_false;
    }
    if (event.type == r_event_key_up) {
        return if (keyReleased(state, event.key)) r_true else r_false;
    }
    if (event.type == r_event_focus_lost) {
        state.gesture = .{};
        releaseAllHeld(state);
        return r_false;
    }
    return r_false;
}

fn destroyCallback(widget: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;
    releaseAllHeld(state);
    std.heap.c_allocator.destroy(state);
}

// ---- C-ABI exports ----------------------------------------------------------

/// Sets the callback for user pointer edits. A NULL callback clears it. An
/// invalid widget is ignored.
pub export fn piano_roll_set_on_change(widget: Rid, callback: ?ChangeCallback, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    setOnChange(state, callback, user_data);
}

/// Creates a piano roll widget. Returns R_INVALID_ID on failure.
pub export fn piano_roll_create(config: *const PianoRollConfig) callconv(.c) Rid {
    const state = std.heap.c_allocator.create(State) catch return r_invalid_id;
    state.* = .{
        .view_start_beat = config.view_start_beat,
        .px_per_beat = config.px_per_beat,
        .top_pitch = config.top_pitch,
        .row_height = config.row_height,
        .grid_index = config.grid_index,
        .base_pitch = config.base_pitch,
        .on_key = config.on_key,
        .key_user_data = config.user_data,
    };
    initHeld(state);

    const widget = Rwidget_create(r_widget_custom);
    if (Rwidget_is_valid(widget) == r_false) {
        std.heap.c_allocator.destroy(state);
        return r_invalid_id;
    }
    Rwidget_set_size(widget, config.width, config.height);
    Rwidget_set_focusable(widget, r_true);
    Rwidget_set_user_handle(widget, state);
    Rcustom_set_paint_callback(widget, paintCallback, state);
    Rwidget_set_event_callback(widget, handleEvent, state);
    Rwidget_set_destroy_callback(widget, destroyCallback, state);
    return widget;
}

/// Sets the visible window: first beat, zoom, top pitch row and row height.
pub export fn piano_roll_set_view(widget: Rid, view_start_beat: f64, px_per_beat: f64, top_pitch: c_int, row_height: f32) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    state.view_start_beat = view_start_beat;
    state.px_per_beat = px_per_beat;
    state.top_pitch = top_pitch;
    state.row_height = row_height;
    Rwidget_invalidate(widget);
}

/// Sets the playhead (beats; negative hides it). With `follow` set the view scrolls so a playhead
/// past the right edge (or before the left edge) comes back into view.
pub export fn piano_roll_set_playhead(widget: Rid, beat: f64, follow: c_int) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    if (!(beat >= 0)) {
        if (state.playhead_beat < 0) return;
        state.playhead_beat = -1;
        Rwidget_invalidate(widget);
        return;
    }
    if (follow != 0 and state.px_per_beat > 0) {
        const visible = @max(@as(f64, state.last_width) - key_column_px, 0) / state.px_per_beat;
        const margin = @min(1.0, visible * 0.1);
        if (visible > 2 and (beat > state.view_start_beat + visible - margin or beat < state.view_start_beat)) {
            state.view_start_beat = @max(beat - margin, 0);
        }
    }
    if (state.playhead_beat == beat) return;
    state.playhead_beat = beat;
    Rwidget_invalidate(widget);
}

/// Sets the grid menu index (0 = 1/4, 1 = 1/8, 2 = 1/16, 3 = 1/32).
pub export fn piano_roll_set_grid(widget: Rid, index: c_int) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    state.grid_index = index;
    Rwidget_invalidate(widget);
}

/// Sets the pitch the QWERTY keys play from; clamped to 0..127.
pub export fn piano_roll_set_base_pitch(widget: Rid, pitch: c_int) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    state.base_pitch = pm.clampPitch64(pitch);
}

/// Number of notes stored in the widget; 0 for an invalid widget.
pub export fn piano_roll_note_count(widget: Rid) callconv(.c) u32 {
    const state = stateOfWidget(widget) orelse return 0;
    return @intCast(state.note_count);
}

/// Copies note `index` into `out`. Returns R_FALSE when the index is out of range.
pub export fn piano_roll_get_note(widget: Rid, index: u32, out: *NoteView) callconv(.c) c_int {
    const state = stateOfWidget(widget) orelse return r_false;
    if (index >= state.note_count) return r_false;
    const note = state.notes[index];
    out.* = .{
        .pitch = @intCast(note.pitch),
        .start_beat = note.start_beat,
        .length_beats = note.length_beats,
    };
    return r_true;
}

/// Sets the callback for selection and edit gestures. A NULL callback clears it.
/// An invalid widget is ignored.
pub export fn piano_roll_set_on_edit(widget: Rid, callback: ?EditCallback, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    state.on_edit = callback;
    state.edit_user_data = user_data;
}

/// Adds a note with an explicit position and selection flag (selected != 0). Returns R_FALSE for an invalid
/// widget, a pitch outside 0..127, a negative or non-finite start, a
/// non-positive or non-finite length, or a full note store.
pub export fn piano_roll_add_note(widget: Rid, pitch: c_int, start_beat: f64, length_beats: f64, selected: c_int) callconv(.c) c_int {
    const state = stateOfWidget(widget) orelse return r_false;
    if (pitch < pm.pitch_min or pitch > pm.pitch_max) return r_false;
    if (!(start_beat >= 0) or !std.math.isFinite(start_beat)) return r_false;
    if (!(length_beats > 0) or !std.math.isFinite(length_beats)) return r_false;
    appendNote(state, .{
        .pitch = pitch,
        .start_beat = start_beat,
        .length_beats = length_beats,
        .selected = selected != 0,
    }) catch return r_false;
    Rwidget_invalidate(widget);
    return r_true;
}

/// Removes every note from the widget.
pub export fn piano_roll_clear_notes(widget: Rid) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    state.note_count = 0;
    Rwidget_invalidate(widget);
}

/// Lights (lit != 0) or releases (lit == 0) a key on the labelled keyboard for a note the
/// app plays itself. Calls nest: every lit != 0 needs one matching lit == 0.
pub export fn piano_roll_set_key_lit(widget: Rid, pitch: c_int, lit: c_int) callconv(.c) void {
    const state = stateOfWidget(widget) orelse return;
    setLit(state, pitch, lit != 0);
    Rwidget_invalidate(widget);
}

// ---- Tests (pure state logic; no Raven calls) -------------------------------

fn defaultState() State {
    var state: State = .{
        .view_start_beat = 0,
        .px_per_beat = 40,
        .top_pitch = 84,
        .row_height = 12,
        .grid_index = 1,
        .base_pitch = 60,
        .on_key = null,
        .key_user_data = null,
    };
    initHeld(&state);
    return state;
}

test "toCharKey folds uppercase letters and keeps other keys" {
    try std.testing.expectEqual(@as(i32, 'a'), toCharKey('A'));
    try std.testing.expectEqual(@as(i32, 'z'), toCharKey('Z'));
    try std.testing.expectEqual(@as(i32, ';'), toCharKey(';'));
    try std.testing.expectEqual(@as(i32, '1'), toCharKey('1'));
}

test "addNoteAtPointer snaps to the grid and noteAt uses the raw beat" {
    var state = defaultState();
    try addNoteAtPointer(&state, 60, 1.3); // grid index 1 = 1/8 = 0.5 beats
    try std.testing.expectEqual(@as(usize, 1), state.note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.notes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.notes[0].length_beats, 1e-9);
    // Hit test uses the unsnapped beat, so 1.9 is inside the note [1.5, 2.0).
    try std.testing.expectEqual(@as(?usize, 0), noteAt(&state, 60, 1.9));
    try std.testing.expectEqual(@as(?usize, null), noteAt(&state, 60, 2.0));
    try std.testing.expectEqual(@as(?usize, null), noteAt(&state, 61, 1.6));
}

test "appendNote reports a full note store" {
    var state = defaultState();
    for (0..max_notes) |_| try appendNote(&state, .{ .pitch = 60, .start_beat = 0, .length_beats = 1 });
    try std.testing.expectError(error.NoteStorageFull, appendNote(&state, .{ .pitch = 60, .start_beat = 0, .length_beats = 1 }));
    try std.testing.expectEqual(@as(usize, max_notes), state.note_count);
}

test "removeNoteAt keeps every other note" {
    var state = defaultState();
    try appendNote(&state, .{ .pitch = 60, .start_beat = 0, .length_beats = 1 });
    try appendNote(&state, .{ .pitch = 62, .start_beat = 1, .length_beats = 1 });
    try appendNote(&state, .{ .pitch = 64, .start_beat = 2, .length_beats = 1 });
    removeNoteAt(&state, 0);
    try std.testing.expectEqual(@as(usize, 2), state.note_count);
    try std.testing.expectEqual(@as(i32, 64), state.notes[0].pitch);
    try std.testing.expectEqual(@as(i32, 62), state.notes[1].pitch);
}

test "pointerDown: double click adds, right click removes, single press on empty grid adds nothing" {
    var state = defaultState();
    // Row 0 is the top pitch 84; x = 0 is the view start.
    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_left, 2, false));
    try std.testing.expectEqual(@as(usize, 1), state.note_count);
    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_right, 1, false));
    try std.testing.expectEqual(@as(usize, 0), state.note_count);

    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_left, 1, false));
    try std.testing.expectEqual(@as(usize, 0), state.note_count);
    try std.testing.expectEqual(GestureKind.rect, state.gesture.kind);
    state.gesture = .{};

    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_left, 3, false));
    try std.testing.expectEqual(@as(usize, 0), state.note_count);
}

test "pointerDown ignores middle button" {
    var state = defaultState();
    try std.testing.expect(!pointerDown(&state, 0.0, 0.0, 2, 1, false));
    try std.testing.expectEqual(@as(usize, 0), state.note_count);
}

test "pointerDown: press on a note selects it; shift toggles; press on empty grid starts rect" {
    var state = defaultState();
    try appendNote(&state, .{ .pitch = 84, .start_beat = 0, .length_beats = 1 });
    try appendNote(&state, .{ .pitch = 84, .start_beat = 2, .length_beats = 1 });

    // Press on the first note (x 0..40, row 0): it becomes the only selection, and a move starts.
    try std.testing.expect(pointerDown(&state, 10.0, 5.0, r_mouse_left, 1, false));
    try std.testing.expect(state.notes[0].selected);
    try std.testing.expect(!state.notes[1].selected);
    try std.testing.expectEqual(GestureKind.move, state.gesture.kind);
    state.gesture = .{};

    // Shift-press on the second note (x 80..120) adds it to the selection.
    try std.testing.expect(pointerDown(&state, 90.0, 5.0, r_mouse_left, 1, true));
    try std.testing.expect(state.notes[0].selected);
    try std.testing.expect(state.notes[1].selected);
    try std.testing.expectEqual(GestureKind.none, state.gesture.kind);

    // Press on empty grid (x 200) with no shift starts a rectangle.
    try std.testing.expect(pointerDown(&state, 200.0, 5.0, r_mouse_left, 1, false));
    try std.testing.expectEqual(GestureKind.rect, state.gesture.kind);
}

test "pointerDown: press on a selected note with no drag selects only that note on release" {
    var state = defaultState();
    try appendNote(&state, .{ .pitch = 84, .start_beat = 0, .length_beats = 1, .selected = true });
    try appendNote(&state, .{ .pitch = 84, .start_beat = 2, .length_beats = 1, .selected = true });
    test_edits_count = 0;
    state.on_edit = recordEdit;

    try std.testing.expect(pointerDown(&state, 10.0, 5.0, r_mouse_left, 1, false));
    // Both stay selected while the press is held, so a drag can move them together.
    try std.testing.expect(state.notes[1].selected);
    finishGesture(&state);
    try std.testing.expectEqual(@as(usize, 1), test_edits_count);
    try std.testing.expectEqual(edit_select_note, test_edits[0].kind);
    try std.testing.expectEqual(@as(c_int, 0), test_edits[0].additive);
}

test "rectangle drag reports the beat and pitch span as a select_rect command" {
    var state = defaultState();
    state.on_edit = recordEdit;
    test_edits_count = 0;
    // Drag from (40, 0) to (120, 24): beats 1..3, pitch rows 84 and 82.
    try std.testing.expect(pointerDown(&state, 40.0, 0.0, r_mouse_left, 1, false));
    state.gesture.cur_x = 120.0;
    state.gesture.cur_y = 24.0;
    finishGesture(&state);
    try std.testing.expectEqual(@as(usize, 1), test_edits_count);
    const cmd = test_edits[0];
    try std.testing.expectEqual(edit_select_rect, cmd.kind);
    try std.testing.expectEqual(@as(c_int, 82), cmd.pitch);
    try std.testing.expectEqual(@as(c_int, 84), cmd.pitch_high);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cmd.start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cmd.length_beats, 1e-9);
    try std.testing.expectEqual(@as(c_int, 0), cmd.additive);
}

test "Delete, Backspace and Ctrl+A report edit commands; Ctrl+Delete is not consumed" {
    var state = defaultState();
    state.on_edit = recordEdit;
    test_edits_count = 0;
    const r_mod_ctrl: u32 = 1 << 1;
    try std.testing.expect(editKey(&state, r_key_delete, 0));
    try std.testing.expect(editKey(&state, r_key_backspace, 0));
    try std.testing.expect(editKey(&state, r_key_a, r_mod_ctrl));
    try std.testing.expect(!editKey(&state, r_key_delete, r_mod_ctrl));
    try std.testing.expect(!editKey(&state, r_key_a, 0));
    try std.testing.expectEqual(@as(usize, 3), test_edits_count);
    try std.testing.expectEqual(edit_delete_selected, test_edits[0].kind);
    try std.testing.expectEqual(edit_delete_selected, test_edits[1].kind);
    try std.testing.expectEqual(edit_select_all, test_edits[2].kind);
}

test "keyPressed plays a note once and keyReleased sends the matching off" {
    var state = defaultState();
    try std.testing.expect(keyPressed(&state, 'A', 0, false)); // RKey A folds to 'a' = pitch 60
    const slot: usize = 'A';
    try std.testing.expectEqual(@as(i32, 60), state.held[slot]);
    try std.testing.expect(keyPressed(&state, 'A', 0, true)); // auto-repeat: consumed, no retrigger
    try std.testing.expect(keyReleased(&state, 'A'));
    try std.testing.expectEqual(@as(i32, -1), state.held[slot]);
    try std.testing.expect(!keyReleased(&state, 'A'));
}

test "keyPressed z and x shift the base octave; unmapped keys pass through" {
    var state = defaultState();
    try std.testing.expect(keyPressed(&state, 'X', 0, false));
    try std.testing.expectEqual(@as(i32, 72), state.base_pitch);
    try std.testing.expect(keyPressed(&state, 'Z', 0, false));
    try std.testing.expect(keyPressed(&state, 'Z', 0, false));
    try std.testing.expectEqual(@as(i32, 48), state.base_pitch);
    try std.testing.expect(!keyPressed(&state, 'Q', 0, false));
}

test "keyPressed with Ctrl held neither shifts the octave nor plays a note" {
    const r_mod_ctrl: u32 = 1 << 1; // RModifier R_MOD_CTRL
    var state = defaultState();
    try std.testing.expect(!keyPressed(&state, 'Z', r_mod_ctrl, false)); // Ctrl+Z: not consumed
    try std.testing.expectEqual(@as(i32, 60), state.base_pitch);
    try std.testing.expect(!keyPressed(&state, 'A', r_mod_ctrl, false)); // Ctrl+A: not a note
    try std.testing.expectEqual(@as(i32, -1), state.held['A']);
}

var test_note_offs: usize = 0;

fn countNoteOffs(pitch: c_int, down: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = pitch;
    _ = user_data;
    if (down == 0) test_note_offs += 1;
}

var test_changes: [8]ChangeRecord = undefined;
var test_change_count: usize = 0;

var test_edits: [8]EditCommand = undefined;
var test_edits_count: usize = 0;

fn recordEdit(command: *const EditCommand, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (test_edits_count >= test_edits.len) return;
    test_edits[test_edits_count] = command.*;
    test_edits_count += 1;
}

fn recordChange(kind: c_int, pitch: c_int, start_beat: f64, length_beats: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (test_change_count >= test_changes.len) return;
    test_changes[test_change_count] = .{ .kind = kind, .pitch = pitch, .start_beat = start_beat, .length_beats = length_beats };
    test_change_count += 1;
}

test "pointer add and remove fire on-change with the snapped note; API edits fire nothing" {
    var state = defaultState();
    state.on_change = recordChange;
    test_change_count = 0;

    // Double click at beat 1.7 (x = 68 px at 40 px/beat) with the 1/8 grid (0.5 beats):
    // one "added" event at 1.5.
    try std.testing.expect(pointerDown(&state, 68.0, 0.0, r_mouse_left, 2, false));
    try std.testing.expectEqual(@as(usize, 1), test_change_count);
    try std.testing.expectEqual(@as(c_int, change_added), test_changes[0].kind);
    try std.testing.expectEqual(@as(c_int, 84), test_changes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), test_changes[0].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), test_changes[0].length_beats, 1e-9);

    // Right click on that note: one "removed" event with the same values.
    try std.testing.expect(pointerDown(&state, 68.0, 0.0, r_mouse_right, 1, false));
    try std.testing.expectEqual(@as(usize, 2), test_change_count);
    try std.testing.expectEqual(@as(c_int, change_removed), test_changes[1].kind);
    try std.testing.expectEqual(@as(c_int, 84), test_changes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), test_changes[1].start_beat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), test_changes[1].length_beats, 1e-9);

    // A single left press on empty grid starts a selection and fires nothing.
    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_left, 1, false));
    try std.testing.expectEqual(@as(usize, 2), test_change_count);
    state.gesture = .{};

    // Clearing the callback stops events.
    setOnChange(&state, null, null);
    try std.testing.expect(pointerDown(&state, 0.0, 0.0, r_mouse_left, 2, false));
    try std.testing.expectEqual(@as(usize, 2), test_change_count);
}

test "programmatic adds and clears never fire on-change" {
    var state = defaultState();
    state.on_change = recordChange;
    test_change_count = 0;
    // piano_roll_add_note and piano_roll_clear_notes both call appendNote or
    // reset note_count directly, so only pointerDown may notify.
    try appendNote(&state, .{ .pitch = 60, .start_beat = 0, .length_beats = 1 });
    state.note_count = 0;
    try std.testing.expectEqual(@as(usize, 0), test_change_count);
}

test "releaseAllHeld sends one note-off per held key" {
    test_note_offs = 0;
    var state = defaultState();
    state.on_key = countNoteOffs;
    try std.testing.expect(keyPressed(&state, 'A', 0, false));
    try std.testing.expect(keyPressed(&state, 'S', 0, false));
    releaseAllHeld(&state);
    try std.testing.expectEqual(@as(usize, 2), test_note_offs);
    releaseAllHeld(&state);
    try std.testing.expectEqual(@as(usize, 2), test_note_offs);
}
