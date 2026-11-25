# Seridian Studio

Seridian Studio is a native digital audio workstation by [Seridian](https://seridian.dev). Its audio engine and project model are written in Zig; its new desktop interface is built with [Raven](https://github.com/oscar-soirey/Raven), a lightweight C GUI library.

The Raven interface is replacing the former GTK4 frontend. The current workspace includes transport, tempo, clip arrangement, track mute/solo and gain, master gain, meters, and session open/save controls. The older GTK4 sources remain as reference during the port and are no longer part of the build.

## Build on Gentoo Linux

Requirements:

- Zig `0.18.0-dev.738+ae9a8acc7` (pinned; `run.sh` finds it under `~/.local/share/zig/dev738`)
- CMake and Ninja
- X11 development headers and Vulkan headers/runtime
- PulseAudio and PipeWire development libraries for the audio backends

Raven is vendored under `vendor/raven` under its Apache-2.0 license and notices. The build configures and compiles its static library automatically.

```sh
zig build -Doptimize=ReleaseFast
zig build run
zig build test
```

On Wayland, Raven currently opens through XWayland. Its upstream Linux backend is X11-based.

## Layout

`zig build` produces three binaries, split by how often each part changes:

| Output | Source | Contents |
| --- | --- | --- |
| `lib/libdaw-engine` | `src/engine_lib.zig` | Audio engine, DSP, instruments, effects, MIDI, project and config (C ABI only) |
| `lib/libdaw-ui` | `src/ui/zig/ui_lib.zig` | Raven window: transport, timeline, mixer (Zig) |
| `bin/seridian-studio` | `src/main.zig` | Launcher: engine startup via `daw_runtime_*`, then the Raven event loop |

Audio output on Linux uses PulseAudio or native PipeWire (set `DAW_AUDIO_BACKEND=pipewire`
to force it); with neither running the app still starts with silent, real-time-clocked
output. Effects that add latency (Vocal Tune, Vocal Strip) are delay-compensated.
Run `seridian doctor` to check the system for low-latency audio. Recording uses the
default input through PulseAudio/PipeWire.

## Documentation

- [docs/CONTROL.md](docs/CONTROL.md): the socket and `seridian` CLI control protocol (every command, the state JSON, limits, worked examples)

## Project layout

- `src/audio`, `src/dsp`, `src/effects`, `src/instruments`: Zig audio engine
- `src/project`, `src/config`, `src/midi`: sessions, settings, and MIDI
- `src/ui/zig`: Raven-based Seridian Studio interface in Zig (`app/` is the window, one file per area)
- `src/ui/main_window_gtk.c` and GTK components: deprecated reference frontend, excluded from builds
- `vendor/raven`: pinned Raven source and upstream notices
- `libs/`: Zig libraries layered per `docs/design/architecture.md` (`zig build test-<name>`); `libs/RUST_TO_ZIG.md` is the guide for the translations from SoundCraft
- `libs/vocal`: realtime vocal processing translated from PitchPure (pitch correction, formant, harmony, vocal EQ, de-ess, rider, compressor, denoise, tape, delay, reverb, limiter, and the full vocal chain); exposed as track effects by `src/effects/vocal.zig`

## Install

```sh
zig build -Doptimize=ReleaseSafe
packaging/install.sh                  # system-wide, PREFIX=/usr/local (use doas or sudo)
PREFIX=$HOME/.local packaging/install.sh   # one user
```

This installs the app, its libraries, a desktop entry with icon (`StartupWMClass=seridian-studio`, so KDE Plasma and other shells match the window to its launcher), and AppStream metadata.

## License

Raven is Apache-2.0 as well; its upstream `LICENSE` and `NOTICE` are included with the vendored dependency. Parts of `libs/` are translated from SoundCraft (MIT OR Apache-2.0, ArtCraft Team and the SoundCraft contributors); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the license text and attribution. Seridian Studio itself is licensed under the Apache License 2.0; see [LICENSE](LICENSE).
