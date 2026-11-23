# Getting started

## Gentoo Linux prerequisites

Install Zig 0.18 or newer, CMake, Ninja, X11 and Vulkan development headers, plus the PulseAudio and PipeWire development libraries used by the audio backends. Raven's current Linux platform is X11; Wayland desktops run it through XWayland.

The Raven source is vendored in `vendor/raven`. `zig build` configures and builds its static library automatically, so a separate GTK4 installation is no longer required.

```sh
zig version
zig build -Doptimize=ReleaseFast
zig build run
```

To run the engine test suite without opening the UI:

```sh
zig build test
```

## First session

Seridian Studio opens with four audio tracks. Use the timeline to scrub, move, and trim clips; the transport controls start and stop the audio engine. Track gain, mute, solo, and master gain are available in the mixer. Use **Save session** to select a session folder.

## Runtime notes

- Raven loads the system Vulkan driver at runtime.
- On Wayland, make sure XWayland is installed and available.
- Choose an audio backend in `daw.conf`; supported Linux backends are PulseAudio and PipeWire.
- GTK4 source files still exist as migration reference, but are not built or linked.
