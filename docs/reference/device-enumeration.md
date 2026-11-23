# Audio Device Enumeration

## Overview

Audio device enumeration has been implemented for the DAW, allowing users to list and select specific audio input/output devices instead of only using the system default.

## Implementation

### Based on ~/changies Code

The implementation is based on the device enumeration approach from the `~/changies` codebase, which uses the `pactl` command-line tool to query PulseAudio/PipeWire devices.

### New Files

**`src/audio/devices.zig`** - Device enumeration module
- `DeviceType` - enum for input/output devices
- `AudioDevice` - struct representing a single audio device (name, description, index)
- `DeviceList` - managed list of devices with cleanup
- `enumerateDevices()` - enumerate devices using `pactl list {sinks|sources} short`
- `getDefaultDevice()` - get the default device using `pactl get-default-{sink|source}`

**`src/audio/list_devices.zig`** - Standalone demo program
- Can be run with: `zig run src/audio/list_devices.zig`
- Lists all available input and output devices
- Shows default devices

### Updated Files

**`src/audio/pulseaudio.zig`**
- Added `device_name: ?[:0]const u8` field to `PulseAudioBackend`
- Added `setDevice()` method to change the output device
- Updated `prepare()` to use selected device or null for default
- Updated `deinit()` to free device name

**`src/audio/pipewire.zig`**
- Added `device_name: ?[:0]const u8` field (stub backend)
- Added `setDevice()` method (stub implementation)
- Updated `deinit()` to free device name

**`src/audio/backend.zig`**
- Added `setDevice()` method to `Backend` union
- Dispatches to appropriate backend implementation

**`src/audio/engine.zig`**
- Added `setOutputDevice()` method to `AudioEngine`
- Forwards device selection to backend

**`src/audio/engine_c_api.zig`**
- Fixed `audio_engine_start()` to return `c_int` instead of `void`
- Returns 0 on success, -1 on error
- Replaced `@panic()` with proper error logging
- Added `const std = @import("std");` import

**`src/ui/main_window_gtk.h`**
- Updated `audio_engine_start()` declaration to return `int`

## How It Works

### Device Enumeration Process

1. **Execute pactl command**
   ```bash
   pactl list sinks short    # For output devices
   pactl list sources short  # For input devices
   ```

2. **Parse output** (format: `INDEX NAME DRIVER FORMAT STATE`)
   - Extract device index and name
   - Filter out monitor devices (`.monitor` suffix)
   - Skip internal devices like `changies_output`

3. **Return device list**
   - Each device has: name, description, index, is_default flag

4. **Get default device**
   ```bash
   pactl get-default-sink    # For output
   pactl get-default-source  # For input
   ```

### PulseAudio/PipeWire Compatibility

The implementation uses `pactl`, which works with both:
- **PulseAudio** - native support
- **PipeWire** - via `pipewire-pulse` compatibility layer

This means the same code works regardless of which audio server is running.

## Usage

### List Available Devices

```bash
zig run src/audio/list_devices.zig
```

Example output:
```
=== Audio Device Enumeration ===

Output Devices (Sinks):
------------------------------------------------------------
  [1] alsa_output.pci-0000_0b_00.3.iec958-stereo
      Index: 57
      Description: alsa_output.pci-0000_0b_00.3.iec958-stereo

  [2] alsa_output.usb-Focusrite_Scarlett_Solo_USB.HiFi__Line1__sink
      Index: 61
      Description: alsa_output.usb-Focusrite_Scarlett_Solo_USB.HiFi__Line1__sink

Default Output Device: alsa_output.usb-Focusrite_Scarlett_Solo_USB.HiFi__Line1__sink
```

### Programmatic Usage

```zig
const devices = @import("audio/devices.zig");

// Enumerate output devices
const outputs = try devices.enumerateDevices(allocator, .output);
defer outputs.deinit();

for (outputs.devices) |device| {
    std.debug.print("Device: {s} (index {})\n", .{ device.name, device.index });
}

// Get default device
const default_output = try devices.getDefaultDevice(allocator, .output);
defer allocator.free(default_output);
```

### Setting a Device

```zig
// In audio engine
try audio_engine.setOutputDevice("alsa_output.usb-Focusrite_Scarlett_Solo_USB.HiFi__Line1__sink");

// Device will be used on next backend restart
```

## Integration Points

### Current State

✅ **Implemented:**
- Device enumeration for PulseAudio/PipeWire
- Device selection in audio backend
- Proper memory management for device names
- Demo program to list devices

⚠️ **Partially Implemented:**
- Device names stored in settings (fields exist in `AudioSettings`)
- Backend supports device selection

❌ **Not Yet Implemented:**
- Settings UI for device selection dropdown
- Automatic backend restart when device changes
- Device change callbacks/notifications
- Pretty device descriptions (currently using raw names)
- Device availability monitoring

### Next Steps to Complete

1. **Settings UI Integration**
   - Add device dropdown to Audio settings panel
   - Populate dropdown with enumerated devices
   - Save/load selected device from settings

2. **Backend Reconnection**
   - Add `reconnect()` method to backends
   - Set atomic flag when device changes
   - Check flag in audio thread and reconnect

3. **Better Device Names**
   - Parse `pactl list sinks/sources` (not `short` version)
   - Extract human-readable descriptions
   - Example: "Focusrite Scarlett Solo USB" instead of "alsa_output.usb-Focusrite..."

4. **Device Monitoring**
   - Listen for PulseAudio/PipeWire device add/remove events
   - Update device list when hardware changes
   - Handle default device changes

## Code Quality

### Follows CLAUDE.md Standards

✅ **Error Handling**
- All errors properly propagated with `try`
- No ignored error unions
- `errdefer` used for cleanup

✅ **Memory Management**
- Explicit allocator passing
- `defer` for cleanup
- Device names properly freed in `deinit()`

✅ **No Panics**
- Removed `@panic()` from `audio_engine_start()`
- Returns error codes to C API instead

### Technical Notes

- Uses `std.ArrayListUnmanaged` for Zig 0.16 compatibility
- Null-terminated strings (`[:0]const u8`) for C API compatibility
- Device names are optional (null = use default device)
- PulseAudio Simple API used for device connection

## Testing

```bash
# Build the project
zig build

# List devices
zig run src/audio/list_devices.zig

# Run the DAW (currently uses default device)
zig build run
```

## Known Limitations

1. **No PipeWire native implementation** - Uses PulseAudio compatibility layer
2. **No device hotplug detection** - Static enumeration only
3. **Raw device names** - No pretty descriptions yet
4. **Output devices only** - Input device selection not exposed to UI
5. **Manual restart required** - No automatic reconnection on device change

## Future Enhancements

- [ ] Native PipeWire device enumeration (without pactl)
- [ ] Device descriptions from PulseAudio metadata
- [ ] Input device selection for recording
- [ ] Device sample rate/format capabilities query
- [ ] Automatic device switching on default device change
- [ ] Device monitoring thread for hotplug events
- [ ] Latency information per device
- [ ] Multi-device support (simultaneous input/output)
