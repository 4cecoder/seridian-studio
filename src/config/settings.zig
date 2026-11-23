/// Comprehensive settings system for DAW
/// Based on patterns from Ghostty, Changies, and AAA game config systems
const std = @import("std");

/// All settings categories (matches UI sidebar)
pub const SettingsCategory = enum {
    audio,
    display,
    graphics,
    midi,
    performance,
    appearance,
    project,
    file_folders,
    plugins,
    advanced,

    pub fn displayName(self: SettingsCategory) []const u8 {
        return switch (self) {
            .audio => "Audio",
            .display => "Display",
            .graphics => "Graphics",
            .midi => "MIDI",
            .performance => "Performance",
            .appearance => "Appearance",
            .project => "Project",
            .file_folders => "File/Folders",
            .plugins => "Plugins",
            .advanced => "Advanced",
        };
    }

    pub fn icon(self: SettingsCategory) []const u8 {
        return switch (self) {
            .audio => "🔊",
            .display => "🖥️",
            .graphics => "🎨",
            .midi => "🎹",
            .performance => "⚡",
            .appearance => "🌈",
            .project => "📁",
            .file_folders => "📂",
            .plugins => "🔌",
            .advanced => "⚙️",
        };
    }
};

/// Audio backend selection
pub const AudioBackend = enum {
    auto,
    pulseaudio,
    pipewire,

    pub fn toString(self: AudioBackend) []const u8 {
        return switch (self) {
            .auto => "auto",
            .pulseaudio => "pulseaudio",
            .pipewire => "pipewire",
        };
    }

    pub fn fromString(s: []const u8) ?AudioBackend {
        const map = std.StaticStringMap(AudioBackend).initComptime(.{
            .{ "auto", .auto },
            .{ "pulseaudio", .pulseaudio },
            .{ "pipewire", .pipewire },
        });
        return map.get(s);
    }
};

/// Sample rate options
pub const SampleRate = enum(u32) {
    @"44100" = 44100,
    @"48000" = 48000,
    @"88200" = 88200,
    @"96000" = 96000,
    @"192000" = 192000,

    pub fn fromInt(i: u32) ?SampleRate {
        return switch (i) {
            44100 => .@"44100",
            48000 => .@"48000",
            88200 => .@"88200",
            96000 => .@"96000",
            192000 => .@"192000",
            else => null,
        };
    }
};

/// Buffer size options
pub const BufferSize = enum(u32) {
    @"128" = 128,
    @"256" = 256,
    @"512" = 512,
    @"1024" = 1024,
    @"2048" = 2048,

    pub fn fromInt(i: u32) ?BufferSize {
        return switch (i) {
            128 => .@"128",
            256 => .@"256",
            512 => .@"512",
            1024 => .@"1024",
            2048 => .@"2048",
            else => null,
        };
    }
};

/// Audio settings
pub const AudioSettings = struct {
    backend: AudioBackend = .auto,
    sample_rate: SampleRate = .@"48000",
    buffer_size: BufferSize = .@"512",
    input_device: []const u8 = "",
    output_device: []const u8 = "",

    pub fn validate(self: *const AudioSettings) !void {
        _ = self;
        // All enum values are valid by definition
        // String fields can be empty (means default)
    }
};

/// Display backend
pub const DisplayBackend = enum {
    auto,
    x11,
    wayland,

    pub fn toString(self: DisplayBackend) []const u8 {
        return switch (self) {
            .auto => "auto",
            .x11 => "x11",
            .wayland => "wayland",
        };
    }

    pub fn fromString(s: []const u8) ?DisplayBackend {
        const map = std.StaticStringMap(DisplayBackend).initComptime(.{
            .{ "auto", .auto },
            .{ "x11", .x11 },
            .{ "wayland", .wayland },
        });
        return map.get(s);
    }
};

/// Display settings
pub const DisplaySettings = struct {
    backend: DisplayBackend = .auto,
    fullscreen_mode: enum { borderless, exclusive } = .borderless,
    window_scale: f32 = 1.0,

    pub fn validate(self: *const DisplaySettings) !void {
        if (self.window_scale < 0.5 or self.window_scale > 2.0) {
            return error.InvalidWindowScale;
        }
    }
};

/// Graphics renderer
pub const GraphicsRenderer = enum {
    auto,
    cairo,
    gl,
    vulkan,

    pub fn toString(self: GraphicsRenderer) []const u8 {
        return switch (self) {
            .auto => "auto",
            .cairo => "cairo",
            .gl => "gl",
            .vulkan => "vulkan",
        };
    }

    pub fn fromString(s: []const u8) ?GraphicsRenderer {
        const map = std.StaticStringMap(GraphicsRenderer).initComptime(.{
            .{ "auto", .auto },
            .{ "cairo", .cairo },
            .{ "gl", .gl },
            .{ "vulkan", .vulkan },
        });
        return map.get(s);
    }
};

/// Graphics settings
pub const GraphicsSettings = struct {
    renderer: GraphicsRenderer = .gl,
    vsync: bool = true,
    max_fps: u32 = 60,

    pub fn validate(self: *const GraphicsSettings) !void {
        if (self.max_fps < 30 or self.max_fps > 144) {
            return error.InvalidMaxFPS;
        }
    }
};

/// Performance settings
pub const PerformanceSettings = struct {
    redraw_strategy: enum { always, smart, minimal } = .smart,
    enable_culling: bool = true,
    enable_batching: bool = true,
    audio_thread_count: u8 = 1,

    pub fn validate(self: *const PerformanceSettings) !void {
        if (self.audio_thread_count < 1 or self.audio_thread_count > 8) {
            return error.InvalidThreadCount;
        }
    }
};

/// Theme selection
pub const Theme = enum {
    tokyo_night,
    tokyo_night_storm,
    tokyo_night_light,
    custom,

    pub fn toString(self: Theme) []const u8 {
        return switch (self) {
            .tokyo_night => "tokyo_night",
            .tokyo_night_storm => "tokyo_night_storm",
            .tokyo_night_light => "tokyo_night_light",
            .custom => "custom",
        };
    }

    pub fn fromString(s: []const u8) ?Theme {
        const map = std.StaticStringMap(Theme).initComptime(.{
            .{ "tokyo_night", .tokyo_night },
            .{ "tokyo_night_storm", .tokyo_night_storm },
            .{ "tokyo_night_light", .tokyo_night_light },
            .{ "custom", .custom },
        });
        return map.get(s);
    }
};

/// Appearance settings
pub const AppearanceSettings = struct {
    theme: Theme = .tokyo_night,
    ui_scale: f32 = 1.0,
    font_size: u8 = 10,

    pub fn validate(self: *const AppearanceSettings) !void {
        if (self.ui_scale < 0.5 or self.ui_scale > 2.0) {
            return error.InvalidUIScale;
        }
        if (self.font_size < 8 or self.font_size > 24) {
            return error.InvalidFontSize;
        }
    }
};

/// Project defaults
pub const ProjectSettings = struct {
    default_bpm: f32 = 120.0,
    default_time_sig_num: u8 = 4,
    default_time_sig_den: u8 = 4,
    auto_save_interval_sec: u32 = 300,

    pub fn validate(self: *const ProjectSettings) !void {
        if (self.default_bpm < 40.0 or self.default_bpm > 300.0) {
            return error.InvalidBPM;
        }
        if (self.default_time_sig_num < 1 or self.default_time_sig_num > 16) {
            return error.InvalidTimeSigNumerator;
        }
        if (self.default_time_sig_den < 1 or self.default_time_sig_den > 16) {
            return error.InvalidTimeSigDenominator;
        }
        if (self.auto_save_interval_sec > 3600) {
            return error.InvalidAutoSaveInterval;
        }
    }
};

/// Log level for advanced settings
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "err",
        };
    }

    pub fn fromString(s: []const u8) ?LogLevel {
        const map = std.StaticStringMap(LogLevel).initComptime(.{
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "err", .err },
        });
        return map.get(s);
    }
};

/// Advanced settings
pub const AdvancedSettings = struct {
    debug_mode: bool = false,
    log_level: LogLevel = .info,
    show_performance_overlay: bool = false,

    pub fn validate(self: *const AdvancedSettings) !void {
        _ = self;
        // All values valid
    }
};

/// Complete settings structure
pub const Settings = struct {
    audio: AudioSettings = .{},
    display: DisplaySettings = .{},
    graphics: GraphicsSettings = .{},
    performance: PerformanceSettings = .{},
    appearance: AppearanceSettings = .{},
    project: ProjectSettings = .{},
    advanced: AdvancedSettings = .{},

    /// Create default settings
    pub fn default() Settings {
        return Settings{};
    }

    /// Validate all settings
    pub fn validate(self: *const Settings) !void {
        try self.audio.validate();
        try self.display.validate();
        try self.graphics.validate();
        try self.performance.validate();
        try self.appearance.validate();
        try self.project.validate();
        try self.advanced.validate();
    }

    /// Check if category requires restart when changed
    pub fn requiresRestart(category: SettingsCategory) bool {
        return switch (category) {
            .audio => true,
            .display => true,
            .graphics => true,
            .appearance => false, // Live preview
            .performance => false,
            .project => false,
            .file_folders => false,
            .plugins => false,
            .midi => false,
            .advanced => false,
        };
    }
};

test "settings validation" {
    var settings = Settings.default();
    try settings.validate();

    // Test invalid BPM
    settings.project.default_bpm = 500.0;
    try std.testing.expectError(error.InvalidBPM, settings.validate());

    // Reset to valid
    settings.project.default_bpm = 120.0;
    try settings.validate();
}

test "enum from string" {
    try std.testing.expectEqual(AudioBackend.auto, AudioBackend.fromString("auto").?);
    try std.testing.expectEqual(AudioBackend.pipewire, AudioBackend.fromString("pipewire").?);
    try std.testing.expectEqual(@as(?AudioBackend, null), AudioBackend.fromString("invalid"));
}
