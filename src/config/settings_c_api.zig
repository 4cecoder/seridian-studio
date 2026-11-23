/// C API for settings persistence
/// Allows GTK UI to save/load settings via INI file
const std = @import("std");
const settings = @import("settings.zig");
const persistence = @import("persistence.zig");

const log = std.log.scoped(.settings_api);

// Global settings instance (singleton pattern for C interop)
var g_settings: settings.Settings = settings.Settings.default();
var g_allocator: ?std.mem.Allocator = null;
var g_initialized: bool = false;

/// Initialize the settings system
export fn settings_init() callconv(.c) c_int {
    if (g_initialized) return 0;

    // Use the general purpose allocator
    g_allocator = std.heap.c_allocator;

    // Try to load from disk
    g_settings = persistence.loadSettings(g_allocator.?) catch |err| {
        log.warn("Failed to load settings: {}, using defaults", .{err});
        return 0; // Still OK, just using defaults
    };

    g_initialized = true;
    log.info("Settings initialized", .{});
    return 0;
}

/// Save current settings to disk
export fn settings_save() callconv(.c) c_int {
    if (!g_initialized or g_allocator == null) {
        log.err("Settings not initialized", .{});
        return -1;
    }

    persistence.saveSettings(g_allocator.?, &g_settings) catch |err| {
        log.err("Failed to save settings: {}", .{err});
        return -1;
    };

    log.info("Settings saved", .{});
    return 0;
}

/// Reload settings from disk
export fn settings_reload() callconv(.c) c_int {
    if (g_allocator == null) {
        g_allocator = std.heap.c_allocator;
    }

    g_settings = persistence.loadSettings(g_allocator.?) catch |err| {
        log.warn("Failed to reload settings: {}, keeping current", .{err});
        return -1;
    };

    g_initialized = true;
    log.info("Settings reloaded", .{});
    return 0;
}

// =============================================================================
// Audio settings getters/setters
// =============================================================================

export fn settings_get_audio_backend() callconv(.c) c_int {
    return @backingInt(g_settings.audio.backend);
}

export fn settings_set_audio_backend(backend: c_int) callconv(.c) void {
    g_settings.audio.backend = switch (backend) {
        0 => .auto,
        1 => .pulseaudio,
        2 => .pipewire,
        else => .auto,
    };
}

export fn settings_get_sample_rate() callconv(.c) c_uint {
    return @backingInt(g_settings.audio.sample_rate);
}

export fn settings_set_sample_rate(rate: c_uint) callconv(.c) void {
    g_settings.audio.sample_rate = settings.SampleRate.fromInt(rate) orelse .@"48000";
}

export fn settings_get_buffer_size() callconv(.c) c_uint {
    return @backingInt(g_settings.audio.buffer_size);
}

export fn settings_set_buffer_size(size: c_uint) callconv(.c) void {
    g_settings.audio.buffer_size = settings.BufferSize.fromInt(size) orelse .@"512";
}

// =============================================================================
// Display settings getters/setters
// =============================================================================

export fn settings_get_display_backend() callconv(.c) c_int {
    return @backingInt(g_settings.display.backend);
}

export fn settings_set_display_backend(backend: c_int) callconv(.c) void {
    g_settings.display.backend = switch (backend) {
        0 => .auto,
        1 => .x11,
        2 => .wayland,
        else => .auto,
    };
}

export fn settings_get_window_scale() callconv(.c) f32 {
    return g_settings.display.window_scale;
}

export fn settings_set_window_scale(scale: f32) callconv(.c) void {
    if (scale >= 0.5 and scale <= 2.0) {
        g_settings.display.window_scale = scale;
    }
}

export fn settings_get_fullscreen_mode() callconv(.c) c_int {
    return switch (g_settings.display.fullscreen_mode) {
        .borderless => 0,
        .exclusive => 1,
    };
}

export fn settings_set_fullscreen_mode(mode: c_int) callconv(.c) void {
    g_settings.display.fullscreen_mode = if (mode == 1) .exclusive else .borderless;
}

// =============================================================================
// Graphics settings getters/setters
// =============================================================================

export fn settings_get_graphics_renderer() callconv(.c) c_int {
    return @backingInt(g_settings.graphics.renderer);
}

export fn settings_set_graphics_renderer(renderer: c_int) callconv(.c) void {
    g_settings.graphics.renderer = switch (renderer) {
        0 => .auto,
        1 => .cairo,
        2 => .gl,
        3 => .vulkan,
        else => .auto,
    };
}

export fn settings_get_vsync() callconv(.c) c_int {
    return if (g_settings.graphics.vsync) 1 else 0;
}

export fn settings_set_vsync(enabled: c_int) callconv(.c) void {
    g_settings.graphics.vsync = enabled != 0;
}

export fn settings_get_max_fps() callconv(.c) c_uint {
    return g_settings.graphics.max_fps;
}

export fn settings_set_max_fps(fps: c_uint) callconv(.c) void {
    if (fps >= 30 and fps <= 144) {
        g_settings.graphics.max_fps = fps;
    }
}

// =============================================================================
// Performance settings getters/setters
// =============================================================================

export fn settings_get_redraw_strategy() callconv(.c) c_int {
    return switch (g_settings.performance.redraw_strategy) {
        .always => 0,
        .smart => 1,
        .minimal => 2,
    };
}

export fn settings_set_redraw_strategy(strategy: c_int) callconv(.c) void {
    g_settings.performance.redraw_strategy = switch (strategy) {
        0 => .always,
        1 => .smart,
        2 => .minimal,
        else => .smart,
    };
}

export fn settings_get_enable_culling() callconv(.c) c_int {
    return if (g_settings.performance.enable_culling) 1 else 0;
}

export fn settings_set_enable_culling(enabled: c_int) callconv(.c) void {
    g_settings.performance.enable_culling = enabled != 0;
}

export fn settings_get_enable_batching() callconv(.c) c_int {
    return if (g_settings.performance.enable_batching) 1 else 0;
}

export fn settings_set_enable_batching(enabled: c_int) callconv(.c) void {
    g_settings.performance.enable_batching = enabled != 0;
}

export fn settings_get_audio_thread_count() callconv(.c) c_uint {
    return g_settings.performance.audio_thread_count;
}

export fn settings_set_audio_thread_count(count: c_uint) callconv(.c) void {
    if (count >= 1 and count <= 8) {
        g_settings.performance.audio_thread_count = @intCast(count);
    }
}

// =============================================================================
// Appearance settings getters/setters
// =============================================================================

export fn settings_get_theme() callconv(.c) c_int {
    return @backingInt(g_settings.appearance.theme);
}

export fn settings_set_theme(theme: c_int) callconv(.c) void {
    g_settings.appearance.theme = switch (theme) {
        0 => .tokyo_night,
        1 => .tokyo_night_storm,
        2 => .tokyo_night_light,
        3 => .custom,
        else => .tokyo_night,
    };
}

export fn settings_get_ui_scale() callconv(.c) f32 {
    return g_settings.appearance.ui_scale;
}

export fn settings_set_ui_scale(scale: f32) callconv(.c) void {
    if (scale >= 0.5 and scale <= 2.0) {
        g_settings.appearance.ui_scale = scale;
    }
}

export fn settings_get_font_size() callconv(.c) c_uint {
    return g_settings.appearance.font_size;
}

export fn settings_set_font_size(size: c_uint) callconv(.c) void {
    if (size >= 8 and size <= 24) {
        g_settings.appearance.font_size = @intCast(size);
    }
}

// =============================================================================
// Project settings getters/setters
// =============================================================================

export fn settings_get_default_bpm() callconv(.c) f32 {
    return g_settings.project.default_bpm;
}

export fn settings_set_default_bpm(bpm: f32) callconv(.c) void {
    if (bpm >= 40.0 and bpm <= 300.0) {
        g_settings.project.default_bpm = bpm;
    }
}

export fn settings_get_default_time_sig_num() callconv(.c) c_uint {
    return g_settings.project.default_time_sig_num;
}

export fn settings_set_default_time_sig_num(num: c_uint) callconv(.c) void {
    if (num >= 1 and num <= 16) {
        g_settings.project.default_time_sig_num = @intCast(num);
    }
}

export fn settings_get_default_time_sig_den() callconv(.c) c_uint {
    return g_settings.project.default_time_sig_den;
}

export fn settings_set_default_time_sig_den(den: c_uint) callconv(.c) void {
    if (den >= 1 and den <= 16) {
        g_settings.project.default_time_sig_den = @intCast(den);
    }
}

export fn settings_get_auto_save_interval() callconv(.c) c_uint {
    return g_settings.project.auto_save_interval_sec;
}

export fn settings_set_auto_save_interval(seconds: c_uint) callconv(.c) void {
    if (seconds <= 3600) {
        g_settings.project.auto_save_interval_sec = seconds;
    }
}

// =============================================================================
// Advanced settings getters/setters
// =============================================================================

export fn settings_get_debug_mode() callconv(.c) c_int {
    return if (g_settings.advanced.debug_mode) 1 else 0;
}

export fn settings_set_debug_mode(enabled: c_int) callconv(.c) void {
    g_settings.advanced.debug_mode = enabled != 0;
}

export fn settings_get_log_level() callconv(.c) c_int {
    return @backingInt(g_settings.advanced.log_level);
}

export fn settings_set_log_level(level: c_int) callconv(.c) void {
    g_settings.advanced.log_level = switch (level) {
        0 => .debug,
        1 => .info,
        2 => .warn,
        3 => .err,
        else => .info,
    };
}

export fn settings_get_show_performance_overlay() callconv(.c) c_int {
    return if (g_settings.advanced.show_performance_overlay) 1 else 0;
}

export fn settings_set_show_performance_overlay(enabled: c_int) callconv(.c) void {
    g_settings.advanced.show_performance_overlay = enabled != 0;
}
