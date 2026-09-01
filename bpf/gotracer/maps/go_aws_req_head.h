// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <bpfcore/vmlinux.h>
#include <bpfcore/bpf_helpers.h>

#include <common/common.h> // GO_AWS_REQ_HEAD_SIZE
#include <common/connection_info.h>
#include <common/map_sizing.h>
#include <common/pin_internal.h>

// Hand-off of the raw HTTPS request head from the crypto/tls probe to the
// net/http roundTrip probe, for AWS SDK semantic detail (rpc.service /
// rpc.method) on Go clients.
//
// Why this exists. Go HTTPS clients are covered by two independent probes:
//   * crypto/tls.(*Conn).Write  -- sees the request bytes in the clear, but has
//     no notion of the HTTP request as a unit;
//   * net/http.(*Transport).roundTrip -- reads method/URL.Path/URL.Host straight
//     out of the http.Request struct, which is richer (it is where http.route
//     comes from) but carries NO headers.
// When roundTrip claims a connection (handled_by_go_conn) the tls probe bails out
// so the request is not reported twice. That dedup is correct, but it also throws
// away the only copy of the request headers, so `X-Amz-Target` -- which is what
// identifies the AWS operation for every AWS-JSON/RPC service -- never reaches
// userspace. The result was that the same S3 call showed up as "S3.ListBuckets"
// from a Python service and as a bare "GET /" from a Go one.
//
// So instead of dropping the bytes, the tls probe stashes the head of the request
// here, keyed by the connection, and the roundTrip return path picks it up and
// ships it alongside the struct-derived fields. The userspace AWS parser is
// unchanged: it already works off exactly this kind of buffer.
//
// Measured on the cluster (Go net/http + aws-sdk-go-v2): ONE Write per request,
// starting at the request line -- 1998 bytes for S3 ListBuckets, 767 for a
// DynamoDB call. net/http buffers the whole header block through a 4096-byte
// bufio.Writer, so a head never arrives split as long as it fits. Should one ever
// exceed that, this captures the first segment.

// Gate for the whole hand-off. Set from payload_extraction.http.aws.enabled, so
// when AWS parsing is off the verifier's constant propagation + dead code
// elimination removes the capture entirely and it costs nothing.
volatile const u32 http_aws_semantics = 0;

// GO_AWS_REQ_HEAD_SIZE lives in common/common.h, next to the event struct that
// carries this buffer to userspace; see there for why it is not FULL_BUF_SIZE.
typedef struct go_aws_req_head {
    unsigned char buf[GO_AWS_REQ_HEAD_SIZE];
    u16 len; // valid bytes in buf; may be < GO_AWS_REQ_HEAD_SIZE for short requests
    u8 _pad[6];
} go_aws_req_head_t;

// LRU rather than a plain hash: an entry is normally consumed by the roundTrip
// return probe, but if that never runs (probe A failed midway, connection torn
// down) the entry must not leak. LRU evicts the oldest instead of failing
// inserts once full.
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __type(key, connection_info_t); // sorted, same key space as handled_by_go_conn
    __type(value, go_aws_req_head_t);
    __uint(max_entries, MAX_CONCURRENT_REQUESTS);
    __uint(pinning, OBI_PIN_INTERNAL);
} go_aws_req_heads SEC(".maps");

// Zeroed template used to create map entries without a ~1 KB stack local (see the
// note on store_go_aws_req_head). A const global lives in .rodata, not on the
// stack.
static const go_aws_req_head_t go_aws_req_head_zero;

// Stash the head of an outgoing HTTPS request. conn must already be sorted, to
// match what the consumer side looks up.
// NOTE ON WHY THIS DOES NOT USE A LOCAL: a go_aws_req_head_t is ~1 KB, and the BPF
// stack is only 512 bytes, so building one on the stack fails to compile ("BPF
// stack limit is exceeded"). Instead we reserve the entry in the map first and
// write through the returned pointer, so the big buffer only ever lives in map
// memory. This is the standard pattern for anything larger than a few hundred
// bytes in BPF.
static __always_inline void
store_go_aws_req_head(const connection_info_t *sorted_conn, const void *u_buf, u64 len) {
    if (!sorted_conn || !u_buf || len == 0) {
        return;
    }

    u32 n = (u32)len;
    bpf_clamp_umax(n, GO_AWS_REQ_HEAD_SIZE);

    // Create (or reuse) the entry, then fill it in place. zero_head is a shared
    // read-only template so we still get a zeroed buffer without a stack copy.
    if (bpf_map_update_elem(&go_aws_req_heads, sorted_conn, &go_aws_req_head_zero, BPF_ANY) != 0) {
        return;
    }

    go_aws_req_head_t *head = bpf_map_lookup_elem(&go_aws_req_heads, sorted_conn);
    if (!head) {
        return;
    }

    // Fixed-size read: the verifier wants a constant length here. A read that runs
    // past the request either fails or yields NULs; head->len records the real
    // length so userspace never looks at the tail.
    if (bpf_probe_read(head->buf, GO_AWS_REQ_HEAD_SIZE, u_buf) != 0) {
        bpf_map_delete_elem(&go_aws_req_heads, sorted_conn);
        return;
    }
    head->len = (u16)n;
}

// Fetch and consume the stashed head for a connection. conn must be sorted.
static __always_inline go_aws_req_head_t *take_go_aws_req_head(connection_info_t *sorted_conn) {
    if (!sorted_conn) {
        return 0;
    }
    return bpf_map_lookup_elem(&go_aws_req_heads, sorted_conn);
}

static __always_inline void drop_go_aws_req_head(connection_info_t *sorted_conn) {
    if (sorted_conn) {
        bpf_map_delete_elem(&go_aws_req_heads, sorted_conn);
    }
}
