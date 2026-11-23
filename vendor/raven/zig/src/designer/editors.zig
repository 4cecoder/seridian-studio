// Translated to Zig from vendor/raven/tools/designer/editors.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - editors.c
// Code editors in tabs: any text file of the project, the interfaces
// (.xml, .xmlc...) included, whose preview is the island (island.c) until
// the visual editor is asked for; and the <script> blocks of an .xmlc. Completion of the Raven API, of the
// widgets of the interface (ui.name), of tags, attributes and @keys.

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

extern "c" fn atof(nptr: [*c]const u8) f64;

// #ifndef RAVEN_IDE_INCLUDE_DIR / #define RAVEN_IDE_INCLUDE_DIR "" / #endif  (given by the build: designer_config)
const RAVEN_IDE_INCLUDE_DIR = @import("designer_config").ide_include_dir;

const editor_t = extern struct {
    widget: raven.Rid,
    /// file shown, or NULL
    path: [*c]u8,
    /// what finds it again: the path, or "file.xmlc#script1"
    key: [*c]u8,
    title: [*c]u8,
    modified: c_int,
    /// counts the changes of its text (the island rebuilds its preview when it moves)
    revision: c_uint,
    save: ide.ide_save_callback,
    user: ?*anyopaque,
};

const g_e_t = extern struct {
    list: [*c]editor_t,
    count: c_int,
    loading: c_int,
    // the Raven API, read from its headers
    api: [*c][*c]u8,
    api_detail: [*c][*c]u8,
    api_count: c_int,
    api_loaded: c_int,
    // the code editor the keyboard was in last
    last: raven.Rid,
};
var g_e: g_e_t = std.mem.zeroes(g_e_t);

// ---------------------------------------------------------------------------
//  Editors
// -------------------------------------------------------------------------

fn by_widget(widget: raven.Rid) [*c]editor_t {
    var i: c_int = 0;
    while (i < g_e.count) : (i += 1) if (g_e.list[@intCast(i)].widget == widget) return &g_e.list[@intCast(i)];
    return null;
}

fn update_tab(e: [*c]editor_t) void {
    var title: [320]u8 = undefined;
    _ = libc.snprintf(&title, title.len, "%s%s", e.*.title, @as([*c]const u8, if (e.*.modified != 0) " *" else ""));
    raven.Rdock_area_set_panel_title(ide.g_ide_dock, e.*.widget, &title);
}

export fn editors_set_modified(widget: raven.Rid, modified: c_int) void {
    const e = by_widget(widget);
    if (e == null or e.*.modified == modified) return;
    e.*.modified = modified;
    update_tab(e);
}

fn on_changed(widget: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const e = by_widget(widget);
    _ = user_data;
    if (e != null) e.*.revision +%= 1;
    if (g_e.loading == 0) editors_set_modified(widget, raven.R_TRUE);
}

fn save_editor(e: [*c]editor_t) c_int {
    if (e.*.save) |save| return save(e.*.widget, e.*.user);
    if (e.*.path != null) {
        const text = raven.Rtext_editor_get_text(e.*.widget);
        if (raven.Rfile_write(e.*.path, text, libc.strlen(text)) == 0) {
            ide.ide_status("Cannot write %s", e.*.path);
            return raven.R_FALSE;
        }
        editors_set_modified(e.*.widget, raven.R_FALSE);
        ide.ide_status("Saved %s", e.*.path);
        // a table of translations, a CMakeLists.txt: what depends on it follows
        if (ide.ide_iequal(ide.ide_extension(e.*.path), "csv") != 0) ide.strings_reload();
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn remove_editor(e: [*c]editor_t) void {
    const index: c_int = @intCast(e - g_e.list);
    libc.free(e.*.path);
    libc.free(e.*.key);
    libc.free(e.*.title);
    _ = libc.memmove(&g_e.list[@intCast(index)], &g_e.list[@intCast(index + 1)], @sizeOf(editor_t) * @as(usize, @intCast(g_e.count - index - 1)));
    g_e.count -= 1;
}

fn on_close(area: raven.Rid, panel: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    const e = by_widget(panel);
    _ = area;
    _ = user_data;
    if (e == null) return raven.R_TRUE;
    if (e.*.modified != 0) {
        var text: [400]u8 = undefined;
        var answer: raven.RMessageResult = undefined;
        _ = libc.snprintf(&text, text.len, "%s has changes that were not saved. Save them?", e.*.title);
        answer = raven.Rmessage_box(ide.g_ide_window, "Unsaved changes", &text, raven.R_MESSAGE_YES_NO_CANCEL);
        if (answer == raven.R_MESSAGE_RESULT_CANCEL) return raven.R_FALSE;
        if (answer == raven.R_MESSAGE_RESULT_YES and save_editor(e) == 0) return raven.R_FALSE;
    }
    remove_editor(e);
    return raven.R_TRUE;
}

// Where the code editors go: in the tabs of the one shown last, else in those
// of the preview, else (the preview is hidden: no interface in the visual
// editor) above the Output.
export fn editors_anchor() raven.Rid {
    var i: c_int = undefined;
    editors_forget_closed();
    if (g_e.last != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_e.last) != 0 and by_widget(g_e.last) != null and raven.Rdock_area_is_panel_open(ide.g_ide_dock, g_e.last) != 0) return g_e.last;
    i = g_e.count - 1;
    while (i >= 0) : (i -= 1) {
        if (raven.Rdock_area_is_panel_open(ide.g_ide_dock, g_e.list[@intCast(i)].widget) != 0) return g_e.list[@intCast(i)].widget;
    }
    if (ide.g_ide_center != raven.R_INVALID_ID and raven.Rdock_area_is_panel_open(ide.g_ide_dock, ide.g_ide_center) != 0) return ide.g_ide_center;
    return raven.R_INVALID_ID;
}

fn dock_editor(widget: raven.Rid, title: [*c]const u8, anchor: raven.Rid) void {
    if (anchor != raven.R_INVALID_ID) raven.Rdock_area_add_panel(ide.g_ide_dock, widget, title, raven.R_DOCK_TAB, anchor, 0.0) else raven.Rdock_area_add_panel(ide.g_ide_dock, widget, title, raven.R_DOCK_TOP, raven.Rwidget_find(ide.g_ide_window, "output"), 0.7);
}

export fn editors_regroup() void {
    var anchor: raven.Rid = if (ide.g_ide_center != raven.R_INVALID_ID and raven.Rdock_area_is_panel_open(ide.g_ide_dock, ide.g_ide_center) != 0) ide.g_ide_center else raven.R_INVALID_ID;
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) {
        const widget = g_e.list[@intCast(i)].widget;
        if (raven.Rdock_area_is_panel_open(ide.g_ide_dock, widget) == 0) continue;
        if (anchor == raven.R_INVALID_ID) {
            raven.Rdock_area_move_panel(ide.g_ide_dock, widget, raven.R_DOCK_TOP, raven.Rwidget_find(ide.g_ide_window, "output"), 0.7);
            anchor = widget;
        } else {
            raven.Rdock_area_move_panel(ide.g_ide_dock, widget, raven.R_DOCK_TAB, anchor, 0.0);
        }
    }
    if (g_e.last != raven.R_INVALID_ID and by_widget(g_e.last) != null and raven.Rdock_area_is_panel_open(ide.g_ide_dock, g_e.last) != 0) raven.Rdock_area_show_panel(ide.g_ide_dock, g_e.last);
}

/// An interface (.xml, .xmlc...): XML, its scripts colored in their language, and the completion of tags and attributes.
fn is_interface(path: [*c]const u8) c_int {
    return @intFromBool(path != null and (ide.ide_interface_language(path) != null or ide.ide_iequal(ide.ide_extension(path), "xml") != 0));
}

fn create(title: [*c]const u8, key: [*c]const u8, path: [*c]const u8, text: [*c]const u8, language: [*c]const u8) [*c]editor_t {
    var e: [*c]editor_t = undefined;
    // (where it goes, before it is one of the editors)
    const anchor = editors_anchor();
    const widget = raven.Rtext_editor_create(null);
    g_e.loading += 1;
    raven.Rtext_editor_set_text(widget, if (text != null) text else "");
    g_e.loading -= 1;
    if (language != null and language[0] != 0) raven.Rtext_editor_set_language(widget, language);
    raven.Rtext_editor_set_line_numbers(widget, raven.R_TRUE);
    raven.Rtext_editor_set_tab_size(widget, 4);
    raven.Rtext_editor_set_changed_callback(widget, &on_changed, null);
    completion_attach(widget, @intFromBool((language != null and ide.ide_iequal(language, "XML") != 0) or is_interface(path) != 0));
    editors_zoom_attach(widget);
    g_e.list = @ptrCast(@alignCast(libc.realloc(g_e.list, @sizeOf(editor_t) * @as(usize, @intCast(g_e.count + 1)))));
    e = &g_e.list[@intCast(g_e.count)];
    g_e.count += 1;
    e.* = std.mem.zeroes(editor_t);
    e.*.widget = widget;
    e.*.path = if (path != null) ide.ide_strdup(path) else null;
    e.*.key = ide.ide_strdup(key);
    e.*.title = ide.ide_strdup(title);
    dock_editor(widget, title, anchor);
    raven.Rdock_area_show_panel(ide.g_ide_dock, widget);
    g_e.last = widget;
    return e;
}

// ---------------------------------------------------------------------------
//  Zoom: Ctrl + wheel (Ctrl + '+', '-', 0) in any editor zooms them all, and
//  the next start comes back to it (ide.ini, editor_zoom).
// -------------------------------------------------------------------------

const g_z_t = extern struct {
    zoom: f32,
    loaded: c_int,
    // the editors that are not code editors: the XML panel, the Output
    others: [8]raven.Rid,
    other_count: c_int,
};
var g_z: g_z_t = std.mem.zeroes(g_z_t);

fn zoom_now() f32 {
    if (g_z.loaded == 0) {
        const saved: f32 = @floatCast(atof(ide.prefs_get("editor_zoom")));
        g_z.zoom = if (saved >= 0.5 and saved <= 4.0) saved else 1.0;
        g_z.loaded = raven.R_TRUE;
    }
    return g_z.zoom;
}

/// Every editor of the IDE at one zoom (`from` already is: the user zoomed it).
fn zoom_all(zoom: f32, from: raven.Rid) void {
    var i: c_int = 0;
    var text: [16]u8 = undefined;
    g_z.zoom = zoom;
    g_z.loaded = raven.R_TRUE;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) if (g_e.list[@intCast(i)].widget != from) raven.Rtext_editor_set_zoom(g_e.list[@intCast(i)].widget, zoom);
    i = 0;
    while (i < g_z.other_count) : (i += 1) {
        if (g_z.others[@intCast(i)] != from and raven.Rwidget_is_valid(g_z.others[@intCast(i)]) != 0) raven.Rtext_editor_set_zoom(g_z.others[@intCast(i)], zoom);
    }
    _ = libc.snprintf(&text, text.len, "%.2f", @as(f64, zoom));
    ide.prefs_set("editor_zoom", &text);
}

fn on_zoom(editor: raven.Rid, zoom: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    zoom_all(zoom, editor);
    ide.ide_status("Text zoom: %d %%  (Ctrl + wheel, Ctrl + '+' / '-', Ctrl + 0: 100 %%)", @as(c_int, @intFromFloat(zoom * 100.0 + 0.5)));
}

export fn editors_zoom_attach(editor: raven.Rid) void {
    var i: c_int = undefined;
    const code: c_int = @intFromBool(by_widget(editor) != null);
    if (editor == raven.R_INVALID_ID or raven.Rwidget_is_valid(editor) == 0) return;
    raven.Rtext_editor_set_zoom(editor, zoom_now());
    raven.Rtext_editor_set_zoom_callback(editor, &on_zoom, null);
    if (code != 0) return;
    i = 0;
    while (i < g_z.other_count) : (i += 1) if (g_z.others[@intCast(i)] == editor) return;
    if (g_z.other_count < @as(c_int, @intCast(g_z.others.len))) {
        g_z.others[@intCast(g_z.other_count)] = editor;
        g_z.other_count += 1;
    }
}

export fn editors_reset_zoom() void {
    zoom_all(1.0, raven.R_INVALID_ID);
    ide.ide_status("Text zoom: 100 %%");
}

// A dock area closes a panel without asking when the program does it
// (Rdock_area_close_panel: the scripts of an .xmlc that is closed): the
// editors whose widget is gone are forgotten here, before anyone looks.
export fn editors_forget_closed() void {
    var i: c_int = g_e.count - 1;
    while (i >= 0) : (i -= 1) {
        if (raven.Rwidget_is_valid(g_e.list[@intCast(i)].widget) == 0) remove_editor(&g_e.list[@intCast(i)]);
    }
}

export fn editors_find(key: [*c]const u8) raven.Rid {
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) if (ide.ide_same_path(g_e.list[@intCast(i)].key, key) != 0) return g_e.list[@intCast(i)].widget;
    return raven.R_INVALID_ID;
}

/// A tab whose title contains a text (the scripts of the tests).
export fn editors_find_title(text: [*c]const u8) raven.Rid {
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) if (libc.strstr(g_e.list[@intCast(i)].title, text) != null) return g_e.list[@intCast(i)].widget;
    return raven.R_INVALID_ID;
}

export fn editors_close_all() void {
    editors_forget_closed();
    while (g_e.count > 0) {
        const widget = g_e.list[@intCast(g_e.count - 1)].widget;
        remove_editor(&g_e.list[@intCast(g_e.count - 1)]);
        if (raven.Rwidget_is_valid(widget) != 0) raven.Rdock_area_close_panel(ide.g_ide_dock, widget);
    }
}

fn go_to_line(widget: raven.Rid, line: c_int) void {
    if (line <= 0) return;
    raven.Rtext_editor_set_cursor(widget, line - 1, 0);
    raven.Rtext_editor_scroll_to_line(widget, line - 1);
    raven.Rwidget_focus(widget);
}

fn language_of(path: [*c]const u8) [*c]const u8 {
    const name = ide.ide_basename(path);
    const ext = ide.ide_extension(path);
    if (ide.ide_iequal(name, "CMakeLists.txt") != 0 or ide.ide_iequal(ext, "cmake") != 0) return "CMake";
    // (an .xmlc, .xmlrs...: its scripts colored in their language, as in the XML panel)
    if (ide.ide_interface_language(path) != null) return if (raven.Rlanguage_for_file(path) != null) raven.Rlanguage_for_file(path) else "XML";
    return raven.Rlanguage_for_file(path);
}

export fn editors_open(path: [*c]const u8, line: c_int) raven.Rid {
    const found = editors_find(path);
    var size: usize = 0;
    var text: [*c]u8 = undefined;
    var e: [*c]editor_t = undefined;
    if (found != raven.R_INVALID_ID) {
        raven.Rdock_area_open_panel(ide.g_ide_dock, found);
        go_to_line(found, line);
        return found;
    }
    text = raven.Rfile_read(path, &size);
    if (text == null) {
        ide.ide_status("Cannot read %s", path);
        return raven.R_INVALID_ID;
    }
    e = create(ide.ide_basename(path), path, path, text, language_of(path));
    raven.Rmemory_free(text);
    go_to_line(e.*.widget, line);
    return e.*.widget;
}

export fn editors_open_text(path: [*c]const u8, text: [*c]const u8, modified: c_int) raven.Rid {
    var found = editors_find(path);
    var e: [*c]editor_t = undefined;
    if (found == raven.R_INVALID_ID) {
        e = create(ide.ide_basename(path), path, path, text, language_of(path));
        found = e.*.widget;
    } else {
        g_e.loading += 1;
        raven.Rtext_editor_set_text(found, text);
        g_e.loading -= 1;
        raven.Rdock_area_open_panel(ide.g_ide_dock, found);
    }
    editors_set_modified(found, modified);
    return found;
}

export fn editors_is_modified(widget: raven.Rid) c_int {
    const e = by_widget(widget);
    return @intFromBool(e != null and e.*.modified != 0);
}

export fn editors_close_file(path: [*c]const u8) void {
    const widget = editors_find(path);
    const e: [*c]editor_t = if (widget != raven.R_INVALID_ID) by_widget(widget) else null;
    if (e == null) return;
    remove_editor(e);
    if (g_e.last == widget) g_e.last = raven.R_INVALID_ID;
    if (raven.Rwidget_is_valid(widget) != 0) raven.Rdock_area_close_panel(ide.g_ide_dock, widget);
}

export fn editors_open_virtual(title: [*c]const u8, key: [*c]const u8, text: [*c]const u8, language: [*c]const u8, save: ide.ide_save_callback, user_data: ?*anyopaque) raven.Rid {
    const found = editors_find(key);
    var e: [*c]editor_t = undefined;
    if (found != raven.R_INVALID_ID) {
        // opened again: what the file says now
        g_e.loading += 1;
        raven.Rtext_editor_set_text(found, text);
        g_e.loading -= 1;
        editors_set_modified(found, raven.R_FALSE);
        e = by_widget(found);
        if (e != null) {
            e.*.save = save;
            e.*.user = user_data;
        }
        return found;
    }
    e = create(title, key, null, text, language);
    e.*.save = save;
    e.*.user = user_data;
    return e.*.widget;
}

export fn editors_save_all() c_int {
    var i: c_int = 0;
    var ok: c_int = raven.R_TRUE;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) {
        if (g_e.list[@intCast(i)].modified != 0 and save_editor(&g_e.list[@intCast(i)]) == 0) ok = raven.R_FALSE;
    }
    return ok;
}

export fn editors_any_modified() c_int {
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) if (g_e.list[@intCast(i)].modified != 0) return raven.R_TRUE;
    return raven.R_FALSE;
}

/// The editor the keyboard is in, else the one it was in last if its tab is in front, else one in front, for File > Save.
fn focused_editor() [*c]editor_t {
    const focus = raven.Rwindow_get_focused_widget(ide.g_ide_window);
    var last: [*c]editor_t = undefined;
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) {
        var walk: raven.Rid = focus;
        while (walk != raven.R_INVALID_ID) : (walk = raven.Rwidget_get_parent(walk)) {
            if (walk == g_e.list[@intCast(i)].widget) {
                g_e.last = walk;
                return &g_e.list[@intCast(i)];
            }
        }
    }
    last = if (g_e.last != raven.R_INVALID_ID) by_widget(g_e.last) else null;
    if (last != null and raven.Rdock_area_is_panel_shown(ide.g_ide_dock, last.*.widget) != 0) return last;
    i = 0;
    while (i < g_e.count) : (i += 1) if (raven.Rdock_area_is_panel_shown(ide.g_ide_dock, g_e.list[@intCast(i)].widget) != 0) return &g_e.list[@intCast(i)];
    return null;
}

export fn editors_current_path() [*c]const u8 {
    const e = focused_editor();
    return if (e != null) e.*.path else null;
}

export fn editors_current_interface(path: [*c][*c]const u8, text: [*c][*c]const u8, revision: [*c]c_uint) c_int {
    const e = focused_editor();
    if (e == null or e.*.path == null or is_interface(e.*.path) == 0) return raven.R_FALSE;
    if (path != null) path.* = e.*.path;
    if (text != null) text.* = raven.Rtext_editor_get_text(e.*.widget);
    if (revision != null) revision.* = e.*.revision;
    return raven.R_TRUE;
}

// int editors_save_focused(void);
export fn editors_save_focused() c_int {
    const e = focused_editor();
    if (e == null) return -1;
    return save_editor(e);
}

export fn editors_clear_markers() void {
    var i: c_int = 0;
    editors_forget_closed();
    while (i < g_e.count) : (i += 1) raven.Rtext_editor_clear_markers(g_e.list[@intCast(i)].widget);
}

export fn editors_add_marker(path: [*c]const u8, line: c_int, column: c_int, @"error": c_int, message: [*c]const u8) void {
    const widget = editors_find(path);
    if (widget == raven.R_INVALID_ID and ide.xmlc_is_open() != 0 and ide.ide_same_path(path, ide.xmlc_path()) != 0) {
        // an .xmlc is whole in the XML panel
        ide.designer_add_marker(line, column, @"error", message);
        return;
    }
    if (widget == raven.R_INVALID_ID or line <= 0) return;
    raven.Rtext_editor_add_marker(widget, line - 1, if (column > 0) column - 1 else 0, -1, @as(raven.RMarkerKind, if (@"error" != 0) raven.R_MARKER_ERROR else raven.R_MARKER_WARNING), message);
}

export fn editors_init() void {
    const S = struct {
        var cmake: raven.RLanguageDesc = std.mem.zeroes(raven.RLanguageDesc);
    };
    g_e.last = raven.R_INVALID_ID;
    S.cmake = std.mem.zeroes(raven.RLanguageDesc);
    S.cmake.name = "CMake";
    S.cmake.extensions = "cmake";
    S.cmake.keywords = "if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return break continue";
    S.cmake.types = "cmake_minimum_required project add_executable add_library target_link_libraries target_sources target_include_directories " ++
        "target_compile_definitions target_compile_options set unset option find_package include add_subdirectory install message list string " ++
        "file get_filename_component set_target_properties configure_file add_custom_command add_custom_target add_test enable_testing " ++
        "raven_target_xmlc";
    S.cmake.constants = "ON OFF TRUE FALSE PRIVATE PUBLIC INTERFACE REQUIRED";
    S.cmake.line_comment = "#";
    S.cmake.string_quotes = "\"";
    _ = raven.Rlanguage_register(&S.cmake);
    // the languages of the scripts that Raven does not color by itself
    {
        const T = struct {
            var go: raven.RLanguageDesc = std.mem.zeroes(raven.RLanguageDesc);
            var zig: raven.RLanguageDesc = std.mem.zeroes(raven.RLanguageDesc);
            var lua: raven.RLanguageDesc = std.mem.zeroes(raven.RLanguageDesc);
        };
        T.go = std.mem.zeroes(raven.RLanguageDesc);
        T.go.name = "Go";
        T.go.extensions = "go";
        T.go.keywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var";
        T.go.types = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any " ++
            "append cap close copy delete len make new panic print println recover";
        T.go.constants = "true false nil iota";
        T.go.line_comment = "//";
        T.go.block_comment_start = "/*";
        T.go.block_comment_end = "*/";
        T.go.string_quotes = "\"'";
        T.go.multiline_strings = "`";
        _ = raven.Rlanguage_register(&T.go);
        T.zig = std.mem.zeroes(raven.RLanguageDesc);
        T.zig.name = "Zig";
        T.zig.extensions = "zig";
        T.zig.keywords = "const var fn pub return if else while for switch break continue defer errdefer try catch orelse struct enum union error test comptime inline export extern callconv usingnamespace and or unreachable";
        T.zig.types = "bool void u8 u16 u32 u64 usize i8 i16 i32 i64 isize f32 f64 c_int c_uint anyopaque anytype type noreturn";
        T.zig.constants = "true false null undefined";
        T.zig.line_comment = "//";
        T.zig.string_quotes = "\"'";
        T.zig.annotation = "@";
        _ = raven.Rlanguage_register(&T.zig);
        T.lua = std.mem.zeroes(raven.RLanguageDesc);
        T.lua.name = "Lua";
        T.lua.extensions = "lua";
        T.lua.keywords = "and break do else elseif end for function goto if in local not or repeat return then until while";
        T.lua.types = "print pairs ipairs require setmetatable getmetatable tostring tonumber type select error assert pcall string table math os io";
        T.lua.constants = "true false nil";
        T.lua.line_comment = "--";
        T.lua.block_comment_start = "--[[";
        T.lua.block_comment_end = "]]";
        T.lua.string_quotes = "\"'";
        _ = raven.Rlanguage_register(&T.lua);
    }
    raven.Rdock_area_set_close_callback(ide.g_ide_dock, &on_close, null);
}

export fn editors_shutdown() void {
    var i: c_int = 0;
    while (i < g_e.count) : (i += 1) {
        libc.free(g_e.list[@intCast(i)].path);
        libc.free(g_e.list[@intCast(i)].key);
        libc.free(g_e.list[@intCast(i)].title);
    }
    libc.free(g_e.list);
    i = 0;
    while (i < g_e.api_count) : (i += 1) {
        libc.free(g_e.api[@intCast(i)]);
        libc.free(g_e.api_detail[@intCast(i)]);
    }
    libc.free(@ptrCast(g_e.api));
    libc.free(@ptrCast(g_e.api_detail));
    g_e = std.mem.zeroes(g_e_t);
    g_e.last = raven.R_INVALID_ID;
}

// ---------------------------------------------------------------------------
//  Completion
// -------------------------------------------------------------------------

fn api_add(name: [*c]const u8, length: usize, detail: [*c]const u8) void {
    var i: c_int = 0;
    const word: [*c]u8 = @ptrCast(libc.malloc(length + 1));
    _ = libc.memcpy(word, name, length);
    word[length] = 0;
    while (i < g_e.api_count) : (i += 1) {
        if (libc.strcmp(g_e.api[@intCast(i)], word) == 0) {
            libc.free(word);
            return;
        }
    }
    g_e.api = @ptrCast(@alignCast(libc.realloc(@ptrCast(g_e.api), @sizeOf([*c]u8) * @as(usize, @intCast(g_e.api_count + 1)))));
    g_e.api_detail = @ptrCast(@alignCast(libc.realloc(@ptrCast(g_e.api_detail), @sizeOf([*c]u8) * @as(usize, @intCast(g_e.api_count + 1)))));
    g_e.api[@intCast(g_e.api_count)] = word;
    g_e.api_detail[@intCast(g_e.api_count)] = ide.ide_strdup(detail);
    g_e.api_count += 1;
}

fn is_word(c: u8) c_int {
    return @intFromBool(std.ascii.isAlphanumeric(c) or c == '_');
}

/// The functions (RAVEN_API ... Rname(), the constants (R_NAME) and the types (Rname) of a header.
fn read_header(path: [*c]const u8) void {
    var size: usize = 0;
    const text = raven.Rfile_read(path, &size);
    var line: [*c]u8 = undefined;
    if (text == null) return;
    line = text;
    while (line != null and line.* != 0) {
        const end = libc.strchr(line, '\n');
        var api: [*c]u8 = undefined;
        if (end != null) end.* = 0;
        api = libc.strstr(line, "RAVEN_API ");
        if (api != null) {
            const paren = libc.strchr(api, '(');
            if (paren != null) {
                var name_end: [*c]u8 = paren;
                var name: [*c]u8 = undefined;
                var detail: [160]u8 = undefined;
                while (name_end > api and std.ascii.isWhitespace((name_end - 1).*)) name_end -= 1;
                name = name_end;
                while (name > api and is_word((name - 1).*) != 0) name -= 1;
                // the return type, as a hint
                const diff: isize = @as(isize, @bitCast(name - api)) - 10;
                _ = libc.snprintf(&detail, detail.len, "%.*s", @as(c_int, @intCast(if (diff > 0) diff else 0)), api + 10);
                if (name < name_end) api_add(name, name_end - name, &detail);
            }
        } else {
            var p: [*c]u8 = line;
            while (p.* == ' ' or p.* == '\t') p += 1;
            // an enumerator: R_SOMETHING = ..., or R_SOMETHING,
            if (p[0] == 'R' and p[1] == '_') {
                var q: [*c]u8 = p;
                while (is_word(q.*) != 0) q += 1;
                if (q.* == ',' or q.* == ' ' or q.* == '=' or q.* == 0) api_add(p, q - p, "constant");
            } else if (libc.strncmp(p, "} R", 3) == 0 or libc.strncmp(p, "}R", 2) == 0) {
                const q = libc.strchr(p, 'R');
                var e: [*c]u8 = q;
                while (is_word(e.*) != 0) e += 1;
                api_add(q, e - q, "type");
            }
        }
        line = if (end != null) end + 1 else null;
    }
    raven.Rmemory_free(text);
}

export fn completion_load_raven_api() void {
    var candidates: [3][*c]const u8 = undefined;
    var tried: [3][*c]u8 = undefined;
    var i: c_int = undefined;
    var n: c_int = 0;
    if (g_e.api_loaded != 0) return;
    g_e.api_loaded = raven.R_TRUE;
    // next to the program (a package: bin/ and include/), or the sources it was built from
    tried[0] = ide.ide_join(ide.ide_exe_dir(), "../include/raven");
    tried[1] = ide.ide_join(ide.ide_exe_dir(), "../../include/raven");
    tried[2] = ide.ide_join(if (RAVEN_IDE_INCLUDE_DIR[0] != 0) RAVEN_IDE_INCLUDE_DIR else ".", "raven");
    candidates[0] = tried[0];
    candidates[1] = tried[1];
    candidates[2] = tried[2];
    i = 0;
    while (i < 3 and n == 0) : (i += 1) {
        var entries: [*c]ide.ide_entry_t = undefined;
        const count = ide.ide_list_dir(candidates[@intCast(i)], &entries);
        var j: c_int = 0;
        while (j < count) : (j += 1) {
            if (entries[@intCast(j)].is_dir == 0 and ide.ide_iequal(ide.ide_extension(&entries[@intCast(j)].name), "h") != 0) {
                const full = ide.ide_join(candidates[@intCast(i)], &entries[@intCast(j)].name);
                read_header(full);
                libc.free(full);
                n += 1;
            }
        }
        libc.free(entries);
    }
    i = 0;
    while (i < 3) : (i += 1) libc.free(tried[@intCast(i)]);
    // the macros of the headers are useful too
    api_add("Rid", 3, "type");
    api_add("R_INVALID_ID", 12, "constant");
    api_add("R_TRUE", 6, "constant");
    api_add("R_FALSE", 7, "constant");
}

/// The text of the line before the cursor.
fn before_cursor(editor: raven.Rid, out: [*c]u8, size: usize) c_int {
    var line: c_int = undefined;
    var column: c_int = undefined;
    var text: [*c]const u8 = undefined;
    raven.Rtext_editor_get_cursor(editor, &line, &column);
    text = raven.Rtext_editor_get_line(editor, line);
    if (text == null) return 0;
    if (@as(usize, @bitCast(@as(isize, column))) >= size) column = @as(c_int, @intCast(size)) - 1;
    if (@as(c_int, @intCast(libc.strlen(text))) < column) column = @intCast(libc.strlen(text));
    _ = libc.memcpy(out, text, @intCast(column));
    out[@intCast(column)] = 0;
    return 1;
}

fn complete_keys(editor: raven.Rid) void {
    var i: c_int = 0;
    const count = ide.strings_key_count();
    while (i < count) : (i += 1) raven.Rtext_editor_add_completion(editor, ide.strings_key(i), "translation");
}

fn complete_c(editor: raven.Rid, prefix: [*c]const u8, before: [*c]const u8) void {
    const lp = libc.strlen(prefix);
    const lb = libc.strlen(before);
    const word_start: [*c]const u8 = before + lb - lp;
    var i: c_int = undefined;
    // ui.<name>: the widgets of the interface
    if (@as(isize, @bitCast(word_start - before)) >= 3 and libc.strncmp(word_start - 3, "ui.", 3) == 0) {
        var names: [256][*c]const u8 = undefined;
        const count = ide.designer_get_names(&names, 256);
        i = 0;
        while (i < count) : (i += 1) raven.Rtext_editor_add_completion(editor, names[@intCast(i)], "Rid");
        return;
    }
    // Rtr("key"), Rtr_plural("key", ...
    if (word_start > before and (word_start - 1).* == '"' and libc.strstr(before, "Rtr") != null) {
        complete_keys(editor);
        return;
    }
    completion_load_raven_api();
    i = 0;
    while (i < g_e.api_count) : (i += 1) raven.Rtext_editor_add_completion(editor, g_e.api[@intCast(i)], g_e.api_detail[@intCast(i)]);
    if (ide.xmlc_is_open() != 0) raven.Rtext_editor_add_completion(editor, "ui", "the widgets that have a Name");
}

fn complete_xml(editor: raven.Rid, prefix: [*c]const u8, before: [*c]const u8) void {
    const lp = libc.strlen(prefix);
    const lb = libc.strlen(before);
    const word_start: [*c]const u8 = before + lb - lp;
    const open: [*c]const u8 = libc.strrchr(before, '<');
    const close: [*c]const u8 = libc.strrchr(before, '>');
    var i: c_int = undefined;
    var quotes: c_int = 0;
    var p: [*c]const u8 = undefined;
    // a value that starts with @: a key of the tables
    if (word_start > before and (word_start - 1).* == '@') {
        complete_keys(editor);
        return;
    }
    if (open == null or (close != null and close > open)) return;
    // the name of an element
    if (word_start == open + 1 or (word_start == open + 2 and open[1] == '/')) {
        i = 0;
        while (i < raven.Rxml_get_tag_count()) : (i += 1) raven.Rtext_editor_add_completion(editor, raven.Rxml_get_tag_name(i), "widget");
        i = 0;
        while (i < raven.Rxml_get_registered_widget_count()) : (i += 1) raven.Rtext_editor_add_completion(editor, raven.Rxml_get_registered_widget_name(i), "declared");
        raven.Rtext_editor_add_completion(editor, "Item", "row");
        raven.Rtext_editor_add_completion(editor, "Shortcut", "keys");
        raven.Rtext_editor_add_completion(editor, "Strings", "translations");
        raven.Rtext_editor_add_completion(editor, "script", "code of the language of the file");
        return;
    }
    // inside a value: nothing to propose
    p = open;
    while (p < word_start) : (p += 1) {
        if (p.* == '"') quotes += 1;
    }
    if (@rem(quotes, 2) != 0) return;
    // an attribute of that element; "Slot.Fi" proposes "Fill" after the dot
    {
        var tag: [96]u8 = undefined;
        var group: [64]u8 = std.mem.zeroes([64]u8);
        var t: [*c]const u8 = open + 1;
        var g: [*c]const u8 = undefined;
        var n: usize = 0;
        while (t.* != 0 and is_word(t.*) != 0 and n + 1 < tag.len) {
            tag[n] = t.*;
            n += 1;
            t += 1;
        }
        tag[n] = 0;
        g = word_start;
        while (g > open and (is_word((g - 1).*) != 0 or (g - 1).* == '.')) : (g -= 1) {}
        if (g < word_start and (word_start - 1).* == '.') _ = libc.snprintf(&group, group.len, "%.*s", @as(c_int, @intCast(word_start - g)), g);
        i = 0;
        while (i < raven.Rxml_get_attribute_count(&tag)) : (i += 1) {
            var info: raven.RXmlAttributeInfo = undefined;
            if (raven.Rxml_get_attribute_info(&tag, i, &info) == 0) continue;
            if (group[0] != 0) {
                if (libc.strncmp(info.name, &group, libc.strlen(&group)) == 0) raven.Rtext_editor_add_completion(editor, info.name + libc.strlen(&group), info.group);
            } else {
                raven.Rtext_editor_add_completion(editor, info.name, info.group);
            }
        }
    }
}

/// In the XML panel of an .xmlc: the cursor is between <script> and </script>.
fn in_script(editor: raven.Rid) c_int {
    const text = raven.Rtext_editor_get_text(editor);
    var at: [*c]const u8 = text;
    var open: [*c]const u8 = null;
    var p: [*c]const u8 = undefined;
    var line: c_int = undefined;
    var column: c_int = undefined;
    var l: c_int = 0;
    raven.Rtext_editor_get_cursor(editor, &line, &column);
    while (at.* != 0 and l < line) {
        const ch = at.*;
        at += 1;
        if (ch == '\n') l += 1;
    }
    p = at;
    while (p.* != 0 and p.* != '\n' and @as(isize, @bitCast(p - at)) < column) : (p += 1) {}
    // the last <script before the cursor, and no </script after it
    at = text;
    while (at < p) : (at += 1) {
        if (at.* != '<') continue;
        if (libc.strncmp(at, "<script", 7) == 0 and (at[7] == '>' or at[7] == ' ' or at[7] == '\t' or at[7] == '\n' or at[7] == '\r')) open = at else if (libc.strncmp(at, "</script", 8) == 0) open = null;
    }
    if (open == null) return 0;
    // (past the end of the opening tag)
    at = libc.strchr(open, '>');
    return @intFromBool(at != null and at < p);
}

fn on_complete(editor: raven.Rid, prefix: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var before: [1024]u8 = undefined;
    if (before_cursor(editor, &before, before.len) == 0) return;
    // an .xmlc is whole in the XML panel: in its scripts, the code of the language
    if (user_data != null and ide.xmlc_is_open() != 0 and in_script(editor) != 0) {
        // the words of the language of the scripts too (the panel itself is in XMLC, XMLRS...)
        const language = ide.ide_interface_language(ide.xmlc_path());
        var desc: raven.RLanguageDesc = undefined;
        if (language != null and raven.Rlanguage_get(language.*.editor, &desc) != 0) {
            var lists: [2][*c]const u8 = undefined;
            var k: c_int = 0;
            lists[0] = desc.keywords;
            lists[1] = desc.types;
            while (k < 2) : (k += 1) {
                var w: [*c]const u8 = lists[@intCast(k)];
                while (w != null and w.* != 0) {
                    var word: [64]u8 = undefined;
                    var n: usize = 0;
                    while (w.* == ' ') w += 1;
                    while (w.* != 0 and w.* != ' ' and n + 1 < word.len) {
                        word[n] = w.*;
                        n += 1;
                        w += 1;
                    }
                    while (w.* != 0 and w.* != ' ') w += 1;
                    word[n] = 0;
                    if (n != 0 and libc.strncmp(&word, prefix, libc.strlen(prefix)) == 0) raven.Rtext_editor_add_completion(editor, &word, if (k != 0) "type" else "keyword");
                }
            }
        }
        complete_c(editor, prefix, &before);
    } else if (user_data != null) complete_xml(editor, prefix, &before) else complete_c(editor, prefix, &before);
}

export fn completion_attach(editor: raven.Rid, xml: c_int) void {
    raven.Rtext_editor_set_completion_callback(editor, &on_complete, if (xml != 0) @as(?*anyopaque, @ptrFromInt(1)) else null);
}
