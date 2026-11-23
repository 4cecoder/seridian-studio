// Translated to Zig from vendor/raven/web/tests/test_web.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
// The harness of vendor/raven/tests/test.h that it uses (CHECK, CHECK_NEAR, CHECK_STR, EXPECT_ERRORS_*, test_init,
// test_report, test_click, RUN) is translated here too. Built by web/CMakeLists.txt into an object whose C `main`
// is linked with the library like the C test was; exit status 0 = pass, 77 = no browser (skipped), 1 = failure.
//
// Raven Web tests.
//
// The first part needs nothing: JSON, base64, a view without a browser.
// The second part drives a real browser (hidden) and checks the whole way:
// a page is loaded, its picture arrives, a click and typed text reach it,
// scripts run, the page talks back. It is skipped (exit code 77) when no
// browser of the Chromium family is found; RAVEN_WEB_BROWSER names one.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const rweb = @import("raven_web");
const web = @import("web_internal");

const Rid = raven.Rid;

extern "c" fn printf(format: [*c]const u8, ...) c_int;
extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
extern "c" fn strncmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
extern "c" fn strstr(haystack: [*c]const u8, needle: [*c]const u8) [*c]const u8;
extern "c" fn strlen(s: [*c]const u8) usize;
extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
extern "c" fn getenv(name: [*c]const u8) [*c]const u8;
extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*anyopaque;
extern "c" fn fputs(text: [*c]const u8, file: ?*anyopaque) c_int;
extern "c" fn fclose(file: ?*anyopaque) c_int;
extern "c" fn remove(path: [*c]const u8) c_int;

// Raven's library is built without the stack probe and the compiler runtime (cmake/RavenZig.cmake); this object
// follows it, with a panic that does not drag the stack trace machinery in.
extern "c" fn abort() noreturn;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
fn testPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    _ = write(2, "test_web (Zig) panic: ", 22);
    _ = write(2, msg.ptr, msg.len);
    _ = write(2, "\n", 1);
    abort();
}
pub const panic = std.debug.FullPanic(testPanic);

// ---------------------------------------------------------------------------
//  The harness (tests/test.h)
// ---------------------------------------------------------------------------

var g_test_checks: c_int = 0;
var g_test_failures: c_int = 0;
var g_test_errors: c_int = 0;
var g_test_expect_errors: c_int = 0;

/// CHECK(condition)
fn CHECK(condition: bool, src: std.builtin.SourceLocation, text: [*c]const u8) void {
    g_test_checks += 1;
    if (!condition) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: %s\n", src.file.ptr, @as(c_int, @intCast(src.line)), text);
    }
}

/// CHECK_NEAR(actual, expected)
fn CHECK_NEAR(actual: f64, expected: f64, src: std.builtin.SourceLocation, text: [*c]const u8) void {
    g_test_checks += 1;
    if (@abs(actual - expected) > 0.51) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: %s = %g, expected %g\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, actual, expected);
    }
}

/// CHECK_STR(actual, expected)
fn CHECK_STR(actual: [*c]const u8, expected: [*c]const u8, src: std.builtin.SourceLocation, text: [*c]const u8) void {
    g_test_checks += 1;
    if (actual == null or strcmp(actual, expected) != 0) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: %s = \"%s\", expected \"%s\"\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, if (actual != null) actual else @as([*c]const u8, "(null)"), expected);
    }
}

/// Errors raised by the library fail the test, unless the test announced them.
fn test_error_callback(code: raven.RError, severity: raven.RSeverity, detail: [*c]const u8) callconv(.c) void {
    g_test_errors += 1;
    if (g_test_expect_errors == 0) {
        g_test_failures += 1;
        _ = printf("  UNEXPECTED ERROR %s (%s): %s\n", raven.Rerror_to_string(code), raven.Rseverity_to_string(severity), detail);
    }
}

fn EXPECT_ERRORS_BEGIN() void {
    g_test_expect_errors = 1;
    g_test_errors = 0;
}

fn EXPECT_ERRORS_END(minimum: c_int, src: std.builtin.SourceLocation) void {
    g_test_expect_errors = 0;
    CHECK(g_test_errors >= minimum, src, "g_test_errors >= (minimum)");
}

/// Starts the library without a window system and without a GPU.
fn test_init(worker_threads: c_int) bool {
    var desc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = raven.R_BACKEND_NULL;
    desc.headless = raven.R_TRUE;
    desc.worker_threads = worker_threads;
    raven.Rerror_set_callback(&test_error_callback);
    if (raven.Rinit_ex(&desc) == 0) return false;
    // the tests read the state right after an input: no animation in between
    raven.Rset_animations_enabled(raven.R_FALSE);
    return true;
}

fn RUN(comptime function: fn () void, name: [*c]const u8) void {
    _ = printf("%s\n", name);
    function();
}

/// Called after Rshutdown: besides the checks of the test, the library must have freed everything.
fn test_report(name: [*c]const u8) c_int {
    var memory: raven.RMemoryStats = undefined;
    raven.Rmemory_get_stats(&memory);
    g_test_checks += 1;
    if (memory.allocation_count != 0) {
        g_test_failures += 1;
        _ = printf("  FAIL: %u allocation(s) of the library are still alive after Rshutdown\n", @as(c_uint, @truncate(memory.allocation_count)));
    }
    g_test_checks += 1;
    if (raven.Rmemory_check() == 0) {
        g_test_failures += 1;
        _ = printf("  FAIL: the heap of the library is corrupted\n");
    }
    _ = printf("%s: %d checks, %d failures\n", name, g_test_checks, g_test_failures);
    return if (g_test_failures == 0) 0 else 1;
}

/// Moves the cursor to the middle of a widget and clicks.
fn test_click(window: Rid, widget: Rid) void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rwidget_get_rect(widget, &x, &y, &w, &h);
    raven.Rwindow_inject_mouse_move(window, x + w * 0.5, y + h * 0.5);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
}

// ---------------------------------------------------------------------------
//  Without a browser
// ---------------------------------------------------------------------------

fn test_json() void {
    var text = "{\"id\":7,\"result\":{\"name\":\"a\\\"b\\\\c\\n\\u00e9\\ud83d\\ude00\",\"list\":[1,2.5,-3e2,true,false,null],\"empty\":{},\"deep\":{\"x\":{\"y\":\"z\"}}}}".*;
    var broken = "{\"a\":[1,2}".*;
    var document: web.rw_json_document_t = undefined;
    var out: web.rw_text_t = undefined;

    CHECK(web.rw_json_parse(&document, &text, strlen(&text)) != 0, @src(), "rw_json_parse(&document, text, strlen(text))");
    CHECK_NEAR(web.rw_json_number(document.root, "id", 0.0), 7.0, @src(), "rw_json_number(document.root, \"id\", 0.0)");
    CHECK_STR(web.rw_json_string(document.root, "result.name", ""), "a\"b\\c\n\xC3\xA9\xF0\x9F\x98\x80", @src(), "rw_json_string(document.root, \"result.name\", \"\")");
    CHECK_STR(web.rw_json_string(document.root, "result.deep.x.y", ""), "z", @src(), "rw_json_string(document.root, \"result.deep.x.y\", \"\")");
    CHECK(web.rw_json_get(document.root, "result.missing") == null, @src(), "rw_json_get(document.root, \"result.missing\") == NULL");
    CHECK(web.rw_json_get(document.root, "result.name.inside") == null, @src(), "rw_json_get(document.root, \"result.name.inside\") == NULL");
    CHECK_STR(web.rw_json_string(document.root, "result.missing", "fallback"), "fallback", @src(), "rw_json_string(document.root, \"result.missing\", \"fallback\")");
    {
        const list = web.rw_json_get(document.root, "result.list");
        var item: [*c]const web.rw_json_t = if (list != null) list.*.first else null;
        CHECK(list != null and list.*.type == web.RW_JSON_ARRAY, @src(), "list && list->type == RW_JSON_ARRAY");
        CHECK(item != null and item.*.number == 1.0, @src(), "item && item->number == 1.0");
        item = if (item != null) item.*.next else null;
        CHECK(item != null and item.*.number == 2.5, @src(), "item && item->number == 2.5");
        item = if (item != null) item.*.next else null;
        CHECK(item != null and item.*.number == -300.0, @src(), "item && item->number == -300.0");
        item = if (item != null) item.*.next else null;
        CHECK(item != null and item.*.type == web.RW_JSON_BOOL and item.*.number == 1.0, @src(), "item && item->type == RW_JSON_BOOL && item->number == 1.0");
        item = if (item != null) item.*.next else null;
        CHECK(item != null and item.*.type == web.RW_JSON_BOOL and item.*.number == 0.0, @src(), "item && item->type == RW_JSON_BOOL && item->number == 0.0");
        item = if (item != null) item.*.next else null;
        CHECK(item != null and item.*.type == web.RW_JSON_NULL and item.*.next == null, @src(), "item && item->type == RW_JSON_NULL && item->next == NULL");
    }
    // written back, it reads the same
    out = std.mem.zeroes(web.rw_text_t);
    web.rw_json_write(&out, web.rw_json_get(document.root, "result.list"));
    CHECK_STR(out.data, "[1,2.5,-300,true,false,null]", @src(), "out.data");
    web.rw_text_free(&out);
    out = std.mem.zeroes(web.rw_text_t);
    web.rw_json_write(&out, web.rw_json_get(document.root, "result.deep"));
    CHECK_STR(out.data, "{\"x\":{\"y\":\"z\"}}", @src(), "out.data");
    web.rw_text_free(&out);
    web.rw_json_free(&document);

    CHECK(web.rw_json_parse(&document, &broken, strlen(&broken)) == 0, @src(), "!rw_json_parse(&document, broken, strlen(broken))");

    out = std.mem.zeroes(web.rw_text_t);
    web.rw_text_json(&out, "tab\there \"quoted\" back\\slash\nline \x01");
    CHECK_STR(out.data, "\"tab\\there \\\"quoted\\\" back\\\\slash\\nline \\u0001\"", @src(), "out.data");
    web.rw_text_printf(&out, " %d %s", @as(c_int, 42), "end");
    CHECK(strstr(out.data, " 42 end") != null, @src(), "strstr(out.data, \" 42 end\") != NULL");
    web.rw_text_free(&out);
}

fn test_base64() void {
    var size: usize = 0;
    var bytes = web.rw_base64_decode("SGVsbG8sIFJhdmVuIQ==", 20, &size);
    CHECK(bytes != null and size == 13 and memcmp(bytes, "Hello, Raven!", 13) == 0, @src(), "bytes && size == 13 && memcmp(bytes, \"Hello, Raven!\", 13) == 0");
    web.rw_free(bytes);
    bytes = web.rw_base64_decode("QQ==", 4, &size);
    CHECK(bytes != null and size == 1 and bytes[0] == 'A', @src(), "bytes && size == 1 && bytes[0] == 'A'");
    web.rw_free(bytes);
    bytes = web.rw_base64_decode("QUI=", 4, &size);
    CHECK(bytes != null and size == 2 and bytes[1] == 'B', @src(), "bytes && size == 2 && bytes[1] == 'B'");
    web.rw_free(bytes);
    bytes = web.rw_base64_decode("not base64!", 11, &size);
    CHECK(bytes == null, @src(), "bytes == NULL");
}

var g_events: [8]c_int = std.mem.zeroes([8]c_int);
fn on_web_event(view: Rid, event: rweb.RWebEvent, user_data: ?*anyopaque) callconv(.c) void {
    _ = view;
    _ = user_data;
    if (event >= rweb.R_WEB_EVENT_NAVIGATED and event <= rweb.R_WEB_EVENT_FAILED) g_events[event - @as(rweb.RWebEvent, rweb.R_WEB_EVENT_NAVIGATED)] += 1;
}

var g_script_calls: c_int = 0;
var g_script_result: [256]u8 = std.mem.zeroes([256]u8);
var g_script_error: [256]u8 = std.mem.zeroes([256]u8);
fn on_script(view: Rid, result: [*c]const u8, @"error": [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = view;
    _ = user_data;
    g_script_calls += 1;
    _ = snprintf(&g_script_result, g_script_result.len, "%s", if (result != null) result else @as([*c]const u8, "(none)"));
    _ = snprintf(&g_script_error, g_script_error.len, "%s", if (@"error" != null) @"error" else @as([*c]const u8, ""));
}

/// A view when there is no browser: it says so, and everything stays safe to call.
fn test_without_browser() void {
    CHECK(test_init(0), @src(), "test_init(0)");
    rweb.Rweb_set_browser_path("/nowhere/no-such-browser");
    CHECK(rweb.Rweb_is_available() == 0, @src(), "!Rweb_is_available()");
    CHECK_STR(rweb.Rweb_get_browser_path(), "", @src(), "Rweb_get_browser_path()");

    const window = raven.Rwindow_create("web", 640, 480, 0);
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rwindow_set_content(window, box);
    const view = rweb.Rweb_view_create();
    CHECK(view != raven.R_INVALID_ID and rweb.Rweb_view_is_valid(view) != 0, @src(), "view != R_INVALID_ID && Rweb_view_is_valid(view)");
    CHECK(rweb.Rweb_view_is_valid(box) == 0, @src(), "!Rweb_view_is_valid(box)");
    _ = raven.Rwidget_add_child(box, view);
    g_events = std.mem.zeroes([8]c_int);
    rweb.Rweb_view_set_event_callback(view, &on_web_event, null);
    CHECK(rweb.Rweb_view_is_ready(view) == 0, @src(), "!Rweb_view_is_ready(view)");
    CHECK(strstr(rweb.Rweb_view_get_error(view), "no-such-browser") != null, @src(), "strstr(Rweb_view_get_error(view), \"no-such-browser\") != NULL");
    rweb.Rweb_view_load_url(view, "https://example.org");
    rweb.Rweb_view_load_html(view, "<p>x</p>", null);
    rweb.Rweb_view_reload(view);
    rweb.Rweb_view_go_back(view);
    CHECK(rweb.Rweb_view_can_go_back(view) == 0 and rweb.Rweb_view_can_go_forward(view) == 0, @src(), "!Rweb_view_can_go_back(view) && !Rweb_view_can_go_forward(view)");
    CHECK_STR(rweb.Rweb_view_get_url(view), "", @src(), "Rweb_view_get_url(view)");
    CHECK(rweb.Rweb_view_is_loading(view) == 0, @src(), "!Rweb_view_is_loading(view)");
    g_script_calls = 0;
    rweb.Rweb_view_run_javascript(view, "1 + 1", &on_script, null);
    CHECK(g_script_calls == 1 and g_script_error[0] != 0, @src(), "g_script_calls == 1 && g_script_error[0] != 0");
    rweb.Rweb_view_set_zoom(view, 1.5);
    CHECK_NEAR(rweb.Rweb_view_get_zoom(view) * 100.0, 150.0, @src(), "Rweb_view_get_zoom(view) * 100.0f");
    _ = raven.Rdraw_frame();
    test_click(window, view);
    raven.Rwindow_inject_text(window, "abc");
    _ = raven.Rdraw_frame();

    // the tag exists once registered, and knows its attributes
    {
        const xml = "<VBox><WebView Name=\"page\" Url=\"about:blank\" Zoom=\"1.25\" Frames=\"Jpeg\" Quality=\"70\" Slot.Fill=\"1\"/></VBox>";
        EXPECT_ERRORS_BEGIN();
        CHECK(raven.Rwidget_create_from_xml(xml, xml.len) == raven.R_INVALID_ID, @src(), "Rwidget_create_from_xml(xml, strlen(xml)) == R_INVALID_ID");
        EXPECT_ERRORS_END(1, @src());
        rweb.Rweb_register_xml();
        CHECK(raven.Rxml_is_tag_registered("WebView") != 0, @src(), "Rxml_is_tag_registered(\"WebView\")");
        const tree = raven.Rwidget_create_from_xml(xml, xml.len);
        CHECK(tree != raven.R_INVALID_ID, @src(), "tree != R_INVALID_ID");
        const page = raven.Rwidget_get_child(tree, 0);
        CHECK(rweb.Rweb_view_is_valid(page) != 0, @src(), "Rweb_view_is_valid(page)");
        CHECK_STR(raven.Rwidget_get_name(page), "page", @src(), "Rwidget_get_name(page)");
        CHECK_NEAR(rweb.Rweb_view_get_zoom(page) * 100.0, 125.0, @src(), "Rweb_view_get_zoom(page) * 100.0f");
        CHECK(raven.Rwidget_set_attribute(page, "Zoom", "2") != 0, @src(), "Rwidget_set_attribute(page, \"Zoom\", \"2\")");
        CHECK_NEAR(rweb.Rweb_view_get_zoom(page) * 100.0, 200.0, @src(), "Rweb_view_get_zoom(page) * 100.0f");
        EXPECT_ERRORS_BEGIN();
        CHECK(raven.Rwidget_set_attribute(page, "NoSuchAttribute", "1") == 0, @src(), "!Rwidget_set_attribute(page, \"NoSuchAttribute\", \"1\")");
        EXPECT_ERRORS_END(0, @src());
        raven.Rwidget_destroy(tree);
    }

    raven.Rwidget_destroy(view);
    _ = raven.Rdraw_frame();
    CHECK(rweb.Rweb_view_is_valid(view) == 0, @src(), "!Rweb_view_is_valid(view)");
    rweb.Rweb_shutdown();
    raven.Rshutdown();
}

// ---------------------------------------------------------------------------
//  With a browser
// ---------------------------------------------------------------------------

var g_messages: c_int = 0;
var g_message: [512]u8 = std.mem.zeroes([512]u8);
fn on_message(view: Rid, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = view;
    _ = user_data;
    g_messages += 1;
    _ = snprintf(&g_message, g_message.len, "%s", message);
}

/// Runs the loop until `*flag` reaches `wanted`, for a few seconds at most.
fn pump(flag: *const c_int, wanted: c_int, seconds: f64) bool {
    const start = raven.Rget_time();
    while (@as(*const volatile c_int, flag).* < wanted and raven.Rget_time() - start < seconds) _ = raven.Rwait_frame(0.02);
    return @as(*const volatile c_int, flag).* >= wanted;
}

fn pump_for(seconds: f64) void {
    const start = raven.Rget_time();
    while (raven.Rget_time() - start < seconds) _ = raven.Rwait_frame(0.02);
}

const g_page =
    "<!doctype html><html><head><title>Raven test page</title>" ++
    "<style>html,body{margin:0;background:#204080;} #b{position:absolute;left:40px;top:40px;width:200px;height:80px;}" ++
    " #t{position:absolute;left:40px;top:160px;width:300px;height:30px;font-size:18px;}</style></head>" ++
    "<body><button id='b' onclick=\"window.raven.postMessage('clicked')\">Click</button>" ++
    "<input id='t' oninput=\"window.raven.postMessage({typed: this.value})\">" ++
    "<script>window.raven.postMessage('ready');</script></body></html>";

/// Waits until the title of the view is `title`, for 10 seconds at most.
fn wait_title(view: Rid, title: [*c]const u8) void {
    const start = raven.Rget_time();
    while (strcmp(rweb.Rweb_view_get_title(view), title) != 0 and raven.Rget_time() - start < 10.0) _ = raven.Rwait_frame(0.02);
}

fn test_with_browser() void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var path: [512]u8 = undefined;

    CHECK(test_init(0), @src(), "test_init(0)");
    rweb.Rweb_set_browser_path(null);
    const window = raven.Rwindow_create("web", 800, 600, 0);
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rwindow_set_content(window, box);
    const view = rweb.Rweb_view_create();
    _ = raven.Rwidget_add_child(box, view);
    raven.Rslot_set_fill(view, 1.0);
    CHECK_STR(rweb.Rweb_view_get_error(view), "", @src(), "Rweb_view_get_error(view)");
    g_events = std.mem.zeroes([8]c_int);
    g_messages = 0;
    rweb.Rweb_view_set_event_callback(view, &on_web_event, null);
    rweb.Rweb_view_set_message_callback(view, &on_message, null);
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(view, &x, &y, &w, &h);
    CHECK_NEAR(w, 800.0, @src(), "w");
    CHECK_NEAR(h, 600.0, @src(), "h");

    // a page given as text: its script runs and talks to the application
    rweb.Rweb_view_load_html(view, g_page, null);
    CHECK(pump(&g_messages, 1, 30.0), @src(), "pump(&g_messages, 1, 30.0)");
    CHECK_STR(&g_message, "ready", @src(), "g_message");
    CHECK(rweb.Rweb_view_is_ready(view) != 0, @src(), "Rweb_view_is_ready(view)");
    CHECK_STR(rweb.Rweb_view_get_error(view), "", @src(), "Rweb_view_get_error(view)");

    // its title arrives
    _ = pump(&g_events[@intCast(rweb.R_WEB_EVENT_TITLE - rweb.R_WEB_EVENT_NAVIGATED)], 1, 10.0);
    wait_title(view, "Raven test page");
    CHECK_STR(rweb.Rweb_view_get_title(view), "Raven test page", @src(), "Rweb_view_get_title(view)");

    // scripts: a number, text, an object, a promise, an error
    g_script_calls = 0;
    rweb.Rweb_view_run_javascript(view, "6 * 7", &on_script, null);
    CHECK(pump(&g_script_calls, 1, 10.0), @src(), "pump(&g_script_calls, 1, 10.0)");
    CHECK_STR(&g_script_result, "42", @src(), "g_script_result");
    CHECK_STR(&g_script_error, "", @src(), "g_script_error");
    rweb.Rweb_view_run_javascript(view, "document.title + '!'", &on_script, null);
    CHECK(pump(&g_script_calls, 2, 10.0), @src(), "pump(&g_script_calls, 2, 10.0)");
    CHECK_STR(&g_script_result, "\"Raven test page!\"", @src(), "g_script_result");
    rweb.Rweb_view_run_javascript(view, "({a: [1, 2], b: 'x'})", &on_script, null);
    CHECK(pump(&g_script_calls, 3, 10.0), @src(), "pump(&g_script_calls, 3, 10.0)");
    CHECK_STR(&g_script_result, "{\"a\":[1,2],\"b\":\"x\"}", @src(), "g_script_result");
    rweb.Rweb_view_run_javascript(view, "new Promise(function(done){ setTimeout(function(){ done('later'); }, 50); })", &on_script, null);
    CHECK(pump(&g_script_calls, 4, 10.0), @src(), "pump(&g_script_calls, 4, 10.0)");
    CHECK_STR(&g_script_result, "\"later\"", @src(), "g_script_result");
    rweb.Rweb_view_run_javascript(view, "noSuchFunction()", &on_script, null);
    CHECK(pump(&g_script_calls, 5, 10.0), @src(), "pump(&g_script_calls, 5, 10.0)");
    CHECK_STR(&g_script_result, "(none)", @src(), "g_script_result");
    CHECK(strstr(&g_script_error, "noSuchFunction") != null, @src(), "strstr(g_script_error, \"noSuchFunction\") != NULL");

    // its picture arrives, at the size of the widget
    if (!build_options.no_image_decoder) {
        const start = raven.Rget_time();
        var width: c_int = 0;
        var height: c_int = 0;
        while (raven.Rget_time() - start < 15.0) {
            const texture = rweb.Rweb_view_get_texture(view);
            if (texture != raven.R_INVALID_ID) raven.Rtexture_get_size(texture, &width, &height);
            if (width == 800 and height == 600) break;
            _ = raven.Rwait_frame(0.02);
        }
        CHECK(width == 800 and height == 600, @src(), "width == 800 && height == 600");
    } else {
        CHECK(rweb.Rweb_view_get_texture(view) == raven.R_INVALID_ID, @src(), "Rweb_view_get_texture(view) == R_INVALID_ID");
    }

    // the size of the page is the size of the widget
    rweb.Rweb_view_run_javascript(view, "window.innerWidth + 'x' + window.innerHeight", &on_script, null);
    CHECK(pump(&g_script_calls, 6, 10.0), @src(), "pump(&g_script_calls, 6, 10.0)");
    CHECK_STR(&g_script_result, "\"800x600\"", @src(), "g_script_result");

    // a click in the widget is a click in the page
    g_messages = 0;
    raven.Rwindow_inject_mouse_move(window, x + 140.0, y + 80.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    CHECK(pump(&g_messages, 1, 10.0), @src(), "pump(&g_messages, 1, 10.0)");
    CHECK_STR(&g_message, "clicked", @src(), "g_message");

    // text typed in the widget goes to the field that has the focus in the page
    g_messages = 0;
    raven.Rwindow_inject_mouse_move(window, x + 100.0, y + 175.0);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    CHECK(raven.Rwidget_is_focused(view) != 0, @src(), "Rwidget_is_focused(view)");
    pump_for(0.3);
    raven.Rwindow_inject_text(window, "h\xC3\xA9");
    CHECK(pump(&g_messages, 2, 10.0), @src(), "pump(&g_messages, 2, 10.0)");
    CHECK_STR(&g_message, "{\"typed\":\"h\xC3\xA9\"}", @src(), "g_message");
    // a key that is not a character
    raven.Rwindow_inject_key(window, raven.R_KEY_BACKSPACE, raven.R_TRUE, 0);
    raven.Rwindow_inject_key(window, raven.R_KEY_BACKSPACE, raven.R_FALSE, 0);
    CHECK(pump(&g_messages, 3, 10.0), @src(), "pump(&g_messages, 3, 10.0)");
    CHECK_STR(&g_message, "{\"typed\":\"h\"}", @src(), "g_message");

    // files of the computer; the address changes, the history fills
    {
        const folder: [*c]const u8 = if (getenv("TMPDIR") != null) getenv("TMPDIR") else (if (getenv("TEMP") != null) getenv("TEMP") else "/tmp");
        var second: [512]u8 = undefined;
        _ = snprintf(&path, path.len, "%s/raven_web_test_page.html", folder);
        _ = snprintf(&second, second.len, "%s/raven_web_test_page_2.html", folder);
        var file = fopen(&path, "wb");
        CHECK(file != null, @src(), "file != NULL");
        if (file != null) {
            _ = fputs("<!doctype html><title>From a file</title><body style='background:#fff'>" ++
                "<script>window.raven.postMessage('file ready')</script>", file);
            _ = fclose(file);
        }
        file = fopen(&second, "wb");
        CHECK(file != null, @src(), "file != NULL");
        if (file != null) {
            _ = fputs("<!doctype html><title>Second file</title><body><script>window.raven.postMessage('second ready')</script>", file);
            _ = fclose(file);
        }
        g_events = std.mem.zeroes([8]c_int);
        g_messages = 0;
        rweb.Rweb_view_load_file(view, &path);
        CHECK(pump(&g_messages, 1, 15.0), @src(), "pump(&g_messages, 1, 15.0)");
        CHECK_STR(&g_message, "file ready", @src(), "g_message");
        CHECK(strncmp(rweb.Rweb_view_get_url(view), "file://", 7) == 0, @src(), "strncmp(Rweb_view_get_url(view), \"file://\", 7) == 0");
        CHECK(strstr(rweb.Rweb_view_get_url(view), "raven_web_test_page.html") != null, @src(), "strstr(Rweb_view_get_url(view), \"raven_web_test_page.html\") != NULL");
        CHECK(g_events[0] >= 1, @src(), "g_events[R_WEB_EVENT_NAVIGATED - R_WEB_EVENT_NAVIGATED] >= 1");
        wait_title(view, "From a file");
        CHECK_STR(rweb.Rweb_view_get_title(view), "From a file", @src(), "Rweb_view_get_title(view)");
        // (the empty page a view starts on is not somewhere to go back to)
        pump_for(0.3);
        CHECK(rweb.Rweb_view_can_go_back(view) == 0, @src(), "!Rweb_view_can_go_back(view)");

        rweb.Rweb_view_load_file(view, &second);
        CHECK(pump(&g_messages, 2, 15.0), @src(), "pump(&g_messages, 2, 15.0)");
        CHECK_STR(&g_message, "second ready", @src(), "g_message");
        {
            const start = raven.Rget_time();
            while (rweb.Rweb_view_can_go_back(view) == 0 and raven.Rget_time() - start < 10.0) _ = raven.Rwait_frame(0.02);
        }
        CHECK(rweb.Rweb_view_can_go_back(view) != 0, @src(), "Rweb_view_can_go_back(view)");
        CHECK(rweb.Rweb_view_can_go_forward(view) == 0, @src(), "!Rweb_view_can_go_forward(view)");
        rweb.Rweb_view_go_back(view);
        CHECK(pump(&g_messages, 3, 15.0), @src(), "pump(&g_messages, 3, 15.0)");
        CHECK_STR(&g_message, "file ready", @src(), "g_message");
        {
            const start = raven.Rget_time();
            while (rweb.Rweb_view_can_go_forward(view) == 0 and raven.Rget_time() - start < 10.0) _ = raven.Rwait_frame(0.02);
        }
        CHECK(rweb.Rweb_view_can_go_forward(view) != 0, @src(), "Rweb_view_can_go_forward(view)");
        CHECK(strstr(rweb.Rweb_view_get_url(view), "raven_web_test_page.html") != null, @src(), "strstr(Rweb_view_get_url(view), \"raven_web_test_page.html\") != NULL");
        _ = remove(&path);
        _ = remove(&second);
    }

    // a second view shares the browser; deleting one leaves the other working
    {
        const other = rweb.Rweb_view_create();
        _ = raven.Rwidget_add_child(box, other);
        g_script_calls = 0;
        rweb.Rweb_view_run_javascript(other, "'second'", &on_script, null);
        CHECK(pump(&g_script_calls, 1, 15.0), @src(), "pump(&g_script_calls, 1, 15.0)");
        CHECK_STR(&g_script_result, "\"second\"", @src(), "g_script_result");
        raven.Rwidget_destroy(other);
        _ = raven.Rdraw_frame();
        g_script_calls = 0;
        rweb.Rweb_view_run_javascript(view, "'first'", &on_script, null);
        CHECK(pump(&g_script_calls, 1, 10.0), @src(), "pump(&g_script_calls, 1, 10.0)");
        CHECK_STR(&g_script_result, "\"first\"", @src(), "g_script_result");
    }

    raven.Rshutdown();
}

/// RAVEN_TEST_NO_IMAGE_DECODER of the C test (Raven built without stb_image), given by CMake as a module.
const build_options = @import("test_web_options");

export fn main() c_int {
    RUN(test_json, "test_json");
    RUN(test_base64, "test_base64");
    RUN(test_without_browser, "test_without_browser");
    const have_browser = rweb.Rweb_is_available() != 0;
    if (have_browser) {
        RUN(test_with_browser, "test_with_browser");
    } else {
        _ = printf("no browser of the Chromium family found: the tests that need one are skipped\n");
    }
    const result = test_report("test_web");
    if (result == 0 and !have_browser) return 77;
    return result;
}
