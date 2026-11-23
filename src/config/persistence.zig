/// Settings persistence layer - INI format save/load
/// Based on Ghostty patterns and XDG compliance
const std = @import("std");
const sys = @import("../utils/sys.zig");
const settings = @import("settings.zig");
const xdg = @import("xdg.zig");
const posix = std.posix;

const log = std.log.scoped(.persistence);

/// Fixed buffer writer for INI generation
const FixedBufferWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeAll(self: *FixedBufferWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn print(self: *FixedBufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const written = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += written.len;
    }

    fn getWritten(self: *const FixedBufferWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// Get config file path (XDG compliant)
pub fn getConfigFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = try xdg.getConfigDir(allocator);
    defer allocator.free(config_dir);

    // One product root for everything the DAW writes: <config>/seridian/daw/
    const seridian_dir = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "seridian" });
    defer allocator.free(seridian_dir);
    const daw_dir = try std.fs.path.join(allocator, &[_][]const u8{ seridian_dir, "daw" });
    defer allocator.free(daw_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ daw_dir, "settings.conf" });
}

/// Save settings to INI file
pub fn saveSettings(allocator: std.mem.Allocator, s: *const settings.Settings) !void {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    // Ensure directory exists
    const dir_path = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    try sys.makePath(dir_path);

    // Generate INI content
    var content_buf: [8192]u8 = undefined;
    var writer = FixedBufferWriter{ .buf = &content_buf };
    writeIniFixed(&writer, s) catch |err| {
        log.err("Failed to generate INI content: {}", .{err});
        return err;
    };

    // Write to file
    const file = try std.Io.Dir.cwd().createFile(sys.io(), config_path, .{});
    defer file.close(sys.io());
    try file.writeStreamingAll(sys.io(), writer.getWritten());

    log.info("Settings saved to: {s}", .{config_path});
}

/// Load settings from INI file
pub fn loadSettings(allocator: std.mem.Allocator) !settings.Settings {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    const file = std.Io.Dir.cwd().openFile(sys.io(), config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.info("Config file not found, using defaults: {s}", .{config_path});
            return settings.Settings.default();
        }
        return err;
    };
    defer file.close(sys.io());

    // Get file size and read
    const stat = try file.stat(sys.io());
    const file_size = @min(stat.size, 8192);

    var content_buf: [8192]u8 = undefined;
    const bytes_read = try file.readPositionalAll(sys.io(), &content_buf, 0);
    const content = content_buf[0..@min(bytes_read, file_size)];

    var result = settings.Settings.default();
    try parseIni(&result, content);
    try result.validate();

    log.info("Settings loaded from: {s}", .{config_path});
    return result;
}

/// Write settings to INI format using fixed buffer writer
fn writeIniFixed(writer: *FixedBufferWriter, s: *const settings.Settings) !void {
    try writer.writeAll("# DAW Settings\n");
    try writer.writeAll("# Auto-generated configuration file\n\n");

    // Audio section
    try writer.writeAll("[Audio]\n");
    try writer.print("backend = {s}\n", .{s.audio.backend.toString()});
    try writer.print("sample_rate = {d}\n", .{@backingInt(s.audio.sample_rate)});
    try writer.print("buffer_size = {d}\n\n", .{@backingInt(s.audio.buffer_size)});

    // Display section
    try writer.writeAll("[Display]\n");
    try writer.print("backend = {s}\n", .{s.display.backend.toString()});
    try writer.print("fullscreen_mode = {s}\n", .{@tagName(s.display.fullscreen_mode)});
    try writer.print("window_scale = {d:.2}\n\n", .{s.display.window_scale});

    // Graphics section
    try writer.writeAll("[Graphics]\n");
    try writer.print("renderer = {s}\n", .{s.graphics.renderer.toString()});
    try writer.print("vsync = {}\n", .{s.graphics.vsync});
    try writer.print("max_fps = {d}\n\n", .{s.graphics.max_fps});

    // Performance section
    try writer.writeAll("[Performance]\n");
    try writer.print("redraw_strategy = {s}\n", .{@tagName(s.performance.redraw_strategy)});
    try writer.print("enable_culling = {}\n", .{s.performance.enable_culling});
    try writer.print("enable_batching = {}\n", .{s.performance.enable_batching});
    try writer.print("audio_thread_count = {d}\n\n", .{s.performance.audio_thread_count});

    // Appearance section
    try writer.writeAll("[Appearance]\n");
    try writer.print("theme = {s}\n", .{s.appearance.theme.toString()});
    try writer.print("ui_scale = {d:.2}\n", .{s.appearance.ui_scale});
    try writer.print("font_size = {d}\n\n", .{s.appearance.font_size});

    // Project section
    try writer.writeAll("[Project]\n");
    try writer.print("default_bpm = {d:.1}\n", .{s.project.default_bpm});
    try writer.print("default_time_sig_num = {d}\n", .{s.project.default_time_sig_num});
    try writer.print("default_time_sig_den = {d}\n", .{s.project.default_time_sig_den});
    try writer.print("auto_save_interval_sec = {d}\n\n", .{s.project.auto_save_interval_sec});

    // Advanced section
    try writer.writeAll("[Advanced]\n");
    try writer.print("debug_mode = {}\n", .{s.advanced.debug_mode});
    try writer.print("log_level = {s}\n", .{s.advanced.log_level.toString()});
    try writer.print("show_performance_overlay = {}\n", .{s.advanced.show_performance_overlay});
}

/// Parse INI file content
fn parseIni(result: *settings.Settings, content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_section: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            current_section = trimmed[1 .. trimmed.len - 1];
            continue;
        }

        // Key-value pair
        var kv = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, kv.next() orelse continue, " \t");
        const value = std.mem.trim(u8, kv.next() orelse "", " \t");

        if (current_section) |section| {
            try parseKeyValue(result, section, key, value);
        }
    }
}

/// Parse individual key-value pair
fn parseKeyValue(result: *settings.Settings, section: []const u8, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, section, "Audio")) {
        if (std.mem.eql(u8, key, "backend")) {
            result.audio.backend = settings.AudioBackend.fromString(value) orelse .auto;
        } else if (std.mem.eql(u8, key, "sample_rate")) {
            const rate = try std.fmt.parseInt(u32, value, 10);
            result.audio.sample_rate = settings.SampleRate.fromInt(rate) orelse .@"48000";
        } else if (std.mem.eql(u8, key, "buffer_size")) {
            const size = try std.fmt.parseInt(u32, value, 10);
            result.audio.buffer_size = settings.BufferSize.fromInt(size) orelse .@"512";
        }
    } else if (std.mem.eql(u8, section, "Display")) {
        if (std.mem.eql(u8, key, "backend")) {
            result.display.backend = settings.DisplayBackend.fromString(value) orelse .auto;
        } else if (std.mem.eql(u8, key, "window_scale")) {
            result.display.window_scale = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "fullscreen_mode")) {
            if (std.mem.eql(u8, value, "exclusive")) {
                result.display.fullscreen_mode = .exclusive;
            } else {
                result.display.fullscreen_mode = .borderless;
            }
        }
    } else if (std.mem.eql(u8, section, "Graphics")) {
        if (std.mem.eql(u8, key, "renderer")) {
            result.graphics.renderer = settings.GraphicsRenderer.fromString(value) orelse .gl;
        } else if (std.mem.eql(u8, key, "vsync")) {
            result.graphics.vsync = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "max_fps")) {
            result.graphics.max_fps = try std.fmt.parseInt(u32, value, 10);
        }
    } else if (std.mem.eql(u8, section, "Performance")) {
        if (std.mem.eql(u8, key, "redraw_strategy")) {
            if (std.mem.eql(u8, value, "always")) {
                result.performance.redraw_strategy = .always;
            } else if (std.mem.eql(u8, value, "minimal")) {
                result.performance.redraw_strategy = .minimal;
            } else {
                result.performance.redraw_strategy = .smart;
            }
        } else if (std.mem.eql(u8, key, "enable_culling")) {
            result.performance.enable_culling = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "enable_batching")) {
            result.performance.enable_batching = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "audio_thread_count")) {
            result.performance.audio_thread_count = try std.fmt.parseInt(u8, value, 10);
        }
    } else if (std.mem.eql(u8, section, "Appearance")) {
        if (std.mem.eql(u8, key, "theme")) {
            result.appearance.theme = settings.Theme.fromString(value) orelse .tokyo_night;
        } else if (std.mem.eql(u8, key, "ui_scale")) {
            result.appearance.ui_scale = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "font_size")) {
            result.appearance.font_size = try std.fmt.parseInt(u8, value, 10);
        }
    } else if (std.mem.eql(u8, section, "Project")) {
        if (std.mem.eql(u8, key, "default_bpm")) {
            result.project.default_bpm = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, key, "default_time_sig_num")) {
            result.project.default_time_sig_num = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "default_time_sig_den")) {
            result.project.default_time_sig_den = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, key, "auto_save_interval_sec")) {
            result.project.auto_save_interval_sec = try std.fmt.parseInt(u32, value, 10);
        }
    } else if (std.mem.eql(u8, section, "Advanced")) {
        if (std.mem.eql(u8, key, "debug_mode")) {
            result.advanced.debug_mode = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "log_level")) {
            result.advanced.log_level = settings.LogLevel.fromString(value) orelse .info;
        } else if (std.mem.eql(u8, key, "show_performance_overlay")) {
            result.advanced.show_performance_overlay = std.mem.eql(u8, value, "true");
        }
    }
}

test "save and load settings" {
    var s = settings.Settings.default();
    s.audio.backend = .pipewire;
    s.audio.sample_rate = .@"96000";
    s.project.default_bpm = 140.0;

    // Generate INI using fixed buffer writer
    var buffer: [8192]u8 = undefined;
    var writer = FixedBufferWriter{ .buf = &buffer };
    try writeIniFixed(&writer, &s);
    const content = writer.getWritten();

    // Parse it back
    var loaded = settings.Settings.default();
    try parseIni(&loaded, content);

    try std.testing.expectEqual(settings.AudioBackend.pipewire, loaded.audio.backend);
    try std.testing.expectEqual(settings.SampleRate.@"96000", loaded.audio.sample_rate);
    try std.testing.expectApproxEqRel(@as(f32, 140.0), loaded.project.default_bpm, 0.01);
}
