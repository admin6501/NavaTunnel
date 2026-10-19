// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type ssSession struct {
	LPort int
	RHost string
	RPort int
	RTTms float64
}

func parseSS(out string) []ssSession {
	var res []ssSession
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if len(res) == 0 {
				continue
			}
			if i := strings.Index(line, " rtt:"); i >= 0 {
				v := line[i+5:]
				if j := strings.IndexAny(v, "/ "); j >= 0 {
					v = v[:j]
				}
				if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 && res[len(res)-1].RTTms < 0 {
					res[len(res)-1].RTTms = f
				}
			}
			continue
		}
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		_, lp, e1 := net.SplitHostPort(f[2])
		rh, rp, e2 := net.SplitHostPort(f[3])
		if e1 != nil || e2 != nil {
			continue
		}
		p, err := strconv.Atoi(lp)
		if err != nil {
			continue
		}
		rport, _ := strconv.Atoi(rp)
		res = append(res, ssSession{LPort: p, RHost: normHost(rh), RPort: rport, RTTms: -1})
	}
	return res
}

func sessionsOn(all []ssSession, ports []int, remotes ...string) []ssSession {
	want := map[string]bool{}
	for _, r := range remotes {
		if r = strings.TrimSpace(r); r != "" {
			want[r] = true
		}
	}
	var res []ssSession
	for _, s := range all {
		hit := false
		for _, p := range ports {
			if p > 0 && s.LPort == p {
				hit = true
				break
			}
		}
		if hit && (len(want) == 0 || want[s.RHost]) {
			res = append(res, s)
		}
	}
	return res
}

func ssEstablished() string {
	out, err := runCmdTimeoutOut(5*time.Second, "ss", "-Htin", "state", "established")
	if err != nil {
		return ""
	}
	return string(out)
}

func minRTT(ss []ssSession) float64 {
	best := -1.0
	for _, s := range ss {
		if s.RTTms >= 0 && (best < 0 || s.RTTms < best) {
			best = s.RTTms
		}
	}
	return best
}

func normHost(h string) string {
	h = strings.TrimSpace(strings.Trim(h, "[]"))
	if i := strings.IndexByte(h, '%'); i >= 0 {
		h = h[:i]
	}
	if ip := net.ParseIP(h); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			return v4.String()
		}
		return ip.String()
	}
	return h
}

func controlPorts(port int) []int {
	if port <= 0 {
		return nil
	}
	return []int{port, port + 2, port - 2}
}

func portOwners(ports []int) map[int]int {
	m := map[int]int{}
	for _, p := range ports {
		for _, q := range controlPorts(p) {
			m[q]++
		}
	}
	return m
}

type ctrlQuery struct {
	ID        int
	Port      int
	RemotePub string
	PeerGre   string
	Extra     []string
}

type ctrlResult struct {
	Linked bool
	RTTms  float64
	Remote string
}

var lastRemote = struct {
	sync.Mutex
	m map[int]string
}{m: map[int]string{}}

func cachedRemote(id int) string {
	lastRemote.Lock()
	defer lastRemote.Unlock()
	return lastRemote.m[id]
}

func rememberRemote(id int, host string) {
	lastRemote.Lock()
	lastRemote.m[id] = host
	lastRemote.Unlock()
}

func controlSessionIn(all []ssSession, q ctrlQuery, owners map[int]int) ctrlResult {
	none := ctrlResult{RTTms: -1}
	cands := sessionsOn(all, controlPorts(q.Port))
	if len(cands) == 0 {
		return none
	}
	known := map[string]bool{}
	for _, r := range append([]string{q.RemotePub, q.PeerGre, cachedRemote(q.ID)}, q.Extra...) {
		if r = normHost(r); r != "" {
			known[r] = true
		}
	}
	var hit []ssSession
	for _, s := range cands {
		if known[s.RHost] {
			hit = append(hit, s)
		}
	}
	if len(hit) == 0 {
		for _, s := range cands {
			if owners == nil || owners[s.LPort] <= 1 {
				hit = append(hit, s)
			}
		}
	}
	if len(hit) == 0 {
		return none
	}
	best := hit[0]
	for _, s := range hit[1:] {
		if s.RTTms >= 0 && (best.RTTms < 0 || s.RTTms < best.RTTms) {
			best = s
		}
	}
	if q.ID >= 0 {
		rememberRemote(q.ID, best.RHost)
	}
	return ctrlResult{Linked: true, RTTms: minRTT(hit), Remote: best.RHost}
}

func linkedFromSS(out string, ports []int, remotes ...string) bool {
	return len(sessionsOn(parseSS(out), ports, remotes...)) > 0
}

var dialFn = func(network, addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout(network, addr, timeout)
}

const connectProbeTimeout = 1500 * time.Millisecond

type connectResult struct {
	OK    bool
	RTTms float64
	Addr  string
}

func connectProbe(q ctrlQuery) connectResult {
	for _, host := range []string{q.PeerGre, q.RemotePub} {
		if host == "" || q.Port <= 0 {
			continue
		}
		addr := net.JoinHostPort(host, strconv.Itoa(q.Port))
		start := time.Now()
		c, err := dialFn("tcp", addr, connectProbeTimeout)
		rtt := max(float64(time.Since(start).Nanoseconds())/1e6, 0.001)
		if err == nil {
			_ = c.Close()
		} else if !errors.Is(err, syscall.ECONNREFUSED) {
			continue
		}
		return connectResult{OK: true, RTTms: rtt, Addr: addr}
	}
	return connectResult{RTTms: -1}
}
