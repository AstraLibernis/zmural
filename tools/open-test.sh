#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# The settings window's "open it elsewhere" buttons (Linux), pressed with a
# virtual mouse on headless Sway with a session bus: Welcome's folder Open,
# General's Log file Open, and a wallpaper's Show in folder. Twice:
#   1. on a desktop with nothing to open things with (xdg-open fails as it
#      does when no app is set up; no file manager on the bus): each button
#      must say so, with the path, instead of doing nothing;
#   2. with an opener and a file manager: each gets the right path, and
#      nobody is told anything.
# Either way no xdg-open is left behind as a zombie.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/open-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-open
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin" "$W/fail" "$W/work"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/bus.pid" | head -1)
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red.png"
# xdg-open exits 3 when it finds no app for the thing ("no method available").
printf '#!/bin/sh\necho "$@" >>%s/fail/calls\nexit 3\n' "$W" >"$W/fail/xdg-open"
printf '#!/bin/sh\necho "$@" >>%s/work/calls\nexit 0\n' "$W" >"$W/work/xdg-open"
chmod +x "$W/fail/xdg-open" "$W/work/xdg-open"

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
[ -e "$W/xdg/wayland-1" ] || { echo "Sway didn't start (see $W/sway.log)"; exit 1; }
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
L=$W/daemon.log
mark() { N=$(wc -l <"$L"); }
since() { tail -n +$((N + 1)) "$L"; }
click() { "$BIN/zmural-test-input" 1280 720 "$@" wait:300 >/dev/null 2>&1; sleep 1.5; }
# Where things are in a 1280x720 window (the sidebar, then each page's button).
page() { case $1 in welcome) click move:84,56 click ;; wallpapers) click move:91,96 click ;; general) click move:80,216 click ;; esac; }
open_welcome() { page welcome; mark; click move:1184,449 click; }
open_log() { page general; mark; click move:1184,461 click; }
show_in_folder() { page wallpapers; mark; click move:415,190 rclick move:479,247 click; }
zombies() { ps --ppid "$ZD" -o stat=,comm= | grep -c '^Z.*xdg-open'; }

run() { # fail|work
  setsid env PATH="$W/$1:$PATH" "$BIN/zmural" --apply "$P/red.png" >"$L" 2>&1 </dev/null & ZD=$!
  sleep 3
  timeout 10 "$BIN/zmural" --settings >/dev/null 2>&1; sleep 2
}
stop() { timeout 10 "$BIN/zmural-console" quit >/dev/null 2>&1; sleep 1; }

# 1. Nothing to open things with.
run fail
open_welcome
check "Welcome's Open with no opener: xdg-open was asked for the folder" "grep -qx '$HOME/Videos/Wallpapers' $W/fail/calls"
check "…and the user is told nothing opened it, with the path" "since | grep -q 'told: nothing opened the folder.*Videos/Wallpapers'"
open_log
check "Log file Open with no opener: the user is told, with the log's path" "since | grep -q 'told: nothing opened the log.*zmural.log'"
show_in_folder
check "Show in folder with no file manager: the user is told, with the path" "since | grep -q 'told: no file manager answered.*red.png'"
check "no xdg-open is left a zombie ($(zombies))" "[ \$(zombies) = 0 ]"
stop

# 2. An opener and a file manager.
setsid python3 -m dbusmock org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1 >"$W/fm.log" 2>&1 </dev/null & FM=$!
sleep 1.5
gdbus call --session -d org.freedesktop.FileManager1 -o /org/freedesktop/FileManager1 -m org.freedesktop.DBus.Mock.AddMethod '' ShowItems ass '' '' >/dev/null
run work
open_welcome
check "Welcome's Open: xdg-open gets the folder" "grep -qx '$HOME/Videos/Wallpapers' $W/work/calls"
check "…and nobody is told anything" "! since | grep -q 'told:'"
open_log
check "Log file Open: xdg-open gets the log" "grep -q 'zmural.log' $W/work/calls && ! since | grep -q 'told:'"
show_in_folder
check "Show in folder: the file manager is asked to show the file" "grep -q 'ShowItems.*red.png' $W/fm.log && ! since | grep -q 'told:'"
check "no xdg-open is left a zombie ($(zombies))" "[ \$(zombies) = 0 ]"
stop

kill $FM $SWAY "$(cat "$W/bus.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
