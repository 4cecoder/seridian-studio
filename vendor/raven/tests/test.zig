// Translated to Zig from vendor/raven/tests/test.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - minimal test harness: no dependency, one executable per file.
//
// The C macros take the text of their condition (#condition) and the place of the check
// (__FILE__, __LINE__); in Zig the caller passes @src() and the text:
//
//     t.CHECK(@src(), raven.Rwidget_is_visible(w) != 0, "Rwidget_is_visible(w)");
//
// Each test program is one Zig object (zig build-obj), linked with libraven.a by CMake
// through the C ABI exactly like the C test was (tests/CMakeLists.txt). It exports `main`.

const std = @import("std");
const raven = @import("raven");

pub const Src = std.builtin.SourceLocation;

// ---- the C library functions the tests call (no @cImport in Zig 0.18) ----
pub extern "c" fn printf(format: [*:0]const u8, ...) c_int;
pub extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) c_int;
pub extern "c" fn strlen(text: [*c]const u8) usize;
pub extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern "c" fn strncmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
pub extern "c" fn strstr(haystack: [*c]const u8, needle: [*c]const u8) [*c]u8;
pub extern "c" fn strchr(text: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;
pub extern "c" fn fabs(x: f64) f64;

pub var g_test_checks: c_int = 0;
pub var g_test_failures: c_int = 0;
pub var g_test_errors: c_int = 0;
pub var g_test_expect_errors: c_int = 0;

/// CHECK(condition)
pub fn CHECK(src: Src, condition: bool, text: [*:0]const u8) void {
    g_test_checks += 1;
    if (!condition) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: %s\n", src.file.ptr, @as(c_int, @intCast(src.line)), text);
    }
}

/// CHECK_NEAR(actual, expected)
pub fn CHECK_NEAR(src: Src, actual: f64, expected: f64, text: [*:0]const u8) void {
    const test_a_: f64 = actual;
    const test_e_: f64 = expected;
    g_test_checks += 1;
    if (fabs(test_a_ - test_e_) > 0.51) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: %s = %g, expected %g\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, test_a_, test_e_);
    }
}

/// CHECK_STR(actual, expected)
pub fn CHECK_STR(src: Src, actual: [*c]const u8, expected: [*c]const u8, text: [*:0]const u8) void {
    const test_a_: [*c]const u8 = actual;
    const test_e_: [*c]const u8 = expected;
    g_test_checks += 1;
    if (test_a_ == null or strcmp(test_a_, test_e_) != 0) {
        g_test_failures += 1;
        const shown: [*c]const u8 = if (test_a_ != null) test_a_ else "(null)";
        _ = printf("  FAIL %s:%d: %s = \"%s\", expected \"%s\"\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, shown, test_e_);
    }
}

/// Bounds of a widget in its window. CHECK_RECT(widget, ex, ey, ew, eh)
pub fn CHECK_RECT(src: Src, widget: raven.Rid, ex: f64, ey: f64, ew: f64, eh: f64, text: [*:0]const u8) void {
    var test_x_: f32 = 0;
    var test_y_: f32 = 0;
    var test_w_: f32 = 0;
    var test_h_: f32 = 0;
    raven.Rwidget_get_rect(widget, &test_x_, &test_y_, &test_w_, &test_h_);
    g_test_checks += 1;
    if (fabs(@as(f64, test_x_) - ex) > 0.51 or fabs(@as(f64, test_y_) - ey) > 0.51 or fabs(@as(f64, test_w_) - ew) > 0.51 or fabs(@as(f64, test_h_) - eh) > 0.51) {
        g_test_failures += 1;
        _ = printf("  FAIL %s:%d: rect of %s = (%g, %g, %g, %g), expected (%g, %g, %g, %g)\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, //
            @as(f64, test_x_), @as(f64, test_y_), @as(f64, test_w_), @as(f64, test_h_), ex, ey, ew, eh);
    }
}

/// Errors raised by the library fail the test, unless the test announced them.
pub fn test_error_callback(code: raven.RError, severity: raven.RSeverity, detail: [*c]const u8) callconv(.c) void {
    g_test_errors += 1;
    if (g_test_expect_errors == 0) {
        g_test_failures += 1;
        _ = printf("  UNEXPECTED ERROR %s (%s): %s\n", raven.Rerror_to_string(code), raven.Rseverity_to_string(severity), detail);
    }
}

pub fn EXPECT_ERRORS_BEGIN() void {
    g_test_expect_errors = 1;
    g_test_errors = 0;
}

/// EXPECT_ERRORS_END(minimum)
pub fn EXPECT_ERRORS_END(src: Src, minimum: c_int, text: [*:0]const u8) void {
    g_test_expect_errors = 0;
    CHECK(src, g_test_errors >= minimum, text);
}

/// Starts the library without a window system and without a GPU.
pub fn test_init(worker_threads: c_int) c_int {
    var desc: raven.RInitDesc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = raven.R_BACKEND_NULL;
    desc.headless = raven.R_TRUE;
    desc.worker_threads = worker_threads;
    raven.Rerror_set_callback(test_error_callback);
    if (raven.Rinit_ex(&desc) == 0) return 0;
    // the tests read the state right after an input: no animation in between
    raven.Rset_animations_enabled(raven.R_FALSE);
    return 1;
}

/// RUN(function)
pub fn RUN(comptime function: fn () void, name: [*:0]const u8) void {
    _ = printf("%s\n", name);
    function();
}

/// Called after Rshutdown: besides the checks of the test, the library must have freed everything.
pub fn test_report(name: [*:0]const u8) c_int {
    var memory: raven.RMemoryStats = std.mem.zeroes(raven.RMemoryStats);
    raven.Rmemory_get_stats(&memory);
    g_test_checks += 1;
    if (memory.allocation_count != 0) {
        g_test_failures += 1;
        _ = printf("  FAIL: %u allocation(s) of the library are still alive after Rshutdown\n", @as(c_uint, @intCast(memory.allocation_count)));
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
pub fn test_click(window: raven.Rid, widget: raven.Rid) void {
    var x: f32 = 0;
    var y: f32 = 0;
    var w: f32 = 0;
    var h: f32 = 0;
    raven.Rwidget_get_rect(widget, &x, &y, &w, &h);
    raven.Rwindow_inject_mouse_move(window, x + w * 0.5, y + h * 0.5);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
}

pub fn test_click_at(window: raven.Rid, x: f32, y: f32) void {
    raven.Rwindow_inject_mouse_move(window, x, y);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(window, raven.R_MOUSE_LEFT, raven.R_FALSE);
}

pub fn test_key(window: raven.Rid, key: raven.RKey, modifiers: raven.Ruint) void {
    raven.Rwindow_inject_key(window, key, raven.R_TRUE, modifiers);
    raven.Rwindow_inject_key(window, key, raven.R_FALSE, modifiers);
}

/// The panic handler of the test programs: a trap in the safe build prints its message and aborts
/// (the standard handler would drag the stack trace machinery into an object linked by the C compiler).
/// Each test root file has `pub const panic = t.panic;`.
extern "c" fn abort() noreturn;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
fn testPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    const prefix = "Raven test (Zig) panic: ";
    _ = write(2, prefix.ptr, prefix.len);
    _ = write(2, msg.ptr, msg.len);
    _ = write(2, "\n", 1);
    abort();
}
pub const panic = std.debug.FullPanic(testPanic);
