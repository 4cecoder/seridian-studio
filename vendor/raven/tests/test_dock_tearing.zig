// Translated to Zig from vendor/raven/tests/test_dock_tearing.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Tearing of dock areas: a tab dragged out of the area takes its panel to a
// window of its own; dragged back over the area, it docks there; a double
// click and the closing of the window put panels back where they were.
// Runs headless (null backend): the events are injected.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdio.h>: what test.zig does not declare
const FILE = opaque {};
extern "c" var stderr: ?*FILE;
extern "c" fn fprintf(stream: ?*FILE, format: [*c]const u8, ...) c_int;
extern "c" fn fopen(pathname: [*c]const u8, mode: [*c]const u8) ?*FILE;
extern "c" fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize;
extern "c" fn fclose(stream: ?*FILE) c_int;

var failures: c_int = 0;
// #define CHECK(condition, what): this file's own check, not the one of test.h
fn CHECK(src: t.Src, condition: bool, what: [*c]const u8) void {
    if (!condition) {
        _ = fprintf(stderr, "FAIL %s (line %d)\n", what, @as(c_int, @intCast(src.line)));
        failures += 1;
    } else _ = t.printf("ok   %s\n", what);
}

fn frames(n: c_int) void {
    var i: c_int = 0;
    while (i < n) : (i += 1) _ = raven.Rdraw_frame();
}

/// Presses at (x0, y0) in a window, drags in steps to (x1, y1) of that window, releases.
fn drag(window: raven.Rid, x0: f32, y0: f32, x1: f32, y1: f32) void {
    var i: c_int = undefined;
    raven.Rwindow_inject_mouse_move(window, x0, y0);
    frames(1);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    frames(1);
    i = 1;
    while (i <= 12) : (i += 1) {
        raven.Rwindow_inject_mouse_move(window, x0 + (x1 - x0) * @as(f32, @floatFromInt(i)) / 12.0, y0 + (y1 - y0) * @as(f32, @floatFromInt(i)) / 12.0);
        frames(1);
    }
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    frames(3);
}

/// The same, the pointer going in steps to a point of the screen: the window may move under it (a floating window follows its tab).
fn drag_to_screen(window: raven.Rid, x0: f32, y0: f32, screen_x: f32, screen_y: f32) void {
    var i: c_int = undefined;
    var wx: c_int = undefined;
    var wy: c_int = undefined;
    raven.Rwindow_get_position(window, &wx, &wy);
    const start_x: f32 = @as(f32, @floatFromInt(wx)) + x0;
    const start_y: f32 = @as(f32, @floatFromInt(wy)) + y0;
    raven.Rwindow_inject_mouse_move(window, x0, y0);
    frames(1);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    frames(1);
    i = 1;
    while (i <= 12) : (i += 1) {
        const sx: f32 = start_x + (screen_x - start_x) * @as(f32, @floatFromInt(i)) / 12.0;
        const sy: f32 = start_y + (screen_y - start_y) * @as(f32, @floatFromInt(i)) / 12.0;
        raven.Rwindow_get_position(window, &wx, &wy);
        raven.Rwindow_inject_mouse_move(window, sx - @as(f32, @floatFromInt(wx)), sy - @as(f32, @floatFromInt(wy)));
        frames(1);
    }
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    frames(3);
}

fn double_click(window: raven.Rid, x: f32, y: f32) void {
    raven.Rwindow_inject_mouse_move(window, x, y);
    frames(1);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    frames(3);
}

export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    var desc: raven.RInitDesc = undefined;
    var floating_window: raven.Rid = undefined;
    var wx: c_int = undefined;
    var wy: c_int = undefined;
    const capture: [*c]const u8 = if (argc > 1) argv[1] else null;
    @memset(std.mem.asBytes(&desc), 0);
    desc.backend = @as(raven.RBackend, if (capture != null) raven.R_BACKEND_VULKAN else raven.R_BACKEND_NULL);
    desc.headless = raven.R_TRUE;
    if (raven.Rinit_ex(&desc) == 0) return 1;
    raven.Rset_animation_time_step(1.0 / 60.0);

    const xml =
        "<Window Title=\"Tearing\" Width=\"900\" Height=\"560\">" ++
        "  <DockArea Name=\"dock\">" ++
        "    <Label Name=\"editor\" Text=\"Editor\" Slot.Title=\"Editor\"/>" ++
        "    <Label Name=\"files\" Text=\"Files\" Slot.Title=\"Files\" Slot.Dock=\"Left\" Slot.DockTo=\"editor\" Slot.DockSize=\"0.3\"/>" ++
        "    <Label Name=\"output\" Text=\"Output\" Slot.Title=\"Output\" Slot.Dock=\"Bottom\" Slot.DockTo=\"editor\" Slot.DockSize=\"0.35\"/>" ++
        "    <Label Name=\"problems\" Text=\"Problems\" Slot.Title=\"Problems\" Slot.Dock=\"Tab\" Slot.DockTo=\"output\"/>" ++
        "  </DockArea>" ++
        "</Window>";
    // sizeof(xml) - 1: the length of the text without its terminating zero
    const window = raven.Rwindow_create_from_xml(xml, xml.len);
    CHECK(@src(), window != raven.R_INVALID_ID, "the window is made");
    raven.Rwindow_set_position(window, 100, 100);
    const dock = raven.Rwidget_find(window, "dock");
    const files = raven.Rwidget_find(window, "files");
    const output = raven.Rwidget_find(window, "output");
    const problems = raven.Rwidget_find(window, "problems");
    frames(10);
    CHECK(@src(), raven.Rdock_area_is_tearable(dock) != 0, "a dock area is tearable by default");

    // 1. the tab Files dragged far below the window: a window of its own
    drag(window, 40.0, 14.0, 450.0, 760.0);
    floating_window = raven.Rdock_area_get_panel_window(dock, files);
    CHECK(@src(), floating_window != raven.R_INVALID_ID, "the dragged tab took Files to a window of its own");
    CHECK(@src(), raven.Rwidget_get_parent(files) != dock, "Files is no longer a child of the area");
    raven.Rwindow_get_position(floating_window, &wx, &wy);
    CHECK(@src(), wx > 300 and wy > 700, "the window opened where the tab was dropped");
    {
        var fw: c_int = 0;
        var fh: c_int = 0;
        raven.Rwindow_get_size(floating_window, &fw, &fh);
        _ = t.printf("     floating window %d x %d\n", fw, fh);
        CHECK(@src(), fw >= 250 and fw <= 300 and fh >= 500, "the window has the size the panel had in the area");
    }
    // !Rdock_area_is_panel_open(dock, output) == 0: C reads it as (!open) == 0
    CHECK(@src(), @intFromBool(raven.Rdock_area_is_panel_open(dock, output) == 0) == 0, "the other panels stayed");
    if (capture != null) {
        frames(20);
        {
            var path: [512]u8 = undefined;
            var w: c_int = 0;
            var h: c_int = 0;
            var i: c_int = undefined;
            var pixels: [*c]u8 = undefined;
            var file: ?*FILE = undefined;
            _ = t.snprintf(&path, path.len, "%s_main.ppm", capture);
            pixels = raven.Rwindow_capture(window, &w, &h);
            file = if (pixels != null) fopen(&path, "wb") else null;
            if (file != null) {
                _ = fprintf(file, "P6\n%d %d\n255\n", w, h);
                i = 0;
                while (i < w * h) : (i += 1) _ = fwrite(pixels + @as(usize, @intCast(i * 4)), 1, 3, file);
                _ = fclose(file);
            }
            raven.Rpixels_free(pixels);
            _ = t.snprintf(&path, path.len, "%s_float.ppm", capture);
            pixels = raven.Rwindow_capture(floating_window, &w, &h);
            file = if (pixels != null) fopen(&path, "wb") else null;
            if (file != null) {
                _ = fprintf(file, "P6\n%d %d\n255\n", w, h);
                i = 0;
                while (i < w * h) : (i += 1) _ = fwrite(pixels + @as(usize, @intCast(i * 4)), 1, 3, file);
                _ = fclose(file);
            }
            raven.Rpixels_free(pixels);
        }
    }
    // the functions of the area work on its floating panel
    raven.Rdock_area_set_panel_title(dock, files, "Explorer");
    CHECK(@src(), raven.Rdock_area_is_panel_open(dock, files) != 0, "the area still knows its floating panel");

    // 2. the floating tab dragged over the middle of the main window: docked there
    const floating = raven.Rwidget_get_parent(files);
    // from its tab to the middle of the editor of the main window (at 100, 100 on the screen)
    drag_to_screen(floating_window, 30.0, 14.0, 100.0 + 600.0, 100.0 + 160.0);
    frames(4);
    CHECK(@src(), raven.Rwidget_get_parent(files) == dock, "dropped over the main window, Files is docked there again");
    CHECK(@src(), raven.Rwindow_is_valid(floating_window) == 0, "the empty floating window closed");
    _ = floating;

    // 3. Rdock_area_float_panel, then a double click on its tab: back where it was
    floating_window = raven.Rdock_area_float_panel(dock, problems, 1200, 300);
    frames(4);
    CHECK(@src(), floating_window != raven.R_INVALID_ID and raven.Rwidget_get_parent(problems) != dock, "Rdock_area_float_panel");
    double_click(floating_window, 30.0, 14.0);
    CHECK(@src(), raven.Rwidget_get_parent(problems) == dock, "a double click on the floating tab docks it back");
    CHECK(@src(), raven.Rwindow_is_valid(floating_window) == 0, "and its window closes");

    // 4. closing a floating window puts its panel back
    floating_window = raven.Rdock_area_float_panel(dock, output, 1200, 300);
    frames(4);
    raven.Rwindow_close(floating_window);
    frames(4);
    CHECK(@src(), raven.Rwidget_get_parent(output) == dock, "closing the floating window docks its panel back");

    // 5. Tearable="false": a tab dragged out stays
    raven.Rdock_area_set_tearable(dock, raven.R_FALSE);
    drag(window, 40.0, 14.0, 450.0, 760.0);
    CHECK(@src(), raven.Rwidget_get_parent(files) == dock, "an area that is not tearable keeps its panels");

    raven.Rshutdown();
    _ = t.printf(if (failures != 0) "%d failure(s)\n" else "all good\n", failures);
    return if (failures != 0) 1 else 0;
}
