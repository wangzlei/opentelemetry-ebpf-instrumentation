#!/usr/bin/env bash
# ping demo: install/upgrade the eBPF agent (SSM Distributor package ADOT-CloudWatchAgent-eBPF-Beta,
# shared from 292779133546) on every host (tag purpose=ping-demo). Traces AND metrics come from the
# agent's OBI receiver (etc/ebpf/obi.yaml) -- no ADOT SDK, no separate collector container.
#
#   REGION=us-west-2 ./upgrade-agent.sh [--version <versionName>] [--ids "<id> ..."]
#   REGION=us-west-2 ./upgrade-agent.sh check [--ids "<id> ..."]
#
# Steps (per host):
#  1) AWS-ConfigureAWSPackage Install, Additional Arguments {"SSM_EBPF":"true"}. A version change is
#     uninstall + install; the package carries the eBPF state across. Same version = no-op.
#  2) 10-aws-env.conf drop-in (AWS_VPC_ID/AWS_SUBNET_ID from IMDS) if missing; omni-bridge.yaml in
#     etc/amazon-cloudwatch-agent.d (bridge-config.sh) when OMNI_BRIDGE_ENDPOINT is set, removed when
#     it is empty; daemon-reload + restart the agent
#  3) docker restart ping-app-svc (OBI tracks the app's connections from process start)
#  4) check: rpm version, active, user, CapEff, ebpf, bridge, E! count
. "$(dirname "$0")/lib.sh"
VERSION="" IDS="" MODE=upgrade
while [ $# -gt 0 ]; do
  case $1 in
    check) MODE=check; shift;;
    --version) VERSION=${2:?}; shift 2;;
    --ids) IDS=${2:?}; shift 2;;
    *) sed -n '2,/^\. /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2;;
  esac
done
check_account
IDS=${IDS:-$(all_ids)}
CAPEFF_WANT=000001c0002c30e4

CHECK='A=/opt/aws/amazon-cloudwatch-agent; L=$A/logs/amazon-cloudwatch-agent.log; P=$(systemctl show -p MainPID --value amazon-cloudwatch-agent)
echo "$(rpm -q --qf "%{VERSION}" amazon-cloudwatch-agent) $(systemctl is-active amazon-cloudwatch-agent) user=$(ps -o user= -p $P 2>/dev/null) CapEff=$(awk "/^CapEff/{print \$2}" /proc/$P/status 2>/dev/null) ebpf=$($A/bin/amazon-cloudwatch-agent-ctl -a status 2>/dev/null | grep -o "\"ebpf\": *\"[a-z]*\"" | grep -o "[a-z]*\"$" | tr -d "\"") vpcenv=$(tr "\0" "\n" < /proc/$P/environ 2>/dev/null | grep -c "^AWS_VPC_ID=vpc-") bridge=$([ -f $A/etc/amazon-cloudwatch-agent.d/omni-bridge.yaml ] && grep -o "http[^ ]*/v1/metrics" $A/etc/amazon-cloudwatch-agent.d/omni-bridge.yaml || echo off) E=$(grep -c "E!" $L 2>/dev/null)"'

if [ "$MODE" = check ]; then
  ssm_run "$CHECK" $IDS | sed "s/CapEff=$CAPEFF_WANT/CapEff=$CAPEFF_WANT(ok)/"
  exit
fi

T0=$SECONDS
DEF=$(aws ssm describe-document --name "$PKG_ARN" --query 'Document.[DefaultVersion,VersionName]' --output text | tr '\t' ' ')
log "1) Distributor Install $PKG_ARN ${VERSION:-(default: doc $DEF)} SSM_EBPF=true on $(echo "$IDS" | wc -w) hosts"
PARAMS="{\"action\":[\"Install\"],\"name\":[\"$PKG_ARN\"],\"additionalArguments\":[\"{\\\"SSM_EBPF\\\":\\\"true\\\"}\"]"
[ -n "$VERSION" ] && PARAMS="$PARAMS,\"version\":[\"$VERSION\"]"
PARAMS="$PARAMS}"
# shellcheck disable=SC2086
c=$(aws ssm send-command --document-name AWS-ConfigureAWSPackage --instance-ids $IDS --parameters "$PARAMS" \
  --timeout-seconds 900 --query Command.CommandId --output text)
sleep 10
if ! TAIL=2 ssm_wait "$c" $IDS; then
  # Seen on ping-payment-2 (2026-10-13): Distributor could not fetch the OLD version's manifest
  # ("InvalidDocumentVersion: Not authorized to request version: 7" -- the share covers $DEFAULT
  # only), skipped the old uninstall, and install.sh's rpm -U then refused the "downgrade"
  # (release obi.cad3cf5 sorts above obi.be9a187). Recovery = the package's uninstall.sh by hand
  # (keeps the eBPF state in etc/ebpf/enabled.reinstall), then Install again.
  FAILED=$(aws ssm list-command-invocations --command-id "$c" --query "CommandInvocations[?Status!='Success'].InstanceId" --output text)
  log "1b) Install failed on $FAILED: erase the old rpm like uninstall.sh, then Install again"
  ssm_run 'A=/opt/aws/amazon-cloudwatch-agent; $A/bin/amazon-cloudwatch-agent-ctl -a prep-restart || true
[ -f $A/etc/ebpf/enabled ] && touch $A/etc/ebpf/enabled.reinstall
$A/bin/amazon-cloudwatch-agent-ctl -a stop || true; rpm -e amazon-cloudwatch-agent && echo erased' $FAILED
  # shellcheck disable=SC2086
  c=$(aws ssm send-command --document-name AWS-ConfigureAWSPackage --instance-ids $FAILED --parameters "$PARAMS" \
    --timeout-seconds 900 --query Command.CommandId --output text)
  sleep 10; TAIL=2 ssm_wait "$c" $FAILED
fi

log "2) VPC/subnet drop-in (if missing) + omni bridge config (${OMNI_BRIDGE_ENDPOINT:-off}) + agent restart"
ssm_run "set -e
D=/etc/systemd/system/amazon-cloudwatch-agent.service.d; F=\$D/10-aws-env.conf
if [ -s \$F ] && grep -q AWS_VPC_ID=vpc- \$F; then echo 'drop-in present'; else
T=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
MD=http://169.254.169.254/latest/meta-data; MAC=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" \$MD/mac)
VPC=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" \$MD/network/interfaces/macs/\$MAC/vpc-id)
SUB=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" \$MD/network/interfaces/macs/\$MAC/subnet-id)
mkdir -p \$D; printf '[Service]\nEnvironment=AWS_VPC_ID=%s AWS_SUBNET_ID=%s\n' \"\$VPC\" \"\$SUB\" > \$F; echo 'drop-in written'; fi
$("$DEPLOY_DIR/bridge-config.sh" --script)
systemctl daemon-reload && systemctl restart amazon-cloudwatch-agent
sleep 15; systemctl is-active amazon-cloudwatch-agent" $IDS

log "3) docker restart $APP"
ssm_run "docker restart $APP >/dev/null && docker ps --filter name=^$APP\$ --format '{{.Names}} {{.Status}}'" $IDS

log "4) check (want CapEff=$CAPEFF_WANT)"
ssm_run "$CHECK" $IDS | sed "s/CapEff=$CAPEFF_WANT/CapEff=$CAPEFF_WANT(ok)/"
echo "total time: $(( (SECONDS-T0)/60 ))m$(( (SECONDS-T0)%60 ))s"
