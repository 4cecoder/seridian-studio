/// Simple program to list audio devices
/// Usage: zig run src/audio/list_devices.zig
const std = @import("std");
const devices = @import("devices.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Audio Device Enumeration ===\n\n", .{});

    // List output devices
    std.debug.print("Output Devices (Sinks):\n", .{});
    std.debug.print("{s}\n", .{&@as([60]u8, @splat('-'))});

    const outputs = devices.enumerateDevices(allocator, .output) catch |err| {
        std.debug.print("Failed to enumerate output devices: {}\n", .{err});
        std.debug.print("Is PulseAudio/PipeWire running?\n", .{});
        return err;
    };
    defer outputs.deinit();

    if (outputs.devices.len == 0) {
        std.debug.print("  No output devices found\n", .{});
    } else {
        for (outputs.devices, 0..) |device, i| {
            std.debug.print("  [{}] {s}\n", .{ i + 1, device.name });
            std.debug.print("      Index: {}\n", .{device.index});
            std.debug.print("      Description: {s}\n", .{device.description});
            std.debug.print("\n", .{});
        }
    }

    // Get default output device
    const default_output = devices.getDefaultDevice(allocator, .output) catch |err| {
        std.debug.print("Failed to get default output device: {}\n\n", .{err});
        return;
    };
    defer allocator.free(default_output);

    std.debug.print("Default Output Device: {s}\n\n", .{default_output});

    // List input devices
    std.debug.print("Input Devices (Sources):\n", .{});
    std.debug.print("{s}\n", .{&@as([60]u8, @splat('-'))});

    const inputs = devices.enumerateDevices(allocator, .input) catch |err| {
        std.debug.print("Failed to enumerate input devices: {}\n", .{err});
        return err;
    };
    defer inputs.deinit();

    if (inputs.devices.len == 0) {
        std.debug.print("  No input devices found\n", .{});
    } else {
        for (inputs.devices, 0..) |device, i| {
            std.debug.print("  [{}] {s}\n", .{ i + 1, device.name });
            std.debug.print("      Index: {}\n", .{device.index});
            std.debug.print("      Description: {s}\n", .{device.description});
            std.debug.print("\n", .{});
        }
    }

    // Get default input device
    const default_input = devices.getDefaultDevice(allocator, .input) catch |err| {
        std.debug.print("Failed to get default input device: {}\n\n", .{err});
        return;
    };
    defer allocator.free(default_input);

    std.debug.print("Default Input Device: {s}\n\n", .{default_input});
}
