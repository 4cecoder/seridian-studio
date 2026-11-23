// Translated to Zig from vendor/raven/src/xml/xml_loader.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_loader.c
// Builds windows and widget trees from XML (see raven_xml.h and docs/XML.md).
//
//   element          -> widget of the class named by the tag
//   attribute        -> rvn_widget_set_attribute
//   child element    -> child widget, unless the class of the parent handles
//                       the tag itself (<Item>, menu <Separator>)
//   text content     -> the "Text" attribute

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const fs_h = @import("../core/fs_h.zig");
const xml_h = @import("xml_h.zig");
const watch_h = @import("xml_watch_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common_h = @import("../widgets/common_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const libc = @import("../sys/libc.zig");

// ---------------------------------------------------------------------------
//  Resources named in attributes (Source="...", Font="...")
// ---------------------------------------------------------------------------

const rvn_xml_resource_t = extern struct {
    path: [*c]u8,
    id: raven.Rid,
};

const xml_state_t = extern struct {
    textures: [*c]rvn_xml_resource_t,
    texture_count: u32,
    texture_cap: u32,
    fonts: [*c]rvn_xml_resource_t,
    font_count: u32,
    font_cap: u32,
    /// Folder of the file being loaded; overrides the base path meanwhile.
    file_dir: [*c]u8,
    /// What Rxml_resolve_path last returned.
    resolved: [*c]u8,
};

var g_xml: xml_state_t = std.mem.zeroes(xml_state_t);

fn rvn_xml_resolve(path: [*c]const u8) [*c]u8 {
    return base.rvn_path_join(if (g_xml.file_dir != null) g_xml.file_dir else ctx_h.g_rvn.xml_base_path, path);
}

export fn rvn_xml_resolve_path(path: [*c]const u8) [*c]u8 {
    return rvn_xml_resolve(path);
}

export fn rvn_xml_texture(path: [*c]const u8) raven.Rid {
    const remote = fs_h.rvn_is_http_url(path) != 0;
    const full = if (remote) base.rvn_strdup(path) else rvn_xml_resolve(path);
    var texture: raven.Rid = undefined;
    var i: u32 = 0;

    while (i < g_xml.texture_count) : (i += 1) {
        if (libc.strcmp(g_xml.textures[i].path, full) != 0) continue;
        // still valid unless the application deleted it
        if (renderer_h.rvn_texture_get(g_xml.textures[i].id) != null) {
            base.rvn_free(full);
            return g_xml.textures[i].id;
        }
        break;
    }
    texture = if (remote) renderer_h.rvn_texture_create_from_url_async(full) else raven.Rtexture_create_from_file(full);
    if (texture == raven.R_INVALID_ID) {
        base.rvn_free(full);
        return raven.R_INVALID_ID;
    }
    if (i < g_xml.texture_count) {
        g_xml.textures[i].id = texture;
        base.rvn_free(full);
    } else {
        base.RVN_ARRAY_RESERVE(&g_xml.textures, &g_xml.texture_cap, g_xml.texture_count + 1);
        g_xml.textures[g_xml.texture_count].path = full;
        g_xml.textures[g_xml.texture_count].id = texture;
        g_xml.texture_count += 1;
    }
    return texture;
}

export fn rvn_xml_font(path: [*c]const u8) raven.Rid {
    var i: u32 = 0;

    // the fonts of the library have names
    if (base.rvn_stricmp(path, "monospace") == 0) return ctx_h.g_rvn.mono_font;

    if (base.rvn_stricmp(path, "default") == 0) return ctx_h.g_rvn.default_font;
    const full = rvn_xml_resolve(path);

    while (i < g_xml.font_count) : (i += 1) {
        if (libc.strcmp(g_xml.fonts[i].path, full) != 0) continue;
        if (raven.Rfont_is_valid(g_xml.fonts[i].id) != 0) {
            base.rvn_free(full);
            return g_xml.fonts[i].id;
        }
        break;
    }
    const font = raven.Rfont_create_from_file(full);
    if (font == raven.R_INVALID_ID) {
        base.rvn_free(full);
        return raven.R_INVALID_ID;
    }
    if (i < g_xml.font_count) {
        g_xml.fonts[i].id = font;
        base.rvn_free(full);
    } else {
        base.RVN_ARRAY_RESERVE(&g_xml.fonts, &g_xml.font_cap, g_xml.font_count + 1);
        g_xml.fonts[g_xml.font_count].path = full;
        g_xml.fonts[g_xml.font_count].id = font;
        g_xml.font_count += 1;
    }
    return font;
}

/// Forgets the resource cache. The textures and fonts themselves belong to the library pools.
export fn rvn_xml_shutdown() void {
    var i: u32 = 0;
    while (i < g_xml.texture_count) : (i += 1) base.rvn_free(g_xml.textures[i].path);
    i = 0;
    while (i < g_xml.font_count) : (i += 1) base.rvn_free(g_xml.fonts[i].path);
    base.rvn_free(g_xml.textures);
    base.rvn_free(g_xml.fonts);
    base.rvn_free(g_xml.file_dir);
    base.rvn_free(g_xml.resolved);
    g_xml = std.mem.zeroes(xml_state_t);
    rvn_xml_tags_shutdown();
    watch_h.rvn_live_shutdown();
    xml_h.rvn_xml_components_shutdown();
    xml_h.rvn_xml_dom_shutdown();
}

// ---------------------------------------------------------------------------
//  Building
// ---------------------------------------------------------------------------

fn rvn_xml_error(node: [*c]const xml_h.rvn_xml_node_t, severity: raven.RSeverity, format: [*c]const u8, ...) callconv(.c) void {
    var message: [256]u8 = undefined;
    var args = @cVaStart();
    defer @cVaEnd(&args);
    _ = libc.vsnprintf(&message, message.len, format, &args);
    const text: [*c]const u8 = &message;
    base.rvn_error(raven.R_ERROR_XML, severity, "XML line %d, column %d: %s", node.*.line, node.*.column, text);
}

// ---------------------------------------------------------------------------
//  Tags made by code
// ---------------------------------------------------------------------------

const RVN_XML_TAGS_MAX = 64;

const rvn_xml_tag_t = extern struct {
    name: [*c]u8,
    create: raven.RXmlTagCreateCallback,
    attribute: raven.RXmlTagAttributeCallback,
    user: ?*anyopaque,
};

// (a slot keeps its place when its tag is removed: the widgets built for it name it by index)
var g_xml_tags: [RVN_XML_TAGS_MAX]rvn_xml_tag_t = std.mem.zeroes([RVN_XML_TAGS_MAX]rvn_xml_tag_t);

export fn rvn_xml_tag_find(name: [*c]const u8) c_int {
    var i: c_int = 0;
    if (name == null) return 0;
    while (i < RVN_XML_TAGS_MAX) : (i += 1) {
        if (g_xml_tags[@intCast(i)].name != null and base.rvn_stricmp(g_xml_tags[@intCast(i)].name, name) == 0) return i + 1;
    }
    return 0;
}

export fn rvn_xml_tag_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int {
    if (widget.*.xml_tag == 0 or widget.*.xml_tag > RVN_XML_TAGS_MAX) return raven.R_FALSE;
    const tag = &g_xml_tags[widget.*.xml_tag - 1];
    if (tag.*.name == null or tag.*.attribute == null) return raven.R_FALSE;
    return @intFromBool(tag.*.attribute.?(widget.*.id, name, value, tag.*.user) != 0);
}

fn rvn_xml_tags_shutdown() void {
    var i: c_int = 0;
    while (i < RVN_XML_TAGS_MAX) : (i += 1) base.rvn_free(g_xml_tags[@intCast(i)].name);
    g_xml_tags = std.mem.zeroes([RVN_XML_TAGS_MAX]rvn_xml_tag_t);
}

export fn Rxml_register_tag(tag: [*c]const u8, create: raven.RXmlTagCreateCallback, set_attribute: raven.RXmlTagAttributeCallback, user_data: ?*anyopaque) c_int {
    var index: c_int = undefined;
    var i: c_int = undefined;
    if (ctx_h.rvn_api_check("Rxml_register_tag") == 0) return raven.R_FALSE;
    if (tag == null or tag[0] == 0 or create == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_register_tag: a tag needs a name and a function that makes its widget");
        return raven.R_FALSE;
    }
    if (widget_h.rvn_widget_class_by_name(tag) != null or base.rvn_stricmp(tag, "Window") == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_register_tag: <%.60s> is a tag of Raven", tag);
        return raven.R_FALSE;
    }
    index = rvn_xml_tag_find(tag) - 1;
    i = 0;
    while (i < RVN_XML_TAGS_MAX and index < 0) : (i += 1) {
        if (g_xml_tags[@intCast(i)].name == null) index = i;
    }
    if (index < 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rxml_register_tag: too many tags (%d)", @as(c_int, RVN_XML_TAGS_MAX));
        return raven.R_FALSE;
    }
    const slot: usize = @intCast(index);
    if (g_xml_tags[slot].name == null) g_xml_tags[slot].name = base.rvn_strdup(tag);
    g_xml_tags[slot].create = create;
    g_xml_tags[slot].attribute = set_attribute;
    g_xml_tags[slot].user = user_data;
    return raven.R_TRUE;
}

export fn Rxml_unregister_tag(tag: [*c]const u8) void {
    var index: c_int = undefined;
    if (ctx_h.rvn_api_check("Rxml_unregister_tag") == 0) return;
    index = rvn_xml_tag_find(tag) - 1;
    if (index < 0) return;
    const slot: usize = @intCast(index);
    base.rvn_free(g_xml_tags[slot].name);
    g_xml_tags[slot] = std.mem.zeroes(rvn_xml_tag_t);
}

export fn Rxml_resolve_path(path: [*c]const u8) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rxml_resolve_path") == 0) return "";
    base.rvn_free(g_xml.resolved);
    g_xml.resolved = if (path != null) rvn_xml_resolve(path) else null;
    const result: [*c]const u8 = if (g_xml.resolved != null) g_xml.resolved else "";
    return result;
}

export fn Rxml_is_tag_registered(tag: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rxml_is_tag_registered") == 0) return raven.R_FALSE;
    return @intFromBool(rvn_xml_tag_find(tag) != 0);
}

export fn rvn_xml_build_node(node: [*c]const xml_h.rvn_xml_node_t) [*c]widget_h.rvn_widget_t {
    var cls: [*c]const widget_h.rvn_widget_class_t = widget_h.rvn_widget_class_by_name(node.*.name);
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = undefined;
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    var widget: [*c]widget_h.rvn_widget_t = undefined;

    if (cls == null) {
        // a tag made by code: it builds its widget itself
        const tag = rvn_xml_tag_find(node.*.name);

        if (tag == 0) {
            rvn_xml_error(node, raven.R_SEVERITY_ERROR, "unknown widget <%.60s>", node.*.name);
            return null;
        }
        const slot: usize = @intCast(tag - 1);
        const made = g_xml_tags[slot].create.?(g_xml_tags[slot].name, g_xml_tags[slot].user);
        widget = widget_h.rvn_widget_get(made);
        if (widget == null or widget.*.parent != null or (widget.*.flags & widget_h.RVN_WF_POPUP) != 0) {
            rvn_xml_error(node, raven.R_SEVERITY_ERROR, "<%.60s>: the function registered for this tag did not return a new widget", node.*.name);
            return null;
        }
        widget.*.xml_tag = @intCast(tag);
        cls = widget.*.cls;
    } else {
        widget = widget_h.rvn_widget_create(cls.*.type);
    }
    if (widget == null) return null;
    widget.*.xml_node = node.*.source;
    // (documents kept for live reload find their widgets again through this)
    const mutable: [*c]xml_h.rvn_xml_node_t = @constCast(node);

    mutable.*.widget = widget.*.id;

    // children first: attributes such as Selected="1" or ActiveTab="2" refer to them
    child = node.*.first_child;

    while (child != null) : (child = child.*.next) {
        // the class may give the tag its own meaning (<Item>, <Separator> in a menu)
        if (cls.*.xml_child != null and cls.*.xml_child.?(widget, child) != 0) continue;

        if ((cls.*.flags & widget_h.RVN_CF_NO_CHILDREN) != 0) {
            rvn_xml_error(child, raven.R_SEVERITY_ERROR, "<%.60s> cannot contain <%.60s>", node.*.name, child.*.name);
            widget_h.rvn_widget_destroy(widget);
            return null;
        }
        const child_widget = rvn_xml_build_node(child);
        if (child_widget == null) {
            widget_h.rvn_widget_destroy(widget);
            return null;
        }
        widget_h.rvn_widget_add_child(widget, child_widget, -1);
    }

    // <Label>Hello</Label> is the same as <Label Text="Hello"/>
    if (node.*.text[0] != 0 and xml_h.rvn_xml_attribute(node, "Text") == null and node.*.first_child == null) {
        _ = widget_h.rvn_widget_set_attribute(widget, "Text", node.*.text);
    }
    attribute = node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (widget_h.rvn_widget_set_attribute(widget, attribute.*.name, attribute.*.value) == 0) {
            // a typo should not prevent the rest of the interface from loading
            rvn_xml_error(node, raven.R_SEVERITY_WARNING, "<%.60s>: unknown attribute or invalid value %.60s=\"%.60s\"", node.*.name, attribute.*.name, attribute.*.value);
        }
    }
    return widget;
}

export fn rvn_xml_load(document: [*c]xml_h.rvn_xml_document_t, xml: [*c]const u8, size: usize, function: [*c]const u8) c_int {
    if (xml == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: NULL text", function);
        return raven.R_FALSE;
    }
    if (xml_h.rvn_xml_parse(document, xml, size) == 0) {
        const err_text: [*c]const u8 = &document.*.@"error";
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: line %d, column %d: %s", function, document.*.error_line, document.*.error_column, err_text);
        xml_h.rvn_xml_free(document);
        return raven.R_FALSE;
    }
    // declared widgets, repetitions, conditions: the document becomes a plain one
    if (xml_h.rvn_xml_expand(document, null) == 0) {
        xml_h.rvn_xml_free(document);
        return raven.R_FALSE;
    }
    if (document.*.root == null) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: the document declares widgets but contains nothing to create", function);
        xml_h.rvn_xml_free(document);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_xml_window_parts(root: [*c]const xml_h.rvn_xml_node_t, content: [*c][*c]const xml_h.rvn_xml_node_t, island: [*c][*c]const xml_h.rvn_xml_node_t) c_int {
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    content.* = null;
    island.* = null;
    child = root.*.first_child;
    while (child != null) : (child = child.*.next) {
        const cls = widget_h.rvn_widget_class_by_name(child.*.name);
        if (base.rvn_stricmp(child.*.name, "Shortcut") == 0) continue;
        // an island next to the content floats above it at the top of the window
        if (cls != null and cls.*.type == raven.R_WIDGET_ISLAND and island.* == null) {
            island.* = child;
            continue;
        }
        if (content.* != null) {
            rvn_xml_error(child, raven.R_SEVERITY_ERROR, "a <Window> has a single content element; wrap them in a panel");
            return raven.R_FALSE;
        }
        content.* = child;
    }
    return raven.R_TRUE;
}

export fn rvn_xml_make_widget(document: [*c]xml_h.rvn_xml_document_t, window_content: c_int) raven.Rid {
    var node: [*c]const xml_h.rvn_xml_node_t = document.*.root;
    var widget: [*c]widget_h.rvn_widget_t = undefined;
    if (base.rvn_stricmp(node.*.name, "Window") == 0) {
        var island: [*c]const xml_h.rvn_xml_node_t = undefined;
        if (window_content == 0) {
            rvn_xml_error(node, raven.R_SEVERITY_ERROR, "the root element is a <Window>: use Rwindow_create_from_xml");
            return raven.R_INVALID_ID;
        }
        // what the window would show: its first element that is neither a shortcut nor an island
        _ = rvn_xml_window_parts(node, &node, &island);

        if (node == null) return raven.R_INVALID_ID;
    }
    widget = rvn_xml_build_node(node);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn rvn_xml_build_widget(document: [*c]xml_h.rvn_xml_document_t, window_content: c_int, function: [*c]const u8) raven.Rid {
    const widget = rvn_xml_make_widget(document, window_content);
    _ = function; // RVN_UNUSED(function)
    xml_h.rvn_xml_free(document);
    return widget;
}

fn rvn_xml_create_widget(xml: [*c]const u8, size: usize, function: [*c]const u8) raven.Rid {
    var document: xml_h.rvn_xml_document_t = undefined;
    if (rvn_xml_load(&document, xml, size, function) == 0) return raven.R_INVALID_ID;
    return rvn_xml_build_widget(&document, raven.R_FALSE, function);
}

fn rvn_xml_create_window(xml: [*c]const u8, size: usize, function: [*c]const u8) raven.Rid {
    var document: xml_h.rvn_xml_document_t = undefined;
    if (rvn_xml_load(&document, xml, size, function) == 0) return raven.R_INVALID_ID;
    return rvn_xml_build_window(&document, function);
}

fn rvn_xml_parse_backdrop(value: [*c]const u8, backdrop: [*c]c_int) c_int {
    const Name = struct { name: [*c]const u8, backdrop: raven.RBackdrop };
    const names = [_]Name{
        .{ .name = "None", .backdrop = raven.R_BACKDROP_NONE },
        .{ .name = "Opaque", .backdrop = raven.R_BACKDROP_NONE },
        .{ .name = "Transparent", .backdrop = raven.R_BACKDROP_TRANSPARENT },
        .{ .name = "Blur", .backdrop = raven.R_BACKDROP_BLUR },
        .{ .name = "Acrylic", .backdrop = raven.R_BACKDROP_ACRYLIC },
        .{ .name = "Mica", .backdrop = raven.R_BACKDROP_MICA },
    };
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        if (base.rvn_stricmp(value, names[i].name) == 0) {
            backdrop.* = @intCast(names[i].backdrop);
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

export fn rvn_xml_window_read(root: [*c]const xml_h.rvn_xml_node_t, window: [*c]xml_h.rvn_xml_window_t, report: c_int) void {
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = undefined;
    var flag: c_int = undefined;

    window.* = std.mem.zeroes(xml_h.rvn_xml_window_t);
    window.*.title = "";
    window.*.width = 800;
    window.*.height = 600;
    window.*.flags = raven.R_WINDOW_DEFAULT;
    window.*.background = raven.R_INVALID_ID;

    attribute = root.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        const name = attribute.*.name;
        const value = attribute.*.value;
        var ok: c_int = raven.R_TRUE;
        if (base.rvn_stricmp(name, "Title") == 0) {
            window.*.title = value;
        } else if (base.rvn_stricmp(name, "Width") == 0) {
            ok = @intFromBool(widget_h.rvn_parse_int(value, &window.*.width) != 0 and window.*.width > 0);
        } else if (base.rvn_stricmp(name, "Height") == 0) {
            ok = @intFromBool(widget_h.rvn_parse_int(value, &window.*.height) != 0 and window.*.height > 0);
        } else if (base.rvn_stricmp(name, "MinWidth") == 0) {
            ok = widget_h.rvn_parse_int(value, &window.*.min_width);
        } else if (base.rvn_stricmp(name, "MinHeight") == 0) {
            ok = widget_h.rvn_parse_int(value, &window.*.min_height);
        } else if (base.rvn_stricmp(name, "Resizable") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag == 0) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_NO_RESIZE));
        } else if (base.rvn_stricmp(name, "Borderless") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag != 0) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_BORDERLESS));
        } else if (base.rvn_stricmp(name, "CustomHeader") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag != 0) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_CUSTOM_HEADER));
        } else if (base.rvn_stricmp(name, "Maximized") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag != 0) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_MAXIMIZED));
        } else if (base.rvn_stricmp(name, "Hidden") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag != 0) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_HIDDEN));
        } else if (base.rvn_stricmp(name, "Transparent") == 0) {
            ok = widget_h.rvn_parse_bool(value, &flag);
            if (ok != 0 and flag != 0) {
                window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_TRANSPARENT));
                if (window.*.backdrop == 0) window.*.backdrop = @intCast(raven.R_BACKDROP_TRANSPARENT);
            }
        } else if (base.rvn_stricmp(name, "Backdrop") == 0) {
            ok = rvn_xml_parse_backdrop(value, &window.*.backdrop);
            if (ok != 0 and window.*.backdrop != @as(c_int, @intCast(raven.R_BACKDROP_NONE))) window.*.flags |= @as(raven.Ruint, @intCast(raven.R_WINDOW_TRANSPARENT));
        } else if (base.rvn_stricmp(name, "ClearColor") == 0) {
            ok = widget_h.rvn_parse_color(value, &window.*.clear);
            window.*.has_clear = ok;
        } else if (base.rvn_stricmp(name, "Background") == 0) {
            window.*.background = rvn_xml_texture(value);
            ok = @intFromBool(window.*.background != raven.R_INVALID_ID);
        } else if (base.rvn_stricmp(name, "Theme") == 0) {
            window.*.theme = value;
        } else {
            ok = raven.R_FALSE;
        }
        if (ok == 0 and report != 0) {
            rvn_xml_error(root, raven.R_SEVERITY_WARNING, "<Window>: unknown attribute or invalid value %.60s=\"%.60s\"", name, value);
        }
    }
}

export fn rvn_xml_window_shortcuts(window: [*c]widget_h.rvn_window_t, root: [*c]const xml_h.rvn_xml_node_t, add: c_int) void {
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    // <Shortcut Keys="Ctrl+S" Action="file.save"/>
    child = root.*.first_child;

    while (child != null) : (child = child.*.next) {
        var key: raven.RKey = undefined;
        var modifiers: u32 = undefined;
        if (base.rvn_stricmp(child.*.name, "Shortcut") != 0) continue;
        const keys = xml_h.rvn_xml_attribute(child, "Keys");
        const action = xml_h.rvn_xml_attribute(child, "Action");
        if (keys == null or action == null or action[0] == 0 or widget_h.rvn_parse_shortcut(keys, &key, &modifiers) == 0) {
            if (add != 0) rvn_xml_error(child, raven.R_SEVERITY_WARNING, "<Shortcut> needs Keys=\"Ctrl+S\" and Action=\"name\"");
            continue;
        }
        if (add != 0) {
            widget_h.rvn_window_add_shortcut(window, key, modifiers, action);
        } else {
            widget_h.rvn_window_remove_shortcut(window, key, modifiers);
        }
    }
}

export fn rvn_xml_make_window(document: [*c]xml_h.rvn_xml_document_t) raven.Rid {
    const root: [*c]const xml_h.rvn_xml_node_t = document.*.root;
    var content_node: [*c]const xml_h.rvn_xml_node_t = undefined;
    var island_node: [*c]const xml_h.rvn_xml_node_t = undefined;
    var content: [*c]widget_h.rvn_widget_t = null;
    var island: [*c]widget_h.rvn_widget_t = null;
    var window_object: [*c]widget_h.rvn_window_t = undefined;
    var description: xml_h.rvn_xml_window_t = undefined;
    var window: raven.Rid = undefined;

    if (base.rvn_stricmp(root.*.name, "Window") != 0) {
        rvn_xml_error(root, raven.R_SEVERITY_ERROR, "the root element must be <Window>, found <%.60s>", root.*.name);
        return raven.R_INVALID_ID;
    }
    rvn_xml_window_read(root, &description, raven.R_TRUE);
    if (description.theme != null and description.theme[0] != 0) {
        // a window names the theme of the application: the name of one, or its file
        const theme = common_h.rvn_xml_theme(description.theme);

        if (theme != null) _ = raven.Rtheme_use(theme.*.name);
    }

    // the content is built first: a mistake in it must not leave an empty window behind
    if (rvn_xml_window_parts(root, &content_node, &island_node) == 0) return raven.R_INVALID_ID;

    if (island_node != null) {
        island = rvn_xml_build_node(island_node);
        if (island == null) return raven.R_INVALID_ID;
    }
    if (content_node != null) {
        content = rvn_xml_build_node(content_node);
        if (content == null) {
            if (island != null) widget_h.rvn_widget_destroy(island);
            return raven.R_INVALID_ID;
        }
    }

    window = raven.Rwindow_create(description.title, description.width, description.height, description.flags);
    if (window == raven.R_INVALID_ID) {
        if (content != null) widget_h.rvn_widget_destroy(content);
        if (island != null) widget_h.rvn_widget_destroy(island);
        return raven.R_INVALID_ID;
    }
    window_object = widget_h.rvn_window_get(window);
    if (window_object != null) window_object.*.xml_node = root.*.source;
    if (description.min_width > 0 or description.min_height > 0) raven.Rwindow_set_min_size(window, description.min_width, description.min_height);
    if (description.has_clear != 0) {
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
        var a: f32 = undefined;
        base.rvn_color_to_floats(description.clear, &r, &g, &b, &a);
        raven.Rwindow_set_clear_color(window, r, g, b, a);
    }
    if (description.background != raven.R_INVALID_ID) raven.Rwindow_set_background(window, description.background);
    if (description.backdrop != 0) _ = raven.Rwindow_set_backdrop(window, @intCast(description.backdrop));
    if (content != null) raven.Rwindow_set_content(window, content.*.id);
    if (island != null) raven.Rwindow_set_island(window, island.*.id);
    if (window_object != null) rvn_xml_window_shortcuts(window_object, root, raven.R_TRUE);
    return window;
}

export fn rvn_xml_build_window(document: [*c]xml_h.rvn_xml_document_t, function: [*c]const u8) raven.Rid {
    const window = rvn_xml_make_window(document);
    _ = function; // RVN_UNUSED(function)
    xml_h.rvn_xml_free(document);
    return window;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rwidget_create_from_xml(xml: [*c]const u8, size: usize) raven.Rid {
    if (ctx_h.rvn_api_check("Rwidget_create_from_xml") == 0) return raven.R_INVALID_ID;
    return rvn_xml_create_widget(xml, size, "Rwidget_create_from_xml");
}

export fn Rwindow_create_from_xml(xml: [*c]const u8, size: usize) raven.Rid {
    if (ctx_h.rvn_api_check("Rwindow_create_from_xml") == 0) return raven.R_INVALID_ID;
    return rvn_xml_create_window(xml, size, "Rwindow_create_from_xml");
}

export fn rvn_xml_push_file_dir(path: [*c]const u8, previous: [*c][*c]u8) void {
    previous.* = g_xml.file_dir;
    g_xml.file_dir = if (path != null) base.rvn_path_dir(path) else null;
}

export fn rvn_xml_pop_file_dir(previous: [*c]u8) void {
    base.rvn_free(g_xml.file_dir);
    g_xml.file_dir = previous;
}

fn rvn_xml_create_from_file(path: [*c]const u8, is_window: c_int, function: [*c]const u8) raven.Rid {
    var document: xml_h.rvn_xml_document_t = undefined;
    var size: usize = 0;
    const text = base.rvn_read_file(path, &size);
    var previous_dir: [*c]u8 = undefined;
    var result: raven.Rid = raven.R_INVALID_ID;
    const path_text: [*c]const u8 = if (path != null) path else "";
    if (text == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "%s: cannot read '%s'", function, path_text);
        return raven.R_INVALID_ID;
    }
    // relative paths inside the file are relative to the file
    rvn_xml_push_file_dir(path, &previous_dir);

    // (the files it includes are noted: a change in one of them is a change in this one)
    watch_h.rvn_live_begin();

    if (xml_h.rvn_xml_load(&document, text, size, function) != 0) {
        result = if (is_window != 0) rvn_xml_make_window(&document) else rvn_xml_make_widget(&document, raven.R_FALSE);
        // the document stays with what it built: when the file changes, the two are compared
        if (result != raven.R_INVALID_ID) {
            watch_h.rvn_live_add(path, is_window, result, &document);
        } else {
            xml_h.rvn_xml_free(&document);
        }
    }
    watch_h.rvn_live_end();
    rvn_xml_pop_file_dir(previous_dir);
    base.rvn_free(text);
    return result;
}

export fn Rwidget_create_from_xml_file(path: [*c]const u8) raven.Rid {
    if (ctx_h.rvn_api_check("Rwidget_create_from_xml_file") == 0) return raven.R_INVALID_ID;
    return rvn_xml_create_from_file(path, raven.R_FALSE, "Rwidget_create_from_xml_file");
}

export fn Rwindow_create_from_xml_file(path: [*c]const u8) raven.Rid {
    if (ctx_h.rvn_api_check("Rwindow_create_from_xml_file") == 0) return raven.R_INVALID_ID;
    return rvn_xml_create_from_file(path, raven.R_TRUE, "Rwindow_create_from_xml_file");
}

export fn Rxml_register_widgets_from_file(path: [*c]const u8) c_int {
    var size: usize = 0;
    var text: [*c]u8 = undefined;
    const previous_dir = g_xml.file_dir;
    var registered: c_int = undefined;
    const path_text: [*c]const u8 = if (path != null) path else "";
    if (ctx_h.rvn_api_check("Rxml_register_widgets_from_file") == 0) return 0;
    text = base.rvn_read_file(path, &size);
    if (text == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rxml_register_widgets_from_file: cannot read '%s'", path_text);
        return 0;
    }
    g_xml.file_dir = base.rvn_path_dir(path);
    registered = raven.Rxml_register_widgets(text, size);
    base.rvn_free(g_xml.file_dir);
    g_xml.file_dir = previous_dir;
    base.rvn_free(text);
    // a change in the file declares its widgets again and rebuilds what uses them
    watch_h.rvn_live_watch_widgets(path);

    return registered;
}

export fn Rxml_set_base_path(path: [*c]const u8) void {
    if (ctx_h.rvn_api_check("Rxml_set_base_path") == 0) return;
    const value: [*c]const u8 = if (path != null and path[0] != 0) path else null;
    _ = base.rvn_str_set(&ctx_h.g_rvn.xml_base_path, value);
}

// rvn_error is replaced in this test by a recorder, so the text built by rvn_xml_error can be checked.
var test_text: [512]u8 = std.mem.zeroes([512]u8);

test "rvn_xml_error formats its variadic arguments with the C ABI" {
    var node = std.mem.zeroes(xml_h.rvn_xml_node_t);
    node.line = 3;
    node.column = 9;
    const name: [*c]const u8 = "Button";
    const other: [*c]const u8 = "Panel";
    rvn_xml_error(&node, raven.R_SEVERITY_ERROR, "<%.60s> cannot contain <%.60s> (%d)", name, other, @as(c_int, 42));
    try std.testing.expect(libc.strcmp(&test_text, "XML line 3, column 9: <Button> cannot contain <Panel> (42)") == 0);
}
