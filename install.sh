#!/bin/sh
# Install Omni Launcher (Flutter) for the current user (no root, no packaging).
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
BUNDLE="$SELF/build/linux/x64/release/bundle"
PREFIX=${HOME}/.local/opt/omni-launcher
BIN_DIR=${HOME}/.local/bin
APPS_DIR=${HOME}/.local/share/applications
ICONS_DIR=${HOME}/.local/share/icons/hicolor/scalable/apps

if [ ! -x "$BUNDLE/omni_launcher" ]; then
    echo "Build the release bundle first:" >&2
    echo "  distrobox enter fedora -- bash -lc 'cd $SELF && PATH=\$HOME/.local/share/flutter/bin:\$PATH flutter build linux --release'" >&2
    exit 1
fi

mkdir -p "$PREFIX" "$BIN_DIR" "$APPS_DIR" "$ICONS_DIR"
rm -rf "$PREFIX/bundle"
cp -r "$BUNDLE" "$PREFIX/bundle"

ln -sf "$PREFIX/bundle/omni_launcher" "$BIN_DIR/omni-launcher"
install -m 644 "$SELF/data/icons/io.github.CoderPuppy.OmniLauncher.svg" \
    "$ICONS_DIR/io.github.CoderPuppy.OmniLauncher.svg"
sed "s|@EXEC@|$BIN_DIR/omni-launcher|" \
    "$SELF/data/io.github.CoderPuppy.OmniLauncher.desktop.in" \
    > "$APPS_DIR/io.github.CoderPuppy.OmniLauncher.desktop"
chmod 644 "$APPS_DIR/io.github.CoderPuppy.OmniLauncher.desktop"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" || true

echo "Installed:"
echo "  bundle  $PREFIX/bundle/omni_launcher"
echo "  binary  $BIN_DIR/omni-launcher"
echo "  desktop $APPS_DIR/io.github.CoderPuppy.OmniLauncher.desktop"
echo "  icon    $ICONS_DIR/io.github.CoderPuppy.OmniLauncher.svg"
