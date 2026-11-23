//! uikit/basic: button (default, primary, flat), toggle switch, checkbox,
//! radio group and separator, in the liquid-glass style.
//!
//! Mode: retained for every widget here. Each one is a Raven widget made with
//! Rwidget_create (or an Rxxx_create shortcut) and placed in the tree. Nothing
//! in this file paints per frame, so there is no immediate-mode code.
//!
//! Raven calls are declared in raven.zig (no @cImport); this file only uses them.
//!
//! Style: colours and metrics are set through Rwidget_set_color and
//! Rwidget_set_metric, never painted by hand. Fills use the glass alphas from
//! theme.zig (0.55 base, 0.65 raised, 0.75 overlay). Corner radii are clamped
//! to 10..14. Text is never below theme.min_font_px (12). Accent marks the
//! active state. State transitions use Raven's springs; theme.transition_ms
//! (120 ms) is the target feel (see docs/development/uikit.md).
//!
//! Status: the configuration types, the pure helpers and the tests are
//! implemented. The create functions call Raven; they are type-checked by the
//! compile probe described in docs/development/uikit.md and not run here.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const style = @import("style.zig");
const raven = @import("raven.zig");

const Rid = raven.Rid;
const invalid = raven.invalid;
const ButtonStyle = raven.ButtonStyle;
const CheckboxStyle = raven.CheckboxStyle;
const ColorRole = raven.ColorRole;
const Orientation = raven.Orientation;
const ClickedCallback = raven.ClickedCallback;
const CheckboxChangedCallback = raven.CheckboxChangedCallback;
const setColor = style.setColor;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Glass fill alphas (theme.zig ranges: base 0.55, raised 0.65, overlay 0.75).
const alpha_base: f32 = theme.glass_alpha_min;
const alpha_raised: f32 = 0.65;
const alpha_overlay: f32 = theme.glass_alpha_max;

/// Ghost (flat) button hover fill.
const alpha_ghost_hover: f32 = theme.glass_alpha_min;

/// Separator line alpha.
const alpha_separator: f32 = 0.35;

/// Gap between radio options and between a checkbox mark and its label.
const spacing_px: f32 = 8.0;

// ---------------------------------------------------------------------------
// Button (Rbutton)
// ---------------------------------------------------------------------------

/// Public names follow the spec. In the task wording, "secondary" is `default`
/// (R_BUTTON_DEFAULT, filled glass) and "ghost" is `flat` (no fill until hovered).
pub const Variant = enum { default, primary, flat };

pub const Config = struct {
    text: [:0]const u8 = "",
    variant: Variant = .default,
    font_px: f32 = theme.font_body_px,
    radius: f32 = theme.radius_control,
    enabled: bool = true,
};

/// Clamped copy of a button config: font >= 12, radius in 10..14.
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.radius = theme.clampRadius(cfg.radius);
    return out;
}

/// Raven button style for a variant.
pub fn buttonStyle(variant: Variant) ButtonStyle {
    return switch (variant) {
        .default => .default,
        .primary => .primary,
        .flat => .flat,
    };
}

/// Creates an Rbutton in the glass style and returns its handle.
pub fn createButton(cfg_in: Config) Rid {
    const cfg = sanitize(cfg_in);
    const id = raven.Rbutton_create(cfg.text.ptr);
    if (id == invalid) return invalid;
    raven.Rbutton_set_style(id, buttonStyle(cfg.variant));
    raven.Rwidget_set_metric(id, .font_size, cfg.font_px);
    raven.Rwidget_set_metric(id, .corner_radius, cfg.radius);
    raven.Rwidget_set_enabled(id, @intFromBool(cfg.enabled));
    setColor(id, .shadow, theme.shadow);
    setColor(id, .focus, theme.accent);
    setColor(id, .text, theme.text);
    setColor(id, .text_disabled, theme.text_muted);
    switch (cfg.variant) {
        .default => {
            raven.Rwidget_set_material(id, .frosted_glass);
            setColor(id, .control, theme.withAlpha(theme.bg_panel, alpha_raised));
            setColor(id, .control_hovered, theme.withAlpha(theme.bg_panel, alpha_overlay));
            setColor(id, .control_pressed, theme.withAlpha(theme.bg_panel, alpha_base));
            setColor(id, .control_border, theme.highlight);
        },
        .primary => {
            raven.Rwidget_set_material(id, .tinted_glass);
            setColor(id, .accent, theme.withAlpha(theme.accent, alpha_overlay));
            setColor(id, .accent_hovered, theme.withAlpha(theme.accent, alpha_overlay));
            setColor(id, .accent_pressed, theme.withAlpha(theme.accent, alpha_base));
            setColor(id, .accent_text, theme.text_on_accent);
        },
        .flat => {
            raven.Rwidget_set_material(id, .default);
            setColor(id, .control, theme.withAlpha(theme.bg_panel, 0.0));
            setColor(id, .control_hovered, theme.withAlpha(theme.bg_panel, alpha_ghost_hover));
            setColor(id, .control_pressed, theme.withAlpha(theme.bg_panel, alpha_base));
            setColor(id, .control_border, theme.withAlpha(theme.bg_panel, 0.0));
        },
    }
    return id;
}

/// Wires the click handler of a button created by createButton.
pub fn setButtonClicked(id: Rid, callback: ?ClickedCallback, user_data: ?*anyopaque) void {
    raven.Rbutton_set_clicked_callback(id, callback, user_data);
}

// ---------------------------------------------------------------------------
// Toggle switch (Rcheckbox, R_CHECKBOX_SWITCH)
// ---------------------------------------------------------------------------

pub const ToggleConfig = struct {
    label: [:0]const u8 = "",
    on: bool = false,
    enabled: bool = true,
};

/// Raven checkbox style for the toggle switch.
pub fn toggleStyle() CheckboxStyle {
    return .@"switch";
}

/// Creates a switch in the glass style. Off track is glass, on track is accent.
pub fn createToggle(cfg: ToggleConfig) Rid {
    const id = raven.Rcheckbox_create(cfg.label.ptr);
    if (id == invalid) return invalid;
    raven.Rcheckbox_set_style(id, toggleStyle());
    raven.Rcheckbox_set_checked(id, @intFromBool(cfg.on));
    raven.Rwidget_set_enabled(id, @intFromBool(cfg.enabled));
    setColor(id, .@"switch", theme.withAlpha(theme.bg_panel, alpha_raised));
    setColor(id, .accent, theme.withAlpha(theme.accent, alpha_overlay));
    setColor(id, .handle, theme.text);
    setColor(id, .text, theme.text);
    setColor(id, .text_disabled, theme.text_muted);
    return id;
}

/// Wires the change handler of a switch created by createToggle.
pub fn setToggleChanged(id: Rid, callback: ?CheckboxChangedCallback, user_data: ?*anyopaque) void {
    raven.Rcheckbox_set_changed_callback(id, callback, user_data);
}

// ---------------------------------------------------------------------------
// Checkbox (Rcheckbox, R_CHECKBOX_CHECK)
// ---------------------------------------------------------------------------

pub const CheckboxConfig = struct {
    label: [:0]const u8 = "",
    checked: bool = false,
    font_px: f32 = theme.font_body_px,
    enabled: bool = true,
};

/// Clamped copy of a checkbox config: font >= 12.
pub fn sanitizeCheckbox(cfg: CheckboxConfig) CheckboxConfig {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    return out;
}

/// Creates a checkbox in the glass style. The check mark is accent.
pub fn createCheckbox(cfg_in: CheckboxConfig) Rid {
    const cfg = sanitizeCheckbox(cfg_in);
    const id = raven.Rcheckbox_create(cfg.label.ptr);
    if (id == invalid) return invalid;
    raven.Rcheckbox_set_style(id, .check);
    raven.Rcheckbox_set_checked(id, @intFromBool(cfg.checked));
    raven.Rwidget_set_enabled(id, @intFromBool(cfg.enabled));
    raven.Rwidget_set_metric(id, .font_size, cfg.font_px);
    raven.Rwidget_set_metric(id, .spacing, spacing_px);
    setColor(id, .accent, theme.accent);
    setColor(id, .control, theme.withAlpha(theme.bg_panel, alpha_raised));
    setColor(id, .control_border, theme.highlight);
    setColor(id, .text, theme.text);
    setColor(id, .text_disabled, theme.text_muted);
    return id;
}

/// Wires the change handler of a checkbox created by createCheckbox.
pub fn setCheckboxChanged(id: Rid, callback: ?CheckboxChangedCallback, user_data: ?*anyopaque) void {
    raven.Rcheckbox_set_changed_callback(id, callback, user_data);
}

// ---------------------------------------------------------------------------
// Radio group (VBox or HBox of Rcheckbox, R_CHECKBOX_RADIO)
// ---------------------------------------------------------------------------

pub const RadioConfig = struct {
    options: []const [:0]const u8 = &.{},
    selected: i32 = 0,
    horizontal: bool = false,
};

/// Index of the selected option, clamped to [0, count - 1]. -1 when count is 0.
pub fn clampSelected(selected: i32, count: usize) i32 {
    if (count == 0) return -1;
    const last_index: usize = count - 1;
    const last: i32 = @intCast(@min(last_index, std.math.maxInt(i32)));
    return std.math.clamp(selected, 0, last);
}

/// Creates a group: one Rcheckbox per option, all children of one box. Raven
/// unchecks the other radio boxes of the same parent, so only one is on.
/// Returns the box handle, or `invalid` if Raven fails to create a child.
pub fn createRadioGroup(cfg: RadioConfig) Rid {
    const group = raven.Rwidget_create(if (cfg.horizontal) .hbox else .vbox);
    if (group == invalid) return invalid;
    raven.Rwidget_set_metric(group, .spacing, spacing_px);
    const selected = clampSelected(cfg.selected, cfg.options.len);
    for (cfg.options, 0..) |option, i| {
        const child = raven.Rcheckbox_create(option.ptr);
        if (child == invalid) return invalid;
        raven.Rcheckbox_set_style(child, .radio);
        raven.Rcheckbox_set_checked(child, @intFromBool(@as(i32, @intCast(i)) == selected));
        setColor(child, .accent, theme.accent);
        setColor(child, .control_border, theme.highlight);
        setColor(child, .text, theme.text);
        if (raven.Rwidget_add_child(group, child) == invalid) return invalid;
    }
    return group;
}

/// Wires the change handler of every option of a group created by createRadioGroup.
pub fn setRadioChanged(group: Rid, callback: ?CheckboxChangedCallback, user_data: ?*anyopaque) void {
    const count = raven.Rwidget_get_child_count(group);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        raven.Rcheckbox_set_changed_callback(raven.Rwidget_get_child(group, i), callback, user_data);
    }
}

// ---------------------------------------------------------------------------
// Separator (Rseparator, R_WIDGET_SEPARATOR)
// ---------------------------------------------------------------------------

pub const SeparatorConfig = struct {
    vertical: bool = false,
    thickness: f32 = 1.0,
    inset: f32 = 8.0,
};

/// Clamped copy of a separator config: thickness in 1..2, inset >= 0.
pub fn sanitizeSeparator(cfg: SeparatorConfig) SeparatorConfig {
    var out = cfg;
    if (std.math.isNan(cfg.thickness) or cfg.thickness < 1.0) {
        out.thickness = 1.0;
    } else if (cfg.thickness > 2.0) {
        out.thickness = 2.0;
    }
    if (std.math.isNan(cfg.inset) or cfg.inset < 0.0) out.inset = 0.0;
    return out;
}

/// Creates a separator line. Thickness sets the minimum size across the line.
/// Inset is the slot padding at both ends along the line.
pub fn createSeparator(cfg_in: SeparatorConfig) Rid {
    const cfg = sanitizeSeparator(cfg_in);
    const id = raven.Rwidget_create(.separator);
    if (id == invalid) return invalid;
    if (cfg.vertical) {
        raven.Rseparator_set_orientation(id, .vertical);
        raven.Rwidget_set_min_size(id, cfg.thickness, 0.0);
        raven.Rslot_set_padding(id, 0.0, cfg.inset, 0.0, cfg.inset);
    } else {
        raven.Rseparator_set_orientation(id, .horizontal);
        raven.Rwidget_set_min_size(id, 0.0, cfg.thickness);
        raven.Rslot_set_padding(id, cfg.inset, 0.0, cfg.inset, 0.0);
    }
    setColor(id, .separator, theme.withAlpha(theme.text_muted, alpha_separator));
    return id;
}

// ---------------------------------------------------------------------------
// Tests (spec: docs/development/uikit.md, one test per widget config)
// ---------------------------------------------------------------------------

test "button configuration: defaults and clamping" {
    const defaults: Config = .{};
    try testing.expectEqual(Variant.default, defaults.variant);
    try testing.expectEqual(@as(f32, 10.0), defaults.radius);
    try testing.expectEqual(@as(f32, 13.0), defaults.font_px);
    try testing.expect(defaults.enabled);

    const small = sanitize(.{ .font_px = 8.0 });
    try testing.expectEqual(@as(f32, 12.0), small.font_px);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .font_px = std.math.nan(f32) }).font_px);

    try testing.expectEqual(@as(f32, 10.0), sanitize(.{ .radius = 0.0 }).radius);
    try testing.expectEqual(@as(f32, 14.0), sanitize(.{ .radius = 40.0 }).radius);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .radius = 12.0 }).radius);

    try testing.expectEqual(ButtonStyle.primary, buttonStyle(.primary));
    try testing.expectEqual(ButtonStyle.flat, buttonStyle(.flat));
    try testing.expectEqual(ButtonStyle.default, buttonStyle(.default));
}

test "toggle_switch configuration: defaults and clamping" {
    const defaults: ToggleConfig = .{};
    try testing.expect(!defaults.on);
    try testing.expect(defaults.enabled);
    try testing.expectEqual(@as(usize, 0), defaults.label.len);
    try testing.expectEqual(CheckboxStyle.@"switch", toggleStyle());
}

test "checkbox configuration: defaults and clamping" {
    const defaults: CheckboxConfig = .{};
    try testing.expect(!defaults.checked);
    try testing.expect(defaults.enabled);
    try testing.expectEqual(@as(f32, 13.0), defaults.font_px);

    try testing.expectEqual(@as(f32, 12.0), sanitizeCheckbox(.{ .font_px = 5.0 }).font_px);
    try testing.expectEqual(@as(f32, 15.0), sanitizeCheckbox(.{ .font_px = 15.0 }).font_px);
}

test "radio_group configuration: defaults and clamping" {
    const defaults: RadioConfig = .{};
    try testing.expectEqual(@as(usize, 0), defaults.options.len);
    try testing.expectEqual(@as(i32, 0), defaults.selected);
    try testing.expect(!defaults.horizontal);

    try testing.expectEqual(@as(i32, -1), clampSelected(0, 0));
    try testing.expectEqual(@as(i32, -1), clampSelected(3, 0));
    try testing.expectEqual(@as(i32, 0), clampSelected(-5, 3));
    try testing.expectEqual(@as(i32, 2), clampSelected(7, 3));
    try testing.expectEqual(@as(i32, 1), clampSelected(1, 3));
}

test "separator configuration: defaults and clamping" {
    const defaults: SeparatorConfig = .{};
    try testing.expect(!defaults.vertical);
    try testing.expectEqual(@as(f32, 1.0), defaults.thickness);
    try testing.expectEqual(@as(f32, 8.0), defaults.inset);

    try testing.expectEqual(@as(f32, 1.0), sanitizeSeparator(.{ .thickness = 0.0 }).thickness);
    try testing.expectEqual(@as(f32, 2.0), sanitizeSeparator(.{ .thickness = 9.0 }).thickness);
    try testing.expectEqual(@as(f32, 0.0), sanitizeSeparator(.{ .inset = -4.0 }).inset);
}
