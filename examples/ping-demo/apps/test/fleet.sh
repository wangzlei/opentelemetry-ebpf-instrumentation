#!/usr/bin/env bash
# Local end-to-end fleet for the polyglot apps on one docker network (`pingtest`):
#   checkout (Python) x1, payment (Go) x3, inventory (Java) x1, audit (Node) x3.
# Docker's embedded DNS returns every container sharing a network alias, so `payment` and `audit`
# resolve to three A records each -- the shape of the Route 53 multivalue records on EC2.
# No OTEL_SERVICE_NAME anywhere.
#   TAG=<sha> ./fleet.sh up [--traffic]    images ping-demo-apps:<role>-<lang>-omni-$TAG (default dev)
#   ./fleet.sh down
# Per-role profile/CPU overrides: CHECKOUT_PROFILE, PAYMENT_PROFILE, INVENTORY_PROFILE, AUDIT_PROFILE,
# and CPU_SHARE (applied to every service).
set -euo pipefail
TAG=${TAG:-dev}
IMG=${IMG:-ping-demo-apps}
NET=pingtest

run() { # name alias image env...
  local name=$1 alias=$2 image=$3; shift 3
  local envs=(); for e in "$@"; do envs+=(-e "$e"); done
  docker run -d --name "$name" --network "$NET" --network-alias "$alias" --memory 256m \
    -e CPU_SHARE="${CPU_SHARE:-0}" "${envs[@]}" "$image" >/dev/null
  echo "started $name ($image)"
}

case "${1:-}" in
  up)
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
    run ping-checkout checkout "$IMG:checkout-python-omni-$TAG" ROLE=checkout PROFILE="${CHECKOUT_PROFILE:-healthy}" \
      PAYMENT_URLS=http://payment:8000 INVENTORY_URLS=http://inventory:8000
    for i in 1 2 3; do
      run "ping-payment-$i" payment "$IMG:payment-go-omni-$TAG" ROLE=payment PROFILE="${PAYMENT_PROFILE:-healthy}" \
        AUDIT_URLS=http://audit:8000
    done
    run ping-inventory inventory "$IMG:inventory-java-omni-$TAG" ROLE=inventory PROFILE="${INVENTORY_PROFILE:-healthy}"
    for i in 1 2 3; do
      run "ping-audit-$i" audit "$IMG:audit-node-omni-$TAG" ROLE=audit PROFILE="${AUDIT_PROFILE:-healthy}"
    done
    if [[ "${2:-}" == "--traffic" ]]; then
      # Same generator as examples/ping-demo/docker-compose.yaml: one POST /checkout per second.
      docker run -d --name ping-traffic --network "$NET" --entrypoint /bin/sh curlimages/curl:latest -c \
        'sleep 5; while true; do curl -s -m 15 -X POST http://checkout:8000/checkout >/dev/null; sleep 1; done' >/dev/null
      echo "started ping-traffic"
    fi
    ;;
  down)
    docker rm -f ping-checkout ping-payment-{1,2,3} ping-inventory ping-audit-{1,2,3} ping-traffic 2>/dev/null | wc -l
    ;;
  *) echo "usage: $0 up [--traffic] | down" >&2; exit 2 ;;
esac
