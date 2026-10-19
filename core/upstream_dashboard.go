// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"bufio"
	"encoding/json"

	"fmt"

	"os"
	"path/filepath"

	"strconv"
	"strings"
	"sync"
	"time"
)

var panelStartedAt = time.Now()

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func peerOr(st tunnelStatus) string {
	if st.Gre.PeerIP != "" {
		return st.Gre.PeerIP
	}
	return st.GrePeer
}

var (
	trafficStateMu   sync.Mutex
	lastRawUp        uint64
	lastRawDown      uint64
	lastRawIf        map[string][2]uint64
	lifetimeUp       uint64
	lifetimeDown     uint64
	trafficStateInit bool
	lastSampleTime   time.Time
	lastStateSave    time.Time
	speedDeltaUp     uint64
	speedDeltaDown   uint64
	currentSpeedUp   float64
	currentSpeedDown float64
)

type persistentTrafficState struct {
	LifetimeUp    uint64 `json:"lifetime_up"`
	LifetimeDown  uint64 `json:"lifetime_down"`
	LifetimeTotal uint64 `json:"lifetime_total"`
	LastRawUp     uint64 `json:"last_raw_up"`
	LastRawDown   uint64 `json:"last_raw_down"`
	SavedAt       int64  `json:"saved_at"`
}

func trafficStateFile() string { return filepath.Join(configDir, "traffic_state.json") }

func loadTrafficStateLocked() {
	if trafficStateInit {
		return
	}
	trafficStateInit = true

	if data, err := os.ReadFile(trafficStateFile()); err == nil {
		var st persistentTrafficState
		if json.Unmarshal(data, &st) == nil && (st.LifetimeUp > 0 || st.LifetimeDown > 0) {
			lifetimeUp = st.LifetimeUp
			lifetimeDown = st.LifetimeDown
			lastRawUp = st.LastRawUp
			lastRawDown = st.LastRawDown
			return
		}
	}

	hist := loadHistory()
	for i := len(hist) - 1; i >= 0; i-- {
		if hist[i].Up != nil && hist[i].Down != nil {
			lifetimeUp = *hist[i].Up
			lifetimeDown = *hist[i].Down
			break
		}
	}
}

func saveTrafficStateLocked() {
	_ = os.MkdirAll(configDir, 0700)
	st := persistentTrafficState{
		LifetimeUp:    lifetimeUp,
		LifetimeDown:  lifetimeDown,
		LifetimeTotal: lifetimeUp + lifetimeDown,
		LastRawUp:     lastRawUp,
		LastRawDown:   lastRawDown,
		SavedAt:       time.Now().Unix(),
	}
	b := mustJSON(st)
	tmp := trafficStateFile() + ".tmp"
	if err := os.WriteFile(tmp, b, 0600); err == nil {
		_ = os.Rename(tmp, trafficStateFile())
	}
	lastStateSave = time.Now()
}

var (
	peerIfsMu       sync.RWMutex
	peerIfsCache    map[string]bool
	peerIfsCacheExp time.Time
)

func getKnownPeerIfs() map[string]bool {
	peerIfsMu.RLock()
	if peerIfsCache != nil && time.Now().Before(peerIfsCacheExp) {
		res := peerIfsCache
		peerIfsMu.RUnlock()
		return res
	}
	peerIfsMu.RUnlock()

	peerIfsMu.Lock()
	defer peerIfsMu.Unlock()
	if peerIfsCache != nil && time.Now().Before(peerIfsCacheExp) {
		return peerIfsCache
	}
	m := make(map[string]bool)
	for _, q := range loadPeers() {
		if q.GreIf != "" {
			m[q.GreIf] = true
		}
	}
	peerIfsCache = m
	peerIfsCacheExp = time.Now().Add(10 * time.Second)
	return m
}

func isTunnelInterface(ifname string) bool {
	if ifname == "lo" || ifname == "gre0" || ifname == "gretap0" || ifname == "erspan0" {
		return false
	}
	if strings.HasPrefix(ifname, "docker") || strings.HasPrefix(ifname, "veth") ||
		strings.HasPrefix(ifname, "br-") || strings.HasPrefix(ifname, "dummy") ||
		strings.HasPrefix(ifname, "eth") || strings.HasPrefix(ifname, "ens") ||
		strings.HasPrefix(ifname, "enp") || strings.HasPrefix(ifname, "wl") {
		return false
	}
	if strings.HasPrefix(ifname, "gre-") || strings.HasPrefix(ifname, "tun") {
		return true
	}
	known := getKnownPeerIfs()
	if known[ifname] {
		return true
	}
	if data, err := os.ReadFile(filepath.Join("/sys/class/net", ifname, "type")); err == nil {
		t := strings.TrimSpace(string(data))
		if t == "778" || t == "823" {
			return true
		}
	}
	return false
}

func primaryInterface() string {
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[1] == "00000000" && fields[0] != "lo" {
			return fields[0]
		}
	}
	return ""
}

func greTrafficFrom(devData string) map[string]any {

	cur := map[string][2]uint64{}
	parse := func(line, ifname string) ([2]uint64, bool) {
		f := strings.Fields(strings.TrimPrefix(line, ifname+":"))
		if len(f) < 9 {
			return [2]uint64{}, false
		}
		var r, t uint64
		_, _ = fmt.Sscanf(f[0], "%d", &r)
		_, _ = fmt.Sscanf(f[8], "%d", &t)
		return [2]uint64{r, t}, true
	}

	if devData != "" {
		for _, line := range strings.Split(devData, "\n") {
			line = strings.TrimSpace(line)
			if !strings.Contains(line, ":") {
				continue
			}
			ifname := strings.TrimSpace(strings.Split(line, ":")[0])
			if !isTunnelInterface(ifname) {
				continue
			}
			if c, ok := parse(line, ifname); ok {
				cur[ifname] = c
			}
		}
	}

	if len(cur) == 0 && devData != "" {
		primIf := primaryInterface()
		for _, line := range strings.Split(devData, "\n") {
			line = strings.TrimSpace(line)
			if !strings.Contains(line, ":") {
				continue
			}
			ifname := strings.TrimSpace(strings.Split(line, ":")[0])
			if primIf != "" && strings.Contains(devData, primIf+":") {
				if ifname != primIf {
					continue
				}
			} else {
				if ifname == "lo" || strings.HasPrefix(ifname, "docker") || strings.HasPrefix(ifname, "veth") || strings.HasPrefix(ifname, "br-") {
					continue
				}
			}
			if c, ok := parse(line, ifname); ok && (c[0] > 0 || c[1] > 0) {
				cur[ifname] = c
				break
			}
		}
	}

	trafficStateMu.Lock()
	defer trafficStateMu.Unlock()

	now := time.Now()

	first := !trafficStateInit
	if first {
		loadTrafficStateLocked()
		lastSampleTime = now
	}

	var dU, dD, rawUp, rawDown uint64
	for name, c := range cur {
		rawDown += c[0]
		rawUp += c[1]
		prev, seen := lastRawIf[name]
		if first || !seen {
			continue
		}
		if c[0] >= prev[0] {
			dD += c[0] - prev[0]
		} else {
			dD += c[0]
		}
		if c[1] >= prev[1] {
			dU += c[1] - prev[1]
		} else {
			dU += c[1]
		}
	}
	lastRawIf = cur

	lifetimeUp += dU
	lifetimeDown += dD
	lastRawUp = rawUp
	lastRawDown = rawDown

	if (dU > 0 || dD > 0) && time.Since(lastStateSave) >= 5*time.Second {
		saveTrafficStateLocked()
	}

	speedDeltaUp += dU
	speedDeltaDown += dD

	dt := now.Sub(lastSampleTime).Seconds()
	if dt >= 1.0 {
		currentSpeedUp = float64(speedDeltaUp) / dt
		currentSpeedDown = float64(speedDeltaDown) / dt
		speedDeltaUp = 0
		speedDeltaDown = 0
		lastSampleTime = now
	}

	return map[string]any{
		"up":         lifetimeUp,
		"down":       lifetimeDown,
		"total":      lifetimeUp + lifetimeDown,
		"speed_up":   currentSpeedUp,
		"speed_down": currentSpeedDown,
	}
}

func memInfo() map[string]any {
	out := map[string]any{"used": nil, "total": nil, "pct": nil, "cache": nil}
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return out
	}
	var total, avail, cached, buffers, sreclaim uint64
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		v, err := strconv.ParseUint(f[1], 10, 64)
		if err != nil {
			continue
		}
		switch f[0] {
		case "MemTotal:":
			total = v * 1024
		case "MemAvailable:":
			avail = v * 1024
		case "Cached:":
			cached = v * 1024
		case "Buffers:":
			buffers = v * 1024
		case "SReclaimable:":
			sreclaim = v * 1024
		}
	}
	if total == 0 {
		return out
	}
	cache := cached + buffers + sreclaim
	used := total - avail
	out["used"] = used
	out["total"] = total
	out["pct"] = fmt.Sprintf("%.1f", float64(used)*100/float64(total))
	out["cache"] = cache
	return out
}

func diskPct(path string) any {
	total, free, err := getDiskUsage(path)
	if err != nil || total == 0 {
		return nil
	}
	used := total - free
	return fmt.Sprintf("%.1f", float64(used)*100/float64(total))
}

func activeConns() any {
	n := 0
	have := false
	for _, f := range []string{"net/tcp", "net/tcp6", "net/udp", "net/udp6"} {
		c, ok := countEstablished(filepath.Join(procRoot, f))
		if ok {
			have = true
			n += c
		}
	}
	if !have {
		return nil
	}
	return n
}

func countEstablished(path string) (int, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 64*1024)
	n := 0
	for first := true; sc.Scan(); {
		if first {
			first = false
			continue
		}
		fields := strings.Fields(sc.Text())
		if len(fields) > 3 && fields[3] == "01" {
			n++
		}
	}
	return n, true
}

type trafficPoint struct {
	T     int64   `json:"t"`
	Up    *uint64 `json:"up"`
	Down  *uint64 `json:"down"`
	Total *uint64 `json:"total"`
	Conns *int    `json:"conns"`
}

var (
	histMu        sync.Mutex
	histCached    []trafficPoint
	histLoaded    bool
	histDirty     bool
	lastFlushTime time.Time
	recorderOnce  sync.Once
)

func historyFile() string { return filepath.Join(configDir, "traffic.json") }

func loadHistory() []trafficPoint {
	if histLoaded {
		return histCached
	}
	histLoaded = true
	data, err := os.ReadFile(historyFile())
	if err == nil {
		var raw []trafficPoint
		if json.Unmarshal(data, &raw) == nil {
			var lastUp, lastDown uint64
			cleaned := make([]trafficPoint, 0, len(raw))
			for _, p := range raw {
				if p.Up == nil {
					u := lastUp
					p.Up = &u
				} else {
					lastUp = *p.Up
				}
				if p.Down == nil {
					d := lastDown
					p.Down = &d
				} else {
					lastDown = *p.Down
				}
				if p.Total == nil {
					tot := lastUp + lastDown
					p.Total = &tot
				}
				cleaned = append(cleaned, p)
			}
			histCached = cleaned
		}
	}
	if histCached == nil {
		histCached = []trafficPoint{}
	}
	return histCached
}
