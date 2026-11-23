# Platform-Aware Test Framework

This document describes the platform-aware test framework for the DAW project, which ensures that tests only run for backends that are available on the current platform.

## Overview

The platform-aware test framework solves the problem of cross-platform testing by:

1. **Compile-time platform detection**: Identifies the current OS (Linux/macOS/Windows)
2. **Runtime backend availability detection**: Checks if backends are actually installed and running
3. **Graceful test skipping**: Skips tests for unavailable backends instead of failing
4. **Clear reporting**: Shows which tests were run, passed, failed, or skipped

## Architecture

### Core Module: `tests/platform_config.zig`

The framework is built around the `platform_config.zig` module, which provides:

- **Platform detection**: Compile-time OS identification
- **Backend detection**: Runtime checks for PulseAudio, PipeWire, CoreAudio, WASAPI
- **TestRunner**: Manages and executes tests with platform awareness
- **Helper functions**: Utilities for skipping tests and requiring backends

### Platform-Backend Matrix

| Platform | Available Backends |
|----------|-------------------|
| Linux    | PulseAudio, PipeWire |
| macOS    | CoreAudio |
| Windows  | WASAPI (when implemented) |

## Usage

### Basic Example

```zig
const std = @import("std");
const platform_config = @import("platform_config.zig");

fn testPulseAudioInit() !void {
    // This test only runs on Linux if PulseAudio is available
    try platform_config.requireBackend(.pulseaudio);

    // Your test code here
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runner = try platform_config.TestRunner.init(allocator);
    defer runner.deinit();

    // Register tests with their required backends
    try runner.addTest("PulseAudio initialization", .pulseaudio, testPulseAudioInit);

    // Run all tests (platform-aware)
    try runner.run();

    // Print summary
    try runner.printReport();
}
```

### Test Output Example

```
======================================================================
Platform-Aware Test Runner
Platform: Linux
======================================================================

Detecting available backends...
  PulseAudio: ✓ Available
  PipeWire: ✗ Not detected

Running tests...

[PulseAudio] PulseAudio: Initialization... ✓ PASSED
[PulseAudio] PulseAudio: Playback... ✓ PASSED
[PipeWire] PipeWire: Initialization... ⊘ SKIPPED
    Reason: Backend not detected at runtime
[CoreAudio] CoreAudio: Initialization... ⊘ SKIPPED
    Reason: Backend not available on this platform

======================================================================
Test Summary
======================================================================
Total tests:   4
Passed:        2
Failed:        0
Skipped:       2
Duration:      150ms
======================================================================
```

## Running Tests

### Example Test Runner

```bash
# Run the example test runner (demonstrates framework features)
zig build test-platform-aware

# Run actual backend tests with platform awareness
zig build run-platform-tests
```

### Individual Test Steps

```bash
# Linux: Tests PulseAudio and PipeWire (if available)
zig build run-platform-tests

# macOS: Tests CoreAudio only
zig build run-platform-tests

# Windows: Will test WASAPI (when implemented)
zig build run-platform-tests
```

## API Reference

### Platform Detection

```zig
const platform_config = @import("platform_config.zig");

// Get current platform at compile time
const platform = platform_config.Platform.current();

// Get platform name
const name = platform.name(); // "Linux", "macOS", "Windows", "Unknown"
```

### Backend Detection

```zig
// Check if backend is available on this platform (compile-time)
if (Backend.pulseaudio.isAvailableOnPlatform(platform)) {
    // Backend is supported on this OS
}

// Check if backend is available at runtime
if (Backend.pulseaudio.detectRuntime()) {
    // Backend is installed and running
}
```

### Test Runner

```zig
// Initialize runner
var runner = try platform_config.TestRunner.init(allocator);
defer runner.deinit();

// Add tests
try runner.addTest("Test name", .backend_type, testFunction);

// Run all tests
try runner.run();

// Print summary report
try runner.printReport();
```

### Helper Functions

```zig
// Require a backend or skip the test
try platform_config.requireBackend(.pulseaudio);

// Skip a test with a message
return platform_config.skipTest("Reason for skipping");

// Get tests for current platform
const tests = platform_config.getCurrentPlatformTests();
```

## Backend Detection Details

### PulseAudio (Linux)

Detection method:
1. Tries to execute `pactl info`
2. Returns true if exit code is 0

### PipeWire (Linux)

Detection method:
1. Checks for `PIPEWIRE_RUNTIME_DIR` environment variable
2. Falls back to executing `pw-cli ls Node`
3. Returns true if exit code is 0

### CoreAudio (macOS)

Detection method:
- Always returns true on macOS (CoreAudio is part of the system)

### WASAPI (Windows)

Detection method:
- Always returns true on Windows (WASAPI is part of the system)
- Note: Currently a stub, to be implemented when Windows support is added

## Design Principles

### 1. No Silent Failures

Tests are never silently skipped. The framework explicitly reports:
- Which backends were detected
- Which tests were skipped
- Why tests were skipped

### 2. Platform Correctness

Tests only run on platforms where they make sense:
- macOS tests don't run on Linux
- Linux tests don't run on macOS
- No cross-compilation confusion

### 3. Runtime Validation

Even on the correct platform, tests are skipped if the backend isn't available:
- PulseAudio tests skip if PulseAudio isn't running
- PipeWire tests skip if PipeWire isn't installed

### 4. Error Handling

All error cases are handled explicitly:
- Detection failures are caught and reported
- Test failures are clearly distinguished from skips
- No use of `unwrap()` or `expect()` in production code

## Integration with Existing Tests

The framework can wrap existing backend tests without rewriting them:

```zig
// Existing test function
fn testBackendInit() !void {
    var backend = try Backend.init(allocator, config, "pulseaudio");
    defer backend.deinit();
}

// Wrapped with platform awareness
fn testBackendInitPlatformAware() !void {
    try platform_config.requireBackend(.pulseaudio);
    try testBackendInit();
}
```

## Future Enhancements

### Planned Features

1. **WASAPI Support**: Full Windows backend detection and testing
2. **JACK Support**: Add JACK backend for Linux professional audio
3. **Backend Priority**: Allow specifying preferred backend order
4. **Parallel Test Execution**: Run independent tests concurrently
5. **Test Filtering**: Run only specific backend tests

### Extension Points

The framework is designed to be extensible:

```zig
// Add new backend type
pub const Backend = enum {
    pulseaudio,
    pipewire,
    coreaudio,
    wasapi,
    jack,  // New backend
};

// Add detection function
fn detectJACK() bool {
    // Detection logic here
}

// Update platform tests
pub fn getLinuxTests() []const Backend {
    return &[_]Backend{ .pulseaudio, .pipewire, .jack };
}
```

## Troubleshooting

### Test Skipped: "Backend not detected at runtime"

**Cause**: The backend is not installed or not running.

**Solution**:
- For PulseAudio: Ensure `pactl info` works
- For PipeWire: Ensure `pw-cli ls Node` works
- Check that the audio server is running

### Test Skipped: "Backend not available on this platform"

**Cause**: The test is for a different platform.

**Solution**: This is expected behavior. The test will run on the correct platform.

### All Tests Skipped

**Cause**: No backends are available on this platform.

**Solution**:
- Install at least one audio backend
- On Linux: Install PulseAudio or PipeWire
- On macOS: CoreAudio should be available by default
- On Windows: WASAPI should be available by default

## Contributing

When adding new backend tests:

1. Use `platform_config.requireBackend()` at the start of the test
2. Register the test with the appropriate backend type
3. Ensure the test cleans up resources properly
4. Add documentation for any new backends

## License

Same as the main DAW project.
