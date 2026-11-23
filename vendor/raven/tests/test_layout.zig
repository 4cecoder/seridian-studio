// Translated to Zig from vendor/raven/tests/test_layout.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - layout: the measure / arrange passes of every panel.
// Sizes are checked through Rwidget_get_rect, in a 400 x 300 window.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

var g_window: raven.Rid = 0;

/// A fixed-size block standing for any content.
fn block(width: f32, height: f32) raven.Rid {
    const spacer = raven.Rwidget_create(raven.R_WIDGET_SPACER);
    raven.Rwidget_set_size(spacer, width, height);
    return spacer;
}

fn test_vbox() void {
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    const a = raven.Rwidget_add_child(box, block(50, 20));
    const b = raven.Rwidget_add_child(box, block(80, 30));
    const c = raven.Rwidget_add_child(box, block(10, 40));
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rwindow_set_content(g_window, box);

    // auto slots stack with their desired height and fill the width
    t.CHECK_RECT(@src(), a, 0, 0, 400, 20, "a");
    t.CHECK_RECT(@src(), b, 0, 20, 400, 30, "b");
    t.CHECK_RECT(@src(), c, 0, 50, 400, 40, "c");
    raven.Rwidget_get_desired_size(box, &w, &h);
    t.CHECK_NEAR(@src(), w, 80, "w");
    t.CHECK_NEAR(@src(), h, 90, "h");

    // a fill slot takes what is left
    raven.Rslot_set_fill(b, 1.0);
    t.CHECK_RECT(@src(), b, 0, 20, 400, 240, "b");
    t.CHECK_RECT(@src(), c, 0, 260, 400, 40, "c");

    // two fill slots share in proportion to their coefficients
    raven.Rslot_set_fill(c, 3.0);
    t.CHECK_RECT(@src(), b, 0, 20, 400, 70, "b");
    t.CHECK_RECT(@src(), c, 0, 90, 400, 210, "c");

    // alignment across the axis, padding and spacing
    raven.Rslot_set_auto(b);
    raven.Rslot_set_auto(c);
    raven.Rslot_set_halign(a, raven.R_HALIGN_CENTER);
    raven.Rslot_set_halign(b, raven.R_HALIGN_RIGHT);
    raven.Rslot_set_padding(c, 5, 6, 7, 8);
    raven.Rpanel_set_spacing(box, 10);
    t.CHECK_RECT(@src(), a, 175, 0, 50, 20, "a");
    t.CHECK_RECT(@src(), b, 320, 30, 80, 30, "b");
    t.CHECK_RECT(@src(), c, 5, 76, 388, 40, "c");

    // a collapsed child takes no space, a hidden one keeps it
    raven.Rwidget_set_visibility(a, raven.R_COLLAPSED);
    t.CHECK_RECT(@src(), b, 320, 0, 80, 30, "b");
    raven.Rwidget_set_visibility(a, raven.R_HIDDEN);
    t.CHECK_RECT(@src(), b, 320, 30, 80, 30, "b");

    // the slot maximum caps a fill slot
    raven.Rwidget_set_visibility(a, raven.R_VISIBLE);
    raven.Rslot_set_fill(b, 1.0);
    raven.Rslot_set_max_size(b, 100.0);
    raven.Rslot_set_halign(b, raven.R_HALIGN_FILL);
    t.CHECK_RECT(@src(), b, 0, 30, 400, 100, "b");
}

fn test_hbox() void {
    const box = raven.Rwidget_create(raven.R_WIDGET_HBOX);
    const a = raven.Rwidget_add_child(box, block(50, 20));
    const b = raven.Rwidget_add_child(box, block(80, 30));
    raven.Rwindow_set_content(g_window, box);
    raven.Rslot_set_fill(b, 1.0);
    raven.Rslot_set_valign(a, raven.R_VALIGN_BOTTOM);
    t.CHECK_RECT(@src(), a, 0, 280, 50, 20, "a");
    t.CHECK_RECT(@src(), b, 50, 0, 350, 300, "b");
    raven.Rslot_set_valign(a, raven.R_VALIGN_CENTER);
    t.CHECK_RECT(@src(), a, 0, 140, 50, 20, "a");
}

fn test_overlay_and_border() void {
    const overlay = raven.Rwidget_create(raven.R_WIDGET_OVERLAY);
    const back = raven.Rwidget_add_child(overlay, block(10, 10));
    const border = raven.Rwidget_add_child(overlay, raven.Rwidget_create(raven.R_WIDGET_BORDER));
    const inside = raven.Rwidget_add_child(border, block(60, 40));
    var replaced: raven.Rid = undefined;
    raven.Rwindow_set_content(g_window, overlay);

    raven.Rslot_set_halign(border, raven.R_HALIGN_RIGHT);
    raven.Rslot_set_valign(border, raven.R_VALIGN_BOTTOM);
    raven.Rslot_set_padding(border, 0, 0, 10, 10);
    raven.Rborder_set_padding(border, 4, 4, 4, 4);
    t.CHECK_RECT(@src(), back, 0, 0, 400, 300, "back");
    t.CHECK_RECT(@src(), border, 322, 242, 68, 48, "border");
    t.CHECK_RECT(@src(), inside, 326, 246, 60, 40, "inside");

    // a single-child panel replaces its child
    replaced = raven.Rwidget_add_child(border, block(20, 20));
    t.CHECK(@src(), raven.Rwidget_is_valid(inside) == 0, "!Rwidget_is_valid(inside)");
    t.CHECK(@src(), raven.Rwidget_get_child_count(border) == 1, "Rwidget_get_child_count(border) == 1");
    t.CHECK_RECT(@src(), replaced, 366, 266, 20, 20, "replaced");
}

fn test_grid() void {
    const grid = raven.Rwidget_create(raven.R_WIDGET_GRID);
    const a = raven.Rwidget_add_child(grid, block(40, 20));
    const b = raven.Rwidget_add_child(grid, block(60, 30));
    const c = raven.Rwidget_add_child(grid, block(100, 10));
    const d = raven.Rwidget_add_child(grid, block(20, 50));
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rwindow_set_content(g_window, grid);
    raven.Rslot_set_grid(a, 0, 0);
    raven.Rslot_set_grid(b, 1, 0);
    raven.Rslot_set_grid(c, 0, 1);
    raven.Rslot_set_grid(d, 1, 1);

    // columns: 100, 60 - rows: 30, 50
    raven.Rwidget_get_desired_size(grid, &w, &h);
    t.CHECK_NEAR(@src(), w, 160, "w");
    t.CHECK_NEAR(@src(), h, 80, "h");
    t.CHECK_RECT(@src(), a, 0, 0, 100, 30, "a");
    t.CHECK_RECT(@src(), b, 100, 0, 60, 30, "b");
    t.CHECK_RECT(@src(), d, 100, 30, 60, 50, "d");

    // a fill column takes the free width, a fill row the free height
    raven.Rgrid_set_column_fill(grid, 1, 1.0);
    raven.Rgrid_set_row_fill(grid, 0, 1.0);
    t.CHECK_RECT(@src(), b, 100, 0, 300, 250, "b");
    t.CHECK_RECT(@src(), c, 0, 250, 100, 50, "c");

    // a spanning cell covers both columns
    raven.Rslot_set_grid_span(c, 2, 1);
    raven.Rwidget_set_visibility(d, raven.R_COLLAPSED);
    t.CHECK_RECT(@src(), c, 0, 290, 400, 10, "c");

    // the first column is now only as wide as `a`; gaps of 8 between tracks
    raven.Rpanel_set_spacing(grid, 8);
    t.CHECK_RECT(@src(), b, 48, 0, 352, 282, "b");
}

fn test_uniform_grid() void {
    const grid = raven.Rwidget_create(raven.R_WIDGET_UNIFORM_GRID);
    var cells: [5]raven.Rid = undefined;
    var i: c_int = undefined;
    i = 0;
    while (i < 5) : (i += 1) cells[@intCast(i)] = raven.Rwidget_add_child(grid, block(10, 10));
    raven.Rwindow_set_content(g_window, grid);
    raven.Runiform_grid_set_columns(grid, 2);
    // 2 columns x 3 rows sharing 400 x 300
    t.CHECK_RECT(@src(), cells[0], 0, 0, 200, 100, "cells[0]");
    t.CHECK_RECT(@src(), cells[1], 200, 0, 200, 100, "cells[1]");
    t.CHECK_RECT(@src(), cells[4], 0, 200, 200, 100, "cells[4]");
}

fn test_size_box_and_canvas() void {
    const box = raven.Rwidget_create(raven.R_WIDGET_SIZE_BOX);
    const content = raven.Rwidget_add_child(box, block(10, 10));
    var canvas: raven.Rid = undefined;
    var pinned: raven.Rid = undefined;
    var stretched: raven.Rid = undefined;
    raven.Rwindow_set_content(g_window, box);

    // 2:1 inside 400 x 300 is 400 x 200, centered
    raven.Rsize_box_set_aspect_ratio(box, 2.0);
    t.CHECK_RECT(@src(), content, 0, 50, 400, 200, "content");
    raven.Rsize_box_set_aspect_ratio(box, 0.5);
    t.CHECK_RECT(@src(), content, 125, 0, 150, 300, "content");

    canvas = raven.Rwidget_create(raven.R_WIDGET_CANVAS);
    pinned = raven.Rwidget_add_child(canvas, block(40, 20));
    stretched = raven.Rwidget_add_child(canvas, block(1, 1));
    raven.Rwindow_set_content(g_window, canvas);

    // pinned to the bottom-right corner, pivot on its own bottom-right corner
    raven.Rslot_set_anchors(pinned, 1, 1, 1, 1);
    raven.Rslot_set_alignment(pinned, 1, 1);
    raven.Rslot_set_position(pinned, -10, -10);
    t.CHECK_RECT(@src(), pinned, 350, 270, 40, 20, "pinned");

    // stretched over the whole canvas with a 20 unit margin
    raven.Rslot_set_anchors(stretched, 0, 0, 1, 1);
    raven.Rslot_set_position(stretched, 20, 20);
    raven.Rslot_set_size(stretched, 20, 20);
    t.CHECK_RECT(@src(), stretched, 20, 20, 360, 260, "stretched");
}

fn test_switcher_and_constraints() void {
    const switcher = raven.Rwidget_create(raven.R_WIDGET_SWITCHER);
    const first = raven.Rwidget_add_child(switcher, block(10, 10));
    const second = raven.Rwidget_add_child(switcher, block(10, 10));
    var box: raven.Rid = undefined;
    var limited: raven.Rid = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rwindow_set_content(g_window, switcher);
    t.CHECK_RECT(@src(), first, 0, 0, 400, 300, "first");
    raven.Rswitcher_set_index(switcher, 1);
    t.CHECK(@src(), raven.Rswitcher_get_index(switcher) == 1, "Rswitcher_get_index(switcher) == 1");
    t.CHECK_RECT(@src(), second, 0, 0, 400, 300, "second");

    box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    limited = raven.Rwidget_add_child(box, block(500, 5));
    raven.Rwindow_set_content(g_window, box);
    raven.Rslot_set_halign(limited, raven.R_HALIGN_LEFT);
    raven.Rwidget_set_max_size(limited, 120, -1);
    raven.Rwidget_set_min_size(limited, -1, 33);
    raven.Rwidget_get_desired_size(limited, &w, &h);
    t.CHECK_NEAR(@src(), w, 120, "w");
    t.CHECK_NEAR(@src(), h, 33, "h");
    t.CHECK_RECT(@src(), limited, 0, 0, 120, 33, "limited");
}

fn test_scroll_box() void {
    const scroll = raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    var rows: [10]raven.Rid = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    const bar: f32 = raven.Rtheme_get_metric(raven.R_METRIC_SCROLLBAR_SIZE);
    var i: c_int = undefined;
    i = 0;
    while (i < 10) : (i += 1) rows[@intCast(i)] = raven.Rwidget_add_child(scroll, block(50, 100));
    raven.Rwindow_set_content(g_window, scroll);

    // 1000 units of content in a 300 unit view: the scrollbar takes its width
    t.CHECK_RECT(@src(), rows[0], 0, 0, 400 - bar, 100, "rows[0]");
    raven.Rscroll_box_set_offset(scroll, 0, 250);
    t.CHECK_RECT(@src(), rows[0], 0, -250, 400 - bar, 100, "rows[0]");
    t.CHECK_RECT(@src(), rows[3], 0, 50, 400 - bar, 100, "rows[3]");

    // offsets are clamped to the content
    raven.Rscroll_box_set_offset(scroll, 0, 5000);
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK_NEAR(@src(), y, 700, "y");
    raven.Rscroll_box_scroll_to_end(scroll);
    t.CHECK_RECT(@src(), rows[9], 0, 200, 400 - bar, 100, "rows[9]");

    raven.Rscroll_box_set_offset(scroll, 0, 0);
    raven.Rwidget_scroll_into_view(rows[5]);
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK_NEAR(@src(), y, 300, "y");

    // the mouse wheel scrolls, and widgets scrolled out of view cannot be hit
    raven.Rscroll_box_set_offset(scroll, 0, 0);
    raven.Rwindow_inject_mouse_move(g_window, 100, 100);
    raven.Rwindow_inject_mouse_wheel(g_window, 0, -1);
    raven.Rscroll_box_get_offset(scroll, &x, &y);
    t.CHECK(@src(), y > 0, "y > 0");
}

fn test_splitter_and_wrap() void {
    const splitter = raven.Rwidget_create(raven.R_WIDGET_SPLITTER);
    const left = raven.Rwidget_add_child(splitter, block(10, 10));
    const right = raven.Rwidget_add_child(splitter, block(10, 10));
    const handle: f32 = raven.Rtheme_get_metric(raven.R_METRIC_SPLITTER_SIZE);
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var wrap: raven.Rid = undefined;
    var items: [5]raven.Rid = undefined;
    var i: c_int = undefined;
    raven.Rwindow_set_content(g_window, splitter);

    raven.Rslot_set_fill(left, 1.0);
    raven.Rslot_set_fill(right, 3.0);
    raven.Rwidget_get_rect(left, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), w, (400 - handle) * 0.25, "w");
    t.CHECK_NEAR(@src(), h, 300, "h");

    // dragging the handle 50 units to the right grows the left pane by 50
    raven.Rwindow_inject_mouse_move(g_window, w + handle * 0.5, 150);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(g_window, w + handle * 0.5 + 50, 150);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK_RECT(@src(), left, 0, 0, w + 50, 300, "left");

    wrap = raven.Rwidget_create(raven.R_WIDGET_WRAP_BOX);
    i = 0;
    while (i < 5) : (i += 1) items[@intCast(i)] = raven.Rwidget_add_child(wrap, block(150, 40));
    raven.Rwindow_set_content(g_window, wrap);
    // two blocks of 150 fit in 400, the third wraps
    t.CHECK_RECT(@src(), items[1], 150, 0, 150, 40, "items[1]");
    t.CHECK_RECT(@src(), items[2], 0, 40, 150, 40, "items[2]");
    t.CHECK_RECT(@src(), items[4], 0, 80, 150, 40, "items[4]");
    raven.Rwidget_get_desired_size(wrap, &w, &h);
    t.CHECK_NEAR(@src(), h, 120, "h");
}

fn test_window_resize_and_text() void {
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    const label = raven.Rwidget_add_child(box, raven.Rlabel_create("The quick brown fox jumps over the lazy dog, again and again and again."));
    const filler = raven.Rwidget_add_child(box, block(10, 10));
    var single_w: f32 = undefined;
    var single_h: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var text_w: f32 = undefined;
    var text_h: f32 = undefined;
    raven.Rwindow_set_content(g_window, box);
    raven.Rslot_set_fill(filler, 1.0);

    raven.Rwidget_get_desired_size(label, &single_w, &single_h);
    t.CHECK(@src(), single_w > 300 and single_h > 8, "single_w > 300 && single_h > 8");
    raven.Rfont_measure_text(raven.R_INVALID_ID, 0, "The quick brown fox", &text_w, &text_h);
    t.CHECK(@src(), text_w > 80 and text_w < single_w, "text_w > 80 && text_w < single_w");
    // the label rounds its desired size up to whole units
    t.CHECK(@src(), text_h <= single_h and text_h > single_h - 1.0, "text_h <= single_h && text_h > single_h - 1.0f");

    // a wrapped label gets taller when the window gets narrower
    raven.Rlabel_set_wrap(label, raven.R_TRUE);
    raven.Rwindow_set_size(g_window, 150, 300);
    raven.Rwidget_get_rect(label, null, null, &w, &h);
    t.CHECK_NEAR(@src(), w, 150, "w");
    t.CHECK(@src(), h >= single_h * 3 - 1, "h >= single_h * 3 - 1");
    t.CHECK_RECT(@src(), filler, 0, h, 150, 300 - h, "filler");

    raven.Rwindow_set_size(g_window, 400, 300);
    raven.Rwidget_get_rect(label, null, null, &w, &h);
    t.CHECK_NEAR(@src(), w, 400, "w");
    t.CHECK(@src(), h < single_h * 3, "h < single_h * 3");
}

fn test_tree_api() void {
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    const a = raven.Rwidget_add_child(box, block(10, 10));
    const b = raven.Rwidget_add_child(box, block(10, 10));
    const other = raven.Rwidget_create(raven.R_WIDGET_HBOX);
    raven.Rwindow_set_content(g_window, box);

    raven.Rwidget_set_name(b, "second");
    t.CHECK(@src(), raven.Rwidget_find(g_window, "second") == b, "Rwidget_find(g_window, \"second\") == b");
    t.CHECK(@src(), raven.Rwidget_find(box, "missing") == raven.R_INVALID_ID, "Rwidget_find(box, \"missing\") == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_get_parent(a) == box, "Rwidget_get_parent(a) == box");
    t.CHECK(@src(), raven.Rwidget_get_child(box, 1) == b, "Rwidget_get_child(box, 1) == b");
    t.CHECK(@src(), raven.Rwidget_get_window(a) == g_window, "Rwidget_get_window(a) == g_window");
    t.CHECK(@src(), raven.Rwidget_get_type(box) == raven.R_WIDGET_VBOX, "Rwidget_get_type(box) == R_WIDGET_VBOX");

    // moving a widget to another parent
    _ = raven.Rwidget_insert_child(other, a, 0);
    t.CHECK(@src(), raven.Rwidget_get_child_count(box) == 1, "Rwidget_get_child_count(box) == 1");
    t.CHECK(@src(), raven.Rwidget_get_parent(a) == other, "Rwidget_get_parent(a) == other");
    t.CHECK(@src(), raven.Rwidget_get_window(a) == raven.R_INVALID_ID, "Rwidget_get_window(a) == R_INVALID_ID");

    // deleting a parent deletes its children; stale handles are detected
    raven.Rwidget_destroy(other);
    t.CHECK(@src(), raven.Rwidget_is_valid(a) == 0, "!Rwidget_is_valid(a)");
    t.EXPECT_ERRORS_BEGIN();
    raven.Rwidget_set_name(a, "ghost");
    t.CHECK(@src(), raven.Rwidget_add_child(a, b) == raven.R_INVALID_ID, "Rwidget_add_child(a, b) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_add_child(box, box) == raven.R_INVALID_ID, "Rwidget_add_child(box, box) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwidget_add_child(b, box) == raven.R_INVALID_ID, "Rwidget_add_child(b, box) == R_INVALID_ID"); // a spacer has no children
    raven.Rgrid_set_column_fill(box, 0, 1.0); // wrong widget type
    t.EXPECT_ERRORS_END(@src(), 5, "g_test_errors >= (5)");
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("cannot initialize Raven\n");
        return 1;
    }
    g_window = raven.Rwindow_create("layout", 400, 300, raven.R_WINDOW_DEFAULT);
    t.CHECK(@src(), raven.Rwindow_is_valid(g_window) != 0, "Rwindow_is_valid(g_window)");

    t.RUN(test_vbox, "test_vbox");
    t.RUN(test_hbox, "test_hbox");
    t.RUN(test_overlay_and_border, "test_overlay_and_border");
    t.RUN(test_grid, "test_grid");
    t.RUN(test_uniform_grid, "test_uniform_grid");
    t.RUN(test_size_box_and_canvas, "test_size_box_and_canvas");
    t.RUN(test_switcher_and_constraints, "test_switcher_and_constraints");
    t.RUN(test_scroll_box, "test_scroll_box");
    t.RUN(test_splitter_and_wrap, "test_splitter_and_wrap");
    t.RUN(test_window_resize_and_text, "test_window_resize_and_text");
    t.RUN(test_tree_api, "test_tree_api");

    raven.Rshutdown();
    return t.test_report("test_layout");
}
