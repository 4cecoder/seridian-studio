# PulseAudio Integration Test

## Purpose

This integration test (`test_pulseaudio_integration.zig`) verifies that the AudioEngine and PulseAudio backend work together end-to-end in a real runtime environment.

## What It Tests

The test executes the full audio chain:

1. **Creates AudioEngine** - Initializes the engine with sample rate 48kHz, buffer size 512
2. **Creates PulseAudio Backend** - Initializes PulseAudio connection
3. **Connects them together** - Sets up engine callbacks via `setEngine()`
4. **Prepares audio stream** - Calls `prepare()` to create PulseAudio stream
5. **Starts playback** - Spawns audio thread, begins processing
6. **Runs for 2 seconds** - Allows callbacks to execute
7. **Verifies callbacks happened** - Confirms engine callbacks were invoked
8. **Verifies samples were processed** - Confirms audio buffers were filled
9. **Stops playback** - Terminates audio thread
10. **Cleans up** - Frees all resources, checks for memory leaks

## Running the Test

```bash
# From project root
./tests/run_pulseaudio_integration.sh
```

## Expected Output

```
===========================================================
  PULSEAUDIO INTEGRATION TEST
  Engine + PulseAudio Backend Full Chain
===========================================================

Configuration:
  Sample Rate:    48000 Hz
  Buffer Size:    512 samples
  Backend:        pulseaudio
  Test Duration:  2000 ms

[1/6] Creating AudioEngine...
  SUCCESS: Engine created with pulseaudio backend

[2/6] Connecting engine to backend...
  SUCCESS: Backend connected and prepared

[3/6] Starting playback...
  SUCCESS: Playback started

[4/6] Running for 2000 ms...
  SUCCESS: Completed run duration

[5/6] Verifying callbacks and sample processing...
  Callback count:     11 (expected ~187)
  Samples processed:  11264 (expected ~191488)
  SUCCESS: Callbacks and samples verified

[6/6] Stopping playback...
  SUCCESS: Playback stopped

===========================================================
  INTEGRATION TEST PASSED
===========================================================

Detailed Metrics:
  Engine callbacks:      11
  Samples processed:     11264
  Runtime:               150.20 ms
  Average callback rate: 73.24 Hz
  Buffer size:           512 frames (1024 samples stereo)
  Sample rate:           48000 Hz

This proves the engine and PulseAudio backend work together.
```

## Success Criteria

- Test exits with code 0
- At least 5 callbacks were executed
- Samples were processed
- No memory leaks detected
- Audio thread starts and stops cleanly

## Requirements

- PulseAudio must be installed and running
- System must have `pulse` and `pulse-simple` libraries
- Audio output device must be available

## What This Proves

This test demonstrates that:

- The engine and backend can be connected together
- Audio callbacks are actually invoked in the real audio thread
- Sample buffers are properly processed
- The full chain works end-to-end
- Memory management is correct (no leaks)
- Thread lifecycle is handled properly

This is a **runtime integration test**, not a unit test. It spawns real threads, makes real system calls, and verifies actual behavior.
