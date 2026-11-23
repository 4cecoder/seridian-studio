//! uikit/container: glass card, collapsing section (Rexpander), tooltip, scroll area.
//!
//! Mode: retained. Every widget is a Raven widget created with Rwidget_create
//! or Rbackground_blur_create and placed in the tree. Nothing here repaints per
//! frame, so no paint callback (immediate mode) is used.
//!
//! Raven calls are declared in raven.zig (no @cImport).
//!
//! Known gaps against docs/development/uikit.md:
//!   - Raven has no per-widget millisecond transition. The motion preset is
//!     chosen by Raven; theme.transition_ms (120) is the target only.
//!   - The card outline is drawn all round at the highlight alpha, not only on
//!     the top edge. Raven has no top-edge-only rim.
//!   - Raven has no tooltip delay setter. TooltipConfig.delay_ms is kept for the
//!     spec but is not applied.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

// ---- Raven types (declared in raven.zig) ----

const Rid = raven.Rid;
const invalid = raven.invalid;

pub const ExpanderChangedCallback = raven.ExpanderChangedCallback;

// ---- helpers ----

/// Negative and NaN values become 0.
fn nonNegative(x: f32) f32 {
    if (!(x >= 0.0)) return 0.0;
    return x;
}

fn setCorners(border_or_blur: Rid, r: f32, is_blur: bool) void {
    if (is_blur) {
        raven.Rbackground_blur_set_corner_radius(border_or_blur, r, r, r, r);
    } else {
        raven.Rborder_set_corner_radius(border_or_blur, r, r, r, r);
    }
}

// ---- glass card ----

/// Glass card. A translucent layered panel with a 1 px light outline, a soft
/// shadow and a backdrop blur behind it.
pub const CardConfig = struct {
    layer: theme.GlassLayer = .base,
    padding: f32 = 14.0,
    radius: f32 = theme.radius_panel,
    blur: bool = true,
};

/// Card config with the spec limits applied: radius in 10..14, padding >= 0.
pub fn sanitizeCard(cfg: CardConfig) CardConfig {
    var out = cfg;
    out.padding = nonNegative(cfg.padding);
    out.radius = theme.clampRadius(cfg.radius);
    return out;
}

/// Fill alpha of the card for its layer, from the theme.
pub fn cardFillAlpha(cfg: CardConfig) f32 {
    return theme.glassAlpha(cfg.layer);
}

/// A built card. Add content to `body`. `root` is the widget to place in the tree.
pub const Card = struct {
    root: Rid,
    body: Rid,
};

/// Builds a glass card. With blur on, the root is a background blur whose child
/// is the glass border that holds the content.
pub fn createCard(cfg_in: CardConfig) Card {
    const cfg = sanitizeCard(cfg_in);
    const alpha = cardFillAlpha(cfg);
    const fill = theme.withAlpha(theme.bg_panel, alpha);
    const rim = theme.highlight;

    const border = raven.Rwidget_create(.border);
    raven.Rborder_set_padding(border, cfg.padding, cfg.padding, cfg.padding, cfg.padding);
    raven.Rborder_set_background(border, fill.r, fill.g, fill.b, fill.a);
    raven.Rborder_set_outline(border, theme.highlight_px, rim.r, rim.g, rim.b, rim.a);
    setCorners(border, cfg.radius, false);
    raven.Rborder_set_shadow(border, theme.shadow_blur_px, 0.0, theme.shadow_offset_y_px);
    raven.Rborder_set_material(border, .glass);

    if (!cfg.blur) return .{ .root = border, .body = border };

    const blur = raven.Rbackground_blur_create();
    raven.Rbackground_blur_set_style(blur, .glass);
    raven.Rbackground_blur_set_radius(blur, theme.blur_radius_px);
    raven.Rbackground_blur_set_tint(blur, fill.r, fill.g, fill.b, fill.a);
    setCorners(blur, cfg.radius, true);
    _ = raven.Rwidget_add_child(blur, border);
    return .{ .root = blur, .body = border };
}

// ---- collapsing section (Rexpander) ----

pub const ExpanderConfig = struct {
    title: [:0]const u8 = "",
    expanded: bool = true,
    font_px: f32 = theme.font_body_px,
};

/// Expander config with font size at least theme.min_font_px.
pub fn sanitizeExpander(cfg: ExpanderConfig) ExpanderConfig {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    return out;
}

/// Builds a collapsing section with `content` as its child. The title text is
/// the text colour; the accent colour marks the widget as active.
pub fn createExpander(cfg_in: ExpanderConfig, content: Rid) Rid {
    const cfg = sanitizeExpander(cfg_in);
    const expander = raven.Rwidget_create(.expander);
    raven.Rexpander_set_title(expander, cfg.title.ptr);
    raven.Rexpander_set_expanded(expander, @intFromBool(cfg.expanded));
    raven.Rwidget_set_metric(expander, .font_size, cfg.font_px);
    raven.Rwidget_set_color(expander, .text, theme.text.r, theme.text.g, theme.text.b, theme.text.a);
    raven.Rwidget_set_color(expander, .accent, theme.accent.r, theme.accent.g, theme.accent.b, theme.accent.a);
    _ = raven.Rwidget_add_child(expander, content);
    return expander;
}

/// Sets the callback for when the user opens or closes the section.
pub fn setExpanderChanged(expander: Rid, callback: ?ExpanderChangedCallback, user_data: ?*anyopaque) void {
    raven.Rexpander_set_changed_callback(expander, callback, user_data);
}

/// Whether the section is currently open.
pub fn isExpanded(expander: Rid) bool {
    return raven.Rexpander_is_expanded(expander) != 0;
}

// ---- tooltip ----

pub const TooltipConfig = struct {
    text: [:0]const u8 = "",
    font_px: f32 = theme.font_body_px,
    radius: f32 = theme.radius_popup,
    /// Not applied: Raven has no tooltip delay setter.
    delay_ms: u32 = 400,
};

/// Tooltip config: font at least 12, radius in 10..14.
pub fn sanitizeTooltip(cfg: TooltipConfig) TooltipConfig {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.radius = theme.clampRadius(cfg.radius);
    return out;
}

/// False when the text is empty: no tooltip is installed then.
pub fn shouldInstallTooltip(cfg: TooltipConfig) bool {
    return cfg.text.len != 0;
}

/// Installs a tooltip on `target`. Raven draws the popup. Its colours are the
/// glass overlay layer and the text colour; the popup radius and font size are
/// set from the config.
pub fn installTooltip(target: Rid, cfg_in: TooltipConfig) void {
    const cfg = sanitizeTooltip(cfg_in);
    if (!shouldInstallTooltip(cfg)) return;
    const fill = theme.withAlpha(theme.bg_panel, theme.glassAlpha(.overlay));
    raven.Rwidget_set_tooltip(target, cfg.text.ptr);
    raven.Rwidget_set_color(target, .tooltip, fill.r, fill.g, fill.b, fill.a);
    raven.Rwidget_set_color(target, .tooltip_text, theme.text.r, theme.text.g, theme.text.b, theme.text.a);
    raven.Rwidget_set_metric(target, .popup_radius, cfg.radius);
    raven.Rwidget_set_metric(target, .font_size, cfg.font_px);
}

// ---- scroll area ----

pub const Orientation = enum { vertical, horizontal };

pub const ScrollConfig = struct {
    orientation: Orientation = .vertical,
    /// Also scroll across the stacking direction when content is too large.
    both: bool = false,
    /// Gap between children, logical px.
    spacing: f32 = 8.0,
};

/// Scroll config with spacing >= 0.
pub fn sanitizeScroll(cfg: ScrollConfig) ScrollConfig {
    var out = cfg;
    out.spacing = nonNegative(cfg.spacing);
    return out;
}

/// Builds a scroll area. Add children with Rwidget_add_child.
pub fn createScrollArea(cfg_in: ScrollConfig) Rid {
    const cfg = sanitizeScroll(cfg_in);
    const area = raven.Rwidget_create(.scroll_box);
    const raven_orientation: raven.Orientation = switch (cfg.orientation) {
        .vertical => .vertical,
        .horizontal => .horizontal,
    };
    raven.Rscroll_box_set_orientation(area, raven_orientation);
    raven.Rscroll_box_set_scroll_both(area, @intFromBool(cfg.both));
    raven.Rpanel_set_spacing(area, cfg.spacing);
    return area;
}

// ---- spec tests ----

fn approx(a: f32, b: f32) !void {
    try testing.expectApproxEqAbs(a, b, 1e-3);
}

test "card configuration: defaults and clamping" {
    const d = CardConfig{};
    try testing.expectEqual(theme.GlassLayer.base, d.layer);
    try approx(d.padding, 14.0);
    try approx(d.radius, 14.0);
    try testing.expect(d.blur);

    try approx(sanitizeCard(.{ .radius = 40.0 }).radius, 14.0);
    try approx(sanitizeCard(.{ .radius = 2.0 }).radius, 10.0);
    try approx(sanitizeCard(.{ .padding = -5.0 }).padding, 0.0);
    try approx(sanitizeCard(.{ .padding = std.math.nan(f32) }).padding, 0.0);
    try approx(cardFillAlpha(.{ .layer = .base }), theme.glassAlpha(.base));
    try approx(cardFillAlpha(.{ .layer = .overlay }), theme.glassAlpha(.overlay));
}

test "expander configuration: defaults and font floor" {
    const d = ExpanderConfig{};
    try testing.expect(d.expanded);
    try approx(d.font_px, 13.0);
    try testing.expectEqualStrings("", d.title);

    try approx(sanitizeExpander(.{ .font_px = 9.0 }).font_px, 12.0);
    try approx(sanitizeExpander(.{ .font_px = 16.0 }).font_px, 16.0);
}

test "tooltip configuration: defaults and clamping" {
    const d = TooltipConfig{};
    try approx(d.font_px, 13.0);
    try approx(d.radius, 12.0);
    try testing.expectEqual(@as(u32, 400), d.delay_ms);

    try approx(sanitizeTooltip(.{ .font_px = 8.0 }).font_px, 12.0);
    try approx(sanitizeTooltip(.{ .radius = 40.0 }).radius, 14.0);
    try approx(sanitizeTooltip(.{ .radius = 0.0 }).radius, 10.0);
    try testing.expect(!shouldInstallTooltip(.{ .text = "" }));
    try testing.expect(shouldInstallTooltip(.{ .text = "Gain" }));
}

test "scroll area configuration: defaults and spacing floor" {
    const d = ScrollConfig{};
    try testing.expectEqual(Orientation.vertical, d.orientation);
    try testing.expect(!d.both);
    try approx(d.spacing, 8.0);

    try approx(sanitizeScroll(.{ .spacing = -3.0 }).spacing, 0.0);
    try approx(sanitizeScroll(.{ .spacing = 4.0 }).spacing, 4.0);
}
