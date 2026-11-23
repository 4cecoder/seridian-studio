# API Reference

## Audio Engine API

### C API (for UI integration)

These functions are exported from Zig and callable from C code.

#### Playback Control

```c
void audio_engine_start(void *engine);
```
Start audio playback. Sets playing state to true and begins processing audio buffers.

```c
void audio_engine_stop(void *engine);
```
Stop audio playback. Sets playing state to false and outputs silence.

#### Track Control

```c
void audio_engine_set_track_gain(void *engine, int track, float gain);
```
Set track volume.
- **track:** Track index (0-3)
- **gain:** Volume (0.0 = silence, 1.0 = unity gain)

```c
void audio_engine_set_track_mute(void *engine, int track, int muted);
```
Mute or unmute a track.
- **track:** Track index (0-3)
- **muted:** 1 = muted, 0 = unmuted

```c
void audio_engine_set_track_solo(void *engine, int track, int soloed);
```
Solo a track (mutes all other tracks).
- **track:** Track index (0-3)
- **soloed:** 1 = soloed, 0 = not soloed

#### Master Control

```c
void audio_engine_set_master_gain(void *engine, float gain);
```
Set master output volume.
- **gain:** Volume (0.0 = silence, 1.0 = unity gain)

#### Metering

```c
float audio_engine_get_track_meter(void *engine, int track);
```
Get current track level.
- **track:** Track index (0-3)
- **Returns:** Peak level (0.0-1.0)

```c
float audio_engine_get_master_meter_left(void *engine);
```
Get master left channel level.
- **Returns:** Peak level (0.0-1.0)

```c
float audio_engine_get_master_meter_right(void *engine);
```
Get master right channel level.
- **Returns:** Peak level (0.0-1.0)

### Zig API

#### AudioEngine

```zig
pub const AudioEngine = struct {
    /// Initialize audio engine
    pub fn init(allocator: Allocator, config: EngineConfig) !AudioEngine

    /// Clean up audio engine
    pub fn deinit(self: *AudioEngine) void

    /// Start playback
    pub fn start(self: *AudioEngine) !void

    /// Stop playback
    pub fn stop(self: *AudioEngine) void

    /// Real-time audio processing callback
    /// WARNING: Called from audio thread - NO ALLOCATIONS
    pub fn process(self: *AudioEngine, output: []f32) void

    /// Set track gain (thread-safe)
    pub fn setTrackGain(self: *AudioEngine, track: usize, gain: f32) void

    /// Set master gain (thread-safe)
    pub fn setMasterGain(self: *AudioEngine, gain: f32) void

    /// Get track meter level (thread-safe)
    pub fn getTrackMeter(self: *AudioEngine, track: usize) f32

    /// Get master meter levels (thread-safe)
    pub fn getMasterMeter(self: *AudioEngine) struct { left: f32, right: f32 }
};
```

#### EngineConfig

```zig
pub const EngineConfig = struct {
    sample_rate: u32 = 48000,
    buffer_size: u32 = 512,
    backend: BackendType = .auto,

    pub const BackendType = enum {
        auto,
        pulseaudio,
        pipewire,
    };
};
```

## Backend API

### Backend Interface

```zig
pub const Backend = union(enum) {
    pulseaudio: PulseAudioBackend,
    pipewire: PipeWireBackend,

    /// Initialize backend with runtime detection
    pub fn init(config: BackendConfig) !Backend

    /// Start audio streaming
    pub fn start(self: *Backend, callback: AudioCallback) !void

    /// Stop audio streaming
    pub fn stop(self: *Backend) void

    /// Clean up backend resources
    pub fn deinit(self: *Backend) void
};
```

### BackendConfig

```zig
pub const BackendConfig = struct {
    sample_rate: u32,
    buffer_size: u32,
    channels: u8 = 2,  // Stereo
};
```

### AudioCallback

```zig
pub const AudioCallback = *const fn (userdata: ?*anyopaque, output: []f32) void;
```

## Configuration API

### Config

```zig
pub const Config = struct {
    audio: AudioConfig,
    project: ProjectConfig,
    ui: UIConfig,
    display: DisplayConfig,

    /// Load configuration from XDG config dir
    pub fn load(allocator: Allocator) !Config

    /// Save configuration to XDG config dir
    pub fn save(self: Config, allocator: Allocator) !void

    /// Get default configuration
    pub fn default() Config
};
```

### XDG Paths

```zig
/// Get XDG config directory path
pub fn getConfigPath(allocator: Allocator, relative_path: []const u8) ![]const u8

/// Get XDG data directory path
pub fn getDataPath(allocator: Allocator, relative_path: []const u8) ![]const u8

/// Get XDG state directory path
pub fn getStatePath(allocator: Allocator, relative_path: []const u8) ![]const u8
```

## UI API

### MainWindow (Opaque C Binding)

```zig
pub const MainWindow = opaque {
    /// Create main window
    extern fn main_window_new(loop: *GMainLoop, engine: *anyopaque) ?*MainWindow;

    /// Show window
    extern fn main_window_show(win: *MainWindow) void;

    /// Set audio engine reference
    extern fn main_window_set_audio_engine(win: *MainWindow, engine: *anyopaque) void;
};
```

## Error Sets

### AudioEngine Errors

```zig
pub const AudioEngineError = error{
    BackendNotAvailable,
    BackendInitFailed,
    InvalidSampleRate,
    InvalidBufferSize,
    AllocationFailed,
};
```

### Backend Errors

```zig
pub const BackendError = error{
    InitFailed,
    DeviceNotFound,
    ConnectionFailed,
};
```

### Config Errors

```zig
pub const ConfigError = error{
    FileNotFound,
    ParseError,
    InvalidValue,
    WriteError,
};
```

## Thread Safety

### Safe from Any Thread

These use atomics and are safe to call from any thread:

- `audio_engine_set_track_gain()`
- `audio_engine_set_master_gain()`
- `audio_engine_set_track_mute()`
- `audio_engine_set_track_solo()`
- `audio_engine_get_track_meter()`
- `audio_engine_get_master_meter_left()`
- `audio_engine_get_master_meter_right()`

### Main Thread Only

These must be called from the main/UI thread:

- `audio_engine_start()`
- `audio_engine_stop()`
- All GTK/UI functions
- `Config.load()`
- `Config.save()`

### Audio Thread Only

These are called internally and should never be called from user code:

- `AudioEngine.process()` - Called by backend

## Usage Examples

### Basic Setup

```zig
const std = @import("std");
const AudioEngine = @import("audio/engine.zig").AudioEngine;
const Config = @import("config/config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const config = try Config.load(allocator);
    defer config.deinit(allocator);

    // Initialize audio engine
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = config.audio.sample_rate,
        .buffer_size = config.audio.buffer_size,
    });
    defer engine.deinit();

    // Start audio
    try engine.start();
    defer engine.stop();

    // Set initial levels
    engine.setMasterGain(0.75);
    engine.setTrackGain(0, 0.8);

    // ... run UI ...
}
```

### Meter Reading Loop

```c
// C code - GTK timer callback
static gboolean update_meters(gpointer user_data) {
    MainWindow *win = (MainWindow *)user_data;

    // Read meters from audio thread
    for (int i = 0; i < 4; i++) {
        float level = audio_engine_get_track_meter(win->audio_engine, i);
        update_meter_display(win->track_meters[i], level);
    }

    float master_l = audio_engine_get_master_meter_left(win->audio_engine);
    float master_r = audio_engine_get_master_meter_right(win->audio_engine);
    update_meter_display(win->master_meter_left, master_l);
    update_meter_display(win->master_meter_right, master_r);

    return G_SOURCE_CONTINUE;  // Keep timer running
}
```

---

**Last Updated:** 2025-12-20
