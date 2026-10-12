#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Linux desktop test matrix: starts each compositor headless (or nested in a
# headless sway), runs zmural's test pattern on it, and saves a screenshot.
#
#   tools/linux-matrix.sh --install        # tools/sandbox-deps.sh rigs (as a sudoer)
#   tools/linux-matrix.sh [desktop...]     # default: all of them
#
# Desktops: sway labwc wayfire river niri cosmic kwin plasma mutter
# Output: zig-out/matrix/<desktop>.png and <desktop>*.log, plus a summary.
#
# Notes from getting each one to run in a container without systemd:
# - sway and kwin_wayland carry cap_sys_nice file capabilities; if that
#   capability isn't allowed, exec fails, so cap-free copies are used. KWin
#   only loads its own Qt platform plugin when the executable's name ends in
#   "kwin_wayland", so its copy keeps that name.
# - niri and cosmic-comp have no headless switch: they run nested, as a
#   window in the headless sway, and the sway output is screenshotted.
# - river 0.4 closes layer surfaces unless a window manager handles
#   river_layer_shell_v1; with no window manager the result is inconclusive.
# - plasma: plasmashell needs kactivitymanagerd (systemd starts it on a real
#   login) and draws its own wallpaper over zmural: that is the expected
#   result until the KDE plugin exists.
# - mutter stands in for GNOME: gnome-shell needs logind, which a container
#   lacks. It has no layer-shell, so zmural's host refusing to start is the
#   expected result.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/zig-out/bin
OUT=$ROOT/zig-out/matrix
WORK=${TMPDIR:-/tmp}/zmural-matrix
mkdir -p "$OUT" "$WORK"

if [ "${1:-}" = --install ]; then
  exec "$ROOT/tools/sandbox-deps.sh" rigs # the one package list
fi

wait_for() { for _ in $(seq 60); do [ -e "$1" ] && return 0; sleep 0.25; done; return 1; }
nocap() { # a copy of $1 without file capabilities, named $2
  local dst=$WORK/bin/$2; mkdir -p "$WORK/bin"
  [ -x "$dst" ] || cp "$(command -v "$1")" "$dst"; echo "$dst"
}
rundir() { local r=$WORK/xdg-$1; rm -rf "$r"; mkdir -p "$r"; chmod 700 "$r"; echo "$r"; }
globals() { wayland-info 2>/dev/null | grep -o "interface: '[^']*" | sed "s/interface: '//"; }
has() { grep -qx "$1" <<<"$G" && echo yes || echo no; }

# Starts zmural (which starts its own layer-shell host) against $WAYLAND_DISPLAY; sets $FRAMES.
zmural_on() {
  local d=$1
  # zmural writes autostart, launcher and plugins under XDG_*_HOME: keep them out of $HOME.
  ZMURAL_CONFIG_DIR=$WORK/cfg-$d XDG_CONFIG_HOME=$WORK/xdgcfg-$d XDG_DATA_HOME=$WORK/xdgdata-$d setsid "$BIN/zmural" --apply test-pattern >"$OUT/$d-daemon.log" 2>&1 </dev/null &
  ZD=$!; sleep 3.5
  FRAMES=$(grep -c 'first frame' "$OUT/$d-daemon.log")
}
zmural_off() { kill "$ZD" 2>/dev/null; sleep 0.5; }

report() { # desktop verdict details
  printf '%-8s %-13s %s\n' "$1" "$2" "$3" | tee -a "$OUT/summary.txt"
}

OUTER=""   # the headless sway, for nested compositors
start_outer() {
  [ -n "$OUTER" ] && return
  local r; r=$(rundir outer)
  printf 'output HEADLESS-1 resolution 1280x720\n' >"$WORK/sway.conf"
  XDG_RUNTIME_DIR=$r WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 \
    setsid "$(nocap sway sway)" -c "$WORK/sway.conf" >"$OUT/outer-sway.log" 2>&1 </dev/null &
  wait_for "$r/wayland-1" && OUTER=$r
}

wlroots() { # desktop cmd...
  local d=$1; shift
  local r; r=$(rundir "$d")
  export XDG_RUNTIME_DIR=$r WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2
  unset WAYLAND_DISPLAY DISPLAY
  setsid "$@" >"$OUT/$d-compositor.log" 2>&1 </dev/null &
  local c=$!
  if ! wait_for "$r/wayland-1" && ! wait_for "$r/wayland-0"; then report "$d" "no-start" "see $d-compositor.log"; kill $c; return; fi
  export WAYLAND_DISPLAY=$(ls "$r" | grep -E '^wayland-[0-9]+$' | head -1)
  G=$(globals)
  zmural_on "$d"; grim "$OUT/$d.png" 2>/dev/null; zmural_off
  kill $c 2>/dev/null
  report "$d" "$([ "$FRAMES" -gt 0 ] && echo shows || echo NOT-SHOWN)" "layer_shell=$(has zwlr_layer_shell_v1) single_pixel=$(has wp_single_pixel_buffer_manager_v1) foreign_toplevel=$(has zwlr_foreign_toplevel_manager_v1)"
}

nested() { # desktop cmd...
  local d=$1; shift
  start_outer || { report "$d" "no-start" "outer sway failed"; return; }
  local r; r=$(rundir "$d")
  ln -sf "$OUTER/wayland-1" "$r/outer"
  export XDG_RUNTIME_DIR=$r WAYLAND_DISPLAY=$r/outer; unset WLR_BACKENDS DISPLAY
  setsid "$@" >"$OUT/$d-compositor.log" 2>&1 </dev/null &
  local c=$!
  sleep 1
  local s; s=$(ls "$r" | grep -E '^wayland-[0-9]+$' | head -1)
  [ -z "$s" ] && { sleep 3; s=$(ls "$r" | grep -E '^wayland-[0-9]+$' | head -1); }
  [ -z "$s" ] && { report "$d" "no-start" "see $d-compositor.log"; kill $c; return; }
  export WAYLAND_DISPLAY=$s
  G=$(globals)
  zmural_on "$d"
  XDG_RUNTIME_DIR=$OUTER WAYLAND_DISPLAY=wayland-1 grim "$OUT/$d.png" 2>/dev/null
  zmural_off; kill $c 2>/dev/null
  report "$d" "$([ "$FRAMES" -gt 0 ] && echo shows || echo NOT-SHOWN)" "layer_shell=$(has zwlr_layer_shell_v1) single_pixel=$(has wp_single_pixel_buffer_manager_v1) foreign_toplevel=$(has zwlr_foreign_toplevel_manager_v1)"
}

kde() { # desktop with_plasmashell(0/1)
  local d=$1 plasma=$2
  local r; r=$(rundir "$d")
  export XDG_RUNTIME_DIR=$r; unset WAYLAND_DISPLAY DISPLAY WLR_BACKENDS
  [ -S /run/dbus/system_bus_socket ] || { sudo mkdir -p /run/dbus && sudo dbus-daemon --system --fork; }
  local kw; kw=$(nocap kwin_wayland kwin_wayland)
  dbus-run-session -- bash -c '
    set -u
    '"$kw"' --virtual --width 1280 --height 720 --socket wayland-k > '"$OUT/$d-compositor.log"' 2>&1 &
    for _ in $(seq 60); do [ -S $XDG_RUNTIME_DIR/wayland-k ] && break; sleep 0.25; done
    export WAYLAND_DISPLAY=wayland-k QT_QPA_PLATFORM=wayland
    '"$(declare -f zmural_on zmural_off)"'
    BIN='"$BIN"' OUT='"$OUT"' WORK='"$WORK"'
    zmural_on '"$d"'
    if [ '"$plasma"' = 1 ]; then
      /usr/libexec/kactivitymanagerd > '"$OUT/$d-kamd.log"' 2>&1 &
      sleep 2
      XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6 QT_FORCE_STDERR_LOGGING=1 \
        plasmashell > '"$OUT/$d-plasmashell.log"' 2>&1 &
      sleep 20
    fi
    timeout 20 spectacle -b -n -f -o '"$OUT/$d.png"' > /dev/null 2>&1
    echo "$FRAMES" > '"$WORK/$d.frames"'
    zmural_off
    kill $(jobs -p) 2>/dev/null
  ' >/dev/null 2>&1
  local frames; frames=$(cat "$WORK/$d.frames" 2>/dev/null || echo 0)
  if [ "$plasma" = 1 ]; then
    report "$d" "covered" "zmural renders ($frames first frame); Plasma's own wallpaper covers it: needs the KDE plugin"
  else
    report "$d" "$([ "$frames" -gt 0 ] && echo shows || echo NOT-SHOWN)" "bare KWin, layer_shell=yes"
  fi
}

mutter_gnome() {
  local d=mutter r; r=$(rundir mutter)
  export XDG_RUNTIME_DIR=$r; unset WAYLAND_DISPLAY DISPLAY WLR_BACKENDS
  local msg
  msg=$(dbus-run-session -- bash -c '
    mutter --headless --wayland --no-x11 --virtual-monitor 1280x720 > '"$OUT/mutter-compositor.log"' 2>&1 &
    for _ in $(seq 60); do ls $XDG_RUNTIME_DIR | grep -qE "^wayland-[0-9]+$" && break; sleep 0.25; done
    export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -E "^wayland-[0-9]+$" | head -1)
    timeout 4 '"$BIN"'/zmural --layer-shell --test-pattern 2>&1 | head -1
    kill $(jobs -p)' 2>/dev/null | grep -v '^Spi\|dbus-daemon')
  report "$d" "unsupported" "GNOME stand-in; host says: ${msg:-nothing} (expected: needs the GNOME extension)"
}

(cd "$ROOT" && zig build) || exit 1
: >"$OUT/summary.txt"
desktops=("$@"); [ ${#desktops[@]} -eq 0 ] && desktops=(sway labwc wayfire river niri cosmic kwin plasma mutter)
for d in "${desktops[@]}"; do
  case $d in
    sway)    wlroots sway "$(nocap sway sway)" -c /dev/null ;;
    labwc)   wlroots labwc labwc ;;
    wayfire) printf '[core]\nplugins = \n' >"$WORK/wayfire.ini"; wlroots wayfire wayfire -c "$WORK/wayfire.ini" ;;
    river)   wlroots river river -no-xwayland -c true ;;
    niri)    nested niri niri ;;
    cosmic)  nested cosmic cosmic-comp ;;
    kwin)    kde kwin 0 ;;
    plasma)  kde plasma 1 ;;
    mutter)  mutter_gnome ;;
    *) echo "unknown desktop: $d" ;;
  esac
done
[ -n "$OUTER" ] && pkill -f "$WORK/bin/sway" 2>/dev/null
echo; echo "screenshots and logs: $OUT"
