# Seridian Studio: Feature Parity Spec

Status: draft, 2026-10-29. Owner: [seridian.dev](https://seridian.dev).

Seridian serves three audiences on one engine: **studio** (recording and
producing), **live performance**, and **DJs**. Companion specs:
[Architecture](architecture.md) (libraries, device interface, TDD and
performance gates) and [Live Performance](live-performance.md) (latency,
automation, live control).

Goal: reach working parity with Pro Tools, FL Studio, Bitwig Studio, Reaper,
Logic Pro and Ableton Live on the features producers use every session, then
win on the things only Seridian's architecture makes cheap (see
[Differentiators](#differentiators)).

Parity does not mean copying all six. Each row below names the competitors that
set the bar, what Seridian has today (verified against the code at `53cdd50`),
the priority, and the milestone that delivers it.

Competitor cells reflect public feature sets as of mid-2026. Re-verify any cell
before quoting it externally.

## Legend

| Mark | Meaning |
| --- | --- |
| ✓ | Shipped and usable |
| ◐ | Partial: engine/DSP exists but not wired, UI-only, or limited |
| — | Absent |
| **P0** | Blocks making a complete song; no one switches without it |
| **P1** | Expected by working producers; absence is a reason to leave |
| **P2** | Competitive advantage or niche; schedule after P0/P1 |

Competitor columns: **PT** Pro Tools, **FL** FL Studio, **BW** Bitwig,
**RP** Reaper, **LG** Logic Pro, **AB** Ableton Live.

## Baseline today

- **Architecture:** `libdaw-engine` (Zig, C ABI only), `libdaw-ui` (Raven, C),
  `seridian-studio` launcher. About 136 exported C functions.
- **Engine:** 4 instruments (Keys, Wavetable, SuperSaw, FM), 24 effects,
  22 DSP modules (including granular, phase vocoder, physical and modal
  synthesis), audio and MIDI clips, recording, undo, WAV export,
  CoreAudio/CoreMIDI, PipeWire/PulseAudio, WASAPI.
- **Hard limits:** `TRACK_COUNT = 4`, `MAX_EFFECTS = 8`, `MAX_CLIPS = 64`
  (`src/project/project.zig`), 16 voices per instrument.
- **Raven UI (`src/ui/raven_app.c`, 716 lines):** transport, tempo, timeline
  with clip move/resize/delete, per-track gain/mute/solo with meters, master
  gain, project new/open/save. No instruments, piano roll, recording, effects,
  or loop controls yet.

## Parity matrix

### 1. Core engine

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Unlimited (dynamic) tracks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — fixed at 4 | P0 | M1 |
| Buses / group tracks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Sends / returns | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Sidechain routing | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Plugin delay compensation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — no effect reports latency | P1 | M2 |
| Multicore audio graph | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — single thread | P1 | M2 |
| Unlimited effects per track | ✓ | ◐ 10 slots | ✓ | ✓ | ◐ 15 slots | ✓ | ◐ 8 slots | P1 | M1 |
| 44.1–192 kHz, resample on load | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ resample on load | P1 | M1 |
| Tempo and time-signature map | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — single tempo | P1 | M3 |

### 2. Recording

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Audio recording | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ engine API, no Raven UI | P0 | M1 |
| Multitrack simultaneous record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — mono input path | P1 | M2 |
| MIDI recording | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ engine, no Raven UI | P0 | M1 |
| Input monitoring | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Metronome / count-in | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Loop / cycle recording | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M1 |
| Punch in/out | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M3 |
| Take lanes + comping | ✓ | ◐ | ✓ | ✓ | ✓ | ✓ | — | P1 | M3 |

### 3. Editing

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Clip move, trim, split | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ engine; ◐ Raven (move/resize) | P0 | M1 |
| Fades and crossfades | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ fades in API, no UI, no crossfade | P0 | M1 |
| Clip gain | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ API, no UI | P1 | M1 |
| Piano roll | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ MIDI clips; editor was GTK only | P0 | M1 |
| Step sequencer | — | ✓ | ◐ | ◐ | ✓ | ◐ | — | P0 | M1 |
| Scale / key awareness | ◐ | ✓ | ✓ | ◐ | ✓ | ✓ | ◐ `scale_c_api` | P1 | M1 |
| MIDI quantize / humanize | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ grid snap only | P1 | M1 |
| Chord / arp tools | — | ✓ | ✓ | ◐ | ✓ | ✓ | — | P2 | M3 |
| MPE | ◐ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P2 | M4 |
| Audio warp / time-stretch | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ phase vocoder DSP, not on clips | P1 | M3 |
| Pitch correction | ✓ | ✓ | — | ◐ | ✓ | — | ◐ unused `dsp/pitch.zig`; port PitchPure | P1 | M2 |
| Vocal tools (de-ess, denoise, rider) | ✓ | ◐ | ◐ | ◐ | ✓ | ◐ | — port PitchPure | P1 | M2 |
| Key detection | — | — | — | — | ◐ | ◐ | — port PitchPure | P2 | M2 |
| Undo history | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ undo v1/v2 | P0 | M1 |

### 4. Arrangement and performance

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Linear arrangement | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ timeline | P0 | M0 |
| Loop region | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Markers / sections | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Pattern-based workflow | — | ✓ | ◐ | — | ◐ | ◐ | — | P1 | M2 |
| Clip launcher (session view) | — | ◐ | ✓ | — | ✓ | ✓ | — | P1 | M3 |
| Ableton Link | — | ✓ | ✓ | ◐ | ✓ | ✓ | — | P2 | M3 |
| MIDI controller mapping / learn | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Control surfaces (MCU/HUI) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P2 | M4 |

### 5. Mixing

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mixer view (faders, pan, meters) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ gain/mute/solo/meter, no pan in UI | P0 | M1 |
| Automation lanes (draw, record) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M2 |
| Automation modes (latch/touch/write) | ✓ | ◐ | ✓ | ✓ | ✓ | ◐ | — | P1 | M2 |
| Modulators (LFO, envelope → any param) | — | ◐ | ✓ | ✓ | ◐ | ✓ | — | P1 | M3 |
| VCA faders | ✓ | — | ◐ | ✓ | ✓ | — | — | P2 | M4 |
| Loudness metering (LUFS) | ✓ | ◐ | ✓ | ✓ | ✓ | ◐ | — | P1 | M2 |
| Spectrum analyzer | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ `spectral.zig` | P2 | M2 |

### 6. Instruments and effects

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Instruments selectable per track | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ | ◐ 4 synths in API, no Raven UI | P0 | M1 |
| Instrument parameter UI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ param API (name/min/max/unit) | P0 | M1 |
| Sampler (multi-zone) | ◐ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Drum machine / drum rack | ◐ | ✓ | ✓ | ◐ | ✓ | ✓ | — | P0 | M1 |
| Instrument presets | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M1 |
| Core effects (EQ, comp, reverb, delay, sat) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ 24 effects; ◐ no Raven UI | P0 | M1 |
| Modulation FX (chorus, flanger, phaser, tremolo, ring mod) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Multiband compressor | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Effect presets | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M1 |
| Modular sound design | — | ◐ | ✓ | ◐ | — | ◐ | ◐ DSP blocks, not user-facing | P2 | M4 |
| Bundled sample/loop library | ◐ | ✓ | ✓ | — | ✓ | ✓ | — | P1 | M3 |
| Browser with preview | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |

### 7. Plugins

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CLAP hosting | — | ✓ | ✓ | ✓ | — | — | — | P0 | M2 |
| VST3 hosting | — | ✓ | ✓ | ✓ | — | ✓ | — | P1 | M3 |
| AU hosting (macOS) | — | ✓ | — | ✓ | ✓ | ✓ | — | P1 | M3 |
| AAX | ✓ | — | — | — | — | — | — | out | — |
| Plugin sandboxing (crash isolation) | — | ◐ | ✓ | ✓ | ◐ | — | — | P1 | M3 |

### 8. Project, export and platform

| Feature | PT | FL | BW | RP | LG | AB | Seridian | Pri | MS |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Save / open project | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | P0 | M0 |
| Autosave + crash recovery | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P0 | M1 |
| Templates | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Export WAV | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ 16/24-bit; ◐ no Raven UI | P0 | M1 |
| Export FLAC / MP3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Stem export | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| Standard MIDI File export | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | P1 | M2 |
| macOS / Windows | ✓ | ✓ | ✓ | ✓ | ◐ mac only | ✓ | ◐ macOS; WASAPI unverified | P0 | M1 |
| Linux | — | — | ✓ | ✓ | — | — | ◐ builds; Raven via X11 | P1 | M2 |
| Scripting API | ◐ | ✓ | ✓ | ✓ | ◐ | ✓ | ◐ C ABI only | P1 | M4 |
| Video track | ✓ | ◐ | — | ✓ | ✓ | ◐ | — | P2 | M5 |
| Surround / Dolby Atmos | ✓ | — | — | ◐ | ✓ | — | — | P2 | M5 |
| Notation | ✓ | — | — | ◐ | ✓ | — | — | out | — |

## Milestones

Each milestone ends with a build that a producer can use end to end, and with
`daw verify` covering everything it adds.

### M0: Stable foundation (now)

- Split-binary build green on macOS and Linux CI. Done locally at `53cdd50`.
- Merge the engine side of `feat/overhaul`: preflight checks, `daw doctor`,
  the `daw verify` harness, and the PipeWire playback fix. Port the harness to
  drive Raven instead of GTK.
- Fix the four live-performance bugs, test-first: CoreMIDI dangling pointer,
  MIDI-thread race, spin lock on the audio thread, block-quantised notes
  ([Live Performance](live-performance.md)).
- Library split prerequisites: layer check, counting allocator, bench harness
  ([Architecture](architecture.md#migration-plan)).
- Exit criteria: `zig build test`, `daw verify`, and a headless launch all pass
  in CI on both platforms.

### M1: Make a complete song

All P0 rows marked M1:
- dynamic tracks, buses and sends
- instruments with a parameter UI
- sampler and drum rack
- step sequencer and piano roll
- MIDI and audio recording with monitoring
- metronome and loop region
- fades
- effects UI
- autosave
- WAV export from the UI

Exit criterion: a new user can program drums, write a bassline and chords,
record a vocal, mix with built-in effects and export a WAV without leaving
Seridian.

### M2: Mix and finish

- automation lanes and modes
- vocal suite from PitchPure: pitch correction, denoise, de-esser, rider, key detection
- CLAP hosting
- sidechain and plugin delay compensation
- multicore graph
- loudness metering
- markers, browser with preview, templates
- FLAC/MP3 and stem export
- MIDI learn
- first-class Linux

### M3: Pro workflow

- warping and time-stretch
- take lanes and comping
- clip launcher, tempo map
- modulators
- VST3 and AU hosting with sandboxing
- content library
- Ableton Link
- chord and arp tools

### M4: Differentiators at full strength

- agent control (MCP)
- scripting
- MPE
- modular sound design
- control surfaces
- Melodyne-style pitch editing
- VCA faders

### M5: Later

Video, surround/Atmos. Notation and AAX are out of scope.

## M1 feature specs

### Dynamic tracks

- Replace `TRACK_COUNT` arrays in `project.zig`, `engine.zig` and
  `midi_clip.zig` with a track list owned by the engine. Tracks are added and
  removed on the UI thread. The audio thread sees an immutable snapshot swapped
  atomically: no locks or allocation on the audio thread.
- Track kinds: audio, instrument, bus, master.
- C API: `audio_engine_add_track(engine, kind) -> id`,
  `audio_engine_remove_track(engine, id)`, `audio_engine_get_track_ids(...)`.
  The existing index-based calls keep working through an index → id mapping
  until the UI moves over.
- Project format: bump `VERSION` to 2; load v1 projects into 4 tracks.
- Acceptance: create 128 tracks with one instrument each and play without
  xruns at 256 frames on an M-series Mac; v1 projects round-trip.

### Buses and sends

- Every track has an output target (master or a bus) and up to 8 post-fader
  sends with level and pre/post switch.
- The engine sorts the routing graph topologically and rejects cycles at edit
  time.
- Acceptance: a reverb bus fed by two sends; muting the bus silences only the
  reverb; creating a cycle is refused with an error.

### Instruments in Raven

- Track header gets an instrument picker populated from
  `audio_engine_get_instrument_type_count/name`.
- Device panel at the bottom of the window: one knob or slider per parameter,
  built from `audio_engine_get_track_instrument_param_*` (name, min, max,
  unit). Double-click resets to the default value.
- On-screen keyboard plus computer-keyboard play (A–K row, Z/X octave), routed
  to `audio_engine_note_on/off` on the selected track.
- Hardware MIDI already routes to the first armed track (`runtime.zig`). Add an
  arm button per track.
- Presets: save and load parameter sets as small INI files per instrument type.
- Acceptance: pick each of the 4 instruments, play from the computer keyboard
  and a MIDI controller, change a parameter while holding a note and hear it.

### Sampler and drum rack

- **Sampler:** load WAV/AIFF, root note, key and velocity zones, ADSR,
  one-shot or sustain loop, filter. Reuses `resample.zig` and `envelope.zig`.
- **Drum rack:** 16 pads, each a one-shot sampler with choke groups, per-pad
  gain, pan and send. MIDI notes 36–51 map to the pads.
- Both register as new `InstrumentType` values so the generic parameter UI
  works unchanged.
- Acceptance: drag a sample onto a pad and hear it from the step sequencer.

### Step sequencer

- A per-track pattern of 16/32/64 steps with velocity, probability and
  per-step note.
- Patterns compile to MIDI clips, so playback, export and undo reuse the MIDI
  clip path.
- Acceptance: program a 4/4 beat in under 30 seconds with mouse only; swing
  0–75% audibly shifts off-beats.

### Piano roll

- Raven port of the GTK piano roll:
  - draw, select, move, resize and delete notes
  - velocity lane
  - snap to grid
  - scale highlighting from `scale_c_api`
  - quantize
- Acceptance: edit an 8-bar MIDI clip; every edit is undoable.

### Recording and monitoring

- Arm, monitor (off/auto/on) and input select per track.
- Record button records into armed tracks at the playhead. Count-in of 0–2
  bars.
- Metronome as an engine-generated click on its own output, with level
  control.
- Acceptance: record 60 s of audio and MIDI simultaneously; the recorded audio
  lines up with the click within 1 ms after latency compensation.

### Loop region, fades, effects UI, autosave, export

- **Loop region:** drag in the timeline ruler; transport loop toggle; looped
  playback is sample-accurate.
- **Fades:** handles at clip corners driving `track_set_clip_fade_in/out`;
  overlapping clips crossfade automatically.
- **Effects UI:** per-track chain view using `effects_c_api`. Same generic
  parameter panel as instruments.
- **Autosave:** every 2 minutes and on quit to a sidecar file; offer recovery
  on next launch after a crash.
- **Export:** dialog for range (song or loop), format and bit depth, calling
  `export.zig`.

## DJ parity

Bar set by rekordbox, Serato DJ Pro, Traktor Pro, VirtualDJ and Engine DJ.
Rows marked "standard" are in all of them. DJ features live in the `dj`,
`analysis` and `ui-dj` libraries ([Architecture](architecture.md)), on the
same engine as the studio.

| Feature | Bar | Seridian | Pri | MS |
| --- | --- | --- | --- | --- |
| 2–4 decks with waveform overview and zoomed waveform | standard | — | P0 | M3 |
| Track analysis: BPM, beatgrid, key, waveform cache | standard | ◐ onset, chroma, peaks; key detection via PitchPure | P0 | M3 |
| Sync and beatmatch; tempo fader with ±8/16/50% ranges | standard | — | P0 | M3 |
| Key lock (tempo change without pitch change) | standard | ◐ phase vocoder and SOLA DSP | P0 | M3 |
| Hot cues, memory cues, auto/manual loops, beat jump, quantize | standard | — | P0 | M3 |
| Mixer: channel faders, 3-band kill EQ, filter, crossfader with curves | standard | ◐ EQ and filter DSP | P0 | M3 |
| Headphone cue (pre-listen) on a second output pair | standard | — needs multichannel output in `io` | P0 | M3 |
| Beat-synced FX | standard | ◐ effects exist, no tempo sync | P1 | M3 |
| Library: crates, playlists, smart crates, history, search | standard | — | P0 | M3 |
| Import from rekordbox XML, Serato crates, Traktor NML | standard (cross-import varies) | — | P1 | M4 |
| MIDI and HID controller support with mapping presets | standard | ◐ MIDI input; no HID | P0 | M3 |
| Record the mix | standard | ◐ recording exists | P1 | M3 |
| Sampler / performance pads | standard | ◐ sampler planned in M1 | P1 | M3 |
| Harmonic mixing (key compatibility shown) | standard | — | P1 | M3 |
| Real-time stem separation | rekordbox, Serato, Traktor, VirtualDJ | — requires an ML model; conflicts with zero-dependency policy, needs a decision | P2 | M5 |
| DVS (timecode vinyl) | Serato, Traktor, rekordbox, VirtualDJ | — | P2 | M5 |
| Streaming service integration | standard | — licensing and business deals, not engineering | out | — |
| Ableton Link | most | — | P1 | M3 |

### Where Seridian beats DJ apps

The DJ apps and the DAWs are separate products. Seridian is one engine, so it
can do what neither side can:

- **Set → arrangement:**
  - A recorded DJ set opens in the studio as an editable arrangement: each
    deck becomes a track, and every fader, EQ and FX move becomes automation.
  - Fix a transition after the fact instead of re-recording the set.
- **Arrangement → deck:**
  - Load a project's stems, or a live DAW session, onto a deck and mix it
    with full control of the parts.
  - Producers DJ their own unreleased tracks without bouncing them.
- **Studio-grade devices on decks:** the vocal tools, instruments and effects
  are all Device-interface bricks, so any of them can sit on a deck or the
  master.
- **Same latency and automation core** as live performance
  ([Live Performance](live-performance.md)): sample-accurate, smoothed, no
  zipper noise.

## Engineering priority

TDD and performance work run alongside every milestone. They are not a
cleanup phase afterwards. Each feature above ships with:
- tests written first;
- an RT-safety check;
- a golden render;
- a benchmark with a budget.

The gates are defined in [Architecture](architecture.md#engineering-process).

## Differentiators

Parity gets Seridian considered. These are why people stay:

1. **Agent-native.** An MCP server over the engine C ABI so Claude and other
   agents can create tracks, write MIDI, mix and export. Competitors rely on
   reverse-engineered remote scripts; Seridian designs for it.
2. **Fast and light.** Millisecond startup, small binaries, no runtime
   dependencies beyond the OS audio stack.
3. **Linux-native pro DAW.** Only Bitwig and Reaper compete there.
4. **Crash-proof sessions.** Autosave plus sandboxed plugins (M3) aimed at
   Reaper/Bitwig-grade stability.
5. **Deep built-in DSP.** Granular, phase vocoder, physical and modal synthesis
   already exist in `src/dsp`; exposing them as instruments is cheap compared
   with competitors licensing them.

## Ideas from daw-swift

The Swift port at `../daw-swift` (last commit 2026-09-05) was surveyed in full.
Its own docs (`Docs/FEATURES.md`, `Docs/MIGRATION_FROM_ZIG.md`) overstate what
is real. Several features are UI-only, and on instruments the Zig engine is
already ahead.

### Port these

Ranked by value; "real" means working DSP or logic behind it.

| # | Feature | Swift source | Real? | Lands in |
| --- | --- | --- | --- | --- |
| 1 | Sampler: classic, one-shot and sliced (16 slices → notes 36–51) | `DAWEngine/QuickSamplerSynth.swift` | ✓ DSP; never wired to UI | M1 Sampler. Slice with Zig `dsp/onset.zig`, not Swift's energy detector |
| 2 | Step sequencer: swing 0–75%, per-step velocity, ratchets ×1–4, lane mute/solo, stamp to MIDI clip | `DAWFoundation/StepSequencer.swift` | ✓ | M1 Step sequencer; also add live step playback, which Swift lacks |
| 3 | Drum synth on the GM map (kick, snare, clap, hats, toms) | `DAWEngine/DrumMachineSynth.swift`, `ModulationDSP.swift` | ✓ | M1 Drum rack, as the built-in default kit; reuse `dsp/modal.zig` and `dsp/physical.zig` |
| 4 | Loop with sample-accurate wrap; metronome (2 kHz accent / 1 kHz, 30 ms) | `DAWEngine/AudioEngine.swift` | ✓ | M1 Loop region, Recording |
| 5 | Aux send/return buses | `AudioEngine.swift` | ✓ (2 fixed) | M1 Buses and sends, generalised |
| 6 | Piano roll tools: chord stamp (10 types), humanize, transpose, duplicate, triplet quantize, velocity lane, key audition | `DAWUI/PianoRollView.swift`, `DAWFoundation/MusicTheory.swift` | ✓ | M1 Piano roll. Make scale snapping real; Swift only dims keys |
| 7 | Chorus, flanger, phaser, tremolo, ring mod, 3-band multiband compressor | `DAWFoundation/ModulationEffects.swift` | ✓ | M2 Modulation FX |
| 8 | Standard MIDI File export (type 0/1), stem export | `DAWEngine/Export.swift`, `DAWFoundation/MIDIFile.swift` | ✓ | M2 Export |
| 9 | Effect rack with auto-generated parameter sliders, bypass, reorder, JSON presets | `DAWSession/PresetStore.swift` | ✓ | M1 Effects UI and presets |
| 10 | 8-band spectrum (Goertzel) | `AudioEngine.swift` | ✓ | M2 Spectrum analyzer |

### UX patterns to adopt in Raven

- **Layout:** transport bar → track list + arrangement → resizable bottom dock
  with tabs (Mixer, Piano Roll, FX, Library, Step Seq) → status bar.
  - Dock drag handle; double-click toggles between two heights.
- **Status bar:**
  - context hints: "Space to play — click the piano grid to add notes", "● Recording — Space stops";
  - unsaved dot, BPM, loop bars, undo count;
  - engine clip/NaN counters, from the existing `getAudioHealthStats`.
- **Audible by default:** a new project boots with a demo arpeggio on track 1,
  so Play makes sound immediately. Pair it with a one-time "three steps to
  your first sound" welcome.
- **Plain-language tooltips** on every control. Swift has 83.
- **Shortcuts:**
  - Space play/stop, ⌘Z/⇧⌘Z, ⌘S/⇧⌘S/⌘O, ⇧⌘E export;
  - ⌘D dock, ⌘1–⌘5 dock tabs, ⇧⌘/ shortcuts sheet.
  - Fix Swift's collisions: duplicate and dock toggle both used ⌘D, and some
    advertised keys were never bound.
- **Arrangement:** follow-playhead, a loop brace on the ruler with an 8% wash
  over the lanes, clip edge-trim with 8 pt hit zones.
- **Theme:** Swift used Tokyo Night (`Sources/DAWUI/Theme.swift`):
  - bg `#1a1b26`, panel `#24283b`, text `#c0caf5`, accent `#7aa2f7`,
    violet `#bb9af7`, green `#9ece6a`, red `#f7768e`.
  - Raven currently uses a lime-accent dark theme (`raven_app.c`). Choosing
    one is a brand decision, not a parity item.

### Do not port

- FM, Supersaw and Wavetable synths: Zig's versions are stronger (more
  algorithms, voices, LFOs and filters).
- Moog ladder: Zig's `analog_filter.zig` is stronger.
- Warp/SOLA: plain resampling, so pitch drifts.
- Automation model: never wired to the engine or UI.
- Session matrix: no quantized launch.
- Fixed `trackCount = 4`: Swift's FX rack maps track 5 to the Master rack.

### Testing ideas

- Swift tests audio through a `.manual` offline backend: render N frames,
  assert peak > 0.001, ≤ 1 and no NaN. Zig already has `null_backend.zig`.
  The `daw verify` harness should add render-and-assert tests for every
  instrument and effect the same way.

## Absorbing PitchPure

`../pitchpure` is Seridian's Rust pitch-correction and vocal suite (v1.0.0,
2026-10-13). Its DSP crates have zero dependencies; its GUI does not. Every
engine module shares one shape: `new(sample_rate)`, f32 setters,
`process(in, out)`, `reset`, `latency_samples`. There is no global state,
I/O or threading.

### Integration: port to Zig, not FFI

Linking it as a Rust staticlib would bring several costs:
- a cargo toolchain inside `zig build`, losing Zig cross-compilation;
- `assert!` panics crossing the C ABI;
- a shape adapter, because PitchPure is mono with reported latency while
  Seridian effects are in-place interleaved stereo.

A port is roughly 1:1 in lines, and it is the right moment to fix PitchPure's
one serious defect: **the corrector allocates on the audio thread**. Its
detectors and tracker make about 6–7 allocations every 512 samples. The AU and
VST3 shells call it on the host thread, so this also affects the shipping
plugins. Port each module with preallocated scratch buffers and port its tests
alongside.

### What to absorb, ranked

| # | Module | PitchPure source (`crates/pitchpure_engine/src/`) | vs. Seridian today | MS |
| --- | --- | --- | --- | --- |
| 1 | Pitch correction: YIN/MPM/ACF fusion tracker, scale quantizer, retune speed/humanize, SOLA shifter (~26 ms) | `detector_*`, `quantizer`, `slew`, `vibrato`, `retune`, `shifter_sola`, `corrector` | New effect. Better than `dsp/pitch.zig`'s unused `PitchCorrector`. SOLA also replaces `effects/pitch_shifter.zig`, which ignores the sample rate and mixes stereo into mono | M2 |
| 2 | Spectral denoise with noise learning | `denoise` | New | M2 |
| 3 | De-esser with listen mode | `deesser` | New | M2 |
| 4 | Vocal rider (auto-gain) | `rider` | New | M2 |
| 5 | Smart voice EQ (adaptive 5-band); per-band dynamics | `voice_eq`, `parametric_eq` | New. Fold dynamic bands into `pro_eq.zig`; don't add a third EQ. `parametric_eq` has no tests, so write them first | M2 |
| 6 | Formant ("throat") shift | `formant` | New. Fix a likely bug first: 1024-sample latency not reported to the chain's dry path | M3 |
| 7 | Key detection (Krumhansl profiles) | `keydetect` | New. Unwired in PitchPure. Ship as "Analyse clip → suggest key/scale", feeding `scale_c_api` | M2 |
| 8 | Tape saturation (2× oversampled, wow/flutter) | `tape` | Better than `saturator.zig` | M3 |
| 9 | Tempo-synced ducking delay (2.5 s) | `delay` | Better than `delay.zig` (~500 ms cap) | M2 |
| 10 | True-peak lookahead limiter | `limiter` | Modest gain over `limiter.zig` | M2 |
| 11 | Modulated FDN vocal reverb with ducking | `reverb` | Overlaps four existing reverbs; optional | M3 |

Skip the compressor (comparable to Seridian's), the PV shifter (Seridian has
`dsp/phase_vocoder.zig`), and the unused `router`, `chain`, `resampler`,
`simd` and `pitchpure_core`.

### Engine prerequisite: effect latency

No Seridian effect reports latency today. The corrector (~26 ms), formant
(1024 samples) and limiter (~71 samples) need plugin delay compensation (§1).
That moves PDC into M2 alongside the vocal tools, and later CLAP hosting
needs it anyway. Add `latency_samples` to the Effect interface and an
`effects_c_api` getter.

### Vocal workflow in the DAW

- **Vocal Chain preset:**
  - order: Tune → Formant → EQ → De-ess → Rider → Compressor → Tape → Delay →
    Reverb → Limiter, built from the ported effects;
  - stages stay in the signal path when bypassed, so toggling never shifts timing.
- **Tune panel in the Raven device dock:**
  - scrolling input-vs-corrected pitch graph;
  - ±100-cent correction needle;
  - one-octave keyboard to toggle allowed notes;
  - retune chips Fast 5 / Natural 40 / Slow 200 ms;
  - scale-aware harmony.
- **Takes:** keep the raw mic alongside the processed take, sample-aligned, so
  correction can be redone after recording. This extends M3 take lanes.
- **Direct-manipulation editors:**
  - compressor transfer curve, de-ess band handle;
  - delay echoes on the beat grid, pre-EQ spectrum;
  - "learn noise" and "listen" buttons.
- **New ground beyond PitchPure:** Melodyne-style note editing on the pitch
  graph (M4). PitchPure's graph is display-only.

### Testing to reuse

- **Port PitchPure's chain QA gate into `daw verify`**
  (`crates/pitchpure_suite/src/qa_tests.rs`):
  - ±8-cent pitch accuracy on synthetic voices;
  - NaN, inf and denormal safety;
  - measured latency equals reported latency (cross-correlation);
  - bypass is bit-exact;
  - offline renders are bit-identical;
  - realtime budget measured in thread CPU time.
- **Add the check PitchPure lacked:** a counting allocator that fails any test
  that allocates inside `process()`.
- **Later, for CLAP hosting (M2):** its `dlopen` plugin harness
  (`crates/pitchpure_harness/`) and async-signal-safe crash reporter
  (`crates/pitchpure_crash/`, logs to `~/Library/Logs/Seridian/`).

## Translating SoundCraft

[SoundCraft](https://github.com/storytold/soundcraft) is a pure-Rust DAW by
the ArtCraft Team, about 116k lines, under MIT OR Apache-2.0. We translate
selected parts to Zig. Each translated file keeps a header naming its source
path and the original copyright. The MIT notice goes in
`THIRD_PARTY_NOTICES.md` with the first translated file.

**Do not copy:**
- ArtCraft brand assets (`docs/brand/*`, trademark-licensed);
- the Pro Tools menu catalog (`crates/engine/catalog/*`, trademark-sensitive).

Zig 0.18 has no `@cImport`, so CLAP, VST3 and AudioToolbox headers become
hand-written `extern` declarations. For VST3, use Steinberg's MIT-licensed
`vst3_c_api` header, not the Rust `vst3` crate.

### Ranked translation plan

| # | Item | Source (`crates/…`) | Seridian lib | ~Lines | MS |
| --- | --- | --- | --- | --- | --- |
| 1 | CLAP host: scan, instance, sample-offset events, params, state, GUI | `clap-host/src/**` | plughost | 2.6k | M2 |
| 2 | Plugin instance handoff: create/prepare on UI thread, adopt into engine, retire back for freeing | `mix/src/{lib,instances}.rs`, `playback/src/{lib,callback}.rs` | graph, session | 0.7k | M2 |
| 3 | Command registry (~280 commands, journaled and undoable) + JSON control protocol + MCP server with batch | `engine/src/{cmd,lib,inspect}.rs`, `automation/src/**`, `docs/{control-protocol,mcp,cli}.md` | session, mcp | 1.2k core | M2 |
| 4 | PDC topology and its tests, with delay lines preallocated (theirs grow on the audio thread) | `mix/src/{strip,lib}.rs`, `mix/tests/it/*` | graph | 0.8k | M2 |
| 5 | Fixture CLAP/VST3 test plugins + junk-file tests | `clap-host/tests/**`, `vst3-host/tests/**`, `tests/fixture/` | plughost tests | 0.9k | M2 |
| 6 | Failure containment: NaN output silences a plugin, latency cap, panic/stall guard | `mix/src/strip.rs` `contain_failure`, `playback/src/callback.rs` | graph, session | 0.2k | M2 |
| 7 | BS.1770 LUFS + true-peak meters | `dsp/src/meter.rs` | analysis | 0.5k | M2 |
| 8 | VST3 host: module thread, exit ordering, param queues, editors | `vst3-host/src/**` | plughost | 3.3k | M3 |
| 9 | AU host (AUv2) | `au-host/src/**` | plughost | 1.5k | M3 |
| 10 | Routing order with cycle fallback | `mix/src/routing.rs` | graph | 0.4k | M1 |
| 11 | File-access confinement for agent sessions | `engine/src/file_access.rs` | mcp | 0.6k | M2 |
| 12 | SMF read/write + MIDI ops | `midi/src/{smf,ops,sequence}.rs` | sequencer | 1.0k | M2 |
| 13 | FLAC encoder, WAV/BWF/RF64/AIFF I/O + malformed-file suite | `audio-io/src/**` | io | 1.7k | M2 |
| 14 | Automation lane ops (`write_range`, slope-window `thin`, `shift_from`), Trim and TouchLatch modes, mute-gating tests | `model/src/automation.rs`, `mix/src/automation.rs`, `mix/tests/it/strip_mute_automation.rs` | automation | 0.7k | M2 |
| 15 | Timebases (timecode, feet+frames, grid/snap) + tempo/meter map | `time/src/**` | sequencer | 1.5k | M3 |

Next tier:
- peaks overview (compare with `peak_cache.zig`);
- lookahead compressor and maximizer, FDN reverb;
- sampler zones and loops;
- autosave/recovery;
- surround panner;
- the asset-attribution CI gate.

### Where Seridian's design stays ahead

SoundCraft is a source of tested building blocks, not a design to copy. Its
engine breaks some real-time rules:
- rayon `par_iter` called from the audio thread;
- delay lines and send buffers resized in `process`;
- a HashMap rebuilt every block;
- plugin parameters looked up by string.

Its automation is linear, stored in samples, and block-rate for plugins.
Seridian keeps its own design ([Live Performance](live-performance.md)):
- sample-accurate events;
- beats + curves;
- an override mode;
- a multicore scheduler on the OS real-time workgroup;
- counting-allocator tests.

What we adopt from SoundCraft:
- tests that renders are identical at any block size;
- returning snapshots to the UI thread for freeing;
- treating every loaded file and plugin state as hostile input.
