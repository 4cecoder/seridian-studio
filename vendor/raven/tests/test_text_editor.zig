// Translated to Zig from vendor/raven/tests/test_text_editor.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - the multi-line text editor, driven by its API and by
// injected keys and mouse events.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h> / <stdio.h> / <string.h> functions that test.zig does not export
extern "c" fn sprintf(buffer: [*c]u8, format: [*:0]const u8, ...) c_int;
extern "c" fn strcat(destination: [*c]u8, source: [*c]const u8) [*c]u8;

var g_window: raven.Rid = 0;
var g_editor: raven.Rid = 0;
var g_changes: c_int = 0;

fn on_changed(editor: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = editor;
    _ = user_data;
    g_changes += 1;
}

fn key(k: raven.RKey, modifiers: raven.Ruint) void {
    raven.Rwindow_inject_key(g_window, k, raven.R_TRUE, modifiers);
    raven.Rwindow_inject_key(g_window, k, raven.R_FALSE, modifiers);
}

// `type` is a Zig keyword: the function is `type_`
fn type_(text: [*c]const u8) void {
    raven.Rwindow_inject_text(g_window, text);
}

/// CHECK_CURSOR(expected_line, expected_column)
fn CHECK_CURSOR(src: t.Src, expected_line: c_int, expected_column: c_int) void {
    var test_l_: c_int = -1;
    var test_c_: c_int = -1;
    raven.Rtext_editor_get_cursor(g_editor, &test_l_, &test_c_);
    t.g_test_checks += 1;
    if (test_l_ != expected_line or test_c_ != expected_column) {
        t.g_test_failures += 1;
        _ = t.printf("  FAIL %s:%d: cursor at (%d, %d), expected (%d, %d)\n", src.file.ptr, @as(c_int, @intCast(src.line)), test_l_, test_c_, expected_line, expected_column);
    }
}

fn open_editor(attributes: [*c]const u8) void {
    var xml: [512]u8 = undefined;
    _ = t.snprintf(&xml, xml.len, "<Window Width=\"400\" Height=\"300\"><TextEditor Name=\"e\" %s/></Window>", attributes);
    g_window = raven.Rwindow_create_from_xml(&xml, t.strlen(&xml));
    t.CHECK(@src(), raven.Rwindow_is_valid(g_window) != 0, "Rwindow_is_valid(g_window)");
    g_editor = raven.Rwidget_find(g_window, "e");
    raven.Rtext_editor_set_changed_callback(g_editor, on_changed, null);
    _ = raven.Rdraw_frame();
    raven.Rwidget_focus(g_editor);
    g_changes = 0;
}

fn test_content() void {
    var a: c_int = undefined;
    var b: c_int = undefined;
    var c: c_int = undefined;
    var d: c_int = undefined;
    open_editor("");
    t.CHECK(@src(), raven.Rwidget_get_type(g_editor) == raven.R_WIDGET_TEXT_EDITOR, "Rwidget_get_type(g_editor) == R_WIDGET_TEXT_EDITOR");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == 1, "Rtext_editor_get_line_count(g_editor) == 1");

    raven.Rtext_editor_set_text(g_editor, "one\ntwo\r\nthree\n");
    // set_text is not an edit of the user
    t.CHECK(@src(), g_changes == 0, "g_changes == 0");
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == 4, "Rtext_editor_get_line_count(g_editor) == 4");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "two", "Rtext_editor_get_line(g_editor, 1)");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 3), "", "Rtext_editor_get_line(g_editor, 3)");
    t.CHECK(@src(), raven.Rtext_editor_get_line(g_editor, 4) == null, "Rtext_editor_get_line(g_editor, 4) == NULL");
    // line breaks come out as '\n'
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one\ntwo\nthree\n", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), raven.Rtext_editor_get_length(g_editor) == 14, "Rtext_editor_get_length(g_editor) == 14");
    CHECK_CURSOR(@src(), 0, 0);
    t.CHECK(@src(), raven.Rtext_editor_can_undo(g_editor) == 0, "!Rtext_editor_can_undo(g_editor)");

    // positions are clamped, and never inside a character
    raven.Rtext_editor_set_text(g_editor, "h\xC3\xA9llo");
    raven.Rtext_editor_set_cursor(g_editor, 0, 2);
    CHECK_CURSOR(@src(), 0, 1);
    raven.Rtext_editor_set_cursor(g_editor, 9, 99);
    CHECK_CURSOR(@src(), 0, 6);
    raven.Rtext_editor_set_cursor(g_editor, -3, -3);
    CHECK_CURSOR(@src(), 0, 0);

    // selection
    raven.Rtext_editor_set_text(g_editor, "alpha\nbeta\ngamma");
    t.CHECK(@src(), raven.Rtext_editor_get_selection(g_editor, &a, &b, &c, &d) == 0, "!Rtext_editor_get_selection(g_editor, &a, &b, &c, &d)");
    raven.Rtext_editor_select(g_editor, 1, 2, 0, 3);
    t.CHECK(@src(), raven.Rtext_editor_get_selection(g_editor, &a, &b, &c, &d) != 0, "Rtext_editor_get_selection(g_editor, &a, &b, &c, &d)");
    t.CHECK(@src(), a == 0 and b == 3 and c == 1 and d == 2, "a == 0 && b == 3 && c == 1 && d == 2");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "ha\nbe", "Rtext_editor_get_selected_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 3);
    raven.Rtext_editor_select_all(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "alpha\nbeta\ngamma", "Rtext_editor_get_selected_text(g_editor)");

    // typing replaces the selection, and tells the application
    raven.Rtext_editor_select(g_editor, 0, 3, 1, 2);
    raven.Rtext_editor_insert_text(g_editor, "X\nY");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "alpX\nYta\ngamma", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 1, 1);
    t.CHECK(@src(), g_changes == 1, "g_changes == 1");
    raven.Rwindow_destroy(g_window);
}

fn test_typing() void {
    open_editor("");
    type_("Hello");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "Hello", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), g_changes == 5, "g_changes == 5");
    CHECK_CURSOR(@src(), 0, 5);

    // Enter keeps the indentation of the line
    raven.Rtext_editor_set_text(g_editor, "\tif (x) {");
    key(raven.R_KEY_END, raven.R_MOD_CTRL);
    key(raven.R_KEY_ENTER, 0);
    type_("y");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "\tif (x) {\n\ty", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 1, 2);

    // backspace and delete, by character, by word, across lines
    raven.Rtext_editor_set_text(g_editor, "one two\nthree");
    raven.Rtext_editor_set_cursor(g_editor, 1, 0);
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one twothree", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 7);
    key(raven.R_KEY_BACKSPACE, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one three", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_DELETE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one hree", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_DELETE, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one ", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_DELETE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "one ", "Rtext_editor_get_text(g_editor)");

    // a character of several bytes is one character
    raven.Rtext_editor_set_text(g_editor, "a\xE2\x82\xAC" ++ "b");
    key(raven.R_KEY_END, 0);
    key(raven.R_KEY_LEFT, 0);
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "ab", "Rtext_editor_get_text(g_editor)");
    type_("\xC3\xA9");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "a\xC3\xA9" ++ "b", "Rtext_editor_get_text(g_editor)");

    // Tab: a tab character, or spaces up to the next stop
    raven.Rtext_editor_set_text(g_editor, "ab");
    key(raven.R_KEY_END, 0);
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "ab\t", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_tab_inserts_spaces(g_editor, raven.R_TRUE);
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "ab\t    ", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "ab");
    key(raven.R_KEY_END, 0);
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "ab  ", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_tab_inserts_spaces(g_editor, raven.R_FALSE);

    // a read-only editor moves and selects but does not change
    raven.Rtext_editor_set_text(g_editor, "fixed");
    raven.Rtext_editor_set_read_only(g_editor, raven.R_TRUE);
    g_changes = 0;
    type_("x");
    key(raven.R_KEY_BACKSPACE, 0);
    key(raven.R_KEY_ENTER, 0);
    key(raven.R_KEY_V, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "fixed", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), g_changes == 0, "g_changes == 0");
    key(raven.R_KEY_END, raven.R_MOD_SHIFT);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "fixed", "Rtext_editor_get_selected_text(g_editor)");
    raven.Rwindow_destroy(g_window);
}

fn test_navigation() void {
    var a: c_int = undefined;
    var b: c_int = undefined;
    var c: c_int = undefined;
    var d: c_int = undefined;
    // a fixed-width font: columns line up from one line to the next
    open_editor("Font=\"monospace\"");
    raven.Rtext_editor_set_text(g_editor, "first line\n  second\n\nlast one here");

    key(raven.R_KEY_RIGHT, 0);
    CHECK_CURSOR(@src(), 0, 1);
    key(raven.R_KEY_RIGHT, raven.R_MOD_CTRL);
    CHECK_CURSOR(@src(), 0, 6);
    key(raven.R_KEY_END, 0);
    CHECK_CURSOR(@src(), 0, 10);
    // past the end of a line: the start of the next
    key(raven.R_KEY_RIGHT, 0);
    CHECK_CURSOR(@src(), 1, 0);
    key(raven.R_KEY_LEFT, 0);
    CHECK_CURSOR(@src(), 0, 10);
    key(raven.R_KEY_LEFT, raven.R_MOD_CTRL);
    CHECK_CURSOR(@src(), 0, 6);

    // Home goes to the text, then to the margin
    raven.Rtext_editor_set_cursor(g_editor, 1, 6);
    key(raven.R_KEY_HOME, 0);
    CHECK_CURSOR(@src(), 1, 2);
    key(raven.R_KEY_HOME, 0);
    CHECK_CURSOR(@src(), 1, 0);
    key(raven.R_KEY_HOME, 0);
    CHECK_CURSOR(@src(), 1, 2);

    // up and down keep the column they started from, through a shorter line
    raven.Rtext_editor_set_cursor(g_editor, 0, 8);
    key(raven.R_KEY_DOWN, 0);
    CHECK_CURSOR(@src(), 1, 8);
    key(raven.R_KEY_DOWN, 0);
    CHECK_CURSOR(@src(), 2, 0);
    key(raven.R_KEY_DOWN, 0);
    {
        var line: c_int = undefined;
        var column: c_int = undefined;
        raven.Rtext_editor_get_cursor(g_editor, &line, &column);
        t.CHECK(@src(), line == 3 and column >= 7 and column <= 9, "line == 3 && column >= 7 && column <= 9");
    }
    key(raven.R_KEY_DOWN, 0);
    CHECK_CURSOR(@src(), 3, 13);
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_UP, 0);
    CHECK_CURSOR(@src(), 0, 0);

    key(raven.R_KEY_END, raven.R_MOD_CTRL);
    CHECK_CURSOR(@src(), 3, 13);
    key(raven.R_KEY_HOME, raven.R_MOD_CTRL);
    CHECK_CURSOR(@src(), 0, 0);

    // Shift selects; an arrow without Shift goes to the end of the selection
    key(raven.R_KEY_RIGHT, raven.R_MOD_SHIFT | raven.R_MOD_CTRL);
    key(raven.R_KEY_DOWN, raven.R_MOD_SHIFT);
    t.CHECK(@src(), raven.Rtext_editor_get_selection(g_editor, &a, &b, &c, &d) != 0, "Rtext_editor_get_selection(g_editor, &a, &b, &c, &d)");
    t.CHECK(@src(), a == 0 and b == 0 and c == 1, "a == 0 && b == 0 && c == 1");
    key(raven.R_KEY_LEFT, 0);
    CHECK_CURSOR(@src(), 0, 0);
    t.CHECK(@src(), raven.Rtext_editor_get_selection(g_editor, &a, &b, &c, &d) == 0, "!Rtext_editor_get_selection(g_editor, &a, &b, &c, &d)");

    key(raven.R_KEY_A, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "first line\n  second\n\nlast one here", "Rtext_editor_get_selected_text(g_editor)");
    raven.Rwindow_destroy(g_window);
}

fn test_clipboard_and_history() void {
    open_editor("");
    raven.Rtext_editor_set_text(g_editor, "copy me\nplease");

    raven.Rtext_editor_select(g_editor, 0, 5, 1, 3);
    key(raven.R_KEY_C, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rclipboard_get_text(), "me\nple", "Rclipboard_get_text()");
    key(raven.R_KEY_X, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy ase", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_END, 0);
    key(raven.R_KEY_V, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy aseme\nple", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 1, 3);

    // each command is one step back
    t.CHECK(@src(), raven.Rtext_editor_can_undo(g_editor) != 0 and raven.Rtext_editor_can_redo(g_editor) == 0, "Rtext_editor_can_undo(g_editor) && !Rtext_editor_can_redo(g_editor)");
    key(raven.R_KEY_Z, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy ase", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 8);
    key(raven.R_KEY_Z, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy me\nplease", "Rtext_editor_get_text(g_editor)");
    // the selection that was cut is selected again
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "me\nple", "Rtext_editor_get_selected_text(g_editor)");
    t.CHECK(@src(), raven.Rtext_editor_can_undo(g_editor) == 0 and raven.Rtext_editor_can_redo(g_editor) != 0, "!Rtext_editor_can_undo(g_editor) && Rtext_editor_can_redo(g_editor)");
    key(raven.R_KEY_Z, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy me\nplease", "Rtext_editor_get_text(g_editor)");

    key(raven.R_KEY_Y, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy ase", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_Z, raven.R_MOD_CTRL | raven.R_MOD_SHIFT);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "copy aseme\nple", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), raven.Rtext_editor_can_redo(g_editor) == 0, "!Rtext_editor_can_redo(g_editor)");

    // a word typed in one go is undone in one go; moving the caret starts another step
    raven.Rtext_editor_set_text(g_editor, "");
    type_("abc");
    type_("def");
    key(raven.R_KEY_HOME, 0);
    type_("X");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "Xabcdef", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "abcdef", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_redo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "abcdef", "Rtext_editor_get_text(g_editor)");
    // a new edit forgets what could be redone
    type_("!");
    t.CHECK(@src(), raven.Rtext_editor_can_redo(g_editor) == 0, "!Rtext_editor_can_redo(g_editor)");

    // many steps back and forth give the same text
    raven.Rtext_editor_set_text(g_editor, "base");
    {
        var expected: [256]u8 = undefined;
        var i: c_int = undefined;
        i = 0;
        while (i < 40) : (i += 1) {
            key(raven.R_KEY_END, raven.R_MOD_CTRL);
            key(raven.R_KEY_ENTER, 0);
            type_("line");
            if (@rem(i, 3) == 0) key(raven.R_KEY_BACKSPACE, raven.R_MOD_CTRL);
        }
        _ = t.snprintf(&expected, expected.len, "%.200s", raven.Rtext_editor_get_text(g_editor));
        i = 0;
        while (i < 200) : (i += 1) raven.Rtext_editor_undo(g_editor);
        t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "base", "Rtext_editor_get_text(g_editor)");
        i = 0;
        while (i < 200) : (i += 1) raven.Rtext_editor_redo(g_editor);
        t.CHECK(@src(), t.strncmp(raven.Rtext_editor_get_text(g_editor), &expected, 200) == 0, "strncmp(Rtext_editor_get_text(g_editor), expected, 200) == 0");
    }
    raven.Rwindow_destroy(g_window);
}

fn test_indent() void {
    open_editor("");
    raven.Rtext_editor_set_text(g_editor, "a\nb\n\nc\nd");
    // lines 0 to 3 selected: the empty one stays empty, the last line is not touched
    raven.Rtext_editor_select(g_editor, 0, 0, 4, 0);
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "\ta\n\tb\n\n\tc\nd", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "\t\ta\n\t\tb\n\n\t\tc\nd", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    key(raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    key(raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "a\nb\n\nc\nd", "Rtext_editor_get_text(g_editor)");
    // three steps to undo: two in, then the two that went out (the third did nothing but is a step)
    raven.Rtext_editor_undo(g_editor);
    raven.Rtext_editor_undo(g_editor);
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "\t\ta\n\t\tb\n\n\t\tc\nd", "Rtext_editor_get_text(g_editor)");

    // Shift+Tab on a line indented with spaces
    raven.Rtext_editor_set_text(g_editor, "      x");
    key(raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "  x", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_TAB, raven.R_MOD_SHIFT);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "x", "Rtext_editor_get_text(g_editor)");
    raven.Rwindow_destroy(g_window);
}

fn test_mouse() void {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var a: c_int = undefined;
    var b: c_int = undefined;
    var c: c_int = undefined;
    var d: c_int = undefined;
    open_editor("");
    raven.Rtext_editor_set_text(g_editor, "hello world\nsecond line\nthird");
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(g_editor, &x, &y, &w, &h);

    // a click far right on the second line puts the caret at its end
    raven.Rwindow_inject_mouse_move(g_window, x + w - 30.0, y + 6.0 + 30.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    CHECK_CURSOR(@src(), 1, 11);
    // below the text: the last line
    raven.Rwindow_inject_mouse_move(g_window, x + 9.0, y + h - 10.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    CHECK_CURSOR(@src(), 2, 0);

    // dragging selects
    raven.Rwindow_inject_mouse_move(g_window, x + 9.0, y + 10.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_move(g_window, x + w - 30.0, y + 6.0 + 30.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtext_editor_get_selection(g_editor, &a, &b, &c, &d) != 0, "Rtext_editor_get_selection(g_editor, &a, &b, &c, &d)");
    t.CHECK(@src(), a == 0 and b == 0 and c == 1 and d == 11, "a == 0 && b == 0 && c == 1 && d == 11");

    // a double click selects a word, a triple click the line
    raven.Rwindow_inject_mouse_move(g_window, x + 14.0, y + 10.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "hello", "Rtext_editor_get_selected_text(g_editor)");
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_selected_text(g_editor), "hello world\n", "Rtext_editor_get_selected_text(g_editor)");
    raven.Rwindow_destroy(g_window);
}

fn test_wrap_and_scroll() void {
    var text: [4096]u8 = undefined;
    var i: c_int = undefined;
    var line: c_int = undefined;
    var column: c_int = undefined;
    var length: c_int = 0;
    open_editor("Wrap=\"true\"");

    // one long line: with word wrap it takes several rows, and the arrows move from row to row
    i = 0;
    while (i < 60) : (i += 1) length += t.snprintf(@as([*c]u8, &text) + @as(usize, @intCast(length)), text.len - @as(usize, @intCast(length)), "word%d ", i);
    raven.Rtext_editor_set_text(g_editor, &text);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == 1, "Rtext_editor_get_line_count(g_editor) == 1");
    key(raven.R_KEY_DOWN, 0);
    raven.Rtext_editor_get_cursor(g_editor, &line, &column);
    t.CHECK(@src(), line == 0 and column > 20 and column < 120, "line == 0 && column > 20 && column < 120");
    i = column;
    key(raven.R_KEY_DOWN, 0);
    raven.Rtext_editor_get_cursor(g_editor, &line, &column);
    t.CHECK(@src(), column > i, "column > i");
    // End stops at the end of the row, Home at its start
    key(raven.R_KEY_HOME, 0);
    raven.Rtext_editor_get_cursor(g_editor, &line, &i);
    key(raven.R_KEY_END, 0);
    raven.Rtext_editor_get_cursor(g_editor, &line, &column);
    t.CHECK(@src(), column > i and column < length, "column > i && column < length");
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_HOME, 0);
    CHECK_CURSOR(@src(), 0, 0);
    // without word wrap it is one row again
    raven.Rtext_editor_set_word_wrap(g_editor, raven.R_FALSE);
    _ = raven.Rdraw_frame();
    key(raven.R_KEY_DOWN, 0);
    CHECK_CURSOR(@src(), 0, length);

    // many lines: the caret stays visible, the options and the wheel do not disturb the text
    length = 0;
    i = 0;
    while (i < 200) : (i += 1) length += t.snprintf(@as([*c]u8, &text) + @as(usize, @intCast(length)), text.len - @as(usize, @intCast(length)), "line %d\n", i);
    raven.Rtext_editor_set_text(g_editor, &text);
    raven.Rtext_editor_set_line_numbers(g_editor, raven.R_TRUE);
    raven.Rtext_editor_set_syntax(g_editor, raven.R_SYNTAX_C);
    _ = raven.Rdraw_frame();
    key(raven.R_KEY_END, raven.R_MOD_CTRL);
    CHECK_CURSOR(@src(), 200, 0);
    _ = raven.Rdraw_frame();
    key(raven.R_KEY_PAGE_UP, 0);
    raven.Rtext_editor_get_cursor(g_editor, &line, &column);
    t.CHECK(@src(), line < 200 and line > 150, "line < 200 && line > 150");
    raven.Rwindow_inject_mouse_move(g_window, 100.0, 100.0);
    raven.Rwindow_inject_mouse_wheel(g_window, 0.0, 20.0);
    _ = raven.Rdraw_frame();
    raven.Rtext_editor_scroll_to_line(g_editor, 100);
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == 201, "Rtext_editor_get_line_count(g_editor) == 201");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 199), "line 199", "Rtext_editor_get_line(g_editor, 199)");

    t.EXPECT_ERRORS_BEGIN();
    raven.Rtext_editor_set_tab_size(g_editor, 0);
    raven.Rtext_editor_set_syntax(g_editor, @as(raven.RSyntax, 1));
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    raven.Rwindow_destroy(g_window);
}

fn test_xml() void {
    const xml =
        "<Window Width=\"400\" Height=\"300\">" ++
        "  <TextEditor Name=\"e\" Syntax=\"Xml\" LineNumbers=\"true\" TabSize=\"2\" Font=\"monospace\" Placeholder=\"empty\"" ++
        "    OnChanged=\"doc.changed\">&lt;a&gt;\n  &lt;b/&gt;\n&lt;/a&gt;</TextEditor>" ++
        "</Window>";
    g_window = raven.Rwindow_create_from_xml(xml, xml.len);
    t.CHECK(@src(), raven.Rwindow_is_valid(g_window) != 0, "Rwindow_is_valid(g_window)");
    g_editor = raven.Rwidget_find(g_window, "e");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "<a>\n  <b/>\n</a>", "Rtext_editor_get_text(g_editor)");
    _ = raven.Rdraw_frame();
    // the tag of other toolkits
    raven.Rwindow_destroy(g_window);
    {
        const other = "<Window><TextArea Name=\"e\" Text=\"x\" ReadOnly=\"true\" Wrap=\"true\"/></Window>";
        g_window = raven.Rwindow_create_from_xml(other, other.len);
    }
    t.CHECK(@src(), raven.Rwindow_is_valid(g_window) != 0, "Rwindow_is_valid(g_window)");
    t.CHECK(@src(), raven.Rwidget_get_type(raven.Rwidget_find(g_window, "e")) == raven.R_WIDGET_TEXT_EDITOR, "Rwidget_get_type(Rwidget_find(g_window, \"e\")) == R_WIDGET_TEXT_EDITOR");
    raven.Rwindow_destroy(g_window);

    t.EXPECT_ERRORS_BEGIN();
    {
        const wrong = "<Window><TextEditor Syntax=\"Klingon\"/></Window>";
        g_window = raven.Rwindow_create_from_xml(wrong, wrong.len);
    }
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    if (raven.Rwindow_is_valid(g_window) != 0) raven.Rwindow_destroy(g_window);
}

fn test_large() void {
    // a text of 20 000 lines is loaded, edited at both ends and read back
    const LINES: c_int = 20000;
    const text: [*c]u8 = @ptrCast(t.malloc(@intCast(LINES * 16)));
    var out: [*c]const u8 = undefined;
    var i: c_int = undefined;
    var length: c_int = 0;
    i = 0;
    while (i < LINES) : (i += 1) length += sprintf(text + @as(usize, @intCast(length)), "row %d\n", i);
    open_editor("LineNumbers=\"true\"");
    raven.Rtext_editor_set_text(g_editor, text);
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == LINES + 1, "Rtext_editor_get_line_count(g_editor) == LINES + 1");
    _ = raven.Rdraw_frame();
    key(raven.R_KEY_END, raven.R_MOD_CTRL);
    type_("end");
    key(raven.R_KEY_HOME, raven.R_MOD_CTRL);
    type_("start ");
    _ = raven.Rdraw_frame();
    out = raven.Rtext_editor_get_text(g_editor);
    t.CHECK(@src(), raven.Rtext_editor_get_length(g_editor) == length + 9, "Rtext_editor_get_length(g_editor) == length + 9");
    t.CHECK(@src(), t.strncmp(out, "start row 0\nrow 1\n", 18) == 0, "strncmp(out, \"start row 0\\nrow 1\\n\", 18) == 0");
    t.CHECK(@src(), t.strcmp(out + @as(usize, @intCast(length)) + 6 - 10, "row 19999\nend") == 0, "strcmp(out + length + 6 - 10, \"row 19999\\nend\") == 0");
    key(raven.R_KEY_A, raven.R_MOD_CTRL);
    key(raven.R_KEY_DELETE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_undo(g_editor);
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == LINES + 1, "Rtext_editor_get_line_count(g_editor) == LINES + 1");
    t.free(text);
    raven.Rwindow_destroy(g_window);
}

// ---- languages ----

fn tok(line: c_int, column: c_int) raven.RToken {
    return raven.Rtext_editor_get_token(g_editor, line, column);
}

/// The token at the first occurrence of `word` in a line.
fn tok_of(line: c_int, word: [*c]const u8) raven.RToken {
    const text: [*c]const u8 = raven.Rtext_editor_get_line(g_editor, line);
    const at: [*c]const u8 = if (text != null) t.strstr(text, word) else null;
    if (at == null) {
        _ = t.printf("  (no \"%s\" in line %d)\n", word, line);
        return @bitCast(@as(c_int, -1));
    }
    return tok(line, @intCast(at - text));
}

fn test_languages() void {
    var i: c_int = undefined;
    var found_rust: c_int = 0;
    var desc: raven.RLanguageDesc = undefined;
    open_editor("Language=\"C\"");

    // the built-in languages, by name, by another name, by extension
    t.CHECK(@src(), raven.Rlanguage_get_count() >= 13, "Rlanguage_get_count() >= 13");
    i = 0;
    while (i < raven.Rlanguage_get_count()) : (i += 1) {
        t.CHECK(@src(), raven.Rlanguage_get_name(i) != null, "Rlanguage_get_name(i) != NULL");
        if (t.strcmp(raven.Rlanguage_get_name(i), "Rust") == 0) found_rust = 1;
    }
    t.CHECK(@src(), found_rust != 0, "found_rust");
    t.CHECK(@src(), raven.Rlanguage_get_name(-1) == null, "Rlanguage_get_name(-1) == NULL");
    t.CHECK(@src(), raven.Rlanguage_get_name(raven.Rlanguage_get_count()) == null, "Rlanguage_get_name(Rlanguage_get_count()) == NULL");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "C", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_language(g_editor, "cpp");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "C++", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_language(g_editor, "py");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "Python", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_language(g_editor, "JAVASCRIPT");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "JavaScript", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_language(g_editor, null);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "", "Rtext_editor_get_language(g_editor)");
    t.EXPECT_ERRORS_BEGIN();
    raven.Rtext_editor_set_language(g_editor, "Klingon");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "", "Rtext_editor_get_language(g_editor)");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("/src/main.rs"), "Rust", "Rlanguage_for_file(\"/src/main.rs\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("a.b/Thing.CS"), "C#", "Rlanguage_for_file(\"a.b/Thing.CS\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("index.html"), "HTML", "Rlanguage_for_file(\"index.html\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("x.hpp"), "C++", "Rlanguage_for_file(\"x.hpp\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("x.h"), "C", "Rlanguage_for_file(\"x.h\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("style.css"), "CSS", "Rlanguage_for_file(\"style.css\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("App.java"), "Java", "Rlanguage_for_file(\"App.java\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("app.jsx"), "JavaScript", "Rlanguage_for_file(\"app.jsx\")");
    t.CHECK(@src(), raven.Rlanguage_for_file("notes.txt") == null, "Rlanguage_for_file(\"notes.txt\") == NULL");
    t.CHECK(@src(), raven.Rlanguage_for_file("Makefile") == null, "Rlanguage_for_file(\"Makefile\") == NULL");
    t.CHECK(@src(), raven.Rlanguage_for_file(null) == null, "Rlanguage_for_file(NULL) == NULL");
    t.CHECK(@src(), raven.Rlanguage_get("rust", &desc) != 0 and t.strcmp(desc.name, "Rust") == 0 and (desc.flags & raven.R_LANGUAGE_NESTED_COMMENTS) != 0, "Rlanguage_get(\"rust\", &desc) && strcmp(desc.name, \"Rust\") == 0 && (desc.flags & R_LANGUAGE_NESTED_COMMENTS)");
    t.CHECK(@src(), raven.Rlanguage_get("Klingon", &desc) == 0, "!Rlanguage_get(\"Klingon\", &desc)");
    // the old shorthand
    raven.Rtext_editor_set_syntax(g_editor, raven.R_SYNTAX_XML);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "XML", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_syntax(g_editor, raven.R_SYNTAX_NONE);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "", "Rtext_editor_get_language(g_editor)");
    // no language: everything is text
    raven.Rtext_editor_set_text(g_editor, "int x = 3; // no");
    t.CHECK(@src(), tok(0, 0) == raven.R_TOKEN_TEXT, "tok(0, 0) == R_TOKEN_TEXT");
    t.CHECK(@src(), tok(0, 12) == raven.R_TOKEN_TEXT, "tok(0, 12) == R_TOKEN_TEXT");

    // C
    raven.Rtext_editor_set_language(g_editor, "C");
    raven.Rtext_editor_set_text(g_editor, "#include <stdio.h>\n" ++
        "/* a comment\n" ++
        "   on two lines */ static int count = 0x1F;\n" ++
        "const char* s = \"a \\\" b\"; // tail\n" ++
        "char c = '\\''; size_t n = sizeof(c) + strlen(s) + NULL;\n" ++
        "float f = 1.5e-3f; return foo (f);");
    t.CHECK(@src(), tok(0, 0) == raven.R_TOKEN_DIRECTIVE, "tok(0, 0) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok(0, 12) == raven.R_TOKEN_DIRECTIVE or tok(0, 12) == raven.R_TOKEN_STRING, "tok(0, 12) == R_TOKEN_DIRECTIVE || tok(0, 12) == R_TOKEN_STRING");
    t.CHECK(@src(), tok(1, 5) == raven.R_TOKEN_COMMENT, "tok(1, 5) == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok(2, 5) == raven.R_TOKEN_COMMENT, "tok(2, 5) == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(2, "static") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"static\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "int") == raven.R_TOKEN_TYPE, "tok_of(2, \"int\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "count") == raven.R_TOKEN_TEXT, "tok_of(2, \"count\") == R_TOKEN_TEXT");
    t.CHECK(@src(), tok_of(2, "0x1F") == raven.R_TOKEN_NUMBER, "tok_of(2, \"0x1F\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(3, "const") == raven.R_TOKEN_KEYWORD, "tok_of(3, \"const\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(3, "\"a") == raven.R_TOKEN_STRING, "tok_of(3, \"\\\"a\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(3, " b\"") == raven.R_TOKEN_STRING, "tok_of(3, \" b\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(3, ";") == raven.R_TOKEN_PUNCTUATION or tok_of(3, ";") == raven.R_TOKEN_TEXT, "tok_of(3, \";\") == R_TOKEN_PUNCTUATION || tok_of(3, \";\") == R_TOKEN_TEXT");
    t.CHECK(@src(), tok_of(3, "// tail") == raven.R_TOKEN_COMMENT, "tok_of(3, \"// tail\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(3, "tail") == raven.R_TOKEN_COMMENT, "tok_of(3, \"tail\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(4, "'\\''") == raven.R_TOKEN_STRING, "tok_of(4, \"'\\\\''\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(4, "size_t") == raven.R_TOKEN_TYPE, "tok_of(4, \"size_t\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(4, "sizeof") == raven.R_TOKEN_KEYWORD, "tok_of(4, \"sizeof\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(4, "strlen") == raven.R_TOKEN_FUNCTION, "tok_of(4, \"strlen\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(4, "NULL") == raven.R_TOKEN_KEYWORD or tok_of(4, "NULL") == raven.R_TOKEN_NUMBER, "tok_of(4, \"NULL\") == R_TOKEN_KEYWORD || tok_of(4, \"NULL\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(5, "1.5e-3f") == raven.R_TOKEN_NUMBER, "tok_of(5, \"1.5e-3f\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(5, "e-3f") == raven.R_TOKEN_NUMBER, "tok_of(5, \"e-3f\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(5, "return") == raven.R_TOKEN_KEYWORD, "tok_of(5, \"return\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(5, "foo") == raven.R_TOKEN_FUNCTION, "tok_of(5, \"foo\") == R_TOKEN_FUNCTION");
    // out of range
    t.CHECK(@src(), tok(99, 0) == raven.R_TOKEN_TEXT, "tok(99, 0) == R_TOKEN_TEXT");
    t.CHECK(@src(), tok(0, 999) == raven.R_TOKEN_TEXT, "tok(0, 999) == R_TOKEN_TEXT");

    // C++
    raven.Rtext_editor_set_language(g_editor, "C++");
    raven.Rtext_editor_set_text(g_editor, "template <typename T> class Box : public Base {\n" ++
        "  std::string name = R\"(raw\n" ++
        " still raw)\"; auto p = nullptr;\n" ++
        "};");
    t.CHECK(@src(), tok_of(0, "template") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"template\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "typename") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"typename\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "class") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"class\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "public") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"public\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "string") == raven.R_TOKEN_TYPE, "tok_of(1, \"string\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(1, "raw") == raven.R_TOKEN_STRING, "tok_of(1, \"raw\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(2, "still") == raven.R_TOKEN_STRING, "tok_of(2, \"still\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(2, "auto") == raven.R_TOKEN_KEYWORD or tok_of(2, "auto") == raven.R_TOKEN_TYPE, "tok_of(2, \"auto\") == R_TOKEN_KEYWORD || tok_of(2, \"auto\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "nullptr") != raven.R_TOKEN_TEXT, "tok_of(2, \"nullptr\") != R_TOKEN_TEXT");

    // C#
    raven.Rtext_editor_set_language(g_editor, "C#");
    raven.Rtext_editor_set_text(g_editor, "using System; // c\n" ++
        "[Serializable] public sealed class A { string s = @\"multi\n" ++
        "line\"; var x = await Run(); }");
    t.CHECK(@src(), tok_of(0, "using") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"using\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "// c") == raven.R_TOKEN_COMMENT, "tok_of(0, \"// c\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(1, "sealed") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"sealed\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "string") == raven.R_TOKEN_TYPE, "tok_of(1, \"string\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(1, "multi") == raven.R_TOKEN_STRING, "tok_of(1, \"multi\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(2, "line") == raven.R_TOKEN_STRING, "tok_of(2, \"line\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(2, "await") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"await\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "Run") == raven.R_TOKEN_FUNCTION, "tok_of(2, \"Run\") == R_TOKEN_FUNCTION");

    // Java
    raven.Rtext_editor_set_language(g_editor, "Java");
    raven.Rtext_editor_set_text(g_editor, "@Override public void run() throws Exception {\n" ++
        "  String t = \"\"\"\n" ++
        "    block\n" ++
        "    \"\"\"; final int n = 10_000; boolean b = true;\n" ++
        "}");
    t.CHECK(@src(), tok(0, 0) == raven.R_TOKEN_DIRECTIVE, "tok(0, 0) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(0, "Override") == raven.R_TOKEN_DIRECTIVE, "tok_of(0, \"Override\") == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(0, "public") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"public\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "void") == raven.R_TOKEN_TYPE or tok_of(0, "void") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"void\") == R_TOKEN_TYPE || tok_of(0, \"void\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "run") == raven.R_TOKEN_FUNCTION, "tok_of(0, \"run\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(0, "throws") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"throws\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "String") == raven.R_TOKEN_TYPE, "tok_of(1, \"String\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "block") == raven.R_TOKEN_STRING, "tok_of(2, \"block\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(3, "final") == raven.R_TOKEN_KEYWORD, "tok_of(3, \"final\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(3, "10_000") == raven.R_TOKEN_NUMBER, "tok_of(3, \"10_000\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(3, "true") != raven.R_TOKEN_TEXT, "tok_of(3, \"true\") != R_TOKEN_TEXT");

    // JavaScript
    raven.Rtext_editor_set_language(g_editor, "JavaScript");
    raven.Rtext_editor_set_text(g_editor, "const f = async (a) => { let s = `tpl ${a}\n" ++
        "more`; return 'q' + \"d\"; } /* c */\n" ++
        "function go() { console.log(undefined); }");
    t.CHECK(@src(), tok_of(0, "const") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"const\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "async") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"async\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "let") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"let\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "tpl") == raven.R_TOKEN_STRING, "tok_of(0, \"tpl\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "more") == raven.R_TOKEN_STRING, "tok_of(1, \"more\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "return") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"return\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "'q'") == raven.R_TOKEN_STRING, "tok_of(1, \"'q'\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "\"d\"") == raven.R_TOKEN_STRING, "tok_of(1, \"\\\"d\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "/* c") == raven.R_TOKEN_COMMENT, "tok_of(1, \"/* c\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(2, "function") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"function\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "go") == raven.R_TOKEN_FUNCTION, "tok_of(2, \"go\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(2, "log") == raven.R_TOKEN_FUNCTION, "tok_of(2, \"log\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(2, "undefined") != raven.R_TOKEN_TEXT, "tok_of(2, \"undefined\") != R_TOKEN_TEXT");

    // Python
    raven.Rtext_editor_set_language(g_editor, "Python");
    raven.Rtext_editor_set_text(g_editor, "# comment\n" ++
        "@decorator\n" ++
        "def area(self, r: float) -> float:\n" ++
        "    \"\"\"doc\n" ++
        "    more doc\"\"\"\n" ++
        "    return 3.14 * r ** 2 if r else None  # c\n" ++
        "s = 'it''s' + f\"x\" ; print(len(s))");
    t.CHECK(@src(), tok(0, 0) == raven.R_TOKEN_COMMENT, "tok(0, 0) == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok(0, 5) == raven.R_TOKEN_COMMENT, "tok(0, 5) == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok(1, 0) == raven.R_TOKEN_DIRECTIVE, "tok(1, 0) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(2, "def") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"def\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "area") == raven.R_TOKEN_FUNCTION, "tok_of(2, \"area\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(2, "float") == raven.R_TOKEN_TYPE, "tok_of(2, \"float\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(3, "doc") == raven.R_TOKEN_STRING, "tok_of(3, \"doc\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(4, "more") == raven.R_TOKEN_STRING, "tok_of(4, \"more\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(5, "return") == raven.R_TOKEN_KEYWORD, "tok_of(5, \"return\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(5, "3.14") == raven.R_TOKEN_NUMBER, "tok_of(5, \"3.14\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(5, "if") == raven.R_TOKEN_KEYWORD, "tok_of(5, \"if\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(5, "None") != raven.R_TOKEN_TEXT, "tok_of(5, \"None\") != R_TOKEN_TEXT");
    t.CHECK(@src(), tok_of(5, "# c") == raven.R_TOKEN_COMMENT, "tok_of(5, \"# c\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(6, "'it'") == raven.R_TOKEN_STRING, "tok_of(6, \"'it'\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(6, "print") == raven.R_TOKEN_TYPE or tok_of(6, "print") == raven.R_TOKEN_FUNCTION, "tok_of(6, \"print\") == R_TOKEN_TYPE || tok_of(6, \"print\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(6, "len") == raven.R_TOKEN_TYPE or tok_of(6, "len") == raven.R_TOKEN_FUNCTION, "tok_of(6, \"len\") == R_TOKEN_TYPE || tok_of(6, \"len\") == R_TOKEN_FUNCTION");

    // Rust
    raven.Rtext_editor_set_language(g_editor, "Rust");
    raven.Rtext_editor_set_text(g_editor, "#[derive(Debug)]\n" ++
        "/* outer /* inner */ still comment */ pub fn main() {\n" ++
        "    let x: u32 = 5; let c = 'a'; let r: &'static str = \"s\";\n" ++
        "    println!(\"{}\", x); match x { _ => () }\n" ++
        "    let t = \"two \\\" \n" ++
        "       lines\"; let raw = r#\"a \"quoted\" b\"#; let n = 1;\n" ++
        "}");
    t.CHECK(@src(), tok(0, 0) == raven.R_TOKEN_DIRECTIVE, "tok(0, 0) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(0, "derive") == raven.R_TOKEN_DIRECTIVE, "tok_of(0, \"derive\") == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(1, "inner") == raven.R_TOKEN_COMMENT, "tok_of(1, \"inner\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(1, "still") == raven.R_TOKEN_COMMENT, "tok_of(1, \"still\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(1, "pub") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"pub\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "fn") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"fn\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "main") == raven.R_TOKEN_FUNCTION, "tok_of(1, \"main\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(2, "let") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"let\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "u32") == raven.R_TOKEN_TYPE, "tok_of(2, \"u32\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "'a'") == raven.R_TOKEN_STRING, "tok_of(2, \"'a'\") == R_TOKEN_STRING");
    // a lifetime is not the start of a character
    t.CHECK(@src(), tok_of(2, "str") == raven.R_TOKEN_TYPE, "tok_of(2, \"str\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "\"s\"") == raven.R_TOKEN_STRING, "tok_of(2, \"\\\"s\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(3, "println") == raven.R_TOKEN_FUNCTION or tok_of(3, "println") == raven.R_TOKEN_TYPE, "tok_of(3, \"println\") == R_TOKEN_FUNCTION || tok_of(3, \"println\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(3, "match") == raven.R_TOKEN_KEYWORD, "tok_of(3, \"match\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(4, "two") == raven.R_TOKEN_STRING, "tok_of(4, \"two\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(5, "lines") == raven.R_TOKEN_STRING, "tok_of(5, \"lines\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(5, "let raw") == raven.R_TOKEN_KEYWORD, "tok_of(5, \"let raw\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(5, "quoted") == raven.R_TOKEN_STRING, "tok_of(5, \"quoted\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(5, " b\"#") == raven.R_TOKEN_STRING, "tok_of(5, \" b\\\"#\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(5, "let n") == raven.R_TOKEN_KEYWORD, "tok_of(5, \"let n\") == R_TOKEN_KEYWORD");

    // CSS
    raven.Rtext_editor_set_language(g_editor, "CSS");
    raven.Rtext_editor_set_text(g_editor, "/* c */ .card > a:hover {\n" ++
        "  color: #ff8800; margin: 4px auto; background: url(\"a.png\");\n" ++
        "}\n" ++
        "@media (max-width: 600px) { body { font-family: 'Inter'; } }");
    t.CHECK(@src(), tok(0, 2) == raven.R_TOKEN_COMMENT, "tok(0, 2) == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(0, "card") == raven.R_TOKEN_ATTRIBUTE, "tok_of(0, \"card\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(0, "a:") == raven.R_TOKEN_TAG, "tok_of(0, \"a:\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(0, "hover") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"hover\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "color") == raven.R_TOKEN_ATTRIBUTE, "tok_of(1, \"color\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(1, "#ff8800") == raven.R_TOKEN_NUMBER, "tok_of(1, \"#ff8800\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(1, "margin") == raven.R_TOKEN_ATTRIBUTE, "tok_of(1, \"margin\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(1, "4px") == raven.R_TOKEN_NUMBER, "tok_of(1, \"4px\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(1, "\"a.png\"") == raven.R_TOKEN_STRING, "tok_of(1, \"\\\"a.png\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok(3, 0) == raven.R_TOKEN_DIRECTIVE or tok(3, 0) == raven.R_TOKEN_KEYWORD, "tok(3, 0) == R_TOKEN_DIRECTIVE || tok(3, 0) == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(3, "body") == raven.R_TOKEN_TAG, "tok_of(3, \"body\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(3, "font-family") == raven.R_TOKEN_ATTRIBUTE, "tok_of(3, \"font-family\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(3, "'Inter'") == raven.R_TOKEN_STRING, "tok_of(3, \"'Inter'\") == R_TOKEN_STRING");

    // an interface with its code (ravenc): the code of the scripts in the language of the file
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("main.xmlc"), "XMLC", "Rlanguage_for_file(\"main.xmlc\")");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("main.xmlrs"), "XMLRS", "Rlanguage_for_file(\"main.xmlrs\")");
    raven.Rtext_editor_set_language(g_editor, "XMLC");
    raven.Rtext_editor_set_text(g_editor, "<script>\n" ++
        "static int n = 42; /* c */\n" ++
        "#include <stdio.h>\n" ++
        "</script>\n" ++
        "<Window Title=\"a\"/>");
    t.CHECK(@src(), tok_of(1, "static") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"static\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "int") == raven.R_TOKEN_TYPE or tok_of(1, "int") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"int\") == R_TOKEN_TYPE || tok_of(1, \"int\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(1, "42") == raven.R_TOKEN_NUMBER, "tok_of(1, \"42\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(1, "c */") == raven.R_TOKEN_COMMENT, "tok_of(1, \"c */\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok(2, 0) == raven.R_TOKEN_DIRECTIVE, "tok(2, 0) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(3, "script") == raven.R_TOKEN_TAG, "tok_of(3, \"script\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(4, "Window") == raven.R_TOKEN_TAG, "tok_of(4, \"Window\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(4, "Title") == raven.R_TOKEN_ATTRIBUTE, "tok_of(4, \"Title\") == R_TOKEN_ATTRIBUTE");
    raven.Rtext_editor_set_language(g_editor, "XMLPY");
    raven.Rtext_editor_set_text(g_editor, "<script>\ndef f(): return None\n</script>");
    t.CHECK(@src(), tok_of(1, "def") == raven.R_TOKEN_KEYWORD, "tok_of(1, \"def\") == R_TOKEN_KEYWORD");

    // HTML, with a script and a style inside
    raven.Rtext_editor_set_language(g_editor, "HTML");
    raven.Rtext_editor_set_text(g_editor, "<!DOCTYPE html>\n" ++
        "<div class=\"box\" hidden>text &amp; more<!-- note --></div>\n" ++
        "<style>\n" ++
        "  p { color: red; } /* css */\n" ++
        "</style>\n" ++
        "<script>\n" ++
        "  let n = 42; // js\n" ++
        "  const s = '</div>';\n" ++
        "</script>\n" ++
        "<p>after</p>");
    t.CHECK(@src(), tok(0, 3) == raven.R_TOKEN_DIRECTIVE, "tok(0, 3) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(1, "div") == raven.R_TOKEN_TAG, "tok_of(1, \"div\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(1, "class") == raven.R_TOKEN_ATTRIBUTE, "tok_of(1, \"class\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(1, "\"box\"") == raven.R_TOKEN_STRING, "tok_of(1, \"\\\"box\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "hidden") == raven.R_TOKEN_ATTRIBUTE, "tok_of(1, \"hidden\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(1, "text") == raven.R_TOKEN_TEXT, "tok_of(1, \"text\") == R_TOKEN_TEXT");
    t.CHECK(@src(), tok_of(1, "note") == raven.R_TOKEN_COMMENT, "tok_of(1, \"note\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(2, "style") == raven.R_TOKEN_TAG, "tok_of(2, \"style\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(3, "p {") == raven.R_TOKEN_TAG, "tok_of(3, \"p {\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(3, "color") == raven.R_TOKEN_ATTRIBUTE, "tok_of(3, \"color\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(3, "css") == raven.R_TOKEN_COMMENT, "tok_of(3, \"css\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(4, "style") == raven.R_TOKEN_TAG, "tok_of(4, \"style\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(5, "script") == raven.R_TOKEN_TAG, "tok_of(5, \"script\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(6, "let") == raven.R_TOKEN_KEYWORD, "tok_of(6, \"let\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(6, "42") == raven.R_TOKEN_NUMBER, "tok_of(6, \"42\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(6, "// js") == raven.R_TOKEN_COMMENT, "tok_of(6, \"// js\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(7, "const") == raven.R_TOKEN_KEYWORD, "tok_of(7, \"const\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(8, "script") == raven.R_TOKEN_TAG, "tok_of(8, \"script\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(9, "p>") == raven.R_TOKEN_TAG, "tok_of(9, \"p>\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(9, "after") == raven.R_TOKEN_TEXT, "tok_of(9, \"after\") == R_TOKEN_TEXT");

    // XML and JSON
    raven.Rtext_editor_set_language(g_editor, "XML");
    raven.Rtext_editor_set_text(g_editor, "<?xml version=\"1.0\"?>\n<Button Text=\"Hi\"/> <![CDATA[ <raw> ]]>");
    t.CHECK(@src(), tok(0, 3) == raven.R_TOKEN_DIRECTIVE, "tok(0, 3) == R_TOKEN_DIRECTIVE");
    t.CHECK(@src(), tok_of(1, "Button") == raven.R_TOKEN_TAG, "tok_of(1, \"Button\") == R_TOKEN_TAG");
    t.CHECK(@src(), tok_of(1, "Text") == raven.R_TOKEN_ATTRIBUTE, "tok_of(1, \"Text\") == R_TOKEN_ATTRIBUTE");
    t.CHECK(@src(), tok_of(1, "\"Hi\"") == raven.R_TOKEN_STRING, "tok_of(1, \"\\\"Hi\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(1, "raw") == raven.R_TOKEN_TEXT, "tok_of(1, \"raw\") == R_TOKEN_TEXT");
    raven.Rtext_editor_set_language(g_editor, "json");
    raven.Rtext_editor_set_text(g_editor, "{ \"key\": [1, -2.5, true, null, \"v\"] }");
    t.CHECK(@src(), tok_of(0, "\"key\"") == raven.R_TOKEN_ATTRIBUTE or tok_of(0, "\"key\"") == raven.R_TOKEN_STRING, "tok_of(0, \"\\\"key\\\"\") == R_TOKEN_ATTRIBUTE || tok_of(0, \"\\\"key\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(0, "2.5") == raven.R_TOKEN_NUMBER, "tok_of(0, \"2.5\") == R_TOKEN_NUMBER");
    t.CHECK(@src(), tok_of(0, "true") != raven.R_TOKEN_TEXT, "tok_of(0, \"true\") != R_TOKEN_TEXT");
    t.CHECK(@src(), tok_of(0, "\"v\"") == raven.R_TOKEN_STRING, "tok_of(0, \"\\\"v\\\"\") == R_TOKEN_STRING");

    // edits above move what the lexer knows: the comment opens and closes
    raven.Rtext_editor_set_language(g_editor, "C");
    raven.Rtext_editor_set_text(g_editor, "int a;\nint b;\nint c;");
    t.CHECK(@src(), tok_of(2, "int") == raven.R_TOKEN_TYPE, "tok_of(2, \"int\") == R_TOKEN_TYPE");
    raven.Rtext_editor_set_cursor(g_editor, 0, 0);
    raven.Rtext_editor_insert_text(g_editor, "/*");
    t.CHECK(@src(), tok_of(2, "int") == raven.R_TOKEN_COMMENT, "tok_of(2, \"int\") == R_TOKEN_COMMENT");
    raven.Rtext_editor_set_cursor(g_editor, 1, 0);
    raven.Rtext_editor_insert_text(g_editor, "*/");
    t.CHECK(@src(), tok_of(1, "int") == raven.R_TOKEN_TYPE, "tok_of(1, \"int\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(2, "int") == raven.R_TOKEN_TYPE, "tok_of(2, \"int\") == R_TOKEN_TYPE");
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(g_window);
}

fn test_custom_language() void {
    var desc: raven.RLanguageDesc = undefined;
    var read: raven.RLanguageDesc = undefined;
    var count: c_int = undefined;
    open_editor("");
    count = raven.Rlanguage_get_count();

    desc = std.mem.zeroes(raven.RLanguageDesc);
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rlanguage_register(&desc) == 0, "!Rlanguage_register(&desc)");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rlanguage_register(null) == 0, "!Rlanguage_register(NULL)");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");

    // a language of our own
    desc.name = "Lua";
    desc.extensions = "lua;luau";
    desc.keywords = "function end local if then else return nil";
    desc.types = "print pairs";
    desc.constants = "true false";
    desc.line_comment = "--";
    desc.block_comment_start = "--[[";
    desc.block_comment_end = "]]";
    desc.string_quotes = "\"'";
    t.CHECK(@src(), raven.Rlanguage_register(&desc) != 0, "Rlanguage_register(&desc)");
    t.CHECK(@src(), raven.Rlanguage_get_count() == count + 1, "Rlanguage_get_count() == count + 1");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("init.LUA"), "Lua", "Rlanguage_for_file(\"init.LUA\")");
    t.CHECK(@src(), raven.Rlanguage_get("lua", &read) != 0 and t.strcmp(read.line_comment, "--") == 0, "Rlanguage_get(\"lua\", &read) && strcmp(read.line_comment, \"--\") == 0");
    // (the strings were copied)
    t.CHECK(@src(), read.keywords != desc.keywords, "read.keywords != desc.keywords");

    raven.Rtext_editor_set_language(g_editor, "luau");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(g_editor), "Lua", "Rtext_editor_get_language(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "local function add(a, b) -- sum\n" ++
        "  --[[ long\n" ++
        "  comment ]] return a + b, nil, \"s\"\n" ++
        "end print(add(1, 2))");
    t.CHECK(@src(), tok_of(0, "local") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"local\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "function") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"function\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "add") == raven.R_TOKEN_FUNCTION, "tok_of(0, \"add\") == R_TOKEN_FUNCTION");
    t.CHECK(@src(), tok_of(0, "-- sum") == raven.R_TOKEN_COMMENT, "tok_of(0, \"-- sum\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(1, "long") == raven.R_TOKEN_COMMENT, "tok_of(1, \"long\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(2, "comment") == raven.R_TOKEN_COMMENT, "tok_of(2, \"comment\") == R_TOKEN_COMMENT");
    t.CHECK(@src(), tok_of(2, "return") == raven.R_TOKEN_KEYWORD, "tok_of(2, \"return\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(2, "\"s\"") == raven.R_TOKEN_STRING, "tok_of(2, \"\\\"s\\\"\") == R_TOKEN_STRING");
    t.CHECK(@src(), tok_of(3, "end") == raven.R_TOKEN_KEYWORD, "tok_of(3, \"end\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(3, "print") == raven.R_TOKEN_TYPE, "tok_of(3, \"print\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(3, "1") == raven.R_TOKEN_NUMBER, "tok_of(3, \"1\") == R_TOKEN_NUMBER");

    // declared again, it is replaced: the editors that use it follow
    t.CHECK(@src(), tok_of(0, "sum") == raven.R_TOKEN_COMMENT, "tok_of(0, \"sum\") == R_TOKEN_COMMENT");
    desc.keywords = "function end local if then else return nil sum";
    desc.line_comment = "##";
    t.CHECK(@src(), raven.Rlanguage_register(&desc) != 0, "Rlanguage_register(&desc)");
    t.CHECK(@src(), raven.Rlanguage_get_count() == count + 1, "Rlanguage_get_count() == count + 1");
    t.CHECK(@src(), tok_of(0, "sum") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"sum\") == R_TOKEN_KEYWORD");
    _ = raven.Rdraw_frame();

    // words added to a built-in language
    raven.Rtext_editor_set_language(g_editor, "C");
    raven.Rtext_editor_set_text(g_editor, "Rid window; vec3 v;");
    t.CHECK(@src(), tok_of(0, "Rid") == raven.R_TOKEN_TEXT, "tok_of(0, \"Rid\") == R_TOKEN_TEXT");
    t.CHECK(@src(), raven.Rlanguage_get("C", &read) != 0, "Rlanguage_get(\"C\", &read)");
    {
        var types: [4096]u8 = undefined;
        _ = t.snprintf(&types, types.len, "%s Rid vec3", read.types);
        read.types = &types;
        t.CHECK(@src(), raven.Rlanguage_register(&read) != 0, "Rlanguage_register(&read)");
    }
    t.CHECK(@src(), raven.Rlanguage_get_count() == count + 1, "Rlanguage_get_count() == count + 1");
    t.CHECK(@src(), tok_of(0, "Rid") == raven.R_TOKEN_TYPE, "tok_of(0, \"Rid\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(0, "vec3") == raven.R_TOKEN_TYPE, "tok_of(0, \"vec3\") == R_TOKEN_TYPE");
    t.CHECK(@src(), tok_of(0, "window") == raven.R_TOKEN_TEXT, "tok_of(0, \"window\") == R_TOKEN_TEXT");

    // without case
    desc = std.mem.zeroes(raven.RLanguageDesc);
    desc.name = "Basic";
    desc.keywords = "PRINT GOTO";
    desc.line_comment = "REM";
    desc.flags = raven.R_LANGUAGE_IGNORE_CASE;
    t.CHECK(@src(), raven.Rlanguage_register(&desc) != 0, "Rlanguage_register(&desc)");
    raven.Rtext_editor_set_language(g_editor, "basic");
    raven.Rtext_editor_set_text(g_editor, "10 print x : Goto 10");
    t.CHECK(@src(), tok_of(0, "print") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"print\") == R_TOKEN_KEYWORD");
    t.CHECK(@src(), tok_of(0, "Goto") == raven.R_TOKEN_KEYWORD, "tok_of(0, \"Goto\") == R_TOKEN_KEYWORD");
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(g_window);
}

fn test_assist() void {
    open_editor("Language=\"C\" TabSpaces=\"true\"");

    // brackets and quotes come in pairs, and the closing one is stepped over
    type_("f");
    type_("(");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f()", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 2);
    type_("\"");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f(\"\")", "Rtext_editor_get_text(g_editor)");
    type_("a");
    type_("\"");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f(\"a\")", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 5);
    type_(")");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f(\"a\")", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 6);
    // an empty pair is erased as one
    type_("[");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f(\"a\")[]", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f(\"a\")", "Rtext_editor_get_text(g_editor)");
    // in C an apostrophe holds a character and is left alone; before a word nothing is paired
    raven.Rtext_editor_set_text(g_editor, "");
    type_("'");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "'", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "name");
    raven.Rtext_editor_set_cursor(g_editor, 0, 0);
    type_("(");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "(name", "Rtext_editor_get_text(g_editor)");
    // inside a comment or a text, a bracket is a character
    raven.Rtext_editor_set_text(g_editor, "// say ");
    raven.Rtext_editor_set_cursor(g_editor, 0, 7);
    type_("(");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "// say (", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "s = \"ab\";");
    raven.Rtext_editor_set_cursor(g_editor, 0, 6);
    type_("{");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "s = \"a{b\";", "Rtext_editor_get_text(g_editor)");
    // around the selection
    raven.Rtext_editor_set_text(g_editor, "a + b");
    raven.Rtext_editor_select(g_editor, 0, 0, 0, 5);
    type_("(");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "(a + b)", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "a + b", "Rtext_editor_get_text(g_editor)");

    // Enter after an opening brace: one level deeper, the closing brace on its own line
    raven.Rtext_editor_set_text(g_editor, "    if (x) ");
    raven.Rtext_editor_set_cursor(g_editor, 0, 11);
    type_("{");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "    if (x) {}", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "    if (x) {\n        \n    }", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 1, 8);
    type_("y");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "        y", "Rtext_editor_get_line(g_editor, 1)");
    // one step back
    raven.Rtext_editor_undo(g_editor);
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "    if (x) {}", "Rtext_editor_get_text(g_editor)");
    // without a closing brace after the caret
    raven.Rtext_editor_set_text(g_editor, "\twhile (1) {");
    raven.Rtext_editor_set_tab_inserts_spaces(g_editor, raven.R_FALSE);
    raven.Rtext_editor_set_cursor(g_editor, 0, 12);
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "\twhile (1) {\n\t\t", "Rtext_editor_get_text(g_editor)");
    type_("x;");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "\t\t", "Rtext_editor_get_line(g_editor, 2)");
    // a closing brace alone on its line comes back one level
    type_("}");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "\t}", "Rtext_editor_get_line(g_editor, 2)");

    // Ctrl+/ comments lines out and back in
    raven.Rtext_editor_set_text(g_editor, "    a();\n        b();\n\n    c();");
    raven.Rtext_editor_select(g_editor, 0, 2, 3, 3);
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "    // a();\n    //     b();\n\n    // c();", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), tok_of(1, "b") == raven.R_TOKEN_COMMENT, "tok_of(1, \"b\") == R_TOKEN_COMMENT");
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "    a();\n        b();\n\n    c();", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_cursor(g_editor, 1, 10);
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "        // b();", "Rtext_editor_get_line(g_editor, 1)");
    CHECK_CURSOR(@src(), 1, 13);
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "        b();", "Rtext_editor_get_line(g_editor, 1)");
    CHECK_CURSOR(@src(), 1, 10);
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "        // b();", "Rtext_editor_get_line(g_editor, 1)");

    // Python: a colon opens a block, and its comments start with a hash
    raven.Rtext_editor_set_language(g_editor, "Python");
    raven.Rtext_editor_set_tab_inserts_spaces(g_editor, raven.R_TRUE);
    raven.Rtext_editor_set_text(g_editor, "def f(x):");
    raven.Rtext_editor_set_cursor(g_editor, 0, 9);
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "def f(x):\n    ", "Rtext_editor_get_text(g_editor)");
    type_("'");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    ''", "Rtext_editor_get_line(g_editor, 1)");
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    ", "Rtext_editor_get_line(g_editor, 1)");
    type_("pass");
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    # pass", "Rtext_editor_get_line(g_editor, 1)");

    // HTML: the closing tag comes with the opening one, and Enter opens it up
    raven.Rtext_editor_set_language(g_editor, "HTML");
    raven.Rtext_editor_set_text(g_editor, "");
    type_("<div class=");
    type_("\"");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "<div class=\"\"", "Rtext_editor_get_text(g_editor)");
    type_("a");
    type_("\"");
    type_(">");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "<div class=\"a\"></div>", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 0, 15);
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "<div class=\"a\">\n    \n</div>", "Rtext_editor_get_text(g_editor)");
    CHECK_CURSOR(@src(), 1, 4);
    // elements without content, and closing tags, are left alone
    type_("<br");
    type_(">");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    <br>", "Rtext_editor_get_line(g_editor, 1)");
    type_("</p");
    type_(">");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    <br></p>", "Rtext_editor_get_line(g_editor, 1)");
    // (a language without line comments: nothing happens)
    key(raven.R_KEY_SLASH, raven.R_MOD_CTRL);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "    <br></p>", "Rtext_editor_get_line(g_editor, 1)");

    // all of it can be turned off
    raven.Rtext_editor_set_language(g_editor, "C");
    raven.Rtext_editor_set_auto_pairs(g_editor, raven.R_FALSE);
    raven.Rtext_editor_set_text(g_editor, "");
    type_("f");
    type_("(");
    type_("{");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f({", "Rtext_editor_get_text(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "f({\n", "Rtext_editor_get_text(g_editor)");
    raven.Rwindow_destroy(g_window);

    // and without a language it never acts
    open_editor("");
    type_("(");
    type_("\"");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "(\"", "Rtext_editor_get_text(g_editor)");
    raven.Rwindow_destroy(g_window);
    open_editor("Language=\"Rust\" AutoPairs=\"false\" Completion=\"false\"");
    type_("{");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "{", "Rtext_editor_get_text(g_editor)");
    raven.Rwindow_destroy(g_window);
}

var g_completion_calls: c_int = 0;
var g_completion_prefix: [64]u8 = std.mem.zeroes([64]u8);

fn on_complete(editor: raven.Rid, prefix: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    g_completion_calls += 1;
    _ = t.snprintf(&g_completion_prefix, g_completion_prefix.len, "%s", prefix);
    t.CHECK(@src(), user_data == @as(?*anyopaque, @ptrCast(&g_completion_calls)), "user_data == (void*)&g_completion_calls");
    raven.Rtext_editor_add_completion(editor, "window_title", "field");
    raven.Rtext_editor_add_completion(editor, "whatever", null);
    raven.Rtext_editor_add_completion(editor, "", null);
    raven.Rtext_editor_add_completion(editor, null, null);
}

fn test_completion() void {
    open_editor("Language=\"C\"");
    raven.Rtext_editor_set_text(g_editor, "int whisker_count = 0;\nint whisper = 1;\n");
    raven.Rtext_editor_set_cursor(g_editor, 2, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");

    // one character is not enough, two are
    type_("w");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    type_("h");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    _ = raven.Rdraw_frame();
    // "while" (keyword), then the names of the text: Enter takes the first
    type_("i");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    type_("s");
    _ = raven.Rdraw_frame();
    // whisker_count, whisper
    key(raven.R_KEY_DOWN, 0);
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "whisper", "Rtext_editor_get_line(g_editor, 2)");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    t.CHECK(@src(), raven.Rtext_editor_get_line_count(g_editor) == 3, "Rtext_editor_get_line_count(g_editor) == 3");
    // one step of history
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "whis", "Rtext_editor_get_line(g_editor, 2)");
    raven.Rtext_editor_undo(g_editor);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "", "Rtext_editor_get_line(g_editor, 2)");

    // a keyword, chosen with Tab; the arrows wrap around
    type_("ret");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_UP, 0);
    key(raven.R_KEY_DOWN, 0);
    key(raven.R_KEY_TAB, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "return", "Rtext_editor_get_line(g_editor, 2)");
    CHECK_CURSOR(@src(), 2, 6);

    // Escape closes the list and keeps the keyboard in the editor
    type_(" wh");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_ESCAPE, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    t.CHECK(@src(), raven.Rwidget_is_focused(g_editor) != 0, "Rwidget_is_focused(g_editor)");
    type_("x");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 2), "return whx", "Rtext_editor_get_line(g_editor, 2)");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");

    // erasing narrows back, down to nothing; moving away closes
    raven.Rtext_editor_set_text(g_editor, "int whisker_count = 0;\n");
    raven.Rtext_editor_set_cursor(g_editor, 1, 0);
    type_("whi");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_BACKSPACE, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    type_("whi");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_LEFT, 0);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_RIGHT, 0);
    // a character that is not of a word ends it
    type_("s");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    type_(";");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "whis;", "Rtext_editor_get_line(g_editor, 1)");

    // nothing to propose: no list. Numbers are not words
    raven.Rtext_editor_set_text(g_editor, "");
    type_("zq");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "");
    type_("12");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");

    // Ctrl+Space: asked for, even with one character, even with none
    raven.Rtext_editor_set_text(g_editor, "");
    type_("s");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_SPACE, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "s", "Rtext_editor_get_text(g_editor)");
    type_("w");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "switch", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "");
    raven.Rtext_editor_show_completions(g_editor);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    _ = raven.Rdraw_frame();
    key(raven.R_KEY_ESCAPE, 0);

    // the application adds its own, listed first
    raven.Rtext_editor_set_completion_callback(g_editor, on_complete, &g_completion_calls);
    raven.Rtext_editor_set_text(g_editor, "");
    g_completion_calls = 0;
    type_("wh");
    t.CHECK(@src(), g_completion_calls == 1, "g_completion_calls == 1");
    t.CHECK_STR(@src(), &g_completion_prefix, "wh", "g_completion_prefix");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "whatever", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "");
    type_("wi");
    t.CHECK(@src(), g_completion_calls == 2, "g_completion_calls == 2");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "window_title", "Rtext_editor_get_text(g_editor)");
    // outside of the callback it is an error
    t.EXPECT_ERRORS_BEGIN();
    raven.Rtext_editor_add_completion(g_editor, "nope", null);
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    raven.Rtext_editor_set_completion_callback(g_editor, null, null);

    // turned off, the editor does not propose by itself; Ctrl+Space still does
    raven.Rtext_editor_set_completion(g_editor, raven.R_FALSE);
    raven.Rtext_editor_set_text(g_editor, "");
    type_("whi");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_SPACE, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    type_("l");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "while", "Rtext_editor_get_text(g_editor)");
    raven.Rtext_editor_set_completion(g_editor, raven.R_TRUE);

    // a click in the list chooses; a click elsewhere closes it
    raven.Rtext_editor_set_text(g_editor, "");
    type_("un");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    _ = raven.Rdraw_frame();
    _ = raven.Rdraw_frame();
    {
        // the list is below the first line, at the left of the editor
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        raven.Rwidget_get_rect(g_editor, &x, &y, &w, &h);
        raven.Rwindow_inject_mouse_move(g_window, x + 40.0, y + 44.0);
        raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
        raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    }
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    t.CHECK(@src(), t.strncmp(raven.Rtext_editor_get_text(g_editor), "un", 2) == 0 and t.strlen(raven.Rtext_editor_get_text(g_editor)) > 2, "strncmp(Rtext_editor_get_text(g_editor), \"un\", 2) == 0 && strlen(Rtext_editor_get_text(g_editor)) > 2");
    t.CHECK(@src(), raven.Rwidget_is_focused(g_editor) != 0, "Rwidget_is_focused(g_editor)");
    raven.Rtext_editor_set_text(g_editor, "\n\n\n\n\n\n\n\n\n\n");
    type_("un");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    _ = raven.Rdraw_frame();
    raven.Rwindow_inject_mouse_move(g_window, 300.0, 250.0);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_TRUE);
    raven.Rwindow_inject_mouse_button(g_window, raven.R_MOUSE_LEFT, raven.R_FALSE);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");

    // read only: nothing; destroyed while the list is shown: nothing left behind
    raven.Rtext_editor_set_text(g_editor, "");
    type_("wh");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    raven.Rwindow_destroy(g_window);
    _ = raven.Rdraw_frame();

    open_editor("Language=\"Python\"");
    type_("im");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    raven.Rwidget_destroy(g_editor);
    _ = raven.Rdraw_frame();
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(g_window);

    // without a language the editor proposes nothing by itself, but Ctrl+Space gives the words of the text
    open_editor("");
    raven.Rtext_editor_set_text(g_editor, "elephant\n");
    raven.Rtext_editor_set_cursor(g_editor, 1, 0);
    type_("ele");
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) == 0, "!Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_SPACE, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtext_editor_is_completing(g_editor) != 0, "Rtext_editor_is_completing(g_editor)");
    key(raven.R_KEY_ENTER, 0);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 1), "elephant", "Rtext_editor_get_line(g_editor, 1)");
    raven.Rwindow_destroy(g_window);
}

fn test_markers_and_brackets() void {
    open_editor("Language=\"C\" LineNumbers=\"true\"");
    raven.Rtext_editor_set_text(g_editor, "int a;\nint b = c;\nint d;\nint e;");
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 0, "Rtext_editor_get_marker_count(g_editor) == 0");
    raven.Rtext_editor_add_marker(g_editor, 1, 8, 9, raven.R_MARKER_ERROR, "'c' undeclared");
    raven.Rtext_editor_add_marker(g_editor, 3, 0, -1, raven.R_MARKER_WARNING, "unused variable 'e'");
    raven.Rtext_editor_add_marker(g_editor, 99, -5, 400, raven.R_MARKER_INFO, null);
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 3, "Rtext_editor_get_marker_count(g_editor) == 3");
    t.EXPECT_ERRORS_BEGIN();
    raven.Rtext_editor_add_marker(g_editor, 0, 0, 1, @as(raven.RMarkerKind, 7), "x");
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 3, "Rtext_editor_get_marker_count(g_editor) == 3");
    _ = raven.Rdraw_frame();

    // the message of the marker under the pointer is the tooltip of the editor
    {
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        var py: f32 = undefined;
        // `error` is a Zig keyword: the local is `error_`
        var error_: c_int = 0;
        var warning: c_int = 0;
        var none: c_int = 0;
        raven.Rwidget_get_rect(g_editor, &x, &y, &w, &h);
        t.CHECK_STR(@src(), raven.Rwidget_get_tooltip(g_editor), "", "Rwidget_get_tooltip(g_editor)");
        py = y + 2.0;
        while (py < y + 120.0) : (py += 3.0) {
            var px: f32 = undefined;
            px = x + 4.0;
            while (px < x + 200.0) : (px += 3.0) {
                var tip: [*c]const u8 = undefined;
                raven.Rwindow_inject_mouse_move(g_window, px, py);
                tip = raven.Rwidget_get_tooltip(g_editor);
                if (t.strcmp(tip, "unused variable 'e'") == 0) {
                    warning += 1;
                } else if (t.strcmp(tip, "'c' undeclared") == 0) {
                    error_ += 1;
                } else if (tip[0] == '\x00') {
                    none += 1;
                } else t.CHECK(@src(), false, "0");
            }
        }
        // a line of six characters against one character: more of the first, and mostly nothing
        t.CHECK(@src(), warning > error_ and error_ > 0 and none > warning, "warning > error && error > 0 && none > warning");
        // past the end of the line, below the text: nothing
        raven.Rwindow_inject_mouse_move(g_window, x + w - 60.0, y + 40.0);
        t.CHECK_STR(@src(), raven.Rwidget_get_tooltip(g_editor), "", "Rwidget_get_tooltip(g_editor)");
        raven.Rwindow_inject_mouse_move(g_window, x + w - 60.0, y + h - 30.0);
        t.CHECK_STR(@src(), raven.Rwidget_get_tooltip(g_editor), "", "Rwidget_get_tooltip(g_editor)");
    }

    // lines added above push the markers down; editing their line removes them
    raven.Rtext_editor_set_cursor(g_editor, 0, 0);
    raven.Rtext_editor_insert_text(g_editor, "/* top */\n\n");
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 3, "Rtext_editor_get_marker_count(g_editor) == 3");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_line(g_editor, 3), "int b = c;", "Rtext_editor_get_line(g_editor, 3)");
    raven.Rtext_editor_set_cursor(g_editor, 3, 9);
    raven.Rtext_editor_insert_text(g_editor, "c");
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 2, "Rtext_editor_get_marker_count(g_editor) == 2");
    // removing lines above pulls them back up
    raven.Rtext_editor_select(g_editor, 0, 0, 2, 0);
    key(raven.R_KEY_DELETE, 0);
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 2, "Rtext_editor_get_marker_count(g_editor) == 2");
    _ = raven.Rdraw_frame();
    raven.Rtext_editor_undo(g_editor);
    _ = raven.Rdraw_frame();
    raven.Rtext_editor_clear_markers(g_editor);
    t.CHECK(@src(), raven.Rtext_editor_get_marker_count(g_editor) == 0, "Rtext_editor_get_marker_count(g_editor) == 0");
    raven.Rtext_editor_clear_markers(g_editor);
    _ = raven.Rdraw_frame();

    // bracket matching is only painted: it must hold with any text
    raven.Rtext_editor_set_text(g_editor, "f(a[1], \"(\", /* ) */ {x}) ]\n)(");
    {
        var column: c_int = undefined;
        column = 0;
        while (column <= 27) : (column += 1) {
            raven.Rtext_editor_set_cursor(g_editor, 0, column);
            _ = raven.Rdraw_frame();
        }
        raven.Rtext_editor_set_cursor(g_editor, 1, 1);
        _ = raven.Rdraw_frame();
    }
    raven.Rwindow_destroy(g_window);
}

/// a zoom, to the percent.  CHECK_ZOOM(actual, expected)
fn CHECK_ZOOM(src: t.Src, actual: f64, expected: f64, text: [*:0]const u8) void {
    const test_a_: f64 = actual;
    const test_e_: f64 = expected;
    t.g_test_checks += 1;
    if (t.fabs(test_a_ - test_e_) > 0.006) {
        t.g_test_failures += 1;
        _ = t.printf("  FAIL %s:%d: %s = %g, expected %g\n", src.file.ptr, @as(c_int, @intCast(src.line)), text, test_a_, test_e_);
    }
}

var g_zooms: c_int = 0;
var g_zoom_seen: f32 = 0;

fn on_zoom(editor: raven.Rid, zoom: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = editor;
    _ = user_data;
    g_zooms += 1;
    g_zoom_seen = zoom;
}

/// The line under a point of the window: where a click there puts the caret.
fn line_at(x: f32, y: f32) c_int {
    var line: c_int = -1;
    var column: c_int = -1;
    // (a click somewhere else first: clicks at the same place would make a double, then a triple click)
    t.test_click_at(g_window, x - 60.0, y - 60.0);
    t.test_click_at(g_window, x, y);
    _ = raven.Rdraw_frame();
    raven.Rtext_editor_get_cursor(g_editor, &line, &column);
    return line;
}

fn zoom_wheel(x: f32, y: f32, notches: f32) void {
    // (a move carries its own modifiers: the pointer goes there first, then Ctrl is held)
    raven.Rwindow_inject_mouse_move(g_window, x, y);
    raven.Rwindow_inject_key(g_window, raven.R_KEY_LEFT_CTRL, raven.R_TRUE, raven.R_MOD_CTRL);
    raven.Rwindow_inject_mouse_wheel(g_window, 0.0, notches);
    raven.Rwindow_inject_key(g_window, raven.R_KEY_LEFT_CTRL, raven.R_FALSE, 0);
    _ = raven.Rdraw_frame();
}

fn test_zoom() void {
    var text: [24000]u8 = undefined;
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var i: c_int = undefined;
    var before: c_int = undefined;
    var wrapped: c_int = undefined;
    wrapped = 0;
    while (wrapped < 2) : (wrapped += 1) {
        open_editor(if (wrapped != 0) @as([*c]const u8, "LineNumbers=\"true\" Wrap=\"true\"") else "LineNumbers=\"true\" Language=\"C\"");
        text[0] = '\x00';
        i = 0;
        while (i < 300) : (i += 1) {
            var line: [80]u8 = undefined;
            _ = t.snprintf(&line, line.len, "int value_%d = %d; /* a comment long enough to wrap */\n", i, i);
            _ = strcat(&text, &line);
        }
        raven.Rtext_editor_set_text(g_editor, &text);
        raven.Rtext_editor_set_zoom_callback(g_editor, on_zoom, null);
        g_zooms = 0;
        _ = raven.Rdraw_frame();
        raven.Rwidget_get_rect(g_editor, &x, &y, &w, &h);
        x += w * 0.4;
        y += h * 0.6;
        raven.Rtext_editor_scroll_to_line(g_editor, 120);
        i = 0;
        while (i < 30) : (i += 1) _ = raven.Rdraw_frame();
        CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.0), "Rtext_editor_get_zoom(g_editor)");

        // Ctrl + wheel zooms around the pointer: the line under it stays under it
        before = line_at(x, y);
        zoom_wheel(x, y, 1.0);
        CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.1), "Rtext_editor_get_zoom(g_editor)");
        t.CHECK(@src(), g_zooms == 1, "g_zooms == 1");
        CHECK_ZOOM(@src(), g_zoom_seen, @as(f32, 1.1), "g_zoom_seen");
        zoom_wheel(x, y, 3.0);
        t.CHECK(@src(), line_at(x, y) == before, "line_at(x, y) == before");
        zoom_wheel(x, y, -6.0);
        t.CHECK(@src(), raven.Rtext_editor_get_zoom(g_editor) < 1.0, "Rtext_editor_get_zoom(g_editor) < 1.0f");
        t.CHECK(@src(), line_at(x, y) == before, "line_at(x, y) == before");
        // it never types nor scrolls
        t.CHECK(@src(), g_changes == 0, "g_changes == 0");
        raven.Rwindow_destroy(g_window);
    }

    open_editor("");
    raven.Rtext_editor_set_text(g_editor, "abc");
    raven.Rtext_editor_set_zoom_callback(g_editor, on_zoom, null);
    g_zooms = 0;
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(g_editor, &x, &y, &w, &h);
    x += 20.0;
    y += 20.0;
    // the keys: Ctrl + '=' / keypad '+', Ctrl + '-' / keypad '-', Ctrl + 0; nothing is typed
    key(raven.R_KEY_EQUAL, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.1), "Rtext_editor_get_zoom(g_editor)");
    key(raven.R_KEY_KP_ADD, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.21), "Rtext_editor_get_zoom(g_editor)");
    key(raven.R_KEY_MINUS, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.1), "Rtext_editor_get_zoom(g_editor)");
    key(raven.R_KEY_0, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.0), "Rtext_editor_get_zoom(g_editor)");
    key(raven.R_KEY_KP_SUBTRACT, raven.R_MOD_CTRL);
    t.CHECK(@src(), raven.Rtext_editor_get_zoom(g_editor) < 1.0, "Rtext_editor_get_zoom(g_editor) < 1.0f");
    t.CHECK(@src(), g_zooms == 5, "g_zooms == 5");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_text(g_editor), "abc", "Rtext_editor_get_text(g_editor)");
    t.CHECK(@src(), g_changes == 0, "g_changes == 0");
    // the limits, and back to 100 % near it
    zoom_wheel(x, y, 100.0);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 4.0), "Rtext_editor_get_zoom(g_editor)");
    zoom_wheel(x, y, -200.0);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 0.5), "Rtext_editor_get_zoom(g_editor)");
    raven.Rtext_editor_set_zoom(g_editor, 1.02);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.0), "Rtext_editor_get_zoom(g_editor)");
    // set by the program: nobody is told
    i = g_zooms;
    raven.Rtext_editor_set_zoom(g_editor, 2.0);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 2.0), "Rtext_editor_get_zoom(g_editor)");
    t.CHECK(@src(), g_zooms == i, "g_zooms == i");
    // not zoomable: Ctrl + wheel and the keys leave it
    raven.Rtext_editor_set_zoomable(g_editor, raven.R_FALSE);
    zoom_wheel(x, y, 1.0);
    key(raven.R_KEY_0, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 2.0), "Rtext_editor_get_zoom(g_editor)");
    t.CHECK(@src(), g_zooms == i, "g_zooms == i");
    raven.Rwindow_destroy(g_window);

    // XML
    open_editor("Zoom=\"1.5\" Zoomable=\"false\"");
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.5), "Rtext_editor_get_zoom(g_editor)");
    key(raven.R_KEY_0, raven.R_MOD_CTRL);
    CHECK_ZOOM(@src(), raven.Rtext_editor_get_zoom(g_editor), @as(f32, 1.5), "Rtext_editor_get_zoom(g_editor)");
    raven.Rwindow_destroy(g_window);
}

export fn main() c_int {
    if (t.test_init(0) == 0) return 1;

    t.RUN(test_content, "test_content");
    t.RUN(test_typing, "test_typing");
    t.RUN(test_navigation, "test_navigation");
    t.RUN(test_clipboard_and_history, "test_clipboard_and_history");
    t.RUN(test_indent, "test_indent");
    t.RUN(test_mouse, "test_mouse");
    t.RUN(test_wrap_and_scroll, "test_wrap_and_scroll");
    t.RUN(test_xml, "test_xml");
    t.RUN(test_large, "test_large");
    t.RUN(test_languages, "test_languages");
    t.RUN(test_custom_language, "test_custom_language");
    t.RUN(test_assist, "test_assist");
    t.RUN(test_completion, "test_completion");
    t.RUN(test_markers_and_brackets, "test_markers_and_brackets");
    t.RUN(test_zoom, "test_zoom");

    raven.Rshutdown();
    return t.test_report("test_text_editor");
}
