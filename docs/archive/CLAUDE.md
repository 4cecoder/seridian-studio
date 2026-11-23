# DAW for Linux - Development Guide

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
```

## Project Overview

A simple Digital Audio Workstation for Linux built with:
- **Zig 0.16** - Systems programming language
- **GTK4** - Native UI framework
- **PulseAudio/PipeWire** - Audio backend

**Current Phase:** Foundation (MVP skeleton complete)

## Architecture

### Module Organization

```
src/
├── main.zig           # Entry point, GTK initialization
├── audio/             # Audio engine & backends
│   ├── engine.zig     # Core audio processing
│   ├── backend.zig    # Backend abstraction
│   ├── pulseaudio.zig # PulseAudio driver
│   └── pipewire.zig   # PipeWire driver (stub)
├── config/            # Configuration management
│   ├── config.zig     # Config structure
│   └── xdg.zig        # XDG directory support
├── ui/                # GTK4 UI
│   ├── app.zig        # App wrapper (Zig)
│   ├── main_window_gtk.h  # C header
│   └── main_window_gtk.c  # GTK implementation
└── utils/             # Utilities
    └── log.zig        # Logging

## Key Design Decisions

### 1. C/Zig Layering for GTK4

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

### 2. Audio Backend Detection

Runtime detection with fallback chain:
1. Check user preference (config/CLI)
2. Try PipeWire (`pw-cli ls Node`)
3. Fall back to PulseAudio (`pactl info`)
4. Error if neither available

### 3. Real-Time Audio Architecture

```
UI Thread (GTK)
    ↓ Atomic values + Command queue
Audio Thread (rt priority)
    ↓ Process buffer (zero-alloc)
Backend (PulseAudio/PipeWire)
```

**Critical:** NO allocations in audio thread's `process()` function

### 4. Build System (Zig 0.16)

Zig 0.16 changed build API:
- Use `b.createModule()` first
- Then `root_module` instead of `root_source_file`
- Add imports to module: `module.addImport()`
- Build options via `options.createModule()`

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

## Common Tasks

### Adding a New Audio Effect

1. Create `src/effects/myeffect.zig`
2. Implement Effect interface:
```zig
pub const MyEffect = struct {
    effect: Effect,
    // parameters...

    pub fn process(effect: *Effect, input: []f32, output: []f32) void {
        const self: *MyEffect = @fieldParentPtr("effect", effect);
        // DSP code here - NO ALLOCATIONS
    }
};
```

3. Add to effect chain in `src/effects/chain.zig`

### Adding GTK4 UI Components

1. Add to `src/ui/main_window_gtk.h`:
```c
void main_window_add_my_widget(MainWindow *win, ...);
```

2. Implement in `src/ui/main_window_gtk.c`:
```c
void main_window_add_my_widget(MainWindow *win, ...) {
    GtkWidget *widget = gtk_...();
    // GTK4 code
}
```

3. Declare extern in `src/ui/app.zig`:
```zig
extern fn main_window_add_my_widget(win: *MainWindow, ...) void;
```

### Debugging Audio Issues

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

## Testing

### Unit Tests

Embedded in source files:
```zig
test "effect processes correctly" {
    const testing = std.testing;
    // Test code
}
```

Run: `zig build test`

### Integration Testing

Manual testing checklist in `README.md`

## Dependencies

### System Libraries

- **GTK4** (`gtk-4`, `glib-2.0`, `gobject-2.0`, `cairo`)
- **PulseAudio** (`pulse`, `pulse-simple`)
- **PipeWire** (`pipewire-0.3`) - optional

### Include Paths

GTK4 requires explicit include paths in build.zig:
```zig
exe.addIncludePath(.{ .cwd_relative = "/usr/include/gtk-4.0" });
exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
// ... see build.zig for full list
```

## Known Issues & Workarounds

### 1. PipeWire Backend is Stub

**Status:** Not implemented
**Workaround:** Use `--backend=pulse` or rely on auto-detection (falls back to PulseAudio)

### 2. GTK4 @cImport Issues

**Issue:** `@cImport` of GTK headers fails with 9000+ errors
**Solution:** Use extern declarations + C implementation (see "C/Zig Layering")

### 3. Audio Engine is Stub

**Status:** Process loop outputs silence only
**Next Steps:** Implement track rendering, mixing, effects

## Code Style

- **Formatting:** `zig fmt` (automatic)
- **Documentation:** `///` for public APIs
- **Error Sets:** Explicit in function signatures
- **Logging:** `std.log.scoped(.module_name)`
- **Naming:** snake_case for functions, PascalCase for types

Example:
```zig
const log = std.log.scoped(.my_module);

pub const MyError = error{
    SomethingFailed,
};

/// Does something important
pub fn doSomething(allocator: Allocator) !void {
    log.info("Doing something", .{});
    // Implementation
}
```

## Performance Guidelines

### Real-Time Audio Thread

❌ **Never:**
- Allocate memory
- Call blocking functions
- Use locks (prefer atomics)
- Do file I/O
- Call printf/log

✅ **Always:**
- Pre-allocate buffers
- Use lock-free structures
- Keep processing deterministic
- Measure CPU usage

### Memory Management

- Pass allocators explicitly
- Use Arena allocators for scoped allocations
- Test with Valgrind: `zig build run-valgrind` (add to build.zig)
- Use `errdefer` for cleanup

## Next Steps (Post-MVP)

1. **Real-Time Audio Thread** - Actual playback/recording
2. **Track System** - Multi-track rendering
3. **Effect Chain** - Process audio through effects
4. **Timeline UI** - Waveform display, editing
5. **Project Persistence** - SQLite-based save/load

## References

- **Changies** (`~/changies`) - Audio architecture inspiration
- **Ghostty** (`~/ghostty`) - Build system, code quality
- **Talkies** (`~/talkies/linux`) - GTK4 integration patterns

## Getting Help

1. Check `PRD.md` for feature specifications
2. Check `README.md` for build instructions
3. Review reference projects in `~/changies`, `~/ghostty`, `~/talkies/linux`
4. Consult Zig documentation: https://ziglang.org/documentation/master/

## Build System Notes

### Zig 0.16 Changes

- `build.zig.zon` requires:
  - `.name` as enum literal (`.daw` not `"daw"`)
  - `.fingerprint` field (unique package ID)
  - `.minimum_zig_version` string

- `build.zig` requires:
  - `b.createModule()` before `b.addExecutable()`
  - `.root_module` instead of `.root_source_file`
  - Link system libraries BEFORE adding C sources

### Adding System Libraries

```zig
exe.linkLibC();
exe.linkSystemLibrary("somelib");
exe.addIncludePath(.{ .cwd_relative = "/usr/include/somelib" });
```

## Troubleshooting

### Build Fails with "gtk/gtk.h not found"

Add GTK4 include paths in build.zig (see existing configuration)

### "undefined symbol: gtk_main"

GTK4 deprecated `gtk_main()` - use `GMainLoop` instead

### Audio Backend Not Found

```bash
# Check available backends
pactl info           # PulseAudio
pw-cli ls Node       # PipeWire

# Force specific backend
./zig-out/bin/daw --backend=pulse
```

### Zig Version Mismatch

Ensure Zig 0.16.0+:
```bash
zig version
# Should show: 0.16.0-dev.XXXX+...
```

---

**Last Updated:** 2025-12-20
**Zig Version:** 0.16.0-dev.1484+d0ba6642b
**GTK Version:** 4.20.2
**PulseAudio Version:** 17.0
