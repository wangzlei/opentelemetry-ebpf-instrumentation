#!/usr/bin/env bash
# Generate OBI's eBPF bindings (*_bpfel.go / *_bpfel.o) inside the pinned
# upstream generator image, then regenerate a second time and compare hashes
# (reproducibility gate). Linux + docker only.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=${1:-"$ROOT/build/obi"}; OCI_BIN=${OCI_BIN:-"sudo docker"}
cd "$TREE"
hashes() { find . -path ./examples -prune -o \( -name '*_bpfel.go' -o -name '*_bpfel.o' \) -print | sort | xargs sha256sum; }
make docker-generate OCI_BIN="$OCI_BIN"
hashes > "$ROOT/build/bpf-hashes-1.txt"
echo "generated $(wc -l < "$ROOT/build/bpf-hashes-1.txt") files"
if [[ ${SKIP_REPRO:-0} != 1 ]]; then
  find . -path ./examples -prune -o \( -name '*_bpfel.go' -o -name '*_bpfel.o' \) -print | xargs rm -f
  make docker-generate OCI_BIN="$OCI_BIN"
  hashes > "$ROOT/build/bpf-hashes-2.txt"
  if diff -q "$ROOT/build/bpf-hashes-1.txt" "$ROOT/build/bpf-hashes-2.txt" >/dev/null; then
    echo "REPRODUCIBLE: $(wc -l < "$ROOT/build/bpf-hashes-2.txt") files, identical sha256 across 2 generations"
  else
    echo "NOT REPRODUCIBLE:"; diff "$ROOT/build/bpf-hashes-1.txt" "$ROOT/build/bpf-hashes-2.txt" | head; exit 1
  fi
fi
