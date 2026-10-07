#!/usr/bin/env bash
# Pin an OBI working tree's go.mod to the dependency versions used by a given
# CloudWatch Agent release, so that cwagent can import OBI without its
# collector/otel/contrib versions being bumped by Go's MVS.
#
# usage: pin-to-cwagent.sh <obi-tree> <cwagent go.mod> [cwagent `go list -m all` output]
#
# Rule: for every module required by BOTH go.mod files, if OBI's version is
# higher than cwagent's, set it to cwagent's. Modules only OBI uses are pinned
# explicitly below (EXTRA_PINS) to the newest release whose own requirements
# do not exceed cwagent's collector/otel lines. Then `go mod tidy`.
set -euo pipefail
OBI=${1:?obi tree}; CWMOD=${2:?cwagent go.mod}; CWALL=${3:-}
cd "$OBI"

# (ebpf-profiler is not pinned: patch 99 vendors the few bits OBI used and
#  drops the dependency - every release fitting collector <= v1.56.0 still
#  needs golang.org/x/arch >= v0.23.0 and mdlayher/socket v0.5.1.)
# Modules not in cwagent's graph: newest version compatible with
# collector v1.56.0/v0.150.0 and otel v1.44.0 (checked against their go.mod).
EXTRA_PINS=(
  go.opentelemetry.io/contrib/detectors/aws/ec2/v2@v2.5.1      # v2.5.2 needs otel v1.45.0 / aws-sdk-go-v2 v1.43
  go.opentelemetry.io/contrib/detectors/aws/eks@v1.43.0        # v1.44.0 needs k8s client-go v0.35.4 (cwagent: v0.35.3)
  go.opentelemetry.io/contrib/detectors/gcp@v1.43.0            # cwagent graph has v1.43.0 (v1.45.0 needs otel v1.45.0)
  go.opentelemetry.io/contrib/detectors/azure/azurevm@v0.16.0  # v0.17.0 needs otel v1.45.0
)

reqs() { go mod edit -json "$1" | python3 -c 'import json,sys; [print(r["Path"], r["Version"], "indirect" if r.get("Indirect") else "direct") for r in (json.load(sys.stdin).get("Require") or [])]'; }

CW_COLLECTOR_V1=$(go mod edit -json "$CWMOD" | python3 -c 'import json,sys; print([r["Version"] for r in json.load(sys.stdin)["Require"] if r["Path"]=="go.opentelemetry.io/collector/component"][0])')
CW_COLLECTOR_V0=$(go mod edit -json "$CWMOD" | python3 -c 'import json,sys; print([r["Version"] for r in json.load(sys.stdin)["Require"] if r["Path"]=="go.opentelemetry.io/collector/component/componenttest"][0])')
echo "cwagent collector train: $CW_COLLECTOR_V1 / $CW_COLLECTOR_V0"
CWGO=$(go mod edit -json "$CWMOD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Go"])')
go mod edit -go="$CWGO" -toolchain=none

declare -A CW
declare -A CWMODV
while read -r p v _; do CW[$p]=$v; CWMODV[$p]=$v; done < <(reqs "$CWMOD")
# Full cwagent module list (direct + indirect, incl. modules pruned from go.mod)
if [[ -n $CWALL ]]; then while read -r p v _; do [[ -n $v ]] && CW[$p]=${CW[$p]:-$v}; done < "$CWALL"; fi

args=()
# Modules cwagent selects (often only in its full graph) that OBI cannot go
# down to; their bump is listed in ci/cwagent-allowed-bumps.txt.
NOPIN=(
  github.com/cilium/ebpf   # cwagent graph: v0.17.3; OBI's bpf2go bindings/loader need v0.22.0
)
while read -r p v kind; do
  if [[ " ${NOPIN[*]} " == *" $p "* ]]; then echo "keep $p $v (NOPIN)"; continue; fi
  case $p in
    go.opentelemetry.io/collector/*)
      # same release train as cwagent's collector: v1.x -> v1.56.0, v0.x -> v0.150.0
      # (also for modules cwagent only has as stale entries of its full graph)
      # cwagent's own go.mod version wins (e.g. configgrpc is v0.150.0 there);
      # otherwise the train matching OBI's major (stale full-graph entries such
      # as otlpexporter v0.111.0 are ignored).
      if [[ -n ${CWMODV[$p]:-} ]]; then nv=${CWMODV[$p]}
      else nv=$( [[ $v == v1.* ]] && echo "$CW_COLLECTOR_V1" || echo "$CW_COLLECTOR_V0" ); fi
      [[ $nv != "$v" ]] && { echo "pin  $p $v -> $nv (collector train)"; args+=("-require=$p@$nv"); }
      continue;;
  esac
  cv=${CW[$p]:-}
  if [[ -z $cv ]]; then
    # OBI-only module.
    # Indirect OBI-only deps are dropped and re-resolved by `go mod tidy` from
    # the (pinned) direct deps, so they settle at the minimum MVS needs.
    if [[ $kind == indirect ]]; then args+=("-droprequire=$p"); fi
    continue
  fi
  [[ $cv == "$v" ]] && continue
  hi=$(printf '%s\n%s\n' "$v" "$cv" | python3 -c '
import sys,re
def k(s):
    s=s.strip().lstrip("v").split("+")[0]; core,_,pre=s.partition("-")
    return ([int(x) for x in core.split(".")], pre=="", pre)
a,b=[l.strip() for l in sys.stdin]
print(a if k(a)>k(b) else b)')
  if [[ $hi == "$v" ]]; then
    echo "pin  $p $v -> $cv"; args+=("-require=$p@$cv")
  fi
done < <(reqs go.mod)
# Upstream deps that patch 99 removed from OBI's import graph (vendored or
# replaced code); drop them before tidy, otherwise their (newer) requirements
# take part in MVS while tidy computes the graph.
DROPPED=(
  go.opentelemetry.io/ebpf-profiler                          # vendored: pkg/internal/processcontext{,/pf}
  go.opentelemetry.io/proto/otlp/processcontext/v1development # vendored: pkg/internal/processcontext/processcontextpb
  github.com/containers/common                                # replaced by a statfs check in pkg/ebpf/cgroupv2.go
)
for d in "${DROPPED[@]}"; do echo "drop $d"; args+=("-droprequire=$d"); done
for e in "${EXTRA_PINS[@]}"; do echo "pin  ${e%@*} -> ${e#*@}"; args+=("-require=$e"); done
go mod edit "${args[@]}"
GOFLAGS=-mod=mod go mod tidy
echo "--- post-tidy check: collector/otel modules above cwagent versions"
bad=0
while read -r p v; do
  cv=${CW[$p]:-}; [[ -z $cv || $cv == "$v" ]] && continue
  hi=$(printf '%s\n%s\n' "$v" "$cv" | python3 -c '
import sys
def k(s):
    s=s.strip().lstrip("v").split("+")[0]; core,_,pre=s.partition("-")
    return ([int(x) for x in core.split(".")], pre=="", pre)
a,b=[l.strip() for l in sys.stdin]
print(a if k(a)>k(b) else b)')
  [[ $hi == "$v" ]] || continue
  case $p in go.opentelemetry.io/collector*|go.opentelemetry.io/otel*|go.opentelemetry.io/contrib*|github.com/open-telemetry/*|github.com/amazon-contributing/*)
    if [[ $p == go.opentelemetry.io/collector* && -z ${CWMODV[$p]:-} ]]; then
      echo "above (stale cwagent full-graph entry, not in its build list): $p obi=$v cwagent=$cv"
    else echo "ABOVE (blocking): $p obi=$v cwagent=$cv"; bad=1; fi;;
  *) echo "above (non-blocking, forced by an OBI-only dependency): $p obi=$v cwagent=$cv";;
  esac
done < <(go list -m -f '{{.Path}} {{.Version}}' all 2>/dev/null)
# OBI-only collector modules must also be on cwagent's train
while read -r p v; do
  [[ -n ${CW[$p]:-} ]] && continue
  case $p in go.opentelemetry.io/collector*)
    [[ $v == "$CW_COLLECTOR_V1" || $v == "$CW_COLLECTOR_V0" ]] || { echo "OFF-TRAIN: $p $v"; bad=1; };; esac
done < <(go list -m -f '{{.Path}} {{.Version}}' all 2>/dev/null)
exit $bad
