// Translated to Zig from vendor/raven/src/widget/watermark.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/watermark.c
// The watermark of the free edition.
//
// Raven is built in two editions, chosen when the library is compiled:
//   - the free edition (the default, RAVEN_PAID=OFF) shows a small note in
//     the bottom right corner of every window;
//   - the paid edition (-DRAVEN_PAID=ON) shows nothing.
// Nothing else differs, and what you make with either one is yours.
//
// The note is painted over everything (popups and tooltips included) and
// never takes the mouse: what is under it still gets the clicks.

const std = @import("std");
const raven = @import("raven");
const config = @import("raven_config");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const widget_h = @import("widget_h.zig");

const RVN_WATERMARK_URL = "oscar-soirey.github.io/Raven";

const g_rvn_watermark_full = [2][*c]const u8{
    "Made with Raven \xC2\xB7 free edition",
    "The paid edition has no watermark \xC2\xB7 " ++ RVN_WATERMARK_URL,
};
const g_rvn_watermark_short = [2][*c]const u8{
    "Raven free edition",
    RVN_WATERMARK_URL,
};

const rvn_watermark_layout_t = extern struct {
    rect: base.rvn_rect_t,
    lines: [*c]const [*c]const u8,
    font_size: f32,
    line_height: f32,
    pad_x: f32,
    pad_y: f32,
};

export fn rvn_watermark_enabled() c_int {
    if (config.paid) return raven.R_FALSE;
    return raven.R_TRUE;
}

/// Where the note goes in a window of that size: R_FALSE when there is none.
fn rvn_watermark_layout(window: [*c]const widget_h.rvn_window_t, out: [*c]rvn_watermark_layout_t) c_int {
    const size = widget_h.rvn_window_size(window);
    const font = font_h.rvn_font_resolve(raven.R_INVALID_ID);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    var base_: f32 = undefined;
    var width: f32 = 0.0;
    const margin: f32 = 8.0;
    var i: c_int = undefined;
    var attempt: c_int = undefined;

    out.* = std.mem.zeroes(rvn_watermark_layout_t);
    if (rvn_watermark_enabled() == 0 or font == null or size.x < 40.0 or size.y < 24.0) return raven.R_FALSE;
    base_ = base.rvn_clampf(ctx_h.RVN_THEME_METRIC(raven.R_METRIC_FONT_SIZE) * 0.85, 9.0, 13.0);

    // the long text when it fits, else the short one, made smaller if it must
    attempt = 0;
    while (attempt < 2) : (attempt += 1) {
        const lines: [*c]const [*c]const u8 = if (attempt == 0) &g_rvn_watermark_full else &g_rvn_watermark_short;
        width = 0.0;
        i = 0;
        while (i < 2) : (i += 1) {
            width = base.rvn_maxf(width, font_h.rvn_text_width(font, base_, lines[@intCast(i)], -1));
        }
        out.*.lines = lines;
        if (width + 20.0 + margin * 2.0 <= size.x) break;
    }
    out.*.font_size = base_;
    if (width + 20.0 + margin * 2.0 > size.x) {
        const fit = base_ * (size.x - 20.0 - margin * 2.0) / base.rvn_maxf(width, 1.0);
        out.*.font_size = base.rvn_maxf(4.0, fit);
        width = width * out.*.font_size / base_;
    }
    font_h.rvn_font_metrics(font, out.*.font_size, &metrics);
    out.*.line_height = metrics.line_height;
    out.*.pad_x = 10.0;
    out.*.pad_y = 5.0;
    out.*.rect.w = width + out.*.pad_x * 2.0;
    out.*.rect.h = out.*.line_height * 2.0 + out.*.pad_y * 2.0;
    out.*.rect.x = base.rvn_maxf(0.0, size.x - out.*.rect.w - margin);
    out.*.rect.y = base.rvn_maxf(0.0, size.y - out.*.rect.h - margin);
    return raven.R_TRUE;
}

export fn rvn_window_paint_watermark(window: [*c]widget_h.rvn_window_t, painter: ?*raven.RPainter) void {
    var layout: rvn_watermark_layout_t = undefined;
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    const opacity = p.*.opacity;
    var y: f32 = undefined;
    var i: c_int = undefined;
    if (rvn_watermark_layout(window, &layout) == 0) return;
    p.*.opacity = 1.0;
    draw_h.rvn_paint_box(p, layout.rect, base.rvn_minf(layout.rect.h * 0.5, 10.0), base.rvn_rgba(0.06, 0.06, 0.08, 0.72), 1.0, base.rvn_rgba(1.0, 1.0, 1.0, 0.22));
    y = layout.rect.y + layout.pad_y;
    i = 0;
    while (i < 2) : (i += 1) {
        const color: base.rvn_color_t = if (i == 0) base.rvn_rgba(1.0, 1.0, 1.0, 0.95) else base.rvn_rgba(0.80, 0.86, 1.0, 0.90);
        draw_h.rvn_paint_text(p, raven.R_INVALID_ID, layout.font_size, layout.rect.x + layout.pad_x, y, layout.lines[@intCast(i)], -1, color);
        y += layout.line_height;
    }
    p.*.opacity = opacity;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Ris_free_edition() c_int {
    return rvn_watermark_enabled();
}

export fn Rwindow_get_watermark_rect(id: raven.Rid, x: [*c]f32, y: [*c]f32, width: [*c]f32, height: [*c]f32) c_int {
    var layout: rvn_watermark_layout_t = undefined;
    if (x != null) x.* = 0.0;
    if (y != null) y.* = 0.0;
    if (width != null) width.* = 0.0;
    if (height != null) height.* = 0.0;
    const window = widget_h.rvn_window_check(id, "Rwindow_get_watermark_rect");
    if (window == null or rvn_watermark_layout(window, &layout) == 0) return raven.R_FALSE;
    if (x != null) x.* = layout.rect.x;
    if (y != null) y.* = layout.rect.y;
    if (width != null) width.* = layout.rect.w;
    if (height != null) height.* = layout.rect.h;
    return raven.R_TRUE;
}
