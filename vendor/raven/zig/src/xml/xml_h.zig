// Translated to Zig from vendor/raven/src/xml/xml.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml.h
// Minimal XML reader: elements, attributes, text, comments, CDATA and the
// predefined / numeric entities. No DTD, no namespaces.
//
// The document owns every string through one arena: releasing it frees all.
//
// `struct rvn_widget_t` / `struct rvn_window_t` are only pointed to here: they are the opaque placeholders of
// externs.zig until widget/widget_h.zig exists.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const externs = @import("externs.zig");

pub const rvn_widget_t = externs.rvn_widget_t;
pub const rvn_window_t = externs.rvn_window_t;

pub const rvn_xml_attribute_t = extern struct {
    name: [*c]const u8,
    value: [*c]const u8,
    next: [*c]rvn_xml_attribute_t,
};
pub const struct_rvn_xml_attribute_t = rvn_xml_attribute_t;

pub const rvn_xml_node_t = extern struct {
    name: [*c]const u8,
    /// Text content of the element with surrounding white space removed; "" when it has none.
    text: [*c]const u8,
    attributes: [*c]rvn_xml_attribute_t,
    parent: [*c]rvn_xml_node_t,
    first_child: [*c]rvn_xml_node_t,
    last_child: [*c]rvn_xml_node_t,
    next: [*c]rvn_xml_node_t,
    /// Position of the opening tag in the source, starting at 1.
    line: c_int,
    column: c_int,
    /// Node of a public document (Rxml_document_...) this element was made
    /// from, or 0. The widgets built from the element remember it.
    source: raven.Rid,
    /// Widget built from the element (documents kept for live reload), or 0.
    widget: raven.Rid,
};
pub const struct_rvn_xml_node_t = rvn_xml_node_t;

/// Name of the nodes that hold a comment, when the parser keeps them: the text is the comment.
pub const RVN_XML_COMMENT = "#comment";

pub const rvn_xml_document_t = extern struct {
    arena: base.rvn_arena_t,
    root: [*c]rvn_xml_node_t,
    /// Comments are kept, as nodes named RVN_XML_COMMENT (those before the root in `prolog`, in order).
    keep_comments: c_int,
    prolog: [*c]rvn_xml_node_t,
    prolog_last: [*c]rvn_xml_node_t,
    /// The text starts with an <?xml ...?> declaration.
    has_declaration: c_int,
    /// Filled when parsing fails.
    @"error": [160]u8,
    error_line: c_int,
    error_column: c_int,
};
pub const struct_rvn_xml_document_t = rvn_xml_document_t;

/// What the attributes of a <Window> say.
pub const rvn_xml_window_t = extern struct {
    title: [*c]const u8,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    flags: raven.Ruint,
    has_clear: c_int,
    clear: base.rvn_color_t,
    background: raven.Rid,
    /// RBackdrop, or 0 when not given.
    backdrop: c_int,
    theme: [*c]const u8,
};
pub const struct_rvn_xml_window_t = rvn_xml_window_t;

/// Parses `size` bytes of UTF-8. Returns R_FALSE and fills `error` on failure.
pub extern fn rvn_xml_parse(document: [*c]rvn_xml_document_t, text: [*c]const u8, size: usize) c_int;
/// The same, keeping the comments (for tools that write the document back).
pub extern fn rvn_xml_parse_keeping_comments(document: [*c]rvn_xml_document_t, text: [*c]const u8, size: usize) c_int;
pub extern fn rvn_xml_free(document: [*c]rvn_xml_document_t) void;
/// Value of an attribute (name compared without case), or NULL.
pub extern fn rvn_xml_attribute(node: [*c]const rvn_xml_node_t, name: [*c]const u8) [*c]const u8;

/// Rewrites a parsed document into a plain one (xml_components.c): the
/// <Widget> declarations are registered and removed, their uses are replaced
/// by their bodies, <Repeat>, <ForEach>, <If> and <Include> are carried out.
/// The root is NULL afterwards when the document only held declarations.
/// `registered` (may be NULL) receives the number of widgets it declared.
/// Returns R_FALSE, after reporting the error, when the document cannot be used.
pub extern fn rvn_xml_expand(document: [*c]rvn_xml_document_t, registered: [*c]c_int) c_int;
pub extern fn rvn_xml_components_shutdown() void;
/// Releases the public documents the application left behind (xml_dom.c).
pub extern fn rvn_xml_dom_shutdown() void;
/// The i-th parameter of a declared widget and its default value. R_FALSE past the last one, or when the name is unknown.
pub extern fn rvn_xml_component_parameter(component: [*c]const u8, index: c_int, name: [*c][*c]const u8, default_value: [*c][*c]const u8) c_int;

/// Builds what an expanded document describes (xml_loader.c) and releases the
/// document. `function` names the caller in the errors.
/// rvn_xml_build_widget: with `window_content`, a <Window> root gives its
/// content (R_INVALID_ID, without an error, when it has none).
pub extern fn rvn_xml_build_window(document: [*c]rvn_xml_document_t, function: [*c]const u8) raven.Rid;
pub extern fn rvn_xml_build_widget(document: [*c]rvn_xml_document_t, window_content: c_int, function: [*c]const u8) raven.Rid;
/// Parses and expands a text: what the build functions take. R_FALSE after reporting the error.
pub extern fn rvn_xml_load(document: [*c]rvn_xml_document_t, xml: [*c]const u8, size: usize, function: [*c]const u8) c_int;
/// Tags made by code (Rxml_register_tag): the index + 1 of a tag, or 0.
pub extern fn rvn_xml_tag_find(name: [*c]const u8) c_int;
/// Gives an attribute to the tag a widget was built for. R_FALSE when it has none, or does not know the attribute.
pub extern fn rvn_xml_tag_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;
/// Builds the widget of an element and of everything inside it. NULL after reporting the error.
pub extern fn rvn_xml_build_node(node: [*c]const rvn_xml_node_t) [*c]rvn_widget_t;
pub extern fn rvn_xml_window_read(root: [*c]const rvn_xml_node_t, description: [*c]rvn_xml_window_t, report: c_int) void;
/// The element of a <Window> that is its content, and the one that is its island (NULL when missing). R_FALSE when it has several contents.
pub extern fn rvn_xml_window_parts(root: [*c]const rvn_xml_node_t, content: [*c][*c]const rvn_xml_node_t, island: [*c][*c]const rvn_xml_node_t) c_int;
/// Adds (or removes) the <Shortcut> elements of a <Window>.
pub extern fn rvn_xml_window_shortcuts(window: [*c]rvn_window_t, root: [*c]const rvn_xml_node_t, add: c_int) void;
/// Same as rvn_xml_build_window / rvn_xml_build_widget, leaving the document to the caller.
pub extern fn rvn_xml_make_window(document: [*c]rvn_xml_document_t) raven.Rid;
pub extern fn rvn_xml_make_widget(document: [*c]rvn_xml_document_t, window_content: c_int) raven.Rid;

/// Runs `load` with the paths of the documents relative to the folder of `path` (NULL: the base path).
pub extern fn rvn_xml_push_file_dir(path: [*c]const u8, previous: [*c][*c]u8) void;
pub extern fn rvn_xml_pop_file_dir(previous: [*c]u8) void;

/// Path of a file named in a document, relative to the document or to the base path. Free with rvn_free.
pub extern fn rvn_xml_resolve_path(path: [*c]const u8) [*c]u8;
