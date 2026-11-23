// Translated to Zig from vendor/raven/src/widgets/tab_view.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/tab_view.c
// TabView: a bar of tabs above one visible page. Every child is a page; the
// title of its tab is the title of its slot (Rslot_set_title).
//
// Documents mode (Rtab_view_set_documents, XML Documents="true") : the major
// tabs of an application (Unreal : the level, then one tab per open asset).
// Tabs on the left with an icon and a close button (a middle click closes
// too) ; the slot keeps the icon (has_icon...) and dock_fixed (no close
// button). Too many tabs : they shrink.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");

const rvn_tab_view_t = extern struct {
    base: widget_h.rvn_widget_t,
    active: c_int,
    hot: c_int,
    callback: raven.RTabChangedCallback,
    user_data: ?*anyopaque,
    /// Left edge and width of the mark of the active tab: it slides from one tab to the next.
    mark_x: raven.RSpring,
    mark_w: raven.RSpring,
    // ---- documents mode ----
    documents: c_int,
    hot_close: c_int, // the pointer is on the close button of the hot tab
    press_close: c_int, // the close button pressed (-1 : none)
    close_callback: raven.RTabCloseCallback,
    close_user: ?*anyopaque,
    /// The page shown : kept when tabs before it come and go.
    active_page: [*c]widget_h.rvn_widget_t,
};

const RVN_TAB_ICON: f32 = 16.0;
const RVN_TAB_ICON_GAP: f32 = 6.0;
const RVN_TAB_CLOSE: f32 = 18.0;

/// (int)value of a uint32_t count or index, as the C cast does.
fn cint(value: u32) c_int {
    return @bitCast(value);
}

fn rvn_tab_view_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    tabs.*.hot = -1;
    tabs.*.press_close = -1;
}

fn rvn_tab_documents(widget: [*c]const widget_h.rvn_widget_t) c_int {
    const tabs: [*c]const rvn_tab_view_t = @ptrCast(widget);
    return tabs.*.documents;
}

fn rvn_tab_bar_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    if (rvn_tab_documents(widget) != 0) return ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT) + 10.0;
    // the segmented control of the glass themes keeps some air under it
    return ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT) + (if (widget_h.rvn_widget_glass(widget) != 0) @as(f32, 8.0) else @as(f32, 2.0));
}

fn rvn_tab_closable(widget: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(rvn_tab_documents(widget) != 0 and child.*.slot.dock_fixed == 0);
}

fn rvn_tab_title(child: [*c]const widget_h.rvn_widget_t) [*c]const u8 {
    if (child.*.slot.title != null and child.*.slot.title[0] != 0) return child.*.slot.title;
    return "Tab";
}

fn rvn_tab_natural_width(widget: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) f32 {
    var w: f32 = common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, rvn_tab_title(child)) +
        ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 2.0 + 4.0;
    if (rvn_tab_documents(widget) == 0) return w;
    if (child.*.slot.has_icon != 0) w += RVN_TAB_ICON + RVN_TAB_ICON_GAP;
    if (rvn_tab_closable(widget, child) != 0) w += RVN_TAB_CLOSE + 4.0;
    return base.rvn_clampf(w + 8.0, 96.0, 280.0);
}

// Documents : the tabs shrink when they do not fit.
fn rvn_tab_width(widget: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) f32 {
    var w: f32 = rvn_tab_natural_width(widget, child);
    if (rvn_tab_documents(widget) != 0 and widget.*.rect.w > 0.0) {
        var total: f32 = 0.0;
        var i: u32 = 0;
        while (i < widget.*.child_count) : (i += 1) total += rvn_tab_natural_width(widget, widget.*.children[i]);
        if (total > widget.*.rect.w - 8.0) w = base.rvn_maxf(48.0, w * (widget.*.rect.w - 8.0) / total);
    }
    return w;
}

// The close button of a tab (documents).
fn rvn_tab_close_rect(widget: [*c]const widget_h.rvn_widget_t, x: f32, w: f32) base.rvn_rect_t {
    const bar = rvn_tab_bar_height(widget);
    return base.rvn_rect(x + w - RVN_TAB_CLOSE - 6.0, (bar - RVN_TAB_CLOSE) * 0.5 + 1.0, RVN_TAB_CLOSE, RVN_TAB_CLOSE);
}

fn rvn_tab_view_page(widget: [*c]widget_h.rvn_widget_t) [*c]widget_h.rvn_widget_t {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    if (tabs.*.active < 0 or tabs.*.active >= cint(widget.*.child_count)) return null;
    return widget.*.children[@intCast(tabs.*.active)];
}

fn rvn_tab_view_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const page = rvn_tab_view_page(widget);
    var desired: base.rvn_vec2_t = if (page != null) ext.rvn_widget_measure_slot(page) else base.rvn_vec2(0.0, 0.0);
    var bar: f32 = 0.0;
    // documents: the major tabs fill the window, they do not grow with their pages
    // (a page bigger than the room is cut, it never pushes out of the window)
    if (rvn_tab_documents(widget) != 0) return base.rvn_vec2(0.0, rvn_tab_bar_height(widget) + 40.0);
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) bar += rvn_tab_width(widget, widget.*.children[i]);
    desired.x = base.rvn_maxf(desired.x, bar);
    desired.y += rvn_tab_bar_height(widget);
    return desired;
}

fn rvn_tab_view_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const page = rvn_tab_view_page(widget);
    const bar = rvn_tab_bar_height(widget);
    if (page != null and widget_h.rvn_widget_collapsed(page) == 0) {
        const room = base.rvn_rect(0.0, bar, widget.*.rect.w, base.rvn_maxf(0.0, widget.*.rect.h - bar));
        ext.rvn_widget_arrange_slot(page, room);
        // the page stays inside the tab view, and is cut at its edges
        if (page.*.rect.x < room.x or page.*.rect.y < room.y or page.*.rect.x + page.*.rect.w > room.x + room.w or
            page.*.rect.y + page.*.rect.h > room.y + room.h)
            ext.rvn_widget_arrange(page, room.x, room.y, room.w, room.h);
        page.*.flags |= widget_h.RVN_WF_CLIP;
    }
}

fn rvn_tab_view_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    return @intFromBool(rvn_tab_view_page(widget) == child);
}

fn rvn_tab_view_children_changed(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    // the page shown stays shown when tabs before it come and go
    if (tabs.*.active_page != null) {
        var i: u32 = 0;
        while (i < widget.*.child_count) : (i += 1) {
            if (widget.*.children[i] == tabs.*.active_page) {
                tabs.*.active = cint(i);
                break;
            }
        }
    }
    if (tabs.*.active >= cint(widget.*.child_count)) tabs.*.active = cint(widget.*.child_count) - 1;
    if (tabs.*.active < 0 and widget.*.child_count > 0) tabs.*.active = 0;
    tabs.*.active_page = if (tabs.*.active >= 0 and tabs.*.active < cint(widget.*.child_count)) widget.*.children[@intCast(tabs.*.active)] else null;
    tabs.*.hot = -1;
    tabs.*.press_close = -1;
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_tab_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32, on_close: [*c]c_int) c_int {
    var position: f32 = if (rvn_tab_documents(widget) != 0) 4.0 else 0.0;
    if (on_close != null) on_close.* = raven.R_FALSE;
    if (y < 0.0 or y >= rvn_tab_bar_height(widget)) return -1;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const width = rvn_tab_width(widget, widget.*.children[i]);
        if (x >= position and x < position + width) {
            if (on_close != null and rvn_tab_closable(widget, widget.*.children[i]) != 0)
                on_close.* = base.rvn_rect_contains(rvn_tab_close_rect(widget, position, width), x, y);
            return cint(i);
        }
        position += width;
    }
    return -1;
}

// The user closes a tab : the application may keep it (R_FALSE), else the page is deleted.
fn rvn_tab_request_close(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    if (index < 0 or index >= cint(widget.*.child_count)) return;
    const page = widget.*.children[@intCast(index)];
    if (rvn_tab_closable(widget, page) == 0) return;
    const content = page.*.id;
    if (tabs.*.close_callback) |close_callback| {
        if (close_callback(widget.*.id, index, content, tabs.*.close_user) == 0) return;
    }
    if (common.rvn_widget_alive(widget) == 0) return;
    if (raven.Rwidget_is_valid(content) != 0 and raven.Rwidget_get_parent(content) == widget.*.id) raven.Rwidget_destroy(content);
}

fn rvn_tab_view_activate(widget: [*c]widget_h.rvn_widget_t, index: c_int, notify: c_int) void {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    const previous = rvn_tab_view_page(widget);
    if (index < 0 or index >= cint(widget.*.child_count) or index == tabs.*.active) return;
    if (previous != null and widget.*.window != null) ext.rvn_window_forget_widget(widget.*.window, previous);
    // the new page comes from the side its tab is on, or the way it was told to appear (documents : at once)
    if (tabs.*.documents == 0) {
        const page = widget.*.children[@intCast(index)];
        if (page.*.fx != null and page.*.fx.*.appear != raven.R_TRANSITION_NONE and page.*.fx.*.appear != 0) {
            ext.rvn_widget_appear(page);
        } else {
            const transition: raven.RTransition = if (index > tabs.*.active) raven.R_TRANSITION_SLIDE_LEFT else raven.R_TRANSITION_SLIDE_RIGHT;
            ext.rvn_widget_play_transition(page, transition, 0.0);
        }
    }
    tabs.*.active = index;
    tabs.*.active_page = widget.*.children[@intCast(index)];
    ext.rvn_widget_invalidate_layout(widget);
    if (notify != 0) {
        if (tabs.*.callback) |callback| callback(widget.*.id, index, tabs.*.user_data);
        if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    }
}

fn rvn_tab_view_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    var index: c_int = undefined;
    var on_close: c_int = raven.R_FALSE;
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            index = rvn_tab_at(widget, event.*.local_x, event.*.local_y, &on_close);
            if (index != tabs.*.hot or on_close != tabs.*.hot_close) {
                tabs.*.hot = index;
                tabs.*.hot_close = on_close;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            if (tabs.*.hot >= 0) {
                tabs.*.hot = -1;
                tabs.*.hot_close = raven.R_FALSE;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            index = rvn_tab_at(widget, event.*.local_x, event.*.local_y, &on_close);
            if (index < 0) return raven.R_FALSE;
            if (tabs.*.documents != 0 and event.*.button == raven.R_MOUSE_MIDDLE) {
                rvn_tab_request_close(widget, index);
                return raven.R_TRUE;
            }
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            if (on_close != 0) {
                tabs.*.press_close = index;
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            }
            rvn_tab_view_activate(widget, index, raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (tabs.*.press_close < 0 or event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            index = rvn_tab_at(widget, event.*.local_x, event.*.local_y, &on_close);
            {
                const pressed = tabs.*.press_close;
                tabs.*.press_close = -1;
                ext.rvn_widget_invalidate_paint(widget);
                if (index == pressed and on_close != 0) rvn_tab_request_close(widget, index);
            }
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_tab_view_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    const bar = rvn_tab_bar_height(widget);
    var position: f32 = 0.0;
    const text: base.rvn_color_t = ext.rvn_widget_text_color(widget, painter);
    var mark_x: f32 = 0.0;
    var mark_w: f32 = 0.0;
    var i: u32 = 0;

    // where the mark of the active tab is now: it slides to its tab, stretched by its own speed
    while (i < widget.*.child_count) : (i += 1) {
        const width = rvn_tab_width(widget, widget.*.children[i]);
        if (cint(i) == tabs.*.active) {
            mark_x = position;
            mark_w = width;
        }
        position += width;
    }
    position = 0.0;
    mark_x = ext.rvn_paint_spring(painter, &tabs.*.mark_x, mark_x, raven.R_MOTION_BOUNCY);
    mark_w = ext.rvn_paint_spring(painter, &tabs.*.mark_w, mark_w, raven.R_MOTION_BOUNCY);
    const stretch = base.rvn_minf(@abs(tabs.*.mark_x.velocity) * 0.018, mark_w * 0.35);
    mark_x -= stretch * 0.5;
    mark_w += stretch;

    if (tabs.*.documents != 0) {
        // the major tabs of the application : left aligned, icon, title, close button
        var x: f32 = 4.0;
        const radius = base.rvn_minf(6.0, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) + 2.0);
        const padding = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X);
        ext.rvn_paint_rect(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, bar), widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER));
        ext.rvn_paint_rect(painter, base.rvn_rect(0.0, bar - 1.0, widget.*.rect.w, 1.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
        i = 0;
        while (i < widget.*.child_count) : (i += 1) {
            const page = widget.*.children[i];
            const width = rvn_tab_width(widget, page);
            const is_active = cint(i) == tabs.*.active;
            const is_hot = cint(i) == tabs.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0;
            const closable = rvn_tab_closable(widget, page) != 0;
            const tab = base.rvn_rect(x, 4.0, width - 2.0, bar - 4.0);
            const color: base.rvn_color_t = if (is_active) text else base.rvn_color_fade(text, if (is_hot) 0.85 else 0.6);
            const radii = [4]f32{ radius, radius, 0.0, 0.0 };
            var tx: f32 = tab.x + padding;
            if (is_active) {
                ext.rvn_paint_box4(painter, base.rvn_rect(tab.x, tab.y, tab.w, tab.h + 1.0), &radii, widget_h.rvn_widget_color(widget, raven.R_COLOR_TAB_ACTIVE), 0.0, 0);
                ext.rvn_paint_box4(painter, base.rvn_rect(tab.x, tab.y, tab.w, 2.0), &radii, widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT), 0.0, 0);
            } else if (is_hot) {
                ext.rvn_paint_box4(painter, tab, &radii, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER_HOVERED), 0.0, 0);
            } else if (i + 1 < widget.*.child_count and cint(i) + 1 != tabs.*.active) {
                ext.rvn_paint_rect(painter, base.rvn_rect(tab.x + tab.w + 0.5, tab.y + 7.0, 1.0, tab.h - 14.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
            }
            ext.rvn_paint_push_clip(painter, base.rvn_rect(tab.x, tab.y, base.rvn_maxf(0.0, tab.w - (if (closable) RVN_TAB_CLOSE + 8.0 else @as(f32, 4.0))), tab.h));
            if (page.*.slot.has_icon != 0) {
                const tint: base.rvn_color_t = if (page.*.slot.icon_tint != 0) color else base.rvn_rgba(1.0, 1.0, 1.0, if (is_active) 1.0 else 0.75);
                ext.rvn_paint_image(painter, base.rvn_rect(tx, @floor(tab.y + (tab.h - RVN_TAB_ICON) * 0.5), RVN_TAB_ICON, RVN_TAB_ICON),
                    page.*.slot.icon, &page.*.slot.icon_uv, tint, 0.0);
                tx += RVN_TAB_ICON + RVN_TAB_ICON_GAP;
            }
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), base.rvn_rect(tx, tab.y, tab.x + tab.w - tx, tab.h), 0.0,
                rvn_tab_title(page), -1, color);
            ext.rvn_paint_pop_clip(painter);
            if (closable and (is_active or is_hot)) {
                const close = rvn_tab_close_rect(widget, x, width);
                const over = is_hot and tabs.*.hot_close != 0;
                if (over or tabs.*.press_close == cint(i))
                    ext.rvn_paint_box(painter, close, RVN_TAB_CLOSE * 0.5, widget_h.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED), 0.0, 0);
                ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CROSS, close.x + RVN_TAB_CLOSE * 0.5, close.y + RVN_TAB_CLOSE * 0.5, 7.0,
                    if (over) text else base.rvn_color_fade(text, 0.6));
            }
            x += width;
        }
        return;
    }
    if (widget_h.rvn_widget_glass(widget) != 0) {
        // a segmented control: a capsule holding the titles, the active one on a lighter pill of glass
        var total: f32 = 0.0;
        i = 0;
        while (i < widget.*.child_count) : (i += 1) total += rvn_tab_width(widget, widget.*.children[i]);
        if (total > 0.0) {
            ext.rvn_paint_box(painter, base.rvn_rect(0.0, 2.0, total, bar - 6.0), (bar - 6.0) * 0.5,
                widget_h.rvn_widget_color(widget, raven.R_COLOR_TRACK), 0.0, 0);
        }
        if (tabs.*.active >= 0 and mark_w > 4.0) {
            const pill = base.rvn_rect(mark_x + 2.0, 4.0, mark_w - 4.0, bar - 10.0);
            common.rvn_paint_surface(painter, widget, pill, pill.h * 0.5, common.RVN_SURFACE_CONTROL, 1.0, 0.6);
        }
        i = 0;
        while (i < widget.*.child_count) : (i += 1) {
            const width = rvn_tab_width(widget, widget.*.children[i]);
            const rect = base.rvn_rect(position, 2.0, width, bar - 6.0);
            const pill = base.rvn_rect(rect.x + 2.0, rect.y + 2.0, rect.w - 4.0, rect.h - 4.0);
            if (cint(i) == tabs.*.active) {
                // (its pill is the mark drawn above)
            } else if (cint(i) == tabs.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0) {
                ext.rvn_paint_box(painter, pill, pill.h * 0.5, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER_HOVERED), 0.0, 0);
            }
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), rect, 0.5,
                rvn_tab_title(widget.*.children[i]), -1, if (cint(i) == tabs.*.active) text else base.rvn_color_fade(text, 0.62));
            position += width;
        }
        return;
    }
    ext.rvn_paint_rect(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, bar), widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER));
    ext.rvn_paint_rect(painter, base.rvn_rect(0.0, bar - 1.0, widget.*.rect.w, 1.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
    if (tabs.*.active >= 0 and mark_w > 0.0) {
        ext.rvn_paint_rect(painter, base.rvn_rect(mark_x, 0.0, mark_w, bar), widget_h.rvn_widget_color(widget, raven.R_COLOR_TAB_ACTIVE));
        ext.rvn_paint_rect(painter, base.rvn_rect(mark_x, 0.0, mark_w, 2.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT));
    }
    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const width = rvn_tab_width(widget, widget.*.children[i]);
        const rect = base.rvn_rect(position, 0.0, width, bar);
        if (cint(i) == tabs.*.active) {
            // (its background is the mark drawn above)
        } else if (cint(i) == tabs.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0) {
            ext.rvn_paint_rect(painter, rect, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER_HOVERED));
        }
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), rect, 0.5,
            rvn_tab_title(widget.*.children[i]), -1,
            if (cint(i) == tabs.*.active) text else base.rvn_color_mix(text, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER), 0.3));
        position += width;
    }
}

fn rvn_tab_view_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    var index: c_int = undefined;
    if (base.rvn_stricmp(name, "ActiveTab") == 0) {
        if (ext.rvn_parse_int(value, &index) == 0) return raven.R_FALSE;
        rvn_tab_view_activate(widget, index, raven.R_FALSE);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Documents") == 0) {
        if (ext.rvn_parse_bool(value, &index) == 0) return raven.R_FALSE;
        const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
        tabs.*.documents = index;
        ext.rvn_widget_invalidate_layout(widget);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export const rvn_class_tab_view: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_TAB_VIEW,
    .name = "TabView",
    .size = @sizeOf(rvn_tab_view_t),
    .flags = widget_h.RVN_CF_SURFACE,
    .init = rvn_tab_view_init,
    .measure = rvn_tab_view_measure,
    .arrange = rvn_tab_view_arrange,
    .paint = rvn_tab_view_paint,
    .event = rvn_tab_view_event,
    .set_attribute = rvn_tab_view_set_attribute,
    .child_active = rvn_tab_view_child_active,
    .children_changed = rvn_tab_view_children_changed,
});

export fn Rtab_view_add_tab(id: raven.Rid, title: [*c]const u8, content: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_add_tab");
    if (widget == null) return -1;
    const page = widget_h.rvn_widget_check(content, 0, "Rtab_view_add_tab");
    if (page == null) return -1;
    if (widget_h.rvn_widget_is_inside(widget, page) != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtab_view_add_tab: the content contains the tab view");
        return -1;
    }
    _ = base.rvn_str_set(&page.*.slot.title, title);
    widget_h.rvn_widget_add_child(widget, page, -1);
    return cint(widget.*.child_count) - 1;
}

export fn Rtab_view_set_active(id: raven.Rid, index: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_active");
    if (widget == null) return;
    rvn_tab_view_activate(widget, index, raven.R_FALSE);
}

export fn Rtab_view_get_active(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_get_active");
    if (widget == null) return -1;
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    return tabs.*.active;
}

export fn Rtab_view_set_changed_callback(id: raven.Rid, callback: raven.RTabChangedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_changed_callback");
    if (widget == null) return;
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    tabs.*.callback = callback;
    tabs.*.user_data = user_data;
}

// ---- documents mode, tabs by their page ----

fn rvn_tab_page_of(widget: [*c]widget_h.rvn_widget_t, content: raven.Rid, function: [*c]const u8) [*c]widget_h.rvn_widget_t {
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget.*.children[i].*.id == content) return widget.*.children[i];
    }
    base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: the widget is not a page of the tab view", function);
    return null;
}

export fn Rtab_view_set_documents(id: raven.Rid, documents: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_documents");
    if (widget == null) return;
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    tabs.*.documents = @intFromBool(documents != 0);
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rtab_view_get_tab_count(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_get_tab_count");
    if (widget == null) return 0;
    return cint(widget.*.child_count);
}

export fn Rtab_view_get_tab(id: raven.Rid, index: c_int) raven.Rid {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_get_tab");
    if (widget == null) return raven.R_INVALID_ID;
    if (index < 0 or index >= cint(widget.*.child_count)) return raven.R_INVALID_ID;
    return widget.*.children[@intCast(index)].*.id;
}

export fn Rtab_view_find_tab(id: raven.Rid, content: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_find_tab");
    if (widget == null) return -1;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget.*.children[i].*.id == content) return cint(i);
    }
    return -1;
}

export fn Rtab_view_set_tab_title(id: raven.Rid, content: raven.Rid, title: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_tab_title");
    if (widget == null) return;
    const page = rvn_tab_page_of(widget, content, "Rtab_view_set_tab_title");
    if (page == null) return;
    const text: [*c]const u8 = if (title != null) title else "";
    _ = base.rvn_str_set(&page.*.slot.title, text);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtab_view_set_tab_icon(id: raven.Rid, content: raven.Rid, texture: raven.Rid, u0_: f32, v0_: f32, u1_: f32, v1_: f32, tint: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_tab_icon");
    if (widget == null) return;
    const page = rvn_tab_page_of(widget, content, "Rtab_view_set_tab_icon");
    if (page == null) return;
    page.*.slot.has_icon = @intFromBool(texture != raven.R_INVALID_ID);
    page.*.slot.icon = texture;
    page.*.slot.icon_uv[0] = u0_;
    page.*.slot.icon_uv[1] = v0_;
    page.*.slot.icon_uv[2] = u1_;
    page.*.slot.icon_uv[3] = v1_;
    page.*.slot.icon_tint = @intFromBool(tint != 0);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtab_view_set_tab_closable(id: raven.Rid, content: raven.Rid, closable: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_tab_closable");
    if (widget == null) return;
    const page = rvn_tab_page_of(widget, content, "Rtab_view_set_tab_closable");
    if (page == null) return;
    page.*.slot.dock_fixed = @intFromBool(closable == 0);
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rtab_view_show_tab(id: raven.Rid, content: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_show_tab");
    if (widget == null) return;
    const index = Rtab_view_find_tab(id, content);
    if (index >= 0) rvn_tab_view_activate(widget, index, raven.R_TRUE);
}

export fn Rtab_view_set_close_callback(id: raven.Rid, callback: raven.RTabCloseCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_TAB_VIEW, "Rtab_view_set_close_callback");
    if (widget == null) return;
    const tabs: [*c]rvn_tab_view_t = @ptrCast(widget);
    tabs.*.close_callback = callback;
    tabs.*.close_user = user_data;
}
