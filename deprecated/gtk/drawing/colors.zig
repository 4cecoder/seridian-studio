/// Tokyo Night color palette and color utilities
const std = @import("std");

/// RGB color with optional alpha channel
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    /// Create color from 24-bit hex value (0xRRGGBB)
    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f64, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f64, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f64, @floatFromInt(hex & 0xFF)) / 255.0,
        };
    }

    /// Create new color with different alpha
    pub fn withAlpha(self: Color, alpha: f64) Color {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = alpha,
        };
    }

    /// Multiply color channels by factor (for gamma/brightness)
    pub fn multiply(self: Color, factor: f64) Color {
        return .{
            .r = self.r * factor,
            .g = self.g * factor,
            .b = self.b * factor,
            .a = self.a,
        };
    }

    /// Linear interpolation between two colors
    pub fn lerp(a: Color, b: Color, t: f64) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }
};

// Tokyo Night Color Palette
pub const TOKYO_BG = Color.fromHex(0x1a1b26);
pub const TOKYO_BG_DARK = Color.fromHex(0x16161e);
pub const TOKYO_BG_HIGHLIGHT = Color.fromHex(0x292e42);
pub const TOKYO_FG = Color.fromHex(0xc0caf5);
pub const TOKYO_FG_DARK = Color.fromHex(0xa9b1d6);
pub const TOKYO_COMMENT = Color.fromHex(0x565f89);
pub const TOKYO_CYAN = Color.fromHex(0x7dcfff);
pub const TOKYO_GREEN = Color.fromHex(0x9ece6a);
pub const TOKYO_ORANGE = Color.fromHex(0xff9e64);
pub const TOKYO_PURPLE = Color.fromHex(0xbb9af7);
pub const TOKYO_RED = Color.fromHex(0xf7768e);
pub const TOKYO_YELLOW = Color.fromHex(0xe0af68);
pub const TOKYO_BLUE = Color.fromHex(0x7aa2f7);

// Audio-specific colors
pub const METER_GREEN = TOKYO_GREEN; // Safe level
pub const METER_YELLOW = TOKYO_YELLOW; // Warning level
pub const METER_RED = TOKYO_RED; // Clipping
pub const METER_PEAK = TOKYO_CYAN; // Peak indicator
pub const PLAYHEAD = TOKYO_RED; // Playhead position
pub const GRID_MAJOR = TOKYO_BLUE; // Bar lines
pub const GRID_MINOR = TOKYO_BG_HIGHLIGHT; // Beat lines

test "color from hex" {
    const white = Color.fromHex(0xFFFFFF);
    try std.testing.expectApproxEqRel(1.0, white.r, 0.01);
    try std.testing.expectApproxEqRel(1.0, white.g, 0.01);
    try std.testing.expectApproxEqRel(1.0, white.b, 0.01);

    const black = Color.fromHex(0x000000);
    try std.testing.expectApproxEqRel(0.0, black.r, 0.01);
    try std.testing.expectApproxEqRel(0.0, black.g, 0.01);
    try std.testing.expectApproxEqRel(0.0, black.b, 0.01);
}

test "color with alpha" {
    const color = TOKYO_RED.withAlpha(0.5);
    try std.testing.expectApproxEqRel(0.5, color.a, 0.01);
    try std.testing.expectApproxEqRel(TOKYO_RED.r, color.r, 0.01);
}

test "color lerp" {
    const black = Color.fromHex(0x000000);
    const white = Color.fromHex(0xFFFFFF);

    const gray = Color.lerp(black, white, 0.5);
    try std.testing.expectApproxEqRel(0.5, gray.r, 0.01);
    try std.testing.expectApproxEqRel(0.5, gray.g, 0.01);
    try std.testing.expectApproxEqRel(0.5, gray.b, 0.01);
}
