// Translated to Zig from vendor/raven/tests/benchmark.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - benchmark: cost of a large widget tree.
//
//   raven_benchmark [columns] [worker threads] [vulkan]
//
// Builds `columns` x 60 rows (5 widgets per row), then measures the first
// layout, a full repaint (serial or split between the worker threads), and
// the layout after changing a single label. By default nothing is rendered
// (null backend): the numbers are the CPU cost of Raven itself. With "vulkan",
// frames are also sent to the GPU and the time of the render thread is shown.

const std = @import("std");
const raven = @import("raven");

// ---- the C library functions the program calls (<stdio.h>, <stdlib.h>, <string.h>) ----
const FILE = opaque {};
extern "c" var stderr: ?*FILE;
extern "c" fn printf(format: [*:0]const u8, ...) c_int;
extern "c" fn fprintf(stream: ?*FILE, format: [*:0]const u8, ...) c_int;
extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) c_int;
extern "c" fn atoi(text: [*c]const u8) c_int;
extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;

const ROWS = 60;

fn build_tree(columns: c_int) raven.Rid {
    const scroll: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    const row_of_columns: raven.Rid = raven.Rwidget_add_child(scroll, raven.Rwidget_create(raven.R_WIDGET_HBOX));
    var column: c_int = undefined;
    var row: c_int = undefined;
    column = 0;
    while (column < columns) : (column += 1) {
        const box: raven.Rid = raven.Rwidget_add_child(row_of_columns, raven.Rwidget_create(raven.R_WIDGET_VBOX));
        row = 0;
        while (row < ROWS) : (row += 1) {
            var text: [32]u8 = undefined;
            const border: raven.Rid = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_BORDER));
            const line: raven.Rid = raven.Rwidget_add_child(border, raven.Rwidget_create(raven.R_WIDGET_HBOX));
            _ = snprintf(&text, text.len, "Item %d.%d", column, row);
            _ = raven.Rwidget_add_child(line, raven.Rlabel_create(&text));
            _ = raven.Rwidget_add_child(line, raven.Rbutton_create("x"));
        }
    }
    return scroll;
}

export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    var columns: c_int = if (argc > 1) atoi(argv[1]) else 40;
    const workers: c_int = if (argc > 2) atoi(argv[2]) else 0;
    const vulkan: c_int = @intFromBool(argc > 3 and strcmp(argv[3], "vulkan") == 0);
    const frames: c_int = 30;
    var desc: raven.RInitDesc = undefined;
    var stats: raven.RFrameStats = undefined;
    var window: raven.Rid = undefined;
    var label: raven.Rid = undefined;
    var start: f64 = undefined;
    var build_ms: f64 = undefined;
    var best: f64 = 1e9;
    var sum: f64 = 0.0;
    var render: f64 = 0.0;
    var i: c_int = undefined;

    if (columns < 4) columns = 4;
    desc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = if (vulkan != 0) raven.R_BACKEND_VULKAN else raven.R_BACKEND_NULL;
    desc.headless = @intFromBool(vulkan == 0);
    desc.worker_threads = workers;
    desc.disable_vsync = raven.R_TRUE;
    if (raven.Rinit_ex(&desc) == 0) {
        _ = fprintf(stderr, "raven_benchmark: cannot start Raven\n");
        return 1;
    }

    // large enough for every widget to be visible: nothing is culled
    window = raven.Rwindow_create("Raven benchmark", if (vulkan != 0) 1600 else 150 * columns, if (vulkan != 0) 900 else 2000, raven.R_WINDOW_DEFAULT);
    start = raven.Rget_time();
    raven.Rwindow_set_content(window, build_tree(columns));
    build_ms = (raven.Rget_time() - start) * 1000.0;

    _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &stats);
    _ = printf("%u widgets, %d worker thread(s)\n", @as(c_uint, stats.widget_count), raven.Rget_worker_thread_count());
    _ = printf("  build         %8.2f ms\n", build_ms);
    _ = printf("  first layout  %8.2f ms\n", stats.layout_ms);
    _ = printf("  first paint   %8.2f ms   (rasterizes the glyphs)\n", stats.paint_ms);

    i = 0;
    while (i < frames) : (i += 1) {
        raven.Rwindow_request_redraw(window);
        _ = raven.Rdraw_frame();
        raven.Rwindow_get_frame_stats(window, &stats);
        if (stats.paint_ms < best) best = stats.paint_ms;
        sum += stats.paint_ms;
        render += stats.render_ms;
    }
    _ = printf("  repaint       %8.2f ms   best of %d (average %.2f ms): %u primitives, %u draw call(s), %u paint job(s)\n", //
        best, frames, sum / @as(f64, @floatFromInt(frames)), @as(c_uint, stats.instance_count), @as(c_uint, stats.draw_call_count), @as(c_uint, stats.paint_job_count));
    if (vulkan != 0) _ = printf("  render thread %8.2f ms   average per frame (upload, record, submit, present)\n", render / @as(f64, @floatFromInt(frames)));

    // one label changes: only its ancestors are measured and arranged again
    label = raven.Rwidget_get_child(raven.Rwidget_get_child(raven.Rwidget_get_child(raven.Rwidget_get_child(raven.Rwidget_get_child(raven.Rwindow_get_content(window), 0), 3), 7), 0), 0);
    raven.Rlabel_set_text(label, "a longer text than before");
    _ = raven.Rdraw_frame();
    raven.Rwindow_get_frame_stats(window, &stats);
    _ = printf("  relayout      %8.3f ms   after changing one label\n", stats.layout_ms);

    raven.Rshutdown();
    return 0;
}

// The panic handler (the pattern of tests/test.zig, which this program does not import): a trap in the
// safe build prints its message and aborts (the standard handler would drag the stack trace machinery
// into an object linked by the C compiler).
extern "c" fn abort() noreturn;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
fn benchmarkPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    const prefix = "Raven benchmark (Zig) panic: ";
    _ = write(2, prefix.ptr, prefix.len);
    _ = write(2, msg.ptr, msg.len);
    _ = write(2, "\n", 1);
    abort();
}
pub const panic = std.debug.FullPanic(benchmarkPanic);
