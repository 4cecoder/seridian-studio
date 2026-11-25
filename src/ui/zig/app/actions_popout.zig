//! Translated to Zig from src/ui/raven_app.c lines 3460-4204: keymap actions, input handlers and the Piano Roll popout window. Seridian Studio window, 1:1 translation.

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

/// PATH_MAX from <limits.h> (Linux): not in libc.zig.
const PATH_MAX = 4096;

/// Runs one keymap action. Note edits apply to the Piano Roll tab, or to the popout when `from_popout` is set;
/// other actions work everywhere.
pub fn run_action_for(action: ext.SeridianAction, from_popout: c_int) void {
    if ((action == ext.SERIDIAN_ACTION_FILE_NEW or action == ext.SERIDIAN_ACTION_FILE_OPEN or
        action == ext.SERIDIAN_ACTION_FILE_SAVE_AS or action == ext.SERIDIAN_ACTION_FILE_EXPORT_WAV) and
        fns.modal_dialog_open() != 0)
    {
        fns.set_status("Finish or cancel the open dialog first");
        return;
    }
    switch (action) {
        ext.SERIDIAN_ACTION_NONE => {},
        ext.SERIDIAN_ACTION_PLAY_STOP => {
            fns.on_play(raven.R_INVALID_ID, null);
        },
        ext.SERIDIAN_ACTION_STOP_AND_REWIND => {
            fns.on_stop(raven.R_INVALID_ID, null);
        },
        ext.SERIDIAN_ACTION_UNDO, ext.SERIDIAN_ACTION_REDO => {
            const is_undo: c_int = @intFromBool(action == ext.SERIDIAN_ACTION_UNDO);
            st.piano_undo_restore_failed = 0;
            const done: c_int = if (is_undo != 0) ext.undo_undo() else ext.undo_redo();
            fns.piano_roll_reload();
            if (done == 0) {
                fns.set_status(if (is_undo != 0) "Nothing to undo" else "Nothing to redo");
            } else if (st.piano_undo_restore_failed != 0) {
                fns.set_status(if (is_undo != 0) "Undo only partly applied" else "Redo only partly applied");
            } else {
                fns.set_status(if (is_undo != 0) "Undo" else "Redo");
            }
        },
        ext.SERIDIAN_ACTION_SELECT_ALL,
        ext.SERIDIAN_ACTION_COPY,
        ext.SERIDIAN_ACTION_CUT,
        ext.SERIDIAN_ACTION_PASTE,
        ext.SERIDIAN_ACTION_DUPLICATE,
        ext.SERIDIAN_ACTION_DELETE,
        => blk: {
            if (from_popout == 0 and fns.piano_roll_active() == 0) {
                var message: [64]u8 = undefined;
                const name = if (@import("builtin").os.tag == .macos) "Cmd" else "Ctrl";
                _ = libc.snprintf(&message, message.len, "Open the Piano Roll (%s+2) to edit notes", name);
                fns.set_status(&message);
                break :blk;
            }
            if (action == ext.SERIDIAN_ACTION_SELECT_ALL) {
                fns.piano_edit_select_all();
            } else if (action == ext.SERIDIAN_ACTION_COPY) {
                fns.piano_edit_copy();
            } else if (action == ext.SERIDIAN_ACTION_CUT) {
                fns.piano_edit_cut();
            } else if (action == ext.SERIDIAN_ACTION_PASTE) {
                fns.piano_edit_paste();
            } else if (action == ext.SERIDIAN_ACTION_DUPLICATE) {
                fns.piano_edit_duplicate();
            } else {
                fns.piano_edit_delete();
            }
        },
        ext.SERIDIAN_ACTION_SPLIT_AT_PLAYHEAD => {
            fns.split_at_playhead();
        },
        ext.SERIDIAN_ACTION_FILE_NEW => {
            fns.on_new_project(raven.R_INVALID_ID, null);
        },
        ext.SERIDIAN_ACTION_FILE_OPEN => {
            fns.on_open_project(raven.R_INVALID_ID, null);
        },
        ext.SERIDIAN_ACTION_FILE_SAVE => {
            fns.save_session(0);
        },
        ext.SERIDIAN_ACTION_FILE_SAVE_AS => {
            fns.save_session(1);
        },
        ext.SERIDIAN_ACTION_FILE_EXPORT_WAV => {
            fns.export_wav();
        },
        ext.SERIDIAN_ACTION_VIEW_ARRANGEMENT => {
            raven.Rtab_view_set_active(app.main_tab_view, st.SERIDIAN_MAIN_TAB_ARRANGEMENT);
        },
        ext.SERIDIAN_ACTION_VIEW_PIANO_ROLL => {
            raven.Rtab_view_set_active(app.main_tab_view, st.SERIDIAN_MAIN_TAB_PIANO_ROLL);
        },
        ext.SERIDIAN_ACTION_ZOOM_IN => {
            fns.zoom_timeline(0.5);
        },
        ext.SERIDIAN_ACTION_ZOOM_OUT => {
            fns.zoom_timeline(2.0);
        },
        ext.SERIDIAN_ACTION_POPOUT_PIANO_ROLL => {
            popout_toggle();
        },
        ext.SERIDIAN_ACTION_POPOUT_MIXER => {
            fns.mixer_popout_toggle();
        },
        ext.SERIDIAN_ACTION_TOGGLE_FULLSCREEN => {
            toggle_window_maximized(app.window);
        },
        else => {},
    }
}

/// F11: Raven has no fullscreen call, only maximize and restore, so F11 toggles between those for `window`.
pub fn toggle_window_maximized(window: raven.Rid) void {
    if (window == raven.R_INVALID_ID or raven.Rwindow_is_valid(window) == 0) return;
    if (ext.seridian_keymap_restore_on_f11(raven.Rwindow_is_maximized(window)) != 0) {
        raven.Rwindow_restore(window);
        fns.set_status("Window restored");
    } else {
        raven.Rwindow_maximize(window);
        fns.set_status("Window maximized");
    }
}

pub fn run_action(action: ext.SeridianAction) void {
    run_action_for(action, 0);
}

/// True while a text field has the keyboard, so typing keeps its own Space, Delete and shortcuts.
pub fn text_entry_focused() c_int {
    const focused = raven.Rwindow_get_focused_widget(app.window);
    if (focused == raven.R_INVALID_ID) return 0;
    switch (raven.Rwidget_get_type(focused)) {
        raven.R_WIDGET_TEXT_INPUT, raven.R_WIDGET_SPIN_BOX, raven.R_WIDGET_TEXT_EDITOR => return 1,
        else => return 0,
    }
}

/// Makes `track` the target of the piano roll and the track FX tab.
pub fn select_track(track: c_int) void {
    if (track < 0 or track >= st.SERIDIAN_TRACK_COUNT) return;
    if (track != app.piano_track) {
        fns.piano_release_all_held();
        app.piano_track = track;
        fns.piano_roll_reload();
    }
    if (app.piano_track_combo != raven.R_INVALID_ID) raven.Rcombo_box_set_selected(app.piano_track_combo, track);
    if (track != app.fx_track) {
        app.fx_track = track;
        fns.rebuild_fx_slots();
    }
    if (app.fx_track_combo != raven.R_INVALID_ID) raven.Rcombo_box_set_selected(app.fx_track_combo, track);
    var message: [48]u8 = undefined;
    _ = libc.snprintf(&message, message.len, "Selected track %d", track + 1);
    fns.set_status(&message);
}

pub fn point_in_widget(widget: raven.Rid, x: f32, y: f32) c_int {
    if (widget == raven.R_INVALID_ID) return 0;
    if (raven.Rwidget_is_valid(widget) == 0 or raven.Rwidget_get_visibility(widget) != raven.R_VISIBLE) return 0;
    var rx: f32 = undefined;
    var ry: f32 = undefined;
    var rw: f32 = undefined;
    var rh: f32 = undefined;
    raven.Rwidget_get_rect(widget, &rx, &ry, &rw, &rh);
    return @intFromBool(x >= rx and x < rx + rw and y >= ry and y < ry + rh);
}

/// Left-click on a mixer strip's name or colour bar selects that track.
pub fn strip_click_handler(context: ?*anyopaque, raw_event: ?*const anyopaque) callconv(.c) c_int {
    _ = context;
    const event: [*c]const raven.REvent = @ptrCast(@alignCast(raw_event));
    if (event.*.type != raven.R_EVENT_MOUSE_DOWN or event.*.button != raven.R_MOUSE_LEFT) return 0;
    const dock_root = app.mixers[st.MIXER_VIEW_DOCK].root;
    // A collapsed or hidden docked mixer (the popout is open) keeps a stale rectangle: it must not catch clicks.
    if (dock_root == raven.R_INVALID_ID or raven.Rwidget_is_valid(dock_root) == 0 or raven.Rwidget_get_visibility(dock_root) != raven.R_VISIBLE) return 0;
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        if (point_in_widget(app.mixers[st.MIXER_VIEW_DOCK].name_labels[@intCast(track)], event.*.x, event.*.y) != 0 or
            point_in_widget(app.mixers[st.MIXER_VIEW_DOCK].color_bars[@intCast(track)], event.*.x, event.*.y) != 0)
        {
            select_track(track);
            return 0;
        }
    }
    return 0;
}

/// Window-level keymap (src/ui/zig/keymap.zig). Consumes every key the table maps.
pub fn keymap_key_handler(context: ?*anyopaque, raw_event: ?*const anyopaque) callconv(.c) c_int {
    _ = context;
    const event: [*c]const raven.REvent = @ptrCast(@alignCast(raw_event));
    if (event.*.type != raven.R_EVENT_KEY_DOWN) return 0;
    const action: ext.SeridianAction = ext.seridian_keymap_lookup(@bitCast(event.*.key), event.*.modifiers);
    if (action == ext.SERIDIAN_ACTION_NONE) return 0;
    if (text_entry_focused() != 0) return 0;
    if (event.*.repeat == 0) run_action(action);
    return 1;
}

// ---- Piano Roll popout ----------------------------------------------------

/// Current geometry of the popout window.
pub fn popout_read_geometry(x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int) void {
    raven.Rwindow_get_position(app.popout_window, x, y);
    raven.Rwindow_get_size(app.popout_window, width, height);
}

// ---- seridian helper (the wm layer): `seridian wm monitors` and `seridian wm place` ----

/// Path of the seridian binary next to this executable. Returns 0 when it is not there.
pub fn seridian_helper_path(out: [*c]u8, capacity: usize) c_int {
    // run.sh sets SERIDIAN_CLI: `zig build run` executes the app from Zig's cache, so the
    // helper next to /proc/self/exe is not there.
    const override = libc.getenv("SERIDIAN_CLI");
    if (override != null and override[0] != 0) {
        if (libc.snprintf(out, capacity, "%s", override) >= @as(c_int, @intCast(capacity))) return 0;
        return @intFromBool(libc.access(out, libc.X_OK) == 0);
    }
    var self: [PATH_MAX]u8 = undefined;
    const n: isize = libc.readlink("/proc/self/exe", &self, self.len - 1);
    if (n <= 0) return 0;
    self[@intCast(n)] = 0;
    const slash = libc.strrchr(&self, '/');
    if (slash == null) return 0;
    slash[1] = 0;
    if (libc.snprintf(out, capacity, "%sseridian", @as([*c]const u8, &self)) >= @as(c_int, @intCast(capacity))) return 0;
    return @intFromBool(libc.access(out, libc.X_OK) == 0);
}

pub fn monotonic_ms() c_long {
    var now: libc.timespec = undefined;
    _ = libc.clock_gettime(libc.CLOCK_MONOTONIC, &now);
    return @as(c_long, now.sec) * 1000 + @divTrunc(@as(c_long, now.nsec), 1000000);
}

/// In the forked child: stdio to /dev/null (and stdout to `stdout_fd` when it is >= 0), drop every other
/// descriptor, exec. Only async-signal-safe calls. Never returns.
pub fn helper_exec_child(path: [*c]const u8, argv: [*c]const [*c]u8, stdout_fd: c_int) void {
    const null_fd = libc.open("/dev/null", libc.O_RDWR);
    if (null_fd >= 0) {
        _ = libc.dup2(null_fd, 0);
        _ = libc.dup2(null_fd, 2);
        if (stdout_fd < 0) _ = libc.dup2(null_fd, 1);
    }
    if (stdout_fd >= 0) _ = libc.dup2(stdout_fd, 1);
    _ = libc.close_range(3, ~@as(c_uint, 0), 0);
    _ = libc.execv(path, argv);
    libc._exit(127);
}

/// Runs `seridian wm <subcommand>` and captures its stdout into out (NUL-terminated, at most capacity - 1 bytes).
/// Waits at most WM_QUERY_TIMEOUT_MS. Returns the length on success, or -1 on any failure.
pub fn seridian_wm_capture(subcommand: [*c]const u8, out: [*c]u8, capacity: usize) c_long {
    var path: [PATH_MAX]u8 = undefined;
    if (seridian_helper_path(&path, path.len) == 0) return -1;
    var fds: [2]c_int = undefined;
    if (libc.pipe2(&fds, libc.O_CLOEXEC) != 0) return -1;
    const argv = [_][*c]u8{ &path, @constCast("wm"), @constCast(subcommand), null };
    const pid = libc.fork();
    if (pid < 0) {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
        return -1;
    }
    if (pid == 0) helper_exec_child(&path, &argv, fds[1]);
    _ = libc.close(fds[1]);

    var length: usize = 0;
    var full: c_int = 0;
    var timed_out: c_int = 0;
    const deadline: c_long = monotonic_ms() + st.WM_QUERY_TIMEOUT_MS;
    while (true) {
        const left: c_long = deadline - monotonic_ms();
        if (left <= 0) {
            timed_out = 1;
            break;
        }
        var pfd: libc.pollfd = .{ .fd = fds[0], .events = libc.POLLIN, .revents = 0 };
        const ready = libc.poll(&pfd, 1, @intCast(left));
        if (ready < 0 and libc.errno() == libc.EINTR) continue;
        if (ready <= 0) {
            timed_out = @intFromBool(ready == 0);
            break;
        }
        const got: isize = libc.read(fds[0], out + length, capacity - 1 - length);
        if (got < 0 and libc.errno() == libc.EINTR) continue;
        if (got <= 0) break; // end of output
        length += @intCast(got);
        if (length >= capacity - 1) {
            full = 1;
            break;
        }
    }
    _ = libc.close(fds[0]);
    if (timed_out != 0 or full != 0) _ = libc.kill(pid, libc.SIGKILL);
    var status: c_int = 0;
    var reaped: libc.pid_t = undefined;
    while (true) {
        reaped = libc.waitpid(pid, &status, 0);
        if (!(reaped < 0 and libc.errno() == libc.EINTR)) break;
    }
    if (timed_out != 0 or full != 0 or reaped != pid or !libc.WIFEXITED(status) or libc.WEXITSTATUS(status) != 0) return -1;
    out[length] = 0;
    return @intCast(length);
}

/// Runs `seridian wm monitors` and keeps its output in app.wm_monitors. On any failure the list is left empty.
pub fn popout_query_monitors() void {
    app.wm_monitors_len = 0;
    app.wm_monitors[0] = 0;
    const length = seridian_wm_capture("monitors", &app.wm_monitors, st.WM_OUTPUT_CAPACITY);
    if (length < 0) {
        app.wm_monitors[0] = 0;
        return;
    }
    app.wm_monitors_len = @intCast(length);
}

/// Runs `seridian wm detect` and copies the word after its "backend:" line into backend (lowercase as printed).
/// Returns 1 when a backend was read, 0 when the helper failed or printed no such line.
pub fn popout_detect_backend(backend: [*c]u8, capacity: usize) c_int {
    var text: [256]u8 = undefined;
    backend[0] = 0;
    if (seridian_wm_capture("detect", &text, text.len) < 0) return 0;
    var line: [*c]const u8 = &text;
    while (line.* != 0) {
        while (line.* == ' ' or line.* == '\t') line += 1;
        if (libc.strncmp(line, "backend:", 8) == 0) {
            line += 8;
            while (line.* == ' ' or line.* == '\t') line += 1;
            var n: usize = 0;
            while (line[n] != 0 and line[n] != '\n' and line[n] != '\r' and line[n] != ' ' and line[n] != '\t') n += 1;
            if (n == 0 or n >= capacity) return 0;
            @memcpy(backend[0..n], line[0..n]);
            backend[n] = 0;
            return 1;
        }
        const eol = libc.strchr(line, '\n');
        if (eol == null) break;
        line = eol + 1;
    }
    return 0;
}

/// Appends one line naming the restore path chosen at popout open to $XDG_RUNTIME_DIR/seridian-popout.log.
pub fn popout_log_restore_path(path_name: [*c]const u8, backend: [*c]const u8) void {
    const dir = libc.getenv("XDG_RUNTIME_DIR");
    var path: [PATH_MAX]u8 = undefined;
    if (libc.snprintf(&path, path.len, "%s/seridian-popout.log", @as([*c]const u8, if (dir != null and dir[0] != 0) dir else "/tmp")) >= @as(c_int, path.len)) return;
    const log = libc.fopen(&path, "a") orelse return;
    _ = libc.fprintf(log, "%ld restore path=%s backend=\"%s\"\n", @as(c_long, libc.time(null)), path_name, backend);
    _ = libc.fclose(log);
}

/// Appends one line per placement attempt to $XDG_RUNTIME_DIR/seridian-popout.log (/tmp when unset).
pub fn popout_log_place(outcome: [*c]const u8) void {
    const dir = libc.getenv("XDG_RUNTIME_DIR");
    var path: [PATH_MAX]u8 = undefined;
    if (libc.snprintf(&path, path.len, "%s/seridian-popout.log", @as([*c]const u8, if (dir != null and dir[0] != 0) dir else "/tmp")) >= @as(c_int, path.len)) return;
    const log = libc.fopen(&path, "a") orelse return;
    _ = libc.fprintf(log, "%ld place monitor=\"%s\" argv=[%s] result=%s\n", @as(c_long, libc.time(null)), @as([*c]const u8, &app.popout_place_monitor), @as([*c]const u8, &app.popout_place_argv), outcome);
    _ = libc.fclose(log);
}

/// Describes a wait status: "exit status N" or "killed by signal N".
pub fn popout_describe_status(status: c_int, out: [*c]u8, capacity: usize) void {
    if (libc.WIFEXITED(status)) {
        _ = libc.snprintf(out, capacity, "exit status %d", libc.WEXITSTATUS(status));
    } else if (libc.WIFSIGNALED(status)) {
        _ = libc.snprintf(out, capacity, "killed by signal %d", libc.WTERMSIG(status));
    } else {
        _ = libc.snprintf(out, capacity, "unknown wait status %d", status);
    }
}

/// Starts `seridian wm place "Piano Roll" <monitor> dx dy w h` detached: fork and exec with no shell, no wait.
/// Returns 0 when the helper is missing or the fork failed.
pub fn popout_spawn_place() c_int {
    var path: [PATH_MAX]u8 = undefined;
    var dx: [16]u8 = undefined;
    var dy: [16]u8 = undefined;
    var width: [16]u8 = undefined;
    var height: [16]u8 = undefined;
    _ = libc.snprintf(&dx, dx.len, "%d", app.popout_place_dx);
    _ = libc.snprintf(&dy, dy.len, "%d", app.popout_place_dy);
    _ = libc.snprintf(&width, width.len, "%d", app.popout_place_w);
    _ = libc.snprintf(&height, height.len, "%d", app.popout_place_h);
    const size_only = app.popout_place_size_only;
    if (seridian_helper_path(&path, path.len) == 0) {
        _ = libc.snprintf(&app.popout_place_argv, app.popout_place_argv.len, "seridian wm %s (helper not found)", @as([*c]const u8, if (size_only != 0) "size" else "place"));
        popout_log_place("not started: helper missing");
        return 0;
    }
    // Only this app's own window may match: another instance has a popout with the same title.
    var owner: [16]u8 = undefined;
    _ = libc.snprintf(&owner, owner.len, "%ld", @as(c_long, libc.getpid()));
    const place_argv = [_][*c]u8{
        &path,  @constCast("wm"), @constCast("place"), @constCast(st.POPOUT_WINDOW_TITLE_MATCH), &app.popout_place_monitor,
        &dx,    &dy,              &width,              &height,                                  @constCast("--pid"),
        &owner, null,
    };
    const size_argv = [_][*c]u8{ &path, @constCast("wm"), @constCast("size"), @constCast(st.POPOUT_WINDOW_TITLE_MATCH), &width, &height, @constCast("--pid"), &owner, null };
    const argv: [*c]const [*c]u8 = if (size_only != 0) &size_argv else &place_argv;
    if (size_only != 0) {
        _ = libc.snprintf(&app.popout_place_argv, app.popout_place_argv.len, "%s wm size \"%s\" %s %s --pid %s", @as([*c]const u8, &path), @as([*c]const u8, st.POPOUT_WINDOW_TITLE_MATCH), @as([*c]const u8, &width), @as([*c]const u8, &height), @as([*c]const u8, &owner));
    } else {
        _ = libc.snprintf(&app.popout_place_argv, app.popout_place_argv.len, "%s wm place \"%s\" \"%s\" %s %s %s %s --pid %s", @as([*c]const u8, &path), @as([*c]const u8, st.POPOUT_WINDOW_TITLE_MATCH), @as([*c]const u8, &app.popout_place_monitor), @as([*c]const u8, &dx), @as([*c]const u8, &dy), @as([*c]const u8, &width), @as([*c]const u8, &height), @as([*c]const u8, &owner));
    }
    const pid = libc.fork();
    if (pid < 0) {
        popout_log_place("not started: fork failed");
        return 0;
    }
    if (pid == 0) helper_exec_child(&path, argv, -1);
    app.popout_place_pid = pid;
    return 1;
}

/// The one deferred step: runs when the popout reports focus (it is mapped) or after POPOUT_PLACE_TIMEOUT_FRAMES.
pub fn popout_place_now() void {
    if (app.popout_place_pending == 0) return;
    app.popout_place_pending = 0;
    app.popout_seen_valid = 0; // re-learn the geometry the window manager settles on
    _ = popout_spawn_place(); // a failed start is logged; an absent or failed placement is not a user-facing error
}

/// Records the outcome of a finished `wm place` child: log line, and a status note with the status on failure.
pub fn popout_finish_place(status: c_int) void {
    var what: [48]u8 = undefined;
    popout_describe_status(status, &what, what.len);
    popout_log_place(&what);
}

/// Collects the detached `wm place` child without blocking.
pub fn popout_reap_place() void {
    if (app.popout_place_pid <= 0) return;
    var status: c_int = 0;
    var reaped: libc.pid_t = undefined;
    while (true) {
        reaped = libc.waitpid(app.popout_place_pid, &status, libc.WNOHANG);
        if (!(reaped < 0 and libc.errno() == libc.EINTR)) break;
    }
    if (reaped == 0) return;
    app.popout_place_pid = 0;
    if (reaped < 0) {
        popout_log_place("lost: waitpid failed");
        return;
    }
    popout_finish_place(status);
}

/// Close and quit: the child must not outlive the popout. A child still running is killed, then reaped.
pub fn popout_reap_place_final() void {
    if (app.popout_place_pid <= 0) return;
    popout_reap_place();
    if (app.popout_place_pid <= 0) return;
    const pid = app.popout_place_pid;
    _ = libc.kill(pid, libc.SIGKILL);
    var status: c_int = 0;
    var reaped: libc.pid_t = undefined;
    while (true) {
        reaped = libc.waitpid(pid, &status, 0);
        if (!(reaped < 0 and libc.errno() == libc.EINTR)) break;
    }
    app.popout_place_pid = 0;
    popout_log_place(if (reaped == pid) "killed: popout closed before it finished" else "lost: waitpid failed");
}

/// Writes popouts.conf with the live geometry of the popout: `open` says whether the popout exists (and so should
/// come back on the next launch). The position is stored relative to the monitor holding the window's centre when
/// the monitor list is known, and as absolute x, y alone otherwise. A popout still waiting to be placed is not
/// saved: its position is the window manager's, not the user's.
pub fn popout_save_state(open: c_int) void {
    if (app.popout_place_pending != 0 or app.popout_user_placed == 0) return;
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = st.POPOUT_DEFAULT_WIDTH;
    var height: c_int = st.POPOUT_DEFAULT_HEIGHT;
    if (app.popout_window != raven.R_INVALID_ID and raven.Rwindow_is_valid(app.popout_window) != 0) popout_read_geometry(&x, &y, &width, &height);
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    var origin_x: c_int = 0;
    var origin_y: c_int = 0;
    popout_query_monitors(); // the monitors may have changed since the popout opened
    const located: c_int = @intFromBool(app.wm_monitors_len > 0 and
        ext.seridian_popout_locate(&app.wm_monitors, app.wm_monitors_len, x + @divTrunc(width, 2), y + @divTrunc(height, 2), &monitor, monitor.len, &origin_x, &origin_y) == 1);
    if (ext.seridian_popout_save(open, x, y, width, height, if (located != 0) &monitor else null, x - origin_x, y - origin_y) != 0) {
        fns.set_status("Could not save the popout position");
        return;
    }
    app.popout_saved[0] = x;
    app.popout_saved[1] = y;
    app.popout_saved[2] = width;
    app.popout_saved[3] = height;
    app.popout_saved_valid = 1;
    app.popout_dirty = 0;
}

/// Marks the popout closed in popouts.conf while keeping the stored position (the window was never placed, so its
/// live position is the window manager's, not the user's).
pub fn popout_save_keep_position(open: c_int) void {
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var dx: c_int = 0;
    var dy: c_int = 0;
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    monitor[0] = 0;
    if (ext.seridian_popout_load(&x, &y, &width, &height, &monitor, monitor.len, &dx, &dy) != 1) return;
    if (ext.seridian_popout_save(open, x, y, width, height, if (monitor[0] != 0) &monitor else null, dx, dy) != 0)
        fns.set_status("Could not save the popout position");
}

/// Close or quit: geometry is written only for a popout the user placed; otherwise the stored values stay.
pub fn popout_save_on_leave(open: c_int) void {
    if (app.popout_user_placed != 0 and app.popout_place_pending == 0) {
        popout_save_state(open);
    } else {
        popout_save_keep_position(open);
    }
}

/// The app is quitting with the popout open: remember it as open, then close the window without docking.
pub fn popout_save_state_on_quit() void {
    popout_save_on_leave(1);
    app.popout_place_pending = 0;
    popout_reap_place_final();
    const window = app.popout_window;
    fns.piano_release_all_held();
    app.popout_window = raven.R_INVALID_ID;
    app.popout_roll = raven.R_INVALID_ID;
    app.popout_grid_combo = raven.R_INVALID_ID;
    fns.popout_buttons_sync();
    raven.Rwindow_destroy(window);
}

/// Called every frame: forgets a popout window that is gone, and closes it when its key handler asked to dock.
pub fn popout_poll_geometry() void {
    if (app.popout_window == raven.R_INVALID_ID) {
        popout_reap_place_final();
        return;
    }
    popout_reap_place(); // every frame, whichever way this function returns
    if (raven.Rwindow_is_valid(app.popout_window) == 0) {
        popout_reap_place_final();
        app.popout_window = raven.R_INVALID_ID;
        app.popout_roll = raven.R_INVALID_ID;
        app.popout_grid_combo = raven.R_INVALID_ID;
        app.popout_place_pending = 0;
        fns.popout_buttons_sync();
        return;
    }
    if (app.popout_dock_requested != 0) {
        app.popout_dock_requested = 0;
        raven.Rwindow_close(app.popout_window);
        return;
    }
    if (app.popout_place_pending != 0) {
        app.popout_place_frames +%= 1;
        if (app.popout_place_frames >= st.POPOUT_PLACE_TIMEOUT_FRAMES) popout_place_now();
        return;
    }
    // Raven has no move event: watch the geometry. While the window manager or the placement helper is still
    // settling the window, nothing counts; a baseline is taken once it has stood still, and a later change is the user's.
    var current: [4]c_int = undefined;
    popout_read_geometry(&current[0], &current[1], &current[2], &current[3]);
    if (app.popout_place_pid > 0) {
        app.popout_seen_valid = 0;
        app.popout_stable_frames = 0;
        return;
    }
    if (libc.memcmp(&app.popout_seen, &current, @sizeOf(@TypeOf(current))) != 0) {
        if (app.popout_seen_valid != 0) app.popout_user_placed = 1;
        @memcpy(&app.popout_seen, &current);
        app.popout_stable_frames = 0;
    } else if (app.popout_seen_valid == 0) {
        app.popout_stable_frames +%= 1;
        if (app.popout_stable_frames >= st.POPOUT_SAVE_SETTLE_FRAMES) app.popout_seen_valid = 1;
    }
}

/// Raven reports a resize of the popout: a user resize once the window has settled (not the first map, not the
/// placement helper's own resize).
pub fn popout_on_resize(window: raven.Rid, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (app.closing != 0 or window != app.popout_window) return;
    if (app.popout_place_pending != 0 or app.popout_place_pid > 0 or app.popout_seen_valid == 0) return;
    if (width != app.popout_seen[2] or height != app.popout_seen[3]) app.popout_user_placed = 1;
}

/// The user closed the popout window: dock the Piano Roll back into the main window. Raven destroys the window.
pub fn popout_on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    if (app.closing != 0) return raven.R_TRUE; // the app is quitting: keep "open" in popouts.conf so it returns next launch
    popout_save_on_leave(0);
    app.popout_place_pending = 0;
    popout_reap_place_final();
    fns.piano_release_all_held();
    app.popout_window = raven.R_INVALID_ID;
    app.popout_roll = raven.R_INVALID_ID;
    app.popout_grid_combo = raven.R_INVALID_ID;
    _ = window;
    fns.popout_buttons_sync();
    raven.Rtab_view_set_active(app.main_tab_view, st.SERIDIAN_MAIN_TAB_PIANO_ROLL);
    fns.set_status("Piano Roll docked");
    return raven.R_TRUE;
}

/// Keyboard of the popout window: its own hook, so main window shortcuts never see these events and these
/// shortcuts never act on the main window's tab.
pub fn popout_event_hook(window: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    if (event == null) return raven.R_FALSE;
    switch (event.*.type) {
        raven.R_EVENT_KEY_DOWN => {
            if (raven.Rwindow_wants_text_input(window) != 0) return raven.R_FALSE;
            const action: ext.SeridianAction = ext.seridian_keymap_lookup(@bitCast(event.*.key), event.*.modifiers);
            switch (action) {
                ext.SERIDIAN_ACTION_NONE => return if (fns.piano_key_down(event, 1) != 0) raven.R_TRUE else raven.R_FALSE,
                ext.SERIDIAN_ACTION_PLAY_STOP,
                ext.SERIDIAN_ACTION_STOP_AND_REWIND,
                ext.SERIDIAN_ACTION_UNDO,
                ext.SERIDIAN_ACTION_REDO,
                ext.SERIDIAN_ACTION_SELECT_ALL,
                ext.SERIDIAN_ACTION_COPY,
                ext.SERIDIAN_ACTION_CUT,
                ext.SERIDIAN_ACTION_PASTE,
                ext.SERIDIAN_ACTION_DUPLICATE,
                ext.SERIDIAN_ACTION_DELETE,
                ext.SERIDIAN_ACTION_FILE_SAVE,
                ext.SERIDIAN_ACTION_POPOUT_MIXER,
                => {
                    if (event.*.repeat == 0) run_action_for(action, 1);
                    return raven.R_TRUE;
                },
                ext.SERIDIAN_ACTION_TOGGLE_FULLSCREEN => {
                    if (event.*.repeat == 0) toggle_window_maximized(window);
                    return raven.R_TRUE;
                },
                ext.SERIDIAN_ACTION_POPOUT_PIANO_ROLL => {
                    app.popout_dock_requested = 1; // closing the window from inside its own event is deferred
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
        },
        raven.R_EVENT_KEY_UP => return if (fns.piano_key_up(event) != 0) raven.R_TRUE else raven.R_FALSE,
        raven.R_EVENT_FOCUS_GAINED => {
            popout_place_now(); // the window is mapped
            return raven.R_FALSE;
        },
        raven.R_EVENT_FOCUS_LOST => {
            fns.piano_release_all_held();
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

/// Opens the popout for `track` (a track number, or -1 for the selected one). With `restore`, the saved
/// geometry is used and the selected track is kept. If the popout is already open it just follows the track.
/// (The C parameters x, y, width and height are assigned in the body; Zig parameters are immutable, so they
/// arrive as `*_init` and are copied into locals with the C names.)
pub fn popout_open(track: c_int, restore: c_int, x_init: c_int, y_init: c_int, width_init: c_int, height_init: c_int, saved_monitor: [*c]const u8, saved_dx: c_int, saved_dy: c_int) void {
    var x = x_init;
    var y = y_init;
    var width = width_init;
    var height = height_init;
    if (app.popout_window != raven.R_INVALID_ID) {
        if (track >= 0 and track != app.piano_track) select_track(track);
        return;
    }
    if (restore == 0 and track >= 0) select_track(track);

    popout_query_monitors();
    app.popout_place_pending = 0;
    app.popout_place_size_only = 0;
    app.popout_place_monitor[0] = 0;
    popout_reap_place_final();
    app.popout_seen_valid = 0;
    app.popout_saved_valid = 0;
    app.popout_dirty = 0;
    app.popout_user_placed = 0;
    @memset(&app.popout_seen, 0);
    app.popout_stable_frames = 0;
    if (restore != 0) {
        // The size minimum and the clamp apply whichever way the position is found.
        var wx: c_int = 0;
        var wy: c_int = 0;
        var ww: c_int = 0;
        var wh: c_int = 0;
        raven.Rwindow_get_position(app.window, &wx, &wy);
        raven.Rwindow_get_size(app.window, &ww, &wh);
        const main_cx = wx + @divTrunc(ww, 2);
        const main_cy = wy + @divTrunc(wh, 2);
        const saved_x = x;
        const saved_y = y;
        if (ext.seridian_popout_restore(&x, &y, &width, &height, main_cx, main_cy) < 0) {
            width = st.POPOUT_DEFAULT_WIDTH;
            height = st.POPOUT_DEFAULT_HEIGHT;
        }
        // Hyprland and sway place the window themselves, and the app's coordinates (XWayland) do not match the
        // compositor's monitor list: restore the size only. A failed detect takes the same path.
        var backend: [32]u8 = undefined;
        const detected = popout_detect_backend(&backend, backend.len);
        const size_only: c_int = @intFromBool(detected == 0 or libc.strcmp(&backend, "hyprland") == 0 or libc.strcmp(&backend, "sway") == 0);
        popout_log_restore_path(if (size_only != 0) "size-only" else "position", if (detected != 0) &backend else "detect-failed");
        if (size_only != 0) {
            // After the window maps, `seridian wm size` applies the saved size (the helper honours SERIDIAN_CLI).
            app.popout_place_w = width;
            app.popout_place_h = height;
            app.popout_place_dx = 0;
            app.popout_place_dy = 0;
            app.popout_place_frames = 0;
            app.popout_place_size_only = 1;
            app.popout_place_pending = 1;
        } else if (app.wm_monitors_len != 0) {
            var dx = saved_dx;
            var dy = saved_dy;
            const planned = ext.seridian_popout_plan(&app.wm_monitors, app.wm_monitors_len, saved_monitor, saved_x, saved_y, saved_dx, saved_dy, main_cx, main_cy, &app.popout_place_monitor, app.popout_place_monitor.len, &dx, &dy, &width, &height);
            if (planned == 1 or planned == 2) {
                app.popout_place_dx = dx;
                app.popout_place_dy = dy;
                app.popout_place_w = width;
                app.popout_place_h = height;
                app.popout_place_frames = 0;
                app.popout_place_pending = 1;
            }
        }
    } else {
        width = st.POPOUT_DEFAULT_WIDTH;
        height = st.POPOUT_DEFAULT_HEIGHT;
    }
    var fallback: [16]u8 = undefined;
    var title: [st.POPOUT_TITLE_CAPACITY]u8 = undefined;
    _ = libc.snprintf(&title, title.len, "Piano Roll - %s", fns.track_display_name(app.piano_track, &fallback, fallback.len));
    const window = raven.Rwindow_create(&title, width, height, raven.R_WINDOW_DEFAULT);
    if (window == raven.R_INVALID_ID) {
        fns.set_status("Could not open the Piano Roll window");
        return;
    }
    const roll = fns.create_piano_roll_widget(&app.popout_roll);
    if (roll == raven.R_INVALID_ID) {
        raven.Rwindow_destroy(window);
        fns.set_status("Could not open the Piano Roll window");
        return;
    }

    const column = fns.make_column(10.0);
    raven.Rslot_set_padding(column, 14.0, 12.0, 14.0, 10.0);
    const header = fns.make_row(8.0);
    _ = raven.Rwidget_add_child(header, fns.make_label("Grid", 11.0, &st.muted_text));
    const grid = raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX);
    _ = raven.Rcombo_box_add_item(grid, "1/4");
    _ = raven.Rcombo_box_add_item(grid, "1/8");
    _ = raven.Rcombo_box_add_item(grid, "1/16");
    _ = raven.Rcombo_box_add_item(grid, "1/32");
    const grid_index: c_int = if (app.piano_grid_combo != raven.R_INVALID_ID) raven.Rcombo_box_get_selected(app.piano_grid_combo) else st.PIANO_ROLL_DEFAULT_GRID;
    raven.Rcombo_box_set_selected(grid, grid_index);
    raven.Rcombo_box_set_changed_callback(grid, &fns.on_piano_grid_changed, null);
    _ = raven.Rwidget_add_child(header, grid);
    _ = raven.Rwidget_add_child(column, header);
    ext.piano_roll_set_grid(roll, grid_index);
    raven.Rslot_set_fill(roll, 1.0);
    _ = raven.Rwidget_add_child(column, roll);

    app.popout_window = window;
    app.popout_roll = roll;
    app.popout_grid_combo = grid;
    raven.Rwindow_set_content(window, column);
    raven.Rwindow_set_clear_color(window, 0.020, 0.024, 0.051, 1.0);
    raven.Rwindow_set_min_size(window, st.POPOUT_MIN_WIDTH, st.POPOUT_MIN_HEIGHT);
    raven.Rwindow_set_close_callback(window, &popout_on_close, null);
    raven.Rwindow_set_resize_callback(window, &popout_on_resize, null);
    raven.Rwindow_set_event_hook(window, &popout_event_hook, null);
    fns.piano_roll_reload();
    raven.Rwindow_show(window);

    // The Piano Roll now lives in its own window: leave the main window on the Arrangement.
    if (raven.Rtab_view_get_active(app.main_tab_view) == st.SERIDIAN_MAIN_TAB_PIANO_ROLL) {
        raven.Rtab_view_set_active(app.main_tab_view, st.SERIDIAN_MAIN_TAB_ARRANGEMENT);
    }
    app.popout_dock_requested = 0;
    fns.popout_buttons_sync();
    fns.set_status("Piano Roll popped out");
}

/// Ctrl+Shift+P: pops the Piano Roll out, or docks it back when it is already out.
pub fn popout_toggle() void {
    if (app.popout_window != raven.R_INVALID_ID) {
        raven.Rwindow_close(app.popout_window);
        return;
    }
    popout_open(app.piano_track, 0, 0, 0, 0, 0, null, 0, 0);
}

/// Reopens the popout at startup when popouts.conf says it was open. A missing or invalid file opens nothing.
pub fn popout_restore() void {
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var dx: c_int = 0;
    var dy: c_int = 0;
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    monitor[0] = 0;
    if (ext.seridian_popout_load(&x, &y, &width, &height, &monitor, monitor.len, &dx, &dy) != 1) return;
    popout_open(-1, 1, x, y, width, height, &monitor, dx, dy);
}
