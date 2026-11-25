# QA ledger: bugs, gaps and features

One shared list for the adversarial QA and developer loop. Each item has an id, a status
(`open`, `fixed`, `wontfix`), how it was found, and (when fixed) the test that guards it.
QA reopens an item when the fix does not hold. Developers fix test-first.

## Bugs

| id | status | finding | evidence |
|----|--------|---------|----------|
| B1 | fixed | CLI rejected bad arguments with the whole usage line and no hint which argument was wrong | `describeProblem` tests in `src/cli/main.zig` |
| B2 | open | `seridian set N instrument Nope` lists only 3 of the 20 instruments ("try: Keys, WavetableSynth, SuperSaw") | live probe |
| B3 | open | CLI accepts `note ... start` up to 1e9 beats, the app rejects above 1e6 and answers with a different message | `note 1 60 1e9 1 90` |
| B4 | open | `seridian state` right after a command can return the previous value (state file lags): `bpm 74` then `state` showed 74.5 | live probe |
| B5 | open | Instrument names do not round-trip: set `ModelPiano`, state reports `Model Piano` | state JSON vs `set` |
| B6 | open | `save` and `export` failures say "could not create the folder" / "could not export the WAV" with no cause (no errno, no path) | probes on `/proc/...` |
| B7 | open | Both the running app (Nov 16 build) and the new build report `seridian 0.1.0`; nothing identifies the build | `seridian version` |
| B8 | open | `/usr/local/bin/seridian-studio-headless` is a stale copy of the Nov 16 GUI binary | `cmp` |

## UI/UX bugs

| id | status | finding | evidence |
|----|--------|---------|----------|
| U1 | open | On-screen help lists `S` for split but not `Ctrl+E`, and omits undo/redo, copy/cut/paste, duplicate, select all, view switching and the pop-out keys. Two copies of the text exist and disagree with `keymap.zig` | `app/settings_transport.zig:579`, `app/mixer.zig:842` |
| U2 | open | `seridian status` / `screenshot` report "window not found" against a KDE Plasma Wayland session | needs a run inside that session |

## Gaps

| id | status | finding |
|----|--------|---------|
| G1 | open | No CLI way to add or configure an effect, so `auto <track> wet` fails on every track until someone adds a reverb in the UI |
| G2 | open | The CLI is capped at 8 tracks and cannot add, delete, rename or colour a track |
| G3 | open | `play` and `stop` answer `ok` whether or not anything changed; no transport state in the reply |
| G4 | open | `clear` has no undo and no confirmation over the socket |
| G5 | open | No `seridian instruments` listing; names are discoverable only by failing |
| G6 | open | Window and panel maximize / fullscreen are not first-class (see F1) |

## Features wanted

| id | status | feature |
|----|--------|---------|
| F1 | open | Maximize: F11 fullscreen, double-click a panel header to maximize it and again to restore, maximize for the piano roll and mixer, remembered per window |
| F2 | open | Loop region, metronome and count-in from the CLI and keyboard |
| F3 | open | MIDI file import and export from the CLI |
| F4 | open | Quantize and humanize commands |
| F5 | open | In-app update check (`seridian update`), with a real build id in `version` |
