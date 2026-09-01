# POC → fork migration plan

Tracks moving the eBPF-agent POC changes (originally developed in a vendored copy
under `collector-monorepo/obi/`, single commit `6b926b8`) onto this fork, based on
**upstream release tags, not `main`** — see the maintenance strategy below.

## Baseline

- Fork target base: **v0.12.2** (upstream release, 2026-08-22).
- POC source of truth: `collector-monorepo` commit `6b926b8`, paths under `obi/`.
- POC's own upstream base was ~v0.9/v0.10 (June), so a naive whole-file port drags
  in 3 months of upstream churn. A per-file 3-way merge onto v0.12.2 was used
  instead: 6 net-new files, 7 clean auto-merges, 12 files with 16 small conflict
  hunks, 0 files removed/renamed upstream.

## The four POC feature buckets and their disposition

| # | Bucket | Disposition on v0.12.2 |
|---|--------|------------------------|
| ① | HTTPS / instrumenter `map_files` uprobe fix | **DROPPED — already upstream.** v0.12.2 `resolveInstrPath` already uses `/proc/PID/map_files/<start>-<end>`. The POC patch is redundant. |
| ② | HTTP/2 multiplexing collection fix | **DEFERRED — upstream reworked this path independently** (`saved_stream_id` + `has_prev_info` + per-stream HPACK parse). The old patch must not be ported onto the new structure. Re-evaluate against v0.12.2 with the rust-h2 testbed before deciding whether any fix is still needed. |
| ③ | AWS SDK generic parser (service/operation from request head) | **PORTED** (this change). |
| ④ | TCP service-name propagation (kind-26 option → `tcp.peer.service.name`) | **PORTED** (this change). |

③ and ④ share `bpf/common/common.h` (one struct, one `-Wpadded` tail), the
`roundTripReturn` block in `go_nethttp.c`, and `spanner.go`, so they are landed as
one "payload enrichment" commit rather than split.

## Files in the ③+④ enrichment change

New:
- `pkg/ebpf/common/http/aws_generic.go` (+ `_test.go`) — the generic AWS parser.
- `bpf/gotracer/maps/go_aws_req_head.h` — crypto/tls → roundTrip request-head hand-off (also declares `volatile const http_aws_semantics`).
- `bpf/maps/svc_peer_name_map.h`, `bpf/tpinjector/maps/{sk_svc_name_map,svc_name_by_pid}.h` — TCP service-name maps.

Edited (AWS/TCP hunks only; HTTP/2 hunks in shared files were dropped):
- `bpf/common/common.h`, `bpf/common/http_info.h` — struct fields + padding.
- `bpf/generictracer/protocol_http.h` — peer-name lookup moved into `submit_http_event` (upstream renamed the old `finish_http`).
- `bpf/gotracer/go_net_tls.c`, `bpf/gotracer/go_nethttp.c` — request-head capture + peer lookup.
- `bpf/tpinjector/tpinjector.c` — kind-26 write/parse, sk_msg scheduling.
- `pkg/appolly/app/request/span.go` — `HTTPSubtypeAWSGeneric = 18` (POC used 16; v0.12.2 already took 16/17 for OpenAICompatible/Ollama), `AWSGeneric` type, `Span.PeerServiceName`, attrs + `TraceName`.
- `pkg/ebpf/common/spanner.go` — PeerServiceName set before enrichment; generic AWS as a fallback after `enrichedGoHTTPSpan` (guarded so dedicated S3/SQS classification wins).
- `pkg/ebpf/common/http_transform.go`, `pkg/export/otel/tracesgen/tracesgen.go` — non-Go path + span attributes.
- `pkg/internal/ebpf/gotracer/gotracer.go` — `http_aws_semantics` constant only (the HTTP/2 tail-call reindex was dropped).
- `pkg/internal/ebpf/tpinjector/tpinjector.go` — `AllowPID` records service.name AND keeps upstream's netns backfill (both behaviors merged); `BlockPID` deletes.

Dropped entirely (① / ②): `pkg/ebpf/instrumenter.go`,
`pkg/internal/ebpf/generictracer/generictracer.go`,
`bpf/generictracer/{k_tracer_tailcall,protocol_http2}.h`,
`bpf/generictracer/types/grpc_frames_ctx.h`.

## Regeneration

BPF C changed, so `*_bpfel.go` / `*_bpfeb.go` bindings must be regenerated and
committed (`make docker-generate`), or CI `check-clean-work-tree` fails and Go code
referencing new struct fields (`AwsReqHead`, `PeerServiceName`, `SvcNameByPid`)
won't compile.

## Long-term maintenance strategy

- Rebase this fork onto upstream **release tags**, not `main`.
- Prefer additive files over edits to churny upstream files; upstream what you can.
- Pipeline-level customizations (e.g. span→metrics) do **not** belong here — build
  them as separate-repo OTel Collector connectors/processors composed via `ocb`.
