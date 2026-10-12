#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# The tray icon as a Sway user meets it (Linux): headless Sway with a session
# bus and swaybar showing tray icons, clicked with a virtual mouse. swaybar
# can't show an app's menu, so a right click asks the app (ContextMenu);
# zmural opens its settings window for both clicks.
#
#   tools/sandbox-deps.sh rigs
#   zig build && tools/tray-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-tray
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/bus.pid" | head -1)
magick -size 320x180 xc:red "$HOME/Pictures/Wallpapers/red.png"

# A plain black bar with nothing but the workspace button and the tray.
cat >"$W/sway.conf" <<EOF
output HEADLESS-1 resolution 1280x720 position 0 0
bar {
  position top
  tray_output *
  status_command while true; do sleep 60; done
  colors { background #000000 statusline #000000 }
}
EOF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
[ -e "$W/xdg/wayland-1" ] || { echo "Sway didn't start (see $W/sway.log)"; exit 1; }
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
dbus-monitor --session "interface='org.kde.StatusNotifierItem'" >"$W/calls.log" 2>&1 & MON=$!

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
windows() { swaymsg -t get_tree | grep -c '"app_id": "org.zmural.Settings"'; }
close() { swaymsg -q '[app_id="org.zmural.Settings"] kill'; sleep 1; }
setsid "$BIN/zmural" --apply "$HOME/Pictures/Wallpapers/red.png" >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 4

# Where the icon is: the only thing drawn on the right half of the bar.
grim -g "640,0 640x20" "$W/bar.png"
read -r w h x y < <(magick "$W/bar.png" -fuzz 10% -trim -format '%w %h %X %Y' info: | tr -d '+')
IX=$((640 + x + w / 2)) IY=$((y + h / 2))
check "the tray icon shows in swaybar (at $IX,$IY, ${w}x${h})" "grep -q 'tray icon registered' $W/daemon.log && [ $w -ge 8 ] && [ $w -le 40 ]"

"$BIN/zmural-test-input" 1280 720 move:$IX,$IY click wait:300 >/dev/null 2>&1; sleep 1.5
check "a left click opens the settings window" "[ \$(windows) = 1 ]"
close
check "…which closes, and zmural stays" "[ \$(windows) = 0 ] && alive $ZD"

"$BIN/zmural-test-input" 1280 720 move:$IX,$IY rclick wait:300 >/dev/null 2>&1; sleep 1.5
check "swaybar asks for the menu on a right click (ContextMenu)" "grep -q 'member=ContextMenu' $W/calls.log"
check "…and the settings window opens for it" "[ \$(windows) = 1 ]"
close

timeout 10 "$BIN/zmural-console" quit >/dev/null 2>&1; sleep 1
check "zmural quits cleanly" "! alive $ZD"
kill $MON $SWAY "$(cat "$W/bus.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
