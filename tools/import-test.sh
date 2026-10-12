#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Live test of `zmural-console import` (Linux) on a headless Sway: real zips
# (made by `zip`, deflated) are unpacked into the library, listed and shown;
# hostile ones (made with Python's zipfile, as an independent writer) are
# refused with nothing written anywhere; the no-zmural cases; and export,
# checked by importing it back and by Info-ZIP's unzip.
#
#   tools/sandbox-deps.sh rigs tests
#   zig build && tools/import-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); BIN=$ROOT/zig-out/bin
W=${TMPDIR:-/tmp}/zmural-import-test
rm -rf "$W"; mkdir -p "$W/xdg" "$W/home/Videos/Wallpapers" "$W/cfg" "$W/xdgcfg" "$W/xdgdata" "$W/bin" "$W/src" "$W/zips"; chmod 700 "$W/xdg"
cp "$(command -v sway)" "$W/bin/sway-nocap" # sway's file capability may be refused in a container
export XDG_RUNTIME_DIR=$W/xdg HOME=$W/home ZMURAL_CONFIG_DIR=$W/cfg XDG_CONFIG_HOME=$W/xdgcfg XDG_DATA_HOME=$W/xdgdata
unset XDG_STATE_HOME WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP SWAYSOCK
V=$HOME/Videos/Wallpapers
magick -size 320x180 xc:green "$V/green.png"

# A zip of two pictures in a folder, as someone would share them.
mkdir -p "$W/src/Sunsets"
magick -size 320x180 xc:red "$W/src/Sunsets/a-red.png"
magick -size 320x180 xc:blue "$W/src/Sunsets/b-blue.png"
(cd "$W/src" && zip -qr "$W/zips/Sunsets.zip" Sunsets)
# A package: a manifest and the picture it names, no top folder.
mkdir -p "$W/src/pkg/media"
magick -size 320x180 xc:red "$W/src/pkg/media/still.png"
printf 'title = "Red still"\ntype = "image"\nentry = "media/still.png"\n' >"$W/src/pkg/zmural.toml"
(cd "$W/src/pkg" && zip -qr "$W/zips/red-still.zip" .)
# Hostile and wrong ones.
python3 - "$W/zips" <<'EOF'
import sys, zipfile
d = sys.argv[1]
def make(name, entries, link=None):
    with zipfile.ZipFile(f"{d}/{name}", "w", zipfile.ZIP_DEFLATED) as z:
        for n, data in entries: z.writestr(n, data)
        if link:
            i = zipfile.ZipInfo(link[0]); i.create_system = 3; i.external_attr = (0o120777 << 16)
            z.writestr(i, link[1])
make("escape.zip", [("rain.png", b"x"), ("../../.config/autostart/evil.desktop", b"[Desktop Entry]\n")])
make("absolute.zip", [("/tmp/zmural-import-test/evil.png", b"x")])
make("backslash.zip", [("a\\..\\..\\evil.png", b"x")])
make("link.zip", [("rain.png", b"x")], link=("home", "/home"))
make("lively-program.zip", [("LivelyInfo.json", b'{"Type": 0, "FileName": "game.exe"}'), ("game.exe", b"MZ")])
make("nothing.zip", [("readme.txt", b"hi")])
open(f"{d}/not-a-zip.zip", "wb").write(b"PK\x03\x04 this is not a zip")
EOF

printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' >"$W/sway.conf"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 setsid "$W/bin/sway-nocap" -c "$W/sway.conf" >"$W/sway.log" 2>&1 </dev/null &
SWAY=$!
for _ in $(seq 40); do [ -e "$W/xdg/wayland-1" ] && break; sleep 0.25; done
export WAYLAND_DISPLAY=wayland-1

FAIL=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAIL=1; fi; }
z() { "$BIN/zmural-console" "$@"; }
imp() { z import "$@" >"$W/out.txt" 2>&1; echo $?; }
lib() { z status | sed -n 's/^library *: \([0-9]*\).*/\1/p'; }
shows() {
  grim -o HEADLESS-1 "$W/out.png" 2>/dev/null || { echo none; return; }
  magick "$W/out.png" -gravity center -crop 100x100+0+0 +repage -resize 1x1 -format '%[fx:int(255*r)] %[fx:int(255*g)] %[fx:int(255*b)]' info: |
    awk '{ if ($1>200 && $2<60 && $3<60) print "red"; else if ($3>200 && $1<60 && $2<60) print "blue"; else if ($2>100 && $1<60 && $3<60) print "green"; else print $0 }'
}
# Everything under the test folder except the zips: refusals must not change it.
tree() { find "$W" -path "$W/zips" -prune -o -path "$W/xdg" -prune -o -path "$W/cfg" -prune -o -name 'out.*' -prune -o -print | sort; }

# 1. zmural not running: no folder known, unless one is given.
rc=$(imp "$W/zips/Sunsets.zip")
check "without zmural and without --to it refuses, exit 3 ($rc)" "[ $rc = 3 ] && grep -q 'give --to' $W/out.txt && [ ! -e $V/Sunsets ]"
rc=$(imp "$W/zips/Sunsets.zip" --to "$W/elsewhere")
check "…with --to it unpacks there (exit $rc)" "[ $rc = 0 ] && [ -f $W/elsewhere/Sunsets/a-red.png ] && [ -f $W/elsewhere/Sunsets/b-blue.png ]"

setsid "$BIN/zmural" --apply "$V/green.png" >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
sleep 3
before=$(lib)

# 2. A zip of pictures, into zmural's first standard folder, listed and shown.
rc=$(imp "$W/zips/Sunsets.zip" --apply); sleep 2
check "a deflated zip of pictures unpacks into Videos/Wallpapers, without nesting (exit $rc)" "[ $rc = 0 ] && [ -f $V/Sunsets/a-red.png ] && [ ! -e $V/Sunsets/Sunsets ]"
check "…zmural lists both at once ($before -> $(lib))" "[ \$(lib) = \$((before + 2)) ]"
check "…and --apply shows the first of them" "[ \$(shows) = red ] && z status | grep -q 'Sunsets/a-red.png'"
rc=$(imp "$W/zips/Sunsets.zip")
check "importing it again makes 'Sunsets (2)' and leaves the first alone" "[ $rc = 0 ] && [ -f '$V/Sunsets (2)/b-blue.png' ] && [ \$(ls $V/Sunsets | wc -l) = 2 ]"

# 3. A package: its manifest is checked and it lands as one folder.
rc=$(imp "$W/zips/red-still.zip")
check "a package unpacks with its manifest and the file it names (exit $rc)" "[ $rc = 0 ] && grep -q 'a wallpaper package' $W/out.txt && [ -f $V/red-still/zmural.toml ] && [ -f $V/red-still/media/still.png ]"

# 4. Hostile and wrong zips: refused, exit 1, nothing written anywhere.
snap=$(tree)
for zf in escape absolute backslash link lively-program nothing not-a-zip; do
  rc=$(imp "$W/zips/$zf.zip")
  reason=$(sed 's/.*: //' "$W/out.txt" | head -c 90)
  check "refused: $zf.zip (exit $rc: $reason)" "[ $rc = 1 ] && grep -q 'not imported' $W/out.txt"
done
check "…and none of them wrote a single file, inside the library or out of it" "[ \"\$(tree)\" = \"\$snap\" ] && [ ! -e $HOME/.config/autostart/evil.desktop ] && [ ! -e /tmp/zmural-import-test/evil.png ]"
check "…nor left a hidden folder behind" "! ls -a $V | grep -q '^\.zmural-import'"
check "zmural was never disturbed by them" "kill -0 $ZD && z status >/dev/null"

# 5. Export: what comes out imports back, byte for byte, and Info-ZIP's unzip
#    (an independent reader) finds nothing wrong with it.
mkdir -p "$W/ex"
(cd "$W/ex" && z export "$V/red-still/zmural.toml" >"$W/out.txt" 2>&1); rc=$?
check "export of a package writes '<its folder>.zip' here (exit $rc)" "[ $rc = 0 ] && [ -f $W/ex/red-still.zip ]"
check "…which unzip -t passes" "unzip -tq $W/ex/red-still.zip >/dev/null"
z export "$V/Sunsets" "$W/ex/sun.zip" >/dev/null 2>&1
rc=$(imp "$W/ex/sun.zip" --to "$W/back")
check "a folder exported and imported again is the same, byte for byte" "[ $rc = 0 ] && diff -r $V/Sunsets $W/back/Sunsets"
z export "$V/Sunsets" "$W/ex/sun.zip" >"$W/out.txt" 2>&1; rc=$?
check "export never overwrites a zip (exit $rc)" "[ $rc = 1 ] && grep -q 'already exists' $W/out.txt"
# By name, as status and the settings window name them, from anywhere.
(cd "$W/ex" && z export green.png >"$W/out.txt" 2>&1); rc=$?
check "export by a file's name in the library (exit $rc)" "[ $rc = 0 ] && unzip -l $W/ex/green.zip | grep -q green.png"
(cd "$W/ex" && z export red-still named.zip >"$W/out.txt" 2>&1); rc=$?
check "…and by a package's name: its folder (exit $rc)" "[ $rc = 0 ] && unzip -l $W/ex/named.zip | grep -q 'red-still/zmural.toml'"
(cd "$W/ex" && z export nosuch.mp4 >"$W/out.txt" 2>&1); rc=$?
check "…a name nothing has is refused, saying so (exit $rc)" "[ $rc = 1 ] && grep -q 'no wallpaper by that name' $W/out.txt"
mkdir -p "$HOME/Pictures/Wallpapers"; cp "$V/green.png" "$HOME/Pictures/Wallpapers/"; z rescan; sleep 1
(cd "$W/ex" && z export green.png again.zip >"$W/out.txt" 2>&1); rc=$?
check "…and so is a name two wallpapers share, asking for the path (exit $rc)" "[ $rc = 1 ] && grep -q '2 wallpapers in the library are named green.png' $W/out.txt && [ ! -e $W/ex/again.zip ]"
rm "$HOME/Pictures/Wallpapers/green.png"; z rescan
head -c 300M /dev/urandom >"$W/big.mp4"
t0=$(date +%s%N); z export "$W/big.mp4" "$W/ex/big.zip" >/dev/null 2>&1; rc=$?; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
rc2=$(imp "$W/ex/big.zip" --to "$W/bigback")
check "a 300 MB file exports in ${ms} ms, and comes back identical" "[ $rc = 0 ] && [ $rc2 = 0 ] && unzip -tq $W/ex/big.zip >/dev/null && cmp -s $W/big.mp4 $W/bigback/big/big.mp4"
rm -rf "$W/big.mp4" "$W/ex/big.zip" "$W/bigback"

# 6. From the settings window: Open file takes a zip, and imports it through
#    zmural-console in a process of its own. ZMURAL_TEST_PICK answers the
#    picker (the desktop's own window, which this rig can't drive).
z quit >/dev/null 2>&1; sleep 1
window_import() { # zip -> runs zmural with the window, clicks Open file
  ZMURAL_TEST_PICK=$1 setsid "$BIN/zmural" --settings >>"$W/daemon.log" 2>&1 </dev/null & ZD=$!
  sleep 4
  "$BIN/zmural-test-input" 1280 720 move:1057,61 click wait:300 >/dev/null 2>&1
  sleep 3; grim "$W/window.png"
}
mkdir -p "$W/src/Window pick"; magick -size 320x180 xc:red "$W/src/Window pick/r.png"
(cd "$W/src" && zip -qr "$W/zips/win.zip" "Window pick")
window_import "$W/zips/win.zip"
check "a zip picked in the window's Open file is imported and shown" "[ -f '$V/Window pick/r.png' ] && z status | grep -q 'Window pick/r.png'"
check "…by zmural-console, in a process of its own, which said how it went" "grep -q '^ok .*Window pick' $W/cfg/import-report.txt && ! ps --ppid $ZD -o comm=,stat= | grep zmural-console | grep -qv Z"
z quit >/dev/null 2>&1; sleep 1
snap=$(tree)
window_import "$W/zips/escape.zip"
check "a hostile zip picked there is refused, says why, and writes nothing" "grep -q '^error escape.zip wasn.t imported: .*outside its folder' $W/cfg/import-report.txt && [ \"\$(tree)\" = \"\$snap\" ] && kill -0 $ZD"

z quit >/dev/null 2>&1; sleep 0.5; kill $SWAY 2>/dev/null
[ $FAIL = 0 ] && echo "all passed" || { echo "FAILED; files in $W"; exit 1; }
