#!/usr/bin/env bash
# Run the local adot-obi collector against the ./fleet.sh fleet for ~60 s (with traffic) and print
# the service.name of every server span it saw, per executable. No AWS access needed.
#   COLLECTOR=otelcol-obi:v0.12.2-<sha> ./autoname.sh
set -euo pipefail
cd "$(dirname "$0")"
COLLECTOR=${COLLECTOR:-$(docker images otelcol-obi --format '{{.Repository}}:{{.Tag}}' | grep -m1 'v0.12.2-')}
docker rm -f ping-autoname >/dev/null 2>&1 || true
docker run -d --name ping-autoname --privileged --pid host --network host \
  -v /sys/fs/bpf:/sys/fs/bpf -v /sys:/sys -v /proc:/proc:ro \
  -v "$PWD/autoname.yaml:/etc/otelcol/config.yaml:ro" "$COLLECTOR" --config=/etc/otelcol/config.yaml >/dev/null
echo "collector $COLLECTOR started; restarting the apps so discovery sees them start"
sleep 15
docker restart ping-checkout ping-payment-{1,2,3} ping-inventory ping-audit-{1,2,3} >/dev/null
docker rm -f ping-autoname-traffic >/dev/null 2>&1 || true
docker run -d --name ping-autoname-traffic --network pingtest --entrypoint /bin/sh curlimages/curl:latest -c \
  'sleep 5; while true; do curl -s -m 15 -X POST http://checkout:8000/checkout >/dev/null; sleep 0.5; done' >/dev/null
sleep "${WAIT:-60}"
docker logs ping-autoname > "${LOG:-/tmp/ping-autoname.log}" 2>&1
echo "service.name per batch of spans (expect checkout_api, payment, inventory, audit-worker):"
grep -oE 'service\.name: Str\([^)]*\)' "${LOG:-/tmp/ping-autoname.log}" | sort | uniq -c
docker rm -f ping-autoname-traffic >/dev/null
# The collector can linger as a zombie for a few seconds after SIGTERM; retry the removal.
docker stop -t 20 ping-autoname >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6; do docker rm -f ping-autoname >/dev/null 2>&1 && break; sleep 5; done
