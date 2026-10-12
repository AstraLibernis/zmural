#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Crashes land in zmural.log (Linux), from zmural itself and from its
# renderers, and a released (stripped) build's addresses turn back into
# the right function with the kept debug file. The crashes are made on
# purpose with ZMURAL_TEST_CRASH, on a headless Sway.
#
#   zig build && zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)
#   tools/crash-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${TMPDIR:-/tmp}/zmural-crash-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap"
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK ZMURAL_TEST_CRASH
magick -size 320x180 xc:red "$HOME/Pictures/Wallpapers/red.png"
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
run() { # label bin-dir crash-spec seconds
  export ZMURAL_CONFIG_DIR=$W/cfg-$1; mkdir -p "$ZMURAL_CONFIG_DIR"
  (ZMURAL_TEST_CRASH=$3 timeout "$4" "$2/zmural" --apply "$HOME/Pictures/Wallpapers/red.png" >"$W/$1.stderr" 2>&1 </dev/null) 2>/dev/null
  echo $? >"$W/$1.rc"
  pkill -f "^$2/zmural( |\$)" 2>/dev/null; sleep 0.5
}
log() { cat "$W/cfg-$1/zmural.log" 2>/dev/null; }

# The working build.
B=$ROOT/zig-out/bin
run main "$B" zmural:panic 10
check "zmural's own panic is in zmural.log, with addresses" "log main | grep -q 'CRASH: zmural .* (zmural, pid [0-9]*): panic: a test crash' && log main | grep -q '^    at 0x'"
check "…and still on stderr, as before" "grep -q 'panic: a test crash' $W/main.stderr"
run fault "$B" zmural:fault 10
check "a fault is in zmural.log too" "log fault | grep -q 'CRASH: .*(zmural, pid [0-9]*): Segmentation fault: at address 0x8'"
run rend "$B" renderer:panic 8
check "a renderer's panic is in the same log, named as the renderer" "log rend | grep -q 'CRASH: .*(renderer image, pid [0-9]*): panic: a test crash'"
check "…while zmural carries on and restarts it" "log rend | grep -q 'renderer 1: restarting in'"
check "…ends in a crash code" "log rend | grep -q '^    code: zmural .* linux crash: [0-9a-f]'"
check "…which zmural shows the user once and clears" "log rend | grep -q 'told the user about a crash: zmural ' && [ ! -e $W/cfg-rend/crash-code ]"

# A renderer that crashes at every start: one notice for the whole run (not
# one per crash), and the line to report stays in status (the settings
# window shows it from there) in case the notice went unseen.
export ZMURAL_CONFIG_DIR=$W/cfg-loop; mkdir -p "$ZMURAL_CONFIG_DIR"
ZMURAL_TEST_CRASH=renderer:panic setsid "$B/zmural" --apply "$HOME/Pictures/Wallpapers/red.png" >"$W/loop.stderr" 2>&1 </dev/null & L=$!
sleep 14
"$B/zmural-console" status >"$W/loop.status" 2>&1
kill $L 2>/dev/null; sleep 0.5
check "a renderer crashing again and again is told once per run ($(log loop | grep -c 'CRASH: .*renderer') crashes)" "[ \$(log loop | grep -c 'CRASH: .*renderer') -ge 3 ] && [ \$(log loop | grep -c 'told the user about a crash') = 1 ] && log loop | grep -q 'another crash this run (not told again)'"
check "…and status keeps the line to report" "grep -q '^crash     : zmural .* linux crash: [0-9a-f]' $W/loop.status"

# The released build: stripped, its debug info kept aside.
P=$(ls -d "$ROOT"/zig-out/package/zmural-*-linux-x86_64 2>/dev/null | head -1)
if [ -n "$P" ]; then
  D=$ROOT/zig-out/package/debug/$(basename "$P")
  run rel "$P/bin" zmural:panic 10
  a=$(log rel | grep -m1 '^    at 0x' | awk '{print $2}')
  check "a released build's crash is in zmural.log, with addresses" "[ -n '$a' ]"
  check "…and the kept debug file turns the first one into the crashing function" "addr2line -f -e $D/zmural.debug $a | head -1 | grep -q testCrash"
  c=$(log rel | grep -m1 '^    code: ' | sed 's/^    code: //')
  check "…and so does its crash code, through zig build crashcode" "(cd $ROOT && zig build crashcode -- \"$c\") 2>&1 | grep -q testCrash"
else
  echo "skip the released-build checks: no package (zig build package ...)"
fi

kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
