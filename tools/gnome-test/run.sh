#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Runs zmural under a real, headless GNOME Shell in a container without
# systemd, and writes screenshots to zig-out/gnome-test/.
#
#   tools/gnome-test/run.sh [wallpaper] [seconds]
#
# Needs: gnome-shell, python3-dbusmock (a mock logind: gnome-shell won't
# start without one), and zmural's extension (`zig build gnome-extension`).
# Test-only pieces here: a screenshot extension (only code inside the Shell
# may take screenshots) and a bwrap wrapper (GNOME's image encoder sandboxes
# itself with bwrap, whose `--dev` needs a devpts mount a container may refuse).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$ROOT/tools/gnome-test
OUT=$ROOT/zig-out/gnome-test
WALLPAPER=${1:-test-pattern}
SECONDS_=${2:-20}
mkdir -p "$OUT/shots"
(cd "$ROOT" && zig build && zig build gnome-extension) || exit 1

gnome-extensions install --force "$ROOT/zig-out/share/zmural/zmural-gnome.zip"
mkdir -p ~/.local/share/gnome-shell/extensions/zmural-test-shot@local
cp "$HERE"/shot-extension/* ~/.local/share/gnome-shell/extensions/zmural-test-shot@local/
mkdir -p "$OUT/bin" && cp "$HERE/bwrap" "$OUT/bin/bwrap" && chmod +x "$OUT/bin/bwrap"

[ -S /run/dbus/system_bus_socket ] || { sudo mkdir -p /run/dbus && sudo dbus-daemon --system --fork; }
if ! gdbus call --system -d org.freedesktop.login1 -o /org/freedesktop/login1 -m org.freedesktop.login1.Manager.ListSessions >/dev/null 2>&1; then
  sudo setsid python3 -m dbusmock --system --template logind >"$OUT/logind-mock.log" 2>&1 </dev/null &
  sleep 2
fi

R=$(mktemp -d /tmp/zmural-gnome-XXXX); chmod 700 "$R"
export XDG_RUNTIME_DIR=$R XDG_CURRENT_DESKTOP=GNOME ZMURAL_SHOT_DIR=$OUT/shots ZMURAL_CONFIG_DIR=$OUT/config
unset WAYLAND_DISPLAY DISPLAY
dbus-run-session -- bash -c '
  gsettings set org.gnome.shell disable-user-extensions false
  gsettings set org.gnome.shell enabled-extensions "[\"org.zmural.gnome@zmural\", \"zmural-test-shot@local\"]"
  PATH='"$OUT"'/bin:$PATH gnome-shell --headless --virtual-monitor 1280x720 --wayland --no-x11 > '"$OUT"'/shell.log 2>&1 &
  for _ in $(seq 60); do ls $XDG_RUNTIME_DIR | grep -qE "^wayland-[0-9]+$" && break; sleep 0.25; done
  export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+$" | head -1)
  sleep 6
  '"$ROOT"'/zig-out/bin/zmural --apply "'"$WALLPAPER"'" > '"$OUT"'/zmural.log 2>&1 &
  sleep '"$SECONDS_"'
  kill $(jobs -p)'
rm -rf "$R"
echo "renderer first frames: $(grep -c 'first frame' "$OUT/zmural.log")"
echo "screenshots: $OUT/shots"
