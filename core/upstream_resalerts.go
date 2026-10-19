// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"fmt"
	"strconv"
	"time"
)

const resHysteresis = 3.0

type resThreshold struct{ warn, crit float64 }

var (
	diskThreshold = resThreshold{85, 92}
	ramThreshold  = resThreshold{90, 96}
)

func resourceState(prev string, pct float64, t resThreshold) string {
	crit, warn := t.crit, t.warn
	switch prev {
	case stateDown:
		crit -= resHysteresis
		warn -= resHysteresis
	case stateDegraded:
		warn -= resHysteresis
	}
	switch {
	case pct >= crit:
		return stateDown
	case pct >= warn:
		return stateDegraded
	}
	return stateHealthy
}

const (
	certCritDays = 7
	certWarnDays = 21
)

func certState(now, expiry time.Time) (string, string) {
	left := expiry.Sub(now)
	days := int(left.Hours() / 24)
	switch {
	case left <= 0:
		return stateDown, "peer API TLS certificate has EXPIRED"
	case days < certCritDays:
		return stateDown, fmt.Sprintf("peer API TLS certificate expires in %d day(s)", days)
	case days < certWarnDays:
		return stateDegraded, fmt.Sprintf("peer API TLS certificate expires in %d days", days)
	}
	return stateHealthy, ""
}

type hostReaders struct {
	diskPct func() (float64, bool)
	ramPct  func() (float64, bool)
	cert    func() (time.Time, bool)
}

func liveHostReaders() hostReaders {
	return hostReaders{
		diskPct: func() (float64, bool) {
			total, free, err := getDiskUsage("/")
			if err != nil || total == 0 {
				return 0, false
			}
			return float64(total-free) * 100 / float64(total), true
		},
		ramPct: func() (float64, bool) {
			m := memInfo()
			s, ok := m["pct"].(string)
			if !ok {
				return 0, false
			}
			v, err := strconv.ParseFloat(s, 64)
			return v, err == nil
		},
		cert: func() (time.Time, bool) {
			if !tlsHasCert() {
				return time.Time{}, false
			}
			exp, _, err := tlsCertExpiry()
			return exp, err == nil
		},
	}
}

func hostResourceLinks(now time.Time, r hostReaders, last func(name string) string) []linkSnap {
	var out []linkSnap
	if r.diskPct != nil {
		if v, ok := r.diskPct(); ok {
			st := resourceState(last("host:disk"), v, diskThreshold)
			out = append(out, linkSnap{Name: "host:disk", State: st, Why: fmt.Sprintf("disk / is %.0f%% full", v)})
		}
	}
	if r.ramPct != nil {
		if v, ok := r.ramPct(); ok {
			st := resourceState(last("host:ram"), v, ramThreshold)
			out = append(out, linkSnap{Name: "host:ram", State: st, Why: fmt.Sprintf("memory is %.0f%% used", v)})
		}
	}
	if r.cert != nil {
		if exp, ok := r.cert(); ok {
			st, why := certState(now, exp)
			out = append(out, linkSnap{Name: "host:tls-cert", State: st, Why: why})
		}
	}
	return out
}

func (t *alertTracker) lastState(name string) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.last[name]
}
