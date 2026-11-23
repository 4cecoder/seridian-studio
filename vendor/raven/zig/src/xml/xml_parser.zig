// Translated to Zig from vendor/raven/src/xml/xml_parser.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_parser.c
// Recursive-descent XML reader.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const xml = @import("xml_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_XML_MAX_DEPTH = 256;

const rvn_xml_reader_t = struct {
    document: [*c]xml.rvn_xml_document_t,
    cursor: [*c]const u8,
    end: [*c]const u8,
    line: c_int,
    column: c_int,
    failed: c_int,
    /// scratch buffer for decoded text and attribute values
    buffer: [*c]u8,
    buffer_count: u32,
    buffer_cap: u32,
};

// ---------------------------------------------------------------------------
//  Reading
// ---------------------------------------------------------------------------

fn rvn_xml_fail(reader: *rvn_xml_reader_t, message: [*c]const u8) void {
    if (reader.failed != 0) return;
    reader.failed = raven.R_TRUE;
    _ = libc.snprintf(&reader.document.*.@"error", reader.document.*.@"error".len, "%s", message);
    reader.document.*.error_line = reader.line;
    reader.document.*.error_column = reader.column;
}

fn rvn_xml_eof(reader: *const rvn_xml_reader_t) c_int {
    return @intFromBool(reader.cursor >= reader.end);
}

fn rvn_xml_peek(reader: *const rvn_xml_reader_t) u8 {
    return if (reader.cursor < reader.end) reader.cursor[0] else 0;
}

fn rvn_xml_advance(reader: *rvn_xml_reader_t) void {
    if (reader.cursor >= reader.end) return;
    if (reader.cursor[0] == '\n') {
        reader.line += 1;
        reader.column = 1;
    } else if ((reader.cursor[0] & 0xC0) != 0x80) {
        // count characters, not bytes
        reader.column += 1;
    }
    reader.cursor += 1;
}

fn rvn_xml_starts_with(reader: *const rvn_xml_reader_t, literal: [*c]const u8) c_int {
    const length = libc.strlen(literal);
    return @intFromBool(@as(usize, @intCast(reader.end - reader.cursor)) >= length and libc.memcmp(reader.cursor, literal, length) == 0);
}

fn rvn_xml_skip(reader: *rvn_xml_reader_t, count: usize) void {
    var remaining = count;
    while (remaining > 0) {
        remaining -= 1;
        rvn_xml_advance(reader);
    }
}

fn rvn_xml_is_space(c: u8) c_int {
    return @intFromBool(c == ' ' or c == '\t' or c == '\r' or c == '\n');
}

fn rvn_xml_skip_space(reader: *rvn_xml_reader_t) void {
    while (rvn_xml_eof(reader) == 0 and rvn_xml_is_space(reader.cursor[0]) != 0) rvn_xml_advance(reader);
}

/// Skips to just after `terminator`. Returns R_FALSE when it is missing.
fn rvn_xml_skip_until(reader: *rvn_xml_reader_t, terminator: [*c]const u8) c_int {
    while (rvn_xml_eof(reader) == 0) {
        if (rvn_xml_starts_with(reader, terminator) != 0) {
            rvn_xml_skip(reader, libc.strlen(terminator));
            return raven.R_TRUE;
        }
        rvn_xml_advance(reader);
    }
    return raven.R_FALSE;
}

fn rvn_xml_is_name_char(c: u8) c_int {
    const u = c;
    return @intFromBool((u >= 'a' and u <= 'z') or (u >= 'A' and u <= 'Z') or (u >= '0' and u <= '9') or
        u == '_' or u == '-' or u == '.' or u == ':' or u >= 0x80);
}

fn rvn_xml_read_name(reader: *rvn_xml_reader_t) [*c]const u8 {
    const start = reader.cursor;
    while (rvn_xml_eof(reader) == 0 and rvn_xml_is_name_char(reader.cursor[0]) != 0) rvn_xml_advance(reader);
    if (reader.cursor == start) {
        rvn_xml_fail(reader, "expected a name");
        return "";
    }
    return base.rvn_arena_strndup(&reader.document.*.arena, start, @intCast(reader.cursor - start));
}

// ---------------------------------------------------------------------------
//  Scratch buffer
// ---------------------------------------------------------------------------

fn rvn_xml_buffer_push(reader: *rvn_xml_reader_t, bytes: [*c]const u8, count: usize) void {
    base.RVN_ARRAY_RESERVE(&reader.buffer, &reader.buffer_cap, reader.buffer_count + @as(u32, @intCast(count)) + 1);
    _ = libc.memcpy(reader.buffer + @as(usize, reader.buffer_count), bytes, count);
    reader.buffer_count += @as(u32, @intCast(count));
}

/// Decodes "&name;" at the cursor into the buffer.
fn rvn_xml_read_entity(reader: *rvn_xml_reader_t) void {
    const named = [_]struct { name: [*c]const u8, value: u8 }{
        .{ .name = "&lt;", .value = '<' },
        .{ .name = "&gt;", .value = '>' },
        .{ .name = "&amp;", .value = '&' },
        .{ .name = "&quot;", .value = '"' },
        .{ .name = "&apos;", .value = '\'' },
    };
    for (0..named.len) |i| {
        if (rvn_xml_starts_with(reader, named[i].name) != 0) {
            rvn_xml_buffer_push(reader, &named[i].value, 1);
            rvn_xml_skip(reader, libc.strlen(named[i].name));
            return;
        }
    }
    if (rvn_xml_starts_with(reader, "&#") != 0) {
        var p: [*c]const u8 = reader.cursor + 2;
        var codepoint: u32 = 0;
        var digits: c_int = 0;
        var hex: c_int = 0;
        var encoded: [4]u8 = undefined;
        if (p < reader.end and (p[0] == 'x' or p[0] == 'X')) {
            hex = 1;
            p += 1;
        }
        while (p < reader.end and p[0] != ';' and digits < 8) {
            const c = p[0];
            const digit: u32 = if (c >= '0' and c <= '9')
                @as(u32, c - '0')
            else if (hex != 0 and c >= 'a' and c <= 'f')
                @as(u32, c - 'a') + 10
            else if (hex != 0 and c >= 'A' and c <= 'F')
                @as(u32, c - 'A') + 10
            else
                break;
            codepoint = codepoint * (if (hex != 0) @as(u32, 16) else 10) + digit;
            digits += 1;
            p += 1;
        }
        if (digits > 0 and p < reader.end and p[0] == ';' and codepoint > 0 and codepoint <= 0x10FFFF) {
            rvn_xml_buffer_push(reader, &encoded, @intCast(base.rvn_utf8_encode(codepoint, &encoded)));
            rvn_xml_skip(reader, @intCast(p + 1 - reader.cursor));
            return;
        }
    }
    rvn_xml_fail(reader, "unknown entity");
}

// ---------------------------------------------------------------------------
//  Grammar
// ---------------------------------------------------------------------------

fn rvn_xml_read_attributes(reader: *rvn_xml_reader_t, node: [*c]xml.rvn_xml_node_t) void {
    var last: [*c]xml.rvn_xml_attribute_t = null;
    while (true) {
        rvn_xml_skip_space(reader);
        if (rvn_xml_eof(reader) != 0 or rvn_xml_peek(reader) == '>' or rvn_xml_peek(reader) == '/' or reader.failed != 0) return;

        const attribute: [*c]xml.rvn_xml_attribute_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&reader.document.*.arena, @sizeOf(xml.rvn_xml_attribute_t))));
        attribute.*.next = null;
        attribute.*.value = "";
        attribute.*.name = rvn_xml_read_name(reader);
        if (reader.failed != 0) return;

        rvn_xml_skip_space(reader);
        if (rvn_xml_peek(reader) != '=') {
            rvn_xml_fail(reader, "expected '=' after the attribute name");
            return;
        }
        rvn_xml_advance(reader);
        rvn_xml_skip_space(reader);
        const quote = rvn_xml_peek(reader);
        if (quote != '"' and quote != '\'') {
            rvn_xml_fail(reader, "attribute values must be quoted");
            return;
        }
        rvn_xml_advance(reader);

        reader.buffer_count = 0;
        while (rvn_xml_eof(reader) == 0 and rvn_xml_peek(reader) != quote and reader.failed == 0) {
            if (rvn_xml_peek(reader) == '&') {
                rvn_xml_read_entity(reader);
            } else if (rvn_xml_peek(reader) == '<') {
                rvn_xml_fail(reader, "'<' is not allowed in an attribute value");
            } else {
                rvn_xml_buffer_push(reader, reader.cursor, 1);
                rvn_xml_advance(reader);
            }
        }
        if (reader.failed != 0) return;
        if (rvn_xml_eof(reader) != 0) {
            rvn_xml_fail(reader, "unterminated attribute value");
            return;
        }
        rvn_xml_advance(reader);
        const bytes: [*c]const u8 = if (reader.buffer != null) reader.buffer else "";
        attribute.*.value = base.rvn_arena_strndup(&reader.document.*.arena, bytes, reader.buffer_count);

        if (last != null) {
            last.*.next = attribute;
        } else {
            node.*.attributes = attribute;
        }
        last = attribute;
    }
}

fn rvn_xml_trim(reader: *rvn_xml_reader_t, text: [*c]const u8, length: usize) [*c]u8 {
    var text_ = text;
    var length_ = length;
    while (length_ > 0 and rvn_xml_is_space(text_[0]) != 0) {
        text_ += 1;
        length_ -= 1;
    }
    while (length_ > 0 and rvn_xml_is_space(text_[length_ - 1]) != 0) length_ -= 1;
    return base.rvn_arena_strndup(&reader.document.*.arena, text_, length_);
}

/// Skips a comment; returns a node that holds it when the document keeps its comments.
fn rvn_xml_read_comment(reader: *rvn_xml_reader_t, parent: [*c]xml.rvn_xml_node_t) [*c]xml.rvn_xml_node_t {
    const line = reader.line;
    const column = reader.column;
    rvn_xml_skip(reader, 4);
    const start = reader.cursor;
    if (rvn_xml_skip_until(reader, "-->") == 0) {
        rvn_xml_fail(reader, "unterminated comment");
        return null;
    }
    if (reader.document.*.keep_comments == 0) return null;
    const node: [*c]xml.rvn_xml_node_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&reader.document.*.arena, @sizeOf(xml.rvn_xml_node_t))));
    _ = libc.memset(node, 0, @sizeOf(xml.rvn_xml_node_t));
    node.*.name = xml.RVN_XML_COMMENT;
    node.*.text = base.rvn_arena_strndup(&reader.document.*.arena, start, @intCast(reader.cursor - 3 - start));
    node.*.parent = parent;
    node.*.line = line;
    node.*.column = column;
    return node;
}

fn rvn_xml_read_element(reader: *rvn_xml_reader_t, parent: [*c]xml.rvn_xml_node_t, depth: c_int) [*c]xml.rvn_xml_node_t {
    var text: [*c]u8 = null;
    var text_count: u32 = 0;
    var text_cap: u32 = 0;

    if (depth > RVN_XML_MAX_DEPTH) {
        rvn_xml_fail(reader, "elements are nested too deeply");
        return null;
    }
    const node: [*c]xml.rvn_xml_node_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&reader.document.*.arena, @sizeOf(xml.rvn_xml_node_t))));
    _ = libc.memset(node, 0, @sizeOf(xml.rvn_xml_node_t));
    node.*.text = "";
    node.*.parent = parent;
    node.*.line = reader.line;
    node.*.column = reader.column;

    rvn_xml_advance(reader); // '<'
    node.*.name = rvn_xml_read_name(reader);
    rvn_xml_read_attributes(reader, node);
    if (reader.failed != 0) return null;

    if (rvn_xml_starts_with(reader, "/>") != 0) {
        rvn_xml_skip(reader, 2);
        return node;
    }
    if (rvn_xml_peek(reader) != '>') {
        rvn_xml_fail(reader, "expected '>' to close the tag");
        return null;
    }
    rvn_xml_advance(reader);

    // content: text, child elements, comments, CDATA, until the closing tag
    while (reader.failed == 0) {
        if (rvn_xml_eof(reader) != 0) {
            rvn_xml_fail(reader, "missing closing tag");
            break;
        }
        if (rvn_xml_starts_with(reader, "<!--") != 0) {
            const comment = rvn_xml_read_comment(reader, node);
            if (comment != null) {
                if (node.*.last_child != null) {
                    node.*.last_child.*.next = comment;
                } else {
                    node.*.first_child = comment;
                }
                node.*.last_child = comment;
            }
        } else if (rvn_xml_starts_with(reader, "<![CDATA[") != 0) {
            rvn_xml_skip(reader, 9);
            const start = reader.cursor;
            if (rvn_xml_skip_until(reader, "]]>") == 0) {
                rvn_xml_fail(reader, "unterminated CDATA section");
            } else {
                const length: usize = @intCast(reader.cursor - 3 - start);
                base.RVN_ARRAY_RESERVE(&text, &text_cap, text_count + @as(u32, @intCast(length)) + 1);
                _ = libc.memcpy(text + @as(usize, text_count), start, length);
                text_count += @as(u32, @intCast(length));
            }
        } else if (rvn_xml_starts_with(reader, "</") != 0) {
            rvn_xml_skip(reader, 2);
            const name = rvn_xml_read_name(reader);
            rvn_xml_skip_space(reader);
            if (reader.failed == 0 and libc.strcmp(name, node.*.name) != 0) {
                var message: [160]u8 = undefined;
                _ = libc.snprintf(&message, message.len, "closing tag </%.40s> does not match <%.40s>", name, node.*.name);
                rvn_xml_fail(reader, &message);
            } else if (reader.failed == 0 and rvn_xml_peek(reader) != '>') {
                rvn_xml_fail(reader, "expected '>' to close the tag");
            } else {
                rvn_xml_advance(reader);
            }
            break;
        } else if (rvn_xml_starts_with(reader, "<?") != 0) {
            if (rvn_xml_skip_until(reader, "?>") == 0) rvn_xml_fail(reader, "unterminated processing instruction");
        } else if (rvn_xml_peek(reader) == '<') {
            const child = rvn_xml_read_element(reader, node, depth + 1);
            if (child != null) {
                if (node.*.last_child != null) {
                    node.*.last_child.*.next = child;
                } else {
                    node.*.first_child = child;
                }
                node.*.last_child = child;
            }
        } else if (rvn_xml_peek(reader) == '&') {
            reader.buffer_count = 0;
            rvn_xml_read_entity(reader);
            if (reader.failed == 0) {
                base.RVN_ARRAY_RESERVE(&text, &text_cap, text_count + reader.buffer_count + 1);
                _ = libc.memcpy(text + @as(usize, text_count), reader.buffer, reader.buffer_count);
                text_count += reader.buffer_count;
            }
        } else {
            base.RVN_ARRAY_RESERVE(&text, &text_cap, text_count + 2);
            text[text_count] = reader.cursor[0];
            text_count += 1;
            rvn_xml_advance(reader);
        }
    }
    if (text_count > 0 and reader.failed == 0) node.*.text = rvn_xml_trim(reader, text, text_count);
    base.rvn_free(text);
    return if (reader.failed != 0) null else node;
}

fn rvn_xml_parse_with(document: [*c]xml.rvn_xml_document_t, text: [*c]const u8, size: usize, keep_comments: c_int) c_int {
    var reader: rvn_xml_reader_t = undefined;

    _ = libc.memset(document, 0, @sizeOf(xml.rvn_xml_document_t));
    document.*.keep_comments = keep_comments;
    base.rvn_arena_init(&document.*.arena, 16384);
    _ = libc.memset(&reader, 0, @sizeOf(rvn_xml_reader_t));
    reader.document = document;
    reader.cursor = if (text != null) text else @as([*c]const u8, "");
    reader.end = reader.cursor + (if (text != null) size else 0);
    reader.line = 1;
    reader.column = 1;

    // UTF-8 byte order mark
    if (rvn_xml_starts_with(&reader, "\xEF\xBB\xBF") != 0) reader.cursor += 3;

    // prolog: declaration, comments, doctype
    while (true) {
        rvn_xml_skip_space(&reader);
        if (rvn_xml_starts_with(&reader, "<?") != 0) {
            if (rvn_xml_starts_with(&reader, "<?xml") != 0) document.*.has_declaration = raven.R_TRUE;
            if (rvn_xml_skip_until(&reader, "?>") == 0) rvn_xml_fail(&reader, "unterminated XML declaration");
        } else if (rvn_xml_starts_with(&reader, "<!--") != 0) {
            const comment = rvn_xml_read_comment(&reader, null);
            if (comment != null) {
                if (document.*.prolog_last != null) {
                    document.*.prolog_last.*.next = comment;
                } else {
                    document.*.prolog = comment;
                }
                document.*.prolog_last = comment;
            }
        } else if (rvn_xml_starts_with(&reader, "<!") != 0) {
            if (rvn_xml_skip_until(&reader, ">") == 0) rvn_xml_fail(&reader, "unterminated declaration");
        } else {
            break;
        }
        if (reader.failed != 0) break;
    }

    if (reader.failed == 0) {
        if (rvn_xml_peek(&reader) != '<') {
            rvn_xml_fail(&reader, "expected a root element");
        } else {
            document.*.root = rvn_xml_read_element(&reader, null, 0);
        }
    }
    if (reader.failed == 0) {
        // only comments and white space may follow the root element
        while (true) {
            rvn_xml_skip_space(&reader);
            if (rvn_xml_starts_with(&reader, "<!--") != 0) {
                // (a comment after the root is not kept: nothing would hold it)
                rvn_xml_skip(&reader, 4);
                if (rvn_xml_skip_until(&reader, "-->") == 0) rvn_xml_fail(&reader, "unterminated comment");
            } else {
                break;
            }
            if (reader.failed != 0) break;
        }
        if (reader.failed == 0 and rvn_xml_eof(&reader) == 0) rvn_xml_fail(&reader, "unexpected content after the root element");
    }

    base.rvn_free(reader.buffer);
    if (reader.failed != 0) {
        document.*.root = null;
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_xml_parse(document: [*c]xml.rvn_xml_document_t, text: [*c]const u8, size: usize) c_int {
    return rvn_xml_parse_with(document, text, size, raven.R_FALSE);
}

export fn rvn_xml_parse_keeping_comments(document: [*c]xml.rvn_xml_document_t, text: [*c]const u8, size: usize) c_int {
    return rvn_xml_parse_with(document, text, size, raven.R_TRUE);
}

export fn rvn_xml_free(document: [*c]xml.rvn_xml_document_t) void {
    base.rvn_arena_free(&document.*.arena);
    document.*.root = null;
}

export fn rvn_xml_attribute(node: [*c]const xml.rvn_xml_node_t, name: [*c]const u8) [*c]const u8 {
    var attribute: [*c]const xml.rvn_xml_attribute_t = node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (base.rvn_stricmp(attribute.*.name, name) == 0) return attribute.*.value;
    }
    return null;
}
