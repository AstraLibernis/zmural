#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Publishes a release (docs/RELEASING.md): checks that main is committed and
# pushed and that docs/releases/v<version>.md exists, then tags v<version>
# (the version in build.zig.zon) and pushes the tag. CI then tests
# everything again and publishes the release; if a test fails, nothing is
# published.
#
#   tools/release.sh          # asks before tagging
#   tools/release.sh --yes
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }
ver=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
tag=v$ver
[ -n "$ver" ] || die "no .version in build.zig.zon"
[ -f "docs/releases/$tag.md" ] || die "write the release notes first: docs/releases/$tag.md"
[ "$(git branch --show-current)" = main ] || die "not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main isn't the same as origin/main: push (or pull) first"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists here"
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null && die "$tag already exists on GitHub"
echo "Release $tag from $(git log -1 --format='%h %s')"
if [ "${1:-}" != --yes ]; then
  read -r -p "Tag and push it? CI publishes it if every test passes. [y/N] " a
  [ "$a" = y ] || [ "$a" = Y ] || die "nothing done"
fi
git tag -a "$tag" -m "zmural $ver"
git push origin "$tag"
echo "Pushed $tag. CI: https://github.com/AstraLibernis/zmural/actions"
