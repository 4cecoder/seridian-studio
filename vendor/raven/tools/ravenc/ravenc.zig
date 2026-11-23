// Translated to Zig from vendor/raven/tools/ravenc/ravenc.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
// The output is byte-for-byte the output of the C program (tools/ravenc/compare.cmake checks it against
// deprecated-c/tools/ravenc/ravenc.c). C strings are slices here: a value that held a NUL byte in C ended
// there, so every stored string is cut at its first NUL (`cstr`), as the C functions saw it.
//
// Raven - tools/ravenc/ravenc.c
// The XMLC compiler: an interface in XML with its code, in one file, turned
// into one source file of the language. Nothing is read or interpreted at run
// time: the interface becomes a table of RXmlCompiledNode.
//
//     ravenc main.xmlc -o main.xmlc.c [--name main] [--lang c]
//
//   .xmlc    C        CMake: raven_target_xmlc
//   .xmlc++  C++      (or .xmlcpp) CMake: raven_target_xmlc
//   .xmlrs   Rust     build.rs: raven_build::compile (bindings/rust-build)
//   .xmlpy   Python   import raven_xmlpy, then import the module (bindings/python)
//   .xmlgo   Go       //go:generate ravenc main.xmlgo -o main.xmlgo.go
//   .xmlcs   C#       Raven.XmlCs.targets (bindings/csharp)
//   .xmlzig  Zig      build.zig: xmlzig.add (bindings/zig)
//   .xmllua  LuaJIT   require("raven_xmllua") (bindings/luajit)
//
// An .xmlc file:
//
//     <script>
//     #include <stdio.h>
//     static int clicks = 0;
//     static void on_ok(Rid sender, const char* action, void* user) {
//         Rlabel_set_text(ui.status, "Clicked");      // ui: the widgets that have a Name
//         clicks++;
//     }
//     int main(void) {
//         Rinit(R_BACKEND_VULKAN);
//         main_create();                              // made by ravenc from the file name
//         while (Rdraw_frame()) {}
//         Rshutdown();
//         return 0;
//     }
//     </script>
//
//     <Window Title="Hello" Width="400" Height="200">
//         <VBox>
//             <Label Name="status">Not clicked</Label>
//             <Button Text="OK" OnClicked="{on_ok}"/>
//         </VBox>
//     </Window>
//
// - <script> holds plain code of the language (no XML escaping: a < b and &&
//   are written as is), at the top level of the file, as many as wanted.
//   C and C++ get #line; Rust, Go, C# and Zig keep the scripts on the lines
//   they have in the file: the errors of the compiler point into it either way.
// - One interface element at the top level: a <Window> (NAME_create returns
//   the window) or any widget (NAME_create returns the widget).
// - Action="{f}", OnClicked="{f}", OnChanged="{f}", OnCommitted="{f}",
//   OnActivated="{f}": the function f of the scripts (a path is allowed:
//   App.on_ok), checked by the compiler of the language:
//     C       void f(Rid sender, const char* action, void* user_data)
//     C++     the same, or void f(Rid, const char*), or anything callable like it
//     Rust    fn f(sender: Rid, action: &str)
//     Python  def f(sender, action)
//     Go      func f(sender raven.ID, action string)
//     C#      static void F(uint sender, string action)   (Program.F, or a method of NAMEUi)
//     Zig     fn f(sender: Rid, action: ?[*:0]const u8, user_data: ?*anyopaque) callconv(.C) void
//     Lua     function f(sender, action)   (a global function, or App.f)
//   Without braces, an action name as in XML.
// - Name="x" (an identifier): the widget once NAME_create has run, as
//   ui.x (C, C++, Python, Go, Zig, Lua), ui().x (Rust), NAMEUi.x (C#).
// - Everything else is the XML of Raven, built exactly as Rwindow_create_from_xml would.
//
// No header is written: another file declares NAME_create itself.
//
// Standalone (no dependency but the Zig standard library): it runs on the build machine.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `Compile`: the input is wrong; the message is in `Ravenc.diag`, its line in `Ravenc.diag_line`.
const Error = error{ Compile, OutOfMemory };

// ---------------------------------------------------------------------------
//  Small tools
// ---------------------------------------------------------------------------

/// C's isspace in the "C" locale.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

/// A C string seen as such: the bytes before the first NUL.
fn cstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// The output being written, and how many '\n' it holds (for #line and the script positions).
const Buffer = struct {
    data: std.ArrayList(u8) = .empty,
    lines: i32 = 0,

    fn add(b: *Buffer, gpa: Allocator, s: []const u8) Allocator.Error!void {
        try b.data.appendSlice(gpa, s);
        b.lines += @intCast(std.mem.count(u8, s, "\n"));
    }

    fn puts(b: *Buffer, gpa: Allocator, s: []const u8) Allocator.Error!void {
        try b.add(gpa, cstr(s));
    }

    fn print(b: *Buffer, gpa: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!void {
        const start = b.data.items.len;
        try b.data.print(gpa, format, args);
        b.lines += @intCast(std.mem.count(u8, b.data.items[start..], "\n"));
    }

    /// A C string literal of any text (UTF-8 kept as is).
    fn cstring(b: *Buffer, gpa: Allocator, s_: []const u8) Allocator.Error!void {
        const s = cstr(s_);
        try b.puts(gpa, "\"");
        for (s, 0..) |c, i| {
            if (c == '"' or c == '\\') {
                try b.add(gpa, &.{ '\\', c });
            } else if (c == '\n') {
                try b.puts(gpa, "\\n");
            } else if (c == '\r') {
                try b.puts(gpa, "\\r");
            } else if (c == '\t') {
                try b.puts(gpa, "\\t");
            } else if (c == '?' and i + 1 < s.len and s[i + 1] == '?') {
                try b.puts(gpa, "?\"\""); // no trigraphs
            } else if (c < 0x20) {
                try b.print(gpa, "\\{o:0>3}", .{c});
            } else {
                try b.add(gpa, &.{c});
            }
        }
        try b.puts(gpa, "\"");
    }

    /// A string literal: C and C++ (octal escapes, no trigraphs), and the others
    /// with \xHH (C#: \u00HH; Rust byte strings: every byte above 127 escaped too).
    fn literal(b: *Buffer, gpa: Allocator, s_: []const u8, lang: Lang) Allocator.Error!void {
        if (lang == .c or lang == .cpp) return b.cstring(gpa, s_);
        const s = cstr(s_);
        try b.puts(gpa, if (lang == .rust) "b\"" else "\"");
        for (s) |c| {
            if (c == '"' or c == '\\') {
                try b.add(gpa, &.{ '\\', c });
            } else if (c == '\n') {
                try b.puts(gpa, "\\n");
            } else if (c == '\r') {
                try b.puts(gpa, "\\r");
            } else if (c == '\t') {
                try b.puts(gpa, "\\t");
            } else if (c < 0x20 or c == 0x7F or (lang == .rust and c >= 0x80)) {
                if (lang == .csharp) try b.print(gpa, "\\u{X:0>4}", .{c}) else try b.print(gpa, "\\x{X:0>2}", .{c});
            } else {
                try b.add(gpa, &.{c});
            }
        }
        try b.puts(gpa, if (lang == .rust) "\\0\"" else "\"");
    }

    /// A Rust literal is a pointer: b"...\0".as_ptr() as *const c_char
    fn rustPtr(b: *Buffer, gpa: Allocator, s: []const u8) Allocator.Error!void {
        try b.literal(gpa, s, .rust);
        try b.puts(gpa, ".as_ptr() as *const ::std::os::raw::c_char");
    }
};

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn iequal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// C's trim: the text without the white space around it.
fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and isSpace(s[start])) start += 1;
    var end = s.len;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

// ---------------------------------------------------------------------------
//  The file: scripts and elements
// ---------------------------------------------------------------------------

const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

const Node = struct {
    tag: []const u8,
    /// text content, trimmed
    text: []const u8 = "",
    attributes: std.ArrayList(Attribute) = .empty,
    parent: ?*Node,
    children: std.ArrayList(*Node) = .empty,
    line: i32,
    /// in the table
    index: i32 = 0,
};

const Script = struct {
    code: []const u8,
    /// line of the first character of the code
    line: i32,
};

const Parser = struct {
    src: []const u8,
    p: usize,
    line: i32,
    scripts: std.ArrayList(Script) = .empty,
    root: ?*Node = null,

    /// The byte at the cursor; 0 at the end (the C program read the NUL after the file).
    fn cur(ps: *const Parser) u8 {
        return if (ps.p < ps.src.len) ps.src[ps.p] else 0;
    }

    fn atEnd(ps: *const Parser) bool {
        return ps.p >= ps.src.len;
    }

    fn advance(ps: *Parser, n: usize) void {
        var i: usize = 0;
        while (i < n and ps.p < ps.src.len) : ({
            i += 1;
            ps.p += 1;
        }) {
            if (ps.src[ps.p] == '\n') ps.line += 1;
        }
    }

    fn starts(ps: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, ps.src[ps.p..], s);
    }

    fn startsI(ps: *const Parser, s: []const u8) bool {
        if (ps.src.len - ps.p < s.len) return false;
        return std.ascii.eqlIgnoreCase(ps.src[ps.p..][0..s.len], s);
    }

    fn skipSpace(ps: *Parser) void {
        while (ps.p < ps.src.len and isSpace(ps.src[ps.p])) ps.advance(1);
    }
};

/// One action function named in braces.
const Binding = struct {
    function: []const u8,
    action: []const u8,
    line: i32,
};

const Lang = enum { c, cpp, rust, python, go, csharp, zig, lua };

const languages = [_]struct { name: []const u8, extension: []const u8, lang: Lang }{
    .{ .name = "c", .extension = "xmlc", .lang = .c },
    .{ .name = "cpp", .extension = "xmlc++", .lang = .cpp },
    .{ .name = "c++", .extension = "xmlcpp", .lang = .cpp },
    .{ .name = "rust", .extension = "xmlrs", .lang = .rust },
    .{ .name = "python", .extension = "xmlpy", .lang = .python },
    .{ .name = "go", .extension = "xmlgo", .lang = .go },
    .{ .name = "csharp", .extension = "xmlcs", .lang = .csharp },
    .{ .name = "zig", .extension = "xmlzig", .lang = .zig },
    .{ .name = "lua", .extension = "xmllua", .lang = .lua },
};

fn languageNamed(name: []const u8) ?Lang {
    for (languages) |l| {
        if (iequal(name, l.name) or iequal(name, l.extension)) return l.lang;
    }
    if (iequal(name, "rs")) return .rust;
    if (iequal(name, "py")) return .python;
    if (iequal(name, "cs") or iequal(name, "c#")) return .csharp;
    return null;
}

fn baseName(path: []const u8) []const u8 {
    var base: usize = 0;
    for (path, 0..) |c, i| if (c == '/' or c == '\\') {
        base = i + 1;
    };
    return path[base..];
}

fn languageOfFile(path: []const u8) ?Lang {
    const base = baseName(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    return languageNamed(base[dot + 1 ..]);
}

/// The compiler: what the C program kept in globals.
const Ravenc = struct {
    gpa: Allocator,
    diag: std.ArrayList(u8) = .empty,
    diag_line: i32 = 0,
    table: std.ArrayList(*Node) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    bindings: std.ArrayList(Binding) = .empty,

    /// die(): keeps the message for main, which prints "<file>:<line>: error: <message>".
    fn die(rc: *Ravenc, line: i32, comptime format: []const u8, args: anytype) Error {
        rc.diag_line = line;
        rc.diag.clearRetainingCapacity();
        try rc.diag.print(rc.gpa, format, args);
        return error.Compile;
    }

    // ---- parsing ----

    /// Skips what is not content: comments, <?...?>, <!DOCTYPE ...>. true when something was skipped.
    fn skipMisc(rc: *Ravenc, ps: *Parser) Error!bool {
        if (ps.starts("<!--")) {
            const line = ps.line;
            while (ps.p < ps.src.len and !ps.starts("-->")) ps.advance(1);
            if (ps.atEnd()) return rc.die(line, "unterminated comment", .{});
            ps.advance(3);
            return true;
        }
        if (ps.starts("<?") or ps.starts("<!DOCTYPE") or ps.starts("<!doctype")) {
            const line = ps.line;
            while (ps.p < ps.src.len and ps.src[ps.p] != '>') ps.advance(1);
            if (ps.atEnd()) return rc.die(line, "unterminated declaration", .{});
            ps.advance(1);
            return true;
        }
        return false;
    }

    fn readName(rc: *Ravenc, ps: *Parser) Error![]const u8 {
        const start = ps.p;
        while (ps.p < ps.src.len) {
            const c = ps.src[ps.p];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c >= 0x80)) break;
            ps.advance(1);
        }
        if (ps.p == start) return rc.die(ps.line, "a name is expected here", .{});
        return try rc.gpa.dupe(u8, ps.src[start..ps.p]);
    }

    /// Appends the UTF-8 of a code point.
    fn putUtf8(rc: *Ravenc, b: *Buffer, c: u64) Allocator.Error!void {
        var s = [_]u8{ 0, 0, 0, 0 };
        if (c < 0x80) {
            s[0] = @truncate(c);
        } else if (c < 0x800) {
            s[0] = @truncate(0xC0 | (c >> 6));
            s[1] = @truncate(0x80 | (c & 63));
        } else if (c < 0x10000) {
            s[0] = @truncate(0xE0 | (c >> 12));
            s[1] = @truncate(0x80 | ((c >> 6) & 63));
            s[2] = @truncate(0x80 | (c & 63));
        } else {
            s[0] = @truncate(0xF0 | (c >> 18));
            s[1] = @truncate(0x80 | ((c >> 12) & 63));
            s[2] = @truncate(0x80 | ((c >> 6) & 63));
            s[3] = @truncate(0x80 | (c & 63));
        }
        try b.puts(rc.gpa, &s);
    }

    /// Reads an entity after '&'.
    fn readEntity(rc: *Ravenc, ps: *Parser, out: *Buffer) Error!void {
        const line = ps.line;
        var semi = ps.p;
        while (semi < ps.src.len and ps.src[semi] != ';' and semi - ps.p < 12) semi += 1;
        if (semi >= ps.src.len or ps.src[semi] != ';') return rc.die(line, "'&' must start an entity (&amp; for the character itself)", .{});
        const n = semi - ps.p;
        const name = cstr(ps.src[ps.p..semi]);
        if (std.mem.eql(u8, name, "amp")) {
            try out.puts(rc.gpa, "&");
        } else if (std.mem.eql(u8, name, "lt")) {
            try out.puts(rc.gpa, "<");
        } else if (std.mem.eql(u8, name, "gt")) {
            try out.puts(rc.gpa, ">");
        } else if (std.mem.eql(u8, name, "quot")) {
            try out.puts(rc.gpa, "\"");
        } else if (std.mem.eql(u8, name, "apos")) {
            try out.puts(rc.gpa, "'");
        } else if (name.len > 0 and name[0] == '#') {
            const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
            const c = strtoul(if (hex) name[2..] else name[1..], if (hex) 16 else 10) orelse
                return rc.die(line, "bad character reference &{s};", .{name});
            if (c == 0 or c > 0x10FFFF) return rc.die(line, "bad character reference &{s};", .{name});
            try rc.putUtf8(out, c);
        } else return rc.die(line, "unknown entity &{s};", .{name});
        ps.advance(n + 1);
    }

    fn readScript(rc: *Ravenc, ps: *Parser, line: i32) Error!void {
        // after <script ...>: plain C until </script>
        ps.skipSpace();
        if (ps.starts("/>")) {
            ps.advance(2);
            return;
        }
        if (ps.cur() != '>') return rc.die(ps.line, "<script> takes no attributes", .{});
        ps.advance(1);
        const start = ps.p;
        const code_line = ps.line;
        while (ps.p < ps.src.len and !ps.startsI("</script")) ps.advance(1);
        if (ps.atEnd()) return rc.die(line, "<script> is not closed (</script>)", .{});
        try ps.scripts.append(rc.gpa, .{ .code = cstr(ps.src[start..ps.p]), .line = code_line });
        ps.advance(8);
        ps.skipSpace();
        if (ps.cur() != '>') return rc.die(ps.line, "'>' expected after </script", .{});
        ps.advance(1);
    }

    /// Content of an element until its closing tag.
    fn readContent(rc: *Ravenc, ps: *Parser, node: *Node) Error!void {
        var text: Buffer = .{};
        while (true) {
            if (ps.atEnd()) return rc.die(node.line, "<{s}> is not closed", .{node.tag});
            if (ps.starts("</")) {
                ps.advance(2);
                const name = try rc.readName(ps);
                if (!std.mem.eql(u8, name, node.tag)) return rc.die(ps.line, "</{s}> closes <{s}>", .{ name, node.tag });
                ps.skipSpace();
                if (ps.cur() != '>') return rc.die(ps.line, "'>' expected", .{});
                ps.advance(1);
                break;
            }
            if (ps.starts("<![CDATA[")) {
                ps.advance(9);
                const start = ps.p;
                while (ps.p < ps.src.len and !ps.starts("]]>")) ps.advance(1);
                if (ps.atEnd()) return rc.die(node.line, "unterminated CDATA", .{});
                try text.add(rc.gpa, ps.src[start..ps.p]);
                ps.advance(3);
                continue;
            }
            if (try rc.skipMisc(ps)) continue;
            if (ps.cur() == '<') {
                if (ps.startsI("<script")) return rc.die(ps.line, "<script> goes at the top level of the file, not inside <{s}>", .{node.tag});
                _ = try rc.readElement(ps, node);
                continue;
            }
            if (ps.cur() == '&') {
                ps.advance(1);
                try rc.readEntity(ps, &text);
                continue;
            }
            try text.add(rc.gpa, ps.src[ps.p..][0..1]);
            ps.advance(1);
        }
        node.text = trim(cstr(text.data.items));
    }

    fn readElement(rc: *Ravenc, ps: *Parser, parent: ?*Node) Error!*Node {
        const node = try rc.gpa.create(Node);
        node.* = .{ .tag = "", .parent = parent, .line = ps.line };
        ps.advance(1); // <
        node.tag = try rc.readName(ps);
        if (parent) |p| try p.children.append(rc.gpa, node);
        while (true) {
            ps.skipSpace();
            if (ps.atEnd()) return rc.die(node.line, "<{s}> is not closed", .{node.tag});
            if (ps.starts("/>")) {
                ps.advance(2);
                node.text = "";
                return node;
            }
            if (ps.cur() == '>') {
                ps.advance(1);
                try rc.readContent(ps, node);
                return node;
            }
            var value: Buffer = .{};
            const name = try rc.readName(ps);
            ps.skipSpace();
            if (ps.cur() != '=') return rc.die(ps.line, "'=' expected after {s}", .{name});
            ps.advance(1);
            ps.skipSpace();
            const quote = ps.cur();
            if (quote != '"' and quote != '\'') return rc.die(ps.line, "the value of {s} must be in quotes", .{name});
            ps.advance(1);
            while (ps.p < ps.src.len and ps.src[ps.p] != quote) {
                if (ps.src[ps.p] == '&') {
                    ps.advance(1);
                    try rc.readEntity(ps, &value);
                    continue;
                }
                if (ps.src[ps.p] == '<') return rc.die(ps.line, "'<' in a value: write &lt;", .{});
                try value.add(rc.gpa, ps.src[ps.p..][0..1]);
                ps.advance(1);
            }
            if (ps.atEnd()) return rc.die(node.line, "unterminated value of {s}", .{name});
            ps.advance(1);
            try node.attributes.append(rc.gpa, .{ .name = name, .value = cstr(value.data.items) });
        }
    }

    fn parse(rc: *Ravenc, ps: *Parser) Error!void {
        while (true) {
            ps.skipSpace();
            if (ps.atEnd()) break;
            if (try rc.skipMisc(ps)) continue;
            if (ps.startsI("<script")) {
                const line = ps.line;
                ps.advance(7);
                if (ps.p < ps.src.len and !isSpace(ps.src[ps.p]) and ps.src[ps.p] != '>' and ps.src[ps.p] != '/') return rc.die(line, "unknown element at the top level", .{});
                try rc.readScript(ps, line);
                continue;
            }
            if (ps.cur() == '<') {
                const line = ps.line;
                const node = try rc.readElement(ps, null);
                if (ps.root != null) return rc.die(line, "a second interface element <{s}>: an .xmlc file has one (<Window> or a widget), and <script> blocks", .{node.tag});
                ps.root = node;
                continue;
            }
            return rc.die(ps.line, "text outside of an element (C code goes in <script>)", .{});
        }
    }

    // ---- the table ----

    fn collect(rc: *Ravenc, node: *Node, unit: []const u8) Error!void {
        node.index = @intCast(rc.table.items.len);
        try rc.table.append(rc.gpa, node);
        for (node.attributes.items) |*a| {
            const n = a.value.len;
            if (isEvent(a.name) and n >= 2 and a.value[0] == '{' and a.value[n - 1] == '}') {
                const function = trim(a.value[1 .. n - 1]);
                if (isTemplateParameter(node, function)) continue;
                if (!isCallable(function)) return rc.die(node.line, "{s}=\"{s}\": the braces hold the name of a function", .{ a.name, a.value });
                var found: ?usize = null;
                for (rc.bindings.items, 0..) |b, i| if (std.mem.eql(u8, b.function, function)) {
                    found = i;
                };
                if (found == null) {
                    // char action[512]; snprintf(action, sizeof(action), "ravenc.%s.%s", unit, function);
                    const full = try std.fmt.allocPrint(rc.gpa, "ravenc.{s}.{s}", .{ unit, function });
                    try rc.bindings.append(rc.gpa, .{ .function = function, .action = full[0..@min(full.len, 511)], .line = node.line });
                    found = rc.bindings.items.len - 1;
                }
                a.value = rc.bindings.items[found.?].action;
            }
            if (iequal(a.name, "Name") and isIdentifier(a.value) and !insideDeclaration(node) and !iequal(node.tag, "Widget")) {
                var seen = false;
                for (rc.names.items) |name| if (std.mem.eql(u8, name, a.value)) {
                    seen = true;
                };
                if (!seen) try rc.names.append(rc.gpa, a.value);
            }
        }
        for (node.children.items) |child| try rc.collect(child, unit);
    }
};

/// strtoul(text, &tail, base) with `*tail == 0` required: null when the text is not a whole number.
/// Like the C library: leading white space, a sign, "0x" for base 16; overflow and negative numbers
/// give values above 0x10FFFF, which the caller refuses.
fn strtoul(text: []const u8, base: u8) ?u64 {
    var i: usize = 0;
    while (i < text.len and isSpace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    if (base == 16 and i + 2 < text.len + 1 and i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X') and
        i + 2 < text.len and std.ascii.isHex(text[i + 2])) i += 2;
    const digits_start = i;
    var value: u64 = 0;
    var overflow = false;
    while (i < text.len) : (i += 1) {
        const d = std.fmt.charToDigit(text[i], base) catch break;
        const mul = @mulWithOverflow(value, @as(u64, base));
        const add = @addWithOverflow(mul[0], @as(u64, d));
        if (mul[1] != 0 or add[1] != 0) overflow = true;
        value = add[0];
    }
    // no digits: the C tail is the start of the text, which ends there only when the text is empty
    if (i == digits_start) return if (text.len == 0) 0 else null;
    if (i != text.len) return null;
    if (overflow) return std.math.maxInt(u64);
    return if (negative) 0 -% value else value;
}

fn isEvent(name: []const u8) bool {
    return iequal(name, "Action") or iequal(name, "OnClicked") or iequal(name, "OnChanged") or
        iequal(name, "OnCommitted") or iequal(name, "OnActivated");
}

/// What the braces may hold: a name, or a path to one (App.on_ok, crate::ui::on_ok).
fn isCallable(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':')) return false;
    return true;
}

fn insideDeclaration(node_: *const Node) bool {
    // the body of a <Widget> declaration is a template: its names belong to each use
    var node = node_.parent;
    while (node) |n| : (node = n.parent) if (iequal(n.tag, "Widget")) return true;
    return false;
}

/// {Text} in the body of <Widget Text="..."> is a parameter of the declaration, not a function
fn isTemplateParameter(node_: *const Node, name: []const u8) bool {
    var node = node_.parent;
    while (node) |n| : (node = n.parent) {
        if (!iequal(n.tag, "Widget")) continue;
        for (n.attributes.items) |a| if (std.mem.eql(u8, a.name, name)) return true;
    }
    return false;
}

fn lineDirective(gpa: Allocator, out: *Buffer, line: i32, path: []const u8) Allocator.Error!void {
    try out.print(gpa, "#line {d} ", .{line});
    try out.cstring(gpa, path);
    try out.puts(gpa, "\n");
}

fn forwardSlashes(gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const r = try gpa.dupe(u8, s);
    std.mem.replaceScalar(u8, r, '\\', '/');
    return r;
}

/// "dir/my-app.xmlc" -> "my_app"
fn unitName(gpa: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const base = baseName(path);
    const n = std.mem.indexOfScalar(u8, base, '.') orelse base.len;
    var name: []u8 = undefined;
    if (n == 0) {
        name = try gpa.dupe(u8, "x");
    } else {
        name = try gpa.dupe(u8, base[0..n]);
    }
    for (name) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '_';
    };
    if (std.ascii.isDigit(name[0])) return std.mem.concat(gpa, u8, &.{ "_", name });
    return name;
}

fn parentIndex(n: *const Node) i32 {
    return if (n.parent) |p| p.index else -1;
}

// ---------------------------------------------------------------------------
//  The languages
// ---------------------------------------------------------------------------

/// What every emitter needs.
const Emit = struct {
    gpa: Allocator,
    out: *Buffer,
    ps: *const Parser,
    rc: *const Ravenc,
    unit: []const u8,
    source_path: []const u8,
    is_window: bool,

    fn puts(e: Emit, s: []const u8) Allocator.Error!void {
        try e.out.puts(e.gpa, s);
    }
    fn print(e: Emit, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try e.out.print(e.gpa, format, args);
    }
    fn literal(e: Emit, s: []const u8, lang: Lang) Allocator.Error!void {
        try e.out.literal(e.gpa, s, lang);
    }
    fn create(e: Emit) []const u8 {
        return if (e.is_window) "Rwindow_create_from_compiled" else "Rwidget_create_from_compiled";
    }

    /// The scripts on the lines they have in the source, the other lines left
    /// empty: what the compiler of the language reports is at the right line of
    /// the .xml file. `first_line` is a line of our own that goes before the
    /// first script, or null.
    fn scriptsInPlace(e: Emit, scripts: []const Script, first_line: ?[]const u8) Allocator.Error!void {
        if (first_line) |first| {
            try e.puts(first);
            // a script that starts on the first line: ours shares it, the lines stay those of the file
            try e.puts(if (scripts.len > 0 and scripts[0].line <= 1) "; " else "\n");
        }
        for (scripts) |script| {
            while (e.out.lines + 1 < script.line) try e.puts("\n");
            try e.puts(script.code);
        }
        try e.puts("\n");
    }

    // ---- C and C++ ----

    fn cLike(e: Emit, lang: Lang, out_path: []const u8) Allocator.Error!void {
        const rc = e.rc;
        try e.print("/* Generated by ravenc from {s}: edit it, not this file. */\n", .{e.source_path});
        try e.puts("#include <Raven.h>\n\n");
        if (lang == .cpp) {
            try e.puts("#include <map>\n#include <memory>\n#include <string>\n\n");
            // {f} takes void f(Rid, const char*, void*), void f(Rid, const char*), or anything callable like it
            try e.puts("namespace ravenc_detail {\n" ++
                "inline void bind(const char* name, void (*f)(Rid, const char*, void*)) { Raction_bind(name, f, nullptr); }\n" ++
                "inline void bind(const char* name, void (*f)(Rid, const char*)) {\n" ++
                "\tRaction_bind(name, [](Rid s, const char* a, void* u) { reinterpret_cast<void (*)(Rid, const char*)>(u)(s, a); }, reinterpret_cast<void*>(f));\n" ++
                "}\n" ++
                "template <class F> inline void bind(const char* name, F f) {\n" ++
                "\t/* one copy per action, freed when the program ends (or when the action is bound again) */\n" ++
                "\tstatic std::map<std::string, std::unique_ptr<F>> kept;\n" ++
                "\tstd::unique_ptr<F>& slot = kept[name];\n" ++
                "\tslot.reset(new F(f));\n" ++
                "\tRaction_bind(name, [](Rid s, const char* a, void* u) { (*static_cast<F*>(u))(s, a); }, slot.get());\n" ++
                "}\n" ++
                "}\n\n");
        }
        if (rc.names.items.len > 0) {
            try e.puts("/* the widgets that have a Name, filled by the create function */\n");
            try e.puts("static struct {\n");
            for (rc.names.items) |name| try e.print("\tRid {s};\n", .{name});
            try e.puts("} ui;\n\n");
        }
        if (e.ps.root != null) try e.print("Rid {s}_create(void);\n\n", .{e.unit});

        for (e.ps.scripts.items) |script| {
            try lineDirective(e.gpa, e.out, script.line, e.source_path);
            try e.puts(script.code);
            try e.puts("\n");
            try lineDirective(e.gpa, e.out, e.out.lines + 2, out_path);
        }
        if (e.ps.root == null) return;

        try e.puts("\n/* ---- the interface ---- */\n\n");
        for (rc.table.items, 0..) |n, i| {
            if (n.attributes.items.len == 0) continue;
            try e.print("static const char* const ravenc_a{d}[] = {{ ", .{i});
            for (n.attributes.items, 0..) |a, k| {
                try e.out.cstring(e.gpa, a.name);
                try e.puts(", ");
                try e.out.cstring(e.gpa, a.value);
                try e.puts(if (k + 1 < n.attributes.items.len) ", " else " ");
            }
            try e.puts("};\n");
        }
        try e.print("\nstatic const RXmlCompiledNode ravenc_nodes[{d}] = {{\n", .{rc.table.items.len});
        for (rc.table.items, 0..) |n, i| {
            try e.puts("\t{ ");
            try e.out.cstring(e.gpa, n.tag);
            try e.puts(", ");
            try e.out.cstring(e.gpa, n.text);
            if (n.attributes.items.len > 0) {
                try e.print(", ravenc_a{d}, {d}", .{ i, n.attributes.items.len });
            } else {
                try e.puts(", 0, 0");
            }
            try e.print(", {d}, {d} }},\n", .{ parentIndex(n), n.line });
        }
        try e.puts("};\n\n");

        try e.print("Rid {s}_create(void) {{\n\tRid root;\n", .{e.unit});
        for (rc.bindings.items) |b| {
            // (a missing or mistyped function is reported on the line of its element)
            try lineDirective(e.gpa, e.out, b.line, e.source_path);
            try e.puts(if (lang == .cpp) "\travenc_detail::bind(" else "\tRaction_bind(");
            try e.out.cstring(e.gpa, b.action);
            if (lang == .cpp) try e.print(", {s});\n", .{b.function}) else try e.print(", {s}, NULL);\n", .{b.function});
        }
        if (rc.bindings.items.len > 0) try lineDirective(e.gpa, e.out, e.out.lines + 2, out_path);
        try e.print("\troot = {s}(ravenc_nodes, {d}, ", .{ e.create(), rc.table.items.len });
        try e.out.cstring(e.gpa, e.source_path);
        try e.puts(");\n");
        for (rc.names.items) |name| {
            try e.print("\tui.{s} = root != R_INVALID_ID ? Rwidget_find(root, ", .{name});
            try e.out.cstring(e.gpa, name);
            try e.puts(") : R_INVALID_ID;\n");
        }
        try e.puts("\treturn root;\n}\n");
    }

    // ---- Rust ----

    fn rust(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        try e.scriptsInPlace(e.ps.scripts.items, null);
        try e.print("\n// ---- generated by ravenc from {s}: edit it, not this file ----\n\n", .{e.source_path});
        try e.puts("/// The widgets that have a Name (filled by the create function).\n#[allow(dead_code)]\n#[derive(Clone, Copy, Debug)]\npub struct RavencUi {\n");
        for (rc.names.items) |name| try e.print("    pub {s}: ::raven::Rid,\n", .{name});
        try e.puts("}\n\nstatic RAVENC_UI: ::std::sync::Mutex<RavencUi> = ::std::sync::Mutex::new(RavencUi {");
        for (rc.names.items, 0..) |name, i| try e.print("{s} {s}: ::raven::R_INVALID_ID", .{ if (i > 0) "," else "", name });
        try e.puts(" });\n\n/// The widgets of the interface: `ui().status`.\n#[allow(dead_code)]\npub fn ui() -> RavencUi {\n    *RAVENC_UI.lock().unwrap()\n}\n\n");
        if (e.ps.root == null) return;
        try e.print("/// Builds the interface of {s} (no XML is read: the table below is it).\n#[allow(dead_code, unused_unsafe)]\npub fn {s}_create() -> ::raven::Rid {{\n", .{ baseName(e.source_path), e.unit });
        for (rc.bindings.items) |b| {
            try e.puts("    ::raven::action_bind(");
            try e.literal(b.action, .c);
            try e.print(", |sender, action| {s}(sender, action));\n", .{b.function});
        }
        for (rc.table.items, 0..) |n, i| {
            if (n.attributes.items.len == 0) continue;
            try e.print("    let a{d}: [*const ::std::os::raw::c_char; {d}] = [", .{ i, n.attributes.items.len * 2 });
            for (n.attributes.items, 0..) |a, k| {
                try e.out.rustPtr(e.gpa, a.name);
                try e.puts(", ");
                try e.out.rustPtr(e.gpa, a.value);
                if (k + 1 < n.attributes.items.len) try e.puts(", ");
            }
            try e.puts("];\n");
        }
        try e.print("    let nodes: [::raven::RXmlCompiledNode; {d}] = [\n", .{rc.table.items.len});
        for (rc.table.items, 0..) |n, i| {
            try e.puts("        ::raven::RXmlCompiledNode { tag: ");
            try e.out.rustPtr(e.gpa, n.tag);
            try e.puts(", text: ");
            try e.out.rustPtr(e.gpa, n.text);
            if (n.attributes.items.len > 0) {
                try e.print(", attributes: a{d}.as_ptr(), attribute_count: {d}", .{ i, n.attributes.items.len });
            } else {
                try e.puts(", attributes: ::std::ptr::null(), attribute_count: 0");
            }
            try e.print(", parent: {d}, line: {d} }},\n", .{ parentIndex(n), n.line });
        }
        try e.print("    ];\n    let root = unsafe {{ ::raven::{s}(nodes.as_ptr(), {d}, ", .{ e.create(), rc.table.items.len });
        try e.out.rustPtr(e.gpa, e.source_path);
        try e.puts(") };\n");
        if (rc.names.items.len > 0) {
            try e.puts("    if root != ::raven::R_INVALID_ID {\n        let mut ui = RAVENC_UI.lock().unwrap();\n");
            for (rc.names.items) |name| try e.print("        ui.{s} = ::raven::widget_find(root, \"{s}\");\n", .{ name, name });
            try e.puts("    }\n");
        }
        try e.puts("    root\n}\n");
    }

    // ---- Python ----

    fn python(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        // (the functions of the scripts are found when create runs: it can come first)
        try e.print("# -*- coding: utf-8 -*-\n# Generated by ravenc from {s}: edit it, not this file.\n", .{e.source_path});
        try e.puts("import ctypes as _ravenc_ctypes\nimport raven as _ravenc_raven\n\n\nclass _RavencUi:\n    \"\"\"The widgets that have a Name (filled by the create function).\"\"\"\n");
        for (rc.names.items) |name| try e.print("    {s} = _ravenc_raven.R_INVALID_ID\n", .{name});
        if (rc.names.items.len == 0) try e.puts("    pass\n");
        try e.puts("\n\nui = _RavencUi()\n\n\n");
        if (e.ps.root != null) {
            try e.print("def {s}_create():\n    \"\"\"Builds the interface of {s}.\"\"\"\n", .{ e.unit, baseName(e.source_path) });
            try e.puts("    R = _ravenc_raven\n    keep = []\n\n" ++
                "    def s(text):\n        data = text.encode(\"utf-8\")\n        keep.append(data)\n        return data\n\n" ++
                "    def a(*texts):\n        array = (_ravenc_ctypes.c_char_p * len(texts))(*[s(t) for t in texts])\n        keep.append(array)\n" ++
                "        return _ravenc_ctypes.cast(array, _ravenc_ctypes.POINTER(_ravenc_ctypes.c_char_p))\n\n");
            for (rc.bindings.items) |b| {
                try e.puts("    R.Raction_bind(");
                try e.literal(b.action, .python);
                try e.print(", lambda sender, action, user_data: {s}(sender, action))\n", .{b.function});
            }
            try e.print("    nodes = (R.RXmlCompiledNode * {d})()\n", .{rc.table.items.len});
            for (rc.table.items, 0..) |n, i| {
                try e.print("    nodes[{d}] = R.RXmlCompiledNode(s(", .{i});
                try e.literal(n.tag, .python);
                try e.puts("), s(");
                try e.literal(n.text, .python);
                try e.puts("), ");
                if (n.attributes.items.len > 0) {
                    try e.puts("a(");
                    for (n.attributes.items, 0..) |a, k| {
                        try e.literal(a.name, .python);
                        try e.puts(", ");
                        try e.literal(a.value, .python);
                        if (k + 1 < n.attributes.items.len) try e.puts(", ");
                    }
                    try e.puts(")");
                } else {
                    try e.puts("None");
                }
                try e.print(", {d}, {d}, {d})\n", .{ n.attributes.items.len, parentIndex(n), n.line });
            }
            try e.print("    root = R.{s}(nodes, {d}, ", .{ e.create(), rc.table.items.len });
            try e.literal(e.source_path, .python);
            try e.puts(")\n    if root != R.R_INVALID_ID:\n");
            for (rc.names.items) |name| try e.print("        ui.{s} = R.Rwidget_find(root, \"{s}\")\n", .{ name, name });
            try e.puts("        pass\n    return root\n\n\n");
        }
        try e.puts("# ---- the scripts ----\n");
        for (e.ps.scripts.items) |script| {
            try e.print("# {s}, line {d}\n", .{ baseName(e.source_path), script.line });
            try e.puts(script.code);
            try e.puts("\n");
        }
    }

    // ---- Go ----

    fn go(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        const import_line = "import ravenc_raven \"raven/raven\"";
        const scripts = e.ps.scripts.items;
        var has_package = false;
        // a script that names its package: the import goes on the same line, after it
        if (scripts.len > 0) {
            const code = scripts[0].code;
            var p: usize = 0;
            while (p < code.len and isSpace(code[p])) p += 1;
            has_package = std.mem.startsWith(u8, code[p..], "package ");
        }
        if (has_package) {
            const first = scripts[0];
            var p: usize = 0;
            while (p < first.code.len and isSpace(first.code[p])) p += 1;
            const end = std.mem.indexOfScalarPos(u8, first.code, p, '\n') orelse first.code.len;
            const code = try std.mem.concat(e.gpa, u8, &.{ first.code[0..end], "; ", import_line, first.code[end..] });
            const copy = try e.gpa.dupe(Script, scripts);
            copy[0].code = code;
            try e.scriptsInPlace(copy, null);
        } else {
            // (on the first line when the scripts leave it free: their lines stay those of the file)
            try e.scriptsInPlace(scripts, "package main; " ++ import_line);
        }
        try e.print("\n// ---- generated by ravenc from {s}: edit it, not this file ----\n\n", .{e.source_path});
        try e.puts("// ui holds the widgets that have a Name (filled by the create function).\nvar ui struct {\n");
        for (rc.names.items) |name| try e.print("\t{s} ravenc_raven.ID\n", .{name});
        try e.puts("}\n\n");
        if (e.ps.root == null) return;
        try e.print("// {s}_create builds the interface of {s}.\nfunc {s}_create() ravenc_raven.ID {{\n", .{ e.unit, baseName(e.source_path), e.unit });
        for (rc.bindings.items) |b| {
            try e.puts("\travenc_raven.ActionBind(");
            try e.literal(b.action, .go);
            try e.print(", {s})\n", .{b.function});
        }
        try e.puts("\tnodes := []ravenc_raven.CompiledNode{\n");
        for (rc.table.items) |n| {
            try e.puts("\t\t{Tag: ");
            try e.literal(n.tag, .go);
            try e.puts(", Text: ");
            try e.literal(n.text, .go);
            if (n.attributes.items.len > 0) {
                try e.puts(", Attributes: []string{");
                for (n.attributes.items, 0..) |a, k| {
                    try e.literal(a.name, .go);
                    try e.puts(", ");
                    try e.literal(a.value, .go);
                    if (k + 1 < n.attributes.items.len) try e.puts(", ");
                }
                try e.puts("}");
            }
            try e.print(", Parent: {d}, Line: {d}}},\n", .{ parentIndex(n), n.line });
        }
        try e.print("\t}}\n\troot := ravenc_raven.CreateCompiled(nodes, {s}, ", .{if (e.is_window) "true" else "false"});
        try e.literal(e.source_path, .go);
        try e.puts(")\n");
        if (rc.names.items.len > 0) {
            try e.puts("\tif root != ravenc_raven.R_INVALID_ID {\n");
            for (rc.names.items) |name| try e.print("\t\tui.{s} = ravenc_raven.WidgetFind(root, \"{s}\")\n", .{ name, name });
            try e.puts("\t}\n");
        }
        try e.puts("\treturn root\n}\n");
    }

    // ---- C# ----

    fn csharp(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        // pascal(cls, sizeof(cls) - 3, unit) with char cls[160]: at most 156 characters, then "Ui"
        var cls: std.ArrayList(u8) = .empty;
        var up = true;
        for (e.unit) |c| {
            if (cls.items.len + 1 >= 157) break;
            if (c == '_') {
                up = true;
                continue;
            }
            try cls.append(e.gpa, if (up) std.ascii.toUpper(c) else c);
            up = false;
        }
        try cls.appendSlice(e.gpa, "Ui");
        try e.scriptsInPlace(e.ps.scripts.items, null);
        try e.print("\n// ---- generated by ravenc from {s}: edit it, not this file ----\n\n", .{e.source_path});
        try e.print("/// <summary>The interface of {s}: Create() builds it; the widgets that have a Name are its fields.</summary>\n", .{baseName(e.source_path)});
        try e.print("public static partial class {s}\n{{\n", .{cls.items});
        for (rc.names.items) |name| try e.print("    public static uint {s} = 0xFFFFFFFF;\n", .{name});
        if (e.ps.root != null) {
            try e.puts("\n    public static uint Create()\n    {\n");
            for (rc.bindings.items) |b| {
                try e.puts("        global::Raven.R.Raction_bind(");
                try e.literal(b.action, .csharp);
                try e.print(", global::Raven.R.Keep<global::Raven.RActionCallback>((sender, action, user) => {s}(sender, " ++
                    "global::System.Runtime.InteropServices.Marshal.PtrToStringUTF8(action) ?? \"\")), global::System.IntPtr.Zero);\n", .{b.function});
            }
            try e.puts("        var memory = new global::System.Collections.Generic.List<global::System.IntPtr>();\n" ++
                "        global::System.IntPtr S(string text) { var p = global::System.Runtime.InteropServices.Marshal.StringToCoTaskMemUTF8(text); memory.Add(p); return p; }\n" ++
                "        global::System.IntPtr A(params string[] texts)\n        {\n" ++
                "            var p = global::System.Runtime.InteropServices.Marshal.AllocCoTaskMem(global::System.IntPtr.Size * texts.Length);\n" ++
                "            memory.Add(p);\n" ++
                "            for (int k = 0; k < texts.Length; k++) global::System.Runtime.InteropServices.Marshal.WriteIntPtr(p, k * global::System.IntPtr.Size, S(texts[k]));\n" ++
                "            return p;\n        }\n");
            try e.print("        var nodes = new global::Raven.RXmlCompiledNode[{d}];\n", .{rc.table.items.len});
            for (rc.table.items, 0..) |n, i| {
                try e.print("        nodes[{d}].tag = S(", .{i});
                try e.literal(n.tag, .csharp);
                try e.print("); nodes[{d}].text = S(", .{i});
                try e.literal(n.text, .csharp);
                try e.puts(");");
                if (n.attributes.items.len > 0) {
                    try e.print(" nodes[{d}].attributes = A(", .{i});
                    for (n.attributes.items, 0..) |a, k| {
                        try e.literal(a.name, .csharp);
                        try e.puts(", ");
                        try e.literal(a.value, .csharp);
                        if (k + 1 < n.attributes.items.len) try e.puts(", ");
                    }
                    try e.puts(");");
                }
                try e.print(" nodes[{d}].attribute_count = {d}; nodes[{d}].parent = {d}; nodes[{d}].line = {d};\n", .{ i, n.attributes.items.len, i, parentIndex(n), i, n.line });
            }
            try e.print("        uint root = global::Raven.R.{s}(ref nodes[0], {d}, ", .{ e.create(), rc.table.items.len });
            try e.literal(e.source_path, .csharp);
            try e.puts(");\n        foreach (var p in memory) global::System.Runtime.InteropServices.Marshal.FreeCoTaskMem(p);\n");
            if (rc.names.items.len > 0) {
                try e.puts("        if (root != 0xFFFFFFFF)\n        {\n");
                for (rc.names.items) |name| try e.print("            {s} = global::Raven.R.Rwidget_find(root, \"{s}\");\n", .{ name, name });
                try e.puts("        }\n");
            }
            try e.puts("        return root;\n    }\n");
        }
        try e.puts("}\n");
    }

    // ---- Zig ----

    fn zig(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        try e.scriptsInPlace(e.ps.scripts.items, null);
        try e.print("\n// ---- generated by ravenc from {s}: edit it, not this file ----\n\n", .{e.source_path});
        try e.puts("const ravenc_r = @import(\"raven\");\n\n/// The widgets that have a Name (filled by the create function).\npub const RavencUi = struct {\n");
        for (rc.names.items) |name| try e.print("    {s}: ravenc_r.Rid = ravenc_r.R_INVALID_ID,\n", .{name});
        try e.puts("};\npub var ui: RavencUi = .{};\n\n");
        if (e.ps.root == null) return;
        for (rc.table.items, 0..) |n, i| {
            if (n.attributes.items.len == 0) continue;
            try e.print("const ravenc_a{d} = [_]?[*:0]const u8{{ ", .{i});
            for (n.attributes.items, 0..) |a, k| {
                try e.literal(a.name, .zig);
                try e.puts(", ");
                try e.literal(a.value, .zig);
                if (k + 1 < n.attributes.items.len) try e.puts(", ");
            }
            try e.puts(" };\n");
        }
        try e.puts("const ravenc_nodes = [_]ravenc_r.RXmlCompiledNode{\n");
        for (rc.table.items, 0..) |n, i| {
            try e.puts("    .{ .tag = ");
            try e.literal(n.tag, .zig);
            try e.puts(", .text = ");
            try e.literal(n.text, .zig);
            if (n.attributes.items.len > 0) try e.print(", .attributes = &ravenc_a{d}, .attribute_count = {d}", .{ i, n.attributes.items.len });
            try e.print(", .parent = {d}, .line = {d} }},\n", .{ parentIndex(n), n.line });
        }
        try e.print("}};\n\n/// Builds the interface of {s}.\npub fn {s}_create() ravenc_r.Rid {{\n", .{ baseName(e.source_path), e.unit });
        for (rc.bindings.items) |b| {
            try e.puts("    ravenc_r.Raction_bind(");
            try e.literal(b.action, .zig);
            try e.print(", &{s}, null);\n", .{b.function});
        }
        try e.print("    const root = ravenc_r.{s}(&ravenc_nodes[0], ravenc_nodes.len, ", .{e.create()});
        try e.literal(e.source_path, .zig);
        try e.puts(");\n");
        if (rc.names.items.len > 0) {
            try e.puts("    if (root != ravenc_r.R_INVALID_ID) {\n");
            for (rc.names.items) |name| try e.print("        ui.{s} = ravenc_r.Rwidget_find(root, \"{s}\");\n", .{ name, name });
            try e.puts("    }\n");
        }
        try e.puts("    return root;\n}\n");
    }

    // ---- Lua (LuaJIT) ----

    fn lua(e: Emit) Allocator.Error!void {
        const rc = e.rc;
        try e.print("-- Generated by ravenc from {s}: edit it, not this file.\n", .{e.source_path});
        try e.puts("local ravenc_raven = require(\"raven\")\nlocal ravenc_ffi = ravenc_raven.ffi\nlocal ravenc_kept = {}\n\n");
        try e.puts("-- the widgets that have a Name (filled by the create function)\nui = {\n");
        for (rc.names.items) |name| try e.print("\t{s} = ravenc_raven.R_INVALID_ID,\n", .{name});
        try e.puts("}\n\n");
        if (e.ps.root != null) {
            // (the functions named in {} are looked for when create runs: global functions, or fields of a global table)
            try e.print("-- builds the interface of {s}\nfunction {s}_create()\n\tlocal R, ffi = ravenc_raven, ravenc_ffi\n", .{ baseName(e.source_path), e.unit });
            try e.puts("\tlocal keep = {}\n\tlocal function a(t)\n\t\tlocal array = ffi.new(\"const char*[?]\", #t, t)\n\t\tkeep[#keep + 1] = array\n\t\treturn array\n\tend\n");
            for (rc.bindings.items, 0..) |b, i| {
                try e.print("\tlocal callback{d} = ffi.cast(\"RActionCallback\", function(sender, action, user_data) {s}(sender, ffi.string(action)) end)\n", .{ i, b.function });
                try e.print("\travenc_kept[#ravenc_kept + 1] = callback{d}\n\tR.Raction_bind(", .{i});
                try e.literal(b.action, .lua);
                try e.print(", callback{d}, nil)\n", .{i});
            }
            try e.print("\tlocal nodes = ffi.new(\"RXmlCompiledNode[?]\", {d})\n", .{rc.table.items.len});
            for (rc.table.items, 0..) |n, i| {
                try e.print("\tnodes[{d}].tag = ", .{i});
                try e.literal(n.tag, .lua);
                try e.print("; nodes[{d}].text = ", .{i});
                try e.literal(n.text, .lua);
                if (n.attributes.items.len > 0) {
                    try e.print("; nodes[{d}].attributes = a({{ ", .{i});
                    for (n.attributes.items, 0..) |a, k| {
                        try e.literal(a.name, .lua);
                        try e.puts(", ");
                        try e.literal(a.value, .lua);
                        if (k + 1 < n.attributes.items.len) try e.puts(", ");
                    }
                    try e.puts(" })");
                }
                try e.print("; nodes[{d}].attribute_count = {d}; nodes[{d}].parent = {d}; nodes[{d}].line = {d}\n", .{ i, n.attributes.items.len, i, parentIndex(n), i, n.line });
            }
            try e.print("\tlocal root = R.{s}(nodes, {d}, ", .{ e.create(), rc.table.items.len });
            try e.literal(e.source_path, .lua);
            try e.puts(")\n\tif root ~= R.R_INVALID_ID then\n");
            for (rc.names.items) |name| try e.print("\t\tui.{s} = R.Rwidget_find(root, \"{s}\")\n", .{ name, name });
            try e.puts("\tend\n\treturn root\nend\n\n");
        }
        try e.puts("-- ---- the scripts ----\n");
        for (e.ps.scripts.items) |script| {
            try e.print("-- {s}, line {d}\n", .{ baseName(e.source_path), script.line });
            try e.puts(script.code);
            try e.puts("\n");
        }
    }
};

const usage_text =
    "ravenc: compiles an interface written in Raven XML with its code into one source file\n" ++
    "usage: ravenc <file> -o <output> [--lang LANGUAGE] [--name NAME]\n" ++
    "  the language comes from the extension of the file:\n" ++
    "    .xmlc (C)  .xmlc++ .xmlcpp (C++)  .xmlrs (Rust)  .xmlpy (Python)\n" ++
    "    .xmlgo (Go)  .xmlcs (C#)  .xmlzig (Zig)  .xmllua (LuaJIT)\n" ++
    "  --lang LANGUAGE   c, cpp, rust, python, go, csharp, zig or lua, whatever the extension\n" ++
    "  --name NAME       the function is NAME_create (default: the file name)\n";

/// The command line, as main() of the C program read it.
const Options = struct {
    input: []const u8,
    output: []const u8,
    name: ?[]const u8 = null,
    lang_name: ?[]const u8 = null,
};

/// null: print the usage (exit status 2).
fn parseArgs(args: []const []const u8) ?Options {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var lang_name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, arg, "--lang") and i + 1 < args.len) {
            i += 1;
            lang_name = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return null;
        } else if (arg.len > 0 and arg[0] == '-') {
            return null;
        } else if (input == null) {
            input = arg;
        } else return null;
    }
    return .{ .input = input orelse return null, .output = output orelse return null, .name = name, .lang_name = lang_name };
}

/// Compiles `source` (the content of the file `input`) to the text of `output`. error.Compile: see rc.diag.
fn compile(rc: *Ravenc, source: []const u8, opts: Options, lang: Lang, unit: []const u8) Error![]const u8 {
    const gpa = rc.gpa;
    var ps: Parser = .{ .src = source, .p = 0, .line = 1 };
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) ps.p += 3;
    try rc.parse(&ps);
    if (ps.root) |root| try rc.collect(root, unit);
    const is_window = if (ps.root) |root| iequal(root.tag, "Window") else false;

    const source_path = try forwardSlashes(gpa, opts.input);
    const out_path = try forwardSlashes(gpa, opts.output);
    var out: Buffer = .{};
    const e: Emit = .{ .gpa = gpa, .out = &out, .ps = &ps, .rc = rc, .unit = unit, .source_path = source_path, .is_window = is_window };
    switch (lang) {
        .c, .cpp => try e.cLike(lang, out_path),
        .rust => try e.rust(),
        .python => try e.python(),
        .go => try e.go(),
        .csharp => try e.csharp(),
        .zig => try e.zig(),
        .lua => try e.lua(),
    }
    return out.data.items;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var err_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    const stderr = &stderr_writer.interface;

    const sentinel_args = try init.minimal.args.toSlice(gpa);
    const args = try gpa.alloc([]const u8, sentinel_args.len);
    for (sentinel_args, args) |src, *dst| dst.* = src;

    const opts = parseArgs(args) orelse {
        try stderr.writeAll(usage_text);
        try stderr.flush();
        return 2;
    };
    var lang: Lang = .c;
    if (opts.lang_name) |lang_name| {
        lang = languageNamed(lang_name) orelse {
            try stderr.print("ravenc: unknown language {s}\n", .{lang_name});
            try stderr.flush();
            return 2;
        };
    } else {
        lang = languageOfFile(opts.input) orelse .c;
    }
    const source = std.Io.Dir.cwd().readFileAlloc(io, opts.input, gpa, .unlimited) catch {
        try stderr.print("ravenc: cannot read {s}\n", .{opts.input});
        try stderr.flush();
        return 1;
    };
    const unit = if (opts.name) |name| name else try unitName(gpa, opts.input);
    if (!isIdentifier(cstr(unit)) or cstr(unit).len != unit.len) {
        try stderr.writeAll("ravenc: --name must be an identifier\n");
        try stderr.flush();
        return 2;
    }

    var rc: Ravenc = .{ .gpa = gpa };
    const text = compile(&rc, source, opts, lang, unit) catch |err| switch (err) {
        error.Compile => {
            try stderr.print("{s}:{d}: error: {s}\n", .{ opts.input, rc.diag_line, rc.diag.items });
            try stderr.flush();
            return 1;
        },
        error.OutOfMemory => {
            try stderr.writeAll("ravenc: out of memory\n");
            try stderr.flush();
            return 1;
        },
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.output, .data = text }) catch {
        try stderr.print("ravenc: cannot write {s}\n", .{opts.output});
        try stderr.flush();
        return 1;
    };
    return 0;
}

// ---------------------------------------------------------------------------
//  Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn compileForTest(arena: Allocator, source: []const u8, input: []const u8, lang: Lang) Error![]const u8 {
    var rc: Ravenc = .{ .gpa = arena };
    const unit = try unitName(arena, input);
    return compile(&rc, source, .{ .input = input, .output = "out.c" }, lang, unit);
}

test "unitName: file name to identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("my_app", try unitName(arena.allocator(), "dir/my-app.xmlc"));
    try testing.expectEqualStrings("_2d", try unitName(arena.allocator(), "c:\\x\\2d.xmlc"));
    try testing.expectEqualStrings("x", try unitName(arena.allocator(), ".xmlc"));
    try testing.expectEqualStrings("x", try unitName(arena.allocator(), "dir/"));
}

test "languages: by name and by extension" {
    try testing.expectEqual(Lang.cpp, languageOfFile("a/b.xmlc++").?);
    try testing.expectEqual(Lang.csharp, languageNamed("C#").?);
    try testing.expectEqual(Lang.rust, languageNamed("rs").?);
    try testing.expect(languageOfFile("a.txt") == null);
    try testing.expect(languageOfFile("noext") == null);
}

test "strtoul: as the C library reads character references" {
    try testing.expectEqual(@as(?u64, 65), strtoul("65", 10));
    try testing.expectEqual(@as(?u64, 0x41), strtoul("41", 16));
    try testing.expectEqual(@as(?u64, 0x41), strtoul("0x41", 16));
    try testing.expectEqual(@as(?u64, 65), strtoul(" +65", 10));
    try testing.expectEqual(@as(?u64, 0), strtoul("", 10));
    try testing.expect(strtoul("6a", 10) == null);
    try testing.expect(strtoul("x", 16) == null);
    try testing.expect(strtoul("-1", 10).? > 0x10FFFF);
    try testing.expect(strtoul("99999999999999999999999", 10).? > 0x10FFFF);
}

test "Buffer.cstring: escapes and no trigraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b: Buffer = .{};
    try b.cstring(arena.allocator(), "a\"b\\c\nd??=\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd?\"\"?=\\001\"", b.data.items);
    try testing.expectEqual(@as(i32, 0), b.lines);
}

test "compile: C window with a binding and a name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\<script>
        \\static void on_ok(Rid s, const char* a, void* u) {}
        \\</script>
        \\<Window Title="Hi &amp; &#x41;">
        \\  <Button Name="ok" OnClicked="{ on_ok }">OK</Button>
        \\</Window>
    ;
    const text = try compileForTest(arena.allocator(), src, "dir/hello.xmlc", .c);
    try testing.expect(std.mem.indexOf(u8, text, "Rid hello_create(void);\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"Title\", \"Hi & A\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"OnClicked\", \"ravenc.hello.on_ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\tRaction_bind(\"ravenc.hello.on_ok\", on_ok, NULL);\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\troot = Rwindow_create_from_compiled(ravenc_nodes, 2, \"dir/hello.xmlc\");\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\tui.ok = root != R_INVALID_ID ? Rwidget_find(root, \"ok\") : R_INVALID_ID;\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "#line 1 \"dir/hello.xmlc\"\n") != null);
}

test "compile: errors carry their line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rc: Ravenc = .{ .gpa = arena.allocator() };
    const opts: Options = .{ .input = "a.xmlc", .output = "a.c" };
    try testing.expectError(error.Compile, compile(&rc, "<Window>\n<Label>x</Button>\n</Window>", opts, .c, "a"));
    try testing.expectEqual(@as(i32, 2), rc.diag_line);
    try testing.expectEqualStrings("</Button> closes <Label>", rc.diag.items);
    try testing.expectError(error.Compile, compile(&rc, "<A/>\n<B/>", opts, .c, "a"));
    try testing.expectEqual(@as(i32, 2), rc.diag_line);
    try testing.expectError(error.Compile, compile(&rc, "<A X=\"&bogus;\"/>", opts, .c, "a"));
    try testing.expectEqualStrings("unknown entity &bogus;", rc.diag.items);
}

test "compile: Go script with a package keeps its lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try compileForTest(arena.allocator(), "<script>package main\nfunc f() {}\n</script>\n<Label/>", "x.xmlgo", .go);
    try testing.expect(std.mem.startsWith(u8, text, "package main; import ravenc_raven \"raven/raven\"\nfunc f() {}\n"));
}

test "parseArgs: as the C main" {
    try testing.expect(parseArgs(&.{ "ravenc", "a.xmlc" }) == null);
    try testing.expect(parseArgs(&.{ "ravenc", "a.xmlc", "-o" }) == null);
    try testing.expect(parseArgs(&.{ "ravenc", "-x", "a", "-o", "b" }) == null);
    const o = parseArgs(&.{ "ravenc", "a.xmlc", "-o", "b.c", "--lang", "zig", "--name", "n" }).?;
    try testing.expectEqualStrings("a.xmlc", o.input);
    try testing.expectEqualStrings("b.c", o.output);
    try testing.expectEqualStrings("zig", o.lang_name.?);
    try testing.expectEqualStrings("n", o.name.?);
}
