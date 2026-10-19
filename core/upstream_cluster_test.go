// SPDX-License-Identifier: AGPL-3.0-only
// Adapted upstream regression tests; see THIRD_PARTY_NOTICES.md.
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"
)

func setupClusterTest(t *testing.T) (string, func()) {
	t.Helper()
	dir, err := os.MkdirTemp("", "cluster_test_*")
	if err != nil {
		t.Fatalf("MkdirTemp failed: %v", err)
	}

	origConfigDir := configDir
	configDir = dir
	clusterMu.Lock()
	clusterCache = nil
	clusterMu.Unlock()

	cleanup := func() {
		configDir = origConfigDir
		clusterMu.Lock()
		clusterCache = nil
		clusterMu.Unlock()
		_ = os.RemoveAll(dir)
	}

	return dir, cleanup
}

func TestClusterConfigPersistence(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	cfg := loadClusterConfig()
	if cfg.Enabled {
		t.Errorf("expected cluster disabled by default")
	}

	cfg.Enabled = true
	cfg.ClusterSecret = "test-secret-12345"
	cfg.PublicIP = "1.2.3.4"
	cfg.ServicePorts = []int{443, 8443}
	cfg.Nodes["node-2"] = ClusterNode{
		ID:       "node-2",
		Name:     "Iran Hub 2",
		APIURL:   "http://5.6.7.8:7777",
		PublicIP: "5.6.7.8",
	}

	if err := saveClusterConfig(cfg); err != nil {
		t.Fatalf("saveClusterConfig failed: %v", err)
	}

	// Invalidate cache and reload
	clusterMu.Lock()
	clusterCache = nil
	clusterMu.Unlock()

	reloaded := loadClusterConfig()
	if !reloaded.Enabled {
		t.Errorf("expected Enabled=true after reload")
	}
	if reloaded.ClusterSecret != "test-secret-12345" {
		t.Errorf("expected secret 'test-secret-12345', got '%s'", reloaded.ClusterSecret)
	}
	if len(reloaded.Nodes) != 1 || reloaded.Nodes["node-2"].PublicIP != "5.6.7.8" {
		t.Errorf("expected node-2 in reloaded nodes: %+v", reloaded.Nodes)
	}
}

func TestVerifyClusterSecret(t *testing.T) {
	req := httptest.NewRequest("POST", "/api/cluster/heartbeat", nil)
	secret := "secret-xyz"

	if verifyClusterSecret(req, secret) {
		t.Errorf("expected false when no auth header provided")
	}

	req.Header.Set("X-Cluster-Secret", "wrong-secret")
	if verifyClusterSecret(req, secret) {
		t.Errorf("expected false for wrong secret")
	}

	req.Header.Set("X-Cluster-Secret", secret)
	if !verifyClusterSecret(req, secret) {
		t.Errorf("expected true with valid X-Cluster-Secret")
	}

	// Test Bearer auth
	req2 := httptest.NewRequest("POST", "/api/cluster/heartbeat", nil)
	req2.Header.Set("Authorization", "Bearer "+secret)
	if !verifyClusterSecret(req2, secret) {
		t.Errorf("expected true with valid Authorization Bearer header")
	}
}

func TestClusterHeartbeatEndpoint(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	cfg := loadClusterConfig()
	cfg.ClusterSecret = "shhh-secret"
	cfg.NodeID = "node-1"
	cfg.PublicIP = "10.0.0.1"
	cfg.Nodes["node-2"] = ClusterNode{
		ID:       "node-2",
		Name:     "Peer 2",
		APIURL:   "http://10.0.0.2:7777",
		PublicIP: "10.0.0.2",
	}
	_ = saveClusterConfig(cfg)

	// 1. Unauthorized request
	req1 := httptest.NewRequest("POST", "/api/cluster/heartbeat", bytes.NewReader([]byte("{}")))
	w1 := httptest.NewRecorder()
	handleClusterHeartbeat(w1, req1)
	if w1.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 Unauthorized, got %d", w1.Code)
	}

	// 2. Authorized request
	payload := ClusterHeartbeatPayload{
		NodeID:       "node-2",
		PublicIP:     "10.0.0.2",
		TunnelStatus: "UP",
		TunnelLoss:   0.0,
		IsFailing:    false,
		Timestamp:    time.Now().Unix(),
	}
	body, _ := json.Marshal(payload)
	req2 := httptest.NewRequest("POST", "/api/cluster/heartbeat", bytes.NewReader(body))
	req2.Header.Set("X-Cluster-Secret", "shhh-secret")
	w2 := httptest.NewRecorder()
	handleClusterHeartbeat(w2, req2)

	if w2.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", w2.Code, w2.Body.String())
	}

	var resp ClusterHeartbeatPayload
	if err := json.Unmarshal(w2.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode heartbeat response: %v", err)
	}
	if resp.NodeID != "node-1" {
		t.Errorf("expected response NodeID 'node-1', got '%s'", resp.NodeID)
	}

	// Verify peer node status was updated in local state
	reloaded := loadClusterConfig()
	peer := reloaded.Nodes["node-2"]
	if !peer.IsHealthy || peer.TunnelStatus != "UP" {
		t.Errorf("expected peer node-2 to be healthy after heartbeat: %+v", peer)
	}
}

func TestClusterFailoverLoopPrevention(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	cfg := loadClusterConfig()
	cfg.ClusterSecret = "sec"
	cfg.Nodes["bad-node"] = ClusterNode{
		ID:           "bad-node",
		Name:         "Failing Node",
		PublicIP:     "9.9.9.9",
		TunnelStatus: "DOWN",
		IsFailing:    true, // Node itself has a broken tunnel
	}
	_ = saveClusterConfig(cfg)

	// Attempt manual failover to the failing node
	body := []byte(`{"target_id":"bad-node"}`)
	req := httptest.NewRequest("POST", "/api/cluster/failover/trigger", bytes.NewReader(body))
	w := httptest.NewRecorder()
	handleClusterFailoverTrigger(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 Bad Request due to loop prevention, got %d", w.Code)
	}
}

func TestClusterMultiForeignConfig(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	cfg := loadClusterConfig()
	if cfg.ForeignNodes == nil {
		t.Fatalf("expected ForeignNodes map to be initialized")
	}

	cfg.ForeignNodes["foreign-de"] = ForeignNode{
		ID:         "foreign-de",
		Name:       "Frankfurt Exit",
		PublicIP:   "198.51.100.73",
		TunnelPort: 55354,
		Protocol:   "wss",
		IsActive:   true,
	}
	cfg.ActiveForeign = "foreign-de"

	if err := saveClusterConfig(cfg); err != nil {
		t.Fatalf("saveClusterConfig failed: %v", err)
	}

	clusterMu.Lock()
	clusterCache = nil
	clusterMu.Unlock()

	reloaded := loadClusterConfig()
	if len(reloaded.ForeignNodes) != 1 {
		t.Fatalf("expected 1 foreign node, got %d", len(reloaded.ForeignNodes))
	}
	if reloaded.ActiveForeign != "foreign-de" {
		t.Fatalf("expected active_foreign 'foreign-de', got '%s'", reloaded.ActiveForeign)
	}
	fn := reloaded.ForeignNodes["foreign-de"]
	if fn.PublicIP != "198.51.100.73" || fn.TunnelPort != 55354 || fn.Protocol != "wss" {
		t.Errorf("unexpected foreign node fields: %+v", fn)
	}
}

func TestClusterWeightedRoundRobinRules(t *testing.T) {
	cfg := ClusterConfig{
		Enabled:       true,
		BalancingMode: "wrr",
		ServicePorts:  []int{443, 8443},
		ForeignNodes: map[string]ForeignNode{
			"fn-1": {
				ID:        "fn-1",
				PublicIP:  "1.1.1.1",
				Weight:    1,
				IsHealthy: true,
			},
			"fn-2": {
				ID:        "fn-2",
				PublicIP:  "2.2.2.2",
				Weight:    2,
				IsHealthy: true,
			},
			"fn-down": {
				ID:        "fn-down",
				PublicIP:  "3.3.3.3",
				Weight:    5,
				IsHealthy: false, // Down node must NOT receive traffic
			},
		},
	}

	rules := generateClusterBalancingRules(&cfg)
	if len(rules) == 0 {
		t.Fatalf("expected balancing rules to be generated")
	}

	// Verify fn-down IP is not present in any rule
	for _, r := range rules {
		if bytes.Contains([]byte(r), []byte("3.3.3.3")) {
			t.Errorf("unhealthy node 3.3.3.3 found in balancing rules: %s", r)
		}
	}

	// Verify 1.1.1.1 and 2.2.2.2 are present
	has1 := false
	has2 := false
	for _, r := range rules {
		if bytes.Contains([]byte(r), []byte("1.1.1.1")) {
			has1 = true
		}
		if bytes.Contains([]byte(r), []byte("2.2.2.2")) {
			has2 = true
		}
	}
	if !has1 || !has2 {
		t.Errorf("expected both healthy nodes in rules, has1=%v has2=%v", has1, has2)
	}
}

func TestClusterCustomTargetPorts(t *testing.T) {
	cfg := ClusterConfig{
		Enabled:       true,
		BalancingMode: "wrr",
		ServicePorts:  []int{443},
		ForeignNodes: map[string]ForeignNode{
			"fn-custom": {
				ID:          "fn-custom",
				PublicIP:    "5.5.5.5",
				Weight:      1,
				IsHealthy:   true,
				TargetPorts: map[int]int{443: 8443}, // Map local 443 -> foreign 8443
			},
		},
	}

	rules := generateClusterBalancingRules(&cfg)
	matched := false
	for _, r := range rules {
		if bytes.Contains([]byte(r), []byte("5.5.5.5:8443")) {
			matched = true
			break
		}
	}
	if !matched {
		t.Errorf("expected destination 5.5.5.5:8443 in rules, got: %+v", rules)
	}
}

func TestCliClusterCommands(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	// 1. Status command
	if code := cliCluster([]string{"status"}); code != 0 {
		t.Fatalf("expected status to return 0, got %d", code)
	}

	// 2. Add foreign node
	if code := cliCluster([]string{"add-foreign", "test-de", "88.99.100.101", "7000", "2", "gre"}); code != 0 {
		t.Fatalf("expected add-foreign to return 0, got %d", code)
	}

	cfg := loadClusterConfig()
	if len(cfg.ForeignNodes) != 1 {
		t.Fatalf("expected 1 foreign node, got %d", len(cfg.ForeignNodes))
	}

	// 3. Set mode
	if code := cliCluster([]string{"set-mode", "wrr"}); code != 0 {
		t.Fatalf("expected set-mode to return 0, got %d", code)
	}
	cfg = loadClusterConfig()
	if cfg.BalancingMode != "wrr" {
		t.Fatalf("expected mode wrr, got %s", cfg.BalancingMode)
	}

	// 4. Switch foreign
	if code := cliCluster([]string{"switch-foreign", "test-de"}); code != 0 {
		t.Fatalf("expected switch-foreign to return 0, got %d", code)
	}

	// 5. Del foreign
	if code := cliCluster([]string{"del-foreign", "test-de"}); code != 0 {
		t.Fatalf("expected del-foreign to return 0, got %d", code)
	}
	cfg = loadClusterConfig()
	if len(cfg.ForeignNodes) != 0 {
		t.Fatalf("expected 0 foreign nodes after deletion, got %d", len(cfg.ForeignNodes))
	}
}

// C3: callers get private copies, so editing one never touches the cache
// another goroutine may be iterating.
func TestClusterConfigCopiesAreIndependent(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	a := loadClusterConfig()
	a.Nodes["x"] = ClusterNode{ID: "x"}
	a.ServicePorts[0] = 1
	if b := loadClusterConfig(); len(b.Nodes) != 0 || b.ServicePorts[0] == 1 {
		t.Fatal("loadClusterConfig shares storage with the cache")
	}
	if err := saveClusterConfig(a); err != nil {
		t.Fatal(err)
	}
	a.Nodes["y"] = ClusterNode{ID: "y"}
	if b := loadClusterConfig(); len(b.Nodes) != 1 {
		t.Fatal("saveClusterConfig kept a reference to the caller's map")
	}
}

// C3: handlers saving while status/monitor read must not crash with
// "concurrent map iteration and map write".
func TestClusterConcurrentAccess(t *testing.T) {
	_, cleanup := setupClusterTest(t)
	defer cleanup()

	done := make(chan struct{})
	var readers sync.WaitGroup
	for i := 0; i < 4; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for {
				select {
				case <-done:
					return
				default:
				}
				c := loadClusterConfig()
				_, _ = json.Marshal(c)
				updateClusterRuntime(func(c *ClusterConfig) {
					for id, n := range c.Nodes {
						n.IsHealthy = !n.IsHealthy
						c.Nodes[id] = n
					}
				})
			}
		}()
	}
	for i := 0; i < 200; i++ {
		c := loadClusterConfig()
		id := "n" + strconv.Itoa(i%10)
		if i%3 == 0 {
			delete(c.Nodes, id)
		} else {
			c.Nodes[id] = ClusterNode{ID: id}
		}
		if err := saveClusterConfig(c); err != nil {
			t.Fatal(err)
		}
	}
	close(done)
	readers.Wait()
}
