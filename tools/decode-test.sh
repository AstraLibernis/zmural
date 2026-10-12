#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of how zmural reports video decoding (Linux), on headless Sway
# with a python-dbusmock notification service: every video logs what decodes
# it, found out afresh at every start; a codec the system can't decode on the
# GPU plays on the CPU and the user is told once per codec; with nobody to
# tell, it is left for next time; a codec that reaches the GPU is forgotten.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/decode-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-decode
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SYSTEM_BUS_ADDRESS
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)

# Two seconds each. Theora and MPEG-4 have no GPU decoder on current drivers;
# VP9 usually has one.
clip() { ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -pix_fmt yuv420p "$@"; }
clip -c:v libvpx-vp9 -b:v 500k "$W/vp9.webm"
clip -c:v libtheora -q:v 6 "$W/theora.mkv"
clip -c:v mpeg4 -q:v 5 "$W/mpeg4.mkv"

setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & MOCK=$!
printf 'output HEADLESS-1 resolution 1280x720\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1

FAIL=0; ZD=
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
up() { # wallpaper
  setsid "$BIN/zmural" --apply "$1" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
  sleep 4
}
down() { kill $ZD 2>/dev/null; sleep 0.7; }
told() { grep -c "No GPU decoder for $1 found" "$W/notify.log"; }

# As if a VP9 file had played on the CPU before (another profile, another size).
printf 'cpu-decode vp9\ncpu-decode other\n' >"$W/cfg/notices"
up "$W/vp9.webm"
check "a video says what decodes it" "grep -qE 'decoding vp9 on the (GPU|CPU)' $W/daemon.log"
if grep -q 'decoding vp9 on the GPU' "$W/daemon.log"; then
  check "a video on the GPU brings no notification" "[ \$(told VP9) = 0 ]"
  check "…and its 'told' note is kept, as the notice promised: the next VP9 file may be on the CPU again" "grep -qx 'cpu-decode vp9' $W/cfg/notices && grep -qx 'cpu-decode other' $W/cfg/notices"
fi

# A picture: decoded once, and GPUs don't decode pictures. Nothing to tell.
magick -size 320x180 xc:red "$W/still.png"
"$BIN/zmural-console" apply "$W/still.png"; sleep 2.5
check "a picture says what decodes it, and brings no notification" "grep -q 'decoding png on the CPU' $W/daemon.log && [ \$(told PNG) = 0 ] && ! grep -q 'cpu-decode png' $W/cfg/notices"
"$BIN/zmural-console" apply "$W/theora.mkv"; sleep 3.5
check "a codec without a GPU decoder plays on the CPU" "grep -q 'decoding theora on the CPU' $W/daemon.log && grep -q 'first frame' $W/daemon.log"
check "…and the user is told" "[ \$(told Theora) = 1 ]"
check "…and it is remembered" "grep -qx 'cpu-decode theora' $W/cfg/notices"
"$BIN/zmural-console" apply "$W/vp9.webm"; sleep 2; "$BIN/zmural-console" apply "$W/theora.mkv"; sleep 3.5
down; up "$W/theora.mkv"
check "the same codec again, and after a restart: not told twice" "[ \$(told Theora) = 1 ] && [ \$(grep -c 'decoding theora on the CPU' $W/daemon.log) -ge 3 ]"

# Nobody to tell: not remembered, so it is said once a desktop is listening.
down; kill $MOCK 2>/dev/null; sleep 0.5
up "$W/mpeg4.mkv"
check "with no notification service it isn't marked as told" "grep -q 'decoding mpeg4 on the CPU' $W/daemon.log && ! grep -q 'cpu-decode mpeg4' $W/cfg/notices"
down
setsid python3 -m dbusmock -t notification_daemon >>"$W/notify.log" 2>&1 </dev/null & MOCK=$!
sleep 1.5
up "$W/mpeg4.mkv"
check "…and is told the next time" "[ \$(told MPEG-4) = 1 ] && grep -qx 'cpu-decode mpeg4' $W/cfg/notices"

down; kill $SWAY $MOCK 2>/dev/null
kill "$(cat "$W/session.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "logs in $W"; exit 1; }
