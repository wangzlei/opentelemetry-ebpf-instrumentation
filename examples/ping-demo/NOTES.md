# ping demo

A small 4-service HTTP app for exercising OBI's RED metrics, distributed traces,
and the experimental TCP-option `peer.service.name` propagation — end to end into
Amazon CloudWatch (metrics) and AWS X-Ray (traces).

## Topology

```
checkout ──POST /charges──▶ payment ──POST /audit──▶ audit   (leaf)
   └───────POST /reservations──▶ inventory                   (leaf)
```

`app/server.py` is one Flask+gunicorn codebase; each instance's behaviour is set
by env vars, so the same image runs every role.

| env | meaning |
|---|---|
| `ROLE` | `checkout` / `payment` / `inventory` / `audit` — selects the served route and downstream calls |
| `PROFILE` | `healthy` / `degraded` / `erroring` / `faulty` — status-code mix + latency of this service's own responses |
| `PAYMENT_URLS` / `INVENTORY_URLS` / `AUDIT_URLS` | comma-separated downstream base URLs (a DNS name is fine — see Discovery) |
| `USE_TLS` | `1` serves HTTPS with a self-signed cert (demo only) |
| `PORT` | listen port (default 8000) |

Runtime controls:
- `POST /fault?profile=<name>` flips this service's `PROFILE` live (fault injection, no restart).
- `GET /healthz` liveness.

## Components

- **App image**: `docker build -t ping-app app/`.
- **Collector image**: the OBI-as-receiver collector, built from `examples/otel-collector`
  (published to GHCR by the fork's build-artifacts workflow). Run it with
  `collector-config.yaml` mounted at `/etc/otelcol/config.yaml`.

## Run locally (docker-compose)

`docker-compose.yaml` brings up the four services, a traffic generator, and the
collector on one host. AWS credentials for the CloudWatch/X-Ray exporters come
from the mounted `~/.aws` (or an instance role on EC2).

```bash
docker build -t ping-app app/
docker compose up -d
```

## Run on EC2 (one service per host)

Launch one instance per role (scale `payment` / `audit` to as many as you want),
each running:
- the collector (host network, privileged, `context_propagation: all`) with
  `collector-config.yaml`, and
- one `ping-app` container (host network) with the role's env.

The instance role needs CloudWatch OTLP + X-Ray write and (for `sigv4auth`) is
picked up from IMDS — no credentials file required.

## Service discovery (Route 53, method 2)

Downstream URLs are DNS names (e.g. `payment.ping.internal`) backed by a Route 53
private hosted zone with multivalue A records (one per instance). The app resolves
the name to all A records and picks one per request (`server.py::_targets`), so
traffic fans out evenly across instances while the `Host` header keeps the logical
name — client `server.address` stays the clean DNS name and `peer.service.name`
still resolves. Plain DNS + a pooled HTTP client would otherwise pin every request
to a single instance.

## Telemetry it produces

RED comes from OBI's native application metrics:
- `http.server.request.duration` — per service (node RED), split per instance by
  the `ec2.instance.id` / `service.instance.id` resource attributes.
- `http.client.request.duration` — per outgoing edge; carries `server.address`
  (the DNS name) **and** `peer.service.name` (the downstream service's own name,
  learned over the kind-26 TCP option).

`collector-config.yaml` also adds AWS-flavoured resource attributes to every span
and metric via a `transform` processor: `ec2.instance.id`, `aws.account.id`,
`aws.region`, `host.ip` (alongside OBI's native `host.id` / `cloud.*`).

Spans go to X-Ray; metrics go to CloudWatch (delta temporality).

## Querying

CloudWatch OTLP metrics are a Prometheus-compatible store — query with PromQL, not
`list-metrics`:
- SigV4 POST `https://monitoring.<region>.amazonaws.com/api/v1/query`, body
  `query=<promql>`, signing service `monitoring`.
- Labels are prefixed: `@resource.service.name`, `@resource.ec2.instance.id`, …;
  a metric name must be given, e.g. `{__name__="http.server.request.duration"}`.
- p99: `histogram_quantile(0.99, sum_over_time({__name__="http.server.request.duration","@resource.service.name"="payment-service"}[5m]))`

Traces: the X-Ray API (`get-trace-summaries` + `batch-get-traces`).
`peer.service.name` is on CLIENT spans.

## Customising metric dimensions

Resource attributes: add/rename in the `transform` processor (config only).
New span-derived metric attributes on the native RED metrics require an OBI change
(an attribute name, a span getter, and the metric's attribute group).
