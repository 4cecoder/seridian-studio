# Platform Compatibility Matrix

This document provides a comprehensive overview of platform support, feature availability, and known limitations for the DAW across different operating systems.

## Quick Reference

| Platform | Status | Audio | MIDI | UI | Build Tool | Production Ready |
|----------|--------|-------|------|----|-----------|--------------------|
| Linux    | ✓ Full Support | PulseAudio, PipeWire (stub) | None (planned) | GTK4 | Zig 0.18+ | Yes |
| macOS    | ✓ Full Support | CoreAudio | CoreMIDI | GTK4 | Zig 0.18+ | Yes |
| Windows  | ✗ Not Supported | - | - | - | - | No |

## Platform Support Matrix

### Linux

#### Audio Backends

| Backend | Status | Implementation | Quality | Notes |
|---------|--------|---------------|---------|-------|
| PulseAudio | ✓ Full | Complete | Production | Recommended, stable |
| PipeWire | ⚠ Stub | Minimal | Development | Stub only, falls back to PulseAudio |
| ALSA | ✗ Not Planned | - | - | No direct support, use PulseAudio |
| JACK | ✗ Not Planned | - | - | No support planned |

**Backend Detection:** Automatic runtime detection with fallback chain:
1. Check user preference (CLI flag or config)
2. Try PulseAudio (`pactl info`)
3. Fall back to PipeWire (if detected via `pw-cli`)
4. Error if neither available

**Force specific backend:**
```bash
./zig-out/bin/daw --backend=pulse
zig build -Dbackend=pulse
```

#### MIDI Backends

| Backend | Status | Implementation | Quality | Notes |
|---------|--------|---------------|---------|-------|
| ALSA MIDI | ✗ Planned | None | - | Tracked in roadmap |
| JACK MIDI | ✗ Not Planned | - | - | No support planned |

#### UI Backend

| Backend | Status | Wayland | X11 | Notes |
|---------|--------|---------|-----|-------|
| GTK4 | ✓ Full | ✓ | ✓ | Auto-detects compositor |

**Window Manager Compatibility:**
- GNOME: ✓ Full support
- KDE Plasma: ✓ Full support
- Hyprland: ✓ Fixed in v0.4 (removed HeaderBar)
- i3/sway: ✓ Full support (no CSD issues)
- bspwm: ✓ Full support
- dwm/xmonad: ✓ Expected to work

#### Build Dependencies

| Package | Required Version | Gentoo | Arch | Ubuntu/Debian |
|---------|------------------|--------|------|---------------|
| Zig | 0.18.0+ (master) | Manual install | `zig` | Manual install |
| GTK4 | 4.10+ | `gui-libs/gtk` | `gtk4` | `libgtk-4-dev` |
| GLib | 2.0+ | Auto (GTK dep) | Auto | `libglib2.0-dev` |
| Cairo | Latest | `x11-libs/cairo` | `cairo` | `libcairo2-dev` |
| PulseAudio | Latest | `media-sound/pulseaudio` | `pulseaudio` | `libpulse-dev` |
| PipeWire | 0.3+ (optional) | `media-video/pipewire` | `pipewire` | `libpipewire-0.3-dev` |

**Installation Commands:**

Gentoo/Funtoo:
```bash
emerge -av dev-lang/zig gui-libs/gtk x11-libs/cairo media-sound/pulseaudio
```

Arch Linux:
```bash
sudo pacman -S zig gtk4 cairo pulseaudio
```

Ubuntu/Debian:
```bash
sudo apt install zig libgtk-4-dev libcairo2-dev libpulse-dev
```

#### Known Limitations

- **PipeWire backend:** Currently a stub, falls back to PulseAudio
- **MIDI support:** Not implemented (Linux ALSA MIDI planned)
- **Zig version:** Must use 0.18.0+ (master/nightly), older versions incompatible

#### Testing Status

| Feature | Tested | Status | Notes |
|---------|--------|--------|-------|
| Audio playback (PulseAudio) | ✓ | Stable | Production quality |
| Audio playback (PipeWire) | ✗ | Stub | Not functional |
| UI rendering (Wayland) | ✓ | Stable | GNOME, Hyprland tested |
| UI rendering (X11) | ✓ | Stable | i3, KDE tested |
| Multi-track mixing | ✓ | Stable | 4 tracks tested |
| Level metering | ✓ | Stable | Real-time updates |
| File I/O | ✓ | Stable | WAV loading/export |
| MIDI input | ✗ | Not implemented | - |

---

### macOS

#### Audio Backends

| Backend | Status | Implementation | Quality | Notes |
|---------|--------|---------------|---------|-------|
| CoreAudio | ✓ Full | Complete | Production | Only backend on macOS |
| PulseAudio | ✗ Not Available | - | - | Linux-only |
| PipeWire | ✗ Not Available | - | - | Linux-only |

**Backend Selection:** CoreAudio is automatically selected on macOS. No fallback needed.

**Framework Dependencies:**
- AudioToolbox
- CoreAudio
- CoreFoundation
- AudioUnit

#### MIDI Backends

| Backend | Status | Implementation | Quality | Notes |
|---------|--------|---------------|---------|-------|
| CoreMIDI | ✓ Full | Complete | Production | Native macOS MIDI |

**CoreMIDI Features:**
- Input port creation and source connection
- Output port for MIDI playback
- Event parsing (Note On/Off, CC, PC, Pitch Bend)
- Multi-source support
- Device enumeration

#### UI Backend

| Backend | Status | Notes |
|---------|--------|-------|
| GTK4 | ✓ Full | Via Homebrew |

**Display Server Compatibility:**
- Quartz (native): ✓ Full support via GTK4 backend

#### Build Dependencies

| Package | Required Version | Homebrew | Notes |
|---------|------------------|----------|-------|
| Zig | 0.18.0+ (master) | Manual install | Download from ziglang.org |
| GTK4 | 4.20.3+ | `brew install gtk4` | Includes GLib, Cairo |
| Cairo | 1.18.4+ | Auto (GTK dep) | - |
| GLib | 2.86.3+ | Auto (GTK dep) | - |
| Pango | 1.57.0+ | Auto (GTK dep) | - |
| Harfbuzz | 12.2.0+ | Auto (GTK dep) | - |

**Installation Commands:**

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install GTK4 (includes dependencies)
brew install gtk4

# Install Zig 0.18+ (master)
# Download from: https://ziglang.org/download/
# Extract and add to PATH
```

**Important Build Notes:**
- Uses system linker (ld64) instead of LLD to avoid duplicate dylib issues
- GTK4 paths are hardcoded for `/opt/homebrew/` (Apple Silicon) in build.zig
- Library search paths automatically configured for Homebrew

#### Known Limitations

- **GTK4 integration:** Requires Homebrew installation (no native Cocoa UI)
- **Homebrew paths:** build.zig assumes Apple Silicon paths (`/opt/homebrew/`)
- **Linker:** Must use system linker (not LLD) for proper dependency resolution

#### Testing Status

| Feature | Tested | Status | Notes |
|---------|--------|--------|-------|
| Audio playback (CoreAudio) | ✓ | Stable | Production quality |
| MIDI input (CoreMIDI) | ✓ | Stable | Full implementation |
| MIDI output (CoreMIDI) | ✓ | Stable | Note On/Off tested |
| UI rendering (GTK4) | ✓ | Stable | Quartz backend |
| Multi-track mixing | ✓ | Stable | 4 tracks tested |
| Level metering | ✓ | Stable | Real-time updates |
| File I/O | ✓ | Stable | WAV loading/export |

---

### Windows

#### Status

**Not Supported** - No implementation planned for Windows at this time.

#### What Would Be Required

If Windows support were to be added in the future:

**Audio Backends:**
- WASAPI (Windows Audio Session API) - Primary
- DirectSound - Legacy fallback

**MIDI Backends:**
- Windows Multimedia API (MMSYSTEM)
- Or UWP MIDI APIs (Windows 10+)

**UI Backend:**
- GTK4 for Windows (via MSYS2/MinGW)
- Or native Win32 API implementation

**Build Tool:**
- Zig 0.18+ (cross-compilation possible from Linux/macOS)

**Challenges:**
- GTK4 on Windows requires MSYS2/MinGW runtime
- Audio backend would need complete rewrite
- MIDI backend would need complete rewrite
- Build system would need Windows-specific configuration
- Testing infrastructure for Windows platform

---

## Build Tool Requirements

### Zig Version

**Required:** Zig 0.18.0-dev (master/nightly)

**Why Zig master:**
- New build API (`b.createModule()`, `.root_module`)
- Updated `build.zig.zon` format (requires `.fingerprint`)
- Breaking changes from 0.13/0.14/0.15

**Installation:**

Download latest Zig 0.18+ master build:
- https://ziglang.org/download/

**Verify version:**
```bash
zig version
# Should show: 0.18.0-dev.XXXX+HASH
```

### Build System Features

**Cross-Platform Configuration:**
- Platform detection: `target.result.os.tag`
- Conditional compilation: `builtin.os.tag`
- Platform-specific modules: `configureMacOSModule()`, `configureLinuxModule()`

**Compile-Time Options:**
```bash
# SIMD optimizations (default: enabled)
zig build -Dsimd=true|false

# Audio backend selection
zig build -Dbackend=auto|pulse|pipewire|coreaudio

# Optimization level
zig build -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall
```

**Build Targets:**
```bash
zig build              # Build debug binary
zig build run          # Build and run
zig build test         # Run unit tests
zig build -Doptimize=ReleaseFast  # Optimized release
```

---

## Quick Start by Platform

### Linux Quick Start

**Prerequisites:**
```bash
# Gentoo/Funtoo
emerge -av dev-lang/zig gui-libs/gtk x11-libs/cairo media-sound/pulseaudio

# Arch Linux
sudo pacman -S zig gtk4 cairo pulseaudio

# Ubuntu/Debian
sudo apt install zig libgtk-4-dev libcairo2-dev libpulse-dev
```

**Build and Run:**
```bash
git clone https://github.com/4cecoder/daw
cd daw
zig build run
```

**Troubleshooting:**
- No audio: Verify PulseAudio is running (`pactl info`)
- GTK errors: Install `adwaita-icon-theme` package
- Wayland issues: Try `GDK_BACKEND=x11 ./zig-out/bin/daw`

---

### macOS Quick Start

**Prerequisites:**
```bash
# Install Homebrew (if needed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install GTK4
brew install gtk4

# Download Zig 0.18+ from https://ziglang.org/download/
# Extract and add to PATH
```

**Build and Run:**
```bash
git clone https://github.com/4cecoder/daw
cd daw
zig build run
```

**Troubleshooting:**
- Linker errors: Ensure using system linker (check build.zig: `use_lld = false`)
- GTK errors: Verify Homebrew GTK4 installed (`brew list gtk4`)
- Audio issues: CoreAudio should "just work" - check Console.app for errors

---

### Windows Quick Start

**Not Supported** - Windows is not currently a supported platform.

---

## Platform-Specific Quirks

### Linux

**PulseAudio vs PipeWire:**
- PipeWire can provide PulseAudio compatibility layer
- DAW PipeWire backend is currently a stub
- Recommend using `--backend=pulse` explicitly if on PipeWire system

**GTK4 on Wayland:**
- Auto-detects Wayland compositor
- Force X11 if needed: `GDK_BACKEND=x11 ./zig-out/bin/daw`
- Hyprland: v0.4+ removes HeaderBar for compatibility

**Tiling Window Managers:**
- No client-side decorations (CSD) - works on all tiling WMs
- i3 recommended config: `for_window [class="daw"] floating enable`

**Package Manager Notes:**
- Gentoo: GTK4 in `gui-libs/gtk`, not `x11-libs`
- Ubuntu: Need `-dev` packages for headers
- Arch: Standard packages work out of box

### macOS

**Homebrew Path Assumptions:**
- build.zig hardcodes `/opt/homebrew/` (Apple Silicon)
- Intel Macs may need path adjustments in build.zig
- Library versions: Paths include version numbers (e.g., `gtk4/4.20.3`)

**Linker Selection:**
- MUST use system linker (ld64), not LLD
- LLD causes duplicate dylib issues with pkg-config dependencies
- Set via `use_lld = false` in build.zig

**CoreAudio Specifics:**
- Always uses default output device
- Buffer sizes: 512 frames recommended (10.7ms @ 48kHz)
- Sample rate: Fixed at 48kHz (macOS standard)

**CoreMIDI Specifics:**
- Automatically enumerates all MIDI sources
- Connects to all available input devices
- Uses extern declarations to avoid Objective-C block issues in headers

**GTK4 on macOS:**
- Uses Quartz backend (native macOS drawing)
- Theming may differ from Linux
- Install `adwaita-icon-theme` if icons missing

---

## Runtime Dependencies

### Linux

**Required at Runtime:**
- GTK4 libraries (gtk-4, glib-2.0, gobject-2.0, gio-2.0)
- Cairo graphics library
- PulseAudio OR PipeWire (with PulseAudio compatibility)
- Adwaita icon theme (recommended)
- Wayland compositor OR X11 server

**Optional:**
- PipeWire (native support planned, currently stub)

### macOS

**Required at Runtime:**
- GTK4 (via Homebrew)
- All GTK4 dependencies (GLib, Cairo, Pango, etc.)
- macOS 10.15+ (Catalina or later) recommended
- CoreAudio (system framework - always available)
- CoreMIDI (system framework - always available)

---

## Feature Support Summary

### Audio Features

| Feature | Linux | macOS | Windows | Notes |
|---------|-------|-------|---------|-------|
| Audio playback | ✓ | ✓ | ✗ | PulseAudio/CoreAudio |
| Multi-track mixing | ✓ | ✓ | ✗ | 4 tracks tested, unlimited support planned |
| Real-time level meters | ✓ | ✓ | ✗ | Lock-free atomic updates |
| Audio recording | ✓ | ✓ | ✗ | Full implementation |
| WAV file loading | ✓ | ✓ | ✗ | Complete |
| WAV file export | ✓ | ✓ | ✗ | Complete |
| Effect processing | ✓ | ✓ | ✗ | EQ, compression, reverb |
| Low-latency mode | ✓ | ✓ | ✗ | ~10ms buffer size supported |

### MIDI Features

| Feature | Linux | macOS | Windows | Notes |
|---------|-------|-------|---------|-------|
| MIDI input | ✗ | ✓ | ✗ | CoreMIDI on macOS |
| MIDI output | ✗ | ✓ | ✗ | CoreMIDI on macOS |
| MIDI recording | ✗ | ✓ | ✗ | Full implementation |
| MIDI playback | ✗ | ✓ | ✗ | Piano roll editor |
| Virtual instruments | ✓ | ✓ | ✗ | Wavetable synth |
| MIDI device enumeration | ✗ | ✓ | ✗ | CoreMIDI |

### UI Features

| Feature | Linux | macOS | Windows | Notes |
|---------|-------|-------|---------|-------|
| Timeline view | ✓ | ✓ | ✗ | Cairo rendering |
| Mixer view | ✓ | ✓ | ✗ | Faders, meters, pan |
| Piano roll editor | ✓ | ✓ | ✗ | MIDI note editing |
| Waveform display | ✓ | ✓ | ✗ | Peak cache optimization |
| Theming | ✓ | ✓ | ✗ | Tokyo Night theme |
| Dark/Light modes | Partial | Partial | ✗ | Dark mode only currently |
| Keyboard shortcuts | ✓ | ✓ | ✗ | Space=play, R=record, etc. |
| Multi-monitor | ✓ | ✓ | ✗ | Full support |

---

## Performance Targets

### Audio Performance

| Metric | Linux | macOS | Target | Notes |
|--------|-------|-------|--------|-------|
| Buffer latency | 10.7ms | 10.7ms | <15ms | 512 frames @ 48kHz |
| CPU usage (4 tracks) | <7% | <7% | <30% | Test tones, no effects |
| CPU usage (with FX) | ~20% | ~20% | <50% | Per-track EQ+compression |
| Audio dropouts | None | None | 0 | Real-time safe processing |

### UI Performance

| Metric | Linux | macOS | Target | Notes |
|--------|-------|-------|--------|-------|
| UI update rate | 10Hz | 10Hz | 10Hz | 100ms timer by design |
| CPU usage (idle) | <2% | <2% | <5% | UI thread only |
| Memory usage | ~11MB | ~15MB | <50MB | Idle, no project loaded |
| Startup time | <1s | <1s | <2s | To main window |

---

## Testing Checklist

### Linux Testing Matrix

**Distributions Tested:**
- [ ] Gentoo/Funtoo
- [ ] Arch Linux
- [ ] Ubuntu 24.04 LTS
- [ ] Debian 12
- [ ] Fedora 40

**Desktop Environments:**
- [x] GNOME 46+ (Wayland)
- [x] KDE Plasma 6 (Wayland/X11)
- [x] Hyprland (Wayland)
- [x] i3 (X11)
- [ ] Sway (Wayland)
- [ ] bspwm (X11)

**Audio Servers:**
- [x] PulseAudio 16.1+
- [ ] PipeWire 0.3+ (stub only)
- [ ] PipeWire with PulseAudio compat

### macOS Testing Matrix

**macOS Versions:**
- [ ] macOS 15 Sequoia
- [ ] macOS 14 Sonoma
- [ ] macOS 13 Ventura
- [ ] macOS 12 Monterey

**Hardware:**
- [ ] Apple Silicon (M1/M2/M3)
- [ ] Intel x86_64

---

## Known Issues by Platform

### Linux

**Issue:** PipeWire backend is stub only
**Workaround:** Use `--backend=pulse` explicitly
**Status:** Implementation tracked in roadmap

**Issue:** MIDI not implemented
**Workaround:** None - feature not available
**Status:** ALSA MIDI planned for future release

**Issue:** Wayland input focus on some tiling WMs
**Workaround:** Use `GDK_BACKEND=x11`
**Status:** GTK4 upstream issue

### macOS

**Issue:** Hardcoded Homebrew paths for Apple Silicon
**Workaround:** Edit build.zig for Intel Mac paths
**Status:** Consider using `pkg-config` instead

**Issue:** GTK4 theme differs from Linux
**Workaround:** None - cosmetic only
**Status:** Accepted limitation

**Issue:** CoreAudio buffer size not configurable
**Workaround:** None - uses system defaults
**Status:** Low priority (default is good)

---

## Future Platform Support

### Planned Improvements

**Linux:**
- [ ] Native PipeWire backend (non-stub)
- [ ] ALSA MIDI support
- [ ] JACK audio backend (low priority)

**macOS:**
- [ ] Dynamic Homebrew path detection
- [ ] Intel Mac testing and optimization
- [ ] Native Cocoa UI (long-term consideration)

**Windows:**
- [ ] WASAPI audio backend
- [ ] Windows MIDI support
- [ ] GTK4 for Windows integration
- [ ] Build system Windows support

### Long-Term Considerations

- **BSD Support:** FreeBSD/OpenBSD may work with PulseAudio/ALSA but untested
- **ARM Linux:** Should work (Zig cross-compilation) but untested
- **Raspberry Pi:** Likely works but performance not guaranteed

---

## Contributing Platform Support

If you want to help improve platform support:

1. **Test on your platform** - Use the testing checklist above
2. **Report issues** - Include platform details, logs, and reproduction steps
3. **Submit fixes** - PRs welcome for platform-specific bugs
4. **Add new backends** - PipeWire, JACK, WASAPI implementations needed

**Testing Template:**
```
Platform: [OS + Version]
Audio: [Backend + Version]
UI: [Desktop Environment]
Build: [Zig Version]

Steps to reproduce:
1. ...

Expected: ...
Actual: ...

Logs:
```

---

**Last Updated:** 2026-01-10
**Document Version:** 1.0
**Zig Version:** 0.18.0-dev
**GTK Version:** 4.10+
