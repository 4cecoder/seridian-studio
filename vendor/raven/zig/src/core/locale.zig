// Translated to Zig from vendor/raven/src/core/locale.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/locale.c
// Translations from CSV tables, the language, plural forms and numbers
// (raven_locale.h). UI thread.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("base_h.zig");
const ctx_h = @import("context_h.zig");
const handle_h = @import("handle_h.zig");
const fs_h = @import("fs_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const xml_watch_h = @import("../xml/xml_watch_h.zig");
const libc = @import("../sys/libc.zig");

const R_TRUE = raven.R_TRUE;
const R_FALSE = raven.R_FALSE;

// #define RVN_LOCALE_RING 16
const RVN_LOCALE_RING = 16;

// Win32 and CoreFoundation declarations (windows.h, CoreFoundation.h): used only in
// their platform branches, which are not analysed on other systems.
const LOCALE_NAME_MAX_LENGTH = 85;
const CP_UTF8: c_uint = 65001;
const CFIndex = isize;
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "kernel32" fn GetUserDefaultLocaleName(name: [*]u16, length: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(code_page: c_uint, flags: u32, wide: [*]const u16, wide_length: c_int, multi: [*c]u8, multi_length: c_int, default_char: ?*const anyopaque, used_default: ?*c_int) callconv(.winapi) c_int;
extern "c" fn CFLocaleCopyPreferredLanguages() ?*anyopaque;
extern "c" fn CFArrayGetCount(array: ?*anyopaque) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: ?*anyopaque, index: CFIndex) ?*anyopaque;
extern "c" fn CFStringGetCString(string: ?*anyopaque, buffer: [*c]u8, buffer_size: CFIndex, encoding: u32) u8;
extern "c" fn CFRelease(cf: ?*anyopaque) void;

// ---------------------------------------------------------------------------
//  Small helpers
// ---------------------------------------------------------------------------

const rvn_locale_entry_t = extern struct {
    key: [*c]u8,
    /// One text per language (NULL: none), as many as g_locale.language_count when written.
    texts: [*c][*c]u8,
    text_count: u32,
};

const rvn_locale_binding_t = extern struct {
    widget: raven.Rid,
    attribute: [*c]u8,
    key: [*c]u8,
};

const rvn_locale_file_t = extern struct {
    path: [*c]u8,
};

const rvn_locale_state_t = extern struct {
    languages: [*c][*c]u8,
    language_count: u32,
    language_cap: u32,
    entries: [*c]rvn_locale_entry_t,
    entry_count: u32,
    entry_cap: u32,
    /// Open addressing: index + 1 into entries, 0 = empty.
    buckets: [*c]u32,
    bucket_count: u32,

    language: [*c]u8,
    current: c_int, // column of the language, -1 if none
    fallback: [*c]u8, // NULL: the first column
    system: [64]u8,

    bindings: [*c]rvn_locale_binding_t,
    binding_count: u32,
    binding_cap: u32,
    applying: c_int,

    files: [*c]rvn_locale_file_t,
    file_count: u32,
    file_cap: u32,

    ring: [RVN_LOCALE_RING][*c]u8,
    ring_next: u32,

    callback: raven.RLocaleChangedCallback,
    callback_user: ?*anyopaque,
};

var g_locale: rvn_locale_state_t = std.mem.zeroes(rvn_locale_state_t);

/// base_h.RVN_ARRAY_RESERVE cannot take an array of pointers: its data argument would be a
/// double pointer, which does not convert to ?*anyopaque. Same growth, with explicit casts.
fn rvn_locale_reserve_strings(data: *[*c][*c]u8, cap: [*c]u32, needed: u32) void {
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf([*c]u8))));
}

fn rvn_locale_hash(text: [*c]const u8) u32 {
    var h: u32 = 2166136261;
    var p = text;
    while (p[0] != 0) : (p += 1) h = (h ^ @as(u32, p[0])) *% 16777619;
    return h;
}

/// Keeps a string for the next RVN_LOCALE_RING calls.
fn rvn_locale_keep(text: [*c]u8) [*c]const u8 {
    const slot = g_locale.ring_next % RVN_LOCALE_RING;
    g_locale.ring_next +%= 1;
    base.rvn_free(g_locale.ring[slot]);
    g_locale.ring[slot] = text;
    return if (text != null) text else "";
}

/// "fr_FR.UTF-8" -> "fr-FR"; lower-cases the language, keeps the rest.
fn rvn_locale_normalize(in: [*c]const u8, out: [*c]u8, cap: usize) void {
    var n: usize = 0;
    var part: c_int = 0;
    var in_ = in;
    while (in_[0] != 0 and n + 1 < cap) : (in_ += 1) {
        var c = in_[0];
        if (c == '.' or c == '@' or c == ':') break;
        if (c == '_') c = '-';
        if (c == '-') {
            part += 1;
        } else if (part == 0 and c >= 'A' and c <= 'Z') {
            c = c - 'A' + 'a';
        }
        out[n] = c;
        n += 1;
    }
    out[n] = 0;
}

/// The first part of a code: "pt-BR" -> "pt".
fn rvn_locale_base_length(code: [*c]const u8) usize {
    var n: usize = 0;
    while (code[n] != 0 and code[n] != '-' and code[n] != '_') n += 1;
    return n;
}

fn rvn_locale_base_is(code: [*c]const u8, base_: [*c]const u8) c_int {
    const n = rvn_locale_base_length(code);
    return if (n == libc.strlen(base_) and base.rvn_strnicmp(code, base_, n) == 0) R_TRUE else R_FALSE;
}

fn rvn_locale_column(code: [*c]const u8) c_int {
    var i: u32 = 0;
    var n: usize = undefined;
    if (code == null or code[0] == 0) return -1;
    while (i < g_locale.language_count) : (i += 1)
        if (base.rvn_stricmp(g_locale.languages[i], code) == 0) return @bitCast(i);
    // "pt-BR" asked, "pt" in the tables; then "fr" asked, "fr-FR" in the tables
    n = rvn_locale_base_length(code);
    i = 0;
    while (i < g_locale.language_count) : (i += 1)
        if (libc.strlen(g_locale.languages[i]) == n and base.rvn_strnicmp(g_locale.languages[i], code, n) == 0) return @bitCast(i);
    i = 0;
    while (i < g_locale.language_count) : (i += 1)
        if (rvn_locale_base_length(g_locale.languages[i]) == n and base.rvn_strnicmp(g_locale.languages[i], code, n) == 0) return @bitCast(i);
    return -1;
}

fn rvn_locale_add_language(code: [*c]const u8) c_int {
    var normalized: [64]u8 = undefined;
    rvn_locale_normalize(code, &normalized, normalized.len);
    if (normalized[0] == 0) return -1;
    {
        var i: u32 = 0;
        while (i < g_locale.language_count) : (i += 1)
            if (base.rvn_stricmp(g_locale.languages[i], &normalized) == 0) return @bitCast(i);
    }
    rvn_locale_reserve_strings(&g_locale.languages, &g_locale.language_cap, g_locale.language_count + 1);
    g_locale.languages[g_locale.language_count] = base.rvn_strdup(&normalized);
    const found: c_int = @bitCast(g_locale.language_count);
    g_locale.language_count += 1;
    // the language may have been chosen before its table was loaded
    g_locale.current = if (g_locale.language != null) rvn_locale_column(g_locale.language) else 0;
    return found;
}

fn rvn_locale_find(key: [*c]const u8) [*c]rvn_locale_entry_t {
    if (g_locale.bucket_count == 0 or key == null) return null;
    const h = rvn_locale_hash(key);
    var i: u32 = 0;
    while (i < g_locale.bucket_count) : (i += 1) {
        const slot = g_locale.buckets[(h +% i) & (g_locale.bucket_count - 1)];
        if (slot == 0) return null;
        if (libc.strcmp(g_locale.entries[slot - 1].key, key) == 0) return &g_locale.entries[slot - 1];
    }
    return null;
}

fn rvn_locale_rehash() void {
    var count: u32 = 64;
    var i: u32 = 0;
    while (count < g_locale.entry_count * 2 + 2) count *= 2;
    base.rvn_free(g_locale.buckets);
    g_locale.buckets = @ptrCast(@alignCast(base.rvn_calloc(@as(usize, count) * @sizeOf(u32))));
    g_locale.bucket_count = count;
    while (i < g_locale.entry_count) : (i += 1) {
        const h = rvn_locale_hash(g_locale.entries[i].key);
        var k: u32 = 0;
        while (g_locale.buckets[(h +% k) & (count - 1)] != 0) k += 1;
        g_locale.buckets[(h +% k) & (count - 1)] = i + 1;
    }
}

fn rvn_locale_entry(key: [*c]const u8) [*c]rvn_locale_entry_t {
    var entry = rvn_locale_find(key);
    if (entry != null) return entry;
    base.RVN_ARRAY_RESERVE(&g_locale.entries, &g_locale.entry_cap, g_locale.entry_count + 1);
    entry = &g_locale.entries[g_locale.entry_count];
    g_locale.entry_count += 1;
    entry.* = std.mem.zeroes(rvn_locale_entry_t);
    entry.*.key = base.rvn_strdup(key);
    if (g_locale.entry_count * 2 + 2 > g_locale.bucket_count) {
        rvn_locale_rehash();
    } else {
        const h = rvn_locale_hash(key);
        var k: u32 = 0;
        while (g_locale.buckets[(h +% k) & (g_locale.bucket_count - 1)] != 0) k += 1;
        g_locale.buckets[(h +% k) & (g_locale.bucket_count - 1)] = g_locale.entry_count;
    }
    return entry;
}

fn rvn_locale_put(entry: [*c]rvn_locale_entry_t, column: c_int, text: [*c]const u8, length: usize) void {
    if (column < 0) return;
    const col: u32 = @bitCast(column);
    if (col >= entry.*.text_count) {
        const count: u32 = col + 1;
        entry.*.texts = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(entry.*.texts), @as(usize, count) * @sizeOf([*c]u8))));
        var i: u32 = entry.*.text_count;
        while (i < count) : (i += 1) entry.*.texts[i] = null;
        entry.*.text_count = count;
    }
    base.rvn_free(entry.*.texts[col]);
    entry.*.texts[col] = base.rvn_strndup(text, length);
}

fn rvn_locale_text(entry: [*c]const rvn_locale_entry_t, column: c_int) [*c]const u8 {
    if (entry == null or column < 0 or @as(u32, @bitCast(column)) >= entry.*.text_count) return null;
    const text = entry.*.texts[@as(u32, @bitCast(column))];
    return if (text != null and text[0] != 0) text else null;
}

fn rvn_locale_fallback_column() c_int {
    const column: c_int = if (g_locale.fallback != null) rvn_locale_column(g_locale.fallback) else -1;
    return if (column >= 0) column else (if (g_locale.language_count != 0) 0 else -1);
}

fn rvn_locale_lookup(key: [*c]const u8) [*c]const u8 {
    const entry = rvn_locale_find(key);
    var text = rvn_locale_text(entry, g_locale.current);
    if (text == null) text = rvn_locale_text(entry, rvn_locale_fallback_column());
    return text;
}

// ---------------------------------------------------------------------------
//  Widgets that show a key
// ---------------------------------------------------------------------------

fn rvn_locale_is_key(text: [*c]const u8) c_int {
    if (text == null or text[0] == 0) return R_FALSE;
    var c = text;
    while (c[0] != 0) : (c += 1) {
        const ch = c[0];
        if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-' or ch == '/'))
            return R_FALSE;
    }
    return R_TRUE;
}

/// Attributes that are names, not texts: "@" there is not a key.
fn rvn_locale_attribute_is_text(name: [*c]const u8) c_int {
    const names = [_][*c]const u8{
        "Name", "Id", "Class", "Theme", "Action", "Source", "Style", "Cursor", "Font", "Icon", "Image", "Texture",
        "Visibility", "Material", "Appear", "DockTo", "Shortcut", "Language", "Direction",
    };
    if (base.rvn_strnicmp(name, "On", 2) == 0 and name[2] >= 'A' and name[2] <= 'Z') return R_FALSE;
    if (libc.strchr(name, '.') != null) return R_FALSE; // Slot.*, Color.*, Metric.*
    for (names) |attr| {
        if (base.rvn_stricmp(name, attr) == 0) return R_FALSE;
    }
    return R_TRUE;
}

fn rvn_locale_binding(widget: raven.Rid, attribute: [*c]const u8) [*c]rvn_locale_binding_t {
    var i: u32 = 0;
    while (i < g_locale.binding_count) : (i += 1) {
        const b = &g_locale.bindings[i];
        if (b.*.widget == widget and base.rvn_stricmp(b.*.attribute, attribute) == 0) return b;
    }
    return null;
}

fn rvn_locale_unbind_at(i: u32) void {
    base.rvn_free(g_locale.bindings[i].attribute);
    base.rvn_free(g_locale.bindings[i].key);
    g_locale.binding_count -= 1;
    g_locale.bindings[i] = g_locale.bindings[g_locale.binding_count];
}

/// Sets the attribute to the translation of the key (the key with its @ when nothing translates it yet).
fn rvn_locale_apply(widget: [*c]widget_h.rvn_widget_t, attribute: [*c]const u8, key: [*c]const u8) c_int {
    var text = rvn_locale_lookup(key);
    var shown: [*c]u8 = null;
    if (text == null) {
        shown = @ptrCast(@alignCast(base.rvn_alloc(libc.strlen(key) + 2)));
        shown[0] = '@';
        _ = libc.strcpy(shown + 1, key);
        text = shown;
    }
    g_locale.applying += 1;
    const ok = widget_h.rvn_widget_set_attribute(widget, attribute, text);
    g_locale.applying -= 1;
    base.rvn_free(shown);
    return ok;
}

/// Called by rvn_widget_set_attribute for every attribute. Returns R_TRUE when
/// it handled the value (a key, or "@@..."), with *result what the widget said.
export fn rvn_locale_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8, result: [*c]c_int) c_int {
    var b: [*c]rvn_locale_binding_t = undefined;
    if (g_locale.applying != 0) return R_FALSE;
    if (value[0] == '@' and rvn_locale_attribute_is_text(name) != 0) {
        if (value[1] == '@') {
            // a text that starts with @
            b = rvn_locale_binding(widget.*.id, name);
            if (b != null) rvn_locale_unbind_at(@intCast(b - g_locale.bindings));
            g_locale.applying += 1;
            result.* = widget_h.rvn_widget_set_attribute(widget, name, value + 1);
            g_locale.applying -= 1;
            return R_TRUE;
        }
        if (rvn_locale_is_key(value + 1) != 0) {
            b = rvn_locale_binding(widget.*.id, name);
            if (b == null) {
                base.RVN_ARRAY_RESERVE(&g_locale.bindings, &g_locale.binding_cap, g_locale.binding_count + 1);
                b = &g_locale.bindings[g_locale.binding_count];
                g_locale.binding_count += 1;
                b.*.widget = widget.*.id;
                b.*.attribute = base.rvn_strdup(name);
                b.*.key = null;
            }
            _ = base.rvn_str_set(&b.*.key, value + 1);
            result.* = rvn_locale_apply(widget, name, value + 1);
            return R_TRUE;
        }
    }
    // a plain text replaces a key
    if (g_locale.binding_count != 0) {
        b = rvn_locale_binding(widget.*.id, name);
        if (b != null) rvn_locale_unbind_at(@intCast(b - g_locale.bindings));
    }
    return R_FALSE;
}

fn rvn_locale_refresh() void {
    var i: u32 = 0;
    while (i < g_locale.binding_count) {
        const b = &g_locale.bindings[i];
        const widget: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(handle_h.rvn_pool_get(&ctx_h.g_rvn.widgets, b.*.widget)));
        if (widget == null or (widget.*.flags & widget_h.RVN_WF_DEAD) != 0) {
            rvn_locale_unbind_at(i);
            continue;
        }
        _ = rvn_locale_apply(widget, b.*.attribute, b.*.key);
        i += 1;
    }
    widget_h.rvn_direction_refresh();
    if (g_locale.callback) |callback| {
        const lang: [*c]const u8 = if (g_locale.language != null) g_locale.language else "";
        callback(lang, g_locale.callback_user);
    }
}

// ---------------------------------------------------------------------------
//  CSV
// ---------------------------------------------------------------------------

const rvn_csv_t = extern struct {
    c: [*c]const u8,
    end: [*c]const u8,
    field: [*c]u8,
    length: u32,
    cap: u32,
};

/// Reads one field into csv->field. Returns 0 at the end of the text, 1 when the
/// field ends the line (or the text), 2 when another field follows on the line.
fn rvn_csv_field(csv: [*c]rvn_csv_t) c_int {
    csv.*.length = 0;
    if (csv.*.c >= csv.*.end) return 0;
    if (csv.*.c[0] == '"') {
        csv.*.c += 1;
        while (csv.*.c < csv.*.end) {
            const ch = csv.*.c[0];
            csv.*.c += 1;
            if (ch == '"') {
                if (csv.*.c < csv.*.end and csv.*.c[0] == '"') {
                    csv.*.c += 1;
                } else {
                    break;
                }
            }
            base.RVN_ARRAY_RESERVE(&csv.*.field, &csv.*.cap, csv.*.length + 2);
            csv.*.field[csv.*.length] = ch;
            csv.*.length += 1;
        }
        // (anything between the closing quote and the separator is ignored)
        while (csv.*.c < csv.*.end and csv.*.c[0] != ',' and csv.*.c[0] != '\n') csv.*.c += 1;
    } else {
        while (csv.*.c < csv.*.end and csv.*.c[0] != ',' and csv.*.c[0] != '\n') {
            base.RVN_ARRAY_RESERVE(&csv.*.field, &csv.*.cap, csv.*.length + 2);
            csv.*.field[csv.*.length] = csv.*.c[0];
            csv.*.length += 1;
            csv.*.c += 1;
        }
        while (csv.*.length != 0 and csv.*.field[csv.*.length - 1] == '\r') csv.*.length -= 1;
    }
    base.RVN_ARRAY_RESERVE(&csv.*.field, &csv.*.cap, csv.*.length + 1);
    csv.*.field[csv.*.length] = 0;
    if (csv.*.c < csv.*.end and csv.*.c[0] == ',') {
        csv.*.c += 1;
        return 2;
    }
    if (csv.*.c < csv.*.end and csv.*.c[0] == '\n') csv.*.c += 1;
    return 1;
}

fn rvn_csv_skip_line(csv: [*c]rvn_csv_t) void {
    while (csv.*.c < csv.*.end and csv.*.c[0] != '\n') csv.*.c += 1;
    if (csv.*.c < csv.*.end) csv.*.c += 1;
}

fn rvn_locale_parse(text: [*c]const u8, size: usize, origin: [*c]const u8) c_int {
    var csv: rvn_csv_t = std.mem.zeroes(rvn_csv_t);
    var columns: [256]c_int = undefined;
    var column_count: c_int = 0;
    var keys: c_int = 0;
    var state: c_int = undefined;
    csv.c = text;
    csv.end = text + size;
    if (size >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) csv.c += 3;

    // the header: key, then the languages
    while (csv.c < csv.end and (csv.c[0] == '#' or csv.c[0] == '\n' or csv.c[0] == '\r')) rvn_csv_skip_line(&csv);
    state = rvn_csv_field(&csv);
    if (state == 0) {
        base.rvn_free(csv.field);
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_load_csv: %s is empty", origin);
        return -1;
    }
    while (state == 2 and column_count < 256) {
        state = rvn_csv_field(&csv);
        columns[@intCast(column_count)] = rvn_locale_add_language(csv.field);
        column_count += 1;
    }
    if (column_count == 0) {
        base.rvn_free(csv.field);
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_load_csv: %s has no language column (the first row is: key,en,fr,...)", origin);
        return -1;
    }

    while (csv.c < csv.end) {
        var column: c_int = 0;
        if (csv.c[0] == '#' or csv.c[0] == '\n' or (csv.c[0] == '\r' and csv.c + 1 < csv.end and csv.c[1] == '\n')) {
            rvn_csv_skip_line(&csv);
            continue;
        }
        state = rvn_csv_field(&csv);
        if (state == 0) break;
        if (csv.field[0] == 0) {
            while (state == 2) state = rvn_csv_field(&csv);
            continue;
        }
        const entry = rvn_locale_entry(csv.field);
        keys += 1;
        while (state == 2) {
            state = rvn_csv_field(&csv);
            if (column < column_count and csv.length != 0) rvn_locale_put(entry, columns[@intCast(column)], csv.field, csv.length);
            column += 1;
        }
    }
    base.rvn_free(csv.field);
    g_locale.current = if (g_locale.language != null) rvn_locale_column(g_locale.language) else 0;
    return keys;
}

fn rvn_locale_file_changed(path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    var size: usize = 0;
    const text = base.rvn_read_file(path, &size);
    _ = user;
    if (text == null) return R_FALSE;
    _ = rvn_locale_parse(text, size, path);
    base.rvn_free(text);
    rvn_locale_refresh();
    return R_TRUE;
}

// ---------------------------------------------------------------------------
//  System language and conventions
// ---------------------------------------------------------------------------

fn rvn_locale_detect_system() void {
    var raw: [128]u8 = std.mem.zeroes([128]u8);
    if (builtin.os.tag == .windows) {
        var name: [LOCALE_NAME_MAX_LENGTH]u16 = undefined;
        if (GetUserDefaultLocaleName(&name, LOCALE_NAME_MAX_LENGTH) > 0)
            _ = WideCharToMultiByte(CP_UTF8, 0, &name, -1, &raw, @intCast(raw.len), null, null);
    } else if (builtin.os.tag.isDarwin()) {
        const languages = CFLocaleCopyPreferredLanguages();
        if (languages != null) {
            if (CFArrayGetCount(languages) > 0) {
                const first = CFArrayGetValueAtIndex(languages, 0);
                _ = CFStringGetCString(first, &raw, @intCast(raw.len), kCFStringEncodingUTF8);
            }
            CFRelease(languages);
        }
    } else {
        const variables = [_][*c]const u8{ "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" };
        var i: usize = 0;
        while (i < variables.len and raw[0] == 0) : (i += 1) {
            const value = libc.getenv(variables[i]);
            if (value != null and value[0] != 0 and libc.strcmp(value, "C") != 0 and libc.strcmp(value, "POSIX") != 0 and libc.strncmp(value, "C.", 2) != 0) {
                var n = libc.strcspn(value, ":");
                if (n >= raw.len) n = raw.len - 1;
                @memcpy(raw[0..n], value[0..n]);
                raw[n] = 0;
            }
        }
    }
    if (raw[0] == 0) _ = libc.strcpy(&raw, "en");
    rvn_locale_normalize(&raw, &g_locale.system, g_locale.system.len);
}

export fn rvn_locale_code_is_rtl(code: [*c]const u8) c_int {
    const rtl = [_][*c]const u8{ "ar", "he", "iw", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ckb", "syr" };
    if (code == null) return R_FALSE;
    for (rtl) |lang| {
        if (rvn_locale_base_is(code, lang) != 0) return R_TRUE;
    }
    return R_FALSE;
}

/// CLDR plural categories for integers, for the most used languages.
fn rvn_locale_plural_category(code_in: [*c]const u8, count: c_longlong) [*c]const u8 {
    const n: c_longlong = if (count < 0) -count else count;
    const n10: c_longlong = @rem(n, 10);
    const n100: c_longlong = @rem(n, 100);
    const no_plural = [_][*c]const u8{ "ja", "zh", "ko", "vi", "th", "id", "ms", "lo", "km", "my", "yo" };
    const zero_one = [_][*c]const u8{ "fr", "pt", "hi", "bn", "fa", "am", "kab", "gu", "kn", "zu" };
    const code: [*c]const u8 = if (code_in != null) code_in else "en";
    for (no_plural) |lang| {
        if (rvn_locale_base_is(code, lang) != 0) return "other";
    }
    for (zero_one) |lang| {
        if (rvn_locale_base_is(code, lang) != 0) return if (n <= 1) "one" else "other";
    }
    if (rvn_locale_base_is(code, "ru") != 0 or rvn_locale_base_is(code, "uk") != 0 or rvn_locale_base_is(code, "be") != 0) {
        if (n10 == 1 and n100 != 11) return "one";
        if (n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14)) return "few";
        return "many";
    }
    if (rvn_locale_base_is(code, "pl") != 0) {
        if (n == 1) return "one";
        if (n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14)) return "few";
        return "many";
    }
    if (rvn_locale_base_is(code, "cs") != 0 or rvn_locale_base_is(code, "sk") != 0) {
        if (n == 1) return "one";
        if (n >= 2 and n <= 4) return "few";
        return "other";
    }
    if (rvn_locale_base_is(code, "ar") != 0) {
        if (n == 0) return "zero";
        if (n == 1) return "one";
        if (n == 2) return "two";
        if (n100 >= 3 and n100 <= 10) return "few";
        if (n100 >= 11) return "many";
        return "other";
    }
    if (rvn_locale_base_is(code, "he") != 0 or rvn_locale_base_is(code, "iw") != 0) {
        if (n == 1) return "one";
        if (n == 2) return "two";
        return "other";
    }
    return if (n == 1) "one" else "other";
}

fn rvn_locale_separators(code: [*c]const u8, decimal: [*c][*c]const u8, group: [*c][*c]const u8) void {
    const comma_dot = [_][*c]const u8{ "de", "es", "it", "nl", "tr", "id", "da", "el", "ro", "hr", "sl", "sr", "vi", "pt-BR" };
    const comma_space = [_][*c]const u8{ "ru", "uk", "pl", "cs", "sk", "sv", "fi", "nb", "no", "hu", "bg", "lt", "lv", "et", "pt" };
    decimal.* = ".";
    group.* = ",";
    if (code == null) return;
    if (base.rvn_stricmp(code, "de-CH") == 0) {
        group.* = "\xE2\x80\x99";
        return;
    }
    if (rvn_locale_base_is(code, "fr") != 0) {
        decimal.* = ",";
        group.* = "\xE2\x80\xAF";
        return;
    }
    if (base.rvn_stricmp(code, "pt-BR") == 0) {
        decimal.* = ",";
        group.* = ".";
        return;
    }
    for (comma_dot) |lang| {
        if (rvn_locale_base_is(code, lang) != 0) {
            decimal.* = ",";
            group.* = ".";
            return;
        }
    }
    for (comma_space) |lang| {
        if (rvn_locale_base_is(code, lang) != 0) {
            decimal.* = ",";
            group.* = "\xC2\xA0";
            return;
        }
    }
}

fn rvn_locale_number(value: f64, decimals_in: c_int) [*c]u8 {
    var decimals: c_int = decimals_in;
    var decimal: [*c]const u8 = undefined;
    var group: [*c]const u8 = undefined;
    var digits: [512]u8 = undefined;
    var out: [1024]u8 = undefined;
    var n: usize = 0;
    const negative = value < 0.0;
    if (decimals < 0) decimals = 0;
    if (decimals > 20) decimals = 20;
    rvn_locale_separators(g_locale.language, &decimal, &group);
    const magnitude: f64 = if (negative) -value else value;
    _ = libc.snprintf(&digits, digits.len, "%.*f", decimals, magnitude);
    const dot = libc.strchr(&digits, '.');
    const integer_length: usize = if (dot != null) @intCast(dot - @as([*c]u8, &digits)) else libc.strlen(&digits);
    if (negative and libc.strcmp(&digits, "0") != 0) {
        out[n] = '-';
        n += 1;
    }
    var i: usize = 0;
    while (i < integer_length and n + 8 < out.len) : (i += 1) {
        out[n] = digits[i];
        n += 1;
        if (integer_length - i - 1 > 0 and (integer_length - i - 1) % 3 == 0 and integer_length > 3) {
            const g = libc.strlen(group);
            @memcpy(out[n..][0..g], group[0..g]);
            n += g;
        }
    }
    if (dot != null) {
        const d = libc.strlen(decimal);
        const rest = libc.strlen(dot + 1);
        if (n + d + rest + 1 < out.len) {
            @memcpy(out[n..][0..d], decimal[0..d]);
            n += d;
            @memcpy(out[n..][0..rest], (dot + 1)[0..rest]);
            n += rest;
        }
    }
    out[n] = 0;
    return base.rvn_strdup(&out);
}

/// {0}..{9} from args, {n} from n_text; "{{" is "{".
fn rvn_locale_substitute(text: [*c]const u8, args: [*c]const [*c]const u8, count: c_int, n_text: [*c]const u8) [*c]u8 {
    var out: base.rvn_text_t = std.mem.zeroes(base.rvn_text_t);
    var c = text;
    while (c[0] != 0) : (c += 1) {
        if (c[0] == '{' and c[1] == '{') {
            base.rvn_text_append(&out, "{", 1);
            c += 1;
            continue;
        }
        if (c[0] == '{' and c[1] >= '0' and c[1] <= '9' and c[2] == '}') {
            const index: c_int = @as(c_int, c[1]) - '0';
            if (index < count and args != null and args[@intCast(index)] != null) base.rvn_text_add(&out, args[@intCast(index)]);
            c += 2;
            continue;
        }
        if (n_text != null and c[0] == '{' and c[1] == 'n' and c[2] == '}') {
            base.rvn_text_add(&out, n_text);
            c += 2;
            continue;
        }
        base.rvn_text_append(&out, c, 1);
    }
    if (out.data == null) return base.rvn_strdup("");
    return out.data;
}

// ---------------------------------------------------------------------------
//  Library
// ---------------------------------------------------------------------------

export fn rvn_locale_rtl() c_int {
    return rvn_locale_code_is_rtl(g_locale.language);
}

export fn rvn_locale_shutdown() void {
    var i: u32 = 0;
    var k: u32 = undefined;
    while (i < g_locale.entry_count) : (i += 1) {
        k = 0;
        while (k < g_locale.entries[i].text_count) : (k += 1) base.rvn_free(g_locale.entries[i].texts[k]);
        base.rvn_free(@ptrCast(g_locale.entries[i].texts));
        base.rvn_free(g_locale.entries[i].key);
    }
    i = 0;
    while (i < g_locale.language_count) : (i += 1) base.rvn_free(g_locale.languages[i]);
    i = 0;
    while (i < g_locale.binding_count) : (i += 1) {
        base.rvn_free(g_locale.bindings[i].attribute);
        base.rvn_free(g_locale.bindings[i].key);
    }
    i = 0;
    while (i < g_locale.file_count) : (i += 1) base.rvn_free(g_locale.files[i].path);
    i = 0;
    while (i < RVN_LOCALE_RING) : (i += 1) base.rvn_free(g_locale.ring[i]);
    base.rvn_free(g_locale.entries);
    base.rvn_free(@ptrCast(g_locale.languages));
    base.rvn_free(g_locale.buckets);
    base.rvn_free(g_locale.bindings);
    base.rvn_free(g_locale.files);
    base.rvn_free(g_locale.language);
    base.rvn_free(g_locale.fallback);
    g_locale = std.mem.zeroes(rvn_locale_state_t);
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rlocale_load_csv(path: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rlocale_load_csv") == 0) return -1;
    if (path == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_load_csv: NULL path");
        return -1;
    }
    var size: usize = 0;
    const text = base.rvn_read_file(path, &size);
    if (text == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rlocale_load_csv: cannot read %s", path);
        return -1;
    }
    const keys = rvn_locale_parse(text, size, path);
    base.rvn_free(text);
    if (keys < 0) return -1;
    const absolute = fs_h.rvn_path_absolute(path);
    const target: [*c]const u8 = if (absolute != null) absolute else path;
    var i: u32 = 0;
    while (i < g_locale.file_count) : (i += 1) {
        if (libc.strcmp(g_locale.files[i].path, target) == 0) break;
    }
    if (i == g_locale.file_count) {
        base.RVN_ARRAY_RESERVE(&g_locale.files, &g_locale.file_cap, g_locale.file_count + 1);
        g_locale.files[g_locale.file_count].path = base.rvn_strdup(target);
        g_locale.file_count += 1;
        if (raven.Rxml_get_live_reload() != 0) xml_watch_h.rvn_watch_add(target, &rvn_locale_file_changed, null);
    }
    base.rvn_free(absolute);
    rvn_locale_refresh();
    return keys;
}

export fn Rlocale_load_csv_from_memory(csv: [*c]const u8, size: usize) c_int {
    if (ctx_h.rvn_api_check("Rlocale_load_csv_from_memory") == 0) return -1;
    if (csv == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_load_csv_from_memory: NULL text");
        return -1;
    }
    const keys = rvn_locale_parse(csv, size, "the text");
    if (keys >= 0) rvn_locale_refresh();
    return keys;
}

export fn Rlocale_clear() void {
    if (ctx_h.rvn_api_check("Rlocale_clear") == 0) return;
    var i: u32 = 0;
    var k: u32 = undefined;
    while (i < g_locale.entry_count) : (i += 1) {
        k = 0;
        while (k < g_locale.entries[i].text_count) : (k += 1) base.rvn_free(g_locale.entries[i].texts[k]);
        base.rvn_free(@ptrCast(g_locale.entries[i].texts));
        base.rvn_free(g_locale.entries[i].key);
    }
    i = 0;
    while (i < g_locale.language_count) : (i += 1) base.rvn_free(g_locale.languages[i]);
    g_locale.entry_count = 0;
    g_locale.language_count = 0;
    g_locale.current = 0;
    base.rvn_free(g_locale.buckets);
    g_locale.buckets = null;
    g_locale.bucket_count = 0;
    rvn_locale_refresh();
}

export fn Rlocale_set_text(language: [*c]const u8, key: [*c]const u8, text: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rlocale_set_text") == 0) return;
    if (language == null or key == null or key[0] == 0 or text == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_set_text: NULL language, key or text");
        return;
    }
    const column = rvn_locale_add_language(language);
    rvn_locale_put(rvn_locale_entry(key), column, text, libc.strlen(text));
    rvn_locale_refresh();
}

export fn Rlocale_get_language_count() c_int {
    if (ctx_h.rvn_api_check("Rlocale_get_language_count") == 0) return 0;
    return @bitCast(g_locale.language_count);
}

export fn Rlocale_get_language_at(index: c_int) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rlocale_get_language_at") == 0) return null;
    if (index >= 0 and @as(u32, @bitCast(index)) < g_locale.language_count) return g_locale.languages[@as(u32, @bitCast(index))];
    return null;
}

export fn Rlocale_set_language(code: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rlocale_set_language") == 0) return R_FALSE;
    if (code == null or code[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlocale_set_language: no language");
        return R_FALSE;
    }
    var normalized: [64]u8 = undefined;
    rvn_locale_normalize(code, &normalized, normalized.len);
    _ = base.rvn_str_set(&g_locale.language, &normalized);
    g_locale.current = rvn_locale_column(&normalized);
    rvn_locale_refresh();
    return @intFromBool(g_locale.current >= 0);
}

export fn Rlocale_get_language() [*c]const u8 {
    if (ctx_h.rvn_api_check("Rlocale_get_language") == 0) return null;
    if (g_locale.language != null) return g_locale.language;
    return if (g_locale.language_count != 0) g_locale.languages[0] else "";
}

export fn Rlocale_get_system_language() [*c]const u8 {
    if (ctx_h.rvn_api_check("Rlocale_get_system_language") == 0) return null;
    if (g_locale.system[0] == 0) rvn_locale_detect_system();
    return &g_locale.system[0];
}

export fn Rlocale_set_fallback_language(code: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rlocale_set_fallback_language") == 0) return;
    const value: [*c]const u8 = if (code != null and code[0] != 0) code else null;
    _ = base.rvn_str_set(&g_locale.fallback, value);
    rvn_locale_refresh();
}

export fn Rlocale_is_rtl() c_int {
    if (ctx_h.rvn_api_check("Rlocale_is_rtl") == 0) return R_FALSE;
    return rvn_locale_rtl();
}

export fn Rlocale_set_changed_callback(callback: raven.RLocaleChangedCallback, user_data: ?*anyopaque) void {
    if (ctx_h.rvn_api_check("Rlocale_set_changed_callback") == 0) return;
    g_locale.callback = callback;
    g_locale.callback_user = user_data;
}

export fn Rtr(key: [*c]const u8) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rtr") == 0) return "";
    if (key == null) return "";
    const text = rvn_locale_lookup(key);
    return if (text != null) text else key;
}

export fn Rtr_exists(key: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rtr_exists") == 0) return R_FALSE;
    return if (key != null and rvn_locale_lookup(key) != null) R_TRUE else R_FALSE;
}

export fn Rtr_format(key: [*c]const u8, args: [*c]const [*c]const u8, arg_count: c_int) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rtr_format") == 0) return "";
    if (key == null) return "";
    return rvn_locale_keep(rvn_locale_substitute(Rtr(key), args, arg_count, null));
}

export fn Rtr_plural(key: [*c]const u8, count: c_int) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rtr_plural") == 0) return "";
    if (key == null) return "";
    const language_name: [*c]const u8 = if (g_locale.language != null) g_locale.language else if (g_locale.language_count != 0) g_locale.languages[0] else "en";
    const category = rvn_locale_plural_category(language_name, count);
    const n = libc.strlen(key);
    const full: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(n + 16)));
    _ = libc.snprintf(full, n + 16, "%s.%s", key, category);
    var text: [*c]const u8 = null;
    text = rvn_locale_lookup(full);
    if (text == null) {
        _ = libc.snprintf(full, n + 16, "%s.other", key);
        text = rvn_locale_lookup(full);
    }
    if (text == null) text = rvn_locale_lookup(key);
    if (text == null) text = key;
    const number = rvn_locale_number(@floatFromInt(count), 0);
    const result = rvn_locale_substitute(text, null, 0, number);
    base.rvn_free(number);
    base.rvn_free(full);
    return rvn_locale_keep(result);
}

export fn Rwidget_set_text_key(id: raven.Rid, attribute_: [*c]const u8, key: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rwidget_set_text_key") == 0) return;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_text_key");
    if (widget == null) return;
    const attribute: [*c]const u8 = if (attribute_ != null and attribute_[0] != 0) attribute_ else "Text";
    if (key == null or key[0] == 0) {
        const b = rvn_locale_binding(id, attribute);
        if (b != null) rvn_locale_unbind_at(@intCast(b - g_locale.bindings));
        return;
    }
    const value: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(libc.strlen(key) + 2)));
    value[0] = '@';
    _ = libc.strcpy(value + 1, key);
    if (rvn_locale_is_key(key) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwidget_set_text_key: \"%s\" is not a key (letters, digits, . _ - /)", key);
    } else {
        _ = widget_h.rvn_widget_set_attribute(widget, attribute, value);
    }
    base.rvn_free(value);
}

export fn Rlocale_format_number(value: f64, decimals: c_int) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rlocale_format_number") == 0) return "";
    return rvn_locale_keep(rvn_locale_number(value, decimals));
}
