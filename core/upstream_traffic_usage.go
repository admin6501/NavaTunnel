// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	usageStep      = time.Minute
	usageKeep      = 7 * 24 * time.Hour
	usageSaveEvery = 60 * time.Second
	usageMaxLinks  = 64
	usageFileVer   = 1
	usageTotalKey  = "total"
	usageMainKey   = "main"
	usageHostKey   = "host"
	usageDayLayout = "2006-01-02"
)

func usageFile() string { return filepath.Join(configDir, "traffic_peers.json") }

type usagePoint struct {
	T  int64  `json:"t"`
	Rx uint64 `json:"rx"`
	Tx uint64 `json:"tx"`
}

type usageLink struct {
	Name   string       `json:"name"`
	Points []usagePoint `json:"points"`

	Days map[string]usageDay `json:"days"`

	LastRx uint64 `json:"last_rx"`
	LastTx uint64 `json:"last_tx"`
	Have   bool   `json:"have"`
	Seen   int64  `json:"seen"`
}

type usageDay struct {
	Rx uint64 `json:"rx"`
	Tx uint64 `json:"tx"`
}

type usageDisk struct {
	Version int                   `json:"v"`
	SavedAt int64                 `json:"saved_at"`
	Links   map[string]*usageLink `json:"links"`
}

type usageStore struct {
	mu    sync.Mutex
	links map[string]*usageLink
	dirty bool
}

var trafficUsage = &usageStore{links: map[string]*usageLink{}}

func usageKey(l peerLive) string {
	if l.ID == mainTunnelID {
		return usageMainKey
	}
	return "p" + strconv.Itoa(l.ID)
}

func minuteOf(t time.Time) int64 { return t.Unix() / 60 * 60 }

func dayOf(unix int64) string { return time.Unix(unix, 0).UTC().Format(usageDayLayout) }

func usageDelta(prev, cur uint64, have bool) uint64 {
	if !have {
		return 0
	}
	if cur >= prev {
		return cur - prev
	}
	return cur
}

func (s *usageStore) observe(key, name string, now time.Time, rx, tx *uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.links[key]
	if l == nil {
		if len(s.links) >= usageMaxLinks {
			return
		}
		l = &usageLink{Days: map[string]usageDay{}}
		s.links[key] = l
	}
	if name != "" {
		l.Name = name
	}
	if rx == nil || tx == nil {
		return
	}
	dRx := usageDelta(l.LastRx, *rx, l.Have)
	dTx := usageDelta(l.LastTx, *tx, l.Have)
	l.LastRx, l.LastTx, l.Have = *rx, *tx, true
	l.Seen = now.Unix()
	if dRx == 0 && dTx == 0 {

		return
	}
	m := minuteOf(now)
	if n := len(l.Points); n > 0 && l.Points[n-1].T == m {
		l.Points[n-1].Rx += dRx
		l.Points[n-1].Tx += dTx
	} else {
		l.Points = append(l.Points, usagePoint{T: m, Rx: dRx, Tx: dTx})
	}
	d := dayOf(now.Unix())
	day := l.Days[d]
	day.Rx += dRx
	day.Tx += dTx
	l.Days[d] = day
	s.dirty = true
}

func (s *usageStore) prune(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cut := now.Add(-usageKeep).Unix()
	cutDay := dayOf(cut)
	for k, l := range s.links {
		i := 0
		for i < len(l.Points) && l.Points[i].T < cut {
			i++
		}
		if i > 0 {
			l.Points = append([]usagePoint(nil), l.Points[i:]...)
			s.dirty = true
		}
		for d := range l.Days {
			if d < cutDay {
				delete(l.Days, d)
				s.dirty = true
			}
		}
		if len(l.Points) == 0 && len(l.Days) == 0 && l.Seen < cut {
			delete(s.links, k)
			s.dirty = true
		}
	}
}

func (s *usageStore) save(path string, now time.Time) error {
	s.prune(now)
	s.mu.Lock()
	d := usageDisk{Version: usageFileVer, SavedAt: now.Unix(), Links: s.links}
	b, err := json.Marshal(d)
	s.dirty = false
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *usageStore) load(path string, now time.Time) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	var d usageDisk
	if json.Unmarshal(b, &d) != nil || d.Version != usageFileVer {

		_ = os.Rename(path, path+".bad")
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for k, l := range d.Links {
		if l == nil || s.links[k] != nil {
			continue
		}
		if l.Days == nil {
			l.Days = map[string]usageDay{}
		}
		sort.Slice(l.Points, func(i, j int) bool { return l.Points[i].T < l.Points[j].T })
		s.links[k] = l
		n++
	}
	return n
}

type usageSeries struct {
	Key    string        `json:"key"`
	Name   string        `json:"name"`
	Rx     uint64        `json:"rx"`
	Tx     uint64        `json:"tx"`
	Points []usagePoint  `json:"points"`
	Days   []usageDayRow `json:"days"`
}

type usageDayRow struct {
	Day string `json:"day"`
	Rx  uint64 `json:"rx"`
	Tx  uint64 `json:"tx"`
}

func usageRange(r string) (time.Duration, int64) {
	switch r {
	case "1h":
		return time.Hour, 60
	case "6h":
		return 6 * time.Hour, 300
	case "24h":
		return 24 * time.Hour, 900
	default:
		return usageKeep, 3600
	}
}

func bucketize(pts []usagePoint, since, step int64) []usagePoint {
	var out []usagePoint
	for _, p := range pts {
		if p.T < since {
			continue
		}
		b := p.T / step * step
		if n := len(out); n > 0 && out[n-1].T == b {
			out[n-1].Rx += p.Rx
			out[n-1].Tx += p.Tx
		} else {
			out = append(out, usagePoint{T: b, Rx: p.Rx, Tx: p.Tx})
		}
	}
	return out
}

func (s *usageStore) series(key string, now time.Time, window time.Duration, step int64) (usageSeries, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.seriesLocked(key, now, window, step)
}

func (s *usageStore) seriesLocked(key string, now time.Time, window time.Duration, step int64) (usageSeries, bool) {
	l := s.links[key]
	if l == nil {
		return usageSeries{}, false
	}
	since := now.Add(-window).Unix()
	pts := bucketize(l.Points, since, step)
	out := usageSeries{Key: key, Name: l.Name, Points: pts}
	if out.Points == nil {
		out.Points = []usagePoint{}
	}
	for _, p := range pts {
		out.Rx += p.Rx
		out.Tx += p.Tx
	}
	cutDay := dayOf(since)
	days := make([]string, 0, len(l.Days))
	for d := range l.Days {
		if d >= cutDay {
			days = append(days, d)
		}
	}
	sort.Strings(days)
	out.Days = []usageDayRow{}
	for _, d := range days {
		out.Days = append(out.Days, usageDayRow{Day: d, Rx: l.Days[d].Rx, Tx: l.Days[d].Tx})
	}
	return out, true
}

func (s *usageStore) all(now time.Time, window time.Duration, step int64) []usageSeries {
	s.mu.Lock()
	defer s.mu.Unlock()
	keys := make([]string, 0, len(s.links))
	for k := range s.links {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {

		rank := func(k string) int {
			switch k {
			case usageHostKey:
				return 0
			case usageMainKey:
				return 1
			}
			return 2
		}
		if ri, rj := rank(keys[i]), rank(keys[j]); ri != rj {
			return ri < rj
		}
		a, _ := strconv.Atoi(strings.TrimPrefix(keys[i], "p"))
		b, _ := strconv.Atoi(strings.TrimPrefix(keys[j], "p"))
		return a < b
	})
	var out []usageSeries
	tot := usageSeries{Key: usageTotalKey, Name: "All links", Points: []usagePoint{}, Days: []usageDayRow{}}
	byMin := map[int64]*usagePoint{}
	byDay := map[string]*usageDayRow{}

	haveLinks := false
	for _, k := range keys {
		if k != usageHostKey {
			haveLinks = true
		}
	}
	for _, k := range keys {
		sr, ok := s.seriesLocked(k, now, window, step)
		if !ok {
			continue
		}
		out = append(out, sr)
		if k == usageHostKey && haveLinks {
			continue
		}
		tot.Rx += sr.Rx
		tot.Tx += sr.Tx
		for _, p := range sr.Points {
			if t := byMin[p.T]; t != nil {
				t.Rx += p.Rx
				t.Tx += p.Tx
			} else {
				c := p
				byMin[p.T] = &c
			}
		}
		for _, d := range sr.Days {
			if t := byDay[d.Day]; t != nil {
				t.Rx += d.Rx
				t.Tx += d.Tx
			} else {
				c := d
				byDay[d.Day] = &c
			}
		}
	}
	ts := make([]int64, 0, len(byMin))
	for t := range byMin {
		ts = append(ts, t)
	}
	sort.Slice(ts, func(i, j int) bool { return ts[i] < ts[j] })
	for _, t := range ts {
		tot.Points = append(tot.Points, *byMin[t])
	}
	ds := make([]string, 0, len(byDay))
	for d := range byDay {
		ds = append(ds, d)
	}
	sort.Strings(ds)
	for _, d := range ds {
		tot.Days = append(tot.Days, *byDay[d])
	}
	return append([]usageSeries{tot}, out...)
}

func usageOnSnapshot(s *HubSnapshot) {
	now := time.Now()
	for _, l := range s.All() {
		trafficUsage.observe(usageKey(l), linkName(l), now, l.Rx, l.Tx)
	}
	rx, tx := tunnelRawTotals(s.DevData)
	trafficUsage.observe(usageHostKey, "This server (all tunnels)", now, rx, tx)
}

func tunnelRawTotals(dev string) (rx, tx *uint64) {
	var r, t uint64
	var have bool
	for _, line := range strings.Split(dev, "\n") {
		line = strings.TrimSpace(line)
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		ifname := strings.TrimSpace(line[:i])
		if !isTunnelInterface(ifname) {
			continue
		}
		f := strings.Fields(line[i+1:])
		if len(f) < 9 {
			continue
		}
		a, e1 := strconv.ParseUint(f[0], 10, 64)
		b, e2 := strconv.ParseUint(f[8], 10, 64)
		if e1 != nil || e2 != nil {
			continue
		}
		r += a
		t += b
		have = true
	}
	if !have {
		return nil, nil
	}
	return &r, &t
}

func startUsagePersistence(stop <-chan struct{}) {
	trafficUsage.load(usageFile(), time.Now())
	go func() {
		t := time.NewTicker(usageSaveEvery)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				trafficUsage.mu.Lock()
				dirty := trafficUsage.dirty
				trafficUsage.mu.Unlock()
				if dirty {
					_ = trafficUsage.save(usageFile(), time.Now())
				}
			case <-stop:
				_ = trafficUsage.save(usageFile(), time.Now())
				return
			}
		}
	}()
}

func handleUsageGet(w http.ResponseWriter, r *http.Request) {
	win, step := usageRange(r.URL.Query().Get("range"))
	writeJSON(w, map[string]any{
		"range":     r.URL.Query().Get("range"),
		"keep_days": int(usageKeep / (24 * time.Hour)),
		"step_sec":  step,
		"now":       time.Now().Unix(),
		"links":     trafficUsage.all(time.Now(), win, step),
	})
}
