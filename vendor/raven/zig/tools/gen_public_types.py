#!/usr/bin/env python3
"""Generate the Zig translation of Raven's public C headers and its layout test.

    python3 -I tools/gen_public_types.py          (from vendor/raven/zig, or anywhere)

Reads  include/Raven.h (and every header it includes),
writes src/raven/raven.zig    the public API as Zig: extern structs / enums / constants /
                              callback types / extern function declarations, exact C layout
        layout/layout.c       prints sizeof / alignof / offsetof / enum and macro values (C)
        layout/layout.zig     prints the same lines from the Zig types

Method: `zig translate-c` (exact layout, written by the compiler) filtered down to the declarations
of the public headers (found with clang's JSON AST), cleaned, plus the macros, which translate-c
cannot express, from MACROS below. Needs: zig, and a C compiler (cc / clang) for the AST.
Run it again when include/raven/*.h change, then run check.sh (it runs the layout test).
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ZIGDIR = os.path.dirname(HERE)
RAVEN = os.path.dirname(ZIGDIR)
INCLUDE = os.path.join(RAVEN, "include")

# Macros of the public headers (translate-c cannot express most of them). (name, zig line, c expression or None)
MACROS = [
    ("RAVEN_VERSION_MAJOR", "pub const RAVEN_VERSION_MAJOR: c_int = 0;", "RAVEN_VERSION_MAJOR"),
    ("RAVEN_VERSION_MINOR", "pub const RAVEN_VERSION_MINOR: c_int = 1;", "RAVEN_VERSION_MINOR"),
    ("RAVEN_VERSION_PATCH", "pub const RAVEN_VERSION_PATCH: c_int = 0;", "RAVEN_VERSION_PATCH"),
    ("RAVEN_API_VERSION", 'pub const RAVEN_API_VERSION = "0.1";', None),
    ("R_FALSE", "pub const R_FALSE: c_int = 0;", "R_FALSE"),
    ("R_TRUE", "pub const R_TRUE: c_int = 1;", "R_TRUE"),
    ("R_INVALID_ID", "pub const R_INVALID_ID: Rid = 0xFFFFFFFF; // ((Rid)-1)", "R_INVALID_ID"),
    ("R_COLOR_COUNT", "pub const R_COLOR_COUNT: c_int = @as(c_int, R_COLOR_LAST_) - @as(c_int, R_COLOR_WINDOW);", "R_COLOR_COUNT"),
    ("R_METRIC_COUNT", "pub const R_METRIC_COUNT: c_int = @as(c_int, R_METRIC_LAST_) - @as(c_int, R_METRIC_FONT_SIZE);", "R_METRIC_COUNT"),
    ("R_PRIM_RECT", "pub const R_PRIM_RECT: c_uint = 0;", "R_PRIM_RECT"),
    ("R_PRIM_GLYPH", "pub const R_PRIM_GLYPH: c_uint = 1;", "R_PRIM_GLYPH"),
    ("R_PRIM_SHADOW", "pub const R_PRIM_SHADOW: c_uint = 2;", "R_PRIM_SHADOW"),
    ("R_PRIM_LINE", "pub const R_PRIM_LINE: c_uint = 3;", "R_PRIM_LINE"),
    ("R_PRIM_TRIANGLE", "pub const R_PRIM_TRIANGLE: c_uint = 4;", "R_PRIM_TRIANGLE"),
    ("R_PRIM_GLASS", "pub const R_PRIM_GLASS: c_uint = 5;", "R_PRIM_GLASS"),
    ("R_PRIM_BLUR", "pub const R_PRIM_BLUR: c_uint = 6;", "R_PRIM_BLUR"),
    ("R_PRIM_CURVE", "pub const R_PRIM_CURVE: c_uint = 7;", "R_PRIM_CURVE"),
    ("R_PRIM_SHADER", "pub const R_PRIM_SHADER: c_uint = 8;", "R_PRIM_SHADER"),
    ("R_PRIM_MASK", "pub const R_PRIM_MASK: c_uint = 0xF;", "R_PRIM_MASK"),
    ("R_INSTANCE_TEXTURED", "pub const R_INSTANCE_TEXTURED: c_uint = 1 << 4;", "R_INSTANCE_TEXTURED"),
    ("R_INSTANCE_NO_POINTER", "pub const R_INSTANCE_NO_POINTER: c_uint = 1 << 5;", "R_INSTANCE_NO_POINTER"),
    ("R_ID_INDEX", "/// #define R_ID_INDEX(id) ((Ruint)(id) & 0xFFFFFu)\npub inline fn R_ID_INDEX(id: Rid) Ruint {\n    return @as(Ruint, id) & 0xFFFFF;\n}", "R_ID_INDEX(0x12345678u)"),
]
# Rerror_check() prints the last error with printf: not translated, a translation uses Rerror_get_last directly.


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def find_cc():
    for cc in ("cc", "clang", "gcc"):
        try:
            subprocess.run([cc, "--version"], check=True, capture_output=True)
            return [cc]
        except (OSError, subprocess.CalledProcessError):
            pass
    return ["zig", "cc"]


def public_names():
    """Names declared by the public headers, from clang's JSON AST."""
    ast = json.loads(run(find_cc() + ["-fsyntax-only", "-Xclang", "-ast-dump=json", "-I", INCLUDE, "-x", "c",
                                       os.path.join(INCLUDE, "Raven.h")]))
    current = None
    funcs, types, consts, records, enums, vars_ = [], [], [], [], [], []
    inc = os.path.realpath(INCLUDE)

    def where(loc):
        for key in ("spellingLoc", "expansionLoc"):
            if key in loc and "file" in loc[key]:
                return loc[key]["file"]
        return loc.get("file")

    for node in ast["inner"]:
        f = where(node.get("loc", {}))
        if f:
            current = f
        if not current or not os.path.realpath(current).startswith(inc):
            continue
        kind = node["kind"]
        if kind == "FunctionDecl":
            funcs.append(node["name"])
        elif kind == "TypedefDecl":
            types.append(node["name"])
        elif kind == "VarDecl":
            vars_.append(node["name"])
        elif kind == "RecordDecl" and node.get("completeDefinition"):
            fields = []
            for child in node.get("inner", []):
                if child["kind"] == "FieldDecl" and "name" in child and not child.get("isBitfield"):
                    fields.append(child["name"])
            records.append((node["name"], node.get("tagUsed", "struct"), fields))
        elif kind == "EnumDecl":
            names = [c["name"] for c in node.get("inner", []) if c["kind"] == "EnumConstantDecl"]
            consts.extend(names)
            if "name" in node:
                enums.append((node["name"], names))
    return funcs, types, consts, records, enums, vars_


ITEM_START = re.compile(r"^(pub |const |var |export |extern |fn |inline )")
ITEM_NAME = re.compile(r"^(?:pub )?(?:const|var|extern fn|fn|inline fn|export fn)\s+(\w+)")


def split_items(text):
    items, cur = [], []
    for line in text.split("\n"):
        if ITEM_START.match(line) and cur:
            items.append("\n".join(cur))
            cur = []
        cur.append(line)
    if cur:
        items.append("\n".join(cur))
    return items


def translate():
    # zig translate-c is run with its stdout in a regular file
    import tempfile
    with tempfile.TemporaryFile(mode="w+") as tmp:
        # relative paths, run from vendor/raven (translate-c hangs on some absolute -I paths)
        subprocess.run(["zig", "translate-c", "-I", "include", "include/Raven.h"], check=True,
                       stdout=tmp, stdin=subprocess.DEVNULL, cwd=RAVEN)
        tmp.seek(0)
        return split_items(tmp.read())


def main():
    funcs, types, consts, records, enums, vars_ = public_names()
    items = translate()
    keep = set(funcs) | set(types) | set(consts) | set(vars_)
    keep |= {"struct_" + r[0] for r in records if r[1] == "struct"} | {"union_" + r[0] for r in records if r[1] == "union"}
    keep |= {"enum_" + e[0] for e in enums}
    # opaque forward declarations (struct RPainter;) are declared without a definition
    start = next(i for i, it in enumerate(items) if (ITEM_NAME.match(it) or [0, 0]) and ITEM_NAME.match(it) and ITEM_NAME.match(it).group(1) == types[0])
    last = max(i for i, it in enumerate(items) if ITEM_NAME.match(it) and ITEM_NAME.match(it).group(1) in keep)
    body, seen = [], set()
    for it in items[start:last + 1]:
        m = ITEM_NAME.match(it)
        name = m.group(1) if m else None
        if name is None:
            continue  # stray comment
        # methods translate-c adds inside structs (pub const Rinit_ex = __root.Rinit_ex;)
        it = "\n".join(l for l in it.split("\n") if "__root." not in l)
        if "__helpers" in it or "@compileError" in it:
            print("warning: skipped item %s (not expressible)" % name, file=sys.stderr)
            continue
        if name in seen:
            continue
        seen.add(name)
        body.append(it.rstrip())
    missing = [n for n in keep if n not in seen and not n.startswith(("struct_", "union_", "enum_"))]
    if missing:
        print("warning: not found in the translate-c output: %s" % sorted(missing), file=sys.stderr)

    macro_names = {m[0] for m in MACROS}
    doc = (
        "// Translated to Zig from vendor/raven/include (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.\n"
        "//\n"
        "// GENERATED by zig/tools/gen_public_types.py (zig translate-c, filtered): do not edit by hand.\n"
        "// The public API of Raven with the exact C layout: extern structs, enum constants, callback types and\n"
        "// extern function declarations. Pointers are C pointers ([*c]T): nullable, indexable, and they coerce to and\n"
        "// from ?*T / [*]T / ?[*]T. zig/layout/ checks the layout against a C compiler.\n"
        "//\n"
        "// Usage in a translated file:   const raven = @import(\"raven\");\n"
        "\n"
    )
    text = doc + "\n".join(body) + "\n\n// Macros of the headers (include/raven/*.h)\n"
    text += "\n".join(m[1] for m in MACROS) + "\n"
    with open(os.path.join(ZIGDIR, "src", "raven", "raven.zig"), "w") as f:
        f.write(text)

    # ----- layout test -----
    def zname(tag, kind):
        # translate-c: typedef name when it exists (RFoo = struct_RFoo); always available as RFoo here
        return tag

    c_lines = ["/* GENERATED by zig/tools/gen_public_types.py: prints the layout of Raven's public types. */",
               "#include <stdio.h>", "#include <stddef.h>", '#include "Raven.h"', "", "int main(void) {"]
    z_lines = ["// GENERATED by zig/tools/gen_public_types.py: prints the layout of the Zig types of raven.zig.",
               'const raven = @import("raven");', 'const std = @import("std");', "",
               "pub fn main() !void {",
               "    var buf: [1024]u8 = undefined;",
               "    var out = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buf);",
               "    const w = &out.interface;"]
    for tag, kind, fields in records:
        ctype = "%s %s" % (kind, tag)
        c_lines.append('\tprintf("sizeof %s %%zu\\n", sizeof(%s));' % (tag, ctype))
        c_lines.append('\tprintf("alignof %s %%zu\\n", _Alignof(%s));' % (tag, ctype))
        z_lines.append('    try w.print("sizeof %s {d}\\n", .{@sizeOf(raven.%s)});' % (tag, tag))
        z_lines.append('    try w.print("alignof %s {d}\\n", .{@alignOf(raven.%s)});' % (tag, tag))
        for fld in fields:
            c_lines.append('\tprintf("offsetof %s.%s %%zu\\n", offsetof(%s, %s));' % (tag, fld, ctype, fld))
            z_lines.append('    try w.print("offsetof %s.%s {d}\\n", .{@offsetOf(raven.%s, "%s")});' % (tag, fld, tag, fld))
    for tag, _ in enums:
        c_lines.append('\tprintf("sizeof enum %s %%zu\\n", sizeof(enum %s));' % (tag, tag))
        z_lines.append('    try w.print("sizeof enum %s {d}\\n", .{@sizeOf(raven.enum_%s)});' % (tag, tag))
    for tag, names in enums:
        for n in names:
            c_lines.append('\tprintf("const %s %%lld\\n", (long long)%s);' % (n, n))
            z_lines.append('    try w.print("const %s {d}\\n", .{@as(i64, raven.%s)});' % (n, n))
    for name, _, cexpr in MACROS:
        if cexpr is None:
            continue
        c_lines.append('\tprintf("macro %s %%lld\\n", (long long)(%s));' % (name, cexpr))
        if name == "R_ID_INDEX":
            z_lines.append('    try w.print("macro %s {d}\\n", .{@as(i64, raven.R_ID_INDEX(0x12345678))});' % name)
        else:
            z_lines.append('    try w.print("macro %s {d}\\n", .{@as(i64, raven.%s)});' % (name, name))
    c_lines += ["\treturn 0;", "}", ""]
    z_lines += ["    try w.flush();", "}", ""]
    os.makedirs(os.path.join(ZIGDIR, "layout"), exist_ok=True)
    with open(os.path.join(ZIGDIR, "layout", "layout.c"), "w") as f:
        f.write("\n".join(c_lines))
    with open(os.path.join(ZIGDIR, "layout", "layout.zig"), "w") as f:
        f.write("\n".join(z_lines))
    print("wrote src/raven/raven.zig (%d items), layout/layout.c, layout/layout.zig (%d records, %d enums)" % (len(body), len(records), len(enums)))


if __name__ == "__main__":
    main()
