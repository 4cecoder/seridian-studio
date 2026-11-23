// Translated to Zig from vendor/raven/tools/designer/welcome.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - welcome.c
// The start page: what the IDE shows when nothing is open. New project, open
// a folder or a file, and the recent projects (the last opened first, with
// their language; a click opens one, the cross takes it out of the list).
//
// Also the preferences of the IDE, kept between two runs in ide_config_dir():
//   ide.ini               key=value (theme, the folder of new projects, the Raven package)
//   recent-projects.txt   one project per line: "<seconds since 1970>\t<folder>"

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

const Rid = raven.Rid;
const R_TRUE = raven.R_TRUE;
const R_FALSE = raven.R_FALSE;
const R_INVALID_ID = raven.R_INVALID_ID;

// (stdlib.h, time.h) time_t: 64 bits on Windows (mingw-w64, where std.c has none)
const time_t = if (builtin.os.tag == .windows) i64 else std.c.time_t;
extern "c" fn atof(s: [*c]const u8) f64;
extern "c" fn time(t: ?*time_t) time_t;
extern "c" fn localtime(t: *const time_t) ?*anyopaque; // struct tm*

const MAX_RECENT = 30;
const MAX_PREFS = 64;
const ROW_HEIGHT: f32 = 62.0;
const ROW_GAP: f32 = 4.0;

const recent_t = extern struct {
    path: [*c]u8,
    name: [*c]u8,
    /// "C", "Rust"... or "CMake", "Folder"
    language: [*c]const u8,
    /// seconds since 1970
    opened: f64,
    /// the folder is not there any more
    missing: c_int,
};

const g_w_t = extern struct {
    page: Rid,
    list: Rid,
    search: Rid,
    empty: Rid,
    back: Rid,
    package: Rid,
    recent: [MAX_RECENT]recent_t,
    count: c_int,
    /// the rows shown (the search filters them): indices into recent
    shown: [MAX_RECENT]c_int,
    shown_count: c_int,
    hovered: c_int,
    hovered_remove: c_int,
    selected: c_int,
    keys: [MAX_PREFS][*c]u8,
    values: [MAX_PREFS][*c]u8,
    pref_count: c_int,
    prefs_loaded: c_int,
};
var g_w: g_w_t = std.mem.zeroes(g_w_t);

// ---------------------------------------------------------------------------
//  Preferences
// ---------------------------------------------------------------------------

fn config_file(name: [*c]const u8) [*c]u8 {
    return ide.ide_join(ide.ide_config_dir(), name);
}

fn prefs_load() void {
    var size: usize = 0;
    if (g_w.prefs_loaded != 0) return;
    g_w.prefs_loaded = R_TRUE;
    const path = config_file("ide.ini");
    const text = raven.Rfile_read(path, &size);
    libc.free(path);
    if (text == null) return;
    {
        var line: [*c]u8 = text;
        while (line != null and line[0] != 0 and g_w.pref_count < MAX_PREFS) {
            const end: [*c]u8 = libc.strchr(line, '\n');
            if (end != null) end[0] = 0;
            if (end != null and end > line and (end - 1)[0] == '\r') (end - 1)[0] = 0;
            const equal: [*c]u8 = libc.strchr(line, '=');
            if (equal != null and equal > line) {
                equal[0] = 0;
                g_w.keys[@intCast(g_w.pref_count)] = ide.ide_strdup(line);
                g_w.values[@intCast(g_w.pref_count)] = ide.ide_strdup(equal + 1);
                g_w.pref_count += 1;
            }
            line = if (end != null) end + 1 else null;
        }
    }
    raven.Rmemory_free(text);
}

export fn prefs_get(key: [*c]const u8) [*c]const u8 {
    var i: c_int = 0;
    prefs_load();
    while (i < g_w.pref_count) : (i += 1) if (libc.strcmp(g_w.keys[@intCast(i)], key) == 0) return g_w.values[@intCast(i)];
    return "";
}

export fn prefs_set(key: [*c]const u8, value: [*c]const u8) void {
    var out = std.mem.zeroes(ide.ide_buffer_t);
    var i: c_int = 0;
    prefs_load();
    while (i < g_w.pref_count) : (i += 1) if (libc.strcmp(g_w.keys[@intCast(i)], key) == 0) break;
    if (i < g_w.pref_count) {
        if (libc.strcmp(g_w.values[@intCast(i)], if (value != null) value else "") == 0) return;
        libc.free(g_w.values[@intCast(i)]);
        g_w.values[@intCast(i)] = ide.ide_strdup(value);
    } else if (g_w.pref_count < MAX_PREFS) {
        g_w.keys[@intCast(g_w.pref_count)] = ide.ide_strdup(key);
        g_w.values[@intCast(g_w.pref_count)] = ide.ide_strdup(value);
        g_w.pref_count += 1;
    }
    i = 0;
    while (i < g_w.pref_count) : (i += 1) ide.ide_buffer_printf(&out, "%s=%s\n", g_w.keys[@intCast(i)], g_w.values[@intCast(i)]);
    const path = config_file("ide.ini");
    _ = raven.Rfile_write(path, @as([*c]const u8, if (out.data != null) out.data else ""), out.size);
    libc.free(path);
    ide.ide_buffer_free(&out);
}

// ---------------------------------------------------------------------------
//  Recent projects
// ---------------------------------------------------------------------------

/// What a project is written in: its interface file, else how it is built.
fn detect_language(folder: [*c]const u8) [*c]const u8 {
    const subfolders = [_][*c]const u8{ "", "src" };
    var f: c_int = 0;
    var i: c_int = 0;
    while (f < 2) : (f += 1) {
        i = 0;
        while (i < ide.ide_language_count()) : (i += 1) {
            var name: [80]u8 = undefined;
            _ = libc.snprintf(&name, name.len, "%s%smain.%s", subfolders[@intCast(f)], @as([*c]const u8, if (f != 0) "/" else ""), ide.ide_language_at(i).*.extension);
            const path = ide.ide_join(folder, &name);
            const found = ide.ide_file_exists(path);
            libc.free(path);
            if (found != 0) return ide.ide_language_at(i).*.name;
        }
    }
    // a native project: the file its tools read, or its program
    {
        const native_t = struct { file: [*c]const u8, language: [*c]const u8 };
        const natives = [_]native_t{
            .{ .file = "main.c", .language = "C" },      .{ .file = "main.cpp", .language = "C++" },   .{ .file = "Cargo.toml", .language = "Rust" }, .{ .file = "go.mod", .language = "Go" }, .{ .file = "Program.cs", .language = "C#" },
            .{ .file = "build.zig", .language = "Zig" }, .{ .file = "main.py", .language = "Python" }, .{ .file = "main.lua", .language = "Lua" },
        };
        i = 0;
        while (i < @as(c_int, natives.len)) : (i += 1) {
            const path = ide.ide_join(folder, natives[@intCast(i)].file);
            const found = ide.ide_file_exists(path);
            libc.free(path);
            if (found != 0) return natives[@intCast(i)].language;
        }
    }
    {
        const cmake = ide.ide_join(folder, "CMakeLists.txt");
        const found = ide.ide_file_exists(cmake);
        libc.free(cmake);
        if (found != 0) return "CMake";
    }
    return "Folder";
}

fn recent_free(r: [*c]recent_t) void {
    libc.free(r.*.path);
    libc.free(r.*.name);
    r.* = std.mem.zeroes(recent_t);
}

fn recent_fill(r: [*c]recent_t, path: [*c]const u8, opened: f64) void {
    r.*.path = ide.ide_normalize(path);
    {
        var n: usize = libc.strlen(r.*.path);
        while (n > 1 and r.*.path[n - 1] == '/') {
            n -= 1;
            r.*.path[n] = 0;
        }
    }
    r.*.name = ide.ide_strdup(ide.ide_basename(r.*.path));
    r.*.opened = opened;
    r.*.missing = @intFromBool(ide.ide_is_dir(r.*.path) == 0);
    r.*.language = if (r.*.missing != 0) "Folder" else detect_language(r.*.path);
}

fn recent_save() void {
    var out = std.mem.zeroes(ide.ide_buffer_t);
    const path = config_file("recent-projects.txt");
    var i: c_int = 0;
    while (i < g_w.count) : (i += 1) ide.ide_buffer_printf(&out, "%.0f\t%s\n", g_w.recent[@intCast(i)].opened, g_w.recent[@intCast(i)].path);
    _ = raven.Rfile_write(path, @as([*c]const u8, if (out.data != null) out.data else ""), out.size);
    libc.free(path);
    ide.ide_buffer_free(&out);
}

fn recent_load() void {
    const path = config_file("recent-projects.txt");
    var size: usize = 0;
    const text = raven.Rfile_read(path, &size);
    libc.free(path);
    if (text == null) return;
    {
        var line: [*c]u8 = text;
        while (line != null and line[0] != 0 and g_w.count < MAX_RECENT) {
            const end: [*c]u8 = libc.strchr(line, '\n');
            if (end != null) end[0] = 0;
            if (end != null and end > line and (end - 1)[0] == '\r') (end - 1)[0] = 0;
            const tab: [*c]u8 = libc.strchr(line, '\t');
            if (tab != null and tab[1] != 0) {
                var i: c_int = 0;
                var duplicate: c_int = 0;
                while (i < g_w.count) : (i += 1) if (ide.ide_same_path(g_w.recent[@intCast(i)].path, tab + 1) != 0) {
                    duplicate = 1;
                };
                if (duplicate == 0) {
                    const at = g_w.count;
                    g_w.count += 1;
                    recent_fill(&g_w.recent[@intCast(at)], tab + 1, atof(line));
                }
            }
            line = if (end != null) end + 1 else null;
        }
    }
    raven.Rmemory_free(text);
}

fn recent_find(folder: [*c]const u8) c_int {
    var i: c_int = 0;
    const normalized = ide.ide_normalize(folder);
    var n: usize = libc.strlen(normalized);
    while (n > 1 and normalized[n - 1] == '/') {
        n -= 1;
        normalized[n] = 0;
    }
    while (i < g_w.count) : (i += 1) {
        if (ide.ide_same_path(g_w.recent[@intCast(i)].path, normalized) != 0) break;
    }
    libc.free(normalized);
    return if (i < g_w.count) i else -1;
}

fn recent_remove_at(index: c_int) void {
    if (index < 0 or index >= g_w.count) return;
    const recent: [*c]recent_t = &g_w.recent;
    recent_free(recent + @as(usize, @intCast(index)));
    _ = libc.memmove(recent + @as(usize, @intCast(index)), recent + @as(usize, @intCast(index + 1)), @sizeOf(recent_t) * @as(usize, @intCast(g_w.count - index - 1)));
    g_w.count -= 1;
    g_w.recent[@intCast(g_w.count)] = std.mem.zeroes(recent_t);
    recent_save();
}

export fn recent_add(folder: [*c]const u8) void {
    var entry: recent_t = undefined;
    const at = recent_find(folder);
    if (at >= 0) recent_remove_at(at);
    if (g_w.count == MAX_RECENT) {
        g_w.count -= 1;
        recent_free(&g_w.recent[@intCast(g_w.count)]);
    }
    entry = std.mem.zeroes(recent_t);
    recent_fill(&entry, folder, @floatFromInt(time(null)));
    const recent: [*c]recent_t = &g_w.recent;
    _ = libc.memmove(recent + 1, recent, @sizeOf(recent_t) * @as(usize, @intCast(g_w.count)));
    g_w.recent[0] = entry;
    g_w.count += 1;
    recent_save();
    refresh_list();
}

// ---------------------------------------------------------------------------
//  The list
// ---------------------------------------------------------------------------

fn language_color(language: [*c]const u8, r: [*c]f32, gr: [*c]f32, b: [*c]f32) void {
    const color_t = struct { name: [*c]const u8, r: f32, g: f32, b: f32 };
    const colors = [_]color_t{
        .{ .name = "C", .r = 0.33, .g = 0.47, .b = 0.80 },     .{ .name = "C++", .r = 0.20, .g = 0.42, .b = 0.70 }, .{ .name = "Rust", .r = 0.80, .g = 0.42, .b = 0.24 }, .{ .name = "Python", .r = 0.22, .g = 0.55, .b = 0.75 },
        .{ .name = "Go", .r = 0.16, .g = 0.66, .b = 0.75 },    .{ .name = "C#", .r = 0.45, .g = 0.33, .b = 0.75 },  .{ .name = "Zig", .r = 0.93, .g = 0.62, .b = 0.15 },  .{ .name = "Lua", .r = 0.20, .g = 0.25, .b = 0.65 },
        .{ .name = "CMake", .r = 0.55, .g = 0.55, .b = 0.60 },
    };
    var i: usize = 0;
    while (i < colors.len) : (i += 1) {
        if (libc.strcmp(colors[i].name, language) == 0) {
            r.* = colors[i].r;
            gr.* = colors[i].g;
            b.* = colors[i].b;
            return;
        }
    }
    b.* = 0.5;
    gr.* = b.*;
    r.* = gr.*;
}

fn language_badge(language: [*c]const u8) [*c]const u8 {
    if (libc.strcmp(language, "Rust") == 0) return "Rs";
    if (libc.strcmp(language, "Python") == 0) return "Py";
    if (libc.strcmp(language, "Folder") == 0) return "...";
    if (libc.strcmp(language, "CMake") == 0) return "CM";
    return language;
}

fn time_ago(then: f64, out: [*c]u8, size: usize) void {
    const seconds: f64 = @as(f64, @floatFromInt(time(null))) - then;
    if (then <= 0.0) {
        _ = libc.snprintf(out, size, "%s", "");
        return;
    }
    if (seconds < 60.0) {
        _ = libc.snprintf(out, size, "just now");
    } else if (seconds < 3600.0) {
        _ = libc.snprintf(out, size, "%d min ago", @as(c_int, @intFromFloat(seconds / 60.0)));
    } else if (seconds < 86400.0) {
        _ = libc.snprintf(out, size, "%d h ago", @as(c_int, @intFromFloat(seconds / 3600.0)));
    } else if (seconds < 86400.0 * 2) {
        _ = libc.snprintf(out, size, "yesterday");
    } else if (seconds < 86400.0 * 31) {
        _ = libc.snprintf(out, size, "%d days ago", @as(c_int, @intFromFloat(seconds / 86400.0)));
    } else {
        const t: time_t = @intFromFloat(then);
        const tm = localtime(&t);
        if (tm != null) {
            _ = libc.strftime(out, size, "%d %b %Y", tm);
        } else out[0] = 0;
    }
}

/// The text cut on the left ("...ts/Raven Projects/demo") to fit a width.
fn fit_left(text: [*c]const u8, size: f32, width: f32, out: [*c]u8, out_size: usize) void {
    var w: f32 = 0.0;
    var h: f32 = 0.0;
    const length: usize = libc.strlen(text);
    var cut: usize = undefined;
    raven.Rfont_measure_text(R_INVALID_ID, size, text, &w, &h);
    if (w <= width) {
        _ = libc.snprintf(out, out_size, "%s", text);
        return;
    }
    cut = 1;
    while (cut < length) : (cut += 1) {
        // (not inside a character of several bytes)
        if ((text[cut] & 0xC0) == 0x80) continue;
        _ = libc.snprintf(out, out_size, "...%s", text + cut);
        raven.Rfont_measure_text(R_INVALID_ID, size, out, &w, &h);
        if (w <= width) return;
    }
    _ = libc.snprintf(out, out_size, "...");
}

fn matches(r: [*c]const recent_t, filter: [*c]const u8) c_int {
    const n: usize = libc.strlen(filter);
    var i: usize = undefined;
    var j: usize = undefined;
    var texts: [2][*c]const u8 = undefined;
    var t: c_int = 0;
    if (n == 0) return 1;
    texts[0] = r.*.name;
    texts[1] = r.*.path;
    while (t < 2) : (t += 1) {
        const text = texts[@intCast(t)];
        i = 0;
        while (text[i] != 0) : (i += 1) {
            j = 0;
            while (j < n and text[i + j] != 0) : (j += 1) if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(filter[j])) break;
            if (j == n) return 1;
        }
    }
    return 0;
}

fn refresh_list() void {
    var i: c_int = 0;
    if (g_w.list == R_INVALID_ID or raven.Rwidget_is_valid(g_w.list) == 0) return;
    const filter = raven.Rtext_input_get_text(g_w.search);
    g_w.shown_count = 0;
    while (i < g_w.count) : (i += 1) if (matches(&g_w.recent[@intCast(i)], filter) != 0) {
        g_w.shown[@intCast(g_w.shown_count)] = i;
        g_w.shown_count += 1;
    };
    if (g_w.selected >= g_w.shown_count) g_w.selected = g_w.shown_count - 1;
    g_w.hovered = -1;
    raven.Rwidget_set_size(g_w.list, -1.0, if (g_w.shown_count != 0) @as(f32, @floatFromInt(g_w.shown_count)) * (ROW_HEIGHT + ROW_GAP) else 1.0);
    raven.Rlabel_set_text(g_w.empty, @as([*c]const u8, if (g_w.count == 0) "No recent projects yet. Create one, or open a folder: it will be listed here." else if (g_w.shown_count == 0) "No recent project matches the search." else ""));
    raven.Rwidget_set_visibility(g_w.empty, if (g_w.shown_count == 0) @as(raven.RVisibility, raven.R_VISIBLE) else raven.R_COLLAPSED);
    raven.Rwidget_invalidate(g_w.list);
}

fn row_rect(row: c_int, width: f32, x: [*c]f32, y: [*c]f32, w: [*c]f32, h: [*c]f32) void {
    x.* = 0.0;
    y.* = @as(f32, @floatFromInt(row)) * (ROW_HEIGHT + ROW_GAP);
    w.* = width;
    h.* = ROW_HEIGHT;
}

/// The little cross that takes a project out of the list, at the right of a row.
fn remove_rect(width: f32, row_y: f32, x: [*c]f32, y: [*c]f32, size: [*c]f32) void {
    size.* = 26.0;
    x.* = width - 14.0 - size.*;
    y.* = row_y + (ROW_HEIGHT - size.*) * 0.5;
}

fn list_paint(widget: Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    var tr: f32 = undefined;
    var tg: f32 = undefined;
    var tb: f32 = undefined;
    var ta: f32 = undefined;
    var hr: f32 = undefined;
    var hg: f32 = undefined;
    var hb: f32 = undefined;
    var ha: f32 = undefined;
    var sr: f32 = undefined;
    var sg: f32 = undefined;
    var sb: f32 = undefined;
    var sa: f32 = undefined;
    var dr: f32 = undefined;
    var dg: f32 = undefined;
    var db: f32 = undefined;
    var da: f32 = undefined;
    const bold: Rid = raven.Rfont_get_variant(raven.Rfont_get_default(), raven.R_FONT_BOLD);
    var row: c_int = 0;
    _ = widget;
    _ = height;
    _ = user_data;
    raven.Rtheme_get_color(raven.R_COLOR_TEXT, &tr, &tg, &tb, &ta);
    raven.Rtheme_get_color(raven.R_COLOR_ROW_HOVERED, &hr, &hg, &hb, &ha);
    raven.Rtheme_get_color(raven.R_COLOR_SELECTION, &sr, &sg, &sb, &sa);
    raven.Rtheme_get_color(raven.R_COLOR_DANGER, &dr, &dg, &db, &da);
    while (row < g_w.shown_count) : (row += 1) {
        const r: [*c]const recent_t = &g_w.recent[@intCast(g_w.shown[@intCast(row)])];
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        var br: f32 = undefined;
        var bg: f32 = undefined;
        var bb: f32 = undefined;
        var tw: f32 = 0.0;
        var th: f32 = 0.0;
        var right: f32 = undefined;
        var text: [1200]u8 = undefined;
        var when: [64]u8 = undefined;
        const badge = language_badge(r.*.language);
        row_rect(row, width, &x, &y, &w, &h);
        if (row == g_w.hovered) {
            raven.Rdraw_rect(painter, x, y, w, h, 12.0, hr, hg, hb, ha);
        } else if (row == g_w.selected) raven.Rdraw_rect(painter, x, y, w, h, 12.0, sr, sg, sb, sa * 0.6);
        // the badge of the language
        language_color(r.*.language, &br, &bg, &bb);
        raven.Rdraw_rect(painter, x + 12.0, y + 11.0, 40.0, 40.0, 10.0, br, bg, bb, if (r.*.missing != 0) 0.35 else 1.0);
        raven.Rfont_measure_text(bold, 14.0, badge, &tw, &th);
        raven.Rdraw_text(painter, bold, 14.0, x + 32.0 - tw * 0.5, y + 31.0 - th * 0.5, badge, 1.0, 1.0, 1.0, 1.0);
        // the time, or the cross under the pointer
        right = w - 16.0;
        if (row == g_w.hovered) {
            var cx: f32 = undefined;
            var cy: f32 = undefined;
            var size: f32 = undefined;
            remove_rect(width, y, &cx, &cy, &size);
            if (g_w.hovered_remove != 0) raven.Rdraw_rect(painter, cx, cy, size, size, size * 0.5, tr, tg, tb, 0.12);
            raven.Rdraw_line(painter, cx + 9.0, cy + 9.0, cx + size - 9.0, cy + size - 9.0, 1.6, tr, tg, tb, 0.75);
            raven.Rdraw_line(painter, cx + size - 9.0, cy + 9.0, cx + 9.0, cy + size - 9.0, 1.6, tr, tg, tb, 0.75);
            right = cx - 10.0;
        } else {
            time_ago(r.*.opened, &when, when.len);
            raven.Rfont_measure_text(R_INVALID_ID, 12.0, &when, &tw, &th);
            raven.Rdraw_text(painter, R_INVALID_ID, 12.0, right - tw, y + 23.0, &when, tr, tg, tb, 0.5);
            right -= tw + 16.0;
        }
        // the name, and where it is
        const text_x: f32 = x + 66.0;
        fit_left(r.*.name, 15.0, right - text_x, &text, text.len);
        raven.Rdraw_text(painter, bold, 15.0, text_x, y + 12.0, &text, tr, tg, tb, if (r.*.missing != 0) 0.5 else 1.0);
        if (r.*.missing != 0) {
            fit_left("The folder is not there any more: the cross takes it out of the list", 12.0, right - text_x, &text, text.len);
            raven.Rdraw_text(painter, R_INVALID_ID, 12.0, text_x, y + 35.0, &text, dr, dg, db, 0.9);
        } else {
            var pretty: [1100]u8 = undefined;
            var line: [1200]u8 = undefined;
            ide.ide_pretty_path(r.*.path, &pretty, pretty.len);
            _ = libc.snprintf(&line, line.len, "%s  ·  %s", r.*.language, &pretty);
            fit_left(&line, 12.0, right - text_x, &text, text.len);
            raven.Rdraw_text(painter, R_INVALID_ID, 12.0, text_x, y + 35.0, &text, tr, tg, tb, 0.55);
        }
    }
}

fn row_at(y: f32) c_int {
    const row: c_int = @intFromFloat(y / (ROW_HEIGHT + ROW_GAP));
    if (y < 0.0 or row >= g_w.shown_count) return -1;
    if (y - @as(f32, @floatFromInt(row)) * (ROW_HEIGHT + ROW_GAP) > ROW_HEIGHT) return -1;
    return row;
}

fn open_row(row: c_int) void {
    if (row < 0 or row >= g_w.shown_count) return;
    const path = ide.ide_strdup(g_w.recent[@intCast(g_w.shown[@intCast(row)])].path);
    if (ide.ide_is_dir(path) == 0) {
        g_w.recent[@intCast(g_w.shown[@intCast(row)])].missing = R_TRUE;
        raven.Rwidget_invalidate(g_w.list);
        ide.ide_status("%s is not there any more.", path);
    } else {
        _ = ide.project_open(path);
    }
    libc.free(path);
}

fn list_event(widget: Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    var row: c_int = undefined;
    _ = user_data;
    raven.Rwidget_get_rect(widget, &x, &y, &w, &h);
    switch (event.*.type) {
        raven.R_EVENT_MOUSE_MOVE => {
            var on_remove: c_int = 0;
            row = row_at(event.*.local_y);
            if (row >= 0) {
                var cx: f32 = undefined;
                var cy: f32 = undefined;
                var size: f32 = undefined;
                remove_rect(w, @as(f32, @floatFromInt(row)) * (ROW_HEIGHT + ROW_GAP), &cx, &cy, &size);
                on_remove = @intFromBool(event.*.local_x >= cx and event.*.local_x <= cx + size and event.*.local_y >= cy and event.*.local_y <= cy + size);
            }
            if (row != g_w.hovered or on_remove != g_w.hovered_remove) {
                g_w.hovered = row;
                g_w.hovered_remove = on_remove;
                raven.Rwidget_invalidate(widget);
            }
            raven.Rwidget_set_cursor(widget, if (row >= 0) @as(raven.RCursor, raven.R_CURSOR_HAND) else raven.R_CURSOR_ARROW);
            return R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            g_w.hovered = -1;
            g_w.hovered_remove = 0;
            raven.Rwidget_invalidate(widget);
            return R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            raven.Rwidget_focus(widget);
            if (event.*.button != raven.R_MOUSE_LEFT) return R_TRUE;
            row = row_at(event.*.local_y);
            if (row < 0) return R_TRUE;
            g_w.selected = row;
            if (g_w.hovered_remove != 0 and row == g_w.hovered) {
                recent_remove_at(g_w.shown[@intCast(row)]);
                refresh_list();
            } else {
                open_row(row);
            }
            return R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if (event.*.key == raven.R_KEY_DOWN and g_w.shown_count != 0) {
                g_w.selected = if (g_w.selected + 1 < g_w.shown_count) g_w.selected + 1 else g_w.shown_count - 1;
            } else if (event.*.key == raven.R_KEY_UP and g_w.shown_count != 0) {
                g_w.selected = if (g_w.selected > 0) g_w.selected - 1 else 0;
            } else if (event.*.key == raven.R_KEY_ENTER) {
                open_row(g_w.selected);
            } else if (event.*.key == raven.R_KEY_DELETE and g_w.selected >= 0 and g_w.selected < g_w.shown_count) {
                recent_remove_at(g_w.shown[@intCast(g_w.selected)]);
                refresh_list();
            } else return R_FALSE;
            raven.Rwidget_invalidate(widget);
            return R_TRUE;
        },
        else => return R_FALSE,
    }
}

fn on_search(input: Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = text;
    _ = user_data;
    g_w.selected = 0;
    refresh_list();
}

/// Enter in the search box: the first project that matches.
fn on_search_committed(input: Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = text;
    _ = user_data;
    if (g_w.shown_count != 0) open_row(if (g_w.selected >= 0) g_w.selected else 0);
}

// ---------------------------------------------------------------------------
//  The page
// ---------------------------------------------------------------------------

const WELCOME_XML =
    "<ScrollBox Slot.Fill=\"1\">" ++
    "  <HBox Spacing=\"56\" Slot.Padding=\"64,48\">" ++
    "    <VBox Spacing=\"10\" Width=\"290\">" ++
    "      <Label Text=\"Raven IDE\" TextSize=\"34\"/>" ++
    "      <Label Name=\"welcome.version\" Opacity=\"0.55\"/>" ++
    "      <Spacer Height=\"22\"/>" ++
    "      <Button Text=\"New project...\" Style=\"Primary\" OnClicked=\"project.new\" Tooltip=\"In the language you choose: with a Raven interface, or native (Ctrl+Shift+N)\"/>" ++
    "      <Button Text=\"Open a folder...\" OnClicked=\"project.open\" Tooltip=\"A project folder (Ctrl+Shift+O)\"/>" ++
    "      <Button Text=\"Open a file...\" OnClicked=\"file.open\" Tooltip=\"An interface: .xml, .xmlc, .xmlrs... (Ctrl+O)\"/>" ++
    "      <Button Name=\"welcome.back\" Style=\"Flat\" OnClicked=\"welcome.back\" Visibility=\"Collapsed\"/>" ++
    "      <Spacer Height=\"22\"/>" ++
    "      <Label Text=\"Without a project\" Opacity=\"0.55\"/>" ++
    "      <Button Text=\"A new window\" Style=\"Flat\" OnClicked=\"file.new.window\" Slot.HAlign=\"Left\"/>" ++
    "      <Button Text=\"A form with its own tags\" Style=\"Flat\" OnClicked=\"file.new.form\" Slot.HAlign=\"Left\"/>" ++
    "      <Spacer Height=\"22\"/>" ++
    "      <Label Text=\"The Raven package\" Opacity=\"0.55\"/>" ++
    "      <Label Name=\"welcome.package\" Wrap=\"true\"/>" ++
    "      <Button Text=\"Choose the Raven package...\" Style=\"Flat\" OnClicked=\"welcome.package\" Slot.HAlign=\"Left\"" ++
    "        Tooltip=\"The folder with bin/, include/ and lib/: what the projects are built with\"/>" ++
    "    </VBox>" ++
    "    <VBox Spacing=\"14\" Slot.Fill=\"1\">" ++
    "      <HBox Spacing=\"12\">" ++
    "        <Label Text=\"Recent projects\" TextSize=\"20\" Slot.Fill=\"1\" Slot.VAlign=\"Center\"/>" ++
    "        <TextInput Name=\"welcome.search\" Placeholder=\"Search\" Width=\"240\"/>" ++
    "      </HBox>" ++
    "      <VBox Name=\"welcome.rows\"/>" ++
    "      <Label Name=\"welcome.empty\" Opacity=\"0.55\" Wrap=\"true\" Slot.Padding=\"4,8\"/>" ++
    "    </VBox>" ++
    "  </HBox>" ++
    "</ScrollBox>";

fn update_package() void {
    var text: [1200]u8 = undefined;
    var pretty: [1100]u8 = undefined;
    if (ide.g_settings.raven_prefix[0] != 0) {
        ide.ide_pretty_path(&ide.g_settings.raven_prefix, &pretty, pretty.len);
        _ = libc.snprintf(&text, text.len, "%s", &pretty);
        raven.Rlabel_set_text(g_w.package, &text);
        raven.Rwidget_set_opacity(g_w.package, 0.8);
    } else {
        raven.Rlabel_set_text(g_w.package, "Not found. C and C++ projects need it to build (Rust, Go, C#, Zig, Python and Lua need its bindings).");
        raven.Rwidget_set_opacity(g_w.package, 1.0);
    }
}

fn action_welcome(sender: Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (libc.strcmp(action, "welcome.back") == 0) {
        welcome_hide();
        ide.ide_status("Back to %s.", @as([*c]const u8, if (ide.g_project_dir != null) ide.ide_basename(ide.g_project_dir) else "the IDE"));
    } else if (libc.strcmp(action, "welcome.package") == 0) {
        var desc: raven.RFileDialogDesc = undefined;
        desc = std.mem.zeroes(raven.RFileDialogDesc);
        desc.parent = ide.g_ide_window;
        desc.title = "The folder of the Raven package (bin/, include/, lib/)";
        const chosen = raven.Rfile_dialog_select_folder(&desc);
        if (chosen != null) {
            _ = libc.snprintf(&ide.g_settings.raven_prefix, ide.g_settings.raven_prefix.len, "%s", chosen);
            prefs_set("raven_prefix", chosen);
            if (ide.g_project_dir != null) ide.project_save_settings();
            update_package();
        }
    }
}

export fn welcome_init() void {
    g_w.page = raven.Rwidget_find(ide.g_ide_window, "page.welcome");
    g_w.list = R_INVALID_ID;
    g_w.hovered = -1;
    g_w.selected = 0;
    recent_load();
    const content: Rid = raven.Rwidget_create_from_xml(WELCOME_XML, WELCOME_XML.len);
    if (content == R_INVALID_ID) return;
    raven.Rslot_set_fill(content, 1.0);
    _ = raven.Rwidget_add_child(g_w.page, content);
    g_w.search = raven.Rwidget_find(content, "welcome.search");
    g_w.empty = raven.Rwidget_find(content, "welcome.empty");
    g_w.back = raven.Rwidget_find(content, "welcome.back");
    g_w.package = raven.Rwidget_find(content, "welcome.package");
    {
        var version: [96]u8 = undefined;
        _ = libc.snprintf(&version, version.len, "Version %s", raven.Rget_version());
        raven.Rlabel_set_text(raven.Rwidget_find(content, "welcome.version"), &version);
    }
    const rows: Rid = raven.Rwidget_find(content, "welcome.rows");
    g_w.list = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rcustom_set_paint_callback(g_w.list, &list_paint, null);
    raven.Rwidget_set_event_callback(g_w.list, &list_event, null);
    raven.Rwidget_set_focusable(g_w.list, R_TRUE);
    _ = raven.Rwidget_add_child(rows, g_w.list);
    raven.Rtext_input_set_changed_callback(g_w.search, &on_search, null);
    raven.Rtext_input_set_committed_callback(g_w.search, &on_search_committed, null);
    raven.Raction_bind("welcome.back", &action_welcome, null);
    raven.Raction_bind("welcome.package", &action_welcome, null);
    refresh_list();
    update_package();
}

export fn welcome_shutdown() void {
    var i: c_int = 0;
    while (i < g_w.count) : (i += 1) recent_free(&g_w.recent[@intCast(i)]);
    g_w.count = 0;
    i = 0;
    while (i < g_w.pref_count) : (i += 1) {
        libc.free(g_w.keys[@intCast(i)]);
        libc.free(g_w.values[@intCast(i)]);
    }
    g_w.pref_count = 0;
}

export fn welcome_show() void {
    const pages: Rid = raven.Rwidget_find(ide.g_ide_window, "pages");
    var i: c_int = 0;
    // folders may have come or gone since
    while (i < g_w.count) : (i += 1) {
        g_w.recent[@intCast(i)].missing = @intFromBool(ide.ide_is_dir(g_w.recent[@intCast(i)].path) == 0);
        if (g_w.recent[@intCast(i)].missing == 0) g_w.recent[@intCast(i)].language = detect_language(g_w.recent[@intCast(i)].path);
    }
    raven.Rswitcher_set_index(pages, 0);
    raven.Rwidget_set_visibility(raven.Rwidget_find(ide.g_ide_window, "header.build"), raven.R_COLLAPSED);
    if (ide.g_project_dir != null) {
        var text: [400]u8 = undefined;
        _ = libc.snprintf(&text, text.len, "Back to %s", ide.ide_basename(ide.g_project_dir));
        raven.Rbutton_set_text(g_w.back, &text);
        raven.Rwidget_set_visibility(g_w.back, raven.R_VISIBLE);
    } else if (ide.designer_has_document() != 0) {
        raven.Rbutton_set_text(g_w.back, "Back to the interface");
        raven.Rwidget_set_visibility(g_w.back, raven.R_VISIBLE);
    } else {
        raven.Rwidget_set_visibility(g_w.back, raven.R_COLLAPSED);
    }
    update_package();
    refresh_list();
    raven.Rwidget_focus(g_w.list);
}

export fn welcome_hide() void {
    const pages: Rid = raven.Rwidget_find(ide.g_ide_window, "pages");
    if (pages == R_INVALID_ID or raven.Rswitcher_get_index(pages) == 1) return;
    raven.Rswitcher_set_index(pages, 1);
    raven.Rwidget_set_visibility(raven.Rwidget_find(ide.g_ide_window, "header.build"), raven.R_VISIBLE);
}

export fn welcome_is_shown() c_int {
    const pages: Rid = if (ide.g_ide_window != R_INVALID_ID) raven.Rwidget_find(ide.g_ide_window, "pages") else R_INVALID_ID;
    return @intFromBool(pages != R_INVALID_ID and raven.Rswitcher_get_index(pages) == 0);
}
