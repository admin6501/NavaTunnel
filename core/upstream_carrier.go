// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"

	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type carrierConfig struct {
	Mode          string   `json:"mode"`
	ActiveCarrier string   `json:"active_carrier"`
	FOUPort1      int      `json:"fou_port1"`
	FOUPort2      int      `json:"fou_port2"`
	WSSPort       int      `json:"wss_port"`
	Candidates    []string `json:"candidates"`
	LastSwitch    string   `json:"last_switch"`
	SwitchCount   int      `json:"switch_count"`
}

func carrierConfigPath() string {
	return filepath.Join(configDir, "carrier.json")
}

func defaultCarrierConfig() carrierConfig {
	return carrierConfig{
		Mode:          "direct",
		ActiveCarrier: "direct",
		FOUPort1:      443,
		FOUPort2:      55555,
		WSSPort:       8443,
		Candidates:    []string{"direct", "wss:8443"},
		LastSwitch:    "",
		SwitchCount:   0,
	}
}

func loadCarrierConfig() carrierConfig {
	def := defaultCarrierConfig()
	data, err := os.ReadFile(carrierConfigPath())
	if err != nil {
		return def
	}
	var c carrierConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return def
	}

	return c
}

func saveCarrierConfig(cfg carrierConfig) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(configDir, 0700); err != nil {
		return err
	}
	tmp := carrierConfigPath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, carrierConfigPath())
}

func runNavaTunnelCarrierCmd(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	script, err := greScriptPath()
	if err == nil {
		cmdArgs := append([]string{script, "carrier"}, args...)
		cmd := exec.CommandContext(ctx, "bash", cmdArgs...)
		cmd.Env = append(os.Environ(), "GRE_SKIP_PANEL=1", "TERM=dumb", "GRE_PANEL_DIR="+configDir)
		return cmd.CombinedOutput()
	}
	if fileExists("/usr/local/bin/NavaTunnel") {
		cmdArgs := append([]string{"carrier"}, args...)
		cmd := exec.CommandContext(ctx, "/usr/local/bin/NavaTunnel", cmdArgs...)
		cmd.Env = append(os.Environ(), "GRE_SKIP_PANEL=1", "TERM=dumb", "GRE_PANEL_DIR="+configDir)
		return cmd.CombinedOutput()
	}
	return nil, fmt.Errorf("NavaTunnel script not found")
}

func updateFrpcTransport(proto string) error {
	frpcPath := filepath.Join(frpDir, "frpc.toml")
	data, err := os.ReadFile(frpcPath)
	if err != nil {
		return err
	}
	lines := strings.Split(string(data), "\n")

	curProto, portLine, curPort := "tcp", -1, 0
	for i, line := range lines {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
			switch strings.TrimSpace(k) {
			case "transport.protocol":
				curProto = strings.Trim(strings.TrimSpace(v), `"'`)
			case "serverPort":
				if portLine < 0 {
					portLine = i
					curPort, _ = strconv.Atoi(strings.TrimSpace(v))
				}
			}
		}
	}
	if portLine >= 0 && curPort > 0 {
		bind, known := curPort, false
		if meta, e := os.ReadFile(filepath.Join(frpDir, "dial.env")); e == nil {
			for _, line := range strings.Split(string(meta), "\n") {
				if strings.HasPrefix(line, "DIAL_CONTROL=") {
					n, e := strconv.Atoi(strings.TrimPrefix(line, "DIAL_CONTROL="))
					if e == nil && n > 0 && n <= 65535 {
						bind = n
						known = true
					}
				}
			}
		}
		if !known {
			if curProto == "quic" {
				if curPort == 65534 {
					return fmt.Errorf("ambiguous QUIC control port; reapply the connection bundle first")
				}
				bind--
			}
			if curProto == "wss" {
				if curPort >= 65533 {
					return fmt.Errorf("ambiguous WSS control port; reapply the connection bundle first")
				}
				bind -= 2
			}
		}
		if bind < 1 || bind > 65535 {
			return fmt.Errorf("invalid base FRP control port")
		}
		want := bind
		if proto == "quic" {
			want = bind + 1
			if want > 65535 {
				want = bind - 1
			}
		}
		if proto == "wss" {
			want = bind + 2
			if want > 65535 {
				want = bind - 2
			}
		}
		lines[portLine] = fmt.Sprintf("serverPort = %d", want)
	}
	found := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "transport.protocol") {
			lines[i] = fmt.Sprintf("transport.protocol = %q", proto)
			found = true
			break
		}
	}
	if !found {
		var newLines []string
		inserted := false
		for _, l := range lines {
			if strings.HasPrefix(strings.TrimSpace(l), "[[proxies]]") && !inserted {
				newLines = append(newLines, fmt.Sprintf("transport.protocol = %q", proto), "")
				inserted = true
			}
			newLines = append(newLines, l)
		}
		if !inserted {
			newLines = append(newLines, fmt.Sprintf("transport.protocol = %q", proto))
		}
		lines = newLines
	}
	if err := writeTokenFile(frpcPath, []byte(strings.Join(lines, "\n"))); err != nil {
		return err
	}
	if _, err := exec.LookPath("systemctl"); err == nil {
		if out, e := exec.Command("systemctl", "restart", "frpc").CombinedOutput(); e != nil {
			_ = writeTokenFile(frpcPath, data)
			_ = exec.Command("systemctl", "restart", "frpc").Run()
			return fmt.Errorf("restart frpc failed; previous config restored: %w: %s", e, out)
		}
	}
	return nil
}

func wssConfigForCarrier(t string) wssConfig {
	c := loadWSSConfig()
	c.Enabled = true
	if ps, ok := strings.CutPrefix(strings.TrimSpace(t), "wss:"); ok {
		if p, err := strconv.Atoi(ps); err == nil && p >= 1 && p <= 65535 {
			c.ListenPort = p
			if host, _, err := net.SplitHostPort(c.RemoteAddr); err == nil && host != "" {
				c.RemoteAddr = net.JoinHostPort(host, ps)
			}
		}
	}
	return c
}

func ensureFrpsUDPListeners() error {
	files, _ := filepath.Glob(filepath.Join(frpDir, "frps*.toml"))
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		content := string(data)
		if strings.Contains(content, "kcpBindPort") && strings.Contains(content, "quicBindPort") {
			continue
		}
		bind := 0
		lines := strings.Split(content, "\n")
		at := -1
		for i, l := range lines {
			if k, v, ok := strings.Cut(strings.TrimSpace(l), "="); ok && strings.TrimSpace(k) == "bindPort" {
				bind, _ = strconv.Atoi(strings.TrimSpace(v))
				at = i
				break
			}
		}
		if bind <= 0 || at < 0 {
			continue
		}
		quic := bind + 1
		if quic > 65535 {
			quic = bind - 1
		}
		var add []string
		if !strings.Contains(content, "kcpBindPort") {
			add = append(add, fmt.Sprintf("kcpBindPort = %d", bind))
		}
		if !strings.Contains(content, "quicBindPort") {
			add = append(add, fmt.Sprintf("quicBindPort = %d", quic))
		}
		lines = append(lines[:at+1], append(add, lines[at+1:]...)...)
		if err := writeTokenFile(f, []byte(strings.Join(lines, "\n"))); err != nil {
			return fmt.Errorf("update %s: %w", filepath.Base(f), err)
		}
		svc := strings.TrimSuffix(filepath.Base(f), ".toml")
		if err := runSystemctl("restart", svc); err != nil {
			return fmt.Errorf("restart %s: %w", svc, err)
		}
	}
	return nil
}

func carrierApplicable(t string) error {
	t = strings.TrimSpace(t)
	switch {
	case t == "direct", strings.HasPrefix(t, "fou:"), t == "wss", strings.HasPrefix(t, "wss:"):
		return nil
	case strings.HasPrefix(t, "frp:"):
		switch strings.TrimPrefix(t, "frp:") {
		case "tcp", "kcp", "quic", "ws", "websocket", "wss":
			return nil
		}
		return fmt.Errorf("unknown FRP transport in %q", t)
	case strings.HasPrefix(t, "backhaul:"), strings.HasPrefix(t, "navalink:"):
		return fmt.Errorf("%s is a tunnel engine, not a carrier: use Switch Engine (Backhaul) or the NavaLink page", t)
	}
	return fmt.Errorf("unknown carrier %q", t)
}

func applyCarrierMode(t string) (string, error) {
	previous := loadCarrierConfig()
	t = strings.TrimSpace(t)
	if e := carrierApplicable(t); e != nil {
		return "", e
	}
	if t != "direct" && !strings.HasPrefix(t, "fou:") && !strings.HasPrefix(t, "wss") && !strings.HasPrefix(t, "frp:") {
		return "", fmt.Errorf("unsupported carrier")
	}
	var out string
	if strings.HasPrefix(t, "frp:") {
		proto := strings.TrimPrefix(t, "frp:")
		if proto == "ws" {
			proto = "websocket"
		}
		switch proto {
		case "tcp", "websocket", "wss", "kcp", "quic":
		default:
			return "", fmt.Errorf("invalid FRP transport")
		}
		if proto == "kcp" || proto == "quic" {
			if e := ensureFrpsUDPListeners(); e != nil {
				return "", e
			}
		}
		if proto == "wss" {
			// frps does not terminate TLS WebSockets itself: prepare its TLS front.
			paths, _ := filepath.Glob(filepath.Join(frpDir, "frps*.toml"))
			if len(paths) > 0 {
				script, e := greScriptPath()
				if e != nil {
					return "", e
				}
				if b, e := runCmdTimeoutOut(120*time.Second, "bash", script, "frp-wss-front"); e != nil {
					return "", fmt.Errorf("prepare WSS front: %w: %s", e, b)
				}
			}
		}
		if e := updateFrpcTransport(proto); e != nil && !os.IsNotExist(e) {
			return "", fmt.Errorf("update frpc transport: %w", e)
		}
		if !fileExists(filepath.Join(frpDir, "frpc.toml")) && !fileExists(filepath.Join(frpDir, "frps.toml")) {
			return "", fmt.Errorf("FRP is not configured")
		}
		out = "FRP transport prepared: " + proto + "; apply the matching selection on the other endpoint"
	} else {
		if strings.HasPrefix(t, "wss") {
			oldWSS := loadWSSConfig()
			next := wssConfigForCarrier(t)
			if next.AuthToken == "" || (next.ListenPort < 1 || next.ListenPort > 65535) {
				return "", fmt.Errorf("configure the WSS carrier token and port first")
			}
			if e := saveWSSConfig(next); e != nil {
				return "", e
			}
			if e := startWSSCarrier(next); e != nil {
				_ = saveWSSConfig(oldWSS)
				if oldWSS.Enabled {
					_ = startWSSCarrier(oldWSS)
				}
				return "", e
			}
		}
		b, e := runNavaTunnelCarrierCmd("set", t)
		if e != nil {
			return "", fmt.Errorf("apply carrier: %w: %s", e, b)
		}
		out = string(b)
		if !strings.HasPrefix(t, "wss") {
			if e := stopWSSCarrier(); e != nil {
				return "", e
			}
		}
	}
	// Never mark failed system changes as successfully applied.
	previous.ActiveCarrier = t
	previous.LastSwitch = time.Now().Format("2006-01-02 15:04:05")
	previous.SwitchCount++
	if e := saveCarrierConfig(previous); e != nil {
		return "", fmt.Errorf("carrier applied but state persistence failed: %w", e)
	}
	return out, nil
}
