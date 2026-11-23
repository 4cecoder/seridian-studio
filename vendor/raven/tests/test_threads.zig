// Translated to Zig from vendor/raven/tests/test_threads.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - threading: job system, tasks posted to the UI thread,
// asynchronous textures, and parallel painting giving the same result as
// serial painting.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");
const test_config = @import("test_config");

pub const panic = t.panic;

const ITEM_COUNT = 100000;

var g_values: [ITEM_COUNT]c_int = std.mem.zeroes([ITEM_COUNT]c_int);
// static volatile int g_posted: Zig has no volatile variables, only volatile pointers,
// so every access goes through the volatile pointer g_posted.
var g_posted_storage: c_int = 0;
const g_posted: *volatile c_int = &g_posted_storage;
var g_label: raven.Rid = 0;

fn fill_range(begin: raven.Ruint, end: raven.Ruint, user_data: ?*anyopaque) callconv(.c) void {
    var i: raven.Ruint = undefined;
    _ = user_data;
    i = begin;
    while (i < end) : (i += 1) g_values[i] += @as(c_int, @bitCast(i)) + 1;
}

// Runs on the UI thread: it may touch widgets.
fn posted_task(user_data: ?*anyopaque) callconv(.c) void {
    raven.Rlabel_set_text(g_label, @as([*c]const u8, @ptrCast(user_data)));
    g_posted.* += 1;
}

// Runs on a worker thread: it must not touch widgets, only post.
fn async_job(user_data: ?*anyopaque) callconv(.c) void {
    // the test counters are not thread-safe: report through the posted task instead of CHECK
    raven.Rtask_post(posted_task, if (raven.Ris_ui_thread() != 0) @as(?*anyopaque, @constCast("job ran on the UI thread")) else user_data);
}

fn wait_for_posted(count: c_int) void {
    const deadline: f64 = raven.Rget_time() + 5.0;
    while (g_posted.* < count and raven.Rget_time() < deadline) {
        raven.Rwait_events(0.05);
        _ = raven.Rdraw_frame();
    }
}

fn test_jobs() void {
    var sum: c_longlong = 0;
    var i: c_int = undefined;
    t.CHECK(@src(), raven.Rget_worker_thread_count() == 4, "Rget_worker_thread_count() == 4");
    t.CHECK(@src(), raven.Ris_ui_thread() != 0, "Ris_ui_thread()");

    @memset(&g_values, 0);
    raven.Rparallel_for(ITEM_COUNT, 512, fill_range, null);
    raven.Rparallel_for(ITEM_COUNT, 0, fill_range, null);
    i = 0;
    while (i < ITEM_COUNT) : (i += 1) sum += g_values[@intCast(i)];
    // every item was visited exactly once per call
    t.CHECK(@src(), sum == 2 * (@as(c_longlong, ITEM_COUNT) * (ITEM_COUNT + 1) / 2), "sum == 2LL * ((long long)ITEM_COUNT * (ITEM_COUNT + 1) / 2)");

    g_posted.* = 0;
    i = 0;
    while (i < 50) : (i += 1) raven.Rtask_run_async(async_job, @constCast("from a worker"));
    wait_for_posted(50);
    t.CHECK(@src(), g_posted.* == 50, "g_posted == 50");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(g_label), "from a worker", "Rlabel_get_text(g_label)");

    // widget functions refuse to run on another thread: tested by the worker above
    // through Ris_ui_thread; here the wake-up from a foreign thread
    g_posted.* = 0;
    raven.Rtask_run_async(async_job, @constCast("again"));
    raven.Rwait_events(5.0);
    wait_for_posted(1);
    t.CHECK(@src(), g_posted.* == 1, "g_posted == 1");
}

fn test_async_texture() void {
    // a 2 x 2 BMP, 24 bits, built by hand
    const bmp = [_]u8{
        'B', 'M', 70, 0,  0,  0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24, 0,
        0,   0,   0,  0,  16, 0, 0, 0, 19, 11, 0, 0, 19, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,   0,   255, 0, 255, 0, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0,
    };
    var texture: raven.Rid = raven.Rtexture_create_async(&bmp, bmp.len);
    var pixels: raven.Rid = undefined;
    const rgba = [16]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    var w: c_int = 0;
    var h: c_int = 0;

    t.CHECK(@src(), raven.Rtexture_is_valid(texture) != 0, "Rtexture_is_valid(texture)");
    if (test_config.no_image_decoder) {
        // built with RAVEN_WITH_STB_IMAGE=OFF: decoding fails, which must be reported and not hang
        t.EXPECT_ERRORS_BEGIN();
        raven.Rtexture_wait(texture);
        t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
        t.CHECK(@src(), raven.Rtexture_is_ready(texture) != 0, "Rtexture_is_ready(texture)");
    } else {
        raven.Rtexture_wait(texture);
        t.CHECK(@src(), raven.Rtexture_is_ready(texture) != 0, "Rtexture_is_ready(texture)");
        raven.Rtexture_get_size(texture, &w, &h);
        t.CHECK(@src(), w == 2 and h == 2, "w == 2 && h == 2");
    }
    raven.Rtexture_destroy(texture);
    t.CHECK(@src(), raven.Rtexture_is_valid(texture) == 0, "!Rtexture_is_valid(texture)");

    pixels = raven.Rtexture_create_from_pixels(&rgba, 2, 2);
    raven.Rtexture_set_filter(pixels, raven.R_FILTER_NEAREST);
    raven.Rtexture_update(pixels, &rgba, 2, 2);
    raven.Rtexture_update(pixels, &rgba, 4, 1);
    raven.Rtexture_get_size(pixels, &w, &h);
    t.CHECK(@src(), w == 4 and h == 1, "w == 4 && h == 1");

    // garbage is reported, not crashed on
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rtexture_create("not an image", 12) == raven.R_INVALID_ID, "Rtexture_create(\"not an image\", 12) == R_INVALID_ID");
    texture = raven.Rtexture_create_async("not an image", 12);
    raven.Rtexture_wait(texture);
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    t.CHECK(@src(), raven.Rtexture_is_ready(texture) != 0, "Rtexture_is_ready(texture)");
    raven.Rtexture_get_size(texture, &w, &h);
    t.CHECK(@src(), w == 0 and h == 0, "w == 0 && h == 0");
}

// A deep, wide tree: 40 groups of 60 rows, each row a border holding a label and a button.
fn build_big_tree() raven.Rid {
    const scroll: raven.Rid = raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    const columns: raven.Rid = raven.Rwidget_add_child(scroll, raven.Rwidget_create(raven.R_WIDGET_HBOX));
    var group: c_int = undefined;
    var row: c_int = undefined;
    group = 0;
    while (group < 40) : (group += 1) {
        const box: raven.Rid = raven.Rwidget_add_child(columns, raven.Rwidget_create(raven.R_WIDGET_VBOX));
        row = 0;
        while (row < 60) : (row += 1) {
            var text: [32]u8 = undefined;
            const border: raven.Rid = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_BORDER));
            const line: raven.Rid = raven.Rwidget_add_child(border, raven.Rwidget_create(raven.R_WIDGET_HBOX));
            _ = t.snprintf(&text, text.len, "Item %d.%d", group, row);
            _ = raven.Rwidget_add_child(line, raven.Rlabel_create(&text));
            _ = raven.Rwidget_add_child(line, raven.Rbutton_create("x"));
            raven.Rborder_set_outline(border, 1, 1, 1, 1, 0.2);
        }
    }
    return scroll;
}

fn paint_big_tree(workers: c_int) raven.RFrameStats {
    var stats: raven.RFrameStats = undefined;
    var window: raven.Rid = undefined;
    var frame: c_int = undefined;
    stats = std.mem.zeroes(raven.RFrameStats);
    if (t.test_init(workers) == 0) return stats;
    // large enough for every widget to be visible, so that nothing is culled
    window = raven.Rwindow_create("big", 6000, 2000, raven.R_WINDOW_DEFAULT);
    raven.Rwindow_set_content(window, build_big_tree());
    // the first frame also rasterizes the glyphs: measure a later one
    frame = 0;
    while (frame < 5) : (frame += 1) {
        raven.Rwindow_request_redraw(window);
        _ = raven.Rdraw_frame();
    }
    raven.Rwindow_get_frame_stats(window, &stats);
    raven.Rshutdown();
    return stats;
}

fn test_parallel_paint() void {
    const serial: raven.RFrameStats = paint_big_tree(-1);
    const parallel: raven.RFrameStats = paint_big_tree(4);

    t.CHECK(@src(), serial.widget_count > 9000, "serial.widget_count > 9000");
    t.CHECK(@src(), serial.paint_job_count == 0, "serial.paint_job_count == 0");
    t.CHECK(@src(), parallel.paint_job_count > 0, "parallel.paint_job_count > 0");
    // the same widgets produce the same primitives and the same batches
    t.CHECK(@src(), parallel.widget_count == serial.widget_count, "parallel.widget_count == serial.widget_count");
    t.CHECK(@src(), parallel.instance_count == serial.instance_count, "parallel.instance_count == serial.instance_count");
    t.CHECK(@src(), parallel.draw_call_count == serial.draw_call_count, "parallel.draw_call_count == serial.draw_call_count");
    t.CHECK(@src(), serial.instance_count > 20000, "serial.instance_count > 20000");
    // text and shapes share one batch: thousands of widgets, a handful of draw calls
    t.CHECK(@src(), serial.draw_call_count <= 2, "serial.draw_call_count <= 2");
    _ = t.printf("  %u widgets, %u instances, %u draw call(s); paint %.2f ms serial, %.2f ms with %u jobs\n", //
        @as(c_uint, serial.widget_count), @as(c_uint, serial.instance_count), @as(c_uint, serial.draw_call_count), serial.paint_ms, parallel.paint_ms, //
        @as(c_uint, parallel.paint_job_count));
}

export fn main() c_int {
    var window: raven.Rid = undefined;
    if (t.test_init(4) == 0) {
        _ = t.printf("cannot initialize Raven\n");
        return 1;
    }
    window = raven.Rwindow_create("threads", 400, 300, raven.R_WINDOW_DEFAULT);
    g_label = raven.Rlabel_create("start");
    raven.Rwindow_set_content(window, g_label);

    t.RUN(test_jobs, "test_jobs");
    t.RUN(test_async_texture, "test_async_texture");
    raven.Rshutdown();

    t.RUN(test_parallel_paint, "test_parallel_paint");
    return t.test_report("test_threads");
}
