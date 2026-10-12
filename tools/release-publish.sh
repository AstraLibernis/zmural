#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# CI's last step for a release (docs/RELEASING.md): takes the packages the
# Windows and Linux jobs built and tested, and puts them on GitHub with the
# notes from docs/releases/v<version>.md and their checksums.
#   - On a v* tag: publishes the release (a 0.x or -suffixed version as a
#     pre-release). The tag must be v + build.zig.zon's version.
#   - Otherwise (a run by hand): a draft of the same release, a preview only
#     the maintainer sees. A later run replaces the draft's files; the tag
#     run publishes that draft.
# A version already published is never touched: make a new one.
#
#   tools/release-publish.sh <artifacts dir>   # needs gh and GH_TOKEN
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ART=$1
ver=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$ROOT/build.zig.zon")
tag=v$ver
[ -n "$ver" ] || { echo "no .version in build.zig.zon"; exit 1; }
publish=false
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  [ "$GITHUB_REF_NAME" = "$tag" ] || { echo "tag $GITHUB_REF_NAME isn't build.zig.zon's version ($tag)"; exit 1; }
  publish=true
fi
pre=false
case $ver in 0.* | *-*) pre=true ;; esac
notes=$ROOT/docs/releases/$tag.md
[ -f "$notes" ] || { echo "no release notes: docs/releases/$tag.md"; exit 1; }

win=zmural-$ver-windows-x86_64
lin=zmural-$ver-linux-x86_64
OUT=$(mktemp -d)
cp "$ART/zmural-windows-release/$win.zip" "$ART/zmural-linux-release/$lin.tar.gz" "$OUT/"
(cd "$ART/zmural-windows-release/debug" && zip -qr "$OUT/$win-debug.zip" "$win")
tar --owner=0 --group=0 -czf "$OUT/$lin-debug.tar.gz" -C "$ART/zmural-linux-release/debug" "$lin"
(cd "$OUT" && sha256sum "$win.zip" "$lin.tar.gz" "$win-debug.zip" "$lin-debug.tar.gz" >SHA256SUMS.txt)
{ cat "$notes"; printf '\n## Checksums (SHA-256)\n\n```\n'; cat "$OUT/SHA256SUMS.txt"; printf '```\n'; } >"$OUT/notes.md"
files=("$OUT/$win.zip" "$OUT/$lin.tar.gz" "$OUT/$win-debug.zip" "$OUT/$lin-debug.tar.gz" "$OUT/SHA256SUMS.txt")

# Drafts don't show under releases/tags/<tag>, so look through the list.
state=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | if .draft then \"draft\" else \"published\" end" | head -1)
if [ "$state" = published ]; then
  echo "$tag is already published; set a new version in build.zig.zon"; exit 1
elif [ "$state" = draft ]; then
  gh release upload "$tag" "${files[@]}" --clobber
  gh release edit "$tag" --title "zmural $ver" --notes-file "$OUT/notes.md" --target "$GITHUB_SHA" --prerelease="$pre" --draft="$([ $publish = true ] && echo false || echo true)"
else
  gh release create "$tag" "${files[@]}" --title "zmural $ver" --notes-file "$OUT/notes.md" --target "$GITHUB_SHA" --prerelease="$pre" --draft="$([ $publish = true ] && echo false || echo true)"
fi
$publish && echo "published $tag" || echo "draft $tag updated (a preview; tools/release.sh publishes it)"
gh release view "$tag" --json url,isDraft,isPrerelease,assets --jq '"\(.url) draft=\(.isDraft) prerelease=\(.isPrerelease) files=\([.assets[].name] | join(" "))"'
