// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ClusterConfig struct {
	Enabled        bool                   `json:"enabled"`
	NodeID         string                 `json:"node_id"`
	ClusterSecret  string                 `json:"cluster_secret"`
	PublicIP       string                 `json:"public_ip"`
	ServicePorts   []int                  `json:"service_ports"`
	BalancingMode  string                 `json:"balancing_mode"`
	Nodes          map[string]ClusterNode `json:"nodes"`
	ForeignNodes   map[string]ForeignNode `json:"foreign_nodes"`
	ActiveForeign  string                 `json:"active_foreign,omitempty"`
	AutoFailover   bool                   `json:"auto_failover"`
	ActiveFailover string                 `json:"active_failover,omitempty"`
	FailoverTarget string                 `json:"failover_target,omitempty"`
	Updated        string                 `json:"updated,omitempty"`
}

type ForeignNode struct {
	ID          string      `json:"id"`
	Name        string      `json:"name"`
	PublicIP    string      `json:"public_ip"`
	TunnelPort  int         `json:"tunnel_port"`
	TargetPorts map[int]int `json:"target_ports,omitempty"`
	Weight      int         `json:"weight"`
	Protocol    string      `json:"protocol"`
	IsActive    bool        `json:"is_active"`
	IsHealthy   bool        `json:"is_healthy"`
	LatencyMs   float64     `json:"latency_ms"`
	LastProbe   time.Time   `json:"last_probe"`
}

type ClusterNode struct {
	TLSFingerprint string    `json:"tls_fingerprint,omitempty"`
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	APIURL         string    `json:"api_url"`
	PublicIP       string    `json:"public_ip"`
	TunnelStatus   string    `json:"tunnel_status"`
	TunnelLoss     float64   `json:"tunnel_loss"`
	LatencyMs      float64   `json:"latency_ms"`
	LastSeen       time.Time `json:"last_seen"`
	IsHealthy      bool      `json:"is_healthy"`
	IsFailing      bool      `json:"is_failing"`
}

type ClusterHeartbeatPayload struct {
	NodeID       string  `json:"node_id"`
	PublicIP     string  `json:"public_ip"`
	TunnelStatus string  `json:"tunnel_status"`
	TunnelLoss   float64 `json:"tunnel_loss"`
	IsFailing    bool    `json:"is_failing"`
	Timestamp    int64   `json:"timestamp"`
}

var (
	clusterMu            sync.RWMutex
	clusterCache         *ClusterConfig
	clusterClient        = &http.Client{Timeout: 3 * time.Second}
	consecutiveFailures  int
	consecutiveSuccesses int
)

func clusterConfigFile() string {
	return filepath.Join(configDir, "cluster_v2.json")
}

func defaultClusterConfig() ClusterConfig {
	return ClusterConfig{
		Enabled:       false,
		NodeID:        "iran-" + strconv.FormatInt(time.Now().Unix()%10000, 10),
		ClusterSecret: "",
		PublicIP:      "",
		ServicePorts:  []int{443, 8443, 2083},
		BalancingMode: "wrr",
		Nodes:         make(map[string]ClusterNode),
		ForeignNodes:  make(map[string]ForeignNode),
		AutoFailover:  true,
	}
}

func cloneClusterConfig(c ClusterConfig) ClusterConfig {
	out := c
	out.ServicePorts = append([]int(nil), c.ServicePorts...)
	out.Nodes = make(map[string]ClusterNode, len(c.Nodes))
	for k, v := range c.Nodes {
		out.Nodes[k] = v
	}
	out.ForeignNodes = make(map[string]ForeignNode, len(c.ForeignNodes))
	for k, v := range c.ForeignNodes {
		if v.TargetPorts != nil {
			tp := make(map[int]int, len(v.TargetPorts))
			for p, q := range v.TargetPorts {
				tp[p] = q
			}
			v.TargetPorts = tp
		}
		out.ForeignNodes[k] = v
	}
	return out
}

func loadClusterConfig() ClusterConfig {
	clusterMu.Lock()
	defer clusterMu.Unlock()
	return cloneClusterConfig(*clusterCacheLocked())
}

func updateClusterRuntime(fn func(c *ClusterConfig)) {
	clusterMu.Lock()
	defer clusterMu.Unlock()
	fn(clusterCacheLocked())
}

func clusterCacheLocked() *ClusterConfig {
	if clusterCache != nil {
		return clusterCache
	}

	data, err := os.ReadFile(clusterConfigFile())
	if err != nil || len(data) == 0 {
		def := defaultClusterConfig()
		clusterCache = &def
		return clusterCache
	}

	var c ClusterConfig
	if err := json.Unmarshal(data, &c); err != nil {
		def := defaultClusterConfig()
		clusterCache = &def
		return clusterCache
	}

	if c.Nodes == nil {
		c.Nodes = make(map[string]ClusterNode)
	}
	if c.ForeignNodes == nil {
		c.ForeignNodes = make(map[string]ForeignNode)
	}
	for id, fn := range c.ForeignNodes {
		if fn.Weight <= 0 {
			fn.Weight = 1
			c.ForeignNodes[id] = fn
		}
	}
	if len(c.ServicePorts) == 0 {
		c.ServicePorts = []int{443, 8443, 2083}
	}
	if c.BalancingMode == "" {
		c.BalancingMode = "wrr"
	}
	clusterCache = &c
	return clusterCache
}

func saveClusterConfig(c ClusterConfig) error {
	clusterMu.Lock()
	defer clusterMu.Unlock()

	c.Updated = time.Now().Format("2006-01-02 15:04:05")
	if c.Nodes == nil {
		c.Nodes = make(map[string]ClusterNode)
	}
	if c.ForeignNodes == nil {
		c.ForeignNodes = make(map[string]ForeignNode)
	}

	_ = os.MkdirAll(configDir, 0700)
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}

	tmp := clusterConfigFile() + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}

	if err := os.Rename(tmp, clusterConfigFile()); err != nil {
		return err
	}

	saved := cloneClusterConfig(c)
	clusterCache = &saved
	return nil
}

func verifyClusterSecret(r *http.Request, secret string) bool {
	if secret == "" {
		return false
	}
	got := r.Header.Get("X-Cluster-Secret")
	if got == "" {
		auth := r.Header.Get("Authorization")
		if strings.HasPrefix(auth, "Bearer ") {
			got = strings.TrimPrefix(auth, "Bearer ")
		}
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(secret)) == 1
}

func handleClusterStatus(w http.ResponseWriter, r *http.Request) {
	cfg := loadClusterConfig()

	localStatus, localLoss, localLat := getLocalTunnelStatus()

	type clusterStatusResponse struct {
		Enabled        bool                   `json:"enabled"`
		NodeID         string                 `json:"node_id"`
		PublicIP       string                 `json:"public_ip"`
		ClusterSecret  string                 `json:"cluster_secret"`
		ServicePorts   []int                  `json:"service_ports"`
		AutoFailover   bool                   `json:"auto_failover"`
		ActiveFailover string                 `json:"active_failover"`
		FailoverTarget string                 `json:"failover_target"`
		LocalTunnel    map[string]any         `json:"local_tunnel"`
		Nodes          map[string]ClusterNode `json:"nodes"`
		ForeignNodes   map[string]ForeignNode `json:"foreign_nodes"`
		ActiveForeign  string                 `json:"active_foreign"`
		Updated        string                 `json:"updated"`
	}

	resp := clusterStatusResponse{
		Enabled:        cfg.Enabled,
		NodeID:         cfg.NodeID,
		PublicIP:       cfg.PublicIP,
		ClusterSecret:  cfg.ClusterSecret,
		ServicePorts:   cfg.ServicePorts,
		AutoFailover:   cfg.AutoFailover,
		ActiveFailover: cfg.ActiveFailover,
		FailoverTarget: cfg.FailoverTarget,
		LocalTunnel: map[string]any{
			"status":     localStatus,
			"loss_pct":   localLoss,
			"latency_ms": localLat,
		},
		Nodes:         cfg.Nodes,
		ForeignNodes:  cfg.ForeignNodes,
		ActiveForeign: cfg.ActiveForeign,
		Updated:       cfg.Updated,
	}

	writeJSON(w, resp)
}

func handleClusterConfigPost(w http.ResponseWriter, r *http.Request) {

	var req struct {
		Enabled       *bool  `json:"enabled"`
		NodeID        string `json:"node_id"`
		ClusterSecret string `json:"cluster_secret"`
		PublicIP      string `json:"public_ip"`
		ServicePorts  []int  `json:"service_ports"`
		BalancingMode string `json:"balancing_mode"`
		AutoFailover  *bool  `json:"auto_failover"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json body"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	previous := cloneClusterConfig(cfg)
	if req.Enabled != nil {
		cfg.Enabled = *req.Enabled
	}
	if strings.TrimSpace(req.NodeID) != "" {
		cfg.NodeID = strings.TrimSpace(req.NodeID)
	}
	if req.ClusterSecret != "" {
		cfg.ClusterSecret = strings.TrimSpace(req.ClusterSecret)
	}
	if req.PublicIP != "" {
		cfg.PublicIP = strings.TrimSpace(req.PublicIP)
	}
	if len(req.ServicePorts) > 0 {
		var validPorts []int
		for _, p := range req.ServicePorts {
			if p > 0 && p < 65536 {
				validPorts = append(validPorts, p)
			}
		}
		if len(validPorts) > 0 {
			cfg.ServicePorts = validPorts
		}
	}
	if req.BalancingMode != "" {
		bm := strings.ToLower(strings.TrimSpace(req.BalancingMode))
		if bm == "wrr" || bm == "failover" || bm == "lowest_latency" {
			cfg.BalancingMode = bm
		}
	}
	if req.AutoFailover != nil {
		cfg.AutoFailover = *req.AutoFailover
	}

	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"failed to save config: %s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	if cfg.Enabled && len(cfg.ForeignNodes) > 0 {
		if err := applyClusterLoadBalancing(&cfg); err != nil {
			_ = saveClusterConfig(previous)
			http.Error(w, err.Error(), 500)
			return
		}
	} else if !cfg.Enabled {
		if err := clearClusterFailover(&cfg); err != nil {
			_ = saveClusterConfig(previous)
			http.Error(w, err.Error(), 500)
			return
		}
	}

	writeJSON(w, map[string]string{"status": "ok"})
}

func handleClusterNodeAdd(w http.ResponseWriter, r *http.Request) {

	var req struct {
		TLSFingerprint string `json:"tls_fingerprint"`
		ID             string `json:"id"`
		Name           string `json:"name"`
		APIURL         string `json:"api_url"`
		PublicIP       string `json:"public_ip"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	req.ID = strings.TrimSpace(req.ID)
	req.APIURL = strings.TrimRight(strings.TrimSpace(req.APIURL), "/")
	if req.ID == "" || req.APIURL == "" {
		http.Error(w, `{"error":"id and api_url are required"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	if req.ID == cfg.NodeID {
		http.Error(w, `{"error":"cannot add self as peer node"}`, http.StatusBadRequest)
		return
	}

	node := ClusterNode{
		TLSFingerprint: req.TLSFingerprint,
		ID:             req.ID,
		Name:           req.Name,
		APIURL:         req.APIURL,
		PublicIP:       strings.TrimSpace(req.PublicIP),
		TunnelStatus:   "UNKNOWN",
		LastSeen:       time.Time{},
		IsHealthy:      false,
	}

	if cfg.ClusterSecret != "" {
		probe, lat, err := sendClusterHeartbeat(node.APIURL, cfg.ClusterSecret, ClusterHeartbeatPayload{
			NodeID:   cfg.NodeID,
			PublicIP: cfg.PublicIP,
		})
		if err == nil {
			node.TunnelStatus = probe.TunnelStatus
			node.TunnelLoss = probe.TunnelLoss
			node.LatencyMs = lat
			node.IsFailing = probe.IsFailing
			node.IsHealthy = true
			node.LastSeen = time.Now()
			if node.PublicIP == "" && probe.PublicIP != "" {
				node.PublicIP = probe.PublicIP
			}
		}
	}

	cfg.Nodes[req.ID] = node
	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, `{"error":"failed to save"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]any{"status": "ok", "node": node})
}

func handleClusterNodeDelete(w http.ResponseWriter, r *http.Request) {

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	delete(cfg.Nodes, req.ID)
	if cfg.ActiveFailover == req.ID {
		_ = clearClusterFailover(&cfg)
	}

	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, `{"error":"failed to save"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]string{"status": "ok"})
}

func handleClusterForeignNodeAdd(w http.ResponseWriter, r *http.Request) {

	var req struct {
		ID          string      `json:"id"`
		Name        string      `json:"name"`
		PublicIP    string      `json:"public_ip"`
		TunnelPort  int         `json:"tunnel_port"`
		Protocol    string      `json:"protocol"`
		Weight      int         `json:"weight"`
		TargetPorts map[int]int `json:"target_ports"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	req.ID = strings.TrimSpace(req.ID)
	req.PublicIP = strings.TrimSpace(req.PublicIP)
	if req.ID == "" || req.PublicIP == "" {
		http.Error(w, `{"error":"id and public_ip are required"}`, http.StatusBadRequest)
		return
	}
	if req.TunnelPort <= 0 {
		req.TunnelPort = 55354
	}
	if req.Protocol == "" {
		req.Protocol = "wss"
	}
	if req.Weight <= 0 {
		req.Weight = 1
	}

	cfg := loadClusterConfig()
	fn := ForeignNode{
		ID:          req.ID,
		Name:        req.Name,
		PublicIP:    req.PublicIP,
		TunnelPort:  req.TunnelPort,
		Protocol:    req.Protocol,
		Weight:      req.Weight,
		TargetPorts: req.TargetPorts,
		IsActive:    len(cfg.ForeignNodes) == 0,
		LastProbe:   time.Now(),
	}

	status, lat := probeForeignNodeHealth(fn)
	fn.IsHealthy = (status == "UP")
	fn.LatencyMs = lat

	if cfg.ForeignNodes == nil {
		cfg.ForeignNodes = make(map[string]ForeignNode)
	}
	cfg.ForeignNodes[req.ID] = fn
	if cfg.ActiveForeign == "" {
		cfg.ActiveForeign = req.ID
	}

	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, `{"error":"failed to save"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]any{"status": "ok", "foreign_node": fn})
}

func handleClusterForeignNodeDelete(w http.ResponseWriter, r *http.Request) {

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	delete(cfg.ForeignNodes, req.ID)
	if cfg.ActiveForeign == req.ID {
		cfg.ActiveForeign = ""
		for k, fn := range cfg.ForeignNodes {
			cfg.ActiveForeign = k
			fn.IsActive = true
			cfg.ForeignNodes[k] = fn
			break
		}
	}

	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, `{"error":"failed to save"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]string{"status": "ok"})
}

func handleClusterForeignSwitch(w http.ResponseWriter, r *http.Request) {

	var req struct {
		TargetID string `json:"target_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	target, exists := cfg.ForeignNodes[req.TargetID]
	if !exists {
		http.Error(w, `{"error":"target foreign node not found"}`, http.StatusBadRequest)
		return
	}

	for k, fn := range cfg.ForeignNodes {
		fn.IsActive = (k == req.TargetID)
		cfg.ForeignNodes[k] = fn
	}
	cfg.ActiveForeign = req.TargetID

	if err := saveClusterConfig(cfg); err != nil {
		http.Error(w, `{"error":"failed to save"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, map[string]any{"status": "ok", "active_foreign": target.ID})
}

func handleClusterHeartbeat(w http.ResponseWriter, r *http.Request) {
	cfg := loadClusterConfig()
	if !verifyClusterSecret(r, cfg.ClusterSecret) {
		http.Error(w, `{"error":"unauthorized cluster secret"}`, http.StatusUnauthorized)
		return
	}

	var payload ClusterHeartbeatPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		http.Error(w, `{"error":"invalid json payload"}`, http.StatusBadRequest)
		return
	}

	if payload.NodeID != "" && payload.NodeID != cfg.NodeID {
		updateClusterRuntime(func(c *ClusterConfig) {
			if existing, ok := c.Nodes[payload.NodeID]; ok {
				existing.TunnelStatus = payload.TunnelStatus
				existing.TunnelLoss = payload.TunnelLoss
				existing.IsFailing = payload.IsFailing
				existing.IsHealthy = payload.TunnelStatus == "UP" && !payload.IsFailing
				existing.LastSeen = time.Now()
				if payload.PublicIP != "" {
					existing.PublicIP = payload.PublicIP
				}
				c.Nodes[payload.NodeID] = existing
			}
		})
	}

	localStatus, localLoss, _ := getLocalTunnelStatus()
	resp := ClusterHeartbeatPayload{
		NodeID:       cfg.NodeID,
		PublicIP:     cfg.PublicIP,
		TunnelStatus: localStatus,
		TunnelLoss:   localLoss,
		IsFailing:    localStatus == "DOWN",
		Timestamp:    time.Now().Unix(),
	}

	writeJSON(w, resp)
}

func handleClusterFailoverTrigger(w http.ResponseWriter, r *http.Request) {

	var req struct {
		TargetID string `json:"target_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
		return
	}

	cfg := loadClusterConfig()
	target, ok := cfg.Nodes[req.TargetID]
	if !ok || target.PublicIP == "" {
		http.Error(w, `{"error":"target node not found or has no public IP"}`, http.StatusBadRequest)
		return
	}

	if target.IsFailing {
		http.Error(w, `{"error":"target node tunnel is failing; cannot reroute to it"}`, http.StatusBadRequest)
		return
	}

	if err := applyClusterFailover(&cfg, target); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"failed to apply failover: %s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	_ = saveClusterConfig(cfg)
	writeJSON(w, map[string]string{"status": "ok", "active_failover": target.ID})
}

func handleClusterFailoverRevert(w http.ResponseWriter, r *http.Request) {

	cfg := loadClusterConfig()
	if err := clearClusterFailover(&cfg); err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"failed to clear failover: %s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	_ = saveClusterConfig(cfg)
	writeJSON(w, map[string]string{"status": "ok", "active_failover": ""})
}

func sendClusterHeartbeat(apiURL string, secret string, req ClusterHeartbeatPayload) (*ClusterHeartbeatPayload, float64, error) {
	req.Timestamp = time.Now().Unix()
	body, _ := json.Marshal(req)
	url := strings.TrimRight(apiURL, "/") + "/api/cluster/heartbeat"

	httpReq, err := http.NewRequestWithContext(context.Background(), "POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("X-Cluster-Secret", secret)

	start := time.Now()
	resp, err := clusterHTTPClient(apiURL).Do(httpReq)
	lat := float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return nil, lat, fmt.Errorf("peer status %d: %s", resp.StatusCode, string(b))
	}

	var res ClusterHeartbeatPayload
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return nil, lat, err
	}

	return &res, lat, nil
}

func probeForeignNodeHealth(node ForeignNode) (status string, latency float64) {
	if node.PublicIP == "" || node.TunnelPort <= 0 {
		return "UNKNOWN", 0
	}
	addr := net.JoinHostPort(node.PublicIP, strconv.Itoa(node.TunnelPort))
	start := time.Now()
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return "DOWN", 0
	}
	_ = conn.Close()
	lat := float64(time.Since(start).Microseconds()) / 1000.0
	return "UP", lat
}

func generateClusterBalancingRules(cfg *ClusterConfig) []string {
	if cfg == nil || !cfg.Enabled || len(cfg.ServicePorts) == 0 {
		return nil
	}

	type targetNode struct {
		id          string
		ip          string
		weight      int
		targetPorts map[int]int
	}

	var healthy []targetNode
	for id, fn := range cfg.ForeignNodes {
		if fn.IsHealthy && fn.PublicIP != "" {
			w := fn.Weight
			if w <= 0 {
				w = 1
			}
			healthy = append(healthy, targetNode{
				id:          id,
				ip:          fn.PublicIP,
				weight:      w,
				targetPorts: fn.TargetPorts,
			})
		}
	}

	sort.Slice(healthy, func(i, j int) bool {
		return healthy[i].id < healthy[j].id
	})

	if len(healthy) == 0 {
		return nil
	}

	var rules []string
	totalWeight := 0
	for _, n := range healthy {
		totalWeight += n.weight
	}

	for _, port := range cfg.ServicePorts {
		pStr := strconv.Itoa(port)
		remainingWeight := totalWeight

		for i, node := range healthy {
			targetPort := port
			if node.targetPorts != nil && node.targetPorts[port] > 0 {
				targetPort = node.targetPorts[port]
			}
			targetDst := fmt.Sprintf("%s:%d", node.ip, targetPort)

			isLast := (i == len(healthy)-1)
			if isLast || remainingWeight <= node.weight {

				rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-PREROUTING -p tcp --dport %s -j DNAT --to-destination %s", pStr, targetDst))
				rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-PREROUTING -p udp --dport %s -j DNAT --to-destination %s", pStr, targetDst))
			} else {
				prob := float64(node.weight) / float64(remainingWeight)
				probStr := fmt.Sprintf("%.4f", prob)
				rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-PREROUTING -p tcp --dport %s -m statistic --mode random --probability %s -j DNAT --to-destination %s", pStr, probStr, targetDst))
				rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-PREROUTING -p udp --dport %s -m statistic --mode random --probability %s -j DNAT --to-destination %s", pStr, probStr, targetDst))
				remainingWeight -= node.weight
			}

			rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-POSTROUTING -d %s -p tcp --dport %d -j MASQUERADE", node.ip, targetPort))
			rules = append(rules, fmt.Sprintf("iptables -t nat -A NAVA-CLUSTER-POSTROUTING -d %s -p udp --dport %d -j MASQUERADE", node.ip, targetPort))
		}
	}

	return rules
}

var lastClusterBalancingHash string

func persistClusterFailover(active, target string) {
	fresh := loadClusterConfig()
	fresh.ActiveFailover = active
	fresh.FailoverTarget = target
	_ = saveClusterConfig(fresh)
}

func startClusterMonitor() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for range ticker.C {

		cfg := loadClusterConfig()
		if !cfg.Enabled || (len(cfg.Nodes) == 0 && len(cfg.ForeignNodes) == 0) {
			continue
		}

		var probeMu sync.Mutex

		if len(cfg.ForeignNodes) > 0 {
			ids := make([]string, 0, len(cfg.ForeignNodes))
			nodes := make([]ForeignNode, 0, len(cfg.ForeignNodes))
			for fid, fnode := range cfg.ForeignNodes {
				ids = append(ids, fid)
				nodes = append(nodes, fnode)
			}
			var fwg sync.WaitGroup
			for i := range ids {
				fwg.Add(1)
				go func(id string, fn ForeignNode) {
					defer fwg.Done()
					status, lat := probeForeignNodeHealth(fn)
					probeMu.Lock()
					fn.IsHealthy = (status == "UP")
					fn.LatencyMs = lat
					fn.LastProbe = time.Now()
					cfg.ForeignNodes[id] = fn
					probeMu.Unlock()
				}(ids[i], nodes[i])
			}
			fwg.Wait()
			updateClusterRuntime(func(c *ClusterConfig) {
				for id, probed := range cfg.ForeignNodes {
					if existing, ok := c.ForeignNodes[id]; ok {
						existing.IsHealthy = probed.IsHealthy
						existing.LatencyMs = probed.LatencyMs
						existing.LastProbe = probed.LastProbe
						c.ForeignNodes[id] = existing
					}
				}
			})

			if cfg.Enabled {
				selection := foreignSelection(cfg)
				rules := generateClusterBalancingRules(&selection)
				rulesHash := strings.Join(rules, "\n")
				if rulesHash != lastClusterBalancingHash {
					if err := applyClusterLoadBalancing(&cfg); err == nil {
						lastClusterBalancingHash = rulesHash
					} else {
						log.Printf("cluster apply: %v", err)
					}
				}
			} else if !cfg.Enabled && lastClusterBalancingHash != "" {
				_ = clearClusterFailover(&cfg)
				lastClusterBalancingHash = ""
			}
		}

		if len(cfg.Nodes) == 0 || cfg.ClusterSecret == "" {
			continue
		}

		localStatus, localLoss, _ := getLocalTunnelStatus()
		isLocalFailing := localStatus == "DOWN" || localLoss > 50.0

		peerIDs := make([]string, 0, len(cfg.Nodes))
		peers := make([]ClusterNode, 0, len(cfg.Nodes))
		for id, node := range cfg.Nodes {
			peerIDs = append(peerIDs, id)
			peers = append(peers, node)
		}
		var wg sync.WaitGroup
		for i := range peerIDs {
			wg.Add(1)
			go func(nid string, n ClusterNode) {
				defer wg.Done()
				res, lat, err := sendClusterHeartbeat(n.APIURL, cfg.ClusterSecret, ClusterHeartbeatPayload{
					NodeID:       cfg.NodeID,
					PublicIP:     cfg.PublicIP,
					TunnelStatus: localStatus,
					TunnelLoss:   localLoss,
					IsFailing:    isLocalFailing,
				})

				probeMu.Lock()
				defer probeMu.Unlock()
				if updated, exists := cfg.Nodes[nid]; exists {
					if err == nil {
						updated.TunnelStatus = res.TunnelStatus
						updated.TunnelLoss = res.TunnelLoss
						updated.IsFailing = res.IsFailing
						updated.IsHealthy = res.TunnelStatus == "UP" && !res.IsFailing
						updated.LatencyMs = lat
						updated.LastSeen = time.Now()
						if updated.PublicIP == "" && res.PublicIP != "" {
							updated.PublicIP = res.PublicIP
						}
					} else {
						updated.IsHealthy = false
						updated.LatencyMs = 0
					}
					cfg.Nodes[nid] = updated
				}
			}(peerIDs[i], peers[i])
		}
		wg.Wait()
		updateClusterRuntime(func(c *ClusterConfig) {
			for id, probed := range cfg.Nodes {
				if existing, ok := c.Nodes[id]; ok {
					existing.TunnelStatus = probed.TunnelStatus
					existing.TunnelLoss = probed.TunnelLoss
					existing.IsFailing = probed.IsFailing
					existing.IsHealthy = probed.IsHealthy
					existing.LatencyMs = probed.LatencyMs
					existing.LastSeen = probed.LastSeen
					if existing.PublicIP == "" {
						existing.PublicIP = probed.PublicIP
					}
					c.Nodes[id] = existing
				}
			}
		})

		if cfg.AutoFailover {
			if isLocalFailing {
				consecutiveSuccesses = 0
				consecutiveFailures++

				if consecutiveFailures >= 3 && cfg.ActiveFailover == "" {

					var bestNode *ClusterNode
					for _, candidate := range cfg.Nodes {
						if candidate.IsHealthy && !candidate.IsFailing && candidate.PublicIP != "" {
							if bestNode == nil || candidate.LatencyMs < bestNode.LatencyMs {
								n := candidate
								bestNode = &n
							}
						}
					}
					if bestNode != nil {
						if err := applyClusterFailover(&cfg, *bestNode); err == nil {
							persistClusterFailover(cfg.ActiveFailover, cfg.FailoverTarget)
						} else {
							log.Printf("cluster failover: %v", err)
						}
					}
				}
			} else if localStatus == "UP" {
				consecutiveFailures = 0
				consecutiveSuccesses++

				if consecutiveSuccesses >= 3 && cfg.ActiveFailover != "" {
					_ = clearClusterFailover(&cfg)
					persistClusterFailover("", "")
				}
			}
		}
	}
}

func cliCluster(args []string) int {
	if len(args) == 0 || args[0] == "status" {
		cfg := loadClusterConfig()
		fmt.Printf("Cluster Enabled:  %v\n", cfg.Enabled)
		fmt.Printf("Node ID:          %s\n", cfg.NodeID)
		fmt.Printf("Balancing Mode:   %s\n", cfg.BalancingMode)
		fmt.Printf("Public IP:        %s\n", cfg.PublicIP)
		fmt.Printf("Auto Failover:    %v\n", cfg.AutoFailover)
		fmt.Printf("Active Failover:  %v\n", cfg.ActiveFailover != "")
		if cfg.ActiveFailover != "" {
			fmt.Printf("Failover Target:  %s (%s)\n", cfg.ActiveFailover, cfg.FailoverTarget)
		}
		fmt.Printf("Peer Nodes:       %d\n", len(cfg.Nodes))
		for id, node := range cfg.Nodes {
			fmt.Printf(" - %s (%s, %s): Healthy=%v, Tunnel=%s\n", id, node.Name, node.PublicIP, node.IsHealthy, node.TunnelStatus)
		}
		fmt.Printf("Foreign Nodes:    %d (Active: %s)\n", len(cfg.ForeignNodes), cfg.ActiveForeign)
		for id, fnode := range cfg.ForeignNodes {
			activeMark := ""
			if id == cfg.ActiveForeign || fnode.IsActive {
				activeMark = " [ACTIVE]"
			}
			w := fnode.Weight
			if w <= 0 {
				w = 1
			}
			fmt.Printf(" - %s (%s, %s:%d/%s)%s: Healthy=%v, Latency=%.1fms, Weight=%d\n", id, fnode.Name, fnode.PublicIP, fnode.TunnelPort, fnode.Protocol, activeMark, fnode.IsHealthy, fnode.LatencyMs, w)
		}
		return 0
	}
	if args[0] == "revert" {
		cfg := loadClusterConfig()
		_ = clearClusterFailover(&cfg)
		_ = saveClusterConfig(cfg)
		fmt.Println("Failover iptables NAT rules reverted to local tunnel.")
		return 0
	}
	if args[0] == "add-foreign" {
		if len(args) < 4 {
			fmt.Println("Usage: NavaTunnel cluster add-foreign <name> <ip> <tunnel_port> [weight] [protocol]")
			return 1
		}
		name := args[1]
		ip := args[2]
		port, err := strconv.Atoi(args[3])
		if err != nil || port < 1 || port > 65535 {
			fmt.Println("Invalid port:", args[3])
			return 1
		}
		weight := 1
		if len(args) >= 5 {
			if w, err := strconv.Atoi(args[4]); err == nil && w > 0 {
				weight = w
			}
		}
		proto := "gre"
		if len(args) >= 6 && args[5] != "" {
			proto = args[5]
		}
		cfg := loadClusterConfig()
		if cfg.ForeignNodes == nil {
			cfg.ForeignNodes = make(map[string]ForeignNode)
		}
		id := fmt.Sprintf("fn_%d", time.Now().UnixNano()%100000)
		cfg.ForeignNodes[id] = ForeignNode{
			ID:         id,
			Name:       name,
			PublicIP:   ip,
			TunnelPort: port,
			Weight:     weight,
			Protocol:   proto,
			IsActive:   len(cfg.ForeignNodes) == 0,
			IsHealthy:  true,
			LastProbe:  time.Now(),
		}
		if cfg.ActiveForeign == "" {
			cfg.ActiveForeign = id
		}
		if err := saveClusterConfig(cfg); err != nil {
			fmt.Println("Failed to save cluster config:", err)
			return 1
		}
		fmt.Printf("Foreign node '%s' added with ID: %s (Weight: %d)\n", name, id, weight)
		return 0
	}
	if args[0] == "del-foreign" || args[0] == "rm-foreign" {
		if len(args) < 2 {
			fmt.Println("Usage: NavaTunnel cluster del-foreign <id_or_name>")
			return 1
		}
		target := args[1]
		cfg := loadClusterConfig()
		found := false
		for k, v := range cfg.ForeignNodes {
			if k == target || v.Name == target {
				delete(cfg.ForeignNodes, k)
				found = true
				if cfg.ActiveForeign == k {
					cfg.ActiveForeign = ""
					for nextID := range cfg.ForeignNodes {
						cfg.ActiveForeign = nextID
						break
					}
				}
				break
			}
		}
		if !found {
			fmt.Println("Foreign node not found:", target)
			return 1
		}
		_ = saveClusterConfig(cfg)
		fmt.Println("Foreign node removed:", target)
		return 0
	}
	if args[0] == "set-mode" {
		if len(args) < 2 {
			fmt.Println("Usage: NavaTunnel cluster set-mode <wrr|failover|lowest_latency>")
			return 1
		}
		mode := args[1]
		if mode != "wrr" && mode != "failover" && mode != "lowest_latency" {
			fmt.Println("Invalid mode. Allowed: wrr, failover, lowest_latency")
			return 1
		}
		cfg := loadClusterConfig()
		cfg.BalancingMode = mode
		_ = saveClusterConfig(cfg)
		fmt.Println("Balancing mode set to:", mode)
		return 0
	}
	if args[0] == "switch-foreign" {
		if len(args) < 2 {
			fmt.Println("Usage: NavaTunnel cluster switch-foreign <id_or_name>")
			return 1
		}
		target := args[1]
		cfg := loadClusterConfig()
		found := false
		for k, v := range cfg.ForeignNodes {
			if k == target || v.Name == target {
				cfg.ActiveForeign = k
				node := v
				node.IsActive = true
				cfg.ForeignNodes[k] = node
				found = true
			} else {
				node := v
				node.IsActive = false
				cfg.ForeignNodes[k] = node
			}
		}
		if !found {
			fmt.Println("Foreign node not found:", target)
			return 1
		}
		_ = saveClusterConfig(cfg)
		fmt.Println("Switched active foreign node to:", target)
		return 0
	}
	fmt.Println("Usage: NavaTunnel cluster [status | revert | add-foreign | del-foreign | set-mode | switch-foreign]")
	return 1
}
