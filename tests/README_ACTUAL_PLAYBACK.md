# Actual Audio Playback Test

## Overview

This test verifies that **ACTUAL AUDIO** plays through your speakers, not just that callbacks happen.

Many audio tests verify that the audio system is initialized correctly and that callbacks are being invoked, but they don't verify that sound actually comes out of the speakers. This test bridges that gap.

## What It Does

The test performs these steps:

1. **Generates a 440Hz sine wave** (musical note A4) - 5 seconds worth of audio data
2. **Initializes the full AudioEngine** with the PulseAudio backend
3. **Connects the engine to the backend** - sets up the audio callback chain
4. **Loads the test tone into track 0** using the track's buffer loading functionality
5. **Starts playback** and lets it run for 3 seconds
6. **Prints a message** instructing you to listen for the tone
7. **Stops playback** and cleans up all resources

## Running the Test

### Method 1: Using the build system (recommended)

```bash
zig build test-actual-playback
```

### Method 2: Using the shell script

```bash
./tests/run_actual_playback.sh
```

## What You Should Hear

You should hear a **clear, steady 440Hz tone** (the musical note A4, the standard tuning pitch) playing for 3 seconds through your speakers or headphones.

- **If you hear it**: ✅ Audio playback is working end-to-end!
- **If you don't hear it**: ❌ There may be an issue with:
  - Your PulseAudio setup
  - Your audio device configuration
  - The audio engine initialization
  - The backend connection

## What This Test Proves

If the test succeeds (you hear the tone), it proves:

- ✓ **Audio engine initialization works** - The engine starts up correctly
- ✓ **PulseAudio backend initialization works** - The backend connects to PulseAudio
- ✓ **Engine-to-backend connection works** - The callback chain is set up correctly
- ✓ **Audio buffer loading works** - Track.loadFromBuffer() correctly loads audio data
- ✓ **Playback start/stop works** - The audio thread starts and stops cleanly
- ✓ **ACTUAL audio output works** - Sound comes out of your speakers!

## Implementation Details

### File Location
- Test source: `./tests/test_actual_playback.zig`
- Shell script: `./tests/run_actual_playback.sh`
- Build config: Added to `build.zig` as `test-actual-playback` step

### Key Components Used

1. **AudioEngine** - Full audio engine with transport, tracks, and effects
2. **PulseAudio Backend** - Linux audio backend using PulseAudio Simple API
3. **Track.loadFromBuffer()** - Loads audio data from memory into a track
4. **Sine wave generator** - Generates a pure tone for testing

### Test Parameters

- **Sample Rate**: 48000 Hz
- **Buffer Size**: 512 samples
- **Tone Frequency**: 440 Hz (A4)
- **Tone Duration**: 5 seconds (generated)
- **Playback Duration**: 3 seconds (actual playback time)
- **Amplitude**: 0.3 (to avoid clipping)

## Comparison to Other Tests

| Test | What It Verifies | Requires Listening? |
|------|------------------|---------------------|
| `test_pulseaudio_integration.zig` | Callbacks happen, samples processed | No |
| `test_pulseaudio_runtime.zig` | Backend can be initialized | No |
| `test_audio_engine_runtime.zig` | Engine can be initialized | No |
| **`test_actual_playback.zig`** | **Sound comes out of speakers** | **Yes** |

This is the **only test** that requires human verification by listening.

## Troubleshooting

### No sound output

1. **Check PulseAudio is running**:
   ```bash
   pulseaudio --check
   echo $?  # Should return 0
   ```

2. **Check default audio device**:
   ```bash
   pactl info | grep "Default Sink"
   ```

3. **Check volume levels**:
   ```bash
   pactl list sinks | grep -A 10 "Sink #"
   ```

4. **Test PulseAudio directly**:
   ```bash
   paplay /usr/share/sounds/alsa/Front_Center.wav
   ```

### Build errors

Make sure you have PulseAudio development headers installed:
```bash
# Debian/Ubuntu
sudo apt-get install libpulse-dev

# Arch Linux
sudo pacman -S libpulse

# Fedora
sudo dnf install pulseaudio-libs-devel
```

## Success Criteria

The test **succeeds** if:
1. It builds without errors
2. It runs without crashing
3. You hear a 440Hz tone for 3 seconds
4. The tone is clear and steady (no pops, clicks, or distortion)

The test **fails** if:
1. It doesn't build
2. It crashes during execution
3. You hear no sound
4. You hear distorted or intermittent sound
