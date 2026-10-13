# Ping demo audit service -- Node.js 22 (built-in http, no dependencies). package.json "name" is
# "audit-worker", which the agent's autoname reads.
FROM golang:1.25-alpine AS tls
# Self-signed pair for USE_TLS=1 (demo only); node:22-slim has no openssl CLI.
RUN mkdir /tls && cd /tls && go run "$(go env GOROOT)/src/crypto/tls/generate_cert.go" \
      --host ping --ecdsa-curve P256 --duration 87600h && chmod 644 /tls/*.pem

FROM node:22-slim
WORKDIR /app
COPY package.json server.js cpuwork.js propagate.js ./
COPY --from=tls /tls /app/tls
ENV PORT=8000 ROLE=audit PROFILE=healthy USE_TLS=0 CPU_SHARE=0 NODE_ENV=production
EXPOSE 8000
USER node
CMD ["node", "server.js"]
