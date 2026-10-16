#!/usr/bin/env bash
#
# Build + install OpenCode Client into this user's home.
#
#   ./install-local.sh            build, install binary + .desktop + icons
#   ./install-local.sh --no-build reuse the current build/ tree
#
# Safe to re-run: it is the "update" path too (new build -> replace binary,
# refresh .desktop / metainfo / icons, refresh caches).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="io.github.haruki.openclient"
BUILD_DIR="$ROOT/build"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share"

DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $DO_BUILD -eq 1 ]]; then
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "==> configuring meson (prefix=$PREFIX)"
        meson setup "$BUILD_DIR" --prefix="$PREFIX"
    else
        # Keep the recorded prefix in sync if --prefix changed.
        meson configure "$BUILD_DIR" --prefix="$PREFIX" >/dev/null
    fi
    echo "==> compiling"
    meson compile -C "$BUILD_DIR"
fi

echo "==> installing into $PREFIX"
meson install -C "$BUILD_DIR" >/dev/null

# The .desktop ships with an absolute Exec path pointing at the machine it
# was authored on. Rewrite the path part only, so any arguments after the
# binary name survive (the "New Session" action uses --new-session).
DESKTOP="$DATA_DIR/applications/$APP_ID.desktop"
if [[ -f "$DESKTOP" ]]; then
    sed -i -E "s|^Exec=.*$APP_ID|Exec=$BIN_DIR/$APP_ID|" "$DESKTOP"
fi

# ~/.local/bin must be reachable. Add it to the login shell profile once.
if [[ ":$PATH:" != *":$BIN_DIR:"* ]] && ! grep -qs "PATH.*$BIN_DIR" "$HOME/.profile" 2>/dev/null; then
    printf '\n# OpenCode Client\nexport PATH="$PATH:%s"\n' "$BIN_DIR" >> "$HOME/.profile"
    echo "==> added $BIN_DIR to PATH in ~/.profile (re-login or: source ~/.profile)"
fi

# Keep the desktop launcher from going stale.
gtk4-update-icon-cache -q -t -f "$DATA_DIR/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$DATA_DIR/applications" 2>/dev/null || true

echo
echo "installed:"
printf '  binary   %s\n' "$BIN_DIR/$APP_ID"
printf '  desktop  %s\n' "$DESKTOP"
printf '  icons    %s/icons/{hicolor,scalable}\n' "$DATA_DIR"
