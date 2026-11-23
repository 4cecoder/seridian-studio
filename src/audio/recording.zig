//! Audio Recording Module
//!
//! Captures audio from system input and creates clips on armed tracks.

const std = @import("std");
const builtin = @import("builtin");
const AudioEngine = @import("engine.zig").AudioEngine;
const Track = @import("track.zig").Track;
const Clip = @import("clip.zig").Clip;
const wav = @import("wav.zig");

// Platform-specific audio input: CoreAudio on macOS, PulseAudio/PipeWire on Linux.
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const coreaudio = if (is_macos) @import("coreaudio.zig") else struct {};
const capture_pulse = if (is_linux) @import("capture_pulse.zig") else struct {};

const log = std.log.scoped(.recording);

pub const RecordingState = enum(u8) {
    idle = 0,
    armed = 1,
    recording = 2,
    stopping = 3,
};

pub const Recording = struct {
    allocator: std.mem.Allocator,
    state: std.atomic.Value(RecordingState),

    // Recording buffer (circular)
    buffer: []f32,
    write_pos: std.atomic.Value(usize),
    buffer_size: usize,

    // Recording metadata
    start_time: f64,
    sample_rate: u32,
    samples_recorded: std.atomic.Value(u64),

    // Target track
    target_track: i32,

    // CoreAudio input unit (macOS)
    input_unit: if (is_macos) ?coreaudio.AudioComponentInstance else ?*anyopaque,
    // Capture thread (Linux)
    linux_capture: if (is_linux) ?*capture_pulse.PulseCapture else void,

    // Input format info (set during initialization)
    input_channels: u32,
    is_non_interleaved: bool,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) !*Recording {
        // Allocate 5 minutes of stereo audio buffer
        const buffer_seconds: usize = 300;
        const buffer_size = buffer_seconds * sample_rate * 2;

        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0.0);

        const rec = try allocator.create(Recording);
        rec.* = Recording{
            .allocator = allocator,
            .state = std.atomic.Value(RecordingState).init(.idle),
            .buffer = buffer,
            .write_pos = std.atomic.Value(usize).init(0),
            .buffer_size = buffer_size,
            .start_time = 0.0,
            .sample_rate = sample_rate,
            .samples_recorded = std.atomic.Value(u64).init(0),
            .target_track = 0,
            .input_unit = null,
            .linux_capture = if (is_linux) null else {},
            .input_channels = 1, // Will be updated during init
            .is_non_interleaved = false,
        };

        return rec;
    }

    pub fn deinit(self: *Recording) void {
        self.stop();
        // input_unit should already be null after stop(), but clean up just in case
        if (is_macos) {
            if (self.input_unit) |unit| {
                _ = coreaudio.os_api.AudioUnitUninitialize(unit);
                _ = coreaudio.os_api.AudioComponentInstanceDispose(unit);
                self.input_unit = null;
            }
        }
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    /// Start recording to specified track
    pub fn start(self: *Recording, track: i32, start_time: f64) !void {
        if (self.state.load(.monotonic) != .idle) {
            return error.AlreadyRecording;
        }

        self.target_track = track;
        self.start_time = start_time;
        self.write_pos.store(0, .monotonic);
        self.samples_recorded.store(0, .monotonic);

        // Reset callback counter for debugging
        g_callback_count = 0;

        if (is_macos) {
            // Initialize CoreAudio input if needed
            if (self.input_unit == null) {
                try self.initInputUnit();
            }

            // Start audio input
            const status = coreaudio.os_api.AudioOutputUnitStart(self.input_unit.?);
            if (status != coreaudio.noErr) {
                log.err("Failed to start audio input: {}", .{status});
                return error.AudioInputStartFailed;
            }
            self.state.store(.recording, .monotonic);
        } else if (is_linux) {
            // Mark recording first so the very first captured chunk is kept.
            self.state.store(.recording, .monotonic);
            const device: ?[*:0]const u8 = if (g_input_device[0] == 0) null else @ptrCast(&g_input_device);
            self.linux_capture = capture_pulse.PulseCapture.start(self.allocator, self.sample_rate, .{
                .context = self,
                .write = writeStereoSink,
            }, device) catch |err| {
                self.state.store(.idle, .monotonic);
                return err;
            };
        } else {
            return error.AudioInputUnsupported;
        }

        log.info("Recording started on track {} at {d:.2}s", .{ track, start_time });
    }

    /// Stop recording and create clip
    pub fn stop(self: *Recording) void {
        const state = self.state.load(.monotonic);
        if (state != .recording) return;

        self.state.store(.stopping, .monotonic);

        if (is_macos) {
            if (self.input_unit) |unit| {
                // Stop the audio unit
                _ = coreaudio.os_api.AudioOutputUnitStop(unit);
                // Uninitialize and dispose to fully release the audio device
                _ = coreaudio.os_api.AudioUnitUninitialize(unit);
                _ = coreaudio.os_api.AudioComponentInstanceDispose(unit);
                self.input_unit = null;
                log.info("Released audio input unit", .{});
            }
        } else if (is_linux) {
            if (self.linux_capture) |capture| {
                capture.stop(self.allocator);
                self.linux_capture = null;
            }
        }

        self.state.store(.idle, .monotonic);
        log.info("Recording stopped: {} samples", .{self.samples_recorded.load(.monotonic)});
    }

    /// Append interleaved stereo samples while recording; drops what no
    /// longer fits in the (5 minute) buffer.
    pub fn appendStereo(self: *Recording, stereo: []const f32) void {
        if (self.state.load(.monotonic) != .recording) return;
        const write_pos = self.write_pos.load(.monotonic);
        const count = @min(stereo.len - stereo.len % 2, self.buffer_size - write_pos);
        if (count == 0) return;
        @memcpy(self.buffer[write_pos..][0..count], stereo[0..count]);
        self.write_pos.store(write_pos + count, .monotonic);
        _ = self.samples_recorded.fetchAdd(count, .monotonic);
    }

    fn writeStereoSink(context: *anyopaque, stereo: []const f32) void {
        const self: *Recording = @ptrCast(@alignCast(context));
        self.appendStereo(stereo);
    }

    /// Get recorded audio data
    pub fn getRecordedData(self: *Recording) []const f32 {
        const samples = self.samples_recorded.load(.monotonic);
        if (samples == 0) return &[_]f32{};

        const len = @min(samples, self.buffer_size);
        return self.buffer[0..len];
    }

    /// Get recording duration in seconds
    pub fn getDuration(self: *Recording) f64 {
        const samples = self.samples_recorded.load(.monotonic);
        return @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(self.sample_rate)) / 2.0;
    }

    /// Save recorded audio to WAV file
    pub fn saveToFile(self: *Recording, path: []const u8) !void {
        const data = self.getRecordedData();
        if (data.len == 0) return error.NoDataToSave;

        var writer = try wav.WavWriter.create(path, self.sample_rate, 2, 16);
        errdefer writer.abort();

        try writer.writeSamples(data);
        try writer.close();

        log.info("Saved recording to: {s}", .{path});
    }

    fn initInputUnit(self: *Recording) !void {
        log.info("Initializing audio input unit...", .{});

        // Find default input component (HAL Output can do both input and output)
        var desc = coreaudio.AudioComponentDescription{
            .componentType = coreaudio.kAudioUnitType_Output,
            .componentSubType = coreaudio.kAudioUnitSubType_HALOutput,
            .componentManufacturer = coreaudio.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };

        const component = coreaudio.os_api.AudioComponentFindNext(null, &desc);
        if (component == null) {
            log.err("No audio input component found", .{});
            return error.NoInputDevice;
        }
        log.info("Found HAL output component", .{});

        var unit: ?coreaudio.AudioComponentInstance = null;
        var status = coreaudio.os_api.AudioComponentInstanceNew(component.?, &unit);
        if (unit == null or status != coreaudio.noErr) {
            log.err("Failed to create audio unit instance: {}", .{status});
            return error.InputUnitCreationFailed;
        }
        log.info("Created audio unit instance", .{});

        const audio_unit = unit.?;

        // CRITICAL: Enable input on Element 1 (input bus) BEFORE disabling output
        var enable_io: u32 = 1;
        status = coreaudio.os_api.AudioUnitSetProperty(
            audio_unit,
            coreaudio.kAudioOutputUnitProperty_EnableIO,
            coreaudio.kAudioUnitScope_Input,
            1, // Input element (bus 1)
            &enable_io,
            @sizeOf(u32),
        );
        if (status != coreaudio.noErr) {
            log.err("Failed to enable input IO: {} (microphone permissions?)", .{status});
            _ = coreaudio.os_api.AudioComponentInstanceDispose(audio_unit);
            return error.InputUnitInitFailed;
        }
        log.info("Enabled input IO on element 1", .{});

        // Disable output on Element 0 (output bus) - we only want input
        enable_io = 0;
        status = coreaudio.os_api.AudioUnitSetProperty(
            audio_unit,
            coreaudio.kAudioOutputUnitProperty_EnableIO,
            coreaudio.kAudioUnitScope_Output,
            0, // Output element (bus 0)
            &enable_io,
            @sizeOf(u32),
        );
        if (status != coreaudio.noErr) {
            log.warn("Failed to disable output IO: {} (non-fatal)", .{status});
        }

        // Set the default input device
        var default_device: u32 = 0;
        var prop_size: u32 = @sizeOf(u32);
        var prop_address = coreaudio.AudioObjectPropertyAddress{
            .mSelector = coreaudio.kAudioHardwarePropertyDefaultInputDevice,
            .mScope = coreaudio.kAudioObjectPropertyScopeGlobal,
            .mElement = coreaudio.kAudioObjectPropertyElementMain,
        };

        status = coreaudio.os_api.AudioObjectGetPropertyData(
            coreaudio.kAudioObjectSystemObject,
            &prop_address,
            0,
            null,
            &prop_size,
            &default_device,
        );
        if (status != coreaudio.noErr or default_device == 0) {
            log.err("Failed to get default input device: {} (no microphone?)", .{status});
            _ = coreaudio.os_api.AudioComponentInstanceDispose(audio_unit);
            return error.NoInputDevice;
        }
        log.info("Default input device ID: {}", .{default_device});

        // Set the current device to the default input device
        status = coreaudio.os_api.AudioUnitSetProperty(
            audio_unit,
            coreaudio.kAudioOutputUnitProperty_CurrentDevice,
            coreaudio.kAudioUnitScope_Global,
            0,
            &default_device,
            @sizeOf(u32),
        );
        if (status != coreaudio.noErr) {
            log.err("Failed to set input device: {}", .{status});
            _ = coreaudio.os_api.AudioComponentInstanceDispose(audio_unit);
            return error.InputUnitInitFailed;
        }
        log.info("Set input device on audio unit", .{});

        // Set up the input callback using kAudioOutputUnitProperty_SetInputCallback
        // This callback is invoked when input data is available
        var callback = coreaudio.AURenderCallbackStruct{
            .inputProc = inputCallback,
            .inputProcRefCon = self,
        };

        status = coreaudio.os_api.AudioUnitSetProperty(
            audio_unit,
            coreaudio.kAudioOutputUnitProperty_SetInputCallback,
            coreaudio.kAudioUnitScope_Global,
            0, // Element 0 for the callback registration
            &callback,
            @sizeOf(coreaudio.AURenderCallbackStruct),
        );
        if (status != coreaudio.noErr) {
            log.err("Failed to set input callback: {}", .{status});
            _ = coreaudio.os_api.AudioComponentInstanceDispose(audio_unit);
            return error.InputUnitInitFailed;
        }
        log.info("Set input callback", .{});

        // Initialize the unit FIRST (before getting format)
        status = coreaudio.os_api.AudioUnitInitialize(audio_unit);
        if (status != coreaudio.noErr) {
            log.err("Failed to initialize audio unit: {}", .{status});
            _ = coreaudio.os_api.AudioComponentInstanceDispose(audio_unit);
            return error.InputUnitInitFailed;
        }

        // Query the actual device format AFTER initialization
        var device_format: coreaudio.AudioStreamBasicDescription = undefined;
        var format_size: u32 = @sizeOf(coreaudio.AudioStreamBasicDescription);
        status = coreaudio.os_api.AudioUnitGetProperty(
            audio_unit,
            coreaudio.kAudioUnitProperty_StreamFormat,
            coreaudio.kAudioUnitScope_Output,
            1, // Input element, output scope = format from hardware
            &device_format,
            &format_size,
        );
        if (status == coreaudio.noErr) {
            const is_non_interleaved = (device_format.mFormatFlags & coreaudio.kAudioFormatFlagIsNonInterleaved) != 0;
            log.info("Device format: {} channels, {} Hz, {} bits, flags=0x{x} (non-interleaved={})", .{
                device_format.mChannelsPerFrame,
                @as(u32, @intFromFloat(device_format.mSampleRate)),
                device_format.mBitsPerChannel,
                device_format.mFormatFlags,
                is_non_interleaved,
            });
            self.input_channels = device_format.mChannelsPerFrame;
            self.is_non_interleaved = is_non_interleaved;
        } else {
            log.warn("Could not query device format: {}, assuming 1 channel interleaved", .{status});
            self.input_channels = 1;
            self.is_non_interleaved = false;
        }

        self.input_unit = audio_unit;
        log.info("Audio input unit initialized successfully! ({} input channels)", .{self.input_channels});
    }
};

// Track callback invocations for debugging
var g_callback_count: u32 = 0;

fn inputCallback(
    inRefCon: ?*anyopaque,
    _: *coreaudio.AudioUnitRenderActionFlags,
    inTimeStamp: *const coreaudio.AudioTimeStamp,
    inBusNumber: u32,
    inNumberFrames: u32,
    ioData: ?*coreaudio.AudioBufferList,
) callconv(.c) coreaudio.OSStatus {
    _ = ioData; // Not used for input - we need to call AudioUnitRender

    const self: *Recording = @ptrCast(@alignCast(inRefCon orelse return coreaudio.noErr));

    // Debug: track that callback is being invoked
    g_callback_count += 1;
    if (g_callback_count == 1) {
        log.info("Input callback invoked! bus={} frames={}", .{ inBusNumber, inNumberFrames });
    }

    if (self.state.load(.monotonic) != .recording) {
        return coreaudio.noErr;
    }

    // Use the actual input channel count from the device
    const input_channels = self.input_channels;
    const is_non_interleaved = self.is_non_interleaved;

    // Allocate buffers for audio data
    var audio_data_left: [2048]f32 = undefined;
    var audio_data_right: [2048]f32 = undefined;
    const bytes_per_channel = inNumberFrames * @sizeOf(f32);

    var status: coreaudio.OSStatus = undefined;
    var render_flags: coreaudio.AudioUnitRenderActionFlags = 0;

    if (is_non_interleaved and input_channels >= 2) {
        // Non-interleaved: separate buffer for each channel (use 2-buffer variant)
        var buffer_list2 = coreaudio.AudioBufferList2{
            .mNumberBuffers = 2,
            .mBuffers = .{
                .{
                    .mNumberChannels = 1,
                    .mDataByteSize = @intCast(@min(bytes_per_channel, audio_data_left.len * @sizeOf(f32))),
                    .mData = @ptrCast(&audio_data_left),
                },
                .{
                    .mNumberChannels = 1,
                    .mDataByteSize = @intCast(@min(bytes_per_channel, audio_data_right.len * @sizeOf(f32))),
                    .mData = @ptrCast(&audio_data_right),
                },
            },
        };

        // Pull audio from the input element (bus 1)
        status = coreaudio.os_api.AudioUnitRender(
            self.input_unit.?,
            &render_flags,
            inTimeStamp,
            1, // Input element is always bus 1
            inNumberFrames,
            @ptrCast(&buffer_list2),
        );
    } else {
        // Interleaved or mono: single buffer
        const bytes_needed = inNumberFrames * input_channels * @sizeOf(f32);
        var buffer_list = coreaudio.AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = .{.{
                .mNumberChannels = input_channels,
                .mDataByteSize = @intCast(@min(bytes_needed, audio_data_left.len * @sizeOf(f32))),
                .mData = @ptrCast(&audio_data_left),
            }},
        };

        // Pull audio from the input element (bus 1)
        status = coreaudio.os_api.AudioUnitRender(
            self.input_unit.?,
            &render_flags,
            inTimeStamp,
            1, // Input element is always bus 1
            inNumberFrames,
            &buffer_list,
        );
    }

    if (status != coreaudio.noErr) {
        // Log first few errors only
        if (g_callback_count < 5) {
            log.warn("AudioUnitRender failed: {} (channels={}, non-interleaved={})", .{ status, input_channels, is_non_interleaved });
        }
        return coreaudio.noErr;
    }

    // Copy to recording buffer, converting to stereo if needed
    const write_pos = self.write_pos.load(.monotonic);
    const space_available = self.buffer_size - write_pos;
    const frames_to_copy = @min(inNumberFrames, space_available / 2);

    if (frames_to_copy > 0) {
        if (is_non_interleaved and input_channels >= 2) {
            // Non-interleaved stereo: separate buffers for L/R
            for (0..frames_to_copy) |i| {
                self.buffer[write_pos + i * 2] = audio_data_left[i];
                self.buffer[write_pos + i * 2 + 1] = audio_data_right[i];
            }
        } else if (input_channels == 1) {
            // Mono to stereo conversion
            for (0..frames_to_copy) |i| {
                const mono_sample = audio_data_left[i];
                self.buffer[write_pos + i * 2] = mono_sample;
                self.buffer[write_pos + i * 2 + 1] = mono_sample;
            }
        } else {
            // Interleaved stereo or more - copy first two channels
            for (0..frames_to_copy) |i| {
                self.buffer[write_pos + i * 2] = audio_data_left[i * input_channels];
                self.buffer[write_pos + i * 2 + 1] = audio_data_left[i * input_channels + @min(1, input_channels - 1)];
            }
        }
        const samples_written = frames_to_copy * 2;
        self.write_pos.store(write_pos + samples_written, .monotonic);
        _ = self.samples_recorded.fetchAdd(samples_written, .monotonic);
    }

    return coreaudio.noErr;
}

// =============================================================================
// C API
// =============================================================================

var g_recording: ?*Recording = null;

/// Input source for the next capture, NUL-terminated; all zero means the default source.
/// Written from the UI thread only while no capture is active (see `isBusy`).
var g_input_device: [128]u8 = @splat(0);

/// Select the input source for the next capture. `name` must be shorter than 128 bytes.
pub fn setInputDevice(name: []const u8) void {
    @memset(&g_input_device, 0);
    @memcpy(g_input_device[0..name.len], name);
}

/// True while a capture is open or stopping, so input settings must not change.
pub fn isBusy() bool {
    const rec = g_recording orelse return false;
    return rec.state.load(.monotonic) != .idle;
}

/// Initialize recording system
export fn recording_init(sample_rate: u32) callconv(.c) c_int {
    if (g_recording != null) return 0; // Already initialized

    // Use page allocator for long-lived recording buffer
    const allocator = std.heap.page_allocator;

    g_recording = Recording.init(allocator, sample_rate) catch {
        log.err("Failed to initialize recording", .{});
        return -1;
    };

    log.info("Recording system initialized ({}Hz)", .{sample_rate});
    return 0;
}

/// Start recording on specified track
export fn recording_start(track: c_int, start_time: f64) callconv(.c) c_int {
    const rec = g_recording orelse return -1;
    rec.start(track, start_time) catch return -1;
    return 0;
}

/// Stop recording
export fn recording_stop() callconv(.c) void {
    if (g_recording) |rec| {
        rec.stop();
    }
}

/// Check if currently recording
export fn recording_is_active() callconv(.c) c_int {
    const rec = g_recording orelse return 0;
    return if (rec.state.load(.monotonic) == .recording) 1 else 0;
}

/// Get recording duration in seconds
export fn recording_get_duration() callconv(.c) f64 {
    const rec = g_recording orelse return 0.0;
    return rec.getDuration();
}

/// Save recording to file
export fn recording_save(path_ptr: [*:0]const u8) callconv(.c) c_int {
    const rec = g_recording orelse return -1;
    const path = std.mem.span(path_ptr);
    rec.saveToFile(path) catch return -1;
    return 0;
}

/// Get pointer to recorded audio data
export fn recording_get_data_ptr() callconv(.c) ?[*]const f32 {
    const rec = g_recording orelse return null;
    const data = rec.getRecordedData();
    if (data.len == 0) return null;
    return data.ptr;
}

/// Get number of samples in recording (stereo interleaved)
export fn recording_get_sample_count() callconv(.c) u64 {
    const rec = g_recording orelse return 0;
    return rec.samples_recorded.load(.monotonic);
}

/// Get recording sample rate
export fn recording_get_sample_rate() callconv(.c) u32 {
    const rec = g_recording orelse return 0;
    return rec.sample_rate;
}

/// Get peak levels for waveform preview (fills output array with peaks)
/// Returns number of peaks written
export fn recording_get_peaks(out_peaks: [*]f32, max_peaks: u32) callconv(.c) u32 {
    const rec = g_recording orelse return 0;
    const sample_count = rec.samples_recorded.load(.monotonic);
    if (sample_count == 0 or max_peaks == 0) return 0;

    const samples_per_peak = @max(1, sample_count / max_peaks);
    var peaks_written: u32 = 0;

    var i: u64 = 0;
    while (i < sample_count and peaks_written < max_peaks) : (i += samples_per_peak) {
        var peak: f32 = 0.0;
        const end = @min(i + samples_per_peak, sample_count);

        // Find max absolute value in this segment
        var j: u64 = i;
        while (j < end) : (j += 2) { // Skip by 2 for stereo
            const left = @abs(rec.buffer[j]);
            const right = if (j + 1 < sample_count) @abs(rec.buffer[j + 1]) else left;
            const sample_peak = @max(left, right);
            if (sample_peak > peak) peak = sample_peak;
        }

        out_peaks[peaks_written] = peak;
        peaks_written += 1;
    }

    return peaks_written;
}

/// Get the recording start time
export fn recording_get_start_time() callconv(.c) f64 {
    const rec = g_recording orelse return 0.0;
    return rec.start_time;
}

/// Get the target track for current recording
export fn recording_get_target_track() callconv(.c) c_int {
    const rec = g_recording orelse return -1;
    return rec.target_track;
}

test "appendStereo fills the buffer and stops at capacity" {
    const rec = try Recording.init(std.testing.allocator, 8);
    defer rec.deinit();
    rec.state.store(.recording, .monotonic);
    rec.appendStereo(&.{ 0.1, 0.2, 0.3, 0.4 });
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.4 }, rec.getRecordedData());
    // An odd trailing sample is dropped and capacity (300 s * 8 Hz * 2) is never exceeded.
    var big: [5001]f32 = @splat(0.5);
    rec.appendStereo(&big);
    rec.appendStereo(&big);
    try std.testing.expectEqual(rec.buffer_size, rec.getRecordedData().len);
    rec.state.store(.idle, .monotonic);
}
