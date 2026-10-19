// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

func revPathAutoEnabled() bool {
	if os.Getenv("NAVATUNNEL_REVPATH_AUTO") == "1" {
		return true
	}
	return cfg.RevPathAuto
}

type SpokeProbeRequest struct {
	HubInner    string `json:"hub_inner"`
	HubPublic   string `json:"hub_public"`
	ControlPort int    `json:"control_port"`
}

type SpokeProbeReport struct {
	OK       bool          `json:"ok"`
	Error    string        `json:"error,omitempty"`
	Matrix   ProbeMatrix   `json:"matrix"`
	Snapshot LocalSnapshot `json:"snapshot"`
	SpokeGre string        `json:"spoke_gre,omitempty"`
	Checked  string        `json:"checked"`
}

func handlePeerRevPathProbe(w http.ResponseWriter, r *http.Request) {
	var req SpokeProbeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, r, "E-ACTION-01", "invalid probe json")
		return
	}
	st := currentLocal()
	spokeInner := strings.SplitN(st.Gre.Inner, "/", 2)[0]
	snap := LocalSnapshot{
		GreIf:           "gre-tunnel",
		InnerLocal:      spokeInner,
		RPFilterAll:     readRPFilter("all"),
		RPFilterDefault: readRPFilter("default"),
		RPFilterIface:   readRPFilter("gre-tunnel"),
		GreMTU:          -1,
	}
	if v, ok := readProcFile("sys/net/ipv4/ip_forward"); ok {
		snap.IPForward = parseIntFile(v) == 1
	}
	if out, err := runCmdTimeout(3*time.Second, "ip", "-o", "link", "show", "gre-tunnel"); err == nil {
		snap.GreMTU = parseLinkMTU(string(out))
	}
	if req.HubInner != "" {
		if out, err := runCmdTimeout(3*time.Second, "ip", "route", "get", req.HubInner); err == nil {
			src, dev := parseRouteGet(string(out))
			snap.RouteKnown = dev != ""
			snap.RouteBackViaGre = dev == "gre-tunnel"
			snap.SrcAddrOnReply = src
		}
	}
	if out, err := runCmdTimeout(5*time.Second, "iptables-save"); err == nil {
		snap.FwChecked = true
		snap.InputDropsProto47, snap.FwDropsICMP = parseIptablesSave(string(out), "gre-tunnel")
	}
	m := probeFromSpoke(req, snap)
	writeJSON(w, SpokeProbeReport{OK: true, Matrix: m, Snapshot: snap,
		SpokeGre: spokeInner, Checked: time.Now().UTC().Format(time.RFC3339)})
}

func probeFromSpoke(req SpokeProbeRequest, snap LocalSnapshot) ProbeMatrix {
	var m ProbeMatrix
	rx0, tx0, have := greCounters("gre-tunnel")
	if req.HubInner != "" {
		m.Results = append(m.Results,
			spokePing(LayerICMPGre64, 64, false, snap.InnerLocal, req.HubInner),
			spokePing(LayerICMPGre1300, 1300, true, snap.InnerLocal, req.HubInner))
		if req.ControlPort > 0 {
			m.Results = append(m.Results, spokeTCP(LayerTCPCtrlInner, req.HubInner, req.ControlPort))
		}
	}
	if req.HubPublic != "" {
		m.Results = append(m.Results, spokePing(LayerICMPPublic, 0, false, "", req.HubPublic))
		if req.ControlPort > 0 {
			m.Results = append(m.Results, spokeTCP(LayerTCPCtrlPublic, req.HubPublic, req.ControlPort))
		}
	}
	if req.HubPublic != "" {

		if req.ControlPort > 0 {
			m.Results = append(m.Results, spokeTCP(LayerTCPWSS, req.HubPublic, req.ControlPort+2))
		}
	}
	if rx1, tx1, ok := greCounters("gre-tunnel"); have && ok {
		dr, dt := rx1-rx0, tx1-tx0
		m.SpokeRxDelta, m.SpokeTxDelta = &dr, &dt
	}
	return m
}

func spokePing(layer string, size int, df bool, src, dst string) ProbeResult {
	r := ProbeResult{Layer: layer, Direction: DirSpokeToHub, Size: size, DF: df}
	args := []string{"-c", "1", "-W", "2"}
	if df {
		args = append(args, "-M", "do")
	}
	if size > 0 {
		args = append(args, "-s", fmt.Sprint(size-28))
	}
	if src != "" {
		args = append(args, "-I", src)
	}
	args = append(args, dst)
	out, err := runCmdTimeout(4*time.Second, "ping", args...)
	if err != nil {
		r.Err = strings.TrimSpace(firstLine(string(out)))
		if r.Err == "" {
			r.Err = err.Error()
		}
		return r
	}
	r.OK = true
	r.RTTms = parsePingRTT(string(out))
	return r
}

func spokeTCP(layer, host string, port int) ProbeResult {
	r := ProbeResult{Layer: layer, Direction: DirSpokeToHub}
	c, err := dialFn("tcp", fmt.Sprintf("%s:%d", host, port), connectProbeTimeout)
	if err == nil {
		_ = c.Close()
		r.OK = true
		return r
	}
	if isRefusedErr(err) {

		r.OK = true
		return r
	}
	r.Err = err.Error()
	return r
}

func isRefusedErr(err error) bool { return errors.Is(err, syscall.ECONNREFUSED) }

var spokeFetcher = requestSpokeProbe

func requestSpokeProbe(p peerRecord) *SpokeProbeReport {
	c := loadPeerConfig()
	if c.PeerSecret == "" {
		return nil
	}
	hubInner := strings.SplitN(p.LocalGre, "/", 2)[0]
	if hubInner == "" {

		st := currentLocal()
		hubInner = strings.SplitN(st.Gre.Inner, "/", 2)[0]
	}
	req := SpokeProbeRequest{HubInner: hubInner, HubPublic: p.LocalPub, ControlPort: p.FrpPort}
	body, _ := json.Marshal(req)

	target := PeerConfig{InternalIP: p.PeerGre, InternalPort: c.InternalPort, PeerBasePath: c.PeerBasePath}
	if p.RemotePub != "" {
		target.PeerURL = "http://" + p.RemotePub
	}
	urls := peerTargetURLs(target, "/api/peer/revpath-probe")
	if len(urls) == 0 {
		return nil
	}
	client := &http.Client{
		Timeout:       15 * time.Second,
		Transport:     &http.Transport{DialContext: (&net.Dialer{Timeout: 4 * time.Second}).DialContext},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	deadHosts := map[string]bool{}
	for _, u := range urls {
		hostKey := u
		if pu, err := url.Parse(u); err == nil {
			hostKey = pu.Host
		}
		if deadHosts[hostKey] {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		hr, err := http.NewRequestWithContext(ctx, "POST", u, bytes.NewReader(body))
		if err != nil {
			cancel()
			continue
		}
		hr.Header.Set("Content-Type", "application/json")
		hr.Header.Set("X-Peer-Secret", c.PeerSecret)
		resp, err := client.Do(hr)
		if err != nil {
			cancel()
			deadHosts[hostKey] = true
			continue
		}
		var rep SpokeProbeReport
		derr := json.NewDecoder(resp.Body).Decode(&rep)
		_ = resp.Body.Close()
		cancel()
		if derr != nil || !rep.OK {
			continue
		}
		return &rep
	}
	return nil
}

func mergeSpokeReport(e *revPathEntry, rep *SpokeProbeReport) {
	if rep == nil {
		return
	}
	keep := e.Matrix.Results[:0]
	for _, r := range e.Matrix.Results {
		if r.Direction == DirSpokeToHub || r.Direction == DirUnprobed {
			continue
		}
		keep = append(keep, r)
	}
	e.Matrix.Results = append(keep, rep.Matrix.Results...)
	e.Matrix.SpokeRxDelta = rep.Matrix.SpokeRxDelta
	e.Matrix.SpokeTxDelta = rep.Matrix.SpokeTxDelta
	e.Diagnosis = classifyRevPath(e.Matrix, e.Snapshot)
}

type FixStep struct {
	At      string  `json:"at"`
	Verdict Verdict `json:"verdict"`
	Action  string  `json:"action"`
	Detail  string  `json:"detail"`
	OK      bool    `json:"ok"`
	Error   string  `json:"error,omitempty"`
}

type FixReport struct {
	PeerID      int       `json:"peer_id"`
	Auto        bool      `json:"auto"`
	Steps       []FixStep `json:"steps"`
	LastRun     string    `json:"last_run,omitempty"`
	LastVerdict Verdict   `json:"last_verdict,omitempty"`
}

var (
	fixMu      sync.Mutex
	fixReports = map[int]*FixReport{}
	fixLastRun = map[int]time.Time{}
	fixHour    = []time.Time{}
)

const (
	fixPeerCooldown = 10 * time.Minute
	fixHourMax      = 3
	revChain        = "NAVA-REVPATH"
)

func fixAllowed(peerID int, now time.Time) bool {
	fixMu.Lock()
	defer fixMu.Unlock()
	if t, ok := fixLastRun[peerID]; ok && now.Sub(t) < fixPeerCooldown {
		return false
	}
	kept := fixHour[:0]
	for _, t := range fixHour {
		if now.Sub(t) < time.Hour {
			kept = append(kept, t)
		}
	}
	fixHour = kept
	return len(fixHour) < fixHourMax
}

func fixMarkRun(peerID int, now time.Time) {
	fixMu.Lock()
	defer fixMu.Unlock()
	fixLastRun[peerID] = now
	fixHour = append(fixHour, now)
}

func fixRecord(peerID int, s FixStep, auto bool, v Verdict) {
	fixMu.Lock()
	defer fixMu.Unlock()
	r := fixReports[peerID]
	if r == nil {
		r = &FixReport{PeerID: peerID}
		fixReports[peerID] = r
	}
	r.Auto = auto
	r.Steps = append(r.Steps, s)
	if len(r.Steps) > 20 {
		r.Steps = r.Steps[len(r.Steps)-20:]
	}
	r.LastRun = s.At
	r.LastVerdict = v
}

var revpathSysctlConf = "/etc/sysctl.d/99-navatunnel-revpath.conf"

func sysctlPersist(key, value string) (rollback func(), err error) {
	old, _ := runCmdTimeout(3*time.Second, "sysctl", "-n", key)
	oldVal := strings.TrimSpace(string(old))
	if _, err := runCmdTimeout(5*time.Second, "sysctl", "-w", key+"="+value); err != nil {
		return nil, err
	}
	conf := revpathSysctlConf
	prev, prevErr := os.ReadFile(conf)

	rb := func() {
		_, _ = runCmdTimeout(5*time.Second, "sysctl", "-w", key+"="+oldVal)
		if oldVal == value {
			return
		}
		if prevErr != nil {
			_ = os.Remove(conf)
		} else {
			_ = os.WriteFile(conf, prev, 0644)
		}
	}
	if oldVal == value {
		return rb, nil
	}
	lines := []string{}
	for _, l := range strings.Split(string(prev), "\n") {
		if strings.TrimSpace(l) == "" || strings.HasPrefix(strings.TrimSpace(l), "#") {
			lines = append(lines, l)
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(l), key+" ") || strings.HasPrefix(strings.TrimSpace(l), key+"=") {
			continue
		}
		lines = append(lines, l)
	}
	lines = append(lines, key+" = "+value)
	if err := os.MkdirAll(filepath.Dir(conf), 0755); err != nil {
		return rb, err
	}
	if err := os.WriteFile(conf, []byte(strings.Join(lines, "\n")), 0644); err != nil {
		return rb, err
	}
	return rb, nil
}

func chainEnsure() error {
	if _, err := runCmdTimeout(3*time.Second, "iptables", "-n", "-L", revChain); err != nil {
		if _, err := runCmdTimeout(3*time.Second, "iptables", "-N", revChain); err != nil {
			return err
		}
	}
	for _, parent := range []string{"INPUT", "FORWARD"} {
		out, _ := runCmdTimeout(3*time.Second, "iptables", "-C", parent, "-j", revChain)
		_ = out
		if _, err := runCmdTimeout(3*time.Second, "iptables", "-C", parent, "-j", revChain); err != nil {
			if _, err := runCmdTimeout(3*time.Second, "iptables", "-I", parent, "1", "-j", revChain); err != nil {
				return err
			}
		}
	}
	return nil
}

func fixPlan(p peerRecord, snap LocalSnapshot, d RevPathDiagnosis) []fixAction {
	switch d.Verdict {
	case VerdictRPFilter:
		ifaces := []string{"net.ipv4.conf.all.rp_filter", "net.ipv4.conf.default.rp_filter"}
		if p.GreIf != "" {
			ifaces = append(ifaces, "net.ipv4.conf."+p.GreIf+".rp_filter")
		}
		var acts []fixAction
		for _, k := range ifaces {
			k := k
			acts = append(acts, fixAction{
				desc: "sysctl " + k + "=2 (loose)",
				apply: func() (func(), error) {
					return sysctlPersist(k, "2")
				},
			})
		}
		return acts
	case VerdictSrcSelect:
		return []fixAction{{
			desc: "pin GRE route source to " + snap.InnerLocal,
			apply: func() (func(), error) {
				old, _ := runCmdTimeout(3*time.Second, "ip", "route", "show", p.PeerGre)
				oldStr := strings.TrimSpace(string(old))
				args := []string{"route", "replace", p.PeerGre, "dev", p.GreIf}
				if snap.InnerLocal != "" {
					args = append(args, "src", snap.InnerLocal)
				}
				if _, err := runCmdTimeout(5*time.Second, "ip", args...); err != nil {
					return nil, err
				}
				return func() {
					if oldStr != "" {
						_, _ = runCmdTimeout(5*time.Second, "ip", "route", "replace", p.PeerGre, "dev", p.GreIf)
					} else {
						_, _ = runCmdTimeout(5*time.Second, "ip", "route", "del", p.PeerGre)
					}
				}, nil
			},
		}}
	case VerdictNoReturnRoute:
		return []fixAction{{
			desc: "add return route to " + p.PeerGre + " via " + p.GreIf,
			apply: func() (func(), error) {
				if _, err := runCmdTimeout(5*time.Second, "ip", "route", "replace", p.PeerGre, "dev", p.GreIf); err != nil {
					return nil, err
				}
				return func() {
					_, _ = runCmdTimeout(5*time.Second, "ip", "route", "del", p.PeerGre)
				}, nil
			},
		}}
	case VerdictFwInput:
		return []fixAction{{
			desc: "allow proto 47 + ICMP from " + fwSourceDesc(p) + " + " + p.GreIf + " in " + revChain,
			apply: func() (func(), error) {
				if err := chainEnsure(); err != nil {
					return nil, err
				}
				added := [][]string{}

				src := []string{}
				if net.ParseIP(p.RemotePub) != nil {
					src = []string{"-s", p.RemotePub}
				}
				rules := [][]string{
					append(append([]string{}, src...), "-p", "47", "-j", "ACCEPT"),
					append(append([]string{}, src...), "-p", "icmp", "-j", "ACCEPT"),
				}
				if p.GreIf != "" {
					rules = append(rules, []string{"-i", p.GreIf, "-j", "ACCEPT"})
				}
				for _, r := range rules {
					if _, err := runCmdTimeout(3*time.Second, "iptables", append([]string{"-C", revChain}, r...)...); err != nil {
						args := append([]string{"-A", revChain}, r...)
						if _, err := runCmdTimeout(3*time.Second, "iptables", args...); err != nil {
							return nil, err
						}
						added = append(added, r)
					}
				}
				return func() {
					for _, r := range added {
						_, _ = runCmdTimeout(3*time.Second, "iptables", append([]string{"-D", revChain}, r...)...)
					}
				}, nil
			},
		}}
	case VerdictMTUBlackhole:
		steps := []int{1360, 1340, 1300}
		cur := snap.GreMTU
		next := 0
		for _, m := range steps {
			if cur <= 0 || m < cur {
				next = m
				break
			}
		}
		if next == 0 {
			return nil
		}
		return []fixAction{{
			desc: fmt.Sprintf("lower %s MTU %d -> %d", p.GreIf, cur, next),
			apply: func() (func(), error) {
				if _, err := runCmdTimeout(5*time.Second, "ip", "link", "set", "dev", p.GreIf, "mtu", fmt.Sprint(next)); err != nil {
					return nil, err
				}
				return func() {
					if cur > 0 {
						_, _ = runCmdTimeout(5*time.Second, "ip", "link", "set", "dev", p.GreIf, "mtu", fmt.Sprint(cur))
					}
				}, nil
			},
		}}
	case VerdictConntrackInvalid:
		return []fixAction{{
			desc: "NOTRACK proto 47 on " + p.GreIf + " (raw table)",
			apply: func() (func(), error) {
				chain := []string{"-t", "raw", "-p", "47", "-j", "NOTRACK"}
				rule := append([]string{}, chain...)
				if p.GreIf != "" {
					rule = []string{"-i", p.GreIf, "-p", "47", "-j", "NOTRACK"}
				}
				check := append([]string{"-t", "raw", "-C", "PREROUTING"}, rule...)
				if _, err := runCmdTimeout(3*time.Second, "iptables", check...); err != nil {
					if _, err := runCmdTimeout(3*time.Second, "iptables", append([]string{"-t", "raw", "-A", "PREROUTING"}, rule...)...); err != nil {
						return nil, err
					}
					return func() {
						_, _ = runCmdTimeout(3*time.Second, "iptables", append([]string{"-t", "raw", "-D", "PREROUTING"}, rule...)...)
					}, nil
				}
				return func() {}, nil
			},
		}}
	}
	return nil
}

type fixAction struct {
	desc  string
	apply func() (rollback func(), err error)
}

func fwSourceDesc(p peerRecord) string {
	if net.ParseIP(p.RemotePub) != nil {
		return p.RemotePub
	}
	return "any (peer public IP unknown)"
}

func worseAfter(before, after RevPathDiagnosis) bool {
	if before.Verdict == VerdictHealthy && after.Verdict != VerdictHealthy {
		return true
	}
	return false
}

func failedLayers(m ProbeMatrix) int {
	if len(m.Results) == 0 {
		return -1
	}
	n := 0
	for _, r := range m.Results {
		if !r.OK {
			n++
		}
	}
	return n
}

func fixMadeWorse(before RevPathDiagnosis, beforeFails int, after *revPathEntry) bool {
	if worseAfter(before, after.Diagnosis) {
		return true
	}
	afterFails := failedLayers(after.Matrix)
	return beforeFails >= 0 && afterFails > beforeFails
}

func applyFix(p peerRecord, snap LocalSnapshot, d RevPathDiagnosis, auto bool, dryRun bool) ([]FixStep, RevPathDiagnosis) {
	plan := fixPlan(p, snap, d)
	now := time.Now().UTC().Format(time.RFC3339)
	var steps []FixStep
	if dryRun {
		for _, a := range plan {
			steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "plan", Detail: a.desc, OK: true})
		}
		if len(plan) == 0 {
			steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "plan", Detail: "no local fix available (" + string(d.Verdict) + ")", OK: false})
		}
		return steps, d
	}
	if !fixAllowed(p.ID, time.Now()) {
		steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "rate-limited", Detail: "max 1 fix / peer / 10 min, 3 / hour; skipped", OK: false})
		return steps, d
	}

	beforeFails := -1
	revPathMu.Lock()
	if e := revPathCache[p.ID]; e != nil {
		beforeFails = failedLayers(e.Matrix)
	}
	revPathMu.Unlock()
	type applied struct {
		desc string
		rb   func()
	}
	var done []applied
	rollbackAll := func() {
		for i := len(done) - 1; i >= 0; i-- {
			done[i].rb()
		}
	}
	for _, a := range plan {
		rb, err := a.apply()
		st := FixStep{At: now, Verdict: d.Verdict, Action: "apply", Detail: a.desc, OK: err == nil}
		if err != nil {
			st.Error = err.Error()
			steps = append(steps, st)
			rollbackAll()
			steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "rollback", Detail: "apply failed; reverted", OK: true})
			for _, s := range steps {
				fixRecord(p.ID, s, auto, d.Verdict)
			}
			return steps, d
		}
		steps = append(steps, st)
		done = append(done, applied{a.desc, rb})
	}
	fixMarkRun(p.ID, time.Now())

	after := diagnosePeer(p)
	if rep := spokeFetcher(p); rep != nil {
		mergeSpokeReport(after, rep)
		revPathMu.Lock()
		revPathCache[p.ID] = after
		revPathMu.Unlock()
	}
	if fixMadeWorse(d, beforeFails, after) {
		rollbackAll()
		steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "rollback", Detail: "re-probe worse (" + string(after.Diagnosis.Verdict) + "); reverted", OK: true})
		for _, s := range steps {
			fixRecord(p.ID, s, auto, d.Verdict)
		}
		return steps, after.Diagnosis
	}
	steps = append(steps, FixStep{At: now, Verdict: d.Verdict, Action: "verify", Detail: "re-probe: " + string(after.Diagnosis.Verdict), OK: true})
	for _, s := range steps {
		fixRecord(p.ID, s, auto, d.Verdict)
	}
	return steps, after.Diagnosis
}

func handleRevPathFix(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PeerID int  `json:"peer_id"`
		Apply  bool `json:"apply"`
		Auto   bool `json:"auto"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PeerID <= 0 {
		writeAPIError(w, r, "E-ACTION-01", "peer_id required")
		return
	}
	p := findPeer(req.PeerID)
	if p == nil {
		writeAPIError(w, r, "E-ACTION-01", "unknown peer")
		return
	}
	entries := revPathRefresh([]int{req.PeerID}, true)
	if len(entries) == 0 {
		writeAPIError(w, r, "E-SYS-01", "diagnosis failed")
		return
	}
	e := entries[0]
	if !req.Apply {
		steps, _ := applyFix(*p, e.Snapshot, e.Diagnosis, false, true)
		writeJSON(w, map[string]any{"peer_id": p.ID, "dry_run": true, "auto_enabled": revPathAutoEnabled(), "diagnosis": e.Diagnosis, "steps": steps})
		return
	}
	if req.Auto && !revPathAutoEnabled() {
		writeAPIError(w, r, "E-ACTION-01", "automatic fixes are off (revpath_auto)")
		return
	}
	steps, after := applyFix(*p, e.Snapshot, e.Diagnosis, req.Auto, false)
	writeJSON(w, map[string]any{"peer_id": p.ID, "dry_run": false, "auto": req.Auto, "before": e.Diagnosis, "after": after, "steps": steps})
}

func handleRevPathFixes(w http.ResponseWriter, r *http.Request) {
	fixMu.Lock()
	defer fixMu.Unlock()
	q := r.URL.Query().Get("peer_id")
	if q != "" {
		for id, rep := range fixReports {
			if fmt.Sprint(id) == q {
				writeJSON(w, map[string]any{"fixes": []FixReport{*rep}, "auto_enabled": revPathAutoEnabled()})
				return
			}
		}
		writeJSON(w, map[string]any{"fixes": []FixReport{}, "auto_enabled": revPathAutoEnabled()})
		return
	}
	out := make([]FixReport, 0, len(fixReports))
	for _, rep := range fixReports {
		out = append(out, *rep)
	}
	writeJSON(w, map[string]any{"fixes": out, "auto_enabled": revPathAutoEnabled()})
}
