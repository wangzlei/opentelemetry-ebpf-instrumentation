# CloudWatch Agent (with the ADOT OBI receiver) image. Build context: the
# directory holding the agent binary built by scripts/build-cwagent.sh
# (build/cwagent/bin/linux_amd64). The binary is statically linked.
#
# Runs on OTel YAML only: -otelconfig points at /etc/cwagent/otel.yaml (default
# baked in, overridable by a mount); the TOML the CLI requires is intentionally empty.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
RUN dnf install -y ca-certificates && dnf clean all
COPY amazon-cloudwatch-agent /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent
# Default config (config/otel.yaml, copied next to the binary by build-cwagent.sh);
# mount your own file over /etc/cwagent/otel.yaml to replace it.
COPY otel.yaml /etc/cwagent/otel.yaml
RUN mkdir -p /etc/cwagent && : > /etc/cwagent/empty.toml
ARG OBI_SOURCE=unknown
LABEL org.opencontainers.image.title="cwagent-obi" \
      io.adot-obi.source="${OBI_SOURCE}"
ENTRYPOINT ["/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent", "-config", "/etc/cwagent/empty.toml", "-otelconfig", "/etc/cwagent/otel.yaml"]
