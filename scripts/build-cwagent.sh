#!/usr/bin/env bash
# Build a test CloudWatch Agent (linux/amd64) that includes the OBI receiver.
# Expects a cwagent checkout on the exp/obi-receiver branch next to this repo
# (its go.mod replaces go.opentelemetry.io/obi => ../adot-obi/build/obi and the
# receiver => ../adot-obi/receiver/obireceiver).
#   CWAGENT=<path> build-cwagent.sh [make|gobuild]
# "make"   : cwagent's own Makefile target amazon-cloudwatch-agent-linux-amd64
# "gobuild": same flags as that target, but only the agent binary
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CW=${CWAGENT:-"$ROOT/../cwagent"}; MODE=${1:-gobuild}
cd "$CW"
export GOFLAGS=-mod=readonly
case $MODE in
  make) make amazon-cloudwatch-agent-linux-amd64 BUILD_SPACE="$ROOT/build/cwagent";;
  gobuild)
    mkdir -p "$ROOT/build/cwagent/bin/linux_amd64"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildmode=default \
      -ldflags="-s -w -X github.com/aws/amazon-cloudwatch-agent/cfg/agentinfo.VersionStr=1.300074.0-obi-exp" \
      -o "$ROOT/build/cwagent/bin/linux_amd64/amazon-cloudwatch-agent" ./cmd/amazon-cloudwatch-agent;;
esac
# Default OTel config for the image (cwagent/Dockerfile copies it from this dir).
cp "$ROOT/config/otel.yaml" "$ROOT/build/cwagent/bin/linux_amd64/otel.yaml"
ls -la "$ROOT/build/cwagent/bin/linux_amd64/"
