#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Soak test (Linux): a day of use squeezed into rounds, on a headless Sway with
# two outputs, a session bus and swaybar's tray, as a user's desktop has.
# Each round switches wallpapers (video, picture, GIF, a broken file), steps
# next/previous, cycles fill modes, gives a monitor its own wallpaper and
# takes it back, pauses, mutes, adjusts and resets, opens and closes the
# settings window, edits settings.toml by hand, imports a zip, unplugs and
# replugs a monitor, and every few rounds kills a renderer the hard way.
# After each round it samples zmural (memory, open files, threads) and its
# processes; at the end it judges the trend once the first rounds have warmed
# up, and checks zmural quit cleanly.
#
#   tools/sandbox-deps.sh rigs tests   (and mako, for notifications)
#   zig build -Doptimize=ReleaseSafe && tools/soak-test.sh [rounds]   # default 30, ~10 min
#   SOAK_BIN=<extracted release>/bin tools/soak-test.sh               # a release as users get it
#   tools/soak-test.sh --judge <samples.csv>                          # only the verdict
#
# Memory is judged on a release build (Debug memory isn't what users get);
# a Debug build adds its allocator's leak report at quit, which fails the test.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# The verdict, from the samples alone, so it can be checked on made-up data.
# Columns: round,seconds,rss_kb,fds,threads,processes,all_rss_kb,answered
judge() { # samples.csv -> prints the verdict lines, exits 1 on a failure
  awk -F, '
    NR == 1 { next }
    { n++; rss[n] = $3; fds[n] = $4; thr[n] = $5; procs[n] = $6; all[n] = $7; if ($8 != 1) unanswered++ }
    function med3(a, i,   x, y, z) { x = a[i-2]; y = a[i-1]; z = a[i]
      return (x <= y) ? ((y <= z) ? y : ((x <= z) ? z : x)) : ((x <= z) ? x : ((y <= z) ? z : y)) }
    function maxr(a, from, to,   i, m) { m = a[from]; for (i = from; i <= to; i++) if (a[i] > m) m = a[i]; return m }
    END {
      fail = 0
      if (n < 8) { print "FAIL too few rounds to judge (" n "; at least 8)"; exit 1 }
      w = int(n / 4); if (w < 3) w = 3
      base = med3(rss, w); last = med3(rss, n); per = (last - base) / (n - w)
      abase = med3(all, w); alast = med3(all, n)
      if (n < 20) {
        printf "--   memory not judged: %d rounds cannot tell warming up from growing (20 at least); zmural %d -> %d kB, all of it %d -> %d kB\n", n, base, last, abase, alast
      } else {
        ok = (last - base <= 8192 && per <= 100)
        printf "%s zmural memory after warm-up (round %d): %d kB -> %d kB at the end (%+d kB, %+.0f kB a round; allowed 8 MB and 100 kB a round)\n", ok ? "ok  " : "FAIL", w, base, last, last - base, per; fail += !ok
        ok = (alast - abase <= 32768)
        printf "%s all of zmural (renderers, display host): %d kB -> %d kB (%+d kB; allowed 32 MB)\n", ok ? "ok  " : "FAIL", abase, alast, alast - abase; fail += !ok
      }
      fb = maxr(fds, 1, w); fe = maxr(fds, n - 2, n); ok = (fe <= fb + 2)
      printf "%s open files: at most %d while warming up, %d at the end (allowed +2)\n", ok ? "ok  " : "FAIL", fb, fe; fail += !ok
      tb = maxr(thr, 1, w); te = maxr(thr, n - 2, n); ok = (te <= tb + 2)
      printf "%s threads: at most %d while warming up, %d at the end (allowed +2)\n", ok ? "ok  " : "FAIL", tb, te; fail += !ok
      pb = maxr(procs, 1, w); pe = maxr(procs, n - 2, n); ok = (pe <= pb)
      printf "%s processes: at most %d while warming up, %d at the end\n", ok ? "ok  " : "FAIL", pb, pe; fail += !ok
      ok = (unanswered == 0)
      printf "%s zmural answered after every round (%d of %d)\n", ok ? "ok  " : "FAIL", n - unanswered, n; fail += !ok
      exit fail > 0
    }' "$1"
}
if [ "${1:-}" = --judge ]; then judge "$2"; exit; fi

ROUNDS=${1:-30}
BIN=${SOAK_BIN:-$ROOT/zig-out/bin}
W=${TMPDIR:-/tmp}/zmural-soak
for p in $(pgrep -f "^$W/" 2>/dev/null); do kill "$p" 2>/dev/null; done
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Videos/Wallpapers" "$W/home/Pictures/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin" "$W/zips"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/bus.pid" | head -1)

V=$HOME/Videos/Wallpapers P=$HOME/Pictures/Wallpapers
ffmpeg -v error -f lavfi -i testsrc2=size=640x360:rate=30 -t 4 -c:v libvpx-vp9 -b:v 300k "$V/clip.webm"
ffmpeg -v error -f lavfi -i mandelbrot=size=640x360:rate=30 -t 4 -c:v libvpx -b:v 300k "$V/fractal.webm"
ffmpeg -v error -f lavfi -i testsrc=size=320x180:rate=10 -t 2 "$P/moving.gif"
for c in red green blue; do magick -size 640x360 "xc:$c" "$P/$c.png"; done
printf 'not a video' >"$W/broken.mp4"
(cd "$P" && zip -q "$W/zips/pack.zip" red.png green.png)

cat >"$W/sway.conf" <<EOF
output HEADLESS-1 resolution 1280x720 position 0 0
bar {
  tray_output *
  status_command while true; do sleep 60; done
}
exec mako
EOF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
[ -e "$W/xdg/wayland-1" ] || { echo "Sway didn't start (see $W/sway.log); a long \$TMPDIR can make its socket path too long"; exit 1; }
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg -q create_output; swaymsg -q output HEADLESS-2 resolution 1024x768 position 1280 0
SECOND=HEADLESS-2

L=$W/daemon.log
setsid "$BIN/zmural" --apply "$V/clip.webm" >"$L" 2>&1 </dev/null & ZD=$!
sleep 4
# Every command must be accepted; a refused one is noted with its error.
z() { timeout 10 "$BIN/zmural-console" "$@" >"$W/cli.out" 2>&1 || { echo "round $r: zmural-console $* -> $(tail -1 "$W/cli.out")" >>"$W/refused.log"; }; }
r=0
alive() { kill -0 "$ZD" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$ZD/status" 2>/dev/null; }
procs() { pgrep -f "^$BIN/zmural( |$)" | while read -r p; do grep -q '^State:.*Z' "/proc/$p/status" 2>/dev/null || echo "$p"; done; }
renderers() { pgrep -f "^$BIN/zmural --renderer"; }
FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
check "zmural is up on two outputs" "alive && timeout 10 $BIN/zmural-console status | grep -c 'HEADLESS-[12]' | grep -q 2"

S=$W/samples.csv
echo "round,seconds,rss_kb,fds,threads,processes,all_rss_kb,answered" >"$S"
START=$(date +%s)
sample() { # round
  local rss fds thr all=0 n=0 ans=0
  rss=$(awk '/^VmRSS/ {print $2}' "/proc/$ZD/status" 2>/dev/null)
  fds=$(ls "/proc/$ZD/fd" 2>/dev/null | wc -l)
  thr=$(awk '/^Threads/ {print $2}' "/proc/$ZD/status" 2>/dev/null)
  for p in $(procs); do all=$((all + $(awk '/^VmRSS/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0))); n=$((n + 1)); done
  timeout 10 "$BIN/zmural-console" status >/dev/null 2>&1 && ans=1
  echo "$1,$(($(date +%s) - START)),${rss:-0},$fds,${thr:-0},$n,$all,$ans" >>"$S"
}

step() { sleep "${1:-1.2}"; }
for r in $(seq 1 "$ROUNDS"); do
  alive || { echo "FAIL zmural is gone in round $r"; FAIL=1; break; }
  z apply "$V/fractal.webm"; step
  z apply "$P/moving.gif"; step
  z apply "$P/red.png"; step
  z next; step; z previous; step
  for f in fit stretch center crop; do z fill "$f"; step 0.4; done
  z apply "$P/green.png" --monitor 2; step; z fill fit --monitor 2; step 0.4
  z fill default --monitor 2; z follow --monitor 2; step
  z apply "$V/clip.webm"; step
  z pause; step 0.6; z play; z mute; z unmute; step 0.6
  z prop brightness -30; z prop speed 1.5; step 0.6; z prop --reset; step 0.6
  timeout 10 "$BIN/zmural" --settings >/dev/null 2>&1; step 1.5
  swaymsg -q '[app_id="org.zmural.Settings"] kill'; step
  z apply "$W/broken.mp4"; step 2
  sed -i "s/^volume = .*/volume = $((r % 100))/" "$W/cfg/settings.toml"; step 2.5
  z import "$W/zips/pack.zip" --to "$P"; z rescan; step
  rm -rf "$P"/pack*; z rescan
  # A monitor unplugged and back (a new output, as when a cable is replugged).
  swaymsg -q output "$SECOND" unplug 2>/dev/null || swaymsg -q output "$SECOND" disable; step 2
  swaymsg -q create_output; SECOND=$(swaymsg -t get_outputs | grep -o '"name": "HEADLESS-[0-9]*"' | tail -1 | grep -o 'HEADLESS-[0-9]*')
  swaymsg -q output "$SECOND" resolution 1024x768 position 1280 0; step 2.5
  if [ $((r % 5)) = 0 ]; then kill -9 $(renderers | head -1) 2>/dev/null; step 4; fi
  sample "$r"
  echo "round $r/$ROUNDS: $(tail -1 "$S")"
done

echo
judge "$S" || FAIL=1
check "every command was accepted$( [ -s "$W/refused.log" ] && printf '\n%s' "$(head -5 "$W/refused.log")")" "[ ! -s $W/refused.log ]"
check "no crash in the log" "! grep -q 'CRASH' $L"
check "every renderer killed on purpose was restarted ($(grep -c 'renderer .*: started' $L) starts)" "[ \$(renderers | wc -l) -ge 1 ]"
timeout 15 "$BIN/zmural-console" quit >/dev/null 2>&1
for _ in $(seq 30); do alive || break; sleep 0.5; done
wait "$ZD" 2>/dev/null; rc=$?
check "it quits cleanly at the end (rc=$rc)" "[ $rc = 0 ]"
check "…leaving no zmural process behind" "[ -z \"\$(procs)\" ]"
check "…and no leak reported (a Debug build's allocator)" "! grep -qi 'leak' $L"
kill "$SWAY" "$(cat "$W/bus.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed; samples in $S" || { echo "FAILED; samples in $S, log in $L"; exit 1; }
