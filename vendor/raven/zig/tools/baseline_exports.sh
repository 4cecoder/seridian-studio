#!/bin/sh
# baseline_exports.sh <cmake build dir of the pure C build> > baseline/exports.<OS>.txt
# One line per C source: "<src/path.c>: sym sym ..." (the global symbols of its object file).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
build="$1"
[ -d "$build/CMakeFiles/raven.dir" ] || { echo "usage: $0 <cmake build dir>" >&2; exit 2; }
cd "$build/CMakeFiles/raven.dir"
find src -name '*.o' -o -name '*.obj' | sort | while read -r obj; do
	src="${obj%.o}"
	src="${src%.obj}"
	echo "$src: $("$here/lib_symbols.sh" "$obj" | tr '\n' ' ')"
done
