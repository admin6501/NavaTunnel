// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

type doctorReport struct {
	Timestamp   string `json:"timestamp"`
	DurationMs  int64  `json:"duration_ms"`
	Role        string `json:"role"`
	Engine      string `json:"engine"`
	Configured  bool   `json:"configured"`
	GREExpected bool   `json:"gre_expected"`

	PeerGREIP    string       `json:"peer_gre_ip"`
	PeerPublicIP string       `json:"peer_public_ip"`
	TunnelName   string       `json:"tunnel_name"`
	InterfaceUp  bool         `json:"interface_up"`
	FRPUp        bool         `json:"frp_up"`
	PingResult   pingSummary  `json:"ping_result"`
	Underlay     pingSummary  `json:"underlay"`
	MTUResult    mtuSummary   `json:"mtu_result"`
	KernelAudit  kernelAudit  `json:"kernel_audit"`
	SpeedResult  speedSummary `json:"speed_result"`

	Tunnels  []TunnelHealthEntry `json:"tunnels"`
	NavaLink *doctorNavaLink     `json:"navalink,omitempty"`
	Score    int                 `json:"score"`
	Rating   string              `json:"rating"`

	Findings        []doctorFinding `json:"findings"`
	Notes           []string        `json:"notes"`
	Issues          []string        `json:"issues"`
	Recommendations []string        `json:"recommendations"`
	FixAvailable    bool            `json:"fix_available"`
	LastError       *errEvent       `json:"last_error,omitempty"`

	RevPath []revPathEntry `json:"revpath,omitempty"`
}

type doctorFinding struct {
	Severity string   `json:"severity"`
	Area     string   `json:"area"`
	Title    string   `json:"title"`
	Fix      string   `json:"fix,omitempty"`
	TitleTpl string   `json:"title_tpl"`
	FixTpl   string   `json:"fix_tpl,omitempty"`
	Args     []string `json:"args,omitempty"`
	Auto     bool     `json:"auto"`
	penalty  int
}

type doctorNavaLink struct {
	Role      string  `json:"role"`
	Active    bool    `json:"active"`
	Connected bool    `json:"connected"`
	LatencyMs float64 `json:"latency_ms"`
	Status    string  `json:"status"`
	LastError string  `json:"last_error,omitempty"`
}

type pingSummary struct {
	Tested     bool    `json:"tested"`
	Target     string  `json:"target,omitempty"`
	Sent       int     `json:"sent"`
	Received   int     `json:"received"`
	PacketLoss float64 `json:"packet_loss"`
	MinRTT     float64 `json:"min_rtt"`
	AvgRTT     float64 `json:"avg_rtt"`
	MaxRTT     float64 `json:"max_rtt"`
	Jitter     float64 `json:"jitter"`
	Success    bool    `json:"success"`
}

type mtuSummary struct {
	Tested    bool `json:"tested"`
	Interface int  `json:"interface"`
	MaxPacket int  `json:"max_packet"`
	Optimal   int  `json:"optimal"`
	MSS       int  `json:"mss"`
}

type kernelAudit struct {
	BBREnabled    bool   `json:"bbr_enabled"`
	CongestionAlg string `json:"congestion_alg"`
	IPForwarding  bool   `json:"ip_forwarding"`
	MSSClamping   bool   `json:"mss_clamping"`
	MSSRule       string `json:"mss_rule"`
	LimitNOFILE   int    `json:"limit_nofile"`
	Somaxconn     int    `json:"somaxconn"`
	ConntrackMax  int    `json:"conntrack_max"`
	TCPTwReuse    bool   `json:"tcp_tw_reuse"`
}

type speedSummary struct {
	Tested         bool    `json:"tested"`
	ThroughputMbps float64 `json:"throughput_mbps"`
	Mode           string  `json:"mode"`
	ServerActive   bool    `json:"server_active"`
	Detail         string  `json:"detail"`
}

type doctorPostRequest struct {
	Action string `json:"action"`
}

var (
	lastDoctorMu     sync.RWMutex
	lastDoctorReport *doctorReport
	lastDoctorAt     time.Time
	doctorRunMu      sync.Mutex
)

func doctorRefresh() *doctorReport {
	arrived := time.Now()
	doctorRunMu.Lock()
	defer doctorRunMu.Unlock()
	lastDoctorMu.RLock()
	c, at := lastDoctorReport, lastDoctorAt
	lastDoctorMu.RUnlock()
	if c != nil && at.After(arrived) {
		return c
	}
	rep := runFullDiagnostics()
	lastDoctorMu.Lock()
	lastDoctorReport, lastDoctorAt = rep, time.Now()
	lastDoctorMu.Unlock()
	return rep
}

func handleDoctorGet(w http.ResponseWriter, r *http.Request) {
	lastDoctorMu.RLock()
	rep := lastDoctorReport
	lastDoctorMu.RUnlock()
	if rep == nil {
		rep = doctorRefresh()
	}
	writeJSON(w, rep)
}

func handleDoctorPost(w http.ResponseWriter, r *http.Request) {
	var req doctorPostRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		req.Action = "run"
	}

	switch req.Action {
	case "run", "refresh":
		writeJSON(w, doctorRefresh())
	case "fix":
		res := applyFixesFn()
		writeJSON(w, map[string]any{
			"status": "ok",
			"fix":    res,
			"report": doctorRefresh(),
		})
	case "iperf-start":
		msg, err := startIperfServer()
		if err != nil {
			writeAPIError(w, r, "E-SYS-01", err.Error())
			return
		}
		writeJSON(w, map[string]string{"status": "ok", "message": msg})
	case "iperf-stop":
		msg, err := stopIperfServer()
		if err != nil {
			writeAPIError(w, r, "E-SYS-01", err.Error())
			return
		}
		writeJSON(w, map[string]string{"status": "ok", "message": msg})
	default:
		writeAPIError(w, r, "E-ACTION-01", "unknown doctor action: "+req.Action)
	}
}

type doctorInputs struct {
	st         tunnelStatus
	gre        bool
	innerPeer  string
	publicPeer string
	ping       pingSummary
	underlay   pingSummary
	mtu        mtuSummary
	kernel     kernelAudit
	speed      speedSummary
	health     *tunnelHealthResult
	navalink   *doctorNavaLink
	extra      []doctorFinding
	lastErr    *errEvent
}

var (
	doctorPingFn     = executePing
	doctorDFProbe    = pingWithDF
	doctorHealthFn   = func() *tunnelHealthResult { return tunnelHealthRefresh(true) }
	doctorNavaLinkFn = doctorNavaLinkStatus
	doctorIfMTUFn    = interfaceMTU
)

func runFullDiagnostics() *doctorReport {
	start := time.Now()
	rep := evaluateDoctor(collectDoctorInputs())
	rep.DurationMs = time.Since(start).Milliseconds()
	return rep
}

func collectDoctorInputs() doctorInputs {
	st := localStatus()
	in := doctorInputs{st: st, gre: greExpected(st), navalink: doctorNavaLinkFn(), lastErr: lastErrorEvent()}
	if st.Gre.Inner != "" {
		in.innerPeer = grePeerInner(st.Gre.Inner)
	}
	in.publicPeer = normHost(st.Gre.PeerIP)
	if in.publicPeer == "" {
		in.publicPeer = normHost(st.RemotePub)
	}
	in.extra = doctorConfigFindings(st)
	in.kernel = executeKernelAudit()
	if !doctorConfigured(in) {
		return in
	}

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		defer func() { _ = recover() }()
		in.health = doctorHealthFn()
	}()
	go func() {
		defer wg.Done()
		if in.publicPeer != "" {
			in.underlay = doctorPingFn(in.publicPeer, 5)
		}
	}()
	go func() {
		defer wg.Done()
		if !in.gre || !st.Gre.Exists || in.innerPeer == "" {
			in.speed = speedSummary{Mode: "iperf3", ServerActive: isIperfServerRunning(),
				Detail: "Needs a GRE tunnel: iPerf3 measures the GRE link"}
			return
		}
		in.ping = doctorPingFn(in.innerPeer, 10)
		if in.ping.Success {
			in.mtu = executeMTUTest(in.innerPeer, doctorIfMTUFn(st.Gre.Name))
		}
		in.speed = executeThroughputTest(in.innerPeer, in.ping.Success)
	}()
	wg.Wait()
	return in
}

func doctorConfigured(in doctorInputs) bool {
	return in.st.Role != "" || in.st.FrpSvc != "" || in.gre || in.navalink != nil
}

func doctorConfigFindings(st tunnelStatus) []doctorFinding {
	var out []doctorFinding

	for _, c := range staleConfigCandidates() {
		if fileExists(c.path) && !engineBinaryPresent(c.engine) {
			out = append(out, newFinding("warning", "config", 10, false,
				"Stale {0} config found ({1}) but the {2} binary is not installed — role is reported as unknown",
				"Remove the stale config or reinstall the engine (Setup tab)",
				filepath.Base(c.path), c.path, c.engine))
		}
	}

	if st.FrpSvc == "frpc" && frpcLoginEOF() {
		f := newFinding("critical", "tunnel", 30, false, "frpc login fails with 'connect to server error: EOF'", "")
		f.Fix, f.FixTpl = errCatalog["E-FRP-10"].Hint, errCatalog["E-FRP-10"].Hint
		out = append(out, f)
	}

	if issue, rec := backhaulDoctorIssue(st); issue != "" {
		f := newFinding("warning", "tunnel", 10, false, "{0}", "", issue)
		f.Fix, f.FixTpl = rec, rec
		out = append(out, f)
	}
	return out
}

func doctorNavaLinkStatus() *doctorNavaLink {
	s := getSSHFwdSnapshotStatus()
	if has, _ := s["has_config"].(bool); !has {
		return nil
	}
	b := &doctorNavaLink{}
	b.Role, _ = s["role"].(string)
	b.Active, _ = s["is_active"].(bool)
	b.Connected, _ = s["connected"].(bool)
	b.LatencyMs, _ = s["latency_ms"].(float64)
	b.Status, _ = s["status_text"].(string)
	b.LastError, _ = s["last_error"].(string)
	if en, _ := s["enabled"].(bool); !en && !b.Active {
		return nil
	}
	return b
}

func fillTpl(tpl string, args []string) string {
	for i, a := range args {
		tpl = strings.ReplaceAll(tpl, "{"+strconv.Itoa(i)+"}", a)
	}
	return tpl
}

func newFinding(sev, area string, penalty int, auto bool, titleTpl, fixTpl string, args ...string) doctorFinding {
	return doctorFinding{Severity: sev, Area: area, penalty: penalty, Auto: auto,
		TitleTpl: titleTpl, FixTpl: fixTpl, Args: args,
		Title: fillTpl(titleTpl, args), Fix: fillTpl(fixTpl, args)}
}

func fmt1(v float64) string { return strconv.FormatFloat(v, 'f', 1, 64) }

func evaluateDoctor(in doctorInputs) *doctorReport {
	st := in.st
	rep := &doctorReport{
		Timestamp:    time.Now().UTC().Format(time.RFC3339),
		Role:         st.Role,
		Engine:       st.Engine,
		GREExpected:  in.gre,
		PeerGREIP:    in.innerPeer,
		PeerPublicIP: in.publicPeer,
		TunnelName:   "gre-tunnel",
		InterfaceUp:  st.Gre.Exists,
		FRPUp:        st.FrpUp,
		PingResult:   in.ping,
		Underlay:     in.underlay,
		MTUResult:    in.mtu,
		KernelAudit:  in.kernel,
		SpeedResult:  in.speed,
		Tunnels:      []TunnelHealthEntry{},
		NavaLink:     in.navalink,
		Findings:     []doctorFinding{},
		Notes:        []string{},
		LastError:    in.lastErr,
		RevPath:      revPathCached(),
	}
	if rep.Engine == "" && in.gre {
		rep.Engine = "gre"
	}
	add := func(f doctorFinding) { rep.Findings = append(rep.Findings, f) }
	for _, f := range in.extra {
		add(f)
	}

	rep.Configured = doctorConfigured(in)
	if !rep.Configured {
		rep.Notes = append(rep.Notes, "No tunnel is set up on this server yet")
		return finishDoctor(rep)
	}

	mainSvcDown := st.FrpSvc != "" && !st.FrpUp
	if in.gre && !st.Gre.Exists {
		add(newFinding("critical", "tunnel", 60, true,
			"GRE interface gre-tunnel is missing",
			"Quick Repair restarts gre-tunnel. If it stays missing, run Setup again on this server"))
	} else if !in.gre && st.FrpSvc != "" {
		rep.Notes = append(rep.Notes, "No GRE on this server: GRE ping, MTU and iPerf3 are skipped")
	}
	if mainSvcDown {
		add(newFinding("critical", "tunnel", 40, true,
			"Tunnel service {0} is not running",
			"Quick Repair restarts it. If it stops again, open Logs and filter by {0}", st.FrpSvc))
	}

	mainPass := false
	if in.health != nil {
		rep.Tunnels = in.health.Tunnels
		for _, t := range in.health.Tunnels {
			if t.ID == mainTunnelID && t.Verdict == VerdictPass {
				mainPass = true
			}
			if t.Verdict == VerdictPass || (t.ID == mainTunnelID && mainSvcDown) {
				continue
			}
			name := t.Name
			if name == "" {
				name = "tunnel-" + strconv.Itoa(t.ID)
			}
			fix := "The service runs and the session is up, but a forwarded port does not answer: check the service behind it on the destination server"
			switch {
			case t.Layers.Service == layerFail:
				fix = "Its service is stopped: restart it from the Tunnel tab"
			case t.Layers.Session == layerFail || t.Verdict == VerdictUnreachable:
				fix = "No control session with the other server: check that it is online and its tunnel port is reachable"
			}
			add(newFinding("critical", "tunnel", 35, false, "Tunnel {0} ({1}) fails: {2}", fix, name, t.Engine, t.Reason))
		}
	}

	if b := in.navalink; b != nil {
		switch {
		case !b.Active:
			add(newFinding("critical", "tunnel", 40, false, "NavaLink is enabled but its service is not running",
				"Open the NavaLink tab and press Start. Its log shows why it stopped"))
		case !b.Connected:
			fix := "Check that the foreign server is online and that its SSH port accepts this server's key"
			if b.LastError != "" {
				fix += ". Last error: {0}"
			}
			add(newFinding("critical", "tunnel", 40, false, "NavaLink is running but not connected to the other server", fix, b.LastError))
		}
	}

	if in.ping.Tested {
		p := in.ping
		switch {
		case !p.Success && mainPass:
			add(newFinding("minor", "path", 5, false,
				"The peer's tunnel address {0} does not answer ping, but the tunnel carries data",
				"ICMP is filtered somewhere on the path. Nothing to do unless traffic stalls", in.innerPeer))
		case !p.Success:
			fix := "The GRE tunnel on the other server is down, or one side has the wrong public IP. Check the Tunnel tab on the other server"
			if in.underlay.Tested && !in.underlay.Success {
				fix = "The peer's public IP {1} does not answer either: the other server may be down or the route is filtered"
			}
			add(newFinding("critical", "path", 40, false,
				"The peer's tunnel address {0} does not answer (100% loss)", fix, in.innerPeer, in.publicPeer))
		default:
			if p.PacketLoss > 15 {
				add(newFinding("warning", "path", 20, false, "High packet loss through the tunnel: {0}%",
					"Loss this high comes from the route. Try another carrier (Benchmark tab)", fmt1(p.PacketLoss)))
			} else if p.PacketLoss > 2 {
				add(newFinding("minor", "path", 8, false, "Some packet loss through the tunnel: {0}%",
					"Watch it. If it grows, try another carrier (Benchmark tab)", fmt1(p.PacketLoss)))
			}
			if p.Jitter > 25 {
				add(newFinding("minor", "path", 5, false, "High jitter: {0} ms",
					"The route is unstable. Calls and games will stutter", fmt1(p.Jitter)))
			}
			if p.AvgRTT > 250 {
				add(newFinding("minor", "path", 5, false, "High latency through the tunnel: {0} ms",
					"Expected on long routes. A closer foreign server or another carrier lowers it", fmt1(p.AvgRTT)))
			}
		}
	}
	if in.underlay.Tested && !in.underlay.Success && (in.ping.Success || mainPass) {
		rep.Notes = append(rep.Notes, "The peer's public IP does not answer ping (ICMP filtered); the tunnel itself works")
	}

	if m := in.mtu; m.Tested {
		if m.MaxPacket > 0 && m.MaxPacket < m.Interface {
			add(newFinding("warning", "mtu", 15, true,
				"Packets of {0} bytes do not cross the tunnel; the largest that does is {1}",
				"Quick Repair sets the GRE MTU to {2} and TCP MSS to {3} and keeps them after restarts. Run Diagnostics on the other server too. Until then, large downloads and TLS handshakes can stall",
				strconv.Itoa(m.Interface), strconv.Itoa(m.MaxPacket), strconv.Itoa(m.Optimal), strconv.Itoa(m.MSS)))
		} else if m.MaxPacket == 0 {
			rep.Notes = append(rep.Notes, "MTU not measured: large pings got no reply")
		}
	}

	k := in.kernel
	if !k.BBREnabled {
		add(newFinding("minor", "kernel", 5, true, "TCP BBR is off (running {0})",
			"BBR keeps throughput up on lossy routes. Quick Repair enables it", k.CongestionAlg))
	}
	if in.gre && !k.IPForwarding {
		add(newFinding("warning", "kernel", 15, true, "IP forwarding is off",
			"GRE cannot route traffic without it. Quick Repair enables it"))
	}
	if in.gre && !k.MSSClamping {
		add(newFinding("warning", "kernel", 10, true, "No TCP MSS clamp rule",
			"Without it, TLS handshakes through GRE can freeze. Quick Repair adds MSS 1340"))
	}
	if k.Somaxconn > 0 && k.Somaxconn < 8192 {
		add(newFinding("minor", "kernel", 3, true, "Listen backlog (somaxconn) is low: {0}",
			"Connections drop under load. Quick Repair raises it to 65535", strconv.Itoa(k.Somaxconn)))
	}
	if k.LimitNOFILE > 0 && k.LimitNOFILE < 65535 {
		add(newFinding("minor", "kernel", 5, true, "Engine open-files limit is low: {0}",
			"The engine runs out of sockets under heavy use. Quick Repair raises it to 1048576", strconv.Itoa(k.LimitNOFILE)))
	}

	return finishDoctor(rep)
}

func finishDoctor(rep *doctorReport) *doctorReport {
	score, critical := 100, false
	for _, f := range rep.Findings {
		score -= f.penalty
		critical = critical || f.Severity == "critical"
		rep.Issues = append(rep.Issues, f.Title)
		rep.Recommendations = append(rep.Recommendations, f.Fix)
		rep.FixAvailable = rep.FixAvailable || f.Auto
	}
	if rep.Issues == nil {
		rep.Issues, rep.Recommendations = []string{}, []string{}
	}
	if critical && score > 45 {
		score = 45
	}
	rep.Score = max(0, min(100, score))
	switch {
	case !rep.Configured:
		rep.Rating = "unset"
	case critical || rep.Score < 50:
		rep.Rating = "critical"
	case rep.Score >= 90:
		rep.Rating = "excellent"
	case rep.Score >= 75:
		rep.Rating = "good"
	default:
		rep.Rating = "warning"
	}
	return rep
}

func executePing(ip string, count int) pingSummary {
	res := pingSummary{Sent: count, Target: ip}
	if ip == "" {
		return res
	}
	res.Tested = true

	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "ping", "-n", strconv.Itoa(count), ip)
	} else {
		cmd = exec.CommandContext(ctx, "ping", "-c", strconv.Itoa(count), "-i", "0.2", "-w", "5", "-q", ip)
	}

	out, err := cmd.CombinedOutput()
	output := string(out)

	if runtime.GOOS != "windows" {

		lossRe := regexp.MustCompile(`(\d+)% packet loss`)
		if m := lossRe.FindStringSubmatch(output); len(m) > 1 {
			loss, _ := strconv.ParseFloat(m[1], 64)
			res.PacketLoss = loss
		}
		rxRe := regexp.MustCompile(`(\d+) received`)
		if m := rxRe.FindStringSubmatch(output); len(m) > 1 {
			rx, _ := strconv.Atoi(m[1])
			res.Received = rx
		}

		rttRe := regexp.MustCompile(`rtt min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)`)
		if m := rttRe.FindStringSubmatch(output); len(m) > 4 {
			res.MinRTT, _ = strconv.ParseFloat(m[1], 64)
			res.AvgRTT, _ = strconv.ParseFloat(m[2], 64)
			res.MaxRTT, _ = strconv.ParseFloat(m[3], 64)
			res.Jitter, _ = strconv.ParseFloat(m[4], 64)
			res.Success = true
		} else if res.Received > 0 {
			res.Success = true
		}
		if res.Received == 0 {
			res.PacketLoss = 100
		}
	} else {

		if err == nil {
			res.Received = count
			res.PacketLoss = 0
			res.MinRTT = 30.0
			res.AvgRTT = 34.5
			res.MaxRTT = 40.0
			res.Jitter = 2.1
			res.Success = true
		}
	}

	return res
}

func executeMTUTest(ip string, ifMTU int) mtuSummary {
	if ifMTU <= 0 {
		ifMTU = 1380
	}
	res := mtuSummary{Tested: true, Interface: ifMTU}
	fits := func(total int) bool { return doctorDFProbe(ip, total-28) }
	const floor = 1200
	switch {
	case fits(ifMTU):
		res.MaxPacket = ifMTU
	case !fits(floor):
		return res
	default:
		lo, hi := floor, ifMTU
		for hi-lo > 4 {
			mid := (lo + hi) / 2
			if fits(mid) {
				lo = mid
			} else {
				hi = mid
			}
		}
		res.MaxPacket = lo
	}
	res.Optimal = res.MaxPacket
	res.MSS = res.Optimal - 40
	return res
}

func pingWithDF(ip string, size int) bool {
	if runtime.GOOS == "windows" {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ping", "-c", "2", "-i", "0.2", "-M", "do", "-s", strconv.Itoa(size), "-W", "1", ip)
	return cmd.Run() == nil
}

var sysClassNet = "/sys/class/net"

func interfaceMTU(name string) int {
	if name == "" {
		name = "gre-tunnel"
	}
	data, err := os.ReadFile(filepath.Join(sysClassNet, name, "mtu"))
	if err != nil {
		return 0
	}
	v, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return v
}

func executeKernelAudit() kernelAudit {
	res := kernelAudit{
		CongestionAlg: "unknown",
	}

	if runtime.GOOS == "windows" {
		res.BBREnabled = true
		res.CongestionAlg = "bbr"
		res.IPForwarding = true
		res.MSSClamping = true
		res.MSSRule = "1340"
		res.LimitNOFILE = 1048576
		res.Somaxconn = 65535
		res.ConntrackMax = 1048576
		res.TCPTwReuse = true
		return res
	}

	if data, err := os.ReadFile("/proc/sys/net/ipv4/tcp_congestion_control"); err == nil {
		alg := strings.TrimSpace(string(data))
		res.CongestionAlg = alg
		if alg == "bbr" {
			res.BBREnabled = true
		}
	}

	if data, err := os.ReadFile("/proc/sys/net/ipv4/ip_forward"); err == nil {
		if strings.TrimSpace(string(data)) == "1" {
			res.IPForwarding = true
		}
	}

	if out, err := runCmdTimeoutOut(3*time.Second, "iptables-save", "-t", "mangle"); err == nil {
		res.MSSRule = mssRuleFrom(string(out))
		res.MSSClamping = res.MSSRule != ""
	}

	if data, err := os.ReadFile("/proc/sys/net/core/somaxconn"); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			res.Somaxconn = v
		}
	}

	if data, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_max"); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			res.ConntrackMax = v
		}
	} else if data, err := os.ReadFile("/proc/sys/net/nf_conntrack_max"); err == nil {
		if v, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			res.ConntrackMax = v
		}
	}

	if data, err := os.ReadFile("/proc/sys/net/ipv4/tcp_tw_reuse"); err == nil {
		if strings.TrimSpace(string(data)) == "1" {
			res.TCPTwReuse = true
		}
	}

	res.LimitNOFILE = engineNOFILE()

	return res
}

func mssRuleFrom(save string) string {
	for _, line := range strings.Split(save, "\n") {
		if !strings.Contains(line, "TCPMSS") {
			continue
		}
		f := strings.Fields(line)
		for i, w := range f {
			if w == "--set-mss" && i+1 < len(f) {
				return f[i+1]
			}
		}
		return "pmtu"
	}
	return ""
}

func engineNOFILE() int {
	for _, svc := range []string{"frps", "frpc", "backhaul-server", "backhaul-client"} {
		out, err := runCmdTimeoutOut(3*time.Second, "systemctl", "show", "-p", "MainPID", "--value", svc)
		pid := strings.TrimSpace(string(out))
		if err != nil || pid == "" || pid == "0" {
			continue
		}
		data, err := os.ReadFile("/proc/" + pid + "/limits")
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "Max open files") {
				if f := strings.Fields(line); len(f) >= 5 {
					if v, err := strconv.Atoi(f[3]); err == nil {
						return v
					}
				}
			}
		}
	}
	return 0
}

func executeThroughputTest(peerIP string, ifUp bool) speedSummary {
	res := speedSummary{
		Mode:   "iperf3",
		Detail: "Ready for benchmark",
	}

	if isIperfServerRunning() {
		res.ServerActive = true
	}

	if !ifUp || peerIP == "" {
		res.Detail = "Skipped: the peer does not answer through the tunnel"
		return res
	}

	if _, err := exec.LookPath("iperf3"); err != nil {
		res.Detail = "iperf3 is not installed here. Start iPerf3 Server installs it"
		return res
	}

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "iperf3", "-c", peerIP, "-t", "3", "-J")
	out, err := cmd.CombinedOutput()
	if err == nil {
		var iperfJSON struct {
			End struct {
				SumReceived struct {
					BitsPerSecond float64 `json:"bits_per_second"`
				} `json:"sum_received"`
			} `json:"end"`
		}
		if json.Unmarshal(out, &iperfJSON) == nil && iperfJSON.End.SumReceived.BitsPerSecond > 0 {
			res.Tested = true
			res.ThroughputMbps = float64(int((iperfJSON.End.SumReceived.BitsPerSecond/(1000*1000))*10)) / 10.0
			res.Detail = "Measured with iPerf3 for 3 seconds"
			return res
		}
	}

	res.Detail = "No iPerf3 server on the other server. Press Start iPerf3 Server there, then run diagnostics here"
	return res
}

func isIperfServerRunning() bool {
	if runtime.GOOS == "windows" {
		return false
	}

	conn, err := net.DialTimeout("tcp", "127.0.0.1:5201", 200*time.Millisecond)
	if err == nil {
		conn.Close()
		return true
	}

	if out, err := exec.Command("pgrep", "-x", "iperf3").CombinedOutput(); err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return true
	}

	if out, err := exec.Command("pidof", "iperf3").CombinedOutput(); err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return true
	}
	return false
}

func startIperfServer() (string, error) {
	if runtime.GOOS == "windows" {
		return "Mock: iperf3 server started on :5201", nil
	}
	if isIperfServerRunning() {
		return "iperf3 server already running on port 5201", nil
	}

	bind := ""
	if inner := localStatus().Gre.Inner; inner != "" {
		bind, _, _ = strings.Cut(inner, "/")
	}
	if bind == "" {
		return "", fmt.Errorf("iPerf3 measures the GRE link, and this server has no GRE tunnel")
	}

	if _, err := exec.LookPath("iperf3"); err != nil {

		_, _ = runCmdTimeout(90*time.Second, "apt-get", "update", "-qq")
		_, _ = runCmdTimeout(120*time.Second, "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-qq", "iperf3")
		if _, err := exec.LookPath("iperf3"); err != nil {
			return "", fmt.Errorf("iperf3 is not installed on this server. Run 'apt update && apt install -y iperf3'")
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "iperf3", "-s", "-D", "-B", bind)
	out, err := cmd.CombinedOutput()
	if err != nil {
		time.Sleep(250 * time.Millisecond)
		if isIperfServerRunning() {
			return "iperf3 server active on port 5201", nil
		}
		errMsg := strings.TrimSpace(string(out))
		if errMsg != "" {
			return "", fmt.Errorf("%s", errMsg)
		}
		return "", fmt.Errorf("failed to start iperf3: %w", err)
	}

	time.Sleep(250 * time.Millisecond)
	return "iperf3 listening on " + bind + ":5201 (GRE only)", nil
}

func stopIperfServer() (string, error) {
	if runtime.GOOS == "windows" {
		return "Mock: iperf3 server stopped", nil
	}
	_ = exec.Command("pkill", "-x", "iperf3").Run()
	_ = exec.Command("killall", "-9", "iperf3").Run()
	_ = exec.Command("fuser", "-k", "5201/tcp").Run()
	time.Sleep(200 * time.Millisecond)
	return "iperf3 daemon stopped", nil
}

var applyFixesFn = applyDoctorFixes

func applyDoctorFixes() map[string]any {
	fixes := []string{}

	if runtime.GOOS == "windows" {
		return map[string]any{
			"applied": []string{"Mock: BBR enabled", "Mock: TCPMSS clamp added"},
		}
	}

	if out, err := tuneViaInstaller("optimize"); err == nil {
		fixes = append(fixes, "Applied TCP BBR & sysctl optimization: "+out)
	}

	fixes = append(fixes, pathMTUFixes()...)

	_ = exec.Command("sysctl", "-w", "net.ipv4.ip_forward=1").Run()
	_ = exec.Command("sysctl", "-w", "net.core.somaxconn=65535").Run()
	_ = exec.Command("sysctl", "-w", "net.ipv4.tcp_tw_reuse=1").Run()
	fixes = append(fixes, "Enabled IPv4 packet forwarding & tuned socket limits (somaxconn=65535, tw_reuse=1)")

	ensureFRPServiceUnits("frps")
	ensureFRPServiceUnits("frpc")
	fixes = append(fixes, "Configured FRP systemd service limits (LimitNOFILE=1048576, LimitNPROC=512000, Restart=always)")

	fst := localStatus()
	if greExpected(fst) {
		fixes = append(fixes, interfaceFixes(fst, func() error {
			return exec.Command("systemctl", "restart", "gre-tunnel").Run()
		})...)
	}

	if fst.FrpSvc != "" && !fst.FrpUp {
		if _, err := runCmdTimeout(20*time.Second, "systemctl", "restart", fst.FrpSvc); err == nil {
			fixes = append(fixes, "Restarted the stopped "+fst.FrpSvc+" service")
		} else {
			fixes = append(fixes, fst.FrpSvc+" did not start: see Logs")
		}
	}

	return map[string]any{
		"applied": fixes,
	}
}

func greExpected(st tunnelStatus) bool {
	if st.Gre.Exists {
		return true
	}
	if st.Engine == "backhaul" {
		return false
	}
	_, err := os.Stat(filepath.Join(engineUnitDir, "gre-tunnel.service"))
	return err == nil
}

func engineLabel(st tunnelStatus) string {
	if st.Engine != "" {
		return st.Engine
	}
	return "no GRE unit"
}

func interfaceFixes(st tunnelStatus, restartGre func() error) []string {
	var fixes []string
	if !st.Gre.Exists {
		if err := restartGre(); err == nil {
			fixes = append(fixes, "Restarted gre-tunnel service to bring interface UP")
		}
	} else if !st.PingOK && st.Gre.PeerIP != "" {
		fixes = append(fixes, "ICMP not answering: not restarting gre-tunnel (see Reverse Path diagnosis)")
	}
	return fixes
}

func frpcLoginEOF() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "journalctl", "-u", "frpc", "-n", "50", "--no-pager").Output()
	if err != nil {
		return false
	}

	lines := strings.Split(strings.ToLower(string(out)), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		switch {
		case strings.Contains(lines[i], "login to server success"):
			return false
		case strings.Contains(lines[i], "connect to server error: eof"):
			return true
		}
	}
	return false
}

func classifyBackhaulLog(raw string) string {
	lines := strings.Split(raw, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.ToLower(lines[i])
		if strings.Contains(l, "control channel established successfully") ||
			strings.Contains(l, "control channel successfully established") {
			return ""
		}
		if code, _ := matchLogCode(lines[i]); strings.HasPrefix(code, "E-BH-") {
			return code
		}
	}
	return ""
}

func backhaulDoctorIssue(st tunnelStatus) (issue, recommendation string) {
	if !strings.HasPrefix(st.FrpSvc, "backhaul") {
		return "", ""
	}
	out, err := runCmdTimeoutOut(5*time.Second, "journalctl", "-u", st.FrpSvc, "-n", "80", "--no-pager")
	if err != nil {
		return "", ""
	}
	code := classifyBackhaulLog(string(out))
	if code == "" {
		return "", ""
	}
	e := errCatalog[code]
	return fmt.Sprintf("%s: %s (%s)", st.FrpSvc, e.Msg, code), e.Hint
}
