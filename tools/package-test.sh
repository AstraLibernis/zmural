#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Checks the Linux release tarball as a user gets it: extracted into an
# empty folder elsewhere, nothing else of the build around, run on a headless
# Sway. It must show a picture, answer zmural-console, open its settings
# window, add itself to the app menu and autostart from where it was
# extracted, and quit cleanly. Also: which glibc it needs.
#
#   zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)
#   tools/package-test.sh
#   tools/package-test.sh --contents   # only the checks that need no display or GPU (CI)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TGZ=$(ls "$ROOT"/zig-out/package/zmural-*-linux-x86_64.tar.gz 2>/dev/null | head -1)
[ -n "$TGZ" ] || { echo "no tarball: zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)"; exit 1; }
W=${TMPDIR:-/tmp}/zmural-package-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/home/opt" "$W/bin"; chmod 700 "$W/xdg"
tar -xzf "$TGZ" -C "$W/home/opt"
Z=$(ls -d "$W"/home/opt/zmural-*); BIN=$Z/bin

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
glibc() { objdump -T "$1" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1; }

check "the tarball holds both programs, the plugin zips and the readme" "[ -x $BIN/zmural ] && [ -x $BIN/zmural-console ] && [ -f $Z/share/zmural/zmural-kde.zip ] && [ -f $Z/share/zmural/zmural-gnome.zip ] && [ -f $Z/README.txt ] && [ -f $Z/LICENSE.txt ]"
g=$(glibc "$BIN/zmural")
check "zmural needs glibc 2.36 at most (it asks for $g)" "[ \"\$(printf '%s\n' $g GLIBC_2.36 | sort -V | tail -1)\" = GLIBC_2.36 ]"
check "zmural-console needs no libc at all" "! objdump -p $BIN/zmural-console | grep -q NEEDED"
DBG=$(dirname "$TGZ")/debug/$(basename "$Z")
check "no debugging info ships, and no build-folder path" "! readelf -S $BIN/zmural | grep -q debug_info && ! strings $BIN/zmural $BIN/zmural-console | grep -q '$ROOT'"
check "the debugging info kept beside the tarball matches each program (build ID)" "for f in zmural zmural-console; do [ \"\$(readelf -n $BIN/\$f 2>/dev/null | grep 'Build ID')\" = \"\$(readelf -n $DBG/\$f.debug | grep 'Build ID')\" ] || exit 1; done"

if [ "${1:-}" = --contents ]; then
  [ $FAIL = 0 ] && echo "all passed (contents only)" || { echo "FAILED"; exit 1; }
  exit 0
fi

cp "$(command -v sway)" "$W/bin/sway-nocap"
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME ZMURAL_CONFIG_DIR WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
magick -size 320x180 xc:red "$HOME/Pictures/Wallpapers/red.png"

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

setsid "$BIN/zmural" >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 4
# A first run: zmural's own wallpaper shows from the package, and the
# settings window opens by itself on Welcome (closed again, so the desktop
# can be seen).
check "a first run shows zmural's own wallpaper, from the package" "\"$BIN/zmural-console\" status | grep -q 'wallpaper : $Z/share/zmural/wallpapers/Prism.webm'"
check "…and opens the settings window on Welcome" "[ \$(swaymsg -t get_tree | grep -c '\"app_id\": \"org.zmural.Settings\"') = 1 ] && grep -q 'first run, so it opens on Welcome' $HOME/.local/state/zmural/zmural.log"
swaymsg '[app_id="org.zmural.Settings"] kill' >/dev/null; sleep 1
"$BIN/zmural-console" apply "$HOME/Pictures/Wallpapers/red.png"; sleep 2.5
grim "$W/out.png" 2>/dev/null
check "the picture shows on the desktop" "[ \"\$(magick $W/out.png -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:(r>0.8&&g<0.25&&b<0.25)?1:0]' info:)\" = 1 ]"
check "zmural-console answers" "$BIN/zmural-console status | grep -q red.png"
# A video too: the released renderer decodes and shows it.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:size=320x180:rate=30 -t 3 -pix_fmt yuv420p -c:v libvpx-vp9 -b:v 200k "$HOME/Pictures/Wallpapers/blue.webm"
"$BIN/zmural-console" apply "$HOME/Pictures/Wallpapers/blue.webm"; sleep 3
grim "$W/video.png" 2>/dev/null
check "a video plays on the desktop" "[ \"\$(magick $W/video.png -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:(b>0.8&&r<0.25&&g<0.25)?1:0]' info:)\" = 1 ] && grep -q 'decoding vp9 on the' $HOME/.local/state/zmural/zmural.log"
check "start at login points at the extracted zmural" "grep -q \"^Exec=\\\"$BIN/zmural\\\"\" $HOME/.config/autostart/zmural.desktop"
check "the app menu entry opens its settings window" "grep -q \"^Exec=\\\"$BIN/zmural\\\" --settings\" $HOME/.local/share/applications/org.zmural.Settings.desktop"
"$BIN/zmural" --settings >/dev/null 2>&1; sleep 2
check "the settings window opens" "swaymsg -t get_tree | grep -q '\"app_id\": \"org.zmural.Settings\"'"
check "the log is in ~/.local/state/zmural" "grep -q 'window: open' $HOME/.local/state/zmural/zmural.log"
"$BIN/zmural-console" quit; for _ in $(seq 50); do kill -0 $ZD 2>/dev/null || break; sleep 0.1; done
wait $ZD; rc=$?
check "it quits cleanly (rc=$rc)" "[ $rc = 0 ]"

kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
