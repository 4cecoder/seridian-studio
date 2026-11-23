//! Translated to Zig from src/ui/raven_app.c lines 4997-5518: command socket and the seridian_raven_run entry point. Seridian Studio window, 1:1 translation.

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

// Command socket: $XDG_RUNTIME_DIR/seridian.sock (mode 0600). A client sends one line and reads one reply
// ("ok" or "error: ..."). Everything is non-blocking and polled once per frame, and each command is applied
// on the UI thread through the same functions the buttons and the piano roll use.

pub fn control_open() void {
    {
        var i: c_int = 0;
        while (i < st.CONTROL_MAX_CLIENTS) : (i += 1) st.control_clients[@intCast(i)].fd = -1;
    }
    const dir: [*c]const u8 = libc.getenv("XDG_RUNTIME_DIR");
    if (dir == null or dir[0] == 0) return;
    var address = std.mem.zeroes(libc.sockaddr_un);
    address.family = libc.AF_UNIX;
    if (libc.snprintf(&address.path, address.path.len, "%s/seridian.sock", dir) >= @as(c_int, @intCast(address.path.len))) return;
    const fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_NONBLOCK | libc.SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    _ = libc.unlink(&address.path); // a stale socket from a crashed run
    const old_mask: libc.mode_t = libc.umask(0o177);
    const bound = libc.bind(fd, @as(*const libc.sockaddr, @ptrCast(&address)), @sizeOf(libc.sockaddr_un));
    _ = libc.umask(old_mask);
    if (bound != 0 or libc.chmod(&address.path, 0o600) != 0 or libc.listen(fd, 8) != 0) {
        _ = libc.close(fd);
        _ = libc.unlink(&address.path);
        return;
    }
    _ = libc.snprintf(&st.control_path, st.control_path.len, "%s", @as([*c]const u8, &address.path));
    st.control_listen_fd = fd;
}

pub fn control_close() void {
    {
        var i: c_int = 0;
        while (i < st.CONTROL_MAX_CLIENTS) : (i += 1) {
            if (st.control_clients[@intCast(i)].fd >= 0) _ = libc.close(st.control_clients[@intCast(i)].fd);
            st.control_clients[@intCast(i)].fd = -1;
        }
    }
    if (st.control_listen_fd >= 0) {
        _ = libc.close(st.control_listen_fd);
        st.control_listen_fd = -1;
        _ = libc.unlink(&st.control_path);
    }
}

pub fn control_parse_int(text: [*c]const u8, low: c_long, high: c_long, out: [*c]c_long) c_int {
    if (text == null or text[0] == 0) return 0;
    var end: [*c]u8 = null;
    libc.set_errno(0);
    const value = libc.strtol(text, &end, 10);
    if (libc.errno() != 0 or end.* != 0 or value < low or value > high) return 0;
    out.* = value;
    return 1;
}

pub fn control_parse_double(text: [*c]const u8, low: f64, high: f64, out: [*c]f64) c_int {
    if (text == null or text[0] == 0) return 0;
    var end: [*c]u8 = null;
    libc.set_errno(0);
    const value = libc.strtod(text, &end);
    if (libc.errno() != 0 or end.* != 0 or !libc.isfinite(value) or value < low or value > high) return 0;
    out.* = value;
    return 1;
}

pub fn control_parse_switch(text: [*c]const u8, out: [*c]c_int) c_int {
    if (text != null and libc.strcmp(text, "on") == 0) {
        out.* = 1;
        return 1;
    }
    if (text != null and libc.strcmp(text, "off") == 0) {
        out.* = 0;
        return 1;
    }
    return 0;
}

/// Parses a track number 1..8 into an engine track index 0..7.
pub fn control_parse_track(text: [*c]const u8, track: [*c]c_int) c_int {
    var value: c_long = 0;
    if (control_parse_int(text, 1, st.SERIDIAN_TRACK_COUNT, &value) == 0) return 0;
    track.* = @as(c_int, @intCast(value)) - 1;
    return 1;
}

/// Makes the piano roll show `track` (when it does not already) and reloads it from the engine.
pub fn control_show_piano_track(track: c_int) void {
    if (track != app.piano_track) {
        fns.piano_release_all_held();
        app.piano_track = track;
        if (app.piano_track_combo != raven.R_INVALID_ID) raven.Rcombo_box_set_selected(app.piano_track_combo, track);
    }
    fns.piano_roll_reload();
}

pub fn control_note(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    var track: c_int = 0;
    var pitch: c_long = 0;
    var velocity: c_long = st.PIANO_NOTE_VELOCITY;
    var start: f64 = 0.0;
    var length: f64 = 0.0;
    if (argc != 5 and argc != 6) return "usage: note <track> <pitch> <start> <length> [velocity]";
    if (control_parse_track(argv[1], &track) == 0) return "track must be 1..8";
    if (control_parse_int(argv[2], 0, 127, &pitch) == 0) return "pitch must be 0..127";
    if (control_parse_double(argv[3], 0.0, 1.0e6, &start) == 0) return "start must be a number of beats >= 0";
    if (control_parse_double(argv[4], 0.0, 1.0e6, &length) == 0 or length <= 0.0) return "length must be a number of beats > 0";
    if (argc == 6 and control_parse_int(argv[5], 1, 127, &velocity) == 0) return "velocity must be 1..127";
    var before: st.NoteSnapshot = undefined;
    fns.piano_undo_begin(track, &before);
    if (ext.midi_clip_add_note(track, start, length, @truncate(@as(c_ulong, @bitCast(pitch))), @truncate(@as(c_ulong, @bitCast(velocity)))) == 0) {
        fns.snapshot_free(&before);
        return "could not add that note";
    }
    fns.piano_undo_commit(track, &before, "Add note");
    control_show_piano_track(track);
    fns.set_status("Note added from the command socket");
    return null;
}

pub fn control_clear(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    var track: c_int = 0;
    if (argc != 2) return "usage: clear <track>";
    if (control_parse_track(argv[1], &track) == 0) return "track must be 1..8";
    var before: st.NoteSnapshot = undefined;
    fns.piano_undo_begin(track, &before);
    ext.midi_clip_clear(track);
    fns.piano_undo_commit(track, &before, "Clear notes");
    control_show_piano_track(track);
    fns.set_status("Notes cleared from the command socket");
    return null;
}

pub fn control_set(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    var track: c_int = 0;
    if (argc != 4) return "usage: set <track> gain|pan|mute|solo|arm <value>";
    if (control_parse_track(argv[1], &track) == 0) return "track must be 1..8";
    const field: [*c]const u8 = argv[2];
    const value: [*c]const u8 = argv[3];
    var number: f64 = 0.0;
    var on: c_int = 0;
    if (libc.strcmp(field, "gain") == 0) {
        if (control_parse_double(value, 0.0, st.CONTROL_GAIN_MAX, &number) == 0) return "gain must be 0..1.5";
        ext.audio_engine_set_track_gain(app.engine, track, @floatCast(number));
    } else if (libc.strcmp(field, "pan") == 0) {
        if (control_parse_double(value, -1.0, 1.0, &number) == 0) return "pan must be -1..1";
        ext.audio_engine_set_track_pan(app.engine, track, @floatCast(number));
        ext.project_set_track_pan(track, @floatCast(number));
    } else if (libc.strcmp(field, "mute") == 0 or libc.strcmp(field, "solo") == 0 or libc.strcmp(field, "arm") == 0) {
        if (control_parse_switch(value, &on) == 0) return "value must be on or off";
        if (field[0] == 'm') {
            ext.audio_engine_set_track_mute(app.engine, track, on);
        } else if (field[0] == 's') {
            ext.audio_engine_set_track_solo(app.engine, track, on);
        } else {
            ext.audio_engine_set_track_arm(app.engine, track, on);
        }
    } else if (libc.strcmp(field, "instrument") == 0) {
        const type_count = ext.audio_engine_get_instrument_type_count();
        var type_: c_int = -1;
        var i: c_int = 0;
        while (i < type_count) : (i += 1) {
            const name = ext.audio_engine_get_instrument_type_name(i);
            if (name != null and libc.strcasecmp(name, value) == 0) {
                type_ = i;
                break;
            }
        }
        if (type_ < 0) return "unknown instrument (try: Keys, WavetableSynth, SuperSaw)";
        if (ext.audio_engine_set_track_instrument(app.engine, track, type_) != 0) return "could not set the instrument";
    } else {
        return "field must be gain, pan, mute, solo, arm or instrument";
    }
    fns.mixer_sync_all();
    return null;
}

pub fn control_auto_field(field: [*c]const u8) c_int {
    if (libc.strcmp(field, "gain") == 0) return st.AUTO_TRACK_GAIN;
    if (libc.strcmp(field, "pan") == 0) return st.AUTO_TRACK_PAN;
    if (libc.strcmp(field, "wet") == 0) return st.AUTO_TRACK_WET;
    return -1;
}

pub fn control_auto_add(target: c_int, track: c_int, beat_text: [*c]const u8, value_text: [*c]const u8) [*c]const u8 {
    var beat: f64 = 0.0;
    var value: f64 = 0.0;
    if (control_parse_double(beat_text, 0.0, 1.0e6, &beat) == 0) return "beat must be a number >= 0";
    const low: f64 = if (target == st.AUTO_TRACK_PAN) -1.0 else 0.0;
    if (control_parse_double(value_text, low, 1.0, &value) == 0) {
        return if (target == st.AUTO_TRACK_PAN) "pan must be -1..1" else "value must be 0..1";
    }
    if (target == st.AUTO_TRACK_WET and ext.audio_engine_track_has_reverb(app.engine, track) == 0) {
        return "that track has no reverb to automate";
    }
    const result = ext.audio_engine_automation_add(app.engine, target, track, beat, @floatCast(value));
    if (result == -2) return "that lane is full";
    if (result != 0) return "could not add the automation point";
    return null;
}

/// auto TRACK gain|pan|wet BEAT VALUE, auto master gain BEAT VALUE, auto clear TRACK gain|pan|wet
pub fn control_auto(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    const usage: [*c]const u8 = "usage: auto <track> gain|pan|wet <beat> <value> | auto master gain <beat> <value> | auto clear <track> gain|pan|wet";
    var track: c_int = 0;
    if (argc < 2) return usage;
    if (libc.strcmp(argv[1], "master") == 0) {
        if (argc != 5 or libc.strcmp(argv[2], "gain") != 0) return usage;
        return control_auto_add(st.AUTO_MASTER_GAIN, 0, argv[3], argv[4]);
    }
    if (libc.strcmp(argv[1], "clear") == 0) {
        if (argc != 4) return usage;
        if (control_parse_track(argv[2], &track) == 0) return "track must be 1..8";
        const target = control_auto_field(argv[3]);
        if (target < 0) return "lane must be gain, pan or wet";
        return if (ext.audio_engine_automation_clear(app.engine, target, track) == 0) null else "could not clear the lane";
    }
    if (argc != 5) return usage;
    if (control_parse_track(argv[1], &track) == 0) return "track must be 1..8";
    const target = control_auto_field(argv[2]);
    if (target < 0) return "lane must be gain, pan or wet";
    return control_auto_add(target, track, argv[3], argv[4]);
}

/// eq TRACK preset drums|bass|pads|lead|harp, eq master tilt on|off
pub fn control_eq(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    const usage: [*c]const u8 = "usage: eq <track> preset drums|bass|pads|lead|harp | eq master tilt on|off";
    var track: c_int = 0;
    var on: c_int = 0;
    if (argc != 4) return usage;
    if (libc.strcmp(argv[1], "master") == 0) {
        if (libc.strcmp(argv[2], "tilt") != 0) return usage;
        if (control_parse_switch(argv[3], &on) == 0) return "value must be on or off";
        const result = ext.audio_engine_eq_master_tilt(app.engine, on);
        if (result == -2) return "the master effects chain is full";
        return if (result == 0) null else "could not set the master tilt";
    }
    if (control_parse_track(argv[1], &track) == 0) return "track must be 1..8";
    if (libc.strcmp(argv[2], "preset") != 0) return usage;
    const result = ext.audio_engine_eq_preset(app.engine, track, argv[3]);
    if (result == -2) return "that track's effects chain is full";
    return if (result == 0) null else "preset must be drums, bass, pads, lead or harp";
}

pub fn control_check_path(argv: [*c][*c]u8, argc: c_int, usage: [*c]const u8) [*c]const u8 {
    if (argc != 2) return usage;
    if (argv[1][0] == 0) return "path is empty";
    if (libc.strlen(argv[1]) > st.CONTROL_PATH_MAX) return "path is too long";
    return null;
}

pub fn control_save(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    const problem = control_check_path(argv, argc, "usage: save <path>");
    if (problem != null) return problem;
    if (fns.make_directory_tree(argv[1]) != 0) return "could not create the folder";
    fns.project_capture_mixer();
    if (ext.project_save_as(argv[1]) != 0) return "could not save the session";
    fns.update_project_title();
    fns.set_status("Session saved from the command socket");
    return null;
}

pub fn control_open_session(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    const problem = control_check_path(argv, argc, "usage: open <path>");
    if (problem != null) return problem;
    if (fns.open_session_folder(argv[1]) != 0) return "could not open the session";
    fns.set_status("Session opened from the command socket");
    return null;
}

pub fn control_export(argv: [*c][*c]u8, argc: c_int) [*c]const u8 {
    const problem = control_check_path(argv, argc, "usage: export <path>");
    if (problem != null) return problem;
    if (ext.audio_engine_is_playing(app.engine) != 0) return "stop playback before exporting";
    if (ext.audio_export_wav(app.engine, argv[1], 0.0, 16) != 0) return "could not export the WAV";
    _ = libc.snprintf(&st.control_ok_detail, st.control_ok_detail.len, "peak %.3f", @as(f64, ext.audio_export_last_peak()));
    fns.set_status("WAV exported from the command socket");
    return null;
}

/// Runs one command line. Returns NULL on success or a message for the client.
pub fn control_run_line(line: [*c]u8) [*c]const u8 {
    var argv: [8][*c]u8 = undefined;
    var argc: c_int = 0;
    var save: [*c]u8 = null;
    var token: [*c]u8 = libc.strtok_r(line, " \t\r", &save);
    while (token != null) : (token = libc.strtok_r(null, " \t\r", &save)) {
        if (argc == 8) return "too many arguments";
        argv[@intCast(argc)] = token;
        argc += 1;
    }
    if (argc == 0) return "empty command";
    const name: [*c]const u8 = argv[0];
    if (libc.strcmp(name, "play") == 0 and argc == 1) {
        if (ext.audio_engine_is_playing(app.engine) == 0) fns.on_play(raven.R_INVALID_ID, null);
        return if (ext.audio_engine_is_playing(app.engine) != 0) null else "could not start the audio engine";
    }
    if (libc.strcmp(name, "stop") == 0 and argc == 1) {
        fns.on_stop(raven.R_INVALID_ID, null);
        return null;
    }
    if (libc.strcmp(name, "bpm") == 0) {
        var bpm: f64 = 0.0;
        if (argc != 2) return "usage: bpm <20..300>";
        if (control_parse_double(argv[1], st.CONTROL_BPM_MIN, st.CONTROL_BPM_MAX, &bpm) == 0) return "bpm must be 20..300";
        fns.bpm_apply(bpm);
        return null;
    }
    if (libc.strcmp(name, "set") == 0) return control_set(&argv, argc);
    if (libc.strcmp(name, "auto") == 0) return control_auto(&argv, argc);
    if (libc.strcmp(name, "eq") == 0) return control_eq(&argv, argc);
    if (libc.strcmp(name, "note") == 0) return control_note(&argv, argc);
    if (libc.strcmp(name, "clear") == 0) return control_clear(&argv, argc);
    if (libc.strcmp(name, "save") == 0) return control_save(&argv, argc);
    if (libc.strcmp(name, "export") == 0) return control_export(&argv, argc);
    if (libc.strcmp(name, "open") == 0) return control_open_session(&argv, argc);
    return "unknown command";
}

pub fn control_reply(fd: c_int, error_: [*c]const u8) void {
    var reply: [160]u8 = undefined;
    var length: c_int = undefined;
    if (error_ != null) {
        length = libc.snprintf(&reply, reply.len, "error: %s\n", error_);
    } else if (st.control_ok_detail[0] != 0) {
        length = libc.snprintf(&reply, reply.len, "ok %s\n", @as([*c]const u8, &st.control_ok_detail));
    } else {
        length = libc.snprintf(&reply, reply.len, "ok\n");
    }
    st.control_ok_detail[0] = 0;
    if (length > 0) _ = libc.send(fd, &reply, @intCast(length), libc.MSG_NOSIGNAL | libc.MSG_DONTWAIT);
}

pub fn control_drop(client: [*c]st.ControlClient) void {
    _ = libc.close(client.*.fd);
    client.*.fd = -1;
}

/// Called once per frame: accepts new clients and runs every complete line. Never blocks.
pub fn control_poll() void {
    if (st.control_listen_fd < 0) return;
    {
        var accepted: c_int = 0;
        while (accepted < st.CONTROL_MAX_CLIENTS) : (accepted += 1) {
            const fd = libc.accept4(st.control_listen_fd, null, null, libc.SOCK_NONBLOCK | libc.SOCK_CLOEXEC);
            if (fd < 0) break;
            var slot: [*c]st.ControlClient = null;
            var i: c_int = 0;
            while (i < st.CONTROL_MAX_CLIENTS and slot == null) : (i += 1) {
                if (st.control_clients[@intCast(i)].fd < 0) slot = &st.control_clients[@intCast(i)];
            }
            if (slot == null) {
                _ = libc.close(fd);
                continue;
            }
            slot.*.fd = fd;
            slot.*.length = 0;
            slot.*.frames = 0;
        }
    }
    {
        var i: c_int = 0;
        while (i < st.CONTROL_MAX_CLIENTS) : (i += 1) {
            const client: *st.ControlClient = &st.control_clients[@intCast(i)];
            if (client.fd < 0) continue;
            const buffer: [*c]u8 = @as([*c]u8, &client.line) + @as(usize, @intCast(client.length));
            const got: isize = libc.recv(client.fd, @ptrCast(buffer), @intCast(st.CONTROL_LINE_CAPACITY - client.length), libc.MSG_DONTWAIT);
            if (got == 0) {
                control_drop(client);
                continue;
            }
            if (got < 0) {
                // (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) && ++client->frames < CONTROL_CLIENT_MAX_FRAMES
                if (libc.errno() == libc.EAGAIN or libc.errno() == libc.EWOULDBLOCK or libc.errno() == libc.EINTR) {
                    client.frames += 1;
                    if (client.frames < st.CONTROL_CLIENT_MAX_FRAMES) continue;
                }
                control_drop(client);
                continue;
            }
            client.length += @as(c_int, @intCast(got));
            const newline: [*c]u8 = @ptrCast(libc.memchr(&client.line, '\n', @intCast(client.length)));
            if (newline != null) {
                newline.* = 0;
                control_reply(client.fd, control_run_line(&client.line));
                control_drop(client);
            } else if (client.length >= st.CONTROL_LINE_CAPACITY) {
                control_reply(client.fd, "line too long");
                control_drop(client);
            }
        }
    }
}

pub export fn seridian_raven_run(engine: ?*anyopaque) callconv(.c) c_int {
    app.* = std.mem.zeroes(st.SeridianApp);
    app.engine = engine;
    app.window = raven.R_INVALID_ID;
    app.timeline = raven.R_INVALID_ID;
    app.status_label = raven.R_INVALID_ID;
    app.midi_header_label = raven.R_INVALID_ID;
    app.midi_status_label = raven.R_INVALID_ID;
    app.midi_port_combo = raven.R_INVALID_ID;
    app.midi_track_combo = raven.R_INVALID_ID;
    app.clock_label = raven.R_INVALID_ID;
    app.position_label = raven.R_INVALID_ID;
    app.project_label = raven.R_INVALID_ID;
    app.clip_empty_hint = raven.R_INVALID_ID;
    app.selected_item = -1;
    app.master_gain = 0.75;
    app.piano_track = 0;
    app.piano_base_pitch = st.PIANO_ROLL_DEFAULT_BASE_PITCH;
    app.piano_roll = raven.R_INVALID_ID;
    app.popout_window = raven.R_INVALID_ID;
    app.popout_roll = raven.R_INVALID_ID;
    app.popout_grid_combo = raven.R_INVALID_ID;
    app.main_tab_view = raven.R_INVALID_ID;
    app.popout_toggle_button = raven.R_INVALID_ID;
    fns.piano_held_reset();
    // Saved device settings are applied before the window (and the first UI frame) starts. A missing or
    // corrupt file means the engine keeps its defaults; the Zig side logs the outcome.
    _ = ext.seridian_audio_settings_load(app.engine);
    fns.resolve_state_path();
    {
        var view: c_int = 0;
        while (view < st.MIXER_VIEW_COUNT) : (view += 1) fns.mixer_view_init(&app.mixers[@intCast(view)]);
    }
    {
        var track: c_int = 0;
        while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
            app.track_color_index[@intCast(track)] = st.default_track_color_index[@intCast(track)];
        }
    }

    var init = std.mem.zeroes(raven.RInitDesc);
    if (@import("ui_options").headless) {
        // Headless build: Raven's null platform and null renderer; no window system, no GPU.
        init.backend = raven.R_BACKEND_NULL;
        init.headless = raven.R_TRUE;
    } else {
        init.backend = raven.R_BACKEND_VULKAN;
    }
    init.app_name = "Seridian Studio";
    // Before the first window: the desktop entry and the doctor's window rules match this class, not `raven`.
    const identity = @import("../app_identity.zig");
    raven.Rset_window_class(identity.window_class, identity.window_class);
    init.worker_threads = 4;
    init.ui_scale = 1.0;
    if (raven.Rinit_ex(&init) == 0) return 1;

    raven.Rtheme_apply(raven.R_THEME_DARK);
    raven.Rtheme_set_color(raven.R_COLOR_WINDOW, 0.020, 0.024, 0.051, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_PANEL, 0.063, 0.071, 0.165, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_BORDER, 0.110, 0.160, 0.300, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TEXT, 0.91, 0.93, 0.95, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TEXT_DISABLED, 0.48, 0.52, 0.58, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TEXT_PLACEHOLDER, 0.42, 0.46, 0.52, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_ACCENT, 0.000, 0.941, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_ACCENT_HOVERED, 0.450, 0.970, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_ACCENT_PRESSED, 0.000, 0.660, 0.780, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_ACCENT_TEXT, 0.020, 0.024, 0.051, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_CONTROL, 0.10, 0.12, 0.14, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_CONTROL_HOVERED, 0.15, 0.18, 0.20, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_CONTROL_PRESSED, 0.20, 0.25, 0.15, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_CONTROL_BORDER, 0.19, 0.22, 0.25, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_INPUT, 0.055, 0.060, 0.068, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_FOCUS, 0.000, 0.941, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_SELECTION, 0.060, 0.200, 0.270, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_ROW_HOVERED, 0.12, 0.14, 0.15, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TRACK, 0.10, 0.12, 0.14, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_HANDLE, 0.000, 0.941, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_HANDLE_HOVERED, 0.450, 0.970, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_SEPARATOR, 0.110, 0.160, 0.300, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_HEADER, 0.09, 0.10, 0.11, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_HEADER_HOVERED, 0.13, 0.15, 0.16, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TAB_ACTIVE, 0.090, 0.140, 0.220, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_POPUP, 0.08, 0.09, 0.10, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_POPUP_BORDER, 0.20, 0.23, 0.26, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TOOLTIP, 0.08, 0.09, 0.10, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_TOOLTIP_TEXT, 0.91, 0.93, 0.95, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_SWITCH, 0.000, 0.941, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_SUCCESS, 0.000, 0.941, 1.000, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_WARNING, 1.0, 0.70, 0.28, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_DANGER, 1.0, 0.38, 0.38, 1.0);
    raven.Rtheme_set_color(raven.R_COLOR_LINK, 0.29, 0.85, 1.0, 1.0);
    app.window = raven.Rwindow_create("Seridian Studio — seridian.dev", 1440, 920, raven.R_WINDOW_DEFAULT);
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }

    const root: raven.Rid = fns.make_column(10.0);
    raven.Rslot_set_padding(root, 14.0, 12.0, 14.0, 10.0);
    _ = raven.Rwidget_add_child(root, fns.build_header());
    _ = raven.Rwidget_add_child(root, fns.build_transport());
    _ = raven.Rwidget_add_child(root, fns.build_main_tabs());
    _ = raven.Rwidget_add_child(root, fns.build_track_mixer());
    _ = raven.Rwidget_add_child(root, fns.build_status_bar());
    raven.Rwindow_set_content(app.window, root);
    raven.Rwindow_set_clear_color(app.window, 0.020, 0.024, 0.051, 1.0);
    raven.Rwindow_set_close_callback(app.window, &fns.on_window_close, null);
    window_input.seridian_window_input_install(app.window);
    if (ext.undo_init() != 0) fns.set_status("Undo history is unavailable");
    ext.undo_set_apply_callback(&fns.piano_undo_apply);
    if (window_input.seridian_window_input_add(&fns.keymap_key_handler, null) != 0) fns.set_status("Keyboard shortcuts are unavailable");
    if (window_input.seridian_window_input_add(&fns.strip_click_handler, null) != 0) fns.set_status("Mixer strip selection is unavailable");
    if (window_input.seridian_window_input_add(&fns.piano_key_handler, null) != 0) fns.set_status("Piano keys are unavailable");

    fns.populate_timeline();
    raven.Rwindow_show(app.window);
    fns.popout_restore();
    fns.mixer_popout_restore();

    fns.offer_recovery();
    st.autosave_baseline = fns.session_signature();
    st.autosave_next_time = fns.monotonic_seconds() + st.AUTOSAVE_INTERVAL_SECONDS;
    control_open();
    // System check (not in the C): runs on a worker thread; preflight_poll shows the result.
    fns.preflight_init();
    // Idle/suspend inhibit while playing or recording (not in the C).
    fns.idle_inhibit_init();
    var frame_count: c_uint = 0;
    while (raven.Rwait_frame(1.0 / 30.0) != 0) {
        // frame_count++ % STATE_SNAPSHOT_EVERY_FRAMES
        const snapshot_due = frame_count % st.STATE_SNAPSHOT_EVERY_FRAMES == 0;
        frame_count +%= 1;
        if (snapshot_due) fns.write_state_snapshot();
        fns.sync_transport_visuals(frame_count);
        fns.midi_refresh_tick();
        if (ext.audio_engine_is_playing(app.engine) != 0) {
            const rate: u32 = ext.audio_engine_get_sample_rate(app.engine);
            if (rate > 0) {
                const seconds: f64 = @as(f64, @floatFromInt(ext.audio_engine_get_position(app.engine))) / @as(f64, @floatFromInt(rate));
                raven.Rtimeline_set_time(app.timeline, seconds);
                fns.update_clock(seconds);
            }
        }
        fns.update_piano_playhead();
        fns.update_track_meters();
        fns.popout_poll_geometry();
        fns.mixer_popout_poll();
        control_poll();
        fns.autosave_tick();
        fns.preflight_poll();
        fns.idle_inhibit_tick();
    }

    control_close();
    fns.preflight_shutdown();
    fns.piano_release_all_held();
    ext.audio_engine_stop(app.engine);
    fns.idle_inhibit_shutdown();
    raven.Rshutdown();
    return 0;
}
