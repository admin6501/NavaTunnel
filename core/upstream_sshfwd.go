// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"

	"strings"
	"sync"
	"time"
)

type SSHFwdConfig struct {
	Role                string `json:"role"`
	Mode                string `json:"mode"`
	RemoteHost          string `json:"remote_host"`
	RemoteUser          string `json:"remote_user"`
	RemoteSSHPort       int    `json:"remote_ssh_port"`
	KeyPath             string `json:"key_path"`
	Ports               []int  `json:"ports"`
	BindAddr            string `json:"bind_addr"`
	FRPBindPort         int    `json:"frp_bind_port"`
	PoolCount           int    `json:"pool_count"`
	Enabled             bool   `json:"enabled"`
	ServerAliveInterval int    `json:"server_alive_interval"`
	ServerAliveCountMax int    `json:"server_alive_count_max"`
	LastStatus          string `json:"last_status"`
	LastError           string `json:"last_error"`
	UpdatedAt           string `json:"updated_at"`
}

var (
	sshFwdMu sync.Mutex
)

func defaultSSHFwdKeyPath() string {
	if os.Geteuid() != 0 || strings.Contains(configDir, "gre-panel-test-") {
		return filepath.Join(configDir, "navatunnel-fwd")
	}
	return "/root/.ssh/navatunnel-fwd"
}

func defaultSSHFwdConfig() SSHFwdConfig {
	return SSHFwdConfig{
		Role:                "iran",
		Mode:                "navalink",
		RemoteHost:          "",
		RemoteUser:          "root",
		RemoteSSHPort:       22,
		KeyPath:             defaultSSHFwdKeyPath(),
		Ports:               []int{},
		BindAddr:            "0.0.0.0",
		FRPBindPort:         55400,
		PoolCount:           5,
		Enabled:             false,
		ServerAliveInterval: 15,
		ServerAliveCountMax: 3,
		LastStatus:          "inactive",
		LastError:           "",
		UpdatedAt:           "",
	}
}

func sshFwdConfigFile() string {
	return filepath.Join(configDir, "sshfwd.json")
}

func loadSSHFwdConfigLocked() SSHFwdConfig {
	cfg := defaultSSHFwdConfig()
	b, err := os.ReadFile(sshFwdConfigFile())
	if err == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	cfg.Mode = "navalink"
	if cfg.RemoteUser == "" {
		cfg.RemoteUser = "root"
	}
	if cfg.RemoteSSHPort <= 0 {
		cfg.RemoteSSHPort = 22
	}
	if cfg.KeyPath == "" || (os.Geteuid() != 0 && strings.HasPrefix(cfg.KeyPath, "/root")) {
		cfg.KeyPath = defaultSSHFwdKeyPath()
	}
	if cfg.Ports == nil {
		cfg.Ports = []int{}
	}
	if cfg.BindAddr == "" {
		cfg.BindAddr = "0.0.0.0"
	}
	if cfg.FRPBindPort <= 0 {
		cfg.FRPBindPort = 55400
	}
	if cfg.PoolCount <= 0 {
		cfg.PoolCount = 25
	}
	if cfg.ServerAliveInterval <= 0 {
		cfg.ServerAliveInterval = 10
	}
	if cfg.ServerAliveCountMax <= 0 {
		cfg.ServerAliveCountMax = 3
	}
	return cfg
}

func isPrivateIP(ipStr string) bool {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return true
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
		return true
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	if ip4[0] == 10 {
		return true
	}
	if ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31 {
		return true
	}
	if ip4[0] == 192 && ip4[1] == 168 {
		return true
	}
	if ip4[0] == 100 && ip4[1]&0xC0 == 64 {
		return true
	}
	return false
}

func formatByteSize(b int64) string {
	if b <= 0 {
		return "0 B"
	}
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}

type NavaLinkLiveMetrics struct {
	Connected      bool    `json:"connected"`
	StatusText     string  `json:"status_text"`
	LatencyMs      float64 `json:"latency_ms"`
	RxBytes        int64   `json:"rx_bytes"`
	TxBytes        int64   `json:"tx_bytes"`
	TotalBytes     int64   `json:"total_bytes"`
	RxFormatted    string  `json:"rx_formatted"`
	TxFormatted    string  `json:"tx_formatted"`
	TotalFormatted string  `json:"total_formatted"`
	CurConns       int     `json:"cur_conns"`
	ClientCounts   int     `json:"client_counts"`
}

func getNavaLinkLiveMetrics(cfg SSHFwdConfig) NavaLinkLiveMetrics {
	isForeign := cfg.Role == "foreign" || cfg.Role == "server"
	if !isForeign {
		outFrpc, _ := runCmd("systemctl", "is-active", "navatunnel-navalink-frpc.service")
		if strings.TrimSpace(outFrpc) == "active" {
			isForeign = true
		}
	}

	if isForeign {
		outFrpc, _ := runCmd("systemctl", "is-active", "navatunnel-navalink-frpc.service")
		if strings.TrimSpace(outFrpc) != "active" {
			return NavaLinkLiveMetrics{Connected: false, StatusText: "inactive", RxFormatted: "0 B", TxFormatted: "0 B", TotalFormatted: "0 B"}
		}

		t0 := time.Now()
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.FRPBindPort), 600*time.Millisecond)
		var lat float64
		connected := false
		statusText := "waiting_for_iran"
		if err == nil {
			lat = float64(time.Since(t0).Microseconds()) / 1000.0
			_ = conn.Close()
			connected = true
			statusText = "connected"
		}

		return NavaLinkLiveMetrics{
			Connected:      connected,
			StatusText:     statusText,
			LatencyMs:      lat,
			RxFormatted:    "0 B",
			TxFormatted:    "0 B",
			TotalFormatted: "0 B",
			ClientCounts:   1,
		}
	}

	outNavaLink, _ := runCmd("systemctl", "is-active", "navatunnel-navalink.service")
	outFrps, _ := runCmd("systemctl", "is-active", "navatunnel-navalink-frps.service")
	navalinkActive := strings.TrimSpace(outNavaLink) == "active"
	frpsActive := strings.TrimSpace(outFrps) == "active"

	if !navalinkActive && !frpsActive {
		return NavaLinkLiveMetrics{Connected: false, StatusText: "inactive", RxFormatted: "0 B", TxFormatted: "0 B", TotalFormatted: "0 B"}
	}

	var lat float64
	if cfg.RemoteHost != "" {
		remoteSSHPort := cfg.RemoteSSHPort
		if remoteSSHPort <= 0 {
			remoteSSHPort = 22
		}
		tRemote := time.Now()
		rConn, rErr := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", cfg.RemoteHost, remoteSSHPort), 600*time.Millisecond)
		if rErr == nil {
			lat = float64(time.Since(tRemote).Microseconds()) / 1000.0
			_ = rConn.Close()
		}
	}
	if lat <= 0 {
		t0 := time.Now()
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.FRPBindPort), 400*time.Millisecond)
		if err == nil {
			lat = float64(time.Since(t0).Microseconds()) / 1000.0
			_ = conn.Close()
		}
	}

	dashPort := cfg.FRPBindPort + 1
	dashURL := fmt.Sprintf("http://127.0.0.1:%d/api/serverinfo", dashPort)
	client := &http.Client{Timeout: 400 * time.Millisecond}
	req, err := http.NewRequest("GET", dashURL, nil)
	var rx, tx int64
	var clientCount, curConns int
	gotDashboard := false
	if err == nil {
		req.SetBasicAuth("admin", "navalink-dash-local")
		resp, rErr := client.Do(req)
		if rErr == nil && resp.StatusCode == 200 {
			var info struct {
				TotalTrafficIn  int64 `json:"totalTrafficIn"`
				TotalTrafficOut int64 `json:"totalTrafficOut"`
				CurConns        int   `json:"curConns"`
				ClientCounts    int   `json:"clientCounts"`
			}
			if json.NewDecoder(resp.Body).Decode(&info) == nil {
				rx = info.TotalTrafficIn
				tx = info.TotalTrafficOut
				curConns = info.CurConns
				clientCount = info.ClientCounts
				gotDashboard = true
			}
			_ = resp.Body.Close()
		}
	}

	connected := false
	statusText := "waiting_for_peer"
	if gotDashboard {
		if clientCount > 0 {
			connected = true
			statusText = "connected"
		}
	} else {
		outSS, _ := runCmd("ss", "-tn", "state", "established", fmt.Sprintf("sport = :%d or dport = :%d", cfg.FRPBindPort, cfg.FRPBindPort))
		lines := strings.Split(strings.TrimSpace(outSS), "\n")
		if len(lines) > 1 {
			connected = true
			statusText = "connected"
			clientCount = 1
		}
	}

	tot := rx + tx
	return NavaLinkLiveMetrics{
		Connected:      connected,
		StatusText:     statusText,
		LatencyMs:      lat,
		RxBytes:        rx,
		TxBytes:        tx,
		TotalBytes:     tot,
		RxFormatted:    formatByteSize(rx),
		TxFormatted:    formatByteSize(tx),
		TotalFormatted: formatByteSize(tot),
		CurConns:       curConns,
		ClientCounts:   clientCount,
	}
}

var navalinkUnitNames = []string{"navatunnel-navalink", "navatunnel-navalink-frpc", "navatunnel-navalink-frps", "navatunnel-ssh-fwd", "navatunnel-frp-ssh-tunnel"}

func navalinkUnitInstalled() bool {
	for _, n := range navalinkUnitNames {
		if _, err := os.Stat(filepath.Join("/etc/systemd/system", n+".service")); err == nil {
			return true
		}
	}
	return false
}

func getSSHFwdSnapshotStatus() map[string]any {
	sshFwdMu.Lock()
	defer sshFwdMu.Unlock()
	cfg := loadSSHFwdConfigLocked()
	configured := cfg.Enabled || (strings.TrimSpace(cfg.RemoteHost) != "" && len(cfg.Ports) > 0) || navalinkUnitInstalled()
	if !configured {
		return map[string]any{"has_config": false, "enabled": false, "is_active": false, "connected": false}
	}
	isActive := false
	for _, n := range navalinkUnitNames {
		if out, _ := runCmd("systemctl", "is-active", n+".service"); strings.TrimSpace(out) == "active" {
			isActive = true
			break
		}
	}
	metrics := getNavaLinkLiveMetrics(cfg)
	return map[string]any{
		"has_config":      true,
		"enabled":         cfg.Enabled || isActive,
		"is_active":       isActive,
		"mode":            cfg.Mode,
		"role":            cfg.Role,
		"remote_host":     cfg.RemoteHost,
		"ports":           cfg.Ports,
		"frp_bind_port":   cfg.FRPBindPort,
		"last_error":      cfg.LastError,
		"connected":       metrics.Connected,
		"status_text":     metrics.StatusText,
		"latency_ms":      metrics.LatencyMs,
		"rx_bytes":        metrics.RxBytes,
		"tx_bytes":        metrics.TxBytes,
		"total_bytes":     metrics.TotalBytes,
		"rx_formatted":    metrics.RxFormatted,
		"tx_formatted":    metrics.TxFormatted,
		"total_formatted": metrics.TotalFormatted,
		"cur_conns":       metrics.CurConns,
		"client_counts":   metrics.ClientCounts,
	}
}
