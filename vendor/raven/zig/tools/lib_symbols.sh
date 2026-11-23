#!/bin/sh
# lib_symbols.sh <archive or object>...: the sorted, de-duplicated global symbols it defines
# (functions and data). Mach-O objects: the leading underscore of C names is removed.
# Objective-C class / protocol metadata symbols are skipped.
# LIB_SYMBOLS_STRIP=0|1 overrides the host-based default (check_unit.sh sets it for the target).
strip_underscore=0
[ "$(uname -s)" = "Darwin" ] && strip_underscore=1
[ -n "${LIB_SYMBOLS_STRIP:-}" ] && strip_underscore="$LIB_SYMBOLS_STRIP"
for f in "$@"; do
	nm -g --defined-only -P "$f"
done | awk -v strip="$strip_underscore" 'NF >= 3 && $2 ~ /^[A-Za-z]$/ && $1 !~ /^\./ { n = $1; if (strip && substr(n, 1, 1) == "_") n = substr(n, 2); print n }' | grep -v '^_*OBJC_\|^\$' | sort -u
