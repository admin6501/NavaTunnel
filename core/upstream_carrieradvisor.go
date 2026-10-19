// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	advMinSamples = 20
	advBadRatio   = 0.80
	advMaxSamples = 2880
)

type carrierStat struct {
	Up, Degraded, Down int
	LastSeen           int64
}

func (c carrierStat) total() int { return c.Up + c.Degraded + c.Down }

func (c carrierStat) ratio() float64 {
	if c.total() == 0 {
		return 0
	}
	return float64(c.Up+c.Degraded) / float64(c.total())
}

type carrierAdvice struct {
	Level   string `json:"level"`
	Message string `json:"message"`
	Suggest string `json:"suggest,omitempty"`
}

type carrierAdvisor struct {
	mu    sync.Mutex
	stats map[string]*carrierStat
	last  time.Time
}

var advisor = &carrierAdvisor{stats: map[string]*carrierStat{}}

func (a *carrierAdvisor) record(now time.Time, carrier, state string) {
	if carrier == "" || state == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.last.IsZero() && now.Sub(a.last) < histEvery {
		return
	}
	a.last = now
	s := a.stats[carrier]
	if s == nil {
		s = &carrierStat{}
		a.stats[carrier] = s
	}
	switch state {
	case stateHealthy:
		s.Up++
	case stateDegraded:
		s.Degraded++
	default:
		s.Down++
	}
	if s.total() > advMaxSamples {
		s.Up, s.Degraded, s.Down = s.Up/2, s.Degraded/2, s.Down/2
	}
	s.LastSeen = now.Unix()
}

func (a *carrierAdvisor) snapshot() map[string]carrierStat {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make(map[string]carrierStat, len(a.stats))
	for k, v := range a.stats {
		out[k] = *v
	}
	return out
}

func adviseCarrier(active string, candidates []string, stats map[string]carrierStat) []carrierAdvice {
	cur := stats[active]
	if cur.total() < advMinSamples {
		return []carrierAdvice{{Level: "info", Message: fmt.Sprintf("Collecting data for carrier %q (%d/%d samples).", active, cur.total(), advMinSamples)}}
	}
	if cur.ratio() >= advBadRatio {
		return []carrierAdvice{{Level: "ok", Message: fmt.Sprintf("Carrier %q is stable (%.0f%% of samples up).", active, cur.ratio()*100)}}
	}
	msg := fmt.Sprintf("Carrier %q was down in %.0f%% of recent samples.", active, (1-cur.ratio())*100)
	type alt struct {
		name  string
		ratio float64
		seen  bool
	}
	var alts []alt
	for _, c := range candidates {
		if c == active {
			continue
		}
		st, ok := stats[c]
		if ok && st.total() >= advMinSamples {
			alts = append(alts, alt{c, st.ratio(), true})
		} else {
			alts = append(alts, alt{c, 0, false})
		}
	}
	sort.SliceStable(alts, func(i, j int) bool {
		if alts[i].seen != alts[j].seen {
			return alts[i].seen
		}
		return alts[i].ratio > alts[j].ratio
	})
	for _, a := range alts {
		if a.seen && a.ratio > cur.ratio() {
			return []carrierAdvice{{Level: "warn", Message: msg + fmt.Sprintf(" %q did better before (%.0f%% up).", a.name, a.ratio*100), Suggest: a.name}}
		}
	}
	for _, a := range alts {
		if !a.seen {
			return []carrierAdvice{{Level: "warn", Message: msg + fmt.Sprintf(" %q has not been tried yet.", a.name), Suggest: a.name}}
		}
	}
	return []carrierAdvice{{Level: "warn", Message: msg + " No better carrier is known; check the path (see Reverse Path / Tunnel health)."}}
}

func carrierAdvisorOnSnapshot(s *HubSnapshot) {
	state := ""
	switch {
	case s.Main != nil:
		state = s.Main.HealthState
	case len(s.Peers) > 0:
		state = s.Peers[0].HealthState
	}
	if state == "" {
		return
	}
	advisor.record(time.Now(), loadCarrierConfig().ActiveCarrier, state)
}

func handleCarrierAdvice(w http.ResponseWriter, r *http.Request) {
	c := loadCarrierConfig()
	stats := advisor.snapshot()
	type row struct {
		Carrier string  `json:"carrier"`
		Samples int     `json:"samples"`
		UpPct   float64 `json:"up_pct"`
	}
	var rows []row
	for k, v := range stats {
		rows = append(rows, row{k, v.total(), float64(int(v.ratio()*1000)) / 10})
	}
	sort.Slice(rows, func(i, j int) bool { return strings.Compare(rows[i].Carrier, rows[j].Carrier) < 0 })
	writeJSON(w, map[string]any{
		"active": c.ActiveCarrier, "advice": adviseCarrier(c.ActiveCarrier, c.Candidates, stats),
		"stats": rows, "auto_switch": false,
	})
}
