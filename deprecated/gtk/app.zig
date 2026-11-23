const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.ui_app);

// External C functions from GTK4
extern fn gtk_init() void;

// C library setenv for environment variables
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;

// External C functions from GLib
const GMainLoop = opaque {};
extern fn g_main_loop_new(context: ?*anyopaque, is_running: c_int) ?*GMainLoop;
extern fn g_main_loop_run(loop: *GMainLoop) void;
extern fn g_main_loop_quit(loop: *GMainLoop) void;

// External C functions from main_window_gtk.c
const MainWindow = opaque {};
extern fn daw_load_theme() void;
extern fn main_window_new(loop: *GMainLoop, engine: ?*anyopaque) ?*MainWindow;
extern fn main_window_show(win: *MainWindow) void;

// Splash screen C API
const SplashScreen = opaque {};
extern fn splash_screen_new() ?*SplashScreen;
extern fn splash_screen_set_stage(splash: *SplashScreen, stage: c_int, detail: ?[*:0]const u8) void;
extern fn splash_screen_set_message(splash: *SplashScreen, message: [*:0]const u8) void;
extern fn splash_screen_update(splash: *SplashScreen) void;
extern fn splash_screen_close(splash: *SplashScreen) void;

// Splash stages (must match splash_screen_gtk.h)
pub const SplashStage = enum(c_int) {
    init = 0,
    config = 1,
    audio_engine = 2,
    audio_backend = 3,
    midi = 4,
    project = 5,
    ui_theme = 6,
    ui_window = 7,
    complete = 8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: ?*MainWindow,
    engine: ?*anyopaque, // AudioEngine pointer (set later)
    splash: ?*SplashScreen,

    pub fn create(allocator: std.mem.Allocator) !*App {
        log.info("Creating GTK4 application", .{});

        // On macOS with Homebrew, set GSettings schema path to fix file dialogs
        if (comptime builtin.os.tag == .macos) {
            // Try common Homebrew paths for GSettings schemas
            const schema_paths = [_][*:0]const u8{
                "/opt/homebrew/share/glib-2.0/schemas",
                "/usr/local/share/glib-2.0/schemas",
            };
            for (schema_paths) |path| {
                if (setenv("GSETTINGS_SCHEMA_DIR", path, 0) == 0) {
                    log.debug("Set GSETTINGS_SCHEMA_DIR to {s}", .{path});
                    break;
                }
            }
        }

        // Initialize GTK first (needed for splash screen)
        gtk_init();

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        app.* = App{
            .allocator = allocator,
            .window = null,
            .engine = null,
            .splash = null,
        };

        return app;
    }

    /// Show the splash screen - call this before initialization
    pub fn showSplash(self: *App) void {
        self.splash = splash_screen_new();
        if (self.splash) |s| {
            splash_screen_update(s);
        }
    }

    /// Update splash screen stage with optional detail message
    pub fn updateSplash(self: *App, stage: SplashStage, detail: ?[]const u8) void {
        if (self.splash) |s| {
            if (detail) |d| {
                // Need null-terminated string for C
                var buf: [256]u8 = undefined;
                const len = @min(d.len, buf.len - 1);
                @memcpy(buf[0..len], d[0..len]);
                buf[len] = 0;
                splash_screen_set_stage(s, @backingInt(stage), @ptrCast(&buf));
            } else {
                splash_screen_set_stage(s, @backingInt(stage), null);
            }
            splash_screen_update(s);
        }
    }

    /// Set engine after audio initialization
    pub fn setEngine(self: *App, engine: *anyopaque) void {
        self.engine = engine;
    }

    pub fn destroy(self: *App) void {
        log.info("Destroying GTK application", .{});

        self.allocator.destroy(self);
    }

    pub fn run(self: *App) i32 {
        // Create GLib main loop
        const main_loop = g_main_loop_new(null, 0) orelse {
            log.err("Failed to create GLib main loop", .{});
            return 1;
        };

        // Update splash for theme loading
        self.updateSplash(.ui_theme, null);

        // Load Tokyo Night theme before creating windows
        daw_load_theme();

        // Update splash for window creation
        self.updateSplash(.ui_window, null);

        // Create main window (pass audio engine)
        const window = main_window_new(main_loop, self.engine) orelse {
            log.err("Failed to create main window", .{});
            return 1;
        };
        self.window = window;

        // Close splash screen before showing main window
        if (self.splash) |s| {
            splash_screen_close(s);
            self.splash = null;
        }

        main_window_show(window);

        log.info("Starting GTK main loop", .{});
        g_main_loop_run(main_loop);

        return 0;
    }
};
