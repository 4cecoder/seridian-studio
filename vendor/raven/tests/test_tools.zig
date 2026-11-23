// Translated to Zig from vendor/raven/tests/test_tools.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - the widgets of creative tools (color picker, timeline, node
// graph), the background blur and the windows that are seen through, and
// the hooks other libraries build on (tags made by code, destroy callback,
// image decoding).

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");
const test_config = @import("test_config");

pub const panic = t.panic;

fn make_window(xml: [*c]const u8) raven.Rid {
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    _ = raven.Rdraw_frame();
    return window;
}

fn click_at(window: raven.Rid, x: f32, y: f32) void {
    raven.Rwindow_inject_mouse_move(window, x, y);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
}

// Press, move in two steps (a drag starts after a few units), release.
fn drag(window: raven.Rid, x0: f32, y0: f32, x1: f32, y1: f32) void {
    raven.Rwindow_inject_mouse_move(window, x0, y0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, (x0 + x1) * 0.5, (y0 + y1) * 0.5);
    raven.Rwindow_inject_mouse_move(window, x1, y1);
    _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    _ = raven.Rdraw_frame();
}

fn press_key(window: raven.Rid, key: raven.RKey, modifiers: raven.Ruint) void {
    raven.Rwindow_inject_key(window, key, raven.R_TRUE, modifiers);
    raven.Rwindow_inject_key(window, key, raven.R_FALSE, modifiers);
}

// ---------------------------------------------------------------------------
//  Color picker
// ---------------------------------------------------------------------------

var g_color_calls: c_int = 0;
var g_color: [4]f32 = std.mem.zeroes([4]f32);
fn on_color(picker: raven.Rid, r: f32, g: f32, b: f32, a: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = picker;
    _ = user_data;
    g_color_calls += 1;
    g_color[0] = r;
    g_color[1] = g;
    g_color[2] = b;
    g_color[3] = a;
}

fn test_color_picker() void {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    var h: f32 = undefined;
    var s: f32 = undefined;
    var v: f32 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var hh: f32 = undefined;

    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");
    const window = make_window("<Window Width=\"320\" Height=\"460\"><VBox Slot.Padding=\"10\">" ++
        "<ColorPicker Name=\"p\" Color=\"#FF0000\" Swatches=\"#00FF00, #0000FF80\"/></VBox></Window>");
    const picker = raven.Rwidget_find(window, "p");
    t.CHECK(@src(), picker != raven.R_INVALID_ID and raven.Rwidget_get_type(picker) == raven.R_WIDGET_COLOR_PICKER, "picker != R_INVALID_ID && Rwidget_get_type(picker) == R_WIDGET_COLOR_PICKER");

    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK(@src(), r == 1.0 and g == 0.0 and b == 0.0 and a == 1.0, "r == 1.0f && g == 0.0f && b == 0.0f && a == 1.0f");
    raven.Rcolor_picker_get_hsv(picker, &h, &s, &v);
    t.CHECK_NEAR(@src(), h, 0.0, "h");
    t.CHECK(@src(), s == 1.0 and v == 1.0, "s == 1.0f && v == 1.0f");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#FF0000", "Rcolor_picker_get_hex(picker)");
    t.CHECK(@src(), raven.Rcolor_picker_get_swatch_count(picker) == 2, "Rcolor_picker_get_swatch_count(picker) == 2");

    // text
    t.CHECK(@src(), raven.Rcolor_picker_set_hex(picker, "#00ff0080") != 0, "Rcolor_picker_set_hex(picker, \"#00ff0080\")");
    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK(@src(), r == 0.0 and g == 1.0 and b == 0.0, "r == 0.0f && g == 1.0f && b == 0.0f");
    t.CHECK_NEAR(@src(), a * 255.0, 128.0, "a * 255.0f");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#00FF0080", "Rcolor_picker_get_hex(picker)");
    // a code without opacity leaves the opacity as it is
    t.CHECK(@src(), raven.Rcolor_picker_set_hex(picker, "36C") != 0, "Rcolor_picker_set_hex(picker, \"36C\")");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#3366CC80", "Rcolor_picker_get_hex(picker)");
    t.CHECK(@src(), raven.Rcolor_picker_set_hex(picker, "not a color") == 0, "!Rcolor_picker_set_hex(picker, \"not a color\")");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#3366CC80", "Rcolor_picker_get_hex(picker)");
    t.CHECK(@src(), raven.Rcolor_picker_set_hex(picker, "#3366CCFF") != 0, "Rcolor_picker_set_hex(picker, \"#3366CCFF\")");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#3366CC", "Rcolor_picker_get_hex(picker)");

    // hue, saturation, value; a gray remembers its hue
    raven.Rcolor_picker_set_hsv(picker, 240.0, 1.0, 1.0);
    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK(@src(), r == 0.0 and g == 0.0 and b == 1.0, "r == 0.0f && g == 0.0f && b == 1.0f");
    raven.Rcolor_picker_set_hsv(picker, 120.0, 0.0, 0.5);
    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK_NEAR(@src(), r * 255.0, 127.5, "r * 255.0f");
    t.CHECK(@src(), r == g and g == b, "r == g && g == b");
    raven.Rcolor_picker_get_hsv(picker, &h, &s, &v);
    t.CHECK_NEAR(@src(), h, 120.0, "h");

    // the conversions, there and back
    raven.Rcolor_rgb_to_hsv(1.0, 0.5, 0.0, &h, &s, &v);
    t.CHECK_NEAR(@src(), h, 30.0, "h");
    t.CHECK(@src(), s == 1.0 and v == 1.0, "s == 1.0f && v == 1.0f");
    raven.Rcolor_hsv_to_rgb(h, s, v, &r, &g, &b);
    t.CHECK_NEAR(@src(), r * 255.0, 255.0, "r * 255.0f");
    t.CHECK_NEAR(@src(), g * 255.0, 127.5, "g * 255.0f");
    t.CHECK_NEAR(@src(), b * 255.0, 0.0, "b * 255.0f");

    // without opacity, colors are opaque
    raven.Rcolor_picker_set_color(picker, 0.2, 0.4, 0.6, 0.5);
    raven.Rcolor_picker_set_alpha_enabled(picker, raven.R_FALSE);
    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK(@src(), a == 1.0, "a == 1.0f");
    t.CHECK_STR(@src(), raven.Rcolor_picker_get_hex(picker), "#336699", "Rcolor_picker_get_hex(picker)");
    raven.Rcolor_picker_set_alpha_enabled(picker, raven.R_TRUE);

    // swatches
    raven.Rcolor_picker_add_swatch(picker, 1.0, 1.0, 1.0, 1.0);
    t.CHECK(@src(), raven.Rcolor_picker_get_swatch_count(picker) == 3, "Rcolor_picker_get_swatch_count(picker) == 3");
    raven.Rcolor_picker_clear_swatches(picker);
    t.CHECK(@src(), raven.Rcolor_picker_get_swatch_count(picker) == 0, "Rcolor_picker_get_swatch_count(picker) == 0");

    // the mouse in the square: saturation across, value down; the callback tells
    raven.Rcolor_picker_set_changed_callback(picker, on_color, null);
    raven.Rcolor_picker_set_hsv(picker, 200.0, 1.0, 1.0);
    t.CHECK(@src(), g_color_calls == 0, "g_color_calls == 0");
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(picker, &x, &y, &w, &hh);
    t.CHECK(@src(), w > 100.0 and hh > 200.0, "w > 100.0f && hh > 200.0f");
    click_at(window, x + w * 0.5, y + 2.0);
    t.CHECK(@src(), g_color_calls >= 1, "g_color_calls >= 1");
    raven.Rcolor_picker_get_hsv(picker, &h, &s, &v);
    t.CHECK_NEAR(@src(), h, 200.0, "h");
    t.CHECK_NEAR(@src(), s * 100.0, 50.0, "s * 100.0f");
    t.CHECK(@src(), v > 0.95, "v > 0.95f");
    raven.Rcolor_picker_get_color(picker, &r, &g, &b, &a);
    t.CHECK(@src(), g_color[0] == r and g_color[1] == g and g_color[2] == b and g_color[3] == a, "g_color[0] == r && g_color[1] == g && g_color[2] == b && g_color[3] == a");
    // dragging out of the square keeps the gesture and clamps
    drag(window, x + w * 0.5, y + 20.0, x - 50.0, y + 20.0);
    raven.Rcolor_picker_get_hsv(picker, &h, &s, &v);
    t.CHECK(@src(), s == 0.0, "s == 0.0f");
    t.CHECK_NEAR(@src(), h, 200.0, "h");

    // as a button that opens the picker in a popup
    raven.Rcolor_picker_set_popup(picker, raven.R_TRUE);
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(picker, &x, &y, &w, &hh);
    t.CHECK(@src(), hh < 60.0, "hh < 60.0f");
    click_at(window, x + w * 0.5, y + hh * 0.5);
    _ = raven.Rdraw_frame();
    press_key(window, raven.R_KEY_ESCAPE, 0);
    _ = raven.Rdraw_frame();
    raven.Rcolor_picker_set_popup(picker, raven.R_FALSE);
    raven.Rcolor_picker_set_compact(picker, raven.R_TRUE);
    _ = raven.Rdraw_frame();

    raven.Rshutdown();
}

// ---------------------------------------------------------------------------
//  Timeline
// ---------------------------------------------------------------------------

var g_time_calls: c_int = 0;
var g_time_value: f64 = 0.0;
fn on_time(timeline: raven.Rid, seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = timeline;
    _ = user_data;
    g_time_calls += 1;
    g_time_value = seconds;
}

var g_item_calls: [4]c_int = std.mem.zeroes([4]c_int);
var g_item_last: [4]c_int = std.mem.zeroes([4]c_int);
fn on_item(timeline: raven.Rid, item: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const which: c_int = @intCast(@as(isize, @bitCast(@intFromPtr(user_data))));
    _ = timeline;
    g_item_calls[@intCast(which)] += 1;
    g_item_last[@intCast(which)] = item;
}

fn test_timeline() void {
    var one: c_int = undefined;
    var two: c_int = undefined;
    var key: c_int = undefined;
    var marker: c_int = undefined;
    var i: c_int = undefined;
    var start: f64 = undefined;
    var end: f64 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;

    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");
    const window = make_window("<Window Width=\"900\" Height=\"300\">" ++
        "<Timeline Name=\"t\" Duration=\"10\" FrameRate=\"10\" HeaderWidth=\"100\">" ++
        "<Track Name=\"A\" Color=\"#FF0000\"><Clip Start=\"1\" Length=\"2\" Label=\"one\"/><Key Time=\"5\" Label=\"k\"/></Track>" ++
        "<Track Name=\"B\"><Clip Start=\"4\" End=\"6\" Label=\"two\" Selected=\"true\"/></Track>" ++
        "<Marker Time=\"8\" Label=\"m\"/></Timeline></Window>");
    const tl = raven.Rwidget_find(window, "t");
    t.CHECK(@src(), tl != raven.R_INVALID_ID and raven.Rwidget_get_type(tl) == raven.R_WIDGET_TIMELINE, "tl != R_INVALID_ID && Rwidget_get_type(tl) == R_WIDGET_TIMELINE");
    raven.Rwidget_get_rect(tl, &x, &y, &w, &h);
    t.CHECK_RECT(@src(), tl, 0.0, 0.0, 900.0, 300.0, "tl");
    // 100 units of headers, then 10 seconds over 800 units
    const second: f32 = 80.0;

    t.CHECK(@src(), raven.Rtimeline_get_duration(tl) == 10.0, "Rtimeline_get_duration(tl) == 10.0");
    t.CHECK(@src(), raven.Rtimeline_get_frame_rate(tl) == 10.0, "Rtimeline_get_frame_rate(tl) == 10.0");
    t.CHECK(@src(), raven.Rtimeline_get_track_count(tl) == 2, "Rtimeline_get_track_count(tl) == 2");
    const track_a = raven.Rtimeline_get_track(tl, 0);
    const track_b = raven.Rtimeline_get_track(tl, 1);
    t.CHECK(@src(), track_a > 0 and track_b > 0 and track_a != track_b, "track_a > 0 && track_b > 0 && track_a != track_b");
    t.CHECK(@src(), raven.Rtimeline_get_track(tl, 2) == 0, "Rtimeline_get_track(tl, 2) == 0");
    t.CHECK_STR(@src(), raven.Rtimeline_get_track_name(tl, track_a), "A", "Rtimeline_get_track_name(tl, track_a)");
    t.CHECK(@src(), raven.Rtimeline_get_item_count(tl) == 4, "Rtimeline_get_item_count(tl) == 4");
    marker = 0;
    key = marker;
    two = key;
    one = two;
    i = 0;
    while (i < raven.Rtimeline_get_item_count(tl)) : (i += 1) {
        const item = raven.Rtimeline_get_item(tl, i);
        switch (raven.Rtimeline_get_item_type(tl, item)) {
            raven.R_TIMELINE_CLIP => {
                if (t.strcmp(raven.Rtimeline_get_item_label(tl, item), "one") == 0) one = item else two = item;
            },
            raven.R_TIMELINE_KEY => key = item,
            raven.R_TIMELINE_MARKER => marker = item,
            else => {},
        }
    }
    t.CHECK(@src(), one != 0 and two != 0 and key != 0 and marker != 0, "one && two && key && marker");
    t.CHECK(@src(), raven.Rtimeline_get_item_track(tl, one) == track_a and raven.Rtimeline_get_item_track(tl, two) == track_b, "Rtimeline_get_item_track(tl, one) == track_a && Rtimeline_get_item_track(tl, two) == track_b");
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, one) == 1.0 and raven.Rtimeline_get_item_length(tl, one) == 2.0, "Rtimeline_get_item_start(tl, one) == 1.0 && Rtimeline_get_item_length(tl, one) == 2.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, two) == 4.0 and raven.Rtimeline_get_item_length(tl, two) == 2.0, "Rtimeline_get_item_start(tl, two) == 4.0 && Rtimeline_get_item_length(tl, two) == 2.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, key) == 5.0 and raven.Rtimeline_get_item_length(tl, key) == 0.0, "Rtimeline_get_item_start(tl, key) == 5.0 && Rtimeline_get_item_length(tl, key) == 0.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_track(tl, marker) == 0 and raven.Rtimeline_get_item_start(tl, marker) == 8.0, "Rtimeline_get_item_track(tl, marker) == 0 && Rtimeline_get_item_start(tl, marker) == 8.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_type(tl, 9999) == raven.R_TIMELINE_NONE, "Rtimeline_get_item_type(tl, 9999) == R_TIMELINE_NONE");
    t.CHECK(@src(), raven.Rtimeline_is_selected(tl, two) != 0 and raven.Rtimeline_is_selected(tl, one) == 0, "Rtimeline_is_selected(tl, two) && !Rtimeline_is_selected(tl, one)");
    t.CHECK(@src(), raven.Rtimeline_get_selection_count(tl) == 1 and raven.Rtimeline_get_selected(tl, 0) == two, "Rtimeline_get_selection_count(tl) == 1 && Rtimeline_get_selected(tl, 0) == two");

    raven.Rtimeline_set_time_callback(tl, on_time, null);
    raven.Rtimeline_set_changed_callback(tl, on_item, @ptrFromInt(@as(usize, @bitCast(@as(isize, 0)))));
    raven.Rtimeline_set_selection_callback(tl, on_item, @ptrFromInt(@as(usize, @bitCast(@as(isize, 1)))));
    raven.Rtimeline_set_removed_callback(tl, on_item, @ptrFromInt(@as(usize, @bitCast(@as(isize, 2)))));
    raven.Rtimeline_set_activated_callback(tl, on_item, @ptrFromInt(@as(usize, @bitCast(@as(isize, 3)))));
    @memset(&g_item_calls, 0);

    // the ruler: the playhead comes under the pointer, on a frame
    click_at(window, x + 100.0 + second * 3.02, y + 15.0);
    t.CHECK(@src(), g_time_calls >= 1, "g_time_calls >= 1");
    t.CHECK_NEAR(@src(), g_time_value * 100.0, 300.0, "g_time_value * 100.0");
    t.CHECK_NEAR(@src(), raven.Rtimeline_get_time(tl) * 100.0, 300.0, "Rtimeline_get_time(tl) * 100.0");
    // setting it from the application does not call back
    g_time_calls = 0;
    raven.Rtimeline_set_time(tl, 2.5);
    t.CHECK(@src(), g_time_calls == 0 and raven.Rtimeline_get_time(tl) == 2.5, "g_time_calls == 0 && Rtimeline_get_time(tl) == 2.5");
    raven.Rtimeline_set_time(tl, 99.0);
    t.CHECK(@src(), raven.Rtimeline_get_time(tl) == 10.0, "Rtimeline_get_time(tl) == 10.0");
    raven.Rtimeline_set_time(tl, 9.5);

    // a clip is dragged two seconds later, and down to the other track
    drag(window, x + 100.0 + second * 2.0, y + 30.0 + 19.0, x + 100.0 + second * 4.0, y + 30.0 + 38.0 + 19.0);
    t.CHECK_NEAR(@src(), raven.Rtimeline_get_item_start(tl, one) * 100.0, 300.0, "Rtimeline_get_item_start(tl, one) * 100.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_length(tl, one) == 2.0, "Rtimeline_get_item_length(tl, one) == 2.0");
    t.CHECK(@src(), raven.Rtimeline_get_item_track(tl, one) == track_b, "Rtimeline_get_item_track(tl, one) == track_b");
    // (told as it happens: once per step of the gesture)
    t.CHECK(@src(), g_item_calls[0] >= 1 and g_item_last[0] == one, "g_item_calls[0] >= 1 && g_item_last[0] == one");
    t.CHECK(@src(), raven.Rtimeline_is_selected(tl, one) != 0 and raven.Rtimeline_is_selected(tl, two) == 0, "Rtimeline_is_selected(tl, one) && !Rtimeline_is_selected(tl, two)");
    t.CHECK(@src(), g_item_calls[1] >= 1, "g_item_calls[1] >= 1");

    // the right end of the other clip is pulled one second further
    drag(window, x + 100.0 + second * 6.0 - 3.0, y + 30.0 + 38.0 + 19.0, x + 100.0 + second * 7.0 - 3.0, y + 30.0 + 38.0 + 19.0);
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, two) == 4.0, "Rtimeline_get_item_start(tl, two) == 4.0");
    t.CHECK_NEAR(@src(), raven.Rtimeline_get_item_length(tl, two) * 100.0, 300.0, "Rtimeline_get_item_length(tl, two) * 100.0");
    t.CHECK(@src(), g_item_last[0] == two, "g_item_last[0] == two");

    // Escape while dragging puts things back
    raven.Rwindow_inject_mouse_move(window, x + 100.0 + second * 5.0, y + 30.0 + 19.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, x + 100.0 + second * 6.0, y + 30.0 + 19.0);
    raven.Rwindow_inject_mouse_move(window, x + 100.0 + second * 7.0, y + 30.0 + 19.0);
    t.CHECK_NEAR(@src(), raven.Rtimeline_get_item_start(tl, key) * 100.0, 700.0, "Rtimeline_get_item_start(tl, key) * 100.0");
    press_key(window, raven.R_KEY_ESCAPE, 0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, key) == 5.0, "Rtimeline_get_item_start(tl, key) == 5.0");

    // a locked track keeps its items
    raven.Rtimeline_set_track_locked(tl, track_a, raven.R_TRUE);
    drag(window, x + 100.0 + second * 5.0, y + 30.0 + 19.0, x + 100.0 + second * 6.0, y + 30.0 + 19.0);
    t.CHECK(@src(), raven.Rtimeline_get_item_start(tl, key) == 5.0, "Rtimeline_get_item_start(tl, key) == 5.0");
    raven.Rtimeline_set_track_locked(tl, track_a, raven.R_FALSE);
    raven.Rtimeline_set_track_muted(tl, track_a, raven.R_TRUE);
    t.CHECK(@src(), raven.Rtimeline_is_track_muted(tl, track_a) != 0, "Rtimeline_is_track_muted(tl, track_a)");

    // the keyboard: Delete removes what is selected, after telling
    raven.Rtimeline_select(tl, key, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtimeline_get_selection_count(tl) == 1 and raven.Rtimeline_is_selected(tl, key) != 0, "Rtimeline_get_selection_count(tl) == 1 && Rtimeline_is_selected(tl, key)");
    raven.Rwidget_focus(tl);
    press_key(window, raven.R_KEY_DELETE, 0);
    t.CHECK(@src(), g_item_calls[2] == 1 and g_item_last[2] == key, "g_item_calls[2] == 1 && g_item_last[2] == key");
    t.CHECK(@src(), raven.Rtimeline_get_item_count(tl) == 3, "Rtimeline_get_item_count(tl) == 3");
    t.CHECK(@src(), raven.Rtimeline_get_item_type(tl, key) == raven.R_TIMELINE_NONE, "Rtimeline_get_item_type(tl, key) == R_TIMELINE_NONE");
    // arrows move the playhead by a frame, Home goes to the start
    raven.Rtimeline_set_time(tl, 2.0);
    press_key(window, raven.R_KEY_RIGHT, 0);
    t.CHECK_NEAR(@src(), raven.Rtimeline_get_time(tl) * 100.0, 210.0, "Rtimeline_get_time(tl) * 100.0");
    press_key(window, raven.R_KEY_HOME, 0);
    t.CHECK(@src(), raven.Rtimeline_get_time(tl) == 0.0, "Rtimeline_get_time(tl) == 0.0");
    press_key(window, raven.R_KEY_A, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtimeline_get_selection_count(tl) == 3, "Rtimeline_get_selection_count(tl) == 3");
    raven.Rtimeline_clear_selection(tl);
    t.CHECK(@src(), raven.Rtimeline_get_selection_count(tl) == 0, "Rtimeline_get_selection_count(tl) == 0");

    // the view: Ctrl + wheel zooms around the pointer
    raven.Rtimeline_get_view(tl, &start, &end);
    t.CHECK(@src(), start == 0.0 and end == 10.0, "start == 0.0 && end == 10.0");
    raven.Rwindow_inject_mouse_move(window, x + 100.0 + second * 5.0, y + 100.0);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_CTRL, raven.R_TRUE, raven.R_MOD_CTRL);
    raven.Rwindow_inject_mouse_wheel(window, 0.0, 2.0);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_CTRL, raven.R_FALSE, 0);
    _ = raven.Rdraw_frame();
    raven.Rtimeline_get_view(tl, &start, &end);
    t.CHECK(@src(), start > 0.5 and end < 9.5 and end - start < 8.0, "start > 0.5 && end < 9.5 && end - start < 8.0");
    t.CHECK_NEAR(@src(), (start + end) * 0.5 * 10.0, 50.0, "(start + end) * 0.5 * 10.0");
    raven.Rtimeline_set_view(tl, 2.0, 6.0);
    raven.Rtimeline_get_view(tl, &start, &end);
    t.CHECK(@src(), start == 2.0 and end == 6.0, "start == 2.0 && end == 6.0");
    t.EXPECT_ERRORS_BEGIN();
    raven.Rtimeline_set_view(tl, 5.0, 5.0);
    raven.Rtimeline_set_duration(tl, -1.0);
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");

    // from the application
    raven.Rtimeline_set_item(tl, one, track_a, 0.5, 1.5);
    t.CHECK(@src(), raven.Rtimeline_get_item_track(tl, one) == track_a and raven.Rtimeline_get_item_start(tl, one) == 0.5 and raven.Rtimeline_get_item_length(tl, one) == 1.5, "Rtimeline_get_item_track(tl, one) == track_a && Rtimeline_get_item_start(tl, one) == 0.5 && Rtimeline_get_item_length(tl, one) == 1.5");
    raven.Rtimeline_set_item_label(tl, one, "renamed");
    t.CHECK_STR(@src(), raven.Rtimeline_get_item_label(tl, one), "renamed", "Rtimeline_get_item_label(tl, one)");
    {
        const track_c = raven.Rtimeline_add_track(tl, "C");
        const clip = raven.Rtimeline_add_clip(tl, track_c, 1.0, 1.0, "c");
        const added_key = raven.Rtimeline_add_key(tl, track_c, 3.0);
        t.CHECK(@src(), track_c > 0 and clip > 0 and added_key > 0 and clip != added_key, "track_c > 0 && clip > 0 && added_key > 0 && clip != added_key");
        t.CHECK(@src(), raven.Rtimeline_get_track_count(tl) == 3 and raven.Rtimeline_get_item_count(tl) == 5, "Rtimeline_get_track_count(tl) == 3 && Rtimeline_get_item_count(tl) == 5");
        raven.Rtimeline_set_track_name(tl, track_c, "Sound");
        t.CHECK_STR(@src(), raven.Rtimeline_get_track_name(tl, track_c), "Sound", "Rtimeline_get_track_name(tl, track_c)");
        // removing a track removes what was on it
        raven.Rtimeline_remove_track(tl, track_c);
        t.CHECK(@src(), raven.Rtimeline_get_track_count(tl) == 2 and raven.Rtimeline_get_item_count(tl) == 3, "Rtimeline_get_track_count(tl) == 2 && Rtimeline_get_item_count(tl) == 3");
        t.CHECK(@src(), raven.Rtimeline_get_item_type(tl, clip) == raven.R_TIMELINE_NONE, "Rtimeline_get_item_type(tl, clip) == R_TIMELINE_NONE");
    }
    raven.Rtimeline_remove_item(tl, marker);
    t.CHECK(@src(), raven.Rtimeline_get_item_count(tl) == 2, "Rtimeline_get_item_count(tl) == 2");

    // playing
    t.CHECK(@src(), raven.Rtimeline_is_playing(tl) == 0, "!Rtimeline_is_playing(tl)");
    raven.Rtimeline_set_playing(tl, raven.R_TRUE);
    t.CHECK(@src(), raven.Rtimeline_is_playing(tl) != 0, "Rtimeline_is_playing(tl)");
    _ = raven.Rdraw_frame();
    raven.Rtimeline_set_playing(tl, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtimeline_is_playing(tl) == 0, "!Rtimeline_is_playing(tl)");
    raven.Rtimeline_set_loop(tl, raven.R_TRUE);

    raven.Rtimeline_clear(tl);
    t.CHECK(@src(), raven.Rtimeline_get_item_count(tl) == 0 and raven.Rtimeline_get_track_count(tl) == 0, "Rtimeline_get_item_count(tl) == 0 && Rtimeline_get_track_count(tl) == 0");
    _ = raven.Rdraw_frame();
    raven.Rshutdown();
}

// ---------------------------------------------------------------------------
//  Node graph
// ---------------------------------------------------------------------------

var g_graph_calls: [5]c_int = std.mem.zeroes([5]c_int);
var g_graph_last: [5]c_int = std.mem.zeroes([5]c_int);
fn on_graph(graph: raven.Rid, item: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const which: c_int = @intCast(@as(isize, @bitCast(@intFromPtr(user_data))));
    _ = graph;
    g_graph_calls[@intCast(which)] += 1;
    g_graph_last[@intCast(which)] = item;
}

var g_connect_allowed: c_int = 1;
var g_connect_calls: c_int = 0;
fn on_connect(graph: raven.Rid, output_pin: c_int, input_pin: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    g_connect_calls += 1;
    t.CHECK(@src(), raven.Rnode_graph_is_pin_output(graph, output_pin) != 0 and raven.Rnode_graph_is_pin_output(graph, input_pin) == 0, "Rnode_graph_is_pin_output(graph, output_pin) && !Rnode_graph_is_pin_output(graph, input_pin)");
    return g_connect_allowed;
}

fn test_node_graph() void {
    var other: c_int = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var px: f32 = undefined;
    var py: f32 = undefined;
    var qx: f32 = undefined;
    var qy: f32 = undefined;
    var zoom: f32 = undefined;

    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");
    const window = make_window("<Window Width=\"900\" Height=\"600\"><NodeGraph Name=\"g\">" ++
        "<Type Name=\"number\" Color=\"#00FF00\"/>" ++
        "<Node Name=\"a\" Title=\"Source\" X=\"50\" Y=\"50\"><Output Name=\"o\" Label=\"Out\" Type=\"number\"/><Output Name=\"c\" Label=\"Col\" Type=\"color\"/></Node>" ++
        "<Node Name=\"b\" Title=\"Mix\" X=\"400\" Y=\"80\"><Input Name=\"i\" Label=\"In\" Type=\"number\"/><Input Label=\"Any\"/>" ++
        "<Checkbox Name=\"chk\" Text=\"Option\"/></Node>" ++
        "<Node Name=\"c\" Title=\"Result\" X=\"400\" Y=\"320\" Color=\"#FF0000\"><Input Name=\"i\" Label=\"In\" Type=\"number\"/></Node>" ++
        "<Link From=\"a.o\" To=\"b.i\"/>" ++
        "</NodeGraph></Window>");
    const graph = raven.Rwidget_find(window, "g");
    t.CHECK(@src(), graph != raven.R_INVALID_ID and raven.Rwidget_get_type(graph) == raven.R_WIDGET_NODE_GRAPH, "graph != R_INVALID_ID && Rwidget_get_type(graph) == R_WIDGET_NODE_GRAPH");
    t.CHECK_RECT(@src(), graph, 0.0, 0.0, 900.0, 600.0, "graph");

    // what the document said
    t.CHECK(@src(), raven.Rnode_graph_get_node_count(graph) == 3, "Rnode_graph_get_node_count(graph) == 3");
    const a = raven.Rnode_graph_find_node(graph, "a");
    const b = raven.Rnode_graph_find_node(graph, "b");
    const c = raven.Rnode_graph_find_node(graph, "c");
    t.CHECK(@src(), a != 0 and b != 0 and c != 0 and a != b and b != c, "a && b && c && a != b && b != c");
    t.CHECK(@src(), raven.Rnode_graph_get_node(graph, 0) == a and raven.Rnode_graph_get_node(graph, 2) == c and raven.Rnode_graph_get_node(graph, 3) == 0, "Rnode_graph_get_node(graph, 0) == a && Rnode_graph_get_node(graph, 2) == c && Rnode_graph_get_node(graph, 3) == 0");
    t.CHECK(@src(), raven.Rnode_graph_find_node(graph, "nobody") == 0, "Rnode_graph_find_node(graph, \"nobody\") == 0");
    t.CHECK_STR(@src(), raven.Rnode_graph_get_node_title(graph, b), "Mix", "Rnode_graph_get_node_title(graph, b)");
    t.CHECK_STR(@src(), raven.Rnode_graph_get_node_name(graph, b), "b", "Rnode_graph_get_node_name(graph, b)");
    raven.Rnode_graph_get_node_position(graph, c, &px, &py);
    t.CHECK(@src(), px == 400.0 and py == 320.0, "px == 400.0f && py == 320.0f");
    const a_out = raven.Rnode_graph_find_pin(graph, a, "o");
    const a_color = raven.Rnode_graph_find_pin(graph, a, "c");
    const b_in = raven.Rnode_graph_find_pin(graph, b, "i");
    const b_any = raven.Rnode_graph_find_pin(graph, b, "Any");
    const c_in = raven.Rnode_graph_find_pin(graph, c, "i");
    t.CHECK(@src(), a_out != 0 and a_color != 0 and b_in != 0 and b_any != 0 and c_in != 0, "a_out && a_color && b_in && b_any && c_in");
    t.CHECK(@src(), raven.Rnode_graph_get_output(graph, a, 0) == a_out and raven.Rnode_graph_get_output(graph, a, 1) == a_color and raven.Rnode_graph_get_output(graph, a, 2) == 0, "Rnode_graph_get_output(graph, a, 0) == a_out && Rnode_graph_get_output(graph, a, 1) == a_color && Rnode_graph_get_output(graph, a, 2) == 0");
    t.CHECK(@src(), raven.Rnode_graph_get_input(graph, b, 1) == b_any and raven.Rnode_graph_get_input(graph, a, 0) == 0, "Rnode_graph_get_input(graph, b, 1) == b_any && Rnode_graph_get_input(graph, a, 0) == 0");
    t.CHECK(@src(), raven.Rnode_graph_get_pin_node(graph, b_any) == b, "Rnode_graph_get_pin_node(graph, b_any) == b");
    t.CHECK(@src(), raven.Rnode_graph_is_pin_output(graph, a_out) != 0 and raven.Rnode_graph_is_pin_output(graph, b_in) == 0, "Rnode_graph_is_pin_output(graph, a_out) && !Rnode_graph_is_pin_output(graph, b_in)");
    t.CHECK_STR(@src(), raven.Rnode_graph_get_pin_label(graph, a_color), "Col", "Rnode_graph_get_pin_label(graph, a_color)");
    t.CHECK_STR(@src(), raven.Rnode_graph_get_pin_type(graph, a_color), "color", "Rnode_graph_get_pin_type(graph, a_color)");
    t.CHECK_STR(@src(), raven.Rnode_graph_get_pin_type(graph, b_any), "", "Rnode_graph_get_pin_type(graph, b_any)");
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 1, "Rnode_graph_get_link_count(graph) == 1");
    const link = raven.Rnode_graph_get_link(graph, 0);
    t.CHECK(@src(), link != 0 and raven.Rnode_graph_get_link_output(graph, link) == a_out and raven.Rnode_graph_get_link_input(graph, link) == b_in, "link && Rnode_graph_get_link_output(graph, link) == a_out && Rnode_graph_get_link_input(graph, link) == b_in");
    t.CHECK(@src(), raven.Rnode_graph_get_input_link(graph, b_in) == link and raven.Rnode_graph_get_input_link(graph, c_in) == 0, "Rnode_graph_get_input_link(graph, b_in) == link && Rnode_graph_get_input_link(graph, c_in) == 0");
    const check = raven.Rnode_graph_get_node_content(graph, b);
    t.CHECK(@src(), check != raven.R_INVALID_ID and check == raven.Rwidget_find(window, "chk"), "check != R_INVALID_ID && check == Rwidget_find(window, \"chk\")");
    t.CHECK(@src(), raven.Rnode_graph_get_node_content(graph, a) == raven.R_INVALID_ID, "Rnode_graph_get_node_content(graph, a) == R_INVALID_ID");

    // the rules of linking: an output to an input of another node, of the same type or of any
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, a_color, b_in) == 0, "Rnode_graph_connect(graph, a_color, b_in) == 0");
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, b_in, a_out) == 0, "Rnode_graph_connect(graph, b_in, a_out) == 0");
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, a_out, b_in) == link, "Rnode_graph_connect(graph, a_out, b_in) == link");
    other = raven.Rnode_graph_connect(graph, a_out, c_in);
    t.CHECK(@src(), other != 0 and other != link and raven.Rnode_graph_get_link_count(graph) == 2, "other && other != link && Rnode_graph_get_link_count(graph) == 2");
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, a_color, b_any) != 0, "Rnode_graph_connect(graph, a_color, b_any) != 0");
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 3, "Rnode_graph_get_link_count(graph) == 3");
    // an input takes one link: a new one replaces it
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, a_out, b_any) != 0, "Rnode_graph_connect(graph, a_out, b_any) != 0");
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 3, "Rnode_graph_get_link_count(graph) == 3");
    t.CHECK(@src(), raven.Rnode_graph_get_link_output(graph, raven.Rnode_graph_get_input_link(graph, b_any)) == a_out, "Rnode_graph_get_link_output(graph, Rnode_graph_get_input_link(graph, b_any)) == a_out");
    raven.Rnode_graph_disconnect(graph, other);
    raven.Rnode_graph_disconnect(graph, raven.Rnode_graph_get_input_link(graph, b_any));
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 1 and raven.Rnode_graph_get_input_link(graph, c_in) == 0, "Rnode_graph_get_link_count(graph) == 1 && Rnode_graph_get_input_link(graph, c_in) == 0");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rnode_graph_connect(graph, a_out, 99999) == 0, "Rnode_graph_connect(graph, a_out, 99999) == 0");
    t.CHECK(@src(), raven.Rnode_graph_add_input(graph, 99999, "x", null) == 0, "Rnode_graph_add_input(graph, 99999, \"x\", NULL) == 0");
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");

    // sizes and places: the pins are on the edges of their node
    raven.Rnode_graph_get_node_size(graph, a, &w, &h);
    t.CHECK(@src(), w >= 140.0 and h > 60.0, "w >= 140.0f && h > 60.0f");
    raven.Rnode_graph_get_pin_position(graph, a_out, &px, &py);
    t.CHECK(@src(), px == 50.0 + w and py > 80.0 and py < 50.0 + h, "px == 50.0f + w && py > 80.0f && py < 50.0f + h");
    raven.Rnode_graph_get_pin_position(graph, b_in, &qx, &qy);
    t.CHECK(@src(), qx == 400.0 and qy > 110.0, "qx == 400.0f && qy > 110.0f");
    // until the view is moved, the corner of the canvas is the corner of the widget
    raven.Rnode_graph_get_view(graph, &x, &y, &zoom);
    t.CHECK(@src(), x == 450.0 and y == 300.0 and zoom == 1.0, "x == 450.0f && y == 300.0f && zoom == 1.0f");
    raven.Rnode_graph_to_canvas(graph, 120.0, 80.0, &x, &y);
    t.CHECK(@src(), x == 120.0 and y == 80.0, "x == 120.0f && y == 80.0f");

    raven.Rnode_graph_set_moved_callback(graph, on_graph, @ptrFromInt(@as(usize, @bitCast(@as(isize, 0)))));
    raven.Rnode_graph_set_selection_callback(graph, on_graph, @ptrFromInt(@as(usize, @bitCast(@as(isize, 1)))));
    raven.Rnode_graph_set_linked_callback(graph, on_graph, @ptrFromInt(@as(usize, @bitCast(@as(isize, 2)))));
    raven.Rnode_graph_set_unlinked_callback(graph, on_graph, @ptrFromInt(@as(usize, @bitCast(@as(isize, 3)))));
    @memset(&g_graph_calls, 0);

    // a node is dragged by its header
    drag(window, 420.0, 330.0, 520.0, 380.0);
    raven.Rnode_graph_get_node_position(graph, c, &px, &py);
    t.CHECK(@src(), px == 500.0 and py == 370.0, "px == 500.0f && py == 370.0f");
    t.CHECK(@src(), g_graph_calls[0] == 1 and g_graph_last[0] == c, "g_graph_calls[0] == 1 && g_graph_last[0] == c");
    t.CHECK(@src(), raven.Rnode_graph_is_node_selected(graph, c) != 0 and raven.Rnode_graph_get_selection_count(graph) == 1 and raven.Rnode_graph_get_selected_node(graph, 0) == c, "Rnode_graph_is_node_selected(graph, c) && Rnode_graph_get_selection_count(graph) == 1 && Rnode_graph_get_selected_node(graph, 0) == c");
    t.CHECK(@src(), g_graph_calls[1] == 1 and g_graph_last[1] == c, "g_graph_calls[1] == 1 && g_graph_last[1] == c");
    // Escape while dragging puts it back
    raven.Rwindow_inject_mouse_move(window, 520.0, 380.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(window, 560.0, 400.0);
    raven.Rwindow_inject_mouse_move(window, 600.0, 420.0);
    raven.Rnode_graph_get_node_position(graph, c, &px, &py);
    t.CHECK(@src(), px == 580.0 and py == 410.0, "px == 580.0f && py == 410.0f");
    press_key(window, raven.R_KEY_ESCAPE, 0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    raven.Rnode_graph_get_node_position(graph, c, &px, &py);
    t.CHECK(@src(), px == 500.0 and py == 370.0, "px == 500.0f && py == 370.0f");
    t.CHECK(@src(), g_graph_calls[0] == 1, "g_graph_calls[0] == 1");

    // a wire is pulled from an output to an input: the application is asked, then told
    raven.Rnode_graph_set_connect_callback(graph, on_connect, null);
    raven.Rnode_graph_get_pin_position(graph, a_out, &px, &py);
    raven.Rnode_graph_get_pin_position(graph, c_in, &qx, &qy);
    g_connect_allowed = 0;
    drag(window, px, py, qx, qy);
    t.CHECK(@src(), g_connect_calls == 1 and raven.Rnode_graph_get_input_link(graph, c_in) == 0 and g_graph_calls[2] == 0, "g_connect_calls == 1 && Rnode_graph_get_input_link(graph, c_in) == 0 && g_graph_calls[2] == 0");
    g_connect_allowed = 1;
    drag(window, px, py, qx, qy);
    other = raven.Rnode_graph_get_input_link(graph, c_in);
    t.CHECK(@src(), g_connect_calls == 2 and other != 0 and raven.Rnode_graph_get_link_output(graph, other) == a_out, "g_connect_calls == 2 && other != 0 && Rnode_graph_get_link_output(graph, other) == a_out");
    t.CHECK(@src(), g_graph_calls[2] == 1 and g_graph_last[2] == other, "g_graph_calls[2] == 1 && g_graph_last[2] == other");
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 2, "Rnode_graph_get_link_count(graph) == 2");
    // pulled the other way round, from the input, it is the same link
    raven.Rnode_graph_disconnect(graph, other);
    drag(window, qx, qy, px, py);
    other = raven.Rnode_graph_get_input_link(graph, c_in);
    t.CHECK(@src(), other != 0 and raven.Rnode_graph_get_link_output(graph, other) == a_out and g_graph_calls[2] == 2, "other != 0 && Rnode_graph_get_link_output(graph, other) == a_out && g_graph_calls[2] == 2");
    // a wire that does not fit goes nowhere: a color into a number
    {
        var cx: f32 = undefined;
        var cy: f32 = undefined;
        raven.Rnode_graph_get_pin_position(graph, a_color, &cx, &cy);
        raven.Rnode_graph_disconnect(graph, other);
        drag(window, cx, cy, qx, qy);
        t.CHECK(@src(), raven.Rnode_graph_get_input_link(graph, c_in) == 0 and g_graph_calls[2] == 2, "Rnode_graph_get_input_link(graph, c_in) == 0 && g_graph_calls[2] == 2");
        drag(window, px, py, qx, qy);
        other = raven.Rnode_graph_get_input_link(graph, c_in);
        t.CHECK(@src(), other != 0 and g_graph_calls[2] == 3, "other != 0 && g_graph_calls[2] == 3");
    }
    // dropped on the node itself, it finds a pin that fits
    raven.Rnode_graph_disconnect(graph, other);
    {
        var nx: f32 = undefined;
        var ny: f32 = undefined;
        var nw: f32 = undefined;
        var nh: f32 = undefined;
        raven.Rnode_graph_get_node_position(graph, c, &nx, &ny);
        raven.Rnode_graph_get_node_size(graph, c, &nw, &nh);
        drag(window, px, py, nx + nw * 0.5, ny + 12.0);
        other = raven.Rnode_graph_get_input_link(graph, c_in);
        t.CHECK(@src(), other != 0 and g_graph_calls[2] == 4, "other != 0 && g_graph_calls[2] == 4");
    }
    // taken by its end at the input and let go in the void, a link is removed
    drag(window, qx, qy, qx - 60.0, qy + 150.0);
    t.CHECK(@src(), raven.Rnode_graph_get_input_link(graph, c_in) == 0, "Rnode_graph_get_input_link(graph, c_in) == 0");
    t.CHECK(@src(), g_graph_calls[3] == 1 and g_graph_last[3] == other, "g_graph_calls[3] == 1 && g_graph_last[3] == other");
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 1, "Rnode_graph_get_link_count(graph) == 1");
    raven.Rnode_graph_set_connect_callback(graph, null, null);

    // selection: a click, Shift + click, a rectangle, the empty canvas
    click_at(window, 420.0, 92.0);
    t.CHECK(@src(), raven.Rnode_graph_is_node_selected(graph, b) != 0 and raven.Rnode_graph_get_selection_count(graph) == 1, "Rnode_graph_is_node_selected(graph, b) && Rnode_graph_get_selection_count(graph) == 1");
    raven.Rwindow_inject_mouse_move(window, 520.0, 380.0);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_SHIFT, raven.R_TRUE, raven.R_MOD_SHIFT);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    raven.Rwindow_inject_key(window, raven.R_KEY_LEFT_SHIFT, raven.R_FALSE, 0);
    t.CHECK(@src(), raven.Rnode_graph_get_selection_count(graph) == 2 and raven.Rnode_graph_is_node_selected(graph, c) != 0, "Rnode_graph_get_selection_count(graph) == 2 && Rnode_graph_is_node_selected(graph, c)");
    click_at(window, 800.0, 560.0);
    t.CHECK(@src(), raven.Rnode_graph_get_selection_count(graph) == 0, "Rnode_graph_get_selection_count(graph) == 0");
    drag(window, 20.0, 20.0, 880.0, 590.0);
    t.CHECK(@src(), raven.Rnode_graph_get_selection_count(graph) == 3, "Rnode_graph_get_selection_count(graph) == 3");
    raven.Rnode_graph_clear_selection(graph);
    raven.Rnode_graph_select_node(graph, a, raven.R_FALSE);
    raven.Rnode_graph_select_node(graph, b, raven.R_TRUE);
    t.CHECK(@src(), raven.Rnode_graph_get_selection_count(graph) == 2 and raven.Rnode_graph_is_node_selected(graph, c) == 0, "Rnode_graph_get_selection_count(graph) == 2 && !Rnode_graph_is_node_selected(graph, c)");
    raven.Rnode_graph_clear_selection(graph);

    // the widget inside a node works like any other
    raven.Rwidget_get_rect(check, &x, &y, &w, &h);
    t.CHECK(@src(), x > 400.0 and y > 110.0 and w > 20.0, "x > 400.0f && y > 110.0f && w > 20.0f");
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) == 0, "!Rcheckbox_is_checked(check)");
    click_at(window, x + 10.0, y + h * 0.5);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) != 0, "Rcheckbox_is_checked(check)");
    // ... also when the graph is seen smaller: the wheel zooms around the pointer
    px = x + 10.0;
    py = y + h * 0.5;
    raven.Rwindow_inject_mouse_move(window, px, py);
    raven.Rwindow_inject_mouse_wheel(window, 0.0, -1.0);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_get_view(graph, null, null, &zoom);
    t.CHECK_NEAR(@src(), zoom * 100.0, 80.0, "zoom * 100.0f");
    raven.Rnode_graph_to_canvas(graph, px, py, &qx, &qy);
    t.CHECK_NEAR(@src(), qx, px, "qx");
    t.CHECK_NEAR(@src(), qy, py, "qy");
    click_at(window, px, py);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) == 0, "!Rcheckbox_is_checked(check)");
    // a place of the canvas is elsewhere in the widget now, and the widget of the node with it
    raven.Rnode_graph_from_canvas(graph, 400.0, 80.0, &qx, &qy);
    t.CHECK(@src(), @abs(qx - 400.0) > 1.0 or @abs(qy - 80.0) > 1.0, "fabsf(qx - 400.0f) > 1.0f || fabsf(qy - 80.0f) > 1.0f");
    raven.Rnode_graph_from_canvas(graph, x + w - 4.0, y + h * 0.5, &qx, &qy);
    click_at(window, qx, qy);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) != 0, "Rcheckbox_is_checked(check)");
    // seen from far, the widgets inside the nodes let the node take the mouse
    raven.Rnode_graph_set_view(graph, 450.0, 300.0, 0.25);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_from_canvas(graph, x + 10.0, y + h * 0.5, &qx, &qy);
    click_at(window, qx, qy);
    t.CHECK(@src(), raven.Rcheckbox_is_checked(check) != 0, "Rcheckbox_is_checked(check)");
    t.CHECK(@src(), raven.Rnode_graph_is_node_selected(graph, b) != 0, "Rnode_graph_is_node_selected(graph, b)");

    // the view
    raven.Rnode_graph_set_view(graph, 100.0, 50.0, 2.0);
    raven.Rnode_graph_get_view(graph, &x, &y, &zoom);
    t.CHECK(@src(), x == 100.0 and y == 50.0 and zoom == 2.0, "x == 100.0f && y == 50.0f && zoom == 2.0f");
    raven.Rnode_graph_to_canvas(graph, 450.0, 300.0, &x, &y);
    t.CHECK_NEAR(@src(), x, 100.0, "x");
    t.CHECK_NEAR(@src(), y, 50.0, "y");
    raven.Rnode_graph_from_canvas(graph, 110.0, 50.0, &x, &y);
    t.CHECK_NEAR(@src(), x, 470.0, "x");
    t.CHECK_NEAR(@src(), y, 300.0, "y");
    t.EXPECT_ERRORS_BEGIN();
    raven.Rnode_graph_set_view(graph, 0.0, 0.0, 0.0);
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    raven.Rnode_graph_frame_all(graph);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_get_view(graph, &x, &y, &zoom);
    t.CHECK(@src(), zoom <= 1.0 and zoom >= 0.2, "zoom <= 1.0f && zoom >= 0.2f");
    {
        // every node is in sight
        var i: c_int = undefined;
        i = 0;
        while (i < raven.Rnode_graph_get_node_count(graph)) : (i += 1) {
            var nx: f32 = undefined;
            var ny: f32 = undefined;
            var nw: f32 = undefined;
            var nh: f32 = undefined;
            var sx: f32 = undefined;
            var sy: f32 = undefined;
            var ex: f32 = undefined;
            var ey: f32 = undefined;
            const node = raven.Rnode_graph_get_node(graph, i);
            raven.Rnode_graph_get_node_position(graph, node, &nx, &ny);
            raven.Rnode_graph_get_node_size(graph, node, &nw, &nh);
            raven.Rnode_graph_from_canvas(graph, nx, ny, &sx, &sy);
            raven.Rnode_graph_from_canvas(graph, nx + nw, ny + nh, &ex, &ey);
            t.CHECK(@src(), sx >= 0.0 and sy >= 0.0 and ex <= 900.0 and ey <= 600.0, "sx >= 0.0f && sy >= 0.0f && ex <= 900.0f && ey <= 600.0f");
        }
    }
    raven.Rnode_graph_set_grid_visible(graph, raven.R_FALSE);
    raven.Rnode_graph_set_flow_visible(graph, raven.R_TRUE);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_set_flow_visible(graph, raven.R_FALSE);

    // read only: looked at, not changed
    raven.Rnode_graph_set_view(graph, 450.0, 300.0, 1.0);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_set_read_only(graph, raven.R_TRUE);
    raven.Rnode_graph_get_node_position(graph, a, &px, &py);
    drag(window, px + 20.0, py + 12.0, px + 120.0, py + 60.0);
    raven.Rnode_graph_get_node_position(graph, a, &qx, &qy);
    t.CHECK(@src(), qx == px and qy == py, "qx == px && qy == py");
    raven.Rnode_graph_set_read_only(graph, raven.R_FALSE);

    // the Delete key: links go; nodes only when the application listens
    raven.Rnode_graph_clear_selection(graph);
    raven.Rnode_graph_select_node(graph, c, raven.R_FALSE);
    raven.Rwidget_focus(graph);
    press_key(window, raven.R_KEY_DELETE, 0);
    t.CHECK(@src(), raven.Rnode_graph_get_node_count(graph) == 3, "Rnode_graph_get_node_count(graph) == 3");
    raven.Rnode_graph_set_removed_callback(graph, on_graph, @ptrFromInt(@as(usize, @bitCast(@as(isize, 4)))));
    press_key(window, raven.R_KEY_DELETE, 0);
    t.CHECK(@src(), raven.Rnode_graph_get_node_count(graph) == 2 and g_graph_calls[4] == 1 and g_graph_last[4] == c, "Rnode_graph_get_node_count(graph) == 2 && g_graph_calls[4] == 1 && g_graph_last[4] == c");
    t.CHECK(@src(), raven.Rnode_graph_find_node(graph, "c") == 0, "Rnode_graph_find_node(graph, \"c\") == 0");
    // removing a node removes its pins, their links, and its widget
    t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 1, "Rnode_graph_get_link_count(graph) == 1");
    raven.Rnode_graph_remove_node(graph, b);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), raven.Rnode_graph_get_node_count(graph) == 1 and raven.Rnode_graph_get_link_count(graph) == 0, "Rnode_graph_get_node_count(graph) == 1 && Rnode_graph_get_link_count(graph) == 0");
    t.CHECK(@src(), raven.Rwidget_is_valid(check) == 0, "!Rwidget_is_valid(check)");

    // built by the application
    {
        const n1 = raven.Rnode_graph_add_node(graph, "One", 10.0, 10.0);
        const n2 = raven.Rnode_graph_add_node(graph, "Two", 300.0, 10.0);
        const out = raven.Rnode_graph_add_output(graph, n1, "Value", "number");
        const in = raven.Rnode_graph_add_input(graph, n2, "Value", "number");
        const slider = raven.Rwidget_create(raven.R_WIDGET_SLIDER);
        var label = raven.Rlabel_create("inside");
        // (int user = 5; is never written: a `const` here, its address handed out as the C `void*`)
        const user: c_int = 5;
        t.CHECK(@src(), n1 != 0 and n2 != 0 and out != 0 and in != 0, "n1 && n2 && out && in");
        t.CHECK(@src(), raven.Rnode_graph_connect(graph, out, in) != 0, "Rnode_graph_connect(graph, out, in) != 0");
        raven.Rnode_graph_set_node_title(graph, n1, "First");
        t.CHECK_STR(@src(), raven.Rnode_graph_get_node_title(graph, n1), "First", "Rnode_graph_get_node_title(graph, n1)");
        raven.Rnode_graph_set_node_name(graph, n1, "first");
        t.CHECK(@src(), raven.Rnode_graph_find_node(graph, "first") == n1, "Rnode_graph_find_node(graph, \"first\") == n1");
        raven.Rnode_graph_set_pin_name(graph, out, "v");
        t.CHECK(@src(), raven.Rnode_graph_find_pin(graph, n1, "v") == out and raven.Rnode_graph_find_pin(graph, n1, "Value") == 0, "Rnode_graph_find_pin(graph, n1, \"v\") == out && Rnode_graph_find_pin(graph, n1, \"Value\") == 0");
        raven.Rnode_graph_set_node_position(graph, n1, 20.0, 30.0);
        raven.Rnode_graph_get_node_position(graph, n1, &px, &py);
        t.CHECK(@src(), px == 20.0 and py == 30.0, "px == 20.0f && py == 30.0f");
        raven.Rnode_graph_set_node_color(graph, n1, 1.0, 0.5, 0.0);
        raven.Rnode_graph_set_type_color(graph, "number", 0.0, 0.5, 1.0);
        raven.Rnode_graph_set_node_user_data(graph, n1, @ptrCast(@constCast(&user)));
        t.CHECK(@src(), raven.Rnode_graph_get_node_user_data(graph, n1) == @as(?*anyopaque, @ptrCast(@constCast(&user))) and raven.Rnode_graph_get_node_user_data(graph, n2) == null, "Rnode_graph_get_node_user_data(graph, n1) == &user && Rnode_graph_get_node_user_data(graph, n2) == NULL");
        // a widget inside: it makes the node larger, and belongs to the graph
        raven.Rnode_graph_get_node_size(graph, n2, &w, &h);
        raven.Rnode_graph_set_node_content(graph, n2, slider);
        t.CHECK(@src(), raven.Rnode_graph_get_node_content(graph, n2) == slider, "Rnode_graph_get_node_content(graph, n2) == slider");
        raven.Rnode_graph_get_node_size(graph, n2, &qx, &qy);
        t.CHECK(@src(), qy > h + 10.0, "qy > h + 10.0f");
        _ = raven.Rdraw_frame();
        raven.Rnode_graph_set_node_content(graph, n2, label);
        _ = raven.Rdraw_frame();
        t.CHECK(@src(), raven.Rwidget_is_valid(slider) == 0 and raven.Rnode_graph_get_node_content(graph, n2) == label, "!Rwidget_is_valid(slider) && Rnode_graph_get_node_content(graph, n2) == label");
        raven.Rnode_graph_set_node_content(graph, n2, raven.R_INVALID_ID);
        _ = raven.Rdraw_frame();
        t.CHECK(@src(), raven.Rwidget_is_valid(label) == 0 and raven.Rnode_graph_get_node_content(graph, n2) == raven.R_INVALID_ID, "!Rwidget_is_valid(label) && Rnode_graph_get_node_content(graph, n2) == R_INVALID_ID");
        // widgets only get in through the nodes
        label = raven.Rlabel_create("stray");
        t.EXPECT_ERRORS_BEGIN();
        _ = raven.Rwidget_add_child(graph, label);
        t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
        raven.Rwidget_destroy(label);
        raven.Rnode_graph_remove_pin(graph, out);
        t.CHECK(@src(), raven.Rnode_graph_get_link_count(graph) == 0 and raven.Rnode_graph_get_output(graph, n1, 0) == 0, "Rnode_graph_get_link_count(graph) == 0 && Rnode_graph_get_output(graph, n1, 0) == 0");
        raven.Rnode_graph_clear(graph);
        t.CHECK(@src(), raven.Rnode_graph_get_node_count(graph) == 0, "Rnode_graph_get_node_count(graph) == 0");
    }
    _ = raven.Rdraw_frame();
    raven.Rshutdown();
}

// A slider inside a node, dragged while the graph is seen at half its size, then larger than life.
fn test_zoomed_content() void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var x0: f32 = undefined;
    var y0: f32 = undefined;
    var x1: f32 = undefined;
    var y1: f32 = undefined;

    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");
    const window = make_window("<Window Width=\"900\" Height=\"600\"><NodeGraph Name=\"g\">" ++
        "<Node Name=\"n\" Title=\"Node\" X=\"200\" Y=\"150\"><Slider Name=\"s\" Width=\"200\" Value=\"0\"/>" ++
        "<ComboBox Name=\"c\" Items=\"One|Two|Three\" Selected=\"0\"/></Node></NodeGraph></Window>");
    const graph = raven.Rwidget_find(window, "g");
    const slider = raven.Rwidget_find(window, "s");
    const combo = raven.Rwidget_find(window, "c");
    const node = raven.Rnode_graph_find_node(graph, "n");
    t.CHECK(@src(), slider != raven.R_INVALID_ID and combo != raven.R_INVALID_ID and node != 0, "slider != R_INVALID_ID && combo != R_INVALID_ID && node != 0");
    // (until the view moves, the canvas and the widget are the same space)
    raven.Rwidget_get_rect(slider, &x, &y, &w, &h);
    t.CHECK(@src(), x > 200.0 and y > 180.0, "x > 200.0f && y > 180.0f");
    t.CHECK_NEAR(@src(), w, 200.0, "w");
    t.CHECK(@src(), raven.Rslider_get_value(slider) == 0.0, "Rslider_get_value(slider) == 0.0f");

    raven.Rnode_graph_set_view(graph, 300.0, 200.0, 0.5);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_from_canvas(graph, x, y + h * 0.5, &x0, &y0);
    raven.Rnode_graph_from_canvas(graph, x + w, y + h * 0.5, &x1, &y1);
    // half the size on screen
    t.CHECK_NEAR(@src(), x1 - x0, 100.0, "x1 - x0");
    drag(window, x0 + 2.0, y0, (x0 + x1) * 0.5, y0);
    t.CHECK(@src(), raven.Rslider_get_value(slider) > 0.42 and raven.Rslider_get_value(slider) < 0.58, "Rslider_get_value(slider) > 0.42f && Rslider_get_value(slider) < 0.58f");
    // the node itself did not move: the slider took the mouse
    {
        var nx: f32 = undefined;
        var ny: f32 = undefined;
        raven.Rnode_graph_get_node_position(graph, node, &nx, &ny);
        t.CHECK(@src(), nx == 200.0 and ny == 150.0, "nx == 200.0f && ny == 150.0f");
    }
    drag(window, (x0 + x1) * 0.5, y0, x1 + 40.0, y0);
    t.CHECK(@src(), raven.Rslider_get_value(slider) == 1.0, "Rslider_get_value(slider) == 1.0f");

    raven.Rnode_graph_set_view(graph, 300.0, 200.0, 2.0);
    _ = raven.Rdraw_frame();
    raven.Rnode_graph_from_canvas(graph, x, y + h * 0.5, &x0, &y0);
    raven.Rnode_graph_from_canvas(graph, x + w, y + h * 0.5, &x1, &y1);
    t.CHECK_NEAR(@src(), x1 - x0, 400.0, "x1 - x0");
    drag(window, x1 - 4.0, y0, x0 + (x1 - x0) * 0.25, y0);
    t.CHECK(@src(), raven.Rslider_get_value(slider) > 0.2 and raven.Rslider_get_value(slider) < 0.3, "Rslider_get_value(slider) > 0.2f && Rslider_get_value(slider) < 0.3f");

    // a list that drops down from a widget of a zoomed node opens where the widget shows, and its rows work
    {
        var cx: f32 = undefined;
        var cy: f32 = undefined;
        // where the combo box is on the canvas: read at life size
        raven.Rnode_graph_set_view(graph, 300.0, 200.0, 1.0);
        _ = raven.Rdraw_frame();
        raven.Rwidget_get_rect(combo, &x, &y, &w, &h);
        raven.Rnode_graph_to_canvas(graph, x + w * 0.5, y + h * 0.5, &cx, &cy);
        raven.Rnode_graph_set_view(graph, 300.0, 200.0, 0.5);
        _ = raven.Rdraw_frame();
        raven.Rnode_graph_from_canvas(graph, cx, cy, &x0, &y0);
        click_at(window, x0, y0);
        _ = raven.Rdraw_frame();
        // the second row: under the button as it shows (half its height), one row and a half further; popups are not zoomed
        click_at(window, x0, y0 + h * 0.25 + 2.0 + raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT) * 1.5);
        _ = raven.Rdraw_frame();
        t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 1, "Rcombo_box_get_selected(combo) == 1");
    }
    raven.Rshutdown();
}

// ---------------------------------------------------------------------------
//  Background blur, windows that are seen through
// ---------------------------------------------------------------------------

fn test_blur_and_transparency() void {
    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");

    const window = make_window("<Window Width=\"400\" Height=\"300\" Transparent=\"true\" Backdrop=\"Blur\">" ++
        "<BackgroundBlur Name=\"b\" Style=\"Native\" Radius=\"12\" Tint=\"#00000040\" Padding=\"8\" CornerRadius=\"10\" Grain=\"0.3\" Saturation=\"1.4\" Shadow=\"16\">" ++
        "<Label Name=\"l\" Text=\"over the desktop\"/></BackgroundBlur></Window>");
    var blur = raven.Rwidget_find(window, "b");
    const label = raven.Rwidget_find(window, "l");
    t.CHECK(@src(), blur != raven.R_INVALID_ID and raven.Rwidget_get_type(blur) == raven.R_WIDGET_BACKGROUND_BLUR, "blur != R_INVALID_ID && Rwidget_get_type(blur) == R_WIDGET_BACKGROUND_BLUR");
    t.CHECK(@src(), raven.Rbackground_blur_get_style(blur) == raven.R_BLUR_NATIVE, "Rbackground_blur_get_style(blur) == R_BLUR_NATIVE");
    t.CHECK(@src(), raven.Rbackground_blur_get_radius(blur) == 12.0, "Rbackground_blur_get_radius(blur) == 12.0f");
    t.CHECK_RECT(@src(), blur, 0.0, 0.0, 400.0, 300.0, "blur");
    t.CHECK_RECT(@src(), label, 8.0, 8.0, 384.0, 284.0, "label");
    // the window is seen through, and the system blurs what is behind
    t.CHECK(@src(), raven.Rwindow_get_backdrop(window) == raven.R_BACKDROP_BLUR, "Rwindow_get_backdrop(window) == R_BACKDROP_BLUR");
    t.CHECK(@src(), raven.Rwindow_set_backdrop(window, raven.R_BACKDROP_ACRYLIC) != 0, "Rwindow_set_backdrop(window, R_BACKDROP_ACRYLIC)");
    t.CHECK(@src(), raven.Rwindow_get_backdrop(window) == raven.R_BACKDROP_ACRYLIC, "Rwindow_get_backdrop(window) == R_BACKDROP_ACRYLIC");
    t.CHECK(@src(), raven.Rwindow_set_backdrop(window, raven.R_BACKDROP_TRANSPARENT) != 0, "Rwindow_set_backdrop(window, R_BACKDROP_TRANSPARENT)");
    t.CHECK(@src(), raven.Rwindow_get_backdrop(window) == raven.R_BACKDROP_TRANSPARENT, "Rwindow_get_backdrop(window) == R_BACKDROP_TRANSPARENT");
    t.CHECK(@src(), raven.Rwindow_get_opacity(window) == 1.0, "Rwindow_get_opacity(window) == 1.0f");
    t.CHECK(@src(), raven.Rwindow_set_opacity(window, 0.5) != 0, "Rwindow_set_opacity(window, 0.5f)");
    t.CHECK(@src(), raven.Rwindow_get_opacity(window) == 0.5, "Rwindow_get_opacity(window) == 0.5f");
    _ = raven.Rwindow_set_opacity(window, 7.0);
    t.CHECK(@src(), raven.Rwindow_get_opacity(window) == 1.0, "Rwindow_get_opacity(window) == 1.0f");

    // each style paints
    raven.Rbackground_blur_set_style(blur, raven.R_BLUR_PLAIN);
    _ = raven.Rdraw_frame();
    raven.Rbackground_blur_set_style(blur, raven.R_BLUR_FROSTED);
    _ = raven.Rdraw_frame();
    raven.Rbackground_blur_set_style(blur, raven.R_BLUR_GLASS);
    t.CHECK(@src(), raven.Rbackground_blur_get_style(blur) == raven.R_BLUR_GLASS, "Rbackground_blur_get_style(blur) == R_BLUR_GLASS");
    _ = raven.Rdraw_frame();
    raven.Rbackground_blur_set_radius(blur, 30.0);
    t.CHECK(@src(), raven.Rbackground_blur_get_radius(blur) == 30.0, "Rbackground_blur_get_radius(blur) == 30.0f");
    raven.Rbackground_blur_set_tint(blur, 1.0, 1.0, 1.0, 0.2);
    raven.Rbackground_blur_clear_tint(blur);
    raven.Rbackground_blur_set_saturation(blur, 1.0);
    raven.Rbackground_blur_set_grain(blur, 0.0);
    raven.Rbackground_blur_set_corner_radius(blur, 4.0, 8.0, 12.0, 16.0);
    raven.Rbackground_blur_set_padding(blur, 1.0, 2.0, 3.0, 4.0);
    raven.Rbackground_blur_set_shadow(blur, 0.0);
    _ = raven.Rdraw_frame();
    t.CHECK_RECT(@src(), label, 1.0, 2.0, 396.0, 294.0, "label");
    t.CHECK(@src(), raven.Rwidget_set_attribute(blur, "Style", "Frosted") != 0 and raven.Rbackground_blur_get_style(blur) == raven.R_BLUR_FROSTED, "Rwidget_set_attribute(blur, \"Style\", \"Frosted\") && Rbackground_blur_get_style(blur) == R_BLUR_FROSTED");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwidget_set_attribute(blur, "Style", "Smoked") == 0, "!Rwidget_set_attribute(blur, \"Style\", \"Smoked\")");
    t.EXPECT_ERRORS_END(@src(), 0, "g_test_errors >= (0)");

    // an ordinary window is not seen through, and says so
    var plain = raven.Rwindow_create("plain", 300, 200, 0);
    t.CHECK(@src(), raven.Rwindow_get_backdrop(plain) == raven.R_BACKDROP_NONE, "Rwindow_get_backdrop(plain) == R_BACKDROP_NONE");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwindow_set_backdrop(plain, raven.R_BACKDROP_BLUR) == 0, "!Rwindow_set_backdrop(plain, R_BACKDROP_BLUR)");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    t.CHECK(@src(), raven.Rwindow_get_backdrop(plain) == raven.R_BACKDROP_NONE, "Rwindow_get_backdrop(plain) == R_BACKDROP_NONE");
    // asked for from code, with the flag
    raven.Rwindow_destroy(plain);
    plain = raven.Rwindow_create("clear", 300, 200, raven.R_WINDOW_TRANSPARENT);
    t.CHECK(@src(), raven.Rwindow_get_backdrop(plain) == raven.R_BACKDROP_TRANSPARENT, "Rwindow_get_backdrop(plain) == R_BACKDROP_TRANSPARENT");
    blur = raven.Rbackground_blur_create();
    raven.Rwindow_set_content(plain, blur);
    t.CHECK(@src(), raven.Rbackground_blur_get_style(blur) == raven.R_BLUR_FROSTED, "Rbackground_blur_get_style(blur) == R_BLUR_FROSTED");
    _ = raven.Rdraw_frame();
    raven.Rshutdown();
}

// ---------------------------------------------------------------------------
//  What other libraries build on
// ---------------------------------------------------------------------------

var g_gauge_created: c_int = 0;
var g_gauge_level: [32]u8 = std.mem.zeroes([32]u8);
fn tag_create(tag: [*c]const u8, user_data: ?*anyopaque) callconv(.c) raven.Rid {
    t.CHECK_STR(@src(), tag, "Gauge", "tag");
    t.CHECK(@src(), user_data == @as(?*anyopaque, @ptrCast(&g_gauge_level)), "user_data == (void*)g_gauge_level");
    g_gauge_created += 1;
    return raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
}

fn tag_attribute(widget: raven.Rid, name: [*c]const u8, value: [*c]const u8, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    _ = user_data;
    if (t.strcmp(name, "Level") != 0) return raven.R_FALSE;
    _ = t.snprintf(&g_gauge_level, g_gauge_level.len, "%s", value);
    return raven.R_TRUE;
}

var g_destroyed: c_int = 0;
fn on_destroyed(widget: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const amount_ptr: [*c]c_int = @ptrCast(@alignCast(user_data));
    g_destroyed += amount_ptr.*;
}

var g_curve_painted: c_int = 0;
fn paint_curve(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = user_data;
    raven.Rdraw_curve(painter, 0.0, 0.0, width * 0.5, 0.0, width * 0.5, height, width, height, 3.0, 1.0, 0.5, 0.0, 1.0);
    g_curve_painted += 1;
}

fn test_hooks() void {
    const xml = "<VBox><Gauge Name=\"g\" Level=\"0.7\" Width=\"50\" Height=\"20\"/><Label Text=\"after\"/></VBox>";
    var custom: raven.Rid = undefined;
    // (int amount = 3; is never written: a `const` here, its address handed out as the C `void*`)
    const amount: c_int = 3;

    t.CHECK(@src(), t.test_init(0) != 0, "test_init(0)");

    // a tag made by code
    t.CHECK(@src(), raven.Rxml_is_tag_registered("Gauge") == 0, "!Rxml_is_tag_registered(\"Gauge\")");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwidget_create_from_xml(xml, t.strlen(xml)) == raven.R_INVALID_ID, "Rwidget_create_from_xml(xml, strlen(xml)) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rxml_register_tag("Button", tag_create, null, null) == 0, "!Rxml_register_tag(\"Button\", tag_create, NULL, NULL)");
    t.CHECK(@src(), raven.Rxml_register_tag("Gauge", null, null, null) == 0, "!Rxml_register_tag(\"Gauge\", NULL, NULL, NULL)");
    t.EXPECT_ERRORS_END(@src(), 3, "g_test_errors >= (3)");
    t.CHECK(@src(), raven.Rxml_register_tag("Gauge", tag_create, tag_attribute, &g_gauge_level) != 0, "Rxml_register_tag(\"Gauge\", tag_create, tag_attribute, g_gauge_level)");
    t.CHECK(@src(), raven.Rxml_is_tag_registered("gauge") != 0, "Rxml_is_tag_registered(\"gauge\")");
    const tree = raven.Rwidget_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), tree != raven.R_INVALID_ID and g_gauge_created == 1, "tree != R_INVALID_ID && g_gauge_created == 1");
    const gauge = raven.Rwidget_find(tree, "g");
    t.CHECK(@src(), gauge != raven.R_INVALID_ID and raven.Rwidget_get_type(gauge) == raven.R_WIDGET_CUSTOM, "gauge != R_INVALID_ID && Rwidget_get_type(gauge) == R_WIDGET_CUSTOM");
    t.CHECK(@src(), raven.Rwidget_get_child(tree, 0) == gauge and raven.Rwidget_get_child_count(tree) == 2, "Rwidget_get_child(tree, 0) == gauge && Rwidget_get_child_count(tree) == 2");
    // its own attribute went to its function, the others to the widget
    t.CHECK_STR(@src(), &g_gauge_level, "0.7", "g_gauge_level");
    t.CHECK(@src(), raven.Rwidget_set_attribute(gauge, "Level", "0.2") != 0, "Rwidget_set_attribute(gauge, \"Level\", \"0.2\")");
    t.CHECK_STR(@src(), &g_gauge_level, "0.2", "g_gauge_level");
    t.CHECK(@src(), raven.Rwidget_set_attribute(gauge, "Opacity", "0.5") != 0, "Rwidget_set_attribute(gauge, \"Opacity\", \"0.5\")");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwidget_set_attribute(gauge, "Unknown", "1") == 0, "!Rwidget_set_attribute(gauge, \"Unknown\", \"1\")");
    t.EXPECT_ERRORS_END(@src(), 0, "g_test_errors >= (0)");
    // the widgets of Raven do not hear about it
    t.CHECK(@src(), raven.Rwidget_set_attribute(raven.Rwidget_get_child(tree, 1), "Level", "1") == 0, "!Rwidget_set_attribute(Rwidget_get_child(tree, 1), \"Level\", \"1\")");
    t.CHECK_STR(@src(), &g_gauge_level, "0.2", "g_gauge_level");
    // a widget outlives its tag
    raven.Rxml_unregister_tag("Gauge");
    t.CHECK(@src(), raven.Rxml_is_tag_registered("Gauge") == 0, "!Rxml_is_tag_registered(\"Gauge\")");
    t.CHECK(@src(), raven.Rwidget_set_attribute(gauge, "Level", "0.9") == 0, "!Rwidget_set_attribute(gauge, \"Level\", \"0.9\")");
    t.CHECK_STR(@src(), &g_gauge_level, "0.2", "g_gauge_level");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwidget_create_from_xml(xml, t.strlen(xml)) == raven.R_INVALID_ID, "Rwidget_create_from_xml(xml, strlen(xml)) == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");

    // told when a widget is gone: with its parent, once
    raven.Rwidget_set_destroy_callback(gauge, on_destroyed, @ptrCast(@constCast(&amount)));
    raven.Rwidget_destroy(tree);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_destroyed == 3, "g_destroyed == 3");
    custom = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rwidget_set_destroy_callback(custom, on_destroyed, @ptrCast(@constCast(&amount)));
    raven.Rwidget_set_destroy_callback(custom, null, null);
    raven.Rwidget_destroy(custom);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_destroyed == 3, "g_destroyed == 3");
    // ... also when Rshutdown is what deletes it (checked below)
    custom = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rwidget_set_destroy_callback(custom, on_destroyed, @ptrCast(@constCast(&amount)));

    // files named in documents
    raven.Rxml_set_base_path("/somewhere/ui");
    t.CHECK_STR(@src(), raven.Rxml_resolve_path("pages/a.html"), "/somewhere/ui/pages/a.html", "Rxml_resolve_path(\"pages/a.html\")");
    raven.Rxml_set_base_path(null);

    // a picture decoded without making a texture: a 2 x 2 bitmap, bottom row first, blue green red
    {
        const bmp = [_]u8{
            'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
            40,  0,   0,  0, 2, 0, 0, 0, 2, 0, 0,  0, 1, 0, 24, 0, 0, 0, 0, 0, 16, 0, 0, 0, 19, 11, 0, 0, 19, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            255, 0,   0,  0, 255, 0, 0, 0,
            0,   0,   255, 255, 255, 255, 0, 0,
        };
        var width: c_int = 0;
        var height: c_int = 0;
        const pixels: [*c]u8 = raven.Rimage_decode(&bmp, bmp.len, &width, &height);
        if (test_config.no_image_decoder) {
            t.CHECK(@src(), pixels == null and width == 0 and height == 0, "pixels == NULL && width == 0 && height == 0");
        } else {
            t.CHECK(@src(), pixels != null and width == 2 and height == 2, "pixels != NULL && width == 2 && height == 2");
            if (pixels != null) {
                // top left is red, top right white, bottom left blue, bottom right green; all opaque
                t.CHECK(@src(), pixels[0] == 255 and pixels[1] == 0 and pixels[2] == 0 and pixels[3] == 255, "pixels[0] == 255 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255");
                t.CHECK(@src(), pixels[4] == 255 and pixels[5] == 255 and pixels[6] == 255, "pixels[4] == 255 && pixels[5] == 255 && pixels[6] == 255");
                t.CHECK(@src(), pixels[8] == 0 and pixels[9] == 0 and pixels[10] == 255, "pixels[8] == 0 && pixels[9] == 0 && pixels[10] == 255");
                t.CHECK(@src(), pixels[12] == 0 and pixels[13] == 255 and pixels[14] == 0, "pixels[12] == 0 && pixels[13] == 255 && pixels[14] == 0");
            }
            raven.Rpixels_free(pixels);
        }
        t.CHECK(@src(), raven.Rimage_decode("not an image", 12, &width, &height) == null and width == 0, "Rimage_decode(\"not an image\", 12, &width, &height) == NULL && width == 0");
        t.CHECK(@src(), raven.Rimage_decode(null, 0, null, null) == null, "Rimage_decode(NULL, 0, NULL, NULL) == NULL");
    }

    // a curve drawn by a custom widget
    const window = raven.Rwindow_create("curve", 200, 100, 0);
    custom = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rcustom_set_paint_callback(custom, paint_curve, null);
    raven.Rwindow_set_content(window, custom);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_curve_painted >= 1, "g_curve_painted >= 1");

    raven.Rshutdown();
    t.CHECK(@src(), g_destroyed == 6, "g_destroyed == 6");
}

export fn main() c_int {
    t.RUN(test_color_picker, "test_color_picker");
    t.RUN(test_timeline, "test_timeline");
    t.RUN(test_node_graph, "test_node_graph");
    t.RUN(test_zoomed_content, "test_zoomed_content");
    t.RUN(test_blur_and_transparency, "test_blur_and_transparency");
    t.RUN(test_hooks, "test_hooks");
    return t.test_report("test_tools");
}
