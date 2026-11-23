// Translated to Zig from vendor/raven/tests/test_editor_features.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - what an editor needs besides the widgets: the state of the
// keys and buttons, a hook on the events of a window, drags inside the
// application, several selected items in a tree, the tile view, panels that
// are hidden and opened again, files held in memory.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

fn window_from(xml: [*c]const u8) raven.Rid {
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    return window;
}

fn center_of(widget: raven.Rid, x: [*c]f32, y: [*c]f32) void {
    var rx: f32 = undefined;
    var ry: f32 = undefined;
    var rw: f32 = undefined;
    var rh: f32 = undefined;
    raven.Rwidget_get_rect(widget, &rx, &ry, &rw, &rh);
    x.* = rx + rw * 0.5;
    y.* = ry + rh * 0.5;
}

// ---------------------------------------------------------------------------
//  Raw input state and the event hook
// -------------------------------------------------------------------------

var g_hook_calls: c_int = 0;
var g_hook_consume: c_int = 0;
var g_hook_last: raven.REventType = 0;

fn on_hook(window: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    g_hook_calls += 1;
    g_hook_last = event.*.type;
    return g_hook_consume;
}

var g_button_clicks: c_int = 0;
fn on_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    g_button_clicks += 1;
}

fn test_input_state() void {
    const window = window_from("<Window Width=\"400\" Height=\"300\"><VBox>" ++
        "<Button Name=\"b\" Text=\"Go\"/><TextInput Name=\"t\"/>" ++
        "</VBox></Window>");
    const button = raven.Rwidget_find(window, "b");
    const text = raven.Rwidget_find(window, "t");

    t.CHECK(@src(), raven.Rwindow_is_key_down(window, raven.R_KEY_W) == 0, "!Rwindow_is_key_down(window, R_KEY_W)");
    raven.Rwindow_inject_key(window, raven.R_KEY_W, raven.R_TRUE, 0);
    t.CHECK(@src(), raven.Rwindow_is_key_down(window, raven.R_KEY_W) != 0, "Rwindow_is_key_down(window, R_KEY_W)");
    raven.Rwindow_inject_key(window, raven.R_KEY_W, raven.R_FALSE, 0);
    t.CHECK(@src(), raven.Rwindow_is_key_down(window, raven.R_KEY_W) == 0, "!Rwindow_is_key_down(window, R_KEY_W)");

    raven.Rwindow_inject_mouse_move(window, 10.0, 10.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_RIGHT, raven.R_TRUE);
    t.CHECK(@src(), raven.Rwindow_is_mouse_button_down(window, raven.R_MOUSE_RIGHT) != 0, "Rwindow_is_mouse_button_down(window, R_MOUSE_RIGHT)");
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_RIGHT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rwindow_is_mouse_button_down(window, raven.R_MOUSE_RIGHT) == 0, "!Rwindow_is_mouse_button_down(window, R_MOUSE_RIGHT)");

    // the keyboard in a text input
    t.CHECK(@src(), raven.Rwindow_wants_text_input(window) == 0, "!Rwindow_wants_text_input(window)");
    raven.Rwidget_focus(text);
    t.CHECK(@src(), raven.Rwindow_wants_text_input(window) != 0, "Rwindow_wants_text_input(window)");
    raven.Rwidget_focus(button);
    t.CHECK(@src(), raven.Rwindow_wants_text_input(window) == 0, "!Rwindow_wants_text_input(window)");

    // Tab: focus navigation, unless the application takes it
    raven.Rwidget_focus(button);
    t.test_key(window, raven.R_KEY_TAB, 0);
    t.CHECK(@src(), raven.Rwindow_get_focused_widget(window) == text, "Rwindow_get_focused_widget(window) == text");
    raven.Rwindow_set_tab_navigation(window, raven.R_FALSE);
    raven.Rwidget_focus(button);
    t.test_key(window, raven.R_KEY_TAB, 0);
    t.CHECK(@src(), raven.Rwindow_get_focused_widget(window) == button, "Rwindow_get_focused_widget(window) == button");

    // the hook sees the events first, and may keep them
    raven.Rbutton_set_clicked_callback(button, on_button, null);
    raven.Rwindow_set_event_hook(window, on_hook, null);
    g_hook_calls = 0;
    g_button_clicks = 0;
    g_hook_consume = raven.R_FALSE;
    t.test_click(window, button);
    t.CHECK(@src(), g_hook_calls >= 3, "g_hook_calls >= 3");
    t.CHECK(@src(), g_button_clicks == 1, "g_button_clicks == 1");
    g_hook_consume = raven.R_TRUE;
    t.test_click(window, button);
    t.CHECK(@src(), g_button_clicks == 1, "g_button_clicks == 1");
    t.CHECK(@src(), g_hook_last == raven.R_EVENT_MOUSE_UP, "g_hook_last == R_EVENT_MOUSE_UP");
    g_hook_consume = raven.R_FALSE;
    raven.Rwindow_set_event_hook(window, null, null);
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Drag and drop inside the application
// -------------------------------------------------------------------------

var g_drop_enter: c_int = 0;
var g_drop_leave: c_int = 0;
var g_drop_dropped: c_int = 0;
var g_drop_data: [64]u8 = std.mem.zeroes([64]u8);
var g_drop_type: [32]u8 = std.mem.zeroes([32]u8);

fn on_drop(target: raven.Rid, event: [*c]const raven.RDropEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = target;
    _ = user_data;
    if (event.*.drag_type == null) return raven.R_FALSE;
    if (event.*.phase == raven.R_DROP_ENTER) g_drop_enter += 1;
    if (event.*.phase == raven.R_DROP_LEAVE) g_drop_leave += 1;
    if (event.*.phase == raven.R_DROP_DROPPED) {
        g_drop_dropped += 1;
        _ = t.snprintf(&g_drop_data, g_drop_data.len, "%s", if (event.*.text != null) event.*.text else @as([*c]const u8, ""));
        _ = t.snprintf(&g_drop_type, g_drop_type.len, "%s", event.*.drag_type);
    }
    return @intFromBool(t.strcmp(event.*.drag_type, "asset") == 0);
}

fn test_internal_drag() void {
    const window = window_from("<Window Width=\"400\" Height=\"300\"><HBox>" ++
        "<Button Name=\"source\" Text=\"Source\" Width=\"100\"/>" ++
        "<Border Name=\"target\" Slot.Fill=\"1\"><Label>Drop here</Label></Border>" ++
        "</HBox></Window>");
    const source = raven.Rwidget_find(window, "source");
    const target = raven.Rwidget_find(window, "target");
    var sx: f32 = undefined;
    var sy: f32 = undefined;
    var tx: f32 = undefined;
    var ty: f32 = undefined;

    center_of(source, &sx, &sy);
    center_of(target, &tx, &ty);
    raven.Rwidget_set_drop_callback(target, on_drop, null);
    // g_drop_enter = g_drop_leave = g_drop_dropped = 0;
    g_drop_dropped = 0;
    g_drop_leave = g_drop_dropped;
    g_drop_enter = g_drop_leave;

    raven.Rwindow_inject_mouse_move(window, sx, sy);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    t.CHECK(@src(), raven.Rdrag_begin(source, "asset", "sprites/hero.png", "hero.png") != 0, "Rdrag_begin(source, \"asset\", \"sprites/hero.png\", \"hero.png\")");
    t.CHECK(@src(), raven.Rdrag_is_active(window) != 0, "Rdrag_is_active(window)");
    t.CHECK_STR(@src(), raven.Rdrag_get_type(window), "asset", "Rdrag_get_type(window)");
    raven.Rwindow_inject_mouse_move(window, tx, ty);
    t.CHECK(@src(), g_drop_enter == 1, "g_drop_enter == 1");
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), g_drop_dropped == 1, "g_drop_dropped == 1");
    t.CHECK_STR(@src(), &g_drop_data, "sprites/hero.png", "g_drop_data");
    t.CHECK_STR(@src(), &g_drop_type, "asset", "g_drop_type");
    t.CHECK(@src(), raven.Rdrag_is_active(window) == 0, "!Rdrag_is_active(window)");

    // a type the target refuses is not dropped
    raven.Rwindow_inject_mouse_move(window, sx, sy);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    _ = raven.Rdrag_begin(source, "actor", "Tree", "Tree");
    raven.Rwindow_inject_mouse_move(window, tx, ty);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), g_drop_dropped == 1, "g_drop_dropped == 1");

    // Escape cancels
    raven.Rwindow_inject_mouse_move(window, sx, sy);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    _ = raven.Rdrag_begin(source, "asset", "a", "a");
    raven.Rwindow_inject_mouse_move(window, tx, ty);
    g_drop_leave = 0;
    t.test_key(window, raven.R_KEY_ESCAPE, 0);
    t.CHECK(@src(), raven.Rdrag_is_active(window) == 0, "!Rdrag_is_active(window)");
    t.CHECK(@src(), g_drop_leave == 1, "g_drop_leave == 1");
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), g_drop_dropped == 1, "g_drop_dropped == 1");
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Tree view: several selected items, menus, drags
// -------------------------------------------------------------------------

var g_context_item: raven.Rid = 0;
var g_context_calls: c_int = 0;
fn on_tree_context(tree: raven.Rid, item: raven.Rid, x: f32, y: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = tree;
    _ = x;
    _ = y;
    _ = user_data;
    g_context_item = item;
    g_context_calls += 1;
}

fn click_row(window: raven.Rid, tree: raven.Rid, row: c_int, modifiers: raven.Ruint, button: raven.RMouseButton) void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    const rh: f32 = raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT);
    raven.Rwidget_get_rect(tree, &x, &y, &w, &h);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_CTRL, @intFromBool((modifiers & raven.R_MOD_CTRL) != 0), modifiers);
    raven.Rwindow_inject_mouse_move(window, x + w * 0.6, y + 1.0 + rh * (@as(f32, @floatFromInt(row)) + 0.5));
    raven.Rwindow_inject_mouse_button(window, button, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, button, raven.R_FALSE);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_CTRL, raven.R_FALSE, 0);
}

fn test_tree_multi() void {
    const window = window_from("<Window Width=\"300\" Height=\"300\"><TreeView Name=\"tree\">" ++
        "<Item Text=\"A\"/><Item Text=\"B\"/><Item Text=\"C\"/><Item Text=\"D\"/>" ++
        "</TreeView></Window>");
    const tree = raven.Rwidget_find(window, "tree");
    const a = raven.Rtree_view_get_item(tree, 0);
    const c = raven.Rtree_view_get_item(tree, 2);
    const d = raven.Rtree_view_get_item(tree, 3);

    raven.Rtree_view_set_multi_select(tree, raven.R_TRUE);
    click_row(window, tree, 0, 0, raven.R_MOUSE_LEFT);
    t.CHECK(@src(), raven.Rtree_view_get_selection_count(tree) == 1, "Rtree_view_get_selection_count(tree) == 1");
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == a, "Rtree_view_get_selected_item(tree) == a");
    // Ctrl adds
    click_row(window, tree, 2, raven.R_MOD_CTRL, raven.R_MOUSE_LEFT);
    t.CHECK(@src(), raven.Rtree_view_get_selection_count(tree) == 2, "Rtree_view_get_selection_count(tree) == 2");
    t.CHECK(@src(), raven.Rtree_item_is_selected(a) != 0, "Rtree_item_is_selected(a)");
    t.CHECK(@src(), raven.Rtree_item_is_selected(c) != 0, "Rtree_item_is_selected(c)");
    t.CHECK(@src(), raven.Rtree_view_get_selection(tree, 1) == c, "Rtree_view_get_selection(tree, 1) == c");
    // Shift: a range from the last click
    click_row(window, tree, 3, raven.R_MOD_SHIFT, raven.R_MOUSE_LEFT);
    t.CHECK(@src(), raven.Rtree_item_is_selected(c) != 0, "Rtree_item_is_selected(c)");
    t.CHECK(@src(), raven.Rtree_item_is_selected(d) != 0, "Rtree_item_is_selected(d)");
    t.CHECK(@src(), raven.Rtree_item_is_selected(a) == 0, "!Rtree_item_is_selected(a)");
    // a plain click on one of the selection keeps only it (on release)
    click_row(window, tree, 2, 0, raven.R_MOUSE_LEFT);
    t.CHECK(@src(), raven.Rtree_view_get_selection_count(tree) == 1, "Rtree_view_get_selection_count(tree) == 1");
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == c, "Rtree_view_get_selected_item(tree) == c");

    // right click: the menu of the item under the pointer, selected first
    raven.Rtree_view_set_context_callback(tree, on_tree_context, null);
    g_context_calls = 0;
    click_row(window, tree, 3, 0, raven.R_MOUSE_RIGHT);
    t.CHECK(@src(), g_context_calls == 1, "g_context_calls == 1");
    t.CHECK(@src(), g_context_item == d, "g_context_item == d");
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == d, "Rtree_view_get_selected_item(tree) == d");
    click_row(window, tree, 8, 0, raven.R_MOUSE_RIGHT);
    t.CHECK(@src(), g_context_calls == 2, "g_context_calls == 2");
    t.CHECK(@src(), g_context_item == raven.R_INVALID_ID, "g_context_item == R_INVALID_ID");

    // an item at a point, and icons that do not break anything
    t.CHECK(@src(), raven.Rtree_view_get_item_at(tree, 10.0, 1.0 + raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT) * 1.5) == raven.Rtree_view_get_item(tree, 1), "Rtree_view_get_item_at(tree, 10.0f, 1.0f + Rtheme_get_metric(R_METRIC_ROW_HEIGHT) * 1.5f) == Rtree_view_get_item(tree, 1)");
    raven.Rtree_item_set_icon(a, raven.R_INVALID_ID, 0, 0, 1, 1);
    raven.Rtree_item_set_text_color(a, 1, 0, 0, 1);
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Tile view
// -------------------------------------------------------------------------

const g_tile_names = [_][*c]const u8{ "one", "two", "three", "four", "five", "six", "seven" };
var g_tile_activated: c_int = -1;
var g_tile_selection_calls: c_int = 0;

fn tile_item(tiles: raven.Rid, index: c_int, item: [*c]raven.RTileItem, user_data: ?*anyopaque) callconv(.c) void {
    _ = tiles;
    _ = user_data;
    item.*.text = g_tile_names[@intCast(index)];
}

fn tile_activated(tiles: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = tiles;
    _ = user_data;
    g_tile_activated = index;
}

fn tile_selection(tiles: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = tiles;
    _ = index;
    _ = user_data;
    g_tile_selection_calls += 1;
}

fn test_tile_view() void {
    const window = window_from("<Window Width=\"400\" Height=\"300\"><TileView Name=\"tiles\" TileWidth=\"100\" TileHeight=\"80\" Spacing=\"10\"/></Window>");
    const tiles = raven.Rwidget_find(window, "tiles");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;

    t.CHECK(@src(), raven.Rwidget_get_type(tiles) == raven.R_WIDGET_TILE_VIEW, "Rwidget_get_type(tiles) == R_WIDGET_TILE_VIEW");
    raven.Rtile_view_set_items(tiles, 7, tile_item, null);
    raven.Rtile_view_set_activated_callback(tiles, tile_activated, null);
    raven.Rtile_view_set_selection_changed_callback(tiles, tile_selection, null);
    t.CHECK(@src(), raven.Rtile_view_get_count(tiles) == 7, "Rtile_view_get_count(tiles) == 7");
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(tiles, &x, &y, &w, &h);

    // tile 0 at (10, 10), tile 1 at (120, 10): three per row in 400 minus the scroll bar
    t.CHECK(@src(), raven.Rtile_view_get_item_at(tiles, 20.0, 20.0) == 0, "Rtile_view_get_item_at(tiles, 20.0f, 20.0f) == 0");
    t.CHECK(@src(), raven.Rtile_view_get_item_at(tiles, 130.0, 20.0) == 1, "Rtile_view_get_item_at(tiles, 130.0f, 20.0f) == 1");
    t.CHECK(@src(), raven.Rtile_view_get_item_at(tiles, 20.0, 110.0) == 3, "Rtile_view_get_item_at(tiles, 20.0f, 110.0f) == 3");
    t.CHECK(@src(), raven.Rtile_view_get_item_at(tiles, 115.0, 20.0) == -1, "Rtile_view_get_item_at(tiles, 115.0f, 20.0f) == -1");

    t.test_click_at(window, x + 130.0, y + 20.0);
    t.CHECK(@src(), raven.Rtile_view_get_current(tiles) == 1, "Rtile_view_get_current(tiles) == 1");
    t.CHECK(@src(), raven.Rtile_view_get_selection_count(tiles) == 1, "Rtile_view_get_selection_count(tiles) == 1");
    t.CHECK(@src(), g_tile_selection_calls >= 1, "g_tile_selection_calls >= 1");

    // Ctrl + click adds, Ctrl + A takes everything
    raven.Rwindow_inject_mouse_move(window, x + 20.0, y + 110.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtile_view_get_selection_count(tiles) == 1, "Rtile_view_get_selection_count(tiles) == 1");
    t.CHECK(@src(), raven.Rtile_view_get_current(tiles) == 3, "Rtile_view_get_current(tiles) == 3");
    t.test_key(window, raven.R_KEY_A, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtile_view_get_selection_count(tiles) == 7, "Rtile_view_get_selection_count(tiles) == 7");
    // (the modifiers come with each event: Ctrl is released)
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_CTRL, raven.R_FALSE, 0);

    // a double click activates
    t.test_click_at(window, x + 20.0, y + 20.0);
    t.test_click_at(window, x + 20.0, y + 20.0);
    t.CHECK(@src(), g_tile_activated == 0, "g_tile_activated == 0");

    // a rubber band from the empty space
    raven.Rtile_view_clear_selection(tiles);
    raven.Rwindow_inject_mouse_move(window, x + 5.0, y + 5.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, x + 150.0, y + 40.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtile_view_is_selected(tiles, 0) != 0, "Rtile_view_is_selected(tiles, 0)");
    t.CHECK(@src(), raven.Rtile_view_is_selected(tiles, 1) != 0, "Rtile_view_is_selected(tiles, 1)");
    t.CHECK(@src(), raven.Rtile_view_is_selected(tiles, 3) == 0, "!Rtile_view_is_selected(tiles, 3)");

    // new items: no selection
    raven.Rtile_view_set_items(tiles, 3, tile_item, null);
    t.CHECK(@src(), raven.Rtile_view_get_selection_count(tiles) == 0, "Rtile_view_get_selection_count(tiles) == 0");
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Dock area: hidden panels
// -------------------------------------------------------------------------

fn test_dock_hidden() void {
    const window = window_from("<Window Width=\"800\" Height=\"600\"><DockArea Name=\"dock\" CloseHides=\"true\">" ++
        "<Label Name=\"a\" Slot.Title=\"A\">A</Label>" ++
        "<Label Name=\"b\" Slot.Title=\"B\" Slot.Dock=\"Left\" Slot.DockSize=\"0.25\">B</Label>" ++
        "<Label Name=\"c\" Slot.Title=\"C\" Slot.Dock=\"Tab\" Slot.DockTo=\"b\">C</Label>" ++
        "</DockArea></Window>");
    const dock = raven.Rwidget_find(window, "dock");
    const a = raven.Rwidget_find(window, "a");
    const b = raven.Rwidget_find(window, "b");
    const c = raven.Rwidget_find(window, "c");

    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(1;b,c),T(0;a))", "Rdock_area_save_layout(dock)");
    raven.Rdock_area_hide_panel(dock, c);
    t.CHECK(@src(), raven.Rwidget_is_valid(c) != 0, "Rwidget_is_valid(c)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, c) == 0, "!Rdock_area_is_panel_open(dock, c)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(0;b),T(0;a))", "Rdock_area_save_layout(dock)");
    // back behind the tabs it shared, in front
    raven.Rdock_area_open_panel(dock, c);
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, c) != 0, "Rdock_area_is_panel_open(dock, c)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, c) != 0, "Rdock_area_is_panel_shown(dock, c)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(1;b,c),T(0;a))", "Rdock_area_save_layout(dock)");

    // alone in its group: its neighbour takes the room, and it comes back on the same side
    raven.Rdock_area_hide_panel(dock, b);
    raven.Rdock_area_hide_panel(dock, c);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "T(0;a)", "Rdock_area_save_layout(dock)");
    raven.Rdock_area_open_panel(dock, c);
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, c) != 0, "Rdock_area_is_panel_open(dock, c)");
    raven.Rdock_area_open_panel(dock, b);
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, b) != 0, "Rdock_area_is_panel_open(dock, b)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, a) != 0, "Rdock_area_is_panel_open(dock, a)");

    // a layout that does not name a hidden panel keeps it hidden
    raven.Rdock_area_hide_panel(dock, c);
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "H(300,T(0;b),T(0;a))") != 0, "Rdock_area_load_layout(dock, \"H(300,T(0;b),T(0;a))\")");
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, c) == 0, "!Rdock_area_is_panel_open(dock, c)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(300,T(0;b),T(0;a))", "Rdock_area_save_layout(dock)");
    // one that names it opens it
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "H(300,T(0;b,c),T(0;a))") != 0, "Rdock_area_load_layout(dock, \"H(300,T(0;b,c),T(0;a))\")");
    t.CHECK(@src(), raven.Rdock_area_is_panel_open(dock, c) != 0, "Rdock_area_is_panel_open(dock, c)");
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Files held in memory
// -------------------------------------------------------------------------

const g_panel_xml = "<VBox><Label Name=\"title\">From memory</Label></VBox>";
const g_window_xml =
    "<Window Width=\"300\" Height=\"200\"><VBox><Include Source=\"panel.xml\"/></VBox></Window>";

fn test_memory_files() void {
    var window: raven.Rid = undefined;
    var title: raven.Rid = undefined;
    var size: usize = 0;
    var text: [*c]u8 = undefined;

    // sizeof(g_panel_xml) - 1, sizeof(g_window_xml) - 1: the lengths of the texts without their terminating zero
    t.CHECK(@src(), raven.Rfile_register_memory("ui/panel.xml", g_panel_xml, g_panel_xml.len, raven.R_FALSE) != 0, "Rfile_register_memory(\"ui/panel.xml\", g_panel_xml, sizeof(g_panel_xml) - 1, R_FALSE)");
    t.CHECK(@src(), raven.Rfile_register_memory("ui/main.xml", g_window_xml, g_window_xml.len, raven.R_TRUE) != 0, "Rfile_register_memory(\"ui/main.xml\", g_window_xml, sizeof(g_window_xml) - 1, R_TRUE)");
    t.CHECK(@src(), raven.Rfile_is_memory("ui\\panel.xml") != 0, "Rfile_is_memory(\"ui\\\\panel.xml\")");
    t.CHECK(@src(), raven.Rfile_is_memory("./ui/main.xml") != 0, "Rfile_is_memory(\"./ui/main.xml\")");
    t.CHECK(@src(), raven.Rfile_is_memory("ui/other.xml") == 0, "!Rfile_is_memory(\"ui/other.xml\")");
    t.CHECK(@src(), raven.Rfile_is_memory("ui/themes/../panel.xml") != 0, "Rfile_is_memory(\"ui/themes/../panel.xml\")");
    t.CHECK(@src(), raven.Rfile_is_memory("ui/./a/b/../../panel.xml") != 0, "Rfile_is_memory(\"ui/./a/b/../../panel.xml\")");
    t.CHECK(@src(), raven.Rfile_is_memory("panel.xml") == 0, "!Rfile_is_memory(\"panel.xml\")");

    text = raven.Rfile_read("ui/panel.xml", &size);
    t.CHECK(@src(), text != null and size == g_panel_xml.len, "text && size == sizeof(g_panel_xml) - 1");
    raven.Rmemory_free(text);

    // the include is found next to the document, in memory too
    window = raven.Rwindow_create_from_xml_file("ui/main.xml");
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    title = raven.Rwidget_find(window, "title");
    t.CHECK(@src(), raven.Rwidget_is_valid(title) != 0, "Rwidget_is_valid(title)");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(title), "From memory", "Rlabel_get_text(title)");
    raven.Rwindow_destroy(window);

    raven.Rfile_unregister_memory("ui/panel.xml");
    raven.Rfile_unregister_memory("ui/main.xml");
    t.CHECK(@src(), raven.Rfile_is_memory("ui/panel.xml") == 0, "!Rfile_is_memory(\"ui/panel.xml\")");
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_editor_features: cannot initialize Raven\n");
        return 1;
    }
    t.RUN(test_input_state, "test_input_state");
    t.RUN(test_internal_drag, "test_internal_drag");
    t.RUN(test_tree_multi, "test_tree_multi");
    t.RUN(test_tile_view, "test_tile_view");
    t.RUN(test_dock_hidden, "test_dock_hidden");
    t.RUN(test_memory_files, "test_memory_files");
    raven.Rshutdown();
    return t.test_report("test_editor_features");
}
