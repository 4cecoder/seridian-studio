# Product Requirements Document: GTK4 DAW for Linux

**Version:** 1.0
**Date:** 2025-12-20
**Status:** Draft
**Target Platform:** Linux (X11 + Wayland)

---

## 1. Executive Summary

A simple, focused Digital Audio Workstation (DAW) for Linux built with **Zig 0.16** and **GTK4**. This MVP prioritizes excellent code quality, real-time audio performance, and Linux-native integration over feature completeness. The project learns from proven patterns in Changies (audio processing), Ghostty (code quality), and Talkies (GTK4 integration).

### Core Philosophy
- **Simple first, powerful later** - Start with essential DAW functionality
- **Code quality over features** - Follow Ghostty's engineering excellence
- **Real-time performance** - Zero-allocation hot paths, <10ms latency
- **Linux-native** - PulseAudio + PipeWire support, XDG compliance
- **Transparent architecture** - Clear separation of concerns, testable modules

---

## 2. Technical Stack

### Core Technologies
- **Language:** Zig 0.16.0+
- **UI Framework:** GTK4 (via C FFI)
- **Audio Backend:** PulseAudio + PipeWire (runtime detection)
- **Build System:** Zig Build
- **Configuration:** TOML format
- **Storage:** SQLite3 (project/session persistence)

### System Requirements
- Linux kernel 5.10+ (for PipeWire)
- GTK4 4.10+
- PulseAudio OR PipeWire
- 4GB RAM minimum
- Multi-core CPU recommended

---

## 3. MVP Feature Set

### 3.1 Core Audio Features (P0)
| Feature | Description | Reference |
|---------|-------------|-----------|
| **Multi-track recording** | 4 mono/stereo tracks minimum | Changies: multi-threaded audio |
| **Playback engine** | Sample-accurate playback with transport controls | Changies: AudioContext pattern |
| **Audio routing** | Input → Track → Master Out | Changies: effect chain |
| **Real-time monitoring** | Zero-latency monitoring with mix control | Changies: PulseAudio streaming |
| **WAV import/export** | 16/24-bit, 44.1/48kHz support | Talkies: WAV header writing |

### 3.2 Editing Features (P0)
| Feature | Description | Reference |
|---------|-------------|-----------|
| **Timeline view** | Horizontal scrolling timeline with waveform display | Industry standard |
| **Cut/Copy/Paste** | Basic region manipulation | Standard DAW UX |
| **Snap to grid** | Quantize edits to bar/beat/sample | Standard DAW UX |
| **Undo/Redo** | Comprehensive undo stack | Standard UX pattern |
| **Zoom controls** | Horizontal + vertical waveform zoom | Standard DAW UX |

### 3.3 Effects (P0 - Minimal Set)
Based on Changies' proven DSP implementations:

| Effect | Purpose | Implementation |
|--------|---------|----------------|
| **High-pass filter** | Remove rumble/DC offset | Changies: vox_chain.zig |
| **Compressor** | Dynamic range control | Changies: vox_chain.zig |
| **Limiter** | Prevent clipping | Changies: vox_chain.zig |
| **Reverb** | Spatial effects | Changies: effects/reverb.zig (Freeverb) |
| **Delay** | Echo effects | Changies: effects/delay.zig |
| **Parametric EQ** | 3-band EQ | Changies: biquad filters |

### 3.4 UI Components (P0)
| Component | Description | Reference |
|-----------|-------------|-----------|
| **Transport bar** | Play/Stop/Record/Loop controls | Standard DAW UX |
| **Track headers** | Volume, pan, mute, solo, record-enable | Standard DAW UX |
| **Mixer view** | Per-track faders with metering | Changies: web UI meters |
| **Effect rack** | Insert effects per track | Changies: effect chain |
| **Status bar** | CPU usage, sample rate, latency, buffer size | Talkies: status window |

### 3.5 Project Management (P0)
- **Save/Load projects** (custom format + SQLite)
- **Recent projects list**
- **Auto-save** (configurable interval)
- **Export mixdown** (WAV/FLAC)

---

## 4. Architecture

### 4.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      GTK4 UI LAYER                           │
│  - Main window (timeline, mixer, transport)                  │
│  - Effect windows                                            │
│  - Dialogs (preferences, export, about)                      │
└──────────────────┬──────────────────────────────────────────┘
                   │ GLib signals + callbacks
┌──────────────────▼──────────────────────────────────────────┐
│                   CONTROL LAYER (Zig)                        │
│  - Command dispatcher                                        │
│  - State management (project, transport, selection)          │
│  - Undo/Redo stack                                           │
└──────────────────┬──────────────────────────────────────────┘
                   │ Atomic values + Mutexes
┌──────────────────▼──────────────────────────────────────────┐
│                  AUDIO ENGINE (Zig)                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ REAL-TIME THREAD (highest priority)                  │   │
│  │  - Audio callback (process buffer)                   │   │
│  │  - Track rendering                                   │   │
│  │  - Effect processing                                 │   │
│  │  - Mixing                                            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  - Project data (tracks, regions, automation)               │
│  - Audio file cache                                         │
│  - Effect instances                                         │
└──────────────────┬──────────────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────────────┐
│              AUDIO BACKEND ABSTRACTION                       │
│  - PulseAudio driver                                         │
│  - PipeWire driver                                           │
│  - Runtime detection + selection                             │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 Thread Architecture

Following Changies' proven multi-threaded pattern:

```
┌─────────────────────┐
│  MAIN THREAD        │
│  - GTK event loop   │
│  - UI updates       │
│  - User interaction │
└──────┬──────────────┘
       │
       │ Atomic values + Message queue
       ▼
┌─────────────────────┐
│ AUDIO THREAD        │  (Real-time priority)
│ - Buffer processing │
│ - Effect chain      │
│ - Mixing            │
│ - Metering          │
└──────┬──────────────┘
       │
       │ Non-blocking I/O
       ▼
┌─────────────────────┐
│ DISK I/O THREAD     │  (Lower priority)
│ - WAV file reading  │
│ - Project saving    │
│ - Waveform caching  │
└─────────────────────┘
```

**Thread Safety:**
- Audio thread: Lock-free reads via atomics
- UI → Audio: Command queue (SPSC ring buffer)
- Audio → UI: Stats via atomic values (RMS, peak, CPU)

### 4.3 Module Organization

Based on Ghostty's excellent structure:

```
src/
├── main.zig                    # Entry point, GTK app initialization
├── build.zig                   # Build configuration
├── build.zig.zon              # Dependencies
│
├── audio/
│   ├── engine.zig             # AudioEngine - central coordinator
│   ├── backend.zig            # Backend abstraction
│   ├── pulseaudio.zig         # PulseAudio driver
│   ├── pipewire.zig           # PipeWire driver
│   ├── track.zig              # Track (multi-channel buffer + effects)
│   ├── transport.zig          # Playback position, tempo, time signature
│   ├── mixer.zig              # Mixing algorithm
│   └── metering.zig           # RMS/Peak calculation
│
├── effects/
│   ├── chain.zig              # Effect chain orchestration
│   ├── effect.zig             # Effect interface
│   ├── highpass.zig           # HPF (from Changies)
│   ├── compressor.zig         # Compressor (from Changies)
│   ├── limiter.zig            # Limiter (from Changies)
│   ├── reverb.zig             # Freeverb implementation
│   ├── delay.zig              # Delay line
│   └── eq.zig                 # Parametric EQ (biquad filters)
│
├── dsp/
│   ├── biquad.zig             # Biquad filter implementation
│   ├── buffer.zig             # Audio buffer utilities
│   ├── ringbuffer.zig         # Lock-free ring buffer
│   └── interpolation.zig      # Sample rate conversion
│
├── project/
│   ├── project.zig            # Project data structure
│   ├── region.zig             # Audio region (clip)
│   ├── automation.zig         # Automation curves
│   ├── persistence.zig        # SQLite save/load
│   └── export.zig             # Mixdown export
│
├── ui/
│   ├── app.zig                # GTK Application wrapper
│   ├── main_window.zig        # Main window (Zig side)
│   ├── main_window_gtk.c      # GTK4 implementation
│   ├── timeline.zig           # Timeline view
│   ├── mixer.zig              # Mixer view
│   ├── transport.zig          # Transport controls
│   ├── effect_rack.zig        # Effect rack UI
│   └── meters.zig             # Level meters (Cairo drawing)
│
├── config/
│   ├── config.zig             # Configuration management
│   ├── preferences.zig        # User preferences
│   └── xdg.zig                # XDG directory resolution
│
├── command/
│   ├── command.zig            # Command pattern (undo/redo)
│   ├── dispatcher.zig         # Command dispatcher
│   └── history.zig            # Undo stack
│
└── utils/
    ├── log.zig                # Logging utilities
    ├── allocator.zig          # Memory pool for audio
    └── atomic_queue.zig       # Lock-free queue for IPC
```

### 4.4 AudioEngine Pattern

Central coordinator inspired by Changies' AudioContext:

```zig
pub const AudioEngine = struct {
    // Configuration
    config: EngineConfig,
    sample_rate: u32,           // 44100 or 48000
    buffer_size: u32,           // 256, 512, 1024, 2048

    // Backend
    backend: Backend,           // PulseAudio or PipeWire

    // Project state
    project: *Project,
    tracks: []Track,
    master_bus: MasterBus,

    // Transport
    transport: Transport,
    position: std.atomic.Value(u64),  // Sample position

    // Real-time communication
    running: std.atomic.Value(bool),
    command_queue: AtomicQueue(Command),

    // Statistics (updated by audio thread, read by UI)
    cpu_usage: std.atomic.Value(f32),
    buffer_underruns: std.atomic.Value(u64),

    // Memory management
    audio_allocator: *AudioAllocator,  // Pre-allocated pool

    pub fn process(self: *AudioEngine, output: []f32) void {
        // REAL-TIME THREAD - NO ALLOCATIONS ALLOWED

        // 1. Process commands from UI thread
        while (self.command_queue.pop()) |cmd| {
            self.executeCommand(cmd);
        }

        // 2. Advance transport
        const pos = self.transport.advance(self.buffer_size);

        // 3. Render each track
        for (self.tracks) |*track| {
            if (track.armed and self.transport.recording) {
                track.recordInput(pos, input_buffer);
            }
            if (track.solo_active or !track.muted) {
                track.render(pos, self.buffer_size, track_buffer);
            }
        }

        // 4. Mix to master
        self.master_bus.mix(self.tracks, output);

        // 5. Update metering
        self.metering.update(output);

        // 6. Update stats
        self.cpu_usage.store(calculate_cpu_usage(), .monotonic);
    }
};
```

---

## 5. Audio Backend Strategy

### 5.1 Backend Abstraction

```zig
pub const Backend = union(enum) {
    pulseaudio: PulseAudioBackend,
    pipewire: PipeWireBackend,

    pub fn init(config: BackendConfig) !Backend {
        // Runtime detection (prefer PipeWire if available)
        if (detectPipeWire()) {
            return .{ .pipewire = try PipeWireBackend.init(config) };
        } else if (detectPulseAudio()) {
            return .{ .pulseaudio = try PulseAudioBackend.init(config) };
        } else {
            return error.NoAudioBackendAvailable;
        }
    }

    pub fn start(self: *Backend, callback: AudioCallback) !void {
        switch (self.*) {
            .pulseaudio => |*pa| try pa.start(callback),
            .pipewire => |*pw| try pw.start(callback),
        }
    }
};
```

### 5.2 PulseAudio Implementation

Based on Changies' proven approach:

```zig
pub const PulseAudioBackend = struct {
    pa_input: ?*c.pa_simple,
    pa_output: ?*c.pa_simple,

    pub fn init(config: BackendConfig) !PulseAudioBackend {
        const spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = config.sample_rate,
            .channels = 2,
        };

        const buffer_attr = c.pa_buffer_attr{
            .maxlength = @sizeOf(f32) * config.buffer_size * 2,
            .tlength = @sizeOf(f32) * config.buffer_size * 2,
            .prebuf = 0,
            .minreq = @sizeOf(f32) * config.buffer_size * 2,
            .fragsize = @sizeOf(f32) * config.buffer_size * 2,
        };

        // Pre-initialize for low latency (Changies pattern)
        const pa_output = c.pa_simple_new(
            null, "DAW", c.PA_STREAM_PLAYBACK, null,
            "Output", &spec, null, &buffer_attr, null
        ) orelse return error.PulseAudioInitFailed;

        return .{ .pa_output = pa_output, .pa_input = null };
    }
};
```

### 5.3 PipeWire Implementation

```zig
pub const PipeWireBackend = struct {
    pw_loop: *c.pw_main_loop,
    pw_stream: *c.pw_stream,

    pub fn init(config: BackendConfig) !PipeWireBackend {
        c.pw_init(null, null);

        const loop = c.pw_main_loop_new(null) orelse
            return error.PipeWireInitFailed;

        // Create stream with pro audio profile
        const props = c.pw_properties_new(
            c.PW_KEY_MEDIA_TYPE, "Audio",
            c.PW_KEY_MEDIA_CATEGORY, "Playback",
            c.PW_KEY_MEDIA_ROLE, "Production",
            c.PW_KEY_NODE_LATENCY, config.latency_string,
            null,
        );

        // ... stream creation

        return .{ .pw_loop = loop, .pw_stream = stream };
    }
};
```

### 5.4 Detection Logic

From Talkies pattern:

```zig
fn detectPipeWire() bool {
    // Check for PipeWire runtime
    if (std.posix.getenv("PIPEWIRE_RUNTIME_DIR")) |_| return true;

    // Check if pipewire daemon is running
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "pw-cli", "ls", "Node" },
    }) catch return false;
    defer result.deinit();

    return result.term.Exited == 0;
}

fn detectPulseAudio() bool {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "pactl", "info" },
    }) catch return false;
    defer result.deinit();

    return result.term.Exited == 0;
}
```

---

## 6. DSP Implementation

### 6.1 Effect Chain

Directly adapted from Changies:

```zig
pub const EffectChain = struct {
    effects: std.ArrayListUnmanaged(*Effect),
    bypass: bool = false,

    pub fn process(self: *EffectChain, input: []f32, output: []f32) void {
        if (self.bypass or self.effects.items.len == 0) {
            @memcpy(output, input);
            return;
        }

        // Process through chain
        var temp_in = input;
        var temp_out: []f32 = undefined;

        for (self.effects.items, 0..) |effect, i| {
            if (!effect.enabled) continue;

            temp_out = if (i == self.effects.items.len - 1)
                output else self.getBuffer(i);

            effect.process(temp_in, temp_out);
            temp_in = temp_out;
        }

        if (temp_out.ptr != output.ptr) {
            @memcpy(output, temp_out);
        }
    }
};
```

### 6.2 Effect Interface

```zig
pub const Effect = struct {
    vtable: *const VTable,
    enabled: bool = true,

    pub const VTable = struct {
        process: *const fn(self: *Effect, input: []f32, output: []f32) void,
        reset: *const fn(self: *Effect) void,
        setParameter: *const fn(self: *Effect, param: Parameter) void,
    };

    pub fn process(self: *Effect, input: []f32, output: []f32) void {
        self.vtable.process(self, input, output);
    }
};
```

### 6.3 Compressor (from Changies)

```zig
pub const Compressor = struct {
    effect: Effect,

    // Parameters
    threshold: f32 = -20.0,     // dBFS
    ratio: f32 = 4.0,           // 4:1
    attack_ms: f32 = 5.0,
    release_ms: f32 = 50.0,
    makeup_gain: f32 = 0.0,     // dB

    // State
    envelope: f32 = 0.0,
    attack_coef: f32,
    release_coef: f32,
    sample_rate: f32,

    pub fn process(effect: *Effect, input: []f32, output: []f32) void {
        const self: *Compressor = @fieldParentPtr("effect", effect);

        const threshold_linear = dbToLinear(self.threshold);

        for (input, output) |in_sample, *out_sample| {
            const input_level = @abs(in_sample);

            // Envelope follower
            const coef = if (input_level > self.envelope)
                self.attack_coef else self.release_coef;
            self.envelope = coef * (self.envelope - input_level) + input_level;

            // Calculate gain reduction
            var gain: f32 = 1.0;
            if (self.envelope > threshold_linear) {
                const overshoot = self.envelope / threshold_linear;
                gain = std.math.pow(f32, overshoot, (1.0 / self.ratio) - 1.0);
            }

            // Apply gain + makeup
            const makeup_linear = dbToLinear(self.makeup_gain);
            out_sample.* = in_sample * gain * makeup_linear;
        }
    }
};
```

---

## 7. UI Implementation

### 7.1 GTK4 Integration Pattern

Based on Talkies' C/Zig layering:

**main_window_gtk.h:**
```c
typedef struct MainWindow MainWindow;

MainWindow* main_window_new(void);
void main_window_show(MainWindow *win);
void main_window_update_transport(MainWindow *win, bool playing, double position);
void main_window_update_meters(MainWindow *win, const float *levels, int count);
```

**main_window.zig:**
```zig
pub const MainWindow = opaque {
    extern fn main_window_new() ?*MainWindow;
    extern fn main_window_show(win: *MainWindow) void;
    extern fn main_window_update_transport(win: *MainWindow, playing: bool, pos: f64) void;
    extern fn main_window_update_meters(win: *MainWindow, levels: [*]const f32, count: c_int) void;

    pub fn create() !*MainWindow {
        return main_window_new() orelse error.GTKInitFailed;
    }
};
```

### 7.2 Level Meters

Inspired by Changies' web UI meters:

```c
// main_window_gtk.c - Cairo drawing
static void draw_meter(GtkDrawingArea *area, cairo_t *cr,
                       int width, int height, gpointer user_data) {
    MeterData *data = user_data;

    // Background
    cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);

    // Level bar with color zones
    int bar_height = (int)(data->level * height);

    // Green zone (0 to -18dB)
    if (bar_height > 0) {
        cairo_set_source_rgb(cr, 0.2, 0.8, 0.2);
        cairo_rectangle(cr, 0, height - bar_height, width,
                       MIN(bar_height, height * 0.7));
        cairo_fill(cr);
    }

    // Yellow zone (-18 to -6dB)
    if (bar_height > height * 0.7) {
        cairo_set_source_rgb(cr, 0.8, 0.8, 0.2);
        cairo_rectangle(cr, 0, height * 0.3, width,
                       MIN(bar_height - height * 0.7, height * 0.2));
        cairo_fill(cr);
    }

    // Red zone (-6dB to 0dB)
    if (bar_height > height * 0.9) {
        cairo_set_source_rgb(cr, 0.8, 0.2, 0.2);
        cairo_rectangle(cr, 0, 0, width, bar_height - height * 0.9);
        cairo_fill(cr);
    }
}
```

### 7.3 Timeline View

```c
static void draw_timeline(GtkDrawingArea *area, cairo_t *cr,
                         int width, int height, gpointer user_data) {
    TimelineData *data = user_data;

    // Draw waveform for each region
    for (int i = 0; i < data->region_count; i++) {
        Region *region = &data->regions[i];
        draw_waveform(cr, region, data->zoom, data->scroll_offset);
    }

    // Draw playhead
    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    int playhead_x = (data->playhead_pos - data->scroll_offset) * data->zoom;
    cairo_move_to(cr, playhead_x, 0);
    cairo_line_to(cr, playhead_x, height);
    cairo_stroke(cr);
}
```

---

## 8. Configuration Management

Based on Talkies' TOML pattern:

### 8.1 Config File Structure

**~/.config/daw/config.toml:**
```toml
[audio]
backend = "auto"           # auto, pulseaudio, pipewire
sample_rate = 48000        # 44100, 48000, 96000
buffer_size = 512          # 128, 256, 512, 1024, 2048
input_device = ""          # Empty = default
output_device = ""

[project]
default_sample_rate = 48000
default_bit_depth = 24
auto_save_interval = 300   # seconds
recent_projects_count = 10
default_project_dir = "~/Music/DAW Projects"

[ui]
theme = "dark"
show_grid = true
snap_enabled = true
snap_mode = "bar"          # bar, beat, sample
meter_decay_rate = 0.95

[display]
waveform_color = "#4A9EFF"
background_color = "#1E1E1E"
grid_color = "#3E3E3E"
```

### 8.2 Config Module

```zig
pub const Config = struct {
    audio: AudioConfig,
    project: ProjectConfig,
    ui: UIConfig,
    display: DisplayConfig,

    pub fn load(allocator: Allocator) !Config {
        const config_path = try xdg.getConfigPath(allocator, "daw/config.toml");
        defer allocator.free(config_path);

        // Create default if doesn't exist
        if (!fileExists(config_path)) {
            const default_config = Config.default();
            try default_config.save(allocator);
            return default_config;
        }

        // Parse TOML
        const file_contents = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
        defer allocator.free(file_contents);

        return try parseToml(Config, file_contents);
    }
};
```

---

## 9. Project Persistence

### 9.1 SQLite Schema

```sql
-- projects.db

CREATE TABLE projects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    sample_rate INTEGER NOT NULL,
    bit_depth INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE TABLE tracks (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    color TEXT,
    volume REAL DEFAULT 1.0,
    pan REAL DEFAULT 0.0,
    muted BOOLEAN DEFAULT 0,
    armed BOOLEAN DEFAULT 0,
    track_index INTEGER NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE TABLE regions (
    id INTEGER PRIMARY KEY,
    track_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    audio_file_path TEXT NOT NULL,
    start_position INTEGER NOT NULL,  -- samples
    length INTEGER NOT NULL,          -- samples
    fade_in INTEGER DEFAULT 0,
    fade_out INTEGER DEFAULT 0,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);

CREATE TABLE effects (
    id INTEGER PRIMARY KEY,
    track_id INTEGER NOT NULL,
    effect_type TEXT NOT NULL,
    parameters TEXT NOT NULL,         -- JSON blob
    enabled BOOLEAN DEFAULT 1,
    effect_index INTEGER NOT NULL,
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
);
```

### 9.2 Project Directory Structure

```
~/Music/DAW Projects/My Song/
├── project.db              # SQLite database
├── audio/
│   ├── track1_take1.wav
│   ├── track1_take2.wav
│   └── track2_take1.wav
├── cache/
│   ├── waveform_cache/
│   │   ├── track1_take1.png
│   │   └── track2_take1.png
│   └── audio_cache/        # Resampled files
└── exports/
    └── mixdown_2025-12-20.wav
```

---

## 10. Build System

### 10.1 build.zig

Following Ghostty's patterns:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable
    const exe = b.addExecutable(.{
        .name = "daw",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C sources for GTK4
    exe.addCSourceFile(.{
        .file = b.path("src/ui/main_window_gtk.c"),
        .flags = &.{"-std=c11"},
    });

    // System libraries
    exe.linkLibC();
    exe.linkSystemLibrary("gtk-4");
    exe.linkSystemLibrary("glib-2.0");
    exe.linkSystemLibrary("gobject-2.0");
    exe.linkSystemLibrary("cairo");
    exe.linkSystemLibrary("pulse");
    exe.linkSystemLibrary("pulse-simple");
    exe.linkSystemLibrary("pipewire-0.3");
    exe.linkSystemLibrary("sqlite3");

    // Build options
    const simd = b.option(bool, "simd", "Enable SIMD optimizations") orelse true;
    const backend = b.option([]const u8, "backend", "Audio backend (auto/pulse/pipewire)") orelse "auto";

    exe.root_module.addOptions("build_options", b.addOptions()
        .addOption(bool, "simd", simd)
        .addOption([]const u8, "backend", backend));

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the DAW");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

### 10.2 build.zig.zon

```zig
.{
    .name = "daw",
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",

    .dependencies = .{},

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "README.md",
    },
}
```

---

## 11. Testing Strategy

### 11.1 Unit Tests

Following Ghostty's embedded test pattern:

```zig
// In src/dsp/biquad.zig
test "highpass filter attenuates low frequencies" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var filter = BiquadFilter.initHighpass(48000, 1000.0, 0.707);

    // Generate 100Hz sine wave
    var input: [480]f32 = undefined;
    for (&input, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        sample.* = @sin(2.0 * std.math.pi * 100.0 * t);
    }

    var output: [480]f32 = undefined;
    for (input, &output) |in, *out| {
        out.* = filter.process(in);
    }

    // Output should be significantly attenuated
    const input_rms = calculateRMS(&input);
    const output_rms = calculateRMS(&output);
    try testing.expect(output_rms < input_rms * 0.1);
}
```

### 11.2 Integration Tests

```zig
test "audio engine processes buffer correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var engine = try AudioEngine.init(alloc, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    // Add test track
    var track = try engine.addTrack("Test Track");
    track.armed = true;

    // Process empty buffer
    var output: [1024]f32 = std.mem.zeroes([1024]f32);
    engine.process(&output);

    // Verify silence
    for (output) |sample| {
        try testing.expectEqual(@as(f32, 0.0), sample);
    }
}
```

### 11.3 Manual Testing Checklist

- [ ] Record audio from multiple sources simultaneously
- [ ] Playback with <10ms latency
- [ ] Effect parameters respond in real-time
- [ ] No audio dropouts during normal operation
- [ ] Save/load project preserves all state
- [ ] Undo/redo works across all operations
- [ ] Meters show accurate levels
- [ ] CPU usage stays below 50% during playback

---

## 12. Performance Requirements

### 12.1 Real-Time Constraints

| Metric | Target | Critical |
|--------|--------|----------|
| **Audio latency** | <10ms | <20ms |
| **CPU usage** (4 tracks + effects) | <30% | <60% |
| **Memory usage** | <500MB | <1GB |
| **UI responsiveness** | <16ms (60fps) | <33ms (30fps) |
| **Project load time** | <2s | <5s |
| **Buffer underruns** | 0/hour | <1/hour |

### 12.2 Zero-Allocation Hot Path

Following Changies' pattern:

```zig
pub fn process(self: *AudioEngine, output: []f32) void {
    // NO ALLOCATIONS ALLOWED IN THIS FUNCTION
    // All buffers pre-allocated at startup

    const start_time = std.time.nanoTimestamp();

    // Process audio...

    const end_time = std.time.nanoTimestamp();
    const processing_time_us = @divTrunc(end_time - start_time, 1000);

    self.stats.processing_time_us.store(processing_time_us, .monotonic);
}
```

---

## 13. Code Quality Standards

### 13.1 Formatting

Following Ghostty:
- **Zig:** `zig fmt` (automatic)
- **C:** `.clang-format` (80-column limit)
- **TOML:** Prettier

### 13.2 Documentation

```zig
//! Audio engine module
//!
//! Provides real-time audio processing with track rendering,
//! effect chains, and mixing.

/// Initialize the audio engine with the given configuration.
///
/// This function pre-allocates all buffers and initializes the
/// audio backend (PulseAudio or PipeWire).
///
/// Returns error.NoAudioBackend if no backend is available.
pub fn init(allocator: Allocator, config: EngineConfig) !AudioEngine {
    // ...
}
```

### 13.3 Error Handling

```zig
pub const EngineError = error{
    NoAudioBackend,
    BackendInitFailed,
    InvalidSampleRate,
    InvalidBufferSize,
    AllocationFailed,
};

// Propagate with context
fn initBackend(config: Config) !Backend {
    return Backend.init(config) catch |err| {
        log.err("Failed to initialize audio backend: {}", .{err});
        return err;
    };
}
```

---

## 14. Development Workflow

### 14.1 Build Commands

```bash
# Development build
zig build

# Run
zig build run

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run specific test
zig build test -Dtest-filter="biquad"

# Format code
zig fmt src/
```

### 14.2 CI/CD Pipeline

GitHub Actions (from Ghostty):

```yaml
name: CI

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.16.0

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libgtk-4-dev \
            libpulse-dev \
            libpipewire-0.3-dev \
            libsqlite3-dev

      - name: Format check
        run: zig fmt --check src/

      - name: Build
        run: zig build

      - name: Test
        run: zig build test
```

---

## 15. Documentation

### 15.1 Documentation Structure

Following Ghostty:

```
docs/
├── README.md               # Overview, installation
├── CONTRIBUTING.md         # Contribution guidelines
├── HACKING.md              # Development guide
├── ARCHITECTURE.md         # Technical architecture
├── API.md                  # Public API reference
└── AGENTS.md               # AI assistant guide
```

### 15.2 README.md Template

```markdown
# DAW for Linux

A simple, high-quality Digital Audio Workstation built with Zig and GTK4.

## Features

- Multi-track recording and playback
- Real-time effects (reverb, delay, compression, EQ)
- Low-latency audio (<10ms)
- PulseAudio and PipeWire support
- GTK4 native interface

## Installation

### Dependencies

- Zig 0.16+
- GTK4 4.10+
- PulseAudio or PipeWire
- SQLite3

### Build from source

```bash
git clone https://github.com/yourusername/daw.git
cd daw
zig build -Doptimize=ReleaseFast
sudo zig build install
```

## Quick Start

```bash
# Run the DAW
daw

# Specify audio backend
daw --backend=pipewire

# Set buffer size
daw --buffer-size=256
```

## License

MIT
```

---

## 16. Success Metrics

### 16.1 MVP Success Criteria

- [ ] Record and play back 4 simultaneous tracks
- [ ] Apply effects in real-time without dropouts
- [ ] Save and load projects reliably
- [ ] Achieve <10ms latency on typical hardware
- [ ] Run for 1 hour without crashes or memory leaks
- [ ] Build completes in <30 seconds
- [ ] All unit tests pass
- [ ] Works on both PulseAudio and PipeWire systems

### 16.2 Code Quality Metrics

- [ ] Test coverage >70%
- [ ] Zero Valgrind errors
- [ ] Zero compiler warnings
- [ ] All public APIs documented
- [ ] CLAUDE.md created for development guidance

---

## 17. Non-Goals (Out of Scope for MVP)

- MIDI support (future version)
- VST/LV2 plugin hosting (future version)
- Advanced editing (time stretching, pitch shifting)
- Video support
- Network collaboration
- Cloud storage integration
- Mobile/tablet support
- Notation/score view
- Sample library management
- Advanced automation (curves, LFOs)

---

## 18. Timeline & Milestones

### Phase 1: Foundation (Weeks 1-2)
- [ ] Project setup (build system, CI/CD)
- [ ] Audio backend abstraction
- [ ] PulseAudio driver implementation
- [ ] Basic GTK4 window
- [ ] Configuration management

### Phase 2: Core Audio (Weeks 3-4)
- [ ] Audio engine with track rendering
- [ ] Transport controls
- [ ] Recording functionality
- [ ] Playback functionality
- [ ] Level metering

### Phase 3: Effects (Week 5)
- [ ] Effect chain architecture
- [ ] Basic effects (HPF, compressor, limiter)
- [ ] Reverb and delay
- [ ] Parametric EQ

### Phase 4: UI (Week 6)
- [ ] Timeline view with waveforms
- [ ] Mixer view
- [ ] Transport controls UI
- [ ] Effect rack UI

### Phase 5: Project Management (Week 7)
- [ ] SQLite persistence
- [ ] Save/load projects
- [ ] WAV import/export
- [ ] Undo/redo system

### Phase 6: Polish (Week 8)
- [ ] PipeWire driver
- [ ] Performance optimization
- [ ] Bug fixes
- [ ] Documentation
- [ ] Testing

---

## 19. Risk Mitigation

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| PipeWire API instability | High | Medium | Maintain PulseAudio fallback |
| Real-time performance issues | High | Medium | Profile early, pre-allocate everything |
| GTK4 Zig bindings complexity | Medium | Medium | Keep C layer thin, reference Talkies |
| Scope creep | High | High | Strict adherence to MVP features |
| Audio dropout bugs | High | Medium | Comprehensive stress testing |

---

## 20. References

### Inspiration Projects
- **Changies** (`~/changies`) - Real-time audio processing, effect chain
- **Ghostty** (`~/ghostty`) - Code quality, build system, documentation
- **Talkies** (`~/talkies/linux`) - GTK4 integration, Linux patterns

### Key Design Patterns
- **AudioContext** (Changies) → AudioEngine
- **Effect Chain** (Changies) → EffectChain
- **C/Zig Layering** (Talkies) → UI implementation
- **State Machine** (Talkies) → Transport state
- **Pre-allocation** (Changies) → Real-time performance

### Documentation Standards
- **CLAUDE.md** (Changies) - Comprehensive development guide
- **HACKING.md** (Ghostty) - Developer onboarding
- **CONTRIBUTING.md** (Ghostty) - Contribution workflow

---

## 21. Appendix

### A. Audio Terminology

- **Sample Rate**: Samples per second (44.1kHz, 48kHz, 96kHz)
- **Buffer Size**: Number of samples processed per callback (256, 512, 1024)
- **Latency**: Time from input to output (depends on buffer size and backend)
- **dBFS**: Decibels relative to full scale (0dB = maximum digital level)
- **RMS**: Root Mean Square (average signal level)
- **Peak**: Maximum absolute value in a buffer

### B. DSP Formulas

**dB to Linear:**
```
linear = 10^(dB / 20)
```

**Linear to dB:**
```
dB = 20 * log10(linear)
```

**RMS Calculation:**
```
RMS = sqrt(sum(sample^2) / count)
```

**Attack/Release Coefficients:**
```
coef = exp(-1 / (time_ms * sample_rate / 1000))
```

### C. Useful Resources

- Zig Language Reference: https://ziglang.org/documentation/master/
- GTK4 Documentation: https://docs.gtk.org/gtk4/
- PipeWire Documentation: https://docs.pipewire.org/
- PulseAudio Simple API: https://freedesktop.org/software/pulseaudio/doxygen/
- Digital Audio Signal Processing: https://ccrma.stanford.edu/~jos/

---

**Document Control:**
- **Author:** [Your Name]
- **Reviewers:** [TBD]
- **Last Updated:** 2025-12-20
- **Next Review:** After Phase 1 completion
