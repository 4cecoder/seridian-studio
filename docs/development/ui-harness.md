# UI harness: CLI, state snapshot, and tests

This page covers how to drive, inspect, and test Seridian Studio from scripts
and AI tools, and how the UI tests are organised.

## Pieces

| Piece | Where | Purpose |
| --- | --- | --- |
| `seridian-studio` | `src/main.zig`, `src/ui/raven_app.c` | The GUI app (Raven C frontend over the Zig engine) |
| `seridian` | `src/cli/main.zig` | Command-line harness: inspect, control, screenshot |
| State snapshot | `src/ui/ui_state.{c,h}`, written from `raven_app.c` | JSON of transport and mixer state, refreshed about 4 times a second |
| App log | `run.sh` | Output of the app, saved for `seridian logs` |
| Knob widget | `src/ui/knob.{c,h}`, math in `src/ui/knob_math.h` | Rotary control used for pan |

## Running the app

```sh
zig build
sh run.sh --x11      # needs DISPLAY (Xwayland on Hyprland is :0)
```

`run.sh` writes the app log to `$XDG_RUNTIME_DIR/seridian-app.log`.
The engine also needs an audio server. If `PIPEWIRE_RUNTIME_DIR` and
`PULSE_SERVER` are both unset, the backend will not be detected, so set
`PULSE_SERVER=unix:/run/user/$(id -u)/pulse/native`.

## The `seridian` CLI

Run `seridian help` for the full list. The commands fall into three groups.

**Inspect**

- `seridian doctor`: checks X display, audio server, and screenshot tools. Exits 1 if a required tool is missing.
- `seridian status`: prints `seridian-studio is running` and `window: <id>`.
- `seridian state [--wait-ms N]`: prints the state snapshot JSON. With `--wait-ms`, waits up to N ms for a fresh snapshot.
- `seridian logs [N]`: prints the last N lines of the app log.

**Control** (all window-relative, logical pixels)

- `seridian key <combo>`: focuses the app and sends a key, e.g. `space`, `Return`, `ctrl+s`.
- `seridian click <x> <y> [--double]`: clicks a point. `--double` sends two clicks, which resets a knob.
- `seridian drag <x> <y> <dx> <dy> [--steps N] [--shift]`: presses at (x, y), moves in N steps to (x+dx, y+dy), releases. `--shift` gives fine control on knobs.

**Capture**

- `seridian screenshot [file.png]`: captures the window. Uses ImageMagick `import` if installed, otherwise `xwd` piped through `ffmpeg`.

Normal output goes to stdout and errors go to stderr, so results can be
captured in scripts:

```sh
WID=$(seridian status 2>/dev/null | sed -n 's/^window: //p')
```

## The state snapshot

The app writes `$XDG_RUNTIME_DIR/seridian-state.json` (fallback
`/tmp/seridian-state.json`), replacing it atomically through a temp file and
`rename`, so readers never see a partial file.

```json
{"playing":false,"position_seconds":0.000,"bpm":120.000,"master_gain":0.750,
 "tracks":[{"index":0,"name":"Track 1","gain":0.750,"pan":0.010,
   "muted":false,"soloed":false,"armed":false,"instrument":""}, ...]}
```

Prefer the snapshot over screenshots when checking values. Use screenshots to
check layout and rendering.

## Tests

Each layer has its own command.

| Command | Covers |
| --- | --- |
| `zig build test` | Engine and project tests (Zig) |
| `zig build test-cli` | CLI argument parsing and helpers (Zig) |
| `zig build test-ui` | Palette, UI math, knob math, state formatting (C, pure functions) |
| `tests/e2e/smoke.sh` | End to end: starts the app, drags a knob, checks state, screenshots |

### Writing UI tests

UI logic that does not call Raven goes in a header under `src/ui/` with a
test in `tests/ui/`. Each test file is a standalone C program with a
`failures` counter. Register new tests in the `ui_test_files` list in
`build.zig`, and add any `.c` sources they link against to the same loop.

Rules for the pure headers:

- No Raven or engine calls.
- Every rule gets a test first (red), then the implementation (green).
- Tests cover edge cases: zero-width ranges, clamping, buffer overflow, and boundaries.

### The end-to-end test

`tests/e2e/smoke.sh` needs a live X display and an audio server. It:

1. starts the app if it isn't running, and waits for the state snapshot
2. checks four tracks are reported
3. drags Track 1's pan knob upward and checks pan moved right
4. double-clicks the knob and checks pan returned to centre
5. saves a screenshot and a copy of the state to the artifact directory

```sh
zig build
tests/e2e/smoke.sh            # artifacts in $XDG_RUNTIME_DIR/seridian-e2e
```

It exits 0 when every check passes. On failure, look at the artifacts first:
`app.log`, `state.json`, and `final.png`.

## Known limits

- Drag sensitivity is calibrated against the state snapshot, not by eye.
- The e2e test assumes Track 1's knob sits at the coordinates in `smoke.sh`.
  If the mixer layout changes, update `KNOB_X` and `KNOB_Y`.
- Raven is still the C frontend. A Zig port is planned on a custom fork.
