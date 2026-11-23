// Translated to Zig from vendor/raven/tests/test_shell.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - what frames an application: custom header, drops coming from
// other applications, docked panels.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <string.h>
extern "c" fn strncat(dest: [*c]u8, src: [*c]const u8, n: usize) [*c]u8;

fn window_from(xml: [*c]const u8) raven.Rid {
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    return window;
}

// ---------------------------------------------------------------------------
//  Header bar
// -------------------------------------------------------------------------

var g_close_asked: c_int = 0;
var g_close_allowed: c_int = 0;
var g_clicked: c_int = 0;

fn on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    g_close_asked += 1;
    return g_close_allowed;
}

fn on_clicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    g_clicked += 1;
}

fn double_click_at(window: raven.Rid, x: f32, y: f32) void {
    t.test_click_at(window, x, y);
    t.test_click_at(window, x, y);
}

fn test_header_bar() void {
    const window = window_from(
        "<Window Title=\"Header\" Width=\"600\" Height=\"300\" CustomHeader=\"true\">" ++
            "<VBox>" ++
            "<HeaderBar Name=\"bar\">" ++
            "<Button Name=\"open\" Text=\"Open\"/>" ++
            "<Button Name=\"share\" Text=\"Share\" Slot.HAlign=\"Right\"/>" ++
            "</HeaderBar>" ++
            "<Label Name=\"body\" Slot.Fill=\"1\">Body</Label>" ++
            "</VBox></Window>");
    const bar = raven.Rwidget_find(window, "bar");
    const open = raven.Rwidget_find(window, "open");
    const share = raven.Rwidget_find(window, "share");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var sx: f32 = undefined;
    var sy: f32 = undefined;
    var sw: f32 = undefined;
    var sh: f32 = undefined;

    t.CHECK(@src(), raven.Rwidget_get_type(bar) == raven.R_WIDGET_HEADER_BAR, "Rwidget_get_type(bar) == R_WIDGET_HEADER_BAR");
    raven.Rwidget_get_rect(bar, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), x, 0, "x");
    t.CHECK_NEAR(@src(), y, 0, "y");
    t.CHECK_NEAR(@src(), w, 600, "w");
    t.CHECK(@src(), h >= 30.0 and h <= 60.0, "h >= 30.0f && h <= 60.0f");

    // children: from the left, and from the right before the window buttons (3 x 46)
    raven.Rwidget_get_rect(open, &sx, &sy, &sw, &sh);
    t.CHECK_NEAR(@src(), sx, 8, "sx");
    t.CHECK(@src(), sy > 0.0 and sy + sh < h, "sy > 0.0f && sy + sh < h");
    raven.Rwidget_get_rect(share, &sx, &sy, &sw, &sh);
    t.CHECK_NEAR(@src(), sx + sw, 600 - 8 - 3 * 46, "sx + sw");

    // the controls inside the bar still work
    raven.Rbutton_set_clicked_callback(open, on_clicked, null);
    g_clicked = 0;
    t.test_click(window, open);
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");

    // a double click on the bar itself maximizes the window, another one restores it
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) == 0, "!Rwindow_is_maximized(window)");
    double_click_at(window, 300.0, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) != 0, "Rwindow_is_maximized(window)");
    double_click_at(window, 300.0, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) == 0, "!Rwindow_is_maximized(window)");
    // ... but not a double click on a control of the bar
    g_clicked = 0;
    raven.Rwidget_get_rect(open, &sx, &sy, &sw, &sh);
    double_click_at(window, sx + sw * 0.5, sy + sh * 0.5);
    t.CHECK(@src(), g_clicked == 2, "g_clicked == 2");
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) == 0, "!Rwindow_is_maximized(window)");

    // window buttons, from the right: close, maximize, minimize
    t.test_click_at(window, 600.0 - 46.0 * 1.5, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) != 0, "Rwindow_is_maximized(window)");
    t.test_click_at(window, 600.0 - 46.0 * 1.5, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) == 0, "!Rwindow_is_maximized(window)");
    t.test_click_at(window, 600.0 - 46.0 * 2.5, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_minimized(window) != 0, "Rwindow_is_minimized(window)");
    raven.Rwindow_restore(window);
    t.CHECK(@src(), raven.Rwindow_is_minimized(window) == 0, "!Rwindow_is_minimized(window)");

    // a press that is released elsewhere does nothing
    raven.Rwindow_inject_mouse_move(window, 600.0 - 23.0, h * 0.5);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, 300.0, 200.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");

    // without the maximize button, the others move over
    raven.Rheader_bar_set_buttons(bar, raven.R_HEADER_CLOSE | raven.R_HEADER_MINIMIZE);
    raven.Rwidget_get_rect(share, &sx, &sy, &sw, &sh);
    t.CHECK_NEAR(@src(), sx + sw, 600 - 8 - 2 * 46, "sx + sw");
    raven.Rheader_bar_set_buttons(bar, raven.R_HEADER_ALL_BUTTONS);

    // the edges of the window are not content: the pointer there is over no widget
    raven.Rwindow_inject_mouse_move(window, 300.0, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(window) == bar, "Rwindow_get_hovered_widget(window) == bar");
    raven.Rwindow_inject_mouse_move(window, 2.0, h * 0.5);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(window) == raven.R_INVALID_ID, "Rwindow_get_hovered_widget(window) == R_INVALID_ID");
    raven.Rwindow_inject_mouse_move(window, 300.0, 2.0);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(window) == raven.R_INVALID_ID, "Rwindow_get_hovered_widget(window) == R_INVALID_ID");
    raven.Rwindow_inject_mouse_move(window, 300.0, 150.0);

    // the close button asks the close callback
    g_close_asked = 0;
    g_close_allowed = raven.R_FALSE;
    raven.Rwindow_set_close_callback(window, on_close, null);
    t.test_click_at(window, 600.0 - 23.0, h * 0.5);
    t.CHECK(@src(), g_close_asked == 1, "g_close_asked == 1");
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    g_close_allowed = raven.R_TRUE;
    t.test_click_at(window, 600.0 - 23.0, h * 0.5);
    t.CHECK(@src(), g_close_asked == 2, "g_close_asked == 2");
    t.CHECK(@src(), raven.Rwindow_is_valid(window) == 0, "!Rwindow_is_valid(window)");
}

fn test_header_variants() void {
    const window = window_from(
        "<Window Title=\"From the window\" Width=\"500\" Height=\"200\" CustomHeader=\"true\" Resizable=\"false\">" ++
            "<VBox>" ++
            "<HeaderBar Name=\"bar\" ButtonSide=\"Left\" TitleAlign=\"Left\" Buttons=\"Close, Minimize\">" ++
            "<Button Name=\"a\" Text=\"A\"/>" ++
            "</HeaderBar>" ++
            "<Border Name=\"handle\" WindowDrag=\"true\" Height=\"40\"><Button Name=\"inside\" Text=\"Inside\" Slot.HAlign=\"Left\"/></Border>" ++
            "<Label Name=\"plain\" Slot.Fill=\"1\">Body</Label>" ++
            "</VBox></Window>");
    const bar = raven.Rwidget_find(window, "bar");
    const a = raven.Rwidget_find(window, "a");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var bx: f32 = undefined;
    var by: f32 = undefined;
    var bw: f32 = undefined;
    var bh: f32 = undefined;

    // lights on the left: the children start after them
    raven.Rwidget_get_rect(a, &x, &y, &w, &h);
    t.CHECK(@src(), x > 14.0 + 2 * 13.0, "x > 14.0f + 2 * 13.0f");
    raven.Rwidget_get_rect(bar, &bx, &by, &bw, &bh);

    // the first light closes; a window that cannot be resized is not maximized by a double click
    double_click_at(window, 300.0, bh * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_maximized(window) == 0, "!Rwindow_is_maximized(window)");

    // any widget can be a handle for the window, and the controls inside it still get their clicks
    g_clicked = 0;
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(window, "inside"), on_clicked, null);
    t.test_click(window, raven.Rwidget_find(window, "inside"));
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");

    // API
    raven.Rheader_bar_set_title(bar, "Mine");
    raven.Rheader_bar_set_button_side(bar, raven.R_HALIGN_RIGHT);
    raven.Rheader_bar_set_title_align(bar, raven.R_HALIGN_CENTER);
    raven.Rheader_bar_set_background(bar, raven.R_FALSE);
    _ = raven.Rdraw_frame();
    t.EXPECT_ERRORS_BEGIN();
    raven.Rheader_bar_set_button_side(bar, raven.R_HALIGN_CENTER);
    raven.Rheader_bar_set_title(a, "not a bar");
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");

    raven.Rwindow_inject_mouse_move(window, 14.0 + 6.0, by + bh * 0.5);
    raven.Rheader_bar_set_button_side(bar, raven.R_HALIGN_LEFT);
    t.test_click_at(window, 14.0 + 6.0, by + bh * 0.5);
    t.CHECK(@src(), raven.Rwindow_is_valid(window) == 0, "!Rwindow_is_valid(window)");
}

// ---------------------------------------------------------------------------
//  Drag and drop
// -------------------------------------------------------------------------

var g_log: [512]u8 = std.mem.zeroes([512]u8);
var g_accept: c_int = 0;
var g_dropped: [256]u8 = std.mem.zeroes([256]u8);

fn on_drop(target: raven.Rid, event: [*c]const raven.RDropEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const who: [*c]const u8 = @ptrCast(user_data);
    var entry: [96]u8 = undefined;
    const phases = [_][*c]const u8{ "enter", "move", "leave", "drop" }; // static const char* const phases[]
    _ = target;
    _ = t.snprintf(&entry, entry.len, "%s:%s ", who, phases[event.*.phase - raven.R_DROP_ENTER]);
    _ = strncat(&g_log, &entry, g_log.len - t.strlen(&g_log) - 1);
    if (event.*.phase == raven.R_DROP_DROPPED) {
        g_dropped[0] = 0;
        {
            var i: c_int = 0;
            while (i < event.*.path_count) : (i += 1) {
                _ = strncat(&g_dropped, event.*.paths[@intCast(i)], g_dropped.len - t.strlen(&g_dropped) - 1);
                _ = strncat(&g_dropped, ";", g_dropped.len - t.strlen(&g_dropped) - 1);
            }
        }
        if (event.*.text != null) _ = strncat(&g_dropped, event.*.text, g_dropped.len - t.strlen(&g_dropped) - 1);
    }
    return g_accept;
}

fn test_drop() void {
    const window = window_from(
        "<Window Width=\"400\" Height=\"200\">" ++
            "<HBox>" ++
            "<Border Name=\"left\" Width=\"200\"><Label Name=\"deep\">Deep</Label></Border>" ++
            "<Border Name=\"right\" Width=\"200\"/>" ++
            "</HBox></Window>");
    const left = raven.Rwidget_find(window, "left");
    const files = [_][*c]const u8{ "/tmp/a.txt", "/tmp/b c.xml" };

    g_accept = raven.R_TRUE;
    g_log[0] = 0;

    // nothing takes drops yet
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) == 0, "!Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drop(window, 50.0, 50.0, &files, 2, null) == 0, "!Rwindow_inject_drop(window, 50.0f, 50.0f, files, 2, NULL)");
    t.CHECK_STR(@src(), &g_log, "", "g_log");

    // a widget: found from the deepest widget under the pointer
    raven.Rwidget_set_drop_callback(left, on_drop, @ptrCast(@constCast("left")));
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 60.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 60.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 300.0, 50.0, raven.R_TRUE) == 0, "!Rwindow_inject_drag(window, 300.0f, 50.0f, R_TRUE)");
    t.CHECK_STR(@src(), &g_log, "left:enter left:move left:leave ", "g_log");

    // the window takes what no widget takes
    g_log[0] = 0;
    raven.Rwindow_set_drop_callback(window, on_drop, @ptrCast(@constCast("window")));
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 300.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 300.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 0.0, 0.0, raven.R_FALSE) == 0, "!Rwindow_inject_drag(window, 0.0f, 0.0f, R_FALSE)");
    t.CHECK_STR(@src(), &g_log, "window:enter window:leave left:enter left:leave ", "g_log");

    // the drop itself
    g_log[0] = 0;
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drop(window, 50.0, 50.0, &files, 2, null) != 0, "Rwindow_inject_drop(window, 50.0f, 50.0f, files, 2, NULL)");
    t.CHECK_STR(@src(), &g_log, "left:enter left:move left:drop ", "g_log");
    t.CHECK_STR(@src(), &g_dropped, "/tmp/a.txt;/tmp/b c.xml;", "g_dropped");

    // a drop that nothing announced (some window systems only report the drop)
    g_log[0] = 0;
    t.CHECK(@src(), raven.Rwindow_inject_drop(window, 300.0, 50.0, null, 0, "some text") != 0, "Rwindow_inject_drop(window, 300.0f, 50.0f, NULL, 0, \"some text\")");
    t.CHECK_STR(@src(), &g_log, "window:enter window:drop ", "g_log");
    t.CHECK_STR(@src(), &g_dropped, "some text", "g_dropped");

    // a target that refuses does not get the drop
    g_log[0] = 0;
    g_accept = raven.R_FALSE;
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) == 0, "!Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK(@src(), raven.Rwindow_inject_drop(window, 50.0, 50.0, &files, 1, null) == 0, "!Rwindow_inject_drop(window, 50.0f, 50.0f, files, 1, NULL)");
    t.CHECK_STR(@src(), &g_log, "left:enter left:move ", "g_log");
    g_accept = raven.R_TRUE;

    // a target deleted in the middle of a drag is forgotten
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    raven.Rwidget_destroy(left);
    g_log[0] = 0;
    t.CHECK(@src(), raven.Rwindow_inject_drag(window, 50.0, 50.0, raven.R_TRUE) != 0, "Rwindow_inject_drag(window, 50.0f, 50.0f, R_TRUE)");
    t.CHECK_STR(@src(), &g_log, "window:enter ", "g_log");
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(window);
}

fn test_hit_test() void {
    const window = window_from(
        "<Window Width=\"400\" Height=\"200\">" ++
            "<HBox Name=\"row\">" ++
            "<Border Name=\"left\" Width=\"200\"><Button Name=\"button\" Text=\"B\" Slot.HAlign=\"Left\" Slot.VAlign=\"Top\" Width=\"50\" Height=\"30\"/></Border>" ++
            "<Border Name=\"right\" Width=\"200\"/>" ++
            "</HBox></Window>");
    const row = raven.Rwidget_find(window, "row");
    const left = raven.Rwidget_find(window, "left");
    const right = raven.Rwidget_find(window, "right");
    const button = raven.Rwidget_find(window, "button");

    t.CHECK(@src(), raven.Rwidget_hit_test(row, 10.0, 10.0) == button, "Rwidget_hit_test(row, 10.0f, 10.0f) == button");
    t.CHECK(@src(), raven.Rwidget_hit_test(row, 100.0, 100.0) == left, "Rwidget_hit_test(row, 100.0f, 100.0f) == left");
    t.CHECK(@src(), raven.Rwidget_hit_test(row, 300.0, 100.0) == right, "Rwidget_hit_test(row, 300.0f, 100.0f) == right");
    // the search stays in the subtree it was given
    t.CHECK(@src(), raven.Rwidget_hit_test(right, 100.0, 100.0) == raven.R_INVALID_ID, "Rwidget_hit_test(right, 100.0f, 100.0f) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_hit_test(right, 300.0, 100.0) == right, "Rwidget_hit_test(right, 300.0f, 100.0f) == right");
    t.CHECK(@src(), raven.Rwidget_hit_test(row, 500.0, 100.0) == raven.R_INVALID_ID, "Rwidget_hit_test(row, 500.0f, 100.0f) == R_INVALID_ID");
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Dock area
// -------------------------------------------------------------------------

var g_dock_changes: c_int = 0;
var g_dock_close_asked: c_int = 0;
var g_dock_close_allowed: c_int = 0;

fn on_dock_changed(area: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = area;
    _ = user_data;
    g_dock_changes += 1;
}

fn on_dock_close(area: raven.Rid, panel: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = area;
    _ = user_data;
    t.CHECK(@src(), raven.Rwidget_is_valid(panel) != 0, "Rwidget_is_valid(panel)");
    g_dock_close_asked += 1;
    return g_dock_close_allowed;
}

// Width of the tab of a panel that can be closed, in the default themes.
fn tab_width(title: [*c]const u8) f32 {
    const label = raven.Rlabel_create(title);
    var width: f32 = 0.0;
    var height: f32 = 0.0;
    raven.Rwidget_get_desired_size(label, &width, &height);
    raven.Rwidget_destroy(label);
    return width + raven.Rtheme_get_metric(raven.R_METRIC_PADDING_X) * 2.0 + 22.0;
}

fn drag(window: raven.Rid, from_x: f32, from_y: f32, to_x: f32, to_y: f32) void {
    raven.Rwindow_inject_mouse_move(window, from_x, from_y);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, from_x + 12.0, from_y + 12.0);
    raven.Rwindow_inject_mouse_move(window, to_x, to_y);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
}

const DOCK_XML: [*c]const u8 =
    "<Window Width=\"800\" Height=\"600\">" ++
    "<DockArea Name=\"dock\">" ++
    "<Label Name=\"a\" Slot.Title=\"A\"/>" ++
    "<Label Name=\"b\" Slot.Title=\"B\" Slot.Dock=\"Left\" Slot.DockSize=\"0.25\"/>" ++
    "<Label Name=\"c\" Slot.Title=\"C\" Slot.Dock=\"Bottom\" Slot.DockTo=\"a\" Slot.DockSize=\"0.5\"/>" ++
    "<Label Name=\"d\" Slot.Title=\"D\" Slot.Dock=\"Tab\" Slot.DockTo=\"c\" Slot.Closable=\"false\"/>" ++
    "</DockArea></Window>";

fn test_dock() void {
    const window = window_from(DOCK_XML);
    const dock = raven.Rwidget_find(window, "dock");
    const a = raven.Rwidget_find(window, "a");
    const b = raven.Rwidget_find(window, "b");
    const c = raven.Rwidget_find(window, "c");
    const d = raven.Rwidget_find(window, "d");
    var e: raven.Rid = undefined;
    const gap: f32 = if (raven.Rtheme_get_metric(raven.R_METRIC_SPLITTER_SIZE) < 4.0) 4.0 else raven.Rtheme_get_metric(raven.R_METRIC_SPLITTER_SIZE);
    const bar: f32 = raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT) + 2.0;
    const left: f32 = @floor((800.0 - gap) * 0.25);
    const top: f32 = @floor((600.0 - gap) * 0.5);
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var saved: [256]u8 = undefined;

    t.CHECK(@src(), raven.Rwidget_get_type(dock) == raven.R_WIDGET_DOCK_AREA, "Rwidget_get_type(dock) == R_WIDGET_DOCK_AREA");
    // B on the left over the whole height; A above C and D, which share their tabs
    t.CHECK_RECT(@src(), b, 1, bar, left - 2, 600 - bar - 1, "b");
    t.CHECK_RECT(@src(), a, left + gap + 1, bar, 800 - left - gap - 2, top - bar - 1, "a");
    t.CHECK_RECT(@src(), d, left + gap + 1, top + gap + bar, 800 - left - gap - 2, 600 - top - gap - bar - 1, "d");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, a) != 0, "Rdock_area_is_panel_shown(dock, a)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, d) != 0, "Rdock_area_is_panel_shown(dock, d)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, c) == 0, "!Rdock_area_is_panel_shown(dock, c)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(0;b),V(500,T(0;a),T(1;c,d)))", "Rdock_area_save_layout(dock)");

    // a click on a tab shows its panel
    raven.Rdock_area_set_changed_callback(dock, on_dock_changed, null);
    g_dock_changes = 0;
    t.test_click_at(window, left + gap + 10.0, top + gap + bar * 0.5);
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, c) != 0, "Rdock_area_is_panel_shown(dock, c)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, d) == 0, "!Rdock_area_is_panel_shown(dock, d)");
    t.CHECK(@src(), g_dock_changes == 1, "g_dock_changes == 1");
    raven.Rdock_area_show_panel(dock, d);
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, d) != 0, "Rdock_area_is_panel_shown(dock, d)");
    raven.Rdock_area_show_panel(dock, c);

    // the close button of a tab asks the callback first
    raven.Rdock_area_set_close_callback(dock, on_dock_close, null);
    g_dock_close_asked = 0;
    g_dock_close_allowed = raven.R_FALSE;
    t.test_click_at(window, left + gap + tab_width("C") - 12.0, top + gap + bar * 0.5);
    t.CHECK(@src(), g_dock_close_asked == 1, "g_dock_close_asked == 1");
    t.CHECK(@src(), raven.Rwidget_is_valid(c) != 0, "Rwidget_is_valid(c)");
    g_dock_close_allowed = raven.R_TRUE;
    t.test_click_at(window, left + gap + tab_width("C") - 12.0, top + gap + bar * 0.5);
    t.CHECK(@src(), g_dock_close_asked == 2, "g_dock_close_asked == 2");
    t.CHECK(@src(), raven.Rwidget_is_valid(c) == 0, "!Rwidget_is_valid(c)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(0;b),V(500,T(0;a),T(0;d)))", "Rdock_area_save_layout(dock)");
    // D cannot be closed by the user: its tab has no button there
    t.test_click_at(window, left + gap + tab_width("D") - 12.0 - 18.0, top + gap + bar * 0.5);
    t.CHECK(@src(), raven.Rwidget_is_valid(d) != 0, "Rwidget_is_valid(d)");
    t.CHECK(@src(), g_dock_close_asked == 2, "g_dock_close_asked == 2");

    // dragging the tab of A onto the middle of B puts A behind the tabs of B; the place of A goes to D
    drag(window, left + gap + 10.0, bar * 0.5, left * 0.5, 300.0);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(1;b,a),T(0;d))", "Rdock_area_save_layout(dock)");
    t.CHECK_RECT(@src(), a, 1, bar, left - 2, 600 - bar - 1, "a");
    t.CHECK_RECT(@src(), d, left + gap + 1, bar, 800 - left - gap - 2, 600 - bar - 1, "d");
    // onto the bottom of D: a new group under it
    drag(window, tab_width("B") + 10.0, bar * 0.5, 600.0, 560.0);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(0;b),V(500,T(0;d),T(0;a)))", "Rdock_area_save_layout(dock)");
    // onto the left edge of the area: against everything
    drag(window, left + gap + 10.0, top + gap + bar * 0.5, 5.0, 300.0);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,T(0;a),H(250,T(0;b),T(0;d)))", "Rdock_area_save_layout(dock)");
    // dropped outside an area that is not tearable, or where it already is: nothing moves
    //   (a tearable area gives the panel a window of its own: test_dock_tearing)
    _ = t.snprintf(&saved, saved.len, "%s", raven.Rdock_area_save_layout(dock));
    raven.Rdock_area_set_tearable(dock, raven.R_FALSE);
    drag(window, 10.0, bar * 0.5, 100.0, 300.0);
    drag(window, 10.0, bar * 0.5, 900.0, 700.0);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), &saved, "Rdock_area_save_layout(dock)");
    raven.Rdock_area_set_tearable(dock, raven.R_TRUE);

    // the border between two groups is dragged to share the room differently
    raven.Rwidget_get_rect(a, &x, &y, &w, &h);
    raven.Rwindow_inject_mouse_move(window, x + w + 1.0 + gap * 0.5, 300.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, x + w + 1.0 + gap * 0.5 + 100.0, 300.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    {
        var after: f32 = undefined;
        raven.Rwidget_get_rect(a, &x, &y, &after, &h);
        t.CHECK_NEAR(@src(), after, w + 100.0, "after");
    }
    // a border never squeezes a panel to nothing
    raven.Rwindow_inject_mouse_move(window, x + w + 100.0 + 1.0 + gap * 0.5, 300.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, -200.0, 300.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    raven.Rwidget_get_rect(a, &x, &y, &w, &h);
    t.CHECK(@src(), w >= 60.0, "w >= 60.0f");

    // a locked area keeps its panels where they are
    _ = t.snprintf(&saved, saved.len, "%s", raven.Rdock_area_save_layout(dock));
    raven.Rdock_area_set_movable(dock, raven.R_FALSE);
    drag(window, 10.0, bar * 0.5, 600.0, 560.0);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), &saved, "Rdock_area_save_layout(dock)");
    raven.Rdock_area_set_movable(dock, raven.R_TRUE);

    // API
    e = raven.Rlabel_create("E");
    raven.Rwidget_set_name(e, "e e");
    raven.Rdock_area_add_panel(dock, e, "Echo", raven.R_DOCK_RIGHT, raven.R_INVALID_ID, 0.2);
    t.CHECK(@src(), raven.Rwidget_get_parent(e) == dock, "Rwidget_get_parent(e) == dock");
    raven.Rwidget_get_rect(e, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), x + w, 799, "x + w");
    t.CHECK_NEAR(@src(), h, 600 - bar - 1, "h");
    raven.Rdock_area_move_panel(dock, e, raven.R_DOCK_TAB, b, 0.0);
    raven.Rdock_area_set_panel_title(dock, e, "Echo 2");
    raven.Rdock_area_set_panel_closable(dock, e, raven.R_FALSE);
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, e) != 0, "Rdock_area_is_panel_shown(dock, e)");
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, b) == 0, "!Rdock_area_is_panel_shown(dock, b)");
    // names are written so that any name can be read back
    t.CHECK(@src(), t.strstr(raven.Rdock_area_save_layout(dock), "T(1;b,e%20e)") != null, "strstr(Rdock_area_save_layout(dock), \"T(1;b,e%20e)\") != NULL");
    raven.Rdock_area_move_panel(dock, e, raven.R_DOCK_TOP, a, 0.3);
    t.CHECK(@src(), raven.Rdock_area_is_panel_shown(dock, b) != 0, "Rdock_area_is_panel_shown(dock, b)");

    // a saved layout comes back, whatever happened in between
    _ = t.snprintf(&saved, saved.len, "%s", raven.Rdock_area_save_layout(dock));
    raven.Rdock_area_move_panel(dock, a, raven.R_DOCK_TAB, d, 0.0);
    raven.Rdock_area_move_panel(dock, b, raven.R_DOCK_BOTTOM, raven.R_INVALID_ID, 0.4);
    t.CHECK(@src(), t.strcmp(raven.Rdock_area_save_layout(dock), &saved) != 0, "strcmp(Rdock_area_save_layout(dock), saved) != 0");
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, &saved) != 0, "Rdock_area_load_layout(dock, saved)");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), &saved, "Rdock_area_save_layout(dock)");
    // text that is not a layout changes nothing
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "X(1,2)") == 0, "!Rdock_area_load_layout(dock, \"X(1,2)\")");
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "H(500,T(0;a),") == 0, "!Rdock_area_load_layout(dock, \"H(500,T(0;a),\")");
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "T(0;a))") == 0, "!Rdock_area_load_layout(dock, \"T(0;a))\")");
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "") == 0, "!Rdock_area_load_layout(dock, \"\")");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), &saved, "Rdock_area_save_layout(dock)");
    // unknown names are ignored, panels that are not named keep a place
    t.CHECK(@src(), raven.Rdock_area_load_layout(dock, "V(300,T(0;ghost),H(500,T(0;d,ghost2),T(5;a)))") != 0, "Rdock_area_load_layout(dock, \"V(300,T(0;ghost),H(500,T(0;d,ghost2),T(5;a)))\")");
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(500,T(2;d,b,e%20e),T(0;a))", "Rdock_area_save_layout(dock)");

    t.EXPECT_ERRORS_BEGIN();
    raven.Rdock_area_add_panel(dock, raven.Rlabel_create("x"), "X", @as(raven.RDockSide, 3), raven.R_INVALID_ID, 0.0);
    raven.Rdock_area_add_panel(dock, raven.Rlabel_create("y"), "Y", raven.R_DOCK_LEFT, dock, 0.0);
    raven.Rdock_area_close_panel(dock, dock);
    raven.Rdock_area_add_panel(dock, window, "W", raven.R_DOCK_LEFT, raven.R_INVALID_ID, 0.0);
    t.EXPECT_ERRORS_END(@src(), 4, "g_test_errors >= (4)");

    // panels deleted by the application leave the tree; an empty area is still an area
    raven.Rdock_area_close_panel(dock, e);
    t.CHECK(@src(), raven.Rwidget_is_valid(e) == 0, "!Rwidget_is_valid(e)");
    raven.Rwidget_destroy(a);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "T(1;d,b)", "Rdock_area_save_layout(dock)");
    raven.Rwidget_destroy(b);
    raven.Rwidget_remove_child(dock, d);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "", "Rdock_area_save_layout(dock)");
    _ = raven.Rdraw_frame();
    _ = raven.Rwidget_add_child(dock, d);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "T(0;d)", "Rdock_area_save_layout(dock)");
    t.CHECK_RECT(@src(), d, 1, bar, 798, 600 - bar - 1, "d");
    raven.Rwindow_destroy(window);
}

// With the animations on: the groups glide to their places and everything comes to rest.
fn test_dock_animated() void {
    const window = window_from(DOCK_XML);
    const dock = raven.Rwidget_find(window, "dock");
    const a = raven.Rwidget_find(window, "a");
    const b = raven.Rwidget_find(window, "b");
    const gap: f32 = if (raven.Rtheme_get_metric(raven.R_METRIC_SPLITTER_SIZE) < 4.0) 4.0 else raven.Rtheme_get_metric(raven.R_METRIC_SPLITTER_SIZE);
    const bar: f32 = raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT) + 2.0;
    const left: f32 = @floor((800.0 - gap) * 0.25);
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var first_w: f32 = undefined;
    var before: raven.RFrameStats = undefined;
    var after: raven.RFrameStats = undefined;
    var i: c_int = undefined;
    var moving: c_int = 0;

    raven.Rset_animations_enabled(raven.R_TRUE);
    raven.Rset_animation_time_step(1.0 / 60.0);
    i = 0;
    while (i < 5) : (i += 1) _ = raven.Rdraw_frame();

    // A is dropped on the right half of B
    raven.Rwindow_inject_mouse_move(window, left + gap + 10.0, bar * 0.5);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, left + gap + 30.0, bar * 0.5 + 30.0);
    i = 0;
    while (i < 3) : (i += 1) _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_move(window, left - 20.0, 300.0);
    i = 0;
    while (i < 10) : (i += 1) _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK_STR(@src(), raven.Rdock_area_save_layout(dock), "H(250,H(500,T(0;b),T(0;a)),T(1;c,d))", "Rdock_area_save_layout(dock)");

    // B is on its way to its new width, not there yet
    raven.Rwidget_get_rect(b, &x, &y, &first_w, &h);
    i = 0;
    while (i < 240) : (i += 1) {
        raven.Rwindow_get_frame_stats(window, &before);
        _ = raven.Rdraw_frame();
        raven.Rwindow_get_frame_stats(window, &after);
        if (after.frame_index == before.frame_index) break;
        moving += 1;
    }
    t.CHECK(@src(), moving > 3 and moving < 240, "moving > 3 && moving < 240");
    raven.Rwidget_get_rect(b, &x, &y, &w, &h);
    t.CHECK(@src(), first_w > w + 10.0, "first_w > w + 10.0f");
    t.CHECK_NEAR(@src(), w, @floor((left - gap) * 0.5) - 2, "w");
    raven.Rwidget_get_rect(a, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), x + w, left - 1, "x + w");

    // a panel deleted while the others are moving
    raven.Rdock_area_move_panel(dock, a, raven.R_DOCK_BOTTOM, raven.R_INVALID_ID, 0.3);
    _ = raven.Rdraw_frame();
    raven.Rwidget_destroy(a);
    _ = raven.Rdraw_frame();
    _ = raven.Rdock_area_load_layout(dock, "T(0;b,c,d)");
    i = 0;
    while (i < 60) : (i += 1) _ = raven.Rdraw_frame();
    t.CHECK_RECT(@src(), b, 1, bar, 798, 600 - bar - 1, "b");
    raven.Rwindow_destroy(window);
    raven.Rset_animations_enabled(raven.R_FALSE);
    raven.Rset_animation_time_step(0.0);
}

// ---------------------------------------------------------------------------
//  Island
// -------------------------------------------------------------------------

var g_island_changes: c_int = 0;
var g_island_state: c_int = 0;

fn on_island_changed(island: raven.Rid, expanded: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = island;
    _ = user_data;
    g_island_changes += 1;
    g_island_state = expanded;
}

// Runs frames until the island is folded, for at most two seconds.
fn wait_folded(island: raven.Rid) void {
    const end: f64 = raven.Rget_time() + 2.0;
    while (raven.Risland_is_expanded(island) != 0 and raven.Rget_time() < end) _ = raven.Rwait_frame(0.02);
}

fn test_island() void {
    var window = window_from(
        "<Window Width=\"600\" Height=\"400\">" ++
            "<Island Name=\"island\" Slot.Padding=\"0,8,0,0\">" ++
            "<Label Name=\"small\">Now</Label>" ++
            "<VBox Name=\"big\" Width=\"300\" Height=\"120\"><Button Name=\"inside\" Text=\"Inside\"/></VBox>" ++
            "</Island>" ++
            "<Button Name=\"under\" Text=\"Under\" Slot.VAlign=\"Top\" Slot.HAlign=\"Center\" Width=\"200\" Height=\"100\"/>" ++
            "</Window>");
    const island = raven.Rwidget_find(window, "island");
    const inside = raven.Rwidget_find(window, "inside");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;

    t.CHECK(@src(), raven.Rwidget_get_type(island) == raven.R_WIDGET_ISLAND, "Rwidget_get_type(island) == R_WIDGET_ISLAND");
    t.CHECK(@src(), raven.Rwindow_get_island(window) == island, "Rwindow_get_island(window) == island");
    t.CHECK(@src(), raven.Rwidget_get_window(island) == window, "Rwidget_get_window(island) == window");
    t.CHECK(@src(), raven.Rwindow_get_content(window) == raven.Rwidget_find(window, "under"), "Rwindow_get_content(window) == Rwidget_find(window, \"under\")");
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");

    // folded: a capsule around its first child, at the top of the window, in the middle
    raven.Rwidget_get_rect(island, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), y, 8, "y");
    t.CHECK_NEAR(@src(), x + w * 0.5, 300, "x + w * 0.5f");
    t.CHECK(@src(), w >= 96.0 and w < 200.0 and h >= 30.0 and h < 50.0, "w >= 96.0f && w < 200.0f && h >= 30.0f && h < 50.0f");

    // it floats above the content: the pointer on it is not on the button under it
    raven.Risland_set_changed_callback(island, on_island_changed, null);
    g_island_changes = 0;
    g_clicked = 0;
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(window, "under"), on_clicked, null);
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(window) == island, "Rwindow_get_hovered_widget(window) == island");
    // ... and the pointer on it unfolds it, around its second child
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    t.CHECK(@src(), g_island_changes == 1 and g_island_state == 1, "g_island_changes == 1 && g_island_state == 1");
    raven.Rwidget_get_rect(island, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), w, 300 + 36, "w");
    t.CHECK_NEAR(@src(), h, 120 + 30, "h");
    t.CHECK_NEAR(@src(), x + w * 0.5, 300, "x + w * 0.5f");
    t.CHECK_RECT(@src(), raven.Rwidget_find(window, "big"), x + 18, 8 + 15, 300, 120, "Rwidget_find(window, \"big\")");

    // the controls inside work, and the island stays open
    raven.Rbutton_set_clicked_callback(inside, on_clicked, null);
    t.test_click(window, inside);
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");

    // the pointer leaves: it folds back a moment later
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    wait_folded(island);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    t.CHECK(@src(), g_island_changes == 2 and g_island_state == 0, "g_island_changes == 2 && g_island_state == 0");
    // what it showed unfolded is out of reach
    raven.Rwidget_get_rect(island, &x, &y, &w, &h);
    t.CHECK(@src(), h < 50.0, "h < 50.0f");
    t.test_click_at(window, 300.0, 90.0);
    t.CHECK(@src(), g_clicked == 2, "g_clicked == 2");

    // unfolded by the pointer, then clicked: it is pinned, and stays when the pointer leaves
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    t.test_click_at(window, 300.0 - 150.0, 14.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    {
        const end: f64 = raven.Rget_time() + 0.5;
        while (raven.Rget_time() < end) _ = raven.Rwait_frame(0.02);
    }
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    t.CHECK(@src(), g_island_changes == 3, "g_island_changes == 3");
    // a press anywhere else folds it, and still does what it was for
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    raven.Rwindow_inject_mouse_move(window, 520.0, 300.0);
    t.test_click_at(window, 520.0, 300.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    t.CHECK(@src(), g_island_changes == 4 and g_island_state == 0, "g_island_changes == 4 && g_island_state == 0");
    // a click folds a pinned island, and the pointer still on it does not unfold it again at once
    t.test_click_at(window, 300.0, 14.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    t.test_click_at(window, 300.0, 14.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_move(window, 302.0, 16.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    wait_folded(island);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    g_island_changes = 2;

    // without hovering: a click unfolds it, another one folds it
    raven.Risland_set_expand_on_hover(island, raven.R_FALSE);
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    t.test_click_at(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    t.test_click_at(window, 300.0 - 150.0, 14.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    raven.Risland_set_expand_on_click(island, raven.R_FALSE);
    t.test_click_at(window, 300.0, 20.0);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    t.CHECK(@src(), g_island_changes == 4, "g_island_changes == 4");

    // from the application: for good, or for a moment
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    raven.Risland_set_expanded(island, raven.R_TRUE);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    raven.Risland_set_expanded(island, raven.R_FALSE);
    raven.Risland_expand_for(island, 0.05);
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    wait_folded(island);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    // shown for a moment while the pointer is on it: it waits for the pointer to leave
    raven.Rwindow_inject_mouse_move(window, 300.0, 20.0);
    raven.Risland_expand_for(island, 0.05);
    {
        const end: f64 = raven.Rget_time() + 0.3;
        while (raven.Rget_time() < end) _ = raven.Rwait_frame(0.02);
    }
    t.CHECK(@src(), raven.Risland_is_expanded(island) != 0, "Risland_is_expanded(island)");
    raven.Rwindow_inject_mouse_move(window, 300.0, 350.0);
    wait_folded(island);
    t.CHECK(@src(), raven.Risland_is_expanded(island) == 0, "!Risland_is_expanded(island)");
    raven.Risland_set_attached(island, raven.R_TRUE);
    _ = raven.Rdraw_frame();

    // an island is also a widget like any other
    {
        const other = raven.Risland_create();
        _ = raven.Rwidget_add_child(other, raven.Rlabel_create("Only one child"));
        raven.Rwindow_set_island(window, other);
        t.CHECK(@src(), raven.Rwidget_is_valid(island) == 0, "!Rwidget_is_valid(island)");
        t.CHECK(@src(), raven.Rwindow_get_island(window) == other, "Rwindow_get_island(window) == other");
        raven.Risland_set_expanded(other, raven.R_TRUE);
        _ = raven.Rdraw_frame();
        raven.Rwindow_set_island(window, raven.R_INVALID_ID);
        t.CHECK(@src(), raven.Rwidget_is_valid(other) == 0, "!Rwidget_is_valid(other)");
        t.CHECK(@src(), raven.Rwindow_get_island(window) == raven.R_INVALID_ID, "Rwindow_get_island(window) == R_INVALID_ID");
    }
    raven.Rwindow_destroy(window);

    window = window_from(
        "<Window Width=\"600\" Height=\"400\"><VBox>" ++
            "<Island Name=\"i\" Expanded=\"true\" ExpandOnHover=\"false\" Slot.HAlign=\"Left\"><Label>a</Label><Label Width=\"200\" Height=\"100\">b</Label></Island>" ++
            "<Label Name=\"below\">Below</Label></VBox></Window>");
    t.CHECK(@src(), raven.Risland_is_expanded(raven.Rwidget_find(window, "i")) != 0, "Risland_is_expanded(Rwidget_find(window, \"i\"))");
    t.CHECK_RECT(@src(), raven.Rwidget_find(window, "i"), 0, 0, 236, 130, "Rwidget_find(window, \"i\")");
    t.CHECK_RECT(@src(), raven.Rwidget_find(window, "below"), 0, 130, 600, 18, "Rwidget_find(window, \"below\")");
    raven.Rwindow_destroy(window);
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_shell: cannot initialize Raven\n");
        return 1;
    }
    t.RUN(test_header_bar, "test_header_bar");
    t.RUN(test_header_variants, "test_header_variants");
    t.RUN(test_drop, "test_drop");
    t.RUN(test_hit_test, "test_hit_test");
    t.RUN(test_dock, "test_dock");
    t.RUN(test_dock_animated, "test_dock_animated");
    t.RUN(test_island, "test_island");
    raven.Rshutdown();
    return t.test_report("test_shell");
}
