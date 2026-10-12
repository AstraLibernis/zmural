#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of a wallpaper that can't be played (Linux): a text file named
# .mp4, a file in a format nothing reads. zmural tells the user and goes back
# to the last wallpaper that played, or to its own (Prism) when nothing has;
# a monitor that had the broken file as its own follows the main wallpaper
# again. The broken file is never saved as the wallpaper. Headless Sway with
# two outputs; notifications go to a python-dbusmock daemon that records them.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/broken-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-broken-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
P=$HOME/Pictures/Wallpapers
magick -size 320x180 xc:red "$P/red.png"; magick -size 320x180 xc:green "$P/green.png"
echo "this is not a video" >"$W/fake.mp4"

export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null & SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg create_output >/dev/null; swaymsg output HEADLESS-2 resolution 1024x768 position 1280 0 >/dev/null
sleep 1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
main() { z status | head -1; }
F=$W/cfg/settings.toml
# The colour in the middle of an output.
shows() { # output number
  grim -o "HEADLESS-$1" "$W/out$1.png" 2>/dev/null || { echo none; return; }
  magick "$W/out$1.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1>200 && $2<60 && $3<60) print "red"; else if ($2>100 && $1<60 && $3<60) print "green"; else print $0 }'
}
told() { grep -c "can't show $1" "$W/notify.log"; }
up() { setsid "$BIN/zmural" "$@" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; sleep 3; }

# 1. Something played, then a broken file: back to what played.
up --apply "$P/red.png"
check "red plays first" "main | grep -q red.png && [ \"\$(shows 1)\" = red ]"
z apply "$W/fake.mp4" 2>"$W/apply.err"; rc=$?; sleep 3
check "a broken file: zmural-console apply fails, saying why (rc=$rc: $(head -c 120 "$W/apply.err"))" "[ $rc = 1 ] && grep -q \"can't show it: cannot play\" $W/apply.err"
check "a broken file: back to the last wallpaper that played" "main | grep -q red.png && [ \"\$(shows 1)\" = red ]"
check "…and the user is told what happened" "[ \$(told fake.mp4) = 1 ] && grep \"can't show fake.mp4\" $W/notify.log | grep -q 'Showing red.png again'"
check "…and the broken file isn't saved" "grep -q '^wallpaper = .*red.png' $F && ! grep -q fake.mp4 $F"

T0=$(date +%s%N); z apply "$P/green.png"; rc=$?; MS=$((($(date +%s%N) - T0) / 1000000))
check "a good file: apply exits 0 once it shows (rc=$rc, ${MS} ms)" "[ $rc = 0 ] && [ $MS -lt 3000 ] && [ \"\$(shows 1)\" = green ]"
z pause; T0=$(date +%s%N); z apply "$P/red.png"; rc=$?; MS=$((($(date +%s%N) - T0) / 1000000)); z play
check "…paused too (rc=$rc, ${MS} ms)" "[ $rc = 0 ] && [ $MS -lt 3000 ]"
z apply "$W/fake.mp4" 2>/dev/null; z apply "$W/fake.mp4" 2>/dev/null; rc=$?; sleep 2
check "…and the user isn't told again: one notification per broken file ($(told fake.mp4))" "[ \$(told fake.mp4) = 1 ]"
check "the same broken file again: fails again, after trying again (rc=$rc)" "[ $rc = 1 ] && [ \$(grep -c 'cannot play' $W/daemon.log) -ge 2 ]"
# Pictures mpv opens but can't decode a frame from: it never ends them, it
# says "No media data to loop" and tries again, several times a second.
echo "not a jpeg" >"$W/text.jpg"; : >"$W/empty.png"; magick -size 16384x16384 xc:blue "$W/huge.png"
for f in text.jpg empty.png huge.png; do
  z apply "$W/$f" 2>"$W/apply.err"; rc=$?; sleep 1
  check "a picture that can't be decoded ($f): apply fails, saying so (rc=$rc)" "[ $rc = 1 ] && grep -q 'no picture or video in it could be decoded' $W/apply.err && main | grep -q 'green.png\|red.png'"
done
# A tiny file with a huge canvas: refused once its size is known.
magick -size 10000x10000 xc:white -colors 2 "$W/canvas.gif"
z apply "$W/canvas.gif" 2>"$W/apply.err"; rc=$?; sleep 1
check "a GIF with a 10000x10000 canvas: refused as larger than a wallpaper can be (rc=$rc)" "[ $rc = 1 ] && grep -q '10000x10000 it is larger' $W/apply.err"
check "…and mpv's retries stop with the renderer" "[ \$(grep -c 'No media data' $W/daemon.log) -le 12 ]"
# A file's name can't write a line of its own into the log.
FORGE="$W/x
2026-10-12 14:30:00.000 error(daemon): FORGED.png"
cp "$P/red.png" "$FORGE"; z apply "$FORGE"; sleep 1
check "a newline in a file's name stays inside its log line" "grep -q 'x\\\\x0a2026' $W/daemon.log && ! grep -q '^2026-10-12 14:30:00.000 error(daemon): FORGED' $W/daemon.log"
z apply "$P/red.png"
# Web wallpapers are Windows-only so far: refused up front, not tried.
mkdir -p "$W/webpkg"; echo '<h1>hi</h1>' >"$W/webpkg/index.html"
printf 'title = "Page"\ntype = "web"\nentry = "index.html"\n' >"$W/webpkg/zmural.toml"
z apply "$W/webpkg/zmural.toml" 2>"$W/apply.err"; rc1=$?; z apply "$W/webpkg/index.html" 2>>"$W/apply.err"; rc2=$?
check "a web package or page on Linux: refused, saying web is Windows-only (rc $rc1 $rc2)" "[ $rc1 = 1 ] && [ $rc2 = 1 ] && [ \$(grep -c 'Windows-only' $W/apply.err) = 2 ] && ! grep -q 'started (web' $W/daemon.log"
printf 'broken for now' >"$W/fixed.mp4"; z apply "$W/fixed.mp4" 2>/dev/null; rc1=$?; sleep 2
cp "$P/green.png" "$W/fixed.mp4"; z apply "$W/fixed.mp4"; rc2=$?
check "a file fixed after it failed: applied again, it shows (rc $rc1 then $rc2)" "[ $rc1 = 1 ] && [ $rc2 = 0 ]"
z apply "$P/red.png"

# 2. A monitor's own wallpaper is broken: it follows the main one again.
T1=$(told fake.mp4); z apply "$W/fake.mp4" --monitor 2; sleep 3
check "a monitor's own broken wallpaper: it follows the main one again" "[ \"\$(shows 2)\" = red ] && ! grep -q fake.mp4 $F && z status | grep HEADLESS-2 | grep -q 'main wallpaper'"
check "…and says so" "[ \$(told fake.mp4) = $((T1 + 1)) ] && grep \"can't show fake.mp4\" $W/notify.log | tail -1 | grep -q 'That monitor shows the main wallpaper again'"
z quit; sleep 1

# 3. Nothing has played yet in this run (started straight on the broken
#    file): zmural's own wallpaper instead.
up --apply "$W/fake.mp4"; sleep 2
check "a broken file with nothing played yet: zmural's own wallpaper" "main | grep -q 'share/zmural/wallpapers/Prism.webm'"
check "…said in the notice" "grep \"can't show fake.mp4\" $W/notify.log | tail -1 | grep -q 'Showing Prism.webm instead'"
check "zmural kept running, nothing crashed" "kill -0 $ZD && ! grep -qi 'panic\|segmentation' $W/daemon.log"

# A web package saved by an older zmural: told, and zmural's own instead.
z quit; sleep 1
sed -i "s|^wallpaper = .*|wallpaper = '$W/webpkg/zmural.toml'|" "$F"
up
check "a saved web wallpaper at start: zmural's own instead, and the user is told" "main | grep -q Prism.webm && grep \"can't show webpkg\" $W/notify.log | grep -q 'Windows-only' && ! grep -q 'started (web' $W/daemon.log"

# 4. A hand edit settings.toml can't use: the user is told once, with the
#    line, and the file is left alone; told again only after it read fine.
bad() { grep -c "zmural can't use settings.toml" "$W/notify.log"; }
cp "$F" "$W/good.toml"
sed -i 's/^volume = .*/volume = "loud"/' "$F"; sleep 3
L=$(grep -n '^volume' "$F" | cut -d: -f1)
check "a value it can't use in settings.toml: the user is told, with the line" "[ \$(bad) = 1 ] && grep \"zmural can't use settings.toml\" $W/notify.log | grep -q 'line $L has a value'"
echo "# still bad" >>"$F"; sleep 3
check "…once, not at every edit while it stays bad" "[ \$(bad) = 1 ] && grep -q 'volume = \"loud\"' $F"
sed -i 's/^fill = .*/fill = "zoom"/' "$F"; sleep 3
check "…but a different mistake while it's still bad is told too" "[ \$(bad) = 2 ]"
cp "$W/good.toml" "$F"; sleep 3; sed -i 's/^volume = .*/volume = "loud"/' "$F"; sleep 3
check "…and again once it read fine and broke again" "[ \$(bad) = 3 ]"
check "…saying zmural keeps its current settings" "grep \"zmural can't use settings.toml\" $W/notify.log | tail -1 | grep -q 'keeps its current settings'"
# Bad already when zmural starts: it runs on its defaults, and says so.
z quit; sleep 1; up
check "a bad settings.toml at start: told zmural uses its defaults" "[ \$(bad) = 4 ] && grep \"zmural can't use settings.toml\" $W/notify.log | tail -1 | grep -q 'uses its defaults for now'"
cp "$W/good.toml" "$F"; sleep 3
# Settings that can't be saved: the user is told, once, and the file is
# left as the user made it.
nosave() { grep -c "zmural can't save its settings" "$W/notify.log"; }
chmod 444 "$F"; z fill fit; z fill center; sleep 3
check "a read-only settings.toml: left alone, and the user is told once ($(nosave))" "[ \$(nosave) = 1 ] && grep \"can't save its settings\" $W/notify.log | grep -q 'read-only' && [ \$(stat -c %a $F) = 444 ] && ! grep -q '^fill = \"center\"' $F"
chmod 644 "$F"; z fill crop; sleep 1
check "…saved again once it's writable" "grep -q '^fill = \"crop\"' $F"
mv "$F" "$W/cfg/real.toml"; ln -s real.toml "$F"; z fill stretch; sleep 1
check "a settings.toml that is a link: written through, the link kept" "[ -L $F ] && grep -q '^fill = \"stretch\"' $W/cfg/real.toml"
rm "$F"; mv "$W/cfg/real.toml" "$F"
z quit; sleep 1

kill $SWAY $NOTIFY 2>/dev/null; kill "$(cat "$W/session.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
