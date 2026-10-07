# Standalone eBPF collector image. Build context: build/obi with the OCB output
# already generated into build/obi/otelcol-obi (scripts/build-collector.sh does
# both). The patched tree ships its generated BPF bindings, so no clang is needed.
FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder
RUN apk add --no-cache git gcc musl-dev linux-headers
WORKDIR /app
COPY . .
WORKDIR /app/otelcol-obi
# GOPROXY/GOSUMDB come from build args, so networks that block the default proxy
# can pass GOPROXY=direct; -buildvcs=false because the context has only a
# partial .git.
ARG GOPROXY=https://proxy.golang.org,direct
ARG GOSUMDB=sum.golang.org
ENV GOPROXY=${GOPROXY} GOSUMDB=${GOSUMDB} GOTOOLCHAIN=local CGO_ENABLED=0
RUN go build -buildvcs=false -trimpath -o /otelcol .

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk add --no-cache ca-certificates
COPY --from=builder /otelcol /otelcol
ARG OBI_SOURCE=unknown
# Identifies the exact patched OBI tree, so an image can be matched to the
# cwagent build that carries the same code (see scripts/build-collector.sh).
LABEL org.opencontainers.image.title="otelcol-obi" \
      io.adot-obi.source="${OBI_SOURCE}"
ENTRYPOINT ["/otelcol"]
