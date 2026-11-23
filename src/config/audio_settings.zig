//! Persistence of the user's audio device selection across restarts.
//!
//! File: `$XDG_CONFIG_HOME/seridian/daw/audio.conf`, plain `key = value` lines. String values
//! (device names) are double-quoted with `\"` and `\\` escapes. A missing or corrupt file
//! yields the defaults; loading never fails because of file contents.

const std = @import("std");
const sys = @import("../utils/sys.zig");
const xdg = @import("xdg.zig");

const log = std.log.scoped(.audio_settings);

const default_sample_rate: u32 = 48000;
const default_buffer_size: u32 = 128;
/// Upper bound on the size of a settings file we are willing to read.
const max_file_bytes: usize = 64 * 1024;
/// Backend preferences the engine understands (see `audio_engine_set_backend`). "auto" is the default.
pub const backend_names = [_][]const u8{ "auto", "pulse", "pipewire", "none" };

pub const AudioSettings = struct {
    /// Output device name; "" means the system default.
    output_device: []const u8 = "",
    /// Input device name; "" means the system default.
    input_device: []const u8 = "",
    sample_rate: u32 = 48000,
    buffer_size: u32 = 128,
    /// Backend preference: one of `backend_names`. Static storage, not freed by `deinit`.
    backend: []const u8 = "auto",

    pub fn deinit(self: *AudioSettings, allocator: std.mem.Allocator) void {
        allocator.free(self.output_device);
        allocator.free(self.input_device);
        self.* = undefined;
    }
};

/// Path of the settings file: `$XDG_CONFIG_HOME/seridian/daw/audio.conf`, falling back to
/// `~/.config/seridian/daw/audio.conf` (caller frees).
pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try xdg.getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "seridian", "daw", "audio.conf" });
}

/// Appends `value` to `out` as a quoted string, escaping quotes, backslashes and line breaks.
fn appendQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Write `s` to `path`, creating parent directories. The file is written to a
/// temporary sibling and renamed over `path`, so a reader never sees a partial file.
pub fn saveTo(allocator: std.mem.Allocator, path: []const u8, s: AudioSettings) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# Seridian audio settings, written by the Settings dialog.\n");
    try out.appendSlice(allocator, "output_device = ");
    try appendQuoted(allocator, &out, s.output_device);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "input_device = ");
    try appendQuoted(allocator, &out, s.input_device);
    try out.append(allocator, '\n');
    const rate_line = try std.fmt.allocPrint(allocator, "sample_rate = {d}\n", .{s.sample_rate});
    defer allocator.free(rate_line);
    try out.appendSlice(allocator, rate_line);
    const buffer_line = try std.fmt.allocPrint(allocator, "buffer_size = {d}\n", .{s.buffer_size});
    defer allocator.free(buffer_line);
    try out.appendSlice(allocator, buffer_line);
    try out.appendSlice(allocator, "backend = ");
    try appendQuoted(allocator, &out, s.backend);
    try out.append(allocator, '\n');

    if (std.fs.path.dirname(path)) |dir| try sys.makePath(dir);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(sys.io(), .{ .sub_path = tmp_path, .data = out.items });
    std.Io.Dir.rename(cwd, tmp_path, cwd, path, sys.io()) catch |err| {
        cwd.deleteFile(sys.io(), tmp_path) catch |del_err| {
            log.warn("could not remove {s} after a failed save: {}", .{ tmp_path, del_err });
        };
        return err;
    };
}

const ParseError = error{ CorruptSettings, OutOfMemory };

/// Decodes a double-quoted value. Any other form, or an unknown escape, is corrupt.
fn parseQuoted(allocator: std.mem.Allocator, raw: []const u8) ParseError![]u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.CorruptSettings;
    const body = raw[1 .. raw.len - 1];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '"') return error.CorruptSettings;
        if (c != '\\') {
            try out.append(allocator, c);
            continue;
        }
        i += 1;
        if (i >= body.len) return error.CorruptSettings;
        const decoded: u8 = switch (body[i]) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            'r' => '\r',
            else => return error.CorruptSettings,
        };
        try out.append(allocator, decoded);
    }
    return out.toOwnedSlice(allocator);
}

/// Parses the whole file. Any malformed line makes the entire file corrupt.
fn parseContent(allocator: std.mem.Allocator, content: []const u8) ParseError!AudioSettings {
    var output = try allocator.dupe(u8, "");
    errdefer allocator.free(output);
    var input = try allocator.dupe(u8, "");
    errdefer allocator.free(input);
    var sample_rate: u32 = default_sample_rate;
    var buffer_size: u32 = default_buffer_size;
    var backend: []const u8 = "auto";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.CorruptSettings;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return error.CorruptSettings;

        if (std.mem.eql(u8, key, "output_device")) {
            const parsed = try parseQuoted(allocator, value);
            allocator.free(output);
            output = parsed;
        } else if (std.mem.eql(u8, key, "input_device")) {
            const parsed = try parseQuoted(allocator, value);
            allocator.free(input);
            input = parsed;
        } else if (std.mem.eql(u8, key, "sample_rate")) {
            sample_rate = std.fmt.parseInt(u32, value, 10) catch return error.CorruptSettings;
        } else if (std.mem.eql(u8, key, "buffer_size")) {
            buffer_size = std.fmt.parseInt(u32, value, 10) catch return error.CorruptSettings;
        } else if (std.mem.eql(u8, key, "backend")) {
            const parsed = try parseQuoted(allocator, value);
            defer allocator.free(parsed);
            backend = knownBackendOrAuto(parsed);
        }
        // Unknown keys are ignored so that newer files still load.
    }

    return .{
        .output_device = output,
        .input_device = input,
        .sample_rate = sample_rate,
        .buffer_size = buffer_size,
        .backend = backend,
    };
}

/// The static name in `backend_names` equal to `name`, or "auto" for anything unknown.
fn knownBackendOrAuto(name: []const u8) []const u8 {
    for (backend_names) |known| {
        if (std.mem.eql(u8, known, name)) return known;
    }
    log.warn("unknown audio backend '{s}' in settings, using auto", .{name});
    return "auto";
}

/// Read settings from `path`. Missing or corrupt file gives the defaults. Caller calls `deinit`.
pub fn loadFrom(allocator: std.mem.Allocator, path: []const u8) !AudioSettings {
    const content = sys.readFileAlloc(allocator, path, max_file_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err != error.FileNotFound) log.warn("cannot read {s}, using defaults: {}", .{ path, err });
        return defaultSettings(allocator);
    };
    defer allocator.free(content);

    return parseContent(allocator, content) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.CorruptSettings => {
            log.warn("ignoring corrupt audio settings in {s}, using defaults", .{path});
            return defaultSettings(allocator);
        },
    };
}

fn defaultSettings(allocator: std.mem.Allocator) !AudioSettings {
    return .{
        .output_device = try allocator.dupe(u8, ""),
        .input_device = try allocator.dupe(u8, ""),
    };
}

const test_dir = "/tmp/seridian-audio-settings-test";

fn testPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    try sys.makePath(test_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{d}.conf", .{ test_dir, name, sys.nanoTimestamp() });
    errdefer allocator.free(path);
    return path;
}

fn removeIfPresent(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(sys.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn expectSettings(want: AudioSettings, got: AudioSettings) !void {
    try std.testing.expectEqualStrings(want.output_device, got.output_device);
    try std.testing.expectEqualStrings(want.input_device, got.input_device);
    try std.testing.expectEqual(want.sample_rate, got.sample_rate);
    try std.testing.expectEqual(want.buffer_size, got.buffer_size);
    try std.testing.expectEqualStrings(want.backend, got.backend);
}

test "audio settings round-trip through a file" {
    const a = std.testing.allocator;
    const path = try testPath(a, "roundtrip");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const want: AudioSettings = .{
        .output_device = "alsa_output.usb-Focusrite_Scarlett_2i2-00.analog-stereo",
        .input_device = "",
        .sample_rate = 48000,
        .buffer_size = 256,
    };
    try saveTo(a, path, want);
    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try expectSettings(want, got);
}

test "audio settings: missing file loads defaults" {
    const a = std.testing.allocator;
    const path = try testPath(a, "missing");
    defer a.free(path);
    try removeIfPresent(path);

    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try expectSettings(.{}, got);
    try std.testing.expectEqualStrings("", got.output_device);
    try std.testing.expectEqual(@as(u32, 48000), got.sample_rate);
    try std.testing.expectEqual(@as(u32, 128), got.buffer_size);
}

test "audio settings: corrupt file loads defaults without crashing" {
    const a = std.testing.allocator;
    const path = try testPath(a, "corrupt");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    try sys.writeFileAtomic(path, "\x00\xff\xfe garbage\noutput_device = \"unterminated\nsample_rate = banana\nbuffer_size = -3\n=\n");
    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try expectSettings(.{}, got);
}

test "audio settings: device name with quotes and backslashes round-trips" {
    const a = std.testing.allocator;
    const path = try testPath(a, "escapes");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const want: AudioSettings = .{
        .output_device = "Studio \"Main\" Out\\Left = 1\\\"x",
        .input_device = "C:\\mic\\\"quoted\"",
        .sample_rate = 96000,
        .buffer_size = 128,
    };
    try saveTo(a, path, want);
    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try expectSettings(want, got);
}

test "audio settings: defaultPath is seridian/daw/audio.conf" {
    const a = std.testing.allocator;
    const path = try defaultPath(a);
    defer a.free(path);
    const suffix = try std.fs.path.join(a, &[_][]const u8{ "seridian", "daw", "audio.conf" });
    defer a.free(suffix);
    try std.testing.expect(std.mem.endsWith(u8, path, suffix));
}

test "audio settings: backend round-trips through a file" {
    const a = std.testing.allocator;
    const path = try testPath(a, "backend");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    const want: AudioSettings = .{ .backend = "pipewire" };
    try saveTo(a, path, want);
    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try std.testing.expectEqualStrings("pipewire", got.backend);
}

test "audio settings: unknown backend name in the file falls back to auto" {
    const a = std.testing.allocator;
    const path = try testPath(a, "unknown-backend");
    defer a.free(path);
    defer removeIfPresent(path) catch {};

    try sys.writeFileAtomic(path, "backend = \"jack\"\nsample_rate = 48000\n");
    var got = try loadFrom(a, path);
    defer got.deinit(a);
    try std.testing.expectEqualStrings("auto", got.backend);
}
