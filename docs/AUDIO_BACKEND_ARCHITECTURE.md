# Audio Backend Architecture

## Overview

The DAW uses a modular, cross-platform audio backend system that automatically detects and uses the best available audio API on each platform.

## Supported Platforms

| Platform | Backend | Status | Features |
|----------|---------|--------|----------|
| **Linux** | PulseAudio | ✅ Fully Implemented | Full playback, low latency |
| **Linux** | PipeWire | ⚠️ Stub (WIP) | Detection only |
| **macOS** | CoreAudio | ✅ Fully Implemented | Native callbacks, low latency |
| **Windows** | WASAPI | 🔄 Planned | Not yet implemented |

## Architecture Principles

### 1. **Low Code Duplication**
- Common interface defined in `backend.zig`
- Platform-specific implementations isolated in separate files
- Shared utilities for buffer management and timing

### 2. **Strong Isolation**
- Each backend is a self-contained module
- No cross-dependencies between backends
- Clean separation of concerns

### 3. **Conditional Compilation**
- Platform-specific code only compiles on target platform
- Uses Zig's compile-time `if` for zero-overhead abstraction
- No runtime overhead for unused backends

## Backend Interface

All backends implement this common interface:

```zig
pub const Backend = union(enum) {
    coreaudio: coreaudio.CoreAudioBackend,
    pulseaudio: pulseaudio.PulseAudioBackend,
    pipewire: pipewire.PipeWireBackend,
    wasapi: wasapi.WASAPIBackend,

    pub fn init(allocator: Allocator, config: *const Config) !Backend
    pub fn deinit(self: *Backend) void
    pub fn prepare(self: *Backend) !void
    pub fn start(self: *Backend) !void
    pub fn stop(self: *Backend) void
    pub fn setEngine(self: *Backend, engine: *anyopaque, callback: ProcessFn) void
};
```

### Key Methods

**`init(allocator, config)`**
- Creates backend instance
- Validates configuration
- Allocates resources

**`prepare()`**
- Initializes audio device/stream
- Sets up buffer sizes
- Prepares for playback

**`setEngine(engine, callback)`**
- Connects audio engine
- Sets process callback function
- Engine provides audio data

**`start()`**
- Begins audio playback
- Spawns audio thread (push-based backends)
- Activates callbacks

**`stop()`**
- Halts audio playback
- Stops audio thread gracefully
- Cleans up resources

**`deinit()`**
- Full cleanup and shutdown
- Frees all allocated memory
- Closes audio device

## Backend Detection

Auto-detection uses this priority order:

### Linux
1. **PulseAudio** (preferred - fully implemented)
   - Detection: checks for `pactl` command
   - Why first: Stable, widely available, fully implemented
2. **PipeWire** (fallback - currently stub)
   - Detection: checks for `pw-cli` command
   - Future: Will replace PulseAudio as primary

### macOS
1. **CoreAudio** (only option)
   - Native macOS audio API
   - Always available on macOS

### Windows (Planned)
1. **WASAPI** (future implementation)
   - Modern Windows audio API
   - Low latency, exclusive mode support

## Implementation Models

### Pull-Based (CoreAudio)
```
OS Audio Thread → renderCallback() → engine.process() → fill buffer → return
```

**Characteristics:**
- OS manages thread
- Callback invoked by OS
- Ultra-low latency
- Less control over timing

**File:** `src/audio/coreaudio.zig`

### Push-Based (PulseAudio, PipeWire)
```
Application Thread → engine.process() → fill buffer → write() → sleep
```

**Characteristics:**
- Application manages thread
- Active polling model
- More control over timing
- Slightly higher latency

**File:** `src/audio/pulseaudio.zig`

## PulseAudio Implementation Details

### Thread Safety
- Uses `std.atomic.Value(bool)` for running flag
- Atomic storage for engine pointer
- Acquire/release memory ordering

### Timing
```zig
buffer_duration_ns = (buffer_size * ns_per_second) / sample_rate
sleep_duration = buffer_duration * 0.8  // 80% to prevent underruns
```

### Audio Thread Loop
```zig
while (running.load(.seq_cst)) {
    if (engine_ptr.load(.acquire)) |engine| {
        @memset(output_buffer, 0);
        process_fn(engine, output_buffer);
        write(output_buffer);
    }
    std.time.sleep(sleep_duration);
}
```

### Error Handling
- Write errors don't crash thread (logs and continues)
- Graceful degradation
- Automatic recovery from transient failures

## Memory Management

### Buffer Allocation
- Buffers pre-allocated in `init()`
- No allocations in audio thread
- Proper cleanup in `deinit()`

### Real-Time Safety
- Audio threads marked with `rt_safe.is_audio_thread = true`
- Debug builds catch violations
- No heap allocations in hot path

## Configuration

```zig
pub const Config = struct {
    sample_rate: u32,      // 44100, 48000, 88200, 96000
    buffer_size: u32,      // 128, 256, 512, 1024, 2048
    audio_backend: enum {
        auto,              // Automatic detection (recommended)
        pulseaudio,        // Force PulseAudio (Linux)
        pipewire,          // Force PipeWire (Linux, stub)
        coreaudio,         // Force CoreAudio (macOS)
        wasapi,            // Force WASAPI (Windows, future)
    },
};
```

## Testing

### Build Verification
```bash
bash tests/test_build.sh
```

Verifies:
- Clean compilation
- No platform-specific symbol leakage
- Correct library linkage
- Executable validity

### Backend Tests (Planned)
```bash
zig test tests/test_pulseaudio_backend.zig
zig test tests/test_backend_detection.zig
```

## Adding New Backends

### 1. Create Backend Module
```zig
// src/audio/newbackend.zig
pub const NewBackend = struct {
    allocator: Allocator,
    running: bool,
    // ... backend-specific fields

    pub fn init(allocator: Allocator, config: *const Config) !NewBackend { }
    pub fn deinit(self: *NewBackend) void { }
    pub fn prepare(self: *NewBackend) !void { }
    pub fn start(self: *NewBackend) !void { }
    pub fn stop(self: *NewBackend) void { }
    pub fn setEngine(self: *NewBackend, engine: *anyopaque, callback: ProcessFn) void { }
};
```

### 2. Add to Backend Union
```zig
// src/audio/backend.zig
const newbackend = if (builtin.os.tag == .target) @import("newbackend.zig") else struct { ... };

pub const Backend = union(enum) {
    // ...
    newbackend: newbackend.NewBackend,
};
```

### 3. Add Detection Logic
```zig
fn detectNewBackend() bool {
    // Platform-specific detection logic
}
```

### 4. Update Auto-Detection
```zig
pub fn init(allocator: Allocator, config: *const Config) !Backend {
    return switch (config.audio_backend) {
        .auto => {
            if (detectNewBackend()) {
                return .{ .newbackend = try newbackend.NewBackend.init(allocator, config) };
            }
            // ... fallback logic
        },
        // ...
    };
}
```

## Performance Characteristics

### PulseAudio
- **Latency:** ~10-20ms (buffer_size=512, sample_rate=48000)
- **CPU Usage:** <1% on modern hardware
- **Thread Priority:** Normal (can be elevated with RT permissions)

### CoreAudio
- **Latency:** ~5-10ms
- **CPU Usage:** <0.5%
- **Thread Priority:** Real-time (OS-managed)

## Troubleshooting

### No Audio Output
1. Check backend detection:
   ```bash
   pactl info  # PulseAudio
   pw-cli info # PipeWire
   ```
2. Verify default device:
   ```bash
   pactl list sinks short
   ```
3. Check DAW logs for backend initialization

### Audio Dropouts/Glitches
1. Increase buffer size (reduces glitches, increases latency)
2. Check CPU usage (reduce track count/effects)
3. Ensure audio thread has adequate priority

### Build Errors
1. Install required development packages:
   ```bash
   # Debian/Ubuntu
   sudo apt install libpulse-dev libpipewire-0.3-dev

   # Fedora/RHEL
   sudo dnf install pulseaudio-libs-devel pipewire-devel

   # Arch
   sudo pacman -S libpulse pipewire
   ```

## Future Enhancements

### Short Term
- [ ] Complete PipeWire implementation (native API, not PulseAudio compat)
- [ ] Add latency compensation
- [ ] Implement device enumeration/selection
- [ ] Add buffer underrun statistics

### Long Term
- [ ] WASAPI backend for Windows
- [ ] JACK support for professional Linux audio
- [ ] ASIO support for Windows pro audio
- [ ] Multi-device synchronization
- [ ] Sample rate conversion

## References

- **PulseAudio:** https://www.freedesktop.org/wiki/Software/PulseAudio/
- **PipeWire:** https://pipewire.org/
- **CoreAudio:** https://developer.apple.com/documentation/coreaudio
- **WASAPI:** https://docs.microsoft.com/en-us/windows/win32/coreaudio/wasapi
