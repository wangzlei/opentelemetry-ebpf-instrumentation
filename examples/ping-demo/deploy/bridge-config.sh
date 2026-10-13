#!/usr/bin/env bash
# ping demo: Omni bridge export from the CloudWatch agent's OBI pipeline, WITHOUT changing the RPM.
#
#   REGION=us-east-1 ./bridge-config.sh                 # write/remove on all hosts + restart agent
#   OMNI_BRIDGE_ENDPOINT=http://<ip>:4318 ./bridge-config.sh   # override env/<region>.env
#   ./bridge-config.sh --ids "<id> ..."                 # only these hosts
#   ./bridge-config.sh --script                         # print the host-side snippet only
#
# How: start-amazon-cloudwatch-agent passes etc/ebpf/obi.yaml (eBPF on) and then EVERY *.yaml in
# etc/amazon-cloudwatch-agent.d/ as -otelconfig; the agent merges them but rejects a key that is
# defined twice with a different value (receivers/processors/exporters/extensions/
# service::pipelines). So this file cannot add an exporter to obi.yaml's `metrics` pipeline; it adds
# a NEW exporter and a NEW pipeline `metrics/omni_bridge` that reuses obi.yaml's obi receiver,
# transform/aws, cumulativetodelta and batch (each pipeline gets its own processor instances; the
# receiver fans out to both pipelines). Same post-delta data as the CloudWatch arm, separate batches.
#
# The file is not owned by the RPM, so it survives Distributor upgrades (uninstall + install; the
# package's install.sh only deletes .d/obi.yaml) and `-a fetch-config` is the only thing that
# empties .d (the demo never runs it). Bounded like the old collector's bridge exporter: no retries,
# 10 s timeout, 100-batch queue, so a dead bridge drops instead of growing the agent's memory.
# OMNI_BRIDGE_ENDPOINT empty -> the file is removed (us-west-2: no bridge).
. "$(dirname "$0")/lib.sh"
F=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/omni-bridge.yaml

snippet() {
  if [ -z "$OMNI_BRIDGE_ENDPOINT" ]; then
    echo "rm -f $F && echo 'omni bridge: off'"
    return
  fi
  cat <<EOF
cat > $F <<'YAML'
# Omni bridge export (ping demo deploy/bridge-config.sh). Removing this file + agent restart = off.
exporters:
  otlp_http/omni_bridge:
    metrics_endpoint: $OMNI_BRIDGE_ENDPOINT/v1/metrics
    compression: gzip
    timeout: 10s
    retry_on_failure:
      enabled: false
    sending_queue:
      enabled: true
      queue_size: 100
      num_consumers: 2
service:
  pipelines:
    metrics/omni_bridge:
      receivers: [obi]
      processors: [transform/aws, cumulativetodelta, batch]
      exporters: [otlp_http/omni_bridge]
YAML
chmod 644 $F && echo "omni bridge: $OMNI_BRIDGE_ENDPOINT"
EOF
}

if [ "${1:-}" = --script ]; then snippet; exit; fi
check_account
IDS=""; [ "${1:-}" = --ids ] && IDS=${2:?}
IDS=${IDS:-$(all_ids)}
log "omni bridge ${OMNI_BRIDGE_ENDPOINT:-off} on $(echo "$IDS" | wc -w) hosts (+ agent restart)"
ssm_run "set -e
$(snippet)
systemctl restart amazon-cloudwatch-agent; sleep 15; systemctl is-active amazon-cloudwatch-agent
grep -c 'merge conflict' /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log | sed 's/^/merge-conflicts-in-log=/'" $IDS
