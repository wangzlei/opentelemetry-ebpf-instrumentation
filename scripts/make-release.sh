#!/usr/bin/env bash
# Simulate an adot-obi release: commit the patched OBI tree INCLUDING the
# generated BPF bindings (gitignored upstream) as obi/ on the `release` branch
# of this repo and tag it obi/<upstream-tag>-adot.<n>. The CloudWatch Agent's
# internal build fetches modules through GOPROXY without clang, so the module
# it consumes must already contain the bindings:
#   replace go.opentelemetry.io/obi => github.com/aws-observability/adot-obi/obi <tag-version>
# Local only: nothing is pushed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=${TREE:-"$ROOT/build/obi"}; N=${1:-1}
UPTAG=$(git -C "$ROOT/upstream" describe --tags --exact-match HEAD)
VER="$UPTAG-adot.$N"; TAG="obi/$VER"
n=$(find "$TREE" -name '*_bpfel.o' | wc -l); [[ $n -gt 0 ]] || { echo "no generated BPF objects in $TREE"; exit 1; }
git -C "$ROOT" worktree prune
WT=$(mktemp -d); git -C "$ROOT" worktree add -q --detach "$WT"
cd "$WT"
if git -C "$ROOT" rev-parse -q --verify release >/dev/null; then git checkout -q release; else git checkout -q --orphan release; git rm -rq --cached . >/dev/null 2>&1 || true; fi
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
mkdir obi && rsync -a --exclude .git "$TREE/" obi/
git add -A obi                                                        # honours OBI's own .gitignore files
find obi \( -name '*_bpfel.go' -o -name '*_bpfel.o' \) -print0 | xargs -0 git add -f   # + generated bindings
cat > README.md <<EOR
adot-obi release $VER: upstream OBI $UPTAG + adot-obi patches ($(git -C "$ROOT" rev-parse --short HEAD)) + generated eBPF bindings.
Module go.opentelemetry.io/obi lives in obi/ (tag $TAG).
EOR
git add README.md
git -c user.name=adot-obi -c user.email=adot-obi@localhost commit -q -m "release $VER (generated BPF bindings included)"
git tag -f "$TAG"
echo "release commit $(git rev-parse --short HEAD) tag $TAG ($(git ls-files obi | grep -c '_bpfel\.o$') BPF objects)"
cd "$ROOT"; git worktree remove --force "$WT"
