//! Snapshot of the DAW's observable state, written as JSON for the `seridian` CLI and automated tests. The app
//! refreshes it a few times a second, so external tools can read real values (levels, pan, gain, transport)
//! instead of guessing from screenshots.
//!
//! Translated from src/ui/ui_state.c and ui_state.h. Numbers are formatted by the C library's snprintf, as in the
//! C, so the JSON text is byte-for-byte the same. Tests ported from tests/ui/ui_state_test.c.

const std = @import("std");

extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
extern "c" fn strlen(text: [*c]const u8) usize;
const FILE = opaque {};
extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*FILE;
extern "c" fn fwrite(data: ?*const anyopaque, size: usize, count: usize, file: *FILE) usize;
extern "c" fn fclose(file: *FILE) c_int;
extern "c" fn remove(path: [*c]const u8) c_int;
extern "c" fn rename(from: [*c]const u8, to: [*c]const u8) c_int;

pub const UI_STATE_MAX_TRACKS = 8;
pub const UI_STATE_NAME_CAPACITY = 64;
/// Eight tracks, a 127-byte device name and up to UI_STATE_MAX_NOTES piano roll notes need more than 4096.
pub const UI_STATE_JSON_CAPACITY = 32768;
pub const UI_STATE_DEVICE_CAPACITY = 128;
pub const UI_STATE_BACKEND_CAPACITY = 32;
/// Notes written per snapshot for the piano roll track; note_count still reports the full total.
pub const UI_STATE_MAX_NOTES = 256;

pub const UiTrackState = extern struct {
    name: [UI_STATE_NAME_CAPACITY]u8,
    instrument: [UI_STATE_NAME_CAPACITY]u8,
    gain: f32,
    pan: f32,
    pan_knob_x: f32,
    pan_knob_y: f32,
    muted: c_int,
    soloed: c_int,
    armed: c_int,
    midi_notes: c_int,
    /// 1 when the track has a reverb; `reverb_wet` is its wet amount 0..1 (0 without a reverb).
    reverb: c_int,
    reverb_wet: f32,
};

/// One note of the piano roll track, as stored in the engine clip.
pub const UiNoteState = extern struct {
    pitch: c_int,
    start_beat: f64,
    length_beats: f64,
    selected: c_int,
};

pub const UiAudioState = extern struct {
    output_device: [UI_STATE_DEVICE_CAPACITY]u8,
    sample_rate: c_uint,
    buffer_size: c_uint,
    backend: [UI_STATE_BACKEND_CAPACITY]u8,
};

pub const UiState = extern struct {
    playing: c_int,
    position_seconds: f64,
    bpm: f32,
    master_gain: f32,
    track_count: c_int,
    tracks: [UI_STATE_MAX_TRACKS]UiTrackState,
    /// Piano roll track: its index, total note count, and the first notes (up to UI_STATE_MAX_NOTES).
    piano_track: c_int,
    piano_note_count: c_int,
    piano_notes: [UI_STATE_MAX_NOTES]UiNoteState,
    audio: UiAudioState,
};

/// Appends into a caller-owned buffer; `overflow` latches once anything did not fit.
const Cursor = struct {
    buffer: [*c]u8,
    capacity: usize,
    length: usize,
    overflow: c_int,
};

fn cursor_put(cursor: *Cursor, text: [*c]const u8) void {
    if (cursor.overflow != 0) return;
    const text_length = strlen(text);
    if (cursor.length + text_length + 1 > cursor.capacity) {
        cursor.overflow = 1;
        return;
    }
    @memcpy(cursor.buffer[cursor.length .. cursor.length + text_length], text[0..text_length]);
    cursor.length += text_length;
    cursor.buffer[cursor.length] = 0;
}

/// `cursor_printf(cursor, format, ...)`: `args` is the tuple of C varargs (floats already widened to f64).
fn cursor_printf(cursor: *Cursor, format: [*:0]const u8, args: anytype) void {
    if (cursor.overflow != 0) return;
    var piece: [256]u8 = undefined;
    const needed: c_int = @call(.auto, snprintf, .{ @as([*c]u8, &piece), piece.len, format } ++ args);
    if (needed < 0 or @as(usize, @intCast(needed)) >= piece.len) {
        cursor.overflow = 1;
        return;
    }
    cursor_put(cursor, &piece);
}

/// Appends `text` as a JSON string literal, escaping quotes, backslashes and control characters.
fn cursor_put_json_string(cursor: *Cursor, text: [*c]const u8) void {
    cursor_put(cursor, "\"");
    var p = text;
    while (p[0] != 0) : (p += 1) {
        const ch: u8 = p[0];
        if (ch == '"') {
            cursor_put(cursor, "\\\"");
        } else if (ch == '\\') {
            cursor_put(cursor, "\\\\");
        } else if (ch == '\n') {
            cursor_put(cursor, "\\n");
        } else if (ch == '\t') {
            cursor_put(cursor, "\\t");
        } else if (ch < 0x20) {
            cursor_printf(cursor, "\\u%04x", .{@as(c_uint, ch)});
        } else {
            cursor_printf(cursor, "%c", .{@as(c_int, ch)});
        }
    }
    cursor_put(cursor, "\"");
}

fn yes_no(flag: c_int) [*c]const u8 {
    return if (flag != 0) "true" else "false";
}

fn cursor_put_track(cursor: *Cursor, track: *const UiTrackState, index: c_int) void {
    cursor_printf(cursor, "{\"index\":%d,\"name\":", .{index});
    cursor_put_json_string(cursor, &track.name);
    cursor_printf(cursor, ",\"gain\":%.3f,\"pan\":%.3f", .{ @as(f64, track.gain), @as(f64, track.pan) });
    cursor_printf(cursor, ",\"pan_knob\":{\"x\":%.1f,\"y\":%.1f}", .{ @as(f64, track.pan_knob_x), @as(f64, track.pan_knob_y) });
    cursor_printf(cursor, ",\"muted\":%s,\"soloed\":%s,\"armed\":%s", .{ yes_no(track.muted), yes_no(track.soloed), yes_no(track.armed) });
    cursor_printf(cursor, ",\"midi_notes\":%d", .{track.midi_notes});
    cursor_put(cursor, ",\"instrument\":");
    cursor_put_json_string(cursor, &track.instrument);
    cursor_printf(cursor, ",\"reverb\":{\"present\":%s,\"wet\":%.3f}", .{ yes_no(track.reverb), @as(f64, track.reverb_wet) });
    cursor_put(cursor, "}");
}

/// Writes `state` as one line of JSON into `buffer` (caller-owned, `buffer_size` bytes), NUL-terminated.
/// Returns the number of characters written, or -1 when the buffer is too small.
pub export fn ui_state_format(state: ?*const UiState, buffer: [*c]u8, buffer_size: usize) callconv(.c) c_int {
    const s = state orelse return -1;
    if (buffer == null or buffer_size == 0) return -1;
    buffer[0] = 0;

    var cursor: Cursor = .{ .buffer = buffer, .capacity = buffer_size, .length = 0, .overflow = 0 };
    cursor_printf(&cursor, "{\"playing\":%s,\"position_seconds\":%.3f,\"bpm\":%.3f,\"master_gain\":%.3f,\"tracks\":[", .{
        yes_no(s.playing),
        s.position_seconds,
        @as(f64, s.bpm),
        @as(f64, s.master_gain),
    });

    const count: c_int = if (s.track_count < 0) 0 else (if (s.track_count > UI_STATE_MAX_TRACKS) UI_STATE_MAX_TRACKS else s.track_count);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (i > 0) cursor_put(&cursor, ",");
        cursor_put_track(&cursor, &s.tracks[@intCast(i)], i);
    }
    cursor_printf(&cursor, "],\"piano_roll\":{\"track\":%d,\"note_count\":%d,\"notes\":[", .{ s.piano_track, s.piano_note_count });
    const note_total: c_int = if (s.piano_note_count < 0) 0 else s.piano_note_count;
    const note_written: c_int = if (note_total > UI_STATE_MAX_NOTES) UI_STATE_MAX_NOTES else note_total;
    i = 0;
    while (i < note_written) : (i += 1) {
        const note = &s.piano_notes[@intCast(i)];
        if (i > 0) cursor_put(&cursor, ",");
        cursor_printf(&cursor, "{\"pitch\":%d,\"start_beat\":%.3f,\"length_beats\":%.3f,\"selected\":%s}", .{
            note.pitch,
            note.start_beat,
            note.length_beats,
            yes_no(note.selected),
        });
    }
    cursor_put(&cursor, "]}");
    cursor_put(&cursor, ",\"audio\":{\"output_device\":");
    cursor_put_json_string(&cursor, &s.audio.output_device);
    cursor_printf(&cursor, ",\"sample_rate\":%u,\"buffer_size\":%u", .{ s.audio.sample_rate, s.audio.buffer_size });
    cursor_put(&cursor, ",\"backend\":");
    cursor_put_json_string(&cursor, &s.audio.backend);
    cursor_put(&cursor, "}}");

    if (cursor.overflow != 0) return -1;
    return @intCast(cursor.length);
}

/// Writes `json` to `path` atomically (temp file, then rename), so a reader never sees a partial snapshot.
/// Returns 0 on success, -1 on failure (the temp file is removed).
pub export fn ui_state_write_file(path: [*c]const u8, json: [*c]const u8) callconv(.c) c_int {
    if (path == null or json == null) return -1;

    var temp_path: [1024]u8 = undefined;
    if (snprintf(&temp_path, temp_path.len, "%s.tmp", path) >= @as(c_int, temp_path.len)) return -1;

    const file = fopen(&temp_path, "w") orelse return -1;
    const length = strlen(json);
    const written = fwrite(json, 1, length, file);
    const closed = fclose(file);
    if (written != length or closed != 0) {
        _ = remove(&temp_path);
        return -1;
    }
    if (rename(&temp_path, path) != 0) {
        _ = remove(&temp_path);
        return -1;
    }
    return 0;
}
