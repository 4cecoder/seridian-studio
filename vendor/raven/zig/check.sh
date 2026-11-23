#!/usr/bin/env bash
# check.sh - the oracle of the C -> Zig translation of Raven.
#
#   zig/check.sh [options] [extra ported sources...]
#
# Builds Raven with the sources of zig/ported.txt replaced by their Zig translations (plus any
# sources given on the command line, e.g. `check.sh src/core/utf8.c`, to try a file without editing
# ported.txt), then verifies, against the recorded results of the pure C build (zig/baseline/):
#   1. the build succeeds                       (C + Zig, ReleaseSafe: overflow / bounds checks trap)
#   2. libraven.a defines exactly the same global symbols as the C library
#   3. the layout of the public types in Zig is the layout the C compiler gives (zig/layout)
#  3b. the layout of the system types the Zig code takes from std.c is the one of the system headers
#   4. the embedded fonts are byte-identical to the TTF files they come from
#   5. Raven's ctest suite (20 tests) passes like it did before any porting
#  5b. (Linux) the Zig tests of Seridian's additions to Raven (zig/tests/*_test.zig) pass
# and prints PASS or FAIL. Exit status 0 = PASS.
#
# Options:
#   --tag NAME        build directory _build/check-NAME (default: default). Use a different tag per
#                     agent when several checks run in the same checkout at the same time.
#   --seridian        also configure and build the library with the options Seridian's build.zig uses
#   --web             build Raven Web into the library (RAVEN_BUILD_WEB=ON, off by default as in Seridian) and
#                     check it too: its symbols against baseline/exports-web.<OS>.txt, test_web against
#                     baseline/tests-web.<OS>.txt (both recorded from the C sources of web/src)
#   --tools           build the tools too (RAVEN_BUILD_TOOLS=ON: the designer, with zig/designer_ported.txt) and
#                     check their tests against baseline/tests-tools.<OS>.txt (recorded from the C designer)
#   --make-baseline   (re)record baseline/ for this OS from a pure C build (RAVEN_ZIG=OFF); no check
#   --clean           delete the build directory first
#   -v                show the full build output
# Environment: RAVEN_CHECK_JOBS (default 4) parallel build jobs.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
ZIGDIR="$PWD"
RAVEN="$(cd .. && pwd)"
OS="$(uname -s)"

TAG=default
# parallel build jobs (the machine is shared: keep it low)
JOBS="${RAVEN_CHECK_JOBS:-4}"
SERIDIAN=0
WEB=0
TOOLS=0
MAKE_BASELINE=0
CLEAN=0
VERBOSE=0
EXTRA=()
while [ $# -gt 0 ]; do
	case "$1" in
		--tag) TAG="$2"; shift ;;
		--seridian) SERIDIAN=1 ;;
		--web) WEB=1 ;;
		--tools) TOOLS=1 ;;
		--make-baseline) MAKE_BASELINE=1 ;;
		--clean) CLEAN=1 ;;
		-v) VERBOSE=1 ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		-*) echo "check.sh: unknown option $1" >&2; exit 2 ;;
		*) EXTRA+=("$1") ;;
	esac
	shift
done

for tool in cmake ninja zig cc python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "check.sh: '$tool' not found in PATH" >&2; exit 2; }
done

BUILD="$ZIGDIR/_build/check-$TAG"
[ "$CLEAN" = 1 ] && rm -rf "$BUILD"
mkdir -p "$BUILD"
LOG="$BUILD/check.log"
: > "$LOG"

FAILS=()
step() { printf '%-34s' "$1"; }
ok() { echo "ok${1:+  ($1)}"; }
fail() { echo "FAIL${1:+  ($1)}"; FAILS+=("$2"); }

# run a command quietly (output to the log); on failure show the tail of its output
quiet() {
	if [ "$VERBOSE" = 1 ]; then "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; fi
	"$@" >>"$LOG" 2>&1
}
tail_log() { echo "---- last lines of $LOG ----"; tail -n "${1:-25}" "$LOG"; echo "----"; }

COMMON_OPTS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DRAVEN_BUILD_EXAMPLES=OFF -DRAVEN_BUILD_TOOLS=OFF -DRAVEN_BUILD_WEB=OFF -DRAVEN_BUILD_TESTS=ON)
# the library build (its own folder with --web, so that switching does not rebuild everything)
LIB="$BUILD/lib"
if [ "$WEB" = 1 ]; then
	COMMON_OPTS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DRAVEN_BUILD_EXAMPLES=OFF -DRAVEN_BUILD_TOOLS=OFF -DRAVEN_BUILD_WEB=ON -DRAVEN_BUILD_TESTS=ON)
	LIB="$BUILD/lib-web"
fi
if [ "$TOOLS" = 1 ]; then
	for i in "${!COMMON_OPTS[@]}"; do
		[ "${COMMON_OPTS[$i]}" = "-DRAVEN_BUILD_TOOLS=OFF" ] && COMMON_OPTS[$i]="-DRAVEN_BUILD_TOOLS=ON"
	done
	LIB="$LIB-tools"
fi

# ---------------------------------------------------------------------------------------------
if [ "$MAKE_BASELINE" = 1 ]; then
	B="$ZIGDIR/_build/baseline-$OS"
	rm -rf "$B"
	echo "recording the baseline for $OS from a pure C build in $B"
	cmake -S "$RAVEN" -B "$B" "${COMMON_OPTS[@]}" -DRAVEN_ZIG=OFF >"$LOG" 2>&1 && cmake --build "$B" --parallel "$JOBS" >>"$LOG" 2>&1 || { tail_log; exit 1; }
	mkdir -p baseline
	"$ZIGDIR/tools/baseline_exports.sh" "$B" > "baseline/exports.$OS.txt"
	( cd "$B" && ctest -j4 --output-on-failure > "$B/ctest.log" 2>&1 )
	python3 -I "$ZIGDIR/tools/ctest_summary.py" record "$B/ctest.log" "baseline/tests.$OS.txt"
	exit 0
fi

# ---------------------------------------------------------------------------------------------
# effective list of ported sources
PORTED_FILE="$BUILD/ported.txt"
cp "$ZIGDIR/ported.txt" "$PORTED_FILE"
for f in "${EXTRA[@]+"${EXTRA[@]}"}"; do
	f="${f#vendor/raven/}"
	echo "$f" >> "$PORTED_FILE"
done
COUNT=$(sed 's/#.*//' "$PORTED_FILE" | grep -c '[^[:space:]]')
echo "Raven C -> Zig check ($OS, tag '$TAG'): $COUNT ported source file(s)"
sed 's/#.*//' "$PORTED_FILE" | grep '[^[:space:]]' | sed 's/^/    /' | head -n 12
[ "$COUNT" -gt 12 ] && echo "    ... ($((COUNT - 12)) more)"

step "1. build"
if ! quiet cmake -S "$RAVEN" -B "$LIB" "${COMMON_OPTS[@]}" -DRAVEN_ZIG=ON \
		-DRAVEN_ZIG_PORTED_FILE="$PORTED_FILE" -DRAVEN_ZIG_ROOT_NAME=".root_$TAG.zig"; then
	fail "cmake configure failed" "build"; tail_log; echo; echo "RESULT: FAIL (${FAILS[*]})"; exit 1
fi
if ! quiet cmake --build "$LIB" --parallel "$JOBS"; then
	fail "compile or link error" "build"; tail_log 40; echo; echo "RESULT: FAIL (${FAILS[*]})"; exit 1
fi
IGNORED="$(grep 'is not part of this configuration' "$LOG" | sed 's/^-- Raven Zig: //; s/ is not part of this configuration (ignored)//' | tr '\n' ' ')"
if [ -n "$IGNORED" ]; then
	ok "NOTE: not part of this OS / configuration, so not built or tested here: $IGNORED"
else
	ok
fi

# ---------------------------------------------------------------------------------------------
step "2. exported symbols vs C"
BASE_EXPORTS="$ZIGDIR/baseline/exports.$OS.txt"
if [ ! -f "$BASE_EXPORTS" ]; then
	echo "skipped (no baseline/exports.$OS.txt: run check.sh --make-baseline on this OS first)"
else
	BASE_EXPORT_FILES=("$BASE_EXPORTS")
	[ "$WEB" = 1 ] && BASE_EXPORT_FILES+=("$ZIGDIR/baseline/exports-web.$OS.txt")
	sed 's/^[^:]*: //' "${BASE_EXPORT_FILES[@]}" | tr ' ' '\n' | grep . | sort -u > "$BUILD/symbols.expected"
	"$ZIGDIR/tools/lib_symbols.sh" "$LIB/libraven.a" > "$BUILD/symbols.actual"
	comm -23 "$BUILD/symbols.expected" "$BUILD/symbols.actual" > "$BUILD/symbols.missing"
	comm -13 "$BUILD/symbols.expected" "$BUILD/symbols.actual" > "$BUILD/symbols.extra"
	if [ -s "$BUILD/symbols.missing" ] || [ -s "$BUILD/symbols.extra" ]; then
		fail "$(wc -l < "$BUILD/symbols.missing" | tr -d ' ') missing, $(wc -l < "$BUILD/symbols.extra" | tr -d ' ') extra" "symbols"
		[ -s "$BUILD/symbols.missing" ] && { echo "    missing (the C library defines them, the Zig build does not):"; head -n 20 "$BUILD/symbols.missing" | sed 's/^/      /'; }
		[ -s "$BUILD/symbols.extra" ] && { echo "    extra (not in the C library):"; head -n 20 "$BUILD/symbols.extra" | sed 's/^/      /'; }
	else
		ok "$(wc -l < "$BUILD/symbols.actual" | tr -d ' ') symbols"
	fi
fi

# ---------------------------------------------------------------------------------------------
step "3. public type layout (C vs Zig)"
LAY="$BUILD/layout"
mkdir -p "$LAY"
if cc -I "$RAVEN/include" "$ZIGDIR/layout/layout.c" -o "$LAY/layout_c" >"$LAY/cc.log" 2>&1 \
	&& "$LAY/layout_c" > "$LAY/c.txt" 2>>"$LAY/cc.log" \
	&& ( cd "$ZIGDIR" && zig run --dep raven -Mroot=layout/layout.zig -Mraven=src/raven/raven.zig --cache-dir "$LAY/cache" ) > "$LAY/zig.txt" 2>"$LAY/zig.err" </dev/null; then
	if diff "$LAY/c.txt" "$LAY/zig.txt" > "$LAY/diff.txt"; then
		ok "$(wc -l < "$LAY/c.txt" | tr -d ' ') values"
	else
		fail "layout differs" "layout"; head -n 20 "$LAY/diff.txt" | sed 's/^/      /'
	fi
else
	fail "layout program did not build or run" "layout"; cat "$LAY/cc.log" "$LAY/zig.err" 2>/dev/null | head -n 20 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------
step "3b. system types (C vs std.c)"
# The C library / OS types the Zig code passes to C (pthread_*_t, timespec, pollfd, dirent): the system headers, read
# by the C compiler, are the oracle. (The private headers of src/ are not compiled by any C code any more, so their
# layout checks were removed: the Zig header units are the only definition of those types.)
CL="$BUILD/layout_system"
mkdir -p "$CL"
if cc "$ZIGDIR/layout/system_layout.c" -o "$CL/layout_c" >"$CL/cc.log" 2>&1 \
	&& "$CL/layout_c" > "$CL/c.txt" 2>>"$CL/cc.log" \
	&& ( cd "$ZIGDIR" && zig run -lc -Mroot=layout/system_layout.zig --cache-dir "$CL/cache" ) > "$CL/zig.txt" 2>"$CL/zig.err" </dev/null; then
	if diff "$CL/c.txt" "$CL/zig.txt" > "$CL/diff.txt"; then
		ok "$(wc -l < "$CL/c.txt" | tr -d ' ') values"
	else
		fail "system type layout differs" "layout_system"; head -n 20 "$CL/diff.txt" | sed 's/^/      /'
	fi
else
	fail "system layout program did not build or run" "layout_system"; cat "$CL/cc.log" "$CL/zig.err" 2>/dev/null | head -n 20 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------
step "4. embedded fonts"
# The static library drags in the platform objects (locale.c, cocoa_platform.m), so the check
# program needs the same frameworks the CMake link line uses (RAVEN_LIBRARIES, CMakeLists.txt).
FONTFRAMEWORKS=()
[ "$OS" = Darwin ] && FONTFRAMEWORKS=(-framework AppKit -framework QuartzCore -framework Metal)
# Linux: the Zig objects call libm (pow, fmod, sinf...); the C side needs pthread and dl (CMakeLists.txt)
[ "$OS" = Linux ] && FONTFRAMEWORKS=(-lX11 -lm -lpthread -ldl)
if cc "${FONTFRAMEWORKS[@]}" "$ZIGDIR/tools/verify_data.c" "$LIB/libraven.a" -o "$BUILD/verify_data" >"$BUILD/verify_data.log" 2>&1 \
	&& "$BUILD/verify_data" "$BUILD/default.ttf" "$BUILD/mono.ttf" \
	&& cmp -s "$BUILD/default.ttf" "$RAVEN/third_party/roboto/Roboto-Regular-subset.ttf" \
	&& cmp -s "$BUILD/mono.ttf" "$RAVEN/third_party/roboto-mono/RobotoMono-Regular-subset.ttf"; then
	ok "identical to third_party/*.ttf"
else
	fail "font data differs from third_party/*.ttf" "fonts"; head -n 10 "$BUILD/verify_data.log" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------
step "5. ctest"
( cd "$LIB" && ctest -j4 --output-on-failure ) > "$BUILD/ctest.log" 2>&1
BASE_TESTS="$ZIGDIR/baseline/tests.$OS.txt"
if [ "$WEB" = 1 ]; then
	cat "$BASE_TESTS" "$ZIGDIR/baseline/tests-web.$OS.txt" > "$BUILD/tests-with-web.txt"
	BASE_TESTS="$BUILD/tests-with-web.txt"
fi
if [ "$TOOLS" = 1 ]; then
	cat "$BASE_TESTS" "$ZIGDIR/baseline/tests-tools.$OS.txt" > "$BUILD/tests-with-tools.txt"
	BASE_TESTS="$BUILD/tests-with-tools.txt"
fi
if python3 -I "$ZIGDIR/tools/ctest_summary.py" compare "$BUILD/ctest.log" "$BASE_TESTS" > "$BUILD/ctest.summary" 2>&1; then
	ok "$(tail -n 1 "$BUILD/ctest.summary")"
else
	fail "regression vs baseline" "ctest"
	sed 's/^/      /' "$BUILD/ctest.summary" | grep -E 'REGRESSION|FAILING|tests pass|baseline' | head -n 20
	echo "    details: $BUILD/ctest.log"
	grep -B2 -A12 -E 'Failed|\*\*\*' "$BUILD/ctest.log" | head -n 40 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------
# Seridian additions to Raven (not in the C baseline): their Zig tests, linked with the library built above
step "5b. Seridian tests (zig/tests)"
ZT_FAIL=0
ZT_COUNT=0
ZT_FILES=()
# (the tests link the X11 build of the library: Linux only)
[ "$OS" = Linux ] && ZT_FILES=("$ZIGDIR"/tests/*_test.zig)
for t in "${ZT_FILES[@]+"${ZT_FILES[@]}"}"; do
	[ -e "$t" ] || continue
	ZT_COUNT=$((ZT_COUNT + 1))
	rel="tests/$(basename "$t")"
	if ! ( cd "$ZIGDIR" && zig test --dep raven -Mroot="$rel" -Mraven=src/raven/raven.zig -lc "$LIB/libraven.a" \
			-lX11 -lm -lpthread -ldl --cache-dir "$BUILD/zigtest-cache" ) >>"$BUILD/zigtest.log" 2>&1 </dev/null; then
		ZT_FAIL=1
		echo "    $rel failed" >>"$BUILD/zigtest.log"
	fi
done
if [ "$ZT_FAIL" = 0 ]; then
	ok "$ZT_COUNT file(s)"
else
	fail "see $BUILD/zigtest.log" "zigtests"; tail -n 20 "$BUILD/zigtest.log" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------------
if [ "$SERIDIAN" = 1 ]; then
	step "6. Seridian's configuration"
	if quiet cmake -S "$RAVEN" -B "$BUILD/seridian" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
			-DRAVEN_PLATFORM=auto -DRAVEN_BACKEND_VULKAN=ON -DRAVEN_BUILD_SHARED=OFF -DRAVEN_BUILD_EXAMPLES=OFF -DRAVEN_BUILD_TESTS=OFF \
			-DRAVEN_BUILD_TOOLS=OFF -DRAVEN_BUILD_WEB="$([ "$WEB" = 1 ] && echo ON || echo OFF)" -DRAVEN_WITH_STB_IMAGE=OFF \
			-DRAVEN_ZIG_PORTED_FILE="$PORTED_FILE" -DRAVEN_ZIG_ROOT_NAME=".root_${TAG}_seridian.zig" \
		&& quiet cmake --build "$BUILD/seridian" --target raven --parallel "$JOBS"; then
		ok "libraven.a builds"
	else
		fail "build failed" "seridian"; tail_log 25
	fi
fi

# ---------------------------------------------------------------------------------------------
echo
if [ ${#FAILS[@]} -eq 0 ]; then
	echo "RESULT: PASS  ($COUNT ported file(s); symbols, layout, fonts and all baseline tests as in the C build)"
	exit 0
fi
echo "RESULT: FAIL  (${FAILS[*]})   full log: $LOG, $BUILD/ctest.log"
exit 1
