#!/usr/bin/env bash
# ping demo: recreate the app container ping-app-svc on every host (SSM), per role, downstream first.
#
#   REGION=us-west-2 ./redeploy-apps.sh <sfx>     polyglot "omni" images from ECR
#                                                 $ECR_ACCOUNT.dkr.ecr.<region>.amazonaws.com/ping-demo-apps,
#                                                 tag <role>-<lang>-omni-<sfx> (e.g. inventory-java-omni-1a2b3c4);
#                                                 <sfx>=latest: newest *-omni-* tag per role.
#                                                 NO OTEL_SERVICE_NAME: names come from the images/OBI.
#   REGION=us-west-2 ./redeploy-apps.sh local     keep each host's CURRENT image and its OTEL_SERVICE_NAME,
#                                                 only re-wire the env below (old single Python app)
#   ROLES="inventory" ./redeploy-apps.sh ...      only these roles (default: audit inventory payment checkout)
#   IMG_INVENTORY=<image> ./redeploy-apps.sh ...  override one role's image (IMG_CHECKOUT/PAYMENT/AUDIT)
#   --dry-run                                     print the per-role host script, change nothing
#
# Wiring (both modes; lei's latest design):
#   checkout  PAYMENT_URLS = INVENTORY_URLS = http://backend.alb.internal:8000 (shared ALB, path routing)
#   payment   AUDIT_URLS=http://audit.$ZONE:8000 PREFER_SAME_AZ=1
#   inventory STOCK_URL=<apigw.sh url> (API Gateway -> Lambda), when the API exists
#   audit     leaf
# plus ROLE, PROFILE=healthy, PORT=8000, USE_TLS=0, json-file log rotation 50m x 3 (--log-opt, so no
# dockerd restart is needed). The traffic container ping-traffic on checkout is left as is; the agent
# is not touched. After `docker run` the container is restarted once (as lei/install-agent.sh), so a
# running OBI tracks its connections from process start.
. "$(dirname "$0")/lib.sh"
ECR_ACCOUNT=${ECR_ACCOUNT:-292779133546}
ECR_REGION=${ECR_REGION:-$AWS_REGION}   # us-east-1 pulls cross-region from us-west-2 (env file)
ECR=$ECR_ACCOUNT.dkr.ecr.$ECR_REGION.amazonaws.com
REPO=ping-demo-apps
O_CHECKOUT=${IMG_CHECKOUT:-} O_PAYMENT=${IMG_PAYMENT:-} O_INVENTORY=${IMG_INVENTORY:-} O_AUDIT=${IMG_AUDIT:-}
ROLES=${ROLES:-$ROLES_ALL}
DRY=0 SFX=""
for a in "$@"; do case $a in --dry-run) DRY=1;; -*) echo "unknown option $a" >&2; exit 2;; *) SFX=$a;; esac; done
[ -n "$SFX" ] || { sed -n '2,/^\. /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }
check_account

# ECR lives in $ECR_ACCOUNT: query it with ada credentials for that account (subshell only).
ecr_tags() {
  (
    unset AWS_PROFILE
    eval "$(~/.toolbox/bin/ada credentials print --account "$ECR_ACCOUNT" --role Admin --provider isengard 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("export AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s" % (d["AccessKeyId"], d["SecretAccessKey"], d["SessionToken"]))')"
    aws ecr describe-images --region $ECR_REGION --repository-name $REPO --query 'sort_by(imageDetails,&imagePushedAt)[].imageTags[]' --output text | tr '\t' '\n'
  )
}

img_for() {  # img_for <role> -> image ref, or "" if not found
  local o="O_$(echo "$1" | tr a-z A-Z)"
  [ -n "${!o}" ] && { echo "${!o}"; return; }
  [ "$SFX" = local ] && { echo LOCAL; return; }
  local t
  if [ "$SFX" = latest ]; then t=$(echo "$TAGS" | grep -E "^$1-[a-z0-9]+-omni-[0-9a-f]+$" | tail -1 || true)
  else t=$(echo "$TAGS" | grep -E "^$1-[a-z0-9]+-omni-$SFX$" | tail -1 || true); fi
  [ -z "$t" ] || echo "$ECR/$REPO:$t"
}

role_env() {  # role_env <role>
  case $1 in
    checkout)  echo "-e ROLE=checkout -e PAYMENT_URLS=http://$BACKEND:8000 -e INVENTORY_URLS=http://$BACKEND:8000";;
    payment)   echo "-e ROLE=payment -e AUDIT_URLS=http://audit.$ZONE:8000 -e PREFER_SAME_AZ=1";;
    inventory) echo "-e ROLE=inventory${STOCK_URL:+ -e STOCK_URL=$STOCK_URL}";;
    audit)     echo "-e ROLE=audit";;
  esac
}

app_script() {  # app_script <role> <image|LOCAL>
  local env; env="$(role_env "$1") -e PROFILE=healthy -e PORT=8000 -e USE_TLS=0"
  if [ "$2" = LOCAL ]; then cat <<EOF
set -e
IMG=\$(docker inspect -f '{{.Config.Image}}' $APP)
SVC=\$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $APP | sed -n 's/^OTEL_SERVICE_NAME=//p')
SVCENV=\${SVC:+-e OTEL_SERVICE_NAME=\$SVC}
EOF
  else cat <<EOF
set -e
IMG=$2; SVCENV=""
aws ecr get-login-password --region $ECR_REGION | docker login --username AWS --password-stdin $ECR >/dev/null
docker pull -q \$IMG >/dev/null
EOF
  fi
  cat <<EOF
docker rm -f $APP >/dev/null 2>&1 || true
docker run -d --name $APP --restart unless-stopped --network host --log-opt max-size=50m --log-opt max-file=3 \\
  $env \$SVCENV \$IMG >/dev/null
docker restart $APP >/dev/null
sleep 5
echo "img=\$(docker inspect -f '{{.Config.Image}}' $APP) svcenv=\$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $APP | grep -c '^OTEL_SERVICE_NAME=') healthz=\$(curl -s -m 3 -o /dev/null -w '%{http_code}' localhost:8000/healthz) \$(docker ps --format '{{.Names}}={{.Status}}' | tr '\n' ' ')"
EOF
}

[ "$SFX" = local ] || TAGS=$(ecr_tags)
STOCK_URL=${STOCK_URL-$("$DEPLOY_DIR/apigw.sh" url 2>/dev/null || true)}
# fail before touching any host if an image is missing
for role in $ROLES; do
  img=$(img_for "$role")
  [ -n "$img" ] || { echo "STOP: no image for $role (want $role-<lang>-omni-$SFX in $ECR/$REPO)"; exit 3; }
  eval "IMG_$(echo "$role" | tr a-z A-Z)=\$img"
done
log "mode=$SFX roles=[$ROLES] STOCK_URL=${STOCK_URL:-none}"
for role in $ROLES; do
  v="IMG_$(echo "$role" | tr a-z A-Z)"; ids=$(ids_by_role "$role")
  if [ $DRY = 1 ]; then echo "--- $role ($ids) ${!v}"; app_script "$role" "${!v}"; continue; fi
  log "app $role -> ${!v} on $(echo "$ids" | wc -w) hosts"
  TAIL=1 ssm_run "$(app_script "$role" "${!v}")" $ids
done
