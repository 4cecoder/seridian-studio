# Testing Guide

This guide provides comprehensive documentation on testing the DAW project, including test categories, available test scripts, and TDD principles used throughout the codebase.

## Table of Contents

- [Quick Start](#quick-start)
- [Test Scripts](#test-scripts)
- [Test Categories](#test-categories)
- [Running Tests](#running-tests)
- [Understanding Test Results](#understanding-test-results)
- [Writing New Tests](#writing-new-tests)
- [TDD Principles](#tdd-principles)
- [CI/CD Integration](#cicd-integration)

## Quick Start

Run the comprehensive test suite:

```bash
# Run all tests
./tests/run_tests.sh

# Run build verification only
./tests/test_build.sh

# Run specific module tests
zig test src/audio/engine.zig --main-pkg-path .
zig test src/midi/midi.zig --main-pkg-path .
zig test src/project/project.zig --main-pkg-path .
```

## Test Scripts

### 1. Comprehensive Test Suite (`tests/run_tests.sh`)

**Purpose:** Runs all project tests in a single pass, providing a complete verification of the codebase.

**What it tests:**
- Build verification (via `test_build.sh`)
- Audio engine unit tests
- MIDI system unit tests
- Project system unit tests
- Audio backend integration tests
- Memory leak detection
- Platform compatibility checks

**Usage:**
```bash
./tests/run_tests.sh
```

**Output:**
```
🧪 DAW Comprehensive Test Suite
==================================
Project: .
Date: 2026-01-10 15:30:00

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Test 1: Build Verification
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[Build output...]
✅ PASSED: Build Verification

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Test 2: Audio Engine Tests
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
All 15 tests passed.
✅ PASSED: Audio Engine Tests

[... more tests ...]

==================================
📊 Test Suite Summary
==================================
Total Tests:  10
Passed:       10 ✅
Failed:       0 ❌

🎉 All tests passed!
Build Status: ✅ READY FOR DISTRIBUTION
```

**Exit codes:**
- `0`: All tests passed
- `1`: One or more tests failed

### 2. Build Verification Test (`tests/test_build.sh`)

**Purpose:** Verifies that the project builds correctly and produces a valid executable with proper platform-specific linkage.

**What it tests:**
1. Clean build from scratch
2. Successful compilation
3. Executable creation
4. Symbol verification (no cross-platform symbol leakage)
5. Library linkage (PulseAudio on Linux)
6. Executable size validation

**Usage:**
```bash
./tests/test_build.sh
```

**Output:**
```
🔨 DAW Build Verification Test
================================

1️⃣ Cleaning previous build...
   ✓ Clean complete

2️⃣ Testing basic build...
   ✓ Build succeeded

3️⃣ Verifying executable...
   ✓ Executable created: zig-out/bin/daw
   -rwxr-xr-x 1 user user 45M Jan 10 15:30 zig-out/bin/daw

4️⃣ Checking for undefined symbols...
   ✓ No macOS-specific symbols found

5️⃣ Checking PulseAudio linkage...
   ✓ PulseAudio libraries linked:
   libpulse.so.0 => /usr/lib/libpulse.so.0

6️⃣ Build size check...
   Executable size: 45MB
   ✓ Executable has valid size

================================
✅ All build verification tests passed!

Summary:
  - Build: SUCCESS
  - Executable: EXISTS (45MB)
  - Platform compatibility: VERIFIED
  - Symbol linkage: CLEAN
```

**Common failures and solutions:**
- **Build failed:** Check compiler errors, ensure all dependencies are installed
- **Executable not found:** Build may have failed silently, check logs in `/tmp/build.log`
- **macOS symbols found on Linux:** Cross-platform compilation issue, check backend selection
- **PulseAudio not linked:** May use alternative backend, verify audio configuration

### 3. Audio Backend Test (`tests/test_audio_backend.zig`)

**Purpose:** Integration test for audio backend functionality without launching the GUI.

**What it tests:**
1. Auto-detection of audio backends
2. Backend initialization
3. Backend preparation
4. Engine callback registration
5. Start/stop functionality
6. Brief playback test

**Usage:**
```bash
zig run tests/test_audio_backend.zig --main-pkg-path .
```

**Output:**
```
🎵 DAW Audio Backend Tests
===========================

1️⃣ Testing auto-detection...
   ✓ Detected backend: pulseaudio

2️⃣ Verifying backend priority...
   ✓ Correctly using PulseAudio backend

3️⃣ Testing backend preparation...
   ✓ Backend prepared successfully

4️⃣ Testing engine connection...
   ✓ Engine callback set

5️⃣ Testing start/stop functionality...
   ✓ Backend started
   ✓ Backend stopped

===========================
✅ All audio backend tests passed!
```

### 4. Backend Detection Tests (`tests/test_backend_detection.zig`)

**Purpose:** Comprehensive unit tests for backend detection and abstraction layer.

**What it tests:**
- Auto-detection selects appropriate backend
- Forced backend selection
- Backend preparation
- Start/stop cycles
- Detection functions
- Multiple backend instances
- Different sample rates (44100, 48000, 88200, 96000)
- Different buffer sizes (128, 256, 512, 1024, 2048)

**Usage:**
```bash
zig test tests/test_backend_detection.zig --main-pkg-path .
```

### 5. PulseAudio Backend Tests (`tests/test_pulseaudio_backend.zig`)

**Purpose:** TDD-style comprehensive tests for the PulseAudio backend implementation.

**What it tests:**
- Init/deinit without memory leaks
- Stream creation via prepare()
- Engine callback storage
- Thread spawning on start
- Thread termination on stop
- Multiple start/stop cycles
- Buffer size configuration
- Graceful handling of missing engine callbacks

**Usage:**
```bash
zig test tests/test_pulseaudio_backend.zig --main-pkg-path .
```

**Example test:**
```zig
test "PulseAudio: start spawns thread" {
    var backend = try pulseaudio.PulseAudioBackend.init(allocator, &cfg);
    defer backend.deinit();

    try backend.prepare();

    var mock_engine = MockEngine{};
    backend.setEngine(@ptrCast(&mock_engine), MockEngine.processCallback);

    try backend.start();
    defer backend.stop();

    // Verify thread was spawned
    try testing.expect(backend.audio_thread != null);
    try testing.expect(backend.running.load(.seq_cst));
}
```

## Test Categories

### 1. Build Verification Tests

**Purpose:** Ensure the project compiles correctly on all platforms.

**Location:** `./tests/test_build.sh`

**Frequency:** Run before every commit, on every CI build

**What they verify:**
- Successful compilation
- No build warnings (when strict mode enabled)
- Correct platform-specific code compilation
- Proper dependency linking

### 2. Unit Tests

**Purpose:** Test individual modules and functions in isolation.

**Location:** Embedded in source files using Zig's `test` blocks

**Examples:**
```zig
// In src/audio/engine.zig
test "AudioEngine: init and deinit" {
    const allocator = testing.allocator;
    var engine = try AudioEngine.init(allocator, .{
        .sample_rate = 44100,
        .buffer_size = 256,
    });
    defer engine.deinit();

    try testing.expect(!engine.playing.load(.monotonic));
}

// In src/effects/reverb.zig
test "Reverb: dry/wet mix" {
    var reverb = Reverb.init(48000);
    reverb.setMix(0.5);

    const input = [_]f32{1.0} ** 128;
    var output = [_]f32{0.0} ** 128;

    reverb.process(&input, &output);

    // Output should be blend of dry and wet
    try testing.expect(output[0] > 0.4 and output[0] < 0.6);
}
```

**Running unit tests:**
```bash
# Test specific module
zig test src/audio/engine.zig --main-pkg-path .
zig test src/effects/reverb.zig --main-pkg-path .

# Test with filter
zig test src/audio/engine.zig --main-pkg-path . -ftest-filter='init'
```

**Key modules with unit tests:**
- `src/audio/engine.zig` - Audio engine core
- `src/midi/midi.zig` - MIDI system
- `src/project/project.zig` - Project management
- `src/dsp/*.zig` - DSP algorithms
- `src/effects/*.zig` - Audio effects
- `src/instruments/*.zig` - Virtual instruments

### 3. Integration Tests

**Purpose:** Test interactions between multiple modules.

**Location:** `./tests/` and `src/*/` files ending in `_test.zig`

**Examples:**

**Audio Backend Integration:**
```bash
zig run tests/test_audio_backend.zig --main-pkg-path .
```

**Project Persistence Integration:**
```bash
zig test src/project/persistence_integration_test.zig --main-pkg-path .
```

This test:
1. Creates a complex project with tracks, clips, and effects
2. Serializes it to disk
3. Loads it back
4. Verifies all data matches exactly

**C API Integration:**
```bash
zig test src/audio/engine_c_api_test.zig --main-pkg-path .
```

Tests the C API bridge for UI integration.

### 4. Real-Time Safety Tests

**Purpose:** Verify that audio thread code doesn't perform allocations or blocking operations.

**Location:** `./src/audio/rt_safe_test.zig`

**What they test:**
- No allocations on audio thread
- Thread-local state tracking
- Lock-free data structures

**Example:**
```zig
test "RealTimeSafeAllocator - allows allocation off audio thread" {
    const allocator = rt_safe.init(testing.allocator);

    // Not an audio thread: should succeed
    rt_safe.is_audio_thread = false;
    const ptr = try allocator.alloc(u8, 1024);
    allocator.free(ptr);
}
```

### 5. Memory Leak Tests

**Purpose:** Ensure proper resource cleanup.

**How to run:**
```bash
# Test with memory leak detection
zig test src/audio/engine.zig --main-pkg-path . -ftest-filter='test_init_deinit'
zig test src/midi/midi.zig --main-pkg-path .
```

**Example test pattern:**
```zig
test "No memory leaks in backend lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    var backend = try Backend.init(allocator, &cfg);
    defer backend.deinit();

    // Test operations...
}
```

### 6. Platform Compatibility Tests

**Purpose:** Verify cross-platform behavior.

**What they test:**
- No platform-specific symbols on wrong platform
- Correct backend selection per platform
- Platform-specific features work correctly

**Example:**
```bash
# Platform check in run_tests.sh
if [ "$(uname)" = "Linux" ]; then
    if nm zig-out/bin/daw | grep -E "AudioComponent|MIDIGetNumber" >/dev/null; then
        echo "❌ Found macOS-specific symbols on Linux build"
        exit 1
    fi
fi
```

## Running Tests

### Run All Tests
```bash
./tests/run_tests.sh
```

### Run Build Verification Only
```bash
./tests/test_build.sh
```

### Run Specific Module Tests
```bash
# Audio engine
zig test src/audio/engine.zig --main-pkg-path .

# MIDI system
zig test src/midi/midi.zig --main-pkg-path .

# Project management
zig test src/project/project.zig --main-pkg-path .

# Specific effect
zig test src/effects/reverb.zig --main-pkg-path .

# DSP utilities
zig test src/dsp/filter.zig --main-pkg-path .
```

### Run Tests with Filters
```bash
# Run only tests matching pattern
zig test src/audio/engine.zig --main-pkg-path . -ftest-filter='init'
zig test src/audio/backend.zig --main-pkg-path . -ftest-filter='PulseAudio'
```

### Run Integration Tests
```bash
# Audio backend integration
zig run tests/test_audio_backend.zig --main-pkg-path .

# Backend detection tests
zig test tests/test_backend_detection.zig --main-pkg-path .

# PulseAudio comprehensive tests
zig test tests/test_pulseaudio_backend.zig --main-pkg-path .
```

### Run Tests in Verbose Mode
```bash
# Zig test output is verbose by default
zig test src/audio/engine.zig --main-pkg-path . --summary all
```

### Run Tests with Optimization
```bash
# Test optimized builds
zig test src/audio/engine.zig --main-pkg-path . -O ReleaseFast
zig test src/dsp/filter.zig --main-pkg-path . -O ReleaseSafe
```

## Understanding Test Results

### Successful Test Output

```
All 15 tests passed.
```

Individual test details are shown with:
- Test name
- Pass/fail status
- Timing information

### Failed Test Output

```
Test [1/15] test.audio_engine.init... FAIL (AssertionFailure)
./src/audio/engine.zig:450:5: 0x1234567 in test.audio_engine.init
    try testing.expect(!engine.playing.load(.monotonic));
    ^
0 passed; 1 failed.
```

**How to interpret:**
1. **Test name:** `test.audio_engine.init`
2. **Error type:** `AssertionFailure`
3. **File and line:** `engine.zig:450:5`
4. **Failed assertion:** The specific check that failed

### Build Verification Results

**Success:**
```
✅ All build verification tests passed!

Summary:
  - Build: SUCCESS
  - Executable: EXISTS (45MB)
  - Platform compatibility: VERIFIED
  - Symbol linkage: CLEAN
```

**Failure example:**
```
❌ FAILED: Build Verification

   Last 20 lines of output:
   [compiler error messages]
```

**Action:** Check the error messages in `/tmp/build.log`

### Integration Test Results

**Audio backend test success:**
```
✅ All audio backend tests passed!
```

**Memory leak detection:**
```
Memory leak detected!
```

**Action:** Review the allocator usage in the failing test, ensure all `defer deinit()` calls are present.

### Test Suite Summary

```
==================================
📊 Test Suite Summary
==================================
Total Tests:  10
Passed:       10 ✅
Failed:       0 ❌

🎉 All tests passed!
```

Or with failures:
```
⚠️  Some tests failed
Build Status: ❌ NEEDS FIXES
```

## Writing New Tests

### Unit Test Pattern

Create tests alongside the code they test:

```zig
// In src/effects/delay.zig

const std = @import("std");
const testing = std.testing;

pub const Delay = struct {
    // Implementation...

    pub fn process(self: *Delay, input: []const f32, output: []f32) void {
        // Process audio...
    }
};

// Tests go at the bottom of the file
test "Delay: initialization" {
    var delay = Delay.init(48000, 0.5);
    defer delay.deinit();

    try testing.expect(delay.delay_time == 0.5);
}

test "Delay: process produces delayed output" {
    var delay = Delay.init(48000, 0.1); // 100ms delay
    defer delay.deinit();

    const input = [_]f32{1.0, 0.0, 0.0, 0.0};
    var output = [_]f32{0.0} ** 4;

    delay.process(&input, &output);

    // First sample should be dry
    try testing.expectApproxEqAbs(@as(f32, 1.0), output[0], 0.01);

    // Later samples should have delay tail
    try testing.expect(output[3] != 0.0);
}

test "Delay: dry/wet mix" {
    var delay = Delay.init(48000, 0.1);
    defer delay.deinit();

    delay.setMix(0.0); // 100% dry

    const input = [_]f32{1.0} ** 128;
    var output = [_]f32{0.0} ** 128;

    delay.process(&input, &output);

    // Output should match input when fully dry
    for (input, output) |in, out| {
        try testing.expectApproxEqAbs(in, out, 0.01);
    }
}
```

### Integration Test Pattern

Create standalone test files in `./tests/`:

```zig
// tests/test_my_feature.zig

const std = @import("std");
const testing = std.testing;
const Engine = @import("../src/audio/engine.zig").AudioEngine;
const Track = @import("../src/audio/track.zig").Track;

test "Feature: complete workflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Setup
    var engine = try Engine.init(allocator, .{
        .sample_rate = 48000,
        .buffer_size = 512,
    });
    defer engine.deinit();

    // 2. Perform operations
    try engine.addTrack("Test Track");
    engine.setTrackGain(0, 0.5);

    // 3. Verify results
    try testing.expectApproxEqAbs(@as(f32, 0.5), engine.getTrackGain(0), 0.001);
}
```

### Test Naming Conventions

```zig
// Format: "Module: what it tests"
test "AudioEngine: initialization" { }
test "AudioEngine: play/pause state" { }
test "Reverb: room size parameter" { }
test "MIDI: note on/off messages" { }

// For edge cases, be descriptive
test "Buffer: handles zero-length input" { }
test "Delay: clamps negative delay times to zero" { }

// For integration tests
test "Project Persistence: save and load round-trip" { }
test "Audio Backend: multiple start/stop cycles" { }
```

### Test Best Practices

1. **Isolation:** Each test should be independent
```zig
test "Independent test" {
    // Create fresh state for this test
    var state = State.init();
    defer state.deinit();

    // Test operations
    // ...
}
```

2. **Cleanup:** Always use `defer` for cleanup
```zig
test "With cleanup" {
    var allocator = testing.allocator;
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data); // Always runs, even if test fails
}
```

3. **Clear assertions:** Use descriptive test checks
```zig
// Good
try testing.expectEqual(@as(u32, 48000), engine.sample_rate);
try testing.expectApproxEqAbs(@as(f32, 0.5), gain, 0.001);

// Less clear
try testing.expect(engine.sample_rate == 48000);
try testing.expect(gain > 0.49 and gain < 0.51);
```

4. **Memory leak detection:** Use GPA in integration tests
```zig
test "No leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Test code using allocator
}
```

5. **Mock external dependencies:**
```zig
const MockEngine = struct {
    process_count: usize = 0,

    fn processCallback(ctx: *anyopaque, buffer: []f32) void {
        const self: *MockEngine = @ptrCast(@alignCast(ctx));
        self.process_count += 1;
        @memset(buffer, 0);
    }
};

test "Callback invocation" {
    var mock = MockEngine{};
    backend.setEngine(@ptrCast(&mock), MockEngine.processCallback);

    try backend.start();
    std.time.sleep(100 * std.time.ns_per_ms);
    backend.stop();

    try testing.expect(mock.process_count > 0);
}
```

### Adding Tests to Test Suite

To add a new test to `./tests/run_tests.sh`:

```bash
# Add after existing tests
run_test "My New Feature Tests" "zig test src/my_feature.zig --main-pkg-path ."

# Or for integration tests
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test: My Integration Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if zig run tests/test_my_integration.zig --main-pkg-path .; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo "✅ PASSED: My Integration Test"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "❌ FAILED: My Integration Test"
fi
```

## TDD Principles

This project follows Test-Driven Development principles where appropriate:

### The TDD Cycle

1. **Red:** Write a failing test
2. **Green:** Write minimal code to make it pass
3. **Refactor:** Improve the code while keeping tests passing

### TDD in Practice

**Example: Adding a new audio effect**

```zig
// Step 1: RED - Write failing test
test "Chorus: modulation depth affects output" {
    var chorus = Chorus.init(48000);
    defer chorus.deinit();

    chorus.setDepth(0.5);

    const input = [_]f32{1.0} ** 128;
    var output = [_]f32{0.0} ** 128;

    chorus.process(&input, &output);

    // Output should differ from input due to modulation
    var differs = false;
    for (input, output) |in, out| {
        if (@abs(in - out) > 0.01) {
            differs = true;
            break;
        }
    }
    try testing.expect(differs);
}

// Step 2: GREEN - Implement minimal functionality
pub const Chorus = struct {
    sample_rate: f32,
    depth: f32,

    pub fn init(sample_rate: u32) Chorus {
        return .{
            .sample_rate = @floatFromInt(sample_rate),
            .depth = 0.0,
        };
    }

    pub fn setDepth(self: *Chorus, depth: f32) void {
        self.depth = depth;
    }

    pub fn process(self: *Chorus, input: []const f32, output: []f32) void {
        // Minimal implementation to pass test
        for (input, output, 0..) |sample, *out, i| {
            const modulation = @sin(@as(f32, @floatFromInt(i)) * 0.1) * self.depth;
            out.* = sample + modulation;
        }
    }

    pub fn deinit(self: *Chorus) void {
        _ = self;
    }
};

// Step 3: REFACTOR - Improve implementation
// Add proper LFO, delay line, better modulation, etc.
```

### When to Use TDD

**Good for:**
- New effects and DSP algorithms
- Audio engine features
- Project persistence
- MIDI processing
- Backend abstractions

**Not necessary for:**
- UI code (better tested manually)
- Simple getters/setters
- Trivial wrappers
- One-time scripts

### TDD Examples in Codebase

**PulseAudio backend** (`tests/test_pulseaudio_backend.zig`):
- Tests written before implementation
- Each feature tested in isolation
- Integration tests for complete workflows
- Memory leak tests for resource management

**Project persistence** (`src/project/persistence_integration_test.zig`):
- Deep integration test
- Verifies save/load round-trip
- Tests complex nested structures
- Ensures data integrity

**C API bridge** (`src/audio/engine_c_api_test.zig`):
- Tests C API before integration
- Verifies parameter passing
- Ensures type safety at boundary

## CI/CD Integration

### Running Tests in CI

Add to your CI pipeline (GitHub Actions example):

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.14.0

      - name: Install Dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libpulse-dev libgtk-4-dev

      - name: Run Tests
        run: ./tests/run_tests.sh

      - name: Upload Build Logs
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: build-logs
          path: /tmp/build.log
```

### Pre-commit Hook

Add to `./.git/hooks/pre-commit`:

```bash
#!/bin/bash
# Run tests before allowing commit

echo "Running tests before commit..."

if ./tests/test_build.sh; then
    echo "Build tests passed"
else
    echo "Build tests failed, aborting commit"
    exit 1
fi

# Optional: Run full test suite (slower)
# ./tests/run_tests.sh

exit 0
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

### Test Coverage

While Zig doesn't have built-in coverage tools yet, you can track coverage manually:

```bash
# Count test blocks
grep -r "^test \"" src/ | wc -l

# Count public functions
grep -r "^pub fn" src/ --include="*.zig" | wc -l

# Estimate coverage
# Coverage ≈ (test count / public function count) * 100%
```

## Troubleshooting

### Tests Pass Locally but Fail in CI

**Likely causes:**
- Different dependency versions
- Platform differences
- Race conditions in concurrent tests
- Environment-specific paths

**Solutions:**
- Pin dependency versions
- Use platform detection in tests
- Add synchronization to tests
- Use temporary directories

### Memory Leak False Positives

Sometimes GPA reports leaks that aren't real:

```zig
// If you see:
// error: Memory leak detected!

// Check for:
defer {
    const leaked = gpa.deinit();
    if (leaked != .ok) {
        std.debug.print("Leaked memory!\n", .{});
        // Add debugging here
    }
}
```

### Flaky Tests

Audio tests can be timing-sensitive:

```zig
// Instead of:
try backend.start();
try testing.expect(backend.running.load(.seq_cst));

// Use:
try backend.start();
std.time.sleep(10 * std.time.ns_per_ms); // Give it time to start
try testing.expect(backend.running.load(.seq_cst));
```

### Platform-Specific Test Failures

Use platform detection:

```zig
test "Platform-specific feature" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Linux-specific test code
}
```

## Summary

This testing infrastructure provides:

- **Build verification** to catch compilation issues early
- **Unit tests** for individual module correctness
- **Integration tests** for multi-module workflows
- **Memory leak detection** for resource safety
- **Platform compatibility** checks
- **Real-time safety** verification for audio code
- **TDD support** for feature development

Run `./tests/run_tests.sh` before every commit to ensure code quality.

For questions or issues with testing, see:
- `./docs/development/guide.md` - Development workflow
- `./docs/AUDIO_BACKEND_ARCHITECTURE.md` - Backend architecture
- `./docs/reference/troubleshooting.md` - Common problems
