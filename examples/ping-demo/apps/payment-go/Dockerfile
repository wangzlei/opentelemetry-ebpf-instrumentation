# Ping demo payment service -- Go (net/http, stdlib only), static binary.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod *.go ./
ENV CGO_ENABLED=0 GOFLAGS=-trimpath GOPROXY=https://goproxy.cn,direct GOSUMDB=off
# Not stripped (no -s -w): OBI Go uprobes resolve functions from the symbol table.
# `-o /out/` (a directory) lets go build name the binary after the last element of the module path
# (go.mod: module ping/payment) -> "payment", which is what the agent's autoname reads.
RUN go vet ./... && go test ./... && go build -o /out/ . && ls -l /out/payment

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/payment /usr/local/bin/payment
ENV PORT=8000 ROLE=payment PROFILE=healthy USE_TLS=0 CPU_SHARE=0
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/payment"]
