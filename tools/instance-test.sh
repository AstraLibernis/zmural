#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# zmural (Linux): one instance per session, takeover of a hung or outdated
# one, never killing a stranger, the CLI, and the start-at-login switch.
# Everything runs in temporary directories; no display is needed.
#
#   tools/instance-test.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
(cd "$ROOT" && zig build) || exit 1
B=$ROOT/zig-out/bin
# A short runtime dir: socket paths must fit in 108 bytes.
R=$(mktemp -d /tmp/zmit-XXXX); chmod 700 $R
T=$(mktemp -d); mkdir -p $T/cfg $T/xdgcfg
trap 'pkill -f "^$B/zmural( |\$)" 2>/dev/null; rm -rf $R $T' EXIT
S=$T; printf 'not really a png' > $S/still.png
# zmural writes autostart, launcher and plugins under these: keep them out of $HOME.
export XDG_RUNTIME_DIR=$R ZMURAL_CONFIG_DIR=$T/cfg XDG_CONFIG_HOME=$T/xdgcfg XDG_DATA_HOME=$T/xdgdata
unset DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
ENTRY=$T/xdgcfg/autostart/zmural.desktop
pass=0; failn=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; failn=$((failn+1)); fi; }
alive() { kill -0 $1 2>/dev/null && ! grep -q '^State:.*Z' /proc/$1/status 2>/dev/null; }
wait_sock() { for i in $(seq 40); do [ -S $R/zmural/control.sock ] && return; sleep 0.1; done; }
start() { setsid $B/zmural "$@" > $T/$LOG 2>&1 < /dev/null & echo $!; }

# zmural needs a GPU render node. Without one (a CI runner, a bare VM) the
# only thing to check is that it says so and exits instead of crashing.
norender() { # command prefix...
  "$@" timeout 10 $B/zmural > $T/nr.log 2>&1; rc=$?
  check "without a GPU node zmural refuses with a message (rc=$rc)" "[ $rc = 2 ] && grep -q 'no GPU render node' $T/nr.log"
}
if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
  echo "no DRM render node here: zmural can't run, so only its refusal is checked"
  norender
  echo; echo "$pass passed, $failn failed"
  [ $failn = 0 ]; exit
fi

# 1. First run: starts, turns start-at-login on.
LOG=a1.log; A=$(start --apply test-pattern); wait_sock
check "first zmural is running" "alive $A"
check "start at login was turned on" "grep -q '^Hidden=false' $ENTRY && grep -q 'Exec=\"$B/zmural\"' $ENTRY"

# 2. A second one of the same version exits and leaves the first alone.
LOG=b2.log; timeout 10 $B/zmural > $T/b2.log 2>&1; rc=$?
check "second zmural exits cleanly (rc=$rc)" "[ $rc = 0 ] && grep -q 'already running' $T/b2.log"
check "first one still runs" "alive $A"

# 3. A second one with --apply hands the wallpaper over.
timeout 10 $B/zmural --apply $S/still.png > $T/b3.log 2>&1
check "--apply handed to the running zmural" "grep -q 'handed it' $T/b3.log && grep -q 'wallpaper: $S/still.png' $T/a1.log"

# 4. The CLI.
check "zmural-console status shows the wallpaper" "$B/zmural-console status | grep -q still.png"
$B/zmural-console pause; check "zmural-console pause" "$B/zmural-console status | grep -q 'paused    : yes'"
$B/zmural-console play;  check "zmural-console play" "$B/zmural-console status | grep -q 'paused    : no'"
$B/zmural-console apply definitely-missing.mp4 2>/dev/null; rc=$?
check "zmural-console apply of a missing file is refused (rc=$rc)" "[ $rc = 1 ]"
# A web address is never a wallpaper.
$B/zmural-console apply https://example.com 2> $T/url.log; rc=$?
check "zmural-console apply of a web address is refused, and says why (rc=$rc)" "[ $rc = 1 ] && grep -q \"doesn't show web addresses\" $T/url.log"
check "the wallpaper is still the picture" "$B/zmural-console status | grep -q still.png && ! $B/zmural-console status | grep -qi 'http'"

# 5. autostart off is remembered across restarts.
$B/zmural-console autostart off > /dev/null
check "autostart off writes Hidden=true" "grep -q '^Hidden=true' $ENTRY"
$B/zmural-console quit; sleep 0.5
check "zmural-console quit stops it" "! alive $A"
LOG=a5.log; A=$(start); wait_sock
check "restart without --apply restores the wallpaper" "$B/zmural-console status | grep -q still.png"
check "restart leaves start-at-login off" "grep -q '^Hidden=true' $ENTRY && grep -q 'start at login is off' $T/a5.log"
check "zmural-console autostart status says off" "$B/zmural-console autostart status | grep -q '^off'"
$B/zmural-console autostart on > /dev/null
check "autostart on writes Hidden=false" "grep -q '^Hidden=false' $ENTRY"

# 6. A hung zmural is stopped and replaced.
kill -STOP $A
LOG=b6.log; t0=$(date +%s.%N); Bpid=$(start); wait_sock; sleep 4.5
check "hung zmural was killed" "! alive $A"
check "new zmural took over" "alive $Bpid && $B/zmural-console status > /dev/null"
check "…and said why" "grep -q \"isn't answering\" $T/b6.log"
A=$Bpid

# 7. An upgrade: a running older version is asked to quit and replaced.
$B/zmural-console quit; sleep 0.5
LOG=a7.log; A=$(ZMURAL_REPORT_VERSION=0.0.9 start); wait_sock
LOG=b7.log; Bpid=$(start); sleep 2
check "older zmural quit on request" "! alive $A && grep -q 'asked to quit' $T/a7.log"
check "newer zmural runs" "alive $Bpid && grep -q 'replacing it with' $T/b7.log"
$B/zmural-console quit; sleep 0.5

# 8. Something else holding the socket (hung, not zmural) is never killed.
python3 - $R/zmural/control.sock > /dev/null 2>&1 <<'PY' &
import socket, sys, os, time
p = sys.argv[1]
if os.path.exists(p): os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.bind(p); s.listen(4)
c, _ = s.accept(); time.sleep(30)
PY
IMPOSTER=$!; sleep 0.5
timeout 15 $B/zmural > $T/b8.log 2>&1; rc=$?
check "an impostor on the socket is not killed" "alive $IMPOSTER"
check "zmural refuses to start instead (rc=$rc)" "[ $rc != 0 ] && grep -q \"isn't zmural\" $T/b8.log"
kill $IMPOSTER 2>/dev/null

# 9. settings.toml edited by hand while zmural runs is picked up, not overwritten.
pkill -f "^$B/zmural( |\$)" 2>/dev/null; sleep 0.5
LOG=a9.log; A=$(start); for i in $(seq 40); do $B/zmural-console status >/dev/null 2>&1 && break; sleep 0.1; done
F=$T/cfg/settings.toml
$B/zmural-console play; $B/zmural-console unmute; sleep 1.2
sed -i 's/^paused = false/paused = true/; s/^volume = .*/volume = 37/; s/^every_minutes = .*/every_minutes = 12/' $F; sleep 2.2
check "a hand edit is picked up within two seconds" "$B/zmural-console status | grep -q 'paused    : yes' && grep -q 'reloaded .* after an outside edit' $T/a9.log"
$B/zmural-console mute; sleep 0.3
check "…and the next save keeps the edit" "grep -q '^volume = 37' $F && grep -q '^every_minutes = 12' $F && grep -q '^muted = true' $F"
cp $F $T/good.toml; printf 'volume = "loud\n' >> $F; sleep 2.2
$B/zmural-console unmute; sleep 0.3
check "a file with a mistake is left alone, and zmural keeps running" "alive $A && tail -1 $F | grep -q loud && $B/zmural-console status | grep -q 'paused    : yes'"
cp $T/good.toml $F; sleep 2.2
$B/zmural-console play; sleep 0.3
check "once fixed it is read and saved again" "grep -q 'reads fine again' $T/a9.log && grep -q '^paused = false' $F"

# 10. A desktop that renamed the Videos and Pictures folders (xdg-user-dirs):
#     their Wallpapers folders are the ones scanned.
pkill -f "^$B/zmural( |\$)" 2>/dev/null; sleep 0.5; rm -f $R/zmural/*.sock
H=$T/home; mkdir -p "$H/Vidéos/Wallpapers" "$H/Bilder/Wallpapers" "$H/Videos/Wallpapers"
printf 'x' > "$H/Vidéos/Wallpapers/a.webm"; printf 'x' > "$H/Bilder/Wallpapers/b.png"; printf 'x' > "$H/Videos/Wallpapers/not-this.webm"
printf '# xdg-user-dirs\nXDG_VIDEOS_DIR="$HOME/Vidéos"\nXDG_PICTURES_DIR="$HOME/Bilder"\n' > $T/xdgcfg/user-dirs.dirs
LOG=a10.log; A=$(HOME=$H start --apply test-pattern); wait_sock
# Three: a.webm, b.png and zmural's own (Prism), not not-this.webm.
check "renamed Videos and Pictures folders are scanned" "grep -q \"always scanning $H/Vidéos/Wallpapers and $H/Bilder/Wallpapers\" $T/a10.log && $B/zmural-console status | grep -q 'library   : 3 wallpapers'"
pkill -f "^$B/zmural( |\$)" 2>/dev/null; sleep 0.5; rm -f $R/zmural/*.sock $T/xdgcfg/user-dirs.dirs

# 11. The same refusal, with the render nodes hidden.
command -v bwrap >/dev/null && norender bwrap --dev-bind / / --tmpfs /dev/dri

echo; echo "$pass passed, $failn failed"
[ $failn = 0 ]
