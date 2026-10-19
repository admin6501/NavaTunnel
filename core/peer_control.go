package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

func peerLinkControl(c controlCall) (int, []byte) {
	p := loadPeerConfig()
	if c.Action == "status" {
		b, _ := json.Marshal(p)
		return 200, maskOutput(b, c.Secrets)
	}
	if c.Action == "config" {
		if e := json.Unmarshal(c.Body, &p); e != nil {
			return 400, []byte(e.Error())
		}
		u, e := url.Parse(p.PeerURL)
		if e != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") {
			return 400, []byte("Valid HTTP(S) peer URL required\n")
		}
		if len(p.PeerSecret) < 24 {
			return 400, []byte("Peer secret must contain at least 24 characters\n")
		}
		if p.Role != "master" && p.Role != "worker" {
			return 400, []byte("Role must be master (Iran) or worker (foreign)\n")
		}
		if e := savePeerConfig(p); e != nil {
			return 500, []byte(e.Error())
		}
		return 200, []byte("Peer link saved. Enable the TLS peer listener on the opposite server.\n")
	}
	if c.Action == "test" {
		start := time.Now()
		_, e := sendToPeer("/api/peer/ping", "POST", map[string]any{})
		_ = updatePeerConfig(func(p *PeerConfig) {
			p.IsConnected = e == nil
			if e == nil {
				p.LatencyMs = float64(time.Since(start).Microseconds()) / 1000
				p.LastSync = time.Now().Format("2006-01-02 15:04:05")
			}
		})
		if e != nil {
			return 400, []byte(e.Error())
		}
		return 200, []byte("Peer authenticated and reachable.\n")
	}
	return 400, []byte("Use peer-link status|config|test\n")
}
func handlePeerApplyCarrier(w http.ResponseWriter, r *http.Request) {
	var v PeerApplyCarrierRequest
	if e := json.NewDecoder(r.Body).Decode(&v); e != nil {
		http.Error(w, "invalid request", 400)
		return
	}
	if e := carrierApplicable(v.Carrier); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	out, e := applyCarrierMode(v.Carrier)
	if e != nil {
		http.Error(w, fmt.Sprint(e), 500)
		return
	}
	writeJSON(w, map[string]any{"status": "ok", "detail": out})
}
func peerHeartbeatLoop(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p := loadPeerConfig()
			if p.PeerURL != "" && len(p.PeerSecret) >= 24 {
				_, _ = peerLinkControl(controlCall{Action: "test"})
			}
		}
	}
}
