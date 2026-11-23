# Troubleshooting

## Build Issues

### "gtk/gtk.h not found"

**Cause:** GTK4 development headers not found

**Solution:**
```bash
# Verify GTK4 is installed
pkg-config --modversion gtk4

# Gentoo/Funtoo
emerge -av gui-libs/gtk

# Arch
sudo pacman -S gtk4

# Ubuntu/Debian
sudo apt install libgtk-4-dev
```

The build system should automatically detect GTK4 paths. If it doesn't, check that `pkg-config --cflags gtk4` returns valid paths.

### "undefined symbol: gtk_main"

**Cause:** Trying to use deprecated GTK3 pattern

**Solution:** This shouldn't occur with the current codebase. The project uses `GMainLoop` instead of `gtk_main()`. If you see this error, ensure you're building from clean source:
```bash
rm -rf zig-out .zig-cache
zig build
```

### Zig Version Mismatch

**Cause:** Using incompatible Zig version

**Solution:**
```bash
# Check version
zig version
# Required: 0.16.0-dev.XXXX+...

# Download latest Zig 0.16 from:
# https://ziglang.org/download/
```

### Build Hangs or Takes Too Long

**Cause:** Incremental build cache issues

**Solution:**
```bash
# Clean build
rm -rf zig-out .zig-cache
zig build

# If still slow, check system resources
htop  # Look for memory pressure
```

### Linker Errors with System Libraries

**Cause:** Missing development libraries

**Solution:**
```bash
# Verify all required libraries are installed
pkg-config --exists gtk4 glib-2.0 cairo || echo "Missing libs"

# Install missing libraries (Gentoo)
emerge -av x11-libs/cairo dev-libs/glib media-sound/pulseaudio

# Install missing libraries (Ubuntu)
sudo apt install libcairo2-dev libglib2.0-dev libpulse-dev
```

## Runtime Issues

### Audio Backend Not Found

**Symptoms:** Error message "No audio backend available"

**Diagnosis:**
```bash
# Check PulseAudio
pactl info
# Should show: Server String: ...

# Check PipeWire
pw-cli ls Node
# Should list nodes

# Check running audio servers
ps aux | grep -E "pulseaudio|pipewire"
```

**Solutions:**

**If using PulseAudio:**
```bash
# Start PulseAudio
pulseaudio --start

# Check status
pactl info

# Force use
./zig-out/bin/daw --backend=pulse
```

**If using PipeWire:**
```bash
# Check PipeWire is running
systemctl --user status pipewire

# Restart if needed
systemctl --user restart pipewire

# PipeWire backend is currently a stub, use PulseAudio:
./zig-out/bin/daw --backend=pulse
```

### No Audio Output

**Symptoms:** DAW runs, meters move, but no sound

**Diagnosis:**
```bash
# 1. Check system volume
pactl list sinks | grep -E "Volume|Mute"

# 2. Test system audio
speaker-test -t sine -f 440

# 3. Check DAW is using correct sink
pactl list sink-inputs
```

**Solutions:**

1. **Unmute system audio:**
```bash
pactl set-sink-mute @DEFAULT_SINK@ 0
pactl set-sink-volume @DEFAULT_SINK@ 50%
```

2. **Select correct audio device:**
```bash
# List available sinks
pactl list short sinks

# Set default (if needed)
pactl set-default-sink SINK_NAME
```

3. **Check DAW audio output:**
```bash
# Run DAW and check console for errors
./zig-out/bin/daw 2>&1 | grep -i "audio\|error"
```

### Application Crashes on Startup

**Symptoms:** Segfault or immediate exit

**Diagnosis:**
```bash
# Run with debug output
./zig-out/bin/daw 2>&1 | tee daw-debug.log

# Check for GTK errors
GTK_DEBUG=all ./zig-out/bin/daw 2>&1 | grep -i error

# Run with gdb
gdb ./zig-out/bin/daw
> run
> bt  # backtrace when it crashes
```

**Common Causes:**

1. **Missing GTK themes:**
```bash
# Install GTK4 themes
# Gentoo
emerge -av x11-themes/adwaita-icon-theme

# Ubuntu
sudo apt install adwaita-icon-theme-full
```

2. **Wayland/X11 issues:**
```bash
# Force X11
GDK_BACKEND=x11 ./zig-out/bin/daw

# Force Wayland
GDK_BACKEND=wayland ./zig-out/bin/daw
```

### Hyprland Window Manager Crashes

**Symptoms:** DAW crashes when moving between workspaces

**Solution:** This was fixed in v0.4. If you're still experiencing issues:

1. **Ensure you're using latest code:**
```bash
git pull
zig build
```

2. **Check Hyprland version:**
```bash
hyprctl version
# Ensure you're on a recent version
```

3. **Try without header bar** (already implemented in v0.4+):
The DAW no longer uses GTK HeaderBar, which was causing the crash.

### High CPU Usage

**Symptoms:** DAW uses >50% CPU when idle or playing

**Diagnosis:**
```bash
# Monitor CPU usage
htop

# Profile the application
perf record ./zig-out/bin/daw
# (run for a bit, then Ctrl+C)
perf report
```

**Expected CPU Usage:**
- Idle: <2%
- Playing (4 test tones): ~7%
- Playing with effects: ~20-30%

**If usage is higher:**
1. Check for runaway timers in GTK
2. Verify update rate is 10Hz (100ms), not higher
3. Check for infinite loops in draw functions

### Memory Leaks

**Symptoms:** Memory usage grows over time

**Diagnosis:**
```bash
# Run with valgrind
valgrind --leak-check=full --show-leak-kinds=all ./zig-out/bin/daw
```

**Expected Results:**
- GTK creates many "still reachable" blocks (normal)
- Should have 0 "definitely lost" blocks
- Should have 0 "indirectly lost" blocks

### Meters Not Updating

**Symptoms:** Level meters stay at zero even when playing

**Diagnosis:**
1. Check that Play is actually triggering audio
2. Check console for audio thread errors
3. Verify atomic reads are working

**Solution:**
```bash
# Check if audio thread is running
./zig-out/bin/daw 2>&1 | grep "process"

# Should see periodic logs (if debug logging enabled)
```

If meters still don't update:
- Check that UI timer is running (100ms)
- Verify `audio_engine_get_track_meter()` is being called
- Check for atomic load/store bugs

## Window Manager Specific Issues

### Tiling Window Managers (i3, sway, bspwm)

**Issue:** Controls not accessible

**Solution:** Since v0.4, all controls are in the main window content area (not in title bar). No special configuration needed.

**Recommended i3 config:**
```
for_window [class="daw"] floating enable
```

### GNOME/Mutter

**Issue:** Window decorations don't match theme

**Solution:** This is expected - the DAW uses minimal decorations. GTK4 CSD (client-side decorations) are not used to maintain tiling WM compatibility.

### KDE Plasma

**Issue:** Window title shows "daw" instead of "DAW for Linux"

**Solution:** This is cosmetic and doesn't affect functionality. The window manager shows the application class name.

## Performance Issues

### Audio Dropouts / Glitches

**Symptoms:** Crackling, pops, or silence during playback

**Diagnosis:**
```bash
# Check buffer underruns
./zig-out/bin/daw 2>&1 | grep -i "underrun"

# Monitor audio latency
pactl list sinks | grep Latency
```

**Solutions:**

1. **Increase buffer size:**
```bash
./zig-out/bin/daw --buffer-size=1024  # Higher = more latency, fewer dropouts
```

2. **Check system load:**
```bash
htop  # Look for high CPU usage from other processes
```

3. **Disable CPU frequency scaling** (for pro audio work):
```bash
# Set performance governor
sudo cpupower frequency-set -g performance
```

### UI Lag / Slow Redraw

**Symptoms:** Timeline or meters update slowly

**Expected:** UI updates at 10Hz (100ms timer) by design - this is intentional to reduce CPU usage.

**If slower than 10Hz:**
1. Check CPU usage (htop)
2. Verify Cairo drawing is efficient
3. Check for blocking I/O in main thread

## Getting More Help

If none of these solutions work:

1. **Gather diagnostic information:**
```bash
# System info
uname -a
zig version
pkg-config --modversion gtk4

# DAW debug output
./zig-out/bin/daw 2>&1 | tee daw-debug.log

# Audio info
pactl info
```

2. **Check logs in:**
- Console output
- `~/.local/state/daw/logs/` (if implemented)
- System journal: `journalctl --user -b | grep daw`

3. **Create a minimal reproduction:**
- Clean build
- Default configuration
- Note exact steps to reproduce

---

**Last Updated:** 2025-12-20
