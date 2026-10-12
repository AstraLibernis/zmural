#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Every control in the settings window (Linux), pressed with a virtual mouse
# the way a person would, and what it did checked: in `zmural-console status`,
# in settings.toml, on the bus, in the log ("told: ..." is every message the
# window showed). The window says where it drew each control
# (ZMURAL_TEST_CONTROLS), so nothing here guesses coordinates; a control out
# of sight is scrolled to with the wheel first. File pickers are the
# desktop's own windows, which a headless rig can't drive: their buttons are
# pressed for real and the answer comes from ZMURAL_TEST_PICK.
# docs/CONTROLS.md lists the controls; each `press` below is one of its rows.
#
# Headless Sway with two outputs, a session bus, a notification daemon, a
# file manager (dbusmock) and an opener that records what it's asked.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/controls-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-controls
# A zmural a failed run left behind (by its runtime folder, not a pattern
# that could match this shell).
for p in $(pgrep -f -- "--apply $W/"); do kill "$p" 2>/dev/null; done
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Pictures/Wallpapers" "$W/home/Videos/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin" "$W/opener" "$W/extra"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY XDG_CURRENT_DESKTOP SWAYSOCK
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>"$W/bus.pid" | head -1)
P=$HOME/Pictures/Wallpapers V=$HOME/Videos/Wallpapers
for c in red green blue; do magick -size 320x180 "xc:$c" "$P/$c.png"; done
magick -size 320x180 xc:yellow "$W/extra/yellow.png"
ffmpeg -v error -f lavfi -i testsrc2=size=320x180:rate=30 -t 3 -c:v libvpx-vp9 -b:v 200k "$V/clip.webm"
# A package with one property of each kind the window can change.
mkdir -p "$V/Kinds"; cp "$P/blue.png" "$V/Kinds/pic.png"
cat >"$V/Kinds/zmural.toml" <<'EOF'
title = "Kinds"
type = "image"
entry = "pic.png"

[properties.level]
kind = "slider"
label = "Level"
default = 5
min = 0
max = 10
step = 1

[properties.glow]
kind = "checkbox"
label = "Glow"
default = false

[properties.mood]
kind = "dropdown"
label = "Mood"
default = "calm"
options = ["calm", "busy", "wild"]
EOF
printf '#!/bin/sh\necho "$@" >>%s/opener/calls\nexit 0\n' "$W" >"$W/opener/xdg-open"; chmod +x "$W/opener/xdg-open"
PICK=$W/pick

setsid python3 -m dbusmock -t notification_daemon >"$W/notify.log" 2>&1 </dev/null & NOTIFY=$!
setsid python3 -m dbusmock org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1 >"$W/fm.log" 2>&1 </dev/null & FM=$!
sleep 1.5
gdbus call --session -d org.freedesktop.FileManager1 -o /org/freedesktop/FileManager1 -m org.freedesktop.DBus.Mock.AddMethod '' ShowItems ass '' '' >/dev/null

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
[ -e "$W/xdg/wayland-1" ] || { echo "Sway didn't start (see $W/sway.log)"; exit 1; }
export WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$W"/xdg/sway-ipc.*.sock)
swaymsg -q create_output; swaymsg -q output HEADLESS-2 resolution 1024x768 position 1280 0
swaymsg -q focus output HEADLESS-1

FAIL=0; PRESSED=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
L=$W/daemon.log F=$W/cfg/settings.toml C=$W/controls.tsv
z() { "$BIN/zmural-console" "$@"; }
st() { z status; }
setting() { grep -m1 "^$1 = " "$F" | sed 's/^[^=]*= *//; s/ *#.*//'; }
mark() { N=$(wc -l <"$L"); }
since() { tail -n +$((N + 1)) "$L"; }
told() { since | grep -q "told: $1"; }

setsid env PATH="$W/opener:$PATH" ZMURAL_TEST_CONTROLS="$C" ZMURAL_TEST_PICK="@$PICK" "$BIN/zmural" --apply "$P/red.png" >"$L" 2>&1 </dev/null & ZD=$!
sleep 3
timeout 10 "$BIN/zmural" --settings >/dev/null 2>&1; sleep 2
# Where the window's content starts on screen (below Sway's title bar).
read -r OX OY < <(swaymsg -t get_tree | jq -r '.. | objects | select(.app_id? == "org.zmural.Settings") | "\(.rect.x + .window_rect.x) \(.rect.y + .window_rect.y)"' | head -1)
check "the window is up and says where its controls are" "[ -n \"$OX\" ] && [ -s $C ]"

# Absolute positions span the whole layout: both outputs, side by side.
input() { "$BIN/zmural-test-input" 2304 768 "$@" wait:250 >/dev/null 2>&1; }
# The control by name, index, and (if given) its label: "x y w h visible".
# An index of * takes any (a tile found by its file's name).
find() { awk -F'\t' -v n="$1" -v i="$2" -v l="${3:-}" '$1 == n && (i == "*" || $2 == i) && (l == "" || $3 == l) { print $4, $5, $6, $7, $8; exit }' "$C"; }
# Scrolls until the control is in sight, then prints its centre on screen.
locate() {
  local line dir=3 tries=0
  while :; do
    line=$(find "$@")
    if [ -z "$line" ]; then
      # A page draws only what is in sight: scroll down, then up, to find it.
      sleep 0.3; line=$(find "$@")
      for s in 3 3 3 3 3 3 -3 -3 -3 -3 -3 -3 -3 -3 -3 -3 -3 -3; do
        [ -n "$line" ] && break
        input move:700,400 scroll:$s; sleep 0.4; line=$(find "$@")
      done
      [ -n "$line" ] || { echo "no control $*" >&2; return 1; }
    fi
    local x y w h vis; read -r x y w h vis <<<"$line"
    if [ "$vis" = 1 ]; then echo "$((OX + x + w / 2)) $((OY + y + h / 2))"; return 0; fi
    tries=$((tries + 1)); [ $tries -gt 30 ] && { echo "can't scroll to $*" >&2; return 1; }
    local before=$y
    input move:700,400 "scroll:$( [ "$y" -gt 360 ] && echo $dir || echo $((-dir)) )"; sleep 0.4
    read -r _ y _ _ _ <<<"$(find "$@")"
    # The wheel's sign is the compositor's: flip once if it went the wrong way.
    if [ "$y" = "$before" ] || { [ "$before" -gt 360 ] && [ "$y" -gt "$before" ]; } || { [ "$before" -le 360 ] && [ "$y" -lt "$before" ]; }; then dir=$((-dir)); fi
  done
}
press() { local at; at=$(locate "$@") || { FAIL=1; return 1; }; input move:${at/ /,} click; PRESSED=$((PRESSED + 1)); sleep 0.8; }
rpress() { local at; at=$(locate "$@") || { FAIL=1; return 1; }; input move:${at/ /,} rclick; PRESSED=$((PRESSED + 1)); sleep 0.8; }
# A slider pressed at a fraction of its length.
slide() { # name index fraction(0..100)
  local x y w h; locate "$1" "$2" >/dev/null || { FAIL=1; return 1; }
  read -r x y w h _ <<<"$(find "$1" "$2")"
  input move:$((OX + x + w * $3 / 100)),$((OY + y + h / 2)) click; PRESSED=$((PRESSED + 1)); sleep 0.8
}
page() { press nav "$1"; }
pick() { printf '%s\n' "$1" >"$PICK"; }

# ---- Sidebar -----------------------------------------------------------------------------
for i in 0 1 2 3 4; do page $i; done
check "the sidebar: General shows its controls" "[ -n \"\$(find autostart 0)\" ]"
page 2
check "…and Playback its own" "[ -n \"\$(find fill 0 Fit)\" ]"

# ---- Player card -------------------------------------------------------------------------
press np 2; sleep 1
check "player card Next: the wallpaper changes" "! st | head -1 | grep -q red.png"
press np 0; sleep 1
check "…Previous: back to red" "st | head -1 | grep -q red.png"
press np 1
check "…Pause: paused by you" "st | grep -q '^paused *: yes (by you'"
press np 1
check "…and Play again" "! st | grep -q '^paused *: yes (by you'"
press np 3
check "…Unmute (wallpapers start muted)" "st | grep -q '^muted *: no'"
press np 3
check "…and Mute" "st | grep -q '^muted *: yes'"

# ---- Wallpapers page ---------------------------------------------------------------------
page 1
press tile '*' green.png; sleep 1
check "a tile: shows that wallpaper" "st | head -1 | grep -q green.png"
cp "$W/extra/yellow.png" "$P/"; press rescan 0; sleep 2
check "Rescan: a file just added gets its tile" "[ -n \"\$(find tile '*' yellow.png)\" ]"
pick "$P/blue.png"; press open-file 0; sleep 1.5
check "Open file (the picker answered blue.png): shows it" "st | head -1 | grep -q blue.png"
pick "$W/extra"; press add-folder 0; sleep 1.5
check "Add folder (answered extra/): it joins the library folders" "grep -q 'extra' $F"
rpress tile '*' red.png
check "a tile's right click: its menu" "[ -n \"\$(find menu 0)\" ]"
press menu 0 "Show on every monitor"; sleep 1
check "menu Show on every monitor: red everywhere" "st | head -1 | grep -q red.png && st | grep HEADLESS-2 | grep -q 'main wallpaper'"
rpress tile '*' green.png
M2=$(awk -F'\t' '$1=="menu" && $3 ~ /monitor 2/ {print $2"\t"$3; exit}' "$C")
press menu "${M2%%$'\t'*}" "${M2#*$'\t'}"; sleep 1
check "menu Show on monitor 2: green there only" "st | grep HEADLESS-2 | grep -q green.png && st | head -1 | grep -q red.png"
rpress tile '*' green.png
press menu '*' "Show in folder"; sleep 1
check "menu Show in folder: the file manager is asked for that file" "grep -q 'ShowItems.*green.png' $W/fm.log"
rpress tile '*' green.png
input move:1200,650 click; sleep 0.8
check "a click outside the menu closes it" "[ -z \"\$(find menu 0)\" ]"
z apply "$P/red.png" >/dev/null

# ---- Welcome page ------------------------------------------------------------------------
page 0
press welcome-tile 0; sleep 1
W0=$(st | head -1)
check "Welcome's tile: shows it ($(basename "${W0#*: }"))" "! echo '$W0' | grep -q red.png"
press welcome-open 0
check "Welcome's folder Open: the opener gets Videos/Wallpapers" "grep -qx '$V' $W/opener/calls"
press welcome-open 1
check "…and Pictures/Wallpapers" "grep -qx '$P' $W/opener/calls"
pick "$W/extra/yellow.png"; press welcome-file 0; sleep 1.5
check "Welcome's Open file: shows the file picked" "st | head -1 | grep -q yellow.png"
mkdir -p "$W/more"; pick "$W/more"; press welcome-add 0; sleep 1.5
check "Welcome's Add folder: it joins the library folders" "grep -q '/more' $F"
press welcome-all 0
check "Welcome's Wallpapers button: the Wallpapers page" "[ -n \"\$(find rescan 0)\" ]"

# ---- Playback page -----------------------------------------------------------------------
page 2
for f in Fit Stretch Center Crop; do
  press fill 0 $f
  check "Fill $f" "[ \$(setting fill) = '\"${f,,}\"' ]"
done
slide volume 0 25
check "the volume slider, pressed a quarter along: $(setting volume)" "v=\$(setting volume); [ \$v -ge 15 ] && [ \$v -le 35 ]"
press muted 0
check "the Mute wallpapers switch: off" "[ \$(setting muted) = false ]"
press muted 0
check "…and on" "[ \$(setting muted) = true ]"
press paused 0
check "the Pause wallpapers switch: on" "[ \$(setting paused) = true ]"
press paused 0
check "…and off" "[ \$(setting paused) = false ]"
for r in "5 min:5" "15 min:15" "30 min:30" "1 h:60" "3 h:180" "Off:0"; do
  press rotate 0 "${r%%:*}"
  check "Change every ${r%%:*}" "[ \$(setting every_minutes) = ${r#*:} ]"
done
for o in "Shuffle:shuffle" "Random:random" "By name:sequential"; do
  press order 0 "${o%%:*}"
  check "Order ${o%%:*}" "[ \$(setting order) = '\"${o#*:}\"' ]"
done
# Customise, on the package with one property of each kind.
z apply "$V/Kinds/zmural.toml" >/dev/null; sleep 1.5
slide prop 0 80
check "Customise slider (Level), pressed 80% along: $(z props | grep level)" "z props | grep level | grep -qE '= (7|8|9)'"
press prop 1
check "Customise switch (Glow): on" "z props | grep glow | grep -q true"
press prop 2 wild
check "Customise choice (Mood): wild" "z props | grep mood | grep -q wild"
press prop-reset 0
check "Customise Reset: all back" "z props | grep level | grep -q '= 5' && z props | grep glow | grep -q false && z props | grep mood | grep -q calm"
z apply "$P/red.png" >/dev/null

# ---- Pausing page ------------------------------------------------------------------------
page 3
ROWS=$(awk -F'\t' '$1=="rule" {print $2}' "$C" | sort -un)
for ci in $ROWS; do
  cond=$(grep -E '^[a-z_]+ = "(none|mute|pause|stop)"' "$F" | sed -n "$((ci + 1))p" | cut -d' ' -f1)
  press rule "$ci" Stop
  check "rule row $ci ($cond): Stop" "[ \$(setting $cond) = '\"stop\"' ]"
  press rule "$ci" Nothing
  check "…and Nothing" "[ \$(setting $cond) = '\"none\"' ]"
done
pick /usr/bin/foot; press app-add 0; sleep 1.5
check "Add app (answered foot): it joins the list" "grep -q \"^apps = \\['foot'\\]\" $F"
press app-remove 0; sleep 1
check "…and its remove button takes it off" "grep -q '^apps = \[\]' $F"
slide resume 0 50
check "the resume slider: $(setting resume_after_ms) ms" "[ \$(setting resume_after_ms) != 400 ]"

# ---- General page ------------------------------------------------------------------------
page 4
A=$XDG_CONFIG_HOME/autostart/zmural.desktop
press autostart 0
check "Start at login: off" "! grep -qs 'Hidden=false' $A || grep -qs 'Hidden=true' $A || [ ! -e $A ]"
press autostart 0
check "…and on" "[ -e $A ] && ! grep -q 'Hidden=true' $A"
mkdir -p "$W/third"; pick "$W/third"; press dir-add 0 "Add folder"; sleep 1.5
check "General's Add folder: it joins the library folders" "grep -q '/third' $F"
D=$(grep -c . <(grep -o "'[^']*'" <<<"$(setting folders)")); press dir-remove 0; sleep 1
check "a library folder's remove button" "[ \$(grep -o \"'[^']*'\" <<<\"\$(setting folders)\" | wc -l) -lt $D ]"
press open-log 0
check "Log file Open: the opener gets zmural.log" "grep -q 'zmural.log' $W/opener/calls"
press reset 0
check "Reset: it asks first" "[ -n \"\$(find confirm-no 0)\" ]"
press confirm-no 0 No
check "…No changes nothing" "[ \$(setting resume_after_ms) != 400 ]"
press reset 0; press confirm-yes 0 Yes; sleep 1
check "…Yes puts pausing back (resume 400 ms)" "[ \$(setting resume_after_ms) = 400 ]"
press uninstall 0
press confirm-no 0 No; sleep 1
check "Uninstall, then No: zmural is still there" "kill -0 $ZD && [ -e $F ]"

echo "$PRESSED presses"
check "nothing crashed, and every message shown is in the log" "! grep -qi 'panic\|segmentation' $L"
z quit >/dev/null 2>&1; sleep 1
kill $ZD $NOTIFY $FM $SWAY "$(cat "$W/bus.pid")" 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; logs in $W"; exit 1; }
