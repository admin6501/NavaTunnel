package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var identifierRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)

func validateControl(c controlCall) error {
	if len(c.Body) == 0 {
		c.Body = json.RawMessage(`{}`)
	}
	var v map[string]json.RawMessage
	if e := json.Unmarshal(c.Body, &v); e != nil {
		return e
	}
	str := func(k string) string { var x string; _ = json.Unmarshal(v[k], &x); return x }
	number := func(k string) int { var x int; _ = json.Unmarshal(v[k], &x); return x }
	if c.Family == "cluster" {
		if pin := str("tls_fingerprint"); pin != "" {
			if b, e := hex.DecodeString(strings.ReplaceAll(pin, ":", "")); e != nil || len(b) != 32 {
				return fmt.Errorf("TLS fingerprint must be 64 hexadecimal characters")
			}
		}
		for _, key := range []string{"id", "node_id", "target_id"} {
			if x := str(key); x != "" && !identifierRE.MatchString(x) {
				return fmt.Errorf("invalid %s", key)
			}
		}
		if ip := str("public_ip"); ip != "" {
			p := net.ParseIP(ip)
			if p == nil || p.To4() == nil || p.IsUnspecified() || p.IsMulticast() || p.IsLoopback() {
				return fmt.Errorf("enter a valid unicast IPv4 address")
			}
		}
		if c.Action == "add-foreign" {
			if p := number("tunnel_port"); p < 1 || p > 65535 {
				return fmt.Errorf("probe port must be 1-65535")
			}
			if w := number("weight"); w < 1 || w > 100 {
				return fmt.Errorf("weight must be 1-100")
			}
			if proto := str("protocol"); proto != "gre" && proto != "wss" && proto != "navalink" && proto != "tcp" {
				return fmt.Errorf("supported paths: gre, wss, navalink, tcp")
			}
			var targets map[int]int
			if len(v["target_ports"]) > 0 {
				if e := json.Unmarshal(v["target_ports"], &targets); e != nil {
					return e
				}
				for a, b := range targets {
					if a < 1 || a > 65535 || b < 1 || b > 65535 {
						return fmt.Errorf("invalid service-port mapping")
					}
				}
			}
		}
		if c.Action == "add-iran" {
			u, e := url.Parse(str("api_url"))
			if e != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
				return fmt.Errorf("enter a valid peer HTTP(S) URL without credentials")
			}
			cfg := loadClusterConfig()
			if len(cfg.ClusterSecret) < 24 {
				return fmt.Errorf("configure the shared cluster secret first (at least 24 characters)")
			}
		}
		if c.Action == "config" {
			if mode := str("balancing_mode"); mode != "" && mode != "wrr" && mode != "failover" && mode != "lowest_latency" {
				return fmt.Errorf("mode must be wrr, failover or lowest_latency")
			}
			if secret := str("cluster_secret"); secret != "" && len(secret) < 24 {
				return fmt.Errorf("cluster secret must contain at least 24 characters")
			}
			if raw := v["service_ports"]; len(raw) > 0 {
				var ps []int
				if e := json.Unmarshal(raw, &ps); e != nil {
					return e
				}
				if len(ps) == 0 || len(ps) > 128 {
					return fmt.Errorf("enter 1-128 service ports")
				}
				for _, p := range ps {
					if p < 1 || p > 65535 {
						return fmt.Errorf("invalid service port")
					}
				}
			}
		}
	}
	return nil
}
func requirePeerAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c := loadPeerConfig()
		got := strings.TrimSpace(r.Header.Get("X-Peer-Secret"))
		if got == "" {
			got = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		}
		if len(c.PeerSecret) < 24 || !ConstantTimeCompare(got, c.PeerSecret) {
			http.NotFound(w, r)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		next(w, r)
	}
}
func handlePeerPing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"status": "pong", "version": coreVersion, "active_carrier": loadCarrierConfig().ActiveCarrier, "time": time.Now().UnixNano()})
}
func handlePeerStatus(w http.ResponseWriter, r *http.Request) {
	state, loss, lat := nativeTunnelStatus()
	writeJSON(w, map[string]any{"status": state, "loss": loss, "latency_ms": lat, "version": coreVersion})
}
func endpointPort(s string) int {
	_, p, e := net.SplitHostPort(s)
	if e != nil {
		return 0
	}
	n, _ := strconv.Atoi(p)
	return n
}

func limitedHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	handleClusterHeartbeat(w, r)
}

func controlEnables(b []byte) bool {
	var v struct {
		Enabled bool `json:"enabled"`
	}
	return json.Unmarshal(b, &v) == nil && v.Enabled
}
