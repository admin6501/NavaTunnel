// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"encoding/json"

	"net"
	"net/http"

	"os/exec"

	"strconv"
)

var configDir = "/etc/gre-panel"

var (
	frpDir      = "/etc/frp"
	backhaulDir = "/etc/backhaul"
)

var runSystemctl = func(args ...string) error {
	return exec.Command("systemctl", args...).Run()
}

func saveCfg() {
	_ = saveConfigAtomic(cfg)
}

func portFree(port int) bool {
	ln, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return false
	}
	_ = ln.Close()
	return true
}

func mustJSON(v any) []byte {
	b, _ := json.MarshalIndent(v, "", "  ")
	return b
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
