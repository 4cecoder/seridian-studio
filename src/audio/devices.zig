/// Audio device enumeration for PulseAudio and PipeWire
/// Based on changies implementation using pactl
const std = @import("std");
const sys = @import("../utils/sys.zig");
const device_parse = @import("device_parse.zig");

const log = std.log.scoped(.audio_devices);

pub const DeviceType = enum {
    output, // Sinks
    input, // Sources
};

pub const AudioDevice = struct {
    /// NUL-terminated: the C UI reads these as C strings.
    name: [:0]const u8,
    description: [:0]const u8,
    index: u32,
    is_default: bool,

    pub fn deinit(self: AudioDevice, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const DeviceList = struct {
    devices: []AudioDevice,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DeviceList) void {
        for (self.devices) |device| {
            device.deinit(self.allocator);
        }
        self.allocator.free(self.devices);
    }
};

/// Enumerate PulseAudio/PipeWire devices using pactl. Parsing is delegated to
/// device_parse.zig, which is pure and unit-tested without a sound server.
pub fn enumerateDevices(allocator: std.mem.Allocator, device_type: DeviceType) !DeviceList {
    const command = switch (device_type) {
        .output => &[_][]const u8{ "pactl", "list", "short", "sinks" },
        .input => &[_][]const u8{ "pactl", "list", "short", "sources" },
    };

    const stdout = sys.runCapture(allocator, command) catch |err| {
        log.warn("Failed to enumerate {s} devices: {}", .{ @tagName(device_type), err });
        return error.DeviceEnumerationFailed;
    };
    defer allocator.free(stdout);

    // A failed default query only leaves is_default unset; the list is still valid.
    const default_name: ?[]const u8 = getDefaultDevice(allocator, device_type) catch null;
    defer if (default_name) |name| allocator.free(name);

    return buildDeviceList(allocator, stdout, default_name orelse "");
}

/// Build an owned device list from `pactl list short sinks|sources` text.
/// Pure: spawns nothing, so it is directly testable with fixtures.
pub fn buildDeviceList(allocator: std.mem.Allocator, list_text: []const u8, default_name: []const u8) !DeviceList {
    // Every parsed line yields at most one device, so the newline count bounds it.
    const capacity = std.mem.count(u8, list_text, "\n") + 1;
    const parsed = try allocator.alloc(device_parse.Device, capacity);
    defer allocator.free(parsed);
    const count = device_parse.parseShortList(list_text, default_name, parsed);

    var device_list: std.ArrayList(AudioDevice) = .empty;
    defer device_list.deinit(allocator);
    errdefer {
        for (device_list.items) |device| {
            device.deinit(allocator);
        }
    }

    for (parsed[0..count]) |entry| {
        const name = try allocator.dupeSentinel(u8, entry.name, 0);
        errdefer allocator.free(name);
        const description = try allocator.dupeSentinel(u8, entry.description, 0);
        errdefer allocator.free(description);

        try device_list.append(allocator, .{
            .name = name,
            .description = description,
            .index = entry.index,
            .is_default = entry.is_default,
        });
    }

    return DeviceList{
        .devices = try device_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Get the default device name for the given type
pub fn getDefaultDevice(allocator: std.mem.Allocator, device_type: DeviceType) ![]const u8 {
    const command = switch (device_type) {
        .output => &[_][]const u8{ "pactl", "get-default-sink" },
        .input => &[_][]const u8{ "pactl", "get-default-source" },
    };

    const stdout = sys.runCapture(allocator, command) catch |err| {
        log.warn("Failed to get default {s} device: {}", .{ @tagName(device_type), err });
        return error.DeviceQueryFailed;
    };
    defer allocator.free(stdout);

    const device_name = try allocator.dupe(u8, device_parse.parseDefaultName(stdout));

    return device_name;
}

const focusrite_sink_fixture =
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n" ++
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n";

const focusrite_sources_fixture =
    "5325\talsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Mic2__source\tPipeWire\tfloat32le 1ch 48000Hz\tSUSPENDED\n" ++
    "5328\talsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Mic1__source\tPipeWire\tfloat32le 1ch 48000Hz\tSUSPENDED\n" ++
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n";

test "buildDeviceList parses pactl fixtures without spawning" {
    // Fixture-driven; the spawning path is covered by enumerateDevices.
    const testing = std.testing;
    const allocator = testing.allocator;
    const focusrite_sink = "alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink";

    const sinks = try buildDeviceList(allocator, focusrite_sink_fixture, focusrite_sink);
    defer sinks.deinit();
    try testing.expectEqual(@as(usize, 1), sinks.devices.len);
    try testing.expectEqualStrings(focusrite_sink, sinks.devices[0].name);
    try testing.expectEqualStrings("Focusrite Scarlett Solo USB Line", sinks.devices[0].description);
    try testing.expectEqual(@as(u32, 5330), sinks.devices[0].index);
    try testing.expect(sinks.devices[0].is_default);

    const sources = try buildDeviceList(allocator, focusrite_sources_fixture, "");
    defer sources.deinit();
    try testing.expectEqual(@as(usize, 2), sources.devices.len);
    try testing.expectEqual(@as(u32, 5325), sources.devices[0].index);
    try testing.expectEqualStrings("Focusrite Scarlett Solo USB Mic2", sources.devices[0].description);
    try testing.expectEqual(@as(u32, 5328), sources.devices[1].index);
    for (sources.devices) |d| try testing.expect(!d.is_default);
}

test "enumerate devices" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Try to enumerate output devices (may fail if pactl not available)
    const devices = enumerateDevices(allocator, .output) catch |err| {
        std.debug.print("Device enumeration failed (expected in CI): {}\n", .{err});
        return;
    };
    defer devices.deinit();

    std.debug.print("Found {} output devices\n", .{devices.devices.len});
    for (devices.devices) |device| {
        std.debug.print("  Device: {s} (index {})\n", .{ device.name, device.index });
    }
}
