// Translated to Zig from vendor/raven/src/widget/style.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/style.c
// The built-in themes, and how a widget finds its colors and metrics: its
// own overrides, then the styles of its theme, then the theme. Named themes,
// styles and theme files are in theme.c.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const handle_h = @import("../core/handle_h.zig");
const widget_h = @import("widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const libc = @import("../sys/libc.zig");

inline fn RVN_COLOR_INDEX(role: anytype) c_int {
    return @as(c_int, @intCast(role)) - raven.R_COLOR_WINDOW;
}

inline fn RVN_METRIC_INDEX(metric: anytype) c_int {
    return @as(c_int, @intCast(metric)) - raven.R_METRIC_FONT_SIZE;
}

fn rvn_color_valid(role: raven.RColorRole) c_int {
    return @intFromBool(role >= raven.R_COLOR_WINDOW and role < raven.R_COLOR_LAST_);
}

fn rvn_metric_valid(metric: raven.RMetric) c_int {
    return @intFromBool(metric >= raven.R_METRIC_FONT_SIZE and metric < raven.R_METRIC_LAST_);
}

// ---------------------------------------------------------------------------
//  Built-in themes
// ---------------------------------------------------------------------------

const rvn_palette_entry_t = struct {
    role: raven.RColorRole,
    rgb: u32,
    alpha: u32,
};

const g_dark_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0x1E1E20, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0x27272A, .alpha = 255 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0x3F3F46, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0xD8D8DC, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0x6C6C74, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0x7C7C86, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x3B82F6, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x5A9AFA, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x2B6CD8, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0x35353A, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0x424248, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0x2B2B30, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0x4C4C54, .alpha = 255 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0x161618, .alpha = 255 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0x3B82F6, .alpha = 255 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0x274B7A, .alpha = 255 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0x2E2E33, .alpha = 255 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0x2C2C30, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0x5C5C66, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0x7C7C88, .alpha = 255 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0x3F3F46, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0x2D2D31, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0x3A3A40, .alpha = 255 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0x1E1E20, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0x2B2B2F, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0x4A4A52, .alpha = 255 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 120 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0x3C3C42, .alpha = 255 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0xE6E6EA, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x3B82F6, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x3FB950, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0xD29922, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xF85149, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0x6CB0FF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0x141416, .alpha = 255 },
};

// High contrast: every pair of text and background above 7:1 (WCAG AAA).
const g_hc_dark_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0x3FF23F, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0xC0C0C0, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x1AEBFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x7DF3FF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x00B3C4, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0x1A1A1A, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0x333333, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0xFFFF00, .alpha = 255 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0x1AEBFF, .alpha = 140 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0x262626, .alpha = 255 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0xFFFF00, .alpha = 255 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0x1A1A1A, .alpha = 255 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0x1AEBFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 0 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x1AEBFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x3FF23F, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0xFFFF00, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xFF6B6B, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0xFFFF00, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0x000000, .alpha = 255 },
};

const g_hc_light_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0x600000, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0x404040, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x1C00A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x2D14D0, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x10006B, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0xE6E6E6, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0xCCCCCC, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0x1C00A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0x37006E, .alpha = 90 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0xE6E6E6, .alpha = 255 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0x1C00A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0xE6E6E6, .alpha = 255 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0x1C00A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 0 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0x000000, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x1C00A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x005A00, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0x6B4A00, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xA30000, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0x00009F, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0xFFFFFF, .alpha = 255 },
};

const g_light_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0xF3F3F5, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0xD0D0D6, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0x1F1F23, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0xA0A0A8, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0x90909A, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x2563EB, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x3B7BF5, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x1D4FC4, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0xE7E7EB, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0xDBDBE1, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0xCBCBD3, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0xC2C2CA, .alpha = 255 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0x2563EB, .alpha = 255 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0xBBD4FB, .alpha = 255 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0xE9EEF6, .alpha = 255 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0xDDDDE2, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0xA9A9B2, .alpha = 255 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0x8A8A94, .alpha = 255 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0xD0D0D6, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0xE9E9ED, .alpha = 255 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0xDDDDE3, .alpha = 255 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0xF3F3F5, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0xC8C8D0, .alpha = 255 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 60 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0x2B2B30, .alpha = 255 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0xF2F2F5, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x2563EB, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x1A7F37, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0x9A6700, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xCF222E, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0x0B62D6, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0xE6E6EB, .alpha = 255 },
};

// Glass themes. Most surfaces are translucent: the alpha of a color is how
// much of it is laid over what shows through. Glass surfaces use these colors
// as their tint (CONTROL, ACCENT, INPUT, PANEL, POPUP: see widgets/common.c).
const g_glass_dark_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0x2A2A2E, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0x3A3A3F, .alpha = 110 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0xFFFFFF, .alpha = 34 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0xF5F5F7, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0xEBEBF5, .alpha = 80 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0xEBEBF5, .alpha = 120 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x0A84FF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x409CFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x0A6FDB, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0xFFFFFF, .alpha = 28 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0xFFFFFF, .alpha = 46 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0xFFFFFF, .alpha = 66 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0xFFFFFF, .alpha = 60 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0x1A1A1D, .alpha = 90 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0x0A84FF, .alpha = 210 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0x0A84FF, .alpha = 130 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0xFFFFFF, .alpha = 20 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0xFFFFFF, .alpha = 40 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0xFFFFFF, .alpha = 90 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0xFFFFFF, .alpha = 140 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0xFFFFFF, .alpha = 30 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0xFFFFFF, .alpha = 16 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0xFFFFFF, .alpha = 30 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0xFFFFFF, .alpha = 52 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0x333337, .alpha = 190 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0xFFFFFF, .alpha = 40 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 110 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0x333337, .alpha = 200 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0xF5F5F7, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x30D158, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x30D158, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0xFFD60A, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xFF453A, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0x6CB6FF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0x1A1A1D, .alpha = 110 },
};

const g_glass_light_palette = [_]rvn_palette_entry_t{
    .{ .role = raven.R_COLOR_WINDOW, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_PANEL, .rgb = 0xFFFFFF, .alpha = 105 },
    .{ .role = raven.R_COLOR_BORDER, .rgb = 0x3C3C43, .alpha = 40 },
    .{ .role = raven.R_COLOR_TEXT, .rgb = 0x1C1C1E, .alpha = 255 },
    .{ .role = raven.R_COLOR_TEXT_DISABLED, .rgb = 0x3C3C43, .alpha = 90 },
    .{ .role = raven.R_COLOR_TEXT_PLACEHOLDER, .rgb = 0x3C3C43, .alpha = 130 },
    .{ .role = raven.R_COLOR_ACCENT, .rgb = 0x007AFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_HOVERED, .rgb = 0x2E90FF, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_PRESSED, .rgb = 0x0066D6, .alpha = 255 },
    .{ .role = raven.R_COLOR_ACCENT_TEXT, .rgb = 0xFFFFFF, .alpha = 255 },
    .{ .role = raven.R_COLOR_CONTROL, .rgb = 0xFFFFFF, .alpha = 120 },
    .{ .role = raven.R_COLOR_CONTROL_HOVERED, .rgb = 0xFFFFFF, .alpha = 165 },
    .{ .role = raven.R_COLOR_CONTROL_PRESSED, .rgb = 0xFFFFFF, .alpha = 205 },
    .{ .role = raven.R_COLOR_CONTROL_BORDER, .rgb = 0x3C3C43, .alpha = 46 },
    .{ .role = raven.R_COLOR_INPUT, .rgb = 0xFFFFFF, .alpha = 110 },
    .{ .role = raven.R_COLOR_FOCUS, .rgb = 0x007AFF, .alpha = 210 },
    .{ .role = raven.R_COLOR_SELECTION, .rgb = 0x007AFF, .alpha = 80 },
    .{ .role = raven.R_COLOR_ROW_HOVERED, .rgb = 0x3C3C43, .alpha = 16 },
    .{ .role = raven.R_COLOR_TRACK, .rgb = 0x787880, .alpha = 52 },
    .{ .role = raven.R_COLOR_HANDLE, .rgb = 0x3C3C43, .alpha = 80 },
    .{ .role = raven.R_COLOR_HANDLE_HOVERED, .rgb = 0x3C3C43, .alpha = 130 },
    .{ .role = raven.R_COLOR_SEPARATOR, .rgb = 0x3C3C43, .alpha = 46 },
    .{ .role = raven.R_COLOR_HEADER, .rgb = 0x3C3C43, .alpha = 12 },
    .{ .role = raven.R_COLOR_HEADER_HOVERED, .rgb = 0x3C3C43, .alpha = 26 },
    .{ .role = raven.R_COLOR_TAB_ACTIVE, .rgb = 0xFFFFFF, .alpha = 215 },
    .{ .role = raven.R_COLOR_POPUP, .rgb = 0xFAFAFA, .alpha = 160 },
    .{ .role = raven.R_COLOR_POPUP_BORDER, .rgb = 0x3C3C43, .alpha = 30 },
    .{ .role = raven.R_COLOR_SHADOW, .rgb = 0x000000, .alpha = 46 },
    .{ .role = raven.R_COLOR_TOOLTIP, .rgb = 0xFAFAFA, .alpha = 185 },
    .{ .role = raven.R_COLOR_TOOLTIP_TEXT, .rgb = 0x1C1C1E, .alpha = 255 },
    .{ .role = raven.R_COLOR_SWITCH, .rgb = 0x34C759, .alpha = 255 },
    .{ .role = raven.R_COLOR_SUCCESS, .rgb = 0x248A3D, .alpha = 255 },
    .{ .role = raven.R_COLOR_WARNING, .rgb = 0xB25000, .alpha = 255 },
    .{ .role = raven.R_COLOR_DANGER, .rgb = 0xD70015, .alpha = 255 },
    .{ .role = raven.R_COLOR_LINK, .rgb = 0x0066CC, .alpha = 255 },
    .{ .role = raven.R_COLOR_CODE, .rgb = 0x3C3C43, .alpha = 24 },
};

// Same order as RMetric.
const g_flat_metrics: [raven.R_METRIC_COUNT]f32 = .{
    13.0, // font size
    4.0, // corner radius
    1.0, // border width
    26.0, // control height
    10.0, // padding x
    4.0, // padding y
    6.0, // spacing
    10.0, // scrollbar size
    22.0, // row height
    16.0, // indent
    5.0, // splitter size
    16.0, // check size
    14.0, // slider handle size
    6.0, // popup radius
    1.0, 1.0, 1.0, 1.0, 1.0, // glass: frost, refraction, saturation, rim, shadow
    18.0, // blur radius
};

// High contrast: the flat metrics with thick borders.
const g_hc_metrics: [raven.R_METRIC_COUNT]f32 = .{
    15.0, // font size
    3.0, // corner radius
    2.0, // border width
    30.0, // control height
    10.0, // padding x
    5.0, // padding y
    6.0, // spacing
    14.0, // scrollbar size
    26.0, // row height
    18.0, // indent
    6.0, // splitter size
    18.0, // check size
    18.0, // slider handle size
    3.0, // popup radius
    1.0, 1.0, 1.0, 1.0, 1.0, // glass: frost, refraction, saturation, rim, shadow
    18.0, // blur radius
};

// Larger, rounder, with more air: controls are capsules.
const g_glass_metrics: [raven.R_METRIC_COUNT]f32 = .{
    14.0, // font size
    12.0, // corner radius
    1.0, // border width
    32.0, // control height
    15.0, // padding x
    6.0, // padding y
    8.0, // spacing
    10.0, // scrollbar size
    30.0, // row height
    18.0, // indent
    7.0, // splitter size
    22.0, // check size
    22.0, // slider handle size
    16.0, // popup radius
    1.0, 1.0, 1.0, 1.0, 1.0, // glass: frost, refraction, saturation, rim, shadow
    18.0, // blur radius
};

// ---------------------------------------------------------------------------
//  Wallpaper of the glass themes
// ---------------------------------------------------------------------------

const RVN_WALLPAPER_SIZE = 256;

const rvn_blob_t = struct {
    x: f32,
    y: f32,
    radius: f32,
    r: f32,
    g: f32,
    b: f32,
};

fn rvn_wallpaper_render(base_: *const [3]f32, blobs: [*c]const rvn_blob_t, count: c_int) raven.Rid {
    const pixels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, RVN_WALLPAPER_SIZE) * RVN_WALLPAPER_SIZE * 4)));
    var x: c_int = undefined;
    var y: c_int = undefined;
    var i: c_int = undefined;

    y = 0;
    while (y < RVN_WALLPAPER_SIZE) : (y += 1) {
        x = 0;
        while (x < RVN_WALLPAPER_SIZE) : (x += 1) {
            const u: f32 = (@as(f32, @floatFromInt(x)) + 0.5) / RVN_WALLPAPER_SIZE;
            const v: f32 = (@as(f32, @floatFromInt(y)) + 0.5) / RVN_WALLPAPER_SIZE;
            var color: [3]f32 = undefined;
            const out: [*c]u8 = pixels + ((@as(usize, @intCast(y)) * RVN_WALLPAPER_SIZE + @as(usize, @intCast(x))) * 4);
            color[0] = base_[0];
            color[1] = base_[1];
            color[2] = base_[2];
            i = 0;
            while (i < count) : (i += 1) {
                const dx = u - blobs[@intCast(i)].x;
                const dy = v - blobs[@intCast(i)].y;
                const weight = libc.expf(-(dx * dx + dy * dy) / (blobs[@intCast(i)].radius * blobs[@intCast(i)].radius * 0.5)) * 0.9;
                color[0] += (blobs[@intCast(i)].r - color[0]) * weight;
                color[1] += (blobs[@intCast(i)].g - color[1]) * weight;
                color[2] += (blobs[@intCast(i)].b - color[2]) * weight;
            }
            out[0] = @intFromFloat(base.rvn_clampf(color[0], 0.0, 1.0) * 255.0 + 0.5);
            out[1] = @intFromFloat(base.rvn_clampf(color[1], 0.0, 1.0) * 255.0 + 0.5);
            out[2] = @intFromFloat(base.rvn_clampf(color[2], 0.0, 1.0) * 255.0 + 0.5);
            out[3] = 255;
        }
    }
    // the texture takes ownership of the pixels
    return renderer_h.rvn_texture_create_raw(RVN_WALLPAPER_SIZE, RVN_WALLPAPER_SIZE, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
}

// Where the blobs lie, and how large they are: the same for every wallpaper.
const g_blob_places = [5]rvn_blob_t{
    .{ .x = 0.15, .y = 0.20, .radius = 0.55, .r = 0.0, .g = 0.0, .b = 0.0 },
    .{ .x = 0.88, .y = 0.12, .radius = 0.50, .r = 0.0, .g = 0.0, .b = 0.0 },
    .{ .x = 0.80, .y = 0.86, .radius = 0.58, .r = 0.0, .g = 0.0, .b = 0.0 },
    .{ .x = 0.12, .y = 0.92, .radius = 0.46, .r = 0.0, .g = 0.0, .b = 0.0 },
    .{ .x = 0.50, .y = 0.50, .radius = 0.34, .r = 0.0, .g = 0.0, .b = 0.0 },
};

export fn rvn_wallpaper_create_colors(base_: u32, colors: [*c]const u32, count_in: c_int) raven.Rid {
    var blobs: [5]rvn_blob_t = undefined;
    var base_color: [3]f32 = undefined;
    var count: c_int = count_in;
    var i: c_int = undefined;
    if (count > 5) count = 5;
    base_color[0] = @as(f32, @floatFromInt((base_ >> 16) & 0xFF)) / 255.0;
    base_color[1] = @as(f32, @floatFromInt((base_ >> 8) & 0xFF)) / 255.0;
    base_color[2] = @as(f32, @floatFromInt(base_ & 0xFF)) / 255.0;
    i = 0;
    while (i < count) : (i += 1) {
        blobs[@intCast(i)] = g_blob_places[@intCast(i)];
        blobs[@intCast(i)].r = @as(f32, @floatFromInt((colors[@intCast(i)] >> 16) & 0xFF)) / 255.0;
        blobs[@intCast(i)].g = @as(f32, @floatFromInt((colors[@intCast(i)] >> 8) & 0xFF)) / 255.0;
        blobs[@intCast(i)].b = @as(f32, @floatFromInt(colors[@intCast(i)] & 0xFF)) / 255.0;
    }
    return rvn_wallpaper_render(&base_color, &blobs, count);
}

// The background of the glass themes: plain black for the dark one, plain
// white for the light one. It is still a wallpaper (a texture under the whole
// window), so that Rwindow_set_background and the Wallpaper of a theme file
// ("#101020, #3040C0, #C02080": colored blobs) replace it the same way.
export fn rvn_theme_builtin_wallpaper(dark: c_int) raven.Rid {
    const wallpaper: *raven.Rid = &ctx_h.g_rvn.wallpapers[if (dark != 0) 0 else 1];
    if (renderer_h.rvn_texture_get(wallpaper.*) == null) {
        // (dark: a graphite grey, not black: the glass reads as frosted, not as a hole)
        wallpaper.* = rvn_wallpaper_create_colors(if (dark != 0) 0x2A2A2E else 0xFFFFFF, null, 0);
    }
    return wallpaper.*;
}

export fn rvn_theme_build(theme: [*c]ctx_h.rvn_theme_t, builtin: raven.RTheme) void {
    var palette: []const rvn_palette_entry_t = undefined;
    var count: usize = undefined;
    var i: usize = undefined;
    const glass: c_int = @intFromBool(builtin == raven.R_THEME_GLASS_DARK or builtin == raven.R_THEME_GLASS_LIGHT);
    const contrast: c_int = @intFromBool(builtin == raven.R_THEME_HIGH_CONTRAST_DARK or builtin == raven.R_THEME_HIGH_CONTRAST_LIGHT);
    const dark: c_int = @intFromBool(builtin == raven.R_THEME_DARK or builtin == raven.R_THEME_GLASS_DARK or builtin == raven.R_THEME_HIGH_CONTRAST_DARK);
    const name = theme.*.name;
    const path = theme.*.path;
    const font = theme.*.font;

    theme.*.name = null;
    theme.*.path = null;
    widget_h.rvn_theme_clear(theme);
    theme.*.name = name;
    theme.*.path = path;
    // (the font is not part of the built-in themes: the one in use stays)
    theme.*.font = font;

    switch (builtin) {
        raven.R_THEME_LIGHT => {
            palette = &g_light_palette;
            count = g_light_palette.len;
        },
        raven.R_THEME_GLASS_DARK => {
            palette = &g_glass_dark_palette;
            count = g_glass_dark_palette.len;
        },
        raven.R_THEME_GLASS_LIGHT => {
            palette = &g_glass_light_palette;
            count = g_glass_light_palette.len;
        },
        raven.R_THEME_HIGH_CONTRAST_DARK => {
            palette = &g_hc_dark_palette;
            count = g_hc_dark_palette.len;
        },
        raven.R_THEME_HIGH_CONTRAST_LIGHT => {
            palette = &g_hc_light_palette;
            count = g_hc_light_palette.len;
        },
        // R_THEME_DARK and default
        else => {
            palette = &g_dark_palette;
            count = g_dark_palette.len;
        },
    }
    i = 0;
    while (i < count) : (i += 1) {
        theme.*.colors[@intCast(RVN_COLOR_INDEX(palette[i].role))] = base.rvn_hex(palette[i].rgb, palette[i].alpha);
    }
    @memcpy(&theme.*.metrics, if (glass != 0) &g_glass_metrics else if (contrast != 0) &g_hc_metrics else &g_flat_metrics);

    theme.*.material = if (glass != 0) raven.R_MATERIAL_FROSTED_GLASS else raven.R_MATERIAL_SOLID;
    theme.*.glass = glass;
    theme.*.dark = dark;
    theme.*.wallpaper = if (glass != 0) rvn_theme_builtin_wallpaper(dark) else raven.R_INVALID_ID;
}

export fn rvn_theme_apply(theme: raven.RTheme) void {
    const names = [_][*c]const u8{ "Dark", "Light", "GlassDark", "GlassLight", "HighContrastDark", "HighContrastLight" };
    rvn_theme_build(&ctx_h.g_rvn.theme, theme);
    _ = base.rvn_str_set(&ctx_h.g_rvn.theme_name, names[@intCast(@as(c_int, @bitCast(theme)) - raven.R_THEME_DARK)]);
    widget_h.rvn_theme_changed();
}

// ---------------------------------------------------------------------------
//  Lookup
// ---------------------------------------------------------------------------

export fn rvn_widget_color(widget: [*c]const widget_h.rvn_widget_t, role: raven.RColorRole) base.rvn_color_t {
    const index: c_int = RVN_COLOR_INDEX(role);
    const bit: u64 = @as(u64, 1) << @intCast(index);
    if (widget.*.style != null and (widget.*.style.*.color_mask & bit) != 0) return widget.*.style.*.colors[@intCast(index)];
    const match = widget_h.rvn_widget_match(widget);
    if (match != null and (match.*.style.color_mask & bit) != 0) return match.*.style.colors[@intCast(index)];
    return widget_h.rvn_widget_theme(widget).*.colors[@intCast(index)];
}

fn rvn_widget_metric_raw(widget: [*c]const widget_h.rvn_widget_t, metric: raven.RMetric) f32 {
    const index: c_int = RVN_METRIC_INDEX(metric);
    const bit: u32 = @as(u32, 1) << @intCast(index);
    if (widget.*.style != null and (widget.*.style.*.metric_mask & bit) != 0) return widget.*.style.*.metrics[@intCast(index)];
    const match = widget_h.rvn_widget_match(widget);
    if (match != null and (match.*.style.metric_mask & bit) != 0) return match.*.style.metrics[@intCast(index)];
    return widget_h.rvn_widget_theme(widget).*.metrics[@intCast(index)];
}

export fn rvn_widget_metric(widget: [*c]const widget_h.rvn_widget_t, metric: raven.RMetric) f32 {
    var value = rvn_widget_metric_raw(widget, metric);
    const scale = widget_h.rvn_a11y_text_scale();
    // larger texts (Raccessibility_set_text_scale): the controls that hold a line of text grow with it
    if (scale != 1.0) {
        switch (metric) {
            raven.R_METRIC_CONTROL_HEIGHT, raven.R_METRIC_ROW_HEIGHT, raven.R_METRIC_CHECK_SIZE, raven.R_METRIC_SLIDER_HANDLE_SIZE, raven.R_METRIC_INDENT, raven.R_METRIC_PADDING_Y => value *= scale,
            else => {},
        }
    }
    return value;
}

export fn rvn_widget_has_color(widget: [*c]const widget_h.rvn_widget_t, role: raven.RColorRole) c_int {
    const bit: u64 = @as(u64, 1) << @intCast(RVN_COLOR_INDEX(role));
    if (widget.*.style != null and (widget.*.style.*.color_mask & bit) != 0) return raven.R_TRUE;
    const match = widget_h.rvn_widget_match(widget);
    return @intFromBool(match != null and (match.*.style.color_mask & bit) != 0);
}

export fn rvn_widget_has_metric(widget: [*c]const widget_h.rvn_widget_t, metric: raven.RMetric) c_int {
    const bit: u32 = @as(u32, 1) << @intCast(RVN_METRIC_INDEX(metric));
    if (widget.*.style != null and (widget.*.style.*.metric_mask & bit) != 0) return raven.R_TRUE;
    const match = widget_h.rvn_widget_match(widget);
    return @intFromBool(match != null and (match.*.style.metric_mask & bit) != 0);
}

fn rvn_widget_style(widget: [*c]widget_h.rvn_widget_t) [*c]ctx_h.rvn_style_t {
    if (widget.*.style == null) widget.*.style = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(ctx_h.rvn_style_t))));
    return widget.*.style;
}

export fn rvn_widget_set_color(widget: [*c]widget_h.rvn_widget_t, role: raven.RColorRole, color: base.rvn_color_t) void {
    const style = rvn_widget_style(widget);
    const index: c_int = RVN_COLOR_INDEX(role);
    style.*.colors[@intCast(index)] = color;
    style.*.color_mask |= @as(u64, 1) << @intCast(index);
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn rvn_widget_set_metric(widget: [*c]widget_h.rvn_widget_t, metric: raven.RMetric, value: f32) void {
    const style = rvn_widget_style(widget);
    const index: c_int = RVN_METRIC_INDEX(metric);
    style.*.metrics[@intCast(index)] = value;
    style.*.metric_mask |= @as(u32, 1) << @intCast(index);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn rvn_widget_text_color(widget: [*c]const widget_h.rvn_widget_t, painter: ?*const raven.RPainter) base.rvn_color_t {
    const p: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    if (p.enabled == 0) return rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED);
    // the painter already carries the override of this widget or of an ancestor
    return p.text_color;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rtheme_apply(theme: raven.RTheme) void {
    if (ctx_h.rvn_api_check("Rtheme_apply") == 0) return;
    if (theme < raven.R_THEME_DARK or theme > raven.R_THEME_HIGH_CONTRAST_LIGHT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_apply: invalid theme");
        return;
    }
    rvn_theme_apply(theme);
}

export fn Rtheme_set_color(role: raven.RColorRole, r: f32, g: f32, b: f32, a: f32) void {
    if (ctx_h.rvn_api_check("Rtheme_set_color") == 0) return;
    if (rvn_color_valid(role) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_color: invalid color role");
        return;
    }
    ctx_h.g_rvn.theme.colors[@intCast(RVN_COLOR_INDEX(role))] = base.rvn_rgba(r, g, b, a);
    widget_h.rvn_theme_changed();
}

export fn Rtheme_get_color(role: raven.RColorRole, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void {
    if (ctx_h.g_rvn.initialized == 0 or rvn_color_valid(role) == 0) {
        if (r != null) r.* = 0.0;
        if (g != null) g.* = 0.0;
        if (b != null) b.* = 0.0;
        if (a != null) a.* = 0.0;
        return;
    }
    base.rvn_color_to_floats(ctx_h.g_rvn.theme.colors[@intCast(RVN_COLOR_INDEX(role))], r, g, b, a);
}

export fn Rtheme_set_metric(metric: raven.RMetric, value: f32) void {
    if (ctx_h.rvn_api_check("Rtheme_set_metric") == 0) return;
    if (rvn_metric_valid(metric) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_metric: invalid metric");
        return;
    }
    ctx_h.g_rvn.theme.metrics[@intCast(RVN_METRIC_INDEX(metric))] = value;
    widget_h.rvn_theme_changed();
}

export fn Rtheme_get_metric(metric: raven.RMetric) f32 {
    if (ctx_h.g_rvn.initialized == 0 or rvn_metric_valid(metric) == 0) return 0.0;
    return ctx_h.g_rvn.theme.metrics[@intCast(RVN_METRIC_INDEX(metric))];
}

export fn Rtheme_set_material(material: raven.RMaterial) void {
    if (ctx_h.rvn_api_check("Rtheme_set_material") == 0) return;
    if (material < raven.R_MATERIAL_SOLID or material > raven.R_MATERIAL_TINTED_GLASS) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_material: invalid material");
        return;
    }
    ctx_h.g_rvn.theme.material = material;
    ctx_h.g_rvn.theme.glass = @intFromBool(material != raven.R_MATERIAL_SOLID);
    // (the sizes of some controls depend on it)
    widget_h.rvn_theme_changed();
}

export fn Rtheme_get_material() raven.RMaterial {
    return if (ctx_h.g_rvn.initialized != 0) ctx_h.g_rvn.theme.material else raven.R_MATERIAL_SOLID;
}

export fn Rwidget_set_material(id: raven.Rid, material: raven.RMaterial) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_material");
    if (widget == null) return;
    if (material < raven.R_MATERIAL_SOLID or material > raven.R_MATERIAL_DEFAULT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_material: invalid material");
        return;
    }
    widget.*.material = if (material == raven.R_MATERIAL_DEFAULT) 0 else material;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_get_material(id: raven.Rid) raven.RMaterial {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_material");
    if (widget == null) return raven.R_MATERIAL_SOLID;
    return widget_h.rvn_widget_material(widget);
}

export fn Rtheme_set_font(font: raven.Rid) void {
    if (ctx_h.rvn_api_check("Rtheme_set_font") == 0) return;
    if (font != raven.R_INVALID_ID and handle_h.rvn_pool_get(&ctx_h.g_rvn.fonts, font) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtheme_set_font: invalid font");
        return;
    }
    ctx_h.g_rvn.theme.font = if (font == raven.R_INVALID_ID) ctx_h.g_rvn.default_font else font;
    widget_h.rvn_theme_changed();
}

export fn Rtheme_get_font() raven.Rid {
    return if (ctx_h.g_rvn.initialized != 0) ctx_h.g_rvn.theme.font else raven.R_INVALID_ID;
}

export fn Rwidget_set_color(id: raven.Rid, role: raven.RColorRole, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_color");
    if (widget == null) return;
    if (rvn_color_valid(role) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_color: invalid color role");
        return;
    }
    rvn_widget_set_color(widget, role, base.rvn_rgba(r, g, b, a));
}

export fn Rwidget_clear_color(id: raven.Rid, role: raven.RColorRole) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_clear_color");
    if (widget == null) return;
    if (rvn_color_valid(role) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_clear_color: invalid color role");
        return;
    }
    if (widget.*.style != null) widget.*.style.*.color_mask &= ~(@as(u64, 1) << @intCast(RVN_COLOR_INDEX(role)));
    widget_h.rvn_widget_invalidate_paint(widget);
}

export fn Rwidget_set_metric(id: raven.Rid, metric: raven.RMetric, value: f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_metric");
    if (widget == null) return;
    if (rvn_metric_valid(metric) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_metric: invalid metric");
        return;
    }
    rvn_widget_set_metric(widget, metric, value);
}

export fn Rwidget_clear_metric(id: raven.Rid, metric: raven.RMetric) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_clear_metric");
    if (widget == null) return;
    if (rvn_metric_valid(metric) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_clear_metric: invalid metric");
        return;
    }
    if (widget.*.style != null) widget.*.style.*.metric_mask &= ~(@as(u32, 1) << @intCast(RVN_METRIC_INDEX(metric)));
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_get_color(id: raven.Rid, role: raven.RColorRole, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_color");
    var color: base.rvn_color_t = 0;
    if (widget != null and rvn_color_valid(role) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_get_color: invalid color role");
    } else if (widget != null) {
        color = rvn_widget_color(widget, role);
    }
    base.rvn_color_to_floats(color, r, g, b, a);
}

export fn Rwidget_get_metric(id: raven.Rid, metric: raven.RMetric) f32 {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_metric");
    if (widget == null) return 0.0;
    if (rvn_metric_valid(metric) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_get_metric: invalid metric");
        return 0.0;
    }
    return rvn_widget_metric(widget, metric);
}
