const std = @import("std");
const sys = @import("../utils/sys.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.coreaudio);

// CoreAudio types and functions via extern declarations
// This avoids Zig's @cImport issues with Objective-C blocks in Apple headers

// Type definitions
pub const OSStatus = i32;
pub const AudioComponentInstance = *opaque {};
pub const AudioComponent = *opaque {};

pub const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32,
    componentFlagsMask: u32,
};

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

pub const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

pub const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

// For non-interleaved stereo input (2 separate buffers)
pub const AudioBufferList2 = extern struct {
    mNumberBuffers: u32,
    mBuffers: [2]AudioBuffer,
};

pub const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: SMPTETime,
    mFlags: u32,
    mReserved: u32,
};

pub const SMPTETime = extern struct {
    mSubframes: i16,
    mSubframeDivisor: i16,
    mCounter: u32,
    mType: u32,
    mFlags: u32,
    mHours: i16,
    mMinutes: i16,
    mSeconds: i16,
    mFrames: i16,
};

pub const AudioUnitRenderActionFlags = u32;

pub const AURenderCallback = *const fn (
    inRefCon: ?*anyopaque,
    ioActionFlags: *AudioUnitRenderActionFlags,
    inTimeStamp: *const AudioTimeStamp,
    inBusNumber: u32,
    inNumberFrames: u32,
    ioData: ?*AudioBufferList,
) callconv(.c) OSStatus;

pub const AURenderCallbackStruct = extern struct {
    inputProc: ?AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

// Constants
pub const noErr: OSStatus = 0;

// Audio Unit Types (FourCC codes)
pub const kAudioUnitType_Output: u32 = 0x61756f75; // 'auou'
pub const kAudioUnitSubType_DefaultOutput: u32 = 0x64656620; // 'def '
pub const kAudioUnitSubType_HALOutput: u32 = 0x6168616c; // 'ahal'
pub const kAudioUnitManufacturer_Apple: u32 = 0x6170706c; // 'appl'

// Audio Format
pub const kAudioFormatLinearPCM: u32 = 0x6c70636d; // 'lpcm'
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsBigEndian: u32 = 1 << 1;
pub const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
pub const kAudioFormatFlagIsNonInterleaved: u32 = 1 << 5;

// Audio Unit Properties
pub const kAudioUnitProperty_StreamFormat: u32 = 8;
pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;
pub const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
pub const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
pub const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;
pub const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;

// Audio Unit Scope
pub const kAudioUnitScope_Input: u32 = 1;
pub const kAudioUnitScope_Output: u32 = 2;
pub const kAudioUnitScope_Global: u32 = 0;

// Audio Hardware Properties
pub const kAudioObjectSystemObject: u32 = 1;
pub const kAudioHardwarePropertyDefaultInputDevice: u32 = 0x64496e20; // 'dIn '
pub const kAudioObjectPropertyScopeGlobal: u32 = 0x676c6f62; // 'glob'
pub const kAudioObjectPropertyElementMain: u32 = 0;

pub const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
};

// External function declarations (linked via AudioToolbox/AudioUnit frameworks)
/// macOS framework entry points. Other platforms get stubs that are never
/// reached (callers check the OS first) so the build still links.
pub const os_api = if (builtin.os.tag == .macos) struct {
    pub extern fn AudioComponentFindNext(inComponent: ?AudioComponent, inDesc: *const AudioComponentDescription) ?AudioComponent;
    pub extern fn AudioComponentInstanceNew(inComponent: AudioComponent, outInstance: *?AudioComponentInstance) OSStatus;
    pub extern fn AudioComponentInstanceDispose(inInstance: AudioComponentInstance) OSStatus;
    pub extern fn AudioUnitInitialize(inUnit: AudioComponentInstance) OSStatus;
    pub extern fn AudioUnitUninitialize(inUnit: AudioComponentInstance) OSStatus;
    pub extern fn AudioOutputUnitStart(ci: AudioComponentInstance) OSStatus;
    pub extern fn AudioOutputUnitStop(ci: AudioComponentInstance) OSStatus;
    pub extern fn AudioUnitSetProperty(
        inUnit: AudioComponentInstance,
        inID: u32,
        inScope: u32,
        inElement: u32,
        inData: ?*const anyopaque,
        inDataSize: u32,
    ) OSStatus;
    pub extern fn AudioUnitGetProperty(
        inUnit: AudioComponentInstance,
        inID: u32,
        inScope: u32,
        inElement: u32,
        outData: *anyopaque,
        ioDataSize: *u32,
    ) OSStatus;
    pub extern fn AudioUnitRender(
        inUnit: AudioComponentInstance,
        ioActionFlags: *AudioUnitRenderActionFlags,
        inTimeStamp: *const AudioTimeStamp,
        inOutputBusNumber: u32,
        inNumberFrames: u32,
        ioData: *AudioBufferList,
    ) OSStatus;
    pub extern fn AudioObjectGetPropertyData(
        inObjectID: u32,
        inAddress: *const AudioObjectPropertyAddress,
        inQualifierDataSize: u32,
        inQualifierData: ?*const anyopaque,
        ioDataSize: *u32,
        outData: *anyopaque,
    ) OSStatus;
    pub extern fn AudioUnitAddRenderNotify(
        inUnit: AudioComponentInstance,
        inProc: AURenderCallback,
        inProcUserData: ?*anyopaque,
    ) OSStatus;
    pub extern fn AudioUnitRemoveRenderNotify(
        inUnit: AudioComponentInstance,
        inProc: AURenderCallback,
        inProcUserData: ?*anyopaque,
    ) OSStatus;
} else struct {
    pub fn AudioComponentFindNext(_: ?AudioComponent, _: *const AudioComponentDescription) ?AudioComponent {
        @panic("AudioComponentFindNext is only available on macOS");
    }
    pub fn AudioComponentInstanceNew(_: AudioComponent, _: *?AudioComponentInstance) OSStatus {
        @panic("AudioComponentInstanceNew is only available on macOS");
    }
    pub fn AudioComponentInstanceDispose(_: AudioComponentInstance) OSStatus {
        @panic("AudioComponentInstanceDispose is only available on macOS");
    }
    pub fn AudioUnitInitialize(_: AudioComponentInstance) OSStatus {
        @panic("AudioUnitInitialize is only available on macOS");
    }
    pub fn AudioUnitUninitialize(_: AudioComponentInstance) OSStatus {
        @panic("AudioUnitUninitialize is only available on macOS");
    }
    pub fn AudioOutputUnitStart(_: AudioComponentInstance) OSStatus {
        @panic("AudioOutputUnitStart is only available on macOS");
    }
    pub fn AudioOutputUnitStop(_: AudioComponentInstance) OSStatus {
        @panic("AudioOutputUnitStop is only available on macOS");
    }
    pub fn AudioUnitSetProperty(_: AudioComponentInstance, _: u32, _: u32, _: u32, _: ?*const anyopaque, _: u32) OSStatus {
        @panic("AudioUnitSetProperty is only available on macOS");
    }
    pub fn AudioUnitGetProperty(_: AudioComponentInstance, _: u32, _: u32, _: u32, _: *anyopaque, _: *u32) OSStatus {
        @panic("AudioUnitGetProperty is only available on macOS");
    }
    pub fn AudioUnitRender(_: AudioComponentInstance, _: *AudioUnitRenderActionFlags, _: *const AudioTimeStamp, _: u32, _: u32, _: *AudioBufferList) OSStatus {
        @panic("AudioUnitRender is only available on macOS");
    }
    pub fn AudioObjectGetPropertyData(_: u32, _: *const AudioObjectPropertyAddress, _: u32, _: ?*const anyopaque, _: *u32, _: *anyopaque) OSStatus {
        @panic("AudioObjectGetPropertyData is only available on macOS");
    }
    pub fn AudioUnitAddRenderNotify(_: AudioComponentInstance, _: AURenderCallback, _: ?*anyopaque) OSStatus {
        @panic("AudioUnitAddRenderNotify is only available on macOS");
    }
    pub fn AudioUnitRemoveRenderNotify(_: AudioComponentInstance, _: AURenderCallback, _: ?*anyopaque) OSStatus {
        @panic("AudioUnitRemoveRenderNotify is only available on macOS");
    }
};

// Render action flags
pub const kAudioUnitRenderAction_PreRender: u32 = 1 << 2;
pub const kAudioUnitRenderAction_PostRender: u32 = 1 << 3;
pub const kAudioOfflineUnitRenderAction_Preflight: u32 = 1 << 4;
pub const kAudioOfflineUnitRenderAction_Render: u32 = 1 << 5;
pub const kAudioOfflineUnitRenderAction_Complete: u32 = 1 << 6;
pub const kAudioUnitRenderAction_OutputIsSilence: u32 = 1 << 7;
pub const kAudioUnitRenderAction_PostRenderError: u32 = 1 << 8;

pub const CoreAudioBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // CoreAudio specific
    audio_unit: ?AudioComponentInstance = null,

    // Engine pointer for render callback (set via setEngine)
    engine: ?*anyopaque = null,
    process_fn: ?*const fn (*anyopaque, []f32) void = null,

    // Callback context (legacy, kept for compatibility)
    process_callback: ?*const fn ([]f32) void = null,
    output_buffer: []f32 = &[_]f32{},

    pub fn init(allocator: std.mem.Allocator, config: anytype) !CoreAudioBackend {
        if (builtin.os.tag != .macos) {
            return error.UnsupportedPlatform;
        }

        log.info("Initializing CoreAudio backend", .{});

        var self = CoreAudioBackend{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
        };

        // Allocate output buffer
        self.output_buffer = try allocator.alloc(f32, config.buffer_size * config.channels);
        errdefer allocator.free(self.output_buffer);

        // Initialize AudioUnit
        try self.setupAudioUnit();

        return self;
    }

    fn setupAudioUnit(self: *CoreAudioBackend) !void {
        // Find default output audio component
        var desc = AudioComponentDescription{
            .componentType = kAudioUnitType_Output,
            .componentSubType = kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };

        const component = os_api.AudioComponentFindNext(null, &desc) orelse {
            log.err("Failed to find default audio output component", .{});
            return error.CoreAudioInitFailed;
        };

        // Create audio unit instance
        var audio_unit: ?AudioComponentInstance = null;
        var status = os_api.AudioComponentInstanceNew(component, &audio_unit);
        if (status != noErr or audio_unit == null) {
            log.err("Failed to create audio unit instance: {d}", .{status});
            return error.CoreAudioInitFailed;
        }
        self.audio_unit = audio_unit;
        errdefer {
            _ = os_api.AudioComponentInstanceDispose(self.audio_unit.?);
            self.audio_unit = null;
        }

        // Set up stream format
        var stream_format = AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(self.sample_rate),
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = @as(u32, @intCast(@sizeOf(f32) * self.channels)),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = @as(u32, @intCast(@sizeOf(f32) * self.channels)),
            .mChannelsPerFrame = self.channels,
            .mBitsPerChannel = 32,
            .mReserved = 0,
        };

        status = os_api.AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &stream_format,
            @sizeOf(AudioStreamBasicDescription),
        );
        if (status != noErr) {
            log.err("Failed to set stream format: {d}", .{status});
            return error.CoreAudioInitFailed;
        }

        // Set maximum frames per slice
        var max_frames: u32 = self.buffer_size;
        status = os_api.AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &max_frames,
            @sizeOf(u32),
        );
        if (status != noErr) {
            log.warn("Failed to set max frames per slice: {d}", .{status});
            // Non-fatal, continue
        }

        // Set up render callback
        var callback_struct = AURenderCallbackStruct{
            .inputProc = renderCallback,
            .inputProcRefCon = self,
        };

        status = os_api.AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback_struct,
            @sizeOf(AURenderCallbackStruct),
        );
        if (status != noErr) {
            log.err("Failed to set render callback: {d}", .{status});
            return error.CoreAudioInitFailed;
        }

        // Initialize the audio unit
        status = os_api.AudioUnitInitialize(self.audio_unit.?);
        if (status != noErr) {
            log.err("Failed to initialize audio unit: {d}", .{status});
            return error.CoreAudioInitFailed;
        }

        log.info("CoreAudio initialized: {d}Hz, {d} channels, buffer={d}", .{
            self.sample_rate,
            self.channels,
            self.buffer_size,
        });
    }

    fn renderCallback(
        inRefCon: ?*anyopaque,
        _: *AudioUnitRenderActionFlags,
        _: *const AudioTimeStamp,
        _: u32,
        inNumberFrames: u32,
        ioData: ?*AudioBufferList,
    ) callconv(.c) OSStatus {
        const rt_safe = @import("rt_safe.zig");
        rt_safe.is_audio_thread = true;
        defer rt_safe.is_audio_thread = false;

        // Safety check for null context
        if (inRefCon == null) return noErr;
        const self: *CoreAudioBackend = @ptrCast(@alignCast(inRefCon));

        // Safety check for null buffer list
        const buffers = ioData orelse return noErr;
        if (buffers.mNumberBuffers == 0) return noErr;

        // Get the first buffer
        const buf = &buffers.mBuffers[0];
        const data = buf.mData orelse return noErr;

        // Calculate the number of samples
        const sample_count = inNumberFrames * buf.mNumberChannels;
        const float_data: [*]f32 = @ptrCast(@alignCast(data));

        // Check running state first
        if (!self.running.load(.acquire)) {
            // Not running - output silence
            @memset(float_data[0..sample_count], 0.0);
            return noErr;
        }

        // Atomically load the engine pointer to avoid race with deinit
        const engine_ptr = @atomicLoad(?*anyopaque, &self.engine, .acquire);
        const process_fn = self.process_fn;

        // Call the engine's process function if both are valid
        if (engine_ptr != null and process_fn != null) {
            process_fn.?(engine_ptr.?, float_data[0..sample_count]);
        } else {
            // No engine connected - output silence
            @memset(float_data[0..sample_count], 0.0);
        }

        return noErr;
    }

    pub fn deinit(self: *CoreAudioBackend) void {
        if (builtin.os.tag != .macos) return;

        log.info("CoreAudio backend shutting down...", .{});

        // First, stop playback and wait for callback to finish
        self.stop();

        // Clear the engine pointer atomically so callback outputs silence
        @atomicStore(?*anyopaque, &self.engine, null, .release);
        self.process_fn = null;

        // Wait for any in-flight render callbacks to complete
        // The audio thread runs at ~10ms intervals for 512 sample buffers at 48kHz
        sys.sleepNs(50 * std.time.ns_per_ms);

        if (self.audio_unit) |au| {
            // Clear the render callback before uninitializing
            var empty_callback = AURenderCallbackStruct{
                .inputProc = null,
                .inputProcRefCon = null,
            };
            _ = os_api.AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &empty_callback,
                @sizeOf(AURenderCallbackStruct),
            );

            // Now safe to uninitialize and dispose
            const uninit_status = os_api.AudioUnitUninitialize(au);
            if (uninit_status != noErr) {
                log.warn("AudioUnitUninitialize returned: {d}", .{uninit_status});
            }

            const dispose_status = os_api.AudioComponentInstanceDispose(au);
            if (dispose_status != noErr) {
                log.warn("AudioComponentInstanceDispose returned: {d}", .{dispose_status});
            }

            self.audio_unit = null;
        }

        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
            self.output_buffer = &[_]f32{};
        }

        log.info("CoreAudio backend shut down cleanly", .{});
    }

    pub fn start(self: *CoreAudioBackend) !void {
        if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

        log.info("Starting CoreAudio playback", .{});
        self.running.store(true, .release);

        if (self.audio_unit) |au| {
            const status = os_api.AudioOutputUnitStart(au);
            if (status != noErr) {
                log.err("Failed to start audio unit: {d}", .{status});
                self.running.store(false, .release);
                return error.CoreAudioStartFailed;
            }
        }
    }

    pub fn stop(self: *CoreAudioBackend) void {
        if (builtin.os.tag != .macos) return;

        // Check if already stopped
        if (!self.running.load(.acquire)) {
            return;
        }

        log.info("Stopping CoreAudio playback", .{});

        // Signal the callback to output silence (seq_cst ensures visibility)
        self.running.store(false, .seq_cst);

        if (self.audio_unit) |au| {
            const status = os_api.AudioOutputUnitStop(au);
            if (status != noErr) {
                log.warn("AudioOutputUnitStop returned: {d}", .{status});
            }
        }

        // Give the audio thread time to finish any in-progress callback
        sys.sleepNs(20 * std.time.ns_per_ms);
    }

    pub fn setProcessCallback(self: *CoreAudioBackend, callback: *const fn ([]f32) void) void {
        self.process_callback = callback;
    }

    /// Set the audio engine and its process function for the render callback
    pub fn setEngine(self: *CoreAudioBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.engine = engine;
        self.process_fn = process_fn;

        // Re-register the render callback with the correct self pointer
        // (needed because self may have moved since setupAudioUnit was called)
        if (self.audio_unit) |au| {
            var callback_struct = AURenderCallbackStruct{
                .inputProc = renderCallback,
                .inputProcRefCon = self,
            };
            _ = os_api.AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback_struct,
                @sizeOf(AURenderCallbackStruct),
            );
        }
    }

    pub fn isRunning(self: *const CoreAudioBackend) bool {
        return self.running.load(.acquire);
    }
};

// Detection function for macOS
pub fn detectCoreAudio() bool {
    return builtin.os.tag == .macos;
}
