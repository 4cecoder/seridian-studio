//! Liquid-glass design tokens for the Seridian UI kit.
//!
//! Spec: docs/development/uikit.md. Base palette mirrors src/ui/palette.h.
//! Tokens are plain data. The helper functions (glassAlpha, clampFontSize,
//! clampRadius, withAlpha) are pure and have no Raven dependency; Raven calls
//! that apply these tokens live in src/uikit/style.zig.
const std = @import("std");
const testing = std.testing;

/// RGBA, each channel in [0, 1]. Same layout as SeridianColor in palette.h.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    /// 0xRRGGBB to an opaque colour.
    pub fn hex(rgb: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0,
        };
    }
};

// Dark base (palette.h: palette_void, palette_deep, palette_panel).
pub const bg_void = Color.hex(0x05060D);
pub const bg_deep = Color.hex(0x0A0B1A);
pub const bg_panel = Color.hex(0x10122A);

// Accent (active state) and secondaries.
pub const accent = Color.hex(0x00F0FF);
pub const accent_violet = Color.hex(0x7B2FFF);
pub const accent_magenta = Color.hex(0xFF2BD6);

// Text. `text` is high contrast on every glass layer.
pub const text = Color.hex(0xE6F7FF);
pub const text_muted = Color.hex(0x9AA7C4); // lighter than palette_muted so it stays readable at 12 px
pub const text_on_accent = bg_void;

// Status.
pub const success = Color.hex(0x3DDC97);
pub const warning = Color.hex(0xFFB347);
pub const danger = Color.hex(0xFF5E6C);

/// Light 1 px line on the top edge of every glass surface.
pub const highlight = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.18 };
pub const highlight_px: f32 = 1.0;

/// Soft shadow under a surface.
pub const shadow = Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.45 };
pub const shadow_blur_px: f32 = 18.0;
pub const shadow_offset_y_px: f32 = 6.0;

// Corner radii in logical px. Every surface radius is in [radius_min, radius_max].
pub const radius_min: f32 = 10.0;
pub const radius_max: f32 = 14.0;
pub const radius_control: f32 = 10.0;
pub const radius_popup: f32 = 12.0;
pub const radius_panel: f32 = 14.0;

/// Text is never drawn below this size (logical px).
pub const min_font_px: f32 = 12.0;
pub const font_body_px: f32 = 13.0;
pub const font_title_px: f32 = 16.0;

/// Duration of hover/press/active state transitions.
pub const transition_ms: u32 = 120;

/// Glass fill alpha range. Layers stack from base to overlay.
pub const glass_alpha_min: f32 = 0.55;
pub const glass_alpha_max: f32 = 0.75;

/// Backdrop blur radius behind panels (Rdraw_glass frost / Rbackground_blur).
pub const blur_radius_px: f32 = 18.0;

pub const GlassLayer = enum { base, raised, overlay };

/// Fill alpha for a layer: base 0.55, raised 0.65, overlay 0.75.
pub fn glassAlpha(layer: GlassLayer) f32 {
    return switch (layer) {
        .base => glass_alpha_min,
        .raised => 0.65,
        .overlay => glass_alpha_max,
    };
}

/// Raises sizes below min_font_px to min_font_px. NaN also gives min_font_px.
pub fn clampFontSize(px: f32) f32 {
    // Written as a negated >= so that NaN fails the test and takes the floor.
    if (!(px >= min_font_px)) return min_font_px;
    return px;
}

/// Clamps a corner radius into [radius_min, radius_max]. NaN gives radius_min.
pub fn clampRadius(r: f32) f32 {
    if (!(r >= radius_min)) return radius_min;
    if (r > radius_max) return radius_max;
    return r;
}

/// Same colour with alpha replaced, alpha clamped to [0, 1]. NaN gives 0.
pub fn withAlpha(c: Color, a: f32) Color {
    var out = c;
    if (!(a >= 0.0)) {
        out.a = 0.0;
    } else if (a > 1.0) {
        out.a = 1.0;
    } else {
        out.a = a;
    }
    return out;
}

fn approx(a: f32, b: f32) !void {
    // palette.h stores 3-digit floats, so compare to 1e-3.
    try testing.expectApproxEqAbs(a, b, 1e-3);
}

test "base palette matches palette.h" {
    try approx(bg_void.r, 0.020);
    try approx(bg_void.g, 0.024);
    try approx(bg_void.b, 0.051);
    try approx(bg_deep.b, 0.102);
    try approx(bg_panel.b, 0.165);
    try approx(accent.r, 0.0);
    try approx(accent.g, 0.941);
    try approx(accent.b, 1.0);
    try approx(text.r, 0.902);
}

test "all tokens are valid colours and the base is dark" {
    const all = [_]Color{ bg_void, bg_deep, bg_panel, accent, accent_violet, accent_magenta, text, text_muted, text_on_accent, success, warning, danger, highlight, shadow };
    for (all) |c| {
        for ([_]f32{ c.r, c.g, c.b, c.a }) |ch| {
            try testing.expect(ch >= 0.0 and ch <= 1.0);
        }
    }
    for ([_]Color{ bg_void, bg_deep, bg_panel }) |c| {
        try testing.expect(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.1);
        try approx(c.a, 1.0);
    }
}

test "text contrast against the panel is high" {
    const lum = struct {
        fn f(c: Color) f32 {
            return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        }
    }.f;
    try testing.expect((lum(text) + 0.05) / (lum(bg_panel) + 0.05) >= 7.0);
    try testing.expect((lum(text_muted) + 0.05) / (lum(bg_panel) + 0.05) >= 4.5);
}

test "radii lie in 10..14" {
    for ([_]f32{ radius_min, radius_max, radius_control, radius_popup, radius_panel }) |r| {
        try testing.expect(r >= 10.0 and r <= 14.0);
    }
    try testing.expect(radius_min < radius_max);
}

test "minimum font size is 12 and sizes respect it" {
    try approx(min_font_px, 12.0);
    try testing.expect(font_body_px >= min_font_px);
    try testing.expect(font_title_px >= min_font_px);
}

test "transition is 120 ms" {
    try testing.expectEqual(@as(u32, 120), transition_ms);
}

test "glass alpha range is 0.55..0.75 and highlight and shadow are set" {
    try approx(glass_alpha_min, 0.55);
    try approx(glass_alpha_max, 0.75);
    try testing.expect(highlight_px == 1.0 and highlight.a > 0.0);
    try testing.expect(shadow_blur_px > 0.0 and shadow_offset_y_px > 0.0);
}

test "glassAlpha steps through the range" {
    try approx(glassAlpha(.base), glass_alpha_min);
    try approx(glassAlpha(.overlay), glass_alpha_max);
    const mid = glassAlpha(.raised);
    try testing.expect(mid > glass_alpha_min and mid < glass_alpha_max);
}

test "clampFontSize never goes below 12" {
    try approx(clampFontSize(8.0), 12.0);
    try approx(clampFontSize(0.0), 12.0);
    try approx(clampFontSize(std.math.nan(f32)), 12.0);
    try approx(clampFontSize(12.0), 12.0);
    try approx(clampFontSize(20.0), 20.0);
}

test "clampRadius stays in 10..14" {
    try approx(clampRadius(0.0), 10.0);
    try approx(clampRadius(12.0), 12.0);
    try approx(clampRadius(40.0), 14.0);
}

test "withAlpha replaces and clamps alpha" {
    const c = withAlpha(accent, 0.6);
    try approx(c.a, 0.6);
    try approx(c.g, accent.g);
    try approx(withAlpha(accent, 2.0).a, 1.0);
    try approx(withAlpha(accent, -1.0).a, 0.0);
}
