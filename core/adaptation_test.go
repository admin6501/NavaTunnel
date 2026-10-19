package main

import (
	"bytes"

	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestForeignModesUseOriginalExitPool(t *testing.T) {
	c := ClusterConfig{Enabled: true, ServicePorts: []int{443}, BalancingMode: "failover", ActiveForeign: "a", ForeignNodes: map[string]ForeignNode{"a": {ID: "a", PublicIP: "10.0.0.1", IsHealthy: false, Weight: 1}, "b": {ID: "b", PublicIP: "10.0.0.2", IsHealthy: true, Weight: 3, LatencyMs: 60}, "c": {ID: "c", PublicIP: "10.0.0.3", IsHealthy: true, Weight: 1, LatencyMs: 20}}}
	s := foreignSelection(c)
	if len(s.ForeignNodes) != 1 || s.ActiveForeign != "b" {
		t.Fatalf("failover: %+v", s)
	}
	c.BalancingMode = "lowest_latency"
	s = foreignSelection(c)
	if s.ActiveForeign != "c" {
		t.Fatalf("latency: %+v", s)
	}
	c.BalancingMode = "wrr"
	s = foreignSelection(c)
	r := strings.Join(generateClusterBalancingRules(&s), "\n")
	if !strings.Contains(r, "0.7500") || strings.Contains(r, "10.0.0.1") {
		t.Fatal(r)
	}
}
func TestFirewallFailureDoesNotPublishFailover(t *testing.T) {
	old := clusterRestore
	defer func() { clusterRestore = old }()
	clusterRestore = func(string) error { return errors.New("injected failure") }
	c := defaultClusterConfig()
	e := applyClusterFailover(&c, ClusterNode{ID: "b", PublicIP: "192.0.2.2", IsHealthy: true})
	if e == nil || c.ActiveFailover != "" {
		t.Fatalf("false success: %+v %v", c, e)
	}
}
func TestOwnedFirewallTransactionsDoNotFlushUnrelatedChains(t *testing.T) {
	cfg := defaultClusterConfig()
	cfg.Enabled = true
	cfg.ForeignNodes = map[string]ForeignNode{"a": {ID: "a", PublicIP: "192.0.2.2", IsHealthy: true, Weight: 1}}
	body := clusterBody(&cfg, generateClusterBalancingRules(&cfg))
	for _, bad := range []string{"-F PREROUTING", "-F POSTROUTING", ":PREROUTING ", ":FORWARD "} {
		if strings.Contains(body, bad) {
			t.Fatal(body)
		}
	}
	if !strings.Contains(body, "CONNMARK") || !strings.Contains(body, "--ctstate DNAT") {
		t.Fatal(body)
	}
}
func TestControlRejectsInvalidDestinationsAndCapacity(t *testing.T) {
	for _, body := range []string{`{"id":"bad","public_ip":"1.2.3.4;reboot","tunnel_port":443,"weight":1,"protocol":"gre"}`, `{"id":"bad","public_ip":"192.0.2.2","tunnel_port":65536,"weight":1,"protocol":"gre"}`, `{"id":"bad","public_ip":"192.0.2.2","tunnel_port":443,"weight":0,"protocol":"gre"}`, `{"id":"bad","public_ip":"192.0.2.2","tunnel_port":443,"weight":1,"protocol":"gre","target_ports":{"443":0}}`} {
		if e := validateControl(controlCall{Family: "cluster", Action: "add-foreign", Body: json.RawMessage(body)}); e == nil {
			t.Fatal(body)
		}
	}
}
func TestClusterStatusRedactsSecretsUnlessExplicit(t *testing.T) {
	b := []byte(`{"cluster_secret":"private","nested":{"auth_token":"token"},"node_id":"public"}`)
	out := string(maskOutput(b, false))
	if strings.Contains(out, "private") || strings.Contains(out, `"token"`) {
		t.Fatal(out)
	}
	if !bytes.Equal(maskOutput(b, true), b) {
		t.Fatal("explicit reveal changed output")
	}
}
func TestPeerCertificatePinIsEnforced(t *testing.T) {
	old := configDir
	configDir = t.TempDir()
	clusterCache = nil
	defer func() { configDir = old; clusterCache = nil }()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer server.Close()
	sum := sha256.Sum256(server.Certificate().Raw)
	c := defaultClusterConfig()
	c.Nodes["x"] = ClusterNode{ID: "x", APIURL: server.URL, TLSFingerprint: hex.EncodeToString(sum[:])}
	_ = saveClusterConfig(c)
	r, e := clusterHTTPClient(server.URL).Get(server.URL)
	if e != nil {
		t.Fatal(e)
	}
	io.Copy(io.Discard, r.Body)
	r.Body.Close()
	n := c.Nodes["x"]
	n.TLSFingerprint = strings.Repeat("0", 64)
	c.Nodes["x"] = n
	_ = saveClusterConfig(c)
	if _, e := clusterHTTPClient(server.URL).Get(server.URL); e == nil {
		t.Fatal("wrong certificate pin accepted")
	}
}
func TestCertificatesPersistPrivately(t *testing.T) {
	old := configDir
	configDir = t.TempDir()
	defer func() { configDir = old }()
	a, e := peerFingerprint()
	if e != nil {
		t.Fatal(e)
	}
	b, e := peerFingerprint()
	if e != nil || a != b || len(a) != 64 {
		t.Fatal(a, b, e)
	}
	st, e := os.Stat(filepath.Join(configDir, "peer-api.key"))
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal(st, e)
	}
}

func TestClusterMarksOnlyConfiguredServicePorts(t *testing.T) {
	c := defaultClusterConfig()
	c.ServicePorts = []int{18443}
	body := clusterBody(&c, []string{"iptables -t nat -A NAVA-CLUSTER-PREROUTING -p tcp --dport 18443 -j DNAT --to-destination 192.0.2.2:18443"})
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "-j CONNMARK") && (!strings.Contains(line, "--dport 18443") || !strings.Contains(line, " -p ")) {
			t.Fatal("unscoped mark: " + line)
		}
	}
}
