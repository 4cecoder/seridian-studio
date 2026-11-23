//! Palette rules (ported from tests/ui/palette_test.c, every assertion kept).

const std = @import("std");
const palette = @import("ui_impl").palette;
const expect = std.testing.expect;

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "hex parsing" {
    const c = palette.palette_from_hex(0x00F0FF);
    try expectNear(c.r, 0.0, 1e-6);
    try expectNear(c.g, 240.0 / 255.0, 1e-6);
    try expectNear(c.b, 1.0, 1e-6);
    try expectNear(c.a, 1.0, 1e-6);
}

test "neon cyan is the accent" {
    // The signature accent must be bright, saturated cyan: high green and blue, no red.
    try expectNear(palette.palette_neon_cyan.r, 0.0, 1e-6);
    try expect(palette.palette_neon_cyan.g > 0.9);
    try expect(palette.palette_neon_cyan.b > 0.9);
}

test "backgrounds are dark" {
    // Every base surface stays dark so neon elements carry the contrast.
    try expect(palette.palette_void.r + palette.palette_void.g + palette.palette_void.b < 0.15);
    try expect(palette.palette_deep.r + palette.palette_deep.g + palette.palette_deep.b < 0.25);
    try expect(palette.palette_panel.r + palette.palette_panel.g + palette.palette_panel.b < 0.35);
}

test "gradient endpoints" {
    const from = palette.palette_from_hex(0x101020);
    const to = palette.palette_from_hex(0x2A0A40);
    const start = palette.palette_gradient_sample(from, to, 0.0);
    const end = palette.palette_gradient_sample(from, to, 1.0);
    try expectNear(start.r, from.r, 1e-6);
    try expectNear(start.b, from.b, 1e-6);
    try expectNear(end.r, to.r, 1e-6);
    try expectNear(end.b, to.b, 1e-6);
}

test "gradient is smooth and clamped" {
    const from = palette.palette_from_hex(0x000000);
    const to = palette.palette_from_hex(0xFFFFFF);
    const mid = palette.palette_gradient_sample(from, to, 0.5);
    try expectNear(mid.g, 0.5, 1e-3);
    // Out-of-range positions clamp to the endpoints instead of overshooting.
    const below = palette.palette_gradient_sample(from, to, -3.0);
    const above = palette.palette_gradient_sample(from, to, 7.0);
    try expectNear(below.g, 0.0, 1e-6);
    try expectNear(above.g, 1.0, 1e-6);
}

test "glow fades to transparent" {
    const glow_near = palette.palette_glow(palette.palette_neon_cyan, 0.0);
    const glow_far = palette.palette_glow(palette.palette_neon_cyan, 1.0);
    try expectNear(glow_near.a, 0.6, 1e-6);
    try expectNear(glow_far.a, 0.0, 1e-6);
    try expectNear(glow_near.g, palette.palette_neon_cyan.g, 1e-6);
}

fn isNeonGreen(c: palette.SeridianColor) bool {
    return c.g > 0.85 and c.r < 0.85 and c.b < 0.5;
}

test "track color set has enough choices" {
    // Ableton-style picker: at least eight distinct choices for tracks.
    try expect(palette.PALETTE_TRACK_COLOR_COUNT >= 8);
}

test "track colors are opaque and named" {
    for (0..palette.PALETTE_TRACK_COLOR_COUNT) |i| {
        try expectNear(palette.palette_track_colors[i].color.a, 1.0, 1e-6);
        try expect(palette.palette_track_colors[i].name != null);
        try expect(palette.palette_track_colors[i].name[0] != 0);
    }
}

test "track colors are distinct" {
    for (0..palette.PALETTE_TRACK_COLOR_COUNT) |i| {
        for (i + 1..palette.PALETTE_TRACK_COLOR_COUNT) |j| {
            const a = palette.palette_track_colors[i].color;
            const b = palette.palette_track_colors[j].color;
            const distance = @abs(a.r - b.r) + @abs(a.g - b.g) + @abs(a.b - b.b);
            try expect(distance > 0.25);
        }
    }
}

test "no track color is neon green" {
    for (0..palette.PALETTE_TRACK_COLOR_COUNT) |i| {
        try expect(!isNeonGreen(palette.palette_track_colors[i].color));
    }
}

test "track color lookup is bounded" {
    try expect(palette.palette_track_color_at(-1) == null);
    try expect(palette.palette_track_color_at(palette.PALETTE_TRACK_COLOR_COUNT) == null);
    try expect(palette.palette_track_color_at(0) != null);
}
