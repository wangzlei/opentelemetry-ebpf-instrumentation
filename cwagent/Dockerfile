# CloudWatch Agent (with the ADOT OBI receiver) image. Build context: the
# directory holding the agent binary built by scripts/build-cwagent.sh
# (build/cwagent/bin/linux_amd64). The binary is statically linked.
#
# Runs on OTel YAML only: -otelconfig points at a mounted file; the TOML the CLI
# requires is intentionally empty.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
RUN dnf install -y ca-certificates && dnf clean all
COPY amazon-cloudwatch-agent /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent
RUN mkdir -p /etc/cwagent && : > /etc/cwagent/empty.toml
ARG OBI_SOURCE=unknown
LABEL org.opencontainers.image.title="cwagent-obi" \
      io.adot-obi.source="${OBI_SOURCE}"
ENTRYPOINT ["/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent", "-config", "/etc/cwagent/empty.toml", "-otelconfig", "/etc/cwagent/otel.yaml"]
