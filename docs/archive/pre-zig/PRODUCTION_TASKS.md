# Production Readiness Tasks

Parallelizable micro-tasks for sub-agents. Each task is independent and can be completed without conflicts.

## Task Execution Guidelines

1. **Claim one task ID** (e.g., DOC-01) before starting
2. **Read only the file(s) listed** for that task
3. **Make minimal, focused changes** - only what the task requires
4. **Run tests after changes**: `zig test <file> --main-pkg-path .`
5. **Run formatter**: `zig fmt <file>`
6. **Verify build**: `zig build`

## Parallelization Rules

- **DOC-XX**: All parallel (different line ranges in same file OK)
- **CONST-XX**: All parallel (different files)
- **TEST-XX**: All parallel (adding new tests)
- **FIX-XX**: Check dependencies before starting
- **VALID-XX**: All parallel (different files)

---

## DOC: Add Doc Comments

| ID | File | Items to Document |
|----|------|-------------------|
| DOC-01 | `src/audio/engine.zig` | `EngineConfig`, `AudioEngine`, `TRACK_COUNT`, `init`, `deinit`, `start`, `stop`, `process` |
| DOC-02 | `src/audio/engine.zig` | `getCpuUsage`, `getPosition`, `isPlaying`, `isRecording`, `getAudioHealthStats` |
| DOC-03 | `src/audio/engine.zig` | `setTrackGain`, `getTrackGain`, `setMasterGain`, `getMasterGain`, `setTrackPan`, `getTrackPan` |
| DOC-04 | `src/audio/engine.zig` | `setTrackMute`, `getTrackMute`, `setTrackSolo`, `getTrackSolo`, `setTrackArm`, `getTrackArm` |
| DOC-05 | `src/audio/engine.zig` | `getTrackMeter`, `getMasterMeterLeft`, `getMasterMeterRight`, `loadTrackFile`, `resetTracks` |
| DOC-06 | `src/audio/track.zig` | `AudioClip`, `Track`, `MAX_BUFFER_FRAMES`, `init`, `deinit` |
| DOC-07 | `src/audio/track.zig` | `loadFile`, `loadFromBuffer`, `setInstrument`, `removeInstrument`, `reset` |
| DOC-08 | `src/audio/track.zig` | `noteOn`, `noteOff`, `hasActiveContent`, `enableClipSync`, `getSyncManager` |
| DOC-09 | `src/audio/backend.zig` | `BackendConfig`, `BackendType`, `Backend`, `init`, `deinit`, `start`, `stop`, `prepare` |
| DOC-10 | `src/dsp/core.zig` | `RingBuffer`, `DelayLine`, `WindowType`, `generateWindow`, `generateWindowWithParam` |
| DOC-11 | `src/dsp/core.zig` | `cubicInterpolate`, `catmullRomInterpolate`, `sinc`, `windowedSinc` |
| DOC-12 | `src/dsp/core.zig` | `powerToDb`, `dbToPower`, `midiToFreq`, `freqToMidi`, `freqToPeriod`, `periodToFreq` |
| DOC-13 | `src/dsp/core.zig` | `OnePoleSmoother`, `LinearRamp`, `hardClip`, `softClipTanh`, `softClipPoly` |
| DOC-14 | `src/midi/midi.zig` | `MIDIEvent`, `MIDIBackend`, `init`, `deinit`, `connectAllSources` |
| DOC-15 | `src/midi/midi.zig` | `getSourceCount`, `getDestinationCount`, `setEventCallback`, `pollEvents`, `sendNoteOn` |
| DOC-16 | `src/project/project.zig` | `EffectState`, `EffectsChainState`, `ClipState`, `TrackState` |
| DOC-17 | `src/project/project.zig` | `ProjectHeader`, `Project`, `init`, `markDirty`, `clearDirty`, `hasSaveLocation` |

**Template:**
```zig
/// Brief one-line description.
///
/// Longer description explaining behavior, parameters, return values, errors.
pub fn functionName(...) ...
```

---

## CONST: Replace Magic Numbers

| ID | File | Constants to Add |
|----|------|------------------|
| CONST-01 | `src/audio/engine.zig` | `DEFAULT_SAMPLE_RATE = 48000`, `DEFAULT_BUFFER_SIZE = 512`, `DEFAULT_TEMPO = 120.0` |
| CONST-02 | `src/audio/engine.zig` | `MIN_TEMPO = 20.0`, `MAX_TEMPO = 300.0`, `DEFAULT_GAIN = 0.75` |
| CONST-03 | `src/audio/clip.zig` | `DEFAULT_SAMPLE_RATE = 48000`, `PEAKS_PER_SECOND = 100` |
| CONST-04 | `src/audio/recording.zig` | `MAX_RECORD_SECONDS = 300` |
| CONST-05 | `src/audio/export.zig` | `EXPORT_BUFFER_SIZE = 1024`, `DEFAULT_EXPORT_DURATION = 10.0` |
| CONST-06 | `src/audio/pulseaudio.zig` | `THREAD_START_TIMEOUT_US = 100_000_000`, `LOG_INTERVAL = 100` |
| CONST-07 | `src/dsp/stereo.zig` | `DEFAULT_DELAY_BUFFER_SIZE = 512`, `DEFAULT_DELAY_SAMPLES = 20` |
| CONST-08 | `src/dsp/dynamics.zig` | `DEFAULT_LOOKAHEAD_MS = 64`, `LOOKAHEAD_BUFFER_SIZE = 512` |
| CONST-09 | `src/dsp/granular.zig` | `MAX_BUFFER_SIZE = 65536`, `MAX_GRAIN_SIZE = 8192` |
| CONST-10 | `src/effects/reverb.zig` | `REFERENCE_SAMPLE_RATE = 44100.0`, `STEREO_SPREAD = 23` |
| CONST-11 | `src/midi/midi_clip.zig` | `MAX_MIDI_NOTE = 127`, `MAX_VELOCITY = 127` |
| CONST-12 | `src/project/project.zig` | `DEFAULT_VOLUME = 0.75`, `DEFAULT_MASTER_VOLUME = 0.75` |
| CONST-13 | `src/core/undo_v2.zig` | `MAX_HOT_ACTIONS = 50`, `MAX_TOTAL_ACTIONS = 200` |

**Template:**
```zig
// At top of file, after imports:
pub const DEFAULT_SAMPLE_RATE: u32 = 48000;

// Replace: .sample_rate = 48000,
// With:    .sample_rate = DEFAULT_SAMPLE_RATE,
```

---

## TEST: Add Missing Tests

| ID | File | Tests to Add |
|----|------|--------------|
| TEST-01 | `src/audio/recording.zig` | `Recording.init`, `start`, `stop`, basic flow |
| TEST-02 | `src/audio/recording.zig` | `getRecordedData`, `getDuration`, `saveToFile` |
| TEST-03 | `src/dsp/utils.zig` | `dbToLinear`, `linearToDb` edge cases |
| TEST-04 | `src/audio/backend.zig` | `setOutputDevice`, error handling |
| TEST-05 | `src/project/persistence.zig` | Error handling, corrupted file recovery |
| TEST-06 | `src/audio/export.zig` | `AudioExporter.init`, progress callbacks |
| TEST-07 | `src/effects/reverb.zig` | Parameter changes, sample rate changes |
| TEST-08 | `src/effects/delay.zig` | Feedback limits, stereo spread |
| TEST-09 | `src/effects/compressor.zig` | Attack/release, ratio, knee |
| TEST-10 | `src/effects/filter.zig` | All filter types, resonance edge cases |
| TEST-11 | `src/dsp/granular.zig` | Grain overlap, buffer boundaries |
| TEST-12 | `src/dsp/phase_vocoder.zig` | Time stretch accuracy |
| TEST-13 | `src/midi/midi_clip.zig` | Note overlap, velocity curves |
| TEST-14 | `src/core/undo_v2.zig` | Memory pressure, snapshot limits |

**Template:**
```zig
test "ModuleName: specific behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try functionUnderTest(allocator, args);
    defer result.deinit();

    try std.testing.expectEqual(expected, result.value);
}
```

---

## FIX: Implement TODOs

| ID | File:Line | Description |
|----|-----------|-------------|
| FIX-01 | `src/dsp/resample.zig:59, src/audio/engine_c_api.zig:296` | Implement sample rate conversion | COMPLETED: Added `resampleLinearByRate()` function with upsampling, downsampling, and same-rate tests. Implemented resampling in `audio_engine_load_track_audio()` C API with channel deinterleaving. Fixed 6 pre-existing C build errors (M_PI undefined). NOTE: Full build verification blocked by pre-existing CoreAudio linking errors on Linux (recording.zig, coreaudio.zig unconditionally importing macOS APIs). |
| FIX-02 | `src/core/undo_v2.zig:183,200,218` | Add proper monotonic timestamps |
| FIX-03 | `src/system/detect.zig:447` | Implement ALSA MIDI device enumeration |
| FIX-04 | `src/system/detect.zig:378` | Get display scale from windowing system |
| FIX-05 | `src/config/config.zig:62` | Implement config save function |
| FIX-06 | `src/instruments/instruments.zig:42` | Get sample rate from audio engine |

---

## STUB: Complete Stub Implementations

| ID | File | Description |
|----|------|-------------|
| STUB-01 | `src/audio/wasapi.zig` | Windows WASAPI backend (entire file) |
| STUB-02 | `src/audio/backend.zig:217-220` | `setOutputDevice` for all backends |
| STUB-03 | `src/system/detect.zig:321,324` | Windows audio/MIDI detection |

---

## VALID: Add Input Validation

| ID | File | Functions to Validate |
|----|------|----------------------|
| VALID-01 | `src/audio/wav.zig` | Path validation, file size limits |
| VALID-02 | `src/project/persistence.zig` | Path validation, version checks |
| VALID-03 | `src/audio/clip_c_api.zig` | Null pointer checks, index bounds |
| VALID-04 | `src/audio/devices_c_api.zig` | Null pointer checks, index bounds |
| VALID-05 | `src/audio/effects_c_api.zig` | Null pointer checks, param ranges |
| VALID-06 | `src/audio/scale_c_api.zig` | Note range validation (0-127) |

---

## Summary

| Category | Count | Parallelizable |
|----------|-------|----------------|
| DOC | 17 | Yes (all) |
| CONST | 13 | Yes (all) |
| TEST | 14 | Yes (all) |
| FIX | 6 | Check deps |
| STUB | 3 | Yes (platform) |
| VALID | 6 | Yes (all) |
| **Total** | **59** | |
