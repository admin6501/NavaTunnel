package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var localCommand = func(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).Output()
}

type healthTarget struct {
	host  string
	port  int
	local bool
}
type healthSession struct {
	localHost, remoteHost string
	localPort, remotePort int
}

func socketAddress(s string) (string, int) {
	host, p, e := net.SplitHostPort(s)
	if e != nil {
		return "", 0
	}
	n, _ := strconv.Atoi(p)
	if ip := net.ParseIP(host); ip != nil {
		host = ip.String()
	}
	return host, n
}
func healthSessions(out []byte) []healthSession {
	var result []healthSession
	for _, row := range strings.Split(string(out), "\n") {
		f := strings.Fields(row)
		if len(f) < 4 {
			continue
		}
		lh, lp := socketAddress(f[len(f)-2])
		rh, rp := socketAddress(f[len(f)-1])
		if lp > 0 && rp > 0 {
			result = append(result, healthSession{lh, rh, lp, rp})
		}
	}
	return result
}

var healthTOMLKey = regexp.MustCompile(`^\s*(bindPort|serverPort|serverAddr)\s*=\s*(.*?)\s*(?:#.*)?$`)

func healthConfig(data []byte, server bool) healthTarget {
	t := healthTarget{local: server}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "[") {
			break
		}
		m := healthTOMLKey.FindStringSubmatch(line)
		if len(m) != 3 {
			continue
		}
		v := strings.Trim(strings.TrimSpace(m[2]), `"'`)
		if server && m[1] == "bindPort" || !server && m[1] == "serverPort" {
			t.port, _ = strconv.Atoi(v)
		}
		if !server && m[1] == "serverAddr" {
			t.host = v
		}
	}
	return t
}
func targetConnected(t healthTarget, s []healthSession) bool {
	for _, c := range s {
		if t.local && c.localPort == t.port {
			return true
		}
		if !t.local && c.remotePort == t.port && (t.host == "" || t.host == c.remoteHost) {
			return true
		}
	}
	return false
}

// Cluster needs a coarse local UP/DOWN signal, not the removed history/doctor collectors.
// Only established FRP control sessions and the retained NavaLink units are considered.
func nativeTunnelStatus() (string, float64, float64) {
	var targets []healthTarget
	configured := false
	files, _ := filepath.Glob(filepath.Join(frpDir, "frps*.toml"))
	for _, p := range files {
		if strings.HasPrefix(filepath.Base(p), "frps-wss") {
			continue
		}
		if data, e := os.ReadFile(p); e == nil {
			configured = true
			t := healthConfig(data, true)
			if t.port > 0 {
				targets = append(targets, t)
			}
		}
	}
	if data, e := os.ReadFile(filepath.Join(frpDir, "frpc.toml")); e == nil {
		configured = true
		t := healthConfig(data, false)
		if t.port > 0 {
			targets = append(targets, t)
		}
	}
	paths, _ := filepath.Glob(filepath.Join(configDir, "navalink", "*", "config.json"))
	type directLink struct {
		ID, Role, Remote string
		SSHPort          int
		Ports            []int
	}
	var direct []directLink
	for _, p := range paths {
		var n struct {
			ID      string `json:"id"`
			Role    string `json:"role"`
			Remote  string `json:"remote_host"`
			Mode    string `json:"mode"`
			Control int    `json:"control_port"`
			SSHPort int    `json:"ssh_port"`
			Ports   []int  `json:"ports"`
			Stopped bool   `json:"stopped"`
		}
		data, e := os.ReadFile(p)
		if e != nil || json.Unmarshal(data, &n) != nil || n.Stopped {
			continue
		}
		configured = true
		if n.Mode == "direct" {
			direct = append(direct, directLink{n.ID, n.Role, n.Remote, n.SSHPort, n.Ports})
			continue
		}
		targets = append(targets, healthTarget{"127.0.0.1", n.Control, n.Role == "iran"})
	}
	if !configured {
		return "UNKNOWN", 0, 0
	}
	out, e := localCommand("ss", "-Htn", "state", "established")
	if e != nil {
		return "UNKNOWN", 0, 0
	}
	sessions := healthSessions(out)
	for _, t := range targets {
		if targetConnected(t, sessions) {
			return "UP", 0, 0
		}
	}
	for _, n := range direct {
		if n.Role == "iran" && identifierRE.MatchString(n.ID) && len(n.Ports) > 0 {
			if _, e := localCommand("systemctl", "is-active", "--quiet", "navalink-"+n.ID+"-ssh.service"); e == nil {
				return "UP", 0, 0
			}
		} else if n.Role == "foreign" {
			p := n.SSHPort
			if p == 0 {
				p = 22
			}
			for _, s := range sessions {
				if s.remoteHost == n.Remote && s.localPort == p {
					return "UP", 0, 0
				}
			}
		}
	}
	return "DOWN", 100, 0
}
