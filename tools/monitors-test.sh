#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of per-monitor wallpapers (Linux) on a headless Sway with two
# outputs: each output is screenshotted and its colour read, so "monitor 2
# shows the green one" (and "monitor 2 has bars") is checked on the screen,
# not in a log.
#
#   tools/sandbox-deps.sh rigs
#   zig build && tools/monitors-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-monitors
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP
P=$HOME/Pictures/Wallpapers
# Yellow sorts after red, so Next from red stays among these colours
# (zmural's own wallpaper comes after the user's files).
for c in red green blue yellow; do magick -size 320x180 "xc:$c" "$P/$c.png"; done

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg create_output >/dev/null; swaymsg output HEADLESS-2 resolution 1024x768 position 1280 0 >/dev/null

FAIL=0; ZD=
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
up() { # zmural arguments...
  setsid "$BIN/zmural" "$@" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
  sleep 3.5
}
down() { kill $ZD 2>/dev/null; sleep 0.7; }
z() { "$BIN/zmural-console" "$@"; }
# The colour in the middle of an output: red, green, blue, yellow, or the numbers if it is none of them.
shows() { # output number
  grim -o "HEADLESS-$1" "$W/out$1.png" 2>/dev/null || { echo none; return; }
  magick "$W/out$1.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1>200 && $2<60 && $3<60) print "red"; else if ($2>100 && $1<60 && $3<60) print "green"; else if ($3>200 && $1<60 && $2<60) print "blue"; else if ($1>200 && $2>200 && $3<60) print "yellow"; else print $0 }'
}
both() { [ "$(shows 1)" = "$1" ] && [ "$(shows 2)" = "$2" ]; }
F=$W/cfg/settings.toml
own() { sed -n '/^\[monitors\]/,/^\[playback\]/p' "$F" | grep -c '^m-'; }

up --apply "$P/red.png"
check "status lists both monitors" "[ \$(z status | grep -c 'HEADLESS-[12]') = 2 ]"
check "one wallpaper on both monitors" "both red red"
check "…from one shared renderer" "[ \$(grep -c 'started (image' $W/daemon.log) = 1 ]"

z apply "$P/green.png" --monitor 2; sleep 2.5
check "a monitor named by number gets its own wallpaper; the other keeps the main one" "both red green"
check "…and the file lists it" "[ \$(own) = 1 ] && grep -q \"green.png\" $F"
check "…and status says so" "z status | grep 'HEADLESS-2' | grep -q green.png && z status | grep 'HEADLESS-1' | grep -q 'main wallpaper'"

z apply "$P/blue.png" --monitor HEADLESS-1; sleep 2.5
check "a monitor named by its connector" "both blue green"
z next; sleep 2.5
check "Next changes the main wallpaper only; monitors with their own keep it" "both blue green && z status | head -1 | grep -qv red.png"

down; up
check "after a restart each monitor shows what it did" "both blue green"

z follow --monitor HEADLESS-1; sleep 2.5
M=$(z status | head -1 | sed 's/.*\///; s/\.png//')
check "follow: that monitor shows the main wallpaper again ($M)" "both $M green && [ \$(own) = 1 ]"

z next --monitor 2; sleep 2.5
check "Next for one monitor steps that monitor only" "[ \"\$(shows 1)\" = $M ] && [ \"\$(shows 2)\" != green ] && [ \$(own) = 1 ]"

z apply "$P/red.png"; sleep 2.5
check "apply without --monitor puts one wallpaper everywhere" "both red red && [ \$(own) = 0 ]"

z apply "$P/missing.png" --monitor 2 2>/dev/null; rc1=$?
z apply "$P/blue.png" --monitor 7 2>/dev/null; rc2=$?
z apply "$P/blue.png" --monitor DP-9 2>/dev/null; rc3=$?
check "a missing file and an unknown monitor are refused, and nothing changes (rc $rc1 $rc2 $rc3)" "[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ $rc3 = 1 ] && both red red && [ \$(own) = 0 ]"

# Fill mode per monitor. The pictures are 16:9; output 2 is 4:3, so "fit"
# leaves bars above and below there and "crop" doesn't.
top() { # output number: the colour of a pixel near the top edge
  grim -o "HEADLESS-$1" "$W/top$1.png" 2>/dev/null
  magick "$W/top$1.png" -crop 40x10+400+4 -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1>200 && $2<60 && $3<60) print "red"; else if ($1<40 && $2<40 && $3<40) print "bar"; else print $0 }'
}
fills() { sed -n '/^\[monitor_fill\]/,/^\[library\]/p' "$F" | grep -c '^m-'; }
check "crop: the picture reaches the top edge of the 4:3 monitor" "[ \"\$(top 2)\" = red ]"
z fill fit --monitor 2; sleep 2.5
check "fit on that monitor only: bars there, the middle still the picture" "[ \"\$(top 2)\" = bar ] && both red red && [ \"\$(top 1)\" = red ]"
check "…from a renderer of its own, recorded in the file and in status" "[ \$(fills) = 1 ] && z status | grep HEADLESS-2 | grep -q 'fill: fit'"
check "…while status still gives the main fill mode as crop" "z status | grep -q '^fill *: crop\$' && ! z status | grep HEADLESS-1 | grep -q 'fill:'"
down; up
check "…and kept across a restart" "[ \"\$(top 2)\" = bar ] && [ \"\$(top 1)\" = red ]"
z fill default --monitor 2; sleep 2.5
check "fill default: that monitor follows the main fill mode again" "[ \"\$(top 2)\" = red ] && [ \$(fills) = 0 ]"
z fill fit; sleep 2.5
check "the main fill mode applies to every monitor without its own" "[ \"\$(top 2)\" = bar ]"
check "…and status gives it (fit)" "z status | grep -q '^fill *: fit\$'"
z fill crop; sleep 2.5

# settings.toml edited by hand while zmural runs.
ID=$(z status | grep HEADLESS-2 | grep -o 'm-[0-9a-f]\{16\}')
sed -i "/^\[monitors\]/a $ID = '$P/blue.png'" "$F"; sleep 3
check "a [monitors] line added by hand is picked up" "both red blue"
sed -i "/^$ID/d" "$F"; sleep 3
check "…and removing it follows the main wallpaper again" "both red red"

down; kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "logs in $W"; exit 1; }
