#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Runs zmural under a headless Plasma 6 (virtual KWin) and checks the tray
# icon, its menu, the settings launcher, the one-settings-window rule, that
# a fullscreen window pauses the wallpaper through zmural's Plasma plugin,
# that a listed app in front does too (KWin reports it), that a closed
# settings window (a thread inside zmural) closes cleanly and leaves zmural running,
# and that quitting with the window open is clean.
# Writes a screenshot to zig-out/kde-test/panel.png.
#
#   tools/kde-test/run.sh
#
# Needs: kwin_wayland, plasmashell, kded6 (it hosts the StatusNotifierWatcher),
# kactivitymanagerd (plasmashell aborts without it), a system bus (started
# here if missing), spectacle, gdbus, foot (the window that goes fullscreen),
# ImageMagick, and the plugin zip (`zig build kde-plugin`).
# kwin_wayland carries file capabilities a container may refuse to exec, so a
# plain copy is run; it must keep the name kwin_wayland or its QPA plugin aborts.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/zig-out/kde-test
Z=$ROOT/zig-out/bin

if [ "${1:-}" != --inside ]; then
  (cd "$ROOT" && zig build) || exit 1
  # plasmashell wants a system bus; a container usually has none.
  [ -S /run/dbus/system_bus_socket ] || { sudo mkdir -p /run/dbus && sudo dbus-daemon --system --fork; } || exit 1
  T=$(mktemp -d); R=$(mktemp -d /tmp/zmkt-XXXX); chmod 700 "$R"
  trap 'rm -rf "$T" "$R"' EXIT
  mkdir -p "$OUT" "$T/kbin" "$T/home/Pictures/Wallpapers"
  cp "$(command -v kwin_wayland)" "$T/kbin/kwin_wayland"
  # Two wallpapers, so the settings window has thumbnails to free when it closes.
  magick -size 640x360 gradient:blue-orange "$T/home/Pictures/Wallpapers/a.png"
  magick -size 640x360 gradient:red-green "$T/home/Pictures/Wallpapers/b.png"
  # The whole session gets a throwaway home: zmural installs its launcher,
  # autostart and plugin there, and plasmashell must find that plugin.
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
    HOME=$T/home XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY= DISPLAY= KT=$T timeout 240 dbus-run-session -- "$0" --inside 2>&1 |
    grep -v '^$\|dbus-daemon\|portal\|fuse\|Gtk-WARN\|KSplash'
  exit "${PIPESTATUS[0]}"
fi

T=$KT
FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
# The settings window is a thread inside zmural: its log says what it did.
logged() { grep -c "$1" "$OUT/daemon.log"; }
daemon_alive() { kill -0 $DPID 2>/dev/null && ! grep -q '^State:.*Z' /proc/$DPID/status; }

"$T/kbin/kwin_wayland" --virtual --width 1280 --height 720 --socket wayland-k >"$OUT/kwin.log" 2>&1 &
for _ in $(seq 60); do [ -S "$XDG_RUNTIME_DIR/wayland-k" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-k QT_QPA_PLATFORM=wayland XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6
/usr/libexec/kactivitymanagerd >/dev/null 2>&1 &
kded6 >"$OUT/kded.log" 2>&1 &
sleep 2
plasmashell >"$OUT/plasmashell.log" 2>&1 &
sleep 12

export ZMURAL_CONFIG_DIR=$T/cfg
"$Z/zmural" --apply test-pattern >"$OUT/daemon.log" 2>&1 &
DPID=$!
sleep 10
ITEM=org.kde.StatusNotifierItem-$DPID-1
ctl() { "$Z/zmural-console" status | grep -E "^ *$1" | grep -q "$2"; }
# Runs a KWin script (a file) once.
kscript() {
  local id; id=$(gdbus call --session -d org.kde.KWin -o /Scripting -m org.kde.kwin.Scripting.loadScript "$1" | grep -o '[0-9]\+' | head -1)
  gdbus call --session -d org.kde.KWin -o /Scripting/Script$id -m org.kde.kwin.Script.run >/dev/null
  sleep 2
  gdbus call --session -d org.kde.KWin -o /Scripting/Script$id -m org.kde.kwin.Script.stop >/dev/null 2>&1
}

check "the tray host knows the icon" \
  "gdbus call --session -d org.kde.StatusNotifierWatcher -o /StatusNotifierWatcher -m org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems | grep -q $ITEM"
check "launcher installed" "grep -q '^Icon=org.zmural.Settings' $T/home/.local/share/applications/org.zmural.Settings.desktop"
check "icons installed" "[ \$(ls $T/home/.local/share/icons/hicolor/*/apps/org.zmural.Settings.png | wc -l) = 7 ]"

gdbus call --session -d "$ITEM" -o /MenuBar -m com.canonical.dbusmenu.Event 3 clicked '<0>' 0 >/dev/null
gdbus call --session -d "$ITEM" -o /MenuBar -m com.canonical.dbusmenu.Event 4 clicked '<0>' 0 >/dev/null
sleep 0.5
check "menu: Paused toggles" "ctl paused yes"
check "menu: Muted toggles" "ctl muted no"

for i in 1 2 3; do
  gdbus call --session -d "$ITEM" -o /StatusNotifierItem -m org.kde.StatusNotifierItem.ProvideXdgActivationToken "tok$i" >/dev/null
  gdbus call --session -d "$ITEM" -o /StatusNotifierItem -m org.kde.StatusNotifierItem.Activate 0 0 >/dev/null
  sleep 2
done
check "three tray clicks open one window" "[ \$(logged 'window: open') = 1 ] && [ \$(logged 'already open') = 2 ]"
timeout 10 "$Z/zmural" --settings >"$OUT/second.log" 2>&1
check "a launch from the app menu hands over and exits 0" "[ $? = 0 ] && grep -q 'asked it for the settings window' $OUT/second.log"
sleep 1
check "still one window" "[ \$(logged 'window: open') = 1 ] && [ \$(logged 'already open') = 3 ]"

timeout 20 spectacle -b -n -f -o "$OUT/panel.png" >/dev/null 2>&1

# Closing the window: its thread must end cleanly and leave zmural running
# (it crashed once, freeing thumbnails after Cairo was unloaded; and again
# when it moved into zmural, at the thread's end with Cairo unloaded).
echo 'for (const w of workspace.windowList()) if (w.caption == "zmural") w.closeWindow();' >"$T/close.js"
kscript "$T/close.js"; sleep 1
check "the closed settings window is gone" "[ \$(logged 'window: closed') = 1 ]"
check "…and zmural is still running" "daemon_alive"
check "…with nothing crashed" "! grep -qi 'panic\|segmentation\|closed by an error' $OUT/daemon.log"

# Pausing: zmural's plugin is the desktop's wallpaper and reports the windows.
# KWin scripting makes a real window fullscreen (a --fullscreen flag isn't one).
check "the Plasma plugin connected" "grep -q 'display 1: .* modifiers' $OUT/daemon.log"
ctl paused yes && gdbus call --session -d "$ITEM" -o /MenuBar -m com.canonical.dbusmenu.Event 3 clicked '<0>' 0 >/dev/null
foot -a zmural-kde-test sleep 100 >/dev/null 2>&1 &
sleep 2
for v in true false; do
  echo "for (const w of workspace.windowList()) if (w.resourceClass == 'zmural-kde-test') w.fullScreen = $v;" >"$T/fs-$v.js"
done
# Only what is logged from here on counts (the menu test paused it too).
N=$(wc -l <"$OUT/daemon.log"); since() { tail -n +$((N + 1)) "$OUT/daemon.log"; }
kscript "$T/fs-true.js"
check "a fullscreen window is reported" "since | grep -q 'windows: fullscreen=true'"
check "…and pauses the wallpaper" "since | grep -q 'none -> pause'"
kscript "$T/fs-false.js"; sleep 3
check "leaving fullscreen resumes it" "since | grep -q 'pause -> none'"

# The app rule: KWin tells zmural which program is in front. The rule is set
# by editing settings.toml under the running zmural.
check "KWin reports the app in front" "grep -q 'KWin reports the app in front' $OUT/daemon.log"
N=$(wc -l <"$OUT/daemon.log") # the test window may be in front already when the rule arrives
sed -i 's/^apps = .*/apps = ["foot"]/' "$T/cfg/settings.toml"; sleep 2
echo "for (const w of workspace.windowList()) if (w.resourceClass == 'zmural-kde-test') workspace.activeWindow = w;" >"$T/front.js"
kscript "$T/front.js"
check "a listed app in front pauses the wallpaper" "since | grep -q 'app rule: foot is in front' && since | grep -q 'none -> pause'"
N=$(wc -l <"$OUT/daemon.log")
gdbus call --session -d "$ITEM" -o /StatusNotifierItem -m org.kde.StatusNotifierItem.Activate 0 0 >/dev/null; sleep 3
echo 'for (const w of workspace.windowList()) if (w.caption == "zmural") workspace.activeWindow = w;' >"$T/front2.js"
kscript "$T/front2.js"; sleep 1
check "another app in front resumes it" "since | grep -q 'none of your apps is in front' && since | grep -q 'pause -> none'"

# Quitting with the settings window open: the window closes first, KWin
# reports the app now in front while zmural unloads its foreground script,
# and that report once ran over the displays already freed (host test 10-06).
"$Z/zmural-console" quit >/dev/null 2>&1
for _ in $(seq 40); do daemon_alive || break; sleep 0.25; done
wait $DPID; QUIT=$?
check "quit with the window open exits 0" "[ $QUIT = 0 ]"
check "…with nothing crashed" "! grep -qi 'panic\|segmentation\|CRASH\|general protection' $OUT/daemon.log"
kill $(jobs -p) 2>/dev/null
exit $FAIL
