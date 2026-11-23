#!/usr/bin/env python3
"""Generate zig/src/render/vulkan/vulkan_h.zig: the Vulkan declarations Raven uses, in Zig.

    python3 -I tools/gen_vulkan_types.py [vulkan include dir]

Raven's Vulkan code (src/render/vulkan/*, src/render/*) includes <vulkan/vulkan.h> with
VK_NO_PROTOTYPES: it needs the types, enums, constants and PFN_vk* function pointer types, never
a Vulkan library (the entry points are loaded at run time into the `rvn_vk` table, vk_loader.h).
The translations cannot use @cImport, so this script takes `zig translate-c` of vulkan_core.h,
keeps the declarations whose names occur in Raven's sources, plus everything they need
(structs, enums, handles, flags), and writes them to one file.

The Vulkan include directory: the argument, $RAVEN_VULKAN_INCLUDE_DIR, the CMake cache of a
zig/_build/*/CMakeCache.txt, /opt/homebrew/include, /usr/local/include or /usr/include.
(Vulkan-Headers are Apache-2.0 OR MIT.) Run it again when the headers change, then check.sh.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ZIGDIR = os.path.dirname(HERE)
RAVEN = os.path.dirname(ZIGDIR)
OUT = os.path.join(ZIGDIR, "src", "render", "vulkan", "vulkan_h.zig")

ITEM_START = re.compile(r"^(pub |const |var |export |extern |fn |inline )")
ITEM_NAME = re.compile(r"^(?:pub )?(?:const|var|extern fn|fn|inline fn|export fn)\s+(\w+)")
WORD = re.compile(r"\b[A-Za-z_]\w*\b")
USED = re.compile(r"\b(Vk[A-Za-z0-9_]+|VK_[A-Z0-9_]+|PFN_vk[A-Za-z0-9]+)\b")


def find_include():
    if len(sys.argv) > 1:
        return sys.argv[1]
    cands = [os.environ.get("RAVEN_VULKAN_INCLUDE_DIR", "")]
    for cache in glob.glob(os.path.join(ZIGDIR, "_build", "*", "CMakeCache.txt")) + glob.glob(os.path.join(ZIGDIR, "_build", "*", "lib", "CMakeCache.txt")):
        for line in open(cache, errors="replace"):
            if line.startswith("RAVEN_VULKAN_INCLUDE_DIR") or line.startswith("Vulkan_INCLUDE_DIR"):
                cands.append(line.split("=", 1)[1].strip())
    cands += ["/opt/homebrew/include", "/usr/local/include", "/usr/include"]
    for c in cands:
        if c and os.path.exists(os.path.join(c, "vulkan", "vulkan_core.h")):
            return c
    sys.exit("gen_vulkan_types.py: no vulkan/vulkan_core.h found: pass the include directory")


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


def main():
    inc = find_include()
    # names used by Raven (the C code and the Vulkan-facing headers)
    roots = set()
    for pattern in ("src/render/**/*.c", "src/render/**/*.h", "src/core/*.h", "src/widget/*.h", "include/raven/*.h", "src/platform/**/*.c", "src/platform/**/*.m"):
        for path in glob.glob(os.path.join(RAVEN, pattern), recursive=True):
            if "/generated/" in path:
                continue
            roots.update(USED.findall(open(path, errors="replace").read()))

    # the function table of vk_loader.h is made with X-macros: X(CreateImage) -> the type PFN_vkCreateImage
    loader = open(os.path.join(RAVEN, "src", "render", "vulkan", "vk_loader.h"), errors="replace").read()
    for name in re.findall(r"\bX\((\w+)\)", loader):
        roots.add("PFN_vk" + name)

    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "vulkan"))
        for name in ("vulkan_core.h", "vk_platform.h"):
            shutil.copy(os.path.join(inc, "vulkan", name), os.path.join(tmp, "vulkan", name))
        out = os.path.join(tmp, "out.zig")
        # relative paths, regular file for the output (zig translate-c hangs on a pipe)
        with open(out, "w") as f:
            subprocess.run(["zig", "translate-c", "-DVK_NO_PROTOTYPES", "-I", ".", "vulkan/vulkan_core.h"], check=True,
                           stdout=f, stdin=subprocess.DEVNULL, cwd=tmp)
        items = split_items(open(out).read())

    by_name = {}
    order = {}
    for i, it in enumerate(items):
        m = ITEM_NAME.match(it)
        if m and m.group(1) not in by_name and not m.group(1).startswith("__"):
            by_name[m.group(1)] = it
            order[m.group(1)] = i
    keep = set()
    todo = [n for n in roots if n in by_name]
    missing = sorted(n for n in roots if n not in by_name)
    while todo:
        n = todo.pop()
        if n in keep:
            continue
        item = by_name[n]
        if "@compileError" in item:
            continue
        keep.add(n)
        for w in WORD.findall(item):
            if w != n and w in by_name and w not in keep:
                todo.append(w)
    version = re.search(r"#define VK_HEADER_VERSION (\d+)", open(os.path.join(inc, "vulkan", "vulkan_core.h")).read()).group(1)
    names = sorted(keep, key=lambda n: order[n])
    body = "\n".join(by_name[n].rstrip() for n in names)
    helpers = "const __helpers = @import(\"std\").zig.c_translation.helpers;\n\n" if "__helpers" in body else ""
    text = (
        "// Translated to Zig from the Vulkan headers (vulkan_core.h %s; Apache-2.0 OR MIT) for vendor/raven/src/render/vulkan.\n"
        "// Modified by Seridian: C11 → Zig translation.\n"
        "//\n"
        "// GENERATED by zig/tools/gen_vulkan_types.py (zig translate-c, filtered to what Raven uses): do not edit by hand.\n"
        "// Types, enum constants, flags and PFN_vk* function pointer types, with VK_NO_PROTOTYPES: the entry points are\n"
        "// the function pointers of the rvn_vk table (vk_loader.h), never extern functions. Handles are ?*struct_Vk*_T.\n"
        "\n%s%s\n"
    ) % (version, helpers, body)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote %s: %d declarations (header version %s), %d used names not found in vulkan_core.h" % (os.path.relpath(OUT, RAVEN), len(names), version, len(missing)))
    if missing:
        print("not found (probably macros of Raven or platform extensions): " + " ".join(missing))


if __name__ == "__main__":
    main()
