// Translated to Zig from vendor/raven/src/xml/xml_dom.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_dom.c
// Documents that can be edited (Rxml_document_..., Rxml_node_...).
//
// The loader reads a text once and forgets it; a tool needs the tree to stay:
// here each node is an object of its own, with a handle, that can be changed
// and written back. To build widgets the tree is turned into the document of
// the loader, every element carrying the handle of its node (`source`): the
// widgets keep it, which is how a click in a preview finds its node.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context = @import("../core/context_h.zig");
const handle = @import("../core/handle_h.zig");
const fs = @import("../core/fs_h.zig");
const xml = @import("xml_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const libc = @import("../sys/libc.zig");

/// RVN_ARRAY_RESERVE (base_h.RVN_ARRAY_RESERVE does not accept arrays of pointers: `[*c][*c]T` data
/// cannot coerce to ?*anyopaque there). Same logic: grow `data` to `needed` items when `cap` is too small.
fn reserveArray(data: anytype, cap: [*c]u32, needed: u32) void {
    const Item = @typeInfo(@typeInfo(@TypeOf(data)).pointer.child).pointer.child;
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(Item))));
}

const rvn_dom_attribute_t = extern struct {
    name: [*c]u8,
    value: [*c]u8,
};

const rvn_dom_document_t = extern struct {
    id: raven.Rid,
    root: [*c]rvn_dom_node_t,
    /// Comments written before the root.
    prolog: [*c][*c]rvn_dom_node_t,
    prolog_count: u32,
    prolog_cap: u32,
    declaration: c_int,
    /// Folder of the file it was read from: the paths written in it start there.
    file: [*c]u8,
    /// Result of the last ..._to_string.
    string: [*c]u8,
};

const rvn_dom_node_t = extern struct {
    id: raven.Rid,
    document: [*c]rvn_dom_document_t,
    parent: [*c]rvn_dom_node_t,
    children: [*c][*c]rvn_dom_node_t,
    child_count: u32,
    child_cap: u32,
    /// NULL for a comment.
    tag: [*c]u8,
    /// Never NULL.
    text: [*c]u8,
    attributes: [*c]rvn_dom_attribute_t,
    attribute_count: u32,
    attribute_cap: u32,
    line: c_int,
    column: c_int,
    /// What the node became the last time the document was built.
    widget: raven.Rid,
};

const rvn_dom_writer_t = extern struct {
    text: [*c]u8,
    count: u32,
    cap: u32,
    line: c_int,
    column: c_int,
};

fn rvn_dom_document(id: raven.Rid, function: [*c]const u8) [*c]rvn_dom_document_t {
    var document: [*c]rvn_dom_document_t = undefined;
    if (context.rvn_api_check(function) == 0) return null;
    document = @ptrCast(@alignCast(handle.rvn_pool_get(&context.g_rvn.xml_documents, id)));
    if (document == null) base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "%s: invalid document handle 0x%08X", function, @as(c_uint, id));
    return document;
}

fn rvn_dom_node(id: raven.Rid, function: [*c]const u8) [*c]rvn_dom_node_t {
    var node: [*c]rvn_dom_node_t = undefined;
    if (context.rvn_api_check(function) == 0) return null;
    node = @ptrCast(@alignCast(handle.rvn_pool_get(&context.g_rvn.xml_nodes, id)));
    if (node == null) base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "%s: invalid node handle 0x%08X", function, @as(c_uint, id));
    return node;
}

// ---------------------------------------------------------------------------
//  Nodes
// ---------------------------------------------------------------------------

fn rvn_dom_new(document: [*c]rvn_dom_document_t, tag: [*c]const u8, text: [*c]const u8) [*c]rvn_dom_node_t {
    const node: [*c]rvn_dom_node_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_dom_node_t))));
    const text_value: [*c]const u8 = if (text != null) text else "";
    node.*.id = handle.rvn_pool_add(&context.g_rvn.xml_nodes, node);
    if (node.*.id == raven.R_INVALID_ID) {
        base.rvn_error(raven.R_ERROR_OUT_OF_MEMORY, raven.R_SEVERITY_ERROR, "XML document: too many nodes");
        base.rvn_free(node);
        return null;
    }
    node.*.document = document;
    node.*.tag = if (tag != null) base.rvn_strdup(tag) else null;
    node.*.text = base.rvn_strdup(text_value);
    return node;
}

fn rvn_dom_free(node: [*c]rvn_dom_node_t) void {
    var i: u32 = 0;
    while (i < node.*.child_count) : (i += 1) rvn_dom_free(node.*.children[i]);
    i = 0;
    while (i < node.*.attribute_count) : (i += 1) {
        base.rvn_free(node.*.attributes[i].name);
        base.rvn_free(node.*.attributes[i].value);
    }
    handle.rvn_pool_remove(&context.g_rvn.xml_nodes, node.*.id);
    base.rvn_free(@ptrCast(node.*.children));
    base.rvn_free(node.*.attributes);
    base.rvn_free(node.*.tag);
    base.rvn_free(node.*.text);
    base.rvn_free(node);
}

fn rvn_dom_insert(parent: [*c]rvn_dom_node_t, child: [*c]rvn_dom_node_t, index: c_int) void {
    const count_int: c_int = @intCast(parent.*.child_count);
    const at: u32 = if (index < 0 or index > count_int) parent.*.child_count else @intCast(index);
    reserveArray(&parent.*.children, &parent.*.child_cap, parent.*.child_count + 1);
    const arr = parent.*.children;
    _ = libc.memmove(@ptrCast(arr + @as(usize, at) + 1), @ptrCast(arr + @as(usize, at)), @sizeOf([*c]rvn_dom_node_t) * @as(usize, parent.*.child_count - at));
    parent.*.children[at] = child;
    parent.*.child_count += 1;
    child.*.parent = parent;
}

fn rvn_dom_index(node: [*c]const rvn_dom_node_t) c_int {
    var i: u32 = 0;
    if (node.*.parent == null) return 0;
    while (i < node.*.parent.*.child_count) : (i += 1) {
        if (node.*.parent.*.children[i] == node) return @intCast(i);
    }
    return 0;
}

fn rvn_dom_detach(node: [*c]rvn_dom_node_t) void {
    const parent = node.*.parent;
    if (parent == null) return;
    const at: u32 = @intCast(rvn_dom_index(node));
    const arr = parent.*.children;
    _ = libc.memmove(@ptrCast(arr + @as(usize, at)), @ptrCast(arr + @as(usize, at) + 1), @sizeOf([*c]rvn_dom_node_t) * @as(usize, parent.*.child_count - at - 1));
    parent.*.child_count -= 1;
    node.*.parent = null;
}

fn rvn_dom_find_attribute(node: [*c]const rvn_dom_node_t, name: [*c]const u8) [*c]rvn_dom_attribute_t {
    var i: u32 = 0;
    while (i < node.*.attribute_count) : (i += 1) {
        if (base.rvn_stricmp(node.*.attributes[i].name, name) == 0) return &node.*.attributes[i];
    }
    return null;
}

fn rvn_dom_set_attribute(node: [*c]rvn_dom_node_t, name: [*c]const u8, value: [*c]const u8) void {
    var attribute = rvn_dom_find_attribute(node, name);
    if (value == null) {
        if (attribute == null) return;
        base.rvn_free(attribute.*.name);
        base.rvn_free(attribute.*.value);
        const end_ptr = node.*.attributes + @as(usize, node.*.attribute_count);
        const remaining: usize = @intCast(end_ptr - attribute - 1);
        _ = libc.memmove(attribute, attribute + 1, @sizeOf(rvn_dom_attribute_t) * remaining);
        node.*.attribute_count -= 1;
        return;
    }
    if (attribute != null) {
        _ = base.rvn_str_set(&attribute.*.value, value);
        return;
    }
    reserveArray(&node.*.attributes, &node.*.attribute_cap, node.*.attribute_count + 1);
    const index = node.*.attribute_count;
    node.*.attribute_count += 1;
    attribute = &node.*.attributes[index];
    attribute.*.name = base.rvn_strdup(name);
    attribute.*.value = base.rvn_strdup(value);
}

/// Can this be the name of a tag or of an attribute?
fn rvn_dom_is_name(name: [*c]const u8) c_int {
    var cursor: [*c]const u8 = undefined;
    if (name == null or name[0] == 0) return raven.R_FALSE;
    cursor = name;
    while (cursor[0] != 0) : (cursor += 1) {
        const c: u8 = cursor[0];
        const letter = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
        if (!letter and !(cursor > name and ((c >= '0' and c <= '9') or c == '.' or c == '-'))) return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

/// A node, and what is under it, from what the parser read.
fn rvn_dom_from_parsed(document: [*c]rvn_dom_document_t, parsed: [*c]const xml.rvn_xml_node_t) [*c]rvn_dom_node_t {
    const comment = libc.strcmp(parsed.*.name, xml.RVN_XML_COMMENT) == 0;
    const tag: [*c]const u8 = if (comment) null else parsed.*.name;
    const node = rvn_dom_new(document, tag, parsed.*.text);
    var attribute: [*c]const xml.rvn_xml_attribute_t = undefined;
    var child: [*c]const xml.rvn_xml_node_t = undefined;
    if (node == null) return null;
    node.*.line = parsed.*.line;
    node.*.column = parsed.*.column;
    attribute = parsed.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        reserveArray(&node.*.attributes, &node.*.attribute_cap, node.*.attribute_count + 1);
        node.*.attributes[node.*.attribute_count].name = base.rvn_strdup(attribute.*.name);
        node.*.attributes[node.*.attribute_count].value = base.rvn_strdup(attribute.*.value);
        node.*.attribute_count += 1;
    }
    child = parsed.*.first_child;
    while (child != null) : (child = child.*.next) {
        const child_node = rvn_dom_from_parsed(document, child);
        if (child_node != null) rvn_dom_insert(node, child_node, -1);
    }
    return node;
}

fn rvn_dom_copy(source: [*c]const rvn_dom_node_t) [*c]rvn_dom_node_t {
    const node = rvn_dom_new(source.*.document, source.*.tag, source.*.text);
    var i: u32 = 0;
    if (node == null) return null;
    while (i < source.*.attribute_count) : (i += 1) rvn_dom_set_attribute(node, source.*.attributes[i].name, source.*.attributes[i].value);
    i = 0;
    while (i < source.*.child_count) : (i += 1) {
        const child = rvn_dom_copy(source.*.children[i]);
        if (child != null) rvn_dom_insert(node, child, -1);
    }
    return node;
}

// ---------------------------------------------------------------------------
//  Writing
// ---------------------------------------------------------------------------

fn rvn_dom_put(writer: [*c]rvn_dom_writer_t, text: [*c]const u8, length: usize) void {
    var i: usize = 0;
    reserveArray(&writer.*.text, &writer.*.cap, writer.*.count + @as(u32, @intCast(length)) + 1);
    _ = libc.memcpy(writer.*.text + @as(usize, writer.*.count), text, length);
    writer.*.count += @as(u32, @intCast(length));
    writer.*.text[@as(usize, writer.*.count)] = 0;
    while (i < length) : (i += 1) {
        if (text[i] == '\n') {
            writer.*.line += 1;
            writer.*.column = 1;
        } else {
            writer.*.column += 1;
        }
    }
}

fn rvn_dom_puts(writer: [*c]rvn_dom_writer_t, text: [*c]const u8) void {
    rvn_dom_put(writer, text, libc.strlen(text));
}

/// Text with the characters that have a meaning in XML written as entities.
fn rvn_dom_put_escaped(writer: [*c]rvn_dom_writer_t, text: [*c]const u8, attribute: c_int) void {
    var start: [*c]const u8 = text;
    var cursor: [*c]const u8 = text;
    while (cursor[0] != 0) : (cursor += 1) {
        var entity: [*c]const u8 = null;
        if (cursor[0] == '&') {
            entity = "&amp;";
        } else if (cursor[0] == '<') {
            entity = "&lt;";
        } else if (cursor[0] == '>') {
            entity = "&gt;";
        } else if (attribute != 0 and cursor[0] == '"') {
            entity = "&quot;";
        } else if (attribute != 0 and cursor[0] == '\n') {
            entity = "&#10;";
        } else if (attribute != 0 and cursor[0] == '\t') {
            entity = "&#9;";
        }
        if (entity == null) continue;
        rvn_dom_put(writer, start, @intFromPtr(cursor) - @intFromPtr(start));
        rvn_dom_puts(writer, entity);
        start = cursor + 1;
    }
    rvn_dom_put(writer, start, @intFromPtr(cursor) - @intFromPtr(start));
}

fn rvn_dom_indent(writer: [*c]rvn_dom_writer_t, depth: c_int) void {
    var d = depth;
    while (d > 0) : (d -= 1) rvn_dom_put(writer, "\t", 1);
}

fn rvn_dom_write(writer: [*c]rvn_dom_writer_t, node: [*c]rvn_dom_node_t, depth: c_int, track: c_int) void {
    var i: u32 = 0;
    rvn_dom_indent(writer, depth);
    if (track != 0) {
        node.*.line = writer.*.line;
        node.*.column = writer.*.column;
    }
    if (node.*.tag == null) {
        rvn_dom_puts(writer, "<!--");
        rvn_dom_puts(writer, node.*.text);
        rvn_dom_puts(writer, "-->\n");
        return;
    }
    rvn_dom_puts(writer, "<");
    rvn_dom_puts(writer, node.*.tag);
    while (i < node.*.attribute_count) : (i += 1) {
        rvn_dom_puts(writer, " ");
        rvn_dom_puts(writer, node.*.attributes[i].name);
        rvn_dom_puts(writer, "=\"");
        rvn_dom_put_escaped(writer, node.*.attributes[i].value, raven.R_TRUE);
        rvn_dom_puts(writer, "\"");
    }
    if (node.*.child_count == 0 and node.*.text[0] == 0) {
        rvn_dom_puts(writer, "/>\n");
        return;
    }
    rvn_dom_puts(writer, ">");
    if (node.*.child_count == 0) {
        rvn_dom_put_escaped(writer, node.*.text, raven.R_FALSE);
    } else {
        rvn_dom_puts(writer, "\n");
        if (node.*.text[0] != 0) {
            rvn_dom_indent(writer, depth + 1);
            rvn_dom_put_escaped(writer, node.*.text, raven.R_FALSE);
            rvn_dom_puts(writer, "\n");
        }
        i = 0;
        while (i < node.*.child_count) : (i += 1) rvn_dom_write(writer, node.*.children[i], depth + 1, track);
        rvn_dom_indent(writer, depth);
    }
    rvn_dom_puts(writer, "</");
    rvn_dom_puts(writer, node.*.tag);
    rvn_dom_puts(writer, ">\n");
}

// ---------------------------------------------------------------------------
//  Documents
// ---------------------------------------------------------------------------

fn rvn_dom_document_new() [*c]rvn_dom_document_t {
    const document: [*c]rvn_dom_document_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_dom_document_t))));
    document.*.id = handle.rvn_pool_add(&context.g_rvn.xml_documents, document);
    if (document.*.id == raven.R_INVALID_ID) {
        base.rvn_error(raven.R_ERROR_OUT_OF_MEMORY, raven.R_SEVERITY_ERROR, "XML document: too many documents");
        base.rvn_free(document);
        return null;
    }
    return document;
}

fn rvn_dom_document_free(document: [*c]rvn_dom_document_t) void {
    var i: u32 = 0;
    if (document.*.root != null) rvn_dom_free(document.*.root);
    while (i < document.*.prolog_count) : (i += 1) rvn_dom_free(document.*.prolog[i]);
    handle.rvn_pool_remove(&context.g_rvn.xml_documents, document.*.id);
    base.rvn_free(@ptrCast(document.*.prolog));
    base.rvn_free(document.*.file);
    base.rvn_free(document.*.string);
    base.rvn_free(document);
}

export fn rvn_xml_dom_shutdown() void {
    var i: u32 = 0;
    while (i < context.g_rvn.xml_documents.used) : (i += 1) {
        const document: [*c]rvn_dom_document_t = @ptrCast(@alignCast(handle.rvn_pool_at(&context.g_rvn.xml_documents, i)));
        if (document != null) rvn_dom_document_free(document);
    }
}

export fn Rxml_document_create(root_tag: [*c]const u8) raven.Rid {
    var document: [*c]rvn_dom_document_t = undefined;
    if (context.rvn_api_check("Rxml_document_create") == 0) return raven.R_INVALID_ID;
    if (rvn_dom_is_name(root_tag) == 0) {
        const shown: [*c]const u8 = if (root_tag != null) root_tag else "";
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_document_create: \"%.60s\" cannot be the name of a tag", shown);
        return raven.R_INVALID_ID;
    }
    document = rvn_dom_document_new();
    if (document == null) return raven.R_INVALID_ID;
    document.*.root = rvn_dom_new(document, root_tag, "");
    if (document.*.root == null) {
        rvn_dom_document_free(document);
        return raven.R_INVALID_ID;
    }
    return document.*.id;
}

fn rvn_dom_parse(xml_text: [*c]const u8, size: usize, @"error": [*c]raven.RXmlError, function: [*c]const u8) raven.Rid {
    var parsed: xml.rvn_xml_document_t = undefined;
    var document: [*c]rvn_dom_document_t = undefined;
    var comment: [*c]const xml.rvn_xml_node_t = undefined;

    if (@"error" != null) @"error".* = std.mem.zeroes(raven.RXmlError);
    if (xml_text == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: NULL text", function);
        return raven.R_INVALID_ID;
    }
    if (xml.rvn_xml_parse_keeping_comments(&parsed, xml_text, size) == 0) {
        if (@"error" != null) {
            @"error".*.line = parsed.error_line;
            @"error".*.column = parsed.error_column;
            _ = libc.snprintf(&@"error".*.message, @"error".*.message.len, "%s", @as([*c]const u8, &parsed.@"error"));
        } else {
            base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: line %d, column %d: %s", function, parsed.error_line, parsed.error_column, @as([*c]const u8, &parsed.@"error"));
        }
        xml.rvn_xml_free(&parsed);
        return raven.R_INVALID_ID;
    }
    document = rvn_dom_document_new();
    if (document == null) {
        xml.rvn_xml_free(&parsed);
        return raven.R_INVALID_ID;
    }
    document.*.declaration = parsed.has_declaration;
    comment = parsed.prolog;
    while (comment != null) : (comment = comment.*.next) {
        const node = rvn_dom_from_parsed(document, comment);
        if (node == null) continue;
        reserveArray(&document.*.prolog, &document.*.prolog_cap, document.*.prolog_count + 1);
        document.*.prolog[document.*.prolog_count] = node;
        document.*.prolog_count += 1;
    }
    document.*.root = rvn_dom_from_parsed(document, parsed.root);
    xml.rvn_xml_free(&parsed);
    if (document.*.root == null) {
        rvn_dom_document_free(document);
        return raven.R_INVALID_ID;
    }
    return document.*.id;
}

export fn Rxml_document_parse(xml_text: [*c]const u8, size: usize, @"error": [*c]raven.RXmlError) raven.Rid {
    if (context.rvn_api_check("Rxml_document_parse") == 0) return raven.R_INVALID_ID;
    return rvn_dom_parse(xml_text, size, @"error", "Rxml_document_parse");
}

export fn Rxml_document_load(path: [*c]const u8) raven.Rid {
    var size: usize = 0;
    var text: [*c]u8 = undefined;
    var id: raven.Rid = undefined;
    if (context.rvn_api_check("Rxml_document_load") == 0) return raven.R_INVALID_ID;
    text = base.rvn_read_file(path, &size);
    if (text == null) {
        const shown: [*c]const u8 = if (path != null) path else "";
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rxml_document_load: cannot read '%s'", shown);
        return raven.R_INVALID_ID;
    }
    id = rvn_dom_parse(text, size, null, "Rxml_document_load");
    base.rvn_free(text);
    if (id != raven.R_INVALID_ID) {
        const document: [*c]rvn_dom_document_t = @ptrCast(@alignCast(handle.rvn_pool_get(&context.g_rvn.xml_documents, id)));
        document.*.file = base.rvn_strdup(path);
    }
    return id;
}

export fn Rxml_document_destroy(id: raven.Rid) void {
    const document = rvn_dom_document(id, "Rxml_document_destroy");
    if (document != null) rvn_dom_document_free(document);
}

export fn Rxml_document_is_valid(id: raven.Rid) c_int {
    return @intFromBool(context.g_rvn.initialized != 0 and handle.rvn_pool_get(&context.g_rvn.xml_documents, id) != null);
}

export fn Rxml_document_get_root(id: raven.Rid) raven.Rid {
    const document = rvn_dom_document(id, "Rxml_document_get_root");
    return if (document != null) document.*.root.*.id else raven.R_INVALID_ID;
}

export fn Rxml_document_to_string(id: raven.Rid) [*c]const u8 {
    const document = rvn_dom_document(id, "Rxml_document_to_string");
    var writer: rvn_dom_writer_t = undefined;
    var i: u32 = 0;
    if (document == null) return "";
    writer = std.mem.zeroes(rvn_dom_writer_t);
    writer.line = 1;
    writer.column = 1;
    if (document.*.declaration != 0) rvn_dom_puts(&writer, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    while (i < document.*.prolog_count) : (i += 1) rvn_dom_write(&writer, document.*.prolog[i], 0, raven.R_TRUE);
    rvn_dom_write(&writer, document.*.root, 0, raven.R_TRUE);
    base.rvn_free(document.*.string);
    document.*.string = writer.text;
    return document.*.string;
}

export fn Rxml_document_save(id: raven.Rid, path: [*c]const u8) c_int {
    const document = rvn_dom_document(id, "Rxml_document_save");
    var text: [*c]const u8 = undefined;
    if (document == null) return raven.R_FALSE;
    if (path == null or path[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_document_save: no path");
        return raven.R_FALSE;
    }
    text = Rxml_document_to_string(id);
    if (fs.rvn_write_file(path, text, libc.strlen(text)) == 0) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rxml_document_save: cannot write '%s'", path);
        return raven.R_FALSE;
    }
    _ = base.rvn_str_set(&document.*.file, path);
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Building
// ---------------------------------------------------------------------------

/// The element of the loader for a node, with what is under it; comments are left out.
fn rvn_dom_to_parsed(arena: [*c]base.rvn_arena_t, node: [*c]rvn_dom_node_t, parent: [*c]xml.rvn_xml_node_t) [*c]xml.rvn_xml_node_t {
    const parsed: [*c]xml.rvn_xml_node_t = @ptrCast(@alignCast(base.rvn_arena_alloc(arena, @sizeOf(xml.rvn_xml_node_t))));
    var last: [*c]xml.rvn_xml_attribute_t = null;
    var i: u32 = 0;
    parsed.* = std.mem.zeroes(xml.rvn_xml_node_t);
    parsed.*.name = base.rvn_arena_strndup(arena, node.*.tag, libc.strlen(node.*.tag));
    parsed.*.text = base.rvn_arena_strndup(arena, node.*.text, libc.strlen(node.*.text));
    parsed.*.parent = parent;
    parsed.*.line = node.*.line;
    parsed.*.column = node.*.column;
    parsed.*.source = node.*.id;
    node.*.widget = raven.R_INVALID_ID;
    while (i < node.*.attribute_count) : (i += 1) {
        const attribute: [*c]xml.rvn_xml_attribute_t = @ptrCast(@alignCast(base.rvn_arena_alloc(arena, @sizeOf(xml.rvn_xml_attribute_t))));
        attribute.*.name = base.rvn_arena_strndup(arena, node.*.attributes[i].name, libc.strlen(node.*.attributes[i].name));
        attribute.*.value = base.rvn_arena_strndup(arena, node.*.attributes[i].value, libc.strlen(node.*.attributes[i].value));
        attribute.*.next = null;
        if (last != null) {
            last.*.next = attribute;
        } else {
            parsed.*.attributes = attribute;
        }
        last = attribute;
    }
    i = 0;
    while (i < node.*.child_count) : (i += 1) {
        if (node.*.children[i].*.tag == null) continue;
        const child = rvn_dom_to_parsed(arena, node.*.children[i], parsed);
        if (parsed.*.last_child != null) {
            parsed.*.last_child.*.next = child;
        } else {
            parsed.*.first_child = child;
        }
        parsed.*.last_child = child;
    }
    return parsed;
}

/// Each node learns the first widget that was built from it: for a declared tag, the widget it stands for.
fn rvn_dom_bind(document: [*c]rvn_dom_document_t, widget: [*c]widget_h.rvn_widget_t) void {
    const node: [*c]rvn_dom_node_t = if (widget.*.xml_node != 0) @ptrCast(@alignCast(handle.rvn_pool_get(&context.g_rvn.xml_nodes, widget.*.xml_node))) else null;
    var i: u32 = 0;
    if (node != null and node.*.document == document and node.*.widget == raven.R_INVALID_ID) node.*.widget = widget.*.id;
    while (i < widget.*.child_count) : (i += 1) rvn_dom_bind(document, widget.*.children[i]);
}

fn rvn_dom_build(document: [*c]rvn_dom_document_t, window: c_int, function: [*c]const u8) raven.Rid {
    var parsed: xml.rvn_xml_document_t = undefined;
    var previous_dir: [*c]u8 = undefined;
    var result: raven.Rid = raven.R_INVALID_ID;

    parsed = std.mem.zeroes(xml.rvn_xml_document_t);
    base.rvn_arena_init(&parsed.arena, 16384);
    parsed.root = rvn_dom_to_parsed(&parsed.arena, document.*.root, null);
    xml.rvn_xml_push_file_dir(document.*.file, &previous_dir);
    if (xml.rvn_xml_expand(&parsed, null) == 0) {
        xml.rvn_xml_free(&parsed);
    } else if (parsed.root == null) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: the document declares widgets but contains nothing to create", function);
        xml.rvn_xml_free(&parsed);
    } else if (window != 0) {
        var built: [*c]widget_h.rvn_window_t = undefined;
        result = xml.rvn_xml_build_window(&parsed, function);
        built = widget_h.rvn_window_get(result);
        if (built != null) {
            document.*.root.*.widget = result;
            if (built.*.root != null) rvn_dom_bind(document, built.*.root);
            if (built.*.island != null) rvn_dom_bind(document, built.*.island);
        }
    } else {
        var built: [*c]widget_h.rvn_widget_t = undefined;
        result = xml.rvn_xml_build_widget(&parsed, raven.R_TRUE, function);
        built = widget_h.rvn_widget_get(result);
        if (built != null) rvn_dom_bind(document, built);
    }
    xml.rvn_xml_pop_file_dir(previous_dir);
    return result;
}

export fn Rxml_document_create_widget(id: raven.Rid) raven.Rid {
    const document = rvn_dom_document(id, "Rxml_document_create_widget");
    return if (document != null) rvn_dom_build(document, raven.R_FALSE, "Rxml_document_create_widget") else raven.R_INVALID_ID;
}

export fn Rxml_document_create_window(id: raven.Rid) raven.Rid {
    const document = rvn_dom_document(id, "Rxml_document_create_window");
    return if (document != null) rvn_dom_build(document, raven.R_TRUE, "Rxml_document_create_window") else raven.R_INVALID_ID;
}

export fn Rxml_node_get_widget(id: raven.Rid) raven.Rid {
    const node = rvn_dom_node(id, "Rxml_node_get_widget");
    if (node == null or node.*.widget == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    if (widget_h.rvn_widget_get(node.*.widget) == null and widget_h.rvn_window_get(node.*.widget) == null) return raven.R_INVALID_ID;
    return node.*.widget;
}

export fn Rwidget_get_xml_node(id: raven.Rid) raven.Rid {
    var widget: [*c]widget_h.rvn_widget_t = undefined;
    if (context.rvn_api_check("Rwidget_get_xml_node") == 0) return raven.R_INVALID_ID;
    // (R_INVALID_ID is what a hit test gives when nothing is there: not an error)
    if (id == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_xml_node");
    if (widget == null or widget.*.xml_node == 0 or handle.rvn_pool_get(&context.g_rvn.xml_nodes, widget.*.xml_node) == null) return raven.R_INVALID_ID;
    return widget.*.xml_node;
}

// ---------------------------------------------------------------------------
//  Nodes: public API
// ---------------------------------------------------------------------------

export fn Rxml_node_is_valid(id: raven.Rid) c_int {
    return @intFromBool(context.g_rvn.initialized != 0 and handle.rvn_pool_get(&context.g_rvn.xml_nodes, id) != null);
}

export fn Rxml_node_get_document(id: raven.Rid) raven.Rid {
    const node = rvn_dom_node(id, "Rxml_node_get_document");
    return if (node != null) node.*.document.*.id else raven.R_INVALID_ID;
}

export fn Rxml_node_get_tag(id: raven.Rid) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_get_tag");
    if (node != null and node.*.tag != null) return node.*.tag;
    return "";
}

export fn Rxml_node_set_tag(id: raven.Rid, tag: [*c]const u8) void {
    const node = rvn_dom_node(id, "Rxml_node_set_tag");
    if (node == null) return;
    if (node.*.tag == null or rvn_dom_is_name(tag) == 0) {
        const fmt: [*c]const u8 = if (node.*.tag != null) "Rxml_node_set_tag: \"%.60s\" cannot be the name of a tag" else "Rxml_node_set_tag: a comment has no tag%.0s";
        const shown: [*c]const u8 = if (tag != null) tag else "";
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, fmt, shown);
        return;
    }
    _ = base.rvn_str_set(&node.*.tag, tag);
}

export fn Rxml_node_is_comment(id: raven.Rid) c_int {
    const node = rvn_dom_node(id, "Rxml_node_is_comment");
    return @intFromBool(node != null and node.*.tag == null);
}

export fn Rxml_node_get_text(id: raven.Rid) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_get_text");
    if (node != null) return node.*.text;
    return "";
}

export fn Rxml_node_set_text(id: raven.Rid, text_arg: [*c]const u8) void {
    const node = rvn_dom_node(id, "Rxml_node_set_text");
    var text: [*c]const u8 = text_arg;
    if (node == null) return;
    if (text == null) text = "";
    if (node.*.tag == null and libc.strstr(text, "--") != null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_node_set_text: a comment cannot contain \"--\"");
        return;
    }
    _ = base.rvn_str_set(&node.*.text, text);
    if (node.*.text == null) node.*.text = base.rvn_strdup("");
}

export fn Rxml_node_get_parent(id: raven.Rid) raven.Rid {
    const node = rvn_dom_node(id, "Rxml_node_get_parent");
    if (node != null and node.*.parent != null) return node.*.parent.*.id;
    return raven.R_INVALID_ID;
}

export fn Rxml_node_get_child_count(id: raven.Rid) c_int {
    const node = rvn_dom_node(id, "Rxml_node_get_child_count");
    return if (node != null) @as(c_int, @intCast(node.*.child_count)) else 0;
}

export fn Rxml_node_get_child(id: raven.Rid, index: c_int) raven.Rid {
    const node = rvn_dom_node(id, "Rxml_node_get_child");
    if (node == null or index < 0 or index >= @as(c_int, @intCast(node.*.child_count))) return raven.R_INVALID_ID;
    return node.*.children[@intCast(index)].*.id;
}

export fn Rxml_node_get_index(id: raven.Rid) c_int {
    const node = rvn_dom_node(id, "Rxml_node_get_index");
    return if (node != null) rvn_dom_index(node) else 0;
}

/// The parent of a node about to be added: an element of a document.
fn rvn_dom_parent(id: raven.Rid, function: [*c]const u8) [*c]rvn_dom_node_t {
    const parent = rvn_dom_node(id, function);
    if (parent != null and parent.*.tag == null) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: a comment cannot contain anything", function);
        return null;
    }
    // (the comments before the root have no parent and take no children either)
    return parent;
}

export fn Rxml_node_add_child(parent_id: raven.Rid, tag: [*c]const u8, index: c_int) raven.Rid {
    const parent = rvn_dom_parent(parent_id, "Rxml_node_add_child");
    var node: [*c]rvn_dom_node_t = undefined;
    if (parent == null) return raven.R_INVALID_ID;
    if (rvn_dom_is_name(tag) == 0) {
        const shown: [*c]const u8 = if (tag != null) tag else "";
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_node_add_child: \"%.60s\" cannot be the name of a tag", shown);
        return raven.R_INVALID_ID;
    }
    node = rvn_dom_new(parent.*.document, tag, "");
    if (node == null) return raven.R_INVALID_ID;
    rvn_dom_insert(parent, node, index);
    return node.*.id;
}

export fn Rxml_node_add_comment(parent_id: raven.Rid, text: [*c]const u8, index: c_int) raven.Rid {
    const parent = rvn_dom_parent(parent_id, "Rxml_node_add_comment");
    var node: [*c]rvn_dom_node_t = undefined;
    if (parent == null) return raven.R_INVALID_ID;
    if (text != null and libc.strstr(text, "--") != null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_node_add_comment: a comment cannot contain \"--\"");
        return raven.R_INVALID_ID;
    }
    node = rvn_dom_new(parent.*.document, null, text);
    if (node == null) return raven.R_INVALID_ID;
    rvn_dom_insert(parent, node, index);
    return node.*.id;
}

export fn Rxml_node_add_xml(parent_id: raven.Rid, xml_text: [*c]const u8, size: usize, index: c_int) raven.Rid {
    const parent = rvn_dom_parent(parent_id, "Rxml_node_add_xml");
    var parsed: xml.rvn_xml_document_t = undefined;
    var node: [*c]rvn_dom_node_t = undefined;
    if (parent == null) return raven.R_INVALID_ID;
    if (xml_text == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_node_add_xml: NULL text");
        return raven.R_INVALID_ID;
    }
    if (xml.rvn_xml_parse_keeping_comments(&parsed, xml_text, size) == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "Rxml_node_add_xml: line %d, column %d: %s", parsed.error_line, parsed.error_column, @as([*c]const u8, &parsed.@"error"));
        xml.rvn_xml_free(&parsed);
        return raven.R_INVALID_ID;
    }
    node = rvn_dom_from_parsed(parent.*.document, parsed.root);
    xml.rvn_xml_free(&parsed);
    if (node == null) return raven.R_INVALID_ID;
    // (its lines were those of the piece of text, not of the document)
    node.*.line = 0;
    node.*.column = 0;
    rvn_dom_insert(parent, node, index);
    return node.*.id;
}

export fn Rxml_node_remove(id: raven.Rid) void {
    const node = rvn_dom_node(id, "Rxml_node_remove");
    if (node == null) return;
    if (node.*.parent == null) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rxml_node_remove: the root of a document cannot be removed");
        return;
    }
    rvn_dom_detach(node);
    rvn_dom_free(node);
}

export fn Rxml_node_move(id: raven.Rid, new_parent_id: raven.Rid, index: c_int) c_int {
    const node = rvn_dom_node(id, "Rxml_node_move");
    const parent: [*c]rvn_dom_node_t = if (node != null) rvn_dom_parent(new_parent_id, "Rxml_node_move") else null;
    var walk: [*c]rvn_dom_node_t = undefined;
    if (node == null or parent == null or node.*.parent == null or parent.*.document != node.*.document) return raven.R_FALSE;
    walk = parent;
    while (walk != null) : (walk = walk.*.parent) {
        if (walk == node) return raven.R_FALSE;
    }
    rvn_dom_detach(node);
    rvn_dom_insert(parent, node, index);
    return raven.R_TRUE;
}

export fn Rxml_node_duplicate(id: raven.Rid) raven.Rid {
    const node = rvn_dom_node(id, "Rxml_node_duplicate");
    var copy: [*c]rvn_dom_node_t = undefined;
    if (node == null) return raven.R_INVALID_ID;
    if (node.*.parent == null) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rxml_node_duplicate: a document has a single root");
        return raven.R_INVALID_ID;
    }
    copy = rvn_dom_copy(node);
    if (copy == null) return raven.R_INVALID_ID;
    rvn_dom_insert(node.*.parent, copy, rvn_dom_index(node) + 1);
    return copy.*.id;
}

export fn Rxml_node_to_string(id: raven.Rid) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_to_string");
    var writer: rvn_dom_writer_t = undefined;
    if (node == null) return "";
    writer = std.mem.zeroes(rvn_dom_writer_t);
    rvn_dom_write(&writer, node, 0, raven.R_FALSE);
    base.rvn_free(node.*.document.*.string);
    node.*.document.*.string = writer.text;
    return writer.text;
}

export fn Rxml_node_get_attribute_count(id: raven.Rid) c_int {
    const node = rvn_dom_node(id, "Rxml_node_get_attribute_count");
    return if (node != null) @as(c_int, @intCast(node.*.attribute_count)) else 0;
}

export fn Rxml_node_get_attribute_name(id: raven.Rid, index: c_int) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_get_attribute_name");
    if (node == null or index < 0 or index >= @as(c_int, @intCast(node.*.attribute_count))) return null;
    return node.*.attributes[@intCast(index)].name;
}

export fn Rxml_node_get_attribute_value(id: raven.Rid, index: c_int) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_get_attribute_value");
    if (node == null or index < 0 or index >= @as(c_int, @intCast(node.*.attribute_count))) return null;
    return node.*.attributes[@intCast(index)].value;
}

export fn Rxml_node_get_attribute(id: raven.Rid, name: [*c]const u8) [*c]const u8 {
    const node = rvn_dom_node(id, "Rxml_node_get_attribute");
    const attribute: [*c]rvn_dom_attribute_t = if (node != null and name != null) rvn_dom_find_attribute(node, name) else null;
    return if (attribute != null) attribute.*.value else null;
}

export fn Rxml_node_set_attribute(id: raven.Rid, name: [*c]const u8, value: [*c]const u8) void {
    const node = rvn_dom_node(id, "Rxml_node_set_attribute");
    if (node == null) return;
    if (node.*.tag == null or rvn_dom_is_name(name) == 0) {
        const fmt: [*c]const u8 = if (node.*.tag != null) "Rxml_node_set_attribute: \"%.60s\" cannot be the name of an attribute" else "Rxml_node_set_attribute: a comment has no attributes%.0s";
        const shown: [*c]const u8 = if (name != null) name else "";
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, fmt, shown);
        return;
    }
    rvn_dom_set_attribute(node, name, value);
}

export fn Rxml_node_get_line(id: raven.Rid) c_int {
    const node = rvn_dom_node(id, "Rxml_node_get_line");
    return if (node != null) node.*.line else 0;
}
