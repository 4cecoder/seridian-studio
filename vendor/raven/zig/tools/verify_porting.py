#!/usr/bin/env python3
"""Compile every ```zig snippet of PORTING.md on this toolchain.

    python3 -I tools/verify_porting.py [PORTING.md]

The first line of a snippet says how it is checked:
    // check: run                      zig test (the snippet has test blocks; they run)
    // check: run-objc                 same, linking libobjc and Foundation (macOS only)
    // check: analyse [target]         every pub declaration is semantically analysed (no linking, no running);
                                       for another target, e.g. x86_64-linux-gnu or x86_64-windows-gnu
    // check: error <text>             must NOT compile, and the compiler's message must contain <text>
A snippet without such a line is an error. Snippets live in zig/src/core/ while they are compiled, so their
relative imports (base_h.zig, ../sys/libc.zig) and the modules `raven` and `raven_config` work as in a translation.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ZIGDIR = os.path.dirname(HERE)
SRC = os.path.join(ZIGDIR, "src")
DOC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ZIGDIR, "PORTING.md")

CONFIG = """pub const platform_win32 = false;
pub const platform_x11 = false;
pub const platform_cocoa = true;
pub const platform_null = false;
pub const backend_vulkan = true;
pub const with_stb_image = true;
pub const build_web = false;
pub const paid = false;
"""


def blocks(text):
    for m in re.finditer(r"^```zig[^\n]*\n(.*?)^```", text, re.S | re.M):
        line = text.count("\n", 0, m.start()) + 2
        yield line, m.group(1)


def main():
    text = open(DOC).read()
    failures = 0
    count = 0
    with tempfile.TemporaryDirectory() as tmp:
        cfg = os.path.join(tmp, "raven_config.zig")
        open(cfg, "w").write(CONFIG)
        for line, code in blocks(text):
            count += 1
            first = code.split("\n", 1)[0]
            m = re.match(r"//\s*check:\s*(\S+)\s*(.*)$", first)
            if not m:
                print("FAIL line %d: snippet without a '// check:' first line" % line)
                failures += 1
                continue
            mode, arg = m.group(1), m.group(2).strip()
            snippet = os.path.join(SRC, "core", ".doc_%d_%d.zig" % (os.getpid(), count))
            wrapper = os.path.join(SRC, ".doc_wrap_%d_%d.zig" % (os.getpid(), count))
            rel = os.path.relpath(snippet, SRC)
            open(snippet, "w").write("\n" + code.split("\n", 1)[1])  # the directive line is the verifier's, not the snippet's
            try:
                mods = ["--dep", "raven_config", "--dep", "raven", "-Mroot=" + wrapper, "-Mraven_config=" + cfg,
                        "-Mraven=" + os.path.join(SRC, "raven", "raven.zig")]
                if mode in ("run", "run-objc"):
                    open(wrapper, "w").write('test {\n    _ = @import("%s");\n}\n' % rel)
                    cmd = ["zig", "test", "-lc", "--cache-dir", os.path.join(ZIGDIR, "_build", "doc-cache")]
                    if mode == "run-objc":
                        cmd += ["-lobjc", "-framework", "Foundation"]
                    cmd += mods
                else:
                    open(wrapper, "w").write(
                        'pub const panic = @import("unit_check.zig").panic;\ncomptime {\n    _ = &@import("unit_check.zig").RefAll(@import("%s")).run;\n}\n' % rel)
                    cmd = ["zig", "build-obj", "-fno-emit-bin", "-lc", "--cache-dir", os.path.join(ZIGDIR, "_build", "doc-cache")]
                    if mode == "analyse" and arg:
                        cmd += ["-target", arg]
                    cmd += mods
                t0 = time.time()
                r = subprocess.run(cmd, cwd=ZIGDIR, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
                out = (r.stdout + r.stderr).replace(SRC + "/", "")
                if mode == "error":
                    if r.returncode == 0:
                        print("FAIL line %d: expected an error containing %r but it compiled" % (line, arg))
                        failures += 1
                    elif arg not in out:
                        print("FAIL line %d: error message does not contain %r:\n%s" % (line, arg, out[:600]))
                        failures += 1
                    else:
                        print("ok   line %d (error: %s)" % (line, arg))
                elif r.returncode != 0:
                    print("FAIL line %d (%s %s):\n%s" % (line, mode, arg, out[:1500]))
                    failures += 1
                else:
                    print("ok   line %d (%s%s) %.1fs" % (line, mode, " " + arg if arg else "", time.time() - t0))
            finally:
                for f in (snippet, wrapper):
                    if os.path.exists(f):
                        os.remove(f)
    print("%d snippet(s), %d failure(s)" % (count, failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
