# Backend Detection Test

## Overview

This test verifies that audio backend detection and selection works correctly across different platforms and configurations.

## Files

- `test_backend_detection.zig` - Isolated Zig test binary
- `run_backend_detection_test.sh` - Shell script wrapper with detailed output

## What It Tests

1. **detectPulseAudio()** - Verifies PulseAudio detection works by calling `pactl info`
2. **detectPipeWire()** - Verifies PipeWire detection works by checking `PIPEWIRE_RUNTIME_DIR` env var or calling `pw-cli ls Node`
3. **Auto backend selection** - Verifies the correct backend is auto-selected based on availability
4. **Forced backend selection** - Logic verified in src/audio/backend.zig
5. **Priority order** - Verifies PulseAudio is preferred over PipeWire (since PipeWire is currently a stub)

## Running the Test

### Quick Test (Binary Only)

```bash
zig build test-backend-detection
```

This runs the compiled test and exits with code 0 on success.

### Comprehensive Test (With Output)

```bash
tests/isolated/run_backend_detection_test.sh
```

This runs the shell script which:
- Detects available backends
- Prints detection results
- Verifies priority order
- Runs the compiled test
- Exits with code 0 on success

## Expected Output

On a Linux system with both PulseAudio and PipeWire:

```
=== Backend Detection Test ===

Platform: Linux

PulseAudio: yes
PipeWire: yes
Auto-selected: PulseAudio

Priority verification:
  Both backends available
  Expected: PulseAudio > PipeWire (PA is fully implemented)
  ✓ Priority order correct

Building and running compiled test...

==================================================
✓ ALL BACKEND DETECTION TESTS PASSED
==================================================
```

## Platform-Specific Behavior

### Linux
- Checks for PulseAudio (via `pactl`)
- Checks for PipeWire (via `pw-cli` or `PIPEWIRE_RUNTIME_DIR`)
- Auto-selects PulseAudio if available (priority order)
- Falls back to PipeWire if only it is available
- Fails if neither backend is available

### macOS
- CoreAudio is always available
- Auto-selects CoreAudio
- Test verifies CoreAudio detection (implementation in src/system/detect.zig)

### Windows
- WASAPI is always available
- Auto-selects WASAPI
- Test verifies WASAPI detection (implementation in src/system/detect.zig)

## Implementation Details

The test uses the same detection logic as the main application:

- **PulseAudio detection**: Spawns `pactl info` and checks exit code
- **PipeWire detection**: Checks `PIPEWIRE_RUNTIME_DIR` env var or spawns `pw-cli ls Node`
- **Priority order**: PulseAudio > PipeWire > ALSA (on Linux)

This ensures the test accurately reflects runtime behavior.

## Known Issues

- The Zig test binary uses simplified output due to std.io API changes in Zig 0.16-dev
- For detailed output, use the shell script wrapper
- The test verifies detection works but doesn't test actual audio I/O (that's tested elsewhere)

## Related Tests

- `tests/test_backend_detection.zig` - Higher-level backend detection tests
- `tests/test_pulseaudio_backend.zig` - PulseAudio-specific tests
- `tests/isolated/test_pulseaudio_isolated.zig` - Isolated PulseAudio runtime tests

## Success Criteria

The test passes if:
1. On Linux: At least one backend (PulseAudio or PipeWire) is detected
2. Priority order is correct (PulseAudio preferred over PipeWire)
3. Detection functions don't crash
4. Exit code is 0

## Maintenance

This test should be run:
- Before releases to verify backend detection works
- After modifying backend detection code
- When adding support for new audio backends
- On each supported platform (Linux, macOS, Windows)
