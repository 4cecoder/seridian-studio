//! System preflight: everything outside Seridian Studio that decides whether
//! audio is reliable and the app integrates with the desktop.
//!
//! `run` gathers facts (files under /proc and /sys, a few short-lived tools
//! such as pw-metadata and hyprctl) and turns them into `Check`s. Every
//! decision is a pure function over those facts so it is unit tested; the
//! gathering skips tools that are not installed and bounds each with
//! `timeout 3`, so a preflight never stalls.
//!
//! Fixes are opt-in and user-level only: they write files under $HOME and
//! run the user's own session tools (hyprctl reload, pw-metadata,
//! update-desktop-database). Anything that needs root, or changes system-wide
//! state, is reported as a command in the hint and never run.
//!
//! Ported from feat/overhaul 4914565 (src/system/preflight.zig). The GTK UI
//! of 72deebd is not ported; `seridian doctor` (src/cli/main.zig) prints the
//! report.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../utils/sys.zig");
const desktop = @import("desktop.zig");
const wm_types = @import("../cli/wm/types.zig");

const log = std.log.scoped(.preflight);

pub const Text = desktop.Text;

/// How Seridian Studio identifies itself to the desktop.
pub const app = struct {
    /// Installed executable (build.zig `addExe`).
    pub const binary = "seridian-studio";
    pub const name = "Seridian Studio";
    /// WM_CLASS res_name and res_class, set by the UI through Raven's
    /// Rset_window_class (desktop.app_wm_class). Rules also match on the
    /// title to tell the main window from the popouts.
    pub const wm_class = desktop.app_wm_class;
    /// Main window title prefix ("Seridian Studio — seridian.dev").
    pub const main_title_regex = "^(Seridian Studio.*)$";
    /// Popout windows (MIXER_POPOUT_TITLE and "Piano Roll - <track>" in raven_app.c).
    pub const popout_title_regex = "^(Mixer|Piano Roll - .*)$";
    pub const desktop_file = "seridian-studio.desktop";
    pub const hypr_rules_file = "seridian-studio.conf";
    pub const pipewire_drop_in = "90-seridian-studio.conf";
};

pub const Status = enum(u8) {
    ok = 0,
    info = 1,
    warn = 2,
    fail = 3,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .info => "info",
            .warn => "warn",
            .fail => "FAIL",
        };
    }

    pub fn max(a: Status, b: Status) Status {
        return if (@backingInt(b) > @backingInt(a)) b else a;
    }
};

/// Automatic, user-level fixes. Values are part of the C ABI. 4 was
/// `power_performance` (powerprofilesctl set performance), retired because it
/// changes system-wide state; its check now prints the command instead.
pub const FixId = enum(u8) {
    none = 0,
    hyprland_rules = 1,
    desktop_entry = 2,
    pipewire_clock = 3,

    pub fn describe(self: FixId) []const u8 {
        return switch (self) {
            .none => "",
            .hyprland_rules => "Install Hyprland window rules",
            .desktop_entry => "Install the desktop entry",
            .pipewire_clock => "Allow lower PipeWire latency",
        };
    }

    /// Name for `seridian doctor --fix <name>` ("" for none).
    pub fn cliName(self: FixId) []const u8 {
        return switch (self) {
            .none => "",
            .hyprland_rules => "hyprland-rules",
            .desktop_entry => "desktop-entry",
            .pipewire_clock => "pipewire-clock",
        };
    }

    /// Parses a CLI fix name; '-' and '_' are interchangeable.
    pub fn parse(text: []const u8) ?FixId {
        inline for (@typeInfo(FixId).@"enum".field_values) |value| {
            const id: FixId = @fromBackingInt(value);
            if (id != .none and namesMatch(text, id.cliName())) return id;
        }
        return null;
    }

    fn namesMatch(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            const nx: u8 = if (x == '_') '-' else x;
            if (nx != y) return false;
        }
        return true;
    }
};

/// Check identifiers. Values are part of the C ABI. 12 was the desktop
/// portal check: Raven opens file dialogs through zenity or kdialog, not the
/// portal, so it is now the file-dialog check.
pub const CheckId = enum(u8) {
    desktop_session = 0,
    audio_server = 1,
    pipewire_clock = 2,
    realtime = 3,
    memlock = 4,
    cpu_governor = 5,
    power_profile = 6,
    kernel_preempt = 7,
    sound_devices = 8,
    midi = 9,
    desktop_entry = 10,
    hyprland_rules = 11,
    file_dialog = 12,
    gnome_suspend = 13,
};

pub const Check = struct {
    id: CheckId,
    status: Status,
    title: []const u8,
    detail: Text(256) = .{},
    hint: Text(256) = .{},
    fix: FixId = .none,

    pub fn make(id: CheckId, status: Status, title: []const u8) Check {
        return .{ .id = id, .status = status, .title = title };
    }
};

pub const max_checks = 24;

pub const Report = struct {
    info: desktop.Info,
    /// Compositor/desktop version when known ("0.56.2").
    desktop_version: Text(32) = .{},
    checks: [max_checks]Check = undefined,
    len: usize = 0,

    pub fn add(self: *Report, check: Check) void {
        if (self.len == max_checks) {
            log.warn("preflight report full; dropping {s}", .{@tagName(check.id)});
            return;
        }
        self.checks[self.len] = check;
        self.len += 1;
    }

    pub fn items(self: *const Report) []const Check {
        return self.checks[0..self.len];
    }

    pub fn worst(self: *const Report) Status {
        var w: Status = .ok;
        for (self.items()) |c| w = w.max(c.status);
        return w;
    }
};

pub const Options = struct {
    sample_rate: u32 = 48000,
    buffer_size: u32 = 128,
    /// Backend the running engine actually uses ("pipewire", "pulseaudio",
    /// "none"...), or null when no engine is running (`seridian doctor`).
    active_backend: ?[]const u8 = null,
    /// Absolute path of the installed seridian-studio binary, for the
    /// desktop entry's Exec line. Null when it could not be found.
    studio_exe: ?[]const u8 = null,
};

// ===========================================================================
// Running the checks
// ===========================================================================

/// Gather facts and evaluate every check. `env` is anything with a
/// `get(name) ?[]const u8` method (std.process.Environ.Map in the CLI,
/// desktop.ProcessEnv in the engine library). `scratch` backs tool output;
/// nothing allocated is kept after return.
pub fn run(scratch: std.mem.Allocator, env: anytype, opts: Options) Report {
    var report: Report = .{ .info = desktop.detect(env) };
    if (builtin.os.tag != .linux) {
        report.add(sessionCheck(report.info, ""));
        return report;
    }

    const procs = ProcSet.scan();
    var dirs: XdgDirs = undefined;
    dirs.init(env);

    // Desktop-specific facts first: the version shows up in the session row.
    var hypr_version: ?Version = null;
    if (report.info.desktop == .hyprland) {
        var argv_buf: [8][]const u8 = undefined;
        if (runTool(scratch, hyprctlArgv(&report.info, &.{ "version", "-j" }, &argv_buf))) |out| {
            defer scratch.free(out);
            hypr_version = parseHyprVersion(out);
            if (hypr_version) |v| report.desktop_version.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        }
    }
    report.add(sessionCheck(report.info, report.desktop_version.slice()));

    // Audio.
    const servers = AudioServers.detect(&dirs, procs);
    report.add(audioServerCheck(servers, opts));
    if (servers.pipewire_socket) {
        const clock: ?PwClock = if (runTool(scratch, &.{ "pw-metadata", "-n", "settings" })) |out| blk: {
            defer scratch.free(out);
            break :blk parsePwSettings(out);
        } else null;
        report.add(pipewireClockCheck(clock, opts));
    }
    report.add(soundDevicesCheck(scanSoundDevices()));

    // Scheduling and power.
    const rtkit = procs.has(.rtkit) or fileExists("/usr/libexec/rtkit-daemon") or fileExists("/usr/lib/rtkit/rtkit-daemon");
    const groups = groupsText(scratch);
    report.add(realtimeCheck(rlimitCur(.RTPRIO), rtkit, groups.slice()));
    report.add(memlockCheck(rlimitCur(.MEMLOCK)));
    {
        var kv: [256]u8 = undefined;
        var cmd: [1024]u8 = undefined;
        var dbg: [128]u8 = undefined;
        var rt: [8]u8 = undefined;
        report.add(kernelCheck(
            readSmall("/proc/sys/kernel/version", &kv) orelse "",
            readSmall("/proc/cmdline", &cmd) orelse "",
            readSmall("/sys/kernel/debug/sched/preempt", &dbg),
            std.mem.eql(u8, trimLine(readSmall("/sys/kernel/realtime", &rt) orelse ""), "1"),
        ));
    }
    {
        var d: [64]u8 = undefined;
        var g: [64]u8 = undefined;
        var e: [64]u8 = undefined;
        if (readSmall("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", &g)) |gov| {
            report.add(governorCheck(
                trimLine(readSmall("/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver", &d) orelse ""),
                trimLine(gov),
                if (readSmall("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", &e)) |v| trimLine(v) else null,
            ));
        }
    }
    if (powerProfile(scratch)) |pp| report.add(powerProfileCheck(pp));

    report.add(midiCheck(fileExists("/dev/snd/seq"), accessRw("/dev/snd/seq")));

    // Desktop integration.
    {
        var entry_buf: [4096]u8 = undefined;
        report.add(desktopEntryCheck(report.info.desktop, findDesktopEntry(env, &dirs, &entry_buf)));
    }
    if (report.info.desktop == .hyprland) {
        var conf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const conf: ?[]u8 = if (hyprConfigPath(env, &dirs, &conf_path_buf)) |p|
            sys.readFileAlloc(scratch, p, max_config_bytes) catch null
        else
            null;
        defer if (conf) |c| scratch.free(c);
        var rules_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rules_file: ?[]u8 = if (hyprConfigPath(env, &dirs, &conf_path_buf)) |p| blk: {
            const dir = std.fs.path.dirname(p) orelse break :blk null;
            const rules_path = std.fmt.bufPrint(&rules_path_buf, "{s}/" ++ app.hypr_rules_file, .{dir}) catch break :blk null;
            break :blk sys.readFileAlloc(scratch, rules_path, max_config_bytes) catch null;
        } else null;
        defer if (rules_file) |r| scratch.free(r);
        report.add(hyprlandRulesCheck(conf, rules_file, hypr_version));
    }
    report.add(fileDialogCheck(report.info.desktop, wm_types.haveTool("zenity"), wm_types.haveTool("kdialog")));
    if (report.info.desktop == .gnome) {
        if (runTool(scratch, &.{ "gsettings", "get", "org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type" })) |out| {
            defer scratch.free(out);
            report.add(gnomeSuspendCheck(std.mem.trim(u8, out, " \n'")));
        }
    }
    return report;
}

const max_config_bytes: usize = 4 << 20;

// ===========================================================================
// Session
// ===========================================================================

pub fn sessionCheck(info: desktop.Info, version: []const u8) Check {
    var c = Check.make(.desktop_session, .ok, "Desktop session");
    const name = info.desktopName();
    if (version.len > 0) {
        c.detail.print("{s} {s} on {s}", .{ name, version, info.session.name() });
    } else {
        c.detail.print("{s} on {s}", .{ name, info.session.name() });
    }
    switch (info.session) {
        .tty => {
            c.status = .info;
            c.detail.print("No graphical session in this environment (desktop: {s})", .{name});
            c.hint.set("Run Seridian Studio from your desktop session; this is expected over SSH or in a plain TTY.");
        },
        .x11 => if (info.wayland_socket) {
            // X11 session type while a compositor socket exists: XWayland env.
            c.status = .info;
            c.hint.set("A Wayland compositor is running but this process sees an X11 session; the app runs through XWayland either way.");
        },
        else => {},
    }
    if (info.desktop == .hyprland and info.hypr_signature_from_socket) {
        c.status = c.status.max(.info);
        c.hint.set("HYPRLAND_INSTANCE_SIGNATURE is missing or stale in this environment; found Hyprland through its socket. Launch Seridian Studio from Hyprland (exec, launcher) for full integration.");
    }
    return c;
}

// ===========================================================================
// Audio server
// ===========================================================================

pub const AudioServers = struct {
    pipewire_socket: bool = false,
    pulse_socket: bool = false,
    pipewire_pulse: bool = false,
    pulseaudio: bool = false,
    session_manager: bool = false,

    fn detect(dirs: *const XdgDirs, procs: ProcSet) AudioServers {
        var s: AudioServers = .{};
        if (dirs.runtime_dir) |rd| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/pipewire-0", .{rd})) |p| {
                s.pipewire_socket = fileExists(p);
            } else |err| switch (err) {
                error.NoSpaceLeft => {},
            }
            if (std.fmt.bufPrint(&buf, "{s}/pulse/native", .{rd})) |p| {
                s.pulse_socket = fileExists(p);
            } else |err| switch (err) {
                error.NoSpaceLeft => {},
            }
        }
        s.pipewire_pulse = procs.has(.pipewire_pulse);
        s.pulseaudio = procs.has(.pulseaudio);
        s.session_manager = procs.has(.wireplumber) or procs.has(.pipewire_media_session);
        return s;
    }
};

pub fn audioServerCheck(s: AudioServers, opts: Options) Check {
    var c = Check.make(.audio_server, .ok, "Audio server");
    if (!s.pipewire_socket and !s.pulse_socket) {
        c.status = .fail;
        c.detail.set("No PipeWire or PulseAudio server is running; Seridian Studio plays silently.");
        c.hint.set("Start PipeWire with pipewire-pulse and WirePlumber (your distro's pipewire package or launcher).");
        return c;
    }
    const pulse_kind: []const u8 = if (s.pipewire_pulse) "pipewire-pulse" else if (s.pulseaudio) "PulseAudio" else "a PulseAudio socket";
    if (s.pipewire_socket and s.pulse_socket) {
        c.detail.print("PipeWire with {s}", .{pulse_kind});
    } else if (s.pipewire_socket) {
        c.detail.set("PipeWire (no PulseAudio compatibility server)");
    } else {
        c.detail.print("{s} only", .{pulse_kind});
    }
    if (opts.active_backend) |b| {
        _ = c.detail.append("; app output: {s}", .{b});
        if (std.mem.eql(u8, b, "none")) {
            c.status = .fail;
            c.hint.set("A server is running but Seridian Studio could not connect to it. Check DAW_AUDIO_BACKEND and the Audio settings, then restart the app.");
            return c;
        }
    }
    if (s.pipewire_socket and !s.session_manager) {
        c.status = .warn;
        c.hint.set("PipeWire has no session manager, so devices and streams are not linked. Start WirePlumber.");
    }
    return c;
}

// ===========================================================================
// PipeWire clock
// ===========================================================================

pub const PwClock = struct {
    rate: u32 = 0,
    quantum: u32 = 0,
    min_quantum: u32 = 0,
    max_quantum: u32 = 0,
    force_quantum: u32 = 0,
    force_rate: u32 = 0,
    allowed_rates: [16]u32 = undefined,
    allowed_len: usize = 0,

    pub fn allows(self: *const PwClock, rate: u32) bool {
        if (self.allowed_len == 0) return rate == self.rate;
        for (self.allowed_rates[0..self.allowed_len]) |r| if (r == rate) return true;
        return false;
    }
};

/// Parse `pw-metadata -n settings` output
/// (`update: id:0 key:'clock.rate' value:'48000' type:''`).
pub fn parsePwSettings(text: []const u8) ?PwClock {
    var clock: PwClock = .{};
    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = quoted(line, "key:'") orelse continue;
        const value = quoted(line, "value:'") orelse continue;
        if (std.mem.eql(u8, key, "clock.allowed-rates")) {
            var it = std.mem.tokenizeAny(u8, value, "[ ],");
            while (it.next()) |tok| {
                if (clock.allowed_len == clock.allowed_rates.len) break;
                const r = std.fmt.parseInt(u32, tok, 10) catch continue;
                clock.allowed_rates[clock.allowed_len] = r;
                clock.allowed_len += 1;
            }
            any = true;
            continue;
        }
        const n = std.fmt.parseInt(u32, value, 10) catch continue;
        const Field = struct { []const u8, *u32 };
        const fields = [_]Field{
            .{ "clock.rate", &clock.rate },
            .{ "clock.quantum", &clock.quantum },
            .{ "clock.min-quantum", &clock.min_quantum },
            .{ "clock.max-quantum", &clock.max_quantum },
            .{ "clock.force-quantum", &clock.force_quantum },
            .{ "clock.force-rate", &clock.force_rate },
        };
        for (fields) |f| if (std.mem.eql(u8, key, f[0])) {
            f[1].* = n;
            any = true;
        };
    }
    return if (any and clock.rate != 0) clock else null;
}

fn quoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, line, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '\'') orelse return null;
    return line[start..end];
}

/// The quantum PipeWire will actually run when the app asks for `buffer`.
pub fn effectiveQuantum(clock: PwClock, buffer: u32) u32 {
    if (clock.force_quantum != 0) return clock.force_quantum;
    var q = buffer;
    if (clock.min_quantum != 0) q = @max(q, clock.min_quantum);
    if (clock.max_quantum != 0) q = @min(q, clock.max_quantum);
    return q;
}

pub fn pipewireClockCheck(clock_opt: ?PwClock, opts: Options) Check {
    var c = Check.make(.pipewire_clock, .ok, "PipeWire latency");
    const clock = clock_opt orelse {
        c.status = .info;
        c.detail.set("Could not read PipeWire's clock settings (pw-metadata missing or failed).");
        return c;
    };
    const quantum = effectiveQuantum(clock, opts.buffer_size);
    const rate = if (clock.force_rate != 0) clock.force_rate else if (clock.allows(opts.sample_rate)) opts.sample_rate else clock.rate;
    const latency_ms = @as(f64, @floatFromInt(quantum)) * 1000.0 / @as(f64, @floatFromInt(@max(rate, 1)));
    c.detail.print("{d} Hz, {d}-frame quantum ({d:.1} ms per cycle); the app asks for {d} frames at {d} Hz", .{ rate, quantum, latency_ms, opts.buffer_size, opts.sample_rate });

    if (clock.force_quantum != 0 and clock.force_quantum != opts.buffer_size) {
        c.status = .info;
        c.hint.print("clock.force-quantum={d} overrides the app's buffer. Reset it with: pw-metadata -n settings 0 clock.force-quantum 0", .{clock.force_quantum});
    }
    if (clock.min_quantum > opts.buffer_size) {
        c.status = .warn;
        c.hint.print("PipeWire won't run below {d} frames (clock.min-quantum), so the {d}-frame buffer can't take effect.", .{ clock.min_quantum, opts.buffer_size });
        c.fix = .pipewire_clock;
    }
    if (!clock.allows(opts.sample_rate) and clock.force_rate == 0) {
        c.status = .warn;
        c.hint.print("{d} Hz is not in clock.allowed-rates, so PipeWire resamples the app to {d} Hz.", .{ opts.sample_rate, clock.rate });
        c.fix = .pipewire_clock;
    }
    return c;
}

/// Lowest quantum worth allowing for the app: a power of two at or below the
/// buffer, clamped to [32, 1024].
pub fn minQuantumFor(buffer: u32) u32 {
    var q: u32 = 32;
    while (q * 2 <= buffer and q < 1024) q *= 2;
    return @min(q, buffer);
}

/// PipeWire drop-in that lets the graph run at the app's buffer and rate.
pub fn pipewireDropIn(buf: []u8, sample_rate: u32, buffer_size: u32) std.Io.Writer.Error![]const u8 {
    var rates: [5]u32 = .{ 44100, 48000, 88200, 96000, sample_rate };
    var n: usize = 4;
    if (std.mem.indexOfScalar(u32, rates[0..4], sample_rate) == null) n = 5;
    std.mem.sort(u32, rates[0..n], {}, std.sort.asc(u32));
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("# Seridian Studio: allow the PipeWire graph to follow the app's buffer and sample rate.\n");
    try w.writeAll("# Generated by `seridian doctor --fix pipewire-clock`; delete this file to undo.\n");
    try w.writeAll("context.properties = {\n    default.clock.allowed-rates = [");
    for (rates[0..n]) |r| try w.print(" {d}", .{r});
    try w.print(" ]\n    default.clock.min-quantum = {d}\n}}\n", .{minQuantumFor(buffer_size)});
    return w.buffered();
}

// ===========================================================================
// Devices, scheduling, kernel, power
// ===========================================================================

pub const SoundDevices = struct { cards: u32 = 0, accessible: u32 = 0 };

fn scanSoundDevices() SoundDevices {
    var s: SoundDevices = .{};
    var dir = std.Io.Dir.openDirAbsolute(sys.io(), "/dev/snd", .{ .iterate = true }) catch return s;
    defer dir.close(sys.io());
    var it = dir.iterate();
    while (true) {
        const entry = (it.next(sys.io()) catch return s) orelse return s;
        if (!std.mem.startsWith(u8, entry.name, "controlC")) continue;
        s.cards += 1;
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/dev/snd/{s}", .{entry.name}) catch continue;
        if (accessRw(path)) s.accessible += 1;
    }
}

pub fn soundDevicesCheck(s: SoundDevices) Check {
    var c = Check.make(.sound_devices, .ok, "Sound cards");
    if (s.cards == 0) {
        c.status = .warn;
        c.detail.set("No ALSA sound cards found under /dev/snd.");
        c.hint.set("Check that your sound driver is loaded (lspci -k, dmesg). USB interfaces need snd-usb-audio.");
        return c;
    }
    c.detail.print("{d} card(s), {d} accessible to this user", .{ s.cards, s.accessible });
    if (s.accessible == 0) {
        c.status = .warn;
        c.hint.set("Your user can't open the sound cards. Log in through a seat manager (logind/elogind) or, as root: usermod -aG audio $USER, then log in again.");
    }
    return c;
}

pub fn realtimeCheck(rtprio: ?u64, rtkit: bool, groups: []const u8) Check {
    var c = Check.make(.realtime, .ok, "Realtime scheduling");
    const prio = rtprio orelse 0;
    if (prio > 0) {
        c.detail.print("Realtime priority allowed (rtprio limit {d})", .{prio});
    } else if (rtkit) {
        c.detail.set("No rtprio limit, but RealtimeKit can grant realtime priority to PipeWire");
        c.status = .info;
        c.hint.set("For the lowest latency, allow rtprio directly (root): echo '@audio - rtprio 95' > /etc/security/limits.d/95-audio.conf, add yourself to audio, log in again.");
    } else {
        c.status = .warn;
        c.detail.set("No realtime priority: audio threads compete with everything else and may drop out.");
        c.hint.set("As root: echo '@audio - rtprio 95' > /etc/security/limits.d/95-audio.conf; usermod -aG audio $USER; then log in again (or install rtkit).");
    }
    if (groups.len > 0) _ = c.detail.append("; groups: {s}", .{groups});
    return c;
}

pub fn memlockCheck(limit: ?u64) Check {
    var c = Check.make(.memlock, .ok, "Locked memory");
    const l = limit orelse {
        c.status = .info;
        c.detail.set("Could not read RLIMIT_MEMLOCK.");
        return c;
    };
    if (l == std.math.maxInt(u64) or l == std.posix.RLIM.INFINITY) {
        c.detail.set("Unlimited");
        return c;
    }
    c.detail.print("{d} MiB", .{l >> 20});
    if (l < 64 << 20) {
        c.status = .info;
        c.hint.set("Large sample libraries lock more memory; raise it as root, e.g. '@audio - memlock unlimited' in /etc/security/limits.d/95-audio.conf.");
    }
    return c;
}

pub const Preempt = enum { rt, full, dynamic_full, dynamic_voluntary, dynamic_none, dynamic_unknown, voluntary, none };

/// Classify the kernel's preemption model from `uname -v` text, the boot
/// command line, the debugfs mode file (root only, so often null) and
/// /sys/kernel/realtime.
pub fn parsePreempt(version: []const u8, cmdline: []const u8, debug_mode: ?[]const u8, realtime: bool) Preempt {
    if (realtime or std.mem.indexOf(u8, version, "PREEMPT_RT") != null) return .rt;
    if (std.mem.indexOf(u8, version, "PREEMPT_DYNAMIC") != null) {
        if (debug_mode) |m| {
            // "none voluntary (full) lazy": the active mode is in parentheses.
            if (std.mem.indexOf(u8, m, "(full)") != null) return .dynamic_full;
            if (std.mem.indexOf(u8, m, "(voluntary)") != null) return .dynamic_voluntary;
            if (std.mem.indexOf(u8, m, "(none)") != null) return .dynamic_none;
            if (std.mem.indexOf(u8, m, "(lazy)") != null) return .dynamic_full;
        }
        if (cmdlineValue(cmdline, "preempt")) |v| {
            if (std.mem.eql(u8, v, "full") or std.mem.eql(u8, v, "lazy")) return .dynamic_full;
            if (std.mem.eql(u8, v, "voluntary")) return .dynamic_voluntary;
            if (std.mem.eql(u8, v, "none")) return .dynamic_none;
        }
        return .dynamic_unknown;
    }
    if (std.mem.indexOf(u8, version, "PREEMPT ") != null or std.mem.endsWith(u8, std.mem.trimEnd(u8, version, "\n"), "PREEMPT")) return .full;
    if (std.mem.indexOf(u8, version, "PREEMPT_VOLUNTARY") != null) return .voluntary;
    return .none;
}

pub fn cmdlineHas(cmdline: []const u8, flag: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (it.next()) |tok| if (std.mem.eql(u8, tok, flag)) return true;
    return false;
}

fn cmdlineValue(cmdline: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, cmdline, " \n");
    while (it.next()) |tok| {
        if (tok.len > key.len and std.mem.startsWith(u8, tok, key) and tok[key.len] == '=') return tok[key.len + 1 ..];
    }
    return null;
}

pub fn kernelCheck(version: []const u8, cmdline: []const u8, debug_mode: ?[]const u8, realtime: bool) Check {
    var c = Check.make(.kernel_preempt, .ok, "Kernel preemption");
    const p = parsePreempt(version, cmdline, debug_mode, realtime);
    const threadirqs = cmdlineHas(cmdline, "threadirqs");
    const irq_note: []const u8 = if (threadirqs) ", threaded IRQs" else "";
    const add_full = "Add preempt=full (and optionally threadirqs) to the kernel command line for steadier low-latency audio.";
    switch (p) {
        .rt => c.detail.print("PREEMPT_RT realtime kernel{s}", .{irq_note}),
        .full => c.detail.print("Fully preemptible kernel{s}", .{irq_note}),
        .dynamic_full => c.detail.print("Dynamic preemption, full mode{s}", .{irq_note}),
        .dynamic_voluntary, .dynamic_none => {
            c.status = .info;
            c.detail.print("Dynamic preemption in {s} mode{s}", .{ if (p == .dynamic_none) "none" else "voluntary", irq_note });
            c.hint.set(add_full);
        },
        .dynamic_unknown => {
            c.status = .info;
            c.detail.print("Dynamic preemption (boot default, usually voluntary on distro kernels){s}", .{irq_note});
            c.hint.set(add_full);
        },
        .voluntary, .none => {
            c.status = .info;
            c.detail.print("{s} preemption{s}", .{ if (p == .none) "No" else "Voluntary", irq_note });
            c.hint.set("Small buffers may crackle under load; a PREEMPT or PREEMPT_RT kernel helps.");
        },
    }
    return c;
}

const performance_profile_hint = "Switch the power profile to performance while recording: powerprofilesctl set performance";

pub fn governorCheck(driver: []const u8, governor: []const u8, epp: ?[]const u8) Check {
    var c = Check.make(.cpu_governor, .ok, "CPU frequency");
    if (epp) |e| {
        c.detail.print("{s}, governor {s}, energy preference {s}", .{ driver, governor, e });
    } else {
        c.detail.print("{s}, governor {s}", .{ driver, governor });
    }
    const root_hint = "While recording, as root: cpupower frequency-set -g performance";
    if (std.mem.eql(u8, governor, "performance")) return c;
    if (epp) |e| {
        // intel_pstate / amd-pstate-epp: "powersave" is normal; EPP decides.
        if (std.mem.eql(u8, e, "performance") or std.mem.eql(u8, e, "balance_performance")) return c;
        c.status = if (std.mem.eql(u8, e, "power")) .warn else .info;
        c.hint.set("The CPU favours power saving and ramps up slowly. " ++ performance_profile_hint);
        return c;
    }
    c.status = if (std.mem.eql(u8, governor, "powersave")) .warn else .info;
    c.hint.set(root_hint);
    return c;
}

pub const PowerProfile = struct {
    source: enum { ppd, tuned, platform },
    name: Text(48) = .{},
};

fn powerProfile(scratch: std.mem.Allocator) ?PowerProfile {
    if (runTool(scratch, &.{ "powerprofilesctl", "get" })) |out| {
        defer scratch.free(out);
        return .{ .source = .ppd, .name = .init(trimLine(out)) };
    }
    if (runTool(scratch, &.{ "tuned-adm", "active" })) |out| {
        defer scratch.free(out);
        if (parseTunedActive(out)) |name| return .{ .source = .tuned, .name = .init(name) };
    }
    var buf: [64]u8 = undefined;
    if (readSmall("/sys/firmware/acpi/platform_profile", &buf)) |p| return .{ .source = .platform, .name = .init(trimLine(p)) };
    return null;
}

pub fn parseTunedActive(out: []const u8) ?[]const u8 {
    const prefix = "Current active profile:";
    const i = std.mem.indexOf(u8, out, prefix) orelse return null;
    const rest = out[i + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const name = std.mem.trim(u8, rest[0..end], " \t");
    return if (name.len == 0) null else name;
}

pub fn powerProfileCheck(p: PowerProfile) Check {
    var c = Check.make(.power_profile, .ok, "Power profile");
    const name = p.name.slice();
    const via: []const u8 = switch (p.source) {
        .ppd => "power-profiles-daemon",
        .tuned => "TuneD",
        .platform => "platform profile",
    };
    c.detail.print("{s} ({s})", .{ name, via });
    const low = std.mem.indexOf(u8, name, "power-saver") != null or std.mem.indexOf(u8, name, "powersave") != null or
        std.mem.eql(u8, name, "low-power") or std.mem.eql(u8, name, "quiet");
    const high = std.mem.indexOf(u8, name, "performance") != null or std.mem.indexOf(u8, name, "latency") != null or std.mem.indexOf(u8, name, "realtime") != null;
    if (high) return c;
    c.status = if (low) .warn else .info;
    c.hint.set(switch (p.source) {
        .ppd => "Use the performance profile while recording or playing dense sessions: powerprofilesctl set performance",
        .tuned => "As root: tuned-adm profile latency-performance",
        .platform => "As root: echo performance > /sys/firmware/acpi/platform_profile",
    });
    return c;
}

pub fn midiCheck(seq_exists: bool, seq_rw: bool) Check {
    var c = Check.make(.midi, .ok, "MIDI");
    if (!seq_exists) {
        c.status = .info;
        c.detail.set("ALSA sequencer not available (/dev/snd/seq missing); hardware MIDI input is off.");
        c.hint.set("Load it as root: modprobe snd-seq. On-screen editing works without it.");
    } else if (!seq_rw) {
        c.status = .warn;
        c.detail.set("ALSA sequencer present but not accessible to this user; hardware MIDI input is off.");
        c.hint.set("As root: usermod -aG audio $USER, then log in again.");
    } else {
        c.detail.set("ALSA sequencer available for hardware MIDI input");
    }
    return c;
}

// ===========================================================================
// Desktop integration
// ===========================================================================

/// True when a desktop entry's StartupWMClass matches the app's window class.
pub fn desktopEntryOk(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "StartupWMClass=")) return std.mem.eql(u8, line["StartupWMClass=".len..], app.wm_class);
    }
    return false;
}

pub const EntryState = enum { missing, no_wm_class, ok };

fn findDesktopEntry(env: anytype, dirs: *const XdgDirs, buf: []u8) EntryState {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var found = false;
    if (dirs.data_home) |dh| {
        if (std.fmt.bufPrint(&path_buf, "{s}/applications/" ++ app.desktop_file, .{dh})) |p| {
            if (readSmall(p, buf)) |text| {
                if (desktopEntryOk(text)) return .ok;
                found = true;
            }
        } else |err| switch (err) {
            error.NoSpaceLeft => {},
        }
    }
    const data_dirs = env.get("XDG_DATA_DIRS") orelse "";
    var dir_it = std.mem.tokenizeScalar(u8, if (data_dirs.len > 0) data_dirs else "/usr/local/share:/usr/share", ':');
    while (dir_it.next()) |d| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/applications/" ++ app.desktop_file, .{d}) catch continue;
        if (readSmall(p, buf)) |text| {
            if (desktopEntryOk(text)) return .ok;
            found = true;
        }
    }
    return if (found) .no_wm_class else .missing;
}

pub fn desktopEntryCheck(d: desktop.Desktop, state: EntryState) Check {
    var c = Check.make(.desktop_entry, .ok, "App launcher entry");
    switch (state) {
        .ok => {
            c.detail.set(app.desktop_file ++ " installed and matched to the window (StartupWMClass=" ++ app.wm_class ++ ")");
            return c;
        },
        .no_wm_class => c.detail.set(app.desktop_file ++ " exists but does not set StartupWMClass=" ++ app.wm_class),
        .missing => c.detail.set("No " ++ app.desktop_file ++ " entry"),
    }
    // Docks and task managers match windows to entries; without one the app
    // shows a generic icon and can't be pinned.
    c.status = switch (d) {
        .kde, .gnome, .cosmic, .cinnamon, .xfce => .warn,
        else => .info,
    };
    c.hint.set(switch (d) {
        .kde => "Plasma's task manager shows a generic icon and can't pin Seridian Studio.",
        .gnome => "GNOME's dash and app grid can't show or pin Seridian Studio.",
        else => "App launchers can't find Seridian Studio and docks show a generic icon.",
    });
    c.fix = .desktop_entry;
    return c;
}

/// Desktop entry for `exe_path` (absolute path of the seridian-studio binary).
pub fn desktopEntry(buf: []u8, exe_path: []const u8) std.Io.Writer.Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll(
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Seridian Studio
        \\GenericName=Digital Audio Workstation
        \\Comment=Record, arrange and mix music
        \\
    );
    // Exec quoting per the Desktop Entry spec.
    try w.writeAll("Exec=\"");
    for (exe_path) |ch| {
        if (ch == '"' or ch == '`' or ch == '$' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeAll(
        \\"
        \\Icon=audio-x-generic
        \\Terminal=false
        \\Categories=AudioVideo;Audio;Midi;Music;
        \\Keywords=music;audio;recording;midi;sequencer;
        \\StartupNotify=true
        \\
    );
    try w.writeAll("StartupWMClass=" ++ app.wm_class ++ "\n");
    return w.buffered();
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn atLeast(self: Version, major: u32, minor: u32) bool {
        return self.major > major or (self.major == major and self.minor >= minor);
    }
};

/// Version from `hyprctl version -j` ("tag": "v0.56.2-12-gabc" or "version").
pub fn parseHyprVersion(json: []const u8) ?Version {
    for ([_][]const u8{ "\"version\"", "\"tag\"" }) |key| {
        const i = std.mem.indexOf(u8, json, key) orelse continue;
        var rest = json[i + key.len ..];
        const q = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        rest = rest[q + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        var s = rest[0..end];
        if (s.len > 0 and s[0] == 'v') s = s[1..];
        var parts = std.mem.tokenizeAny(u8, s, ".-");
        const major = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
        const minor = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
        const patch = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        return .{ .major = major, .minor = minor, .patch = patch };
    }
    return null;
}

/// True when hyprland.conf sources the app's rules file (comments ignored).
pub fn hyprConfigSourcesRules(conf: []const u8) bool {
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "source") and std.mem.indexOf(u8, line, app.hypr_rules_file) != null) return true;
    }
    return false;
}

/// True when a rules text has a window rule for the app's current window
/// class (comments ignored). A rules file written before the app had its own
/// class matches "raven" and is stale.
pub fn hyprRulesMatchClass(rules: []const u8) bool {
    var lines = std.mem.splitScalar(u8, rules, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "windowrule") and std.mem.indexOf(u8, line, "^(" ++ app.wm_class ++ ")$") != null) return true;
    }
    return false;
}

/// True when hyprland.conf already sources the app's rules file or has rules
/// for its window class (comments ignored).
pub fn hyprConfigHasRules(conf: []const u8) bool {
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "source") and std.mem.indexOf(u8, line, app.hypr_rules_file) != null) return true;
        if (std.mem.startsWith(u8, line, "windowrule") and std.mem.indexOf(u8, line, "^(" ++ app.wm_class ++ ")$") != null) return true;
    }
    return false;
}

/// `rules_file` is the sourced rules file (seridian-studio.conf next to
/// hyprland.conf), or null when it could not be read.
pub fn hyprlandRulesCheck(conf: ?[]const u8, rules_file: ?[]const u8, version: ?Version) Check {
    var c = Check.make(.hyprland_rules, .ok, "Hyprland window rules");
    const text = conf orelse {
        c.status = .info;
        c.detail.set("Could not read hyprland.conf");
        return c;
    };
    if (hyprConfigSourcesRules(text)) {
        if (rules_file) |rules| if (!hyprRulesMatchClass(rules)) {
            c.status = .warn;
            c.detail.set(app.hypr_rules_file ++ " is outdated: its rules do not match the window class " ++ app.wm_class);
            c.hint.set("Rewrite it so the Mixer and Piano Roll popouts float again.");
            c.fix = .hyprland_rules;
            return c;
        };
    }
    if (hyprConfigHasRules(text)) {
        c.detail.set("Installed: the Mixer and Piano Roll popouts float; idle stays inhibited in fullscreen");
        return c;
    }
    c.status = .warn;
    c.detail.set("No rules for Seridian Studio's windows (class " ++ app.wm_class ++ ")");
    c.hint.set("Without them the Mixer and Piano Roll popouts tile instead of floating over the arrangement.");
    c.fix = .hyprland_rules;
    if (version == null) c.hint.set("Without them the Mixer and Piano Roll popouts tile. (hyprctl unavailable; rules use the newest syntax.)");
    return c;
}

/// Window rules for Seridian Studio. Hyprland 0.53 replaced windowrulev2 with
/// `windowrule = match:..., effect value`; both forms are produced. Every
/// rule matches the app's class (desktop.app_wm_class) and a title, which
/// tells the main window from the popouts.
pub fn hyprlandRules(buf: []u8, version: ?Version) std.Io.Writer.Error![]const u8 {
    const modern = if (version) |v| v.atLeast(0, 53) else true;
    const class = "^(" ++ app.wm_class ++ ")$";
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("# Seridian Studio: Hyprland integration. Generated by `seridian doctor --fix hyprland-rules`;\n");
    try w.writeAll("# remove the `source` line in hyprland.conf to undo.\n");
    if (modern) {
        try w.writeAll("windowrule = match:class " ++ class ++ ", match:title " ++ app.popout_title_regex ++ ", float true\n");
        try w.writeAll("windowrule = match:class " ++ class ++ ", match:title " ++ app.main_title_regex ++ ", idle_inhibit fullscreen\n");
    } else {
        try w.writeAll("windowrulev2 = float, class:" ++ class ++ ", title:" ++ app.popout_title_regex ++ "\n");
        try w.writeAll("windowrulev2 = idleinhibit fullscreen, class:" ++ class ++ ", title:" ++ app.main_title_regex ++ "\n");
    }
    return w.buffered();
}

/// Raven opens Open/Save/Export dialogs with zenity, or kdialog on KDE
/// (vendor/raven/zig/src/widgets/dialogs.zig); without either they can't open.
pub fn fileDialogCheck(d: desktop.Desktop, zenity: bool, kdialog: bool) Check {
    var c = Check.make(.file_dialog, .ok, "File dialogs");
    if (!zenity and !kdialog) {
        c.status = .warn;
        c.detail.set("Neither zenity nor kdialog is installed, so Open, Save and Export dialogs can't open.");
        c.hint.set(if (d == .kde) "Install kdialog (or zenity)." else "Install zenity (or kdialog on KDE).");
        return c;
    }
    const used: []const u8 = if (kdialog and (d == .kde or !zenity)) "kdialog" else "zenity";
    c.detail.print("{s} opens file dialogs", .{used});
    return c;
}

pub fn gnomeSuspendCheck(ac_type: []const u8) Check {
    var c = Check.make(.gnome_suspend, .ok, "GNOME automatic suspend");
    if (std.mem.eql(u8, ac_type, "nothing")) {
        c.detail.set("Off while plugged in");
        return c;
    }
    c.status = .info;
    c.detail.print("On AC power GNOME will '{s}' when idle", .{ac_type});
    c.hint.set("Seridian Studio does not inhibit idle, so a long recording without input can be suspended. To turn it off: gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'");
    return c;
}

// ===========================================================================
// Fixes
// ===========================================================================

/// What `applyFix` did, for printing (paths can be long).
pub const FixMessage = Text(1024);

pub const FixError = error{
    /// HOME is unset, relative or `/`.
    MissingHome,
    /// The target resolved outside $HOME (e.g. XDG_CONFIG_HOME elsewhere).
    OutsideHome,
    NoHyprlandConfig,
    /// The seridian-studio binary was not found for the desktop entry.
    StudioNotFound,
    UnsupportedFix,
    NoSpaceLeft,
};

/// Apply `fix`, writing only under $HOME. On success `msg` lists every file
/// written and every user-session command run; on failure the error says why.
pub fn applyFix(scratch: std.mem.Allocator, env: anytype, fix: FixId, opts: Options, msg: *FixMessage) !void {
    var dirs: XdgDirs = undefined;
    dirs.init(env);
    const home = dirs.home orelse return error.MissingHome;
    switch (fix) {
        .none => return error.UnsupportedFix,
        .desktop_entry => {
            const exe = opts.studio_exe orelse return error.StudioNotFound;
            const data_home = dirs.data_home orelse return error.MissingHome;
            var text_buf: [2048]u8 = undefined;
            const text = desktopEntry(&text_buf, exe) catch return error.NoSpaceLeft;
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&dir_buf, "{s}/applications", .{data_home});
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/" ++ app.desktop_file, .{dir});
            try requireUnderHome(home, path);
            try sys.makePath(dir);
            try sys.writeFileAtomic(path, text);
            msg.print("Wrote {s} (Exec={s})", .{ path, exe });
            if (sys.runSucceeds(&.{ "update-desktop-database", dir })) _ = msg.append("; ran update-desktop-database {s}", .{dir});
        },
        .hyprland_rules => {
            const info = desktop.detect(env);
            var conf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const conf_path = hyprConfigPath(env, &dirs, &conf_path_buf) orelse return error.NoHyprlandConfig;
            try requireUnderHome(home, conf_path);
            const conf = sys.readFileAlloc(scratch, conf_path, max_config_bytes) catch return error.NoHyprlandConfig;
            defer scratch.free(conf);

            var argv_buf: [8][]const u8 = undefined;
            const version: ?Version = if (runTool(scratch, hyprctlArgv(&info, &.{ "version", "-j" }, &argv_buf))) |out| blk: {
                defer scratch.free(out);
                break :blk parseHyprVersion(out);
            } else null;
            var rules_buf: [2048]u8 = undefined;
            const rules = hyprlandRules(&rules_buf, version) catch return error.NoSpaceLeft;

            const dir = std.fs.path.dirname(conf_path) orelse return error.NoHyprlandConfig;
            var rules_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rules_path = try std.fmt.bufPrint(&rules_path_buf, "{s}/" ++ app.hypr_rules_file, .{dir});
            try requireUnderHome(home, rules_path);
            try sys.writeFileAtomic(rules_path, rules);

            if (!hyprConfigHasRules(conf)) {
                var backup_buf: [std.fs.max_path_bytes]u8 = undefined;
                const backup = try std.fmt.bufPrint(&backup_buf, "{s}.seridian-backup-{d}", .{ conf_path, sys.timestamp() });
                try sys.writeFileAtomic(backup, conf);
                const sep: []const u8 = if (conf.len > 0 and conf[conf.len - 1] != '\n') "\n" else "";
                const new_conf = try std.fmt.allocPrint(scratch, "{s}{s}\n# Seridian Studio window rules (seridian doctor --fix hyprland-rules)\nsource = {s}\n", .{ conf, sep, rules_path });
                defer scratch.free(new_conf);
                try sys.writeFileAtomic(conf_path, new_conf);
                msg.print("Wrote {s}; appended a source line to {s} (backup: {s})", .{ rules_path, conf_path, backup });
            } else {
                msg.print("Wrote {s} (already sourced from {s})", .{ rules_path, conf_path });
            }
            if (sys.runSucceeds(hyprctlArgv(&info, &.{"reload"}, &argv_buf))) {
                _ = msg.append("; ran hyprctl reload", .{});
            } else {
                _ = msg.append("; hyprctl reload failed, rules apply on the next reload", .{});
            }
        },
        .pipewire_clock => {
            const config_home = dirs.config_home orelse return error.MissingHome;
            var text_buf: [1024]u8 = undefined;
            const text = pipewireDropIn(&text_buf, opts.sample_rate, opts.buffer_size) catch return error.NoSpaceLeft;
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&dir_buf, "{s}/pipewire/pipewire.conf.d", .{config_home});
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/" ++ app.pipewire_drop_in, .{dir});
            try requireUnderHome(home, path);
            try sys.makePath(dir);
            try sys.writeFileAtomic(path, text);
            // Apply to the user's running graph too; the file covers restarts.
            var q_buf: [16]u8 = undefined;
            const q = try std.fmt.bufPrint(&q_buf, "{d}", .{minQuantumFor(opts.buffer_size)});
            const live_ok = sys.runSucceeds(&.{ "pw-metadata", "-n", "settings", "0", "clock.min-quantum", q });
            msg.print("Wrote {s}{s}", .{ path, if (live_ok) "; ran pw-metadata to apply it to the running PipeWire" else "; restart PipeWire to apply" });
        },
    }
}

/// Fails unless `path` is absolute, inside `home` and free of `..` parts.
pub fn requireUnderHome(home: []const u8, path: []const u8) FixError!void {
    if (!std.fs.path.isAbsolute(home) or std.mem.eql(u8, std.mem.trimEnd(u8, home, "/"), "")) return error.MissingHome;
    const base = std.mem.trimEnd(u8, home, "/");
    if (!std.fs.path.isAbsolute(path)) return error.OutsideHome;
    if (!std.mem.startsWith(u8, path, base) or path.len <= base.len or path[base.len] != '/') return error.OutsideHome;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.OutsideHome;
    }
}

// ===========================================================================
// Fact gathering helpers
// ===========================================================================

/// XDG locations. Initialized in place: the fallbacks point into the
/// struct's own buffers, so it must not be copied after `init`.
const XdgDirs = struct {
    home: ?[]const u8,
    runtime_dir: ?[]const u8,
    config_home: ?[]const u8,
    data_home: ?[]const u8,
    config_home_buf: [std.fs.max_path_bytes]u8,
    data_home_buf: [std.fs.max_path_bytes]u8,

    fn init(self: *XdgDirs, env: anytype) void {
        self.home = absoluteEnv(env, "HOME");
        self.runtime_dir = absoluteEnv(env, "XDG_RUNTIME_DIR");
        self.config_home = absoluteEnv(env, "XDG_CONFIG_HOME");
        self.data_home = absoluteEnv(env, "XDG_DATA_HOME");
        if (self.config_home == null) if (self.home) |h| {
            self.config_home = std.fmt.bufPrint(&self.config_home_buf, "{s}/.config", .{h}) catch null;
        };
        if (self.data_home == null) if (self.home) |h| {
            self.data_home = std.fmt.bufPrint(&self.data_home_buf, "{s}/.local/share", .{h}) catch null;
        };
    }
};

/// The XDG spec says relative values are invalid and must be ignored.
fn absoluteEnv(env: anytype, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len > 0 and std.fs.path.isAbsolute(v)) v else null;
}

fn hyprConfigPath(env: anytype, dirs: *const XdgDirs, buf: []u8) ?[]const u8 {
    if (absoluteEnv(env, "HYPRLAND_CONFIG")) |p| return p;
    const ch = dirs.config_home orelse return null;
    const p = std.fmt.bufPrint(buf, "{s}/hypr/hyprland.conf", .{ch}) catch return null;
    return if (fileExists(p)) p else null;
}

/// hyprctl argv in `storage`, adding `--instance` when the signature was
/// found through the runtime socket instead of the environment.
fn hyprctlArgv(info: *const desktop.Info, args: []const []const u8, storage: *[8][]const u8) []const []const u8 {
    var n: usize = 0;
    storage[n] = "hyprctl";
    n += 1;
    if (info.hypr_signature_from_socket) {
        storage[n] = "--instance";
        storage[n + 1] = info.hypr_signature.slice();
        n += 2;
    }
    for (args) |a| {
        if (n == storage.len) break;
        storage[n] = a;
        n += 1;
    }
    return storage[0..n];
}

/// Run a short-lived tool with a 3 s limit (through the wm layer's silent
/// `capture`). Null when it is missing, fails or times out: each is a reason
/// to skip the check, not an error.
fn runTool(scratch: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var full: [12][]const u8 = undefined;
    var n: usize = 0;
    if (fileExists("/usr/bin/timeout") or fileExists("/bin/timeout")) {
        full[0] = "timeout";
        full[1] = "3";
        n = 2;
    }
    for (argv) |a| {
        if (n == full.len) break;
        full[n] = a;
        n += 1;
    }
    const result = wm_types.capture(scratch, full[0..n]) catch return null;
    if (!result.ok()) {
        result.deinit(scratch);
        return null;
    }
    return result.out;
}

fn groupsText(scratch: std.mem.Allocator) Text(80) {
    var t: Text(80) = .{};
    const out = runTool(scratch, &.{ "id", "-Gn" }) orelse return t;
    defer scratch.free(out);
    var it = std.mem.tokenizeAny(u8, out, " \n");
    while (it.next()) |g| {
        const relevant = std.mem.eql(u8, g, "audio") or std.mem.eql(u8, g, "realtime") or std.mem.eql(u8, g, "pipewire") or std.mem.eql(u8, g, "rtkit");
        if (!relevant) continue;
        const ok = if (t.len > 0) t.append(", {s}", .{g}) else t.append("{s}", .{g});
        if (!ok) break;
    }
    return t;
}

fn rlimitCur(resource: std.posix.rlimit_resource) ?u64 {
    const r = std.posix.getrlimit(resource) catch return null;
    return r.cur;
}

fn fileExists(path: []const u8) bool {
    return (desktop.FsProbe{}).exists(path);
}

fn accessRw(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(sys.io(), path, .{ .read = true, .write = true }) catch return false;
    return true;
}

fn trimLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Read a small file into `buf`. Streams instead of trusting stat sizes,
/// which are 0 for procfs/sysfs files. Null when it can't be read.
fn readSmall(path: []const u8, buf: []u8) ?[]u8 {
    var f = std.Io.Dir.cwd().openFile(sys.io(), path, .{}) catch return null;
    defer f.close(sys.io());
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.readStreaming(sys.io(), &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// Running processes the checks care about (one pass over /proc).
const ProcSet = struct {
    const Name = enum { rtkit, pipewire, pipewire_pulse, pulseaudio, wireplumber, pipewire_media_session };
    bits: std.EnumSet(Name) = .empty,

    fn has(self: ProcSet, n: Name) bool {
        return self.bits.contains(n);
    }

    fn scan() ProcSet {
        var set: ProcSet = .{};
        var dir = std.Io.Dir.openDirAbsolute(sys.io(), "/proc", .{ .iterate = true }) catch return set;
        defer dir.close(sys.io());
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(sys.io()) catch return set) orelse return set;
            if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/cmdline", .{entry.name}) catch continue;
            var buf: [256]u8 = undefined;
            const cmd = readSmall(path, &buf) orelse continue;
            set.addCmdline(cmd);
        }
    }

    /// Record the process whose NUL-separated command line is `cmd`.
    fn addCmdline(self: *ProcSet, cmd: []const u8) void {
        const arg0 = std.mem.sliceTo(cmd, 0);
        const base = std.fs.path.basename(arg0);
        const table = [_]struct { []const u8, Name }{
            .{ "rtkit-daemon", .rtkit },
            .{ "pipewire", .pipewire },
            .{ "pipewire-pulse", .pipewire_pulse },
            .{ "pulseaudio", .pulseaudio },
            .{ "wireplumber", .wireplumber },
            .{ "pipewire-media-session", .pipewire_media_session },
        };
        for (table) |e| if (std.mem.eql(u8, base, e[0])) self.bits.insert(e[1]);
        // pipewire-pulse is often `pipewire -c pipewire-pulse.conf`.
        if (std.mem.eql(u8, base, "pipewire") and std.mem.indexOf(u8, cmd, "pipewire-pulse.conf") != null) self.bits.insert(.pipewire_pulse);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Environment for tests: a fixed list of variables.
const TestEnv = struct {
    vars: []const [2][]const u8 = &.{},

    pub fn get(self: *const TestEnv, name: []const u8) ?[]const u8 {
        for (self.vars) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
};

test "parsePwSettings reads the clock" {
    const out =
        \\Found "settings" metadata 31
        \\update: id:0 key:'log.level' value:'2' type:''
        \\update: id:0 key:'clock.rate' value:'48000' type:''
        \\update: id:0 key:'clock.allowed-rates' value:'[ 44100, 48000 ]' type:''
        \\update: id:0 key:'clock.quantum' value:'1024' type:''
        \\update: id:0 key:'clock.min-quantum' value:'32' type:''
        \\update: id:0 key:'clock.max-quantum' value:'2048' type:''
        \\update: id:0 key:'clock.force-quantum' value:'0' type:''
        \\update: id:0 key:'clock.force-rate' value:'0' type:''
    ;
    const c = parsePwSettings(out).?;
    try testing.expectEqual(@as(u32, 48000), c.rate);
    try testing.expectEqual(@as(u32, 32), c.min_quantum);
    try testing.expectEqual(@as(u32, 2048), c.max_quantum);
    try testing.expectEqual(@as(usize, 2), c.allowed_len);
    try testing.expect(c.allows(44100));
    try testing.expect(!c.allows(96000));
    try testing.expect(parsePwSettings("garbage") == null);
}

test "PipeWire clock evaluation" {
    var clock: PwClock = .{ .rate = 48000, .min_quantum = 32, .max_quantum = 2048 };
    clock.allowed_rates[0] = 48000;
    clock.allowed_len = 1;

    const good = pipewireClockCheck(clock, .{ .sample_rate = 48000, .buffer_size = 256 });
    try testing.expectEqual(Status.ok, good.status);
    try testing.expect(std.mem.indexOf(u8, good.detail.slice(), "256-frame quantum (5.3 ms") != null);

    clock.min_quantum = 1024;
    const floor = pipewireClockCheck(clock, .{ .sample_rate = 48000, .buffer_size = 256 });
    try testing.expectEqual(Status.warn, floor.status);
    try testing.expectEqual(FixId.pipewire_clock, floor.fix);
    try testing.expectEqual(@as(u32, 1024), effectiveQuantum(clock, 256));

    clock.min_quantum = 32;
    const resample = pipewireClockCheck(clock, .{ .sample_rate = 44100, .buffer_size = 256 });
    try testing.expectEqual(Status.warn, resample.status);

    clock.force_quantum = 128;
    const forced = pipewireClockCheck(clock, .{ .sample_rate = 48000, .buffer_size = 256 });
    try testing.expectEqual(Status.info, forced.status);
    try testing.expectEqual(@as(u32, 128), effectiveQuantum(clock, 256));

    try testing.expectEqual(Status.info, pipewireClockCheck(null, .{}).status);
}

test "pipewireDropIn and minQuantumFor" {
    try testing.expectEqual(@as(u32, 256), minQuantumFor(256));
    try testing.expectEqual(@as(u32, 256), minQuantumFor(300));
    try testing.expectEqual(@as(u32, 32), minQuantumFor(32));
    try testing.expectEqual(@as(u32, 16), minQuantumFor(16));
    var buf: [512]u8 = undefined;
    const text = try pipewireDropIn(&buf, 44100, 128);
    try testing.expect(std.mem.indexOf(u8, text, "allowed-rates = [ 44100 48000 88200 96000 ]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min-quantum = 128") != null);
    const odd = try pipewireDropIn(&buf, 32000, 512);
    try testing.expect(std.mem.indexOf(u8, odd, "[ 32000 44100 48000 88200 96000 ]") != null);
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.WriteFailed, pipewireDropIn(&tiny, 48000, 256));
}

test "audio server evaluation" {
    try testing.expectEqual(Status.fail, audioServerCheck(.{}, .{}).status);
    const full: AudioServers = .{ .pipewire_socket = true, .pulse_socket = true, .pipewire_pulse = true, .session_manager = true };
    const ok = audioServerCheck(full, .{ .active_backend = "pipewire" });
    try testing.expectEqual(Status.ok, ok.status);
    try testing.expectEqualStrings("PipeWire with pipewire-pulse; app output: pipewire", ok.detail.slice());
    try testing.expectEqual(Status.fail, audioServerCheck(full, .{ .active_backend = "none" }).status);
    var no_wp = full;
    no_wp.session_manager = false;
    try testing.expectEqual(Status.warn, audioServerCheck(no_wp, .{}).status);
    try testing.expectEqualStrings("PulseAudio only", audioServerCheck(.{ .pulse_socket = true, .pulseaudio = true }, .{}).detail.slice());
}

test "kernel preemption classification" {
    const dyn = "#1 SMP PREEMPT_DYNAMIC Sat Oct  3 14:00:02 -00 2026\n";
    try testing.expectEqual(Preempt.dynamic_unknown, parsePreempt(dyn, "root=/dev/sda1", null, false));
    try testing.expectEqual(Preempt.dynamic_full, parsePreempt(dyn, "root=x preempt=full threadirqs", null, false));
    try testing.expectEqual(Preempt.dynamic_voluntary, parsePreempt(dyn, "", "none (voluntary) full lazy", false));
    try testing.expectEqual(Preempt.rt, parsePreempt("#1 SMP PREEMPT_RT Mon", "", null, false));
    try testing.expectEqual(Preempt.rt, parsePreempt(dyn, "", null, true));
    try testing.expectEqual(Preempt.full, parsePreempt("#1 SMP PREEMPT Mon Jan 1", "", null, false));
    try testing.expectEqual(Preempt.none, parsePreempt("#1 SMP Mon Jan 1", "", null, false));
    try testing.expect(cmdlineHas("a threadirqs b", "threadirqs"));
    try testing.expect(!cmdlineHas("a threadirqsx b", "threadirqs"));

    const k = kernelCheck(dyn, "preempt=full threadirqs", null, false);
    try testing.expectEqual(Status.ok, k.status);
    try testing.expectEqualStrings("Dynamic preemption, full mode, threaded IRQs", k.detail.slice());
    try testing.expectEqual(Status.info, kernelCheck(dyn, "", null, false).status);
}

test "CPU governor evaluation" {
    try testing.expectEqual(Status.ok, governorCheck("acpi-cpufreq", "performance", null).status);
    try testing.expectEqual(Status.info, governorCheck("acpi-cpufreq", "schedutil", null).status);
    try testing.expectEqual(Status.warn, governorCheck("acpi-cpufreq", "powersave", null).status);
    try testing.expectEqual(Status.ok, governorCheck("amd-pstate-epp", "powersave", "balance_performance").status);
    const power = governorCheck("intel_pstate", "powersave", "power");
    try testing.expectEqual(Status.warn, power.status);
    // Changing the power profile is system-wide, so it is a hint, not a fix.
    try testing.expectEqual(FixId.none, power.fix);
    try testing.expect(std.mem.indexOf(u8, power.hint.slice(), "powerprofilesctl set performance") != null);
}

test "power profile evaluation" {
    try testing.expectEqual(Status.ok, powerProfileCheck(.{ .source = .ppd, .name = .init("performance") }).status);
    const bal = powerProfileCheck(.{ .source = .ppd, .name = .init("balanced") });
    try testing.expectEqual(Status.info, bal.status);
    try testing.expectEqual(FixId.none, bal.fix);
    try testing.expect(std.mem.indexOf(u8, bal.hint.slice(), "powerprofilesctl set performance") != null);
    try testing.expectEqual(Status.warn, powerProfileCheck(.{ .source = .ppd, .name = .init("power-saver") }).status);
    const tuned = powerProfileCheck(.{ .source = .tuned, .name = .init("powersave") });
    try testing.expectEqual(Status.warn, tuned.status);
    try testing.expectEqual(FixId.none, tuned.fix);
    try testing.expectEqualStrings("balanced", parseTunedActive("Current active profile: balanced\n").?);
    try testing.expect(parseTunedActive("No current active profile.") == null);
}

test "realtime and memlock evaluation" {
    const ok = realtimeCheck(95, false, "audio, pipewire");
    try testing.expectEqual(Status.ok, ok.status);
    try testing.expectEqualStrings("Realtime priority allowed (rtprio limit 95); groups: audio, pipewire", ok.detail.slice());
    try testing.expectEqual(Status.info, realtimeCheck(0, true, "").status);
    try testing.expectEqual(Status.warn, realtimeCheck(0, false, "").status);
    try testing.expectEqual(Status.warn, realtimeCheck(null, false, "").status);
    try testing.expectEqual(Status.ok, memlockCheck(std.math.maxInt(u64)).status);
    try testing.expectEqual(Status.info, memlockCheck(8 << 20).status);
    try testing.expectEqual(Status.ok, memlockCheck(1 << 30).status);
    try testing.expectEqual(Status.info, memlockCheck(null).status);
}

test "sound device and MIDI evaluation" {
    try testing.expectEqual(Status.warn, soundDevicesCheck(.{}).status);
    try testing.expectEqual(Status.warn, soundDevicesCheck(.{ .cards = 2 }).status);
    try testing.expectEqual(Status.ok, soundDevicesCheck(.{ .cards = 2, .accessible = 2 }).status);
    try testing.expectEqual(Status.ok, midiCheck(true, true).status);
    try testing.expectEqual(Status.warn, midiCheck(true, false).status);
    try testing.expectEqual(Status.info, midiCheck(false, false).status);
}

test "desktop entry uses the seridian-studio binary and window class" {
    var buf: [2048]u8 = undefined;
    const text = try desktopEntry(&buf, "/opt/my \"studio\"/bin/seridian-studio");
    try testing.expect(std.mem.indexOf(u8, text, "Exec=\"/opt/my \\\"studio\\\"/bin/seridian-studio\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Name=Seridian Studio\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "StartupWMClass=seridian-studio\n") != null);
    try testing.expect(desktopEntryOk(text));
    try testing.expect(!desktopEntryOk("[Desktop Entry]\nName=Seridian Studio\n"));
    try testing.expect(!desktopEntryOk("StartupWMClass=daw\n"));
    try testing.expect(!desktopEntryOk("StartupWMClass=Raven\n"));
    // an entry written when the app still had Raven's default class
    try testing.expect(!desktopEntryOk("StartupWMClass=raven\n"));

    try testing.expectEqual(Status.warn, desktopEntryCheck(.kde, .missing).status);
    try testing.expectEqual(Status.info, desktopEntryCheck(.hyprland, .missing).status);
    try testing.expectEqual(FixId.desktop_entry, desktopEntryCheck(.gnome, .no_wm_class).fix);
    try testing.expectEqual(Status.ok, desktopEntryCheck(.gnome, .ok).status);
}

test "Hyprland version, config detection and rules" {
    const v = parseHyprVersion("{\"branch\": \"v0.56.2\", \"commit\": \"efb5\", \"tag\": \"v0.56.2\", \"commits\": \"7661\"}").?;
    try testing.expectEqual(Version{ .major = 0, .minor = 56, .patch = 2 }, v);
    try testing.expect(v.atLeast(0, 53));
    try testing.expect(!(Version{ .major = 0, .minor = 52, .patch = 9 }).atLeast(0, 53));
    try testing.expectEqual(Version{ .major = 0, .minor = 41, .patch = 2 }, parseHyprVersion("{\"tag\": \"v0.41.2-24-g3a2d\"}").?);
    try testing.expect(parseHyprVersion("{}") == null);

    try testing.expect(hyprConfigHasRules("source = ~/.config/hypr/seridian-studio.conf\n"));
    try testing.expect(hyprConfigHasRules("windowrule = match:class ^(seridian-studio)$, float true"));
    try testing.expect(!hyprConfigHasRules("windowrule = match:class ^(raven)$, float true"));
    try testing.expect(!hyprConfigHasRules("# source = ~/.config/hypr/seridian-studio.conf\nwindowrule = match:class ^(wofi)$, float true\n"));
    try testing.expect(!hyprConfigHasRules("source = ~/.config/hypr/daw.conf\n"));

    const missing = hyprlandRulesCheck("exec-once = waybar\n", null, v);
    try testing.expectEqual(Status.warn, missing.status);
    try testing.expectEqual(FixId.hyprland_rules, missing.fix);
    try testing.expectEqual(Status.ok, hyprlandRulesCheck("source = seridian-studio.conf", null, v).status);
    try testing.expectEqual(Status.info, hyprlandRulesCheck(null, null, v).status);
    // a sourced rules file from before the app had its own window class
    const stale = hyprlandRulesCheck("source = seridian-studio.conf", "windowrule = match:class ^(raven)$, match:title ^(Mixer)$, float true\n", v);
    try testing.expectEqual(Status.warn, stale.status);
    try testing.expectEqual(FixId.hyprland_rules, stale.fix);
    const current = hyprlandRulesCheck("source = seridian-studio.conf", "windowrule = match:class ^(seridian-studio)$, match:title ^(Mixer)$, float true\n", v);
    try testing.expectEqual(Status.ok, current.status);

    var buf: [2048]u8 = undefined;
    const modern = try hyprlandRules(&buf, v);
    try testing.expect(std.mem.indexOf(u8, modern, "windowrule = match:class ^(seridian-studio)$, match:title ^(Mixer|Piano Roll - .*)$, float true\n") != null);
    try testing.expect(std.mem.indexOf(u8, modern, "windowrule = match:class ^(seridian-studio)$, match:title ^(Seridian Studio.*)$, idle_inhibit fullscreen\n") != null);
    try testing.expect(hyprRulesMatchClass(modern));
    try testing.expect(std.mem.indexOf(u8, modern, "windowrulev2") == null);
    try testing.expect(hyprConfigHasRules(modern));
    var buf2: [2048]u8 = undefined;
    const legacy = try hyprlandRules(&buf2, .{ .major = 0, .minor = 45, .patch = 0 });
    try testing.expect(std.mem.indexOf(u8, legacy, "windowrulev2 = float, class:^(seridian-studio)$, title:^(Mixer|Piano Roll - .*)$\n") != null);
    try testing.expect(hyprRulesMatchClass(legacy));
    try testing.expect(hyprConfigHasRules(legacy));
}

test "file dialog and GNOME suspend evaluation" {
    try testing.expectEqual(Status.warn, fileDialogCheck(.kde, false, false).status);
    try testing.expectEqualStrings("kdialog opens file dialogs", fileDialogCheck(.kde, true, true).detail.slice());
    try testing.expectEqualStrings("zenity opens file dialogs", fileDialogCheck(.hyprland, true, true).detail.slice());
    try testing.expectEqualStrings("kdialog opens file dialogs", fileDialogCheck(.gnome, false, true).detail.slice());
    try testing.expectEqual(Status.ok, fileDialogCheck(.gnome, true, false).status);
    try testing.expectEqual(Status.ok, gnomeSuspendCheck("nothing").status);
    try testing.expectEqual(Status.info, gnomeSuspendCheck("suspend").status);
}

test "session row" {
    var info: desktop.Info = .{ .desktop = .hyprland, .session = .wayland };
    const c = sessionCheck(info, "0.56.2");
    try testing.expectEqual(Status.ok, c.status);
    try testing.expectEqualStrings("Hyprland 0.56.2 on Wayland", c.detail.slice());
    info.hypr_signature_from_socket = true;
    try testing.expectEqual(Status.info, sessionCheck(info, "").status);
    try testing.expectEqual(Status.info, sessionCheck(.{ .desktop = .unknown, .session = .tty }, "").status);
    try testing.expectEqual(Status.info, sessionCheck(.{ .desktop = .gnome, .session = .x11, .wayland_socket = true }, "").status);
}

test "Status, FixId and Report helpers" {
    try testing.expectEqual(Status.warn, Status.info.max(.warn));
    try testing.expectEqual(Status.fail, Status.fail.max(.ok));
    try testing.expectEqualStrings("FAIL", Status.fail.label());

    try testing.expectEqual(FixId.hyprland_rules, FixId.parse("hyprland-rules").?);
    try testing.expectEqual(FixId.desktop_entry, FixId.parse("desktop_entry").?);
    try testing.expectEqual(FixId.pipewire_clock, FixId.parse("pipewire-clock").?);
    try testing.expect(FixId.parse("none") == null);
    try testing.expect(FixId.parse("") == null);
    try testing.expect(FixId.parse("power-performance") == null);
    try testing.expectEqualStrings("Install the desktop entry", FixId.desktop_entry.describe());

    var r: Report = .{ .info = .{ .desktop = .unknown, .session = .tty } };
    try testing.expectEqual(Status.ok, r.worst());
    r.add(Check.make(.midi, .info, "a"));
    r.add(Check.make(.realtime, .warn, "b"));
    try testing.expectEqual(Status.warn, r.worst());
    for (0..max_checks + 3) |_| r.add(Check.make(.midi, .ok, "x"));
    try testing.expectEqual(@as(usize, max_checks), r.len);
}

test "requireUnderHome only allows paths inside HOME" {
    try requireUnderHome("/home/u", "/home/u/.config/hypr/seridian-studio.conf");
    try requireUnderHome("/home/u/", "/home/u/.local/share/applications/seridian-studio.desktop");
    try testing.expectError(error.OutsideHome, requireUnderHome("/home/u", "/home/user2/x"));
    try testing.expectError(error.OutsideHome, requireUnderHome("/home/u", "/etc/pipewire/x.conf"));
    try testing.expectError(error.OutsideHome, requireUnderHome("/home/u", "/home/u/../v/x"));
    try testing.expectError(error.OutsideHome, requireUnderHome("/home/u", "/home/u"));
    try testing.expectError(error.OutsideHome, requireUnderHome("/home/u", "relative/x"));
    try testing.expectError(error.MissingHome, requireUnderHome("/", "/x"));
    try testing.expectError(error.MissingHome, requireUnderHome("home", "/home/x"));
}

test "XdgDirs falls back to HOME and ignores relative values" {
    const env: TestEnv = .{ .vars = &.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "relative" }, .{ "XDG_DATA_HOME", "/data" } } };
    var dirs: XdgDirs = undefined;
    dirs.init(&env);
    try testing.expectEqualStrings("/home/u/.config", dirs.config_home.?);
    try testing.expectEqualStrings("/data", dirs.data_home.?);
    try testing.expect(dirs.runtime_dir == null);
}

test "applyFix refuses to write outside HOME or without one" {
    var msg: FixMessage = .{};
    const no_home: TestEnv = .{};
    try testing.expectError(error.MissingHome, applyFix(testing.allocator, &no_home, .pipewire_clock, .{}, &msg));
    const elsewhere: TestEnv = .{ .vars = &.{ .{ "HOME", "/home/nobody-seridian-test" }, .{ "XDG_CONFIG_HOME", "/etc" }, .{ "XDG_DATA_HOME", "/usr/share" } } };
    try testing.expectError(error.OutsideHome, applyFix(testing.allocator, &elsewhere, .pipewire_clock, .{}, &msg));
    try testing.expectError(error.OutsideHome, applyFix(testing.allocator, &elsewhere, .desktop_entry, .{ .studio_exe = "/usr/bin/seridian-studio" }, &msg));
    try testing.expectError(error.StudioNotFound, applyFix(testing.allocator, &elsewhere, .desktop_entry, .{}, &msg));
    try testing.expectError(error.UnsupportedFix, applyFix(testing.allocator, &elsewhere, .none, .{}, &msg));
    try testing.expectEqual(@as(usize, 0), msg.len);
}

test "ProcSet recognizes audio daemons from their command lines" {
    var set: ProcSet = .{};
    set.addCmdline("/usr/bin/wireplumber\x00");
    set.addCmdline("/usr/bin/pipewire\x00-c\x00pipewire-pulse.conf\x00");
    set.addCmdline("/usr/libexec/rtkit-daemon\x00");
    try testing.expect(set.has(.wireplumber));
    try testing.expect(set.has(.pipewire));
    try testing.expect(set.has(.pipewire_pulse));
    try testing.expect(set.has(.rtkit));
    try testing.expect(!set.has(.pulseaudio));
}

test "hyprctlArgv adds --instance for a socket-found signature" {
    var info: desktop.Info = .{ .desktop = .hyprland, .session = .wayland };
    var storage: [8][]const u8 = undefined;
    const plain = hyprctlArgv(&info, &.{ "version", "-j" }, &storage);
    try testing.expectEqual(@as(usize, 3), plain.len);
    info.hypr_signature.set("sig");
    info.hypr_signature_from_socket = true;
    const inst = hyprctlArgv(&info, &.{"reload"}, &storage);
    try testing.expectEqualStrings("--instance", inst[1]);
    try testing.expectEqualStrings("sig", inst[2]);
    try testing.expectEqualStrings("reload", inst[3]);
}

test "readSmall reads procfs and reports missing files" {
    var buf: [64]u8 = undefined;
    if (builtin.os.tag == .linux) try testing.expect(readSmall("/proc/self/cmdline", &buf) != null);
    try testing.expect(readSmall("/nonexistent-seridian-preflight-file", &buf) == null);
    try testing.expectEqualStrings("x", trimLine(" x\n"));
}

test "run gathers a report on this machine without failing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = run(arena.allocator(), desktop.ProcessEnv{}, .{});
    try testing.expect(r.len > 0);
    try testing.expectEqual(CheckId.desktop_session, r.items()[0].id);
}
