#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the settings window (Linux) on a headless Sway. The window is
# a thread inside zmural, so what is checked is what that changes: it opens
# from `zmural --settings`, a second ask raises the one window, it closes
# and opens again, a click in it reaches the daemon, zmural quits cleanly
# with the window open, and a first run opens it by itself on Welcome.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/settings-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-settings-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_ACTIVATION_TOKEN
P=$HOME/Pictures/Wallpapers
for c in red green; do magick -size 320x180 "xc:$c" "$P/$c.png"; done

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
# How many settings windows the compositor has.
windows() { swaymsg -t get_tree | grep -c '"app_id": "org.zmural.Settings"'; }
logged() { grep -c "$1" "$W/daemon.log"; }
# zmural processes other than its renderers and display host: the window is
# a thread, so starting it must not add one.
procs() { pgrep -f "^$BIN/zmural( |$)" | while read -r p; do grep -q '^State:.*Z' "/proc/$p/status" && continue; tr '\0' ' ' <"/proc/$p/cmdline" | grep -qE -- '--renderer|--layer-shell' || echo "$p"; done | wc -l; }

setsid "$BIN/zmural" --apply "$P/red.png" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 1
check "zmural runs, with no window yet" "alive $ZD && [ \$(windows) = 0 ]"

# 1. A second zmural asks the running one for the window.
timeout 10 "$BIN/zmural" --settings >"$W/ask1.log" 2>&1; rc=$?
sleep 2
check "zmural --settings hands over and exits 0 (rc=$rc)" "[ $rc = 0 ] && grep -q 'asked it for the settings window' $W/ask1.log"
check "the window is open" "[ \$(windows) = 1 ] && [ \$(logged 'window: open') = 1 ]"
check "…inside zmural: no process was started for it" "[ \$(procs) = 1 ]"

# 2. Asking again raises the one window.
timeout 10 "$BIN/zmural" --settings >/dev/null 2>&1; sleep 1
check "a second ask brings the one window forward" "[ \$(windows) = 1 ] && [ \$(logged 'already open') = 1 ] && [ \$(logged 'window: open') = 1 ]"

# 3. It drew something: a settings window is not one flat colour.
grim "$W/window.png" 2>/dev/null
check "the window has drawn its pages" "[ \$(magick $W/window.png -unique-colors -format '%w' info:) -gt 50 ]"

# 4. Clicks in the window reach the daemon. Sway tiles the window over the
#    whole 1280x720 output, so its controls sit at fixed places: the player
#    card's pause button, and the first thumbnail (green.png).
"$BIN/zmural-test-input" 1280 720 move:115,680 click wait:300 >/dev/null 2>&1; sleep 1
check "a click on pause pauses the wallpaper" "z status | grep -q 'paused    : yes'"
"$BIN/zmural-test-input" 1280 720 move:415,190 click wait:300 >/dev/null 2>&1; sleep 1
check "a click on a thumbnail shows that wallpaper" "z status | grep -q green.png"

# 5. Closing it leaves zmural running, and it opens again.
swaymsg '[app_id="org.zmural.Settings"] kill' >/dev/null; sleep 1.5
check "closing the window closes only the window" "[ \$(windows) = 0 ] && alive $ZD && [ \$(logged 'window: closed') = 1 ]"
check "zmural still answers" "z status | grep -q green.png"
timeout 10 "$BIN/zmural" --settings >/dev/null 2>&1; sleep 2
check "it opens a second time" "[ \$(windows) = 1 ] && [ \$(logged 'window: open') = 2 ]"

# 6. Quitting with the window open: the window goes, zmural exits cleanly.
z quit; for _ in $(seq 50); do alive $ZD || break; sleep 0.1; done
wait $ZD 2>/dev/null; rc=$?
check "zmural-console quit closes the window and zmural exits 0 (rc=$rc)" "[ $rc = 0 ] && [ \$(windows) = 0 ]"
check "nothing was killed or crashed" "! grep -qi 'panic\|segmentation\|closed by an error' $W/daemon.log"

# 7. With no zmural running, --settings starts one and opens the window.
setsid "$BIN/zmural" --settings >>"$W/daemon2.log" 2>&1 </dev/null & ZD=$!
sleep 3
check "zmural --settings starts zmural with the window open" "alive $ZD && [ \$(windows) = 1 ]"
z quit; sleep 1

# 8. The first run: no settings file, no wallpaper asked for. zmural's own
#    wallpaper (Prism) shows at once, and the window opens by itself on
#    Welcome. A picture put in a standard folder shows up there on its own,
#    after the user's files come zmural's, and a click on it shows it.
#    ($ZMURAL_CONFIG_DIR turns the first run off, so this zmural gets a
#    fresh XDG config and home instead.)
F=$W/first; mkdir -p "$F/cfg" "$F/home"
(export XDG_CONFIG_HOME=$F/cfg HOME=$F/home; unset ZMURAL_CONFIG_DIR
 exec setsid "$BIN/zmural" >>"$W/daemon3.log" 2>&1 </dev/null) & ZD=$!
sleep 3
FLOG=$F/home/.local/state/zmural/zmural.log
check "a first run opens the window by itself" "alive $ZD && [ \$(windows) = 1 ] && grep -q 'first run: opening the settings window' $FLOG"
check "…on Welcome" "grep -q 'first run, so it opens on Welcome' $FLOG"
check "…with zmural's own wallpaper showing" "z status | grep -q 'wallpaper : .*/share/zmural/wallpapers/Prism.webm'"
# Prism has no thumbnail in the desktop's cache (nothing has one here):
# zmural makes one into its own cache, scaled down, and the tile shows it.
grim "$W/welcome.png" 2>/dev/null
check "…and a thumbnail made for its tile" "[ \"\$(magick identify -format '%wx%h' $F/home/.cache/zmural/thumbs/*.png 2>/dev/null)\" = 400x225 ]"
mkdir -p "$F/home/Videos/Wallpapers"; magick -size 320x180 xc:blue "$F/home/Videos/Wallpapers/blue.png"
sleep 5
check "Welcome finds a new picture by itself" "z status | grep -q 'library   : 2 wallpapers'"
"$BIN/zmural-test-input" 1280 720 move:415,250 click wait:300 >/dev/null 2>&1; sleep 1
check "the user's picture comes first: a click on Welcome's first tile shows it" "z status | grep -q blue.png"
z quit; sleep 1
(export XDG_CONFIG_HOME=$F/cfg HOME=$F/home; unset ZMURAL_CONFIG_DIR
 exec setsid "$BIN/zmural" >>"$W/daemon3.log" 2>&1 </dev/null) & ZD=$!
sleep 3
check "the next start is not a first run: no window, the picture chosen" "alive $ZD && [ \$(windows) = 0 ] && [ \$(grep -c 'first run' $FLOG) = 2 ] && z status | grep -q blue.png"
z quit; sleep 1

# 9. A user who closes the window and quits without changing anything gets
#    Welcome again at the next start, on Prism: nothing is saved until the
#    user picks or changes something (owner's decision, 2026-10-06).
F=$W/first2; mkdir -p "$F/cfg" "$F/home"
OPENED=
for _ in 1 2; do
  (export XDG_CONFIG_HOME=$F/cfg HOME=$F/home; unset ZMURAL_CONFIG_DIR
   exec setsid "$BIN/zmural" >>"$W/daemon4.log" 2>&1 </dev/null) & ZD=$!
  sleep 3
  OPENED="$OPENED$(windows)"
  z quit; sleep 1
done
FLOG=$F/home/.local/state/zmural/zmural.log
check "nothing changed: Welcome opens at every start, nothing saved" "[ $OPENED = 11 ] && [ \$(grep -c 'first run: opening' $FLOG) = 2 ] && [ ! -e $F/cfg/zmural/settings.toml ]"

kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
