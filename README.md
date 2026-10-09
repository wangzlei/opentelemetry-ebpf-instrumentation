# adot-obi (experimental, local only)

ADOT build of the OpenTelemetry eBPF Instrumentation (OBI), consumed by the
Amazon CloudWatch Agent (cwagent) as an OTel receiver (`receivers: obi:`).

This is a **patch-based** repo, not a fork: pristine upstream OBI plus a small,
numbered patch stack, regenerated against each upstream tag.

## Layout

```
upstream/                 git submodule: open-telemetry/opentelemetry-ebpf-instrumentation @ v0.12.2 (pristine)
                          (.gitmodules points at GitHub; this local clone was initialised from the
                           local fork checkout, so no network is needed)
patches/                  git format-patch stack applied in order on top of upstream/
  01-tcp-service-name.patch            server writes its service.name into a TCP option (kind 26); client records it
                                       (tpinjector), incl. the server-response capture fix for kprobe-traced servers
  02-http2-multiplex.patch             capture every HTTP/2 stream on a multiplexed connection (+ unit/integration test)
  03-peer-service-name-red-attrs.patch peer.service.name on client spans and on http.client.request.duration
  04-forwarded-host.patch              server spans: X-Forwarded-Host (else Host) as x-forwarded-host, and without
                                       the port as peer.service.name on HTTP server RED (topology through L7 LBs)
  99-pin-to-cwagent.patch              go.mod pinned to cwagent's dependency versions + forced code adaptations (ALWAYS LAST)
obi/                      GENERATED, committed: upstream/ + patches/ as plain code (minus .github/ and
                          internal/test/integration/). Committed together with patches/ so every commit shows
                          the real code change. Never edit; scripts/check-obi.sh (CI + pre-commit) enforces it
receiver/obireceiver/     Go module github.com/aws-observability/adot-obi/receiver/obireceiver - the factory cwagent
                          registers; thin wrapper over go.opentelemetry.io/obi/collector with cwagent defaults
processor/                config-only replacement for collector-side bits (aws.vpc.id / aws.subnet.id via resource processor)
config/otel.yaml          default OTel config baked into BOTH images (/etc/otelcol/config.yaml = the collector's
                          default --config; /etc/cwagent/otel.yaml for cwagent). OBI -> X-Ray traces + CloudWatch
                          OTLP metrics, AWS SDK spans on. AWS_REGION overrides the region; mount your own file over
                          that path to replace it. CI validates it inside the collector image
collector/                standalone eBPF collector distribution (OCB builder-config + Dockerfile) built from the same
                          build/obi as cwagent - for demos and A/B checks; image label io.adot-obi.source = tag+patch hash
cwagent/                  the cwagent change (format-patch of branch exp/obi-receiver on v1.300074.0): 0001 registers
                          the obi receiver; 0002-0003 make the RPM run the agent as cwagent with 7 ambient caps
                          (systemd drop-in service.d/ebpf.conf, no SYS_ADMIN). CI applies all of them
scripts/
  apply-patches.sh        upstream/ + patches/ -> build/obi (git repo, one commit per patch, tag `upstream`)
  generate-bpf.sh         `make docker-generate` in build/obi, twice, sha256-compared (reproducibility)
  refresh-patches.sh      export build/obi commits back to patches/ (name from `Adot-Obi-Patch:` trailer)
  sync-obi.sh             build/obi -> obi/ (the committed snapshot; excludes per obi-snapshot.exclude)
  check-obi.sh            regenerate in a temp dir and fail if obi/ differs from upstream/ + patches/
  install-hooks.sh        pre-commit hook running check-obi.sh when patches/ or obi/ change
  pin-to-cwagent.sh       regenerate the go.mod part of 99-pin-to-cwagent from a cwagent go.mod
  build-cwagent.sh        build the test cwagent (linux/amd64) against build/obi + receiver
  make-release.sh         commit build/obi INCLUDING generated BPF bindings to branch `release`, tag obi/<tag>-adot.<n>
  build-collector.sh      build the standalone collector image (collector/) from build/obi
ci/
  run.sh                  local pipeline (Linux host): apply -> bpf -> obi -> cwagent -> e2e -> collector, logs in ci/logs/
  run-remote.sh           same, driven from a Mac: rsync to the dev desktop, run, copy logs back
  check-cwagent-versions.sh  fails if cwagent's collector/otel/contrib versions moved
test/e2e/                 runtime test: 2-tier HTTP app, agent under 6/7 capabilities, debug-exporter output assertions
```

## Where this lives on GitHub

Branch `adot-obi` of the OBI fork `github.com/wangzlei/opentelemetry-ebpf-instrumentation`
(an orphan branch: its history is unrelated to the fork's OBI branches). Every push runs
`.github/workflows/build-images.yml`, which

- applies the patches, generates BPF, runs the CI gates (`ci/run.sh apply bpf obi cwagent collector`);
- pushes two images built from the same patched tree, both labelled `io.adot-obi.source`:
  - `ghcr.io/wangzlei/adot-obi-collector:<sha>|latest` - standalone OTel Collector + OBI receiver
  - `ghcr.io/wangzlei/adot-obi-cwagent:<sha>|latest` - CloudWatch Agent + OBI receiver
- first checks that `obi/` equals upstream + patches (`scripts/check-obi.sh`);
- force-updates branch `adot/<upstream tag>` = the upstream tag plus one commit per patch, to read the
  patched code patch by patch on GitHub.

Edit `patches/` here (via build/obi + refresh-patches.sh), never `adot/<tag>` directly.

## Tracking changes (for people and AI agents)

| Question | Where to look |
|---|---|
| What does the patched code look like? | `obi/` in this repo (committed, always in sync), or branch `adot/<upstream tag>` on GitHub |
| What did we change relative to upstream, and why? | One commit per patch: `git -C build/obi log upstream..HEAD`, then `git show <commit>`. The message says what and why; the `Source:` line names the original fork commits; the `Adot-Obi-Patch: NN-name` trailer names the patch file |
| What changed in the code in a given commit? | `git show <commit> -- obi/` (or the commit page on GitHub): the patch edit and its real code effect are in the same commit |
| What changed between any two versions? | `git diff <commitA> <commitB> -- obi/` |
| Who/when changed a given line of patched code? | `git blame obi/<path>` |
| Why was a patch reshaped? | This repo's history: `git log -p -- patches/` and the commit messages here |

Rules that keep this traceable:

- Never edit `obi/` or `adot/<tag>`. Change code in `build/obi`, amend the commit of the patch it
  belongs to, run `scripts/refresh-patches.sh` then `scripts/sync-obi.sh`, and commit `patches/`
  and `obi/` together with a message saying what changed and why.
- One concern per patch. A new feature becomes a new numbered patch between `03` and `99`;
  `99-pin-to-cwagent` always stays last.
- Keep each patch's commit message current: what it does, why upstream does not already do it,
  and its `Source:` provenance.

## Version matrix

| adot-obi       | upstream OBI | cwagent     | collector (stable / 0.x) | otel-go | go     |
|----------------|--------------|-------------|--------------------------|---------|--------|
| v0.12.2-adot.1 | v0.12.2      | v1.300074.0 | v1.56.0 / v0.150.0       | v1.44.0 | 1.25.8 |

Upstream OBI v0.12.2 itself is on collector v1.64.0/v0.158.0, otel v1.45.0, go 1.25.11 -
the gap is absorbed by `99-pin-to-cwagent`.

## Workflows

```bash
git submodule update --init                 # upstream/ at the pinned tag
scripts/apply-patches.sh                    # -> build/obi
# edit in build/obi, commit with trailer "Adot-Obi-Patch: NN-name" (amend into the right commit) then:
scripts/refresh-patches.sh                  # -> patches/
scripts/sync-obi.sh                         # -> obi/ (commit together with patches/)
scripts/install-hooks.sh                    # once: pre-commit consistency check
scripts/generate-bpf.sh                     # Linux + docker; bindings are gitignored upstream
ci/run.sh                                   # or: DEVDSK=<linux host> ci/run-remote.sh from a Mac
```

**Rebasing onto a new upstream tag**: move the submodule to the tag, run apply-patches
(fix conflicts with `git am --3way`), then drop and regenerate 99 with
`scripts/pin-to-cwagent.sh build/obi <cwagent go.mod>` and fix compile/test breaks.

**Releases / why generated BPF is committed**: cwagent's internal build pulls Go modules
through a GOPROXY and has no clang, so the module it consumes must already contain
`*_bpfel.go`/`*_bpfel.o`. `scripts/make-release.sh` puts build/obi (with bindings) under
`obi/` on the `release` branch and tags `obi/v0.12.2-adot.N`; cwagent then uses
`replace go.opentelemetry.io/obi => github.com/aws-observability/adot-obi/obi v0.12.2-adot.N`
(the module path inside stays `go.opentelemetry.io/obi`). Locally simulated only; nothing pushed.

## Receiver defaults (cwagent)

`ebpf.context_propagation: tcp` (no header injection, which needs CAP_SYS_ADMIN via
bpf_probe_write_user for Go), network flow metrics off, `enforce_sys_caps: false`.
The YAML block under `receivers: obi:` is OBI's standard config schema. Nothing is
instrumented until `discovery` selects targets.

Required capabilities: CAP_BPF, CAP_PERFMON, CAP_SYS_PTRACE, CAP_DAC_READ_SEARCH,
CAP_CHECKPOINT_RESTORE, CAP_NET_RAW, + CAP_NET_ADMIN for context propagation. No CAP_SYS_ADMIN.
Caveats: kernels < 5.11 also want CAP_SYS_RESOURCE (or a high RLIMIT_MEMLOCK set by the
service manager); on cgroup-v1 hosts (Amazon Linux 2) TCP propagation needs a cgroup2
hierarchy at /sys/fs/cgroup/unified, otherwise OBI's fallback (fsmount) needs CAP_SYS_ADMIN
and propagation is silently off (RED still works, no peer.service.name).
