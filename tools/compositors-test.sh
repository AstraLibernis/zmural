#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of window facts from Hyprland's and Wayfire's own IPC (Linux,
# `daemon/compositor.zig`): a fullscreen window pauses the wallpaper, the
# same window on a workspace that isn't showing doesn't, a maximized one is
# reported, and the app rule works. Wayfire runs headless (with its ipc and
# ipc-rules plugins, then without, for the hint); Hyprland has no headless
# mode of its own, so it runs nested in a headless KWin (Sway's xdg-shell is
# too old for it).
#
#   tools/sandbox-deps.sh rigs tests
#   Hyprland: sudo dnf copr enable sdegler/hyprland && sudo dnf install hyprland
#     (a third-party build: Fedora 44 doesn't package Hyprland)
#   zig build && tools/compositors-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
# Short: Hyprland's socket path (with its 62-character instance name) must
# fit a Unix socket address, 108 bytes.
W=${TMPDIR:-/tmp}/zmc
rm -rf "$W"; mkdir -p "$W/home/Pictures/Wallpapers" "$W/bin"
magick -size 320x180 xc:red "$W/home/Pictures/Wallpapers/red.png"
unset WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK NIRI_SOCKET HYPRLAND_INSTANCE_SIGNATURE WAYFIRE_SOCKET XDG_STATE_HOME
FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
# Each case runs inside its own session bus; its checks are written to a
# file and printed here.
results() { cat "$W/$1.results"; grep -q '^FAIL' "$W/$1.results" && FAIL=1; }

# ---- Wayfire ---------------------------------------------------------------------------

wayfire_case() { # name plugins
  local name=$1 plugins=$2 D=$W/$1
  mkdir -p "$D/xdg" "$D/cfg"; chmod 700 "$D/xdg"
  printf '[core]\nplugins = %s\n' "$plugins" >"$D/wayfire.ini"
  cat >"$D/run.sh" <<EOS
set -u
export XDG_RUNTIME_DIR=$D/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$D/cfg
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 wayfire -c $D/wayfire.ini >$D/wayfire.log 2>&1 &
for _ in \$(seq 40); do ls $D/xdg | grep -qE '^wayland-[0-9]+\$' && break; sleep 0.25; done; sleep 1
export WAYLAND_DISPLAY=\$(ls $D/xdg | grep -E '^wayland-[0-9]+\$' | head -1)
# Wayfire sets this for the programs it starts; zmural is started by hand here.
S=\$(ls $D/xdg/wayfire-*.socket 2>/dev/null | head -1); [ -n "\$S" ] && export WAYFIRE_SOCKET=\$S
[ $name = wayfire-plain ] && export XDG_CURRENT_DESKTOP=wayfire
wf() { python3 -c 'import socket,struct,json,os,sys
s=socket.socket(socket.AF_UNIX); s.connect(os.environ["WAYFIRE_SOCKET"])
b=json.dumps({"method":sys.argv[1],"data":json.loads(sys.argv[2])}).encode(); s.sendall(struct.pack("<I",len(b))+b)
n=struct.unpack("<I",s.recv(4))[0]; r=b""
while len(r)<n: r+=s.recv(n-len(r))' "\$@"; }
$(declare -f check)
L=$D/cfg/zmural.log
mark() { N=\$(wc -l <\$L); }; since() { tail -n +\$((N + 1)) \$L; }
setsid $BIN/zmural --apply $W/home/Pictures/Wallpapers/red.png >$D/daemon.out 2>&1 </dev/null &
sleep 3
if [ $name = wayfire-plain ]; then
  check "Wayfire without its ipc plugin: zmural says which plugins to turn on" "grep -q \"Wayfire's ipc plugin is off\" \$L"
else
  check "Wayfire: zmural reads window facts from its IPC" "grep -q 'Wayfire: window facts and the app in front from its IPC' \$L"
  mark; setsid foot -a listed --fullscreen sleep 300 >/dev/null 2>&1 </dev/null & FOOT=\$!; sleep 2
  check "…a fullscreen window pauses the wallpaper" "since | grep -q 'fullscreen=true' && since | grep -q 'none -> pause'"
  mark; wf vswitch/set-workspace '{"x":1,"y":0,"output-id":1}'; sleep 1.5
  check "…on a workspace that isn't showing, it doesn't" "since | grep -q 'fullscreen=false' && since | grep -q 'pause -> none'"
  wf vswitch/set-workspace '{"x":0,"y":0,"output-id":1}'; sleep 1.5
  sed -i 's/^apps = .*/apps = ["foot"]/' $D/cfg/settings.toml; sleep 2.5
  check "…and the app rule sees the app in front" "grep -q 'app rule: foot is in front' \$L"
  kill \$FOOT
fi
$BIN/zmural-console quit; sleep 0.5
kill \$(jobs -p) 2>/dev/null
EOS
  timeout 90 dbus-run-session -- bash "$D/run.sh" 2>/dev/null | grep -E '^(ok|FAIL) ' >"$W/$name.results"
  results "$name"
}

wayfire_case wayfire "ipc ipc-rules vswitch"
wayfire_case wayfire-plain ""

# ---- Hyprland --------------------------------------------------------------------------

if ! command -v Hyprland >/dev/null; then
  echo "FAIL Hyprland isn't installed (sudo dnf copr enable sdegler/hyprland && sudo dnf install hyprland)"; FAIL=1
else
  D=$W/h; mkdir -p "$D/kx" "$D/xdg" "$D/cfg" "$D/hcfg/hypr"; chmod 700 "$D/kx" "$D/xdg"
  cp "$(command -v kwin_wayland)" "$W/bin/kwin_wayland" # without its file capability, which a container may refuse
  printf 'monitor = , 1280x720, 0x0, 1\nmisc {\n  disable_hyprland_logo = true\n  disable_splash_rendering = true\n}\necosystem {\n  no_update_news = true\n  no_donation_nag = true\n}\n' >"$D/hcfg/hypr/hyprland.conf"
  cat >"$D/run.sh" <<EOS
set -u
export XDG_RUNTIME_DIR=$D/kx
$W/bin/kwin_wayland --virtual --width 1280 --height 720 --socket wayland-k >$D/kwin.log 2>&1 &
for _ in \$(seq 60); do [ -S $D/kx/wayland-k ] && break; sleep 0.25; done
ln -sf $D/kx/wayland-k $D/xdg/outer
export XDG_RUNTIME_DIR=$D/xdg
(cd $D && XDG_CONFIG_HOME=$D/hcfg WAYLAND_DISPLAY=$D/xdg/outer exec Hyprland >$D/hyprland.log 2>&1) &
for _ in \$(seq 40); do ls $D/xdg/hypr/*/.socket.sock >/dev/null 2>&1 && break; sleep 0.25; done
export HYPRLAND_INSTANCE_SIGNATURE=\$(ls $D/xdg/hypr | head -1) WAYLAND_DISPLAY=\$(ls $D/xdg | grep -E '^wayland-[0-9]+\$' | head -1)
export HOME=$W/home ZMURAL_CONFIG_DIR=$D/cfg
$(declare -f check)
L=$D/cfg/zmural.log
mark() { N=\$(wc -l <\$L); }; since() { tail -n +\$((N + 1)) \$L; }
setsid $BIN/zmural --apply $W/home/Pictures/Wallpapers/red.png >$D/daemon.out 2>&1 </dev/null &
sleep 3
check "Hyprland: zmural reads window facts from its IPC" "grep -q 'Hyprland: window facts and the app in front from its IPC' \$L"
check "…and shows the wallpaper there (its own display host)" "grep -q 'first frame' \$L"
hyprctl dispatch exec "foot -a listed sleep 300" >/dev/null; sleep 1.5
mark; hyprctl dispatch fullscreen 0 >/dev/null; sleep 1
check "…a fullscreen window pauses the wallpaper" "since | grep -q 'fullscreen=true' && since | grep -q 'none -> pause'"
mark; hyprctl dispatch workspace 2 >/dev/null; sleep 1
check "…on a workspace that isn't showing, it doesn't" "since | grep -q 'fullscreen=false' && since | grep -q 'pause -> none'"
mark; hyprctl dispatch workspace 1 >/dev/null; sleep 1; hyprctl dispatch fullscreen 1 >/dev/null; sleep 1
check "…a maximized one is reported" "since | grep -q 'maximized=true'"
sed -i 's/^apps = .*/apps = ["foot"]/' $D/cfg/settings.toml; sleep 2.5
check "…and the app rule sees the app in front" "grep -q 'app rule: foot is in front' \$L"
$BIN/zmural-console quit; sleep 0.5
kill \$(jobs -p) 2>/dev/null
EOS
  timeout 120 dbus-run-session -- bash "$D/run.sh" 2>/dev/null | grep -E '^(ok|FAIL) ' >"$W/hyprland.results"
  results hyprland
fi

[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
