#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the uninstaller (Linux), on a headless Sway: `zmural-console
# uninstall` asks first and does nothing on "no"; on "yes" it stops zmural
# and removes everything zmural added (start at login, menu entry and icons,
# the KDE/GNOME plugin, settings, log, state, sockets) and nothing else: the
# wallpapers, their folders and zmural's own program folder stay. Then the
# same from the settings window's Uninstall button, by keyboard, also when
# a service manager kills what zmural started as soon as it exits.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/uninstall-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-uninstall-test
command -v wtype >/dev/null || { echo "wtype isn't installed: tools/sandbox-deps.sh tests"; exit 1; }
FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }

setup() {
  rm -rf "$W"; mkdir -p "$W/xdg" "$W/bin"; chmod 700 "$W/xdg"
  cp "$(command -v sway)" "$W/bin/sway-nocap"
  export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME ZMURAL_CONFIG_DIR WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
  # The user's things: wallpapers in the standard folder and in a folder of their own.
  mkdir -p "$HOME/Pictures/Wallpapers" "$HOME/Art"
  magick -size 320x180 xc:red "$HOME/Pictures/Wallpapers/red.png"
  magick -size 320x180 xc:blue "$HOME/Art/blue.png"
  # As if zmural had installed its KDE plugin and GNOME extension here.
  mkdir -p "$HOME/.local/share/plasma/wallpapers/org.zmural.kde" "$HOME/.local/share/gnome-shell/extensions/org.zmural.gnome@zmural"
  echo '{}' >"$HOME/.local/share/plasma/wallpapers/org.zmural.kde/metadata.json"
  echo '{}' >"$HOME/.local/share/gnome-shell/extensions/org.zmural.gnome@zmural/metadata.json"
  printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
  SWAY=$!
  for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
  export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
  setsid "$BIN/zmural" --apply "$HOME/Pictures/Wallpapers/red.png" "$@" >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
  sleep 3
  # Add the user's own folder, as the settings window would.
  sed -i "s|^folders = .*|folders = [\"$HOME/Art\"]|" "$HOME/.config/zmural/settings.toml"; sleep 2
}
added=(".config/autostart/zmural.desktop" ".local/share/applications/org.zmural.Settings.desktop"
  ".local/share/icons/hicolor/48x48/apps/org.zmural.Settings.png" ".local/share/plasma/wallpapers/org.zmural.kde"
  ".local/share/gnome-shell/extensions/org.zmural.gnome@zmural" ".config/zmural/settings.toml" ".local/state/zmural/zmural.log")
kept=("Pictures/Wallpapers/red.png" "Art/blue.png" "Pictures/Wallpapers" "Art")
all_there() { for f in "$@"; do [ -e "$HOME/$f" ] || { echo "  missing: $f"; return 1; }; done; }
none_there() { for f in "$@"; do [ -e "$HOME/$f" ] && { echo "  still there: $f"; return 1; }; done; return 0; }
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

# 1. From the terminal.
setup
check "zmural added its things" "all_there ${added[*]}"
echo n | "$BIN/zmural-console" uninstall >"$W/no.txt" 2>&1
check "answering no removes nothing" "grep -q 'Nothing was removed' $W/no.txt && all_there ${added[*]} && alive $ZD"
echo y | "$BIN/zmural-console" uninstall >"$W/yes.txt" 2>&1; rc=$?
check "answering yes stops zmural (rc=$rc)" "[ $rc = 0 ] && ! alive $ZD && grep -q 'stopped zmural' $W/yes.txt"
check "…and removes everything it added" "none_there ${added[*]} .config/zmural .local/state/zmural .local/share/zmural && [ ! -e $W/xdg/zmural ]"
check "…and nothing else: the wallpapers and their folders stay" "all_there ${kept[*]}"
# The folder it names: bin's parent when share/zmural sits beside bin (a
# tarball's layout, which zig-out also has once the KDE plugin is built).
PROG=$BIN; [ -d "$(dirname "$BIN")/share/zmural" ] && PROG=$(dirname "$BIN")
check "…nor zmural's own program folder, which it names for the user to delete" "[ -x $BIN/zmural ] && grep -q \"To finish, delete zmural.s own folder: $PROG\$\" $W/yes.txt && grep -q 'Not touched: your wallpapers' $W/yes.txt"
kill $SWAY 2>/dev/null; sleep 0.5

# 2. From the settings window: General, Uninstall, then Yes (No has the focus).
setup --settings
k() { local a=(-s 600); for x in "$@"; do a+=(-k "$x" -s 150); done; wtype "${a[@]}"; sleep 1; }
# Tab to the pages, Home (Welcome), Down to General, Tab twice to its page,
# End to its last control (Uninstall).
k Tab Home Down Down Down Down Return Tab Tab End Return
wtype -s 600 -k Left -s 150 -k Return; T0=$(date +%s%N)  # from No to Yes
for _ in $(seq 100); do alive $ZD || break; sleep 0.05; done
GONE_MS=$((($(date +%s%N) - T0) / 1000000)); sleep 1
check "the window's Uninstall button, after its question, removes zmural too" "! alive $ZD && none_there ${added[*]} && all_there ${kept[*]}"
# The window used to wait out a 3 s request to a zmural that was quitting,
# showing a half-drawn dialog (blind test, 2026-10-12).
check "…and it's gone soon after Yes, not seconds later (${GONE_MS} ms)" "[ $GONE_MS -lt 1500 ]"
kill $SWAY 2>/dev/null; sleep 0.5

# 3. The same, under a service manager that ends every process zmural started
# the moment zmural itself exits (systemd's ExitType=main with
# KillMode=control-group: what `systemd-run --user` and most hand-written
# services do). zmural leads its own session here; when it exits, everything
# left in that session is killed, as systemd would kill its cgroup.
# The removal is held back 1.5 s, as a real Plasma's D-Bus round trips hold
# it on the desktop: long enough that zmural has exited before it starts.
ZMURAL_TEST_SLOW_UNINSTALL=1500 setup --settings
( while alive $ZD; do sleep 0.02; done; pkill -KILL -s $ZD ) &
REAPER=$!
k Tab Home Down Down Down Down Return Tab Tab End Return
k Left Return
for _ in $(seq 80); do alive $ZD || break; sleep 0.1; done; sleep 1
wait $REAPER 2>/dev/null
check "…and still removes everything when its children die with it" "! alive $ZD && none_there ${added[*]} && all_there ${kept[*]}"
kill $SWAY 2>/dev/null

[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; files in $W"; exit 1; }
