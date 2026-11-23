# Seridian Studio architecture

Status: draft, 2026-10-29. Owner: [seridian.dev](https://seridian.dev).
Related: [Feature Parity](feature-parity.md), [Live Performance](live-performance.md).

Seridian is one engine serving three audiences: studio (recording and
producing), live performance, and DJs. It is assembled from libraries that
snap together like Lego bricks. Every feature, including everything absorbed
from daw-swift, PitchPure and `feat/overhaul`, lives in exactly one library.
Apps are thin shells that choose which bricks to load.

## Principles

1. **Split by volatility.** Code that changes rarely sits at the bottom; code
   that changes daily sits at the top. A library may depend only on libraries
   below it, which are more stable. CI enforces this.
2. **One stud shape.** Every sound-producing or sound-processing unit (synth,
   sampler, effect, vocal tool, DJ deck) implements the same Device interface.
   Anything that speaks it plugs into the graph, a CLAP plugin wrapper, or the
   offline CLI unchanged.
3. **Real-time safety is structural.** The audio thread touches only
   preallocated memory, lock-free queues and immutable snapshots. Tests prove
   it for every device (see [Engineering process](#engineering-process)).
4. **Test first, measure always.** No feature lands without a failing test
   first, and no hot path lands without a benchmark and a budget.

## Library stack

From most stable (bottom) to most volatile (top):

```text
 L5  Frontends     ui-studio · ui-dj · ui-kit                     (Raven, C)
 L4  Session       session (daw_runtime_*) · project · mcp
 L3  Engine        graph · sequencer · automation · io · plughost
 L2  Devices       instruments · effects · vocal · dj · analysis
 L1  DSP           seridian-dsp
 L0  Core          seridian-core
```

| Lib | Layer | Contents | Comes from | Change rate |
| --- | --- | --- | --- | --- |
| `core` | L0 | RT primitives: SPSC queue, atomics, parameter smoother, epoch reclamation, counting allocator, units, trace ring | `src/utils`, `src/audio/rt_safe.zig`, new | Rare |
| `dsp` | L1 | Pure DSP: filters, oscillators, envelopes, FFT, resampling, phase vocoder, SOLA, pitch detectors (YIN/MPM/ACF + tracker), onset, granular, modal, physical | `src/dsp`, PitchPure `detector_*`, `shifter_sola`, `fft` | Rare |
| `instruments` | L2 | Keys, Wavetable, SuperSaw, FM, sampler, drum rack, drum synth | `src/instruments`, daw-swift sampler + drum synth | Monthly |
| `effects` | L2 | 24 effects, plus modulation FX (chorus, flanger, phaser, tremolo, ring mod), multiband compressor, tape, ducking delay, true-peak limiter | `src/effects`, daw-swift `ModulationEffects`, PitchPure `tape`/`delay`/`limiter` | Monthly |
| `vocal` | L2 | Pitch correction, formant shift, denoise, de-esser, rider, voice EQ, harmony | PitchPure engine | Monthly |
| `analysis` | L2 | Key detection, BPM and beatgrid, onsets, loudness (LUFS), waveform peaks, spectrum | PitchPure `keydetect`, `src/dsp/onset.zig`, `spectral.zig`, `src/audio/peak_cache.zig` | Monthly |
| `dj` | L2 | Deck (player with key lock, cues, loops, beat jump, sync), DJ EQ/filter, crossfader, cue mix | New | Monthly |
| `io` | L3 | Audio backends (CoreAudio, PipeWire, Pulse, WASAPI, null), MIDI (CoreMIDI, ALSA), HID controllers, latency query and calibration | `src/audio` backends, `src/midi` | Monthly |
| `graph` | L3 | Routing, buses, sends, sidechain, PDC, multicore scheduler, metering | `src/audio/engine.zig`, `track.zig` | Weekly |
| `sequencer` | L3 | Transport, tempo map, clips, clip launcher, step sequencer, MIDI scheduling, recording | `src/audio/clip*`, `recording.zig`, `src/midi/midi_clip.zig`, daw-swift step sequencer | Weekly |
| `automation` | L3 | Lanes, modes, override, MIDI learn, macros | New ([Live Performance](live-performance.md) §C–D) | Weekly |
| `plughost` | L3 | CLAP (then VST3, AU) hosting, sandbox process | New; PitchPure harness patterns | Weekly |
| `project` | L4 | Model, file format, undo, autosave, templates, presets | `src/project`, `src/core/undo*`, `src/config` | Weekly |
| `session` | L4 | Wires engine + project + io; exports the `daw_runtime_*` C ABI | `src/runtime.zig`, `src/engine_lib.zig` | Weekly |
| `mcp` | L4 | Agent control over the session C ABI | New | Weekly |
| `ui-kit` | L5 | Shared Raven widgets: knob, fader, meter, waveform, piano keys, pitch graph, automation lane | New, from `raven_app.c`; Raven itself is being translated from C11 to Zig on `feat/raven-zig` | Daily |
| `ui-studio` | L5 | Arrangement, mixer, editors, device dock | `src/ui/raven_app.c` | Daily |
| `ui-dj` | L5 | Decks, library, mixer, performance pads | New | Daily |

### Apps (thin shells)

| App | Loads | Purpose |
| --- | --- | --- |
| `seridian-studio` | everything through `ui-studio` | Record, produce, mix, perform |
| `seridian-dj` | `dj`, `analysis`, `effects`, `io`, `graph`, `ui-dj` | DJ app on the same engine; a project can open in either |
| `seridian` (CLI) | session without UI | `render`, `analyze`, `verify`, `doctor`, `bench` |
| `seridian-mcp` | session + `mcp` | Agent-driven sessions |
| Plugins | one device library + CLAP wrapper | Ship any Seridian device (for example the PitchPure tuner) into other DAWs |

## The Device interface (the stud)

One C ABI, versioned and append-only, declared in `libs/core/include/seridian_device.h`:

- **Descriptor:** id, name, category, and its parameter list (id, name,
  min/max/default, unit, curve, automatable, smoothing time).
- **Lifecycle:** `create(sample_rate, max_block)`, `destroy`, `reset`.
  All allocation happens here.
- **`process(ctx)`:** the context carries:
  - non-interleaved channel buffers (mono/stereo/multichannel),
  - frame count,
  - a sorted event list with sample offsets (notes, parameter changes,
    transport),
  - the transport state.
- **Must not** allocate, lock, log or do I/O inside `process`.
- **Reporting:** `latency_samples`, `tail_samples`.
- **State:** `save_state` and `load_state` to a byte buffer, for projects and
  presets.

Each device library exports `seridian_<lib>_devices()`, which returns its
descriptor table. The graph builds its registry from those tables at startup,
and optional packs can be loaded with `dlopen`. One `process` call per device
per block keeps the cost of crossing a library boundary negligible.

Today's `Effect` and `Instrument` types in Zig become thin adapters over this
interface during migration. PitchPure's mono, latency-reporting modules map
onto it directly.

## Binaries and linking

- **Module split is fine-grained; binary split is coarse.** Inside Zig, each
  library is a Zig module, so hot inner loops still inline across modules.
  Shared libraries are built at layer boundaries, where change rates differ.
- **Build modes:**
  - `-Dlink=dynamic` (development default): one `.dylib`/`.so` per library.
    Editing the UI relinks only `ui-*`; device work relinks only that device
    library.
  - `-Dlink=static` (release option): a single binary per app, for maximum
    inlining and simple distribution.
- RUNPATH is `@loader_path` on macOS and `$ORIGIN` on Linux. This is already
  in `build.zig`.
- **Layout:**

  ```text
  libs/<name>/
    src/          Zig sources
    include/      public C headers (the ABI)
    tests/        unit, golden and property tests
    bench/        benchmarks with budgets
  ```

- `zig build check-layers` scans the `@import`s and fails if a library imports
  from a higher layer.

## Engineering process

Testing and optimisation are a top priority, on equal footing with features.

### Test-driven development

1. **Every change starts with a failing test** in the owning library's
   `tests/`. Bug fixes start with a regression test that reproduces the bug.
2. **Test layers for every library:**

   | Layer | What | Runs |
   | --- | --- | --- |
   | Unit | Pure functions and structs | Every commit |
   | Property | Random parameters and input → no NaN/inf/denormals, bounded output, deterministic | Every commit |
   | Golden render | Offline render on `null_backend` compared with a stored reference within tolerance | Every commit |
   | RT-safety | Counting allocator and lock tracer around every device's `process` | Every commit |
   | ABI | Header compiled and called from C; descriptor and parameter round-trip | Every commit |
   | Integration | Session-level scenarios (record, automate, export) | Every commit |
   | UI | Raven driven through its accessibility tree (`raven_accessibility.h`), as PitchPure's GUI tests do | Every commit |
   | Soak / hardware | 1-hour xrun soak, loopback latency, controller checklist | Nightly / before release |

3. **Port PitchPure's QA gate** (`pitchpure_suite/src/qa_tests.rs`):
   - pitch accuracy within ±8 cents;
   - measured latency equals reported latency;
   - bit-exact bypass;
   - bit-identical offline renders;
   - realtime budget measured in thread CPU time.
4. **`seridian verify`** runs the whole suite against the installed binaries.
   It replaces the GTK-based `daw verify` from `feat/overhaul`.

### Performance

1. **Every device and engine hot path has a benchmark:**
   - `zig build bench` measures ns/sample at 48 kHz, block sizes 32–2048, and
     voice counts 1/16/64;
   - results go to `bench/results.json`.
2. **Budgets:**
   - **Engine overhead:** ≤ 5% of the block time at 128 frames with 64 empty
     tracks.
   - **Reference set:** 16 tracks of instruments, effects and automation run
     at ≤ 35% of one core at 128 frames.
   - **Devices:** each declares its own budget in its bench file.
3. **Regression gate:**
   - CI compares the medians of repeated CPU-time runs with
     `bench/baseline.json`, and fails on more than 10% regression.
   - Baselines are updated only in a commit that says why.
4. **Built-in profiler:**
   - The audio thread writes per-block, per-device timings to a lock-free
     trace ring.
   - The UI shows them as the CPU meter; `seridian bench --trace` exports
     Chrome-trace JSON.
   - Adds no dependency.
5. **Standing optimisation rules:**
   - flush denormals (FTZ/DAZ) on audio threads;
   - SIMD (`@Vector`) in `dsp` inner loops;
   - struct-of-arrays voice state;
   - no per-sample virtual calls;
   - a multicore graph scheduler on the OS real-time workgroup.

### CI gates

These run in order; any failure blocks the merge:
1. fmt
2. layer check
3. build (dynamic and static)
4. unit, property, golden, RT-safety, ABI and integration tests
5. bench regression
6. headless launch
7. UI tests (macOS and Linux)

Soak and hardware checks run nightly and before each release.

## Migration plan

Incremental: every step keeps `zig build test` green and the app launching.

1. **Prerequisites (M0):**
   - remove the upward import `dsp/voice.zig` → `instruments/`;
   - add `check-layers`, the counting allocator and the bench harness;
   - fix the M0 live-performance bugs, test-first ([Live Performance](live-performance.md)).
2. **Extract the bottom of the stack:**
   - extract `core` and `dsp`; define `seridian_device.h`;
   - adapt the existing effects and instruments behind it.
3. **Extract device families:**
   - split `instruments`, `effects` and `analysis` into their own libraries;
   - port the PitchPure modules into `vocal`/`effects`/`analysis`, with
     preallocated scratch buffers and their tests.
4. **Split the engine:** break `src/audio/engine.zig` into `graph`,
   `sequencer` and `io`; replace `TRACK_COUNT` with dynamic tracks.
5. **Split the UI:**
   - split `raven_app.c` into `ui-kit` and `ui-studio`;
   - add the device dock (instruments back in the UI).
6. **New libraries:** add `automation`, `plughost`, `dj`/`ui-dj` and `mcp` as
   new libraries, each test-first.

## Audio safety boundary

The audio callback lives in the engine and never calls UI code. The UI talks
to the engine only through lock-free queues and atomically published
snapshots, and polls meters and position for display.

## Frontend

**Raven to Zig (in progress, `feat/raven-zig`):**
- Raven's ~75k lines of C11 are being translated to Zig under
  `vendor/raven/zig/`, one module at a time.
- Each translated file exports the same C ABI symbols as the C file it
  replaces, so C and Zig coexist.
- Raven's own C test suite and a layout test check each module before it is
  swapped in.
- Once all modules are Zig, cross-module calls move to native `@import`. The
  C tests are translated last.

Raven (vendored at `vendor/raven`, upstream commit
`c4410662723bf0eec633a36a7c2e4d69490325cf`) owns the window, widget tree and
event loop. It is built with CMake/Ninja and linked statically into
`ui-*`. The former GTK4 UI in `src/ui/*_gtk.c` is reference only and is not
built.
