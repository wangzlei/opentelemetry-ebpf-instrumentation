// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <bpfcore/vmlinux.h>

#include <common/h2_tp_huffman.h>
#include <common/http_types.h>

typedef struct grpc_frames_ctx {
    http2_grpc_request_t prev_info;
    u8 has_prev_info;
    u8 found_data_frame;
    u8 iterations;
    u8 terminate_search;

    int pos; //FIXME should be size_t equivalent
    int saved_buf_pos;
    u32 saved_stream_id;
    // resume_frame_scan: byte offset just past the frame whose handler was
    // tail-called, so that handler can hand control back to the frame scan and
    // the remaining multiplexed streams in the same buffer get processed too.
    // _pad keeps this block 8-byte aligned (BPF is built -Werror -Wpadded).
    int resume_pos;
    u32 _pad_resume;
    call_protocol_args_t args;
    http2_conn_stream_t stream;

    // set by the server scan, consumed by the huffman decode program
    h2_tp_huff_candidate_t huff;
    // candidate list backing huff, so a rejected candidate can be retried
    h2_tp_huff_scan_t huff_scan;
} grpc_frames_ctx_t;
