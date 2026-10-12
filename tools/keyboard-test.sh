#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the settings window by keyboard alone (Linux), on a headless
# Sway, with keys typed by wtype (a virtual keyboard with its own keymap, so
# this also checks that zmural reads the keymap). Tab moves between groups
# (the pages, the player card's buttons, the buttons above the wallpapers,
# the page); the arrows move inside one, in the direction pressed.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/keyboard-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-keyboard-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
command -v wtype >/dev/null || { echo "wtype isn't installed: tools/sandbox-deps.sh tests"; exit 1; }
cp "$(command -v sway)" "$W/bin/sway-nocap"
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
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
# Types keys, one wtype run (its virtual keyboard appears first, so a pause
# before the first key), then waits for the window to act.
keys() { local a=(-s 600); for k in "$@"; do a+=(-k "$k" -s 120); done; wtype "${a[@]}"; sleep 1; }
tabs() { local k=(); for _ in $(seq "$1"); do k+=(Tab); done; keys "${k[@]}"; }
toml() { grep -q "^$1 = $2\$" "$W/cfg/settings.toml"; }
# Is the middle of this region dark (a focus ring's colour in the light theme)?
ring_at() { grim -g "$1" "$W/ring.png" 2>/dev/null; [ "$(magick "$W/ring.png" -format '%[fx:minima.r<0.2?1:0]' info:)" = 1 ]; }

setsid "$BIN/zmural" --apply "$P/red.png" --settings >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 4
check "no focus ring before a key is pressed" "! ring_at '92,660 48x40'"

# 1. The player card's pause button: Tab to the pages, Tab to the card's
#    first button (previous), Right to the next one.
tabs 2; keys Right
check "Tab and Right show the focus ring (on the pause button)" "ring_at '92,660 48x40'"
keys Return
check "Enter presses it: paused" "z status | grep -q 'paused    : yes'"

# 2. The wallpaper grid: Tab to Open file and Add folder, Tab again to the
#    first tile (green).
tabs 2
keys Return
check "Enter on a wallpaper shows it" "z status | grep -q green.png"

# 3. Right to the next tile (red). The Menu key opens its menu under it;
#    Escape closes it, nothing done.
keys Right
grim -g "540,240 200x100" "$W/no-menu.png"
keys Menu
grim -g "540,240 200x100" "$W/menu.png"
check "the Menu key opens the wallpaper's menu under it" "[ \"\$(magick compare -metric AE $W/no-menu.png $W/menu.png null: 2>&1 | cut -d' ' -f1 | cut -d. -f1)\" -gt 2000 ]"
keys Escape
check "Escape closes it and nothing changes" "z status | grep -q green.png"
keys Menu Return
check "Menu, then Enter on its first line (Show on desktop) shows that wallpaper" "z status | grep -q red.png"

# 4. The Playback page: Tab round to the pages, Home (Welcome), Down past
#    Wallpapers to Playback, Enter.
tabs 1; keys Home Down Down Return
# From Playback: Tab to the card, Tab to the page's first control.
tabs 2; keys Right
check "Right on the fill choice picks the next one (Fit)" "toml fill '\"fit\"'"
keys Down Right Right
check "Right on the volume slider turns it up, a step at a time" "toml volume 60"
keys End
check "End puts it at the top" "toml volume 100"

# 5. General's Reset asks first, with No focused: Enter changes nothing.
#    Tab round to the pages, Home and Down to General; Tab twice to its
#    page, End to its last control (Uninstall), Up to the one above (Reset).
before=$(md5sum <"$W/cfg/settings.toml")
tabs 1; keys Home Down Down Down Down Return
tabs 2; keys End Up Return
grim "$W/question.png"
check "Reset asks first" "[ \"\$(magick $W/question.png -crop 200x60+540+330 +repage -format '%[fx:mean<0.5?1:0]' info:)\" = 0 ] && ! toml volume 50"
keys Return
check "Enter in the question takes the focused No: nothing is reset" "[ \"\$(md5sum <$W/cfg/settings.toml)\" = \"$before\" ] && toml volume 100"

# 6. Escape with no menu or question open closes the window; zmural stays.
check "the window is still open after Escape closed the menu" "! grep -q 'window: closed' $W/daemon.log"
keys Escape
check "Escape with nothing open closes the window" "grep -q 'window: closed' $W/daemon.log && z status >/dev/null"

z quit; sleep 0.5
kill $SWAY 2>/dev/null
grep -qi "panic\|crash" "$W/daemon.log" && { echo "FAIL something crashed"; FAIL=1; }
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
