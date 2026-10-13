#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of switching KDE Plasma to zmural's plugin when Plasma can't be
# reached at first (zmural started before it, at login, say): zmural tries
# again until Plasma answers, then switches its desktops and tells the user,
# instead of leaving the desktop without zmural's wallpaper. Plasma that
# answers with an error is tried again too; Plasma that answers at once is
# switched at once. Plasma and the notification daemon are python-dbusmock
# stand-ins that record their calls; plasmashell --version and kpackagetool6
# are stand-ins on PATH.
#
#   tools/sandbox-deps.sh tests
#   zig build && zig build kde-plugin && tools/kde-switch-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
[ -f "$ROOT/zig-out/share/zmural/zmural-kde.zip" ] || { echo "no plugin zip: zig build kde-plugin"; exit 1; }
W=${TMPDIR:-/tmp}/zmural-kde-switch-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/stubs"; chmod 700 "$W/xdg"
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata XDG_CACHE_HOME=$W/cache
unset XDG_STATE_HOME WAYLAND_DISPLAY SWAYSOCK
export XDG_CURRENT_DESKTOP=KDE
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:green "$P/green.png"

S=$W/stubs
cat >"$S/plasmashell" <<EOS
#!/bin/sh
echo "plasmashell 6.4.0"
EOS
cat >"$S/kpackagetool6" <<EOS
#!/bin/sh
echo "kpackagetool6 \$*" >>"$W/stubs.log"
mkdir -p "$W/xdgdata/plasma/wallpapers/org.zmural.kde" && echo '{}' >"$W/xdgdata/plasma/wallpapers/org.zmural.kde/metadata.json"
EOS
chmod +x "$S"/*
export PATH=$S:$PATH

export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
sleep 1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
# Calls to evaluateScript (an error answer is a line of its own, not counted).
scripts() { cat "$W"/plasma*.log 2>/dev/null | grep -c 'evaluateScript "'; }
told() { grep -c "$1" "$W/notify.log"; }
# A stand-in for Plasma, logging to plasma-$2.log: evaluateScript answers with $1 (Python).
plasma() {
  setsid python3 -m dbusmock --session -l "$W/plasma-$2.log" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell >/dev/null 2>&1 </dev/null & PLASMA=$!
  for _ in $(seq 40); do gdbus introspect --session -d org.kde.plasmashell -o /PlasmaShell >/dev/null 2>&1 && break; sleep 0.25; done
  gdbus call --session -d org.kde.plasmashell -o /PlasmaShell -m org.freedesktop.DBus.Mock.AddMethod \
    org.kde.PlasmaShell evaluateScript s s "$1" >/dev/null
}
up() { setsid "$BIN/zmural" --apply "$P/green.png" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; }
down() { "$BIN/zmural-console" quit >/dev/null 2>&1; for _ in $(seq 30); do kill -0 $ZD 2>/dev/null || break; sleep 0.1; done; }

# 1. First run, Plasma not there yet: the plugin is installed, and zmural
#    keeps trying until Plasma answers 8 s later.
up; sleep 8
check "the plugin is installed while Plasma isn't there yet" "grep -q 'kpackagetool6 --type Plasma/Wallpaper -i' $W/stubs.log"
check "…and zmural says it will try again, without telling the user to do it by hand" "grep -q 'trying again to switch the desktops to zmural' $W/daemon.log && [ \$(told 'set Wallpaper type to zmural') = 0 ]"
plasma 'ret = ""' ok
s=0; for _ in $(seq 80); do [ "$(scripts)" -ge 1 ] && break; sleep 0.5; s=$((s + 1)); done
check "once Plasma is there, its desktops are switched to zmural's plugin (within $((s / 2)) s; tries are at most 16 s apart this early)" "[ \$(scripts) = 1 ] && grep -q 'd.wallpaperPlugin = \"org.zmural.kde\"' $W/plasma-ok.log"
sleep 1
check "…the user is told it shows zmural's wallpaper now, once" "[ \$(told 'now shows zmural') = 1 ]"
check "…and it is tried no more" "sleep 3; [ \$(scripts) = 1 ] && grep -q 'desktops set to zmural' $W/daemon.log"
down

# 2. The next start, Plasma there: switched at once, nothing to tell.
up; sleep 3
check "Plasma there at the start: switched at once, and nothing told (the plugin is up to date)" "[ \$(scripts) = 2 ] && [ \$(told 'now shows zmural') = 1 ] && [ \$(grep -c 'kpackagetool6' $W/stubs.log) = 1 ]"
down
kill $PLASMA 2>/dev/null; sleep 0.5

# 3. Plasma answers with an error (desktop scripting locked, say): tried again, a little later each time.
plasma 'raise dbus.exceptions.DBusException("scripting is locked", name="org.kde.plasmashell.Error")' locked
before=$(scripts); up; sleep 9
n=$(($(scripts) - before))
check "Plasma answering with an error: tried again, 1, 2, 4 s apart ($n tries in 9 s)" "[ $n -ge 3 ] && [ $n -le 5 ]"
check "…and the user isn't told anything yet" "[ \$(told 'set Wallpaper type to zmural') = 0 ]"
down

kill $PLASMA $NOTIFY 2>/dev/null; kill "$(cat "$W/session.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
