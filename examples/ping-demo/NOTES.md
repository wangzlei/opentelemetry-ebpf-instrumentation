# ping demo — design & usage notes

A small 4-service HTTP app for demonstrating, end to end on AWS:
- OBI's RED metrics + distributed traces (→ CloudWatch metrics via OTLP, → X-Ray),
  incl. the experimental TCP-option `peer.service.name`;
- CloudWatch **Network Flow Monitor (NFM)** for the network layer;
- a two-layer RCA story: **OBI RED localizes the slow service/instance; NFM localizes
  the bad subnet** (packet loss / retransmissions).

This doc is written so a teammate (or a fresh Claude session) can pick the demo back up.
Live resource IDs (instances, subnets, Route 53, active faults) are in `HANDOFF.md`.

## Topology

```
checkout ──POST /charges──▶ payment ──POST /audit──▶ audit   (leaf)
   └───────POST /reservations──▶ inventory                   (leaf)
```

`app/server.py` is one Flask+gunicorn codebase; role/behaviour via env:

| env | meaning |
|---|---|
| `ROLE` | checkout / payment / inventory / audit — served route + downstream calls |
| `PROFILE` | healthy / degraded / erroring / faulty — this service's own status-mix + latency |
| `PAYMENT_URLS` / `INVENTORY_URLS` / `AUDIT_URLS` | comma-separated downstream base URLs; a Route 53 DNS name is expected |
| `PREFER_SAME_AZ` | `1` → call the same-AZ downstream (see routing below) |
| `USE_TLS` | `1` → serve HTTPS with a self-signed cert |
| `PORT` | listen port (default 8000) |
| `POST /fault?profile=<name>` | flip PROFILE live (app-level fault injection) |

## How server.py routes to downstreams (`call()` / `_targets()`)

Downstreams are Route 53 DNS names (e.g. `payment.ping.internal`) backed by **multivalue
A records — one per instance**. Plain DNS + a pooled HTTP client would pin every request
to one IP, so the app does its own client-side load-balancing:

1. `_targets(base)` resolves the DNS name to **all** A records via `socket.getaddrinfo`,
   returning one `(http://<ip>:<port><path>, Host=<name>)` per IP.
2. `call()` collects targets for all downstream URLs, then:
   - **`PREFER_SAME_AZ=1`**: keep only targets whose IP is in the caller's own `/24`.
     In this demo one subnet == one AZ, so same `/24` == same AZ → the call stays in-AZ
     (mirrors production topology-aware routing that avoids cross-AZ hops). Falls back to
     all targets if none share the subnet (e.g. checkout, which lives in a different subnet).
   - `random.shuffle` + take the first that succeeds (retry the next on failure).
   - The IP is what we connect to; `Host` header stays the DNS name → the client
     `server.address` stays the clean name and `peer.service.name` still resolves.

Demo wiring: **checkout→payment is random** (checkout is in a different subnet, no same-AZ
payment, so it fans out across all 3); **payment→audit is same-AZ** (`PREFER_SAME_AZ=1` on
payment → each payment calls only the audit in its own subnet/AZ).

## Why split into per-AZ subnets (for NFM)

NFM's managed views aggregate flows by **subnet / AZ / VPC / service** — never per instance.
So to let NFM *localize a network problem to a specific service*, put **one app subnet per
AZ**, with that AZ's payment + audit sharing it (this is also how production looks — services
of a tier share the per-AZ app subnet; per-service subnets are not real, isolation is via
security groups). Then:
- a fault on one AZ's instances shows up as **that subnet** being the retransmissions /
  RTT top-contributor, distinct from the other AZs' subnets;
- cross-AZ calls (checkout→payment) appear as `INTER_AZ`, in-AZ (payment→audit) as `INTRA_AZ`.

(An earlier iteration used one subnet per instance — that makes NFM show per-instance, but
is NOT production-realistic and oversells NFM; we deliberately use per-AZ shared subnets.)

## Telemetry

RED = OBI native application metrics → CloudWatch OTLP (query with PromQL, see below):
- `http.server.request.duration` — node RED, per service, split per instance by
  `@resource.ec2.instance.id` / `service.instance.id`.
- `http.client.request.duration` — edge RED; carries `server.address` (DNS name) **and**
  `peer.service.name` (downstream's own name, from the kind-26 TCP option).
- `collector-config.yaml` adds AWS resource attrs to every span/metric via a transform
  processor: `ec2.instance.id`, `aws.account.id`, `aws.region`, `host.ip` (from OBI's EC2
  detection), plus `aws.vpc.id` / `aws.subnet.id` — OBI does **not** detect VPC/subnet, so
  they're read from the host's IMDS at deploy time and passed to the collector as
  `AWS_VPC_ID` / `AWS_SUBNET_ID` env, injected via `${env:...}` in `transform/aws`. The
  subnet attr lets you slice RED by the same subnet NFM localizes a fault to.
- Spans → X-Ray.

NFM (agent installed via SSM Distributor + activate; see below) → the network layer.

## Mocking a network problem (retransmission / latency)

Inject with `tc netem` on the **egress** of **all instances in the target subnet** (so the
whole subnet's traffic is impaired), over SSM:
```bash
dnf install -y iproute-tc
tc qdisc add dev ens5 root netem loss 25%          # packet loss  -> retransmissions/timeouts
# or:  netem delay 400ms                            # latency      -> RTT
# or:  netem loss 20% delay 200ms
# remove:
tc qdisc del dev ens5 root
```
`ens5` is the AL2023 ENA primary NIC. Loss is what NFM ranks best (see below). netem is a
persistent qdisc — it keeps injecting until removed or reboot.

## What each tool shows (and what it can't)

OBI RED (per-instance, exact):
- The impaired subnet's **payment** instance server p99 spikes (it blocks on the lossy/slow
  downstream + retransmits its own responses) — stands out vs the other AZs' payments.
- The impaired **audit**'s own server RED stays ~normal — netem sits **below** OBI's
  socket-level measurement, so audit's *code time* is unaffected. This is the
  **network-vs-code** signal (caller/client time ≫ callee/server time = network, not code).
- The client edge (`http.client.request.duration`) is aggregated by `peer.service.name`
  (not per downstream instance), so it shows the edge is slow but not which instance.

NFM:
- **Workload insights** (no monitor needed): top-contributors for `RETRANSMISSIONS`,
  `TIMEOUTS`, `DATA_TRANSFERRED` — aggregated to subnet/AZ. Packet loss → the bad subnet
  becomes the retransmissions top-contributor. **No RTT here.**
- **A Monitor** (must be created; local↔remote resources = subnets/VPC/AZ/service, 25 each,
  20 monitors/account/region) publishes CloudWatch `AWS/NetworkFlowMonitor` metrics:
  `RoundTripTime`, `Retransmissions`, `Timeouts`, `DataTransferred`, `HealthIndicator (NHI)`.
  **RTT only exists via a monitor.**
- **NHI** = binary "is the *AWS* network degraded on this path" (0 healthy / 100 degraded).
  You **cannot** fake NHI — injected netem is host-local, so NHI stays Healthy.
- The NFM agent's raw OTLP actually carries per-flow `remote_address:port` + `rtt_us`
  (dumped and verified), but the managed backend aggregates it to subnet. To get per-flow
  IP/RTT you'd have to point the agent's `--endpoint` at your own OTLP collector.

## Two-layer RCA story (the demo payoff)

1. **OBI RED** → the slow *service/instance*: e.g. payment-2b server p99 = 22s vs ~1s for
   payment-2a/2c; audit-2b server ~normal → "payment-2b is slow, and it's not audit's code".
2. **NFM Workload insights** → the bad *subnet*: the 2b app subnet is the retransmissions
   top-contributor → "the 2b subnet has packet loss".
3. Conclusion: a network fault on the 2b subnet is degrading the service instances there.

## Querying

CloudWatch OTLP metrics (Prometheus store, PromQL — NOT list-metrics):
- SigV4 POST `https://monitoring.<region>.amazonaws.com/api/v1/query`, body `query=<promql>`,
  signing service `monitoring`. Labels prefixed `@resource.*`; a metric name is required.
- `histogram_quantile(0.99, sum_over_time({__name__="http.server.request.duration","@resource.host.ip"="<ip>"}[3m]))`

NFM Workload insights (no monitor), via the `networkflowmonitor` API — scope id from
`aws networkflowmonitor list-scopes`:
```bash
aws networkflowmonitor start-query-workload-insights-top-contributors \
  --scope-id <SCOPE> --start-time <ISO> --end-time <ISO> \
  --metric-name RETRANSMISSIONS --destination-category INTRA_AZ   # or INTER_AZ, TIMEOUTS, DATA_TRANSFERRED
aws networkflowmonitor get-query-status-workload-insights-top-contributors  --scope-id <SCOPE> --query-id <QID>
aws networkflowmonitor get-query-results-workload-insights-top-contributors --scope-id <SCOPE> --query-id <QID>
```
Result rows are keyed by `localSubnetId` / `localAz` / `remoteIdentifier` (subnet ARNs) —
NFM's physical `usw2-azN` is a per-account random mapping; trust the subnet id.

Traces: X-Ray `get-trace-summaries` + `batch-get-traces`; `peer.service.name` on CLIENT spans.

## NFM agent enablement (per instance)

1. Attach managed policy `CloudWatchNetworkFlowMonitorAgentPublishPolicy` to the instance role.
2. Install: SSM Distributor package `AmazonCloudWatchNetworkFlowMonitorAgent`
   (`aws ssm send-command --document-name AWS-ConfigureAWSPackage --parameters action=Install,name=...`).
3. Activate: SSM document `AmazonCloudWatch-NetworkFlowMonitorManageAgent` (`Action=Activate`).
Agent = Rust + eBPF sock_ops (`aws/network-flow-monitor-agent`); publishes OTLP protobuf
(SigV4 service `networkflowmonitor`) to `https://networkflowmonitorreports.<region>.api.aws/publish`.

## Images / collector

- App: `docker build -t ping-app app/`.
- Collector: `ghcr.io/wangzlei/obi-collector` (public, multi-arch), run with `collector-config.yaml`
  mounted at `/etc/otelcol/config.yaml`; rebuild via the fork's `build-artifacts.yml` workflow.
- Deploy per host: collector (host-net, privileged, cp=all) + one `ping-app` container (host-net),
  provisioned over SSM. No cross-host orchestrator; Route 53 for discovery.
