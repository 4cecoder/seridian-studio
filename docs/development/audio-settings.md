# Audio settings popout: spec

Status: spec only, no code written. Nothing in this document has been built or
run; every "expected" result below is a target, not an observed result.

Goal: from a Settings popout in the header, a song-maker can pick the output
device, input device, sample rate and buffer size, see which backend is in use,
and Apply or Cancel. Everything else (per-app routing, exclusive mode, channel
maps, persistence of device names) is out of scope.

## What exists today (read from the tree)

- `AudioEngine` (`src/audio/engine.zig`) holds `config: EngineConfig`
  (`sample_rate`, `buffer_size`, `backend_preference`), `backend: Backend`,
  `playing: atomic bool`. `start()`/`stop()` set `playing` and call
  `backend.start()/stop()`. The engine is created once in
  `src/runtime.zig` from `rt.cfg.audio`; nothing can change rate, buffer or device
  afterwards.
- `Backend` (`src/audio/backend.zig`) is a union of coreaudio, pulseaudio,
  pipewire, none. `BackendConfig` is `{sample_rate, buffer_size, channels}`:
  there is no device field.
- `PulseAudioBackend` (`src/audio/pulseaudio.zig`): `prepare()` calls
  `pa_simple_new(null, "DAW", PLAYBACK, null /* device */, ...)`. `start()`
  already frees and re-creates the stream on every start, so a device name only
  has to reach that `dev` argument. `render_buffer` is allocated once, sized
  `buffer_size * channels`, so a buffer-size change must reallocate it.
- Device enumeration that works on Linux: `src/audio/devices_c_api.zig`
  (`audio_enumerate_output_devices`, `audio_get_output_device_name(i)`,
  `audio_get_output_device_description(i)`, `..._is_default(i)`, and the
  `input` equivalents), backed by `pactl list sinks|sources short`.
  Caveats: `audio_init_devices(NULL)` must be called once first and no caller
  does so today; returned pointers are valid only until the next enumeration.
- `system_get_output_device_name` / `system_get_input_device_name` in
  `src/system/system_c_api.zig` are CoreAudio-only (they return "Unknown
  Output" on Linux). Do not use them for the dropdowns.
- Lists that already exist: `system_get_available_sample_rates()` returns
  `{uint32_t rates[8]; uint32_t count;}` (44100, 48000, 88200, 96000) and
  `system_get_available_buffer_sizes()` returns `{uint32_t sizes[8]; uint32_t
  count;}` (64, 128, 256, 512, 1024, 2048). Both come from `detect.detect()`
  in `src/system/detect.zig`.
- Input capture (`src/audio/capture_pulse.zig`, `PulseCapture.start`) opens the
  default source (`pa_simple_new(..., null /* dev */, ...)`).
- `write_state_snapshot()` in `src/ui/raven_app.c` fills `UiState`;
  `ui_state_format` in `src/ui/ui_state.c` writes one JSON line.
  `UI_STATE_JSON_CAPACITY` is 2048.
- Raven dialogs: `Rdialog_open(window, content, closed_cb, user_data)`,
  `Rdialog_close(widget, result)` (`vendor/raven/include/raven/raven_dialogs.h`).
  The window owns and deletes `content` on close; Escape closes with result 0.
  `RDialogClosedCallback` is `void (*)(Rid content, int result, void *user_data)`.

## 1. Engine C API

All in `src/audio/engine_c_api.zig`, `pub export ... callconv(.c)`, using the
existing `castEngine`/`castEngineConst`. All setters are UI-thread only.

Return codes shared by the setters:

| code | meaning |
| --- | --- |
| 0 | ok (including "already that value", which is a no-op) |
| -1 | null engine or null/invalid pointer argument |
| -2 | value not allowed (not in the available list, or name 128 bytes or longer) |
| -3 | backend cannot honour it (for example a named device on the `none` backend) |
| -4 | the backend could not be re-opened; the previous settings were restored and are still active |
| -5 | refused because a recording is in progress |

```c
int audio_engine_set_output_device(void *engine, const char *name);
int audio_engine_set_buffer_size(void *engine, uint32_t frames);
int audio_engine_set_sample_rate(void *engine, uint32_t rate);
int audio_engine_get_output_device(void *engine, char *out_buf, size_t len);
```

Additional getters the popout and snapshot need (same file):

```c
uint32_t audio_engine_get_buffer_size(void *engine);
int audio_engine_get_backend(void *engine, char *out_buf, size_t len);
int audio_engine_set_input_device(void *engine, const char *name);
int audio_engine_get_input_device(void *engine, char *out_buf, size_t len);
```

`audio_engine_get_sample_rate` already exists and stays as the rate getter.

### Semantics

1. `audio_engine_set_output_device(engine, name)`
   - `name` is an output device name from `audio_get_output_device_name`;
     `""` means the default sink (PulseAudio `dev = NULL`). NULL `name` is -1.
   - Returns -2 for a name of 128 bytes or longer, -5 if recording.
   - Procedure: remember `was_playing = engine.playing`; `engine.stop()`;
     build a new `Backend` from `BackendConfig` extended with a
     `device: []const u8 = ""` field and the current rate and buffer size; on
     success deinit the old backend, swap, call `connectBackend()`, and if
     `was_playing` call `engine.start()`. On failure keep the old backend,
     restart it only if `was_playing`, and return -4.
   - The new backend is built with the current backend's type name
     (`@tagName(engine.backend)`) as the preference, not
     `config.backend_preference`. With `"auto"`, `Backend.init` silently falls
     back to the silent `none` backend when a device fails to open, which would
     turn a typo into silence instead of an error.
   - `PulseAudioBackend` stores the name in a fixed `[128]u8` NUL-terminated
     field and passes it as the `dev` argument of `pa_simple_new` in
     `prepare()`. PipeWire must pass it as the stream target property; if that
     cannot be done, PipeWire returns -3 for a non-empty name rather than
     ignoring it. The `none` backend accepts only `""`. CoreAudio is out of
     scope on this Linux pass: non-empty returns -3.
   - Only a stop-and-restart if it was playing; a stopped engine stays stopped
     (`audio_engine_is_playing` is 0 before and after).

2. `audio_engine_set_buffer_size(engine, frames)`
   - Accepted only if `frames` appears in `detect.detect().buffer_sizes` (the
     same source as `system_get_available_buffer_sizes`); otherwise -2 and
     `engine.config.buffer_size` is unchanged.
   - Same stop, rebuild backend, swap, restart-if-playing procedure as above
     with the new `buffer_size`. This also reallocates the pulse
     `render_buffer`, which is why rebuilding the backend is used instead of
     patching a field. On success set `engine.config.buffer_size = frames`.

3. `audio_engine_set_sample_rate(engine, rate)`
   - Accepted only if `rate` appears in `detect.detect().sample_rates`;
     otherwise -2, value unchanged.
   - Same procedure. After the swap, set `engine.config.sample_rate = rate` and
     rescale the transport so the song stays at the same musical time:
     `position = position * new_rate / old_rate` (use u128 or f64 for the
     intermediate). Clips need no work: `AudioClip.read` in
     `src/audio/track.zig` already resamples when the clip rate differs from
     the output rate. Effects get the rate per `process` call.
   - Open item for the implementer to check and report: the rate used when the
     recording module is created (`recording_init(sample_rate)`) should follow
     the engine rate; if it is fixed at startup, document that recordings made
     after a rate change use the new rate only after the next restart, or fix it.

4. `audio_engine_get_output_device(engine, out_buf, len)`
   - Copies the current name (empty string for default) plus NUL into
     `out_buf`. Returns the name length (excluding NUL, >= 0). Returns -1 for a
     null engine or null `out_buf` or `len == 0`, and -2 if the name plus NUL
     does not fit (then `out_buf[0] = 0`).
   - `audio_engine_get_input_device` and `audio_engine_get_backend` follow the
     same contract. `get_backend` writes `@tagName(engine.backend)`
     (`pulseaudio`, `pipewire`, `coreaudio`, `none`).

5. `audio_engine_set_input_device(engine, name)` (needed for the input dropdown)
   - Same name rules as the output (`""` is the default source, 128-byte limit,
     -5 while recording). It does not touch the playback backend or transport.
   - Stored on the engine and forwarded to `capture_pulse.zig` through a new
     `device: ?[*:0]const u8` parameter of `PulseCapture.start` (replacing the
     `null` `dev` argument there); `Recording.start` reads the stored name when
     it starts a capture. Takes effect on the next recording start.

### Where the state lives

Add to `AudioEngine`: `output_device: [128]u8`, `input_device: [128]u8`
(both zero-filled meaning default). Add `device` to `BackendConfig`.

## 2. State snapshot

`src/ui/ui_state.h`: raise `UI_STATE_JSON_CAPACITY` from 2048 to 4096 (four
tracks plus a 127-byte device name with worst-case escaping would otherwise
risk overflow, which makes `ui_state_format` return -1 and the snapshot stop
updating). Add:

```c
#define UI_STATE_DEVICE_CAPACITY 128
#define UI_STATE_BACKEND_CAPACITY 32

typedef struct UiAudioState {
    char output_device[UI_STATE_DEVICE_CAPACITY];
    unsigned sample_rate;
    unsigned buffer_size;
    char backend[UI_STATE_BACKEND_CAPACITY];
} UiAudioState;
```

and a member `UiAudioState audio;` at the end of `UiState`.

`src/ui/ui_state.c`: after the tracks array, `ui_state_format` appends
`,"audio":{"output_device":<json string>,"sample_rate":<n>,"buffer_size":<n>,"backend":<json string>}`
before the closing `}`. Strings go through `cursor_put_json_string` (not
`cursor_printf`, whose pieces are capped at 256 bytes). Example:

```json
..."tracks":[...],"audio":{"output_device":"","sample_rate":48000,"buffer_size":512,"backend":"pulseaudio"}}
```

`write_state_snapshot()` in `src/ui/raven_app.c` fills it from
`audio_engine_get_output_device`, `audio_engine_get_sample_rate`,
`audio_engine_get_buffer_size`, `audio_engine_get_backend`, with the four
`extern` declarations added next to the existing ones. If a getter fails, leave
the zeroed default. The `seridian state` command and `docs/development/ui-harness.md`
should mention the new object.

## 3. Tests, written first

Write these before the implementation; they must fail to compile or fail on
first run, then pass.

### Zig: `src/audio/engine_c_api_test.zig`

Each test creates the engine with
`.{ .sample_rate = 48000, .buffer_size = 256, .backend_preference = "none" }`
so no audio server is needed, and calls the C API through `capi.*` with
`@ptrCast(&engine)` as the existing test does.

1. `"C API - invalid buffer size is rejected and old value kept"`: for each of
   0, 100, 300, 4096: `set_buffer_size` returns nonzero (expect -2);
   `audio_engine_get_buffer_size` is still 256 and `engine.config.buffer_size`
   is still 256.
2. `"C API - valid buffer size is reported by the getter"`: for each size in
   the available list (64..2048): returns 0, `audio_engine_get_buffer_size`
   equals it, `engine.config.buffer_size` equals it.
3. `"C API - invalid sample rate is rejected and old value kept"`: 0, 22050,
   192000 return -2; `audio_engine_get_sample_rate` still 48000.
4. `"C API - valid sample rate is reported and position is rescaled"`: set
   position to 48000, `set_sample_rate(96000)` returns 0, getter is 96000,
   `audio_engine_get_position` is 96000.
5. `"C API - settings change keeps the transport state"`: with the stopped
   engine, setters leave `audio_engine_is_playing` at 0; after
   `audio_engine_start` returns 0, `set_buffer_size(128)` returns 0 and
   `audio_engine_is_playing` is still 1; call `audio_engine_stop` at the end.
6. `"C API - output device"`: initial `get_output_device` returns length 0 and
   an empty string; `set_output_device("")` returns 0; `set_output_device("alsa_output.fake")`
   on the `none` backend returns -3 and the getter still returns empty; a
   128-byte name returns -2; a `len` of 1 for a non-empty name returns -2; a
   NULL name returns -1.
7. `"C API - input device"`: same as 6 for the input getter/setter.
8. `"C API - setters refuse while recording"`: if a recording can be started
   without hardware in a test, expect -5 for all four setters and unchanged
   values; if it cannot, state that in the test file and skip rather than fake it.
9. `"C API - backend name"`: `audio_engine_get_backend` writes `none` for this
   engine.

### C: `tests/ui/ui_state_test.c`

Extend `sample_state()` with `strcpy(state.audio.output_device, "alsa_output.\"x\"")`,
`sample_rate = 48000`, `buffer_size = 512`, `strcpy(state.audio.backend, "pulseaudio")`.

1. `test_format_writes_audio_object`: expects `"audio":{`, `"sample_rate":48000`,
   `"buffer_size":512`, `"backend":"pulseaudio"`, and the escaped device
   `"output_device":"alsa_output.\"x\""`.
2. `test_format_audio_default_device_is_empty_string`: zeroed audio state gives
   `"output_device":""`.
3. `test_format_fits_worst_case_audio`: 127-character device name made of
   quotes (escaped length doubles) with four tracks still formats (return > 0),
   proving the new capacity.
Register all three in `main` of that file (same way as the existing tests). The
file is already built by the `ui_test_files` list in `build.zig`.

Run: `export PATH=$HOME/.local/share/zig/dev738/zig-x86_64-linux-0.18.0-dev.738+ae9a8acc7:$PATH`
then `zig build test`, and report the output verbatim.

## 4. Settings popout (`src/ui/raven_app.c`)

Header: in `build_header()` add, between Open session and Save (or after Save),
`add_button(row, "Settings", on_open_settings, NULL, R_BUTTON_FLAT)` with tooltip
"Audio devices, sample rate and buffer size".

State: a file-static `settings` struct holding the combo Rids (`output`,
`input`, `rate`, `buffer`), the backend label Rid, and parallel arrays of the
raw device names for each device combo (item text is the human description;
the name is what the engine needs). Item 0 of each device combo is "System
default" with name `""`.

`on_open_settings` (does nothing if `Rwindow_has_dialog(app.window)`):

1. Once at startup (before the first open is fine) call `audio_init_devices(NULL)`.
   Declare in the `extern` block: `audio_init_devices`,
   `audio_enumerate_output_devices`, `audio_enumerate_input_devices`,
   `audio_get_output_device_name/description`, `audio_get_input_device_name/description`,
   the system list functions with matching `typedef struct { uint32_t rates[8]; uint32_t count; } SampleRateList;`
   and `BufferSizeList`, and the new engine functions.
2. Enumerate, copy the names and descriptions into the settings struct right
   away (the library pointers are invalidated by the next enumeration). Skip
   input sources whose name ends in `.monitor` (they are loopbacks of outputs,
   not microphones). If enumeration returns -1, show only "System default".
3. Build content with the existing `make_column`, `make_row`, `make_label`,
   `Rcombo_box_*` helpers: a title label "Audio settings"; four labelled rows
   (Output, Input, Sample rate, Buffer size); a read-only row "Backend" showing
   `audio_engine_get_backend`; and a button row with Cancel and Apply
   (`R_BUTTON_PRIMARY`). Sample-rate items are "44100 Hz" etc. and buffer items
   "256 samples (5.3 ms at current rate)" or simply "256", taken from the two
   system lists.
4. Preselect from the live engine: the output/input combos by matching the
   engine's current name (no match, select "System default"), the rate and
   buffer combos by matching the engine's current values.
5. `Rdialog_open(app.window, content, on_settings_closed, NULL)`.

Buttons: Cancel calls `Rdialog_close(button, 0)`. Apply calls
`Rdialog_close(button, 1)`. Escape closes with result 0 (Raven behaviour).

`on_settings_closed(content, result, user_data)`:

- `result != 1`: do nothing at all. No engine setter is called, so old values
  stay (this is the "Cancel keeps old values" requirement). Clear the
  settings struct's Rids.
- `result == 1`: read the four selections (still valid inside this callback),
  then for each value that differs from the live one, call in this order:
  buffer size, sample rate, output device, input device. Collect any nonzero
  return and show `set_status(...)` with which setting failed and the code
  ("Could not apply output device (-4); kept the previous device"). On all
  success show "Audio settings applied". Call `write_state_snapshot()` once at
  the end so the harness sees the new values immediately. Because the
  engine restarts the stream when playing, playback may glitch briefly; this
  is acceptable and not a bug.

Not in scope: persisting the chosen devices (`AudioConfig.input_device` and
`output_device` exist in `src/config/config.zig` but nothing reads them yet;
the existing `settings_set_sample_rate`/`settings_set_buffer_size` plus
`settings_save` can persist rate and buffer in a follow-up).

## 5. Acceptance checklist (to be run and reported verbatim by the implementer)

1. `zig build test` passes, including the nine Zig tests and three C tests above.
2. `zig build` builds `seridian-studio`.
3. Start the app per `docs/development/ui-harness.md` (`sh run.sh --x11`, with
   `PULSE_SERVER` set) and `seridian state`: the JSON contains
   `"audio":{"output_device":"","sample_rate":48000,"buffer_size":512,"backend":...}`.
4. Click Settings, choose buffer 128, Apply: `seridian state` shows
   `"buffer_size":128`. Reopen, choose 1024, Cancel: it still shows 128.
5. Start playback, change the output device in the popout, Apply: playback
   continues on the new sink (check with `pactl list sink-inputs short`), and
   `audio.output_device` equals the chosen name.
6. Attempt a rate or buffer value outside the lists via a unit test only (the
   dropdown cannot produce one); expect -2 and unchanged state.

Record the exact command output for each; do not mark an item passed without
having seen it.
