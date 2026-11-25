# Competitive review: layout, workflow and gaps

How Seridian Studio compares with Ableton Live, Logic Pro and Pro Tools, based on a real
headed run at 1440x920 (build 1f17bb5) and the QA ledger (`docs/QA.md`). Competitor behaviour
is from general knowledge of those products; Seridian behaviour is from the screenshots and code.

## What the screen shows today

Top to bottom: header (title, session buttons, system status), transport (play, stop, record,
split, time, tempo, tap), tab strip (Arrangement, Piano Roll), the arrangement on the left with
a Session / Clip / Track FX panel on the right, and a mixer with eight strips and a master
filling the bottom third. The status bar is at the very bottom.

## Layout findings

| id | finding | why it matters |
|----|---------|----------------|
| L1 | The mixer takes about 35% of the height and the arrangement about 25%. The arrangement is where work happens, and only two of eight tracks are visible | Every competitor gives the arrangement the most space and lets the mixer collapse (Ableton: Tab switches views; Logic: X toggles the mixer; Pro Tools: Edit and Mix windows) |
| L2 | MIDI notes do not appear in the arrangement. A session of 791 notes shows "No clips in this session yet" | The first thing a user checks is whether their music is on the timeline. All three competitors draw MIDI clips with a note preview |
| L3 | The ruler is in seconds (0s, 5s, 10s). The transport shows Bar and Beat | Music is edited in bars and beats; the ruler and the readout should agree and follow the tempo |
| L4 | The title shows the previous session's name after a session is opened over the socket (title read "nick-session-backup-20261125" while the lofi session was loaded) | Wrong title means a wrong Save target in the user's head |
| L5 | The Session panel is clipped at the bottom with no scrollbar (U11, in progress) | Content unreachable at normal size |
| L6 | Eight fixed tracks; five or more sit empty as "No instrument" strips and cost screen space | Competitors start with what is used and add tracks on demand |

## Gap matrix (what a working producer expects)

`have` = present, `part` = partly, `no` = absent. Priority: P1 ship-blocking for credibility, P2 expected, P3 differentiator.

| area | Ableton | Logic | Pro Tools | Seridian | priority |
|------|---------|-------|-----------|----------|----------|
| MIDI clips visible in the arrangement | yes | yes | yes | no | P1 |
| Collapsible mixer / view toggle | Tab | X | Cmd+= | no | P1 |
| Bars and beats ruler, grid snap | yes | yes | yes | no (seconds) | P1 |
| Loop region, loop playback | yes | yes | yes | no | P1 |
| Metronome and count-in | yes | yes | yes | no | P1 |
| Add, delete, rename, recolour tracks | yes | yes | yes | no (fixed 8) | P1 |
| Undo and redo everywhere | yes | yes | yes | part | P1 |
| Save prompt on close | yes | yes | yes | have (U3) | done |
| Crash recovery | yes | yes | yes | have | done |
| Maximize a panel or window | yes | yes | yes | part (F11 toggles maximize) | P2 |
| Time signature and tempo changes | yes | yes | yes | no | P2 |
| Insert effects visible per strip, drag to reorder | yes | yes | yes | part (Track FX tab) | P2 |
| Sends and return buses | yes | yes | yes | no | P2 |
| Meters in strips with peak hold | yes | yes | yes | part | P2 |
| Browser for instruments, effects, samples | yes | yes | yes | no | P2 |
| Quantize, humanize | yes | yes | yes | no | P2 |
| Automation drawn on the timeline | yes | yes | yes | CLI only | P2 |
| Audio recording from the interface | yes | yes | yes | part | P2 |
| Plugin hosting (CLAP, VST3) | yes | AU | AAX | part (library exists) | P2 |
| MIDI import and export | yes | yes | yes | no | P3 |
| Physically modelled instruments, no samples | no | no | no | have | P3 differentiator |
| Full control from a command line while it runs | no | no | no | have | P3 differentiator |
| Open source, Linux first | no | no | no | have | P3 differentiator |

## Compact ways of working

- Layout presets, one key each: Arrange (arrangement large, mixer hidden), Mix (mixer large), Edit (piano roll large). Remember the choice per session.
- Mixer strips collapse to a thin row (name, mute, solo, meter) and expand on click.
- Hide empty tracks automatically; `+` adds the next one.
- Panel headers double-click to maximize and again to restore.
- Everything reachable from a command palette (Ctrl+K) that lists every action with its shortcut. The keymap table already exists as the single source of truth, so the palette is cheap.

## Order of work

1. L1, L2, L3 and L4: arrangement-first layout with a collapsible mixer, MIDI clips drawn on the timeline, bars and beats ruler, correct title.
2. Loop, metronome, count-in; add, delete and rename tracks.
3. Layout presets and the command palette.
4. Sends and returns, timeline automation, quantize and humanize.
5. Browser, MIDI import and export.

Each item follows the same loop: a failing test first, the smallest fix, an adversarial QA pass that
tries to break it, and a headed run to look at the real screen.

## Benchmark: a better Ableton

Ableton's strength is a fast, keyboard-driven way of sketching: Session view for trying ideas,
Arrangement view for finishing, Tab to flip between them, one device chain per track, and
everything reachable without leaving the keys. Beating it means matching that speed first and then
doing things it cannot.

Match (needed before anyone will switch):

| Ableton habit | Seridian status | work item |
|---------------|-----------------|-----------|
| Session view: a grid of clips per track that launch in time with the beat | no | new view, launch quantize, scene launch |
| Tab flips Session and Arrangement | no | view switch on the keymap (one table) |
| Device chain per track, shown beside the track | part | Track FX tab to a chain strip under the track |
| Clip view with notes, loop braces, per-clip gain and fades | part (Clip tab) | draw the clip view from the piano roll data |
| Capture MIDI: it records what you just played | no | keep a rolling buffer of live MIDI, one key to commit it |
| Tap tempo, metronome, count-in, loop | tap only | metronome, count-in, loop region |
| Drag to arrange, Ctrl+D duplicate, Ctrl+E split | have (D, E) | keep |

Beat it (what Ableton does not do):

| Edge | Why Ableton cannot easily follow |
|------|----------------------------------|
| Every action is a command. `seridian` drives the running app, so a session can be built, tweaked and rendered from a script or by an AI, and the screen updates live | Ableton's automation surface is Max for Live and a private API |
| Instruments are physical models, not sample libraries. Nothing to download, the whole instrument ships in the binary | Ableton's good sounds are paid packs |
| Open source under Apache-2.0, native Linux | closed, Windows and macOS only |
| Crash recovery and "unsaved changes" are on by default and tested | present in Ableton; parity, not an edge |
| One keymap table drives the shortcuts, the help screen and (planned) the command palette, so they cannot disagree | Ableton's help is separate from its bindings |

Next after the layout work: Session view with clip launching, the device chain strip, Capture MIDI.
