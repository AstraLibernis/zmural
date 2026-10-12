#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the app rule on Niri (Linux): Niri runs nested in a headless
# Sway (it has no headless mode), zmural reads the focused window's process
# from Niri's IPC, and a listed app in front pauses the wallpaper.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/niri-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-niri-test
rm -rf "$W"; mkdir -p "$W/outer" "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/outer" "$W/xdg"
command -v niri >/dev/null || { echo "niri isn't installed: tools/sandbox-deps.sh rigs"; exit 1; }
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK NIRI_SOCKET DISPLAY
magick -size 320x180 xc:red "$HOME/Pictures/Wallpapers/red.png"

printf 'output HEADLESS-1 resolution 1280x720\n' >"$W/sway.conf"
XDG_RUNTIME_DIR=$W/outer WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/outer.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/outer/wayland-1" ] && break; sleep 0.25; done
ln -sf "$W/outer/wayland-1" "$W/xdg/outer"
export XDG_RUNTIME_DIR=$W/xdg
WAYLAND_DISPLAY=$W/xdg/outer setsid niri >"$W/niri.log" 2>&1 </dev/null &
NIRI=$!
for _ in $(seq 40); do ls "$W/xdg" | grep -qE '^wayland-[0-9]+$' && ls "$W"/xdg/niri.*.sock >/dev/null 2>&1 && break; sleep 0.25; done
export WAYLAND_DISPLAY=$(ls "$W/xdg" | grep -E '^wayland-[0-9]+$' | head -1) NIRI_SOCKET=$(ls "$W"/xdg/niri.*.sock | head -1)

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
L=$W/daemon.log
mark() { N=$(wc -l <"$L"); }
since() { tail -n +$((N + 1)) "$L"; }

setsid "$BIN/zmural" --apply "$HOME/Pictures/Wallpapers/red.png" >"$L" 2>&1 </dev/null & ZD=$!
sleep 3
check "zmural reads the app in front from Niri's IPC" "grep -q 'Niri: the app in front from its IPC' $L"
check "…and shows the wallpaper there (its own display host)" "grep -q 'first frame' $L"
sed -i 's/^apps = .*/apps = ["foot"]/' "$ZMURAL_CONFIG_DIR/settings.toml"; sleep 2

mark; setsid foot -a listed sleep 300 >/dev/null 2>&1 </dev/null & FOOT=$!; sleep 1.5
check "a listed app in front pauses the wallpaper" "since | grep -q 'app rule: foot is in front' && since | grep -q -- '-> pause'"
mark; kill $FOOT; sleep 1.5
check "with it gone the wallpaper plays again" "since | grep -q 'none of your apps is in front' && since | grep -q 'pause -> none'"

"$BIN/zmural-console" quit; sleep 0.5
kill $NIRI $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
