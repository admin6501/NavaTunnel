// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	VerdictPass        = "PASS"
	VerdictFail        = "FAIL"
	VerdictUnreachable = "UNREACHABLE"
)

const (
	layerOK      = "ok"
	layerFail    = "fail"
	layerSkipped = "skipped"
	layerUnknown = "unknown"
)

const (
	tunnelHealthTTL     = 60 * time.Second
	dataProbeDialTO     = 3 * time.Second
	dataProbeBannerWait = 300 * time.Millisecond
	dataProbeEchoWait   = 700 * time.Millisecond
	tunnelTaskTimeout   = 12 * time.Second
)

var dataProbePayload = []byte("\r\n")

var (
	tunnelHealthAutoRun = true
	tunnelHealthSettle  = 12 * time.Second
)

type TunnelLayers struct {
	Service string `json:"service"`
	Session string `json:"session"`
	Data    string `json:"data"`
}

type TunnelHealthEntry struct {
	ID          int          `json:"id"`
	Name        string       `json:"name"`
	Engine      string       `json:"engine"`
	Role        string       `json:"role"`
	Verdict     string       `json:"verdict"`
	LatencyMs   float64      `json:"latency_ms"`
	LatencyKind string       `json:"latency_kind"`
	Layers      TunnelLayers `json:"layers"`
	Reason      string       `json:"reason"`
	Checked     string       `json:"checked"`
}

type tunnelHealthResult struct {
	Tunnels       []TunnelHealthEntry `json:"tunnels"`
	Checked       string              `json:"checked"`
	SnapshotAgeMs int64               `json:"snapshot_age_ms"`
	checkedAt     time.Time
}

type thTarget struct {
	id          int
	name        string
	engine      string
	role        string
	unit        string
	svcUp       bool
	linked      bool
	icmpOK      bool
	latMs       float64
	latKind     string
	ctrlPort    int
	ports       []int
	hosts       []string
	q           ctrlQuery
	probeCached bool
}

func thEngine(declared, unit string, greUp bool) string {
	switch e := strings.ToLower(strings.TrimSpace(declared)); e {
	case "frp", "backhaul", "gre-backhaul":
		return e
	}
	switch {
	case strings.HasPrefix(unit, "backhaul") && greUp:
		return "gre-backhaul"
	case strings.HasPrefix(unit, "backhaul"):
		return "backhaul"
	}
	return "frp"
}

func thBinary(engine, unit string) string {
	if engine != "frp" {
		return "backhaul"
	}
	if strings.HasPrefix(unit, "frpc") {
		return "frpc"
	}
	return "frps"
}

func thTargets(s *HubSnapshot) []thTarget {
	var out []thTarget
	hub := []string{"127.0.0.1"}
	add := func(l peerLive, role, unit string, hosts []string, ctrl int) {
		t := thTarget{id: l.ID, name: l.Name, role: role, unit: unit, svcUp: l.FrpUp, linked: l.Linked,
			icmpOK: l.ICMPOK, latMs: l.LatencyMs, latKind: l.LatencyKind, ctrlPort: ctrl, ports: l.Ports, hosts: hosts,
			q:           ctrlQuery{ID: l.ID, Port: l.FrpPort, RemotePub: l.RemotePub, PeerGre: l.PeerGre},
			probeCached: snapProbe.lookup(l.ID).OK}
		if l.ID == mainTunnelID {
			t.q.PeerGre = l.icmpTarget
		}
		t.engine = thEngine(l.Engine, unit, l.GreUp)
		out = append(out, t)
	}
	if s.Main != nil {
		add(*s.Main, "hub", s.Local.FrpSvc, hub, s.Main.FrpPort)
	} else if strings.HasPrefix(s.Local.Role, "foreign") && s.Local.FrpSvc != "" {
		st := s.Local
		var hosts []string
		peerInner := ""
		if st.Gre.Inner != "" {
			peerInner = grePeerInner(st.Gre.Inner)
			hosts = append(hosts, peerInner)
		}
		if h := normHost(st.RemotePub); h != "" {
			hosts = append(hosts, h)
		}
		l := peerLive{peerRecord: peerRecord{ID: mainTunnelID, Name: "Tunnel", RemotePub: st.RemotePub, Engine: st.Engine,
			FrpPort: st.BindPort, Ports: st.ProxyPorts, PeerGre: peerInner},
			GreUp: st.Gre.Exists, FrpUp: st.FrpUp, Linked: s.LocalSession, LatencyMs: -1}
		if s.LocalSession && s.LocalRTT >= 0 {
			l.LatencyMs, l.LatencyKind = round1(s.LocalRTT), "tcp"
		}
		add(l, "spoke", st.FrpSvc, hosts, st.BindPort)
	}
	for _, p := range s.Peers {
		add(p, "peer", p.FrpsSvc, hub, p.FrpPort)
	}
	return out
}

func dataProbe(hosts []string, port int) (rtt float64, detail string, err error) {
	var last error
	for _, h := range hosts {
		addr := net.JoinHostPort(h, strconv.Itoa(port))
		start := time.Now()
		c, derr := dialFn("tcp", addr, dataProbeDialTO)
		if derr != nil {
			last = fmt.Errorf("connect %s: %w", addr, derr)
			continue
		}
		rtt, detail, err = probeConn(c, start)
		_ = c.Close()
		if err == nil {
			return rtt, detail, nil
		}
		last = fmt.Errorf("%s: %w", addr, err)
	}
	if last == nil {
		last = errors.New("no address to probe")
	}
	return -1, "", last
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

func probeConn(c net.Conn, start time.Time) (float64, string, error) {
	rtt := func() float64 { return max(float64(time.Since(start).Nanoseconds())/1e6, 0.001) }
	buf := make([]byte, 1024)
	_ = c.SetReadDeadline(time.Now().Add(dataProbeBannerWait))
	if n, err := c.Read(buf); n > 0 {
		return rtt(), "server sent a banner", nil
	} else if err != nil && !isTimeout(err) {
		return -1, "", errors.New("connection closed right after connect (the service behind the forward is down or refusing)")
	}
	_ = c.SetWriteDeadline(time.Now().Add(dataProbeEchoWait))
	if _, err := c.Write(dataProbePayload); err != nil {
		return -1, "", fmt.Errorf("payload write failed: %w", err)
	}
	_ = c.SetReadDeadline(time.Now().Add(dataProbeEchoWait))
	n, err := c.Read(buf)
	switch {
	case n > 0:
		return rtt(), "payload answered", nil
	case err != nil && isTimeout(err):
		return rtt(), "payload accepted, connection held open", nil
	}
	return rtt(), "payload accepted, remote closed afterwards", nil
}

func checkTunnel(t thTarget, now string) TunnelHealthEntry {
	e := TunnelHealthEntry{ID: t.id, Name: t.name, Engine: t.engine, Role: t.role, LatencyMs: -1, Checked: now,
		Layers: TunnelLayers{Service: layerSkipped, Session: layerSkipped, Data: layerSkipped}}
	if t.latKind != "" && t.latMs >= 0 {
		e.LatencyMs, e.LatencyKind = t.latMs, t.latKind
	}
	if bin := thBinary(t.engine, t.unit); !engineBinaryPresent(bin) {
		e.Verdict, e.Layers.Service = VerdictFail, layerFail
		e.Reason = fmt.Sprintf("engine binary missing (%s not installed) — the %s tunnel cannot run", bin, t.engine)
		return e
	}
	if !t.svcUp {
		e.Verdict, e.Layers.Service = VerdictFail, layerFail
		if t.unit == "" {
			e.Reason = "no tunnel service configured for this entry"
		} else {
			e.Reason = fmt.Sprintf("%s is configured but not active", t.unit)
		}
		return e
	}
	e.Layers.Service = layerOK
	if !t.linked {
		path := ""
		switch {
		case t.icmpOK:
			path = "ping"
		case t.probeCached:
			path = "TCP"
		default:
			if r := connectProbe(t.q); r.OK {
				path = "TCP"
			}
		}
		if path == "" {
			e.Verdict, e.Layers.Session = VerdictUnreachable, layerUnknown
			e.Reason = "peer not answering on any path — cannot tell engine health"
			return e
		}
		e.Verdict, e.Layers.Session = VerdictFail, layerFail
		e.Reason = fmt.Sprintf("control session expected but absent (peer answers %s, its %s client is not connected)", path, t.engine)
		return e
	}
	e.Layers.Session = layerOK

	port := 0
	for _, p := range t.ports {
		if p > 0 {
			port = p
			break
		}
	}
	if len(t.hosts) == 0 {

		e.Verdict, e.Layers.Data = VerdictUnreachable, layerUnknown
		e.Reason = "session live but no address to probe — cannot verify the data path"
		return e
	}
	if port == 0 {

		if _, _, err := dataProbeConnectOnly(t.hosts, t.ctrlPort); err != nil {
			e.Verdict, e.Layers.Data = VerdictFail, layerFail
			e.Reason = "no forwarded port to probe — control port only; control port connect failed: " + err.Error()
			return e
		}
		e.Verdict = VerdictPass
		e.Reason = "no forwarded port to probe — control port only"
		return e
	}
	rtt, detail, err := dataProbe(t.hosts, port)
	if err != nil {
		e.Verdict, e.Layers.Data = VerdictFail, layerFail
		e.Reason = fmt.Sprintf("control session is live but the data probe on port %d failed: %v", port, err)
		return e
	}
	e.Verdict, e.Layers.Data = VerdictPass, layerOK
	if e.LatencyKind == "" {
		e.LatencyMs, e.LatencyKind = round1(rtt), "data"
	}
	e.Reason = fmt.Sprintf("service active, session live, data path OK on port %d (%s)", port, detail)
	return e
}

func dataProbeConnectOnly(hosts []string, port int) (float64, string, error) {
	if port <= 0 {
		return -1, "", errors.New("no control port known")
	}
	var last error
	for _, h := range hosts {
		addr := net.JoinHostPort(h, strconv.Itoa(port))
		start := time.Now()
		c, err := dialFn("tcp", addr, dataProbeDialTO)
		if err != nil {
			last = err
			continue
		}
		_ = c.Close()
		return float64(time.Since(start).Nanoseconds()) / 1e6, "connect", nil
	}
	if last == nil {
		last = errors.New("no address to probe")
	}
	return -1, "", last
}

var (
	tunnelHealthMu   sync.Mutex
	tunnelHealthLast *tunnelHealthResult
	tunnelHealthRun  sync.Mutex
	tunnelHealthPool = newWorkPool(min(runtime.NumCPU(), 4))
)

func runTunnelHealth() *tunnelHealthResult {
	snap := currentSnapshot()
	now := time.Now()
	stamp := now.UTC().Format(time.RFC3339)
	res := &tunnelHealthResult{Tunnels: []TunnelHealthEntry{}, Checked: stamp, SnapshotAgeMs: snap.AgeMs(), checkedAt: now}
	targets := thTargets(snap)

	var mu sync.Mutex
	done := make([]*TunnelHealthEntry, len(targets))
	sealed := false
	for i, t := range targets {
		i, t := i, t
		tunnelHealthPool.submit("th:"+strconv.Itoa(i), tunnelTaskTimeout, func() {
			defer func() { _ = recover() }()
			e := checkTunnel(t, stamp)
			mu.Lock()
			if !sealed {
				done[i] = &e
			}
			mu.Unlock()
		})
	}
	tunnelHealthPool.wait()
	mu.Lock()
	sealed = true
	for i, t := range targets {
		if done[i] != nil {
			res.Tunnels = append(res.Tunnels, *done[i])
			continue
		}
		res.Tunnels = append(res.Tunnels, TunnelHealthEntry{ID: t.id, Name: t.name, Engine: t.engine, Role: t.role,
			Verdict: VerdictFail, LatencyMs: -1, Checked: stamp, Reason: "health check timed out",
			Layers: TunnelLayers{Service: layerUnknown, Session: layerUnknown, Data: layerUnknown}})
	}
	mu.Unlock()
	return res
}

func tunnelHealthCached() *tunnelHealthResult {
	tunnelHealthMu.Lock()
	defer tunnelHealthMu.Unlock()
	return tunnelHealthLast
}

func tunnelHealthRefresh(force bool) *tunnelHealthResult {
	arrived := time.Now()
	tunnelHealthRun.Lock()
	defer tunnelHealthRun.Unlock()
	if c := tunnelHealthCached(); c != nil && (c.checkedAt.After(arrived) || (!force && time.Since(c.checkedAt) < tunnelHealthTTL)) {
		return c
	}
	res := runTunnelHealth()
	if res.SnapshotAgeMs >= 0 {
		tunnelHealthMu.Lock()
		tunnelHealthLast = res
		tunnelHealthMu.Unlock()
	}
	return res
}

func runTunnelHealthOnce() {
	defer func() { _ = recover() }()
	if !tunnelHealthAutoRun {
		return
	}
	time.Sleep(tunnelHealthSettle)
	tunnelHealthRefresh(true)
}

func handleTunnelHealthGet(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("cached") == "1" {
		if c := tunnelHealthCached(); c != nil {
			writeJSON(w, c)
		} else {
			writeJSON(w, &tunnelHealthResult{Tunnels: []TunnelHealthEntry{}, SnapshotAgeMs: -1})
		}
		return
	}
	writeJSON(w, tunnelHealthRefresh(false))
}

func handleTunnelHealthRun(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, tunnelHealthRefresh(true))
}

func resetTunnelHealth() {
	tunnelHealthMu.Lock()
	tunnelHealthLast = nil
	tunnelHealthMu.Unlock()
}
