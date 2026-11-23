# Development Guide

This guide covers developer workflows, code standards, and common tasks for the DAW project.

## Quick Reference

```bash
# Build
zig build

# Run
zig build run

# Test
zig build test

# Clean
rm -rf zig-out .zig-cache

# Format code
zig fmt src/
```

## Project Overview

A simple Digital Audio Workstation for Linux built with:
- **Zig 0.18+** - Systems programming language
- **GTK4** - Native UI framework
- **PulseAudio/PipeWire** - Audio backend

## Code Standards

### Zig Code Style

- **Formatting:** `zig fmt` (automatic)
- **Documentation:** `///` for public APIs
- **Error Sets:** Explicit in function signatures
- **Logging:** `std.log.scoped(.module_name)`
- **Naming:** snake_case for functions, PascalCase for types

**Example:**
```zig
const log = std.log.scoped(.audio_engine);

pub const AudioError = error{
    BackendInitFailed,
    InvalidSampleRate,
};

/// Initialize audio engine with given configuration
pub fn init(allocator: Allocator, config: Config) !AudioEngine {
    log.info("Initializing audio engine", .{});
    // Implementation
}
```

### C Code Style

- **Standard:** C11
- **GTK Conventions:** Follow GTK4 naming patterns
- **Memory:** GTK handles most cleanup automatically
- **Headers:** Minimal - only expose what Zig needs

### Error Handling

**Always handle errors explicitly:**
```zig
// NEVER ignore errors
const file = try std.fs.cwd().openFile("foo.txt", .{});
defer file.close();

// Provide context when propagating
fn loadConfig() !Config {
    return parseToml(data) catch |err| {
        log.err("Failed to parse config: {}", .{err});
        return err;
    };
}

// Use errdefer for cleanup
fn allocateBuffer(allocator: Allocator) ![]f32 {
    const buffer = try allocator.alloc(f32, 1024);
    errdefer allocator.free(buffer);

    try initializeBuffer(buffer);
    return buffer;
}
```

### Real-Time Audio Rules

**In the audio thread's `process()` function:**

❌ **NEVER:**
- Allocate memory
- Use locks or mutexes
- Call blocking functions
- Do file I/O
- Call `log.*` functions

✅ **ALWAYS:**
- Pre-allocate all buffers
- Use atomics for shared state
- Keep processing deterministic
- Measure CPU usage periodically

## Architecture & Integration

### C/Zig Layering for GTK4

**Why:** GTK4 headers cause issues with Zig's `@cImport` (9000+ errors)

**Solution:**
- GTK4 UI implemented in C (`main_window_gtk.c`)
- Zig code uses `extern fn` declarations
- Minimal opaque pointer pattern
- No direct @cImport of GTK headers in Zig

Example:
```zig
// In Zig
const MainWindow = opaque {};
extern fn main_window_new(loop: *GMainLoop) ?*MainWindow;
extern fn main_window_show(win: *MainWindow) void;

// In C
MainWindow* main_window_new(GMainLoop *loop) {
    // GTK4 implementation
}
```

### Audio Backend Detection

Runtime detection with fallback chain:
1. Check user preference (config/CLI)
2. Try PipeWire (`pw-cli ls Node`)
3. Fall back to PulseAudio (`pactl info`)
4. Error if neither available

### Real-Time Audio Architecture

```
UI Thread (GTK)
    ↓ Atomic values + Command queue
Audio Thread (rt priority)
    ↓ Process buffer (zero-alloc)
Backend (PulseAudio/PipeWire)
```

**Critical:** NO allocations in audio thread's `process()` function

## Common Development Tasks

### Adding a New Audio Effect

1. **Create effect file:**
```zig
// src/effects/myeffect.zig
pub const MyEffect = struct {
    effect: Effect,

    // Parameters
    param1: f32 = 0.5,
    param2: f32 = 1.0,

    // State (if needed)
    history: [2]f32 = .{0, 0},
    sample_rate: f32,

    pub fn init(sample_rate: f32) MyEffect {
        return .{ .sample_rate = sample_rate };
    }

    pub fn process(effect: *Effect, input: []f32, output: []f32) void {
        const self: *MyEffect = @fieldParentPtr("effect", effect);

        // DSP code here - NO ALLOCATIONS
        for (input, output) |in_sample, *out_sample| {
            out_sample.* = processSample(self, in_sample);
        }
    }

    fn processSample(self: *MyEffect, sample: f32) f32 {
        // Your DSP algorithm
        return sample * self.param1;
    }
};
```

2. **Add to effect chain** (when implemented)

### Adding a GTK UI Component

1. **Add to header:**
```c
// src/ui/main_window_gtk.h
void main_window_add_my_widget(MainWindow *win, int x, int y);
```

2. **Implement in C:**
```c
// src/ui/main_window_gtk.c
void main_window_add_my_widget(MainWindow *win, int x, int y) {
    GtkWidget *widget = gtk_button_new_with_label("My Widget");

    // Connect signals
    g_signal_connect(widget, "clicked",
        G_CALLBACK(on_my_widget_clicked), win);

    // Add to layout
    gtk_box_append(GTK_BOX(win->main_box), widget);
}

static void on_my_widget_clicked(GtkButton *button, gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;
    // Handle click
}
```

3. **Declare in Zig:**
```zig
// src/ui/app.zig
extern fn main_window_add_my_widget(win: *MainWindow, x: i32, y: i32) void;

// Use it
main_window_add_my_widget(window, 10, 20);
```

### Exposing Zig Functions to C

1. **Create C API wrapper:**
```zig
// src/audio/engine_c_api.zig
export fn audio_engine_my_function(
    engine: ?*anyopaque,
    param: c_int
) callconv(.c) f32 {
    const eng = @as(*AudioEngine, @ptrCast(@alignCast(engine orelse return 0.0)));

    // Call Zig function
    return eng.myFunction(@intCast(param));
}
```

2. **Declare in C header:**
```c
// src/ui/main_window_gtk.h
float audio_engine_my_function(void *engine, int param);
```

3. **Ensure compilation:**
```zig
// src/main.zig
comptime {
    _ = @import("audio/engine_c_api.zig");
}
```

## Debugging

### Audio Issues
```bash
# Check PulseAudio
pactl info
pactl list sinks

# Check PipeWire
pw-cli ls Node
pw-cli info

# Run with debug logging
./zig-out/bin/daw 2>&1 | grep -E "audio|pulse|pipe"
```

### GTK Issues
```bash
# GTK debug inspector
GTK_DEBUG=interactive ./zig-out/bin/daw
```

### Memory Leaks
```bash
# Manual check with valgrind
valgrind --leak-check=full ./zig-out/bin/daw
```

## Testing

### Unit Tests
Embedded in source files:
```zig
test "audio engine initializes correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var engine = try AudioEngine.init(alloc, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    try testing.expectEqual(@as(u32, 48000), engine.sample_rate);
    try testing.expectEqual(@as(u32, 512), engine.buffer_size);
}
```

Run tests: `zig build test`

## Build System (Zig 0.18+)

Zig 0.18+ changed high-level build API:
- `build.zig.zon` requires `.name` as enum literal and `.fingerprint`.
- `build.zig` uses `b.createModule()` and `.root_module`.

```zig
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("build_options", options.createModule());

const exe = b.addExecutable(.{
    .name = "daw",
    .root_module = exe_mod,
});
```

### Adding System Libraries
```zig
// Link libraries BEFORE adding C sources
exe.linkLibC();
exe.linkSystemLibrary("gtk-4");
exe.linkSystemLibrary("pulse");

exe.addCSourceFile(.{
    .file = b.path("src/ui/main_window_gtk.c"),
    .flags = &.{"std=c11"},
});
```

---

**Last Updated:** 2025-12-25
