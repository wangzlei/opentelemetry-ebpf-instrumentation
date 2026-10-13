# shellcheck shell=bash
# Common helpers for the ping demo deploy scripts. Source it from a bash script:
#   . "$(dirname "$0")/lib.sh"      (REGION=us-west-2 by default; REGION=us-east-1 for the Omni rig)
# Hosts are found by tag purpose=ping-demo + ping-role=<role>, so the same scripts work on the
# us-west-2 rig (unique Name tags) and the us-east-1 rig (Name repeated per role).
set -euo pipefail
DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REGION=${REGION:-us-west-2}
[ -f "$DEPLOY_DIR/env/$REGION.env" ] || { echo "no env/$REGION.env" >&2; exit 2; }
# shellcheck disable=SC1090
. "$DEPLOY_DIR/env/$REGION.env"
export AWS_REGION=$REGION AWS_PAGER=""
# Named profile unless the caller already exported credentials (e.g. ada credentials print).
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then export AWS_PROFILE=${AWS_PROFILE:-$PROFILE}; fi
ROLES_ALL="audit inventory payment checkout"   # downstream first
APP=ping-app-svc                               # app container name on every host
BACKEND=backend.alb.internal                   # shared ALB name (private zone alb.internal)

log() { echo "[$(date +%H:%M:%S)] $*"; }
none() { [ -z "${1:-}" ] || [ "$1" = None ] || [ "$1" = null ]; }
check_account() {
  [ "$(aws sts get-caller-identity --query Account --output text)" = "$ACCOUNT" ] \
    || { echo "wrong account (need $ACCOUNT)" >&2; exit 1; }
}

# ids_by_role <role>: running instance ids with ping-role=<role>
ids_by_role() {
  aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$TAG_VAL" "Name=tag:ping-role,Values=$1" \
    Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text
}
all_ids() {
  aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$TAG_VAL" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
name_of() {
  aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' --output text
}

# ssm_send <script> <instance-id>... -> command id (AWS-RunShellScript)
ssm_send() {
  local s=$1; shift
  local p; p=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["1800"]}))' "$s")
  # shellcheck disable=SC2068
  aws ssm send-command --document-name AWS-RunShellScript --instance-ids $@ --parameters "$p" \
    --timeout-seconds 600 --query Command.CommandId --output text
}
# ssm_wait <command-id> <instance-id>... ; prints "name id status: <last TAIL lines>"; rc 1 on any failure
ssm_wait() {
  local c=$1 rc=0 id; shift
  # shellcheck disable=SC2068
  for id in $@; do
    local st=Pending
    for _ in $(seq 1 240); do
      st=$(aws ssm get-command-invocation --command-id "$c" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case $st in Success|Failed|TimedOut|Cancelled) break;; esac; sleep 5
    done
    local out; out=$(aws ssm get-command-invocation --command-id "$c" --instance-id "$id" \
      --query StandardOutputContent --output text 2>/dev/null | sed "/^[[:space:]]*$/d" | tail -"${TAIL:-3}")
    printf '  %-16s %-20s %-8s %s\n' "$(name_of "$id")" "$id" "$st" "$(echo "$out" | tr '\n' ' ')"
    [ "$st" = Success ] || rc=1
  done
  return $rc
}
# ssm_run <script> <instance-id>... : send + wait
ssm_run() { local s=$1; shift; local c; c=$(ssm_send "$s" "$@"); ssm_wait "$c" "$@"; }
