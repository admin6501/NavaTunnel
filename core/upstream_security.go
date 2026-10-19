// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"net"
	"net/http"

	"os"
	"strings"
)

func IsTrustedProxy(ipStr string) bool {
	ipStr = strings.TrimSpace(ipStr)
	if ipStr == "" {
		return false
	}
	if strings.EqualFold(ipStr, "localhost") {
		ipStr = "127.0.0.1"
	}
	parsedIP := net.ParseIP(ipStr)

	raw := os.Getenv("TRUSTED_PROXY_IPS")
	if raw == "" {
		return false
	}

	if parsedIP == nil {
		return false
	}

	parts := strings.Split(raw, ",")
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}

		if strings.Contains(p, "/") {
			_, subnet, err := net.ParseCIDR(p)
			if err == nil && subnet.Contains(parsedIP) {
				return true
			}
			continue
		}

		if target := net.ParseIP(p); target != nil {
			if target.Equal(parsedIP) {
				return true
			}
		}
	}
	return false
}

func ClientIP(r *http.Request) string {
	if r == nil {
		return ""
	}

	remoteHost, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		remoteHost = strings.Trim(r.RemoteAddr, "[]")
	}

	if IsTrustedProxy(remoteHost) {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			candidate := strings.TrimSpace(parts[0])
			if candidate != "" {
				if host, _, err := net.SplitHostPort(candidate); err == nil {
					return host
				}
				return strings.Trim(candidate, "[]")
			}
		}
		if xri := r.Header.Get("X-Real-IP"); xri != "" {
			cand := strings.TrimSpace(xri)
			if host, _, err := net.SplitHostPort(cand); err == nil {
				return host
			}
			return strings.Trim(cand, "[]")
		}
	}

	return remoteHost
}
