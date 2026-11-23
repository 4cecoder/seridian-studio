// Translated to Zig from vendor/raven/tools/designer/xmlc.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - xmlc.c
// An interface with its code in one file (.xmlc, .xmlrs, .xmlpy...): the
// whole file is in one editor, scripts and interface together, as it is
// written. The visual editor shows the interface element of the file (the
// first element that is not a <script>); what it changes is written back in
// its place, the rest of the file untouched.

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

// <ctype.h>
extern "c" fn tolower(ch: c_int) c_int;
extern "c" fn isspace(ch: c_int) c_int;

var g_x: extern struct {
    path: [*c]u8,
} = .{ .path = null };

fn line_of(text_: [*c]const u8, at: [*c]const u8) c_int {
    var text = text_;
    var line: c_int = 1;
    while (text < at) : (text += 1) {
        if (text.* == '\n') line += 1;
    }
    return line;
}

fn starts_i(p: [*c]const u8, end: [*c]const u8, s: [*c]const u8) c_int {
    const n: usize = libc.strlen(s);
    var i: usize = 0;
    if ((@intFromPtr(end) -% @intFromPtr(p)) < n) return 0;
    while (i < n) : (i += 1) {
        if (tolower(@as(c_int, p[i])) != tolower(@as(c_int, s[i]))) return 0;
    }
    return 1;
}

/// After the end of the element that starts at p ('<'), or NULL.
fn skip_element(p_: [*c]const u8, end: [*c]const u8) [*c]const u8 {
    var p = p_;
    var depth: c_int = 0;
    while (p < end) {
        if (starts_i(p, end, "<!--") != 0) {
            const close: [*c]const u8 = libc.strstr(p + 4, "-->");
            if (close == null) return null;
            p = close + 3;
        } else if (starts_i(p, end, "<![CDATA[") != 0) {
            const close: [*c]const u8 = libc.strstr(p + 9, "]]>");
            if (close == null) return null;
            p = close + 3;
        } else if (p.* == '<' and p + 1 < end and p[1] == '/') {
            const close: [*c]const u8 = @ptrCast(libc.memchr(p, '>', @intFromPtr(end) -% @intFromPtr(p)));
            if (close == null) return null;
            p = close + 1;
            depth -= 1;
            if (depth == 0) return p;
        } else if (p.* == '<') {
            // an opening tag: its attributes may hold '>' in quotes
            var quote: u8 = 0;
            var q: [*c]const u8 = p + 1;
            while (q < end) : (q += 1) {
                if (quote != 0) {
                    if (q.* == quote) quote = 0;
                } else if (q.* == '"' or q.* == '\'') {
                    quote = q.*;
                } else if (q.* == '>') break;
            }
            if (q >= end) return null;
            if ((q - 1).* != '/') depth += 1;
            p = q + 1;
            if (depth == 0) return p;
        } else {
            p += 1;
        }
    }
    return null;
}

export fn xmlc_find_interface(text: [*c]const u8, start: [*c]usize, end: [*c]usize, line: [*c]c_int) c_int {
    var p: [*c]const u8 = text;
    const stop: [*c]const u8 = text + libc.strlen(text);
    while (p < stop) {
        if (starts_i(p, stop, "<!--") != 0) {
            const close: [*c]const u8 = libc.strstr(p + 4, "-->");
            p = if (close != null) close + 3 else stop;
        } else if (starts_i(p, stop, "<?") != 0 or starts_i(p, stop, "<!") != 0) {
            const close: [*c]const u8 = @ptrCast(libc.memchr(p, '>', @intFromPtr(stop) -% @intFromPtr(p)));
            p = if (close != null) close + 1 else stop;
        } else if (starts_i(p, stop, "<script") != 0 and (p + 7 >= stop or isspace(@as(c_int, p[7])) != 0 or p[7] == '>' or p[7] == '/')) {
            // a script: its code may hold anything, '<' included
            const open_end: [*c]const u8 = @ptrCast(libc.memchr(p, '>', @intFromPtr(stop) -% @intFromPtr(p)));
            var close: [*c]const u8 = undefined;
            if (open_end == null) return -1;
            if ((open_end - 1).* == '/') {
                p = open_end + 1;
                continue;
            }
            close = open_end + 1;
            while (close < stop and starts_i(close, stop, "</script") == 0) : (close += 1) {}
            if (close >= stop) return -1;
            close = @ptrCast(libc.memchr(close, '>', @intFromPtr(stop) -% @intFromPtr(close)));
            if (close == null) return -1;
            p = close + 1;
        } else if (p.* == '<') {
            const element_end: [*c]const u8 = skip_element(p, stop);
            if (element_end == null) return -1;
            start.* = @intFromPtr(p) -% @intFromPtr(text);
            end.* = @intFromPtr(element_end) -% @intFromPtr(text);
            if (line != null) line.* = line_of(text, p);
            return raven.R_TRUE;
        } else {
            p += 1;
        }
    }
    return raven.R_FALSE;
}

export fn xmlc_is_open() c_int {
    return @intFromBool(g_x.path != null);
}

export fn xmlc_path() [*c]const u8 {
    return g_x.path;
}

export fn xmlc_close() void {
    libc.free(g_x.path);
    g_x.path = null;
}

export fn xmlc_open(path: [*c]const u8) c_int {
    return xmlc_open_text(path, null);
}

export fn xmlc_open_text(path: [*c]const u8, given: [*c]const u8) c_int {
    var size: usize = 0;
    var start: usize = undefined;
    var end: usize = undefined;
    var text: [*c]u8 = if (given != null) null else raven.Rfile_read(path, &size);
    if (given == null and text == null) {
        ide.ide_status("Cannot read %s", path);
        return raven.R_FALSE;
    }
    if (given != null) {
        // (the text of a code editor: a copy, freed as the file would be)
        size = libc.strlen(given);
        text = @ptrCast(raven.Rmemory_alloc(size + 1));
        @memcpy(text[0 .. size + 1], given[0 .. size + 1]);
    }
    if (xmlc_is_open() != 0) xmlc_close();
    g_x.path = ide.ide_strdup(path);
    if (xmlc_find_interface(text, &start, &end, null) <= 0) {
        // a file with only scripts: an interface to start from, at its end (not when its elements are not closed: that shows in the Problems panel)
        var out = std.mem.zeroes(ide.ide_buffer_t);
        const start_with = "\n<Window Title=\"Window\" Width=\"480\" Height=\"320\">\n\t<VBox/>\n</Window>\n";
        const closed: c_int = @intFromBool(xmlc_find_interface(text, &start, &end, null) == 0);
        ide.ide_buffer_add(&out, text, libc.strlen(text));
        if (closed != 0) ide.ide_buffer_add(&out, start_with, start_with.len);
        ide.designer_load_interface(if (out.data != null) out.data else "", path, raven.R_TRUE);
        ide.ide_buffer_free(&out);
    } else {
        ide.designer_load_interface(text, path, raven.R_TRUE);
    }
    raven.Rmemory_free(text);
    return raven.R_TRUE;
}

export fn xmlc_save() c_int {
    const text: [*c]const u8 = ide.designer_get_interface_text();
    var ok: c_int = undefined;
    if (g_x.path == null) return raven.R_FALSE;
    ok = raven.Rfile_write(g_x.path, text, libc.strlen(text));
    if (ok != 0) {
        ide.designer_set_modified(raven.R_FALSE);
        ide.ide_status("Saved %s", g_x.path);
    } else {
        ide.ide_status("Cannot write %s", g_x.path);
    }
    return ok;
}

export fn xmlc_interface_line() c_int {
    var start: usize = undefined;
    var end: usize = undefined;
    var line: c_int = 1;
    if (xmlc_find_interface(ide.designer_get_interface_text(), &start, &end, &line) <= 0) return 1;
    return line;
}
