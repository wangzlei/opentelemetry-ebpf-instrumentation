#!/usr/bin/env bash
# ping demo: free disk on every host (tag purpose=ping-demo) without touching running containers.
#
#   REGION=us-west-2 ./cleanup-disk.sh          # cleanup + report
#   REGION=us-west-2 ./cleanup-disk.sh report   # report only
#
# Per host:
#  1) docker rm the STOPPED rollback containers ping-collector / ping-collector-old (their json logs
#     go with them); a running container of that name is left alone
#  2) docker image prune -af (never removes an image a container uses) + docker builder prune -af
#  3) /etc/docker/daemon.json with json-file rotation (50m x 3) if there is none. dockerd is NOT
#     restarted: it applies on the next dockerd start; containers created by redeploy-apps.sh carry
#     the same --log-opt explicitly, so they rotate now.
# Prints disk before/after, the json log sizes of the running containers and the remaining images.
. "$(dirname "$0")/lib.sh"
check_account
MODE=${1:-cleanup}

REPORT='echo "disk=$(df --output=used,pcent -h / | tail -1 | tr -s " ") images=$(docker images -q | sort -u | wc -l) logs=$(for c in $(docker ps -q); do echo -n "$(docker inspect -f "{{.Name}}" $c | tr -d /):$(du -h $(docker inspect -f "{{.LogPath}}" $c) 2>/dev/null | cut -f1),"; done)"'

CLEAN='set -e
echo "before: $(df --output=used,pcent -h / | tail -1 | tr -s " ")"
for c in ping-collector ping-collector-old; do
  st=$(docker inspect -f "{{.State.Status}}" $c 2>/dev/null || true)
  if [ -n "$st" ] && [ "$st" != running ]; then docker rm $c >/dev/null && echo "rm $c ($st)"; fi
done
docker image prune -af >/dev/null
docker builder prune -af >/dev/null 2>&1 || true
if [ ! -s /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  echo "{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"50m\",\"max-file\":\"3\"}}" > /etc/docker/daemon.json
  echo "daemon.json written (applies at next dockerd start)"
fi
echo "after: $(df --output=used,pcent -h / | tail -1 | tr -s " ")"
'
IDS=$(all_ids)
if [ "$MODE" = cleanup ]; then
  log "cleanup on $(echo "$IDS" | wc -w) hosts"
  TAIL=6 ssm_run "$CLEAN" $IDS
fi
log "report"
ssm_run "$REPORT" $IDS
