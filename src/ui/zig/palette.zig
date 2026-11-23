//! Seridian Studio palette: dark cyberpunk base, neon cyan accent, and smooth gradients between deep violet and
//! cyan. Pure math, no UI dependencies, so the color rules are unit-tested (tests below, ported from
//! tests/ui/palette_test.c).
//!
//! Translated from src/ui/palette.h. Names are the C names so the window code reads the same.

const std = @import("std");

pub const SeridianColor = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Converts 0xRRGGBB to an opaque color.
pub fn palette_from_hex(rgb: u32) SeridianColor {
    return .{
        .r = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0,
        .a = 1.0,
    };
}

pub fn palette_clamp01(value: f32) f32 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

pub fn palette_lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * t;
}

/// Blends two colors; t is clamped to [0, 1] so the ends are exact.
pub fn palette_gradient_sample(from: SeridianColor, to: SeridianColor, t: f32) SeridianColor {
    const k = palette_clamp01(t);
    return .{
        .r = palette_lerp(from.r, to.r, k),
        .g = palette_lerp(from.g, to.g, k),
        .b = palette_lerp(from.b, to.b, k),
        .a = palette_lerp(from.a, to.a, k),
    };
}

/// Glow halo: keeps the hue, fades alpha from 0.6 at the source to 0 at distance 1.
pub fn palette_glow(source: SeridianColor, distance: f32) SeridianColor {
    var color = source;
    color.a = 0.6 * (1.0 - palette_clamp01(distance));
    return color;
}

// Base surfaces: near-black with a blue-violet cast.
pub const palette_void: SeridianColor = .{ .r = 0.020, .g = 0.024, .b = 0.051, .a = 1.0 }; // #05060D
pub const palette_deep: SeridianColor = .{ .r = 0.039, .g = 0.043, .b = 0.102, .a = 1.0 }; // #0A0B1A
pub const palette_panel: SeridianColor = .{ .r = 0.063, .g = 0.071, .b = 0.165, .a = 1.0 }; // #10122A

/// Signature accent.
pub const palette_neon_cyan: SeridianColor = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 }; // #00F0FF

// Secondary neon for gradient ends.
pub const palette_neon_magenta: SeridianColor = .{ .r = 1.000, .g = 0.169, .b = 0.839, .a = 1.0 }; // #FF2BD6
pub const palette_violet: SeridianColor = .{ .r = 0.482, .g = 0.184, .b = 1.000, .a = 1.0 }; // #7B2FFF

pub const palette_text: SeridianColor = .{ .r = 0.902, .g = 0.969, .b = 1.000, .a = 1.0 }; // #E6F7FF
pub const palette_muted: SeridianColor = .{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 }; // #6B7A99

/// Choices offered by the track color menu (right-click a track). Neon green is deliberately absent.
pub const SeridianTrackColor = extern struct {
    name: [*c]const u8,
    color: SeridianColor,
};

pub const PALETTE_TRACK_COLOR_COUNT = 8;

pub const palette_track_colors = [PALETTE_TRACK_COLOR_COUNT]SeridianTrackColor{
    .{ .name = "Neon Cyan", .color = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 } },
    .{ .name = "Magenta", .color = .{ .r = 1.000, .g = 0.169, .b = 0.839, .a = 1.0 } },
    .{ .name = "Violet", .color = .{ .r = 0.482, .g = 0.184, .b = 1.000, .a = 1.0 } },
    .{ .name = "Amber", .color = .{ .r = 1.000, .g = 0.702, .b = 0.278, .a = 1.0 } },
    .{ .name = "Coral", .color = .{ .r = 1.000, .g = 0.369, .b = 0.424, .a = 1.0 } },
    .{ .name = "Electric Blue", .color = .{ .r = 0.239, .g = 0.482, .b = 1.000, .a = 1.0 } },
    .{ .name = "Ice", .color = .{ .r = 0.902, .g = 0.969, .b = 1.000, .a = 1.0 } },
    .{ .name = "Rose", .color = .{ .r = 1.000, .g = 0.545, .b = 0.749, .a = 1.0 } },
};

/// Bounds-checked lookup; null for an index outside the table. The pointer is to static data.
pub fn palette_track_color_at(index: c_int) [*c]const SeridianTrackColor {
    if (index < 0 or index >= PALETTE_TRACK_COLOR_COUNT) return null;
    return &palette_track_colors[@intCast(index)];
}
