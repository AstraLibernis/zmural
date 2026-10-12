#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of a wallpaper's properties (Linux) on a headless Sway with two
# outputs: the built-in adjustments of a plain picture or video are set from
# the command line and their effect is read off a screenshot.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/props-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-props
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP
P=$HOME/Pictures/Wallpapers
for c in red green blue; do magick -size 320x180 "xc:$c" "$P/$c.png"; done
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=red:size=320x180:rate=30 -t 2 -pix_fmt yuv420p -c:v libvpx-vp9 -b:v 200k "$P/clip.webm"

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg create_output >/dev/null; swaymsg output HEADLESS-2 resolution 1280x720 position 1280 0 >/dev/null

FAIL=0; ZD=
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
up() {
  setsid "$BIN/zmural" "$@" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
  sleep 3.5
}
down() { kill $ZD 2>/dev/null; sleep 0.7; }
z() { "$BIN/zmural-console" "$@"; }
# What the middle of an output looks like: red, green, blue, dark, grey, or the numbers.
shows() {
  grim -o "HEADLESS-$1" "$W/out$1.png" 2>/dev/null || { echo none; return; }
  magick "$W/out$1.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ d=$1-$2; if (d<0) d=-d; e=$1-$3; if (e<0) e=-e;
           if ($1<25 && $2<25 && $3<25) print "dark"; else if (d<25 && e<25) print "grey";
           else if ($1>200 && $2<60 && $3<60) print "red"; else if ($2>100 && $1<60 && $3<60) print "green";
           else if ($3>200 && $1<60 && $2<60) print "blue"; else print $0 }'
}
V=$W/cfg/properties

up --apply "$P/red.png"
check "a picture has brightness, contrast and gamma" "[ \$(z props | grep -c -i -E 'brightness|contrast|gamma') = 3 ] && ! z props | grep -qi -E 'speed|saturation|hue'"
check "untouched, it shows as it is" "[ \$(shows 1) = red ]"
z prop brightness -100; sleep 1.5
check "brightness all the way down: the picture goes dark, on every monitor showing it" "[ \$(shows 1) = dark ] && [ \$(shows 2) = dark ]"
z prop --reset; sleep 1.5
check "reset puts it back" "[ \$(shows 1) = red ]"
z prop gamma 100; sleep 1.5
check "gamma all the way up: washed out, not plain red any more" "[ \"\$(shows 1)\" != red ] && [ \"\$(shows 1)\" != dark ]"
z prop gamma 0; z prop contrast -100; sleep 1.5
check "contrast all the way down: dark" "[ \$(shows 1) = dark ]"
check "the value is kept in a file of its own for this wallpaper" "[ \$(ls $V | wc -l) = 1 ] && grep -q 'contrast = -100' $V/*.toml && ! grep -q gamma $V/*.toml"

z apply "$P/blue.png" --monitor 2; sleep 2.5
check "a monitor showing another wallpaper isn't touched by the main one's adjustments" "[ \$(shows 1) = dark ] && [ \$(shows 2) = blue ]"
z follow --monitor 2; sleep 2

z apply "$P/green.png"; sleep 2.5
check "another wallpaper starts with its own values" "[ \$(shows 1) = green ]"
z apply "$P/red.png"; sleep 2.5
check "…and coming back, the first still has what was set" "[ \$(shows 1) = dark ]"
down; up
check "…also after a restart" "[ \$(shows 1) = dark ]"

z prop brightness 500 2>/dev/null; rc1=$?
z prop volume 3 2>/dev/null; rc2=$?
z prop gamma lots 2>/dev/null; rc3=$?
check "out of range, unknown and non-numeric values are refused (rc $rc1 $rc2 $rc3)" "[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 1 ] && [ \$(shows 1) = dark ]"
z prop --reset; sleep 1

z apply "$P/clip.webm"; sleep 3
check "a video has six: speed, saturation and hue as well" "[ \$(z props | grep -c -i -E 'speed|brightness|contrast|saturation|gamma|hue') = 6 ] && [ \$(shows 1) = red ]"
z prop saturation -100; sleep 1.5
check "saturation all the way down on a video: grey" "[ \$(shows 1) = grey ]"
z prop saturation 0; z prop speed 2; z prop brightness -100; sleep 1.5
check "brightness and speed reach a playing video, and mpv takes them" "[ \$(shows 1) = dark ] && ! grep -q 'mpv speed\|mpv brightness\|mpv saturation' $W/daemon.log"
z prop --reset

down; kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "logs in $W"; exit 1; }
