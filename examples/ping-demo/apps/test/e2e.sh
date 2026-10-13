#!/usr/bin/env bash
# End-to-end checks for the four polyglot images against a running ./fleet.sh fleet (network
# pingtest). Starts and removes its own extra containers (names e2e-*). Prints PASS/FAIL per check.
#   TAG=<sha> ./fleet.sh up && TAG=<sha> ./e2e.sh; ./fleet.sh down
set -uo pipefail
cd "$(dirname "$0")"
TAG=${TAG:-dev}
IMG=${IMG:-ping-demo-apps}
NET=pingtest
declare -A IMAGE=(
  [python]="$IMG:checkout-python-omni-$TAG" [go]="$IMG:payment-go-omni-$TAG"
  [java]="$IMG:inventory-java-omni-$TAG"   [node]="$IMG:audit-node-omni-$TAG"
)
LANGS=(python go java node)
FAILS=0

P() { docker run --rm --network "$NET" -v "$PWD/probe.py:/p.py:ro" --entrypoint python "${IMAGE[python]}" /p.py "$@"; }
check() { # name python-expr-over-`r` json
  if python3 -c "import json,sys; r=json.loads(sys.argv[2]); s={int(k):v for k,v in r.get('statuses',{}).items()}; n=r.get('n',1); sys.exit(0 if ($1) else 1)" "$1" "$3" 2>/dev/null
  then echo "PASS $2  $3"; else echo "FAIL $2  $3"; FAILS=$((FAILS+1)); fi
}
expect() { # name expected-substring actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1  $3"; else echo "FAIL $1  expected '$2' got: $3"; FAILS=$((FAILS+1)); fi
}
fault() { P post "http://$1:8000/fault?profile=$2" >/dev/null; }
app() { # name lang env...  (extra container on the test network)
  local name=$1 lang=$2; shift 2
  local envs=(); for e in "$@"; do envs+=(-e "$e"); done
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --network "$NET" --memory 256m "${envs[@]}" ${DOCKER_ARGS:-} "${IMAGE[$lang]}" >/dev/null
}
ready() { for _ in $(seq 40); do P get "http://$1:8000/healthz" >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "FAIL $1 never became ready"; FAILS=$((FAILS+1)); }
AUDITS=(ping-audit-1 ping-audit-2 ping-audit-3)
all_audit() { for a in "${AUDITS[@]}"; do fault "$a" "$1"; done; }

echo "== 1. endpoints + /fault on every language (each image as a leaf)"
for l in "${LANGS[@]}"; do
  app "e2e-leaf-$l" "$l" ROLE=audit PROFILE=healthy
done
for l in "${LANGS[@]}"; do
  h="e2e-leaf-$l"; ready "$h"
  expect "$l healthz"          '"cpu_share":0.0,"ok":true,"pid":'      "$(P get http://$h:8000/healthz)"
  expect "$l fault bogus"      '400 {"error":"unknown profile","valid":["healthy","flaky","degraded","erroring","faulty"]}' \
                               "$(P post "http://$h:8000/fault?profile=bogus")"
  expect "$l fault default"    '200 {"profile":"degraded","role":"audit"}' "$(P post http://$h:8000/fault)"
  # Python: the POST reached one of two gunicorn workers, so sample until that worker answers.
  out=""; for _ in 1 2 3 4 5 6 7 8 9 10; do out=$(P get http://$h:8000/healthz); [[ $out == *degraded* ]] && break; done
  expect "$l healthz after"    '"profile":"degraded","role":"audit"'     "$out"
  expect "$l fault flaky"      '200 {"profile":"flaky","role":"audit"}'  "$(P post "http://$h:8000/fault?profile=flaky")"
  expect "$l GET route = 405"  '405'                                     "$(P get http://$h:8000/audit)"
  expect "$l GET /fault = 405" '405'                                     "$(P get http://$h:8000/fault)"
  expect "$l unknown = 404"    '404'                                     "$(P get http://$h:8000/nope)"
done

echo "== 2. permanent small failure rate (profile flaky: expect ~2% 500, ~1% 429)"
# Python's /fault reaches one of its two gunicorn workers, so its leaf is started with PROFILE=flaky.
app e2e-leaf-python python ROLE=audit PROFILE=flaky; ready e2e-leaf-python
for l in "${LANGS[@]}"; do
  r=$(P hit "http://e2e-leaf-$l:8000/audit" 3000 48)
  check "set(s) <= {200,500,429} and 0.01 <= s.get(500,0)/n <= 0.032 and 0.003 <= s.get(429,0)/n <= 0.02" "$l flaky mix" "$r"
done

echo "== 3. failure propagation: every language as the parent of the 3 Node audits"
for l in "${LANGS[@]}"; do app "e2e-parent-$l" "$l" ROLE=payment PROFILE=healthy AUDIT_URLS=http://audit:8000; done
for l in "${LANGS[@]}"; do ready "e2e-parent-$l"; done
all_audit faulty    # 20% 200, 50% 503, 30% 500 -> parent adopts every failure as 500 (never 503)
for l in "${LANGS[@]}"; do
  r=$(P hit "http://e2e-parent-$l:8000/charges" 400 32)
  check "set(s) <= {200,500} and 0.72 <= s.get(500,0)/n <= 0.88" "$l adopts faulty audit as 500" "$r"
done
all_audit erroring  # 50% 200, 12% 404, 25% 500, 13% 429 -> parent: 429 passes through, 404/500 -> 500
for l in "${LANGS[@]}"; do
  r=$(P hit "http://e2e-parent-$l:8000/charges" 600 32)
  check "set(s) <= {200,500,429} and 0.07 <= s.get(429,0)/n <= 0.19 and 0.30 <= s.get(500,0)/n <= 0.45" "$l throttle passes, 404->500" "$r"
done
all_audit healthy
for l in "${LANGS[@]}"; do
  r=$(P hit "http://e2e-parent-$l:8000/charges" 200 32)
  check "s == {200: n}" "$l healthy deps -> all 200" "$r"
done
# A transport failure is not propagated: a downstream that refuses every connection leaves the parent 200.
for l in "${LANGS[@]}"; do app "e2e-dead-$l" "$l" ROLE=payment PROFILE=healthy AUDIT_URLS=http://e2e-nonexistent:8000; done
for l in "${LANGS[@]}"; do ready "e2e-dead-$l"; r=$(P hit "http://e2e-dead-$l:8000/charges" 50 16)
  check "s == {200: n}" "$l unreachable dep not adopted" "$r"; done
# Checkout (Python) over the real fleet: inventory (Java) faulty -> checkout 500.
fault ping-inventory faulty
r=$(P hit http://checkout:8000/checkout 200 16); fault ping-inventory healthy
check "set(s) <= {200,500} and 0.70 <= s.get(500,0)/n <= 0.90" "fleet: checkout adopts inventory fault" "$r"

echo "== 4. DNS multi-A fan-out + PREFER_SAME_AZ"
before=(); for a in "${AUDITS[@]}"; do before+=("$(docker logs "$a" 2>&1 | grep -c 'POST /audit ')"); done
for l in "${LANGS[@]}"; do P hit "http://e2e-parent-$l:8000/charges" 150 16 >/dev/null; done
i=0; spread=""; for a in "${AUDITS[@]}"; do n=$(( $(docker logs "$a" 2>&1 | grep -c 'POST /audit ') - before[i] )); spread+="$a=$n "; i=$((i+1)); done
check "all(120 <= int(x.split('=')[1]) <= 280 for x in r['spread'].split())" "600 calls spread over 3 A records" "{\"spread\": \"$spread\"}"
# A far audit on a second network/subnet. The parent sits on both; docker picks the default gateway
# by network name, so `pingtest-far` (sorting after `pingtest`) leaves pingtest as the parent's
# primary -- its /24 is the parent's "AZ" and the far audit is out of it.
docker network inspect pingtest-far >/dev/null 2>&1 || docker network create --subnet 10.250.7.0/24 pingtest-far >/dev/null
docker rm -f e2e-far >/dev/null 2>&1
docker run -d --name e2e-far --network pingtest-far --network-alias far --memory 256m -e ROLE=audit "${IMAGE[node]}" >/dev/null
for az in 0 1; do
  for l in "${LANGS[@]}"; do
    app "e2e-az-$l" "$l" ROLE=payment PREFER_SAME_AZ=$az AUDIT_URLS=http://audit:8000,http://far:8000
    docker network connect pingtest-far "e2e-az-$l"
  done
  for l in "${LANGS[@]}"; do ready "e2e-az-$l"; done
  f0=$(docker logs e2e-far 2>&1 | grep -c 'POST /audit ')
  for l in "${LANGS[@]}"; do P hit "http://e2e-az-$l:8000/charges" 80 16 >/dev/null; done
  far=$(( $(docker logs e2e-far 2>&1 | grep -c 'POST /audit ') - f0 ))
  if [[ $az == 0 ]]; then check "30 <= r['far'] <= 130" "PREFER_SAME_AZ=0: far subnet gets ~1/4 of 320" "{\"far\": $far}"
  else check "r['far'] == 0" "PREFER_SAME_AZ=1: far subnet gets nothing" "{\"far\": $far}"; fi
done

echo "== 5. CPU_SHARE (real CPU, bounded by thread CPU time)"
for l in "${LANGS[@]}"; do
  DOCKER_ARGS="--cpus 4" app "e2e-cpu-$l" "$l" ROLE=audit PROFILE=degraded CPU_SHARE=0.5
  DOCKER_ARGS="--cpus 0.25" app "e2e-cpuslow-$l" "$l" ROLE=audit PROFILE=degraded CPU_SHARE=0.5
done
for l in "${LANGS[@]}"; do
  ready "e2e-cpu-$l"; ready "e2e-cpuslow-$l"
  expect "$l healthz cpu_share" '"cpu_share":0.5' "$(P get http://e2e-cpu-$l:8000/healthz)"
  P hit "http://e2e-cpu-$l:8000/audit" 30 2 >/dev/null
  P hit "http://e2e-cpuslow-$l:8000/audit" 12 2 >/dev/null
  for c in "e2e-cpu-$l" "e2e-cpuslow-$l"; do
    s=$(docker logs "$c" 2>&1 | grep '^cpuwork ' | python3 -c '
import re,sys,statistics as st
L=[dict(re.findall(r"(\w+)=([\w.]+)",l)) for l in sys.stdin]
print("{\"lines\":%d,\"slowdown\":%.2f,\"cpu\":%.3f}"%(len(L),st.median(float(x["slowdown"]) for x in L) if L else 0,st.median(float(x["cpu"].rstrip("s")) for x in L) if L else 0))')
    if [[ $c == e2e-cpu-* ]]; then check "r['lines'] >= 28 and 0.9 <= r['slowdown'] <= 1.6 and r['cpu'] > 0.1" "$l uncontended: slowdown ~1" "$s"
    else check "r['lines'] >= 10 and r['slowdown'] >= 3" "$l --cpus 0.25 x2 concurrent: slowdown >> 1" "$s"; fi
  done
done
# The Node burn runs off the event loop: /healthz stays fast while 4 burns are in flight.
P hit http://e2e-cpu-node:8000/audit 8 8 >/dev/null & sleep 0.3
t=$(docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -w '%{time_total}' http://e2e-cpu-node:8000/healthz); wait
check "r['t'] < 0.2" "node event loop free during burns" "{\"t\": $t}"

echo "== 6. USE_TLS=1: every language serves HTTPS, and calls an https:// downstream (self-signed)"
# Leaf in each language serves TLS with PROFILE=faulty; the parent in the NEXT language calls it over
# https and must adopt its faults -- which proves the TLS round trip in both directions.
for l in "${LANGS[@]}"; do app "e2e-tls-$l" "$l" ROLE=audit PROFILE=faulty USE_TLS=1; done
declare -A NEXT=([python]=go [go]=java [java]=node [node]=python)
for l in "${LANGS[@]}"; do app "e2e-tlsp-$l" "$l" ROLE=payment AUDIT_URLS="https://e2e-tls-${NEXT[$l]}:8000"; done
for l in "${LANGS[@]}"; do ready "e2e-tlsp-$l"; done
sleep 2
for l in "${LANGS[@]}"; do
  r=$(P hit "http://e2e-tlsp-$l:8000/charges" 150 16)
  check "set(s) <= {200,500} and 0.65 <= s.get(500,0)/n <= 0.92" "$l -> https ${NEXT[$l]} leaf (faulty) adopted" "$r"
done

echo "== cleanup"
docker rm -f $(docker ps -aq --filter name=e2e-) >/dev/null 2>&1
docker network rm pingtest-far >/dev/null 2>&1
echo "FAILS=$FAILS"; exit $(( FAILS > 0 ))
