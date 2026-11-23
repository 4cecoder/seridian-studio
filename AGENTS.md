# AGENTS.md

This file provides essential guidance for agentic coding agents working in this DAW repository.

**Current state and open work: read `docs/HANDOFF.md` first.**

## Build & Test Commands

```bash
# Build
zig build

# Run application
zig build run

# Run all unit tests
zig build test

# Run specific module tests
zig test src/audio/engine.zig --main-pkg-path .
zig test src/midi/midi.zig --main-pkg-path .
zig test src/project/project.zig --main-pkg-path .

# Run tests with filter
zig test src/audio/engine.zig --main-pkg-path . -ftest-filter='init'

# Format code (check only - exits with non-zero if changes needed)
zig build fmt

# Format code (apply changes)
zig fmt src/ tests/

# Clean build artifacts
rm -rf zig-out .zig-cache
```

## Code Style Guidelines

### Imports
- Use `@import()` for Zig modules
- C imports via `@cImport()` limited to platform-specific headers
- Re-export commonly used types at module level
- Example: `pub const AudioEngine = @import("audio/engine.zig").AudioEngine;`

### Formatting
- Run `zig fmt` before committing - it's automatic
- No manual formatting preferences needed
- `zig build fmt` in CI enforces formatting

### Types
- Prefer explicit types over inference for public APIs
- Use `std.atomic.Value(T)` for cross-thread data
- Use `?*anyopaque` and `@ptrCast(@alignCast())` for FFI boundaries
- Use `extern struct` for C-compatible structures
- Use `opaque {}` for opaque C types

### Naming Conventions
- Types: `PascalCase` (e.g., `AudioEngine`, `RingBuffer`)
- Functions: `snake_case` (e.g., `initAudio`, `processBuffer`)
- Constants: `UPPER_SNAKE_CASE` (e.g., `TRACK_COUNT`, `MAX_HISTORY`)
- Module-level: `snake_case.zig` (e.g., `audio_engine.zig`)
- Enum values: `snake_case` (e.g., `low_pass`, `high_pass`)

### Error Handling
- NEVER ignore errors - Zig compiler enforces this
- Use `try` for propagation, `catch` for explicit handling
- Always use `defer` for cleanup, `errdefer` for error-only cleanup
- Use error sets in public function signatures
- Pattern: `try operation() catch |err| { log.err("context: {}", .{err}); return err; }`
- In C API: Return error codes instead of panicking

### Memory Management
- Use `defer` immediately after every allocation
- Use `errdefer` for resources that should be freed only on error
- Pre-allocate all audio buffers in `init()`, never in `process()`
- Example:
  ```zig
  const buffer = try allocator.alloc(f32, size);
  defer allocator.free(buffer);
  errdefer cleanupOnlyOnError();
  ```

## Real-Time Audio Safety (CRITICAL)

### Audio Thread Rules (in `process()` functions)
**NEVER do:**
- Allocate memory (use pre-allocated buffers)
- Use locks, mutexes, or blocking calls
- Perform file I/O or syscalls
- Call logging functions
- Call `std.posix.*` functions

**ALWAYS do:**
- Use atomics for shared state (`.load()`, `.store()`, `.fetchAdd()`)
- Keep processing deterministic and bounded
- Use `.monotonic` memory ordering unless ordering is critical
- Pre-allocate all buffers in `init()`

### Real-Time Safety Enforcement
- Audio thread marked via `rt_safe.is_audio_thread = true`
- `rt_safe.assertRealTimeSafe()` catches violations in debug builds
- Custom `RealTimeSafeAllocator` panics on audio thread allocation

## Cross-Platform Considerations

### Platform Detection
```zig
const builtin = @import("builtin");
if (builtin.os.tag == .linux) { /* Linux */ }
else if (builtin.os.tag == .macos) { /* macOS */ }
else if (builtin.os.tag == .windows) { /* Windows */ }
```

### Audio Backends
- Linux: PulseAudio (default), PipeWire
- macOS: CoreAudio
- Backend selected at build time via `-Dbackend=pulse|pipewire|coreaudio`

### Conditional C Imports
Wrap platform-specific C headers to avoid linker errors:
```zig
const c = if (builtin.os.tag == .linux) @cImport({
    @cInclude("pulse/simple.h");
}) else struct { /* stub */ };
```

## Architecture Patterns

### C/Zig Layering
- GTK4 UI in C files (`src/ui/*.c`)
- Zig code calls C via `extern fn` declarations
- Zig exposes C API via `export fn` with `callconv(.c)`
- Use opaque pointers to avoid exposing internal structure layout

### Helper Functions
- Repeated patterns (3+ times) get abstracted into helpers
- Use `inline fn` for zero-cost abstractions
- Use `comptime fn` for compile-time computations
- Example: `initAtomicArray()` for atomic array initialization

### Atomic Operations
- All cross-thread data uses `std.atomic.Value(T)`
- Use `.load(.monotonic)` for most reads (relaxed ordering)
- Use `.fetchAdd()` for counters (single-writer pattern)
- Store before releasing: `.store(val, .release)`
- Load after acquiring: `.load(.acquire)`

## Testing Patterns

### Unit Tests
- Place tests at bottom of files using `test` blocks
- Use `std.testing` for assertions
- Test naming: `"Module: specific behavior"`
- Example: `test "AudioEngine: initialization returns valid state"`

### Integration Tests
- Place in `tests/` directory
- Use GPA for leak detection:
  ```zig
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer { const leaked = gpa.deinit(); if (leaked != .ok) @panic("Leak!"); }
  const allocator = gpa.allocator();
  ```

### Mocking External Dependencies
- Create mock structs for testing in isolation
- Use function pointers for callbacks
- Test both success and error paths

## Documentation
- Public APIs require `///` doc comments
- Use scoped logging: `const log = std.log.scoped(.module_name);`
- Log levels: `log.info()`, `log.warn()`, `log.err()`
- NO logging in audio thread `process()` functions

## Constants
- Define named constants, no magic numbers
- Use `pub const` for public constants
- Example: `pub const TRACK_COUNT = 4;`

## Development Workflow
1. Make changes to code
2. Run `zig fmt src/` to format
3. Run `zig test <module.zig> --main-pkg-path .` for affected modules
4. Run `zig build` to verify build succeeds
5. Run `zig build run` to test application
6. Run `zig build test` for full test suite

## Platform-Specific Files
- `src/audio/pulseaudio.zig` - Linux PulseAudio backend
- `src/audio/coreaudio.zig` - macOS CoreAudio backend
- `src/ui/*.c` - GTK4 UI (C code)
- Build system handles platform selection via `builtin.os.tag`

## Key Files
- `build.zig` - Build configuration, test steps, platform setup
- `src/main.zig` - Application entry point
- `src/audio/engine.zig` - Core audio engine
- `src/dsp/core.zig` - DSP utilities
- `src/effects/effects.zig` - Effects registry
- `src/audio/rt_safe.zig` - Real-time safety enforcement
