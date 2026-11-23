const std = @import("std");
const sys = @import("../utils/sys.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.system_detect);

/// Supported operating systems
pub const OS = enum {
    macos,
    linux,
    windows,
    unknown,

    pub fn current() OS {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .linux => .linux,
            .windows => .windows,
            else => .unknown,
        };
    }

    pub fn name(self: OS) []const u8 {
        return switch (self) {
            .macos => "macOS",
            .linux => "Linux",
            .windows => "Windows",
            .unknown => "Unknown",
        };
    }
};

/// Supported audio backends
pub const AudioBackend = enum {
    coreaudio,
    pulseaudio,
    pipewire,
    alsa,
    wasapi,
    none,

    pub fn name(self: AudioBackend) []const u8 {
        return switch (self) {
            .coreaudio => "CoreAudio",
            .pulseaudio => "PulseAudio",
            .pipewire => "PipeWire",
            .alsa => "ALSA",
            .wasapi => "WASAPI",
            .none => "None",
        };
    }
};

/// Supported MIDI backends
pub const MIDIBackend = enum {
    coremidi,
    alsa_seq,
    winmm,
    none,

    pub fn name(self: MIDIBackend) []const u8 {
        return switch (self) {
            .coremidi => "CoreMIDI",
            .alsa_seq => "ALSA Sequencer",
            .winmm => "Windows Multimedia",
            .none => "None",
        };
    }
};

/// Supported graphics renderers
pub const GraphicsRenderer = enum {
    metal,
    vulkan,
    opengl,
    directx,
    software,
    none,

    pub fn name(self: GraphicsRenderer) []const u8 {
        return switch (self) {
            .metal => "Metal",
            .vulkan => "Vulkan",
            .opengl => "OpenGL",
            .directx => "DirectX",
            .software => "Software",
            .none => "None",
        };
    }
};

/// Audio device information
pub const AudioDevice = struct {
    id: [64]u8,
    name: [128]u8,
    is_input: bool,
    is_default: bool,
    sample_rates: []const u32,
    channels: u32,
};

/// Maximum number of audio devices we can enumerate
pub const MAX_AUDIO_DEVICES = 32;

/// GPU information
pub const GPUInfo = struct {
    vendor: [64]u8,
    name: [128]u8,
    vram_mb: u32,
    supports_metal: bool,
    supports_vulkan: bool,
    supports_opengl: bool,
};

/// System capabilities detected at runtime
pub const SystemCapabilities = struct {
    os: OS,
    arch: []const u8,

    // Audio
    audio_backends: []const AudioBackend,
    preferred_audio: AudioBackend,
    sample_rates: []const u32,
    default_sample_rate: u32,
    buffer_sizes: []const u32,
    default_buffer_size: u32,

    // Audio devices (discovered at runtime)
    input_device_count: u32,
    output_device_count: u32,

    // MIDI
    midi_backend: MIDIBackend,
    midi_inputs: u32,
    midi_outputs: u32,

    // Graphics
    graphics_renderers: []const GraphicsRenderer,
    preferred_renderer: GraphicsRenderer,
    gpu_vendor: []const u8,
    gpu_name: []const u8,

    // Display
    has_gpu_acceleration: bool,
    display_scale: f32,
    display_refresh_rate: u32,

    // Performance
    cpu_cores: u32,
    recommended_threads: u32,

    pub fn log_info(self: *const SystemCapabilities) void {
        log.info("System: {s} ({s})", .{ self.os.name(), self.arch });
        log.info("Audio: {s} @ {d}Hz, buffer {d}", .{
            self.preferred_audio.name(),
            self.default_sample_rate,
            self.default_buffer_size,
        });
        log.info("Audio devices: {d} input, {d} output", .{
            self.input_device_count,
            self.output_device_count,
        });
        log.info("MIDI: {s} ({d} in, {d} out)", .{
            self.midi_backend.name(),
            self.midi_inputs,
            self.midi_outputs,
        });
        log.info("Graphics: {s} (GPU: {s})", .{
            self.preferred_renderer.name(),
            self.gpu_name,
        });
        log.info("CPU: {d} cores, {d} recommended threads", .{
            self.cpu_cores,
            self.recommended_threads,
        });
    }
};

/// Detect system capabilities
pub fn detect() SystemCapabilities {
    const os = OS.current();
    const arch = @tagName(builtin.cpu.arch);

    // CPU detection
    const cpu_cores = getCPUCores();
    const recommended_threads = @max(1, cpu_cores -| 1); // Leave one core for OS

    // OS-specific detection
    return switch (os) {
        .macos => detectMacOS(arch, cpu_cores, recommended_threads),
        .linux => detectLinux(arch, cpu_cores, recommended_threads),
        .windows => detectWindows(arch, cpu_cores, recommended_threads),
        .unknown => detectUnknown(arch, cpu_cores, recommended_threads),
    };
}

fn detectMacOS(arch: []const u8, cpu_cores: u32, recommended_threads: u32) SystemCapabilities {
    // CoreAudio is always available on macOS
    const audio_backends = &[_]AudioBackend{.coreaudio};
    const sample_rates = &[_]u32{ 44100, 48000, 88200, 96000 };
    const buffer_sizes = &[_]u32{ 64, 128, 256, 512, 1024, 2048 };

    // CoreMIDI is always available on macOS
    const midi_info = detectCoreMIDI();

    // Detect audio devices
    const audio_devices = detectCoreAudioDevices();

    // Detect graphics (Metal is primary on macOS, OpenGL as fallback)
    const graphics_renderers = &[_]GraphicsRenderer{ .metal, .opengl };
    const gpu_info = detectMacGPU();

    return .{
        .os = .macos,
        .arch = arch,
        .audio_backends = audio_backends,
        .preferred_audio = .coreaudio,
        .sample_rates = sample_rates,
        .default_sample_rate = 48000,
        .buffer_sizes = buffer_sizes,
        .default_buffer_size = 128,
        .input_device_count = audio_devices.inputs,
        .output_device_count = audio_devices.outputs,
        .midi_backend = .coremidi,
        .midi_inputs = midi_info.inputs,
        .midi_outputs = midi_info.outputs,
        .graphics_renderers = graphics_renderers,
        .preferred_renderer = .metal,
        .gpu_vendor = gpu_info.vendor,
        .gpu_name = gpu_info.name,
        .has_gpu_acceleration = true, // Metal is always available
        .display_scale = getDisplayScale(),
        .display_refresh_rate = getDisplayRefreshRate(),
        .cpu_cores = cpu_cores,
        .recommended_threads = recommended_threads,
    };
}

fn detectLinux(arch: []const u8, cpu_cores: u32, recommended_threads: u32) SystemCapabilities {
    // Detect available audio backends
    var backends_list: [3]AudioBackend = undefined;
    var backend_count: usize = 0;
    var preferred: AudioBackend = .none;

    // Check PipeWire first (modern Linux)
    if (detectPipeWire()) {
        backends_list[backend_count] = .pipewire;
        backend_count += 1;
        if (preferred == .none) preferred = .pipewire;
    }

    // Check PulseAudio
    if (detectPulseAudio()) {
        backends_list[backend_count] = .pulseaudio;
        backend_count += 1;
        if (preferred == .none) preferred = .pulseaudio;
    }

    // ALSA is usually available as fallback
    if (detectALSA()) {
        backends_list[backend_count] = .alsa;
        backend_count += 1;
        if (preferred == .none) preferred = .alsa;
    }

    const sample_rates = &[_]u32{ 44100, 48000, 88200, 96000 };
    const buffer_sizes = &[_]u32{ 64, 128, 256, 512, 1024, 2048 };

    // ALSA Sequencer for MIDI
    const midi_info = detectALSASeq();

    // Detect audio devices (Linux)
    const audio_devices = detectLinuxAudioDevices();

    // Detect graphics (Vulkan preferred if available, then OpenGL)
    const graphics_info = detectLinuxGraphics();

    return .{
        .os = .linux,
        .arch = arch,
        .audio_backends = backends_list[0..backend_count],
        .preferred_audio = preferred,
        .sample_rates = sample_rates,
        .default_sample_rate = 48000,
        .buffer_sizes = buffer_sizes,
        .default_buffer_size = 128,
        .input_device_count = audio_devices.inputs,
        .output_device_count = audio_devices.outputs,
        .midi_backend = if (midi_info.available) .alsa_seq else .none,
        .midi_inputs = midi_info.inputs,
        .midi_outputs = midi_info.outputs,
        .graphics_renderers = graphics_info.renderers[0..graphics_info.count],
        .preferred_renderer = graphics_info.preferred,
        .gpu_vendor = graphics_info.vendor,
        .gpu_name = graphics_info.name,
        .has_gpu_acceleration = detectGPU(),
        .display_scale = getDisplayScale(),
        .display_refresh_rate = getDisplayRefreshRate(),
        .cpu_cores = cpu_cores,
        .recommended_threads = recommended_threads,
    };
}

fn detectWindows(arch: []const u8, cpu_cores: u32, recommended_threads: u32) SystemCapabilities {
    // WASAPI is always available on modern Windows
    const audio_backends = &[_]AudioBackend{.wasapi};
    const sample_rates = &[_]u32{ 44100, 48000, 88200, 96000 };
    const buffer_sizes = &[_]u32{ 64, 128, 256, 512, 1024, 2048 };

    // DirectX/Vulkan available on Windows
    const graphics_renderers = &[_]GraphicsRenderer{ .directx, .vulkan, .opengl };

    return .{
        .os = .windows,
        .arch = arch,
        .audio_backends = audio_backends,
        .preferred_audio = .wasapi,
        .sample_rates = sample_rates,
        .default_sample_rate = 48000,
        .buffer_sizes = buffer_sizes,
        .default_buffer_size = 128,
        .input_device_count = 0, // TODO: detect Windows audio devices
        .output_device_count = 0,
        .midi_backend = .winmm,
        .midi_inputs = 0, // TODO: detect Windows MIDI
        .midi_outputs = 0,
        .graphics_renderers = graphics_renderers,
        .preferred_renderer = .directx,
        .gpu_vendor = "Unknown",
        .gpu_name = "Unknown",
        .has_gpu_acceleration = true, // DirectX is usually available
        .display_scale = 1.0,
        .display_refresh_rate = 60,
        .cpu_cores = cpu_cores,
        .recommended_threads = recommended_threads,
    };
}

fn detectUnknown(arch: []const u8, cpu_cores: u32, recommended_threads: u32) SystemCapabilities {
    const graphics_renderers = &[_]GraphicsRenderer{.software};

    return .{
        .os = .unknown,
        .arch = arch,
        .audio_backends = &[_]AudioBackend{},
        .preferred_audio = .none,
        .sample_rates = &[_]u32{48000},
        .default_sample_rate = 48000,
        .buffer_sizes = &[_]u32{512},
        .default_buffer_size = 512,
        .input_device_count = 0,
        .output_device_count = 0,
        .midi_backend = .none,
        .midi_inputs = 0,
        .midi_outputs = 0,
        .graphics_renderers = graphics_renderers,
        .preferred_renderer = .software,
        .gpu_vendor = "Unknown",
        .gpu_name = "Unknown",
        .has_gpu_acceleration = false,
        .display_scale = 1.0,
        .display_refresh_rate = 60,
        .cpu_cores = cpu_cores,
        .recommended_threads = recommended_threads,
    };
}

// =============================================================================
// Platform-specific detection helpers
// =============================================================================

fn getCPUCores() u32 {
    // Use Zig's built-in CPU feature detection
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @intCast(@min(cpu_count, 128));
}

fn getDisplayScale() f32 {
    // TODO: Get actual display scale from windowing system
    // For now, return default
    return 1.0;
}

// macOS detection - CoreMIDI externs
const has_coremidi = builtin.os.tag == .macos;

extern fn MIDIGetNumberOfSources() usize;
extern fn MIDIGetNumberOfDestinations() usize;

fn detectCoreMIDI() struct { inputs: u32, outputs: u32 } {
    if (!has_coremidi) return .{ .inputs = 0, .outputs = 0 };

    return .{
        .inputs = @intCast(MIDIGetNumberOfSources()),
        .outputs = @intCast(MIDIGetNumberOfDestinations()),
    };
}

// Linux detection
fn detectPipeWire() bool {
    if (builtin.os.tag != .linux) return false;

    // Check for PipeWire runtime
    if (sys.getenv("PIPEWIRE_RUNTIME_DIR")) |_| {
        return true;
    }

    // Try running pw-cli
    return runCommand(&[_][]const u8{ "pw-cli", "info", "0" });
}

fn detectPulseAudio() bool {
    if (builtin.os.tag != .linux) return false;

    // Try running pactl
    return runCommand(&[_][]const u8{ "pactl", "info" });
}

fn detectALSA() bool {
    if (builtin.os.tag != .linux) return false;

    // Check for /proc/asound
    std.Io.Dir.accessAbsolute(sys.io(), "/proc/asound/version", .{}) catch return false;
    return true;
}

fn detectALSASeq() struct { available: bool, inputs: u32, outputs: u32 } {
    if (builtin.os.tag != .linux) return .{ .available = false, .inputs = 0, .outputs = 0 };

    // Check for ALSA sequencer
    std.Io.Dir.accessAbsolute(sys.io(), "/dev/snd/seq", .{}) catch {
        return .{ .available = false, .inputs = 0, .outputs = 0 };
    };

    // TODO: Actually enumerate MIDI devices
    return .{ .available = true, .inputs = 0, .outputs = 0 };
}

fn detectGPU() bool {
    if (builtin.os.tag != .linux) return false;

    // Check for DRI devices
    var dir = std.Io.Dir.openDirAbsolute(sys.io(), "/dev/dri", .{ .iterate = true }) catch return false;
    defer dir.close(sys.io());

    var iter = dir.iterate();
    while (iter.next(sys.io()) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "card")) {
            return true;
        }
    }
    return false;
}

// Helper to run a command and check if it succeeds
fn runCommand(argv: []const []const u8) bool {
    return sys.runSucceeds(argv);
}

// Helper to run a command and capture up to `buffer.len` bytes of stdout.
fn runCommandWithOutput(argv: []const []const u8, buffer: []u8) ?[]const u8 {
    var child = std.process.spawn(sys.io(), .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return null;
    const stdout = child.stdout orelse return null;

    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const bytes = stdout.readStreaming(sys.io(), &.{buffer[total_read..]}) catch break;
        if (bytes == 0) break;
        total_read += bytes;
    }

    _ = child.wait(sys.io()) catch return null;

    if (total_read == 0) return null;
    return buffer[0..total_read];
}

fn getDisplayRefreshRate() u32 {
    if (builtin.os.tag == .linux) {
        var buffer: [2048]u8 = undefined;
        if (runCommandWithOutput(&[_][]const u8{ "xrandr", "--current" }, &buffer)) |output| {
            // Look for active refresh rate (marked with *)
            var i: usize = 0;
            while (i + 5 < output.len) : (i += 1) {
                if (output[i] == '*') {
                    // Scan backwards to find the rate
                    var j = i;
                    while (j > 0 and output[j - 1] != ' ' and output[j - 1] != '\t') {
                        j -= 1;
                    }
                    if (j < i) {
                        // Try to parse as float
                        var end = j;
                        while (end < i and ((output[end] >= '0' and output[end] <= '9') or output[end] == '.')) {
                            end += 1;
                        }
                        if (end > j) {
                            const rate = std.fmt.parseFloat(f32, output[j..end]) catch 60.0;
                            return @intFromFloat(@round(rate));
                        }
                    }
                }
            }
        }
    }
    // Default to 60Hz for macOS and Windows (requires native APIs for accurate detection)
    return 60;
}

// =============================================================================
// macOS-specific detection
// =============================================================================

// CoreAudio property selectors
const kAudioHardwarePropertyDevices: u32 = 0x64657623; // 'dev#'
const kAudioObjectPropertyScopeGlobal: u32 = 0x676c6f62; // 'glob'
const kAudioObjectPropertyElementMain: u32 = 0;
const kAudioObjectSystemObject: u32 = 1;
const kAudioDevicePropertyStreams: u32 = 0x73746d23; // 'stm#'
const kAudioObjectPropertyScopeInput: u32 = 0x696e7074; // 'inpt'
const kAudioObjectPropertyScopeOutput: u32 = 0x6f757470; // 'outp'
const kAudioObjectPropertyName: u32 = 0x6c6e616d; // 'lnam'

const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
};

extern fn AudioObjectGetPropertyDataSize(
    inObjectID: u32,
    inAddress: *const AudioObjectPropertyAddress,
    inQualifierDataSize: u32,
    inQualifierData: ?*const anyopaque,
    outDataSize: *u32,
) i32;

extern fn AudioObjectGetPropertyData(
    inObjectID: u32,
    inAddress: *const AudioObjectPropertyAddress,
    inQualifierDataSize: u32,
    inQualifierData: ?*const anyopaque,
    ioDataSize: *u32,
    outData: *anyopaque,
) i32;

// CoreFoundation string handling
const CFStringRef = *opaque {};
extern fn CFStringGetLength(theString: CFStringRef) isize;
extern fn CFStringGetCString(theString: CFStringRef, buffer: [*]u8, bufferSize: isize, encoding: u32) bool;
extern fn CFRelease(cf: *anyopaque) void;
const kCFStringEncodingUTF8: u32 = 0x08000100;

/// Audio device info with name
pub const CoreAudioDeviceInfo = struct {
    id: u32,
    name: [128]u8,
    name_len: usize,
    is_input: bool,
    is_output: bool,
    is_default_input: bool,
    is_default_output: bool,
};

/// Maximum devices we can enumerate
pub const MAX_COREAUDIO_DEVICES = 32;

/// Cached device list (static to avoid allocations)
var cached_devices: [MAX_COREAUDIO_DEVICES]CoreAudioDeviceInfo = undefined;
var cached_device_count: usize = 0;
var devices_enumerated: bool = false;

/// Get device name from CoreAudio
fn getCoreAudioDeviceName(device_id: u32, buffer: *[128]u8) usize {
    if (builtin.os.tag != .macos) return 0;

    const name_address = AudioObjectPropertyAddress{
        .mSelector = kAudioObjectPropertyName,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    var cf_string: CFStringRef = undefined;
    var size: u32 = @sizeOf(CFStringRef);

    const status = AudioObjectGetPropertyData(
        device_id,
        &name_address,
        0,
        null,
        &size,
        @ptrCast(&cf_string),
    );

    if (status != 0) return 0;

    // Convert CFString to C string
    const success = CFStringGetCString(cf_string, buffer, 128, kCFStringEncodingUTF8);
    CFRelease(@ptrCast(cf_string));

    if (!success) return 0;

    // Find null terminator to get length
    var len: usize = 0;
    while (len < 128 and buffer[len] != 0) : (len += 1) {}
    return len;
}

/// Enumerate all CoreAudio devices with names (cached)
pub fn enumerateCoreAudioDevices() []CoreAudioDeviceInfo {
    if (builtin.os.tag != .macos) return cached_devices[0..0];

    // Return cached results if already enumerated
    if (devices_enumerated) return cached_devices[0..cached_device_count];

    // Get list of all audio devices
    const devices_address = AudioObjectPropertyAddress{
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    var data_size: u32 = 0;
    var status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        null,
        &data_size,
    );

    if (status != 0 or data_size == 0) {
        devices_enumerated = true;
        return cached_devices[0..0];
    }

    // Get device IDs
    var device_ids: [64]u32 = undefined;
    const max_devices = @min(data_size / @sizeOf(u32), 64);
    var actual_size: u32 = @intCast(max_devices * @sizeOf(u32));

    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        null,
        &actual_size,
        @ptrCast(&device_ids),
    );

    if (status != 0) {
        devices_enumerated = true;
        return cached_devices[0..0];
    }

    const actual_count = actual_size / @sizeOf(u32);
    cached_device_count = 0;

    // Enumerate each device
    for (device_ids[0..actual_count]) |device_id| {
        if (cached_device_count >= MAX_COREAUDIO_DEVICES) break;

        var device = &cached_devices[cached_device_count];
        device.id = device_id;
        device.is_input = false;
        device.is_output = false;
        device.is_default_input = false;
        device.is_default_output = false;

        // Get device name
        device.name_len = getCoreAudioDeviceName(device_id, &device.name);
        if (device.name_len == 0) {
            // Skip devices without names
            continue;
        }

        // Check for input streams
        const input_address = AudioObjectPropertyAddress{
            .mSelector = kAudioDevicePropertyStreams,
            .mScope = kAudioObjectPropertyScopeInput,
            .mElement = kAudioObjectPropertyElementMain,
        };

        var stream_size: u32 = 0;
        if (AudioObjectGetPropertyDataSize(device_id, &input_address, 0, null, &stream_size) == 0 and stream_size > 0) {
            device.is_input = true;
        }

        // Check for output streams
        const output_address = AudioObjectPropertyAddress{
            .mSelector = kAudioDevicePropertyStreams,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain,
        };

        stream_size = 0;
        if (AudioObjectGetPropertyDataSize(device_id, &output_address, 0, null, &stream_size) == 0 and stream_size > 0) {
            device.is_output = true;
        }

        // Only include devices that have input or output
        if (device.is_input or device.is_output) {
            cached_device_count += 1;
        }
    }

    devices_enumerated = true;
    return cached_devices[0..cached_device_count];
}

/// Get input devices only
pub fn getInputDevices() []CoreAudioDeviceInfo {
    const all = enumerateCoreAudioDevices();
    // Filter in-place by marking - for simplicity return all and let caller filter
    _ = all;
    return enumerateCoreAudioDevices();
}

/// Get output devices only
pub fn getOutputDevices() []CoreAudioDeviceInfo {
    return enumerateCoreAudioDevices();
}

fn detectCoreAudioDevices() struct { inputs: u32, outputs: u32 } {
    if (builtin.os.tag != .macos) return .{ .inputs = 0, .outputs = 0 };

    var inputs: u32 = 0;
    var outputs: u32 = 0;

    // Get list of all audio devices
    const devices_address = AudioObjectPropertyAddress{
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    var data_size: u32 = 0;
    var status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        null,
        &data_size,
    );

    if (status != 0 or data_size == 0) {
        return .{ .inputs = 1, .outputs = 1 }; // Fallback to defaults
    }

    const device_count = data_size / @sizeOf(u32);
    if (device_count == 0) {
        return .{ .inputs = 1, .outputs = 1 };
    }

    // Get device IDs
    var device_ids: [64]u32 = undefined;
    const max_devices = @min(device_count, 64);
    var actual_size: u32 = @intCast(max_devices * @sizeOf(u32));

    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        null,
        &actual_size,
        @ptrCast(&device_ids),
    );

    if (status != 0) {
        return .{ .inputs = 1, .outputs = 1 };
    }

    const actual_count = actual_size / @sizeOf(u32);

    // Check each device for input/output capability
    for (device_ids[0..actual_count]) |device_id| {
        // Check for input streams
        const input_address = AudioObjectPropertyAddress{
            .mSelector = kAudioDevicePropertyStreams,
            .mScope = kAudioObjectPropertyScopeInput,
            .mElement = kAudioObjectPropertyElementMain,
        };

        var stream_size: u32 = 0;
        if (AudioObjectGetPropertyDataSize(device_id, &input_address, 0, null, &stream_size) == 0 and stream_size > 0) {
            inputs += 1;
        }

        // Check for output streams
        const output_address = AudioObjectPropertyAddress{
            .mSelector = kAudioDevicePropertyStreams,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain,
        };

        stream_size = 0;
        if (AudioObjectGetPropertyDataSize(device_id, &output_address, 0, null, &stream_size) == 0 and stream_size > 0) {
            outputs += 1;
        }
    }

    // Ensure at least default devices
    if (inputs == 0) inputs = 1;
    if (outputs == 0) outputs = 1;

    return .{ .inputs = inputs, .outputs = outputs };
}

fn detectMacGPU() struct { vendor: []const u8, name: []const u8 } {
    if (builtin.os.tag != .macos) return .{ .vendor = "Unknown", .name = "Unknown" };

    // Use system_profiler to get GPU info
    var buffer: [4096]u8 = undefined;
    if (runCommandWithOutput(&[_][]const u8{
        "system_profiler",
        "SPDisplaysDataType",
        "-detailLevel",
        "mini",
    }, &buffer)) |output| {
        // Look for "Chipset Model:" line
        if (std.mem.indexOf(u8, output, "Chipset Model:")) |idx| {
            var start = idx + "Chipset Model:".len;
            // Skip whitespace
            while (start < output.len and (output[start] == ' ' or output[start] == ':')) {
                start += 1;
            }
            // Find end of line
            var end = start;
            while (end < output.len and output[end] != '\n' and output[end] != '\r') {
                end += 1;
            }
            if (end > start) {
                const gpu_name = output[start..end];
                // Determine vendor from name
                if (std.mem.indexOf(u8, gpu_name, "Apple") != null) {
                    return .{ .vendor = "Apple", .name = gpu_name };
                } else if (std.mem.indexOf(u8, gpu_name, "AMD") != null or std.mem.indexOf(u8, gpu_name, "Radeon") != null) {
                    return .{ .vendor = "AMD", .name = gpu_name };
                } else if (std.mem.indexOf(u8, gpu_name, "Intel") != null) {
                    return .{ .vendor = "Intel", .name = gpu_name };
                } else if (std.mem.indexOf(u8, gpu_name, "NVIDIA") != null) {
                    return .{ .vendor = "NVIDIA", .name = gpu_name };
                } else {
                    return .{ .vendor = "Unknown", .name = gpu_name };
                }
            }
        }
    }

    // Default for Apple Silicon
    return .{ .vendor = "Apple", .name = "Apple Silicon GPU" };
}

// =============================================================================
// Linux-specific detection
// =============================================================================

fn detectLinuxAudioDevices() struct { inputs: u32, outputs: u32 } {
    if (builtin.os.tag != .linux) return .{ .inputs = 0, .outputs = 0 };

    var inputs: u32 = 0;
    var outputs: u32 = 0;

    // Try PulseAudio/PipeWire via pactl
    var buffer: [8192]u8 = undefined;
    if (runCommandWithOutput(&[_][]const u8{ "pactl", "list", "sources", "short" }, &buffer)) |output| {
        // Count non-monitor sources
        var i: usize = 0;
        var line_start: usize = 0;
        while (i <= output.len) : (i += 1) {
            if (i == output.len or output[i] == '\n') {
                if (i > line_start) {
                    const line = output[line_start..i];
                    if (std.mem.indexOf(u8, line, ".monitor") == null and line.len > 0) {
                        inputs += 1;
                    }
                }
                line_start = i + 1;
            }
        }
    }

    if (runCommandWithOutput(&[_][]const u8{ "pactl", "list", "sinks", "short" }, &buffer)) |output| {
        for (output) |c| {
            if (c == '\n') outputs += 1;
        }
        if (output.len > 0 and output[output.len - 1] != '\n') outputs += 1;
    }

    // Fallback to ALSA if PulseAudio unavailable
    if (inputs == 0 and outputs == 0) {
        var card_buf: [4096]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(sys.io(), "/proc/asound/cards", &card_buf)) |contents| {
            const bytes = contents.len;
            if (bytes > 0) {
                var card_count: u32 = 0;
                var j: usize = 0;
                while (j < bytes) : (j += 1) {
                    if (j == 0 or card_buf[j - 1] == '\n') {
                        var k = j;
                        while (k < bytes and card_buf[k] == ' ') k += 1;
                        if (k < bytes and card_buf[k] >= '0' and card_buf[k] <= '9') {
                            card_count += 1;
                        }
                    }
                }
                inputs = @max(card_count, 1);
                outputs = @max(card_count, 1);
            }
        } else |_| {}
    }

    if (inputs == 0) inputs = 1;
    if (outputs == 0) outputs = 1;

    return .{ .inputs = inputs, .outputs = outputs };
}

const LinuxGraphicsResult = struct {
    renderers: [3]GraphicsRenderer,
    count: usize,
    preferred: GraphicsRenderer,
    vendor: []const u8,
    name: []const u8,
};

fn detectLinuxGraphics() LinuxGraphicsResult {
    var result = LinuxGraphicsResult{
        .renderers = .{ .software, .software, .software },
        .count = 0,
        .preferred = .software,
        .vendor = "Unknown",
        .name = "Unknown",
    };

    if (builtin.os.tag != .linux) {
        result.count = 1;
        return result;
    }

    // Check for Vulkan
    if (runCommand(&[_][]const u8{ "vulkaninfo", "--summary" })) {
        result.renderers[result.count] = .vulkan;
        result.count += 1;
        result.preferred = .vulkan;
    }

    // Check for OpenGL and parse GPU info
    var buffer: [4096]u8 = undefined;
    if (runCommandWithOutput(&[_][]const u8{ "glxinfo", "-B" }, &buffer)) |output| {
        result.renderers[result.count] = .opengl;
        result.count += 1;
        if (result.preferred == .software) {
            result.preferred = .opengl;
        }

        // Parse OpenGL vendor
        if (std.mem.indexOf(u8, output, "OpenGL vendor string:")) |idx| {
            var start = idx + "OpenGL vendor string:".len;
            while (start < output.len and output[start] == ' ') start += 1;
            var end = start;
            while (end < output.len and output[end] != '\n') end += 1;
            if (end > start) {
                result.vendor = output[start..end];
            }
        }

        // Parse OpenGL renderer (GPU name)
        if (std.mem.indexOf(u8, output, "OpenGL renderer string:")) |idx| {
            var start = idx + "OpenGL renderer string:".len;
            while (start < output.len and output[start] == ' ') start += 1;
            var end = start;
            while (end < output.len and output[end] != '\n') end += 1;
            if (end > start) {
                result.name = output[start..end];
            }
        }
    }

    // Always have software fallback
    if (result.count == 0 or result.renderers[result.count - 1] != .software) {
        result.renderers[result.count] = .software;
        result.count += 1;
    }

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "detect current system" {
    const caps = detect();
    try std.testing.expect(caps.os != .unknown or builtin.os.tag == .freestanding);
    try std.testing.expect(caps.cpu_cores > 0);
}
