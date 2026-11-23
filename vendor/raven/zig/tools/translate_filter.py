#!/usr/bin/env python3
"""Keep, from a `zig translate-c` output, the declarations that belong to the C file itself.

    translate_filter.py <raw.zig> <source.c|.m>   > body.zig

translate-c emits every declaration of every header the file includes. The body keeps the items whose
names the file itself defines: functions and variables (static ones too), typedef / struct / union /
enum names and enumerators, and #define names. Heuristic (a text scan of the C file), good enough to
read the file's own code; the raw output is the place to look up the headers' declarations.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c_exports  # noqa: E402

ITEM_START = re.compile(r"^(pub |const |var |export |extern |fn |inline |comptime )")
ITEM_NAME = re.compile(r"^(?:pub )?(?:export |extern |inline )*(?:const|var|fn)\s+(\w+)")


def own_names(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    names = {n.lstrip("?") for n in c_exports.exports(path, include_static=True)}
    for m in re.finditer(r"^\s*#\s*define\s+(\w+)", text, re.M):
        names.add(m.group(1))
    clean = c_exports.clean(text)
    for m in re.finditer(r"\b(struct|union|enum)\s+(\w+)", clean):
        names.update([m.group(2), "%s_%s" % (m.group(1), m.group(2))])
    for m in re.finditer(r"\btypedef\b[^;{]*?(\w+)\s*;", clean):
        names.add(m.group(1))
    for m in re.finditer(r"\}\s*(\w+)\s*;", clean):  # typedef struct {...} name;
        names.add(m.group(1))
    # enumerators: the identifiers inside enum { ... }
    for m in re.finditer(r"\benum\b[^{;]*\{([^}]*)\}", clean):
        for e in re.finditer(r"(\w+)\s*(?:=[^,]*)?(?:,|$)", m.group(1).strip()):
            names.add(e.group(1))
    return names


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    raw, source = sys.argv[1:]
    names = own_names(source)
    items, cur = [], []
    for line in open(raw).read().split("\n"):
        if ITEM_START.match(line) and cur:
            items.append("\n".join(cur))
            cur = []
        cur.append(line)
    items.append("\n".join(cur))
    out = []
    for it in items:
        m = ITEM_NAME.match(it)
        if m and m.group(1) in names:
            out.append(it.rstrip())
    print("// translate-c baseline of %s: the declarations the file itself defines (see PORTING.md, Baseline)." % source[source.rfind("/src/") + 1:])
    print("// NOT a translation: it keeps C's int promotions, [*c] pointers and __helpers casts. Rewrite it by the rules.")
    print("const __helpers = @import(\"std\").zig.c_translation.helpers;")
    print()
    print("\n".join(out))


if __name__ == "__main__":
    main()
