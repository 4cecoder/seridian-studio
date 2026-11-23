// Translated to Zig from vendor/raven/src/widgets/island.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/island.c
// Island: a small dark capsule, usually at the top of a window, that unfolds
// into a panel and folds back, like the notch of a laptop turned into a place
// for live information.
//
// It has two contents: the first child is shown while it is folded, the
// second while it is unfolded. The capsule goes from the size of one to the
// size of the other on two springs, and paints both contents itself: each
// one fades and scales with how far the capsule has gone, clipped to the
// capsule, so that nothing is ever cut by its edge or drawn outside of it.
//
// An island is dark whatever the theme: what is inside it is drawn with the
// dark counterpart of the theme (rvn_theme_dark_twin) unless it was given a
// theme of its own.
//
// What keeps it unfolded, any of:
//   - pinned: unfolded by a click or by Risland_set_expanded;
//   - held: Risland_expand_for, until its time is over;
//   - the pointer: over it (when it unfolds on hover, or once it is unfolded
//     by anything else), or over a menu opened from inside it.
// When nothing does, it folds, after a short delay if the pointer just left.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const draw_h = @import("../render/draw_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

/// Time the pointer may spend outside before an island it kept open folds back.
const RVN_ISLAND_LEAVE_DELAY = 0.28;

const rvn_island_t = extern struct {
    base: widget_h.rvn_widget_t,
    expanded: c_int,
    no_hover: c_int,
    no_click: c_int,
    /// Glued to the edge it hangs from: square corners there (a notch).
    attached: c_int,

    pinned: c_int,
    /// Risland_expand_for: when its time is over (seconds of rvn_clock_seconds), 0 = not held.
    hold_until: f64,
    /// The pointer left at this time; it folds RVN_ISLAND_LEAVE_DELAY later.
    left_at: f64,
    /// Folded by a click while under the pointer: the pointer does not unfold it again until it has left.
    hover_blocked: c_int,

    /// The size it is drawn with; it runs after the size of the content shown.
    width: raven.RSpring,
    height: raven.RSpring,
    sized: c_int,
    goal_w: f32,
    goal_h: f32,
    /// Size of the capsule around each content, from the last measure.
    folded_size: base.rvn_vec2_t,
    unfolded_size: base.rvn_vec2_t,
    timer: raven.Rid,
    callback: raven.RIslandChangedCallback,
    user_data: ?*anyopaque,
};

/// Islands that are unfolded, to fold the pinned ones when the user presses elsewhere.
const OpenIslands = extern struct {
    ids: [*c]raven.Rid,
    count: u32,
    cap: u32,
};
var g_open_islands: OpenIslands = std.mem.zeroes(OpenIslands);

fn rvn_island_content(widget: [*c]const widget_h.rvn_widget_t, expanded: c_int) [*c]widget_h.rvn_widget_t {
    const index: u32 = if (expanded != 0) 1 else 0;
    // with a single child, the island is an empty capsule that unfolds into it
    if (widget.*.child_count == 1) return if (expanded != 0) widget.*.children[0] else null;
    return if (index < widget.*.child_count) widget.*.children[index] else null;
}

/// Size of the capsule around one of its contents.
fn rvn_island_size_for(widget: [*c]const widget_h.rvn_widget_t, expanded: c_int) base.rvn_vec2_t {
    const content = rvn_island_content(widget, expanded);
    var size = if (content != null and widget_h.rvn_widget_collapsed(content) == 0) ext.rvn_widget_measure_slot(content) else base.rvn_vec2(0.0, 0.0);
    if (expanded != 0) {
        size.x = base.rvn_maxf(size.x + 36.0, 180.0);
        size.y = base.rvn_maxf(size.y + 30.0, 64.0);
    } else {
        size.x = base.rvn_maxf(size.x + 28.0, 96.0);
        size.y = base.rvn_maxf(size.y + 10.0, 30.0);
    }
    return size;
}

fn rvn_island_stop_timer(island: [*c]rvn_island_t) void {
    if (island.*.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(island.*.timer) != 0) raven.Rtimer_destroy(island.*.timer);
    island.*.timer = raven.R_INVALID_ID;
}

fn rvn_island_track(widget: [*c]widget_h.rvn_widget_t, open: c_int) void {
    var i: u32 = 0;
    while (i < g_open_islands.count) : (i += 1) {
        if (g_open_islands.ids[i] != widget.*.id) continue;
        if (open == 0) {
            g_open_islands.count -= 1;
            g_open_islands.ids[i] = g_open_islands.ids[g_open_islands.count];
        }
        return;
    }
    if (open == 0) return;
    base.RVN_ARRAY_RESERVE(&g_open_islands.ids, &g_open_islands.cap, g_open_islands.count + 1);
    g_open_islands.ids[g_open_islands.count] = widget.*.id;
    g_open_islands.count += 1;
}

fn rvn_island_set(widget: [*c]widget_h.rvn_widget_t, expanded_in: c_int, notify: c_int) void {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    // (C reassigns its parameter: `expanded = expanded != 0;`)
    const expanded: c_int = if (expanded_in != 0) 1 else 0;
    if (island.*.expanded == expanded) return;
    // what was inside stops taking the mouse and the keyboard; it fades away while the capsule changes
    const leaving = rvn_island_content(widget, island.*.expanded);
    if (leaving != null and widget.*.window != null) ext.rvn_window_forget_widget(widget.*.window, leaving);
    island.*.expanded = expanded;
    rvn_island_track(widget, expanded);
    ext.rvn_widget_invalidate_layout(widget);
    if (notify != 0) {
        if (island.*.callback) |callback| callback(widget.*.id, expanded, island.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    }
}

/// Is a menu or a list opened from inside the island still there? The pointer is then busy with the island.
fn rvn_island_has_popup(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const window: [*c]const widget_h.rvn_window_t = widget.*.window;
    var i: u32 = 0;
    if (window == null) return raven.R_FALSE;
    while (i < window.*.popup_count) : (i += 1) {
        const owner: [*c]const widget_h.rvn_widget_t = window.*.popups[i].owner;
        if (owner != null and ext.rvn_widget_is_inside(owner, widget) != 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

/// Looks at what keeps the island unfolded and unfolds it, folds it, or waits.
fn rvn_island_update(widget: [*c]widget_h.rvn_widget_t, notify: c_int) void {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    const now = ext.rvn_clock_seconds();
    const under = (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0;
    var wait: f64 = -1.0;

    if (!under) island.*.hover_blocked = raven.R_FALSE;
    if (island.*.hold_until > 0.0 and now + 0.002 >= island.*.hold_until) island.*.hold_until = 0.0;
    const held = island.*.hold_until > 0.0;
    // the pointer unfolds it when it may; once unfolded, it always keeps it so
    const hovered = under and island.*.hover_blocked == 0 and (island.*.no_hover == 0 or island.*.expanded != 0);
    const busy = island.*.expanded != 0 and rvn_island_has_popup(widget) != 0;

    rvn_island_stop_timer(island);
    if (island.*.pinned != 0 or held or hovered or busy) {
        rvn_island_set(widget, raven.R_TRUE, notify);
        if (common.rvn_widget_alive(widget) == 0) return;
        if (island.*.pinned == 0 and !hovered) {
            if (busy) wait = RVN_ISLAND_LEAVE_DELAY;
            if (held and (wait < 0.0 or island.*.hold_until - now < wait)) wait = island.*.hold_until - now;
        }
    } else if (island.*.expanded != 0) {
        // nothing keeps it: it folds, a moment after the pointer left
        const fold_at: f64 = if (island.*.left_at > 0.0) island.*.left_at + RVN_ISLAND_LEAVE_DELAY else 0.0;
        if (now + 0.002 >= fold_at) {
            island.*.left_at = 0.0;
            rvn_island_set(widget, raven.R_FALSE, notify);
        } else {
            wait = fold_at - now;
        }
    }
    if (wait >= 0.0 and common.rvn_widget_alive(widget) != 0) {
        island.*.timer = raven.Rtimer_create(@as(f64, base.rvn_maxf(@floatCast(wait), 0.001)), raven.R_FALSE, &rvn_island_timer, @ptrFromInt(@as(usize, widget.*.id)));
    }
}

fn rvn_island_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = ext.rvn_widget_get(@truncate(@intFromPtr(user_data)));
    _ = timer;
    if (widget == null or widget.*.cls.*.@"type" != raven.R_WIDGET_ISLAND) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.timer = raven.R_INVALID_ID;
    rvn_island_update(widget, raven.R_TRUE);
}

/// Folds it now, whatever kept it unfolded.
fn rvn_island_fold(widget: [*c]widget_h.rvn_widget_t, notify: c_int) void {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.pinned = raven.R_FALSE;
    island.*.hold_until = 0.0;
    island.*.left_at = 0.0;
    // (still under the pointer: it must leave before it unfolds it again)
    island.*.hover_blocked = if ((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0) 1 else 0;
    rvn_island_stop_timer(island);
    rvn_island_set(widget, raven.R_FALSE, notify);
}

export fn rvn_islands_pressed(window: [*c]widget_h.rvn_window_t, hit: [*c]widget_h.rvn_widget_t, on_popup: c_int) void {
    var i: u32 = 0;
    // (a press in a menu is not a press outside of the island the menu belongs to)
    if (on_popup != 0) return;
    while (i < g_open_islands.count) {
        const widget = ext.rvn_widget_get(g_open_islands.ids[i]);
        if (widget == null) {
            g_open_islands.count -= 1;
            g_open_islands.ids[i] = g_open_islands.ids[g_open_islands.count];
            continue;
        }
        i += 1;
        if (widget.*.window != window or (hit != null and ext.rvn_widget_is_inside(hit, widget) != 0)) continue;
        // a press anywhere else puts it away, as it closes a menu
        rvn_island_fold(widget, raven.R_TRUE);
        i = 0;
        if (window.*.dead != 0) return;
    }
}

export fn rvn_islands_shutdown() void {
    base.rvn_free(g_open_islands.ids);
    @memset(std.mem.asBytes(&g_open_islands), 0);
}

fn rvn_island_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.timer = raven.R_INVALID_ID;
    // dark whatever the theme of the application
    ext.rvn_widget_set_theme(widget, ext.rvn_theme_dark_twin(), raven.R_TRUE);
}

fn rvn_island_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    rvn_island_track(widget, raven.R_FALSE);
    // (at shutdown the timers are released with the library)
    if (ext.g_rvn.initialized != 0) rvn_island_stop_timer(@ptrCast(widget));
}

fn rvn_island_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    const folded = rvn_island_size_for(widget, raven.R_FALSE);
    const unfolded = rvn_island_size_for(widget, raven.R_TRUE);
    const target = if (island.*.expanded != 0) unfolded else folded;

    island.*.folded_size = folded;
    island.*.unfolded_size = unfolded;
    if (island.*.sized == 0) {
        ext.rvn_spring_set(&island.*.width, target.x);
        ext.rvn_spring_set(&island.*.height, target.y);
        island.*.sized = raven.R_TRUE;
        island.*.goal_w = target.x;
        island.*.goal_h = target.y;
    } else if (island.*.goal_w != target.x or island.*.goal_h != target.y) {
        // (asked once per target: each request gives the window another layout pass)
        island.*.goal_w = target.x;
        island.*.goal_h = target.y;
        // it springs open and settles shut
        const motion: raven.RMotion = if (island.*.expanded != 0) raven.R_MOTION_BOUNCY else raven.R_MOTION_SMOOTH;
        ext.rvn_widget_animate_layout(widget, &island.*.width, target.x, motion);
        ext.rvn_widget_animate_layout(widget, &island.*.height, target.y, motion);
    }
    return base.rvn_vec2(base.rvn_maxf(island.*.width.value, base.rvn_minf(folded.x, unfolded.x)), base.rvn_maxf(island.*.height.value, base.rvn_minf(folded.y, unfolded.y)));
}

fn rvn_island_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    var i: u32 = 0;
    // each content keeps the place it has in its own capsule, hung from the top and centered: the capsule opens around it
    while (i < widget.*.child_count and i < 2) : (i += 1) {
        const child = widget.*.children[i];
        const expanded: c_int = if (widget.*.child_count == 1 or i == 1) 1 else 0;
        const size = rvn_island_size_for(widget, expanded);
        const pad_x: f32 = if (expanded != 0) 18.0 else 14.0;
        const pad_y: f32 = if (expanded != 0) 15.0 else 5.0;
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        ext.rvn_widget_arrange_slot(child, base.rvn_rect(@floor((widget.*.rect.w - size.x) * 0.5) + pad_x, pad_y, base.rvn_maxf(0.0, size.x - pad_x * 2.0), base.rvn_maxf(0.0, size.y - pad_y * 2.0)));
    }
}

fn rvn_island_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    return @intFromBool(rvn_island_content(widget, island.*.expanded) == child);
}

fn rvn_smoothstep(from: f32, to: f32, x: f32) f32 {
    const t = base.rvn_clampf((x - from) / (to - from), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// One of the two contents, faded and scaled around a point of the island.
fn rvn_island_paint_content(child: [*c]widget_h.rvn_widget_t, painter: *const draw_h.RPainter, opacity: f32, scale: f32, pivot_x: f32, pivot_y: f32) void {
    var inner: draw_h.RPainter = painter.*;
    const first_instance: u32 = painter.list.*.instance_count;
    const first_command: u32 = painter.list.*.command_count;
    const px = (painter.ox + pivot_x) * painter.scale;
    const py = (painter.oy + pivot_y) * painter.scale;
    if (opacity <= 0.004 or base.rvn_box_empty(painter.clip) != 0) return;
    inner.opacity *= opacity;
    inner.clip_depth = 0;
    if (scale != 1.0) {
        // it is painted at its full size and scaled afterwards: what the capsule lets through is that much larger for now
        inner.clip = base.rvn_box(px + (painter.clip.x0 - px) / scale, py + (painter.clip.y0 - py) / scale, px + (painter.clip.x1 - px) / scale, py + (painter.clip.y1 - py) / scale);
    }
    ext.rvn_widget_paint(child, @ptrCast(&inner));
    if (scale != 1.0) {
        ext.rvn_drawlist_transform(painter.list, first_instance, first_command, scale, scale, px, py, 0.0, 0.0, painter.clip);
    }
}

fn rvn_island_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const theme = widget_h.rvn_widget_theme(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const folded = island.*.folded_size;
    const unfolded = island.*.unfolded_size;
    const span = (unfolded.x - folded.x) + (unfolded.y - folded.y);
    // how far the capsule has gone from its folded size to its unfolded one (past 1 while it bounces)
    const t: f32 = if (span > 1.0) ((rect.w - folded.x) + (rect.h - folded.y)) / span else if (island.*.expanded != 0) 1.0 else 0.0;
    const open = base.rvn_clampf(t, 0.0, 1.0);
    const hover = common.rvn_widget_hover(widget, painter, if ((widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.enabled != 0 and island.*.expanded == 0) 1 else 0);
    // a capsule when folded, a rounded panel when unfolded
    const radius = base.rvn_minf(rect.h * 0.5, 15.0 + 13.0 * open);
    var radii: [4]f32 = undefined;
    const small = rvn_island_content(widget, raven.R_FALSE);
    const large = rvn_island_content(widget, raven.R_TRUE);
    const material = widget_h.rvn_widget_material(widget);

    const top_radius: f32 = if (island.*.attached != 0) 0.0 else radius;
    radii[0] = top_radius;
    radii[1] = top_radius;
    radii[2] = radius;
    radii[3] = radius;

    if (theme.*.dark == 0) {
        // it was given a light theme: a panel of that theme
        if (material == raven.R_MATERIAL_SOLID) {
            ext.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + 3.0 + 5.0 * open, rect.w, rect.h), radius, 12.0 + 18.0 * open, ext.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
            ext.rvn_paint_box4(painter, rect, &radii, ext.rvn_widget_color(widget, raven.R_COLOR_POPUP), 1.0, ext.rvn_widget_color(widget, raven.R_COLOR_POPUP_BORDER));
        } else {
            var glass: draw_h.rvn_glass_t = undefined;
            common.rvn_glass_style(widget, common.RVN_SURFACE_POPUP, hover, 0.0, &glass);
            glass.shadow = 12.0 + 14.0 * open;
            ext.rvn_paint_glass(painter, rect, &radii, &glass);
        }
    } else if (material == raven.R_MATERIAL_SOLID) {
        const fill: base.rvn_color_t = if (ext.rvn_widget_has_color(widget, raven.R_COLOR_PANEL) != 0) ext.rvn_widget_color(widget, raven.R_COLOR_PANEL) else base.rvn_hex(0x08080A, 252);
        // two shadows: a tight one that sets it on the window, a wide one that lifts it when it opens
        ext.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + 1.0, rect.w, rect.h), radius, 5.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.30));
        ext.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + 4.0 + 8.0 * open, rect.w, rect.h), radius, 14.0 + 26.0 * open, base.rvn_rgba(0.0, 0.0, 0.0, 0.26 + 0.16 * open));
        ext.rvn_paint_box4(painter, rect, &radii, fill, 1.0, base.rvn_rgba(1.0, 1.0, 1.0, 0.085 + 0.05 * base.rvn_clampf(hover, 0.0, 1.0)));
    } else {
        // smoked glass: the window shows through, darkened enough for white text whatever is behind
        var glass = std.mem.zeroes(draw_h.rvn_glass_t);
        var tint: base.rvn_color_t = if (ext.rvn_widget_has_color(widget, raven.R_COLOR_PANEL) != 0) ext.rvn_widget_color(widget, raven.R_COLOR_PANEL) else base.rvn_hex(0x07070B, 184);
        if (material == raven.R_MATERIAL_TINTED_GLASS) tint = base.rvn_color_mix(tint, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT), 0.7), 0.45);
        glass.tint = tint;
        glass.frost = if (material == raven.R_MATERIAL_GLASS) 0.3 else 1.0;
        glass.refraction = if (material == raven.R_MATERIAL_GLASS) 18.0 else 12.0;
        glass.bevel = 7.0 + 3.0 * open;
        glass.saturation = 1.6;
        glass.rim = base.rvn_rgba(1.0, 1.0, 1.0, 0.34 + 0.12 * base.rvn_clampf(hover, 0.0, 1.0));
        glass.glow = 0.02 * base.rvn_clampf(hover, 0.0, 1.0);
        glass.shadow = 12.0 + 20.0 * open;
        glass.shadow_color = base.rvn_rgba(0.0, 0.0, 0.0, 0.34 + 0.1 * open);
        common.rvn_glass_tune(widget, &glass);
        ext.rvn_paint_glass(painter, rect, &radii, &glass);
    }

    // the contents, kept inside the capsule: the largest rectangle that stays clear of its round corners
    {
        var inner: draw_h.RPainter = dp.*;
        const inset = radius * 0.2929;
        const top: f32 = if (island.*.attached != 0) 0.0 else inset;
        const center = rect.w * 0.5;
        ext.rvn_paint_push_clip(@ptrCast(&inner), base.rvn_rect(inset, top, rect.w - inset * 2.0, rect.h - top - inset));
        // the small one leaves early, growing a little as if it were coming closer
        if (small != null) {
            rvn_island_paint_content(small, &inner, 1.0 - rvn_smoothstep(0.0, 0.3, t), 1.0 + 0.16 * open, center, folded.y * 0.5);
        }
        // the large one is hung from the top and always fits: it grows with the capsule, and shows as it gets readable
        if (large != null) {
            const fit = base.rvn_minf(rect.w / base.rvn_maxf(unfolded.x, 1.0), rect.h / base.rvn_maxf(unfolded.y, 1.0));
            rvn_island_paint_content(large, &inner, rvn_smoothstep(0.22, 0.8, t), base.rvn_clampf(fit, 0.3, 1.0), center, 0.0);
        }
    }

    // under the pointer, a folded island swells a little: it is about to open
    widget.*.xform.grow_x = 0.035 * hover;
    widget.*.xform.grow_y = 0.06 * hover;
}

fn rvn_island_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_ENTER => {
            island.*.left_at = 0.0;
            rvn_island_update(widget, raven.R_TRUE);
            if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            island.*.left_at = ext.rvn_clock_seconds();
            rvn_island_update(widget, raven.R_TRUE);
            if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            // a press on the island itself, not on a control inside it
            if (event.*.button != raven.R_MOUSE_LEFT or event.*.target != widget.*.id) return @intFromBool(event.*.target == widget.*.id);
            if (island.*.no_click != 0) return raven.R_TRUE;
            if (island.*.expanded != 0 and island.*.pinned != 0) {
                rvn_island_fold(widget, raven.R_TRUE);
            } else {
                // folded: it unfolds; unfolded by the pointer or for a while: it now stays
                island.*.pinned = raven.R_TRUE;
                island.*.hover_blocked = raven.R_FALSE;
                rvn_island_update(widget, raven.R_TRUE);
            }
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_island_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const island: [*c]rvn_island_t = @ptrCast(widget);
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Theme") == 0) {
        // its own theme, or "Default" for the one of the window instead of the dark one
        var theme: [*c]const common.rvn_theme_t = null;
        if (base.rvn_stricmp(value, "Dark twin") == 0 or base.rvn_stricmp(value, "Auto") == 0 or value[0] == 0) {
            ext.rvn_widget_set_theme(widget, ext.rvn_theme_dark_twin(), raven.R_TRUE);
            return raven.R_TRUE;
        }
        if (base.rvn_stricmp(value, "Default") != 0 and base.rvn_stricmp(value, "Inherit") != 0) {
            theme = common.rvn_xml_theme(value);
            if (theme == null) return raven.R_FALSE;
        }
        ext.rvn_widget_set_theme(widget, theme, if (theme != null) raven.R_TRUE else raven.R_FALSE);
        return raven.R_TRUE;
    }
    if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
    if (base.rvn_stricmp(name, "Expanded") == 0) {
        if (flag != 0) {
            island.*.pinned = raven.R_TRUE;
            rvn_island_update(widget, raven.R_FALSE);
        } else {
            rvn_island_fold(widget, raven.R_FALSE);
        }
    } else if (base.rvn_stricmp(name, "ExpandOnHover") == 0) {
        island.*.no_hover = if (flag == 0) 1 else 0;
    } else if (base.rvn_stricmp(name, "ExpandOnClick") == 0) {
        island.*.no_click = if (flag == 0) 1 else 0;
    } else if (base.rvn_stricmp(name, "Attached") == 0) {
        island.*.attached = flag;
        ext.rvn_widget_invalidate_paint(widget);
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export const rvn_class_island: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_ISLAND,
    .name = "Island",
    .size = @sizeOf(rvn_island_t),
    .flags = widget_h.RVN_CF_CLIP | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_OWN_CHILDREN,
    .init = rvn_island_init,
    .destroy = rvn_island_destroy,
    .measure = rvn_island_measure,
    .arrange = rvn_island_arrange,
    .paint = rvn_island_paint,
    .event = rvn_island_event,
    .set_attribute = rvn_island_set_attribute,
    .child_active = rvn_island_child_active,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Risland_create() raven.Rid {
    if (ext.rvn_api_check("Risland_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_ISLAND);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Risland_set_expanded(id: raven.Rid, expanded: c_int) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_set_expanded");
    if (widget == null) return;
    if (expanded != 0) {
        const island: [*c]rvn_island_t = @ptrCast(widget);
        island.*.pinned = raven.R_TRUE;
        island.*.hover_blocked = raven.R_FALSE;
        rvn_island_update(widget, raven.R_FALSE);
    } else {
        rvn_island_fold(widget, raven.R_FALSE);
    }
}

export fn Risland_is_expanded(id: raven.Rid) c_int {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_is_expanded");
    if (widget == null) return raven.R_FALSE;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    return island.*.expanded;
}

export fn Risland_expand_for(id: raven.Rid, seconds: f64) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_expand_for");
    if (widget == null) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.hold_until = ext.rvn_clock_seconds() + (if (seconds > 0.0) seconds else 0.0);
    island.*.hover_blocked = raven.R_FALSE;
    // (when its time is over it folds a moment after the pointer left, or at once if it is not there)
    island.*.left_at = 0.0;
    rvn_island_update(widget, raven.R_FALSE);
}

export fn Risland_set_expand_on_hover(id: raven.Rid, enabled: c_int) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_set_expand_on_hover");
    if (widget == null) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.no_hover = if (enabled == 0) 1 else 0;
}

export fn Risland_set_expand_on_click(id: raven.Rid, enabled: c_int) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_set_expand_on_click");
    if (widget == null) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.no_click = if (enabled == 0) 1 else 0;
}

export fn Risland_set_attached(id: raven.Rid, attached: c_int) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_set_attached");
    if (widget == null) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.attached = if (attached != 0) 1 else 0;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Risland_set_changed_callback(id: raven.Rid, callback: raven.RIslandChangedCallback, user_data: ?*anyopaque) void {
    const widget = ext.rvn_widget_check(id, raven.R_WIDGET_ISLAND, "Risland_set_changed_callback");
    if (widget == null) return;
    const island: [*c]rvn_island_t = @ptrCast(widget);
    island.*.callback = callback;
    island.*.user_data = user_data;
}
