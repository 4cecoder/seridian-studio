# Handoff (2026-11-13)

Current state of Seridian Studio. Read this, then `AGENTS.md`, `docs/design/architecture.md`,
`docs/design/live-performance.md` and `docs/design/feature-parity.md`.

## Where things are

- `master` (local; push needs the owner's go-ahead) holds all Zig DAW work, consolidated on branch
  `feature/v01-daw` in the `daw-consolidate` worktree. Every other branch is merged or superseded:
  - this repo: `consolidate/ui-harness` (knob/UI-state work is in master; the knob is now Zig),
    `wip/raven-core-opencode` and `stash/opencode-wip-*` (Raven core is fully ported),
    `snapshot/ui-harness-knobs-20261030` (raw working-tree snapshot);
  - the second clone `~/media/audio/daw` (`feat/overhaul`, `feat/shell`, `feat/icons`, `feat/preflight`,
    `feat/verify-harness`, `fix/linux-audio`, Oct 18, GTK era): the engine and system work was ported (PipeWire
    playback, `DAW_AUDIO_BACKEND`, preflight). What was left is GTK-only (shell, GResource icons, `daw verify`),
    which the Raven UI and the `seridian` CLI harness replace;
  - `~/media/audio/daw/.worktrees/001-fix-midi-playback-always-starting-at-zero` (Jan 2026, never built):
    thread-locking for the old PipeWire skeleton, replaced by `src/audio/pw_stream.zig`.
- Toolchain: Zig `0.18.0-dev.738+ae9a8acc7`, pinned in `build.zig.zon`, CI and `run.sh`. There is no final
  0.18.0 release yet (latest stable 0.17.1). The `zig` on PATH on the dev machine is an older dev build that
  cannot build `libs/mcp`; use `~/.local/share/zig/dev738/.../zig` or `run.sh`. Build with `-j4` (the machine
  overheats).
- Verified 2026-11-13: `zig build`, `zig build test` (80/80 steps), `zig build fmt`, ReleaseSafe GUI and
  headless builds, `test-vocal` in ReleaseFast (204 pass, 5 skipped = Rust `#[ignore]` benchmarks), and a
  headless run on PipeWire: CLI `song` + `export` renders 176 s, peak 0.891; `seridian doctor` exit 0.
  Re-verified after the M0, Vocal Strip and PipeWire-in-Zig work: `zig build`, `zig build test` (80/80),
  `zig build fmt`, headless build, `test-vocal` ReleaseFast (204 pass, 5 skipped); headless on PipeWire node
  `seridian-studio` runs F32LE 2 ch 48 kHz (quantum 128 with default settings, 0 errors in `pw-top`).

## Done

- SoundCraft libraries: all nine reviewed. Raven: 99 configured C files build from their Zig translations.
- Raven, the rest of its C: `Rset_window_class` (X11 WM_CLASS); `ravenc` is Zig (byte-identical to the C, test
  `ravenc_matches_c`); Raven Web (`web/src`, test_web) is Zig (`check.sh --web`); the private-header layout checks
  were dropped (no C compiles them), public + system-type layout checks stay; the designer (all 11 files)
  is Zig too (`zig/designer_ported.txt`, `check.sh --tools`: its 6 tests pass). C originals: `vendor/raven/deprecated-c/`.
- Per-track live input, ALSA sequencer MIDI input (lock-free note ring), autosave and crash recovery.
- **Native PipeWire playback** (`src/audio/pw_stream.zig` + `pipewire.zig` BlockAdapter), ported from
  `feat/overhaul` 794049f. Node `seridian-studio`, F32 stereo, `node.latency` = buffer. `DAW_AUDIO_BACKEND`
  (auto/pipewire/pulse/none) overrides the config and the saved backend. The stream is Zig over
  hand-written libpipewire declarations; the SPA EnumFormat POD is built by `src/audio/spa_pod.zig`
  (verified byte-for-byte against `spa_format_audio_raw_build` before `pw_stream.c` was deleted). The
  engine compiles no C.
- **`seridian doctor`** now includes the realtime-audio preflight (session, audio server, PipeWire quantum,
  rtprio, memlock, kernel preemption, governor, MIDI, desktop entry, Hyprland rules, file dialogs) and
  `--fix hyprland-rules|desktop-entry|pipewire-clock` (writes under $HOME only). Engine C API
  `daw_preflight_*` exported; the window shows it (header indicator "System OK" / "N problems" and a System check
  dialog with hints and one-click fixes, `src/ui/zig/app/preflight_panel.zig`), run on a worker thread.
- **PitchPure absorbed** as `libs/vocal` (L2, no dependencies): the whole `pitchpure_engine` and
  `pitchpure_suite` crates with every Rust test, including the 10-test QA suite. `pitchpure_core` (unused
  placeholders), the CLI, the GUI and the plugin shells were not ported.
- **Vocal track effects** (`src/effects/vocal.zig`), appended after Pro EQ so saved indices are unchanged:
  De-esser, Vocal Rider, Denoise, Tape, Vocal Tune (corrector + formant), Vocal Strip (the full chain).
  They are rebuilt when the engine sample rate changes.
- **Plugin delay compensation** (`src/audio/pdc.zig`): effects report latency; every track is delayed to the
  slowest chain, and WAV export skips the latency.
- Fixed: launch segfault (UI called `audio_engine_midi_input_name` with the wrong signature); CI now installs
  `libasound2-dev` (the build links ALSA) and runs vocal QA optimized.
- Window class: the app calls `Rset_window_class("seridian-studio", "seridian-studio")` before its first window,
  matching the doctor's Hyprland rules and `StartupWMClass`. Users who ran `seridian doctor --fix
  hyprland-rules|desktop-entry` before must run them again. Done: preflight in the UI (System check) and
  idle/suspend inhibit while playing/recording (`src/ui/zig/idle_inhibit*.zig`).
- UI theme: the cyan cyberpunk palette (`src/ui/zig/palette.zig`, accent #00F0FF on violet) is what the app uses.
- **The UI is Zig**: `src/ui/raven_app.c` and its C helpers were translated 1:1 to `src/ui/zig/app/` and
  `src/ui/zig/*.zig` (see `docs/development/ZIG_FOCUS.md`); libdaw-ui compiles no C. The UI C tests are Zig tests
  in `tests/ui/` (`zig build test-ui`).
- **Live-performance M0 (engine side)**, each with a test that failed first:
  - one event path into the audio thread: UI/CLI/MIDI-backend notes go through a lock-free MPSC queue
    (`src/audio/event_queue.zig`); only the audio thread touches voices;
  - MIDI clips publish immutable snapshots (atomic pointer + per-reader hazard slots); the audio thread
    never locks and never misses a note while the UI edits;
  - sample-accurate clip notes: instruments render in sub-blocks split at each note on/off frame;
    identical output at any block size;
  - gain, master and pan ramp per sample over 10 ms (no zipper noise), continuing from automation;
  - default buffer 128 frames everywhere (engine, config, saved settings, detection, preflight);
  - effect automation (reverb wet) on a timeline-anchored 32-sample grid, block-size independent;
  - allocation check: `process()` with every feature active makes zero allocator calls.
- **Vocal Strip block-size parity**: the strip re-blocks into fixed 1024-frame chain calls (+1024 frames
  latency, reported for PDC); output is bit-identical at any host block size.

## Next

1. Live-performance M0 leftovers: health counters in the status bar (UI; `getAudioHealthStats` is there),
   lock tracing in tests (allocation is checked), the spec's smoothing check (HF energy below -90 dBFS on
   a gain step), hardware-MIDI timestamps (M1), mute ramps, and `process()` blocks larger than 2048 frames
   (backends never deliver them today). Export (`renderOffline`) still shares voices and ramps with the
   audio thread if run while playing; the app's export command refuses that, `audio_export_wav` does not.
2. A saved `audio.conf` keeps its buffer size (the owner's says 512); 128 applies to fresh setups.
3. Raven leftovers: a Windows designer build (C variadic functions in `os/build/main.zig` do not compile for
   x86_64-windows on this Zig); no C-oracle layout check for the hand-written X11 structs in
   `x11_platform.zig`; the browser half of `test_web` needs a Chromium on the test machine.


## Goals

Seridian Studio should beat Pro Tools, FL Studio, Bitwig, Reaper, Logic and Ableton by winning wedges, not by parity
everywhere: rock-solid live performance (low latency, sample-accurate, zero xruns), studio recording and production,
and DJ workflows, in one product built from small libraries ("Lego" layers, see `docs/design/architecture.md`).
TDD and measured optimisation come first: a change is done when it has a test that failed before it.

Done criteria for this handoff, in order:
1. SoundCraft libraries: all nine reviewed and committed (section 1).
2. Raven: every C file translated, every module integrated in `ported.txt`, Raven's C tests and the app launch pass
   (section 2).
3. Live-performance M0 bugs fixed test-first (section 3).

## Work loop

Take one unit at a time (one library to review, one C file to translate, one bug to fix). For each unit:
1. Read the relevant spec section and the source being translated or fixed.
2. Write or port the tests first; run them and see them fail (or, for translations, see them compile against C).
3. Implement. Never weaken or delete a test to make it pass.
4. `zig build -j4`, `zig build test -j4`, `zig build fmt`; for Raven also `vendor/raven/zig/check.sh`.
5. Commit that unit alone with a message naming it. Update the status lines in this file when a section's state changes.
6. If a unit is stuck after a few honest attempts, note it under "Blocked" below with the error, and move on.

Keep builds at `-j4` and run one heavy build at a time; the machine overheats.

## Open issue from the owner (2026-10-30)

- The UI on master still has the lime-green theme; the owner's latest UI is a **cyan cyberpunk** look that is not
  in this repo yet. Find where it lives (another branch, worktree, machine or session) before more UI work.

## Blocked

Nothing open.

## Leave alone

- Push only with the owner's go-ahead.
