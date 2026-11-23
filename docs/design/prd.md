# Seridian Studio — product brief

Seridian Studio is a Linux-first digital audio workstation by Seridian. It aims to pair a responsive, low-latency Zig audio engine with a focused creative interface powered by Raven.

## Product identity

- Product: **Seridian Studio**
- Publisher: **Seridian**
- Website: [seridian.dev](https://seridian.dev)
- UI: Raven C GUI library
- Engine: Zig 0.18+

## Current application surface

- Audio engine transport and tempo controls
- Four-track arrangement timeline with clip scrubbing, movement, and trimming
- Track gain, mute, solo, and level meters
- Master gain and stereo output meter
- Session folder open and save
- PulseAudio and PipeWire output paths on Linux

## Product direction

The first priority is a stable, usable Linux production workflow: import and record audio, arrange and edit clips, create MIDI parts, mix with native effects, and save portable sessions. Improve discoverability and accessibility as the Raven UI grows. Maintain real-time audio safety independently of UI rendering and scheduling.

## Current technical constraints

- Raven 0.1 is active development; pin the vendored commit and review API changes deliberately.
- Raven's Linux windowing backend is X11; Wayland users currently depend on XWayland.
- The GTK4 frontend is deprecated and excluded from the build. Some editor features have not yet been ported to Raven.
- App distribution terms must be defined by Seridian; Raven is included under Apache-2.0 with its upstream notices.
