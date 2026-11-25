#!/usr/bin/env bash
# Installs a built tree (zig-out) as a desktop application.
#
#   zig build -Doptimize=ReleaseSafe
#   packaging/install.sh                 # PREFIX=/usr/local
#   PREFIX=$HOME/.local packaging/install.sh
#   DESTDIR=/tmp/stage packaging/install.sh   # for packagers
#
# Layout: the program and its libraries stay together under
# $PREFIX/lib/seridian-studio/{bin,lib}, because the binaries find their
# libraries through $ORIGIN/../lib. $PREFIX/bin gets symlinks, and the
# desktop entry, icon and AppStream file go under $PREFIX/share.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
prefix="${PREFIX:-/usr/local}"
dest="${DESTDIR:-}"
app="$dest$prefix/lib/seridian-studio"

for f in zig-out/bin/seridian-studio zig-out/bin/seridian zig-out/lib/libdaw-engine.so.0.1.0 zig-out/lib/libdaw-ui.so.0.1.0; do
    [ -e "$root/$f" ] || { echo "missing $f: run 'zig build -Doptimize=ReleaseSafe' first" >&2; exit 1; }
done

# Install into a fresh directory and swap it in, so an update never leaves a
# half-copied tree behind a running launcher.
staging="$app.new"
rm -rf "$staging"
mkdir -p "$staging/bin" "$staging/lib"
cp -a "$root"/zig-out/bin/seridian-studio "$root"/zig-out/bin/seridian "$staging/bin/"
cp -a "$root"/zig-out/lib/libdaw-* "$staging/lib/"
rm -rf "$app.old"
[ -e "$app" ] && mv "$app" "$app.old"
mv "$staging" "$app"
rm -rf "$app.old"

mkdir -p "$dest$prefix/bin"
ln -sf "$prefix/lib/seridian-studio/bin/seridian-studio" "$dest$prefix/bin/seridian-studio"
ln -sf "$prefix/lib/seridian-studio/bin/seridian" "$dest$prefix/bin/seridian"

share="$dest$prefix/share"
install -Dm644 "$here/seridian-studio.desktop" "$share/applications/seridian-studio.desktop"
install -Dm644 "$here/seridian-studio.svg" "$share/icons/hicolor/scalable/apps/seridian-studio.svg"
install -Dm644 "$here/seridian-studio.metainfo.xml" "$share/metainfo/dev.seridian.studio.metainfo.xml"

# Refresh the caches the desktop reads, when the tools exist and this is a real install.
if [ -z "$dest" ]; then
    command -v update-desktop-database >/dev/null && update-desktop-database "$share/applications" || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" || true
    command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
fi
echo "installed to $prefix (app in $prefix/lib/seridian-studio)"
