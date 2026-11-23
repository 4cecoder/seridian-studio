// Translated to Zig from vendor/raven/src/widgets/text_editor.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/text_editor.c
// TextEditor: multi-line text editing.
//
// The text is an array of lines, each one a small UTF-8 buffer: inserting or
// deleting touches one line (and moves pointers when lines are added), which
// stays fast for texts of tens of thousands of lines.
//
// A position is (line, column), the column being a byte offset in the line.
// With word wrap a line is shown on several rows; the places where it is cut
// are computed once per line and per width, and kept until the line changes.
// Only the rows that are visible are measured, colored and painted.
//
// Every change goes through one function, rvn_ed_replace, which also records
// what is needed to undo it.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const context_h = @import("../core/context_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const R_TRUE = raven.R_TRUE;
const R_FALSE = raven.R_FALSE;
const R_INVALID_ID = raven.R_INVALID_ID;
const Rid = raven.Rid;

const RVN_ED_PAD_X: f32 = 8.0;
const RVN_ED_PAD_Y: f32 = 6.0;
const RVN_ED_MAX_SPANS = 192;
/// Characters typed in a row are undone together, up to this many.
const RVN_ED_TYPING_GROUP = 48;
const RVN_ED_MAX_UNDO = 512;

const rvn_ed_pos_t = extern struct {
    line: c_int,
    column: c_int,
};

const rvn_ed_line_t = extern struct {
    text: [*c]u8,
    length: c_int,
    cap: c_int,
    /// Width of the line on one row, or a negative value when it is not known.
    width: f32,
    /// Word wrap: number of rows (0 = not computed) and where the rows after the first begin.
    row_count: c_int,
    breaks: [*c]c_int,
    /// What the lexer is in at the start of the line (syntax colors).
    lex_in: u8,
};

/// A part of a line underlined with a message (Rtext_editor_add_marker).
const rvn_ed_marker_t = extern struct {
    line: c_int,
    from: c_int,
    /// Negative: to the end of the line.
    to: c_int,
    kind: raven.RMarkerKind,
    message: [*c]u8,
};

/// One step of the history: `removed` was replaced by `inserted` at `start`.
const rvn_ed_edit_t = extern struct {
    start: rvn_ed_pos_t,
    removed: [*c]u8,
    removed_length: c_int,
    inserted: [*c]u8,
    inserted_length: c_int,
    caret_before: rvn_ed_pos_t,
    anchor_before: rvn_ed_pos_t,
    caret_after: rvn_ed_pos_t,
    /// A run of typed characters that the next one may join.
    typing: c_int,
};

const rvn_text_editor_t = extern struct {
    base: widget_h.rvn_widget_t,
    lines: [*c]rvn_ed_line_t,
    line_count: u32,
    line_cap: u32,

    /// The selection is the range between the two; the caret is where typing goes.
    caret: rvn_ed_pos_t,
    anchor: rvn_ed_pos_t,
    /// Horizontal position kept while moving up and down; negative = take it from the caret.
    goal_x: f32,

    read_only: c_int,
    wrap: c_int,
    line_numbers: c_int,
    tab_size: c_int,
    tab_spaces: c_int,
    /// Name of the language, or NULL; what it was found to be, and when it was looked for.
    language_name: [*c]u8,
    language: ?*const common.rvn_language_t,
    language_generation: u32,
    no_pairs: c_int,
    no_completion: c_int,
    /// Counts the changes of the text: what was computed for a version is forgotten with it.
    version: u32,
    /// The bracket next to the caret and the one that closes it, found for (match_version, match_caret).
    match_version: u32,
    match_caret: rvn_ed_pos_t,
    match_found: c_int,
    match_a: rvn_ed_pos_t,
    match_b: rvn_ed_pos_t,
    /// Parts of the text underlined with a message.
    markers: [*c]rvn_ed_marker_t,
    marker_count: u32,
    marker_cap: u32,
    /// The tooltip of the widget is the message of a marker.
    marker_tip: c_int,
    /// The list of proposals (a popup of the window), created on first use.
    complete: [*c]widget_h.rvn_widget_t,
    completion_callback: raven.RCompletionCallback,
    completion_user: ?*anyopaque,
    font: Rid,
    font_size: f32,
    /// Zoom of the text, a factor of the font size (0: 1). Ctrl + wheel, Ctrl + '+' / '-' / 0.
    zoom: f32,
    no_zoom: c_int,
    zoom_callback: raven.RTextEditorZoomCallback,
    zoom_user: ?*anyopaque,
    placeholder: [*c]u8,

    vbar: common.rvn_scrollbar_t,
    hbar: common.rvn_scrollbar_t,
    /// Word wrap: width the rows were cut for, and the first row of each line.
    wrap_width: f32,
    row_starts: [*c]u32,
    row_starts_cap: u32,
    total_rows: u32,
    rows_dirty: c_int,
    /// Without word wrap: width of the longest line.
    max_width: f32,
    /// Lines whose lex_in is up to date (always a prefix of the text).
    lex_valid: u32,
    /// The caret must be scrolled into view at the next layout.
    reveal_pending: c_int,

    undo: [*c]rvn_ed_edit_t,
    undo_count: u32,
    undo_cap: u32,
    redo: [*c]rvn_ed_edit_t,
    redo_count: u32,
    redo_cap: u32,

    selecting: c_int,
    blink_timer: Rid,
    blink_start: f64,
    /// Where the caret is drawn, in the coordinates of the text: it glides to its place.
    caret_x: raven.RSpring,
    caret_y: raven.RSpring,

    /// Results of Rtext_editor_get_text / get_selected_text.
    text_cache: [*c]u8,
    text_cache_length: c_int,
    text_cache_valid: c_int,
    selection_cache: [*c]u8,

    callback: raven.RTextEditorChangedCallback,
    user_data: ?*anyopaque,
};

/// What is needed to measure and place text, computed once per function.
const rvn_ed_metrics_t = extern struct {
    font: ?*font_h.rvn_font_t,
    font_id: Rid,
    size: f32,
    line_height: f32,
    space: f32,
    tab: f32,
    /// Width of the margin of the line numbers, 0 without it.
    gutter: f32,
    /// Where the text is drawn, in the widget.
    area: base.rvn_rect_t,
    bar: f32,
    /// Theme of the editor: the colors of the code come from it.
    theme: [*c]const context_h.rvn_theme_t,
    /// The bold and the italic of the font, for formatted text; the font itself otherwise.
    bold_id: Rid,
    italic_id: Rid,
};

// C library helpers with the C signatures' meaning (memcpy, memmove, memset on byte counts).
inline fn cmemcpy(dst: anytype, src: anytype, n: usize) void {
    _ = libc.memcpy(dst, src, n);
}
inline fn cmemmove(dst: anytype, src: anytype, n: usize) void {
    _ = libc.memmove(dst, src, n);
}
inline fn cmemset(dst: anytype, value: c_int, n: usize) void {
    _ = libc.memset(dst, value, n);
}
inline fn ccast(comptime T: type, p: anytype) T {
    return @ptrCast(@alignCast(p));
}

// ---------------------------------------------------------------------------
//  Positions
// -------------------------------------------------------------------------

fn rvn_ed_pos(line: c_int, column: c_int) rvn_ed_pos_t {
    return .{ .line = line, .column = column };
}

fn rvn_ed_pos_cmp(a: rvn_ed_pos_t, b: rvn_ed_pos_t) c_int {
    if (a.line != b.line) return if (a.line < b.line) -1 else 1;
    if (a.column != b.column) return if (a.column < b.column) -1 else 1;
    return 0;
}

fn rvn_ed_clamp(ed: [*c]const rvn_text_editor_t, pos_in: rvn_ed_pos_t) rvn_ed_pos_t {
    var pos = pos_in;
    pos.line = base.rvn_clampi(pos.line, 0, @as(c_int, @intCast(ed.*.line_count)) - 1);
    pos.column = base.rvn_clampi(pos.column, 0, ed.*.lines[@intCast(pos.line)].length);
    // never inside a character
    while (pos.column > 0 and pos.column < ed.*.lines[@intCast(pos.line)].length and
        (@as(u8, @intCast(ed.*.lines[@intCast(pos.line)].text[@intCast(pos.column)])) & 0xC0) == 0x80) pos.column -= 1;
    return pos;
}

fn rvn_ed_sel_min(ed: [*c]const rvn_text_editor_t) rvn_ed_pos_t {
    return if (rvn_ed_pos_cmp(ed.*.caret, ed.*.anchor) <= 0) ed.*.caret else ed.*.anchor;
}

fn rvn_ed_sel_max(ed: [*c]const rvn_text_editor_t) rvn_ed_pos_t {
    return if (rvn_ed_pos_cmp(ed.*.caret, ed.*.anchor) <= 0) ed.*.anchor else ed.*.caret;
}

fn rvn_ed_has_selection(ed: [*c]const rvn_text_editor_t) c_int {
    return @intFromBool(rvn_ed_pos_cmp(ed.*.caret, ed.*.anchor) != 0);
}

fn rvn_ed_end(ed: [*c]const rvn_text_editor_t) rvn_ed_pos_t {
    return rvn_ed_pos(@as(c_int, @intCast(ed.*.line_count)) - 1, ed.*.lines[ed.*.line_count - 1].length);
}

/// Position reached after inserting `text` at `start` (carriage returns before a line break are dropped, as rvn_ed_replace does).
fn rvn_ed_pos_after(start_in: rvn_ed_pos_t, text: [*c]const u8, length: c_int) rvn_ed_pos_t {
    var start = start_in;
    var i: c_int = 0;
    var begin: c_int = 0;
    while (i <= length) : (i += 1) {
        if (i == length or text[@intCast(i)] == '\n') {
            var piece = i - begin;
            while (piece > 0 and text[@intCast(begin + piece - 1)] == '\r') piece -= 1;
            start.column += piece;
            if (i < length) {
                start.line += 1;
                start.column = 0;
            }
            begin = i + 1;
        }
    }
    return start;
}

// ---------------------------------------------------------------------------
//  Lines
// -------------------------------------------------------------------------

fn rvn_ed_line_dirty(line: [*c]rvn_ed_line_t) void {
    line.*.width = -1.0;
    line.*.row_count = 0;
}

fn rvn_ed_line_reserve(line: [*c]rvn_ed_line_t, length: c_int) void {
    if (length + 1 > line.*.cap) {
        var cap: c_int = if (line.*.cap != 0) line.*.cap else 16;
        while (cap < length + 1) cap *= 2;
        line.*.text = ccast([*c]u8, base.rvn_realloc(line.*.text, @intCast(cap)));
        line.*.cap = cap;
    }
}

fn rvn_ed_line_set(line: [*c]rvn_ed_line_t, text: [*c]const u8, length: c_int) void {
    rvn_ed_line_reserve(line, length);
    if (length > 0) cmemcpy(line.*.text, text, @intCast(length));
    line.*.text[@intCast(length)] = 0;
    line.*.length = length;
    rvn_ed_line_dirty(line);
}

fn rvn_ed_line_free(line: [*c]rvn_ed_line_t) void {
    base.rvn_free(line.*.text);
    base.rvn_free(line.*.breaks);
}

/// Opens `count` empty lines at `index`.
fn rvn_ed_lines_insert(ed: [*c]rvn_text_editor_t, index: u32, count: u32) void {
    if (count == 0) return;
    base.RVN_ARRAY_RESERVE(&ed.*.lines, &ed.*.line_cap, ed.*.line_count + count);
    cmemmove(ed.*.lines + index + count, ed.*.lines + index, @sizeOf(rvn_ed_line_t) * (ed.*.line_count - index));
    cmemset(ed.*.lines + index, 0, @sizeOf(rvn_ed_line_t) * count);
    var i: u32 = 0;
    while (i < count) : (i += 1) rvn_ed_line_set(&ed.*.lines[index + i], "", 0);
    ed.*.line_count += count;
}

fn rvn_ed_lines_remove(ed: [*c]rvn_text_editor_t, index: u32, count: u32) void {
    if (count == 0) return;
    var i: u32 = 0;
    while (i < count) : (i += 1) rvn_ed_line_free(&ed.*.lines[index + i]);
    cmemmove(ed.*.lines + index, ed.*.lines + index + count, @sizeOf(rvn_ed_line_t) * (ed.*.line_count - index - count));
    ed.*.line_count -= count;
}

/// The text between two ordered positions, in a new block.
fn rvn_ed_range(ed: [*c]const rvn_text_editor_t, from: rvn_ed_pos_t, to: rvn_ed_pos_t, length_out: [*c]c_int) [*c]u8 {
    var length: usize = 0;
    var line: c_int = from.line;
    while (line <= to.line) : (line += 1) {
        const begin: c_int = if (line == from.line) from.column else 0;
        const end: c_int = if (line == to.line) to.column else ed.*.lines[@intCast(line)].length;
        length += @intCast(end - begin + (if (line < to.line) @as(c_int, 1) else 0));
    }
    const out: [*c]u8 = ccast([*c]u8, base.rvn_alloc(length + 1));
    var w: usize = 0;
    line = from.line;
    while (line <= to.line) : (line += 1) {
        const begin: c_int = if (line == from.line) from.column else 0;
        const end: c_int = if (line == to.line) to.column else ed.*.lines[@intCast(line)].length;
        cmemcpy(out + w, ed.*.lines[@intCast(line)].text + @as(usize, @intCast(begin)), @intCast(end - begin));
        w += @intCast(end - begin);
        if (line < to.line) {
            out[w] = '\n';
            w += 1;
        }
    }
    out[w] = 0;
    if (length_out != null) length_out.* = @intCast(length);
    return out;
}

// ---------------------------------------------------------------------------
//  History
// -------------------------------------------------------------------------

fn rvn_ed_edit_free(edit: [*c]rvn_ed_edit_t) void {
    base.rvn_free(edit.*.removed);
    base.rvn_free(edit.*.inserted);
}

fn rvn_ed_history_clear(edits: [*c]rvn_ed_edit_t, count: [*c]u32) void {
    var i: u32 = 0;
    while (i < count.*) : (i += 1) rvn_ed_edit_free(&edits[i]);
    count.* = 0;
}

fn rvn_ed_changed_state(ed: [*c]rvn_text_editor_t, first_line: c_int) void {
    ed.*.rows_dirty = R_TRUE;
    ed.*.text_cache_valid = R_FALSE;
    ed.*.version += 1;
    const fl: u32 = @intCast(first_line);
    if (fl + 1 < ed.*.lex_valid) ed.*.lex_valid = fl + 1;
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

/// The one function that changes the text: replaces what lies between two
/// positions by `text` (either may be empty) and returns the position after
/// the inserted text. `record` stores the step in the history.
fn rvn_ed_replace(ed: [*c]rvn_text_editor_t, from_in: rvn_ed_pos_t, to_in: rvn_ed_pos_t, text: [*c]const u8, length_in: c_int, record: c_int) rvn_ed_pos_t {
    var from = from_in;
    var to = to_in;
    var length = length_in;
    var pieces: c_int = 1;

    if (rvn_ed_pos_cmp(from, to) > 0) {
        const swap = from;
        from = to;
        to = swap;
    }
    if (length < 0) length = @intCast(libc.strlen(text));

    if (record != 0) {
        const has_last = ed.*.undo_count != 0;
        const last: [*c]rvn_ed_edit_t = if (has_last) ed.*.undo + (ed.*.undo_count - 1) else null;
        const typed = length > 0 and rvn_ed_pos_cmp(from, to) == 0 and libc.memchr(text, '\n', @intCast(length)) == null and
            base.rvn_utf8_count(text, length) == 1;
        rvn_ed_history_clear(ed.*.redo, &ed.*.redo_count);
        if (typed and has_last and last.*.typing != 0 and last.*.removed_length == 0 and last.*.inserted_length < RVN_ED_TYPING_GROUP and
            rvn_ed_pos_cmp(last.*.caret_after, from) == 0)
        {
            // one more character of a run that is being typed: same step
            last.*.inserted = ccast([*c]u8, base.rvn_realloc(last.*.inserted, @intCast(last.*.inserted_length + length + 1)));
            cmemcpy(last.*.inserted + @as(usize, @intCast(last.*.inserted_length)), text, @intCast(length));
            last.*.inserted_length += length;
            last.*.inserted[@intCast(last.*.inserted_length)] = 0;
            last.*.caret_after = rvn_ed_pos(from.line, from.column + length);
        } else {
            if (ed.*.undo_count == RVN_ED_MAX_UNDO) {
                rvn_ed_edit_free(&ed.*.undo[0]);
                cmemmove(ed.*.undo, ed.*.undo + 1, @sizeOf(rvn_ed_edit_t) * (ed.*.undo_count - 1));
                ed.*.undo_count -= 1;
            }
            base.RVN_ARRAY_RESERVE(&ed.*.undo, &ed.*.undo_cap, ed.*.undo_count + 1);
            const edit: [*c]rvn_ed_edit_t = ed.*.undo + ed.*.undo_count;
            ed.*.undo_count += 1;
            cmemset(edit, 0, @sizeOf(rvn_ed_edit_t));
            edit.*.start = from;
            edit.*.removed = rvn_ed_range(ed, from, to, &edit.*.removed_length);
            edit.*.inserted = base.rvn_strndup(text, @intCast(length));
            edit.*.inserted_length = length;
            edit.*.caret_before = ed.*.caret;
            edit.*.anchor_before = ed.*.anchor;
            edit.*.caret_after = rvn_ed_pos_after(from, text, length);
            edit.*.typing = @intFromBool(typed);
        }
    }

    var i: c_int = 0;
    while (i < length) : (i += 1) {
        if (text[@intCast(i)] == '\n') pieces += 1;
    }
    // the markers below follow their lines; those of the lines that change are out of date
    {
        const delta: c_int = (pieces - 1) - (to.line - from.line);
        var m: u32 = 0;
        while (m < ed.*.marker_count) {
            const marker: [*c]rvn_ed_marker_t = &ed.*.markers[m];
            if (marker.*.line > to.line) {
                marker.*.line += delta;
                m += 1;
            } else if (marker.*.line >= from.line) {
                base.rvn_free(marker.*.message);
                ed.*.marker_count -= 1;
                marker.* = ed.*.markers[ed.*.marker_count];
            } else {
                m += 1;
            }
        }
    }

    // what follows the range on its last line is kept aside, and put back after the new text
    const tail_length: c_int = ed.*.lines[@intCast(to.line)].length - to.column;
    const tail: [*c]u8 = base.rvn_strndup(ed.*.lines[@intCast(to.line)].text + @as(usize, @intCast(to.column)), @intCast(tail_length));
    rvn_ed_lines_remove(ed, @intCast(from.line + 1), @intCast(to.line - from.line));
    var line: [*c]rvn_ed_line_t = &ed.*.lines[@intCast(from.line)];
    line.*.length = from.column;
    line.*.text[@intCast(line.*.length)] = 0;

    rvn_ed_lines_insert(ed, @intCast(from.line + 1), @intCast(pieces - 1));

    // the pieces between line breaks, without carriage returns
    var begin: c_int = 0;
    var index: c_int = from.line;
    var end: rvn_ed_pos_t = from;
    i = 0;
    while (i <= length) : (i += 1) {
        if (i == length or text[@intCast(i)] == '\n') {
            var piece = i - begin;
            line = &ed.*.lines[@intCast(index)];
            while (piece > 0 and text[@intCast(begin + piece - 1)] == '\r') piece -= 1;
            rvn_ed_line_reserve(line, line.*.length + piece + (if (i == length) tail_length else 0));
            if (piece > 0) cmemcpy(line.*.text + @as(usize, @intCast(line.*.length)), text + @as(usize, @intCast(begin)), @intCast(piece));
            line.*.length += piece;
            line.*.text[@intCast(line.*.length)] = 0;
            rvn_ed_line_dirty(line);
            end = rvn_ed_pos(index, line.*.length);
            begin = i + 1;
            index += 1;
        }
    }
    line = &ed.*.lines[@intCast(end.line)];
    if (tail_length > 0) cmemcpy(line.*.text + @as(usize, @intCast(line.*.length)), tail, @intCast(tail_length));
    line.*.length += tail_length;
    line.*.text[@intCast(line.*.length)] = 0;
    base.rvn_free(tail);

    rvn_ed_changed_state(ed, from.line);
    return end;
}

/// Tells the application that the user changed the text.
fn rvn_ed_notify(widget: [*c]widget_h.rvn_widget_t) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    if (ed.*.callback) |callback| callback(widget.*.id, ed.*.user_data);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
}

fn rvn_ed_break_typing(ed: [*c]rvn_text_editor_t) void {
    if (ed.*.undo_count != 0) ed.*.undo[ed.*.undo_count - 1].typing = R_FALSE;
}

fn rvn_ed_move_edit(to: [*c][*c]rvn_ed_edit_t, to_count: [*c]u32, to_cap: [*c]u32, from: [*c]rvn_ed_edit_t, from_count: [*c]u32) void {
    base.RVN_ARRAY_RESERVE(to, to_cap, to_count.* + 1);
    from_count.* -= 1;
    to.*[to_count.*] = from[from_count.*];
    to_count.* += 1;
}

fn rvn_ed_undo(ed: [*c]rvn_text_editor_t) c_int {
    if (ed.*.undo_count == 0 or ed.*.read_only != 0) return R_FALSE;
    const edit: [*c]rvn_ed_edit_t = ed.*.undo + (ed.*.undo_count - 1);
    edit.*.typing = R_FALSE;
    _ = rvn_ed_replace(ed, edit.*.start, rvn_ed_pos_after(edit.*.start, edit.*.inserted, edit.*.inserted_length), edit.*.removed, edit.*.removed_length, R_FALSE);
    ed.*.caret = rvn_ed_clamp(ed, edit.*.caret_before);
    ed.*.anchor = rvn_ed_clamp(ed, edit.*.anchor_before);
    rvn_ed_move_edit(&ed.*.redo, &ed.*.redo_count, &ed.*.redo_cap, ed.*.undo, &ed.*.undo_count);
    return R_TRUE;
}

fn rvn_ed_redo(ed: [*c]rvn_text_editor_t) c_int {
    if (ed.*.redo_count == 0 or ed.*.read_only != 0) return R_FALSE;
    const edit: [*c]rvn_ed_edit_t = ed.*.redo + (ed.*.redo_count - 1);
    _ = rvn_ed_replace(ed, edit.*.start, rvn_ed_pos_after(edit.*.start, edit.*.removed, edit.*.removed_length), edit.*.inserted, edit.*.inserted_length, R_FALSE);
    const after = rvn_ed_clamp(ed, edit.*.caret_after);
    ed.*.caret = after;
    ed.*.anchor = after;
    rvn_ed_move_edit(&ed.*.undo, &ed.*.undo_count, &ed.*.undo_cap, ed.*.redo, &ed.*.redo_count);
    return R_TRUE;
}

// ---------------------------------------------------------------------------
//  Metrics and horizontal positions
// -------------------------------------------------------------------------

/// Text starting `off` bytes into `text`.
inline fn at(text: [*c]const u8, off: c_int) [*c]const u8 {
    return text + @as(usize, @intCast(off));
}

/// Painter scale (pixels per logical unit), the field of the full RPainter struct.
fn painterScale(painter: ?*raven.RPainter) f32 {
    const p: *const draw_h.RPainter = ccast(*const draw_h.RPainter, painter.?);
    return p.scale;
}

fn rvn_ed_font_id(ed: [*c]const rvn_text_editor_t) Rid {
    if (ed.*.font != R_INVALID_ID and raven.Rfont_is_valid(ed.*.font) != 0) return ed.*.font;
    // text that has a language is code: it lines up better with a fixed width
    return if (ed.*.language_name != null) ext.g_rvn.mono_font else R_INVALID_ID;
}

/// The language of the editor, looked for again when the languages changed.
fn rvn_ed_language(ed: [*c]rvn_text_editor_t) ?*const common.rvn_language_t {
    if (ed.*.language_generation != common.rvn_language_generation()) {
        ed.*.language = if (ed.*.language_name != null) common.rvn_language_find(ed.*.language_name) else null;
        ed.*.language_generation = common.rvn_language_generation();
        ed.*.lex_valid = 0;
    }
    return ed.*.language;
}

fn rvn_ed_language_desc(ed: [*c]rvn_text_editor_t) [*c]const raven.RLanguageDesc {
    const language = rvn_ed_language(ed);
    return if (language) |l| common.rvn_language_desc(l) else null;
}

fn rvn_ed_metrics(ed: [*c]rvn_text_editor_t, m: [*c]rvn_ed_metrics_t) void {
    const widget: [*c]const widget_h.rvn_widget_t = &ed.*.base;
    var font_metrics: font_h.rvn_font_metrics_t = undefined;
    var digits: c_int = 1;

    m.*.theme = widget_h.rvn_widget_theme(widget);
    m.*.font_id = rvn_ed_font_id(ed);
    m.*.font = ext.rvn_font_resolve(m.*.font_id);
    m.*.bold_id = m.*.font_id;
    m.*.italic_id = m.*.font_id;
    {
        // (the styles of a font are made when first asked for, here: the editor is measured before it is painted)
        const language = rvn_ed_language(ed);
        if (language) |l| {
            if ((common.rvn_language_desc(l).*.flags & @as(u32, @intCast(raven.R_LANGUAGE_FORMATTED_TEXT))) != 0) {
                m.*.bold_id = ext.rvn_font_variant(m.*.font_id, font_h.RVN_FONT_BOLD);
                m.*.italic_id = ext.rvn_font_variant(m.*.font_id, font_h.RVN_FONT_ITALIC);
            }
        }
    }
    m.*.size = common.rvn_widget_font_size(widget, ed.*.font_size) * (if (ed.*.zoom > 0.0) ed.*.zoom else @as(f32, 1.0));
    ext.rvn_font_metrics(m.*.font, m.*.size, &font_metrics);
    m.*.line_height = @ceil(font_metrics.line_height + 2.0);
    m.*.space = ext.rvn_text_width(m.*.font, m.*.size, " ", 1);
    if (m.*.space <= 0.0) m.*.space = m.*.size * 0.3;
    m.*.tab = m.*.space * @as(f32, @floatFromInt(base.rvn_maxi(ed.*.tab_size, 1)));
    m.*.bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);

    m.*.gutter = 0.0;
    if (ed.*.line_numbers != 0) {
        const digit = ext.rvn_text_width(m.*.font, m.*.size, "0", 1);
        var count: u32 = ed.*.line_count;
        while (count >= 10) : (count /= 10) digits += 1;
        m.*.gutter = @ceil(digit * @as(f32, @floatFromInt(base.rvn_maxi(digits, 2))) + 18.0);
    }
    m.*.area.x = m.*.gutter + RVN_ED_PAD_X;
    m.*.area.y = RVN_ED_PAD_Y;
    // with word wrap the room of the scrollbar is always kept: the text does not flow again when it appears
    m.*.area.w = base.rvn_maxf(0.0, widget.*.rect.w - m.*.area.x - RVN_ED_PAD_X -
        (if (ed.*.wrap != 0 or common.rvn_scrollbar_needed(&ed.*.vbar) != 0) m.*.bar else 0.0));
    m.*.area.h = base.rvn_maxf(0.0, widget.*.rect.h - RVN_ED_PAD_Y * 2.0 -
        (if (ed.*.wrap == 0 and common.rvn_scrollbar_needed(&ed.*.hbar) != 0) m.*.bar else 0.0));
}

/// Horizontal position reached after text[from..to), starting at `x` on the row: tabs jump to the next stop.
fn rvn_ed_advance(m: [*c]const rvn_ed_metrics_t, text: [*c]const u8, from: c_int, to: c_int, x_in: f32) f32 {
    var x = x_in;
    var run = from;
    var i = from;
    while (i < to) : (i += 1) {
        if (text[@intCast(i)] != '\t') continue;
        if (i > run) x += ext.rvn_text_width(m.*.font, m.*.size, at(text, run), i - run);
        x = (@floor(x / m.*.tab + 0.001) + 1.0) * m.*.tab;
        run = i + 1;
    }
    if (to > run) x += ext.rvn_text_width(m.*.font, m.*.size, at(text, run), to - run);
    return x;
}

/// Byte offset in text[from..to) nearest to the horizontal position `target`.
fn rvn_ed_offset_at(m: [*c]const rvn_ed_metrics_t, text: [*c]const u8, from: c_int, to: c_int, target: f32) c_int {
    var x: f32 = 0.0;
    var i = from;
    while (i < to) {
        const next = base.rvn_utf8_next(text, to, i);
        const after = rvn_ed_advance(m, text, i, next, x);
        if (target < (x + after) * 0.5) return i;
        x = after;
        i = next;
    }
    return to;
}

// ---------------------------------------------------------------------------
//  Rows (word wrap)
// -------------------------------------------------------------------------

/// Cuts one line into rows no wider than `width`, at spaces when it can.
fn rvn_ed_wrap_line(m: [*c]const rvn_ed_metrics_t, line: [*c]rvn_ed_line_t, width: f32) void {
    var breaks_cap: c_int = 0;
    var count: c_int = 0;
    var i: c_int = 0;
    var row_start: c_int = 0;
    var last_space: c_int = -1;
    var x: f32 = 0.0;
    var breaks: [*c]c_int = null;

    while (i < line.*.length) {
        const next = base.rvn_utf8_next(line.*.text, line.*.length, i);
        const after = rvn_ed_advance(m, line.*.text, i, next, x);
        if (after > width and i > row_start) {
            const cut: c_int = if (last_space > row_start) last_space else i;
            if (count + 1 > breaks_cap) {
                breaks_cap = if (breaks_cap != 0) breaks_cap * 2 else 4;
                breaks = ccast([*c]c_int, base.rvn_realloc(breaks, @sizeOf(c_int) * @as(usize, @intCast(breaks_cap))));
            }
            breaks[@intCast(count)] = cut;
            count += 1;
            row_start = cut;
            last_space = -1;
            x = rvn_ed_advance(m, line.*.text, cut, i, 0.0);
            continue;
        }
        if (line.*.text[@intCast(i)] == ' ' or line.*.text[@intCast(i)] == '\t') last_space = next;
        x = after;
        i = next;
    }
    base.rvn_free(line.*.breaks);
    line.*.breaks = breaks;
    line.*.row_count = count + 1;
}

/// Bytes of a line shown on one of its rows.
fn rvn_ed_row_range(ed: [*c]const rvn_text_editor_t, line: c_int, row: c_int, begin: [*c]c_int, end: [*c]c_int) void {
    const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
    if (ed.*.wrap == 0 or l.*.row_count <= 1) {
        begin.* = 0;
        end.* = l.*.length;
        return;
    }
    begin.* = if (row > 0) l.*.breaks[@intCast(row - 1)] else 0;
    end.* = if (row + 1 < l.*.row_count) l.*.breaks[@intCast(row)] else l.*.length;
}

/// Row of a line that shows a column: a column on a cut is at the start of the row after it.
fn rvn_ed_row_of(ed: [*c]const rvn_text_editor_t, line: c_int, column: c_int) c_int {
    const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
    var row: c_int = 0;
    if (ed.*.wrap == 0 or l.*.row_count <= 1) return 0;
    while (row + 1 < l.*.row_count and l.*.breaks[@intCast(row)] <= column) row += 1;
    return row;
}

/// Brings the row tables and the size of the content up to date.
fn rvn_ed_update_rows(ed: [*c]rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t) void {
    var i: u32 = 0;
    var rows: u32 = 0;
    var widest: f32 = 0.0;

    if (ed.*.wrap != 0 and ed.*.wrap_width != m.*.area.w) {
        ed.*.wrap_width = m.*.area.w;
        i = 0;
        while (i < ed.*.line_count) : (i += 1) ed.*.lines[i].row_count = 0;
        ed.*.rows_dirty = R_TRUE;
    }
    if (ed.*.rows_dirty == 0) return;
    ed.*.rows_dirty = R_FALSE;

    if (ed.*.wrap != 0) {
        base.RVN_ARRAY_RESERVE(&ed.*.row_starts, &ed.*.row_starts_cap, ed.*.line_count + 1);
        i = 0;
        while (i < ed.*.line_count) : (i += 1) {
            if (ed.*.lines[i].row_count == 0) rvn_ed_wrap_line(m, &ed.*.lines[i], base.rvn_maxf(ed.*.wrap_width, m.*.space * 4.0));
            ed.*.row_starts[i] = rows;
            rows += @intCast(ed.*.lines[i].row_count);
        }
        ed.*.row_starts[ed.*.line_count] = rows;
        ed.*.total_rows = rows;
        ed.*.max_width = 0.0;
    } else {
        i = 0;
        while (i < ed.*.line_count) : (i += 1) {
            const line: [*c]rvn_ed_line_t = &ed.*.lines[i];
            if (line.*.width < 0.0) line.*.width = rvn_ed_advance(m, line.*.text, 0, line.*.length, 0.0);
            if (line.*.width > widest) widest = line.*.width;
        }
        ed.*.total_rows = ed.*.line_count;
        ed.*.max_width = widest;
    }
}

fn rvn_ed_first_row(ed: [*c]const rvn_text_editor_t, line: c_int) u32 {
    return if (ed.*.wrap != 0) ed.*.row_starts[@intCast(line)] else @intCast(line);
}

/// Line and row in the line of a row counted from the top of the text.
fn rvn_ed_locate_row(ed: [*c]const rvn_text_editor_t, global_row_in: u32, line: [*c]c_int, row: [*c]c_int) void {
    var low: u32 = 0;
    var high: u32 = ed.*.line_count - 1;
    var global_row = global_row_in;
    if (global_row >= ed.*.total_rows) global_row = ed.*.total_rows - 1;
    if (ed.*.wrap == 0) {
        line.* = @intCast(global_row);
        row.* = 0;
        return;
    }
    while (low < high) {
        const middle: u32 = (low + high + 1) / 2;
        if (ed.*.row_starts[middle] <= global_row) low = middle else high = middle - 1;
    }
    line.* = @intCast(low);
    row.* = @intCast(global_row - ed.*.row_starts[low]);
}

/// Where a position is drawn, in the coordinates of the text (before scrolling).
fn rvn_ed_pos_point(ed: [*c]const rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t, pos: rvn_ed_pos_t) base.rvn_vec2_t {
    const row = rvn_ed_row_of(ed, pos.line, pos.column);
    var begin: c_int = undefined;
    var end: c_int = undefined;
    rvn_ed_row_range(ed, pos.line, row, &begin, &end);
    return base.rvn_vec2(
        rvn_ed_advance(m, ed.*.lines[@intCast(pos.line)].text, begin, pos.column, 0.0),
        @as(f32, @floatFromInt(rvn_ed_first_row(ed, pos.line) + @as(u32, @intCast(row)))) * m.*.line_height,
    );
}

/// Position under a point given in the coordinates of the text.
fn rvn_ed_point_pos(ed: [*c]const rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t, x: f32, y: f32) rvn_ed_pos_t {
    var line: c_int = undefined;
    var row: c_int = undefined;
    var begin: c_int = undefined;
    var end: c_int = undefined;
    var global = @floor(y / m.*.line_height);
    if (global < 0.0) global = 0.0;
    if (global > @as(f32, @floatFromInt(ed.*.total_rows))) global = @floatFromInt(ed.*.total_rows);
    rvn_ed_locate_row(ed, @intFromFloat(global), &line, &row);
    rvn_ed_row_range(ed, line, row, &begin, &end);
    var column = rvn_ed_offset_at(m, ed.*.lines[@intCast(line)].text, begin, end, x);
    // the end of a wrapped row is the position before the cut, not the start of the next row
    if (ed.*.wrap != 0 and column == end and row + 1 < ed.*.lines[@intCast(line)].row_count and column > begin) {
        column = base.rvn_utf8_prev(ed.*.lines[@intCast(line)].text, column);
    }
    return rvn_ed_pos(line, column);
}

fn rvn_ed_update_bars(ed: [*c]rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t) void {
    ed.*.vbar.content = @as(f32, @floatFromInt(ed.*.total_rows)) * m.*.line_height;
    ed.*.vbar.viewport = m.*.area.h;
    _ = common.rvn_scrollbar_clamp(&ed.*.vbar);
    // room for the caret after the longest line
    ed.*.hbar.content = if (ed.*.wrap != 0) 0.0 else ed.*.max_width + m.*.space * 2.0;
    ed.*.hbar.viewport = m.*.area.w;
    _ = common.rvn_scrollbar_clamp(&ed.*.hbar);
}

/// Scrolls as little as needed to show the caret. Before the editor has its size, this waits for the layout.
fn rvn_ed_reveal(ed: [*c]rvn_text_editor_t, in_layout: c_int) void {
    var m: rvn_ed_metrics_t = undefined;
    if (in_layout == 0 and (ed.*.base.rect.w <= 0.0 or ed.*.base.rect.h <= 0.0 or (ed.*.base.flags & widget_h.RVN_WF_LAYOUT_DIRTY) != 0)) {
        ed.*.reveal_pending = R_TRUE;
        return;
    }
    rvn_ed_metrics(ed, &m);
    rvn_ed_update_rows(ed, &m);
    rvn_ed_update_bars(ed, &m);
    const point = rvn_ed_pos_point(ed, &m, ed.*.caret);
    if (point.y < ed.*.vbar.offset) {
        _ = common.rvn_scrollbar_set(&ed.*.vbar, point.y);
    } else if (point.y + m.line_height > ed.*.vbar.offset + ed.*.vbar.viewport) {
        _ = common.rvn_scrollbar_set(&ed.*.vbar, point.y + m.line_height - ed.*.vbar.viewport);
    }
    if (ed.*.wrap == 0) {
        if (point.x < ed.*.hbar.offset + m.space) {
            _ = common.rvn_scrollbar_set(&ed.*.hbar, point.x - m.space * 4.0);
        } else if (point.x > ed.*.hbar.offset + ed.*.hbar.viewport - m.space * 2.0) {
            _ = common.rvn_scrollbar_set(&ed.*.hbar, point.x - ed.*.hbar.viewport + m.space * 6.0);
        }
    }
    ed.*.reveal_pending = R_FALSE;
}

/// The caret moved: keep it visible and solid for a moment.
fn rvn_ed_caret_moved(ed: [*c]rvn_text_editor_t, keep_goal: c_int) void {
    if (keep_goal == 0) ed.*.goal_x = -1.0;
    ed.*.blink_start = ext.rvn_clock_seconds();
    rvn_ed_reveal(ed, R_FALSE);
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

// ---------------------------------------------------------------------------
//  Layout
// -------------------------------------------------------------------------

fn rvn_text_editor_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    var m: rvn_ed_metrics_t = undefined;
    rvn_ed_metrics(ed, &m);
    // an editor is given its size by its parent; by itself it asks for a few lines
    return base.rvn_vec2(220.0, m.line_height * 5.0 + RVN_ED_PAD_Y * 2.0);
}

fn rvn_text_editor_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    var m: rvn_ed_metrics_t = undefined;
    // the scrollbars take room, which changes what is needed: twice is enough to settle
    var pass: c_int = 0;
    while (pass < 2) : (pass += 1) {
        rvn_ed_metrics(ed, &m);
        rvn_ed_update_rows(ed, &m);
        rvn_ed_update_bars(ed, &m);
    }
    if (ed.*.reveal_pending != 0) rvn_ed_reveal(ed, R_TRUE);
}

fn rvn_ed_tracks(ed: [*c]const rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t, vertical: [*c]base.rvn_rect_t, horizontal: [*c]base.rvn_rect_t) void {
    const widget: [*c]const widget_h.rvn_widget_t = &ed.*.base;
    const h_needed = ed.*.wrap == 0 and common.rvn_scrollbar_needed(&ed.*.hbar) != 0;
    vertical.* = base.rvn_rect(widget.*.rect.w - m.*.bar - 1.0, 1.0, m.*.bar, widget.*.rect.h - 2.0 - (if (h_needed) m.*.bar else 0.0));
    horizontal.* = base.rvn_rect(m.*.gutter + 1.0, widget.*.rect.h - m.*.bar - 1.0, widget.*.rect.w - m.*.gutter - 2.0 - (if (common.rvn_scrollbar_needed(&ed.*.vbar) != 0) m.*.bar else 0.0), m.*.bar);
}

// ---------------------------------------------------------------------------
//  Paint
// -------------------------------------------------------------------------

/// Makes the lexer state of the lines up to `line` valid.
fn rvn_ed_lex_until(ed: [*c]rvn_text_editor_t, line: u32) void {
    const language = rvn_ed_language(ed);
    if (ed.*.lex_valid == 0) {
        ed.*.lines[0].lex_in = 0;
        ed.*.lex_valid = 1;
    }
    while (ed.*.lex_valid <= line and ed.*.lex_valid < ed.*.line_count) {
        const previous: [*c]const rvn_ed_line_t = &ed.*.lines[ed.*.lex_valid - 1];
        ed.*.lines[ed.*.lex_valid].lex_in = common.rvn_syntax_line(language, previous.*.text, previous.*.length, previous.*.lex_in, null, 0, null);
        ed.*.lex_valid += 1;
    }
}

// ---------------------------------------------------------------------------
//  Brackets
// -------------------------------------------------------------------------

/// R_TRUE when a column of a line is code: not inside a comment or a text.
fn rvn_ed_is_code(ed: [*c]rvn_text_editor_t, line: c_int, column: c_int) c_int {
    const language = rvn_ed_language(ed);
    var spans: [RVN_ED_MAX_SPANS]common.rvn_span_t = undefined;
    var count: c_int = 0;
    if (language == null) return R_TRUE;
    rvn_ed_lex_until(ed, @intCast(line));
    const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
    _ = common.rvn_syntax_line(language, l.*.text, l.*.length, l.*.lex_in, &spans, RVN_ED_MAX_SPANS, &count);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (column >= spans[@intCast(i)].start and column < spans[@intCast(i)].end) {
            return @intFromBool(spans[@intCast(i)].token != common.RVN_TOKEN_COMMENT and spans[@intCast(i)].token != common.RVN_TOKEN_STRING);
        }
    }
    return R_TRUE;
}

/// The bracket that closes (or opens) the one at `at`. Looks no further than a few thousand lines.
fn rvn_ed_match_bracket(ed: [*c]rvn_text_editor_t, at_pos: rvn_ed_pos_t, match: [*c]rvn_ed_pos_t) c_int {
    const open: [*c]const u8 = "([{";
    const closers: [*c]const u8 = ")]}";
    const language = rvn_ed_language(ed);
    var l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(at_pos.line)];
    var spans: [RVN_ED_MAX_SPANS]common.rvn_span_t = undefined;
    var forward: c_int = undefined;
    var other: u8 = undefined;
    var depth: c_int = 1;
    var line: c_int = at_pos.line;
    var column: c_int = undefined;
    var budget: c_int = 3000;
    var span_count: c_int = 0;

    if (at_pos.column < 0 or at_pos.column >= l.*.length) return R_FALSE;
    const bracket: u8 = l.*.text[@intCast(at_pos.column)];
    const found_open = libc.strchr(open, bracket);
    if (found_open != null and bracket != 0) {
        forward = R_TRUE;
        other = closers[@intCast(@intFromPtr(found_open) - @intFromPtr(open))];
    } else {
        const found_close = libc.strchr(closers, bracket);
        if (found_close != null and bracket != 0) {
            forward = R_FALSE;
            other = open[@intCast(@intFromPtr(found_close) - @intFromPtr(closers))];
        } else {
            return R_FALSE;
        }
    }
    if (rvn_ed_is_code(ed, at_pos.line, at_pos.column) == 0) return R_FALSE;

    column = at_pos.column + (if (forward != 0) @as(c_int, 1) else @as(c_int, -1));
    while (line >= 0 and line < @as(c_int, @intCast(ed.*.line_count)) and budget > 0) {
        budget -= 1;
        l = &ed.*.lines[@intCast(line)];
        if (language) |lang| {
            rvn_ed_lex_until(ed, @intCast(line));
            _ = common.rvn_syntax_line(lang, l.*.text, l.*.length, l.*.lex_in, &spans, RVN_ED_MAX_SPANS, &span_count);
        }
        while (column >= 0 and column < l.*.length) : (column += if (forward != 0) @as(c_int, 1) else @as(c_int, -1)) {
            const c: u8 = l.*.text[@intCast(column)];
            var code = true;
            if (c != bracket and c != other) continue;
            var i: c_int = 0;
            while (i < span_count and code) : (i += 1) {
                if (column >= spans[@intCast(i)].start and column < spans[@intCast(i)].end) {
                    code = spans[@intCast(i)].token != common.RVN_TOKEN_COMMENT and spans[@intCast(i)].token != common.RVN_TOKEN_STRING;
                }
            }
            if (!code) continue;
            depth += if (c == bracket) @as(c_int, 1) else @as(c_int, -1);
            if (depth == 0) {
                match.* = rvn_ed_pos(line, column);
                return R_TRUE;
            }
        }
        line += if (forward != 0) @as(c_int, 1) else @as(c_int, -1);
        if (line >= 0 and line < @as(c_int, @intCast(ed.*.line_count))) {
            column = if (forward != 0) 0 else ed.*.lines[@intCast(line)].length - 1;
        }
    }
    return R_FALSE;
}

/// The pair of brackets to show for the place of the caret: the one after it, else the one before it.
fn rvn_ed_update_match(ed: [*c]rvn_text_editor_t) void {
    var at_pos = ed.*.caret;
    if (ed.*.match_version == ed.*.version and rvn_ed_pos_cmp(ed.*.match_caret, ed.*.caret) == 0) return;
    ed.*.match_version = ed.*.version;
    ed.*.match_caret = ed.*.caret;
    ed.*.match_found = rvn_ed_match_bracket(ed, at_pos, &ed.*.match_b);
    if (ed.*.match_found == 0 and at_pos.column > 0) {
        at_pos.column -= 1;
        ed.*.match_found = rvn_ed_match_bracket(ed, at_pos, &ed.*.match_b);
    }
    ed.*.match_a = at_pos;
}

/// Draws text[begin..end) of a line at (x, y), tabs expanded, each span in its color.
fn rvn_ed_paint_text(painter: ?*raven.RPainter, m: [*c]const rvn_ed_metrics_t, text: [*c]const u8, begin: c_int, end: c_int, x: f32, y: f32, spans: [*c]const common.rvn_span_t, span_count: c_int, color: base.rvn_color_t) void {
    var pen: f32 = 0.0;
    var i = begin;
    var span: c_int = 0;

    while (i < end) {
        var stop = end;
        var run_color = color;
        var font = m.*.font_id;
        while (span < span_count and spans[@intCast(span)].end <= i) span += 1;
        if (span < span_count) {
            if (spans[@intCast(span)].start <= i) {
                const token: common.rvn_token_t = spans[@intCast(span)].token;
                run_color = common.rvn_syntax_color(m.*.theme, token, color);
                // formatted text: the styles have the advances of the font, so the columns do not move
                if (token == common.RVN_TOKEN_STRONG or token == common.RVN_TOKEN_HEADING) {
                    font = m.*.bold_id;
                } else if (token == common.RVN_TOKEN_EMPHASIS) {
                    font = m.*.italic_id;
                }
                stop = base.rvn_mini(stop, spans[@intCast(span)].end);
            } else {
                stop = base.rvn_mini(stop, spans[@intCast(span)].start);
            }
        }
        if (text[@intCast(i)] == '\t') {
            pen = (@floor(pen / m.*.tab + 0.001) + 1.0) * m.*.tab;
            i += 1;
            continue;
        }
        if (libc.memchr(at(text, i), '\t', @intCast(stop - i))) |tab| {
            stop = @intCast(@intFromPtr(tab) - @intFromPtr(text));
        }
        ext.rvn_paint_text(painter, font, m.*.size, x + pen, y + 1.0, at(text, i), stop - i, run_color);
        pen += ext.rvn_text_width(m.*.font, m.*.size, at(text, i), stop - i);
        i = stop;
    }
}

fn rvn_ed_marker_color(kind: raven.RMarkerKind, widget: [*c]const widget_h.rvn_widget_t) base.rvn_color_t {
    return switch (kind) {
        raven.R_MARKER_ERROR => ext.rvn_widget_color(widget, raven.R_COLOR_DANGER),
        raven.R_MARKER_WARNING => ext.rvn_widget_color(widget, raven.R_COLOR_WARNING),
        else => ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT),
    };
}

fn rvn_text_editor_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    var m: rvn_ed_metrics_t = undefined;
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    var vertical: base.rvn_rect_t = undefined;
    var horizontal: base.rvn_rect_t = undefined;
    const origin = ext.rvn_widget_origin(widget);
    const focused: c_int = if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0) 1 else 0;
    const has_selection = rvn_ed_has_selection(ed);
    const sel_min = rvn_ed_sel_min(ed);
    const sel_max = rvn_ed_sel_max(ed);
    const text = ext.rvn_widget_text_color(widget, painter);
    var selection = ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION);
    const dim = ext.rvn_widget_color(widget, raven.R_COLOR_TEXT_PLACEHOLDER);
    const radius = ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    const focus = base.rvn_clampf(ext.rvn_paint_spring(painter, &widget.*.press, if (focused != 0) 1.0 else 0.0, raven.R_MOTION_SNAPPY), 0.0, 1.0);
    var span_count: c_int = 0;
    var span_line: c_int = -1;
    var spans: [RVN_ED_MAX_SPANS]common.rvn_span_t = undefined;
    const language = rvn_ed_language(ed);

    rvn_ed_metrics(ed, &m);
    rvn_ed_update_rows(ed, &m);
    if (focused == 0) selection = base.rvn_color_fade(selection, 0.55);

    // frame
    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(painter, widget, rect, base.rvn_minf(radius, 14.0), common.RVN_SURFACE_INPUT, 0.0, 0.0);
        if (focus > 0.01) {
            ext.rvn_paint_box(painter, rect, base.rvn_minf(radius, 14.0), 0, 1.5, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS), focus));
        }
    } else {
        ext.rvn_paint_box(painter, rect, radius, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_BORDER), ext.rvn_widget_color(widget, raven.R_COLOR_FOCUS), focus));
    }

    var scroll_y = common.rvn_scrollbar_shown(&ed.*.vbar, painter);
    var scroll_x: f32 = if (ed.*.wrap != 0) 0.0 else common.rvn_scrollbar_shown(&ed.*.hbar, painter);
    // whole pixels: the text stays sharp while it scrolls
    const scale = painterScale(painter);
    scroll_y = @floor(scroll_y * scale + 0.5) / scale;
    scroll_x = @floor(scroll_x * scale + 0.5) / scale;

    const first_row: u32 = if (scroll_y > 0.0) @intFromFloat(scroll_y / m.line_height) else 0;
    var last_row: u32 = @as(u32, @intFromFloat(base.rvn_maxf(0.0, (scroll_y + m.area.h) / m.line_height))) + 1;
    if (last_row > ed.*.total_rows) last_row = ed.*.total_rows;

    // margin of the line numbers
    if (ed.*.line_numbers != 0) {
        ext.rvn_paint_push_clip(painter, base.rvn_rect(1.0, 1.0, m.gutter, rect.h - 2.0));
        ext.rvn_paint_rect(painter, base.rvn_rect(m.gutter - 1.0, 4.0, 1.0, rect.h - 8.0), ext.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
        var row: u32 = first_row;
        while (row < last_row) : (row += 1) {
            var line: c_int = undefined;
            var line_row: c_int = undefined;
            var number: [16]u8 = undefined;
            rvn_ed_locate_row(ed, row, &line, &line_row);
            if (line_row != 0) continue;
            _ = libc.snprintf(&number, number.len, "%d", line + 1);
            const row_y = m.area.y + @as(f32, @floatFromInt(row)) * m.line_height - scroll_y;
            ext.rvn_paint_text_in(painter, m.font_id, m.size, base.rvn_rect(0.0, row_y, m.gutter - 9.0, m.line_height), 1.0, &number, -1, if (line == ed.*.caret.line) text else dim);
            // a dot in the margin of the lines that have a marker
            var marker: u32 = 0;
            while (marker < ed.*.marker_count) : (marker += 1) {
                if (ed.*.markers[marker].line != line) continue;
                ext.rvn_paint_box(painter, base.rvn_rect(4.0, row_y + m.line_height * 0.5 - 3.0, 6.0, 6.0), 3.0, rvn_ed_marker_color(ed.*.markers[marker].kind, widget), 0.0, 0);
                break;
            }
        }
        ext.rvn_paint_pop_clip(painter);
    }

    ext.rvn_paint_push_clip(painter, base.rvn_rect(m.gutter + 1.0, 1.0, rect.w - m.gutter - 2.0, rect.h - 2.0));

    if (ed.*.line_count == 1 and ed.*.lines[0].length == 0 and ed.*.placeholder != null) {
        ext.rvn_paint_text(painter, m.font_id, m.size, m.area.x, m.area.y + 1.0, ed.*.placeholder, -1, dim);
    }

    if (language != null and last_row > 0) {
        var line: c_int = undefined;
        var line_row: c_int = undefined;
        rvn_ed_locate_row(ed, last_row - 1, &line, &line_row);
        rvn_ed_lex_until(ed, @intCast(line));
    }
    // the bracket next to the caret and the one that goes with it
    if (focused != 0 and !(has_selection != 0) and language != null) {
        rvn_ed_update_match(ed);
    } else {
        ed.*.match_found = R_FALSE;
    }

    var row: u32 = first_row;
    while (row < last_row) : (row += 1) {
        var line: c_int = undefined;
        var line_row: c_int = undefined;
        var begin: c_int = undefined;
        var end: c_int = undefined;
        rvn_ed_locate_row(ed, row, &line, &line_row);
        rvn_ed_row_range(ed, line, line_row, &begin, &end);
        const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
        const y = m.area.y + @as(f32, @floatFromInt(row)) * m.line_height - scroll_y;

        // the line of the caret, lightly marked
        if (focused != 0 and !(has_selection != 0) and line == ed.*.caret.line and ed.*.read_only == 0) {
            ext.rvn_paint_rect(painter, base.rvn_rect(m.gutter + 1.0, y, rect.w - m.gutter - 2.0, m.line_height), base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_ROW_HOVERED), 0.6));
        }
        // the part of the selection that lies on this row
        if (has_selection != 0 and line >= sel_min.line and line <= sel_max.line) {
            const from: c_int = if (line == sel_min.line) base.rvn_maxi(sel_min.column, begin) else begin;
            const to: c_int = if (line == sel_max.line) base.rvn_mini(sel_max.column, end) else end;
            if (from <= to and !(line == sel_max.line and sel_max.column < begin) and !(line == sel_min.line and sel_min.column > end)) {
                const x0 = rvn_ed_advance(&m, l.*.text, begin, from, 0.0);
                var x1 = rvn_ed_advance(&m, l.*.text, from, to, x0);
                // a selected line break shows as a little more than the text
                if (line < sel_max.line and end == l.*.length) x1 += m.space;
                if (x1 > x0) {
                    ext.rvn_paint_box(painter, base.rvn_rect(m.area.x + x0 - scroll_x, y, x1 - x0, m.line_height), 3.0, selection, 0.0, 0);
                }
            }
        }
        if (ed.*.match_found != 0) {
            var which: c_int = 0;
            while (which < 2) : (which += 1) {
                const mpos = if (which != 0) ed.*.match_b else ed.*.match_a;
                if (mpos.line != line or mpos.column < begin or mpos.column >= end) continue;
                const x0 = rvn_ed_advance(&m, l.*.text, begin, mpos.column, 0.0);
                ext.rvn_paint_box(painter, base.rvn_rect(m.area.x + x0 - scroll_x - 1.0, y + 1.0, rvn_ed_advance(&m, l.*.text, mpos.column, mpos.column + 1, x0) - x0 + 2.0, m.line_height - 2.0), 3.0, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT), 0.22), 1.0, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT), 0.7));
            }
        }
        if (end > begin) {
            if (language) |lang| {
                if (span_line != line) {
                    _ = common.rvn_syntax_line(lang, l.*.text, l.*.length, l.*.lex_in, &spans, RVN_ED_MAX_SPANS, &span_count);
                    span_line = line;
                }
            }
            rvn_ed_paint_text(painter, &m, l.*.text, begin, end, m.area.x - scroll_x, y, &spans, if (language != null) span_count else 0, text);
        }
        // markers: a wavy line under what they are about
        var marker: u32 = 0;
        while (marker < ed.*.marker_count) : (marker += 1) {
            const mark: [*c]const rvn_ed_marker_t = &ed.*.markers[marker];
            if (mark.*.line != line) continue;
            const from = base.rvn_clampi(mark.*.from, begin, end);
            const to = if (mark.*.to < 0) end else base.rvn_clampi(mark.*.to, begin, end);
            if (to < from or (mark.*.from >= end and end > begin and line_row + 1 < l.*.row_count)) continue;
            const x0 = rvn_ed_advance(&m, l.*.text, begin, from, 0.0);
            var x1 = rvn_ed_advance(&m, l.*.text, from, to, x0);
            // (something to see even for an empty range)
            if (x1 - x0 < m.space * 1.5) x1 = x0 + m.space * 1.5;
            const color = rvn_ed_marker_color(mark.*.kind, widget);
            var wave: f32 = x0;
            while (wave < x1) : (wave += 4.0) {
                const next = base.rvn_minf(wave + 4.0, x1);
                const up = (@as(c_int, @intFromFloat((wave - x0) / 4.0)) & 1) != 0;
                ext.rvn_paint_line(painter, m.area.x + wave - scroll_x, y + m.line_height - (if (up) @as(f32, 3.5) else @as(f32, 1.5)), m.area.x + next - scroll_x, y + m.line_height - (if (up) @as(f32, 1.5) else @as(f32, 3.5)), 1.2, color);
            }
        }
    }

    // the caret glides to its place and blinks once it rests there
    if (focused != 0 and ed.*.read_only == 0) {
        const point = rvn_ed_pos_point(ed, &m, ed.*.caret);
        const x = ext.rvn_paint_spring(painter, &ed.*.caret_x, point.x, raven.R_MOTION_SNAPPY);
        const caret_y = ext.rvn_paint_spring(painter, &ed.*.caret_y, point.y, raven.R_MOTION_SNAPPY);
        const moving = ext.rvn_spring_moving(&ed.*.caret_x, point.x) != 0 or ext.rvn_spring_moving(&ed.*.caret_y, point.y) != 0;
        if (moving or @mod(ext.rvn_clock_seconds() - ed.*.blink_start, 1.0) < 0.55) {
            ext.rvn_paint_box(painter, base.rvn_rect(m.area.x + x - scroll_x - 1.0, m.area.y + caret_y - scroll_y + 1.0, 2.0, m.line_height - 2.0), 1.0, ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_HOVERED), 0.0, 0);
        }
    } else {
        ed.*.caret_x.started = R_FALSE;
        ed.*.caret_y.started = R_FALSE;
    }
    ext.rvn_paint_pop_clip(painter);

    rvn_ed_tracks(ed, &m, &vertical, &horizontal);
    const mouse_x: f32 = if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0;
    const mouse_y: f32 = if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0;
    common.rvn_scrollbar_paint(&ed.*.vbar, widget, painter, vertical, R_TRUE, mouse_x, mouse_y);
    if (ed.*.wrap == 0) {
        common.rvn_scrollbar_paint(&ed.*.hbar, widget, painter, horizontal, R_FALSE, mouse_x, mouse_y);
    }
}

// ---------------------------------------------------------------------------
//  Editing commands
// -------------------------------------------------------------------------

/// True when the language flag `flag` (a raven.R_LANGUAGE_* value) is set in `flags`.
inline fn hasFlag(flags: raven.Ruint, comptime flag: c_int) bool {
    return (flags & @as(raven.Ruint, @intCast(flag))) != 0;
}

const rvn_ed_class_t = c_uint;
const RVN_ED_SPACE: c_uint = 0;
const RVN_ED_WORD: c_uint = 1;
const RVN_ED_PUNCTUATION: c_uint = 2;

fn rvn_ed_class(c: u8) rvn_ed_class_t {
    if (c == ' ' or c == '\t') return RVN_ED_SPACE;
    if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 0x80) return RVN_ED_WORD;
    return RVN_ED_PUNCTUATION;
}

fn rvn_ed_char_left(ed: [*c]const rvn_text_editor_t, pos: rvn_ed_pos_t) rvn_ed_pos_t {
    if (pos.column > 0) return rvn_ed_pos(pos.line, base.rvn_utf8_prev(ed.*.lines[@intCast(pos.line)].text, pos.column));
    if (pos.line > 0) return rvn_ed_pos(pos.line - 1, ed.*.lines[@intCast(pos.line - 1)].length);
    return pos;
}

fn rvn_ed_char_right(ed: [*c]const rvn_text_editor_t, pos: rvn_ed_pos_t) rvn_ed_pos_t {
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(pos.line)];
    if (pos.column < line.*.length) return rvn_ed_pos(pos.line, base.rvn_utf8_next(line.*.text, line.*.length, pos.column));
    if (pos.line + 1 < @as(c_int, @intCast(ed.*.line_count))) return rvn_ed_pos(pos.line + 1, 0);
    return pos;
}

fn rvn_ed_word_left(ed: [*c]const rvn_text_editor_t, pos_in: rvn_ed_pos_t) rvn_ed_pos_t {
    var pos = pos_in;
    const text = ed.*.lines[@intCast(pos.line)].text;
    if (pos.column == 0) return rvn_ed_char_left(ed, pos);
    while (pos.column > 0 and rvn_ed_class(text[@intCast(pos.column - 1)]) == RVN_ED_SPACE) pos.column -= 1;
    if (pos.column == 0) return pos;
    const kind = rvn_ed_class(text[@intCast(pos.column - 1)]);
    while (pos.column > 0 and rvn_ed_class(text[@intCast(pos.column - 1)]) == kind) pos.column -= 1;
    return pos;
}

fn rvn_ed_word_right(ed: [*c]const rvn_text_editor_t, pos_in: rvn_ed_pos_t) rvn_ed_pos_t {
    var pos = pos_in;
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(pos.line)];
    if (pos.column >= line.*.length) return rvn_ed_char_right(ed, pos);
    const kind = rvn_ed_class(line.*.text[@intCast(pos.column)]);
    while (pos.column < line.*.length and rvn_ed_class(line.*.text[@intCast(pos.column)]) == kind) pos.column += 1;
    while (pos.column < line.*.length and rvn_ed_class(line.*.text[@intCast(pos.column)]) == RVN_ED_SPACE) pos.column += 1;
    return pos;
}

/// Up or down by `rows` rows, keeping the horizontal position.
fn rvn_ed_move_rows(ed: [*c]rvn_text_editor_t, m: [*c]const rvn_ed_metrics_t, pos: rvn_ed_pos_t, rows: c_int) rvn_ed_pos_t {
    const point = rvn_ed_pos_point(ed, m, pos);
    const global: c_int = @as(c_int, @intCast(rvn_ed_first_row(ed, pos.line) + @as(u32, @intCast(rvn_ed_row_of(ed, pos.line, pos.column))))) + rows;
    if (ed.*.goal_x < 0.0) ed.*.goal_x = point.x;
    if (global < 0) return rvn_ed_pos(0, 0);
    if (global >= @as(c_int, @intCast(ed.*.total_rows))) return rvn_ed_end(ed);
    return rvn_ed_point_pos(ed, m, ed.*.goal_x, (@as(f32, @floatFromInt(global)) + 0.5) * m.*.line_height);
}

fn rvn_ed_copy(ed: [*c]const rvn_text_editor_t) void {
    if (rvn_ed_has_selection(ed) == 0) return;
    const text = rvn_ed_range(ed, rvn_ed_sel_min(ed), rvn_ed_sel_max(ed), null);
    raven.Rclipboard_set_text(text);
    base.rvn_free(text);
}

/// Replaces the selection by a text, as one step of the history.
fn rvn_ed_insert(ed: [*c]rvn_text_editor_t, text: [*c]const u8, length: c_int) void {
    const r = rvn_ed_replace(ed, rvn_ed_sel_min(ed), rvn_ed_sel_max(ed), text, length, R_TRUE);
    ed.*.caret = r;
    ed.*.anchor = r;
}

fn rvn_ed_delete_selection(ed: [*c]rvn_text_editor_t) c_int {
    if (rvn_ed_has_selection(ed) == 0) return R_FALSE;
    rvn_ed_insert(ed, "", 0);
    return R_TRUE;
}

/// Tab and Shift+Tab over a selection of several lines: one level in or out for each of them.
fn rvn_ed_indent_lines(ed: [*c]rvn_text_editor_t, outdent: c_int) void {
    const from = rvn_ed_sel_min(ed);
    const to = rvn_ed_sel_max(ed);
    const first = from.line;
    var last = to.line;
    var length: c_int = 0;
    var cap: c_int = 0;
    var out: [*c]u8 = null;
    var unit: [17]u8 = undefined;
    var unit_length: c_int = 1;

    // a selection that ends at the start of a line does not include that line
    if (last > first and to.column == 0) last -= 1;
    unit[0] = '\t';
    if (ed.*.tab_spaces != 0) {
        unit_length = base.rvn_clampi(ed.*.tab_size, 1, 16);
        cmemset(&unit, ' ', @intCast(unit_length));
    }
    var line: c_int = first;
    while (line <= last) : (line += 1) {
        const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
        var skip: c_int = 0;
        var add: c_int = 0;
        if (outdent != 0) {
            if (l.*.length > 0 and l.*.text[0] == '\t') {
                skip = 1;
            } else {
                while (skip < l.*.length and skip < ed.*.tab_size and l.*.text[@intCast(skip)] == ' ') skip += 1;
            }
        } else if (l.*.length > 0) {
            add = unit_length;
        }
        if (length + add + (l.*.length - skip) + 2 > cap) {
            cap = (length + add + l.*.length + 2) * 2;
            out = ccast([*c]u8, base.rvn_realloc(out, @intCast(cap)));
        }
        cmemcpy(out + @as(usize, @intCast(length)), &unit, @intCast(add));
        length += add;
        cmemcpy(out + @as(usize, @intCast(length)), l.*.text + @as(usize, @intCast(skip)), @intCast(l.*.length - skip));
        length += l.*.length - skip;
        if (line < last) {
            out[@intCast(length)] = '\n';
            length += 1;
        }
    }
    rvn_ed_break_typing(ed);
    const src: [*c]const u8 = if (out != null) out else "";
    _ = rvn_ed_replace(ed, rvn_ed_pos(first, 0), rvn_ed_pos(last, ed.*.lines[@intCast(last)].length), src, length, R_TRUE);
    rvn_ed_break_typing(ed);
    base.rvn_free(out);
    // the lines stay selected, to indent again
    ed.*.anchor = rvn_ed_pos(first, 0);
    ed.*.caret = if (last + 1 < @as(c_int, @intCast(ed.*.line_count)) and to.column == 0 and to.line > first)
        rvn_ed_pos(last + 1, 0)
    else
        rvn_ed_pos(last, ed.*.lines[@intCast(last)].length);
}

// ---------------------------------------------------------------------------
//  Help while typing: indentation, pairs, comments
// -------------------------------------------------------------------------

/// One level of indentation, as the Tab key writes it. Returns its length.
fn rvn_ed_indent_unit(ed: [*c]const rvn_text_editor_t, unit: *[17]u8) c_int {
    var length: c_int = 1;
    unit[0] = '\t';
    if (ed.*.tab_spaces != 0) {
        length = base.rvn_clampi(ed.*.tab_size, 1, 16);
        cmemset(unit, ' ', @intCast(length));
    }
    unit[@intCast(length)] = 0;
    return length;
}

fn rvn_ed_is_blank(c: u8) c_int {
    return @intFromBool(c == ' ' or c == '\t');
}

/// The character that closes an opening bracket or quote, or 0.
fn rvn_ed_closer(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        '`' => '`',
        else => 0,
    };
}

/// Enter: the new line starts with the indentation of the one it comes from,
/// one level deeper after an opening bracket (or a colon in Python, or an
/// opening tag). Between a bracket and the one that closes it, the closing
/// one goes down to a line of its own.
fn rvn_ed_new_line(ed: [*c]rvn_text_editor_t) void {
    const from = rvn_ed_sel_min(ed);
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(from.line)];
    const desc = if (ed.*.no_pairs != 0) null else rvn_ed_language_desc(ed);
    var buffer: [320]u8 = undefined;
    var unit: [17]u8 = undefined;
    var indent: c_int = 0;
    var length: c_int = 0;
    const unit_length = rvn_ed_indent_unit(ed, &unit);
    var deeper: c_int = R_FALSE;
    var split: c_int = R_FALSE;

    while (indent < line.*.length and indent < from.column and indent < 128 and rvn_ed_is_blank(line.*.text[@intCast(indent)]) != 0) indent += 1;
    if (desc != null and rvn_ed_has_selection(ed) == 0) {
        var last = from.column;
        const after: u8 = if (from.column < line.*.length) line.*.text[@intCast(from.column)] else 0;
        while (last > 0 and rvn_ed_is_blank(line.*.text[@intCast(last - 1)]) != 0) last -= 1;
        const before: u8 = if (last > 0) line.*.text[@intCast(last - 1)] else 0;
        if (before == '{' or before == '[' or before == '(') {
            deeper = R_TRUE;
            split = @intFromBool(after != 0 and after == rvn_ed_closer(before));
        } else if (before == ':' and hasFlag(desc.*.flags, raven.R_LANGUAGE_INDENT_ON_COLON)) {
            deeper = R_TRUE;
        } else if (before == '>' and hasFlag(desc.*.flags, raven.R_LANGUAGE_MARKUP) and last >= 2 and line.*.text[@intCast(last - 2)] != '/') {
            // after an opening tag, not after a closing one
            var open: c_int = last - 2;
            while (open > 0 and line.*.text[@intCast(open)] != '<') open -= 1;
            if (line.*.text[@intCast(open)] == '<' and line.*.text[@intCast(open + 1)] != '/' and line.*.text[@intCast(open + 1)] != '!' and line.*.text[@intCast(open + 1)] != '?') {
                deeper = R_TRUE;
                split = @intFromBool(after == '<' and from.column + 1 < line.*.length and line.*.text[@intCast(from.column + 1)] == '/');
            }
        }
    }
    buffer[@intCast(length)] = '\n';
    length += 1;
    cmemcpy(buffer[@intCast(length)..].ptr, line.*.text, @intCast(indent));
    length += indent;
    if (deeper != 0) {
        cmemcpy(buffer[@intCast(length)..].ptr, &unit, @intCast(unit_length));
        length += unit_length;
    }
    if (split != 0) {
        buffer[@intCast(length)] = '\n';
        length += 1;
        cmemcpy(buffer[@intCast(length)..].ptr, line.*.text, @intCast(indent));
        length += indent;
    }
    rvn_ed_break_typing(ed);
    rvn_ed_insert(ed, &buffer, length);
    rvn_ed_break_typing(ed);
    if (split != 0) {
        const p = rvn_ed_pos(from.line + 1, indent + unit_length);
        ed.*.caret = p;
        ed.*.anchor = p;
    }
}

/// Is a quote character one that the language writes its texts with?
fn rvn_ed_is_quote(desc: [*c]const raven.RLanguageDesc, c: u8) c_int {
    if (c != '"' and c != '\'' and c != '`') return R_FALSE;
    if (hasFlag(desc.*.flags, raven.R_LANGUAGE_MARKUP)) return @intFromBool(c != '`');
    // (an apostrophe is rarely the start of a text where it holds a single character)
    if (c == '\'' and hasFlag(desc.*.flags, raven.R_LANGUAGE_CHAR_LITERALS)) return R_FALSE;
    if (desc.*.string_quotes != null and libc.strchr(desc.*.string_quotes, c) != null) return R_TRUE;
    // or one of the marks of its texts that span lines, when it is this character alone (a backquote)
    if (desc.*.multiline_strings != null) {
        var mark: [*c]const u8 = desc.*.multiline_strings;
        while (mark[0] != 0) {
            if (mark[0] == c and (mark == desc.*.multiline_strings or (mark - 1)[0] == ' ') and (mark[1] == ' ' or mark[1] == 0)) return R_TRUE;
            mark += 1;
        }
    }
    return R_FALSE;
}

/// Elements of HTML that have no closing tag.
fn rvn_ed_is_void_tag(name: [*c]const u8, length: c_int) c_int {
    const tags = [_][*c]const u8{ "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr" };
    for (tags) |tag| {
        if (@as(c_int, @intCast(libc.strlen(tag))) == length and base.rvn_strnicmp(tag, name, @intCast(length)) == 0) return R_TRUE;
    }
    return R_FALSE;
}

/// A character typed by the user: with a language, brackets and quotes come in pairs.
fn rvn_ed_type(ed: [*c]rvn_text_editor_t, codepoint: u32) void {
    const desc = if (ed.*.no_pairs != 0) null else rvn_ed_language_desc(ed);
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(ed.*.caret.line)];
    const selection = rvn_ed_has_selection(ed) != 0;
    var encoded: [4]u8 = undefined;
    const length = base.rvn_utf8_encode(codepoint, &encoded);
    const c: u8 = if (codepoint < 128) @intCast(codepoint) else 0;
    const next: u8 = if (!selection and ed.*.caret.column < line.*.length) line.*.text[@intCast(ed.*.caret.column)] else 0;
    const previous: u8 = if (!selection and ed.*.caret.column > 0) line.*.text[@intCast(ed.*.caret.column - 1)] else 0;
    const closer_c = rvn_ed_closer(c);
    const is_q = desc != null and rvn_ed_is_quote(desc, c) != 0;
    const room = next == 0 or rvn_ed_is_blank(next) != 0 or libc.strchr(")]}>,;", next) != null;

    if (desc == null or c == 0) {
        rvn_ed_insert(ed, &encoded, length);
        return;
    }
    // the closing character is already there: step over it
    if (!selection and next == c and (c == ')' or c == ']' or c == '}' or is_q)) {
        const p = rvn_ed_pos(ed.*.caret.line, ed.*.caret.column + 1);
        ed.*.caret = p;
        ed.*.anchor = p;
        return;
    }
    if (closer_c != 0 and (is_q or c == '(' or c == '[' or c == '{')) {
        if (selection) {
            // around what is selected
            const inner = rvn_ed_range(ed, rvn_ed_sel_min(ed), rvn_ed_sel_max(ed), null);
            const inner_length: usize = libc.strlen(inner);
            const wrapped: [*c]u8 = ccast([*c]u8, base.rvn_alloc(inner_length + 3));
            wrapped[0] = c;
            cmemcpy(wrapped + 1, inner, inner_length);
            wrapped[inner_length + 1] = closer_c;
            wrapped[inner_length + 2] = 0;
            rvn_ed_break_typing(ed);
            rvn_ed_insert(ed, wrapped, @as(c_int, @intCast(inner_length)) + 2);
            rvn_ed_break_typing(ed);
            base.rvn_free(wrapped);
            base.rvn_free(inner);
            return;
        }
        // in a comment or in a text, a bracket is only a character
        if (room and rvn_ed_is_code(ed, ed.*.caret.line, base.rvn_maxi(ed.*.caret.column - 1, 0)) != 0 and
            (is_q == false or (rvn_ed_class(previous) != RVN_ED_WORD and previous != c and previous != '\\')))
        {
            var pair: [2]u8 = .{ c, closer_c };
            rvn_ed_break_typing(ed);
            rvn_ed_insert(ed, &pair, 2);
            rvn_ed_break_typing(ed);
            const p = rvn_ed_pos(ed.*.caret.line, ed.*.caret.column - 1);
            ed.*.caret = p;
            ed.*.anchor = p;
            return;
        }
    }
    if (c == '}' and !selection and ed.*.caret.column > 0) {
        // alone on its line, a closing brace comes back one level
        const column = ed.*.caret.column;
        var cut: c_int = 0;
        var blank: c_int = R_TRUE;
        var i: c_int = 0;
        while (i < column and blank != 0) : (i += 1) blank = rvn_ed_is_blank(line.*.text[@intCast(i)]);
        if (blank != 0) {
            if (line.*.text[@intCast(column - 1)] == '\t') {
                cut = 1;
            } else {
                while (cut < ed.*.tab_size and cut < column and line.*.text[@intCast(column - 1 - cut)] == ' ') cut += 1;
            }
            rvn_ed_break_typing(ed);
            const r = rvn_ed_replace(ed, rvn_ed_pos(ed.*.caret.line, column - cut), ed.*.caret, "}", 1, R_TRUE);
            ed.*.caret = r;
            ed.*.anchor = r;
            rvn_ed_break_typing(ed);
            return;
        }
    }
    if (c == '>' and !selection and hasFlag(desc.*.flags, raven.R_LANGUAGE_MARKUP) and previous != '/' and previous != '-' and previous != '?') {
        // the end of an opening tag: its closing tag comes with it
        var open: c_int = ed.*.caret.column - 1;
        while (open >= 0 and line.*.text[@intCast(open)] != '<' and line.*.text[@intCast(open)] != '>') open -= 1;
        if (open >= 0 and line.*.text[@intCast(open)] == '<' and open + 1 < ed.*.caret.column and rvn_ed_class(line.*.text[@intCast(open + 1)]) == RVN_ED_WORD) {
            var name_end: c_int = open + 1;
            while (name_end < ed.*.caret.column and rvn_ed_is_blank(line.*.text[@intCast(name_end)]) == 0) name_end += 1;
            if (!(hasFlag(desc.*.flags, raven.R_LANGUAGE_EMBEDS) and rvn_ed_is_void_tag(at(line.*.text, open + 1), name_end - open - 1) != 0) and name_end - open < 80) {
                var closing: [96]u8 = undefined;
                const closing_length: c_int = libc.snprintf(&closing, closing.len, "></%.*s>", name_end - open - 1, at(line.*.text, open + 1));
                const caret = ed.*.caret;
                rvn_ed_break_typing(ed);
                rvn_ed_insert(ed, &closing, closing_length);
                rvn_ed_break_typing(ed);
                const p = rvn_ed_pos(caret.line, caret.column + 1);
                ed.*.caret = p;
                ed.*.anchor = p;
                return;
            }
        }
    }
    rvn_ed_insert(ed, &encoded, length);
}

/// Ctrl+/: comments the selected lines out, or back in when they all are. Returns R_FALSE when the language has no such comment.
fn rvn_ed_toggle_comment(ed: [*c]rvn_text_editor_t) c_int {
    const desc = rvn_ed_language_desc(ed);
    const from = rvn_ed_sel_min(ed);
    const to = rvn_ed_sel_max(ed);
    const first = from.line;
    var last = to.line;
    var min_indent: c_int = 1 << 20;
    var all = R_TRUE;
    var any = R_FALSE;
    var length: c_int = 0;
    var cap: c_int = 0;
    var out: [*c]u8 = null;

    if (desc == null or desc.*.line_comment == null) return R_FALSE;
    const mark_length: c_int = @intCast(libc.strlen(desc.*.line_comment));
    if (last > first and to.column == 0) last -= 1;
    var line: c_int = first;
    while (line <= last) : (line += 1) {
        const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
        var indent: c_int = 0;
        while (indent < l.*.length and rvn_ed_is_blank(l.*.text[@intCast(indent)]) != 0) indent += 1;
        if (indent == l.*.length) continue;
        any = R_TRUE;
        if (indent < min_indent) min_indent = indent;
        if (l.*.length - indent < mark_length or libc.memcmp(at(l.*.text, indent), desc.*.line_comment, @intCast(mark_length)) != 0) all = R_FALSE;
    }
    if (any == R_FALSE) return R_TRUE;
    line = first;
    while (line <= last) : (line += 1) {
        const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
        var indent: c_int = 0;
        while (indent < l.*.length and rvn_ed_is_blank(l.*.text[@intCast(indent)]) != 0) indent += 1;
        if (length + l.*.length + mark_length + 4 > cap) {
            cap = (length + l.*.length + mark_length + 4) * 2;
            out = ccast([*c]u8, base.rvn_realloc(out, @intCast(cap)));
        }
        if (indent == l.*.length) {
            cmemcpy(out + @as(usize, @intCast(length)), l.*.text, @intCast(l.*.length));
            length += l.*.length;
        } else if (all != R_FALSE) {
            var skip = indent + mark_length;
            if (skip < l.*.length and l.*.text[@intCast(skip)] == ' ') skip += 1;
            cmemcpy(out + @as(usize, @intCast(length)), l.*.text, @intCast(indent));
            length += indent;
            cmemcpy(out + @as(usize, @intCast(length)), l.*.text + @as(usize, @intCast(skip)), @intCast(l.*.length - skip));
            length += l.*.length - skip;
        } else {
            // the marks line up, at the indentation of the least indented line
            cmemcpy(out + @as(usize, @intCast(length)), l.*.text, @intCast(min_indent));
            length += min_indent;
            cmemcpy(out + @as(usize, @intCast(length)), desc.*.line_comment, @intCast(mark_length));
            length += mark_length;
            out[@intCast(length)] = ' ';
            length += 1;
            cmemcpy(out + @as(usize, @intCast(length)), l.*.text + @as(usize, @intCast(min_indent)), @intCast(l.*.length - min_indent));
            length += l.*.length - min_indent;
        }
        if (line < last) {
            out[@intCast(length)] = '\n';
            length += 1;
        }
    }
    rvn_ed_break_typing(ed);
    const src: [*c]const u8 = if (out != null) out else "";
    _ = rvn_ed_replace(ed, rvn_ed_pos(first, 0), rvn_ed_pos(last, ed.*.lines[@intCast(last)].length), src, length, R_TRUE);
    rvn_ed_break_typing(ed);
    base.rvn_free(out);
    if (first == last and rvn_ed_pos_cmp(from, to) == 0) {
        const p = rvn_ed_clamp(ed, rvn_ed_pos(first, from.column + (if (all != R_FALSE) -(mark_length + 1) else mark_length + 1)));
        ed.*.caret = p;
        ed.*.anchor = p;
    } else {
        ed.*.anchor = rvn_ed_pos(first, 0);
        ed.*.caret = rvn_ed_pos(last, ed.*.lines[@intCast(last)].length);
    }
    return R_TRUE;
}

// ---------------------------------------------------------------------------
//  Proposals (completion)
//
//  The list is a popup of the window, owned by the editor. The editor keeps
//  the keyboard: the popup only takes the keys that move in the list or
//  choose from it, and every character typed narrows the list down.
// -------------------------------------------------------------------------

const RVN_EDC_MAX_ITEMS: u32 = 400;
const RVN_EDC_MAX_ROWS: c_int = 8;

const rvn_edc_item_t = extern struct {
    text: [*c]u8,
    detail: [*c]u8,
    /// 0: given by the application; 1: starts as what was typed; 2: starts so, whatever the case.
    rank: c_int,
    /// When it was added: the proposals of the application stay in the order it gave them.
    order: u32,
};

const rvn_ed_complete_t = extern struct {
    base: widget_h.rvn_widget_t,
    editor: [*c]rvn_text_editor_t,
    items: [*c]rvn_edc_item_t,
    count: u32,
    cap: u32,
    selected: c_int,
    bar: common.rvn_scrollbar_t,
    select_y: raven.RSpring,
    /// Where the word being completed starts, and how many bytes of it are typed.
    start: rvn_ed_pos_t,
    prefix_length: c_int,
    /// R_TRUE while the callback of the application may add proposals.
    collecting: c_int,
};

fn rvn_edc_clear(list: [*c]rvn_ed_complete_t) void {
    var i: u32 = 0;
    while (i < list.*.count) : (i += 1) {
        base.rvn_free(list.*.items[i].text);
        base.rvn_free(list.*.items[i].detail);
    }
    list.*.count = 0;
}

fn rvn_edc_add(list: [*c]rvn_ed_complete_t, text: [*c]const u8, length: c_int, detail: [*c]const u8, rank: c_int) void {
    if (list.*.count >= RVN_EDC_MAX_ITEMS or length <= 0) return;
    base.RVN_ARRAY_RESERVE(&list.*.items, &list.*.cap, list.*.count + 1);
    const item: [*c]rvn_edc_item_t = &list.*.items[list.*.count];
    list.*.count += 1;
    item.*.text = base.rvn_strndup(text, @intCast(length));
    item.*.detail = if (detail != null) base.rvn_strdup(detail) else null;
    item.*.rank = rank;
    item.*.order = list.*.count;
}

fn rvn_edc_compare(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: [*c]const rvn_edc_item_t = ccast([*c]const rvn_edc_item_t, a);
    const y: [*c]const rvn_edc_item_t = ccast([*c]const rvn_edc_item_t, b);
    if (x.*.rank != y.*.rank) return if (x.*.rank < y.*.rank) -1 else 1;
    if (x.*.rank == 0) {
        if (x.*.order < y.*.order) return -1;
        if (x.*.order > y.*.order) return 1;
        return 0;
    }
    var order = base.rvn_stricmp(x.*.text, y.*.text);
    if (order == 0) order = libc.strcmp(x.*.text, y.*.text);
    // the same word twice: the one that says what it is comes first, and is the one kept
    if (order == 0) order = (if (x.*.detail != null) @as(c_int, 0) else 1) - (if (y.*.detail != null) @as(c_int, 0) else 1);
    return order;
}

fn rvn_edc_row_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT);
}

fn rvn_edc_pad(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return if (widget_h.rvn_widget_glass(widget) != 0) 5.0 else 1.0;
}

fn rvn_edc_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    const font = ext.rvn_font_resolve(ext.g_rvn.mono_font);
    const size = common.rvn_widget_font_size(widget, 0.0);
    var width: f32 = 0.0;
    const rows: u32 = if (list.*.count < @as(u32, @intCast(RVN_EDC_MAX_ROWS))) list.*.count else @intCast(RVN_EDC_MAX_ROWS);
    var i: u32 = 0;
    while (i < list.*.count and i < 64) : (i += 1) {
        var item = ext.rvn_text_width(font, size, list.*.items[i].text, -1);
        if (list.*.items[i].detail != null) {
            item += common.rvn_widget_text_width(widget, R_INVALID_ID, 0.0, list.*.items[i].detail) + 28.0;
        }
        if (item > width) width = item;
    }
    width = base.rvn_clampf(width + ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 2.0 + 14.0, 180.0, 460.0);
    return base.rvn_vec2(@ceil(width), rvn_edc_row_height(widget) * @as(f32, @floatFromInt(if (rows != 0) rows else 1)) + rvn_edc_pad(widget) * 2.0);
}

fn rvn_edc_reveal(widget: [*c]widget_h.rvn_widget_t) void {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    const row = rvn_edc_row_height(widget);
    const top = row * @as(f32, @floatFromInt(list.*.selected));
    if (top < list.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top);
    } else if (top + row > list.*.bar.offset + list.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&list.*.bar, top + row - list.*.bar.viewport);
    }
}

fn rvn_edc_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    list.*.bar.content = rvn_edc_row_height(widget) * @as(f32, @floatFromInt(list.*.count));
    list.*.bar.viewport = base.rvn_maxf(0.0, widget.*.rect.h - rvn_edc_pad(widget) * 2.0);
    _ = common.rvn_scrollbar_clamp(&list.*.bar);
    rvn_edc_reveal(widget);
}

fn rvn_edc_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    const pad = rvn_edc_pad(widget);
    return base.rvn_rect(widget.*.rect.w - bar - 1.0, pad, bar, base.rvn_maxf(0.0, widget.*.rect.h - pad * 2.0));
}

fn rvn_edc_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const row = rvn_edc_row_height(widget);
    const padding = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 0.8;
    const radius = ext.rvn_widget_metric(widget, raven.R_METRIC_POPUP_RADIUS);
    const pad = rvn_edc_pad(widget);
    const size = common.rvn_widget_font_size(widget, 0.0);
    const offset = common.rvn_scrollbar_shown(&list.*.bar, painter);
    const font = ext.rvn_font_resolve(ext.g_rvn.mono_font);
    const text_color = ext.rvn_widget_color(widget, raven.R_COLOR_TEXT);
    const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_HOVERED);
    const origin = ext.rvn_widget_origin(widget);
    const first: c_int = @intFromFloat(@floor(offset / row));

    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_POPUP, 0.0, 0.0);
    } else {
        ext.rvn_paint_shadow(painter, base.rvn_rect(0.0, 3.0, rect.w, rect.h), radius, 12.0, ext.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
        ext.rvn_paint_box(painter, rect, radius, ext.rvn_widget_color(widget, raven.R_COLOR_POPUP), 1.0, ext.rvn_widget_color(widget, raven.R_COLOR_POPUP_BORDER));
    }
    ext.rvn_paint_push_clip(painter, base.rvn_rect(1.0, pad, rect.w - 2.0, rect.h - pad * 2.0));
    if (list.*.selected >= 0 and list.*.selected < @as(c_int, @intCast(list.*.count))) {
        const y = ext.rvn_paint_spring(painter, &list.*.select_y, row * @as(f32, @floatFromInt(list.*.selected)), raven.R_MOTION_SNAPPY);
        common.rvn_paint_row(painter, widget, base.rvn_rect(1.0, pad + y - offset, rect.w - 2.0, row), ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION));
    }
    const last: c_int = base.rvn_mini(@intCast(list.*.count), first + @as(c_int, @intFromFloat(list.*.bar.viewport / row)) + 3);
    var i: c_int = base.rvn_maxi(first, 0);
    while (i < last) : (i += 1) {
        const item: [*c]const rvn_edc_item_t = &list.*.items[@intCast(i)];
        const line = base.rvn_rect(padding, pad + row * @as(f32, @floatFromInt(i)) - offset, rect.w - padding * 2.0, row);
        const typed = base.rvn_mini(list.*.prefix_length, @intCast(libc.strlen(item.*.text)));
        const typed_width = ext.rvn_text_width(font, size, item.*.text, typed);
        // what is already typed stands out from what choosing the word would add
        ext.rvn_paint_text_in(painter, ext.g_rvn.mono_font, size, line, 0.0, item.*.text, typed, accent);
        ext.rvn_paint_text_in(painter, ext.g_rvn.mono_font, size, base.rvn_rect(line.x + typed_width, line.y, line.w - typed_width, row), 0.0, at(item.*.text, typed), -1, text_color);
        if (item.*.detail != null) {
            ext.rvn_paint_text_in(painter, R_INVALID_ID, size - 1.0, base.rvn_rect(line.x, line.y, line.w - 6.0, row), 1.0, item.*.detail, -1, base.rvn_color_fade(text_color, 0.5));
        }
    }
    ext.rvn_paint_pop_clip(painter);
    common.rvn_scrollbar_paint(&list.*.bar, widget, painter, rvn_edc_track(widget), R_TRUE, if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0, if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0);
}

fn rvn_ed_completing(ed: [*c]const rvn_text_editor_t) c_int {
    return @intFromBool(ed.*.complete != null and (ed.*.complete.*.flags & widget_h.RVN_WF_POPUP) != 0);
}

fn rvn_ed_complete_close(ed: [*c]rvn_text_editor_t) void {
    if (rvn_ed_completing(ed) != 0 and ed.*.complete.*.window != null) {
        ext.rvn_window_close_popup(ed.*.complete.*.window, ed.*.complete);
    }
}

/// Puts the chosen word in place of what was typed of it.
fn rvn_ed_complete_accept(ed: [*c]rvn_text_editor_t, index: c_int) void {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, ed.*.complete);
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    if (list == null or index < 0 or index >= @as(c_int, @intCast(list.*.count))) return;
    const text = base.rvn_strdup(list.*.items[@intCast(index)].text);
    rvn_ed_complete_close(ed);
    if (list.*.start.line == ed.*.caret.line and list.*.start.column <= ed.*.caret.column and ed.*.read_only == 0) {
        rvn_ed_break_typing(ed);
        const r = rvn_ed_replace(ed, list.*.start, ed.*.caret, text, -1, R_TRUE);
        ed.*.caret = r;
        ed.*.anchor = r;
        rvn_ed_break_typing(ed);
        rvn_ed_caret_moved(ed, R_FALSE);
        base.rvn_free(text);
        rvn_ed_notify(widget);
        return;
    }
    base.rvn_free(text);
}

fn rvn_edc_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    const count: c_int = @intCast(list.*.count);
    var changed: c_int = R_FALSE;
    const pad = rvn_edc_pad(widget);
    const etype: c_int = @intCast(event.*.type);

    if (etype == raven.R_EVENT_MOUSE_DOWN or etype == raven.R_EVENT_MOUSE_MOVE or etype == raven.R_EVENT_MOUSE_UP) {
        if (common.rvn_scrollbar_event(&list.*.bar, widget, event, rvn_edc_track(widget), R_TRUE, &changed) != 0) {
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        }
    }
    switch (etype) {
        raven.R_EVENT_MOUSE_DOWN => {
            if (@as(c_int, @intCast(event.*.button)) != raven.R_MOUSE_LEFT) return R_TRUE;
            const row: c_int = @intFromFloat(@floor((event.*.local_y - pad + list.*.bar.offset) / rvn_edc_row_height(widget)));
            if (row >= 0 and row < count) rvn_ed_complete_accept(list.*.editor, row);
            return R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            _ = common.rvn_scrollbar_wheel(&list.*.bar, -event.*.wheel_y * rvn_edc_row_height(widget) * 3.0);
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if (count == 0 or hasFlag(event.*.modifiers, raven.R_MOD_CTRL) or hasFlag(event.*.modifiers, raven.R_MOD_ALT) or
                hasFlag(event.*.modifiers, raven.R_MOD_SUPER)) return R_FALSE;
            var row: c_int = undefined;
            switch (@as(c_int, @intCast(event.*.key))) {
                raven.R_KEY_UP => row = if (list.*.selected <= 0) count - 1 else list.*.selected - 1,
                raven.R_KEY_DOWN => row = if (list.*.selected + 1 >= count) 0 else list.*.selected + 1,
                raven.R_KEY_PAGE_UP => row = base.rvn_maxi(list.*.selected - RVN_EDC_MAX_ROWS + 1, 0),
                raven.R_KEY_PAGE_DOWN => row = base.rvn_mini(list.*.selected + RVN_EDC_MAX_ROWS - 1, count - 1),
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER, raven.R_KEY_TAB => {
                    rvn_ed_complete_accept(list.*.editor, list.*.selected);
                    return R_TRUE;
                },
                // everything else is for the editor: typing goes on
                else => return R_FALSE,
            }
            list.*.selected = row;
            rvn_edc_reveal(widget);
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        },
        else => return R_FALSE,
    }
}

fn rvn_edc_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, widget);
    rvn_edc_clear(list);
    base.rvn_free(list.*.items);
}

const rvn_class_ed_complete: widget_h.rvn_widget_class_t = .{
    .type = common.RVN_WIDGET_INTERNAL_COMPLETION,
    .name = "TextEditorCompletion",
    .size = @sizeOf(rvn_ed_complete_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_NO_MIRROR,
    .destroy = rvn_edc_destroy,
    .measure = rvn_edc_measure,
    .arrange = rvn_edc_arrange,
    .paint = rvn_edc_paint,
    .event = rvn_edc_event,
    .init = null,
    .set_attribute = null,
    .paint_overlay = null,
    .child_active = null,
    .child_at = null,
    .children_changed = null,
    .xml_child = null,
    .popup_closed = null,
    .window_drag_at = null,
};

fn rvn_ed_is_word_char(c: u8) c_int {
    return @intFromBool((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$' or c >= 0x80);
}

/// Adds the names of the text that start with `prefix`, from the lines around the caret.
fn rvn_ed_complete_document(ed: [*c]rvn_text_editor_t, list: [*c]rvn_ed_complete_t, prefix: [*c]const u8, prefix_length: c_int) void {
    const first = base.rvn_maxi(ed.*.caret.line - 4000, 0);
    const last = base.rvn_mini(ed.*.caret.line + 4000, @as(c_int, @intCast(ed.*.line_count)) - 1);
    var line: c_int = first;
    while (line <= last and list.*.count < RVN_EDC_MAX_ITEMS) : (line += 1) {
        const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
        var i: c_int = 0;
        while (i < l.*.length) {
            if (rvn_ed_is_word_char(l.*.text[@intCast(i)]) == 0) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < l.*.length and rvn_ed_is_word_char(l.*.text[@intCast(i)]) != 0) i += 1;
            // long enough to be worth choosing, not a number, and not the word being typed itself
            if (i - start < 3 or i - start <= prefix_length or (l.*.text[@intCast(start)] >= '0' and l.*.text[@intCast(start)] <= '9')) continue;
            if (line == ed.*.caret.line and start == list.*.start.column) continue;
            if (base.rvn_strnicmp(at(l.*.text, start), prefix, @intCast(prefix_length)) != 0) continue;
            rvn_edc_add(list, at(l.*.text, start), i - start, null, if (libc.memcmp(at(l.*.text, start), prefix, @intCast(prefix_length)) == 0) @as(c_int, 1) else @as(c_int, 2));
        }
    }
}

/// Gathers the proposals for the word before the caret and shows them, or
/// hides the list when there is nothing to propose.
/// mode 0: after a character was typed (two characters at least are needed)
/// mode 1: asked for (Ctrl+Space): any start, even none
/// mode 2: the list is shown and the word changed
fn rvn_ed_complete_update(widget: [*c]widget_h.rvn_widget_t, mode: c_int) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    const language = rvn_ed_language(ed);
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(ed.*.caret.line)];
    const details = [3][*c]const u8{ "keyword", "type", "constant" };
    var prefix: [128]u8 = undefined;
    var start: c_int = ed.*.caret.column;

    if (widget.*.window == null or ed.*.read_only != 0 or rvn_ed_has_selection(ed) != 0 or
        (mode == 0 and (ed.*.no_completion != 0 or language == null)))
    {
        rvn_ed_complete_close(ed);
        return;
    }
    while (start > 0 and rvn_ed_is_word_char(line.*.text[@intCast(start - 1)]) != 0) start -= 1;
    const prefix_length: c_int = ed.*.caret.column - start;
    if (prefix_length >= @as(c_int, @intCast(prefix.len)) or (mode == 0 and prefix_length < 2) or (mode == 2 and prefix_length < 1) or
        (prefix_length > 0 and line.*.text[@intCast(start)] >= '0' and line.*.text[@intCast(start)] <= '9'))
    {
        rvn_ed_complete_close(ed);
        return;
    }
    cmemcpy(&prefix, at(line.*.text, start), @intCast(prefix_length));
    prefix[@intCast(prefix_length)] = 0;

    if (ed.*.complete == null) {
        ed.*.complete = ext.rvn_widget_create_class(&rvn_class_ed_complete);
        if (ed.*.complete == null) return;
        ed.*.complete.*.flags |= widget_h.RVN_WF_INTERNAL;
        ccast([*c]rvn_ed_complete_t, ed.*.complete).*.editor = ed;
    }
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, ed.*.complete);
    // another word than the one the list was shown for: it moves there
    if (rvn_ed_completing(ed) != 0 and (list.*.start.line != ed.*.caret.line or list.*.start.column != start)) rvn_ed_complete_close(ed);
    rvn_edc_clear(list);
    list.*.start = rvn_ed_pos(ed.*.caret.line, start);
    list.*.prefix_length = prefix_length;

    if (ed.*.completion_callback) |callback| {
        const id = widget.*.id;
        list.*.collecting = R_TRUE;
        callback(id, &prefix, ed.*.completion_user);
        if (ext.rvn_widget_get(id) == null) return;
        list.*.collecting = R_FALSE;
    }
    if (language) |lang| {
        var k: c_int = 0;
        while (k < 3) : (k += 1) {
            const count = common.rvn_language_word_count(lang, k);
            var i: c_int = 0;
            while (i < count) : (i += 1) {
                const word = common.rvn_language_word(lang, k, i);
                if (@as(c_int, @intCast(libc.strlen(word))) <= prefix_length or base.rvn_strnicmp(word, &prefix, @intCast(prefix_length)) != 0) continue;
                rvn_edc_add(list, word, @intCast(libc.strlen(word)), details[@intCast(k)], if (libc.memcmp(word, &prefix, @intCast(prefix_length)) == 0) @as(c_int, 1) else @as(c_int, 2));
            }
        }
    }
    if (prefix_length > 0) rvn_ed_complete_document(ed, list, &prefix, prefix_length);

    if (list.*.count > 1) libc.qsort(list.*.items, list.*.count, @sizeOf(rvn_edc_item_t), rvn_edc_compare);
    var write: u32 = 0;
    var read: u32 = 0;
    while (read < list.*.count) {
        var twice = write > 0 and libc.strcmp(list.*.items[write - 1].text, list.*.items[read].text) == 0;
        // (what the application proposed is not listed a second time among the words of the language or of the text)
        var given: u32 = 0;
        while (!twice and given < write and list.*.items[given].rank == 0) : (given += 1) {
            twice = libc.strcmp(list.*.items[given].text, list.*.items[read].text) == 0;
        }
        if (twice) {
            base.rvn_free(list.*.items[read].text);
            base.rvn_free(list.*.items[read].detail);
            read += 1;
            continue;
        }
        list.*.items[write] = list.*.items[read];
        write += 1;
        read += 1;
    }
    list.*.count = write;
    if (list.*.count == 0) {
        rvn_ed_complete_close(ed);
        return;
    }
    list.*.selected = 0;
    list.*.bar.offset = 0.0;
    list.*.select_y.started = R_FALSE;
    list.*.base.material = widget.*.material;

    if (rvn_ed_completing(ed) == 0) {
        var m: rvn_ed_metrics_t = undefined;
        const origin = ext.rvn_widget_origin(widget);
        rvn_ed_metrics(ed, &m);
        rvn_ed_update_rows(ed, &m);
        const point = rvn_ed_pos_point(ed, &m, list.*.start);
        ext.rvn_window_open_popup(widget.*.window, ed.*.complete, widget, base.rvn_rect(origin.x + m.area.x + point.x - ed.*.hbar.offset - 6.0, origin.y + m.area.y + point.y - ed.*.vbar.offset, 10.0, m.line_height + 3.0), widget_h.RVN_POPUP_BELOW, 0.0);
    }
    ext.rvn_widget_invalidate_layout(ed.*.complete);
    widget.*.window.*.needs_layout = R_TRUE;
}

/// The marker under a point of the text, or NULL.
fn rvn_ed_marker_at(ed: [*c]const rvn_text_editor_t, pos: rvn_ed_pos_t) [*c]const rvn_ed_marker_t {
    var i: u32 = 0;
    while (i < ed.*.marker_count) : (i += 1) {
        const marker: [*c]const rvn_ed_marker_t = &ed.*.markers[i];
        if (marker.*.line != pos.line or pos.column < marker.*.from) continue;
        if (marker.*.to < 0 or pos.column <= marker.*.to) return marker;
    }
    return null;
}

/// Is the caret between an opening bracket or quote and the one that closes it, with nothing in between?
fn rvn_ed_between_pair(ed: [*c]rvn_text_editor_t) c_int {
    const desc = if (ed.*.no_pairs != 0) null else rvn_ed_language_desc(ed);
    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(ed.*.caret.line)];
    if (desc == null or ed.*.caret.column <= 0 or ed.*.caret.column >= line.*.length) return R_FALSE;
    const before = line.*.text[@intCast(ed.*.caret.column - 1)];
    const after = line.*.text[@intCast(ed.*.caret.column)];
    if (rvn_ed_closer(before) == 0 or rvn_ed_closer(before) != after) return R_FALSE;
    return @intFromBool(before == '(' or before == '[' or before == '{' or rvn_ed_is_quote(desc, before) != 0);
}

fn rvn_ed_blink(timer: Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = ext.rvn_widget_get(@intCast(@intFromPtr(user_data)));
    _ = timer;
    if (widget != null) ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_ed_set_focused(widget: [*c]widget_h.rvn_widget_t, focused: c_int) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    if (focused != 0) {
        ed.*.blink_start = ext.rvn_clock_seconds();
        if (ed.*.blink_timer == R_INVALID_ID) {
            ed.*.blink_timer = raven.Rtimer_create(0.5, R_TRUE, rvn_ed_blink, @ptrFromInt(@as(usize, widget.*.id)));
        }
    } else {
        if (ed.*.blink_timer != R_INVALID_ID) {
            if (raven.Rtimer_is_valid(ed.*.blink_timer) != 0) raven.Rtimer_destroy(ed.*.blink_timer);
            ed.*.blink_timer = R_INVALID_ID;
        }
        ed.*.selecting = R_FALSE;
        rvn_ed_break_typing(ed);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

/// Moves the caret to `target`, extending the selection with Shift.
fn rvn_ed_go(ed: [*c]rvn_text_editor_t, target: rvn_ed_pos_t, extend: c_int, keep_goal: c_int) void {
    ed.*.caret = rvn_ed_clamp(ed, target);
    if (extend == 0) ed.*.anchor = ed.*.caret;
    rvn_ed_break_typing(ed);
    rvn_ed_complete_close(ed);
    rvn_ed_caret_moved(ed, keep_goal);
}

// ---------------------------------------------------------------------------
//  Zoom
// -------------------------------------------------------------------------

const RVN_ED_ZOOM_MIN: f32 = 0.5;
const RVN_ED_ZOOM_MAX: f32 = 4.0;
/// one notch of the wheel, one press of Ctrl + '+'
const RVN_ED_ZOOM_STEP: f32 = 1.1;

/// Zooms the text, the point (anchor_x, anchor_y) of the widget staying over
/// the same text: under the pointer for the wheel, at the caret for the keys.
/// Returns R_TRUE when the zoom changed; `notify` calls the zoom callback.
fn rvn_ed_set_zoom(ed: [*c]rvn_text_editor_t, zoom_in: f32, anchor_x: f32, anchor_y: f32, notify: c_int) c_int {
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    const before_zoom: f32 = if (ed.*.zoom > 0.0) ed.*.zoom else 1.0;
    var zoom = base.rvn_clampf(zoom_in, RVN_ED_ZOOM_MIN, RVN_ED_ZOOM_MAX);
    // (back to 100 % when it passes near it: the wheel finds it again)
    if (@abs(zoom - 1.0) < 0.03) zoom = 1.0;
    zoom = @floor(zoom * 100.0 + 0.5) / 100.0;
    if (@abs(zoom - before_zoom) < 0.001) return R_FALSE;

    var before: rvn_ed_metrics_t = undefined;
    var after: rvn_ed_metrics_t = undefined;
    rvn_ed_metrics(ed, &before);
    rvn_ed_update_rows(ed, &before);
    const ax = base.rvn_clampf(anchor_x - before.area.x, 0.0, before.area.w);
    const ay = base.rvn_clampf(anchor_y - before.area.y, 0.0, before.area.h);
    // What is under the anchor: a place in the text, and where in its row (a
    // fraction of the row, a width in font sizes). Rows would not do: with
    // word wrap, the lines do not have the same rows at another size.
    const tx = ed.*.hbar.offset + ax;
    const ty = ed.*.vbar.offset + ay;
    const pos = rvn_ed_point_pos(ed, &before, tx, ty);
    var point = rvn_ed_pos_point(ed, &before, pos);
    const fy = (ty - point.y) / before.line_height;
    const fx = (tx - point.x) / before.size;

    ed.*.zoom = zoom;
    rvn_ed_relayout(ed);
    rvn_ed_metrics(ed, &after);
    rvn_ed_update_rows(ed, &after);
    // (the gutter of the line numbers grows with the text: measured again)
    rvn_ed_metrics(ed, &after);
    rvn_ed_update_bars(ed, &after);
    // the same place of the text under the anchor again
    point = rvn_ed_pos_point(ed, &after, pos);
    _ = common.rvn_scrollbar_set(&ed.*.vbar, point.y + fy * after.line_height - ay);
    if (ed.*.wrap == 0) _ = common.rvn_scrollbar_set(&ed.*.hbar, point.x + fx * after.size - ax);
    // no glide from where things were at the other size: they are drawn in their place at once
    ed.*.vbar.shown.started = R_FALSE;
    ed.*.hbar.shown.started = R_FALSE;
    ed.*.caret_x.started = R_FALSE;
    ed.*.caret_y.started = R_FALSE;
    rvn_ed_complete_close(ed);
    ext.rvn_widget_invalidate_paint(widget);
    if (notify != 0) {
        if (ed.*.zoom_callback) |callback| callback(widget.*.id, zoom, ed.*.zoom_user);
    }
    return R_TRUE;
}

/// Ctrl + '+' (or '='), Ctrl + '-', Ctrl + 0, also on the keypad: around the caret, or the middle when it is out of view.
fn rvn_ed_zoom_key(ed: [*c]rvn_text_editor_t, event: [*c]const raven.REvent) c_int {
    const zoom: f32 = if (ed.*.zoom > 0.0) ed.*.zoom else 1.0;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var m: rvn_ed_metrics_t = undefined;
    const key: c_int = @intCast(event.*.key);
    const zin = key == raven.R_KEY_EQUAL or key == raven.R_KEY_KP_ADD or event.*.codepoint == '+' or event.*.codepoint == '=';
    const zout = key == raven.R_KEY_MINUS or key == raven.R_KEY_KP_SUBTRACT or event.*.codepoint == '-';
    const reset = key == raven.R_KEY_0 or key == raven.R_KEY_KP_0 or event.*.codepoint == '0';
    if (ed.*.no_zoom != 0 or (!hasFlag(event.*.modifiers, raven.R_MOD_CTRL) and !hasFlag(event.*.modifiers, raven.R_MOD_SUPER)) or
        hasFlag(event.*.modifiers, raven.R_MOD_ALT)) return R_FALSE;
    if (!zin and !zout and !reset) return R_FALSE;
    rvn_ed_metrics(ed, &m);
    rvn_ed_update_rows(ed, &m);
    const point = rvn_ed_pos_point(ed, &m, ed.*.caret);
    x = m.area.x + point.x - ed.*.hbar.offset;
    y = m.area.y + point.y - ed.*.vbar.offset;
    if (y < m.area.y or y > m.area.y + m.area.h) {
        x = m.area.x;
        y = m.area.y + m.area.h * 0.5;
    }
    const target: f32 = if (reset) 1.0 else if (zin) zoom * RVN_ED_ZOOM_STEP else zoom / RVN_ED_ZOOM_STEP;
    _ = rvn_ed_set_zoom(ed, target, x, y, R_TRUE);
    return R_TRUE;
}

/// Keys that type a character are consumed so that they never trigger a
/// window shortcut; the character itself arrives as a text event.
fn rvn_ed_printable(key: c_int, command: bool, alt: bool) c_int {
    if (command or alt or key >= 256 or key == raven.R_KEY_UNKNOWN) return R_FALSE;
    return R_TRUE;
}

fn rvn_ed_key(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) c_int {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    const shift = hasFlag(event.*.modifiers, raven.R_MOD_SHIFT);
    const command = hasFlag(event.*.modifiers, raven.R_MOD_CTRL) or hasFlag(event.*.modifiers, raven.R_MOD_SUPER);
    const alt = hasFlag(event.*.modifiers, raven.R_MOD_ALT);
    var changed: c_int = R_FALSE;
    const id = widget.*.id;
    var m: rvn_ed_metrics_t = undefined;
    var target: rvn_ed_pos_t = undefined;
    const key: c_int = @intCast(event.*.key);

    if (rvn_ed_zoom_key(ed, event) != 0) return R_TRUE;

    rvn_ed_metrics(ed, &m);
    rvn_ed_update_rows(ed, &m);

    switch (key) {
        raven.R_KEY_SPACE => {
            if (!command) return rvn_ed_printable(key, command, alt);
            rvn_ed_complete_update(widget, 1);
            return R_TRUE;
        },
        raven.R_KEY_SLASH => {
            if (!command) return rvn_ed_printable(key, command, alt);
            if (ed.*.read_only != 0 or rvn_ed_toggle_comment(ed) == 0) return R_TRUE;
            changed = R_TRUE;
        },
        raven.R_KEY_LEFT => {
            if (!shift and !command and rvn_ed_has_selection(ed) != 0) {
                target = rvn_ed_sel_min(ed);
            } else {
                target = if (command) rvn_ed_word_left(ed, ed.*.caret) else rvn_ed_char_left(ed, ed.*.caret);
            }
            rvn_ed_go(ed, target, @intFromBool(shift), R_FALSE);
            return R_TRUE;
        },
        raven.R_KEY_RIGHT => {
            if (!shift and !command and rvn_ed_has_selection(ed) != 0) {
                target = rvn_ed_sel_max(ed);
            } else {
                target = if (command) rvn_ed_word_right(ed, ed.*.caret) else rvn_ed_char_right(ed, ed.*.caret);
            }
            rvn_ed_go(ed, target, @intFromBool(shift), R_FALSE);
            return R_TRUE;
        },
        raven.R_KEY_UP, raven.R_KEY_DOWN => {
            if (command) {
                // Ctrl + arrows scroll without moving the caret
                _ = common.rvn_scrollbar_wheel(&ed.*.vbar, if (key == raven.R_KEY_UP) -m.line_height else m.line_height);
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            rvn_ed_go(ed, rvn_ed_move_rows(ed, &m, ed.*.caret, if (key == raven.R_KEY_UP) -1 else 1), @intFromBool(shift), R_TRUE);
            return R_TRUE;
        },
        raven.R_KEY_PAGE_UP, raven.R_KEY_PAGE_DOWN => {
            const page = base.rvn_maxi(@as(c_int, @intFromFloat(m.area.h / m.line_height)) - 1, 1);
            rvn_ed_go(ed, rvn_ed_move_rows(ed, &m, ed.*.caret, if (key == raven.R_KEY_PAGE_UP) -page else page), @intFromBool(shift), R_TRUE);
            return R_TRUE;
        },
        raven.R_KEY_HOME => {
            if (command) {
                target = rvn_ed_pos(0, 0);
            } else {
                // the start of the row, or the first character that is not a space when already there
                const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(ed.*.caret.line)];
                var begin: c_int = undefined;
                var end: c_int = undefined;
                rvn_ed_row_range(ed, ed.*.caret.line, rvn_ed_row_of(ed, ed.*.caret.line, ed.*.caret.column), &begin, &end);
                var indent = begin;
                while (indent < end and (line.*.text[@intCast(indent)] == ' ' or line.*.text[@intCast(indent)] == '\t')) indent += 1;
                target = rvn_ed_pos(ed.*.caret.line, if (ed.*.caret.column == indent or indent == end) begin else indent);
            }
            rvn_ed_go(ed, target, @intFromBool(shift), R_FALSE);
            return R_TRUE;
        },
        raven.R_KEY_END => {
            if (command) {
                target = rvn_ed_end(ed);
            } else {
                var begin: c_int = undefined;
                var end: c_int = undefined;
                const row = rvn_ed_row_of(ed, ed.*.caret.line, ed.*.caret.column);
                rvn_ed_row_range(ed, ed.*.caret.line, row, &begin, &end);
                // (the last position of a wrapped row is before its cut)
                if (ed.*.wrap != 0 and row + 1 < ed.*.lines[@intCast(ed.*.caret.line)].row_count and end > begin) {
                    end = base.rvn_utf8_prev(ed.*.lines[@intCast(ed.*.caret.line)].text, end);
                }
                target = rvn_ed_pos(ed.*.caret.line, end);
            }
            rvn_ed_go(ed, target, @intFromBool(shift), R_FALSE);
            return R_TRUE;
        },
        raven.R_KEY_BACKSPACE, raven.R_KEY_DELETE => {
            if (ed.*.read_only != 0) return R_TRUE;
            if (rvn_ed_has_selection(ed) == 0) {
                if (key == raven.R_KEY_BACKSPACE) {
                    ed.*.anchor = if (command) rvn_ed_word_left(ed, ed.*.caret) else rvn_ed_char_left(ed, ed.*.caret);
                } else {
                    ed.*.anchor = if (command) rvn_ed_word_right(ed, ed.*.caret) else rvn_ed_char_right(ed, ed.*.caret);
                }
                if (key == raven.R_KEY_BACKSPACE and !command and rvn_ed_between_pair(ed) != 0) {
                    // a pair with nothing in it goes away as it came: together
                    ed.*.caret = rvn_ed_char_right(ed, ed.*.caret);
                }
            }
            rvn_ed_break_typing(ed);
            changed = rvn_ed_delete_selection(ed);
        },
        raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
            if (ed.*.read_only != 0) return R_TRUE;
            rvn_ed_new_line(ed);
            changed = R_TRUE;
        },
        raven.R_KEY_TAB => {
            if (command or alt) return R_FALSE;
            if (ed.*.read_only != 0) return R_FALSE;
            if (shift or rvn_ed_sel_min(ed).line != rvn_ed_sel_max(ed).line) {
                rvn_ed_indent_lines(ed, @intFromBool(shift));
            } else if (ed.*.tab_spaces != 0) {
                // up to the next tab stop
                var spaces: [16]u8 = undefined;
                const line_text = ed.*.lines[@intCast(rvn_ed_sel_min(ed).line)].text;
                var count = base.rvn_clampi(ed.*.tab_size, 1, 16);
                var columns: c_int = 0;
                var at_col: c_int = 0;
                const stop = rvn_ed_sel_min(ed).column;
                // the column on screen: a tab before the caret counts for what it shows
                while (at_col < stop) {
                    if (line_text[@intCast(at_col)] == '\t') {
                        columns += count - @rem(columns, count);
                    } else {
                        columns += 1;
                    }
                    at_col = base.rvn_utf8_next(line_text, stop, at_col);
                }
                count -= @rem(columns, count);
                cmemset(&spaces, ' ', @intCast(count));
                rvn_ed_break_typing(ed);
                rvn_ed_insert(ed, &spaces, count);
            } else {
                rvn_ed_break_typing(ed);
                rvn_ed_insert(ed, "\t", 1);
            }
            changed = R_TRUE;
        },
        raven.R_KEY_A => {
            if (!command) return rvn_ed_printable(key, command, alt);
            ed.*.anchor = rvn_ed_pos(0, 0);
            ed.*.caret = rvn_ed_end(ed);
            rvn_ed_break_typing(ed);
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        },
        raven.R_KEY_C => {
            if (!command) return rvn_ed_printable(key, command, alt);
            rvn_ed_copy(ed);
            return R_TRUE;
        },
        raven.R_KEY_X => {
            if (!command) return rvn_ed_printable(key, command, alt);
            rvn_ed_copy(ed);
            if (ed.*.read_only != 0) return R_TRUE;
            rvn_ed_break_typing(ed);
            changed = rvn_ed_delete_selection(ed);
        },
        raven.R_KEY_V => {
            if (!command) return rvn_ed_printable(key, command, alt);
            if (ed.*.read_only != 0) return R_TRUE;
            const clip = raven.Rclipboard_get_text();
            if (clip == null or clip[0] == 0) return R_TRUE;
            rvn_ed_break_typing(ed);
            rvn_ed_insert(ed, clip, -1);
            rvn_ed_break_typing(ed);
            changed = R_TRUE;
        },
        raven.R_KEY_Z => {
            if (!command) return rvn_ed_printable(key, command, alt);
            changed = if (shift) rvn_ed_redo(ed) else rvn_ed_undo(ed);
            if (changed == 0) return R_TRUE;
        },
        raven.R_KEY_Y => {
            if (!command) return rvn_ed_printable(key, command, alt);
            changed = rvn_ed_redo(ed);
            if (changed == 0) return R_TRUE;
        },
        else => return rvn_ed_printable(key, command, alt),
    }
    rvn_ed_caret_moved(ed, R_FALSE);
    if (changed != 0) rvn_ed_notify(widget);
    if (ext.rvn_widget_get(id) == null) return R_TRUE;
    // erasing narrows the list of proposals back; anything else is another matter
    if (key == raven.R_KEY_BACKSPACE or key == raven.R_KEY_DELETE) {
        if (rvn_ed_completing(ed) != 0) rvn_ed_complete_update(widget, 2);
    } else {
        rvn_ed_complete_close(ed);
    }
    return R_TRUE;
}

fn rvn_text_editor_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    var m: rvn_ed_metrics_t = undefined;
    var vertical: base.rvn_rect_t = undefined;
    var horizontal: base.rvn_rect_t = undefined;
    var changed: c_int = R_FALSE;
    const etype: c_int = @intCast(event.*.type);

    switch (etype) {
        raven.R_EVENT_FOCUS_GAINED => {
            rvn_ed_set_focused(widget, R_TRUE);
            return R_TRUE;
        },
        raven.R_EVENT_FOCUS_LOST => {
            rvn_ed_complete_close(ed);
            rvn_ed_set_focused(widget, R_FALSE);
            return R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0) return R_FALSE;
            return rvn_ed_key(widget, event);
        },
        raven.R_EVENT_TEXT => {
            const id = widget.*.id;
            const version = ed.*.version;
            if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0 or ed.*.read_only != 0) return R_FALSE;
            if (event.*.codepoint < 32 or event.*.codepoint == 127) return R_FALSE;
            rvn_ed_type(ed, event.*.codepoint);
            rvn_ed_caret_moved(ed, R_FALSE);
            if (ed.*.version != version) rvn_ed_notify(widget);
            if (ext.rvn_widget_get(id) == null) return R_TRUE;
            // each character of a word narrows the proposals down; anything else ends the word
            if (event.*.codepoint >= 128 or rvn_ed_is_word_char(@truncate(event.*.codepoint)) != 0) {
                rvn_ed_complete_update(widget, if (rvn_ed_completing(ed) != 0) 2 else 0);
            } else {
                rvn_ed_complete_close(ed);
            }
            return R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            rvn_ed_complete_close(ed);
            // Ctrl + wheel zooms, around the pointer; it never scrolls what contains the editor
            if (hasFlag(event.*.modifiers, raven.R_MOD_CTRL) and ed.*.no_zoom == 0) {
                const zoom: f32 = if (ed.*.zoom > 0.0) ed.*.zoom else 1.0;
                if (event.*.wheel_y != 0.0) {
                    _ = rvn_ed_set_zoom(ed, zoom * libc.powf(RVN_ED_ZOOM_STEP, event.*.wheel_y), event.*.local_x, event.*.local_y, R_TRUE);
                }
                return R_TRUE;
            }
            rvn_ed_metrics(ed, &m);
            if (hasFlag(event.*.modifiers, raven.R_MOD_SHIFT) and ed.*.wrap == 0) {
                changed = common.rvn_scrollbar_wheel(&ed.*.hbar, -event.*.wheel_y * m.space * 12.0);
            } else {
                changed = common.rvn_scrollbar_wheel(&ed.*.vbar, -event.*.wheel_y * m.line_height * 3.0);
                if (event.*.wheel_x != 0.0 and ed.*.wrap == 0) {
                    changed |= common.rvn_scrollbar_wheel(&ed.*.hbar, -event.*.wheel_x * m.space * 12.0);
                }
            }
            ext.rvn_widget_invalidate_paint(widget);
            // at the end of its range, the wheel goes to what contains the editor
            return changed;
        },
        raven.R_EVENT_MOUSE_DOWN, raven.R_EVENT_MOUSE_MOVE, raven.R_EVENT_MOUSE_UP => {
            var used: c_int = undefined;
            rvn_ed_metrics(ed, &m);
            rvn_ed_update_rows(ed, &m);
            rvn_ed_tracks(ed, &m, &vertical, &horizontal);
            if (ed.*.selecting == 0) {
                used = common.rvn_scrollbar_event(&ed.*.vbar, widget, event, vertical, R_TRUE, &changed);
                if (used == 0 and ed.*.wrap == 0) used = common.rvn_scrollbar_event(&ed.*.hbar, widget, event, horizontal, R_FALSE, &changed);
                if (used != 0) {
                    ext.rvn_widget_invalidate_paint(widget);
                    return R_TRUE;
                }
            }
            if (etype == raven.R_EVENT_MOUSE_UP) {
                if (@as(c_int, @intCast(event.*.button)) != raven.R_MOUSE_LEFT or ed.*.selecting == 0) return R_FALSE;
                ed.*.selecting = R_FALSE;
                ext.rvn_widget_release_mouse(widget);
                return R_TRUE;
            }
            if (etype == raven.R_EVENT_MOUSE_MOVE and ed.*.selecting == 0) {
                if (ed.*.marker_count > 0 or ed.*.marker_tip != 0) {
                    // the message of the marker under the pointer is the tooltip of the editor
                    var marker: [*c]const rvn_ed_marker_t = null;
                    if (base.rvn_rect_contains(m.area, event.*.local_x, event.*.local_y) != 0) {
                        const tx = event.*.local_x - m.area.x + ed.*.hbar.offset;
                        const ty = event.*.local_y - m.area.y + ed.*.vbar.offset;
                        const pos = rvn_ed_point_pos(ed, &m, tx, ty);
                        const point = rvn_ed_pos_point(ed, &m, pos);
                        // (the nearest position is not under the pointer when it is past the end of the line, or below the text)
                        if (ty >= point.y and ty < point.y + m.line_height and @abs(tx - point.x) <= m.space) {
                            marker = rvn_ed_marker_at(ed, pos);
                        }
                    }
                    const message: [*c]const u8 = if (marker != null) marker.*.message else null;
                    const differs = if (message != null)
                        (widget.*.tooltip == null or libc.strcmp(widget.*.tooltip, message) != 0)
                    else
                        ed.*.marker_tip != 0;
                    if (differs) {
                        _ = base.rvn_str_set(&widget.*.tooltip, message);
                        ed.*.marker_tip = @intFromBool(message != null);
                        if (widget.*.window != null) ext.rvn_window_rearm_tooltip(widget.*.window);
                    }
                }
                // the scrollbars react to the pointer
                ext.rvn_widget_invalidate_paint(widget);
                return R_FALSE;
            }
            if (etype == raven.R_EVENT_MOUSE_DOWN and @as(c_int, @intCast(event.*.button)) != raven.R_MOUSE_LEFT) return R_FALSE;

            const pos = rvn_ed_point_pos(ed, &m, event.*.local_x - m.area.x + ed.*.hbar.offset, event.*.local_y - m.area.y + ed.*.vbar.offset);
            if (etype == raven.R_EVENT_MOUSE_DOWN) {
                if (event.*.clicks >= 3) {
                    // the whole line, with its line break
                    ed.*.anchor = rvn_ed_pos(pos.line, 0);
                    ed.*.caret = if (pos.line + 1 < @as(c_int, @intCast(ed.*.line_count)))
                        rvn_ed_pos(pos.line + 1, 0)
                    else
                        rvn_ed_pos(pos.line, ed.*.lines[@intCast(pos.line)].length);
                } else if (event.*.clicks == 2) {
                    const line: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(pos.line)];
                    var begin = pos.column;
                    var end = pos.column;
                    if (line.*.length > 0) {
                        if (begin >= line.*.length) begin = line.*.length - 1;
                        const kind = rvn_ed_class(line.*.text[@intCast(begin)]);
                        end = begin;
                        while (begin > 0 and rvn_ed_class(line.*.text[@intCast(begin - 1)]) == kind) begin -= 1;
                        while (end < line.*.length and rvn_ed_class(line.*.text[@intCast(end)]) == kind) end += 1;
                    }
                    ed.*.anchor = rvn_ed_pos(pos.line, begin);
                    ed.*.caret = rvn_ed_pos(pos.line, end);
                } else {
                    ed.*.caret = pos;
                    if (!hasFlag(event.*.modifiers, raven.R_MOD_SHIFT)) ed.*.anchor = pos;
                    ed.*.selecting = R_TRUE;
                    ext.rvn_widget_capture_mouse(widget);
                }
                rvn_ed_complete_close(ed);
                rvn_ed_break_typing(ed);
            } else {
                ed.*.caret = pos;
            }
            rvn_ed_caret_moved(ed, R_FALSE);
            return R_TRUE;
        },
        else => return R_FALSE,
    }
}

// ---------------------------------------------------------------------------
//  Class
// ---------------------------------------------------------------------------

fn rvn_ed_set_text(ed: [*c]rvn_text_editor_t, text: [*c]const u8) void {
    rvn_ed_history_clear(ed.*.undo, &ed.*.undo_count);
    rvn_ed_history_clear(ed.*.redo, &ed.*.redo_count);
    _ = rvn_ed_replace(ed, rvn_ed_pos(0, 0), rvn_ed_end(ed), if (text != null) text else "", -1, R_FALSE);
    const origin = rvn_ed_pos(0, 0);
    ed.*.caret = origin;
    ed.*.anchor = origin;
    ed.*.vbar.offset = 0.0;
    ed.*.hbar.offset = 0.0;
    ed.*.goal_x = -1.0;
    ext.rvn_widget_invalidate_layout(&ed.*.base);
}

fn rvn_text_editor_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    ed.*.tab_size = 4;
    ed.*.font = R_INVALID_ID;
    ed.*.goal_x = -1.0;
    ed.*.blink_timer = R_INVALID_ID;
    ed.*.rows_dirty = R_TRUE;
    rvn_ed_lines_insert(ed, 0, 1);
    widget.*.cursor = @intCast(raven.R_CURSOR_IBEAM);
}

fn rvn_text_editor_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    if (ed.*.blink_timer != R_INVALID_ID and raven.Rtimer_is_valid(ed.*.blink_timer) != 0) raven.Rtimer_destroy(ed.*.blink_timer);
    var i: u32 = 0;
    while (i < ed.*.line_count) : (i += 1) rvn_ed_line_free(&ed.*.lines[i]);
    base.rvn_free(ed.*.lines);
    base.rvn_free(ed.*.row_starts);
    rvn_ed_history_clear(ed.*.undo, &ed.*.undo_count);
    rvn_ed_history_clear(ed.*.redo, &ed.*.redo_count);
    base.rvn_free(ed.*.undo);
    base.rvn_free(ed.*.redo);
    base.rvn_free(ed.*.placeholder);
    base.rvn_free(ed.*.text_cache);
    base.rvn_free(ed.*.selection_cache);
    base.rvn_free(ed.*.language_name);
    i = 0;
    while (i < ed.*.marker_count) : (i += 1) base.rvn_free(ed.*.markers[i].message);
    base.rvn_free(ed.*.markers);
    if (ed.*.complete != null) ext.rvn_widget_destroy(ed.*.complete);
}

/// Gives the editor a language by name; NULL, "" or "None" removes it. Returns R_FALSE when the name is unknown.
fn rvn_ed_set_language(ed: [*c]rvn_text_editor_t, name: [*c]const u8) c_int {
    var language: ?*const common.rvn_language_t = null;
    if (name != null and name[0] != 0 and base.rvn_stricmp(name, "None") != 0) {
        language = common.rvn_language_find(name);
        if (language == null) return R_FALSE;
    }
    const src: [*c]const u8 = if (language) |l| common.rvn_language_desc(l).*.name else null;
    _ = base.rvn_str_set(&ed.*.language_name, src);
    // (looked for again, and everything that was computed with the other one with it)
    ed.*.language_generation = common.rvn_language_generation() -% 1;
    ed.*.lex_valid = 0;
    ed.*.match_version = ed.*.version -% 1;
    rvn_ed_complete_close(ed);
    return R_TRUE;
}

fn rvn_text_editor_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const ed: [*c]rvn_text_editor_t = ccast([*c]rvn_text_editor_t, widget);
    var number: f32 = undefined;
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Text") == 0) {
        rvn_ed_set_text(ed, value);
        return R_TRUE;
    }
    if (base.rvn_stricmp(name, "Placeholder") == 0) {
        _ = base.rvn_str_set(&ed.*.placeholder, value);
    } else if (base.rvn_stricmp(name, "ReadOnly") == 0) {
        if (ext.rvn_parse_bool(value, &ed.*.read_only) == 0) return R_FALSE;
    } else if (base.rvn_stricmp(name, "Wrap") == 0 or base.rvn_stricmp(name, "WordWrap") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        Rtext_editor_set_word_wrap(widget.*.id, flag);
    } else if (base.rvn_stricmp(name, "LineNumbers") == 0) {
        if (ext.rvn_parse_bool(value, &ed.*.line_numbers) == 0) return R_FALSE;
    } else if (base.rvn_stricmp(name, "TabSize") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0 or number < 1.0 or number > 16.0) return R_FALSE;
        ed.*.tab_size = @intFromFloat(number);
    } else if (base.rvn_stricmp(name, "TabSpaces") == 0) {
        if (ext.rvn_parse_bool(value, &ed.*.tab_spaces) == 0) return R_FALSE;
    } else if (base.rvn_stricmp(name, "Language") == 0 or base.rvn_stricmp(name, "Syntax") == 0) {
        if (rvn_ed_set_language(ed, value) == 0) return R_FALSE;
    } else if (base.rvn_stricmp(name, "Markdown") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        if (rvn_ed_set_language(ed, if (flag != 0) "Markdown" else "") == 0) return R_FALSE;
    } else if (base.rvn_stricmp(name, "Completion") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        ed.*.no_completion = @intFromBool(flag == 0);
    } else if (base.rvn_stricmp(name, "AutoPairs") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        ed.*.no_pairs = @intFromBool(flag == 0);
    } else if (base.rvn_stricmp(name, "Font") == 0) {
        const font = common.rvn_xml_font(value);
        if (font == R_INVALID_ID) return R_FALSE;
        ed.*.font = font;
    } else if (base.rvn_stricmp(name, "FontSize") == 0 or base.rvn_stricmp(name, "TextSize") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0 or number < 0.0) return R_FALSE;
        ed.*.font_size = number;
    } else if (base.rvn_stricmp(name, "Zoom") == 0) {
        if (ext.rvn_parse_float(value, &number) == 0 or number <= 0.0) return R_FALSE;
        ed.*.zoom = base.rvn_clampf(number, RVN_ED_ZOOM_MIN, RVN_ED_ZOOM_MAX);
    } else if (base.rvn_stricmp(name, "Zoomable") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        ed.*.no_zoom = @intFromBool(flag == 0);
    } else {
        return R_FALSE;
    }
    // anything above may change the size of the rows
    var i: u32 = 0;
    while (i < ed.*.line_count) : (i += 1) rvn_ed_line_dirty(&ed.*.lines[i]);
    ed.*.rows_dirty = R_TRUE;
    ext.rvn_widget_invalidate_layout(widget);
    return R_TRUE;
}

export const rvn_class_text_editor: widget_h.rvn_widget_class_t = .{
    .type = raven.R_WIDGET_TEXT_EDITOR,
    .name = "TextEditor",
    .size = @sizeOf(rvn_text_editor_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_NO_MIRROR,
    .init = rvn_text_editor_init,
    .destroy = rvn_text_editor_destroy,
    .measure = rvn_text_editor_measure,
    .arrange = rvn_text_editor_arrange,
    .paint = rvn_text_editor_paint,
    .event = rvn_text_editor_event,
    .set_attribute = rvn_text_editor_set_attribute,
    .paint_overlay = null,
    .child_active = null,
    .child_at = null,
    .children_changed = null,
    .xml_child = null,
    .popup_closed = null,
    .window_drag_at = null,
};

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/// An option that changes how the lines are laid out.
fn rvn_ed_relayout(ed: [*c]rvn_text_editor_t) void {
    var i: u32 = 0;
    while (i < ed.*.line_count) : (i += 1) rvn_ed_line_dirty(&ed.*.lines[i]);
    ed.*.rows_dirty = R_TRUE;
    ext.rvn_widget_invalidate_layout(&ed.*.base);
}

/// The editor of a handle, or NULL: the checks of the RVN_EDITOR macros.
fn editorOf(id: Rid, function: [*c]const u8) [*c]rvn_text_editor_t {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_TEXT_EDITOR, function);
    return if (widget != null) ccast([*c]rvn_text_editor_t, widget) else null;
}

export fn Rtext_editor_create(text: [*c]const u8) Rid {
    if (ext.rvn_api_check("Rtext_editor_create") == 0) return R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_TEXT_EDITOR);
    if (widget == null) return R_INVALID_ID;
    if (text != null and text[0] != 0) rvn_ed_set_text(ccast([*c]rvn_text_editor_t, widget), text);
    return widget.*.id;
}

export fn Rtext_editor_set_text(id: Rid, text: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_set_text");
    if (ed == null) return;
    rvn_ed_set_text(ed, text);
}

export fn Rtext_editor_get_text(id: Rid) [*c]const u8 {
    const ed = editorOf(id, "Rtext_editor_get_text");
    if (ed == null) return "";
    if (ed.*.text_cache_valid == 0) {
        base.rvn_free(ed.*.text_cache);
        ed.*.text_cache = rvn_ed_range(ed, rvn_ed_pos(0, 0), rvn_ed_end(ed), &ed.*.text_cache_length);
        ed.*.text_cache_valid = R_TRUE;
    }
    return ed.*.text_cache;
}

export fn Rtext_editor_get_length(id: Rid) c_int {
    if (ext.rvn_widget_check(id, raven.R_WIDGET_TEXT_EDITOR, "Rtext_editor_get_length") == null) return 0;
    _ = Rtext_editor_get_text(id);
    return ccast([*c]rvn_text_editor_t, ext.rvn_widget_get(id)).*.text_cache_length;
}

export fn Rtext_editor_get_line_count(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_get_line_count");
    if (ed == null) return 0;
    return @intCast(ed.*.line_count);
}

export fn Rtext_editor_get_line(id: Rid, line: c_int) [*c]const u8 {
    const ed = editorOf(id, "Rtext_editor_get_line");
    if (ed == null) return null;
    if (line < 0 or line >= @as(c_int, @intCast(ed.*.line_count))) return null;
    return ed.*.lines[@intCast(line)].text;
}

export fn Rtext_editor_insert_text(id: Rid, text: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_insert_text");
    if (ed == null) return;
    if (text == null) return;
    rvn_ed_break_typing(ed);
    rvn_ed_insert(ed, text, -1);
    rvn_ed_break_typing(ed);
    rvn_ed_caret_moved(ed, R_FALSE);
    rvn_ed_notify(&ed.*.base);
}

export fn Rtext_editor_set_cursor(id: Rid, line: c_int, column: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_cursor");
    if (ed == null) return;
    const p = rvn_ed_clamp(ed, rvn_ed_pos(line, column));
    ed.*.caret = p;
    ed.*.anchor = p;
    rvn_ed_break_typing(ed);
    rvn_ed_caret_moved(ed, R_FALSE);
}

export fn Rtext_editor_get_cursor(id: Rid, line: [*c]c_int, column: [*c]c_int) void {
    if (line != null) line.* = 0;
    if (column != null) column.* = 0;
    const ed = editorOf(id, "Rtext_editor_get_cursor");
    if (ed == null) return;
    if (line != null) line.* = ed.*.caret.line;
    if (column != null) column.* = ed.*.caret.column;
}

export fn Rtext_editor_select(id: Rid, from_line: c_int, from_column: c_int, to_line: c_int, to_column: c_int) void {
    const ed = editorOf(id, "Rtext_editor_select");
    if (ed == null) return;
    ed.*.anchor = rvn_ed_clamp(ed, rvn_ed_pos(from_line, from_column));
    ed.*.caret = rvn_ed_clamp(ed, rvn_ed_pos(to_line, to_column));
    rvn_ed_break_typing(ed);
    rvn_ed_caret_moved(ed, R_FALSE);
}

export fn Rtext_editor_select_all(id: Rid) void {
    const ed = editorOf(id, "Rtext_editor_select_all");
    if (ed == null) return;
    ed.*.anchor = rvn_ed_pos(0, 0);
    ed.*.caret = rvn_ed_end(ed);
    rvn_ed_break_typing(ed);
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

export fn Rtext_editor_get_selection(id: Rid, from_line: [*c]c_int, from_column: [*c]c_int, to_line: [*c]c_int, to_column: [*c]c_int) c_int {
    const ed = editorOf(id, "Rtext_editor_get_selection");
    if (ed == null) return R_FALSE;
    const from = rvn_ed_sel_min(ed);
    const to = rvn_ed_sel_max(ed);
    if (from_line != null) from_line.* = from.line;
    if (from_column != null) from_column.* = from.column;
    if (to_line != null) to_line.* = to.line;
    if (to_column != null) to_column.* = to.column;
    return rvn_ed_has_selection(ed);
}

export fn Rtext_editor_get_selected_text(id: Rid) [*c]const u8 {
    const ed = editorOf(id, "Rtext_editor_get_selected_text");
    if (ed == null) return "";
    base.rvn_free(ed.*.selection_cache);
    ed.*.selection_cache = rvn_ed_range(ed, rvn_ed_sel_min(ed), rvn_ed_sel_max(ed), null);
    return ed.*.selection_cache;
}

export fn Rtext_editor_scroll_to_line(id: Rid, line: c_int) void {
    const ed = editorOf(id, "Rtext_editor_scroll_to_line");
    if (ed == null) return;
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) ext.rvn_window_layout(widget.*.window);
    var m: rvn_ed_metrics_t = undefined;
    rvn_ed_metrics(ed, &m);
    rvn_ed_update_rows(ed, &m);
    rvn_ed_update_bars(ed, &m);
    const point = rvn_ed_pos_point(ed, &m, rvn_ed_clamp(ed, rvn_ed_pos(line, 0)));
    // a third of the way down: the lines before it give some context
    _ = common.rvn_scrollbar_set(&ed.*.vbar, point.y - ed.*.vbar.viewport * 0.33);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_editor_undo(id: Rid) void {
    const ed = editorOf(id, "Rtext_editor_undo");
    if (ed == null) return;
    if (rvn_ed_undo(ed) == 0) return;
    rvn_ed_caret_moved(ed, R_FALSE);
    rvn_ed_notify(&ed.*.base);
}

export fn Rtext_editor_redo(id: Rid) void {
    const ed = editorOf(id, "Rtext_editor_redo");
    if (ed == null) return;
    if (rvn_ed_redo(ed) == 0) return;
    rvn_ed_caret_moved(ed, R_FALSE);
    rvn_ed_notify(&ed.*.base);
}

export fn Rtext_editor_can_undo(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_can_undo");
    if (ed == null) return R_FALSE;
    return @intFromBool(ed.*.undo_count > 0 and ed.*.read_only == 0);
}

export fn Rtext_editor_can_redo(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_can_redo");
    if (ed == null) return R_FALSE;
    return @intFromBool(ed.*.redo_count > 0 and ed.*.read_only == 0);
}

export fn Rtext_editor_set_read_only(id: Rid, read_only: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_read_only");
    if (ed == null) return;
    ed.*.read_only = @intFromBool(read_only != 0);
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

export fn Rtext_editor_set_word_wrap(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_word_wrap");
    if (ed == null) return;
    if (ed.*.wrap == @intFromBool(enabled != 0)) return;
    ed.*.wrap = @intFromBool(enabled != 0);
    ed.*.wrap_width = -1.0;
    ed.*.hbar.offset = 0.0;
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_line_numbers(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_line_numbers");
    if (ed == null) return;
    ed.*.line_numbers = @intFromBool(enabled != 0);
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_tab_size(id: Rid, spaces: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_tab_size");
    if (ed == null) return;
    if (spaces < 1 or spaces > 16) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtext_editor_set_tab_size: the size must be between 1 and 16");
        return;
    }
    ed.*.tab_size = spaces;
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_tab_inserts_spaces(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_tab_inserts_spaces");
    if (ed == null) return;
    ed.*.tab_spaces = @intFromBool(enabled != 0);
}

export fn Rtext_editor_set_syntax(id: Rid, syntax: raven.RSyntax) void {
    const ed = editorOf(id, "Rtext_editor_set_syntax");
    if (ed == null) return;
    const s: c_int = @intCast(syntax);
    if (s < raven.R_SYNTAX_NONE or s > raven.R_SYNTAX_C) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtext_editor_set_syntax: invalid syntax");
        return;
    }
    const name: [*c]const u8 = if (s == raven.R_SYNTAX_XML) "XML" else if (s == raven.R_SYNTAX_C) "C" else null;
    _ = rvn_ed_set_language(ed, name);
    // (the font may change with it)
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_language(id: Rid, name: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_set_language");
    if (ed == null) return;
    if (rvn_ed_set_language(ed, name) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_WARNING, "Rtext_editor_set_language: unknown language \"%s\"", name);
        return;
    }
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_markdown(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_markdown");
    if (ed == null) return;
    _ = rvn_ed_set_language(ed, if (enabled != 0) "Markdown" else "");
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_get_markdown(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_get_markdown");
    if (ed == null) return R_FALSE;
    const language = rvn_ed_language(ed) orelse return R_FALSE;
    return @intFromBool(hasFlag(common.rvn_language_desc(language).*.flags, raven.R_LANGUAGE_FORMATTED_TEXT));
}

export fn Rtext_editor_get_language(id: Rid) [*c]const u8 {
    const ed = editorOf(id, "Rtext_editor_get_language");
    if (ed == null) return "";
    return if (ed.*.language_name != null) ed.*.language_name else "";
}

export fn Rtext_editor_get_token(id: Rid, line: c_int, column: c_int) raven.RToken {
    var spans: [RVN_ED_MAX_SPANS]common.rvn_span_t = undefined;
    var count: c_int = 0;
    const ed = editorOf(id, "Rtext_editor_get_token");
    if (ed == null) return @intCast(raven.R_TOKEN_TEXT);
    const language = rvn_ed_language(ed);
    if (language == null or line < 0 or line >= @as(c_int, @intCast(ed.*.line_count)) or column < 0 or column >= ed.*.lines[@intCast(line)].length) {
        return @intCast(raven.R_TOKEN_TEXT);
    }
    rvn_ed_lex_until(ed, @intCast(line));
    const l: [*c]const rvn_ed_line_t = &ed.*.lines[@intCast(line)];
    _ = common.rvn_syntax_line(language, l.*.text, l.*.length, l.*.lex_in, &spans, RVN_ED_MAX_SPANS, &count);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (column >= spans[@intCast(i)].start and column < spans[@intCast(i)].end) {
            return common.rvn_token_public(spans[@intCast(i)].token);
        }
    }
    return @intCast(raven.R_TOKEN_TEXT);
}

export fn Rtext_editor_set_completion(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_completion");
    if (ed == null) return;
    ed.*.no_completion = @intFromBool(enabled == 0);
    if (enabled == 0) rvn_ed_complete_close(ed);
}

export fn Rtext_editor_show_completions(id: Rid) void {
    const ed = editorOf(id, "Rtext_editor_show_completions");
    if (ed == null) return;
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    if (widget.*.window != null and widget.*.window.*.needs_layout != 0) ext.rvn_window_layout(widget.*.window);
    rvn_ed_complete_update(widget, 1);
}

export fn Rtext_editor_is_completing(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_is_completing");
    if (ed == null) return R_FALSE;
    return rvn_ed_completing(ed);
}

export fn Rtext_editor_set_completion_callback(id: Rid, callback: raven.RCompletionCallback, user_data: ?*anyopaque) void {
    const ed = editorOf(id, "Rtext_editor_set_completion_callback");
    if (ed == null) return;
    ed.*.completion_callback = callback;
    ed.*.completion_user = user_data;
}

export fn Rtext_editor_add_completion(id: Rid, text: [*c]const u8, detail: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_add_completion");
    if (ed == null) return;
    const list: [*c]rvn_ed_complete_t = ccast([*c]rvn_ed_complete_t, ed.*.complete);
    if (list == null or list.*.collecting == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtext_editor_add_completion: only from a completion callback");
        return;
    }
    if (text == null or text[0] == 0) return;
    // (only what continues the word being typed)
    if (@as(c_int, @intCast(libc.strlen(text))) < list.*.prefix_length or
        base.rvn_strnicmp(text, at(ed.*.lines[@intCast(list.*.start.line)].text, list.*.start.column), @intCast(list.*.prefix_length)) != 0) return;
    rvn_edc_add(list, text, @intCast(libc.strlen(text)), if (detail != null and detail[0] != 0) detail else null, 0);
}

export fn Rtext_editor_set_auto_pairs(id: Rid, enabled: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_auto_pairs");
    if (ed == null) return;
    ed.*.no_pairs = @intFromBool(enabled == 0);
}

export fn Rtext_editor_add_marker(id: Rid, line_in: c_int, from_column_in: c_int, to_column_in: c_int, kind: raven.RMarkerKind, message: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_add_marker");
    if (ed == null) return;
    const k: c_int = @intCast(kind);
    if (k < raven.R_MARKER_ERROR or k > raven.R_MARKER_INFO) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtext_editor_add_marker: invalid kind");
        return;
    }
    const line = base.rvn_clampi(line_in, 0, @as(c_int, @intCast(ed.*.line_count)) - 1);
    const from_column = base.rvn_clampi(from_column_in, 0, ed.*.lines[@intCast(line)].length);
    var to_column = to_column_in;
    if (to_column >= 0) to_column = base.rvn_clampi(to_column, from_column, ed.*.lines[@intCast(line)].length);
    base.RVN_ARRAY_RESERVE(&ed.*.markers, &ed.*.marker_cap, ed.*.marker_count + 1);
    const marker: [*c]rvn_ed_marker_t = &ed.*.markers[ed.*.marker_count];
    ed.*.marker_count += 1;
    marker.*.line = line;
    marker.*.from = from_column;
    marker.*.to = if (to_column < 0) -1 else to_column;
    marker.*.kind = kind;
    marker.*.message = if (message != null and message[0] != 0) base.rvn_strdup(message) else null;
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

export fn Rtext_editor_clear_markers(id: Rid) void {
    const ed = editorOf(id, "Rtext_editor_clear_markers");
    if (ed == null) return;
    var i: u32 = 0;
    while (i < ed.*.marker_count) : (i += 1) base.rvn_free(ed.*.markers[i].message);
    ed.*.marker_count = 0;
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    if (ed.*.marker_tip != 0) {
        _ = base.rvn_str_set(&widget.*.tooltip, null);
        ed.*.marker_tip = R_FALSE;
        if (widget.*.window != null) ext.rvn_window_rearm_tooltip(widget.*.window);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtext_editor_get_marker_count(id: Rid) c_int {
    const ed = editorOf(id, "Rtext_editor_get_marker_count");
    if (ed == null) return 0;
    return @intCast(ed.*.marker_count);
}

export fn Rtext_editor_set_font(id: Rid, font: Rid, size: f32) void {
    const ed = editorOf(id, "Rtext_editor_set_font");
    if (ed == null) return;
    ed.*.font = font;
    ed.*.font_size = if (size > 0.0) size else 0.0;
    rvn_ed_relayout(ed);
}

export fn Rtext_editor_set_zoom(id: Rid, zoom_in: f32) void {
    const ed = editorOf(id, "Rtext_editor_set_zoom");
    if (ed == null) return;
    var zoom = zoom_in;
    if (zoom <= 0.0) zoom = 1.0;
    const widget: [*c]widget_h.rvn_widget_t = &ed.*.base;
    // (from the program: the top of the view stays where it is, nobody is told)
    if (widget.*.rect.w > 0.0 and widget.*.rect.h > 0.0) {
        _ = rvn_ed_set_zoom(ed, zoom, 0.0, 0.0, R_FALSE);
    } else {
        ed.*.zoom = base.rvn_clampf(zoom, RVN_ED_ZOOM_MIN, RVN_ED_ZOOM_MAX);
        rvn_ed_relayout(ed);
    }
}

export fn Rtext_editor_get_zoom(id: Rid) f32 {
    const ed = editorOf(id, "Rtext_editor_get_zoom");
    if (ed == null) return 1.0;
    return if (ed.*.zoom > 0.0) ed.*.zoom else 1.0;
}

export fn Rtext_editor_set_zoomable(id: Rid, zoomable: c_int) void {
    const ed = editorOf(id, "Rtext_editor_set_zoomable");
    if (ed == null) return;
    ed.*.no_zoom = @intFromBool(zoomable == 0);
}

export fn Rtext_editor_set_zoom_callback(id: Rid, callback: raven.RTextEditorZoomCallback, user_data: ?*anyopaque) void {
    const ed = editorOf(id, "Rtext_editor_set_zoom_callback");
    if (ed == null) return;
    ed.*.zoom_callback = callback;
    ed.*.zoom_user = user_data;
}

export fn Rtext_editor_set_placeholder(id: Rid, text: [*c]const u8) void {
    const ed = editorOf(id, "Rtext_editor_set_placeholder");
    if (ed == null) return;
    _ = base.rvn_str_set(&ed.*.placeholder, text);
    ext.rvn_widget_invalidate_paint(&ed.*.base);
}

export fn Rtext_editor_set_changed_callback(id: Rid, callback: raven.RTextEditorChangedCallback, user_data: ?*anyopaque) void {
    const ed = editorOf(id, "Rtext_editor_set_changed_callback");
    if (ed == null) return;
    ed.*.callback = callback;
    ed.*.user_data = user_data;
}
