# ping demo — polyglot sample apps

The four ping-demo services, one language each, with the **same external behaviour** as
`../app/server.py` (the Flask app the Omni RCA demo was built on — `$ROLE` routes, `$PROFILE` mixes,
`POST /fault`, `CPU_SHARE`, failure propagation, the permanent `flaky` failure rate, DNS multi-A
fan-out). No OpenTelemetry SDK and no `OTEL_SERVICE_NAME`: traces and RED come from the eBPF agent,
and each service names itself through the agent's autoname (patch 05).

```
checkout (Python) ──POST /charges──▶ payment (Go) ──POST /audit──▶ audit (Node)
        └──────────POST /reservations──▶ inventory (Java)
```

| dir | service | language / stack | image (linux/amd64) | autoname source → expected `service.name` |
|---|---|---|---|---|
| `checkout-python/` | checkout | Python 3.12, Flask + gunicorn (2 workers × 8 threads) | `python:3.12-slim` (pinned digest), ~156 MB | `gunicorn … checkout_api:app` → **`checkout_api`** |
| `payment-go/` | payment | Go 1.25, `net/http` stdlib | `distroless/static`, ~12 MB | binary `/usr/local/bin/payment` (module `ping/payment`, unstripped) → **`payment`** |
| `inventory-java/` | inventory | Java 21, JDK `HttpServer` + `HttpClient` (HTTP/1.1, 32 threads) | jlink'd JRE on `debian:12-slim`, ~118 MB (keeps `java.instrument` + `java.logging` so OBI's Java agent attaches) | `java -jar /app/inventory-0.4.0.jar` (no Implementation-Title) → **`inventory`** |
| `audit-node/` | audit | Node 22, built-in `http`, no dependencies | `node:22-slim`, ~227 MB | `package.json` `"name": "audit-worker"` → **`audit-worker`** |

`checkout-python/` is a copy of `../app` (server.py, cpuwork.py, propagate.py and their tests, same
pinned requirements and base image) plus `checkout_api.py` (the entry module) and `PREFER_SAME_AZ`.
`../app` itself is unchanged. Every port reads `$ROLE` and can serve any role (the e2e suite runs each
language in the leaf and the parent role); each is deployed only for its own. If `OTEL_SERVICE_NAME`
is set on a container, the agent uses it instead of autoname — the apps never read it.

## Environment (identical in all four)

| env | default | meaning |
|---|---|---|
| `ROLE` | image's role | `checkout` / `payment` / `inventory` / `audit` — served route + downstream calls. Unknown → exits at start |
| `PROFILE` | `healthy` | `healthy` / `flaky` / `degraded` / `erroring` / `faulty` — status mix + latency of this service's own responses |
| `PAYMENT_URLS`, `INVENTORY_URLS` | — | checkout's downstreams (comma-separated base URLs; DNS names fan out, see below) |
| `AUDIT_URLS` | — | payment's downstream |
| `CPU_SHARE` | `0` | share of each response's target duration spent on real CPU instead of sleeping; parsed and clamped to 0…1, junk/NaN/inf → 0; reported by `/healthz` |
| `PREFER_SAME_AZ` | `0` | `1`: call only downstream IPs in this host's /24 (fallback: all) |
| `USE_TLS` | `0` | `1`: serve HTTPS with a self-signed cert; `https://` downstream URLs are called without verification |
| `PORT` | `8000` | listen port |
| `DEBUG` | `0` | ports only: `1` logs the inbound `Host` and failed downstream calls |

Run on EC2 (host network, one app per host; images do not set `OTEL_SERVICE_NAME`):
```bash
IMG=292779133546.dkr.ecr.us-west-2.amazonaws.com/ping-demo-apps
docker run -d --name ping-app-svc --restart unless-stopped --network host --memory 256m \
  -e PROFILE=flaky -e PAYMENT_URLS=http://payment.ping.internal:8000 \
  -e INVENTORY_URLS=http://inventory.ping.internal:8000 $IMG:checkout-python-omni-<sha>
docker run ... -e PROFILE=flaky -e AUDIT_URLS=http://audit.ping.internal:8000 $IMG:payment-go-omni-<sha>
docker run ... -e PROFILE=flaky $IMG:inventory-java-omni-<sha>
docker run ... -e PROFILE=flaky $IMG:audit-node-omni-<sha>
```
`ROLE` is baked into each image (`ENV ROLE=<its role>`), so it need not be passed. Add `-e CPU_SHARE=0.5`
on the hosts whose CPU fault should show in their own latency.

## Parity

| feature (server.py semantics) | Python checkout | Go payment | Java inventory | Node audit |
|---|---|---|---|---|
| `$ROLE` routes: `POST /checkout` → payment `/charges` + inventory `/reservations` (sequential); `POST /charges` → audit `/audit`; inventory/audit leaves | ✔ | ✔ | ✔ | ✔ |
| `$PROFILE` table (5 profiles, same rows), weighted pick + clamped `triangular(lo, hi, mean)` | ✔ | ✔ | ✔ | ✔ |
| `flaky` = permanent 2 % 500 + 1 % 429 | ✔ | ✔ | ✔ | ✔ |
| downstreams called only on the OK path, before the sleep | ✔ | ✔ | ✔ | ✔ |
| failure propagation (`worst_status`): any failure → 500, 429 passes only if every failure is 429, no-call/transport error not adopted, no retry on a status | ✔ | ✔ | ✔ | ✔ |
| `POST /fault?profile=` (default `degraded`, 400 + `valid` list in profile order) | per gunicorn **worker** (≈ half the traffic) | instance-wide | instance-wide | instance-wide |
| `GET /healthz` → `{cpu_share, ok, pid, profile, role}` (sorted keys, `cpu_share` as a float) | ✔ (answering worker's pid) | ✔ | ✔ | ✔ |
| `CPU_SHARE`: compute bounded by **thread CPU time** (pbkdf2-sha256, 512-iteration chunks), 3 s wall cap, sleep = fixed share (never the remainder), one `cpuwork role=… slowdown=… capped=…` log line per request when > 0 | ✔ (`time.thread_time`, GIL released) | ✔ (`CLOCK_THREAD_CPUTIME_ID`, goroutine locked to its thread) | ✔ (`ThreadMXBean`) | ✔ (worker-thread pool ≤ 16, `process.threadCpuUsage`; event loop stays free) |
| DNS multi-A fan-out: every IPv4 A record, shuffled, `Host: <name>:<port>`, next IP on a transport error, fresh connection per call, 5 s timeout | ✔ | ✔ | ✔ | ✔ |
| `PREFER_SAME_AZ` (/24 of the UDP-connect local IP) | ✔ (added) | ✔ | ✔ | ✔ |
| `USE_TLS` server + unverified `https://` client | ✔ (openssl at start) | ✔ (cert generated in-process) | ✔ (PKCS12 baked at build) | ✔ (PEM baked at build) |
| 404 unknown path / 405 wrong method | ✔ (Flask HTML) | ✔ (text) | ✔ (JSON) | ✔ (JSON) |
| access log line per request | gunicorn | `METHOD URI STATUS` | same | same |

Known, deliberate differences: the ports run one process, so `/fault` is instance-wide (the Python app's
two-worker split is documented in `../NOTES.md`); error *bodies* for 404/405 differ per framework (the
status codes match); capacity differs (gunicorn: 16 concurrent requests; Java: 32 threads; Go/Node:
unbounded), which only matters above ~16 concurrent requests per instance. Not ported from the older
lei-demo audit app: the optional AWS SDK Lambda archive call (`ARCHIVE_FUNCTION`) — it is not in
`server.py`, and dropping it leaves the Node image dependency-free. Java inventory only: optional `STOCK_URL` — on the OK path of POST /reservations it POSTs
`{"sku":...}` to that HTTPS URL (the API Gateway -> Lambda from deploy/apigw.sh); the result is not adopted.

## Build, push

```bash
./build.sh            # local images ping-demo-apps:<role>-<lang>-omni-<HEAD short sha>
./build.sh --push     # + push to 292779133546.dkr.ecr.us-west-2.amazonaws.com/ping-demo-apps
```
Builds use `GOPROXY=https://goproxy.cn,direct`; the Go build runs `go vet` + `go test`.
Unit tests outside docker: `python3 checkout-python/test_propagate.py`, `python3 checkout-python/test_cpuwork.py`,
`(cd payment-go && go test ./...)`, `(cd audit-node && node --test test.js)`.

## Local end-to-end test

```bash
cd test
TAG=<sha> ./fleet.sh up            # checkout x1, payment x3, inventory x1, audit x3 on network pingtest
TAG=<sha> ./e2e.sh                 # PASS/FAIL per check, ~7 min
./autoname.sh                      # optional: local otelcol-obi with a debug exporter -> service names
./fleet.sh down
```
`e2e.sh` checks, for every language: endpoints and `/fault` switching, the `flaky` rate (3000 requests),
propagation as a parent (faulty → 500, erroring → 429 passthrough + 500, healthy → 200, unreachable
dependency not adopted), three-way A-record spread, `PREFER_SAME_AZ` on/off with a second subnet,
`CPU_SHARE` slowdown ≈ 1 uncontended vs ≫ 1 under `--cpus 0.25`, and HTTPS server + client.
