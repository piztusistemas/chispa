#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Marco Sumari Tellez and IngeCAD contributors.
#
# Build a Debian/Ubuntu package (.deb) of IngeCAD for amd64.
#
#     packaging/build-deb.sh [outdir] [bundle]
#
# bundle: an already built PyInstaller onedir (the folder holding the
# `ingecad` executable). Without it, this builds one first, which needs the
# same as build-appimage.sh: the project venv with the runtime deps, and
# vendor/libredwg/bin built (see tools/libredwg-patches/README.md).
#
# The package installs the bundle under /opt/ingecad, a launcher in
# /usr/bin, and the desktop entry, icons, .dwg/.dxf MIME types and AppStream
# metadata under /usr/share. No maintainer scripts: dpkg's triggers from
# desktop-file-utils, shared-mime-info and hicolor-icon-theme refresh their
# caches on their own.
#
# WHERE TO BUILD THIS: the bundle carries its own Python and Qt but links
# against the host's glibc, as the AppImage does -- build on the oldest
# system you want it to install on (the release workflow uses Ubuntu 22.04,
# glibc 2.35, which also covers Debian 12 and later).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:-$ROOT/dist}
BUNDLE=${2:-}
WORK=${INGECAD_BUILD_DIR:-$ROOT/build}
PYTHON=${PYTHON:-$ROOT/venv/bin/python}
ARCH=amd64

cd "$ROOT"
VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' core/version.py)
PKGDIR="$WORK/deb/ingecad_${VERSION}_$ARCH"
DEB="$OUT/ingecad_${VERSION}_$ARCH.deb"

echo "==> IngeCAD $VERSION -> $DEB"

if [ -z "$BUNDLE" ]; then
    for tool in dwg2dxf dxf2dwg; do
        if [ ! -x "vendor/libredwg/bin/$tool" ]; then
            echo "!! vendor/libredwg/bin/$tool is missing." >&2
            echo "   Build it first: tools/libredwg-patches/README.md" >&2
            exit 1
        fi
    done
    # The bundle carries this Python. On 3.11 a PySide6 refcount slip on
    # None while painting the OpenGL viewport is a fatal error and the app
    # aborts; from 3.12 None is immortal and the slip is harmless. Debian 12
    # ships 3.11: get a 3.12 with `uv python install 3.12` and point PYTHON
    # at a venv made from it.
    if ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
        echo "!! $PYTHON is $("$PYTHON" -V 2>&1); the bundle needs Python 3.12 or newer." >&2
        exit 1
    fi
    echo "==> PyInstaller"
    "$PYTHON" -m PyInstaller --version >/dev/null 2>&1 \
        || "$PYTHON" -m pip install --quiet pyinstaller
    rm -rf "$WORK/pyi"
    INGECAD_ROOT="$ROOT" "$PYTHON" -m PyInstaller --noconfirm \
        --distpath "$WORK/pyi" --workpath "$WORK/pyi-work" \
        packaging/ingecad.spec
    BUNDLE="$WORK/pyi/ingecad"
fi

echo "==> the bundle finds its own data"
"$BUNDLE/ingecad" --check

echo "==> package tree"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/DEBIAN" "$PKGDIR/opt/ingecad" "$PKGDIR/usr/bin" \
         "$PKGDIR/usr/share/applications" "$PKGDIR/usr/share/metainfo" \
         "$PKGDIR/usr/share/mime/packages" \
         "$PKGDIR/usr/share/icons/hicolor/scalable/apps" \
         "$PKGDIR/usr/share/doc/ingecad"
cp -a "$BUNDLE/." "$PKGDIR/opt/ingecad/"

# The launcher does what the AppImage's AppRun does, for the same reasons
# (see build-appimage.sh): Wayland with X11 as the fallback, and GIO kept
# away from the host's modules, which do not load against the bundle's glib.
mkdir -p "$PKGDIR/opt/ingecad/gio-modules"
cat > "$PKGDIR/usr/bin/ingecad" <<'SH'
#!/bin/sh
[ -z "$QT_QPA_PLATFORM" ] && export QT_QPA_PLATFORM="wayland;xcb"
export GIO_MODULE_DIR=/opt/ingecad/gio-modules
exec /opt/ingecad/ingecad "$@"
SH
chmod 755 "$PKGDIR/usr/bin/ingecad"

cp resources/ingecad.desktop "$PKGDIR/usr/share/applications/ingecad.desktop"
cp resources/mime/ingecad.xml "$PKGDIR/usr/share/mime/packages/ingecad.xml"
# The Flatpak's AppStream file, pointed at this package's desktop entry, so
# software centres list IngeCAD with its description and screenshots.
sed 's|<launchable type="desktop-id">.*</launchable>|<launchable type="desktop-id">ingecad.desktop</launchable>|' \
    packaging/flatpak/org.ingecad.IngeCAD.metainfo.xml \
    > "$PKGDIR/usr/share/metainfo/org.ingecad.IngeCAD.metainfo.xml"

cp resources/ingecad.svg "$PKGDIR/usr/share/icons/hicolor/scalable/apps/ingecad.svg"
for s in 16 24 32 48 64 128 256 512; do
    mkdir -p "$PKGDIR/usr/share/icons/hicolor/${s}x${s}/apps"
    cp "resources/icons/ingecad_$s.png" \
       "$PKGDIR/usr/share/icons/hicolor/${s}x${s}/apps/ingecad.png"
    if [ -d "resources/icons/hicolor/${s}x${s}/mimetypes" ]; then
        mkdir -p "$PKGDIR/usr/share/icons/hicolor/${s}x${s}/mimetypes"
        cp resources/icons/hicolor/"${s}x${s}"/mimetypes/*.png \
           "$PKGDIR/usr/share/icons/hicolor/${s}x${s}/mimetypes/"
    fi
done

cat > "$PKGDIR/usr/share/doc/ingecad/copyright" <<TXT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: IngeCAD
Source: https://github.com/ingelibre/ingecad

Files: *
Copyright: 2026 Marco Sumari Tellez and IngeCAD contributors
License: GPL-3.0-or-later
 On Debian systems, the full text of the GNU General Public License
 version 3 can be found in /usr/share/common-licenses/GPL-3.
TXT

# The four libraries packaging/ingecad.spec leaves to the host (issues #20,
# #21), the GL driver Qt loads, and what Qt's xcb platform needs that the
# PySide6 wheel does not carry.
SIZE=$(du -sk --exclude=DEBIAN "$PKGDIR" | cut -f1)
cat > "$PKGDIR/DEBIAN/control" <<CTL
Package: ingecad
Version: $VERSION
Architecture: $ARCH
Maintainer: Marco Sumari Tellez <ing.sumari@gmail.com>
Installed-Size: $SIZE
Depends: libc6 (>= 2.35), libstdc++6, libgcc-s1, libfontconfig1, libfreetype6, libgl1, libegl1, libxkbcommon0, libxkbcommon-x11-0, libxcb-cursor0
Section: graphics
Priority: optional
Homepage: https://ingecad.org
Description: Free 2D CAD for Linux, with DWG out of the box
 IngeCAD is a lightweight 2D drafting program in the spirit of classic CAD:
 the usual command aliases, menus and toolbars with a real command line,
 and faithful round-tripping of DWG/DXF files. Reads and writes DWG through
 GNU LibreDWG, bundled.
CTL

echo "==> dpkg-deb"
mkdir -p "$OUT"
rm -f "$DEB"
dpkg-deb --root-owner-group -Zxz --build "$PKGDIR" "$DEB"
dpkg-deb --info "$DEB" | sed -n '/Package:/,/Depends:/p'

printf '\n%s  (%s)\n' "$DEB" "$(du -h "$DEB" | cut -f1)"
