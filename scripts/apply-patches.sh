#!/usr/bin/env bash
# Materialise the patched OBI tree: upstream/ (pristine OBI tag) + patches/*.patch
# -> build/obi, a throw-away git repo with one commit per patch (so it can be
# edited and exported back with refresh-patches.sh, and so `make docker-generate`
# has the git metadata it needs).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UP="$ROOT/upstream"; OUT=${1:-"$ROOT/build/obi"}
[[ -e $UP/go.mod ]] || { echo "upstream/ is empty: run 'git submodule update --init'"; exit 1; }
TAG=$(git -C "$UP" describe --tags --exact-match HEAD 2>/dev/null || git -C "$UP" rev-parse --short HEAD)
rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$UP" archive --format=tar HEAD | tar -x -C "$OUT"
cd "$OUT"
git init -q -b main
git -c user.name=adot-obi -c user.email=adot-obi@localhost add -A
git -c user.name=adot-obi -c user.email=adot-obi@localhost commit -q -m "upstream OBI $TAG" --date="@0"
git tag upstream
for p in "$ROOT"/patches/[0-9][0-9]-*.patch; do
  echo "applying $(basename "$p")"
  git -c user.name=adot-obi -c user.email=adot-obi@localhost am -q --3way --keep-cr "$p" \
    || { echo "FAILED to apply $(basename "$p")"; git am --abort || true; exit 1; }
done
echo "patched tree: $OUT ($(git rev-list --count upstream..HEAD) patches on $TAG)"
