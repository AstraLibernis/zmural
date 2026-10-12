#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of a wallpaper that can't be played (Linux): a text file named
# .mp4, a file in a format nothing reads. zmural tells the user and goes back
# to the last wallpaper that played, or to its own (Prism) when nothing has;
# a monitor that had the broken file as its own follows the main wallpaper
# again. The broken file is never saved as the wallpaper. Headless Sway with
# two outputs; notifications go to a python-dbusmock daemon that records them.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/broken-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-broken-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red.png"; magick -size 320x180 xc:green "$P/green.png"
echo "this is not a video" >"$W/fake.mp4"

export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null & SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg create_output >/dev/null; swaymsg output HEADLESS-2 resolution 1024x768 position 1280 0 >/dev/null
sleep 1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
main() { z status | head -1; }
F=$W/cfg/settings.toml
# The colour in the middle of an output.
shows() { # output number
  grim -o "HEADLESS-$1" "$W/out$1.png" 2>/dev/null || { echo none; return; }
  magick "$W/out$1.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1>200 && $2<60 && $3<60) print "red"; else if ($2>100 && $1<60 && $3<60) print "green"; else print $0 }'
}
told() { grep -c "can't show $1" "$W/notify.log"; }
up() { setsid "$BIN/zmural" "$@" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; sleep 3; }

# 1. Something played, then a broken file: back to what played.
up --apply "$P/red.png"
check "red plays first" "main | grep -q red.png && [ \"\$(shows 1)\" = red ]"
z apply "$W/fake.mp4"; sleep 3
check "a broken file: back to the last wallpaper that played" "main | grep -q red.png && [ \"\$(shows 1)\" = red ]"
check "…and the user is told what happened" "[ \$(told fake.mp4) = 1 ] && grep \"can't show fake.mp4\" $W/notify.log | grep -q 'Showing red.png again'"
check "…and the broken file isn't saved" "grep -q '^wallpaper = .*red.png' $F && ! grep -q fake.mp4 $F"

# 2. A monitor's own wallpaper is broken: it follows the main one again.
z apply "$W/fake.mp4" --monitor 2; sleep 3
check "a monitor's own broken wallpaper: it follows the main one again" "[ \"\$(shows 2)\" = red ] && ! grep -q fake.mp4 $F && z status | grep HEADLESS-2 | grep -q 'main wallpaper'"
check "…and says so" "[ \$(told fake.mp4) = 2 ] && grep \"can't show fake.mp4\" $W/notify.log | tail -1 | grep -q 'That monitor shows the main wallpaper again'"
z quit; sleep 1

# 3. Nothing has played yet in this run (started straight on the broken
#    file): zmural's own wallpaper instead.
up --apply "$W/fake.mp4"; sleep 2
check "a broken file with nothing played yet: zmural's own wallpaper" "main | grep -q 'share/zmural/wallpapers/Prism.webm'"
check "…said in the notice" "grep \"can't show fake.mp4\" $W/notify.log | tail -1 | grep -q 'Showing Prism.webm instead'"
check "zmural kept running, nothing crashed" "kill -0 $ZD && ! grep -qi 'panic\|segmentation' $W/daemon.log"
z quit; sleep 1

kill $SWAY $NOTIFY 2>/dev/null; kill "$(cat "$W/session.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
