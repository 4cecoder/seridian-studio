// Translated to Zig from vendor/raven/src/widgets/common.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/common.c
// Helpers shared by the widget implementations.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

// ---------------------------------------------------------------------------
//  Text
// ---------------------------------------------------------------------------

/// Font size of a widget: `size` if positive, else its R_METRIC_FONT_SIZE.
export fn rvn_widget_font_size(widget: [*c]const widget_h.rvn_widget_t, size: f32) f32 {
    return if (size > 0.0) size else widget_h.rvn_widget_metric(widget, raven.R_METRIC_FONT_SIZE);
}

/// Width of a single line of text for a widget.
export fn rvn_widget_text_width(widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, text: [*c]const u8) f32 {
    const resolved = ext.rvn_font_resolve(font);
    if (resolved == null or text == null) return 0.0;
    return ext.rvn_text_width(resolved, rvn_widget_font_size(widget, size), text, -1);
}

/// Height of one line of text for a widget.
export fn rvn_widget_line_height(widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32) f32 {
    const resolved = ext.rvn_font_resolve(font);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    if (resolved == null) return 0.0;
    ext.rvn_font_metrics(resolved, rvn_widget_font_size(widget, size), &metrics);
    return metrics.line_height;
}

/// Calls the typed callback result and then the action of the widget; R_TRUE while the widget is alive.
export fn rvn_widget_alive(widget: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool((widget.*.flags & widget_h.RVN_WF_DEAD) == 0);
}

// ---------------------------------------------------------------------------
//  Glass themes
// ---------------------------------------------------------------------------

/// Corner radius of a control of the given height: its metric, or half the height (a capsule) with a glass theme.
export fn rvn_control_radius(widget: [*c]const widget_h.rvn_widget_t, height: f32) f32 {
    if (widget_h.rvn_widget_glass(widget) != 0) return height * 0.5;
    return widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
}

/// Color between two roles, with the alpha interpolated too.
fn rvn_role_mix(widget: [*c]const widget_h.rvn_widget_t, from: raven.RColorRole, to: raven.RColorRole, t: f32) base.rvn_color_t {
    return base.rvn_color_mix(widget_h.rvn_widget_color(widget, from), widget_h.rvn_widget_color(widget, to), base.rvn_clampf(t, 0.0, 1.0));
}

/// Look of a kind of surface in the current theme; `hover` and `press` are 0..1.
export fn rvn_glass_style(widget: [*c]const widget_h.rvn_widget_t, kind: common.rvn_surface_t, hover_in: f32, press_in: f32, glass: [*c]draw_h.rvn_glass_t) void {
    const dark: c_int = widget_h.rvn_widget_theme(widget).*.dark;
    // the rim catches more light on a pale surface
    var rim: f32 = if (dark != 0) 0.55 else 0.85;
    var tint: base.rvn_color_t = undefined;

    // springs run past their ends: the look only follows them between 0 and 1
    const hover = base.rvn_clampf(hover_in, 0.0, 1.0);
    const press = base.rvn_clampf(press_in, 0.0, 1.0);
    glass.* = std.mem.zeroes(draw_h.rvn_glass_t);
    glass.*.frost = 1.0;
    glass.*.refraction = 10.0;
    glass.*.saturation = 1.5;
    glass.*.shadow_color = widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW);

    switch (kind) {
        common.RVN_SURFACE_ACCENT => {
            tint = rvn_role_mix(widget, raven.R_COLOR_ACCENT, raven.R_COLOR_ACCENT_HOVERED, hover);
            tint = base.rvn_color_mix(tint, widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT_PRESSED), press);
            // tinted glass: the color dominates but what is behind still shows
            tint = base.rvn_color_fade(tint, 0.84);
            glass.*.saturation = 1.3;
            glass.*.shadow = 7.0;
        },
        common.RVN_SURFACE_INPUT => {
            tint = widget_h.rvn_widget_color(widget, raven.R_COLOR_INPUT);
            rim *= 0.55;
            glass.*.refraction = 6.0;
        },
        common.RVN_SURFACE_BAR => {
            tint = widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL);
            rim *= 0.6;
            glass.*.refraction = 8.0;
            glass.*.bevel = 6.0;
        },
        common.RVN_SURFACE_PANEL => {
            tint = widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL);
            glass.*.refraction = 14.0;
            glass.*.bevel = 12.0;
        },
        common.RVN_SURFACE_POPUP => {
            tint = widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP);
            glass.*.refraction = 14.0;
            glass.*.bevel = 10.0;
            glass.*.saturation = 1.7;
            glass.*.shadow = 22.0;
        },
        common.RVN_SURFACE_LENS => {
            tint = base.rvn_rgba(1.0, 1.0, 1.0, if (dark != 0) 0.06 else 0.16);
            rim = 1.0;
            glass.*.frost = 0.0;
            glass.*.refraction = 16.0;
            glass.*.saturation = 1.15;
            glass.*.shadow = 9.0;
        },
        // RVN_SURFACE_CONTROL and default
        else => {
            tint = rvn_role_mix(widget, raven.R_COLOR_CONTROL, raven.R_COLOR_CONTROL_HOVERED, hover);
            tint = base.rvn_color_mix(tint, widget_h.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED), press);
            glass.*.frost = 0.9;
            glass.*.shadow = 6.0;
        },
    }
    // the material: how much of what is behind comes through, and in which color
    {
        var alpha: f32 = @as(f32, @floatFromInt(base.rvn_color_a(tint))) / 255.0;
        switch (widget_h.rvn_widget_material(widget)) {
            raven.R_MATERIAL_GLASS => {
                // clear: barely tinted, barely blurred, and a rim that bends like a lens
                tint = if (kind == common.RVN_SURFACE_ACCENT) base.rvn_color_fade(tint, 0.82) else base.rvn_color_fade(tint, 0.55);
                glass.*.frost *= 0.22;
                glass.*.refraction *= 1.5;
                glass.*.saturation = 1.0 + (glass.*.saturation - 1.0) * 0.5;
                rim = base.rvn_minf(rim * 1.2, 1.0);
            },
            raven.R_MATERIAL_TINTED_GLASS => {
                if (kind != common.RVN_SURFACE_ACCENT and kind != common.RVN_SURFACE_LENS) {
                    // frosted, and colored: the accent shows through every surface, stronger on what floats higher
                    const strength: f32 = if (kind == common.RVN_SURFACE_INPUT) 0.25 else (if (kind == common.RVN_SURFACE_BAR) 0.4 else 0.55);
                    var accent = widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
                    accent = base.rvn_color_fade(accent, base.rvn_clampf(alpha * 1.35 + 0.14, 0.0, 0.78) / base.rvn_maxf(@as(f32, @floatFromInt(base.rvn_color_a(accent))) / 255.0, 0.01));
                    tint = base.rvn_color_mix(base.rvn_color_fade(tint, base.rvn_clampf(alpha * 1.35 + 0.14, 0.0, 0.78) / base.rvn_maxf(alpha, 0.01)), accent, strength);
                }
                glass.*.saturation = 1.25;
            },
            else => {},
        }
        // a palette made for solid surfaces would hide everything: glass keeps some of what is behind
        alpha = @as(f32, @floatFromInt(base.rvn_color_a(tint))) / 255.0;
        if (kind != common.RVN_SURFACE_ACCENT and alpha > 0.74) tint = base.rvn_color_fade(tint, 0.74 / alpha);
    }
    glass.*.tint = tint;
    glass.*.rim = base.rvn_rgba(1.0, 1.0, 1.0, base.rvn_clampf(rim + 0.25 * press, 0.0, 1.0));
    // touched glass lights up
    const glow_k: f32 = if (dark != 0) 0.05 else 0.03;
    glass.*.glow = glow_k * press;
    rvn_glass_tune(widget, glass);
}

/// Applies the glass metrics of the theme (R_METRIC_GLASS_...) to a glass made by hand.
export fn rvn_glass_tune(widget: [*c]const widget_h.rvn_widget_t, glass: [*c]draw_h.rvn_glass_t) void {
    // the glass of the theme (or of the widget): each metric multiplies what the material gives
    const frost = widget_h.rvn_widget_metric(widget, raven.R_METRIC_GLASS_FROST);
    const refraction = widget_h.rvn_widget_metric(widget, raven.R_METRIC_GLASS_REFRACTION);
    const saturation = widget_h.rvn_widget_metric(widget, raven.R_METRIC_GLASS_SATURATION);
    const rim = widget_h.rvn_widget_metric(widget, raven.R_METRIC_GLASS_RIM);
    const shadow = widget_h.rvn_widget_metric(widget, raven.R_METRIC_GLASS_SHADOW);
    if (frost != 1.0) glass.*.frost = base.rvn_clampf(glass.*.frost * frost, 0.0, 1.0);
    if (refraction != 1.0) glass.*.refraction *= base.rvn_maxf(refraction, 0.0);
    if (saturation != 1.0) glass.*.saturation = base.rvn_maxf(0.0, 1.0 + (glass.*.saturation - 1.0) * saturation);
    if (rim != 1.0) {
        const alpha: u32 = @intFromFloat(base.rvn_clampf(@as(f32, @floatFromInt(base.rvn_color_a(glass.*.rim))) * base.rvn_maxf(rim, 0.0), 0.0, 255.0));
        glass.*.rim = (glass.*.rim & 0x00FFFFFF) | (alpha << 24);
    }
    if (shadow != 1.0) glass.*.shadow *= base.rvn_maxf(shadow, 0.0);
}

/// Glass surface with one radius, dimmed when the painter is disabled.
export fn rvn_paint_surface(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, rect: base.rvn_rect_t, radius: f32, kind: common.rvn_surface_t, hover: f32, press: f32) void {
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    var glass: draw_h.rvn_glass_t = undefined;
    var radii: [4]f32 = undefined;
    const opacity = dp.opacity;

    rvn_glass_style(widget, kind, hover, press, &glass);
    radii[0] = radius;
    radii[1] = radius;
    radii[2] = radius;
    radii[3] = radius;
    if (dp.enabled == 0) {
        dp.opacity *= 0.5;
        glass.shadow = 0.0;
    }
    ext.rvn_paint_glass(painter, rect, &radii, &glass);
    dp.opacity = opacity;
}

/// Background of a hovered or selected row: a plain rectangle, or an inset
/// rounded one with a glass theme.
export fn rvn_paint_row(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, row: base.rvn_rect_t, color: base.rvn_color_t) void {
    if (widget_h.rvn_widget_glass(widget) != 0) {
        ext.rvn_paint_box(painter, base.rvn_rect(row.x + 4.0, row.y + 1.0, row.w - 8.0, row.h - 2.0), 8.0, color, 0.0, 0);
    } else {
        ext.rvn_paint_rect(painter, row, color);
    }
}

/// Eased hover / pressed state of a widget for the glass themes (widget->anim).
export fn rvn_widget_hover(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, hovered: c_int) f32 {
    const target: f32 = if (hovered != 0) 1.0 else 0.0;
    return ext.rvn_paint_spring(painter, &widget.*.hover, target, raven.R_MOTION_SNAPPY);
}

export fn rvn_widget_press(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, pressed: c_int) f32 {
    // goes down at once; released, it springs back past its rest position
    const motion: raven.RMotion = if (pressed != 0) raven.R_MOTION_SNAPPY else raven.R_MOTION_BOUNCY;
    const target: f32 = if (pressed != 0) 1.0 else 0.0;
    return ext.rvn_paint_spring(painter, &widget.*.press, target, motion);
}

/// Squash and stretch: sets the transform of the widget from its press state
/// (rvn_widget_press), `amount` being the part of its height it loses when
/// fully pressed. To call from the paint function, every time.
export fn rvn_widget_squash(widget: [*c]widget_h.rvn_widget_t, press: f32, amount: f32) void {
    // pressed: flatter and wider, like something soft; released, the spring overshoots the other way
    widget.*.xform.grow_x = amount * 0.45 * press;
    widget.*.xform.grow_y = -amount * press;
}

/// A solid knob with a soft shadow (slider, switch), or a lens of clear glass while `press` is 1.
export fn rvn_paint_knob(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, rect: base.rvn_rect_t, press: f32) void {
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const radius = base.rvn_minf(rect.w, rect.h) * 0.5;
    if (press > 0.02 and dp.enabled != 0) {
        // picked up: the knob grows and turns into a drop of clear glass
        const grow = 3.0 * press;
        const lens = base.rvn_rect(rect.x - grow * 1.4, rect.y - grow, rect.w + grow * 2.8, rect.h + grow * 2.0);
        const opacity = dp.opacity;
        rvn_paint_surface(painter, widget, lens, radius + grow, common.RVN_SURFACE_LENS, 0.0, 1.0);
        // the solid knob fades into it
        dp.opacity *= 1.0 - press;
        ext.rvn_paint_box(painter, rect, radius, base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.0, 0);
        dp.opacity = opacity;
        return;
    }
    ext.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + 1.5, rect.w, rect.h), radius, 5.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.28));
    const fill: base.rvn_color_t = if (dp.enabled != 0) base.rvn_rgba(1.0, 1.0, 1.0, 1.0) else base.rvn_rgba(0.85, 0.85, 0.87, 1.0);
    ext.rvn_paint_box(painter, rect, radius, fill, 0.0, 0);
}

export fn rvn_paint_focus(widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, radius: f32) void {
    const width = ext.rvn_a11y_focus_width();
    if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) == 0 or widget.*.window == null) return;
    if (widget.*.window.*.focus_visible == 0 and ext.rvn_a11y_focus_always() == 0) return;
    ext.rvn_paint_box(painter, base.rvn_rect(-width, -width, widget.*.rect.w + width * 2.0, widget.*.rect.h + width * 2.0), radius + width, 0, width, widget_h.rvn_widget_color(widget, raven.R_COLOR_FOCUS));
}

// ---------------------------------------------------------------------------
//  Scrollbar
// ---------------------------------------------------------------------------

export fn rvn_scrollbar_max(bar: [*c]const common.rvn_scrollbar_t) f32 {
    return base.rvn_maxf(0.0, bar.*.content - bar.*.viewport);
}

export fn rvn_scrollbar_needed(bar: [*c]const common.rvn_scrollbar_t) c_int {
    return @intFromBool(bar.*.content > bar.*.viewport + 0.5);
}

export fn rvn_scrollbar_set(bar: [*c]common.rvn_scrollbar_t, offset: f32) c_int {
    var clamped = base.rvn_clampf(offset, 0.0, rvn_scrollbar_max(bar));
    // whole logical units keep scrolled content on the pixel grid at scale 1
    clamped = @floor(clamped + 0.5);
    if (clamped > rvn_scrollbar_max(bar)) clamped = rvn_scrollbar_max(bar);
    if (clamped == bar.*.offset) return raven.R_FALSE;
    bar.*.offset = clamped;
    return raven.R_TRUE;
}

export fn rvn_scrollbar_clamp(bar: [*c]common.rvn_scrollbar_t) c_int {
    return rvn_scrollbar_set(bar, bar.*.offset);
}

/// Scrolls by `delta` logical units (the wheel). Returns R_TRUE when the
/// offset changed; at an end of the range it returns R_FALSE and makes the
/// content bounce, which only needs a repaint.
export fn rvn_scrollbar_wheel(bar: [*c]common.rvn_scrollbar_t, delta: f32) c_int {
    if (rvn_scrollbar_set(bar, bar.*.offset + delta) != 0) return raven.R_TRUE;
    // nowhere to go: the push becomes speed, and the spring brings the content back
    if (rvn_scrollbar_needed(bar) != 0 and bar.*.shown.started != 0) {
        ext.rvn_spring_kick(&bar.*.shown, base.rvn_clampf(delta * 9.0, -1400.0, 1400.0));
    }
    return raven.R_FALSE;
}

/// While painting: advances the drawn position and returns it. It may lie outside 0 .. max.
export fn rvn_scrollbar_shown(bar: [*c]common.rvn_scrollbar_t, painter: ?*raven.RPainter) f32 {
    // a thumb that is dragged, or a view that lost its scrolling, follows at once
    if (bar.*.dragging != 0 or rvn_scrollbar_needed(bar) == 0) ext.rvn_spring_set(&bar.*.shown, bar.*.offset);
    return ext.rvn_paint_spring(painter, &bar.*.shown, bar.*.offset, raven.R_MOTION_SMOOTH);
}

fn rvn_scrollbar_thumb(bar: [*c]const common.rvn_scrollbar_t, track_length: f32, start: [*c]f32, length: [*c]f32) void {
    const ratio: f32 = if (bar.*.content > 0.0) base.rvn_clampf(bar.*.viewport / bar.*.content, 0.0, 1.0) else 1.0;
    const max = rvn_scrollbar_max(bar);
    length.* = base.rvn_maxf(track_length * ratio, base.rvn_minf(24.0, track_length));
    start.* = if (max > 0.0) (track_length - length.*) * (bar.*.offset / max) else 0.0;
}

export fn rvn_scrollbar_paint(bar: [*c]common.rvn_scrollbar_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter,
    track: base.rvn_rect_t, vertical: c_int, mouse_x: f32, mouse_y: f32) void {

    var start: f32 = undefined;
    var length: f32 = undefined;
    const thickness: f32 = if (vertical != 0) track.w else track.h;
    const track_length: f32 = if (vertical != 0) track.h else track.w;
    const max = rvn_scrollbar_max(bar);
    const shown: f32 = if (bar.*.shown.started != 0) bar.*.shown.value else bar.*.offset;
    var thumb: base.rvn_rect_t = undefined;

    if (rvn_scrollbar_needed(bar) == 0) return;
    rvn_scrollbar_thumb(bar, track_length, &start, &length);
    // the thumb follows what is drawn, and is squeezed against the end the content is pulled past
    if (max > 0.0) start = (track_length - length) * base.rvn_clampf(shown / max, 0.0, 1.0);
    if (shown < 0.0) {
        length = base.rvn_maxf(length + shown, 12.0);
    } else if (shown > max) {
        const squeezed = base.rvn_maxf(length - (shown - max), 12.0);
        start += length - squeezed;
        length = squeezed;
    }
    if (vertical != 0) {
        thumb = base.rvn_rect(track.x + 2.0, track.y + start + 2.0, thickness - 4.0, length - 4.0);
    } else {
        thumb = base.rvn_rect(track.x + start + 2.0, track.y + 2.0, length - 4.0, thickness - 4.0);
    }

    const hot: c_int = @intFromBool(bar.*.dragging != 0 or ((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and base.rvn_rect_contains(track, mouse_x, mouse_y) != 0));
    if (widget_h.rvn_widget_glass(widget) != 0) {
        // no track: a thin capsule over the content, thicker under the pointer, gone when nothing moves
        const active: c_int = @intFromBool(hot != 0 or (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 or ext.rvn_spring_moving(&bar.*.shown, bar.*.offset) != 0);
        const fade_target: f32 = if (active != 0) 1.0 else 0.0;
        const visible = base.rvn_clampf(ext.rvn_paint_spring(painter, &bar.*.fade, fade_target, raven.R_MOTION_SMOOTH), 0.0, 1.0);
        const slim: f32 = if (hot != 0) 1.0 else 2.0;
        if (visible < 0.02) return;
        if (vertical != 0) {
            thumb = base.rvn_rect(thumb.x + slim, thumb.y, thumb.w - slim * 2.0, thumb.h);
        } else {
            thumb = base.rvn_rect(thumb.x, thumb.y + slim, thumb.w, thumb.h - slim * 2.0);
        }
        const role_glass: raven.RColorRole = if (hot != 0) raven.R_COLOR_HANDLE_HOVERED else raven.R_COLOR_HANDLE;
        ext.rvn_paint_box(painter, thumb, thickness, base.rvn_color_fade(widget_h.rvn_widget_color(widget, role_glass), visible), 0.0, 0);
        return;
    }
    ext.rvn_paint_rect(painter, track, base.rvn_color_fade(widget_h.rvn_widget_color(widget, raven.R_COLOR_TRACK), 0.6));
    const role: raven.RColorRole = if (hot != 0) raven.R_COLOR_HANDLE_HOVERED else raven.R_COLOR_HANDLE;
    ext.rvn_paint_box(painter, thumb, (thickness - 4.0) * 0.5, widget_h.rvn_widget_color(widget, role), 0.0, 0);
}

/// Handles mouse down / move / up on the track (given in widget coordinates).
/// Returns R_TRUE when the event was used; *changed is set when the offset moved.
export fn rvn_scrollbar_event(bar: [*c]common.rvn_scrollbar_t, widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent,
    track: base.rvn_rect_t, vertical: c_int, changed: [*c]c_int) c_int {

    const track_length: f32 = if (vertical != 0) track.h else track.w;
    const position: f32 = if (vertical != 0) event.*.local_y - track.y else event.*.local_x - track.x;
    var start: f32 = undefined;
    var length: f32 = undefined;

    changed.* = raven.R_FALSE;
    if (bar.*.dragging == 0 and rvn_scrollbar_needed(bar) == 0) return raven.R_FALSE;
    rvn_scrollbar_thumb(bar, track_length, &start, &length);
    const travel = track_length - length;

    switch (event.*.type) {
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT or base.rvn_rect_contains(track, event.*.local_x, event.*.local_y) == 0) return raven.R_FALSE;
            if (position < start or position > start + length) {
                // click in the track: bring the middle of the thumb under the cursor
                if (travel > 0.0) changed.* = rvn_scrollbar_set(bar, (position - length * 0.5) / travel * rvn_scrollbar_max(bar));
                rvn_scrollbar_thumb(bar, track_length, &start, &length);
            }
            bar.*.dragging = raven.R_TRUE;
            bar.*.grab = position - start;
            ext.rvn_widget_capture_mouse(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (bar.*.dragging == 0) return raven.R_FALSE;
            if (travel > 0.0) changed.* = rvn_scrollbar_set(bar, (position - bar.*.grab) / travel * rvn_scrollbar_max(bar));
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (bar.*.dragging == 0 or event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            bar.*.dragging = raven.R_FALSE;
            ext.rvn_widget_release_mouse(widget);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}
