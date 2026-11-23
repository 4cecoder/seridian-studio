// Translated to Zig from vendor/raven/src/widgets/menu.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/menu.c
// MenuBar, Menu and MenuItem.
//
//   MenuBar   draws the titles of its Menu children and opens them
//   Menu      a popup listing its children: MenuItems and sub-Menus
//   MenuItem  one entry: text, shortcut, optional check mark, or a separator
//
// Menus and items are widgets so that they have handles, names, actions and
// an enabled state like everything else, but they are not laid out by the
// generic passes: a Menu measures and draws its entries itself and is shown
// through the popup layer of the window.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const rvn_menu_item_t = extern struct {
    base: widget_h.rvn_widget_t,
    text: [*c]u8,
    shortcut_text: [*c]u8,
    key: raven.RKey,
    modifiers: u32,
    separator: c_int,
    checkable: c_int,
    checked: c_int,
    callback: raven.RMenuItemClickedCallback,
    user_data: ?*anyopaque,
    /// Icon drawn before the text (Rmenu_item_set_icon).
    has_icon: c_int,
    icon: raven.Rid,
    icon_uv: [4]f32,
    icon_tint: c_int,
};

const rvn_menu_t = extern struct {
    base: widget_h.rvn_widget_t,
    title: [*c]u8,
    /// Index of the highlighted child, or -1.
    hot: c_int,
    /// Sub-menu currently open, or NULL.
    open_sub: [*c]widget_h.rvn_widget_t,
    /// Top and height of the highlight as drawn: it slides from entry to entry.
    hot_y: raven.RSpring,
    hot_h: raven.RSpring,
};

const rvn_menu_bar_t = extern struct {
    base: widget_h.rvn_widget_t,
    hot: c_int,
    /// Index of the child menu currently open, or -1.
    open: c_int,
    /// Left edge and width of the mark of the open menu: it slides from title to title.
    mark_x: raven.RSpring,
    mark_w: raven.RSpring,
};

const RVN_MENU_PADDING: f32 = 4.0;
const RVN_MENU_GUTTER: f32 = 24.0;
const RVN_MENU_ICON: f32 = 14.0;
const RVN_MENU_ICON_COLUMN: f32 = 20.0;

/// R_TRUE when an item of the menu has an icon : the texts of every item move right of the icon column.
fn rvn_menu_has_icons(widget: [*c]const widget_h.rvn_widget_t) c_int {
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]const widget_h.rvn_widget_t = widget.*.children[i];
        if (child.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM and @as([*c]const rvn_menu_item_t, @ptrCast(child)).*.has_icon != 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}
const RVN_MENU_SEPARATOR_HEIGHT: f32 = 7.0;

// ===========================================================================
//  Shortcut names
// ===========================================================================

const g_key_names = [_]struct { name: [*c]const u8, key: raven.RKey }{
    .{ .name = "Space", .key = raven.R_KEY_SPACE }, .{ .name = "Escape", .key = raven.R_KEY_ESCAPE }, .{ .name = "Esc", .key = raven.R_KEY_ESCAPE }, .{ .name = "Enter", .key = raven.R_KEY_ENTER },
    .{ .name = "Return", .key = raven.R_KEY_ENTER }, .{ .name = "Tab", .key = raven.R_KEY_TAB }, .{ .name = "Backspace", .key = raven.R_KEY_BACKSPACE }, .{ .name = "Insert", .key = raven.R_KEY_INSERT },
    .{ .name = "Delete", .key = raven.R_KEY_DELETE }, .{ .name = "Del", .key = raven.R_KEY_DELETE }, .{ .name = "Right", .key = raven.R_KEY_RIGHT }, .{ .name = "Left", .key = raven.R_KEY_LEFT },
    .{ .name = "Down", .key = raven.R_KEY_DOWN }, .{ .name = "Up", .key = raven.R_KEY_UP }, .{ .name = "PageUp", .key = raven.R_KEY_PAGE_UP }, .{ .name = "PageDown", .key = raven.R_KEY_PAGE_DOWN },
    .{ .name = "Home", .key = raven.R_KEY_HOME }, .{ .name = "End", .key = raven.R_KEY_END }, .{ .name = "F1", .key = raven.R_KEY_F1 }, .{ .name = "F2", .key = raven.R_KEY_F2 }, .{ .name = "F3", .key = raven.R_KEY_F3 },
    .{ .name = "F4", .key = raven.R_KEY_F4 }, .{ .name = "F5", .key = raven.R_KEY_F5 }, .{ .name = "F6", .key = raven.R_KEY_F6 }, .{ .name = "F7", .key = raven.R_KEY_F7 }, .{ .name = "F8", .key = raven.R_KEY_F8 },
    .{ .name = "F9", .key = raven.R_KEY_F9 }, .{ .name = "F10", .key = raven.R_KEY_F10 }, .{ .name = "F11", .key = raven.R_KEY_F11 }, .{ .name = "F12", .key = raven.R_KEY_F12 },
};

fn rvn_key_name(key: raven.RKey, buffer: [*c]u8) [*c]const u8 {
    var i: usize = 0;
    while (i < g_key_names.len) : (i += 1) {
        if (g_key_names[i].key == key) return g_key_names[i].name;
    }
    const ikey: c_int = @bitCast(key);
    if (ikey > 32 and ikey < 127) {
        buffer[0] = @truncate(key);
        buffer[1] = 0;
        return buffer;
    }
    return "";
}

fn rvn_shortcut_format(key: raven.RKey, modifiers: u32, out: [*c]u8, size: usize) void {
    var single: [2]u8 = undefined;
    const ctrl: [*c]const u8 = if ((modifiers & raven.R_MOD_CTRL) != 0) "Ctrl+" else "";
    const super: [*c]const u8 = if ((modifiers & raven.R_MOD_SUPER) != 0) "Super+" else "";
    const alt: [*c]const u8 = if ((modifiers & raven.R_MOD_ALT) != 0) "Alt+" else "";
    const shift: [*c]const u8 = if ((modifiers & raven.R_MOD_SHIFT) != 0) "Shift+" else "";
    _ = libc.snprintf(out, size, "%s%s%s%s%s", ctrl, super, alt, shift, rvn_key_name(key, &single));
}

/// Parses "Ctrl+Shift+S". Also used by the <Window> shortcuts of the XML loader.
export fn rvn_parse_shortcut(text_: [*c]const u8, key: [*c]raven.RKey, modifiers: [*c]u32) c_int {
    var text = text_;
    key.* = raven.R_KEY_UNKNOWN;
    modifiers.* = 0;
    while (text[0] != 0) {
        var token: [16]u8 = undefined;
        var length: usize = libc.strcspn(text, "+");
        var i: usize = 0;
        // "Ctrl++" : the last token is the plus key itself
        if (length == 0 and text[0] == '+') length = 1;
        if (length >= token.len) return raven.R_FALSE;
        @memcpy(token[0..length], text[0..length]);
        token[length] = 0;
        text += length;
        if (text[0] == '+') text += 1;

        if (base.rvn_stricmp(&token, "Ctrl") == 0 or base.rvn_stricmp(&token, "Control") == 0) {
            modifiers.* |= raven.R_MOD_CTRL;
        } else if (base.rvn_stricmp(&token, "Shift") == 0) {
            modifiers.* |= raven.R_MOD_SHIFT;
        } else if (base.rvn_stricmp(&token, "Alt") == 0) {
            modifiers.* |= raven.R_MOD_ALT;
        } else if (base.rvn_stricmp(&token, "Super") == 0 or base.rvn_stricmp(&token, "Cmd") == 0 or base.rvn_stricmp(&token, "Win") == 0) {
            modifiers.* |= raven.R_MOD_SUPER;
        } else {
            if (key.* != raven.R_KEY_UNKNOWN) return raven.R_FALSE;
            i = 0;
            while (i < g_key_names.len) : (i += 1) {
                if (base.rvn_stricmp(&token, g_key_names[i].name) == 0) key.* = g_key_names[i].key;
            }
            if (key.* == raven.R_KEY_UNKNOWN and length == 1) {
                var c: u8 = token[0];
                if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
                if (c > 32 and c < 127) key.* = c;
            }
            if (key.* == raven.R_KEY_UNKNOWN) return raven.R_FALSE;
        }
    }
    return @intFromBool(key.* != raven.R_KEY_UNKNOWN);
}

// ===========================================================================
//  MenuItem
// ===========================================================================

fn rvn_menu_item_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    base.rvn_free(item.*.text);
    base.rvn_free(item.*.shortcut_text);
}

fn rvn_menu_item_set_shortcut(widget: [*c]widget_h.rvn_widget_t, key: raven.RKey, modifiers: u32) void {
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    var buffer: [48]u8 = undefined;
    item.*.key = key;
    item.*.modifiers = modifiers & 0xF;
    if (key == raven.R_KEY_UNKNOWN) {
        _ = base.rvn_str_set(&item.*.shortcut_text, null);
    } else {
        rvn_shortcut_format(key, item.*.modifiers, &buffer, buffer.len);
        _ = base.rvn_str_set(&item.*.shortcut_text, &buffer);
    }
    if (widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
}

export fn rvn_menu_item_trigger(widget: [*c]widget_h.rvn_widget_t) void {
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    var root: [*c]widget_h.rvn_widget_t = widget;
    var window: [*c]widget_h.rvn_window_t = widget.*.window;

    if (item.*.separator != 0) return;
    if (item.*.checkable != 0) item.*.checked = @intFromBool(item.*.checked == 0);
    // a context menu is only attached to a window while it is open
    while (root.*.parent != null) root = root.*.parent;
    if (window == null) window = root.*.window;
    // close the menus first: the callback may open a dialog or delete the menu
    if (window != null) widget_h.rvn_window_close_popups(window);
    if (item.*.callback) |callback| callback(widget.*.id, item.*.user_data);
    if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
}

fn rvn_menu_item_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    var key: raven.RKey = undefined;
    var modifiers: u32 = undefined;
    if (base.rvn_stricmp(name, "Text") == 0) {
        _ = base.rvn_str_set(&item.*.text, value);
    } else if (base.rvn_stricmp(name, "Shortcut") == 0) {
        if (rvn_parse_shortcut(value, &key, &modifiers) == 0) return raven.R_FALSE;
        rvn_menu_item_set_shortcut(widget, key, modifiers);
    } else if (base.rvn_stricmp(name, "Checkable") == 0) {
        if (ext.rvn_parse_bool(value, &item.*.checkable) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Checked") == 0) {
        if (ext.rvn_parse_bool(value, &item.*.checked) == 0) return raven.R_FALSE;
        if (item.*.checked != 0) item.*.checkable = raven.R_TRUE;
    } else if (base.rvn_stricmp(name, "Separator") == 0) {
        if (ext.rvn_parse_bool(value, &item.*.separator) == 0) return raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    if (widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
    return raven.R_TRUE;
}

export const rvn_class_menu_item: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_MENU_ITEM,
    .name = "MenuItem",
    .size = @sizeOf(rvn_menu_item_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_NO_HIT,
    .destroy = rvn_menu_item_destroy,
    .set_attribute = rvn_menu_item_set_attribute,
});

// ===========================================================================
//  Menu
// ===========================================================================

fn rvn_menu_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    base.rvn_free(menu.*.title);
}

fn rvn_menu_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    menu.*.hot = -1;
}

fn rvn_menu_is_entry(child: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool((child.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM or child.*.cls.*.@"type" == raven.R_WIDGET_MENU) and widget_h.rvn_widget_collapsed(child) == 0);
}

fn rvn_menu_entry_is_separator(child: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(child.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM and @as([*c]const rvn_menu_item_t, @ptrCast(child)).*.separator != 0);
}

fn rvn_menu_entry_text(child: [*c]const widget_h.rvn_widget_t) [*c]const u8 {
    const text: [*c]const u8 = if (child.*.cls.*.@"type" == raven.R_WIDGET_MENU) @as([*c]const rvn_menu_t, @ptrCast(child)).*.title else @as([*c]const rvn_menu_item_t, @ptrCast(child)).*.text;
    return if (text != null) text else "";
}

fn rvn_menu_entry_height(menu: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) f32 {
    return if (rvn_menu_entry_is_separator(child) != 0) RVN_MENU_SEPARATOR_HEIGHT else widget_h.rvn_widget_metric(menu, raven.R_METRIC_ROW_HEIGHT) + 2.0;
}

/// An entry can be highlighted and triggered.
fn rvn_menu_entry_selectable(child: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(rvn_menu_is_entry(child) != 0 and rvn_menu_entry_is_separator(child) == 0 and (child.*.flags & widget_h.RVN_WF_DISABLED) == 0);
}

fn rvn_menu_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    var text_width: f32 = 0.0;
    var shortcut_width: f32 = 0.0;
    var height: f32 = RVN_MENU_PADDING * 2.0;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]widget_h.rvn_widget_t = widget.*.children[i];
        if (rvn_menu_is_entry(child) == 0) continue;
        height += rvn_menu_entry_height(widget, child);
        if (rvn_menu_entry_is_separator(child) != 0) continue;
        text_width = base.rvn_maxf(text_width, common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, rvn_menu_entry_text(child)));
        if (child.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM) {
            const item: [*c]rvn_menu_item_t = @ptrCast(child);
            shortcut_width = base.rvn_maxf(shortcut_width, common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, item.*.shortcut_text));
        }
    }
    // check gutter | icons | text | gap | shortcut | room for the sub-menu arrow
    const icon_column: f32 = if (rvn_menu_has_icons(widget) != 0) RVN_MENU_ICON_COLUMN else 0.0;
    return base.rvn_vec2(@ceil(RVN_MENU_GUTTER + icon_column + text_width + 28.0 + shortcut_width + 20.0), @ceil(height));
}

/// Rectangle of the entry `index` in menu coordinates; R_FALSE when it is not an entry.
fn rvn_menu_entry_rect(widget: [*c]const widget_h.rvn_widget_t, index: c_int, rect: [*c]base.rvn_rect_t) c_int {
    var y: f32 = RVN_MENU_PADDING;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]const widget_h.rvn_widget_t = widget.*.children[i];
        if (rvn_menu_is_entry(child) == 0) continue;
        const height = rvn_menu_entry_height(widget, child);
        if (@as(c_int, @bitCast(i)) == index) {
            rect.* = base.rvn_rect(RVN_MENU_PADDING, y, widget.*.rect.w - RVN_MENU_PADDING * 2.0, height);
            return raven.R_TRUE;
        }
        y += height;
    }
    return raven.R_FALSE;
}

fn rvn_menu_entry_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    var i: u32 = 0;
    if (x < 0.0 or x >= widget.*.rect.w) return -1;
    while (i < widget.*.child_count) : (i += 1) {
        var rect: base.rvn_rect_t = undefined;
        if (rvn_menu_entry_rect(widget, @bitCast(i), &rect) != 0 and y >= rect.y and y < rect.y + rect.h) return @bitCast(i);
    }
    return -1;
}

fn rvn_menu_close_sub(widget: [*c]widget_h.rvn_widget_t) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    if (menu.*.open_sub != null and widget.*.window != null) widget_h.rvn_window_close_popup(widget.*.window, menu.*.open_sub);
    menu.*.open_sub = null;
}

fn rvn_menu_open_sub(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    const sub: [*c]widget_h.rvn_widget_t = widget.*.children[@intCast(index)];
    const origin = widget_h.rvn_widget_origin(widget);
    var rect: base.rvn_rect_t = undefined;
    if (menu.*.open_sub == sub or widget.*.window == null) return;
    rvn_menu_close_sub(widget);
    if (rvn_menu_entry_rect(widget, index, &rect) == 0) return;
    menu.*.open_sub = sub;
    // overlap the parent menu by its padding, like native menus
    widget_h.rvn_window_open_popup(widget.*.window, sub, widget, base.rvn_rect(origin.x, origin.y + rect.y - RVN_MENU_PADDING, widget.*.rect.w - 2.0, rect.h), widget_h.RVN_POPUP_RIGHT, 0.0);
}

fn rvn_menu_set_hot(widget: [*c]widget_h.rvn_widget_t, index_: c_int, open_sub: c_int) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    var index = index_;
    if (index >= 0 and rvn_menu_entry_selectable(widget.*.children[@intCast(index)]) == 0) index = -1;
    if (menu.*.hot != index) {
        menu.*.hot = index;
        widget_h.rvn_widget_invalidate_paint(widget);
    }
    if (index >= 0 and widget.*.children[@intCast(index)].*.cls.*.@"type" == raven.R_WIDGET_MENU) {
        if (open_sub != 0) rvn_menu_open_sub(widget, index);
    } else if (index >= 0) {
        rvn_menu_close_sub(widget);
    }
}

/// Moves the highlight to the next selectable entry in a direction.
fn rvn_menu_step(widget: [*c]widget_h.rvn_widget_t, direction: c_int) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    const count: c_int = @bitCast(widget.*.child_count);
    var index: c_int = menu.*.hot;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        index = if (index < 0) (if (direction > 0) 0 else count - 1) else @rem(index + direction + count, count);
        if (rvn_menu_entry_selectable(widget.*.children[@intCast(index)]) != 0) {
            rvn_menu_set_hot(widget, index, raven.R_FALSE);
            return;
        }
    }
}

fn rvn_menu_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const radius = widget_h.rvn_widget_metric(widget, raven.R_METRIC_POPUP_RADIUS);
    const row_radius: f32 = if (widget_h.rvn_widget_glass(widget) != 0) 9.0 else 3.0;
    const font_size = common.rvn_widget_font_size(widget, 0.0);
    const text = widget_h.rvn_widget_color(widget, raven.R_COLOR_TEXT);
    const dim = widget_h.rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED);
    const icons = rvn_menu_has_icons(widget);
    var i: u32 = 0;

    if (widget_h.rvn_widget_glass(widget) != 0) {
        common.rvn_paint_surface(painter, widget, rect, radius, common.RVN_SURFACE_POPUP, 0.0, 0.0);
    } else {
        ext.rvn_paint_shadow(painter, base.rvn_rect(0.0, 4.0, rect.w, rect.h), radius, 16.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_SHADOW));
        ext.rvn_paint_box(painter, rect, radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP), 1.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_POPUP_BORDER));
    }

    // the highlight slides under the pointer from entry to entry
    {
        var row: base.rvn_rect_t = undefined;
        if (menu.*.hot >= 0 and menu.*.hot < @as(c_int, @bitCast(widget.*.child_count)) and rvn_menu_entry_rect(widget, menu.*.hot, &row) != 0 and
            (widget.*.children[@intCast(menu.*.hot)].*.flags & widget_h.RVN_WF_DISABLED) == 0 and rvn_menu_entry_is_separator(widget.*.children[@intCast(menu.*.hot)]) == 0)
        {
            row.y = ext.rvn_paint_spring(painter, &menu.*.hot_y, row.y, raven.R_MOTION_SNAPPY);
            row.h = ext.rvn_paint_spring(painter, &menu.*.hot_h, row.h, raven.R_MOTION_SNAPPY);
            ext.rvn_paint_box(painter, row, row_radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_SELECTION), 0.0, 0);
        } else {
            menu.*.hot_y.started = raven.R_FALSE;
            menu.*.hot_h.started = raven.R_FALSE;
        }
    }

    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]widget_h.rvn_widget_t = widget.*.children[i];
        var row: base.rvn_rect_t = undefined;
        const enabled = (child.*.flags & widget_h.RVN_WF_DISABLED) == 0;
        // (the entry under the pointer has the sliding highlight; an open sub-menu keeps its own)
        const index: c_int = @bitCast(i);
        const hot = index != menu.*.hot and menu.*.open_sub == child;
        const color = if (enabled) text else dim;

        if (rvn_menu_entry_rect(widget, index, &row) == 0) continue;
        if (rvn_menu_entry_is_separator(child) != 0) {
            ext.rvn_paint_rect(painter, base.rvn_rect(row.x + 4.0, row.y + @floor(row.h * 0.5), row.w - 8.0, 1.0), widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
            continue;
        }
        if (hot and enabled) {
            ext.rvn_paint_box(painter, row, row_radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_SELECTION), 0.0, 0);
        }
        if (child.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM and @as([*c]const rvn_menu_item_t, @ptrCast(child)).*.has_icon != 0) {
            const item: [*c]const rvn_menu_item_t = @ptrCast(child);
            const tint = if (item.*.icon_tint != 0) color else base.rvn_rgba(1.0, 1.0, 1.0, if (enabled) 1.0 else 0.45);
            ext.rvn_paint_image(painter, base.rvn_rect(row.x + RVN_MENU_GUTTER - RVN_MENU_PADDING, @floor(row.y + (row.h - RVN_MENU_ICON) * 0.5), RVN_MENU_ICON, RVN_MENU_ICON), item.*.icon, &item.*.icon_uv, tint, 0.0);
        }
        const text_x: f32 = row.x + RVN_MENU_GUTTER - RVN_MENU_PADDING + (if (icons != 0) RVN_MENU_ICON_COLUMN else 0.0);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size, base.rvn_rect(text_x, row.y, row.w, row.h), 0.0, rvn_menu_entry_text(child), -1, color);

        if (child.*.cls.*.@"type" == raven.R_WIDGET_MENU) {
            ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CHEVRON_RIGHT, row.x + row.w - 10.0, row.y + row.h * 0.5, 7.0, color);
        } else {
            const item: [*c]rvn_menu_item_t = @ptrCast(child);
            if (item.*.checked != 0) {
                ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CHECK, row.x + 10.0, row.y + row.h * 0.5, 8.0, color);
            }
            if (item.*.shortcut_text != null) {
                ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font_size, base.rvn_rect(row.x, row.y, row.w - 10.0, row.h), 1.0, item.*.shortcut_text, -1, base.rvn_color_mix(color, dim, 0.6));
            }
        }
    }
}

fn rvn_menu_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    var index: c_int = undefined;

    // a menu only reacts while it is shown
    if ((widget.*.flags & widget_h.RVN_WF_POPUP) == 0) return raven.R_FALSE;

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            index = rvn_menu_entry_at(widget, event.*.local_x, event.*.local_y);
            if (index >= 0) rvn_menu_set_hot(widget, index, raven.R_TRUE);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_DOWN => return raven.R_TRUE,
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_TRUE;
            index = rvn_menu_entry_at(widget, event.*.local_x, event.*.local_y);
            if (index < 0 or rvn_menu_entry_selectable(widget.*.children[@intCast(index)]) == 0) return raven.R_TRUE;
            if (widget.*.children[@intCast(index)].*.cls.*.@"type" == raven.R_WIDGET_MENU) {
                rvn_menu_set_hot(widget, index, raven.R_TRUE);
            } else {
                rvn_menu_item_trigger(widget.*.children[@intCast(index)]);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => return raven.R_TRUE,
        raven.R_EVENT_KEY_DOWN => switch (event.*.key) {
            raven.R_KEY_UP => {
                rvn_menu_step(widget, -1);
                return raven.R_TRUE;
            },
            raven.R_KEY_DOWN => {
                rvn_menu_step(widget, 1);
                return raven.R_TRUE;
            },
            raven.R_KEY_RIGHT => {
                if (menu.*.hot >= 0 and widget.*.children[@intCast(menu.*.hot)].*.cls.*.@"type" == raven.R_WIDGET_MENU) {
                    const sub: [*c]widget_h.rvn_widget_t = widget.*.children[@intCast(menu.*.hot)];
                    rvn_menu_open_sub(widget, menu.*.hot);
                    rvn_menu_step(sub, 1);
                }
                return raven.R_TRUE;
            },
            raven.R_KEY_LEFT => {
                // closes a sub-menu and returns to its parent menu
                if (widget.*.parent != null and widget.*.parent.*.cls.*.@"type" == raven.R_WIDGET_MENU and widget.*.window != null) {
                    widget_h.rvn_window_close_popup(widget.*.window, widget);
                }
                return raven.R_TRUE;
            },
            raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER, raven.R_KEY_SPACE => {
                if (menu.*.hot < 0) return raven.R_TRUE;
                if (widget.*.children[@intCast(menu.*.hot)].*.cls.*.@"type" == raven.R_WIDGET_MENU) {
                    const sub: [*c]widget_h.rvn_widget_t = widget.*.children[@intCast(menu.*.hot)];
                    rvn_menu_open_sub(widget, menu.*.hot);
                    rvn_menu_step(sub, 1);
                } else {
                    rvn_menu_item_trigger(widget.*.children[@intCast(menu.*.hot)]);
                }
                return raven.R_TRUE;
            },
            else => {
                // Escape goes to the window, which closes the top popup
                return raven.R_FALSE;
            },
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_menu_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    // entries are not widgets on screen, and sub-menus are placed by the popup layer
    _ = widget;
}

fn rvn_menu_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    // entries are drawn by the menu itself and sub-menus live in the popup layer
    _ = widget;
    _ = child;
    return raven.R_FALSE;
}

fn rvn_menu_popup_closed(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    menu.*.hot = -1;
    menu.*.open_sub = null;
    if (widget.*.parent != null and widget.*.parent.*.cls.*.@"type" == raven.R_WIDGET_MENU) {
        const parent: [*c]rvn_menu_t = @ptrCast(widget.*.parent);
        if (parent.*.open_sub == widget) parent.*.open_sub = null;
        widget_h.rvn_widget_invalidate_paint(widget.*.parent);
    } else if (widget.*.parent != null and widget.*.parent.*.cls.*.@"type" == raven.R_WIDGET_MENU_BAR) {
        rvn_menu_bar_menu_closed(widget.*.parent, widget);
    }
}

export fn rvn_menu_popup(menu: [*c]widget_h.rvn_widget_t, window: [*c]widget_h.rvn_window_t, x: f32, y: f32) void {
    if (menu.*.window != null and menu.*.window != window) widget_h.rvn_window_close_popup(menu.*.window, menu);
    widget_h.rvn_window_open_popup(window, menu, null, base.rvn_rect(x, y, 0.0, 0.0), widget_h.RVN_POPUP_AT, 0.0);
}

fn rvn_menu_add_separator(menu: [*c]widget_h.rvn_widget_t) [*c]widget_h.rvn_widget_t {
    const item = widget_h.rvn_widget_create(raven.R_WIDGET_MENU_ITEM);
    if (item == null) return null;
    const item_data: [*c]rvn_menu_item_t = @ptrCast(item);
    item_data.*.separator = raven.R_TRUE;
    widget_h.rvn_widget_add_child(menu, item, -1);
    return item;
}

fn rvn_menu_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    if (base.rvn_stricmp(name, "Text") == 0 or base.rvn_stricmp(name, "Title") == 0) {
        const menu: [*c]rvn_menu_t = @ptrCast(widget);
        _ = base.rvn_str_set(&menu.*.title, value);
        if (widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_menu_xml_child(widget: [*c]widget_h.rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    // inside a menu, <Separator/> is a menu separator, not the Separator widget
    if (base.rvn_stricmp(node.*.name, "Separator") == 0 or base.rvn_stricmp(node.*.name, "MenuSeparator") == 0) {
        return @intFromBool(rvn_menu_add_separator(widget) != null);
    }
    return raven.R_FALSE;
}

fn rvn_menu_children_changed(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    menu.*.hot = -1;
}

export const rvn_class_menu: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_MENU,
    .name = "Menu",
    .size = @sizeOf(rvn_menu_t),
    .flags = widget_h.RVN_CF_SURFACE,
    .init = rvn_menu_init,
    .destroy = rvn_menu_destroy,
    .measure = rvn_menu_measure,
    .arrange = rvn_menu_arrange,
    .paint = rvn_menu_paint,
    .event = rvn_menu_event,
    .set_attribute = rvn_menu_set_attribute,
    .child_active = rvn_menu_child_active,
    .children_changed = rvn_menu_children_changed,
    .xml_child = rvn_menu_xml_child,
    .popup_closed = rvn_menu_popup_closed,
});

/// Finds the enabled menu item bound to a shortcut anywhere below `root`.
export fn rvn_menu_find_shortcut(root: [*c]widget_h.rvn_widget_t, key: raven.RKey, modifiers: u32) [*c]widget_h.rvn_widget_t {
    var i: u32 = 0;
    if (root == null or (root.*.flags & widget_h.RVN_WF_DISABLED) != 0) return null;
    if (root.*.cls.*.@"type" == raven.R_WIDGET_MENU_ITEM) {
        const item: [*c]rvn_menu_item_t = @ptrCast(root);
        return if (item.*.key == key and item.*.key != raven.R_KEY_UNKNOWN and item.*.modifiers == modifiers) root else null;
    }
    while (i < root.*.child_count) : (i += 1) {
        const found = rvn_menu_find_shortcut(root.*.children[i], key, modifiers);
        if (found != null) return found;
    }
    return null;
}

// ===========================================================================
//  MenuBar
// ===========================================================================

fn rvn_menu_bar_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const bar: [*c]rvn_menu_bar_t = @ptrCast(widget);
    bar.*.hot = -1;
    bar.*.open = -1;
}

fn rvn_menu_bar_title_width(widget: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) f32 {
    return @ceil(common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, rvn_menu_entry_text(child))) +
        widget_h.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 2.0;
}

fn rvn_menu_bar_is_title(child: [*c]const widget_h.rvn_widget_t) c_int {
    return @intFromBool(child.*.cls.*.@"type" == raven.R_WIDGET_MENU and widget_h.rvn_widget_collapsed(child) == 0);
}

fn rvn_menu_bar_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    var width: f32 = 4.0;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (rvn_menu_bar_is_title(widget.*.children[i]) != 0) width += rvn_menu_bar_title_width(widget, widget.*.children[i]);
    }
    return base.rvn_vec2(width, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT));
}

fn rvn_menu_bar_title_rect(widget: [*c]const widget_h.rvn_widget_t, index: c_int, rect: [*c]base.rvn_rect_t) c_int {
    var x: f32 = 2.0;
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (rvn_menu_bar_is_title(widget.*.children[i]) == 0) continue;
        const width = rvn_menu_bar_title_width(widget, widget.*.children[i]);
        if (@as(c_int, @bitCast(i)) == index) {
            rect.* = base.rvn_rect(x, 2.0, width, widget.*.rect.h - 4.0);
            return raven.R_TRUE;
        }
        x += width;
    }
    return raven.R_FALSE;
}

fn rvn_menu_bar_title_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    var i: u32 = 0;
    if (y < 0.0 or y >= widget.*.rect.h) return -1;
    while (i < widget.*.child_count) : (i += 1) {
        var rect: base.rvn_rect_t = undefined;
        if (rvn_menu_bar_title_rect(widget, @bitCast(i), &rect) != 0 and x >= rect.x and x < rect.x + rect.w) return @bitCast(i);
    }
    return -1;
}

fn rvn_menu_bar_open(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const bar: [*c]rvn_menu_bar_t = @ptrCast(widget);
    const origin = widget_h.rvn_widget_origin(widget);
    var rect: base.rvn_rect_t = undefined;
    if (widget.*.window == null or rvn_menu_bar_title_rect(widget, index, &rect) == 0) return;
    if ((widget.*.children[@intCast(index)].*.flags & widget_h.RVN_WF_DISABLED) != 0) return;
    widget_h.rvn_window_close_popups(widget.*.window);
    bar.*.open = index;
    widget_h.rvn_window_open_popup(widget.*.window, widget.*.children[@intCast(index)], widget, base.rvn_rect(origin.x + rect.x, origin.y, rect.w, widget.*.rect.h), widget_h.RVN_POPUP_BELOW, 0.0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_menu_bar_menu_closed(widget: [*c]widget_h.rvn_widget_t, menu: [*c]widget_h.rvn_widget_t) void {
    const bar: [*c]rvn_menu_bar_t = @ptrCast(widget);
    if (bar.*.open >= 0 and bar.*.open < @as(c_int, @bitCast(widget.*.child_count)) and widget.*.children[@intCast(bar.*.open)] == menu) bar.*.open = -1;
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_menu_bar_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const bar: [*c]rvn_menu_bar_t = @ptrCast(widget);
    const text = widget_h.rvn_widget_text_color(widget, painter);
    const title_radius: f32 = if (widget_h.rvn_widget_glass(widget) != 0) 100.0 else 3.0;
    var i: u32 = 0;

    if (widget.*.parent != null and widget.*.parent.*.cls.*.@"type" == raven.R_WIDGET_HEADER_BAR) {
        // inside a header bar, the bar is the background
    } else if (widget_h.rvn_widget_glass(widget) != 0) {
        // a strip of glass across the window
        common.rvn_paint_surface(painter, widget, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), 0.0, common.RVN_SURFACE_BAR, 0.0, 0.0);
    } else {
        ext.rvn_paint_rect(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER));
    }
    // the mark of the open menu slides from title to title
    {
        var rect: base.rvn_rect_t = undefined;
        if (bar.*.open >= 0 and rvn_menu_bar_title_rect(widget, bar.*.open, &rect) != 0) {
            if (widget_h.rvn_widget_glass(widget) != 0) rect = base.rvn_rect(rect.x, rect.y + 3.0, rect.w, rect.h - 6.0);
            rect.x = ext.rvn_paint_spring(painter, &bar.*.mark_x, rect.x, raven.R_MOTION_BOUNCY);
            rect.w = ext.rvn_paint_spring(painter, &bar.*.mark_w, rect.w, raven.R_MOTION_BOUNCY);
            ext.rvn_paint_box(painter, rect, title_radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_SELECTION), 0.0, 0);
        } else {
            bar.*.mark_x.started = raven.R_FALSE;
            bar.*.mark_w.started = raven.R_FALSE;
        }
    }
    while (i < widget.*.child_count) : (i += 1) {
        const child: [*c]widget_h.rvn_widget_t = widget.*.children[i];
        var rect: base.rvn_rect_t = undefined;
        const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
        const enabled = dp.enabled != 0 and (child.*.flags & widget_h.RVN_WF_DISABLED) == 0;
        const index: c_int = @bitCast(i);
        if (rvn_menu_bar_title_rect(widget, index, &rect) == 0) continue;
        if (widget_h.rvn_widget_glass(widget) != 0) rect = base.rvn_rect(rect.x, rect.y + 3.0, rect.w, rect.h - 6.0);
        if (index == bar.*.open) {
            // (drawn above)
        } else if (index == bar.*.hot and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and enabled) {
            ext.rvn_paint_box(painter, rect, title_radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER_HOVERED), 0.0, 0);
        }
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, common.rvn_widget_font_size(widget, 0.0), rect, 0.5, rvn_menu_entry_text(child), -1, if (enabled) text else widget_h.rvn_widget_color(widget, raven.R_COLOR_TEXT_DISABLED));
    }
}

fn rvn_menu_bar_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const bar: [*c]rvn_menu_bar_t = @ptrCast(widget);
    var index: c_int = undefined;
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            index = rvn_menu_bar_title_at(widget, event.*.local_x, event.*.local_y);
            if (index != bar.*.hot) {
                bar.*.hot = index;
                widget_h.rvn_widget_invalidate_paint(widget);
            }
            // with a menu open, moving over another title switches to it
            if (bar.*.open >= 0 and index >= 0 and index != bar.*.open) rvn_menu_bar_open(widget, index);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            bar.*.hot = -1;
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            index = rvn_menu_bar_title_at(widget, event.*.local_x, event.*.local_y);
            if (event.*.button != raven.R_MOUSE_LEFT or index < 0) return raven.R_FALSE;
            rvn_menu_bar_open(widget, index);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

export const rvn_class_menu_bar: widget_h.rvn_widget_class_t = std.mem.zeroInit(widget_h.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_MENU_BAR,
    .name = "MenuBar",
    .size = @sizeOf(rvn_menu_bar_t),
    .flags = widget_h.RVN_CF_SURFACE,
    .init = rvn_menu_bar_init,
    .measure = rvn_menu_bar_measure,
    .arrange = rvn_menu_arrange,
    .paint = rvn_menu_bar_paint,
    .event = rvn_menu_bar_event,
    .child_active = rvn_menu_child_active,
});

// ===========================================================================
//  Public API
// ===========================================================================

export fn Rmenu_add_menu(id: raven.Rid, title: [*c]const u8) raven.Rid {
    const parent = widget_h.rvn_widget_check(id, 0, "Rmenu_add_menu");
    if (parent == null) return raven.R_INVALID_ID;
    if (parent.*.cls.*.@"type" != raven.R_WIDGET_MENU_BAR and parent.*.cls.*.@"type" != raven.R_WIDGET_MENU) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rmenu_add_menu: expected a MenuBar or a Menu, got a %s", parent.*.cls.*.name);
        return raven.R_INVALID_ID;
    }
    const menu = widget_h.rvn_widget_create(raven.R_WIDGET_MENU);
    if (menu == null) return raven.R_INVALID_ID;
    const menu_data: [*c]rvn_menu_t = @ptrCast(menu);
    menu_data.*.title = base.rvn_strdup(title);
    widget_h.rvn_widget_add_child(parent, menu, -1);
    return menu.*.id;
}

export fn Rmenu_set_title(id: raven.Rid, title: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU, "Rmenu_set_title");
    if (widget == null) return;
    const menu: [*c]rvn_menu_t = @ptrCast(widget);
    if (base.rvn_str_set(&menu.*.title, title) != 0 and widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
}

export fn Rmenu_add_item(id: raven.Rid, text: [*c]const u8) raven.Rid {
    const menu = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU, "Rmenu_add_item");
    if (menu == null) return raven.R_INVALID_ID;
    const item = widget_h.rvn_widget_create(raven.R_WIDGET_MENU_ITEM);
    if (item == null) return raven.R_INVALID_ID;
    const item_data: [*c]rvn_menu_item_t = @ptrCast(item);
    item_data.*.text = base.rvn_strdup(text);
    widget_h.rvn_widget_add_child(menu, item, -1);
    return item.*.id;
}

export fn Rmenu_add_separator(id: raven.Rid) raven.Rid {
    const menu = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU, "Rmenu_add_separator");
    if (menu == null) return raven.R_INVALID_ID;
    const item = rvn_menu_add_separator(menu);
    return if (item != null) item.*.id else raven.R_INVALID_ID;
}

export fn Rmenu_item_set_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_text");
    if (widget == null) return;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    if (base.rvn_str_set(&item.*.text, text) != 0 and widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
}

export fn Rmenu_item_get_text(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_get_text");
    if (widget == null) return "";
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    return if (item.*.text != null) item.*.text else "";
}

export fn Rmenu_item_set_shortcut(id: raven.Rid, key: raven.RKey, modifiers: raven.Ruint) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_shortcut");
    if (widget == null) return;
    rvn_menu_item_set_shortcut(widget, key, modifiers);
}

export fn Rmenu_item_set_checkable(id: raven.Rid, checkable: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_checkable");
    if (widget == null) return;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    item.*.checkable = @intFromBool(checkable != 0);
}

export fn Rmenu_item_set_icon(id: raven.Rid, texture: raven.Rid, u0_: f32, v0: f32, u1_: f32, v1: f32, tint: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_icon");
    if (widget == null) return;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    item.*.has_icon = @intFromBool(texture != raven.R_INVALID_ID);
    item.*.icon = texture;
    item.*.icon_uv[0] = u0_;
    item.*.icon_uv[1] = v0;
    item.*.icon_uv[2] = u1_;
    item.*.icon_uv[3] = v1;
    item.*.icon_tint = @intFromBool(tint != 0);
    if (widget.*.parent != null) widget_h.rvn_widget_invalidate_layout(widget.*.parent);
}

export fn Rmenu_item_set_checked(id: raven.Rid, checked: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_checked");
    if (widget == null) return;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    item.*.checked = @intFromBool(checked != 0);
    if (widget.*.parent != null) widget_h.rvn_widget_invalidate_paint(widget.*.parent);
}

export fn Rmenu_item_is_checked(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_is_checked");
    if (widget == null) return raven.R_FALSE;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    return item.*.checked;
}

export fn Rmenu_item_set_clicked_callback(id: raven.Rid, callback: raven.RMenuItemClickedCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU_ITEM, "Rmenu_item_set_clicked_callback");
    if (widget == null) return;
    const item: [*c]rvn_menu_item_t = @ptrCast(widget);
    item.*.callback = callback;
    item.*.user_data = user_data;
}

export fn Rmenu_open(id: raven.Rid, window_id: raven.Rid, x: f32, y: f32) void {
    const menu = widget_h.rvn_widget_check(id, raven.R_WIDGET_MENU, "Rmenu_open");
    if (menu == null) return;
    const window = widget_h.rvn_window_check(window_id, "Rmenu_open");
    if (window == null) return;
    widget_h.rvn_window_close_popups(window);
    rvn_menu_popup(menu, window, x, y);
}
