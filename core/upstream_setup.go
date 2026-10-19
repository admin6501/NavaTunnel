// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"encoding/json"

	"io"

	"net"
	"net/http"
	"os"

	"path/filepath"

	"strings"
	"sync"
	"time"
)

const (
	defaultIranGRE    = "10.10.10.2"
	defaultForeignGRE = "10.10.10.1"
	defaultFrpPortMin = 20000
	defaultFrpPortMax = 60000

	bundlePrefix            = "hsh1_"
	bundlePrefixBackhaul    = "bh1_"
	bundlePrefixGreBackhaul = "gh1_"
)

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func detectPublicIP() string {
	src := routeSourceIP()
	if src != "" && !isPrivateIP(src) {
		return src
	}
	if v := savedPublicIP(); v != "" {
		return v
	}
	if v := externalPublicIPCached(); v != "" {
		return v
	}
	return src
}

func routeSourceIP() string {
	out, err := runCmdTimeout(5*time.Second, "ip", "route", "get", "1.1.1.1")
	if err == nil {
		f := strings.Fields(string(out))
		for i, p := range f {
			if p == "src" && i+1 < len(f) {
				if net.ParseIP(f[i+1]) != nil {
					return f[i+1]
				}
			}
		}
	}
	return ""
}

func savedPublicIP() string {
	var meta struct {
		LocalPub string `json:"local_public"`
	}
	if data, err := os.ReadFile(filepath.Join(configDir, "setup.json")); err == nil {
		_ = json.Unmarshal(data, &meta)
	}
	if ip := strings.TrimSpace(meta.LocalPub); net.ParseIP(ip) != nil && !isPrivateIP(ip) {
		return ip
	}
	return ""
}

var (
	extIPMu   sync.Mutex
	extIPVal  string
	extIPTime time.Time

	externalIPLookup = lookupExternalPublicIP
)

func externalPublicIPCached() string {
	extIPMu.Lock()
	defer extIPMu.Unlock()
	if extIPVal != "" && time.Since(extIPTime) < 30*time.Minute {
		return extIPVal
	}
	if extIPVal == "" && !extIPTime.IsZero() && time.Since(extIPTime) < 2*time.Minute {
		return ""
	}
	extIPTime = time.Now()
	if v := externalIPLookup(); v != "" {
		extIPVal = v
	}
	return extIPVal
}

func lookupExternalPublicIP() string {
	dialer := &net.Dialer{Timeout: 1200 * time.Millisecond}
	client := &http.Client{Timeout: 1200 * time.Millisecond, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", addr)
		},
	}}
	for _, u := range []string{"https://api.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"} {
		resp, err := client.Get(u)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64))
		_ = resp.Body.Close()
		candidate := strings.TrimSpace(string(body))
		if resp.StatusCode == 200 && isV4(candidate) && !isPrivateIP(candidate) {
			return candidate
		}
	}
	return ""
}
