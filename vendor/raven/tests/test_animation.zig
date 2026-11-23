// Translated to Zig from vendor/raven/tests/test_animation.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - springs, transitions and the animations of the layout.
// Time is under control: every frame advances the animations by 1/60 s.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

var g_spring: raven.RSpring = std.mem.zeroes(raven.RSpring);
var g_target: f32 = 0;
var g_motion: raven.RMotion = raven.R_MOTION_BOUNCY;
var g_value: f32 = 0;
var g_highest: f32 = 0;
var g_lowest: f32 = 0;
var g_paints: c_int = 0;

fn paint_spring(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = width;
    _ = height;
    _ = user_data;
    g_value = raven.Rdraw_spring(painter, &g_spring, g_target, g_motion);
    if (g_value > g_highest) g_highest = g_value;
    if (g_value < g_lowest) g_lowest = g_value;
    g_paints += 1;
}

fn window_from(xml: [*c]const u8) raven.Rid {
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    return window;
}

/// Frames until the window has nothing left to animate (it stops asking for frames).
fn run_until_still(window: raven.Rid, limit: c_int) c_int {
    var frames: c_int = 0;
    var quiet: c_int = 0;
    while (frames < limit and quiet < 3) {
        const before = g_paints;
        var a: raven.RFrameStats = undefined;
        var b: raven.RFrameStats = undefined;
        raven.Rwindow_get_frame_stats(window, &a);
        _ = raven.Rdraw_frame();
        raven.Rwindow_get_frame_stats(window, &b);
        // a window at rest is not painted again
        if (b.frame_index == a.frame_index and g_paints == before) quiet += 1 else quiet = 0;
        frames += 1;
    }
    return frames - quiet;
}

fn test_springs() void {
    const window = window_from("<Window Width=\"200\" Height=\"100\"><Custom Name=\"c\"/></Window>");
    var frames: c_int = undefined;
    raven.Rcustom_set_paint_callback(raven.Rwidget_find(window, "c"), paint_spring, null);

    // the first paint puts the spring on its target: what is already there does not animate
    g_target = 0.0;
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_value == 0.0, "g_value == 0.0f");
    t.CHECK(@src(), run_until_still(window, 20) <= 1, "run_until_still(window, 20) <= 1");

    // a bouncy spring runs past its target, comes back, and stops exactly on it
    g_target = 1.0;
    g_highest = 0.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_value > 0.0 and g_value < 0.5, "g_value > 0.0f && g_value < 0.5f");
    frames = run_until_still(window, 600);
    t.CHECK(@src(), g_value == 1.0, "g_value == 1.0f");
    t.CHECK(@src(), g_highest > 1.05 and g_highest < 1.4, "g_highest > 1.05f && g_highest < 1.4f");
    // about 0.38 s of response: settled in a fraction of a second, not instantly
    t.CHECK(@src(), frames > 15 and frames < 120, "frames > 15 && frames < 120");
    _ = t.printf("  bouncy: peak %.3f, at rest after %d frames\n", @as(f64, g_highest), frames);

    // a smooth spring never passes its target
    g_motion = raven.R_MOTION_SMOOTH;
    g_target = 0.0;
    g_lowest = 1.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    frames = run_until_still(window, 600);
    t.CHECK(@src(), g_value == 0.0, "g_value == 0.0f");
    t.CHECK(@src(), g_lowest >= -0.001, "g_lowest >= -0.001f");
    t.CHECK(@src(), frames > 10 and frames < 120, "frames > 10 && frames < 120");

    // a kick sends it away from its target and it comes back
    raven.Rspring_kick(&g_spring, 20.0);
    g_highest = 0.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    frames = run_until_still(window, 600);
    t.CHECK(@src(), g_highest > 0.2, "g_highest > 0.2f");
    t.CHECK(@src(), g_value == 0.0, "g_value == 0.0f");

    // without animations, the value is the target at once
    raven.Rset_animations_enabled(raven.R_FALSE);
    t.CHECK(@src(), raven.Rget_animations_enabled() == 0, "!Rget_animations_enabled()");
    g_target = 5.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), g_value == 5.0, "g_value == 5.0f");
    raven.Rset_animations_enabled(raven.R_TRUE);

    // twice as fast: about half the frames
    g_motion = raven.R_MOTION_BOUNCY;
    g_target = 0.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    frames = run_until_still(window, 600);
    raven.Rset_animation_speed(2.0);
    g_target = 5.0;
    raven.Rwidget_invalidate(raven.Rwidget_find(window, "c"));
    t.CHECK(@src(), run_until_still(window, 600) < @divTrunc(frames * 3, 4), "run_until_still(window, 600) < frames * 3 / 4");
    raven.Rset_animation_speed(1.0);
    t.EXPECT_ERRORS_BEGIN();
    raven.Rset_animation_speed(0.0);
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");

    raven.Rwindow_destroy(window);
}

fn test_layout_animation() void {
    const window = window_from(
        "<Window Width=\"300\" Height=\"400\"><VBox>" ++
            "  <Expander Name=\"e\" Title=\"Section\" Expanded=\"false\"><Border Height=\"100\"/></Expander>" ++
            "  <Border Name=\"below\" Height=\"20\"/>" ++
            "</VBox></Window>",
    );
    const expander = raven.Rwidget_find(window, "e");
    const below = raven.Rwidget_find(window, "below");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var closed_y: f32 = undefined;
    var highest: f32 = 0.0;
    var frames: c_int = 0;
    var between: c_int = 0;

    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(below, &x, &closed_y, &w, &h);

    // opening: what is below moves down frame after frame, goes a little too far, and settles 100 units lower
    raven.Rexpander_set_expanded(expander, raven.R_TRUE);
    t.CHECK(@src(), raven.Rexpander_is_expanded(expander) != 0, "Rexpander_is_expanded(expander)");
    frames = 0;
    while (frames < 300) : (frames += 1) {
        _ = raven.Rdraw_frame();
        raven.Rwidget_get_rect(below, &x, &y, &w, &h);
        if (y > highest) highest = y;
        if (y > closed_y + 5.0 and y < closed_y + 95.0) between += 1;
    }
    t.CHECK_NEAR(@src(), y, closed_y + 100.0, "y");
    t.CHECK(@src(), between >= 3, "between >= 3");
    t.CHECK(@src(), highest > closed_y + 101.0, "highest > closed_y + 101.0f");

    // closing: back where it was, and the content takes no input once it is closed
    raven.Rexpander_set_expanded(expander, raven.R_FALSE);
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(below, &x, &y, &w, &h);
    t.CHECK(@src(), y < closed_y + 100.0 and y > closed_y, "y < closed_y + 100.0f && y > closed_y");
    frames = 0;
    while (frames < 300) : (frames += 1) _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(below, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), y, closed_y, "y");

    // a widget destroyed in the middle of its animation is forgotten
    raven.Rexpander_set_expanded(expander, raven.R_TRUE);
    _ = raven.Rdraw_frame();
    raven.Rwidget_destroy(expander);
    frames = 0;
    while (frames < 10) : (frames += 1) _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(below, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), y, 0.0, "y");

    raven.Rwindow_destroy(window);
}

fn test_transitions() void {
    const window = window_from(
        "<Window Width=\"300\" Height=\"200\"><VBox>" ++
            "  <Label Name=\"a\" Appear=\"FlyUp\">First</Label>" ++
            "  <Label Name=\"b\" Appear=\"Pop\" AppearDelay=\"0.2\">Second</Label>" ++
            "  <Custom Name=\"c\" Height=\"10\"/>" ++
            "</VBox></Window>",
    );
    const a = raven.Rwidget_find(window, "a");
    var stats: raven.RFrameStats = undefined;
    var frames: c_int = undefined;

    g_target = 0.0;
    raven.Rspring_set(&g_spring, 0.0);
    raven.Rcustom_set_paint_callback(raven.Rwidget_find(window, "c"), paint_spring, null);

    // the second label waits 0.2 s: it draws nothing during the first frames
    _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &stats);
    // (relative counts: the free edition adds its watermark to every frame)
    const first: raven.Ruint = stats.instance_count;
    t.CHECK(@src(), first >= 5, "first >= 5");
    // both arrive, then the window is still
    frames = run_until_still(window, 600);
    t.CHECK(@src(), frames > 20 and frames < 200, "frames > 20 && frames < 200");
    raven.Rwindow_get_frame_stats(window, &stats);
    const all: raven.Ruint = stats.instance_count;
    t.CHECK(@src(), all > first, "all > first");

    // the layout never moved: a transition only changes what is drawn
    t.CHECK_RECT(@src(), a, 0, 0, 300, 18, "a");

    // hidden and shown again: it plays again
    raven.Rwidget_set_visibility(a, raven.R_HIDDEN);
    _ = raven.Rdraw_frame();
    raven.Rwidget_set_visibility(a, raven.R_VISIBLE);
    frames = run_until_still(window, 600);
    t.CHECK(@src(), frames > 10, "frames > 10");

    // played by hand, with a delay
    raven.Rwidget_play_transition(a, raven.R_TRANSITION_DROP, 0.1);
    _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &stats);
    t.CHECK(@src(), stats.instance_count < all, "stats.instance_count < all");
    frames = run_until_still(window, 600);
    t.CHECK(@src(), frames > 10, "frames > 10");
    raven.Rwindow_get_frame_stats(window, &stats);
    t.CHECK(@src(), stats.instance_count == all, "stats.instance_count == all");

    // removed: nothing plays any more
    raven.Rwidget_set_transition(a, raven.R_TRANSITION_NONE, 0.0);
    raven.Rwidget_set_visibility(a, raven.R_HIDDEN);
    _ = raven.Rdraw_frame();
    raven.Rwidget_set_visibility(a, raven.R_VISIBLE);
    t.CHECK(@src(), run_until_still(window, 600) <= 2, "run_until_still(window, 600) <= 2");

    t.EXPECT_ERRORS_BEGIN();
    raven.Rwidget_set_transition(a, @as(raven.RTransition, 12345), 0.0);
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");

    raven.Rwindow_destroy(window);
}

fn test_popups() void {
    const window = window_from(
        "<Window Width=\"300\" Height=\"200\"><VBox>" ++
            "  <ComboBox Name=\"combo\" Selected=\"0\"><Item Text=\"One\"/><Item Text=\"Two\"/><Item Text=\"Three\"/></ComboBox>" ++
            "</VBox></Window>",
    );
    const combo = raven.Rwidget_find(window, "combo");
    var menu: raven.Rid = undefined;
    var closed: raven.RFrameStats = undefined;
    var open: raven.RFrameStats = undefined;
    var stats: raven.RFrameStats = undefined;
    var frames: c_int = undefined;

    frames = 0;
    while (frames < 60) : (frames += 1) _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &closed);

    // open: the list grows out of the box, then everything is still
    t.test_click(window, combo);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), run_until_still(window, 600) > 5, "run_until_still(window, 600) > 5");
    raven.Rwindow_get_frame_stats(window, &open);
    t.CHECK(@src(), open.instance_count > closed.instance_count, "open.instance_count > closed.instance_count");

    // picked: the choice is made at once, the list is still drawn while it shrinks, then it is gone
    raven.Rwindow_inject_key(window, raven.R_KEY_DOWN, raven.R_TRUE, 0);
    raven.Rwindow_inject_key(window, raven.R_KEY_DOWN, raven.R_FALSE, 0);
    raven.Rwindow_inject_key(window, raven.R_KEY_ENTER, raven.R_TRUE, 0);
    raven.Rwindow_inject_key(window, raven.R_KEY_ENTER, raven.R_FALSE, 0);
    t.CHECK(@src(), raven.Rcombo_box_get_selected(combo) == 1, "Rcombo_box_get_selected(combo) == 1");
    _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &stats);
    t.CHECK(@src(), stats.instance_count > closed.instance_count, "stats.instance_count > closed.instance_count");
    _ = run_until_still(window, 600);
    raven.Rwindow_get_frame_stats(window, &stats);
    t.CHECK(@src(), stats.instance_count <= closed.instance_count + 2, "stats.instance_count <= closed.instance_count + 2");

    // a menu destroyed while it is closing, and a window destroyed with a popup still shrinking
    menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    _ = raven.Rmenu_add_item(menu, "Item");
    raven.Rmenu_open(menu, window, 20.0, 20.0);
    _ = raven.Rdraw_frame();
    raven.Rwindow_close_popups(window);
    _ = raven.Rdraw_frame();
    raven.Rwidget_destroy(menu);
    _ = raven.Rdraw_frame();
    menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    _ = raven.Rmenu_add_item(menu, "Item");
    raven.Rmenu_open(menu, window, 20.0, 20.0);
    _ = raven.Rdraw_frame();
    raven.Rwindow_close_popups(window);
    // opened again before it finished closing
    raven.Rmenu_open(menu, window, 30.0, 30.0);
    _ = raven.Rdraw_frame();
    raven.Rwindow_close_popups(window);
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(window);
    _ = raven.Rdraw_frame();
    raven.Rwidget_destroy(menu);
}

fn test_scrolling() void {
    const window = window_from(
        "<Window Width=\"200\" Height=\"100\"><ScrollBox Name=\"s\"><Border Height=\"400\"/></ScrollBox></Window>",
    );
    const scroll = raven.Rwidget_find(window, "s");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var frames: c_int = undefined;

    _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_move(window, 50.0, 50.0);
    // the offset is where the content is going: it changes at once, the drawing follows
    raven.Rwindow_inject_mouse_wheel(window, 0.0, -1.0);
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK_NEAR(@src(), y, 48.0, "y");
    frames = run_until_still(window, 600);
    t.CHECK(@src(), frames > 5 and frames < 120, "frames > 5 && frames < 120");

    // against the end: the offset stays, the content bounces and comes back
    raven.Rwindow_inject_mouse_wheel(window, 0.0, 5.0);
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK_NEAR(@src(), y, 0.0, "y");
    _ = run_until_still(window, 600);
    raven.Rwindow_inject_mouse_wheel(window, 0.0, 5.0);
    frames = run_until_still(window, 600);
    t.CHECK(@src(), frames > 5 and frames < 200, "frames > 5 && frames < 200");
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK_NEAR(@src(), y, 0.0, "y");

    raven.Rwindow_destroy(window);
}

export fn main() c_int {
    if (t.test_init(0) == 0) return 1;
    raven.Rset_animations_enabled(raven.R_TRUE);
    raven.Rset_animation_time_step(1.0 / 60.0);

    t.RUN(test_springs, "test_springs");
    t.RUN(test_layout_animation, "test_layout_animation");
    t.RUN(test_transitions, "test_transitions");
    t.RUN(test_popups, "test_popups");
    t.RUN(test_scrolling, "test_scrolling");

    raven.Rshutdown();
    return t.test_report("test_animation");
}
