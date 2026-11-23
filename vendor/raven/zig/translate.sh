#!/usr/bin/env bash
# translate.sh - a raw baseline translation of ONE Raven C file with `zig translate-c`.
#
#   zig/translate.sh <src/widgets/button.c> [target]       (path relative to vendor/raven, or absolute)
#
# Writes (and prints the paths of):
#   zig/_build/translate/<name>.raw.zig    everything translate-c produces, including the system headers
#   zig/_build/translate/<name>.body.zig   only the declarations the C file itself defines (a text-scan filter)
# The body is a STARTING POINT: translate-c keeps C's integer promotions and every pointer as [*c], writes casts with
# __helpers, and cannot do goto or some macros. Rewrite it by the rules of PORTING.md; use it to read the
# C file's own declarations and the raw file to look up the headers' structs, constants and OS types.
#
# Not for Objective-C (.m): translate-c cannot parse it.
# Known behaviours of this toolchain: translate-c hangs when its output goes to a pipe (this script writes to a
# file) and on some absolute -I paths (this script runs from vendor/raven with relative paths).
# Works: every file of core, widget, widgets, render, xml, the Vulkan files, and for the other OS
#   zig/translate.sh src/platform/x11/x11_platform.c x86_64-linux-gnu      (Raven declares the Xlib API itself)
#   zig/translate.sh src/core/thread_posix.c x86_64-linux-gnu
# Does not work on this toolchain: Objective-C, and the Windows files (translate-c stops in the intrinsics headers
# of mingw): for those read the headers of Windows by hand, see PORTING.md.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAVEN="$(cd "$HERE/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,15p' "$0"; exit 2; }
SRC="${1#"$RAVEN"/}"
TARGET="${2:-}"
[ -f "$RAVEN/$SRC" ] || { echo "translate.sh: $SRC not found under $RAVEN" >&2; exit 2; }
case "$SRC" in
	*.m) echo "translate.sh: translate-c cannot parse Objective-C (it crashes): translate $SRC by hand, see PORTING.md, Cocoa." >&2; exit 2 ;;
esac
OUTDIR="$HERE/_build/translate"
mkdir -p "$OUTDIR"
NAME="$(echo "${SRC#src/}" | tr '/' '_')"
NAME="${NAME%.*}"
RAW="$OUTDIR/$NAME.raw.zig"
BODY="$OUTDIR/$NAME.body.zig"

if [ -n "$TARGET" ]; then OSNAME="$TARGET"; else OSNAME="$(uname -s)"; fi
DEFS=(-DRAVEN_BACKEND_VULKAN_ENABLED -DRAVEN_WITH_STB_IMAGE)
case "$OSNAME" in
	*macos*|*Darwin*|*darwin*) DEFS+=(-DRAVEN_PLATFORM_COCOA -D_DARWIN_C_SOURCE) ;;
	*windows*|*MINGW*|*MSYS*) DEFS+=(-DRAVEN_PLATFORM_WIN32 -D_WIN32_WINNT=0x0601 -DWINVER=0x0601) ;;
	*) DEFS+=(-DRAVEN_PLATFORM_X11 -D_GNU_SOURCE) ;;
esac

# the Vulkan headers, copied under zig/_build so that every path is relative
INCS=(-I include -I src -I "$(dirname "$SRC")" -I third_party)
if [ ! -f "$HERE/_build/vkhdr/vulkan/vulkan_core.h" ]; then
	for d in "${RAVEN_VULKAN_INCLUDE_DIR:-}" /opt/homebrew/include /usr/local/include /usr/include; do
		if [ -n "$d" ] && [ -f "$d/vulkan/vulkan_core.h" ]; then
			mkdir -p "$HERE/_build/vkhdr/vulkan"
			cp "$d"/vulkan/vulkan_core.h "$d"/vulkan/vk_platform.h "$HERE/_build/vkhdr/vulkan/"
			break
		fi
	done
fi
[ -f "$HERE/_build/vkhdr/vulkan/vulkan_core.h" ] && INCS+=(-I zig/_build/vkhdr)

# -lc: with a -target, the headers of that target's libc (glibc, mingw) instead of the host's
ARGS=(translate-c -lc)
[ -n "$TARGET" ] && ARGS+=(-target "$TARGET")
ARGS+=("${DEFS[@]}" "${INCS[@]}" "$SRC")
( cd "$RAVEN" && timeout 120 zig "${ARGS[@]}" > "$RAW" 2> "$OUTDIR/$NAME.err" < /dev/null )
RC=$?
if [ $RC -ne 0 ] || [ ! -s "$RAW" ]; then
	rm -f "$RAW"
	echo "translate.sh: zig translate-c failed (exit $RC) for $SRC${TARGET:+ ($TARGET)}:" >&2
	head -n 20 "$OUTDIR/$NAME.err" >&2
	[ $RC -eq 124 ] && echo "(timeout: translate-c hangs on some inputs)" >&2
	exit 1
fi
[ -s "$OUTDIR/$NAME.err" ] && { echo "translate-c messages:"; head -n 10 "$OUTDIR/$NAME.err"; }
python3 -I "$HERE/tools/translate_filter.py" "$RAW" "$RAVEN/$SRC" > "$BODY"
echo "raw : $RAW ($(wc -l < "$RAW" | tr -d ' ') lines)"
echo "body: $BODY ($(wc -l < "$BODY" | tr -d ' ') lines)"
