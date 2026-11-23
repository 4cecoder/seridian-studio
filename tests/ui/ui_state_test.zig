//! State snapshot JSON (ported from tests/ui/ui_state_test.c, every assertion kept).

const std = @import("std");
const ui_state = @import("ui_impl").ui_state;
const expect = std.testing.expect;

const UiState = ui_state.UiState;

fn setText(dest: []u8, text: []const u8) void {
    @memcpy(dest[0..text.len], text);
    dest[text.len] = 0;
}

fn expectContains(json: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, json, needle) == null) {
        std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, json });
        return error.TestExpectedContains;
    }
}

fn sampleState() UiState {
    var state = std.mem.zeroes(UiState);
    state.playing = 1;
    state.position_seconds = 12.5;
    state.bpm = 120.0;
    state.master_gain = 0.75;
    state.track_count = 2;
    setText(&state.tracks[0].name, "Track 1");
    state.tracks[0].pan_knob_x = 475.0;
    state.tracks[0].pan_knob_y = 770.5;
    state.tracks[0].gain = 0.5;
    state.tracks[0].pan = -0.25;
    state.tracks[0].armed = 1;
    setText(&state.tracks[1].name, "Bass \"Pad\"");
    state.tracks[1].muted = 1;
    setText(&state.tracks[1].instrument, "Wavetable");
    state.tracks[0].midi_notes = 3;
    state.tracks[1].midi_notes = 0;
    setText(&state.audio.output_device, "alsa_output.\"x\"");
    state.audio.sample_rate = 48000;
    state.audio.buffer_size = 512;
    setText(&state.audio.backend, "pulseaudio");
    return state;
}

/// Formats `state` into `json` and returns the written text (empty on failure) with the C return value.
fn format(state: *const UiState, json: *[ui_state.UI_STATE_JSON_CAPACITY]u8) struct { written: c_int, text: []const u8 } {
    const written = ui_state.ui_state_format(state, json, json.len);
    return .{ .written = written, .text = std.mem.sliceTo(json, 0) };
}

test "format writes transport fields" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"playing\":true");
    try expectContains(out.text, "\"position_seconds\":12.500");
    try expectContains(out.text, "\"bpm\":120.000");
}

test "format writes each track" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expectContains(out.text, "\"name\":\"Track 1\"");
    try expectContains(out.text, "\"pan\":-0.250");
    try expectContains(out.text, "\"armed\":true");
    try expectContains(out.text, "\"muted\":true");
    try expectContains(out.text, "\"instrument\":\"Wavetable\"");
}

test "format writes midi note count per track" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expectContains(out.text, "\"midi_notes\":3,\"instrument\":\"\"");
    try expectContains(out.text, "\"midi_notes\":0,\"instrument\":\"Wavetable\"");
}

test "format reports pan knob centre" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expectContains(out.text, "\"pan_knob\":{\"x\":475.0,\"y\":770.5}");
}

test "format escapes quotes in names" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expectContains(out.text, "\"name\":\"Bass \\\"Pad\\\"\"");
}

test "format reports track count only" {
    // Only the first track_count entries are written; unused slots must not appear.
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expectContains(out.text, "\"index\":1");
    try expect(std.mem.indexOf(u8, out.text, "\"index\":2") == null);
    try expect(std.mem.indexOf(u8, out.text, "\"index\":3") == null);
}

test "format rejects small buffer" {
    var tiny: [8]u8 = undefined;
    const state = sampleState();
    try expect(ui_state.ui_state_format(&state, &tiny, tiny.len) < 0);
}

test "format escapes control characters" {
    var state = sampleState();
    setText(&state.tracks[0].name, "a\nb");
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const out = format(&state, &json);
    try expectContains(out.text, "\"name\":\"a\\nb\"");
    try expect(std.mem.indexOfScalar(u8, out.text, '\n') == null);
}

test "format writes audio object" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"audio\":{");
    try expectContains(out.text, "\"sample_rate\":48000");
    try expectContains(out.text, "\"buffer_size\":512");
    try expectContains(out.text, "\"backend\":\"pulseaudio\"");
    try expectContains(out.text, "\"output_device\":\"alsa_output.\\\"x\\\"\"");
}

test "format audio default device is empty string" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    var state = sampleState();
    state.audio = std.mem.zeroes(ui_state.UiAudioState);
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"output_device\":\"\"");
}

test "format fits worst case audio" {
    // 127 quote characters escape to 254 bytes, the longest device name the engine can report.
    // Eight tracks with 63-quote names and instruments add their own worst-case escaping.
    var state = sampleState();
    @memset(state.audio.output_device[0..127], '"');
    state.audio.output_device[127] = 0;
    state.track_count = ui_state.UI_STATE_MAX_TRACKS;
    for (0..ui_state.UI_STATE_MAX_TRACKS) |i| {
        @memset(state.tracks[i].name[0..63], '"');
        state.tracks[i].name[63] = 0;
        @memset(state.tracks[i].instrument[0..63], '"');
        state.tracks[i].instrument[63] = 0;
    }

    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"audio\":{");
}

test "format writes piano roll notes" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    var state = sampleState();
    state.piano_track = 1;
    state.piano_note_count = 2;
    state.piano_notes[0] = .{ .pitch = 60, .start_beat = 1.5, .length_beats = 0.5, .selected = 1 };
    state.piano_notes[1] = .{ .pitch = 64, .start_beat = 2.0, .length_beats = 1.0, .selected = 0 };
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"piano_roll\":{\"track\":1,\"note_count\":2,\"notes\":[" ++
        "{\"pitch\":60,\"start_beat\":1.500,\"length_beats\":0.500,\"selected\":true}," ++
        "{\"pitch\":64,\"start_beat\":2.000,\"length_beats\":1.000,\"selected\":false}]}");
}

test "format piano roll empty track" {
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    const state = sampleState();
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"piano_roll\":{\"track\":0,\"note_count\":0,\"notes\":[]}");
}

test "format caps piano roll notes" {
    // The array holds at most UI_STATE_MAX_NOTES entries, while note_count reports the full total.
    var json: [ui_state.UI_STATE_JSON_CAPACITY]u8 = undefined;
    var state = sampleState();
    state.piano_note_count = ui_state.UI_STATE_MAX_NOTES + 10;
    for (0..ui_state.UI_STATE_MAX_NOTES) |i| {
        state.piano_notes[i] = .{ .pitch = 60, .start_beat = 0.0, .length_beats = 1.0, .selected = 0 };
    }
    const out = format(&state, &json);
    try expect(out.written > 0);
    try expectContains(out.text, "\"note_count\":266");
    try expect(std.mem.count(u8, out.text, "\"pitch\":") == ui_state.UI_STATE_MAX_NOTES);
}

test "write file replaces the file atomically" {
    // Not in the C suite: ui_state_write_file had no test. Writes, overwrites, and leaves no temp file behind.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to the working directory.
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}/state.json", .{tmp.sub_path}, 0);
    try expect(ui_state.ui_state_write_file(path.ptr, "{\"a\":1}") == 0);
    try expect(ui_state.ui_state_write_file(path.ptr, "{\"b\":2}") == 0);
    var read_buf: [64]u8 = undefined;
    const contents = try tmp.dir.readFile(io, "state.json", &read_buf);
    try std.testing.expectEqualStrings("{\"b\":2}", contents);
    try expect(ui_state.ui_state_write_file(null, "x") == -1);
    try expect(ui_state.ui_state_write_file(path.ptr, null) == -1);
    var probe: [8]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "state.json.tmp", &probe));
}
