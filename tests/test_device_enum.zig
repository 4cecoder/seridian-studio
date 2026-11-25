/// Simple device enumeration test
/// Verifies that audio device listing works
const std = @import("std");
const devices = @import("audio/devices.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== OUTPUT DEVICES ===\n", .{});

    const output_devices = devices.enumerateDevices(allocator, .output) catch |err| {
        std.debug.print("Failed to enumerate output devices: {}\n", .{err});
        return err;
    };
    defer output_devices.deinit();

    for (output_devices.devices) |device| {
        const default_marker: []const u8 = if (device.is_default) " [DEFAULT]" else "";
        std.debug.print("{d}: {s}{s}\n", .{ device.index, device.description, default_marker });
    }

    std.debug.print("\n=== INPUT DEVICES ===\n", .{});

    const input_devices = devices.enumerateDevices(allocator, .input) catch |err| {
        std.debug.print("Failed to enumerate input devices: {}\n", .{err});
        return err;
    };
    defer input_devices.deinit();

    for (input_devices.devices) |device| {
        const default_marker: []const u8 = if (device.is_default) " [DEFAULT]" else "";
        std.debug.print("{d}: {s}{s}\n", .{ device.index, device.description, default_marker });
    }

    std.debug.print("\n", .{});
}
