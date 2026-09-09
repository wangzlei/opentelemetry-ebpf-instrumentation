# ping demo — usage guide

A 4-service HTTP app for exercising OBI's RED metrics, distributed traces, and the
experimental TCP-option `peer.service.name` propagation — end to end into Amazon
CloudWatch (metrics) and AWS X-Ray (traces).

```
checkout ──POST /charges──▶ payment ──POST /audit──▶ audit   (leaf)
   └───────POST /reservations──▶ inventory                   (leaf)
```

`app/server.py` is one Flask+gunicorn codebase; each instance's behaviour is set by
env vars, so the same image runs every role.

| env | meaning |
|---|---|
| `ROLE` | `checkout` / `payment` / `inventory` / `audit` — served route + downstream calls |
| `PROFILE` | `healthy` / `degraded` / `erroring` / `faulty` — status-code mix + latency of this service's own responses |
| `PAYMENT_URLS` / `INVENTORY_URLS` / `AUDIT_URLS` | comma-separated downstream base URLs (a DNS name is fine — see Discovery) |
| `USE_TLS` | `1` serves HTTPS with a self-signed cert (demo only) |
| `PORT` | listen port (default 8000) |

Runtime controls: `POST /fault?profile=<name>` flips this service's `PROFILE` live;
`GET /healthz` liveness.

---

## 1. Images

**App** — built from this folder, no registry needed:
```bash
docker build -t ping-app app/
```

**Collector** — the OBI-as-receiver collector, built from `examples/otel-collector`
(ocb) and published multi-arch to GHCR by the fork's `build-artifacts.yml` workflow.
It bundles: obi receiver, otlphttp + sigv4auth (CloudWatch/X-Ray), cumulativetodelta,
transformprocessor (+ spanmetrics/filter, unused by default).
```bash
# pull the current image (public; tag = a commit short-sha on demo/ping)
docker pull ghcr.io/wangzlei/obi-collector:latest
# or rebuild after an OBI/builder-config change:
gh workflow run "Build artifacts (obi + collector)" \
  --repo wangzlei/opentelemetry-ebpf-instrumentation --ref demo/ping
```
`collector-config.yaml` (this folder) is mounted at `/etc/otelcol/config.yaml`.

---

## 2. Run locally (docker-compose, single host)

Everything on one Docker host; exporters use your `~/.aws` (profile via `AWS_PROFILE`).
```bash
docker build -t ping-app app/
AWS_PROFILE=<profile> docker compose up -d
docker logs -f ping-collector      # watch export
```
`docker-compose.yaml` runs the four services + a traffic generator + the collector.

---

## 3. Run on EC2 (one service per host)

This is the deployment used for the reference setup: N instances, each running its
own collector + one app container, discovery via Route 53. There is no cross-host
orchestrator — each host is provisioned individually over SSM.

Reference values (us-west-2, profile `ping`): AMI `ami-0b787142aa56d54db`
(AL2023 x86), VPC `vpc-017c34776120b35bc`, subnet `subnet-002be9598dad093c4`,
SG `sg-0f6caf64203f751e2` (intra :8000 + egress), instance profile
`Ec2DemoObservability-ObsInstanceInstanceProfile...` (SSM + CloudWatch + X-Ray),
Route 53 private zone `ping.internal` (`Z097757611V01PJRE00N6`).

### 3a. Launch instances (one per role; scale payment/audit)
```bash
aws ec2 run-instances --region us-west-2 --profile ping \
  --image-id ami-0b787142aa56d54db --instance-type t3.medium --count 3 \
  --subnet-id subnet-002be9598dad093c4 --security-group-ids sg-0f6caf64203f751e2 \
  --iam-instance-profile Arn=<obs-instance-profile-arn> \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ping-payment},{Key=ping-role,Value=payment},{Key=purpose,Value=ping-demo}]'
```
Repeat per role (`checkout` ×1, `payment` ×3, `inventory` ×1, `audit` ×3).

### 3b. Route 53 records (method-2 discovery)
Multivalue A records, one value per instance IP, low TTL:
```bash
aws route53 change-resource-record-sets --profile ping --hosted-zone-id Z097757611V01PJRE00N6 \
  --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
    "Name":"payment.ping.internal","Type":"A","TTL":10,
    "ResourceRecords":[{"Value":"<ip1>"},{"Value":"<ip2>"},{"Value":"<ip3>"}]}}]}'
# repeat for audit (3), inventory (1), checkout (1)
```

### 3c. Provision each host (SSM `AWS-RunShellScript`)
Per host: install docker, drop the app files + `collector-config.yaml` under
`/opt/ping`, then run the collector (host-net, privileged) and one app container
(host-net) with the role's env. Downstream URLs are the DNS names above, e.g.:
- checkout: `PAYMENT_URLS=http://payment.ping.internal:8000 INVENTORY_URLS=http://inventory.ping.internal:8000`
- payment:  `AUDIT_URLS=http://audit.ping.internal:8000`

```bash
docker run -d --name ping-collector --restart unless-stopped --privileged --pid host \
  --network host -e AWS_REGION=us-west-2 \
  -v /sys/fs/bpf:/sys/fs/bpf -v /sys:/sys -v /proc:/proc:ro \
  -v /opt/ping/collector-config.yaml:/etc/otelcol/config.yaml:ro \
  obi-collector:ping --config /etc/otelcol/config.yaml

docker run -d --name ping-app-svc --restart unless-stopped --network host \
  -e OTEL_SERVICE_NAME=payment-service -e ROLE=payment -e PROFILE=healthy \
  -e AUDIT_URLS=http://audit.ping.internal:8000 ping-app
```
Access hosts with `aws ssm start-session --target <instance-id>` (no SSH/public IP).

---

## 4. Service discovery / traffic fan-out

Downstream URLs are DNS names backed by Route 53 multivalue A records. The app
resolves the name to all A records and picks one per request (`server.py::_targets`),
sending `Host: <name>` — so traffic spreads evenly across instances while the client
`server.address` stays the clean DNS name and `peer.service.name` still resolves.
(Plain DNS + a pooled HTTP client would pin every request to one instance.)

---

## 5. Telemetry produced

RED = OBI native application metrics:
- `http.server.request.duration` — node RED, per service, split per instance by the
  `@resource.ec2.instance.id` / `service.instance.id` resource attributes.
- `http.client.request.duration` — edge RED; carries `server.address` (DNS name) **and**
  `peer.service.name` (downstream service's own name, from the kind-26 TCP option).

`collector-config.yaml` adds AWS-flavoured resource attributes to every span/metric via
a `transform` processor: `ec2.instance.id`, `aws.account.id`, `aws.region`, `host.ip`
(alongside OBI's native `host.id` / `cloud.*`).

---

## 6. Fault injection

- App latency / errors: `curl -XPOST 'http://<host>:8000/fault?profile=degraded'` on one
  instance (per-instance, live).
- Network latency (kernel qdisc): on one host over SSM —
  `dnf install -y iproute-tc; tc qdisc add dev ens5 root netem delay 400ms`
  (remove: `tc qdisc del dev ens5 root`). NOTE: netem sits below OBI's socket-level
  measurement, so the affected server's OWN duration stays normal; the latency shows on
  the caller's client edge (T_client) and propagates up — the client-vs-server gap is the
  network-vs-code signal. Application RED cannot name which instance is slow (client edge
  is aggregated by peer.service.name); enable OBI's `network`/TCP-RTT metrics for that.

---

## 7. Querying

CloudWatch OTLP metrics are a Prometheus-compatible store — use PromQL, not `list-metrics`:
- SigV4 POST `https://monitoring.<region>.amazonaws.com/api/v1/query`, body `query=<promql>`,
  signing service `monitoring`. Labels are prefixed (`@resource.service.name`,
  `@resource.ec2.instance.id`, …); a metric name is required, e.g.
  `{__name__="http.server.request.duration"}`.
- p99: `histogram_quantile(0.99, sum_over_time({__name__="http.server.request.duration","@resource.service.name"="payment-service"}[5m]))`
- count: `histogram_count(sum_over_time({__name__="http.server.request.duration","@resource.service.name"="payment-service"}[5m]))`

Traces: X-Ray API (`get-trace-summaries` + `batch-get-traces`, max 5 ids/call).
`peer.service.name` is on CLIENT spans.

---

## 8. Customising metric dimensions

- Resource attributes: add/rename in the `transform` processor (config only, no rebuild).
- New span-derived attributes on the native RED metrics: an OBI change (attribute name +
  span getter + the metric's attribute group) — see how `peer.service.name` was added.
- Fully arbitrary dimensions from any span/resource attribute: switch RED to the
  `spanmetricsconnector` (already compiled into the image; wire it in `collector-config.yaml`).
