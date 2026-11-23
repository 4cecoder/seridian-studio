// =============================================================================
// Audio Devices C API Bridge
// =============================================================================
// Exposes audio device enumeration to C code

const std = @import("std");
const devices = @import("devices.zig");

const DeviceType = devices.DeviceType;
const DeviceList = devices.DeviceList;

// =============================================================================
// Global State
// =============================================================================

var gpa_instance = std.heap.DebugAllocator(.{}){};
var global_allocator: std.mem.Allocator = undefined;
var allocator_initialized: bool = false;
var output_devices: ?DeviceList = null;
var input_devices: ?DeviceList = null;

/// Initialize the C API with an allocator
pub export fn audio_init_devices(allocator: ?*anyopaque) callconv(.c) void {
    if (allocator) |ptr| {
        const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ptr));
        global_allocator = alloc.*;
        allocator_initialized = true;
    } else {
        // No allocator provided, use internal GPA
        global_allocator = gpa_instance.allocator();
        allocator_initialized = true;
    }
}

// =============================================================================
// Device Enumeration
// =============================================================================

/// Enumerate output devices (sinks)
/// Returns count of devices found, or -1 on error
pub export fn audio_enumerate_output_devices() callconv(.c) c_int {
    if (output_devices) |dev_list| {
        dev_list.deinit();
    }

    output_devices = devices.enumerateDevices(global_allocator, .output) catch |err| {
        std.debug.print("Failed to enumerate output devices: {}\n", .{err});
        return -1;
    };

    return @intCast(output_devices.?.devices.len);
}

/// Enumerate input devices (sources)
/// Returns count of devices found, or -1 on error
pub export fn audio_enumerate_input_devices() callconv(.c) c_int {
    if (input_devices) |dev_list| {
        dev_list.deinit();
    }

    input_devices = devices.enumerateDevices(global_allocator, .input) catch |err| {
        std.debug.print("Failed to enumerate input devices: {}\n", .{err});
        return -1;
    };

    return @intCast(input_devices.?.devices.len);
}

// =============================================================================
// Device Information
// =============================================================================

/// Get device name by index from output devices
/// Returns pointer to internal string (valid until next enumeration)
pub export fn audio_get_output_device_name(index: c_int) callconv(.c) [*:0]const u8 {
    const dev_list = output_devices orelse return "Unknown";
    if (index < 0 or index >= dev_list.devices.len) return "Unknown";

    const device = dev_list.devices[@intCast(index)];
    return device.name.ptr;
}

/// Get device description by index from output devices
/// Returns pointer to internal string (valid until next enumeration)
pub export fn audio_get_output_device_description(index: c_int) callconv(.c) [*:0]const u8 {
    const dev_list = output_devices orelse return "Unknown";
    if (index < 0 or index >= dev_list.devices.len) return "Unknown";

    const device = dev_list.devices[@intCast(index)];
    return device.description.ptr;
}

/// Check if output device is default
/// Returns 1 if default, 0 otherwise
pub export fn audio_get_output_device_is_default(index: c_int) callconv(.c) c_int {
    const dev_list = output_devices orelse return 0;
    if (index < 0 or index >= dev_list.devices.len) return 0;

    const device = dev_list.devices[@intCast(index)];
    return if (device.is_default) 1 else 0;
}

/// Get device name by index from input devices
/// Returns pointer to internal string (valid until next enumeration)
pub export fn audio_get_input_device_name(index: c_int) callconv(.c) [*:0]const u8 {
    const dev_list = input_devices orelse return "Unknown";
    if (index < 0 or index >= dev_list.devices.len) return "Unknown";

    const device = dev_list.devices[@intCast(index)];
    return device.name.ptr;
}

/// Get device description by index from input devices
/// Returns pointer to internal string (valid until next enumeration)
pub export fn audio_get_input_device_description(index: c_int) callconv(.c) [*:0]const u8 {
    const dev_list = input_devices orelse return "Unknown";
    if (index < 0 or index >= dev_list.devices.len) return "Unknown";

    const device = dev_list.devices[@intCast(index)];
    return device.description.ptr;
}

/// Check if input device is default
/// Returns 1 if default, 0 otherwise
pub export fn audio_get_input_device_is_default(index: c_int) callconv(.c) c_int {
    const dev_list = input_devices orelse return 0;
    if (index < 0 or index >= dev_list.devices.len) return 0;

    const device = dev_list.devices[@intCast(index)];
    return if (device.is_default) 1 else 0;
}

// =============================================================================
// Cleanup
// =============================================================================

/// Free all allocated device lists
pub export fn audio_free_devices() callconv(.c) void {
    if (output_devices) |dev_list| {
        dev_list.deinit();
        output_devices = null;
    }

    if (input_devices) |dev_list| {
        dev_list.deinit();
        input_devices = null;
    }
}

// =============================================================================
// Tests
// =============================================================================

const test_sinks =
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n" ++
    "64\talsa_output.pci-0000_0b_00.3.iec958-stereo\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n";

/// The C side reads these as C strings, so the byte after the last character must be 0.
fn expectTerminated(c_str: [*:0]const u8, expected: []const u8) !void {
    const bytes: [*]const u8 = c_str;
    try std.testing.expectEqualStrings(expected, bytes[0..expected.len]);
    try std.testing.expectEqual(@as(u8, 0), bytes[expected.len]);
}

test "output device name and description handed to C are NUL-terminated" {
    audio_free_devices();
    defer audio_free_devices();
    output_devices = try devices.buildDeviceList(std.testing.allocator, test_sinks, "");

    const list = output_devices.?;
    try std.testing.expectEqual(@as(usize, 2), list.devices.len);
    for (list.devices, 0..) |device, i| {
        const index: c_int = @intCast(i);
        try expectTerminated(audio_get_output_device_name(index), device.name);
        try expectTerminated(audio_get_output_device_description(index), device.description);
    }
}

test "input device name and description handed to C are NUL-terminated" {
    audio_free_devices();
    defer audio_free_devices();
    input_devices = try devices.buildDeviceList(std.testing.allocator, test_sinks, "");

    const list = input_devices.?;
    try std.testing.expectEqual(@as(usize, 2), list.devices.len);
    for (list.devices, 0..) |device, i| {
        const index: c_int = @intCast(i);
        try expectTerminated(audio_get_input_device_name(index), device.name);
        try expectTerminated(audio_get_input_device_description(index), device.description);
    }
}
