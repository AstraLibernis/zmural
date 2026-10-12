#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Vendors waywallen-display (github.com/waywallen/waywallen-display, MIT,
# Copyright (c) 2026 hypengw) into third_party/waywallen-display, renamed
# so it talks to zmural and never clashes with an installed waywallen.
#
#   tools/vendor-waywallen-display.sh <waywallen-display checkout>
#
# Re-run it with a newer checkout to pull upstream fixes; the renames below
# are the whole patch. Internal C/C++ names (waywallen_display_*,
# WaywallenDisplay) are deliberately left alone: they never leave the
# plugin, and keeping them makes upstream diffs apply cleanly.
set -euo pipefail

SRC=$(cd "${1:?usage: $0 <waywallen-display checkout>}" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DST=$ROOT/third_party/waywallen-display
COMMIT=$(git -C "$SRC" rev-parse HEAD)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$SRC/Cargo.toml" | head -1)

rm -rf "$DST"
mkdir -p "$DST"
# What the KDE and GNOME clients need: the C core, the QML and GObject
# plugins, the extensions, translations and the CMake build. Not the Rust
# layer-shell client (zmural has its own), examples or CI files.
for p in LICENSE BUILD.md CMakeLists.txt Cargo.toml glibc-2.17.h cmake include src/generated \
         plugins extensions po scripts/build_kde_embed.sh scripts/build_gnome_zip.sh; do
  [ -e "$SRC/$p" ] || continue
  mkdir -p "$DST/$(dirname "$p")"
  cp -a "$SRC/$p" "$DST/$p"
done
for f in "$SRC"/src/*.c "$SRC"/src/*.h; do cp -a "$f" "$DST/src/"; done

# ---- the renames ------------------------------------------------------------------
# Order matters: longer names first.
rules=(
  # zmural's socket, not waywallen's.
  's#waywallen/display\.sock#zmural/display.sock#g'
  # zmural's D-Bus name (the fast-reconnect cue; GNOME's launch cue).
  's#org\.waywallen\.waywallen\.Daemon1#org.zmural.Daemon1#g'
  's#org\.waywallen\.waywallen\.Daemon#org.zmural.Daemon#g'
  's#/org/waywallen/waywallen/Daemon#/org/zmural/Daemon#g'
  # The Plasma wallpaper plugin ID, and its translation domain.
  's#org\.waywallen\.kde#org.zmural.kde#g'
  # Private QML module URIs: two plugins claiming one URI can't coexist in plasmashell.
  's#Waywallen\.DisplayEmbed#Zmural.DisplayEmbed#g'
  's#WaywallenDisplayEmbed#ZmuralDisplayEmbed#g'
  # Package file names.
  's#waywallen-kde-#zmural-kde-#g'
  # The GNOME extension: its UUID, settings schema and translation domain.
  's#org\.waywallen\.gnome@waywallen\.io#org.zmural.gnome@zmural#g'
  's#org\.waywallen\.gnome\b#org.zmural.gnome#g'
  's#org\.gnome\.shell\.extensions\.waywallen#org.gnome.shell.extensions.zmural#g'
  's#/org/gnome/shell/extensions/waywallen/#/org/gnome/shell/extensions/zmural/#g'
  's#waywallen-gnome#zmural-gnome#g'
  # Its renderer's app ID: the extension finds (and hides) its renderer
  # windows by it, so two extensions sharing it would fight over windows.
  's#io\.github\.waywallen\.WaywallenRenderer#org.zmural.Renderer#g'
  # Effect names on the Shell's own actors.
  's#waywallen-(overview|desktop)-blur#zmural-\1-blur#g'
  # Log prefixes.
  's#\[waywallen\] #[zmural] #g'
)
sed_args=()
for r in "${rules[@]}"; do sed_args+=(-e "$r"); done
find "$DST" -type f ! -name LICENSE ! -name '*.png' ! -name '*.svg' -print0 | xargs -0 sed -i -E "${sed_args[@]}"
# The default QML module URI, only where it is one: in GJS code
# `Waywallen.Display` is the GObject library's class, which keeps its name.
find "$DST" -type f \( -name '*.qml' -o -name qmldir -o -name CMakeLists.txt -o -name '*.cpp' -o -name '*.hpp' -o -name '*.sh' -o -name '*.md' \) -print0 |
  xargs -0 sed -i -E 's#Waywallen\.Display\b#Zmural.Display#g'
# File names carrying the IDs (translation catalogs, the settings schema).
find "$DST" -depth \( -name '*org.waywallen.kde*' -o -name '*waywallen-gnome*' -o -name '*extensions.waywallen*' \) | while read -r f; do
  mv "$f" "$(dirname "$f")/$(basename "$f" | sed -e 's/org\.waywallen\.kde/org.zmural.kde/' -e 's/waywallen-gnome/zmural-gnome/' -e 's/extensions\.waywallen/extensions.zmural/')"
done

# ---- zmural's wording ------------------------------------------------------------
KDE=$DST/extensions/kde/package
python3 - "$KDE/metadata.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
k = m["KPlugin"]
k["Name"] = "zmural"
k["Description"] = "Live wallpapers from zmural (display plugin based on waywallen-display)"
k.pop("Description[ru]", None)
k["Authors"] = [{"Name": "AstraLibernis"}, {"Name": "hypengw (waywallen-display)"}]
k["Website"] = "https://github.com/AstraLibernis/zmural"
k["License"] = "GPL-3.0-or-later"
json.dump(m, open(p, "w"), indent=4, ensure_ascii=False)
open(p, "a").write("\n")
PY
sed -i -E \
  -e 's#"waywallen-display module failed to load"#"zmural display module failed to load"#' \
  -e 's#"Install or update waywallen-display:"#"Reinstall zmural:"#' \
  -e 's#text: "https://github.com/waywallen/waywallen-display"#text: "https://github.com/AstraLibernis/zmural"#' \
  "$KDE/contents/ui/main.qml"
sed -i -E \
  -e 's#<a href=\\"https://github.com/waywallen/waywallen\\">github.com/waywallen/waywallen</a>#<a href=\\"https://github.com/AstraLibernis/zmural\\">zmural</a> (display plugin from <a href=\\"https://github.com/waywallen/waywallen-display\\">waywallen-display</a>)#' \
  -e 's#Please report at <a href=\\"https://github.com/waywallen/waywallen-display/issues\\">github.com/waywallen/waywallen-display/issues</a>#Please report it to zmural#' \
  "$KDE/contents/ui/config.qml"

GNOME=$DST/extensions/gnome
sed -i -E \
  -e 's#"name": "Waywallen"#"name": "zmural"#' \
  -e 's#"description": "[^"]*"#"description": "Live wallpapers from zmural (display extension based on waywallen-display)."#' \
  -e 's#"url": "https://github.com/waywallen"#"url": "https://github.com/AstraLibernis/zmural"#' \
  "$GNOME/extension/metadata.json.in"

cat > "$DST/VENDORED.md" <<EOF
# waywallen-display, vendored

- Upstream: https://github.com/waywallen/waywallen-display
- Commit: \`$COMMIT\` (version $VERSION)
- Licence: MIT, Copyright (c) 2026 hypengw (see \`LICENSE\`). \`glibc-2.17.h\`
  is MIT, Copyright 2021 Bill Zissimopoulos (its header).
- Vendored by \`tools/vendor-waywallen-display.sh\`, which also applies every
  change: the socket path (\`\$XDG_RUNTIME_DIR/zmural/display.sock\`), the
  D-Bus name (\`org.zmural.Daemon\`), the Plasma plugin ID (\`org.zmural.kde\`),
  the private QML module URIs (\`Zmural.Display*\`), the GNOME extension's
  UUID (\`org.zmural.gnome@zmural\`), settings schema, translation domain and
  renderer app ID (\`org.zmural.Renderer\`), package names, and zmural's
  wording in the KDE and GNOME packages. Don't edit files here by hand:
  change the script and re-run it.
- zmural speaks the same protocol (waywallen-display-v1 v9), so these
  clients work against it unchanged apart from the names.
EOF
echo "vendored waywallen-display $VERSION ($COMMIT) into $DST"
grep -rIl 'waywallen/display\.sock\|org\.waywallen\.kde\|org\.waywallen\.waywallen\|org\.waywallen\.gnome\|WaywallenRenderer\|extensions\.waywallen' "$DST" && { echo "leftover upstream names (above)"; exit 1; } || true
