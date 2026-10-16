#!/bin/sh
# Run the launcher from this checkout, without installing anything.
#
# `install.sh` is for a real install: it copies the bundle into ~/.local, links
# it on PATH and writes a desktop entry, which is what puts it in the app grid.
# This is the one to use while working on the launcher — it touches nothing
# outside this directory, so the app grid keeps showing the flatpak alone.
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE="$SELF/build/linux/x64/release/bundle"

if [ ! -x "$BUNDLE/omni_launcher" ]; then
    echo "No bundle to run yet. Build one:" >&2
    echo "  cd $SELF && flutter build linux --release" >&2
    echo "(see README -> From source if the toolchain is missing)" >&2
    exit 1
fi

exec "$BUNDLE/omni_launcher" "$@"
