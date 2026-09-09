# ping demo — OBI collector notes

Session notes for the "ping" demo built on this branch (`demo/ping`). A 4-service
RED topology instrumented by OBI, with metrics to CloudWatch and traces to X-Ray.
`collector-config.yaml` in this folder is the runtime config the OBI-as-receiver
collector is launched with (mounted at `/etc/otelcol/config.yaml`).

## Topology

```
checkout ──POST /charges──▶ payment ──POST /audit──▶ audit   (leaf)
   └───────POST /reservations──▶ inventory                   (leaf)
```

Four Flask+gunicorn services (one codebase, role via `$ROLE`, health profile via
`$PROFILE`). Deployed one-service-per-host on 8 x86 EC2 (checkout×1, payment×3,
inventory×1, audit×3); each host runs its own OBI collector (host-net, privileged,
`context_propagation: all`). Discovery is method-2: a Route53 private zone
(`ping.internal`) with multivalue A records for payment/audit.

## What this collector config does

- **OBI receiver** (`open_port: 8000`, `features: application`) auto-instruments
  the local Python service.
- **traces/xray**: all spans → CloudWatch/X-Ray OTLP
  (`https://xray.<region>.amazonaws.com/v1/traces`, SigV4 service `xray`).
- **RED metrics are span-derived** via two `spanmetricsconnector` instances split
  by span kind (`filter/server`, `filter/client`). Each uses `namespace:
  http.server.request` / `http.client.request` so the emitted `<namespace>.duration`
  histogram matches the OTel semconv names `http.server.request.duration` /
  `http.client.request.duration`. Buckets and dimensions are curated to match OBI's
  native RED; the client metric additionally carries `peer.service.name`.
- **transform/aws** copies OBI's EC2-detected resource attributes to AWS-flavored
  keys on the metric/span resource: `host.id`→`ec2.instance.id`,
  `cloud.account.id`→`aws.account.id`, `cloud.region`→`aws.region`, and derives
  `host.ip` from the `ip-a-b-c-d` internal hostname.
- **transform/strip** removes spanmetrics' baked-in `span.name`/`span.kind`/
  `status.code`; **filter/calls** drops the redundant `*.calls` counter.
- **metrics** → CloudWatch Metrics OTLP
  (`https://monitoring.<region>.amazonaws.com/v1/metrics`, SigV4 service
  `monitoring`), delta temporality via `cumulativetodelta`.

Adding any new metric dimension is config-only: add it under a connector's
`dimensions` (must be a span attribute that OBI already emits). No rebuild.

## Querying (CloudWatch OTLP is a Prometheus-compatible store, NOT list-metrics)

Metrics — SigV4 POST to `https://monitoring.<region>.amazonaws.com/api/v1/query`,
body `query=<promql>`, sign service `monitoring`. Labels are prefixed:
`@resource.service.name`, `@resource.ec2.instance.id`, etc. A metric name must be
given explicitly, e.g. `{__name__="http.server.request.duration"}`.

Traces — the X-Ray API (`get-trace-summaries` + `batch-get-traces`, max 5 ids/call).
`peer.service.name` appears on CLIENT spans.

## Collector image (builder-config components)

The image is built from `examples/otel-collector` (ocb). Components this branch
added to `builder-config.yaml`, all pinned to the collector core version the OBI
`replace` pulls in (v0.158.0) to avoid an ottl/pprofile compile skew:
`otlphttpexporter`, `sigv4authextension`, `cumulativetodeltaprocessor`,
`transformprocessor`, `filterprocessor`, `spanmetricsconnector`.

## The 499 fix (eBPF)

With `context_propagation: all`, passive (server) sockets are inserted into
`sock_dir` (sockhash) by `bpf_sock_ops_passive_est_cb`, so their response egress
goes through the sk_psock path. `kprobe/tcp_sendmsg` does not fire there, and the
generic tracer's backup kprobe (`tcp_rate_check_app_limited`) reads the response
from `msg_buffers` — which the sk_msg server branch (`schedule_service_name_option`
→ `SK_PASS`) never populated. So plaintext HTTP/1 server responses were missed and
`force_finish_http` stamped `http.response.status_code=499` with a 0-byte body.
HTTPS was unaffected because its response is captured via the `SSL_write` uprobe
(before encryption), off the psock egress path.

Fix (`bpf/tpinjector/tpinjector.c`): the server sk_msg branch now calls
`bpf_msg_pull_data` + `fill_msg_buffers(msg, &t_ctx->p_conn, &e_key)` before
`SK_PASS`, mirroring the client request path, so the backup kprobe can capture the
server response. This keeps `sock_dir` (and therefore `peer.service.name`) while
restoring correct server-side RED.

## peer.service.name

Carried hop-by-hop over a kind-26 TCP option: the downstream writes its own
`service.name` on the response; the upstream's OBI parses it into
`svc_peer_name_map` (conn→name) and stamps it onto the client HTTP event. Surfaced
as the span attribute `peer.service.name` (renamed from `tcp.peer.service.name`).
Works cross-host on plaintext and HTTPS; breaks only across a TCP-terminating hop
(LB / proxy / mesh sidecar).
