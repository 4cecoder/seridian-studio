// Translated to Zig from vendor/raven/web/src/web_json.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_json.c
// Memory, growing text, a JSON reader that works in place, a JSON writer,
// base64. Thread-safe as long as each object is used by one thread.

const std = @import("std");
const raven = @import("raven");
const web = @import("web_internal_h.zig");
const libc = @import("../sys/libc.zig");

const rw_text_t = web.rw_text_t;
const rw_json_t = web.rw_json_t;
const rw_json_document_t = web.rw_json_document_t;

// ---------------------------------------------------------------------------
//  Memory: the allocator of Raven, so that the statistics of the application
//  see this library too
// ---------------------------------------------------------------------------

export fn rw_alloc(size: usize) ?*anyopaque {
    return raven.Rmemory_alloc(if (size != 0) size else 1);
}

export fn rw_realloc(pointer: ?*anyopaque, size: usize) ?*anyopaque {
    return raven.Rmemory_realloc(pointer, if (size != 0) size else 1);
}

export fn rw_free(pointer: ?*anyopaque) void {
    if (pointer != null) raven.Rmemory_free(pointer);
}

export fn rw_strdup(text: [*c]const u8) [*c]u8 {
    if (text == null) return null;
    const length = libc.strlen(text);
    const copy: [*c]u8 = @ptrCast(rw_alloc(length + 1));
    if (copy != null) @memcpy(copy[0 .. length + 1], text[0 .. length + 1]);
    return copy;
}

// ---------------------------------------------------------------------------
//  Text
// ---------------------------------------------------------------------------

fn rw_text_reserve(text: [*c]rw_text_t, more: usize) c_int {
    const needed = text.*.length + more + 1;
    var capacity: usize = if (text.*.capacity != 0) text.*.capacity else 128;
    if (needed <= text.*.capacity) return 1;
    while (capacity < needed) capacity *= 2;
    const data: [*c]u8 = @ptrCast(rw_realloc(text.*.data, capacity));
    if (data == null) return 0;
    text.*.data = data;
    text.*.capacity = capacity;
    return 1;
}

export fn rw_text_add(text: [*c]rw_text_t, data: [*c]const u8, size: usize) void {
    if (rw_text_reserve(text, size) == 0) return;
    if (size > 0) @memcpy((text.*.data + text.*.length)[0..size], data[0..size]);
    text.*.length += size;
    text.*.data[text.*.length] = 0;
}

export fn rw_text_puts(text: [*c]rw_text_t, string: [*c]const u8) void {
    if (string != null) rw_text_add(text, string, libc.strlen(string));
}

export fn rw_text_printf(text: [*c]rw_text_t, format: [*c]const u8, ...) callconv(.c) void {
    var small: [256]u8 = undefined;
    var arguments = @cVaStart(); // va_start(arguments, format);
    const length = libc.vsnprintf(&small, small.len, format, &arguments);
    @cVaEnd(&arguments); // va_end(arguments);
    if (length < 0) return;
    const n: usize = @intCast(length);
    if (n < small.len) {
        rw_text_add(text, &small, n);
        return;
    }
    if (rw_text_reserve(text, n) == 0) return;
    arguments = @cVaStart(); // va_start(arguments, format);
    _ = libc.vsnprintf(text.*.data + text.*.length, n + 1, format, &arguments);
    @cVaEnd(&arguments); // va_end(arguments);
    text.*.length += n;
}

export fn rw_text_json(text: [*c]rw_text_t, string: [*c]const u8) void {
    var cursor: [*c]const u8 = if (string != null) string else "";
    var run: [*c]const u8 = cursor;
    rw_text_add(text, "\"", 1);
    while (cursor.* != 0) : (cursor += 1) {
        var escape: [*c]const u8 = null;
        var code: [8]u8 = undefined;
        switch (cursor.*) {
            '"' => escape = "\\\"",
            '\\' => escape = "\\\\",
            '\n' => escape = "\\n",
            '\r' => escape = "\\r",
            '\t' => escape = "\\t",
            else => {
                if (cursor.* < 0x20) {
                    _ = libc.snprintf(&code, code.len, "\\u%04x", @as(c_uint, cursor.*));
                    escape = &code;
                }
            },
        }
        if (escape == null) continue;
        rw_text_add(text, run, @intCast(cursor - run));
        rw_text_puts(text, escape);
        run = cursor + 1;
    }
    rw_text_add(text, run, @intCast(cursor - run));
    rw_text_add(text, "\"", 1);
}

export fn rw_text_free(text: [*c]rw_text_t) void {
    rw_free(text.*.data);
    text.*.data = null;
    text.*.capacity = 0;
    text.*.length = 0;
}

// ---------------------------------------------------------------------------
//  JSON reader
// ---------------------------------------------------------------------------

const RW_JSON_BLOCK = 64;
const RW_JSON_DEPTH = 64;

const rw_json_block_t = extern struct {
    next: [*c]rw_json_block_t,
    used: c_int,
    values: [RW_JSON_BLOCK]rw_json_t,
};

const rw_json_reader_t = extern struct {
    document: [*c]rw_json_document_t,
    cursor: [*c]u8,
    end: [*c]u8,
    failed: c_int,
};

fn rw_json_new(reader: [*c]rw_json_reader_t) [*c]rw_json_t {
    var block: [*c]rw_json_block_t = @ptrCast(@alignCast(reader.*.document.*.blocks));
    if (block == null or block.*.used == RW_JSON_BLOCK) {
        block = @ptrCast(@alignCast(rw_alloc(@sizeOf(rw_json_block_t))));
        if (block == null) {
            reader.*.failed = 1;
            return null;
        }
        block.*.next = @ptrCast(@alignCast(reader.*.document.*.blocks));
        block.*.used = 0;
        reader.*.document.*.blocks = block;
    }
    const value: [*c]rw_json_t = &block.*.values[@intCast(block.*.used)];
    block.*.used += 1;
    value.* = std.mem.zeroes(rw_json_t);
    return value;
}

fn rw_json_space(reader: [*c]rw_json_reader_t) void {
    while (reader.*.cursor < reader.*.end and (reader.*.cursor.* == ' ' or reader.*.cursor.* == '\n' or reader.*.cursor.* == '\r' or reader.*.cursor.* == '\t')) reader.*.cursor += 1;
}

fn rw_json_hex(text: [*c]const u8, value: [*c]c_uint) c_int {
    var result: c_uint = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const c = text[i];
        result <<= 4;
        if (c >= '0' and c <= '9') {
            result |= @as(c_uint, c - '0');
        } else if (c >= 'a' and c <= 'f') {
            result |= @as(c_uint, c - 'a' + 10);
        } else if (c >= 'A' and c <= 'F') {
            result |= @as(c_uint, c - 'A' + 10);
        } else return 0;
    }
    value.* = result;
    return 1;
}

fn rw_json_utf8(out_: [*c]u8, code: c_uint) [*c]u8 {
    var out = out_;
    if (code < 0x80) {
        out[0] = @truncate(code);
        out += 1;
    } else if (code < 0x800) {
        out[0] = @truncate(0xC0 | (code >> 6));
        out[1] = @truncate(0x80 | (code & 0x3F));
        out += 2;
    } else if (code < 0x10000) {
        out[0] = @truncate(0xE0 | (code >> 12));
        out[1] = @truncate(0x80 | ((code >> 6) & 0x3F));
        out[2] = @truncate(0x80 | (code & 0x3F));
        out += 3;
    } else {
        out[0] = @truncate(0xF0 | (code >> 18));
        out[1] = @truncate(0x80 | ((code >> 12) & 0x3F));
        out[2] = @truncate(0x80 | ((code >> 6) & 0x3F));
        out[3] = @truncate(0x80 | (code & 0x3F));
        out += 4;
    }
    return out;
}

/// A string, resolved where it stands: the result is never longer than the source.
fn rw_json_read_string(reader: [*c]rw_json_reader_t, string: [*c][*c]const u8, length: [*c]usize) c_int {
    var in: [*c]u8 = reader.*.cursor + 1;
    const start: [*c]u8 = in;
    // the common case: nothing to resolve (the picture of a page is megabytes of base64)
    while (in < reader.*.end and in.* != '"' and in.* != '\\') in += 1;
    var out: [*c]u8 = in;
    while (in < reader.*.end and in.* != '"') {
        if (in.* != '\\') {
            out.* = in.*;
            out += 1;
            in += 1;
            continue;
        }
        if (in + 1 >= reader.*.end) return 0;
        in += 1;
        const escaped = in.*;
        in += 1;
        switch (escaped) {
            '"' => {
                out.* = '"';
                out += 1;
            },
            '\\' => {
                out.* = '\\';
                out += 1;
            },
            '/' => {
                out.* = '/';
                out += 1;
            },
            'b' => {
                out.* = 0x08;
                out += 1;
            },
            'f' => {
                out.* = 0x0C;
                out += 1;
            },
            'n' => {
                out.* = '\n';
                out += 1;
            },
            'r' => {
                out.* = '\r';
                out += 1;
            },
            't' => {
                out.* = '\t';
                out += 1;
            },
            'u' => {
                var code: c_uint = undefined;
                var low: c_uint = undefined;
                if (in + 4 > reader.*.end or rw_json_hex(in, &code) == 0) return 0;
                in += 4;
                // two halves of a character outside the basic plane
                if (code >= 0xD800 and code < 0xDC00 and in + 6 <= reader.*.end and in[0] == '\\' and in[1] == 'u' and rw_json_hex(in + 2, &low) != 0 and low >= 0xDC00 and low < 0xE000) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    in += 6;
                }
                out = rw_json_utf8(out, code);
            },
            else => return 0,
        }
    }
    if (in >= reader.*.end) return 0;
    out.* = 0;
    string.* = start;
    length.* = @intCast(out - start);
    reader.*.cursor = in + 1;
    return 1;
}

fn rw_json_read(reader: [*c]rw_json_reader_t, depth: c_int) [*c]rw_json_t {
    var last: [*c]rw_json_t = null;

    rw_json_space(reader);
    if (reader.*.cursor >= reader.*.end or depth > RW_JSON_DEPTH) {
        reader.*.failed = 1;
        return null;
    }
    const value = rw_json_new(reader);
    if (value == null) return null;
    const c = reader.*.cursor.*;
    if (c == '{' or c == '[') {
        const close: u8 = if (c == '{') '}' else ']';
        value.*.type = @intCast(if (c == '{') web.RW_JSON_OBJECT else web.RW_JSON_ARRAY);
        reader.*.cursor += 1;
        rw_json_space(reader);
        if (reader.*.cursor < reader.*.end and reader.*.cursor.* == close) {
            reader.*.cursor += 1;
            return value;
        }
        while (true) {
            var key: [*c]const u8 = null;
            var key_length: usize = 0;
            if (value.*.type == web.RW_JSON_OBJECT) {
                rw_json_space(reader);
                if (reader.*.cursor >= reader.*.end or reader.*.cursor.* != '"' or rw_json_read_string(reader, &key, &key_length) == 0) break;
                rw_json_space(reader);
                if (reader.*.cursor >= reader.*.end or reader.*.cursor.* != ':') break;
                reader.*.cursor += 1;
            }
            const child = rw_json_read(reader, depth + 1);
            if (child == null) return null;
            child.*.key = key;
            if (last != null) {
                last.*.next = child;
            } else {
                value.*.first = child;
            }
            last = child;
            rw_json_space(reader);
            if (reader.*.cursor >= reader.*.end) break;
            if (reader.*.cursor.* == ',') {
                reader.*.cursor += 1;
                continue;
            }
            if (reader.*.cursor.* == close) {
                reader.*.cursor += 1;
                return value;
            }
            break;
        }
        reader.*.failed = 1;
        return null;
    }
    if (c == '"') {
        value.*.type = web.RW_JSON_STRING;
        if (rw_json_read_string(reader, &value.*.string, &value.*.length) == 0) {
            reader.*.failed = 1;
            return null;
        }
        return value;
    }
    if (reader.*.end - reader.*.cursor >= 4 and libc.memcmp(reader.*.cursor, "true", 4) == 0) {
        value.*.type = web.RW_JSON_BOOL;
        value.*.number = 1.0;
        reader.*.cursor += 4;
        return value;
    }
    if (reader.*.end - reader.*.cursor >= 5 and libc.memcmp(reader.*.cursor, "false", 5) == 0) {
        value.*.type = web.RW_JSON_BOOL;
        reader.*.cursor += 5;
        return value;
    }
    if (reader.*.end - reader.*.cursor >= 4 and libc.memcmp(reader.*.cursor, "null", 4) == 0) {
        reader.*.cursor += 4;
        return value;
    }
    if (c == '-' or (c >= '0' and c <= '9')) {
        var number: [40]u8 = undefined;
        var length: usize = 0;
        while (reader.*.cursor < reader.*.end and length + 1 < number.len and
            ((reader.*.cursor.* >= '0' and reader.*.cursor.* <= '9') or reader.*.cursor.* == '-' or reader.*.cursor.* == '+' or reader.*.cursor.* == '.' or reader.*.cursor.* == 'e' or reader.*.cursor.* == 'E'))
        {
            number[length] = reader.*.cursor.*;
            length += 1;
            reader.*.cursor += 1;
        }
        number[length] = 0;
        value.*.type = web.RW_JSON_NUMBER;
        value.*.number = libc.strtod(&number, null);
        return value;
    }
    reader.*.failed = 1;
    return null;
}

export fn rw_json_parse(document: [*c]rw_json_document_t, text: [*c]u8, size: usize) c_int {
    var reader: rw_json_reader_t = undefined;
    document.* = std.mem.zeroes(rw_json_document_t);
    reader.document = document;
    reader.cursor = text;
    reader.end = text + size;
    reader.failed = 0;
    document.*.root = rw_json_read(&reader, 0);
    if (document.*.root == null or reader.failed != 0) {
        rw_json_free(document);
        return 0;
    }
    return 1;
}

export fn rw_json_free(document: [*c]rw_json_document_t) void {
    var block: [*c]rw_json_block_t = @ptrCast(@alignCast(document.*.blocks));
    while (block != null) {
        const next = block.*.next;
        rw_free(block);
        block = next;
    }
    document.*.blocks = null;
    document.*.root = null;
}

export fn rw_json_get(value_: [*c]const rw_json_t, path_: [*c]const u8) [*c]const rw_json_t {
    var value = value_;
    var path = path_;
    while (value != null and path != null and path.* != 0) {
        const dot: [*c]const u8 = libc.strchr(path, '.');
        const length: usize = if (dot != null) @intCast(dot - path) else libc.strlen(path);
        if (value.*.type != web.RW_JSON_OBJECT) return null;
        var child: [*c]const rw_json_t = value.*.first;
        while (child != null) : (child = child.*.next) {
            if (child.*.key != null and libc.strlen(child.*.key) == length and libc.memcmp(child.*.key, path, length) == 0) break;
        }
        value = child;
        path = if (dot != null) dot + 1 else null;
    }
    return value;
}

export fn rw_json_string(value: [*c]const rw_json_t, path: [*c]const u8, fallback: [*c]const u8) [*c]const u8 {
    const found = rw_json_get(value, path);
    return if (found != null and found.*.type == web.RW_JSON_STRING) found.*.string else fallback;
}

export fn rw_json_number(value: [*c]const rw_json_t, path: [*c]const u8, fallback: f64) f64 {
    const found = rw_json_get(value, path);
    return if (found != null and found.*.type == web.RW_JSON_NUMBER) found.*.number else fallback;
}

export fn rw_json_bool(value: [*c]const rw_json_t, path: [*c]const u8, fallback: c_int) c_int {
    const found = rw_json_get(value, path);
    return if (found != null and found.*.type == web.RW_JSON_BOOL) @intFromBool(found.*.number != 0.0) else fallback;
}

export fn rw_json_write(text: [*c]rw_text_t, value: [*c]const rw_json_t) void {
    if (value == null) {
        rw_text_puts(text, "null");
        return;
    }
    switch (value.*.type) {
        web.RW_JSON_NULL => rw_text_puts(text, "null"),
        web.RW_JSON_BOOL => rw_text_puts(text, if (value.*.number != 0.0) "true" else "false"),
        web.RW_JSON_NUMBER => {
            // value->number == (double)(long long)value->number && -1e15 < value->number < 1e15
            // (the range is checked first here: the conversion of a double out of range is undefined in C and traps in Zig)
            if (value.*.number > -1e15 and value.*.number < 1e15 and value.*.number == @as(f64, @floatFromInt(@as(c_longlong, @intFromFloat(value.*.number))))) {
                rw_text_printf(text, "%lld", @as(c_longlong, @intFromFloat(value.*.number)));
            } else {
                rw_text_printf(text, "%.17g", value.*.number);
            }
        },
        web.RW_JSON_STRING => rw_text_json(text, value.*.string),
        web.RW_JSON_ARRAY, web.RW_JSON_OBJECT => {
            rw_text_puts(text, if (value.*.type == web.RW_JSON_ARRAY) "[" else "{");
            var child: [*c]const rw_json_t = value.*.first;
            while (child != null) : (child = child.*.next) {
                if (child != value.*.first) rw_text_puts(text, ",");
                if (value.*.type == web.RW_JSON_OBJECT) {
                    rw_text_json(text, child.*.key);
                    rw_text_puts(text, ":");
                }
                rw_json_write(text, child);
            }
            rw_text_puts(text, if (value.*.type == web.RW_JSON_ARRAY) "]" else "}");
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
//  Base64
// ---------------------------------------------------------------------------

const base64_state = struct {
    var table: [256]i8 = std.mem.zeroes([256]i8);
    var ready: c_int = 0;
};

export fn rw_base64_decode(text: [*c]const u8, length: usize, size: [*c]usize) [*c]u8 {
    var written: usize = 0;
    var bits: u32 = 0;
    var count: c_int = 0;

    if (base64_state.ready == 0) {
        const alphabet: [*c]const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        // (only the thread that reads the browser decodes)
        @memset(&base64_state.table, -1);
        var k: usize = 0;
        while (k < 64) : (k += 1) base64_state.table[alphabet[k]] = @intCast(k);
        base64_state.ready = 1;
    }
    const out: [*c]u8 = @ptrCast(rw_alloc(length / 4 * 3 + 3));
    if (out == null) return null;
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const value: c_int = base64_state.table[text[i]];
        if (text[i] == '=') break;
        if (value < 0) {
            if (text[i] == '\n' or text[i] == '\r') continue;
            rw_free(out);
            return null;
        }
        bits = (bits << 6) | @as(u32, @intCast(value));
        count += 1;
        if (count == 4) {
            out[written] = @truncate(bits >> 16);
            out[written + 1] = @truncate(bits >> 8);
            out[written + 2] = @truncate(bits);
            written += 3;
            bits = 0;
            count = 0;
        }
    }
    if (count == 3) {
        out[written] = @truncate(bits >> 10);
        out[written + 1] = @truncate(bits >> 2);
        written += 2;
    } else if (count == 2) {
        out[written] = @truncate(bits >> 4);
        written += 1;
    }
    size.* = written;
    return out;
}
