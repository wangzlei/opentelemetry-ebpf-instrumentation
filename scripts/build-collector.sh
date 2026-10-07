#!/usr/bin/env bash
# Build the standalone eBPF collector image from build/obi (the same patched OBI
# tree cwagent uses). Linux + docker; run scripts/apply-patches.sh and
# scripts/generate-bpf.sh first.
#
#   scripts/build-collector.sh [image-tag]     default: otelcol-obi:<upstream tag>-<patch hash>
#
# The image label io.adot-obi.source records the upstream tag and the hash of the
# patch stack, so two builds can be confirmed to carry identical OBI code.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
O="$ROOT/build/obi"
[[ -d $O/.git ]] || { echo "build/obi missing: run scripts/apply-patches.sh"; exit 1; }
ls "$O"/pkg/internal/ebpf/generictracer/*_bpfel.go >/dev/null 2>&1 \
  || { echo "BPF bindings missing: run scripts/generate-bpf.sh"; exit 1; }

UP_TAG=$(git -C "$ROOT/upstream" describe --tags --exact-match HEAD 2>/dev/null || git -C "$ROOT/upstream" rev-parse --short HEAD)
PATCH_HASH=$(cat "$ROOT"/patches/[0-9][0-9]-*.patch | sha256sum | cut -c1-12)
SOURCE="obi-${UP_TAG}+patches-${PATCH_HASH}"
TAG=${1:-"otelcol-obi:${UP_TAG}-${PATCH_HASH}"}

ver=$(sed -n 's/^.*go.opentelemetry.io\/collector\/exporter\/debugexporter \(v[0-9.]*\).*$/\1/p' "$ROOT/collector/builder-config.yaml")
GOBIN=$(go env GOPATH)/bin
go install "go.opentelemetry.io/collector/cmd/builder@${ver}"
cp "$ROOT/collector/builder-config.yaml" "$O/otelcol-obi-builder.yaml"
(cd "$O" && GOFLAGS=-mod=mod "$GOBIN/builder" --skip-compilation --config ./otelcol-obi-builder.yaml)

docker build -f "$ROOT/collector/Dockerfile" \
  --build-arg GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" \
  --build-arg GOSUMDB="${GOSUMDB:-sum.golang.org}" \
  --build-arg OBI_SOURCE="$SOURCE" \
  -t "$TAG" "$O"
echo "built $TAG ($SOURCE)"
