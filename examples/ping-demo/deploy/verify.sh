#!/usr/bin/env bash
# ping demo: end-to-end check of the agent, CloudWatch RED, the topology join and X-Ray.
#
#   REGION=us-west-2 ./verify.sh [window, default 5m]
#
#  1) per-host agent state (upgrade-agent.sh check)
#  2) server RED by service (+ by service/subnet/instance: aws.subnet.id slicing) and by http.route
#  3) client RED edges: service -> server.address / peer.service.name / http.route, and the join
#     client server.address == server peer.service.name (both backend.alb.internal:8000 via the ALB)
#  4) X-Ray service graph (all services + APIGW stage + Lambda), Lambda invocations/errors
# Everything is filtered by @resource.aws.vpc.id = the rig's VPC (other demos share the account).
. "$(dirname "$0")/lib.sh"
check_account
W=${1:-5m}

log "1) agent"
"$DEPLOY_DIR/upgrade-agent.sh" check

log "2-3) CloudWatch RED (window $W, vpc $VPC_ID)"
VPC_ID=$VPC_ID W=$W python3 - "$DEPLOY_DIR" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
from cwq import query
vpc, w = os.environ["VPC_ID"], os.environ["W"]

def q(metric, by, extra=""):
    by_s = ",".join(f'"{b}"' for b in by)
    r = query(f'sum by ({by_s}) (histogram_count(sum_over_time({{"__name__"="{metric}","@resource.aws.vpc.id"="{vpc}"{extra}}}[{w}])))')
    if r.get("status") != "success":
        print("  query failed:", r); return []
    return sorted(([x["metric"].get(b, "-") for b in by], float(x["value"][1])) for x in r["data"]["result"])

def show(title, rows):
    print(f"  {title}")
    for k, v in rows:
        print(f"    {v:8.0f}  " + "  ".join(k))

S = "http.server.request.duration"; C = "http.client.request.duration"
show("server RED by service", q(S, ["@resource.service.name"]))
show("server RED by service / subnet / instance", q(S, ["@resource.service.name", "@resource.aws.subnet.id", "@resource.ec2.instance.id"]))
srv = q(S, ["@resource.service.name", "http.route", "peer.service.name", "http.response.status_code"])
show("server RED by service / http.route / peer.service.name / status", srv)
cli = q(C, ["@resource.service.name", "server.address", "peer.service.name", "http.route", "http.response.status_code"])
show("client RED by service / server.address / peer.service.name / http.route / status", cli)
server_names = {k[2] for k, _ in srv if k[2] != "-"}
print("  topology join (client server.address == server peer.service.name):")
for addr in sorted({k[1] for k, _ in cli}):
    print(f"    {addr:60s} {'JOINED' if addr in server_names else 'no server match'}")
EOF

log "4) X-Ray service graph (last 10 min) + Lambda"
END=$(date -u +%s); START=$((END - 600))
aws xray get-service-graph --start-time "$START" --end-time "$END" --output json | python3 -c '
import json, sys
g = json.load(sys.stdin)["Services"]
ids = {s["ReferenceId"]: "%s(%s)" % (s.get("Name"), s.get("Type")) for s in g}
for s in g:
    print("   ", ids[s["ReferenceId"]], "->", ", ".join(ids.get(e["ReferenceId"], "?") for e in s.get("Edges", [])) or "-")'
for m in Invocations Errors; do
  echo "    lambda $PFX-inventory-stock $m (10 min): $(aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name $m \
    --dimensions Name=FunctionName,Value=$PFX-inventory-stock --start-time "$(date -u -d @$START +%FT%TZ)" --end-time "$(date -u -d @$END +%FT%TZ)" \
    --period 600 --statistics Sum --query 'Datapoints[0].Sum' --output text)"
done
