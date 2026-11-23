#!/usr/bin/env python3
"""Summarize a ctest log against the recorded baseline of the pure C build.

    ctest_summary.py record <ctest.log> <baseline file>      write the baseline (name status)
    ctest_summary.py compare <ctest.log> <baseline file>     table + verdict, exit 1 on any regression

Statuses: PASS, FAIL, SKIP (ctest "Skipped", e.g. test_render without a Vulkan driver), NOTRUN.
A regression is a test that passed (or was skipped) in the baseline and does not pass now.
"""
import re
import sys

LINE = re.compile(r"Test\s+#\d+:\s+(\S+)\s+\.+\s*(?:\*+)?\s*(Passed|Failed|Skipped|Not Run|Exception[^\d]*|Timeout|SEGFAULT|Subprocess aborted)")


def parse(path):
    result = {}
    for line in open(path, errors="replace"):
        m = LINE.search(line)
        if m:
            word = m.group(2)
            status = {"Passed": "PASS", "Skipped": "SKIP", "Not Run": "NOTRUN"}.get(word, "FAIL")
            result[m.group(1)] = status
    return result


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("record", "compare"):
        sys.exit(__doc__)
    mode, log, base = sys.argv[1:]
    now = parse(log)
    if mode == "record":
        with open(base, "w") as f:
            for name in sorted(now):
                f.write("%s %s\n" % (name, now[name]))
        print("recorded %d tests in %s" % (len(now), base))
        return
    try:
        before = dict(line.split() for line in open(base) if line.strip())
    except OSError:
        before = {}
        print("no baseline file %s: nothing to compare with" % base)
    bad = 0
    width = max([len(n) for n in list(now) + list(before)] + [4])
    print("%-*s  %-8s %-8s" % (width, "test", "baseline", "now"))
    for name in sorted(set(now) | set(before)):
        b, n = before.get(name, "-"), now.get(name, "MISSING")
        mark = ""
        if n != "PASS" and b in ("PASS", "SKIP", "-") and not (n == "SKIP" and b == "SKIP"):
            mark = "  <-- REGRESSION" if b != "-" else "  <-- FAILING (new test)"
            bad += 1
        elif n != b:
            mark = "  (changed)"
        print("%-*s  %-8s %-8s%s" % (width, name, b, n, mark))
    passed = sum(1 for s in now.values() if s == "PASS")
    print("%d of %d tests pass now; baseline %d of %d" % (passed, len(now), sum(1 for s in before.values() if s == "PASS"), len(before)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
