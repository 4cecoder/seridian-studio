// Seridian addition (not in upstream Raven): tests of Rset_window_class / Rget_window_class, the X11 WM_CLASS of
// the windows Raven creates. Run by check.sh (step 6) against the libraven.a it built:
//
//   zig test tests/window_class_test.zig --dep raven -Mroot=tests/window_class_test.zig -Mraven=src/raven/raven.zig \
//       -lc <build>/libraven.a -lX11 -lm -lpthread -ldl
//
// The X11 part opens a hidden (never mapped) window on $DISPLAY and reads its WM_CLASS back through a second
// connection; it is skipped when no X server answers.

const std = @import("std");
const raven = @import("raven");

const Display = opaque {};
const XClassHint = extern struct {
    res_name: ?[*:0]u8,
    res_class: ?[*:0]u8,
};
extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(display: *Display) c_int;
extern "X11" fn XGetClassHint(display: *Display, window: c_ulong, hint: *XClassHint) c_int;
extern "X11" fn XFree(data: ?*anyopaque) c_int;

fn current() struct { name: []const u8, class: []const u8 } {
    var name: [*c]const u8 = null;
    var class: [*c]const u8 = null;
    raven.Rget_window_class(&name, &class);
    return .{ .name = std.mem.span(@as([*:0]const u8, @ptrCast(name))), .class = std.mem.span(@as([*:0]const u8, @ptrCast(class))) };
}

test "Rget_window_class: default is raven / raven" {
    raven.Rset_window_class(null, null);
    const now = current();
    try std.testing.expectEqualStrings("raven", now.name);
    try std.testing.expectEqualStrings("raven", now.class);
}

test "Rset_window_class: class defaults to the name, empty strings restore the default" {
    defer raven.Rset_window_class(null, null);
    raven.Rset_window_class("seridian-studio", null);
    try std.testing.expectEqualStrings("seridian-studio", current().name);
    try std.testing.expectEqualStrings("seridian-studio", current().class);

    raven.Rset_window_class("seridian-studio", "Seridian-Studio");
    try std.testing.expectEqualStrings("seridian-studio", current().name);
    try std.testing.expectEqualStrings("Seridian-Studio", current().class);

    raven.Rset_window_class("", "");
    try std.testing.expectEqualStrings("raven", current().name);
    try std.testing.expectEqualStrings("raven", current().class);
}

test "Rset_window_class: long names are truncated to 63 bytes" {
    defer raven.Rset_window_class(null, null);
    var long: [101]u8 = undefined;
    @memset(long[0..100], 'a');
    long[100] = 0;
    raven.Rset_window_class(&long, null);
    try std.testing.expectEqual(@as(usize, 63), current().name.len);
    try std.testing.expectEqual(@as(usize, 63), current().class.len);
}

test "Rget_window_class: either out pointer may be NULL" {
    var class: [*c]const u8 = null;
    raven.Rget_window_class(null, &class);
    try std.testing.expect(class != null);
    raven.Rget_window_class(null, null);
}

test "X11: a window carries the WM_CLASS given by Rset_window_class" {
    const probe = XOpenDisplay(null) orelse return error.SkipZigTest;
    defer _ = XCloseDisplay(probe);

    raven.Rset_window_class("seridian-studio", null);
    defer raven.Rset_window_class(null, null);
    const desc: raven.RInitDesc = .{ .backend = raven.R_BACKEND_NULL, .disable_render_thread = raven.R_TRUE, .worker_threads = -1 };
    if (raven.Rinit_ex(&desc) == 0) return error.SkipZigTest;
    defer raven.Rshutdown();

    const window = raven.Rwindow_create("window class test", 64, 64, raven.R_WINDOW_HIDDEN);
    try std.testing.expect(window != raven.R_INVALID_ID);
    defer raven.Rwindow_destroy(window);
    var native: raven.RNativeWindow = .{};
    try std.testing.expect(raven.Rwindow_get_native_handle(window, &native) != 0);
    if (native.system != raven.R_WINDOW_SYSTEM_X11) return error.SkipZigTest;

    var hint: XClassHint = .{ .res_name = null, .res_class = null };
    try std.testing.expect(XGetClassHint(probe, native.window, &hint) != 0);
    defer _ = XFree(hint.res_name);
    defer _ = XFree(hint.res_class);
    try std.testing.expectEqualStrings("seridian-studio", std.mem.span(hint.res_name orelse return error.TestUnexpectedResult));
    try std.testing.expectEqualStrings("seridian-studio", std.mem.span(hint.res_class orelse return error.TestUnexpectedResult));
}
