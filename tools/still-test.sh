#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the still-picture fallback (Linux): where nothing live can
# show, zmural sets the showing wallpaper as the desktop's own, still, through
# the XDG wallpaper portal, again when it changes, and tells the user once. A
# video becomes one of its frames. The cases: no Wayland display at all; GNOME
# before zmural's extension runs (the user's background kept, and put back by
# uninstall); a Plasma too old for zmural's plugin. The portal and the
# notification daemon are python-dbusmock stand-ins that record the calls;
# GNOME's and Plasma's programs are stand-ins on PATH.
#
#   tools/sandbox-deps.sh tests
#   zig build && tools/still-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-still-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/home/Videos/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata"; chmod 700 "$W/xdg"
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata XDG_CACHE_HOME=$W/cache
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red one.png"; magick -size 320x180 xc:green "$P/green.png"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x180:rate=30 -t 1 -pix_fmt yuv420p -c:v libvpx-vp9 "$HOME/Videos/Wallpapers/clip.webm"

export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
setsid python3 -m dbusmock --session -l "$W/portal.log" org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.Wallpaper >/dev/null 2>&1 </dev/null & PORTAL=$!
setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
sleep 1.5
gdbus call --session -d org.freedesktop.portal.Desktop -o /org/freedesktop/portal/desktop -m org.freedesktop.DBus.Mock.AddMethod \
  org.freedesktop.portal.Wallpaper SetWallpaperURI 'ssa{sv}' 'o' "ret = dbus.ObjectPath('/org/freedesktop/portal/desktop/request/1/t')" >/dev/null

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
calls() { grep -c 'SetWallpaperURI' "$W/portal.log"; }

setsid "$BIN/zmural" --apply "$P/red one.png" >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 2
check "with no Wayland display, zmural says so" "grep -q 'no Wayland display' $W/daemon.log"
check "…and sets the picture through the wallpaper portal" "[ \$(calls) = 1 ] && grep -q 'SetWallpaperURI \"\" \"file://$P/red%20one.png\"' $W/portal.log"
check "…asking for the background, without a preview" "grep 'SetWallpaperURI' $W/portal.log | grep -q \"set-on.*background\" && grep 'SetWallpaperURI' $W/portal.log | grep -q 'show-preview.*False'"
check "the user is told once" "[ \$(grep -c \"can't show live wallpapers here\" $W/notify.log) = 1 ]"

"$BIN/zmural-console" apply "$P/green.png"; sleep 1
check "a new picture is set again" "[ \$(calls) = 2 ] && grep -q 'green.png' $W/portal.log"
check "…without telling again" "[ \$(grep -c \"can't show live wallpapers here\" $W/notify.log) = 1 ]"

"$BIN/zmural-console" apply "$HOME/Videos/Wallpapers/clip.webm"; sleep 3
check "a video: one of its frames is made and set" "[ \$(calls) = 3 ] && grep 'SetWallpaperURI' $W/portal.log | tail -1 | grep -q 'file://$W/cache/zmural/stills/[0-9a-f]*.png'"
check "…a real picture, from the video" "[ \"\$(file -b --mime-type $W/cache/zmural/stills/*.png)\" = image/png ]"
"$BIN/zmural-console" apply "$P/green.png"; sleep 1
"$BIN/zmural-console" apply "$HOME/Videos/Wallpapers/clip.webm"; sleep 1
check "…made once: the second time it comes from the cache" "[ \$(calls) = 5 ] && [ \$(grep -c 'making a picture of' $W/daemon.log) = 1 ]"

"$BIN/zmural-console" quit; sleep 0.5

# Desktops where zmural's own plugin or extension can't show anything yet get
# the still too. Their programs are stand-ins on PATH that record their calls.
S=$W/stubs; mkdir -p "$S"
cat >"$S/gsettings" <<EOS
#!/bin/sh
echo "gsettings \$*" >>"$W/stubs.log"
case "\$*" in
  "get org.gnome.shell enabled-extensions") echo "['org.zmural.gnome@zmural']" ;;
  "get org.gnome.desktop.background picture-uri") echo "'file:///usr/share/backgrounds/mine.png'" ;;
  "get org.gnome.desktop.background picture-uri-dark") echo "'file:///usr/share/backgrounds/mine-dark.png'" ;;
esac
EOS
cat >"$S/gnome-shell" <<EOS
#!/bin/sh
echo "GNOME Shell 50.1"
EOS
cat >"$S/gnome-extensions" <<EOS
#!/bin/sh
echo "gnome-extensions \$*" >>"$W/stubs.log"
case "\$1" in info) echo "  Enabled: Yes"; echo "  State: INITIALIZED" ;; esac
EOS
cat >"$S/plasmashell" <<EOS
#!/bin/sh
echo "plasmashell 5.27.11"
EOS
chmod +x "$S"/*

# GNOME, the extension just installed: GNOME starts it at the next login.
PATH=$S:$PATH XDG_CURRENT_DESKTOP=GNOME setsid "$BIN/zmural" --apply "$P/red one.png" >"$W/gnome.log" 2>&1 </dev/null & ZD=$!
sleep 3
check "GNOME before its extension runs: the still is set" "[ \$(calls) = 6 ] && grep 'SetWallpaperURI' $W/portal.log | tail -1 | grep -q 'red%20one.png'"
check "…the user's own background kept first" "grep -q \"picture-uri='file:///usr/share/backgrounds/mine.png'\" $W/cfg/gnome-background && grep -q 'picture-uri-dark=' $W/cfg/gnome-background"
check "…and told to log in again, not that live wallpapers can't show" "grep -q 'Log out and back in' $W/notify.log && [ \$(grep -c \"can't show live wallpapers here\" $W/notify.log) = 1 ]"
# Uninstall gives the user's background back.
PATH=$S:$PATH XDG_CURRENT_DESKTOP=GNOME "$BIN/zmural" --uninstall >"$W/uninstall.log" 2>&1
check "uninstall puts the user's GNOME background back" "grep -q \"gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/backgrounds/mine.png'\" $W/stubs.log && grep -q \"picture-uri-dark 'file:///usr/share/backgrounds/mine-dark.png'\" $W/stubs.log && grep -q 'your own background is back' $W/uninstall.log"
check "…and removes the still pictures" "[ ! -e $W/cache/zmural ]"
for _ in $(seq 30); do kill -0 $ZD 2>/dev/null || break; sleep 0.1; done

# KDE Plasma 5: zmural's plugin can't run there, so the still is set (no
# plugin to switch away from).
mkdir -p "$W/cfg"
PATH=$S:$PATH XDG_CURRENT_DESKTOP=KDE setsid "$BIN/zmural" --apply "$P/green.png" >"$W/kde.log" 2>&1 </dev/null & ZD=$!
sleep 3
check "Plasma 5: the still is set, and the user told what Plasma zmural needs" "[ \$(calls) = 7 ] && grep 'SetWallpaperURI' $W/portal.log | tail -1 | grep -q green.png && grep -q 'This desktop has Plasma 5.27' $W/notify.log"
"$BIN/zmural-console" quit; sleep 0.5
kill $PORTAL $NOTIFY $(cat "$W/session.pid") 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
