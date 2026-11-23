# Piano roll editing: rules and state snapshot

Pure editing rules live in `src/ui/zig/piano_edit.zig` (tests first; bodies are
stubs until implemented). The widget (`src/ui/zig/piano_roll.zig`) and wiring
(`src/ui/raven_app.c`) call them and then the engine note API.

## Rules

- Grid: 40 px per beat, pitch rows about 12 px, grid origin at window x 14.
- Hit test: topmost note wins (later drawn = on top). The rightmost 6 px of a
  note (clamped to its width) is the resize zone; the rest is the body.
- Rectangle select: drag corners in any direction are normalised to a
  positive-size rectangle.
- Move: the earliest selected note's new start snaps to the grid; no note may
  start before beat 0.
- Resize: the note end snaps to the grid; length is at least one grid step.
- Click: plain click selects only that note; shift-click toggles it and keeps
  the rest of the selection.

## Engine calls

`midi_clip_add_note`, `midi_clip_remove_note`, `midi_clip_move_note`,
`midi_clip_resize_note`, `midi_clip_select_in_rect`, `midi_clip_select_all`,
`midi_clip_delete_selected`, `midi_clip_get_note`, `midi_clip_get_note_count`
(`src/midi/midi_clip.zig`). `midi_clip_get_note` returns id, start beat,
duration, pitch, velocity and selected flag by index.

## Per-note state snapshot

The UI state snapshot (see `ui-harness.md`) gains the notes of the selected
track as an array. Each entry is derived from `midi_clip_get_note`:

```json
"notes": [
  { "start": 0.0, "length": 1.0, "pitch": 60, "selected": false },
  { "start": 1.5, "length": 0.5, "pitch": 64, "selected": true }
]
```

| Field | Type | Meaning |
| --- | --- | --- |
| `start` | number | Start in beats (`start_beat`), >= 0 |
| `length` | number | Duration in beats (`duration`), >= one grid step |
| `pitch` | integer | MIDI pitch 0..127 |
| `selected` | boolean | True when the note is selected |

Order follows note index (`0 .. midi_clip_get_note_count - 1`). The array is
empty when the selected track has no notes. Note ids and velocity are not part
of the snapshot.
