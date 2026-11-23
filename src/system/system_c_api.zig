//! C API for system detection
//! Exposes system capabilities to C code (GTK settings modal)

const std = @import("std");
const detect = @import("detect.zig");

// System info struct for C
pub const SystemInfo = extern struct {
    // OS info
    os_name: [32]u8,
    arch: [16]u8,

    // Audio
    audio_backend: [32]u8,
    sample_rate: u32,
    buffer_size: u32,

    // MIDI
    midi_backend: [32]u8,
    midi_inputs: u32,
    midi_outputs: u32,

    // Hardware
    cpu_cores: u32,
    recommended_threads: u32,
    has_gpu_acceleration: bool,
    display_scale: f32,
};

fn copyString(dest: []u8, src: []const u8) void {
    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
    dest[len] = 0;
}

/// Get system information for display in settings
export fn system_get_info() SystemInfo {
    const caps = detect.detect();

    var info = SystemInfo{
        .os_name = @as([32]u8, @splat(0)),
        .arch = @as([16]u8, @splat(0)),
        .audio_backend = @as([32]u8, @splat(0)),
        .sample_rate = caps.default_sample_rate,
        .buffer_size = caps.default_buffer_size,
        .midi_backend = @as([32]u8, @splat(0)),
        .midi_inputs = caps.midi_inputs,
        .midi_outputs = caps.midi_outputs,
        .cpu_cores = caps.cpu_cores,
        .recommended_threads = caps.recommended_threads,
        .has_gpu_acceleration = caps.has_gpu_acceleration,
        .display_scale = caps.display_scale,
    };

    copyString(&info.os_name, caps.os.name());
    copyString(&info.arch, caps.arch);
    copyString(&info.audio_backend, caps.preferred_audio.name());
    copyString(&info.midi_backend, caps.midi_backend.name());

    return info;
}

/// Get OS name as C string
export fn system_get_os_name() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.os.name().ptr);
}

/// Get preferred audio backend name
export fn system_get_audio_backend() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.preferred_audio.name().ptr);
}

/// Get MIDI backend name
export fn system_get_midi_backend() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.midi_backend.name().ptr);
}

/// Get CPU core count
export fn system_get_cpu_cores() u32 {
    const caps = detect.detect();
    return caps.cpu_cores;
}

/// Get recommended thread count
export fn system_get_recommended_threads() u32 {
    const caps = detect.detect();
    return caps.recommended_threads;
}

/// Get MIDI input count
export fn system_get_midi_inputs() u32 {
    const caps = detect.detect();
    return caps.midi_inputs;
}

/// Get MIDI output count
export fn system_get_midi_outputs() u32 {
    const caps = detect.detect();
    return caps.midi_outputs;
}

/// Check if GPU acceleration is available
export fn system_has_gpu_acceleration() bool {
    const caps = detect.detect();
    return caps.has_gpu_acceleration;
}

/// Get default sample rate
export fn system_get_default_sample_rate() u32 {
    const caps = detect.detect();
    return caps.default_sample_rate;
}

/// Get default buffer size
export fn system_get_default_buffer_size() u32 {
    const caps = detect.detect();
    return caps.default_buffer_size;
}

// =============================================================================
// Available backends - for settings dropdowns
// =============================================================================

const MAX_BACKENDS = 8;

/// Audio backend list for C
pub const AudioBackendList = extern struct {
    names: [MAX_BACKENDS][32]u8,
    count: u32,
};

/// Get list of available audio backends
export fn system_get_available_audio_backends() AudioBackendList {
    const caps = detect.detect();

    var list = AudioBackendList{
        .names = @as([MAX_BACKENDS][32]u8, @splat(@as([32]u8, @splat(0)))),
        .count = 0,
    };

    for (caps.audio_backends) |backend| {
        if (list.count >= MAX_BACKENDS) break;
        copyString(&list.names[list.count], backend.name());
        list.count += 1;
    }

    return list;
}

/// Get count of available audio backends
export fn system_get_audio_backend_count() u32 {
    const caps = detect.detect();
    return @intCast(caps.audio_backends.len);
}

/// Get audio backend name by index
export fn system_get_audio_backend_name(index: u32) [*:0]const u8 {
    const caps = detect.detect();
    if (index >= caps.audio_backends.len) {
        return "Unknown";
    }
    return @ptrCast(caps.audio_backends[index].name().ptr);
}

/// Sample rate list for C
pub const SampleRateList = extern struct {
    rates: [8]u32,
    count: u32,
};

/// Get list of available sample rates
export fn system_get_available_sample_rates() SampleRateList {
    const caps = detect.detect();

    var list = SampleRateList{
        .rates = @as([8]u32, @splat(0)),
        .count = 0,
    };

    for (caps.sample_rates) |rate| {
        if (list.count >= 8) break;
        list.rates[list.count] = rate;
        list.count += 1;
    }

    return list;
}

/// Buffer size list for C
pub const BufferSizeList = extern struct {
    sizes: [8]u32,
    count: u32,
};

/// Get list of available buffer sizes
export fn system_get_available_buffer_sizes() BufferSizeList {
    const caps = detect.detect();

    var list = BufferSizeList{
        .sizes = @as([8]u32, @splat(0)),
        .count = 0,
    };

    for (caps.buffer_sizes) |size| {
        if (list.count >= 8) break;
        list.sizes[list.count] = size;
        list.count += 1;
    }

    return list;
}

// =============================================================================
// Graphics renderer API
// =============================================================================

const MAX_RENDERERS = 4;

/// Graphics renderer list for C
pub const GraphicsRendererList = extern struct {
    names: [MAX_RENDERERS][32]u8,
    count: u32,
};

/// Get list of available graphics renderers
export fn system_get_available_renderers() GraphicsRendererList {
    const caps = detect.detect();

    var list = GraphicsRendererList{
        .names = @as([MAX_RENDERERS][32]u8, @splat(@as([32]u8, @splat(0)))),
        .count = 0,
    };

    for (caps.graphics_renderers) |renderer| {
        if (list.count >= MAX_RENDERERS) break;
        copyString(&list.names[list.count], renderer.name());
        list.count += 1;
    }

    return list;
}

/// Get preferred graphics renderer name
export fn system_get_preferred_renderer() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.preferred_renderer.name().ptr);
}

/// Get GPU vendor
export fn system_get_gpu_vendor() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.gpu_vendor.ptr);
}

/// Get GPU name
export fn system_get_gpu_name() [*:0]const u8 {
    const caps = detect.detect();
    return @ptrCast(caps.gpu_name.ptr);
}

/// Get display refresh rate
export fn system_get_display_refresh_rate() u32 {
    const caps = detect.detect();
    return caps.display_refresh_rate;
}

// =============================================================================
// Audio device enumeration
// =============================================================================

/// Get count of input devices
export fn system_get_input_device_count() u32 {
    const devices = detect.enumerateCoreAudioDevices();
    var count: u32 = 0;
    for (devices) |d| {
        if (d.is_input) count += 1;
    }
    return if (count > 0) count else 1; // At least 1 for "System Default"
}

/// Get count of output devices
export fn system_get_output_device_count() u32 {
    const devices = detect.enumerateCoreAudioDevices();
    var count: u32 = 0;
    for (devices) |d| {
        if (d.is_output) count += 1;
    }
    return if (count > 0) count else 1; // At least 1 for "System Default"
}

/// Get input device name by index (0 = first input device)
/// Returns pointer to static buffer, valid until next call
var input_name_buffer: [128]u8 = undefined;
export fn system_get_input_device_name(index: u32) [*:0]const u8 {
    const devices = detect.enumerateCoreAudioDevices();
    var input_idx: u32 = 0;
    for (devices) |d| {
        if (d.is_input) {
            if (input_idx == index) {
                // Copy name to buffer and null-terminate
                const len = @min(d.name_len, 127);
                @memcpy(input_name_buffer[0..len], d.name[0..len]);
                input_name_buffer[len] = 0;
                return @ptrCast(&input_name_buffer);
            }
            input_idx += 1;
        }
    }
    // Fallback
    const fallback = "Unknown Input";
    @memcpy(input_name_buffer[0..fallback.len], fallback);
    input_name_buffer[fallback.len] = 0;
    return @ptrCast(&input_name_buffer);
}

/// Get output device name by index (0 = first output device)
var output_name_buffer: [128]u8 = undefined;
export fn system_get_output_device_name(index: u32) [*:0]const u8 {
    const devices = detect.enumerateCoreAudioDevices();
    var output_idx: u32 = 0;
    for (devices) |d| {
        if (d.is_output) {
            if (output_idx == index) {
                // Copy name to buffer and null-terminate
                const len = @min(d.name_len, 127);
                @memcpy(output_name_buffer[0..len], d.name[0..len]);
                output_name_buffer[len] = 0;
                return @ptrCast(&output_name_buffer);
            }
            output_idx += 1;
        }
    }
    // Fallback
    const fallback = "Unknown Output";
    @memcpy(output_name_buffer[0..fallback.len], fallback);
    output_name_buffer[fallback.len] = 0;
    return @ptrCast(&output_name_buffer);
}
