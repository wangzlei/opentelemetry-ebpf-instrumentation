#!/usr/bin/env bash
# Verify that the committed snapshot obi/ is exactly upstream/ + patches/.
# Regenerates the patched tree in a temp dir and compares it file by file.
#   scripts/check-obi.sh            exit 0 = consistent, 1 = obi/ is stale or hand-edited
# Fix a failure with: scripts/apply-patches.sh && scripts/sync-obi.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$ROOT/scripts/apply-patches.sh" "$tmp/tree" >/dev/null
"$ROOT/scripts/sync-obi.sh" "$tmp/tree" "$tmp/obi" >/dev/null
if diff -r -q "$tmp/obi" "$ROOT/obi" > "$tmp/diff.txt"; then
  echo "obi/ matches upstream/ + patches/ ($(find "$ROOT/obi" -type f | wc -l | tr -d ' ') files)"
else
  echo "obi/ does NOT match upstream/ + patches/:"
  sed "s|$tmp/obi|<regenerated>|g; s|$ROOT/obi|obi|g" "$tmp/diff.txt" | head -20
  echo "fix: scripts/apply-patches.sh && scripts/sync-obi.sh   (never edit obi/ by hand)"
  exit 1
fi
