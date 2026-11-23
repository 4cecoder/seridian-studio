# Seridian Studio: Latency, Automation and Live Performance Spec

Status: draft, 2026-10-29. Owner: [seridian.dev](https://seridian.dev).
Parent: [Feature Parity Spec](feature-parity.md).

On stage, a DAW is judged on three things: notes land when they should, knobs
do what they say without clicks, and it never glitches. This spec sets numeric
targets for each, records where the engine stands today (verified against the
code at `fe1b6a2`), and defines the work in milestone order.

## Targets

| Area | Target |
| --- | --- |
| Output latency | Selectable buffer of 32–2048 frames. Default 128 (2.7 ms at 48 kHz). Changeable while running, with no restart |
| Round-trip latency | Measured and shown in the status bar. Recordings land compensated within ±1 sample of the calibrated offset |
| Sequenced timing | Clip notes and automation are sample-accurate: 0 samples of error, independent of buffer size |
| Live MIDI timing | Hardware notes are placed by their timestamp. Jitter ≤ 1 ms, instead of up to one buffer |
| Parameter changes | No zipper noise. Every parameter is smoothed; gain and pan are ramped per sample |
| Stability | 0 xruns in a 1-hour soak at 128 frames with the reference live set. Nothing on the audio thread allocates, locks, logs or does I/O |
| Plugin delay compensation | Parallel paths stay phase-aligned: a null test passes with any mix of latent effects |
| Monitoring | Low-latency monitoring mode adds 0 samples to armed, monitored tracks |

## Where the engine is today

Verified in code. Items 1–4 are live-performance bugs and belong in M0, ahead of
any new feature.

| # | Finding | Location | Effect on stage |
| --- | --- | --- | --- |
| 1 | The CoreMIDI read callback is given `&self` of a stack local, which is gone once `init` returns | `src/midi/coremidi.zig:175,199` | Hardware MIDI input reads freed stack memory: crashes or garbage notes |
| 1b | Received packet lists were parsed with Zig's natural alignment. CoreMIDI uses `#pragma pack(4)`: first packet at offset 4, data at +10, 4-byte steps on arm64 | `src/midi/coremidi.zig` | Hardware notes misread or dropped. **Fixed with 1** in the commit after `af94a72` |
| 2 | Hardware MIDI calls `Track.noteOn` directly on the CoreMIDI thread while the audio thread renders the same voices | `src/runtime.zig` `midiEventCallback` | Data race on voice state: stuck notes, glitches, possible crashes. **Fixed 2026-11-13:** MIDI callbacks and the note C API push to `src/audio/event_queue.zig`, drained by the audio thread |
| 3 | The audio thread takes a spin lock on MIDI clips that the UI also takes while editing | `src/midi/midi_clip.zig` (`mutex.lock()`) | Editing a clip during playback can stall the audio thread (priority inversion → dropout). **Fixed 2026-11-13:** immutable snapshots (A4) |
| 4 | Clip notes fire at the start of the buffer, not at their sample position | `src/audio/engine.zig` `process`, MIDI section | Timing jitter up to one buffer: 10.7 ms at the current 512-frame default. **Fixed 2026-11-13:** split rendering at note frames (A3, clip notes) |
| 5 | Gains are atomics applied once per block with no smoothing | `src/audio/engine.zig` (`track_gains`, `master_gain`) | Zipper noise on fader moves; automation would inherit it. **Fixed 2026-11-13:** gain, master and pan ramp per sample over 10 ms |
| 6 | Default buffer is 512 frames; device latency and safety offset are never queried | `src/config/config.zig`, `src/audio/coreaudio.zig` | Too slow for playing live; recordings can't be latency-compensated. **Default fixed 2026-11-13 (128 frames);** latency query still open |
| 7 | No effect reports latency; no PDC | `src/effects/effect.zig` | Latent effects (PitchPure tune ≈ 26 ms) push tracks out of phase. **Fixed:** `src/audio/pdc.zig` |
| 8 | No automation engine | — | Nothing to perform with. **Partly fixed:** lanes for gain, pan, reverb wet and master (`src/audio/automation.zig`), per sample for gain/pan and on a 32-sample grid for effects; modes, curves and recording are still open |
| 9 | Health counters exist (NaN/inf, clips, `buffer_underruns`) but aren't shown | `src/audio/engine.zig` `getAudioHealthStats` | Problems on stage are invisible |

## Design

### A. Real-time core (M0–M1)

1. **Fix CoreMIDI ownership (M0). Done:** the backend now comes from the per-source refCon, packets are parsed in Apple's packed layout, and regression tests are mutation-checked.
   Original plan:
   - Allocate the backend on the heap (or let `Runtime` own it), then create
     the input port with a pointer that stays valid.
   - Add a test that sends a packet through the callback after `init` returns.
2. **One event path into the audio thread (M0).**
   - Hardware MIDI, UI note audition, transport and parameter changes all go
     through lock-free single-producer/single-consumer queues: one per
     producer thread, drained at the start of each block.
   - Nothing outside the audio thread touches voice state.
3. **Timestamped events, split rendering (M1).**
   - Every event carries a sample offset within the block:
     - clip notes: from beat → sample conversion;
     - hardware MIDI: from the CoreMIDI host timestamp, mapped through the
       device clock, plus one block of fixed delay so timing stays constant.
   - The engine renders each track in sub-blocks split at event offsets. This
     needs no instrument changes, and timing becomes sample-accurate.
4. **Lock-free clip access (M1).**
   - The UI edits a copy of a clip and publishes it with an atomic pointer
     swap. The audio thread only reads immutable snapshots.
   - Old versions are freed on the UI thread once the audio thread has moved
     past them, tracked by an epoch counter.
   - Replaces the spin lock in `midi_clip.zig`.
5. **Parameter smoothing (M1).**
   - Every parameter is a smoothed value: target set atomically, ramped on the
     audio thread.
   - Gain, pan and sends ramp linearly per sample over the block. Other
     parameters use a one-pole filter with a ~10 ms time constant (PitchPure's
     `params.rs` pattern).
6. **Thread hygiene (M1).**
   - The audio thread never allocates, locks, logs or does I/O; tests enforce
     this (see Verification).
   - Long audio streams from disk through a prefetch thread with a lock-free
     ring.
   - When the multicore graph lands (M2), worker threads join the device's
     real-time workgroup (`os_workgroup` on macOS) so the OS schedules them
     with the I/O thread.

### B. Latency management (M1–M2)

1. **Buffer and device control (M1).**
   - Buffer size 32–2048 and sample rate in Settings.
   - Changes apply live: fade out (5 ms), stop the stream, reconfigure,
     restart, fade in.
   - The default becomes 128 frames; drop to 256 automatically if xruns repeat
     at startup, and say so in the status bar.
2. **Know the real latency (M1).**
   - Query the device's input and output latency, safety offset and stream
     latency (`kAudioDevicePropertyLatency`, `kAudioDevicePropertySafetyOffset`,
     `kAudioStreamPropertyLatency`; PipeWire/WASAPI equivalents).
   - Show it as "Out 3.1 ms · RT 6.4 ms" in the status bar.
3. **Loopback calibration (M1).**
   - Settings → "Measure latency": play an impulse out, record it back in,
     cross-correlate to find the true round trip. Reuse PitchPure's
     latency-measurement test.
   - Store the offset per device; use it in place of the reported value.
4. **Recording compensation (M1).**
   - Recorded audio and MIDI shift earlier by the measured round trip, so takes
     line up with what the performer heard.
5. **Plugin delay compensation (M2).**
   - Effects and plugins report `latency_samples`; this is a new field on the
     Effect interface, with an `effects_c_api` getter.
   - The graph computes the latency of each path and delays the shorter paths
     (tracks, sends, sidechains), so everything meets aligned at the master.
   - Automation, meters and the playhead read the compensated position.
   - Latency changes from plugins re-run the computation outside the audio
     thread.
6. **Low-latency monitoring mode (M2).**
   - One switch in the transport, with a shortcut. On armed, monitored tracks
     it bypasses any effect above a latency threshold (default 2 ms) and
     removes PDC delay from the live input path.
   - Effects can be flagged "live safe" to stay on.
   - UI marks every bypassed effect, so nothing is silently missing.
7. **Latency visibility (M2).** Each effect slot shows its latency, and each
   track header shows the total for the track. A "constrain delay" toggle
   disables effects above the threshold project-wide (performance mode).

### C. Automation (M2)

1. **Model.**
   - Each automatable parameter has a lane of breakpoints. Each breakpoint is
     a time in beats, a normalised value from 0 to 1, and a curve to the next
     point: hold, linear, exponential or S-curve.
   - Stored in the project file (format v2), undoable through the existing
     undo system.
   - Clip envelopes (automation that moves with the clip, as in Ableton) come
     in M3.
2. **What is automatable.**
   - Track volume, pan, mute and sends.
   - Every instrument and effect parameter, through the existing
     `*_param_*` C APIs.
   - Macros, plugin parameters (CLAP, M2), and tempo (tempo map, M3).
3. **Playback.**
   - The audio thread evaluates lanes from an immutable snapshot (as in A4) at
     sub-block resolution: at most 32 samples, and per sample for gain and pan.
   - Output feeds the same smoother as manual changes, so the two can't fight.
4. **Modes.** Off, Read, Touch, Latch and Write per track, plus a global
   override:
   - **Touch:** writes while the control is held, then returns to the lane.
   - **Latch:** writes from the first touch until transport stops.
   - **Write:** overwrites everything it passes.
5. **Recording.**
   - UI gestures send begin/value/end events with timestamps through a queue.
   - The UI thread writes points, thinning them with Ramer–Douglas–Peucker
     (tolerance 0.5% of range) so lanes stay editable.
6. **Manual override (live essential).**
   - Moving an automated control in Read mode overrides its lane until the
     user re-enables automation with one global "Re-enable automation" button.
   - Overridden lanes are drawn dimmed. This matches Ableton, and it's what
     performers expect.
7. **Editing.**
   - Draw, select, move and delete points; draw lines and shapes (ramp, sine,
     square); copy and paste.
   - "Thin" command, and snap to grid.

### D. Live control (M2–M3)

1. **MIDI learn and mapping (M2).**
   - Any parameter maps to a CC, note or pitch bend with min/max and an
     invert option.
   - Takeover modes for controllers without motorised feedback: Pickup (waits
     until the knob crosses the value), Value Scaling, and Jump.
   - Mappings are stored per project, with an optional global controller
     profile.
   - Mapped values are sent back to controllers that support feedback.
2. **Macros (M2).**
   - 8 macro knobs per track, each driving many parameters with their own
     ranges and curves.
   - Macros are automatable and mappable: one knob for a whole build-up.
3. **Clip launcher with launch quantisation (M3).**
   - Launch at the next bar, beat or 1/16, with scenes and follow actions
     (next, random, stop).
   - Stop buttons, plus a global "stop all clips at next bar".
4. **Sync (M3).**
   - Ableton Link, MIDI clock in and out (with jitter smoothing on input),
     tap tempo.
5. **Safety tools (M2).**
   - Panic: all notes off, reset controllers, clear reverb and delay tails.
   - Per-track and total CPU meters; xrun counter in the status bar.
   - Freeze/flatten for heavy tracks; sandboxed plugins (M3).
6. **Performance mode (M4).**
   - Setlists that preload the next project and switch without an audio drop.
   - A UI lock against accidental edits.

## Verification

Each item ships with a `daw verify` check. Checks that run on the offline
`null_backend` belong in CI; the hardware checks are a pre-release checklist.

| Check | Method | Pass |
| --- | --- | --- |
| Sample-accurate notes | Schedule notes at known samples at 64/512/2048 frames; render offline; detect onsets | 0-sample error at every buffer size |
| Live MIDI placement | Inject timestamped events into the MIDI queue; render; measure onsets | ≤ 1 ms from the timestamp |
| No allocation or lock on the audio thread | Counting allocator and lock tracer around `process()` in every engine test | 0 allocations, 0 lock acquisitions |
| Smoothing | Step a gain from 0 to 1; measure energy above 10 kHz on a 100 Hz sine | Below −90 dBFS |
| Automation accuracy | Render a linear volume ramp; compare with the analytic curve | Within 0.01 dB |
| PDC null test | Same signal through a latent effect at 100% dry (latency only) and a plain path, one inverted | Sum below −120 dBFS |
| Recording alignment | Offline loopback: output feeds input with a known delay; record; cross-correlate | ±1 sample after compensation |
| Buffer change while playing | Change the buffer 20 times during playback | No crash, no NaN, no stuck notes |
| Soak | 1 hour at 128 frames with the reference set (16 tracks, instruments, effects, automation) | 0 xruns (nightly macOS run plus a hardware run before each release) |
| CoreMIDI regression | Send packets after `init` returns | Received, no crash (sanitizer clean) |

## Milestones

- **M0:**
  - fix findings 1–3 (CoreMIDI ownership, a single event path, no spin lock
    on the audio thread);
  - allocation and lock checks in tests;
  - health counters in the status bar.
- **M1:**
  - sample-accurate events; lock-free clip snapshots;
  - parameter smoothing;
  - runtime buffer and sample-rate changes, default 128;
  - latency query and display, loopback calibration, recording compensation.
- **M2:**
  - automation engine, lanes, modes and override;
  - PDC; low-latency monitoring mode; latency display per slot;
  - MIDI learn with takeover modes; macros;
  - panic, CPU meters.
- **M3:** clip launcher with quantised launch and scenes, Link, MIDI clock,
  clip envelopes, sandboxed plugins.
- **M4:** setlists and performance mode.
