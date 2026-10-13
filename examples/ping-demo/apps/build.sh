#!/usr/bin/env bash
# Build the four polyglot ping-demo images (linux/amd64) and, with --push, push them to ECR.
#   ./build.sh            # local tags ping-demo-apps:<role>-<lang>-omni-<sha>
#   ./build.sh --push     # also tag + push to $REGISTRY/ping-demo-apps
# <sha> = short sha of the current HEAD of this repo (override with TAG_SHA=...).
set -euo pipefail
cd "$(dirname "$0")"
REGISTRY=${REGISTRY:-292779133546.dkr.ecr.us-west-2.amazonaws.com}
REPO=${REPO:-ping-demo-apps}
SHA=${TAG_SHA:-$(git rev-parse --short=7 HEAD)}
PUSH=0; [[ "${1:-}" == "--push" ]] && PUSH=1

declare -A DIRS=(
  [checkout-python]=checkout-python
  [payment-go]=payment-go
  [inventory-java]=inventory-java
  [audit-node]=audit-node
)
if (( PUSH )); then
  region=$(echo "$REGISTRY" | cut -d. -f4)
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$REGISTRY"
fi
for name in checkout-python payment-go inventory-java audit-node; do
  tag="${name}-omni-${SHA}"
  echo "=== build $REPO:$tag"
  docker build --platform linux/amd64 -t "$REPO:$tag" "${DIRS[$name]}"
  if (( PUSH )); then
    docker tag "$REPO:$tag" "$REGISTRY/$REPO:$tag"
    docker push "$REGISTRY/$REPO:$tag"
  fi
done
docker images "$REPO" --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep "omni-${SHA}"
