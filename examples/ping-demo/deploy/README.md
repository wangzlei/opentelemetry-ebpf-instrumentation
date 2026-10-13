# ping demo deploy scripts

Region-parametrized scripts for the ping demo on EC2 with the eBPF CloudWatch agent (ADOT OBI inside
`amazon-cloudwatch-agent`, SSM Distributor package `ADOT-CloudWatchAgent-eBPF-Beta`). The agent
produces BOTH traces (X-Ray OTLP) and RED metrics (CloudWatch OTLP); there is no ADOT SDK and no
collector container. Ported from `collector-monorepo/demo/lei`.

`REGION=<region>` selects `env/<region>.env` (default `us-west-2`). Credentials: `AWS_PROFILE=ping`
(from the env file) unless `AWS_ACCESS_KEY_ID` is already exported (ada). Hosts are found by tag
`purpose=ping-demo` + `ping-role=<role>`.

| script | does |
|---|---|
| `cleanup-disk.sh [report]` | rm STOPPED `ping-collector`/`ping-collector-old`, `docker image prune -af`, builder prune, `/etc/docker/daemon.json` log rotation (no dockerd restart) |
| `upgrade-agent.sh [--version v] [--ids ..] \| check` | stop a running old `ping-collector`, Distributor Install `{"SSM_EBPF":"true"}`, VPC/subnet drop-in, Omni bridge file, restart agent + app, per-host check (rpm, active, user=cwagent, CapEff `000001c0002c30e4`, ebpf, bridge) |
| `bridge-config.sh [--ids ..]` | write/remove `etc/amazon-cloudwatch-agent.d/omni-bridge.yaml` per `OMNI_BRIDGE_ENDPOINT`, restart agent |
| `infra.sh hosts\|alb\|dns\|probe\|all` | launch `NEW_HOSTS` (+ seed the role's current app image via S3 + agent), shared ALB + `alb.internal` zone, host A records, curl the ALB paths |
| `apigw.sh [url\|down]` | inventory -> API Gateway (REST, X-Ray) -> Lambda `ping-inventory-stock` |
| `redeploy-apps.sh <sfx>\|latest\|local [--dry-run]` | recreate `ping-app-svc` per role: `*-omni-<sfx>` ECR images without `OTEL_SERVICE_NAME`, or `local` = current image re-wired |
| `verify.sh [window]` | agent check, RED by service/subnet/route, client/server topology join, X-Ray service graph, Lambda |
| `cwq.py '<promql>'` | SigV4 CloudWatch PromQL query (`AWS_REGION` aware) |

Topology (lei's latest design):

```
checkout --POST /charges------> backend.alb.internal:8000 (ALB ping-backend-alb) --> payment x3 --> audit.<zone> x3
         \-POST /reservations-> backend.alb.internal:8000 ------------------------> inventory x3 --> API GW -> Lambda
```

ALB: one listener :8000, `/charges*` -> payment TG, `/reservations*` -> inventory TG, default 404,
health check `GET /healthz`. `backend.alb.internal` lives in its own private zone `alb.internal`.
Every backend sees `Host: backend.alb.internal:8000`, so the join is client `server.address` ==
server `peer.service.name` (both `backend.alb.internal:8000`). The client RED's own
`peer.service.name` (TCP option) is EMPTY through the ALB: the option does not survive an L7 proxy.

## Omni bridge (us-east-1 only)

The old collector exported the metrics pipeline also to the bridge (`otlp_http/bridge`). The agent
cannot be given an extra exporter on its `metrics` pipeline (the `.d` YAML merge rejects a pipeline
or component defined twice with a different value), but a `.d` YAML may ADD components: the agent
passes `etc/ebpf/obi.yaml` and every `etc/amazon-cloudwatch-agent.d/*.yaml` as `-otelconfig`.
`bridge-config.sh` writes `omni-bridge.yaml` = exporter `otlp_http/omni_bridge` (no retry, 10 s,
queue 100) + pipeline `metrics/omni_bridge: [obi] -> [transform/aws, cumulativetodelta, batch]`.
Verified on ping-audit-2a (us-west-2, 2026-10-13) against a local OTLP sink: merged config loads,
gzip OTLP posts arrive, no CloudWatch-arm errors. The file is not RPM-owned, so it survives
Distributor upgrades (install.sh only deletes `.d/obi.yaml`). Differences from the old collector:
separate pipeline = separate batches (same post-delta datapoints), batch size 500 (not 1024),
metrics only (as before; traces go to X-Ray only).

Omni-required attributes, checked in CloudWatch (us-west-2): `http.route` (client + server),
`@resource.aws.vpc.id`, `@resource.aws.subnet.id` (3 inventory subnets), `@resource.ec2.instance.id`
/ `host.id` / `service.instance.id`, server `peer.service.name`, client `server.address`. No `k8s.*`
on EC2. Client `peer.service.name` is present only on direct (non-ALB) edges, e.g. payment -> audit.

## us-east-1: what is still needed (not done)

1. Distributor package in us-east-1: documents are regional and `ADOT-CloudWatchAgent-eBPF-Beta` does
   not exist there. Publish it in 292779133546/us-east-1 and share it with 868155213681 (or publish
   in 868155213681 and set `PKG_ARN` to the plain name).
2. A us-east-1b subnet for the ALB (all rig subnets are us-east-1a; an ALB needs 2 AZs), NAT route
   table like the others; put it in `ALB_SUBNETS`. `ALB_SG=$APP_SG` (the app SG only admits itself).
3. Images: `ping-demo-apps` exists only in us-west-2 ECR; the env sets `ECR_REGION=us-west-2`
   (cross-region pull via the NAT, repo policy already allows 868155213681).
4. Order: `cleanup-disk.sh` -> `upgrade-agent.sh` (stops the running `ping-collector` OBI first, writes
   the bridge file for `http://10.20.1.194:4318`) -> `infra.sh alb` -> `apigw.sh` ->
   `redeploy-apps.sh <sfx>` -> `verify.sh`. Confirm the bridge topic's message count rises (a wrong
   endpoint fails quietly by design).
5. Omni ingestion: topology across the ALB must join on client `server.address` == server
   `peer.service.name`, not on the client's `peer.service.name` (empty through an L7 proxy).
6. Hosts there are t3.small with Name tags repeated per role; `ping-role` is what the scripts use.
