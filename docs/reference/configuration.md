# Configuration Reference

## Configuration Files

The DAW follows XDG Base Directory specifications for configuration storage.

### File Locations

```
~/.config/daw/           # XDG_CONFIG_HOME
├── config.toml          # Main configuration file
└── recent.json          # Recent projects list (planned)

~/.local/share/daw/      # XDG_DATA_HOME
├── projects/            # Project databases (planned)
└── cache/               # Waveform cache (planned)

~/.local/state/daw/      # XDG_STATE_HOME
└── logs/                # Application logs (planned)
```

## Configuration File Format

Configuration is stored in TOML format at `~/.config/daw/config.toml`.

### Default Configuration

```toml
[audio]
backend = "auto"           # auto, pulseaudio, pipewire
sample_rate = 48000        # 44100, 48000, 96000
buffer_size = 512          # 128, 256, 512, 1024, 2048
input_device = ""          # Empty = default device
output_device = ""         # Empty = default device

[project]
default_sample_rate = 48000
default_bit_depth = 24      # 16, 24
auto_save_interval = 300    # seconds (0 = disabled)
recent_projects_count = 10
default_project_dir = "~/Music/DAW Projects"

[ui]
theme = "tokyo-night"       # tokyo-night (only option currently)
show_grid = true
snap_enabled = true
snap_mode = "bar"           # bar, beat, sample
meter_decay_rate = 0.95     # 0.0-1.0
update_rate_ms = 100        # UI update interval

[display]
waveform_color = "#7aa2f7"  # Tokyo Night blue
background_color = "#1a1b26" # Tokyo Night background
grid_color = "#292e42"      # Tokyo Night subtle
playhead_color = "#f7768e"  # Tokyo Night red
```

## Configuration Options Reference

### Audio Section

#### `backend`
- **Type:** String
- **Default:** `"auto"`
- **Options:** `"auto"`, `"pulseaudio"`, `"pipewire"`
- **Description:** Audio backend selection. `"auto"` tries PipeWire first, falls back to PulseAudio.

**Note:** PipeWire backend is currently a stub - use `"pulseaudio"` for working audio.

#### `sample_rate`
- **Type:** Integer
- **Default:** `48000`
- **Options:** `44100`, `48000`, `96000`
- **Description:** Audio sample rate in Hz. Higher rates = better quality, more CPU usage.

**Common Values:**
- `44100` - CD quality
- `48000` - Professional standard (recommended)
- `96000` - High-resolution audio

#### `buffer_size`
- **Type:** Integer
- **Default:** `512`
- **Options:** `128`, `256`, `512`, `1024`, `2048`
- **Description:** Audio buffer size in samples. Affects latency vs. stability trade-off.

**Latency Calculation:**
```
Latency (ms) = (buffer_size / sample_rate) * 1000

Examples @ 48kHz:
- 128 samples = 2.7ms
- 256 samples = 5.3ms
- 512 samples = 10.7ms (default)
- 1024 samples = 21.3ms
- 2048 samples = 42.7ms
```

**Guidelines:**
- `128-256`: Ultra-low latency, requires powerful CPU
- `512`: Good balance (recommended)
- `1024-2048`: More stable, higher latency

#### `input_device` / `output_device`
- **Type:** String
- **Default:** `""` (empty = system default)
- **Description:** Specific audio device names. Empty string uses system default.

**Finding Device Names:**
```bash
# PulseAudio
pactl list short sinks     # Output devices
pactl list short sources   # Input devices

# PipeWire
pw-cli list-objects | grep node.name
```

### Project Section

#### `default_sample_rate`
- **Type:** Integer
- **Default:** `48000`
- **Description:** Sample rate for new projects

#### `default_bit_depth`
- **Type:** Integer
- **Default:** `24`
- **Options:** `16`, `24`
- **Description:** Bit depth for new recordings/projects

#### `auto_save_interval`
- **Type:** Integer (seconds)
- **Default:** `300` (5 minutes)
- **Description:** Auto-save interval. Set to `0` to disable.

#### `recent_projects_count`
- **Type:** Integer
- **Default:** `10`
- **Description:** Number of recent projects to remember

#### `default_project_dir`
- **Type:** String (path)
- **Default:** `"~/Music/DAW Projects"`
- **Description:** Default directory for new projects. Tilde (~) expands to home directory.

### UI Section

#### `theme`
- **Type:** String
- **Default:** `"tokyo-night"`
- **Options:** `"tokyo-night"`
- **Description:** Color theme. Currently only Tokyo Night is implemented.

#### `show_grid`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Show grid lines in timeline

#### `snap_enabled`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable snap-to-grid for editing

#### `snap_mode`
- **Type:** String
- **Default:** `"bar"`
- **Options:** `"bar"`, `"beat"`, `"sample"`
- **Description:** Grid snap resolution

#### `meter_decay_rate`
- **Type:** Float (0.0-1.0)
- **Default:** `0.95`
- **Description:** Meter decay rate. Higher = slower decay. 1.0 = no decay.

#### `update_rate_ms`
- **Type:** Integer (milliseconds)
- **Default:** `100`
- **Range:** `16-1000`
- **Description:** UI update interval. Lower = smoother, higher CPU usage.

**Common Values:**
- `16` - 60 FPS (smooth but high CPU)
- `33` - 30 FPS
- `100` - 10 FPS (default, good balance)

### Display Section

All colors use hexadecimal format: `"#RRGGBB"`

#### `waveform_color`
- **Default:** `"#7aa2f7"` (Tokyo Night blue)
- **Description:** Color for audio waveforms and regions

#### `background_color`
- **Default:** `"#1a1b26"` (Tokyo Night background)
- **Description:** Main background color

#### `grid_color`
- **Default:** `"#292e42"` (Tokyo Night subtle)
- **Description:** Timeline grid line color

#### `playhead_color`
- **Default:** `"#f7768e"` (Tokyo Night red)
- **Description:** Playhead/cursor color

## Command-Line Arguments

Command-line arguments override configuration file settings.

### Usage

```bash
./zig-out/bin/daw [OPTIONS]
```

### Available Options

#### `--backend=<name>`
Override audio backend selection.
```bash
./zig-out/bin/daw --backend=pulse
./zig-out/bin/daw --backend=pipewire
```

#### `--buffer-size=<samples>`
Override buffer size.
```bash
./zig-out/bin/daw --buffer-size=256
./zig-out/bin/daw --buffer-size=1024
```

#### `--sample-rate=<hz>`
Override sample rate (planned).
```bash
./zig-out/bin/daw --sample-rate=44100
```

## Environment Variables

### `XDG_CONFIG_HOME`
- **Default:** `~/.config`
- **Description:** Override config directory location

**Example:**
```bash
XDG_CONFIG_HOME=/tmp/config ./zig-out/bin/daw
# Looks for config at: /tmp/config/daw/config.toml
```

### `XDG_DATA_HOME`
- **Default:** `~/.local/share`
- **Description:** Override data directory location

### `XDG_STATE_HOME`
- **Default:** `~/.local/state`
- **Description:** Override state directory location

## Creating a Configuration File

### Automatic Creation

If no configuration file exists, the DAW uses built-in defaults. To create a configuration file:

```bash
# 1. Create config directory
mkdir -p ~/.config/daw

# 2. Create config file
cat > ~/.config/daw/config.toml << 'EOF'
[audio]
backend = "auto"
sample_rate = 48000
buffer_size = 512

[ui]
theme = "tokyo-night"
update_rate_ms = 100
EOF

# 3. Run DAW - it will use your config
./zig-out/bin/daw
```

### Validation

The DAW validates configuration on startup. Invalid values will:
1. Log a warning
2. Fall back to default values

**Check logs:**
```bash
./zig-out/bin/daw 2>&1 | grep -i "config\|warning"
```

## Configuration Examples

### Low-Latency Setup

```toml
[audio]
backend = "pulseaudio"
sample_rate = 48000
buffer_size = 256  # ~5ms latency

[ui]
update_rate_ms = 16  # 60 FPS for smoother meters
```

### Stable/Conservative Setup

```toml
[audio]
backend = "pulseaudio"
sample_rate = 48000
buffer_size = 1024  # ~21ms latency, very stable

[ui]
update_rate_ms = 100  # Lower CPU usage
```

### High-Resolution Audio

```toml
[audio]
backend = "pulseaudio"
sample_rate = 96000
buffer_size = 1024  # ~11ms latency at 96kHz

[project]
default_sample_rate = 96000
default_bit_depth = 24
```

---

**Last Updated:** 2025-12-20
