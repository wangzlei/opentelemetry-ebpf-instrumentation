// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linux && (amd64 || arm64)

package obireceiver // import "github.com/aws-observability/adot-obi/receiver/obireceiver"

import (
	"go.opentelemetry.io/obi/pkg/config"
	"go.opentelemetry.io/obi/pkg/obi"
)

// DefaultOBIConfig returns OBI's defaults adjusted for the CloudWatch Agent:
//
//   - ebpf.context_propagation: "tcp". Context (and, with the ADOT patches, the
//     downstream service name -> peer.service.name) is carried in a TCP option
//     only. "headers"/"all" are not the default because Go library-level header
//     injection uses bpf_probe_write_user, which needs CAP_SYS_ADMIN, and
//     because rewriting HTTP payloads is more intrusive than a TCP option.
//     Requires CAP_NET_ADMIN; set "disabled" to run without it.
//   - network flow metrics (network.enable) off: they are a separate,
//     high-cardinality feature that CloudWatch customers opt into explicitly.
//   - enforce_sys_caps false: missing capabilities are logged, and individual
//     features degrade, instead of failing agent startup.
//
// Everything else (RED metrics features, discovery defaults, buffer sizes) is
// OBI's upstream default.
func DefaultOBIConfig() *obi.Config {
	cfg := obi.DefaultConfig
	cfg.EBPF.ContextPropagation = config.ContextPropagationTCP
	cfg.NetworkFlows.Enable = false
	cfg.EnforceSysCaps = false
	return &cfg
}
