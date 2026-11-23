#!/usr/bin/env python3
"""List the global (non-static) functions and variables a Raven C / Objective-C source defines.

    c_exports.py <source.c|.m>

Prints one symbol per line. A symbol defined inside an #if / #ifdef block (other than the
include guard) is prefixed with '?': it depends on the configuration, so it may be absent
from a given build. This is a lightweight scanner for Raven's code style, not a C parser;
tools/test_c_exports.sh checks it against the symbols of the compiled library.
"""
import re
import sys

STATIC_MACROS = {"RVN_INLINE", "static", "extern", "typedef"}
NOT_DEFINITIONS = {"extern", "typedef"}


def clean(text):
    """Remove comments, strings, char literals and preprocessor lines; track #if nesting per line."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(" " + "\n" * text.count("\n", i, j))
            i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append('""' if c == '"' else "0")
            i = j + 1
        else:
            out.append(c)
            i += 1
    text = "".join(out)
    # preprocessor lines (with continuations): keep a marker so #if depth is known
    lines = text.split("\n")
    result = []
    depth = 0
    guard_seen = False
    k = 0
    while k < len(lines):
        line = lines[k]
        stripped = line.strip()
        if stripped.startswith("#"):
            full = stripped
            while full.endswith("\\") and k + 1 < len(lines):
                k += 1
                full = full[:-1] + " " + lines[k].strip()
            directive = re.match(r"#\s*(\w+)", full)
            d = directive.group(1) if directive else ""
            if d in ("if", "ifdef", "ifndef"):
                depth += 1
            elif d == "endif":
                depth -= 1
            result.append(("\x00PP%d\x00" % depth))
        else:
            result.append(line)
        k += 1
    return "\n".join(result)


def split_items(text):
    """Split the top level into items: (header_text_without_bodies, has_function_body, conditional)."""
    items = []
    cur = []
    brace = paren = 0
    pp_depth = 0
    item_cond = False
    i, n = 0, len(text)
    body_after_paren = False
    while i < n:
        c = text[i]
        if c == "\x00":
            j = text.index("\x00", i + 1)
            pp_depth = int(text[i + 3:j])
            i = j + 1
            continue
        if brace == 0:
            if c == "(":
                paren += 1
            elif c == ")":
                paren -= 1
            if c == "{" and paren == 0:
                head = "".join(cur).strip()
                # function body: the header ends with ')' (maybe an attribute after); else a type / initializer body
                if re.search(r"\)\s*(__attribute__\s*\(\(.*?\)\)\s*)?$", head) and "=" not in head.split("(")[0]:
                    # skip the body
                    depth = 1
                    i += 1
                    while i < n and depth:
                        if text[i] == "{":
                            depth += 1
                        elif text[i] == "}":
                            depth -= 1
                        i += 1
                    items.append((head, True, item_cond or pp_depth > 1))
                    cur = []
                    item_cond = False
                    continue
                # a struct / enum / union body or an initializer: skip to the matching brace, keep going
                depth = 1
                i += 1
                while i < n and depth:
                    if text[i] == "{":
                        depth += 1
                    elif text[i] == "}":
                        depth -= 1
                    i += 1
                cur.append(" {} ")
                continue
            if c == ";" and paren == 0:
                head = "".join(cur).strip()
                if head:
                    items.append((head, False, item_cond or pp_depth > 1))
                cur = []
                item_cond = False
                i += 1
                continue
        if not "".join(cur).strip() and not c.isspace():
            item_cond = pp_depth > 1
        cur.append(c)
        i += 1
    return items


def declarator_names(head):
    """Variable names declared by 'type a = 1, b[3], *c'."""
    head = re.sub(r"\{\}", "", head)
    parts, depth, cur = [], 0, ""
    for ch in head:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    names = []
    for k, part in enumerate(parts):
        part = part.split("=")[0] if "=" in part else part
        m = re.search(r"\(\s*\*\s*(\w+)\s*\)\s*\(", part)  # function pointer variable
        if m:
            names.append(m.group(1))
            continue
        part = re.sub(r"\[[^\]]*\]", "", part).strip()
        m = re.search(r"(\w+)\s*$", part)
        if m:
            names.append(m.group(1))
    # 'struct tag {} name' with no declarator leaves the tag only: caller filters by type keywords
    return names


def exports(path, include_static=False):
    """Names of the global functions / variables defined by the file; with include_static also the static ones."""
    skip = NOT_DEFINITIONS if include_static else STATIC_MACROS
    text = open(path, encoding="utf-8", errors="replace").read()
    if path.endswith(".m"):
        text = re.sub(r"@(interface|implementation|protocol)\b.*?@end", " ", text, flags=re.S)
    text = clean(text)
    found = []
    for head, is_func, cond in split_items(text):
        words = set(re.findall(r"[A-Za-z_]\w*", head))
        if words & skip:
            continue
        if is_func:
            m = re.search(r"(\w+)\s*\(", head)
            if m:
                found.append((m.group(1), cond))
            continue
        if "(" in head and not re.search(r"\(\s*\*\s*\w+\s*\)\s*\(", head):
            continue  # a prototype
        names = declarator_names(head)
        tokens = re.findall(r"[A-Za-z_]\w*", re.sub(r"\{\}", "", head))
        if len(tokens) < 2:
            continue
        # 'struct tag;' / 'struct tag {...};' declare no object
        if re.match(r"^(struct|union|enum)\s+\w+\s*(\{\})?\s*$", head) or re.match(r"^(struct|union|enum)\s*\{\}\s*$", head):
            continue
        for name in names:
            found.append((name, cond))
    seen = set()
    result = []
    for name, cond in found:
        if name not in seen:
            seen.add(name)
            result.append(("?" if cond else "") + name)
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    for sym in exports(sys.argv[1]):
        print(sym)
