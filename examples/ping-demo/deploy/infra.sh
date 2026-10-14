#!/usr/bin/env bash
# ping demo infra on top of an EXISTING ping rig (VPC, SG, instance profile, zone, 8 hosts):
#
#   REGION=us-west-2 ./infra.sh hosts    # launch NEW_HOSTS (env/<region>.env) if missing, seed the app
#                                        # (copy of the role's ping-app image via S3) + install the agent
#   REGION=us-west-2 ./infra.sh alb      # shared internal ALB + TGs + path rules, private zone
#                                        # alb with backend.alb -> ALB
#   REGION=us-west-2 ./infra.sh dns      # host A records in $ZONE (audit/inventory/checkout = all IPs)
#   REGION=us-west-2 ./infra.sh probe    # curl the ALB paths from the checkout host
#   REGION=us-west-2 ./infra.sh all      # hosts, alb, dns, probe
#
# Idempotent: hosts by Name tag, ALB/TG by name, zone by name on the VPC. Every resource gets the tag
# purpose=ping-demo. ALB design = lei (demo/lei/up.sh infra_alb): ONE internal ALB in front of payment
# AND inventory, reached through ONE name backend.alb:8000, routed by path
# (/charges -> payment TG, /reservations -> inventory TG, default 404), health check GET /healthz.
# Every backend therefore sees Host: backend.alb:8000, which is what the client RED
# server.address and the server RED peer.service.name (X-Forwarded-Host/Host) join on.
. "$(dirname "$0")/lib.sh"
check_account
ALB_NAME=$PFX-backend-alb
ALB_SG_NAME=$PFX-backend-alb-sg
IMG_BUCKET=${IMG_BUCKET:-ping-demo-img-$ACCOUNT-usw2}   # instance role may Put/Get here (ping-demo-img-s3)

USER_DATA='#!/bin/bash
set -eux
dnf install -y docker iproute-tc
mkdir -p /etc/docker
echo "{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"50m\",\"max-file\":\"3\"}}" > /etc/docker/daemon.json
systemctl enable --now docker
touch /var/lib/ping-docker-ready'

tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=$TAG_KEY,Value=$TAG_VAL}${3:-}]"; }

# ---------------------------------------------------------------- hosts
hosts() {
  local h name sn role new=""
  for h in $NEW_HOSTS; do
    IFS=: read -r name sn role <<< "$h"
    local id; id=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PFX-$name" "Name=tag:$TAG_KEY,Values=$TAG_VAL" \
      Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
    if none "$id"; then
      local az; az=$(aws ec2 describe-subnets --subnet-ids "$sn" --query 'Subnets[0].AvailabilityZone' --output text)
      id=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$ITYPE" --subnet-id "$sn" \
        --security-group-ids "$APP_SG" --iam-instance-profile Name="$INSTANCE_PROFILE" \
        --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
        --user-data "$USER_DATA" \
        --tag-specifications "$(tags instance "$PFX-$name" ",{Key=ping-role,Value=$role},{Key=ping-az,Value=$az}")" \
          "$(tags volume "$PFX-$name")" "$(tags network-interface "$PFX-$name")" \
        --query 'Instances[0].InstanceId' --output text)
      log "launched $PFX-$name $id ($role, $sn $az)"
      new="$new $id"
    else
      log "exists $PFX-$name $id"
    fi
  done
  [ -n "$new" ] || { log "no new hosts"; return 0; }
  # shellcheck disable=SC2086
  aws ec2 wait instance-status-ok --instance-ids $new
  for _ in $(seq 1 60); do
    local n; n=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$(echo $new | tr ' ' ,)" \
      --query "length(InstanceInformationList[?PingStatus=='Online'])" --output text)
    [ "$n" -ge "$(echo $new | wc -w)" ] && break; sleep 10
  done
  seed_app "$new"
  # shellcheck disable=SC2086
  "$DEPLOY_DIR/upgrade-agent.sh" --ids "$(echo $new)"
}

# seed_app "<new ids>": run the role's CURRENT app on new hosts: docker save the ping-app image of an
# existing host of the same role -> S3 -> docker load, and the same container env (+ log rotation).
seed_app() {
  local id
  for id in $1; do
    local role src; role=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].Tags[?Key==`ping-role`]|[0].Value' --output text)
    src=$(for i in $(ids_by_role "$role"); do echo "$i"; done | grep -v "$id" | head -1)
    local key=ping-app/$role-$src.tar.gz
    log "seed $id ($role) from $src via s3://$IMG_BUCKET/$key"
    TAIL=1 ssm_run "set -e; img=\$(docker inspect -f '{{.Config.Image}}' $APP)
aws s3 ls s3://$IMG_BUCKET/$key >/dev/null 2>&1 || docker save \$img | gzip | aws s3 cp - s3://$IMG_BUCKET/$key
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $APP | grep -E '^(ROLE|PROFILE|OTEL_SERVICE_NAME|PORT|USE_TLS|CPU_SHARE|[A-Z]+_URLS)=' > /tmp/app.env
aws s3 cp /tmp/app.env s3://$IMG_BUCKET/$key.env >/dev/null; echo \"\$img \$(tr '\n' ' ' < /tmp/app.env)\"" "$src"
    TAIL=1 ssm_run "set -e; for i in \$(seq 1 60); do [ -f /var/lib/ping-docker-ready ] && systemctl is-active -q docker && break; sleep 5; done
img=\$(aws s3 cp s3://$IMG_BUCKET/$key - | gunzip | docker load | sed -n 's/^Loaded image: //p' | tail -1)
aws s3 cp s3://$IMG_BUCKET/$key.env /opt/ping-app.env >/dev/null
docker rm -f $APP >/dev/null 2>&1 || true
docker run -d --name $APP --restart unless-stopped --network host --log-opt max-size=50m --log-opt max-file=3 --env-file /opt/ping-app.env \$img >/dev/null
sleep 3; curl -s -m 3 localhost:8000/healthz | head -c 120" "$id"
  done
}

# ---------------------------------------------------------------- ALB
alb() {
  # ALB_SG set in env/<region>.env = reuse that SG (us-east-1: the app SG only admits itself).
  local sg=${ALB_SG:-}
  none "$sg" && sg=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$ALB_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if none "$sg"; then
    sg=$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$ALB_SG_NAME" \
      --description "ping demo shared internal ALB: tcp 8000 from $VPC_CIDR" \
      --tag-specifications "$(tags security-group "$ALB_SG_NAME")" --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 8000 --cidr "$VPC_CIDR" >/dev/null
    log "created SG $ALB_SG_NAME $sg"
  fi
  tg() {  # tg <name> <role> -> target group ARN (created; all hosts of <role> registered)
    local arn; arn=$(aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
    if none "$arn"; then
      arn=$(aws elbv2 create-target-group --name "$1" --protocol HTTP --port 8000 --vpc-id "$VPC_ID" \
        --target-type instance --health-check-protocol HTTP --health-check-path /healthz --health-check-port traffic-port \
        --health-check-interval-seconds 10 --tags "Key=$TAG_KEY,Value=$TAG_VAL" --query 'TargetGroups[0].TargetGroupArn' --output text)
      log "created TG $1" >&2
    fi
    aws elbv2 modify-target-group-attributes --target-group-arn "$arn" \
      --attributes Key=load_balancing.algorithm.type,Value=weighted_random >/dev/null
    # shellcheck disable=SC2046
    aws elbv2 register-targets --target-group-arn "$arn" --targets $(for i in $(ids_by_role "$2"); do echo "Id=$i,Port=8000"; done)
    echo "$arn"
  }
  local tg_pay tg_inv; tg_pay=$(tg "$PFX-backend-payment-tg" payment); tg_inv=$(tg "$PFX-backend-inventory-tg" inventory)
  local arn; arn=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  if none "$arn"; then
    # shellcheck disable=SC2086
    arn=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internal \
      --subnets $ALB_SUBNETS --security-groups "$sg" --tags "Key=$TAG_KEY,Value=$TAG_VAL" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    log "created ALB $arn"
  fi
  local lis; lis=$(aws elbv2 describe-listeners --load-balancer-arn "$arn" --query 'Listeners[0].ListenerArn' --output text)
  if none "$lis"; then
    lis=$(aws elbv2 create-listener --load-balancer-arn "$arn" --protocol HTTP --port 8000 \
      --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"404","ContentType":"text/plain","MessageBody":"no route"}}]' \
      --tags "Key=$TAG_KEY,Value=$TAG_VAL" --query 'Listeners[0].ListenerArn' --output text)
    log "created listener :8000 (default 404)"
  fi
  rule() {  # rule <priority> <path> <tg-arn>
    if [ "$(aws elbv2 describe-rules --listener-arn "$lis" --query "length(Rules[?Priority=='$1'])")" = 0 ]; then
      aws elbv2 create-rule --listener-arn "$lis" --priority "$1" --tags "Key=$TAG_KEY,Value=$TAG_VAL" \
        --conditions "Field=path-pattern,Values=$2" --actions Type=forward,TargetGroupArn="$3" >/dev/null
      log "rule $1: $2 -> $3"
    fi
  }
  rule 10 '/charges*' "$tg_pay"
  rule 20 '/reservations*' "$tg_inv"
  aws elbv2 wait load-balancer-available --load-balancer-arns "$arn"
  local dns zone; read -r dns zone < <(aws elbv2 describe-load-balancers --load-balancer-arns "$arn" \
    --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text)

  # private zone $BACKEND_ZONE on the rig's VPC, record $BACKEND -> ALB (alias)
  local zid; zid=$(aws route53 list-hosted-zones-by-vpc --vpc-id "$VPC_ID" --vpc-region "$AWS_REGION" \
    --query "HostedZoneSummaries[?Name=='$BACKEND_ZONE.'].HostedZoneId | [0]" --output text)
  if none "$zid"; then
    zid=$(aws route53 create-hosted-zone --name $BACKEND_ZONE --caller-reference "$PFX-demo-alb-$(date +%s)" \
      --vpc VPCRegion="$AWS_REGION",VPCId="$VPC_ID" --hosted-zone-config Comment="ping demo shared ALB",PrivateZone=true \
      --query HostedZone.Id --output text)
    zid=${zid#/hostedzone/}
    aws route53 change-tags-for-resource --resource-type hostedzone --resource-id "$zid" --add-tags "Key=$TAG_KEY,Value=$TAG_VAL"
    log "created zone $BACKEND_ZONE $zid"
  fi
  aws route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$BACKEND\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$zone\",\"DNSName\":\"$dns\",\"EvaluateTargetHealth\":false}}}]}" >/dev/null
  log "ALB $ALB_NAME $arn sg=$sg"
  log "  TG payment $tg_pay"
  log "  TG inventory $tg_inv"
  log "  zone $BACKEND_ZONE $zid: $BACKEND -> $dns"
  for t in "$tg_pay" "$tg_inv"; do
    aws elbv2 describe-target-health --target-group-arn "$t" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | tr '\n' ' '; echo
  done
}

# ---------------------------------------------------------------- DNS (host records)
dns() {
  local role batch="" ips
  for role in audit inventory checkout; do
    # shellcheck disable=SC2046
    ips=$(aws ec2 describe-instances --instance-ids $(ids_by_role $role) --query 'Reservations[].Instances[].PrivateIpAddress' --output text)
    batch="$batch{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$role.$ZONE\",\"Type\":\"A\",\"TTL\":10,\"ResourceRecords\":[$(for i in $ips; do echo -n "{\"Value\":\"$i\"},"; done | sed 's/,$//')]}},"
    log "$role.$ZONE -> $ips"
  done
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{\"Comment\":\"ping demo\",\"Changes\":[${batch%,}]}" >/dev/null
}

probe() {  # from the checkout host: 404 default, /charges and /reservations through the ALB
  TAIL=4 ssm_run "getent hosts $BACKEND | head -3 | tr '\n' ' '; echo
for p in /nope /charges /reservations; do echo \"\$p -> \$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST http://$BACKEND:8000\$p)\"; done | tr '\n' ' '" "$(ids_by_role checkout)"
}

case ${1:-} in
  hosts) hosts;; alb) alb;; dns) dns;; probe) probe;;
  all) hosts; alb; dns; probe;;
  *) sed -n '2,/^\. /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2;;
esac
