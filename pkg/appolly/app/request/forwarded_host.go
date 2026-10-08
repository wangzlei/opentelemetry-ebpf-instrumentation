// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package request // import "go.opentelemetry.io/obi/pkg/appolly/app/request"

import (
	"net"
	"strings"
)

// ForwardedHostName turns a raw X-Forwarded-Host / Host header value into a bare
// host name: the first entry of a comma-separated proxy chain, without the port
// or IPv6 brackets. Returns "" for an empty value.
func ForwardedHostName(v string) string {
	if i := strings.IndexByte(v, ','); i >= 0 {
		v = v[:i]
	}
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if host, _, err := net.SplitHostPort(v); err == nil {
		return host
	}
	return strings.Trim(v, "[]")
}
