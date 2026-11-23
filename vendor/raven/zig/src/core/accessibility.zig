// Translated to Zig from vendor/raven/src/core/accessibility.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/accessibility.c
// Sight (text size, contrast, focus, motion, color filters) and the tree
// that screen readers see (core/accessibility.h). UI thread.

const std = @import("std");
const raven = @import("raven");
const base = @import("base_h.zig");
const ctx_h = @import("context_h.zig");
const handle_h = @import("handle_h.zig");
const thread_h = @import("thread_h.zig");
const a11y_h = @import("accessibility_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const libc = @import("../sys/libc.zig");

// What a widget says of itself, allocated on first use (rvn_widget_t::a11y).
// widget_h declares rvn_widget_t.a11y as an opaque pointer: this is the real layout, see a11yOf.
const rvn_a11y_t = extern struct {
    name: [*c]u8,
    description: [*c]u8,
    role: raven.RAccessibleRole,
    hidden: c_int,
    labelled_by: raven.Rid,
};

// The record of a widget, from the opaque pointer of widget_h (the struct is private to this file).
fn a11yOf(ptr: ?*widget_h.rvn_a11y_t) [*c]rvn_a11y_t {
    return @ptrCast(@alignCast(ptr));
}

// The platform table (g_rvn.platform is typed ?*const anyopaque in context_h).
fn currentPlatform() [*c]const plat_h.rvn_platform_t {
    return @ptrCast(@alignCast(ctx_h.g_rvn.platform));
}

var g_a11y: struct {
    text_scale: f32,
    high_contrast: c_int,
    theme_before: [*c]u8,
    focus_always: c_int,
    filter: raven.RColorFilter,
    // the screen reader: asked to the platform at most once a second
    active: c_int,
    active_checked: f64,
    // bumped when widgets come or go: the tree changed
    generation: u32,
    // strings of rvn_a11y_describe and Rwidget_get_accessible_name
    name: base.rvn_text_t,
    value: base.rvn_text_t,
    description: base.rvn_text_t,
    scratch: base.rvn_text_t,
    linear: [256]f32,
    linear_ready: c_int,
} = .{
    .text_scale = 1.0,
    .high_contrast = 0,
    .theme_before = null,
    .focus_always = 0,
    .filter = raven.R_COLOR_FILTER_NONE,
    .active = 0,
    .active_checked = -10.0,
    .generation = 0,
    .name = std.mem.zeroes(base.rvn_text_t),
    .value = std.mem.zeroes(base.rvn_text_t),
    .description = std.mem.zeroes(base.rvn_text_t),
    .scratch = std.mem.zeroes(base.rvn_text_t),
    .linear = std.mem.zeroes([256]f32),
    .linear_ready = 0,
};

// ---------------------------------------------------------------------------
//  Settings read by the rest of the library
// ---------------------------------------------------------------------------

export fn rvn_a11y_text_scale() f32 {
    return g_a11y.text_scale;
}

export fn rvn_a11y_focus_always() c_int {
    return @intFromBool(g_a11y.focus_always != 0 or g_a11y.high_contrast != 0);
}

export fn rvn_a11y_focus_width() f32 {
    return if (g_a11y.focus_always != 0 or g_a11y.high_contrast != 0) 3.0 else 2.0;
}

export fn rvn_a11y_structure_changed() void {
    g_a11y.generation +%= 1;
}

export fn rvn_a11y_widget_destroyed(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.a11y == null) return;
    const a = a11yOf(widget.*.a11y);
    base.rvn_free(a.*.name);
    base.rvn_free(a.*.description);
    base.rvn_free(a);
    widget.*.a11y = null;
    g_a11y.generation +%= 1;
}

export fn rvn_a11y_shutdown() void {
    base.rvn_free(g_a11y.theme_before);
    base.rvn_free(g_a11y.name.data);
    base.rvn_free(g_a11y.value.data);
    base.rvn_free(g_a11y.description.data);
    base.rvn_free(g_a11y.scratch.data);
    g_a11y.name = std.mem.zeroes(base.rvn_text_t);
    g_a11y.value = std.mem.zeroes(base.rvn_text_t);
    g_a11y.description = std.mem.zeroes(base.rvn_text_t);
    g_a11y.scratch = std.mem.zeroes(base.rvn_text_t);
    g_a11y.theme_before = null;
    g_a11y.text_scale = 1.0;
    g_a11y.high_contrast = 0;
    g_a11y.focus_always = 0;
    g_a11y.filter = raven.R_COLOR_FILTER_NONE;
    g_a11y.active = 0;
    g_a11y.active_checked = -10.0;
}

// ---------------------------------------------------------------------------
//  Color filters, applied to the colors of a frame (widget/window.c)
// ---------------------------------------------------------------------------

fn rvn_srgb_to_linear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else libc.powf((c + 0.055) / 1.055, 2.4);
}

fn rvn_linear_to_srgb(c_: f32) f32 {
    const c = base.rvn_clampf(c_, 0.0, 1.0);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * libc.powf(c, 1.0 / @as(f32, 2.4)) - 0.055;
}

// Machado, Oliveira and Fernandes (2009), severity 1, in linear RGB.
const g_sim_protan = [9]f32{ 0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998 };
const g_sim_deutan = [9]f32{ 0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881 };
const g_sim_tritan = [9]f32{ 1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900 };

fn rvn_mul3(m: [*c]const f32, in: [*c]const f32, out: [*c]f32) void {
    out[0] = m[0] * in[0] + m[1] * in[1] + m[2] * in[2];
    out[1] = m[3] * in[0] + m[4] * in[1] + m[5] * in[2];
    out[2] = m[6] * in[0] + m[7] * in[1] + m[8] * in[2];
}

fn rvn_a11y_filter_color(color: u32, filter: raven.RColorFilter) u32 {
    var rgb: [3]f32 = undefined;
    var out: [3]f32 = undefined;
    var sim: [3]f32 = undefined;
    var matrix: [*c]const f32 = null;
    const a: u32 = color >> 24;
    if (g_a11y.linear_ready == 0) {
        var i: c_int = 0;
        while (i < 256) : (i += 1) {
            g_a11y.linear[@intCast(i)] = rvn_srgb_to_linear(@as(f32, @floatFromInt(i)) / 255.0);
        }
        g_a11y.linear_ready = 1;
    }
    rgb[0] = g_a11y.linear[color & 0xFF];
    rgb[1] = g_a11y.linear[(color >> 8) & 0xFF];
    rgb[2] = g_a11y.linear[(color >> 16) & 0xFF];

    switch (filter) {
        raven.R_COLOR_FILTER_PROTANOPIA, raven.R_COLOR_FILTER_SIMULATE_PROTANOPIA => {
            matrix = &g_sim_protan;
        },
        raven.R_COLOR_FILTER_DEUTERANOPIA, raven.R_COLOR_FILTER_SIMULATE_DEUTERANOPIA => {
            matrix = &g_sim_deutan;
        },
        raven.R_COLOR_FILTER_TRITANOPIA, raven.R_COLOR_FILTER_SIMULATE_TRITANOPIA => {
            matrix = &g_sim_tritan;
        },
        else => {},
    }
    switch (filter) {
        raven.R_COLOR_FILTER_GRAYSCALE, raven.R_COLOR_FILTER_SIMULATE_ACHROMATOPSIA => {
            const y: f32 = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
            out[0] = y;
            out[1] = y;
            out[2] = y;
        },
        raven.R_COLOR_FILTER_INVERT => {
            // (in sRGB: inverted perceived lightness)
            const r: u32 = 255 - (color & 0xFF);
            const g: u32 = 255 - ((color >> 8) & 0xFF);
            const b: u32 = 255 - ((color >> 16) & 0xFF);
            return r | (g << 8) | (b << 16) | (a << 24);
        },
        raven.R_COLOR_FILTER_SIMULATE_PROTANOPIA, raven.R_COLOR_FILTER_SIMULATE_DEUTERANOPIA, raven.R_COLOR_FILTER_SIMULATE_TRITANOPIA => {
            rvn_mul3(matrix, &rgb, &out);
        },
        raven.R_COLOR_FILTER_PROTANOPIA, raven.R_COLOR_FILTER_DEUTERANOPIA => {
            // daltonization: what is lost is moved into the channels that are seen
            var error_: [3]f32 = undefined;
            rvn_mul3(matrix, &rgb, &sim);
            error_[0] = rgb[0] - sim[0];
            error_[1] = rgb[1] - sim[1];
            error_[2] = rgb[2] - sim[2];
            out[0] = rgb[0];
            out[1] = rgb[1] + 0.7 * error_[0] + error_[1];
            out[2] = rgb[2] + 0.7 * error_[0] + error_[2];
        },
        raven.R_COLOR_FILTER_TRITANOPIA => {
            var error_: [3]f32 = undefined;
            rvn_mul3(matrix, &rgb, &sim);
            error_[0] = rgb[0] - sim[0];
            error_[1] = rgb[1] - sim[1];
            error_[2] = rgb[2] - sim[2];
            out[0] = rgb[0] + error_[0] + 0.7 * error_[2];
            out[1] = rgb[1] + error_[1] + 0.7 * error_[2];
            out[2] = rgb[2];
        },
        else => return color,
    }
    return @as(u32, @intFromFloat(rvn_linear_to_srgb(out[0]) * 255.0 + 0.5)) |
        (@as(u32, @intFromFloat(rvn_linear_to_srgb(out[1]) * 255.0 + 0.5)) << 8) |
        (@as(u32, @intFromFloat(rvn_linear_to_srgb(out[2]) * 255.0 + 0.5)) << 16) | (a << 24);
}

export fn rvn_a11y_filter_instances(instances: [*c]raven.RDrawInstance, count: u32) void {
    var i: u32 = 0;
    const filter = g_a11y.filter;
    if (filter == raven.R_COLOR_FILTER_NONE) return;
    while (i < count) : (i += 1) {
        const instance = &instances[i];
        const prim: u32 = instance.flags & raven.R_PRIM_MASK;
        // pictures keep their colors (their tint, white, is not changed either)
        if ((instance.flags & raven.R_INSTANCE_TEXTURED) != 0 and prim != raven.R_PRIM_GLYPH) continue;
        instance.color = rvn_a11y_filter_color(instance.color, filter);
        instance.border_color = rvn_a11y_filter_color(instance.border_color, filter);
    }
}

// ---------------------------------------------------------------------------
//  The tree
// ---------------------------------------------------------------------------

const RVN_ITEM_SHIFT = 32;

fn rvn_a11y_rid(id: a11y_h.rvn_a11y_id_t) raven.Rid {
    return @truncate(id);
}

fn rvn_a11y_item(id: a11y_h.rvn_a11y_id_t) c_int {
    return @as(c_int, @bitCast(@as(u32, @truncate(id >> RVN_ITEM_SHIFT)))) - 1;
}

fn rvn_a11y_make_item(widget: raven.Rid, index: c_int) a11y_h.rvn_a11y_id_t {
    return @as(a11y_h.rvn_a11y_id_t, widget) | (@as(a11y_h.rvn_a11y_id_t, @as(u32, @bitCast(index + 1))) << RVN_ITEM_SHIFT);
}

fn rvn_a11y_as_window(id: a11y_h.rvn_a11y_id_t) [*c]widget_h.rvn_window_t {
    if ((id >> RVN_ITEM_SHIFT) != 0) return null;
    return @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.windows, rvn_a11y_rid(id))));
}

fn rvn_a11y_as_widget(id: a11y_h.rvn_a11y_id_t) [*c]widget_h.rvn_widget_t {
    const widget: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.widgets, rvn_a11y_rid(id))));
    return if (widget != null and (widget.*.flags & widget_h.RVN_WF_DEAD) == 0) widget else null;
}

export fn rvn_a11y_window_of(platform_user: ?*anyopaque) raven.Rid {
    const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(platform_user));
    return if (window != null) window.*.id else raven.R_INVALID_ID;
}

fn rvn_a11y_default_role(widget: [*c]const widget_h.rvn_widget_t) raven.RAccessibleRole {
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_LABEL => return raven.R_ROLE_TEXT,
        raven.R_WIDGET_BUTTON => return raven.R_ROLE_BUTTON,
        raven.R_WIDGET_CHECKBOX => return raven.R_ROLE_CHECKBOX,
        raven.R_WIDGET_SLIDER => return raven.R_ROLE_SLIDER,
        raven.R_WIDGET_PROGRESSBAR => return raven.R_ROLE_PROGRESS_BAR,
        raven.R_WIDGET_IMAGE => return if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.name != null) raven.R_ROLE_IMAGE else raven.R_ROLE_NONE,
        raven.R_WIDGET_TEXT_INPUT => return raven.R_ROLE_TEXT_FIELD,
        raven.R_WIDGET_SPIN_BOX => return raven.R_ROLE_SPIN_BUTTON,
        raven.R_WIDGET_COMBO_BOX => return raven.R_ROLE_COMBO_BOX,
        raven.R_WIDGET_SEPARATOR => return raven.R_ROLE_SEPARATOR,
        raven.R_WIDGET_LIST_VIEW => return raven.R_ROLE_LIST,
        raven.R_WIDGET_TILE_VIEW => return raven.R_ROLE_LIST,
        raven.R_WIDGET_TREE_VIEW => return raven.R_ROLE_TREE,
        raven.R_WIDGET_MENU_BAR => return raven.R_ROLE_MENU_BAR,
        raven.R_WIDGET_MENU => return raven.R_ROLE_MENU,
        raven.R_WIDGET_MENU_ITEM => return raven.R_ROLE_MENU_ITEM,
        raven.R_WIDGET_TAB_VIEW => return raven.R_ROLE_TAB_LIST,
        raven.R_WIDGET_EXPANDER => return raven.R_ROLE_GROUP,
        raven.R_WIDGET_ISLAND => return raven.R_ROLE_GROUP,
        raven.R_WIDGET_HEADER_BAR => return raven.R_ROLE_TOOLBAR,
        raven.R_WIDGET_TEXT_EDITOR => return raven.R_ROLE_DOCUMENT,
        raven.R_WIDGET_FILE_BROWSER => return raven.R_ROLE_GROUP,
        raven.R_WIDGET_COLOR_PICKER => return raven.R_ROLE_GROUP,
        raven.R_WIDGET_VIEWPORT, raven.R_WIDGET_TIMELINE, raven.R_WIDGET_NODE_GRAPH, raven.R_WIDGET_BLOCK_EDITOR => return raven.R_ROLE_CANVAS,
        // boxes, grids, borders, scroll boxes...: layout only, unless named
        else => return if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.name != null) raven.R_ROLE_GROUP else raven.R_ROLE_NONE,
    }
}

fn rvn_a11y_role_of(widget: [*c]const widget_h.rvn_widget_t) raven.RAccessibleRole {
    if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.role != raven.R_ROLE_AUTO) return a11yOf(widget.*.a11y).*.role;
    // a page of a tab view is a tab panel
    if (widget.*.parent != null and widget.*.parent.*.cls.*.type == raven.R_WIDGET_TAB_VIEW) return raven.R_ROLE_TAB_PANEL;
    return rvn_a11y_default_role(widget);
}

// Roles whose children are only how they look: a button and its label are one thing.
fn rvn_a11y_is_leaf(role: raven.RAccessibleRole) c_int {
    switch (role) {
        raven.R_ROLE_TEXT, raven.R_ROLE_HEADING, raven.R_ROLE_LINK, raven.R_ROLE_BUTTON, raven.R_ROLE_TOGGLE_BUTTON,
        raven.R_ROLE_CHECKBOX, raven.R_ROLE_RADIO_BUTTON, raven.R_ROLE_SLIDER, raven.R_ROLE_PROGRESS_BAR, raven.R_ROLE_SPIN_BUTTON,
        raven.R_ROLE_TEXT_FIELD, raven.R_ROLE_DOCUMENT, raven.R_ROLE_COMBO_BOX, raven.R_ROLE_MENU_ITEM, raven.R_ROLE_TAB,
        raven.R_ROLE_IMAGE, raven.R_ROLE_SEPARATOR, raven.R_ROLE_LIST_ITEM, raven.R_ROLE_TREE_ITEM,
        => return raven.R_TRUE,
        else => return raven.R_FALSE,
    }
}

fn rvn_a11y_visible(widget: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(widget.*.visibility == raven.R_VISIBLE and !(widget.*.a11y != null and a11yOf(widget.*.a11y).*.hidden != 0));
}

// A widget that is a node: shown, not hidden, not inside a leaf, with a role.
fn rvn_a11y_exposed(widget: [*c]const widget_h.rvn_widget_t) c_int {
    if (rvn_a11y_role_of(widget) == raven.R_ROLE_NONE) return raven.R_FALSE;
    var walk: [*c]const widget_h.rvn_widget_t = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if (rvn_a11y_visible(walk) == 0) return raven.R_FALSE;
        if (walk != widget and rvn_a11y_is_leaf(rvn_a11y_role_of(walk)) != 0) return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// The exposed children of a widget, the layout widgets flattened. Returns the count; fills out[0..max).
fn rvn_a11y_collect(widget: [*c]const widget_h.rvn_widget_t, out: [*c][*c]widget_h.rvn_widget_t, max: c_int, count_: c_int) c_int {
    var count = count_;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]widget_h.rvn_widget_t = widget.*.children[i];
        if (rvn_a11y_visible(child) == 0 or (child.*.flags & widget_h.RVN_WF_DEAD) != 0) continue;
        // only the page that is shown of a tab view
        if (widget.*.cls.*.type == raven.R_WIDGET_TAB_VIEW and @as(c_int, @intCast(i)) != raven.Rtab_view_get_active(widget.*.id)) continue;
        if (rvn_a11y_role_of(child) == raven.R_ROLE_NONE) {
            count = rvn_a11y_collect(child, out, max, count);
        } else {
            if (out != null and count < max) out[@intCast(count)] = child;
            count += 1;
        }
    }
    return count;
}

// Items shown as children of a widget (rows of a list, tabs).
fn rvn_a11y_item_count(widget: [*c]const widget_h.rvn_widget_t) c_int {
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_LIST_VIEW => return raven.Rlist_view_get_item_count(widget.*.id),
        raven.R_WIDGET_TREE_VIEW => return raven.Rtree_view_get_item_count(widget.*.id),
        raven.R_WIDGET_TAB_VIEW => return @intCast(widget.*.child_count),
        else => return 0,
    }
}

fn rvn_a11y_widget_child_count(widget: [*c]const widget_h.rvn_widget_t) c_int {
    if (rvn_a11y_is_leaf(rvn_a11y_role_of(widget)) != 0) return 0;
    return rvn_a11y_item_count(widget) + rvn_a11y_collect(widget, null, 0, 0);
}

fn rvn_a11y_widget_child(widget: [*c]const widget_h.rvn_widget_t, index_: c_int) a11y_h.rvn_a11y_id_t {
    var index = index_;
    var count: c_int = undefined;
    const items = rvn_a11y_item_count(widget);
    if (index < 0) return 0;
    if (index < items) return rvn_a11y_make_item(widget.*.id, index);
    index -= items;
    // (the children before the one asked for are counted, not kept)
    {
        var result: a11y_h.rvn_a11y_id_t = 0;
        count = rvn_a11y_collect(widget, null, 0, 0);
        if (index >= count) return 0;
        const all: [*c][*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(count)) * @sizeOf([*c]widget_h.rvn_widget_t))));
        _ = rvn_a11y_collect(widget, all, count, 0);
        result = all[@intCast(index)].*.id;
        base.rvn_free(@ptrCast(all));
        return result;
    }
}

// The widgets that are the top of a window: content, island, open popups.
fn rvn_a11y_window_tops(window: [*c]widget_h.rvn_window_t, tops: [*c][*c]widget_h.rvn_widget_t, max: c_int) c_int {
    var count: c_int = 0;
    var i: u32 = 0;
    if (window.*.root != null and count < max) {
        tops[@intCast(count)] = window.*.root;
        count += 1;
    }
    if (window.*.island != null and count < max) {
        tops[@intCast(count)] = window.*.island;
        count += 1;
    }
    while (i < window.*.popup_count and count < max) : (i += 1) {
        tops[@intCast(count)] = window.*.popups[i].root;
        count += 1;
    }
    return count;
}

fn rvn_a11y_window_child_count(window: [*c]widget_h.rvn_window_t) c_int {
    var tops: [16][*c]widget_h.rvn_widget_t = undefined;
    const n = rvn_a11y_window_tops(window, &tops, 16);
    var i: c_int = 0;
    var count: c_int = 0;
    while (i < n) : (i += 1) {
        if (rvn_a11y_visible(tops[@intCast(i)]) == 0) continue;
        if (rvn_a11y_role_of(tops[@intCast(i)]) == raven.R_ROLE_NONE) {
            count += rvn_a11y_collect(tops[@intCast(i)], null, 0, 0);
        } else {
            count += 1;
        }
    }
    return count;
}

fn rvn_a11y_window_child(window: [*c]widget_h.rvn_window_t, index_: c_int) a11y_h.rvn_a11y_id_t {
    var index = index_;
    var tops: [16][*c]widget_h.rvn_widget_t = undefined;
    const n = rvn_a11y_window_tops(window, &tops, 16);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (rvn_a11y_visible(tops[@intCast(i)]) == 0) continue;
        if (rvn_a11y_role_of(tops[@intCast(i)]) != raven.R_ROLE_NONE) {
            if (index == 0) return tops[@intCast(i)].*.id;
            index -= 1;
            continue;
        }
        const here = rvn_a11y_collect(tops[@intCast(i)], null, 0, 0);
        if (index < here) {
            const all: [*c][*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(here)) * @sizeOf([*c]widget_h.rvn_widget_t))));
            _ = rvn_a11y_collect(tops[@intCast(i)], all, here, 0);
            const id = all[@intCast(index)].*.id;
            base.rvn_free(@ptrCast(all));
            return id;
        }
        index -= here;
    }
    return 0;
}

// The node a widget is part of: itself, or the nearest exposed ancestor, or its window.
fn rvn_a11y_node_of(widget: [*c]widget_h.rvn_widget_t) a11y_h.rvn_a11y_id_t {
    var walk: [*c]widget_h.rvn_widget_t = widget;
    var best: [*c]widget_h.rvn_widget_t = null;
    while (walk != null) : (walk = walk.*.parent) {
        if (rvn_a11y_role_of(walk) != raven.R_ROLE_NONE and rvn_a11y_visible(walk) != 0) {
            // a leaf above takes what is inside it
            if (best == null or rvn_a11y_is_leaf(rvn_a11y_role_of(walk)) != 0) best = walk;
        }
    }
    // (a leaf high up wins; else the deepest exposed one)
    walk = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if (rvn_a11y_exposed(walk) != 0) {
            var leaf: [*c]widget_h.rvn_widget_t = null;
            var up: [*c]widget_h.rvn_widget_t = walk.*.parent;
            while (up != null) : (up = up.*.parent) {
                if (rvn_a11y_visible(up) != 0 and rvn_a11y_is_leaf(rvn_a11y_role_of(up)) != 0) leaf = up;
            }
            return if (leaf != null) leaf.*.id else walk.*.id;
        }
    }
    return if (widget.*.window != null) @as(a11y_h.rvn_a11y_id_t, widget.*.window.*.id) else 0;
}

export fn rvn_a11y_exists(id: a11y_h.rvn_a11y_id_t) c_int {
    if (rvn_a11y_as_window(id) != null) return raven.R_TRUE;
    const widget = rvn_a11y_as_widget(id);
    if (widget == null or widget.*.window == null) return raven.R_FALSE;
    if (rvn_a11y_item(id) >= 0) return @intFromBool(rvn_a11y_item(id) < rvn_a11y_item_count(widget));
    return rvn_a11y_exposed(widget);
}

export fn rvn_a11y_window(id: a11y_h.rvn_a11y_id_t) raven.Rid {
    if (rvn_a11y_as_window(id) != null) return rvn_a11y_rid(id);
    const widget = rvn_a11y_as_widget(id);
    return if (widget != null and widget.*.window != null) widget.*.window.*.id else raven.R_INVALID_ID;
}

export fn rvn_a11y_parent(id: a11y_h.rvn_a11y_id_t) a11y_h.rvn_a11y_id_t {
    if (rvn_a11y_as_window(id) != null) return 0;
    const widget = rvn_a11y_as_widget(id);
    if (widget == null) return 0;
    if (rvn_a11y_item(id) >= 0) return widget.*.id;
    var walk: [*c]widget_h.rvn_widget_t = widget.*.parent;
    while (walk != null) : (walk = walk.*.parent) {
        if (rvn_a11y_role_of(walk) != raven.R_ROLE_NONE and rvn_a11y_visible(walk) != 0) return walk.*.id;
    }
    return if (widget.*.window != null) @as(a11y_h.rvn_a11y_id_t, widget.*.window.*.id) else 0;
}

export fn rvn_a11y_child_count(id: a11y_h.rvn_a11y_id_t) c_int {
    const window = rvn_a11y_as_window(id);
    if (window != null) return rvn_a11y_window_child_count(window);
    const widget = rvn_a11y_as_widget(id);
    if (widget == null or rvn_a11y_item(id) >= 0) return 0;
    return rvn_a11y_widget_child_count(widget);
}

export fn rvn_a11y_child(id: a11y_h.rvn_a11y_id_t, index: c_int) a11y_h.rvn_a11y_id_t {
    const window = rvn_a11y_as_window(id);
    if (window != null) return rvn_a11y_window_child(window, index);
    const widget = rvn_a11y_as_widget(id);
    if (widget == null or rvn_a11y_item(id) >= 0 or rvn_a11y_is_leaf(rvn_a11y_role_of(widget)) != 0) return 0;
    return rvn_a11y_widget_child(widget, index);
}

export fn rvn_a11y_index_in_parent(id: a11y_h.rvn_a11y_id_t) c_int {
    const parent = rvn_a11y_parent(id);
    if (parent == 0) return -1;
    const count = rvn_a11y_child_count(parent);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (rvn_a11y_child(parent, i) == id) return i;
    }
    return -1;
}

fn rvn_a11y_deepest(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) [*c]widget_h.rvn_widget_t {
    if (rvn_a11y_visible(widget) == 0) return null;
    if (x < 0.0 or y < 0.0 or x > widget.*.rect.w or y > widget.*.rect.h) return null;
    var i: u32 = widget.*.child_count;
    while (i > 0) : (i -= 1) {
        const child = widget.*.children[i - 1];
        const hit = rvn_a11y_deepest(child, x - child.*.rect.x, y - child.*.rect.y);
        if (hit != null) return hit;
    }
    return widget;
}

export fn rvn_a11y_hit(id: raven.Rid, x: f32, y: f32) a11y_h.rvn_a11y_id_t {
    const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.windows, id)));
    var tops: [16][*c]widget_h.rvn_widget_t = undefined;
    if (window == null) return 0;
    const n = rvn_a11y_window_tops(window, &tops, 16);
    var i: c_int = n - 1;
    while (i >= 0) : (i -= 1) {
        const top = tops[@intCast(i)];
        const hit = rvn_a11y_deepest(top, x - top.*.rect.x, y - top.*.rect.y);
        if (hit != null) return rvn_a11y_node_of(hit);
    }
    return @as(a11y_h.rvn_a11y_id_t, id);
}

export fn rvn_a11y_focus(id: raven.Rid) a11y_h.rvn_a11y_id_t {
    const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.windows, id)));
    if (window == null) return 0;
    if (window.*.focus == null or (window.*.focus.*.flags & widget_h.RVN_WF_DEAD) != 0) return @as(a11y_h.rvn_a11y_id_t, id);
    // the selected row of a list that has the focus
    if (window.*.focus.*.cls.*.type == raven.R_WIDGET_LIST_VIEW) {
        const selected = raven.Rlist_view_get_selected(window.*.focus.*.id);
        if (selected >= 0) return rvn_a11y_make_item(window.*.focus.*.id, selected);
    }
    return rvn_a11y_node_of(window.*.focus);
}

// ---------------------------------------------------------------------------
//  What a node is
// ---------------------------------------------------------------------------

// The texts shown inside a widget, one after the other.
fn rvn_a11y_inner_text(widget: [*c]const widget_h.rvn_widget_t, out: [*c]base.rvn_text_t, depth: c_int) void {
    if (depth > 8 or rvn_a11y_visible(widget) == 0) return;
    if (widget.*.cls.*.type == raven.R_WIDGET_LABEL) {
        const text = raven.Rlabel_get_text(widget.*.id);
        if (text != null and text[0] != 0) {
            if (out.*.length != 0) base.rvn_text_add(out, " ");
            base.rvn_text_add(out, text);
        }
        return;
    }
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) rvn_a11y_inner_text(widget.*.children[i], out, depth + 1);
}

// For a field without a name: the label just before it in its container (a form).
fn rvn_a11y_label_before(widget: [*c]const widget_h.rvn_widget_t) [*c]const widget_h.rvn_widget_t {
    var walk: [*c]const widget_h.rvn_widget_t = widget;
    var depth: c_int = 0;
    while (walk != null and walk.*.parent != null and depth < 3) : ({
        depth += 1;
        walk = walk.*.parent;
    }) {
        const parent = walk.*.parent;
        var i: u32 = 0;
        var at: u32 = 0;
        while (i < parent.*.child_count) : (i += 1) {
            if (parent.*.children[i] == walk) at = i;
        }
        while (at > 0) {
            at -= 1;
            const before: [*c]const widget_h.rvn_widget_t = parent.*.children[at];
            if (rvn_a11y_visible(before) == 0) continue;
            if (before.*.cls.*.type == raven.R_WIDGET_LABEL) return before;
            // a label inside a box of layout before it (a row of a form), not inside a button
            if (before.*.child_count == 1 and before.*.children[0].*.cls.*.type == raven.R_WIDGET_LABEL and rvn_a11y_role_of(before) == raven.R_ROLE_NONE) {
                return before.*.children[0];
            }
            break;
        }
    }
    return null;
}

fn rvn_a11y_name_of(widget: [*c]const widget_h.rvn_widget_t, role: raven.RAccessibleRole, out: [*c]base.rvn_text_t) void {
    out.*.length = 0;
    if (out.*.data != null) out.*.data[0] = 0;
    if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.name != null) {
        base.rvn_text_add(out, a11yOf(widget.*.a11y).*.name);
        return;
    }
    if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.labelled_by != 0) {
        const labelled = a11yOf(widget.*.a11y).*.labelled_by;
        const text: [*c]const u8 = if (raven.Rwidget_get_type(labelled) == raven.R_WIDGET_LABEL) raven.Rlabel_get_text(labelled) else null;
        if (text != null) {
            base.rvn_text_add(out, text);
            return;
        }
    }
    // the widgets that draw their text themselves
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_CHECKBOX => {
            base.rvn_text_add(out, raven.Rcheckbox_get_text(widget.*.id));
        },
        raven.R_WIDGET_MENU_ITEM => {
            base.rvn_text_add(out, raven.Rmenu_item_get_text(widget.*.id));
        },
        raven.R_WIDGET_EXPANDER => {
            base.rvn_text_add(out, raven.Rexpander_get_title(widget.*.id));
        },
        else => {},
    }
    if (out.*.length != 0) return;
    switch (role) {
        raven.R_ROLE_TEXT, raven.R_ROLE_HEADING, raven.R_ROLE_LINK, raven.R_ROLE_BUTTON, raven.R_ROLE_TOGGLE_BUTTON,
        raven.R_ROLE_CHECKBOX, raven.R_ROLE_RADIO_BUTTON, raven.R_ROLE_MENU_ITEM, raven.R_ROLE_GROUP, raven.R_ROLE_TAB,
        => {
            rvn_a11y_inner_text(widget, out, 0);
        },
        raven.R_ROLE_TAB_PANEL => {
            if (widget.*.slot.title != null) base.rvn_text_add(out, widget.*.slot.title);
        },
        else => {},
    }
    if (out.*.length == 0 and (role == raven.R_ROLE_TEXT_FIELD or role == raven.R_ROLE_SPIN_BUTTON or role == raven.R_ROLE_SLIDER or role == raven.R_ROLE_COMBO_BOX or
        role == raven.R_ROLE_PROGRESS_BAR or role == raven.R_ROLE_DOCUMENT or role == raven.R_ROLE_LIST or role == raven.R_ROLE_TREE or role == raven.R_ROLE_CHECKBOX))
    {
        const label = rvn_a11y_label_before(widget);
        if (label != null) base.rvn_text_add(out, raven.Rlabel_get_text(label.*.id));
    }
    // last: the tooltip
    if (out.*.length == 0 and widget.*.tooltip != null) base.rvn_text_add(out, widget.*.tooltip);
}

fn rvn_a11y_reset(text: [*c]base.rvn_text_t) void {
    text.*.length = 0;
    if (text.*.data != null) text.*.data[0] = 0;
}

fn rvn_a11y_str(text: [*c]base.rvn_text_t) [*c]const u8 {
    return if (text.*.data != null) text.*.data else "";
}

export fn rvn_a11y_describe(id: a11y_h.rvn_a11y_id_t, node: [*c]a11y_h.rvn_a11y_node_t) c_int {
    const window = rvn_a11y_as_window(id);
    node.* = std.mem.zeroes(a11y_h.rvn_a11y_node_t);
    node.*.id = id;
    rvn_a11y_reset(&g_a11y.name);
    rvn_a11y_reset(&g_a11y.value);
    rvn_a11y_reset(&g_a11y.description);

    if (window != null) {
        const size = widget_h.rvn_window_size(window);
        node.*.role = raven.R_ROLE_WINDOW;
        if (window.*.title != null) base.rvn_text_add(&g_a11y.name, window.*.title);
        node.*.width = size.x;
        node.*.height = size.y;
        node.*.name = rvn_a11y_str(&g_a11y.name);
        node.*.value = "";
        node.*.description = "";
        return raven.R_TRUE;
    }
    const widget = rvn_a11y_as_widget(id);
    if (widget == null) return raven.R_FALSE;
    const item = rvn_a11y_item(id);
    {
        const origin = widget_h.rvn_widget_origin(widget);
        node.*.x = origin.x;
        node.*.y = origin.y;
        node.*.width = widget.*.rect.w;
        node.*.height = widget.*.rect.h;
    }
    {
        var walk: [*c]const widget_h.rvn_widget_t = widget;
        while (walk != null) : (walk = walk.*.parent) {
            if ((walk.*.flags & widget_h.RVN_WF_DISABLED) != 0) node.*.states |= a11y_h.RVN_A11Y_DISABLED;
        }
    }

    if (item >= 0) {
        // a row, a tab
        switch (widget.*.cls.*.type) {
            raven.R_WIDGET_LIST_VIEW => {
                const text = raven.Rlist_view_get_item_text(widget.*.id, item);
                node.*.role = raven.R_ROLE_LIST_ITEM;
                if (text != null) base.rvn_text_add(&g_a11y.name, text);
                node.*.states |= a11y_h.RVN_A11Y_SELECTABLE | a11y_h.RVN_A11Y_INVOKABLE;
                if (raven.Rlist_view_get_selected(widget.*.id) == item) node.*.states |= a11y_h.RVN_A11Y_SELECTED;
                if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0 and raven.Rlist_view_get_selected(widget.*.id) == item) {
                    node.*.states |= a11y_h.RVN_A11Y_FOCUSED;
                }
            },
            raven.R_WIDGET_TREE_VIEW => {
                const tree_item = raven.Rtree_view_get_item(widget.*.id, item);
                const text: [*c]const u8 = if (tree_item != 0) raven.Rtree_item_get_text(tree_item) else null;
                node.*.role = raven.R_ROLE_TREE_ITEM;
                if (text != null) base.rvn_text_add(&g_a11y.name, text);
                node.*.states |= a11y_h.RVN_A11Y_SELECTABLE | a11y_h.RVN_A11Y_INVOKABLE | a11y_h.RVN_A11Y_EXPANDABLE;
                if (tree_item != 0 and raven.Rtree_item_is_expanded(tree_item) != 0) node.*.states |= a11y_h.RVN_A11Y_EXPANDED;
                if (tree_item != 0 and raven.Rtree_view_get_selected_item(widget.*.id) == tree_item) node.*.states |= a11y_h.RVN_A11Y_SELECTED;
            },
            raven.R_WIDGET_TAB_VIEW => {
                const page: [*c]widget_h.rvn_widget_t = if (@as(u32, @intCast(item)) < widget.*.child_count) widget.*.children[@intCast(item)] else null;
                node.*.role = raven.R_ROLE_TAB;
                if (page != null and page.*.a11y != null and a11yOf(page.*.a11y).*.name != null) {
                    base.rvn_text_add(&g_a11y.name, a11yOf(page.*.a11y).*.name);
                } else if (page != null and page.*.slot.title != null) {
                    base.rvn_text_add(&g_a11y.name, page.*.slot.title);
                }
                node.*.states |= a11y_h.RVN_A11Y_SELECTABLE | a11y_h.RVN_A11Y_INVOKABLE;
                if (raven.Rtab_view_get_active(widget.*.id) == item) node.*.states |= a11y_h.RVN_A11Y_SELECTED;
            },
            else => return raven.R_FALSE,
        }
        node.*.name = rvn_a11y_str(&g_a11y.name);
        node.*.value = "";
        node.*.description = "";
        return raven.R_TRUE;
    }

    node.*.role = rvn_a11y_role_of(widget);
    rvn_a11y_name_of(widget, node.*.role, &g_a11y.name);
    if (widget.*.a11y != null and a11yOf(widget.*.a11y).*.description != null) {
        base.rvn_text_add(&g_a11y.description, a11yOf(widget.*.a11y).*.description);
    } else if (widget.*.tooltip != null and libc.strcmp(widget.*.tooltip, rvn_a11y_str(&g_a11y.name)) != 0) {
        base.rvn_text_add(&g_a11y.description, widget.*.tooltip);
    }
    if ((widget.*.flags & widget_h.RVN_WF_FOCUSABLE) != 0) node.*.states |= a11y_h.RVN_A11Y_FOCUSABLE;
    if ((widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0) node.*.states |= a11y_h.RVN_A11Y_FOCUSED;

    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_BUTTON => {
            node.*.states |= a11y_h.RVN_A11Y_INVOKABLE;
        },
        raven.R_WIDGET_MENU_ITEM => {
            node.*.states |= a11y_h.RVN_A11Y_INVOKABLE;
            if (raven.Rmenu_item_is_checked(widget.*.id) != 0) node.*.states |= a11y_h.RVN_A11Y_CHECKED | a11y_h.RVN_A11Y_CHECKABLE;
        },
        raven.R_WIDGET_CHECKBOX => {
            node.*.states |= a11y_h.RVN_A11Y_CHECKABLE | a11y_h.RVN_A11Y_INVOKABLE;
            if (raven.Rcheckbox_is_checked(widget.*.id) != 0) node.*.states |= a11y_h.RVN_A11Y_CHECKED;
        },
        raven.R_WIDGET_SLIDER => {
            var minimum: f32 = 0.0;
            var maximum: f32 = 1.0;
            var step: f32 = 0.0;
            raven.Rslider_get_range(widget.*.id, &minimum, &maximum, &step);
            node.*.number = raven.Rslider_get_value(widget.*.id);
            node.*.minimum = minimum;
            node.*.maximum = maximum;
            node.*.step = if (step > 0.0) @as(f64, step) else @as(f64, maximum - minimum) / 100.0;
            node.*.states |= a11y_h.RVN_A11Y_HAS_RANGE;
            base.rvn_text_printf(&g_a11y.value, "%g", node.*.number);
        },
        raven.R_WIDGET_PROGRESSBAR => {
            node.*.number = @as(f64, raven.Rprogress_bar_get_value(widget.*.id)) * 100.0;
            node.*.minimum = 0.0;
            node.*.maximum = 100.0;
            node.*.states |= a11y_h.RVN_A11Y_HAS_RANGE | a11y_h.RVN_A11Y_READONLY;
            base.rvn_text_printf(&g_a11y.value, "%.0f%%", node.*.number);
        },
        raven.R_WIDGET_SPIN_BOX => {
            var minimum: f64 = 0.0;
            var maximum: f64 = 0.0;
            var step: f64 = 1.0;
            raven.Rspin_box_get_range(widget.*.id, &minimum, &maximum, &step);
            node.*.number = raven.Rspin_box_get_value(widget.*.id);
            node.*.minimum = minimum;
            node.*.maximum = maximum;
            node.*.step = step;
            node.*.states |= a11y_h.RVN_A11Y_HAS_RANGE;
            base.rvn_text_printf(&g_a11y.value, "%g", node.*.number);
        },
        raven.R_WIDGET_TEXT_INPUT => {
            const text = raven.Rtext_input_get_text(widget.*.id);
            node.*.states |= a11y_h.RVN_A11Y_EDITABLE;
            if (raven.Rtext_input_is_read_only(widget.*.id) != 0) node.*.states |= a11y_h.RVN_A11Y_READONLY;
            if (raven.Rtext_input_is_password(widget.*.id) != 0) {
                const n: usize = if (text != null) @intCast(base.rvn_utf8_count(text, @intCast(libc.strlen(text)))) else 0;
                var i: usize = 0;
                node.*.states |= a11y_h.RVN_A11Y_PASSWORD;
                while (i < n) : (i += 1) base.rvn_text_add(&g_a11y.value, "\xE2\x80\xA2");
            } else if (text != null) {
                base.rvn_text_add(&g_a11y.value, text);
            }
        },
        raven.R_WIDGET_TEXT_EDITOR => {
            const text = raven.Rtext_editor_get_text(widget.*.id);
            node.*.states |= a11y_h.RVN_A11Y_EDITABLE | a11y_h.RVN_A11Y_MULTILINE;
            if (text != null) base.rvn_text_add(&g_a11y.value, text);
        },
        raven.R_WIDGET_COMBO_BOX => {
            const selected = raven.Rcombo_box_get_selected(widget.*.id);
            const text: [*c]const u8 = if (selected >= 0) raven.Rcombo_box_get_item_text(widget.*.id, selected) else null;
            node.*.states |= a11y_h.RVN_A11Y_EXPANDABLE | a11y_h.RVN_A11Y_INVOKABLE;
            if (text != null) base.rvn_text_add(&g_a11y.value, text);
        },
        raven.R_WIDGET_LIST_VIEW => {
            const selected = raven.Rlist_view_get_selected(widget.*.id);
            const text: [*c]const u8 = if (selected >= 0) raven.Rlist_view_get_item_text(widget.*.id, selected) else null;
            if (text != null) base.rvn_text_add(&g_a11y.value, text);
        },
        raven.R_WIDGET_TREE_VIEW => {
            const selected = raven.Rtree_view_get_selected_item(widget.*.id);
            const text: [*c]const u8 = if (selected != 0) raven.Rtree_item_get_text(selected) else null;
            if (text != null) base.rvn_text_add(&g_a11y.value, text);
        },
        raven.R_WIDGET_EXPANDER => {
            node.*.states |= a11y_h.RVN_A11Y_EXPANDABLE | a11y_h.RVN_A11Y_INVOKABLE;
            if (raven.Rexpander_is_expanded(widget.*.id) != 0) node.*.states |= a11y_h.RVN_A11Y_EXPANDED;
        },
        raven.R_WIDGET_ISLAND => {
            node.*.states |= a11y_h.RVN_A11Y_EXPANDABLE;
            if (raven.Risland_is_expanded(widget.*.id) != 0) node.*.states |= a11y_h.RVN_A11Y_EXPANDED;
        },
        else => {},
    }
    if ((widget.*.flags & widget_h.RVN_WF_POPUP) != 0 and widget.*.cls.*.type != raven.R_WIDGET_MENU) node.*.states |= a11y_h.RVN_A11Y_MODAL;
    node.*.name = rvn_a11y_str(&g_a11y.name);
    node.*.value = rvn_a11y_str(&g_a11y.value);
    node.*.description = rvn_a11y_str(&g_a11y.description);
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Actions from the screen reader
// ---------------------------------------------------------------------------

// What the keyboard would do: the widget handles it as if the user pressed the key.
fn rvn_a11y_key(widget_: [*c]widget_h.rvn_widget_t, key: raven.RKey) void {
    var event: raven.REvent = undefined;
    var widget = widget_;
    const id = widget.*.id;
    widget_h.rvn_widget_focus(widget);
    if (widget.*.cls.*.event == null) return;
    event = std.mem.zeroes(raven.REvent);
    event.type = raven.R_EVENT_KEY_DOWN;
    event.key = key;
    event.target = id;
    _ = widget.*.cls.*.event.?(widget, &event);
    widget = widget_h.rvn_widget_get(id);
    if (widget == null or widget.*.cls.*.event == null) return;
    event.type = raven.R_EVENT_KEY_UP;
    _ = widget.*.cls.*.event.?(widget, &event);
}

export fn rvn_a11y_act(id: a11y_h.rvn_a11y_id_t, action: a11y_h.rvn_a11y_action_t) c_int {
    const widget = rvn_a11y_as_widget(id);
    const item = rvn_a11y_item(id);
    if (widget == null) return raven.R_FALSE;
    if (action == a11y_h.RVN_A11Y_FOCUS) {
        widget_h.rvn_widget_focus(widget);
        if (item >= 0 and widget.*.cls.*.type == raven.R_WIDGET_LIST_VIEW) raven.Rlist_view_set_selected(widget.*.id, item);
        return raven.R_TRUE;
    }
    if (item >= 0) {
        switch (widget.*.cls.*.type) {
            raven.R_WIDGET_LIST_VIEW => {
                raven.Rlist_view_set_selected(widget.*.id, item);
                return raven.R_TRUE;
            },
            raven.R_WIDGET_TAB_VIEW => {
                raven.Rtab_view_set_active(widget.*.id, item);
                return raven.R_TRUE;
            },
            raven.R_WIDGET_TREE_VIEW => {
                const tree_item = raven.Rtree_view_get_item(widget.*.id, item);
                if (tree_item == 0) return raven.R_FALSE;
                if (action == a11y_h.RVN_A11Y_EXPAND or action == a11y_h.RVN_A11Y_COLLAPSE) {
                    raven.Rtree_item_set_expanded(tree_item, @intFromBool(action == a11y_h.RVN_A11Y_EXPAND));
                } else {
                    raven.Rtree_view_set_selected_item(widget.*.id, tree_item);
                }
                return raven.R_TRUE;
            },
            else => return raven.R_FALSE,
        }
    }
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_BUTTON, raven.R_WIDGET_MENU_ITEM => {
            rvn_a11y_key(widget, raven.R_KEY_ENTER);
            return raven.R_TRUE;
        },
        raven.R_WIDGET_CHECKBOX => {
            rvn_a11y_key(widget, raven.R_KEY_SPACE);
            return raven.R_TRUE;
        },
        raven.R_WIDGET_EXPANDER => {
            raven.Rexpander_set_expanded(widget.*.id, if (action == a11y_h.RVN_A11Y_EXPAND) raven.R_TRUE else if (action == a11y_h.RVN_A11Y_COLLAPSE) raven.R_FALSE else @intFromBool(raven.Rexpander_is_expanded(widget.*.id) == 0));
            return raven.R_TRUE;
        },
        raven.R_WIDGET_ISLAND => {
            raven.Risland_set_expanded(widget.*.id, if (action == a11y_h.RVN_A11Y_EXPAND) raven.R_TRUE else if (action == a11y_h.RVN_A11Y_COLLAPSE) raven.R_FALSE else @intFromBool(raven.Risland_is_expanded(widget.*.id) == 0));
            return raven.R_TRUE;
        },
        raven.R_WIDGET_COMBO_BOX => {
            rvn_a11y_key(widget, raven.R_KEY_SPACE);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

export fn rvn_a11y_set_value(id: a11y_h.rvn_a11y_id_t, text: [*c]const u8) c_int {
    const widget = rvn_a11y_as_widget(id);
    var end: [*c]u8 = null;
    var number: f64 = undefined;
    if (widget == null or text == null or rvn_a11y_item(id) >= 0) return raven.R_FALSE;
    switch (widget.*.cls.*.type) {
        raven.R_WIDGET_TEXT_INPUT => {
            if (raven.Rtext_input_is_read_only(widget.*.id) != 0) return raven.R_FALSE;
            raven.Rtext_input_set_text(widget.*.id, text);
            return raven.R_TRUE;
        },
        raven.R_WIDGET_TEXT_EDITOR => {
            raven.Rtext_editor_set_text(widget.*.id, text);
            return raven.R_TRUE;
        },
        raven.R_WIDGET_SLIDER, raven.R_WIDGET_SPIN_BOX => {
            number = libc.strtod(text, &end);
            if (end == text) return raven.R_FALSE;
            return rvn_a11y_set_number(id, number);
        },
        else => return raven.R_FALSE,
    }
}

export fn rvn_a11y_set_number(id: a11y_h.rvn_a11y_id_t, value: f64) c_int {
    const widget = rvn_a11y_as_widget(id);
    if (widget == null or rvn_a11y_item(id) >= 0) return raven.R_FALSE;
    if (widget.*.cls.*.type == raven.R_WIDGET_SLIDER) {
        raven.Rslider_set_value(widget.*.id, @floatCast(value));
        return raven.R_TRUE;
    }
    if (widget.*.cls.*.type == raven.R_WIDGET_SPIN_BOX) {
        raven.Rspin_box_set_value(widget.*.id, value);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export fn rvn_a11y_window_origin(id: a11y_h.rvn_a11y_id_t, x: [*c]c_int, y: [*c]c_int, scale: [*c]f32) void {
    const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.windows, rvn_a11y_window(id))));
    x.* = 0;
    y.* = 0;
    scale.* = 1.0;
    const platform = currentPlatform();
    if (window == null or window.*.platform == null or platform == null) return;
    if (platform.*.window_get_position) |get_position| get_position(window.*.platform, x, y);
    if (platform.*.window_get_scale) |get_scale| scale.* = get_scale(window.*.platform);
    if (!(scale.* > 0.0)) scale.* = 1.0;
}

export fn rvn_a11y_screen_rect(id: a11y_h.rvn_a11y_id_t, x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int) void {
    var node: a11y_h.rvn_a11y_node_t = undefined;
    var wx: c_int = undefined;
    var wy: c_int = undefined;
    var scale: f32 = undefined;
    x.* = 0;
    y.* = 0;
    width.* = 0;
    height.* = 0;
    if (rvn_a11y_describe(id, &node) == 0) return;
    rvn_a11y_window_origin(id, &wx, &wy, &scale);
    x.* = wx + @as(c_int, @intFromFloat(@floor(node.x * scale + 0.5)));
    y.* = wy + @as(c_int, @intFromFloat(@floor(node.y * scale + 0.5)));
    width.* = @as(c_int, @intFromFloat(@floor(node.width * scale + 0.5)));
    height.* = @as(c_int, @intFromFloat(@floor(node.height * scale + 0.5)));
}

export fn rvn_a11y_locale() [*c]const u8 {
    const language = raven.Rlocale_get_language();
    return if (language != null and language[0] != 0) language else "en";
}

export fn rvn_a11y_role_name(role: raven.RAccessibleRole) [*c]const u8 {
    const names = [_][*c]const u8{
        "none",         "window",      "group",       "text",     "heading",    "link",         "button",       "toggle button", "check box",  "radio button",
        "slider",       "progress bar", "spin button", "text field", "document",   "combo box",    "list",         "list item",    "tree",       "tree item",
        "table",        "menu bar",    "menu",        "menu item",  "tab list",   "tab",          "tab panel",    "tool bar",      "status bar", "dialog",
        "alert",        "image",       "canvas",      "separator",  "scroll bar", "pane",
    };
    const index: c_int = @as(c_int, @bitCast(role)) - raven.R_ROLE_NONE;
    return if (index >= 0 and index < names.len) names[@intCast(index)] else "unknown";
}

// ---------------------------------------------------------------------------
//  Events: after each frame of a window (widget/window.c)
// ---------------------------------------------------------------------------

fn rvn_a11y_platform_active() c_int {
    const now = thread_h.rvn_clock_seconds();
    const platform = currentPlatform();
    if (platform == null or platform.*.a11y_event == null) return raven.R_FALSE;
    if (now - g_a11y.active_checked > 1.0) {
        g_a11y.active_checked = now;
        g_a11y.active = if (platform.*.a11y_active) |is_active| is_active() else raven.R_TRUE;
    }
    return g_a11y.active;
}

fn rvn_a11y_hash(node: [*c]const a11y_h.rvn_a11y_node_t) u32 {
    var h: u32 = 2166136261;
    var c: [*c]const u8 = node.*.name;
    while (c != null and c[0] != 0) : (c += 1) h = (h ^ @as(u32, c[0])) *% 16777619;
    h = (h ^ 0xFF) *% 16777619;
    var v: [*c]const u8 = node.*.value;
    while (v != null and v[0] != 0) : (v += 1) h = (h ^ @as(u32, v[0])) *% 16777619;
    h ^= node.*.states *% 2654435761;
    // (uint32_t)(double): the value is taken through 64 bits, as x86-64 compilers do
    const wide: u64 = @bitCast(@as(i64, @intFromFloat(node.*.number * 1000.0)));
    h ^= @as(u32, @truncate(wide));
    return h;
}

export fn rvn_a11y_frame(window: [*c]widget_h.rvn_window_t) void {
    var node: a11y_h.rvn_a11y_node_t = undefined;
    const platform = currentPlatform();
    if (window.*.platform == null or rvn_a11y_platform_active() == 0) return;
    const focus = rvn_a11y_focus(window.*.id);
    if (g_a11y.generation != window.*.a11y_generation) {
        window.*.a11y_generation = g_a11y.generation;
        platform.*.a11y_event.?(window.*.platform, a11y_h.RVN_A11Y_EVENT_STRUCTURE, @as(u64, window.*.id));
    }
    if (rvn_a11y_describe(focus, &node) == 0) return;
    const hash = rvn_a11y_hash(&node);
    if (focus != window.*.a11y_focus) {
        window.*.a11y_focus = focus;
        window.*.a11y_hash = hash;
        platform.*.a11y_event.?(window.*.platform, a11y_h.RVN_A11Y_EVENT_FOCUS, focus);
    } else if (hash != window.*.a11y_hash) {
        window.*.a11y_hash = hash;
        platform.*.a11y_event.?(window.*.platform, a11y_h.RVN_A11Y_EVENT_VALUE, focus);
    }
}

// ---------------------------------------------------------------------------
//  Public API: sight
// ---------------------------------------------------------------------------

export fn Raccessibility_set_text_scale(scale: f32) void {
    if (ctx_h.rvn_api_check("Raccessibility_set_text_scale") == 0) return;
    if (!(scale >= 0.5 and scale <= 4.0)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Raccessibility_set_text_scale: the scale goes from 0.5 to 4");
        return;
    }
    if (scale == g_a11y.text_scale) return;
    g_a11y.text_scale = scale;
    // every size changes: measure everything again
    widget_h.rvn_theme_changed();
}

export fn Raccessibility_get_text_scale() f32 {
    if (ctx_h.rvn_api_check("Raccessibility_get_text_scale") == 0) return 1.0;
    return g_a11y.text_scale;
}

export fn Raccessibility_set_high_contrast(enabled_: c_int) void {
    if (ctx_h.rvn_api_check("Raccessibility_set_high_contrast") == 0) return;
    const enabled: c_int = @intFromBool(enabled_ != 0);
    if (enabled == g_a11y.high_contrast) return;
    if (enabled != 0) {
        const current = raven.Rtheme_get_name();
        const dark = raven.Rtheme_is_dark();
        _ = base.rvn_str_set(&g_a11y.theme_before, if (current != null) current else "Dark");
        g_a11y.high_contrast = 1;
        raven.Rtheme_apply(if (dark != 0) raven.R_THEME_HIGH_CONTRAST_DARK else raven.R_THEME_HIGH_CONTRAST_LIGHT);
    } else {
        g_a11y.high_contrast = 0;
        if (g_a11y.theme_before == null or raven.Rtheme_use(g_a11y.theme_before) == 0) raven.Rtheme_apply(raven.R_THEME_DARK);
    }
    ctx_h.rvn_invalidate_all_windows();
}

export fn Raccessibility_get_high_contrast() c_int {
    if (ctx_h.rvn_api_check("Raccessibility_get_high_contrast") == 0) return raven.R_FALSE;
    return g_a11y.high_contrast;
}

export fn Raccessibility_set_focus_always_visible(enabled: c_int) void {
    if (ctx_h.rvn_api_check("Raccessibility_set_focus_always_visible") == 0) return;
    g_a11y.focus_always = @intFromBool(enabled != 0);
    ctx_h.rvn_invalidate_all_windows();
}

export fn Raccessibility_get_focus_always_visible() c_int {
    if (ctx_h.rvn_api_check("Raccessibility_get_focus_always_visible") == 0) return raven.R_FALSE;
    return g_a11y.focus_always;
}

export fn Raccessibility_set_reduce_motion(enabled: c_int) void {
    if (ctx_h.rvn_api_check("Raccessibility_set_reduce_motion") == 0) return;
    raven.Rset_animations_enabled(@intFromBool(enabled == 0));
}

export fn Raccessibility_get_reduce_motion() c_int {
    if (ctx_h.rvn_api_check("Raccessibility_get_reduce_motion") == 0) return raven.R_FALSE;
    return @intFromBool(raven.Rget_animations_enabled() == 0);
}

export fn Raccessibility_set_color_filter(filter: raven.RColorFilter) void {
    if (ctx_h.rvn_api_check("Raccessibility_set_color_filter") == 0) return;
    if (filter < raven.R_COLOR_FILTER_NONE or filter > raven.R_COLOR_FILTER_SIMULATE_ACHROMATOPSIA) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Raccessibility_set_color_filter: invalid filter");
        return;
    }
    g_a11y.filter = filter;
    ctx_h.rvn_invalidate_all_windows();
}

export fn Raccessibility_get_color_filter() raven.RColorFilter {
    if (ctx_h.rvn_api_check("Raccessibility_get_color_filter") == 0) return raven.R_COLOR_FILTER_NONE;
    return g_a11y.filter;
}

export fn Raccessibility_get_system_settings(settings: [*c]raven.RAccessibilitySettings) void {
    if (ctx_h.rvn_api_check("Raccessibility_get_system_settings") == 0) return;
    if (settings == null) return;
    settings.* = std.mem.zeroes(raven.RAccessibilitySettings);
    settings.*.text_scale = 1.0;
    const platform = currentPlatform();
    if (platform != null) {
        if (platform.*.a11y_settings) |get_settings| get_settings(settings);
    }
    if (!(settings.*.text_scale >= 0.5 and settings.*.text_scale <= 4.0)) settings.*.text_scale = 1.0;
    if (platform != null) {
        if (platform.*.a11y_active) |is_active| settings.*.screen_reader = is_active();
    }
}

export fn Raccessibility_follow_system() void {
    if (ctx_h.rvn_api_check("Raccessibility_follow_system") == 0) return;
    var settings: raven.RAccessibilitySettings = undefined;
    Raccessibility_get_system_settings(&settings);
    Raccessibility_set_text_scale(settings.text_scale);
    Raccessibility_set_high_contrast(settings.high_contrast);
    Raccessibility_set_reduce_motion(settings.reduce_motion);
    if (settings.screen_reader != 0) Raccessibility_set_focus_always_visible(raven.R_TRUE);
}

// ---------------------------------------------------------------------------
//  Public API: screen readers
// ---------------------------------------------------------------------------

fn rvn_a11y_of(widget: [*c]widget_h.rvn_widget_t) [*c]rvn_a11y_t {
    if (widget.*.a11y == null) widget.*.a11y = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_a11y_t))));
    return a11yOf(widget.*.a11y);
}

export fn Rwidget_set_accessible_name(id: raven.Rid, name: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rwidget_set_accessible_name") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_accessible_name");
    if (widget == null) return;
    _ = base.rvn_str_set(&rvn_a11y_of(widget).*.name, if (name != null and name[0] != 0) name else null);
    g_a11y.generation +%= 1;
}

export fn Rwidget_get_accessible_name(id: raven.Rid) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rwidget_get_accessible_name") == 0) return "";
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_accessible_name");
    if (widget == null) return "";
    rvn_a11y_name_of(widget, rvn_a11y_role_of(widget), &g_a11y.scratch);
    return rvn_a11y_str(&g_a11y.scratch);
}

export fn Rwidget_set_accessible_description(id: raven.Rid, description: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rwidget_set_accessible_description") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_accessible_description");
    if (widget == null) return;
    _ = base.rvn_str_set(&rvn_a11y_of(widget).*.description, if (description != null and description[0] != 0) description else null);
}

export fn Rwidget_set_accessible_role(id: raven.Rid, role: raven.RAccessibleRole) void {
    if (ctx_h.rvn_api_check("Rwidget_set_accessible_role") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_accessible_role");
    if (widget == null) return;
    if (role != raven.R_ROLE_AUTO and (role < raven.R_ROLE_NONE or role > raven.R_ROLE_PANE)) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rwidget_set_accessible_role: invalid role");
        return;
    }
    rvn_a11y_of(widget).*.role = role;
    g_a11y.generation +%= 1;
}

export fn Rwidget_get_accessible_role(id: raven.Rid) raven.RAccessibleRole {
    if (ctx_h.rvn_api_check("Rwidget_get_accessible_role") == 0) return raven.R_ROLE_NONE;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_accessible_role");
    return if (widget != null) rvn_a11y_role_of(widget) else raven.R_ROLE_NONE;
}

export fn Rwidget_set_accessible_hidden(id: raven.Rid, hidden: c_int) void {
    if (ctx_h.rvn_api_check("Rwidget_set_accessible_hidden") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_accessible_hidden");
    if (widget == null) return;
    rvn_a11y_of(widget).*.hidden = @intFromBool(hidden != 0);
    g_a11y.generation +%= 1;
}

export fn Rwidget_set_accessible_labelled_by(id: raven.Rid, label: raven.Rid) void {
    if (ctx_h.rvn_api_check("Rwidget_set_accessible_labelled_by") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_accessible_labelled_by");
    if (widget == null) return;
    rvn_a11y_of(widget).*.labelled_by = label;
}

export fn Raccessibility_announce(text: [*c]const u8, assertive: c_int) void {
    var i: u32 = 0;
    if (ctx_h.rvn_api_check("Raccessibility_announce") == 0) return;
    const platform = currentPlatform();
    if (text == null or text[0] == 0 or platform == null or platform.*.a11y_announce == null) return;
    // through the window that has the focus of the system, else the first one
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i)));
        if (window != null and window.*.platform != null and window.*.active != 0) {
            platform.*.a11y_announce.?(window.*.platform, text, assertive);
            return;
        }
    }
    i = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i)));
        if (window != null and window.*.platform != null) {
            platform.*.a11y_announce.?(window.*.platform, text, assertive);
            return;
        }
    }
}

export fn Raccessibility_is_screen_reader_active() c_int {
    if (ctx_h.rvn_api_check("Raccessibility_is_screen_reader_active") == 0) return raven.R_FALSE;
    const platform = currentPlatform();
    if (platform != null) {
        if (platform.*.a11y_active) |is_active| return is_active();
    }
    return raven.R_FALSE;
}

// XML: AccessibleName, AccessibleDescription, AccessibleRole, AccessibleHidden
export fn rvn_a11y_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int {
    const RoleName = struct { name: [*c]const u8, role: raven.RAccessibleRole };
    const roles = [_]RoleName{
        .{ .name = "Auto", .role = raven.R_ROLE_AUTO },
        .{ .name = "None", .role = raven.R_ROLE_NONE },
        .{ .name = "Group", .role = raven.R_ROLE_GROUP },
        .{ .name = "Text", .role = raven.R_ROLE_TEXT },
        .{ .name = "Heading", .role = raven.R_ROLE_HEADING },
        .{ .name = "Link", .role = raven.R_ROLE_LINK },
        .{ .name = "Button", .role = raven.R_ROLE_BUTTON },
        .{ .name = "ToggleButton", .role = raven.R_ROLE_TOGGLE_BUTTON },
        .{ .name = "CheckBox", .role = raven.R_ROLE_CHECKBOX },
        .{ .name = "RadioButton", .role = raven.R_ROLE_RADIO_BUTTON },
        .{ .name = "Slider", .role = raven.R_ROLE_SLIDER },
        .{ .name = "ProgressBar", .role = raven.R_ROLE_PROGRESS_BAR },
        .{ .name = "SpinButton", .role = raven.R_ROLE_SPIN_BUTTON },
        .{ .name = "TextField", .role = raven.R_ROLE_TEXT_FIELD },
        .{ .name = "Document", .role = raven.R_ROLE_DOCUMENT },
        .{ .name = "ComboBox", .role = raven.R_ROLE_COMBO_BOX },
        .{ .name = "List", .role = raven.R_ROLE_LIST },
        .{ .name = "ListItem", .role = raven.R_ROLE_LIST_ITEM },
        .{ .name = "Tree", .role = raven.R_ROLE_TREE },
        .{ .name = "TreeItem", .role = raven.R_ROLE_TREE_ITEM },
        .{ .name = "Table", .role = raven.R_ROLE_TABLE },
        .{ .name = "MenuBar", .role = raven.R_ROLE_MENU_BAR },
        .{ .name = "Menu", .role = raven.R_ROLE_MENU },
        .{ .name = "MenuItem", .role = raven.R_ROLE_MENU_ITEM },
        .{ .name = "TabList", .role = raven.R_ROLE_TAB_LIST },
        .{ .name = "Tab", .role = raven.R_ROLE_TAB },
        .{ .name = "TabPanel", .role = raven.R_ROLE_TAB_PANEL },
        .{ .name = "Toolbar", .role = raven.R_ROLE_TOOLBAR },
        .{ .name = "StatusBar", .role = raven.R_ROLE_STATUS_BAR },
        .{ .name = "Dialog", .role = raven.R_ROLE_DIALOG },
        .{ .name = "Alert", .role = raven.R_ROLE_ALERT },
        .{ .name = "Image", .role = raven.R_ROLE_IMAGE },
        .{ .name = "Canvas", .role = raven.R_ROLE_CANVAS },
        .{ .name = "Separator", .role = raven.R_ROLE_SEPARATOR },
        .{ .name = "ScrollBar", .role = raven.R_ROLE_SCROLL_BAR },
        .{ .name = "Pane", .role = raven.R_ROLE_PANE },
    };
    var flag: c_int = undefined;
    var i: usize = 0;
    if (base.rvn_stricmp(name, "AccessibleName") == 0) {
        Rwidget_set_accessible_name(widget.*.id, value);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "AccessibleDescription") == 0) {
        Rwidget_set_accessible_description(widget.*.id, value);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "AccessibleHidden") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        Rwidget_set_accessible_hidden(widget.*.id, flag);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "AccessibleRole") == 0) {
        while (i < roles.len) : (i += 1) {
            if (base.rvn_stricmp(value, roles[i].name) == 0) {
                Rwidget_set_accessible_role(widget.*.id, roles[i].role);
                return raven.R_TRUE;
            }
        }
        return raven.R_FALSE;
    }
    return -1;
}
