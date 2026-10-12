#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of zmural's system facts (daemon/facts_linux.zig) on headless
# Sway, against python-dbusmock stand-ins for UPower, power-profiles-daemon,
# logind (on a private bus posing as the system bus), KDE's ScreenSaver and
# GameMode. Each fact is turned on and off; the renderer must pause and resume.
# Then a stalled service must leave the main loop responsive.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/facts-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-facts
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin"; chmod 700 "$W/xdg"
# sway carries cap_sys_nice; a container may not allow it, so run a cap-free copy.
cp "$(command -v sway)" "$W/bin/sway-nocap"
# zmural writes autostart, launcher and plugins under XDG_*_HOME: keep them out of $HOME.
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/session.pid" | head -1)
export DBUS_SYSTEM_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/system.pid" | head -1)

MOCKS=()
mock() { setsid python3 -m dbusmock "$@" >>"$W/mock.log" 2>&1 </dev/null & MOCKS+=($!); }
mock --system org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower
mock --system org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles
mock --system org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager
mock org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver
mock com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode
sleep 1.5

g() { gdbus call "$@" >/dev/null || echo "gdbus failed: $*"; }
MOCK=org.freedesktop.DBus.Mock
UP=(org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower)
PP=(org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles)
LS=(org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session)
SS=(org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver)
GM=(com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode)
g --system -d ${UP[0]} -o ${UP[1]} -m $MOCK.AddProperty ${UP[2]} OnBattery '<false>'
g --system -d ${PP[0]} -o ${PP[1]} -m $MOCK.AddProperty ${PP[2]} ActiveProfile "<'balanced'>"
g --system -d org.freedesktop.login1 -o /org/freedesktop/login1 -m $MOCK.AddObject ${LS[1]} ${LS[2]} "{'LockedHint': <false>, 'Active': <true>, 'Remote': <false>}" '[]'
g --session -d ${SS[0]} -o ${SS[1]} -m $MOCK.AddMethod ${SS[2]} GetActive '' b 'ret = getattr(self, "active", False)'
g --session -d ${SS[0]} -o ${SS[1]} -m $MOCK.AddMethod '' SetActive b '' 'self.active = args[0]'
g --session -d ${GM[0]} -o ${GM[1]} -m $MOCK.AddProperty ${GM[2]} ClientCount '<0>'

printf 'output HEADLESS-1 resolution 1280x720\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1
setsid "$BIN/zmural" --apply test-pattern >"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 0.5
sleep 3

set_prop() { # bus, dest, path, iface, name, value
  g --$1 -d $2 -o $3 -m org.freedesktop.DBus.Properties.Set $4 $5 "$6"
}
FAIL=0
# Turns a fact on, then off; the daemon log must show it begin and end, and
# the renderer pause and resume.
check() { # name, fact, on command, off command
  local n0 on off
  n0=$(wc -l <"$W/daemon.log"); eval "$3"; sleep 2.5
  on=$(tail -n +$((n0 + 1)) "$W/daemon.log")
  n0=$(wc -l <"$W/daemon.log"); eval "$4"; sleep 3
  off=$(tail -n +$((n0 + 1)) "$W/daemon.log")
  if grep -q "system: $2 began" <<<"$on" && grep -q -- "-> pause" <<<"$on" &&
     grep -q "system: $2 ended" <<<"$off" && grep -q "pause -> none" <<<"$off"; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  on:  $(grep -E 'system:|renderer' <<<"$on" | tr '\n' ' ')"; echo "  off: $(grep -E 'system:|renderer' <<<"$off" | tr '\n' ' ')"; FAIL=1
  fi
}
check "on battery"        on_battery       "set_prop system ${UP[*]} OnBattery '<true>'"                "set_prop system ${UP[*]} OnBattery '<false>'"
check "power saver"       power_saver      "set_prop system ${PP[*]} ActiveProfile \"<'power-saver'>\"" "set_prop system ${PP[*]} ActiveProfile \"<'balanced'>\""
check "logind LockedHint" session_locked   "set_prop system ${LS[*]} LockedHint '<true>'"               "set_prop system ${LS[*]} LockedHint '<false>'"
check "KDE locker"        session_locked   "g --session -d ${SS[0]} -o ${SS[1]} -m ${SS[2]}.SetActive true" "g --session -d ${SS[0]} -o ${SS[1]} -m ${SS[2]}.SetActive false"
check "session inactive"  session_inactive "set_prop system ${LS[*]} Active '<false>'"                  "set_prop system ${LS[*]} Active '<true>'"
check "remote session"    remote_session   "set_prop system ${LS[*]} Remote '<true>'"                   "set_prop system ${LS[*]} Remote '<false>'"
check "GameMode"          game_mode        "set_prop session ${GM[*]} ClientCount '<1>'"                "set_prop session ${GM[*]} ClientCount '<0>'"

# A service that stalls must not stall the main loop (it forwards every frame).
g --session -d ${SS[0]} -o ${SS[1]} -m $MOCK.AddMethod ${SS[2]} GetActive '' b 'import time; time.sleep(30); ret = False'
sleep 1.5
worst=0
for _ in 1 2 3 4 5; do
  s=$(date +%s%N); "$BIN/zmural-console" status >/dev/null; e=$(date +%s%N)
  ms=$(((e - s) / 1000000)); [ $ms -gt $worst ] && worst=$ms; sleep 0.5
done
if [ $worst -lt 200 ]; then echo "ok   stalled service: status answers in ${worst} ms at worst"; else echo "FAIL stalled service: status took ${worst} ms"; FAIL=1; fi

kill $ZD $SWAY "${MOCKS[@]}" 2>/dev/null
kill "$(cat "$W/session.pid")" "$(cat "$W/system.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "logs in $W"; exit 1; }
