const std = @import("std");
const sys = @import("../utils/sys.zig");
const builtin = @import("builtin");

// Platform-specific imports
const coreaudio = @import("coreaudio.zig");
const pulseaudio = @import("pulseaudio.zig");
const pipewire = @import("pipewire.zig");
const null_backend = @import("null_backend.zig");

const log = std.log.scoped(.audio_backend);

pub const BackendConfig = struct {
    sample_rate: u32,
    buffer_size: u32,
    channels: u8,
    /// Output device name from the device list; "" is the system default.
    device: []const u8 = "",
};

/// Whether backend type `backend_type` can route to the named output `device`.
/// The empty name (system default) is always accepted.
pub fn canRouteTo(backend_type: BackendType, device: []const u8) bool {
    if (device.len == 0) return true;
    return switch (backend_type) {
        .pulseaudio => true,
        // PipeWire does not pass a target yet; CoreAudio is out of scope on Linux; none has no sinks.
        .pipewire, .coreaudio, .none => false,
    };
}

pub const BackendType = enum {
    coreaudio,
    pulseaudio,
    pipewire,
    /// No audio server reachable: silent, still clocked in real time.
    none,
};

pub const Backend = union(BackendType) {
    coreaudio: coreaudio.CoreAudioBackend,
    pulseaudio: pulseaudio.PulseAudioBackend,
    pipewire: pipewire.PipeWireBackend,
    none: null_backend.NullBackend,

    pub fn init(
        allocator: std.mem.Allocator,
        config: BackendConfig,
        preference: []const u8,
    ) !Backend {
        // Platform-specific initialization
        if (builtin.os.tag == .macos) {
            return initMacOS(allocator, config, preference);
        } else if (builtin.os.tag == .linux) {
            return initLinux(allocator, config, preference);
        } else {
            log.err("Unsupported platform: {s}", .{@tagName(builtin.os.tag)});
            return error.UnsupportedPlatform;
        }
    }

    fn initMacOS(
        allocator: std.mem.Allocator,
        config: BackendConfig,
        preference: []const u8,
    ) !Backend {
        // On macOS, CoreAudio is always available
        if (std.mem.eql(u8, preference, "coreaudio") or std.mem.eql(u8, preference, "auto")) {
            log.info("Initializing CoreAudio backend", .{});
            return .{ .coreaudio = try coreaudio.CoreAudioBackend.init(allocator, config) };
        }

        // User explicitly requested a Linux backend on macOS
        log.err("Backend '{s}' is not available on macOS, use 'coreaudio' or 'auto'", .{preference});
        return error.NoAudioBackendAvailable;
    }

    fn initLinux(
        allocator: std.mem.Allocator,
        config: BackendConfig,
        preference: []const u8,
    ) !Backend {
        // Try based on preference
        if (std.mem.eql(u8, preference, "pipewire")) {
            if (detectPipeWire()) {
                log.info("Initializing PipeWire backend (requested)", .{});
                return .{ .pipewire = try pipewire.PipeWireBackend.init(allocator, config) };
            } else {
                log.warn("PipeWire requested but not available, falling back to PulseAudio", .{});
            }
        } else if (std.mem.eql(u8, preference, "pulse") or std.mem.eql(u8, preference, "pulseaudio")) {
            if (detectPulseAudio()) {
                log.info("Initializing PulseAudio backend (requested)", .{});
                return .{ .pulseaudio = try pulseaudio.PulseAudioBackend.init(allocator, config) };
            } else {
                log.warn("PulseAudio requested but not available", .{});
                return error.NoAudioBackendAvailable;
            }
        }

        if (std.mem.eql(u8, preference, "none")) {
            return .{ .none = try null_backend.NullBackend.init(allocator, config) };
        }

        // Auto-detect: PulseAudio first. Its stream plays on the default sink today; the PipeWire
        // backend connects but stays paused, so it is only used when PulseAudio is not available.
        if (detectPulseAudio()) {
            log.info("Initializing PulseAudio backend (auto-detected)", .{});
            if (pulseaudio.PulseAudioBackend.init(allocator, config)) |pa| return .{ .pulseaudio = pa } else |err| {
                log.warn("PulseAudio unavailable ({})", .{err});
            }
        }
        if (detectPipeWire()) {
            log.info("Initializing PipeWire backend (auto-detected)", .{});
            if (pipewire.PipeWireBackend.init(allocator, config)) |pw| return .{ .pipewire = pw } else |err| {
                log.warn("PipeWire unavailable ({}), trying PulseAudio", .{err});
            }
        }
        log.warn("No audio server found (neither PipeWire nor PulseAudio); audio output is silent", .{});
        return .{ .none = try null_backend.NullBackend.init(allocator, config) };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .coreaudio => |*ca| ca.deinit(),
            .pulseaudio => |*pa| pa.deinit(),
            .pipewire => |*pw| pw.deinit(),
            .none => |*n| n.deinit(),
        }
    }

    pub fn start(self: *Backend) !void {
        switch (self.*) {
            .coreaudio => |*ca| try ca.start(),
            .pulseaudio => |*pa| try pa.start(),
            .pipewire => |*pw| try pw.start(),
            .none => |*n| try n.start(),
        }
    }

    pub fn stop(self: *Backend) void {
        switch (self.*) {
            .coreaudio => |*ca| ca.stop(),
            .pulseaudio => |*pa| pa.stop(),
            .pipewire => |*pw| pw.stop(),
            .none => |*n| n.stop(),
        }
    }

    /// Set the audio engine for callback-based backends
    pub fn setEngine(self: *Backend, engine: *anyopaque, process_fn: *const fn (*anyopaque, []f32) void) void {
        switch (self.*) {
            .coreaudio => |*ca| ca.setEngine(engine, process_fn),
            .pulseaudio => |*pa| pa.setEngine(engine, process_fn),
            .pipewire => |*pw| pw.setEngine(engine, process_fn),
            .none => |*n| n.setEngine(engine, process_fn),
        }
    }

    /// Get the current backend type
    pub fn getType(self: Backend) BackendType {
        return self;
    }
};

fn detectPipeWire() bool {
    // Check for PipeWire runtime directory
    if (sys.getenv("PIPEWIRE_RUNTIME_DIR")) |_| {
        return true;
    }

    // Try to execute pw-cli
    return sys.runSucceeds(&.{ "pw-cli", "ls", "Node" });
}

fn detectPulseAudio() bool {
    // An explicit PULSE_SERVER means the server is configured; trust it, as detectPipeWire does
    // with its runtime dir. Otherwise ask pactl.
    if (sys.getenv("PULSE_SERVER")) |_| {
        return true;
    }
    return sys.runSucceeds(&.{ "pactl", "info" });
}

test "backend detection" {
    // Just verify detection functions don't crash
    _ = detectPipeWire();
    _ = detectPulseAudio();
}
