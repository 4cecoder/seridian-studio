/// Settings modal Zig wrapper - integrates GTK C implementation with Zig settings system
/// Provides type-safe interface for settings UI, manages state, and handles persistence
const std = @import("std");
const settings = @import("../../config/settings.zig");
const persistence = @import("../../config/persistence.zig");

const log = std.log.scoped(.settings_modal);

// Opaque pointers to GTK types (implementation in C)
const SettingsModalC = opaque {};
pub const GtkWindow = opaque {};

// External C functions from settings_modal_gtk.c (to be implemented)
extern fn settings_modal_new(parent: ?*GtkWindow) ?*SettingsModalC;
extern fn settings_modal_show(modal: *SettingsModalC) void;
extern fn settings_modal_destroy(modal: *SettingsModalC) void;
extern fn settings_modal_set_callbacks(
    modal: *SettingsModalC,
    user_data: ?*anyopaque,
    on_apply: *const fn (?*anyopaque) callconv(.c) void,
    on_cancel: *const fn (?*anyopaque) callconv(.c) void,
) void;

// Update GTK UI from Zig settings
extern fn settings_modal_update_audio_backend(modal: *SettingsModalC, backend: c_int) void;
extern fn settings_modal_update_sample_rate(modal: *SettingsModalC, rate: u32) void;
extern fn settings_modal_update_buffer_size(modal: *SettingsModalC, size: u32) void;
extern fn settings_modal_update_display_backend(modal: *SettingsModalC, backend: c_int) void;
extern fn settings_modal_update_fullscreen_mode(modal: *SettingsModalC, mode: c_int) void;
extern fn settings_modal_update_window_scale(modal: *SettingsModalC, scale: f32) void;
extern fn settings_modal_update_graphics_renderer(modal: *SettingsModalC, renderer: c_int) void;
extern fn settings_modal_update_vsync(modal: *SettingsModalC, enabled: c_int) void;
extern fn settings_modal_update_max_fps(modal: *SettingsModalC, fps: u32) void;
extern fn settings_modal_update_redraw_strategy(modal: *SettingsModalC, strategy: c_int) void;
extern fn settings_modal_update_enable_culling(modal: *SettingsModalC, enabled: c_int) void;
extern fn settings_modal_update_enable_batching(modal: *SettingsModalC, enabled: c_int) void;
extern fn settings_modal_update_audio_thread_count(modal: *SettingsModalC, count: u8) void;
extern fn settings_modal_update_theme(modal: *SettingsModalC, theme: c_int) void;
extern fn settings_modal_update_ui_scale(modal: *SettingsModalC, scale: f32) void;
extern fn settings_modal_update_font_size(modal: *SettingsModalC, size: u8) void;
extern fn settings_modal_update_default_bpm(modal: *SettingsModalC, bpm: f32) void;
extern fn settings_modal_update_default_time_sig(modal: *SettingsModalC, num: u8, den: u8) void;
extern fn settings_modal_update_auto_save_interval(modal: *SettingsModalC, seconds: u32) void;
extern fn settings_modal_update_debug_mode(modal: *SettingsModalC, enabled: c_int) void;
extern fn settings_modal_update_log_level(modal: *SettingsModalC, level: c_int) void;
extern fn settings_modal_update_show_performance_overlay(modal: *SettingsModalC, enabled: c_int) void;

/// Zig wrapper for settings modal
pub const SettingsModal = struct {
    allocator: std.mem.Allocator,
    modal_c: *SettingsModalC,
    settings_current: settings.Settings,
    settings_original: settings.Settings,

    /// Create new settings modal
    pub fn create(allocator: std.mem.Allocator, parent: ?*GtkWindow) !*SettingsModal {
        log.info("Creating settings modal", .{});

        // Load current settings from disk
        const current_settings = try persistence.loadSettings(allocator);

        // Create GTK modal
        const modal_c = settings_modal_new(parent) orelse {
            log.err("Failed to create settings modal GTK object", .{});
            return error.ModalCreationFailed;
        };

        // Allocate wrapper
        const modal = try allocator.create(SettingsModal);
        errdefer allocator.destroy(modal);

        modal.* = SettingsModal{
            .allocator = allocator,
            .modal_c = modal_c,
            .settings_current = current_settings,
            .settings_original = current_settings, // Save for cancel
        };

        // Set up callbacks (C will call back into Zig)
        settings_modal_set_callbacks(
            modal_c,
            modal,
            &onApplyCallback,
            &onCancelCallback,
        );

        // Initialize GTK UI with current settings
        modal.syncToGtk();

        return modal;
    }

    /// Show the settings modal
    pub fn show(self: *SettingsModal) void {
        log.info("Showing settings modal", .{});
        settings_modal_show(self.modal_c);
    }

    /// Destroy the settings modal
    pub fn destroy(self: *SettingsModal) void {
        log.info("Destroying settings modal", .{});
        settings_modal_destroy(self.modal_c);
        self.allocator.destroy(self);
    }

    /// Apply settings (save to disk)
    pub fn onApply(self: *SettingsModal) void {
        log.info("Applying settings", .{});

        // Validate current settings
        self.settings_current.validate() catch |err| {
            log.err("Settings validation failed: {}", .{err});
            return;
        };

        // Save to disk
        persistence.saveSettings(self.allocator, &self.settings_current) catch |err| {
            log.err("Failed to save settings: {}", .{err});
            return;
        };

        // Update original (so cancel works from this point forward)
        self.settings_original = self.settings_current;

        log.info("Settings applied successfully", .{});
    }

    /// Cancel settings (revert to original)
    pub fn onCancel(self: *SettingsModal) void {
        log.info("Canceling settings changes", .{});

        // Revert to original
        self.settings_current = self.settings_original;

        // Sync GTK UI back to original values
        self.syncToGtk();
    }

    /// Sync Zig settings to GTK UI
    fn syncToGtk(self: *SettingsModal) void {
        // Audio settings
        settings_modal_update_audio_backend(self.modal_c, @backingInt(self.settings_current.audio.backend));
        settings_modal_update_sample_rate(self.modal_c, @backingInt(self.settings_current.audio.sample_rate));
        settings_modal_update_buffer_size(self.modal_c, @backingInt(self.settings_current.audio.buffer_size));

        // Display settings
        settings_modal_update_display_backend(self.modal_c, @backingInt(self.settings_current.display.backend));
        settings_modal_update_fullscreen_mode(self.modal_c, @backingInt(self.settings_current.display.fullscreen_mode));
        settings_modal_update_window_scale(self.modal_c, self.settings_current.display.window_scale);

        // Graphics settings
        settings_modal_update_graphics_renderer(self.modal_c, @backingInt(self.settings_current.graphics.renderer));
        settings_modal_update_vsync(self.modal_c, if (self.settings_current.graphics.vsync) 1 else 0);
        settings_modal_update_max_fps(self.modal_c, self.settings_current.graphics.max_fps);

        // Performance settings
        settings_modal_update_redraw_strategy(self.modal_c, @backingInt(self.settings_current.performance.redraw_strategy));
        settings_modal_update_enable_culling(self.modal_c, if (self.settings_current.performance.enable_culling) 1 else 0);
        settings_modal_update_enable_batching(self.modal_c, if (self.settings_current.performance.enable_batching) 1 else 0);
        settings_modal_update_audio_thread_count(self.modal_c, self.settings_current.performance.audio_thread_count);

        // Appearance settings
        settings_modal_update_theme(self.modal_c, @backingInt(self.settings_current.appearance.theme));
        settings_modal_update_ui_scale(self.modal_c, self.settings_current.appearance.ui_scale);
        settings_modal_update_font_size(self.modal_c, self.settings_current.appearance.font_size);

        // Project settings
        settings_modal_update_default_bpm(self.modal_c, self.settings_current.project.default_bpm);
        settings_modal_update_default_time_sig(
            self.modal_c,
            self.settings_current.project.default_time_sig_num,
            self.settings_current.project.default_time_sig_den,
        );
        settings_modal_update_auto_save_interval(self.modal_c, self.settings_current.project.auto_save_interval_sec);

        // Advanced settings
        settings_modal_update_debug_mode(self.modal_c, if (self.settings_current.advanced.debug_mode) 1 else 0);
        settings_modal_update_log_level(self.modal_c, @backingInt(self.settings_current.advanced.log_level));
        settings_modal_update_show_performance_overlay(self.modal_c, if (self.settings_current.advanced.show_performance_overlay) 1 else 0);
    }
};

// ============================================================================
// C Callbacks (called from GTK when UI changes)
// ============================================================================

fn onApplyCallback(user_data: ?*anyopaque) callconv(.c) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.onApply();
}

fn onCancelCallback(user_data: ?*anyopaque) callconv(.c) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.onCancel();
}

// ============================================================================
// Exported C API for GTK callbacks (GTK updates Zig settings)
// ============================================================================

export fn settings_update_audio_backend(user_data: ?*anyopaque, backend: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.audio.backend = @fromBackingInt(@intCast(backend));
    log.debug("Audio backend updated: {s}", .{modal.settings_current.audio.backend.toString()});
}

export fn settings_update_sample_rate(user_data: ?*anyopaque, rate: u32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    if (settings.SampleRate.fromInt(rate)) |sr| {
        modal.settings_current.audio.sample_rate = sr;
        log.debug("Sample rate updated: {d}", .{rate});
    }
}

export fn settings_update_buffer_size(user_data: ?*anyopaque, size: u32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    if (settings.BufferSize.fromInt(size)) |bs| {
        modal.settings_current.audio.buffer_size = bs;
        log.debug("Buffer size updated: {d}", .{size});
    }
}

export fn settings_update_display_backend(user_data: ?*anyopaque, backend: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.display.backend = @fromBackingInt(@intCast(backend));
    log.debug("Display backend updated: {s}", .{modal.settings_current.display.backend.toString()});
}

export fn settings_update_fullscreen_mode(user_data: ?*anyopaque, mode: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.display.fullscreen_mode = if (mode == 1) .exclusive else .borderless;
    log.debug("Fullscreen mode updated: {s}", .{@tagName(modal.settings_current.display.fullscreen_mode)});
}

export fn settings_update_window_scale(user_data: ?*anyopaque, scale: f32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.display.window_scale = scale;
    log.debug("Window scale updated: {d:.2}", .{scale});
}

export fn settings_update_graphics_renderer(user_data: ?*anyopaque, renderer: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.graphics.renderer = @fromBackingInt(@intCast(renderer));
    log.debug("Graphics renderer updated: {s}", .{modal.settings_current.graphics.renderer.toString()});
}

export fn settings_update_vsync(user_data: ?*anyopaque, enabled: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.graphics.vsync = enabled != 0;
    log.debug("VSync updated: {}", .{modal.settings_current.graphics.vsync});
}

export fn settings_update_max_fps(user_data: ?*anyopaque, fps: u32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.graphics.max_fps = fps;
    log.debug("Max FPS updated: {d}", .{fps});
}

export fn settings_update_redraw_strategy(user_data: ?*anyopaque, strategy: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.performance.redraw_strategy = @fromBackingInt(@intCast(strategy));
    log.debug("Redraw strategy updated: {s}", .{@tagName(modal.settings_current.performance.redraw_strategy)});
}

export fn settings_update_enable_culling(user_data: ?*anyopaque, enabled: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.performance.enable_culling = enabled != 0;
    log.debug("Culling updated: {}", .{modal.settings_current.performance.enable_culling});
}

export fn settings_update_enable_batching(user_data: ?*anyopaque, enabled: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.performance.enable_batching = enabled != 0;
    log.debug("Batching updated: {}", .{modal.settings_current.performance.enable_batching});
}

export fn settings_update_audio_thread_count(user_data: ?*anyopaque, count: u8) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.performance.audio_thread_count = count;
    log.debug("Audio thread count updated: {d}", .{count});
}

export fn settings_update_theme(user_data: ?*anyopaque, theme: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.appearance.theme = @fromBackingInt(@intCast(theme));
    log.debug("Theme updated: {s}", .{modal.settings_current.appearance.theme.toString()});
}

export fn settings_update_ui_scale(user_data: ?*anyopaque, scale: f32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.appearance.ui_scale = scale;
    log.debug("UI scale updated: {d:.2}", .{scale});
}

export fn settings_update_font_size(user_data: ?*anyopaque, size: u8) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.appearance.font_size = size;
    log.debug("Font size updated: {d}", .{size});
}

export fn settings_update_default_bpm(user_data: ?*anyopaque, bpm: f32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.project.default_bpm = bpm;
    log.debug("Default BPM updated: {d:.1}", .{bpm});
}

export fn settings_update_default_time_sig(user_data: ?*anyopaque, num: u8, den: u8) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.project.default_time_sig_num = num;
    modal.settings_current.project.default_time_sig_den = den;
    log.debug("Default time signature updated: {d}/{d}", .{ num, den });
}

export fn settings_update_auto_save_interval(user_data: ?*anyopaque, seconds: u32) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.project.auto_save_interval_sec = seconds;
    log.debug("Auto-save interval updated: {d}s", .{seconds});
}

export fn settings_update_debug_mode(user_data: ?*anyopaque, enabled: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.advanced.debug_mode = enabled != 0;
    log.debug("Debug mode updated: {}", .{modal.settings_current.advanced.debug_mode});
}

export fn settings_update_log_level(user_data: ?*anyopaque, level: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.advanced.log_level = @fromBackingInt(@intCast(level));
    log.debug("Log level updated: {s}", .{modal.settings_current.advanced.log_level.toString()});
}

export fn settings_update_show_performance_overlay(user_data: ?*anyopaque, enabled: c_int) void {
    const modal: *SettingsModal = @ptrCast(@alignCast(user_data));
    modal.settings_current.advanced.show_performance_overlay = enabled != 0;
    log.debug("Performance overlay updated: {}", .{modal.settings_current.advanced.show_performance_overlay});
}
