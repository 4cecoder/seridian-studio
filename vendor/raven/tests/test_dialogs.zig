// Translated to Zig from vendor/raven/tests/test_dialogs.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - dialogs, message boxes, the file browser and the file dialogs.
//
// The functions that wait for the user (Rdialog_run, Rmessage_box,
// Rfile_dialog_...) are answered by timers: they run the frames of the
// application while they wait, so a timer fires inside them.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h>, <stdio.h>
extern "c" fn getenv(name: [*c]const u8) [*c]u8;
extern "c" fn remove(path: [*c]const u8) c_int;

// #if defined(_WIN32): <direct.h>, <windows.h>
extern "c" fn _mkdir(path: [*c]const u8) c_int;
extern "c" fn _rmdir(path: [*c]const u8) c_int;
extern "kernel32" fn SetFileAttributesA(lpFileName: [*c]const u8, dwFileAttributes: u32) callconv(.winapi) c_int;
const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2; // <windows.h>
// #else: <sys/stat.h>, <unistd.h>
extern "c" fn mkdir(path: [*c]const u8, mode: std.c.mode_t) c_int;
extern "c" fn rmdir(path: [*c]const u8) c_int;

// #define test_mkdir(path) _mkdir(path)        (Windows)
// #define test_mkdir(path) mkdir(path, 0777)   (otherwise)
inline fn test_mkdir(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        return _mkdir(path);
    } else {
        return mkdir(path, 0o777);
    }
}
const TEST_SEPARATOR = if (builtin.os.tag == .windows) "\\" else "/";

var g_root: [512]u8 = std.mem.zeroes([512]u8);

fn in_root(relative: [*c]const u8) [*c]const u8 {
    const S = struct {
        var paths: [4][700]u8 = std.mem.zeroes([4][700]u8);
        var next: c_int = 0;
    };
    const path: [*c]u8 = &S.paths[@intCast(S.next & 3)];
    S.next += 1;
    _ = t.snprintf(path, 700, "%s%s%s", @as([*c]const u8, &g_root), @as([*c]const u8, if (relative[0] != 0) TEST_SEPARATOR else ""), relative);
    return path;
}

fn make_tree() void {
    var temp: [*c]const u8 = getenv("TMPDIR");
    if (builtin.os.tag == .windows) {
        if (temp == null) temp = getenv("TEMP");
        if (temp == null) temp = ".";
    } else {
        if (temp == null) temp = "/tmp";
    }
    {
        // macOS gives TMPDIR with a separator at its end: the file browser writes paths without "//"
        var length: usize = t.strlen(temp);
        while (length > 1 and (temp[length - 1] == '/' or temp[length - 1] == '\\')) length -= 1;
        _ = t.snprintf(&g_root, g_root.len, "%.*s%sraven_test_dialogs_%u", @as(c_int, @intCast(length)), temp, @as([*c]const u8, TEST_SEPARATOR), @as(c_uint, @intFromFloat(raven.Rget_time() * 1e6)) +% 17);
    }
    _ = test_mkdir(&g_root);
    _ = test_mkdir(in_root("sub"));
    _ = test_mkdir(in_root("zeta"));
    t.CHECK(@src(), raven.Rfile_write(in_root("beta.txt"), "beta", 4) != 0, "Rfile_write(in_root(\"beta.txt\"), \"beta\", 4)");
    t.CHECK(@src(), raven.Rfile_write(in_root("alpha.xml"), "<a/>", 4) != 0, "Rfile_write(in_root(\"alpha.xml\"), \"<a/>\", 4)");
    t.CHECK(@src(), raven.Rfile_write(in_root("Gamma.XML"), "<g/>!", 5) != 0, "Rfile_write(in_root(\"Gamma.XML\"), \"<g/>!\", 5)");
    t.CHECK(@src(), raven.Rfile_write(in_root(".hidden"), "", 0) != 0, "Rfile_write(in_root(\".hidden\"), \"\", 0)");
    if (builtin.os.tag == .windows) {
        // on Windows a file is hidden by its attribute, not by its name
        _ = SetFileAttributesA(in_root(".hidden"), FILE_ATTRIBUTE_HIDDEN);
    }
    t.CHECK(@src(), raven.Rfile_write(in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"), "in", 2) != 0, "Rfile_write(in_root(\"sub\" TEST_SEPARATOR \"inner.txt\"), \"in\", 2)");
}

fn remove_tree() void {
    _ = remove(in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"));
    _ = remove(in_root("beta.txt"));
    _ = remove(in_root("alpha.xml"));
    _ = remove(in_root("Gamma.XML"));
    _ = remove(in_root(".hidden"));
    _ = remove(in_root("saved.xml"));
    if (builtin.os.tag == .windows) {
        _ = _rmdir(in_root("sub"));
        _ = _rmdir(in_root("zeta"));
        _ = _rmdir(&g_root);
    } else {
        _ = rmdir(in_root("sub"));
        _ = rmdir(in_root("zeta"));
        _ = rmdir(&g_root);
    }
}

fn window_from(xml: [*c]const u8) raven.Rid {
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    return window;
}

// ---------------------------------------------------------------------------
//  Files
// -------------------------------------------------------------------------

fn test_files() void {
    var size: usize = 99;
    var text: [*c]u8 = raven.Rfile_read(in_root("Gamma.XML"), &size);
    t.CHECK(@src(), text != null, "text != NULL");
    t.CHECK(@src(), size == 5, "size == 5");
    if (text != null) t.CHECK_STR(@src(), text, "<g/>!", "text");
    raven.Rmemory_free(text);

    text = raven.Rfile_read(in_root("missing.txt"), &size);
    t.CHECK(@src(), text == null, "text == NULL");
    t.CHECK(@src(), size == 0, "size == 0");
    t.CHECK(@src(), raven.Rfile_write(in_root("no_such_folder" ++ TEST_SEPARATOR ++ "x.txt"), "x", 1) == 0, "!Rfile_write(in_root(\"no_such_folder\" TEST_SEPARATOR \"x.txt\"), \"x\", 1)");
    t.CHECK(@src(), raven.Rfile_write(null, "x", 1) == 0, "!Rfile_write(NULL, \"x\", 1)");

    // an empty file is a file
    text = raven.Rfile_read(in_root(".hidden"), &size);
    t.CHECK(@src(), text != null and size == 0, "text != NULL && size == 0");
    raven.Rmemory_free(text);
}

// ---------------------------------------------------------------------------
//  Dialogs
// -------------------------------------------------------------------------

var g_clicked: c_int = 0;
var g_closed: c_int = 0;
var g_closed_result: c_int = 0;
var g_window: raven.Rid = 0;

fn on_clicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    g_clicked += 1;
}

fn on_closed(content: raven.Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    // the content is still there when the callback runs
    t.CHECK(@src(), raven.Rwidget_is_valid(content) != 0, "Rwidget_is_valid(content)");
    g_closed += 1;
    g_closed_result = result;
}

fn on_dialog_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    // (int)(intptr_t)user_data
    raven.Rdialog_close(button, @truncate(@as(isize, @bitCast(@intFromPtr(user_data)))));
}

fn test_dialog() void {
    const window = window_from(
        "<Window Width=\"600\" Height=\"400\">" ++
            "<VBox><Button Name=\"under\" Text=\"Under\"/><TextInput Name=\"field\"/></VBox></Window>");
    const under = raven.Rwidget_find(window, "under");
    const field = raven.Rwidget_find(window, "field");
    var box: raven.Rid = undefined;
    var ok: raven.Rid = undefined;
    var input: raven.Rid = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;

    raven.Rbutton_set_clicked_callback(under, on_clicked, null);
    g_clicked = 0;
    t.test_click(window, under);
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");
    raven.Rwidget_focus(field);
    t.CHECK(@src(), raven.Rwidget_is_focused(field) != 0, "Rwidget_is_focused(field)");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) == 0, "!Rwindow_has_dialog(window)");

    {
        const xml: [*c]const u8 = "<VBox Width=\"300\" Spacing=\"8\"><Label>Sure?</Label><TextInput Name=\"in\"/><Button Name=\"ok\" Text=\"OK\"/></VBox>";
        box = raven.Rwidget_create_from_xml(xml, t.strlen(xml));
    }
    t.CHECK(@src(), raven.Rwidget_is_valid(box) != 0, "Rwidget_is_valid(box)");
    g_closed = 0;
    raven.Rdialog_open(window, box, on_closed, null);
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) != 0, "Rwindow_has_dialog(window)");
    ok = raven.Rwidget_find(box, "ok");
    input = raven.Rwidget_find(box, "in");

    // in the middle of the window, at its own size
    raven.Rwidget_get_rect(box, &x, &y, &w, &h);
    t.CHECK_NEAR(@src(), w, 300, "w");
    t.CHECK_NEAR(@src(), x, 150, "x");
    t.CHECK_NEAR(@src(), y + h * 0.5, 200, "y + h * 0.5f");

    // what is under the dialog is out of reach, and lost the keyboard
    t.test_click(window, under);
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");
    t.CHECK(@src(), raven.Rwidget_is_focused(field) == 0, "!Rwidget_is_focused(field)");
    raven.Rwindow_inject_mouse_move(window, 20.0, 20.0);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(window) == raven.R_INVALID_ID, "Rwindow_get_hovered_widget(window) == R_INVALID_ID");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) != 0, "Rwindow_has_dialog(window)");

    // the dialog has its own focus, and the Tab key stays inside
    t.test_click(window, input);
    t.CHECK(@src(), raven.Rwidget_is_focused(input) != 0, "Rwidget_is_focused(input)");
    raven.Rwindow_inject_text(window, "hello");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "hello", "Rtext_input_get_text(input)");
    t.test_key(window, raven.R_KEY_TAB, 0);
    t.CHECK(@src(), raven.Rwidget_is_focused(ok) != 0, "Rwidget_is_focused(ok)");
    t.test_key(window, raven.R_KEY_TAB, 0);
    t.CHECK(@src(), raven.Rwidget_is_focused(input) != 0, "Rwidget_is_focused(input)");

    // closing: the callback gets the result, the content is deleted, the focus comes back
    raven.Rbutton_set_clicked_callback(ok, on_dialog_button, @ptrFromInt(@as(usize, @bitCast(@as(isize, 42))))); // (void*)(intptr_t)42
    t.test_click(window, ok);
    t.CHECK(@src(), g_closed == 1, "g_closed == 1");
    t.CHECK(@src(), g_closed_result == 42, "g_closed_result == 42");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) == 0, "!Rwindow_has_dialog(window)");
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
    t.CHECK(@src(), raven.Rwidget_is_focused(field) != 0, "Rwidget_is_focused(field)");
    t.test_click(window, under);
    t.CHECK(@src(), g_clicked == 2, "g_clicked == 2");

    // Escape dismisses with 0
    box = raven.Rlabel_create("Escape me");
    raven.Rdialog_open(window, box, on_closed, null);
    t.test_key(window, raven.R_KEY_ESCAPE, 0);
    t.CHECK(@src(), g_closed == 2, "g_closed == 2");
    t.CHECK(@src(), g_closed_result == 0, "g_closed_result == 0");
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");

    // two dialogs stack; the window resized under them keeps them
    box = raven.Rlabel_create("First");
    raven.Rdialog_open(window, box, on_closed, null);
    ok = raven.Rlabel_create("Second");
    raven.Rdialog_open(window, ok, on_closed, null);
    raven.Rwindow_set_size(window, 640, 420);
    t.CHECK(@src(), raven.Rwidget_is_valid(box) != 0 and raven.Rwidget_is_valid(ok) != 0, "Rwidget_is_valid(box) && Rwidget_is_valid(ok)");
    raven.Rdialog_close(ok, 7);
    t.CHECK(@src(), g_closed == 3 and g_closed_result == 7, "g_closed == 3 && g_closed_result == 7");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) != 0, "Rwindow_has_dialog(window)");
    raven.Rdialog_close(box, 8);
    t.CHECK(@src(), g_closed == 4 and g_closed_result == 8, "g_closed == 4 && g_closed_result == 8");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) == 0, "!Rwindow_has_dialog(window)");

    // a dialog deleted by the application just goes away
    box = raven.Rlabel_create("Deleted");
    raven.Rdialog_open(window, box, on_closed, null);
    raven.Rwidget_destroy(box);
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) == 0, "!Rwindow_has_dialog(window)");
    t.CHECK(@src(), g_closed == 5, "g_closed == 5");

    // a window destroyed with a dialog open deletes it
    box = raven.Rlabel_create("Left open");
    raven.Rdialog_open(window, box, on_closed, null);
    raven.Rwindow_destroy(window);
    t.CHECK(@src(), g_closed == 6, "g_closed == 6");
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
}

fn close_later(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    raven.Rdialog_close(@truncate(@intFromPtr(user_data)), 5); // (Rid)(uintptr_t)user_data
}

fn press_enter(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
}

fn press_escape(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    t.test_key(g_window, raven.R_KEY_ESCAPE, 0);
}

fn quit_later(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    raven.Rwindow_destroy(g_window);
}

fn quit_application(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    raven.Rquit(0);
}

fn test_dialog_run() void {
    var box: raven.Rid = undefined;
    g_window = window_from("<Window Width=\"600\" Height=\"400\"><Label>Under</Label></Window>");

    box = raven.Rlabel_create("Wait for me");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, close_later, @ptrFromInt(@as(usize, box))); // (void*)(uintptr_t)box
    t.CHECK(@src(), raven.Rdialog_run(g_window, box) == 5, "Rdialog_run(g_window, box) == 5");
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
    t.CHECK(@src(), raven.Rwindow_has_dialog(g_window) == 0, "!Rwindow_has_dialog(g_window)");

    // message boxes: Enter is the main button, Escape cancels (or says no)
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_enter, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, "Title", "A message that is long enough to be wrapped on several lines of the box.", raven.R_MESSAGE_OK) == raven.R_MESSAGE_RESULT_OK, "Rmessage_box(g_window, \"Title\", \"A message that is long enough to be wrapped on several lines of the box.\", R_MESSAGE_OK) == R_MESSAGE_RESULT_OK");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_enter, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, null, "Question", raven.R_MESSAGE_YES_NO_CANCEL) == raven.R_MESSAGE_RESULT_YES, "Rmessage_box(g_window, NULL, \"Question\", R_MESSAGE_YES_NO_CANCEL) == R_MESSAGE_RESULT_YES");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_escape, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, "Title", "Question", raven.R_MESSAGE_YES_NO_CANCEL) == raven.R_MESSAGE_RESULT_CANCEL, "Rmessage_box(g_window, \"Title\", \"Question\", R_MESSAGE_YES_NO_CANCEL) == R_MESSAGE_RESULT_CANCEL");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_escape, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, "Title", "Question", raven.R_MESSAGE_YES_NO) == raven.R_MESSAGE_RESULT_NO, "Rmessage_box(g_window, \"Title\", \"Question\", R_MESSAGE_YES_NO) == R_MESSAGE_RESULT_NO");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_escape, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, "Title", "Question", raven.R_MESSAGE_OK_CANCEL) == raven.R_MESSAGE_RESULT_CANCEL, "Rmessage_box(g_window, \"Title\", \"Question\", R_MESSAGE_OK_CANCEL) == R_MESSAGE_RESULT_CANCEL");
    t.CHECK(@src(), raven.Rwindow_has_dialog(g_window) == 0, "!Rwindow_has_dialog(g_window)");

    // the window goes away while a function waits: it returns as if dismissed
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, quit_later, null);
    t.CHECK(@src(), raven.Rmessage_box(g_window, "Title", "Never answered", raven.R_MESSAGE_OK) == raven.R_MESSAGE_RESULT_CANCEL, "Rmessage_box(g_window, \"Title\", \"Never answered\", R_MESSAGE_OK) == R_MESSAGE_RESULT_CANCEL");
    t.CHECK(@src(), raven.Rwindow_is_valid(g_window) == 0, "!Rwindow_is_valid(g_window)");

    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rdialog_run(g_window, raven.R_INVALID_ID) == 0, "Rdialog_run(g_window, R_INVALID_ID) == 0");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
}

// ---------------------------------------------------------------------------
//  File browser
// -------------------------------------------------------------------------

var g_accepted: [700]u8 = std.mem.zeroes([700]u8);
var g_accepts: c_int = 0;
var g_cancels: c_int = 0;
var g_selected: [700]u8 = std.mem.zeroes([700]u8);
var g_selections: c_int = 0;

fn on_accepted(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = browser;
    _ = user_data;
    _ = t.snprintf(&g_accepted, g_accepted.len, "%s", if (path != null) path else @as([*c]const u8, "(null)"));
    g_accepts += 1;
}

fn on_cancelled(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = browser;
    _ = path;
    _ = user_data;
    g_cancels += 1;
}

fn on_selection(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = browser;
    _ = user_data;
    _ = t.snprintf(&g_selected, g_selected.len, "%s", if (path != null) path else @as([*c]const u8, "(none)"));
    g_selections += 1;
}

// The children of a browser, in the order it creates them.
// enum { FB_PATH, FB_PLACES, FB_NAME, FB_FILTER, FB_CANCEL, FB_ACCEPT };
const FB_PATH: c_int = 0;
const FB_PLACES: c_int = 1;
const FB_NAME: c_int = 2;
const FB_FILTER: c_int = 3;
const FB_CANCEL: c_int = 4;
const FB_ACCEPT: c_int = 5;

fn type_in(window: raven.Rid, field: raven.Rid, text: [*c]const u8) void {
    raven.Rtext_input_set_text(field, "");
    raven.Rwidget_focus(field);
    raven.Rwindow_inject_text(window, text);
    t.test_key(window, raven.R_KEY_ENTER, 0);
}

fn test_file_browser() void {
    const window = window_from("<Window Width=\"800\" Height=\"520\"><FileBrowser Name=\"fb\"/></Window>");
    const browser = raven.Rwidget_find(window, "fb");
    const name = raven.Rwidget_get_child(browser, FB_NAME);
    var filters: [2]raven.RFileFilter = undefined;

    t.CHECK(@src(), raven.Rwidget_get_type(browser) == raven.R_WIDGET_FILE_BROWSER, "Rwidget_get_type(browser) == R_WIDGET_FILE_BROWSER");
    t.CHECK(@src(), raven.Rwidget_get_child_count(browser) == 6, "Rwidget_get_child_count(browser) == 6");
    raven.Rfile_browser_set_accepted_callback(browser, on_accepted, null);
    raven.Rfile_browser_set_cancelled_callback(browser, on_cancelled, null);
    raven.Rfile_browser_set_selection_changed_callback(browser, on_selection, null);

    t.CHECK(@src(), raven.Rfile_browser_set_directory(browser, &g_root) != 0, "Rfile_browser_set_directory(browser, g_root)");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    t.CHECK(@src(), raven.Rfile_browser_set_directory(browser, in_root("nowhere")) == 0, "!Rfile_browser_set_directory(browser, in_root(\"nowhere\"))");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(raven.Rwidget_get_child(browser, FB_PATH)), &g_root, "Rtext_input_get_text(Rwidget_get_child(browser, FB_PATH))");

    // selection, by name; the name goes to the name field
    g_selections = 0;
    raven.Rfile_browser_select(browser, "beta.txt");
    t.CHECK(@src(), g_selections == 1, "g_selections == 1");
    t.CHECK_STR(@src(), &g_selected, in_root("beta.txt"), "g_selected");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 1, "Rfile_browser_get_selection_count(browser) == 1");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("beta.txt"), "Rfile_browser_get_selection(browser, 0)");
    t.CHECK(@src(), raven.Rfile_browser_get_selection(browser, 1) == null, "Rfile_browser_get_selection(browser, 1) == NULL");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(name), "beta.txt", "Rtext_input_get_text(name)");
    raven.Rfile_browser_select(browser, ".hidden");
    t.CHECK(@src(), g_selections == 1, "g_selections == 1");

    // the keyboard: folders come first (sub, zeta), then the files without case (alpha, beta, Gamma)
    raven.Rwidget_focus(browser);
    t.test_key(window, raven.R_KEY_HOME, 0);
    t.CHECK_STR(@src(), &g_selected, in_root("sub"), "g_selected");
    t.test_key(window, raven.R_KEY_DOWN, 0);
    t.CHECK_STR(@src(), &g_selected, in_root("zeta"), "g_selected");
    t.test_key(window, raven.R_KEY_DOWN, 0);
    t.CHECK_STR(@src(), &g_selected, in_root("alpha.xml"), "g_selected");
    t.test_key(window, raven.R_KEY_END, 0);
    t.CHECK_STR(@src(), &g_selected, in_root("Gamma.XML"), "g_selected");
    // typing goes to the first name that starts with it
    raven.Rwindow_inject_text(window, "be");
    t.CHECK_STR(@src(), &g_selected, in_root("beta.txt"), "g_selected");

    // Enter on a file accepts it; on a folder, enters it; Backspace goes back up
    g_accepts = 0;
    t.test_key(window, raven.R_KEY_ENTER, 0);
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), &g_accepted, in_root("beta.txt"), "g_accepted");
    raven.Rfile_browser_select(browser, "sub");
    t.test_key(window, raven.R_KEY_ENTER, 0);
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), in_root("sub"), "Rfile_browser_get_directory(browser)");
    raven.Rfile_browser_select(browser, "inner.txt");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"), "Rfile_browser_get_selection(browser, 0)");
    t.test_key(window, raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    // ... and the folder that was left is the one selected
    t.CHECK_STR(@src(), &g_selected, in_root("sub"), "g_selected");
    // Alt+Left / Alt+Right walk the history
    t.test_key(window, raven.R_KEY_LEFT, raven.R_MOD_ALT);
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), in_root("sub"), "Rfile_browser_get_directory(browser)");
    t.test_key(window, raven.R_KEY_RIGHT, raven.R_MOD_ALT);
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");

    // hidden files
    raven.Rfile_browser_set_show_hidden(browser, raven.R_TRUE);
    raven.Rfile_browser_select(browser, ".hidden");
    t.CHECK_STR(@src(), &g_selected, in_root(".hidden"), "g_selected");
    raven.Rfile_browser_set_show_hidden(browser, raven.R_FALSE);
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 0, "Rfile_browser_get_selection_count(browser) == 0");

    // filters: folders stay, files must match, without case
    filters[0].name = "XML";
    filters[0].patterns = "*.xml;*.ui";
    filters[1].name = "All";
    filters[1].patterns = "*";
    raven.Rfile_browser_set_filters(browser, &filters, 2);
    t.CHECK(@src(), raven.Rcombo_box_get_item_count(raven.Rwidget_get_child(browser, FB_FILTER)) == 2, "Rcombo_box_get_item_count(Rwidget_get_child(browser, FB_FILTER)) == 2");
    raven.Rfile_browser_select(browser, "beta.txt");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 0, "Rfile_browser_get_selection_count(browser) == 0");
    raven.Rfile_browser_select(browser, "Gamma.XML");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 1, "Rfile_browser_get_selection_count(browser) == 1");
    raven.Rfile_browser_select(browser, "zeta");
    t.CHECK_STR(@src(), &g_selected, in_root("zeta"), "g_selected");
    raven.Rfile_browser_set_filters(browser, &filters[1], 1);
    raven.Rfile_browser_select(browser, "beta.txt");
    t.CHECK_STR(@src(), &g_selected, in_root("beta.txt"), "g_selected");

    // the name field: a name of the folder, a path, a folder to go to, or nonsense
    g_accepts = 0;
    type_in(window, name, "alpha.xml");
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), &g_accepted, in_root("alpha.xml"), "g_accepted");
    type_in(window, name, "nothing.here");
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    type_in(window, name, "sub");
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), in_root("sub"), "Rfile_browser_get_directory(browser)");
    type_in(window, name, "..");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    type_in(window, name, in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"));
    t.CHECK(@src(), g_accepts == 2, "g_accepts == 2");
    t.CHECK_STR(@src(), &g_accepted, in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"), "g_accepted");
    // the path field goes to a folder, or to the folder of a file, which it selects
    type_in(window, raven.Rwidget_get_child(browser, FB_PATH), in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"));
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), in_root("sub"), "Rfile_browser_get_directory(browser)");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("sub" ++ TEST_SEPARATOR ++ "inner.txt"), "Rfile_browser_get_selection(browser, 0)");
    type_in(window, raven.Rwidget_get_child(browser, FB_PATH), in_root("nowhere"));
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), in_root("sub"), "Rfile_browser_get_directory(browser)");
    t.CHECK(@src(), raven.Rfile_browser_set_directory(browser, &g_root) != 0, "Rfile_browser_set_directory(browser, g_root)");

    // buttons
    raven.Rfile_browser_select(browser, "beta.txt");
    t.test_click(window, raven.Rwidget_get_child(browser, FB_ACCEPT));
    t.CHECK(@src(), g_accepts == 3, "g_accepts == 3");
    t.CHECK_STR(@src(), &g_accepted, in_root("beta.txt"), "g_accepted");
    g_cancels = 0;
    t.test_click(window, raven.Rwidget_get_child(browser, FB_CANCEL));
    t.CHECK(@src(), g_cancels == 1, "g_cancels == 1");

    // several files
    raven.Rfile_browser_set_multiple(browser, raven.R_TRUE);
    raven.Rwidget_focus(browser);
    raven.Rfile_browser_select(browser, "alpha.xml");
    t.test_key(window, raven.R_KEY_DOWN, raven.R_MOD_SHIFT);
    t.test_key(window, raven.R_KEY_DOWN, raven.R_MOD_SHIFT);
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 3, "Rfile_browser_get_selection_count(browser) == 3");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("alpha.xml"), "Rfile_browser_get_selection(browser, 0)");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 2), in_root("Gamma.XML"), "Rfile_browser_get_selection(browser, 2)");
    t.test_key(window, raven.R_KEY_A, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 3, "Rfile_browser_get_selection_count(browser) == 3");
    raven.Rfile_browser_set_multiple(browser, raven.R_FALSE);

    // save: any name, the extension is added, an existing file must be confirmed
    raven.Rfile_browser_set_mode(browser, raven.R_FILE_BROWSER_SAVE);
    raven.Rfile_browser_set_filters(browser, &filters, 1);
    g_accepts = 0;
    type_in(window, name, "saved");
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), &g_accepted, in_root("saved.xml"), "g_accepted");
    raven.Rfile_browser_set_default_extension(browser, ".txt");
    type_in(window, name, "saved");
    t.CHECK_STR(@src(), &g_accepted, in_root("saved.txt"), "g_accepted");
    type_in(window, name, "saved.md");
    t.CHECK_STR(@src(), &g_accepted, in_root("saved.md"), "g_accepted");
    t.CHECK(@src(), g_accepts == 3, "g_accepts == 3");
    g_window = window;
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_escape, null);
    type_in(window, name, "alpha.xml");
    t.CHECK(@src(), g_accepts == 3, "g_accepts == 3");
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_enter, null);
    type_in(window, name, "alpha.xml");
    t.CHECK(@src(), g_accepts == 4, "g_accepts == 4");
    t.CHECK_STR(@src(), &g_accepted, in_root("alpha.xml"), "g_accepted");

    // folders: only folders are listed; the button takes the folder shown
    raven.Rfile_browser_set_mode(browser, raven.R_FILE_BROWSER_FOLDER);
    raven.Rfile_browser_select(browser, "beta.txt");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 0, "Rfile_browser_get_selection_count(browser) == 0");
    raven.Rtext_input_set_text(name, "");
    g_accepts = 0;
    t.test_click(window, raven.Rwidget_get_child(browser, FB_ACCEPT));
    t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
    t.CHECK_STR(@src(), &g_accepted, &g_root, "g_accepted");
    raven.Rfile_browser_select(browser, "zeta");
    t.test_click(window, raven.Rwidget_get_child(browser, FB_ACCEPT));
    t.CHECK_STR(@src(), &g_accepted, in_root("zeta"), "g_accepted");

    // an explorer panel: no controls
    raven.Rfile_browser_set_controls_visible(browser, raven.R_FALSE);
    raven.Rfile_browser_set_places_visible(browser, raven.R_FALSE);
    t.CHECK(@src(), raven.Rwidget_get_visibility(name) == raven.R_COLLAPSED, "Rwidget_get_visibility(name) == R_COLLAPSED");
    _ = raven.Rdraw_frame();
    raven.Rfile_browser_refresh(browser);

    t.EXPECT_ERRORS_BEGIN();
    raven.Rfile_browser_set_mode(browser, @as(raven.RFileBrowserMode, 1));
    _ = raven.Rwidget_add_child(browser, raven.Rlabel_create("no"));
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    raven.Rwindow_destroy(window);
}

fn test_file_browser_xml() void {
    var xml: [1200]u8 = undefined;
    var window: raven.Rid = undefined;
    var browser: raven.Rid = undefined;
    _ = t.snprintf(&xml, xml.len, "<Window Width=\"300\" Height=\"400\">" ++
        "<FileBrowser Name=\"fb\" Directory=\"%s\" Filter=\"*.txt\" Controls=\"false\" Places=\"false\" ShowHidden=\"false\" Mode=\"Open\"/></Window>", @as([*c]const u8, &g_root));
    window = window_from(&xml);
    browser = raven.Rwidget_find(window, "fb");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    raven.Rfile_browser_select(browser, "alpha.xml");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 0, "Rfile_browser_get_selection_count(browser) == 0");
    raven.Rfile_browser_select(browser, "beta.txt");
    t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 1, "Rfile_browser_get_selection_count(browser) == 1");

    // a double click on a row: the list starts under the path field and its header
    raven.Rfile_browser_set_accepted_callback(browser, on_accepted, null);
    g_accepts = 0;
    {
        const control: f32 = raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT);
        const row: f32 = raven.Rtheme_get_metric(raven.R_METRIC_ROW_HEIGHT);
        const y: f32 = control + 8.0 + row + 2.0 + row * 2.5;
        t.test_click_at(window, 100.0, y);
        t.CHECK(@src(), raven.Rfile_browser_get_selection_count(browser) == 1, "Rfile_browser_get_selection_count(browser) == 1");
        t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("beta.txt"), "Rfile_browser_get_selection(browser, 0)");
        t.test_click_at(window, 100.0, y);
        t.CHECK(@src(), g_accepts == 1, "g_accepts == 1");
        t.CHECK_STR(@src(), &g_accepted, in_root("beta.txt"), "g_accepted");
        // the header sorts: a click on "Name" reverses the order of the files (folders stay first)
        t.test_click_at(window, 60.0, control + 8.0 + row * 0.5);
        raven.Rwidget_focus(browser);
        t.test_key(window, raven.R_KEY_HOME, 0);
        t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("zeta"), "Rfile_browser_get_selection(browser, 0)");
        t.test_key(window, raven.R_KEY_END, 0);
        t.CHECK_STR(@src(), raven.Rfile_browser_get_selection(browser, 0), in_root("beta.txt"), "Rfile_browser_get_selection(browser, 0)");
    }
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  File dialogs (the browser of Raven: there is no window system here)
// -------------------------------------------------------------------------

fn find_browser(widget: raven.Rid) raven.Rid {
    var i: c_int = undefined;
    var count: c_int = undefined;
    if (raven.Rwidget_get_type(widget) == raven.R_WIDGET_FILE_BROWSER) return widget;
    count = raven.Rwidget_get_child_count(widget);
    i = 0;
    while (i < count) : (i += 1) {
        const found = find_browser(raven.Rwidget_get_child(widget, i));
        if (found != raven.R_INVALID_ID) return found;
    }
    return raven.R_INVALID_ID;
}

var g_dialog_browser: raven.Rid = 0;

// The browser shown by the dialog is the widget that has the keyboard.
fn choose_beta(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const browser = raven.Rwindow_get_focused_widget(g_window);
    _ = timer;
    _ = user_data;
    g_dialog_browser = browser;
    t.CHECK(@src(), raven.Rwidget_get_type(browser) == raven.R_WIDGET_FILE_BROWSER, "Rwidget_get_type(browser) == R_WIDGET_FILE_BROWSER");
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    raven.Rfile_browser_select(browser, "beta.txt");
    t.test_key(g_window, raven.R_KEY_ENTER, 0);
}

fn choose_two(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const browser = raven.Rwindow_get_focused_widget(g_window);
    _ = timer;
    _ = user_data;
    raven.Rfile_browser_select(browser, "alpha.xml");
    t.test_key(g_window, raven.R_KEY_DOWN, raven.R_MOD_SHIFT);
    t.test_click(g_window, raven.Rwidget_get_child(browser, FB_ACCEPT));
}

fn choose_name(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const browser = raven.Rwindow_get_focused_widget(g_window);
    _ = timer;
    type_in(g_window, raven.Rwidget_get_child(browser, FB_NAME), @as([*c]const u8, @ptrCast(user_data)));
}

fn choose_folder(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const browser = raven.Rwindow_get_focused_widget(g_window);
    _ = timer;
    _ = user_data;
    // the previous dialog ended in the same folder: this one starts there
    t.CHECK_STR(@src(), raven.Rfile_browser_get_directory(browser), &g_root, "Rfile_browser_get_directory(browser)");
    raven.Rfile_browser_select(browser, "sub");
    t.test_click(g_window, raven.Rwidget_get_child(browser, FB_ACCEPT));
}

fn test_file_dialogs() void {
    var desc: raven.RFileDialogDesc = undefined;
    var filter: raven.RFileFilter = undefined;
    var path: [*c]const u8 = undefined;

    g_window = window_from("<Window Width=\"900\" Height=\"600\"><Label>Under</Label></Window>");
    _ = find_browser;

    @memset(std.mem.asBytes(&desc), 0);
    desc.parent = g_window;
    desc.directory = &g_root;
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, choose_beta, null);
    path = raven.Rfile_dialog_open(&desc);
    t.CHECK(@src(), path != null, "path != NULL");
    if (path != null) t.CHECK_STR(@src(), path, in_root("beta.txt"), "path");
    t.CHECK(@src(), raven.Rfile_dialog_get_result_count() == 1, "Rfile_dialog_get_result_count() == 1");
    t.CHECK(@src(), raven.Rwindow_has_dialog(g_window) == 0, "!Rwindow_has_dialog(g_window)");
    t.CHECK(@src(), raven.Rwidget_is_valid(g_dialog_browser) == 0, "!Rwidget_is_valid(g_dialog_browser)");

    // cancelled
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, press_escape, null);
    t.CHECK(@src(), raven.Rfile_dialog_open(&desc) == null, "Rfile_dialog_open(&desc) == NULL");
    t.CHECK(@src(), raven.Rfile_dialog_get_result_count() == 0, "Rfile_dialog_get_result_count() == 0");
    t.CHECK(@src(), raven.Rfile_dialog_get_result(0) == null, "Rfile_dialog_get_result(0) == NULL");

    // several files
    desc.flags = raven.R_FILE_DIALOG_MULTIPLE | raven.R_FILE_DIALOG_RAVEN;
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, choose_two, null);
    path = raven.Rfile_dialog_open(&desc);
    t.CHECK(@src(), raven.Rfile_dialog_get_result_count() == 2, "Rfile_dialog_get_result_count() == 2");
    if (raven.Rfile_dialog_get_result_count() == 2) {
        t.CHECK_STR(@src(), raven.Rfile_dialog_get_result(0), in_root("alpha.xml"), "Rfile_dialog_get_result(0)");
        t.CHECK_STR(@src(), raven.Rfile_dialog_get_result(1), in_root("beta.txt"), "Rfile_dialog_get_result(1)");
        t.CHECK(@src(), path == raven.Rfile_dialog_get_result(0), "path == Rfile_dialog_get_result(0)");
    }

    // save
    desc.flags = 0;
    desc.directory = null;
    desc.title = "Save the thing";
    desc.file_name = "proposed.xml";
    filter.name = "XML";
    filter.patterns = "*.xml";
    desc.filters = &filter;
    desc.filter_count = 1;
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, choose_name, @ptrCast(@constCast("saved")));
    path = raven.Rfile_dialog_save(&desc);
    t.CHECK(@src(), path != null, "path != NULL");
    if (path != null) t.CHECK_STR(@src(), path, in_root("saved.xml"), "path");

    // folder
    @memset(std.mem.asBytes(&desc), 0);
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, choose_folder, null);
    path = raven.Rfile_dialog_select_folder(&desc);
    t.CHECK(@src(), path != null, "path != NULL");
    if (path != null) t.CHECK_STR(@src(), path, in_root("sub"), "path");
    raven.Rwindow_destroy(g_window);

    // without any window, the dialog opens one for itself; quitting the application ends it
    _ = raven.Rtimer_create(0.01, raven.R_FALSE, quit_application, null);
    t.CHECK(@src(), raven.Rfile_dialog_open(null) == null, "Rfile_dialog_open(NULL) == NULL");
    t.CHECK(@src(), raven.Ris_running() == 0, "!Ris_running()");
}

// With the animations on, a closed dialog stays drawn while it leaves, then is deleted.
fn test_dialog_animated() void {
    const window = window_from("<Window Width=\"600\" Height=\"400\"><Button Name=\"under\" Text=\"Under\"/></Window>");
    var box: raven.Rid = undefined;
    var again: raven.Rid = undefined;
    var i: c_int = undefined;

    raven.Rset_animations_enabled(raven.R_TRUE);
    raven.Rset_animation_time_step(1.0 / 60.0);
    box = raven.Rlabel_create("Leaving");
    g_closed = 0;
    raven.Rdialog_open(window, box, on_closed, null);
    i = 0;
    while (i < 5) : (i += 1) _ = raven.Rdraw_frame();
    raven.Rdialog_close(box, 3);
    t.CHECK(@src(), g_closed == 1 and g_closed_result == 3, "g_closed == 1 && g_closed_result == 3");
    t.CHECK(@src(), raven.Rwindow_has_dialog(window) == 0, "!Rwindow_has_dialog(window)");
    // still there, on its way out, and out of reach
    t.CHECK(@src(), raven.Rwidget_is_valid(box) != 0, "Rwidget_is_valid(box)");
    g_clicked = 0;
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(window, "under"), on_clicked, null);
    t.test_click(window, raven.Rwidget_find(window, "under"));
    t.CHECK(@src(), g_clicked == 1, "g_clicked == 1");
    i = 0;
    while (i < 120 and raven.Rwidget_is_valid(box) != 0) : (i += 1) {
        raven.Rwindow_request_redraw(window);
        _ = raven.Rdraw_frame();
    }
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
    t.CHECK(@src(), i > 2 and i < 120, "i > 2 && i < 120");

    // closed while leaving, deleted while leaving, and a window closed with a dialog on its way out
    box = raven.Rlabel_create("One");
    raven.Rdialog_open(window, box, null, null);
    _ = raven.Rdraw_frame();
    raven.Rdialog_close(box, 0);
    raven.Rdialog_close(box, 0);
    raven.Rwidget_destroy(box);
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
    _ = raven.Rdraw_frame();
    box = raven.Rlabel_create("Two");
    again = raven.Rlabel_create("Three");
    raven.Rdialog_open(window, box, null, null);
    raven.Rdialog_open(window, again, null, null);
    _ = raven.Rdraw_frame();
    raven.Rdialog_close(again, 0);
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(window);
    t.CHECK(@src(), raven.Rwidget_is_valid(box) == 0, "!Rwidget_is_valid(box)");
    t.CHECK(@src(), raven.Rwidget_is_valid(again) == 0, "!Rwidget_is_valid(again)");
    raven.Rset_animations_enabled(raven.R_FALSE);
    raven.Rset_animation_time_step(0.0);
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_dialogs: cannot initialize Raven\n");
        return 1;
    }
    make_tree();
    t.RUN(test_files, "test_files");
    t.RUN(test_dialog, "test_dialog");
    t.RUN(test_dialog_run, "test_dialog_run");
    t.RUN(test_dialog_animated, "test_dialog_animated");
    t.RUN(test_file_browser, "test_file_browser");
    t.RUN(test_file_browser_xml, "test_file_browser_xml");
    t.RUN(test_file_dialogs, "test_file_dialogs");
    remove_tree();
    raven.Rshutdown();
    return t.test_report("test_dialogs");
}
