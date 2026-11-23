const std = @import("std");
const sys = @import("../utils/sys.zig");
const builtin = @import("builtin");

/// Get config directory path (platform-aware)
/// - macOS: ~/Library/Application Support
/// - Linux: $XDG_CONFIG_HOME or ~/.config
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    // Check for explicit XDG override (works on all platforms)
    if (sys.getenv("XDG_CONFIG_HOME")) |xdg_config| {
        return try allocator.dupe(u8, xdg_config);
    }

    const home = sys.getenv("HOME") orelse return error.NoHomeDirectory;

    if (builtin.os.tag == .macos) {
        // macOS convention: ~/Library/Application Support
        return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Application Support" });
    } else {
        // Linux/Unix convention: ~/.config
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
    }
}

/// Get data directory path (platform-aware)
/// - macOS: ~/Library/Application Support (same as config on macOS)
/// - Linux: $XDG_DATA_HOME or ~/.local/share
pub fn getDataDir(allocator: std.mem.Allocator) ![]const u8 {
    // Check for explicit XDG override
    if (sys.getenv("XDG_DATA_HOME")) |xdg_data| {
        return try allocator.dupe(u8, xdg_data);
    }

    const home = sys.getenv("HOME") orelse return error.NoHomeDirectory;

    if (builtin.os.tag == .macos) {
        // macOS convention: ~/Library/Application Support
        return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Application Support" });
    } else {
        // Linux/Unix convention: ~/.local/share
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share" });
    }
}

/// Get cache directory path (platform-aware)
/// - macOS: ~/Library/Caches
/// - Linux: $XDG_CACHE_HOME or ~/.cache
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (sys.getenv("XDG_CACHE_HOME")) |xdg_cache| {
        return try allocator.dupe(u8, xdg_cache);
    }

    const home = sys.getenv("HOME") orelse return error.NoHomeDirectory;

    if (builtin.os.tag == .macos) {
        return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Caches" });
    } else {
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache" });
    }
}

/// Get config file path for the application
pub fn getConfigPath(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ config_dir, app_name });
}

/// Get data directory path for the application
pub fn getDataPath(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    const data_dir = try getDataDir(allocator);
    defer allocator.free(data_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ data_dir, app_name });
}

test "xdg paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Just test that functions don't crash
    const config_path = getConfigPath(allocator, "test") catch |err| switch (err) {
        error.NoHomeDirectory => return, // OK in test environment
        else => return err,
    };
    defer allocator.free(config_path);
}
