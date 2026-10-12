#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Makes the Debian 13 root the KDE plugin and GNOME extension are built in,
# and prints its path. A program built against a library runs only on that
# library's version or newer, so the plugins are built on the oldest system
# that meets what they declare (Plasma 6 and GNOME 48 both ship first in
# Debian 13; Qt 6.8 there), not on the newest machine at hand.
#
#   tools/plugin-root.sh       # once: about 2 GB, apt needs sudo
#   zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)
set -u
# Not under ~/.cache/zmural: `zmural-console uninstall` deletes that folder.
D=${ZMURAL_PLUGIN_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/zmural-build/debian13}
# A root made where it used to live moves here once.
old=$HOME/.cache/zmural/debian13-build
if [ -z "${ZMURAL_PLUGIN_ROOT:-}" ] && [ ! -e "$D" ] && [ -e "$old/.ready" ]; then
  mkdir -p "$(dirname "$D")" && mv "$old" "$D" && { [ -e "$old.apt.log" ] && mv "$old.apt.log" "$D.apt.log"; true; } >&2
fi
if [ ! -e "$D/.ready" ]; then
  base=https://images.linuxcontainers.org/images/debian/trixie/amd64/default
  build=$(curl -sL "$base/" | grep -o '[0-9]\{8\}_[0-9][0-9]:[0-9][0-9]' | sort -u | tail -1)
  [ -n "$build" ] || { echo "can't list $base" >&2; exit 1; }
  sudo rm -rf "$D"; mkdir -p "$D"
  curl -sL "$base/$build/rootfs.tar.xz" | tar -xJ -C "$D" 2>/dev/null
  sudo rm -f "$D/etc/resolv.conf"; sudo cp /etc/resolv.conf "$D/etc/resolv.conf"
  sudo chroot "$D" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      cmake ninja-build g++ pkg-config gettext zip file \
      qt6-base-dev qt6-declarative-dev libegl-dev libgles-dev libgbm-dev libvulkan-dev \
      libgtk-4-dev libglib2.0-dev libglib2.0-dev-bin gobject-introspection libgirepository1.0-dev' >"$D.apt.log" 2>&1 ||
    { echo "apt failed; see $D.apt.log" >&2; exit 1; }
  sudo chown -R "$(id -u):$(id -g)" "$D" 2>/dev/null
  touch "$D/.ready"
fi
echo "$D"
