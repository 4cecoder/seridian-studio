//! `seridian`: command-line companion to Seridian Studio.
//!
//! Built for scripted and AI-assisted use: every command is a plugin in the
//! `commands` table (name, summary, run function), in the style of Volatility's
//! plugin list. Commands print plain text, return exit code 0 on success and 1
//! on failure, and never start the GUI or the audio engine.
//!
//! Output routing: normal results go to stdout so they can be captured with
//! `$(...)`; errors and failure diagnostics go to stderr.

const std = @import("std");
const device_parse = @import("../audio/device_parse.zig");
const wm_layer = @import("wm/wm.zig");
const wm_types = @import("wm/types.zig");
const song = @import("song.zig");
const preflight = @import("../system/preflight.zig");
const preflight_types = @import("../system/preflight_types.zig");
const audio_settings = @import("../config/audio_settings.zig");

const version_string = "0.1.0";
const app_binary = "seridian-studio";
const window_title = "Seridian Studio";
const state_file_name = "seridian-state.json";
const log_file_name = "seridian-app.log";

const Env = std.process.Environ.Map;

const doctor_usage = "seridian doctor [--fix hyprland-rules|desktop-entry|pipewire-clock]";
const doctor_help =
    \\Usage: seridian doctor [--fix NAME]
    \\
    \\Checks the X display, the audio server, window-manager helpers and the
    \\running app, then a "Realtime audio" section: PipeWire latency against the
    \\app's sample rate and buffer (from audio.conf), realtime and memlock limits,
    \\kernel preemption, CPU governor and power profile, sound card and MIDI
    \\access, the desktop entry, Hyprland window rules and file-dialog tools.
    \\Each check prints [PASS], [INFO], [WARN] or [FAIL] with a hint.
    \\
    \\Exit status is 1 when any check FAILs; WARN and INFO never change it.
    \\
    \\--fix NAME applies one opt-in fix. Fixes write only under $HOME, never run
    \\root commands, and print every file they wrote:
    \\  hyprland-rules  write ~/.config/hypr/seridian-studio.conf, source it from
    \\                  hyprland.conf (backed up first), then hyprctl reload
    \\  desktop-entry   write ~/.local/share/applications/seridian-studio.desktop
    \\                  (Exec is the installed seridian-studio binary)
    \\  pipewire-clock  write ~/.config/pipewire/pipewire.conf.d/90-seridian-studio.conf
    \\                  and apply it to the running PipeWire with pw-metadata
    \\Root-level changes (rtprio limits, kernel options, governors) are printed
    \\as hints, never run.
    \\
;
const key_usage = "seridian key <combo>";
const click_usage = "seridian click <x> <y> [--double]";
const drag_usage = "seridian drag <x> <y> <dx> <dy> [--steps N] [--shift]";
const state_usage = "seridian state [--wait-ms N]";
const logs_usage = "seridian logs [N]";
const wm_usage = wm_layer.usage_all;
const play_usage = "seridian play";
const stop_usage = "seridian stop";
const bpm_usage = "seridian bpm <20..300>";
const set_usage = "seridian set <track 1..8> gain <0..1.5> | pan <-1..1> | mute|solo|arm on|off | instrument NAME";
const note_usage = "seridian note <track 1..8> <pitch 0..127> <start >=0> <length >0> [velocity 1..127]";
const clear_usage = "seridian clear <track 1..8>";
const auto_usage = "seridian auto <track 1..8> gain <beat >=0> <0..1> | pan <beat> <-1..1> | wet <beat> <0..1>; auto master gain <beat> <0..1>; auto clear <track> gain|pan|wet";
const eq_usage = "seridian eq <track 1..8> preset drums|bass|pads|lead|harp; eq master tilt on|off";
const eq_preset_names = [_][]const u8{ "drums", "bass", "pads", "lead", "harp" };
const save_usage = "seridian save PATH";
const open_usage = "seridian open PATH";
const export_usage = "seridian export PATH";
/// Longest path the app socket accepts.
const max_path_bytes = 120;

const socket_file_name = "seridian.sock";
const max_track: u8 = 8;
const max_reply_bytes: usize = 4096;

const drag_default_steps: u32 = 10;
const drag_max_steps: u32 = 200;
// Seconds between pointer events; shorter gaps are dropped by the app.
const drag_step_delay = "0.05";
const default_log_lines: u32 = 40;
const max_state_bytes: usize = 16 * 1024 * 1024;
const state_poll_interval_ns: i96 = 50 * std.time.ns_per_ms;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    run: *const fn (std.mem.Allocator, std.Io, *const Env, []const []const u8) anyerror!u8,
};

const commands = [_]Command{
    .{
        .name = "version",
        .summary = "Print the CLI version",
        .usage = "seridian version",
        .run = cmdVersion,
    },
    .{
        .name = "doctor",
        .summary = "Triage the setup: display, audio server, realtime audio, desktop; --fix NAME applies a user-level fix",
        .usage = doctor_usage,
        .run = cmdDoctor,
    },
    .{
        .name = "status",
        .summary = "Report whether Seridian Studio is running and its window id",
        .usage = "seridian status",
        .run = cmdStatus,
    },
    .{
        .name = "screenshot",
        .summary = "Capture the Seridian Studio window to a PNG (needs ImageMagick and xwininfo)",
        .usage = "seridian screenshot [output.png]",
        .run = cmdScreenshot,
    },
    .{
        .name = "devices",
        .summary = "List PulseAudio/PipeWire output sinks and input sources via pactl",
        .usage = "seridian devices",
        .run = cmdDevices,
    },
    .{
        .name = "key",
        .summary = "Focus the Studio window and send a key combo (xdotool syntax, e.g. ctrl+s)",
        .usage = key_usage,
        .run = cmdKey,
    },
    .{
        .name = "click",
        .summary = "Click at window-relative logical pixel (x, y); --double for a double click",
        .usage = click_usage,
        .run = cmdClick,
    },
    .{
        .name = "drag",
        .summary = "Drag with the left button from (x, y) by (dx, dy) in N steps; --shift holds Shift",
        .usage = drag_usage,
        .run = cmdDrag,
    },
    .{
        .name = "state",
        .summary = "Print the app's state file; --wait-ms N waits for a fresh write",
        .usage = state_usage,
        .run = cmdState,
    },
    .{
        .name = "wm",
        .summary = "Window-manager control: detect | list | monitors | float | move | resize | place (Hyprland, Sway, KDE, GNOME, X11)",
        .usage = wm_usage,
        .run = cmdWm,
    },
    .{
        .name = "logs",
        .summary = "Print the last N lines of the app log (default 40)",
        .usage = logs_usage,
        .run = cmdLogs,
    },
    .{ .name = "play", .summary = "Start playback in the running app", .usage = play_usage, .run = cmdPlay },
    .{ .name = "stop", .summary = "Stop playback in the running app", .usage = stop_usage, .run = cmdStop },
    .{ .name = "bpm", .summary = "Set the tempo (20..300)", .usage = bpm_usage, .run = cmdBpm },
    .{ .name = "set", .summary = "Set a track's gain, pan, mute, solo or arm", .usage = set_usage, .run = cmdSet },
    .{ .name = "note", .summary = "Add a note: track, pitch, start beat, length in beats, optional velocity", .usage = note_usage, .run = cmdNote },
    .{ .name = "clear", .summary = "Remove all notes on a track", .usage = clear_usage, .run = cmdClear },
    .{ .name = "auto", .summary = "Add an automation point (gain, pan, reverb wet, master gain) or clear a lane", .usage = auto_usage, .run = cmdAuto },
    .{ .name = "eq", .summary = "Apply an EQ preset to a track, or switch the master tilt", .usage = eq_usage, .run = cmdEq },
    .{ .name = "save", .summary = "Save the session to the folder PATH", .usage = save_usage, .run = cmdSave },
    .{ .name = "open", .summary = "Open the session folder PATH", .usage = open_usage, .run = cmdOpen },
    .{ .name = "song", .summary = "Write an arranged demo song (5 tracks, 88 bars) into the app; optional PATH to save", .usage = song.usage, .run = cmdSong },
    .{ .name = "export", .summary = "Write a 16-bit WAV of the session to PATH", .usage = export_usage, .run = cmdExport },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const sentinel_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try allocator.alloc([]const u8, sentinel_args.len);
    defer allocator.free(args);
    for (sentinel_args, args) |src, *dst| dst.* = src;

    const exit_code = dispatch(allocator, io, init.environ_map, args[1..]) catch |err| blk: {
        var err_buf: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
        try stderr_writer.interface.print("seridian: {s}\n", .{@errorName(err)});
        try stderr_writer.interface.flush();
        break :blk @as(u8, 1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn dispatch(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        var out_buf: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
        try printUsage(&stdout_writer.interface);
        return 0;
    }
    for (commands) |command| {
        if (std.mem.eql(u8, args[0], command.name)) {
            return command.run(allocator, io, env, args[1..]);
        }
    }
    var err_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    try stderr_writer.interface.print("seridian: unknown command '{s}'\n\n", .{args[0]});
    try printUsage(&stderr_writer.interface);
    return 1;
}

/// Writes the usage text to `out` and flushes it.
fn printUsage(out: *std.Io.Writer) !void {
    try out.print("seridian {s} — Seridian Studio command-line tools\n\n", .{version_string});
    try out.print("Usage: seridian <command> [arguments]\n\nCommands:\n", .{});
    for (commands) |command| {
        try out.print("  {s: <12} {s}\n", .{ command.name, command.summary });
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmdVersion(_: std.mem.Allocator, io: std.Io, _: *const Env, _: []const []const u8) !u8 {
    var out_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_writer.interface;
    try out.print("seridian {s}\n", .{version_string});
    try out.flush();
    return 0;
}

/// Writes the doctor line for the window-manager backend. The backend comes
/// from `wm.detect`, the same function `seridian wm` uses, so the two can
/// never disagree. SERIDIAN_WM is honoured for every backend.
fn writeWmBackendLine(out: *std.Io.Writer, env: *const Env) !void {
    const detection = wm_layer.detect(env) catch {
        try out.writeAll("  [WARN] window manager backend: invalid SERIDIAN_WM '");
        try wm_types.writeEscaped(out, env.get("SERIDIAN_WM") orelse "");
        try out.writeAll("' (valid: hyprland, sway, kwin, x11, gnome_wayland, none)\n");
        return;
    };
    try out.print("  [INFO] window manager backend: {s} ({s})\n", .{ @tagName(detection.backend), detection.reason });
}

/// Window-manager helper binaries that doctor reports on. Missing helpers only
/// limit window-manager features, so they are warnings and never fail doctor.
const wm_helpers = [_][]const u8{ "hyprctl", "swaymsg", "xdotool", "wmctrl", "gdbus" };

/// Prints a WARN line for each missing helper and returns the number of warnings.
/// qdbus and kdotool are alternatives, so only their absence together is a warning.
fn checkWmHelpers(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !u8 {
    var warnings: u8 = 0;
    for (wm_helpers) |name| {
        if (try hasBinary(allocator, io, name)) {
            try out.print("  [PASS] helper {s} found\n", .{name});
        } else {
            try out.print("  [WARN] helper {s} not found\n", .{name});
            warnings += 1;
        }
    }
    if ((try hasBinary(allocator, io, "qdbus")) or (try hasBinary(allocator, io, "kdotool"))) {
        try out.print("  [PASS] helper qdbus or kdotool found\n", .{});
    } else {
        try out.print("  [WARN] helper qdbus or kdotool not found (neither is installed)\n", .{});
        warnings += 1;
    }
    return warnings;
}

/// Reports whether `name` resolves to an executable on PATH, using the shell's `command -v`.
fn hasBinary(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !bool {
    return runOk(allocator, io, &.{ "sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "sh", name }) catch false;
}

/// What `seridian doctor` was asked to do.
const DoctorArgs = union(enum) {
    report,
    help,
    fix: preflight.FixId,
};

fn parseDoctorArgs(args: []const []const u8) error{ InvalidArgs, UnknownFix }!DoctorArgs {
    if (args.len == 0) return .report;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    if (std.mem.eql(u8, args[0], "--fix")) {
        if (args.len != 2) return error.InvalidArgs;
        return .{ .fix = preflight.FixId.parse(args[1]) orelse return error.UnknownFix };
    }
    return error.InvalidArgs;
}

fn cmdDoctor(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    const parsed = parseDoctorArgs(args) catch |err| switch (err) {
        error.InvalidArgs => return usageError(io, doctor_usage),
        error.UnknownFix => {
            try printErr(io, "seridian doctor: unknown fix '{s}' (valid: hyprland-rules, desktop-entry, pipewire-clock)\n", .{args[1]});
            return 1;
        },
    };
    switch (parsed) {
        .help => {
            try printOut(io, "{s}", .{doctor_help});
            return 0;
        },
        .fix => |fix| return doctorFix(allocator, io, env, fix),
        .report => {},
    }

    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_writer.interface;

    var failures: u32 = 0;
    failures += try check(allocator, io, out, "X display (Raven renders through X11/XWayland)", &.{ "xwininfo", "-root" });
    failures += try check(allocator, io, out, "PulseAudio/PipeWire server reachable", &.{ "pactl", "info" });
    failures += try check(allocator, io, out, "xwininfo (for window lookup)", &.{ "xwininfo", "-version" });
    failures += try check(allocator, io, out, "xwd + ffmpeg (for screenshots)", &.{ "ffmpeg", "-version" });

    try writeWmBackendLine(out, env);
    const helper_warnings = try checkWmHelpers(allocator, io, out);

    const running = isAppRunning(allocator, io);
    try out.print("  [{s}] {s} running\n", .{ if (running) "PASS" else "INFO", app_binary });

    // Realtime audio and desktop integration (src/system/preflight.zig).
    const report = try allocator.create(preflight_types.CReport);
    defer allocator.destroy(report);
    {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const opts = try doctorOptions(arena.allocator(), io, env, &exe_buf);
        const result = preflight.run(arena.allocator(), env, opts);
        preflight_types.fromReport(&result, report);
    }
    try out.writeAll("\n");
    try preflight_types.writeText(out, report, fixCliName);
    failures += report.countStatus(preflight_types.status_fail);
    const audio_warnings = report.countStatus(preflight_types.status_warn);

    if (helper_warnings > 0) {
        try out.print("\n{d} warning(s): optional window-manager helpers are missing.\n", .{helper_warnings});
    }
    if (audio_warnings > 0) {
        try out.print("{s}{d} realtime-audio warning(s): audio works, but latency or desktop integration suffers.\n", .{ if (helper_warnings > 0) "" else "\n", audio_warnings });
    }
    if (failures == 0) {
        try out.print("\nNo blocking problems found.\n", .{});
        try out.flush();
        return 0;
    }
    try out.flush();

    try printErr(io, "\n{d} check(s) failed. The GUI needs an X display and an audio server; fix the FAIL items above.\n", .{failures});
    return 1;
}

/// `--fix` argument for a preflight fix id ("" when there is none).
fn fixCliName(fix: u32) []const u8 {
    const id = std.enums.fromInt(preflight.FixId, fix) orelse return "";
    return id.cliName();
}

/// Preflight options for the CLI: the sample rate and buffer size the app
/// will use (audio.conf, defaults when absent) and the seridian-studio path.
fn doctorOptions(arena: std.mem.Allocator, io: std.Io, env: *const Env, exe_buf: []u8) !preflight.Options {
    var opts: preflight.Options = .{};
    const settings_path = audio_settings.defaultPath(arena) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (settings_path) |path| {
        const settings = try audio_settings.loadFrom(arena, path);
        opts.sample_rate = settings.sample_rate;
        opts.buffer_size = settings.buffer_size;
    }
    opts.studio_exe = findStudioExe(io, env, exe_buf);
    return opts;
}

/// The seridian-studio binary installed beside this `seridian` (bin/ of the
/// same tree), else the first one on PATH. Null when neither exists.
fn findStudioExe(io: std.Io, env: *const Env, buf: []u8) ?[]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &dir_buf)) |len| {
        if (executableIn(io, dir_buf[0..len], app_binary, buf)) |path| return path;
    } else |_| {
        // No /proc/self/exe (unusual); PATH is still searched.
    }
    return findOnPath(io, env.get("PATH") orelse "", app_binary, buf);
}

/// First `dir/name` from the colon-separated `path_list` that is executable.
fn findOnPath(io: std.Io, path_list: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var dirs = std.mem.tokenizeScalar(u8, path_list, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        if (executableIn(io, dir, name, buf)) |path| return path;
    }
    return null;
}

fn executableIn(io: std.Io, dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null;
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return null;
    return path;
}

/// `seridian doctor --fix NAME`: apply one user-level fix and print what it wrote.
fn doctorFix(allocator: std.mem.Allocator, io: std.Io, env: *const Env, fix: preflight.FixId) !u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opts = try doctorOptions(arena.allocator(), io, env, &exe_buf);
    var msg: preflight.FixMessage = .{};
    preflight.applyFix(arena.allocator(), env, fix, opts, &msg) catch |err| {
        const why: []const u8 = switch (err) {
            error.MissingHome => "HOME is unset or not an absolute path",
            error.OutsideHome => "the target is outside $HOME (check XDG_CONFIG_HOME, XDG_DATA_HOME, HYPRLAND_CONFIG); nothing was written",
            error.NoHyprlandConfig => "no readable hyprland.conf (set HYPRLAND_CONFIG or create ~/.config/hypr/hyprland.conf)",
            error.StudioNotFound => "seridian-studio was not found beside seridian or on PATH; build or install it first",
            else => @errorName(err),
        };
        try printErr(io, "seridian doctor --fix {s}: {s} failed: {s}\n", .{ fix.cliName(), fix.describe(), why });
        return 1;
    };
    try printOut(io, "{s}: {s}\n", .{ fix.describe(), msg.slice() });
    return 0;
}

fn cmdStatus(allocator: std.mem.Allocator, io: std.Io, _: *const Env, _: []const []const u8) !u8 {
    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_writer.interface;

    if (!isAppRunning(allocator, io)) {
        try out.print("{s} is not running\n", .{app_binary});
        try out.flush();
        return 1;
    }
    try out.print("{s} is running\n", .{app_binary});
    if (try findWindowId(allocator, io)) |id| {
        defer allocator.free(id);
        try out.print("window: {s}\n", .{id});
    } else {
        try out.print("window: not found (the app may still be starting)\n", .{});
    }
    try out.flush();
    return 0;
}

fn cmdScreenshot(allocator: std.mem.Allocator, io: std.Io, _: *const Env, args: []const []const u8) !u8 {
    const output = if (args.len > 0) args[0] else "seridian-screenshot.png";
    const window_id = (try findWindowId(allocator, io)) orelse {
        var err_buf: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
        try stderr_writer.interface.print("no '{s}' window found; start the app first with `sh run.sh`\n", .{window_title});
        try stderr_writer.interface.flush();
        return 1;
    };
    defer allocator.free(window_id);

    try captureWindow(allocator, io, window_id, output);

    var out_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    try stdout_writer.interface.print("saved {s} (window {s})\n", .{ output, window_id });
    try stdout_writer.interface.flush();
    return 0;
}

/// Captures one window to `output`. Uses ImageMagick `import` when installed,
/// otherwise `xwd` piped through `ffmpeg` (which reads XWD natively).
fn captureWindow(allocator: std.mem.Allocator, io: std.Io, window_id: []const u8, output: []const u8) !void {
    if (try runOk(allocator, io, &.{ "import", "-window", window_id, output })) return;

    const xwd_path = try std.fmt.allocPrint(allocator, "{s}.xwd", .{output});
    defer allocator.free(xwd_path);

    const dumped = try runOk(allocator, io, &.{ "xwd", "-id", window_id, "-silent", "-out", xwd_path });
    if (!dumped) return error.CaptureFailed;

    const converted = try runOk(allocator, io, &.{ "ffmpeg", "-loglevel", "error", "-y", "-i", xwd_path, output });
    _ = try runOk(allocator, io, &.{ "rm", "-f", xwd_path });
    if (!converted) return error.CaptureFailed;
}

const max_listed_devices = 64;

fn cmdDevices(allocator: std.mem.Allocator, io: std.Io, _: *const Env, _: []const []const u8) !u8 {
    // A missing default is not fatal: the lists still print, with nothing marked.
    const default_text = try runCapture(allocator, io, &.{ "pactl", "get-default-sink" });
    defer if (default_text) |text| allocator.free(text);
    const default_sink = if (default_text) |text| device_parse.parseDefaultName(text) else "";

    const sinks_text = (try runCapture(allocator, io, &.{ "pactl", "list", "short", "sinks" })) orelse
        return devicesFailure(io, "sinks");
    defer allocator.free(sinks_text);
    const sources_text = (try runCapture(allocator, io, &.{ "pactl", "list", "short", "sources" })) orelse
        return devicesFailure(io, "sources");
    defer allocator.free(sources_text);

    var sinks: [max_listed_devices]device_parse.Device = undefined;
    const sink_count = device_parse.parseShortList(sinks_text, default_sink, &sinks);
    var sources: [max_listed_devices]device_parse.Device = undefined;
    const source_count = device_parse.parseShortList(sources_text, "", &sources);

    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_writer.interface;
    try out.print("Output devices (sinks):\n", .{});
    for (sinks[0..sink_count]) |dev| try printDevice(out, dev);
    try out.print("Input devices (sources):\n", .{});
    for (sources[0..source_count]) |dev| try printDevice(out, dev);
    try out.flush();
    return 0;
}

fn printDevice(out: *std.Io.Writer, dev: device_parse.Device) !void {
    try out.print("  {s} {d: >6}  {s}  ({s})\n", .{
        if (dev.is_default) "*" else " ",
        dev.index,
        dev.name,
        dev.description,
    });
}

fn devicesFailure(io: std.Io, what: []const u8) !u8 {
    var err_buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    try stderr_writer.interface.print("pactl failed to list {s}; is PulseAudio or PipeWire running?\n", .{what});
    try stderr_writer.interface.flush();
    return 1;
}

fn cmdWm(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    const code = try wm_layer.run(allocator, env, args, &stdout_writer.interface, &stderr_writer.interface);
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return code;
}

fn cmdKey(allocator: std.mem.Allocator, io: std.Io, _: *const Env, args: []const []const u8) !u8 {
    if (args.len != 1) return usageError(io, key_usage);
    const window_id = (try findWindowId(allocator, io)) orelse return noWindowError(io);
    defer allocator.free(window_id);

    if (!try runOk(allocator, io, &.{ "xdotool", "windowfocus", "--sync", window_id })) {
        try printErr(io, "could not focus the '{s}' window\n", .{window_title});
        return 1;
    }
    if (!try runOk(allocator, io, &.{ "xdotool", "key", "--clearmodifiers", args[0] })) {
        try printErr(io, "xdotool could not send key '{s}'\n", .{args[0]});
        return 1;
    }
    return 0;
}

fn cmdClick(allocator: std.mem.Allocator, io: std.Io, _: *const Env, args: []const []const u8) !u8 {
    const click = parseClickArgs(args) catch return usageError(io, click_usage);
    const window_id = (try findWindowId(allocator, io)) orelse return noWindowError(io);
    defer allocator.free(window_id);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x_text = try intString(arena, click.x);
    const y_text = try intString(arena, click.y);
    const repeat = if (click.double) "2" else "1";

    // Raven ignores a press that arrives in the same instant the pointer moves
    // onto a widget, so pause before clicking.
    const argv = [_][]const u8{
        "xdotool", "mousemove", "--window", window_id,  x_text, y_text,
        "sleep",   "0.1",       "click",    "--repeat", repeat, "--delay",
        "80",      "1",
    };
    if (!try runOk(allocator, io, &argv)) {
        try printErr(io, "xdotool click failed\n", .{});
        return 1;
    }
    return 0;
}

fn cmdDrag(allocator: std.mem.Allocator, io: std.Io, _: *const Env, args: []const []const u8) !u8 {
    const drag = parseDragArgs(args) catch return usageError(io, drag_usage);
    const window_id = (try findWindowId(allocator, io)) orelse return noWindowError(io);
    defer allocator.free(window_id);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const argv = try buildDragArgv(arena_state.allocator(), window_id, drag);

    if (!try runOk(allocator, io, argv)) {
        try printErr(io, "xdotool drag failed\n", .{});
        return 1;
    }
    return 0;
}

fn cmdState(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    const wait_ms = parseWaitMs(args) catch return usageError(io, state_usage);
    const path = try runtimeFilePath(allocator, env, state_file_name);
    defer allocator.free(path);

    // The wait deadline is measured from the moment the command started, so a
    // state file written before this call never satisfies `--wait-ms`.
    const start = std.Io.Timestamp.now(io, .real);
    const deadline = start.nanoseconds + @as(i96, wait_ms orelse 0) * std.time.ns_per_ms;

    while (true) {
        if (try statIfExists(io, path)) |stat| {
            if (wait_ms == null or stat.mtime.nanoseconds > start.nanoseconds) {
                return printFileContents(allocator, io, path);
            }
        } else if (wait_ms == null) {
            try printErr(io, "no state file at {s}; is the app running?\n", .{path});
            return 1;
        }

        if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline) {
            try printErr(io, "timed out after {d} ms waiting for an update to {s}\n", .{ wait_ms orelse 0, path });
            return 1;
        }
        try std.Io.sleep(io, .{ .nanoseconds = state_poll_interval_ns }, .awake);
    }
}

fn cmdPlay(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "play", args);
}

fn cmdStop(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "stop", args);
}

fn cmdBpm(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "bpm", args);
}

fn cmdSet(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "set", args);
}

fn cmdNote(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "note", args);
}

fn cmdClear(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "clear", args);
}

fn cmdAuto(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "auto", args);
}

fn cmdEq(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "eq", args);
}

fn cmdSave(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "save", args);
}

fn cmdOpen(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "open", args);
}

fn cmdExport(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    return sendCommand(allocator, io, env, "export", args);
}

fn cmdSong(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    const path = try socketPath(allocator, env);
    defer allocator.free(path);
    return song.run(io, path, args);
}

fn usageFor(name: []const u8) []const u8 {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.usage;
    }
    return "seridian help";
}

/// Validates the arguments, connects to the app's socket, sends one line and
/// prints the one-line reply. "ok" exits 0; anything else is an error, exit 1.
fn sendCommand(allocator: std.mem.Allocator, io: std.Io, env: *const Env, name: []const u8, requested_args: []const []const u8) !u8 {
    // The app resolves a relative path against its own working directory, so the CLI sends an absolute one.
    var absolute_path: ?[]u8 = null;
    defer if (absolute_path) |p| allocator.free(p);
    var path_args: [1][]const u8 = undefined;
    var args = requested_args;
    if (takesPath(name) and requested_args.len == 1 and requested_args[0].len > 0 and !std.fs.path.isAbsolute(requested_args[0])) {
        const cwd = std.process.currentPathAlloc(io, allocator) catch |err| {
            try printErr(io, "cannot find the current directory: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer allocator.free(cwd);
        absolute_path = try absolutePath(allocator, cwd, requested_args[0]);
        path_args[0] = absolute_path.?;
        args = &path_args;
    }

    var line_buf: [256]u8 = undefined;
    const line = buildLine(&line_buf, name, args) catch {
        var problem_buf: [200]u8 = undefined;
        try printErr(io, "error: {s}\n", .{describeProblem(&problem_buf, name, args)});
        return usageError(io, usageFor(name));
    };

    const path = try socketPath(allocator, env);
    defer allocator.free(path);
    const address = std.Io.net.UnixAddress.init(path) catch {
        try printErr(io, "socket path too long: {s}\n", .{path});
        return 1;
    };
    const stream = address.connect(io) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            try printErr(io, "app is not running\n", .{});
            return 1;
        },
        else => {
            try printErr(io, "cannot connect to {s}: {s}\n", .{ path, @errorName(err) });
            return 1;
        },
    };
    defer stream.close(io);

    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(line) catch {
        try printErr(io, "failed to send to the app\n", .{});
        return 1;
    };
    writer.interface.writeAll("\n") catch {
        try printErr(io, "failed to send to the app\n", .{});
        return 1;
    };
    writer.interface.flush() catch {
        try printErr(io, "failed to send to the app\n", .{});
        return 1;
    };

    var read_buf: [max_reply_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const reply_raw = reader.interface.takeDelimiterExclusive('\n') catch {
        try printErr(io, "no reply from the app\n", .{});
        return 1;
    };
    const reply = std.mem.trim(u8, reply_raw, " \r\t");

    if (std.mem.eql(u8, reply, "ok") or std.mem.startsWith(u8, reply, "ok ")) {
        var out_buf: [max_reply_bytes + 1]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
        try stdout_writer.interface.writeAll(reply);
        try stdout_writer.interface.writeAll("\n");
        try stdout_writer.interface.flush();
        return 0;
    }
    try printErr(io, "{s}\n", .{reply});
    return 1;
}

fn socketPath(allocator: std.mem.Allocator, env: *const Env) ![]u8 {
    if (env.get("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, socket_file_name });
    }
    return std.fmt.allocPrint(allocator, "/tmp/seridian-{d}.sock", .{std.c.getuid()});
}

const ArgError = error{InvalidArgs};

fn parseIntIn(text: []const u8, min: i64, max: i64) ArgError!i64 {
    const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidArgs;
    if (value < min or value > max) return error.InvalidArgs;
    return value;
}

fn parseFloatIn(text: []const u8, min: f64, max: f64) ArgError!f64 {
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidArgs;
    if (!std.math.isFinite(value) or value < min or value > max) return error.InvalidArgs;
    return value;
}

fn parseOnOff(text: []const u8) ArgError!bool {
    if (std.mem.eql(u8, text, "on")) return true;
    if (std.mem.eql(u8, text, "off")) return false;
    return error.InvalidArgs;
}

fn isAutoLane(text: []const u8) bool {
    return std.mem.eql(u8, text, "gain") or std.mem.eql(u8, text, "pan") or std.mem.eql(u8, text, "wet");
}

/// True for the commands whose single argument is a file or folder path.
fn takesPath(name: []const u8) bool {
    return std.mem.eql(u8, name, "save") or std.mem.eql(u8, name, "open") or std.mem.eql(u8, name, "export");
}

/// Makes `path` absolute against `cwd` (the CLI's own working directory) and normalizes it.
/// An already absolute path is returned as a copy. The caller frees the result.
fn absolutePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

/// Checks the arguments of one command and renders the line sent to the app.
/// Track numbers are 1-based on the wire, as typed.
fn buildLine(buf: []u8, name: []const u8, args: []const []const u8) ArgError![]const u8 {
    const too_long = error.InvalidArgs;
    if (std.mem.eql(u8, name, "play") or std.mem.eql(u8, name, "stop")) {
        if (args.len != 0) return error.InvalidArgs;
        return std.fmt.bufPrint(buf, "{s}", .{name}) catch too_long;
    }
    if (std.mem.eql(u8, name, "bpm")) {
        if (args.len != 1) return error.InvalidArgs;
        const bpm = try parseFloatIn(args[0], 20, 300);
        return std.fmt.bufPrint(buf, "bpm {d}", .{bpm}) catch too_long;
    }
    if (std.mem.eql(u8, name, "clear")) {
        if (args.len != 1) return error.InvalidArgs;
        const track = try parseIntIn(args[0], 1, max_track);
        return std.fmt.bufPrint(buf, "clear {d}", .{track}) catch too_long;
    }
    if (std.mem.eql(u8, name, "save") or std.mem.eql(u8, name, "open") or std.mem.eql(u8, name, "export")) {
        if (args.len != 1) return error.InvalidArgs;
        const path = args[0];
        if (path.len == 0 or path.len > max_path_bytes) return error.InvalidArgs;
        for (path) |c| if (c <= ' ' or c == 0x7f) return error.InvalidArgs;
        return std.fmt.bufPrint(buf, "{s} {s}", .{ name, path }) catch too_long;
    }
    if (std.mem.eql(u8, name, "set")) {
        if (args.len != 3) return error.InvalidArgs;
        const track = try parseIntIn(args[0], 1, max_track);
        const field = args[1];
        if (std.mem.eql(u8, field, "gain")) {
            const v = try parseFloatIn(args[2], 0, 1.5);
            return std.fmt.bufPrint(buf, "set {d} gain {d}", .{ track, v }) catch too_long;
        }
        if (std.mem.eql(u8, field, "pan")) {
            const v = try parseFloatIn(args[2], -1, 1);
            return std.fmt.bufPrint(buf, "set {d} pan {d}", .{ track, v }) catch too_long;
        }
        if (std.mem.eql(u8, field, "mute") or std.mem.eql(u8, field, "solo") or std.mem.eql(u8, field, "arm")) {
            const on = try parseOnOff(args[2]);
            return std.fmt.bufPrint(buf, "set {d} {s} {s}", .{ track, field, if (on) "on" else "off" }) catch too_long;
        }
        if (std.mem.eql(u8, field, "instrument")) {
            const instrument = args[2];
            if (instrument.len == 0 or instrument.len > 32) return error.InvalidArgs;
            for (instrument) |c| if (c == ' ' or c == '\t') return error.InvalidArgs;
            return std.fmt.bufPrint(buf, "set {d} instrument {s}", .{ track, instrument }) catch too_long;
        }
        return error.InvalidArgs;
    }
    if (std.mem.eql(u8, name, "auto")) {
        if (args.len == 4 and std.mem.eql(u8, args[0], "master")) {
            if (!std.mem.eql(u8, args[1], "gain")) return error.InvalidArgs;
            const beat = try parseFloatIn(args[2], 0, 1e6);
            const v = try parseFloatIn(args[3], 0, 1);
            return std.fmt.bufPrint(buf, "auto master gain {d} {d}", .{ beat, v }) catch too_long;
        }
        if (args.len == 3 and std.mem.eql(u8, args[0], "clear")) {
            const track = try parseIntIn(args[1], 1, max_track);
            if (!isAutoLane(args[2])) return error.InvalidArgs;
            return std.fmt.bufPrint(buf, "auto clear {d} {s}", .{ track, args[2] }) catch too_long;
        }
        if (args.len == 4) {
            const track = try parseIntIn(args[0], 1, max_track);
            if (!isAutoLane(args[1])) return error.InvalidArgs;
            const beat = try parseFloatIn(args[2], 0, 1e6);
            const low: f64 = if (std.mem.eql(u8, args[1], "pan")) -1 else 0;
            const v = try parseFloatIn(args[3], low, 1);
            return std.fmt.bufPrint(buf, "auto {d} {s} {d} {d}", .{ track, args[1], beat, v }) catch too_long;
        }
        return error.InvalidArgs;
    }
    if (std.mem.eql(u8, name, "eq")) {
        if (args.len != 3) return error.InvalidArgs;
        if (std.mem.eql(u8, args[0], "master")) {
            if (!std.mem.eql(u8, args[1], "tilt")) return error.InvalidArgs;
            const on = try parseOnOff(args[2]);
            return std.fmt.bufPrint(buf, "eq master tilt {s}", .{if (on) "on" else "off"}) catch too_long;
        }
        const track = try parseIntIn(args[0], 1, max_track);
        if (!std.mem.eql(u8, args[1], "preset")) return error.InvalidArgs;
        for (eq_preset_names) |preset| {
            if (std.mem.eql(u8, args[2], preset)) {
                return std.fmt.bufPrint(buf, "eq {d} preset {s}", .{ track, preset }) catch too_long;
            }
        }
        return error.InvalidArgs;
    }
    if (std.mem.eql(u8, name, "note")) {
        if (args.len != 4 and args.len != 5) return error.InvalidArgs;
        const track = try parseIntIn(args[0], 1, max_track);
        const pitch = try parseIntIn(args[1], 0, 127);
        const start = try parseFloatIn(args[2], 0, 1e9);
        const length = try parseFloatIn(args[3], 0, 1e9);
        if (length <= 0) return error.InvalidArgs;
        const velocity = if (args.len == 5) try parseIntIn(args[4], 1, 127) else 100;
        return std.fmt.bufPrint(buf, "note {d} {d} {d} {d} {d}", .{ track, pitch, start, length, velocity }) catch too_long;
    }
    return error.InvalidArgs;
}

/// Explains why `buildLine` rejected the arguments: which one is wrong, what it may be, and what was
/// given. The text lives in `buf`; shapes this does not recognise get a plain fallback.
fn describeProblem(buf: []u8, name: []const u8, args: []const []const u8) []const u8 {
    const fallback = "invalid arguments";
    const eql = std.mem.eql;
    if (eql(u8, name, "note")) {
        if (args.len != 4 and args.len != 5) return countProblem(buf, "note takes 4 or 5 arguments", args.len);
        if (intProblem(buf, "track", args[0], 1, max_track)) |m| return m;
        if (intProblem(buf, "pitch", args[1], 0, 127)) |m| return m;
        if (parseFloatIn(args[2], 0, 1e9)) |_| {} else |_| return given(buf, "start must be a number of beats 0 or more", args[2]);
        const length_ok = if (parseFloatIn(args[3], 0, 1e9)) |v| v > 0 else |_| false;
        if (!length_ok) return given(buf, "length must be greater than 0", args[3]);
        if (args.len == 5) if (intProblem(buf, "velocity", args[4], 1, 127)) |m| return m;
        return fallback;
    }
    if (eql(u8, name, "bpm")) {
        if (args.len != 1) return countProblem(buf, "bpm takes 1 argument", args.len);
        return floatProblem(buf, "tempo", args[0], 20, 300) orelse fallback;
    }
    if (eql(u8, name, "clear")) {
        if (args.len != 1) return countProblem(buf, "clear takes 1 argument", args.len);
        return intProblem(buf, "track", args[0], 1, max_track) orelse fallback;
    }
    if (eql(u8, name, "set")) {
        if (args.len != 3) return countProblem(buf, "set takes 3 arguments", args.len);
        if (intProblem(buf, "track", args[0], 1, max_track)) |m| return m;
        const field = args[1];
        if (eql(u8, field, "gain")) return floatProblem(buf, "gain", args[2], 0, 1.5) orelse fallback;
        if (eql(u8, field, "pan")) return floatProblem(buf, "pan", args[2], -1, 1) orelse fallback;
        if (eql(u8, field, "mute") or eql(u8, field, "solo") or eql(u8, field, "arm")) {
            const what = std.fmt.bufPrint(buf, "{s} must be on or off", .{field}) catch return fallback;
            return given(buf[what.len..], what, args[2]);
        }
        if (eql(u8, field, "instrument")) return "instrument must be a name of 1 to 32 characters without spaces";
        return std.fmt.bufPrint(buf, "unknown setting '{s}'; use gain, pan, mute, solo, arm or instrument", .{field}) catch fallback;
    }
    if (eql(u8, name, "eq")) {
        if (args.len != 3) return countProblem(buf, "eq takes 3 arguments", args.len);
        if (eql(u8, args[0], "master")) return "eq master takes: tilt on|off";
        if (intProblem(buf, "track", args[0], 1, max_track)) |m| return m;
        if (!eql(u8, args[1], "preset")) return "eq takes: <track> preset NAME, or master tilt on|off";
        return std.fmt.bufPrint(buf, "unknown preset '{s}'; use drums, bass, pads, lead or harp", .{args[2]}) catch fallback;
    }
    if (eql(u8, name, "auto") and args.len == 4 and !eql(u8, args[0], "master")) {
        if (intProblem(buf, "track", args[0], 1, max_track)) |m| return m;
        if (!isAutoLane(args[1])) return given(buf, "lane must be gain, pan or wet", args[1]);
        if (floatProblem(buf, "beat", args[2], 0, 1e6)) |m| return m;
        const low: f64 = if (eql(u8, args[1], "pan")) -1 else 0;
        return floatProblem(buf, "value", args[3], low, 1) orelse fallback;
    }
    return fallback;
}

/// "<what>, got '<text>'" rendered into `buf`.
fn given(buf: []u8, what: []const u8, text: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}, got '{s}'", .{ what, text }) catch "invalid arguments";
}

fn countProblem(buf: []u8, what: []const u8, got: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}, got {d}", .{ what, got }) catch "invalid arguments";
}

/// A message when `text` is not a whole number in min..max; null when it is.
fn intProblem(buf: []u8, label: []const u8, text: []const u8, min: i64, max: i64) ?[]const u8 {
    if (parseIntIn(text, min, max)) |_| return null else |_| {}
    return std.fmt.bufPrint(buf, "{s} must be a whole number {d}..{d}, got '{s}'", .{ label, min, max, text }) catch "invalid arguments";
}

/// A message when `text` is not a finite number in min..max; null when it is.
fn floatProblem(buf: []u8, label: []const u8, text: []const u8, min: f64, max: f64) ?[]const u8 {
    if (parseFloatIn(text, min, max)) |_| return null else |_| {}
    return std.fmt.bufPrint(buf, "{s} must be a number {d}..{d}, got '{s}'", .{ label, min, max, text }) catch "invalid arguments";
}

fn cmdLogs(allocator: std.mem.Allocator, io: std.Io, env: *const Env, args: []const []const u8) !u8 {
    const line_count = parseLogLines(args) catch return usageError(io, logs_usage);
    const path = try runtimeFilePath(allocator, env, log_file_name);
    defer allocator.free(path);

    if ((try statIfExists(io, path)) == null) {
        try printErr(io, "no log at {s}\n", .{path});
        return 1;
    }

    const count_text = try std.fmt.allocPrint(allocator, "{d}", .{line_count});
    defer allocator.free(count_text);
    const tail = (try runCapture(allocator, io, &.{ "tail", "-n", count_text, path })) orelse {
        try printErr(io, "tail failed on {s}\n", .{path});
        return 1;
    };
    defer allocator.free(tail);

    try printOut(io, "{s}", .{tail});
    return 0;
}

// ---------------------------------------------------------------------------
// Argument and path parsing (pure: they take already-read strings)
// ---------------------------------------------------------------------------

const ClickArgs = struct {
    x: i64,
    y: i64,
    double: bool,
};

fn parseClickArgs(args: []const []const u8) error{InvalidArgs}!ClickArgs {
    if (args.len < 2 or args.len > 3) return error.InvalidArgs;
    var double = false;
    if (args.len == 3) {
        if (!std.mem.eql(u8, args[2], "--double")) return error.InvalidArgs;
        double = true;
    }
    return .{
        .x = try parseInteger(args[0]),
        .y = try parseInteger(args[1]),
        .double = double,
    };
}

const DragArgs = struct {
    x: i64,
    y: i64,
    dx: i64,
    dy: i64,
    steps: u32,
    shift: bool,
};

fn parseDragArgs(args: []const []const u8) error{InvalidArgs}!DragArgs {
    if (args.len < 4) return error.InvalidArgs;
    var parsed = DragArgs{
        .x = try parseInteger(args[0]),
        .y = try parseInteger(args[1]),
        .dx = try parseInteger(args[2]),
        .dy = try parseInteger(args[3]),
        .steps = drag_default_steps,
        .shift = false,
    };
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shift")) {
            parsed.shift = true;
        } else if (std.mem.eql(u8, args[i], "--steps")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            const steps = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgs;
            if (steps < 1 or steps > drag_max_steps) return error.InvalidArgs;
            parsed.steps = steps;
        } else {
            return error.InvalidArgs;
        }
    }
    return parsed;
}

fn parseWaitMs(args: []const []const u8) error{InvalidArgs}!?u64 {
    if (args.len == 0) return null;
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--wait-ms")) return error.InvalidArgs;
    return std.fmt.parseInt(u64, args[1], 10) catch return error.InvalidArgs;
}

fn parseLogLines(args: []const []const u8) error{InvalidArgs}!u32 {
    if (args.len == 0) return default_log_lines;
    if (args.len != 1) return error.InvalidArgs;
    return std.fmt.parseInt(u32, args[0], 10) catch return error.InvalidArgs;
}

fn parseInteger(text: []const u8) error{InvalidArgs}!i64 {
    return std.fmt.parseInt(i64, text, 10) catch return error.InvalidArgs;
}

/// Resolves `$XDG_RUNTIME_DIR/<file_name>`, falling back to `/tmp/<file_name>`
/// when the variable is unset or empty (matching the app's own rule).
fn resolveRuntimePath(allocator: std.mem.Allocator, runtime_dir: ?[]const u8, file_name: []const u8) ![]u8 {
    if (runtime_dir) |dir| {
        if (dir.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file_name });
    }
    return std.fmt.allocPrint(allocator, "/tmp/{s}", .{file_name});
}

fn runtimeFilePath(allocator: std.mem.Allocator, env: *const Env, file_name: []const u8) ![]u8 {
    return resolveRuntimePath(allocator, env.get("XDG_RUNTIME_DIR"), file_name);
}

/// Builds the single xdotool invocation for a drag: move to the start, press,
/// move in `steps` equal increments to the end, release. `--shift` wraps it in
/// keydown/keyup shift. Returned slice lives in `arena`.
fn buildDragArgv(arena: std.mem.Allocator, window_id: []const u8, drag: DragArgs) ![]const []const u8 {
    const shift_slots: usize = if (drag.shift) 2 else 0;
    // Each pause is `sleep <seconds>` (2 items). The app drops pointer moves that
    // arrive with no gap, so every step and the press are followed by one.
    const total = 1 + shift_slots + 5 + 2 + 2 + @as(usize, drag.steps) * (5 + 2) + 2 + shift_slots;
    const argv = try arena.alloc([]const u8, total);
    var writer = ArgWriter{ .items = argv };

    writer.push("xdotool");
    if (drag.shift) {
        writer.push("keydown");
        writer.push("shift");
    }
    writer.push("mousemove");
    writer.push("--window");
    writer.push(window_id);
    writer.push(try intString(arena, drag.x));
    writer.push(try intString(arena, drag.y));
    writer.push("mousedown");
    writer.push("1");
    writer.push("sleep");
    writer.push(drag_step_delay);

    const steps: i64 = drag.steps;
    var step: u32 = 1;
    while (step <= drag.steps) : (step += 1) {
        const offset_x = drag.x + @divTrunc(drag.dx * @as(i64, step), steps);
        const offset_y = drag.y + @divTrunc(drag.dy * @as(i64, step), steps);
        writer.push("mousemove");
        writer.push("--window");
        writer.push(window_id);
        writer.push(try intString(arena, offset_x));
        writer.push(try intString(arena, offset_y));
        writer.push("sleep");
        writer.push(drag_step_delay);
    }

    writer.push("mouseup");
    writer.push("1");
    if (drag.shift) {
        writer.push("keyup");
        writer.push("shift");
    }
    std.debug.assert(writer.len == total);
    return argv;
}

/// Fills a pre-sized argv slice in order. The size is computed up front by the
/// caller, so a push past the end is a programming error and asserts.
const ArgWriter = struct {
    items: [][]const u8,
    len: usize = 0,

    fn push(self: *ArgWriter, value: []const u8) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = value;
        self.len += 1;
    }
};

fn intString(allocator: std.mem.Allocator, value: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

// ---------------------------------------------------------------------------
// Output and error helpers
// ---------------------------------------------------------------------------

fn printOut(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var out_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    try stdout_writer.interface.print(fmt, fmt_args);
    try stdout_writer.interface.flush();
}

fn printErr(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) !void {
    var err_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    try stderr_writer.interface.print(fmt, fmt_args);
    try stderr_writer.interface.flush();
}

fn usageError(io: std.Io, usage: []const u8) !u8 {
    try printErr(io, "usage: {s}\n", .{usage});
    return 1;
}

fn noWindowError(io: std.Io) !u8 {
    try printErr(io, "no '{s}' window; start the app first\n", .{window_title});
    return 1;
}

/// Prints the file at `path` exactly as stored. A file that disappears between
/// the stat and the read is reported as missing.
fn printFileContents(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try printErr(io, "no state file at {s}; is the app running?\n", .{path});
            return 1;
        },
        else => return err,
    };
    defer allocator.free(contents);
    try printOut(io, "{s}", .{contents});
    return 0;
}

/// Returns the file's stat, or null when the path does not exist.
fn statIfExists(io: std.Io, path: []const u8) !?std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Runs a command, prints PASS/FAIL to `out`, and returns 1 when it failed.
fn check(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, label: []const u8, argv: []const []const u8) !u8 {
    const ok = runOk(allocator, io, argv) catch false;
    try out.print("  [{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", label });
    return if (ok) 0 else 1;
}

fn isAppRunning(allocator: std.mem.Allocator, io: std.Io) bool {
    return runOk(allocator, io, &.{ "pgrep", "-x", app_binary }) catch false;
}

/// Finds the X window id of the Studio window in the `xwininfo -root -tree` output.
fn findWindowId(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const tree = (try runCapture(allocator, io, &.{ "xwininfo", "-root", "-tree" })) orelse return null;
    defer allocator.free(tree);

    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, window_title) == null) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "0x")) continue;
        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        return try allocator.dupe(u8, trimmed[0..end]);
    }
    return null;
}

/// Runs argv and returns true when it exits with status 0.
fn runOk(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Runs argv and returns its stdout when it exits with status 0; caller frees.
fn runCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    return result.stdout;
}

test "command names are unique" {
    for (commands, 0..) |command, i| {
        for (commands[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, command.name, other.name));
        }
    }
}

test "every command has a summary and usage line" {
    for (commands) |command| {
        try std.testing.expect(command.summary.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, command.usage, "seridian "));
    }
}

test "window id is parsed from xwininfo tree output" {
    const allocator = std.testing.allocator;
    const sample =
        \\     0x400001 "Terminal": ("foot" "foot")  800x600+0+0
        \\     0xa0000d "Seridian Studio — seridian.dev": ("raven" "raven")  1900x980+1930+90
        \\
    ;
    var lines = std.mem.splitScalar(u8, sample, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, window_title) == null) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        found = trimmed[0..end];
    }
    try std.testing.expectEqualStrings("0xa0000d", found.?);
    _ = allocator;
}

test "version string is non-empty" {
    try std.testing.expect(version_string.len > 0);
}

test "drag parser accepts valid input" {
    const drag = try parseDragArgs(&.{ "10", "20", "-5", "300", "--steps", "4", "--shift" });
    try std.testing.expectEqual(@as(i64, 10), drag.x);
    try std.testing.expectEqual(@as(i64, 20), drag.y);
    try std.testing.expectEqual(@as(i64, -5), drag.dx);
    try std.testing.expectEqual(@as(i64, 300), drag.dy);
    try std.testing.expectEqual(@as(u32, 4), drag.steps);
    try std.testing.expect(drag.shift);

    const defaults = try parseDragArgs(&.{ "1", "2", "3", "4" });
    try std.testing.expectEqual(drag_default_steps, defaults.steps);
    try std.testing.expect(!defaults.shift);
}

test "drag parser rejects non-integer dx" {
    try std.testing.expectError(error.InvalidArgs, parseDragArgs(&.{ "10", "10", "abc", "5" }));
}

test "drag parser rejects non-integer dy" {
    try std.testing.expectError(error.InvalidArgs, parseDragArgs(&.{ "10", "10", "5", "zzz" }));
}

test "drag parser rejects steps 0 and 201" {
    try std.testing.expectError(error.InvalidArgs, parseDragArgs(&.{ "10", "10", "5", "5", "--steps", "0" }));
    try std.testing.expectError(error.InvalidArgs, parseDragArgs(&.{ "10", "10", "5", "5", "--steps", "201" }));
    const max = try parseDragArgs(&.{ "10", "10", "5", "5", "--steps", "200" });
    try std.testing.expectEqual(@as(u32, 200), max.steps);
}

test "state path uses XDG_RUNTIME_DIR when set" {
    const allocator = std.testing.allocator;
    const path = try resolveRuntimePath(allocator, "/run/user/1000", state_file_name);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/seridian-state.json", path);
}

test "state path falls back to /tmp when XDG_RUNTIME_DIR is unset or empty" {
    const allocator = std.testing.allocator;
    const unset = try resolveRuntimePath(allocator, null, state_file_name);
    defer allocator.free(unset);
    try std.testing.expectEqualStrings("/tmp/seridian-state.json", unset);

    const empty = try resolveRuntimePath(allocator, "", state_file_name);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("/tmp/seridian-state.json", empty);
}

test "doctor reports the backend that wm.detect returns" {
    const envs = [_][]const [2][]const u8{
        &.{},
        &.{.{ "DISPLAY", ":0" }},
        &.{ .{ "SERIDIAN_WM", "gnome_wayland" }, .{ "DISPLAY", ":0" } },
        &.{ .{ "SERIDIAN_WM", "sway" }, .{ "SWAYSOCK", "/nonexistent-seridian-test-dir/s" } },
        &.{ .{ "SWAYSOCK", "/nonexistent-seridian-test-dir/s" }, .{ "XDG_CURRENT_DESKTOP", "KDE" } },
        &.{ .{ "HYPRLAND_INSTANCE_SIGNATURE", "stale" }, .{ "XDG_RUNTIME_DIR", "/nonexistent-seridian-test-dir" }, .{ "DISPLAY", ":0" } },
    };
    for (envs) |pairs| {
        var env = Env.init(std.testing.allocator);
        defer env.deinit();
        for (pairs) |pair| try env.put(pair[0], pair[1]);
        const detection = try wm_layer.detect(&env);
        var buf: [512]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        try writeWmBackendLine(&out, &env);
        var expected_buf: [512]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "  [INFO] window manager backend: {s} ({s})\n", .{ @tagName(detection.backend), detection.reason });
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}

test "doctor warns about an invalid SERIDIAN_WM instead of guessing" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SERIDIAN_WM", "i3\n");
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeWmBackendLine(&out, &env);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "  [WARN] window manager backend: invalid SERIDIAN_WM 'i3\\n'"));
}

test "doctor arguments: report, help and named fixes" {
    try std.testing.expectEqual(DoctorArgs.report, try parseDoctorArgs(&.{}));
    try std.testing.expectEqual(DoctorArgs.help, try parseDoctorArgs(&.{"--help"}));
    try std.testing.expectEqual(preflight.FixId.hyprland_rules, (try parseDoctorArgs(&.{ "--fix", "hyprland-rules" })).fix);
    try std.testing.expectEqual(preflight.FixId.desktop_entry, (try parseDoctorArgs(&.{ "--fix", "desktop_entry" })).fix);
    try std.testing.expectEqual(preflight.FixId.pipewire_clock, (try parseDoctorArgs(&.{ "--fix", "pipewire-clock" })).fix);
    try std.testing.expectError(error.UnknownFix, parseDoctorArgs(&.{ "--fix", "power-performance" }));
    try std.testing.expectError(error.InvalidArgs, parseDoctorArgs(&.{"--fix"}));
    try std.testing.expectError(error.InvalidArgs, parseDoctorArgs(&.{ "--fix", "a", "b" }));
    try std.testing.expectError(error.InvalidArgs, parseDoctorArgs(&.{"--json"}));
}

test "doctor prints the --fix name for each fix id" {
    try std.testing.expectEqualStrings("", fixCliName(0));
    try std.testing.expectEqualStrings("hyprland-rules", fixCliName(1));
    try std.testing.expectEqualStrings("desktop-entry", fixCliName(2));
    try std.testing.expectEqualStrings("pipewire-clock", fixCliName(3));
    try std.testing.expectEqualStrings("", fixCliName(4));
    // Every fix the help text names parses back.
    for ([_][]const u8{ "hyprland-rules", "desktop-entry", "pipewire-clock" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, doctor_usage, name) != null);
        try std.testing.expect(std.mem.indexOf(u8, doctor_help, name) != null);
        try std.testing.expect(preflight.FixId.parse(name) != null);
    }
}

test "findOnPath skips relative and missing directories" {
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = findOnPath(io, "relative:/nonexistent-seridian-dir:/bin:/usr/bin", "sh", &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, found, "/sh"));
    try std.testing.expect(findOnPath(io, "/nonexistent-seridian-dir", "sh", &buf) == null);
    try std.testing.expect(findOnPath(io, "", "sh", &buf) == null);
}

test "preflight modules' tests are included" {
    std.testing.refAllDecls(preflight);
    std.testing.refAllDecls(preflight_types);
}

test "window-manager layer tests are included" {
    std.testing.refAllDecls(wm_layer);
}

fn expectLine(expected: []const u8, name: []const u8, args: []const []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try buildLine(&buf, name, args));
}

fn expectRejected(name: []const u8, args: []const []const u8) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidArgs, buildLine(&buf, name, args));
}

test "app commands accept valid input" {
    try expectLine("play", "play", &.{});
    try expectLine("stop", "stop", &.{});
    try expectLine("bpm 120", "bpm", &.{"120"});
    try expectLine("bpm 20", "bpm", &.{"20"});
    try expectLine("bpm 300", "bpm", &.{"300"});
    try expectLine("set 1 gain 0.6", "set", &.{ "1", "gain", "0.6" });
    try expectLine("set 8 pan -0.3", "set", &.{ "8", "pan", "-0.3" });
    try expectLine("set 2 mute on", "set", &.{ "2", "mute", "on" });
    try expectLine("set 2 solo off", "set", &.{ "2", "solo", "off" });
    try expectLine("set 3 arm on", "set", &.{ "3", "arm", "on" });
    try expectLine("note 1 60 0 1 100", "note", &.{ "1", "60", "0", "1" });
    try expectLine("note 1 60 0.5 2 90", "note", &.{ "1", "60", "0.5", "2", "90" });
    try expectLine("clear 1", "clear", &.{"1"});
    try expectLine("auto 1 gain 0 0", "auto", &.{ "1", "gain", "0", "0" });
    try expectLine("auto 2 pan 4 -0.5", "auto", &.{ "2", "pan", "4", "-0.5" });
    try expectLine("auto 3 wet 1.5 0.4", "auto", &.{ "3", "wet", "1.5", "0.4" });
    try expectLine("auto master gain 8 1", "auto", &.{ "master", "gain", "8", "1" });
    try expectLine("auto clear 1 gain", "auto", &.{ "clear", "1", "gain" });
    try expectLine("eq 3 preset drums", "eq", &.{ "3", "preset", "drums" });
    try expectLine("eq master tilt on", "eq", &.{ "master", "tilt", "on" });
    try expectRejected("eq", &.{ "3", "preset", "kazoo" });
    try expectRejected("eq", &.{ "master", "tilt", "maybe" });
    try expectLine("save /tmp/song", "save", &.{"/tmp/song"});
    try expectLine("open /tmp/song", "open", &.{"/tmp/song"});
    try expectLine("export /tmp/song/mix.wav", "export", &.{"/tmp/song/mix.wav"});
}

test "app commands reject bad counts and ranges" {
    try expectRejected("play", &.{"1"});
    try expectRejected("bpm", &.{});
    try expectRejected("bpm", &.{"19"});
    try expectRejected("bpm", &.{"301"});
    try expectRejected("bpm", &.{"fast"});
    try expectRejected("bpm", &.{"nan"});
    try expectRejected("set", &.{ "0", "gain", "1" });
    try expectRejected("set", &.{ "9", "gain", "1" });
    try expectRejected("set", &.{ "1", "gain", "1.6" });
    try expectRejected("set", &.{ "1", "gain", "-0.1" });
    try expectRejected("set", &.{ "1", "pan", "1.1" });
    try expectRejected("set", &.{ "1", "pan", "inf" });
    try expectRejected("set", &.{ "1", "mute", "yes" });
    try expectRejected("set", &.{ "1", "volume", "1" });
    try expectRejected("set", &.{ "1", "gain" });
    try expectRejected("note", &.{ "1", "128", "0", "1" });
    try expectRejected("note", &.{ "1", "60", "-1", "1" });
    try expectRejected("note", &.{ "1", "60", "0", "0" });
    try expectRejected("note", &.{ "1", "60", "0", "1", "0" });
    try expectRejected("note", &.{ "1", "60", "0", "1", "128" });
    try expectRejected("note", &.{ "1", "60", "0" });
    try expectRejected("clear", &.{"9"});
    try expectRejected("auto", &.{});
    try expectRejected("auto", &.{ "0", "gain", "0", "0" });
    try expectRejected("auto", &.{ "1", "gain", "-1", "0" });
    try expectRejected("auto", &.{ "1", "gain", "0", "1.1" });
    try expectRejected("auto", &.{ "1", "pan", "0", "-1.1" });
    try expectRejected("auto", &.{ "1", "volume", "0", "1" });
    try expectRejected("auto", &.{ "1", "gain", "0" });
    try expectRejected("auto", &.{ "master", "pan", "0", "0" });
    try expectRejected("auto", &.{ "clear", "1" });
    try expectRejected("auto", &.{ "clear", "9", "gain" });
    try expectRejected("auto", &.{ "clear", "1", "mute" });
    try expectRejected("clear", &.{});
    try expectRejected("save", &.{});
    try expectRejected("save", &.{""});
    try expectRejected("save", &.{ "a", "b" });
    try expectRejected("save", &.{"has space"});
    try expectRejected("open", &.{});
    try expectRejected("open", &.{""});
    try expectRejected("open", &.{ "a", "b" });
    try expectRejected("open", &.{"has space"});
    try expectRejected("export", &.{""});
    var long_path: [max_path_bytes + 1]u8 = undefined;
    @memset(&long_path, 'x');
    try expectRejected("export", &.{long_path[0..]});
}

test "relative save, open and export paths become absolute against the CLI's directory" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "rel", .want = "/work/dir/rel" },
        .{ .path = "a/b.wav", .want = "/work/dir/a/b.wav" },
        .{ .path = "./x", .want = "/work/dir/x" },
        .{ .path = "../up", .want = "/work/up" },
        .{ .path = "/abs/path", .want = "/abs/path" },
    };
    for (cases) |case| {
        const got = try absolutePath(allocator, "/work/dir", case.path);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
    try std.testing.expect(takesPath("save") and takesPath("open") and takesPath("export"));
    try std.testing.expect(!takesPath("bpm"));
}

test "socket path uses XDG_RUNTIME_DIR" {
    const allocator = std.testing.allocator;
    var env = Env.init(allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const path = try socketPath(allocator, &env);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/seridian.sock", path);
}

fn expectProblem(expected: []const u8, name: []const u8, args: []const []const u8) !void {
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings(expected, describeProblem(&buf, name, args));
}

test "describeProblem names the argument that is wrong, its range and what was given" {
    try expectProblem("pitch must be a whole number 0..127, got '200'", "note", &.{ "1", "200", "0", "1" });
    try expectProblem("pitch must be a whole number 0..127, got 'abc'", "note", &.{ "1", "abc", "0", "1" });
    try expectProblem("track must be a whole number 1..8, got '9'", "note", &.{ "9", "60", "0", "1" });
    try expectProblem("start must be a number of beats 0 or more, got '-3'", "note", &.{ "1", "60", "-3", "1" });
    try expectProblem("length must be greater than 0, got '0'", "note", &.{ "1", "60", "0", "0" });
    try expectProblem("velocity must be a whole number 1..127, got '500'", "note", &.{ "1", "60", "0", "1", "500" });
    try expectProblem("note takes 4 or 5 arguments, got 3", "note", &.{ "1", "60", "0" });
}

test "describeProblem covers tempo, set, eq, auto and clear" {
    try expectProblem("tempo must be a number 20..300, got '19'", "bpm", &.{"19"});
    try expectProblem("bpm takes 1 argument, got 0", "bpm", &.{});
    try expectProblem("gain must be a number 0..1.5, got '99'", "set", &.{ "1", "gain", "99" });
    try expectProblem("pan must be a number -1..1, got '2'", "set", &.{ "1", "pan", "2" });
    try expectProblem("mute must be on or off, got 'maybe'", "set", &.{ "1", "mute", "maybe" });
    try expectProblem("unknown setting 'colour'; use gain, pan, mute, solo, arm or instrument", "set", &.{ "1", "colour", "3" });
    try expectProblem("unknown preset 'nope'; use drums, bass, pads, lead or harp", "eq", &.{ "1", "preset", "nope" });
    try expectProblem("track must be a whole number 1..8, got '0'", "clear", &.{"0"});
    try expectProblem("lane must be gain, pan or wet, got 'volume'", "auto", &.{ "1", "volume", "0", "0.5" });
    try expectProblem("value must be a number 0..1, got '2'", "auto", &.{ "1", "gain", "0", "2" });
}

test "describeProblem falls back to a plain message for shapes it does not know" {
    try expectProblem("invalid arguments", "play", &.{"extra"});
}
