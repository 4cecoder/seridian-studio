# Build Instructions

Comprehensive cross-platform build guide for the DAW project.

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Linux](#linux)
  - [macOS](#macos)
  - [Windows](#windows)
- [Building the DAW](#building-the-daw)
  - [Quick Start](#quick-start)
  - [Build Options](#build-options)
  - [Build Targets](#build-targets)
- [Verifying Your Build](#verifying-your-build)
- [Common Build Issues](#common-build-issues)
- [Platform-Specific Notes](#platform-specific-notes)

---

## Prerequisites

### Required Tools (All Platforms)

- **Zig master** (minimum: `0.18.0-dev.35+5e754304d`)
  - Download from: https://ziglang.org/download/
  - **Important:** Use Zig master (0.18-dev) or later. Earlier versions will not work.

### Linux

#### Gentoo/Funtoo

```bash
# Install all required dependencies
emerge -av dev-lang/zig gui-libs/gtk x11-libs/cairo \
    media-sound/pulseaudio media-video/pipewire
```

#### Arch Linux

```bash
# Install all required dependencies
sudo pacman -S zig gtk4 cairo pulseaudio pipewire
```

#### Ubuntu/Debian

```bash
# Install all required dependencies
sudo apt update
sudo apt install zig libgtk-4-dev libcairo2-dev \
    libpulse-dev libpipewire-0.3-dev \
    libglib2.0-dev libpango1.0-dev
```

#### Fedora/RHEL

```bash
# Install all required dependencies
sudo dnf install zig gtk4-devel cairo-devel \
    pulseaudio-libs-devel pipewire-devel \
    glib2-devel pango-devel
```

#### Required Libraries

- **GTK4** 4.10+ (`gtk-4`)
- **GLib** 2.0+ (`glib-2.0`, `gobject-2.0`, `gio-2.0`)
- **Cairo** (`cairo`)
- **PulseAudio** (`pulse`, `pulse-simple`)
- **PipeWire** 0.3+ (`pipewire-0.3`) - optional

#### Verify Installation

```bash
# Check Zig version
zig version
# Should show: 0.18.0-dev.XXXX+...

# Verify GTK4 installation
pkg-config --modversion gtk4
# Should show: 4.10.0 or higher

# Verify other dependencies
pkg-config --modversion glib-2.0 cairo
pkg-config --libs pulse pipewire-0.3
```

### macOS

#### Homebrew Setup

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required dependencies
brew install zig gtk4 cairo glib
```

#### Required Libraries

- **GTK4** 4.10+ (installed via Homebrew)
- **GLib** 2.0+ (installed via Homebrew)
- **Cairo** (installed via Homebrew)
- **CoreAudio** (system framework - no installation needed)
- **CoreMIDI** (system framework - no installation needed)

#### Verify Installation

```bash
# Check Zig version
zig version
# Should show: 0.18.0-dev.XXXX+...

# Verify GTK4 installation (Homebrew paths)
pkg-config --modversion gtk4
# Should show: 4.10.0 or higher

# Check Homebrew library paths
ls /opt/homebrew/lib/libgtk*
ls /opt/homebrew/lib/libcairo*
```

#### Important macOS Notes

1. **Homebrew Paths**: The build system expects libraries in `/opt/homebrew/` (Apple Silicon) or `/usr/local/` (Intel).
2. **System Linker**: macOS builds use the system linker (`ld64`) instead of LLD to avoid duplicate dylib issues.
3. **Audio Backend**: CoreAudio is the default and recommended backend on macOS.

### Windows

**Windows support is currently experimental.** The build system is optimized for Linux and macOS.

#### Requirements

- **Zig master** (download Windows build from https://ziglang.org/download/)
- **MSYS2** or **WSL2** (recommended for GTK4 support)

#### Using WSL2 (Recommended)

```bash
# Install WSL2 with Ubuntu
wsl --install -d Ubuntu

# Follow Ubuntu/Debian instructions above
```

#### Using MSYS2

```bash
# Install MSYS2 from https://www.msys2.org/
# Then in MSYS2 terminal:
pacman -S mingw-w64-x86_64-zig mingw-w64-x86_64-gtk4 \
    mingw-w64-x86_64-cairo
```

**Note:** Native Windows builds may require additional configuration. WSL2 is strongly recommended for the best experience.

---

## Building the DAW

### Quick Start

```bash
# Clone the repository
git clone https://github.com/4cecoder/daw
cd daw

# Build (debug mode)
zig build

# Run the DAW
zig build run

# Or run the executable directly
./zig-out/bin/daw
```

That's it! The DAW should launch with the GTK4 interface.

### Build Options

#### Optimization Levels

```bash
# Debug build (default, fastest compile)
zig build

# Release build with safety checks
zig build -Doptimize=ReleaseSafe

# Fast release build (recommended for production)
zig build -Doptimize=ReleaseFast

# Small release build (minimal binary size)
zig build -Doptimize=ReleaseSmall
```

#### Audio Backend Selection

```bash
# Auto-detect audio backend (default)
zig build

# Force PulseAudio backend (Linux)
zig build -Dbackend=pulse

# Force PipeWire backend (Linux)
zig build -Dbackend=pipewire

# Force CoreAudio backend (macOS - default)
zig build -Dbackend=coreaudio
```

#### SIMD Optimizations

```bash
# Enable SIMD optimizations (default)
zig build

# Disable SIMD optimizations (for debugging or compatibility)
zig build -Dsimd=false
```

#### Combined Options

```bash
# Production build with PulseAudio backend
zig build -Doptimize=ReleaseFast -Dbackend=pulse

# Debug build with PipeWire backend, no SIMD
zig build -Dbackend=pipewire -Dsimd=false
```

### Build Targets

```bash
# Build only (don't run)
zig build

# Build and run
zig build run

# Run unit tests
zig build test

# Format code (check only)
zig build fmt

# Clean build artifacts
rm -rf zig-out .zig-cache
```

---

## Verifying Your Build

### Automated Build Verification

Use the included test script to verify your build:

```bash
# Run the build verification script
bash tests/test_build.sh
```

This script will:
1. Clean previous build artifacts
2. Build the project from scratch
3. Verify the executable was created
4. Check for undefined symbols
5. Verify library linkage (Linux)
6. Report build size and status

Expected output:
```
🔨 DAW Build Verification Test
================================

1️⃣ Cleaning previous build...
   ✓ Clean complete

2️⃣ Testing basic build...
   ✓ Build succeeded

3️⃣ Verifying executable...
   ✓ Executable created: zig-out/bin/daw

4️⃣ Checking for undefined symbols...
   ✓ No macOS-specific symbols found

5️⃣ Checking PulseAudio linkage...
   ✓ PulseAudio libraries linked

6️⃣ Build size check...
   Executable size: 2MB
   ✓ Executable has valid size

================================
✅ All build verification tests passed!
```

### Manual Verification

#### Check Executable Exists

```bash
ls -lh zig-out/bin/daw
# Should show executable with size ~2-5MB
```

#### Test Run

```bash
# Run the DAW
./zig-out/bin/daw

# You should see:
# - GTK4 window opens with Tokyo Night theme
# - Transport controls (Play/Stop/Record)
# - 4 tracks visible in timeline
# - Mixer with 4 channels + master bus
```

#### Verify Library Linkage (Linux)

```bash
# Check linked libraries
ldd zig-out/bin/daw

# Should show:
# - libgtk-4.so
# - libglib-2.0.so
# - libcairo.so
# - libpulse.so (if using PulseAudio backend)
```

#### Verify Symbols (Linux)

```bash
# Check for required GTK symbols
nm -D zig-out/bin/daw | grep gtk_

# Check for audio symbols
nm -D zig-out/bin/daw | grep -E 'pa_|pw_'
```

---

## Common Build Issues

### Issue: "gtk/gtk.h not found"

**Symptoms:**
```
error: 'gtk/gtk.h' file not found
```

**Solution (Linux):**
```bash
# Verify GTK4 is installed
pkg-config --modversion gtk4

# If not installed, install development headers
# Ubuntu/Debian:
sudo apt install libgtk-4-dev

# Arch:
sudo pacman -S gtk4

# Gentoo:
emerge gui-libs/gtk
```

**Solution (macOS):**
```bash
# Reinstall GTK4 via Homebrew
brew reinstall gtk4

# Verify paths
ls /opt/homebrew/include/gtk-4.0/gtk/gtk.h
```

### Issue: Zig Version Mismatch

**Symptoms:**
```
error: Zig version X.Y.Z does not meet the minimum build requirement of 0.18.0-dev.35
```

**Solution:**
```bash
# Download Zig master
# From: https://ziglang.org/download/

# Extract and verify
./zig version
# Should show: 0.18.0-dev.XXXX+...

# Update PATH if necessary
export PATH="/path/to/zig-master:$PATH"
```

### Issue: "undefined reference to gtk_main"

**Symptoms:**
```
error: undefined reference to 'gtk_main'
```

**Cause:** This error should not occur in the current codebase (GTK4 uses `GMainLoop` instead).

**Solution:** Ensure you're building from the latest source:
```bash
git pull origin master
rm -rf .zig-cache zig-out
zig build
```

### Issue: Audio Backend Not Found (Linux)

**Symptoms:**
```
Failed to initialize audio backend
```

**Solution:**
```bash
# Check if PulseAudio is running
pactl info

# If not running, start it
pulseaudio --start

# Or try PipeWire backend
zig build -Dbackend=pipewire run

# Verify PipeWire is running
systemctl --user status pipewire
```

### Issue: macOS Library Paths Not Found

**Symptoms:**
```
error: library not found for -lgtk-4
```

**Solution:**
```bash
# Verify Homebrew installation
brew list gtk4

# Check library paths
ls /opt/homebrew/lib/libgtk*

# If on Intel Mac, paths may be different:
ls /usr/local/lib/libgtk*

# You may need to update build.zig library paths
# Edit lines 115-137 in build.zig to match your Homebrew installation
```

### Issue: Build Fails with "std.builtin.ObjectFormat not found"

**Symptoms:**
```
error: container 'std.builtin' has no member called 'ObjectFormat'
```

**Cause:** Using Zig version older than 0.18.0-dev.35.

**Solution:** Upgrade to Zig master (see "Zig Version Mismatch" above).

### Issue: SIMD-Related Errors

**Symptoms:**
```
error: SIMD not supported on this target
```

**Solution:** Disable SIMD optimizations:
```bash
zig build -Dsimd=false
```

### Issue: Out of Memory During Build

**Symptoms:**
```
error: OutOfMemory
```

**Solution:**
```bash
# Reduce optimization level
zig build -Doptimize=Debug

# Or increase system swap space (Linux)
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

---

## Platform-Specific Notes

### Linux

#### Audio Backend Selection

The DAW supports multiple audio backends on Linux:

1. **PulseAudio** (default, most compatible)
   - Works with most Linux desktop environments
   - Automatic sample rate conversion
   - Mature and stable

2. **PipeWire** (modern alternative)
   - Better latency characteristics
   - Compatible with PulseAudio clients
   - Recommended for modern distributions

Select backend at build time:
```bash
zig build -Dbackend=pulse     # PulseAudio
zig build -Dbackend=pipewire  # PipeWire
```

#### Include Paths

The build system expects standard Linux paths:
- `/usr/include/gtk-4.0`
- `/usr/include/glib-2.0`
- `/usr/lib64/glib-2.0/include` (64-bit systems)

If your distribution uses different paths, you may need to modify `configureLinuxModule()` in `build.zig`.

#### 32-bit vs 64-bit

The build system assumes 64-bit (`/usr/lib64`). For 32-bit systems, update paths in `build.zig`:
```zig
// Change from:
mod.addIncludePath(.{ .cwd_relative = "/usr/lib64/glib-2.0/include" });

// To:
mod.addIncludePath(.{ .cwd_relative = "/usr/lib/glib-2.0/include" });
```

### macOS

#### Apple Silicon vs Intel

- **Apple Silicon (M1/M2/M3):** Libraries in `/opt/homebrew/`
- **Intel:** Libraries in `/usr/local/`

The build system currently assumes Apple Silicon paths. For Intel Macs, update `configureMacOSModule()` in `build.zig`.

#### System Frameworks

macOS builds automatically link these frameworks:
- `AudioToolbox.framework` - Core audio functionality
- `CoreAudio.framework` - Audio hardware access
- `CoreFoundation.framework` - Core system utilities
- `AudioUnit.framework` - Audio processing units
- `CoreMIDI.framework` - MIDI device support

No additional installation required - these are part of macOS.

#### Code Signing

For distribution, you'll need to sign the binary:
```bash
# Sign with ad-hoc signature (local testing)
codesign -s - zig-out/bin/daw

# Sign with Developer ID (distribution)
codesign -s "Developer ID Application: Your Name" zig-out/bin/daw
```

#### Homebrew Version Pinning

The build system currently references specific Homebrew versions:
- `gtk4/4.20.3`
- `cairo/1.18.4`
- `glib/2.86.3`

If you have different versions, update the paths in `configureMacOSModule()` or use symlinks:
```bash
# Check your versions
brew list --versions gtk4 cairo glib

# Update build.zig paths accordingly
```

### Windows

#### WSL2 vs MSYS2

- **WSL2 (Recommended):** Full Linux environment, better compatibility
- **MSYS2:** Native Windows build, experimental

#### WSL2 Setup

```bash
# Install Ubuntu on WSL2
wsl --install -d Ubuntu

# Follow Linux build instructions
cd /mnt/c/Users/YourName/daw
zig build
```

#### Native Windows Build

Currently **not officially supported**. The build system expects POSIX paths and Linux/macOS-specific libraries.

For native Windows support, contributions are welcome to add:
- Windows audio backend (WASAPI/DirectSound)
- Windows-specific library paths
- MinGW/MSVC toolchain support

---

## Build Performance Tips

### Faster Incremental Builds

```bash
# Use debug mode during development (fastest compile)
zig build

# Only use release builds for testing/distribution
zig build -Doptimize=ReleaseFast
```

### Parallel Builds

Zig automatically parallelizes builds. To limit CPU usage:
```bash
# Limit to 4 threads
zig build -j4

# Use all available cores (default)
zig build
```

### Cache Management

```bash
# Clear cache if builds act strange
rm -rf .zig-cache

# Clear everything for a fresh start
rm -rf .zig-cache zig-out
```

---

## Additional Resources

- **Getting Started Guide:** [docs/getting-started.md](getting-started.md)
- **Development Guide:** [docs/development/guide.md](development/guide.md)
- **Architecture Documentation:** [docs/design/architecture.md](design/architecture.md)
- **Audio Backend Architecture:** [docs/AUDIO_BACKEND_ARCHITECTURE.md](AUDIO_BACKEND_ARCHITECTURE.md)

---

**Last Updated:** 2026-01-10
