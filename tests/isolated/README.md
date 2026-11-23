# Isolated Audio Tests

This directory contains isolated tests that verify audio components work independently.

## test_engine_isolated.zig

Tests the core audio engine functionality by calling `process()` directly without requiring a backend to be running.

### What it tests:
- Engine initialization
- Loading audio data into tracks
- Direct buffer processing via `process()`
- Transport controls (start/stop/seek)
- Position advancement
- Gain controls
- Continuous audio generation

### Running the test:

```bash
zig build test-engine-isolated
```

### Expected output:

The test will print detailed progress for each test case and should exit with code 0 on success.

### Key insight:

This test proves the engine's core processing logic is **completely independent** of any audio backend. While the engine still initializes a backend (for now), the test never calls `backend.start()` - it directly calls `engine.process()` to generate audio, demonstrating that the engine can work standalone.

### Test results:

- ✓ Samples generated
- ✓ Position advances correctly
- ✓ Transport controls work
- ✓ Gain controls affect output
- Exit code: 0 on success

---

## test_pipewire_isolated.zig

Tests the PipeWire backend in complete isolation, verifying API contract and state management.

### What it tests:
- Backend initialization
- Initial state verification (running flag, config)
- Stream preparation (prepare())
- Start/stop functionality
- Running state verification
- Multiple start/stop cycles
- Clean shutdown (deinit())

### Running the test:

```bash
# Using zig build
zig build test-pipewire-isolated

# Or using the shell script
./tests/isolated/run_pipewire_test.sh
```

### Expected output:

The test will print detailed progress for each step and exit with code 0 on success.

### Current status:

The PipeWire backend is currently a stub implementation. The test verifies:
- ✓ Backend initializes correctly
- ✓ Configuration is stored properly
- ✓ State management works (running flag via atomics)
- ✓ API contract is correct
- ⚠ Stream preparation returns expected error (not implemented in stub)

When PipeWire implementation is complete, this test should be extended to verify:
- Audio thread execution
- Callback invocation
- Actual audio processing
- Buffer management

### Test results:
- ✓ Backend initializes
- ✓ State transitions work
- ⚠ prepare() not yet implemented (expected for stub)
- Exit code: 0 on success

---

## test_pulseaudio_isolated.zig

Tests the PulseAudio backend in complete isolation with real audio thread execution.

### What it tests:
- Backend initialization
- Stream preparation
- Audio thread spawning
- Callback execution and counting
- Buffer processing
- Start/stop cycles
- Thread safety
- Clean shutdown

### Running the test:

```bash
# Using zig build
zig build run-test-pulseaudio-isolated
```

### Requirements:

- PulseAudio must be installed and running on the system
- On Linux systems with PulseAudio available

### Expected output:

The test runs callbacks for 500ms and verifies they execute correctly. Exit code 0 on success.

---

## test_coreaudio_isolated.zig

Tests the CoreAudio backend in complete isolation with real audio callback execution.

### What it tests:
- Backend initialization
- Audio unit setup
- Render callback registration
- Callback execution and counting
- Buffer processing
- Start/stop cycles
- Thread safety
- Clean shutdown

### Running the test:

```bash
# Using zig build
zig build test-coreaudio-isolated

# Or using the shell script
./tests/isolated/run_coreaudio_test.sh
```

### Requirements:

- macOS system with CoreAudio framework
- Test automatically skips on non-macOS platforms

### Expected output:

On macOS: The test runs callbacks for 500ms and verifies they execute correctly. Exit code 0 on success.

On non-macOS: The test prints "Skipped (not on macOS)" and exits with code 0.

### Platform behavior:

- **macOS**: Full CoreAudio backend test with real audio callbacks
- **Linux/Other**: Gracefully skips with success exit code
- Includes stub implementations for cross-platform compilation

---

## Why Isolated Tests?

Isolated tests verify that each component works independently:

- **No Dependencies** - Test backends without the full audio engine
- **Fast Feedback** - Quick compile and run times
- **Clear Results** - Easy to see what's working and what's not
- **API Verification** - Ensure components implement expected interfaces
- **Platform Testing** - Test backends on their native platforms

These complement integration tests which verify the full audio chain (engine + backend).
