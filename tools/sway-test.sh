#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the window facts zmural reads from Sway's IPC (Linux), on a
# headless Sway with one output: a fullscreen window on a hidden workspace
# doesn't pause the wallpaper (the display host's window list alone can't
# tell), a showing one does, windows covering the output do and a small one
# doesn't, and a listed app in front does.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/sway-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-sway-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red.png"

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
L=$W/daemon.log
mark() { N=$(wc -l <"$L"); }
since() { tail -n +$((N + 1)) "$L"; }
paused() { since | grep -q -- '-> pause'; }
resumed() { since | grep -q 'pause -> none'; }
win() { setsid foot -a "$1" sleep 300 >/dev/null 2>&1 </dev/null & sleep 1.2; }

setsid "$BIN/zmural" --apply "$P/red.png" >"$L" 2>&1 </dev/null & ZD=$!
sleep 3
check "zmural reads window facts from Sway's IPC" "grep -q 'window facts and the app in front from its IPC' $L"

# 1. A fullscreen window on a workspace that isn't showing.
swaymsg workspace 3 >/dev/null; mark; win hidden; swaymsg fullscreen enable >/dev/null; sleep 0.5
check "a fullscreen window that is showing pauses the wallpaper" "paused"
mark; swaymsg workspace 1 >/dev/null; sleep 1.5
check "switching to an empty workspace resumes it" "resumed && since | grep -q 'HEADLESS-1: fullscreen=false'"
mark; sleep 1.5
check "a fullscreen window on a hidden workspace doesn't pause it" "! paused"

# 2. Covered: a tiled window fills the output; a small floating one doesn't.
mark; win tiled; sleep 0.5
check "a window covering the output pauses the wallpaper" "paused && since | grep -q 'covered=true'"
mark; swaymsg '[app_id="tiled"] floating enable, resize set 300 200' >/dev/null; sleep 1.5
check "made small and floating, it no longer covers it" "resumed && since | grep -q 'covered=false'"

# 3. The app rule: a listed app in front.
# The small floating window (a foot) has focus but covers nothing: listing
# foot is what pauses.
mark; sed -i 's/^apps = .*/apps = ["foot"]/' "$ZMURAL_CONFIG_DIR/settings.toml"; sleep 2
check "a listed app in front pauses the wallpaper" "since | grep -q 'app rule: foot is in front' && paused"
mark; swaymsg '[app_id="tiled"] kill' >/dev/null; sleep 1.5
check "with none of them in front it resumes" "since | grep -q 'none of your apps is in front' && resumed"

"$BIN/zmural-console" quit; sleep 0.5
swaymsg '[app_id="hidden"] kill' >/dev/null 2>&1
kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
