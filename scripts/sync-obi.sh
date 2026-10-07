#!/usr/bin/env bash
# Copy the patched OBI tree (build/obi) into the committed snapshot obi/, so every
# commit of this repo carries patches/ AND the resulting code side by side
# (git log -p / blame / GitHub show the real code change of each patch edit).
#
#   scripts/sync-obi.sh [src-tree] [dest]      defaults: build/obi -> obi
#
# obi/ is GENERATED: never edit it. scripts/check-obi.sh (CI + pre-commit) fails
# when obi/ differs from upstream/ + patches/.
#
# Copied: the files tracked in the patched tree, minus paths that are not useful
# for reading or reviewing the code (kept in sync with check-obi.sh via
# obi-snapshot.exclude). Generated BPF bindings are untracked, so never copied.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-"$ROOT/build/obi"}; DEST=${2:-"$ROOT/obi"}
[[ -d $SRC/.git ]] || { echo "$SRC is not a patched tree: run scripts/apply-patches.sh"; exit 1; }
list=$(mktemp); trap 'rm -f "$list"' EXIT
git -C "$SRC" ls-files | grep -v -E -f "$ROOT/scripts/obi-snapshot.exclude" > "$list"
rm -rf "$DEST"; mkdir -p "$DEST"
rsync -a --files-from="$list" "$SRC/" "$DEST/"
echo "obi/: $(wc -l < "$list" | tr -d ' ') files from $(git -C "$SRC" log -1 --format='%h %s')"
