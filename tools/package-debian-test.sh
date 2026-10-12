#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Runs the Linux release tarball inside a Debian 12 root (glibc 2.36, its own
# libmpv, Mesa, Cairo and Pango) against a headless Sway on this machine:
# the oldest distro the tarball claims. The root is downloaded once (about
# 100 MB) and its libraries installed with apt, which needs sudo.
#
#   zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)
#   tools/package-debian-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TGZ=$(ls "$ROOT"/zig-out/package/zmural-*-linux-x86_64.tar.gz 2>/dev/null | head -1)
[ -n "$TGZ" ] || { echo "no tarball: zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)"; exit 1; }
D=${ZMURAL_DEBIAN_ROOT:-/tmp/zmural-debian12}
if [ ! -x "$D/usr/lib/x86_64-linux-gnu/libmpv.so.2" ] && [ ! -e "$D/usr/lib/x86_64-linux-gnu/libmpv.so.2" ]; then
  base=https://images.linuxcontainers.org/images/debian/bookworm/amd64/default
  build=$(curl -sL "$base/" | grep -o '[0-9]\{8\}_[0-9][0-9]:[0-9][0-9]' | sort -u | tail -1)
  [ -n "$build" ] || { echo "can't list $base"; exit 1; }
  mkdir -p "$D"; curl -sL "$base/$build/rootfs.tar.xz" | tar -xJ -C "$D" 2>/dev/null
  sudo rm -f "$D/etc/resolv.conf"; sudo cp /etc/resolv.conf "$D/etc/resolv.conf"
  sudo chroot "$D" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends libmpv2 libegl1 libgbm1 libgles2 libgl1-mesa-dri libpango-1.0-0 libpangocairo-1.0-0 libcairo2 libfontconfig1 fonts-dejavu-core' >"$D.apt.log" 2>&1 ||
    { echo "apt failed; see $D.apt.log"; exit 1; }
fi

W=${TMPDIR:-/tmp}/zmural-debian-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/home/opt" "$W/bin"; chmod 700 "$W/xdg"
tar -xzf "$TGZ" -C "$W/home/opt"
Z=$(ls -d "$W"/home/opt/zmural-*)
cp "$(command -v sway)" "$W/bin/sway-nocap"
magick -size 320x180 xc:red "$W/home/Pictures/Wallpapers/red.png"
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
export XDG_RUNTIME_DIR=$W/xdg
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME ZMURAL_CONFIG_DIR
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
deb() {
  bwrap --bind "$D" / --dev-bind /dev /dev --proc /proc --ro-bind /sys /sys --tmpfs /tmp --bind "$W" "$W" \
    --setenv HOME "$W/home" --setenv XDG_RUNTIME_DIR "$W/xdg" --setenv WAYLAND_DISPLAY wayland-1 --setenv SWAYSOCK "$SWAYSOCK" \
    --setenv PATH /usr/bin:/bin "$@"
}

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
check "inside is Debian 12 with glibc 2.36" "deb cat /etc/debian_version | grep -q '^12' && deb /usr/bin/ldd --version | head -1 | grep -q ' 2.36$'"
check "both programs start there" "deb $Z/bin/zmural --version | grep -q zmural && deb $Z/bin/zmural-console --version | grep -q zmural-console"
deb "$Z/bin/zmural" --apply "$W/home/Pictures/Wallpapers/red.png" >"$W/daemon.log" 2>&1 &
sleep 6
grim "$W/out.png" 2>/dev/null
check "the picture shows, through Debian's libmpv and Mesa" "[ \"\$(magick $W/out.png -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:(r>0.8&&g<0.25&&b<0.25)?1:0]' info:)\" = 1 ]"
check "zmural-console answers" "deb $Z/bin/zmural-console status | grep -q red.png"
deb "$Z/bin/zmural" --settings >/dev/null 2>&1; sleep 3
check "the settings window opens, through Debian's Cairo and Pango" "swaymsg -t get_tree | grep -q '\"app_id\": \"org.zmural.Settings\"' && grep -q 'window: open' $W/daemon.log"
deb "$Z/bin/zmural-console" quit; sleep 1
kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
