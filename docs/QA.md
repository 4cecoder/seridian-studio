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
| B9 | fixed | DATA LOSS: `save` silently skips any track whose serialized MIDI exceeds the 32 KB buffer (about 1700 notes); the reply is `ok`, no `midi_trackN.bin` is written, and `open` brings the track back empty. A stale file from an earlier save is not removed either (the `size <= 0` path just `continue`s). Load has the same 32 KB cap | `persistence.zig:130,153-154,303`. Repro: add 1800 notes to track 8 with `note 8 ...`, `save D`, `ls D` has no `midi_track7.bin` (twice) Guarded by test `save keeps a track whose MIDI exceeds 32 KB and reports a track that cannot be written`. |
| B10 | fixed | DATA LOSS: gain above 1.0 is accepted (`set N gain 1.5`, usage says 0..1.5) and heard in export (peak 0.718), but `state` reports 1.0 and `save` writes `volume = 1.0000`; after `open` the peak is 0.693. Mixer capture reads the clamped fader value | `project_capture_mixer` `app/project.zig:~228`; `set 1 gain 1.5; save D; open D; export` twice Guarded by test `AudioEngine - setTrackGain clamping; track gain above 1.0 is stored through the C API`. |
| B11 | fixed | DATA LOSS: `open` ignores `bpm` and `master_volume` in project.daw. Save at 150, `bpm 77`, `open` leaves 77; editing the file to `bpm = 90` also has no effect. `refresh_after_load` only reads the engine tempo back | `app/project.zig:405-413,418-424`; `project_apply_mixer` applies tracks only Guarded by test `tests/e2e/control_regressions.sh open_restores_bpm_and_master`. |
| B12 | open | DATA LOSS: effects chains and automation are not persisted. After `eq 1 preset bass`, `eq master tilt on`, `auto ...`, the saved project.daw has every `[TrackNEffects] count = 0` and no automation section; `open` of that save exports like a clean session. The autosave signature also leaves out effects, automation, master gain and loop, so a recovery copy is not refreshed by those edits | `session_signature` `app/project.zig:442-484`; save, open, export, compare WAVs (twice) |
| B13 | open | Corrupt `midi_trackN.bin` is accepted and reported `ok`: a 100-byte truncation loads 4 notes, 20000 random bytes load 1051 garbage notes on that track (no length or range validation). Only a log warning, never a reply | `loadMidiData` `persistence.zig:~300-335`; `open` a copy built with `head -c 100` or `/dev/urandom` (twice) |
| B14 | open | Truncated, empty or garbage `project.daw` makes `open` answer `ok` while every mixer value silently resets to defaults (gain 0.2 became 0.75); parse errors are only `log.warn`ed per key. The file is also silently cut at 64 KB | `parseProjectIni` `persistence.zig:~355-375`, 64 KB read at `:281-284`; `open` a truncated copy (3 variants) |
| B15 | fixed | Relative paths are resolved against the app's working directory, not the CLI's: `cd /tmp/x; seridian save rel` and `seridian export a.wav` create the files in the app's cwd (the repo here) and reply `ok`. The CLI should make PATH absolute before sending | `cli/main.zig` `sendCommand`; `app/control.zig:~257-290`; twice Guarded by test `tests/e2e/control_regressions.sh relative_paths_are_absolute; CLI unit test 'relative save, open and export paths become absolute against the CLI's directory'`. |
| B16 | open | A socket client that sends several lines in one write gets one `ok` and only the first line runs (`bpm 111` then `bpm 222` leaves 111); the rest is dropped silently. An embedded NUL truncates the line the same way (`bpm 133\0junk` is `ok`) | `control_poll` `app/control.zig:~385-398` |
| B17 | open | `export` of an empty session writes a 10.0 s silent WAV and replies `ok peak 0.000` | clear all 8 tracks, `export /abs/e.wav`, `ffprobe` (twice) |
| B18 | open | `export` runs synchronously on the UI thread with no cap: one note at beat 3000 gives a 1500 s, 288 MB WAV and 28.5 s with the socket and window frozen; the `note` limit of 1e6 beats allows a roughly 96 GB export. The "Exporting WAV..." status is set before the blocking call so it is never painted. No free-disk check | `control_export` `app/control.zig:~280`, `app/project.zig:386`; `note 1 60 3000 1; time seridian export /abs/f.wav` |
| B19 | open | When an automation lane holds 128 points a further point is refused with "that lane is full", even one at an existing beat that would only replace a value; two points at one beat are otherwise both kept | `auto 1 gain 5 0.5` repeated, `control_auto_add` `app/control.zig:~178` |
| B20 | open | `state` lists at most 256 notes in `piano_roll.notes` while `note_count` shows the real total (264 listed as 256, 5000 as 256), with no truncation flag | `seridian state` after `song` (twice) |
| B21 | open | Automation gain points are capped at 0..1 while `set gain` allows 0..1.5, so a lane cannot reach a level the fader can | `control_auto_add` `app/control.zig:~173`, `CONTROL_GAIN_MAX` |

## UI/UX bugs

| id | status | finding | evidence |
|----|--------|---------|----------|
| U1 | open | On-screen help lists `S` for split but not `Ctrl+E`, and omits undo/redo, copy/cut/paste, duplicate, select all, view switching and the pop-out keys. Two copies of the text exist and disagree with `keymap.zig` | `app/settings_transport.zig:579`, `app/mixer.zig:842` |
| U2 | open | `seridian status` / `screenshot` report "window not found" against a KDE Plasma Wayland session | needs a run inside that session |
| U3 | open | DATA LOSS: closing the window quits with no "unsaved changes" prompt and marks the recovery copy clean, so unsaved MIDI, mixer and automation work is discarded | `on_window_close` `app/project.zig:589-594` |
| U4 | open | New and Open only warn when `session_has_content()` is true, which counts audio clips and a save location, not MIDI notes or mixer edits. A MIDI-only session is thrown away with no prompt, while a saved but unchanged session always prompts | `app/widgets.zig:201-208`, `app/project.zig:147,507` |
| U5 | open | Plain `S` is bound to split in the keymap, which runs before the piano handler and consumes the key, so the computer-keyboard note `s` (D) never plays on the Piano Roll tab or the popout | `keymap.zig:~86`, registration order `app/control.zig:519-521`, `piano_math.zig:86` |
| U6 | open | Export WAV and Save As have no button, menu entry or tooltip. Export is reachable only by Ctrl+Shift+E (in the status-bar hint but not in the Session tab help), Save As only by Ctrl+Shift+S, which no text mentions | `app/settings_transport.zig:282-288,579`, `app/mixer.zig:842`, `app/actions_popout.zig:130` |
| U7 | open | The window keymap skips shortcuts while a text field has focus, but the piano key handler has no such check, so typing in a field while the Piano Roll tab is active may play notes and swallow `z` / `x`. The dialog guard also omits `FILE_SAVE`, so Ctrl+S can stack a second file dialog | `app/piano.zig:583-596` vs `app/actions_popout.zig:196`; guard `:23-26` (code reading, not run) |
| U8 | open | Save As refuses an existing folder name ("A folder with that name already exists") with no overwrite option, while the socket `save` overwrites any existing folder silently; the two paths disagree | `app/project.zig:~176-190` vs `app/control.zig:~262` |
| U9 | open | Status message says "Cmd+2" on Linux (the binding is Ctrl+2) | `app/actions_popout.zig:59` |

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
