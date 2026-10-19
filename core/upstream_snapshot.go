// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"hash/fnv"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	snapshotEvery = 5 * time.Second
	icmpEvery     = 60 * time.Second

	snapFirstWait = 3 * time.Second
)

const (
	icmpFirstJitter  = 3 * time.Second
	icmpRepeatJitter = 5 * time.Second
	probeOKTTL       = 15 * time.Second
	probeFailTTL     = 30 * time.Second
	snapTaskTimeout  = 6 * time.Second
)

var baseUnits = []string{"frps", "frpc"}

type icmpResult struct {
	OK    bool
	Ms    float64
	Known bool
}

type devCounters struct{ rx, tx uint64 }

type hostView struct {
	sessions   []ssSession
	tunnelShow string
	tunnelOK   bool
	inner      map[string]string
	active     map[string]bool
	devData    string
	dev        map[string]devCounters
	flowing    map[string]bool
	owners     map[int]int
	icmp       func(target string) icmpResult
	connect    func(id int) connectResult
}

func (v *hostView) icmpFor(target string) icmpResult {
	if target == "" || v.icmp == nil {
		return icmpResult{}
	}
	return v.icmp(target)
}

func (v *hostView) traffic(ifname string) (rx, tx *uint64) {
	c, ok := v.dev[ifname]
	if !ok {
		return nil, nil
	}
	r, t := c.rx, c.tx
	return &r, &t
}

func parseAddrShow(out string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		name := strings.TrimSuffix(f[1], ":")
		if i := strings.IndexByte(name, '@'); i >= 0 {
			name = name[:i]
		}
		for i := 2; i+1 < len(f); i++ {
			if f[i] == "inet" {
				if _, seen := m[name]; !seen {
					m[name] = f[i+1]
				}
				break
			}
		}
	}
	return m
}

func parseIsActive(units []string, out string) (map[string]bool, bool) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != len(units) {
		return nil, false
	}
	m := make(map[string]bool, len(units))
	for i, u := range units {
		m[u] = strings.TrimSpace(lines[i]) == "active"
	}
	return m, true
}

func parseNetDev(data string) map[string]devCounters {
	m := map[string]devCounters{}
	for _, line := range strings.Split(data, "\n") {
		name, rest, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		if len(f) < 9 {
			continue
		}
		r, e1 := strconv.ParseUint(f[0], 10, 64)
		t, e2 := strconv.ParseUint(f[8], 10, 64)
		if e1 != nil || e2 != nil {
			continue
		}
		m[strings.TrimSpace(name)] = devCounters{r, t}
	}
	return m
}

func unitsFor(recs []peerRecord) []string {
	units := append([]string{}, baseUnits...)
	seen := map[string]bool{}
	for _, u := range units {
		seen[u] = true
	}
	for _, p := range recs {
		if p.FrpsSvc != "" && !seen[p.FrpsSvc] {
			seen[p.FrpsSvc] = true
			units = append(units, p.FrpsSvc)
		}
	}
	return units
}

func controlPortsOf(recs []peerRecord, extra ...int) []int {
	var ports []int
	for _, p := range recs {
		ports = append(ports, p.FrpPort)
	}
	return append(ports, extra...)
}

func timedStep(name string, f func()) {
	t := time.Now()
	f()
	recordSampler("snapshot."+name, time.Since(t))
}

func collectHost(recs []peerRecord, prev map[string]devCounters) *hostView {
	v := &hostView{inner: map[string]string{}, active: map[string]bool{}, flowing: map[string]bool{}}
	timedStep("ss", func() {
		if out, err := runCmdTimeoutOut(5*time.Second, "ss", "-Htin", "state", "established"); err == nil {
			v.sessions = parseSS(string(out))
		}
	})
	timedStep("ip_tunnel", func() {
		if out, err := runCmdTimeout(5*time.Second, "ip", "tunnel", "show"); err == nil {
			v.tunnelShow, v.tunnelOK = string(out), true
		}
	})
	timedStep("ip_addr", func() {
		if out, err := runCmdTimeoutOut(5*time.Second, "ip", "-o", "-4", "addr", "show"); err == nil {
			v.inner = parseAddrShow(string(out))
		}
	})
	timedStep("systemctl", func() {
		units := unitsFor(recs)
		out, _ := runCmdTimeoutOut(5*time.Second, "systemctl", append([]string{"is-active"}, units...)...)
		if m, ok := parseIsActive(units, string(out)); ok {
			v.active = m
			return
		}
		for _, u := range units {
			o, _ := runCmdTimeoutOut(5*time.Second, "systemctl", "is-active", u)
			v.active[u] = strings.TrimSpace(string(o)) == "active"
		}
	})
	timedStep("netdev", func() {
		if b, err := os.ReadFile(filepath.Join(procRoot, "net/dev")); err == nil {
			v.devData = string(b)
			v.dev = parseNetDev(v.devData)
		}
		for name, c := range v.dev {
			if p, ok := prev[name]; ok && p != c {
				v.flowing[name] = true
			}
		}
	})
	v.owners = portOwners(controlPortsOf(recs))
	return v
}

func pingOnce(target string) (bool, float64) {
	start := time.Now()
	if _, err := runCmdTimeout(4*time.Second, "ping", "-c", "1", "-W", "2", target); err != nil {
		return false, -1
	}
	return true, float64(time.Since(start).Microseconds()) / 1000
}

func directView(recs []peerRecord) *hostView {
	v := collectHost(recs, nil)
	v.icmp = func(target string) icmpResult {
		ok, d := pingOnce(target)
		return icmpResult{OK: ok, Ms: d, Known: true}
	}
	return v
}

func mainTunnelFrom(st tunnelStatus, v *hostView) *peerLive {
	if !strings.HasPrefix(st.Role, "iran") || !(st.Gre.Exists || st.FrpUp || len(st.Proxies) > 0) {
		return nil
	}
	name := "Tunnel"
	if st.RemotePub != "" {
		name = "Tunnel · " + st.RemotePub
	}
	rec := peerRecord{ID: mainTunnelID, Name: name, RemotePub: st.RemotePub, Engine: st.Engine,
		Transport: st.Transport, FrpPort: st.BindPort, Ports: st.ProxyPorts}
	l := &peerLive{peerRecord: rec, GreUp: st.Gre.Exists, FrpUp: st.FrpUp, GreInner: st.Gre.Inner}
	sig := LinkSignals{ServiceActive: st.FrpUp, GreIfUp: st.Gre.Exists}
	if st.FrpUp {
		r := controlSessionIn(v.sessions, ctrlQuery{ID: mainTunnelID, Port: st.BindPort}, v.owners)
		l.Linked, sig.Session, sig.TCPRTTms = r.Linked, r.Linked, r.RTTms
		if !r.Linked && v.connect != nil {
			if c := v.connect(mainTunnelID); c.OK {
				sig.ConnectRTTms = c.RTTms
			}
		}
	}
	if st.Gre.Inner != "" {
		l.icmpTarget = grePeerInner(st.Gre.Inner)
	}
	sig.TrafficFlowing = v.flowing["gre-tunnel"]
	l.applyHealth(sig, v.icmpFor(l.icmpTarget))
	return l
}

type HubSnapshot struct {
	At      time.Time
	Seq     uint64
	BuildMs float64
	Local   tunnelStatus
	Main    *peerLive
	Peers   []peerLive
	Traffic map[string]any

	DevData string

	LocalSession bool
	LocalRTT     float64
	ActiveConns  any
	PublicIP     string
	FrpSince     string
	NavaLink     map[string]any
}

func (s *HubSnapshot) AgeMs() int64 {
	if s == nil || s.At.IsZero() {
		return -1
	}
	return time.Since(s.At).Milliseconds()
}

func (s *HubSnapshot) All() []peerLive {
	age := s.AgeMs()
	out := make([]peerLive, 0, len(s.Peers)+1)
	if s.Main != nil {
		out = append(out, *s.Main)
	}
	out = append(out, s.Peers...)
	for i := range out {
		out[i].SnapshotAgeMs = age
	}
	return out
}

func (s *HubSnapshot) PeersAged() []peerLive {
	age := s.AgeMs()
	out := append([]peerLive(nil), s.Peers...)
	for i := range out {
		out[i].SnapshotAgeMs = age
	}
	return out
}

var (
	snapPtr      atomic.Pointer[HubSnapshot]
	snapBuilding atomic.Bool
	snapSkipped  atomic.Uint64
	snapTicks    atomic.Uint64
	snapSeq      atomic.Uint64
	snapSyncMu   sync.Mutex
	snapGaveUp   atomic.Int64
	snapDeb      = newHealthDebouncer()
	snapPrevDev  = struct {
		sync.Mutex
		m map[string]devCounters
	}{}
	snapPool  = newWorkPool(min(runtime.NumCPU(), 4))
	snapIcmp  = newIcmpState()
	snapProbe = newProbeState()
	snapSince = struct {
		sync.Mutex
		svc string
		val string
		at  time.Time
	}{}
)

func frpSinceCached(svc string) string {
	if svc == "" {
		return ""
	}
	snapSince.Lock()
	defer snapSince.Unlock()
	if snapSince.svc == svc && time.Since(snapSince.at) < time.Minute {
		return snapSince.val
	}
	val := ""
	if out, err := runCmdTimeoutOut(5*time.Second, "systemctl", "show", svc, "-p", "ActiveEnterTimestamp", "--value"); err == nil {
		if s := strings.TrimSpace(string(out)); s != "" && s != "n/a" {
			val = s
		}
	}
	snapSince.svc, snapSince.val, snapSince.at = svc, val, time.Now()
	return val
}

func buildSnapshot() *HubSnapshot {
	t0 := time.Now()
	recs := loadPeers()
	snapPrevDev.Lock()
	prev := snapPrevDev.m
	snapPrevDev.Unlock()
	v := collectHost(recs, prev)
	snapPrevDev.Lock()
	snapPrevDev.m = v.dev
	snapPrevDev.Unlock()

	local := localStatusFrom(v)
	v.owners = portOwners(controlPortsOf(recs, local.BindPort))
	v.icmp = snapIcmp.lookup
	v.connect = snapProbe.lookup

	s := &HubSnapshot{Local: local, Seq: snapSeq.Add(1)}
	timedStep("peers", func() {
		s.Peers = livePeersFrom(v, recs)
		s.Main = mainTunnelFrom(local, v)
	})

	alive := map[int]bool{}
	debounce := func(l *peerLive) {
		alive[l.ID] = true
		l.HealthState, l.Reasons = snapDeb.observe(l.ID, LinkHealth{State: l.HealthState, Reasons: l.Reasons})
	}
	for i := range s.Peers {
		debounce(&s.Peers[i])
	}
	if s.Main != nil {
		debounce(s.Main)
	}
	snapDeb.prune(alive)

	s.LocalSession, s.LocalRTT = localSessionFrom(local, s.Main, v)

	timedStep("traffic", func() {
		s.Traffic = greTrafficFrom(v.devData)
		s.DevData = v.devData
		s.ActiveConns = activeConns()
	})
	s.PublicIP = detectPublicIPCached()
	s.FrpSince = frpSinceCached(local.FrpSvc)

	snapIcmp.setTargets(icmpTargets(s))
	snapProbe.schedule(time.Now(), probeQueries(s))

	s.At = time.Now()
	s.BuildMs = ms(time.Since(t0))
	recordSampler("snapshot", time.Since(t0))
	s.NavaLink = getSSHFwdSnapshotStatus()
	return s
}

func localSessionFrom(st tunnelStatus, main *peerLive, v *hostView) (bool, float64) {
	if main != nil {
		if main.LatencyKind == "tcp" {
			return main.Linked, main.LatencyMs
		}
		return main.Linked, -1
	}
	if !st.FrpUp || st.BindPort <= 0 || st.RemotePub == "" {
		return false, -1
	}
	remote := normHost(st.RemotePub)
	var found []ssSession
	for _, c := range v.sessions {
		if c.RHost == remote && c.RPort == st.BindPort {
			found = append(found, c)
		}
	}
	return len(found) > 0, minRTT(found)
}

func icmpTargets(s *HubSnapshot) map[string]bool {
	m := map[string]bool{}
	if s.Local.Gre.Inner != "" {
		m[grePeerInner(s.Local.Gre.Inner)] = s.LocalSession
	}
	for _, l := range s.All() {
		if l.icmpTarget != "" {
			m[l.icmpTarget] = m[l.icmpTarget] || (l.FrpUp && l.Linked)
		}
	}
	return m
}

func probeQueries(s *HubSnapshot) []ctrlQuery {
	var qs []ctrlQuery
	for _, l := range s.All() {
		if l.FrpUp && !l.Linked && l.FrpPort > 0 {
			q := ctrlQuery{ID: l.ID, Port: l.FrpPort, RemotePub: l.RemotePub, PeerGre: l.PeerGre}
			if l.ID == mainTunnelID {
				q.PeerGre = l.icmpTarget
			}
			qs = append(qs, q)
		}
	}
	return qs
}

func snapshotTick() bool {
	if !snapBuilding.CompareAndSwap(false, true) {
		snapSkipped.Add(1)
		return false
	}
	defer snapBuilding.Store(false)
	snap := buildSnapshot()
	snapPtr.Store(snap)
	snapTicks.Add(1)
	alertsOnSnapshot(snap)
	historyOnSnapshot(snap)
	usageOnSnapshot(snap)
	carrierAdvisorOnSnapshot(snap)
	return true
}

func currentSnapshot() *HubSnapshot {
	if s := snapPtr.Load(); s != nil {
		return s
	}
	if time.Since(time.Unix(0, snapGaveUp.Load())) < snapshotEvery {
		return &HubSnapshot{}
	}
	snapSyncMu.Lock()
	defer snapSyncMu.Unlock()
	if s := snapPtr.Load(); s != nil {
		return s
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		snapshotTick()
	}()
	select {
	case <-done:
	case <-time.After(snapFirstWait):
	}
	if s := snapPtr.Load(); s != nil {
		return s
	}
	snapGaveUp.Store(time.Now().UnixNano())
	return &HubSnapshot{}
}

func setSnapshotAgeHeader(w http.ResponseWriter, s *HubSnapshot) {
	w.Header().Set("X-Snapshot-Age-Ms", strconv.FormatInt(s.AgeMs(), 10))
}

func currentLocal() tunnelStatus {
	if s := snapPtr.Load(); s != nil {
		return s.Local
	}
	if s := currentSnapshot(); !s.At.IsZero() {
		return s.Local
	}
	return localStatus()
}

func startSnapshotCollector(ctx context.Context) {
	go func() {
		snapshotTick()
		tk := time.NewTicker(snapshotEvery)
		defer tk.Stop()
		for {
			select {
			case <-tk.C:
				snapshotTick()
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() {
		tk := time.NewTicker(snapshotEvery)
		defer tk.Stop()
		for {
			select {
			case now := <-tk.C:
				snapIcmp.pass(now)
			case <-ctx.Done():
				return
			}
		}
	}()
}

type workPool struct {
	sem  chan struct{}
	wg   sync.WaitGroup
	mu   sync.Mutex
	busy map[string]bool
}

func newWorkPool(n int) *workPool {
	return &workPool{sem: make(chan struct{}, max(n, 1)), busy: map[string]bool{}}
}

func (p *workPool) submit(key string, d time.Duration, fn func()) {
	p.mu.Lock()
	if p.busy[key] {
		p.mu.Unlock()
		return
	}
	p.busy[key] = true
	p.mu.Unlock()
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		p.sem <- struct{}{}
		defer func() {
			<-p.sem
			p.mu.Lock()
			delete(p.busy, key)
			p.mu.Unlock()
		}()
		done := make(chan struct{})
		go func() { defer close(done); fn() }()
		select {
		case <-done:
		case <-time.After(d):
		}
	}()
}

func (p *workPool) wait() { p.wg.Wait() }

func jitter(key string, span time.Duration) time.Duration {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	return time.Duration(h.Sum32()) % span
}

type icmpState struct {
	mu      sync.Mutex
	res     map[string]icmpResult
	due     map[string]time.Time
	targets map[string]bool
}

func newIcmpState() *icmpState {
	return &icmpState{res: map[string]icmpResult{}, due: map[string]time.Time{}, targets: map[string]bool{}}
}

func (c *icmpState) lookup(target string) icmpResult {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.res[target]
}

func (c *icmpState) setTargets(m map[string]bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.targets = m
	for k := range c.res {
		if _, ok := m[k]; !ok {
			delete(c.res, k)
			delete(c.due, k)
		}
	}
}

func (c *icmpState) pass(now time.Time) {
	c.mu.Lock()
	var due []string
	for addr, sess := range c.targets {
		if sess {
			continue
		}
		d, ok := c.due[addr]
		if !ok {
			d = now.Add(jitter(addr, icmpFirstJitter))
			c.due[addr] = d
		}
		if !now.Before(d) {
			c.due[addr] = now.Add(icmpEvery + jitter(addr, icmpRepeatJitter))
			due = append(due, addr)
		}
	}
	c.mu.Unlock()
	for _, addr := range due {
		addr := addr
		snapPool.submit("icmp:"+addr, snapTaskTimeout, func() {
			ok, d := pingOnce(addr)
			c.mu.Lock()
			c.res[addr] = icmpResult{OK: ok, Ms: d, Known: true}
			c.mu.Unlock()
		})
	}
}

type probeEntry struct {
	r  connectResult
	at time.Time
}

type probeState struct {
	mu  sync.Mutex
	res map[int]probeEntry
}

func newProbeState() *probeState { return &probeState{res: map[int]probeEntry{}} }

func (c *probeState) lookup(id int) connectResult {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.res[id].r
}

func (c *probeState) schedule(now time.Time, qs []ctrlQuery) {
	keep := map[int]bool{}
	for _, q := range qs {
		keep[q.ID] = true
	}
	c.mu.Lock()
	for id := range c.res {
		if !keep[id] {
			delete(c.res, id)
		}
	}
	var stale []ctrlQuery
	for _, q := range qs {
		e, ok := c.res[q.ID]
		ttl := probeFailTTL
		if e.r.OK {
			ttl = probeOKTTL
		}
		if !ok || now.Sub(e.at) >= ttl {
			stale = append(stale, q)
		}
	}
	c.mu.Unlock()
	for _, q := range stale {
		q := q
		snapPool.submit("probe:"+strconv.Itoa(q.ID), snapTaskTimeout, func() {
			r := connectProbe(q)
			c.mu.Lock()
			c.res[q.ID] = probeEntry{r, time.Now()}
			c.mu.Unlock()
		})
	}
}

type snapStatsJSON struct {
	Ready        bool    `json:"ready"`
	At           string  `json:"at,omitempty"`
	AgeMs        int64   `json:"age_ms"`
	BuildMs      float64 `json:"last_build_ms"`
	Ticks        uint64  `json:"ticks"`
	SkippedTicks uint64  `json:"skipped_ticks"`
	Building     bool    `json:"building"`
}

func snapshotStats() snapStatsJSON {
	st := snapStatsJSON{AgeMs: -1, Ticks: snapTicks.Load(), SkippedTicks: snapSkipped.Load(), Building: snapBuilding.Load()}
	if s := snapPtr.Load(); s != nil {
		st.Ready, st.At, st.AgeMs, st.BuildMs = true, s.At.UTC().Format(time.RFC3339), s.AgeMs(), s.BuildMs
	}
	return st
}

func resetSnapshotState() {
	snapPool.wait()
	snapPtr.Store(nil)
	snapGaveUp.Store(0)
	snapDeb = newHealthDebouncer()
	snapIcmp = newIcmpState()
	snapProbe = newProbeState()
	snapPrevDev.Lock()
	snapPrevDev.m = nil
	snapPrevDev.Unlock()
	snapSince.Lock()
	snapSince.svc, snapSince.val = "", ""
	snapSince.Unlock()
	lastRemote.Lock()
	lastRemote.m = map[int]string{}
	lastRemote.Unlock()
	snapTicks.Store(0)
	snapSkipped.Store(0)
}
