//! uikit/splash: the splash window shown at launch. It carries the logo text,
//! a progress bar and a status line, and the app closes it when start-up ends.
//!
//! Mode: retained. The window and its children (logo label, Rprogress_bar,
//! status label) are created once with Rwindow_create and Rwidget_create, then
//! updated by Rprogress_bar_set_value and Rlabel_set_text. Nothing here repaints
//! per frame, so there is no immediate-mode code in this file.
//!
//! Raven calls (declared below by hand, no @cImport): Rwindow_create,
//! Rwindow_set_content, Rwindow_show, Rwindow_destroy (raven_window.h),
//! Rwidget_create(R_WIDGET_PROGRESSBAR) (raven_widget.h, WidgetType.progressbar
//! in raven.zig), Rprogress_bar_set_value (raven_controls.h).
//!
//! Liquid glass: the card is a translucent layered fill (theme.glassAlpha),
//! with a 1 px top highlight, a soft shadow, and a corner radius of 10 to 14.
//! The active state uses the accent colour. Text is never below 12 px.
//!
//! Status: the pure logic and configuration rules are specified by the tests
//! below and are `@panic("todo")` until the widget is built.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

/// Errors from opening the splash window.
pub const Error = error{WindowFailed};

// raven_window.h: Rwindow_create and its close, show and content calls.
extern fn Rwindow_create(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) raven.Rid;
extern fn Rwindow_destroy(window: raven.Rid) void;
extern fn Rwindow_set_content(window: raven.Rid, widget: raven.Rid) void;
extern fn Rwindow_show(window: raven.Rid) void;

// raven_widget.h and raven_layout.h: the widget tree under the window.
extern fn Rwidget_create(kind: raven.WidgetType) raven.Rid;
extern fn Rwidget_add_child(parent: raven.Rid, child: raven.Rid) raven.Rid;
extern fn Rwidget_set_size(widget: raven.Rid, width: f32, height: f32) void;
extern fn Rwidget_set_color(widget: raven.Rid, role: raven.ColorRole, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rborder_set_padding(border: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void;
extern fn Rborder_set_background(border: raven.Rid, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rborder_set_outline(border: raven.Rid, width: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rborder_set_corner_radius(border: raven.Rid, tl: f32, tr: f32, br: f32, bl: f32) void;
extern fn Rborder_set_shadow(border: raven.Rid, blur: f32, offset_x: f32, offset_y: f32) void;
extern fn Rborder_set_material(border: raven.Rid, material: raven.Material) void;

// raven_controls.h: label and progress bar.
extern fn Rlabel_create(text: [*:0]const u8) raven.Rid;
extern fn Rlabel_set_text(label: raven.Rid, text: [*:0]const u8) void;
extern fn Rlabel_set_text_size(label: raven.Rid, size: f32) void;
extern fn Rlabel_set_text_align(label: raven.Rid, text_align: raven.TextAlign) void;
extern fn Rlabel_set_color(label: raven.Rid, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rprogress_bar_set_value(progress_bar: raven.Rid, value: f32) void;

// Window flags from raven_window.h.
const window_no_resize: c_uint = 1 << 0;
const window_borderless: c_uint = 1 << 2;
const window_transparent: c_uint = 1 << 5;

/// Splash configuration. Every field has a default, so `.{}` is a valid splash.
pub const Config = struct {
    /// Logo text, drawn large above the progress bar.
    logo_text: [:0]const u8 = "bytecats",
    /// Status line under the progress bar, for example "Loading plugins".
    status: [:0]const u8 = "Starting",
    /// Progress in [0, 1]. Values outside the range are clamped by `sanitize`.
    progress: f32 = 0.0,
    /// Window size in logical pixels.
    width: f32 = 420.0,
    height: f32 = 240.0,
    /// Corner radius in logical pixels. Clamped to [10, 14] by `sanitize`.
    radius: f32 = theme.radius_panel,
    /// Logo size in px. Never below 12 (theme.min_font_px).
    logo_px: f32 = theme.font_title_px,
    /// Status line size in px. Never below 12 (theme.min_font_px).
    status_px: f32 = theme.font_body_px,
    /// Glass layer of the card. Sets the fill alpha (theme.glassAlpha).
    layer: theme.GlassLayer = .overlay,
};

/// The drawing values derived from a Config. Pure data, no Raven calls.
pub const Chrome = struct {
    radius: f32,
    /// Translucent layered fill: theme.bg_panel at the layer's alpha.
    fill: theme.Color,
    /// 1 px light line along the top edge.
    highlight_px: f32,
    shadow_blur_px: f32,
    shadow_offset_y_px: f32,
};

/// Smallest and largest window side in logical px. Values outside the range
/// are clamped before they become a Raven size.
pub const min_window_px: f32 = 1.0;
pub const max_window_px: f32 = 4096.0;

/// Clamps a window side into [min_window_px, max_window_px]. NaN gives the minimum.
pub fn clampWindowPx(v: f32) f32 {
    if (!(v >= min_window_px)) return min_window_px;
    if (v > max_window_px) return max_window_px;
    return v;
}

/// Window side as the integer Raven takes. The float is clamped first, so the
/// conversion never sees a NaN, a negative or an out-of-range value.
pub fn windowPx(v: f32) c_int {
    const clamped = clampWindowPx(v);
    return @intFromFloat(clamped);
}

/// Window size in whole px, as passed to Rwindow_create.
pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

/// The window size for `cfg`, after sanitize.
pub fn windowSize(cfg: Config) WindowSize {
    const s = sanitize(cfg);
    return .{ .width = windowPx(s.width), .height = windowPx(s.height) };
}

/// Clamps progress into [0, 1]. NaN gives 0.
pub fn clampProgress(value: f32) f32 {
    // Negated >= so that NaN fails the test and takes the floor.
    if (!(value >= 0.0)) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

/// Returns a copy of `cfg` with progress clamped to [0, 1], the window size
/// clamped to [1, 4096], radius clamped to [10, 14] and both text sizes raised
/// to at least 12 px. Other fields are kept.
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    out.progress = clampProgress(cfg.progress);
    out.width = clampWindowPx(cfg.width);
    out.height = clampWindowPx(cfg.height);
    out.radius = theme.clampRadius(cfg.radius);
    out.logo_px = theme.clampFontSize(cfg.logo_px);
    out.status_px = theme.clampFontSize(cfg.status_px);
    return out;
}

/// Index of the active step when `progress` in [0, 1] is split into `steps`
/// equal bands: floor(progress * steps), clamped to steps - 1. Zero steps gives
/// 0. NaN and negative progress give 0; progress 1.0 gives steps - 1.
pub fn stepIndex(progress: f32, steps: usize) usize {
    if (steps == 0) return 0;
    const last = steps - 1;
    const p = clampProgress(progress);
    if (p >= 1.0) return last;
    const scaled: f32 = p * @as(f32, @floatFromInt(steps));
    const idx: usize = @intFromFloat(@floor(scaled));
    return @min(idx, last);
}

/// Accent colour for the active state, text_muted for the inactive state.
pub fn stageColor(active: bool) theme.Color {
    return if (active) theme.accent else theme.text_muted;
}

/// Derives the drawing values for `cfg`. The config is sanitized first, so the
/// radius is in [10, 14] and the fill alpha is theme.glassAlpha(cfg.layer).
pub fn chrome(cfg: Config) Chrome {
    const s = sanitize(cfg);
    return .{
        .radius = s.radius,
        .fill = theme.withAlpha(theme.bg_panel, theme.glassAlpha(s.layer)),
        .highlight_px = theme.highlight_px,
        .shadow_blur_px = theme.shadow_blur_px,
        .shadow_offset_y_px = theme.shadow_offset_y_px,
    };
}

/// A splash window open on screen. Created by `open`, closed by `close`.
pub const Splash = struct {
    window: raven.Rid,
    progress_bar: raven.Rid,
    status_label: raven.Rid,

    /// Creates the window, its widgets and shows it. Errors if Raven fails to
    /// create the window.
    pub fn open(cfg: Config) Error!Splash {
        const s = sanitize(cfg);
        const c = chrome(s);
        const size = windowSize(cfg);
        const window = Rwindow_create(
            "Bytecats",
            size.width,
            size.height,
            window_no_resize | window_borderless | window_transparent,
        );
        if (window == raven.invalid) return error.WindowFailed;

        // Card: glass border holding the logo, the progress bar and the status line.
        const card = Rwidget_create(.border);
        Rborder_set_material(card, .glass);
        Rborder_set_background(card, c.fill.r, c.fill.g, c.fill.b, c.fill.a);
        Rborder_set_outline(card, c.highlight_px, theme.highlight.r, theme.highlight.g, theme.highlight.b, theme.highlight.a);
        Rborder_set_corner_radius(card, c.radius, c.radius, c.radius, c.radius);
        Rborder_set_shadow(card, c.shadow_blur_px, 0.0, c.shadow_offset_y_px);
        Rborder_set_padding(card, 20.0, 20.0, 20.0, 20.0);
        Rwidget_set_size(card, s.width, s.height);

        const column = Rwidget_create(.vbox);

        const logo = Rlabel_create(s.logo_text.ptr);
        Rlabel_set_text_size(logo, s.logo_px);
        Rlabel_set_text_align(logo, .center);
        Rlabel_set_color(logo, theme.text.r, theme.text.g, theme.text.b, theme.text.a);

        const bar = Rwidget_create(.progressbar);
        Rprogress_bar_set_value(bar, s.progress);
        Rwidget_set_color(bar, .accent, theme.accent.r, theme.accent.g, theme.accent.b, theme.accent.a);

        const status = Rlabel_create(s.status.ptr);
        Rlabel_set_text_size(status, s.status_px);
        Rlabel_set_text_align(status, .center);
        Rlabel_set_color(status, theme.text_muted.r, theme.text_muted.g, theme.text_muted.b, theme.text_muted.a);

        _ = Rwidget_add_child(column, logo);
        _ = Rwidget_add_child(column, bar);
        _ = Rwidget_add_child(column, status);
        _ = Rwidget_add_child(card, column);

        Rwindow_set_content(window, card);
        Rwindow_show(window);

        return .{ .window = window, .progress_bar = bar, .status_label = status };
    }

    /// Sets progress; the value is clamped with `clampProgress`.
    pub fn setProgress(self: *Splash, value: f32) void {
        Rprogress_bar_set_value(self.progress_bar, clampProgress(value));
    }

    /// Replaces the status line text.
    pub fn setStatus(self: *Splash, text: [:0]const u8) void {
        Rlabel_set_text(self.status_label, text.ptr);
    }

    /// Destroys the window. The app calls this when start-up is done.
    pub fn close(self: *Splash) void {
        Rwindow_destroy(self.window);
    }
};

test "splash config: defaults" {
    // Must check:
    //   - logo "bytecats", status "Starting", progress 0
    //   - size 420 x 240, radius theme.radius_panel (14), overlay layer
    //   - logo_px theme.font_title_px (16), status_px theme.font_body_px (13)
    const cfg: Config = .{};
    try testing.expectEqualStrings("bytecats", cfg.logo_text);
    try testing.expectEqualStrings("Starting", cfg.status);
    try testing.expectEqual(@as(f32, 0.0), cfg.progress);
    try testing.expectEqual(@as(f32, 420.0), cfg.width);
    try testing.expectEqual(@as(f32, 240.0), cfg.height);
    try testing.expectEqual(theme.radius_panel, cfg.radius);
    try testing.expectEqual(theme.font_title_px, cfg.logo_px);
    try testing.expectEqual(theme.font_body_px, cfg.status_px);
    try testing.expectEqual(theme.GlassLayer.overlay, cfg.layer);
}

test "clampProgress: range [0, 1], NaN gives 0" {
    // Must check:
    //   - 0 -> 0, 1 -> 1, 0.25 unchanged
    //   - -0.5 -> 0, 1.7 -> 1, -inf -> 0, +inf -> 1
    //   - NaN -> 0
    try testing.expectEqual(@as(f32, 0.0), clampProgress(0.0));
    try testing.expectEqual(@as(f32, 1.0), clampProgress(1.0));
    try testing.expectEqual(@as(f32, 0.25), clampProgress(0.25));
    try testing.expectEqual(@as(f32, 0.0), clampProgress(-0.5));
    try testing.expectEqual(@as(f32, 1.0), clampProgress(1.7));
    try testing.expectEqual(@as(f32, 0.0), clampProgress(-std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 1.0), clampProgress(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0.0), clampProgress(std.math.nan(f32)));
}

test "sanitize: clamps progress, radius and text sizes" {
    // Must check:
    //   - progress 2.0 -> 1.0, progress -1.0 -> 0.0
    //   - radius 3 -> 10, radius 50 -> 14, radius NaN -> 10, radius 12 kept
    //   - logo_px 8 -> 12, status_px NaN -> 12, status_px 13 kept
    //   - text, size and layer fields are kept as given
    const low_radius = sanitize(.{ .progress = 2.0, .radius = 3.0, .logo_px = 8.0 });
    try testing.expectEqual(@as(f32, 1.0), low_radius.progress);
    try testing.expectEqual(@as(f32, 10.0), low_radius.radius);
    try testing.expectEqual(@as(f32, 12.0), low_radius.logo_px);

    const high_radius = sanitize(.{ .progress = -1.0, .radius = 50.0, .status_px = std.math.nan(f32) });
    try testing.expectEqual(@as(f32, 0.0), high_radius.progress);
    try testing.expectEqual(@as(f32, 14.0), high_radius.radius);
    try testing.expectEqual(@as(f32, 12.0), high_radius.status_px);

    const nan_radius = sanitize(.{ .radius = std.math.nan(f32) });
    try testing.expectEqual(@as(f32, 10.0), nan_radius.radius);

    const kept = sanitize(.{ .radius = 12.0, .status_px = 13.0, .logo_text = "bc", .layer = .base });
    try testing.expectEqual(@as(f32, 12.0), kept.radius);
    try testing.expectEqual(@as(f32, 13.0), kept.status_px);
    try testing.expectEqualStrings("bc", kept.logo_text);
    try testing.expectEqual(theme.GlassLayer.base, kept.layer);
}

test "stepIndex: equal bands, clamped to the last step" {
    // Must check (steps = 4):
    //   - 0.0 -> 0, 0.24 -> 0, 0.25 -> 1, 0.5 -> 2, 0.999 -> 3
    //   - 1.0 -> 3 (never steps)
    //   - NaN -> 0, negative -> 0, above 1 -> 3
    //   - steps = 0 gives 0 for any progress
    try testing.expectEqual(@as(usize, 0), stepIndex(0.0, 4));
    try testing.expectEqual(@as(usize, 0), stepIndex(0.24, 4));
    try testing.expectEqual(@as(usize, 1), stepIndex(0.25, 4));
    try testing.expectEqual(@as(usize, 2), stepIndex(0.5, 4));
    try testing.expectEqual(@as(usize, 3), stepIndex(0.999, 4));
    try testing.expectEqual(@as(usize, 3), stepIndex(1.0, 4));
    try testing.expectEqual(@as(usize, 0), stepIndex(std.math.nan(f32), 4));
    try testing.expectEqual(@as(usize, 0), stepIndex(-0.1, 4));
    try testing.expectEqual(@as(usize, 3), stepIndex(1.5, 4));
    try testing.expectEqual(@as(usize, 0), stepIndex(0.9, 0));
}

test "stageColor: accent when active, muted text when inactive" {
    // Must check:
    //   - active -> theme.accent
    //   - inactive -> theme.text_muted
    try testing.expectEqual(theme.accent, stageColor(true));
    try testing.expectEqual(theme.text_muted, stageColor(false));
}

test "chrome: translucent layered card with highlight and shadow" {
    // Must check:
    //   - radius 14 by default, and clamped to [10, 14] as in sanitize
    //   - fill keeps theme.bg_panel colour, alpha theme.glassAlpha(.overlay)
    //   - alpha stays in [glass_alpha_min, glass_alpha_max]
    //   - highlight_px is 1, shadow blur and offset from theme
    //   - base < raised < overlay in alpha
    const c = chrome(.{});
    try testing.expectEqual(@as(f32, 14.0), c.radius);
    try testing.expectEqual(theme.bg_panel.r, c.fill.r);
    try testing.expectEqual(theme.bg_panel.g, c.fill.g);
    try testing.expectEqual(theme.bg_panel.b, c.fill.b);
    try testing.expectEqual(theme.glassAlpha(.overlay), c.fill.a);
    try testing.expect(c.fill.a >= theme.glass_alpha_min and c.fill.a <= theme.glass_alpha_max);
    try testing.expectEqual(@as(f32, 1.0), c.highlight_px);
    try testing.expectEqual(theme.shadow_blur_px, c.shadow_blur_px);
    try testing.expectEqual(theme.shadow_offset_y_px, c.shadow_offset_y_px);

    const clamped = chrome(.{ .radius = 50.0 });
    try testing.expectEqual(@as(f32, 14.0), clamped.radius);

    const base = chrome(.{ .layer = .base }).fill.a;
    const raised = chrome(.{ .layer = .raised }).fill.a;
    const overlay = chrome(.{ .layer = .overlay }).fill.a;
    try testing.expect(base < raised);
    try testing.expect(raised < overlay);
}

test "splash window size: NaN, negative and above-range sizes are clamped" {
    try testing.expectEqual(@as(c_int, 1), windowPx(std.math.nan(f32)));
    try testing.expectEqual(@as(c_int, 1), windowPx(-300.0));
    try testing.expectEqual(@as(c_int, 1), windowPx(0.0));
    try testing.expectEqual(@as(c_int, 4096), windowPx(1.0e9));
    try testing.expectEqual(@as(c_int, 4096), windowPx(std.math.inf(f32)));
    try testing.expectEqual(@as(c_int, 420), windowPx(420.0));
    try testing.expectEqual(@as(c_int, 240), windowPx(240.9));
}

test "splash window size: the config is sanitized before the size is taken" {
    const bad_nan = windowSize(.{ .width = std.math.nan(f32), .height = -5.0 });
    try testing.expectEqual(@as(c_int, 1), bad_nan.width);
    try testing.expectEqual(@as(c_int, 1), bad_nan.height);

    const huge = windowSize(.{ .width = 1.0e30, .height = std.math.inf(f32) });
    try testing.expectEqual(@as(c_int, 4096), huge.width);
    try testing.expectEqual(@as(c_int, 4096), huge.height);

    const normal = windowSize(.{});
    try testing.expectEqual(@as(c_int, 420), normal.width);
    try testing.expectEqual(@as(c_int, 240), normal.height);
}
