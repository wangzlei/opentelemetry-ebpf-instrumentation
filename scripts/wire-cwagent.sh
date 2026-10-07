#!/usr/bin/env bash
# (Re)create the cwagent go.mod wiring from the release go.mod: requires +
# local replaces for go.opentelemetry.io/obi and the receiver, then tidy.
# Starting from the release go.mod matters: `go mod tidy` never lowers versions
# a previous tidy already recorded.
#   wire-cwagent.sh <cwagent dir> <release go.mod> <release go.sum>
set -euo pipefail
CW=${1:?cwagent dir}; BASEMOD=${2:?}; BASESUM=${3:?}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Receiver module first: drop its indirect requires and re-tidy, so stale
# (higher) versions recorded by an earlier tidy cannot leak into cwagent.
( cd "$ROOT/receiver/obireceiver"
  for m in $(go mod edit -json | python3 -c 'import json,sys; [print(r["Path"]) for r in json.load(sys.stdin)["Require"] if r.get("Indirect")]'); do
    go mod edit -droprequire="$m"; done
  rm -f go.sum; GOFLAGS=-mod=mod go mod tidy )
cd "$CW"
cp "$BASEMOD" go.mod; cp "$BASESUM" go.sum
cat >> go.mod <<'EOR'

// ADOT-OBI experimental: patched OpenTelemetry eBPF Instrumentation receiver.
// ../adot-obi is the adot-obi repo checkout (build/obi = upstream OBI v0.12.2
// + patches/ + generated BPF bindings, produced by scripts/apply-patches.sh and
// scripts/generate-bpf.sh).
replace (
	github.com/aws-observability/adot-obi/receiver/obireceiver => ../adot-obi/receiver/obireceiver
	go.opentelemetry.io/obi => ../adot-obi/build/obi
)
EOR
go mod edit -require=github.com/aws-observability/adot-obi/receiver/obireceiver@v0.0.0-00010101000000-000000000000 -require=go.opentelemetry.io/obi@v0.12.2
GOFLAGS=-mod=mod go mod tidy
