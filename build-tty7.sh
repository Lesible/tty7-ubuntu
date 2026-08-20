#!/bin/sh
# Pack the official tty7 Linux tarball into a .deb for Ubuntu 24.04.
# Unlike ghostty-ubuntu (source + zig + dpkg-buildpackage), tty7 ships
# prebuilt binaries — wrapping them is the whole job.
#
# Usage:
#   ./build-tty7.sh                         # download latest linux-x86_64 tarball
#   ./build-tty7.sh 26.8.3                  # that version from GitHub
#   TARBALL=./tty7-*.tar.gz ./build-tty7.sh # use a local tarball
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${TTY7_REPO:-l0ng-ai/tty7}"
DISTRO_VERSION="$(lsb_release -sr 2>/dev/null || echo 24.04)"
ARCH="$(dpkg --print-architecture)"
DEBIAN_SUFFIX="${DEBIAN_SUFFIX:-1~ubuntu${DISTRO_VERSION}}"

if [ "$ARCH" != "amd64" ]; then
  echo "Official Linux tarball is x86_64 only (got $ARCH)." >&2
  exit 1
fi

VERSION="${1:-}"
TARBALL="${TARBALL:-}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

download() {
  ver="$1"
  name="tty7-${ver}-linux-x86_64.tar.gz"
  url="https://github.com/${REPO}/releases/download/v${ver}/${name}"
  echo "Fetch $url"
  wget -q -O "$WORKDIR/$name" "$url"
  TARBALL="$WORKDIR/$name"
}

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || { echo "TARBALL not found: $TARBALL" >&2; exit 1; }
elif [ -n "$VERSION" ]; then
  download "$VERSION"
else
  echo "Resolve latest release"
  VERSION="$(wget -q -O- "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || { echo "Could not resolve latest tag." >&2; exit 1; }
  download "$VERSION"
fi

# Version from tarball name if still unknown.
if [ -z "$VERSION" ]; then
  VERSION="$(basename "$TARBALL" | sed -n 's/^tty7-\([0-9][^/]*\)-linux-.*/\1/p')"
fi
[ -n "$VERSION" ] || { echo "Pass a version or a tty7-VERSION-linux-*.tar.gz" >&2; exit 1; }

echo "Unpack $TARBALL"
tar -xzf "$TARBALL" -C "$WORKDIR"
SRC="$(find "$WORKDIR" -maxdepth 2 -type f -name tty7-app -printf '%h\n' | head -1)"
[ -x "$SRC/tty7-app" ] && [ -x "$SRC/tty7" ] || {
  echo "tarball missing tty7 / tty7-app" >&2
  exit 1
}

PKG="tty7_${VERSION}-${DEBIAN_SUFFIX}_${ARCH}"
ROOT="$WORKDIR/$PKG"
LIB="$ROOT/usr/lib/tty7"
BIN="$ROOT/usr/bin"
DOC="$ROOT/usr/share/doc/tty7"
APP="$ROOT/usr/share/applications"
ICON="$ROOT/usr/share/icons/hicolor/scalable/apps"
DEBIAN="$ROOT/DEBIAN"

mkdir -p "$LIB" "$BIN" "$DOC" "$APP" "$ICON" "$DEBIAN"

install -m 755 "$SRC/tty7" "$LIB/tty7"
install -m 755 "$SRC/tty7-app" "$LIB/tty7-app"
if [ -d "$SRC/completions" ]; then
  cp -a "$SRC/completions" "$LIB/completions"
fi
[ -f "$SRC/README.md" ] && install -m 644 "$SRC/README.md" "$DOC/README.md"
if [ -f "$SRC/LICENSE" ]; then
  install -m 644 "$SRC/LICENSE" "$DOC/copyright"
fi

# Completions are resolved next to the real binary or via TTY7_COMPLETIONS_DIR.
# Wrappers keep /usr/bin names without breaking that lookup.
cat > "$BIN/tty7" <<'EOF'
#!/bin/sh
export TTY7_COMPLETIONS_DIR="${TTY7_COMPLETIONS_DIR:-/usr/lib/tty7/completions}"
exec /usr/lib/tty7/tty7 "$@"
EOF
cat > "$BIN/tty7-app" <<'EOF'
#!/bin/sh
export TTY7_COMPLETIONS_DIR="${TTY7_COMPLETIONS_DIR:-/usr/lib/tty7/completions}"
exec /usr/lib/tty7/tty7-app "$@"
EOF
chmod 755 "$BIN/tty7" "$BIN/tty7-app"

cat > "$APP/tty7.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=tty7
Comment=A terminal workbench: persistent sessions, remote work, agents
Exec=tty7 %F
Icon=tty7
Terminal=false
Categories=System;TerminalEmulator;
Keywords=terminal;shell;console;tty;ssh;
StartupWMClass=tty7
MimeType=x-scheme-handler/ssh;
EOF

# Official app icon (Apache-2.0, l0ng-ai/tty7).
cat > "$ICON/tty7.svg" <<'EOF'
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <rect x="100" y="100" width="824" height="824" rx="185" fill="#ECEAE4"/>
  <g transform="translate(108.8 125.6) scale(8.4)">
    <rect x="28" y="16" width="58" height="46" rx="12" fill="#3FDD8C" opacity="0.8"/>
    <rect x="10" y="30" width="58" height="46" rx="12" fill="#17171A"/>
    <path d="M24 42 L35 53 L24 64" fill="none" stroke="#ECEAE4" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
  </g>
</svg>
EOF

SIZE="$(du -sk "$ROOT" | cut -f1)"

# Direct NEEDED of tty7-app on Ubuntu 24.04; libc6 covers libm.
cat > "$DEBIAN/control" <<EOF
Package: tty7
Version: ${VERSION}-${DEBIAN_SUFFIX}
Architecture: ${ARCH}
Maintainer: local build <tty7@localhost>
Section: utils
Priority: optional
Homepage: https://github.com/${REPO}
Installed-Size: ${SIZE}
Depends: libc6, libgcc-s1, libxcb1, libxkbcommon0, libxkbcommon-x11-0, libgssapi-krb5-2
Recommends: libwayland-client0, xdg-desktop-portal, fonts-ibm-plex
Provides: x-terminal-emulator
Description: GPU-accelerated terminal workbench
 tty7 is a terminal workbench with persistent sessions, native SSH,
 and coding-agent panes. Rendering uses Zed's gpui; the VT layer
 comes from Alacritty.
EOF

echo "Build $PKG.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$SCRIPT_DIR/${PKG}.deb"

echo "Build complete!"
ls -lh "$SCRIPT_DIR/${PKG}.deb"
dpkg-deb -I "$SCRIPT_DIR/${PKG}.deb"
echo
dpkg-deb -c "$SCRIPT_DIR/${PKG}.deb" | awk '{print $6}' | grep -v '/$'
