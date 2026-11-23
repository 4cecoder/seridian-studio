// Translated to Zig from vendor/raven/tests/test_widgets.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - controls driven by synthetic input (Rwindow_inject_...), focus,
// popups, handles and deletion from inside callbacks.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

var g_window: raven.Rid = 0;
var g_clicks: c_int = 0;
var g_last_int: c_int = 0;
var g_last_float: f32 = 0;
var g_last_double: f64 = 0;
var g_last_text: [128]u8 = std.mem.zeroes([128]u8);
var g_last_id: raven.Rid = 0;
var g_actions: c_int = 0;
var g_last_action: [64]u8 = std.mem.zeroes([64]u8);

fn on_click(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    g_clicks += 1;
}

fn on_action(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    g_actions += 1;
    g_last_id = sender;
    _ = t.snprintf(&g_last_action, g_last_action.len, "%s", action);
}

fn on_check(checkbox: raven.Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = checkbox;
    _ = user_data;
    g_last_int = checked;
    g_clicks += 1;
}

fn on_slider(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = slider;
    _ = user_data;
    g_last_float = value;
}

fn on_text(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = user_data;
    _ = t.snprintf(&g_last_text, g_last_text.len, "%s", text);
    g_clicks += 1;
}

fn on_index(widget: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = user_data;
    g_last_int = index;
    g_clicks += 1;
}

fn on_spin(widget: raven.Rid, value: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = user_data;
    g_last_double = value;
}

fn on_tree(tree: raven.Rid, item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = tree;
    _ = user_data;
    g_last_id = item;
    g_clicks += 1;
}

fn on_menu_item(item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    g_last_id = item;
    g_clicks += 1;
}

// A column of widgets, each on its own row, aligned to the left.
fn column() raven.Rid {
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rpanel_set_spacing(box, 4);
    raven.Rwindow_set_content(g_window, box);
    return box;
}

fn test_button() void {
    const box = column();
    const button = raven.Rwidget_add_child(box, raven.Rbutton_create("Save"));
    const disabled = raven.Rwidget_add_child(box, raven.Rbutton_create("Disabled"));
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rslot_set_halign(button, raven.R_HALIGN_LEFT);
    raven.Rbutton_set_clicked_callback(button, on_click, null);
    raven.Rbutton_set_clicked_callback(disabled, on_click, null);
    raven.Rwidget_set_action(button, "file.save");
    raven.Rwidget_set_enabled(disabled, raven.R_FALSE);
    raven.Raction_bind("file.save", on_action, null);

    raven.Rwidget_get_rect(button, &x, &y, &w, &h);
    t.CHECK(@src(), w > 30 and w < 120, "w > 30 && w < 120");
    t.CHECK_NEAR(@src(), h, raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT), "h");

    g_actions = 0;
    g_clicks = g_actions;
    t.test_click(g_window, button);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
    t.CHECK(@src(), g_actions == 1, "g_actions == 1");
    t.CHECK_STR(@src(), &g_last_action, "file.save", "g_last_action");
    t.CHECK(@src(), g_last_id == button, "g_last_id == button");
    t.CHECK(@src(), raven.Rwidget_is_hovered(button) != 0, "Rwidget_is_hovered(button)");
    t.CHECK(@src(), raven.Rwindow_get_focused_widget(g_window) == button, "Rwindow_get_focused_widget(g_window) == button");

    // press on the button, release outside: no click
    raven.Rwindow_inject_mouse_move(g_window, x + 5, y + 5);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(g_window, 390, 290);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
    t.CHECK(@src(), raven.Rwidget_is_hovered(button) == 0, "!Rwidget_is_hovered(button)");

    // a disabled button ignores clicks
    t.test_click(g_window, disabled);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // keyboard: the focused button is clicked with Enter and Space
    raven.Rwidget_focus(button);
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.test_key(g_window, raven.R_KEY_SPACE, 0);
    t.CHECK(@src(), g_clicks == 3, "g_clicks == 3");

    // an unbound action goes to the default handler
    raven.Raction_unbind("file.save");
    raven.Raction_set_default_handler(on_action, null);
    g_actions = 0;
    t.test_click(g_window, button);
    t.CHECK(@src(), g_actions == 1, "g_actions == 1");
    raven.Raction_set_default_handler(null, null);
}

fn test_checkbox_and_radio() void {
    const box = column();
    const check = raven.Rwidget_add_child(box, raven.Rcheckbox_create("Shadows"));
    const radio_a = raven.Rwidget_add_child(box, raven.Rcheckbox_create("Low"));
    const radio_b = raven.Rwidget_add_child(box, raven.Rcheckbox_create("High"));
    raven.Rcheckbox_set_style(radio_a, raven.R_CHECKBOX_RADIO);
    raven.Rcheckbox_set_style(radio_b, raven.R_CHECKBOX_RADIO);
    raven.Rcheckbox_set_changed_callback(check, on_check, null);

    g_clicks = 0;
    t.test_click(g_window, check);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) != 0, "Rcheckbox_is_checked(check)");
    t.CHECK(@src(), g_clicks == 1 and g_last_int == 1, "g_clicks == 1 && g_last_int == 1");
    t.test_click(g_window, check);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) == 0, "!Rcheckbox_is_checked(check)");

    // setting the value from code does not call back
    raven.Rcheckbox_set_checked(check, raven.R_TRUE);
    t.CHECK(@src(), g_clicks == 2, "g_clicks == 2");

    // radio boxes of one parent are exclusive and cannot be unchecked by a click
    t.test_click(g_window, radio_a);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(radio_a) != 0 and raven.Rcheckbox_is_checked(radio_b) == 0, "Rcheckbox_is_checked(radio_a) && !Rcheckbox_is_checked(radio_b)");
    t.test_click(g_window, radio_b);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(radio_a) == 0 and raven.Rcheckbox_is_checked(radio_b) != 0, "!Rcheckbox_is_checked(radio_a) && Rcheckbox_is_checked(radio_b)");
    t.test_click(g_window, radio_b);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(radio_b) != 0, "Rcheckbox_is_checked(radio_b)");
}

fn test_slider_and_spin_box() void {
    const box = column();
    const slider = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_SLIDER));
    const spin = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_SPIN_BOX));
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rslider_set_range(slider, 0, 100);
    raven.Rslider_set_changed_callback(slider, on_slider, null);
    raven.Rwidget_get_rect(slider, &x, &y, &w, &h);

    // clicking in the middle of the track gives the middle of the range
    t.test_click(g_window, slider);
    t.CHECK_NEAR(@src(), raven.Rslider_get_value(slider), 50, "Rslider_get_value(slider)");
    t.CHECK_NEAR(@src(), g_last_float, 50, "g_last_float");

    // dragging past the end clamps to the maximum
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(g_window, x + w + 200, y);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK_NEAR(@src(), raven.Rslider_get_value(slider), 100, "Rslider_get_value(slider)");

    raven.Rslider_set_step(slider, 25);
    raven.Rslider_set_value(slider, 40);
    t.CHECK_NEAR(@src(), raven.Rslider_get_value(slider), 50, "Rslider_get_value(slider)");
    t.test_key(g_window, raven.R_KEY_LEFT, 0);
    t.CHECK_NEAR(@src(), raven.Rslider_get_value(slider), 25, "Rslider_get_value(slider)");

    // spin box: arrows step, typing replaces the value, the range clamps
    raven.Rspin_box_set_range(spin, 0, 10);
    raven.Rspin_box_set_step(spin, 0.5);
    raven.Rspin_box_set_value(spin, 3);
    raven.Rspin_box_set_changed_callback(spin, on_spin, null);
    raven.Rwidget_focus(spin);
    t.test_key(g_window, raven.R_KEY_UP, 0);
    t.CHECK_NEAR(@src(), raven.Rspin_box_get_value(spin) * 10, 35, "Rspin_box_get_value(spin) * 10");
    t.CHECK_NEAR(@src(), g_last_double * 10, 35, "g_last_double * 10");
    raven.Rwindow_inject_text(g_window, "7.25");
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.CHECK_NEAR(@src(), raven.Rspin_box_get_value(spin) * 100, 725, "Rspin_box_get_value(spin) * 100");
    raven.Rwindow_inject_text(g_window, "99");
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.CHECK_NEAR(@src(), raven.Rspin_box_get_value(spin), 10, "Rspin_box_get_value(spin)");
    // Escape cancels an edit
    raven.Rwindow_inject_text(g_window, "1");
    t.test_key(g_window, raven.R_KEY_ESCAPE, 0);
    t.CHECK_NEAR(@src(), raven.Rspin_box_get_value(spin), 10, "Rspin_box_get_value(spin)");
}

fn test_text_input() void {
    const box = column();
    const input = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_TEXT_INPUT));
    const other = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_TEXT_INPUT));
    raven.Rtext_input_set_changed_callback(input, on_text, null);
    raven.Rtext_input_set_committed_callback(input, on_text, null);

    t.test_click(g_window, input);
    t.CHECK(@src(), raven.Rwidget_is_focused(input) != 0, "Rwidget_is_focused(input)");
    raven.Rwindow_inject_text(g_window, "H\xC3\xA9llo");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "H\xC3\xA9llo", "Rtext_input_get_text(input)");
    t.CHECK_STR(@src(), &g_last_text, "H\xC3\xA9llo", "g_last_text");

    // the caret moves by characters, not bytes
    t.test_key(g_window, raven.R_KEY_HOME, 0);
    t.test_key(g_window, raven.R_KEY_RIGHT, 0);
    t.test_key(g_window, raven.R_KEY_RIGHT, 0);
    t.test_key(g_window, raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "Hllo", "Rtext_input_get_text(input)");
    t.test_key(g_window, raven.R_KEY_DELETE, 0);
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "Hlo", "Rtext_input_get_text(input)");

    // selection, clipboard
    t.test_key(g_window, raven.R_KEY_A, raven.R_MOD_CTRL);
    t.test_key(g_window, raven.R_KEY_C, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rclipboard_get_text(), "Hlo", "Rclipboard_get_text()");
    t.test_key(g_window, raven.R_KEY_END, 0);
    t.test_key(g_window, raven.R_KEY_V, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "HloHlo", "Rtext_input_get_text(input)");
    t.test_key(g_window, raven.R_KEY_LEFT, raven.R_MOD_SHIFT);
    t.test_key(g_window, raven.R_KEY_LEFT, raven.R_MOD_SHIFT);
    t.test_key(g_window, raven.R_KEY_X, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "HloH", "Rtext_input_get_text(input)");
    t.CHECK_STR(@src(), raven.Rclipboard_get_text(), "lo", "Rclipboard_get_text()");

    // Enter commits
    g_clicks = 0;
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // Tab moves the focus to the next focusable widget, Shift+Tab back
    t.test_key(g_window, raven.R_KEY_TAB, 0);
    t.CHECK(@src(), raven.Rwindow_get_focused_widget(g_window) == other, "Rwindow_get_focused_widget(g_window) == other");
    t.test_key(g_window, raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    t.CHECK(@src(), raven.Rwindow_get_focused_widget(g_window) == input, "Rwindow_get_focused_widget(g_window) == input");

    // limits and read-only
    raven.Rtext_input_set_text(input, "");
    raven.Rtext_input_set_max_length(input, 3);
    raven.Rwindow_inject_text(g_window, "abcdef");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "abc", "Rtext_input_get_text(input)");
    raven.Rtext_input_set_max_length(input, 0);
    raven.Rtext_input_set_read_only(input, raven.R_TRUE);
    raven.Rwindow_inject_text(g_window, "x");
    t.test_key(g_window, raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "abc", "Rtext_input_get_text(input)");
}

fn test_combo_box() void {
    const box = column();
    const combo = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_COMBO_BOX));
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    const row: f32 = raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT);
    raven.Rslot_set_halign(combo, raven.R_HALIGN_LEFT);
    _ = raven.Rcombo_box_add_item(combo, "Low");
    _ = raven.Rcombo_box_add_item(combo, "Medium");
    t.CHECK(@src(), raven.Rcombo_box_add_item(combo, "High") == 2, "Rcombo_box_add_item(combo, \"High\") == 2");
    raven.Rcombo_box_set_selected(combo, 0);
    raven.Rcombo_box_set_changed_callback(combo, on_index, null);
    t.CHECK(@src(), raven.Rcombo_box_get_item_count(combo) == 3, "Rcombo_box_get_item_count(combo) == 3");
    t.CHECK_STR(@src(), raven.Rcombo_box_get_item_text(combo, 1), "Medium", "Rcombo_box_get_item_text(combo, 1)");

    // a click opens the list below the box; a click on the third row selects it
    raven.Rwidget_get_rect(combo, &x, &y, &w, &h);
    g_clicks = 0;
    t.test_click(g_window, combo);
    t.test_click_at(g_window, x + 10, y + h + 2 + 1 + row * 2.5);
    t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 2, "Rcombo_box_get_selected(combo) == 2");
    t.CHECK(@src(), g_clicks == 1 and g_last_int == 2, "g_clicks == 1 && g_last_int == 2");

    // a click outside closes the list without selecting and without reaching what is below
    t.test_click(g_window, combo);
    t.test_click_at(g_window, 380, 280);
    t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 2, "Rcombo_box_get_selected(combo) == 2");
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // keyboard in the open list
    t.test_click(g_window, combo);
    t.test_key(g_window, raven.R_KEY_UP, 0);
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 1, "Rcombo_box_get_selected(combo) == 1");
    t.test_click(g_window, combo);
    t.test_key(g_window, raven.R_KEY_ESCAPE, 0);
    t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 1, "Rcombo_box_get_selected(combo) == 1");
}

fn virtual_row(list: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) [*c]const u8 {
    const S = struct {
        var buffer: [32]u8 = std.mem.zeroes([32]u8);
    };
    _ = list;
    _ = user_data;
    _ = t.snprintf(&S.buffer, S.buffer.len, "Row %d", index);
    return &S.buffer;
}

fn test_list_and_tree() void {
    const box = column();
    const list = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_LIST_VIEW));
    const tree = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_TREE_VIEW));
    // Rid root, child, leaf; (declared where they are assigned: each is assigned once)
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    const row: f32 = raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT);
    raven.Rslot_set_fill(tree, 1.0);
    raven.Rwidget_set_size(list, -1, 100);

    // a million virtual rows cost nothing
    raven.Rlist_view_set_virtual_items(list, 1000000, virtual_row, null);
    raven.Rlist_view_set_selection_changed_callback(list, on_index, null);
    t.CHECK(@src(), raven.Rlist_view_get_item_count(list) == 1000000, "Rlist_view_get_item_count(list) == 1000000");
    t.CHECK_STR(@src(), raven.Rlist_view_get_item_text(list, 123456), "Row 123456", "Rlist_view_get_item_text(list, 123456)");
    raven.Rwidget_get_rect(list, &x, &y, &w, &h);
    t.test_click_at(g_window, x + 20, y + 1 + row * 1.5);
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 1, "Rlist_view_get_selected(list) == 1");
    t.test_key(g_window, raven.R_KEY_DOWN, 0);
    t.test_key(g_window, raven.R_KEY_DOWN, 0);
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 3, "Rlist_view_get_selected(list) == 3");
    t.test_key(g_window, raven.R_KEY_END, 0);
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 999999 and g_last_int == 999999, "Rlist_view_get_selected(list) == 999999 && g_last_int == 999999");
    // the list scrolled to its end: clicking the last visible row still maps to the right index
    t.test_click_at(g_window, x + 20, y + h - 3);
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 999999, "Rlist_view_get_selected(list) == 999999");

    // stored items
    raven.Rlist_view_set_virtual_items(list, 0, null, null);
    _ = raven.Rlist_view_add_item(list, "one");
    _ = raven.Rlist_view_add_item(list, "two");
    _ = raven.Rlist_view_add_item(list, "three");
    raven.Rlist_view_set_selected(list, 2);
    raven.Rlist_view_remove_item(list, 0);
    t.CHECK(@src(), raven.Rlist_view_get_item_count(list) == 2, "Rlist_view_get_item_count(list) == 2");
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 1, "Rlist_view_get_selected(list) == 1");
    t.CHECK_STR(@src(), raven.Rlist_view_get_item_text(list, 1), "three", "Rlist_view_get_item_text(list, 1)");

    // tree
    const root = raven.Rtree_view_add_item(tree, raven.R_INVALID_ID, "World");
    const child = raven.Rtree_view_add_item(tree, root, "Player");
    const leaf = raven.Rtree_view_add_item(tree, child, "Camera");
    _ = raven.Rtree_view_add_item(tree, raven.R_INVALID_ID, "Sky");
    raven.Rtree_view_set_selection_changed_callback(tree, on_tree, null);
    t.CHECK(@src(), raven.Rtree_item_get_parent(leaf) == child, "Rtree_item_get_parent(leaf) == child");
    t.CHECK(@src(), raven.Rtree_item_get_parent(root) == raven.R_INVALID_ID, "Rtree_item_get_parent(root) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rtree_item_get_child_count(root) == 1, "Rtree_item_get_child_count(root) == 1");
    t.CHECK(@src(), raven.Rtree_item_get_child(root, 0) == child, "Rtree_item_get_child(root, 0) == child");

    // only "World" and "Sky" are shown: the second row is "Sky"
    raven.Rwidget_get_rect(tree, &x, &y, &w, &h);
    t.test_click_at(g_window, x + 60, y + 1 + row * 1.5);
    t.CHECK_STR(@src(), raven.Rtree_item_get_text(raven.Rtree_view_get_selected_item(tree)), "Sky", "Rtree_item_get_text(Rtree_view_get_selected_item(tree))");

    // keyboard: up to "World", right opens it, right again enters it
    t.test_key(g_window, raven.R_KEY_UP, 0);
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == root, "Rtree_view_get_selected_item(tree) == root");
    t.test_key(g_window, raven.R_KEY_RIGHT, 0);
    t.CHECK(@src(), raven.Rtree_item_is_expanded(root) != 0, "Rtree_item_is_expanded(root)");
    t.test_key(g_window, raven.R_KEY_RIGHT, 0);
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == child and g_last_id == child, "Rtree_view_get_selected_item(tree) == child && g_last_id == child");

    // selecting a hidden item opens the branches above it
    raven.Rtree_item_set_expanded(root, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == root, "Rtree_view_get_selected_item(tree) == root");
    raven.Rtree_view_set_selected_item(tree, leaf);
    t.CHECK(@src(), raven.Rtree_item_is_expanded(root) != 0 and raven.Rtree_item_is_expanded(child) != 0, "Rtree_item_is_expanded(root) && Rtree_item_is_expanded(child)");

    // deleting an item deletes its branch and clears the selection inside it
    raven.Rtree_item_destroy(child);
    t.CHECK(@src(), raven.Rtree_item_is_valid(leaf) == 0, "!Rtree_item_is_valid(leaf)");
    t.CHECK(@src(), raven.Rtree_view_get_selected_item(tree) == raven.R_INVALID_ID, "Rtree_view_get_selected_item(tree) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rtree_item_get_child_count(root) == 0, "Rtree_item_get_child_count(root) == 0");
}

fn test_menus() void {
    const box = column();
    const bar = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_MENU_BAR));
    const file = raven.Rmenu_add_menu(bar, "File");
    const edit = raven.Rmenu_add_menu(bar, "Edit");
    const open = raven.Rmenu_add_item(file, "Open...");
    const recent = raven.Rmenu_add_menu(file, "Recent");
    const recent_a = raven.Rmenu_add_item(recent, "scene.lynx");
    // Rid grid_item, context, context_item, target; (declared where they are assigned: each is assigned once)
    const row: f32 = raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT) + 2;
    const bar_h: f32 = raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT);
    _ = raven.Rmenu_add_separator(file);
    _ = raven.Rmenu_add_item(file, "Quit");
    const grid_item = raven.Rmenu_add_item(edit, "Show grid");
    raven.Rmenu_item_set_checkable(grid_item, raven.R_TRUE);
    raven.Rmenu_item_set_shortcut(grid_item, raven.R_KEY_G, raven.R_MOD_CTRL);
    raven.Rmenu_item_set_clicked_callback(open, on_menu_item, null);
    raven.Rmenu_item_set_clicked_callback(recent_a, on_menu_item, null);
    raven.Rmenu_item_set_clicked_callback(grid_item, on_menu_item, null);
    const target = raven.Rwidget_add_child(box, raven.Rbutton_create("Target"));
    raven.Rbutton_set_clicked_callback(target, on_click, null);

    // click the "File" title, then its first entry
    g_clicks = 0;
    t.test_click_at(g_window, 15, bar_h * 0.5);
    t.test_click_at(g_window, 30, bar_h + 4 + row * 0.5);
    t.CHECK(@src(), g_clicks == 1 and g_last_id == open, "g_clicks == 1 && g_last_id == open");

    // hovering "Recent" opens the sub-menu to the right; click its entry
    t.test_click_at(g_window, 15, bar_h * 0.5);
    raven.Rwindow_inject_mouse_move(g_window, 30, bar_h + 4 + row * 1.5);
    {
        var mx: f32 = undefined;
        var my: f32 = undefined;
        var mw: f32 = undefined;
        var mh: f32 = undefined;
        raven.Rwidget_get_rect(recent, &mx, &my, &mw, &mh);
        t.CHECK(@src(), mx > 40 and mw > 40, "mx > 40 && mw > 40");
        t.test_click_at(g_window, mx + 20, my + 4 + row * 0.5);
    }
    t.CHECK(@src(), g_clicks == 2 and g_last_id == recent_a, "g_clicks == 2 && g_last_id == recent_a");

    // with a menu open, a click elsewhere only closes it
    t.test_click_at(g_window, 15, bar_h * 0.5);
    t.test_click(g_window, target);
    t.CHECK(@src(), g_clicks == 2, "g_clicks == 2");
    t.test_click(g_window, target);
    t.CHECK(@src(), g_clicks == 3, "g_clicks == 3");

    // keyboard navigation: Down skips to the first entry, Enter triggers it
    t.test_click_at(g_window, 15, bar_h * 0.5);
    t.test_key(g_window, raven.R_KEY_DOWN, 0);
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
    t.CHECK(@src(), g_clicks == 4 and g_last_id == open, "g_clicks == 4 && g_last_id == open");

    // the shortcut of a menu item works without opening the menu, and toggles the check
    t.test_key(g_window, raven.R_KEY_G, raven.R_MOD_CTRL);
    t.CHECK(@src(), g_clicks == 5 and g_last_id == grid_item, "g_clicks == 5 && g_last_id == grid_item");
    t.CHECK(@src(), raven.Rmenu_item_is_checked(grid_item) != 0, "Rmenu_item_is_checked(grid_item)");
    raven.Rwidget_set_enabled(grid_item, raven.R_FALSE);
    t.test_key(g_window, raven.R_KEY_G, raven.R_MOD_CTRL);
    t.CHECK(@src(), g_clicks == 5, "g_clicks == 5");

    // context menu: a right click on the button opens it at the cursor
    const context = raven.Rwidget_create(raven.R_WIDGET_MENU);
    const context_item = raven.Rmenu_add_item(context, "Rename");
    raven.Rmenu_item_set_clicked_callback(context_item, on_menu_item, null);
    raven.Rwidget_set_context_menu(target, context);
    {
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        raven.Rwidget_get_rect(target, &x, &y, &w, &h);
        raven.Rwindow_inject_mouse_move(g_window, x + 10, y + 5);
        raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_RIGHT, raven.R_TRUE);
        raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_RIGHT, raven.R_FALSE);
        t.test_click_at(g_window, x + 10 + 30, y + 5 + 4 + row * 0.5);
    }
    t.CHECK(@src(), g_clicks == 6 and g_last_id == context_item, "g_clicks == 6 && g_last_id == context_item");
    raven.Rwidget_destroy(context);
}

fn test_tabs_and_expander() void {
    const box = column();
    const tabs = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_TAB_VIEW));
    const page_a = raven.Rbutton_create("A");
    const page_b = raven.Rbutton_create("B");
    const expander = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_EXPANDER));
    const content = raven.Rwidget_add_child(expander, raven.Rbutton_create("Inside"));
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var ex: f32 = undefined;
    var ey: f32 = undefined;
    var ew: f32 = undefined;
    var eh: f32 = undefined;
    t.CHECK(@src(), raven.Rtab_view_add_tab(tabs, "First", page_a) == 0, "Rtab_view_add_tab(tabs, \"First\", page_a) == 0");
    t.CHECK(@src(), raven.Rtab_view_add_tab(tabs, "Second", page_b) == 1, "Rtab_view_add_tab(tabs, \"Second\", page_b) == 1");
    raven.Rtab_view_set_changed_callback(tabs, on_index, null);
    raven.Rbutton_set_clicked_callback(page_a, on_click, null);
    raven.Rbutton_set_clicked_callback(content, on_click, null);
    raven.Rexpander_set_title(expander, "Transform");

    // the hidden page cannot be clicked
    raven.Rwidget_get_rect(page_a, &x, &y, &w, &h);
    g_clicks = 0;
    t.test_click(g_window, page_a);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
    raven.Rtab_view_set_active(tabs, 1);
    t.test_click_at(g_window, x + w * 0.5, y + h * 0.5);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // clicking the first tab title comes back to it
    raven.Rwidget_get_rect(tabs, &x, &y, &w, &h);
    t.test_click_at(g_window, x + 10, y + 8);
    t.CHECK(@src(), raven.Rtab_view_get_active(tabs) == 0 and g_last_int == 0, "Rtab_view_get_active(tabs) == 0 && g_last_int == 0");

    // collapsing the expander removes its content from the layout and from hit testing
    raven.Rwidget_get_rect(expander, &ex, &ey, &ew, &eh);
    g_clicks = 0;
    t.test_click(g_window, content);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
    t.test_click_at(g_window, ex + 30, ey + 5);
    t.CHECK(@src(), raven.Rexpander_is_expanded(expander) == 0, "!Rexpander_is_expanded(expander)");
    raven.Rwidget_get_rect(expander, &x, &y, &w, &h);
    t.CHECK(@src(), h < eh, "h < eh");
    t.test_click_at(g_window, ex + ew * 0.5, ey + eh - 5);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
}

// Deleting widgets from their own callbacks must be safe.
fn delete_self(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rwidget_destroy(button);
    g_clicks += 1;
}

fn delete_parent(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rwidget_destroy(raven.Rwidget_get_parent(button));
    g_clicks += 1;
}

fn replace_content(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    raven.Rwindow_set_content(g_window, raven.Rlabel_create("replaced"));
    g_clicks += 1;
}

fn consume_event(widget: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    _ = user_data;
    return @intFromBool(event.*.type == raven.R_EVENT_MOUSE_DOWN);
}

fn test_deletion_and_events() void {
    var box = column();
    const first = raven.Rwidget_add_child(box, raven.Rbutton_create("delete me"));
    const inner_box = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_HBOX));
    const second = raven.Rwidget_add_child(inner_box, raven.Rbutton_create("delete my parent"));
    const third = raven.Rwidget_add_child(box, raven.Rbutton_create("replace everything"));
    // Rid blocked; (declared where it is assigned: it is assigned once)
    raven.Rbutton_set_clicked_callback(first, delete_self, null);
    raven.Rbutton_set_clicked_callback(second, delete_parent, null);
    raven.Rbutton_set_clicked_callback(third, replace_content, null);

    g_clicks = 0;
    t.test_click(g_window, first);
    t.CHECK(@src(), g_clicks == 1 and raven.Rwidget_is_valid(first) == 0, "g_clicks == 1 && !Rwidget_is_valid(first)");
    t.test_click(g_window, second);
    t.CHECK(@src(), g_clicks == 2 and raven.Rwidget_is_valid(inner_box) == 0 and raven.Rwidget_is_valid(second) == 0, "g_clicks == 2 && !Rwidget_is_valid(inner_box) && !Rwidget_is_valid(second)");
    t.test_click(g_window, third);
    t.CHECK(@src(), g_clicks == 3 and raven.Rwidget_is_valid(box) == 0 and raven.Rwidget_is_valid(third) == 0, "g_clicks == 3 && !Rwidget_is_valid(box) && !Rwidget_is_valid(third)");
    t.CHECK(@src(), raven.Rwidget_get_type(raven.Rwindow_get_content(g_window)) == raven.R_WIDGET_LABEL, "Rwidget_get_type(Rwindow_get_content(g_window)) == R_WIDGET_LABEL");

    // an event callback that consumes the press prevents the click
    box = column();
    const blocked = raven.Rwidget_add_child(box, raven.Rbutton_create("blocked"));
    raven.Rbutton_set_clicked_callback(blocked, on_click, null);
    raven.Rwidget_set_event_callback(blocked, consume_event, null);
    g_clicks = 0;
    t.test_click(g_window, blocked);
    t.CHECK(@src(), g_clicks == 0, "g_clicks == 0");

    // hit testing can be switched off: the click goes through
    raven.Rwidget_set_event_callback(blocked, null, null);
    raven.Rwidget_set_hit_testable(blocked, raven.R_FALSE);
    t.test_click(g_window, blocked);
    t.CHECK(@src(), g_clicks == 0, "g_clicks == 0");
    raven.Rwidget_set_hit_testable(blocked, raven.R_TRUE);
    t.test_click(g_window, blocked);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");
}

fn on_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    const counter: [*c]c_int = @ptrCast(@alignCast(user_data));
    counter.* += 1; // (*(int*)user_data)++;
}

fn test_timers_theme_and_attributes() void {
    const box = column();
    const label = raven.Rwidget_add_child(box, raven.Rlabel_create("text"));
    // Rid timer; (declared where it is assigned: it is assigned once)
    var fired: c_int = 0;
    var i: c_int = undefined;
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    var before: f32 = undefined;
    var after: f32 = undefined;
    var w: f32 = undefined;

    const timer = raven.Rtimer_create(0.0, raven.R_FALSE, on_timer, &fired);
    t.CHECK(@src(), raven.Rtimer_is_valid(timer) != 0, "Rtimer_is_valid(timer)");
    i = 0;
    while (i < 3) : (i += 1) _ = raven.Rdraw_frame();
    t.CHECK(@src(), fired == 1, "fired == 1");
    t.CHECK(@src(), raven.Rtimer_is_valid(timer) == 0, "!Rtimer_is_valid(timer)");

    // a theme change is seen by widgets that were already measured
    raven.Rwidget_get_desired_size(label, &w, &before);
    raven.Rtheme_set_metric(raven.R_METRIC_FONT_SIZE, 26);
    raven.Rwidget_get_desired_size(label, &w, &after);
    t.CHECK(@src(), after > before * 1.5, "after > before * 1.5f");
    raven.Rtheme_set_metric(raven.R_METRIC_FONT_SIZE, 13);

    raven.Rtheme_apply(raven.R_THEME_LIGHT);
    raven.Rtheme_get_color(raven.R_COLOR_WINDOW, &r, &g, &b, &a);
    t.CHECK(@src(), r > 0.8 and a > 0.99, "r > 0.8f && a > 0.99f");
    raven.Rtheme_apply(raven.R_THEME_DARK);
    raven.Rtheme_get_color(raven.R_COLOR_WINDOW, &r, &g, &b, &a);
    t.CHECK(@src(), r < 0.3, "r < 0.3f");

    // string attributes: the names used in XML
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "Text", "changed") != 0, "Rwidget_set_attribute(label, \"Text\", \"changed\")");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(label), "changed", "Rlabel_get_text(label)");
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "Slot.HAlign", "Center") != 0, "Rwidget_set_attribute(label, \"Slot.HAlign\", \"Center\")");
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "Color.Text", "#FF8000") != 0, "Rwidget_set_attribute(label, \"Color.Text\", \"#FF8000\")");
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "Visibility", "Collapsed") != 0, "Rwidget_set_attribute(label, \"Visibility\", \"Collapsed\")");
    t.CHECK(@src(), raven.Rwidget_get_visibility(label) == raven.R_COLLAPSED, "Rwidget_get_visibility(label) == R_COLLAPSED");
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "NoSuchAttribute", "1") == 0, "!Rwidget_set_attribute(label, \"NoSuchAttribute\", \"1\")");
    t.CHECK(@src(), raven.Rwidget_set_attribute(label, "Opacity", "not a number") == 0, "!Rwidget_set_attribute(label, \"Opacity\", \"not a number\")");
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("cannot initialize Raven\n");
        return 1;
    }
    g_window = raven.Rwindow_create("widgets", 400, 300, raven.R_WINDOW_DEFAULT);

    t.RUN(test_button, "test_button");
    t.RUN(test_checkbox_and_radio, "test_checkbox_and_radio");
    t.RUN(test_slider_and_spin_box, "test_slider_and_spin_box");
    t.RUN(test_text_input, "test_text_input");
    t.RUN(test_combo_box, "test_combo_box");
    t.RUN(test_list_and_tree, "test_list_and_tree");
    t.RUN(test_menus, "test_menus");
    t.RUN(test_tabs_and_expander, "test_tabs_and_expander");
    t.RUN(test_deletion_and_events, "test_deletion_and_events");
    t.RUN(test_timers_theme_and_attributes, "test_timers_theme_and_attributes");

    // everything still paints
    _ = raven.Rdraw_frame();
    raven.Rshutdown();
    return t.test_report("test_widgets");
}
