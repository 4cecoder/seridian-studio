# Control protocol

Seridian Studio can be driven from scripts and other programs without touching the window. There are two
layers, and both are described here as they behave in this build:

- the **socket**: a line protocol over a Unix socket that the running app listens on;
- the **`seridian` CLI**: validates arguments, sends one line to the socket and prints the reply.

The headless build (`seridian-studio-headless`) answers the same protocol as the window, so everything
below also works on a machine with no display.

Out of scope for now: adding, deleting or colouring tracks. The mixer has a fixed set of 8 tracks.
`set N name` renames one; nothing else about the track list can be changed from the CLI.

## Transport

| Item | Value |
|------|-------|
| Socket | `$XDG_RUNTIME_DIR/seridian.sock`, a Unix stream socket, mode `0600` |
| State file | `$XDG_RUNTIME_DIR/seridian-state.json` (`/tmp/seridian-state.json` when `XDG_RUNTIME_DIR` is unset) |
| Log file | `$XDG_RUNTIME_DIR/seridian-app.log` (`seridian logs [N]`) |

The app creates the socket only when `XDG_RUNTIME_DIR` is set and not empty. The CLI looks in the same
place, so a script that must reach a particular instance sets `XDG_RUNTIME_DIR` for both. A second app
started in the same runtime directory exits with a message naming the running pid.

## Requests and replies

One request is one connection:

1. Connect.
2. Send one command line ending in `\n`.
3. Read one reply line ending in `\n`.
4. The app closes the connection.

Reply forms:

| Reply | Meaning |
|-------|---------|
| `ok` | The command ran. |
| `ok DETAIL` | The command ran and has something to report (`ok playing`, `ok peak 0.704`). |
| `error: MESSAGE` | Nothing was changed. The message says why. |

Limits:

| Limit | Value |
|-------|-------|
| Line length | 128 bytes per request including the newline, so a command is at most 127 bytes. A longer one gets `error: line too long`. |
| Commands per request | One. Anything after the newline, in the same request, is refused with `error: send one command per request` and nothing runs. A NUL byte in the line is refused with `error: the command contains a NUL byte`. |
| Words per line | 8, separated by spaces, tabs or `\r`. More gets `error: too many arguments`. |
| Path length | 1 to 120 bytes, no spaces. A longer one gets `error: path is too long`. A missing path is a usage error (`error: usage: save <path>`), because the line is split on spaces. |
| Client slots | 8 connections at a time. A ninth is closed at once with no reply. |
| Idle client | A client is dropped with no reply after 90 frames without a complete line. That is about 3 seconds in the window, but the headless build spins faster and drops after roughly 10 ms, so send the line right after connecting (QA B28). |
| Reply length | 511 bytes; a longer message is cut. |

The app reads the socket once per frame (about 30 times a second) and runs each command on its UI thread, the
same code the buttons and the piano roll use, so a command takes up to about 35 ms to be answered. Commands from
separate connections run in arrival order.

Relative paths in `save`, `open` and `export` are resolved by the app in the app's working directory. The CLI
turns them into absolute paths against its own directory first; a raw client should send absolute paths.

## Commands

Tracks are numbered 1 to 8 on the wire. `state` numbers them from 0 (`index`).

### Transport and tempo

| Command | Arguments | Reply |
|---------|-----------|-------|
| `play` | none | `ok playing`, or `ok playing (already)` when it was playing. `error: could not start the audio engine` when the engine cannot start. |
| `stop` | none | `ok stopped`, or `ok stopped (already)` when it was stopped. |
| `bpm V` | tempo 20..300 | `ok`. Errors: `usage: bpm <20..300>`, `bpm must be 20..300`. |

`play` and `stop` exit 0 either way: "already" is information, not a failure. The reply is printed on stdout.

### Mixer: `set`

`set TRACK FIELD VALUE` (the CLI usage line is `seridian set <track 1..8> gain <0..1.5> | pan <-1..1> |
mute|solo|arm on|off | reverb on|off | reverb wet <0..1> | name TEXT | instrument NAME`).

| Command | Range | Notes |
|---------|-------|-------|
| `set N gain V` | 0..1.5 | `gain must be 0..1.5` |
| `set N pan V` | -1..1 | `pan must be -1..1` |
| `set N mute on\|off` | on, off | `value must be on or off` |
| `set N solo on\|off` | on, off | same |
| `set N arm on\|off` | on, off | same |
| `set N reverb on\|off` | on, off | `on` adds one reverb to the track's effects chain (a second `on` keeps one); `off` removes it. `reverb must be on, off or wet <0..1>`, `that track's effects chain is full`. |
| `set N reverb wet V` | 0..1 | Needs a reverb: `that track has no reverb; run set <track> reverb on first`. `reverb wet must be 0..1`. |
| `set N name TEXT` | 1 to 24 printable ASCII characters, at most 5 words | See below. |
| `set N instrument NAME` | a name from `seridian instruments` | See below. |

Common errors: `track must be 1..8`, `field must be gain, pan, mute, solo, arm, reverb, name or instrument`, and
`usage: set <track> gain|pan|mute|solo|arm|reverb|instrument <value> | set <track> reverb wet <0..1> | set <track> name <text>`.

**Names.** The words after `name` are joined with single spaces, so `set 1 name Bass Line` and
`set 1 name "Bass Line"` give the same name. A name is 1 to 24 characters from printable ASCII (space to `~`),
with no leading, trailing or doubled space and no control characters (tab, newline, DEL and so on), and at most
5 words. Anything else is refused with
`name must be 1 to 24 printable characters (letters, digits, punctuation, spaces) in at most 5 words`.
`state` reports the name in `tracks[].name`; `save` writes it and `open` restores it. Unnamed tracks show as
`Track 1` to `Track 8`.

**Instruments.** `seridian instruments` prints every name, one per line, from the same table the app uses:

```
Keys WavetableSynth SuperSaw FMSynth DrumKit Strings Brass Woodwind Harp DrumKit808 DrumKit909
StringsWarm StringsBright BrassTrumpet BrassHorn ModelStrings ModelPluck ModelBrass ModelClarinet
ModelPiano ModelPercussion
```

A name matches ignoring case and spaces, so `modelpiano`, `ModelPiano` and `Model Piano` pick the same
instrument. (Over the raw socket spaces split words, so send `ModelPiano`; the CLI also accepts the quoted
`"Model Piano"` and sends the listed name.) `state` reports `tracks[].instrument` as the listed name, so the
value read back is a value `set` accepts. An unknown name is refused with the full list:
`unknown instrument; use one of: Keys, WavetableSynth, ...`. The CLI says the same from its side, before it
connects: `unknown instrument 'Nope'; use one of: ...`.

### Notes

| Command | Arguments | Notes |
|---------|-----------|-------|
| `note TRACK PITCH START LENGTH [VELOCITY]` | pitch 0..127, start 0..1000000 beats, length above 0 and up to 1000000 beats, velocity 1..127 (the CLI sends 100 when omitted) | Adds one note to the track's clip and shows that track in the piano roll. |
| `clear TRACK` | track 1..8 | Removes every note on the track. There is no confirmation; the UI's undo covers it. |

Errors: `usage: note <track> <pitch> <start> <length> [velocity]`, `pitch must be 0..127`,
`start must be a number of beats 0..1000000`, `length must be a number of beats above 0 and up to 1000000`,
`velocity must be 1..127`, `could not add that note`. The start and length limit is one constant
(`src/control_limits.zig`) shared by the CLI and the app, so both refuse the same values with the same words.
The CLI adds the offending value: `start must be a number of beats 0..1000000, got '1e9'`.

### Automation and EQ

| Command | Arguments |
|---------|-----------|
| `auto TRACK gain BEAT VALUE` | VALUE 0..1 |
| `auto TRACK pan BEAT VALUE` | VALUE -1..1 |
| `auto TRACK wet BEAT VALUE` | VALUE 0..1; the track needs a reverb (`set N reverb on`) |
| `auto master gain BEAT VALUE` | VALUE 0..1 |
| `auto clear TRACK gain\|pan\|wet` | removes every point of that lane |
| `eq TRACK preset drums\|bass\|pads\|lead\|harp` | adds the preset EQ to the track's chain |
| `eq master tilt on\|off` | master tilt EQ |

BEAT is 0..1000000. A lane holds 128 points. Errors: `beat must be a number of beats 0..1000000`, `value must be 0..1`,
`pan must be -1..1`, `lane must be gain, pan or wet`, `that track has no reverb to automate`, `that lane is
full`, `could not add the automation point`, `could not clear the lane`, `preset must be drums, bass, pads, lead
or harp`, `that track's effects chain is full`, `the master effects chain is full`, plus the `usage:` lines
for `auto` and `eq`.

### Files

| Command | Reply |
|---------|-------|
| `save PATH` | `ok`. Creates the folder (and parents), then writes `project.daw` and the per-track MIDI files. |
| `open PATH` | `ok`. Replaces the session with the one in the folder and stops playback. |
| `export PATH` | `ok peak P` (P is the peak of the 16-bit stereo WAV, three decimals). Playback must be stopped: `stop playback before exporting`. |

A failure names the path and the cause from the operating system or the engine. Errors for files (the text is
checked against the app by the e2e test `doc_error_texts`):

```
error: could not create the folder /usr/seridian-e2e/x: permission denied
error: could not create the folder /proc/version/x: not a directory
error: could not create the folder /proc/version: not a directory
error: could not open the session /nonexistent-e2e: no project.daw in that folder
error: could not export the WAV to /proc/version/out.wav: not a directory
error: usage: save <path>
error: usage: open <path>
error: usage: export <path>
error: path is too long
```

The last four are the argument errors: no path or two paths (`usage:`), and a path over 120 bytes.
Writing the session can also fail after the folder exists: `error: could not save the session to PATH: CAUSE`.

Causes include `permission denied`, `no such file or directory`, `not a directory`, `is a directory`,
`no space left on the device`, `read-only file system`, `file name too long`, `already exists`, `invalid path`, `file is busy`,
`no project.daw in that folder`. A cause without a plain wording is reported as `unexpected error (Name)`.

### Errors that apply to every command

`unknown command`, `empty command`, `too many arguments`, `line too long`, `send one command per request`,
`the command contains a NUL byte`.

## CLI-only commands

| Command | What it does |
|---------|--------------|
| `seridian instruments` | Prints the instrument names, one per line. Needs no running app. |
| `seridian state [--wait-ms N]` | Prints the state file. With `--wait-ms N` it waits up to N ms for a write newer than the call. |
| `seridian song [PATH]` | Sends about 1,800 commands that build an 88-bar demo song (5 tracks), then saves it to PATH when given. |
| `seridian version`, `doctor`, `status`, `logs`, `screenshot`, `key`, `click`, `drag`, `wm`, `devices` | Setup, window and desktop tools. They do not use the socket. |

CLI behaviour for the socket commands:

- Arguments are checked before connecting. A bad one prints `error: WHAT is wrong, got 'X'` and the usage line
  on stderr and exits 1; the app is not contacted.
- `app is not running` (exit 1) when nothing listens on the socket.
- An `ok` or `ok DETAIL` reply is printed on stdout and exits 0. An `error: ...` reply is printed on stderr
  and exits 1.

## State JSON

`seridian state` prints the state file as one line of JSON (pipe it to `jq`). The app rewrites it about four
times a second and again after every socket command, before the reply is sent, so `seridian state` right after
a command shows that command's result.

| Field | Type | Meaning |
|-------|------|---------|
| `playing` | bool | Transport is running. |
| `position_seconds` | number | Playhead, 3 decimals. |
| `bpm` | number | Tempo. |
| `master_gain` | number | Master volume. |
| `tracks` | array of 8 | One object per track, below. |
| `piano_roll.track` | int | Track shown in the piano roll (0-based). It follows the last `note` or `clear`. |
| `piano_roll.note_count` | int | Real number of notes on that track. |
| `piano_roll.notes` | array | At most the first 256 notes: `pitch`, `start_beat`, `length_beats`, `selected`. |
| `audio.output_device`, `sample_rate`, `buffer_size`, `backend` | | The audio output. `backend` is `none` when no audio server was found. |

Each track object:

| Field | Type | Meaning |
|-------|------|---------|
| `index` | int | 0 to 7. |
| `name` | string | The track name (`Track N` unless renamed). |
| `gain`, `pan` | number | Same ranges as `set`. |
| `pan_knob.x`, `pan_knob.y` | number | Window position of the pan knob, for UI automation. |
| `muted`, `soloed`, `armed` | bool | |
| `midi_notes` | int | Notes on the track. |
| `instrument` | string | The listed instrument name, or `""` when the track has none. |
| `reverb.present` | bool | The track has a reverb. |
| `reverb.wet` | number | Its wet amount, 0..1 (0 when there is no reverb). |

## Worked examples

Each command below was run against a headless instance. Start one with its own runtime directory:

```sh
export XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"
seridian-studio-headless &
until seridian bpm 120 >/dev/null 2>&1; do sleep 0.2; done
mkdir -p /tmp/seridian-demo
```

### 1. Build a 4-bar loop

A kick on every beat and a bass line, 4 bars of 4 beats at 100 bpm.

```sh
seridian bpm 100
seridian set 1 instrument DrumKit
seridian set 2 instrument WavetableSynth
seridian clear 1
seridian clear 2
for beat in $(seq 0 15); do
  seridian note 1 36 "$beat" 0.5 110
done
for bar in 0 1 2 3; do
  start=$((bar * 4))
  seridian note 2 36 "$start" 1.5 100
  seridian note 2 43 "$((start + 2))" 1.5 100
done
seridian play
seridian state | jq '{playing, bpm, kick_notes: .tracks[0].midi_notes, bass_notes: .tracks[1].midi_notes}'
seridian stop
```

### 2. Render to WAV

Export needs the transport stopped. The reply carries the peak level.

```sh
seridian stop
seridian export /tmp/seridian-demo/loop.wav
ls -l /tmp/seridian-demo/loop.wav
```

Run it after example 1: it prints `ok peak 0.xxx`. A path that cannot be written names the cause, for example
`seridian export /proc/version/a.wav` prints `error: could not export the WAV to /proc/version/a.wav: not a directory`.

### 3. Rename and mix tracks

```sh
seridian set 1 name Drums
seridian set 2 name Bass Line
seridian set 1 gain 0.9
seridian set 2 gain 0.7
seridian set 2 pan -0.3
seridian set 3 mute on
seridian set 2 solo on
seridian set 2 solo off
seridian state | jq -r '.tracks[0:3][] | "\(.index) \(.name) gain=\(.gain) pan=\(.pan) muted=\(.muted)"'
seridian save /tmp/seridian-demo/mix
seridian open /tmp/seridian-demo/mix
```

The names, gains and pans are in `project.daw`; `open` brings them back.

### 4. Add reverb and automate it

Automating `wet` needs a reverb on the track, which `set N reverb on` adds.

```sh
seridian set 2 reverb on
seridian set 2 reverb wet 0.2
seridian auto 2 wet 0 0.1
seridian auto 2 wet 8 0.8
seridian auto 2 wet 16 0.1
seridian state | jq '.tracks[1].reverb'
seridian auto clear 2 wet
seridian set 2 reverb off
```

The first `auto 2 wet` fails with `that track has no reverb to automate` until `reverb on` has run.

### 5. Script a whole song

For a ready-made one, `seridian song /tmp/seridian-demo/song` builds the 88-bar demo and saves it. To write your own,
loop over a section table. This one makes a 16-bar song (intro, verse, chorus, outro) with chords on track 1 and a
bass on track 2:

```sh
#!/usr/bin/env bash
set -eu
seridian bpm 110
seridian set 1 instrument StringsWarm
seridian set 2 instrument WavetableSynth
seridian set 1 name Pad
seridian set 2 name Bass
seridian clear 1
seridian clear 2
chords=(48 53 55 50)          # root of one chord per bar, cycled
bar=0
for section in intro:4 verse:4 chorus:4 outro:4; do
  name=${section%%:*}; bars=${section##*:}
  for _ in $(seq 1 "$bars"); do
    root=${chords[$((bar % 4))]}
    start=$((bar * 4))
    seridian note 1 "$root" "$start" 4 80
    seridian note 1 "$((root + 4))" "$start" 4 80
    seridian note 1 "$((root + 7))" "$start" 4 80
    if [ "$name" != intro ]; then
      for beat in 0 1 2 3; do
        seridian note 2 "$((root - 12))" "$((start + beat))" 0.75 100
      done
    fi
    bar=$((bar + 1))
  done
done
seridian auto master gain 0 0.6
seridian auto master gain 60 1
seridian save /tmp/seridian-demo/song16
seridian export /tmp/seridian-demo/song16.wav
```

### 6. Drive it from Python over the raw socket

No CLI needed: the protocol is one line out, one line back.

```python
import json
import os
import socket

SOCKET = os.environ["XDG_RUNTIME_DIR"] + "/seridian.sock"
STATE = os.environ["XDG_RUNTIME_DIR"] + "/seridian-state.json"


def send(command: str) -> str:
    """Sends one command, returns the reply line ('ok ...' or 'error: ...')."""
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(SOCKET)
        s.sendall(command.encode("ascii") + b"\n")
        s.settimeout(10)
        return s.makefile().readline().rstrip("\n")


def state() -> dict:
    with open(STATE) as f:
        return json.load(f)


assert send("bpm 96") == "ok"
assert send("set 1 name Python") == "ok"
assert send("set 1 instrument Keys") == "ok"
for i, pitch in enumerate([60, 64, 67, 72]):
    assert send(f"note 1 {pitch} {i} 1 100") == "ok"
print(send("play"))                      # ok playing
print(state()["tracks"][0]["name"])      # Python  (the file is fresh once the reply arrives)
print(send("stop"))                      # ok stopped
print(send("set 1 gain 9"))              # error: gain must be 0..1.5
```

Save it as `drive.py` and run `python3 drive.py`.
