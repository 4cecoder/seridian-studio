#!/usr/bin/env python3
"""Generate the Zig versions of Raven's generated data: embedded fonts and SPIR-V shaders.

    python3 -I tools/gen_data.py        (from anywhere)

  src/resources/default_font.c, mono_font.c        -> zig/src/resources/<name>.zig
        export const rvn_<font>_font_data: [N]u8, export const rvn_<font>_font_size: usize
        (the same two symbols as the C file: it is listed in ported.txt)
  src/render/vulkan/generated/<name>_spv.h        -> zig/src/render/vulkan/generated/<name>_spv.zig
        pub const rvn_<name>_spv: [N]u32 (data for the translations of vk_pipeline.c and shader.c;
        no symbols of its own: the C headers were `static const` arrays)

The C files are the source of truth (they are generated from the TTF files / GLSL shaders by
tools/embed.py and the CMake option RAVEN_REBUILD_SHADERS): run this again after regenerating them.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ZIGDIR = os.path.dirname(HERE)
RAVEN = os.path.dirname(ZIGDIR)
HEADER = "// Translated to Zig from vendor/raven/%s (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.\n"
NUMBER = re.compile(r"0[xX][0-9a-fA-F]+|\d+")


def numbers(text):
    return [int(t, 0) for t in NUMBER.findall(text)]


def emit_array(out, values, per_line):
    for i in range(0, len(values), per_line):
        out.write("    " + ", ".join(str(v) if v < 256 and per_line == 20 else ("0x%08x" % v) for v in values[i:i + per_line]) + ",\n")


def font(src):
    text = open(os.path.join(RAVEN, src), encoding="utf-8").read()
    comment = re.match(r"/\*\*(.*?)\*/", text, re.S).group(1)
    comment = "\n".join("//" + (" " + l.strip(" *") if l.strip(" *") else "") for l in comment.strip().split("\n"))
    m = re.search(r"const unsigned char (\w+)_data\[\]\s*=\s*\{(.*?)\};", text, re.S)
    sym = m.group(1)
    data = numbers(m.group(2))
    size = int(re.search(r"const size_t %s_size\s*=\s*(\d+);" % sym, text).group(1))
    if len(data) != size or any(v > 255 for v in data):
        sys.exit("%s: %d bytes found, %d declared" % (src, len(data), size))
    dst = os.path.join(ZIGDIR, "src", re.sub(r"\.c$", ".zig", src[len("src/"):]))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as out:
        out.write(HEADER % src + "//\n" + comment + "\n\n")
        out.write("export const %s_data: [%d]u8 = .{\n" % (sym, size))
        emit_array(out, data, 20)
        out.write("};\n\nexport const %s_size: usize = %d;\n" % (sym, size))
    print("wrote", os.path.relpath(dst, RAVEN), size, "bytes")


def shader(src):
    text = open(os.path.join(RAVEN, src), encoding="utf-8").read()
    comment = re.match(r"/\*\*(.*?)\*/", text, re.S).group(1)
    comment = "\n".join("//" + (" " + l.strip(" *") if l.strip(" *") else "") for l in comment.strip().split("\n"))
    m = re.search(r"static const uint32_t (\w+)\[(\d+)\]\s*=\s*\{(.*?)\};", text, re.S)
    sym, count, body = m.group(1), int(m.group(2)), m.group(3)
    words = numbers(body)
    if len(words) != count or any(v > 0xFFFFFFFF for v in words):
        sys.exit("%s: %d words found, %d declared" % (src, len(words), count))
    dst = os.path.join(ZIGDIR, "src", re.sub(r"\.h$", ".zig", src[len("src/"):]))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as out:
        out.write(HEADER % src + "//\n" + comment + "\n\n")
        out.write("pub const %s: [%d]u32 = .{\n" % (sym, count))
        emit_array(out, words, 8)
        out.write("};\n")
    print("wrote", os.path.relpath(dst, RAVEN), count, "words")


def main():
    for src in ("src/resources/default_font.c", "src/resources/mono_font.c"):
        font(src)
    for path in sorted(glob.glob(os.path.join(RAVEN, "src/render/vulkan/generated/*_spv.h"))):
        shader(os.path.relpath(path, RAVEN))


if __name__ == "__main__":
    main()
