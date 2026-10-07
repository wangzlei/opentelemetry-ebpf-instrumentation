#!/usr/bin/env bash
# adot-obi local test pipeline. Run on a Linux x86_64 host with docker, go and
# sudo (the dev desktop). From a Mac, use ci/run-remote.sh which syncs this repo
# + the cwagent checkout to the dev desktop and runs this script there.
#
#   ci/run.sh [stage ...]     stages: apply bpf obi collector cwagent e2e   (default: all)
#
# Env: CWAGENT=<cwagent checkout on exp/obi-receiver> (default ../cwagent)
#      GOPROXY/GOSUMDB (default proxy.golang.org / sum.golang.org; override on networks that block them)
#      SKIP_REPRO=1  skip the second BPF generation
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CW=${CWAGENT:-"$ROOT/../cwagent"}
LOGS="$ROOT/ci/logs"; mkdir -p "$LOGS"
export GOPROXY=${GOPROXY:-https://proxy.golang.org,direct} GOSUMDB=${GOSUMDB:-sum.golang.org} GOFLAGS=-mod=readonly
STAGES=("$@"); [[ ${#STAGES[@]} -gt 0 ]] || STAGES=(apply bpf obi collector cwagent e2e)
declare -A RESULT
run() { # run <stage> <cmd...>: log to ci/logs/<stage>.log, record PASS/FAIL
  local s=$1; shift
  echo "=== [$s] $*" | tee -a "$LOGS/$s.log"
  if ( "$@" ) >> "$LOGS/$s.log" 2>&1; then echo "    ok"; else RESULT[$s]=FAIL; echo "    FAILED (see ci/logs/$s.log)"; tail -20 "$LOGS/$s.log"; return 1; fi
}
want() { [[ " ${STAGES[*]} " == *" $1 "* ]]; }

# 1. patches apply cleanly onto pristine upstream
if want apply; then : > "$LOGS/apply.log"; RESULT[apply]=PASS
  run apply "$ROOT/scripts/apply-patches.sh"
  run apply git -C "$ROOT/build/obi" log --oneline upstream..HEAD
fi

# 2. BPF generation (pinned generator image) + reproducibility
if want bpf; then : > "$LOGS/bpf.log"; RESULT[bpf]=PASS
  run bpf "$ROOT/scripts/generate-bpf.sh"
fi

# 3. patched OBI: build, vet, unit tests of patched packages; receiver module
if want obi; then : > "$LOGS/obi.log"; RESULT[obi]=PASS
  O="$ROOT/build/obi"
  PKGS=(./pkg/ebpf/common/... ./pkg/internal/ebpf/tpinjector/... ./pkg/internal/ebpf/gotracer/...
        ./pkg/export/otel/tracesgen/... ./pkg/export/attributes/... ./pkg/appolly/app/request/...
        ./pkg/appolly/meta/... ./pkg/appolly/discover/... ./pkg/internal/processcontext/... ./pkg/obi/... ./collector/...)
  run obi bash -c "cd '$O' && go build ./..."
  run obi bash -c "cd '$O' && go vet ${PKGS[*]}"
  # Known environment-dependent upstream test: tpinjector TestTracer_Constants
  # expects the bpf_iter bundle, which OBI only loads on kernels >= 5.11.
  SKIP=""; kv=$(uname -r); kmaj=${kv%%.*}; kmin=${kv#*.}; kmin=${kmin%%.*}
  if (( kmaj < 5 || (kmaj == 5 && kmin < 11) )); then
    SKIP="-skip ^TestTracer_Constants\$"; echo "kernel $kv < 5.11: skipping upstream tpinjector TestTracer_Constants (needs bpf_iter)" | tee -a "$LOGS/obi.log"
  fi
  run obi bash -c "cd '$O' && go test -count=1 $SKIP ${PKGS[*]}"
  run obi bash -c "cd '$ROOT/receiver/obireceiver' && go vet ./... && go test -count=1 -v ./..."
fi

# 4. standalone eBPF collector image from the same build/obi (demo / A-B builds).
#    Independent of cwagent; runs first because it is fast and cwagent is the slowest stage.
if want collector; then : > "$LOGS/collector.log"; RESULT[collector]=PASS
  run collector env GOPROXY="${COLLECTOR_GOPROXY:-direct}" GOSUMDB=off "$ROOT/scripts/build-collector.sh"
  run collector bash -c "docker run --rm \$(docker images --format '{{.Repository}}:{{.Tag}}' otelcol-obi | head -1) components | grep -E '^ *- (name: )?(obi|otlphttp|sigv4auth|cumulativetodelta|spanmetrics)' "
fi

# 5. cwagent compat build (the key gate): replaces resolve, no collector bump
if want cwagent; then : > "$LOGS/cwagent.log"; RESULT[cwagent]=PASS
  run cwagent bash -c "cd '$CW' && cp go.mod /tmp/adot-obi-cw.go.mod && GOFLAGS=-mod=mod go mod tidy && diff /tmp/adot-obi-cw.go.mod go.mod && echo 'cwagent go.mod is tidy'"
  run cwagent "$ROOT/ci/check-cwagent-versions.sh" "$ROOT/ci/cwagent-v1.300074.0.go.mod" "$CW/go.mod"
  run cwagent bash -c "cd '$CW' && go list -m all > '$LOGS/cwagent-new.modlist' && '$ROOT/ci/check-cwagent-versions.sh' --full '$ROOT/ci/cwagent-v1.300074.0.modlist' '$LOGS/cwagent-new.modlist'"
  run cwagent "$ROOT/scripts/build-cwagent.sh" gobuild
  run cwagent bash -c "cd '$CW' && go vet ./service/defaultcomponents/ && go test -count=1 ./service/defaultcomponents/"
  run cwagent bash -c "cd '$CW' && GOOS=windows GOARCH=amd64 go build -o /dev/null ./cmd/amazon-cloudwatch-agent && echo windows ok"
  run cwagent bash -c "cd '$CW' && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /dev/null ./cmd/amazon-cloudwatch-agent && echo linux/arm64 ok"
fi

# 6. runtime e2e with restricted capabilities
if want e2e; then : > "$LOGS/e2e.log"; RESULT[e2e]=PASS
  AG="$ROOT/build/cwagent/bin/linux_amd64/amazon-cloudwatch-agent"
  run e2e "$ROOT/test/e2e/run-e2e.sh" "$AG" tcp "$LOGS/e2e-tcp"
  run e2e "$ROOT/test/e2e/run-e2e.sh" "$AG" nonetadmin "$LOGS/e2e-nonetadmin"
  if [[ -e $LOGS/e2e-tcp/cgroup2-mounted-by-e2e ]]; then "$ROOT/test/e2e/cgroup2-undo.sh" | tee -a "$LOGS/e2e.log"; fi
fi

echo; echo "===== summary ====="
rc=0; for s in apply bpf obi collector cwagent e2e; do
  [[ -n ${RESULT[$s]:-} ]] || continue; printf '%-8s %s\n' "$s" "${RESULT[$s]}"; [[ ${RESULT[$s]} == PASS ]] || rc=1
done | tee "$LOGS/summary.txt"
grep -q FAIL "$LOGS/summary.txt" && exit 1 || exit 0
