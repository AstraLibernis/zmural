#!/usr/bin/env bash
# Build the GNOME Shell extension zip (renderer + bundled GObject .so +
# typelib + compiled gschema). Configures with the GObject and GNOME
# plugins on; the display lib is statically linked into libwaywallen-gobject
# so only that one .so ships. The zip lands in
# ${BUILD_DIR}/zmural-gnome-*.zip.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_DIR=${BUILD_DIR:-build}

cd "$REPO_ROOT"

cmake -S . -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DWAYWALLEN_DISPLAY_PLUGIN_GOBJECT=ON \
    -DWAYWALLEN_DISPLAY_PLUGIN_GNOME=ON

cmake --build "$BUILD_DIR"

( cd "$BUILD_DIR" && cpack -G ZIP --config CPackConfig.cmake )
