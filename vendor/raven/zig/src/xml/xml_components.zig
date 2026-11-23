// Translated to Zig from vendor/raven/src/xml/xml_components.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_components.c
// Widgets declared in XML, and what makes a description more than a list of
// tags: parameters, expressions, conditions, repetitions, included files.
//
//     <Widget Name="Card" Title="Untitled" Wide="false">
//       <Border Padding="12" Width="{Wide ? 320 : 200}">
//         <VBox Spacing="6">
//           <Label Text="{Title}" TextSize="17"/>
//           <Children/>
//         </VBox>
//       </Border>
//     </Widget>
//     ...
//     <Card Title="Hello" Slot.Fill="1"><Button Text="Inside"/></Card>
//
// Nothing of this reaches the widgets: a parsed document is rewritten into a
// plain one before it is built (rvn_xml_expand). Each use of a declared
// widget is replaced by a copy of its body in which the {expressions} are
// computed, <Children/> is replaced by the children given at the use, and the
// attributes that are not parameters are given to the root of the copy.
//
// {expressions} are only looked for where there are variables: inside the
// body of a <Widget>, of a <Repeat> or of a <ForEach>. Anywhere else a brace
// is a brace, so existing documents (source code in a text editor...) keep
// their meaning. Where they are looked for, "{{" and "}}" write a brace.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context = @import("../core/context_h.zig");
const xml = @import("xml_h.zig");
const watch = @import("xml_watch_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_XC_MAX_DEPTH = 48;

const rvn_component_t = extern struct {
    name: [*c]u8,
    /// Owns the copy of the <Widget> element, which is its root.
    document: xml.rvn_xml_document_t,
};

const ComponentRegistry = extern struct {
    items: [*c]rvn_component_t,
    count: u32,
    cap: u32,
    /// Number of instances made so far: the value of {Instance}.
    instances: u32,
};

var g_components: ComponentRegistry = std.mem.zeroes(ComponentRegistry);

const rvn_xc_var_t = extern struct {
    name: [*c]const u8,
    value: [*c]const u8,
    next: [*c]rvn_xc_var_t,
};

const rvn_xc_scope_t = extern struct {
    vars: [*c]rvn_xc_var_t,
    /// Enclosing variables (<Repeat> inside a <Widget>); NULL for the body of a <Widget>, which only sees its parameters.
    parent: [*c]const rvn_xc_scope_t,
    /// Where the widget being expanded is used: its children are what <Children/> stands for.
    use: [*c]const xml.rvn_xml_node_t,
    use_scope: [*c]const rvn_xc_scope_t,
};

const rvn_xc_t = extern struct {
    document: [*c]xml.rvn_xml_document_t,
    depth: c_int,
    failed: c_int,
    registered: c_int,
};

/// A value of the expression language: a text, also a number when it reads as one.
const rvn_xv_t = extern struct {
    text: [*c]const u8,
    number: f64,
    is_number: c_int,
};

const rvn_xe_t = extern struct {
    ctx: [*c]rvn_xc_t,
    scope: [*c]const rvn_xc_scope_t,
    where: [*c]const xml.rvn_xml_node_t,
    cursor: [*c]const u8,
    end: [*c]const u8,
    failed: c_int,
    depth: c_int,
};

/// RVN_ARRAY_RESERVE (base_h.RVN_ARRAY_RESERVE does not accept arrays of pointers: `[*c][*c]T` data
/// cannot coerce to ?*anyopaque there). Same logic: grow `data` to `needed` items when `cap` is too small.
fn reserveArray(data: anytype, cap: [*c]u32, needed: u32) void {
    const Item = @typeInfo(@typeInfo(@TypeOf(data)).pointer.child).pointer.child;
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(Item))));
}

// ---------------------------------------------------------------------------
//  Messages
// ---------------------------------------------------------------------------

fn rvn_xc_report(node: [*c]const xml.rvn_xml_node_t, severity: raven.RSeverity, format: [*c]const u8, ...) callconv(.c) void {
    var message: [256]u8 = undefined;
    var args = @cVaStart();
    _ = libc.vsnprintf(&message, message.len, format, &args);
    @cVaEnd(&args);
    const line: c_int = if (node != null) node.*.line else 0;
    const column: c_int = if (node != null) node.*.column else 0;
    base.rvn_error(raven.R_ERROR_XML, severity, "XML line %d, column %d: %s", line, column, @as([*c]const u8, &message));
}

// ---------------------------------------------------------------------------
//  Nodes
// ---------------------------------------------------------------------------

fn rvn_xc_node(arena: [*c]base.rvn_arena_t, like: [*c]const xml.rvn_xml_node_t, name: [*c]const u8) [*c]xml.rvn_xml_node_t {
    const node: [*c]xml.rvn_xml_node_t = @ptrCast(@alignCast(base.rvn_arena_alloc(arena, @sizeOf(xml.rvn_xml_node_t))));
    node.* = std.mem.zeroes(xml.rvn_xml_node_t);
    node.*.name = base.rvn_arena_strndup(arena, name, libc.strlen(name));
    node.*.text = "";
    if (like != null) {
        node.*.line = like.*.line;
        node.*.column = like.*.column;
        node.*.source = like.*.source;
    }
    return node;
}

fn rvn_xc_append(parent: [*c]xml.rvn_xml_node_t, child: [*c]xml.rvn_xml_node_t) void {
    child.*.parent = parent;
    child.*.next = null;
    if (parent.*.last_child != null) {
        parent.*.last_child.*.next = child;
    } else {
        parent.*.first_child = child;
    }
    parent.*.last_child = child;
}

/// Sets an attribute: replaces the value of one that exists (names without case), else adds it at the end.
fn rvn_xc_set_attribute(arena: [*c]base.rvn_arena_t, node: [*c]xml.rvn_xml_node_t, name: [*c]const u8, value: [*c]const u8) void {
    var attribute: [*c]xml.rvn_xml_attribute_t = node.*.attributes;
    var last: [*c]xml.rvn_xml_attribute_t = null;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (base.rvn_stricmp(attribute.*.name, name) == 0) {
            attribute.*.value = value;
            return;
        }
        last = attribute;
    }
    attribute = @ptrCast(@alignCast(base.rvn_arena_alloc(arena, @sizeOf(xml.rvn_xml_attribute_t))));
    attribute.*.name = base.rvn_arena_strndup(arena, name, libc.strlen(name));
    attribute.*.value = value;
    attribute.*.next = null;
    if (last != null) {
        last.*.next = attribute;
    } else {
        node.*.attributes = attribute;
    }
}

fn rvn_xc_remove_attribute(node: [*c]xml.rvn_xml_node_t, name: [*c]const u8) void {
    var link: [*c][*c]xml.rvn_xml_attribute_t = &node.*.attributes;
    while (link.* != null) {
        if (base.rvn_stricmp(link.*.*.name, name) == 0) {
            link.* = link.*.*.next;
        } else {
            link = &link.*.*.next;
        }
    }
}

/// Copies an element and everything under it, as it is.
fn rvn_xc_copy(arena: [*c]base.rvn_arena_t, source: [*c]const xml.rvn_xml_node_t) [*c]xml.rvn_xml_node_t {
    const node = rvn_xc_node(arena, source, source.*.name);
    var attribute: [*c]const xml.rvn_xml_attribute_t = undefined;
    var child: [*c]const xml.rvn_xml_node_t = undefined;
    var last: [*c]xml.rvn_xml_attribute_t = null;
    node.*.text = base.rvn_arena_strndup(arena, source.*.text, libc.strlen(source.*.text));
    attribute = source.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        const copy: [*c]xml.rvn_xml_attribute_t = @ptrCast(@alignCast(base.rvn_arena_alloc(arena, @sizeOf(xml.rvn_xml_attribute_t))));
        copy.*.name = base.rvn_arena_strndup(arena, attribute.*.name, libc.strlen(attribute.*.name));
        copy.*.value = base.rvn_arena_strndup(arena, attribute.*.value, libc.strlen(attribute.*.value));
        copy.*.next = null;
        if (last != null) {
            last.*.next = copy;
        } else {
            node.*.attributes = copy;
        }
        last = copy;
    }
    child = source.*.first_child;
    while (child != null) : (child = child.*.next) rvn_xc_append(node, rvn_xc_copy(arena, child));
    return node;
}

// ---------------------------------------------------------------------------
//  Registry
// ---------------------------------------------------------------------------

fn rvn_component_find(name: [*c]const u8) [*c]rvn_component_t {
    var i: u32 = 0;
    while (i < g_components.count) : (i += 1) {
        if (base.rvn_stricmp(g_components.items[i].name, name) == 0) return &g_components.items[i];
    }
    return null;
}

fn rvn_component_release(component: [*c]rvn_component_t) void {
    base.rvn_free(component.*.name);
    xml.rvn_xml_free(&component.*.document);
}

export fn rvn_xml_components_shutdown() void {
    var i: u32 = 0;
    while (i < g_components.count) : (i += 1) rvn_component_release(&g_components.items[i]);
    base.rvn_free(g_components.items);
    g_components = std.mem.zeroes(ComponentRegistry);
}

fn rvn_xc_reserved(name: [*c]const u8) c_int {
    const reserved = [_][*c]const u8{
        "Window", "Widget", "Widgets", "Children", "Repeat", "ForEach", "If", "Include", "Strings", "Shortcut", "Item", "Separator",
    };
    var i: usize = 0;
    while (i < reserved.len) : (i += 1) {
        if (base.rvn_stricmp(name, reserved[i]) == 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_xc_clear_source(node: [*c]xml.rvn_xml_node_t) void {
    var child = node.*.first_child;
    node.*.source = 0;
    while (child != null) : (child = child.*.next) rvn_xc_clear_source(child);
}

/// Keeps a <Widget Name="..."> for later uses of its tag. Declaring a name again replaces it.
fn rvn_xc_register(ctx: [*c]rvn_xc_t, definition: [*c]const xml.rvn_xml_node_t) void {
    const name = xml.rvn_xml_attribute(definition, "Name");
    var component: [*c]rvn_component_t = undefined;
    var cursor: [*c]const u8 = undefined;

    if (name == null or name[0] == 0) {
        rvn_xc_report(definition, raven.R_SEVERITY_ERROR, "<Widget> needs a Name: the tag it declares");
        return;
    }
    cursor = name;
    while (cursor[0] != 0) : (cursor += 1) {
        const c: u8 = cursor[0];
        const letter = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        if (!letter and !(cursor > name and ((c >= '0' and c <= '9') or c == '.' or c == '-'))) {
            rvn_xc_report(definition, raven.R_SEVERITY_ERROR, "<Widget Name=\"%.60s\">: this cannot be the name of a tag", name);
            return;
        }
    }
    if (rvn_xc_reserved(name) != 0 or widget_h.rvn_widget_class_by_name(name) != null) {
        rvn_xc_report(definition, raven.R_SEVERITY_ERROR, "<Widget Name=\"%.60s\">: this tag already exists", name);
        return;
    }
    if (definition.*.first_child == null) {
        rvn_xc_report(definition, raven.R_SEVERITY_ERROR, "<Widget Name=\"%.60s\"> is empty: it needs the element it stands for", name);
        return;
    }
    component = rvn_component_find(name);
    if (component != null) {
        rvn_component_release(component);
    } else {
        reserveArray(&g_components.items, &g_components.cap, g_components.count + 1);
        component = &g_components.items[g_components.count];
        g_components.count += 1;
    }
    component.* = std.mem.zeroes(rvn_component_t);
    component.*.name = base.rvn_strdup(name);
    base.rvn_arena_init(&component.*.document.arena, 4096);
    component.*.document.root = rvn_xc_copy(&component.*.document.arena, definition);
    // (what a use of it becomes comes from the use, not from here)
    rvn_xc_clear_source(component.*.document.root);
    ctx.*.registered += 1;
}

// ---------------------------------------------------------------------------
//  Variables
// ---------------------------------------------------------------------------

fn rvn_xc_find_var(scope_in: [*c]const rvn_xc_scope_t, name: [*c]const u8, length: usize) [*c]rvn_xc_var_t {
    var scope = scope_in;
    while (scope != null) : (scope = scope.*.parent) {
        var variable = scope.*.vars;
        while (variable != null) : (variable = variable.*.next) {
            if (libc.strlen(variable.*.name) == length and base.rvn_strnicmp(variable.*.name, name, length) == 0) return variable;
        }
    }
    return null;
}

fn rvn_xc_add_var(ctx: [*c]rvn_xc_t, scope: [*c]rvn_xc_scope_t, name: [*c]const u8, value: [*c]const u8) [*c]rvn_xc_var_t {
    const variable: [*c]rvn_xc_var_t = @ptrCast(@alignCast(base.rvn_arena_alloc(&ctx.*.document.*.arena, @sizeOf(rvn_xc_var_t))));
    variable.*.name = name;
    variable.*.value = value;
    variable.*.next = scope.*.vars;
    scope.*.vars = variable;
    return variable;
}

fn rvn_xc_number_text(ctx: [*c]rvn_xc_t, number: f64) [*c]const u8 {
    var buffer: [48]u8 = undefined;
    if (number == @floor(number) and @abs(number) < 1e15) {
        _ = libc.snprintf(&buffer, buffer.len, "%.0f", number);
    } else {
        _ = libc.snprintf(&buffer, buffer.len, "%.6g", number);
    }
    return base.rvn_arena_strndup(&ctx.*.document.*.arena, &buffer, libc.strlen(&buffer));
}

// ---------------------------------------------------------------------------
//  Expressions
//
//    expression := or [ '?' expression ':' expression ]
//    or         := and { '||' and }
//    and        := compare { '&&' compare }
//    compare    := sum [ ( '==' | '!=' | '<' | '<=' | '>' | '>=' ) sum ]
//    sum        := product { ( '+' | '-' ) product }
//    product    := unary { ( '*' | '/' | '%' ) unary }
//    unary      := ( '!' | '-' ) unary | primary
//    primary    := number | 'text' | name | name '(' arguments ')' | '(' expression ')'
//
//  A value is a text; it is also a number when it reads as one. '+' adds
//  numbers and joins texts; "", "0" and "false" are false.
// ---------------------------------------------------------------------------

fn rvn_xv_text(text: [*c]const u8) rvn_xv_t {
    var value: rvn_xv_t = undefined;
    var end: [*c]u8 = null;
    value.text = text;
    value.number = 0.0;
    value.is_number = raven.R_FALSE;
    if (text[0] != 0 and text[0] != ' ') {
        const number = libc.strtod(text, &end);
        if (end != null and end[0] == 0) {
            value.number = number;
            value.is_number = raven.R_TRUE;
        }
    }
    return value;
}

fn rvn_xv_number(e: [*c]rvn_xe_t, number: f64) rvn_xv_t {
    return .{
        .text = rvn_xc_number_text(e.*.ctx, number),
        .number = number,
        .is_number = raven.R_TRUE,
    };
}

fn rvn_xv_bool(flag: c_int) rvn_xv_t {
    const text: [*c]const u8 = if (flag != 0) "true" else "false";
    return .{
        .text = text,
        .number = if (flag != 0) 1.0 else 0.0,
        .is_number = raven.R_FALSE,
    };
}

fn rvn_xv_truth(value: rvn_xv_t) c_int {
    if (value.is_number != 0) return @intFromBool(value.number != 0.0);
    return @intFromBool(value.text[0] != 0 and base.rvn_stricmp(value.text, "false") != 0);
}

fn rvn_xe_fail(e: [*c]rvn_xe_t, message: [*c]const u8) void {
    if (e.*.failed != 0) return;
    e.*.failed = raven.R_TRUE;
    rvn_xc_report(e.*.where, raven.R_SEVERITY_WARNING, "in an expression: %s", message);
}

fn rvn_xe_space(e: [*c]rvn_xe_t) void {
    while (e.*.cursor < e.*.end and (e.*.cursor[0] == ' ' or e.*.cursor[0] == '\t' or e.*.cursor[0] == '\n' or e.*.cursor[0] == '\r')) e.*.cursor += 1;
}

fn rvn_xe_take(e: [*c]rvn_xe_t, token: [*c]const u8) c_int {
    const length: usize = libc.strlen(token);
    rvn_xe_space(e);
    const avail: usize = @intCast(e.*.end - e.*.cursor);
    if (avail < length or libc.memcmp(e.*.cursor, token, length) != 0) return raven.R_FALSE;
    e.*.cursor += length;
    return raven.R_TRUE;
}

fn rvn_xe_call(e: [*c]rvn_xe_t, name: [*c]const u8, length: usize) rvn_xv_t {
    var args: [4]rvn_xv_t = undefined;
    var count: c_int = 0;
    var text: [32]u8 = undefined;

    rvn_xe_space(e);
    if (rvn_xe_take(e, ")") == 0) {
        while (true) {
            if (count == 4) {
                rvn_xe_fail(e, "too many arguments");
                break;
            }
            args[@intCast(count)] = rvn_xe_expression(e);
            count += 1;
            if (!(e.*.failed == 0 and rvn_xe_take(e, ",") != 0)) break;
        }
        if (e.*.failed == 0 and rvn_xe_take(e, ")") == 0) rvn_xe_fail(e, "expected ')'");
    }
    if (e.*.failed != 0) return rvn_xv_text("");
    const shown_length: c_int = @intCast(@min(length, 30));
    _ = libc.snprintf(&text, text.len, "%.*s", shown_length, name);

    if (count == 2 and base.rvn_stricmp(&text, "min") == 0) return rvn_xv_number(e, if (args[0].number < args[1].number) args[0].number else args[1].number);
    if (count == 2 and base.rvn_stricmp(&text, "max") == 0) return rvn_xv_number(e, if (args[0].number > args[1].number) args[0].number else args[1].number);
    if (count == 1 and base.rvn_stricmp(&text, "round") == 0) return rvn_xv_number(e, @floor(args[0].number + 0.5));
    if (count == 1 and base.rvn_stricmp(&text, "floor") == 0) return rvn_xv_number(e, @floor(args[0].number));
    if (count == 1 and base.rvn_stricmp(&text, "ceil") == 0) return rvn_xv_number(e, @ceil(args[0].number));
    if (count == 1 and base.rvn_stricmp(&text, "abs") == 0) return rvn_xv_number(e, @abs(args[0].number));
    if (count == 1 and base.rvn_stricmp(&text, "len") == 0) return rvn_xv_number(e, @floatFromInt(base.rvn_utf8_count(args[0].text, @intCast(libc.strlen(args[0].text)))));
    if (count == 1 and base.rvn_stricmp(&text, "empty") == 0) return rvn_xv_bool(@intFromBool(args[0].text[0] == 0));
    // the first argument that is not empty: {default(Title, 'Untitled')}
    if (count == 2 and base.rvn_stricmp(&text, "default") == 0) return if (args[0].text[0] != 0) args[0] else args[1];
    if (count == 1 and (base.rvn_stricmp(&text, "upper") == 0 or base.rvn_stricmp(&text, "lower") == 0)) {
        const copy: [*c]u8 = base.rvn_arena_strndup(&e.*.ctx.*.document.*.arena, args[0].text, libc.strlen(args[0].text));
        var cursor: [*c]u8 = copy;
        const upper = base.rvn_stricmp(&text, "upper") == 0;
        while (cursor[0] != 0) : (cursor += 1) {
            if (upper and cursor[0] >= 'a' and cursor[0] <= 'z') {
                cursor[0] = cursor[0] - 32;
            } else if (!upper and cursor[0] >= 'A' and cursor[0] <= 'Z') {
                cursor[0] = cursor[0] + 32;
            }
        }
        return rvn_xv_text(copy);
    }
    rvn_xe_fail(e, "unknown function, or wrong number of arguments");
    return rvn_xv_text("");
}

fn rvn_xe_primary(e: [*c]rvn_xe_t) rvn_xv_t {
    var start: [*c]const u8 = undefined;
    rvn_xe_space(e);
    if (e.*.cursor >= e.*.end) {
        rvn_xe_fail(e, "something is missing");
        return rvn_xv_text("");
    }
    start = e.*.cursor;
    if (start[0] == '(') {
        var value: rvn_xv_t = undefined;
        e.*.cursor += 1;
        value = rvn_xe_expression(e);
        if (e.*.failed == 0 and rvn_xe_take(e, ")") == 0) rvn_xe_fail(e, "expected ')'");
        return value;
    }
    if (start[0] == '\'' or start[0] == '"') {
        const quote = start[0];
        var close: [*c]const u8 = start + 1;
        while (close < e.*.end and close[0] != quote) close += 1;
        if (close >= e.*.end) {
            rvn_xe_fail(e, "a text is not closed");
            return rvn_xv_text("");
        }
        e.*.cursor = close + 1;
        // (a quoted text is a text, even when it reads as a number)
        var value: rvn_xv_t = undefined;
        value.text = base.rvn_arena_strndup(&e.*.ctx.*.document.*.arena, start + 1, @intFromPtr(close) - @intFromPtr(start) - 1);
        value.number = libc.strtod(value.text, null);
        value.is_number = raven.R_FALSE;
        return value;
    }
    if ((start[0] >= '0' and start[0] <= '9') or start[0] == '.') {
        var end: [*c]u8 = null;
        var buffer: [64]u8 = undefined;
        const avail: usize = @intCast(e.*.end - start);
        const length: usize = if (avail < buffer.len - 1) avail else buffer.len - 1;
        const buf_ptr: [*c]u8 = &buffer;
        @memcpy(buffer[0..length], start[0..length]);
        buffer[length] = 0;
        const number = libc.strtod(&buffer, &end);
        if (end == buf_ptr) {
            rvn_xe_fail(e, "a number is wrong");
            return rvn_xv_text("");
        }
        e.*.cursor = start + (@intFromPtr(end) - @intFromPtr(buf_ptr));
        return rvn_xv_number(e, number);
    }
    if ((start[0] >= 'a' and start[0] <= 'z') or (start[0] >= 'A' and start[0] <= 'Z') or start[0] == '_') {
        var close: [*c]const u8 = start;
        var variable: [*c]rvn_xc_var_t = undefined;
        while (close < e.*.end and ((close[0] >= 'a' and close[0] <= 'z') or (close[0] >= 'A' and close[0] <= 'Z') or
            (close[0] >= '0' and close[0] <= '9') or close[0] == '_' or close[0] == '.')) close += 1;
        const length: usize = @intFromPtr(close) - @intFromPtr(start);
        e.*.cursor = close;
        rvn_xe_space(e);
        if (e.*.cursor < e.*.end and e.*.cursor[0] == '(') {
            e.*.cursor += 1;
            return rvn_xe_call(e, start, length);
        }
        if (length == 4 and base.rvn_strnicmp(start, "true", 4) == 0) return rvn_xv_bool(raven.R_TRUE);
        if (length == 5 and base.rvn_strnicmp(start, "false", 5) == 0) return rvn_xv_bool(raven.R_FALSE);
        variable = rvn_xc_find_var(e.*.scope, start, length);
        if (variable == null) {
            var message: [96]u8 = undefined;
            const shown_length: c_int = @intCast(@min(length, 60));
            _ = libc.snprintf(&message, message.len, "'%.*s' is not a parameter here", shown_length, start);
            rvn_xe_fail(e, &message);
            return rvn_xv_text("");
        }
        return rvn_xv_text(variable.*.value);
    }
    rvn_xe_fail(e, "unexpected character");
    return rvn_xv_text("");
}

fn rvn_xe_unary(e: [*c]rvn_xe_t) rvn_xv_t {
    rvn_xe_space(e);
    if (e.*.cursor < e.*.end and e.*.cursor[0] == '!' and !(e.*.cursor + 1 < e.*.end and e.*.cursor[1] == '=')) {
        e.*.cursor += 1;
        return rvn_xv_bool(@intFromBool(rvn_xv_truth(rvn_xe_unary(e)) == 0));
    }
    if (e.*.cursor < e.*.end and e.*.cursor[0] == '-') {
        e.*.cursor += 1;
        return rvn_xv_number(e, -rvn_xe_unary(e).number);
    }
    return rvn_xe_primary(e);
}

fn rvn_xe_product(e: [*c]rvn_xe_t) rvn_xv_t {
    var left = rvn_xe_unary(e);
    while (e.*.failed == 0) {
        var right: rvn_xv_t = undefined;
        rvn_xe_space(e);
        if (e.*.cursor >= e.*.end or (e.*.cursor[0] != '*' and e.*.cursor[0] != '/' and e.*.cursor[0] != '%')) break;
        const op = e.*.cursor[0];
        e.*.cursor += 1;
        right = rvn_xe_unary(e);
        if (op == '*') {
            left = rvn_xv_number(e, left.number * right.number);
        } else if (right.number == 0.0) {
            left = rvn_xv_number(e, 0.0);
        } else if (op == '/') {
            left = rvn_xv_number(e, left.number / right.number);
        } else {
            left = rvn_xv_number(e, libc.fmod(left.number, right.number));
        }
    }
    return left;
}

fn rvn_xe_sum(e: [*c]rvn_xe_t) rvn_xv_t {
    var left = rvn_xe_product(e);
    while (e.*.failed == 0) {
        var right: rvn_xv_t = undefined;
        rvn_xe_space(e);
        if (e.*.cursor >= e.*.end or (e.*.cursor[0] != '+' and e.*.cursor[0] != '-')) break;
        const op = e.*.cursor[0];
        e.*.cursor += 1;
        right = rvn_xe_product(e);
        if (op == '-') {
            left = rvn_xv_number(e, left.number - right.number);
        } else if (left.is_number != 0 and right.is_number != 0) {
            left = rvn_xv_number(e, left.number + right.number);
        } else {
            // texts are joined
            const a: usize = libc.strlen(left.text);
            const b: usize = libc.strlen(right.text);
            const joined: [*c]u8 = @ptrCast(@alignCast(base.rvn_arena_alloc(&e.*.ctx.*.document.*.arena, a + b + 1)));
            _ = libc.memcpy(joined, left.text, a);
            _ = libc.memcpy(joined + a, right.text, b + 1);
            left.text = joined;
            left.is_number = raven.R_FALSE;
            left.number = 0.0;
        }
    }
    return left;
}

fn rvn_xe_compare(e: [*c]rvn_xe_t) rvn_xv_t {
    const operators = [_][*c]const u8{ "==", "!=", "<=", ">=", "<", ">" };
    var which: c_int = 0;
    const left = rvn_xe_sum(e);
    while (which < 6) : (which += 1) {
        if (rvn_xe_take(e, operators[@intCast(which)]) != 0) break;
    }
    if (which == 6 or e.*.failed != 0) return left;
    const right = rvn_xe_sum(e);
    const order: c_int = if (left.is_number != 0 and right.is_number != 0)
        (if (left.number < right.number) -1 else if (left.number > right.number) 1 else 0)
    else
        libc.strcmp(left.text, right.text);
    switch (which) {
        0 => return rvn_xv_bool(@intFromBool(order == 0)),
        1 => return rvn_xv_bool(@intFromBool(order != 0)),
        2 => return rvn_xv_bool(@intFromBool(order <= 0)),
        3 => return rvn_xv_bool(@intFromBool(order >= 0)),
        4 => return rvn_xv_bool(@intFromBool(order < 0)),
        else => return rvn_xv_bool(@intFromBool(order > 0)),
    }
}

fn rvn_xe_and(e: [*c]rvn_xe_t) rvn_xv_t {
    var left = rvn_xe_compare(e);
    while (e.*.failed == 0 and rvn_xe_take(e, "&&") != 0) {
        const right = rvn_xe_compare(e);
        left = rvn_xv_bool(@intFromBool(rvn_xv_truth(left) != 0 and rvn_xv_truth(right) != 0));
    }
    return left;
}

fn rvn_xe_or(e: [*c]rvn_xe_t) rvn_xv_t {
    var left = rvn_xe_and(e);
    while (e.*.failed == 0 and rvn_xe_take(e, "||") != 0) {
        const right = rvn_xe_and(e);
        left = rvn_xv_bool(@intFromBool(rvn_xv_truth(left) != 0 or rvn_xv_truth(right) != 0));
    }
    return left;
}

fn rvn_xe_expression(e: [*c]rvn_xe_t) rvn_xv_t {
    var condition: rvn_xv_t = undefined;
    e.*.depth += 1;
    if (e.*.depth > 64) {
        rvn_xe_fail(e, "nested too deeply");
        e.*.depth -= 1;
        return rvn_xv_text("");
    }
    condition = rvn_xe_or(e);
    if (e.*.failed == 0 and rvn_xe_take(e, "?") != 0) {
        const yes = rvn_xe_expression(e);
        var no: rvn_xv_t = undefined;
        if (e.*.failed == 0 and rvn_xe_take(e, ":") == 0) rvn_xe_fail(e, "expected ':'");
        no = rvn_xe_expression(e);
        condition = if (rvn_xv_truth(condition) != 0) yes else no;
    }
    e.*.depth -= 1;
    return condition;
}

/// Computes one expression (what is between two braces).
fn rvn_xc_evaluate(ctx: [*c]rvn_xc_t, scope: [*c]const rvn_xc_scope_t, where: [*c]const xml.rvn_xml_node_t, text: [*c]const u8, length: usize) rvn_xv_t {
    var e: rvn_xe_t = std.mem.zeroes(rvn_xe_t);
    e.ctx = ctx;
    e.scope = scope;
    e.where = where;
    e.cursor = text;
    e.end = text + length;
    const value = rvn_xe_expression(&e);
    rvn_xe_space(&e);
    if (e.failed == 0 and e.cursor < e.end) rvn_xe_fail(&e, "something is left after the end");
    return if (e.failed != 0) rvn_xv_text("") else value;
}

/// A text of the source with its {expressions} computed. Without variables
/// around (scope NULL), the text is copied as it is.
fn rvn_xc_text(ctx: [*c]rvn_xc_t, scope: [*c]const rvn_xc_scope_t, where: [*c]const xml.rvn_xml_node_t, text: [*c]const u8) [*c]const u8 {
    const arena: [*c]base.rvn_arena_t = &ctx.*.document.*.arena;
    var out: [*c]u8 = null;
    var count: u32 = 0;
    var cap: u32 = 0;
    var cursor: [*c]const u8 = text;

    if (scope == null or (libc.strchr(text, '{') == null and libc.strchr(text, '}') == null)) return base.rvn_arena_strndup(arena, text, libc.strlen(text));
    while (cursor[0] != 0) {
        if ((cursor[0] == '{' and cursor[1] == '{') or (cursor[0] == '}' and cursor[1] == '}')) {
            reserveArray(&out, &cap, count + 2);
            out[count] = cursor[0];
            count += 1;
            cursor += 2;
        } else if (cursor[0] == '{') {
            var close: [*c]const u8 = cursor + 1;
            var quote: u8 = 0;
            // (a closing brace inside a quoted text does not end the expression)
            while (close[0] != 0 and (quote != 0 or close[0] != '}')) {
                if (quote != 0 and close[0] == quote) {
                    quote = 0;
                } else if (quote == 0 and (close[0] == '\'' or close[0] == '"')) {
                    quote = close[0];
                }
                close += 1;
            }
            if (close[0] == 0) {
                rvn_xc_report(where, raven.R_SEVERITY_WARNING, "'{' without its '}' (write \"{{\" for a brace)");
                break;
            }
            const value = rvn_xc_evaluate(ctx, scope, where, cursor + 1, @intFromPtr(close) - @intFromPtr(cursor) - 1);
            const length: usize = libc.strlen(value.text);
            reserveArray(&out, &cap, count + @as(u32, @intCast(length)) + 1);
            _ = libc.memcpy(out + @as(usize, count), value.text, length);
            count += @as(u32, @intCast(length));
            cursor = close + 1;
        } else {
            reserveArray(&out, &cap, count + 2);
            out[count] = cursor[0];
            count += 1;
            cursor += 1;
        }
    }
    const source: [*c]const u8 = if (out != null) out else "";
    const result = base.rvn_arena_strndup(arena, source, count);
    base.rvn_free(out);
    return result;
}

// ---------------------------------------------------------------------------
//  Expansion
// ---------------------------------------------------------------------------

fn rvn_xc_expand_children(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    var child = node.*.first_child;
    while (child != null and ctx.*.failed == 0) : (child = child.*.next) rvn_xc_expand(ctx, child, scope, holder);
}

/// A new set of variables inside `parent`, with the same <Children/>.
fn rvn_xc_scope_inside(scope: [*c]rvn_xc_scope_t, parent: [*c]const rvn_xc_scope_t) void {
    scope.* = std.mem.zeroes(rvn_xc_scope_t);
    scope.*.parent = parent;
    if (parent != null) {
        scope.*.use = parent.*.use;
        scope.*.use_scope = parent.*.use_scope;
    }
}

fn rvn_xc_attribute(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, name: [*c]const u8) [*c]const u8 {
    const value = xml.rvn_xml_attribute(node, name);
    return if (value != null) rvn_xc_text(ctx, scope, node, value) else null;
}

/// <Repeat Count="3" Var="i">: its content, Count times, with {i} going from 0.
fn rvn_xc_repeat(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    const count_text = rvn_xc_attribute(ctx, node, scope, "Count");
    const var_name = xml.rvn_xml_attribute(node, "Var");
    var count: c_int = if (count_text != null) @intFromFloat(libc.strtod(count_text, null)) else 0;
    var i: c_int = 0;
    if (count_text == null) rvn_xc_report(node, raven.R_SEVERITY_WARNING, "<Repeat> needs Count=\"...\"");
    if (count > 10000) {
        rvn_xc_report(node, raven.R_SEVERITY_WARNING, "<Repeat Count=\"%d\">: limited to 10000", count);
        count = 10000;
    }
    while (i < count and ctx.*.failed == 0) : (i += 1) {
        var frame: rvn_xc_scope_t = undefined;
        const name: [*c]const u8 = if (var_name != null and var_name[0] != 0) var_name else "Index";
        rvn_xc_scope_inside(&frame, scope);
        _ = rvn_xc_add_var(ctx, &frame, name, rvn_xc_number_text(ctx, @floatFromInt(i)));
        rvn_xc_expand_children(ctx, node, &frame, holder);
    }
}

/// <ForEach Items="a|b|c" Var="name">: its content once per item, with {name} and {Index}.
fn rvn_xc_for_each(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    var items: [*c]const u8 = rvn_xc_attribute(ctx, node, scope, "Items");
    const var_name = xml.rvn_xml_attribute(node, "Var");
    const index_var = xml.rvn_xml_attribute(node, "Index");
    const separator = xml.rvn_xml_attribute(node, "Separator");
    const split: u8 = if (separator != null and separator[0] != 0) separator[0] else '|';
    var index: c_int = 0;
    if (items == null) {
        rvn_xc_report(node, raven.R_SEVERITY_WARNING, "<ForEach> needs Items=\"a|b|c\"");
        return;
    }
    while (items[0] != 0 and ctx.*.failed == 0) {
        var end: [*c]const u8 = items;
        var frame: rvn_xc_scope_t = undefined;
        const name: [*c]const u8 = if (var_name != null and var_name[0] != 0) var_name else "Item";
        const index_name: [*c]const u8 = if (index_var != null and index_var[0] != 0) index_var else "Index";
        while (end[0] != 0 and end[0] != split) end += 1;
        rvn_xc_scope_inside(&frame, scope);
        const item_text = base.rvn_arena_strndup(&ctx.*.document.*.arena, items, @intFromPtr(end) - @intFromPtr(items));
        _ = rvn_xc_add_var(ctx, &frame, name, item_text);
        _ = rvn_xc_add_var(ctx, &frame, index_name, rvn_xc_number_text(ctx, @floatFromInt(index)));
        index += 1;
        rvn_xc_expand_children(ctx, node, &frame, holder);
        items = if (end[0] != 0) end + 1 else end;
    }
}

/// <Children/>: the children given where the widget is used; its own content when there are none.
fn rvn_xc_children(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    const name = rvn_xc_attribute(ctx, node, scope, "Name");
    var child: [*c]const xml.rvn_xml_node_t = undefined;
    const before = holder.*.last_child;
    var added: [*c]xml.rvn_xml_node_t = undefined;
    var found: c_int = raven.R_FALSE;

    if (scope == null or scope.*.use == null) {
        rvn_xc_report(node, raven.R_SEVERITY_WARNING, "<Children/> only means something inside a <Widget>");
        return;
    }
    child = scope.*.use.*.first_child;
    while (child != null and ctx.*.failed == 0) : (child = child.*.next) {
        const into = xml.rvn_xml_attribute(child, "Into");
        const match = if (name != null and name[0] != 0)
            (into != null and base.rvn_stricmp(into, name) == 0)
        else
            (into == null or into[0] == 0);
        if (!match) continue;
        found = raven.R_TRUE;
        // (they belong to the place of the use: its variables, and its own <Children/>)
        rvn_xc_expand(ctx, child, scope.*.use_scope, holder);
    }
    if (found == 0) rvn_xc_expand_children(ctx, node, scope, holder);
    // "Into" was for us: the widgets do not know it
    added = if (before != null) before.*.next else holder.*.first_child;
    while (added != null) : (added = added.*.next) rvn_xc_remove_attribute(added, "Into");
}

/// Marks the elements that come from nowhere as made from `source`.
fn rvn_xc_set_source(node: [*c]xml.rvn_xml_node_t, source: raven.Rid) void {
    var child = node.*.first_child;
    if (node.*.source == 0) node.*.source = source;
    while (child != null) : (child = child.*.next) rvn_xc_set_source(child, source);
}

/// A use of a declared widget: its body, with the parameters of this use.
fn rvn_xc_instantiate(ctx: [*c]rvn_xc_t, component: [*c]const rvn_component_t, use: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    const arena: [*c]base.rvn_arena_t = &ctx.*.document.*.arena;
    const definition: [*c]const xml.rvn_xml_node_t = component.*.document.root;
    var attribute: [*c]const xml.rvn_xml_attribute_t = undefined;
    const extra = rvn_xc_node(arena, use, "extra");
    const out = rvn_xc_node(arena, use, "out");
    var root: [*c]xml.rvn_xml_node_t = undefined;
    var frame: rvn_xc_scope_t = std.mem.zeroes(rvn_xc_scope_t);
    var variable: [*c]rvn_xc_var_t = undefined;

    frame.use = use;
    frame.use_scope = scope;
    // the parameters and their default values: the attributes of the declaration
    attribute = definition.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (base.rvn_stricmp(attribute.*.name, "Name") == 0) continue;
        _ = rvn_xc_add_var(ctx, &frame, base.rvn_arena_strndup(arena, attribute.*.name, libc.strlen(attribute.*.name)), base.rvn_arena_strndup(arena, attribute.*.value, libc.strlen(attribute.*.value)));
    }
    // the attributes of the use: values of parameters, or attributes for the widget it becomes
    attribute = use.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        // (If="..." decided whether the tag is used at all: it is not for the widget)
        if (base.rvn_stricmp(attribute.*.name, "If") == 0) continue;
        const value = rvn_xc_text(ctx, scope, use, attribute.*.value);
        variable = rvn_xc_find_var(&frame, attribute.*.name, libc.strlen(attribute.*.name));
        if (variable != null) {
            variable.*.value = value;
        } else {
            rvn_xc_set_attribute(arena, extra, attribute.*.name, value);
        }
    }
    // <Card>some text</Card>: the text is the Text parameter, or the Text of the widget
    if (use.*.text[0] != 0 and xml.rvn_xml_attribute(use, "Text") == null) {
        const text = rvn_xc_text(ctx, scope, use, use.*.text);
        variable = rvn_xc_find_var(&frame, "Text", 4);
        if (variable != null) {
            variable.*.value = text;
        } else {
            rvn_xc_set_attribute(arena, extra, "Text", text);
        }
    }
    g_components.instances += 1;
    _ = rvn_xc_add_var(ctx, &frame, "Instance", rvn_xc_number_text(ctx, @floatFromInt(g_components.instances)));

    rvn_xc_expand_children(ctx, definition, &frame, out);
    if (ctx.*.failed != 0) return;
    root = out.*.first_child;
    if (root == null or root.*.next != null) {
        const detail: [*c]const u8 = if (root != null) "several (wrap them in a panel)" else "none";
        rvn_xc_report(use, raven.R_SEVERITY_ERROR, "<%.60s>: a <Widget> stands for exactly one element, this one gives %s", component.*.name, detail);
        ctx.*.failed = raven.R_TRUE;
        return;
    }
    attribute = extra.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        rvn_xc_set_attribute(arena, root, attribute.*.name, attribute.*.value);
    }
    root.*.line = use.*.line;
    root.*.column = use.*.column;
    // everything the declaration gave comes from this use; the children it was given keep where they come from
    rvn_xc_set_source(root, use.*.source);
    rvn_xc_append(holder, root);
}

fn rvn_xc_include(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    const source = rvn_xc_attribute(ctx, node, scope, "Source");
    var included: xml.rvn_xml_document_t = undefined;
    var path: [*c]u8 = undefined;
    var text: [*c]u8 = undefined;
    var size: usize = 0;

    if (source == null or source[0] == 0) {
        rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<Include> needs Source=\"file.xml\"");
        return;
    }
    path = xml.rvn_xml_resolve_path(source);
    watch.rvn_live_dependency(path);
    text = base.rvn_read_file(path, &size);
    if (text == null) {
        rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<Include>: cannot read '%.160s'", path);
        base.rvn_free(path);
        return;
    }
    if (xml.rvn_xml_parse(&included, text, size) == 0) {
        rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<Include Source=\"%.80s\">: line %d, column %d: %s", source, included.error_line, included.error_column, @as([*c]const u8, &included.@"error"));
    } else {
        // (what the file declares is declared; what it contains comes here)
        rvn_xc_expand(ctx, included.root, null, holder);
    }
    xml.rvn_xml_free(&included);
    base.rvn_free(text);
    base.rvn_free(path);
}

/// Rewrites one element of the source into zero, one or several plain elements added to `holder`.
fn rvn_xc_expand(ctx: [*c]rvn_xc_t, node: [*c]const xml.rvn_xml_node_t, scope: [*c]const rvn_xc_scope_t, holder: [*c]xml.rvn_xml_node_t) void {
    const arena: [*c]base.rvn_arena_t = &ctx.*.document.*.arena;
    var attribute: [*c]const xml.rvn_xml_attribute_t = undefined;
    const component: [*c]rvn_component_t = rvn_component_find(node.*.name);
    var condition: [*c]const u8 = undefined;
    var copy: [*c]xml.rvn_xml_node_t = undefined;

    if (ctx.*.failed != 0 or node.*.name[0] == '#') return;
    ctx.*.depth += 1;
    if (ctx.*.depth > RVN_XC_MAX_DEPTH) {
        rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<%.60s>: widgets are nested too deeply (does a <Widget> contain itself?)", node.*.name);
        ctx.*.failed = raven.R_TRUE;
        ctx.*.depth -= 1;
        return;
    }

    // If="..." on any element
    condition = xml.rvn_xml_attribute(node, "If");
    if (condition != null and base.rvn_stricmp(node.*.name, "If") != 0) {
        const value = rvn_xc_text(ctx, scope, node, condition);
        if (rvn_xv_truth(rvn_xv_text(value)) == 0) {
            ctx.*.depth -= 1;
            return;
        }
    }

    if (base.rvn_stricmp(node.*.name, "Widget") == 0) {
        rvn_xc_register(ctx, node);
    } else if (base.rvn_stricmp(node.*.name, "Widgets") == 0) {
        // a file of declarations: only a container
        rvn_xc_expand_children(ctx, node, scope, holder);
    } else if (base.rvn_stricmp(node.*.name, "Include") == 0) {
        rvn_xc_include(ctx, node, scope, holder);
    } else if (base.rvn_stricmp(node.*.name, "Strings") == 0) {
        // <Strings Source="strings.csv"/>: a table of translations (raven_locale.h)
        const source = rvn_xc_attribute(ctx, node, scope, "Source");
        if (source == null or source[0] == 0) {
            rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<Strings> needs Source=\"strings.csv\"");
        } else {
            const path = xml.rvn_xml_resolve_path(source);
            if (raven.Rlocale_load_csv(path) < 0) rvn_xc_report(node, raven.R_SEVERITY_ERROR, "<Strings>: cannot load '%.160s'", path);
            base.rvn_free(path);
        }
    } else if (base.rvn_stricmp(node.*.name, "Children") == 0) {
        rvn_xc_children(ctx, node, scope, holder);
    } else if (base.rvn_stricmp(node.*.name, "Repeat") == 0) {
        rvn_xc_repeat(ctx, node, scope, holder);
    } else if (base.rvn_stricmp(node.*.name, "ForEach") == 0) {
        rvn_xc_for_each(ctx, node, scope, holder);
    } else if (base.rvn_stricmp(node.*.name, "If") == 0) {
        const test_text = rvn_xc_attribute(ctx, node, scope, "Test");
        if (test_text == null) {
            rvn_xc_report(node, raven.R_SEVERITY_WARNING, "<If> needs Test=\"...\"");
        } else if (rvn_xv_truth(rvn_xv_text(test_text)) != 0) {
            rvn_xc_expand_children(ctx, node, scope, holder);
        }
    } else if (component != null) {
        rvn_xc_instantiate(ctx, component, node, scope, holder);
    } else {
        // an ordinary element: itself, with what is inside rewritten
        copy = rvn_xc_node(arena, node, node.*.name);
        copy.*.text = rvn_xc_text(ctx, scope, node, node.*.text);
        attribute = node.*.attributes;
        while (attribute != null) : (attribute = attribute.*.next) {
            if (base.rvn_stricmp(attribute.*.name, "If") == 0) continue;
            rvn_xc_set_attribute(arena, copy, attribute.*.name, rvn_xc_text(ctx, scope, node, attribute.*.value));
        }
        rvn_xc_append(holder, copy);
        rvn_xc_expand_children(ctx, node, scope, copy);
    }
    ctx.*.depth -= 1;
}

export fn rvn_xml_expand(document: [*c]xml.rvn_xml_document_t, registered: [*c]c_int) c_int {
    var ctx: rvn_xc_t = undefined;
    var holder: [*c]xml.rvn_xml_node_t = undefined;

    if (registered != null) registered.* = 0;
    if (document.*.root == null) return raven.R_TRUE;
    ctx = std.mem.zeroes(rvn_xc_t);
    ctx.document = document;
    holder = rvn_xc_node(&document.*.arena, document.*.root, "document");
    rvn_xc_expand(&ctx, document.*.root, null, holder);
    if (registered != null) registered.* = ctx.registered;
    if (ctx.failed != 0) {
        document.*.root = null;
        return raven.R_FALSE;
    }
    if (holder.*.first_child != null and holder.*.first_child.*.next != null) {
        rvn_xc_report(holder.*.first_child.*.next, raven.R_SEVERITY_ERROR, "a document has a single root element besides its <Widget> declarations");
        document.*.root = null;
        return raven.R_FALSE;
    }
    document.*.root = holder.*.first_child;
    if (document.*.root != null) document.*.root.*.parent = null;
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rxml_register_widgets(xml_text: [*c]const u8, size: usize) c_int {
    var document: xml.rvn_xml_document_t = undefined;
    var registered: c_int = 0;
    if (context.rvn_api_check("Rxml_register_widgets") == 0) return 0;
    if (xml_text == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rxml_register_widgets: NULL text");
        return 0;
    }
    if (xml.rvn_xml_parse(&document, xml_text, size) == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "Rxml_register_widgets: line %d, column %d: %s", document.error_line, document.error_column, @as([*c]const u8, &document.@"error"));
        xml.rvn_xml_free(&document);
        return 0;
    }
    _ = rvn_xml_expand(&document, &registered);
    xml.rvn_xml_free(&document);
    return registered;
}

export fn rvn_xml_component_parameter(component_name: [*c]const u8, index: c_int, name: [*c][*c]const u8, default_value: [*c][*c]const u8) c_int {
    const component = if (component_name != null) rvn_component_find(component_name) else null;
    var attribute: [*c]const xml.rvn_xml_attribute_t = undefined;
    var remaining: c_int = index;
    if (component == null or index < 0) return raven.R_FALSE;
    attribute = component.*.document.root.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (base.rvn_stricmp(attribute.*.name, "Name") == 0) continue;
        const hit = remaining == 0;
        remaining -= 1;
        if (hit) {
            if (name != null) name.* = attribute.*.name;
            if (default_value != null) default_value.* = attribute.*.value;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

export fn Rxml_unregister_widget(name: [*c]const u8) void {
    var component: [*c]rvn_component_t = undefined;
    if (context.rvn_api_check("Rxml_unregister_widget") == 0) return;
    component = if (name != null) rvn_component_find(name) else null;
    if (component == null) return;
    rvn_component_release(component);
    g_components.count -= 1;
    component.* = g_components.items[g_components.count];
}

export fn Rxml_is_widget_registered(name: [*c]const u8) c_int {
    return @intFromBool(context.g_rvn.initialized != 0 and name != null and rvn_component_find(name) != null);
}

export fn Rxml_get_registered_widget_count() c_int {
    return if (context.g_rvn.initialized != 0) @as(c_int, @intCast(g_components.count)) else 0;
}

export fn Rxml_get_registered_widget_name(index: c_int) [*c]const u8 {
    if (context.g_rvn.initialized == 0 or index < 0 or index >= @as(c_int, @intCast(g_components.count))) return null;
    return g_components.items[@intCast(index)].name;
}
