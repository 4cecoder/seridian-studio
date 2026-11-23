// Translated to Zig from vendor/raven/src/widgets/file_browser.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/file_browser.c
// FileBrowser: an explorer of the files of the computer. It is what the
// file dialogs show where the OS has no dialog of its own, and a widget that
// applications put in their own layouts.
//
// The browser draws the list of files and the navigation buttons itself;
// the fields around the list (path, places, name, filter, buttons) are
// ordinary widgets that it owns as children and arranges by hand.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const fs_h = @import("../core/fs_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

// enum { RVN_FB_BACK, RVN_FB_FORWARD, RVN_FB_UP, RVN_FB_NAV_COUNT };
const RVN_FB_BACK = 0;
const RVN_FB_FORWARD = 1;
const RVN_FB_UP = 2;
const RVN_FB_NAV_COUNT = 3;
// enum { RVN_FB_COLUMN_NAME, RVN_FB_COLUMN_SIZE, RVN_FB_COLUMN_DATE };
const RVN_FB_COLUMN_NAME = 0;
const RVN_FB_COLUMN_SIZE = 1;
const RVN_FB_COLUMN_DATE = 2;

const RVN_FB_GAP: f32 = 8.0;
const RVN_FB_PLACES_WIDTH: f32 = 150.0;
const RVN_FB_SIZE_WIDTH: f32 = 84.0;
const RVN_FB_DATE_WIDTH: f32 = 132.0;
const RVN_FB_HISTORY_MAX = 64;

const rvn_file_browser_t = extern struct {
    base: widget_h.rvn_widget_t,
    mode: raven.RFileBrowserMode,
    directory: [*c]u8,
    /// the entries shown: filtered and sorted
    entries: [*c]fs_h.rvn_dir_entry_t,
    entry_count: u32,
    selected: [*c]u8,
    /// Entry the keyboard is on, entry a range selection started from, entry under the pointer; -1 = none.
    cursor: c_int,
    anchor: c_int,
    hot: c_int,
    sort_column: c_int,
    sort_descending: c_int,
    show_hidden: c_int,
    multiple: c_int,
    controls_hidden: c_int,
    places_hidden: c_int,
    filter_names: [*c][*c]u8,
    filter_patterns: [*c][*c]u8,
    filter_count: c_int,
    filter_index: c_int,
    default_extension: [*c]u8,
    places: [*c]fs_h.rvn_place_t,
    place_count: u32,
    /// folders visited, for Back and Forward
    history: [RVN_FB_HISTORY_MAX][*c]u8,
    history_count: c_int,
    history_at: c_int,

    // children
    path_input: [*c]widget_h.rvn_widget_t,
    places_list: [*c]widget_h.rvn_widget_t,
    name_input: [*c]widget_h.rvn_widget_t,
    filter_combo: [*c]widget_h.rvn_widget_t,
    accept_button: [*c]widget_h.rvn_widget_t,
    cancel_button: [*c]widget_h.rvn_widget_t,
    /// R_TRUE while the browser itself changes its fields: their callbacks do nothing.
    updating: c_int,

    // geometry, computed by arrange
    nav: [RVN_FB_NAV_COUNT]base.rvn_rect_t,
    list: base.rvn_rect_t,
    header_height: f32,
    bar: common.rvn_scrollbar_t,
    select_y: raven.RSpring,
    nav_hot: c_int,
    nav_down: c_int,
    nav_hover: [RVN_FB_NAV_COUNT]raven.RSpring,
    nav_press: [RVN_FB_NAV_COUNT]raven.RSpring,

    // typing the first letters of a name moves to it
    typed: [32]u8,
    typed_time: f64,

    selection_paths: [*c][*c]u8,
    selection_count: u32,
    accepted: raven.RFileBrowserCallback,
    accepted_user: ?*anyopaque,
    cancelled: raven.RFileBrowserCallback,
    cancelled_user: ?*anyopaque,
    selection_changed: raven.RFileBrowserCallback,
    selection_user: ?*anyopaque,
};

fn rvn_fb_from_user(user_data: ?*anyopaque) [*c]widget_h.rvn_widget_t {
    const widget = ext.rvn_widget_get(@truncate(@intFromPtr(user_data)));
    if (widget != null and widget.*.cls.*.@"type" == raven.R_WIDGET_FILE_BROWSER) return widget;
    return null;
}

// ---------------------------------------------------------------------------
//  Entries
// ---------------------------------------------------------------------------

var g_fb_sort_column: c_int = 0;
var g_fb_sort_descending: c_int = 0;

fn rvn_fb_compare(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: *const fs_h.rvn_dir_entry_t = @ptrCast(@alignCast(a.?));
    const y: *const fs_h.rvn_dir_entry_t = @ptrCast(@alignCast(b.?));
    var result: c_int = 0;
    // folders first, whatever the order
    if (x.is_dir != y.is_dir) return if (x.is_dir != 0) -1 else 1;
    if (g_fb_sort_column == RVN_FB_COLUMN_SIZE and x.is_dir == 0) {
        result = if (x.size < y.size) -1 else if (x.size > y.size) 1 else 0;
    } else if (g_fb_sort_column == RVN_FB_COLUMN_DATE) {
        result = if (x.modified < y.modified) -1 else if (x.modified > y.modified) 1 else 0;
    }
    if (result == 0) {
        result = base.rvn_stricmp(x.name, y.name);
        if (result == 0) result = libc.strcmp(x.name, y.name);
        if (g_fb_sort_column != RVN_FB_COLUMN_NAME) return result;
    }
    return if (g_fb_sort_descending != 0) -result else result;
}

fn rvn_fb_free_selection_paths(browser: [*c]rvn_file_browser_t) void {
    var i: u32 = 0;
    while (i < browser.*.selection_count) : (i += 1) base.rvn_free(browser.*.selection_paths[i]);
    base.rvn_free(@ptrCast(browser.*.selection_paths));
    browser.*.selection_paths = null;
    browser.*.selection_count = 0;
}

fn rvn_fb_free_entries(browser: [*c]rvn_file_browser_t) void {
    ext.rvn_dir_free(browser.*.entries, browser.*.entry_count);
    base.rvn_free(browser.*.selected);
    browser.*.entries = null;
    browser.*.selected = null;
    browser.*.entry_count = 0;
    browser.*.cursor = -1;
    browser.*.anchor = -1;
    browser.*.hot = -1;
    rvn_fb_free_selection_paths(browser);
}

fn rvn_fb_patterns(browser: [*c]const rvn_file_browser_t) [*c]const u8 {
    if (browser.*.filter_index < 0 or browser.*.filter_index >= browser.*.filter_count) return null;
    return browser.*.filter_patterns[@intCast(browser.*.filter_index)];
}

/// Reads the current folder again. Returns R_FALSE when it cannot be read (the list is then empty).
fn rvn_fb_load(widget: [*c]widget_h.rvn_widget_t) c_int {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var all: [*c]fs_h.rvn_dir_entry_t = null;
    var count: u32 = 0;
    var kept: u32 = 0;
    var i: u32 = undefined;
    var keep: [*c]u8 = null;

    // the entry the cursor is on stays selected through a refresh
    if (browser.*.cursor >= 0) keep = base.rvn_strdup(browser.*.entries[@intCast(browser.*.cursor)].name);
    rvn_fb_free_entries(browser);
    const ok: c_int = @intFromBool(browser.*.directory != null and ext.rvn_dir_read(browser.*.directory, &all, &count) != 0);
    i = 0;
    while (i < count) : (i += 1) {
        const entry = &all[i];
        var show = browser.*.show_hidden != 0 or entry.*.hidden == 0;
        if (show and entry.*.is_dir == 0) {
            show = browser.*.mode != raven.R_FILE_BROWSER_FOLDER and ext.rvn_pattern_match(rvn_fb_patterns(browser), entry.*.name) != 0;
        }
        if (show) {
            all[kept] = entry.*;
            kept += 1;
        } else {
            base.rvn_free(entry.*.name);
        }
    }
    browser.*.entries = all;
    browser.*.entry_count = kept;
    browser.*.selected = @ptrCast(@alignCast(base.rvn_calloc(if (kept != 0) kept else 1)));
    g_fb_sort_column = browser.*.sort_column;
    g_fb_sort_descending = browser.*.sort_descending;
    if (kept > 1) libc.qsort(all, kept, @sizeOf(fs_h.rvn_dir_entry_t), &rvn_fb_compare);
    if (keep != null) {
        i = 0;
        while (i < kept) : (i += 1) {
            if (libc.strcmp(all[i].name, keep) == 0) {
                browser.*.cursor = @intCast(i);
                browser.*.anchor = @intCast(i);
                browser.*.selected[i] = 1;
                break;
            }
        }
        base.rvn_free(keep);
    }
    browser.*.bar.offset = 0.0;
    browser.*.select_y.started = 0;
    ext.rvn_widget_invalidate_layout(widget);
    return ok;
}

fn rvn_fb_entry_path(browser: [*c]const rvn_file_browser_t, index: c_int) [*c]u8 {
    return ext.rvn_path_child(browser.*.directory, browser.*.entries[@intCast(index)].name);
}

// ---------------------------------------------------------------------------
//  Fields
// ---------------------------------------------------------------------------

fn rvn_fb_set_field(browser: [*c]rvn_file_browser_t, field: [*c]widget_h.rvn_widget_t, text: [*c]const u8) void {
    browser.*.updating += 1;
    const value: [*c]const u8 = if (text != null) text else "";
    _ = ext.rvn_widget_set_attribute(field, "Text", value);
    browser.*.updating -= 1;
}

fn rvn_fb_accept_label(browser: [*c]const rvn_file_browser_t) [*c]const u8 {
    switch (browser.*.mode) {
        raven.R_FILE_BROWSER_SAVE => return "Save",
        raven.R_FILE_BROWSER_FOLDER => return "Select folder",
        else => return "Open",
    }
}

/// Brings the fields in line with the state: path, places, button label, visibility of the controls.
fn rvn_fb_sync_fields(widget: [*c]widget_h.rvn_widget_t) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const controls: raven.RVisibility = if (browser.*.controls_hidden != 0) raven.R_COLLAPSED else raven.R_VISIBLE;
    var place: c_int = -1;
    var i: u32 = undefined;

    rvn_fb_set_field(browser, browser.*.path_input, browser.*.directory);
    rvn_fb_set_field(browser, browser.*.accept_button, rvn_fb_accept_label(browser));
    browser.*.name_input.*.visibility = controls;
    browser.*.accept_button.*.visibility = controls;
    browser.*.cancel_button.*.visibility = controls;
    browser.*.filter_combo.*.visibility = if (browser.*.controls_hidden != 0 or browser.*.filter_count == 0 or
        browser.*.mode == raven.R_FILE_BROWSER_FOLDER) raven.R_COLLAPSED else raven.R_VISIBLE;
    browser.*.places_list.*.visibility = if (browser.*.places_hidden != 0) raven.R_COLLAPSED else raven.R_VISIBLE;
    i = 0;
    while (i < browser.*.place_count and browser.*.directory != null) : (i += 1) {
        if (libc.strcmp(browser.*.places[i].path, browser.*.directory) == 0) place = @intCast(i);
    }
    browser.*.updating += 1;
    raven.Rlist_view_set_selected(browser.*.places_list.*.id, place);
    browser.*.updating -= 1;
    ext.rvn_widget_invalidate_layout(widget);
}

/// A field that cannot take what was asked shakes its head.
fn rvn_fb_refuse(field: [*c]widget_h.rvn_widget_t) void {
    ext.rvn_widget_play_transition(field, raven.R_TRANSITION_POP, 0.0);
}

fn rvn_fb_notify_selection(widget: [*c]widget_h.rvn_widget_t) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    rvn_fb_free_selection_paths(browser);
    // the name of what is selected goes to the name field, when it is the kind of thing being chosen
    if (browser.*.cursor >= 0) {
        const entry = &browser.*.entries[@intCast(browser.*.cursor)];
        if (entry.*.is_dir == @intFromBool(browser.*.mode == raven.R_FILE_BROWSER_FOLDER)) rvn_fb_set_field(browser, browser.*.name_input, entry.*.name);
    }
    ext.rvn_widget_invalidate_paint(widget);
    if (browser.*.selection_changed) |callback| {
        const path: [*c]u8 = if (browser.*.cursor >= 0) rvn_fb_entry_path(browser, browser.*.cursor) else null;
        callback(widget.*.id, path, browser.*.selection_user);
        base.rvn_free(path);
    }
}

// ---------------------------------------------------------------------------
//  Navigation
// ---------------------------------------------------------------------------

fn rvn_fb_navigate(widget: [*c]widget_h.rvn_widget_t, path: [*c]const u8, remember: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var absolute: [*c]u8 = ext.rvn_path_absolute(path);
    var select: [*c]u8 = null;
    var i: c_int = undefined;

    if (absolute == null) return;
    // a path to a file shows its folder and selects the file
    if (ext.rvn_path_exists(absolute) != 0 and ext.rvn_path_is_dir(absolute) == 0) {
        const parent = ext.rvn_path_parent(absolute);
        select = base.rvn_strdup(ext.rvn_path_name(absolute));
        base.rvn_free(absolute);
        absolute = parent;
        if (absolute == null) {
            base.rvn_free(select);
            return;
        }
    }
    if (ext.rvn_path_is_dir(absolute) == 0) {
        base.rvn_free(absolute);
        base.rvn_free(select);
        rvn_fb_set_field(browser, browser.*.path_input, browser.*.directory);
        rvn_fb_refuse(browser.*.path_input);
        return;
    }
    if (browser.*.directory != null and libc.strcmp(browser.*.directory, absolute) == 0) {
        base.rvn_free(absolute);
    } else {
        base.rvn_free(browser.*.directory);
        browser.*.directory = absolute;
        if (remember != 0) {
            // a new visit forgets where Forward was going
            i = browser.*.history_at + 1;
            while (i < browser.*.history_count) : (i += 1) base.rvn_free(browser.*.history[@intCast(i)]);
            browser.*.history_count = browser.*.history_at + 1;
            if (browser.*.history_count == RVN_FB_HISTORY_MAX) {
                base.rvn_free(browser.*.history[0]);
                _ = libc.memmove(@ptrCast(&browser.*.history[0]), @ptrCast(&browser.*.history[1]), @sizeOf([*c]u8) * (RVN_FB_HISTORY_MAX - 1));
                browser.*.history_count -= 1;
            }
            browser.*.history[@intCast(browser.*.history_count)] = base.rvn_strdup(browser.*.directory);
            browser.*.history_count += 1;
            browser.*.history_at = browser.*.history_count - 1;
        }
        browser.*.cursor = -1;
    }
    _ = rvn_fb_load(widget);
    if (select != null) {
        i = 0;
        while (i < @as(c_int, @intCast(browser.*.entry_count))) : (i += 1) {
            if (libc.strcmp(browser.*.entries[@intCast(i)].name, select) == 0) {
                _ = libc.memset(browser.*.selected, 0, browser.*.entry_count);
                browser.*.selected[@intCast(i)] = 1;
                browser.*.cursor = i;
                browser.*.anchor = i;
            }
        }
        rvn_fb_set_field(browser, browser.*.name_input, select);
        base.rvn_free(select);
    }
    rvn_fb_sync_fields(widget);
    rvn_fb_notify_selection(widget);
}

fn rvn_fb_nav_enabled(browser: [*c]const rvn_file_browser_t, button: c_int) c_int {
    switch (button) {
        RVN_FB_BACK => return @intFromBool(browser.*.history_at > 0),
        RVN_FB_FORWARD => return @intFromBool(browser.*.history_at + 1 < browser.*.history_count),
        else => {
            const parent: [*c]u8 = if (browser.*.directory != null) ext.rvn_path_parent(browser.*.directory) else null;
            const has_parent = parent != null;
            base.rvn_free(parent);
            return @intFromBool(has_parent);
        },
    }
}

fn rvn_fb_nav(widget: [*c]widget_h.rvn_widget_t, button: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (rvn_fb_nav_enabled(browser, button) == 0) return;
    if (button == RVN_FB_UP) {
        const parent = ext.rvn_path_parent(browser.*.directory);
        const from = base.rvn_strdup(browser.*.directory);
        rvn_fb_navigate(widget, parent, raven.R_TRUE);
        // the folder that was left is the one selected in its parent
        Rfile_browser_select(widget.*.id, ext.rvn_path_name(from));
        base.rvn_free(parent);
        base.rvn_free(from);
    } else {
        browser.*.history_at += if (button == RVN_FB_BACK) -1 else 1;
        rvn_fb_navigate(widget, browser.*.history[@intCast(browser.*.history_at)], raven.R_FALSE);
    }
}

// ---------------------------------------------------------------------------
//  Choosing
// ---------------------------------------------------------------------------

fn rvn_fb_fire_accepted(widget: [*c]widget_h.rvn_widget_t, path: [*c]const u8) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const copy = base.rvn_strdup(path);
    ext.rvn_dispatch_begin();
    if (browser.*.accepted) |callback| callback(widget.*.id, copy, browser.*.accepted_user);
    if (common.rvn_widget_alive(widget) != 0) ext.rvn_widget_fire_action(widget);
    ext.rvn_dispatch_end();
    base.rvn_free(copy);
}

/// What the name field means: a path, relative to the folder shown unless it is absolute.
fn rvn_fb_resolve(browser: [*c]const rvn_file_browser_t, name: [*c]const u8) [*c]u8 {
    var is_absolute = name[0] == '~' or fs_h.rvn_path_is_separator(name[0]) != 0;
    if (builtin.os.tag == .windows) {
        if (name[0] != 0 and name[1] == ':') is_absolute = true;
    }
    if (is_absolute) return ext.rvn_path_absolute(name);
    const joined = ext.rvn_path_child(browser.*.directory, name);
    const absolute = ext.rvn_path_absolute(joined);
    base.rvn_free(joined);
    return absolute;
}

/// Name with the default extension, when it was typed without one. Free with rvn_free.
fn rvn_fb_with_extension(browser: [*c]const rvn_file_browser_t, name: [*c]const u8) [*c]u8 {
    var extension: [*c]const u8 = browser.*.default_extension;
    const patterns = rvn_fb_patterns(browser);
    var first: [32]u8 = undefined;

    if (libc.strchr(ext.rvn_path_name(name), '.') != null) return base.rvn_strdup(name);
    if ((extension == null or extension[0] == 0) and patterns != null and patterns[0] == '*' and patterns[1] == '.') {
        // the first pattern of the active filter: "*.xml;*.ui" -> "xml"
        var i: usize = 0;
        while (patterns[2 + i] != 0 and patterns[2 + i] != ';' and patterns[2 + i] != ',' and patterns[2 + i] != '*' and i + 1 < first.len) {
            first[i] = patterns[2 + i];
            i += 1;
        }
        first[i] = 0;
        extension = &first;
    }
    if (extension == null or extension[0] == 0) return base.rvn_strdup(name);
    if (extension[0] == '.') extension += 1;
    const length = libc.strlen(name);
    const result: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(length + libc.strlen(extension) + 2)));
    @memcpy(result[0..length], name[0..length]);
    result[length] = '.';
    _ = libc.strcpy(result + length + 1, extension);
    return result;
}

fn rvn_fb_name_text(browser: [*c]const rvn_file_browser_t) [*c]const u8 {
    var text: [*c]const u8 = raven.Rtext_input_get_text(browser.*.name_input.*.id);
    while (text[0] == ' ') text += 1;
    return text;
}

fn rvn_fb_accept(widget: [*c]widget_h.rvn_widget_t) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const name = rvn_fb_name_text(browser);
    var path: [*c]u8 = undefined;

    if (browser.*.directory == null) return;
    if (browser.*.mode == raven.R_FILE_BROWSER_FOLDER) {
        if (name[0] == 0) {
            rvn_fb_fire_accepted(widget, browser.*.directory);
            return;
        }
        path = rvn_fb_resolve(browser, name);
        if (path != null and ext.rvn_path_is_dir(path) != 0) {
            rvn_fb_fire_accepted(widget, path);
        } else {
            rvn_fb_refuse(browser.*.name_input);
        }
        base.rvn_free(path);
        return;
    }

    if (name[0] == 0) {
        // nothing typed: Open enters the folder the cursor is on
        if (browser.*.cursor >= 0 and browser.*.entries[@intCast(browser.*.cursor)].is_dir != 0) {
            path = rvn_fb_entry_path(browser, browser.*.cursor);
            rvn_fb_navigate(widget, path, raven.R_TRUE);
            base.rvn_free(path);
        } else {
            rvn_fb_refuse(browser.*.name_input);
        }
        return;
    }
    if (browser.*.mode == raven.R_FILE_BROWSER_SAVE) {
        const full = rvn_fb_with_extension(browser, name);
        path = rvn_fb_resolve(browser, full);
        base.rvn_free(full);
    } else {
        path = rvn_fb_resolve(browser, name);
    }
    if (path == null) return;
    if (ext.rvn_path_is_dir(path) != 0) {
        rvn_fb_set_field(browser, browser.*.name_input, "");
        rvn_fb_navigate(widget, path, raven.R_TRUE);
    } else if (browser.*.mode == raven.R_FILE_BROWSER_OPEN) {
        if (ext.rvn_path_exists(path) != 0) {
            rvn_fb_fire_accepted(widget, path);
        } else {
            rvn_fb_refuse(browser.*.name_input);
        }
    } else {
        var write = true;
        if (ext.rvn_path_exists(path) != 0 and widget.*.window != null) {
            var message: [512]u8 = undefined;
            const id = widget.*.id;
            _ = libc.snprintf(&message, message.len, "\"%.300s\" already exists.\nDo you want to replace it?", ext.rvn_path_name(path));
            write = raven.Rmessage_box(widget.*.window.*.id, "Replace the file?", &message, raven.R_MESSAGE_YES_NO) == raven.R_MESSAGE_RESULT_YES;
            // (the application went on running while the question was shown)
            if (ext.rvn_widget_get(id) == null) write = false;
        }
        if (write) rvn_fb_fire_accepted(widget, path);
    }
    base.rvn_free(path);
}

/// A double click or Enter on an entry of the list.
fn rvn_fb_activate(widget: [*c]widget_h.rvn_widget_t, index: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (index < 0 or index >= @as(c_int, @intCast(browser.*.entry_count))) return;
    const path = rvn_fb_entry_path(browser, index);
    if (browser.*.entries[@intCast(index)].is_dir != 0) {
        rvn_fb_navigate(widget, path, raven.R_TRUE);
    } else if (browser.*.mode == raven.R_FILE_BROWSER_SAVE) {
        rvn_fb_set_field(browser, browser.*.name_input, browser.*.entries[@intCast(index)].name);
        rvn_fb_accept(widget);
    } else {
        rvn_fb_fire_accepted(widget, path);
    }
    base.rvn_free(path);
}

// ---------------------------------------------------------------------------
//  Callbacks of the fields
// ---------------------------------------------------------------------------

fn rvn_fb_on_path(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = input;
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.updating != 0) return;
    rvn_fb_navigate(widget, text, raven.R_TRUE);
}

fn rvn_fb_on_name(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = input;
    _ = text;
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.updating != 0) return;
    rvn_fb_accept(widget);
}

fn rvn_fb_on_place(list: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = list;
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.updating != 0 or index < 0 or index >= @as(c_int, @intCast(browser.*.place_count))) return;
    rvn_fb_navigate(widget, browser.*.places[@intCast(index)].path, raven.R_TRUE);
}

fn rvn_fb_on_filter(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = combo;
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.updating != 0) return;
    browser.*.filter_index = index;
    _ = rvn_fb_load(widget);
}

fn rvn_fb_on_accept(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = button;
    if (widget != null) rvn_fb_accept(widget);
}

fn rvn_fb_on_cancel(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = rvn_fb_from_user(user_data);
    _ = button;
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.cancelled) |callback| callback(widget.*.id, null, browser.*.cancelled_user);
}

// ---------------------------------------------------------------------------
//  Class
// ---------------------------------------------------------------------------

fn rvn_fb_child(widget: [*c]widget_h.rvn_widget_t, type_: raven.RWidgetType) [*c]widget_h.rvn_widget_t {
    const child = ext.rvn_widget_create(type_);
    ext.rvn_widget_add_child(widget, child, -1);
    return child;
}

fn rvn_file_browser_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const self: ?*anyopaque = @ptrFromInt(@as(usize, widget.*.id));
    var i: u32 = undefined;

    browser.*.mode = raven.R_FILE_BROWSER_OPEN;
    browser.*.cursor = -1;
    browser.*.anchor = -1;
    browser.*.hot = -1;
    browser.*.nav_hot = -1;
    browser.*.nav_down = -1;
    browser.*.history_at = -1;

    browser.*.path_input = rvn_fb_child(widget, raven.R_WIDGET_TEXT_INPUT);
    browser.*.places_list = rvn_fb_child(widget, raven.R_WIDGET_LIST_VIEW);
    browser.*.name_input = rvn_fb_child(widget, raven.R_WIDGET_TEXT_INPUT);
    browser.*.filter_combo = rvn_fb_child(widget, raven.R_WIDGET_COMBO_BOX);
    browser.*.cancel_button = rvn_fb_child(widget, raven.R_WIDGET_BUTTON);
    browser.*.accept_button = rvn_fb_child(widget, raven.R_WIDGET_BUTTON);
    _ = ext.rvn_widget_set_attribute(browser.*.name_input, "Placeholder", "File name");
    _ = ext.rvn_widget_set_attribute(browser.*.cancel_button, "Text", "Cancel");
    _ = ext.rvn_widget_set_attribute(browser.*.accept_button, "Style", "Primary");
    raven.Rtext_input_set_committed_callback(browser.*.path_input.*.id, &rvn_fb_on_path, self);
    raven.Rtext_input_set_committed_callback(browser.*.name_input.*.id, &rvn_fb_on_name, self);
    raven.Rlist_view_set_selection_changed_callback(browser.*.places_list.*.id, &rvn_fb_on_place, self);
    raven.Rcombo_box_set_changed_callback(browser.*.filter_combo.*.id, &rvn_fb_on_filter, self);
    raven.Rbutton_set_clicked_callback(browser.*.accept_button.*.id, &rvn_fb_on_accept, self);
    raven.Rbutton_set_clicked_callback(browser.*.cancel_button.*.id, &rvn_fb_on_cancel, self);

    ext.rvn_fs_places(&browser.*.places, &browser.*.place_count);
    i = 0;
    while (i < browser.*.place_count) : (i += 1) {
        _ = raven.Rlist_view_add_item(browser.*.places_list.*.id, browser.*.places[i].label);
    }

    const home = ext.rvn_path_home();
    rvn_fb_navigate(widget, home, raven.R_TRUE);
    base.rvn_free(home);
}

fn rvn_file_browser_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var i: c_int = 0;
    rvn_fb_free_entries(browser);
    ext.rvn_fs_places_free(browser.*.places, browser.*.place_count);
    while (i < browser.*.filter_count) : (i += 1) {
        base.rvn_free(browser.*.filter_names[@intCast(i)]);
        base.rvn_free(browser.*.filter_patterns[@intCast(i)]);
    }
    base.rvn_free(@ptrCast(browser.*.filter_names));
    base.rvn_free(@ptrCast(browser.*.filter_patterns));
    i = 0;
    while (i < browser.*.history_count) : (i += 1) base.rvn_free(browser.*.history[@intCast(i)]);
    base.rvn_free(browser.*.default_extension);
    base.rvn_free(browser.*.directory);
}

fn rvn_fb_row_height(widget: [*c]const widget_h.rvn_widget_t) f32 {
    return ext.rvn_widget_metric(widget, raven.R_METRIC_ROW_HEIGHT);
}

fn rvn_file_browser_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var i: u32 = 0;
    // (the children are arranged by hand, but they still need their own measure)
    while (i < widget.*.child_count) : (i += 1) _ = ext.rvn_widget_measure(widget.*.children[i]);
    if (browser.*.controls_hidden != 0) return base.rvn_vec2(if (browser.*.places_hidden != 0) 300.0 else 460.0, 320.0);
    return base.rvn_vec2(720.0, 440.0);
}

fn rvn_file_browser_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const control = ext.rvn_widget_metric(widget, raven.R_METRIC_CONTROL_HEIGHT);
    const width = widget.*.rect.w;
    const height = widget.*.rect.h;
    const top: f32 = control + RVN_FB_GAP;
    var bottom: f32 = height;
    var x: f32 = 0.0;
    var list_x: f32 = 0.0;
    var i: usize = 0;

    while (i < RVN_FB_NAV_COUNT) : (i += 1) {
        browser.*.nav[i] = base.rvn_rect(x, 0.0, control, control);
        x += control + 4.0;
    }
    x += 4.0;
    ext.rvn_widget_arrange(browser.*.path_input, x, 0.0, base.rvn_maxf(0.0, width - x), control);

    if (browser.*.controls_hidden == 0) {
        const accept = base.rvn_maxf(browser.*.accept_button.*.desired.x, 96.0);
        const cancel = base.rvn_maxf(browser.*.cancel_button.*.desired.x, 84.0);
        const filter: f32 = if (widget_h.rvn_widget_collapsed(browser.*.filter_combo) != 0) 0.0 else base.rvn_minf(210.0, width * 0.35);
        var row = height - control;
        ext.rvn_widget_arrange(browser.*.accept_button, width - accept, row, accept, control);
        ext.rvn_widget_arrange(browser.*.cancel_button, width - accept - RVN_FB_GAP - cancel, row, cancel, control);
        row -= control + RVN_FB_GAP;
        if (filter > 0.0) ext.rvn_widget_arrange(browser.*.filter_combo, width - filter, row, filter, control);
        ext.rvn_widget_arrange(browser.*.name_input, 0.0, row, base.rvn_maxf(0.0, width - (if (filter > 0.0) filter + RVN_FB_GAP else 0.0)), control);
        bottom = row - RVN_FB_GAP;
    }

    // the places leave when the browser is too narrow for them
    const places = browser.*.places_hidden == 0 and width >= 420.0;
    if (places) {
        ext.rvn_widget_arrange(browser.*.places_list, 0.0, top, RVN_FB_PLACES_WIDTH, base.rvn_maxf(0.0, bottom - top));
        list_x = RVN_FB_PLACES_WIDTH + RVN_FB_GAP;
    } else {
        ext.rvn_widget_arrange(browser.*.places_list, 0.0, top, 0.0, 0.0);
    }
    browser.*.list = base.rvn_rect(list_x, top, base.rvn_maxf(0.0, width - list_x), base.rvn_maxf(0.0, bottom - top));
    browser.*.header_height = rvn_fb_row_height(widget) + 2.0;
    browser.*.bar.content = rvn_fb_row_height(widget) * @as(f32, @floatFromInt(browser.*.entry_count));
    browser.*.bar.viewport = base.rvn_maxf(0.0, browser.*.list.h - browser.*.header_height - 2.0);
    _ = common.rvn_scrollbar_clamp(&browser.*.bar);
}

fn rvn_file_browser_child_active(widget: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t) callconv(.c) c_int {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (child == browser.*.places_list) return @intFromBool(child.*.rect.w > 0.0);
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  List: geometry
// ---------------------------------------------------------------------------

fn rvn_fb_track(widget: [*c]const widget_h.rvn_widget_t) base.rvn_rect_t {
    const browser: [*c]const rvn_file_browser_t = @ptrCast(widget);
    const bar = ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    return base.rvn_rect(browser.*.list.x + browser.*.list.w - bar - 1.0, browser.*.list.y + browser.*.header_height,
        bar, base.rvn_maxf(0.0, browser.*.list.h - browser.*.header_height - 1.0));
}

/// Top of the rows, in widget coordinates, for a scroll offset of 0.
fn rvn_fb_rows_top(browser: [*c]const rvn_file_browser_t) f32 {
    return browser.*.list.y + browser.*.header_height;
}

fn rvn_fb_row_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const browser: [*c]const rvn_file_browser_t = @ptrCast(widget);
    const top = rvn_fb_rows_top(browser);
    if (x < browser.*.list.x or x >= browser.*.list.x + browser.*.list.w or y < top or y >= browser.*.list.y + browser.*.list.h - 1.0) return -1;
    const row: c_int = @intFromFloat(@floor((y - top + browser.*.bar.offset) / rvn_fb_row_height(widget)));
    return if (row >= 0 and row < @as(c_int, @intCast(browser.*.entry_count))) row else -1;
}

/// Column of the header under a point, or -1.
fn rvn_fb_column_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const browser: [*c]const rvn_file_browser_t = @ptrCast(widget);
    const right = browser.*.list.x + browser.*.list.w;
    if (x < browser.*.list.x or x >= right or y < browser.*.list.y or y >= browser.*.list.y + browser.*.header_height) return -1;
    if (browser.*.list.w < 380.0) return RVN_FB_COLUMN_NAME;
    if (x >= right - RVN_FB_DATE_WIDTH) return RVN_FB_COLUMN_DATE;
    if (x >= right - RVN_FB_DATE_WIDTH - RVN_FB_SIZE_WIDTH) return RVN_FB_COLUMN_SIZE;
    return RVN_FB_COLUMN_NAME;
}

fn rvn_fb_nav_at(widget: [*c]const widget_h.rvn_widget_t, x: f32, y: f32) c_int {
    const browser: [*c]const rvn_file_browser_t = @ptrCast(widget);
    var i: usize = 0;
    while (i < RVN_FB_NAV_COUNT) : (i += 1) {
        if (base.rvn_rect_contains(browser.*.nav[i], x, y) != 0) return @intCast(i);
    }
    return -1;
}

fn rvn_fb_reveal(widget: [*c]widget_h.rvn_widget_t, row: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const height = rvn_fb_row_height(widget);
    const top: f32 = height * @as(f32, @floatFromInt(row));
    if (row < 0) return;
    browser.*.bar.content = height * @as(f32, @floatFromInt(browser.*.entry_count));
    if (top < browser.*.bar.offset) {
        _ = common.rvn_scrollbar_set(&browser.*.bar, top);
    } else if (top + height > browser.*.bar.offset + browser.*.bar.viewport) {
        _ = common.rvn_scrollbar_set(&browser.*.bar, top + height - browser.*.bar.viewport);
    }
    ext.rvn_widget_invalidate_paint(widget);
}

/// Moves the cursor to a row: alone, added to the selection (toggle), or as the end of a range.
fn rvn_fb_select_row(widget: [*c]widget_h.rvn_widget_t, row: c_int, toggle: c_int, range: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var toggle_ = toggle;
    var range_ = range;
    var i: c_int = undefined;
    if (row < 0 or row >= @as(c_int, @intCast(browser.*.entry_count))) return;
    if (browser.*.multiple == 0) {
        toggle_ = raven.R_FALSE;
        range_ = raven.R_FALSE;
    }
    if (range_ != 0 and browser.*.anchor >= 0) {
        const from = base.rvn_mini(browser.*.anchor, row);
        const to = base.rvn_maxi(browser.*.anchor, row);
        i = 0;
        while (i < @as(c_int, @intCast(browser.*.entry_count))) : (i += 1) {
            browser.*.selected[@intCast(i)] = @intFromBool(i >= from and i <= to);
        }
    } else if (toggle_ != 0) {
        browser.*.selected[@intCast(row)] = @intFromBool(browser.*.selected[@intCast(row)] == 0);
        browser.*.anchor = row;
    } else {
        _ = libc.memset(browser.*.selected, 0, browser.*.entry_count);
        browser.*.selected[@intCast(row)] = 1;
        browser.*.anchor = row;
    }
    browser.*.cursor = row;
    rvn_fb_reveal(widget, row);
    rvn_fb_notify_selection(widget);
}

// ---------------------------------------------------------------------------
//  Paint
// ---------------------------------------------------------------------------

fn rvn_fb_format_size(size: u64, out: [*c]u8, out_size: usize) void {
    const units = [_][*c]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(size);
    var unit: c_int = 0;
    while (value >= 1024.0 and unit < 4) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) {
        _ = libc.snprintf(out, out_size, "%u B", @as(c_uint, @truncate(size)));
    } else {
        const format: [*c]const u8 = if (value < 10.0) "%.1f %s" else "%.0f %s";
        _ = libc.snprintf(out, out_size, format, value, units[@intCast(unit)]);
    }
}

/// `time_t` is a 64-bit integer on every target Raven supports (std.c.time_t is void on Windows).
extern "c" fn localtime(timer: *const i64) ?*anyopaque; // struct tm*

fn rvn_fb_format_date(seconds: i64, out: [*c]u8, out_size: usize) void {
    const time: i64 = seconds;
    const local: ?*anyopaque = if (seconds > 0) localtime(&time) else null;
    out[0] = 0;
    if (local != null) _ = libc.strftime(out, out_size, "%Y-%m-%d %H:%M", local);
}

/// A folder or a sheet of paper, in a 16 x 14 box.
fn rvn_fb_paint_icon(painter: ?*raven.RPainter, is_dir: c_int, x: f32, y: f32, accent: base.rvn_color_t, text: base.rvn_color_t) void {
    if (is_dir != 0) {
        ext.rvn_paint_box(painter, base.rvn_rect(x, y, 7.5, 5.0), 1.5, accent, 0.0, 0);
        ext.rvn_paint_box(painter, base.rvn_rect(x, y + 2.5, 16.0, 11.0), 2.0, accent, 0.0, 0);
        ext.rvn_paint_rect(painter, base.rvn_rect(x + 1.0, y + 4.5, 14.0, 1.0), base.rvn_rgba(1.0, 1.0, 1.0, 0.25));
    } else {
        const line = base.rvn_color_fade(text, 0.55);
        ext.rvn_paint_box(painter, base.rvn_rect(x + 2.5, y - 0.5, 11.0, 14.5), 2.0, base.rvn_color_fade(text, 0.08), 1.0, line);
        ext.rvn_paint_rect(painter, base.rvn_rect(x + 5.0, y + 4.0, 6.0, 1.0), line);
        ext.rvn_paint_rect(painter, base.rvn_rect(x + 5.0, y + 7.0, 6.0, 1.0), line);
        ext.rvn_paint_rect(painter, base.rvn_rect(x + 5.0, y + 10.0, 4.0, 1.0), line);
    }
}

fn rvn_fb_paint_nav(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, button: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const angles = [RVN_FB_NAV_COUNT]f32{ 3.14159265, 0.0, -1.57079633 };
    const idx: usize = @intCast(button);
    const rect = browser.*.nav[idx];
    const enabled = dp.*.enabled != 0 and rvn_fb_nav_enabled(browser, button) != 0;
    const hover = ext.rvn_paint_spring(painter, &browser.*.nav_hover[idx], if (enabled and browser.*.nav_hot == button) 1.0 else 0.0, raven.R_MOTION_BOUNCY);
    const press = ext.rvn_paint_spring(painter, &browser.*.nav_press[idx],
        if (enabled and browser.*.nav_down == button and browser.*.nav_hot == button) 1.0 else 0.0, raven.R_MOTION_SNAPPY);
    const text = ext.rvn_widget_text_color(widget, painter);
    const first_instance = dp.*.list.*.instance_count;
    const first_command = dp.*.list.*.command_count;
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;

    if (widget_h.rvn_widget_glass(widget) != 0) {
        const shown = base.rvn_clampf(base.rvn_maxf(hover, press), 0.0, 1.0);
        if (shown > 0.01) {
            const opacity = dp.*.opacity;
            dp.*.opacity *= shown;
            common.rvn_paint_surface(painter, widget, rect, rect.h * 0.5, common.RVN_SURFACE_CONTROL, hover, press);
            dp.*.opacity = opacity;
        }
    } else {
        const fill = base.rvn_color_mix(base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_HOVERED), base.rvn_clampf(hover, 0.0, 1.0)),
            ext.rvn_widget_color(widget, raven.R_COLOR_CONTROL_PRESSED), base.rvn_clampf(press, 0.0, 1.0));
        ext.rvn_paint_box(painter, rect, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), fill, 0.0, 0);
    }
    ext.rvn_paint_chevron(painter, cx, cy, 10.0, angles[idx], if (enabled) text else base.rvn_color_fade(text, 0.3));
    const scale: f32 = 1.0 + 0.16 * hover - 0.2 * press;
    if (scale < 0.999 or scale > 1.001) {
        ext.rvn_drawlist_transform(dp.*.list, first_instance, first_command, scale, scale,
            (dp.*.ox + cx) * dp.*.scale, (dp.*.oy + cy) * dp.*.scale, 0.0, 0.0, dp.*.clip);
    }
}

fn rvn_file_browser_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const dp: *draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const list = browser.*.list;
    const row = rvn_fb_row_height(widget);
    const padding = ext.rvn_widget_metric(widget, raven.R_METRIC_PADDING_X) * 0.8;
    const font = common.rvn_widget_font_size(widget, 0.0);
    const bar_width: f32 = if (common.rvn_scrollbar_needed(&browser.*.bar) != 0) ext.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE) else 0.0;
    const content_width = list.w - 2.0 - bar_width;
    const offset = common.rvn_scrollbar_shown(&browser.*.bar, painter);
    const top = rvn_fb_rows_top(browser);
    const focused = (widget.*.flags & widget_h.RVN_WF_FOCUSED) != 0;
    const columns = list.w >= 380.0;
    const name_width = content_width - (if (columns) RVN_FB_SIZE_WIDTH + RVN_FB_DATE_WIDTH else 0.0);
    const text = ext.rvn_widget_text_color(widget, painter);
    const dim = base.rvn_color_fade(text, 0.6);
    const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    const selection = ext.rvn_widget_color(widget, raven.R_COLOR_SELECTION);
    const origin = ext.rvn_widget_origin(widget);
    var i: c_int = undefined;

    i = 0;
    while (i < RVN_FB_NAV_COUNT) : (i += 1) rvn_fb_paint_nav(widget, painter, i);
    if (list.w <= 2.0 or list.h <= 2.0) return;

    ext.rvn_paint_box(painter, list, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), ext.rvn_widget_color(widget, raven.R_COLOR_INPUT),
        ext.rvn_widget_metric(widget, raven.R_METRIC_BORDER_WIDTH), ext.rvn_widget_color(widget, if (focused) raven.R_COLOR_FOCUS else raven.R_COLOR_BORDER));

    // header: the names of the columns; a chevron shows which one orders the list
    {
        const titles = [_][*c]const u8{ "Name", "Size", "Modified" };
        var x: [3]f32 = undefined;
        var w: [3]f32 = undefined;
        x[0] = list.x + 1.0;
        w[0] = name_width;
        x[1] = x[0] + name_width;
        w[1] = RVN_FB_SIZE_WIDTH;
        x[2] = x[1] + RVN_FB_SIZE_WIDTH;
        w[2] = RVN_FB_DATE_WIDTH;
        i = 0;
        while (i < (if (columns) @as(c_int, 3) else 1)) : (i += 1) {
            const idx: usize = @intCast(i);
            const cell = base.rvn_rect(x[idx] + padding, list.y + 1.0, base.rvn_maxf(0.0, w[idx] - padding * 2.0), browser.*.header_height - 1.0);
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font, cell, if (i == RVN_FB_COLUMN_SIZE) 1.0 else 0.0, titles[idx], -1, dim);
            if (browser.*.sort_column == i) {
                const title_width = common.rvn_widget_text_width(widget, raven.R_INVALID_ID, 0.0, titles[idx]);
                const cx = if (i == RVN_FB_COLUMN_SIZE) cell.x + cell.w - title_width - 10.0 else cell.x + title_width + 10.0;
                ext.rvn_paint_chevron(painter, cx, cell.y + cell.h * 0.5, 7.0, if (browser.*.sort_descending != 0) 1.57079633 else -1.57079633, dim);
            }
        }
        ext.rvn_paint_rect(painter, base.rvn_rect(list.x + 1.0, list.y + browser.*.header_height - 1.0, list.w - 2.0, 1.0),
            ext.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR));
    }

    ext.rvn_paint_push_clip(painter, base.rvn_rect(list.x + 1.0, top, list.w - 2.0, base.rvn_maxf(0.0, list.h - browser.*.header_height - 1.0)));
    const first: c_int = base.rvn_maxi(@intFromFloat(@floor(offset / row)), 0);
    const last: c_int = base.rvn_mini(@as(c_int, @intCast(browser.*.entry_count)), first + @as(c_int, @intFromFloat(browser.*.bar.viewport / row)) + 3);
    if (browser.*.cursor >= 0 and browser.*.selected[@intCast(browser.*.cursor)] != 0) {
        // the row under the cursor glides from where it was
        const y = ext.rvn_paint_spring(painter, &browser.*.select_y, row * @as(f32, @floatFromInt(browser.*.cursor)), raven.R_MOTION_SNAPPY);
        common.rvn_paint_row(painter, widget, base.rvn_rect(list.x + 1.0, top + y - offset, content_width, row),
            if (focused) selection else base.rvn_color_mix(selection, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), 0.45));
    } else {
        browser.*.select_y.started = 0;
    }
    i = first;
    while (i < last) : (i += 1) {
        const idx: usize = @intCast(i);
        const entry = &browser.*.entries[idx];
        const line = base.rvn_rect(list.x + 1.0, top + row * @as(f32, @floatFromInt(i)) - offset, content_width, row);
        var buffer: [48]u8 = undefined;
        if (browser.*.selected[idx] != 0 and i != browser.*.cursor) {
            common.rvn_paint_row(painter, widget, line, base.rvn_color_mix(selection, ext.rvn_widget_color(widget, raven.R_COLOR_INPUT), if (focused) 0.2 else 0.45));
        } else if (i == browser.*.hot and browser.*.selected[idx] == 0 and (widget.*.flags & widget_h.RVN_WF_HOVERED) != 0 and dp.*.enabled != 0) {
            common.rvn_paint_row(painter, widget, line, ext.rvn_widget_color(widget, raven.R_COLOR_ROW_HOVERED));
        }
        rvn_fb_paint_icon(painter, entry.*.is_dir, line.x + padding, line.y + @floor((row - 14.0) * 0.5), accent, text);
        ext.rvn_paint_push_clip(painter, base.rvn_rect(line.x, line.y, base.rvn_maxf(0.0, name_width - 6.0), row));
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font, base.rvn_rect(line.x + padding + 24.0, line.y, name_width, row), 0.0, entry.*.name, -1, text);
        ext.rvn_paint_pop_clip(painter);
        if (!columns) continue;
        if (entry.*.is_dir == 0) {
            rvn_fb_format_size(entry.*.size, &buffer, buffer.len);
            ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font,
                base.rvn_rect(line.x + name_width + padding, line.y, RVN_FB_SIZE_WIDTH - padding * 2.0, row), 1.0, &buffer, -1, dim);
        }
        rvn_fb_format_date(entry.*.modified, &buffer, buffer.len);
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font,
            base.rvn_rect(line.x + name_width + RVN_FB_SIZE_WIDTH + padding, line.y, RVN_FB_DATE_WIDTH - padding * 2.0, row), 0.0, &buffer, -1, dim);
    }
    if (browser.*.entry_count == 0) {
        ext.rvn_paint_text_in(painter, raven.R_INVALID_ID, font, base.rvn_rect(list.x, top, list.w, base.rvn_minf(row * 3.0, list.h - browser.*.header_height)),
            0.5, "This folder is empty", -1, dim);
    }
    ext.rvn_paint_pop_clip(painter);
    common.rvn_scrollbar_paint(&browser.*.bar, widget, painter, rvn_fb_track(widget), raven.R_TRUE,
        if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0,
        if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0);
}

// ---------------------------------------------------------------------------
//  Events
// ---------------------------------------------------------------------------

/// Typing the start of a name moves the cursor to the first entry that has it.
fn rvn_fb_type(widget: [*c]widget_h.rvn_widget_t, codepoint: u32) c_int {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const now = ext.rvn_clock_seconds();
    var encoded: [4]u8 = undefined;
    var length: usize = libc.strlen(&browser.*.typed);
    var i: c_int = undefined;
    if (codepoint < 32) return raven.R_FALSE;
    if (now - browser.*.typed_time > 0.9) length = 0;
    const bytes: c_int = base.rvn_utf8_encode(codepoint, &encoded);
    const nbytes: usize = @intCast(bytes);
    if (length + nbytes >= browser.*.typed.len) length = 0;
    @memcpy(browser.*.typed[length..][0..nbytes], encoded[0..nbytes]);
    length += nbytes;
    browser.*.typed[length] = 0;
    browser.*.typed_time = now;
    i = 0;
    while (i < @as(c_int, @intCast(browser.*.entry_count))) : (i += 1) {
        if (base.rvn_strnicmp(browser.*.entries[@intCast(i)].name, &browser.*.typed, length) == 0) {
            rvn_fb_select_row(widget, i, raven.R_FALSE, raven.R_FALSE);
            break;
        }
    }
    return raven.R_TRUE;
}

fn rvn_file_browser_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    const own = event.*.target == widget.*.id;
    const count: c_int = @intCast(browser.*.entry_count);
    var changed: c_int = raven.R_FALSE;
    var row: c_int = undefined;
    var page: c_int = undefined;

    if (own and (event.*.@"type" == raven.R_EVENT_MOUSE_DOWN or event.*.@"type" == raven.R_EVENT_MOUSE_MOVE or event.*.@"type" == raven.R_EVENT_MOUSE_UP)) {
        if (common.rvn_scrollbar_event(&browser.*.bar, widget, event, rvn_fb_track(widget), raven.R_TRUE, &changed) != 0) {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        }
    }
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            const nav: c_int = if (own) rvn_fb_nav_at(widget, event.*.local_x, event.*.local_y) else -1;
            row = if (own) rvn_fb_row_at(widget, event.*.local_x, event.*.local_y) else -1;
            if (row != browser.*.hot or nav != browser.*.nav_hot) {
                browser.*.hot = row;
                browser.*.nav_hot = nav;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return @intFromBool(browser.*.nav_down >= 0);
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            browser.*.hot = -1;
            if (browser.*.nav_down < 0) browser.*.nav_hot = -1;
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (!own or event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            const nav = rvn_fb_nav_at(widget, event.*.local_x, event.*.local_y);
            if (nav >= 0) {
                browser.*.nav_down = nav;
                browser.*.nav_hot = nav;
                ext.rvn_widget_capture_mouse(widget);
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_TRUE;
            }
            const column = rvn_fb_column_at(widget, event.*.local_x, event.*.local_y);
            if (column >= 0) {
                // a second click on the same column reverses the order
                if (browser.*.sort_column == column) {
                    browser.*.sort_descending = @intFromBool(browser.*.sort_descending == 0);
                } else {
                    browser.*.sort_descending = raven.R_FALSE;
                }
                browser.*.sort_column = column;
                _ = rvn_fb_load(widget);
                return raven.R_TRUE;
            }
            row = rvn_fb_row_at(widget, event.*.local_x, event.*.local_y);
            if (row >= 0) {
                if (event.*.clicks == 2) {
                    rvn_fb_activate(widget, row);
                } else {
                    rvn_fb_select_row(widget, row,
                        @intFromBool((event.*.modifiers & raven.R_MOD_CTRL) != 0),
                        @intFromBool((event.*.modifiers & raven.R_MOD_SHIFT) != 0));
                }
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            const down = browser.*.nav_down;
            if (event.*.button != raven.R_MOUSE_LEFT or down < 0) return raven.R_FALSE;
            browser.*.nav_down = -1;
            ext.rvn_widget_release_mouse(widget);
            ext.rvn_widget_invalidate_paint(widget);
            if (rvn_fb_nav_at(widget, event.*.local_x, event.*.local_y) == down) {
                ext.rvn_spring_kick(&browser.*.nav_hover[@intCast(down)], 6.0);
                rvn_fb_nav(widget, down);
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if (!own) return raven.R_FALSE;
            if (common.rvn_scrollbar_wheel(&browser.*.bar, -event.*.wheel_y * rvn_fb_row_height(widget) * 3.0) == 0) {
                ext.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            }
            browser.*.hot = rvn_fb_row_at(widget, event.*.local_x, event.*.local_y);
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_TRUE;
        },
        raven.R_EVENT_FOCUS_GAINED, raven.R_EVENT_FOCUS_LOST => {
            ext.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_TEXT => {
            if (!own or (event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL | raven.R_MOD_ALT))) != 0) return raven.R_FALSE;
            return rvn_fb_type(widget, event.*.codepoint);
        },
        raven.R_EVENT_KEY_DOWN => {
            if (!own) return raven.R_FALSE;
            page = base.rvn_maxi(1, @as(c_int, @intFromFloat(browser.*.bar.viewport / rvn_fb_row_height(widget))) - 1);
            switch (event.*.key) {
                raven.R_KEY_UP => row = if (browser.*.cursor < 0) count - 1 else browser.*.cursor - 1,
                raven.R_KEY_DOWN => row = browser.*.cursor + 1,
                raven.R_KEY_PAGE_UP => row = browser.*.cursor - page,
                raven.R_KEY_PAGE_DOWN => row = browser.*.cursor + page,
                raven.R_KEY_HOME => row = 0,
                raven.R_KEY_END => row = count - 1,
                raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
                    if (browser.*.cursor >= 0) rvn_fb_activate(widget, browser.*.cursor);
                    return raven.R_TRUE;
                },
                raven.R_KEY_BACKSPACE => {
                    rvn_fb_nav(widget, RVN_FB_UP);
                    return raven.R_TRUE;
                },
                raven.R_KEY_LEFT, raven.R_KEY_RIGHT => {
                    if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_ALT))) == 0) return raven.R_FALSE;
                    rvn_fb_nav(widget, if (event.*.key == raven.R_KEY_LEFT) RVN_FB_BACK else RVN_FB_FORWARD);
                    return raven.R_TRUE;
                },
                raven.R_KEY_F5 => {
                    _ = rvn_fb_load(widget);
                    return raven.R_TRUE;
                },
                raven.R_KEY_H => {
                    if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL))) == 0) return raven.R_FALSE;
                    browser.*.show_hidden = @intFromBool(browser.*.show_hidden == 0);
                    _ = rvn_fb_load(widget);
                    return raven.R_TRUE;
                },
                raven.R_KEY_A => {
                    if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL))) == 0 or browser.*.multiple == 0) return raven.R_FALSE;
                    row = 0;
                    while (row < count) : (row += 1) {
                        browser.*.selected[@intCast(row)] = @intFromBool(browser.*.entries[@intCast(row)].is_dir == 0);
                    }
                    rvn_fb_notify_selection(widget);
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
            if (count > 0) rvn_fb_select_row(widget, base.rvn_clampi(row, 0, count - 1), raven.R_FALSE,
                @intFromBool((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_SHIFT))) != 0));
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_fb_set_mode(widget: [*c]widget_h.rvn_widget_t, mode: raven.RFileBrowserMode) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.mode == mode) return;
    browser.*.mode = mode;
    const placeholder: [*c]const u8 = if (mode == raven.R_FILE_BROWSER_FOLDER) "Folder" else "File name";
    _ = ext.rvn_widget_set_attribute(browser.*.name_input, "Placeholder", placeholder);
    _ = rvn_fb_load(widget);
    rvn_fb_sync_fields(widget);
}

fn rvn_fb_set_filters(widget: [*c]widget_h.rvn_widget_t, filters: [*c]const raven.RFileFilter, count: c_int) void {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var i: c_int = 0;
    while (i < browser.*.filter_count) : (i += 1) {
        base.rvn_free(browser.*.filter_names[@intCast(i)]);
        base.rvn_free(browser.*.filter_patterns[@intCast(i)]);
    }
    base.rvn_free(@ptrCast(browser.*.filter_names));
    base.rvn_free(@ptrCast(browser.*.filter_patterns));
    browser.*.filter_names = null;
    browser.*.filter_patterns = null;
    browser.*.filter_count = 0;
    browser.*.filter_index = 0;
    browser.*.updating += 1;
    raven.Rcombo_box_clear_items(browser.*.filter_combo.*.id);
    if (filters != null and count > 0) {
        browser.*.filter_names = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf([*c]u8) * @as(usize, @intCast(count)))));
        browser.*.filter_patterns = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf([*c]u8) * @as(usize, @intCast(count)))));
        i = 0;
        while (i < count) : (i += 1) {
            var label: [256]u8 = undefined;
            const filter = filters[@intCast(i)];
            const patterns: [*c]const u8 = if (filter.patterns != null) filter.patterns else "*";
            browser.*.filter_patterns[@intCast(i)] = base.rvn_strdup(patterns);
            // "Images (*.png;*.jpg)"
            if (filter.name != null and filter.name[0] != 0) {
                _ = libc.snprintf(&label, label.len, "%.120s (%.100s)", filter.name, patterns);
            } else {
                _ = libc.snprintf(&label, label.len, "%.200s", patterns);
            }
            browser.*.filter_names[@intCast(i)] = base.rvn_strdup(&label);
            _ = raven.Rcombo_box_add_item(browser.*.filter_combo.*.id, &label);
        }
        browser.*.filter_count = count;
        raven.Rcombo_box_set_selected(browser.*.filter_combo.*.id, 0);
    }
    browser.*.updating -= 1;
    _ = rvn_fb_load(widget);
    rvn_fb_sync_fields(widget);
}

fn rvn_file_browser_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Directory") == 0 or base.rvn_stricmp(name, "Path") == 0) {
        rvn_fb_navigate(widget, value, raven.R_TRUE);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Mode") == 0) {
        if (base.rvn_stricmp(value, "Open") == 0) {
            rvn_fb_set_mode(widget, raven.R_FILE_BROWSER_OPEN);
        } else if (base.rvn_stricmp(value, "Save") == 0) {
            rvn_fb_set_mode(widget, raven.R_FILE_BROWSER_SAVE);
        } else if (base.rvn_stricmp(value, "Folder") == 0) {
            rvn_fb_set_mode(widget, raven.R_FILE_BROWSER_FOLDER);
        } else {
            return raven.R_FALSE;
        }
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "Filter") == 0) {
        const filter = raven.RFileFilter{ .name = null, .patterns = value };
        const has_value = value[0] != 0;
        rvn_fb_set_filters(widget, if (has_value) &filter else null, if (has_value) 1 else 0);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "FileName") == 0) {
        rvn_fb_set_field(browser, browser.*.name_input, value);
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(name, "DefaultExtension") == 0) {
        _ = base.rvn_str_set(&browser.*.default_extension, value);
        return raven.R_TRUE;
    }
    if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
    if (base.rvn_stricmp(name, "ShowHidden") == 0) {
        browser.*.show_hidden = flag;
        _ = rvn_fb_load(widget);
    } else if (base.rvn_stricmp(name, "Multiple") == 0) {
        browser.*.multiple = flag;
    } else if (base.rvn_stricmp(name, "Controls") == 0) {
        browser.*.controls_hidden = @intFromBool(flag == 0);
        rvn_fb_sync_fields(widget);
    } else if (base.rvn_stricmp(name, "Places") == 0) {
        browser.*.places_hidden = @intFromBool(flag == 0);
        rvn_fb_sync_fields(widget);
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export const rvn_class_file_browser: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_FILE_BROWSER,
    .name = "FileBrowser",
    .size = @sizeOf(rvn_file_browser_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_SURFACE,
    .init = rvn_file_browser_init,
    .destroy = rvn_file_browser_destroy,
    .measure = rvn_file_browser_measure,
    .arrange = rvn_file_browser_arrange,
    .paint = rvn_file_browser_paint,
    .event = rvn_file_browser_event,
    .set_attribute = rvn_file_browser_set_attribute,
    .child_active = rvn_file_browser_child_active,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rfile_browser_create() raven.Rid {
    if (ctx_h.rvn_api_check("Rfile_browser_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_FILE_BROWSER);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rfile_browser_set_mode(id: raven.Rid, mode: raven.RFileBrowserMode) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_mode");
    if (widget == null) return;
    if (mode < raven.R_FILE_BROWSER_OPEN or mode > raven.R_FILE_BROWSER_FOLDER) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rfile_browser_set_mode: invalid mode");
        return;
    }
    rvn_fb_set_mode(widget, mode);
}

export fn Rfile_browser_set_directory(id: raven.Rid, path: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_directory");
    if (widget == null) return raven.R_FALSE;
    if (path == null) return raven.R_FALSE;
    const absolute = ext.rvn_path_absolute(path);
    const ok: c_int = @intFromBool(absolute != null and ext.rvn_path_exists(absolute) != 0);
    base.rvn_free(absolute);
    if (ok != 0) rvn_fb_navigate(widget, path, raven.R_TRUE);
    return ok;
}

export fn Rfile_browser_get_directory(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_get_directory");
    if (widget == null) return "";
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (browser.*.directory != null) return browser.*.directory;
    return "";
}

export fn Rfile_browser_refresh(id: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_refresh");
    if (widget == null) return;
    _ = rvn_fb_load(widget);
}

export fn Rfile_browser_set_filters(id: raven.Rid, filters: [*c]const raven.RFileFilter, count: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_filters");
    if (widget == null) return;
    rvn_fb_set_filters(widget, filters, count);
}

export fn Rfile_browser_set_show_hidden(id: raven.Rid, show: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_show_hidden");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.show_hidden = @intFromBool(show != 0);
    _ = rvn_fb_load(widget);
}

export fn Rfile_browser_set_multiple(id: raven.Rid, multiple: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_multiple");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.multiple = @intFromBool(multiple != 0);
}

export fn Rfile_browser_set_controls_visible(id: raven.Rid, visible: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_controls_visible");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.controls_hidden = @intFromBool(visible == 0);
    rvn_fb_sync_fields(widget);
}

export fn Rfile_browser_set_places_visible(id: raven.Rid, visible: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_places_visible");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.places_hidden = @intFromBool(visible == 0);
    rvn_fb_sync_fields(widget);
}

export fn Rfile_browser_set_file_name(id: raven.Rid, name: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_file_name");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    rvn_fb_set_field(browser, browser.*.name_input, name);
}

export fn Rfile_browser_set_default_extension(id: raven.Rid, extension: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_default_extension");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    _ = base.rvn_str_set(&browser.*.default_extension, extension);
}

fn rvn_fb_build_selection(browser: [*c]rvn_file_browser_t) void {
    var i: u32 = 0;
    var count: u32 = 0;
    if (browser.*.selection_paths != null) return;
    while (i < browser.*.entry_count) : (i += 1) count += browser.*.selected[i];
    browser.*.selection_paths = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf([*c]u8) * (if (count != 0) count else 1))));
    i = 0;
    while (i < browser.*.entry_count) : (i += 1) {
        if (browser.*.selected[i] != 0) {
            browser.*.selection_paths[browser.*.selection_count] = rvn_fb_entry_path(browser, @intCast(i));
            browser.*.selection_count += 1;
        }
    }
}

export fn Rfile_browser_get_selection_count(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_get_selection_count");
    if (widget == null) return 0;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    rvn_fb_build_selection(browser);
    return @intCast(browser.*.selection_count);
}

export fn Rfile_browser_get_selection(id: raven.Rid, index: c_int) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_get_selection");
    if (widget == null) return null;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    rvn_fb_build_selection(browser);
    if (index < 0 or index >= @as(c_int, @intCast(browser.*.selection_count))) return null;
    return browser.*.selection_paths[@intCast(index)];
}

export fn Rfile_browser_select(id: raven.Rid, name: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_select");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    if (name == null) return;
    var i: u32 = 0;
    while (i < browser.*.entry_count) : (i += 1) {
        if (libc.strcmp(browser.*.entries[i].name, name) == 0) {
            rvn_fb_select_row(widget, @intCast(i), raven.R_FALSE, raven.R_FALSE);
            return;
        }
    }
}

export fn Rfile_browser_set_accepted_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_accepted_callback");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.accepted = callback;
    browser.*.accepted_user = user_data;
}

export fn Rfile_browser_set_cancelled_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_cancelled_callback");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.cancelled = callback;
    browser.*.cancelled_user = user_data;
}

export fn Rfile_browser_set_selection_changed_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_FILE_BROWSER, "Rfile_browser_set_selection_changed_callback");
    if (widget == null) return;
    const browser: [*c]rvn_file_browser_t = @ptrCast(widget);
    browser.*.selection_changed = callback;
    browser.*.selection_user = user_data;
}
