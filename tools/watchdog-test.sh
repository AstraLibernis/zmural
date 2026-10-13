#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of the frame watchdog (Linux): a renderer that stops (SIGSTOP)
# is killed and started again; a video cut short while it plays, which
# leaves mpv stuck with no error, ends its renderer, and the restart finds
# the file broken: the user is told and the last wallpaper that played comes
# back. And no false alarm: a still picture, a GIF holding one frame for
# 15 s and a paused video are left alone. Headless Sway; notifications go to
# a python-dbusmock daemon that records them.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/watchdog-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-watchdog-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Videos/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
V=$HOME/Videos/Wallpapers
clip() { ffmpeg -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -t 20 "$@"; }
clip -c:v libvpx-vp9 -b:v 1M -deadline realtime "$V/good.webm"
clip -c:v mpeg4 -q:v 5 "$V/cut.mp4"
clip -c:v libvpx-vp9 -b:v 1M -deadline realtime "$V/cut-header.webm"
magick -size 640x360 xc:red "$V/still.png"
magick -delay 1500 -size 64x64 xc:red xc:blue -loop 0 "$V/slow.gif" # each frame held 15 s

export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null & SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
sleep 1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
main() { z status | head -1; }
# Two screenshots half a second apart: does the picture change?
moving() { grim -o HEADLESS-1 "$W/s1.png"; sleep 0.5; grim -o HEADLESS-1 "$W/s2.png"; cmp -s "$W/s1.png" "$W/s2.png" && echo frozen || echo moving; }
rpid() { pgrep -f "^$BIN/zmural --renderer" | head -1; }
# Wait up to $1 seconds for a command to succeed; prints the seconds it took.
within() { local n=$1; shift; local t0=$(date +%s); for _ in $(seq $((n * 2))); do eval "$@" && { echo $(($(date +%s) - t0)); return 0; }; sleep 0.5; done; echo never; return 1; }
count() { grep -c "$1" "$W/daemon.log"; }

setsid "$BIN/zmural" --apply "$V/good.webm" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!; sleep 3
check "a video plays" "[ \"\$(moving)\" = moving ]"

# 1. A renderer that stops: SIGSTOP, as a debugger, a hung driver call or a
#    stuck library would leave it.
R=$(rpid); kill -STOP "$R"; sleep 1
check "a stopped renderer freezes the picture (the case to catch)" "[ \"\$(moving)\" = frozen ]"
s=$(within 25 "[ -n \"\$(rpid)\" ] && [ \"\$(rpid)\" != $R ] && [ \"\$(moving)\" = moving ]")
check "…it is killed and started again, and the picture moves again (${s} s; at most 5 s to the next ping, 10 s to answer, 2 s to restart)" "[ \"$s\" != never ] && [ $s -le 22 ]"
check "…the log says why" "grep -q 'no answer for 10 s (stopped or hung); starting it again' $W/daemon.log"
check "…and the stopped process is gone, not left behind" "! kill -0 $R 2>/dev/null || grep -q '^State:.*Z' /proc/$R/status"
check "…and it isn't told as a crash" "[ \$(grep -c 'ran into a problem' $W/notify.log) = 0 ]"

# 2. A video cut to nothing while it plays: mpv keeps what it read, then
#    seeks forever with no error. The renderer notices and ends; the restart
#    can't load the file; the user is told, and the last good one is back.
z apply "$V/cut.mp4"; sleep 2
check "a second video plays" "main | grep -q cut.mp4 && [ \"\$(moving)\" = moving ]"
truncate -s 0 "$V/cut.mp4"
s=$(within 60 "grep -q \"stopped playing '$V/cut.mp4'\" $W/daemon.log")
check "a video cut to nothing while it plays: the renderer says it stopped (${s} s after the cut)" "[ \"$s\" != never ]"
s=$(within 20 "main | grep -q good.webm && [ \"\$(moving)\" = moving ]")
check "…and the last wallpaper that played is back, moving (${s} s later)" "[ \"$s\" != never ]"
check "…and the user is told the file can't be shown" "grep -q \"can't show cut.mp4\" $W/notify.log"
check "…and it isn't saved as the wallpaper" "! grep -q cut.mp4 $W/cfg/settings.toml"

# 3. The same with only the file's first 4 KiB left (its header).
z apply "$V/cut-header.webm"; sleep 2
truncate -s 4096 "$V/cut-header.webm"
s=$(within 60 "main | grep -q good.webm && grep -q \"can't show cut-header.webm\" $W/notify.log")
check "a video cut to its header while it plays: told, and the last good one is back (${s} s)" "[ \"$s\" != never ] && [ \"\$(moving)\" = moving ]"

# 4. No false alarm: what plays slowly, or not at all, on purpose.
before=$(($(count 'no answer for') + $(count 'stopped playing')))
z apply "$V/still.png"; sleep 1; R=$(rpid); sleep 25
check "a still picture for 25 s: left alone" "[ \"\$(rpid)\" = $R ] && main | grep -q still.png"
z apply "$V/slow.gif"; sleep 1; R=$(rpid); sleep 25
check "a GIF holding each frame 15 s, for 25 s: left alone" "[ \"\$(rpid)\" = $R ] && main | grep -q slow.gif"
z apply "$V/good.webm"; sleep 1; R=$(rpid); z pause; sleep 25; z play; sleep 2
check "a video paused 25 s: left alone, and it moves again on play" "[ \"\$(rpid)\" = $R ] && [ \"\$(moving)\" = moving ]"
check "…no watchdog line in the log for any of them" "[ \$((\$(count 'no answer for') + \$(count 'stopped playing'))) = $before ]"

z quit >/dev/null 2>&1; sleep 1
kill $ZD $SWAY $NOTIFY 2>/dev/null; kill "$(cat "$W/session.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
