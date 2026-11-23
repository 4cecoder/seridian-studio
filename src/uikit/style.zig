//! Applies the liquid-glass tokens from theme.zig to Raven widgets.
//!
//! Mode: retained. Every function here configures a Raven widget that already
//! exists in the tree (created with Rwidget_create or an Rxxx_create). Nothing
//! here paints, so there is no immediate-mode code in this file. The frosted
//! panel uses Raven's glass material and Rbackground_blur, not Rdraw_glass,
//! because Rdraw_glass only works inside a paint callback.
//!
//! Raven declarations are written by hand from vendor/raven/include/raven/*.h.
//! Raven-backed functions are only analysed when called, so the pure helpers
//! below can be tested with `zig test src/uikit/style.zig` without linking Raven.
const std = @import("std");
const theme = @import("theme.zig");
const raven = @import("raven.zig");

const testing = std.testing;

/// Tint strength of a frosted panel. Low, so the glass stays subtle.
pub const blur_tint_alpha: f32 = 0.30;

/// Fill of a glass surface at a given layer: the panel colour at the layer's alpha.
/// Pure. Alpha is always inside glass_alpha_min..glass_alpha_max.
pub fn glassFill(layer: theme.GlassLayer) theme.Color {
    return theme.withAlpha(theme.bg_panel, theme.glassAlpha(layer));
}

/// Clamps a size request to a finite, non-negative value. NaN, infinities that
/// would make layout unbounded, and negatives all become 0 or the largest finite
/// value. Pure.
pub fn sanitizeSize(v: f32) f32 {
    if (!std.math.isFinite(v)) {
        if (std.math.isNan(v) or v < 0.0) return 0.0;
        return std.math.floatMax(f32);
    }
    if (v < 0.0) return 0.0;
    return v;
}

/// Sets one colour role of a Raven widget. The colour is used as given, alpha included.
pub fn setColor(widget: raven.Rid, role: raven.ColorRole, c: theme.Color) void {
    raven.Rwidget_set_color(widget, role, c.r, c.g, c.b, c.a);
}

/// Sets a Raven widget's size request. Sizes are sanitized first.
pub fn sizeWidget(widget: raven.Rid, width: f32, height: f32) void {
    raven.Rwidget_set_size(widget, sanitizeSize(width), sanitizeSize(height));
}

const RoleColor = struct {
    role: raven.ColorRole,
    color: theme.Color,
};

/// Every colour role the glass theme sets. Each role appears once.
const glass_roles = [_]RoleColor{
    .{ .role = .window, .color = theme.bg_deep },
    .{ .role = .panel, .color = glassFill(.base) },
    .{ .role = .border, .color = theme.highlight },
    .{ .role = .text, .color = theme.text },
    .{ .role = .text_disabled, .color = theme.text_muted },
    .{ .role = .text_placeholder, .color = theme.text_muted },
    .{ .role = .accent, .color = theme.accent },
    .{ .role = .accent_hovered, .color = theme.accent },
    .{ .role = .accent_pressed, .color = theme.accent_violet },
    .{ .role = .accent_text, .color = theme.text_on_accent },
    .{ .role = .control, .color = glassFill(.raised) },
    .{ .role = .control_hovered, .color = glassFill(.overlay) },
    .{ .role = .control_pressed, .color = glassFill(.overlay) },
    .{ .role = .control_border, .color = theme.highlight },
    .{ .role = .input, .color = glassFill(.base) },
    .{ .role = .focus, .color = theme.accent },
    .{ .role = .selection, .color = theme.withAlpha(theme.accent, 0.35) },
    .{ .role = .row_hovered, .color = theme.withAlpha(theme.accent, 0.12) }, // ROW_HOVERED
    .{ .role = .track, .color = glassFill(.base) },
    .{ .role = .handle, .color = theme.accent },
    .{ .role = .handle_hovered, .color = theme.accent },
    .{ .role = .separator, .color = theme.withAlpha(theme.text, 0.12) },
    .{ .role = .header, .color = glassFill(.raised) }, // HEADER
    .{ .role = .header_hovered, .color = glassFill(.overlay) }, // HEADER_HOVERED
    .{ .role = .tab_active, .color = theme.accent }, // TAB_ACTIVE
    .{ .role = .popup, .color = glassFill(.overlay) },
    .{ .role = .popup_border, .color = theme.highlight },
    .{ .role = .shadow, .color = theme.shadow },
    .{ .role = .tooltip, .color = glassFill(.overlay) },
    .{ .role = .tooltip_text, .color = theme.text },
    .{ .role = .@"switch", .color = theme.accent },
    .{ .role = .success, .color = theme.success },
    .{ .role = .warning, .color = theme.warning },
    .{ .role = .danger, .color = theme.danger },
    .{ .role = .link, .color = theme.accent }, // LINK
    .{ .role = .code, .color = theme.text }, // CODE
};

/// Installs the dark glass theme and then the glass colour roles. Rtheme_apply
/// resets colours, so it runs first. Call once at startup, before widgets are
/// created.
pub fn applyGlassTheme() void {
    raven.Rtheme_apply(.glass_dark);
    for (glass_roles) |rc| {
        raven.Rtheme_set_color(rc.role, rc.color.r, rc.color.g, rc.color.b, rc.color.a);
    }
}

/// Styles a glass surface (a Raven Border): layered translucent fill, glass
/// material, rounded corners, a soft shadow below, and a 1 px top rim. The radius is clamped to
/// the 10..14 range.
pub fn styleGlassBorder(border: raven.Rid, layer: theme.GlassLayer, radius: f32) void {
    const fill = glassFill(layer);
    const r = theme.clampRadius(radius);
    raven.Rborder_set_background(border, fill.r, fill.g, fill.b, fill.a);
    raven.Rborder_set_corner_radius(border, r, r, r, r);
    raven.Rborder_set_shadow(border, theme.shadow_blur_px, 0.0, theme.shadow_offset_y_px);
    raven.Rborder_set_material(border, .glass);
    raven.Rwidget_set_metric(border, .glass_rim, theme.highlight_px);
}

/// Styles a backdrop blur behind a panel: glass blur at the theme radius, a
/// faint panel tint, and the shadow. The corner radius is clamped to 10..14.
pub fn styleBackgroundBlur(blur: raven.Rid, radius: f32) void {
    const r = theme.clampRadius(radius);
    const tint = theme.withAlpha(theme.bg_panel, blur_tint_alpha);
    raven.Rbackground_blur_set_style(blur, .glass);
    raven.Rbackground_blur_set_radius(blur, theme.blur_radius_px);
    raven.Rbackground_blur_set_tint(blur, tint.r, tint.g, tint.b, tint.a);
    raven.Rbackground_blur_set_shadow(blur, theme.shadow_blur_px);
    raven.Rbackground_blur_set_corner_radius(blur, r, r, r, r);
}

/// Sets a widget's font size, never below theme.min_font_px, and its corner
/// radius, clamped to 10..14.
pub fn styleControlMetrics(widget: raven.Rid, font_px: f32, radius: f32) void {
    raven.Rwidget_set_metric(widget, .font_size, theme.clampFontSize(font_px));
    raven.Rwidget_set_metric(widget, .corner_radius, theme.clampRadius(radius));
}

/// Styles a text label: high-contrast text colour and a size of at least 12 px.
pub fn styleLabel(label: raven.Rid, size_px: f32) void {
    const c = theme.text;
    raven.Rlabel_set_color(label, c.r, c.g, c.b, c.a);
    raven.Rlabel_set_text_size(label, theme.clampFontSize(size_px));
}

/// Marks a widget as active: accent fill with dark text on it.
pub fn styleActive(widget: raven.Rid) void {
    const a = theme.accent;
    const t = theme.text_on_accent;
    raven.Rwidget_set_color(widget, .accent, a.r, a.g, a.b, a.a);
    raven.Rwidget_set_color(widget, .accent_text, t.r, t.g, t.b, t.a);
}

// ---- tests (pure helpers only; no Raven symbols are referenced here) ----

test "glassFill uses the panel colour at the layer alpha" {
    for ([_]theme.GlassLayer{ .base, .raised, .overlay }) |layer| {
        const f = glassFill(layer);
        try testing.expectApproxEqAbs(theme.bg_panel.r, f.r, 1e-6);
        try testing.expectApproxEqAbs(theme.bg_panel.b, f.b, 1e-6);
        try testing.expectApproxEqAbs(theme.glassAlpha(layer), f.a, 1e-6);
        try testing.expect(f.a >= theme.glass_alpha_min and f.a <= theme.glass_alpha_max);
    }
}

test "sanitizeSize maps bad requests to finite non-negative sizes" {
    try testing.expectEqual(@as(f32, 0.0), sanitizeSize(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 0.0), sanitizeSize(-3.0));
    try testing.expectEqual(@as(f32, 12.0), sanitizeSize(12.0));
    try testing.expectEqual(std.math.floatMax(f32), sanitizeSize(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0.0), sanitizeSize(-std.math.inf(f32)));
}

test "every themed colour role is listed once" {
    for (glass_roles, 0..) |a, i| {
        for (glass_roles[i + 1 ..]) |b| {
            try testing.expect(a.role != b.role);
        }
    }
}

test "every themed colour is a valid colour" {
    for (glass_roles) |rc| {
        const c = rc.color;
        for ([_]f32{ c.r, c.g, c.b, c.a }) |ch| {
            try testing.expect(ch >= 0.0 and ch <= 1.0);
        }
    }
}
