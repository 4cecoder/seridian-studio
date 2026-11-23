#!/usr/bin/env bash
# check_unit.sh - compile-check ONE translated file in isolation.
#
#   zig/check_unit.sh <zig/src/....zig> [target]
#
#   target: a zig -target triple, default the host. Use x86_64-linux-gnu for X11 / AT-SPI / POSIX code
#           and x86_64-windows-gnu for Win32 code, so they can be checked on a Mac.
#
# What it does:
#   - compiles the file (every pub declaration is analysed, see src/unit_check.zig) to an object,
#     with the module imports a translation may use:  @import("raven") (public API types) and
#     @import("raven_config") (the build options of the C preprocessor);
#   - compares the global symbols the object defines with the non-static functions / variables of
#     the C file it replaces (src/<m>/<f>.zig <-> vendor/raven/src/<m>/<f>.c|.m): none missing,
#     none extra. A header unit (<name>_h.zig, translation of <name>.h) must export nothing.
# It does not link and does not run anything: zig/check.sh does that. It needs only the .zig files
# the file imports (header units, src/raven/raven.zig), never another translated .c file.
# Exit status 0 = OK.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAVEN="$(cd "$HERE/.." && pwd)"
SRC="$HERE/src"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then sed -n '2,19p' "$0"; exit 2; fi
FILE="$1"
TARGET="${2:-}"
[ -f "$FILE" ] || { echo "UNIT FAIL: $FILE does not exist"; exit 1; }
ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
case "$ABS" in
	"$SRC"/*.zig) ;;
	*) echo "UNIT FAIL: $FILE is not a .zig file under $SRC"; exit 1 ;;
esac
REL="${ABS#"$SRC"/}"

# the OS of the target decides the platform flags of raven_config and the symbol prefix
if [ -n "$TARGET" ]; then OSNAME="$TARGET"; else OSNAME="$(uname -s)"; fi
case "$OSNAME" in
	*macos*|*Darwin*|*darwin*) PLATFORM=cocoa; STRIP=1 ;;
	*windows*|*MINGW*|*MSYS*) PLATFORM=win32; STRIP=0 ;;
	*) PLATFORM=x11; STRIP=0 ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rvn-unit.XXXXXX")"
WRAPPER="$SRC/.unit_$$.zig"
trap 'rm -rf "$TMP" "$WRAPPER"' EXIT

{
	echo "// check_unit.sh: the build options of a default Raven configuration for this target."
	for p in win32 x11 cocoa null; do
		if [ "$p" = "$PLATFORM" ]; then echo "pub const platform_$p = true;"; else echo "pub const platform_$p = false;"; fi
	done
	echo "pub const backend_vulkan = true;"
	echo "pub const with_stb_image = true;"
	echo "pub const build_web = false;"
	echo "pub const paid = false;"
} > "$TMP/raven_config.zig"

if [ "$REL" = "raven/raven.zig" ]; then IMPORT='@import("raven")'; else IMPORT="@import(\"$REL\")"; fi
cat > "$WRAPPER" <<ZIG
pub const panic = @import("unit_check.zig").panic;
comptime {
    _ = &@import("unit_check.zig").RefAll($IMPORT).run;
}
ZIG

ARGS=(build-obj -OReleaseSafe -lc)
[ -n "$TARGET" ] && ARGS+=(-target "$TARGET")
# (the designer's translations also import designer_config: RAVEN_IDE_INCLUDE_DIR, see tools/CMakeLists.txt)
echo "pub const ide_include_dir = \"$RAVEN/include\";" > "$TMP/designer_config.zig"
ARGS+=(--name unit --cache-dir "$HERE/_build/unit-cache" --dep raven_config --dep raven --dep designer_config -Mroot="$WRAPPER"
	-Mraven_config="$TMP/raven_config.zig" -Mraven="$SRC/raven/raven.zig" -Mdesigner_config="$TMP/designer_config.zig"
	-femit-bin="$TMP/unit.o")

( cd "$HERE" && zig "${ARGS[@]}" ) > "$TMP/zig.out" 2>&1 < /dev/null
RC=$?
if [ $RC -ne 0 ]; then
	sed "s|$SRC/||g" "$TMP/zig.out" | head -n 60
	if grep -q 'unable to load\|FileNotFound\|file not found\|no module named' "$TMP/zig.out"; then
		echo "hint: the file imports a .zig file that does not exist yet (a header unit or another unit); it must exist first."
	fi
	echo "UNIT FAIL: $REL does not compile${TARGET:+ for $TARGET}"
	exit 1
fi
# warnings on stderr (zig prints none for a clean build)
[ -s "$TMP/zig.out" ] && sed "s|$SRC/||g" "$TMP/zig.out" | head -n 20

# --- exports versus the C file ---
BASE="${REL%.zig}"
CFILE=""
# (src/web/<f>.zig is web/src/<f>.c; the C files that are ported live on in deprecated-c/)
case "$BASE" in
	web/*) CDIRS=("$RAVEN/web/src" "$RAVEN/deprecated-c/web/src"); CBASE="${BASE#web/}" ;;
	designer/*) CDIRS=("$RAVEN/tools/designer" "$RAVEN/deprecated-c/tools/designer"); CBASE="${BASE#designer/}" ;;
	*) CDIRS=("$RAVEN/src" "$RAVEN/deprecated-c/src"); CBASE="$BASE" ;;
esac
for dir in "${CDIRS[@]}"; do
	for ext in c m; do [ -z "$CFILE" ] && [ -f "$dir/$CBASE.$ext" ] && CFILE="$dir/$CBASE.$ext"; done
done
LIB_SYMBOLS_STRIP=$STRIP "$HERE/tools/lib_symbols.sh" "$TMP/unit.o" > "$TMP/actual.txt"
NACT="$(wc -l < "$TMP/actual.txt" | tr -d ' ')"
if [ -n "$CFILE" ]; then
	python3 -I "$HERE/tools/c_exports.py" "$CFILE" > "$TMP/c_all.txt"
	grep -v '^?' "$TMP/c_all.txt" | sort -u > "$TMP/want.txt"
	grep '^?' "$TMP/c_all.txt" | sed 's/^?//' | sort -u > "$TMP/maybe.txt"
	sort -u "$TMP/want.txt" "$TMP/maybe.txt" > "$TMP/known.txt"
	comm -23 "$TMP/want.txt" "$TMP/actual.txt" > "$TMP/missing.txt"
	comm -13 "$TMP/known.txt" "$TMP/actual.txt" > "$TMP/extra.txt"
	comm -23 "$TMP/maybe.txt" "$TMP/actual.txt" | comm -23 - "$TMP/want.txt" > "$TMP/maybe_missing.txt"
	if [ -s "$TMP/missing.txt" ] || [ -s "$TMP/extra.txt" ]; then
		[ -s "$TMP/missing.txt" ] && { echo "missing exports (the C file defines them as non-static, the Zig file does not export them):"; sed 's/^/    /' "$TMP/missing.txt"; }
		[ -s "$TMP/extra.txt" ] && { echo "extra exports (not defined by the C file; 'export' only what the C file defines non-static):"; sed 's/^/    /' "$TMP/extra.txt"; }
		echo "UNIT FAIL: $REL exports do not match ${CFILE#"$RAVEN"/}"
		exit 1
	fi
	if [ -s "$TMP/maybe_missing.txt" ]; then
		echo "note: not exported on this target (the C file defines them inside #if blocks): $(tr '\n' ' ' < "$TMP/maybe_missing.txt")"
	fi
	echo "UNIT OK: $REL compiles${TARGET:+ for $TARGET}; $NACT exported symbol(s) match ${CFILE#"$RAVEN"/}"
else
	case "$BASE" in
		*_h)
			if [ "$NACT" -ne 0 ]; then
				echo "a header unit must not export anything, but exports: $(tr '\n' ' ' < "$TMP/actual.txt")"
				echo "UNIT FAIL: $REL"
				exit 1
			fi ;;
	esac
	echo "UNIT OK: $REL compiles${TARGET:+ for $TARGET}; no C counterpart to compare exports with ($NACT exported)"
fi
exit 0
