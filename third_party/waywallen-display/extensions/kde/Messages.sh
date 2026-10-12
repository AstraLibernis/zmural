#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
po_dir="$script_dir/po"
domain=plasma_wallpaper_org.zmural.kde

xgettext_cmd=${XGETTEXT:-xgettext}
for tool in "$xgettext_cmd" msginit msgmerge msgfmt; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'error: required gettext tool not found: %s\n' "$tool" >&2
        exit 1
    }
done

mkdir -p "$po_dir"
tmp_pot=$(mktemp "$po_dir/.${domain}.pot.XXXXXX")
trap 'rm -f "$tmp_pot" "$po_dir"/*.po.tmp' EXIT HUP INT TERM

cd "$repo_root"
"$xgettext_cmd" \
    --language=JavaScript \
    --keyword=i18nd:2 \
    --from-code=UTF-8 \
    --no-git \
    --sort-by-file \
    --no-wrap \
    --package-name="$domain" \
    --msgid-bugs-address=https://github.com/waywallen/waywallen-display/issues \
    --output="$tmp_pot" \
    --files-from="$script_dir/POTFILES.in"
sed 's/^"POT-Creation-Date:.*\\n"$/"POT-Creation-Date: 1970-01-01 00:00+0000\\n"/' "$tmp_pot" > "$tmp_pot.normalized"
mv "$tmp_pot.normalized" "$tmp_pot"
mv "$tmp_pot" "$po_dir/$domain.pot"

while IFS= read -r lang; do
    case "$lang" in ''|'#'*) continue ;; esac
    po="$po_dir/$lang.po"
    if [ -f "$po" ]; then
        msgmerge --update --backup=none --no-wrap "$po" "$po_dir/$domain.pot"
    else
        msginit --no-translator --locale="$lang" --input="$po_dir/$domain.pot" --output-file="$po"
    fi
    msgfmt --check --check-format -o /dev/null "$po"
done < "$po_dir/LINGUAS"
