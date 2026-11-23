// Translated to Zig from vendor/raven/examples/notepad/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - notepad
// A small text editor: what a real one is made of.
//
//   custom header     the title bar is a widget of the window (notepad.xml)
//   TextEditor        several lines, undo, clipboard; with a language: colors,
//                     proposals while typing, brackets, indentation, Ctrl+/
//   languages         the list of the library, chosen from the name of the file
//                     (Rlanguage_for_file), plus one declared here (INI)
//   completion        a callback adds its own proposals to those of the editor
//   markers           the lines that say TODO or FIXME are underlined
//   file dialogs      the ones of the system (Rfile_dialog_open / save)
//   message box       "discard the changes?" before losing them
//   drag and drop     a file dropped on the window is opened
//
// Run it with a file to open it:  raven_notepad main.c

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// (<ctype.h> is included by the C file but none of its functions is used.)
// (#ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR ".": the module `example` always defines it.)

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    editor: raven.Rid,
    header: raven.Rid,
    language: raven.Rid,
    status: raven.Rid,
    notes: raven.Rid,
    position: raven.Rid,
    path: [1024]u8,
    modified: c_int,
    /// Set while the program itself changes the editor or the list of languages.
    loading: c_int,
    scan_timer: raven.Rid,
    last_line: c_int,
    last_column: c_int,
});

// ---------------------------------------------------------------------------
//  Title, status
// -------------------------------------------------------------------------

fn file_name(path: [*c]const u8) [*c]const u8 {
    var slash: [*c]const u8 = example.strrchr(path, '/');
    const backslash: [*c]const u8 = example.strrchr(path, '\\');
    if (backslash != null and (slash == null or backslash > slash)) slash = backslash;
    return if (slash != null) slash + 1 else path;
}

fn update_title() void {
    var title: [1100]u8 = undefined;
    _ = example.snprintf(&title, title.len, "%s%s - Raven Notepad", if (app.path[0] != 0) file_name(&app.path) else @as([*c]const u8, "Untitled"), @as([*c]const u8, if (app.modified != 0) " *" else ""));
    // the header bar shows the title of its window
    raven.Rwindow_set_title(app.window, &title);
}

fn set_status(format: [*c]const u8, detail: [*c]const u8) void {
    var text: [1200]u8 = undefined;
    _ = example.snprintf(&text, text.len, format, detail);
    raven.Rlabel_set_text(app.status, &text);
}

// The position of the cursor, read once per frame: cheap, and nothing to wire.
fn on_frame(delta_seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    var line: c_int = 0;
    var column: c_int = 0;
    var text: [64]u8 = undefined;
    _ = delta_seconds;
    _ = user_data;
    if (raven.Rwidget_is_valid(app.editor) == 0) return;
    raven.Rtext_editor_get_cursor(app.editor, &line, &column);
    if (line == app.last_line and column == app.last_column) return;
    app.last_line = line;
    app.last_column = column;
    _ = example.snprintf(&text, text.len, "Line %d, column %d", line + 1, column + 1);
    raven.Rlabel_set_text(app.position, &text);
}

// ---------------------------------------------------------------------------
//  Languages
// -------------------------------------------------------------------------

// A language of our own: the editor only needs to be told what its words and comments look like.
fn register_ini() void {
    var ini: raven.RLanguageDesc = undefined;
    @memset(std.mem.asBytes(&ini), 0);
    ini.name = "INI";
    ini.extensions = "ini;cfg;conf";
    ini.constants = "true false yes no on off";
    ini.line_comment = ";";
    ini.string_quotes = "\"";
    ini.flags = raven.R_LANGUAGE_IGNORE_CASE;
    _ = raven.Rlanguage_register(&ini);
}

fn fill_languages() void {
    var i: c_int = undefined;
    app.loading += 1;
    raven.Rcombo_box_clear_items(app.language);
    _ = raven.Rcombo_box_add_item(app.language, "Plain text");
    i = 0;
    while (i < raven.Rlanguage_get_count()) : (i += 1) _ = raven.Rcombo_box_add_item(app.language, raven.Rlanguage_get_name(i));
    raven.Rcombo_box_set_selected(app.language, 0);
    app.loading -= 1;
}

fn set_language(name: [*c]const u8) void {
    var i: c_int = undefined;
    raven.Rtext_editor_set_language(app.editor, name);
    app.loading += 1;
    raven.Rcombo_box_set_selected(app.language, 0);
    i = 0;
    while (name != null and i < raven.Rlanguage_get_count()) : (i += 1) {
        if (example.strcmp(raven.Rlanguage_get_name(i), name) == 0) raven.Rcombo_box_set_selected(app.language, i + 1);
    }
    app.loading -= 1;
}

fn action_language(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const index: c_int = raven.Rcombo_box_get_selected(app.language);
    _ = sender;
    _ = action;
    _ = user_data;
    if (app.loading != 0) return;
    raven.Rtext_editor_set_language(app.editor, if (index > 0) raven.Rlanguage_get_name(index - 1) else null);
    raven.Rwidget_focus(app.editor);
}

//
// Proposals of the application, listed before those of the editor (the words
// of the language and the names already in the text): here, a few snippets.
// A language server would answer in the same place.
//
fn on_complete(editor: raven.Rid, prefix: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const snippets = [_]struct { language: [*c]const u8, text: [*c]const u8, detail: [*c]const u8 }{
        .{ .language = "C", .text = "printf(\"%d\\n\", );", .detail = "snippet" }, .{ .language = "C", .text = "for (int i = 0; i < n; i++) {", .detail = "snippet" },
        .{ .language = "C", .text = "#include <stdio.h>", .detail = "snippet" },  .{ .language = "C++", .text = "std::cout << ", .detail = "snippet" },
        .{ .language = "Python", .text = "print(f\"{}\")", .detail = "snippet" }, .{ .language = "Python", .text = "if __name__ == \"__main__\":", .detail = "snippet" },
        .{ .language = "Rust", .text = "println!(\"{}\", );", .detail = "snippet" }, .{ .language = "JavaScript", .text = "console.log();", .detail = "snippet" },
        .{ .language = "HTML", .text = "<!DOCTYPE html>", .detail = "snippet" },  .{ .language = "Java", .text = "System.out.println();", .detail = "snippet" },
    };
    const language: [*c]const u8 = raven.Rtext_editor_get_language(editor);
    var i: usize = undefined;
    _ = user_data;
    _ = prefix;
    // (the editor only keeps those that start with what is typed)
    i = 0;
    while (i < snippets.len) : (i += 1) {
        if (example.strcmp(snippets[i].language, language) == 0) raven.Rtext_editor_add_completion(editor, snippets[i].text, snippets[i].detail);
    }
    raven.Rtext_editor_add_completion(editor, "TODO", "note");
    raven.Rtext_editor_add_completion(editor, "FIXME", "note");
}

// ---------------------------------------------------------------------------
//  Markers: the notes left in the text
// -------------------------------------------------------------------------

fn scan_notes(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const count: c_int = raven.Rtext_editor_get_line_count(app.editor);
    var line: c_int = undefined;
    var found: c_int = 0;
    var text: [64]u8 = undefined;
    _ = timer;
    _ = user_data;
    app.scan_timer = raven.R_INVALID_ID;
    raven.Rtext_editor_clear_markers(app.editor);
    line = 0;
    while (line < count and found < 200) : (line += 1) {
        const content: [*c]const u8 = raven.Rtext_editor_get_line(app.editor, line);
        const todo: [*c]const u8 = if (content != null) example.strstr(content, "TODO") else null;
        const fixme: [*c]const u8 = if (content != null) example.strstr(content, "FIXME") else null;
        if (fixme != null) {
            raven.Rtext_editor_add_marker(app.editor, line, @intCast(fixme - content), -1, raven.R_MARKER_WARNING, "Something to fix");
            found += 1;
        } else if (todo != null) {
            raven.Rtext_editor_add_marker(app.editor, line, @intCast(todo - content), -1, raven.R_MARKER_INFO, "Something left to do");
            found += 1;
        }
    }
    if (found != 0) {
        _ = example.snprintf(&text, text.len, "%d note%s", found, @as([*c]const u8, if (found > 1) "s" else ""));
    } else text[0] = 0;
    raven.Rlabel_set_text(app.notes, &text);
}

fn on_changed(editor: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = editor;
    _ = user_data;
    if (app.modified == 0) {
        app.modified = raven.R_TRUE;
        update_title();
    }
    // scanned once the typing pauses
    if (app.scan_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(app.scan_timer) != 0) raven.Rtimer_destroy(app.scan_timer);
    app.scan_timer = raven.Rtimer_create(0.4, raven.R_FALSE, scan_notes, null);
}

// ---------------------------------------------------------------------------
//  Files
// -------------------------------------------------------------------------

const g_filters = [_]raven.RFileFilter{
    .{ .name = "Text and code", .patterns = "*.txt;*.md;*.c;*.h;*.cpp;*.hpp;*.cs;*.java;*.js;*.ts;*.py;*.rs;*.html;*.css;*.xml;*.json;*.ini" },
    .{ .name = "All files", .patterns = "*" },
};

// R_TRUE when the text can be replaced: nothing to lose, or the user agreed to lose it.
fn can_discard() c_int {
    if (app.modified == 0) return raven.R_TRUE;
    return @intFromBool(raven.Rmessage_box(app.window, "Unsaved changes", "The text has changes that were not saved. Discard them?", raven.R_MESSAGE_OK_CANCEL) ==
        raven.R_MESSAGE_RESULT_OK);
}

fn open_path(path: [*c]const u8) void {
    var size: usize = 0;
    const text: [*c]u8 = raven.Rfile_read(path, &size);
    if (text == null) {
        set_status("Cannot read %s", path);
        return;
    }
    raven.Rtext_editor_set_text(app.editor, text);
    raven.Rmemory_free(text);
    _ = example.snprintf(&app.path, app.path.len, "%s", path);
    app.modified = raven.R_FALSE;
    // "main.rs" is Rust, "notes.txt" is nothing in particular
    set_language(raven.Rlanguage_for_file(path));
    update_title();
    scan_notes(raven.R_INVALID_ID, null);
    set_status("Opened %s", path);
    raven.Rwidget_focus(app.editor);
}

fn save(ask: c_int) c_int {
    var text: [*c]const u8 = undefined;
    if (ask != 0 or app.path[0] == 0) {
        var desc: raven.RFileDialogDesc = undefined;
        var chosen: [*c]const u8 = undefined;
        @memset(std.mem.asBytes(&desc), 0);
        desc.parent = app.window;
        desc.title = "Save the text";
        desc.file_name = if (app.path[0] != 0) file_name(&app.path) else "untitled.txt";
        desc.filters = &g_filters;
        desc.filter_count = 2;
        desc.default_extension = "txt";
        chosen = raven.Rfile_dialog_save(&desc);
        if (chosen == null) return raven.R_FALSE;
        _ = example.snprintf(&app.path, app.path.len, "%s", chosen);
        set_language(raven.Rlanguage_for_file(&app.path));
    }
    text = raven.Rtext_editor_get_text(app.editor);
    if (raven.Rfile_write(&app.path, text, @intCast(raven.Rtext_editor_get_length(app.editor))) == 0) {
        set_status("Cannot write %s", &app.path);
        return raven.R_FALSE;
    }
    app.modified = raven.R_FALSE;
    update_title();
    set_status("Saved %s", &app.path);
    return raven.R_TRUE;
}

fn action_file(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (example.strcmp(action, "file.new") == 0) {
        if (can_discard() == 0) return;
        raven.Rtext_editor_set_text(app.editor, "");
        app.path[0] = 0;
        app.modified = raven.R_FALSE;
        set_language(null);
        update_title();
        scan_notes(raven.R_INVALID_ID, null);
        set_status("%s", "New text.");
    } else if (example.strcmp(action, "file.open") == 0) {
        var desc: raven.RFileDialogDesc = undefined;
        var chosen: [*c]const u8 = undefined;
        if (can_discard() == 0) return;
        @memset(std.mem.asBytes(&desc), 0);
        desc.parent = app.window;
        desc.title = "Open a text";
        desc.filters = &g_filters;
        desc.filter_count = 2;
        chosen = raven.Rfile_dialog_open(&desc);
        if (chosen != null) open_path(chosen);
    } else if (example.strcmp(action, "file.save") == 0) {
        _ = save(raven.R_FALSE);
    } else if (example.strcmp(action, "file.save_as") == 0) {
        _ = save(raven.R_TRUE);
    } else if (example.strcmp(action, "file.quit") == 0) {
        if (can_discard() != 0) raven.Rquit(0);
    }
}

// The close button of the header bar, Alt+F4: the same question.
fn on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    if (can_discard() == 0) return raven.R_FALSE;
    raven.Rquit(0);
    return raven.R_TRUE;
}

//
// Something is dragged over the window from another application. Returning
// R_TRUE while it moves says "I take it" (the window is then highlighted);
// the files are known when it is dropped.
//
fn on_drop(target: raven.Rid, event: [*c]const raven.RDropEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = target;
    _ = user_data;
    if (event.*.phase != raven.R_DROP_DROPPED) return raven.R_TRUE;
    if (event.*.path_count > 0) {
        if (can_discard() != 0) open_path(event.*.paths[0]);
    } else if (event.*.text != null) {
        raven.Rtext_editor_insert_text(app.editor, event.*.text);
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Edit, view
// -------------------------------------------------------------------------

fn action_edit(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    raven.Rwidget_focus(app.editor);
    if (example.strcmp(action, "edit.undo") == 0) raven.Rtext_editor_undo(app.editor)
    else if (example.strcmp(action, "edit.redo") == 0) raven.Rtext_editor_redo(app.editor)
    else if (example.strcmp(action, "edit.select_all") == 0) raven.Rtext_editor_select_all(app.editor)
    else if (example.strcmp(action, "edit.complete") == 0) raven.Rtext_editor_show_completions(app.editor);
}

fn action_view(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (example.strcmp(action, "view.numbers") == 0) raven.Rtext_editor_set_line_numbers(app.editor, raven.Rmenu_item_is_checked(sender))
    else if (example.strcmp(action, "view.wrap") == 0) raven.Rtext_editor_set_word_wrap(app.editor, raven.Rmenu_item_is_checked(sender))
    else if (example.strcmp(action, "view.dark") == 0) raven.Rtheme_apply(raven.R_THEME_DARK)
    else if (example.strcmp(action, "view.light") == 0) raven.Rtheme_apply(raven.R_THEME_LIGHT)
    else if (example.strcmp(action, "view.glass_dark") == 0) raven.Rtheme_apply(raven.R_THEME_GLASS_DARK)
    else if (example.strcmp(action, "view.glass_light") == 0) raven.Rtheme_apply(raven.R_THEME_GLASS_LIGHT);
}

// ---------------------------------------------------------------------------
//  Start
// -------------------------------------------------------------------------

const WELCOME: [:0]const u8 =
    "/* Raven Notepad: this text is C, so the editor colors it. */\n" ++
    "#include <stdio.h>\n" ++
    "\n" ++
    "/* TODO: type \"pri\" on an empty line and choose a proposal with Enter */\n" ++
    "static int square(int value) {\n" ++
    "\treturn value * value;\n" ++
    "}\n" ++
    "\n" ++
    "int main(void) {\n" ++
    "\tfor (int i = 0; i < 4; i++) {\n" ++
    "\t\tprintf(\"%d squared is %d\\n\", i, square(i));\n" ++
    "\t}\n" ++
    "\treturn 0; /* FIXME: put the cursor after a brace to see the one it closes */\n" ++
    "}\n";

export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    const file_actions = [_][*c]const u8{ "file.new", "file.open", "file.save", "file.save_as", "file.quit" };
    const edit_actions = [_][*c]const u8{ "edit.undo", "edit.redo", "edit.select_all", "edit.complete" };
    const view_actions = [_][*c]const u8{ "view.numbers", "view.wrap", "view.dark", "view.light", "view.glass_dark", "view.glass_light" };
    var i: usize = undefined;

    if (example.example_init("notepad") == 0) return 1;
    register_ini();

    i = 0;
    while (i < file_actions.len) : (i += 1) raven.Raction_bind(file_actions[i], action_file, null);
    i = 0;
    while (i < edit_actions.len) : (i += 1) raven.Raction_bind(edit_actions[i], action_edit, null);
    i = 0;
    while (i < view_actions.len) : (i += 1) raven.Raction_bind(view_actions[i], action_view, null);
    raven.Raction_bind("view.language", action_language, null);

    app.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/notepad.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    app.editor = raven.Rwidget_find(app.window, "editor");
    app.header = raven.Rwidget_find(app.window, "header");
    app.language = raven.Rwidget_find(app.window, "language");
    app.status = raven.Rwidget_find(app.window, "status");
    app.notes = raven.Rwidget_find(app.window, "notes");
    app.position = raven.Rwidget_find(app.window, "position");
    app.scan_timer = raven.R_INVALID_ID;
    app.last_line = -1;

    fill_languages();
    raven.Rtext_editor_set_changed_callback(app.editor, on_changed, null);
    raven.Rtext_editor_set_completion_callback(app.editor, on_complete, null);
    raven.Rwindow_set_close_callback(app.window, on_close, null);
    raven.Rwindow_set_drop_callback(app.window, on_drop, null);
    raven.Rset_frame_callback(on_frame, null);

    if (argc > 1 and argv[1][0] != '-') {
        open_path(argv[1]);
    } else {
        raven.Rtext_editor_set_text(app.editor, WELCOME);
        set_language("C");
        scan_notes(raven.R_INVALID_ID, null);
        set_status("%s", "Drop a file on the window to open it.");
    }
    update_title();
    raven.Rwidget_focus(app.editor);

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    return 0;
}
