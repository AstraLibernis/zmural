#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Reinstalls everything the Linux build and the headless tests need in the dev
# container. The container's /usr is a throwaway overlay: every restart of
# the service recreates it from the base image, and every package below is
# gone again (see notes/host-test-2026-09-30.md). Run this once per fresh
# container, before `zig build kde-plugin`, tools/kde-test/run.sh,
# tools/linux-matrix.sh or tools/facts-test.sh.
#
#   tools/sandbox-deps.sh            # install all groups
#   tools/sandbox-deps.sh --check    # only report what's missing (exit 1 if any)
#   tools/sandbox-deps.sh plugins    # one or more groups: plugins rigs tests
#
# Groups:
#   plugins  zig build kde-plugin / gnome-extension (CMake + Ninja, Qt 6, GTK 4, GI)
#   rigs     the headless desktops for linux-matrix.sh, kde-test, gnome-test
#   tests    dbusmock (facts-test, decode-test), gdb, foot, kded6 + kactivitymanagerd
#            (kde-test), ffmpeg (decode-test makes its clips), wtype (keyboard-test types)
set -u
cd "$(dirname "$0")/.." || exit 1

PLUGINS="cmake ninja-build gcc-c++ pkgconf-pkg-config
  qt6-qtbase-devel qt6-qtdeclarative-devel
  gtk4-devel gobject-introspection-devel glib2-devel
  mesa-libEGL-devel mesa-libGLES-devel vulkan-loader-devel mesa-libgbm-devel
  zip"
# mesa-vulkan-drivers: the GNOME extension draws through Vulkan (without it,
# vkCreateInstance fails and gnome-test shows no frame).
RIGS="sway labwc wayfire river niri cosmic-comp mutter gnome-shell
  kwin plasma-workspace plasma-desktop spectacle grim wayland-utils
  mesa-dri-drivers mesa-vulkan-drivers mesa-libgbm mesa-libEGL mpv-libs dbus-daemon ImageMagick"
TESTS="python3-dbusmock gdb foot kf6-kded kactivitymanagerd ffmpeg-free wtype"

# A group is present when every package in it is installed (a half-installed
# group counts as missing; dnf then only adds what isn't there).
probe() {
  local pkgs
  case $1 in plugins) pkgs=$PLUGINS ;; rigs) pkgs=$RIGS ;; tests) pkgs=$TESTS ;; esac
  # shellcheck disable=SC2086
  rpm -q --whatprovides $pkgs >/dev/null 2>&1
}

check=0; groups=()
for a in "$@"; do
  case $a in
    --check) check=1 ;;
    plugins|rigs|tests) groups+=("$a") ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ ${#groups[@]} -eq 0 ] && groups=(plugins rigs tests)

missing=()
for g in "${groups[@]}"; do
  if probe "$g"; then echo "$g: present"; else echo "$g: missing"; missing+=("$g"); fi
done
[ ${#missing[@]} -eq 0 ] && exit 0
[ $check -eq 1 ] && exit 1

pkgs=""
for g in "${missing[@]}"; do
  case $g in plugins) pkgs="$pkgs $PLUGINS" ;; rigs) pkgs="$pkgs $RIGS" ;; tests) pkgs="$pkgs $TESTS" ;; esac
done
# shellcheck disable=SC2086
sudo dnf install -y --setopt=install_weak_deps=False $pkgs || exit 1
for g in "${missing[@]}"; do probe "$g" || { echo "$g: still missing after install" >&2; exit 1; }; done
echo "done; these live in the overlay and vanish on the next container restart"
