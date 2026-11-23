// Translated to Zig from vendor/raven/src/xml/xml_compiled.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_compiled.c
// Interfaces compiled by ravenc: a table of elements becomes the same tree
// the parser would make, then goes through the same expansion and building
// as an interpreted document. No XML is read at run time.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const xml_h = @import("xml_h.zig");

fn rvn_xml_from_compiled(document: [*c]xml_h.rvn_xml_document_t, nodes: [*c]const raven.RXmlCompiledNode, count: c_int, source: [*c]const u8, function: [*c]const u8) c_int {
    var made: [*c][*c]xml_h.rvn_xml_node_t = undefined;
    var i: c_int = 0;
    var j: c_int = 0;
    const source_name: [*c]const u8 = if (source != null) source else "?";

    document.* = std.mem.zeroes(xml_h.rvn_xml_document_t);
    base.rvn_arena_init(&document.*.arena, 16384);
    if (nodes == null or count <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: empty table (%s)", function, source_name);
        return raven.R_FALSE;
    }
    made = @ptrCast(@alignCast(base.rvn_arena_alloc(&document.*.arena, @sizeOf([*c]xml_h.rvn_xml_node_t) * @as(usize, @intCast(count)))));
    while (i < count) : (i += 1) {
        const in = &nodes[@intCast(i)];
        const node: [*c]xml_h.rvn_xml_node_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&document.*.arena, @sizeOf(xml_h.rvn_xml_node_t))));
        var last: [*c]xml_h.rvn_xml_attribute_t = null;
        node.* = std.mem.zeroes(xml_h.rvn_xml_node_t);
        if (in.tag == null or in.parent >= i or (i > 0 and in.parent < 0) or (i == 0 and in.parent >= 0)) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: damaged table at element %d (%s)", function, i, source_name);
            xml_h.rvn_xml_free(document);
            return raven.R_FALSE;
        }
        // the strings are the program's: they live as long as it does
        const text: [*c]const u8 = if (in.text != null) in.text else "";
        node.*.name = in.tag;
        node.*.text = text;
        node.*.line = in.line;
        node.*.column = 1;
        j = 0;
        while (j < in.attribute_count) : (j += 1) {
            const attribute: [*c]xml_h.rvn_xml_attribute_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&document.*.arena, @sizeOf(xml_h.rvn_xml_attribute_t))));
            attribute.*.name = in.attributes[@intCast(j * 2)];
            attribute.*.value = in.attributes[@intCast(j * 2 + 1)];
            attribute.*.next = null;
            if (last != null) {
                last.*.next = attribute;
            } else {
                node.*.attributes = attribute;
            }
            last = attribute;
        }
        if (in.parent >= 0) {
            const parent = made[@intCast(in.parent)];
            node.*.parent = parent;
            if (parent.*.last_child != null) {
                parent.*.last_child.*.next = node;
            } else {
                parent.*.first_child = node;
            }
            parent.*.last_child = node;
        }
        made[@intCast(i)] = node;
    }
    document.*.root = made[0];
    if (xml_h.rvn_xml_expand(document, null) == 0) {
        xml_h.rvn_xml_free(document);
        return raven.R_FALSE;
    }
    if (document.*.root == null) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: %s only declares widgets", function, source_name);
        xml_h.rvn_xml_free(document);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn Rwindow_create_from_compiled(nodes: [*c]const raven.RXmlCompiledNode, count: c_int, source: [*c]const u8) raven.Rid {
    var document: xml_h.rvn_xml_document_t = undefined;
    if (ctx_h.rvn_api_check("Rwindow_create_from_compiled") == 0) return raven.R_INVALID_ID;
    if (rvn_xml_from_compiled(&document, nodes, count, source, "Rwindow_create_from_compiled") == 0) return raven.R_INVALID_ID;
    return xml_h.rvn_xml_build_window(&document, "Rwindow_create_from_compiled");
}

export fn Rwidget_create_from_compiled(nodes: [*c]const raven.RXmlCompiledNode, count: c_int, source: [*c]const u8) raven.Rid {
    var document: xml_h.rvn_xml_document_t = undefined;
    if (ctx_h.rvn_api_check("Rwidget_create_from_compiled") == 0) return raven.R_INVALID_ID;
    if (rvn_xml_from_compiled(&document, nodes, count, source, "Rwidget_create_from_compiled") == 0) return raven.R_INVALID_ID;
    return xml_h.rvn_xml_build_widget(&document, raven.R_FALSE, "Rwidget_create_from_compiled");
}
