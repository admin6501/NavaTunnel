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
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

func tuneViaInstaller(action string) (string, error) {
	script, err := greScriptPath()
	if err != nil {
		return "", err
	}
	arg := map[string]string{
		"optimize": "optimize", "restore": "restore", "tune-status": "tune-status",
	}[action]
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", script, arg)
	cmd.Env = append(os.Environ(), "GRE_SKIP_PANEL=1", "TERM=dumb", "GRE_PANEL_DIR="+configDir)
	out, runErr := cmd.CombinedOutput()
	o := strings.TrimSpace(string(out))
	if o == "" {
		o = action + " done"
	}
	if runErr != nil {
		return o, fmt.Errorf("tune command failed: %w", runErr)
	}
	return o, nil
}

type peerRecord struct {
	ID             int      `json:"id"`
	Name           string   `json:"name"`
	LocalPub       string   `json:"local_pub"`
	RemotePub      string   `json:"remote_pub"`
	FrpPort        int      `json:"frp_port"`
	LocalGre       string   `json:"local_gre"`
	PeerGre        string   `json:"peer_gre"`
	Ports          []int    `json:"ports"`
	RawPorts       []string `json:"raw_ports,omitempty"`
	Token          string   `json:"token,omitempty"`
	GreIf          string   `json:"gre_if"`
	FrpsSvc        string   `json:"frps_svc"`
	Carrier        string   `json:"carrier,omitempty"`
	Engine         string   `json:"engine,omitempty"`
	Transport      string   `json:"transport,omitempty"`
	NoGre          bool     `json:"no_gre,omitempty"`
	Legacy         bool     `json:"legacy,omitempty"`
	ProxyProtocol  string   `json:"proxy_protocol,omitempty"`
	FRPTransport   string   `json:"frp_transport,omitempty"`
	UseEncryption  bool     `json:"use_encryption,omitempty"`
	UseCompression bool     `json:"use_compression,omitempty"`
}

type peerLive struct {
	peerRecord
	GreUp    bool   `json:"gre_up"`
	GreInner string `json:"gre_inner"`
	FrpUp    bool   `json:"frp_up"`
	Linked   bool   `json:"linked"`
	FrpOnly  bool   `json:"frp_only"`
	PingOK   bool   `json:"ping_ok"`
	PingMs   string `json:"ping_ms"`

	LatencyMs   float64 `json:"latency_ms"`
	LatencyKind string  `json:"latency_kind"`
	Rx          *uint64 `json:"rx"`
	Tx          *uint64 `json:"tx"`

	HealthState   string   `json:"health_state"`
	ICMPFiltered  bool     `json:"icmp_filtered"`
	ICMPOK        bool     `json:"icmp_ok"`
	ICMPMs        float64  `json:"icmp_ms"`
	Reasons       []string `json:"reasons"`
	SnapshotAgeMs int64    `json:"snapshot_age_ms"`
	ICMPKnown     bool     `json:"-"`
	icmpTarget    string
}

func peersFile() string { return configDir + "/peers.json" }

func loadPeers() []peerRecord {
	data, err := os.ReadFile(peersFile())
	if err != nil {
		return nil
	}
	var v struct {
		Peers []peerRecord `json:"peers"`
	}
	if json.Unmarshal(data, &v) != nil {
		return nil
	}
	return v.Peers
}

func findPeer(id int) *peerRecord {
	for _, p := range loadPeers() {
		if p.ID == id {
			c := p
			return &c
		}
	}
	return nil
}

func livePeersFrom(v *hostView, recs []peerRecord) []peerLive {
	if len(recs) == 0 {
		return nil
	}
	out := make([]peerLive, 0, len(recs))
	for _, p := range recs {
		l := peerLive{peerRecord: p}
		if p.NoGre {
			l.GreInner = "standalone"
			l.GreUp = true
		} else if v.tunnelOK {

			l.GreInner = v.inner[p.GreIf]
			l.GreUp = l.GreInner != ""
		}
		l.FrpUp = v.active[p.FrpsSvc]
		sig := LinkSignals{ServiceActive: l.FrpUp, GreIfUp: l.GreUp}
		q := ctrlQuery{ID: p.ID, Port: p.FrpPort, RemotePub: p.RemotePub, PeerGre: p.PeerGre}
		if l.FrpUp {
			r := controlSessionIn(v.sessions, q, v.owners)
			l.Linked, sig.Session, sig.TCPRTTms = r.Linked, r.Linked, r.RTTms
			if !r.Linked && v.connect != nil {
				if c := v.connect(p.ID); c.OK {
					sig.ConnectRTTms = c.RTTms
				}
			}
		}
		l.icmpTarget = p.PeerGre
		if l.icmpTarget == "" && p.NoGre {
			l.icmpTarget = p.RemotePub
		}
		ic := v.icmpFor(l.icmpTarget)
		if !p.NoGre {
			l.Rx, l.Tx = v.traffic(p.GreIf)
			sig.TrafficFlowing = v.flowing[p.GreIf]
		}
		sig.Rx, sig.Tx = l.Rx, l.Tx
		l.applyHealth(sig, ic)
		out = append(out, l)
	}
	return out
}

func (l *peerLive) applyHealth(sig LinkSignals, ic icmpResult) {
	sig.ICMPOK, sig.ICMPms, sig.ICMPFresh = ic.OK, ic.Ms, ic.Known
	l.PingOK, l.ICMPOK, l.ICMPKnown, l.ICMPMs = ic.OK, ic.OK, ic.Known, -1
	if ic.OK {
		l.PingMs = fmt.Sprintf("%.0fms", ic.Ms)
		l.ICMPMs = ic.Ms
	}
	h := ComputeHealth(sig)
	l.HealthState, l.ICMPFiltered, l.Reasons = h.State, h.ICMPFiltered, h.Reasons
	l.LatencyMs, l.LatencyKind = h.LatencyMs, h.LatencyKind
	l.FrpOnly = l.Linked && !l.PingOK
}

type greState struct {
	Exists bool   `json:"exists"`
	Name   string `json:"name"`
	Local  string `json:"local"`
	PeerIP string `json:"peer_ip"`
	Inner  string `json:"inner"`
}

type tunnelStatus struct {
	Role         string   `json:"role"`
	Engine       string   `json:"engine,omitempty"`
	TunnelEngine string   `json:"tunnel_engine,omitempty"`
	TunnelType   string   `json:"tunnel_type,omitempty"`
	Transport    string   `json:"transport,omitempty"`
	Gre          greState `json:"gre"`
	GrePeer      string   `json:"gre_peer"`
	LocalPub     string   `json:"local_pub,omitempty"`
	RemotePub    string   `json:"remote_pub,omitempty"`
	PingOK       bool     `json:"ping_ok"`
	PingMs       string   `json:"ping_ms"`
	FrpUp        bool     `json:"frp_up"`
	FrpSvc       string   `json:"frp_svc"`
	FrpPort      int      `json:"frp_port"`
	Proxies      []string `json:"proxies"`
	ProxyPorts   []int    `json:"proxy_ports"`
	Ports        []int    `json:"ports,omitempty"`
	BindPort     int      `json:"bind_port"`

	TuneBackup bool `json:"tune_backup"`
}

var (
	engineBinDirs     = []string{"/usr/local/bin"}
	backhaulExtraBins = []string{"/root/backhaul-core/backhaul_premium"}
)

func executableFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}

func engineBinaryPresent(engine string) bool {
	for _, d := range engineBinDirs {
		if executableFile(filepath.Join(d, engine)) {
			return true
		}
	}
	if engine == "backhaul" {
		for _, p := range backhaulExtraBins {
			if executableFile(p) {
				return true
			}
		}
	}
	return false
}

type staleConfigCandidate struct {
	path, engine, role, svc string
}

func staleConfigCandidates() []staleConfigCandidate {
	return []staleConfigCandidate{
		{filepath.Join(frpDir, "frps.toml"), "frps", "iran (server)", "frps"},
		{filepath.Join(frpDir, "frpc.toml"), "frpc", "foreign (client)", "frpc"},
		{filepath.Join(backhaulDir, "config.toml"), "backhaul", "iran (backhaul)", "backhaul-server"},
		{filepath.Join(backhaulDir, "server.toml"), "backhaul", "iran (backhaul)", "backhaul-server"},
		{filepath.Join(configDir, "server.toml"), "backhaul", "iran (backhaul)", "backhaul-server"},
		{filepath.Join(backhaulDir, "client.toml"), "backhaul", "foreign (backhaul)", "backhaul-client"},
		{filepath.Join(configDir, "client.toml"), "backhaul", "foreign (backhaul)", "backhaul-client"},
	}
}

func localStatus() tunnelStatus {
	return localStatusFrom(directView(nil))
}

func localStatusFrom(v *hostView) tunnelStatus {
	var st tunnelStatus
	st.TuneBackup = fileExists(filepath.Join(configDir, "tune.bak"))

	if v.tunnelOK {
		for _, line := range strings.Split(v.tunnelShow, "\n") {
			if strings.Contains(line, "gre-tunnel") {
				st.Gre.Exists = true
				st.Gre.Name = "gre-tunnel"
				parts := strings.Fields(line)
				for i, p := range parts {
					if p == "local" && i+1 < len(parts) {
						st.Gre.Local = parts[i+1]
					}
					if p == "remote" && i+1 < len(parts) {
						st.Gre.PeerIP = parts[i+1]
						st.GrePeer = parts[i+1]
					}
				}
			}
		}
	}
	if inner := v.inner["gre-tunnel"]; inner != "" {
		st.Gre.Inner = inner
		st.Gre.Exists = true
		if st.Gre.Name == "" {
			st.Gre.Name = "gre-tunnel"
		}
	}

	for _, svc := range baseUnits {
		if v.active[svc] {
			st.FrpUp = true
			st.FrpSvc = svc
			switch svc {
			case "frps":
				st.Role = "iran (server)"
			case "frpc":
				st.Role = "foreign (client)"
			case "backhaul-server":
				st.Role = "iran (backhaul)"
			case "backhaul-client":
				st.Role = "foreign (backhaul)"
			}
			break
		}
	}
	if st.Role == "" {

		var per []string
		for u, on := range v.active {
			if on && strings.HasPrefix(u, "backhaul-server-") {
				per = append(per, u)
			}
		}
		if len(per) > 0 {
			sort.Strings(per)
			st.FrpUp = true
			st.FrpSvc = per[0]
			st.Role = "iran (backhaul)"
		}
	}
	if st.Role == "" {

		for _, c := range staleConfigCandidates() {
			if fileExists(c.path) && engineBinaryPresent(c.engine) {
				st.Role = c.role
				st.FrpSvc = c.svc
				break
			}
		}
	}

	if strings.HasPrefix(st.FrpSvc, "backhaul") {
		if st.Gre.Exists {
			st.Engine = "gre-backhaul"
		} else {
			st.Engine = "backhaul"
		}
		st.TunnelEngine = st.Engine
		st.TunnelType = st.Engine
		bhPath := filepath.Join(backhaulDir, "config.toml")
		if _, err := os.Stat(bhPath); err != nil {
			if _, err := os.Stat(filepath.Join(backhaulDir, "server.toml")); err == nil {
				bhPath = filepath.Join(backhaulDir, "server.toml")
			} else if _, err := os.Stat(filepath.Join(configDir, "server.toml")); err == nil {
				bhPath = filepath.Join(configDir, "server.toml")
			}
		}
		if st.FrpSvc == "backhaul-client" {
			if _, err := os.Stat(filepath.Join(backhaulDir, "client.toml")); err == nil {
				bhPath = filepath.Join(backhaulDir, "client.toml")
			} else if _, err := os.Stat(filepath.Join(configDir, "client.toml")); err == nil {
				bhPath = filepath.Join(configDir, "client.toml")
			}
		}
		if data, err := os.ReadFile(bhPath); err == nil {
			bc := parseBackhaulConf(string(data))
			if bc.Transport != "" {
				st.Transport = bc.Transport
			}
			if bc.RemoteAddr != "" {
				if host, portStr, err := net.SplitHostPort(bc.RemoteAddr); err == nil {
					st.RemotePub = host
					st.Gre.PeerIP = host
					if v, err := strconv.Atoi(portStr); err == nil {
						st.BindPort = v
						st.FrpPort = v
					}
				}
			}
			if bc.BindAddr != "" {
				if _, portStr, err := net.SplitHostPort(bc.BindAddr); err == nil {
					if v, err := strconv.Atoi(portStr); err == nil {
						st.BindPort = v
						st.FrpPort = v
					}
				}
			}
			for _, pStr := range bc.Ports {
				st.Proxies = append(st.Proxies, pStr)
				basePart := strings.Split(strings.Split(pStr, "-")[0], "=")[0]
				if v, err := strconv.Atoi(basePart); err == nil {
					st.ProxyPorts = append(st.ProxyPorts, v)
				}
			}
		}
	} else {
		if st.FrpSvc != "" {
			st.Engine = "frp"
		}
		tomlPath := filepath.Join(frpDir, "frps.toml")
		if st.FrpSvc == "frpc" {
			tomlPath = filepath.Join(frpDir, "frpc.toml")
		}
		if data, err := os.ReadFile(tomlPath); err == nil {
			inProxy := false
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "serverAddr = ") {
					addr := strings.Trim(strings.TrimPrefix(line, "serverAddr = "), `"' `)
					st.RemotePub = addr
					if st.Gre.PeerIP == "" {
						st.Gre.PeerIP = addr
					}
				}
				if strings.HasPrefix(line, "bindPort") || strings.HasPrefix(line, "serverPort") {

					if parts := strings.SplitN(line, "=", 2); len(parts) == 2 {
						if v, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil && v > 0 {
							st.BindPort = v
							st.FrpPort = v
						}
					}
					continue
				}

				if strings.HasPrefix(line, "[[proxies]]") {

					inProxy = true
					continue
				}
				if strings.HasPrefix(line, "[") {
					inProxy = false
					continue
				}
				if strings.HasPrefix(line, "name = ") {
					name := strings.Trim(strings.TrimPrefix(line, "name = "), `"`)
					if inProxy {
						st.Proxies = append(st.Proxies, name)
					}
					continue
				}

				if inProxy && (strings.HasPrefix(line, "remotePort") || strings.HasPrefix(line, "localPort")) {
					if parts := strings.SplitN(line, "=", 2); len(parts) == 2 {
						if v, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil && v > 0 {
							st.ProxyPorts = append(st.ProxyPorts, v)
						}
					}
				}
			}
		}
	}

	st.ProxyPorts = uniqInts(st.ProxyPorts)

	if st.Gre.Inner != "" {
		if target := grePeerInner(st.Gre.Inner); target != "" {
			ic := v.icmpFor(target)
			st.PingOK = ic.OK
			if ic.OK {
				st.PingMs = fmt.Sprintf("%.0fms", ic.Ms)
			}
		}
	}
	st.TunnelEngine = st.Engine
	st.TunnelType = st.Engine
	st.LocalPub = st.Gre.Local
	if st.RemotePub == "" {
		st.RemotePub = st.Gre.PeerIP
	}
	st.Ports = st.ProxyPorts
	return decorateNativeStatus(st)
}

func uniqInts(in []int) []int {
	seen := map[int]bool{}
	out := []int{}
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

func grePeerInner(cidr string) string {
	ip := strings.Split(cidr, "/")[0]
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return ""
	}
	last := 0
	fmt.Sscanf(parts[3], "%d", &last)
	if last%2 == 0 {
		last--
	} else {
		last++
	}
	return fmt.Sprintf("%s.%s.%s.%d", parts[0], parts[1], parts[2], last)
}

var engineUnitDir = "/etc/systemd/system"

var engineSwitchServices = []string{"gre-tunnel", "frps", "frpc", "backhaul-server", "backhaul-client"}

var (
	engineServiceActive = func(svc string) bool {
		out, err := runCmdTimeoutOut(5*time.Second, "systemctl", "is-active", svc+".service")
		return err == nil && strings.TrimSpace(string(out)) == "active"
	}

	engineVerifyDelay = 3 * time.Second
)

type engineSwitchTx struct {
	wasActive map[string]bool
	files     map[string][]byte
}

func (tx *engineSwitchTx) start(svc string) error {
	if err := runSystemctl("restart", svc); err != nil {
		return fmt.Errorf("systemctl restart %s failed: %w", svc, err)
	}
	_ = runSystemctl("enable", svc)
	if engineVerifyDelay > 0 {
		time.Sleep(engineVerifyDelay)
	}
	if !engineServiceActive(svc) {
		return fmt.Errorf("%s exited right after restart (check its config with journalctl -u %s)", svc, svc)
	}
	return nil
}

func (tx *engineSwitchTx) rollback(cause error) error {
	for _, s := range engineSwitchServices[1:] {
		_ = runSystemctl("stop", s)
	}
	for p, b := range tx.files {
		if b == nil {
			_ = os.Remove(p)
		} else {
			_ = writeTokenFile(p, b)
		}
	}
	restored := []string{}
	for _, s := range engineSwitchServices {
		if tx.wasActive[s] {
			_ = runSystemctl("restart", s)
			restored = append(restored, s)
		}
	}
	if len(restored) == 0 {
		return fmt.Errorf("%w; previous configs restored", cause)
	}
	return fmt.Errorf("%w; previous engine restored (%s)", cause, strings.Join(restored, ", "))
}

func writeTokenFile(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0600); err != nil {
		return err
	}
	return os.Chmod(path, 0600)
}

func ensureFRPServiceUnits(svcName string) {
	if runtime.GOOS == "windows" {
		return
	}
	unitPath := "/etc/systemd/system/" + svcName + ".service"
	data, err := os.ReadFile(unitPath)
	if err != nil {
		return
	}
	content := string(data)
	changed := false
	if !strings.Contains(content, "LimitNOFILE") {
		content = strings.Replace(content, "[Service]", "[Service]\nLimitNOFILE=1048576\nLimitNPROC=512000\nTasksMax=infinity\nStartLimitIntervalSec=0", 1)
		changed = true
	}
	if !strings.Contains(content, "CPUWeight=") {
		content = strings.Replace(content, "[Service]", "[Service]\nCPUWeight=100", 1)
		changed = true
	}
	if strings.Contains(content, "Restart=on-failure") {
		content = strings.Replace(content, "Restart=on-failure", "Restart=always", 1)
		changed = true
	}
	if strings.Contains(content, "StartLimitIntervalSec=60") {
		content = strings.Replace(content, "StartLimitIntervalSec=60\nStartLimitBurst=5\n", "", 1)
		changed = true
	}
	if changed {
		_ = os.WriteFile(unitPath, []byte(content), 0644)
		_ = runSystemctl("daemon-reload")
	}
}
