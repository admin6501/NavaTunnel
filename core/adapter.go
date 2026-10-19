package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type coreConfig struct {
	TLSPort      int    `json:"tls_port"`
	Port         int    `json:"port"`
	BasePath     string `json:"base_path"`
	RevPathAuto  bool   `json:"revpath_auto"`
	MetricsToken string `json:"metrics_token"`
	Username     string `json:"username"`
}

var cfg = coreConfig{Port: 47777, Username: "root"}
var mu sync.Mutex

func effectiveTLSPort() int               { return cfg.TLSPort }
func cfgPath() string                     { return filepath.Join(configDir, "core.json") }
func saveConfigAtomic(c coreConfig) error { return saveJSONPrivate(cfgPath(), c) }
func saveJSONPrivate(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".nava-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if e = f.Chmod(0600); e != nil {
		return e
	}
	if _, e = f.Write(append(b, '\n')); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(f.Name(), path)
}
func greScriptPath() (string, error) {
	for _, p := range []string{"/usr/local/bin/NavaTunnel.sh", "/usr/local/bin/NavaTunnel"} {
		if fileExists(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("NavaTunnel script is not installed")
}
func writeAPIError(w http.ResponseWriter, r *http.Request, code, detail string) {
	info, ok := errCatalog[code]
	if !ok {
		info = errInfo{Status: http.StatusBadRequest, Msg: "request failed", Hint: ""}
		code = "E-SYS-01"
	}
	msg := info.Msg
	if detail != "" {
		msg = detail
	}
	ep := ""
	if r != nil {
		ep = r.Method + " " + r.URL.Path
	}
	recordError(code, ep, msg)
	w.Header().Set("Content-Type", "application/json")
	if info.Status < 400 {
		info.Status = http.StatusBadRequest
	}
	w.WriteHeader(info.Status)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error_code": code, "error": msg, "hint": info.Hint,
	})
}

func recordError(code, endpoint, detail string) {
	ev := errEvent{
		Time:     time.Now().Format("2006-01-02 15:04:05"),
		Code:     code,
		Endpoint: endpoint,
		Detail:   redactLogSecrets(detail),
	}
	errMu.Lock()
	errEvents = append(errEvents, ev)
	if len(errEvents) > 200 {
		errEvents = errEvents[len(errEvents)-200:]
	}
	errMu.Unlock()
	errorDiskMu.Lock()
	defer errorDiskMu.Unlock()
	_ = os.MkdirAll(configDir, 0700)
	rotateAuditLocked(errorLogPath())
	line, _ := json.Marshal(ev)
	f, err := os.OpenFile(errorLogPath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err == nil {
		_, _ = f.Write(append(line, '\n'))
		_ = f.Close()
	}
}

func LogSecurityAudit(event, user, ip, details string) {
	auditMu.Lock()
	defer auditMu.Unlock()

	_ = os.MkdirAll(configDir, 0700)
	details = redactLogSecrets(details)
	ts := time.Now().UTC().Format(time.RFC3339)
	entry := fmt.Sprintf("[%s] EVENT=%s user=%q ip=%s %s\n", ts, event, user, ip, details)

	log.Printf("[AUDIT] %s", strings.TrimSpace(entry))

	auditPath := auditLogPath()
	rotateAuditLocked(auditPath)
	f, err := os.OpenFile(auditPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err == nil {
		_, _ = f.WriteString(entry)
		_ = f.Close()
	}
}

var auditMu sync.Mutex
var errorDiskMu sync.Mutex

type localCLIKey struct{}

func authed(r *http.Request) bool     { return r.Context().Value(localCLIKey{}) == true }
func clientIP(r *http.Request) string { return ClientIP(r) }
func nativeTunnelStatus() (string, float64, float64) {
	s := currentSnapshot()
	configured := false
	if s.LocalSession {
		return "UP", 0, s.LocalRTT
	}
	for _, p := range s.All() {
		configured = true
		if p.Linked {
			return "UP", 0, p.LatencyMs
		}
	}
	// NavaLink keeps its registry separate from legacy GRE peers.
	paths, _ := filepath.Glob(filepath.Join(configDir, "navalink", "*", "config.json"))
	out, _ := runCmdTimeoutOut(3*time.Second, "ss", "-Htn", "state", "established")
	sessions := parseSS(string(out))
	for _, p := range paths {
		var n struct {
			ID      string `json:"id"`
			Role    string `json:"role"`
			Control int    `json:"control_port"`
			Mode    string `json:"mode"`
			Ports   []int  `json:"ports"`
			Remote  string `json:"remote_host"`
			SSHPort int    `json:"ssh_port"`
			Stopped bool   `json:"stopped"`
		}
		b, e := os.ReadFile(p)
		if e != nil || json.Unmarshal(b, &n) != nil || n.Stopped {
			continue
		}
		configured = true
		if n.Mode == "direct" {
			if n.Role == "iran" && len(n.Ports) > 0 {
				output, e := runCmdTimeoutOut(3*time.Second, "systemctl", "is-active", "--quiet", "navalink-"+n.ID+"-ssh.service")
				_ = output
				if e == nil {
					return "UP", 0, 0
				}
			} else {
				for _, session := range sessions {
					if session.RHost == n.Remote && (n.SSHPort == 0 && session.LPort == 22 || session.LPort == n.SSHPort) {
						return "UP", 0, session.RTTms
					}
				}
			}
			continue
		}
		for _, session := range sessions {
			if (session.LPort == n.Control || session.RPort == n.Control) && net.ParseIP(session.RHost).IsLoopback() {
				return "UP", 0, session.RTTms
			}
		}
	}
	if configured || fileExists(filepath.Join(frpDir, "frpc.toml")) {
		return "DOWN", 100, 0
	}
	return "UNKNOWN", 0, 0
}
func getLocalTunnelStatus() (string, float64, float64) {
	c := loadClusterConfig()
	if c.Enabled && len(c.ForeignNodes) > 0 {
		selection := foreignSelection(c)
		fresh := false
		for _, n := range c.ForeignNodes {
			if !n.LastProbe.IsZero() && time.Since(n.LastProbe) < 15*time.Second {
				fresh = true
			}
		}
		for _, n := range selection.ForeignNodes {
			if n.IsHealthy && !n.LastProbe.IsZero() && time.Since(n.LastProbe) < 15*time.Second {
				return "UP", 0, n.LatencyMs
			}
		}
		if fresh {
			return "DOWN", 100, 0
		}
		return "UNKNOWN", 0, 0
	}
	return nativeTunnelStatus()
}
func cliContext() context.Context {
	return context.WithValue(context.Background(), localCLIKey{}, true)
}

func decorateNativeStatus(st tunnelStatus) tunnelStatus {
	if st.Role != "" && st.Role != "unknown" {
		return st
	}
	paths, _ := filepath.Glob(filepath.Join(configDir, "navalink", "*", "config.json"))
	for _, path := range paths {
		var n struct {
			ID      string `json:"id"`
			Role    string `json:"role"`
			Remote  string `json:"remote_host"`
			Local   string `json:"local_pub"`
			Mode    string `json:"mode"`
			Control int    `json:"control_port"`
			Stopped bool   `json:"stopped"`
			Ports   []int  `json:"ports"`
		}
		data, e := os.ReadFile(path)
		if e != nil || json.Unmarshal(data, &n) != nil || n.Stopped {
			continue
		}
		st.Engine = "navalink"
		st.TunnelEngine = "navalink"
		st.TunnelType = "navalink"
		st.Role = n.Role + " (navalink)"
		st.RemotePub = n.Remote
		st.LocalPub = n.Local
		st.Ports = n.Ports
		st.BindPort = n.Control
		if n.Role == "iran" {
			if n.Mode == "direct" {
				st.FrpSvc = "navalink-" + n.ID + "-ssh"
			} else {
				st.FrpSvc = "navalink-" + n.ID + "-server"
			}
		} else if n.Mode != "direct" {
			st.FrpSvc = "navalink-" + n.ID + "-client"
		}
		if st.FrpSvc != "" {
			_, e = runCmdTimeoutOut(3*time.Second, "systemctl", "is-active", "--quiet", st.FrpSvc)
			st.FrpUp = e == nil
		}
		return st
	}
	return st
}
