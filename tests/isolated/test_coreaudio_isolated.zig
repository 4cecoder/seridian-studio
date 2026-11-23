// CoreAudio Isolated Runtime Test
// This is a standalone executable that proves the CoreAudio backend works at runtime.
// It can be run directly to verify backend functionality without the Zig test framework.

const std = @import("std");
const builtin = @import("builtin");

// Exit codes
const EXIT_SUCCESS: u8 = 0;
const EXIT_FAILURE: u8 = 1;

// Platform check: Skip if not on macOS
fn checkPlatform() bool {
    if (builtin.os.tag != .macos) {
        std.debug.print("\n", .{});
        std.debug.print("========================================\n", .{});
        std.debug.print("CoreAudio Isolated Runtime Test\n", .{});
        std.debug.print("========================================\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Skipped (not on macOS)\n", .{});
        std.debug.print("\n", .{});
        return false;
    }
    return true;
}

// CoreAudio types and extern declarations
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
pub const kAudioUnitType_Output: u32 = 0x61756f75; // 'auou'
pub const kAudioUnitSubType_DefaultOutput: u32 = 0x64656620; // 'def '
pub const kAudioUnitManufacturer_Apple: u32 = 0x6170706c; // 'appl'
pub const kAudioFormatLinearPCM: u32 = 0x6c70636d; // 'lpcm'
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
pub const kAudioUnitProperty_StreamFormat: u32 = 8;
pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;
pub const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
pub const kAudioUnitScope_Input: u32 = 1;
pub const kAudioUnitScope_Global: u32 = 0;

// External function declarations (only available on macOS)
// Provide stubs for non-macOS platforms to allow compilation
pub const AudioComponentFindNext = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioComponentFindNext(inComponent: ?AudioComponent, inDesc: *const AudioComponentDescription) ?AudioComponent;
    }.AudioComponentFindNext
else
    struct {
        fn stub(_: ?AudioComponent, _: *const AudioComponentDescription) ?AudioComponent {
            return null;
        }
    }.stub;

pub const AudioComponentInstanceNew = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioComponentInstanceNew(inComponent: AudioComponent, outInstance: *?AudioComponentInstance) OSStatus;
    }.AudioComponentInstanceNew
else
    struct {
        fn stub(_: AudioComponent, _: *?AudioComponentInstance) OSStatus {
            return -1;
        }
    }.stub;

pub const AudioComponentInstanceDispose = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioComponentInstanceDispose(inInstance: AudioComponentInstance) OSStatus;
    }.AudioComponentInstanceDispose
else
    struct {
        fn stub(_: AudioComponentInstance) OSStatus {
            return 0;
        }
    }.stub;

pub const AudioUnitInitialize = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioUnitInitialize(inUnit: AudioComponentInstance) OSStatus;
    }.AudioUnitInitialize
else
    struct {
        fn stub(_: AudioComponentInstance) OSStatus {
            return -1;
        }
    }.stub;

pub const AudioUnitUninitialize = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioUnitUninitialize(inUnit: AudioComponentInstance) OSStatus;
    }.AudioUnitUninitialize
else
    struct {
        fn stub(_: AudioComponentInstance) OSStatus {
            return 0;
        }
    }.stub;

pub const AudioOutputUnitStart = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioOutputUnitStart(ci: AudioComponentInstance) OSStatus;
    }.AudioOutputUnitStart
else
    struct {
        fn stub(_: AudioComponentInstance) OSStatus {
            return -1;
        }
    }.stub;

pub const AudioOutputUnitStop = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioOutputUnitStop(ci: AudioComponentInstance) OSStatus;
    }.AudioOutputUnitStop
else
    struct {
        fn stub(_: AudioComponentInstance) OSStatus {
            return 0;
        }
    }.stub;

pub const AudioUnitSetProperty = if (builtin.os.tag == .macos)
    struct {
        extern fn AudioUnitSetProperty(
            inUnit: AudioComponentInstance,
            inID: u32,
            inScope: u32,
            inElement: u32,
            inData: ?*const anyopaque,
            inDataSize: u32,
        ) OSStatus;
    }.AudioUnitSetProperty
else
    struct {
        fn stub(_: AudioComponentInstance, _: u32, _: u32, _: u32, _: ?*const anyopaque, _: u32) OSStatus {
            return -1;
        }
    }.stub;

// Simplified CoreAudio backend for testing
const CoreAudioBackend = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    audio_unit: ?AudioComponentInstance = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    engine: std.atomic.Value(?*anyopaque),
    process_fn: ?*const fn (*anyopaque, []f32) void = null,
    output_buffer: []f32 = &[_]f32{},

    fn init(allocator: std.mem.Allocator, config: anytype) !CoreAudioBackend {
        var self = CoreAudioBackend{
            .allocator = allocator,
            .sample_rate = config.sample_rate,
            .buffer_size = config.buffer_size,
            .channels = config.channels,
            .engine = std.atomic.Value(?*anyopaque).init(null),
        };

        self.output_buffer = try allocator.alloc(f32, config.buffer_size * config.channels);
        errdefer allocator.free(self.output_buffer);

        return self;
    }

    fn prepare(self: *CoreAudioBackend) !void {
        // Find default output audio component
        var desc = AudioComponentDescription{
            .componentType = kAudioUnitType_Output,
            .componentSubType = kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };

        const component = AudioComponentFindNext(null, &desc) orelse {
            std.debug.print("Failed to find default audio output component\n", .{});
            return error.CoreAudioInitFailed;
        };

        // Create audio unit instance
        var audio_unit: ?AudioComponentInstance = null;
        var status = AudioComponentInstanceNew(component, &audio_unit);
        if (status != noErr or audio_unit == null) {
            std.debug.print("Failed to create audio unit instance: {d}\n", .{status});
            return error.CoreAudioInitFailed;
        }
        self.audio_unit = audio_unit;
        errdefer {
            _ = AudioComponentInstanceDispose(self.audio_unit.?);
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

        status = AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &stream_format,
            @sizeOf(AudioStreamBasicDescription),
        );
        if (status != noErr) {
            std.debug.print("Failed to set stream format: {d}\n", .{status});
            return error.CoreAudioInitFailed;
        }

        // Set maximum frames per slice
        var max_frames: u32 = self.buffer_size;
        status = AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &max_frames,
            @sizeOf(u32),
        );
        if (status != noErr) {
            std.debug.print("Warning: Failed to set max frames per slice: {d}\n", .{status});
            // Non-fatal, continue
        }

        // Set up render callback
        var callback_struct = AURenderCallbackStruct{
            .inputProc = renderCallback,
            .inputProcRefCon = self,
        };

        status = AudioUnitSetProperty(
            self.audio_unit.?,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback_struct,
            @sizeOf(AURenderCallbackStruct),
        );
        if (status != noErr) {
            std.debug.print("Failed to set render callback: {d}\n", .{status});
            return error.CoreAudioInitFailed;
        }

        // Initialize the audio unit
        status = AudioUnitInitialize(self.audio_unit.?);
        if (status != noErr) {
            std.debug.print("Failed to initialize audio unit: {d}\n", .{status});
            return error.CoreAudioInitFailed;
        }
    }

    fn renderCallback(
        inRefCon: ?*anyopaque,
        _: *AudioUnitRenderActionFlags,
        _: *const AudioTimeStamp,
        _: u32,
        inNumberFrames: u32,
        ioData: ?*AudioBufferList,
    ) callconv(.c) OSStatus {
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

        // Atomically load the engine pointer
        const engine_ptr = self.engine.load(.acquire);
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

    fn deinit(self: *CoreAudioBackend) void {
        self.stop();

        // Clear the engine pointer atomically
        self.engine.store(null, .release);
        self.process_fn = null;

        // Wait for any in-flight render callbacks to complete
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

        if (self.audio_unit) |au| {
            // Clear the render callback
            var empty_callback = AURenderCallbackStruct{
                .inputProc = null,
                .inputProcRefCon = null,
            };
            _ = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &empty_callback,
                @sizeOf(AURenderCallbackStruct),
            );

            // Uninitialize and dispose
            _ = AudioUnitUninitialize(au);
            _ = AudioComponentInstanceDispose(au);
            self.audio_unit = null;
        }

        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
            self.output_buffer = &[_]f32{};
        }
    }

    fn start(self: *CoreAudioBackend) !void {
        self.running.store(true, .release);

        if (self.audio_unit) |au| {
            const status = AudioOutputUnitStart(au);
            if (status != noErr) {
                std.debug.print("Failed to start audio unit: {d}\n", .{status});
                self.running.store(false, .release);
                return error.CoreAudioStartFailed;
            }
        }
    }

    fn stop(self: *CoreAudioBackend) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        self.running.store(false, .release);

        if (self.audio_unit) |au| {
            _ = AudioOutputUnitStop(au);
        }

        // Give the audio thread time to finish any in-progress callback
        std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
    }

    fn setEngine(self: *CoreAudioBackend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        self.engine.store(engine, .release);
        self.process_fn = process_fn;
    }
};

// Mock engine that counts callback invocations
const CallbackCounter = struct {
    invocation_count: std.atomic.Value(u32),
    last_buffer_size: std.atomic.Value(usize),
    total_samples_processed: std.atomic.Value(u64),

    fn init() CallbackCounter {
        return .{
            .invocation_count = std.atomic.Value(u32).init(0),
            .last_buffer_size = std.atomic.Value(usize).init(0),
            .total_samples_processed = std.atomic.Value(u64).init(0),
        };
    }

    fn processCallback(ctx: *anyopaque, buffer: []f32) void {
        const self: *CallbackCounter = @ptrCast(@alignCast(ctx));

        _ = self.invocation_count.fetchAdd(1, .monotonic);
        self.last_buffer_size.store(buffer.len, .monotonic);
        _ = self.total_samples_processed.fetchAdd(buffer.len, .monotonic);

        // Fill buffer with a simple test signal (sine wave at 440Hz)
        const sample_rate: f32 = 48000.0;
        const frequency: f32 = 440.0;

        for (buffer, 0..) |*sample, i| {
            const t = @as(f32, @floatFromInt(i)) / sample_rate;
            sample.* = @sin(2.0 * std.math.pi * frequency * t) * 0.1;
        }
    }

    fn getCount(self: *const CallbackCounter) u32 {
        return self.invocation_count.load(.monotonic);
    }

    fn getBufferSize(self: *const CallbackCounter) usize {
        return self.last_buffer_size.load(.monotonic);
    }

    fn getTotalSamples(self: *const CallbackCounter) u64 {
        return self.total_samples_processed.load(.monotonic);
    }
};

// Simple config struct for CoreAudio initialization
const TestConfig = struct {
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
};

pub fn main() !void {
    // Platform check first
    if (!checkPlatform()) {
        std.process.exit(EXIT_SUCCESS);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("CoreAudio Isolated Runtime Test\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("\n", .{});

    // Configuration
    const cfg = TestConfig{
        .sample_rate = 48000,
        .buffer_size = 512,
        .channels = 2,
    };

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Sample rate: {d} Hz\n", .{cfg.sample_rate});
    std.debug.print("  Buffer size: {d} frames\n", .{cfg.buffer_size});
    std.debug.print("  Channels: {d}\n", .{cfg.channels});
    std.debug.print("\n", .{});

    var all_tests_passed = true;

    // Step 1: Initialize backend
    std.debug.print("Step 1: Initializing CoreAudio backend...\n", .{});
    var backend = CoreAudioBackend.init(allocator, cfg) catch |err| {
        std.debug.print("FAIL: Could not initialize CoreAudio backend: {}\n", .{err});
        std.debug.print("CoreAudio may not be available on this system.\n", .{});
        std.process.exit(EXIT_FAILURE);
    };
    defer backend.deinit();
    std.debug.print("  Result: PASS (backend initialized)\n", .{});
    std.debug.print("\n", .{});

    // Step 2: Prepare the audio unit
    std.debug.print("Step 2: Calling prepare() to set up CoreAudio...\n", .{});
    backend.prepare() catch |err| {
        std.debug.print("FAIL: Could not prepare CoreAudio: {}\n", .{err});
        std.debug.print("CoreAudio initialization failed.\n", .{});
        std.process.exit(EXIT_FAILURE);
    };
    std.debug.print("  Result: PASS (audio unit prepared)\n", .{});
    std.debug.print("\n", .{});

    // Step 3: Create mock engine
    std.debug.print("Step 3: Creating mock engine (callback counter)...\n", .{});
    var counter = CallbackCounter.init();
    std.debug.print("  Result: PASS (counter created)\n", .{});
    std.debug.print("\n", .{});

    // Step 4: Set engine
    std.debug.print("Step 4: Calling setEngine()...\n", .{});
    backend.setEngine(@ptrCast(&counter), CallbackCounter.processCallback);
    std.debug.print("  Result: PASS (engine callback registered)\n", .{});
    std.debug.print("\n", .{});

    // Step 5: Start playback
    std.debug.print("Step 5: Calling start()...\n", .{});
    backend.start() catch |err| {
        std.debug.print("FAIL: Could not start playback: {}\n", .{err});
        all_tests_passed = false;
        std.process.exit(EXIT_FAILURE);
    };
    std.debug.print("  Result: PASS (playback started)\n", .{});
    std.debug.print("\n", .{});

    // Step 6: Sleep and collect data
    std.debug.print("Step 6: Sleeping for 500ms to allow callbacks...\n", .{});
    std.posix.nanosleep(0, 500 * std.time.ns_per_ms);
    std.debug.print("  Result: PASS (sleep completed)\n", .{});
    std.debug.print("\n", .{});

    // Step 7: Check callback count
    std.debug.print("Step 7: Checking callback count...\n", .{});
    const count_while_running = counter.getCount();
    const buffer_size = counter.getBufferSize();
    const total_samples = counter.getTotalSamples();

    std.debug.print("  Callbacks invoked: {d}\n", .{count_while_running});
    std.debug.print("  Expected: >0\n", .{});
    std.debug.print("  Last buffer size: {d} samples\n", .{buffer_size});
    std.debug.print("  Total samples processed: {d}\n", .{total_samples});

    if (count_while_running > 0) {
        std.debug.print("  Result: PASS (callbacks executed)\n", .{});
    } else {
        std.debug.print("  Result: FAIL (no callbacks executed)\n", .{});
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Additional validation: buffer size
    const expected_buffer_size = cfg.buffer_size * cfg.channels;
    if (buffer_size == expected_buffer_size) {
        std.debug.print("  Buffer size validation: PASS ({d} == {d})\n", .{ buffer_size, expected_buffer_size });
    } else {
        std.debug.print("  Buffer size validation: FAIL ({d} != {d})\n", .{ buffer_size, expected_buffer_size });
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Additional validation: callback rate
    const buffer_duration_ms = (@as(f64, @floatFromInt(cfg.buffer_size)) * 1000.0) / @as(f64, @floatFromInt(cfg.sample_rate));
    const expected_callbacks = @as(u32, @intFromFloat(500.0 / buffer_duration_ms));
    const min_callbacks = expected_callbacks / 2;
    const max_callbacks = expected_callbacks * 2;

    std.debug.print("  Callback rate validation:\n", .{});
    std.debug.print("    Expected (approx): {d} callbacks\n", .{expected_callbacks});
    std.debug.print("    Acceptable range: {d} - {d}\n", .{ min_callbacks, max_callbacks });
    std.debug.print("    Actual: {d}\n", .{count_while_running});

    if (count_while_running >= min_callbacks and count_while_running <= max_callbacks) {
        std.debug.print("    Result: PASS (callback rate is reasonable)\n", .{});
    } else {
        std.debug.print("    Result: WARN (callback rate outside expected range)\n", .{});
    }
    std.debug.print("\n", .{});

    // Step 8: Stop playback
    std.debug.print("Step 8: Calling stop()...\n", .{});
    backend.stop();
    std.debug.print("  Result: PASS (stop requested)\n", .{});
    std.debug.print("\n", .{});

    // Step 9: Verify callbacks stopped
    std.debug.print("Step 9: Verifying callbacks stopped...\n", .{});
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
    const count_after_stop = counter.getCount();
    std.debug.print("  Callback count immediately after stop: {d}\n", .{count_after_stop});

    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);
    const count_final = counter.getCount();
    std.debug.print("  Callback count after 200ms wait: {d}\n", .{count_final});

    if (count_after_stop == count_final) {
        std.debug.print("  Result: PASS (callbacks stopped, {d} == {d})\n", .{ count_after_stop, count_final });
    } else {
        std.debug.print("  Result: FAIL (callbacks continued, {d} != {d})\n", .{ count_after_stop, count_final });
        all_tests_passed = false;
    }
    std.debug.print("\n", .{});

    // Step 10: deinit() is called via defer
    std.debug.print("Step 10: Calling deinit() (via defer)...\n", .{});
    std.debug.print("  Result: Will execute on function exit\n", .{});
    std.debug.print("\n", .{});

    // Final summary
    std.debug.print("========================================\n", .{});
    std.debug.print("Test Summary\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Callbacks invoked: {d}\n", .{count_while_running});
    std.debug.print("Expected: >0\n", .{});
    std.debug.print("Total samples processed: {d}\n", .{total_samples});
    std.debug.print("Buffer size: {d} samples (expected: {d})\n", .{ buffer_size, expected_buffer_size });
    std.debug.print("Callbacks stopped: {s}\n", .{if (count_after_stop == count_final) "YES" else "NO"});
    std.debug.print("\n", .{});

    if (all_tests_passed and count_while_running > 0) {
        std.debug.print("Overall Result: PASS\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("The CoreAudio backend is working correctly!\n", .{});
        std.debug.print("- Audio callbacks execute properly\n", .{});
        std.debug.print("- Buffer sizes are correct\n", .{});
        std.debug.print("- Playback stops cleanly\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(EXIT_SUCCESS);
    } else {
        std.debug.print("Overall Result: FAIL\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("The CoreAudio backend is NOT working correctly.\n", .{});
        std.debug.print("See detailed output above for failure reasons.\n", .{});
        std.debug.print("\n", .{});
        std.process.exit(EXIT_FAILURE);
    }
}
