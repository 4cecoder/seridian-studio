const std = @import("std");
const xdg = @import("xdg.zig");

const log = std.log.scoped(.config);

pub const AudioConfig = struct {
    backend: []const u8 = "auto",
    sample_rate: u32 = 48000,
    buffer_size: u32 = 128,
    input_device: []const u8 = "",
    output_device: []const u8 = "",
};

pub const ProjectConfig = struct {
    default_sample_rate: u32 = 48000,
    default_bit_depth: u8 = 24,
    auto_save_interval: u32 = 300,
    recent_projects_count: u8 = 10,
    default_project_dir: []const u8 = "~/Music/DAW Projects",
};

pub const UIConfig = struct {
    theme: []const u8 = "dark",
    show_grid: bool = true,
    snap_enabled: bool = true,
    snap_mode: []const u8 = "bar",
    meter_decay_rate: f32 = 0.95,
};

pub const Config = struct {
    audio: AudioConfig = .{},
    project: ProjectConfig = .{},
    ui: UIConfig = .{},

    pub fn default() Config {
        return Config{};
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        _ = allocator;

        // For MVP, just use defaults
        // In a full implementation, we would:
        // 1. Get config path via XDG
        // 2. Try to read and parse TOML file
        // 3. Fall back to defaults if missing

        log.info("Using default configuration", .{});
        return Config.default();
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Nothing to free for now since we're using string literals
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
        // Stub for now
        log.info("Config save (stub)", .{});
    }
};

test "config defaults" {
    const config = Config.default();
    try std.testing.expectEqual(@as(u32, 48000), config.audio.sample_rate);
    try std.testing.expectEqual(@as(u32, 128), config.audio.buffer_size);
}
