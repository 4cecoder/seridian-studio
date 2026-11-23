// Translated to Zig from vendor/raven/tools/designer/strings.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - strings.c
// The Translations panel: a CSV table of the project as a grid, one row per
// key, one column per language. A cell left empty is marked (the fallback
// language shows instead). Changes show in the preview while typing; the
// language of the preview is chosen above it, right to left included.

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

extern "c" fn strpbrk(s: [*c]const u8, accept: [*c]const u8) [*c]u8;

const MAX_COLUMNS = 32;
const MAX_SHOWN = 600;

const row_t = extern struct {
    /// cells[0] is the key
    cells: [MAX_COLUMNS][*c]u8,
    /// a line starting with #: kept as it is in cells[0]
    comment: c_int,
};

const table_t = extern struct {
    path: [*c]u8,
    columns: c_int,
    headers: [MAX_COLUMNS][*c]u8,
    rows: [*c]row_t,
    row_count: c_int,
    modified: c_int,
};

// (the anonymous struct of g_s in the C)
const strings_state_t = extern struct {
    panel: raven.Rid,
    grid: raven.Rid,
    file_combo: raven.Rid,
    filter: raven.Rid,
    new_language: raven.Rid,
    language_combo: raven.Rid,
    refresh_timer: raven.Rid,
    tables: [*c]table_t,
    table_count: c_int,
    current: c_int,
    syncing: c_int,
    keys: [*c][*c]u8,
    key_count: c_int,
    language: [64]u8,
};

var g_s: strings_state_t = std.mem.zeroes(strings_state_t);

// ---------------------------------------------------------------------------
//  CSV
// -------------------------------------------------------------------------

/// One record: the fields, as CSV quotes them. Returns the start of the next record.
fn read_record(p_: [*c]const u8, fields: [*c][*c]u8, max: c_int, count: [*c]c_int) [*c]const u8 {
    var p = p_;
    var field = std.mem.zeroes(ide.ide_buffer_t);
    count.* = 0;
    while (true) {
        field.size = 0;
        if (field.data != null) field.data[0] = 0;
        if (p.* == '"') {
            p += 1;
            while (true) {
                if (p.* == 0) break;
                if (p.* == '"') {
                    if (p[1] == '"') {
                        ide.ide_buffer_add(&field, "\"", 1);
                        p += 2;
                        continue;
                    }
                    p += 1;
                    break;
                }
                ide.ide_buffer_add(&field, p, 1);
                p += 1;
            }
            while (p.* != 0 and p.* != ',' and p.* != '\n' and p.* != '\r') p += 1;
        } else {
            const start = p;
            while (p.* != 0 and p.* != ',' and p.* != '\n' and p.* != '\r') p += 1;
            ide.ide_buffer_add(&field, start, @intCast(p - start));
        }
        if (count.* < max) {
            fields[@intCast(count.*)] = ide.ide_strdup(if (field.data != null) field.data else "");
            count.* += 1;
        }
        if (p.* == ',') {
            p += 1;
            continue;
        }
        if (p.* == '\r') p += 1;
        if (p.* == '\n') p += 1;
        break;
    }
    ide.ide_buffer_free(&field);
    return p;
}

fn free_table(t: [*c]table_t) void {
    var i: c_int = undefined;
    var j: c_int = undefined;
    libc.free(t.*.path);
    i = 0;
    while (i < t.*.columns) : (i += 1) libc.free(t.*.headers[@intCast(i)]);
    i = 0;
    while (i < t.*.row_count) : (i += 1) {
        j = 0;
        while (j < MAX_COLUMNS) : (j += 1) libc.free(t.*.rows[@intCast(i)].cells[@intCast(j)]);
    }
    libc.free(t.*.rows);
    t.* = std.mem.zeroes(table_t);
}

fn load_table(t: [*c]table_t, path: [*c]const u8) c_int {
    var size: usize = 0;
    const text = raven.Rfile_read(path, &size);
    var p: [*c]const u8 = undefined;
    t.* = std.mem.zeroes(table_t);
    if (text == null) return raven.R_FALSE;
    t.*.path = ide.ide_strdup(path);
    p = text;
    if (p[0] == 0xEF and p[1] == 0xBB and p[2] == 0xBF) p += 3;
    // the first record names the columns
    while (p.* == '#' or p.* == '\n' or p.* == '\r') {
        while (p.* != 0 and p.* != '\n') p += 1;
        if (p.* != 0) p += 1;
    }
    if (p.* != 0) p = read_record(p, &t.*.headers, MAX_COLUMNS, &t.*.columns);
    while (p.* != 0) {
        var row: row_t = undefined;
        var count: c_int = 0;
        var i: c_int = undefined;
        row = std.mem.zeroes(row_t);
        if (p.* == '\n' or p.* == '\r') {
            p += 1;
            continue;
        }
        if (p.* == '#') {
            var end = p;
            while (end.* != 0 and end.* != '\n' and end.* != '\r') end += 1;
            row.cells[0] = @ptrCast(libc.malloc(@as(usize, @intCast(end - p)) + 1));
            @memcpy(row.cells[0][0..@intCast(end - p)], p[0..@intCast(end - p)]);
            row.cells[0][@intCast(end - p)] = 0;
            row.comment = 1;
            p = end;
        } else {
            p = read_record(p, &row.cells, MAX_COLUMNS, &count);
        }
        i = 0;
        while (i < t.*.columns) : (i += 1) {
            if (row.cells[@intCast(i)] == null) row.cells[@intCast(i)] = ide.ide_strdup("");
        }
        t.*.rows = @ptrCast(@alignCast(libc.realloc(t.*.rows, @sizeOf(row_t) * @as(usize, @intCast(t.*.row_count + 1)))));
        t.*.rows[@intCast(t.*.row_count)] = row;
        t.*.row_count += 1;
    }
    raven.Rmemory_free(text);
    if (t.*.columns == 0) {
        t.*.headers[0] = ide.ide_strdup("key");
        t.*.headers[1] = ide.ide_strdup("en");
        t.*.columns = 2;
    }
    return raven.R_TRUE;
}

fn write_field(out: [*c]ide.ide_buffer_t, text: [*c]const u8) void {
    var p: [*c]const u8 = undefined;
    const quote: c_int = @intFromBool(strpbrk(text, ",\"\n\r") != null or (text[0] == ' ') or (text[0] != 0 and text[libc.strlen(text) - 1] == ' ') or text[0] == '#');
    if (quote == 0) {
        ide.ide_buffer_add(out, text, libc.strlen(text));
        return;
    }
    ide.ide_buffer_add(out, "\"", 1);
    p = text;
    while (p.* != 0) : (p += 1) {
        if (p.* == '"') ide.ide_buffer_add(out, "\"\"", 2) else ide.ide_buffer_add(out, p, 1);
    }
    ide.ide_buffer_add(out, "\"", 1);
}

fn save_table(t: [*c]table_t) c_int {
    var out = std.mem.zeroes(ide.ide_buffer_t);
    var i: c_int = undefined;
    var j: c_int = undefined;
    var ok: c_int = undefined;
    i = 0;
    while (i < t.*.columns) : (i += 1) {
        if (i != 0) ide.ide_buffer_add(&out, ",", 1);
        write_field(&out, t.*.headers[@intCast(i)]);
    }
    ide.ide_buffer_add(&out, "\n", 1);
    i = 0;
    while (i < t.*.row_count) : (i += 1) {
        if (t.*.rows[@intCast(i)].comment != 0) {
            ide.ide_buffer_add(&out, t.*.rows[@intCast(i)].cells[0], libc.strlen(t.*.rows[@intCast(i)].cells[0]));
        } else {
            j = 0;
            while (j < t.*.columns) : (j += 1) {
                if (j != 0) ide.ide_buffer_add(&out, ",", 1);
                write_field(&out, if (t.*.rows[@intCast(i)].cells[@intCast(j)] != null) t.*.rows[@intCast(i)].cells[@intCast(j)] else "");
            }
        }
        ide.ide_buffer_add(&out, "\n", 1);
    }
    ok = raven.Rfile_write(t.*.path, out.data, out.size);
    ide.ide_buffer_free(&out);
    if (ok != 0) t.*.modified = 0;
    return ok;
}

// ---------------------------------------------------------------------------
//  The grid
// -------------------------------------------------------------------------

fn current() [*c]table_t {
    return if (g_s.current >= 0 and g_s.current < g_s.table_count) &g_s.tables[@intCast(g_s.current)] else null;
}

fn update_title() void {
    const t = current();
    var title: [300]u8 = undefined;
    _ = libc.snprintf(&title, title.len, "Translations%s%s%s", @as([*c]const u8, if (t != null) " - " else ""), @as([*c]const u8, if (t != null) ide.ide_basename(t.*.path) else ""), @as([*c]const u8, if (t != null and t.*.modified != 0) " *" else ""));
    raven.Rdock_area_set_panel_title(ide.g_ide_dock, g_s.panel, &title);
}

fn mark_cell(input: raven.Rid, missing: c_int) void {
    if (missing != 0) {
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
        var a: f32 = undefined;
        raven.Rtheme_get_color(raven.R_COLOR_DANGER, &r, &g, &b, &a);
        raven.Rwidget_set_color(input, raven.R_COLOR_CONTROL_BORDER, r, g, b, 0.9);
        raven.Rwidget_set_color(input, raven.R_COLOR_INPUT, r, g, b, 0.12);
        raven.Rwidget_set_tooltip(input, "Missing: the program shows the text of the first language");
    } else {
        raven.Rwidget_clear_color(input, raven.R_COLOR_CONTROL_BORDER);
        raven.Rwidget_clear_color(input, raven.R_COLOR_INPUT);
        raven.Rwidget_set_tooltip(input, "");
    }
}

fn on_refresh_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    g_s.refresh_timer = raven.R_INVALID_ID;
    ide.designer_refresh_preview();
}

fn schedule_refresh() void {
    if (g_s.refresh_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_s.refresh_timer) != 0) raven.Rtimer_destroy(g_s.refresh_timer);
    g_s.refresh_timer = raven.Rtimer_create(0.35, raven.R_FALSE, on_refresh_timer, null);
}

// (static void collect_keys(void); : a forward declaration in the C)

/// user_data: row * MAX_COLUMNS + column
fn on_cell(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const t = current();
    const code: c_int = @bitCast(@as(c_uint, @truncate(@intFromPtr(user_data))));
    const row: c_int = @divTrunc(code, MAX_COLUMNS);
    const column: c_int = @rem(code, MAX_COLUMNS);
    if (g_s.syncing != 0 or t == null or row >= t.*.row_count or column >= t.*.columns) return;
    libc.free(t.*.rows[@intCast(row)].cells[@intCast(column)]);
    t.*.rows[@intCast(row)].cells[@intCast(column)] = ide.ide_strdup(text);
    if (column > 0) {
        mark_cell(input, @intFromBool(text[0] == 0 and column > 1));
        // the preview shows it at once
        raven.Rlocale_set_text(t.*.headers[@intCast(column)], t.*.rows[@intCast(row)].cells[0], text);
        schedule_refresh();
    } else {
        collect_keys();
    }
    if (t.*.modified == 0) {
        t.*.modified = 1;
        update_title();
    }
}

// (static void rebuild_grid(void); : a forward declaration in the C)

fn on_delete_row(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const t = current();
    const row: c_int = @bitCast(@as(c_uint, @truncate(@intFromPtr(user_data))));
    var j: c_int = undefined;
    _ = button;
    if (t == null or row >= t.*.row_count) return;
    j = 0;
    while (j < MAX_COLUMNS) : (j += 1) libc.free(t.*.rows[@intCast(row)].cells[@intCast(j)]);
    _ = libc.memmove(&t.*.rows[@intCast(row)], &t.*.rows[@intCast(row + 1)], @sizeOf(row_t) * @as(usize, @intCast(t.*.row_count - row - 1)));
    t.*.row_count -= 1;
    t.*.modified = 1;
    update_title();
    collect_keys();
    rebuild_grid();
}

fn matches(row: [*c]const row_t, columns: c_int, filter: [*c]const u8) c_int {
    var i: c_int = undefined;
    if (filter[0] == 0) return 1;
    i = 0;
    while (i < columns) : (i += 1) {
        const cell: [*c]const u8 = row.*.cells[@intCast(i)];
        const n: usize = libc.strlen(filter);
        var k: usize = undefined;
        if (cell == null) continue;
        k = 0;
        while (cell[k] != 0) : (k += 1) {
            var m: usize = 0;
            while (m < n and cell[k + m] != 0 and std.ascii.toLower(cell[k + m]) == std.ascii.toLower(filter[m])) : (m += 1) {}
            if (m == n) return 1;
        }
    }
    return 0;
}

fn rebuild_grid() void {
    const t = current();
    const filter = raven.Rtext_input_get_text(g_s.filter);
    var header: raven.Rid = undefined;
    var i: c_int = undefined;
    var j: c_int = undefined;
    var shown: c_int = 0;
    g_s.syncing += 1;
    raven.Rwidget_clear_children(g_s.grid);
    if (t == null) {
        _ = raven.Rwidget_add_child(g_s.grid, raven.Rlabel_create(if (ide.g_project_dir != null) "The project has no .csv table: Add table creates strings.csv." else "Open a project to edit its translations."));
        g_s.syncing -= 1;
        update_title();
        return;
    }
    header = raven.Rwidget_create(raven.R_WIDGET_HBOX);
    raven.Rpanel_set_spacing(header, 6.0);
    j = 0;
    while (j < t.*.columns) : (j += 1) {
        const label = raven.Rlabel_create(if (j == 0) "Key" else t.*.headers[@intCast(j)]);
        _ = raven.Rwidget_set_attribute(label, "TextSize", "13");
        if (j == 0) raven.Rwidget_set_size(label, 220.0, -1.0) else raven.Rslot_set_fill(label, 1.0);
        _ = raven.Rwidget_add_child(header, label);
    }
    {
        const spacer = raven.Rwidget_create(raven.R_WIDGET_SPACER);
        raven.Rwidget_set_size(spacer, 28.0, 1.0);
        _ = raven.Rwidget_add_child(header, spacer);
    }
    _ = raven.Rwidget_add_child(g_s.grid, header);
    i = 0;
    while (i < t.*.row_count and shown < MAX_SHOWN) : (i += 1) {
        var line: raven.Rid = undefined;
        var remove: raven.Rid = undefined;
        if (t.*.rows[@intCast(i)].comment != 0 or matches(&t.*.rows[@intCast(i)], t.*.columns, filter) == 0) continue;
        line = raven.Rwidget_create(raven.R_WIDGET_HBOX);
        raven.Rpanel_set_spacing(line, 6.0);
        j = 0;
        while (j < t.*.columns) : (j += 1) {
            const input = raven.Rwidget_create(raven.R_WIDGET_TEXT_INPUT);
            raven.Rtext_input_set_text(input, if (t.*.rows[@intCast(i)].cells[@intCast(j)] != null) t.*.rows[@intCast(i)].cells[@intCast(j)] else "");
            if (j == 0) raven.Rwidget_set_size(input, 220.0, -1.0) else raven.Rslot_set_fill(input, 1.0);
            // the column of a right-to-left language is written from the right
            if (j > 0) {
                const code: [*c]const u8 = t.*.headers[@intCast(j)];
                if (libc.strncmp(code, "ar", 2) == 0 or libc.strncmp(code, "he", 2) == 0 or libc.strncmp(code, "fa", 2) == 0 or libc.strncmp(code, "ur", 2) == 0)
                    raven.Rwidget_set_direction(input, raven.R_DIRECTION_RTL);
            }
            if (j > 1) mark_cell(input, @intFromBool(!(t.*.rows[@intCast(i)].cells[@intCast(j)] != null and t.*.rows[@intCast(i)].cells[@intCast(j)][0] != 0)));
            raven.Rtext_input_set_changed_callback(input, on_cell, @ptrFromInt(@as(usize, @intCast(i * MAX_COLUMNS + j))));
            _ = raven.Rwidget_add_child(line, input);
        }
        remove = raven.Rwidget_create(raven.R_WIDGET_BUTTON);
        raven.Rbutton_set_text(remove, "x");
        _ = raven.Rwidget_set_attribute(remove, "Style", "Flat");
        raven.Rwidget_set_tooltip(remove, "Delete this key");
        raven.Rwidget_set_size(remove, 28.0, -1.0);
        raven.Rbutton_set_clicked_callback(remove, on_delete_row, @ptrFromInt(@as(usize, @intCast(i))));
        _ = raven.Rwidget_add_child(line, remove);
        _ = raven.Rwidget_add_child(g_s.grid, line);
        shown += 1;
    }
    if (shown == MAX_SHOWN) _ = raven.Rwidget_add_child(g_s.grid, raven.Rlabel_create("(more keys: type in the search box to find them)"));
    g_s.syncing -= 1;
    update_title();
}

// ---------------------------------------------------------------------------
//  Tables of the project
// -------------------------------------------------------------------------

fn collect_keys() void {
    var i: c_int = undefined;
    var j: c_int = undefined;
    i = 0;
    while (i < g_s.key_count) : (i += 1) libc.free(g_s.keys[@intCast(i)]);
    libc.free(@ptrCast(g_s.keys));
    g_s.keys = null;
    g_s.key_count = 0;
    i = 0;
    while (i < g_s.table_count) : (i += 1) {
        j = 0;
        while (j < g_s.tables[@intCast(i)].row_count) : (j += 1) {
            const row: [*c]const row_t = &g_s.tables[@intCast(i)].rows[@intCast(j)];
            if (row.*.comment != 0 or row.*.cells[0] == null or row.*.cells[0][0] == 0) continue;
            g_s.keys = @ptrCast(@alignCast(libc.realloc(@ptrCast(g_s.keys), @sizeOf([*c]u8) * @as(usize, @intCast(g_s.key_count + 1)))));
            g_s.keys[@intCast(g_s.key_count)] = ide.ide_strdup(row.*.cells[0]);
            g_s.key_count += 1;
        }
    }
}

export fn strings_key_count() c_int {
    return g_s.key_count;
}

export fn strings_key(index: c_int) [*c]const u8 {
    return if (index >= 0 and index < g_s.key_count) g_s.keys[@intCast(index)] else "";
}

fn find_tables(folder: [*c]const u8, depth: c_int) void {
    var entries: [*c]ide.ide_entry_t = undefined;
    const count = ide.ide_list_dir(folder, &entries);
    var i: c_int = undefined;
    i = 0;
    while (i < count) : (i += 1) {
        var full: [*c]u8 = undefined;
        if (entries[@intCast(i)].name[0] == '.' or ide.ide_iequal(&entries[@intCast(i)].name, "build") != 0 or libc.strncmp(&entries[@intCast(i)].name, "build-", 6) == 0) continue;
        full = ide.ide_join(folder, &entries[@intCast(i)].name);
        if (entries[@intCast(i)].is_dir != 0) {
            if (depth < 3) find_tables(full, depth + 1);
        } else if (ide.ide_iequal(ide.ide_extension(&entries[@intCast(i)].name), "csv") != 0) {
            var t: table_t = undefined;
            if (load_table(&t, full) != 0) {
                g_s.tables = @ptrCast(@alignCast(libc.realloc(g_s.tables, @sizeOf(table_t) * @as(usize, @intCast(g_s.table_count + 1)))));
                g_s.tables[@intCast(g_s.table_count)] = t;
                g_s.table_count += 1;
            }
        }
        libc.free(full);
    }
    libc.free(entries);
}

fn fill_language_combo() void {
    var i: c_int = undefined;
    const count = raven.Rlocale_get_language_count();
    var selected: c_int = 0;
    g_s.syncing += 1;
    raven.Rcombo_box_clear_items(g_s.language_combo);
    _ = raven.Rcombo_box_add_item(g_s.language_combo, "Language: first column");
    i = 0;
    while (i < count) : (i += 1) {
        const code = raven.Rlocale_get_language_at(i);
        var item: [96]u8 = undefined;
        _ = libc.snprintf(&item, item.len, "Language: %s", code);
        _ = raven.Rcombo_box_add_item(g_s.language_combo, &item);
        if (g_s.language[0] != 0 and libc.strcmp(code, &g_s.language) == 0) selected = i + 1;
    }
    raven.Rcombo_box_set_selected(g_s.language_combo, selected);
    g_s.syncing -= 1;
}

fn apply_language() void {
    if (g_s.language[0] != 0 and raven.Rlocale_set_language(&g_s.language) != 0) {
        raven.Rwidget_set_direction(ide.designer_get_frame(), if (raven.Rlocale_is_rtl() != 0) raven.R_DIRECTION_RTL else raven.R_DIRECTION_LTR);
    } else {
        if (raven.Rlocale_get_language_count() > 0) _ = raven.Rlocale_set_language(raven.Rlocale_get_language_at(0));
        raven.Rwidget_set_direction(ide.designer_get_frame(), if (raven.Rlocale_get_language_count() > 0 and raven.Rlocale_is_rtl() != 0) raven.R_DIRECTION_RTL else raven.R_DIRECTION_LTR);
    }
}

export fn strings_reload() void {
    var i: c_int = undefined;
    const previous_path: [*c]u8 = if (current() != null) ide.ide_strdup(current().*.path) else null;
    i = 0;
    while (i < g_s.table_count) : (i += 1) free_table(&g_s.tables[@intCast(i)]);
    libc.free(g_s.tables);
    g_s.tables = null;
    g_s.table_count = 0;
    g_s.current = -1;
    raven.Rlocale_clear();
    if (ide.g_project_dir != null) find_tables(ide.g_project_dir, 0);
    i = 0;
    while (i < g_s.table_count) : (i += 1) {
        _ = raven.Rlocale_load_csv(g_s.tables[@intCast(i)].path);
        if (previous_path != null and ide.ide_same_path(previous_path, g_s.tables[@intCast(i)].path) != 0) g_s.current = i;
    }
    libc.free(previous_path);
    if (g_s.current < 0 and g_s.table_count != 0) g_s.current = 0;
    g_s.syncing += 1;
    raven.Rcombo_box_clear_items(g_s.file_combo);
    i = 0;
    while (i < g_s.table_count) : (i += 1) _ = raven.Rcombo_box_add_item(g_s.file_combo, ide.ide_basename(g_s.tables[@intCast(i)].path));
    if (g_s.current >= 0) raven.Rcombo_box_set_selected(g_s.file_combo, g_s.current);
    g_s.syncing -= 1;
    collect_keys();
    fill_language_combo();
    apply_language();
    rebuild_grid();
    ide.designer_refresh_preview();
}

export fn strings_open(path: [*c]const u8) void {
    var i: c_int = 0;
    while (i < g_s.table_count) : (i += 1) {
        if (ide.ide_same_path(g_s.tables[@intCast(i)].path, path) != 0) {
            g_s.current = i;
            g_s.syncing += 1;
            raven.Rcombo_box_set_selected(g_s.file_combo, i);
            g_s.syncing -= 1;
            rebuild_grid();
            raven.Rdock_area_open_panel(ide.g_ide_dock, g_s.panel);
            return;
        }
    }
    // a table outside of the project: as text
    _ = ide.editors_open(path, 0);
}

export fn strings_any_modified() c_int {
    var i: c_int = 0;
    while (i < g_s.table_count) : (i += 1) {
        if (g_s.tables[@intCast(i)].modified != 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export fn strings_save() c_int {
    var i: c_int = undefined;
    var ok: c_int = raven.R_TRUE;
    i = 0;
    while (i < g_s.table_count) : (i += 1) {
        if (g_s.tables[@intCast(i)].modified != 0 and save_table(&g_s.tables[@intCast(i)]) == 0) {
            ide.ide_status("Cannot write %s", g_s.tables[@intCast(i)].path);
            ok = raven.R_FALSE;
        }
    }
    update_title();
    return ok;
}

// ---------------------------------------------------------------------------
//  Commands
// -------------------------------------------------------------------------

fn add_key() void {
    const t = current();
    var row: row_t = undefined;
    var key: [64]u8 = undefined;
    var n: c_int = 1;
    var i: c_int = undefined;
    var taken: c_int = undefined;
    if (t == null) return;
    while (true) {
        _ = libc.snprintf(&key, key.len, "new.key%d", n);
        n += 1;
        taken = 0;
        i = 0;
        while (i < t.*.row_count) : (i += 1) {
            if (t.*.rows[@intCast(i)].cells[0] != null and libc.strcmp(t.*.rows[@intCast(i)].cells[0], &key) == 0) taken = 1;
        }
        if (taken == 0) break;
    }
    row = std.mem.zeroes(row_t);
    row.cells[0] = ide.ide_strdup(&key);
    i = 1;
    while (i < t.*.columns) : (i += 1) row.cells[@intCast(i)] = ide.ide_strdup("");
    t.*.rows = @ptrCast(@alignCast(libc.realloc(t.*.rows, @sizeOf(row_t) * @as(usize, @intCast(t.*.row_count + 1)))));
    t.*.rows[@intCast(t.*.row_count)] = row;
    t.*.row_count += 1;
    t.*.modified = 1;
    raven.Rtext_input_set_text(g_s.filter, "");
    collect_keys();
    rebuild_grid();
    ide.ide_status("Key %s added: rename it in the first column.", @as([*c]const u8, &key));
}

fn add_language() void {
    const t = current();
    const code = raven.Rtext_input_get_text(g_s.new_language);
    var i: c_int = undefined;
    if (t == null) return;
    if (code[0] == 0 or libc.strchr(code, ',') != null or libc.strchr(code, '"') != null) {
        ide.ide_status("Type the code of the language first (fr, de, ar, pt-BR...).");
        return;
    }
    i = 0;
    while (i < t.*.columns) : (i += 1) {
        if (ide.ide_iequal(t.*.headers[@intCast(i)], code) != 0) {
            ide.ide_status("The table already has %s.", code);
            return;
        }
    }
    if (t.*.columns >= MAX_COLUMNS) return;
    t.*.headers[@intCast(t.*.columns)] = ide.ide_strdup(code);
    i = 0;
    while (i < t.*.row_count) : (i += 1) {
        if (t.*.rows[@intCast(i)].comment == 0) t.*.rows[@intCast(i)].cells[@intCast(t.*.columns)] = ide.ide_strdup("");
    }
    t.*.columns += 1;
    t.*.modified = 1;
    raven.Rtext_input_set_text(g_s.new_language, "");
    rebuild_grid();
    ide.ide_status("Language %s added: its empty cells are marked.", code);
}

fn add_table() void {
    var path: [*c]u8 = undefined;
    if (ide.g_project_dir == null) {
        ide.ide_status("Open a project first.");
        return;
    }
    path = ide.ide_join(ide.g_project_dir, "strings.csv");
    if (ide.ide_file_exists(path) == 0) _ = raven.Rfile_write(path, "key,en\n", 7);
    libc.free(path);
    strings_reload();
    ide.project_refresh_explorer();
}

fn action_strings(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (libc.strcmp(action, "strings.add_key") == 0) {
        add_key();
    } else if (libc.strcmp(action, "strings.add_language") == 0) {
        add_language();
    } else if (libc.strcmp(action, "strings.add_table") == 0) {
        add_table();
    } else if (libc.strcmp(action, "strings.save") == 0) {
        if (strings_save() != 0) {
            ide.ide_status("Translations saved.");
            strings_reload();
        }
    } else if (libc.strcmp(action, "strings.filter") == 0) {
        if (g_s.syncing == 0) rebuild_grid();
    } else if (libc.strcmp(action, "strings.reload") == 0) {
        strings_reload();
    }
}

fn on_file_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    if (g_s.syncing != 0 or index < 0 or index >= g_s.table_count) return;
    g_s.current = index;
    rebuild_grid();
}

fn on_language_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = user_data;
    if (g_s.syncing != 0) return;
    if (index <= 0) {
        g_s.language[0] = 0;
    } else {
        _ = libc.snprintf(&g_s.language, g_s.language.len, "%s", raven.Rlocale_get_language_at(index - 1));
    }
    apply_language();
    ide.designer_refresh_preview();
    ide.ide_status(if (g_s.language[0] != 0) "The preview is in %s%s." else "The preview is in the first language.", @as([*c]const u8, &g_s.language), @as([*c]const u8, if (g_s.language[0] != 0 and raven.Rlocale_is_rtl() != 0) ", right to left" else ""));
}

export fn strings_init() void {
    g_s.panel = raven.Rwidget_find(ide.g_ide_window, "panel.strings");
    g_s.grid = raven.Rwidget_find(ide.g_ide_window, "strings.grid");
    g_s.file_combo = raven.Rwidget_find(ide.g_ide_window, "strings.file");
    g_s.filter = raven.Rwidget_find(ide.g_ide_window, "strings.filter");
    g_s.new_language = raven.Rwidget_find(ide.g_ide_window, "strings.language");
    g_s.language_combo = raven.Rwidget_find(ide.g_ide_window, "preview.language");
    g_s.refresh_timer = raven.R_INVALID_ID;
    g_s.current = -1;
    raven.Rcombo_box_set_changed_callback(g_s.file_combo, on_file_changed, null);
    raven.Rcombo_box_set_changed_callback(g_s.language_combo, on_language_changed, null);
    raven.Raction_bind("strings.add_key", action_strings, null);
    raven.Raction_bind("strings.add_language", action_strings, null);
    raven.Raction_bind("strings.add_table", action_strings, null);
    raven.Raction_bind("strings.save", action_strings, null);
    raven.Raction_bind("strings.filter", action_strings, null);
    raven.Raction_bind("strings.reload", action_strings, null);
    fill_language_combo();
    rebuild_grid();
}

export fn strings_shutdown() void {
    var i: c_int = undefined;
    i = 0;
    while (i < g_s.table_count) : (i += 1) free_table(&g_s.tables[@intCast(i)]);
    libc.free(g_s.tables);
    i = 0;
    while (i < g_s.key_count) : (i += 1) libc.free(g_s.keys[@intCast(i)]);
    libc.free(@ptrCast(g_s.keys));
    g_s = std.mem.zeroes(strings_state_t);
}

export fn strings_set_preview_language(code: [*c]const u8) void {
    _ = libc.snprintf(&g_s.language, g_s.language.len, "%s", @as([*c]const u8, if (code != null) code else ""));
    fill_language_combo();
    apply_language();
    ide.designer_refresh_preview();
}

/// For the scripts of the tests: a cell by key and column.
export fn strings_set_cell(key: [*c]const u8, column: c_int, text: [*c]const u8) c_int {
    const t = current();
    var i: c_int = undefined;
    if (t == null or column <= 0 or column >= t.*.columns) return raven.R_FALSE;
    i = 0;
    while (i < t.*.row_count) : (i += 1) {
        if (t.*.rows[@intCast(i)].comment == 0 and t.*.rows[@intCast(i)].cells[0] != null and libc.strcmp(t.*.rows[@intCast(i)].cells[0], key) == 0) {
            libc.free(t.*.rows[@intCast(i)].cells[@intCast(column)]);
            t.*.rows[@intCast(i)].cells[@intCast(column)] = ide.ide_strdup(text);
            raven.Rlocale_set_text(t.*.headers[@intCast(column)], key, text);
            t.*.modified = 1;
            rebuild_grid();
            ide.designer_refresh_preview();
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}
