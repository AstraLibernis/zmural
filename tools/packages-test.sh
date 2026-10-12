#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of wallpaper packages on Linux (a folder with zmural.toml), on a
# headless Sway: a picture and a video package show the file they name, a
# package's own property reaches the picture, a broken one is refused before
# anything changes, one can't be given to a single monitor, it is one entry
# in the library, it comes back after a restart, and an imported package
# shows straight away; a Lively video package is converted on import and
# plays, its mpv-named slider working. Colours are read off screenshots.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/packages-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-packages-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Videos/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin" "$W/src"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
V=$HOME/Videos/Wallpapers
magick -size 320x180 xc:green "$V/green.png"
# A picture package with a property of its own (an mpv adjustment by name).
mkdir -p "$V/Red still/media"
magick -size 320x180 xc:red "$V/Red still/media/still.png"
cat >"$V/Red still/zmural.toml" <<'EOF'
title = "Red still"
type = "image"
entry = "media/still.png"

[properties.brightness]
kind = "slider"
label = "Darken"
default = 0
min = -100
max = 0
EOF
# A video package.
mkdir -p "$V/Blue loop"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:size=320x180:rate=30 -t 2 -pix_fmt yuv420p -c:v libvpx-vp9 -b:v 200k "$V/Blue loop/loop.webm"
printf 'title = "Blue loop"\ntype = "video"\nentry = "loop.webm"\n' >"$V/Blue loop/zmural.toml"
# A broken one: it names a file that isn't there.
mkdir -p "$W/broken"
printf 'title = "Broken"\ntype = "image"\nentry = "gone.png"\n' >"$W/broken/zmural.toml"
# A package to import.
mkdir -p "$W/src/pkg"
magick -size 320x180 xc:blue "$W/src/pkg/b.png"
printf 'title = "Imported"\ntype = "image"\nentry = "b.png"\n' >"$W/src/pkg/zmural.toml"
(cd "$W/src/pkg" && zip -qr "$W/imported.zip" .)

# A Lively Wallpaper video package, as Lively writes it: Type 7 (video) as a
# number, a BOM, Newtonsoft's comments and trailing commas, and a slider
# named after mpv's property (Lively's way of offering video filters).
mkdir -p "$W/src/lively"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:size=320x180:rate=30 -t 2 -pix_fmt yuv420p -c:v libvpx-vp9 -b:v 200k "$W/src/lively/sea.webm"
printf '\xef\xbb\xbf{\n  "AppVersion": "2.1.0.0", "Title": "Blue sea", "Author": "someone", "Type": 7,\n  "FileName": "sea.webm", "IsAbsolutePath": false, "Tags": null,\n}\n' >"$W/src/lively/LivelyInfo.json"
printf '{\n  /* filters */\n  "brightness": { "type": "slider", "text": "Brightness", "min": -100, "max": 100, "step": 1, "value": 0, },\n  "note": { "type": "label", "value": "hi" },\n}\n' >"$W/src/lively/LivelyProperties.json"
(cd "$W/src/lively" && zip -qr "$W/sea.zip" .)

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

FAIL=0; ZD=
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
up() { setsid "$BIN/zmural" "$@" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; sleep 3.5; }
down() { z quit >/dev/null 2>&1; sleep 0.7; }
shows() {
  grim -o HEADLESS-1 "$W/out.png" 2>/dev/null || { echo none; return; }
  magick "$W/out.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1<25 && $2<25 && $3<25) print "dark"; else if ($1>200 && $2<60 && $3<60) print "red"; else if ($3>200 && $1<60 && $2<60) print "blue"; else if ($2>100 && $1<60 && $3<60) print "green"; else print $0 }'
}
RED="$V/Red still/zmural.toml"

up --apply "$V/green.png"
# Three of the user's, plus zmural's own (Prism).
check "the library lists each package once, not its files (3 entries, and zmural's own)" "z status | grep -q 'library   : 4 wallpapers'"
z apply "$RED"; sleep 2
check "a picture package shows the picture it names" "[ \$(shows) = red ]"
check "…its own property is listed, under its title" "z props | grep -q -i 'Darken' && grep -q \"package 'Red still' (image, 1 properties)\" $W/daemon.log"
z prop brightness -100; sleep 1.5
check "…and setting it reaches the picture (brightness -100: dark)" "[ \$(shows) = dark ]"
z prop --reset; sleep 1.5
z apply "$V/Blue loop/zmural.toml"; sleep 2.5
check "a video package plays the video it names" "[ \$(shows) = blue ]"

z apply "$W/broken/zmural.toml" >"$W/broken.txt" 2>&1; rc=$?
check "a broken package is refused with a reason (exit $rc), and what showed stays" "[ $rc = 1 ] && grep -q 'not a usable wallpaper package' $W/broken.txt && [ \$(shows) = blue ] && grep -q \"the file it names isn't there: gone.png\" $W/daemon.log"
z apply "$RED" --monitor 1 >"$W/mon.txt" 2>&1; rc=$?
check "a package can't be one monitor's own wallpaper (exit $rc)" "[ $rc = 1 ] && grep -q 'only be the main wallpaper' $W/mon.txt && [ \$(shows) = blue ]"

z apply "$RED"; sleep 2; z prop brightness -100; sleep 1
down; up
check "after a restart the package shows again, with its value kept" "[ \$(shows) = dark ] && z status | grep -q 'Red still/zmural.toml'"
z prop --reset; sleep 1

z import "$W/imported.zip" --apply >"$W/import.txt" 2>&1; rc=$?; sleep 2
check "an imported package shows straight away (exit $rc)" "[ $rc = 0 ] && [ \$(shows) = blue ] && z status | grep -q 'imported/zmural.toml'"
z import "$W/sea.zip" --apply >"$W/lively.txt" 2>&1; rc=$?; sleep 2.5
check "a Lively video package is converted on import and plays (exit $rc)" "[ $rc = 0 ] && grep -q 'Lively wallpaper' $W/lively.txt && grep -q 'note (label)' $W/lively.txt && [ \$(shows) = blue ] && grep -q \"title = 'Blue sea'\" $V/sea/zmural.toml"
z prop brightness -100; sleep 1.5
check "…and its Lively slider named after mpv's property works as in Lively (dark)" "[ \$(shows) = dark ]"
z prop --reset
check "zmural is still running and nothing crashed" "kill -0 $ZD && ! grep -qi 'panic\|CRASH' $W/daemon.log"

down; kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; files in $W"; exit 1; }
