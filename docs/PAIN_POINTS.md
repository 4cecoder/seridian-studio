# What users hate about DAWs, and how Seridian attacks it

Research notes from public forum threads (KVR, Steinberg, Image-Line, Native Instruments, Ardour
Discourse, Cakewalk, Fender/Suno announcements). Everything here is anecdotal: forum posts, several from
2019 to 2024, no systematic survey. Reddit could not be searched. A KVR poll of "which DAW do you hate
most" put Ableton Live first (about 20.5%), Logic Pro second (19.2%) and Pro Tools third (16.1%); it is a
self-selected vote and only a rough signal.

## Pain points reported, with sources

| theme | what people say | sources |
|-------|-----------------|---------|
| Slow, fragile setup | Pro Tools needs about six menu steps to make an audio track; Logic's file browser and track setup are slow; Reaper needs heavy customization before it is usable | [KVR: top 3 things you hate](https://www.kvraudio.com/forum/viewtopic.php?p=7295322), [KVR: what DAW do you hate](https://kvraudio.com/forum/viewtopic.php?p=7408286), [B&H guide](https://www.bhphotovideo.com/explora/node/126356) |
| Weak MIDI editing | Live's MIDI editor and missing event list; Pro Tools MIDI is cumbersome | [KVR: lacking vs the competition](https://www.kvraudio.com/forum/viewtopic.php?p=8472535), [B&H guide](https://www.bhphotovideo.com/explora/node/126356) |
| Plugin scanning | Scans hang on one bad plugin, take 5 to 10 minutes or most of a day, or repeat on every launch when the host should cache the result | [NI: Maschine scan](https://community.native-instruments.com/discussion/40578/maschine-3-cant-scan-vst-plugins-successfully), [KVR: Live's slow scan](https://kvraudio.com/forum/viewtopic.php?p=8902733), [Image-Line request](https://forum.image-line.com/viewtopic.php?p=1971374) |
| A plugin crash takes down the session | FL Studio crashing when a plugin opens; Bitwig praised for surviving plugin crashes | [KVR: Zebra scan](https://www.kvraudio.com/forum/viewtopic.php?p=8988380), [Steinberg: Waves engine](https://forums.steinberg.net/t/the-engine-for-waves-plugins-sucks/1039209) |
| Linux audio | Ardour xruns on newer distros where Bitwig is clean; Reaper needs adjusting for PipeWire; PipeWire's JACK layer blamed for latency; Windows VSTs through yabridge need bigger buffers | [Ardour Discourse: performance](https://discourse.ardour.org/t/is-there-any-attention-towards-big-performance-issues-in-ardour-on-newer-distros/111621), [Ardour Discourse: comparison](https://discourse.ardour.org/t/ardour-vs-reaper-vs-bitwig-studio-vs-tracktion/106025/62), [KVR: Linux DAW thread](https://www.kvraudio.com/forum/viewtopic.php?p=8766371) |
| Cost and platform lock | Logic needs a Mac; Pro Tools is heavy and expensive | [KVR: what DAW do you hate](https://kvraudio.com/forum/viewtopic.php?p=7408560) |
| Stem separation | The most requested add-on; Ardour users script Demucs themselves; Fender Studio Pro ships it | [Ardour Discourse: stem separation](https://discourse.ardour.org/t/ai-stem-source-separation-in-ardour/112808/12), [MusicRadar on Fender Studio Pro](https://musicradar.com/music-tech/daws/ai-isnt-the-destination-making-music-is-fender-looks-forward-as-its-studio-pro-daw-integrates-moises-stem-separation-and-a-smart-studio-assistant) |
| Scripting and automation | Requests for open project APIs, AI copilots for Live and Reaper, and a conversational DAW (Suno Studio 2.0); also skepticism that it is a gimmick | [KVR: AI copilot for Live](https://www.kvraudio.com/forum/viewtopic.php?p=9154651), [Steinberg: future of automation](https://forums.steinberg.net/t/the-future-of-automation-ai-and-workflow-in-cubase-where-are-we/1041717), [MusicTech on Suno Studio 2.0](https://musictech.com/news/gear/suno-studio-2-0-upgrade-new-features/) |
| Switching habits | Much of the loudest complaining is people moving DAWs and missing their old keys | KVR threads above |

## Where Seridian attacks each one

| pain | attack | status |
|------|--------|--------|
| Setup friction | A new session is usable at once: instruments are built in, no browser to dig through; `seridian song` and the CLI build a whole session in seconds | have |
| Plugin scanning | Scan in a child process with a per-plugin timeout, cache results on disk, never scan at startup, blacklist a plugin that hangs and say which one. `libs/plughost` has CLAP and VST3 scanners to build this on | to build (P2) |
| Plugin crash kills the session | Host plugins out of process so a crash drops one strip, not the project; crash recovery and the unsaved-changes prompt are already in | recovery have, isolation to build |
| Linux audio | Native PipeWire stream in Zig (no JACK layer), PulseAudio fallback, `seridian doctor` checks realtime setup; add an xrun counter in the status bar | part |
| MIDI editing | Piano roll exists; add an event list view and quantize and humanize commands | to build |
| Cost, platform | Free, Apache-2.0, native Linux | have |
| Stem separation | Offer it as an optional command that calls a local model, off by default | to build (P3) |
| Scripting and AI | The control socket and `seridian` CLI already drive the live app; publish the protocol so any script or agent can use it, and add `seridian instruments`, reverb and effect commands, track add and rename (gaps G1, G2, G5) | have, widening |
| Habit switching | Keymap presets (Ableton, Logic, Reaper) from the single keymap table | to build |

## Reading the evidence honestly

These threads show what annoys a vocal minority of forum users. They do not show what most
producers want. The plugin-scanning and crash-isolation complaints are the most consistent across
products, which makes them the safest bet. The AI complaints are mixed, so scripting and the CLI come
first, and anything generative stays optional.
