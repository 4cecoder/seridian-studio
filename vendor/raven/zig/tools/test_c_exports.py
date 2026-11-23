#!/usr/bin/env python3
"""Check tools/c_exports.py against the symbols of the compiled C library (baseline/exports.<OS>.txt)."""
import os
import platform
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import c_exports

raven = os.path.dirname(os.path.dirname(here))
base = os.path.join(raven, "zig", "baseline", "exports.%s.txt" % platform.system())
bad = 0
total = 0
for line in open(base):
    src, _, syms = line.partition(": ")
    want = set(syms.split())
    got = c_exports.exports(os.path.join(raven, src))
    uncond = {g for g in got if not g.startswith("?")}
    cond = {g[1:] for g in got if g.startswith("?")}
    total += 1
    missing = want - uncond - cond          # in the object, not found by the scanner
    extra = uncond - want                   # unconditional per the scanner, absent from the object
    if missing or extra:
        bad += 1
        print("%s: scanner missing %s, extra %s" % (src, sorted(missing), sorted(extra)))
print("%d of %d sources differ" % (bad, total))
sys.exit(1 if bad else 0)
