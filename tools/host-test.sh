#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the layer-shell display host as zmural's own child (Linux) on
# a headless Sway: zmural starts it, starts it again when it dies, never runs
# two on one display, and takes it away when zmural quits or is killed.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/host-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-host-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red.png"

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
# The live host processes (zombies don't count).
hosts() { pgrep -f "^$BIN/zmural --layer-shell" | while read -r p; do grep -q '^State:.*Z' "/proc/$p/status" 2>/dev/null || echo "$p"; done; }
nhosts() { hosts | wc -l; }
# Is the middle of the output red?
red() {
  grim "$W/out.png" 2>/dev/null || return 1
  [ "$(magick "$W/out.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:(r>0.8&&g<0.25&&b<0.25)?1:0]' info:)" = 1 ]
}
start() { setsid "$BIN/zmural" --apply "$P/red.png" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; }

# 1. zmural alone: it starts its own host and the picture shows.
start; sleep 3
check "zmural started its display host itself" "[ \$(nhosts) = 1 ] && grep -q 'display host: started' $W/daemon.log"
check "the wallpaper shows, with nothing else started by hand" "red"

# 2. A second host on the same display leaves at once.
timeout 10 "$BIN/zmural" --layer-shell >"$W/second.log" 2>&1; rc=$?
check "a second host exits and says why (rc=$rc)" "[ $rc = 4 ] && grep -q 'already shows on this display' $W/second.log"
check "…and the first is untouched" "[ \$(nhosts) = 1 ] && red"

# 3. The host dies: zmural starts it again and the picture comes back.
H1=$(hosts); kill -9 $H1; sleep 4
H2=$(hosts)
check "a killed host is started again" "[ -n \"$H2\" ] && [ \"$H2\" != \"$H1\" ] && grep -q 'display host was killed' $W/daemon.log"
check "…and the wallpaper is back" "red"

# 4. Quitting zmural takes the host and the wallpaper with it.
"$BIN/zmural-console" quit; for _ in $(seq 50); do alive $ZD || break; sleep 0.1; done; sleep 0.5
check "zmural quit ends the host" "[ \$(nhosts) = 0 ]"
check "…and the desktop is no longer the wallpaper" "! red"

# 5. zmural killed outright: the host still goes.
start; sleep 3
check "running again" "[ \$(nhosts) = 1 ] && red"
kill -9 $ZD; sleep 1
check "a killed zmural takes its host with it" "[ \$(nhosts) = 0 ]"
rm -f "$W"/xdg/zmural/*.sock

# 6. A host started by hand is used, not doubled.
setsid "$BIN/zmural" --layer-shell >"$W/manual.log" 2>&1 </dev/null & MH=$!
sleep 1; start; sleep 3
check "with a host already running, zmural starts none" "[ \$(nhosts) = 1 ] && [ \$(hosts) = $MH ] && grep -q 'already running on this display; using it' $W/daemon.log"
check "…and shows through it" "red"
"$BIN/zmural-console" quit; sleep 1; kill $MH 2>/dev/null; sleep 0.5

# 7. On KDE Plasma and GNOME the plugin or extension is the host: none is started.
XDG_CURRENT_DESKTOP=KDE setsid "$BIN/zmural" --apply "$P/red.png" >"$W/kde.log" 2>&1 </dev/null & ZD=$!
sleep 3
check "no layer-shell host on KDE Plasma" "[ \$(nhosts) = 0 ] && ! grep -q 'display host: started' $W/kde.log"
kill $ZD 2>/dev/null; sleep 0.5

# 7b. A desktop below what zmural needs: said in the log, and nothing installed
#     for it. Stand-ins report the versions; the installers leave a mark if run.
F=$W/fake; mkdir -p "$F"
printf '#!/bin/sh\necho "plasmashell 5.27.11"\n' >"$F/plasmashell"
printf '#!/bin/sh\necho "GNOME Shell 46.0"\n' >"$F/gnome-shell"
for t in kpackagetool6 gnome-extensions; do printf '#!/bin/sh\ntouch "%s/ran-%s"\n' "$F" "$t" >"$F/$t"; done
chmod +x "$F"/*
need() { # $1 = desktop, $2 = log; more env before the command
  local de=$1 log=$2; shift 2
  env XDG_CURRENT_DESKTOP=$de PATH="$F:$PATH" "$@" setsid "$BIN/zmural" --apply "$P/red.png" >"$W/$log" 2>&1 </dev/null & local z=$!
  sleep 3; kill $z 2>/dev/null; sleep 0.5
}
need KDE need-kde.log
check "Plasma 5: the log says the plugin needs Plasma 6" "grep -q \"KDE plugin needs Plasma 6.*This desktop has Plasma 5.27\" $W/need-kde.log"
need GNOME need-gnome.log
check "GNOME 46: the log names the versions the extension declares" "grep -q 'GNOME extension needs GNOME 48, 49, 50 or 51.*This desktop has GNOME 46' $W/need-gnome.log"
printf '#!/bin/sh\nexit 127\n' >"$F/gnome-shell"; need Budgie:GNOME need-budgie.log # as if not installed
check "GNOME named, but no GNOME Shell: said so" "grep -q \"calls itself GNOME, but GNOME Shell isn't running it\" $W/need-budgie.log"
need KDE need-x11.log XDG_SESSION_TYPE=x11
check "an X11 session: the log says zmural needs Wayland" "grep -q 'zmural needs a Wayland session' $W/need-x11.log"
check "…and in none of them was anything installed" "[ ! -e $F/ran-kpackagetool6 ] && [ ! -e $F/ran-gnome-extensions ]"

kill $SWAY 2>/dev/null; sleep 0.5

# 8. A compositor without wlr-layer-shell (Mutter, standing in for a desktop
#    zmural has no host for): the host says so once and zmural stops trying.
if command -v mutter >/dev/null && command -v dbus-run-session >/dev/null; then
  M=$W/xdg-m; mkdir -p "$M"; chmod 700 "$M"
  XDG_RUNTIME_DIR=$M WAYLAND_DISPLAY= dbus-run-session -- bash -c '
    unset WAYLAND_DISPLAY
    mutter --headless --wayland --no-x11 --virtual-monitor 1280x720 >"'"$W"'/mutter.log" 2>&1 &
    for _ in $(seq 60); do ls $XDG_RUNTIME_DIR | grep -qE "^wayland-[0-9]+$" && break; sleep 0.25; done
    export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+$" | head -1)
    unset DBUS_SESSION_BUS_ADDRESS
    "'"$BIN"'/zmural" --apply test-pattern >"'"$W"'/mutter-daemon.log" 2>&1 &
    sleep 7; kill $(jobs -p)' >/dev/null 2>&1
  check "without wlr-layer-shell the host is tried once, not again and again" "[ \$(grep -c 'display host: started' $W/mutter-daemon.log) = 1 ]"
  check "…and zmural says live wallpapers can't show there" "[ \$(grep -c 'lacks what zmural' $W/mutter-daemon.log) = 1 ]"
else
  echo "skip the no-layer-shell check: mutter or dbus-run-session isn't installed"
fi

[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
