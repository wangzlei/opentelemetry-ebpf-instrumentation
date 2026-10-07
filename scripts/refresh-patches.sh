#!/usr/bin/env bash
# Export the patch stack back out of an edited working tree (default build/obi).
# Every commit after the `upstream` tag becomes one numbered patch; the patch
# name comes from the commit's "Adot-Obi-Patch: NN-name" trailer.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=${1:-"$ROOT/build/obi"}; BASE=${2:-upstream}
tmp=$(mktemp -d)
git -C "$TREE" format-patch -q --no-signature --zero-commit --full-index -o "$tmp" "$BASE"..HEAD
rm -f "$ROOT"/patches/[0-9][0-9]-*.patch
for f in "$tmp"/*.patch; do
  name=$(sed -n 's/^Adot-Obi-Patch: *//p' "$f" | head -1)
  [[ -n $name ]] || { echo "commit in $(basename "$f") has no Adot-Obi-Patch trailer"; exit 1; }
  mv "$f" "$ROOT/patches/$name.patch"; echo "patches/$name.patch"
done
rm -rf "$tmp"
