# Swift migration baseline (archived Zig design)

The Zig + GTK4 implementation in this repo is the frozen reference for the
Swift 6 port at `../daw-swift`.

- Baseline commit: `0fb9ad7` — "Add clip trimming feature and fix recording clip colors"
- Branch audit (2026-09-05): `origin/macos` == `master`
  (`git diff master..origin/macos --stat` empty). No unmerged ideas; macOS
  work (CoreAudio backend, CoreMIDI, GSettings/Homebrew paths, Metal
  preference, splash screen, voice pools, DSP utilities) is already in-tree.
- Canonical design docs: `docs/design/architecture.md`, `docs/design/prd.md`,
  `docs/reference/api.md`, `docs/reference/rt-audio-patterns.md`,
  `docs/getting-started.md`, plus `daw.conf`, `src/main.zig`, `src/root.zig`.
- Module inventory (37k lines Zig/C): `src/audio` (engine/track/clip/export/wav/
  recording/backends), `src/dsp` (23 files), `src/effects` (24 types + chain),
  `src/instruments` (fm/supersaw/wavetable), `src/midi`, `src/project`
  (INI + sidecars), `src/core/undo.zig`, `src/config`, `src/system/detect.zig`,
  `src/ui` (GTK4/Cairo), `src/utils/log.zig`.
- Key invariants the Swift port preserves: TRACK_COUNT=4, MAX_EFFECTS=8,
  MAGIC `WADZ` (0x5741445A), VERSION=1, INI sections
  (`[Project]/[MasterEffects]/[TrackN]/[TrackNEffects]/[TrackNClipM]`),
  MIDI binary (16B header + 18B/note), linear mixer pan law, RT rules
  (no alloc/lock/I/O on audio thread, atomics + param queue UI→audio,
  meter polling audio→UI), 9-stage splash order.
- Full port map + deltas: `../daw-swift/Docs/MIGRATION_FROM_ZIG.md`.

Do not extend the Zig app without also updating the baseline commit above and
the Swift port map.
