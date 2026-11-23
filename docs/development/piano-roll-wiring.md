# Piano roll wiring spec

Goal: edit MIDI notes in the app and play them, so a song can be made. This
spec only covers what that needs. No code is in this file.

Sources read: `src/ui/zig/piano_roll.zig`, `src/ui/raven_app.c`,
`src/ui/window_input.{c,h}`, `src/ui/piano_math.h`, `src/midi/midi_clip.zig`,
`src/audio/engine_c_api.zig`, `tests/e2e/smoke.sh`.

## What exists

- The widget (`piano_roll_create`, `set_view`, `set_grid`, `set_base_pitch`,
  `note_count`, `get_note`, `add_note`, `clear_notes`) keeps its own note list
  (max 512). It has no note ids and no change callback.
- Edits it can make today: left click on an empty cell adds a one-grid-cell
  note; left click on a note, or right click on a note, removes it. It has no
  drag-move and no resize, so `midi_clip_move_note` and `midi_clip_resize_note`
  are not needed yet (see "Later").
- The widget removes with a swap-remove, so its note indices are not stable.
- The engine's per-track clip (`midi_clip_*`) identifies notes by `u32` id.
  `midi_clip_get_note(track, index, &id, &start, &duration, &pitch, &velocity,
  &selected)` returns 1 on success. `midi_clip_add_note(track, start, duration,
  pitch, velocity)` returns the id, or 0 on failure.
  `midi_clip_remove_note(track, id)` returns 1 on success.
- `raven_app.c` has `SERIDIAN_TRACK_COUNT` = 4 tracks and tab constants
  `SERIDIAN_TAB_*`. `build_arrangement` builds the timeline plus the inspector
  tab view. `write_state_snapshot` fills `UiTrackState` per track.
  `seridian_window_input_add(handler, context)` registers a handler on the
  shared dispatcher (handler: `int (*)(void *ctx, const void *event)`, non-zero
  consumes).

## 1. New export: `piano_roll_set_on_change`

Add to `src/ui/zig/piano_roll.zig`:

`piano_roll_set_on_change(widget, callback, user_data)`

Callback type: `void (*)(int kind, int pitch, double start_beat, double length_beats, void *user_data)`.

- `kind`: 0 = note added, 1 = note removed.
- The values describe the note that was added or removed, in beats, as stored
  in the widget (so the app can find the matching engine note).
- Fired only from user pointer edits (`pointerDown` when it adds or removes).
  Never fired by `piano_roll_add_note` or `piano_roll_clear_notes`, so the app
  can reload a track without echoing edits back into the engine.
- Passing a NULL callback clears it. An invalid widget is ignored.
- Needs a pure-state Zig test: a click that adds fires one "added" event with
  the snapped start and grid length; a click on that note fires one "removed"
  event with the same values; `add_note`/`clear_notes` fire nothing.

## 2. Mapping grid edits to `midi_clip` calls (selected track)

The app keeps `piano_track` (0..3), the track chosen in the Piano Roll tab.
The on-change handler acts on that track:

- Added: call `midi_clip_add_note(piano_track, start_beat, length_beats, pitch,
  100)`. If it returns 0, show a status message and rebuild the widget from the
  engine (below) so the two never disagree.
- Removed: scan `midi_clip_get_note` for index 0..`midi_clip_get_note_count`-1
  for the note whose pitch matches and whose start and duration match within
  1e-6; call `midi_clip_remove_note(piano_track, id)` with its id. If none
  matches, rebuild from the engine.

Reload (on track change, and on startup): `piano_roll_clear_notes`, then for
each engine note `piano_roll_add_note(widget, pitch, start, duration)`. The
engine is the source of truth for the song.

Beats are clip-relative. Velocity is fixed at 100 for now.

## 3. Piano Roll tab with a track combo

- Add a Piano Roll tab next to the Arrangement using `Rtab_view` (the same
  widget family as the inspector). Tabs: "Arrangement" (existing content from
  `build_arrangement`) and "Piano Roll". Add `SERIDIAN_TAB_*`-style constants
  for the new main-area tab indices; keep them separate from the inspector's
  constants.
- The Piano Roll tab holds: a header row with a track combo
  (`Rcombo_box`, one item per track from `project_get_track_name`, falling back
  to "Audio N") and a grid combo (1/4, 1/8, 1/16, 1/32 mapped to
  `piano_roll_set_grid` 0..3); below it the piano roll widget, set to fill.
- Changing the track combo sets `piano_track` and reloads the widget from the
  engine (section 2). Default track is 0.
- Create the widget with `on_key = NULL` so the widget itself never plays
  notes; computer-key playing is done in section 4 only. Register the on-change
  handler right after creation.
- Do not change any `vendor/raven` file.

## 4. Computer keys play the selected track

Register one handler with `seridian_window_input_add` (the shared dispatcher;
do not call `Rwindow_set_event_hook` again).

- On key down: ignore if any modifier (Ctrl, Alt, Super) is held; also ignore
  when the Piano Roll tab is not the active main tab, so typing elsewhere does
  not play notes. Fold the letter to lowercase and call
  `piano_key_to_pitch(key, base_pitch)` from `piano_math.h`. If the result is
  below 0, return 0 (not consumed). Otherwise, on a first press (not an
  auto-repeat, and not already held) call
  `audio_engine_note_on(engine, piano_track, pitch, 100)` and return 1.
- On key up: if that key is holding a pitch, call
  `audio_engine_note_off(engine, piano_track, pitch)` and return 1.
- Keep a held-pitch table indexed by key (like the widget's), so the note-off
  matches the pitch that started it even if the octave or track changed. On
  window focus loss and on track change, send note-off for every held key.
- `z` and `x` shift `base_pitch` down and up an octave (`piano_shift_octave`),
  no modifiers, no repeat. Mirror the value into `piano_roll_set_base_pitch`.
- With modifiers held the handler returns 0, so existing shortcuts (Ctrl+S,
  Ctrl+Z and so on) still work.
- `audio_engine_note_on/off` need a track with an instrument; if the track has
  none (`audio_engine_track_has_instrument` is 0), show "Pick an instrument for
  this track" in the status bar once and do not call the engine.
- `audio_engine_note_off` is declared `export fn` (not `pub export`) in
  `engine_c_api.zig`; confirm it links from C, as `note_on` is `pub export`. If
  it does not, make it `pub export`.

## 5. State snapshot: `midi_notes` per track

- Add `int midi_notes;` to `UiTrackState` in `src/ui/ui_state.h`.
- In `write_state_snapshot`, set `out->midi_notes = midi_clip_get_note_count(track)`.
- In `ui_state_format` (`src/ui/ui_state.c`), emit `"midi_notes":N` for each
  track, next to `instrument`.
- Add the field to the `tests/ui/ui_state_test.c` format test (red first), and
  update the JSON example in `docs/development/ui-harness.md`.

## 6. E2E checks to add (`tests/e2e/smoke.sh`)

The harness drives by window-relative pixels, so add `TAB_X/TAB_Y`,
`ROLL_X/ROLL_Y` constants like `KNOB_X/KNOB_Y`, and document them in
`ui-harness.md`. Add a helper to read `.tracks[N].midi_notes` with `jq`.

1. Baseline: `midi_notes` of track 0 is a number (0 on a fresh session).
2. Switch to the Piano Roll tab (click the tab), click an empty grid cell:
   `midi_notes` of track 0 becomes baseline + 1.
3. Click the same cell again (it is now a note): `midi_notes` returns to
   baseline.
4. Right click on an added note removes it (needs a right-click option in the
   CLI; if absent, skip and say so, do not fake it).
5. Add two notes at different cells, switch the track combo to track 1 and
   back to track 0: track 0 still reports baseline + 2 and track 1 is
   unchanged (the reload path).
6. Key play: press `a` with the Piano Roll tab active; check the app log has no
   error and the track meter or `tracks[0]` state is unchanged otherwise. Audio
   level cannot be asserted from the snapshot unless a meter field is added;
   do not claim a sound check without one.
7. Modifier guard: `ctrl+a` must not play and must not change `midi_notes`.

Each check prints `[PASS]` or `[FAIL]` through the existing `pass`/`fail`
helpers; report the script output verbatim.

## Unit tests that go with it

- `zig build test`: the on-change export test from section 1.
- `zig build test-ui`: `ui_state_test` covers `midi_notes`.
- A small pure-C test for the held-key table logic if it is put in a header
  under `src/ui/` (no Raven calls), registered in `ui_test_files` in `build.zig`.

## Later (not needed to make a song)

Note drag-move and resize (would use `midi_clip_move_note` and
`midi_clip_resize_note`), velocity editing, quantize, and playing the clip back
in time with the transport.
